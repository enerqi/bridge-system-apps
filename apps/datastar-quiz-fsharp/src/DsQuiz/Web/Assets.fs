/// The static assets, embedded in the assembly and PRE-COMPRESSED AT BOOT.
///
/// Embedded rather than read from disk so the published binary is the deployment: the python app
/// resolves its corpus and assets from the script's own location and chdirs to parse them, and neither
/// trick survives `dotnet publish` into an arbitrary directory.
///
/// Pre-compressing at startup is the Odin ports' trick and it is worth taking: the stylesheets and
/// `datastar.js` are the same bytes for every visitor, so brotli-ing them per request is work done
/// thousands of times for one answer. The two Odin ports measure ~300 ms of startup to save 999 KB of
/// repeated compression; here it is the same deal, and it happens while the corpus is being prepared
/// anyway. A request then picks identity or brotli from a table.
///
/// THE QUALITY IS 5, THE SAME AS THE STREAMS, AND THAT IS MEASURED. The first version used 11 on the
/// reasoning that a one-off cost at boot is free for bytes served for the life of the process. It is not
/// free, and it is not close (9 assets, 1,973 KB):
///
///     quality   saved     compress   boot
///     0 (off)     0 KB       4 ms    333 ms
///     5         930 KB      25 ms    340 ms
///     9         935 KB      96 ms    417 ms
///     11        951 KB    1484 ms   1793 ms
///
/// Quality 5 takes 98% of the saving for 1.7% of the time. Quality 11 costs 59x as long for the last
/// 21 KB, and it dominated the whole startup -- which is a bad deploy and also drowns out the codegen
/// columns this port exists to measure. `DSQUIZ_ASSET_BROTLI` sets it; 0 turns pre-compression off
/// entirely, which is the "what did this actually buy" control.
module DsQuiz.Web.Assets

open System
open System.Collections.Generic
open System.IO
open System.IO.Compression
open System.Reflection

/// One asset, in both encodings.
[<NoEquality; NoComparison>]
type Asset =
    {
        Path: string
        ContentType: string
        Identity: byte array
        /// `Array.empty` when brotli made it no smaller -- a tiny file compresses to more than itself,
        /// and shipping that would be a lie about the wire cost.
        Brotli: byte array
    }

let private contentTypeFor (name: string) : string =
    match Path.GetExtension(name).ToLowerInvariant() with
    | ".css" -> "text/css; charset=utf-8"
    | ".js" -> "text/javascript; charset=utf-8"
    | ".map" -> "application/json; charset=utf-8"
    | ".jpeg"
    | ".jpg" -> "image/jpeg"
    | ".png" -> "image/png"
    | ".svg" -> "image/svg+xml"
    | ".ico" -> "image/x-icon"
    | _ -> "application/octet-stream"

/// The brotli quality the assets are pre-compressed at. 0 skips pre-compression entirely.
let quality =
    match Environment.GetEnvironmentVariable "DSQUIZ_ASSET_BROTLI" with
    | null
    | "" -> 5
    | value ->
        match Int32.TryParse value with
        | true, parsed -> Math.Clamp(parsed, 0, 11)
        | _ -> 5

let private compress (bytes: byte array) : byte array =
    if quality = 0 then
        Array.empty
    else
        use compressed = new MemoryStream(bytes.Length / 3 + 64)

        (let options = BrotliCompressionOptions(Quality = quality)
         use brotli = new BrotliStream(compressed, options, true)
         brotli.Write(bytes, 0, bytes.Length))

        let out = compressed.ToArray()
        // only keep it if it actually won
        if out.Length < bytes.Length then out else Array.empty

let private read (assembly: Assembly) (resource: string) : byte array =
    use stream = assembly.GetManifestResourceStream resource
    use buffer = new MemoryStream()
    stream.CopyTo buffer
    buffer.ToArray()

/// Everything under `static/` and `media/`, loaded and compressed once.
///
/// The key is the request path as the routes see it (`static/app.css`), which is the logical name the
/// project file gives each embedded resource -- so adding a stylesheet is adding a file, with nothing
/// to register here.
let load () : System.Collections.Generic.Dictionary<string, Asset> =
    let assembly = Assembly.GetExecutingAssembly()
    let assets = Dictionary<string, Asset>(StringComparer.Ordinal)

    for resource in assembly.GetManifestResourceNames() do
        if
            resource.StartsWith("static/", StringComparison.Ordinal)
            || resource.StartsWith("media/", StringComparison.Ordinal)
        then
            let bytes = read assembly resource

            assets[resource] <-
                { Path = resource
                  ContentType = contentTypeFor resource
                  Identity = bytes
                  Brotli = compress bytes }

    assets

/// What the startup line reports: how many assets, and how many bytes the pre-compression saved.
let savings (assets: Dictionary<string, Asset>) : struct (int * int * int) =
    let mutable identity = 0
    let mutable compressed = 0

    for entry in assets do
        identity <- identity + entry.Value.Identity.Length

        compressed <-
            compressed
            + (if entry.Value.Brotli.Length > 0 then
                   entry.Value.Brotli.Length
               else
                   entry.Value.Identity.Length)

    struct (assets.Count, identity, identity - compressed)
