#!/bin/bash
# SessionStart hook: ensure the `aql` interpreter is available so the agent can
# run aless and its tests. aless tracks aql MAIN (the aql:tui stack it needs
# postdates any tagged build), so this builds aql from the latest main.
#
# Synchronous and idempotent: skips the build if a binary already exists, and
# caches it into the container so later sessions are instant. Progress goes to
# stderr; stdout is left clean (SessionStart stdout is injected as context).
set -uo pipefail

# Web sessions are the target; locally a developer already has aql. No-op
# elsewhere. (Remove this guard to build everywhere.)
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

log() { echo "[session-start] $*" >&2; }

BIN_DIR="$HOME/.local/bin"
AQL="$BIN_DIR/aql"

# Persist PATH for the rest of the session.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export PATH=\"$BIN_DIR:\$PATH\"" >> "$CLAUDE_ENV_FILE"
fi
export PATH="$BIN_DIR:$PATH"

if command -v aql >/dev/null 2>&1 || [ -x "$AQL" ]; then
  log "aql already present ($("$AQL" -version 2>/dev/null || aql -version 2>/dev/null)); skipping build."
else
  if ! command -v go >/dev/null 2>&1; then
    log "WARNING: Go toolchain not found; cannot build aql. Install Go, then build aql from an aql-lang/aql checkout: cd cmd/go && go build -o \"$AQL\" ./aql"
    exit 0
  fi
  log "Building aql from aql-lang/aql main (one-time; cached afterwards)…"
  mkdir -p "$BIN_DIR"
  src="$(mktemp -d)"
  if git clone --quiet --depth 1 https://github.com/aql-lang/aql "$src"; then
    ref="$(git -C "$src" rev-parse --short HEAD 2>/dev/null || echo main)"
    # GOWORK=off: the aql repo ships a go.work, so disable workspace mode;
    # GOFLAGS=-mod=mod then builds the standalone clone.
    ( cd "$src/cmd/go" \
      && GOWORK=off GOFLAGS=-mod=mod go build \
           -ldflags "-X github.com/aql-lang/aql/cmd/go.Version=${ref}" \
           -o "$AQL" ./aql ) \
      && log "Built $("$AQL" -version 2>/dev/null)." \
      || log "WARNING: aql build failed; build manually from an aql checkout (cd cmd/go && go build -o \"$AQL\" ./aql)."
  else
    log "WARNING: could not fetch aql source (network?); build manually from an aql checkout."
  fi
  rm -rf "$src"
fi

# Fast confidence check: run the smoke suite if aql is usable. Never fail the
# session on a check error.
if [ -x "$AQL" ] && [ -f "$CLAUDE_PROJECT_DIR/test/aless_smoke_test.aql" ]; then
  if ( cd "$CLAUDE_PROJECT_DIR" && "$AQL" test/aless_smoke_test.aql >/dev/null 2>&1 ); then
    log "Smoke check passed (aql test/aless_smoke_test.aql)."
  else
    log "NOTE: smoke check did not pass; the aql toolchain may be incomplete or main may have regressed."
  fi
fi

exit 0
