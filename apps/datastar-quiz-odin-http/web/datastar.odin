// The Datastar wire format, written out by hand.
//
// Every other port of this quiz reaches for its language's SDK: `datastar-py` in the python,
// `datastar-go`, `datastar-rs`, and Tina's own `extensions/http/datastar` in the sibling Odin port.
// odin-http has none, so this file is it -- and it turns out to be about eighty lines, because the
// protocol is an SSE event with a fixed name and a handful of `data:` fields:
//
//	event: datastar-patch-elements
//	data: selector #app
//	data: mode inner
//	data: elements <div id="app">
//	data: elements   ...one `data: elements ` line per line of html...
//	data: elements </div>
//	(blank line)
//
// Two rules are the whole format. A payload is split on '\n' and EVERY line gets the prefix, because
// a bare newline inside `data:` would end the event. And `mode` is omitted when it is `outer`,
// `selector` when it is empty -- the defaults are on the client, and the bytes not sent are the
// point: the fat morph patch goes out ~180,000 times in a load run.
//
// Writing it here rather than binding an SDK also buys the thing Tina's port had to give up. There,
// each event is serialised straight into the connection's egress buffer through
// `reserve_body_exact`, which is exactly where a compressor would have to sit, so its SSE streams
// are identity-only. These events are built as bytes we own, so compressing them is a decision about
// encoder lifetime (see compress.odin) rather than a wall.
package web

import "core:io"
import "core:strings"

DATASTAR_EVENT_PATCH_ELEMENTS :: "datastar-patch-elements"
DATASTAR_EVENT_PATCH_SIGNALS :: "datastar-patch-signals"

// The client-side merge strategies. Same set and same names as every Datastar SDK; `Outer` is the
// protocol default and is never written on the wire.
Patch_Mode :: enum u8 {
	Outer,
	Inner,
	Replace,
	Prepend,
	Append,
	Before,
	After,
	Remove,
}

patch_mode_string :: proc(mode: Patch_Mode) -> string {
	switch mode {
	case .Outer:
		return "outer"
	case .Inner:
		return "inner"
	case .Replace:
		return "replace"
	case .Prepend:
		return "prepend"
	case .Append:
		return "append"
	case .Before:
		return "before"
	case .After:
		return "after"
	case .Remove:
		return "remove"
	}
	return "outer"
}

// One `datastar-patch-elements` event.
write_patch_elements :: proc(writer: io.Writer, elements, selector: string, mode: Patch_Mode) {
	io.write_string(writer, "event: " + DATASTAR_EVENT_PATCH_ELEMENTS + "\n")
	if selector != "" {
		io.write_string(writer, "data: selector ")
		io.write_string(writer, selector)
		io.write_byte(writer, '\n')
	}
	if mode != .Outer {
		io.write_string(writer, "data: mode ")
		io.write_string(writer, patch_mode_string(mode))
		io.write_byte(writer, '\n')
	}
	write_data_lines(writer, "elements", elements)
	io.write_byte(writer, '\n')
}

// One `datastar-patch-signals` event. The payload is a JSON object, always one line here, but it
// goes through the same splitter so a renderer that ever emits a pretty-printed one cannot break the
// stream silently.
write_patch_signals :: proc(writer: io.Writer, signals: string) {
	io.write_string(writer, "event: " + DATASTAR_EVENT_PATCH_SIGNALS + "\n")
	write_data_lines(writer, "signals", signals)
	io.write_byte(writer, '\n')
}

// `data: <name> <line>` for every line of the payload.
//
// An EMPTY payload writes nothing at all, which is what the callers rely on: an event with no
// `data:` line is not a valid patch, and `push_elements` refuses to queue one in the first place.
@(private = "file")
write_data_lines :: proc(writer: io.Writer, name, payload: string) {
	rest := payload
	for {
		newline := strings.index_byte(rest, '\n')
		line := newline < 0 ? rest : rest[:newline]
		io.write_string(writer, "data: ")
		io.write_string(writer, name)
		io.write_byte(writer, ' ')
		io.write_string(writer, line)
		io.write_byte(writer, '\n')
		if newline < 0 {
			break
		}
		rest = rest[newline + 1:]
	}
}
