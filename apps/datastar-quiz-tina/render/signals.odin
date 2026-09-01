// The signal payloads.
//
// Datastar keeps a signal store in the browser and patches it over SSE. Three groups matter here and
// the difference between them is the whole state model:
//
//   - SERVER-OWNED display values are `_`-prefixed, which is datastar's marker for "local": they are
//     never uploaded back, so the score and the clock cost nothing on a request.
//   - BROWSER-OWNED form values carry no underscore, so they ride along with every request -- that
//     is how the server learns the difficulty slider moved.
//   - VIEW-LOCAL values the server never sets, declared so they exist from the first paint. An
//     undefined signal reads as the empty string in an expression, and `data-attr` treats that as
//     "set the attribute", so an undeclared `$_topicsOpen` leaves `<dialog open>` and the topic
//     picker is stuck open.
//
// Written as JSON by hand rather than through a map and a serialiser. The payloads are small, fixed
// and known at compile time, and each one has to fit a single SSE event reservation, so knowing the
// byte count matters more than the generality.
package render

import "../engine"
import "../session"
import "core:strings"

// Every signal the server owns, as a `datastar-patch-signals` payload.
//
// `_timeLeftPct` and `_questionMs` drive the timer bar: the server states the allowance and resets
// the bar per question, and the browser's 100 ms interval walks it down. No clock is shared, because
// the bar is cosmetic -- the bonus that actually scores is recomputed server-side from
// `question_start` when the answer arrives.
signals :: proc(s: ^session.Session, allocator := context.allocator) -> string {
	time_left := session.still_playing(s) ? session.percent_time_left(s) : 0

	out := strings.builder_make(0, 256, allocator)
	strings.write_byte(&out, '{')
	write_int_field(&out, "_correct", s.score.questions_correct, first = true)
	write_int_field(&out, "_attempted", s.score.questions_attempted)
	write_int_field(&out, "_scorePct", engine.score_percentage(s.score))
	write_int_field(&out, "_points", s.score.total_points)
	write_int_field(&out, "_pointsPct", points_percent(s.score.total_points, s.points_goal))
	write_int_field(&out, "_streak", s.score.streak)
	write_int_field(&out, "_skipsLeft", s.skips_left)
	write_bool_field(&out, "_playing", session.still_playing(s))
	// Whether the countdown should be running at all. `_playing` is not the same question: a scored
	// answer parks on the reveal with the quiz very much still in play, and the bar kept draining
	// there -- time pressure on a question that had already been answered. The client interval and
	// the held stream both gate on this.
	write_bool_field(&out, "_ticking", session.on_the_clock(s))
	write_int_field(&out, "_questionMs", engine.py_round(s.question_seconds * 1000))
	write_int_field(&out, "_timeLeftPct", time_left)
	strings.write_byte(&out, '}')
	return strings.to_string(out)
}

// The gauge's fill, capped at 100.
points_percent :: proc(points, goal: int) -> int {
	if goal <= 0 {
		return 0
	}
	return min(engine.py_round(f64(points) / f64(goal) * 100.0), 100)
}

// The EFFECTIVE settings, echoed back after the server has adopted them.
//
// The browser originates these, but the server clamps them, so after adopting a value the two can
// disagree -- send `difficulty: 99` and the server uses 8 while the slider still reads 99 until the
// next page load.
//
// Note what is deliberately NOT here: `filterText` and the `topics` ticks. Those are DRAFTS the user
// may be in the middle of editing, and re-stating them on an unrelated patch -- a Skip, say -- would
// wipe what they were typing.
settings_signals :: proc(s: ^session.Session, allocator := context.allocator) -> string {
	out := strings.builder_make(0, 96, allocator)
	strings.write_byte(&out, '{')
	write_settings_fields(&out, s)
	strings.write_byte(&out, '}')
	return strings.to_string(out)
}

// The two patches every state-changing route sends together: the view, then the whole signal set.
// Merged into one payload because they are one logical update and two events cost two reservations.
view_signals :: proc(s: ^session.Session, allocator := context.allocator) -> string {
	server := signals(s, context.temp_allocator)
	out := strings.builder_make(0, len(server) + 96, allocator)
	// `signals` already emitted the braces; splice the settings in before the closing one.
	strings.write_string(&out, server[:len(server) - 1])
	write_settings_fields(&out, s, first = false)
	strings.write_byte(&out, '}')
	return strings.to_string(out)
}

@(private = "file")
write_settings_fields :: proc(out: ^strings.Builder, s: ^session.Session, first := true) {
	write_int_field(out, "difficulty", s.settings.difficulty, first = first)
	write_bool_field(out, "ladderMode", s.settings.ladder_mode)
	write_bool_field(out, "targetOn", s.settings.target_on)
	write_int_field(out, "targetPct", s.settings.target_pct)
}

// The signals the BROWSER owns: form inputs bound with `data-bind`.
//
// No underscore, so datastar uploads them with every request. `topics` is seeded from the filter in
// force, so the picker's ticks agree with it even when the filter was typed rather than picked.
bound_signals :: proc(
	s: ^session.Session,
	choices: []Topic_Choice,
	active_topics: []string,
	allocator := context.allocator,
) -> string {
	out := strings.builder_make(0, 512, allocator)
	strings.write_byte(&out, '{')
	write_settings_fields(&out, s)
	write_string_field(&out, "filterText", s.filter_text)

	strings.write_string(&out, `,"topics":{`)
	for choice, index in choices {
		if index > 0 {
			strings.write_byte(&out, ',')
		}
		ticked := false
		for name in active_topics {
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

// View-local signals the server never sets, declared so they exist from the first paint.
//
// Declared in the `data-signals` OBJECT rather than as `data-signals:_topics-open`, because
// attribute keys are kebab-then-camel converted and that eats a leading underscore -- and the
// underscore is what keeps these out of every request.
local_ui_signals :: proc(theme: string, allocator := context.allocator) -> string {
	out := strings.builder_make(0, 256, allocator)
	strings.write_byte(&out, '{')
	write_bool_field(&out, "_topicsOpen", false, first = true)
	write_bool_field(&out, "_answering", false)
	write_string_field(&out, "_font", "notes")
	// `auto` | `light` | `dark`, remembered across reloads in the theme cookie and seeded from it
	// here, so the signal and the server-rendered attribute agree from the first frame.
	write_string_field(&out, "_theme", theme)
	// closed at every width, now that the drawer holds only settings
	write_bool_field(&out, "_navOpen", false)
	write_string_field(&out, "_css", DEFAULT_CSS)
	// The "game feel" experiment: hit-stop and shake on the reveal, floating points on the card you
	// picked, an escalating streak chip. Purely presentational, so purely local -- the server
	// streams the floaters either way and `body.juice` decides whether they are visible.
	write_bool_field(&out, "_juice", true)
	// Sound, OFF by default and the only appearance preference that is. Everything else here changes
	// how the page looks to the person who asked for it; audio arrives in a ROOM, and a quiz played
	// in a lesson or on a train should make no noise until someone says so. It also gates the FETCH:
	// the <audio> elements have no `src` until this is true.
	write_bool_field(&out, "_sound", false)
	strings.write_byte(&out, '}')
	return strings.to_string(out)
}

//
// JSON field writers. Small enough to be obvious, and they keep the payload sizes predictable.
//

@(private)
write_int_field :: proc(out: ^strings.Builder, name: string, value: int, first := false) {
	if !first {
		strings.write_byte(out, ',')
	}
	strings.write_byte(out, '"')
	strings.write_string(out, name)
	strings.write_string(out, `":`)
	strings.write_int(out, value)
}

@(private)
write_bool_field :: proc(out: ^strings.Builder, name: string, value: bool, first := false) {
	if !first {
		strings.write_byte(out, ',')
	}
	strings.write_byte(out, '"')
	strings.write_string(out, name)
	strings.write_string(out, `":`)
	strings.write_string(out, value ? "true" : "false")
}

@(private)
write_string_field :: proc(out: ^strings.Builder, name: string, value: string, first := false) {
	if !first {
		strings.write_byte(out, ',')
	}
	strings.write_byte(out, '"')
	strings.write_string(out, name)
	strings.write_string(out, `":`)
	write_json_string(out, value)
}

// A JSON string literal. The filter text is user input and reaches the browser inside a signal
// payload, so the escaping here is not cosmetic.
@(private)
write_json_string :: proc(out: ^strings.Builder, value: string) {
	strings.write_byte(out, '"')
	for index in 0 ..< len(value) {
		ch := value[index]
		switch ch {
		case '"':
			strings.write_string(out, `\"`)
		case '\\':
			strings.write_string(out, `\\`)
		case '\n':
			strings.write_string(out, `\n`)
		case '\r':
			strings.write_string(out, `\r`)
		case '\t':
			strings.write_string(out, `\t`)
		case:
			if ch < 0x20 {
				strings.write_string(out, `\u00`)
				strings.write_byte(out, HEX_DIGITS[ch >> 4])
				strings.write_byte(out, HEX_DIGITS[ch & 0xF])
			} else {
				strings.write_byte(out, ch)
			}
		}
	}
	strings.write_byte(out, '"')
}

@(private = "file")
HEX_DIGITS := "0123456789abcdef"
