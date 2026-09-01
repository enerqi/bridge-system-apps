/// The quiz rules: question generation, scoring, the time bonus, milestone skip awards, completion.
///
/// No HTTP, no HTML, no signals -- this is the state machine the routes drive, ported from
/// `apps/datastar-quiz/engine.py` (itself a port of the panel app's `points` / `on_answer_click` /
/// `reset_time_bonus_by_difficulty`) by way of the Go port's `internal/engine/engine.go`. Keeping it
/// separate is what lets it be benchmarked with no server in the way.
///
/// Scoring applies the whole state change at once and *returns* the instalments as toasts: the SSE
/// handler replays them with the same delays, but a mid-stream reload sees final state rather than a
/// half-scored session.
module DsQuiz.Engine

open System

open DsQuiz.Corpus

[<Literal>]
let InitialDifficulty = 5

[<Literal>]
let MinDifficulty = 4

[<Literal>]
let MaxDifficulty = 8

[<Literal>]
let PointsGoal = 1000

[<Literal>]
let InitialSkips = 3

/// The fractions of the goal that each pay for one skip.
let scoreMilestones =
    [| 0.1
       0.25
       0.45
       0.65
       0.8
       1.0 |]

/// The seconds allowed per question, by difficulty (the panel's `reset_time_bonus_by_difficulty`).
let private secondsPerLevel (difficulty: int) : int =
    match difficulty with
    | 4 -> 8
    | 5 -> 7
    | 6 -> 6
    | 7 -> 5
    | 8 -> 4
    | _ -> 4

/// The allowance for one question.
let secondsForDifficulty (difficulty: int) : float =
    float (difficulty * secondsPerLevel difficulty)

/// python's `round()` on a float: half to EVEN, not half away from zero.
///
/// Used everywhere the python rounds, because the two disagree at every .5 -- and the percentages
/// here land on one often enough for it to show (a 50% time bonus on an even candidate count, the
/// gauge at exactly 12.5%). .NET's `Math.Round` is already half-to-even by default, but the call is
/// spelled out so nobody "fixes" it to `MidpointRounding.AwayFromZero`.
let pyRound (value: float) : int =
    int (Math.Round(value, MidpointRounding.ToEven))

/// The time bonus percentage, as the panel's `TimeBonus` progress bar computed it.
let percentTimeLeft (elapsed: float) (allowed: float) : int =
    if allowed <= 0.0 then
        0
    else
        pyRound (Math.Max(allowed - elapsed, 0.0) / allowed * 100.0)

/// Turns a difficulty the browser sent into one the quiz can use.
///
/// The argument is already-coerced: `Web.Signals` applies the python `int()` semantics (a number
/// truncates toward zero, a string is parsed, anything unreadable is absent) because that is where
/// the JSON shapes are known. What is left here is the rule that matters to the rules -- an absent or
/// unusable value is the DEFAULT, not the nearest legal value, and anything else is clamped into
/// range.
let clampDifficulty (difficulty: int voption) : int =
    match difficulty with
    | ValueNone -> InitialDifficulty
    | ValueSome value -> max MinDifficulty (min MaxDifficulty value)

// ---------------------------------------------------------------------------------------------
// questions
// ---------------------------------------------------------------------------------------------

/// Which way round a question is asked.
[<StructuralEquality; NoComparison>]
type ChoiceType =
    /// several auctions, one description -- pick the auction it describes
    | Auctions
    /// one auction, several descriptions -- pick the one that fits
    | Descriptions

let choiceTypeText (choiceType: ChoiceType) : string =
    match choiceType with
    | Auctions -> "Auctions"
    | Descriptions -> "Descriptions"

/// One question as the browser will see it.
[<NoEquality; NoComparison>]
type Question =
    { Candidates: string array
      Answer: string
      AnswerCandidate: string
      ChoiceType: ChoiceType }

    /// Where the right answer sits among the candidates, or -1.
    member this.AnswerIndex = System.Array.IndexOf(this.Candidates, this.AnswerCandidate)

let emptyQuestion =
    { Candidates = Array.empty
      Answer = ""
      AnswerCandidate = ""
      ChoiceType = Auctions }

/// `quiz.prettify_description`: trim, and spell the suit shorthand out. The remaining `!x`-to-glyph
/// work is presentation and happens in the renderer.
let prettifyDescription (text: string) : string =
    let trimmed = text.Trim()

    if trimmed.IndexOf '!' < 0 then
        trimmed
    else
        trimmed.Replace("!c", "C").Replace("!d", "D").Replace("!h", "H").Replace("!s", "S")

/// How the parts of one auction are joined for display -- the same ` --> ` the panel app used, which
/// the renderer then turns into a glyph.
[<Literal>]
let AuctionSeparator = " --> "

/// Bounds the "keep drawing until the descriptions are distinct" loop.
///
/// The python spins forever if a working set holds fewer distinct non-blank descriptions than the
/// question needs candidates, and it cannot happen in practice: a filter that selects fewer than
/// `MaxDifficulty` auctions is rejected as `too_few` and the whole system is used instead. A request
/// that never returns is a worse failure than a repeated candidate, so the loop gives up rather than
/// hanging -- on any corpus where the python terminates, this bound is never reached.
[<Literal>]
let private MaxDraws = 10000

/// Draws one question from a working set, with the choice type named. `quiz.generate_question`.
///
/// `working` is the INDICES the filter selected, into `auctions` -- the shape `Corpus.FilterCheck`
/// hands back, so no auction is copied to ask a question.
let newQuestionOfType
    (auctions: Auction array)
    (working: int array)
    (difficulty: int)
    (choiceType: ChoiceType)
    : Question =
    if working.Length = 0 then
        { emptyQuestion with ChoiceType = choiceType }
    else
        let answerAt = Random.Shared.Next difficulty
        let seen = Collections.Generic.HashSet<string>(difficulty, StringComparer.Ordinal)
        let candidates = ResizeArray<string> difficulty
        let mutable answer = ""
        let mutable answerCandidate = ""
        let mutable exhausted = false

        let mutable i = 0

        while not exhausted && i < difficulty do
            let mutable description = ""
            let mutable auction = ""
            let mutable draw = 0

            while description = "" && draw < MaxDraws do
                let picked = auctions[working[Random.Shared.Next working.Length]]
                let candidate = prettifyDescription picked.Description

                // some auction sequences, some preludes do not have descriptions
                if candidate <> "" && not (seen.Contains candidate) then
                    description <- candidate
                    auction <- String.Join(AuctionSeparator, picked.Sequence)

                draw <- draw + 1

            if description = "" then
                exhausted <- true
            else
                seen.Add description |> ignore

                let shown, hidden =
                    match choiceType with
                    | Auctions -> auction, description
                    | Descriptions -> description, auction

                if i = answerAt then
                    answer <- hidden
                    answerCandidate <- shown

                candidates.Add shown
                i <- i + 1

        { Candidates = candidates.ToArray()
          Answer = answer
          AnswerCandidate = answerCandidate
          ChoiceType = choiceType }

/// Draws one question, with the choice type picked at random as `random_multi_choice_type` does.
let newQuestion (auctions: Auction array) (working: int array) (difficulty: int) : Question =
    let choiceType = if Random.Shared.Next 2 = 0 then Descriptions else Auctions

    newQuestionOfType auctions working difficulty choiceType

// ---------------------------------------------------------------------------------------------
// scoring
// ---------------------------------------------------------------------------------------------

/// One answer's score, broken into the instalments the toasts reveal.
[<Struct; StructuralEquality; NoComparison>]
type Points =
    { FromCandidateLengths: int
      FromStreakBonus: int
      FromTimeBonus: int }

    member this.Total =
        this.FromCandidateLengths + this.FromStreakBonus + this.FromTimeBonus

let private whitespace = [| ' '; '\t'; '\n'; '\r' |]

/// The verbatim port of `quiz_app.points` -- longer auctions are worth more, with a streak
/// multiplier and a time multiplier on top.
let scorePoints (question: Question) (streak: int) (percentLeft: int) : Points =
    let mutable fromCandidateLengths = 0

    for candidate in question.Candidates do
        fromCandidateLengths <-
            fromCandidateLengths
            + candidate.Replace("-->", "").Split(whitespace, StringSplitOptions.RemoveEmptyEntries).Length

    let streakBonus =
        if streak > 1 then
            let percentBonus = Math.Min(float streak * 10.0 / 100.0, 1.0)
            pyRound (float fromCandidateLengths * percentBonus)
        else
            0

    let timeBonus =
        if percentLeft > 0 then
            pyRound (float fromCandidateLengths * (float percentLeft / 100.0))
        else
            0

    { FromCandidateLengths = fromCandidateLengths; FromStreakBonus = streakBonus; FromTimeBonus = timeBonus }

/// What a toast's colour language says. Matches the panel notification methods so the CSS can keep
/// the same names.
[<StructuralEquality; NoComparison>]
type ToastKind =
    | ToastSuccess
    | ToastInfo
    | ToastWarning

let toastKindText (kind: ToastKind) : string =
    match kind with
    | ToastSuccess -> "success"
    | ToastInfo -> "info"
    | ToastWarning -> "warning"

/// One notification, and how long the stream should pause after showing it.
[<NoEquality; NoComparison>]
type Toast =
    {
        Kind: ToastKind
        Text: string
        /// seconds
        Pause: float
        /// The running points total *as at this toast*. The state change is applied in one go, but the
        /// panel app revealed the points in instalments (candidate length, then streak bonus, then time
        /// bonus), so each toast carries the number to show alongside it.
        PointsAfter: int voption
        /// This beat is a milestone paying for a skip. A flag rather than a text match in the renderer:
        /// the words are presentation and have been reworded once already, and "+1 SKIP!" appearing in
        /// the stream handler would make an unrelated copy edit silently drop the gauge sweep and the
        /// sound that go with it.
        AwardsSkip: bool
    }

let private toast kind text pause : Toast =
    { Kind = kind
      Text = text
      Pause = pause
      PointsAfter = ValueNone
      AwardsSkip = false }

/// The outcome of scoring one answer.
[<NoEquality; NoComparison>]
type Answered =
    { Correct: bool
      Toasts: Toast array
      Completed: bool
      AwardedSkips: int }

/// The part of a session the score panel renders.
///
/// IMMUTABLE, and `answer` below returns the next one. The panel app and both earlier ports mutate a
/// ledger through a pointer; a record and a returned value say the same thing without the question of
/// who else is holding it, and the copy is four ints and a six-element array.
[<NoEquality; NoComparison>]
type Score =
    {
        QuestionsCorrect: int
        QuestionsAttempted: int
        Streak: int
        TotalPoints: int
        /// The milestones not yet collected, highest first -- taken from the back as the points pass
        /// them, exactly as the python's reversed list is.
        AvailableMilestones: float array
    }

[<CompilationRepresentation(CompilationRepresentationFlags.ModuleSuffix)>]
[<RequireQualifiedAccess>]
module Score =

    /// A fresh ledger. Also what a restart resets to, which is why it is a value and not a function.
    let start =
        { QuestionsCorrect = 0
          QuestionsAttempted = 0
          Streak = 0
          TotalPoints = 0
          AvailableMilestones = Array.rev scoreMilestones }

    /// The proportion of attempts that were right.
    let percentage (score: Score) : int =
        if score.QuestionsAttempted > 0 then
            pyRound (float score.QuestionsCorrect / float score.QuestionsAttempted * 100.0)
        else
            0

/// Everything scoring one answer needs beyond the ledger.
[<NoEquality; NoComparison>]
type AnswerInput =
    {
        Question: Question
        Candidate: string
        PercentLeft: int
        LadderMode: bool
        TargetOn: bool
        TargetPct: int
        LastCorrectPoints: int
        /// A parameter rather than the module constant so the debug panel can shorten a quiz without a
        /// global mutation -- the goal decides both completion and where the skip milestones fall, and
        /// two sessions in one process may disagree.
        PointsGoal: int
    }

/// What scoring one answer produced: the outcome, the ledger it leaves behind, and the new "last
/// correct points" -- what the NEXT wrong answer costs in ladder mode.
[<NoEquality; NoComparison>]
type Scored = { Outcome: Answered; Score: Score; LastCorrectPoints: int }

/// Scores one answer.
///
/// A wrong answer's toasts are deliberately brief: the answer itself is revealed in place in the
/// question card, not spelled out in a notification the player must wait behind.
let answer (score: Score) (input: AnswerInput) : Scored =
    let correct = input.Candidate = input.Question.AnswerCandidate
    let toasts = ResizeArray<Toast> 8

    if not correct then
        let scoreWasNonZero = score.TotalPoints > 0

        let after =
            { score with
                Streak = 0
                QuestionsAttempted = score.QuestionsAttempted + 1
                TotalPoints =
                    if input.LadderMode then
                        max (score.TotalPoints - input.LastCorrectPoints) 0
                    else
                        score.TotalPoints }

        toasts.Add(toast ToastWarning "Not quite" 0.6)

        if input.LadderMode && input.LastCorrectPoints > 0 && scoreWasNonZero then
            toasts.Add
                { toast ToastWarning $"Ladder mode: -%d{input.LastCorrectPoints} points" 0.6 with
                    PointsAfter = ValueSome after.TotalPoints }

        { Outcome =
            { Correct = false
              Toasts = toasts.ToArray()
              Completed = false
              AwardedSkips = 0 }
          Score = after
          LastCorrectPoints = input.LastCorrectPoints }
    else

        let streak = score.Streak + 1
        let increase = scorePoints input.Question streak input.PercentLeft

        toasts.Add(toast ToastSuccess "Correct!" 0.5)
        let mutable running = score.TotalPoints + increase.FromCandidateLengths

        toasts.Add
            { toast ToastInfo $"+%d{increase.FromCandidateLengths}!" 0.5 with
                PointsAfter = ValueSome running }

        if increase.FromStreakBonus > 0 then
            running <- running + increase.FromStreakBonus

            toasts.Add
                { toast ToastInfo $"Streak %d{streak}, Bonus +%d{increase.FromStreakBonus}" 0.5 with
                    PointsAfter = ValueSome running }

        if increase.FromTimeBonus > 0 then
            running <- running + increase.FromTimeBonus

            toasts.Add
                { toast ToastInfo $"Time Bonus +%d{increase.FromTimeBonus}" 0.5 with
                    PointsAfter = ValueSome running }

        // How many milestones the new total has passed. They are held highest-first, so the ones that pay
        // out sit at the END of the array and what is left is a prefix of it -- no shuffling, one slice.
        let outstanding = score.AvailableMilestones
        let mutable awardedSkips = 0

        let mutable passing = true

        while passing && awardedSkips < outstanding.Length do
            let next = outstanding[outstanding.Length - 1 - awardedSkips]

            if next * float input.PointsGoal <= float running then
                awardedSkips <- awardedSkips + 1
            else
                passing <- false

        for _ in 1..awardedSkips do
            toasts.Add { toast ToastSuccess "+1 SKIP!" 0.5 with AwardsSkip = true }

        let after =
            { QuestionsCorrect = score.QuestionsCorrect + 1
              QuestionsAttempted = score.QuestionsAttempted + 1
              Streak = streak
              TotalPoints = running
              AvailableMilestones = Array.sub outstanding 0 (outstanding.Length - awardedSkips) }

        let mutable completed = false

        if running >= input.PointsGoal then
            let percentage = Score.percentage after

            if not input.TargetOn || percentage >= input.TargetPct then
                completed <- true
            else
                toasts.Add(
                    toast
                        ToastWarning
                        $"Current score %d{percentage}%%, target score %d{input.TargetPct}%%"
                        0.5
                )

        // the panel handler paused a further second before moving on when the answer was right
        toasts.Add(toast ToastInfo "" 1.0)

        { Outcome =
            { Correct = true
              Toasts = toasts.ToArray()
              Completed = completed
              AwardedSkips = awardedSkips }
          Score = after
          LastCorrectPoints = increase.Total }
