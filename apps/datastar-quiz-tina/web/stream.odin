// Streaming: the page, and the Datastar patches every state-changing route sends.
//
// Two shapes appear here and they are not interchangeable.
//
// A DOCUMENT is one large body of a known length: `begin_fixed_stream`, then write on each
// `Send_Ready` until it is gone. The whole thing is rendered up front, because its length has to be
// declared before the first byte.
//
// An SSE STREAM is a sequence of small, separately-framed events. Each Datastar event is serialised
// into ONE exact `reserve_body_exact` reservation, so an event either fits the egress buffer whole
// or is refused -- there is no partial event. That is what makes the answer choreography a list of
// steps rather than one write: each patch is its own reservation, and a pause between them is a
// suspend and a resume rather than a sleep.
//
// WHERE THE BYTES LIVE, which is the one thing to get right in this file.
//
// A response outlives the handler call that started it: the document is rendered on `Request_Start`
// and written over many `Send_Ready`s, and an SSE script is built once and replayed across several
// timed resumes. Tina resets the SCRATCH arena before EVERY handler invocation, so anything held in
// `context.temp_allocator` across one of those boundaries is a dangling pointer -- and because the
// arena is a bump allocator that silently stops, the first symptom is not a crash but a document
// that ends mid-attribute.
//
// So everything a later event will read comes out of an arena the ROUTE STATE owns -- a fixed byte
// array declared in `Stream_State`, which Tina allocates one of per connection slot at boot from
// `state_size`. It is reset at the start of each response, so a connection serving a thousand
// requests never grows.
//
// Not `tina.ctx_working_arena()`, which is the other obvious answer and is wrong: that is Tina's own
// per-connection memory, sized by the framework for the request frame, the header table and the
// route state itself. Writing a 20 KB page into it collides with the framework's bookkeeping, and
// the arena is only about 24 KB to begin with -- measured, by watching the page truncate at 12,832
// bytes mid-attribute.
//
// So the cost of the largest response this app can produce is declared up front and multiplied by
// the connection count, exactly like the egress buffer. That is Tina's bargain: the memory ceiling
// is a number in the source rather than a question answered under load.
package web

import "../render"
import "../session"
import "base:runtime"
import "core:mem"
import "core:strings"
import tina "tina:src"
import datastar "tina:src/extensions/http/datastar"
import http "tina:src/extensions/http/server"

// The tag a timed resume comes back with. Tina has no sleep: a pause is `expect_notification` with a
// timeout, which parks the connection isolate and returns it to the scheduler until the timer wheel
// fires. That is the whole reason a paced toast sequence costs nothing while it waits.
PAUSE_TAG :: tina.Message_Tag(1)

// One step of a stream. Building the whole script up front and then replaying it is what lets the
// session be mutated ONCE, before the first byte -- so a mid-stream reload sees final state rather
// than a half-scored quiz.
Step :: struct {
	kind:     Step_Kind,
	html:     string,
	selector: string,
	mode:     datastar.Patch_Mode,
	pause_ns: u64,
}

Step_Kind :: enum u8 {
	Patch_Elements,
	Patch_Signals,
	Pause,
}

// The most steps one answer can produce: a dozen toasts, each with a sound, a gauge sweep, a signal
// patch and a floater, plus the view pair at the end.
STEPS_MAX :: 96

// How much memory one response may use for the strings it hands to later events.
//
// The largest is the index document: ~20 KB rendered for this corpus, against the Go port's measured
// 20,268 bytes for the same page. The fat morph patch is ~23.6 KB, plus the toast, floater and signal
// strings of one answer.
//
// The CEILING is not a preference. `state_size` on a route registration is a `u16`, so the whole
// `Stream_State` -- this arena, the step array and the cursors -- has to fit 65,535 bytes. That is
// the same u16 coordinate space the egress buffer lives in, and it is the second place in this app
// where Tina's addressing, not its policy, sets the limit. 56 KB leaves ~9 KB for the rest.
//
// Static, and paid per connection slot: 56 KB × 512 = ~29 MB, on top of the egress buffer's 32 MB.
RESPONSE_ARENA_SIZE :: 56 * 1024

// Initial builder capacities, chosen so a response never has to GROW inside the arena -- a doubling
// realloc would need the old and new buffers at once and blow a budget that fits comfortably
// otherwise.
DOCUMENT_CAPACITY :: 40 * 1024
APP_BODY_CAPACITY :: 24 * 1024

// What this response is waiting for, when it is parked.
//
// Both a pause and a store round trip come back as `Application_Reply`, so the handler cannot tell
// them apart from the event alone -- this is what tells it. `.None` means the response is not
// parked on anything.
Pending :: enum u8 {
	None,
	// Waiting for the session store to answer `TAG_ACQUIRE`. That answer may be QUEUED behind
	// another connection's lease on the same session, in which case it simply arrives later -- the
	// wait is the store's, not a retry loop here.
	Session,
	// Waiting out a toast's pause, which is the ordinary case.
	Pause,
}

// What an in-flight response is holding. One per connection slot, sized at boot.
Stream_State :: struct {
	// A rendered document, for the page route.
	document:    string,
	offset:      int,

	// A script of SSE steps, for everything else.
	steps:       [STEPS_MAX]Step,
	count:       int,
	next:        int,
	started:     bool,

	// The session round trip. See `session/store_protocol.odin`.
	pending:     Pending,
	// The session this response holds a LEASE on, as an integer, or 0. Every exit path from the
	// build has to give it back -- including the failures, which is why it lives on the state and
	// not in a local.
	leased:      u64,
	// What the request said, kept across the park. The strings in it point at the request frame or
	// at this response's arena, both of which outlive the park.
	read:        Request_Read,
	switching:   bool,

	// The response's own memory. See the note at the top of this file.
	arena:       mem.Arena,
	arena_bytes: [RESPONSE_ARENA_SIZE]u8,
	arena_ready: bool,
}

// How long a connection waits for the store before giving up on it. Generous: the store answers in
// microseconds, and the only way to reach this is the store being gone.
STORE_TIMEOUT_NS :: u64(2_000_000_000)

// The session, taken here and now, when the store is on this thread.
//
// `ready = false` means there is no local store -- the shard count is above one -- and the caller
// should ask the isolate instead. Everything else about the two paths is the same, including the
// lease: it is taken here and given back by `release_session` exactly as it would be by message.
acquire_here :: proc(state: ^Stream_State) -> (resolved: Request_Context, ready: bool) {
	if local_store == nil {
		return {}, false
	}
	request := session.Acquire_Request {
		settings     = state.read.settings,
		variant_slot = u8(max(state.read.variant_slot, 0)),
	}
	copy(request.sid[:], state.read.sid)

	answer, _ := session.acquire(local_store, request)
	if answer.session == 0 {
		return {}, false
	}
	state.leased = answer.session
	return resolved_from(state.read, cast(^session.Session)uintptr(answer.session), answer.replaced), true
}

// Ask the store for this request's session and park until it answers.
//
// The reply comes back as `Application_Reply` with `TAG_ACQUIRED`, which is why `pending` is set:
// a paused toast script resumes through the same event.
acquire_session :: proc(route_context: http.Route_Context, state: ^Stream_State) -> http.Route_Step {
	handle := store_handle()
	if handle == tina.ISOLATE_HANDLE_NONE {
		// The store has not booted yet. Microseconds wide, and answering 503 is honest.
		return http.Route_Step.Close
	}

	request := session.Acquire_Request {
		settings     = state.read.settings,
		variant_slot = u8(max(state.read.variant_slot, 0)),
	}
	copy(request.sid[:], state.read.sid)

	if http.expect_reply(
		   route_context,
		   handle,
		   TAG_ACQUIRE,
		   mem.byte_slice(&request, size_of(request)),
		   STORE_TIMEOUT_NS,
	   ) !=
	   .ok {
		return http.Route_Step.Close
	}
	state.pending = .Session
	return http.Route_Step.Expect_Application
}

// Read the store's answer.
//
// Two outcomes now, not three: the session, or nothing. A session somebody else is inside no longer
// comes back as `busy` -- the store queues this connection and answers it when the lease returns,
// which it can do because the connection is parked on exactly this (source, tag, correlation). What
// is left here is the real failure: the store never answered, and the caller says 503.
session_from_reply :: proc(
	reply: http.Application_Reply,
	route_context: http.Route_Context,
	state: ^Stream_State,
) -> (
	resolved: Request_Context,
	ready: bool,
) {
	state.pending = .None

	if reply.reply_result == .Timeout {
		return {}, false
	}
	if reply.message_tag != TAG_ACQUIRE || len(reply.payload_bytes) < size_of(session.Acquire_Reply) {
		return {}, false
	}

	answer := (cast(^session.Acquire_Reply)raw_data(reply.payload_bytes))^
	// `busy` reaches here only when the store's queue is full, which is a store under abuse rather
	// than a session under contention. It is answered the same way a missing store is.
	if answer.busy || answer.session == 0 {
		return {}, false
	}

	state.leased = answer.session
	return resolved_from(state.read, cast(^session.Session)uintptr(answer.session), answer.replaced), true
}

// What to say when `session_from_reply` did not hand back a session.
//
// 503 rather than a closed connection: the browser is not wrong, this server is, and a status code
// says so where a reset does not.
pending_step :: proc(state: ^Stream_State, response: ^http.Response) -> http.Route_Step {
	release_session(state)
	return http.respond_text(response, http.HTTP_STATUS_SERVICE_UNAVAILABLE, "the session store is not answering")
}

// Give the session back. Fire and forget: the store needs no answer, and a caller that waited for
// one would pay a second round trip for nothing.
release_session :: proc(state: ^Stream_State) {
	if state.leased == 0 {
		return
	}
	if local_store != nil {
		bits := state.leased
		state.leased = 0
		// A local release can wake a queued caller too -- it just cannot be another shard, so the
		// only way to be queued here is two requests for one session in flight at once.
		wake, woke := session.release(local_store, bits)
		if woke {
			reply := wake.reply
			_ = tina.ctx_send_with_correlation(
				tina.Isolate_Handle(wake.source),
				TAG_ACQUIRE,
				mem.byte_slice(&reply, size_of(reply)),
				tina.Correlation_Id(wake.correlation),
			)
		}
		return
	}
	request := session.Release_Request {
		session = state.leased,
	}
	state.leased = 0
	handle := store_handle()
	if handle == tina.ISOLATE_HANDLE_NONE {
		return
	}
	_ = tina.ctx_send(handle, TAG_RELEASE, &request)
}

// The arena of the response currently being built. A package-level pointer rather than a parameter
// threaded through every writer, because the render tree is deep and every level would carry it.
//
// Safe because one shard runs one handler at a time: it is set on entry and never read outside one.
// `@(thread_local)` is what keeps that sentence true above one shard -- a Tina shard is an OS
// thread, so thread-local IS per-shard, and two shards building responses at the same instant each
// see their own. Without it this is the fastest way to hand one connection another's arena.
@(private)
@(thread_local)
current_state: ^Stream_State

//
// Documents
//

// The allocator for anything that outlives the handler call: the rendered document, and every string
// an SSE step points at. NOT `context.temp_allocator` -- see the note at the top of this file.
response_arena :: proc() -> runtime.Allocator {
	// The guard is not defensive noise. `current_state` is a package-level pointer, and the routes
	// that do NOT use a `Stream_State` -- the held timer, the asset streams -- never set it, so it
	// can still hold the previous request's. Allocating from an arena that was never initialised
	// panics the shard ("Allocation on uninitialized Arena allocator"), which is how this was found.
	// Anything asking for response memory outside a scripted response gets scratch instead, which is
	// the right answer for a string consumed inside one handler call.
	if current_state == nil || !current_state.arena_ready {
		return context.temp_allocator
	}
	return mem.arena_allocator(&current_state.arena)
}

// Point the response allocator at this connection's state and reclaim the previous response's bytes.
// Called once per response, on `Request_Start`.
response_arena_begin :: proc(state: ^Stream_State) {
	if !state.arena_ready {
		mem.arena_init(&state.arena, state.arena_bytes[:])
		state.arena_ready = true
	}
	free_all(mem.arena_allocator(&state.arena))
	current_state = state
}

// Re-point the allocator on a resumed event, without discarding what the response already built.
response_arena_resume :: proc(state: ^Stream_State) {
	current_state = state
}

// Begin streaming a rendered document. The body is already built, so its length is known.
begin_document :: proc(
	response: ^http.Response,
	request: ^http.Request,
	state: ^Stream_State,
	document: string,
	content_type: string,
	cache_control: string,
) -> http.Route_Step {
	// NOT `state^ = Stream_State{...}`: the document was just rendered INTO this state's arena, and
	// assigning a fresh struct would zero the bytes it points at. Only the document cursor is reset.
	state.offset = 0
	if http.header_set(response, "Cache-Control", cache_control) != .Staged {
		return http.close()
	}

	// Compressed into the RESPONSE arena, so the compressed bytes outlive this handler call the same
	// way the rendered document does.
	encoded := Encoded {
		identity = transmute([]u8)document,
	}
	// Only for a client that ASKED. Compressing unconditionally and then choosing is the same answer
	// for the browser and a different one for the machine: measured with the closed-loop probe, a
	// `GET /` with `Accept-Encoding: identity` cost exactly what a brotli one did, because the work
	// was done either way and thrown away.
	if wants_brotli(request) {
		if compressed, ok := compress_whole(transmute([]u8)document, response_arena()); ok {
			encoded.brotli = compressed
		}
	}

	// The chosen form and the DECLARED LENGTH are one decision. Tina asserts that a fixed-length body
	// matches its Content-Length exactly, and the panic kills the connection isolate -- so getting
	// this pair out of step shows up as a connection reset, not a short page.
	state.document = string(choose_encoding(response, request, encoded))
	if http.begin_fixed_stream(response, http.HTTP_STATUS_OK, content_type, u64(len(state.document))) != .Begun {
		return http.close()
	}
	return pump_document(response, state)
}

// Write until the buffer stops admitting, then flush. A short `write_bytes` is not an error: it is
// the backpressure protocol, and the rest belongs to the next `Send_Ready`.
pump_document :: proc(response: ^http.Response, state: ^Stream_State) -> http.Route_Step {
	remaining := transmute([]u8)state.document[state.offset:]
	for len(remaining) > 0 {
		written := int(http.write_bytes(response, remaining))
		if written == 0 {
			break
		}
		state.offset += written
		remaining = remaining[written:]
	}
	return http.flush(final = len(remaining) == 0)
}

//
// SSE scripts
//

script_reset :: proc(state: ^Stream_State) {
	state.count = 0
	state.next = 0
	state.started = false
	state.pending = .None
}

// An EMPTY payload is dropped rather than pushed, and that guard is load-bearing rather than tidy.
// `patch_elements` refuses an empty payload unless the mode is `.Remove`, the handler closes on the
// error, and the stream then simply STOPS -- the client keeps whatever it had. That is not
// hypothetical: the toast script's last entry is `Toast{text = "", pause = 1.0}`, the pause the
// python's panel handler took before moving on, and `render.toast` renders no element for it. Every
// CORRECT answer therefore ended its stream one step early, losing that pause, the toast clear AND
// the fat morph -- so the card never advanced until the next interaction, while the run showed no
// failures at all. Measured before the fix: a correct answer's stream ran 1,510 ms against the Go
// port's 2,513 ms for the same script. A step that renders nothing should contribute its PAUSE and
// nothing else, which is what dropping it here does.
push_elements :: proc(state: ^Stream_State, html: string, selector: string = "", mode: datastar.Patch_Mode = .Inner) {
	if state.count >= STEPS_MAX {
		return
	}
	if html == "" && mode != .Remove {
		return
	}
	state.steps[state.count] = Step {
		kind     = .Patch_Elements,
		html     = html,
		selector = selector,
		mode     = mode,
	}
	state.count += 1
}

push_signals :: proc(state: ^Stream_State, json: string) {
	if state.count >= STEPS_MAX {
		return
	}
	state.steps[state.count] = Step {
		kind = .Patch_Signals,
		html = json,
	}
	state.count += 1
}

push_pause :: proc(state: ^Stream_State, seconds: f64) {
	if state.count >= STEPS_MAX || seconds <= 0 {
		return
	}
	state.steps[state.count] = Step {
		kind     = .Pause,
		pause_ns = u64(seconds * 1_000_000_000),
	}
	state.count += 1
}

// Empty a slot.
//
// The python and the Go port both do this by patching EMPTY elements with mode `inner`. Tina's SDK
// refuses that -- `patch_elements` returns `.Invalid_Argument` for an empty payload unless the mode
// is `.Remove` -- and the failure is silent from the browser's side: the stream just stops, because
// the handler closes on the error. It cost an afternoon, so it is written down here.
//
// Replacing the whole element with an empty one is the same thing said in a way the SDK accepts, and
// it is what `.Outer` is for. The replacements have to carry the element's own attributes, or the
// clear would quietly drop `aria-live` from the toast slot and `hidden` from the sound sink.
EMPTY_TOASTS :: `<div class="toasts" id="toasts" aria-live="polite"></div>`
EMPTY_SFX :: `<div id="sfx" hidden aria-hidden="true"></div>`
EMPTY_TOPICS_STATUS :: `<div id="topics-status" class="filter-status"></div>`

clear_toasts :: proc(state: ^Stream_State) {
	push_elements(state, EMPTY_TOASTS, "#toasts", .Outer)
}

clear_sfx :: proc(state: ^Stream_State) {
	push_elements(state, EMPTY_SFX, "#sfx", .Outer)
}

clear_topics_status :: proc(state: ^Stream_State) {
	push_elements(state, EMPTY_TOPICS_STATUS, "#topics-status", .Outer)
}

// The standard pair every state-changing route ends with: the whole `#app` body, then the whole
// signal set.
//
// FAT MORPH -- `#app` entire rather than the handful of elements that changed. It costs ~3.4 KB more
// per interaction and the repetitive markup compresses well; what it buys is one description of what
// the page looks like in a given state instead of six that drift.
push_view :: proc(state: ^Stream_State, s: ^session.Session) {
	body := strings.builder_make(0, APP_BODY_CAPACITY, response_arena())
	render.write_app_body(&body, render_context_for(s), s, filter_status_for(s))
	push_elements(state, strings.to_string(body), "#app", .Inner)
	push_signals(state, render.view_signals(s, response_arena()))
}

// A session whose page has fallen behind gets the same fat patch plus a warning, so a stale tab
// catches up rather than silently doing nothing.
push_resync :: proc(state: ^Stream_State, s: ^session.Session) {
	push_view(state, s)
	push_elements(
		state,
		`<div class="toast warning notification is-warning">Quiz reloaded — this page has caught up</div>`,
		"#toasts",
		.Inner,
	)
}

// Run the script from wherever it left off, until it finishes or hits a pause.
//
// `.Expect_Application` parks the connection isolate on the timer wheel; it resumes on
// `Application_Reply` with `reply_result == .Timeout` and comes straight back here.
run_script :: proc(
	response: ^http.Response,
	route_context: http.Route_Context,
	state: ^Stream_State,
) -> http.Route_Step {
	// An empty script is 204 NO CONTENT -- a deliberate no-op, not an error. Skip with none left,
	// Next while not on a reveal, a settings post that changed nothing, an answer to a finished
	// quiz: all of them land here, and the load harness counts a 204 as a success.
	if state.count == 0 {
		return http.respond_text(response, http.HTTP_STATUS_NO_CONTENT, "")
	}

	generator: datastar.Generator
	if !state.started {
		start_error: datastar.SSE_Start_Error
		generator, start_error = datastar.start_sse(response)
		if start_error != .None {
			return http.close()
		}
		state.started = true
	} else {
		generator = datastar.resume(response)
	}

	for state.next < state.count {
		step := state.steps[state.next]
		state.next += 1

		switch step.kind {
		case .Patch_Elements:
			options := datastar.Patch_Elements_Options {
				selector = step.selector,
				mode     = step.mode,
			}
			if datastar.patch_elements(&generator, step.html, options) != .None {
				return http.close()
			}
		case .Patch_Signals:
			if datastar.patch_signals(&generator, step.html) != .None {
				return http.close()
			}
		case .Pause:
			// Flush what has been staged BEFORE parking, or the toasts the player is meant to read
			// during the pause would arrive after it.
			return http.flush()
		}
	}
	return http.flush(final = true)
}

// After a flush that ended on a pause, park for that pause's duration.
resume_after_flush :: proc(route_context: http.Route_Context, state: ^Stream_State) -> http.Route_Step {
	if state.next == 0 || state.next > state.count {
		return http.close()
	}
	previous := state.steps[state.next - 1]
	if previous.kind != .Pause {
		// Backpressure, not a pause: the buffer drained and there is more script to write.
		return state.next < state.count ? http.Route_Step.Flush : http.close()
	}
	// `pending` says which of the two things a resume is: the store answering, or this pause being
	// up. Both arrive as `Application_Reply`, and a script that forgets to say which stops dead at
	// its first pause -- the toasts play, and the fat morph after them never goes.
	state.pending = .Pause
	return http.expect_notification(route_context, previous.pause_ns, tina.ISOLATE_HANDLE_NONE, PAUSE_TAG)
}
