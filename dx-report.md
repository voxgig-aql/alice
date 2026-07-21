# Developer-experience report: bloom-filter on AQL

**Date:** 2026-06-11 (second round)
**AQL build under test:** `aql-lang/aql` @ `7193a7d3`
(`7193a7d3c69857207e44b4bd53541b9b0d4348aa`, main as of 2026-06-11;
39 commits past `958c379b`, which this report previously covered;
built locally with `GOFLAGS=-mod=mod`; version string now reports
`aql 0.1.0-dev (git 7193a7d3c698)`).
**Context:** re-verification round. The first 2026-06-11 report (at
`958c379b`) filed eight issues after migrating this module to the
class/Array/raise surface. Six of the eight — including all three
🔴 — were fixed upstream within the same day's 39 commits, several
visibly in direct response to the DX reports. Every verdict below was
re-reproduced first-hand against the build above using the original
minimal repros; the module's five test suites pass on this build
unmodified.

Severity: **🔴 high** (silent wrong results / crash / blocks a use case) ·
**🟡 medium** (friction, clear workaround) · **🟢 low** (papercut).

---

## Update (DX-driven aql fixes)

A later aql HEAD split the accessor family: `get`/`getr` now **evaluate**
their key (so `lst get i` reads the bound variable `i`), while literal
bare-word field access moved to the new `.field` / `!.field` sugar
(lowering to `dot`/`dotr`), with the quoted-atom `get field/q` form kept
for the receiver-less stack-value case. Migrating this module to that
surface was a test-only change: `bloom.aql` already read fields with
`.field` / `!.` and only used `get` with String or computed keys, so it
needed no edits; the six literal-field error reads in
`test/bloom_unit_test.aql` (`e get code`, etc., where the caught error is
a bound receiver and `code` is a literal field) became `e.code`. No
`comp/r` box-pattern workaround applies here — this library does not use
`comp/r`, so nothing of that kind was removed (that cleanup is specific to
the sort/stats modules). Verification additionally depends on three
upstream fixes carried by the local aql build under which this was checked
— the `comp/r` frame over-pop fix, `StructUtil.parse` float fidelity, and
the checker `no_signature` fix; the migrated suites and `aql check` are
green only on a build carrying them.

---

## Fixed since the `958c379b` report

- **🔴→✅ Guard `if` + following `def`: guards fire first now**
  (aql `00cb7a79`, "guards fire before the next statement"). The
  defining repro — an else-less validation `if` whose `raise` was
  pre-empted by eager evaluation of the next `def` statement — now
  raises the guard's own error:

  ```aql
  def t fn [ [x:Any] [Integer] [
    if ((x is Float) not) [
      def m "not a float"
      raise bad_input m
    ]
    def y (x gt 0.0)
    7
  ] ]
  do [t none] error [ get code ]    # => bad_input  (was: incomparable)
  ```

  `bloom.aql` keeps the explicit empty else `[]` on its guards anyway —
  it costs nothing, reads as intent, and stays correct on older builds.

- **🔴→✅ Class-field defaults are per-instance** (aql `607cd1b9`).
  A mutable schema default (`store:(flex {})`) is no longer one shared
  value: writing through one instance is invisible to another. The
  Python-style mutable-default trap is gone. (`BloomFilter` still
  declares `bits` as a required typed field and passes a fresh Array
  per `make` — that remains the clearer design.)

- **🔴→✅ `Object` instances format** (same commit, "open objects
  render"). `print (object {a:1}) end` prints `Object{a:1}`; a bare
  `make Object {}` on the final stack prints `Object{}` instead of
  SIGSEGV-ing the interpreter.

- **🟡→✅ `raise` accepts template-string messages** (aql `00cb7a79`,
  "templates fill typed slots"). Both the bare and parenthesised forms
  now work, with the code and interpolated message intact:

  ```aql
  raise bad_input `got ${t}`        # => bad_input, message "got x"
  ```

  The bind-first idiom (`def msg …` then `raise code msg`) is no longer
  required; this module keeps it for back-compat and readability.

- **🟢→✅ `getr` raises the documented `not_found`** (aql `93ebcd40`;
  was `getr_error`, contradicting REFERENCE.md).

- **🟢→✅ `StructUtil.jsonify` emits Floats as JSON numbers** (aql
  `862546fd`); a `jsonify` → `parse` round trip preserves the Float
  type now. (`Bloom.encode` continues to use canon — unchanged, just
  no longer the only type-preserving option.)

Also fixed without having been formally filed: `aql -version` now
stamps the git commit (`1981f601`), so "which build am I on?" — a
recurring nuisance across these reports — answers itself.

---

## Still open

### 1. 🟡 `print` forward-arg collection reverses/breaks chained prints

Unchanged through three builds:

```aql
(1 add 1) print (2 add 2) print     # prints 4 then 2 — the first
                                    # print collects (2 add 2)
```

The reliable idiom remains one fully-grouped value per statement —
`print (`label: ${value}`) end` — with which output appears strictly
in source order. Every print in this module's tests and docs uses it.

### 2. ✅ `aql check` is now gating-ready (resolved on the pinned build)

The check-mode false positives are **gone** on the current pin. Two upstream
re-pins cleared them: `2342477` ("checker-accuracy fixes: 0 check
warnings/info") and `7b1a4fb` ("full check cleanliness: 0 errors/warnings/
info"). Both blockers this section tracked are fixed:

- the false `no_signature: no matching signature for mul` in
  `derive-m`/`derive-k` (arithmetic through `convert Float`) and the
  consequent `fn_body_error` — gone (the `convert` return-type fix);
- the `unused_def` cascade on the words reachable only through the
  `export "Bloom" {…}` map — the checker now traces those exports as uses.

`aql check bloom.aql` reports **0 errors** (and exits `0`), so it is safe to
gate. **Follow-up:** the CI static-check step in `.github/workflows/test.yml`
still runs `aql check --soft bloom.aql` with `continue-on-error: true` (an
advisory carried over from when the false positives were real). Dropping
`--soft` and `continue-on-error` — `run: aql check bloom.aql` — turns it into
a real gate. That edit needs a token with `workflow` scope (as the workflow
promotion did), so it is left for a maintainer.

### 3. ✅ Bytecode (`--compile`) each-body block-local divergence — fixed upstream (`407feda`)

> **Resolved 2026-06-24.** The divergence below is **fixed** on aql
> `407feda` (the reduced repro is byte-identical between interpreter and
> `--compile`), along with two short-lived `main` regressions that broke
> the library on the 2026-06-23 tips — a `None`-in-template interpolation
> bug and `convert`/fold `no_signature` check false positives (all in
> `f247557` / `fc47452`; see `aql-backend-report.md` and upstream
> `design/CLIENT-FIXES-2026-06-24.md`). `test/divergence/run.sh` now pins
> `407feda` and every suite is clean across interpreter, `aql check` (0
> errors), and `aql --compile`. The original finding is kept below as the
> record; the unit suite's top-level `_seen` fixture is retained (harmless,
> and keeps the suite robust on older builds).

Newer aql can run a program through a bytecode backend instead of the
interpreter, selectable at the CLI: `aql --compile X` (bytecode when
compilable, else a *silent* fallback to the interpreter — documented to be
identical, "opt-in performance, never semantics") and `aql --force-compile X`
(require the bytecode path, or abort with a refusal reason). A differential
test (`test/divergence/`, run with `test/divergence/run.sh`) checks the
contract `aql --compile X == aql X` across this library's suites.

Most of it holds — and that is real progress: the loop-free core
(`make`/`add`/`contains`/`merge`/`encode`/`decode`) now **fully compiles**
under `--force-compile` and returns byte-identical results, where at this
module's pin (`7193a7d3`) the bytecode path couldn't run the library at
all. The one sharp edge: a compiled `each` body **drops a block-local
binding** from the enclosing block. Reduced repro (passes on the
interpreter, wrong under `--compile`):

```aql
import "aql:test" end
import "./bloom.aql" end
[ def bf ({n: 1000, p: 0.01} Bloom.make end)
  def _ (iota 50 each [ var [[i] bf Bloom.add (convert String i) end 0 ] ])
  def cnt (bf Bloom.count end)
  true (45 lte cnt) Assert.equal end
] "count-within-tolerance" Test.test end
# interpreter => passes
# --compile   => each: element 0: [aql/undefined_word]: undefined word: bf
```

Inside the `each` the compiled path can't see the block-local `bf`, so
`bf Bloom.add …` raises `undefined word: bf`. The damage is that this leaks
through `--compile` (TRY): the emitter thinks it can lower the body, so it
does *not* fall back to the interpreter, and the wrong result escapes —
breaking the "identical, never semantics" guarantee. Trigger is narrow: a
*block-local* `def` referenced from an `each` body. A **top-level** binding
survives; a single-expression top-level loop is instead *refused* (`each`
Stage 2/3) and falls back cleanly. Upstream aql bug, not a bloom defect.

The fix on our side is one structural choice: `test/bloom_unit_test.aql`
builds its bulk fixture (`_seen`) at **top level** rather than inside the
`Test.test` block — keeping it in scope for the compiler, and (the leading
underscore) skipping `aql check`'s unused_def false positive for body-only
defs. With that, every suite is clean across all three surfaces
(interpreter, `aql check` with 0 errors, and `aql --compile` identical to
the interpreter); `test/divergence/run.sh` enforces it. Tested against aql
`c44d994` (the harness builds a newer aql than this module's pin, since the
bytecode CLI postdates `7193a7d3`). See `test/divergence/README.md`.

---

## Observations on the new build

- **The DX feedback loop works.** Six issues filed against `958c379b`
  were fixed within 39 commits, with commit messages that read
  straight off the report ("guards fire before the next statement",
  "per-instance mutable class defaults; open objects render"). A
  parallel report from the `aql:decision` module got the same
  treatment (`1981f601`), and that module moved out of core
  (`a7882da9`).
- **New language surface since `958c379b`** (not yet exercised by this
  module): lambda arrows (`(x:Integer => body)`, `ec35e87a`/
  `dfe262d6`), map overloads for `each`/`fold`/`filter` plus `keys`/
  `vals` and a `KeyVal` entry type (`c6ed6e1a`), a `canon` word for
  round-trippable source (`c0b727bf`), type-valued params
  (`ce9914a3`), and a categorised `describe` with guaranteed-complete
  word docs (`ce133d6c`/`fd82aee9`). The `keys`/`vals` words would
  have simplified the sparse-map bit store this module used two
  designs ago; the packed-Array design doesn't need them.
- **Stability:** all five suites, the AGENTS.md verification script,
  and both tutorial scripts produce byte-identical results on
  `958c379b` → `7193a7d3`. Hashing, sizing, encode payloads, and the
  measured tutorial false-positive rate (97/1000 at p = 0.1) are
  unchanged.

---

## Upgrade notes: `db828ec` → current main

Carried forward for anyone jumping from the older pin (all migrated in
this module's history):

| Change | Before | After |
|--------|--------|-------|
| `refine Object` removed | `def T (refine Object {…})` | `def T class {…}` (subclass: `refine <Class> {…}`) |
| `StringUtil.indexof` argument order | haystack-first (`indexof <haystack> <needle>`) | **haystack-last** (`indexof <needle> <haystack>`); whole string module is subject-last |
| Integer overflow | silent 64-bit wrap | hard `integer_overflow` error — mask (`BinUtil.band`) before multiplying if you relied on wrap |
| `set` on a mutable container | returned values varied | Store / Object / Array / class: writes in place, **returns nothing**; FlexMap/FlexList: returns the node; Map: returns a new map |
| `import` terminator | `import "x" end` required | `end` optional (structure-first); bare `import "x"` is the idiomatic form again |
| Custom errors | only the undefined-word idiom | `raise` (code, message — template literals fine, payload map form) |

---

## Summary

| # | Severity | Issue | Status vs `958c379b` |
|---|----------|-------|----------------------|
| — | — | guard `if` + following `def` pre-empted (was §1 🔴) | **fixed** (`00cb7a79`) |
| — | — | mutable class default shared across instances (was §2 🔴) | **fixed** (`607cd1b9`) |
| — | — | formatting an `Object` crashes (was §3 🔴) | **fixed** (`607cd1b9`) |
| — | — | `raise` rejects template messages (was §4 🟡) | **fixed** (`00cb7a79`) |
| — | — | `getr` code ≠ docs (was §6 🟢) | **fixed** (`93ebcd40`) |
| — | — | `jsonify` stringifies Floats (was §7 🟢) | **fixed** (`862546fd`) |
| 1 | 🟡 | `print` forward-collection reverses/breaks | unchanged (3rd report) |
| 2 | ✅ | `aql check`: false `mul` no_signature + export-map `unused_def` | **resolved** on `7b1a4fb` (0 errors; gating-ready) |
| 3 | ✅ | bytecode `--compile` block-local `each`-body divergence (+ two 2026-06-23 `main` regressions) | **fixed** upstream `f247557`/`fc47452`; harness pin moved to aql `407feda` |


---

# 2026-07-21 round: the `av` viewer on aql main @ `c1d2a1a`

**AQL build under test:** `aql-lang/aql` @ `c1d2a1a` (main, 2026-07-20),
built from source in-workspace (`cd cmd/go && go build ./aql`; note
`GOFLAGS=-mod=mod` now *fails* inside the aql workspace — "-mod may only
be set to readonly or vendor when in workspace mode" — the flag is only
for standalone clones).
**Context:** building `viewer/` — a jless-style TUI file viewer with
tabs and watch-reload, written in AQL on the freshly-landed `aql:tui`
stack (upstream 2026-07-17). First real-world exercise of `aql:tui`,
`aql:io` watching, the actor words, and deep cross-module call chains
from this repo. Everything below was hit while making the viewer work;
each verdict was isolated with a minimal repro where one exists. The
five viewer suites plus the headless app-integration suite are green on
this build; the Bloom library and its pin are untouched.

## New issues

### 5. 🔴 `def` from a call can silently fail to bind in deep call chains

In an update-loop chain (fn → `case` arm → fn → fn, as driven by
`Tui.run` or an equivalent fold), a `def` whose value is a call to a
**local alias fn** (a one-line wrapper around another module's export)
or to a **recursive fn** completes without binding — no error at the
def, then the *next* statement raises `undefined_word` for the name:

```aql
def with-active fn [[state:Map tab:Map] [Map] [ AvTabs.put-active state (tab) ]]
# inside a case arm several frames deep:
def s3 (with-active (s2) (tabw))     # completes, binds NOTHING
def err ((AvTabs.active (s3)) …)     # [aql/undefined_word]: s3
```

Replacing the alias with the direct module call (`def s3
(AvTabs.put-active (s2) (tabw))`) binds correctly; converting recursive
helpers (`add-ancestors`, `surviving-anchor`) to `fold`s fixed the same
failure in `AvTabs.reanchor`/`reveal`. The same shapes work when called
from a test body or the top level — only the deep chain misbinds, so a
green unit suite does not protect the composed program. Every viewer
module now avoids local alias fns and recursion in state-machinery as a
matter of policy. Not reduced to a standalone repro (context-sensitive);
the pre-fix shapes are in this repo's git history
(`viewer/av.aql`/`av-tabs.aql` before 7c6f739).

### 6. 🔴 `IO.watch` callbacks are never delivered while `Tui.run` runs

A watch registered from inside a `Tui.run` update never fires its body:
no callback, no `send`, nothing — while the *identical* registration in
a headless script delivers within milliseconds. Repro pair:

```aql
# headless: fires (op=write lands in /tmp/av-fire.txt)
def fire fn [[ev:Map] [Integer] [ IO.write (make Pathon "/tmp/av-fire.txt") "hit" end drop 0 ]]
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

### 7. 🔴 User multi-signature fn dispatch loses a value's concrete type

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
single-sig fns with native `is`-chains (`viewer/av-doc.aql`
`node-kind`/`get-seg`/`has-seg`); multi-sig overloads only where the
dispatch happens directly on an expression at the call site.

### 8. 🟡 A map literal returned from an fn body evaluates after teardown

`fn [[a:Integer b:Integer] [Map] [ {x: (b)} ]]` raises
`undefined_word: b` at call time: the returned map literal's `(…)`
values evaluate only after the call's params are gone (body-local defs
survive; params do not). **Workaround:** bind first — `def out {x:
(b)} out`. Used everywhere in `viewer/`.

### 9. 🟡 No script argv (and no env access)

`aql script.aql a b c` silently ignores `a b c` (the CLI reads only the
script path), and no word exposes environment variables. A CLI tool
written in AQL cannot receive "which file to open" from its command
line — the viewer's launch story is `aql av.aql` + `:open`, or an
`aql -e 'import … Av.run {files:[…]}'` one-liner. RFC:
`proposals/script-argv-and-env.md`.

### 10. 🟡 Checker friction: several false-error shapes gate execution

Plain `aql X` refuses to run on check *errors*, and these check-only
shapes all came up while building the viewer (workarounds in
parentheses; all shipped in `viewer/`):

- `is`-guarded branches don't narrow: `get`/`has` on a checker-typed
  disjunct is an error even though the branch guards it (→ overloads or
  is-chains behind an `[Any]` fn).
- A fold's accumulator is typed as the *element* type, so map-shaped
  accumulators error (→ restructure; see also §11).
- An IO-word result binds as an unresolved partial when an arg type
  mismatches — `IO.read "s"` needs `(make Pathon s)`; the follow-on
  errors ("cannot call `x`") point at every *use* of the binding.
- `convert String x` needs a statically-Scalar `x`; an Any-typed name
  inside `${…}` is treated as a zero-arg call (→ tiny typed coercion
  helpers `as-str`/`as-int`, typed accessors like `row-at`).
- `aql check viewer/av-nav.aql` from the repo root can't resolve the
  module's sibling `./av-doc.aql` import — a top-level *script*'s
  imports are CWD-relative; only *imported* modules resolve against
  their own directory (→ check intra-package modules from `viewer/`, or
  check the root launcher, which exercises the whole tree).

### 11. 🟡 `fold`'s var binding order contradicts its description

`describe fold` says "the accumulator is pushed first", and bloom-era
code reads `var [[acc x]]` — but the element is on *top*, so
`var [[a b]]` binds `a` = element, `b` = accumulator:

```aql
print (fold [ var [[a b] (a) ]] ["elem"] "init")   # elem — a is the ELEMENT
```

Commutative folds (`add`) mask the swap; anything asymmetric silently
computes garbage. The viewer's folds all read `var [[elem acc]]`.

### 12. 🟢 Map key order is always sorted

`{b:1, a:2}` stores, prints, and iterates as `a, b` — source order is
unrecoverable, so a JSON viewer cannot show keys in file order (jless
does). Documented as a viewer deviation.

### 13. 🟢 jsonic-family leniency swallows truncation

`{"a": 1, "b": ` parses without error to `{a:1, b:null}` on the
`json`/`jsonic` paths — a malformed file "loads fine" with partial
content. There is no strict mode on the `IO.read` formats. The viewer
surfaces only hard read/parse errors.

## What worked well (worth keeping)

- **`IO.read` is a one-stop loader**: extension-inferred parsing over
  the whole tabnas family (plus `{fmt}` override, `{field:
  {separation:"\t"}}` for CSV variants — the "no tsv parse kind" gap in
  earlier planning was wrong at the IO.read level; only the `parse`
  word's kind set lacks it). `viewer/av-fmt.aql` is ~40 lines because
  of this.
- **The `aql:tui` core held up**: alt-screen, diffed rendering, widget
  layout, key decoding, `Tui.quit`, and the "any mailbox message folds
  through update" contract all behaved exactly as specified —
  `send {…} "tui"` from a spawned process is a reliable event source.
- **`canon` is the right display serializer** (no HTML escaping, smart
  quote switching, `none`/numbers/bools render cleanly).
- **Headless TUI testing via an exported feed word**: exporting the
  update fold (`Av.feed`) lets a plain test suite drive the real app —
  command mode, tabs, search, watch-reload against real disk writes —
  with no terminal. Pattern recommended for any aql:tui app (an
  AQL-reachable virtual backend would still be better — see proposal).

## Summary (this round)

| # | Severity | Issue | Status |
|---|----------|-------|--------|
| 5 | 🔴 | silent `def`-binding failure in deep call chains (alias fns, recursion) | open; policy workaround |
| 6 | 🔴 | `IO.watch` callbacks starved under `Tui.run` | open; metronome+poll workaround |
| 7 | 🔴 | multi-sig dispatch degrades through Any params in each/cross-module chains | open; is-chain workaround |
| 8 | 🟡 | returned map literal evaluates after param teardown | open; def-then-return |
| 9 | 🟡 | no script argv / env access | open; RFC filed |
| 10 | 🟡 | checker false-error shapes gate `aql X` | open; typed-helper idioms |
| 11 | 🟡 | fold var order contradicts docs | open; element-first idiom |
| 12 | 🟢 | map keys always sorted | by design? documented |
| 13 | 🟢 | lenient parsing swallows truncation | by design; documented |
