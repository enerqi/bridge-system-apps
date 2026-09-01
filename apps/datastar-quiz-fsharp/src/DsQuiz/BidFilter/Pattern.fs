/// The bidding-tree prefix filter's PATTERN LANGUAGE: an F# port of the matching half of
/// `apps/quiz/bidfilter.py`, by way of the Go port's `internal/bidfilter/pattern.go`.
///
/// It turns the quiz's messy auction strings (e.g. `["1C (Pass) 1H"; "2D"; "2S"]`, with opponents in
/// parens, `!x` suit shorthand, and multi-suit bids like `2DHS`) into canonical positions, and
/// matches an auction prefix against a user pattern like `1D-1M-1N`, where suit-class shortcuts
/// expand:
///
///     M -> majors  {H, S}      N -> notrump {N}
///     m -> minors  {C, D}
///
/// So `1D-1M-1N` matches both `1D-1H-1N` and `1D-1S-1N`. Opponent bids are written in parens in a
/// pattern too, e.g. `1H-(X)-2H`.
///
/// A filter string may hold several comma-separated entries, matched as an OR. Each entry is either
/// a bid pattern or the name of a *topic* -- a pre-composed collection of patterns, which in this
/// port arrives with the exported corpus rather than from a toml.
module DsQuiz.BidFilter.Pattern

open System
open System.Text.RegularExpressions

open DsQuiz.Bids

/// Whose call a pattern position asks for. Python writes this as `Optional[bool]`, where None means
/// "don't care"; the tri-state is the same thing said in a type.
[<StructuralEquality; NoComparison>]
type Side =
    /// python's None: don't care
    | EitherSide
    /// python's False: ours
    | OurSide
    /// python's True: the opponents'
    | TheirSide

let inline sideOf (byOpponent: bool) : Side =
    if byOpponent then TheirSide else OurSide

/// What kind of call a pattern position asks for. Narrower than `Bids.Kind` on purpose: a pattern
/// can only ask for the four real call kinds or for anything at all, so a token like `cue` or `next`
/// is a pattern error rather than a pattern.
[<StructuralEquality; NoComparison>]
type PatternKind =
    | PatBid
    | PatPass
    | PatDouble
    | PatRedouble
    /// `*` / `any`: any call at this position
    | PatAny

/// One alternative at one position of a pattern.
[<Struct; StructuralEquality; NoComparison>]
type BidPattern =
    {
        /// 0 = any level
        Level: int
        /// allowed suits; `Suits.Empty` = any suit
        SuitClass: Suits
        Kind: PatternKind
        Side: Side
    }

/// One position in an auction: the alternatives allowed there.
///
/// Usually one. `/` writes more than one -- `2D/2H`, `3S/4C` -- which is a single call the author
/// wrote as a choice, *not* two consecutive calls. Alternatives differing only in suit could equally
/// be written `2DH`; ones spanning levels (`3S/4C`) have no single-token form, which is why a
/// position is a set of patterns rather than one widened pattern.
[<NoEquality; NoComparison>]
type CallPattern = { Alternatives: BidPattern array }

/// A whole bid pattern: one `CallPattern` per position.
type Pattern = CallPattern array

/// One place in an auction: the calls it allows. One for an ordinary call, several for `2D/2H`.
type Position = Call array

/// A parsed auction: one `Position` per call.
type Auction = Position array

/// The concrete auctions one written auction stands for -- one unless correlated suit classes bind
/// (see `Relative.expandCorrelated`) or a relative token like `next` resolves several ways.
type Variants = Auction array

// ---------------------------------------------------------------------------------------------
// text
// ---------------------------------------------------------------------------------------------

let private re pattern : System.Text.RegularExpressions.Regex = Regex(pattern, RegexOptions.Compiled)

let private wsRE = re @"\s+"
let private dashRE = re @"\s*-+\s*"

/// One dash is enough to separate calls -- bml's `--` is accepted too, and both normalise to a
/// single `-`.
let private splitRE = re @"-+|\s+"

let private openParenRE = re @"\(\s+"
let private closeParenRE = re @"\s+\)"

let private levelWildcardPatternRE = re @"^([1-7])[X*]$"
let private otherClassPatternRE = re @"^([1-7])?O([Mm])$"
let private levelSuitsPatternRE = re @"^([1-7])?([CDHSNMm]+)$"

/// Tidies raw user input: strip ends, collapse whitespace runs, and remove whitespace that is
/// decorative rather than a token separator (inside brackets, around `--` and around the comma
/// entry separator).
let normaliseFilterText (text: string) : string =
    let collapsed = wsRE.Replace(text.Trim(), " ")
    let dashed = dashRE.Replace(collapsed, "-")
    let opened = openParenRE.Replace(dashed, "(")
    let closed = closeParenRE.Replace(opened, ")")

    // rebuild from the entries so empty ones (`,,` or a trailing `,`) vanish
    closed.Split ','
    |> Array.map (fun part -> part.Trim())
    |> Array.filter (fun part -> part <> "")
    |> String.concat ", "

/// Splits normalised filter text on commas into non-empty entries.
let splitEntries (text: string) : string array =
    (normaliseFilterText text).Split ','
    |> Array.map (fun entry -> entry.Trim())
    |> Array.filter (fun entry -> entry <> "")

// ---------------------------------------------------------------------------------------------
// parsing
// ---------------------------------------------------------------------------------------------

let private levelOf (text: string) : int =
    if text = "" then 0 else int text[0] - int '0'

/// Parses one alternative of one position. `Error` carries the offending token, which is what the
/// caller shows the user when an entry resolves to neither a pattern nor a topic.
let private parseAlternative (token: string) (outerOpp: bool) : Result<BidPattern, string> =
    let struct (bracketed, ownOpp) = stripBrackets token
    let opp = ownOpp || outerOpp
    // brackets are the notation for "the opponents did this", so a token without them is one of our
    // calls. (The bare `*` wildcard below opts back out to "either side" -- that is what makes it
    // useful for counting depth.)
    let side = sideOf opp
    let inner = foldCallCase (expandSuitShorthand bracketed)
    let upper = inner.ToUpperInvariant()

    let ok (kind: PatternKind) (level: int) (suits: Suits) : Result<BidPattern, string> =
        Ok
            { Level = level
              SuitClass = suits
              Kind = kind
              Side = side }

    match upper with
    | "P"
    | "PASS" -> ok PatPass 0 Suits.Empty
    | "X"
    | "DBL" -> ok PatDouble 0 Suits.Empty
    | "XX"
    | "RDBL"
    | "R" -> ok PatRedouble 0 Suits.Empty
    | "*"
    | "ANY" ->
        // wildcard: any call at this position, by either side unless bracketed. `(*)` means "the
        // opponents actually did something here", since their passes are dropped by
        // `significantPositions`.
        Ok
            { Level = 0
              SuitClass = Suits.Empty
              Kind = PatAny
              Side = (if opp then TheirSide else EitherSide) }
    | _ ->

        let levelWildcard = levelWildcardPatternRE.Match upper

        if levelWildcard.Success then
            // `1*` / `1x` -- any suit at that level (an empty suit class means "any"). Bid tables spell
            // this `x`, section headers `*`; a bare `X` was caught above as a double, so the level makes
            // them unambiguous.
            ok PatBid (levelOf levelWildcard.Groups[1].Value) Suits.Empty
        else

            let otherClass = otherClassPatternRE.Match inner

            if otherClass.Success then
                // `oM` in a *pattern* has no earlier call to be "other" than, so it asks for the class: an
                // auction whose oM resolved either way matches.
                let suits =
                    if otherClass.Groups[2].Value = "m" then
                        Suits.minors
                    else
                        Suits.majors

                ok PatBid (levelOf otherClass.Groups[1].Value) suits
            else

                // level + suit-class chars (case-sensitive: M/m are the class shortcuts)
                let levelSuits = levelSuitsPatternRE.Match inner

                if not levelSuits.Success then
                    Error token
                else
                    let mutable suitClass = Suits.Empty

                    for ch in levelSuits.Groups[2].Value do
                        let bit =
                            match ch with
                            | 'M' -> Suits.majors
                            | 'm' -> Suits.minors
                            | _ -> Suits.ofChar ch

                        suitClass <- suitClass ||| bit

                    ok PatBid (levelOf levelSuits.Groups[1].Value) suitClass

/// Parses one position, which may be an alternation (`2D/2H`, `3S/4C`). Brackets may wrap the whole
/// alternation -- `(2D/2H)` is the opponents making either call -- or an individual branch.
let private parsePatternToken (token: string) : Result<CallPattern, string> =
    let struct (inner, opp) = stripBrackets token

    let parts =
        inner.Split(AltSep, StringSplitOptions.RemoveEmptyEntries)
        |> Array.filter (fun part -> part.Trim() <> "")

    if parts.Length = 0 then
        Error token
    else
        let alternatives = Array.zeroCreate<BidPattern> parts.Length
        let mutable failure = ValueNone

        for i in 0 .. parts.Length - 1 do
            if failure.IsNone then
                match parseAlternative parts[i] opp with
                | Ok alternative -> alternatives[i] <- alternative
                | Error bad -> failure <- ValueSome bad

        match failure with
        | ValueSome bad -> Error bad
        | ValueNone -> Ok { Alternatives = alternatives }

/// Parses `1D-1M-1N` (dashes or spaces; bml's `--` also accepted). A position may offer
/// alternatives with `/`: `1M-3S/4C`.
let parsePattern (patternText: string) : Result<Pattern, string> =
    let parts =
        splitRE.Split(normaliseFilterText patternText)
        |> Array.filter (fun part -> part <> "")

    if parts.Length = 0 then
        Error patternText
    else
        let positions = Array.zeroCreate<CallPattern> parts.Length
        let mutable failure = ValueNone

        for i in 0 .. parts.Length - 1 do
            if failure.IsNone then
                match parsePatternToken parts[i] with
                | Ok position -> positions[i] <- position
                | Error bad -> failure <- ValueSome bad

        match failure with
        | ValueSome bad -> Error bad
        | ValueNone -> Ok positions

/// Rewrites a pattern the way it was understood: `-`-joined, whitespace tidied, case folded
/// (`1d -- 1M 1n` -> `1D-1M-1N`). This is what the input box shows after the user commits.
let canonicalPatternText (patternText: string) : string =
    splitRE.Split(normaliseFilterText patternText)
    |> Array.filter (fun part -> part <> "")
    |> Array.map (fun part ->
        let struct (inner, opp) = stripBrackets part
        let folded = foldCallCase (expandSuitShorthand inner)
        if opp then "(" + folded + ")" else folded
    )
    |> String.concat "-"
