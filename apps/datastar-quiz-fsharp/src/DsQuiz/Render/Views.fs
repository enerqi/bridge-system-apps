/// The pages, as F# rather than as template files.
///
/// Every datastar attribute is written with `.attr`, not with the view engine's typed attribute
/// surface, and that is on purpose: they are `data-on:keydown__window`, `data-attr:disabled`,
/// `data-bind:topics.1-c-opening` -- names with colons and dots that no typed surface covers -- and
/// writing all of them the same way keeps this file a line-for-line reading of the other ports'
/// templates. Attribute ORDER follows the templates too, because that is half of what the parity diff
/// checks.
///
/// TWO THINGS THE F# COMPILER FORCED, both worth knowing before editing:
///
///  - The expressions are built by CONCATENATION rather than interpolation. Datastar expressions are
///    full of single quotes (`@post('/next')`), and an interpolated string cannot hold a quote inside
///    its `{...}` hole -- so `$"... {post page \"/next\"}"` is a compile error, not a style choice.
///  - `svg`, `path` and `text` are not among the engine's tags (they are SVG, not HTML), so the dial
///    below uses three one-line custom nodes.
///
/// A NOTE ON THE VALUELESS FORMS. The templates write `data-bind:difficulty` with no value, where
/// datastar reads the KEY. Here they are `.attr(name, "")`, which renders `name=""` -- the same thing
/// to an HTML parser and to datastar, and the only form the engine offers.
module DsQuiz.Render.Views

open Oxpecker.ViewEngine

open DsQuiz.Engine
open DsQuiz.Render
open DsQuiz.Render.Page

/// The three SVG tags the score dial needs.
///
/// `path` is a REGULAR node even though it never has children, and that is not an oversight: a void
/// node renders `<path ...>` with no closing tag, and inside `<svg>` the HTML parser is in FOREIGN
/// CONTENT where no element is void -- so an unclosed `<path>` swallows every sibling after it and the
/// dial's `<text>` ends up inside it. `<path ...></path>` is what a browser needs to see.
type private svg() =
    inherit RegularNode("svg")

type private path() =
    inherit RegularNode("path")

type private svgText() =
    inherit RegularNode("text")

/// `@post('<prefix>/<route><variantQuery>')`, which is most of what this page's attributes say.
let private post (page: PageData) (route: string) : string =
    "@post('" + page.Prefix + route + page.VariantQuery + "')"

let private get' (page: PageData) (route: string) : string =
    "@get('" + page.Prefix + route + page.VariantQuery + "')"

/// `window.matchMedia('<query>').matches` -- "the drawer is an overlay right now".
let private atOverlayWidth =
    "window.matchMedia('" + DrawerOverlayQuery + "').matches"

// ---------------------------------------------------------------------------------------------
// #quiz -- the question, the reveal, the finale
// ---------------------------------------------------------------------------------------------

/// The question: prompt, the thing to match, and the candidate buttons.
///
/// THE ACTION IS IN THE URL -- `/answer/<qid>/<index>` -- not in a signal. The qid is the server's
/// question nonce, so a second click, a stale tab or a replayed request scores nothing: the server
/// compares the qid and resyncs the page. That replaces the panel app's "multiple clicks occurred too
/// quickly before server disabled the buttons" guard.
///
/// `data-indicator` sets a local signal while the request is in flight, and every button reads it to
/// disable itself. It is written in the *value* form, not as `data-indicator:_answering`: attribute
/// keys go through `kebab`, which turns a leading underscore into a dash and then drops it, so the key
/// form would name the signal `Answering` -- losing the underscore that keeps it local.
///
/// These are BUTTONS, not a radio group: a click commits immediately, with no separate submit. What
/// they get instead is `role="group"` with a label, and a digit accelerator each -- through ONE window
/// keydown handler on the group, not one per button. Five identical `__window` listeners were five
/// registrations and five teardowns per patch, and five copies of the same guard to keep in step.
///
/// The guard is three things: `$_answering` (an answer already in flight -- NOT cosmetic: the server
/// mutates before it streams, so by the time the toasts are playing the *next* question is already the
/// live one); `closest(TypingTargets)` (a keystroke aimed at a control that has a use for it belongs to
/// that control); and the digit being in range for THIS question. `evt.key` is compared through
/// `Number`, so a ten-choice question cannot silently accept "1" as ten.
let question
    (page: PageData)
    (intro: string)
    (answer: string)
    (candidates: string array)
    : Oxpecker.ViewEngine.Tags.Fragment =
    let digitAccelerator =
        "!$_answering && !$_topicsOpen\n       && !evt.target.closest?.('"
        + TypingTargets
        + "')\n       && Number(evt.key) >= 1 && Number(evt.key) <= "
        + string candidates.Length
        + "\n       && @post('"
        + page.Prefix
        + "/answer/"
        + string page.Qid
        + "/' + (Number(evt.key) - 1) + '"
        + page.VariantQuery
        + "')"

    Fragment() {
        h2 (class' = "intro") { intro }

        p (class' = "answer") {
            raw "&ldquo;"
            strong () { raw answer }
            raw "&rdquo;"
        }

        // `data-attr` in the OBJECT form, because a hyphenated attribute name cannot survive as a key:
        // `data-attr:aria-busy` is kebab-then-camel converted to `ariaBusy` and nothing reaches the
        // DOM -- no `aria-busy`, no error, the attribute simply never appears. The value is the STRING
        // "true"/"false", not the boolean: a boolean `true` renders as `aria-busy=""` (datastar's "set
        // the attribute" form), and an empty string is not a valid ARIA state.
        div(class' = "candidates")
            .attr("role", "group")
            .attr("aria-label", "answer choices")
            .attr("data-indicator", "_answering")
            .attr("data-attr", "{'aria-busy': $_answering ? 'true' : 'false'}")
            .attr ("data-on:keydown__window", digitAccelerator) {
            for index in 0 .. candidates.Length - 1 do
                button(type' = "button", class' = "candidate button")
                    .attr("data-indicator", "_answering")
                    .attr("data-attr:disabled", "$_answering")
                    .attr ("data-on:click", post page ("/answer/" + string page.Qid + "/" + string index)) {
                    kbd(class' = "accel tag is-light").attr ("aria-hidden", "true") { index + 1 }

                    span (class' = "candidate-text") { raw candidates[index] }
                }
        }
    }

/// Shown in `#quiz` after a wrong answer, instead of panel's 4.2s centre-screen toast.
///
/// Non-blocking and in place: the prompt stays, the right answer is marked, the choice you took is
/// marked, and nothing advances until you say so. The clock for the NEXT question starts when it is
/// served, so reading this costs you no time bonus.
let reveal
    (page: PageData)
    (intro: string)
    (answer: string)
    (candidates: string array)
    (correctIndex: int)
    (wrongIndex: int)
    : Oxpecker.ViewEngine.Tags.Fragment =
    // The window keydown lives on the WRAPPER and excludes BUTTON, because a focused button already
    // activates on Enter/Space natively. Binding both to the button fired two `@post('/next')`s: the
    // second superseded and aborted the first, after the server had already advanced the question --
    // so state moved on while the browser kept the stale reveal.
    //
    // Form controls are excluded with `closest`, not a tagName list: Enter in the filter box commits a
    // filter and must not also advance the question. ACTIVATION targets, not TYPING targets: Space
    // ACTIVATES a focused checkbox or radio, so those keep their claim on this key.
    let advance =
        "(evt.key === 'Enter' || evt.key === ' ')\n       && !$_topicsOpen\n       && evt.target.tagName !== 'BUTTON'\n       && !evt.target.closest?.('"
        + ActivationTargets
        + "')\n       && "
        + post page "/next"

    Fragment() {
        h2 (class' = "intro") { intro }

        p (class' = "answer") {
            raw "&ldquo;"
            strong () { raw answer }
            raw "&rdquo;"
        }

        div(class' = "candidates").attr("role", "group").attr ("aria-label", "answer choices, revealed") {
            for index in 0 .. candidates.Length - 1 do
                let verdict =
                    if index = correctIndex then "correct"
                    elif index = wrongIndex then "wrong"
                    else ""

                div (class' = "candidate revealed " + verdict) {
                    span(class' = "mark").attr ("aria-hidden", "true") {
                        raw (
                            if index = correctIndex then "&#10003;"
                            elif index = wrongIndex then "&#10007;"
                            else ""
                        )
                    }

                    span (class' = "candidate-text") { raw candidates[index] }
                }
        }

        div(class' = "reveal-actions").attr ("data-on:keydown__window", advance) {
            button(type' = "button", class' = "next button is-primary")
                .attr("autofocus", "")
                .attr ("data-on:click", post page "/next") {
                "Next question"
            }

            span (class' = "reveal-hint") { "or press Enter" }
        }
    }

/// Replaces `#quiz` once the points goal (and the target percentage, if required) is met.
///
/// This is the payoff for a quiz that takes several minutes, and it used to be three static party emoji
/// and a sentence. The finale is built from pieces CSS can animate individually, which is the only
/// reason any of this needs markup rather than a stylesheet: every party emoji is its OWN span (a
/// single text node cannot be staggered), every digit of every number is its own span (`figureFragment`),
/// and the confetti is a fixed list of glyph / drift / spin / delay tuples rendered as inline custom
/// properties -- the drift is a percentage of the CARD, not of the viewport, so the party cannot spill
/// past the window edge and scroll the page.
///
/// Inert without the game-feel toggle: `juice.css` scopes every rule to `body.juice`. `aria-hidden` on
/// the decoration -- a screen reader wants the numbers and the sentence, not sixteen confetti.
let completed
    (page: PageData)
    (elapsed: string)
    (points: int)
    (correct: int)
    (attempted: int)
    (percentage: int)
    (goal: int)
    : Oxpecker.ViewEngine.Tags.div =
    div (class' = "finale") {
        div(class' = "confetti").attr ("aria-hidden", "true") {
            for bit in confetti do
                span(class' = "confetti-bit")
                    .attr (
                        "style",
                        "--drift: "
                        + string bit.Drift
                        + "%; --spin: "
                        + string bit.Spin
                        + "deg; --i: "
                        + string bit.Step
                    ) {
                    bit.Glyph
                }
        }

        h2(class' = "celebrate").attr ("aria-hidden", "true") {
            for index in 0..3 do
                span(class' = "pop").attr ("style", "--i: " + string index) { raw "&#127881;" }
        }

        p (class' = "celebrate-text") { "Quiz complete!" }

        div (class' = "finale-figures") {
            span (class' = "finale-stat") {
                raw (figureFragment (string points) "big" "")

                span (class' = "finale-label") { "points of " + string goal }
            }

            span (class' = "finale-stat") {
                raw (figureFragment (string percentage) "" "%")

                span (class' = "finale-label") { string correct + " of " + string attempted + " right" }
            }

            span (class' = "finale-stat") {
                raw (figureFragment elapsed "" "s")

                span (class' = "finale-label") { "start to finish" }
            }
        }

        p (class' = "celebrate-text") { raw "Well done, now take a break&hellip;" }

        img(src = page.Prefix + "/media/completed.jpeg", alt = "cat sleeping next to computer mouse")
            .attr ("width", "600")
    }

// ---------------------------------------------------------------------------------------------
// the topics picker
// ---------------------------------------------------------------------------------------------

/// A NON-MODAL dialog (`open`, not `showModal()`), because the picker is a panel over the card rather
/// than a trap: it gets no Escape handling from the browser, so that is wired by hand, and the guard on
/// `$_topicsOpen` keeps the key free for anything else when the picker is shut.
///
/// Ticking boxes changes `$topics` (no underscore, so it is uploaded) but commits nothing: the working
/// set only changes on Apply. Closing DISCARDS -- the same path as the Close button, because the
/// dialog's first line promises that nothing changes until Apply.
let topicsDialog (page: PageData) : Oxpecker.ViewEngine.Tags.dialog =
    let discard = get' page "/filter/topics-reset"
    let previewTopics = get' page "/filter/preview-topics"

    dialog(class' = "topics-dialog", id = "topics-dialog")
        .attr("data-attr:open", "$_topicsOpen")
        .attr (
            "data-on:keydown__window",
            "evt.key === 'Escape' && $_topicsOpen\n          && ($_topicsOpen = false, "
            + discard
            + ")"
        ) {
        h2 () { "Topics" }

        p () {
            raw
                "Pick any number &mdash; an auction matching <em>any</em> selected topic is included. Nothing\n    changes until you press <strong>Apply</strong>, which replaces whatever is in the filter box."
        }

        // The LIST scrolls, not the dialog: with nineteen topics Apply / Clear / Close were sliced in
        // half at the bottom edge, and the actions of a dialog should never be the thing you have to
        // scroll to find. The list itself flows into as many columns as the card is wide enough for.
        div (class' = "topics-scroll") {
            div (class' = "topic-list") {
                for topic in page.Topics do
                    label (class' = "checkbox") {
                        input(type' = "checkbox").attr(topic.Bind, "").attr ("data-on:change", previewTopics)

                        topic.Name
                    }
            }

            div (id = "topics-status", class' = "filter-status") { () }

            if page.TopicsHaveDescriptions then
                details().attr ("data-preserve-attr", "open") {
                    summary () { "What the topics mean" }

                    ul (class' = "topic-legend") {
                        for topic in page.Topics do
                            if topic.Description <> "" then
                                li () {
                                    strong () { topic.Name }

                                    raw " &mdash; "
                                    topic.Description
                                }
                    }
                }
        }

        div (class' = "dialog-actions") {
            button(type' = "button", class' = "button is-primary")
                .attr ("data-on:click", "$_topicsOpen = false; " + post page "/filter/apply-topics") {
                "Apply"
            }

            // `@setAll`, not `$topics = {}`: the boxes bind one LEAF at a time
            // (`data-bind:topics.<slug>`), so `topics` is a NAMESPACE, not a value -- assigning an
            // empty object to it replaces the branch the bindings are watching instead of writing to
            // the leaves, and every box stayed ticked. The `@get` after it is not decoration: the
            // status line under the list is server-rendered from the ticks, so without it Clear leaves
            // "N topics selected" under an empty list.
            button(type' = "button", class' = "light button is-light")
                .attr ("data-on:click", "@setAll(false, {include: /^topics\\./}); " + previewTopics) {
                "Clear"
            }

            button(type' = "button", class' = "light button is-light")
                .attr ("data-on:click", "$_topicsOpen = false; " + discard) {
                "Close"
            }
        }
    }

// ---------------------------------------------------------------------------------------------
// #app -- the fat morph target
// ---------------------------------------------------------------------------------------------

/// The Notation list: static, so it is rendered once at module init and appended as a string on every
/// render thereafter.
let private notationNotes =
    prerender (
        details(class' = "notes").attr ("data-preserve-attr", "open") {
            summary () { "Notation" }

            ul () {
                li () {
                    "Bids in brackets e.g (1♥), (bid), (any), (1NT) etc. indicate the opponents made the bid."
                }

                li () { "The opponents' bids are often automatically removed from the question" }
                li () { "~ means roughly/approximately (points are guides, not absolute)" }
                li () { "X or Dbl means double" }
                li () { "GF/FG means game forcing" }
                li () { "NF means non-forcing" }
                li () { "M means major, oM other major" }
                li () { "m means minor, om other minor" }
                li () { "Hx/HHx means Honour + x (small card), Honour Honour x etc." }
            }
        }
    )

/// The filter syntax help: also static.
let private filterHelp =
    prerender (
        details(class' = "filter-help").attr ("data-preserve-attr", "open") {
            summary () { "Filter syntax" }

            ul () {
                li () {
                    code () { "1D-1M-1N" }

                    raw " a bid; suits C D H S N. Separate calls with a dash or a space &mdash; "

                    code () { "1D 1H" }
                    ", "

                    code () { "1D-1H" }
                    " and "

                    code () { "1D--1H" }
                    " are the same"
                }

                li () {
                    code () { "M" }
                    " / "

                    code () { "m" }

                    raw " any major / any minor &mdash; "

                    em () { "the only place case matters" }
                }

                li () {
                    code () { "1*" }
                    " / "

                    code () { "*" }
                    " any suit at that level / any call"
                }

                li () {
                    code () { "Pass" }
                    " "

                    code () { "X" }
                    " "

                    code () { "XX" }
                    " pass, double, redouble"
                }

                li () {
                    code () { "(2H)" }
                    " brackets = the opponents' call; "

                    code () { "(*)" }
                    " = they did something"
                }

                li () {
                    code () { "1D-1M, 2C" }

                    raw " comma separates alternatives &mdash; either one matches"
                }
            }

            p () {
                raw
                    "A pattern describes <strong>your</strong> auction: opponent calls you do not mention are stepped over, so <code>1D-1H</code> matches 1D (Pass) 1H, 1D (1S) 1H and 1D (X) 1H. Bracket a call to pin the opponents down at that exact point. Too few matches falls back to the whole system."
            }
        }
    )

let private topbar (page: PageData) : Oxpecker.ViewEngine.Tags.header =
    // Three states in one button: auto (the OS decides, the default) -> light -> dark. Auto is a real
    // state, not a synonym for light: it is the only one that follows the machine when it switches at
    // sunset, and it is what `data-theme` being ABSENT means.
    let cycleTheme =
        "$_theme = $_theme === 'auto' ? 'light' : ($_theme === 'light' ? 'dark' : 'auto');\n                document.cookie = '"
        + ThemeCookie
        + "=' + $_theme + ';path="
        + page.CookiePath
        + ";max-age=31536000;samesite=lax'"

    // The `s` accelerator restates the button's own disabled conditions, because a window handler does
    // not inherit them.
    let skipAccelerator =
        "evt.key === 's'\n                && $_skipsLeft > 0 && $_playing && !$_answering && !$_topicsOpen\n                && !evt.target.closest?.('"
        + TypingTargets
        + "')\n                && "
        + post page "/skip"

    header (class' = "topbar") {
        button(type' = "button", class' = "nav-toggle")
            .attr("aria-label", "Toggle sidebar")
            .attr("data-attr:aria-expanded", "$_navOpen")
            .attr ("data-on:click", "$_navOpen = !$_navOpen") {
            span(class' = "bars").attr ("aria-hidden", "true") { () }
        }

        h1 () { page.VariantTitle }

        // The glyphs are symbol-font TEXT, not emoji, so they take the app bar's white.
        button(type' = "button", class' = "theme-toggle button")
            .attr("data-attr:aria-label", "'Colour theme: ' + $_theme + '. Activate to change.'")
            .attr("data-attr:title", "'Theme: ' + $_theme")
            .attr ("data-on:click", cycleTheme) {
            span()
                .attr("aria-hidden", "true")
                .attr ("data-text", "$_theme === 'light' ? '☀' : ($_theme === 'dark' ? '☾' : '◐')") {
                "◐"
            }
        }

        span (class' = "topbar-spacer") { () }

        // The streak GROWS with the run and warms through two colour bands. `Math.min` caps the growth
        // at 8 -- an unbounded scale eventually reflows the app bar. It SAYS "streak", because a bare
        // "3x" is a rebus; the word is dropped again under 560px, and the `aria-label` carries it at
        // every width.
        span(class' = "streak")
            .attr("data-attr:aria-label", "'streak ' + $_streak")
            .attr("data-class", "{hot: $_streak >= 3, blazing: $_streak >= 6, cold: $_streak < 1}")
            .attr ("data-style:transform", "'scale(' + (1 + Math.min($_streak, 8) * 0.06) + ')'") {
            span(class' = "streak-label").attr ("aria-hidden", "true") { "streak" }

            span().attr("aria-hidden", "true").attr ("data-text", "$_streak") { () }

            span().attr ("aria-hidden", "true") { raw "&times;" }
        }

        span (class' = "topbar-score") {
            span (class' = "score-fraction") {
                span().attr ("data-text", "$_correct") { () }
                "/"

                span().attr ("data-text", "$_attempted") { () }

                raw "&nbsp;·&nbsp;"
            }

            span().attr ("data-text", "$_points") { () }
            " pts"
        }

        // The gauge is TICKED at the milestones: each one is a skip you can earn, so the bar answers
        // "how close am I to another skip" at a glance. The gradient stays on the track with a mask
        // over the unearned part, so a colour means the same number of points wherever the bar has
        // reached.
        div(class' = "meter points-meter hud-meter")
            .attr("role", "img")
            .attr("data-class", "{full: $_pointsPct >= 100}")
            .attr ("data-attr:aria-label", "'points ' + $_points + ' of " + string page.PointsGoal + "'") {
            div(class' = "meter-mask").attr ("data-style:width", "(100 - $_pointsPct) + '%'") { () }

            for pct in page.MilestoneTicks do
                span(class' = "meter-tick")
                    .attr("style", "left: " + string pct + "%")
                    .attr ("data-class", "{earned: $_pointsPct >= " + string pct + "}") {
                    ()
                }
        }

        button(type' = "button", class' = "skip warning button is-warning")
            .attr("data-attr:disabled", "$_skipsLeft <= 0 || !$_playing")
            .attr("data-on:click", post page "/skip")
            .attr ("data-on:keydown__window", skipAccelerator) {
            "Skip "

            span(class' = "skip-count").attr ("data-text", "$_skipsLeft") { () }
        }
    }

let private progressPanel (page: PageData) : Oxpecker.ViewEngine.Tags.details =
    // `data-preserve-attr="open"`: `open` is state the PLAYER set, and the server has no idea about it
    // -- so a fat morph, which rewrites `#app` from markup that never carries the attribute, snapped
    // every disclosure shut on every answer, skip and restart.
    details(class' = "panel box progress", id = "progress").attr ("data-preserve-attr", "open") {
        summary () { "Progress" }

        // The dial is ONE path whose dash offset is driven by a signal, so nothing is patched to move
        // it. `PI * 90 = 282.74` is the full sweep.
        svg()
            .attr("class", "dial")
            .attr("viewBox", "0 0 200 110")
            .attr("role", "img")
            .attr ("aria-label", "percentage correct") {
            path().attr("class", "dial-track").attr ("d", "M 10 100 A 90 90 0 0 1 190 100") { () }

            path()
                .attr("class", "dial-value")
                .attr("d", "M 10 100 A 90 90 0 0 1 190 100")
                .attr("data-style:stroke-dashoffset", "282.74 * (1 - $_scorePct / 100)")
                .attr (
                    "data-class",
                    "{poor: $_scorePct < 30, weak: $_scorePct >= 30 && $_scorePct < 49, fair: $_scorePct >= 49 && $_scorePct < 59, ok: $_scorePct >= 59 && $_scorePct < 75, good: $_scorePct >= 75}"
                ) {
                ()
            }

            svgText()
                .attr("class", "dial-text")
                .attr("x", "100")
                .attr("y", "95")
                .attr ("data-text", "$_scorePct + '%'") {
                "0%"
            }
        }

        p (class' = "score-line") {
            span().attr ("data-text", "$_correct") { () }
            " of "

            span().attr ("data-text", "$_attempted") { () }
            " right "

            raw "&middot; "

            span().attr ("data-text", "$_points") { () }
            " / " + string page.PointsGoal + " points"
        }
    }

/// Only rendered when the session is armed -- `?debug` on a page load, or `DSQUIZ_DEBUG=1`. Not styled
/// beyond a warning tint on purpose: it should look like scaffolding.
let private debugPanel (page: PageData) : Oxpecker.ViewEngine.Tags.section =
    // Bound out here rather than inline: a parenthesised `if` is ambiguous as a computation-expression
    // child, and the compiler says so.
    let playingText = if page.Playing then "playing " else "finished "

    section (class' = "panel box debug", id = "debug") {
        strong () { "Debug" }

        div (class' = "debug-row") {
            button(type' = "button", class' = "button is-small")
                .attr ("data-on:click", post page "/debug/points/100") {
                "+100 pts"
            }

            button(type' = "button", class' = "button is-small")
                .attr ("data-on:click", post page "/debug/points/-100") {
                raw "&minus;100"
            }
        }

        div (class' = "debug-row") {
            // a 200-point goal exercises the whole milestone ladder in a minute
            button(type' = "button", class' = "button is-small")
                .attr ("data-on:click", post page "/debug/goal/200") {
                "goal 200"
            }

            button(type' = "button", class' = "button is-small")
                .attr ("data-on:click", post page "/debug/goal/1000") {
                "goal 1000"
            }
        }

        div (class' = "debug-row") {
            button(type' = "button", class' = "button is-small")
                .attr ("data-on:click", post page "/debug/reveal") {
                "show reveal"
            }

            button(type' = "button", class' = "button is-small")
                .attr ("data-on:click", post page "/debug/complete") {
                "show finale"
            }
        }

        p (class' = "hint") {
            "goal " + string page.PointsGoal + " "

            raw "&middot; "
            "qid " + string page.Qid + " "

            raw "&middot; "
            playingText

            raw "&middot; "
            "build " + page.BuildStamp
        }
    }

let private controlsPanel (page: PageData) : Oxpecker.ViewEngine.Tags.section =
    let settingsPost = post page "/settings"

    // `checked` is server-rendered: an unchecked box on first paint is state the binding would push
    // back up, quietly turning ladder mode off. Built out here because a `let` followed by an `if` is
    // ambiguous as a computation-expression child.
    let checkbox (bind: string) (isChecked: bool) =
        let box =
            input(type' = "checkbox").attr(bind, "").attr ("data-on:change", settingsPost)

        if isChecked then box.attr ("checked", "") else box

    let ladderBox = checkbox "data-bind:ladder-mode" page.Settings.LadderMode
    let targetBox = checkbox "data-bind:target-on" page.Settings.TargetOn

    section (class' = "panel box controls") {
        label () {
            "Difficulty "

            output().attr ("data-text", "$difficulty") { () }

            // DEBOUNCED, because with the KEYBOARD `change` fires on every arrow keypress and a
            // settings change restarts the quiz, so holding an arrow key wiped the score. `value` is
            // server-rendered too: a range input with no value defaults to the midpoint of its span,
            // which is what the browser paints before datastar's binding has run.
            input(type' = "range")
                .attr("min", string page.MinDifficulty)
                .attr("max", string page.MaxDifficulty)
                .attr("step", "1")
                .attr("value", string page.Settings.Difficulty)
                .attr("data-bind:difficulty", "")
                .attr ("data-on:change__debounce.400ms", settingsPost)
        }

        label (class' = "checkbox") {
            ladderBox
            " Ladder mode (can lose points)"
        }

        label (class' = "checkbox") {
            targetBox
            " Target percentage required"
        }

        label () {
            "Target "

            output().attr ("data-text", "$targetPct") { () }
            "%"

            input(type' = "range")
                .attr("min", "70")
                .attr("max", "90")
                .attr("step", "10")
                .attr("value", string page.Settings.TargetPct)
                .attr("data-attr:disabled", "!$targetOn")
                .attr("data-bind:target-pct", "")
                .attr ("data-on:change__debounce.400ms", settingsPost)
        }

        // The topics picker and the filter box answer the same question at two very different prices: a
        // topic is a name you recognise, the filter is a pattern language with six rules. Opening the
        // picker closes the drawer at overlay widths, so on a phone you are not looking at a dialog
        // stacked on top of the thing you opened it from.
        if page.Topics.Length > 0 then
            button(type' = "button", class' = "light button is-light")
                .attr ("data-on:click", "$_topicsOpen = true; " + atOverlayWidth + " && ($_navOpen = false)") {
                raw "Topics&hellip;"
            }

        // The STATUS line stays outside the fold: it says what the working set currently is.
        div (class' = "filter-status", id = "filter-status") { raw page.FilterStatus }

        details(class' = "advanced").attr ("data-preserve-attr", "open") {
            summary () { "Advanced: bidding tree filter" }

            // Every keystroke asks the server what it WOULD select; only Enter commits. The validation
            // stays where the matcher is, so the browser knows nothing about bidding.
            label () {
                "Bidding tree filter"

                input(type' = "text", class' = "input")
                    .attr("list", "topic-names")
                    .attr("placeholder", "e.g. 1D-1M-1N, or a topic")
                    .attr("value", page.FilterText)
                    .attr("data-bind:filter-text", "")
                    .attr("data-on:input__debounce.300ms", get' page "/filter/preview")
                    .attr (
                        "data-on:keydown",
                        "evt.key === 'Enter' && (evt.target.blur(), " + post page "/filter/apply" + ")"
                    )
            }

            datalist (id = "topic-names") {
                for topic in page.Topics do
                    option().attr ("value", topic.Name) { () }
            }

            filterHelp
        }

        p (class' = "hint") { em () { "Changes restart the quiz." } }

        // Restart CLOSES the drawer at overlay widths: at those widths the drawer covers the quiz, so
        // "start again" that leaves you looking at the settings panel you just used is a second tap for
        // no reason. Only the explicit button does this -- the sliders and checkboxes restart the quiz
        // too, and you may be adjusting several.
        button(type' = "button", class' = "danger button is-danger")
            .attr (
                "data-on:click",
                post page "/restart"
                + ";\n                    "
                + atOverlayWidth
                + " && ($_navOpen = false)"
            ) {
            "Restart"
        }

        details(class' = "appearance").attr ("data-preserve-attr", "open") {
            summary () { "Appearance" }

            // The two `<select>`s BLUR on change, because a focused select keeps the keyboard and the
            // digit accelerators ignore keystrokes aimed at a form control -- so picking a font or a
            // stylesheet silently disabled 1-9 for the rest of the session. These two are safe to blur
            // because a change is the whole interaction; the difficulty slider and the filter box are
            // NOT.
            //
            // The Bulma option is the reason for the `class="light button is-light"` pairs throughout
            // this file: Bulma is class-based, so the framework's class strings have to be IN the
            // markup, and they ship on every patch whichever stylesheet is active. That is the cost the
            // comparison is measuring, so it is paid in the open. DEBUG ONLY: the A/B/C is settled.
            if page.Debug then
                label () {
                    "Base CSS"

                    div (class' = "select") {
                        select().attr("data-bind", "_css").attr ("data-on:change", "evt.target.blur()") {
                            option().attr ("value", "hand") { "Hand-rolled" }
                            option().attr ("value", "pico") { "Pico classless" }
                            option().attr ("value", "bulma") { "Bulma (spike)" }
                        }
                    }
                }

            // `checked` here has to AGREE with the declared default of `$_juice`: an unchecked box would
            // be what `data-bind` uploads into the signal on first paint, turning it off before anyone
            // chose to.
            label (class' = "checkbox") {
                input(type' = "checkbox").attr("checked", "").attr ("data-bind", "_juice")

                " Game feel (shake, floating points, streak)"
            }

            // Note the MISSING `checked` -- it has to agree with the declared default of `$_sound`, or
            // the first paint would upload `true` into the signal and the quiz would start making noise
            // on its own.
            label (class' = "checkbox") {
                input(type' = "checkbox").attr ("data-bind", "_sound")

                " Sound (countdown tick, scoring chimes)"
            }

            label () {
                "Font"

                div (class' = "select") {
                    select().attr("data-bind", "_font").attr ("data-on:change", "evt.target.blur()") {
                        option().attr ("value", "notes") { "Open Sans (as the notes)" }
                        option().attr ("value", "system") { "System UI" }
                        option().attr ("value", "rounded") { "Rounded" }
                        option().attr ("value", "serif") { "Serif" }
                        option().attr ("value", "mono") { "Monospace" }
                    }
                }
            }
        }
    }

/// THE COUNTDOWN IS THE EXPERIMENT (`DSQUIZ_TIMER`): `client` walks `$_timeLeftPct` down from the
/// allowance the server stated with the question -- no connection held, no per-tick server work;
/// `stream` has a held SSE connection push the value, which is panel's model exactly. Either way
/// nothing here is trusted for scoring: the bonus is recomputed server-side from the question's start
/// time when the answer arrives.
///
/// In stream mode the connection is opened by `data-init` on `<body>`, NOT here: this element is inside
/// the morph target, so a per-patch `data-init` would open a fresh held connection on every
/// interaction.
///
/// The interval gates on `$_ticking`, the server's "a live, unanswered question is being timed", not on
/// `$_playing` -- which is only false once the whole quiz is over, so the bar kept draining after a
/// question was answered. The last three seconds also TICK, when sound is on; it rides this interval
/// rather than having one of its own, and `$_timeLeftPct * $_questionMs < 300000` is "under three
/// seconds left" without a division.
let private timerBar (page: PageData) : Oxpecker.ViewEngine.Tags.div =
    let bar =
        div (class' = "timer", id = "timer") {
            // The bands are the game-feel layer: the last one throbs, and a bar that is FROZEN behind a
            // reveal must not -- urgency about a question you have already answered is a lie.
            div(class' = "timer-fill")
                .attr("data-style:width", "$_timeLeftPct + '%'")
                .attr (
                    "data-class",
                    "{spent: $_timeLeftPct < 17, low: $_timeLeftPct >= 17 && $_timeLeftPct < 49, mid: $_timeLeftPct >= 49 && $_timeLeftPct < 65, high: $_timeLeftPct >= 65, ticking: $_ticking && !$_answering}"
                )
        }

    if page.StreamTimer then
        bar
    else
        bar.attr (
            "data-on-interval__duration.100ms",
            "$_ticking && !$_answering && ($_timeLeftPct = Math.max(0, $_timeLeftPct - 10000 / $_questionMs)) && $_sound && $_timeLeftPct * $_questionMs < 300000 && document.getElementById('sfx-tick')?.play()?.catch(() => {})"
        )

let private mainColumn (page: PageData) : Oxpecker.ViewEngine.Tags.main =
    main (class' = "main") {
        // COMING BACK FROM THE SYSTEM NOTES TAKES THE KEYBOARD BACK. Read the notes, click inside them
        // to scroll, come back to the quiz, and 1-9 do nothing while the mouse still works. Nothing
        // here is broken when that happens -- the notes are an <iframe>, so a click inside them puts
        // focus in ANOTHER DOCUMENT, and every accelerator here is a `__window` listener on ours.
        // Bringing the pointer back to the question is the gesture that means "I am playing again", so
        // that is where the focus is taken back. Narrow on purpose -- only when the thing holding focus
        // is an iframe -- and `window.focus()` as well as the blur, because the parent document has to
        // be the one holding focus.
        section(class' = "card", id = "quiz")
            .attr (
                "data-on:mouseenter",
                "document.activeElement?.tagName === 'IFRAME'\n                   && (document.activeElement.blur(), window.focus())"
            ) {
            raw page.QuizBody
        }

        timerBar page

        div(class' = "toasts", id = "toasts").attr ("aria-live", "polite") { () }

        if page.Topics.Length > 0 then
            topicsDialog page

        notationNotes

        details(class' = "notes").attr ("data-preserve-attr", "open") {
            summary () { "System Notes" }

            iframe().attr("src", page.SystemNotesURL).attr("title", "system notes").attr ("loading", "lazy")
        }
    }

/// The morph target: patched WHOLE on every interaction ("fat morph").
///
/// The Tao of Datastar: "Morphing ensures that only modified parts of the DOM are updated, preserving
/// state and improving performance. This allows you to send down large chunks of the DOM tree". So this
/// is the unit of update, and the server stops having to remember which fragments a change touches --
/// the class of bug that let a clamped `difficulty` sit stale in the sidebar.
///
/// Two things stay OUTSIDE this region, on `<body>`, precisely because they must not be re-created by a
/// morph: the signal declarations, and `data-init` (which in stream mode opens the timer connection --
/// re-running it per patch would leak a held connection each time).
let app (page: PageData) : Oxpecker.ViewEngine.Tags.Fragment =
    Fragment() {
        topbar page

        div(class' = "layout").attr ("data-class", "{'nav-closed': !$_navOpen}") {
            // The outside-click close checks `.nav-toggle` explicitly: the toggle lives OUTSIDE the
            // drawer, so opening it also counted as an outside click and the two handlers cancelled
            // each other out.
            aside(class' = "sidebar")
                .attr (
                    "data-on:click__outside",
                    "$_navOpen && "
                    + atOverlayWidth
                    + " && !evt.target.closest('.nav-toggle') && ($_navOpen = false)"
                ) {
                progressPanel page

                if page.Debug then
                    debugPanel page

                controlsPanel page
            }

            mainColumn page
        }
    }

// ---------------------------------------------------------------------------------------------
// the document
// ---------------------------------------------------------------------------------------------

/// The whole page: head, `<body>` with the signal declarations, and `#app` holding the page itself.
///
/// Server-rendered from current session state -- no client-side bootstrap, no hydration, so view-source
/// is the state of the quiz and a reload resumes it exactly.
///
/// `data-theme` goes on the ROOT, not on `<body>`, and that is not a preference: the canvas and the
/// scrollbars take `color-scheme` from the root and nowhere else, and Pico and Bulma both document
/// `data-theme` on `<html>`, so putting it there switches the frameworks' own dark themes for free. It
/// is ABSENT -- not 'auto', not '' -- when the OS should decide, which is what leaves
/// `color-scheme: light dark` in charge. It is rendered TWICE over: once statically from the cookie,
/// which is what makes the first paint right, and once as `data-attr`, which keeps it right after a
/// click.
let shell (page: PageData) (initialSignals: string) (theme: string) : Oxpecker.ViewEngine.Tags.html =
    let cssSwap =
        "$_css ? ($_css === 'hand' ? '"
        + page.Prefix
        + "/static/app.css' : '"
        + page.Prefix
        + "/static/app-' + $_css + '.css') : '"
        + page.CssHref
        + "'"

    let init =
        if page.StreamTimer then
            "$_navOpen = false; " + get' page "/timer"
        else
            "$_navOpen = false"

    let root =
        html()
            .attr("lang", "en")
            .attr ("data-attr:data-theme", "$_theme && $_theme !== 'auto' ? $_theme : false")

    let rooted =
        if theme = "auto" then
            root
        else
            root.attr ("data-theme", theme)

    rooted {
        head () {
            meta().attr ("charset", "utf-8")

            title () { page.VariantTitle }

            meta().attr("name", "viewport").attr ("content", "width=device-width, initial-scale=1.0")

            // THE CSS A/B/C: `$_css` swaps the whole stylesheet with no reload and no server
            // involvement. The href is BUILT from the signal rather than a chain of ternaries, which
            // makes the file naming the contract: `hand` is `app.css` and anything else is
            // `app-<signal>.css`. The empty branch is not defensive noise -- this element is in
            // <head>, so it is processed BEFORE `data-signals` on <body> has declared anything, and an
            // undefined signal reads as '', which built `/static/app-.css` and fetched a 404 on every
            // single page load.
            link().attr("rel", "stylesheet").attr("data-attr:href", cssSwap).attr ("href", page.CssHref)

            // The game-feel layer, loaded AFTER the base sheet: every rule in it is scoped to
            // `body.juice`, so it is inert until the Appearance toggle turns it on. One file rather
            // than three copies is the whole reason it is separate -- the experiment can be deleted by
            // deleting a file and one signal.
            link().attr("rel", "stylesheet").attr ("href", page.Prefix + "/static/juice.css")

            // inline, so a bare deployment does not 404 looking for one
            link()
                .attr("rel", "icon")
                .attr (
                    "href",
                    "data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><text y='13' font-size='13'>&#9824;</text></svg>"
                )

            // vendored, not the CDN: works offline and pins the version we tested against
            script().attr("type", "module").attr ("src", page.Prefix + "/static/datastar.js") { () }
        }

        // `data-init` runs once on load. The drawer starts CLOSED at every width: what is left in it is
        // difficulty, the filter, topics, ladder mode, the target, Restart and Appearance, every one of
        // which restarts the quiz or is a one-off preference.
        //
        // `juice` on the <body>, not inside `#app`: it must survive every morph, and every rule in
        // `juice.css` hangs off it.
        body()
            .attr("data-signals", initialSignals)
            .attr("data-attr:data-font", "$_font")
            .attr("data-class", "{juice: $_juice}")
            .attr ("data-init", init) {
            // The morph target. Its contents are `app`, CALLED rather than duplicated: this and the fat
            // patch must render the same markup, and when they were two copies they drifted within the
            // hour.
            div (id = "app") { app page }

            // OUTSIDE `#app`, and that is the whole design. The morph target is rewritten on every
            // interaction; an <audio> element inside it would be replaced mid-playback, and the browser
            // would re-fetch each file every time. Out here they are loaded once per page and survive
            // everything.
            //
            // `data-attr:src` rather than a static `src`: with sound off (the default) these elements
            // have no source, so a player who never turns it on never requests a WAV. `?v=` is the
            // build stamp, so a changed synth reaches a browser that has the old file cached.
            for name in sfxNames do
                audio(id = "sfx-" + name)
                    .attr("preload", "auto")
                    .attr (
                        "data-attr:src",
                        "$_sound ? '"
                        + page.Prefix
                        + "/sfx/"
                        + name
                        + "?v="
                        + page.BuildStamp
                        + "' : false"
                    )

            // The sink the beats are appended to. Cleared at the start of every answer stream, so it
            // holds at most the handful of markers one answer produced.
            div(id = "sfx").attr("hidden", "").attr ("aria-hidden", "true") { () }
        }
    }

// ---------------------------------------------------------------------------------------------
// rendering
// ---------------------------------------------------------------------------------------------

/// ONE POST-PROCESSING PASS, AND IT IS NOT COSMETIC.
///
/// The view engine escapes `'` to `&#39;` in attribute values. That is correct HTML and a browser
/// decodes it before datastar ever sees it -- but every datastar expression in this app is full of
/// single quotes (`@post('/answer/7/0?squad')`), and the OTHER FOUR PORTS all emit them literally
/// (jinja, Askama and Odin's writers leave `'` alone inside a double-quoted attribute). Two things
/// depend on that:
///
///  * The shared load harness reads the page with regexes written against literal quotes
///    (`@post\('([^']*?)/...`), and it is declared unchanged across ports. With `&#39;` it read the
///    variant query as `?squad&#39;)` and could not find the reveal's Next action at all.
///  * The wire-size column is only comparable if the markup is.
///
/// The Go port hit the same class of problem from the other side -- `html/template` treats `data-on:*`
/// as JavaScript and rewrote `/` as `\/` -- and solved it by splicing the prefix into the template
/// source. This is that fix, one layer up: a single pass over the rendered string. `"` never needs the
/// same treatment, because no attribute value here contains one.
let private literalApostrophes (html: string) : string = html.Replace("&#39;", "'")

/// Renders one element to markup the harness and the other ports can read.
let toHtml (element: HtmlElement) : string =
    literalApostrophes (Render.toString element)

/// One `#app` fragment, for a fat-morph patch.
let renderApp (page: PageData) : string = toHtml (app page)

/// The whole document, `<!DOCTYPE html>` and all.
let renderShell (page: PageData) (initialSignals: string) (theme: string) : string =
    literalApostrophes (Render.toHtmlDocString (shell page initialSignals theme))
