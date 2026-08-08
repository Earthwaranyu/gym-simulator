#!/usr/bin/env bash
# Runs every static check over src/: formatting, lints, and --!strict type analysis.
# Usage: ./scripts/check.sh [--fix]
#
# --fix applies StyLua formatting instead of only reporting it.

set -euo pipefail

cd "$(dirname "$0")/.."

DEFS=".luau-defs/globalTypes.d.luau"
DEFS_URL="https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.d.luau"

status=0

if [[ "${1:-}" == "--fix" ]]; then
	echo "==> stylua (applying)"
	stylua src
else
	echo "==> stylua --check"
	stylua --check src || status=1
fi

echo "==> selene"
selene src || status=1

# luau-lsp needs the Roblox API surface and a map from file paths to instance paths.
# Both are generated artefacts, so they are fetched on demand and gitignored.
if [[ ! -f "$DEFS" ]]; then
	echo "==> fetching Roblox type definitions"
	mkdir -p "$(dirname "$DEFS")"
	curl -fsSL -o "$DEFS" "$DEFS_URL"
fi

echo "==> rojo sourcemap"
rojo sourcemap default.project.json -o sourcemap.json

echo "==> luau-lsp analyze (--!strict)"
# Capture rather than test the pipeline directly: luau-lsp exits non-zero when it
# finds errors, and under `set -o pipefail` that status masks grep's, which silently
# inverted this check and reported success while errors were printed.
analysis=$(luau-lsp analyze --sourcemap=sourcemap.json --definitions="$DEFS" src 2>&1 |
	grep -v '^\[INFO\]' | grep -v '^\[WARN\]' || true)

if [[ -n "$analysis" ]]; then
	echo "$analysis"
	status=1
else
	echo "no type errors"
fi

# Balance is the one thing here that breaks quietly: a retuned weight still
# compiles, still type-checks, and still lints. These are the invariants that say
# whether PvP is still playable, and they run in milliseconds because Formulas
# touches no Roblox API.
echo "==> self-tests"
luau scripts/selftest.luau || status=1

# The world generator is code too. This catches stale model JSON, duplicated map
# destinations, broken machine contracts, unbalanced variants, and a regression
# back to the old rectangular grid before Rojo ever opens the place.
echo "==> generated gym"
python3 scripts/validate_gym.py || status=1

# The economy simulator reads the real configs through a generated module. If a
# balance number moved and nobody regenerated it, every projection in the model is
# stale — which is worse than having no model, because it still looks authoritative.
echo "==> balance inputs"
python3 scripts/extract_balance.py --check || status=1

if [[ $status -eq 0 ]]; then
	echo
	echo "All checks passed."
else
	echo
	echo "Checks FAILED." >&2
fi

exit $status
