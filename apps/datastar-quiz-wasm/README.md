# datastar-quiz-wasm — the quiz with no server

The bidding quiz as **one self-contained HTML file** (~800 KB). Email it, put it on a USB stick or a
static host, or open it straight from disk: no server, no install, no network except for the
"System Notes" panel, which embeds the published notes from `sublime.is`.

```shell
just dswasm page     # -> apps/datastar-quiz-wasm/dist/bridge-quiz.html (both systems)
just dswasm template # -> dist/quiz-template.html, the same page with an EMPTY corpus slot
just dswasm test     # the routes, headless in node
just dswasm serve    # localhost:5090, for tools that refuse file:// (playwright does)
```

`bridge-quiz.html?swedish` opens the Swedish Club variant and `?debug` arms the debug panel, as on
the servers.

## The template, and the notes workbench

The corpus is NOT compiled into the module. The page carries it as JSON beside the module
(`<script id="quiz-corpus">`), and `host.js` hands it over system by system (`qz_add_system`, then
`qz_start`). So one build of the module serves any corpus, and `just dswasm template` writes the page
with the corpus left out: the text `/*QUIZ_CORPUS*/`, exactly once. To fill it, replace that text with a
JSON array of systems in the exporter's shape, with every `</` written `<\/`.

That is what the notes workbench's `quiz` button does, for whichever `.bml` file it has open: it reads the
bid tables out of its editor buffer (its `quiz_corpus` package, held to the python extraction over every
file in the corpus) and writes `<file>-quiz.html`. The workbench BUNDLES the template, from a vendored
copy in the notes repo, so its users need nothing set up. **After changing this app, run
`just dswasm vendor-template`** (it rebuilds the template and copies it to
`$BRIDGE_SYSTEM_HOME/deal-simulations/odin-sims/ui/quiz-template.html`), then rebuild the workbench. Its
settings can also point at `dist/quiz-template.html` directly, to try a build before vendoring it.

The wasm build is not byte-reproducible (the compiler lays data out differently from run to run), so
every vendor shows as a ~660KB change there - vendor when the app changed, not as a routine step.

A generated quiz has one system. Its topics are the `.bml` file's own `#+TOPIC:` lines plus a generic
default set, and this page keeps ONLY the topics whose filter selects enough auctions to quiz on
(`quizzable_topics` in `src/main.odin` - the matcher lives here, not in the workbench), so a generic topic
appears only where it means something. A system can also carry its notes as a whole html document
(`system_notes_html`); `host.js` lifts that out before the engine sees the corpus and gives the "System
Notes" panel a blob of it, which is what `system_notes_url` = `/__quiz/notes/<i>` names.

## How it works

Every other port is a server that Datastar talks to over SSE. This one moves the server into the
page, and changes nothing else:

- **The Odin packages are the tina port's, imported rather than copied** (`-collection:quiz=
  ../datastar-quiz-tina`): `bids`, `bidfilter`, `corpus`, `engine`, `session`, `render`, `sfx`. They
  compile to `js_wasm32` unchanged, and `corpus.load_sources` (added for this) loads systems from
  JSON at runtime; the embedded corpus is never referenced, so it is not in the module.
- **`src/` replaces `web/`**: the same route builders, which mutate the session once and describe the
  response as a script of patches and pauses, with the HTTP taken out. `qz_request` takes a request
  as a string and returns the script in Datastar's SSE wire format, a pause written as a NUL-framed
  millisecond count between events.
- **`host/host.js` replaces `window.fetch`** for URLs under the module's mount point (`/__quiz/...`).
  The answer comes back as a streamed `text/event-stream` response with its pauses waited out, which
  is all Datastar can see of a server. **Datastar is the published v1.0.2, unchanged**, and so is the
  markup `render` writes.
- **`tools/build_page.py` inlines everything**: the wasm module (gzipped, base64, unpacked with
  `DecompressionStream`), Odin's `odin.js` runtime (read from the toolchain so it always matches the
  compiler), the host, Datastar, the stylesheets, and the finale photo resized to the width it is
  shown at. A `file://` page may not fetch even a file next to it, so nothing can be left outside.

Measured headless: the module boots (corpus parsed, filter index built) in ~90 ms, renders the page
in ~3 ms, and answers a question in ~1 ms. The module is 368 KB (133 KB gzipped); the template is
658 KB, and the page with both systems 1.4 MB, most of it the corpus JSON.

## Where it deliberately differs from the servers

- **Restart takes the filter as typed.** On the servers (and the python reference) a filter typed but not
  applied with Enter is ignored by Restart, which restarts on the filter in force while the box shows the
  new text - it reads as "the filter does not work". Here Restart applies a pending filter first, exactly
  as Enter would. Pinned by the smoke test.

## Things that cost time, written down

- **Odin compiles `_test.odin` files in ordinary builds.** Their `core:testing` import pulls in
  `core:os`, which fails at compile time on `js_wasm32`. The six test files in the tina port now start
  with `#+build !js`; their native tests still pass (bids 27, corpus 4 incl. the filter goldens,
  engine 21, render 6, session 9).
- **`runtime.heap_allocator()` does not exist on `js_wasm32`.** It asserts on the first allocation.
  `session.store_allocator()` returns it, so the routes here use the module's default allocator
  instead (`session_allocator` in `src/routes.odin`).
- **Asset URLs are rewritten in the TEXT, never on the live DOM.** A `MutationObserver` mapping
  `href`/`src` to blob URLs hung the tab: Datastar re-applies `data-attr:href` when the attribute
  changes, the observer changed it back, and the two took turns forever. The text is the page plus
  every streamed patch, since the finale's picture arrives in one.
- **`core:net` does not build for `js_wasm32`**, so `src/script.odin` has its own percent-decoding for
  a GET's `?datastar=` signals.

## Limits

- **One player, one tab.** There is one session per variant, held in the module's memory. A reload
  starts a new quiz; nothing is persisted yet.
- **The corpus is frozen when the page is made.** For `just dswasm page` it is the tina port's copy. After editing a `.bml`
  file: `just dsgo export-corpus` (writes the Go port's `internal/corpus/data/*.json`), copy those two
  files into `apps/datastar-quiz-tina/corpus/data/` (no recipe does that copy yet; the files are
  byte-identical today), then `just dswasm page` again.
- **The stylesheet picker is disabled** (it is a `?debug` affordance). Datastar builds that URL from a
  signal, which a literal rewrite cannot reach, so the page keeps the default Pico sheet.
- **The theme choice is not remembered on `file://`.** It lives in a cookie, and Chrome gives a
  `file://` page none. It works from a web host.
