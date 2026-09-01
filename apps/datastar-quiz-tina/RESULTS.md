# Load runs

Measured on **2026-08-30/31**, on the machine the python numbers in `../datastar-quiz/COMPARISON.md`,
the Go numbers in `../datastar-quiz-golang/RESULTS.md` and the Rust numbers in
`../datastar-quiz-rust/RESULTS.md` were measured on: 24 cores, Windows, over loopback, load generated
by `apps/dsquiz-perf/` (locust) on the same box.

The harness is **unchanged** — the same one that drove the other three. It reads the mount prefix,
the variant query, the question nonce and the candidate count off the page rather than assuming
them, so one client drives all four servers. What differs is the runtime, not the load.

```shell
just dstina serve                                         # port 5061, one shard
DSQUIZ_PERF_HOST=http://127.0.0.1:5061 just dsperf headless 400 20 300
```

Two things to know before reading any number here.

**This port is measured with brotli compiled in** (`-define:DSQUIZ_BROTLI=true`), which is what makes
it comparable to the other three. That build did not run at all when the previous session handed
over; it does now, and the encoder is the same C brotli at quality 5 with a 256-byte minimum that
Litestar, `andybalholm/brotli` and the `brotli` crate were configured with.

**`req/s` in the scenario tables is not a capacity number.** It is set by the scenarios' think time
and by the ~1 s answer choreography. The ceiling is in *"Where this server actually stops"*, and on
this port the ceiling is a **crash**, not a knee — see that section before quoting anything else.

---

## Player + filter + cold-visit scenarios

All three scenarios mixed, one shard, brotli build.

| | python (one loop) | go, 1 core | rust, 1 core | **tina, 1 shard, 400** | **tina, 1 shard, 500** |
|---|---|---|---|---|---|
| users | 400 | 400 | 400 | **400** | **500** |
| spawn / duration | — | 20/s, 300 s | 40/s, 200 s | 20/s, 300 s | 40/s, 150 s |
| requests | — | — | — | 24,934 | 16,062 |
| **failures** | 0 | 0 | 0 | **0** | **0** |
| aggregate P50 | 4 ms | 1 ms | 2 ms | **1 ms** | **1 ms** |
| aggregate P90 | — | — | — | 2 ms | 2 ms |
| aggregate P95 | 72 ms | 4 ms | 19 ms | **2 ms** | 15 ms |
| aggregate P99 | — | 16 ms | — | 16 ms | 48 ms |
| `POST /answer` (TTFB) | P50 2, P95 62 ms | P50 1, P95 3 ms | P50 1, P95 5 ms | **P50 1, P95 2 ms** | P50 1, P95 7 ms |
| `GET /filter/preview` | P50 4, P95 77 ms | P50 1, P95 3 ms | — | **P50 1, P95 2 ms** | P50 1, P95 3 ms |
| whole `/answer` SSE stream | mean ~1.1 s | mean 1.004 s | mean 1.013 s | **mean 1.029 s** | mean 0.996 s |
| throughput | ~100 req/s | 82 req/s | — | 83 req/s | 107 req/s |
| RSS (1,024 connection slots) | ~120 MB | 171 MB | 53 MB | 207 → 216 MB | — |

Re-run after phase I, on the same 400 users for 200 s: **16,191 requests, 0 failures, P50 1 ms,
P95 3 ms, P99 15 ms, stream mean 970 ms, 81 req/s** — the same server, with the session store behind
the protocol seam described below.

At 400 users this is the best latency column in the comparison — P95 2 ms against Go's 4 ms and the
python's 72 ms, with the same choreography timing (1.029 s against Go's 1.004 s and the python's
~1.1 s, on a script of deliberate sleeps summing to ~0.95–1.0 s for a correct answer). At 500 the
tail starts to move (P95 2 → 15 ms, P99 16 → 48 ms) while the median does not, and the page route is
where it shows: `GET /` goes from P50 12 ms / P95 24 ms to P50 34 ms / P95 67 ms. That is queueing on
one shard, and it is the only warning before the failure in the next-but-one section.

RSS is the other half of the thesis and it holds: 207 MB at rest with 1,024 slots, 216 MB peak with
400 players on it — **9 MB of growth under load**, against a Go port whose equivalent figure was
171 MB rising to 278 MB at 1,000 users. What the memory *is* is discussed under "Memory" below, and
most of it is bought before the first request arrives.

## The bug the measurement found

The first 400-user run reported an `/answer` SSE stream mean of **559 ms** against the Go port's
1,004 ms for the same script, with **zero failures**. A one-second gap in a one-second choreography
is not scheduling noise, so it was traced frame by frame (`curl -N`, timestamping every event):

```
verdict=CORRECT  total=1510 ms                    verdict=wrong  total=611 ms
  +   7 ms  signals {"_streak":1}                   +   7 ms  signals {"_streak":0}
  +   0 ms  elements <div id="sfx" …>               +   0 ms  elements <div id="sfx" …>
  +   0 ms  elements <div class="toast success…>    +   0 ms  elements <div class="toast warning…>
  + 499 ms  elements <div class="toast info…>       + 600 ms  elements <div class="toasts" …>   <- clear
  + 500 ms  elements <div class="toast info…>       +   0 ms  elements <header class="topbar"…> <- fat morph
  (nothing further — connection closed)             +   0 ms  signals {"_correct":0,…}
```

Every **correct** answer ended its stream one step early. The script's last entry is
`Toast{text = "", pause = 1.0}` — the beat the python's panel handler took before moving on — and
`render.toast` renders no element for a toast with no text. Tina's Datastar SDK refuses an empty
payload (`patch_elements` returns `.Invalid_Argument` unless the mode is `.Remove`), the handler
closes on the error, and the stream simply stops: no final pause, **no toast clear, and no fat
morph**. The question card never advanced until the player's next interaction, and because the
connection closed cleanly after a valid partial stream, the load harness recorded a success.

The fix is in `web/stream.odin`: `push_elements` drops an empty payload rather than pushing it, so a
step that renders nothing contributes its **pause** and nothing else. After it, a correct answer runs
**2,506 ms** against the Go port's 2,513 ms on the same session shape, and the 400-user stream mean
went 559 ms → **1,029 ms**. `render/fragments_test.odin` now pins the contract the guard depends on
(an empty toast renders `""`, a spoken one does not), because the failure is invisible from every
direction: no error, no failed request, no log line.

This is the second time this trap has been paid for in this port, and the first time it was silent.

## Compression that nobody asked for

The closed-loop probe reported `GET /` at 3,254 req/s with `Accept-Encoding: br` and 3,262 req/s with
`identity` — the same number for a page that is 20,319 bytes one way and 4,944 the other. The
document was compressed on **every** request and the identity client's copy was then thrown away.
`begin_document` now compresses only when `wants_brotli(request)`, and the identity path went to
**27,708 req/s**, 8.5× what it was doing. Nothing about the compressed path changed.

Worth noting how it was found: it is invisible in a browser (which always asks for brotli), invisible
in the scenario runs (the harness asks for brotli too), and only shows up as *two encodings costing
the same*, which is a shape you have to be looking for.

## Per route, head to head

Closed-loop: no think time, one route at a time, one session, `hey -n 3000 -c 4`, each route run
twice — once with `Accept-Encoding: br` and once with `identity`. **Both servers on one core, in the
same session, on the same client**, so nothing drifts between them (`quizd.exe` with
`GOMAXPROCS=1`).

| route | go, brotli | **tina, brotli** | go, identity | **tina, identity** |
|---|---|---|---|---|
| `GET /` (full page, ~20 KB) | 764 | **3,505** | 1,346 | **27,708** |
| `POST /restart` (full fat morph, ~18 KB) | 634 | **21,625** | 1,843 | **21,520** |
| `GET /filter/preview` | 7,575 | **51,777** | 11,652 | **52,430** |
| `POST /settings` (204 no-op) | 19,853 | **53,350** | 21,471 | **53,646** |

Three readings, in order of how much they should be trusted.

**Uncompressed, this server renders the page 20.6× faster than the Go port** — 36 µs against 743 µs
per response. That is the whole point of the exercise: one shard, no allocation after boot, the
document written straight into an arena the connection slot already owns, and no garbage collector
anywhere near it.

**`POST /restart` is the same number in both columns because this port does not compress SSE at
all.** That is the documented divergence, not a win: Tina's Datastar SDK serialises each event
directly into the connection's egress buffer through `reserve_body_exact`, which is exactly where a
compressor would have to sit, so compressing the streams means serialising the Datastar frames in
this app and keeping the SDK only for `read_signals`. Against the Go port's *compressed* 634 req/s
the 21,625 here is comparing 18 KB on the wire with 4.9 KB on the wire. The honest comparison for
that row is Go's identity column: 1,843 against 21,520, **11.7×**.

**The two right-hand rows are at the client's ceiling, not the server's.** Raising the probe to
`-c 8` moved `/filter/preview` to 62,871 and `/settings` to 63,377, so both are floors. The `GET /`
rows are the only ones where the server is clearly the limit.

Turning the page row into a cost per request (`1/rps_brotli − 1/rps_identity`):

| | go | tina |
|---|---|---|
| `GET /` service time, identity | 743 µs | **36 µs** |
| `GET /` service time, brotli | 1,309 µs | 285 µs |
| compression's share of the response | 43% | **87%** |

Compression is 87% of a page response here — the same finding the Rust port reached (91%) for the
same reason: once the renderer is fast enough, the request *is* the compressor. Moving compression to
a reverse proxy (which a deployment behind nginx is doing anyway, and which would then cache the
pre-compressed assets too) would multiply this route's ceiling by about **8×**.

## Where this server actually stops

Not at a knee. The shard **crashes**. There were two faults; one has a cause and a fix, and one is
still open.

| load (mixed scenarios, one shard) | outcome |
|---|---|
| 400 users, 20/s, 300 s | clean — 24,934 requests, 0 failures |
| 500 users, 40/s, 150 s | clean — 16,062 requests, 0 failures |
| 600 users, 40/s | **shard 0 SIGSEGV at t+14 s**, then quarantine; 54% of requests fail |
| 700 users, 40/s | **SIGSEGV**, 61% fail |
| 1,000 users, 40/s | **SIGSEGV**, 83% fail |

What the log says, every time:

```
[RECOVERY] Shard 0 performing Level 2 recovery (Reason: Signal (SIGSEGV/BUS/FPE))
[RECOVERY] Shard 0 performing Level 2 recovery (Reason: Root Escalate)      x3
[QUARANTINE] Shard 0 recovery requires operator retry. Quarantining.
```

Tina catches the fault, tries to rebuild the shard three times, escalates, and quarantines it. The
**process stays alive** and the port stops answering — `/health` refuses the connection while the
executable is still running and the watchdog still ticking, which is the worst shape a health check
can be in: a supervisor watching the process sees nothing wrong.

It is not the load generator, and it is none of the obvious suspects:

| ruled out by | result |
|---|---|
| 4,096 connection slots instead of 2,048 | dies identically, at the same t+14 s — **not slot exhaustion** |
| the identity build (no brotli linked at all) | dies **sooner**, t+6 s — **not the compressor** |
| the cold-visit scenario alone (no answers, no pauses, no timers) | dies at t+7 s — **not the paused-stream path** |
| `hey -c 300` against `/health`, `/filter/preview`, `/static/*`, `/sfx/*` | all clean |

**A ten-second reproduction:** `hey -n 6000 -c 300 http://127.0.0.1:5061/`. That killed the shard on
its own, while the same command at `-c 16`, `-c 64` and `-c 128` was clean — so the trigger was
concurrency on the **index route** specifically, the one route that renders a per-request document
into the response arena.

### Fault 1: a memo entry allocated in the per-call scratch arena — FIXED

`render.active_topic_names` called `corpus.check_filter(…, context.temp_allocator)`, and inside a
Tina handler `context.allocator` **is** the per-call scratch arena. The filter memo keeps what it is
given: on a miss it cloned the key and stored the `Filter_Check` *in scratch*, and the next request
overwrote both. From then on the memo held a live-looking key whose bytes had changed under it and a
pointer into reused memory, which it handed to later requests as a valid result. It only shows up
under enough concurrency to recycle the arena with different content, which is exactly the shape the
bisection found: `/` faulted, `/filter/preview` (which passed a persistent allocator) did not.

The fix is that `check_filter` takes **no allocator at all** — everything the memo keeps comes from
`system.allocator`, the corpus's own, which lives as long as the process. After it, the `hey`
reproduction above serves 6,000/6,000 at `-c 300` and 30,000/30,000 at `-c 600`, and the whole
connection-churn variant (`-disable-keepalive`) stopped reproducing too.

### Fault 2: a stale I/O completion wipes a live connection's identity — FOUND, and it is in Tina

At **600 users the shard faults about 6 seconds in** — any scenario, one at a time or mixed, with
2,048 or 4,096 connection slots; 400 and 500 stay clean. It needs the plain release build (a `-debug`
build and an `-o:speed -debug` build both survive), and no `hey` shape reproduces it, which is what
made it look like a race in this app. It is not: it is a nil pointer that Tina hands its own handler.

**How it was caught.** Tina's vectored exception handler recovers the shard, so the process never
dies and Windows never writes a dump; `cdb` from the Windows Kits install does not start on this
machine. So a scratch COPY of Tina (`TINA_HOME` pointed at it, the real checkout untouched) got two
diagnostic prints: one in `_vectored_exception_handler` for the exception record, one in the
scheduler for any dispatch that passes a handler a nil message.

```
[FAULT]  code=3221225477 (0xC0000005 ACCESS_VIOLATION) op=0 (read) addr=112 (0x70)
         rip - image base = 0x2f01c
[NILMSG] kind=1 (.Runnable) type=1 (HTTP connection) slot=59
         state=1 (.Runnable) inbox=0 flags=2 (.IO_Completion_Ready) io_kind=0 (.None)
```

`objdump` at that RVA is a function prologue followed by `movzwl 0x70(%rdx),%eax` and a jump table
over message tags — `message.tag`, at offset 0x70 of `tina.Message`, read from a NULL `message`. That
is `_http_connection_handler`, whose first statement is `switch message.tag`.

**The chain.** `_reactor_completion_retire_stale` (`src/io_reactor.odin`) clears the SLOT's I/O
identity when it retires a STALE completion:

```odin
} else if soa_meta[slot_index]._state != .Unallocated {
    soa_meta[slot_index].io_operation_kind = .None      // <- the LIVE operation's kind
    soa_meta[slot_index].io_fd             = FD_HANDLE_NONE
    soa_meta[slot_index].io_slot_index     = IO_SLOT_INDEX_NONE
}
```

Those fields belong to the slot, not to the operation being retired — and the slot has already moved
on, which is exactly what made the completion stale. If a fresh completion was already marked ready,
its kind is wiped while `.IO_Completion_Ready` stays set. `_dispatch_kind_for_slot` needs
`io_operation_kind != .None` to return `.Io_Completion`, the inbox is empty, and the state is
`.Runnable` — so it returns `.Runnable`, and `shard.odin`'s dispatch calls the handler with
`message_pointer = nil`. Access violation, VEH recovery, three escalations, quarantine.

**Two fixes were tried in the scratch copy, and both are informative:**

| candidate | result |
|---|---|
| also clear `.IO_Completion_Ready` in the retire path | flags reach the dispatch as 0 — and the slot is STILL `.Runnable` with an empty inbox, so it still gets a nil message and still faults |
| do not touch a live slot's identity at all | **no fault in 170 s at 600 users** — but half the requests then hang to a 120 s timeout, so that clearing is load-bearing for teardown |

So the fix belongs in Tina and is one of two shapes, ideally both:

1. **The retire path must leave the slot in a state that matches what it is doing** — clear identity
   only when there is no live operation, or restore the waiting state it interrupted.
2. **A `.Runnable` dispatch must never hand a handler a nil message** (or `_http_connection_handler`
   must tolerate one). That is defence in depth: it turns this whole class of scheduler bug into a
   no-op instead of a segfault, and the same nil reaches any user isolate whose handler reads its
   message — this app's store isolate included.

Nothing in this app can prevent it: the app never puts a connection isolate into `.Runnable`.

**Until Tina is fixed, the deployable figure for this port is 500 concurrent players on one shard**,
and everything above it is that defect rather than a capacity limit. The Go port's comparable ceiling
was ~3,850 users on one core, and the Rust port's ~4,300; this port's ~500 is not a measurement of
the same thing, and should not be quoted as one.

## Phase I: the sessions in an isolate, and what the round trip costs

The question this phase exists to answer: a session touch used to be a map lookup on the shard that
was already running the handler. Above one shard it cannot be — Tina shards share no memory, and
nothing routes a browser to a shard (`Reuse_Port` lets the kernel place each connection, coordinator
mode hands the FD to whichever shard the dispatcher picks; neither reads a cookie). So the store
becomes an isolate, and every session touch becomes a send, a park, a scheduler turn and a resume.
**What does that cost?**

### It costs more than the work it protects, at one shard

Measured by making every session touch go through the isolate, on the single shard this platform can
run:

| 400 users, 200 s, mixed scenarios | requests | P50 | P90 | failures |
|---|---|---|---|---|
| session touch as a message (isolate) | 4,158 | 1 ms | 53,000 ms | 0, but a fifth of the run stalled |
| session touch as a call (local store) | **16,191** | **1 ms** | **2 ms** | **0** |

The tail is the whole story: the median request is unaffected, and a fifth of them stop dead. The
asset routes stayed at 1 ms throughout while every session-touching route sat at 50-60 s, and the
server accumulated 278 sockets in `CLOSE_WAIT` — connections parked on an answer, with the client
giving up first. The store itself was innocent and said so: its own counters (now on `/health`)
showed `acquires == answered == releases`, no queueing and no failed sends, for every request that
reached it. What did not reach it is the point.

So the shipped design keeps **one seam and two transports**: `session/store_protocol.odin` holds the
operations, and they are called directly when the process runs one shard and by message when it runs
more. The routes do not know which — `acquire_here` answers immediately or says "ask the isolate",
and both paths converge on `build_and_run`.

### A pointer in a message, and the lease that makes it safe

An acquire replies with a POINTER into the store's shard, which is a deliberate exception to
shared-nothing. It is safe because the session is **leased** while a caller holds it: no second
caller is given the same session, and the sweep will not delete it. The lease is taken and released
inside ONE handler call, because this app mutates a session once, before the first byte of the
response — which is also why the pauses that follow do not hold it.

Two decisions came out of measurement rather than design:

- **A busy session queues rather than retries.** The first version answered `busy` and the caller
  parked a millisecond and asked again. With four connections on ONE session that served **73
  requests a second**; the same probe over a store-side wait queue serves **46,000-54,000**. The
  caller is already parked on its reply, so the store can simply answer it later — the release hands
  the lease straight to the first waiter, so a latecomer cannot overtake a queued caller.
- **The held countdown never takes a lease.** It reads one integer ten times a second per open tab;
  leasing for that would make the busiest sessions in the process unavailable for a read. It sends
  `TAG_PEEK_TIME` and the store computes the number on its own shard.

### The cross-shard proof, since the HTTP server cannot be one

**Tina's HTTP server is single-shard on Windows.** `install_into_system_spec` asserts it — *"HTTP v1
multi-shard mode is unsupported on Windows (Tina core lacks cross-shard FD handoff)"* — and
`SO_REUSEPORT` does not exist here either, so neither ingress mode has anything to stand on. The app
refuses `DSQUIZ_SHARDS > 1` on this platform with that reason rather than letting an assert inside
the framework do it.

Tina's **core** is not single-shard, though; only the FD handoff is missing. So `just shardcheck`
runs the real store isolate on shard 0 and drives it from a prober on every shard, with no HTTP
anywhere: each prober runs 200 rounds of acquire → release → acquire-the-shared-session → release →
peek, and every shard fights over one session on purpose.

| shards | rounds | failures |
|---|---|---|
| 4 | 800 | **0** |
| 10 (this project's ceiling) | 2,000 | **0** |

The probers assert what the design claims: the pointer that came back names the session they asked
for, it is leased when they get it, and no two shards hold it at once. Ten is the ceiling because a
Tina shard spins a whole core at idle (below) — ten shards is ten cores of this box burning to prove
a protocol.

### What is still unproven

The multi-shard **HTTP** path — `ingress_mode = .Reuse_Port`, several listeners, connections landing
on any shard — is written and compiles, and nothing on this machine can run it. That is the honest
state of phase I: the app-side work is done and portable, the protocol is proven across shards, and
the platform is what is missing.

## CPU: the axis that does not transfer

Tina's shard loop is `for { scheduler_tick(shard) }` with no blocking wait anywhere in it — the I/O
service point is skipped entirely when nothing is in flight (`io_awaiting_count > 0`), and there is
no park, no sleep and no completion-port wait to return to. So:

| | server CPU |
|---|---|
| idle, serving nothing | **1.049 cores** |
| 400 users, mixed scenarios | 0.994 cores |

**A shard costs one core whether or not anybody is using it.** That is a run-to-completion design
choice, not a bug, and it is where the P50 of 1 ms comes from — no syscall stands between a packet
and the handler. But it means the metric both other ports were compared on (Go: 0.253 cores at 1,000
users; Rust: 0.223) **cannot be computed for this one**: utilisation is 100% at every load, so CPU
time says nothing about headroom, and the only instruments left are latency, achieved throughput and
the failure point.

Two consequences for a deployment. Density is per shard, not per request: four shards is four cores
before any traffic. And an idle instance costs the same as a busy one, which inverts the usual
autoscaling argument.

## Memory

Everything is reserved at boot, and the size is a straight line in the connection-slot count:

| connection slots | grand arena requested | RSS (working set) | private bytes |
|---|---|---|---|
| 128 | 22 MB | 45 MB | 52 MB |
| 512 | 90 MB | 113 MB | 120 MB |
| 1,024 | 181 MB | 204 MB | 211 MB |
| 2,048 | 362 MB | 385 MB | 392 MB |
| 4,096 | 724 MB | 747 MB | 755 MB |

That is **~176 KB per connection slot** — the 63 KB egress buffer plus the 56 KB response arena plus
Tina's own per-slot working memory — and about 23 MB of everything else (the corpus, the sounds, the
pre-compressed assets, the executable). A slot is a pre-allocated isolate, not a soft limit: this
many connections can exist and the rest are shed.

Under load it does not move: 207 MB at rest and 216 MB peak with 400 players (1,024 slots). The Go
port's equivalent went 171 → 278 MB at 1,000 users *after* its brotli pooling fix, and 506 MB before
it. This port cannot have that bug: the encoder is created once at boot with an arena-backed
allocator and cannot allocate outside the memory this app hands it.

Compiling brotli in costs **+6 MB RSS / +10 MB private** at 512 slots — the 8 MB encoder arena, a
128 KB scratch buffer and the second copy of every pre-compressed asset. The arena was sized by
measurement rather than by fear (it was 24 MB while the encoder was being debugged):

| input | encoder high-water |
|---|---|
| 24 KB (the fat morph) | 0.99 MB |
| 128 KB | 1.82 MB |
| 901 KB (`completed.jpeg`, the largest asset) | 3.81 MB |
| 2 MB | 6.80 MB |

Brotli's ring buffer grows with the input, so it is the largest *asset* that sets the size, not the
largest response. `test_the_largest_asset_fits_the_arena` pins it, because the failure mode is
silent: the arena reports `spent`, compression fails, and every client quietly gets identity.

## Compression, and what is actually on the wire

| | bytes | |
|---|---|---|
| index document, identity | 20,319 | Go's is 20,268 for the same page |
| index document, brotli q5 | 4,944 | **4.1×** |
| `bulma.min.css`, identity | 677,931 | |
| `bulma.min.css`, brotli q5 | 42,757 | **15.9×**, compressed once at boot |
| one interaction (`POST /skip`, fat morph) | 17,999 | **uncompressed — see below** |
| assets pre-compressed at boot | 9 files, 999 KB saved | ~300 ms of startup |

Ratios are in line with the others (Go's fat patch 27,709 → 4,935, the python's 23.6 KB → 4,069).
Pre-compressing the static assets once at boot rather than per request is the one place this port
beats the other three outright rather than matching them; the python and Go pay quality-5 brotli for
678 KB of Bulma on every cold visit that misses a proxy cache.

**The SSE streams are not compressed**, and that is a real divergence from the comparison's ground
rules rather than an oversight — the reason is structural and is written up in `web/compress.odin`
and in the README. It is why `POST /restart` above must be read against Go's identity column, and it
is worth ~3.6× on the wire for every interaction.

## Corpus and boot

| | python | go | **tina** |
|---|---|---|---|
| parse + prepare both systems | ~5.5 s | ~70 ms | **48–62 ms** |
| auctions | 7,627 + 1,652 | same | 9,279 across 2 systems |
| sounds synthesised at boot | 5 | 5 | 5 |

Primed at boot, never lazily, in every port — the ground rules ask for it, and on the python that
5.5 s used to land inside a request, on the first visitor to open the second system.

## What is not measured here

Named so the gaps are not mistaken for findings:

- **The held-timer scenario** (`DSQUIZ_TIMER=stream`, a signal patch every 100 ms per open tab).
  Go ran it at 400 mixed users; this port has not, and it is the axis where a
  one-core-per-shard runtime should look best.
- **A saturation ramp.** There is nothing to ramp into: the server faults between 500 and 600 users,
  so the "where one core saturates" table the other two ports have cannot be built until that is
  fixed.
- **Microbenchmarks** — `check_filter("1C")` over 7,627 auctions (python 15.8 ms, Go 0.38 ms), the
  memo hit rate, `answer` and `new_question`. There is no benchmark harness in this project yet;
  `odin-skel add bench` installs one.
- **Multi-shard HTTP.** Phase I is built and the protocol is proven across shards
  (`just shardcheck`), but Tina's HTTP server is single-shard on Windows, so the thing that cannot be
  measured here is a real request landing on shard 3. Note the CPU section before wanting it: N
  shards is N cores at idle, and Go's own conclusion at this load was that the other 23 cores bought
  nothing.

## Caveats

- Loopback only, and the load generator shares the machine with the server.
- `req/s` in the scenario tables is scenario-bound, not server-bound. The `hey` table is closed-loop
  and its two small routes are client-bound; only `GET /` there is clearly server-limited.
- The python and Rust columns are from their own documents, measured on this machine but not on this
  day and not interleaved with these runs. **The Go column in the per-route table was measured
  interleaved with this one, on the same client, and is the valid comparison**; the Go figures in its
  own RESULTS.md are higher because that run had the machine to itself.
- RSS on Windows is not like-for-like against a python process's RSS.
- `POST /answer` numbers are TTFB — locust stops its clock at the headers on a streamed response, in
  every column — and the whole-stream mean is reported separately.
- The harness counts **204 as success**: it is this app's deliberate no-op (a skip with none left,
  Next off a reveal, a settings post that changed nothing), not an error.
