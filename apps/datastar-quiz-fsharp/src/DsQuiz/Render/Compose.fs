/// Turning a session into a page: the three bodies the routes send, and the data they share.
///
/// `quizBody` decides WHICH of the three `#quiz` faces is showing (question, reveal, finale);
/// `appBody` is the fat-morph unit; `shell` is the whole document. All three go through `pageData`, so
/// the document and the patch cannot disagree about the state they render.
///
/// THE OPENS HERE ARE DELIBERATELY SHORT. `Corpus.System` is a module in this codebase and `System` is
/// the BCL's root namespace, so `open DsQuiz.Corpus` would shadow it and `System.Char` would stop
/// resolving. Everything below is qualified instead, which is also how a reader can tell which `System`
/// is meant.
module DsQuiz.Render.Compose

open System

open DsQuiz
open DsQuiz.Engine
open DsQuiz.Render.Page
open DsQuiz.Session

/// Everything both the document and the fat-morph fragment need, plus the filter check they were built
/// from -- the caller needs it for the status line and the topic ticks, and computing it twice would be
/// the app's most expensive routine run twice.
let pageData
    (config: Config)
    (state: State)
    : struct (DsQuiz.Render.Page.PageData * DsQuiz.Corpus.FilterCheck) =
    let system = state.System
    let check = Corpus.System.checkFilter state.FilterText MaxDifficulty system
    let choices = Names.topicChoices system

    let page =
        { VariantTitle = system.Variant.Title
          SystemNotesURL = system.Variant.SystemNotesURL
          Settings = state.Settings
          Playing = State.stillPlaying state
          // filled in by the callers below, which know whether they want the whole page or just this
          QuizBody = ""
          MinDifficulty = MinDifficulty
          MaxDifficulty = MaxDifficulty
          MilestoneTicks = milestoneTicks
          PointsGoal = state.PointsGoal
          Debug = state.Debug
          Qid = state.Qid
          StreamTimer = config.StreamTimer
          BuildStamp = buildStamp
          CssHref = stylesheetHref Signals.DefaultCSS config.Prefix
          CookiePath = (if config.Prefix = "" then "/" else config.Prefix)
          Topics = choices
          TopicsHaveDescriptions = choices |> Array.exists (fun choice -> choice.Description <> "")
          FilterText = state.FilterText
          FilterStatus = filterStatusFragment check state.FilterText ""
          Prefix = config.Prefix
          VariantQuery = variantQuery system.Variant }

    struct (page, check)

/// The `#quiz` fragment: prompt, the thing to match and the candidate buttons -- or the revealed answer
/// after a wrong one, or the completion screen once the points goal is met.
let quizBody (config: Config) (state: State) : string =
    let struct (page, _) = pageData config state

    if not (State.stillPlaying state) then
        Views.toHtml (
            Views.completed
                page
                // rounded to whole seconds: the finale renders this at 2.4rem, one span per character,
                // and "137" assembles better than "137.4"
                (string (pyRound (State.elapsedSeconds state)))
                state.Score.TotalPoints
                state.Score.QuestionsCorrect
                state.Score.QuestionsAttempted
                (Score.percentage state.Score)
                state.PointsGoal
        )
    else
        let asked = state.Question

        // the first letter is raised: the description is corpus prose and reads as a sentence here
        let answer =
            let text = Auction.emojiTextAuction asked.Answer

            if text = "" then
                text
            else
                string (Char.ToUpperInvariant text[0]) + text.Substring 1

        let candidates =
            asked.Candidates
            |> Array.map (fun candidate -> Escape.suits (Auction.emojiTextAuction candidate))

        let intro = introFor asked.ChoiceType
        let coloured = Escape.suits answer

        if state.AwaitingNext then
            let wrongIndex =
                match state.WrongIndex with
                | ValueSome index -> index
                | ValueNone -> -1

            Views.toHtml (Views.reveal page intro coloured candidates asked.AnswerIndex wrongIndex)
        else
            Views.toHtml (Views.question page intro coloured candidates)

/// The whole page below `<body>`: the fat-morph unit.
///
/// Sending this rather than a hand-picked fragment is what the Tao of Datastar asks for, and it removes
/// a class of bug -- the server no longer has to remember which fragments a state change touches.
let appBody (config: Config) (state: State) : string =
    let struct (page, _) = pageData config state
    Views.renderApp { page with QuizBody = quizBody config state }

/// The whole document: server-rendered current state, no client-side bootstrap, so view-source is the
/// state of the quiz and a reload resumes it exactly.
///
/// `theme` comes from the cookie the toggle wrote. It is rendered STATICALLY onto `<html>` as well as
/// declared as a signal: the attribute is what makes the first paint right, and the signal is what
/// keeps it right when the toggle is clicked.
let shell (config: Config) (state: State) (theme: string) : string =
    let struct (page, check) = pageData config state

    let initial = Signals.initialSignals state page.Topics check.Parsed.TopicNames theme

    Views.renderShell { page with QuizBody = quizBody config state } initial theme
