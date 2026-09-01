/// The two rewrites that happen to an auction BEFORE it is ever matched: binding correlated suit
/// classes, and resolving the relative tokens (`next`, `jump`, `cue`, `raise`, `slam`, ...) into the
/// concrete calls the table meant. Ported from the Go port's `internal/bidfilter/relative.go`.
///
/// Both work the same way, and it is the design decision worth knowing: rather than binding
/// variables inside the matcher -- which would make it stateful and need backtracking -- an auction
/// is EXPANDED into the concrete auctions it stands for, and matches if any of them does. The
/// matcher stays a pure overlap test, and anything unresolvable stays unmatched rather than
/// quietly becoming a wildcard.
module DsQuiz.BidFilter.Relative

open DsQuiz.Bids
open DsQuiz.BidFilter.Pattern

// ---------------------------------------------------------------------------------------------
// correlated suit classes
//
// `1HS--2M` is "1H then 2H, or 1S then 2S" -- one major, named twice. Matching each position
// independently also accepts 1H then 2S, an auction the section never described. The corpus proves
// the intent: it writes `oM` when it means *the other* major, which would be pointless if a repeated
// `M` did not mean the same one.
//
// For a single set-valued position this expansion is identical to the plain overlap test; it only
// tightens where two positions share a class.
// ---------------------------------------------------------------------------------------------

/// A suit class is a proper subset of the denominations: {H,S} and {C,D} bind, the
/// five-denomination wildcard (`3*`) does not -- two wildcards in an auction are unrelated, not "the
/// same unknown suit".
let private bindable = [| Suits.majors; Suits.minors |]

/// The class this call's suit is drawn from, if it is one that binds, or `Suits.Empty`. A concrete
/// call counts: `1H` is a use of the majors class, which is what lets a later `2oM` mean spades.
let private bindingClass (call: Call) : DsQuiz.Bids.Suits =
    if not (isBid call) || Suits.isEmpty call.Suits then
        Suits.Empty
    elif call.SuitClass <> NoClass then
        let klass = classSuits call
        if Array.contains klass bindable then klass else Suits.Empty
    else
        match bindable |> Array.tryFind (fun klass -> Suits.subsetOf klass call.Suits) with
        | Some klass -> klass
        | None -> Suits.Empty

/// The classes this auction uses as a variable.
///
/// A class binds when the auction leaves it open more than once (`1HS ... 2M`), or names "the other"
/// one alongside any call of that class (`1H ... 2oM` -- the concrete 1H is what fixes it).
let private boundClasses (auction: Auction) : DsQuiz.Bids.Suits array =
    // Two classes, so two counters each rather than a dictionary -- and a fixed order, which keeps
    // the generated variants stable run to run.
    let anyUses = Array.zeroCreate<int> bindable.Length
    let openUses = Array.zeroCreate<int> bindable.Length
    let other = Array.zeroCreate<bool> bindable.Length

    for position in auction do
        for call in position do
            let klass = bindingClass call

            if not (Suits.isEmpty klass) then
                let index = Array.findIndex (fun k -> k = klass) bindable
                anyUses[index] <- anyUses[index] + 1

                if isOtherClass call then
                    other[index] <- true
                elif Suits.count call.Suits > 1 then
                    openUses[index] <- openUses[index] + 1

    [| for index in 0 .. bindable.Length - 1 do
           if
               anyUses[index] > 0
               && (openUses[index] > 1 || (other[index] && anyUses[index] > 1))
           then
               bindable[index] |]

/// The one denomination of `klass` the auction states outright, if any.
///
/// Two different concrete calls of the same class (`1H` then `1S`) leave the variable genuinely
/// ambiguous; `Suits.Empty` makes the caller fall back to the untightened auction rather than guess.
let private fixedSuit (auction: Auction) (klass: Suits) : DsQuiz.Bids.Suits =
    let mutable concrete = Suits.Empty

    for position in auction do
        for call in position do
            if bindingClass call = klass && Suits.count call.Suits = 1 then
                concrete <- concrete ||| call.Suits

    if Suits.count concrete = 1 then concrete else Suits.Empty

/// One class bound to one denomination. Two entries at most, so a lookup is a scan.
[<Struct>]
type private Binding = { Class: Suits; Chosen: Suits }

let private resolveCall (call: Call) (assignment: Binding array) : DsQuiz.Bids.Call =
    let klass = bindingClass call

    if Suits.isEmpty klass || Suits.count call.Suits = 1 then
        call
    else
        let mutable chosen = Suits.Empty

        for binding in assignment do
            if binding.Class = klass then
                chosen <- binding.Chosen

        if Suits.isEmpty chosen then
            call
        elif isOtherClass call then
            { call with Suits = klass &&& ~~~chosen }
        else
            { call with Suits = chosen }

/// itertools.product over the domains, in the same order.
let private product (domains: Suits array array) : DsQuiz.Bids.Suits array array =
    let mutable out = [| Array.empty<Suits> |]

    for domain in domains do
        let grown = ResizeArray<Suits array>(out.Length * domain.Length)

        for prefix in out do
            for value in domain do
                grown.Add(Array.append prefix [| value |])

        out <- grown.ToArray()

    out

/// The concrete auctions an auction with correlated suit classes stands for -- the auction unchanged
/// when nothing binds, which is the common case.
let expandCorrelated (auction: Auction) : Auction array =
    let classes = boundClasses auction

    if classes.Length = 0 then
        [| auction |]
    else
        let domains =
            classes
            |> Array.map (fun klass ->
                let fixedTo = fixedSuit auction klass

                let hasOther =
                    auction
                    |> Array.exists (fun position ->
                        position
                        |> Array.exists (fun call -> bindingClass call = klass && isOtherClass call)
                    )

                if not (Suits.isEmpty fixedTo) && hasOther then
                    // a spelled-out call pins the variable
                    [| fixedTo |]
                else
                    Suits.toArray klass
            )

        let variants =
            product domains
            |> Array.map (fun choice ->
                let assignment =
                    Array.init classes.Length (fun i -> { Class = classes[i]; Chosen = choice[i] })

                auction
                |> Array.map (fun position ->
                    position |> Array.map (fun call -> resolveCall call assignment)
                )
            )

        if variants.Length = 0 then [| auction |] else variants

// ---------------------------------------------------------------------------------------------
// relative calls
// ---------------------------------------------------------------------------------------------

/// The token kinds whose call has to be worked out from the auction so far.
let private isRelative (kind: Kind) : bool =
    match kind with
    | Next
    | Jump
    | Cue
    | CueOver
    | CueLow
    | CueHigh
    | New
    | Step
    | Raise
    | Strain
    | StrainAny
    | Slam
    | NextSuit
    | FourthSuit -> true
    | Bid
    | Pass
    | Double
    | Redouble
    | Any
    | AnyBid
    | AnyCall
    | Game
    | AtLeast
    | Other -> false

/// One way a relative token could resolve: the call it becomes, plus the previous position pinned to
/// the single call it was measured from (when that position is the one immediately before, which is
/// the position `resolveRelative` rewrites).
[<Struct>]
type private Resolution = { Parent: Call; HasParent: bool; Resolved: Call }

/// The index of the last position holding an actual bid.
///
/// Everything here measures "cheapest above" from a *bid*: a raise or a cue over partner's double is
/// still legal, it just has to clear the last bid. -1 when the auction holds no bid at all.
let private lastBidPosition (auction: Auction) : int =
    let mutable found = -1
    let mutable i = auction.Length - 1

    while found < 0 && i >= 0 do
        if
            auction[i]
            |> Array.exists (fun call -> isBid call && not (Suits.isEmpty call.Suits))
        then
            found <- i

        i <- i - 1

    found

/// The index of the opponents' most recent *call*, of any kind.
let private lastOpponentPosition (auction: Auction) : int =
    let mutable found = -1
    let mutable i = auction.Length - 1

    while found < 0 && i >= 0 do
        if auction[i] |> Array.exists (fun call -> call.ByOpponent) then
            found <- i

        i <- i - 1

    found

/// The denominations the auction pinned down to one suit, optionally only one side's. An unresolved
/// `2M` names no single suit, so it neither counts as bid nor rules a suit out.
let private spokenSuits (auction: Auction) (side: Side) : DsQuiz.Bids.Suits =
    let mutable suits = Suits.Empty

    for position in auction do
        for call in position do
            let wanted =
                isBid call
                && Suits.count call.Suits = 1
                && (side = EitherSide || sideOf call.ByOpponent = side)

            if wanted then
                suits <- suits ||| call.Suits

    suits

/// The suits nobody has bid -- neither side. Notrump is not a suit.
let private unbidSuits (auction: Auction) : DsQuiz.Bids.Suits =
    Suits.real &&& ~~~(spokenSuits auction EitherSide)

/// The call in each of `suits`: at `level` when the token named one (`3new`), otherwise the cheapest
/// available (a simple bid, not a jump).
let private inSuits (parent: Call) (suits: Suits) (level: int) : DsQuiz.Bids.Call array =
    [| for suit in Suits.toArray suits do
           if level = 0 then
               match cheapestCall parent suit with
               | ValueSome call -> call
               | ValueNone -> ()
           else
               { parent with
                   Level = level
                   Suits = suit
                   SuitClass = NoClass
                   JumpLevels = 0 } |]

/// The suits of the last bid on the given side -- partner's, for our own tokens.
///
/// When that bid is the one we are measuring from it has already been pinned to a single suit, so
/// use it: `4HS` then `slam` is 6H over 4H or 6S over 4S, never 6S over 4H.
let private partnerSuits
    (auction: Auction)
    (byOpponent: bool)
    (parent: Call)
    (hasParent: bool)
    : DsQuiz.Bids.Suits =
    let mutable answer = Suits.Empty
    let mutable settled = false
    let mutable index = auction.Length - 1

    while not settled && index >= 0 do
        let mutable found = Suits.Empty

        for call in auction[index] do
            if isBid call && call.ByOpponent = byOpponent then
                found <- found ||| call.Suits

        if not (Suits.isEmpty found) then
            settled <- true

            answer <-
                if hasParent && parent.ByOpponent = byOpponent && index = lastBidPosition auction then
                    parent.Suits &&& Suits.all
                else
                    found &&& Suits.all

        index <- index - 1

    answer

/// Support for the last suit partner bid.
///
/// Partner's suit is the last bid on our own side of the table -- usually the call right before
/// ours, but an opponent may have come in between (`2D--(P)--2N--(any)--raise`). `jumpRaise` is one
/// level above the simple raise, and `3raise` names the level outright.
///
/// Caveat: when partner's bid was itself several calls (`2HS`) *and* it is not the call immediately
/// before ours, both raises are offered rather than one per pinned variant -- only the previous
/// position is pinned.
let private raisesFrom (parent: Call) (auction: Auction) (token: Call) : DsQuiz.Bids.Call array =
    let suits = partnerSuits auction token.ByOpponent parent true

    if Suits.isEmpty suits then
        Array.empty
    else
        let calls = inSuits parent suits token.Level

        if token.JumpLevels = 0 then
            calls
        else
            calls
            |> Array.filter (fun call -> call.Level + token.JumpLevels <= 7)
            |> Array.map (fun call -> { call with Level = call.Level + token.JumpLevels })

/// `slam`: the agreed suit -- the last one our side named -- at the slam level, 6 or 7. `6slam` says
/// which.
let private slamsFrom (parent: Call) (auction: Auction) (token: Call) : DsQuiz.Bids.Call array =
    let suits = partnerSuits auction token.ByOpponent parent true
    let levels = if token.Level <> 0 then [| token.Level |] else slamLevels

    [| for suit in Suits.toArray suits do
           match cheapestCall parent suit with
           | ValueSome cheapest ->
               for level in levels do
                   if level >= cheapest.Level then
                       { cheapest with Level = level }
           | ValueNone -> () |]

/// `nextSuit`: the next bid up that is a suit -- the cheapest call above, skipping notrump (a `next`
/// that lands on 3N is not one).
let private nextSuitFrom (parent: Call) : DsQuiz.Bids.Call array =
    let candidates =
        [| for suit in Suits.toArray Suits.real do
               match cheapestCall parent suit with
               | ValueSome call -> call
               | ValueNone -> () |]

    match lowestCall candidates with
    | ValueSome lowest -> [| lowest |]
    | ValueNone -> Array.empty

/// `4thSuit`: fourth-suit-forcing -- the one suit still unbid.
///
/// Only resolvable when exactly one is left; with two or more the token is not describing anything
/// the auction has pinned down.
let private fourthSuitFrom (parent: Call) (auction: Auction) : DsQuiz.Bids.Call array =
    let unbid = unbidSuits auction

    if Suits.count unbid <> 1 then
        Array.empty
    else
        inSuits parent unbid 0

/// The step response(s) to an artificial ask.
///
/// `1step` is one rung up the ladder, `2step` two. `xstep` is "a step response, however many the
/// scheme has" -- the author's reading -- so it stands for the first `StepLimit` of them rather than
/// for one known call.
let private stepsFrom (parent: Call) (step: int) : DsQuiz.Bids.Call array =
    let wanted = if step <> 0 then [| step |] else [| 1..StepLimit |]

    [| for n in wanted do
           match stepCall parent n with
           | ValueSome call -> call
           | ValueNone -> () |]

/// The suit of the last call by the player on our immediate right, the one `CueOver` cues -- as
/// opposed to `cue`, which is any of their suits.
///
/// It is their *last call* that matters, not their last bid: if they doubled, there is nothing to
/// cue over and the token stays unresolved, even though an earlier opponent bid is sitting there.
/// Notrump is dropped, there being no such thing as cueing notrump.
let private rhoSuits (parent: Call) (auction: Auction) : DsQuiz.Bids.Suits =
    let last = lastOpponentPosition auction

    if last < 0 then
        Suits.Empty
    elif parent.ByOpponent && last = lastBidPosition auction then
        // their last call *is* the bid we are measuring from, already pinned
        parent.Suits &&& Suits.real
    else
        let mutable suits = Suits.Empty

        for call in auction[last] do
            if isBid call then
                suits <- suits ||| call.Suits

        suits &&& Suits.real

/// `cueLow` / `cueHi`: a cue of the lower- or higher-ranking of *their two suits*. Only resolvable
/// when the auction shows two opponent suits.
let private pickedCue (parent: Call) (auction: Auction) (token: Call) : DsQuiz.Bids.Call array =
    let theirs = spokenSuits auction TheirSide

    if Suits.count theirs < 2 then
        Array.empty
    else
        let wantLow = token.Kind = CueLow
        let mutable picked = Suits.Empty
        let mutable best = 0

        for suit in Suits.toArray theirs do
            let rank = Suits.rank suit

            if Suits.isEmpty picked || (if wantLow then rank < best else rank > best) then
                picked <- suit
                best <- rank

        inSuits parent picked token.Level

/// A cue bid: their suit. Unqualified it is the *lowest* cue available, so with two opponent suits
/// shown only the cheaper one counts.
let private cuesFrom (parent: Call) (auction: Auction) (level: int) : DsQuiz.Bids.Call array =
    let calls = inSuits parent (spokenSuits auction TheirSide) level

    if level = 0 && calls.Length > 0 then
        match lowestCall calls with
        | ValueSome lowest -> [| lowest |]
        | ValueNone -> calls
    else
        calls

/// Every call `jump` could be over `parent`: a jump in a *new suit*.
///
/// A jump is `levels` above the cheapest bid available in that suit, never in notrump (a jump to 3N
/// is a different animal), and never in a suit already bid. "Already bid" counts only calls the
/// auction pinned down to one denomination, so an unresolved `2M` does not silently rule both majors
/// out.
let private jumpsFrom (parent: Call) (levels: int) (auction: Auction) : DsQuiz.Bids.Call array =
    let spoken = spokenSuits auction EitherSide ||| parent.Suits

    [| for suit in Suits.toArray (Suits.real &&& ~~~spoken) do
           match cheapestCall parent suit with
           | ValueSome cheapest when cheapest.Level + levels <= 7 ->
               { cheapest with Level = cheapest.Level + levels }
           | _ -> () |]

/// `!c+`: that strain at whatever level it takes, so every legal bid in it from the cheapest upward.
let private strainAnyFrom (parent: Call) (suits: Suits) : DsQuiz.Bids.Call array =
    [| for cheapest in inSuits parent suits 0 do
           for level in cheapest.Level .. 7 do
               { cheapest with Level = level } |]

/// (pinned previous call, the call the token resolves to) for each call the previous position could
/// have been.
let private resolutionsOf (relative: Call) (auction: Auction) : Resolution array =
    let source = lastBidPosition auction

    if source < 0 then
        Array.empty
    else
        let pin = source = auction.Length - 1

        [| for previous in auction[source] do
               for suit in Suits.toArray previous.Suits do
                   let parent = { previous with Suits = suit; SuitClass = NoClass }

                   let calls =
                       match relative.Kind with
                       | Next ->
                           match nextCall parent with
                           | ValueSome call -> [| call |]
                           | ValueNone -> Array.empty
                       | Jump -> jumpsFrom parent relative.JumpLevels auction
                       | New -> inSuits parent (unbidSuits auction) relative.Level
                       // a denomination with no level: the simple (non-jump) bid in it
                       | Strain -> inSuits parent relative.Suits 0
                       | StrainAny -> strainAnyFrom parent relative.Suits
                       | Raise -> raisesFrom parent auction relative
                       | Slam -> slamsFrom parent auction relative
                       | NextSuit -> nextSuitFrom parent
                       | FourthSuit -> fourthSuitFrom parent auction
                       | Step -> stepsFrom parent relative.Level
                       | CueOver -> inSuits parent (rhoSuits parent auction) relative.Level
                       | CueLow
                       | CueHigh -> pickedCue parent auction relative
                       | _ -> cuesFrom parent auction relative.Level

                   for call in calls do
                       { Parent = parent; HasParent = pin; Resolved = call } |]

let private appendPosition (auction: Auction) (position: Position) : Auction =
    Array.append auction [| position |]

/// Replaces `next` with the call it stands for: the cheapest bid above the position before it
/// (`4HS = splinter` then `next = RKB` is 4S over 4H).
///
/// Returns the auctions that produces. A parent naming several calls gives one auction per call,
/// *with the parent pinned* -- 4H then 4S, or 4S then 4N, and never 4H then 4N, which no line of the
/// table describes. A `next` whose parent is not a bid at all (`any`, prose) stays unresolved and so
/// matches nothing: the auction never said which call it was.
///
/// Run *after* `expandCorrelated`, so a parent whose suit class was bound is already concrete.
let resolveRelative (auction: Auction) : Auction array =
    let mutable auctions = [| Array.empty<Position> |]

    for position in auction do
        let relatives = position |> Array.filter (fun call -> isRelative call.Kind)

        if relatives.Length > 0 && auctions[0].Length > 0 then
            let grown = ResizeArray<Auction> auctions.Length

            for built in auctions do
                let mutable resolvedAny = false

                for relative in relatives do
                    // `!c/!d` is two relative tokens at one position, so every one of them
                    // contributes its resolutions
                    for resolution in resolutionsOf relative built do
                        resolvedAny <- true

                        let call = { resolution.Resolved with ByOpponent = relative.ByOpponent }

                        if resolution.HasParent then
                            let pinned = Array.copy built
                            pinned[pinned.Length - 1] <- [| resolution.Parent |]
                            grown.Add(appendPosition pinned [| call |])
                        else
                            // the call we measured from is further back than the previous position,
                            // so there is nothing to pin here
                            grown.Add(appendPosition built [| call |])

                if not resolvedAny then
                    // unresolvable, keep as is
                    grown.Add(appendPosition built position)

            auctions <- grown.ToArray()
        else
            auctions <- auctions |> Array.map (fun built -> appendPosition built position)

    auctions
