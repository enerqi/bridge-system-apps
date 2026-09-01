// Turning written call tokens into `Bid`s.
//
// The python does this with a normalise-then-regex pipeline that builds three or four strings per
// token. Here normalisation writes into a stack buffer the caller owns and the regexes are written
// out as byte comparisons, so parsing a token allocates nothing at all. That is not premature: this
// runs on every token of a 7,600-auction corpus at boot, and again on every keystroke in the filter
// box, where the only memory available is a handler scratch arena measured in kilobytes.
package bids

import "core:strings"

// `!h` / `!H` -> `H`, the shorthand used in .bml source. Writes into `buffer` and returns the
// prefix of it that was used; returns `text` unchanged if it does not fit, since an over-long token
// is prose and parses to `.Other` either way.
expand_suit_shorthand :: proc(text: string, buffer: []u8) -> string {
	if len(text) > len(buffer) {
		return text
	}
	used := 0
	index := 0
	for index < len(text) {
		ch := text[index]
		if ch == '!' && index + 1 < len(text) && is_suit_letter(text[index + 1]) {
			buffer[used] = to_upper(text[index + 1])
			used += 1
			index += 2
			continue
		}
		buffer[used] = ch
		used += 1
		index += 1
	}
	return string(buffer[:used])
}

// Uppercase a token, keeping a lowercase `m` (minors) distinct from `M` (majors). Everything else is
// a suit letter or a keyword, for which case carries no meaning.
fold_call_case :: proc(token: string, buffer: []u8) -> string {
	if len(token) > len(buffer) {
		return token
	}
	for index in 0 ..< len(token) {
		ch := token[index]
		buffer[index] = ch == 'm' ? 'm' : to_upper(ch)
	}
	return string(buffer[:len(token)])
}

// Case-fold a token and reduce `NT` to `N`, without touching brackets.
//
// Two buffers because the three steps cannot share one: shorthand expansion and case folding each
// read their whole input before writing, and `NT` -> `N` shortens in place afterwards.
normalise_call_token :: proc(token: string, scratch, buffer: []u8) -> string {
	expanded := expand_suit_shorthand(strings.trim_space(token), scratch)
	folded := fold_call_case(expanded, buffer)
	return collapse_notrump(folded, buffer)
}

// `NT` -> `N`, in place. `folded` must already alias `buffer`.
@(private = "file")
collapse_notrump :: proc(folded: string, buffer: []u8) -> string {
	if len(folded) > len(buffer) || raw_data(folded) != raw_data(buffer) {
		return folded
	}
	used := 0
	index := 0
	for index < len(folded) {
		if folded[index] == 'N' && index + 1 < len(folded) && folded[index + 1] == 'T' {
			buffer[used] = 'N'
			used += 1
			index += 2
			continue
		}
		buffer[used] = folded[index]
		used += 1
		index += 1
	}
	return string(buffer[:used])
}

// Split `(1S)` into its inner text and "was it the opponents'".
strip_brackets :: proc(token: string) -> (inner: string, by_opponent: bool) {
	trimmed := strings.trim_space(token)
	return strings.trim(trimmed, "()"), strings.has_prefix(trimmed, "(")
}

// `[1D](#1C--1D)` -> `1D`. Bid tables may write a call as a markdown link to the section that
// explains it, and the label is the call.
unwrap_link :: proc(token: string) -> string {
	trimmed := strings.trim_space(token)
	if !strings.has_prefix(trimmed, "[") {
		return token
	}
	rest := trimmed[1:]
	close := strings.index_byte(rest, ']')
	if close < 0 {
		return token
	}
	label := rest[:close]
	if len(label) == 0 || strings.index_any(label, " \t\r\n") >= 0 {
		return token
	}
	after := rest[close + 1:]
	if !strings.has_prefix(after, "(") || !strings.has_suffix(after, ")") {
		return token
	}
	if strings.index_byte(after[1:len(after) - 1], ')') >= 0 {
		return token
	}
	return label
}

// `HS` -> {H,S}; `M` -> majors; `m` -> minors; `*` -> every denomination.
expand_denominations :: proc(text: string) -> Suits {
	suits := NO_SUITS
	for index in 0 ..< len(text) {
		switch text[index] {
		case 'M':
			suits |= MAJORS
		case 'm':
			suits |= MINORS
		case '*':
			suits |= ALL_SUITS
		case:
			suits |= suit_from_char(text[index])
		}
	}
	return suits
}

// Parse one auction position into the calls it allows, written into `out`.
//
// `2D/2H` is *one* call written as two possibilities, and `(2D/2H)` is the opponents making it; the
// brackets may wrap the whole alternation or each alternative.
parse_call_alternatives :: proc(token: string, out: []Bid) -> []Bid {
	trimmed := strings.trim_space(token)
	if trimmed == "" {
		return out[:0]
	}
	outer, outer_opponent := strip_brackets(unwrap_link(trimmed))

	count := 0
	rest := outer
	for count < len(out) {
		part: string
		separator := strings.index_byte(rest, u8(ALT_SEP))
		if separator < 0 {
			part = rest
		} else {
			part = rest[:separator]
			rest = rest[separator + 1:]
		}
		if strings.trim_space(part) != "" {
			if call, ok := parse_call(part); ok {
				// brackets around the whole alternation apply to every alternative
				call.by_opponent = call.by_opponent || outer_opponent
				out[count] = call
				count += 1
			}
		}
		if separator < 0 {
			break
		}
	}
	return out[:count]
}

// One Bid covering every alternative, when they differ only in denomination.
//
// `2D/2H` is exactly `2DH`. Alternatives spanning levels (`3S/4C`) or kinds cannot be one Bid, and
// the caller falls back to `.Other`.
merge_alternatives :: proc(calls: []Bid) -> (merged: Bid, ok: bool) {
	if len(calls) == 0 {
		return {}, false
	}
	merged = calls[0]
	for call in calls[1:] {
		if call.level != merged.level || call.kind != merged.kind || call.by_opponent != merged.by_opponent {
			return {}, false
		}
		merged.suits |= call.suits
	}
	return merged, true
}

// Parse a single call. `ok` is false only for empty input; an unrecognised token comes back as
// `.Other` so it can be carried along rather than crashing a whole sequence.
parse_call :: proc(token: string) -> (bid: Bid, ok: bool) {
	trimmed := strings.trim_space(token)
	if trimmed == "" {
		return {}, false
	}
	unwrapped := unwrap_link(trimmed)

	if strings.index_byte(unwrapped, u8(ALT_SEP)) >= 0 {
		alternatives: [ALTERNATIVES_MAX]Bid
		if merged, merged_ok := merge_alternatives(parse_call_alternatives(unwrapped, alternatives[:])); merged_ok {
			return merged, true
		}
		_, opponent := strip_brackets(unwrapped)
		return plain(.Other, opponent), true
	}

	scratch_buffer, normal_buffer: [TOKEN_BUFFER_MAX]u8
	normalised := normalise_call_token(unwrapped, scratch_buffer[:], normal_buffer[:])
	inner, opponent := strip_brackets(normalised)

	// `inner` keeps its lowercase `m`; `upper` does not. The two are distinct only for the suit
	// classes, and every keyword match below wants the case-insensitive one.
	upper_buffer: [TOKEN_BUFFER_MAX]u8
	upper := upper_ascii(inner, upper_buffer[:])

	switch inner {
	case "P", "PASS":
		return plain(.Pass, opponent), true
	case "X", "DBL":
		return plain(.Double, opponent), true
	case "XX", "RDBL", "R":
		return plain(.Redouble, opponent), true
	case "ANY":
		return plain(.Any, opponent), true
	case "NEXT":
		return plain(.Next, opponent), true
	}

	switch upper {
	case "OTHER", "OTHERS":
		return plain(.Any, opponent), true
	case "OVERCALL", "HIGHER":
		return plain(.Any_Bid, opponent), true
	case "BID":
		return plain(.Any_Call, opponent), true
	case "GAME":
		return plain(.Game, opponent), true
	case "JUMP", "JUMPNEW", "NEWJUMP":
		bid = plain(.Jump, opponent)
		bid.jump_levels = 1
		return bid, true
	case "DOUBLEJUMP":
		bid = plain(.Jump, opponent)
		bid.jump_levels = 2
		return bid, true
	}

	// `!d` is diamonds, but a bare `D` written on its own is the double, so this guard looks at the
	// token as written rather than at the shorthand-expanded form.
	raw_inner, _ := strip_brackets(trimmed)
	if !equal_fold(raw_inner, "D") {
		if suits, plus, matched := match_strain(inner, upper); matched {
			bid = plain(plus ? .Strain_Any : .Strain, opponent)
			bid.suits = suits
			return bid, true
		}
	}

	if level, matched := match_suffixed(upper, "SLAM"); matched {
		bid = plain(.Slam, opponent)
		bid.level = level
		return bid, true
	}
	if upper == "NEXTSUIT" {
		return plain(.Next_Suit, opponent), true
	}
	if upper == "4THSUIT" || upper == "FOURTHSUIT" {
		return plain(.Fourth_Suit, opponent), true
	}
	if level, jump, matched := match_raise(upper); matched {
		bid = plain(.Raise, opponent)
		bid.level = level
		bid.jump_levels = jump
		return bid, true
	}
	if step, matched := match_step(upper); matched {
		// level carries which step; 0 means "any of them"
		bid = plain(.Step, opponent)
		bid.level = step
		return bid, true
	}
	if level, kind, matched := match_cue_pick(upper); matched {
		bid = plain(kind, opponent)
		bid.level = level
		return bid, true
	}
	if level, matched := match_suffixed(upper, "CUEOVER"); matched {
		bid = plain(.Cue_Over, opponent)
		bid.level = level
		return bid, true
	}
	if level, matched := match_suffixed(upper, "CUE"); matched {
		bid = plain(.Cue, opponent)
		bid.level = level
		return bid, true
	}
	if level, matched := match_new(upper); matched {
		bid = plain(.New, opponent)
		bid.level = level
		return bid, true
	}
	if level, suits, matched := match_at_least(inner); matched {
		// `2N+` -- every call from 2N up. Enumerated by `calls_at_or_above` rather than stored as a
		// bound, so matching stays a plain set intersection.
		bid = plain(.At_Least, opponent)
		bid.level = level
		bid.suits = suits
		return bid, true
	}
	if level, matched := match_level_wildcard(inner); matched {
		bid = plain(.Bid, opponent)
		bid.level = level
		bid.suits = ALL_SUITS
		return bid, true
	}
	if level, class, matched := match_other_class(inner); matched {
		// `oM` with no level ("the other major, at whatever level") keeps level 0: it still
		// constrains the denomination, which is what it is for.
		bid = plain(.Bid, opponent)
		bid.level = level
		bid.suits = class_suits_of(class)
		bid.suit_class = class
		return bid, true
	}
	if level, denominations, matched := match_bid(inner); matched {
		bid = plain(.Bid, opponent)
		bid.level = level
		bid.suits = expand_denominations(denominations)
		switch denominations {
		case "M":
			bid.suit_class = .Major
		case "m":
			bid.suit_class = .Minor
		}
		return bid, true
	}
	return plain(.Other, opponent), true
}

//
// The regexes of the python, written out. A regex engine would do, but these run on every token of a
// 7,600-auction corpus at boot and each one here is a handful of byte comparisons.
//

// `^(?:MAJORS?|MINORS?|([CDHSNMm]+))(\+)?$` -- a denomination with no level.
@(private = "file")
match_strain :: proc(inner, upper: string) -> (suits: Suits, plus: bool, ok: bool) {
	body := inner
	if strings.has_suffix(body, "+") {
		body = body[:len(body) - 1]
		plus = true
	}
	upper_body := upper
	if strings.has_suffix(upper_body, "+") {
		upper_body = upper_body[:len(upper_body) - 1]
	}
	if upper_body == "MAJOR" || upper_body == "MAJORS" {
		return MAJORS, plus, true
	}
	if upper_body == "MINOR" || upper_body == "MINORS" {
		return MINORS, plus, true
	}
	if len(body) == 0 {
		return {}, false, false
	}
	for index in 0 ..< len(body) {
		switch body[index] {
		case 'C', 'D', 'H', 'S', 'N', 'M', 'm':
		case:
			return {}, false, false
		}
	}
	return expand_denominations(body), plus, true
}

// `^([1-7])?<WORD>$`
@(private = "file")
match_suffixed :: proc(upper, word: string) -> (level: u8, ok: bool) {
	if !strings.has_suffix(upper, word) {
		return 0, false
	}
	rest := upper[:len(upper) - len(word)]
	switch len(rest) {
	case 0:
		return 0, true
	case 1:
		if is_level(rest[0]) {
			return rest[0] - '0', true
		}
	}
	return 0, false
}

// `^([1-7])?(JUMP)?RAISE$`
@(private = "file")
match_raise :: proc(upper: string) -> (level: u8, jump: u8, ok: bool) {
	if !strings.has_suffix(upper, "RAISE") {
		return 0, 0, false
	}
	rest := upper[:len(upper) - len("RAISE")]
	if strings.has_suffix(rest, "JUMP") {
		rest = rest[:len(rest) - len("JUMP")]
		jump = 1
	}
	switch len(rest) {
	case 0:
		return 0, jump, true
	case 1:
		if is_level(rest[0]) {
			return rest[0] - '0', jump, true
		}
	}
	return 0, 0, false
}

// `^(?:([1-7]|X)STEP|STEP([1-7]))$` -- both spellings occur. 0 means "any of them".
@(private = "file")
match_step :: proc(upper: string) -> (step: u8, ok: bool) {
	if strings.has_suffix(upper, "STEP") {
		rest := upper[:len(upper) - len("STEP")]
		if rest == "X" {
			return 0, true
		}
		if len(rest) == 1 && is_level(rest[0]) {
			return rest[0] - '0', true
		}
		return 0, false
	}
	if strings.has_prefix(upper, "STEP") {
		rest := upper[len("STEP"):]
		if len(rest) == 1 && is_level(rest[0]) {
			return rest[0] - '0', true
		}
	}
	return 0, false
}

// `^([1-7])?CUE(LOW|HI|HIGH)$`
@(private = "file")
match_cue_pick :: proc(upper: string) -> (level: u8, kind: Kind, ok: bool) {
	if found, matched := match_suffixed(upper, "CUELOW"); matched {
		return found, .Cue_Low, true
	}
	if found, matched := match_suffixed(upper, "CUEHIGH"); matched {
		return found, .Cue_High, true
	}
	if found, matched := match_suffixed(upper, "CUEHI"); matched {
		return found, .Cue_High, true
	}
	return 0, .Other, false
}

// `^(?:([1-7])?(?:NEW(?:SUIT)?|SUIT|OTHERSUIT)|([1-7])Y)$`
@(private = "file")
match_new :: proc(upper: string) -> (level: u8, ok: bool) {
	for suffix in ([4]string{"NEWSUIT", "NEW", "OTHERSUIT", "SUIT"}) {
		if found, matched := match_suffixed(upper, suffix); matched {
			return found, true
		}
	}
	// `2Y` is `2new` -- the `y` spelling exists to pin the level
	if len(upper) == 2 && is_level(upper[0]) && upper[1] == 'Y' {
		return upper[0] - '0', true
	}
	return 0, false
}

// `^([1-7])([CDHSNMm*X])\+$` -- `2N+` is 2N or higher.
@(private = "file")
match_at_least :: proc(inner: string) -> (level: u8, suits: Suits, ok: bool) {
	if !strings.has_suffix(inner, "+") {
		return 0, {}, false
	}
	body := inner[:len(inner) - 1]
	if len(body) != 2 || !is_level(body[0]) {
		return 0, {}, false
	}
	switch body[1] {
	case 'X', '*':
		return body[0] - '0', ALL_SUITS, true
	case 'M':
		return body[0] - '0', MAJORS, true
	case 'm':
		return body[0] - '0', MINORS, true
	case 'C', 'D', 'H', 'S', 'N':
		return body[0] - '0', suit_from_char(body[1]), true
	}
	return 0, {}, false
}

// `^([1-7])[X*]$` -- any denomination at that level.
@(private = "file")
match_level_wildcard :: proc(inner: string) -> (level: u8, ok: bool) {
	if len(inner) == 2 && is_level(inner[0]) && (inner[1] == 'X' || inner[1] == '*') {
		return inner[0] - '0', true
	}
	return 0, false
}

// `^([1-7])?O([Mm])$`
@(private = "file")
match_other_class :: proc(inner: string) -> (level: u8, class: Suit_Class, ok: bool) {
	rest: string
	switch len(inner) {
	case 2:
		rest = inner
	case 3:
		if !is_level(inner[0]) {
			return 0, .None, false
		}
		level = inner[0] - '0'
		rest = inner[1:]
	case:
		return 0, .None, false
	}
	if rest[0] != 'O' {
		return 0, .None, false
	}
	switch rest[1] {
	case 'M':
		return level, .Other_Major, true
	case 'm':
		return level, .Other_Minor, true
	}
	return 0, .None, false
}

// `^\(?([1-7])([CDHSNMm*]+)\)?$`
@(private = "file")
match_bid :: proc(inner: string) -> (level: u8, denominations: string, ok: bool) {
	if len(inner) < 2 || !is_level(inner[0]) {
		return 0, "", false
	}
	denominations = inner[1:]
	for index in 0 ..< len(denominations) {
		switch denominations[index] {
		case 'C', 'D', 'H', 'S', 'N', 'M', 'm', '*':
		case:
			return 0, "", false
		}
	}
	return inner[0] - '0', denominations, true
}

//
// Small character helpers. `core:strings`'s case routines are unicode-aware and allocate; every
// token here is ASCII by construction.
//

@(private = "file")
is_level :: #force_inline proc "contextless" (ch: u8) -> bool {
	return ch >= '1' && ch <= '7'
}

@(private = "file")
is_suit_letter :: #force_inline proc "contextless" (ch: u8) -> bool {
	switch ch {
	case 'c', 'd', 'h', 's', 'C', 'D', 'H', 'S':
		return true
	}
	return false
}

@(private = "file")
to_upper :: #force_inline proc "contextless" (ch: u8) -> u8 {
	return ch >= 'a' && ch <= 'z' ? ch - 32 : ch
}

@(private = "file")
upper_ascii :: proc(text: string, buffer: []u8) -> string {
	if len(text) > len(buffer) {
		return text
	}
	for index in 0 ..< len(text) {
		buffer[index] = to_upper(text[index])
	}
	return string(buffer[:len(text)])
}

@(private = "file")
equal_fold :: proc(a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for index in 0 ..< len(a) {
		if to_upper(a[index]) != to_upper(b[index]) {
			return false
		}
	}
	return true
}
