// The routes.
//
// Every one of them is an EVENT route, even the ones that never pause. Two reasons: a Datastar
// response is a stream, so it needs `Send_Ready` to finish writing when the buffer backs up; and the
// multi-shard step turns every session touch into a suspend and a resume, which only an event route
// can do. Writing them all this shape now is what keeps that phase from being a rewrite.
//
// The pattern is the same throughout: `Request_Start` mutates the session and BUILDS the script,
// then every later event just keeps running it. State is fully mutated before the first byte, so a
// mid-stream reload sees final state rather than a half-scored session.
package web

import "../engine"
import "../render"
import "../session"
import "core:strconv"
import "core:strings"
import datastar "tina:src/extensions/http/datastar"
import http "tina:src/extensions/http/server"

// What a route does when the request arrives. Fills the script; the shared dispatcher runs it.
@(private)
Builder :: #type proc(resolved: Request_Context, request: ^http.Request, state: ^Stream_State)

// The shared body of every SSE route -- the filter and debug routes come through here too.
@(private)
dispatch :: proc(
	event: http.Route_Event,
	request: ^http.Request,
	response: ^http.Response,
	route_context: http.Route_Context,
	raw_state: rawptr,
	build: Builder,
) -> http.Route_Step {
	state := cast(^Stream_State)raw_state

	switch ev in event {
	case http.Request_Start:
		response_arena_begin(state)
		script_reset(state)
		// Read the request, then get the session. Everything the build needs is either in
		// `state.read` or re-readable from the request frame afterwards, because the frame survives
		// a park.
		state.read = read_request(request, allocator = response_arena())
		state.switching = false
		if resolved, ready := acquire_here(state); ready {
			// One shard: the store is on this thread and the answer is already in hand.
			return build_and_run(resolved, request, response, route_context, state, build)
		}
		return acquire_session(route_context, state)

	case http.Send_Ready:
		response_arena_resume(state)
		return resume_after_flush(route_context, state)

	case http.Application_Reply:
		response_arena_resume(state)
		switch state.pending {
		case .Session:
			resolved, ready := session_from_reply(ev, route_context, state)
			if !ready {
				// The store never answered -- it is gone, or its queue is full. Either way this
				// request has nothing to build from.
				return pending_step(state, response)
			}
			return build_and_run(resolved, request, response, route_context, state, build)
		case .Pause:
			return run_script(response, route_context, state)
		case .None:
			return http.close()
		}
		return http.close()

	case http.Body_Chunk, http.Application_Notification, http.Peer_Closed, http.Server_Drain:
		release_session(state)
		return http.close()
	}
	release_session(state)
	return http.close()
}

// Build the response and start running it. The same body whichever way the session arrived -- from
// the store on this thread, or from the store isolate on another.
@(private)
build_and_run :: proc(
	resolved: Request_Context,
	request: ^http.Request,
	response: ^http.Response,
	route_context: http.Route_Context,
	state: ^Stream_State,
	build: Builder,
) -> http.Route_Step {
	set_session_cookie(response, resolved.sid)
	build(resolved, request, state)
	// The mutation is done and the response is built out of the arena, so the session goes back NOW
	// rather than when the stream finishes: the pauses that follow are the player's, not the store's.
	release_session(state)
	return run_script(response, route_context, state)
}

//
// The page
//

route_index :: proc(
	event: http.Route_Event,
	request: ^http.Request,
	response: ^http.Response,
	route_context: http.Route_Context,
	raw_state: rawptr,
) -> http.Route_Step {
	state := cast(^Stream_State)raw_state

	switch ev in event {
	case http.Request_Start:
		response_arena_begin(state)
		script_reset(state)
		// The index page is the one route that uses the SWITCHING variant rule: a bare url means
		// "back to the default variant", a query naming no variant means "keep what you have".
		state.read = read_request(request, switching = true, allocator = response_arena())
		state.switching = true
		if resolved, ready := acquire_here(state); ready {
			return begin_page(resolved, request, response, state)
		}
		return acquire_session(route_context, state)

	case http.Application_Reply:
		response_arena_resume(state)
		if state.pending != .Session {
			return http.close()
		}
		resolved, ready := session_from_reply(ev, route_context, state)
		if !ready {
			return pending_step(state, response)
		}
		return begin_page(resolved, request, response, state)

	case http.Send_Ready:
		response_arena_resume(state)
		return pump_document(response, state)

	case http.Body_Chunk, http.Application_Notification, http.Peer_Closed, http.Server_Drain:
		release_session(state)
		return http.close()
	}
	release_session(state)
	return http.close()
}

// Render the page and start streaming it. As with `build_and_run`, one body for both ways the
// session can arrive.
@(private = "file")
begin_page :: proc(
	resolved: Request_Context,
	request: ^http.Request,
	response: ^http.Response,
	state: ^Stream_State,
) -> http.Route_Step {
	set_session_cookie(response, resolved.sid)

	// `?debug` arms the debug panel for this session, and it stays armed until the session is
	// swept -- so the panel survives the interactions that patch the page.
	if strings.contains(string(http.query(request)), "debug") {
		resolved.session.debug = true
	}

	document := strings.builder_make(0, DOCUMENT_CAPACITY, response_arena())
	render.write_shell(
		&document,
		render_context_for(resolved.session),
		resolved.session,
		read_theme(request),
		filter_status_for(resolved.session),
	)
	// Rendered, so the session goes back before a byte is written: the document is bytes in this
	// response's arena from here on, and holding the lease through the write would hold it for the
	// length of a download.
	release_session(state)

	// `no-store`, not `no-cache`: the page IS the session state, and a back-button restore of a
	// finished quiz showing a live question is worse than a refetch.
	return begin_document(
		response,
		request,
		state,
		strings.to_string(document),
		"text/html; charset=utf-8",
		"no-store",
	)
}

//
// The answer choreography
//

route_answer :: proc(
	event: http.Route_Event,
	request: ^http.Request,
	response: ^http.Response,
	route_context: http.Route_Context,
	raw_state: rawptr,
) -> http.Route_Step {
	return dispatch(event, request, response, route_context, raw_state, build_answer)
}

// The centre of the app, and the thing the load harness measures.
//
// The order and the pauses below are load-bearing: `apps/datastar-quiz/tools/measure.py` asserts the
// frames ARRIVE at roughly [3, 618, 623, 623, 623] ms, and a compressor that buffers instead of
// flushing per event collapses the whole sequence into one frame.
@(private = "file")
build_answer :: proc(resolved: Request_Context, request: ^http.Request, state: ^Stream_State) {
	s := resolved.session

	qid, qid_ok := strconv.parse_u64(string(http.param(request, "qid")))
	index, index_ok := strconv.parse_int(string(http.param(request, "index")))
	if !qid_ok || !index_ok {
		return
	}

	// A stale page resyncs rather than scoring. This is the qid nonce doing its job: a double click,
	// a replayed request and a tab left open overnight all land here.
	if is_stale(resolved, qid) {
		push_resync(state, s)
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
		session.store_allocator(),
	)
	s.last_correct_points = last_points
	s.skips_left += result.awarded_skips

	if result.completed {
		session.complete(s)
	} else if result.correct {
		session.new_question(s, session.store_allocator())
	} else {
		// Park on the reveal: the answer is shown in place, and nothing advances until Next.
		s.awaiting_next = true
		s.wrong_index = index
		s.has_wrong_index = true
	}

	// 1. the streak, first and alone, so the chip reacts before anything else
	push_signals(state, streak_signal(s))

	// 2. clear the sound sink, then 3. the verdict sound BEFORE its toast
	clear_sfx(state)
	push_elements(state, render.sfx_beat(result.correct ? "correct" : "wrong", response_arena()), "#sfx", .Append)

	for item, position in result.toasts {
		push_elements(state, render.toast(item, response_arena()), "#toasts", .Inner)

		if item.awards_skip {
			push_elements(state, render.meter_sweep(), "#app .points-meter", .Append)
			push_elements(state, render.sfx_beat("skip", response_arena()), "#sfx", .Append)
		}
		if item.has_points_after {
			// Against the PER-SESSION goal, not the module constant: the debug panel can shorten a
			// quiz, and the gauge has to agree with the milestones.
			push_signals(state, points_signal(item.points_after, s.points_goal))
		}
		if floater := render.floater(item, result.completed, response_arena()); floater != "" {
			push_elements(state, floater, picked_card_selector(index), .Append)
		}
		_ = position
		push_pause(state, item.pause)
	}

	if result.completed {
		push_elements(state, render.sfx_beat("final", response_arena()), "#sfx", .Append)
	}
	clear_toasts(state)

	// The clock starts when the question REACHES the player -- after the toasts have been paced out,
	// not when it was drawn.
	if session.on_the_clock(s) {
		session.start_question_clock(s)
	}
	push_view(state, s)
}

@(private = "file")
picked_card_selector :: proc(index: int) -> string {
	return strings.concatenate({"#quiz .candidates > :nth-child(", itoa(index + 1), ")"}, response_arena())
}

//
// The actions that share the view patches
//

route_next :: proc(
	event: http.Route_Event,
	request: ^http.Request,
	response: ^http.Response,
	route_context: http.Route_Context,
	raw_state: rawptr,
) -> http.Route_Step {
	return dispatch(event, request, response, route_context, raw_state, build_next)
}

@(private = "file")
build_next :: proc(resolved: Request_Context, request: ^http.Request, state: ^Stream_State) {
	s := resolved.session
	// Next only means something on a reveal. Pressed anywhere else it is a no-op, which is what
	// stops the reveal's Enter handler from racing the button and advancing twice.
	if !s.awaiting_next || !session.still_playing(s) {
		return
	}
	sync_settings(s, resolved.uploaded)
	session.new_question(s, session.store_allocator())
	clear_toasts(state)
	push_view(state, s)
}

route_skip :: proc(
	event: http.Route_Event,
	request: ^http.Request,
	response: ^http.Response,
	route_context: http.Route_Context,
	raw_state: rawptr,
) -> http.Route_Step {
	return dispatch(event, request, response, route_context, raw_state, build_skip)
}

@(private = "file")
build_skip :: proc(resolved: Request_Context, request: ^http.Request, state: ^Stream_State) {
	s := resolved.session
	if s.skips_left <= 0 || !session.still_playing(s) {
		return
	}
	sync_settings(s, resolved.uploaded)
	s.skips_left -= 1
	session.new_question(s, session.store_allocator())
	clear_toasts(state)
	push_view(state, s)
}

route_restart :: proc(
	event: http.Route_Event,
	request: ^http.Request,
	response: ^http.Response,
	route_context: http.Route_Context,
	raw_state: rawptr,
) -> http.Route_Step {
	return dispatch(event, request, response, route_context, raw_state, build_restart)
}

@(private = "file")
build_restart :: proc(resolved: Request_Context, request: ^http.Request, state: ^Stream_State) {
	s := resolved.session
	sync_settings(s, resolved.uploaded)
	session.restart(s, session.store_allocator())
	clear_toasts(state)
	push_view(state, s)
}

route_settings :: proc(
	event: http.Route_Event,
	request: ^http.Request,
	response: ^http.Response,
	route_context: http.Route_Context,
	raw_state: rawptr,
) -> http.Route_Step {
	return dispatch(event, request, response, route_context, raw_state, build_settings)
}

// A settings post that changed nothing answers 204.
//
// That matters more than it looks: every one of these controls restarts the quiz, and the slider
// fires on every drag step. Without the comparison, moving it and moving it back would throw the
// game away.
@(private = "file")
build_settings :: proc(resolved: Request_Context, request: ^http.Request, state: ^Stream_State) {
	s := resolved.session
	if !sync_settings(s, resolved.uploaded) {
		return
	}
	session.restart(s, session.store_allocator())
	clear_toasts(state)
	push_view(state, s)
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
filter_status_for :: proc(s: ^session.Session) -> string {
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
		response_arena(),
	)
}

@(private = "file")
streak_signal :: proc(s: ^session.Session) -> string {
	return strings.concatenate({`{"_streak":`, itoa(s.score.streak), "}"}, response_arena())
}

@(private = "file")
points_signal :: proc(points, goal: int) -> string {
	return strings.concatenate(
		{`{"_points":`, itoa(points), `,"_pointsPct":`, itoa(render.points_percent(points, goal)), "}"},
		response_arena(),
	)
}

// Scratch, deliberately: every caller hands the result straight to `strings.concatenate`, which
// copies it into the response arena. Allocating the digits there too would waste the budget that the
// u16 route-state cap makes tight.
@(private)
itoa :: proc(value: int) -> string {
	out := strings.builder_make(0, 24, context.temp_allocator)
	strings.write_int(&out, value)
	return strings.to_string(out)
}

_ :: datastar
