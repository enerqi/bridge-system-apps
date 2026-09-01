/// Streaming datastar events, compressed.
///
/// # COMPRESSING AN SSE STREAM IS ITS OWN PROBLEM, and every ecosystem gets it wrong differently
///
/// Litestar compresses the stream and flushes the compressor per ASGI chunk, which is correct, and is
/// the behaviour the other ports have to match or the wire comparison is meaningless.
///
/// The Go SDK offers `WithCompression`, which flushes after every event but never CLOSES the
/// compressor, so the stream ends without its terminating block: `just dsperf smoke` failed every POST
/// there with `brotli: decoder failed`.
///
/// `tower-http`'s `CompressionLayer` makes the opposite choice and is explicit about it: its
/// `DefaultPredicate` skips `text/event-stream` outright. So a Rust app that simply adds the layer
/// silently ships UNCOMPRESSED streams -- safe, and worth a 5x wire-size advantage in the comparison it
/// exists to make.
///
/// **ASP.NET Core makes the same choice as tower-http, and quietly.** `text/event-stream` is absent
/// from `ResponseCompressionDefaults.MimeTypes` and the middleware supports no wildcards, so the
/// streams are never touched by it. There is nothing to switch off -- the risk here is the mirror
/// image, forgetting that the middleware covers nothing on these routes.
///
/// # WHY `BrotliEncoder` AND NOT `BrotliStream`
///
/// `BrotliStream`'s `CompressionLevel` constructors map `Optimal` to quality 4 and `SmallestSize` to
/// 11: QUALITY 5 IS UNREACHABLE through them, and quality 5 is what Litestar is pinned to and what the
/// other ports use. The struct encoder takes the quality directly, and it also gives explicit control
/// over the two operations an SSE stream needs and a `Stream` does not separate: flush after every
/// event, and one final block at the end.
///
/// # THE WINDOW IS LEFT AT 22, AND THAT IS A MEASURED DECISION
///
/// The Go port pinned brotli's window to 2^16 after a heap profile showed `ringBufferInitBuffer` at
/// 282 MB -- 81.6% of its live heap. Copying that into Rust was a mistake and it was measured: a small
/// window makes quality 5 re-run its match finder, costing 7.7x the CPU for 0.7% WORSE compression.
/// .NET's default window is 22, the same as the brotli crate's, so both arguments are named here and
/// left where the two ports agree.
module DsQuiz.Web.Sse

open System
open System.Buffers
open System.IO
open System.IO.Compression
open System.Text
open System.Threading
open System.Threading.Tasks
open Microsoft.AspNetCore.Http

/// Quality 5 is what Litestar is pinned to and is the knee: measured on this app's own fat patch, q6
/// costs 68% more time for 0.4% fewer bytes, q9 is 8x the CPU for 1%.
[<Literal>]
let Quality = 5

/// 22 is the default on both sides. See the module note for the 7.7x that pinning it lower cost.
[<Literal>]
let Window = 22

/// `PipeWriter.WriteAsync` returns a `ValueTask<FlushResult>`; nothing here reads the result, and
/// `ignore` on a `ValueTask` is a bug (it never awaits), so this says what is meant.
let inline private ignoreValueTask (value: ValueTask<'a>) =
    task {
        let! _ = value
        return ()
    }

/// Which encoding a stream will use.
[<StructuralEquality; NoComparison>]
type Encoding =
    | Identity
    | Brotli
    | Gzip

let headerValue (encoding: Encoding) : string =
    match encoding with
    | Identity -> ""
    | Brotli -> "br"
    | Gzip -> "gzip"

/// Server priority, brotli first -- the same order Litestar negotiates in.
///
/// q-values that DISABLE an encoding (`br;q=0`) are honoured; the finer preference ordering is not,
/// because the server has an opinion and this is the one the comparison pins.
let negotiate (acceptEncoding: string) : Encoding =
    if String.IsNullOrEmpty acceptEncoding then
        Identity
    else
        let mutable brotli = false
        let mutable gzip = false

        for part in acceptEncoding.Split ',' do
            let fields = part.Split ';'
            let name = fields[0].Trim()

            let disabled =
                fields
                |> Array.skip 1
                |> Array.exists (fun parameter ->
                    let squeezed = parameter.Replace(" ", "").Replace("\t", "")

                    squeezed.Equals("q=0", StringComparison.OrdinalIgnoreCase)
                    || squeezed.Equals("q=0.0", StringComparison.OrdinalIgnoreCase)
                )

            if not disabled then
                if name.Equals("br", StringComparison.OrdinalIgnoreCase) then
                    brotli <- true
                elif name.Equals("gzip", StringComparison.OrdinalIgnoreCase) then
                    gzip <- true

        if brotli then Brotli
        elif gzip then Gzip
        else Identity

/// The body side of one SSE response: takes event text, puts bytes on the wire.
///
/// ONE ENCODER PER RESPONSE, NO POOL, and that half is the experiment this port runs: a brotli encoder
/// allocates its window and hash tables up front, and the Go port paid 506 MB of resident set at 400
/// users before pooling them. Here the encoder is disposed at the end of the response and its memory
/// goes back to the allocator *then* -- but the allocator is a GC, so "goes back" means "becomes
/// garbage", and whether that is enough is a question only a load run can answer. RESULTS.md reports
/// it.
///
/// Gzip has no struct encoder in the BCL, so that branch wraps a `GZipStream` over a growable buffer.
/// It is the fallback for a client that refuses brotli, and nothing in the harness exercises it hard.
[<Sealed>]
type Writer(response: HttpResponse, encoding: Encoding) =
    let mutable brotli = Unchecked.defaultof<BrotliEncoder>
    let mutable gzipBuffer: MemoryStream = null
    let mutable gzip: GZipStream = null

    do
        match encoding with
        | Brotli -> brotli <- new BrotliEncoder(Quality, Window)
        | Gzip ->
            gzipBuffer <- new MemoryStream()
            gzip <- new GZipStream(gzipBuffer, CompressionLevel.Fastest, leaveOpen = true)
        | Identity -> ()

    /// Writes UTF-8 straight into the response's `PipeWriter` -- the same thing the datastar SDK does
    /// for an uncompressed stream, and the reason the identity path has no intermediate buffer.
    member private _.WriteRaw(utf8: ReadOnlySpan<byte>) =
        let writer = response.BodyWriter
        let span = writer.GetSpan utf8.Length
        utf8.CopyTo span
        writer.Advance utf8.Length

    /// Compresses `source` and writes whatever the encoder is willing to give up, then flushes it.
    ///
    /// The `DestinationTooSmall` loop is not defensive: `BrotliEncoder.Flush` documents that a flush
    /// happens only once the source is depleted AND the destination has room for what is left, so a
    /// single call can legitimately do half the job.
    member private this.WriteBrotli(source: ReadOnlySpan<byte>) =
        let mutable remaining = source
        let size = max 1024 (BrotliEncoder.GetMaxCompressedLength source.Length)
        let buffer = ArrayPool<byte>.Shared.Rent size

        try
            let mutable going = true

            while going do
                let mutable consumed = 0
                let mutable written = 0

                let status =
                    brotli.Compress(remaining, buffer.AsSpan(), &consumed, &written, isFinalBlock = false)

                if written > 0 then
                    this.WriteRaw(ReadOnlySpan(buffer, 0, written))

                remaining <- remaining.Slice consumed
                going <- status = OperationStatus.DestinationTooSmall || not remaining.IsEmpty

            let mutable flushing = true

            while flushing do
                let mutable written = 0
                let status = brotli.Flush(buffer.AsSpan(), &written)

                if written > 0 then
                    this.WriteRaw(ReadOnlySpan(buffer, 0, written))

                flushing <- status = OperationStatus.DestinationTooSmall
        finally
            ArrayPool<byte>.Shared.Return buffer

    member private this.WriteGzip(utf8: byte array) =
        gzip.Write(utf8, 0, utf8.Length)
        gzip.Flush()
        this.DrainGzipBuffer()

    member private this.DrainGzipBuffer() =
        if gzipBuffer.Length > 0L then
            let bytes = gzipBuffer.GetBuffer()
            this.WriteRaw(ReadOnlySpan(bytes, 0, int gzipBuffer.Length))
            gzipBuffer.SetLength 0L
            gzipBuffer.Position <- 0L

    /// Encodes one event and puts it on the wire.
    ///
    /// EVERY PUSH FLUSHES, and `FlushAsync` on the `PipeWriter` is the part that matters: `GetSpan` and
    /// `Advance` only fill the pipe's buffer, so without the flush a paced answer stream would arrive
    /// in one burst at the end -- which is exactly what `tools/measure.py` asserts against by checking
    /// that the frames spread over more than 300 ms.
    member this.PushAsync(text: string, cancellationToken: CancellationToken) =
        task {
            let utf8 = Text.Encoding.UTF8.GetBytes text

            match encoding with
            | Identity -> this.WriteRaw(ReadOnlySpan utf8)
            | Brotli -> this.WriteBrotli(ReadOnlySpan utf8)
            | Gzip -> this.WriteGzip utf8

            let! _ = response.BodyWriter.FlushAsync cancellationToken
            return ()
        }

    /// Finishes the stream: the terminating block, then a last flush.
    ///
    /// THIS IS THE STEP THE GO SDK OMITS, and the reason a client that decodes the whole body at once
    /// rejected every answer it sent.
    member this.FinishAsync(cancellationToken: CancellationToken) =
        task {
            match encoding with
            | Identity -> ()
            | Brotli ->
                let buffer = ArrayPool<byte>.Shared.Rent 1024

                try
                    let mutable going = true

                    while going do
                        let mutable consumed = 0
                        let mutable written = 0

                        let status =
                            brotli.Compress(
                                ReadOnlySpan<byte>.Empty,
                                buffer.AsSpan(),
                                &consumed,
                                &written,
                                isFinalBlock = true
                            )

                        if written > 0 then
                            this.WriteRaw(ReadOnlySpan(buffer, 0, written))

                        going <- status = OperationStatus.DestinationTooSmall
                finally
                    ArrayPool<byte>.Shared.Return buffer
            | Gzip ->
                // disposing the GZipStream is what writes the final deflate block and the gzip trailer
                gzip.Dispose()
                this.DrainGzipBuffer()

            let! _ = response.BodyWriter.FlushAsync cancellationToken
            return ()
        }

    interface IDisposable with
        member _.Dispose() =
            match encoding with
            | Brotli -> brotli.Dispose()
            | Gzip ->
                if gzip <> null then
                    gzip.Dispose()

                if gzipBuffer <> null then
                    gzipBuffer.Dispose()
            | Identity -> ()

/// Whole-response compression, for the document and anything else that is not a stream.
///
/// The framework's `ResponseCompression` middleware cannot express this app's ground rule: its brotli
/// provider exposes only `Level` (whose default is `Fastest`, i.e. quality 1) and it has no minimum-size
/// option at all. "Quality 5, above 256 bytes" is what every other port runs, so it is done here.
///
/// Below the floor brotli costs more bytes than it saves and the CPU is pure waste; above it the page is
/// ~23 KB of markup that compresses about 5:1.
[<Literal>]
let MinCompressSize = 256

let private compressWhole (encoding: Encoding) (utf8: byte array) : byte array =
    use buffer = new MemoryStream(utf8.Length / 3 + 64)

    (match encoding with
     | Brotli ->
         // Only `Quality` is settable here -- `BrotliCompressionOptions` exposes no window property, and
         // its window is the same 22 the struct encoder defaults to, which is the value this port wants
         // anyway (see the module note).
         let options = BrotliCompressionOptions(Quality = Quality)
         use brotli = new BrotliStream(buffer, options, true)
         brotli.Write(utf8, 0, utf8.Length)
     | _ ->
         use gzip = new GZipStream(buffer, CompressionLevel.Fastest, true)
         gzip.Write(utf8, 0, utf8.Length))

    buffer.ToArray()

let writeCompressedAsync (ctx: HttpContext) (utf8: byte array) : System.Threading.Tasks.Task =
    task {
        let encoding =
            if utf8.Length < MinCompressSize then
                Identity
            else
                negotiate (string ctx.Request.Headers.AcceptEncoding)

        let bytes =
            match encoding with
            | Identity -> utf8
            | _ ->
                ctx.Response.Headers.ContentEncoding <- headerValue encoding
                ctx.Response.Headers.Vary <- "Accept-Encoding"
                compressWhole encoding utf8

        do!
            ctx.Response.BodyWriter.WriteAsync(ReadOnlyMemory bytes, ctx.RequestAborted)
            |> ignoreValueTask
    }
    :> Task

/// Opens a datastar SSE response: the headers, then the writer that carries its events.
///
/// `Cache-Control: no-cache` and no `Content-Length`; `Connection: keep-alive` only on HTTP/1.1, where
/// the header means anything.
let start (ctx: HttpContext) : Writer =
    let encoding = negotiate (string ctx.Request.Headers.AcceptEncoding)
    let response = ctx.Response
    response.StatusCode <- 200
    response.Headers.ContentType <- "text/event-stream"
    response.Headers.CacheControl <- "no-cache"

    if ctx.Request.Protocol = HttpProtocol.Http11 then
        response.Headers.Connection <- "keep-alive"

    match headerValue encoding with
    | "" -> ()
    | value -> response.Headers.ContentEncoding <- value

    new Writer(response, encoding)
