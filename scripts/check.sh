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

if [[ $status -eq 0 ]]; then
	echo
	echo "All checks passed."
else
	echo
	echo "Checks FAILED." >&2
fi

exit $status
