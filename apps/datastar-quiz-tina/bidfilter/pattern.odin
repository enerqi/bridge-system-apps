// The pattern language: `1D-1M-1N`, `1H-(X)-2H`, `1N-2D/2H`, `*-*-*`.
//
// Suit-class shortcuts expand -- `M` is the majors, `m` the minors -- so `1D-1M-1N` matches both
// `1D-1H-1N` and `1D-1S-1N`. Opponent calls are written in brackets. A filter string may hold
// several comma-separated entries, matched as an OR.
//
// This is a port of the matching half of `apps/quiz/bidfilter.py`. The corpus itself is exported
// from the python as JSON, but the matcher is not: it is where the CPU goes, and a comparison that
// skipped it would not be a comparison.
package bidfilter

import "../bids"
import "../flat"
import "core:strings"

// Whose call a pattern position asks for. The python writes this as `Optional[bool]`, where None
// means "don't care"; the tri-state is the same thing said in a type.
Side :: enum u8 {
	Either, // None: don't care
	Ours, // False
	Theirs, // True
}

side_of :: #force_inline proc "contextless" (by_opponent: bool) -> Side {
	return by_opponent ? .Theirs : .Ours
}

// Whether a call by this side satisfies the pattern.
side_accepts :: #force_inline proc "contextless" (side: Side, by_opponent: bool) -> bool {
	switch side {
	case .Either:
		return true
	case .Ours:
		return !by_opponent
	case .Theirs:
		return by_opponent
	}
	return false
}

// What a pattern position asks for, beyond the denominations.
Pattern_Kind :: enum u8 {
	Bid,
	Pass,
	Double,
	Redouble,
	Wildcard, // the bare `*` / `any`: any call at this position
}

// One alternative at one position of a pattern. Six bytes, like a `bids.Bid`.
Bid_Pattern :: struct {
	level: u8, // 0 = any level
	suits: bids.Suits, // empty = any denomination
	kind:  Pattern_Kind,
	side:  Side,
}

// A whole bid pattern: one group of alternatives per position.
//
// Usually one alternative. `/` writes more than one -- `2D/2H`, `3S/4C` -- which is a single call
// the author wrote as a choice, NOT two consecutive calls. Alternatives differing only in
// denomination could equally be written `2DH`; ones spanning levels (`3S/4C`) have no single-token
// form, which is why a position is a set of patterns rather than one widened pattern.
Pattern :: flat.Flat(Bid_Pattern)

// Tidy raw user input: strip the ends, collapse whitespace runs, and remove whitespace that is
// decorative rather than a token separator (inside brackets, around `--`, and around the comma
// entry separator).
//
// Written by hand rather than as five regex passes, because it runs on every keystroke AND is the
// key of the filter memo, so it is on the hot path twice.
normalize_filter_text :: proc(text: string, allocator := context.allocator) -> string #no_bounds_check {
	// Collapse whitespace runs, then dash runs (with any surrounding whitespace) to a single `-`.
	collapsed := strings.builder_make(0, len(text), context.temp_allocator)
	pending_space, pending_dash := false, false
	for ch in strings.trim_space(text) {
		if is_space(ch) {
			pending_space = true
			continue
		}
		if ch == '-' {
			pending_dash = true
			pending_space = false
			continue
		}
		if pending_dash {
			strings.write_byte(&collapsed, '-')
		} else if pending_space {
			strings.write_byte(&collapsed, ' ')
		}
		pending_dash, pending_space = false, false
		strings.write_rune(&collapsed, ch)
	}
	if pending_dash {
		strings.write_byte(&collapsed, '-')
	}

	// Whitespace just inside a bracket is decorative.
	source := strings.to_string(collapsed)
	tidied := strings.builder_make(0, len(source), context.temp_allocator)
	for index in 0 ..< len(source) {
		if source[index] == ' ' {
			tidy := strings.to_string(tidied)
			before: u8 = len(tidy) == 0 ? 0 : tidy[len(tidy) - 1]
			after: u8 = index + 1 < len(source) ? source[index + 1] : 0
			if before == '(' || after == ')' {
				continue
			}
		}
		strings.write_byte(&tidied, source[index])
	}

	// Rebuild from the entries, so empty ones (`,,`, or a trailing comma) vanish.
	out := strings.builder_make(0, len(source), allocator)
	written := 0
	rest := strings.to_string(tidied)
	for {
		comma := strings.index_byte(rest, ',')
		entry := comma < 0 ? rest : rest[:comma]
		if trimmed := strings.trim_space(entry); trimmed != "" {
			if written > 0 {
				strings.write_string(&out, ", ")
			}
			strings.write_string(&out, trimmed)
			written += 1
		}
		if comma < 0 {
			break
		}
		rest = rest[comma + 1:]
	}
	return strings.to_string(out)
}

// Split normalised filter text on commas into non-empty entries.
split_entries :: proc(text: string, allocator := context.allocator) -> []string {
	normalised := normalize_filter_text(text, context.temp_allocator)
	entries := make([dynamic]string, 0, 4, allocator)
	rest := normalised
	for {
		comma := strings.index_byte(rest, ',')
		part := comma < 0 ? rest : rest[:comma]
		if trimmed := strings.trim_space(part); trimmed != "" {
			append(&entries, strings.clone(trimmed, allocator))
		}
		if comma < 0 {
			break
		}
		rest = rest[comma + 1:]
	}
	return entries[:]
}

// Parse `1D-1M-1N` (dashes or spaces; bml's `--` also accepted). A position may offer alternatives
// with `/`: `1M-3S/4C`.
parse_pattern :: proc(text: string, allocator := context.allocator) -> (pattern: Pattern, ok: bool) {
	normalised := normalize_filter_text(text, context.temp_allocator)
	pattern = flat.make_flat(Bid_Pattern, 4, 4, allocator)
	iterator := tokens(normalised)
	for token in iterate_tokens(&iterator) {
		if !parse_pattern_token(token, &pattern) {
			flat.destroy(&pattern)
			return {}, false
		}
	}
	if flat.is_empty(pattern) {
		flat.destroy(&pattern)
		return {}, false
	}
	return pattern, true
}

destroy_pattern :: proc(pattern: ^Pattern) {
	flat.destroy(pattern)
}

// Rewrite a pattern the way it was understood: `-`-joined, whitespace tidied, case folded, so
// `1d -- 1M 1n` comes back as `1D-1M-1N`. This is what the filter box shows after a commit.
canonical_pattern_text :: proc(text: string, allocator := context.allocator) -> string {
	normalised := normalize_filter_text(text, context.temp_allocator)
	out := strings.builder_make(0, len(normalised), allocator)
	iterator := tokens(normalised)
	for token in iterate_tokens(&iterator) {
		if strings.builder_len(out) > 0 {
			strings.write_byte(&out, '-')
		}
		inner, opponent := bids.strip_brackets(token)
		scratch, folded: [bids.TOKEN_BUFFER_MAX]u8
		expanded := bids.expand_suit_shorthand(inner, scratch[:])
		call_text := bids.fold_call_case(expanded, folded[:])
		if opponent {
			strings.write_byte(&out, '(')
			strings.write_string(&out, call_text)
			strings.write_byte(&out, ')')
		} else {
			strings.write_string(&out, call_text)
		}
	}
	return strings.to_string(out)
}

// Parse one position, which may be an alternation (`2D/2H`, `3S/4C`).
//
// Brackets may wrap the whole alternation -- `(2D/2H)` is the opponents making either call -- or an
// individual branch.
@(private = "file")
parse_pattern_token :: proc(token: string, out: ^Pattern) -> bool {
	inner, opponent := bids.strip_brackets(token)
	before := flat.open_len(out^)
	rest := inner
	for {
		separator := strings.index_byte(rest, u8(bids.ALT_SEP))
		part := separator < 0 ? rest : rest[:separator]
		if strings.trim_space(part) != "" {
			alternative, ok := parse_alternative(part, opponent)
			if !ok {
				return false
			}
			flat.push_item(out, alternative)
		}
		if separator < 0 {
			break
		}
		rest = rest[separator + 1:]
	}
	if flat.open_len(out^) == before {
		return false
	}
	flat.close_group(out)
	return true
}

@(private = "file")
parse_alternative :: proc(token: string, outer_opponent: bool) -> (pattern: Bid_Pattern, ok: bool) {
	raw, own_opponent := bids.strip_brackets(token)
	opponent := own_opponent || outer_opponent
	// Brackets are the notation for "the opponents did this", so a token without them is one of our
	// calls. The bare `*` wildcard below opts back out to "either side", which is what makes it
	// useful for counting depth.
	side := side_of(opponent)

	scratch, folded, upper_buffer: [bids.TOKEN_BUFFER_MAX]u8
	expanded := bids.expand_suit_shorthand(raw, scratch[:])
	inner := bids.fold_call_case(expanded, folded[:])
	upper := upper_ascii(inner, upper_buffer[:])

	switch upper {
	case "P", "PASS":
		return Bid_Pattern{kind = .Pass, side = side}, true
	case "X", "DBL":
		return Bid_Pattern{kind = .Double, side = side}, true
	case "XX", "RDBL", "R":
		return Bid_Pattern{kind = .Redouble, side = side}, true
	case "*", "ANY":
		// Any call at this position, by either side unless bracketed. `(*)` means "the opponents
		// did something here", since their passes are dropped.
		return Bid_Pattern{kind = .Wildcard, side = opponent ? .Theirs : .Either}, true
	}

	// `1*` / `1x` -- any denomination at that level (an empty suit set means "any"). Bid tables
	// spell this `x` and section headers `*`; a bare `X` was caught above as a double, so the level
	// is what makes them unambiguous.
	if len(upper) == 2 && is_level(upper[0]) && (upper[1] == 'X' || upper[1] == '*') {
		return Bid_Pattern{level = upper[0] - '0', kind = .Bid, side = side}, true
	}

	level := u8(0)
	rest := inner
	if len(rest) > 0 && is_level(rest[0]) {
		level = rest[0] - '0'
		rest = rest[1:]
	}

	// `oM` in a PATTERN has no earlier call to be "other" than, so it asks for the class: an auction
	// whose oM resolved either way matches.
	if len(rest) == 2 && rest[0] == 'O' && (rest[1] == 'M' || rest[1] == 'm') {
		suits := rest[1] == 'M' ? bids.MAJORS : bids.MINORS
		return Bid_Pattern{level = level, suits = suits, kind = .Bid, side = side}, true
	}

	// Level plus denomination characters, `^([1-7])?([CDHSNMm]+)$`, case-sensitive because M and m
	// are the class shortcuts. Note what is NOT accepted: `T`. A pattern is not NT-normalised (only
	// auctions are), so `1NT` typed into the filter box is rejected here and falls through to being
	// read as a topic name -- which is what the python and the Go port both do, and the tests pin.
	if len(rest) == 0 {
		return {}, false
	}
	suits := bids.NO_SUITS
	for index in 0 ..< len(rest) {
		switch rest[index] {
		case 'M':
			suits |= bids.MAJORS
		case 'm':
			suits |= bids.MINORS
		case 'C', 'D', 'H', 'S', 'N':
			suits |= bids.suit_from_char(rest[index])
		case:
			return {}, false
		}
	}
	return Bid_Pattern{level = level, suits = suits, kind = .Bid, side = side}, true
}

// Split a pattern on `-` and whitespace, which are interchangeable separators.
@(private = "file")
Token_Iterator :: struct {
	rest: string,
}

@(private = "file")
tokens :: proc(text: string) -> Token_Iterator {
	return Token_Iterator{rest = text}
}

@(private = "file")
iterate_tokens :: proc(iterator: ^Token_Iterator) -> (token: string, ok: bool) {
	for len(iterator.rest) > 0 {
		end := 0
		for end < len(iterator.rest) && !is_separator(iterator.rest[end]) {
			end += 1
		}
		token = iterator.rest[:end]
		iterator.rest = end < len(iterator.rest) ? iterator.rest[end + 1:] : ""
		if token != "" {
			return token, true
		}
	}
	return "", false
}

@(private = "file")
is_separator :: #force_inline proc "contextless" (ch: u8) -> bool {
	return ch == '-' || ch == ' ' || ch == '\t'
}

@(private = "file")
is_space :: #force_inline proc "contextless" (ch: rune) -> bool {
	return ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' || ch == '\v' || ch == '\f'
}

@(private = "file")
is_level :: #force_inline proc "contextless" (ch: u8) -> bool {
	return ch >= '1' && ch <= '7'
}

@(private = "file")
upper_ascii :: proc(text: string, buffer: []u8) -> string {
	if len(text) > len(buffer) {
		return text
	}
	for index in 0 ..< len(text) {
		ch := text[index]
		buffer[index] = ch >= 'a' && ch <= 'z' ? ch - 32 : ch
	}
	return string(buffer[:len(text)])
}
