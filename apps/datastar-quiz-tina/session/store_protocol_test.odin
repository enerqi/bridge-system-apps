// The store protocol, driven with no shard under it.
//
// This is the half of phase I that can be tested as ordinary code: `acquire`, `release` and
// `peek_time` are plain procedures over a `Store`, and the isolate around them
// (`web/store_isolate.odin`) is a mailbox that calls exactly these. What the tests pin is the part
// that is easy to get wrong and impossible to see from a request log -- who holds a lease, what the
// sweep is allowed to delete, and whether a peek can be starved by one.
package session

import "../corpus"
import "core:testing"
import "core:time"

@(private = "file")
loaded: corpus.Corpus

@(private = "file")
fixture :: proc(t: ^testing.T) -> ^Store {
	if len(registered_systems) == 0 {
		ok: bool
		loaded, ok = corpus.load(context.allocator)
		testing.expect(t, ok, "the corpus did not load")
		register_systems(loaded.systems)
	}
	store := new(Store, context.temp_allocator)
	store^ = make_store(context.temp_allocator)
	return store
}

@(private = "file")
request_for :: proc(sid: string, slot: u8 = 0) -> Acquire_Request {
	request := Acquire_Request {
		settings     = default_settings(),
		variant_slot = slot,
	}
	copy(request.sid[:], sid)
	return request
}

@(private = "file")
SID_A :: "0123456789abcdef0123456789abcdef"
@(private = "file")
SID_B :: "fedcba9876543210fedcba9876543210"

@(test)
test_an_acquire_creates_a_session_and_leases_it :: proc(t: ^testing.T) {
	store := fixture(t)

	first, _ := acquire(store, request_for(SID_A))
	testing.expect(t, first.session != 0, "no session came back")
	testing.expect(t, first.replaced, "a session that did not exist should report itself as new")
	testing.expect(t, !first.busy)

	s := cast(^Session)uintptr(first.session)
	testing.expect(t, s.lease_held, "an acquired session must be leased")
	testing.expect_value(t, s.sid, SID_A)
}

// The whole reason a pointer may cross a shard: while one caller is inside a session, nobody else
// is given it.
//
// A caller that names itself is QUEUED rather than refused -- it is already parked on its reply, so
// the store answers it when the lease comes back. A caller that does not (zero source: a test, or
// the queue being full) gets `busy` and decides for itself.
@(test)
test_a_leased_session_is_busy_until_it_is_released :: proc(t: ^testing.T) {
	store := fixture(t)

	first, _ := acquire(store, request_for(SID_A))
	testing.expect(t, first.session != 0)

	second, queued := acquire(store, request_for(SID_A))
	testing.expect(t, !queued, "a caller with no source cannot be queued")
	testing.expect(t, second.busy, "a leased session must report busy")
	testing.expect_value(t, second.session, 0)

	_, woke := release(store, first.session)
	testing.expect(t, !woke, "nobody was queued, so nobody is owed an answer")

	third, _ := acquire(store, request_for(SID_A))
	testing.expect(t, !third.busy, "a released session must be acquirable again")
	testing.expect_value(t, third.session, first.session)
	testing.expect(t, !third.replaced, "the same session came back, so nothing was replaced")
}

// The queue is what keeps two requests for one session from turning into a millisecond-quantised
// spin. Measured with four connections on one session: retrying served 73 requests a second; this
// serves tens of thousands.
@(test)
test_a_queued_caller_is_handed_the_lease_on_release :: proc(t: ^testing.T) {
	store := fixture(t)

	held, _ := acquire(store, request_for(SID_A))
	testing.expect(t, held.session != 0)

	CALLER :: u64(0xBEEF)
	CORRELATION :: u32(7)
	answer, queued := acquire(store, request_for(SID_A), CALLER, CORRELATION)
	testing.expect(t, queued, "a busy session with a named caller must queue it")
	testing.expect_value(t, answer.session, 0)
	testing.expect(t, !answer.busy, "a queued caller is not a refused one")

	wake, woke := release(store, held.session)
	testing.expect(t, woke, "the release owes the queued caller an answer")
	testing.expect_value(t, wake.source, CALLER)
	testing.expect_value(t, wake.correlation, CORRELATION)
	testing.expect_value(t, wake.reply.session, held.session)

	// The lease PASSED to the waiter rather than being dropped and re-taken, so a request arriving
	// between the two cannot overtake it.
	s := cast(^Session)uintptr(held.session)
	testing.expect(t, s.lease_held, "the woken caller holds the lease")

	late, _ := acquire(store, request_for(SID_A))
	testing.expect(t, late.busy, "a latecomer finds it busy, as it should")
}

// The bound exists so a pathological client cannot grow the store without limit. Past it the answer
// is `busy` again, which the caller can still act on.
@(test)
test_the_queue_is_bounded :: proc(t: ^testing.T) {
	store := fixture(t)

	held, _ := acquire(store, request_for(SID_A))
	for index in 0 ..< WAITERS_MAX {
		_, queued := acquire(store, request_for(SID_A), u64(index + 1), u32(index))
		testing.expectf(t, queued, "waiter %d should have been queued", index)
	}
	overflow, queued := acquire(store, request_for(SID_A), u64(9999), u32(9999))
	testing.expect(t, !queued, "the queue is full, so this one is not on it")
	testing.expect(t, overflow.busy, "and it is told so")
	testing.expect(t, held.session != 0)
}

// A connection that dies mid-call never sends its release. The session is not corrupt -- it is just
// marked -- so the lease has a deadline rather than the browser having a dead quiz.
@(test)
test_a_stale_lease_is_stolen :: proc(t: ^testing.T) {
	store := fixture(t)

	first, _ := acquire(store, request_for(SID_A))
	s := cast(^Session)uintptr(first.session)
	s.lease_taken = time.time_add(time.now(), -(LEASE_MAX + time.Second))

	second, _ := acquire(store, request_for(SID_A))
	testing.expect(t, !second.busy, "a lease older than LEASE_MAX must be stolen")
	testing.expect_value(t, second.session, first.session)
}

// Two variants behind one cookie are two games. The slot is what says which, and a slot that names
// nothing is a malformed message rather than a request.
@(test)
test_the_variant_slot_picks_the_game :: proc(t: ^testing.T) {
	store := fixture(t)
	testing.expect(t, len(registered_systems) >= 2, "this corpus should carry two systems")

	squad, _ := acquire(store, request_for(SID_A, 0))
	swedish, _ := acquire(store, request_for(SID_A, 1))
	testing.expect(t, squad.session != 0 && swedish.session != 0)
	testing.expect(t, squad.session != swedish.session, "one cookie, two variants, two sessions")

	nowhere, _ := acquire(store, request_for(SID_A, 99))
	testing.expect_value(t, nowhere.session, 0)
	testing.expect(t, !nowhere.busy, "a bad slot is a failure, not a busy session")
}

// The held countdown asks ten times a second per open tab. If that took a lease it would make the
// busiest sessions in the process unavailable for a read of one integer.
@(test)
test_a_peek_reads_without_leasing :: proc(t: ^testing.T) {
	store := fixture(t)

	first, _ := acquire(store, request_for(SID_A))
	_, _ = release(store, first.session)

	peek := Peek_Time_Request {
		variant_slot = 0,
	}
	copy(peek.sid[:], SID_A)

	answer := peek_time(store, peek)
	testing.expect(t, answer.found, "the session is there, so the peek should find it")
	testing.expect(t, answer.percent_left >= 0 && answer.percent_left <= 100)

	s := cast(^Session)uintptr(first.session)
	testing.expect(t, !s.lease_held, "a peek must not leave a lease behind")

	// And a peek while somebody else holds the lease still answers: it is a read on the store's own
	// shard, not a claim on the session.
	held, _ := acquire(store, request_for(SID_A))
	testing.expect(t, held.session != 0)
	during := peek_time(store, peek)
	testing.expect(t, during.found, "a peek must not be starved by a lease")
}

@(test)
test_a_peek_for_a_session_that_is_gone_says_so :: proc(t: ^testing.T) {
	store := fixture(t)
	peek := Peek_Time_Request {
		variant_slot = 0,
	}
	copy(peek.sid[:], SID_B)
	testing.expect(t, !peek_time(store, peek).found, "nothing was ever created for this browser")
}

// The sweep is the other half of the lease: a session another shard is inside must not be deleted
// under it, however old it looks.
@(test)
test_the_sweep_leaves_a_leased_session_alone :: proc(t: ^testing.T) {
	store := fixture(t)

	held, _ := acquire(store, request_for(SID_A))
	idle, _ := acquire(store, request_for(SID_B))
	_, _ = release(store, idle.session)

	// Both are old enough to sweep; only one of them is in use.
	stale := time.time_add(time.now(), -(TTL + time.Minute))
	(cast(^Session)uintptr(held.session)).touched = stale
	(cast(^Session)uintptr(idle.session)).touched = stale
	store.last_sweep = time.time_add(time.now(), -(SWEEP_INTERVAL + time.Minute))

	sweep_if_due(store)

	testing.expect_value(t, store_count(store), 1)
	again, _ := acquire(store, request_for(SID_A))
	testing.expect(t, again.busy, "the leased session survived the sweep and is still leased")
}
