/// The views, rendered once and read back.
///
/// These are not snapshot tests -- the DSL's whitespace is its own and there is nothing to compare it
/// against byte for byte. They check the things that FAIL SILENTLY in this app: an attribute whose name
/// the engine mangled, a datastar expression the escaper broke, a signal name that lost its underscore,
/// a `data-bind` that ended up naming a different signal than the server seeds.
module DsQuiz.Tests.ViewsTests

open Expecto
open Oxpecker
open DsQuiz
// NOT `open Oxpecker.ViewEngine`: this project has its own `Render` namespace, and opening both would
// leave `Render.toString` ambiguous. `ViewEngine.Render.toString` says which one is meant.
open DsQuiz.Render

let private page: Page.PageData =
    { VariantTitle = "Squad System"
      SystemNotesURL = "https://example.invalid/notes"
      Settings =
        { Difficulty = 6
          LadderMode = true
          TargetOn = false
          TargetPct = 80 }
      Playing = true
      QuizBody = "<h2 class=\"intro\">the question</h2>"
      MinDifficulty = Engine.MinDifficulty
      MaxDifficulty = Engine.MaxDifficulty
      MilestoneTicks = Page.milestoneTicks
      PointsGoal = 1000
      Debug = true
      Qid = 42L
      StreamTimer = false
      BuildStamp = "abcd1234"
      CssHref = "/static/app.css"
      CookiePath = "/"
      Topics =
        [| { Name = "1C opening"
             Slug = "1-c-opening"
             Key = "1COpening"
             Description = "the strong club"
             Bind = "data-bind:topics.1-c-opening" } |]
      TopicsHaveDescriptions = true
      FilterText = "1D-1M"
      FilterStatus = "<div class=\"filter-line\">67 auctions match</div>"
      Prefix = ""
      VariantQuery = "?squad" }

let private document: string = Views.renderShell page "{\"_points\":0}" "dark"
let private fragment: string = Views.renderApp page

let tests: Test =
    testList
        "views"
        [ test "the document is a document" {
              Expect.stringStarts document "<!DOCTYPE html>" "doctype"
              Expect.stringContains document "<html lang=\"en\"" "root element"
              Expect.stringContains document "id=\"app\"" "the morph target"
              Expect.stringContains document "Squad System" "the title"
          }

          test "the theme is rendered twice over -- statically and as a signal binding" {
              Expect.stringContains document "data-theme=\"dark\"" "the static attribute for the first paint"
              Expect.stringContains document "data-attr:data-theme=" "and the binding that keeps it right"
          }

          test "the signal declarations and data-init live on body, outside the morph target" {
              Expect.stringContains document "data-signals=" "declared"
              Expect.stringContains document "data-init=" "init"
              // both must be OUTSIDE #app, or a morph re-creates them and the held timer connection leaks
              let appAt = document.IndexOf "id=\"app\""
              let signalsAt = document.IndexOf "data-signals="
              Expect.isLessThan signalsAt appAt "data-signals is before #app"
              Expect.isFalse (fragment.Contains "data-signals=") "the fat patch does not carry them"
              Expect.isFalse (fragment.Contains "data-init=\"$_navOpen") "nor data-init"
          }

          test "the sound elements are outside the morph target and carry the build stamp" {
              Expect.stringContains document "id=\"sfx-correct\"" "the audio elements"
              Expect.stringContains document "abcd1234" "the build stamp on their src"
              Expect.isFalse (fragment.Contains "id=\"sfx-correct\"") "not in the fat patch"
          }

          test "the underscore survives on every local signal name" {
              // the whole point of the underscore is that datastar never uploads these, and the one way
              // to lose it is to write the attribute in the KEY form
              for name in
                  [ "$_answering"
                    "$_topicsOpen"
                    "$_navOpen"
                    "$_streak"
                    "$_timeLeftPct" ] do
                  Expect.stringContains fragment name name

              Expect.stringContains fragment "data-bind=\"_juice\"" "the value form for the juice toggle"
              Expect.stringContains fragment "data-bind=\"_sound\"" "and for sound"
          }

          test "the topic binding is the whole attribute, slug and all" {
              Expect.stringContains fragment "data-bind:topics.1-c-opening" "the precomputed bind attribute"
              Expect.stringContains fragment "1C opening" "the label"
          }

          test "the datastar expressions survive escaping" {
              // The engine escapes attribute values, so the question is whether an expression still READS
              // as itself: `&&` may arrive as `&amp;&amp;` and `'` as `&#39;`, both of which a browser
              // decodes back before datastar ever sees them. What must NOT happen is the expression being
              // truncated or the quotes being dropped.
              Expect.stringContains fragment "@post(" "the action is still an action"
              Expect.stringContains fragment "?squad" "the variant query rides on every action"
              Expect.stringContains fragment "matchMedia(" "the overlay-width check"
              Expect.stringContains fragment "Math.min($_streak, 8)" "the streak scale expression"
          }

          test "the server-rendered form values are present, so the first paint is not the midpoint" {
              Expect.stringContains fragment "value=\"6\"" "the difficulty the session actually has"
              Expect.stringContains fragment "value=\"80\"" "the target percentage"
              Expect.stringContains fragment "checked" "ladder mode is on, so its box is checked"
              Expect.stringContains fragment "value=\"1D-1M\"" "the filter text in force"
          }

          test "the quiz body and the filter status are inserted as markup, not as text" {
              Expect.stringContains fragment "<h2 class=\"intro\">the question</h2>" "the quiz body"
              Expect.stringContains fragment "67 auctions match" "the filter status"
              Expect.isFalse (fragment.Contains "&lt;h2") "the body was not escaped a second time"
          }

          test "the debug panel appears only when the session is armed" {
              Expect.stringContains fragment "id=\"debug\"" "armed here"
              let quiet = Views.renderApp { page with Debug = false }
              Expect.isFalse (quiet.Contains "id=\"debug\"") "and gone when it is not"
              Expect.isFalse (quiet.Contains "Base CSS") "the stylesheet A/B/C is debug-only too"
          }

          test "the client timer carries its interval, and the stream timer does not" {
              Expect.stringContains fragment "data-on-interval__duration.100ms" "the client interval"
              let streamed = Views.renderApp { page with StreamTimer = true }
              Expect.isFalse (streamed.Contains "data-on-interval") "stream mode has no interval"
          }

          test "the score dial renders as real svg" {
              Expect.stringContains fragment "<svg" "the dial"
              // CLOSED paths: inside <svg> the parser is in foreign content, where an unclosed <path>
              // swallows its siblings and the <text> disappears into it
              Expect.stringContains fragment "</path>" "its two paths, closed"
              Expect.stringContains fragment "<text" "and the percentage label"
              Expect.stringContains fragment "282.74" "the full sweep"
          }

          test "the question fragment anchors the answer to the qid" {
              let rendered =
                  ViewEngine.Render.toString (Views.question page "the intro" "1♠" [| "1C"; "1D"; "1H" |])

              Expect.stringContains rendered "/answer/42/0" "first candidate"
              Expect.stringContains rendered "/answer/42/2" "last candidate"
              // `&lt;=`, not `<=`: the engine escapes attribute values, and a browser decodes it back
              // before datastar ever parses the expression
              Expect.stringContains rendered "Number(evt.key) &lt;= 3" "the digit accelerator knows the count"
              Expect.stringContains rendered "closest?.(" "and still excludes controls that want the key"
              Expect.stringContains rendered "<kbd" "each button shows its digit"
              // the value form, not `data-indicator:_answering`, which would lose the underscore
              Expect.stringContains rendered "data-indicator=\"_answering\"" "the in-flight indicator"
          }

          test "the reveal marks the right answer and the one that was taken" {
              let rendered =
                  ViewEngine.Render.toString (Views.reveal page "the intro" "1♠" [| "1C"; "1D"; "1H" |] 2 0)

              Expect.stringContains rendered "candidate revealed correct" "the right answer"
              Expect.stringContains rendered "candidate revealed wrong" "the one taken"
              Expect.stringContains rendered "&#10003;" "a tick"
              Expect.stringContains rendered "&#10007;" "and a cross"
              Expect.stringContains rendered "/next" "and the way onward"
          }

          test "the finale spans every digit separately" {
              let rendered =
                  ViewEngine.Render.toString (Views.completed page "42.5" 1000 9 10 90 1000)

              Expect.stringContains rendered "class=\"figure big\"" "the points figure"
              Expect.stringContains rendered "class=\"digit\"" "one span per digit"
              Expect.stringContains rendered "confetti-bit" "the confetti"
              Expect.stringContains rendered "completed.jpeg" "the cat"
          } ]
