/// The F# port of the bidding quiz: same hypermedia architecture, same corpus, same routes, same SSE
/// choreography, driven by the same locust harness (`apps/dsquiz-perf`) as the python, Go, Rust and two
/// Odin ports. What differs is the runtime.
///
/// TWO THINGS THIS PORT ASKS THAT THE OTHERS CANNOT:
///
///  1. The SSE writer is FIRST-PARTY LIBRARY CODE in the app's own language.
///     `StarFederation.Datastar.FSharp` is the core of `starfederation/datastar-dotnet` -- the C# package
///     is a shim over it -- and it writes UTF-8 straight into `IBufferWriter<byte>`. `Web/Frames.fs`
///     records the one place the library could not be used, and why.
///  2. A DEPLOY-TIME CODEGEN AXIS: JIT / ReadyToRun / Native AOT as three columns for startup, resident
///     set, steady-state throughput and binary size.
///
/// `CreateSlimBuilder`, not `CreateBuilder`, from the first commit: it drops HTTPS endpoints, HTTP/3, IIS
/// integration, static web assets and regex route constraints -- none of which this app uses -- and it is
/// what a Native AOT publish requires. Starting on it means P6 is a publish flag rather than a rewrite.
module DsQuiz.Program

open System
open System.Diagnostics
open Microsoft.AspNetCore.Builder
open Microsoft.AspNetCore.Hosting
open Microsoft.Extensions.DependencyInjection
open Microsoft.Extensions.Hosting
open Microsoft.Extensions.Logging
open Oxpecker

open DsQuiz.Web
open DsQuiz.Web.Config

[<EntryPoint>]
let main argv : int =
    let config = parse argv
    let booted = Stopwatch.StartNew()

    // BOTH VARIANTS PARSED AND PREPARED HERE, before the listener opens. There is deliberately no lazy
    // path: a first request that paid for the corpus would poison exactly the percentiles this port
    // exists to report. A corpus this build cannot read is a startup failure.
    match DsQuiz.Corpus.load () with
    | Error reason ->
        Console.Error.WriteLine("quizd: " + reason)
        1
    | Ok corpus ->

        let corpusMs = booted.ElapsedMilliseconds

        // The sounds are synthesised and the assets pre-compressed now, for the same reason: the first player
        // to turn sound on, and the first page load, should not pay for work every later one reuses.
        DsQuiz.Sfx.warm ()
        let sfxMs = booted.ElapsedMilliseconds - corpusMs
        let assets = Assets.load ()
        let struct (assetCount, assetBytes, assetSaved) = Assets.savings assets
        let assetsMs = booted.ElapsedMilliseconds - corpusMs - sfxMs

        let store = Session.Store.start ()

        let state: Handlers.AppState =
            { Config = config
              Renderer =
                { Prefix = config.Prefix; StreamTimer = config.StreamTimer; FatMorph = config.FatMorph }
              Corpus = corpus
              Store = store
              Assets = assets }

        let builder = WebApplication.CreateSlimBuilder(argv)

        // The startup line below is the run's own record; per-request framework logging is not, and at
        // 4,000 req/s it is a measurable cost. Warning keeps genuine faults visible.
        builder.Logging.SetMinimumLevel LogLevel.Warning |> ignore

        builder.WebHost.ConfigureKestrel(fun options ->
            // NO WRITE TIMEOUT. `MinResponseDataRate` IS Kestrel's write timeout (240 bytes/second after a
            // 5-second grace, checked every second) and both of this app's streams sit under it: `/timer` in
            // stream mode holds a connection for up to ten minutes pushing one small patch per 100ms, and the
            // answer choreography spends seconds in deliberate pauses. Killing it here is the equivalent of
            // the Go port's deliberately absent `WriteTimeout`.
            //
            // It has to be server-wide: the per-request `IHttpMinResponseDataRateFeature` is not present for
            // HTTP/2 requests.
            //
            // Debugging trap: this limit, `KeepAliveTimeout` and `RequestHeadersTimeout` are all silently
            // unenforced while a debugger is attached, so a stream that dies under `just serve` looks
            // perfectly healthy under the debugger.
            options.Limits.MinResponseDataRate <- null
            // bounds a client that opens a socket and says nothing; mirrors the Go port's
            // ReadHeaderTimeout / IdleTimeout pair
            options.Limits.RequestHeadersTimeout <- TimeSpan.FromSeconds 10.0
            options.Limits.KeepAliveTimeout <- TimeSpan.FromMinutes 2.0
            // signals arrive as a JSON body on POST; the other ports cap it at 1 MiB
            options.Limits.MaxRequestBodySize <- 1L <<< 20
            // TCP_NODELAY needs no action here: `SocketTransportOptions.NoDelay` defaults to true. The Rust
            // port had to set it by hand (axum does not), and it was worth 10-11ms per interaction -- a real
            // difference between the runtimes, and a line for RESULTS.md.
            options.Listen(Net.IPAddress.Parse config.Addr, config.Port)
        )
        |> ignore

        builder.Services.AddRouting().AddOxpecker() |> ignore

        let host = builder.Build()
        host.UseRouting().UseOxpecker(Server.endpoints state) |> ignore

        // The sweeper runs for the life of the process, dropping sessions nobody has touched in six hours. A
        // `PeriodicTimer` in a background task rather than a `System.Threading.Timer`: no callback allocation
        // per tick, and it stops with the host's own token.
        backgroundTask {
            use ticker = new Threading.PeriodicTimer(Session.SweepPeriod)
            let stopping = host.Lifetime.ApplicationStopping
            let mutable running = true

            while running do
                let! ticked = ticker.WaitForNextTickAsync stopping
                running <- ticked && not stopping.IsCancellationRequested

                if running then
                    Session.Store.sweep store |> ignore
        }
        |> ignore

        let gcMode =
            if Runtime.GCSettings.IsServerGC then
                "server"
            else
                "workstation"

        let datas =
            match AppContext.GetData "System.GC.DynamicAdaptationMode" with
            | null -> "default"
            | value -> string value

        let auctions =
            DsQuiz.Corpus.variantOrder
            |> Array.sumBy (fun key ->
                match DsQuiz.Corpus.Corpus.tryGet key corpus with
                | ValueSome system -> system.Auctions.Length
                | ValueNone -> 0
            )

        // ONE LINE, because a load run has to be reconstructable from its log. `processors` is the core
        // budget: `DOTNET_PROCESSOR_COUNT=1` is what `serve-1core` sets, and it lands on
        // `Environment.ProcessorCount`, Kestrel's IO queue count and the GC heap count together.
        //
        // BUILT BY CONCATENATION, NOT BY `printfn`. F#'s printf reflects over its format specifiers
        // (`MethodInfo.MakeGenericMethod`), which Native AOT cannot do -- this one line was the second
        // thing to kill the AOT binary at startup, after `routef`. `Console.Out.WriteLine` over a
        // concatenated string is AOT-safe and, at one call per process, costs nothing worth measuring.
        let line =
            String.Concat(
                [| "quizd listening addr="
                   config.Addr
                   ":"
                   string config.Port
                   " prefix="
                   (if config.Prefix = "" then "/" else config.Prefix)
                   " timer="
                   timerText config.Timer
                   " morph="
                   morphText config.Morph
                   " debug="
                   debugText config.Debug
                   " processors="
                   string Environment.ProcessorCount
                   " gc="
                   gcMode
                   " datas="
                   datas
                   " auctions="
                   string auctions
                   " assets="
                   string assetCount
                   "/"
                   string (assetBytes / 1024)
                   "KB(-"
                   string (assetSaved / 1024)
                   "KB) sfx="
                   string (DsQuiz.Sfx.totalBytes () / 1024)
                   "KB corpus_ms="
                   string corpusMs
                   " sfx_ms="
                   string sfxMs
                   " assets_ms="
                   string assetsMs
                   " boot_ms="
                   string booted.ElapsedMilliseconds |]
            )

        Console.Out.WriteLine line

        host.Run()
        0
