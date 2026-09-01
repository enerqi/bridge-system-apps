// The five sounds, synthesised at boot.
//
// There are no audio files in this repo, in any of the four implementations: the whole set is about
// 20 KB of PCM built from sine waves during startup and served from memory. That is not a stunt --
// it means the deployment is one binary, and a sound can be changed by editing an envelope rather
// than by finding a sample with a licence.
//
// 8000 Hz, 8-bit unsigned mono. Deliberately cheap: these are UI blips, and at this rate the whole
// set costs less than one small PNG.
package sfx

import "base:runtime"
import "core:math"
import "core:strings"

SAMPLE_RATE :: 8000

// Silence sits at 128 in unsigned 8-bit PCM.
@(private = "file")
ZERO :: 128

// Peak amplitude, as a fraction of full scale. There is no volume control anywhere in the app -- the
// levels are baked in here, because setting `.volume` in the browser would need real JavaScript.
@(private = "file")
PEAK :: 0.33

// A linear fade at each end of a note. Without it the waveform starts and stops at a non-zero
// sample, which is a step discontinuity -- an audible click on every beat.
@(private = "file")
EDGE_SECONDS :: 0.004

NAMES :: [5]string{"correct", "wrong", "skip", "final", "tick"}

Sound :: struct {
	name:  string,
	bytes: []u8,
}

// The synthesised set, in `NAMES` order. Built once during boot and never freed.
sounds: []Sound

// Note frequencies, equal temperament.
@(private = "file")
G2 :: 98.00
@(private = "file")
G3 :: 196.00
@(private = "file")
C5 :: 523.25
@(private = "file")
E5 :: 659.25
@(private = "file")
G5 :: 783.99
@(private = "file")
B5 :: 987.77
@(private = "file")
C6 :: 1046.50
@(private = "file")
E6 :: 1318.51
@(private = "file")
G6 :: 1567.98

build :: proc(allocator := context.allocator) -> []Sound {
	names := NAMES
	out := make([]Sound, len(names), allocator)
	for name, index in names {
		out[index] = Sound {
			name  = name,
			bytes = synthesise(name, allocator),
		}
	}
	sounds = out
	return out
}

find :: proc(name: string) -> (sound: Sound, ok: bool) {
	for candidate in sounds {
		if candidate.name == name {
			return candidate, true
		}
	}
	return {}, false
}

@(private = "file")
synthesise :: proc(name: string, allocator: runtime.Allocator) -> []u8 {
	samples := make([dynamic]f64, 0, SAMPLE_RATE, context.temp_allocator)

	switch name {
	case "correct":
		// A rising two-note chime: the answer was right, and the interval says so before the toast
		// has finished rendering.
		note(&samples, E5, 0.09)
		note(&samples, B5, 0.16)

	case "wrong":
		// One low note with its own octave underneath, longer and slower to decay. Not harsh: a
		// wrong answer already costs points and shows a reveal, and a buzzer on top reads as
		// punishment.
		low := tone(G3, 0.22, decay = 4.0, gain = 1.0, allocator = context.temp_allocator)
		under := tone(G2, 0.22, decay = 4.0, gain = 0.5, allocator = context.temp_allocator)
		mix(&samples, low, under)

	case "skip":
		// A three-note arpeggio, because a milestone is the one thing here worth a flourish.
		note(&samples, C6, 0.07)
		note(&samples, E6, 0.07)
		note(&samples, G6, 0.20)

	case "final":
		// The finale: a major triad, then the octave with a fifth under it, decaying slowly.
		note(&samples, C5, 0.12)
		note(&samples, E5, 0.12)
		note(&samples, G5, 0.12)
		top := tone(C6, 0.45, decay = 3.0, gain = 1.0, allocator = context.temp_allocator)
		under := tone(G5, 0.45, decay = 3.0, gain = 0.5, allocator = context.temp_allocator)
		mix(&samples, top, under)

	case "tick":
		// The countdown tick -- and the reason it is a whole second long.
		//
		// The page plays this on a 100 ms interval, and `HTMLMediaElement.play()` on an element that
		// is ALREADY PLAYING is a no-op. So the trailing silence IS the rate limit: the sample's own
		// length spaces the ticks one second apart, with no timer, no counter and no state anywhere
		// in the page. Shortening it would make the quiz chatter ten times a second.
		note(&samples, 1200.0, 0.045, decay = 9.0)
		silence(&samples, 0.955)
	}

	return wav(samples[:], allocator)
}

// Append one note.
@(private = "file")
note :: proc(into: ^[dynamic]f64, frequency, seconds: f64, decay := 6.0, gain := 1.0) {
	count := int(seconds * SAMPLE_RATE)
	for index in 0 ..< count {
		append(into, sample_at(f64(index) / SAMPLE_RATE, frequency, seconds, decay, gain))
	}
}

@(private = "file")
silence :: proc(into: ^[dynamic]f64, seconds: f64) {
	count := int(seconds * SAMPLE_RATE)
	for _ in 0 ..< count {
		append(into, 0.0)
	}
}

// One note as its own buffer, for mixing.
@(private = "file")
tone :: proc(frequency, seconds: f64, decay := 6.0, gain := 1.0, allocator := context.allocator) -> []f64 {
	count := int(seconds * SAMPLE_RATE)
	out := make([]f64, count, allocator)
	for index in 0 ..< count {
		out[index] = sample_at(f64(index) / SAMPLE_RATE, frequency, seconds, decay, gain)
	}
	return out
}

// A decaying sine with a linear fade at each end.
@(private = "file")
sample_at :: proc(t, frequency, seconds, decay, gain: f64) -> f64 {
	envelope := math.exp(-decay * t / seconds)
	edge := min(1.0, t / EDGE_SECONDS, (seconds - t) / EDGE_SECONDS)
	return math.sin(2.0 * math.PI * frequency * t) * envelope * max(edge, 0.0) * gain
}

// Element-wise sum, appended. Ragged lengths are fine -- the shorter layer simply stops.
@(private = "file")
mix :: proc(into: ^[dynamic]f64, layers: ..[]f64) {
	longest := 0
	for layer in layers {
		longest = max(longest, len(layer))
	}
	for index in 0 ..< longest {
		total := 0.0
		for layer in layers {
			if index < len(layer) {
				total += layer[index]
			}
		}
		append(into, total)
	}
}

// A RIFF/WAVE header and the samples, quantised to unsigned 8-bit.
@(private = "file")
wav :: proc(samples: []f64, allocator: runtime.Allocator) -> []u8 {
	data_size := len(samples)
	out := strings.builder_make(0, 44 + data_size, allocator)

	strings.write_string(&out, "RIFF")
	write_u32_le(&out, u32(36 + data_size))
	strings.write_string(&out, "WAVE")

	strings.write_string(&out, "fmt ")
	write_u32_le(&out, 16) // PCM header size
	write_u16_le(&out, 1) // PCM, uncompressed
	write_u16_le(&out, 1) // mono
	write_u32_le(&out, SAMPLE_RATE)
	write_u32_le(&out, SAMPLE_RATE) // byte rate: rate * channels * bytes per sample
	write_u16_le(&out, 1) // block align
	write_u16_le(&out, 8) // bits per sample

	strings.write_string(&out, "data")
	write_u32_le(&out, u32(data_size))
	for value in samples {
		scaled := f64(ZERO) + value * PEAK * 127.0
		strings.write_byte(&out, u8(clamp(int(scaled), 0, 255)))
	}
	return transmute([]u8)strings.to_string(out)
}

@(private = "file")
write_u16_le :: proc(out: ^strings.Builder, value: u16) {
	strings.write_byte(out, u8(value))
	strings.write_byte(out, u8(value >> 8))
}

@(private = "file")
write_u32_le :: proc(out: ^strings.Builder, value: u32) {
	strings.write_byte(out, u8(value))
	strings.write_byte(out, u8(value >> 8))
	strings.write_byte(out, u8(value >> 16))
	strings.write_byte(out, u8(value >> 24))
}
