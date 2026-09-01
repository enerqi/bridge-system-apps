// The main column: the question card, the timer bar, the toast slot, the topics dialog and the
// reference notes.
package render

import "../engine"
import "../session"
import "core:strings"

@(private)
write_main :: proc(out: ^strings.Builder, context_: Context, s: ^session.Session) {
	query := variant_query(s, context.temp_allocator)

	strings.write_string(out, `<main class="main">`)

	// The mouseenter handler is for the system-notes iframe below: once it takes focus, every
	// keystroke goes to bridgebase's page instead of the quiz, and the accelerators stop working
	// with no visible reason. Moving the pointer back over the card takes focus off it.
	strings.write_string(
		out,
		`<section class="card" id="quiz" data-on:mouseenter="document.activeElement?.tagName === 'IFRAME' &amp;&amp; (document.activeElement.blur(), window.focus())">`,
	)
	write_card_body(out, context_, s)
	strings.write_string(out, `</section>`)

	write_timer(out, context_)

	strings.write_string(out, `<div class="toasts" id="toasts" aria-live="polite"></div>`)

	if len(context_.choices) > 0 {
		write_topics_dialog(out, context_, s, query)
	}

	write_notation_notes(out)
	write_system_notes(out, s)

	strings.write_string(out, `</main>`)
}

// What `#quiz` holds: the finale, the reveal, or the playable question.
@(private)
write_card_body :: proc(out: ^strings.Builder, context_: Context, s: ^session.Session) {
	if s.has_completed {
		write_completed_body(out, context_, s)
		return
	}
	if s.awaiting_next {
		write_reveal_body(out, s, context_.prefix)
		return
	}
	write_quiz_body(out, s, context_.prefix)
}

// The countdown bar.
//
// In the default `client` mode the browser walks it down on a 100 ms interval and no clock is
// shared: the bar is cosmetic, and the bonus that actually scores is recomputed server-side from
// `question_start` when the answer arrives. In `stream` mode the held `/timer` route pushes
// `_timeLeftPct` instead, and the interval is not rendered at all.
//
// The interval gates on `$_ticking && !$_answering`, not on `$_playing`: a scored answer parks on the
// reveal with the quiz very much still in play, and the bar kept draining there -- time pressure on
// a question that had already been answered.
@(private = "file")
write_timer :: proc(out: ^strings.Builder, context_: Context) {
	strings.write_string(out, `<div class="timer" id="timer"`)
	if context_.timer_mode != "stream" {
		strings.write_string(
			out,
			` data-on-interval__duration.100ms="$_ticking &amp;&amp; !$_answering &amp;&amp; ($_timeLeftPct = Math.max(0, $_timeLeftPct - 10000 / $_questionMs)) &amp;&amp; $_sound &amp;&amp; $_timeLeftPct * $_questionMs &lt; 300000 &amp;&amp; document.getElementById('sfx-tick')?.play()?.catch(() =&gt; {})"`,
		)
	}
	strings.write_string(
		out,
		`><div class="timer-fill" data-style:width="$_timeLeftPct + '%'" data-class="{spent: $_timeLeftPct &lt; 17, low: $_timeLeftPct &gt;= 17 &amp;&amp; $_timeLeftPct &lt; 49, mid: $_timeLeftPct &gt;= 49 &amp;&amp; $_timeLeftPct &lt; 65, high: $_timeLeftPct &gt;= 65, ticking: $_ticking &amp;&amp; !$_answering}"></div></div>`,
	)
}

// The topics picker.
//
// Nothing commits until Apply: the checkboxes drive a PREVIEW, so a player can see how many auctions
// a combination selects before living with it.
@(private = "file")
write_topics_dialog :: proc(out: ^strings.Builder, context_: Context, s: ^session.Session, query: string) {
	strings.write_string(
		out,
		`<dialog class="topics-dialog" id="topics-dialog" data-attr:open="$_topicsOpen" data-on:keydown__window="evt.key === 'Escape' &amp;&amp; $_topicsOpen &amp;&amp; ($_topicsOpen = false, @get('`,
	)
	strings.write_string(out, context_.prefix)
	strings.write_string(out, `/filter/topics-reset`)
	strings.write_string(out, query)
	strings.write_string(out, `'))"><h2>Topics</h2>`)
	strings.write_string(
		out,
		`<p>Pick any number &mdash; an auction matching <em>any</em> selected topic is included. Nothing changes until you press <strong>Apply</strong>, which replaces whatever is in the filter box.</p>`,
	)

	strings.write_string(out, `<div class="topics-scroll"><div class="topic-list">`)
	for choice in context_.choices {
		strings.write_string(out, `<label class="checkbox"><input type="checkbox" `)
		strings.write_string(out, choice.bind)
		strings.write_string(out, ` data-on:change="@get('`)
		strings.write_string(out, context_.prefix)
		strings.write_string(out, `/filter/preview-topics`)
		strings.write_string(out, query)
		strings.write_string(out, `')" /> `)
		write_escaped(out, choice.name)
		strings.write_string(out, `</label>`)
	}
	strings.write_string(out, `</div><div id="topics-status" class="filter-status"></div>`)

	has_descriptions := false
	for choice in context_.choices {
		if choice.description != "" {
			has_descriptions = true
			break
		}
	}
	if has_descriptions {
		strings.write_string(
			out,
			`<details data-preserve-attr="open"><summary>What the topics mean</summary><ul class="topic-legend">`,
		)
		for choice in context_.choices {
			if choice.description == "" {
				continue
			}
			strings.write_string(out, `<li><strong>`)
			write_escaped(out, choice.name)
			strings.write_string(out, `</strong> &mdash; `)
			write_escaped(out, choice.description)
			strings.write_string(out, `</li>`)
		}
		strings.write_string(out, `</ul></details>`)
	}
	strings.write_string(out, `</div>`)

	strings.write_string(
		out,
		`<div class="dialog-actions"><button type="button" class="button is-primary" data-on:click="$_topicsOpen = false; @post('`,
	)
	strings.write_string(out, context_.prefix)
	strings.write_string(out, `/filter/apply-topics`)
	strings.write_string(out, query)
	strings.write_string(out, `')">Apply</button>`)

	// `@setAll` with an include pattern, so Clear unticks the topic branch and nothing else.
	strings.write_string(
		out,
		`<button type="button" class="light button is-light" data-on:click="@setAll(false, {include: /^topics\./}); @get('`,
	)
	strings.write_string(out, context_.prefix)
	strings.write_string(out, `/filter/preview-topics`)
	strings.write_string(out, query)
	strings.write_string(out, `')">Clear</button>`)

	// Close RESETS the ticks to the filter in force, rather than leaving a half-made selection that
	// disagrees with the filter box.
	strings.write_string(
		out,
		`<button type="button" class="light button is-light" data-on:click="$_topicsOpen = false; @get('`,
	)
	strings.write_string(out, context_.prefix)
	strings.write_string(out, `/filter/topics-reset`)
	strings.write_string(out, query)
	strings.write_string(out, `')">Close</button></div></dialog>`)
}

@(private = "file")
write_notation_notes :: proc(out: ^strings.Builder) {
	strings.write_string(
		out,
		`<details class="notes" data-preserve-attr="open"><summary>Notation</summary><ul>` +
		`<li>Bids in brackets e.g (1` +
		HEART +
		`), (bid), (any), (1NT) etc. indicate the opponents made the bid.</li>` +
		`<li>The opponents' bids are often automatically removed from the question</li>` +
		`<li>~ means roughly/approximately (points are guides, not absolute)</li>` +
		`<li>X or Dbl means double</li>` +
		`<li>GF/FG means game forcing</li>` +
		`<li>NF means non-forcing</li>` +
		`<li>M means major, oM other major</li>` +
		`<li>m means minor, om other minor</li>` +
		`<li>Hx/HHx means Honour + x (small card), Honour Honour x etc.</li>` +
		`</ul></details>`,
	)
}

@(private = "file")
write_system_notes :: proc(out: ^strings.Builder, s: ^session.Session) {
	strings.write_string(
		out,
		`<details class="notes" data-preserve-attr="open"><summary>System Notes</summary><iframe src="`,
	)
	write_escaped(out, s.system.system_notes_url)
	strings.write_string(out, `" title="system notes" loading="lazy"></iframe></details>`)
}

// The finale.
@(private = "file")
write_completed_body :: proc(out: ^strings.Builder, context_: Context, s: ^session.Session) {
	strings.write_string(out, `<div class="finale"><div class="confetti" aria-hidden="true">`)
	confetti := CONFETTI
	for bit in confetti {
		strings.write_string(out, `<span class="confetti-bit" style="--drift: `)
		strings.write_int(out, bit.drift)
		strings.write_string(out, `%; --spin: `)
		strings.write_int(out, bit.spin)
		strings.write_string(out, `deg; --i: `)
		strings.write_int(out, bit.step)
		strings.write_string(out, `">`)
		strings.write_string(out, bit.glyph)
		strings.write_string(out, `</span>`)
	}
	strings.write_string(out, `</div><h2 class="celebrate" aria-hidden="true">`)
	for index in 0 ..< 3 {
		strings.write_string(out, `<span class="pop" style="--i: `)
		strings.write_int(out, index)
		strings.write_string(out, `">&#127881;</span>`)
	}
	strings.write_string(out, `</h2><p class="celebrate-text">Quiz complete!</p>`)

	strings.write_string(out, `<div class="finale-figures"><span class="finale-stat">`)
	write_figure(out, s.score.total_points, "big", "")
	strings.write_string(out, `<span class="finale-label">points of `)
	strings.write_int(out, s.points_goal)
	strings.write_string(out, `</span></span><span class="finale-stat">`)
	write_figure(out, engine.score_percentage(s.score), "", "%")
	strings.write_string(out, `<span class="finale-label">`)
	strings.write_int(out, s.score.questions_correct)
	strings.write_string(out, ` of `)
	strings.write_int(out, s.score.questions_attempted)
	strings.write_string(out, ` right</span></span><span class="finale-stat">`)
	write_figure(out, engine.py_round(session.quiz_seconds(s)), "", "s")
	strings.write_string(out, `<span class="finale-label">start to finish</span></span></div>`)

	strings.write_string(out, `<p class="celebrate-text">Well done, now take a break&hellip;</p>`)
	strings.write_string(out, `<img src="`)
	strings.write_string(out, context_.prefix)
	strings.write_string(out, `/media/completed.jpeg" alt="cat sleeping next to computer mouse" width="600" /></div>`)
}

// One number, a span per digit, so each can be animated in from somewhere different.
//
// The unit lives INSIDE the figure, not beside it: `.finale-stat` is a flex column, so a sibling `%`
// or `s` became its own row under the number.
@(private = "file")
write_figure :: proc(out: ^strings.Builder, value: int, class, unit: string) {
	strings.write_string(out, `<span class="figure `)
	strings.write_string(out, class)
	strings.write_string(out, `">`)

	digits: [24]u8
	text := format_int(value, digits[:])
	for index in 0 ..< len(text) {
		strings.write_string(out, `<span class="digit" style="--i: `)
		strings.write_int(out, index)
		strings.write_string(out, `">`)
		strings.write_byte(out, text[index])
		strings.write_string(out, `</span>`)
	}
	if unit != "" {
		strings.write_string(out, `<span class="figure-unit">`)
		strings.write_string(out, unit)
		strings.write_string(out, `</span>`)
	}
	strings.write_string(out, `</span>`)
}

@(private = "file")
format_int :: proc(value: int, buffer: []u8) -> string {
	if value == 0 {
		buffer[0] = '0'
		return string(buffer[:1])
	}
	negative := value < 0
	remaining := negative ? -value : value
	end := len(buffer)
	for remaining > 0 {
		end -= 1
		buffer[end] = u8('0' + remaining % 10)
		remaining /= 10
	}
	if negative {
		end -= 1
		buffer[end] = '-'
	}
	return string(buffer[end:])
}

@(private = "file")
Confetti_Bit :: struct {
	glyph: string,
	drift: int,
	spin:  int,
	step:  int,
}

// The confetti table, fixed rather than random: a server-side random would differ between the page
// render and a later fat patch, so the pieces would jump.
@(private = "file")
CONFETTI :: [12]Confetti_Bit {
	{"♠", -18, 220, 0},
	{"♥", 12, -160, 1},
	{"♦", -6, 300, 2},
	{"♣", 22, -240, 3},
	{"★", -14, 180, 4},
	{"♠", 8, -300, 5},
	{"♥", -22, 260, 6},
	{"♦", 16, -200, 7},
	{"♣", -10, 340, 8},
	{"★", 20, -280, 9},
	{"♠", -16, 200, 10},
	{"♥", 10, -220, 11},
}
