// The whole page, and the `#app` body every interaction replaces.
//
// FAT MORPH: an interaction patches `#app` entire rather than the handful of elements that changed.
// It costs ~3.4 KB more per interaction over the wire and the repetitive markup compresses well, and
// what it buys is that there is exactly one description of what the page looks like in a given state
// -- this file. The alternative, patching six selectors, is six descriptions that drift.
//
// Only the toast slot is patched finer, because one answer shows several in sequence.
//
// Server-rendered from current session state, with no client-side bootstrap and no hydration: view
// source is the state of the quiz, and a reload resumes it exactly.
package render

import "../corpus"
import "../engine"
import "../session"
import "core:strings"

THEME_COOKIE :: "dsq_theme"

// Below this width the sidebar is an overlay drawer rather than a column, so opening the topics
// dialog or restarting has to close it.
DRAWER_OVERLAY_QUERY :: "(max-width: 900px)"

// What the page needs that is not in the session.
Context :: struct {
	prefix:      string, // mount point, "" unless DSQUIZ_PREFIX is set
	cookie_path: string, // the prefix or "/"
	timer_mode:  string, // "client" | "stream"
	build_stamp: string,
	choices:     []Topic_Choice,
}

// The document. Everything below `#app` is written by `write_app_body`, so this file and the fat
// patch cannot drift -- when they were two copies they drifted within the hour.
write_shell :: proc(
	out: ^strings.Builder,
	context_: Context,
	s: ^session.Session,
	theme: string,
	filter_status: string,
) {
	css_href := stylesheet_href(DEFAULT_CSS, context_.prefix, context.temp_allocator)
	query := variant_query(s, context.temp_allocator)

	strings.write_string(out, "<!DOCTYPE html>\n")

	// `data-theme` goes on <html>, not <body>: the scrollbars take `color-scheme` from the root and
	// nowhere else, and Pico and Bulma both document `data-theme` there, so putting it there
	// switches the frameworks' own dark themes for free.
	//
	// It is `false` -- not 'auto', not '' -- when the OS should decide: datastar REMOVES an
	// attribute set to false, and no attribute is what leaves `color-scheme: light dark` in charge.
	// The attribute is rendered twice over: once statically from the cookie, which is what makes the
	// first paint right, and once as `data-attr`, which keeps it right after a click. Without the
	// static half a remembered choice arrives a frame late.
	strings.write_string(out, `<html lang="en"`)
	if theme == "light" || theme == "dark" {
		strings.write_string(out, ` data-theme="`)
		strings.write_string(out, theme)
		strings.write_byte(out, '"')
	}
	strings.write_string(out, ` data-attr:data-theme="$_theme &amp;&amp; $_theme !== 'auto' ? $_theme : false">`)

	strings.write_string(out, `<head><meta charset="utf-8" /><title>`)
	write_escaped(out, s.system.title)
	strings.write_string(out, `</title>`)
	strings.write_string(out, `<meta name="viewport" content="width=device-width, initial-scale=1.0" />`)

	// The href is BUILT from the signal rather than a chain of ternaries, which makes the file
	// naming the contract: `hand` is `app.css` and anything else is `app-<signal>.css`.
	//
	// The empty branch is not defensive noise. This element is in <head>, so it is processed BEFORE
	// `data-signals` on <body> has declared anything, and an undefined signal reads as '' -- which
	// built `/static/app-.css` and fetched a 404 on every single page load before the real value
	// arrived a tick later.
	strings.write_string(out, `<link rel="stylesheet" data-attr:href="$_css ? ($_css === 'hand' ? '`)
	strings.write_string(out, context_.prefix)
	strings.write_string(out, `/static/app.css' : '`)
	strings.write_string(out, context_.prefix)
	strings.write_string(out, `/static/app-' + $_css + '.css') : '`)
	strings.write_string(out, css_href)
	strings.write_string(out, `'" href="`)
	strings.write_string(out, css_href)
	strings.write_string(out, `" />`)

	// Every rule in juice.css hangs off `body.juice`, so it is inert until the Appearance toggle
	// turns it on. One file rather than three copies is the whole reason it is separate -- the
	// experiment can be deleted by deleting a file and one signal.
	strings.write_string(out, `<link rel="stylesheet" href="`)
	strings.write_string(out, context_.prefix)
	strings.write_string(out, `/static/juice.css" />`)
	strings.write_string(
		out,
		`<link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><text y='13' font-size='13'>&#9824;</text></svg>" />`,
	)
	strings.write_string(out, `<script type="module" src="`)
	strings.write_string(out, context_.prefix)
	strings.write_string(out, `/static/datastar.js"></script></head>`)

	// `juice` on the <body>, not inside `#app`: it has to survive every morph.
	strings.write_string(out, `<body data-signals="`)
	write_escaped(out, initial_signals(s, context_.choices, theme, context.temp_allocator))
	strings.write_string(out, `" data-attr:data-font="$_font" data-class="{juice: $_juice}"`)
	strings.write_string(out, ` data-init="$_navOpen = false`)
	if context_.timer_mode == "stream" {
		strings.write_string(out, `; @get('`)
		strings.write_string(out, context_.prefix)
		strings.write_string(out, `/timer`)
		strings.write_string(out, query)
		strings.write_string(out, `')`)
	}
	strings.write_string(out, `">`)

	strings.write_string(out, `<div id="app">`)
	write_app_body(out, context_, s, filter_status)
	strings.write_string(out, `</div>`)

	// The <audio> elements live OUTSIDE `#app`, and that is the whole design. The morph target is
	// rewritten on every interaction; an <audio> inside it would be replaced mid-playback and the
	// browser would re-fetch each file every time. Out here they are loaded once per page.
	//
	// `data-attr:src` rather than a static `src`: with sound off (the default) these have no source,
	// so a player who never turns it on never requests a WAV. `?v=` is the build stamp, so a changed
	// synth reaches a browser holding the old file.
	for name in SFX_NAMES {
		strings.write_string(out, `<audio id="sfx-`)
		strings.write_string(out, name)
		strings.write_string(out, `" preload="auto" data-attr:src="$_sound ? '`)
		strings.write_string(out, context_.prefix)
		strings.write_string(out, `/sfx/`)
		strings.write_string(out, name)
		strings.write_string(out, `?v=`)
		strings.write_string(out, context_.build_stamp)
		strings.write_string(out, `' : false"></audio>`)
	}
	strings.write_string(out, `<div id="sfx" hidden aria-hidden="true"></div>`)
	strings.write_string(out, `</body></html>`)
}

// The five sounds, in the order the shell declares them. Kept here rather than imported from `sfx`
// so the renderer does not depend on the synthesiser.
SFX_NAMES :: [5]string{"correct", "wrong", "skip", "final", "tick"}

// The seed for the whole signal store: server-owned, browser-owned and view-local, in one object.
@(private = "file")
initial_signals :: proc(
	s: ^session.Session,
	choices: []Topic_Choice,
	theme: string,
	allocator := context.allocator,
) -> string {
	server := signals(s, context.temp_allocator)
	bound := bound_signals(s, choices, active_topic_names(s), context.temp_allocator)
	local := local_ui_signals(theme, context.temp_allocator)

	out := strings.builder_make(0, len(server) + len(bound) + len(local), allocator)
	strings.write_string(&out, server[:len(server) - 1]) // drop the closing brace
	strings.write_byte(&out, ',')
	strings.write_string(&out, bound[1:len(bound) - 1]) // drop both braces
	strings.write_byte(&out, ',')
	strings.write_string(&out, local[1:]) // drop the opening brace
	return strings.to_string(out)
}

// Which topics the filter in force resolved to, so the picker's ticks agree with it even when the
// filter was typed rather than picked.
active_topic_names :: proc(s: ^session.Session) -> []string {
	check := corpus.check_filter(s.system, s.filter_text, engine.MAX_DIFFICULTY)
	return check.parsed.topic_names
}

// Everything inside `#app`: the top bar, the sidebar and the main column.
write_app_body :: proc(out: ^strings.Builder, context_: Context, s: ^session.Session, filter_status: string) {
	write_topbar(out, context_, s)
	strings.write_string(out, `<div class="layout" data-class="{'nav-closed': !$_navOpen}">`)
	write_sidebar(out, context_, s, filter_status)
	write_main(out, context_, s)
	strings.write_string(out, `</div>`)
}

@(private = "file")
write_topbar :: proc(out: ^strings.Builder, context_: Context, s: ^session.Session) {
	query := variant_query(s, context.temp_allocator)

	strings.write_string(out, `<header class="topbar">`)
	strings.write_string(
		out,
		`<button type="button" class="nav-toggle" aria-label="Toggle sidebar" data-attr:aria-expanded="$_navOpen" data-on:click="$_navOpen = !$_navOpen"><span class="bars" aria-hidden="true"></span></button>`,
	)
	strings.write_string(out, `<h1>`)
	write_escaped(out, s.system.title)
	strings.write_string(out, `</h1>`)

	strings.write_string(out, `<button type="button" class="theme-toggle button"`)
	strings.write_string(
		out,
		` data-attr:aria-label="'Colour theme: ' + $_theme + '. Activate to change.'" data-attr:title="'Theme: ' + $_theme"`,
	)
	strings.write_string(
		out,
		` data-on:click="$_theme = $_theme === 'auto' ? 'light' : ($_theme === 'light' ? 'dark' : 'auto'); document.cookie = '`,
	)
	strings.write_string(out, THEME_COOKIE)
	strings.write_string(out, `=' + $_theme + ';path=`)
	strings.write_string(out, context_.cookie_path)
	strings.write_string(out, `;max-age=31536000;samesite=lax'">`)
	strings.write_string(
		out,
		`<span aria-hidden="true" data-text="$_theme === 'light' ? '☀' : ($_theme === 'dark' ? '☾' : '◐')">◐</span></button>`,
	)

	strings.write_string(out, `<span class="topbar-spacer"></span>`)
	strings.write_string(
		out,
		`<span class="streak" data-attr:aria-label="'streak ' + $_streak" data-class="{hot: $_streak &gt;= 3, blazing: $_streak &gt;= 6, cold: $_streak &lt; 1}" data-style:transform="'scale(' + (1 + Math.min($_streak, 8) * 0.06) + ')'"><span class="streak-label" aria-hidden="true">streak</span><span aria-hidden="true" data-text="$_streak"></span><span aria-hidden="true">&times;</span></span>`,
	)
	strings.write_string(
		out,
		`<span class="topbar-score"><span class="score-fraction"><span data-text="$_correct"></span>/<span data-text="$_attempted"></span>&nbsp;·&nbsp;</span><span data-text="$_points"></span> pts</span>`,
	)

	strings.write_string(
		out,
		`<div class="meter points-meter hud-meter" role="img" data-class="{full: $_pointsPct &gt;= 100}" data-attr:aria-label="'points ' + $_points + ' of `,
	)
	strings.write_int(out, s.points_goal)
	strings.write_string(out, `'"><div class="meter-mask" data-style:width="(100 - $_pointsPct) + '%'"></div>`)
	milestones := engine.SCORE_MILESTONES
	for milestone in milestones {
		tick := engine.py_round(milestone * 100)
		strings.write_string(out, `<span class="meter-tick" style="left: `)
		strings.write_int(out, tick)
		strings.write_string(out, `%" data-class="{earned: $_pointsPct &gt;= `)
		strings.write_int(out, tick)
		strings.write_string(out, `}"></span>`)
	}
	strings.write_string(out, `</div>`)

	strings.write_string(
		out,
		`<button type="button" class="skip warning button is-warning" data-attr:disabled="$_skipsLeft &lt;= 0 || !$_playing" data-on:click="@post('`,
	)
	strings.write_string(out, context_.prefix)
	strings.write_string(out, `/skip`)
	strings.write_string(out, query)
	strings.write_string(
		out,
		`')" data-on:keydown__window="evt.key === 's' &amp;&amp; $_skipsLeft &gt; 0 &amp;&amp; $_playing &amp;&amp; !$_answering &amp;&amp; !$_topicsOpen &amp;&amp; !evt.target.closest?.('`,
	)
	strings.write_string(out, TYPING_TARGETS)
	strings.write_string(out, `') &amp;&amp; @post('`)
	strings.write_string(out, context_.prefix)
	strings.write_string(out, `/skip`)
	strings.write_string(out, query)
	strings.write_string(out, `')">Skip <span class="skip-count" data-text="$_skipsLeft"></span></button>`)
	strings.write_string(out, `</header>`)
}
