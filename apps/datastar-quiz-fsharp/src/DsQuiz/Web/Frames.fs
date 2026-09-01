/// The datastar SSE frames, as text.
///
/// # WHY THIS EXISTS, GIVEN THAT THE SDK WRITES FRAMES PERFECTLY WELL
///
/// `StarFederation.Datastar.FSharp` is this port's headline: the SSE writer is first-party library code
/// in the app's own language, and it is good code -- UTF-8 written straight into the response's
/// `IBufferWriter<byte>`, byte-literal prefixes, `StringTokenizer` line splitting, `[<Struct>]` option
/// records. Every one of its writers takes an `HttpResponse` and writes to `httpResponse.BodyWriter`.
///
/// THAT IS EXACTLY THE PROBLEM: THERE IS NO SEAM FOR COMPRESSION. The ground rule this comparison runs
/// under is brotli quality 5 on every response including the streams (the python's litestar compresses
/// and flushes per chunk), and a writer that goes directly to the response's pipe cannot be given a
/// compressor to go through. The Rust port hand-rolled its stream for the same reason, one layer down.
///
/// So the frames are built here as text and handed to `Sse.Writer`, which compresses and flushes them.
/// The format is small and pinned by the SDK's own `Consts`, and `FramesTests` checks this module's
/// output against what the SDK writes for the same event -- so "hand-rolled" does not mean "guessed".
///
/// THERE IS A SECOND WAY, and P5 measures it rather than this file arguing about it: ASP.NET Core lets a
/// request REPLACE its response body feature (`IHttpResponseBodyFeature`), which is how the framework's
/// own compression middleware works. Wrapping the body in a compressing stream would let the SDK write
/// its frames while brotli sits underneath, at the cost of a `Stream` hop and `BrotliStream`'s coarser
/// quality control. Both paths are real; the A/B belongs in RESULTS.md, not in a comment.
module DsQuiz.Web.Frames

open System.Text

/// How a patch is applied. The SDK's default is `Outer`, so that one is never written out.
[<StructuralEquality; NoComparison>]
type PatchMode =
    | Inner
    | Append

let private modeText (mode: PatchMode) : string =
    match mode with
    | Inner -> "inner"
    | Append -> "append"

/// `data: <name> <value>`, once per line of `value` -- a multi-line payload is several data lines, which
/// is what the SSE format requires and what the SDK's `splitLinesToSegments` does.
let private dataLines (name: string) (value: string) (out: StringBuilder) : unit =
    let mutable start = 0
    let mutable wrote = false

    while start <= value.Length do
        let stop =
            match value.IndexOfAny([| '\n'; '\r' |], start) with
            | -1 -> value.Length
            | found -> found

        if stop > start then
            out.Append("data: ").Append(name).Append(' ') |> ignore
            out.Append(value, start, stop - start).Append('\n') |> ignore
            wrote <- true

        start <- if stop = value.Length then value.Length + 1 else stop + 1

    // An empty payload still needs its line: `elements` with nothing after it is how a patch says
    // "replace the contents of this selector with nothing", which is what clearing the toasts is.
    if not wrote then
        out.Append("data: ").Append(name).Append(" \n") |> ignore

/// A `datastar-patch-elements` frame.
let patchElements (html: string) (selector: string) (mode: PatchMode) : string =
    let out = StringBuilder(html.Length + 96)
    out.Append("event: datastar-patch-elements\n") |> ignore
    out.Append("data: selector ").Append(selector).Append('\n') |> ignore
    out.Append("data: mode ").Append(modeText mode).Append('\n') |> ignore
    dataLines "elements" html out
    out.Append('\n').ToString()

/// A `datastar-patch-signals` frame.
let patchSignals (signals: string) : string =
    let out = StringBuilder(signals.Length + 64)
    out.Append("event: datastar-patch-signals\n") |> ignore
    dataLines "signals" signals out
    out.Append('\n').ToString()
