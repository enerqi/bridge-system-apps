// The small fragments the answer stream patches in one at a time.
//
// Each of these is one SSE event, so each has to fit one egress reservation on its own. They are all
// well under a kilobyte, which is why the answer choreography can be a dozen events without ever
// approaching the buffer.
package render

import "../engine"
import "core:strings"

// `♠` -> `<span class="scolor">♠</span>`, using bml's own colour classes so the quiz and the notes
// agree. Escapes first: the text may be a description from the corpus or a toast the engine built.
suits :: proc(out: ^strings.Builder, text: string) {
	escaped := strings.builder_make(0, len(text) + 16, context.temp_allocator)
	write_escaped(&escaped, text)
	source := strings.to_string(escaped)

	index := 0
	for index < len(source) {
		// The glyphs are three bytes each in UTF-8; compare the whole sequence rather than a byte.
		if index + 3 <= len(source) {
			glyph := source[index:index + 3]
			class := suit_class(glyph)
			if class != "" {
				strings.write_string(out, `<span class="`)
				strings.write_string(out, class)
				strings.write_string(out, `">`)
				strings.write_string(out, glyph)
				strings.write_string(out, `</span>`)
				index += 3
				continue
			}
		}
		strings.write_byte(out, source[index])
		index += 1
	}
}

@(private = "file")
suit_class :: proc "contextless" (glyph: string) -> string {
	switch glyph {
	case CLUB:
		return "ccolor"
	case DIAMOND:
		return "dcolor"
	case HEART:
		return "hcolor"
	case SPADE:
		return "scolor"
	}
	return ""
}

// One notification. An empty toast renders nothing -- the trailing beat of a right answer carries no
// text, it exists only for its pause.
toast :: proc(item: engine.Toast, allocator := context.allocator) -> string {
	if item.text == "" {
		return ""
	}
	out := strings.builder_make(0, len(item.text) + 96, allocator)
	strings.write_string(&out, `<div class="toast `)
	strings.write_string(&out, item.kind)
	strings.write_string(&out, ` notification is-`)
	strings.write_string(&out, item.kind)
	strings.write_string(&out, `">`)
	suits(&out, item.text)
	strings.write_string(&out, `</div>`)
	return strings.to_string(out)
}

// The number that floats off the card you picked.
//
// A skip milestone floats "+1 SKIP"; anything else floats its signed number, and a toast with no
// number in it floats nothing. `final` is the completing answer, which gets a bigger treatment.
floater :: proc(item: engine.Toast, final: bool, allocator := context.allocator) -> string {
	text := strings.trim_space(item.text)

	label: string
	if contains_fold(text, "SKIP") {
		label = "+1 SKIP"
	} else {
		number, found := signed_number(text)
		if !found {
			return ""
		}
		label = number
	}

	out := strings.builder_make(0, len(label) + 64, allocator)
	strings.write_string(&out, `<span class="floater `)
	strings.write_string(&out, strings.has_prefix(label, "+") ? "gain" : "loss")
	if final {
		strings.write_string(&out, " final")
	}
	strings.write_string(&out, `" aria-hidden="true">`)
	write_escaped(&out, label)
	strings.write_string(&out, `</span>`)
	return strings.to_string(out)
}

// The python's `[+-]\d+`: the first signed run of digits in the text.
@(private = "file")
signed_number :: proc(text: string) -> (number: string, found: bool) {
	for index in 0 ..< len(text) {
		if text[index] != '+' && text[index] != '-' {
			continue
		}
		end := index + 1
		for end < len(text) && text[end] >= '0' && text[end] <= '9' {
			end += 1
		}
		if end > index + 1 {
			return text[index:end], true
		}
	}
	return "", false
}

@(private = "file")
contains_fold :: proc(haystack, needle: string) -> bool {
	if len(needle) > len(haystack) {
		return false
	}
	for start in 0 ..= len(haystack) - len(needle) {
		matched := true
		for offset in 0 ..< len(needle) {
			a := haystack[start + offset]
			b := needle[offset]
			if a >= 'a' && a <= 'z' {
				a -= 32
			}
			if b >= 'a' && b <= 'z' {
				b -= 32
			}
			if a != b {
				matched = false
				break
			}
		}
		if matched {
			return true
		}
	}
	return false
}

// A sound marker, APPENDED to `#sfx` rather than morphed into it.
//
// Appended because an idempotent morph would leave two identical consecutive beats silent the second
// time -- the DOM would not change, so `data-init` would not run again. `#sfx` is cleared at the
// start of each answer, so it holds at most the handful of markers one answer produced.
sfx_beat :: proc(beat: string, allocator := context.allocator) -> string {
	out := strings.builder_make(0, 128, allocator)
	strings.write_string(&out, `<span aria-hidden="true" data-init="$_sound &amp;&amp; document.getElementById('sfx-`)
	strings.write_string(&out, beat)
	strings.write_string(&out, `')?.play()?.catch(() =&gt; {})"></span>`)
	return strings.to_string(out)
}

// The light that sweeps the points gauge when a milestone pays for a skip.
meter_sweep :: proc() -> string {
	return `<span class="meter-sweep" aria-hidden="true"></span>`
}

// The line under the filter box: what the current text selects, and what is wrong with it.
//
// Errors come first and are the user's own text, so they are escaped. `pending_hint` is shown only
// when the typed filter differs from the one in force -- "press Enter to apply" is noise otherwise.
filter_status :: proc(
	status: string,
	hits: int,
	errors: []string,
	entry_count: int,
	canonical_text, in_force, pending_hint: string,
	max_difficulty: int,
	allocator := context.allocator,
) -> string {
	out := strings.builder_make(0, 256, allocator)

	if len(errors) > 0 {
		strings.write_string(&out, `<div class="filter-line">⚠ not a topic or pattern: `)
		for entry, index in errors {
			if index > 0 {
				strings.write_string(&out, ", ")
			}
			strings.write_string(&out, "<code>")
			write_escaped(&out, entry)
			strings.write_string(&out, "</code>")
		}
		strings.write_string(&out, "</div>\n")
	}

	strings.write_string(&out, `<div class="filter-line">`)
	switch {
	case status == "too_few":
		strings.write_string(&out, "⚠ only ")
		strings.write_int(&out, hits)
		strings.write_string(&out, " match, need ")
		strings.write_int(&out, max_difficulty)
		strings.write_string(&out, "+ — the whole system is used")
	case status == "error":
		strings.write_string(&out, "⚠ nothing usable — the whole system is used")
	case entry_count == 0:
		strings.write_string(&out, "the whole system, <strong>")
		strings.write_int(&out, hits)
		strings.write_string(&out, "</strong> auctions")
	case:
		strings.write_string(&out, "<strong>")
		strings.write_int(&out, hits)
		strings.write_string(&out, "</strong> auctions match")
	}
	strings.write_string(&out, "</div>\n")

	if pending_hint != "" && canonical_text != in_force {
		strings.write_string(&out, `<div class="filter-line"><em>`)
		write_escaped(&out, pending_hint)
		strings.write_string(&out, "</em></div>\n")
	}
	return strings.to_string(out)
}
