# dsquiz-odin-http

The bridge bidding quiz, a fifth time: Odin on [odin-http](https://github.com/laytan/odin-http).

`apps/datastar-quiz/` (python, Litestar + Datastar) is the source of truth. `apps/datastar-quiz-golang/`
was the third implementation and its `HANDOFF.md` is the written port specification — the comparison
ground rules in §1 and the wire protocol in §3 apply here unchanged. `apps/datastar-quiz-tina/` was
the fourth, and this one is its sibling.

## Why a fifth

Because the fourth left a variable uncontrolled.

The Tina port is a very good answer to "what does a shared-nothing, thread-per-core runtime with no
allocation after boot cost?" — but it is written in Odin, on a framework, against a comparison whose
other three members are three different languages. When its numbers differ from Go's, the honest
answer is *something about Odin, or Tina, or both*.

This port removes the "or both". **Everything except `web/` is the Tina port's source, unchanged** —
the same `bids`, `bidfilter`, `flat`, `corpus`, `engine`, `session`, `render`, `sfx` and `brotlienc`
packages, byte for byte. The same compiler, the same corpus, the same renderer, the same scoring.
What differs is the HTTP runtime and the ~1,500 lines that sit on it:
### The snapshot this is against

**Copied from `apps/datastar-quiz-tina/` on 2026-08-31, early afternoon, and that port is still being
worked on.** It has already moved since: its `session/` package has gained a `store_protocol.odin`
and a lease on `Session` (`lease_held` / `lease_taken`), which is phase I — the store becoming an
isolate that connection isolates reach by message. This port's `session/` is the pre-lease snapshot,
deliberately: the lease is Tina's answer to Tina's shared-nothing model, and copying it here would
import the thing the comparison is trying to hold constant.

So "the same source" is a claim about **that snapshot**, and it decays. What it is worth is checkable
in one command, and the answer should be a short list rather than a long one:

```shell
diff -rq apps/datastar-quiz-tina/{bids,bidfilter,flat,corpus,engine,session,render,sfx,brotlienc}          apps/datastar-quiz-odin-http/{bids,bidfilter,flat,corpus,engine,session,render,sfx,brotlienc}
```

Every Tina figure quoted below and in `RESULTS.md` is likewise **that port's `RESULTS.md` as
published on 2026-08-31**, not a number this session re-measured — the two servers were never run
side by side, because rebuilding a tree somebody else is editing is a good way to measure neither.
Read the cross-port rows as "against the Tina port as it stood", and re-run both if a decision
depends on it.


| | tina | odin-http |
|---|---|---|
| concurrency | shared-nothing shards, one OS thread each | threads over shared memory, one event loop each |
| session store | a plain map, no lock (one shard owns it) | a map behind one `sync.Mutex` |
| response memory | a fixed `u16`-addressed block per connection slot, sized at boot | a growing `virtual.Arena` per connection, freed per request |
| response buffer | `HTTP_EGRESS_BUFFER_SIZE`, compiled in, bisected to 64768 max | none — bodies are strings |
| large bodies | streamed over `Send_Ready` because they exceed the buffer | `body_set` and `respond` |
| SSE | its own Datastar SDK, one exact reservation per event | ~110 lines of wire format in `datastar.odin` |
| pauses | `expect_notification` parks the connection isolate | `nbio.timeout` — with a trap; see below |
| memory at rest | 72.5 MB at 512 connection slots | 23.9 MB |

Neither is free, and that is the finding rather than a preface to one: the Tina port knows its
ceiling before the first request and pays for it at boot; this one is small at rest and finds its
ceiling under load.

## Running it

```shell
just dsoh serve             # port 5062 (python 5008, go 5060, tina 5061 — all five run side by side)
just dsoh serve-brotli      # the build RESULTS.md measures; needs a prior `just dsoh build-brotli`
just dsoh serve-all-cores   # odin-http's own default thread count instead of the like-for-like one
just dsoh lint              # type check everything, odin-http included
just dsoh lint-strict       # full vet + style over the packages that do not import odin-http
just dsoh test-all          # every package's tests
just dsoh qa                # all of the above
```

odin-http is an external checkout, the way this repo already treats `norn`, `bridge-markup`,
`odin-sciter` and `tina`: clone it to `~/dev/odin-http`, or set `ODIN_HTTP_HOME`.

| variable | default | |
|---|---|---|
| `ODIN_HTTP_HOME` | `~/dev/odin-http` | the odin-http checkout |
| `DSQUIZ_PORT` | `5062` | |
| `DSQUIZ_THREADS` | `1` | event-loop threads; `0` asks for odin-http's own default (cores − 1) |
| `DSQUIZ_PREFIX` | *(none)* | mount point, applied to routing and to every emitted URL |
| `DSQUIZ_TIMER` | `client` | `stream` holds an SSE connection per player instead |
| `DSQUIZ_DEBUG` | | `1` also arms the debug panel without `?debug` |

There is deliberately no `DSQUIZ_CONNECTION_SLOTS` and no egress-buffer knob. That is the point of
the comparison: this runtime has nothing to size.

## Status

| phase | | |
|---|---|---|
| A | toolchain, server boot, `/health` | **done** |
| B | static assets | **done** |
| C | `bids` + `bidfilter` + `corpus`, goldens green | **done** (inherited) |
| D | `engine`, `session`, `render`, the index page | **done** (inherited) |
| E | the SSE choreography | **done** — and see "The trap this port paid for" |
| F | filter, topics, debug, sound | **done** |
| G | brotli | **done** — `just serve-brotli`, assets pre-compressed at boot |
| H | load measurement, RESULTS.md | **done** — `RESULTS.md` |
| I | multi-thread under load | `just serve-all-cores` runs; not measured |

Every route in the python is implemented. `tools/measure.py` — the python's own instrument — reports
the answer choreography as correctly paced, and the load harness reports **zero failures at 400 and
at 800 users**, with the index route surviving `hey -n 40000 -c 1000` — the command that faults the
Tina port at a fifth of that. `RESULTS.md` has all of it.

## Measurements

| | python | go, 1 core | tina, 1 shard | **odin-http, 1 thread** |
|---|---|---|---|---|
| corpus primed at boot | ~5.5 s | ~70 ms | 48 ms | **60 ms** (9,279 auctions, incl. 9 assets pre-compressed, 999 KB saved) |
| index document | | 20,268 B | 19,852 B | **19,924 B** |
| one interaction (`/skip`) | | | 17,835 B | **17,849 B** |
| a correct answer's choreography | ~1.1 s stream | 2,513 ms | 2,506 ms | **2,529 ms** |
| a wrong answer's choreography | | | | **608 ms** |
| RSS booted, serving nothing | ~120 MB | 171 MB | 72.5 MB (512 slots) | **23.9 MB** |
| tests | 619 | | 61 | **64** |

The document and interaction sizes are the Tina port's to within the digits of a build stamp, which
is the check that the two really are the same app: the renderer is the same file.

**Is this faster than the Rust port?** Measured properly — both servers started together and walked
route by route in lockstep — **no: on application work they are level.** `GET /` identity 19,276 req/s
here against 17,584 there (1.10×), `POST /settings` a tie, and `GET /filter/preview` **faster in
Rust**. An earlier version of this file claimed 1.7–3.1× on those rows; that came from comparing
numbers measured here against numbers quoted from the Rust port's own document, which understated
itself by up to 5×. What survives is the C `libbrotli` against the `brotli` crate (1.8× on a
compressed page) and the fact that this port does not compress SSE at all. The Rust port is also
ahead on memory under load. And the one comparison with a single variable in it — two Odin ports,
byte-identical app packages — says odin-http is 1.5–2.2× slower per request than Tina.
`RESULTS.md`, "CORRECTION: the same probe run interleaved", has it.

## The trap this port paid for

**A `core:nbio` timeout registered from a send completion does not wake the loop.**

The whole choreography is pauses — a toast, 0.5 s, another toast — and the first working build ran
them at 777 ms, 1000 ms, 2008 ms against a script of 0.5 s, 0.5 s and 1.5 s. Nothing errored,
nothing failed, and the load harness counted every request a success.

`nbio`'s tick decides how long to sleep **before** it drains the completed-operations queue:

```odin
l.now = time.now()
next_timeout := check_timeouts(l)                      // how long this tick may sleep
...drain l.completed, running callbacks...             // a callback here registers a new timeout
GetQueuedCompletionStatusEx(..., next_timeout, ...)    // sleeps straight past it
```

A send on loopback completes inline, so its callback runs out of that queue — and a timeout
registered there is invisible to the sleep that immediately follows. The loop then sleeps until the
next wake-up it already knew about, which in an odin-http server is the once-a-second date-header
refresh. That is where the 1 s quantisation came from, and without that timer the wait would be
`INFINITE`.

Measured with a 12-tick repro rather than reasoned about (`just dsoh nbio-timer <mode>`,
`tools/nbiotimer/`):

```
plain      gaps (ms): 110 109 107 108 110 108 110 109 108 109 109 109
with_date  gaps (ms): 114 108 109 111 110 109 109 108 111 109 108 108
after_send gaps (ms): 109 109 785 1010 1013 1015 1013 1001 1005 1003 1015 1001
```

A chained 100 ms timeout is accurate on its own **and** with a 1 s timer beside it, and ten times
too long when it is re-armed from a send completion. A timeout registered from a *timeout* callback
is fine — `check_timeouts` re-scans after firing its callbacks — so the fix is to never re-arm from
the completion: `stream_send` registers the pause **first** and submits the send **after** it, and
the step ends when both have finished. The order of those two calls is the whole fix, and it is
commented as load-bearing where it lives.

This is a bug in `core:nbio` rather than in odin-http or in this app, and it is worth reporting
upstream: moving `check_timeouts` after the completed-queue drain would fix it for everyone.

## What else the port surfaced

**odin-http's streaming writer frames chunks; it does not send them.** `http.response_writer_init`
gives a correct chunked-encoding `io.Writer`, and `.Flush` appends a chunk to the response's own
buffer — the bytes reach the socket in one `nbio.send` when the response is closed. For a file that
is right. For a paced SSE stream it turns a quiz into a slideshow, with no error anywhere. So the
framing here is odin-http's and the sending is this app's: flush an event into the response buffer,
hand that buffer to `nbio.send`, reset it on the completion. The last event closes the writer, which
writes the terminating chunk and returns the connection to odin-http's own request loop, so
keep-alive, the request-body drain and teardown all stay the library's job.

**`context.temp_allocator` inside a handler is not the connection's arena.** odin-http calls handlers
from its scanner's IO callbacks, whose context is the event loop's, so a response built out of
`context.temp_allocator` and read back in a timer callback is reading memory nobody owns. The
connection's own growing arena (`response._conn.temp_allocator`) is both the correct lifetime — freed
once, after the response is sent — and the only thing that makes a 2.5-second choreography safe.
`request_arena` is the one place this app names it, and every allocator argument in `web/` is
explicit for the same reason.

**Lua patterns eat a hyphen.** odin-http routes match with Lua patterns, where `-` is the lazy-repeat
quantifier, so `/filter/preview-topics` reads as "prefi", zero-or-more "w", then "topics", and
matches nothing anybody types. The literal dashes in the route table are escaped as `%-`, and the
mount prefix — somebody's environment variable — goes through `escape_pattern`.

**An `Encoded` filled in only on the compressing path serves nothing.** The identity form of every
asset was only ever assigned inside `compress_assets`, which is behind `-define:DSQUIZ_BROTLI=true`.
The default build answered every stylesheet with `200`, the right content type and
`content-length: 0` — a page with no CSS at all, which no test and no browser reports as an error.
`init_assets` now points every asset at its own bytes, unconditionally. **The Tina port has the same
shape and, read at the time of writing, the same bug**: `web/assets.odin` there assigns
`asset.encoded` only inside `compress_assets`, which its `server.odin` calls under
`when BROTLI_ENABLED`, and `stream_asset` then sends `choose_encoding(..., asset.encoded)`. Its
measurements were all taken on `serve-brotli`, where the path is filled in, which is why nothing
caught it. Not verified by running it — that tree is being edited concurrently — so check before
acting on it:

```shell
just dstina serve                                          # the default build, no brotli
curl -sI http://127.0.0.1:5061/static/app.css | head -3    # content-length: 0 means yes
```

**A POST body is asynchronous.** `http.body` takes a callback, so every POST route is "ask for the
body, then do the work" rather than one straight-line handler — Datastar uploads its signal store as
that body. `sse_route_post` and `sse_route_get` are the two entry points, and they meet again in
`run_build`.

## Deliberate divergences

Recorded as they happen, the way the Go and Tina ports record theirs.

- **One event-loop thread.** odin-http's own default is `cores - 1`; the comparison's budget is one
  loop, matching the python's single asyncio loop, Tina's one shard and `just dsgo serve-1core`.
  `just serve-all-cores` lifts it, and the session store's mutex then does real work.
- **One lock, held for the build and never for the stream.** The corpus is read-only after boot and
  its filter memo is already `@(thread_local)`, so the sessions are the only shared mutable state.
  Every route mutates its session fully before the first byte goes out, which is what lets the lock
  be released before the ~2.5 seconds of pauses.
- **SSE streams are not compressed** — the same divergence the Tina port records, for a different
  reason. There the SDK writes each event straight into the connection's egress buffer and there is
  nowhere for a compressor to sit. Here the events are bytes this app owns, so the wall is the
  *encoder's lifetime*: a stream that flushes per event holds its encoder for the length of the
  choreography, and this app's encoder is backed by an 8 MB arena. One per in-flight answer is the Go
  port's 282 MB line rediscovered from the other side. A small pool sized against concurrency is the
  real answer and is a phase of its own.
- **Documents are compressed per request; assets are compressed once at boot.** Quality 5, `LGWIN =
  16`, 256-byte minimum — what the other four were configured with. `bulma.min.css` goes out at
  42,757 bytes rather than 677,931, which is the same number the Tina port measures, from the same
  encoder.
- **The variant-from-query defect is reproduced, not fixed.** Typing "swedish" into the filter box of
  a squad page switches systems on the next `/filter/preview`, because the query scan sees datastar's
  `?datastar=<json>`. The python does this and the other ports kept it; a divergence would show up in
  the load runs and be read as a runtime effect.
- **Lint is split in two**, exactly as in the Tina port and for the same reason: `odin check` applies
  `-vet` and `-strict-style` to every package it parses, the collection included, and there is no way
  to scope them. `lint` type-checks everything; `lint-strict` runs the full set over the packages that
  do not import odin-http, which is most of the code.

## Layout

```
main.odin        operational setup: tracking allocator, backtraces, logger
quizd.odin       the entry point, which hands over to web.serve
bids/            the call model — a port of the bml tools' bmlbids.py       (tina port, unchanged)
bidfilter/       the pattern language and the matcher                        (tina port, unchanged)
flat/            groups stored end to end; the container the corpus is on    (tina port, unchanged)
corpus/          the embedded JSON, the variants, and the memoised filter    (tina port, unchanged)
engine/          points, streak, toasts, milestones, completion              (tina port, unchanged)
session/         the (sid, variant) store                                    (tina port, unchanged)
render/          the HTML writers, the signal payloads, the naming transform (tina port, unchanged)
sfx/             five WAVs synthesised at boot                               (tina port, unchanged)
brotlienc/       bindings to the C encoder                                   (tina port, unchanged)
web/             THE PORT: the routes, the SSE pacing, the Datastar wire format
tools/           the three diagnostics whose findings are quoted above:
                   nbiotimer/     the nbio timer repro   (`just dsoh nbio-timer <mode>`)
                   sse_probe.py   one answer, frame by frame  (`just dsoh sse-probe`)
                   timer_probe.py the held countdown's tick spacing (`just dsoh timer-probe`)
```

`web/` is nine files:

| file | what |
|---|---|
| `server.odin` | config, boot, the route table, the store's lock |
| `routes.odin` | the dispatcher (async body, then build, then stream) and the answer choreography |
| `request.odin` | session cookie, theme cookie, uploaded signals |
| `sse.odin` | the script, and the pacing — the file the nbio trap lives in |
| `datastar.odin` | the wire format, written by hand: two event types and a line splitter |
| `filter.odin` | the filter box and the topic picker |
| `debug.odin` | the debug panel, the held countdown, the sounds |
| `assets.odin` | the embedded assets |
| `compress.odin` | brotli, and what is and is not compressed |

The corpus is exported from the python by `apps/datastar-quiz/tools/export_corpus.py`, as in the
other ports.
