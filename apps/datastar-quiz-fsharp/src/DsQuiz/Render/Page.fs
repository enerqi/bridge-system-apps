/// What the views need and do not own, plus the SMALL FRAGMENTS.
///
/// The fragments -- a toast, a floating number, a sound beat, the gauge sweep, the filter status --
/// are built as strings rather than through the view engine, and that is deliberate: they are the
/// things that go out over SSE, several per answer, and they are the payloads the other ports' output
/// is diffed against. A `StringBuilder` and the shared escaper keep them byte-identical; the DSL is
/// for the page.
module DsQuiz.Render.Page

open System
open System.Reflection
open System.Text

open DsQuiz
open DsQuiz.Corpus
open DsQuiz.Engine
open DsQuiz.Render

/// A keystroke aimed at a control that has a use for it belongs to that control.
///
/// NOT "any form control": a focused difficulty slider (which keeps focus on purpose, or you could
/// not arrow it) then killed the 1-9 accelerators for the rest of the session.
[<Literal>]
let TypingTargets =
    "input:not([type=range]):not([type=checkbox]):not([type=radio]), select, textarea, [contenteditable]"

/// The same, for Enter and Space: those two ACTIVATE a focused checkbox or radio, so those keep their
/// claim on the key even though they have none on a digit.
[<Literal>]
let ActivationTargets =
    "input:not([type=range]), select, textarea, [contenteditable]"

/// Below this width the sidebar is an overlay drawer rather than a column, which is what makes an
/// outside click mean "close me".
[<Literal>]
let DrawerOverlayQuery = "(max-width: 900px)"

/// The theme cookie: `auto` | `light` | `dark`, written by the browser and only read by the server.
[<Literal>]
let ThemeCookie = "dsq_theme"

/// The sounds, synthesised at boot and served from `/sfx/<name>`. No binary assets in the repo.
let sfxNames =
    [| "correct"
       "wrong"
       "skip"
       "final"
       "tick" |]

/// `auto` unless the cookie says otherwise -- anything unrecognised is `auto`, because the value came
/// from a browser and a typo should not leave the page in a state the toggle cannot cycle out of.
let themeFrom (cookieValue: string) : string =
    match cookieValue with
    | "light" -> "light"
    | "dark" -> "dark"
    | _ -> "auto"

/// The stylesheet the `_css` experiment starts on: `hand` is `app.css`, anything else is
/// `app-<value>.css`. The file naming IS the contract -- the markup builds the href from the signal
/// rather than listing the sheets in a chain of ternaries.
let stylesheetHref (value: string) (prefix: string) : string =
    if value = "hand" then
        prefix + "/static/app.css"
    else
        prefix + "/static/app-" + value + ".css"

/// The session cookie is one per browser, so it cannot say which quiz a given *page* is playing: open
/// `?swedish` and the squad tab, the back-history entry and the phone's other tab all still hold the
/// old markup while the cookie has moved on. The page's own URLs can say it, and they are written by
/// the server that knows.
let variantQuery (variant: Variant) : string = "?" + variant.Key

/// A stamp that changes when this build does, for the `?v=` on the sound URLs.
///
/// The Rust port hashes its template sources with FNV-1a; the equivalent here is the module version
/// id, which the compiler regenerates on every build. Eight hex characters is plenty for a cache
/// buster.
let buildStamp =
    Assembly.GetExecutingAssembly().ManifestModule.ModuleVersionId.ToString("N").Substring(0, 8)

/// Where the skip milestones fall, as percentages of the goal -- the ticks on the points gauge. The
/// last milestone IS the goal, so it is dropped: a tick at 100% is the end of the bar.
let milestoneTicks =
    scoreMilestones
    |> Array.filter (fun milestone -> milestone < 1.0)
    |> Array.map (fun milestone -> pyRound (milestone * 100.0))

/// The prompt, which says which way round this question is.
let introFor (choiceType: ChoiceType) : string =
    match choiceType with
    | Descriptions -> "Which description matches the final bid in this sequence:"
    | Auctions -> "In which auction is the final bid best described by:"

/// One confetti bit: a glyph, how far it drifts across the CARD (a percentage of the card, not the
/// viewport, so the party cannot spill past the window edge and scroll the page), how far it spins,
/// and which step of the stagger it is on.
[<Struct; NoEquality; NoComparison>]
type ConfettiBit =
    { Glyph: string
      Drift: int
      Spin: int
      Step: int }

/// Fixed rather than random on purpose: the server renders the finale, and a reload should show the
/// same party. The offsets are spread by hand, because a formula (`i * 37 % 100`) looks combed rather
/// than scattered.
let confetti =
    [| { Glyph = "🎉"
         Drift = -42
         Spin = -35
         Step = 0 }
       { Glyph = "🎊"
         Drift = -28
         Spin = 24
         Step = 3 }
       { Glyph = "✨"
         Drift = -35
         Spin = -12
         Step = 7 }
       { Glyph = "🥳"
         Drift = -14
         Spin = 41
         Step = 1 }
       { Glyph = "🎉"
         Drift = -6
         Spin = -28
         Step = 5 }
       { Glyph = "🎊"
         Drift = 9
         Spin = 16
         Step = 2 }
       { Glyph = "✨"
         Drift = 18
         Spin = -44
         Step = 8 }
       { Glyph = "🎉"
         Drift = 27
         Spin = 31
         Step = 4 }
       { Glyph = "🥳"
         Drift = 36
         Spin = -19
         Step = 6 }
       { Glyph = "🎊"
         Drift = 44
         Spin = 38
         Step = 1 }
       { Glyph = "✨"
         Drift = -21
         Spin = 9
         Step = 9 }
       { Glyph = "🎉"
         Drift = 3
         Spin = -40
         Step = 7 }
       { Glyph = "🎊"
         Drift = 31
         Spin = 12
         Step = 3 }
       { Glyph = "✨"
         Drift = -47
         Spin = 27
         Step = 5 }
       { Glyph = "🥳"
         Drift = 22
         Spin = -33
         Step = 8 }
       { Glyph = "🎉"
         Drift = -11
         Spin = 44
         Step = 2 } |]

/// The deployment-shaped state the renderer needs and does not own.
[<NoEquality; NoComparison>]
type Config =
    {
        /// Where the app is mounted, when it is not at the root of a host. Empty for a root mount.
        Prefix: string
        /// whether `/timer` holds a connection instead of the browser running an interval
        StreamTimer: bool
        /// whether a patch carries the whole `#app` or only `#quiz`
        FatMorph: bool
    }

/// Everything both the document and the fat-morph fragment need, gathered once per render.
[<NoEquality; NoComparison>]
type PageData =
    {
        VariantTitle: string
        SystemNotesURL: string
        Settings: Session.Settings
        Playing: bool
        /// the `#quiz` body, already rendered: the question, the reveal or the finale
        QuizBody: string
        MinDifficulty: int
        MaxDifficulty: int
        MilestoneTicks: int array
        PointsGoal: int
        Debug: bool
        Qid: int64
        StreamTimer: bool
        BuildStamp: string
        CssHref: string
        CookiePath: string
        Topics: Names.TopicChoice array
        TopicsHaveDescriptions: bool
        FilterText: string
        /// the `#filter-status` body, already rendered
        FilterStatus: string
        Prefix: string
        VariantQuery: string
    }

// ---------------------------------------------------------------------------------------------
// the small fragments
// ---------------------------------------------------------------------------------------------

/// The `#toasts` fragment. An empty text renders an empty container -- the panel handler's bare
/// one-second beat between the last toast and the next question.
let toastFragment (item: Toast) : string =
    if item.Text = "" then
        ""
    else
        let kind = toastKindText item.Kind

        StringBuilder(96)
            .Append("<div class=\"toast ")
            .Append(kind)
            .Append(" notification is-")
            .Append(kind)
            .Append("\">")
            .Append(Escape.suits item.Text)
            .Append("</div>")
            .ToString()

/// The python's `[+-]\d+`.
let private findSignedNumber (text: string) : string =
    let mutable found = ""
    let mutable start = 0

    while found = "" && start < text.Length do
        if text[start] = '+' || text[start] = '-' then
            let mutable stop = start + 1

            while stop < text.Length && Char.IsAsciiDigit text[stop] do
                stop <- stop + 1

            if stop > start + 1 then
                found <- text.Substring(start, stop - start)

        start <- start + 1

    found

/// The number that floats up off the card the player chose, or "" for a beat without one.
///
/// The floater says what you SCORED, so only the beats carrying a number get one -- "Correct!" and
/// "Not quite" are already said by the card's own tick or cross. `+1 SKIP!` earns one because it is a
/// reward the corner toast makes too easy to miss.
///
/// `finalBeat` marks the answer that crossed the points goal: the same number, in gold, larger and
/// slower, because it is the last one the player will ever see on that card.
let floaterFragment (item: Toast) (finalBeat: bool) : string =
    let text = item.Text.Trim()

    let label =
        if text.Contains("SKIP", StringComparison.OrdinalIgnoreCase) then
            "+1 SKIP"
        else
            findSignedNumber text

    if label = "" then
        ""
    else
        let kind =
            (if label.StartsWith '+' then "gain" else "loss")
            + (if finalBeat then " final" else "")

        $"<span class=\"floater {kind}\" aria-hidden=\"true\">{label}</span>"

/// One sound beat: markup that plays `<audio id="sfx-<beat>">`, which is already in the page.
///
/// Appended to `#sfx`, which is the same trick as the floaters -- the server knows when the beat
/// happened, so the beat is a patch rather than something the browser has to work out. Two things are
/// deliberate: `$_sound &&` gates it client-side, because the preference is a LOCAL signal the server
/// cannot know; and `play()` alone, because an element that has ENDED rewinds itself on the next call
/// and one still playing ignores it, which is what makes `tick` self-spacing.
let sfxBeatFragment (beat: string) : string =
    $"<span aria-hidden=\"true\" data-init=\"$_sound && document.getElementById('sfx-{beat}')?.play()?.catch(() => {{}})\"></span>"

/// The shine that crosses the points gauge when a milestone has just paid for a skip. Appended to the
/// gauge itself, so it needs no signal and no cleanup: the fat morph at the end of the answer stream
/// rewrites `#app` from markup that never contains it.
[<Literal>]
let MeterSweepFragment = "<span class=\"meter-sweep\" aria-hidden=\"true\"></span>"

/// One span per character, numbered, so each digit can be sent in from somewhere different. The unit
/// lives INSIDE the figure: `.finale-stat` is a flex column, so a sibling `%` or `s` became its own
/// row under the number.
let figureFragment (value: string) (klass: string) (unit: string) : string =
    let out = StringBuilder 96
    out.Append("<span class=\"figure ").Append(klass).Append("\">") |> ignore

    for i in 0 .. value.Length - 1 do
        out
            .Append("<span class=\"digit\" style=\"--i: ")
            .Append(i)
            .Append("\">")
            .Append(value[i])
            .Append("</span>")
        |> ignore

    if unit <> "" then
        out.Append("<span class=\"figure-unit\">").Append(unit).Append("</span>")
        |> ignore

    out.Append("</span>").ToString()

/// The `#filter-status` fragment: what the text in the box *would* select.
///
/// Asking never commits anything, so this is safe to render on every keystroke -- which is the point:
/// the validation lives with the matcher, on the server, and the browser needs to know nothing about
/// bidding.
let filterStatusFragment (check: FilterCheck) (inForce: string) (pendingHint: string) : string =
    let lines = ResizeArray<string> 3
    let parsed = check.Parsed

    if parsed.Errors.Length > 0 then
        // the unrecognised entries are whatever the user typed, so they are escaped
        let line = StringBuilder("⚠ not a topic or pattern: ")

        for i in 0 .. parsed.Errors.Length - 1 do
            if i > 0 then
                line.Append ", " |> ignore

            line.Append("<code>") |> ignore
            Escape.escapeInto parsed.Errors[i] line
            line.Append("</code>") |> ignore

        lines.Add(line.ToString())

    match check.Status with
    | FilterTooFew ->
        lines.Add $"⚠ only {check.Hits.Length} match, need {MaxDifficulty}+ — the whole system is used"
    | FilterError -> lines.Add "⚠ nothing usable — the whole system is used"
    | _ when parsed.Entries.Length = 0 ->
        lines.Add $"the whole system, <strong>{check.Hits.Length}</strong> auctions"
    | _ -> lines.Add $"<strong>{check.Hits.Length}</strong> auctions match"

    if pendingHint <> "" && parsed.CanonicalText <> inForce then
        let line = StringBuilder "<em>"
        Escape.escapeInto pendingHint line
        line.Append "</em>" |> ignore
        lines.Add(line.ToString())

    let out = StringBuilder 128

    for line in lines do
        out.Append("<div class=\"filter-line\">").Append(line).Append("</div>\n")
        |> ignore

    out.ToString()
