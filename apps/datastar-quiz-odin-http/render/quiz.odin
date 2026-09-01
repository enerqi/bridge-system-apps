// The `#quiz` fragment: the prompt, the thing to match, and the candidate buttons -- and the reveal
// that replaces it after a wrong answer.
package render

import "../engine"
import "../session"
import "core:strings"

// The stylesheet everyone gets. The A/B/C between the hand-rolled sheet, Pico and Bulma is a
// runtime choice, and this is where it starts.
DEFAULT_CSS :: "pico"

// Which controls have a claim on a keystroke.
//
// NOT "any form control": a focused difficulty slider -- which keeps focus on purpose, or it could
// not be arrowed -- then killed the 1-9 accelerators for the rest of the session. So a range input
// is excluded from the typing set.
TYPING_TARGETS :: "input:not([type=range]):not([type=checkbox]):not([type=radio]), select, textarea, [contenteditable]"

// The same question for Enter and Space, which ACTIVATE a focused checkbox or radio -- so those keep
// their claim on this key even though they have none on a digit.
ACTIVATION_TARGETS :: "input:not([type=range]), select, textarea, [contenteditable]"

INTRO_AUCTIONS :: "In which auction is the final bid best described by:"
INTRO_DESCRIPTIONS :: "Which description matches the final bid in this sequence:"

intro_for :: proc "contextless" (choice_type: engine.Choice_Type) -> string {
	return choice_type == .Descriptions ? INTRO_DESCRIPTIONS : INTRO_AUCTIONS
}

// The stylesheet URL for a `$_css` value. A naming contract, not a lookup: the template rebuilds the
// same string in the browser when the picker changes.
stylesheet_href :: proc(value, prefix: string, allocator := context.allocator) -> string {
	name := value == "hand" ? "app.css" : strings.concatenate({"app-", value, ".css"}, context.temp_allocator)
	return strings.concatenate({prefix, "/static/", name}, allocator)
}

// `?squad` / `?swedish`, appended to every action URL.
//
// The session cookie is one per browser, so it cannot say which quiz a given PAGE is playing: open
// `?swedish` and the squad tab, the back-history entry and the phone's other tab all still hold the
// old markup while the cookie has moved on. The page's own URLs can say it, and they are written by
// the server that knows.
variant_query :: proc(s: ^session.Session, allocator := context.allocator) -> string {
	return strings.concatenate({"?", s.system.key}, allocator)
}

// The playable question.
//
// The action is in the URL -- `/answer/<qid>/<index>` -- not in a signal. The qid is the server's
// question nonce, so a second click, a stale tab or a replayed request scores nothing: the server
// compares the qid and resyncs the page. That replaces the panel app's "multiple clicks occurred too
// quickly before the server disabled the buttons" guard.
//
// `data-indicator` sets a local signal while a request is in flight and every button reads it to
// disable itself -- the visual half of the same protection, without a round trip. It is written in
// the VALUE form, not as `data-indicator:_answering`: attribute keys go through `kebab`, which turns
// a leading underscore into a dash and then drops it, so the key form would name the signal
// `Answering` and lose the underscore that keeps it local.
//
// These are BUTTONS, not a radio group: a click commits immediately, with no separate submit. What
// they get instead is `role="group"` with a label, and a digit accelerator each.
write_quiz_body :: proc(out: ^strings.Builder, s: ^session.Session, prefix: string) {
	query := variant_query(s, context.temp_allocator)
	answer := emoji_text_auction(s.question.answer, context.temp_allocator)

	strings.write_string(out, `<h2 class="intro">`)
	write_escaped(out, intro_for(s.question.choice_type))
	strings.write_string(out, `</h2>`)
	strings.write_string(out, `<p class="answer">&ldquo;<strong>`)
	write_escaped(out, answer)
	strings.write_string(out, `</strong>&rdquo;</p>`)

	// `data-attr` in the OBJECT form, because a hyphenated attribute name cannot survive as a key:
	// `data-attr:aria-busy` is kebab-then-camel converted to `ariaBusy` and nothing reaches the DOM
	// -- no `aria-busy`, no error, the attribute simply never appears.
	//
	// The value is the STRING "true"/"false", not the boolean: a boolean `true` renders as
	// `aria-busy=""`, datastar's "set the attribute" form, and an empty string is not a valid ARIA
	// state.
	//
	// ONE window keydown handler, on the group, mapping the digit to an index -- not one per button.
	// Five identical `__window` listeners were five registrations and five teardowns per patch, and
	// five copies of the same guard to keep in step. The guard is three things:
	//   - `$_answering` -- an answer already in flight. NOT cosmetic and not removable: the server
	//     mutates before it streams, so by the time the toasts are playing the NEXT question is
	//     already the live one, and a keypress here would answer a question not yet shown.
	//   - `closest(TYPING_TARGETS)` -- a keystroke aimed at a control that has a use for it belongs
	//     to that control.
	//   - the digit is in range for THIS question's choice count.
	// `evt.key` is compared through `Number` rather than as a string, so a ten-choice question would
	// not silently accept "1" as ten.
	strings.write_string(out, `<div class="candidates" role="group" aria-label="answer choices"`)
	strings.write_string(out, ` data-indicator="_answering"`)
	strings.write_string(out, ` data-attr="{'aria-busy': $_answering ? 'true' : 'false'}"`)
	strings.write_string(out, ` data-on:keydown__window="!$_answering &amp;&amp; !$_topicsOpen`)
	strings.write_string(out, ` &amp;&amp; !evt.target.closest?.('`)
	strings.write_string(out, TYPING_TARGETS)
	strings.write_string(out, `')`)
	strings.write_string(out, ` &amp;&amp; Number(evt.key) &gt;= 1 &amp;&amp; Number(evt.key) &lt;= `)
	strings.write_int(out, len(s.question.candidates))
	strings.write_string(out, ` &amp;&amp; @post('`)
	strings.write_string(out, prefix)
	strings.write_string(out, `/answer/`)
	strings.write_u64(out, s.qid)
	strings.write_string(out, `/' + (Number(evt.key) - 1) + '`)
	strings.write_string(out, query)
	strings.write_string(out, `')">`)

	for candidate, index in s.question.candidates {
		strings.write_string(out, `<button type="button" class="candidate button"`)
		strings.write_string(out, ` data-indicator="_answering"`)
		strings.write_string(out, ` data-attr:disabled="$_answering"`)
		strings.write_string(out, ` data-on:click="@post('`)
		strings.write_string(out, prefix)
		strings.write_string(out, `/answer/`)
		strings.write_u64(out, s.qid)
		strings.write_byte(out, '/')
		strings.write_int(out, index)
		strings.write_string(out, query)
		strings.write_string(out, `')">`)
		strings.write_string(out, `<kbd class="accel tag is-light" aria-hidden="true">`)
		strings.write_int(out, index + 1)
		strings.write_string(out, `</kbd><span class="candidate-text">`)
		write_escaped(out, emoji_text_auction(candidate, context.temp_allocator))
		strings.write_string(out, `</span></button>`)
	}
	strings.write_string(out, `</div>`)
}

// Shown in `#quiz` after a wrong answer, instead of panel's 4.2 s centre-screen toast.
//
// Non-blocking and in place: the prompt stays, the right answer is marked, the choice taken is
// marked, and nothing advances until the player says so. The clock for the NEXT question starts when
// it is served, so reading this costs no time bonus.
write_reveal_body :: proc(out: ^strings.Builder, s: ^session.Session, prefix: string) {
	query := variant_query(s, context.temp_allocator)
	correct_index, _ := engine.answer_index(s.question)

	strings.write_string(out, `<h2 class="intro">`)
	write_escaped(out, intro_for(s.question.choice_type))
	strings.write_string(out, `</h2>`)
	strings.write_string(out, `<p class="answer">&ldquo;<strong>`)
	write_escaped(out, emoji_text_auction(s.question.answer, context.temp_allocator))
	strings.write_string(out, `</strong>&rdquo;</p>`)

	strings.write_string(out, `<div class="candidates" role="group" aria-label="answer choices, revealed">`)
	for candidate, index in s.question.candidates {
		strings.write_string(out, `<div class="candidate revealed`)
		if index == correct_index {
			strings.write_string(out, ` correct`)
		} else if s.has_wrong_index && index == s.wrong_index {
			strings.write_string(out, ` wrong`)
		}
		strings.write_string(out, `"><span class="mark" aria-hidden="true">`)
		if index == correct_index {
			strings.write_string(out, "&#10003;")
		} else if s.has_wrong_index && index == s.wrong_index {
			strings.write_string(out, "&#10007;")
		}
		strings.write_string(out, `</span><span class="candidate-text">`)
		write_escaped(out, emoji_text_auction(candidate, context.temp_allocator))
		strings.write_string(out, `</span></div>`)
	}
	strings.write_string(out, `</div>`)

	// The window keydown lives on the WRAPPER and excludes BUTTON, because a focused button already
	// activates on Enter/Space natively. Binding both to the button fired two `@post('/next')`s: the
	// second superseded and aborted the first, after the server had already advanced the question --
	// so state moved on while the browser kept the stale reveal.
	//
	// Form controls are excluded with `closest`, not a tagName list: Enter in the filter box commits
	// a filter and must not also advance the question. BUTTON stays a tagName test -- it is
	// specifically the element the event fired on that activates natively.
	strings.write_string(
		out,
		`<div class="reveal-actions" data-on:keydown__window="(evt.key === 'Enter' || evt.key === ' ')`,
	)
	strings.write_string(out, ` &amp;&amp; !$_topicsOpen &amp;&amp; evt.target.tagName !== 'BUTTON'`)
	strings.write_string(out, ` &amp;&amp; !evt.target.closest?.('`)
	strings.write_string(out, ACTIVATION_TARGETS)
	strings.write_string(out, `') &amp;&amp; @post('`)
	strings.write_string(out, prefix)
	strings.write_string(out, `/next`)
	strings.write_string(out, query)
	strings.write_string(out, `')">`)
	strings.write_string(out, `<button type="button" class="next button is-primary" autofocus data-on:click="@post('`)
	strings.write_string(out, prefix)
	strings.write_string(out, `/next`)
	strings.write_string(out, query)
	strings.write_string(out, `')">Next question</button>`)
	strings.write_string(out, `<span class="reveal-hint">or press Enter</span></div>`)
}

// HTML text escaping. The corpus is trusted content, but the filter box is not, and the same writer
// serves both.
write_escaped :: proc(out: ^strings.Builder, text: string) {
	for index in 0 ..< len(text) {
		switch text[index] {
		case '&':
			strings.write_string(out, "&amp;")
		case '<':
			strings.write_string(out, "&lt;")
		case '>':
			strings.write_string(out, "&gt;")
		case '"':
			strings.write_string(out, "&#34;")
		case '\'':
			strings.write_string(out, "&#39;")
		case:
			strings.write_byte(out, text[index])
		}
	}
}
