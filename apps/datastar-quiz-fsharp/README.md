# datastar-quiz-fsharp

The **sixth** implementation of the bidding quiz: F# on .NET 10, [Oxpecker](https://github.com/Lanayx/Oxpecker)
over ASP.NET Core, with [`StarFederation.Datastar.FSharp`](https://github.com/starfederation/datastar-dotnet)
for the datastar contract. Same hypermedia architecture, same corpus, same twenty routes, same SSE
choreography, driven by the same unchanged locust harness (`apps/dsquiz-perf`) as the python, Go, Rust
and two Odin ports. What differs is the runtime.

```shell
just dsfs serve            # every core, port 5080
just dsfs serve-1core      # DOTNET_PROCESSOR_COUNT=1 -- the like-for-like run
just dsfs test             # 225 tests, including 132 filter goldens recorded from the python
just dsfs bench            # the microbenchmarks, with allocations per operation
just dsfs qa               # fantomas --check + warnings-as-errors
just dsfs format           # rewrite to fantomas' output
just dsfs tools            # restore the pinned tools (once per checkout)
```

## Formatting, and why there is no linter

**Fantomas** is the F# formatter, pinned as a local dotnet tool in `.config/dotnet-tools.json` so every
checkout formats identically. It is configured in `.editorconfig` -- it has no config file of its own --
and only the settings this project actually changed from the defaults are listed there: 110 columns to
match the prose comments, and `number_of_items` formatters so a 20-field record like `PageData` goes
one field per line instead of filling (a filled 20-field record turns a one-word change into a
twelve-line diff).

**There is deliberately no linter.** The compiler already does most of what an F# linter would --
unused bindings, incomplete matches, shadowing -- which is what `WarnOn` in the fsproj turns on, with
warnings as errors; and FSharpLint is effectively unmaintained. The live option for the rest is an
ANALYZER (`FSharp.Analyzers.SDK`, e.g. G-Research's or Ionide's), which catches the things types cannot:
`Option.get` on a path that can be `None`, a missed `Dispose`, a culture-sensitive string comparison.
Not wired up here yet, and it is the obvious next addition to `qa`.

## The two questions this port asks

**1. What does it cost when the SSE writer is FIRST-PARTY LIBRARY CODE in the app's own language?**

`StarFederation.Datastar.FSharp` is not a binding or a community wrapper: it is the core of
`starfederation/datastar-dotnet`, and the C# package is a shim over it
(`src/csharp/StarFederation.Datastar.csproj` ProjectReferences the F# project, not the reverse). It is
good code — UTF-8 written straight into the response's `IBufferWriter<byte>`, byte-literal prefixes
(`"data: "B`), `StringTokenizer` line splitting with no per-line allocation, `[<Struct>]` option
records with `voption` fields.

**And this port could not use it for the streams.** Every writer it offers takes an `HttpResponse` and
writes to `httpResponse.BodyWriter`, which leaves no seam for a compressor — and the ground rule here is
brotli quality 5 on every response, streams included. `Web/Frames.fs` builds the frames as text instead
and hands them to `Web/Sse.fs`; that file records the alternative (replace the response's
`IHttpResponseBodyFeature` with a compressing one, which is how the framework's own compression
middleware works) as something to measure rather than to argue about. The Rust port hand-rolled its
stream for the same reason one layer down.

**2. What does the DEPLOY-TIME CODEGEN AXIS buy?** JIT / ReadyToRun / Native AOT, as three columns for
startup, resident set, steady-state throughput and **binary size** — which nothing else in this repo
measures, despite four of the six ports shipping a single embedded binary. `just dsfs publish-jit`,
`publish-r2r`, `publish-aot`, `sizes`.

## What is F#-specific here, and why

| decision | reason |
|---|---|
| **The corpus JSON is read by a hand-written `Utf8JsonReader` walk** | F# has **no Roslyn source generators**, so `System.Text.Json`'s source generation — which emits a C# partial class — is simply unavailable. The alternative is the reflection-based serialiser, which carries trim warnings and would shut the Native AOT column before it opened. |
| **The signal payload is read the same way** | The coercion *is* the work: a signal arrives as `true`, `"true"`, `1`, `"1"`, `""` or absent, and the ports reimplement python's `bool()`/`int()` for it. A typed deserialiser needs a `JsonConverter` per field to say that, and `FSharp.SystemTextJson` (for `option` fields) is reflection-based. |
| **State is an immutable record; every transition returns the next one** | The python is one asyncio loop; Go and Rust mutate a struct behind a mutex. Here the only mutable cell in the app is the one field a `Session` holds, swapped under its lock — so what a click does to a quiz is pure and testable with no session at all. |
| **Hits are indices, not auctions** | 4 bytes a hit, shared between every session that asked the same question. The Go port stores the auctions and pays 14.6 MB of live heap for it. |
| **`[<NoEquality; NoComparison>]` on the big records** | F# generates structural `Equals`/`GetHashCode`/`IComparable` for every record by default. Nothing calls them on `State`, `System`, `Question`, `Score` or `TopicSet`, and saying so removes the generated code. `Call`, `Settings`, `Points` and the two dictionary keys *are* compared, so they keep equality and lose only ordering. |
| **`[<RequireQualifiedAccess>]` on the function modules** | `open` in F# is a wildcard import. `Suits.count`, `Score.percentage`, `Store.tryGet` say what they count, average and look up; a bare `count` does not. |
| **The views are the ViewEngine DSL, not template files** | Compile-time-checked markup, like the Rust port's Askama, and `prerender` snapshots the static subtrees (the notation list, the filter help) to a literal string once at module init. |

## Layout

F# is compile-order significant, so the file order in `DsQuiz.fsproj` **is** the dependency graph:
bottom-up, `Web/` last, and nothing outside `Web/` touches ASP.NET.

| file | what |
|---|---|
| `Bids.fs` | the canonical model of a bridge call — a port of the bml tools' `bmlbids.py` |
| `BidFilter/Pattern.fs` | the filter's pattern language (`1D-1M-1N`, `(X)`, `2D/2H`, `oM`) |
| `BidFilter/Relative.fs` | binding correlated suit classes, and resolving `next`/`jump`/`cue`/`raise`/`slam` |
| `BidFilter/Matcher.fs` | the stateless prefix match, and the auction preparation that makes it possible |
| `BidFilter/Topics.fs` | topics, and the interpretation of a whole filter string |
| `Corpus.fs` | the exported corpus, the columnar prepared form, and the 256-entry filter memo |
| `Engine.fs` | the quiz rules: question generation, scoring, the time bonus, milestones, completion |
| `Session.fs` | the immutable state, its transitions, and the (browser, variant) store |
| `Sfx.fs` | five WAVs synthesised at boot from `sin` and a hand-written RIFF header |
| `Render/Escape.fs`, `Auction.fs` | the byte-matching escaper, the suit glyphs, the auction text |
| `Render/Names.fs` | the datastar kebab/camel transform — the one that fails silently |
| `Render/Signals.fs` | the signal payloads, written into a `StringBuilder` with sorted keys |
| `Render/Page.fs` | page data, the shared constants, and the SSE fragments (toast, floater, sweep, ...) |
| `Render/Views.fs` | the pages, as an F# DSL |
| `Render/Compose.fs` | session state → the three bodies the routes send |
| `Web/Config.fs` | the env/flag surface |
| `Web/Sse.fs` | negotiation, the per-event-flushed compressed writer, whole-response compression |
| `Web/Frames.fs` | the datastar frames as text, and why the SDK's writer is not used |
| `Web/Assets.fs` | the embedded assets, brotli-precompressed at boot |
| `Web/Handlers.fs` | every route |
| `Web/Server.fs` | the route table and the middleware split |

## Things that bit, and are now written down

- **The view engine escapes `'` to `&#39;`,** which is correct HTML and completely invisible to a
  browser — and it broke the shared harness, whose regexes are written against the literal quotes every
  other port emits (`@post('/answer/7/0?squad')`). It read the variant query as `?squad&#39;)` and could
  not see the reveal's Next action at all. `Views.toHtml` is the one pass that fixes it, and the Go port
  fought the same class of problem from the other side (`html/template` rewriting `/` as `\/`).
- **`<path>` as a void node breaks the score dial.** Inside `<svg>` the HTML parser is in *foreign
  content*, where no element is void, so `<path ...>` with no closing tag swallows every sibling after
  it and the dial's `<text>` ends up inside it. `RegularNode`, not `VoidNode`.
- **`ServerGarbageCollector` is not a thing.** The MSBuild property is `ServerGarbageCollection`; the
  misspelling is silently ignored and leaves you on workstation GC. And on a one-core budget the runtime
  falls back to workstation GC *anyway*, `System.GC.Server=true` or not — the startup line reports which
  one is actually live.
- **`routef` takes a compile-time `PrintfFormat`,** so a mount prefix read from the environment cannot
  be interpolated into one. `subRoute` takes an ordinary string, which is the seam.
- **`BrotliStream` cannot express quality 5** — its `CompressionLevel` constructors map `Optimal` to 4
  and `SmallestSize` to 11 — so the streams use the `BrotliEncoder` struct, which takes the quality
  directly and separates "flush after this event" from "write the final block".
- **`MinResponseDataRate` is Kestrel's write timeout** (240 bytes/second after a 5-second grace), and
  both of this app's streams sit under it. It is disabled server-wide; the per-request feature is absent
  under HTTP/2. All three of those limits are also silently unenforced while a debugger is attached.
- **`TCP_NODELAY` needs no action:** Kestrel's `SocketTransportOptions.NoDelay` defaults to `true`. The
  Rust port had to set it by hand and it was worth 10-11 ms per interaction.
- **`ResponseCompression` never touches `text/event-stream`** (it is absent from
  `ResponseCompressionDefaults.MimeTypes`, and wildcards are unsupported) — the same silent choice
  `tower-http` makes. Nothing to switch off, only something to remember.

## Environment

Identical to the other ports, plus one knob that cannot be a flag.

| variable | default | meaning |
|---|---|---|
| `DSQUIZ_ADDR` | `127.0.0.1` | interface |
| `DSQUIZ_PORT` | `5080` | port (python 5008, Go 5060, tina 5061, odin-http 5062, Rust 5070) |
| `DSQUIZ_TIMER` | `client` | `client` interval or a held `stream` |
| `DSQUIZ_MORPH` | `fat` | patch `#app` or only `#quiz` |
| `DSQUIZ_PREFIX` | *(empty)* | mount prefix, e.g. `/bridge-system-quiz` |
| `DSQUIZ_DEBUG` | *(empty)* | `""` per-session via `?debug`, `1` always, `0` never |
| `DSQUIZ_CORPUS_DIR` | *(unset)* | read `<variant>.json` from disk instead of the embedded copy |
| **`DOTNET_PROCESSOR_COUNT`** | *(unset)* | **the core budget.** The runtime reads it during initialisation, before `main`, so it cannot be a flag. `1` lands on `Environment.ProcessorCount`, Kestrel's IO queue count and the GC heap count together — which is why it is the honest single knob. |
| `DOTNET_GCDynamicAdaptationMode` | `1` | DATAS, on by default from .NET 9. `just dsfs serve-nodatas` turns it off. |
