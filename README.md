# alice — an aql file viewer

A full-screen terminal viewer for every file format [aql](https://github.com/aql-lang/aql)
can parse, written **in AQL** on the `aql:tui` stack, modeled on
[jless](https://jless.io)'s interface — extended with **tabs** for
multiple open files and a **watch** mode that reloads changed files
while keeping your place.

```bash
aql alice.aql                 # welcome tab; open files with :open
aql alice.aql notes.json      # open a file straight away (needs IO.args — see below)
```

Verified against `aql-lang/aql` **main @ `c1d2a1a`** (2026-07-20). alice
tracks aql **main**, unpinned — the `aql:tui` stack it rides on landed
upstream on 2026-07-17, and the app follows it forward. A "last
verified" commit is recorded here instead of a pin; CI builds aql from
main on every run.

## Launch

From the repo root (imports are working-directory-relative):

```bash
aql alice.aql                 # welcome tab; open files with :open
```

On an aql carrying the `IO.args` word (see
`proposals/script-argv-and-env.md`; implemented on the aql branch this
viewer was developed against), files pass straight from the shell:

```bash
aql alice.aql notes.json data.csv
```

On builds without it, aql scripts cannot read command-line arguments
(dx-report §5) — the launcher falls back to the welcome tab (`:open`
from there), or use the `-e` form:

```bash
aql -e 'import "./alice-app.aql"  Alice.run {files: ["test/fixtures/sample.json"]}'
aql -e 'import "./alice-app.aql"  Alice.run {files: ["a.json", "b.csv"], watch: false}'
```

Remote viewing works for free, because the same app map serves both
runtimes: `Alice.serve {tcp: 9700, token: "s3cret"} …` then `aql attach`.

## Formats

Parsing is aql's own `IO.read`, which infers the format from the file
extension: `json jsonic json5 jsonc csv tsv toml yaml xml ini/cfg/conf
zon md/markdown rss/atom`. Anything else (or `:open <path> text`) is
shown as plain-text lines, so every file is viewable. CSV/TSV render as
a list of header-keyed records. An explicit kind overrides the
extension: `:open data.log json`.

## Keys

| Keys | Action |
|------|--------|
| `j` `k` / arrows | move focus down / up |
| `l` / right | expand a container, or step to its first child |
| `h` / left | collapse an open container, or go to the parent |
| `H` | go to the parent without collapsing |
| `J` `K` | next / previous sibling |
| `w` `b` | next / previous change of depth |
| `space` | toggle fold |
| `c` | collapse (from a leaf: collapse at the parent) |
| `e` / `E` | expand / deep-expand the focused subtree (row-capped) |
| `g` `G` | first / last row |
| `0` `^` / `$` | first / last sibling |
| `C-f` `C-b` / `pgdn` `pgup` | page down / up |
| `C-d` `C-u` | half page down / up |
| `C-e` `C-y` | scroll without moving focus |
| `z` then `z`/`t`/`b` | focused row to center / top / bottom |
| `.` `,` | scroll long values right / left |
| `/text` | search keys and values (smart case), `n` / `N` cycle |
| `*` | search for the focused key |
| `y` | print focused path + value to the status line |
| `tab` / `backtab` | next / previous tab |
| `W` | toggle watch on the active tab |
| `r` | reload the active tab now |
| `?` | help overlay (any key returns) |
| `q` | close the tab (last tab closed quits) |
| `C-c` / `C-\` | quit (aql:tui built-ins) |

Commands (`:`): `:open <path> [kind]` · `:close` · `:tab <n>` ·
`:next` · `:prev` · `:watch on|off` · `:help` · `:quit`.

## Watch

Watching is ON by default for every opened tab (`Alice.run {watch:
false}`, `:watch off`, or `W` to opt out; the status bar shows
`watching`). A spawned metronome process ticks the app once a second;
each watched tab's mtime+size stamp is compared and, on change, the
file is reloaded and the view **re-anchored**:

1. the focused row's path is the anchor; its screen line is noted;
2. expansions whose paths survive in the new document are kept;
3. if the anchor's node was deleted, focus falls to its nearest
   surviving ancestor;
4. rows are rebuilt and scrolled so the anchor sits on the same screen
   line.

A reload that fails to parse keeps the old view and shows the error; a
deleted file keeps its buffer and marks the tab `✗` (gone) — and comes
back when the file does. Edits within the same second that also keep
the byte size identical are invisible to the stamp (accepted
limitation). Polling is used instead of fsnotify because `IO.watch`
callbacks are never delivered while `Tui.run` owns the runtime — see
dx-report §2.

## Deviations from jless (v1)

- Map keys display in **sorted order** — aql maps sort their keys;
  source order is not preserved (dx-report §8).
- Strings render aql-style (`'single-quoted'`, via `canon`), not JSON
  double-quoted.
- No line mode (`m`/`%`), no clipboard yank (aql has no subprocess or
  clipboard access — `y` prints to the status line instead), no digit
  counts, no regex search (literal smart-case; `aql:minilang`'s `re` is
  the upgrade path), no `<`/`>` indent control, no mouse.
- XML files parse to an element node and currently display as a single
  leaf.

## Architecture

```
alice.aql        entry launcher: reads IO.args, runs Alice.run
alice-app.aql    shell: Tui.run app map, mode routing, watch metronome
alice-view.aql   pure widget builders (tab strip, tree pane, bars, help)
alice-nav.aql    pure jless keymap fold over a tab's view state
alice-tabs.aql   pure tab set + reload re-anchor + reveal
alice-doc.aql    pure document → row model (splices, search, display)
alice-fmt.aql    format detection + IO.read loading
```

Everything except `alice-app.aql` is terminal-free and unit-tested
(`test/alice_*`). The shell itself is exercised headlessly through
`Alice.feed`, which folds synthetic events through the real update loop —
including the watch pipeline against real on-disk writes
(`test/alice_app_unit_test.aql`). Rendering and raw key decoding are
covered by a manual PTY smoke:

```bash
printf '…keys…' | script -qec "stty cols 130 rows 32; aql alice.aql" /dev/null
```

(a real terminal is nicer). The AQL-runtime pitfalls this codebase had
to design around — and the idioms that dodge them — are catalogued in
[`dx-report.md`](dx-report.md), with upstream RFCs in
[`proposals/`](proposals/).

## Tests & CI

Seven suites under `test/` (run each with `aql test/<name>.aql`):

```bash
aql test/alice_fmt_unit_test.aql    # format detection + load
aql test/alice_doc_unit_test.aql    # document → row model
aql test/alice_doc_prop_test.aql    # property-based row-model invariants
aql test/alice_nav_unit_test.aql    # the jless keymap fold
aql test/alice_tabs_unit_test.aql   # tab set + reload re-anchor
aql test/alice_app_unit_test.aql    # headless full-app integration
aql test/alice_smoke_test.aql       # every fixture format loads
```

Each assertion suite ends by asserting `Test.fail-count` is `0` and
printing `all green`; all seven also run **fully bytecode-compiled**
(`aql --force-compile`) byte-identical to the interpreter.

CI ([`.github/workflows/test.yml`](.github/workflows/test.yml)) builds
aql from **main** on every push and pull request, `aql check`s every
module and the launcher, and runs all seven suites. Because it tracks
main rather than a pin, an upstream regression can break CI
independently of any change here — the accepted trade-off for riding the
latest `aql:tui`.

## License

See [LICENSE](LICENSE).
