/// Server-side session state -- the authoritative quiz.
///
/// Datastar's doctrine: "Most state should live in the backend. Since the frontend is exposed to the
/// user, the backend should be the source of truth." Everything here is state the browser must not
/// own: the current question (it carries the answer), the score and milestone ledger, and the working
/// set of auctions.
///
/// THE STATE IS AN IMMUTABLE RECORD AND EVERY TRANSITION IS A FUNCTION RETURNING THE NEXT ONE. The
/// python is one asyncio loop, so a handler there runs to its next `await` with no other handler
/// inside the same session; the Go and Rust ports mutate a struct behind a mutex. Here the only
/// mutable cell in the app is the one field a `Session` holds, swapped under its lock -- which means
/// the interesting half (what a click does to a quiz) is pure and testable without a session at all.
///
/// The working set is a SHARED `int array`: an unfiltered session shares the system's "everything"
/// list, a filtered one shares the memo's answer. Neither copies an auction, and two browsers that
/// apply the same filter hold the same allocation. Where Rust needs `Arc<[u32]>` to say that, a
/// managed runtime says it by handing over the reference.
module DsQuiz.Session

open System
open System.Collections.Concurrent
open System.Collections.Generic
open System.Diagnostics
open System.Security.Cryptography
open System.Threading

open DsQuiz.Corpus
open DsQuiz.Engine

/// The cookie identifies the BROWSER, not the quiz: sessions live under (browser, variant), so the
/// squad quiz and the swedish one coexist instead of one replacing the other. Deliberately still one
/// cookie under one name -- nginx pins a browser to a worker with `hash $cookie_dsq_sid consistent`,
/// and a name that varied by variant would leave that directive hashing on a cookie half the requests
/// do not carry.
[<Literal>]
let Cookie = "dsq_sid"

let Ttl = TimeSpan.FromHours 6.0
let SweepPeriod = TimeSpan.FromMinutes 10.0

/// THE QUESTION NONCE IS PROCESS-WIDE, and that is the whole point of it.
///
/// Per session, starting at 1, a page whose session had been REPLACED -- `?swedish` used to discard the
/// old session, a restart empties the store, a session ages out after six hours -- posted qid=1 at a
/// brand new session whose first question was *also* qid=1. The staleness guard then passed by
/// coincidence and the answer was scored against a question that had never been on screen. That is the
/// "I answered one question and it showed me another" report, and it is not a race: it is two counters
/// that both start at 1.
let mutable private qids = 0L

/// The next question nonce. Unique per process, not per session.
let nextQid () : int64 = Interlocked.Increment &qids

/// The bound signals, as last seen from the browser. Mirrors of client-originated state: the browser is
/// the source of truth for these, and every request re-states them.
// Equality IS used: the `/settings` route compares what the browser sent with what it adopted and
// answers 204 when nothing moved.
[<Struct; StructuralEquality; NoComparison>]
type Settings =
    { Difficulty: int
      LadderMode: bool
      TargetOn: bool
      TargetPct: int }

[<CompilationRepresentation(CompilationRepresentationFlags.ModuleSuffix)>]
[<RequireQualifiedAccess>]
module Settings =

    let start =
        { Difficulty = InitialDifficulty
          LadderMode = true
          TargetOn = false
          TargetPct = 70 }

/// One quiz, at one moment.
[<NoEquality; NoComparison>]
type State =
    {
        System: Corpus.System
        Settings: Settings
        Score: Score
        /// indices into `System.Auctions`: the whole system, or a filter's hits, shared either way
        WorkingSet: int array
        Question: Question
        /// from `nextQid`; the answer route rejects a stale one. Never per-session.
        Qid: int64
        SkipsLeft: int
        LastCorrectPoints: int
        FilterText: string
        QuizStart: DateTime
        Completion: DateTime voption
        /// A monotonic timestamp, not a wall clock: `Stopwatch.GetElapsedTime` off this is immune to the
        /// clock being adjusted mid-question, which a `DateTime` subtraction is not.
        QuestionStartedAt: int64
        QuestionSeconds: float
        /// Set when a wrong answer has been scored: the question stays on screen with the right answer
        /// marked, and nothing moves on until the player asks. Panel instead blocked for 4.2s behind a
        /// centre-screen toast.
        AwaitingNext: bool
        WrongIndex: int voption
        /// Per-session so the debug panel can shorten a quiz without mutating a constant.
        PointsGoal: int
        /// Set when the session was opened with `?debug` (or `DSQUIZ_DEBUG=1`). Sticky, like the variant,
        /// because the query is gone after the first navigation.
        Debug: bool
        /// What was left on the clock when the question was answered. The allowance stops mattering the
        /// moment an answer is scored, so it is frozen rather than left running: otherwise a reload while
        /// parked on the reveal reports a smaller number than the one the answer was scored with.
        FrozenTimeLeft: int voption
    }

[<CompilationRepresentation(CompilationRepresentationFlags.ModuleSuffix)>]
[<RequireQualifiedAccess>]
module State =

    let stillPlaying (state: State) : bool = state.Completion.IsNone

    /// Whether a live, unanswered question is being timed.
    ///
    /// False while parked on a reveal and after completion -- the two states where the countdown must
    /// stop rather than keep draining.
    let onTheClock (state: State) : bool =
        stillPlaying state && not state.AwaitingNext

    /// How long the quiz took, to one decimal (the completion screen's number).
    let elapsedSeconds (state: State) : float =
        let ended =
            match state.Completion with
            | ValueSome at -> at
            | ValueNone -> DateTime.UtcNow

        Math.Round(Math.Max((ended - state.QuizStart).TotalSeconds, 0.0) * 10.0) / 10.0

    /// What is left of this question's allowance.
    let percentTimeLeft (state: State) : int =
        match state.FrozenTimeLeft with
        | ValueSome frozen -> frozen
        | ValueNone ->
            let elapsed = Stopwatch.GetElapsedTime(state.QuestionStartedAt).TotalSeconds
            Engine.percentTimeLeft elapsed state.QuestionSeconds

    /// (Re)starts the allowance for the current question.
    ///
    /// Called again when the question actually reaches the browser: the answer stream spends up to
    /// several seconds showing notifications after the next question has been drawn, and charging the
    /// player for that time would cost them a chunk of their bonus.
    let startQuestionClock (state: State) : State =
        { state with QuestionStartedAt = Stopwatch.GetTimestamp(); FrozenTimeLeft = ValueNone }

    /// Stops the countdown where it stands, because this question has been answered.
    let freezeQuestionClock (state: State) : State =
        { state with FrozenTimeLeft = ValueSome(percentTimeLeft state) }

    /// Draws a new question and restarts its clock. The qid changes, which is what makes the previous
    /// question's answer buttons dead -- a double click cannot score twice.
    let nextQuestion (state: State) : State =
        startQuestionClock
            { state with
                AwaitingNext = false
                WrongIndex = ValueNone
                Question = newQuestion state.System.Auctions state.WorkingSet state.Settings.Difficulty
                Qid = nextQid ()
                QuestionSeconds = secondsForDifficulty state.Settings.Difficulty }

    /// Commits a bidding-tree filter, narrowing the working set. Returns the next state, what the
    /// filter selected, and whether it changed anything.
    ///
    /// Anything other than a usable filter falls back to the whole system, and the stored text is the
    /// *canonical* form (topic prefixes resolved, whitespace tidied) so the input box can show what is
    /// really in force.
    let applyFilter
        (text: string)
        (minHits: int)
        (state: State)
        : struct (State * Corpus.FilterCheck * bool) =
        let check = System.checkFilter text minHits state.System

        let next =
            { state with
                WorkingSet = (if usable check then check.Hits else state.System.AllIndices)
                FilterText = check.Parsed.CanonicalText }

        struct (next, check, check.Parsed.CanonicalText <> state.FilterText)

    /// The port of the panel's `reset_skips_and_scoring_and_timer_and_question`. Every settings or
    /// filter change goes through here, as in the panel app.
    let restart (state: State) : State =
        nextQuestion
            { state with
                Score = Score.start
                SkipsLeft = InitialSkips
                LastCorrectPoints = 0
                QuizStart = DateTime.UtcNow
                Completion = ValueNone }

    let complete (state: State) : State =
        { state with Completion = ValueSome DateTime.UtcNow }

    /// A fresh quiz on a system: the whole corpus as the working set, and a first question drawn from
    /// it. The qid comes from the process-wide counter, so this session's first question cannot share a
    /// nonce with the first question of the session it replaced -- see `nextQid`.
    let create (system: Corpus.System) : State =
        let settings = Settings.start

        { System = system
          Settings = settings
          Score = Score.start
          WorkingSet = system.AllIndices
          Question = newQuestion system.Auctions system.AllIndices settings.Difficulty
          Qid = nextQid ()
          SkipsLeft = InitialSkips
          LastCorrectPoints = 0
          FilterText = ""
          QuizStart = DateTime.UtcNow
          Completion = ValueNone
          QuestionStartedAt = Stopwatch.GetTimestamp()
          QuestionSeconds = secondsForDifficulty settings.Difficulty
          AwaitingNext = false
          WrongIndex = ValueNone
          PointsGoal = PointsGoal
          Debug = false
          FrozenTimeLeft = ValueNone }

/// One quiz in progress: the state, and the lock that serialises the requests changing it.
///
/// Two tabs, a click arriving during an answer stream and the held timer connection can all be inside
/// one session at once, so `update` reads-modifies-writes under the lock and hands back what the
/// caller needs. Handlers do their state work in one synchronous step and stream afterwards, which is
/// also what keeps a paced answer stream from holding a lock for six seconds.
[<NoEquality; NoComparison>]
type Session =
    {
        Sid: string
        /// The variant this session is playing. Fixed for its life, and outside the lock on purpose: a
        /// handler needs it to resolve topics and the filter before it has any reason to take the lock.
        System: Corpus.System
        Gate: obj
        mutable State: State
        /// When this session was last used, for the sweeper. A monotonic timestamp, written without the
        /// lock on purpose: one that is a request stale cannot evict a live session, and the sweeper must
        /// not queue behind a paced answer stream to find out.
        mutable TouchedAt: int64
    }

[<CompilationRepresentation(CompilationRepresentationFlags.ModuleSuffix)>]
[<RequireQualifiedAccess>]
module Session =

    let create (sid: string) (system: Corpus.System) : Session =
        { Sid = sid
          System = system
          Gate = obj ()
          State = State.create system
          TouchedAt = Stopwatch.GetTimestamp() }

    /// Reads the state under the lock. For handlers that only render.
    let read (session: Session) : State =
        lock session.Gate (fun () -> session.State)

    /// Applies a transition under the lock and returns what the caller asked for alongside the state it
    /// leaves behind.
    let update (work: State -> struct (State * 'a)) (session: Session) =
        lock
            session.Gate
            (fun () ->
                let struct (next, answer) = work session.State
                session.State <- next
                answer
            )

    /// `update` for a transition with nothing to report.
    let change (work: State -> State) (session: Session) =
        update (fun state -> struct (work state, ())) session

    let touch (session: Session) : unit =
        session.TouchedAt <- Stopwatch.GetTimestamp()

/// The (browser, variant) key. A struct so a lookup allocates nothing, and `NoComparison` because F#
/// would otherwise generate the `IComparable` machinery this is never sorted by.
[<Struct; NoComparison>]
type SessionKey = { Sid: string; VariantKey: string }

/// The process-local session registry with TTL eviction, keyed by (browser, variant).
///
/// ONE QUIZ PER VARIANT PER BROWSER, which is what panel had for free by keying its sessions on the
/// variant. The single-session version replaced the whole quiz whenever `?swedish` was opened, and with
/// one cookie per browser that reached across tabs: the squad tab, the back-history entry and the
/// phone's other tab were all left holding a quiz that no longer existed, mid-score.
///
/// `Current` remembers which variant a browser last *navigated* to, for the one request that cannot
/// say: a page load with a query that names no variant (`?debug`).
[<NoEquality; NoComparison>]
type Store =
    { Sessions: ConcurrentDictionary<SessionKey, Session>
      Current: ConcurrentDictionary<string, string>
      Ttl: TimeSpan }

/// A random browser id: 128 bits, hex-encoded -- the same shape as the Go port's `crypto/rand` value
/// and the python's `uuid4().hex`.
let newSid () : string =
    Convert.ToHexStringLower(RandomNumberGenerator.GetBytes 16)

[<CompilationRepresentation(CompilationRepresentationFlags.ModuleSuffix)>]
[<RequireQualifiedAccess>]
module Store =

    /// A `ConcurrentDictionary` rather than a map behind a reader-writer lock: reads are lock-free and
    /// this is read on every request, written once per session.
    let create (ttl: TimeSpan) : Store =
        { Sessions = ConcurrentDictionary<SessionKey, Session>()
          Current = ConcurrentDictionary<string, string>(StringComparer.Ordinal)
          Ttl = ttl }

    let start () : Store = create Ttl

    let count (store: Store) : int = store.Sessions.Count

    /// The variant this browser last navigated to, if the store still has it.
    let currentVariant (sid: string) (store: Store) : string voption =
        if String.IsNullOrEmpty sid then
            ValueNone
        else
            match store.Current.TryGetValue sid with
            | true, remembered -> ValueSome remembered
            | _ -> ValueNone

    /// This browser's session for `variantKey`, or for whatever it is currently on when the key is
    /// empty.
    let tryGet (sid: string) (variantKey: string) (store: Store) : Session voption =
        let key =
            if String.IsNullOrEmpty sid then
                ValueNone
            elif variantKey <> "" then
                ValueSome { Sid = sid; VariantKey = variantKey }
            else
                // the only path that has to name the variant from elsewhere
                match currentVariant sid store with
                | ValueSome remembered -> ValueSome { Sid = sid; VariantKey = remembered }
                | ValueNone -> ValueNone

        match key with
        | ValueNone -> ValueNone
        | ValueSome key ->
            match store.Sessions.TryGetValue key with
            | true, session ->
                Session.touch session
                ValueSome session
            | _ -> ValueNone

    /// Builds a quiz for a system under the given browser id (a new browser if there is none).
    let create' (system: Corpus.System) (sid: string voption) (store: Store) : Session =
        let sid =
            match sid with
            | ValueSome existing when existing <> "" -> existing
            | _ -> newSid ()

        let created = Session.create sid system

        store.Sessions[{ Sid = sid; VariantKey = system.Variant.Key }] <- created

        // Only if absent, not an assignment: a browser with NO mark has to get one from somewhere, and
        // the quiz it just had built is the only candidate. A browser that already has one keeps it --
        // moving the mark is a navigation's job, so a rebuild triggered by a background tab's click
        // cannot decide what the next `?debug` page load resumes.
        store.Current.TryAdd(sid, system.Variant.Key) |> ignore
        created

    /// Records which variant this browser last navigated to. Only page loads call this.
    let remember (sid: string) (variantKey: string) (store: Store) : unit =
        if not (String.IsNullOrEmpty sid) then
            store.Current[sid] <- variantKey

    /// Drops sessions untouched for longer than the TTL, and any `Current` mark left pointing at
    /// nothing. Returns how many went.
    let sweep (store: Store) : int =
        let mutable dropped = 0

        for entry in store.Sessions do
            if Stopwatch.GetElapsedTime entry.Value.TouchedAt > store.Ttl then
                if store.Sessions.TryRemove(entry.Key, ref Unchecked.defaultof<Session>) then
                    dropped <- dropped + 1

        let live = HashSet<string>(StringComparer.Ordinal)

        for key in store.Sessions.Keys do
            live.Add key.Sid |> ignore

        for sid in store.Current.Keys do
            if not (live.Contains sid) then
                store.Current.TryRemove(sid, ref Unchecked.defaultof<string>) |> ignore

        dropped
