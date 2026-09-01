# dsquiz-tina — handoff

★★ **Read this first, then `README.md`.** The README is the as-built record and the measurements;
this file is what is left to do and everything a cold start needs to do it.

State at handoff: **phases A–I complete as far as this platform allows.** The quiz plays, brotli
works, the sessions live behind the phase-I protocol seam, `RESULTS.md` holds the numbers.
`just dstina qa` is clean — format, both lints, 73 tests across seven packages — and
`just dstina shardcheck 10` passes. Everything is UNCOMMITTED.

**One open defect, and it is TINA's, not this app's: the shard SIGSEGVs at ~600 concurrent users,
about six seconds in.** Any one scenario does it; 400 and 500 users are clean.

```shell
just dstina serve-brotli
DSQUIZ_PERF_HOST=http://127.0.0.1:5061 just dsperf headless 600 40 150
# [RECOVERY] Shard 0 ... (Reason: Signal (SIGSEGV/BUS/FPE)) -> [QUARANTINE], and the port stops
# answering while the PROCESS stays up and the watchdog keeps ticking.
```

**Root cause, found and evidenced** (RESULTS.md, "Fault 2", has the full chain):
`_reactor_completion_retire_stale` in `~/dev/tina/src/io_reactor.odin` clears the SLOT's I/O identity
(`io_operation_kind`, `io_fd`, `io_slot_index`) while retiring a STALE completion. Those fields belong
to whatever the slot is doing NOW. If a fresh completion was already marked ready, its kind is wiped
while `.IO_Completion_Ready` stays set; `_dispatch_kind_for_slot` can then no longer return
`.Io_Completion`, the inbox is empty and the state is `.Runnable`, so the scheduler dispatches
`.Runnable` — **with `message_pointer = nil`** — and `_http_connection_handler` dereferences
`message.tag` (offset 0x70) on its first line.

Captured from a scratch copy of Tina with two prints added (the real checkout was never touched):

```
[FAULT]  code=0xC0000005 op=read addr=0x70   rip-base=0x2f01c  -> movzwl 0x70(%rdx) at a prologue
[NILMSG] kind=.Runnable type=connection state=.Runnable inbox=0 flags=.IO_Completion_Ready io_kind=.None
```

Two fixes were tried there: clearing the ready flag as well still faults (the slot is still
`.Runnable` with nothing to deliver), and not touching a live slot's identity stops the fault for
170 s at 600 users but hangs half the requests, so that clearing does serve teardown. The fix is
Tina's to make: the retire path must leave the slot in a state matching what it is doing, and
`.Runnable` should never hand a handler a nil message. **Nothing in this app can prevent it** — and
note the same nil would reach the store isolate's handler, which also reads `message.tag` first.

The diagnostic copy is disposable: `cp -r ~/dev/tina <scratch>/tina-diag`, patch
`_vectored_exception_handler` (`sys_signals_setup_windows.odin`) to print the exception record and
`shard.odin` line ~1219 to print the dispatch kind when `message_pointer == nil`, then build with
`-collection:tina=<scratch>/tina-diag`.

**The fault that WAS fixed, because the shape recurs:** the filter memo was being handed
`context.temp_allocator`, and inside a Tina handler that IS the per-call scratch arena, so a memoised
entry was dangling before the next request — while still being found by its key. `check_filter` now
takes no allocator at all; everything the memo keeps comes from `system.allocator`. Anything that
outlives a handler call and is not in the response arena wants the same audit.

---

## Where to stand up

```shell
just dstina serve            # port 5061; python 5008 and go 5060 can run alongside
just dstina qa               # format, lint, lint-strict, test-all
just dstina serve-debug      # bounds checks, backtraces, tracking allocator
DSQUIZ_TIMER=stream just dstina serve    # the held-SSE countdown
DSQUIZ_DEBUG=1 just dstina serve         # arms the debug panel without ?debug
```

Needs a tina checkout at `~/dev/tina` (`TINA_HOME` overrides). Pinned in this session against
`a2e8d4d`; if tina has moved, re-bisect the egress ceiling (below) before trusting the constant.

Two smoke scripts from this session are worth recreating if they are gone — they live in the
scratchpad, not the repo:

- a curl loop over every route asserting status codes and SSE event counts;
- `apps/datastar-quiz/tools/measure.py --base http://127.0.0.1:5061`, which is the python's own
  instrument and the honest pacing gate.

**Test SSE with curl, never `urllib`/`httpx` defaults.** `urllib` sends `Connection: close`, Tina
honours it (`_connection_continue_after_non_final_flush` finalises instead of dispatching
`Send_Ready`), and a perfectly healthy paced stream then looks like it dies at its first flush. This
cost an afternoon twice.

---

## Phase G — brotli: DONE

It works. The blocker was the staged library, not the bindings, the linker or Odin: the MSVC
static-CRT (`/MT`) build that `just build-brotli` produces had been staged into `target/brotli/` but
never retested. With it, `-define:DSQUIZ_BROTLI=true` boots, pre-compresses 9 assets at boot (999 KB
saved, ~300 ms), serves every route, and the compressed page decodes byte-identical to the identity
one. Do not re-run the ruled-out table that used to live here — GNU `.a`, `/MD`, `msvcrt.lib`,
`core:c/libc` — the answer is `/MT`, and `just build-brotli` already asks for it
(`CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded`).

`ARENA_SIZE` is **8 MB**, down from the 24 MB it was raised to while the encoder was being debugged.
Brotli's ring buffer grows with the input, so it is the largest ASSET that sets it, not the largest
response: 901 KB of `completed.jpeg` peaks at 3.81 MB (the measured table is in `brotlienc.odin` and
`test_the_largest_asset_fits_the_arena` pins it). Beyond the arena the encoder refuses to start and
the caller serves identity — a bounded refusal rather than a reach for the heap, which is the whole
reason the allocator callbacks exist.

Two things were fixed here that only a measurement would have found, both written up in
`RESULTS.md`:

- **Every CORRECT answer truncated its own stream.** The script's last entry is
  `Toast{text = "", pause = 1.0}`, `render.toast` renders nothing for it, the SDK refuses an empty
  payload, and the handler closed — losing the final pause, the toast clear AND the fat morph, with
  no error and no failed request. `push_elements` now drops an empty payload; `render/fragments_test.odin`
  pins the contract.
- **The document was compressed for clients that asked for identity**, then thrown away.
  `begin_document` now compresses only when `wants_brotli(request)`; `GET /` with identity went
  3,254 → 27,708 req/s.

**Still true: SSE streams are not compressed.** Tina's Datastar SDK serialises each event directly
into the egress buffer via `reserve_body_exact`, which is where a compressor would have to sit.
Compressing them means serialising the Datastar frames in this app and keeping the SDK only for
`read_signals` — a contained change (`web/stream.odin` already holds the whole event script as data)
that trades away the SDK. It costs ~3.6× on the wire per interaction, and `RESULTS.md` records it
as a divergence and reads `POST /restart` against the Go port's identity column because of it.

## Phase H — measurement: DONE, with one gap the defect owns

`RESULTS.md` is written. Headline numbers, all against the brotli build, one shard:

- 400 users: P50 1 ms, P95 2 ms, 0 failures, SSE choreography mean 1.029 s (Go 1.004, python ~1.1).
- 500 users: still 0 failures, but the tail moves — P95 15 ms, and `GET /` P50 12 → 34 ms.
- Closed-loop, interleaved with a `GOMAXPROCS=1` Go server on the same client: `GET /` **27,708
  req/s identity** against Go's 1,346 (20.6×), 3,505 against 764 compressed. Compression is 87% of
  a page response.
- RSS is ~176 KB per connection slot, reserved at boot, and grows 9 MB under 400 users.
- **A shard costs one core idle** — `for { scheduler_tick() }` never blocks. Measured 1.049 cores
  serving nothing. The "server CPU" axis the Go and Rust columns were compared on cannot be computed
  for this port, and N shards is N cores before any traffic.

What is missing, and why: the **held-timer scenario** (`DSQUIZ_TIMER=stream`) has not been run, and
the **saturation ramp** cannot be built until the crash is fixed — there is nothing to ramp into.
**Microbenchmarks** (`check_filter("1C")` over 7,627 auctions: python 15.8 ms, Go 0.38 ms) need a
harness; `odin-skel add bench` installs one.

Instruments, all in the scratchpad rather than the repo, and worth recreating there:

```shell
hey -n 3000 -c 4 -H "Cookie: $SID" -H "Accept-Encoding: br" http://127.0.0.1:5061/   # per route
DSQUIZ_PERF_HOST=http://127.0.0.1:5061 just dsperf headless 400 20 300               # scenarios
```

**Use `hey` or `curl`, never a python socket loop, for the uncompressed routes.** A hand-rolled
python probe caps out around 3,000 req/s and silently reported the CLIENT's ceiling — it is what hid
the redundant-compression bug above, by reporting brotli and identity as equally fast.

## Phase I — the session store as an isolate: DONE, minus the platform

The seam is `session/store_protocol.odin`: the operations (`acquire`, `release`, `peek_time`, the
lease, the wait queue) as plain data and plain procedures, with no framework in them and nine tests
over them. `web/store_isolate.odin` is the mailbox around it — one isolate on shard 0, owning the map
that every shard needs and no shard may touch directly.

**Two transports, one seam, and that is deliberate.** At one shard the store is on the calling thread
and the routes call it directly (`acquire_here`); above one shard they send `TAG_ACQUIRE` and park.
The measurement that forced it is in `RESULTS.md`: routing every session touch through the isolate on
a single shard took the standard 400-user run from 16,191 requests to 4,158, with a fifth of them
stalling and 278 sockets left in `CLOSE_WAIT` — while the store's own counters showed it had answered
every request that reached it. Do not "simplify" that back into one transport without re-running
`just dsperf headless 400 20 200`.

Three things worth knowing before touching it:

- **The lease is what makes a pointer in a message safe.** An acquire replies with a pointer into the
  store's shard; the session is leased while the caller holds it, so nobody else is inside it and the
  sweep leaves it alone. It is held for ONE handler call — this app mutates a session once, before
  the first byte — and `release_session` is on every exit path, including the failures.
- **Busy queues, it does not retry.** The first version parked a millisecond and asked again: four
  connections on one session served 73 requests a second. The store-side queue serves 46,000-54,000.
  The release hands the lease straight to the first waiter.
- **An answer carries the tag of the QUESTION.** `http.expect_reply` records the tag it sent as the
  one it will accept back, so a reply under its own `TAG_ACQUIRED` is ignored and the caller times out
  two seconds later with a healthy store sitting there. That cost an afternoon; the comment in
  `web/store_isolate.odin` is there so it costs nobody else one.

**What cannot be run here.** Tina's HTTP server is single-shard on Windows —
`install_into_system_spec` asserts it ("Tina core lacks cross-shard FD handoff") and there is no
`SO_REUSEPORT` on Windows either, so `.Reuse_Port` and `.Coordinator` both have nothing to stand on.
`shard_count_from_environment` refuses `DSQUIZ_SHARDS > 1` there with that reason. The multi-shard
HTTP path is written and compiles; a Linux box is what it needs.

**What IS proven across shards:** `just shardcheck [n]` (default 4, max 10) boots the real store
isolate on shard 0 and drives it from a prober on every shard with no HTTP anywhere — 200 rounds each
of acquire/release/acquire-the-shared-session/release/peek, every shard fighting over one session on
purpose. 4 shards: 800 rounds, 0 failures. 10 shards: 2,000 rounds, 0 failures. Ten is the ceiling
this project runs, because a shard spins a whole core at idle.

Also part of this phase, and load-bearing above one shard:

- `corpus/cache.odin` — the filter memo is now `@(thread_local)`, one per shard, indexed by
  `System.cache_slot`. A `System` is shared and never written; a memo is written on every miss.
- `web/compress.odin` — the brotli arena and output buffer are `@(thread_local)` and built lazily on
  first use, because a shard cannot be reached before `tina_start`.
- `web/stream.odin` — `current_state` is `@(thread_local)`.
- `session/session.odin` — the question nonce is process-wide ON PURPOSE, so it is atomic rather than
  thread-local: a per-shard counter would hand two sessions the same nonce again.

## The three ceilings, and how they were found

All of them are `u16` in somebody's struct. Each is a constant in the source with its measurement
beside it; re-derive them if tina moves.

**Egress buffer: 64768, not 65535.** `response.odin` asserts `HTTP_EGRESS_BUFFER_SIZE <= max(u16)`,
which reads like 65535, but `server.odin` requires the whole `HTTP_Connection` — connection state
plus the trailing egress buffer — to fit the u16 `payload_offset` space. Bisected: 64768 builds,
64769 fails. Connection state is 767 bytes. The justfile compiles in **64512**, that ceiling with
256 bytes of slack.

**Route state: also u16.** `state_size` on a route registration caps `Stream_State` — the response
arena, the step array and the cursors — at 65535. `RESPONSE_ARENA_SIZE` is **56 KB**.

**Datastar events are atomic.** The SDK serialises each into one exact `reserve_body_exact`
reservation. An event that does not fit is refused, not truncated — which is why the fat morph
(~23.6 KB) forces the buffer near its ceiling.

---

## Traps already paid for

Each of these cost real time and is commented where it bites.

**Scratch is reset before every handler call.** A response outlives the call that started it: the
document is rendered on `Request_Start` and written over many `Send_Ready`s. Anything held in
`context.temp_allocator` across that boundary dangles, and because the arena is a bump allocator that
silently stops, the symptom is a page truncating mid-attribute at 12,832 bytes — not a crash.
Response-lifetime memory comes from `response_arena()`, an arena the route state owns.
`tina.ctx_working_arena()` is the other obvious answer and is wrong: that is tina's own per-connection
memory, sized for the request frame, and about 24 KB.

**`patch_elements` refuses an empty payload** unless the mode is `.Remove`. The python and the Go
port both clear `#sfx` and `#toasts` by patching empty elements with mode `inner`; here the handler
closes on the error and the stream just stops. That is not only a clearing problem: the toast script's
trailing beat is `Toast{text = "", pause = 1.0}` and `render.toast` renders nothing for it, so EVERY
CORRECT ANSWER ended its stream one step early -- no final pause, no toast clear, no fat morph -- with
no error anywhere and the load harness recording a success. `push_elements` now drops an empty payload
rather than pushing it, so a step that renders nothing contributes its PAUSE and nothing else. `clear_toasts` / `clear_sfx` / `clear_topics_status`
replace the element with an empty one under `.Outer`, carrying its own attributes — dropping
`aria-live` or `hidden` in that replacement would be a silent regression.

**A fixed-length body must match its Content-Length exactly.** Tina asserts it; the panic kills the
connection isolate, so the symptom is a connection reset, not a short response. Choosing the body and
declaring the length must be one statement. This bit three times — the document, the assets and the
sounds — each time because an edit landed on one half.

**`state^ = Stream_State{}` zeroes the response arena** if the document has already been rendered
into it. Reset the cursor, not the struct.

**A package-level `current_state`** is what `response_arena()` reads. Routes that do not use a
`Stream_State` — the held timer, the asset streams — never set it, so it can hold the previous
request's; allocating from an uninitialised arena panics the shard. The guard in `response_arena()`
is load-bearing, not defensive noise.

**odinfmt reformats between edits.** Several scripted `replace` calls silently did not match because
the target text had been reflowed onto one line. Anything applied with a string replace needs its
result grepped, or the edit lands nowhere and the failure shows up as a runtime reset.

---

## Layout

```
main.odin        skeleton's operational setup: tracking allocator, backtraces, logger
quizd.odin       entry point; hands to web.serve
bids/            588 + 395t   the call model, a port of bmlbids.py. Bid is 6 bytes, no pointer
bidfilter/       716 + ...    pattern language, matcher, relative-call resolution
flat/            groups stored end to end -- two allocations per auction, not one per position
corpus/          embedded JSON, variants, the PER-SHARD memoised filter, the goldens test
engine/          438 + 364t   points, streak, toasts, milestones -- no HTTP, no HTML
session/         the (sid, variant) store, the lease and the wait queue -- the phase-I seam, framework-free
render/          the HTML writers, the signal payloads, the naming transform
sfx/             five WAVs synthesised at boot -- no audio files in any of the four ports
brotlienc/       C encoder bindings with arena-backed callbacks
web/             routes, the SSE choreography, the response arena, content encoding, the store ISOLATE
shardcheck/      the cross-shard proof: the real store isolate, a prober per shard, no HTTP
```

## Parity artefacts

- `testdata/filter_goldens.json` — 132 probes, byte-identical to the Go and Rust trees. All pass,
  digests included. A hit count alone would not notice two auctions swapping in and out.
- `testdata/topic_names.json` — 36 topic names → slug and signal key. All pass, plus every topic name
  in the corpus. That transform is silent when wrong.
- Regenerate with `just dsgo export-corpus`, which shells into the python. **Note:** both exporters
  hard-code the *golang* tree as their output, so the Rust and Tina copies are manual and go stale
  after a `.bml` edit. `topic_names.json` has no producer script at all, in any tree. Worth fixing
  once, in `apps/datastar-quiz/tools/`.
