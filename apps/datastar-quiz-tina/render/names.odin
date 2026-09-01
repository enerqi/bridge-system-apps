// Datastar attribute-key naming.
//
// HTML lowercases attribute names, so `data-bind:filterText` reaches datastar as
// `data-bind:filtertext` and binds a DIFFERENT signal from the `filterText` the server seeded.
// Datastar's answer is to write attribute keys in kebab-case and convert: `bind.ts` runs the key
// through `camel`, which is `kebab` then de-dashing.
//
// `kebab` also splits letter/digit boundaries, so `1c_opening` becomes the signal `1COpening` -- a
// slug cannot simply be assumed to survive the trip. And an underscore is a SEPARATOR, not a
// character, so `_answering` becomes `Answering`: an underscore-prefixed signal written in attribute
// KEY position is silently promoted from a local to one the browser uploads. That is why every
// underscore signal in the markup appears in VALUE position (`data-indicator="_answering"`).
//
// Getting this wrong is silent, which is why four implementations of one five-line transform exist
// -- here, `apps/datastar-quiz/render.py`, the Go port, and the load harness's own copy in
// `apps/dsquiz-perf/common/datastar.py` -- and why `testdata/topic_names.json` pins the result for
// every real topic name.
//
// Written as byte scans rather than five regex passes. The python memoises these because a yappi
// profile of a 60-user minute counted 37,868 calls to `datastar_kebab`; here the whole derived row
// set is built once per system instead, one level up (see `topic_choices`).
package render

import "core:strings"

// Datastar's `kebab`, which is what an attribute key goes through.
//
// The five passes, in order: split an uppercase run before a capitalised word (`HTTPServer` ->
// `HTTP-Server`), split lower-or-digit before upper, split letter before digits and digits before
// letter, collapse whitespace and underscore runs to a dash, then lowercase.
datastar_kebab :: proc(text: string, allocator := context.allocator) -> string {
	out := strings.builder_make(0, len(text) + 8, allocator)
	for index in 0 ..< len(text) {
		ch := text[index]

		if is_space_or_underscore(ch) {
			// A run collapses to ONE dash -- python's `re.sub(r"[\s_]+", "-", ...)` -- and a
			// leading one is emitted like any other. That is not an oversight: it is what turns
			// `_answering` into `-answering` and then `Answering`, promoting an underscore-prefixed
			// local signal into one the browser uploads. Suppressing it here would hide the trap
			// this transform exists to expose.
			if strings.builder_len(out) == 0 || last_byte(out) != '-' {
				strings.write_byte(&out, '-')
			}
			continue
		}

		if index > 0 {
			previous := text[index - 1]
			split :=
				(is_upper(previous) && is_upper(ch) && index + 1 < len(text) && is_lower(text[index + 1])) ||
				((is_lower(previous) || is_digit(previous)) && is_upper(ch)) ||
				(is_alpha(previous) && is_digit(ch)) ||
				(is_digit(previous) && is_alpha(ch))
			if split && strings.builder_len(out) > 0 && last_byte(out) != '-' {
				strings.write_byte(&out, '-')
			}
		}
		strings.write_byte(&out, to_lower(ch))
	}
	return strings.to_string(out)
}

// The name a kebab attribute key actually writes into the signal store.
datastar_camel :: proc(text: string, allocator := context.allocator) -> string {
	kebab := datastar_kebab(text, context.temp_allocator)
	out := strings.builder_make(0, len(kebab), allocator)
	upper_next := false
	for index in 0 ..< len(kebab) {
		if kebab[index] == '-' {
			upper_next = true
			continue
		}
		strings.write_byte(&out, upper_next ? to_upper(kebab[index]) : kebab[index])
		upper_next = false
	}
	return strings.to_string(out)
}

// The attribute form of a topic name: `data-bind:topics.<slug>`.
//
// Punctuation is dropped to a space BEFORE kebabbing, so `2/1 game force` slugs to `2-1-game-force`
// rather than keeping the slash.
topic_slug :: proc(name: string, allocator := context.allocator) -> string {
	stripped := strings.builder_make(0, len(name), context.temp_allocator)
	for index in 0 ..< len(name) {
		ch := name[index]
		keep := is_alpha(ch) || is_digit(ch) || is_space_or_underscore(ch) || ch == '-'
		strings.write_byte(&stripped, keep ? ch : ' ')
	}

	kebab := datastar_kebab(strings.to_string(stripped), context.temp_allocator)

	// collapse dash runs and trim the ends
	collapsed := strings.builder_make(0, len(kebab), context.temp_allocator)
	for index in 0 ..< len(kebab) {
		if kebab[index] == '-' && strings.builder_len(collapsed) > 0 && last_byte(collapsed) == '-' {
			continue
		}
		strings.write_byte(&collapsed, kebab[index])
	}
	slug := strings.trim(strings.to_string(collapsed), "-")
	if slug == "" {
		return strings.clone("topic", allocator)
	}
	return strings.clone(slug, allocator)
}

// The name that same binding writes into the signal store.
topic_signal_key :: proc(name: string, allocator := context.allocator) -> string {
	slug := topic_slug(name, context.temp_allocator)
	return datastar_camel(slug, allocator)
}

@(private = "file")
last_byte :: proc(builder: strings.Builder) -> u8 {
	text := strings.to_string(builder)
	return len(text) == 0 ? 0 : text[len(text) - 1]
}

@(private = "file")
is_upper :: #force_inline proc "contextless" (ch: u8) -> bool {
	return ch >= 'A' && ch <= 'Z'
}

@(private = "file")
is_lower :: #force_inline proc "contextless" (ch: u8) -> bool {
	return ch >= 'a' && ch <= 'z'
}

@(private = "file")
is_alpha :: #force_inline proc "contextless" (ch: u8) -> bool {
	return is_upper(ch) || is_lower(ch)
}

@(private = "file")
is_digit :: #force_inline proc "contextless" (ch: u8) -> bool {
	return ch >= '0' && ch <= '9'
}

@(private = "file")
is_space_or_underscore :: #force_inline proc "contextless" (ch: u8) -> bool {
	return ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' || ch == '_'
}

@(private = "file")
to_lower :: #force_inline proc "contextless" (ch: u8) -> u8 {
	return is_upper(ch) ? ch + 32 : ch
}

@(private = "file")
to_upper :: #force_inline proc "contextless" (ch: u8) -> u8 {
	return is_lower(ch) ? ch - 32 : ch
}
