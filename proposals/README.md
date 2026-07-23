# proposals/

Upstream **AQL-language** design proposals (RFCs) surfaced while building
`aless` — changes to the `aql` interpreter itself, not to this app. They
live here so the idea is captured next to the code that motivated it.

- One proposal per file, kebab-case.
- Each is cross-referenced from the gotcha that motivated it in
  [`dx-report.md`](../dx-report.md).

Current proposals:

- [`script-argv-and-env.md`](script-argv-and-env.md) — script argv
  (`IO.args`) and environment access, so an AQL CLI program can receive
  its arguments (dx-report §5).
- [`tui-live-io-and-testability.md`](tui-live-io-and-testability.md) —
  deliver `IO.watch` callbacks under `Tui.run`, and expose an
  AQL-reachable virtual terminal backend for headless testing (dx-report
  §2).
- [`update-loop-def-binding-soundness.md`](update-loop-def-binding-soundness.md)
  — the silent `def`-binding failure in deep update-loop call chains
  (dx-report §1).
