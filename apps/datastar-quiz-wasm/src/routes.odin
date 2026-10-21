// The routes, as the tina port's `web/` has them, minus the HTTP.
//
// Each builder is the server's, step for step: it mutates the session ONCE and then describes what
// the page should see as a script of patches and pauses. The order and the pauses are load-bearing in
// exactly the same way (`apps/datastar-quiz/tools/measure.py` pins them against the python), so they
// are kept rather than tidied. What changed is only where the request comes from and where the
// script goes: a string from `host.js` in, the Datastar wire format out.
package main

import "base:runtime"
import "core:strconv"
import "core:strings"
import "quiz:corpus"
import "quiz:engine"
import "quiz:render"
import "quiz:session"

Request :: struct {
	method: string,
	path:   string, // after PREFIX
	query:  string, // without the `?`
	cookie: string,
	body:   string, // a POST's JSON signals; a GET carries them in `?datastar=`
}

// The signals the page uploads. See the tina port's `web/request.odin`.
Uploaded_Signals :: struct {
	difficulty: Maybe(f64) `json:"difficulty"`,
	ladderMode: Maybe(bool) `json:"ladderMode"`,
	targetOn:   Maybe(bool) `json:"targetOn"`,
	targetPct:  Maybe(f64) `json:"targetPct"`,
	filterText: Maybe(string) `json:"filterText"`,
}

// A request, resolved against the session it is about.
Resolved :: struct {
	request:  Request,
	session:  ^session.Session,
	uploaded: Uploaded_Signals,
	payload:  string, // the raw signal JSON, for the topic scan
}

// The variant the last page was showing: a query naming no variant keeps it.
current_slot := -1

handle :: proc(request: Request, out: ^strings.Builder) {
	path := request.path

	if path == "/" || path == "" {
		route_index(request, out)
		return
	}

	resolved, ok := resolve(request, switching = false)
	if !ok {
		write_no_content(out)
		return
	}
	script := Script{}

	switch {
	case strings.has_prefix(path, "/answer/"):
		build_answer(&resolved, &script, path[len("/answer/"):])
	case path == "/next":
		build_next(&resolved, &script)
	case path == "/skip":
		build_skip(&resolved, &script)
	case path == "/restart":
		build_restart(&resolved, &script)
	case path == "/settings":
		build_settings(&resolved, &script)
	case path == "/filter/preview":
		build_filter_preview(&resolved, &script)
	case path == "/filter/preview-topics":
		build_topics_preview(&resolved, &script)
	case path == "/filter/topics-reset":
		build_topics_reset(&resolved, &script)
	case path == "/filter/apply":
		build_filter_apply(&resolved, &script)
	case path == "/filter/apply-topics":
		build_topics_apply(&resolved, &script)
	case strings.has_prefix(path, "/debug/points/"):
		build_debug_points(&resolved, &script, path[len("/debug/points/"):])
	case strings.has_prefix(path, "/debug/goal/"):
		build_debug_goal(&resolved, &script, path[len("/debug/goal/"):])
	case path == "/debug/reveal":
		build_debug_reveal(&resolved, &script)
	case path == "/debug/complete":
		build_debug_complete(&resolved, &script)
	}
	write_script(out, &script)
}

//
// Resolving a request
//

// The variant, the session, and what the page uploaded.
//
// `switching` is the index page's rule: a bare url means the default variant, a query naming none
// (`?debug`) means the one already showing. Everywhere else only an explicit variant switches.
resolve :: proc(request: Request, switching: bool) -> (resolved: Resolved, ok: bool) {
	system: ^corpus.System
	found: bool
	if switching {
		system, found = corpus.variant_switch_for_query(loaded_corpus, request.query)
	} else {
		system, found = corpus.requested_variant(loaded_corpus, request.query)
	}
	if !found {
		if current_slot >= 0 {
			system = &loaded_corpus.systems[current_slot]
		} else {
			system = corpus.default_system(loaded_corpus)
		}
	}
	slot := session.slot_for_system(system)
	if slot < 0 {
		return {}, false
	}
	current_slot = slot

	resolved.request = request
	resolved.payload = request.body
	if resolved.payload == "" {
		resolved.payload = query_value(request.query, "datastar")
	}
	has_signals := resolved.payload != "" && read_signals(resolved.payload, &resolved.uploaded)

	if sessions[slot] == nil {
		// A new session adopts the settings the page was already showing, rather than snapping back
		// to the defaults.
		settings := session.default_settings()
		if has_signals {
			apply_uploaded_settings(&settings, resolved.uploaded)
		}
		sessions[slot] = session.make_session("local", system, settings, session_allocator())
	}
	resolved.session = sessions[slot]
	return resolved, true
}

// Adopt the four bound settings the page uploaded, clamped. Returns whether anything changed.
sync_settings :: proc(s: ^session.Session, uploaded: Uploaded_Signals) -> (changed: bool) {
	wanted := s.settings
	apply_uploaded_settings(&wanted, uploaded)
	wanted = session.clamp_settings(wanted)
	if wanted == s.settings {
		return false
	}
	s.settings = wanted
	return true
}

@(private = "file")
apply_uploaded_settings :: proc(settings: ^session.Settings, uploaded: Uploaded_Signals) {
	if value, has := uploaded.difficulty.?; has {
		settings.difficulty = engine.clamp_difficulty(int(value))
	}
	if value, has := uploaded.ladderMode.?; has {
		settings.ladder_mode = value
	}
	if value, has := uploaded.targetOn.?; has {
		settings.target_on = value
	}
	if value, has := uploaded.targetPct.?; has {
		settings.target_pct = clamp(int(value), 70, 90)
	}
}

render_context_for :: proc(s: ^session.Session) -> render.Context {
	return render.Context {
		prefix = PREFIX,
		cookie_path = "/",
		// The countdown runs in the page. "stream" is the server holding a `/timer` response open,
		// which is exactly the kind of thing there is no server here to do.
		timer_mode = "client",
		build_stamp = "wasm",
		choices = choices_for(s.system),
	}
}

choices_for :: proc(system: ^corpus.System) -> []render.Topic_Choice {
	slot := session.slot_for_system(system)
	return slot < 0 ? nil : topic_choices[slot]
}

corpus_check :: proc(s: ^session.Session) -> ^corpus.Filter_Check {
	return corpus.check_filter(s.system, s.filter_text, engine.MAX_DIFFICULTY)
}

filter_status_for :: proc(s: ^session.Session) -> string {
	check := corpus_check(s)
	return render.filter_status(
		corpus.status_text(check.status),
		len(check.hits),
		check.parsed.errors,
		len(check.parsed.entries),
		check.parsed.canonical_text,
		s.filter_text,
		"",
		engine.MAX_DIFFICULTY,
		context.temp_allocator,
	)
}

//
// The page
//

route_index :: proc(request: Request, out: ^strings.Builder) {
	resolved, ok := resolve(request, switching = true)
	if !ok {
		write_no_content(out)
		return
	}
	s := resolved.session
	if strings.contains(request.query, "debug") {
		s.debug = true
	}
	strings.write_byte(out, 'D')
	render.write_shell(out, render_context_for(s), s, read_theme(request.cookie), filter_status_for(s))
}

// The theme cookie, where the page has cookies at all -- a `file://` page in Chrome does not.
@(private = "file")
read_theme :: proc(cookie: string) -> string {
	rest := cookie
	for len(rest) > 0 {
		semicolon := strings.index_byte(rest, ';')
		pair := semicolon < 0 ? rest : rest[:semicolon]
		rest = semicolon < 0 ? "" : rest[semicolon + 1:]
		trimmed := strings.trim_space(pair)
		equals := strings.index_byte(trimmed, '=')
		if equals < 0 || strings.trim_space(trimmed[:equals]) != render.THEME_COOKIE {
			continue
		}
		switch value := strings.trim_space(trimmed[equals + 1:]); value {
		case "light", "dark", "auto":
			return value
		}
	}
	return "auto"
}

//
// The answer choreography
//

@(private = "file")
build_answer :: proc(resolved: ^Resolved, script: ^Script, rest: string) {
	s := resolved.session

	slash := strings.index_byte(rest, '/')
	if slash < 0 {
		return
	}
	qid, qid_ok := strconv.parse_u64(rest[:slash])
	index, index_ok := strconv.parse_int(rest[slash + 1:])
	if !qid_ok || !index_ok {
		return
	}

	// A stale page resyncs rather than scoring: a double click and a replayed request land here.
	if s.qid != qid {
		push_resync(script, s)
		return
	}
	if !session.still_playing(s) || s.awaiting_next {
		return
	}
	if index < 0 || index >= len(s.question.candidates) {
		return
	}

	sync_settings(s, resolved.uploaded)
	percent_left := session.percent_time_left(s)
	chosen := s.question.candidates[index]

	// EVERYTHING is applied here, before a single step is streamed.
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
		session_allocator(),
	)
	s.last_correct_points = last_points
	s.skips_left += result.awarded_skips

	if result.completed {
		session.complete(s)
	} else if result.correct {
		session.new_question(s, session_allocator())
	} else {
		s.awaiting_next = true
		s.wrong_index = index
		s.has_wrong_index = true
	}

	// 1. the streak, first and alone, so the chip reacts before anything else
	push_signals(script, concat(`{"_streak":`, itoa(s.score.streak), "}"))

	// 2. clear the sound sink, then 3. the verdict sound BEFORE its toast
	clear_sfx(script)
	push_elements(script, render.sfx_beat(result.correct ? "correct" : "wrong", context.temp_allocator), "#sfx", .Append)

	for item in result.toasts {
		push_elements(script, render.toast(item, context.temp_allocator), "#toasts", .Inner)

		if item.awards_skip {
			push_elements(script, render.meter_sweep(), "#app .points-meter", .Append)
			push_elements(script, render.sfx_beat("skip", context.temp_allocator), "#sfx", .Append)
		}
		if item.has_points_after {
			push_signals(
				script,
				concat(
					`{"_points":`,
					itoa(item.points_after),
					`,"_pointsPct":`,
					itoa(render.points_percent(item.points_after, s.points_goal)),
					"}",
				),
			)
		}
		if floater := render.floater(item, result.completed, context.temp_allocator); floater != "" {
			push_elements(script, floater, concat("#quiz .candidates > :nth-child(", itoa(index + 1), ")"), .Append)
		}
		push_pause(script, item.pause)
	}

	if result.completed {
		push_elements(script, render.sfx_beat("final", context.temp_allocator), "#sfx", .Append)
	}
	clear_toasts(script)

	// The clock starts when the question REACHES the player, after the toasts.
	//
	// The server restarts it here too, but there it runs when the script is BUILT and the pauses are
	// served afterwards -- so the same line, in the same place, means the same thing.
	if session.on_the_clock(s) {
		session.start_question_clock(s)
	}
	push_view(script, s)
}

//
// The actions that share the view patches
//

@(private = "file")
build_next :: proc(resolved: ^Resolved, script: ^Script) {
	s := resolved.session
	if !s.awaiting_next || !session.still_playing(s) {
		return
	}
	sync_settings(s, resolved.uploaded)
	session.new_question(s, session_allocator())
	clear_toasts(script)
	push_view(script, s)
}

@(private = "file")
build_skip :: proc(resolved: ^Resolved, script: ^Script) {
	s := resolved.session
	if s.skips_left <= 0 || !session.still_playing(s) {
		return
	}
	sync_settings(s, resolved.uploaded)
	s.skips_left -= 1
	session.new_question(s, session_allocator())
	clear_toasts(script)
	push_view(script, s)
}

@(private = "file")
build_restart :: proc(resolved: ^Resolved, script: ^Script) {
	s := resolved.session
	sync_settings(s, resolved.uploaded)

	// RESTART TAKES THE FILTER AS TYPED. A filter typed but not yet applied with Enter is what someone
	// pressing Restart means to play - restarting on the OLD filter while the box shows the new one read as
	// "the filter does not work". So a pending filter is applied first, exactly as Enter applies it (which
	// restarts on its own when the canonical text changed). The python reference and the server ports
	// still restart on the applied filter only; this is a deliberate difference.
	if typed, has := resolved.uploaded.filterText.?; has {
		check := corpus.check_filter(s.system, typed, engine.MAX_DIFFICULTY)
		if check.parsed.canonical_text != s.filter_text {
			apply_filter(script, s, typed, "#filter-status")
			return
		}
	}
	session.restart(s, session_allocator())
	clear_toasts(script)
	push_view(script, s)
}

// A settings post that changed nothing is a no-op: the slider fires on every drag step, and moving it
// and back must not throw the game away.
@(private = "file")
build_settings :: proc(resolved: ^Resolved, script: ^Script) {
	s := resolved.session
	if !sync_settings(s, resolved.uploaded) {
		return
	}
	session.restart(s, session_allocator())
	clear_toasts(script)
	push_view(script, s)
}

//
// The filter and the topic picker. A PREVIEW commits nothing; only Apply changes the filter.
//

@(private = "file")
PENDING_HINT :: "press Enter to apply"

@(private = "file")
build_filter_preview :: proc(resolved: ^Resolved, script: ^Script) {
	s := resolved.session
	typed := resolved.uploaded.filterText.? or_else s.filter_text
	push_status(script, s, typed, "#filter-status")
}

@(private = "file")
build_topics_preview :: proc(resolved: ^Resolved, script: ^Script) {
	push_status(script, resolved.session, ticked_topics_text(resolved), "#topics-status")
}

@(private = "file")
build_topics_reset :: proc(resolved: ^Resolved, script: ^Script) {
	s := resolved.session
	check := corpus_check(s)
	push_signals(script, topics_only_signals(s, check.parsed.topic_names))
	clear_picker_status(script, s)
}

@(private = "file")
build_filter_apply :: proc(resolved: ^Resolved, script: ^Script) {
	s := resolved.session
	typed := resolved.uploaded.filterText.? or_else s.filter_text
	apply_filter(script, s, typed, "#filter-status")
}

@(private = "file")
build_topics_apply :: proc(resolved: ^Resolved, script: ^Script) {
	apply_filter(script, resolved.session, ticked_topics_text(resolved), "#filter-status")
}

// Adopt a filter, and restart the quiz only if the CANONICAL text changed.
@(private = "file")
apply_filter :: proc(script: ^Script, s: ^session.Session, text: string, status_selector: string) {
	check := corpus.check_filter(s.system, text, engine.MAX_DIFFICULTY)
	canonical := strings.clone(check.parsed.canonical_text, session_allocator())
	changed := canonical != s.filter_text
	s.filter_text = canonical

	push_elements(
		script,
		render.filter_status(
			corpus.status_text(check.status),
			len(check.hits),
			check.parsed.errors,
			len(check.parsed.entries),
			check.parsed.canonical_text,
			s.filter_text,
			"",
			engine.MAX_DIFFICULTY,
			context.temp_allocator,
		),
		status_selector,
		.Inner,
	)
	clear_picker_status(script, s)
	push_signals(
		script,
		render.bound_signals(s, choices_for(s.system), check.parsed.topic_names, context.temp_allocator),
	)

	if !changed {
		return
	}
	session.restart(s, session_allocator())
	clear_toasts(script)
	push_view(script, s)
}

@(private = "file")
push_status :: proc(script: ^Script, s: ^session.Session, text: string, selector: string) {
	check := corpus.check_filter(s.system, text, engine.MAX_DIFFICULTY)
	push_elements(
		script,
		render.filter_status(
			corpus.status_text(check.status),
			len(check.hits),
			check.parsed.errors,
			len(check.parsed.entries),
			check.parsed.canonical_text,
			s.filter_text,
			PENDING_HINT,
			engine.MAX_DIFFICULTY,
			context.temp_allocator,
		),
		selector,
		.Inner,
	)
}

// The filter text a set of ticked topics stands for: their names, comma-joined.
@(private = "file")
ticked_topics_text :: proc(resolved: ^Resolved) -> string {
	if resolved.payload == "" {
		return resolved.session.filter_text
	}
	out := strings.builder_make(0, 256, context.temp_allocator)
	for choice in choices_for(resolved.session.system) {
		if !signal_is_true(resolved.payload, choice.key) {
			continue
		}
		if strings.builder_len(out) > 0 {
			strings.write_string(&out, ", ")
		}
		strings.write_string(&out, choice.name)
	}
	return strings.to_string(out)
}

// Is `"<key>": true` in the payload? A scan rather than a parse, as on the server.
@(private = "file")
signal_is_true :: proc(payload, key: string) -> bool {
	needle := concat(`"`, key, `"`)
	at := strings.index(payload, needle)
	if at < 0 {
		return false
	}
	rest := payload[at + len(needle):]
	for index in 0 ..< len(rest) {
		switch rest[index] {
		case ' ', '\t', '\n', '\r', ':':
			continue
		case:
			return strings.has_prefix(rest[index:], "true")
		}
	}
	return false
}

@(private = "file")
topics_only_signals :: proc(s: ^session.Session, active: []string) -> string {
	out := strings.builder_make(0, 512, context.temp_allocator)
	strings.write_string(&out, `{"topics":{`)
	for choice, index in choices_for(s.system) {
		if index > 0 {
			strings.write_byte(&out, ',')
		}
		ticked := false
		for name in active {
			if name == choice.name {
				ticked = true
				break
			}
		}
		strings.write_byte(&out, '"')
		strings.write_string(&out, choice.key)
		strings.write_string(&out, `":`)
		strings.write_string(&out, ticked ? "true" : "false")
	}
	strings.write_string(&out, "}}")
	return strings.to_string(out)
}

// Empty the topic picker's status line - when there IS a picker. A system with no topics (a quiz the
// notes workbench generated from one `.bml` file) renders none, and a patch aimed at a missing element is
// a Datastar warning in the console on every filter apply.
@(private = "file")
clear_picker_status :: proc(script: ^Script, s: ^session.Session) {
	if len(choices_for(s.system)) > 0 {
		clear_topics_status(script)
	}
}

//
// The debug panel (`?debug`)
//

@(private = "file")
build_debug_points :: proc(resolved: ^Resolved, script: ^Script, rest: string) {
	s := resolved.session
	delta, ok := strconv.parse_int(rest)
	if !s.debug || !ok {
		return
	}
	s.score.total_points = max(s.score.total_points + delta, 0)
	push_view(script, s)
}

@(private = "file")
build_debug_goal :: proc(resolved: ^Resolved, script: ^Script, rest: string) {
	s := resolved.session
	value, ok := strconv.parse_int(rest)
	if !s.debug || !ok {
		return
	}
	s.points_goal = clamp(value, 10, 100_000)
	push_view(script, s)
}

@(private = "file")
build_debug_reveal :: proc(resolved: ^Resolved, script: ^Script) {
	s := resolved.session
	if !s.debug || len(s.question.candidates) == 0 {
		return
	}
	correct, _ := engine.answer_index(s.question)
	s.awaiting_next = true
	s.has_wrong_index = true
	s.wrong_index = correct == 0 ? min(1, len(s.question.candidates) - 1) : 0
	push_view(script, s)
}

// Finish through the REAL scoring path, so the finale is reached the way a player reaches it.
@(private = "file")
build_debug_complete :: proc(resolved: ^Resolved, script: ^Script) {
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
		session_allocator(),
	)
	s.last_correct_points = last
	s.skips_left += result.awarded_skips
	if result.completed {
		session.complete(s)
	}
	push_view(script, s)
}

//
// The view pair every state-changing route ends with
//

// FAT MORPH: the whole `#app`, then the whole signal set.
push_view :: proc(script: ^Script, s: ^session.Session) {
	body := strings.builder_make(0, 24 * 1024, context.temp_allocator)
	render.write_app_body(&body, render_context_for(s), s, filter_status_for(s))
	push_elements(script, strings.to_string(body), "#app", .Inner)
	push_signals(script, render.view_signals(s, context.temp_allocator))
}

push_resync :: proc(script: ^Script, s: ^session.Session) {
	push_view(script, s)
	push_elements(
		script,
		`<div class="toast warning notification is-warning">Quiz reloaded — this page has caught up</div>`,
		"#toasts",
		.Inner,
	)
}

//
// Small helpers
//

concat :: proc(parts: ..string) -> string {
	return strings.concatenate(parts, context.temp_allocator)
}

itoa :: proc(value: int) -> string {
	out := strings.builder_make(0, 24, context.temp_allocator)
	strings.write_int(&out, value)
	return strings.to_string(out)
}

// Where session state lives: the module's own heap, for as long as the page is open.
//
// NOT `session.store_allocator()`, which is `runtime.heap_allocator()` -- libc's heap, which does not
// exist on js_wasm32 (it asserts on the first allocation). The default allocator here is Odin's wasm
// page allocator, and nothing else in the module frees anything into it.
session_allocator :: proc() -> runtime.Allocator {
	return global_context.allocator
}
