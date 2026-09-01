// The debug panel, the held countdown, and the sounds.
//
// Every `/debug/*` route answers 204 unless the session is armed, which happens only by loading the
// page with `?debug`. That is not access control -- there is nothing here worth protecting -- it is
// so that a stray request from a bookmarked url cannot quietly move a player's score.
package web

import "../engine"
import "../session"
import "../sfx"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import http "odinhttp:."

route_debug_points :: proc(request: ^http.Request, response: ^http.Response) {
	sse_route_post(request, response, build_debug_points)
}

@(private = "file")
build_debug_points :: proc(resolved: Request_Context, request: ^http.Request, stream: ^Stream) {
	s := resolved.session
	if !s.debug || len(request.url_params) < 1 {
		return
	}
	delta, ok := strconv.parse_int(request.url_params[0])
	if !ok {
		return
	}
	s.score.total_points = max(s.score.total_points + delta, 0)
	push_view(stream, s)
}

route_debug_goal :: proc(request: ^http.Request, response: ^http.Response) {
	sse_route_post(request, response, build_debug_goal)
}

// A per-session goal, so a short quiz can be played through without a global mutation. Clamped
// because the goal decides both completion and where the skip milestones fall.
@(private = "file")
build_debug_goal :: proc(resolved: Request_Context, request: ^http.Request, stream: ^Stream) {
	s := resolved.session
	if !s.debug || len(request.url_params) < 1 {
		return
	}
	value, ok := strconv.parse_int(request.url_params[0])
	if !ok {
		return
	}
	s.points_goal = clamp(value, 10, 100_000)
	push_view(stream, s)
}

// Park on a reveal with a synthetic wrong answer, to look at the reveal without playing to one.
route_debug_reveal :: proc(request: ^http.Request, response: ^http.Response) {
	sse_route_post(request, response, build_debug_reveal)
}

@(private = "file")
build_debug_reveal :: proc(resolved: Request_Context, request: ^http.Request, stream: ^Stream) {
	s := resolved.session
	if !s.debug || len(s.question.candidates) == 0 {
		return
	}
	correct, _ := engine.answer_index(s.question)
	s.awaiting_next = true
	s.has_wrong_index = true
	s.wrong_index = correct == 0 ? min(1, len(s.question.candidates) - 1) : 0
	push_view(stream, s)
}

// Finish the quiz through the REAL scoring path rather than by setting a flag, so the finale is
// reached the same way a player reaches it.
route_debug_complete :: proc(request: ^http.Request, response: ^http.Response) {
	sse_route_post(request, response, build_debug_complete)
}

@(private = "file")
build_debug_complete :: proc(resolved: Request_Context, request: ^http.Request, stream: ^Stream) {
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
		store.allocator,
	)
	s.last_correct_points = last
	s.skips_left += result.awarded_skips
	if result.completed {
		session.complete(s)
	}
	push_view(stream, s)
}

//
// The held countdown
//

// What a `/timer` stream is holding between ticks. Reached through `Stream.user`.
@(private = "file")
Timer_State :: struct {
	stream:  ^Stream,
	sid:     string,
	variant: string,
	elapsed: time.Duration,
}

// 100 ms a tick, for up to ten minutes.
@(private = "file")
TIMER_INTERVAL :: 100 * time.Millisecond
@(private = "file")
TIMER_MAX :: 600 * time.Second

// The one thing the python could not ship.
//
// In `client` mode the browser walks the bar down on its own interval and this route answers 204. In
// `stream` mode the server pushes `_timeLeftPct` instead, which needs a connection held open per
// player for the length of a quiz -- 400 users was 600 goroutines in Go and never ran at all under
// python's single loop. Here it is one connection, one arena and a repeating `nbio.timeout`: the
// held stream is the same `Stream` every other route uses, with a `refill` that pushes the next tick
// instead of ending.
route_timer :: proc(request: ^http.Request, response: ^http.Response) {
	if config.timer_mode != "stream" {
		http.respond(response, http.Status.No_Content)
		return
	}

	arena := request_arena(response)

	sync.lock(&store_lock)
	resolved := resolve_request(request, response, "")
	set_session_cookie(response, resolved.sid)
	first := time_left_signal(resolved.session, arena)
	sync.unlock(&store_lock)

	state := new(Timer_State, arena)
	state.sid = strings.clone(resolved.sid, arena)
	state.variant = strings.clone(resolved.system.key, arena)

	stream := new(Stream, arena)
	stream_init(stream, response)
	state.stream = stream
	stream.user = state
	stream.refill = timer_refill

	push_signals(stream, first)
	push_pause(stream, time.duration_seconds(TIMER_INTERVAL))
	stream_run(stream)
}

// One more tick, or false to close.
//
// The session is looked up per tick rather than held: it may have been restarted, swept or replaced
// under the stream, and a pointer captured at connect time would outlive it.
@(private = "file")
timer_refill :: proc(stream: ^Stream) -> bool {
	state := cast(^Timer_State)stream.user
	state.elapsed += TIMER_INTERVAL
	if state.elapsed >= TIMER_MAX {
		return false
	}

	arena := request_arena(stream.response)
	sync.lock(&store_lock)
	found, ok := session.store_get(&store, session.Key{sid = state.sid, variant = state.variant})
	signal := ok ? time_left_signal(found, arena) : ""
	sync.unlock(&store_lock)
	if !ok {
		return false
	}

	script_reset(stream)
	push_signals(stream, signal)
	push_pause(stream, time.duration_seconds(TIMER_INTERVAL))
	return true
}

@(private = "file")
time_left_signal :: proc(s: ^session.Session, allocator := context.allocator) -> string {
	left := session.still_playing(s) ? session.percent_time_left(s) : 0
	return strings.concatenate({`{"_timeLeftPct":`, itoa(left, allocator), "}"}, allocator)
}

//
// The sounds
//

// Served from memory with a one-year immutable cache; the `?v=` build stamp on the page's `<audio>`
// elements is what busts it when a synth changes.
//
// A WAV of sine waves compresses poorly and these are ~4-8 KB each, so they go out as they are.
route_sfx :: proc(request: ^http.Request, response: ^http.Response) {
	name := len(request.url_params) > 0 ? request.url_params[0] : ""
	sound, ok := sfx.find(name)
	if !ok {
		http.respond_plain(response, "not found", .Not_Found)
		return
	}
	http.headers_set_unsafe(&response.headers, "cache-control", "max-age=31536000, public")
	http.headers_set_unsafe(&response.headers, "content-type", "audio/wav")
	response.status = .OK
	http.body_set(response, sound.bytes)
	http.respond(response)
}
