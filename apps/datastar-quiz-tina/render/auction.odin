// Turning one auction, or one description, into the text a card shows.
//
// Copied from `apps/quiz/quiz_app.py` (via the python port's `render.py`) rather than shared -- that
// module imports panel. It is presentation-only, and it is the one piece of deliberate duplication
// in this port, as it is in the Go one.
package render

import "core:strings"

// The suit glyphs, deliberately WITHOUT U+FE0F: the variation selector makes some browsers pick an
// emoji font, and these are meant to be text that inherits the card's colour.
CLUB :: "♣"
DIAMOND :: "♦"
HEART :: "♥"
SPADE :: "♠"

// A button strips excess internal whitespace, so the separator has to carry its own -- these are
// U+2063 INVISIBLE SEPARATOR, four either side of the arrow.
@(private = "file")
INVISIBLE :: "⁣"

BID_SEPARATOR :: INVISIBLE + INVISIBLE + INVISIBLE + INVISIBLE + "‣" + INVISIBLE + INVISIBLE + INVISIBLE + INVISIBLE

// The python's `_suit_replace_regex` pass: `\d([CDHS]|N(?!T))+` -- a digit followed by one or more
// denominations, with the suit letters becoming glyphs and a bare `N` becoming `NT`.
//
// Hand-written rather than a regex because the NEGATIVE LOOKAHEAD is the load-bearing part: it is
// what keeps an already-spelled `1NT` from becoming `1NTT`.
@(private = "file")
suit_replace_in_bids :: proc(text: string, allocator := context.allocator) -> string {
	out := strings.builder_make(0, len(text) + 16, allocator)
	index := 0
	for index < len(text) {
		ch := text[index]
		if ch >= '0' && ch <= '9' {
			end := index + 1
			for end < len(text) {
				d := text[end]
				if d == 'C' || d == 'D' || d == 'H' || d == 'S' {
					end += 1
					continue
				}
				if d == 'N' && (end + 1 >= len(text) || text[end + 1] != 'T') {
					end += 1
					continue
				}
				break
			}
			if end > index + 1 {
				strings.write_byte(&out, ch)
				for position in index + 1 ..< end {
					switch text[position] {
					case 'C':
						strings.write_string(&out, CLUB)
					case 'D':
						strings.write_string(&out, DIAMOND)
					case 'H':
						strings.write_string(&out, HEART)
					case 'S':
						strings.write_string(&out, SPADE)
					case 'N':
						strings.write_string(&out, "NT")
					}
				}
				index = end
				continue
			}
		}
		strings.write_byte(&out, ch)
		index += 1
	}
	return strings.to_string(out)
}

// One auction (or description) as the card shows it: suit letters become glyphs, the `-->` joiner
// becomes the arrow separator, and markdown link targets are dropped.
emoji_text_auction :: proc(auction: string, allocator := context.allocator) -> string {
	text := auction

	if count_byte(text, '(') == 1 && count_byte(text, ')') == 1 && strings.contains(text, "(Pass)") {
		// A superfluous (pass). Better fixed in the data source, or by making every opposition call
		// explicit; until then it reads as a separator rather than as a call.
		text = replace_all(text, "(Pass)", BID_SEPARATOR)
	}

	text = suit_replace_in_bids(text, context.temp_allocator)

	// bml's `!x` shorthand
	text = replace_all(text, "!c", CLUB)
	text = replace_all(text, "!d", DIAMOND)
	text = replace_all(text, "!h", HEART)
	text = replace_all(text, "!s", SPADE)

	// a denomination standing alone as a word
	text = replace_all(text, " C ", " " + CLUB + " ")
	text = replace_all(text, " D ", " " + DIAMOND + " ")
	text = replace_all(text, " H ", " " + HEART + " ")
	text = replace_all(text, " S ", " " + SPADE + " ")

	// and one starting a word, which the space-delimited pass above cannot see
	text = replace_word_initial(text, 'C', CLUB)
	text = replace_word_initial(text, 'D', DIAMOND)
	text = replace_word_initial(text, 'H', HEART)
	text = replace_word_initial(text, 'S', SPADE)

	// plurals: "4+ Cs"
	text = replace_all(text, "Cs", CLUB + "s")
	text = replace_all(text, "Ds", DIAMOND + "s")
	text = replace_all(text, "Hs", HEART + "s")
	text = replace_all(text, "Ss", SPADE + "s")

	text = replace_all(text, "-->", BID_SEPARATOR)
	text = replace_all(text, "--", "-")

	text = replace_all(text, "[", "")
	text = replace_all(text, "]", "")
	return strip_link_targets(text, allocator)
}

// The python's `\bC ` family: a denomination at a word boundary, followed by a space.
@(private = "file")
replace_word_initial :: proc(text: string, letter: u8, glyph: string) -> string {
	out := strings.builder_make(0, len(text) + 8, context.temp_allocator)
	index := 0
	for index < len(text) {
		at_boundary := index == 0 || !is_word_byte(text[index - 1])
		if at_boundary && text[index] == letter && index + 1 < len(text) && text[index + 1] == ' ' {
			strings.write_string(&out, glyph)
			strings.write_byte(&out, ' ')
			index += 2
			continue
		}
		strings.write_byte(&out, text[index])
		index += 1
	}
	return strings.to_string(out)
}

// Drop `(#anchor)` link targets, keeping the label text the caller has already unbracketed.
@(private = "file")
strip_link_targets :: proc(text: string, allocator := context.allocator) -> string {
	out := strings.builder_make(0, len(text), allocator)
	index := 0
	for index < len(text) {
		if index + 1 < len(text) && text[index] == '(' && text[index + 1] == '#' {
			close := strings.index_byte(text[index:], ')')
			if close >= 0 {
				index += close + 1
				continue
			}
		}
		strings.write_byte(&out, text[index])
		index += 1
	}
	return strings.to_string(out)
}

@(private = "file")
is_word_byte :: #force_inline proc "contextless" (ch: u8) -> bool {
	return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_'
}

@(private = "file")
count_byte :: proc(text: string, target: u8) -> (count: int) {
	for index in 0 ..< len(text) {
		if text[index] == target {
			count += 1
		}
	}
	return count
}

@(private = "file")
replace_all :: proc(text, old, new: string) -> string {
	if old == "" || !strings.contains(text, old) {
		return text
	}
	out := strings.builder_make(0, len(text) + 16, context.temp_allocator)
	rest := text
	for {
		at := strings.index(rest, old)
		if at < 0 {
			strings.write_string(&out, rest)
			break
		}
		strings.write_string(&out, rest[:at])
		strings.write_string(&out, new)
		rest = rest[at + len(old):]
	}
	return strings.to_string(out)
}
