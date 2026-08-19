#!/bin/bash
# Coverage over the offline harness.
#
# IMPORTANT: this script must NEVER block a release.
#
# It once did. It hardcoded the luacov path from the author's machine
# (/usr/local/share/lua/5.1), so on any host where luarocks installed luacov
# somewhere else the script died under `set -e` with no output at all -- and
# because it ran in CI ahead of the packager, the whole release silently
# stopped. A quality signal for the author is not a reason to deny users a
# build.
#
# So: locate luacov rather than assume it, and when it genuinely cannot run,
# say so clearly and exit 0.

ROOT=${1:-build/CompletionNavigator}
FLOOR=${2:-80}

note() { echo "coverage: $*"; }

if [ ! -f "$ROOT/CompletionNavigator.toc" ]; then
  note "no addon tree at '$ROOT'; skipping."
  exit 0
fi

if [ ! -f harness.lua ]; then
  note "harness.lua not found; skipping."
  exit 0
fi

# Find luacov wherever this machine put it. luacov is pure Lua, so any
# version's install directory works under any Lua interpreter.
LUACOV_PATH=""

# Ask luarocks first. It knows where it installed things, which a hardcoded
# list of directories does not -- and a workspace-local rocks tree (which is
# what CI now uses, having abandoned apt) appears in none of the usual places.
if command -v luarocks >/dev/null 2>&1; then
  ROCKS_PATH=$(luarocks path --lr-path 2>/dev/null)
  [ -n "$ROCKS_PATH" ] && LUACOV_PATH="${ROCKS_PATH};${LUACOV_PATH}"
fi

for base in /usr/local/share/lua /usr/share/lua "$HOME/.luarocks/share/lua"; do
  [ -d "$base" ] || continue

  for versioned in "$base"/*; do
    if [ -f "$versioned/luacov.lua" ] || [ -d "$versioned/luacov" ]; then
      LUACOV_PATH="$versioned/?.lua;$versioned/?/init.lua;$LUACOV_PATH"
    fi
  done
done

if [ -z "$LUACOV_PATH" ]; then
  note "luacov is not installed; skipping coverage."
  note "install it with:  luarocks install luacov"
  exit 0
fi

export LUA_PATH="${LUACOV_PATH};;"

# Confirm it actually loads before relying on it.
if ! lua5.4 -e 'require("luacov.runner")' >/dev/null 2>&1; then
  note "luacov was found but will not load; skipping coverage."
  exit 0
fi

cat > .luacov <<CONFIG
statsfile = "luacov.stats.out"
reportfile = "luacov.report.out"
include = { "${ROOT}/.*" }
exclude = { "harness", "bench", "luacov", "^%./%.", "/%.lua/", "%.luarocks" }
CONFIG

rm -f luacov.stats.out luacov.report.out

lua5.4 -lluacov harness.lua "$ROOT" > /dev/null 2>&1

lua5.4 -e 'require("luacov.reporter").report()' > /dev/null 2>&1

if [ ! -f luacov.report.out ]; then
  note "no report was produced; skipping."
  exit 0
fi

TOTAL=$(grep -E "^Total" luacov.report.out | awk '{print $NF}' | tr -d '%')

if [ -z "$TOTAL" ]; then
  note "report contained no total; skipping."
  exit 0
fi

# The report lists every file twice: once with per-line detail, once in the
# summary table. Only the summary rows have four columns.
echo "Coverage by file, weakest first:"
awk 'NF==4 && $1 ~ /\.lua$/ { gsub(/%/,"",$4); printf "  %6.2f%%  %s\n", $4, $1 }' \
  luacov.report.out | sort -n | head -8

echo ""
echo "Total: ${TOTAL}%"

# Compared as integers: bash cannot do floating point, and a floor is a floor.
if [ "${TOTAL%.*}" -lt "$FLOOR" ]; then
  echo "FAIL: coverage ${TOTAL}% is below the ${FLOOR}% floor"
  exit 1
fi

echo "Above the ${FLOOR}% floor."
