/// The auction text: suit letters become glyphs, the `-->` joiner becomes the arrow separator, and
/// markdown link targets are dropped.
///
/// These rules are copied from `apps/quiz/quiz_app.py` rather than shared -- that module imports
/// panel. It is presentation-only, and the copy is the one piece of deliberate duplication in this
/// port, as it is in the other four.
module DsQuiz.Render.Auction

open System
open System.Text

open DsQuiz.Render.Escape

/// Silly, but a button strips excess internal whitespace, so the separator carries its own.
[<Literal>]
let private InvisibleSeparator = '⁣'

let private bidSeparator =
    String(InvisibleSeparator, 4) + "‣" + String(InvisibleSeparator, 4)

/// The python's `_suit_replace_regex` pass: `\d([CDHS]|N(?!T))+`, a digit followed by one or more
/// denominations, with the suit letters becoming glyphs and a bare `N` becoming `NT`.
///
/// Hand-written rather than a regex because of the negative lookahead, which is what keeps an
/// already-spelled `1NT` from becoming `1NTT`.
let private suitReplaceInBids (text: string) : string =
    let out = StringBuilder text.Length
    let mutable index = 0

    while index < text.Length do
        let ch = text[index]

        let runEnd =
            if Char.IsAsciiDigit ch then
                let mutable e = index + 1
                let mutable scanning = true

                while scanning && e < text.Length do
                    match text[e] with
                    | 'C'
                    | 'D'
                    | 'H'
                    | 'S' -> e <- e + 1
                    | 'N' when e + 1 >= text.Length || text[e + 1] <> 'T' -> e <- e + 1
                    | _ -> scanning <- false

                e
            else
                index

        if runEnd > index + 1 then
            out.Append ch |> ignore

            for i in index + 1 .. runEnd - 1 do
                let glyph =
                    match text[i] with
                    | 'C' -> string Club
                    | 'D' -> string Diamond
                    | 'H' -> string Heart
                    | 'S' -> string Spade
                    | _ -> "NT"

                out.Append glyph |> ignore

            index <- runEnd
        else
            // not necessarily ascii: descriptions carry prose
            out.Append ch |> ignore
            index <- index + 1

    out.ToString()

/// Replaces `C `/`D `/`H `/`S ` at a word boundary with the glyph -- the python's four `\b` regexes.
let private wordSuits (text: string) : string =
    let out = StringBuilder text.Length
    let mutable index = 0

    while index < text.Length do
        let ch = text[index]

        let isLetter =
            match ch with
            | 'C'
            | 'D'
            | 'H'
            | 'S' -> true
            | _ -> false

        let atBoundary =
            index = 0 || not (Char.IsLetterOrDigit text[index - 1] || text[index - 1] = '_')

        if isLetter && atBoundary && index + 1 < text.Length && text[index + 1] = ' ' then
            let glyph =
                match ch with
                | 'C' -> Club
                | 'D' -> Diamond
                | 'H' -> Heart
                | _ -> Spade

            out.Append(glyph).Append ' ' |> ignore
            index <- index + 2
        else
            out.Append ch |> ignore
            index <- index + 1

    out.ToString()

/// One pass over the text applying whichever of the pairs matches at each position.
///
/// The python chains `str.Replace` calls, which is one pass over the whole string each; one pass with
/// a small table is the same answer for a fraction of the copying, and this runs on every candidate
/// of every question.
let private replaceEach (pairs: (string * string) array) (text: string) : string =
    let out = StringBuilder text.Length
    let mutable index = 0

    while index < text.Length do
        let mutable matched = false

        for from, replacement in pairs do
            if
                not matched
                && from.Length <= text.Length - index
                && String.CompareOrdinal(text, index, from, 0, from.Length) = 0
            then
                out.Append replacement |> ignore
                index <- index + from.Length
                matched <- true

        if not matched then
            out.Append text[index] |> ignore
            index <- index + 1

    out.ToString()

/// Drops `(#anchor)` markdown link targets.
let private stripLinkTargets (text: string) : string =
    let out = StringBuilder text.Length
    let mutable rest = text
    let mutable finished = false

    while not finished do
        let start = rest.IndexOf("(#", StringComparison.Ordinal)
        let last = rest.LastIndexOf ')'

        if start < 0 || last < 0 || last < start then
            out.Append rest |> ignore
            finished <- true
        else
            out.Append(rest, 0, start) |> ignore
            rest <- rest.Substring(last + 1)

    out.ToString()

let private shorthandPairs = [| "!c", "♣"; "!d", "♦"; "!h", "♥"; "!s", "♠" |]

let private spacedPairs =
    [| " C ", " ♣ "; " D ", " ♦ "; " H ", " ♥ "; " S ", " ♠ " |]

let private pluralPairs = [| "Cs", "♣s"; "Ds", "♦s"; "Hs", "♥s"; "Ss", "♠s" |]

/// Turns one auction (or one description) into the text the card shows.
let emojiTextAuction (auction: string) : string =
    let text =
        // superfluous (pass); better fixed in the data source, or by making all opposition bids
        // explicit
        if
            auction.AsSpan().Count '(' = 1
            && auction.AsSpan().Count ')' = 1
            && auction.Contains("(Pass)", StringComparison.Ordinal)
        then
            auction.Replace("(Pass)", bidSeparator)
        else
            auction

    text
    |> suitReplaceInBids
    |> replaceEach shorthandPairs
    |> replaceEach spacedPairs
    |> wordSuits
    |> replaceEach pluralPairs
    |> _.Replace("-->", bidSeparator)
    |> _.Replace("--", "-")
    |> _.Replace("[", "")
    |> _.Replace("]", "")
    |> stripLinkTargets
