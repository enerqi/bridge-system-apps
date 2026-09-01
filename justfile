# Guide for Just *task* runner
# https://just.systems/man/en/chapter_20.html
#
# This repo is the applications half of the bridge system. The other half -- the .bml system notes,
# the BML -> HTML build and the deal simulations -- lives in bridge-bidding-system, and stays there.
# SHELL, as in the app justfiles and deal-simulations/odin-sims: `cmd.exe` starts in ~9ms and is
# always available, and just launches a shell per recipe line.
#  - alternatives: `nu -c` ~41ms, `powershell -NoLogo -NoProfile -Command` ~143ms
#  - cost: poor language for a multi-line recipe, hence `[script]` -> python for anything with logic
[windows]
set shell := ["cmd.exe", "/c"]
[unix]
set shell := ["bash", "-c"]
set minimum-version := "1.49.0"  # [script] (1.49); also [group] 1.27, set lazy 1.47
set unstable  # [script]
set lazy
# `python` alone is not a reliable cross-platform lookup (cf. python/python3/python3.x). uv resolves
# and downloads on every platform, and --no-project means no pyproject.toml / local .venv lookup --
# these scripts are justfile plumbing, NOT part of this repo's environment. Recipes opt in with the
# bare `[script]` attribute (no interpreter argument).
set script-interpreter := ["uv", "run", "--no-project", "-p", "3.14", "python"]

# The BML system-notes repo, which owns the .bml corpus these apps read. Same env-var + home-default
# shape that repo uses for its own external checkouts (bml, bridge-markup, tina, odin-http).
system_home := env_var_or_default("BRIDGE_SYSTEM_HOME", join(home_directory(), "docs", "bridge", "bridge-bidding-system"))
bml_home := env_var_or_default("BML_TOOLS_DIRECTORY", join(home_directory(), "dev", "bml"))

# quiz.py honours this override; without it its fallback is two levels up from apps/quiz/, which in
# THIS repo is the root -- and the corpus is not here. A root `export` reaches module recipes too,
# so `just dsquiz test` is covered by this one line as well as `just quiz`.
export BML_DOCS_DIRECTORY := system_home

#
# Python apps (apps/<app>/). Run from the repo root -- the recipe paths below are relative to this
# justfile. The .bml corpus is NOT here: quiz.py resolves it from BML_DOCS_DIRECTORY (exported
# above), not from the cwd, so BRIDGE_SYSTEM_HOME is what points these at the notes repo.
#

# serve quiz app in dev mode
[group('apps')]
quiz:
    uv run panel serve apps/quiz/quiz_app.py --dev

# serve quiz app in dev mode with OpenTelemetry tracing (see apps/quiz/run-jaeger-tracing.cmd)
[group('apps')]
quiz-traced:
    uv run panel serve apps/quiz/quiz_app.py --dev --setup apps/quiz/quiz_app_telemetry_setup.py

# run the quiz app python tests
[group('apps')]
quiz-test *args:
    uv run --with pytest pytest apps/quiz/tests {{args}}

# serve the optimal point count app in dev mode
[group('apps')]
opc:
    uv run panel serve apps/optimal-point-count/optimal_point_count_app.py --dev

# The datastar/litestar port of the quiz owns its own justfile (and its own uv project, so litestar
# stays out of this repo's lock), reached from here as a module: `just dsquiz serve` (granian, port
# 5008, alongside `just quiz` on 5006), `just dsquiz qa`, `just dsquiz test`,
# `just dsquiz serve-streamed` for the held-SSE timer variant. `just --list dsquiz` lists them all.
#
# It deploys itself too -- `just dsquiz deploy` (-> X:/quiz-ds/), NOT `deploy-quiz` below: that port
# needs the repo's directory layout rather than one flat directory, because it imports apps/quiz and
# serves an asset from there. apps/datastar-quiz/DEPLOY.md is the walkthrough.

# datastar quiz port (litestar + uvicorn/granian): serve, deploy, test, qa, routes, ...
[group('modules')]
mod dsquiz 'apps/datastar-quiz'

# THIRD implementation of the same quiz, in Go, for the runtime comparison: same hypermedia
# architecture, same corpus (exported from the python app and embedded), same routes, driven by the
# same dsperf harness. `just dsgo serve-1core` is the like-for-like run against the python's single
# asyncio loop; `just dsgo serve` is the deployment question. apps/datastar-quiz-golang/README.md.

# datastar quiz port (Go, net/http + datastar-go): serve, serve-1core, test, bench, qa, pprof, ...
[group('modules')]
mod dsgo 'apps/datastar-quiz-golang'

# FOURTH implementation, in Odin on Tina (github.com/pmbanugo/tina) -- a shared-nothing,
# thread-per-core framework with no allocation after boot. Same corpus, same routes, same dsperf
# harness. It is the allocation question the other three cannot ask: memory is sized at startup and
# the process sheds load rather than growing. One shard, matching the python's single asyncio loop
# and `just dsgo serve-1core`. Needs a tina checkout at ~/dev/tina (TINA_HOME overrides).
# apps/datastar-quiz-tina/README.md.

# datastar quiz port (Odin, tina http + its datastar SDK): serve, lint, lint-strict, test, qa, ...
[group('modules')]
mod dstina 'apps/datastar-quiz-tina'

# FIFTH implementation, and the SECOND in Odin: the same app on odin-http (github.com/laytan/odin-http),
# a plain nbio event-loop server over shared memory. Everything except `web/` is the tina port's
# source unchanged, so the pair isolates the HTTP runtime and nothing else -- fixed per-connection
# buffers sized at boot against arenas that grow per request, shared-nothing shards against threads
# and one mutex. One event-loop thread by default, the like-for-like budget; `just dsoh
# serve-all-cores` for the deployment question. Needs an odin-http checkout at ~/dev/odin-http
# (ODIN_HTTP_HOME overrides). apps/datastar-quiz-odin-http/README.md.

# datastar quiz port (Odin, odin-http + a hand-written datastar writer): serve, lint, test, qa, ...
[group('modules')]
mod dsoh 'apps/datastar-quiz-odin-http'

# FOURTH implementation, in Rust: same architecture, same corpus, same routes, driven by the same
# dsperf harness. Where the Go port answers "what does a compiled runtime cost", this one answers
# "what does no GC and no per-call allocation cost on top of that".
# `just dsrs serve-1core` is the like-for-like run. apps/datastar-quiz-rust/README.md.

# datastar quiz port (Rust, tokio + axum + datastar-rs): serve, serve-1core, test, bench, qa, ...
[group('modules')]
mod dsrs 'apps/datastar-quiz-rust'

# SIXTH implementation, in F# on .NET 10. Two things it asks that none of the others can. First,
# the SSE writer is FIRST-PARTY LIBRARY CODE in the app's own language: `StarFederation.Datastar.FSharp`
# is the core of starfederation/datastar-dotnet (the C# package is a shim over it), and it writes
# UTF-8 straight into the response's IBufferWriter -- where the Go SDK had to be worked around, the
# Rust stream is hand-rolled and both Odin ports hand-wrote a writer. Second, a DEPLOY-TIME CODEGEN
# axis: JIT / ReadyToRun / Native AOT as three columns for startup, resident set, throughput and
# binary size -- which nothing in this repo measures today. `just dsfs serve-1core` is the
# like-for-like run (DOTNET_PROCESSOR_COUNT=1). apps/datastar-quiz-fsharp/README.md.

# datastar quiz port (F#, Oxpecker + StarFederation.Datastar.FSharp): serve, serve-1core, test, qa, ...
[group('modules')]
mod dsfs 'apps/datastar-quiz-fsharp'

# locust performance tests against a RUNNING datastar quiz: smoke, headless, soak, report, qa
[group('modules')]
mod dsperf 'apps/dsquiz-perf'

# The corpus comes from the notes repo (BRIDGE_SYSTEM_HOME), everything else from here.
# ---
# copy PANEL quiz app files to deployment folder (flattened: app + bml corpus in one directory)
[group('apps')]
[script]
deploy-quiz:
    import shutil
    from pathlib import Path

    # `source_directory()`, not the cwd: the recipe is then correct whether it runs from the repo
    # root or (were this file ever imported) from elsewhere.
    root = Path(r"{{source_directory()}}")
    quiz = root / "apps" / "quiz"
    system_home = Path(r"{{system_home}}")
    bml_home = Path(r"{{bml_home}}")
    dest = Path(r"X:/quiz-u16/")

    # Flattened on purpose: the panel app and the .bml corpus land in one directory, with the bml
    # tools in a `bml/` subdirectory beside them.
    dest.mkdir(parents=True, exist_ok=True)
    for src in (
        *system_home.glob("*.bml"),
        *quiz.glob("*.py"),
        *quiz.glob("*.jpeg"),
        *quiz.glob("*_topics.toml"),
        root / "pyproject.toml",
        root / "uv.lock",
    ):
        shutil.copy2(src, dest / src.name)

    bml_dest = dest / "bml"
    bml_dest.mkdir(parents=True, exist_ok=True)
    for src in bml_home.glob("*.py"):
        shutil.copy2(src, bml_dest / src.name)

