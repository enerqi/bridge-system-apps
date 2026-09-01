# dsquiz-tina

The bridge bidding quiz, a fourth time: Odin on [Tina](https://github.com/pmbanugo/tina).

`apps/datastar-quiz/` (python, Litestar + Datastar) is the source of truth. `apps/datastar-quiz-golang/`
was the third implementation and its `HANDOFF.md` is the written port specification — the comparison
ground rules in §1 and the wire protocol in §3 apply here unchanged. This is the fourth.

## Why a fourth

Not for another web app. For the *allocation* question the other three cannot ask.

Python allocates freely, Go has a garbage collector, Rust has ownership and still a heap. Tina is a
shared-nothing, thread-per-core framework whose whole premise is that after boot there is no
`malloc`: every isolate, every message envelope and every I/O buffer is carved from one contiguous
per-shard block sized at startup, and when the workload exceeds it the process sheds load rather
than growing. The quiz suits that because its working set is knowable — one immutable corpus, N
sessions, and a response that has to fit a fixed buffer.

Where the Go port's heap profile found a 282 MB line (a brotli encoder allocated per SSE response),
Tina's contract says such a line cannot exist. This port is a test of whether that contract survives
contact with a real hypermedia app.

The short answer: yes, and the bill arrives up front. Every ceiling this app runs into is a `u16` in
somebody's struct, and the memory is a number in the source rather than a question answered under
load.

## Running it

```shell
just dstina serve          # port 5061 (python 5008, go 5060 — all three can run side by side)
just dstina lint           # type check, tina included
just dstina lint-strict    # full vet + style over the packages that do not import tina
just dstina test-all       # every package's tests
just dstina qa             # all of the above
```

Tina is an external checkout, the way this repo already treats `norn`, `bridge-markup` and
`odin-sciter`: clone it to `~/dev/tina`, or set `TINA_HOME`.

| variable | default | |
|---|---|---|
| `TINA_HOME` | `~/dev/tina` | the tina checkout |
| `TINA_EGRESS_BUFFER_SIZE` | `64512` | per-connection response buffer, compiled in |
| `DSQUIZ_PORT` | `5061` | |
| `DSQUIZ_CONNECTION_SLOTS` | `512` | pre-allocated connection isolates |
| `DSQUIZ_PREFIX` | *(none)* | mount point, applied to routing and to every emitted URL |
| `DSQUIZ_TIMER` | `client` | `stream` holds an SSE connection per player instead |
| `DSQUIZ_DEBUG` | | `1` also arms the debug panel without `?debug` |

`HANDOFF.md` is the next-session brief: what is left, what was already ruled out, and the traps that
have already been paid for.

## Status

| phase | | |
|---|---|---|
| A | toolchain, server boot, `/health` | **done** |
| B | static assets, streamed | **done** |
| C | `bids` + `bidfilter` + `corpus`, goldens green | **done** |
| D | `engine`, `session`, `render`, the index page | **done** |
| E | the SSE choreography | **done** |
| F | filter, topics, debug, sound | **done** |
| G | brotli | **done** — `just serve-brotli`, assets pre-compressed at boot |
| H | load measurement, RESULTS.md | **done** — `RESULTS.md`; one open defect, below |
| I | multi-shard | **done** where the platform allows — `just shardcheck`, and see below |

The quiz plays. Every route in the python is implemented, and `tools/measure.py` — the python's own
instrument — reports the answer choreography as correctly paced.

## Measurements

| | python | go, 1 core | tina, 1 shard |
|---|---|---|---|
| corpus primed at boot | ~5.5 s | ~70 ms | **48 ms** (9,279 auctions) |
| index document | | 20,268 B | **19,852 B** |
| one interaction (`/skip`) | | | **17,835 B** |
| RSS booted, serving nothing | | | **72.5 MB** at 512 slots |
| tests | 619 | | **61** |

`tools/measure.py` against this server:

```
SSE frame arrival, compressed (a wrong answer's toast sequence)
  chunk arrivals (ms): [1, 1, 1, 1, 600, 600, 600]
  spread 599 ms over 7 chunks -- paced, so compression is not buffering
```

Four immediate frames, the 0.6 s toast pause, then three more. That is the property the ground rules
actually care about, and it holds.

## Three ceilings, all of them u16

Tina's addressing, not its policy, sets every limit this app ran into. Each was found by bisection or
by a panic, and each is now a constant with the measurement next to it.

**The egress buffer is 64768 bytes, not 65535.** `response.odin` asserts
`HTTP_EGRESS_BUFFER_SIZE <= max(u16)`, which reads like the limit is 65535, but the binding
constraint is in `server.odin`: the whole `HTTP_Connection` — connection state *plus* the egress
buffer that trails it — has to fit Tina's u16 `payload_offset` space. Bisected against tina
`a2e8d4d`: **64768 builds, 64769 fails**, so the connection state is 767 bytes. The justfile compiles
in 64512.

This matters because Tina's Datastar SDK serialises each SSE event into **one exact
`reserve_body_exact` reservation**. An event that does not fit is refused, not truncated. The fat
morph patches `#app` whole, so the 4096-byte default is nowhere near enough.

**`state_size` is a u16 too**, so a route's state — where this app keeps the memory a response hands
to later events — is capped at 65535 bytes. `RESPONSE_ARENA_SIZE` is 56 KB, that ceiling with room
for the step array.

**Static allocation is real and visible.** 63 KB of egress plus 56 KB of response arena, times 512
connection slots, is ~61 MB reserved before a single request arrives; measured RSS at boot is 72.5 MB
serving nothing. That is the trade, and it is the number the comparison should be read against rather
than hidden.

## What the port surfaced

Things that were not obvious from the outside, in the order they cost time.

**Scratch is reset before every handler call.** A response outlives the call that started it — the
document is rendered on `Request_Start` and written over many `Send_Ready`s — so anything held in
`context.temp_allocator` across that boundary dangles. Because the arena is a bump allocator that
silently stops, the first symptom is not a crash but a page that ends mid-attribute at 12,832 bytes.
Everything a later event reads now comes from an arena the route state owns.

`tina.ctx_working_arena()` is the other obvious answer and is also wrong: that is Tina's own
per-connection memory, sized by the framework for the request frame and the header table, and about
24 KB.

**`patch_elements` refuses an empty payload.** The python and the Go port both clear `#sfx` and
`#toasts` by patching empty elements with mode `inner`; Tina's SDK returns `.Invalid_Argument` unless
the mode is `.Remove`, and the handler closes on the error — so the stream just stops, with nothing
in the browser to say why. Replacing the element with an empty one under mode `.Outer` is the same
thing said in a way the SDK accepts.

**A fixed-length body must match its Content-Length exactly**, and Tina asserts it. The panic kills
the connection isolate, so the symptom is a connection reset rather than a short response. Choosing
the body and declaring the length have to be one decision; they are, now, in one statement.

**`urllib` sends `Connection: close`,** and Tina honours it:
`_connection_continue_after_non_final_flush` finalises the response instead of dispatching
`Send_Ready`. A perfectly healthy paced stream therefore looks like it dies at its first flush. This
cost an afternoon twice — once against tina's own SSE example before any of this port existed, and
once against the answer choreography. Test SSE with curl.

**Windows IOCP is fine.** Tina's badge says Odin `dev-2026-05` and this is `dev-2026-08-nightly`; it
builds clean, holds SSE connections open, and paces `expect_notification` resumes accurately. The
held `/timer` stream delivers exactly 30 ticks in 3 seconds.

## Where the allocation story shows up

- **`Bid` is six bytes**, `Copy`, no pointer in it. Preparing the swedish system produces roughly
  400,000 of them, held for the life of the process: 16 MB in Go, where `Kind` and `SuitClass` are
  strings, against ~2.4 MB here.
- **Parsing allocates nothing.** Token normalisation writes into stack buffers the caller owns,
  because `parse_call` runs on every token of the corpus at boot *and* on every keystroke in the
  filter box. The leak tracker is silent across the whole `bids` suite.
- **The filter memo needs no lock.** The Go port guards it with a mutex and the Rust port with
  `parking_lot`; one shard owns the store and runs every handler on one thread, so there is no other
  thread to exclude. The same applies to the session store and to the single shared brotli encoder —
  the Go port needs a `sync.Pool` for that one.
- **`flat`** stores groups end to end with an offsets array, so an auction is two allocations rather
  than one per position. The obvious `[][]Bid` would spend an allocation and a 16-byte header on each
  6-byte payload, ~380,000 times.

## Parity

**All 132 golden probes pass** — `testdata/filter_goldens.json`, the same file the Go and Rust trees
carry byte-identical. Each pins status, hit count, canonical text, errors, topic names, and a sha256
over the comma-joined indices of the selected auctions. The digest is the one that matters: a hit
count alone would not notice two auctions swapping in and out. Typing `1C` into the filter box
reports "327 auctions match", which is the python's number.

**The 36 topic-name goldens pass**, plus every topic name in the corpus. That transform is silent
when wrong — a mistyped signal name binds a different signal rather than failing — and four
implementations of it exist.

`engine`'s constants are pinned case by case, including python's banker's rounding, which the two
disagree on at every `.5`.

## Deliberate divergences

Recorded as they happen, the way the Go port records its inherited defect.

- **One shard by default**, which is the like-for-like budget the comparison asks for — the python
  owns one asyncio loop and `just dsgo serve-1core` is one core. `DSQUIZ_SHARDS` raises it, up to
  this app's ceiling of ten (a Tina shard spins a whole core at idle, so ten shards is ten cores).

  Phase I is what makes that a setting: the sessions live behind one seam
  (`session/store_protocol.odin` — the operations, the lease, the wait queue, no framework in it),
  reached directly when the process runs one shard and through an isolate
  (`web/store_isolate.odin`) when it runs more. Both transports, one seam, deliberately: routing every
  session touch through a mailbox on a SINGLE shard cost three quarters of the throughput and stalled
  a fifth of the run (RESULTS.md, "Phase I").

  **Multi-shard HTTP does not run on Windows**, and that is Tina rather than this app:
  `install_into_system_spec` asserts `shard_count == 1` there (no cross-shard FD handoff) and Windows
  has no `SO_REUSEPORT`. The app refuses `DSQUIZ_SHARDS > 1` with that reason. What is proven across
  shards is the store protocol itself — `just shardcheck 10` runs the real isolate against a prober on
  every shard, 2,000 rounds, no HTTP.
- **Documents are compressed per request; assets are compressed once at boot.** The encoder is the C
  brotli at quality 5 with `LGWIN = 16` and a 256-byte minimum, matching what the other three ports
  were configured with, driven through allocator callbacks backed by an 8 MB arena this app owns — so
  the "no allocation after boot" claim survives contact with a compressor, and the Go port's 282 MB
  per-response encoder cannot happen here. It is behind `-define:DSQUIZ_BROTLI=true`
  (`just serve-brotli`, default off) because the library is somebody else's source and is not
  vendored: run `just build-brotli` first.

  What blocked it for a whole session was the staged library, not the bindings, the linker or Odin.
  CMake picks whatever compiler it finds, and radlink cannot read the GNU `.a` that chocolatey's gcc
  produces; a `/MD` build links but references `__imp_malloc`, and naming `system:msvcrt.lib` in the
  foreign import gives a binary that dies before `main` — two C runtimes, and the loser is the
  process. The answer is the MSVC **static** CRT (`CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded`), which
  is what `just build-brotli` asks for.

  Pre-compressing the assets at boot is the one place this port beats the other three outright rather
  than matching them: 9 files, 999 KB saved, ~300 ms of startup, and `bulma.min.css` goes out at
  42,757 bytes instead of 677,931 on every cold visit.
- **The shard SIGSEGVs above ~500 concurrent users.** An open defect, not a capacity limit, and the
  first thing to fix: `hey -n 6000 -c 300 http://127.0.0.1:5061/` reproduces it in seconds, Tina
  quarantines the shard, and the process stays alive answering nothing. `RESULTS.md`, "Where this
  server actually stops", has the bisection.
- **SSE streams are still not compressed.** Tina's Datastar SDK serialises each event
  directly into the connection's egress buffer, which is exactly where a compressor has to sit.
  Compressing them means serialising the Datastar frames in this app and keeping the SDK only for
  `read_signals` — a dozen lines of wire format, but it trades away the SDK that made this port
  cheap.
- **The variant-from-query defect is reproduced, not fixed.** Typing "swedish" into the filter box of
  a squad page switches systems on the next `/filter/preview`, because the query scan sees datastar's
  `?datastar=<json>`. The python does this and the Go port kept it; a divergence would show up in the
  load runs and be read as a runtime effect.
- **Lint is split in two.** `odin check` applies `-vet` and `-strict-style` to every package it
  parses, the collection included, and there is no way to scope them. Tina is space-indented where
  this project is tab-indented, and its simulation-test files import `core:testing` unused outside a
  test build. So `lint` type-checks everything and `lint-strict` runs the full vet and style set over
  the packages that do not import tina — which is most of the code.

## Layout

```
main.odin        operational setup: tracking allocator, backtraces, logger
quizd.odin       the entry point, which hands over to web.serve
bids/            the call model -- a port of the bml tools' bmlbids.py
bidfilter/       the pattern language and the matcher -- a port of apps/quiz/bidfilter.py
flat/            groups stored end to end; the container the corpus is built on
corpus/          the embedded JSON, the variants, and the memoised filter
engine/          points, streak, toasts, milestones, completion -- no HTTP, no HTML
session/         the (sid, variant) store; every access goes through store.odin
render/          the HTML writers, the signal payloads, the naming transform
sfx/             five WAVs synthesised at boot -- no audio files, in any of the four ports
brotlienc/       bindings to the C encoder, with Tina-backed allocator callbacks
web/             the routes, the SSE choreography, the response arena
```

The corpus is exported from the python by `apps/datastar-quiz/tools/export_corpus.py`, as in the
other ports. The matcher is not: it is where the CPU goes, and a comparison that skipped it would not
be a comparison.
