// Content encoding.
//
// # What is compressed, and what is not
//
// The static assets are compressed ONCE AT BOOT and held in both forms. They never change within a
// process, so compressing them per request would be paying quality-5 brotli for an answer that is
// always the same -- 678 KB of Bulma, every time somebody loads the page.
//
// The rendered document is compressed per request, because it carries the session's own state, and
// ONLY for a client that asked: compressing unconditionally and then choosing is the same answer for
// the browser and a different one for the machine.
//
// The SSE streams are NOT compressed, and that is the same deliberate divergence the sibling Tina
// port records -- for a different reason, which is worth stating because it is the interesting one.
// There, the SDK serialises each event straight into the connection's egress buffer, so there is
// nowhere for a compressor to sit. Here the events are bytes this app owns (`datastar.odin`), so the
// wall is not structural: it is the ENCODER'S LIFETIME. A brotli stream that flushes per event has
// to hold its encoder for the length of the choreography, ~2.5 seconds of pauses, and this app's
// encoder is backed by an 8 MB arena. One per in-flight answer is the Go port's 282 MB line
// rediscovered from the other side. Fixing it properly means a small pool of encoders sized against
// concurrency rather than one per response, which is a phase of its own and is recorded in
// README.md rather than half-done here.
//
// What is NOT in question is that the pacing survives compression, which is the property the ground
// rules actually care about: `tools/measure.py` reports the frames arriving spread out rather than
// in one burst.
package web

import "../brotlienc"
import "base:runtime"
import "core:log"
import "core:strings"
import http "odinhttp:."

// One encoder arena and one output buffer PER THREAD, reused for every compressed response on it.
//
// `@(thread_local)` rather than a lock: an odin-http server thread owns its event loop and runs one
// handler at a time, so an encoder per thread is exactly enough and never contended. The Go port
// needs a `sync.Pool` for the same job.
@(private = "file")
@(thread_local)
encoder_arena: brotlienc.Arena

@(private = "file")
@(thread_local)
scratch: [dynamic]u8

// A static asset in both forms.
Encoded :: struct {
	identity: []u8,
	brotli:   []u8, // empty when compression did not help, or the asset is below the minimum
}

@(thread_local)
compression_ready: bool

// Give this thread its encoder memory. Idempotent, and safe to call on every request: it is a bool
// test after the first one.
//
// The allocator is the process heap rather than the connection arena, and it has to be: this memory
// outlives the request that triggered it.
compression_init :: proc() {
	if compression_ready {
		return
	}
	allocator := runtime.heap_allocator()
	encoder_arena.bytes = make([]u8, brotlienc.ARENA_SIZE, allocator)
	scratch = make([dynamic]u8, 0, 128 * 1024, allocator)
	compression_ready = true
}

// Compress a whole buffer in one shot: create, feed, finish, destroy.
//
// `.Finish` in the same call as the data is what makes this a complete, decodable stream -- the
// failure the Go port shipped was flushing without ever finishing, which every client rejects.
compress_whole :: proc(input: []u8, allocator := context.allocator) -> (out: []u8, ok: bool) {
	when !BROTLI_ENABLED {
		return nil, false
	} else {
		if len(input) < brotlienc.MINIMUM_SIZE {
			return nil, false
		}
		// The boot call to `compression_init` ran on the MAIN thread and this memory is per thread,
		// so the server thread that takes the first request has none yet. Idempotent and a bool test
		// after that, which is why it sits on the hot path rather than in a boot hook.
		compression_init()
		brotlienc.arena_reset(&encoder_arena)
		encoder, created := brotlienc.create(&encoder_arena)
		if !created {
			log.warn("the brotli encoder would not start; serving identity")
			return nil, false
		}
		defer brotlienc.destroy(encoder)

		clear(&scratch)
		if !brotlienc.compress(encoder, input, .Finish, &scratch) {
			return nil, false
		}
		// Compression that did not help is not applied: the response would be bigger AND cost the
		// client a decode.
		if len(scratch) >= len(input) {
			return nil, false
		}

		copied := make([]u8, len(scratch), allocator)
		copy(copied, scratch[:])
		return copied, true
	}
}

// Pre-compress an asset at boot.
encode_asset :: proc(identity: []u8, allocator := context.allocator) -> Encoded {
	compressed, ok := compress_whole(identity, allocator)
	return Encoded{identity = identity, brotli = ok ? compressed : nil}
}

// Does this request want brotli?
//
// A plain substring test on `Accept-Encoding`. Not a full quality-value parse: the only thing this
// app does with the header is choose between two encodings it already holds, and no client sends
// `br;q=0` in practice. If one did, it would get identity, which is always correct.
wants_brotli :: proc(request: ^http.Request) -> bool {
	value, _ := http.headers_get_unsafe(request.headers, "accept-encoding")
	return strings.contains(value, "br")
}

// Send a body in whichever form this client asked for, compressing it now.
//
// `Vary: Accept-Encoding` on every response, compressed or not: a cache that stored the identity
// form without it would then serve it to a client that asked for brotli, and vice versa.
respond_encoded :: proc(request: ^http.Request, response: ^http.Response, body: []u8, content_type: string) {
	http.headers_set_unsafe(&response.headers, "vary", "accept-encoding")
	http.headers_set_unsafe(&response.headers, "content-type", content_type)
	response.status = .OK

	out := body
	if wants_brotli(request) {
		if compressed, ok := compress_whole(body, request_arena(response)); ok {
			http.headers_set_unsafe(&response.headers, "content-encoding", "br")
			out = compressed
		}
	}
	http.body_set(response, out)
	http.respond(response)
}

// Send a body already held in both forms.
respond_prepared :: proc(
	request: ^http.Request,
	response: ^http.Response,
	encoded: Encoded,
	content_type: string,
	cache_control: string,
) {
	http.headers_set_unsafe(&response.headers, "vary", "accept-encoding")
	http.headers_set_unsafe(&response.headers, "content-type", content_type)
	http.headers_set_unsafe(&response.headers, "cache-control", cache_control)
	response.status = .OK

	out := encoded.identity
	if len(encoded.brotli) > 0 && wants_brotli(request) {
		http.headers_set_unsafe(&response.headers, "content-encoding", "br")
		out = encoded.brotli
	}
	http.body_set(response, out)
	http.respond(response)
}
