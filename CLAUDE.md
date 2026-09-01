# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

The applications built on top of the **BML** bridge bidding system: a Panel bidding quiz, a
standalone point-count analysis, and six ports of the same datastar/hypermedia quiz — Python, Go,
Rust, F# and two flavours of Odin — kept side by side as a runtime comparison. Each app is a
directory under `apps/`.

These were split out of **bridge-bidding-system**, which keeps the `.bml` system notes, the
BML → HTML build and the deal simulations. That repo is still a *runtime* dependency of the Python
apps (see below); nothing here builds or edits the notes.

## External dependencies (must be installed/configured)

- **bridge-bidding-system** — the notes repo, which owns the `.bml` corpus the Python apps parse.
  Located via `BRIDGE_SYSTEM_HOME`, else `~/docs/bridge/bridge-bidding-system`. The root `justfile`
  exports it as `BML_DOCS_DIRECTORY`, which is the override `quiz.py` honours; without it `quiz.py`
  falls back to two levels up from `apps/quiz/` — this repo's root, where there is no corpus. A root
  `export` reaches module recipes too, so `just dsquiz test` is covered as well as `just quiz`.
- **BML tools** — separate repo (`enerqi/bml`). Located via `BML_TOOLS_DIRECTORY`, else `~/dev/bml`.
  Provides the `bml` module `quiz.py` imports, and `bmlbids.py`, the shared model of a bridge *call*
  (multi-suit `1HS`, classes `2M`/`3m`, `oM`, wildcards `3*`/`3x`, alternation `2D/2H`, and the
  pseudo-bids `next`/`jump`/`cue`/`new`/`game`/`any`).
- **uv** — Python is pinned to 3.14 (`pyproject.toml`); run all Python via `uv run`.
- **just**, **nu** (nushell) — the root `justfile` uses `set shell := ["nu", "-c"]`. Each app's own
  justfile picks its own shell.
- Per-port toolchains: **Go**, **Rust/cargo**, **.NET 10**, **Odin** — plus a **tina** checkout at
  `~/dev/tina` (`TINA_HOME`) and an **odin-http** checkout at `~/dev/odin-http` (`ODIN_HTTP_HOME`)
  for the two Odin ports. Each port's `README.md` is the authority for its own.

## Common commands

```shell
# Panel apps (run from the repo root; paths in these recipes are relative to the justfile)
just quiz                 # = uv run panel serve apps/quiz/quiz_app.py --dev   (port 5006)
just quiz-traced          # same + --setup apps/quiz/quiz_app_telemetry_setup.py
just quiz-test            # pytest apps/quiz/tests
just opc                  # the optimal point count app

# Each datastar port is a just module with its own justfile; `just --list <mod>` enumerates it.
just dsquiz serve         # python/litestar reference port (port 5008)
just dsgo   serve-1core   # Go
just dsrs   serve-1core   # Rust
just dsfs   serve-1core   # F#
just dstina serve         # Odin on tina
just dsoh   serve         # Odin on odin-http
just dsperf headless      # locust harness against a RUNNING port
```

Lint: ruff, `line-length = 120`. Type checking is off (`pyright` `typeCheckingMode = "off"`).

## The shared corpus, and which apps need the notes repo at runtime

The Python app owns the BML parser and is the source of truth. The compiled ports **embed** a JSON
corpus exported from it, so they build, test and run with no notes repo present at all. Only the
export needs it:

```shell
just dsgo export-corpus    # re-runs the python exporters, rewrites the Go goldens
just dsrs export-corpus    # same, then copies the same bytes into the Rust port
```

Run those after editing a `.bml` file or a topics toml in the notes repo, then re-run the ports'
tests — the goldens (132 filter probes over both systems) are what holds the ported matchers to the
reference.

## Python apps (apps/)

Each app is a directory of flat modules (no packages), served from the repo root;
`apps/quiz/tests/conftest.py` puts the app dir on `sys.path` for pytest. Shared dependencies stay in
the root `pyproject.toml` / `uv.lock` — except `apps/datastar-quiz`, which has its own uv project so
litestar stays out of the root lock.

### apps/quiz/

- `quiz.py` — loads bid tables by importing the external `bml` module and parsing `.bml` into
  header-context trees + bid `Node`s (`load_bid_tables`). No web framework here. The `.bml` corpus is
  **not** found via the cwd: `bml_docs_dir()` takes `BML_DOCS_DIRECTORY` first (which is how it finds
  the notes repo from here), then beside the script in a flattened deployment, then two levels up.
  `load_bid_tables` chdirs there while parsing, because the `bml` module resolves `#INCLUDE` relative
  to the working directory.
- `quiz_app.py` — Panel/Bokeh UI on top of `quiz.py`; PEP 723 inline script metadata.
  `just deploy-quiz` flattens the notes repo's `*.bml` + `apps/quiz/*.py`, `*.jpeg`, `*_topics.toml`
  + `pyproject.toml`, `uv.lock` into `X:/quiz-u16/`, plus the BML tools' `*.py` into
  `X:/quiz-u16/bml/` (the deployment sets `BML_TOOLS_DIRECTORY` to that subdir).
- `bidfilter.py` / `*_topics.toml` — bidding-tree filter patterns and the pre-composed sidebar
  topics. One topics file per quiz variant: `bidfilter.topics_file_for(variant)` picks
  `<variant>_topics.toml` if present (e.g. `swedish_topics.toml`, for `?swedish`), else
  `default_topics.toml`. Whole-file replacement — no merging or inheritance. Bid tables hold more
  than calls: words describing a call relative to the auction (`next`, `jump`, `cue`, `new`,
  `(overcall)`, `game`). `bmlbids` parses those; `bidfilter` *resolves* them, expanding an auction
  into the concrete auctions it stands for (`prepare_auction` → `expand_correlated`,
  `resolve_relative`) and matching if any of them does — the matcher stays stateless, and anything
  unresolvable stays unmatched rather than becoming a wildcard. `PSEUDO_BID_TOKENS.md` holds the
  plan, the corpus census and the open questions.
- `quiz_app_telemetry_setup.py` / `quiz_telemetry.py` — optional OpenTelemetry setup; load via
  `panel serve --setup` (`just quiz-traced`). `run-jaeger-tracing.cmd` starts a local Jaeger
  (OTLP 4317/4318, UI 16686) for traces.

### apps/optimal-point-count/

- `optimal_point_count.py` / `optimal_point_count_app.py` — standalone honour-combination
  point-count analysis (`just opc`).

## The datastar quiz ports (apps/datastar-quiz*)

Same hypermedia architecture, same corpus, same routes, driven by the same `dsperf` harness. The
`mod` comments in the root `justfile` say what question each port exists to answer; each port's
`README.md` (and `RESULTS.md`, where present) has the measurements.

| module | directory | stack |
|---|---|---|
| `dsquiz` | `apps/datastar-quiz` | Python, litestar + uvicorn/granian — the reference; owns the BML parser and the exporters |
| `dsgo` | `apps/datastar-quiz-golang` | Go, `net/http` + datastar-go |
| `dsrs` | `apps/datastar-quiz-rust` | Rust, tokio + axum + datastar-rs |
| `dsfs` | `apps/datastar-quiz-fsharp` | F#, Oxpecker + StarFederation.Datastar.FSharp (JIT / ReadyToRun / Native AOT) |
| `dstina` | `apps/datastar-quiz-tina` | Odin, tina http — shared-nothing, thread-per-core, no allocation after boot |
| `dsoh` | `apps/datastar-quiz-odin-http` | Odin, odin-http — everything but `web/` is the tina port's source unchanged |
| `dsperf` | `apps/dsquiz-perf` | locust harness against a running port |

`apps/datastar-quiz/DEPLOY.md` is the deployment walkthrough; `DESIGN.md`, `CSS_GUIDE.md` and
`COMPARISON.md` there cover the UI and the cross-port comparison.

## Justfile notes

- App justfiles use `source_directory()`, **not** `justfile_directory()`: as a module from the root,
  the latter is the ROOT justfile's directory, which pointed `uv --project` at the wrong project.
- `repo := parent_directory(parent_directory(source_directory()))` in an app justfile means *this*
  repo's root — that is why the `apps/` directory level is kept. It is for reaching sibling apps
  (`repo / "apps" / "datastar-quiz"`); the `.bml` corpus is `system_home`, a different place.
- `mod` paths are literal strings: no variables, no env-var expansion. That is why the notes repo
  cannot reach these apps as modules, and why the split is clean rather than cross-linked.
