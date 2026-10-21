// The bidding quiz as a WebAssembly module: the server, moved into the page.
//
// Every package but this one is the tina port's, imported through the `quiz` collection rather than
// copied -- `bids`, `bidfilter`, `corpus`, `engine`, `session`, `render` and `sfx`, unchanged. What
// is here replaces `web/`: the same route builders, answering requests that never leave the browser.
//
// The page's `fetch` is intercepted by `host/host.js`, which hands each request to `qz_request` and
// turns the SCRIPT that comes back into the Datastar SSE stream a server would have sent -- pauses
// included. Datastar itself is the published v1.0.2, unchanged, so the markup `render` writes works
// exactly as it does against a server.
//
// The CORPUS IS NOT IN THE MODULE. The page carries it as JSON beside the module and `host.js` hands
// it over system by system (`qz_add_system`, then `qz_start`). That is what makes one build of this
// module a TEMPLATE: the notes workbench generates a quiz for any `.bml` file by writing a different
// corpus into the same page, with no compiler involved.
//
// One player, one browser tab: there is no session store and no cookie, only one session per variant,
// made on first use. Memory is the wasm heap, and the request's strings go to the temp allocator,
// which is freed at the start of the next request.
package main

import "base:runtime"
import "core:fmt"
import "core:strings"
import "quiz:corpus"
import "quiz:engine"
import "quiz:render"
import "quiz:session"
import "quiz:sfx"

// The mount point the rendered markup uses for its own URLs. Not a real path anywhere: `host.js`
// recognises it in a request and in an asset URL, and never lets either reach the network.
PREFIX :: "/__quiz"

loaded_corpus: corpus.Corpus
topic_choices: [][]render.Topic_Choice
sounds: []sfx.Sound

// One session per variant, index-aligned with `loaded_corpus.systems`.
sessions: []^session.Session

// The response to the last request. Lives until the next one; `host.js` copies it out at once.
result: strings.Builder

// The page's original context, kept so every export runs with the same allocators.
@(private)
global_context: runtime.Context

// The systems' JSON, as `host.js` hands it over. Kept for the life of the module.
system_sources: [dynamic]string

main :: proc() {
	global_context = context
	result = strings.builder_make(0, 64 * 1024)
	sounds = sfx.build()
}

// One system's exporter JSON. Copied: the bytes arrive in temp memory.
@(export)
qz_add_system :: proc "c" (data: [^]u8, size: i32) {
	context = global_context
	append(&system_sources, strings.clone(string(data[:size])))
}

// Parse the systems handed over and build the filter index. Returns 0 when the corpus is unusable.
@(export)
qz_start :: proc "c" () -> i32 {
	context = global_context
	ok: bool
	loaded_corpus, ok = corpus.load_sources(system_sources[:])
	if !ok {
		fmt.eprintln("quiz: the corpus did not load")
		return 0
	}
	topic_choices = make([][]render.Topic_Choice, len(loaded_corpus.systems))
	for &system, index in loaded_corpus.systems {
		topic_choices[index] = quizzable_topics(&system, render.build_topic_choices(&system))
	}
	session.register_systems(loaded_corpus.systems)
	sessions = make([]^session.Session, len(loaded_corpus.systems))
	return 1
}

//
// The exports. `host.js` is the only caller.
//

// Somewhere to write a request of `size` bytes. Temp memory: it is freed by the next request, and
// `qz_request` is always called straight after.
@(export)
qz_alloc :: proc "c" (size: i32) -> rawptr {
	context = global_context
	free_all(context.temp_allocator)
	bytes, _ := make([]u8, int(size), context.temp_allocator)
	return raw_data(bytes)
}

// Answer one request. The request is `METHOD\nPATH\nQUERY\nCOOKIE\nBODY`, the body last because it
// is the one part that can hold a newline. Returns the response's length; `qz_result` points at it.
@(export)
qz_request :: proc "c" (data: [^]u8, size: i32) -> i32 {
	context = global_context
	text := string(data[:size])
	request: Request
	request.method, text = cut_line(text)
	request.path, text = cut_line(text)
	request.query, text = cut_line(text)
	request.cookie, text = cut_line(text)
	request.body = text

	strings.builder_reset(&result)
	handle(request, &result)
	return i32(strings.builder_len(result))
}

@(export)
qz_result :: proc "c" () -> rawptr {
	return raw_data(result.buf)
}

// The sounds, synthesised at boot exactly as the servers do. `host.js` turns each into a blob URL.
@(export)
qz_sound_count :: proc "c" () -> i32 {
	return i32(len(sounds))
}

@(export)
qz_sound_name :: proc "c" (index: i32, size: ^i32) -> rawptr {
	name := sounds[index].name
	size^ = i32(len(name))
	return raw_data(name)
}

@(export)
qz_sound_bytes :: proc "c" (index: i32, size: ^i32) -> rawptr {
	bytes := sounds[index].bytes
	size^ = i32(len(bytes))
	return raw_data(bytes)
}

/*
The picker offers only the topics there is something to quiz on: each topic's name is a filter (the
filter language resolves topic names), and a topic stays if that filter is USABLE - it selects enough
auctions to fill a question, as the filter box itself requires before it narrows the quiz.

This is what lets a quiz carry a generic set of topics (the notes workbench adds its defaults to every
quiz it generates) without showing "Preempts" for a file that has none: the matcher is here, so the
choice is made here. A topic left out is still a word the filter box understands.
*/
@(private = "file")
quizzable_topics :: proc(system: ^corpus.System, choices: []render.Topic_Choice) -> []render.Topic_Choice {
	kept := make([dynamic]render.Topic_Choice, 0, len(choices))
	for choice in choices {
		if corpus.filter_usable(corpus.check_filter(system, choice.name, engine.MAX_DIFFICULTY)^) {
			append(&kept, choice)
		}
	}
	return kept[:]
}

@(private = "file")
cut_line :: proc(text: string) -> (line: string, rest: string) {
	at := strings.index_byte(text, '\n')
	if at < 0 {
		return text, ""
	}
	return text[:at], text[at + 1:]
}
