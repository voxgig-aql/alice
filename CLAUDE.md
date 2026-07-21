# CLAUDE.md

This repository is the `Bloom` bloom-filter library, written in AQL.

## Using the library

See @AGENTS.md for how to call the `Bloom` API correctly from AQL — the
calling convention, the full API, copy-paste idioms, and the common
mistakes to avoid. Every example there is verified against the pinned
`aql` build.

## Working on this repository

- A SessionStart hook (`.claude/settings.json` →
  `.claude/hooks/session-start.sh`) builds `aql` from the pinned commit in
  remote sessions, so a fresh session can run the suites. Locally, build it
  once from source (there is no tagged release and `go install …/aql@latest`
  is blocked by replace directives) — see
  [docs/how-to.md](docs/how-to.md#install-and-run-aql).
- Tests live in `test/`, named `<subject>_<unit|prop>_<test|spec>.aql` plus a
  `bloom_smoke_test.aql`: `_test` = imperative (`Test.test`/`Test.check-prop`),
  `_spec` = declarative spec; `unit` = example-based, `prop` = property-based.
  Each assertion-bearing suite ends by asserting `Test.fail-count` is `0` and
  prints `all green`.
- `test/divergence/run.sh` runs every suite through all three aql surfaces —
  interpreter, `aql check`, and the byte compiler (`aql --compile`) — and
  asserts none errors or disagrees. It pins the same aql ref as the library
  (historically it ran a newer one, before the pin caught up). See its
  `README.md`; the byte-compiler bug it guards against is `dx-report.md` §3.
- Known AQL-runtime gotchas observed with the pinned build are in
  `dx-report.md`. The pinned aql commit is single-sourced in the CI workflow's
  `AQL_REF` (`.github/workflows/test.yml`); a CI `consistency` job fails if the
  hook, `test/divergence/run.sh`, or `api.json` drift from it.
- `viewer/` + `av.aql` is a separate deliverable: the `av` TUI file viewer
  (jless-style; tabs; watch-reload), written in AQL against aql **main** —
  NOT the library pin, which predates the `aql:tui` stack it needs. Build
  aql from latest main to run/develop it; its conventions and keymap are in
  `viewer/README.md`, its runtime findings are the 2026-07-21 round of
  `dx-report.md`, and CI runs its suites in the `viewer` job.
- Forking this repo to start a new AQL library? See `TEMPLATE.md`.
