# Developer-experience report: `alice` on AQL

**AQL build under test:** `aql-lang/aql` @ `c1d2a1a` (main, 2026-07-20),
built from source in-workspace (`cd cmd/go && go build ./aql`; note
`GOFLAGS=-mod=mod` now *fails* inside the aql workspace — "-mod may only
be set to readonly or vendor when in workspace mode" — the flag is only
for standalone clones).

**Context:** `alice` is a jless-style TUI file viewer with tabs and
watch-reload, written in AQL on the freshly-landed `aql:tui` stack
(upstream 2026-07-17). It is the first real-world exercise of `aql:tui`,
`aql:io` watching, the actor words, and deep cross-module call chains.
Everything below was hit while making the viewer work; each verdict was
isolated with a minimal repro where one exists. The five module suites
plus the headless app-integration suite and the fixtures smoke are green
on this build.

Severity: **🔴 high** (silent wrong results / crash / blocks a use case) ·
**🟡 medium** (friction, clear workaround) · **🟢 low** (papercut).

---

## Issues

### 1. 🔴 `def` from a call can silently fail to bind in deep call chains

In an update-loop chain (fn → `case` arm → fn → fn, as driven by
`Tui.run` or an equivalent fold), a `def` whose value is a call to a
**local alias fn** (a one-line wrapper around another module's export)
or to a **recursive fn** completes without binding — no error at the
def, then the *next* statement raises `undefined_word` for the name:

```aql
def with-active fn [[state:Map tab:Map] [Map] [ AliceTabs.put-active state (tab) ]]
# inside a case arm several frames deep:
def s3 (with-active (s2) (tabw))     # completes, binds NOTHING
def err ((AliceTabs.active (s3)) …)     # [aql/undefined_word]: s3
```

Replacing the alias with the direct module call (`def s3
(AliceTabs.put-active (s2) (tabw))`) binds correctly; converting recursive
helpers (`add-ancestors`, `surviving-anchor`) to `fold`s fixed the same
failure in `AliceTabs.reanchor`/`reveal`. Every module now avoids local
alias fns and recursion in state-machinery as a matter of policy.

**Root-caused & fixed** (on the tracked aql branch): reduced to a
standalone repro and isolated to **tail-call elimination**, so it is
**interpreter-only** — the default runtime compiles and the bytecode path
was always correct, which is why the same shape returns the right value
under `--force-compile` and only `--no-compile` errored. That masking is
also why it never showed up as a standalone repro before: `aql script.aql`
compiles, so the failure only surfaced in the composed program along a
path the compiler happened to refuse (falling back to the interpreter).
Minimal repro (`--no-compile`):

```aql
def f fn [[n:Integer] [Integer] [ if ((n) lte 0) [ 0 ] [ f ((n) sub 1) ] ]]
def x (f 3)          # binds nothing under the interpreter
def y ((x) add 1)    # [aql/undefined_word]: x
```

The trigger is precise: a fn body that ends in a **tail call** whose
**result is consumed as a forward paren-group argument** (`def x (f n)`,
`g (f n)`, `(f n) add …`). A forward paren group is evaluated eagerly by
the engine's `evalParenGroupAt`, which walks the group's tokens with a
local paren-depth counter to find its matching `)`. The tail call inside
the group fires TCO, which rewrites the enclosing frame region on the tape
(full-frame replacement / shell elision) out from under that counter — the
group's `)` is deleted or index-shifted before the loop decrements on it,
so the counter never reaches zero, the group never collapses, and the
bound result silently vanishes. Neither recursion nor an alias is required
in itself; both merely *produce* the shape — an alias `def s3
(Ns.put-active …)` is a one-call tail body bound through a forward paren.
The fix declines TCO while a paren group is being evaluated (the tail call
nests, which the depth counter tracks correctly) — a strict improvement,
since a declined tail call only nests and never changes a result. (One
narrow, interpreter-only caveat: a *very* deep — >~70k — tail recursion
consumed through a forward paren now nests rather than iterating, so
`--no-compile` can raise `tape_exhausted` where the default compiled path
stays O(1). The shape was fully broken before, so this is still strictly
better; the compiler covers it on every path but the diagnostic
interpreter.) The fold/direct-call workarounds above are retained because
this viewer also runs on stock aql main, where the fix has yet to merge —
they dispatch correctly either way. (Pre-fix shapes are in this repo's git history,
`alice-app.aql`/`alice-tabs.aql` before 7c6f739.)

### 2. 🔴 `IO.watch` callbacks are never delivered while `Tui.run` runs

A watch registered from inside a `Tui.run` update never fires its body:
no callback, no `send`, nothing — while the *identical* registration in
a headless script delivers within milliseconds. Repro pair:

```aql
# headless: fires (op=write lands in /tmp/alice-fire.txt)
def fire fn [[ev:Map] [Integer] [ IO.write (make Pathon "/tmp/alice-fire.txt") "hit" end drop 0 ]]
IO.watch (make Pathon ".") [fire] {match: "w.json"}
IO.write (make Pathon "./w.json") "{}" end drop
TimeUtil.sleep 800
```

The same `IO.watch` call made during a `Tui.run` update (the handle is
live, `Watcher(W_…)`) never runs `[fire]` for external writes to the
watched directory. Presumably the callback's concurrent fork needs the
runtime that registered it, and the TUI driver owns it while parked on
the mailbox. Since the whole point of watching in a TUI is reacting
while the loop is parked, `aql:tui` + `IO.watch` currently cannot be
combined. **Workaround (shipped):** a spawned metronome process
(`spawn` + `TimeUtil.sleep` + `send {tag:"tick"} "tui"` — this path
works perfectly) with mtime+size polling in `update`.

### 3. 🔴 User multi-signature fn dispatch loses a value's concrete type

A multi-sig fn (`[v:Map]…[v:List]…[v:Any]…` overloads) picks its `Any`
overload for a genuine Map when the value arrives through an Any param
inside a call chain that originates in an `each` body — and in some
cross-module chains (a value loaded in module A, dispatched by module
B's internal overloads). Native words (`is`, `get`, `keys`) see the
true type in the same positions. Minimal repro:

```aql
def nk fn [ [v:Map] [String] ["map"] [v:Any] [String] ["leaf"] ]
def hop fn [[cv:Any] [String] [ nk (cv) ]]
def doc {meta: {age: 36}}
print (hop ((doc) get "meta"))                                  # map ✓
print (each [ var [[k] (hop ((doc) get (k))) ] ] (keys (doc)))  # ["leaf"] ✗
```

**Workaround (shipped):** type dispatch in shared data-plumbing uses
single-sig fns with native `is`-chains (`alice-doc.aql`
`node-kind`/`get-seg`/`has-seg`); multi-sig overloads only where the
dispatch happens directly on an expression at the call site.

**Fixed** (on the aql branch this viewer tracks): the divergence was
**bytecode-only** — the interpreter re-dispatched on the true value
(`--no-compile` yields `["map"]`), but the default runtime compiles, and
the compiler baked the wrong arm (`["leaf"]`). Root cause: the value
reaches `nk` through `hop`'s `Any` param, whose generalised arg is a
*strict* `Any` carrier (`core_helpers.go`); a strict `Any` matched only
`nk`'s `Any` overload, so `matchSignature` committed that arm statically
instead of arming the runtime poly re-match. The each/fold body is only
what keeps the intermediate value gradual (a loop-variable key defeats the
constant-fold that would otherwise pin it to a concrete `Map`). The fix
treats a strict `Any` carrier as reaching every same-arity arm, so the
dispatch arms the existing user-poly re-match and the VM re-runs
`MatchSignature` on the real value — exactly like the interpreter, or it
refuses to the interpreter; never a wrong static commit. Pinned by
`lang/go/bytecode_userpoly_anywrapper_test.go` (a Map selects the Map arm,
a leaf the Any arm, on both surfaces). The `is`-chain workaround above is
retained because this viewer also runs on stock aql main, where the fix
has yet to merge — it dispatches correctly either way.

### 4. 🟡 A map literal returned from an fn body evaluates after teardown

`fn [[a:Integer b:Integer] [Map] [ {x: (b)} ]]` raises
`undefined_word: b` at call time: the returned map literal's `(…)`
values evaluate only after the call's params are gone (body-local defs
survive; params do not). **Workaround:** bind first — `def out {x:
(b)} out`. Used everywhere in the modules.

### 5. 🟡 No script argv (and no env access)

`aql script.aql a b c` silently ignores `a b c` (the CLI reads only the
script path), and no word exposes environment variables. A CLI tool
written in AQL cannot receive "which file to open" from its command
line — so `alice`'s baseline launch story is `aql alice.aql` + `:open`,
or an `aql -e 'import … Alice.run {files:[…]}'` one-liner. RFC:
`proposals/script-argv-and-env.md` (an `IO.args` word + CLI plumbing;
the launcher already reads it behind a `do/error` feature-detect, so a
build that carries it accepts `aql alice.aql notes.json`).

### 6. 🟡 Checker friction: several false-error shapes gate execution

Plain `aql X` refuses to run on check *errors*, and these check-only
shapes all came up while building the viewer (workarounds in
parentheses; all shipped):

- `is`-guarded branches don't narrow: `get`/`has` on a checker-typed
  disjunct is an error even though the branch guards it (→ overloads or
  is-chains behind an `[Any]` fn).
- A fold's accumulator is typed as the *element* type, so map-shaped
  accumulators error (→ restructure; see also §7).
- An IO-word result binds as an unresolved partial when an arg type
  mismatches — `IO.read "s"` needs `(make Pathon s)`; the follow-on
  errors ("cannot call `x`") point at every *use* of the binding.
- `convert String x` needs a statically-Scalar `x`; an Any-typed name
  inside `${…}` is treated as a zero-arg call (→ tiny typed coercion
  helpers `as-str`/`as-int`, typed accessors like `row-at`).
- A top-level *script*'s relative imports are CWD-relative, while an
  *imported* module's imports resolve against its own directory. When
  the modules lived under `viewer/`, `aql check viewer/alice-nav.aql`
  from the repo root couldn't resolve the module's sibling
  `./alice-doc.aql`. Flattening every module to the repo root removed
  the mismatch — `aql check alice-nav.aql` now resolves its siblings —
  so the whole tree checks clean file-by-file from the root.

### 7. 🟡 `fold`'s var binding order contradicts its description

`describe fold` says "the accumulator is pushed first", and the older
idiom reads `var [[acc x]]` — but the element is on *top*, so
`var [[a b]]` binds `a` = element, `b` = accumulator:

```aql
print (fold [ var [[a b] (a) ]] ["elem"] "init")   # elem — a is the ELEMENT
```

Commutative folds (`add`) mask the swap; anything asymmetric silently
computes garbage. Every fold in this repo reads `var [[elem acc]]`.

### 8. 🟢 Map key order is always sorted

`{b:1, a:2}` stores, prints, and iterates as `a, b` — source order is
unrecoverable, so a JSON viewer cannot show keys in file order (jless
does). Documented as a viewer deviation.

### 9. 🟢 jsonic-family leniency swallows truncation

`{"a": 1, "b": ` parses without error to `{a:1, b:null}` on the
`json`/`jsonic` paths — a malformed file "loads fine" with partial
content. There is no strict mode on the `IO.read` formats. The viewer
surfaces only hard read/parse errors.

## What worked well (worth keeping)

- **`IO.read` is a one-stop loader**: extension-inferred parsing over
  the whole tabnas family (plus `{fmt}` override, `{field:
  {separation:"\t"}}` for CSV variants — the "no tsv parse kind" gap in
  earlier planning was wrong at the IO.read level; only the `parse`
  word's kind set lacks it). `alice-fmt.aql` is ~40 lines because of
  this.
- **The `aql:tui` core held up**: alt-screen, diffed rendering, widget
  layout, key decoding, `Tui.quit`, and the "any mailbox message folds
  through update" contract all behaved exactly as specified —
  `send {…} "tui"` from a spawned process is a reliable event source.
- **`canon` is the right display serializer** (no HTML escaping, smart
  quote switching, `none`/numbers/bools render cleanly).
- **Headless TUI testing via an exported feed word**: exporting the
  update fold (`Alice.feed`) lets a plain test suite drive the real app —
  command mode, tabs, search, watch-reload against real disk writes —
  with no terminal. Pattern recommended for any aql:tui app (an
  AQL-reachable virtual backend would still be better — see
  `proposals/tui-live-io-and-testability.md`).

## Bytecode status

All seven suites — including the headless app-integration suite — run
**fully compiled** under `aql --force-compile`, byte-identical to the
interpreter, after one fix this surfaced: a `for`-loop body must leave
no residual value (`for` accumulates each iteration's results on the
stack, so the watch metronome's value-yielding body both grew the stack
by one entry per second and refused compilation with "result is a
variadic loop value"). The live TUI under `--force-compile
--compile-report` now stamps **all 110** of its runtime-constructed
callbacks to the VM — zero refusals — after isolating and designing out
the one refusing shape, since fully reduced to its law: a **Map-typed
local consumed by a user-fn call inside an `if` branch** loses its
operand provenance for any later user-fn call after the join — "fn call
operand of unknown provenance" — even with identical branches, and with
a single consuming branch. The boundary is sharp: a scalar local
survives the identical shape, the same map local survives without the
`if`, and it survives when nothing reuses it after the join.

**Fixed upstream** (on the aql branch this viewer tracks): the root
cause was a branch-join provenance bug — an enclosing local merely READ
inside both `if` arms is narrowed-through-use (identity-preserving), but
`InstallJoinedDefs` re-seated it as a fresh-ID `JoinCarriers` result,
stranding every later reference. `joinBranchDef` (eng/go/carrier.go) now
keeps the shared ID when both arm carriers are the same identity (an
identity no-op merge), so the binding's compile seat survives; a genuine
reassignment (differing IDs) keeps the fresh-ID join. With the fix the
`def midpane (if … [help-pane] [tree-pane …])` form compiles with zero
refusals; `alice-view.aql` branches on the whole widget list instead of
binding the pane so that it also compiles cleanly on stock aql main,
where the fix has yet to merge. Pinned upstream by
`lang/go/bytecode_ifbranch_operand_test.go` and the
`design/COMPILABLE-SUBSET.md` §2 branch-join narrow-preservation note.

## Summary

| # | Severity | Issue | Status |
|---|----------|-------|--------|
| 1 | 🔴 | silent `def`-binding failure in deep call chains (alias fns, recursion) | **root-caused & fixed** on the tracked aql branch (TCO × forward-paren-group, interpreter-only); fold/direct workaround retained for stock main |
| 2 | 🔴 | `IO.watch` callbacks starved under `Tui.run` | open; metronome+poll workaround |
| 3 | 🔴 | multi-sig dispatch degrades through Any params in each/cross-module chains | **fixed** on the tracked aql branch (bytecode strict-Any re-dispatch); is-chain workaround retained for stock main |
| 4 | 🟡 | returned map literal evaluates after param teardown | open; def-then-return |
| 5 | 🟡 | no script argv / env access | open; RFC filed, launcher feature-detects |
| 6 | 🟡 | checker false-error shapes gate `aql X` | open; typed-helper idioms |
| 7 | 🟡 | fold var order contradicts docs | open; element-first idiom |
| 8 | 🟢 | map keys always sorted | by design; documented deviation |
| 9 | 🟢 | lenient parsing swallows truncation | by design; documented |
