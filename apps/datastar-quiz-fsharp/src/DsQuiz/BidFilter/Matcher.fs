/// Matching an auction against a pattern. Ported from the Go port's `internal/bidfilter/match.go`.
///
/// The matcher is STATELESS and does no backtracking: `Relative` has already expanded an auction
/// into the concrete auctions it stands for, so all that is left here is an overlap test per
/// position and the rule about stepping over opponent calls.
module DsQuiz.BidFilter.Matcher

open System

open DsQuiz.Bids
open DsQuiz.BidFilter.Pattern

/// Whether one call satisfies one alternative of one pattern position.
///
/// Both sides can name a *set* of calls -- the auction may record `1HS` or `2D/2H`, the pattern may
/// ask for `1M` or `3S/4C` -- so this is a test for overlap, not equality: the position matches if
/// any alternative it allows shares a denomination with any the call allows.
let callMatchesAlternative (call: Call) (pat: BidPattern) : bool =
    let sideOk = pat.Side = EitherSide || pat.Side = sideOf call.ByOpponent

    match call.Kind with
    | Any
    | AnyBid
    | AnyCall ->
        // a catch-all row -- "whatever is called here" -- so it answers to any pattern, subject to
        // whose call it was and to how much the word promised: `(overcall)` is a bid, `(bid)` is
        // anything but a pass, `any`/`other(s)` is anything at all
        sideOk
        && match call.Kind with
           | AnyBid ->
               match pat.Kind with
               | PatBid
               | PatAny -> true
               | _ -> false
           | AnyCall ->
               match pat.Kind with
               | PatBid
               | PatDouble
               | PatRedouble
               | PatAny -> true
               | _ -> false
           | _ -> true
    | _ ->

        let kindOk =
            match pat.Kind with
            | PatAny -> true
            | PatBid -> call.Kind = Bid
            | PatPass -> call.Kind = Pass
            | PatDouble -> call.Kind = Double
            | PatRedouble -> call.Kind = Redouble

        if not kindOk || not sideOk then
            false
        elif pat.Kind = PatBid then
            (pat.Level = 0 || pat.Level = call.Level)
            && (Suits.isEmpty pat.SuitClass || Suits.has pat.SuitClass call.Suits)
        else
            true

/// `callMatchesAlternative` over a whole position of the pattern (its alternatives).
let private callMatches (call: Call) (pat: CallPattern) : bool =
    // an explicit lambda rather than a partial application: `Array.exists` takes an
    // `[<InlineIfLambda>]` predicate, and a partially applied function is not one
    pat.Alternatives |> Array.exists (fun alt -> callMatchesAlternative call alt)

/// The same when the *auction* position is itself a set of calls.
///
/// `1HS--3S/4C` records a position no single call can express, so an auction position is a tuple of
/// alternatives. It matches when any of them does -- the recorded auction is one of these calls, and
/// the filter is asking whether it could be the one wanted.
let positionMatches (position: Position) (pat: CallPattern) : bool =
    position |> Array.exists (fun call -> callMatches call pat)

let private allByOpponent (position: Position) : bool =
    position |> Array.forall (fun call -> call.ByOpponent)

/// Must this position line up with the very next call rather than skipping over opponent calls? True
/// for anything bracketed and for the bare `*`.
let private anchored (pat: CallPattern) : bool =
    pat.Alternatives
    |> Array.exists (fun alt -> alt.Side = TheirSide || alt.Kind = PatAny)

/// Whether the auction begins with the pattern.
///
/// A pattern describes *our* auction. The opponents can slip a call in at any point, so opponent
/// calls the pattern does not ask about are stepped over rather than failing the match: `1D-1H`
/// matches 1D (Pass) 1H, 1D (1S) 1H and 1D (X) 1H alike.
///
/// THREE KINDS OF TOKEN OPT OUT of that skipping and line up with whatever call comes next:
///   - the *first* token, because this is a prefix match: it anchors to the opening call, so `2C`
///     means we opened 2C, not that we bid 2C at some point after an opponent's opening;
///   - a bracketed token -- `(X)`, `(2H)`, `(*)` -- which is *about* the opponents, so it must match
///     the very next call;
///   - the bare wildcard `*`, meaning "any call at all" including an opponent's, which is what makes
///     `*-*-*-*-*-*` mean "six calls deep" rather than "six calls by us".
let matchesPrefix (auction: Auction) (pattern: Pattern) : bool =
    let mutable i = 0
    let mutable n = 0
    let mutable matched = true

    while matched && n < pattern.Length do
        let pat = pattern[n]

        if n > 0 && not (anchored pat) then
            while i < auction.Length && allByOpponent auction[i] do
                i <- i + 1

        if i >= auction.Length || not (positionMatches auction[i] pat) then
            matched <- false
        else
            i <- i + 1
            n <- n + 1

    matched

/// Parses an auction into one entry per position, each the calls it allows.
///
/// Unlike a flat call parse this keeps `3S/4C` -- an alternation spanning levels, which has no
/// single-call form -- instead of degrading it to `Other`.
let parseSequencePositions (sequence: string array) : Auction =
    let positions = ResizeArray<Position>()

    for element in sequence do
        for token in element.Split(' ', StringSplitOptions.RemoveEmptyEntries) do
            let calls = ResizeArray<Call>()

            for call in parseCallAlternatives token do
                match call.Kind with
                // `2N+` names its own floor, so it needs no auction: expand it here into the calls
                // it allows
                | AtLeast -> calls.AddRange(callsAtOrAbove call)
                // a game contract: 3N, 4H, 4S, 5C or 5D
                | Game -> calls.AddRange(gameCalls call.ByOpponent)
                | _ -> calls.Add call

            if calls.Count > 0 then
                positions.Add(calls.ToArray())

    positions.ToArray()

/// Drops opponent passes. They are noise for filtering -- the auction notation omits them anyway --
/// and dropping them is what lets `(*)` mean "the opponents actually did something". Active opponent
/// calls like (X) or (1S) are kept, and `matchesPrefix` decides whether to step over them.
let significantPositions (auction: Auction) : Auction =
    auction
    |> Array.filter (fun position ->
        not (position |> Array.forall (fun call -> call.ByOpponent && call.Kind = Pass))
    )

/// Turns one auction into the concrete auctions it stands for: parsed into positions, opponent passes
/// dropped, suit classes bound, `next` and its relatives resolved.
let prepareAuction (sequence: string array) : Variants =
    let positions = significantPositions (parseSequencePositions sequence)
    let variants = ResizeArray<Auction>()

    for variant in Relative.expandCorrelated positions do
        variants.AddRange(Relative.resolveRelative variant)

    variants.ToArray()

/// Pre-parses a corpus of auctions once, so that repeatedly re-filtering it (validating on every
/// keystroke) is only prefix comparisons.
let prepareSequenceBids (sequences: string array array) : DsQuiz.BidFilter.Pattern.Variants array =
    sequences |> Array.map prepareAuction

/// Whether a pre-parsed auction matches *any* of the patterns (comma = OR).
let bidsMatchAny (variants: Variants) (patterns: Pattern array) : bool =
    let mutable found = false
    let mutable v = 0

    while not found && v < variants.Length do
        let mutable p = 0

        while not found && p < patterns.Length do
            if matchesPrefix variants[v] patterns[p] then
                found <- true

            p <- p + 1

        v <- v + 1

    found

/// Parses a raw auction and prefix-matches it against any of the patterns. Convenience for tests and
/// one-off checks; the app pre-parses instead.
let sequenceMatchesAny (sequence: string array) (patterns: Pattern array) : bool =
    bidsMatchAny (prepareAuction sequence) patterns
