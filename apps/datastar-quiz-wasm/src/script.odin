// The response: a script of patches and pauses, written in the Datastar wire format.
//
// What `host.js` gets back from `qz_request` is one of three things, told apart by the first byte:
//
//   N              nothing to do -- the server's 204
//   D<html>        a whole document, for the index page
//   S<sse>         an SSE body. A pause is a NUL, the milliseconds, and another NUL, between events;
//                  `host.js` splits on NUL and waits out every odd field. HTML never contains a NUL.
//
// Writing the SSE here rather than in the host keeps the wire format in one place, next to the code
// that decides what to send -- as the servers' Datastar SDKs do.
package main

import "core:encoding/json"
import "core:strings"

Patch_Mode :: enum u8 {
	Outer,
	Inner,
	Append,
	Remove,
}

Step_Kind :: enum u8 {
	Patch_Elements,
	Patch_Signals,
	Pause,
}

Step :: struct {
	kind:     Step_Kind,
	html:     string,
	selector: string,
	mode:     Patch_Mode,
	pause_ms: int,
}

Script :: struct {
	steps: [dynamic]Step,
}

// An EMPTY payload is dropped rather than pushed, so a toast that renders nothing contributes its
// pause and nothing else -- the same rule as the tina port's `push_elements`, kept for the same
// reason: the toast script's last entry is a pause with no text.
push_elements :: proc(script: ^Script, html: string, selector: string = "", mode: Patch_Mode = .Inner) {
	if html == "" && mode != .Remove {
		return
	}
	append(&script.steps, Step{kind = .Patch_Elements, html = html, selector = selector, mode = mode})
}

push_signals :: proc(script: ^Script, json_text: string) {
	append(&script.steps, Step{kind = .Patch_Signals, html = json_text})
}

push_pause :: proc(script: ^Script, seconds: f64) {
	if seconds <= 0 {
		return
	}
	append(&script.steps, Step{kind = .Pause, pause_ms = int(seconds * 1000)})
}

// Emptying a slot is replacing it with an empty copy of itself, attributes included.
EMPTY_TOASTS :: `<div class="toasts" id="toasts" aria-live="polite"></div>`
EMPTY_SFX :: `<div id="sfx" hidden aria-hidden="true"></div>`
EMPTY_TOPICS_STATUS :: `<div id="topics-status" class="filter-status"></div>`

clear_toasts :: proc(script: ^Script) {
	push_elements(script, EMPTY_TOASTS, "#toasts", .Outer)
}

clear_sfx :: proc(script: ^Script) {
	push_elements(script, EMPTY_SFX, "#sfx", .Outer)
}

clear_topics_status :: proc(script: ^Script) {
	push_elements(script, EMPTY_TOPICS_STATUS, "#topics-status", .Outer)
}

write_no_content :: proc(out: ^strings.Builder) {
	strings.write_byte(out, 'N')
}

write_script :: proc(out: ^strings.Builder, script: ^Script) {
	if len(script.steps) == 0 {
		write_no_content(out)
		return
	}
	strings.write_byte(out, 'S')
	for step in script.steps {
		switch step.kind {
		case .Patch_Elements:
			strings.write_string(out, "event: datastar-patch-elements\n")
			if step.selector != "" {
				strings.write_string(out, "data: selector ")
				strings.write_string(out, step.selector)
				strings.write_byte(out, '\n')
			}
			if step.mode != .Outer {
				strings.write_string(out, "data: mode ")
				strings.write_string(out, mode_name(step.mode))
				strings.write_byte(out, '\n')
			}
			write_data_lines(out, "elements ", step.html)
			strings.write_byte(out, '\n')
		case .Patch_Signals:
			strings.write_string(out, "event: datastar-patch-signals\n")
			write_data_lines(out, "signals ", step.html)
			strings.write_byte(out, '\n')
		case .Pause:
			strings.write_byte(out, 0)
			strings.write_int(out, step.pause_ms)
			strings.write_byte(out, 0)
		}
	}
}

// One `data:` line per line of payload: an SSE field cannot hold a newline.
@(private = "file")
write_data_lines :: proc(out: ^strings.Builder, key: string, payload: string) {
	rest := payload
	for {
		at := strings.index_byte(rest, '\n')
		line := at < 0 ? rest : rest[:at]
		strings.write_string(out, "data: ")
		strings.write_string(out, key)
		strings.write_string(out, strings.trim_right(line, "\r"))
		strings.write_byte(out, '\n')
		if at < 0 {
			break
		}
		rest = rest[at + 1:]
	}
}

@(private = "file")
mode_name :: proc(mode: Patch_Mode) -> string {
	switch mode {
	case .Outer:
		return "outer"
	case .Inner:
		return "inner"
	case .Append:
		return "append"
	case .Remove:
		return "remove"
	}
	return "outer"
}

//
// Reading what the page sent
//

// Malformed signals are not an error: they read as nothing uploaded, as on the server.
read_signals :: proc(payload: string, into: ^Uploaded_Signals) -> bool {
	return json.unmarshal_string(payload, into, allocator = context.temp_allocator) == nil
}

// One value from a query string, percent-decoded. Datastar puts a GET's signals in `?datastar=`.
query_value :: proc(query: string, key: string) -> string {
	rest := query
	for len(rest) > 0 {
		amp := strings.index_byte(rest, '&')
		pair := amp < 0 ? rest : rest[:amp]
		rest = amp < 0 ? "" : rest[amp + 1:]
		equals := strings.index_byte(pair, '=')
		if equals < 0 || pair[:equals] != key {
			continue
		}
		return percent_decode(pair[equals + 1:])
	}
	return ""
}

// `core:net` has one of these, but `core:net` does not build for js_wasm32. A malformed escape is
// kept as it is rather than failing the whole value.
@(private = "file")
percent_decode :: proc(text: string) -> string {
	out := strings.builder_make(0, len(text), context.temp_allocator)
	for index := 0; index < len(text); index += 1 {
		ch := text[index]
		if ch == '+' {
			strings.write_byte(&out, ' ')
			continue
		}
		if ch == '%' && index + 2 < len(text) {
			high, high_ok := hex_value(text[index + 1])
			low, low_ok := hex_value(text[index + 2])
			if high_ok && low_ok {
				strings.write_byte(&out, high << 4 | low)
				index += 2
				continue
			}
		}
		strings.write_byte(&out, ch)
	}
	return strings.to_string(out)
}

@(private = "file")
hex_value :: proc(ch: u8) -> (value: u8, ok: bool) {
	switch ch {
	case '0' ..= '9':
		return ch - '0', true
	case 'a' ..= 'f':
		return ch - 'a' + 10, true
	case 'A' ..= 'F':
		return ch - 'A' + 10, true
	}
	return 0, false
}
