/// The signal payloads.
///
/// Written straight into a `StringBuilder` rather than through a dictionary and a serialiser. The keys
/// are fixed and the values are numbers, booleans and two strings, so the JSON is a handful of appends
/// -- and the server-owned set goes out with EVERY view patch, which is the hottest thing this app
/// does after rendering. It also keeps `System.Text.Json`'s reflection-based writer off the hot path,
/// which is what keeps the Native AOT column open.
///
/// THERE IS NO WRITER OBJECT AND NO "IS THIS THE FIRST KEY" FLAG: the object always opens with `{`, so
/// `out.Length > 1` already answers that question. The whole module is functions over a builder.
///
/// KEYS ARE EMITTED IN SORTED ORDER, because that is what Go's `json.Marshal` does with a map and it
/// is the port this one diffs against. Worth knowing: the RUST port's writer is not sorted throughout
/// -- its bound-signal payload emits `filterText` after the four settings keys, where sorted order
/// puts it second -- so the Go and Rust payloads already differ in key order and only the values can
/// be compared between those two. Sorting here costs nothing (the order is written out, not computed)
/// and makes at least two of the three agree byte for byte.
module DsQuiz.Render.Signals

open System
open System.Collections.Generic
open System.Text

open DsQuiz.Engine
open DsQuiz.Render.Names
open DsQuiz.Session

/// Opens the object. Every `key` below adds its own comma when it is not the first.
let start (capacity: int) : System.Text.StringBuilder =
    let out = StringBuilder capacity
    out.Append '{' |> ignore
    out

let finish (out: StringBuilder) : string =
    out.Append '}' |> ignore
    out.ToString()

let private key (name: string) (out: StringBuilder) : System.Text.StringBuilder =
    if out.Length > 1 then
        out.Append ',' |> ignore

    out.Append('"').Append(name).Append("\":")

/// JSON string escaping, per RFC 8259.
let private jsonString (value: string) (out: StringBuilder) : System.Text.StringBuilder =
    out.Append '"' |> ignore

    for ch in value do
        match ch with
        | '"' -> out.Append "\\\"" |> ignore
        | '\\' -> out.Append "\\\\" |> ignore
        | '\n' -> out.Append "\\n" |> ignore
        | '\r' -> out.Append "\\r" |> ignore
        | '\t' -> out.Append "\\t" |> ignore
        | c when c < ' ' -> out.Append("\\u").Append((int c).ToString "x4") |> ignore
        | c -> out.Append c |> ignore

    out.Append '"'

let number (name: string) (value: int) (out: StringBuilder) : System.Text.StringBuilder =
    (key name out).Append value

let boolean (name: string) (value: bool) (out: StringBuilder) : System.Text.StringBuilder =
    (key name out).Append(if value then "true" else "false")

let string' (name: string) (value: string) (out: StringBuilder) : System.Text.StringBuilder =
    jsonString value (key name out)

/// A nested object of booleans -- the topic ticks.
let flags
    (name: string)
    (entries: KeyValuePair<string, bool> array)
    (out: StringBuilder)
    : System.Text.StringBuilder =
    (key name out).Append '{' |> ignore

    for i in 0 .. entries.Length - 1 do
        if i > 0 then
            out.Append ',' |> ignore

        (jsonString entries[i].Key out).Append(':').Append(if entries[i].Value then "true" else "false")
        |> ignore

    out.Append '}'

/// The gauge's fill, capped at 100.
let pointsPercent (points: int) (goal: int) : int =
    if goal <= 0 then
        0
    else
        min (pyRound (float points / float goal * 100.0)) 100

/// Every signal the server owns.
///
/// Local (`_`-prefixed) so they are never uploaded back. `_timeLeftPct` and `_questionMs` drive the
/// timer bar: the server states the allowance and resets the bar per question, and the browser's 100ms
/// interval walks it down. No clock is shared, because the bar is cosmetic -- the bonus that actually
/// scores is recomputed server-side when the answer arrives.
let serverSignals (state: State) (out: StringBuilder) : System.Text.StringBuilder =
    let playing = State.stillPlaying state
    let timeLeft = if playing then State.percentTimeLeft state else 0

    out
    |> number "_attempted" state.Score.QuestionsAttempted
    |> number "_correct" state.Score.QuestionsCorrect
    |> boolean "_playing" playing
    |> number "_points" state.Score.TotalPoints
    |> number "_pointsPct" (pointsPercent state.Score.TotalPoints state.PointsGoal)
    |> number "_questionMs" (pyRound (state.QuestionSeconds * 1000.0))
    |> number "_scorePct" (Score.percentage state.Score)
    |> number "_skipsLeft" state.SkipsLeft
    |> number "_streak" state.Score.Streak
    // Whether the countdown should be running at all. `_playing` is not the same question: a scored
    // answer parks on the reveal with the quiz very much still in play, and the bar kept draining
    // there -- time pressure on a question that had already been answered.
    |> boolean "_ticking" (State.onTheClock state)
    |> number "_timeLeftPct" timeLeft

/// The *effective* settings, to be echoed back after the server has adopted them.
///
/// The browser originates these, but the server clamps them, so after adopting a value the two can
/// disagree -- send `difficulty: 99` and the server uses 8 while the slider still reads 99 until the
/// next page load.
///
/// Note what is deliberately NOT here: `filterText` and the `topics` ticks. Those are drafts the user
/// may be in the middle of editing, and re-stating them on an unrelated patch (a Skip, say) would wipe
/// what they were typing.
let settingsSignals (state: State) (out: StringBuilder) : System.Text.StringBuilder =
    out
    |> number "difficulty" state.Settings.Difficulty
    |> boolean "ladderMode" state.Settings.LadderMode
    |> boolean "targetOn" state.Settings.TargetOn
    |> number "targetPct" state.Settings.TargetPct

/// The signals the *browser* owns: form inputs bound with `data-bind`.
///
/// These have no underscore, so datastar uploads them with every request -- that is how the server
/// learns the slider moved. `topics` is seeded from the filter in force, so the picker's ticks agree
/// with it even when the filter was typed rather than picked.
let boundSignals
    (state: State)
    (choices: TopicChoice array)
    (activeTopics: string array)
    (out: StringBuilder)
    : System.Text.StringBuilder =
    let ticked = HashSet<string>(StringComparer.Ordinal)

    for name in activeTopics do
        ticked.Add(topicSignalKey name) |> ignore

    let ticks =
        choices
        |> Array.map (fun choice -> KeyValuePair(choice.Key, ticked.Contains choice.Key))

    // sorted: difficulty, filterText, ladderMode, targetOn, targetPct, topics
    out
    |> number "difficulty" state.Settings.Difficulty
    |> string' "filterText" state.FilterText
    |> boolean "ladderMode" state.Settings.LadderMode
    |> boolean "targetOn" state.Settings.TargetOn
    |> number "targetPct" state.Settings.TargetPct
    |> flags "topics" ticks

/// The default stylesheet the `_css` experiment starts on.
[<Literal>]
let DefaultCSS = "hand"

/// View-local signals the server never sets, declared so they exist from the first paint.
///
/// THEY MUST BE DECLARED: an undefined signal reads as `''` in an expression, and `data-attr` treats
/// `''` as "set the attribute", so an undeclared `$_topicsOpen` leaves `<dialog open>` -- the picker is
/// stuck open. Declared in the `data-signals` OBJECT rather than as `data-signals:_topics-open`,
/// because attribute keys are kebab-then-camel converted, which eats a leading underscore -- and the
/// underscore is what keeps these out of every request.
let localUISignals (theme: string) (out: StringBuilder) : System.Text.StringBuilder =
    out
    |> boolean "_answering" false
    |> string' "_css" DefaultCSS
    |> string' "_font" "notes"
    // The "game feel" experiment: hit-stop and shake on the reveal, floating points on the card you
    // picked, and an escalating streak chip. Purely presentational, so purely local -- the server
    // streams the floaters either way and `body.juice` decides whether they are visible.
    |> boolean "_juice" true
    // closed at every width now that the drawer holds only settings
    |> boolean "_navOpen" false
    // Sound, OFF by default and the only appearance preference that is. Everything else here changes
    // how the page looks to the person who asked for it; audio arrives in a room, and a quiz played in
    // a lesson or on a train should make no noise until someone says so. It also gates the FETCH: the
    // <audio> elements have no `src` until this is true.
    |> boolean "_sound" false
    // `auto` | `light` | `dark`, remembered across reloads in the theme cookie and seeded from it
    // here, so the signal and the server-rendered attribute agree from the first frame.
    |> string' "_theme" theme
    |> boolean "_topicsOpen" false

/// The whole `data-signals` object for a first paint: everything the server owns, the effective
/// settings, the bound drafts and the view-local flags.
let initialSignals
    (state: State)
    (choices: TopicChoice array)
    (activeTopics: string array)
    (theme: string)
    : string =
    start 900
    |> serverSignals state
    |> boundSignals state choices activeTopics
    |> localUISignals theme
    |> finish

/// The signal patch that accompanies a view patch: server-owned plus effective settings, and
/// deliberately not the drafts.
let viewSignals (state: State) : string =
    start 420 |> serverSignals state |> settingsSignals state |> finish
