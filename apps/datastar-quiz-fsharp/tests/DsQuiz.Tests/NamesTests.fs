/// The datastar name transform, against `testdata/topic_names.json` -- the same goldens the python,
/// the Go port, the Rust port and the load harness all check, because a wrong answer here binds a
/// different signal and nothing anywhere reports an error.
module DsQuiz.Tests.NamesTests

open System
open System.IO
open System.Text.Json

open Expecto
open DsQuiz
open DsQuiz.Render.Names

let private goldensPath: string =
    Path.Combine(AppContext.BaseDirectory, "testdata", "topic_names.json")

let private readGoldens () : (string * string * string) array =
    use document = JsonDocument.Parse(File.ReadAllText goldensPath)

    [| for topic in document.RootElement.EnumerateObject() ->
           topic.Name, topic.Value.GetProperty("slug").GetString(), topic.Value.GetProperty("key").GetString() |]

let tests: Test =
    testList
        "names"
        [ test "the kebab transform splits letter/digit boundaries as datastar's does" {
              Expect.equal (datastarKebab "filterText") "filter-text" "camelCase"
              Expect.equal (datastarKebab "1c_opening") "1-c-opening" "digit then letter, and the underscore"
              Expect.equal (datastarKebab "ladderMode") "ladder-mode" "camelCase"
              Expect.equal (datastarKebab "targetPct") "target-pct" "camelCase"
              Expect.equal (datastarKebab "2NT opening") "2-nt-opening" "a space and a digit boundary"
          }

          test "the camel transform is what the attribute writes into the signal store" {
              Expect.equal (datastarCamel "filter-text") "filterText" "round trip"
              Expect.equal (datastarCamel "1c_opening") "1COpening" "the case that surprises everyone"
              Expect.equal (datastarCamel "filterText") "filterText" "already camel"
          }

          test "a topic slug drops punctuation and never comes back empty" {
              Expect.equal (topicSlug "Responses to 1C") "responses-to-1-c" "spaces and a digit boundary"
              Expect.equal (topicSlug "1NT opening") "1-nt-opening" "notrump"
              Expect.equal (topicSlug "!!!") "topic" "punctuation only still yields a usable slug"
          }

          testList
              "topic name goldens"
              [ for name, slug, key in readGoldens () ->
                    test name {
                        Expect.equal (topicSlug name) slug "slug"
                        Expect.equal (topicSignalKey name) key "signal key"
                    } ]

          test "the picker rows are built once per variant and carry the whole bind attribute" {
              match Corpus.load () with
              | Error reason -> failtest reason
              | Ok corpus ->
                  let system = Corpus.Corpus.defaultSystem corpus
                  let first = topicChoices system
                  let second = topicChoices system

                  Expect.isTrue (obj.ReferenceEquals(first, second)) "cached per variant, not per render"
                  Expect.isGreaterThan first.Length 0 "the default variant has topics"

                  for choice in first do
                      Expect.equal choice.Bind ("data-bind:topics." + choice.Slug) "the whole attribute"
                      Expect.equal choice.Key (topicSignalKey choice.Name) "the signal key"
          } ]
