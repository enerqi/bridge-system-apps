// The bidding-tree filter and the topic picker.
//
// The distinction that runs through this file: a PREVIEW commits nothing. Typing in the filter box
// and ticking topics both re-check the corpus and report what would be selected, but only Apply
// changes the filter in force -- and only then, and only if the canonical text actually changed,
// does the quiz restart.
package web

import "../corpus"
import "../engine"
import "../render"
import "../session"
import "core:strings"
import http "odinhttp:."

// What the filter box shows under itself while the text differs from the filter in force.
@(private = "file")
PENDING_HINT :: "press Enter to apply"

// The check for the filter CURRENTLY IN FORCE, which is what the page renders against.
@(private)
corpus_check :: proc(s: ^session.Session) -> ^corpus.Filter_Check {
	return corpus.check_filter(s.system, s.filter_text, engine.MAX_DIFFICULTY)
}

@(private)
status_text_of :: proc(check: ^corpus.Filter_Check) -> string {
	return corpus.status_text(check.status)
}

//
// Previewing
//

route_filter_preview :: proc(request: ^http.Request, response: ^http.Response) {
	sse_route_get(request, response, build_filter_preview)
}

// Check the TYPED text without adopting it, and patch the status line.
@(private = "file")
build_filter_preview :: proc(resolved: Request_Context, request: ^http.Request, stream: ^Stream) {
	s := resolved.session
	typed := resolved.uploaded.filterText.? or_else s.filter_text
	push_status(stream, s, typed, "#filter-status")
}

route_topics_preview :: proc(request: ^http.Request, response: ^http.Response) {
	sse_route_get(request, response, build_topics_preview)
}

@(private = "file")
build_topics_preview :: proc(resolved: Request_Context, request: ^http.Request, stream: ^Stream) {
	s := resolved.session
	text := ticked_topics_text(resolved, request_arena(stream.response))
	push_status(stream, s, text, "#topics-status")
}

// Put the ticks back to the filter in force, and clear the picker's status line.
//
// This is what Close and Escape do: a half-made selection that disagrees with the filter box is
// worse than no selection, because the next Apply would commit it.
route_topics_reset :: proc(request: ^http.Request, response: ^http.Response) {
	sse_route_get(request, response, build_topics_reset)
}

@(private = "file")
build_topics_reset :: proc(resolved: Request_Context, request: ^http.Request, stream: ^Stream) {
	s := resolved.session
	check := corpus_check(s)
	push_signals(stream, topics_only_signals(s, check.parsed.topic_names, request_arena(stream.response)))
	clear_topics_status(stream)
}

//
// Applying
//

route_filter_apply :: proc(request: ^http.Request, response: ^http.Response) {
	sse_route_post(request, response, build_filter_apply)
}

@(private = "file")
build_filter_apply :: proc(resolved: Request_Context, request: ^http.Request, stream: ^Stream) {
	s := resolved.session
	typed := resolved.uploaded.filterText.? or_else s.filter_text
	apply_filter(stream, s, typed, "#filter-status")
}

route_topics_apply :: proc(request: ^http.Request, response: ^http.Response) {
	sse_route_post(request, response, build_topics_apply)
}

@(private = "file")
build_topics_apply :: proc(resolved: Request_Context, request: ^http.Request, stream: ^Stream) {
	s := resolved.session
	apply_filter(stream, s, ticked_topics_text(resolved, request_arena(stream.response)), "#filter-status")
}

// Adopt a filter, and restart the quiz only if the CANONICAL text changed.
//
// Canonical, not literal: `1d -- 1M` and `1D-1M` are the same filter, and retyping one as the other
// should not throw a game away.
@(private = "file")
apply_filter :: proc(stream: ^Stream, s: ^session.Session, text: string, status_selector: string) {
	arena := request_arena(stream.response)
	check := corpus.check_filter(s.system, text, engine.MAX_DIFFICULTY)
	canonical := strings.clone(check.parsed.canonical_text, store.allocator)
	changed := canonical != s.filter_text

	s.filter_text = canonical

	push_elements(
		stream,
		render.filter_status(
			corpus.status_text(check.status),
			len(check.hits),
			check.parsed.errors,
			len(check.parsed.entries),
			check.parsed.canonical_text,
			s.filter_text,
			"",
			engine.MAX_DIFFICULTY,
			arena,
		),
		status_selector,
		.Inner,
	)
	clear_topics_status(stream)
	push_signals(stream, render.bound_signals(s, choices_for(s.system), check.parsed.topic_names, arena))

	if !changed {
		return
	}
	session.restart(s, store.allocator)
	clear_toasts(stream)
	push_view(stream, s)
}

//
// Shared bits
//

@(private = "file")
push_status :: proc(stream: ^Stream, s: ^session.Session, text: string, selector: string) {
	arena := request_arena(stream.response)
	check := corpus.check_filter(s.system, text, engine.MAX_DIFFICULTY)
	push_elements(
		stream,
		render.filter_status(
			corpus.status_text(check.status),
			len(check.hits),
			check.parsed.errors,
			len(check.parsed.entries),
			check.parsed.canonical_text,
			s.filter_text,
			PENDING_HINT,
			engine.MAX_DIFFICULTY,
			arena,
		),
		selector,
		.Inner,
	)
}

// The filter text a set of ticked topics stands for: their names, comma-joined.
//
// Read straight out of the raw signal payload rather than through a map, because the keys are
// per-variant and derived from topic names -- so the lookup goes the other way, from each known
// choice to whether its key is `true` in the payload.
@(private = "file")
ticked_topics_text :: proc(resolved: Request_Context, allocator := context.allocator) -> string {
	if resolved.payload == "" {
		return resolved.session.filter_text
	}

	out := strings.builder_make(0, 256, allocator)
	for choice in choices_for(resolved.system) {
		if !signal_is_true(resolved.payload, choice.key, allocator) {
			continue
		}
		if strings.builder_len(out) > 0 {
			strings.write_string(&out, ", ")
		}
		strings.write_string(&out, choice.name)
	}
	return strings.to_string(out)
}

// Is `"<key>": true` in the payload's `topics` object?
//
// A scan rather than a parse: the object has one entry per topic and this runs on every tick, so
// unmarshalling it would allocate a map per keystroke to answer a question about one key.
@(private = "file")
signal_is_true :: proc(payload, key: string, allocator := context.allocator) -> bool {
	needle := strings.concatenate({`"`, key, `"`}, allocator)
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

// Only the `topics` branch, so a reset does not re-state the filter text the user may be editing.
@(private = "file")
topics_only_signals :: proc(s: ^session.Session, active: []string, allocator := context.allocator) -> string {
	out := strings.builder_make(0, 512, allocator)
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

_ :: http
