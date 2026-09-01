# datastar-quiz-fsharp: what it measures

The columns this sits beside: `apps/datastar-quiz/COMPARISON.md` (python, the reference, and now the F#
section), `apps/datastar-quiz-golang/RESULTS.md`, `apps/datastar-quiz-rust/RESULTS.md`,
`apps/datastar-quiz-tina/RESULTS.md`, and `apps/datastar-quiz-odin-http/README.md`.

**The harness is unchanged.** `apps/dsquiz-perf` reads the mount prefix, the variant query, the question
nonce and the candidate count off the page rather than assuming them, so one client drives all six
servers. The ground rules are `apps/datastar-quiz-golang/HANDOFF.md` §1 and §3: one process, no worker
pool the python cannot match, identical SSE choreography, brotli quality 5 with a 256-byte floor, caches
primed at boot, and a datastar response with no events is a `204`.

## The box

24 logical cores, Windows 11, .NET SDK 10.0.400. The injector shares the box with the server, as it does
for every other port (locust cannot use `--processes N` on Windows). `127.0.0.1` throughout, never
`localhost` — that costs ~204 ms of IPv6 fallback here.

## Scenario run: 400 users, one core, 300 s

`just dsfs serve-1core` (`DOTNET_PROCESSOR_COUNT=1`), then
`DSQUIZ_PERF_HOST=http://127.0.0.1:5080 just dsperf headless 400 20 300`. **24,575 requests, 0 failures,
every threshold passed.**

| | python (one loop) | go | rust | tina | **F# (jit)** |
|---|---|---|---|---|---|
| aggregate P50 / P95 | 4 / 72 ms | 1 / 4 ms | 2 / 19 ms | 1 / 2 ms | **1 / 4 ms** |
| aggregate P99 / max | — | — | — | — | **26 / 79 ms** |
| `POST /answer` TTFB P50 / P95 / P99 | 2 / 62 ms | 1 / 3 ms | 1 / 5 ms | 1 / 2 ms | **1 / 3 / 12 ms** |
| `/answer` whole stream, mean | ~1.1 s | 1.004 s | 1.013 s | 1.029 s | **0.99 s** |
| `GET /` P50 / P95 | — | — | — | — | **4 / 42 ms** (cold 2 / 13) |
| `GET /filter/preview` P50 / P95 | — | — | — | — | **1 / 3 ms** (2,958 reqs) |
| resident set | ~120 MB | 171 MB | **53 MB** | 207-216 MB | **118 MB** |
| private bytes | — | — | — | — | **173 MB** |
| server CPU, cores | ~0.89 (pinned) | ~0.10 | 0.110 | 1.049 (*idle too*) | **0.161** |
| threads | — | — | — | — | **16** |

Read `POST /answer` as TTFB: locust stops the clock at the headers on a streamed response, and the whole
stream is the separate row. The req/s figures are not a capacity number — the scenarios have think time.

**`gc=workstation`, and that is not a mistake in the recipe.** With `DOTNET_PROCESSOR_COUNT=1` the runtime
falls back to workstation GC even though `System.GC.Server=true` is in the runtimeconfig. The startup line
reports which collector is actually live, because the recipe cannot. Server GC and DATAS only apply to the
unrestricted column, which is what makes `just dsfs serve-nodatas` a knob for that column alone.

## The codegen axis

Same source, three publishes. `hey -n 3000 -c 4`, **one core**, with a warm-up pass discarded so the JIT
column is not charged for its own tiering.

| | JIT | ReadyToRun | **Native AOT** |
|---|---|---|---|
| deployable size | 7.2 MB *(+ a .NET install)* | 115.0 MB, 355 files | **15.9 MB, 2 files** |
| process start → first response | 681 ms | 618 ms | **553 ms** |
| the app's own boot accounting | 354 ms | 279 ms | **115 ms** |
| corpus parse + prepare | 241 ms | 180 ms | **84 ms** |
| `GET /` identity | 4,372 req/s | 4,995 req/s | **10,975 req/s** |
| `GET /` brotli | 1,662 req/s | 1,609 req/s | **3,419 req/s** |
| `GET /filter/preview` brotli | 7,124 req/s | 5,863 req/s | **9,753 req/s** |
| resident set, idle | 96.5 MB | 97.3 MB | **66.2 MB** |
| idle CPU | 0.120 cores | 0.130 cores | **0.000 cores** |

Unrestricted (24 cores), for the deployment question rather than the comparison:

| | JIT | ReadyToRun | Native AOT |
|---|---|---|---|
| `GET /` identity | 7,472 req/s | 8,570 req/s | **13,961 req/s** |
| `GET /` brotli | 2,699 req/s | 2,788 req/s | **3,430 req/s** |
| resident set | 119.2 MB | 123.7 MB | **105.9 MB** |

**Native AOT is 2.5× the JIT build on the page route, a third less memory, and its corpus prepare is 2.9×
faster** — most of what looked like a slow F# corpus loader was JIT warm-up. Idle CPU falls to zero
because there is no tiered-compilation background work to do.

Put beside the other ports' one-core per-route table: `GET /` identity **10,975** against Rust's 10,933
and Go's 1,337; `GET /` brotli **3,419** against Go's 785 and Rust's 955; `filter/preview` brotli
**9,753** against Go's 4,284 and Rust's 3,035. (Those columns were interleaved on one client in their own
runs — see the caveats in each port's RESULTS.md — so treat the cross-port comparison as indicative and
the within-port codegen comparison as exact.)

**Compression is 62-69% of a page response here** (identity 4,372 → brotli 1,662 for JIT; 10,975 → 3,419
for AOT), against Go's 41-43%, Rust's 91% and tina's 87%.

### Getting AOT to work cost three fixes

None of them was predictable from the documentation, and the shape of the trouble is the finding:
**it compiles, it links, and then it throws on the first line that formats a string.**

1. **`vswhere.exe` must be on PATH** or the native link step fails with `'vswhere.exe' is not recognized`
   and exit code 123. It ships with VS at `C:/Program Files (x86)/Microsoft Visual Studio/Installer`. The
   `publish-aot` recipe prepends it.
2. **Oxpecker and FSharp.Core emit aggregate trim/AOT warnings** — `IL2104: Assembly 'Oxpecker' produced
   trim warnings`, `IL3053: Assembly 'FSharp.Core' produced AOT analysis warnings`. ILC compiles the app
   regardless; with `TreatWarningsAsErrors` the publish fails on warnings about code it successfully
   compiled. The recipe turns that off for this publish only.
3. **Two things in the app died at startup while the build succeeded:**
   - **`routef`** builds its ASP.NET route template by reflecting over the handler's parameters
     (`RouteTemplateBuilder.convertToRouteTemplate(string, ParameterInfo[])`). AOT trims that metadata, so
     the placeholder evaluator indexes past the end of the array:
     `IndexOutOfRangeException at Oxpecker.RouteTemplateBuilder.placeholderEvaluator`. Oxpecker's own
     README offers `route` + `TryGetRouteValue`, which is what the app uses now — a dictionary lookup and
     a parse instead of a reflection-built binding, which is if anything cheaper.
   - **`printfn`** reflects over its format specifiers:
     `NotSupportedException: ... PrintfImpl+Specializations ... MethodInfo.MakeGenericMethod() is not
     compatible with AOT compilation`. The one startup line was the only caller; it is
     `Console.Out.WriteLine` over a concatenated string now, and `%A` was replaced by three
     `timerText`/`morphText`/`debugText` functions that are better output anyway.

### The AOT binary is verified, not just built

`just dsperf smoke` passes against it (exit 0, zero failures), and a sweep of all twenty routes returns
what it should: every interaction 200, `/settings` with nothing changed 204, `/timer` in client mode 204,
the debug routes 204 unarmed and 200 after a `?debug` page load, and `/debug/complete` streaming 31 events
ending in the finale. Boot is 122 ms (corpus 89, sounds 1, assets 23).

## Boot

| | python | go | rust | tina | odin-http | **F# jit** | **F# aot** |
|---|---|---|---|---|---|---|---|
| parse + prepare both corpora | ~5.5 s | ~70 ms | 21.3 ms | 48-62 ms | 48-62 ms | 241 ms | **84 ms** |
| synthesise the five WAVs | — | — | — | — | — | 6-7 ms | **0 ms** |
| pre-compress 9 assets (1,973 KB) | — | — | — | ~300 ms | ~300 ms | 25 ms | **25 ms** |
| the app's own boot total | — | — | — | — | — | 354 ms | **115 ms** |

The corpus prepare is still 1.2× Go's and 4× Rust's on the AOT column, and the reason is structural: the
prepared form here is an array of arrays of arrays (`Variants` → `Auction` → `Position` → `Call array`),
where the Rust port flattens the whole thing into four columnar `Vec`s in one arena and measures 0.72 MB
of prepared heap. That is the next thing to move, and it is the allocation cost this comparison exists to
find.

### Asset pre-compression: the measurement that changed the default

The first version compressed the assets at quality 11, reasoning that a one-off cost at boot is free for
bytes served for the life of the process. It is not free, and it is not close:

| `DSQUIZ_ASSET_BROTLI` | saved | compress | boot total |
|---|---|---|---|
| 0 (off) | 0 KB | 4 ms | 333 ms |
| **5** (the default) | **930 KB** | **25 ms** | **340 ms** |
| 9 | 935 KB | 96 ms | 417 ms |
| 11 | 951 KB | 1,484 ms | 1,793 ms |

Quality 5 takes 98% of the saving for 1.7% of the time; quality 11 costs 59× as long for the last 21 KB
and dominated the whole startup, which is both a bad deploy and a measurement that drowns out the codegen
columns it is supposed to sit beside.

## Wire

`just dsquiz measure --base http://127.0.0.1:5080` — the same instrument every other port reports.

```
payload sizes
  GET / (document)                   raw  20,408  br  5,078    4.0x smaller
  POST /skip (one interaction)       raw  18,638  br  4,539    4.1x smaller
  GET /static/app.css                raw  43,388  br 12,733    3.4x smaller
  GET /static/pico.classless.min.css raw  71,040  br  8,964    7.9x smaller
  GET /static/bulma.min.css          raw 677,931  br 36,338   18.7x smaller
  GET /static/datastar.js            raw  33,952  br 12,000    2.8x smaller
```

The brotli stream also decodes cleanly end to end through `curl --compressed` (4,599 B → 18,785 B on a
three-event `/restart`), which is the check the Go SDK failed: its `WithCompression` flushes after every
event but never closes the compressor, so the stream ends without its terminating block and a client that
decodes the whole body rejects it. `Web/Sse.fs` writes the final block explicitly.

## Pacing

```
SSE frame arrival, compressed (a wrong answer's toast sequence)
  content-encoding: br
  chunk arrivals (ms): [1, 1, 1, 1, 512, 512, 512, 1022, 1022, 1022, 1535, 2548, 2549, 2549, 2549]
  spread 2548 ms over 15 chunks -- paced, so compression is not buffering
```

One `PipeWriter.FlushAsync` per event is the whole mechanism. `GetSpan`/`Advance` only fill the pipe's
buffer, so without the flush the whole choreography would arrive in one burst at the end — which is
exactly what `tools/measure.py` asserts against by requiring a spread over 300 ms.

## Microbenchmarks

`just dsfs bench` — BenchmarkDotNet rather than the hand-rolled timer the Rust port uses, for one reason
worth the dependency: it reports **allocations per operation**, which is the column Go's and Rust's
harnesses cannot show and the one this comparison keeps asking about.

| | python | go | rust | **F#** | **F# allocated** |
|---|---|---|---|---|---|
| `checkFilter "1C"`, 7,627 auctions, cold | 15.8 ms | 380 µs | **96.5 µs** | 154 µs | 24,432 B |
| memo hit | — | 15 µs | 154 ns | **185 ns** | **96 B** |
| `checkFilter` a topic name, cold | 43 ms | — | — | **28.7 µs** | 6,736 B |
| `scorePoints` | — | 0.68 µs | 381 ns | **288 ns** | 760 B |
| `newQuestion` (difficulty 5) | — | — | — | **573 ns** | 915 B |
| `answer`, correct | — | — | — | **516 ns** | 1,680 B |
| `viewSignals` | — | — | — | **306 ns** | 1,400 B |
| `quizBody` (the `#quiz` fragment) | — | — | — | **15.4 µs** | 25,864 B |
| `appBody` (the fat morph, ~20 KB out) | — | — | — | **53.4 µs** | **187,643 B** |
| `shell` (the whole document) | — | — | — | **72.5 µs** | 227,500 B |
| load both corpora, warm process | ~5.5 s | ~70 ms | 21.3 ms | **43.5 ms** | **58.8 MB** |

On the pure-compute routines this is a good showing: the memo hit is at Rust parity (185 ns against 154,
and 80× faster than Go's 15 µs), `scorePoints` is *faster* than the Rust port's recorded number, and the
cold filter sits between Rust and Go and much nearer Rust. Nothing here needed a tuning pass.

**The allocation column is where the runtime is actually paying, and it is worth reading carefully:**

- **The fat morph allocates 187 KB to produce ~20 KB of markup** — nine bytes allocated per byte sent.
  That is the pooled `StringBuilder`, the DSL object tree the render walks, the UTF-16→UTF-8 conversion
  and the one `literalApostrophes` pass. It is not a leak and the GC handles it (Gen0 only, no Gen2), but
  it is the concrete answer to "where does .NET lose to Rust on the same work".
- **Loading the corpus allocates 58.8 MB**, against the Rust port's measured **0.72 MB of prepared heap**.
  That is 80×, and it is structural rather than incidental: the prepared form here is an array of arrays
  of arrays (`Variants` → `Auction` → `Position` → `Call array`) where Rust flattens the whole thing into
  four columnar `Vec`s in one arena. It is the single biggest thing to fix and the reason the 84 ms
  prepare is still 4× Rust's 21.3 ms.
- **The memo hit allocates 96 bytes**, which is the point of it: the answer is a shared `int array` handed
  back by reference, so a filtered session costs nothing per request.

One measurement artefact to know about: `synthesise the five WAVs` reports 5 ns because the sounds are
`lazy` and another benchmark in the same process had already forced them. The real number is the 6-7 ms
the startup line reports.

## The two bugs the port surfaced

Both were invisible in a browser, which is the pattern every port's bug section reports.

**The view engine escapes `'` to `&#39;` in attribute values.** Correct HTML, decoded before datastar ever
sees it, and the page works perfectly by hand. But the shared harness reads the page with regexes written
against the literal quotes the other four ports emit (`@post\('([^']*?)/...`), and it is declared
unchanged across ports — so it read the variant query as `?squad&#39;)` and could not find the reveal's
Next action at all. **16 of 18 page loads failed the smoke test** with *"page carried neither a question, a
reveal nor the finale"*. `Views.toHtml` is one pass over the rendered string. The Go port fought the same
class of problem from the other side: `html/template` treats `data-on:*` as JavaScript and rewrote `/` as
`\/`.

**`<path>` as a void element breaks the score dial.** Inside `<svg>` the HTML parser is in *foreign
content*, where no element is void, so `<path ...>` with no closing tag swallows every sibling after it
and the dial's `<text>` ends up inside the path. A render test caught this one before a browser did —
`RegularNode`, not `VoidNode`.

## Still to run

- The 1,000-user column and the saturation ramp, which is where the other ports found their knees
  (~3,850 users for Go, ~4,300 for Rust).
- `just dsperf timer-stream`, the held-connection countdown.
- DATAS on versus off on the unrestricted column, which is the only place it applies.
- The flatter prepared-corpus arena, and a re-measure of the 84 ms and the 58.8 MB.
- Rendering into a pooled UTF-8 buffer rather than through a `string`, which is where most of the fat
  morph's 187 KB goes.
