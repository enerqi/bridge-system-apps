/// THE PARITY TEST: the same 132 probes the Go and Rust ports run, recorded from the PYTHON
/// implementation by `apps/datastar-quiz/tools/export_filter_goldens.py`.
///
/// `BidsTests` covers the call model case by case; this covers the other half -- that the ported
/// matcher selects the SAME auctions out of the real corpus as the reference does. The digest is a
/// sha256 over the matching indices, so a single auction moving in or out fails the test.
module DsQuiz.Tests.CorpusTests

open System
open System.IO
open System.Security.Cryptography
open System.Text
open System.Text.Json

open Expecto
open DsQuiz
open DsQuiz.Corpus

/// One probe recorded from the python.
type private Golden =
    { Text: string
      MinHits: int
      Status: string
      Hits: int
      Digest: string
      Canonical: string
      Errors: string array
      TopicNames: string array }

let private goldensPath: string =
    Path.Combine(AppContext.BaseDirectory, "testdata", "filter_goldens.json")

let private strings (element: JsonElement) : string array =
    element.EnumerateArray()
    |> Seq.map (fun item -> item.GetString())
    |> Array.ofSeq

let private readGoldens () : (string * Golden) array =
    use document = JsonDocument.Parse(File.ReadAllText goldensPath)

    [| for variant in document.RootElement.EnumerateObject() do
           for probe in variant.Value.EnumerateArray() do
               variant.Name,
               { Text = probe.GetProperty("text").GetString()
                 MinHits = probe.GetProperty("min_hits").GetInt32()
                 Status = probe.GetProperty("status").GetString()
                 Hits = probe.GetProperty("hits").GetInt32()
                 Digest = probe.GetProperty("digest").GetString()
                 Canonical = probe.GetProperty("canonical").GetString()
                 Errors = strings (probe.GetProperty "errors")
                 TopicNames = strings (probe.GetProperty "topic_names") } |]

/// The python's `sha256(",".join(str(i) for i in indices))`. Storing hits as INDICES rather than as
/// auctions is what makes this a direct read.
let private digestOf (indices: int array) : string =
    Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(String.Join(",", indices))))

/// Loaded once for the whole list: the corpus is 1.2 MB of JSON and ~9,300 auctions to prepare, and
/// every probe reads the same thing.
let private loaded =
    lazy
        (match Corpus.load () with
         | Ok corpus -> corpus
         | Error reason -> failwith reason)

let private systemFor (key: string) : Corpus.System =
    match Corpus.tryGet key loaded.Value with
    | ValueSome system -> system
    | ValueNone -> failtestf "variant %s did not load" key

let tests: Test =
    testList
        "corpus"
        [ test "both variants load, with the auction counts the export recorded" {
              let squad = systemFor "squad"
              let swedish = systemFor "swedish"

              Expect.isGreaterThan squad.Auctions.Length 1000 "squad auctions"
              Expect.isGreaterThan swedish.Auctions.Length 5000 "swedish auctions"
              Expect.equal squad.Variant.Key "squad" "squad key"
              Expect.equal swedish.Variant.Key "swedish" "swedish key"
              Expect.isGreaterThan (BidFilter.Topics.TopicSet.count squad.Topics) 0 "squad topics"
          }

          test "a bare URL means squad, and an unrelated query keeps the session's variant" {
              let corpus = loaded.Value
              Expect.equal (Corpus.defaultSystem corpus).Variant.Key "squad" "the default"
              Expect.isTrue (Corpus.requestedVariant "" corpus).IsNone "no query names no variant"
              Expect.isTrue (Corpus.requestedVariant "debug" corpus).IsNone "?debug names no variant"

              match Corpus.requestedVariant "swedish" corpus with
              | ValueSome system -> Expect.equal system.Variant.Key "swedish" "?swedish"
              | ValueNone -> failtest "?swedish should name a variant"

              match Corpus.variantSwitchForQuery "" corpus with
              | ValueSome system -> Expect.equal system.Variant.Key "squad" "a bare URL means take me home"
              | ValueNone -> failtest "a bare URL should switch to the default"

              Expect.isTrue (Corpus.variantSwitchForQuery "debug" corpus).IsNone "?debug keeps the variant"
          }

          // Reference equality rather than the hit/miss counters: the goldens below run in parallel
          // against the same two systems, so the counters are shared state and a count assertion here
          // would be testing the scheduler. Getting the SAME array back proves the second call did not
          // recompute.
          // SEQUENCED, and reference equality rather than the hit/miss counters. Both halves are about
          // the same problem: the goldens below run in PARALLEL against these two shared systems, so the
          // counters are shared state, and 264 golden probes can evict this test's own entry from a
          // 256-entry LRU between its two calls -- which failed the run about one time in ten. Running
          // it outside the parallel pool makes it deterministic.
          testSequenced
          <| test "the filter memo answers the second identical question from cache" {
              let squad = systemFor "squad"
              let first = System.checkFilter "1C" 8 squad
              let second = System.checkFilter "1C  " 8 squad

              Expect.isTrue
                  (obj.ReferenceEquals(first.Hits, second.Hits))
                  "normalisation makes `1C  ` the same key, so the answer is the cached one"

              Expect.equal (FilterCache.info squad.Cache).MaxSize FilterCacheSize "memo size"
          }

          testSequenced
          <| test "an unfiltered check shares one index array rather than allocating per request" {
              let squad = systemFor "squad"
              let check = System.checkFilter "" 8 squad
              Expect.equal check.Status FilterAll "no patterns means everything"
              Expect.isTrue (obj.ReferenceEquals(check.Hits, squad.AllIndices)) "the shared array"
          }

          testList
              "filter goldens"
              [ for probeIndex, (variantKey, golden) in readGoldens () |> Array.indexed ->
                    // the probe text is in the name so a failure says which filter broke; the index
                    // keeps the names unique, because the recorded probes are not (swedish asks
                    // `1D 1M` at min 8 twice, once via each spelling that normalises to it)
                    let shown = if golden.Text = "" then "<empty>" else golden.Text
                    let label = $"[{probeIndex}] {variantKey}: {shown} (min {golden.MinHits})"

                    test label {
                        let system = systemFor variantKey
                        let check = System.checkFilter golden.Text golden.MinHits system

                        Expect.equal (statusText check.Status) golden.Status "status"
                        Expect.equal check.Hits.Length golden.Hits "how many auctions matched"
                        Expect.equal (digestOf check.Hits) golden.Digest "WHICH auctions matched"
                        Expect.equal check.Parsed.CanonicalText golden.Canonical "canonical text"
                        Expect.equal check.Parsed.Errors golden.Errors "errors"
                        Expect.equal check.Parsed.TopicNames golden.TopicNames "topic names"
                    } ] ]
