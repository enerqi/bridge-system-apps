// The session store's PROTOCOL and its operations, with no framework in them.
//
// `store.odin` holds the map and the sweep; this file is what a caller on another shard may ask of
// it, as plain data and plain procedures. The ISOLATE that runs them -- the mailbox, the tags, the
// replies -- is `web/store_isolate.odin`, because that is where Tina belongs: this package is
// lint-checked and unit-tested without the framework, like the rest of the app's logic, and the
// tests below drive the whole protocol with no shard under them.
//
// # Why an isolate at all (phase I)
//
// A session belongs to a BROWSER, and nothing routes a browser to a shard: `Reuse_Port` lets the
// kernel put each connection wherever it likes, and coordinator mode hands the FD to whichever shard
// the dispatcher picks. Neither reads a cookie. So the same session is reachable from every shard,
// Tina shards share no memory, and exactly one shard has to own the map.
//
// # The lease, and why a pointer may cross a shard with one
//
// An acquire answers with a POINTER into the store's shard. That is a deliberate exception to
// shared-nothing, and it is safe for one reason: the session is LEASED while the caller holds it, so
// no other shard is inside the same session at the same time and the sweep leaves it alone. The
// lease is taken and released inside ONE handler call -- the app mutates a session once, before the
// first byte of the response (see the note at the top of `web/stream.odin`) -- which is what makes
// that possible.
//
// A lease that is never given back would strand a session, so it also has a deadline: one older than
// `LEASE_MAX` is stolen. That is the connection dying mid-call, which the supervision tree makes an
// ordinary event.
//
// # Reads that do not need a lease
//
// The held countdown looks at one number, ten times a second, per open tab. `peek_time` is for that:
// the store computes the value on its own shard and answers with an integer. No pointer crosses,
// nothing is leased, and the timer can never be the reason a session is busy.
package session

import "../corpus"
import "base:runtime"
import "core:time"

// A session id is 32 hex characters, so it fits a message payload with room to spare -- which is the
// whole reason the protocol is keyed by (sid, variant) rather than by anything richer.
SID_LENGTH :: 32

// How long a lease may be held before the store assumes the holder is dead and takes it back.
//
// A lease is held for the length of ONE handler call -- tens of microseconds -- so this is four
// orders of magnitude of slack. It is not a timeout to tune, it is a leak stopper: the holder died,
// or was woken from the queue and never came back, and the session must not be stuck behind it.
LEASE_MAX :: 5 * time.Second

// How many callers may be QUEUED on busy sessions at once, across the whole store.
//
// Waiting rather than retrying is the difference between a queue and a spin: a caller that finds a
// session busy is parked on its `expect_reply` already, so the store can simply answer it later,
// when the lease comes back. Measured with four connections hammering ONE session: retrying at a
// millisecond a go served 73 requests a second, and the same probe over this queue serves tens of
// thousands. The bound exists so a pathological client cannot grow the store without limit; past it
// the answer is `busy` and the caller decides.
WAITERS_MAX :: 256

// "Give me this session, and make me one if it is not there."
//
// The settings ride along because a session created for a browser that already has a page open must
// adopt what that page is showing rather than snapping back to the defaults.
Acquire_Request :: struct {
	sid:          [SID_LENGTH]u8,
	settings:     Settings,
	variant_slot: u8,
}

// The answer. `session` is a pointer, sent as an integer because a message is bytes.
Acquire_Reply :: struct {
	session:  u64,
	replaced: bool,
	busy:     bool,
}

Release_Request :: struct {
	session: u64,
}

// Somebody parked on a session that was busy, and what it takes to answer them later.
//
// `source` and `correlation` are a Tina handle and correlation id, kept as plain integers because
// this file has no framework in it -- `web/store_isolate.odin` turns them back into a send.
Waiter :: struct {
	session:     u64,
	source:      u64,
	correlation: u32,
}

// A queued caller, now owed an answer.
Wake :: struct {
	source:      u64,
	correlation: u32,
	reply:       Acquire_Reply,
}

Peek_Time_Request :: struct {
	sid:          [SID_LENGTH]u8,
	variant_slot: u8,
}

// The countdown's one number, plus whether the session is still there at all.
Peek_Time_Reply :: struct {
	percent_left: i32,
	found:        bool,
}

#assert(size_of(Acquire_Request) <= 96, "Acquire_Request must fit a Tina message payload")
#assert(size_of(Peek_Time_Request) <= 96, "Peek_Time_Request must fit a Tina message payload")

// The allocator every session and everything hanging off one comes from.
//
// The process heap, explicitly, rather than `context.allocator`: this memory is allocated on the
// store's shard and written by whichever shard holds the lease, so it has to be an allocator that
// survives both -- and inside a Tina handler `context.allocator` is the per-call scratch arena.
// The debug build's tracking allocator is deliberately not used here for the same reason: it is not
// thread-safe, and a session outlives every request that touches it.
store_allocator :: proc() -> runtime.Allocator {
	return runtime.heap_allocator()
}

// The corpus, as the store sees it.
//
// A message carries a variant SLOT rather than a variant name: an index is one byte, a name is a
// string, and a string in a message would have to be copied into the payload and back out again for
// no gain. The slot is the index into this, which is `Corpus.systems` -- registered once, before
// `tina_start`, and read-only from then on, so every shard may point at it.
@(private)
registered_systems: []corpus.System

// Hand the store the corpus. Before `tina_start`, from the main thread, exactly once.
register_systems :: proc(systems: []corpus.System) {
	registered_systems = systems
}

// The variant name in a slot, or "" when the slot names nothing -- which is a malformed message
// rather than a request, and is answered as a failure rather than trusted.
variant_key_for :: proc(slot: int) -> string {
	if slot < 0 || slot >= len(registered_systems) {
		return ""
	}
	return registered_systems[slot].key
}

system_for_slot :: proc(slot: int) -> ^corpus.System {
	if slot < 0 || slot >= len(registered_systems) {
		return nil
	}
	return &registered_systems[slot]
}

// Which slot a system is in, for a caller that has the pointer and needs the message field.
slot_for_system :: proc(system: ^corpus.System) -> int {
	for &candidate, index in registered_systems {
		if &candidate == system {
			return index
		}
	}
	return -1
}

@(private)
make_session_for_slot :: proc(sid: string, slot: int, settings: Settings, allocator: runtime.Allocator) -> ^Session {
	system := system_for_slot(slot)
	if system == nil {
		return nil
	}
	return make_session(sid, system, settings, allocator)
}


// The three operations, as plain procedures over the store, so they can be tested without a shard.

// Take the lease on a session, creating it if this browser has none.
//
// `source` and `correlation` identify the caller so that a BUSY session can queue them instead of
// refusing: `queued = true` means no answer is due yet and one will arrive from `release`. A caller
// that does not want to queue (a test, or the store being full) passes zeros and reads `busy`.
acquire :: proc(
	store: ^Store,
	request: Acquire_Request,
	source: u64 = 0,
	correlation: u32 = 0,
) -> (
	reply: Acquire_Reply,
	queued: bool,
) {
	sid := request.sid
	key := Key {
		sid     = string(sid[:]),
		variant = variant_key_for(int(request.variant_slot)),
	}
	if key.variant == "" {
		return Acquire_Reply{}, false
	}

	found, exists := store_get(store, key)
	if exists {
		if leased(found) {
			if source != 0 && len(store.waiters) < WAITERS_MAX {
				append(
					&store.waiters,
					Waiter{session = u64(uintptr(found)), source = source, correlation = correlation},
				)
				return Acquire_Reply{}, true
			}
			return Acquire_Reply{busy = true}, false
		}
		take_lease(found)
		return Acquire_Reply{session = u64(uintptr(found))}, false
	}

	created := make_session_for_slot(
		clone_sid(request.sid, store.allocator),
		int(request.variant_slot),
		request.settings,
		store.allocator,
	)
	if created == nil {
		return Acquire_Reply{}, false
	}
	store_put(store, Key{sid = created.sid, variant = key.variant}, created)
	take_lease(created)
	return Acquire_Reply{session = u64(uintptr(created)), replaced = true}, false
}

// Give a session back, and hand it straight to whoever is waiting for it.
//
// The lease is not cleared and re-taken in that case: it passes from one holder to the next inside
// this call, so a queued caller cannot be overtaken by a request that arrives in between.
release :: proc(store: ^Store, session_bits: u64) -> (wake: Wake, woke: bool) {
	if session_bits == 0 {
		return {}, false
	}
	s := cast(^Session)uintptr(session_bits)
	s.touched = time.now()

	for waiter, index in store.waiters {
		if waiter.session != session_bits {
			continue
		}
		ordered_remove(&store.waiters, index)
		take_lease(s)
		return Wake {
				source = waiter.source,
				correlation = waiter.correlation,
				reply = Acquire_Reply{session = session_bits},
			},
			true
	}

	s.lease_held = false
	return {}, false
}

peek_time :: proc(store: ^Store, request: Peek_Time_Request) -> Peek_Time_Reply {
	variant := variant_key_for(int(request.variant_slot))
	if variant == "" {
		return Peek_Time_Reply{}
	}
	sid := request.sid
	found, exists := store_get(store, Key{sid = string(sid[:]), variant = variant})
	if !exists {
		return Peek_Time_Reply{}
	}
	return Peek_Time_Reply{percent_left = i32(percent_time_left(found)), found = true}
}

@(private)
leased :: proc(s: ^Session) -> bool {
	if !s.lease_held {
		return false
	}
	// A lease nobody gave back. The holder died mid-call; the session is not corrupt, it is just
	// marked. Steal it rather than stranding the browser it belongs to.
	if time.since(s.lease_taken) > LEASE_MAX {
		s.lease_held = false
		return false
	}
	return true
}

@(private)
take_lease :: proc(s: ^Session) {
	s.lease_held = true
	s.lease_taken = time.now()
}

@(private)
clone_sid :: proc(sid: [SID_LENGTH]u8, allocator: runtime.Allocator) -> string {
	source := sid
	buffer := make([]u8, SID_LENGTH, allocator)
	copy(buffer, source[:])
	return string(buffer)
}
