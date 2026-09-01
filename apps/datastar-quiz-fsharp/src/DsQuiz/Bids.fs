/// The canonical model of a bridge call: an F# port of the bml tools' `bmlbids.py`
/// (`~/dev/bml/bmlbids.py`), which the python quiz, the html renderers and the Odin markup
/// implementation all share. Ported from the Go port's `internal/bids/bids.go`, which is itself
/// that python.
///
/// A call is written the way bml writes it:
///
///     1D 2H 3N      a bid: level 1-7 plus one or more suits, C D H S N
///     1HS           a multi-suit bid, meaning "1H or 1S"
///     2M 3m         suit classes: M = a major {H,S}, m = a minor {C,D}. These are the one place
///                   case is significant
///     3* 3x         any denomination at that level
///     oM 3oM        "the other major" -- a variable resolved against an earlier call
///     [1D](#1C--1D) a call written as a markdown link to its own section
///     1!h           `!x` suit shorthand, as used in .bml source
///     1NT           `NT` is accepted and normalised to `N`
///     Pass P        pass          X Dbl    double        XX Rdbl R   redouble
///     (1S) (X)      brackets mean the opponents made this call
///     2D/2H 3S/4C   alternatives at ONE position
///
/// Anything else that appears in a bid table -- `any`, `cue`, `new`, `Game`, `others` -- parses as
/// its own kind rather than failing, so a sequence containing one can still be handled as a whole.
///
/// THREE DELIBERATE DIFFERENCES from the python, none of them semantic:
///
///   - `Suits` is a flags enum rather than a frozenset, so `Call` is a comparable value type and
///     the set operations are single instructions. The corpus is ~7,600 auctions and every one of
///     them is parsed at boot.
///   - `Level` is an int where python has `Optional[int]`, with 0 standing for None. No real level
///     is 0 (they run 1-7), and `Step` -- the one kind that uses the field for something else --
///     counts from 1 as well.
///   - `Kind` and `SuitClass` are unions rather than strings, so a missing case is a compile error
///     rather than a silently unmatched branch. Their cases carry no data, so they are singletons:
///     naming one allocates nothing.
module DsQuiz.Bids

open System
open System.Text
open System.Text.RegularExpressions

/// A set of denominations, one bit each. Notrump is a denomination but not a suit -- several
/// routines below care about the difference, and say so.
[<Flags>]
type Suits =
    | Empty = 0uy
    | Clubs = 1uy
    | Diamonds = 2uy
    | Hearts = 4uy
    | Spades = 8uy
    | Notrump = 16uy

/// What a token is. `Bid` covers a real bid; everything else is a token a bid table can hold.
[<StructuralEquality; NoComparison>]
type Kind =
    | Bid
    | Pass
    | Double
    | Redouble
    /// `any`, `others`
    | Any
    /// `(overcall)`, `(higher)` -- any *bid*, so not a pass and not a double
    | AnyBid
    /// `(bid)` -- the same but doubles count too; anything except a pass
    | AnyCall
    /// `game`: 3N, or a major or minor game
    | Game
    /// `next`: the cheapest call above the previous one
    | Next
    /// `jump`, `doubleJump`: a new suit, one or two levels above the cheapest available
    | Jump
    /// `!c`, `majors`: that strain, cheapest available
    | Strain
    /// `!c+`: that strain at whatever level it takes -- the pass-or-correct sense
    | StrainAny
    | Slam
    | NextSuit
    /// `4thSuit`: fourth-suit-forcing, the one suit still unbid
    | FourthSuit
    /// `raise`, `jumpRaise`: supports the last suit partner bid
    | Raise
    /// a step response to an artificial ask; `Level` carries which step, 0 for any
    | Step
    /// `cue`: a bid in a suit the opponents bid
    | Cue
    /// `CueOver`: cues the player on your immediate right
    | CueOver
    | CueLow
    | CueHigh
    /// `suit`, `newSuit`, `2Y`, `(otherSuit)`
    | New
    /// `2N+`: that call or anything above it
    | AtLeast
    /// a token this model does not recognise, carried along rather than crashing a sequence
    | Other

/// Which suit *class* a token named, when it named one rather than listing denominations. `Suits`
/// still holds the class's full membership, so a consumer that does not resolve variables keeps
/// matching as before; one that does (the quiz's filter) can tie `1HS ... 2M` to the same major and
/// `2oM` to the other.
[<StructuralEquality; NoComparison>]
type SuitClass =
    | NoClass
    /// `M`
    | MajorClass
    /// `m`
    | MinorClass
    /// `oM` -- the complement, within its class, of the bound suit
    | OtherMajor
    /// `om`
    | OtherMinor

/// One call. `Suits` holds every denomination the token allows, so a plain `1H` is {H} and a
/// multi-suit `1HS` is {H, S}.
// Equality is used (`mergeAlternatives` compares two calls' shape); ordering never is, and F# would
// otherwise generate `IComparable` plus a structural comparer for every field.
[<Struct; StructuralEquality; NoComparison>]
type Call =
    {
        /// 1..7, or 0 for pass/double/redouble/other
        Level: int
        Suits: Suits
        Kind: Kind
        ByOpponent: bool
        SuitClass: SuitClass
        /// for `Jump` and `Raise`: how many levels above the cheapest available bid
        JumpLevels: int
    }

// ---------------------------------------------------------------------------------------------
// denomination sets
// ---------------------------------------------------------------------------------------------

// Qualified access always: a bare `majors` or `count` says nothing about what it counts.
[<RequireQualifiedAccess>]
module Suits =

    let majors = Suits.Hearts ||| Suits.Spades
    let minors = Suits.Clubs ||| Suits.Diamonds

    let all =
        Suits.Clubs
        ||| Suits.Diamonds
        ||| Suits.Hearts
        ||| Suits.Spades
        ||| Suits.Notrump

    /// The four real suits: what `new`, `jump` and the cue tokens range over.
    let real = Suits.Clubs ||| Suits.Diamonds ||| Suits.Hearts ||| Suits.Spades

    /// Alphabetical -- the order python's `sorted(frozenset)` produces. Kept so generated variants
    /// come out in the same order as the reference implementation's.
    let alphabetical =
        [| Suits.Clubs
           Suits.Diamonds
           Suits.Hearts
           Suits.Notrump
           Suits.Spades |]

    /// Auction order within a level; notrump is highest.
    let byRank =
        [| Suits.Clubs
           Suits.Diamonds
           Suits.Hearts
           Suits.Spades
           Suits.Notrump |]

    let inline has (other: Suits) (suits: Suits) : bool = suits &&& other <> Suits.Empty
    let inline isEmpty (suits: Suits) : bool = suits = Suits.Empty
    /// every denomination here is also in `other`
    let inline subsetOf (other: Suits) (suits: Suits) : bool = suits &&& ~~~other = Suits.Empty

    let ofChar (ch: char) : Suits =
        match ch with
        | 'C' -> Suits.Clubs
        | 'D' -> Suits.Diamonds
        | 'H' -> Suits.Hearts
        | 'S' -> Suits.Spades
        | 'N' -> Suits.Notrump
        | _ -> Suits.Empty

    let toChar (suit: Suits) : char =
        match suit with
        | Suits.Clubs -> 'C'
        | Suits.Diamonds -> 'D'
        | Suits.Hearts -> 'H'
        | Suits.Spades -> 'S'
        | Suits.Notrump -> 'N'
        | _ -> ' '

    /// Rank of one denomination within a level (1..5). Zero for anything else.
    let rank (suit: Suits) : int =
        match suit with
        | Suits.Clubs -> 1
        | Suits.Diamonds -> 2
        | Suits.Hearts -> 3
        | Suits.Spades -> 4
        | Suits.Notrump -> 5
        | _ -> 0

    let rankOfChar (ch: char) : int = rank (ofChar ch)

    let count (suits: Suits) : int =
        let mutable found = 0

        for bit in alphabetical do
            if has bit suits then
                found <- found + 1

        found

    /// The one denomination in the set, or `Suits.Empty` if it does not hold exactly one.
    let single (suits: Suits) : Suits =
        if count suits = 1 then suits else Suits.Empty

    /// The denominations of a set, alphabetically -- python's `sorted()` order.
    let toArray (suits: Suits) : Suits array =
        alphabetical |> Array.filter (fun bit -> has bit suits)

    /// The denominations of a set in AUCTION order (C D H S N), for enumerating a call upwards.
    let inRankOrder (suits: Suits) : Suits array =
        byRank |> Array.filter (fun bit -> has bit suits)

    let chars (suits: Suits) : System.String =
        String(toArray suits |> Array.map toChar)

    let lowestRank (suits: Suits) : int =
        let mutable lowest = 6

        for bit in alphabetical do
            if has bit suits then
                lowest <- min lowest (rank bit)

        lowest

    let highestRank (suits: Suits) : int =
        let mutable highest = 0

        for bit in alphabetical do
            if has bit suits then
                highest <- max highest (rank bit)

        highest

let inline isBid (call: Call) : bool = call.Kind = Bid

/// `oM`/`om`: the complement, within its class, of the bound suit.
let isOtherClass (call: Call) : bool =
    call.SuitClass = OtherMajor || call.SuitClass = OtherMinor

/// The denominations this token's class ranges over ({H,S} for any of M/oM), or its own suits when
/// it named no class.
let classSuits (call: Call) : Suits =
    match call.SuitClass with
    | MajorClass
    | OtherMajor -> Suits.majors
    | MinorClass
    | OtherMinor -> Suits.minors
    | NoClass -> call.Suits

let emptyCall =
    { Level = 0
      Suits = Suits.Empty
      Kind = Other
      ByOpponent = false
      SuitClass = NoClass
      JumpLevels = 0 }

/// `game` is a game contract: 3N or a major game or a minor game.
let private gameCallTexts =
    [| "3N"
       "4H"
       "4S"
       "5C"
       "5D" |]

/// The levels `slam` stands for when the token does not say.
let slamLevels = [| 6; 7 |]

/// How many step responses `xstep` stands for -- the corpus's own EKB rows describe five
/// ("5th step = 2 KC + a void") before leaving the ladder with `6x`.
[<Literal>]
let StepLimit = 5

/// Separates alternatives at a single position: `2D/2H` is one call, not two.
[<Literal>]
let AltSep = "/"

// ---------------------------------------------------------------------------------------------
// tokens
// ---------------------------------------------------------------------------------------------

// Compiled, because every auction in the corpus is parsed at boot and the filter re-parses its
// patterns per request.
let private re pattern : System.Text.RegularExpressions.Regex = Regex(pattern, RegexOptions.Compiled)

/// A bid is a level then one or more denominations. The multi-suit form (`1HS`, `4CDHS`) is a real
/// thing in bml tables and headers, not a typo.
let private bidRE = re @"^\(?([1-7])([CDHSNMm*]+)\)?$"

/// `3*` and `3x` both mean "any denomination at that level". A bare `X` is a double, but a
/// level-prefixed one cannot be.
let private levelWildcardRE = re @"^([1-7])[X*]$"

/// `oM` is "the other major" -- a variable, not a suit set.
let private otherClassRE = re @"^([1-7])?O([Mm])$"

let private shorthandRE = re @"!([cdhsCDHS])"

/// A bid may be written as a markdown link, e.g. `[1D](#1C--1D) Negative 0--7`.
let private linkRE = re @"^\[([^\]\s]+)\]\([^)]*\)$"

/// `cue` is a bid in a suit the opponents bid; `CueOver` cues the player on your immediate right;
/// `cueLow`/`cueHi` name which of their two suits.
let private cueRE = re @"^([1-7])?CUE$"

let private cueOverRE = re @"^([1-7])?CUEOVER$"
let private cuePickRE = re @"^([1-7])?CUE(LOW|HI|HIGH)$"

/// Step responses to an artificial ask. Both spellings occur: `1step` and `step1`.
let private stepRE = re @"^(?:([1-7]|X)STEP|STEP([1-7]))$"

/// `raise` supports the last suit partner bid; `jumpRaise` is one level higher.
let private raiseRE = re @"^([1-7])?(JUMP)?RAISE$"

let private slamRE = re @"^([1-7])?SLAM$"

/// A denomination with no level is a *simple* bid in that strain; a trailing `+` widens it to any
/// level in that strain. A bare `D` is excluded: it is the double.
let private strainRE = re @"^(?:MAJORS?|MINORS?|([CDHSNMm]+))(\+)?$"

/// `suit`/`newSuit`/`2Y` are all the new-suit bid; `(otherSuit)` is the same rule said from the
/// opponents' side.
let private newRE = re @"^(?:([1-7])?(?:NEW(?:SUIT)?|SUIT|OTHERSUIT)|([1-7])Y)$"

/// `2N+` is "2N or anything higher". The bound is written out, so it needs nothing from the auction.
let private atLeastRE = re @"^([1-7])([CDHSNMm*X])\+$"

/// Turns `!h` / `!H` into `H`, the shorthand used in .bml source.
let expandSuitShorthand (text: string) : string =
    if text.IndexOf '!' < 0 then
        text
    else
        shorthandRE.Replace(text, (fun (m: Match) -> m.Groups[1].Value.ToUpperInvariant()))

/// Uppercases a token, keeping a lowercase `m` (minors) distinct from `M` (majors). Everything else
/// is a suit letter or a keyword, for which case carries no meaning.
let foldCallCase (token: string) : string =
    let out = StringBuilder token.Length

    for ch in token do
        out.Append(if ch = 'm' then ch else Char.ToUpperInvariant ch) |> ignore

    out.ToString()

/// Case-folds a token and reduces `NT` to `N`, without touching brackets.
let normaliseCallToken (token: string) : string =
    (foldCallCase (expandSuitShorthand (token.Trim()))).Replace("NT", "N")

let private bracketChars = [| '('; ')' |]

/// Splits `(1S)` into its inner text and "was it the opponents'".
let stripBrackets (token: string) : struct (string * bool) =
    struct (token.Trim bracketChars, token.Trim().StartsWith('('))

/// Turns `[1D](#1C--1D)` into `1D`.
let unwrapLink (token: string) : string =
    let trimmed = token.Trim()
    let m = linkRE.Match trimmed
    if m.Success then m.Groups[1].Value else token

/// `HS` -> {H,S}; `M` -> majors; `m` -> minors; `*` -> everything.
let private expandDenominations (text: string) : Suits =
    let mutable suits = Suits.Empty

    for ch in text do
        let bit =
            match ch with
            | 'M' -> Suits.majors
            | 'm' -> Suits.minors
            | '*' -> Suits.all
            | _ -> Suits.ofChar ch

        suits <- suits ||| bit

    suits

let private optLevel (text: string) : int =
    match Int32.TryParse text with
    | true, level -> level
    | _ -> 0

let private passTokens = [| "P"; "PASS" |]
let private doubleTokens = [| "X"; "DBL" |]
let private redoubleTokens = [| "XX"; "RDBL"; "R" |]
let private otherTokens = [| "OTHER"; "OTHERS" |]
let private anyBidTokens = [| "OVERCALL"; "HIGHER" |]
let private fourthSuitTokens = [| "4THSUIT"; "FOURTHSUIT" |]

let inline private oneOf (tokens: string array) (token: string) = Array.contains token tokens

/// How many levels a jump token jumps, or 0 if it is not one. A jump in these tables is a jump *in
/// a new suit*, one level above the cheapest bid available in it; `doubleJump` is one higher again.
let private jumpLevelsOf (upper: string) : int =
    match upper with
    | "JUMP"
    | "JUMPNEW"
    | "NEWJUMP" -> 1
    | "DOUBLEJUMP" -> 2
    | _ -> 0

let private spaceSep = [| ' ' |]

/// Parses a single call. `ValueNone` only for empty input; unrecognised tokens come back as
/// `Kind.Other` so they can be carried along rather than crashing a sequence.
///
/// THE ORDER OF THE TESTS BELOW IS THE PYTHON'S AND THE GO PORT'S, AND IT MATTERS: `strainRE` would
/// happily eat `D` (the double), `cueRE` would eat the tail of `CUELOW`, and `bidRE` would eat the
/// level off `3X`.
let rec parseCall (token: string) : Call voption =
    if String.IsNullOrWhiteSpace token then
        ValueNone
    else

        let token = unwrapLink (token.Trim())

        if token.Contains AltSep then
            match mergeAlternatives (parseCallAlternatives token) with
            | ValueSome merged -> ValueSome merged
            | ValueNone ->
                let struct (_, opp) = stripBrackets token
                ValueSome { emptyCall with ByOpponent = opp }
        else

            let struct (inner, opp) = stripBrackets (normaliseCallToken token)
            let upper = inner.ToUpperInvariant()

            let inline call (kind: Kind) : Call voption =
                ValueSome { emptyCall with Kind = kind; ByOpponent = opp }

            if oneOf passTokens inner then
                call Pass
            elif oneOf doubleTokens inner then
                call Double
            elif oneOf redoubleTokens inner then
                call Redouble
            elif inner = "ANY" || oneOf otherTokens upper then
                call Any
            elif oneOf anyBidTokens upper then
                call AnyBid
            elif upper = "BID" then
                call AnyCall
            elif upper = "GAME" then
                call Game
            elif inner = "NEXT" then
                call Next
            elif jumpLevelsOf upper > 0 then
                ValueSome { emptyCall with Kind = Jump; ByOpponent = opp; JumpLevels = jumpLevelsOf upper }
            else

                // `!d` is diamonds, but a bare `D` written on its own is the double, so this guard looks at the
                // token as written rather than after shorthand expansion
                let struct (rawInner, _) = stripBrackets (token.Trim())

                let strain =
                    let m = strainRE.Match inner
                    if m.Success then m else strainRE.Match upper

                if strain.Success && rawInner.ToUpperInvariant() <> "D" then
                    let suits =
                        if upper.StartsWith("MAJOR", StringComparison.Ordinal) then
                            Suits.majors
                        elif upper.StartsWith("MINOR", StringComparison.Ordinal) then
                            Suits.minors
                        else
                            expandDenominations strain.Groups[1].Value

                    ValueSome
                        { emptyCall with
                            Suits = suits
                            Kind = (if strain.Groups[2].Value <> "" then StrainAny else Strain)
                            ByOpponent = opp }
                else

                    let inline tryMatch (pattern: Regex) (text: string) =
                        let m = pattern.Match text
                        if m.Success then ValueSome m else ValueNone

                    match tryMatch slamRE upper with
                    | ValueSome m ->
                        ValueSome
                            { emptyCall with
                                Level = optLevel m.Groups[1].Value
                                Kind = Slam
                                ByOpponent = opp }
                    | ValueNone ->

                        if upper = "NEXTSUIT" then
                            call NextSuit
                        elif oneOf fourthSuitTokens upper then
                            call FourthSuit
                        else

                            match tryMatch raiseRE upper with
                            | ValueSome m ->
                                ValueSome
                                    { emptyCall with
                                        Level = optLevel m.Groups[1].Value
                                        Kind = Raise
                                        ByOpponent = opp
                                        JumpLevels = (if m.Groups[2].Value <> "" then 1 else 0) }
                            | ValueNone ->

                                match tryMatch stepRE upper with
                                | ValueSome m ->
                                    // level carries which step; 0 means "any of them"
                                    let which =
                                        if m.Groups[1].Value <> "" then
                                            m.Groups[1].Value
                                        else
                                            m.Groups[2].Value

                                    ValueSome
                                        { emptyCall with
                                            Level = (if which = "X" then 0 else optLevel which)
                                            Kind = Step
                                            ByOpponent = opp }
                                | ValueNone ->

                                    match tryMatch cuePickRE upper with
                                    | ValueSome m ->
                                        ValueSome
                                            { emptyCall with
                                                Level = optLevel m.Groups[1].Value
                                                Kind = (if m.Groups[2].Value = "LOW" then CueLow else CueHigh)
                                                ByOpponent = opp }
                                    | ValueNone ->

                                        match tryMatch cueOverRE upper with
                                        | ValueSome m ->
                                            ValueSome
                                                { emptyCall with
                                                    Level = optLevel m.Groups[1].Value
                                                    Kind = CueOver
                                                    ByOpponent = opp }
                                        | ValueNone ->

                                            match tryMatch cueRE upper with
                                            | ValueSome m ->
                                                ValueSome
                                                    { emptyCall with
                                                        Level = optLevel m.Groups[1].Value
                                                        Kind = Cue
                                                        ByOpponent = opp }
                                            | ValueNone ->

                                                match tryMatch newRE upper with
                                                | ValueSome m ->
                                                    let level =
                                                        if m.Groups[1].Value <> "" then
                                                            m.Groups[1].Value
                                                        else
                                                            m.Groups[2].Value

                                                    ValueSome
                                                        { emptyCall with
                                                            Level = optLevel level
                                                            Kind = New
                                                            ByOpponent = opp }
                                                | ValueNone ->

                                                    match tryMatch atLeastRE inner with
                                                    | ValueSome m ->
                                                        // `2N+` -- every call from 2N up. Enumerated by `callsAtOrAbove` rather than stored as a
                                                        // bound, so matching stays a plain set intersection.
                                                        ValueSome
                                                            { emptyCall with
                                                                Level = optLevel m.Groups[1].Value
                                                                Suits =
                                                                    expandDenominations (
                                                                        m.Groups[2].Value.Replace("X", "*")
                                                                    )
                                                                Kind = AtLeast
                                                                ByOpponent = opp }
                                                    | ValueNone ->

                                                        match tryMatch levelWildcardRE inner with
                                                        | ValueSome m ->
                                                            ValueSome
                                                                { emptyCall with
                                                                    Level = optLevel m.Groups[1].Value
                                                                    Suits = Suits.all
                                                                    Kind = Bid
                                                                    ByOpponent = opp }
                                                        | ValueNone ->

                                                            match tryMatch otherClassRE inner with
                                                            | ValueSome m ->
                                                                // `oM` with no level ("the other major, at whatever level") keeps level 0: it still
                                                                // constrains the suit, which is what it is for.
                                                                let minor = m.Groups[2].Value = "m"

                                                                ValueSome
                                                                    { emptyCall with
                                                                        Level = optLevel m.Groups[1].Value
                                                                        Suits =
                                                                            (if minor then
                                                                                 Suits.minors
                                                                             else
                                                                                 Suits.majors)
                                                                        Kind = Bid
                                                                        ByOpponent = opp
                                                                        SuitClass =
                                                                            (if minor then
                                                                                 OtherMinor
                                                                             else
                                                                                 OtherMajor) }
                                                            | ValueNone ->

                                                                match tryMatch bidRE inner with
                                                                | ValueSome m ->
                                                                    let denominations = m.Groups[2].Value

                                                                    ValueSome
                                                                        { emptyCall with
                                                                            Level = optLevel m.Groups[1].Value
                                                                            Suits =
                                                                                expandDenominations
                                                                                    denominations
                                                                            Kind = Bid
                                                                            ByOpponent = opp
                                                                            SuitClass =
                                                                                match denominations with
                                                                                | "M" -> MajorClass
                                                                                | "m" -> MinorClass
                                                                                | _ -> NoClass }
                                                                | ValueNone -> call Other

/// Parses one auction position into the calls it allows.
///
/// `2D/2H` is *one* call written as two possibilities, and `(2D/2H)` is the opponents making it;
/// the brackets may wrap the whole alternation or each alternative.
and parseCallAlternatives (token: string) : Call array =
    if String.IsNullOrWhiteSpace token then
        Array.empty
    else
        let struct (outer, outerOpp) = stripBrackets (unwrapLink (token.Trim()))

        [| for part in outer.Split AltSep do
               match parseCall part with
               | ValueSome call ->
                   // brackets around the whole alternation apply to every alternative
                   { call with ByOpponent = call.ByOpponent || outerOpp }
               | ValueNone -> () |]

/// One `Call` covering every alternative, when they differ only in suit. `2D/2H` is exactly `2DH`.
/// Alternatives spanning levels (`3S/4C`) or kinds cannot be one call, and the caller falls back to
/// `Kind.Other`.
and mergeAlternatives (calls: Call array) : Call voption =
    if calls.Length = 0 then
        ValueNone
    else
        let first = calls[0]
        let mutable suits = first.Suits
        let mutable compatible = true

        for i in 1 .. calls.Length - 1 do
            let other = calls[i]

            if
                other.Level <> first.Level
                || other.Kind <> first.Kind
                || other.ByOpponent <> first.ByOpponent
            then
                compatible <- false
            else
                suits <- suits ||| other.Suits

        if compatible then
            ValueSome { first with Suits = suits }
        else
            ValueNone

/// Flattens strings that may each hold several space-separated calls (`"1C (Pass) 1H"`) into one
/// array of calls.
let parseCalls (sequence: string array) : Call array =
    [| for element in sequence do
           for token in element.Split(spaceSep, StringSplitOptions.RemoveEmptyEntries) do
               match parseCall token with
               | ValueSome call -> call
               | ValueNone -> () |]

/// A real bid (not pass/double/prose). Multi-suit counts, and so does an alternation of bids --
/// including `3S/4C`, which spans levels and so has no single-call form to ask `isBid` of.
let isBidToken (token: string) : bool =
    let calls = parseCallAlternatives token
    calls.Length > 0 && calls |> Array.forall isBid

/// The bid tokens, as written, out of strings that may hold several calls. Non-bids (pass, double,
/// prose) are dropped; multi-suit bids are kept -- dropping them is what loses section context like
/// `1C--1HS`.
let bidTokens (strings: string array) : string array =
    [| for s in strings do
           for token in s.Split(spaceSep, StringSplitOptions.RemoveEmptyEntries) do
               if isBidToken token then
                   token |]

/// The cheapest bid above `call` -- one denomination up, or the next level starting at clubs when
/// `call` was notrump.
///
/// Only defined for a bid naming one denomination: after a token that could be several calls
/// (`4HS`, `3x`, `any`) there is no single next step. `ValueNone` at the ceiling (7N) and for
/// non-bids.
let nextCall (call: Call) : Call voption =
    if not (isBid call) || call.Level = 0 || Suits.count call.Suits <> 1 then
        ValueNone
    else
        match Suits.rank call.Suits with
        | 5 when call.Level = 7 -> ValueNone
        | 5 -> ValueSome { call with Level = call.Level + 1; Suits = Suits.Clubs; SuitClass = NoClass }
        | rank -> ValueSome { call with Suits = Suits.byRank[rank]; SuitClass = NoClass }

/// The `steps`-th call above `previous`, counting the cheapest as step 1. This is the ladder
/// artificial asks answer on: over a 4N keycard ask, 5C is step 1.
let stepCall (previous: Call) (steps: int) : Call voption =
    let mutable call = ValueSome previous
    let mutable remaining = steps

    while remaining > 0 && call.IsSome do
        call <- nextCall call.Value
        remaining <- remaining - 1

    call

/// The lowest bid in `suit` that is legal over `previous`: the same level when `suit` outranks the
/// previous denomination, one level up otherwise. `ValueNone` past 7, or when `previous` is not one
/// specific bid (`4HS` could be either).
let cheapestCall (previous: Call) (suit: Suits) : Call voption =
    if not (isBid previous) || previous.Level = 0 || Suits.count previous.Suits <> 1 then
        ValueNone
    else
        let level =
            if Suits.rank suit <= Suits.rank previous.Suits then
                previous.Level + 1
            else
                previous.Level

        if level > 7 then
            ValueNone
        else
            ValueSome
                { previous with
                    Level = level
                    Suits = suit
                    SuitClass = NoClass
                    JumpLevels = 0 }

/// The game contracts: 3N, 4H, 4S, 5C, 5D.
let gameCalls (byOpponent: bool) : Call array =
    gameCallTexts
    |> Array.map (fun text ->
        match parseCall text with
        | ValueSome call -> { call with ByOpponent = byOpponent }
        | ValueNone -> emptyCall
    )

/// Every bid from `call` upwards, for an `AtLeast` token like `2N+`. Enumerating them keeps
/// matching a set intersection instead of needing a comparison operator in the pattern language.
let callsAtOrAbove (call: Call) : Call array =
    if call.Level = 0 || Suits.isEmpty call.Suits then
        Array.empty
    else
        let floor = Suits.lowestRank call.Suits

        [| for level in call.Level .. 7 do
               for suit in Suits.byRank do
                   if not (level = call.Level && Suits.rank suit < floor) then
                       { emptyCall with
                           Level = level
                           Suits = suit
                           Kind = Bid
                           ByOpponent = call.ByOpponent } |]

let private oneLessThan (left: Call) (right: Call) : bool =
    if not (isBid left) || left.Level = 0 || not (isBid right) || right.Level = 0 then
        false
    elif left.Level <> right.Level then
        left.Level < right.Level
    else
        // same level: every denomination `left` could be must rank below every one `right` could
        // be, so compare left's highest against right's lowest
        Suits.highestRank left.Suits < Suits.lowestRank right.Suits

/// Whether `left` ranks strictly below `right` in the auction.
///
/// Strict throughout, because the caller is asking "did this call have to come first?" and a wrong
/// yes invents an auction. A multi-suit bid is below another call only when *every* denomination it
/// allows is, and an alternation is below only when every branch is. Non-bids compare as false.
let callLessThan (left: string) (right: string) : bool =
    let lefts = parseCallAlternatives left
    let rights = parseCallAlternatives right

    lefts.Length > 0
    && rights.Length > 0
    && lefts |> Array.forall (fun x -> rights |> Array.forall (oneLessThan x))

/// python's `min(calls, key=lambda c: (c.level, SUIT_RANK[...]))`.
let lowestCall (calls: Call array) : Call voption =
    if calls.Length = 0 then
        ValueNone
    else
        let mutable best = calls[0]

        for i in 1 .. calls.Length - 1 do
            let call = calls[i]

            let better =
                call.Level < best.Level
                || (call.Level = best.Level && Suits.rank call.Suits < Suits.rank best.Suits)

            if better then
                best <- call

        ValueSome best
