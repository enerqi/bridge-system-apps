// The SSE choreography: a script of patches and pauses, paced onto the socket.
//
// # Why this file exists at all
//
// odin-http's own streaming writer (`http.Response_Writer`) frames chunks correctly and does NOT
// send them: `.Flush` appends a chunk to the response's buffer, and the bytes reach the socket in
// one `nbio.send` when the response is finally closed. For a file that is exactly right. For this
// app it is the difference between a quiz and a slideshow -- the answer choreography is a toast, a
// beat, another toast, and `apps/datastar-quiz/tools/measure.py` asserts the frames ARRIVE at
// roughly [3, 618, 623, 623, 623] ms. Buffered, they all arrive at once at the end and the harness
// still reports a success.
//
// So the framing comes from odin-http and the SENDING is done here: flush an event into the response
// buffer, hand that buffer to `nbio.send`, and on the completion either park on `nbio.timeout` for
// the step's pause or write the next event. The last event closes the writer, which writes the
// terminating chunk and hands the connection back to odin-http's own request loop -- so the keep-
// alive, the request-body drain and the connection teardown all stay the library's job.
//
// Nothing here allocates. The events are written through the response writer's buffer, the response
// buffer keeps its capacity across the resets, and the `Stream` itself is one allocation from the
// connection arena made before the first byte.
//
// # Where the bytes live
//
// A response outlives the handler call that started it -- a correct answer's script runs ~2.5
// seconds across a dozen callbacks -- so every string a later step points at has to outlive the
// handler too. That memory is the connection's own arena (`http.Connection.temp_allocator`, a
// GROWING `virtual.Arena`), which odin-http frees once, after the response is sent. `request_arena`
// below is the only way this app names it.
//
// This is the one place where the two Odin ports differ in kind rather than in API. Tina's route
// state is a `u16`-addressed fixed block, so the sibling port declares `RESPONSE_ARENA_SIZE :: 56 *
// 1024` per connection slot and pays it at boot whether or not anybody connects; here the arena
// grows to whatever the response needs and is handed back after it. Neither is free: that port knows
// its ceiling before it starts, and this one finds out under load.
package web

import "core:bytes"
import "core:io"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:nbio"
import "core:time"
import http "odinhttp:."

// The most steps one answer can produce: a dozen toasts, each with a sound, a gauge sweep, a signal
// patch and a floater, plus the view pair at the end. A fixed array rather than a `[dynamic]` so the
// script costs one allocation and cannot reallocate under a callback holding a pointer into it.
STEPS_MAX :: 96

// The response writer's staging buffer. One event -- the fat morph, ~24 KB of `#app` -- should form
// ONE chunk, so this is sized above it; a larger write is still correct, it just frames as a chunk
// of its own.
@(private = "file")
WRITER_BUFFER_SIZE :: 32 * 1024

Step_Kind :: enum u8 {
	Patch_Elements,
	Patch_Signals,
	Pause,
}

Step :: struct {
	kind:     Step_Kind,
	html:     string,
	selector: string,
	mode:     Patch_Mode,
	pause:    time.Duration,
}

// One in-flight SSE response.
Stream :: struct {
	response: ^http.Response,
	writer:   http.Response_Writer,
	out:      io.Writer,
	steps:    [STEPS_MAX]Step,
	count:    int,
	next:     int,
	started:  bool,
	finished: bool,
	// Set once the script is spent and the terminating chunk is on its way, so the send completion
	// knows to close rather than to look for another step.
	closing:  bool,
	// A step is finished when BOTH its bytes have left and its pause has elapsed, and those two run
	// concurrently on purpose (see `stream_send`). Whichever finishes second moves the script on.
	sending:  bool,
	paused:   bool,

	// A HELD stream refills instead of ending. `refill` is called when the script runs out: it
	// resets the script, pushes the next beat and returns true, or returns false to close. The
	// countdown in `debug.odin` is the only user -- one tick, one 100 ms pause, for ten minutes --
	// and `user` is what it keeps its place in.
	refill:   proc(stream: ^Stream) -> bool,
	user:     rawptr,
}

// The connection's arena: the allocator for anything that outlives the handler call.
//
// odin-http hands a handler `context.temp_allocator` from whatever thread context the event loop is
// running under, NOT this arena -- so a response built out of `context.temp_allocator` and read back
// in a timer callback is reading memory nobody owns. Naming the connection's own arena is the fix,
// and it is also the right lifetime: `clean_request_loop` frees it after the response is sent.
request_arena :: proc(response: ^http.Response) -> mem.Allocator {
	return virtual.arena_allocator(&response._conn.temp_allocator)
}

//
// Building a script
//

stream_init :: proc(stream: ^Stream, response: ^http.Response) {
	stream.response = response
	stream.count = 0
	stream.next = 0
	stream.started = false
	stream.finished = false
	stream.closing = false
	stream.sending = false
	stream.paused = true
}

// Empty the script without touching anything else. What a refill starts with.
script_reset :: proc(stream: ^Stream) {
	stream.count = 0
	stream.next = 0
}

// An EMPTY payload is dropped rather than queued, and that guard is load-bearing rather than tidy.
//
// The toast script's last entry is `Toast{text = "", pause = 1.0}` -- the beat the python's panel
// handler takes before moving on -- and `render.toast` renders no element for it. An event with no
// `data:` line is not a valid patch, so a step that renders nothing must contribute its PAUSE and
// nothing else. The sibling Tina port shipped this bug: its SDK refused the empty payload, the
// handler closed on the error, and EVERY correct answer lost its final pause, its toast clear AND
// its fat morph -- with no error, no failed request and nothing in the browser to say why.
push_elements :: proc(stream: ^Stream, html: string, selector: string = "", mode: Patch_Mode = .Inner) {
	if stream.count >= STEPS_MAX {
		return
	}
	if html == "" && mode != .Remove {
		return
	}
	stream.steps[stream.count] = Step {
		kind     = .Patch_Elements,
		html     = html,
		selector = selector,
		mode     = mode,
	}
	stream.count += 1
}

push_signals :: proc(stream: ^Stream, json: string) {
	if stream.count >= STEPS_MAX || json == "" {
		return
	}
	stream.steps[stream.count] = Step {
		kind = .Patch_Signals,
		html = json,
	}
	stream.count += 1
}

push_pause :: proc(stream: ^Stream, seconds: f64) {
	if stream.count >= STEPS_MAX || seconds <= 0 {
		return
	}
	stream.steps[stream.count] = Step {
		kind  = .Pause,
		pause = time.Duration(seconds * f64(time.Second)),
	}
	stream.count += 1
}

//
// Running it
//

// Start the response and run the script until it pauses or ends.
//
// An empty script is 204 NO CONTENT -- a deliberate no-op, not an error. Skip with none left, Next
// while not on a reveal, a settings post that changed nothing, an answer to a finished quiz: all of
// them land here, and the load harness counts a 204 as a success.
stream_run :: proc(stream: ^Stream) {
	response := stream.response
	if stream.count == 0 {
		http.respond(response, http.Status.No_Content)
		return
	}

	response.status = .OK
	http.headers_set_unsafe(&response.headers, "content-type", "text/event-stream")
	http.headers_set_unsafe(&response.headers, "cache-control", "no-cache")
	// Nginx and friends buffer an unknown-length body by default, which would undo every pause in
	// the script at the proxy instead of in the app.
	http.headers_set_unsafe(&response.headers, "x-accel-buffering", "no")

	buffer := make([]byte, WRITER_BUFFER_SIZE, request_arena(response))
	stream.out = http.response_writer_init(&stream.writer, response, buffer)
	stream.started = true

	stream_pump(stream)
}

// Write events until the script ends or hits a pause, then get the bytes onto the wire.
@(private = "file")
stream_pump :: proc(stream: ^Stream) {
	for {
		if stream.next >= stream.count {
			// A held stream refills here and keeps going; everything else is done.
			if stream.refill != nil && stream.refill(stream) {
				continue
			}
			stream.closing = true
			io.flush(stream.out)
			stream_send(stream, 0)
			return
		}

		step := stream.steps[stream.next]
		stream.next += 1

		switch step.kind {
		case .Patch_Elements:
			write_patch_elements(stream.out, step.html, step.selector, step.mode)
		case .Patch_Signals:
			write_patch_signals(stream.out, step.html)
		case .Pause:
			// Flush what has been written BEFORE parking, or the toasts the player is meant to read
			// during the pause would arrive after it.
			io.flush(stream.out)
			stream_send(stream, step.pause)
			return
		}
	}
}

// Hand the staged chunks to the socket, and start the pause at the same moment.
//
// THE ORDER OF THESE TWO CALLS IS LOAD-BEARING, and the reason is a `core:nbio` sharp edge that cost
// an afternoon and is worth writing down, because nothing about it is visible from the API.
//
// `nbio`'s tick computes how long to sleep BEFORE it drains the completed-operations queue:
//
//	l.now = time.now()
//	next_timeout := check_timeouts(l)      // <- how long this tick may sleep
//	...drain l.completed, running callbacks...   // <- a callback here registers a new timeout
//	GetQueuedCompletionStatusEx(..., next_timeout, ...)   // <- sleeps past it
//
// A send on loopback completes INLINE, so its callback runs out of that queue -- and a timeout
// registered there is invisible to the sleep that immediately follows. The loop then sleeps until
// the next wake-up it already knew about, which in an odin-http server is the once-a-second date
// header refresh. Measured with a 12-tick repro (scratchpad, `nbiotimer`): a chained 100 ms timeout
// runs at 109 ms on its own AND with a 1 s timer beside it, and at **1010 ms** when it is re-armed
// from a send completion. The quiz's 0.5 s toast beats were arriving 1 s apart, and nothing errored.
//
// A timeout registered from a TIMEOUT callback is fine -- `check_timeouts` re-scans after firing --
// so the fix is to never re-arm from the completion: the pause is registered here, in the callback
// that is already running, and the send is submitted after it. The two then race, and
// `stream_advance` moves on when both are done.
@(private = "file")
stream_send :: proc(stream: ^Stream, pause: time.Duration) {
	stream.paused = pause <= 0
	if pause > 0 {
		nbio.timeout_poly(pause, stream, on_pause_elapsed)
	}

	staged := bytes.buffer_to_bytes(&stream.response._buf)
	if len(staged) == 0 {
		stream.sending = false
		stream_advance(stream)
		return
	}
	stream.sending = true
	nbio.send_poly(stream.response._conn.socket, {staged}, stream, on_sent)
}

@(private = "file")
on_sent :: proc(op: ^nbio.Operation, stream: ^Stream) {
	stream.sending = false
	if op.send.err != nil {
		// A client that went away mid-choreography is ordinary, not an error worth a stack: the
		// player closed the tab during the toasts. Finish the response so odin-http tears the
		// connection down through its own path rather than leaving it in flight.
		log.debugf("sse send failed, closing: %v", op.send.err)
		stream.closing = true
		stream_finish(stream)
		return
	}
	bytes.buffer_reset(&stream.response._buf)
	stream_advance(stream)
}

@(private = "file")
on_pause_elapsed :: proc(_: ^nbio.Operation, stream: ^Stream) {
	stream.paused = true
	stream_advance(stream)
}

// Move on once the step's bytes have left AND its pause has elapsed.
@(private = "file")
stream_advance :: proc(stream: ^Stream) {
	if stream.sending || !stream.paused {
		return
	}
	if stream.closing {
		stream_finish(stream)
		return
	}
	stream_pump(stream)
}

// End the response: terminating chunk, then `respond`, which sends it and hands the connection back
// to odin-http's request loop (keep-alive, body drain, arena reset -- all of it the library's).
@(private = "file")
stream_finish :: proc(stream: ^Stream) {
	if stream.finished {
		return
	}
	stream.finished = true
	io.close(stream.out)
}
