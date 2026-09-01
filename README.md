# bridge-system-apps

Applications built on the **BML** bridge bidding system: a Panel bidding quiz, a standalone
point-count analysis, and six ports of the same datastar/hypermedia quiz — Python, Go, Rust, F# and
Odin on two different HTTP runtimes — kept side by side as a runtime comparison.

These were split out of [bridge-bidding-system](https://github.com/enerqi/bridge-bidding-systems),
which still owns the `.bml` system notes, the BML → HTML build and the deal simulations. That repo
remains a runtime dependency of the Python apps; nothing here builds or edits the notes.

## The apps

| just module | directory | stack | port |
|---|---|---|---|
| — | `apps/quiz` | Python, Panel/Bokeh — the original quiz | 5006 |
| — | `apps/optimal-point-count` | Python, Panel — honour-combination analysis | — |
| `dsquiz` | `apps/datastar-quiz` | Python, litestar + uvicorn/granian — the reference port; owns the BML parser and the corpus exporters | 5008 |
| `dsgo` | `apps/datastar-quiz-golang` | Go, `net/http` + datastar-go | 5060 |
| `dstina` | `apps/datastar-quiz-tina` | Odin, tina http — shared-nothing, thread-per-core, no allocation after boot | 5061 |
| `dsoh` | `apps/datastar-quiz-odin-http` | Odin, odin-http — everything but `web/` is the tina port's source unchanged, so the pair isolates the HTTP runtime and nothing else | 5062 |
| `dsrs` | `apps/datastar-quiz-rust` | Rust, tokio + axum + datastar-rs | 5070 |
| `dsfs` | `apps/datastar-quiz-fsharp` | F#, Oxpecker + StarFederation.Datastar.FSharp | 5080 |
| `dsperf` | `apps/dsquiz-perf` | locust harness, run against any of the above | — |

The ports use distinct default ports (`DSQUIZ_PORT` overrides) so they can run side by side.
Each port's own `README.md` — and `RESULTS.md`, where present — has the measurements and the
question that port exists to answer.

## The corpus, and the one cross-repo dependency

The `.bml` corpus is **not in this repo**. The Python quiz parses it directly; the compiled ports
embed a JSON corpus exported from that Python app.

`BRIDGE_SYSTEM_HOME` points at the notes checkout — default
`~/docs/bridge/bridge-bidding-system`. The root `justfile` exports it as `BML_DOCS_DIRECTORY`, which
is the override `quiz.py` honours; without it `quiz.py` falls back to two levels up from
`apps/quiz/`, which here is the repo root, where there is no corpus. A root `export` reaches module
recipes too, so `just dsquiz test` is covered as well as `just quiz`.
`apps/datastar-quiz/justfile` defines it again so that app also works when run from its own
directory; both read the same env var, so they cannot disagree.

**The compiled ports need none of this at runtime** — their corpus is embedded, so they build, test
and serve with no notes checkout present. Only the export needs it:

```shell
just dsgo export-corpus    # re-runs the python exporters, rewrites the Go corpus + goldens
just dsrs export-corpus    # same, then copies the identical bytes into the Rust port
just dsfs export-corpus    # pulls from the Go port's data
```

Run those after editing a `.bml` file or a topics toml over in the notes repo, then re-run the
ports' tests. The goldens — 132 filter probes across both bidding systems, each recording a status
and a digest of the exact auctions selected — are what hold the ported matchers to the Python
reference.

## Requirements

- **[uv](https://docs.astral.sh/uv/)** — Python is pinned to 3.14; run all Python through `uv run`.
- **[just](https://just.systems)** 1.49+ — the root `justfile` runs recipe lines through `cmd.exe` on
  Windows and `bash` elsewhere, and uses `[script]` recipes (python, via `uv run --no-project`) for
  anything with logic. Each app's justfile picks its own shell the same way.
- **bridge-bidding-system** checkout — see above. Needed by the Python apps and the corpus exporters.
- **BML tools** — `enerqi/bml`, located via `BML_TOOLS_DIRECTORY`, else `~/dev/bml`. Provides the
  `bml` module `quiz.py` imports and `bmlbids.py`, the shared model of a bridge *call*.
- Per-port toolchains, each needed only for its own port: **Go**, **Rust/cargo**, **.NET**,
  **Odin** — plus a [tina](https://github.com/pmbanugo/tina) checkout at `~/dev/tina` (`TINA_HOME`)
  and an [odin-http](https://github.com/laytan/odin-http) checkout at `~/dev/odin-http`
  (`ODIN_HTTP_HOME`) for the two Odin ports.

## Quick start

```shell
uv sync

just --list               # the top-level recipes and the seven modules
just --list dsquiz        # one module's recipes

just quiz                 # panel quiz          -> http://localhost:5006/quiz_app
just dsquiz serve         # litestar port       -> http://127.0.0.1:5008
just opc                  # optimal point count

just quiz-test            # 89 tests
just dsquiz test          # 629 tests
just dsgo test
just dsrs test
just dsperf headless      # locust, against a RUNNING port
```

Every port exposes the same shape: `serve`, `test`, `qa`. The like-for-like run — one thread of
execution, matching the Python's single asyncio loop, which is the comparison the whole set exists
for — is `serve-1core` on `dsgo`, `dsrs` and `dsfs`; the two Odin ports are already single-shard by
default, so plain `serve` is theirs (`dsoh serve-all-cores` is the deployment question instead).

## Python apps

Each is a directory of flat modules — no packages — served from the repo root;
`apps/quiz/tests/conftest.py` puts the app directory on `sys.path` for pytest. Shared dependencies
live in the root `pyproject.toml` / `uv.lock`, except `apps/datastar-quiz`, which is deliberately its
own uv project so litestar and datastar stay out of the lock the panel app shares.

### apps/quiz

- **`quiz.py`** — loads bid tables by importing the external `bml` module and parsing `.bml` into
  header-context trees and bid nodes (`load_bid_tables`). No web framework. `bml_docs_dir()` resolves
  the corpus in this order: `BML_DOCS_DIRECTORY`, then beside the script (a flattened deployment),
  then two levels up. `load_bid_tables` chdirs there while parsing, because the `bml` module resolves
  `#INCLUDE` relative to the working directory.
- **`quiz_app.py`** — the Panel/Bokeh UI. `just deploy-quiz` flattens the notes repo's `*.bml` plus
  `apps/quiz/*.py`, `*.jpeg`, `*_topics.toml`, `pyproject.toml` and `uv.lock` into `X:/quiz-u16/`,
  and the BML tools' `*.py` into `X:/quiz-u16/bml/` (the deployment sets `BML_TOOLS_DIRECTORY` to
  that subdirectory).
- **`bidfilter.py`** and the `*_topics.toml` files — bidding-tree filter patterns and the
  pre-composed sidebar topics. One topics file per variant: `topics_file_for(variant)` picks
  `<variant>_topics.toml` if present (`swedish_topics.toml`, for `?swedish`), else
  `default_topics.toml` — whole-file replacement, no merging or inheritance.

  Bid tables hold more than calls: they hold words describing a call *relative to* the auction
  (`next`, `jump`, `cue`, `new`, `(overcall)`, `game`). `bmlbids` parses those; `bidfilter`
  **resolves** them, expanding an auction into the concrete auctions it stands for
  (`prepare_auction` → `expand_correlated`, `resolve_relative`) and matching if any of them does.
  The matcher stays stateless, and anything unresolvable stays unmatched rather than becoming a
  wildcard. `PSEUDO_BID_TOKENS.md` holds the plan, the corpus census and the open questions.
- **`quiz_telemetry.py`** / **`quiz_app_telemetry_setup.py`** — optional OpenTelemetry, loaded via
  `panel serve --setup` (`just quiz-traced`). `run-jaeger-tracing.cmd` starts a local Jaeger in
  docker: OTLP on 4317/4318, UI on 16686.

### apps/optimal-point-count

`optimal_point_count.py` / `optimal_point_count_app.py` — standalone honour-combination point-count
analysis (`just opc`).

### apps/datastar-quiz

`corpus.py` imports `apps/quiz/quiz.py` and `bidfilter.py` rather than copying them — they are pure
domain code, neither imports panel — by prepending that directory to `sys.path`. Nothing under
`apps/quiz/` is modified. `DEPLOY.md` is the deployment walkthrough; `DESIGN.md`, `CSS_GUIDE.md` and
`COMPARISON.md` cover the UI and the cross-port comparison.

## Justfile conventions

- App justfiles use `source_directory()`, **not** `justfile_directory()`. Invoked as a module from
  the root, the latter is the *root* justfile's directory — which pointed `uv --project` at the wrong
  project and broke every import.
- `repo := parent_directory(parent_directory(source_directory()))` in an app justfile means this
  repo's root. That is why the `apps/` directory level exists: it is how a port reaches a sibling
  (`repo / "apps" / "datastar-quiz"`). The `.bml` corpus is a different place — `system_home`.
- `mod` paths are literal strings: no variables, no environment-variable expansion. That is why the
  notes repo cannot reach these apps as modules and does not try.

## Known issues

- `just dsquiz qa` fails at the lint step: `RUF100 unused noqa: E402` in
  `tools/export_filter_goldens.py:25`. Pre-existing, unrelated to the repo split. `just dsquiz test`
  and `just dsquiz lint` are otherwise clean.
