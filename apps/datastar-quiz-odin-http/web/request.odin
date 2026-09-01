// What every route needs before it can do anything: which browser, which variant, which session, and
// what the browser uploaded.
//
// The only difference from the sibling Tina port is where the uploaded signals come from. Tina hands
// a route a buffered body; odin-http reads the body asynchronously, so the body arrives here as a
// string the dispatcher already fetched (see `routes.odin`), and this file only has to decide
// between it and the `?datastar=` query a GET carries.
package web

import "../corpus"
import "../engine"
import "../render"
import "../session"
import "core:encoding/json"
import "core:strings"
import http "odinhttp:."

// The signals the browser owns and uploads on every request.
//
// Datastar sends the WHOLE store minus the `_`-prefixed locals, so this struct is what the app reads
// back: the four settings and the filter text. Anything else in the payload is ignored, which is
// what makes adding a view-local signal a one-line change in the renderer.
//
// `topics` is deliberately NOT a field: the keys are per-variant and derived from topic names, so a
// fixed struct cannot name them, and unmarshalling into a map would allocate one entry per topic on
// every request. The ticked names are pulled out by scanning the raw payload instead
// (`filter.odin`), which is why `Request_Context` keeps it.
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
	// The raw uploaded JSON, kept for the topic picker's key scan.
	payload:     string,
	// Whether the payload parsed at all. Malformed signals are NOT a server error: they are answered
	// as though nothing was uploaded, so a corrupted store in one tab cannot 500 the app.
	has_signals: bool,
}

// Resolve a request: the browser, the variant it names, and the session for that pair.
//
// `switching` picks which of the two variant rules applies. Only the index page uses the second: a
// BARE url means "back to the default variant", while a non-empty query naming no variant (`?debug`)
// means "keep whatever you have". Everywhere else, only an explicit `?swedish`/`?squad` switches.
resolve_request :: proc(
	request: ^http.Request,
	response: ^http.Response,
	body: string,
	switching := false,
) -> (
	resolved: Request_Context,
) {
	query := request.url.query

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
	resolved.system = system

	resolved.sid = read_sid(request)
	if resolved.sid == "" {
		resolved.sid = session.new_sid(store.allocator)
	}

	// Signals are read BEFORE the session is created, so a brand-new session adopts the settings the
	// page was already showing rather than snapping back to the defaults.
	resolved.payload = signals_payload(request, response, body)
	resolved.has_signals = read_signals(resolved.payload, &resolved.uploaded, request_arena(response))

	settings := session.default_settings()
	apply_uploaded_settings(&settings, resolved.uploaded)

	resolved.session, resolved.replaced = store_get_or_create(resolved.sid, system, settings)
	return resolved
}

// The raw signal JSON, wherever this method puts it.
//
// Datastar uploads its store as the request body on a POST and as a percent-encoded `?datastar=`
// parameter on a GET. This app's set is ~475 bytes before the topic ticks, which is why the server's
// request-line limit is raised (see `server.odin`).
@(private = "file")
signals_payload :: proc(request: ^http.Request, response: ^http.Response, body: string) -> string {
	if body != "" {
		return body
	}
	if decoded, ok := http.query_get_percent_decoded(request.url, "datastar", request_arena(response)); ok {
		return decoded
	}
	return ""
}

@(private = "file")
read_signals :: proc(payload: string, signals: ^Uploaded_Signals, allocator := context.allocator) -> bool {
	if payload == "" {
		return false
	}
	return json.unmarshal(transmute([]u8)payload, signals, .JSON, allocator) == nil
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
	return cookie_value(request, session.COOKIE_NAME, session.valid_sid)
}

// The theme cookie, which seeds `_theme` so a remembered choice is right on the FIRST paint rather
// than a frame late.
read_theme :: proc(request: ^http.Request) -> string {
	value := cookie_value(request, render.THEME_COOKIE, proc(value: string) -> bool {
		switch value {
		case "light", "dark", "auto":
			return true
		}
		return false
	})
	return value == "" ? "auto" : value
}

// One `Cookie:` header, scanned for a name whose value passes `accept`.
//
// A scan rather than a parse: odin-http parses request cookies on demand and this app wants two
// named values out of a header that is usually one pair long.
@(private = "file")
cookie_value :: proc(request: ^http.Request, name: string, accept: proc(value: string) -> bool) -> string {
	header, has := http.headers_get(request.headers, "cookie")
	if !has {
		return ""
	}
	rest := header
	for len(rest) > 0 {
		semicolon := strings.index_byte(rest, ';')
		pair := semicolon < 0 ? rest : rest[:semicolon]
		rest = semicolon < 0 ? "" : rest[semicolon + 1:]

		trimmed := strings.trim_space(pair)
		equals := strings.index_byte(trimmed, '=')
		if equals < 0 || strings.trim_space(trimmed[:equals]) != name {
			continue
		}
		value := strings.trim_space(trimmed[equals + 1:])
		if accept(value) {
			return value
		}
	}
	return ""
}

// `HttpOnly` and `SameSite=Lax`, and scoped to the mount prefix.
//
// HttpOnly because nothing in the page has any use for the value -- it is a server-side lookup key,
// not something the browser reasons about. Lax rather than Strict so that following a link INTO the
// quiz still finds the session.
set_session_cookie :: proc(response: ^http.Response, sid: string) {
	value := strings.concatenate(
		{session.COOKIE_NAME, "=", sid, "; Path=", cookie_path(), "; Max-Age=21600; HttpOnly; SameSite=Lax"},
		request_arena(response),
	)
	http.headers_set_unsafe(&response.headers, "set-cookie", value)
}

cookie_path :: proc() -> string {
	return config.prefix == "" ? "/" : config.prefix
}
