// What every route needs before it can do anything: which browser, which variant, which session, and
// what the browser uploaded.
package web

import "../corpus"
import "../engine"
import "../render"
import "../session"
import "core:strings"
import datastar "tina:src/extensions/http/datastar"
import http "tina:src/extensions/http/server"

// The signals the browser owns and uploads on every request.
//
// Datastar sends the WHOLE store minus the `_`-prefixed locals, so this struct is what the app reads
// back: the four settings, the filter text, and the topic ticks. Anything else in the payload is
// ignored, which is what makes adding a view-local signal a one-line change in the renderer.
//
// `topics` is deliberately a raw JSON slice rather than a map: the keys are per-variant and derived
// from topic names, so a fixed struct cannot name them, and unmarshalling into a map would allocate
// one entry per topic on every request. The ticked names are pulled out by scanning it instead.
Uploaded_Signals :: struct {
	difficulty: Maybe(f64) `json:"difficulty"`,
	ladderMode: Maybe(bool) `json:"ladderMode"`,
	targetOn:   Maybe(bool) `json:"targetOn"`,
	targetPct:  Maybe(f64) `json:"targetPct"`,
	filterText: Maybe(string) `json:"filterText"`,
}

// A request, resolved.
Request_Context :: struct {
	sid:         string,
	system:      ^corpus.System,
	session:     ^session.Session,
	// The cookie named a session the store no longer has. Not an error -- a restarted server, or a
	// swept session -- but every route has to treat the request as stale, however well its question
	// id happens to match.
	replaced:    bool,
	uploaded:    Uploaded_Signals,
	// Whether the payload parsed at all. Malformed signals are NOT a server error: they are answered
	// as though nothing was uploaded, so a corrupted store in one tab cannot 500 the app.
	has_signals: bool,
}

// Everything a request says about itself, read WITHOUT the session.
//
// The split is phase I: the session lives in another isolate now, so a handler reads the request,
// asks the store for the session and parks. This is the half that happens before the park, and the
// `Request_Context` above is what the two halves add up to.
//
// The request FRAME survives a park -- Tina rebuilds the `Request` from the connection's own
// buffers on the resume event -- so headers, query, path parameters and a buffered body can all be
// read again afterwards. What does NOT survive is anything unmarshalled into the per-call scratch
// arena, which is why the signals are read on both sides of the park rather than carried across it.
Request_Read :: struct {
	sid:          string,
	system:       ^corpus.System,
	variant_slot: int,
	settings:     session.Settings,
	uploaded:     Uploaded_Signals,
	has_signals:  bool,
}

// Read a request: the browser, the variant it names, and the settings its page is showing.
//
// `switching` picks which of the two variant rules applies. Only the index page uses the second: a
// BARE url means "back to the default variant", while a non-empty query naming no variant (`?debug`)
// means "keep whatever you have". Everywhere else, only an explicit `?swedish`/`?squad` switches.
read_request :: proc(request: ^http.Request, switching := false, allocator := context.allocator) -> Request_Read {
	query := string(http.query(request))

	system: ^corpus.System
	found: bool
	if switching {
		system, found = corpus.variant_switch_for_query(loaded_corpus, query)
	} else {
		system, found = corpus.requested_variant(loaded_corpus, query)
	}
	if !found {
		system = corpus.default_system(loaded_corpus)
	}

	read := Request_Read {
		system       = system,
		variant_slot = session.slot_for_system(system),
	}

	read.sid = read_sid(request)
	if read.sid == "" {
		read.sid = session.new_sid(allocator)
	}

	// Signals are read BEFORE the session is created, so a brand-new session adopts the settings the
	// page was already showing rather than snapping back to the defaults.
	read.has_signals = datastar.read_signals(request, &read.uploaded) == .None

	read.settings = session.default_settings()
	apply_uploaded_settings(&read.settings, read.uploaded)
	return read
}

// The two halves, added up: what the request said, plus the session the store handed back.
resolved_from :: proc(read: Request_Read, s: ^session.Session, replaced: bool) -> Request_Context {
	return Request_Context {
		sid = read.sid,
		system = read.system,
		session = s,
		replaced = replaced,
		uploaded = read.uploaded,
		has_signals = read.has_signals,
	}
}

// Adopt the four bound settings the browser uploaded, clamped.
//
// Returns whether anything actually changed, which is what `/settings` uses to decide between
// restarting the quiz and answering 204.
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
	// A range input uploads a NUMBER, but a page that has been through a JSON round trip can send it
	// as a float, and an old tab can send something unusable. Truncating toward zero is what the
	// python's `int()` does, and anything unreadable keeps the current value.
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

// Is this request talking about a question that is no longer the live one?
//
// True when the cookie named a session the store has replaced, or when the qid does not match. The
// qid is the server's own nonce, so a double click, a stale tab and a replayed request all land here
// rather than scoring twice.
is_stale :: proc(resolved: Request_Context, qid: u64) -> bool {
	return resolved.replaced || resolved.session.qid != qid
}

//
// Cookies
//

// The session cookie's value, if the browser sent one that could be ours.
@(private = "file")
read_sid :: proc(request: ^http.Request) -> string {
	header := string(http.header(request, "cookie"))
	rest := header
	for len(rest) > 0 {
		semicolon := strings.index_byte(rest, ';')
		pair := semicolon < 0 ? rest : rest[:semicolon]
		rest = semicolon < 0 ? "" : rest[semicolon + 1:]

		trimmed := strings.trim_space(pair)
		equals := strings.index_byte(trimmed, '=')
		if equals < 0 {
			continue
		}
		if strings.trim_space(trimmed[:equals]) != session.COOKIE_NAME {
			continue
		}
		value := strings.trim_space(trimmed[equals + 1:])
		if session.valid_sid(value) {
			return value
		}
	}
	return ""
}

// The theme cookie, which seeds `_theme` so a remembered choice is right on the FIRST paint rather
// than a frame late.
read_theme :: proc(request: ^http.Request) -> string {
	header := string(http.header(request, "cookie"))
	rest := header
	for len(rest) > 0 {
		semicolon := strings.index_byte(rest, ';')
		pair := semicolon < 0 ? rest : rest[:semicolon]
		rest = semicolon < 0 ? "" : rest[semicolon + 1:]

		trimmed := strings.trim_space(pair)
		equals := strings.index_byte(trimmed, '=')
		if equals < 0 || strings.trim_space(trimmed[:equals]) != render.THEME_COOKIE {
			continue
		}
		value := strings.trim_space(trimmed[equals + 1:])
		switch value {
		case "light", "dark", "auto":
			return value
		}
	}
	return "auto"
}

// `HttpOnly` and `SameSite=Lax`, and scoped to the mount prefix.
//
// HttpOnly because nothing in the page has any use for the value -- it is a server-side lookup key,
// not something the browser reasons about. Lax rather than Strict so that following a link INTO the
// quiz still finds the session.
set_session_cookie :: proc(response: ^http.Response, sid: string) {
	value := strings.concatenate(
		{session.COOKIE_NAME, "=", sid, "; Path=", cookie_path(), "; Max-Age=21600; HttpOnly; SameSite=Lax"},
		context.temp_allocator,
	)
	_ = http.header_add(response, "Set-Cookie", value)
}

cookie_path :: proc() -> string {
	return config.prefix == "" ? "/" : config.prefix
}
