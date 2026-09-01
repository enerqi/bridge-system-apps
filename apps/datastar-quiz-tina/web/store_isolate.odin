// The session store, RUNNING: the isolate half of phase I.
//
// The protocol and the operations are `session/store_protocol.odin`, which has no framework in it.
// This is the mailbox around them -- one isolate, on shard 0, owning the map that every shard needs
// and no shard may touch directly.
//
// `dispatch` in `routes.odin` is the caller: it reads the request, sends `TAG_ACQUIRE` here, parks
// the connection isolate, and builds the response when the answer comes back.
package web

import "../session"
import "core:mem"
import "core:sync"
import tina "tina:src"

// THREE tags, and an answer carries the tag of the question.
//
// `http.expect_reply` records the tag it SENT as the one it will accept back -- the expectation is
// (source, tag, correlation), and the tag half is the request's. An answer under its own
// `TAG_ACQUIRED` is therefore not an answer at all: the connection ignores it and times out two
// seconds later with a healthy store sitting right there. Which of the two answers this is, the
// caller knows from what it asked.
TAG_ACQUIRE: tina.Message_Tag : tina.USER_MESSAGE_TAG_BASE + 20
TAG_RELEASE: tina.Message_Tag : tina.USER_MESSAGE_TAG_BASE + 21
TAG_PEEK_TIME: tina.Message_Tag : tina.USER_MESSAGE_TAG_BASE + 22

// What the store has been asked for, and what it has answered.
//
// Atomic because they are written on the store's shard and read by whatever serves `/health`, which
// is any shard. They exist because the failure this protocol can produce -- a caller parked on an
// answer that never comes -- is invisible from both ends otherwise: the connection just waits.
Store_Counters :: struct {
	acquires: u64,
	answered: u64,
	queued:   u64,
	woken:    u64,
	releases: u64,
	peeks:    u64,
	failed:   u64,
}

@(private = "file")
counters: Store_Counters

store_counters :: proc() -> Store_Counters {
	return Store_Counters {
		acquires = sync.atomic_load(&counters.acquires),
		answered = sync.atomic_load(&counters.answered),
		queued = sync.atomic_load(&counters.queued),
		woken = sync.atomic_load(&counters.woken),
		releases = sync.atomic_load(&counters.releases),
		peeks = sync.atomic_load(&counters.peeks),
		failed = sync.atomic_load(&counters.failed),
	}
}

// The store, when it is NOT an isolate.
//
// Above one shard the sessions have to live behind a mailbox: shards share no memory, and nothing
// routes a browser to a shard. At ONE shard none of that is true -- there is a single thread, the
// store is on it, and a message to itself is a park, a scheduler turn and a resume for a map lookup.
// Measured: the same 400-user run that this app has always passed went from 24,934 requests to
// 4,158 with the round trip in the way, and connections piled up half-closed while the client waited.
//
// So the SEAM is the protocol, not the transport: `session/store_protocol.odin` holds the operations,
// and they are called directly here and by message there. One shard is the default and the number
// the comparison is measured at, so this is the path that runs in practice; the isolate below is
// what makes the shard count a setting, and `just shardcheck` is what proves it works across shards.
@(private)
local_store: ^session.Store

// Set up whichever half this process needs. Before `tina_start`, from the main thread.
use_local_store :: proc(allocator := context.allocator) {
	store := new(session.Store, allocator)
	store^ = session.make_store(session.store_allocator())
	local_store = store
}

// The isolate's own state: the store, and nothing else.
Store_Isolate :: struct {
	store: session.Store,
}

// Where connection isolates find the store.
//
// Published by the store's own init and read by every shard, so it is atomic -- the one handle in
// the process that crosses threads. A connection that arrives before the store has booted reads
// `ISOLATE_HANDLE_NONE` and answers 503 rather than dereferencing a zero; that window is microseconds
// wide and only exists at boot.
@(private = "file")
published_handle: u64

store_handle :: proc "contextless" () -> tina.Isolate_Handle {
	return tina.Isolate_Handle(sync.atomic_load_explicit(&published_handle, .Acquire))
}

store_isolate_init :: proc(self_raw: rawptr, args: []u8) -> tina.Isolate_Transition {
	self := tina.self_as(Store_Isolate, self_raw)
	self.store = session.make_store(session.store_allocator())
	sync.atomic_store_explicit(&published_handle, u64(tina.ctx_self_handle()), .Release)
	return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
}

store_isolate_handler :: proc(self_raw: rawptr, message: ^tina.Message) -> tina.Isolate_Transition {
	self := tina.self_as(Store_Isolate, self_raw)

	switch message.tag {
	case TAG_ACQUIRE:
		request := tina.payload_as(session.Acquire_Request, message.user.payload[:])
		// The caller identifies itself so a busy session can QUEUE it: it is parked on this exact
		// (source, tag, correlation) already, so the answer can simply arrive later -- from the
		// release below rather than from here.
		reply, queued := session.acquire(&self.store, request^, u64(message.user.source), u32(message.correlation))
		sync.atomic_add(&counters.acquires, 1)
		if queued {
			sync.atomic_add(&counters.queued, 1)
		} else {
			sync.atomic_add(&counters.answered, 1)
			answer(TAG_ACQUIRE, message, mem.byte_slice(&reply, size_of(reply)))
		}
		return tina.ISOLATE_TRANSITION_WAIT_MESSAGE

	case TAG_RELEASE:
		request := tina.payload_as(session.Release_Request, message.user.payload[:])
		wake, woke := session.release(&self.store, request.session)
		sync.atomic_add(&counters.releases, 1)
		if woke {
			sync.atomic_add(&counters.woken, 1)
			// Answering somebody else's request, from this turn: their correlation, their handle,
			// and the tag they asked under.
			reply := wake.reply
			_ = tina.ctx_send_with_correlation(
				tina.Isolate_Handle(wake.source),
				TAG_ACQUIRE,
				mem.byte_slice(&reply, size_of(reply)),
				tina.Correlation_Id(wake.correlation),
			)
		}
		return tina.ISOLATE_TRANSITION_WAIT_MESSAGE

	case TAG_PEEK_TIME:
		request := tina.payload_as(session.Peek_Time_Request, message.user.payload[:])
		reply := session.peek_time(&self.store, request^)
		sync.atomic_add(&counters.peeks, 1)
		answer(TAG_PEEK_TIME, message, mem.byte_slice(&reply, size_of(reply)))
		return tina.ISOLATE_TRANSITION_WAIT_MESSAGE

	case:
		return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
	}
}

// Answer a request, CARRYING ITS CORRELATION BACK.
//
// Not `ctx_reply`: that one is for a `ctx_call`, and it refuses anything else with
// `.not_call_context` -- silently, if the result is discarded. The HTTP side parks with
// `expect_reply`, which is a SEND plus an expectation keyed on (source, tag, correlation), so the
// answer is an ordinary send carrying the correlation id that arrived.
@(private = "file")
answer :: proc($tag: tina.Message_Tag, message: ^tina.Message, payload: []u8) {
	if tina.ctx_send_with_correlation(message.user.source, tag, payload, message.correlation) != .ok {
		// The caller is parked on this answer. A send that does not land is a connection that waits
		// for its timeout, so it is counted rather than shrugged at.
		sync.atomic_add(&counters.failed, 1)
	}
}
