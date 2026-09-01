/// The sound effects, synthesised at startup. No audio files in the repo, and no audio library.
///
/// Five short WAVs -- a chime for a right answer, a thud for a wrong one, an arpeggio when a milestone
/// pays for a skip, a fanfare at the finale, and a tick for the last seconds of the countdown. They
/// are built from `sin` and a hand-written RIFF header, which means the repo carries no binary assets,
/// no licence question about somebody's sample pack, and no build step.
///
/// 8 kHz, 8-bit, mono, deliberately. These are blips heard once through laptop speakers; the fidelity
/// that costs bytes here buys nothing. The whole set is ~20 KB and is fetched only if the player turns
/// sound on -- the `<audio>` elements have no `src` until then.
///
/// TWO THINGS WORTH KNOWING
///
///  * **The tick's length is its rate limit.** `data-on-interval` runs at 100 ms, so a tick fired from
///    it would be a 10 Hz buzz. `HTMLMediaElement.play()` on an element that is ALREADY playing is a
///    no-op, so `tick` is a 45 ms blip followed by silence out to a full second: the sample's own
///    duration is what spaces the ticks, and no timer state has to be kept anywhere.
///  * **Nothing here is louder than it needs to be.** There is no volume control (that would need real
///    JavaScript), so the peak amplitude is baked in at a third of full scale and the envelopes decay
///    fast.
module DsQuiz.Sfx

open System

[<Literal>]
let private SampleRate = 8000

/// 8-bit WAV is UNSIGNED, centred on 128 -- a signed reading of it is the classic "why does it click".
[<Literal>]
let private Zero = 128

/// Peak amplitude, as a fraction of full scale. Quiet on purpose: no volume control exists.
[<Literal>]
let private Peak = 0.33

/// Fade applied to the first and last few milliseconds of every note. Without it the waveform starts
/// and ends on a discontinuity, which is heard as a click on top of the note.
[<Literal>]
let private EdgeSeconds = 0.004

/// One sine tone with an exponential decay, as floats in [-1, 1].
let private note (frequency: float) (seconds: float) (decay: float) (gain: float) : float array =
    let count = int (float SampleRate * seconds)

    Array.init
        count
        (fun index ->
            let t = float index / float SampleRate
            let envelope = if seconds <> 0.0 then exp (-decay * t / seconds) else 0.0
            let edge = min 1.0 (min (t / EdgeSeconds) ((seconds - t) / EdgeSeconds))
            sin (2.0 * Math.PI * frequency * t) * envelope * max edge 0.0 * gain
        )

let private silence (seconds: float) : float array =
    Array.zeroCreate<float> (int (float SampleRate * seconds))

/// Sums layers of equal-or-different length (a chord, or a note over a tail).
let private mix (layers: float array array) : float array =
    let length = layers |> Array.fold (fun longest layer -> max longest layer.Length) 0
    let out = Array.zeroCreate<float> length

    for layer in layers do
        for index in 0 .. layer.Length - 1 do
            out[index] <- out[index] + layer[index]

    out

let private join (parts: float array array) : float array = Array.concat parts

/// PCM bytes with a RIFF header, CLIPPED rather than wrapped -- a wrapped overflow is a loud crack.
let private encodeWav (samples: float array) : byte array =
    let frames =
        samples
        |> Array.map (fun value ->
            // `int` truncates toward zero, which is what python's int() does
            byte (Math.Clamp(Zero + int (value * Peak * 127.0), 0, 255))
        )

    let out = ResizeArray<byte>(44 + frames.Length)

    let ascii (text: string) =
        out.AddRange(Text.Encoding.ASCII.GetBytes text)

    let u32 (value: int) =
        out.AddRange(BitConverter.GetBytes(uint32 value))

    let u16 (value: int) =
        out.AddRange(BitConverter.GetBytes(uint16 value))

    ascii "RIFF"
    u32 (36 + frames.Length)
    ascii "WAVE"
    ascii "fmt "
    u32 16 // PCM header length
    u16 1 // PCM
    u16 1 // mono
    u32 SampleRate
    u32 SampleRate // byte rate: 1 channel x 1 byte
    u16 1 // block align
    u16 8 // bits per sample
    ascii "data"
    u32 frames.Length
    out.AddRange frames
    out.ToArray()

/// The five WAVs, built once at boot so the first player to turn sound on does not pay for it. Handed
/// straight to the response body and never mutated.
let private sounds =
    lazy
        ( // A rising pair says "that went up"; the fifth is the interval that reads as resolved rather
         // than merely different. Short, because it plays under the first toast. E5 -> B5.
         let correct = join [| note 659.25 0.09 6.0 1.0; note 987.77 0.16 6.0 1.0 |]

         // Down, and low enough to be a different KIND of sound rather than a sadder version of the
         // same one. A touch of the octave below gives it a body the pure tone lacks. G3 + G2.
         let wrong = mix [| note 196.00 0.22 4.0 1.0; note 98.00 0.22 4.0 0.5 |]

         // A skip is EARNED -- three notes up the major triad, brighter than the answer chime, because
         // it is the rarer event and it competes with the gauge sweep for attention. C6 E6 G6.
         let skip =
             join [| note 1046.50 0.07 6.0 1.0; note 1318.51 0.07 6.0 1.0; note 1567.98 0.20 6.0 1.0 |]

         // The finale, once per quiz: the same triad with a held root on top.
         let finalFanfare =
             join
                 [| note 523.25 0.12 6.0 1.0
                    note 659.25 0.12 6.0 1.0
                    note 783.99 0.12 6.0 1.0
                    mix [| note 1046.50 0.45 3.0 1.0; note 783.99 0.45 3.0 0.5 |] |]

         // The countdown. See the module note: the trailing silence is the rate limit.
         let tick = join [| note 1200.0 0.045 9.0 1.0; silence 0.955 |]

         [| "correct", encodeWav correct
            "wrong", encodeWav wrong
            "skip", encodeWav skip
            "final", encodeWav finalFanfare
            "tick", encodeWav tick |])

/// One synthesised WAV by name.
let tryGet (name: string) : byte array voption =
    let mutable found = ValueNone

    for key, bytes in sounds.Value do
        if key = name then
            found <- ValueSome bytes

    found

/// Builds them all now, at boot.
let warm () : unit = sounds.Value |> ignore

/// How many bytes the whole set takes, for the startup line.
let totalBytes () : int =
    sounds.Value |> Array.sumBy (fun (_, bytes) -> bytes.Length)
