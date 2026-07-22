# CLAUDE.md

This repository is **`alice`** — a jless-style TUI file viewer for every
format aql can parse (tabs; watch-reload), written **in AQL** on the
`aql:tui` stack. Start with **[README.md](README.md)**: what it is, how
to launch it, the full keymap, the watch semantics, and the module map.

## Working on this repository

- **Build aql from main.** alice tracks aql **main**, unpinned — the
  `aql:tui` stack it needs landed upstream 2026-07-17. Build the
  interpreter from a source checkout:
  ```bash
  cd <aql-checkout>/cmd/go && go build -o ~/.local/bin/aql ./aql
  ```
  Note `GOFLAGS=-mod=mod` *fails* inside the aql workspace ("-mod may
  only be set to readonly or vendor when in workspace mode") — it is only
  for standalone clones. A SessionStart hook
  (`.claude/hooks/session-start.sh`) builds aql from main in remote
  sessions so a fresh session can run the suites.
- **Modules live at the repo root** (no subfolders): `alice.aql` is the
  entry launcher; `alice-app.aql` is the `Tui.run` shell (the only module
  that touches the terminal); `alice-{view,nav,tabs,doc,fmt}.aql` are the
  pure, terminal-free core. Run everything from the repo root — relative
  imports (`./alice-doc.aql`) resolve against the working directory.
- **Tests live in `test/`**, named `alice_<subject>_<unit|prop>_test.aql`
  plus `alice_smoke_test.aql`. Each assertion-bearing suite ends by
  asserting `Test.fail-count` is `0` and prints `all green`. The pure
  modules are unit/property tested directly; the shell is driven
  headlessly through the exported `Alice.feed` fold
  (`test/alice_app_unit_test.aql`) — there is no AQL-reachable virtual
  terminal, so rendering and raw key decoding are covered only by the
  manual PTY smoke in the README.
- **Before committing**, from the repo root:
  ```bash
  for f in alice.aql alice-app.aql alice-fmt.aql alice-doc.aql \
           alice-nav.aql alice-tabs.aql alice-view.aql; do aql check "$f"; done
  for t in test/alice_*_test.aql test/alice_smoke_test.aql; do aql "$t"; done
  ```
  All modules should `aql check` clean; every suite should print
  `all green`. The suites also run under `aql --force-compile` (bytecode)
  byte-identical to the interpreter — keep them compiling.
- **Known AQL-runtime gotchas** observed while building alice — and the
  idioms that dodge them — are in [`dx-report.md`](dx-report.md). Read it
  before changing the state machinery: the deep-call-chain `def`-binding
  failure (§1), the `IO.watch`-under-`Tui.run` starvation that forces the
  metronome+poll design (§2), and the multi-sig dispatch degradation (§3)
  each shaped how these modules are written.
- **Upstream AQL proposals** raised from this work live in
  [`proposals/`](proposals/) (RFCs against the aql interpreter, not
  changes to alice).
