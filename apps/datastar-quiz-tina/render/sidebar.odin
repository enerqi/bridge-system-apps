// The sidebar: progress, the debug panel, and every control that restarts the quiz.
//
// It is a drawer, closed at every width, because everything in it is difficulty, the filter, topics,
// ladder mode, the target, Restart and Appearance -- every one of which restarts the quiz or is a
// one-off preference.
package render

import "../engine"
import "../session"
import "core:strings"

@(private)
write_sidebar :: proc(out: ^strings.Builder, context_: Context, s: ^session.Session, filter_status: string) {
	query := variant_query(s, context.temp_allocator)

	strings.write_string(
		out,
		`<aside class="sidebar" data-on:click__outside="$_navOpen &amp;&amp; window.matchMedia('`,
	)
	strings.write_string(out, DRAWER_OVERLAY_QUERY)
	strings.write_string(
		out,
		`').matches &amp;&amp; !evt.target.closest('.nav-toggle') &amp;&amp; ($_navOpen = false)">`,
	)

	write_progress_panel(out, s)
	if s.debug {
		write_debug_panel(out, context_, s, query)
	}
	write_controls_panel(out, context_, s, query, filter_status)

	strings.write_string(out, `</aside>`)
}

// `data-preserve-attr="open"` on every <details> here: a fat morph replaces the element, and without
// it a panel the player opened would snap shut on the next interaction.
@(private = "file")
write_progress_panel :: proc(out: ^strings.Builder, s: ^session.Session) {
	strings.write_string(
		out,
		`<details class="panel box progress" id="progress" data-preserve-attr="open"><summary>Progress</summary>`,
	)
	strings.write_string(
		out,
		`<svg class="dial" viewBox="0 0 200 110" role="img" aria-label="percentage correct"><path class="dial-track" d="M 10 100 A 90 90 0 0 1 190 100" /><path class="dial-value" d="M 10 100 A 90 90 0 0 1 190 100" data-style:stroke-dashoffset="282.74 * (1 - $_scorePct / 100)" data-class="{poor: $_scorePct &lt; 30, weak: $_scorePct &gt;= 30 &amp;&amp; $_scorePct &lt; 49, fair: $_scorePct &gt;= 49 &amp;&amp; $_scorePct &lt; 59, ok: $_scorePct &gt;= 59 &amp;&amp; $_scorePct &lt; 75, good: $_scorePct &gt;= 75}" /><text class="dial-text" x="100" y="95" data-text="$_scorePct + '%'">0%</text></svg>`,
	)
	strings.write_string(
		out,
		`<p class="score-line"><span data-text="$_correct"></span> of <span data-text="$_attempted"></span> right &middot; <span data-text="$_points"></span> / `,
	)
	strings.write_int(out, s.points_goal)
	strings.write_string(out, ` points</p></details>`)
}

@(private = "file")
write_debug_panel :: proc(out: ^strings.Builder, context_: Context, s: ^session.Session, query: string) {
	strings.write_string(out, `<section class="panel box debug" id="debug"><strong>Debug</strong>`)

	strings.write_string(out, `<div class="debug-row">`)
	write_debug_button(out, context_, query, "/debug/points/100", "+100 pts")
	write_debug_button(out, context_, query, "/debug/points/-100", "&minus;100")
	strings.write_string(out, `</div><div class="debug-row">`)
	write_debug_button(out, context_, query, "/debug/goal/200", "goal 200")
	write_debug_button(out, context_, query, "/debug/goal/1000", "goal 1000")
	strings.write_string(out, `</div><div class="debug-row">`)
	write_debug_button(out, context_, query, "/debug/reveal", "show reveal")
	write_debug_button(out, context_, query, "/debug/complete", "show finale")
	strings.write_string(out, `</div>`)

	strings.write_string(out, `<p class="hint">goal `)
	strings.write_int(out, s.points_goal)
	strings.write_string(out, ` &middot; qid `)
	strings.write_u64(out, s.qid)
	strings.write_string(out, ` &middot; `)
	strings.write_string(out, session.still_playing(s) ? "playing" : "finished")
	strings.write_string(out, ` &middot; build `)
	write_escaped(out, context_.build_stamp)
	strings.write_string(out, `</p></section>`)
}

@(private = "file")
write_debug_button :: proc(out: ^strings.Builder, context_: Context, query, path, label: string) {
	strings.write_string(out, `<button type="button" class="button is-small" data-on:click="@post('`)
	strings.write_string(out, context_.prefix)
	strings.write_string(out, path)
	strings.write_string(out, query)
	strings.write_string(out, `')">`)
	strings.write_string(out, label)
	strings.write_string(out, `</button>`)
}

@(private = "file")
write_controls_panel :: proc(
	out: ^strings.Builder,
	context_: Context,
	s: ^session.Session,
	query, filter_status: string,
) {
	strings.write_string(out, `<section class="panel box controls">`)

	// The difficulty slider posts on `change`, debounced, not on `input`: dragging it fires a
	// continuous stream, and every one of those restarts the quiz.
	strings.write_string(out, `<label>Difficulty <output data-text="$difficulty"></output><input type="range" min="`)
	strings.write_int(out, engine.MIN_DIFFICULTY)
	strings.write_string(out, `" max="`)
	strings.write_int(out, engine.MAX_DIFFICULTY)
	strings.write_string(out, `" step="1" value="`)
	strings.write_int(out, s.settings.difficulty)
	strings.write_string(out, `" data-bind:difficulty data-on:change__debounce.400ms="@post('`)
	strings.write_string(out, context_.prefix)
	strings.write_string(out, `/settings`)
	strings.write_string(out, query)
	strings.write_string(out, `')" /></label>`)

	write_checkbox(
		out,
		context_,
		query,
		"data-bind:ladder-mode",
		s.settings.ladder_mode,
		"Ladder mode (can lose points)",
	)
	write_checkbox(out, context_, query, "data-bind:target-on", s.settings.target_on, "Target percentage required")

	strings.write_string(
		out,
		`<label>Target <output data-text="$targetPct"></output>%<input type="range" min="70" max="90" step="10" value="`,
	)
	strings.write_int(out, s.settings.target_pct)
	strings.write_string(
		out,
		`" data-attr:disabled="!$targetOn" data-bind:target-pct data-on:change__debounce.400ms="@post('`,
	)
	strings.write_string(out, context_.prefix)
	strings.write_string(out, `/settings`)
	strings.write_string(out, query)
	strings.write_string(out, `')" /></label>`)

	if len(context_.choices) > 0 {
		strings.write_string(
			out,
			`<button type="button" class="light button is-light" data-on:click="$_topicsOpen = true; window.matchMedia('`,
		)
		strings.write_string(out, DRAWER_OVERLAY_QUERY)
		strings.write_string(out, `').matches &amp;&amp; ($_navOpen = false)">Topics&hellip;</button>`)
	}

	strings.write_string(out, `<div class="filter-status" id="filter-status">`)
	strings.write_string(out, filter_status)
	strings.write_string(out, `</div>`)

	write_filter_details(out, context_, s, query)

	strings.write_string(out, `<p class="hint"><em>Changes restart the quiz.</em></p>`)
	strings.write_string(out, `<button type="button" class="danger button is-danger" data-on:click="@post('`)
	strings.write_string(out, context_.prefix)
	strings.write_string(out, `/restart`)
	strings.write_string(out, query)
	strings.write_string(out, `'); window.matchMedia('`)
	strings.write_string(out, DRAWER_OVERLAY_QUERY)
	strings.write_string(out, `').matches &amp;&amp; ($_navOpen = false)">Restart</button>`)

	write_appearance_details(out, s)
	strings.write_string(out, `</section>`)
}

@(private = "file")
write_checkbox :: proc(out: ^strings.Builder, context_: Context, query, bind: string, checked: bool, label: string) {
	strings.write_string(out, `<label class="checkbox"><input type="checkbox" `)
	if checked {
		strings.write_string(out, `checked `)
	}
	strings.write_string(out, bind)
	strings.write_string(out, ` data-on:change="@post('`)
	strings.write_string(out, context_.prefix)
	strings.write_string(out, `/settings`)
	strings.write_string(out, query)
	strings.write_string(out, `')" /> `)
	strings.write_string(out, label)
	strings.write_string(out, `</label>`)
}

@(private = "file")
write_filter_details :: proc(out: ^strings.Builder, context_: Context, s: ^session.Session, query: string) {
	strings.write_string(
		out,
		`<details class="advanced" data-preserve-attr="open"><summary>Advanced: bidding tree filter</summary>`,
	)

	// `input` previews (debounced, commits nothing), Enter applies. The blur before the post is
	// deliberate: on a phone it dismisses the keyboard, and the reveal's Enter handler excludes
	// focused form controls, so leaving focus here would swallow the next Enter.
	strings.write_string(
		out,
		`<label>Bidding tree filter<input type="text" class="input" list="topic-names" placeholder="e.g. 1D-1M-1N, or a topic" value="`,
	)
	write_escaped(out, s.filter_text)
	strings.write_string(out, `" data-bind:filter-text data-on:input__debounce.300ms="@get('`)
	strings.write_string(out, context_.prefix)
	strings.write_string(out, `/filter/preview`)
	strings.write_string(out, query)
	strings.write_string(out, `')" data-on:keydown="evt.key === 'Enter' &amp;&amp; (evt.target.blur(), @post('`)
	strings.write_string(out, context_.prefix)
	strings.write_string(out, `/filter/apply`)
	strings.write_string(out, query)
	strings.write_string(out, `'))" /></label>`)

	strings.write_string(out, `<datalist id="topic-names">`)
	for choice in context_.choices {
		strings.write_string(out, `<option value="`)
		write_escaped(out, choice.name)
		strings.write_string(out, `"></option>`)
	}
	strings.write_string(out, `</datalist>`)

	strings.write_string(
		out,
		`<details class="filter-help" data-preserve-attr="open"><summary>Filter syntax</summary><ul>` +
		`<li><code>1D-1M-1N</code> a bid; suits C D H S N. Separate calls with a dash or a space &mdash; <code>1D 1H</code>, <code>1D-1H</code> and <code>1D--1H</code> are the same</li>` +
		`<li><code>M</code> / <code>m</code> any major / any minor &mdash; <em>the only place case matters</em></li>` +
		`<li><code>1*</code> / <code>*</code> any suit at that level / any call</li>` +
		`<li><code>Pass</code> <code>X</code> <code>XX</code> pass, double, redouble</li>` +
		`<li><code>(2H)</code> brackets = the opponents' call; <code>(*)</code> = they did something</li>` +
		`<li><code>1D-1M, 2C</code> comma separates alternatives &mdash; either one matches</li></ul>` +
		`<p>A pattern describes <strong>your</strong> auction: opponent calls you do not mention are stepped over, so <code>1D-1H</code> matches 1D (Pass) 1H, 1D (1S) 1H and 1D (X) 1H. Bracket a call to pin the opponents down at that exact point. Too few matches falls back to the whole system.</p></details>`,
	)
	strings.write_string(out, `</details>`)
}

@(private = "file")
write_appearance_details :: proc(out: ^strings.Builder, s: ^session.Session) {
	strings.write_string(out, `<details class="appearance" data-preserve-attr="open"><summary>Appearance</summary>`)

	// The stylesheet picker is debug-only: the comparison settled on Pico, and leaving a control
	// that swaps the whole base sheet in a player's sidebar is an invitation to a bug report about
	// a layout nobody ships.
	if s.debug {
		strings.write_string(
			out,
			`<label>Base CSS<div class="select"><select data-bind="_css" data-on:change="evt.target.blur()"><option value="hand">Hand-rolled</option><option value="pico">Pico classless</option><option value="bulma">Bulma (spike)</option></select></div></label>`,
		)
	}

	// `data-bind` in the VALUE form for every underscore signal here: as a key it would be
	// kebab-then-camel converted, which eats the leading underscore and turns a local signal into
	// one uploaded on every request.
	strings.write_string(
		out,
		`<label class="checkbox"><input type="checkbox" checked data-bind="_juice" /> Game feel (shake, floating points, streak)</label>` +
		`<label class="checkbox"><input type="checkbox" data-bind="_sound" /> Sound (countdown tick, scoring chimes)</label>` +
		`<label>Font<div class="select"><select data-bind="_font" data-on:change="evt.target.blur()">` +
		`<option value="notes">Open Sans (as the notes)</option><option value="system">System UI</option>` +
		`<option value="rounded">Rounded</option><option value="serif">Serif</option>` +
		`<option value="mono">Monospace</option></select></div></label></details>`,
	)
}
