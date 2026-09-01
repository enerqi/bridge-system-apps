/// The microbenchmarks the other ports publish, so the numbers line up in RESULTS.md:
///
///   | | python | go | rust | odin |
///   |---|---|---|---|---|
///   | boot: parse + prepare both corpora | ~5.5 s | ~70 ms | 21.3 ms | 48-62 ms |
///   | `checkFilter "1C"` over 7,627 auctions | 15.8 ms | 380 µs | 96.5 µs | (no harness) |
///   | memo hit | | 15 µs | 154 ns | |
///   | `scorePoints` | | 0.68 µs | 381 ns | |
///
/// BenchmarkDotNet rather than the hand-rolled timer the Rust port uses, for one reason worth the
/// dependency: it reports ALLOCATIONS PER OPERATION. That is the column Go's and Rust's harnesses
/// cannot show and the one this comparison keeps asking about -- ".NET is fast, the cost is garbage".
///
/// `engine`, `bidfilter` and `corpus` are free of ASP.NET precisely so this can run with no server in
/// the way.
module DsQuiz.Bench.Benchmarks

open BenchmarkDotNet.Attributes
open BenchmarkDotNet.Running

open DsQuiz
open DsQuiz.Engine

[<MemoryDiagnoser>]
type FilterBenchmarks() =
    let mutable corpus = Unchecked.defaultof<Corpus.Corpus>
    let mutable squad = Unchecked.defaultof<Corpus.System>
    let mutable swedish = Unchecked.defaultof<Corpus.System>

    [<GlobalSetup>]
    member _.Setup() : unit =
        corpus <-
            match Corpus.load () with
            | Ok loaded -> loaded
            | Error reason -> failwith reason

        squad <- Corpus.Corpus.defaultSystem corpus

        swedish <-
            match Corpus.Corpus.tryGet "swedish" corpus with
            | ValueSome system -> system
            | ValueNone -> failwith "swedish"

    /// The headline: one pattern against the bigger system's 7,627 auctions, memo cleared each time.
    [<Benchmark(Description = "checkFilter 1C, cold (swedish, 7627 auctions)")>]
    member _.CheckFilterCold() : int =
        Corpus.FilterCache.clear swedish.Cache
        (Corpus.System.checkFilter "1C" MaxDifficulty swedish).Hits.Length

    /// The same question asked twice, which is what a typist does -- and what the memo is for.
    [<Benchmark(Description = "checkFilter 1C, memo hit")>]
    member _.CheckFilterWarm() : int =
        (Corpus.System.checkFilter "1C" MaxDifficulty swedish).Hits.Length

    /// A topic is several patterns OR-ed, so it is the expensive end of the same routine.
    [<Benchmark(Description = "checkFilter a topic name, cold")>]
    member _.CheckTopicCold() : int =
        Corpus.FilterCache.clear squad.Cache
        (Corpus.System.checkFilter squad.Topics.List[0].Name MaxDifficulty squad).Hits.Length

[<MemoryDiagnoser>]
type EngineBenchmarks() =
    let question =
        { Candidates =
            [| "1C (Pass) 1H --> 2D"
               "1D --> 1S"
               "1N --> 2C"
               "2H"
               "3N" |]
          Answer = "the description"
          AnswerCandidate = "1C (Pass) 1H --> 2D"
          ChoiceType = Auctions }

    let mutable system = Unchecked.defaultof<Corpus.System>

    [<GlobalSetup>]
    member _.Setup() : unit =
        system <-
            match Corpus.load () with
            | Ok loaded -> Corpus.Corpus.defaultSystem loaded
            | Error reason -> failwith reason

    [<Benchmark(Description = "scorePoints")>]
    member _.ScorePoints() : int = (scorePoints question 5 62).Total

    [<Benchmark(Description = "newQuestion (difficulty 5)")>]
    member _.NewQuestion() : int =
        (newQuestion system.Auctions system.AllIndices 5).Candidates.Length

    [<Benchmark(Description = "answer, correct")>]
    member _.Answer() : int =
        let scored =
            answer
                Score.start
                { Question = question
                  Candidate = question.AnswerCandidate
                  PercentLeft = 62
                  LadderMode = true
                  TargetOn = false
                  TargetPct = 70
                  LastCorrectPoints = 0
                  PointsGoal = PointsGoal }

        scored.Outcome.Toasts.Length

/// Rendering, which is the other half of what a request spends its time on.
[<MemoryDiagnoser>]
type RenderBenchmarks() =
    let config: Render.Page.Config =
        { Prefix = ""; StreamTimer = false; FatMorph = true }

    let mutable state = Unchecked.defaultof<Session.State>

    [<GlobalSetup>]
    member _.Setup() : unit =
        let system =
            match Corpus.load () with
            | Ok loaded -> Corpus.Corpus.defaultSystem loaded
            | Error reason -> failwith reason

        state <- Session.State.create system

    /// The fat morph: what every interaction sends.
    [<Benchmark(Description = "appBody (the fat morph)")>]
    member _.AppBody() : int =
        (Render.Compose.appBody config state).Length

    /// The `#quiz` fragment on its own, which is what fragment-morph mode sends.
    [<Benchmark(Description = "quizBody (the fragment)")>]
    member _.QuizBody() : int =
        (Render.Compose.quizBody config state).Length

    /// The whole document, once per page load.
    [<Benchmark(Description = "shell (the whole document)")>]
    member _.Shell() : int =
        (Render.Compose.shell config state "auto").Length

    /// The signal payload that rides along with every view patch.
    [<Benchmark(Description = "viewSignals")>]
    member _.ViewSignals() : int =
        (Render.Signals.viewSignals state).Length

/// Loading the corpus is the boot cost the other ports all report, so it is measured the same way --
/// but with `[<IterationCount>]` kept low, because each iteration parses 1.2 MB of JSON and prepares
/// ~9,300 auctions.
[<MemoryDiagnoser; SimpleJob(launchCount = 1, warmupCount = 1, iterationCount = 3)>]
type BootBenchmarks() =

    [<Benchmark(Description = "load both corpora (parse + prepare)")>]
    member _.LoadCorpus() : int =
        match Corpus.load () with
        | Ok corpus -> (Corpus.Corpus.defaultSystem corpus).Auctions.Length
        | Error reason -> failwith reason

    [<Benchmark(Description = "synthesise the five WAVs")>]
    member _.Sfx() : int =
        Sfx.warm ()
        Sfx.totalBytes ()

[<EntryPoint>]
let main (argv: string array) : int =
    BenchmarkSwitcher
        .FromTypes(
            [| typeof<FilterBenchmarks>
               typeof<EngineBenchmarks>
               typeof<RenderBenchmarks>
               typeof<BootBenchmarks> |]
        )
        .Run(argv)
    |> ignore

    0
