// The encoder, exercised end to end -- including the two mistakes the Go port made.
package brotlienc

import "core:compress/gzip"
import "core:math/rand"
import "core:testing"

@(private = "file")
new_arena :: proc(t: ^testing.T) -> ^Arena {
	arena := new(Arena, context.temp_allocator)
	arena.bytes = make([]u8, ARENA_SIZE, context.temp_allocator)
	return arena
}

@(test)
test_the_encoder_allocates_only_from_its_arena :: proc(t: ^testing.T) {
	arena := new_arena(t)
	encoder, ok := create(arena)
	testing.expect(t, ok, "the encoder did not start")
	defer destroy(encoder)

	testing.expect(t, arena.used > 0, "the encoder allocated nothing, so it is not using the arena")
	testing.expect(t, !arena.spent, "the arena was exhausted at quality 5 with a 64KB window")
	testing.expectf(t, arena.used <= ARENA_SIZE, "the encoder wanted %d bytes of %d", arena.used, ARENA_SIZE)
}

@(test)
test_a_finished_stream_is_smaller_and_terminated :: proc(t: ^testing.T) {
	arena := new_arena(t)
	encoder, ok := create(arena)
	testing.expect(t, ok)
	defer destroy(encoder)

	// The repetitive markup this app sends is the reason compression is worth it at all.
	source := make([dynamic]u8, 0, 8192, context.temp_allocator)
	for _ in 0 ..< 200 {
		append(&source, ..transmute([]u8)string(`<div class="candidate button">1C</div>`))
	}

	out := make([dynamic]u8, 0, 4096, context.temp_allocator)
	testing.expect(t, compress(encoder, source[:], .Finish, &out))
	testing.expect(t, bool(BrotliEncoderIsFinished(encoder)), "the stream was never terminated")
	testing.expectf(
		t,
		len(out) < len(source) / 4,
		"%d bytes compressed to %d, expected far better on repetitive markup",
		len(source),
		len(out),
	)
}

// A flush has to make everything fed so far decodable, or the paced SSE frames sit in the encoder
// and arrive together -- which is the failure the pacing exists to prevent.
@(test)
test_a_flush_emits_the_bytes_fed_so_far :: proc(t: ^testing.T) {
	arena := new_arena(t)
	encoder, ok := create(arena)
	testing.expect(t, ok)
	defer destroy(encoder)

	out := make([dynamic]u8, 0, 1024, context.temp_allocator)

	frame := transmute([]u8)string("event: datastar-patch-elements\ndata: elements <div>1</div>\n\n")
	testing.expect(t, compress(encoder, frame, .Flush, &out))
	after_first := len(out)
	testing.expect(t, after_first > 0, "a flush produced no output at all")

	testing.expect(t, compress(encoder, frame, .Flush, &out))
	testing.expect(t, len(out) > after_first, "the second flush produced nothing, so frames would arrive bunched")
}

// Never finishing is the other failure mode, and it is the one the Go port shipped: the SDK's own
// compression flushed after every event but never closed the stream, so every POST failed with
// `brotli: decoder failed`.
@(test)
test_flushing_without_finishing_leaves_the_stream_open :: proc(t: ^testing.T) {
	arena := new_arena(t)
	encoder, ok := create(arena)
	testing.expect(t, ok)
	defer destroy(encoder)

	out := make([dynamic]u8, 0, 1024, context.temp_allocator)
	testing.expect(t, compress(encoder, transmute([]u8)string("hello"), .Flush, &out))
	testing.expect(t, !bool(BrotliEncoderIsFinished(encoder)), "a flush must not terminate the stream")

	testing.expect(t, compress(encoder, nil, .Finish, &out))
	testing.expect(t, bool(BrotliEncoderIsFinished(encoder)), "finish must terminate the stream")
}

// The arena is sized for the LARGEST thing the app compresses, and that is an asset rather than a
// response: `completed.jpeg` is 901,082 bytes. Brotli's ring buffer grows with the input, so this is
// the test that would catch a bigger asset being added without ARENA_SIZE moving with it -- the
// symptom otherwise is silent: `spent` is set, compression fails, and every client quietly gets
// identity.
@(test)
test_the_largest_asset_fits_the_arena :: proc(t: ^testing.T) {
	LARGEST_ASSET :: 901_082

	arena := new_arena(t)
	encoder, ok := create(arena)
	testing.expect(t, ok)
	defer destroy(encoder)

	// Incompressible bytes, which is what a jpeg is: the encoder still buffers all of it.
	source := make([]u8, LARGEST_ASSET, context.temp_allocator)
	for i in 0 ..< len(source) {
		source[i] = u8(rand.int31_max(256))
	}

	out := make([dynamic]u8, 0, LARGEST_ASSET, context.temp_allocator)
	testing.expect(t, compress(encoder, source, .Finish, &out))
	testing.expect(t, !arena.spent, "the arena ran out on the largest asset this app serves")
	testing.expectf(t, arena.used <= ARENA_SIZE, "high-water %d bytes of an %d byte arena", arena.used, ARENA_SIZE)
}

@(test)
test_an_arena_too_small_fails_rather_than_reaching_for_the_heap :: proc(t: ^testing.T) {
	arena := new(Arena, context.temp_allocator)
	arena.bytes = make([]u8, 1024, context.temp_allocator) // nowhere near enough

	encoder, ok := create(arena)
	defer if ok {destroy(encoder)}

	testing.expect(t, arena.spent, "the arena should have recorded that it ran out")
	testing.expect(t, !ok, "the encoder should refuse to start rather than allocate elsewhere")
}

_ :: gzip
