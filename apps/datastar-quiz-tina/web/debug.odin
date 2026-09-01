// The debug panel, the held countdown, and the sounds.
//
// Every `/debug/*` route answers 204 unless the session is armed, which happens only by loading the
// page with `?debug`. That is not access control -- there is nothing here worth protecting -- it is
// so that a stray request from a bookmarked url cannot quietly move a player's score.
package web

import "../engine"
import "../render"
import "../session"
import "../sfx"
import "core:mem"
import "core:strconv"
import "core:strings"
import tina "tina:src"
import datastar "tina:src/extensions/http/datastar"
import http "tina:src/extensions/http/server"

// The shared event-route body, exported for the filter routes to reuse.
//
// It was its own copy of the request/build/run dance until the session moved into an isolate -- at
// which point one copy of acquire/build/release is the only tolerable number, so this is now a name
// for `dispatch`.
@(private)
event_route :: proc(
	event: http.Route_Event,
	request: ^http.Request,
	response: ^http.Response,
	route_context: http.Route_Context,
	raw_state: rawptr,
	build: Builder,
) -> http.Route_Step {
	return dispatch(event, request, response, route_context, raw_state, build)
}

route_debug_points :: proc(
	event: http.Route_Event,
	request: ^http.Request,
	response: ^http.Response,
	route_context: http.Route_Context,
	raw_state: rawptr,
) -> http.Route_Step {
	return event_route(event, request, response, route_context, raw_state, build_debug_points)
}

@(private = "file")
build_debug_points :: proc(resolved: Request_Context, request: ^http.Request, state: ^Stream_State) {
	s := resolved.session
	if !s.debug {
		return
	}
	delta, ok := strconv.parse_int(string(http.param(request, "delta")))
	if !ok {
		return
	}
	s.score.total_points = max(s.score.total_points + delta, 0)
	push_view(state, s)
}

route_debug_goal :: proc(
	event: http.Route_Event,
	request: ^http.Request,
	response: ^http.Response,
	route_context: http.Route_Context,
	raw_state: rawptr,
) -> http.Route_Step {
	return event_route(event, request, response, route_context, raw_state, build_debug_goal)
}

// A per-session goal, so a short quiz can be played through without a global mutation. Clamped
// because the goal decides both completion and where the skip milestones fall.
@(private = "file")
build_debug_goal :: proc(resolved: Request_Context, request: ^http.Request, state: ^Stream_State) {
	s := resolved.session
	if !s.debug {
		return
	}
	value, ok := strconv.parse_int(string(http.param(request, "value")))
	if !ok {
		return
	}
	s.points_goal = clamp(value, 10, 100_000)
	push_view(state, s)
}

// Park on a reveal with a synthetic wrong answer, to look at the reveal without playing to one.
route_debug_reveal :: proc(
	event: http.Route_Event,
	request: ^http.Request,
	response: ^http.Response,
	route_context: http.Route_Context,
	raw_state: rawptr,
) -> http.Route_Step {
	return event_route(event, request, response, route_context, raw_state, build_debug_reveal)
}

@(private = "file")
build_debug_reveal :: proc(resolved: Request_Context, request: ^http.Request, state: ^Stream_State) {
	s := resolved.session
	if !s.debug || len(s.question.candidates) == 0 {
		return
	}
	correct, _ := engine.answer_index(s.question)
	s.awaiting_next = true
	s.has_wrong_index = true
	s.wrong_index = correct == 0 ? min(1, len(s.question.candidates) - 1) : 0
	push_view(state, s)
}

// Finish the quiz through the REAL scoring path rather than by setting a flag, so the finale is
// reached the same way a player reaches it.
route_debug_complete :: proc(
	event: http.Route_Event,
	request: ^http.Request,
	response: ^http.Response,
	route_context: http.Route_Context,
	raw_state: rawptr,
) -> http.Route_Step {
	return event_route(event, request, response, route_context, raw_state, build_debug_complete)
}

@(private = "file")
build_debug_complete :: proc(resolved: Request_Context, request: ^http.Request, state: ^Stream_State) {
	s := resolved.session
	if !s.debug || len(s.question.candidates) == 0 {
		return
	}
	s.score.total_points = max(s.points_goal - 1, 0)
	result, last := engine.answer(
		&s.score,
		engine.Answer_Input {
			question = s.question,
			candidate = s.question.answer_candidate,
			percent_left = 0,
			ladder_mode = s.settings.ladder_mode,
			target_on = false,
			target_pct = s.settings.target_pct,
			last_correct_points = s.last_correct_points,
			points_goal = s.points_goal,
		},
		session.store_allocator(),
	)
	s.last_correct_points = last
	s.skips_left += result.awarded_skips
	if result.completed {
		session.complete(s)
	}
	push_view(state, s)
}

//
// The held countdown
//

// What a `/timer` stream is holding between ticks.
//
// The sid is COPIED rather than pointed at: this state outlives its request by up to ten minutes,
// and it is the only thing the store needs to find the session again.
Timer_State :: struct {
	sid:          [session.SID_LENGTH]u8,
	variant_slot: u8,
	elapsed:      u64,
	started:      bool,
	// What this stream is parked on. The timer's own tick and the store's answer both arrive as
	// `Application_Reply`, so the state has to say which is expected.
	waiting:      Timer_Wait,
}

Timer_Wait :: enum u8 {
	None,
	// Parked on the timer wheel, between ticks.
	Tick,
	// Parked on the store, waiting for the one number this route pushes.
	Peek,
}

// 100 ms a tick, for up to ten minutes.
@(private = "file")
TIMER_INTERVAL_NS :: u64(100_000_000)
@(private = "file")
TIMER_MAX_NS :: u64(600) * 1_000_000_000

// The one thing the python could not ship.
//
// In `client` mode the browser walks the bar down on its own interval and this route answers 204. In
// `stream` mode the server pushes `_timeLeftPct` instead, which needs a connection held open per
// player for the length of a quiz -- 400 users was 600 goroutines in Go and never ran at all under
// python's single loop. Here it is one isolate per connection, parked on the timer wheel between
// ticks, which is the shape Tina is actually for.
//
// It never takes a LEASE. Ten peeks a second per open tab would hold the busiest sessions in the
// process for a read of one integer, so the store computes that integer itself and sends it
// (`TAG_PEEK_TIME`). The session is looked up per tick rather than held for the same reason
// it always was: it may have been restarted, swept or replaced under the stream.
route_timer :: proc(
	event: http.Route_Event,
	request: ^http.Request,
	response: ^http.Response,
	route_context: http.Route_Context,
	raw_state: rawptr,
) -> http.Route_Step {
	state := cast(^Timer_State)raw_state

	switch ev in event {
	case http.Request_Start:
		if config.timer_mode != "stream" {
			return http.respond_text(response, http.HTTP_STATUS_NO_CONTENT, "")
		}
		read := read_request(request, allocator = context.temp_allocator)
		state^ = Timer_State {
			variant_slot = u8(max(read.variant_slot, 0)),
		}
		copy(state.sid[:], read.sid)
		set_session_cookie(response, read.sid)
		if left, found := peek_here(state); found {
			return start_countdown(response, state, left)
		}
		return peek_time(route_context, state)

	case http.Send_Ready:
		if !state.started || state.elapsed >= TIMER_MAX_NS {
			return http.close()
		}
		state.waiting = .Tick
		return http.expect_notification(route_context, TIMER_INTERVAL_NS, tina.ISOLATE_HANDLE_NONE, PAUSE_TAG)

	case http.Application_Reply:
		switch state.waiting {
		case .Tick:
			if ev.reply_result != .Timeout {
				return http.close()
			}
			state.elapsed += TIMER_INTERVAL_NS
			if left, found := peek_here(state); found {
				return start_countdown(response, state, left)
			}
			return peek_time(route_context, state)

		case .Peek:
			state.waiting = .None
			if ev.reply_result == .Timeout || ev.message_tag != TAG_PEEK_TIME {
				return http.close()
			}
			if len(ev.payload_bytes) < size_of(session.Peek_Time_Reply) {
				return http.close()
			}
			answer := (cast(^session.Peek_Time_Reply)raw_data(ev.payload_bytes))^
			if !answer.found {
				return http.close()
			}

			return start_countdown(response, state, int(answer.percent_left))

		case .None:
			return http.close()
		}
		return http.close()

	case http.Body_Chunk, http.Application_Notification, http.Peer_Closed, http.Server_Drain:
		return http.close()
	}
	return http.close()
}

// The countdown's one number, when the store is on this thread. See `web/store_isolate.odin` for
// why one shard does not go through a mailbox to read an integer it already owns.
@(private = "file")
peek_here :: proc(state: ^Timer_State) -> (percent_left: int, found: bool) {
	if local_store == nil {
		return 0, false
	}
	answer := session.peek_time(
		local_store,
		session.Peek_Time_Request{sid = state.sid, variant_slot = state.variant_slot},
	)
	return int(answer.percent_left), answer.found
}

// Push one tick. Opens the stream on the first, resumes it after that.
@(private = "file")
start_countdown :: proc(response: ^http.Response, state: ^Timer_State, percent_left: int) -> http.Route_Step {
	if !state.started {
		generator, start_error := datastar.start_sse(response)
		if start_error != .None {
			return http.close()
		}
		if datastar.patch_signals(&generator, time_left_signal(percent_left)) != .None {
			return http.close()
		}
		state.started = true
		return http.flush()
	}

	sse := datastar.resume(response)
	if datastar.patch_signals(&sse, time_left_signal(percent_left)) != .None {
		return http.close()
	}
	return http.flush()
}

// Ask the store for this session's remaining time and park until it answers.
@(private = "file")
peek_time :: proc(route_context: http.Route_Context, state: ^Timer_State) -> http.Route_Step {
	handle := store_handle()
	if handle == tina.ISOLATE_HANDLE_NONE {
		return http.close()
	}
	request := session.Peek_Time_Request {
		sid          = state.sid,
		variant_slot = state.variant_slot,
	}
	if http.expect_reply(
		   route_context,
		   handle,
		   TAG_PEEK_TIME,
		   mem.byte_slice(&request, size_of(request)),
		   STORE_TIMEOUT_NS,
	   ) !=
	   .ok {
		return http.close()
	}
	state.waiting = .Peek
	return http.Route_Step.Expect_Application
}

@(private = "file")
time_left_signal :: proc(percent_left: int) -> string {
	return strings.concatenate({`{"_timeLeftPct":`, itoa(percent_left), "}"}, response_arena())
}

//
// The sounds
//

// Served from memory with a one-year immutable cache; the `?v=` build stamp on the page's `<audio>`
// elements is what busts it when a synth changes.
route_sfx :: proc(
	event: http.Route_Event,
	request: ^http.Request,
	response: ^http.Response,
	route_context: http.Route_Context,
	raw_state: rawptr,
) -> http.Route_Step {
	state := cast(^Asset_Stream)raw_state

	switch _ in event {
	case http.Request_Start:
		state^ = Asset_Stream{}
		sound, ok := sfx.find(string(http.param(request, "name")))
		if !ok {
			return http.respond_text(response, http.HTTP_STATUS_NOT_FOUND, "not found")
		}
		state.asset = &SFX_ASSET
		// A WAV of sine waves compresses poorly and these are ~4-8 KB each, so they go out as they
		// are -- `body` is what `pump_asset` sends, and it has to agree with the declared length.
		state.body = sound.bytes

		if http.header_set(response, "Cache-Control", "max-age=31536000, public") != .Staged {
			return http.close()
		}
		if http.begin_fixed_stream(response, http.HTTP_STATUS_OK, "audio/wav", u64(len(sound.bytes))) != .Begun {
			return http.close()
		}
		return pump_asset(response, state)

	case http.Send_Ready:
		if state.asset == nil {
			return http.close()
		}
		return pump_asset(response, state)

	case http.Body_Chunk, http.Application_Reply, http.Application_Notification, http.Peer_Closed, http.Server_Drain:
		return http.close()
	}
	return http.close()
}

// One shard, one request at a time, so a single scratch descriptor serves every sound request.
@(private = "file")
SFX_ASSET := Asset {
	name          = "sfx",
	content_type  = "audio/wav",
	cache_control = "max-age=31536000, public",
}

_ :: render
