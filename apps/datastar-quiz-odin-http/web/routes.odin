// The routes.
//
// The pattern is the same throughout: resolve the request, mutate the session, BUILD the whole
// script, and only then start streaming it. State is fully mutated before the first byte, so a
// mid-stream reload sees final state rather than a half-scored session -- and, here, so the session
// lock is held for the build and never for the ~2.5 seconds a correct answer's choreography spends
// on the wire.
//
// The one shape odin-http imposes is that a request body arrives ASYNCHRONOUSLY: `http.body` takes a
// callback, so every POST is "ask for the body, then do the work" rather than one straight-line
// handler. Datastar uploads its signal store as that body, so every POST route in this app goes
// through `sse_route_post` and every GET through `sse_route_get`, and the two meet again in
// `run_build`.
package web

import "../engine"
import "../render"
import "../session"
import "core:strconv"
import "core:strings"
import "core:sync"
import http "odinhttp:."

// The uploaded signal set is ~475 bytes before the topic ticks; 8 KB is generous for the widest
// variant's picker, and a body over it is answered as though nothing was uploaded rather than as an
// error.
@(private = "file")
SIGNALS_BODY_MAX :: 8192

// What a route does when the request arrives. Fills the script; `run_build` runs it.
@(private)
Builder :: #type proc(resolved: Request_Context, request: ^http.Request, stream: ^Stream)

// A POST waiting for its body. Allocated from the connection arena, like everything else a callback
// reads.
@(private = "file")
Pending :: struct {
	request:  ^http.Request,
	response: ^http.Response,
	build:    Builder,
}

@(private)
sse_route_get :: proc(request: ^http.Request, response: ^http.Response, build: Builder) {
	run_build(request, response, "", build)
}

@(private)
sse_route_post :: proc(request: ^http.Request, response: ^http.Response, build: Builder) {
	pending := new(Pending, request_arena(response))
	pending^ = Pending {
		request  = request,
		response = response,
		build    = build,
	}
	http.body(request, SIGNALS_BODY_MAX, pending, on_body)
}

@(private = "file")
on_body :: proc(user_data: rawptr, body: http.Body, error: http.Body_Error) {
	pending := cast(^Pending)user_data
	// A body that could not be read is not a server error: it is answered as though nothing was
	// uploaded, so a corrupted store in one tab cannot 500 the app.
	payload := error == nil ? string(body) : ""
	run_build(pending.request, pending.response, payload, pending.build)
}

// Resolve, mutate, build, stream. The lock covers everything that touches the session store and
// nothing that touches the socket.
@(private = "file")
run_build :: proc(request: ^http.Request, response: ^http.Response, body: string, build: Builder, switching := false) {
	stream := new(Stream, request_arena(response))
	stream_init(stream, response)

	sync.lock(&store_lock)
	resolved := resolve_request(request, response, body, switching)
	set_session_cookie(response, resolved.sid)
	build(resolved, request, stream)
	sync.unlock(&store_lock)

	stream_run(stream)
}

//
// The page
//

route_index :: proc(request: ^http.Request, response: ^http.Response) {
	arena := request_arena(response)

	sync.lock(&store_lock)
	// The index page is the one route that uses the SWITCHING variant rule: a bare url means "back
	// to the default variant", a query naming no variant means "keep what you have".
	resolved := resolve_request(request, response, "", switching = true)
	set_session_cookie(response, resolved.sid)

	// `?debug` arms the debug panel for this session, and it stays armed until the session is swept
	// -- so the panel survives the interactions that patch the page.
	if strings.contains(request.url.query, "debug") {
		resolved.session.debug = true
	}

	document := strings.builder_make(0, DOCUMENT_CAPACITY, arena)
	render.write_shell(
		&document,
		render_context_for(resolved.session),
		resolved.session,
		read_theme(request),
		filter_status_for(resolved.session, arena),
	)
	sync.unlock(&store_lock)

	// `no-store`, not `no-cache`: the page IS the session state, and a back-button restore of a
	// finished quiz showing a live question is worse than a refetch.
	http.headers_set_unsafe(&response.headers, "cache-control", "no-store")
	respond_encoded(request, response, transmute([]u8)strings.to_string(document), "text/html; charset=utf-8")
}

// The initial builder capacity for the index document.
//
// Chosen so the document never has to GROW, and the size of it is not a guess: the builder's whole
// capacity stays resident for the life of the connection, because the per-connection arena's
// `free_all` keeps its high-water block. Measured with 500 held keep-alive connections that had each
// rendered the page once: 40 KB of capacity cost 110 KB per connection, 24 KB cost 94 KB. So the
// capacity is paid per connection, once, and it is worth trimming.
//
// The floor is the LARGEST variant, not the default one -- measured identity, this corpus:
// squad 19,917 B, default 20,102 B, **swedish 24,517 B**. Growing inside a bump arena is the worst
// outcome available: the old block is not reused, so a page that outgrows this leaves the whole
// capacity stranded AND commits a doubled one. 32 KB is the largest page plus ~30%.
@(private = "file")
DOCUMENT_CAPACITY :: 32 * 1024

// The `#app` body a fat morph carries. ~23.6 KB measured on the python.
@(private)
APP_BODY_CAPACITY :: 24 * 1024

//
// The answer choreography
//

route_answer :: proc(request: ^http.Request, response: ^http.Response) {
	sse_route_post(request, response, build_answer)
}

// The centre of the app, and the thing the load harness measures.
//
// The order and the pauses below are load-bearing: `apps/datastar-quiz/tools/measure.py` asserts the
// frames ARRIVE at roughly [3, 618, 623, 623, 623] ms, and a server that buffers instead of flushing
// per event collapses the whole sequence into one frame.
@(private = "file")
build_answer :: proc(resolved: Request_Context, request: ^http.Request, stream: ^Stream) {
	s := resolved.session
	arena := request_arena(stream.response)

	if len(request.url_params) < 2 {
		return
	}
	qid, qid_ok := strconv.parse_u64(request.url_params[0])
	index, index_ok := strconv.parse_int(request.url_params[1])
	if !qid_ok || !index_ok {
		return
	}

	// A stale page resyncs rather than scoring. This is the qid nonce doing its job: a double click,
	// a replayed request and a tab left open overnight all land here.
	if is_stale(resolved, qid) {
		push_resync(stream, s)
		return
	}
	// An answer to a finished quiz, or an index that is not on the card, is a no-op -- 204.
	if !session.still_playing(s) || s.awaiting_next {
		return
	}
	if index < 0 || index >= len(s.question.candidates) {
		return
	}

	sync_settings(s, resolved.uploaded)
	percent_left := session.percent_time_left(s)
	chosen := s.question.candidates[index]

	// EVERYTHING is applied here, before a single byte is streamed.
	result, last_points := engine.answer(
		&s.score,
		engine.Answer_Input {
			question = s.question,
			candidate = chosen,
			percent_left = percent_left,
			ladder_mode = s.settings.ladder_mode,
			target_on = s.settings.target_on,
			target_pct = s.settings.target_pct,
			last_correct_points = s.last_correct_points,
			points_goal = s.points_goal,
		},
		store.allocator,
	)
	s.last_correct_points = last_points
	s.skips_left += result.awarded_skips

	if result.completed {
		session.complete(s)
	} else if result.correct {
		session.new_question(s, store.allocator)
	} else {
		// Park on the reveal: the answer is shown in place, and nothing advances until Next.
		s.awaiting_next = true
		s.wrong_index = index
		s.has_wrong_index = true
	}

	// 1. the streak, first and alone, so the chip reacts before anything else
	push_signals(stream, streak_signal(s, arena))

	// 2. clear the sound sink, then 3. the verdict sound BEFORE its toast
	clear_sfx(stream)
	push_elements(stream, render.sfx_beat(result.correct ? "correct" : "wrong", arena), "#sfx", .Append)

	for item in result.toasts {
		push_elements(stream, render.toast(item, arena), "#toasts", .Inner)

		if item.awards_skip {
			push_elements(stream, render.meter_sweep(), "#app .points-meter", .Append)
			push_elements(stream, render.sfx_beat("skip", arena), "#sfx", .Append)
		}
		if item.has_points_after {
			// Against the PER-SESSION goal, not the module constant: the debug panel can shorten a
			// quiz, and the gauge has to agree with the milestones.
			push_signals(stream, points_signal(item.points_after, s.points_goal, arena))
		}
		if floater := render.floater(item, result.completed, arena); floater != "" {
			push_elements(stream, floater, picked_card_selector(index, arena), .Append)
		}
		push_pause(stream, item.pause)
	}

	if result.completed {
		push_elements(stream, render.sfx_beat("final", arena), "#sfx", .Append)
	}
	clear_toasts(stream)

	// The clock starts when the question REACHES the player -- after the toasts have been paced out,
	// not when it was drawn.
	if session.on_the_clock(s) {
		session.start_question_clock(s)
	}
	push_view(stream, s)
}

@(private = "file")
picked_card_selector :: proc(index: int, allocator := context.allocator) -> string {
	return strings.concatenate({"#quiz .candidates > :nth-child(", itoa(index + 1, allocator), ")"}, allocator)
}

//
// The actions that share the view patches
//

route_next :: proc(request: ^http.Request, response: ^http.Response) {
	sse_route_post(request, response, build_next)
}

@(private = "file")
build_next :: proc(resolved: Request_Context, request: ^http.Request, stream: ^Stream) {
	s := resolved.session
	// Next only means something on a reveal. Pressed anywhere else it is a no-op, which is what
	// stops the reveal's Enter handler from racing the button and advancing twice.
	if !s.awaiting_next || !session.still_playing(s) {
		return
	}
	sync_settings(s, resolved.uploaded)
	session.new_question(s, store.allocator)
	clear_toasts(stream)
	push_view(stream, s)
}

route_skip :: proc(request: ^http.Request, response: ^http.Response) {
	sse_route_post(request, response, build_skip)
}

@(private = "file")
build_skip :: proc(resolved: Request_Context, request: ^http.Request, stream: ^Stream) {
	s := resolved.session
	if s.skips_left <= 0 || !session.still_playing(s) {
		return
	}
	sync_settings(s, resolved.uploaded)
	s.skips_left -= 1
	session.new_question(s, store.allocator)
	clear_toasts(stream)
	push_view(stream, s)
}

route_restart :: proc(request: ^http.Request, response: ^http.Response) {
	sse_route_post(request, response, build_restart)
}

@(private = "file")
build_restart :: proc(resolved: Request_Context, request: ^http.Request, stream: ^Stream) {
	s := resolved.session
	sync_settings(s, resolved.uploaded)
	session.restart(s, store.allocator)
	clear_toasts(stream)
	push_view(stream, s)
}

route_settings :: proc(request: ^http.Request, response: ^http.Response) {
	sse_route_post(request, response, build_settings)
}

// A settings post that changed nothing answers 204.
//
// That matters more than it looks: every one of these controls restarts the quiz, and the slider
// fires on every drag step. Without the comparison, moving it and moving it back would throw the
// game away.
@(private = "file")
build_settings :: proc(resolved: Request_Context, request: ^http.Request, stream: ^Stream) {
	s := resolved.session
	if !sync_settings(s, resolved.uploaded) {
		return
	}
	session.restart(s, store.allocator)
	clear_toasts(stream)
	push_view(stream, s)
}

//
// The patches every state-changing route shares
//

// Empty a slot.
//
// The replacements carry the element's own attributes, or the clear would quietly drop `aria-live`
// from the toast slot and `hidden` from the sound sink. `.Outer` rather than an empty `.Inner`
// because an event needs a payload -- see `push_elements`.
EMPTY_TOASTS :: `<div class="toasts" id="toasts" aria-live="polite"></div>`
EMPTY_SFX :: `<div id="sfx" hidden aria-hidden="true"></div>`
EMPTY_TOPICS_STATUS :: `<div id="topics-status" class="filter-status"></div>`

@(private)
clear_toasts :: proc(stream: ^Stream) {
	push_elements(stream, EMPTY_TOASTS, "#toasts", .Outer)
}

@(private)
clear_sfx :: proc(stream: ^Stream) {
	push_elements(stream, EMPTY_SFX, "#sfx", .Outer)
}

@(private)
clear_topics_status :: proc(stream: ^Stream) {
	push_elements(stream, EMPTY_TOPICS_STATUS, "#topics-status", .Outer)
}

// The standard pair every state-changing route ends with: the whole `#app` body, then the whole
// signal set.
//
// FAT MORPH -- `#app` entire rather than the handful of elements that changed. It costs ~3.4 KB more
// per interaction and the repetitive markup compresses well; what it buys is one description of what
// the page looks like in a given state instead of six that drift.
@(private)
push_view :: proc(stream: ^Stream, s: ^session.Session) {
	arena := request_arena(stream.response)
	body := strings.builder_make(0, APP_BODY_CAPACITY, arena)
	render.write_app_body(&body, render_context_for(s), s, filter_status_for(s, arena))
	push_elements(stream, strings.to_string(body), "#app", .Inner)
	push_signals(stream, render.view_signals(s, arena))
}

// A session whose page has fallen behind gets the same fat patch plus a warning, so a stale tab
// catches up rather than silently doing nothing.
@(private)
push_resync :: proc(stream: ^Stream, s: ^session.Session) {
	push_view(stream, s)
	push_elements(
		stream,
		`<div class="toast warning notification is-warning">Quiz reloaded — this page has caught up</div>`,
		"#toasts",
		.Inner,
	)
}

//
// Small helpers
//

@(private)
render_context_for :: proc(s: ^session.Session) -> render.Context {
	out := render_context()
	out.choices = choices_for(s.system)
	return out
}

@(private)
filter_status_for :: proc(s: ^session.Session, allocator := context.allocator) -> string {
	check := corpus_check(s)
	return render.filter_status(
		status_text_of(check),
		len(check.hits),
		check.parsed.errors,
		len(check.parsed.entries),
		check.parsed.canonical_text,
		s.filter_text,
		"",
		engine.MAX_DIFFICULTY,
		allocator,
	)
}

@(private = "file")
streak_signal :: proc(s: ^session.Session, allocator := context.allocator) -> string {
	return strings.concatenate({`{"_streak":`, itoa(s.score.streak, allocator), "}"}, allocator)
}

@(private = "file")
points_signal :: proc(points, goal: int, allocator := context.allocator) -> string {
	return strings.concatenate(
		{
			`{"_points":`,
			itoa(points, allocator),
			`,"_pointsPct":`,
			itoa(render.points_percent(points, goal), allocator),
			"}",
		},
		allocator,
	)
}

// Digits, in the caller's memory.
//
// The allocator is explicit and never defaulted, because inside an odin-http handler
// `context.allocator` is the THREAD's, not the connection's -- so a defaulted one here would leak a
// 24-byte block per interaction into an allocator nothing frees. Every caller hands the result
// straight to `strings.concatenate`, which copies it.
@(private)
itoa :: proc(value: int, allocator := context.allocator) -> string {
	buffer := make([]byte, 24, allocator)
	return strconv.write_int(buffer, i64(value), 10)
}
