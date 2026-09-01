/// HTML escaping and the suit glyphs.
///
/// THE ESCAPER IS HAND-WRITTEN FOR ONE REASON: entity spelling. The jinja templates and Go's
/// `html/template` write `&lt;` and `&#34;`; Oxpecker's (excellent, `SearchValues`-vectorised)
/// encoder and Askama's both make different-but-equally-correct choices. This text is compared
/// against the other ports' output often enough that matching is worth twenty lines -- and the two
/// places it matters most, the signal payload and the fragments that go out over SSE, do not pass
/// through the view engine at all.
module DsQuiz.Render.Escape

open System
open System.Text

[<Literal>]
let Club = '♣'

[<Literal>]
let Diamond = '♦'

[<Literal>]
let Heart = '♥'

[<Literal>]
let Spade = '♠'

/// glyph -> bml css class. Same names and glyphs as `bml2html._SUIT`, so the colours defined in
/// `bml.css` are the colours here.
let private suitClass (ch: char) : string =
    match ch with
    | Club -> "ccolor"
    | Diamond -> "dcolor"
    | Heart -> "hcolor"
    | Spade -> "scolor"
    | _ -> ""

/// Escapes into a builder, using the same entities the jinja and Go templates emit.
let escapeInto (text: string) (out: StringBuilder) : unit =
    for ch in text do
        match ch with
        | '&' -> out.Append "&amp;" |> ignore
        | '<' -> out.Append "&lt;" |> ignore
        | '>' -> out.Append "&gt;" |> ignore
        | '"' -> out.Append "&#34;" |> ignore
        | '\'' -> out.Append "&#39;" |> ignore
        | _ -> out.Append ch |> ignore

/// Whether escaping would change anything -- the common case is that it would not, and a scan is
/// cheaper than a builder.
let private needsEscape (text: string) : bool =
    let mutable found = false

    for ch in text do
        match ch with
        | '&'
        | '<'
        | '>'
        | '"'
        | '\'' -> found <- true
        | _ -> ()

    found

let escape (text: string) : string =
    if not (needsEscape text) then
        text
    else
        let out = StringBuilder(text.Length + 16)
        escapeInto text out
        out.ToString()

/// Colours the suit glyphs: `♠` -> `<span class="scolor">♠</span>`.
///
/// The input is escaped first, so this is safe for anything -- including the bml descriptions, which
/// are corpus text rather than user input, and the auctions inside toast messages. A separate step
/// from the auction text because that function's output also travels through the engine's toast
/// strings, where markup would be escaped again.
let suits (text: string) : string =
    let escaped = escape text
    let mutable hasGlyph = false

    for ch in escaped do
        if suitClass ch <> "" then
            hasGlyph <- true

    if not hasGlyph then
        escaped
    else
        let out = StringBuilder(escaped.Length + 32)

        for ch in escaped do
            match suitClass ch with
            | "" -> out.Append ch |> ignore
            | klass ->
                out.Append("<span class=\"").Append(klass).Append("\">").Append(ch).Append "</span>"
                |> ignore

        out.ToString()
