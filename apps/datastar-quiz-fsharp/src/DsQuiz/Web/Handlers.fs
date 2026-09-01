/// Every route.
///
/// The shape of all of them: resolve the session, do the state work SYNCHRONOUSLY under its lock,
/// collect the events, then stream. The one exception is `/answer`, which streams *while* pausing
/// between beats -- and even there the whole state change is applied before the first byte goes out, so
/// a reload mid-notification shows the finished score rather than a half-scored session.
///
/// A 204 IS A NO-OP, NOT AN ERROR. A datastar response with no events is `204 No Content`, and this app
/// returns one deliberately whenever a press no longer applies: Skip with none left, Next while not on
/// a reveal, a settings POST that changed nothing, an answer to a finished quiz, `/timer` in client
/// mode, any debug route on an unarmed session. The load harness treats 200 and 204 alike; a server
/// answering 200 with an empty body would be lying about having done something.
module DsQuiz.Web.Handlers

open System
open System.Text
open System.Text.Json
open System.Threading.Tasks
open Microsoft.AspNetCore.Http
open Oxpecker

open DsQuiz
open DsQuiz.Engine
open DsQuiz.Render
open DsQuiz.Session
open DsQuiz.Web.Frames

/// The element targets. Only these are ever patched as elements; everything else the server owns
/// arrives as `_`-prefixed signals.
[<Literal>]
let AppSelector = "#app"

[<Literal>]
let QuizSelector = "#quiz"

[<Literal>]
let ToastsSelector = "#toasts"

/// The sound sink lives OUTSIDE `#app`, with the `<audio>` elements, so a fat morph cannot disturb a
/// sound mid-play. The gauge is inside it, which is exactly what the milestone sweep wants: the next
/// view patch takes the shine away with no cleanup.
[<Literal>]
let SfxSelector = "#sfx"

[<Literal>]
let MeterSelector = "#app .points-meter"

[<Literal>]
let FilterStatusSelector = "#filter-status"

[<Literal>]
let TopicsStatusSelector = "#topics-status"

/// Everything a handler needs, built once at startup and shared by every request.
[<NoEquality; NoComparison>]
type AppState =
    { Config: Config.Config
      Renderer: Page.Config
      Corpus: Corpus.Corpus
      Store: Store
      Assets: Collections.Generic.Dictionary<string, Assets.Asset> }

// ---------------------------------------------------------------------------------------------
// signals
// ---------------------------------------------------------------------------------------------

/// The signals a request carries, read into a snapshot.
///
/// NOT a live `JsonDocument`: that type rents pooled buffers and has to be disposed, and threading its
/// lifetime through a paced answer stream is a leak waiting to happen. The shapes are loose on purpose
/// (datastar sends whatever the browser has, and the python accepted int/float/str/bool for every one of
/// them), so the coercions happen HERE, once, and the rest of the file sees settled values.
///
/// `voption` throughout because ABSENT AND FALSE ARE DIFFERENT: a request that does not mention
/// `ladderMode` must leave the session's own value alone, while one that sends `false` must turn it off.
[<NoEquality; NoComparison>]
type SignalPayload =
    {
        Difficulty: int voption
        LadderMode: bool voption
        TargetOn: bool voption
        TargetPct: int voption
        FilterText: string voption
        /// the topic signal keys the picker has ticked
        Ticked: Collections.Generic.HashSet<string>
    }

let emptyPayload =
    { Difficulty = ValueNone
      LadderMode = ValueNone
      TargetOn = ValueNone
      TargetPct = ValueNone
      FilterText = ValueNone
      Ticked = Collections.Generic.HashSet<string>(StringComparer.Ordinal) }

/// python's `bool(x)` over a decoded JSON value.
let private truthy (element: JsonElement) : bool =
    match element.ValueKind with
    | JsonValueKind.True -> true
    | JsonValueKind.False -> false
    | JsonValueKind.Number -> element.GetDouble() <> 0.0
    | JsonValueKind.String -> element.GetString() <> ""
    | JsonValueKind.Array -> element.GetArrayLength() > 0
    | JsonValueKind.Object -> element.EnumerateObject() |> Seq.isEmpty |> not
    | _ -> false

/// python's `int(x)` with its TypeError/ValueError suppressed.
let private asInt (element: JsonElement) : int voption =
    match element.ValueKind with
    | JsonValueKind.Number ->
        // truncates toward zero, as python's int() does
        ValueSome(int (element.GetDouble()))
    | JsonValueKind.String ->
        match Int32.TryParse((element.GetString()).Trim()) with
        | true, parsed -> ValueSome parsed
        | _ -> ValueNone
    | JsonValueKind.True -> ValueSome 1
    | JsonValueKind.False -> ValueSome 0
    | _ -> ValueNone

/// Reads a signals payload. Anything unparseable is no signals at all -- the same answer the python
/// gives, and the routes all have a sensible reading of "the browser said nothing".
let parsePayload (json: string) : SignalPayload =
    if String.IsNullOrWhiteSpace json then
        emptyPayload
    else
        try
            use document = JsonDocument.Parse json
            let root = document.RootElement

            if root.ValueKind <> JsonValueKind.Object then
                emptyPayload
            else
                let field (name: string) =
                    match root.TryGetProperty name with
                    | true, value -> ValueSome value
                    | _ -> ValueNone

                let ticked = Collections.Generic.HashSet<string>(StringComparer.Ordinal)

                match field "topics" with
                | ValueSome topics when topics.ValueKind = JsonValueKind.Object ->
                    for entry in topics.EnumerateObject() do
                        if truthy entry.Value then
                            ticked.Add entry.Name |> ignore
                | _ -> ()

                { Difficulty =
                    match field "difficulty" with
                    | ValueSome element -> asInt element
                    | ValueNone -> ValueNone
                  LadderMode = field "ladderMode" |> ValueOption.map truthy
                  TargetOn = field "targetOn" |> ValueOption.map truthy
                  TargetPct =
                    match field "targetPct" with
                    | ValueSome element -> asInt element
                    | ValueNone -> ValueNone
                  FilterText =
                    match field "filterText" with
                    | ValueSome element when element.ValueKind = JsonValueKind.String ->
                        ValueSome(element.GetString())
                    | _ -> ValueNone
                  Ticked = ticked }
        with _ ->
            emptyPayload

/// Adopts the bound signals the browser just sent, returning the next state and whether anything moved.
///
/// The browser is the source of truth for these -- they originate there and are uploaded with every
/// request -- so the session merely mirrors them. A change restarts the quiz, exactly as the panel
/// watchers did.
let private syncSettings (payload: SignalPayload) (state: State) : struct (DsQuiz.Session.State * bool) =
    let before = state.Settings

    let settings =
        { Difficulty =
            match payload.Difficulty with
            | ValueSome _ -> clampDifficulty payload.Difficulty
            | ValueNone -> before.Difficulty
          LadderMode = ValueOption.defaultValue before.LadderMode payload.LadderMode
          TargetOn = ValueOption.defaultValue before.TargetOn payload.TargetOn
          TargetPct =
            match payload.TargetPct with
            | ValueSome pct -> Math.Clamp(pct, 70, 90)
            | ValueNone -> before.TargetPct }

    struct ({ state with Settings = settings }, settings <> before)

let private filterTextFrom (payload: SignalPayload) : string =
    ValueOption.defaultValue "" payload.FilterText

/// Ticked topic slugs back into the filter text they stand for.
///
/// Signal paths cannot hold spaces, so the picker binds kebab-case slugs, which datastar stores
/// camel-cased. The real topic names live here, on the server, so an unknown key simply does not select
/// anything.
let private topicsTextFrom (system: Corpus.System) (payload: SignalPayload) : string =
    Names.topicChoices system
    |> Array.filter (fun choice -> payload.Ticked.Contains choice.Key)
    |> Array.map (fun choice -> choice.Name)
    |> String.concat ", "

// ---------------------------------------------------------------------------------------------
// requests
// ---------------------------------------------------------------------------------------------

/// The raw query string, without its `?`. Read as-is: the datastar signals ride in it on GET routes and
/// re-parsing them into a dictionary would be a second pass over the ~800 bytes already in hand.
let private rawQuery (ctx: HttpContext) : string =
    let value = ctx.Request.QueryString.Value

    if String.IsNullOrEmpty value then "" else value.Substring 1

/// One query parameter, percent-decoded. `+` is a space, as in a form-encoded query.
let private queryParam (name: string) (query: string) : string =
    let mutable found = ""

    for pair in query.Split '&' do
        if found = "" && pair.StartsWith(name + "=", StringComparison.Ordinal) then
            found <- Uri.UnescapeDataString(pair.Substring(name.Length + 1).Replace("+", " "))

    found

/// Signals on a GET arrive as `?datastar=<json>`.
let private signalsFromQuery (query: string) : SignalPayload =
    parsePayload (queryParam "datastar" query)

let private readBodyAsync (ctx: HttpContext) : System.Threading.Tasks.Task<SignalPayload> =
    task {
        use reader = new IO.StreamReader(ctx.Request.Body, Text.Encoding.UTF8)
        let! body = reader.ReadToEndAsync ctx.RequestAborted
        return parsePayload body
    }

let private cookieValue (name: string) (ctx: HttpContext) : string =
    match ctx.Request.Cookies.TryGetValue name with
    | true, value -> value
    | _ -> ""

/// This browser's session for the variant this request belongs to, or a new one, plus whether the
/// browser arrived with an identity we no longer have a quiz for.
///
/// The variant is resolved FIRST, because it is half the key: sessions live under (browser, variant) so
/// the two systems coexist. When the request names none, the browser's last navigated-to variant stands
/// in, and failing that the default.
///
/// The `replaced` flag records a browser arriving with an identity we no longer have a quiz for -- a
/// restart, a six-hour gap -- so the play routes can resync the page instead of quietly scoring against
/// a question it has never shown.
let private sessionFor
    (app: AppState)
    (ctx: HttpContext)
    (wanted: Corpus.System voption)
    : struct (DsQuiz.Session.Session * bool) =
    let sid = cookieValue Cookie ctx

    let system =
        match wanted with
        | ValueSome system -> system
        | ValueNone ->
            match Store.currentVariant sid app.Store with
            | ValueSome key ->
                match Corpus.Corpus.tryGet key app.Corpus with
                | ValueSome system -> system
                | ValueNone -> Corpus.Corpus.defaultSystem app.Corpus
            | ValueNone -> Corpus.Corpus.defaultSystem app.Corpus

    match Store.tryGet sid system.Variant.Key app.Store with
    | ValueSome found -> struct (found, false)
    | ValueNone ->
        let replaced = sid <> ""
        let sid = if sid = "" then ValueNone else ValueSome sid
        struct (Store.create' system sid app.Store, replaced)

/// `sessionFor` for an interaction: only an explicitly named variant switches it. Reading a *bare* path
/// as "take me to the default" would throw a swedish player back to squad on their first click.
let private playSession (app: AppState) (ctx: HttpContext) : struct (DsQuiz.Session.Session * bool) =
    sessionFor app ctx (Corpus.Corpus.requestedVariant (rawQuery ctx) app.Corpus)

let private writeCookie (app: AppState) (session: Session) (ctx: HttpContext) : unit =
    let path = if app.Config.Prefix = "" then "/" else app.Config.Prefix

    ctx.Response.Headers.SetCookie <-
        Microsoft.Extensions.Primitives.StringValues(
            $"{Cookie}={session.Sid}; Path={path}; HttpOnly; SameSite=Lax"
        )

/// Whether the page this request came from is talking about a quiz that no longer exists.
///
/// Two ways: the session itself is gone (`replaced`), so *nothing* the page says applies; or the
/// question nonce has moved on -- a double click, a replayed request, a background tab. Since qids are
/// unique per process, the second test is exact.
let private stale (replaced: bool) (qid: int64 voption) (state: State) : bool =
    replaced
    || (
        match qid with
        | ValueSome sent -> sent <> state.Qid
        | ValueNone -> false
    )

// ---------------------------------------------------------------------------------------------
// events
// ---------------------------------------------------------------------------------------------

/// The standard "make the browser agree with the session" set.
///
/// Server-owned signals *and* the effective settings: the browser proposed those, but the server clamps
/// them, so echoing them is what stops a rejected value sitting in the UI until a reload. Drafts
/// (`filterText`, topic ticks) are excluded.
let private viewPatches (app: AppState) (state: State) : string array =
    let elements =
        if app.Config.FatMorph then
            patchElements (Compose.appBody app.Renderer state) AppSelector Inner
        else
            patchElements (Compose.quizBody app.Renderer state) QuizSelector Inner

    [| elements; patchSignals (Signals.viewSignals state) |]

/// Answers a stale interaction by making the page tell the truth again.
///
/// The old answer was a bare 204: correct, in that nothing should be scored, but from the player's chair
/// it is a dead button -- and the page stays wrong, so the next click is stale too. This re-renders the
/// whole page from the session that actually exists, which is the one thing that ends the loop, and says
/// so.
///
/// The FAT patch even in fragment-morph mode: what is stale here is not just the question. The title,
/// the score, the drawer and the topics all belong to a quiz this browser is no longer in.
let private resync (app: AppState) (state: State) : string array =
    let notice =
        { Kind = ToastWarning
          Text = "Quiz reloaded — this page has caught up"
          Pause = 0.0
          PointsAfter = ValueNone
          AwardsSkip = false }

    [| patchElements (Compose.appBody app.Renderer state) AppSelector Inner
       patchSignals (Signals.viewSignals state)
       patchElements (Page.toastFragment notice) ToastsSelector Inner |]

let private clearToasts = patchElements "" ToastsSelector Inner

/// Empties the sound sink before an answer appends its beats to it.
///
/// The markers are appended rather than morphed, so without this they would accumulate for the life of
/// the page. Clearing at the START rather than the end also means a marker is never removed while the
/// sound it started is still playing -- the `<audio>` element is what plays, and it lives outside the
/// sink.
let private clearSfx = patchElements "" SfxSelector Inner

/// The card the player just chose.
///
/// `nth-child` rather than `nth-of-type`: every child of the group is a button, so they agree, and
/// nth-child does not care if a future revision wraps them. The floaters need no cleanup -- both
/// outcomes replace `#quiz` wholesale a moment later.
let private pickedCardSelector (index: int) : string =
    QuizSelector + " .candidates > :nth-child(" + string (index + 1) + ")"

/// Writes the cookie and then the events, as one compressed SSE response -- or a 204 when there are
/// none.
let private respondAsync
    (app: AppState)
    (session: Session)
    (events: string array)
    (ctx: HttpContext)
    : System.Threading.Tasks.Task =
    task {
        writeCookie app session ctx

        if events.Length = 0 then
            ctx.Response.StatusCode <- StatusCodes.Status204NoContent
        else
            use writer = Sse.start ctx

            for event in events do
                do! writer.PushAsync(event, ctx.RequestAborted)

            do! writer.FinishAsync ctx.RequestAborted
    }
    :> Task

// ---------------------------------------------------------------------------------------------
// the page
// ---------------------------------------------------------------------------------------------

let private debugAllowed (app: AppState) (query: string) : bool =
    match app.Config.Debug with
    | Config.DebugNever -> false
    | Config.DebugAlways -> true
    | Config.DebugPerSession -> query.Contains("debug", StringComparison.OrdinalIgnoreCase)

/// The full page. Everything the browser knows starts here, in view-source.
///
/// Also where the debug flag is decided, and only here: the datastar interactions POST to bare paths
/// with no query, so re-reading `?debug` per request would switch the panel off on the first click. Set
/// on page load, sticky for the session.
let index (app: AppState) : EndpointHandler =
    fun ctx ->
        let query = rawQuery ctx

        // A bare URL additionally means the default variant, and only a real navigation can carry that
        // meaning.
        let struct (session, _) =
            sessionFor app ctx (Corpus.Corpus.variantSwitchForQuery query app.Corpus)

        // The theme is the browser's preference, not the session's: it is written by the toggle into its
        // own cookie and only relayed here, so it survives a new session, a restart and a second tab.
        let theme = Page.themeFrom (cookieValue Page.ThemeCookie ctx)

        let html =
            session
            |> Session.update (fun state ->
                let next = { state with Debug = debugAllowed app query }
                struct (next, Compose.shell app.Renderer next theme)
            )

        // A NAVIGATION is the only thing that moves the mark for "which system this browser is on",
        // which is what an ambiguous later page load (`?debug`, naming no variant) resolves against.
        Store.remember session.Sid session.System.Variant.Key app.Store

        writeCookie app session ctx
        ctx.Response.StatusCode <- StatusCodes.Status200OK
        ctx.Response.Headers.ContentType <- "text/html; charset=utf-8"
        // this page IS session state -- the current question, the score, the reveal you are parked on --
        // rendered into HTML, so a cached copy is a stale question at best
        ctx.Response.Headers.CacheControl <- "no-store"
        Sse.writeCompressedAsync ctx (Text.Encoding.UTF8.GetBytes html)

// ---------------------------------------------------------------------------------------------
// answering
// ---------------------------------------------------------------------------------------------

/// What scoring decided, handed from the locked section to the stream.
[<NoEquality; NoComparison>]
type private Verdict =
    /// nothing to do: a finished quiz, or an index that is not a candidate
    | Nothing
    /// the page is talking about a quiz that no longer exists
    | Resync of string array
    | Scored of Answered * int * int

/// Scores one answer, then streams the notifications the way panel showed them.
///
/// `floaters` is off for `/debug/complete`: the browser is showing whatever it was showing (often the
/// previous finale, since that route restarts a finished quiz), so a patch aimed at `.candidates >
/// :nth-child(n)` finds no target and datastar logs a warning for every scoring beat.
let private scoreAnswerAsync
    (app: AppState)
    (session: Session)
    (replaced: bool)
    (qid: int64)
    (index: int)
    (floaters: bool)
    (payload: SignalPayload)
    (ctx: HttpContext)
    : System.Threading.Tasks.Task =
    let verdict =
        session
        |> Session.update (fun state ->
            if stale replaced (ValueSome qid) state then
                struct (state, Resync(resync app state))
            elif not (State.stillPlaying state) || index >= state.Question.Candidates.Length then
                struct (state, Nothing)
            else
                let struct (state, _) = syncSettings payload state

                let candidate = state.Question.Candidates[index]
                // the bonus that scores is measured HERE, from the server's own clock -- the browser's
                // countdown bar is only an animation
                let percentLeft = State.percentTimeLeft state

                let scored =
                    answer
                        state.Score
                        { Question = state.Question
                          Candidate = candidate
                          PercentLeft = percentLeft
                          LadderMode = state.Settings.LadderMode
                          TargetOn = state.Settings.TargetOn
                          TargetPct = state.Settings.TargetPct
                          LastCorrectPoints = state.LastCorrectPoints
                          PointsGoal = state.PointsGoal }

                let settled =
                    { state with
                        Score = scored.Score
                        LastCorrectPoints = scored.LastCorrectPoints
                        SkipsLeft = state.SkipsLeft + scored.Outcome.AwardedSkips }
                    // the clock stops the moment the answer is scored -- everything after this point
                    // should report what was left, not keep draining
                    |> State.freezeQuestionClock

                // STATE IS SETTLED BEFORE A SINGLE BYTE IS STREAMED, so a reload mid-notification shows
                // the finished score and the next question rather than a half-applied answer
                let settled =
                    if scored.Outcome.Completed then
                        State.complete settled
                    elif scored.Outcome.Correct then
                        State.nextQuestion settled
                    else
                        // park on the reveal instead: the answer is shown in place, and the player
                        // advances when they are ready
                        { settled with AwaitingNext = true; WrongIndex = ValueSome index }

                struct (settled, Scored(scored.Outcome, settled.PointsGoal, settled.Score.Streak))
        )

    match verdict with
    | Nothing -> respondAsync app session Array.empty ctx
    | Resync events -> respondAsync app session events ctx
    | Scored(outcome, goal, streak) ->
        // THE PANEL NOTIFICATION CHAIN, AS ONE SSE RESPONSE. `on_answer_click` awaited
        // `asyncio.sleep` between notification calls; the same pacing survives here, with each beat as
        // an element patch and the pauses as `Task.Delay` -- which is one of the differences this port
        // exists to measure.
        task {
            writeCookie app session ctx
            use writer = Sse.start ctx
            let ct = ctx.RequestAborted
            let push (event: string) = writer.PushAsync(event, ct)

            // The streak lands with the FIRST beat, not with the view patch at the end of the stream:
            // the chip is the reward for the answer that was just given, and arriving two or three
            // seconds late read as belonging to the following question.
            let streakSignal =
                Signals.start 32 |> Signals.number "_streak" streak |> Signals.finish

            do! push (patchSignals streakSignal)

            // Sound rides the same beats, gated client-side on `$_sound`. The verdict chime goes FIRST,
            // before the toast it belongs to, because a sound that arrives after the words have appeared
            // reads as a response to reading them.
            let verdictSound = if outcome.Correct then "correct" else "wrong"
            do! push clearSfx
            do! push (patchElements (Page.sfxBeatFragment verdictSound) SfxSelector Append)

            for toast in outcome.Toasts do
                do! push (patchElements (Page.toastFragment toast) ToastsSelector Inner)

                // A milestone has just paid for a skip: the gauge that measures milestones says so
                // itself, rather than leaving it to one toast among four. Both halves are one-shot
                // appends -- the shine is taken away by the view patch at the end of the stream, the
                // sound marker by the `clearSfx` of the next answer.
                if toast.AwardsSkip then
                    do! push (patchElements Page.MeterSweepFragment MeterSelector Append)
                    do! push (patchElements (Page.sfxBeatFragment "skip") SfxSelector Append)

                match toast.PointsAfter with
                | ValueSome points ->
                    // the SESSION's goal, not the constant: with a debug goal of 200 these mid-stream
                    // percentages were computed against 1000 while the view patch used 200, so the gauge
                    // jumped backwards when the final patch arrived
                    let signals =
                        Signals.start 64
                        |> Signals.number "_points" points
                        |> Signals.number "_pointsPct" (Signals.pointsPercent points goal)
                        |> Signals.finish

                    do! push (patchSignals signals)
                | ValueNone -> ()

                if floaters then
                    let floater = Page.floaterFragment toast outcome.Completed

                    if floater <> "" then
                        do! push (patchElements floater (pickedCardSelector index) Append)

                if toast.Pause > 0.0 then
                    do! Task.Delay(TimeSpan.FromSeconds toast.Pause, ct)

            // The finale's own sound, once per quiz, with the completion screen rather than with the
            // answer: the gold floater and the confetti are the same beat, and the fanfare is long
            // enough that firing it beside the "Correct!" chime would be two flourishes over each other.
            if outcome.Completed then
                do! push (patchElements (Page.sfxBeatFragment "final") SfxSelector Append)

            do! push clearToasts

            let patches =
                session
                |> Session.update (fun state ->
                    // the clock starts when the question reaches the player, not when it was drawn --
                    // the notifications above took real seconds and they are not thinking time
                    let next =
                        if State.stillPlaying state && not state.AwaitingNext then
                            State.startQuestionClock state
                        else
                            state

                    struct (next, viewPatches app next)
                )

            for patch in patches do
                do! push patch

            do! writer.FinishAsync ct
        }
        :> Task

let answer (app: AppState) (qid: int64) (index: int) : EndpointHandler =
    fun ctx ->
        task {
            let struct (session, replaced) = playSession app ctx
            let! signals = readBodyAsync ctx
            do! scoreAnswerAsync app session replaced qid index true signals ctx
        }
        :> Task

// ---------------------------------------------------------------------------------------------
// the other play routes
// ---------------------------------------------------------------------------------------------

/// The shape every simple interaction has: read the body, take the lock, decide, respond.
///
/// `decide` gets the state with the browser's settings already adopted and returns the next state plus
/// the events. Returning no events is the 204.
let private interactionAsync
    (app: AppState)
    (checkStale: bool)
    (decide: SignalPayload -> State -> struct (State * string array))
    : EndpointHandler =
    fun ctx ->
        task {
            let struct (session, replaced) = playSession app ctx
            let! signals = readBodyAsync ctx

            let events =
                session
                |> Session.update (fun state ->
                    if checkStale && stale replaced ValueNone state then
                        struct (state, resync app state)
                    else
                        decide signals state
                )

            do! respondAsync app session events ctx
        }
        :> Task

/// Leaves the revealed answer and draws the next question.
///
/// Only valid while parked on a reveal, so a stray press cannot skip a live question -- that is what
/// Skip is for, and it costs a skip.
let next (app: AppState) : (Microsoft.AspNetCore.Http.HttpContext -> System.Threading.Tasks.Task) =
    interactionAsync
        app
        true
        (fun signals state ->
            let struct (state, _) = syncSettings signals state

            if not state.AwaitingNext || not (State.stillPlaying state) then
                struct (state, Array.empty)
            else
                let next = State.nextQuestion state
                struct (next, Array.append [| clearToasts |] (viewPatches app next))
        )

/// Spends a skip, if a milestone has paid for one.
let skip (app: AppState) : (Microsoft.AspNetCore.Http.HttpContext -> System.Threading.Tasks.Task) =
    interactionAsync
        app
        true
        (fun signals state ->
            let struct (state, _) = syncSettings signals state

            if state.SkipsLeft <= 0 || not (State.stillPlaying state) then
                struct (state, Array.empty)
            else
                let next = State.nextQuestion { state with SkipsLeft = state.SkipsLeft - 1 }
                struct (next, Array.append [| clearToasts |] (viewPatches app next))
        )

let restart (app: AppState) : (Microsoft.AspNetCore.Http.HttpContext -> System.Threading.Tasks.Task) =
    interactionAsync
        app
        false
        (fun signals state ->
            let struct (state, _) = syncSettings signals state
            let next = State.restart state
            struct (next, Array.append [| clearToasts |] (viewPatches app next))
        )

/// Difficulty / ladder mode / target percentage arrive as bound signals.
///
/// Panel restarted the quiz on every such change, so this does too -- and only when a value actually
/// moved, so a re-sent identical signal set is free.
let settings (app: AppState) : (Microsoft.AspNetCore.Http.HttpContext -> System.Threading.Tasks.Task) =
    interactionAsync
        app
        false
        (fun signals state ->
            let struct (state, changed) = syncSettings signals state

            if not changed then
                struct (state, Array.empty)
            else
                let next = State.restart state
                struct (next, Array.append [| clearToasts |] (viewPatches app next))
        )

// ---------------------------------------------------------------------------------------------
// the held countdown
// ---------------------------------------------------------------------------------------------

/// How often the held stream pushes, matching the client interval exactly -- the two push models must
/// agree about the bar's motion or the mode becomes visible to the player.
let private TimerTick = TimeSpan.FromMilliseconds 100.0

/// A held stream needs an upper bound, or an abandoned tab keeps a connection and a session alive
/// forever. Ten minutes is far longer than any question; the client reopens on the next page load.
let private TimerStreamMax = TimeSpan.FromMinutes 10.0

/// The held-connection countdown: panel's push model, for comparison with the client interval.
///
/// Only reachable when `DSQUIZ_TIMER=stream`; the shell wires `data-init` to it in that mode and omits
/// the `data-on-interval` attribute, so exactly one of the two is ever live.
///
/// Note what this costs against the client-interval default: a tick per 100ms per connected tab, each
/// one a signal patch over the wire, whether or not the value changed. On python that is the mode nobody
/// would ship; here it is a `PeriodicTimer` and a task.
let timer (app: AppState) : EndpointHandler =
    fun ctx ->
        task {
            let struct (session, _) = playSession app ctx

            if not app.Config.StreamTimer then
                do! respondAsync app session Array.empty ctx
            else
                writeCookie app session ctx
                use writer = Sse.start ctx
                let ct = ctx.RequestAborted
                use ticker = new Threading.PeriodicTimer(TimerTick)
                let deadline = DateTime.UtcNow.Add TimerStreamMax
                let mutable running = true

                while running && not ct.IsCancellationRequested do
                    let state = Session.read session
                    let playing = State.stillPlaying state

                    if not playing then
                        let signals = Signals.start 32 |> Signals.number "_timeLeftPct" 0 |> Signals.finish

                        do! writer.PushAsync(patchSignals signals, ct)
                        running <- false
                    else
                        // Nothing to push while parked on a reveal: the question has been answered, so
                        // the clock is frozen and every tick would restate the same number. The client
                        // interval gates on the same condition (`$_ticking`).
                        if State.onTheClock state then
                            let signals =
                                Signals.start 32
                                |> Signals.number "_timeLeftPct" (State.percentTimeLeft state)
                                |> Signals.finish

                            do! writer.PushAsync(patchSignals signals, ct)

                        if DateTime.UtcNow > deadline then
                            running <- false
                        else
                            let! ticked = ticker.WaitForNextTickAsync ct
                            running <- ticked

                do! writer.FinishAsync ct
        }
        :> Task

// ---------------------------------------------------------------------------------------------
// the bidding-tree filter
// ---------------------------------------------------------------------------------------------

/// What the text in the box *would* select. Commits nothing.
///
/// This is the panel `value_input` watcher, except the validation never left the server. Cheap enough to
/// run per keystroke because the corpus is pre-parsed and the check is memoised.
let private previewAsync
    (app: AppState)
    (session: Session)
    (text: string)
    (selector: string)
    (hint: string)
    ctx
    : System.Threading.Tasks.Task =
    let state = Session.read session
    let check = Corpus.System.checkFilter text MaxDifficulty session.System

    let events =
        [| patchElements (Page.filterStatusFragment check state.FilterText hint) selector Inner |]

    respondAsync app session events ctx

let filterPreview (app: AppState) : EndpointHandler =
    fun ctx ->
        let query = rawQuery ctx
        let struct (session, _) = playSession app ctx
        let signals = signalsFromQuery query
        previewAsync app session (filterTextFrom signals) FilterStatusSelector "press Enter to apply" ctx

let topicsPreview (app: AppState) : EndpointHandler =
    fun ctx ->
        let query = rawQuery ctx
        let struct (session, _) = playSession app ctx
        let signals = signalsFromQuery query

        previewAsync
            app
            session
            (topicsTextFrom session.System signals)
            TopicsStatusSelector
            "press Apply to use this"
            ctx

/// Close (and Escape) DISCARD the ticks, putting them back to the filter in force.
///
/// The picker has an explicit Apply and says so in its own first line, which makes Close the cancel path
/// -- and a cancel that quietly keeps your edits is the odd one out among dialogs. Keeping them also
/// left the picker disagreeing with the app.
///
/// Only the `topics` branch is patched. The bound signals also carry the difficulty and `filterText`,
/// and `filterText` is a DRAFT the player may be part-way through typing in the drawer behind the dialog
/// -- re-sending it here would wipe it.
let topicsReset (app: AppState) : EndpointHandler =
    fun ctx ->
        let struct (session, _) = playSession app ctx
        let state = Session.read session
        let check = Corpus.System.checkFilter state.FilterText MaxDifficulty session.System
        let choices = Names.topicChoices session.System

        let ticked =
            check.Parsed.TopicNames |> Array.map Names.topicSignalKey |> Set.ofArray

        let flags =
            choices
            |> Array.map (fun choice ->
                Collections.Generic.KeyValuePair(choice.Key, ticked.Contains choice.Key)
            )

        let signals = Signals.start 256 |> Signals.flags "topics" flags |> Signals.finish

        let events =
            [| patchSignals signals
               // ...and the picker's own status line, which was previewing a selection that no longer
               // exists. Empty rather than re-rendered: with nothing pending there is nothing to say.
               patchElements "" TopicsStatusSelector Inner |]

        respondAsync app session events ctx

/// The one path that changes the filter in force.
let private commitFilterAsync
    (app: AppState)
    (session: Session)
    (text: string)
    ctx
    : System.Threading.Tasks.Task =
    let events =
        session
        |> Session.update (fun state ->
            let struct (applied, check, changed) = State.applyFilter text MaxDifficulty state
            let choices = Names.topicChoices session.System

            let bound =
                Signals.start 512
                |> Signals.boundSignals applied choices check.Parsed.TopicNames
                |> Signals.finish

            let head =
                [| patchElements
                       (Page.filterStatusFragment check applied.FilterText "")
                       FilterStatusSelector
                       Inner
                   patchElements "" TopicsStatusSelector Inner
                   // the box and the picker are brought into line with what was actually applied: the
                   // canonical text has topic prefixes expanded and the whitespace tidied
                   patchSignals bound |]

            if changed then
                let restarted = State.restart applied

                struct (restarted, Array.concat [ head; [| clearToasts |]; viewPatches app restarted ])
            else
                struct (applied, head)
        )

    respondAsync app session events ctx

let filterApply (app: AppState) : EndpointHandler =
    fun ctx ->
        task {
            let struct (session, _) = playSession app ctx
            let! signals = readBodyAsync ctx
            do! commitFilterAsync app session (filterTextFrom signals) ctx
        }
        :> Task

/// Apply replaces whatever is in the filter box with the ticked topics, as panel did.
let topicsApply (app: AppState) : EndpointHandler =
    fun ctx ->
        task {
            let struct (session, _) = playSession app ctx
            let! signals = readBodyAsync ctx
            do! commitFilterAsync app session (topicsTextFrom session.System signals) ctx
        }
        :> Task

// ---------------------------------------------------------------------------------------------
// the debug panel
// ---------------------------------------------------------------------------------------------

/// Every debug route is a no-op unless the session is armed, so an unarmed instance answers with a 204
/// rather than a 404 -- the same "nothing to do" answer a stale qid gets, and it does not advertise
/// whether the routes exist.
let private debugAsync (app: AppState) (change: State -> State) : EndpointHandler =
    fun ctx ->
        let struct (session, _) = playSession app ctx

        let events =
            session
            |> Session.update (fun state ->
                if not state.Debug then
                    struct (state, Array.empty)
                else
                    let next = change state
                    struct (next, viewPatches app next)
            )

        respondAsync app session events ctx

/// Adds or removes points without answering anything.
///
/// Deliberately does NOT check the goal: crossing it by hand should not fake a completion, because then
/// the finale would be reachable without the code path that produces it. `/debug/complete` is the honest
/// way to see that screen.
let debugPoints
    (app: AppState)
    (delta: int)
    : (Microsoft.AspNetCore.Http.HttpContext -> System.Threading.Tasks.Task) =
    debugAsync
        app
        (fun state ->
            { state with Score = { state.Score with TotalPoints = max (state.Score.TotalPoints + delta) 0 } }
        )

/// Shortens (or lengthens) the quiz. Per session, so this is not a global mutation. The milestones that
/// pay for skips are fractions of the goal, so lowering it also brings those forward -- which is the
/// point: a 200-point goal exercises the whole ladder in a minute.
let debugGoal
    (app: AppState)
    (value: int)
    : (Microsoft.AspNetCore.Http.HttpContext -> System.Threading.Tasks.Task) =
    debugAsync app (fun state -> { state with PointsGoal = Math.Clamp(value, 10, 100_000) })

/// Parks on the reveal without getting one wrong, for looking at the shake and the marks.
let debugReveal (app: AppState) : EndpointHandler =
    fun ctx ->
        let struct (session, _) = playSession app ctx

        let events =
            session
            |> Session.update (fun state ->
                if not state.Debug then
                    struct (state, Array.empty)
                else
                    let state =
                        if State.stillPlaying state then
                            state
                        else
                            State.restart state

                    let count = state.Question.Candidates.Length
                    let correct = state.Question.AnswerIndex

                    if count = 0 || correct < 0 then
                        struct (state, Array.empty)
                    else
                        let parked =
                            { state with AwaitingNext = true; WrongIndex = ValueSome((correct + 1) % count) }
                            |> State.freezeQuestionClock

                        struct (parked, viewPatches app parked)
            )

        respondAsync app session events ctx

/// Jumps to the finale, through the real scoring path.
///
/// Points are set one short of the goal and the current question is answered *correctly*, so this goes
/// through the engine -> completed -> the toast chain -> the completion screen, including the gold
/// goal-crossing floater. Faking the completion would show the screen while skipping everything that
/// makes it happen.
let debugComplete (app: AppState) : EndpointHandler =
    fun ctx ->
        let struct (session, replaced) = playSession app ctx

        let armed =
            session
            |> Session.update (fun state ->
                if not state.Debug then
                    struct (state, ValueNone)
                else
                    let state =
                        if State.stillPlaying state then
                            state
                        else
                            State.restart state

                    let ready =
                        { state with
                            Score = { state.Score with TotalPoints = max (state.PointsGoal - 1) 0 }
                            AwaitingNext = false }

                    let correct = ready.Question.AnswerIndex

                    if correct < 0 then
                        struct (ready, ValueNone)
                    else
                        struct (ready, ValueSome(struct (ready.Qid, correct)))
            )

        match armed with
        | ValueNone -> respondAsync app session Array.empty ctx
        | ValueSome(struct (qid, correctIndex)) ->
            scoreAnswerAsync app session replaced qid correctIndex false emptyPayload ctx

// ---------------------------------------------------------------------------------------------
// assets
// ---------------------------------------------------------------------------------------------

/// One synthesised WAV. `max-age` a year: the URL carries the build stamp, so a changed synth is a
/// different URL.
///
/// The only route that needs nothing from `AppState`: the sounds are process-wide and identical for
/// every session.
let sound (name: string) : EndpointHandler =
    fun ctx ->
        match Sfx.tryGet name with
        | ValueNone ->
            ctx.Response.StatusCode <- StatusCodes.Status404NotFound
            Task.CompletedTask
        | ValueSome bytes ->
            ctx.Response.StatusCode <- StatusCodes.Status200OK
            ctx.Response.Headers.ContentType <- "audio/wav"
            ctx.Response.Headers.CacheControl <- "public, max-age=31536000"
            ctx.Response.BodyWriter.WriteAsync(ReadOnlyMemory bytes, ctx.RequestAborted).AsTask()

/// A stylesheet, a script or the completion image, from the pre-compressed table.
///
/// `no-cache` rather than a long max-age: these change with the app and are small, and a stale
/// stylesheet against new markup is the one caching failure a player cannot work around. It means
/// revalidate, not "do not store".
let asset (app: AppState) (folder: string) (path: string) : EndpointHandler =
    fun ctx ->
        match app.Assets.TryGetValue(folder + "/" + path) with
        | false, _ ->
            ctx.Response.StatusCode <- StatusCodes.Status404NotFound
            Task.CompletedTask
        | true, found ->
            let wantsBrotli =
                Sse.negotiate (string ctx.Request.Headers.AcceptEncoding) = Sse.Brotli

            let bytes =
                if wantsBrotli && found.Brotli.Length > 0 then
                    ctx.Response.Headers.ContentEncoding <- "br"
                    ctx.Response.Headers.Vary <- "Accept-Encoding"
                    found.Brotli
                else
                    found.Identity

            ctx.Response.StatusCode <- StatusCodes.Status200OK
            ctx.Response.Headers.ContentType <- found.ContentType
            ctx.Response.Headers.CacheControl <- "no-cache"
            ctx.Response.BodyWriter.WriteAsync(ReadOnlyMemory bytes, ctx.RequestAborted).AsTask()
