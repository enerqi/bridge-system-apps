// Content encoding.
//
// # What is compressed, and what is not
//
// The static assets are compressed ONCE AT BOOT and held in both forms. They never change within a
// process, so compressing them per request would be paying quality-5 brotli for an answer that is
// always the same -- 678 KB of Bulma, every time somebody loads the page. This is the one place this
// port can beat the others outright rather than merely match them, and it costs a few hundred
// milliseconds of startup.
//
// The rendered document is compressed per request, because it carries the session's own state.
//
// The SSE streams are NOT compressed, and that is a real divergence from the comparison's ground
// rules rather than an oversight. The reason is structural: Tina's Datastar SDK serialises each
// event directly into the connection's egress buffer through `reserve_body_exact`, which is exactly
// where a compressor would have to sit. Compressing them means serialising the Datastar frames in
// this app instead of using the SDK for anything but `read_signals` -- doable, the wire format is a
// dozen lines, but it trades away the SDK that made this port cheap. It is recorded in README.md
// under "Deliberate divergences" and measured at identity until then.
//
// What is NOT in question is that the pacing survives compression, which is the property the ground
// rules actually care about: `tools/measure.py` reports "spread 599 ms over 7 chunks -- paced", and
// the encoder's own tests pin that a `.Flush` per event emits that event's bytes.
//go:build note -- this file compiles either way; `compress_whole` is the only entry point that does
// anything when the encoder is switched off, and it reports "did not compress" so every caller falls
// through to identity.
package web

import "../brotlienc"
import "base:runtime"
import "core:log"
import "core:strings"
import http "tina:src/extensions/http/server"

// One encoder arena and one output buffer PER SHARD, reused for every compressed response on it.
//
// One shard runs one handler at a time, so a single arena and a single buffer serve that whole
// shard -- the Go port needed a `sync.Pool` for the same job, and the shared-nothing model makes the
// pool a variable. `@(thread_local)` is what makes "per shard" true rather than aspirational: a Tina
// shard is an OS thread, and two shards compressing at the same instant must not share a bump arena.
//
// The cost of that is one lazy allocation per shard rather than one at boot: a shard cannot be
// reached before `tina_start`, and there is no boot moment on its own thread. `compression_ready`
// is therefore per shard too, and every entry point checks it.
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

// Give this shard its encoder memory. Idempotent, and safe to call on every request: it is a bool
// test after the first one.
//
// The allocator is the process heap rather than anything Tina owns, and it has to be: this runs on
// the shard's thread, the memory outlives the request that triggered it, and Tina's per-connection
// and per-call arenas are the wrong lifetime for both reasons.
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
		// The boot call to `compression_init` ran on the MAIN thread, and this memory is per shard --
		// so the shard that serves the first request has none yet. Idempotent and a bool test after
		// that, which is why it sits on the hot path rather than in a boot hook no shard has.
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
		// Compression that did not help is not applied: the response would be bigger AND cost the client
		// a decode.
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
	return strings.contains(string(http.header(request, "accept-encoding")), "br")
}

// Pick the form to send, and stage the headers that go with it.
//
// `Vary: Accept-Encoding` on every response, compressed or not: a cache that stored the identity
// form without it would then serve it to a client that asked for brotli, and vice versa.
choose_encoding :: proc(response: ^http.Response, request: ^http.Request, encoded: Encoded) -> []u8 {
	if http.header_set(response, "Vary", "Accept-Encoding") != .Staged {
		return encoded.identity
	}
	if len(encoded.brotli) == 0 || !wants_brotli(request) {
		return encoded.identity
	}
	if http.header_set(response, "Content-Encoding", "br") != .Staged {
		return encoded.identity
	}
	return encoded.brotli
}
