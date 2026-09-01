// Bindings to the C brotli encoder, driven by hand.
//
// Odin has no brotli and no deflate ENCODER anywhere -- `core:compress` decompresses only, and
// `vendor:` carries lz4. The comparison's ground rules ask every port to compress at brotli quality
// 5 with a 256-byte minimum, matching what Litestar's facade does, so the encoder is the C one.
//
// The library is built from `~/dev/brotli` by `just build-brotli` into `target/brotli/`. It is not
// vendored: it is somebody else's source, it builds in about ten seconds, and a `.a` in a notes
// repository would be an odd thing to find.
//
// # Why the allocator callbacks matter here
//
// `BrotliEncoderCreateInstance` takes an allocator, and this port passes one backed by Tina's own
// memory rather than letting the encoder call `malloc`. That is the whole point of running this
// experiment on Tina: the claim is that after boot there is no dynamic allocation, and a compressor
// is exactly the kind of component that quietly breaks such a claim. The Go port's heap profile
// found a brotli encoder allocated per SSE response holding 282 MB -- 81.6% of its live heap -- and
// the fix there was pooling plus a smaller window. Here the encoder cannot allocate outside the
// arena it is given.
package brotlienc

import "base:runtime"
import "core:c"

foreign import lib {"../target/brotli/brotlienc.lib", "../target/brotli/brotlicommon.lib"}

Encoder :: distinct rawptr

// `BROTLI_PARAM_*`, the ones this app sets.
Parameter :: enum c.int {
	Mode    = 0,
	Quality = 1,
	// The sliding window, as a power of two. 16 is 64 KB.
	LGWin   = 2,
	LGBlock = 3,
}

// `BROTLI_OPERATION_*`.
Operation :: enum c.int {
	Process = 0,
	Flush   = 1,
	Finish  = 2,
}

// Quality 5 is the knee, measured on this app's own 23.6 KB fat patch: the python's COMPARISON.md
// walks the curve and 5 is where the ratio stops improving faster than the CPU cost rises. Litestar
// is configured the same way, so this is parity rather than preference.
QUALITY :: 5

// A 64 KB window rather than the 4 MB default.
//
// This is the Go port's heap-profile fix, ported before it could become a bug again: brotli's ring
// buffer is sized from the window, and at the default it dominated the process's live memory. This
// app's largest response is ~24 KB, so a 64 KB window costs nothing in ratio.
LGWIN :: 16

// The smallest response worth compressing, matching Litestar's `minimum_size`. Below it the framing
// overhead and the CPU are not repaid -- and the paced SSE frames are mostly a few hundred bytes.
MINIMUM_SIZE :: 256

@(default_calling_convention = "c")
foreign lib {
	BrotliEncoderCreateInstance :: proc(alloc_func: Alloc_Func, free_func: Free_Func, opaque: rawptr) -> Encoder ---
	BrotliEncoderDestroyInstance :: proc(state: Encoder) ---
	BrotliEncoderSetParameter :: proc(state: Encoder, param: Parameter, value: u32) -> b32 ---
	BrotliEncoderCompressStream :: proc(state: Encoder, op: Operation, available_in: ^c.size_t, next_in: ^[^]u8, available_out: ^c.size_t, next_out: ^[^]u8, total_out: ^c.size_t) -> b32 ---
	BrotliEncoderHasMoreOutput :: proc(state: Encoder) -> b32 ---
	BrotliEncoderTakeOutput :: proc(state: Encoder, size: ^c.size_t) -> [^]u8 ---
	BrotliEncoderIsFinished :: proc(state: Encoder) -> b32 ---
}

Alloc_Func :: #type proc "c" (opaque: rawptr, size: c.size_t) -> rawptr
Free_Func :: #type proc "c" (opaque: rawptr, address: rawptr)

// The memory one encoder is allowed.
//
// Brotli's demand is not a constant: the ring buffer grows with the input, so it is the LARGEST
// thing this app compresses that sets the size. Measured here at quality 5 with a 64 KB window
// (`test_the_largest_asset_fits_the_arena`), high-water including the 6,976 bytes taken at create:
//
//     24 KB input (the fat morph)      ->   0.99 MB
//    128 KB input                      ->   1.82 MB
//    901 KB input (completed.jpeg, the largest asset)  ->  3.81 MB
//      2 MB input                      ->   6.80 MB
//
// 8 MB is that largest case with room for an asset twice its size. Beyond it the arena reports
// `spent`, `create`/`compress` fail, and the caller serves identity -- a bounded refusal rather
// than a reach for the heap, which is the whole reason the callbacks exist. It is also memory
// reserved at boot and never returned, so it is charged against the RSS number in RESULTS.md:
// 24 MB, the size while the encoder was being debugged, was a third of the process for nothing.
ARENA_SIZE :: 8 * 1024 * 1024

// What an encoder allocates from. One per compressed response.
//
// A bump arena with no free: brotli allocates a handful of blocks at creation and frees them all at
// destruction, so reclaiming individually would be bookkeeping nobody reads. `reset` is what returns
// the memory, and it happens between responses.
Arena :: struct {
	bytes: []u8,
	used:  int,
	// Set when an allocation did not fit. The encoder handles a null return by failing the stream,
	// which is what should happen -- but silently, so this is how the app finds out.
	spent: bool,
}

arena_alloc :: proc "c" (opaque: rawptr, size: c.size_t) -> rawptr {
	arena := cast(^Arena)opaque
	if arena == nil {
		return nil
	}
	// 16-byte alignment: brotli stores u64s and pointers in these blocks.
	aligned := (arena.used + 15) & ~int(15)
	wanted := int(size)
	if aligned + wanted > len(arena.bytes) {
		arena.spent = true
		return nil
	}
	arena.used = aligned + wanted
	return rawptr(&arena.bytes[aligned])
}

arena_free :: proc "c" (opaque: rawptr, address: rawptr) {
	// Nothing. See the note on `Arena`.
}

arena_reset :: proc(arena: ^Arena) {
	arena.used = 0
	arena.spent = false
}

// Create an encoder that allocates only from `arena`.
create :: proc(arena: ^Arena) -> (encoder: Encoder, ok: bool) {
	encoder = BrotliEncoderCreateInstance(arena_alloc, arena_free, rawptr(arena))
	if encoder == nil {
		return nil, false
	}
	if !BrotliEncoderSetParameter(encoder, .Quality, QUALITY) {
		BrotliEncoderDestroyInstance(encoder)
		return nil, false
	}
	if !BrotliEncoderSetParameter(encoder, .LGWin, LGWIN) {
		BrotliEncoderDestroyInstance(encoder)
		return nil, false
	}
	return encoder, true
}

destroy :: proc(encoder: Encoder) {
	if encoder != nil {
		BrotliEncoderDestroyInstance(encoder)
	}
}

// Feed `input` and take whatever comes out, appending it to `out`.
//
// `operation` is the whole protocol:
//   - `.Process` buffers, and may emit nothing at all
//   - `.Flush`   ends a block so everything fed so far is DECODABLE by the client. This is what an
//     SSE event needs: without it the paced frames sit in the encoder and arrive together,
//     which is exactly the thing the pacing exists to avoid.
//   - `.Finish`  writes the stream terminator. Skipping it is the other obvious failure: the Go port
//     hit `brotli: decoder failed` on every POST because the SDK's own compression flushed
//     but never closed.
compress :: proc(encoder: Encoder, input: []u8, operation: Operation, out: ^[dynamic]u8) -> bool {
	available_in := c.size_t(len(input))
	next_in: [^]u8 = len(input) > 0 ? raw_data(input) : nil

	for {
		// Taking the output rather than supplying a buffer: brotli hands back a pointer into its own
		// ring, which is one copy instead of two and needs no guess about the compressed size.
		available_out := c.size_t(0)
		next_out: [^]u8 = nil
		if !BrotliEncoderCompressStream(encoder, operation, &available_in, &next_in, &available_out, &next_out, nil) {
			return false
		}

		for BrotliEncoderHasMoreOutput(encoder) {
			size := c.size_t(0)
			chunk := BrotliEncoderTakeOutput(encoder, &size)
			if chunk == nil || size == 0 {
				break
			}
			append(out, ..chunk[:int(size)])
		}

		if available_in == 0 && !BrotliEncoderHasMoreOutput(encoder) {
			break
		}
	}
	return true
}

_ :: runtime
