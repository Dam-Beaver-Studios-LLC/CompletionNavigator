#!/bin/bash
# Coverage over the offline harness.
#
# luacov installs under Lua 5.1 on this machine but is pure Lua, so 5.4 runs it
# fine with the path pointed at it.
set -e

ROOT=${1:-build/CompletionNavigator}
FLOOR=${2:-80}

LUA51="/usr/local/share/lua/5.1/?.lua;/usr/local/share/lua/5.1/?/init.lua;;"

# Write the config next to wherever we are running, so the same script works
# from the development tree and from a freshly scaffolded copy.
cat > .luacov <<CONFIG
statsfile = "luacov.stats.out"
reportfile = "luacov.report.out"
include = { "${ROOT}/.*" }
exclude = { "harness", "bench", "luacov" }
CONFIG

rm -f luacov.stats.out luacov.report.out

LUA_PATH="$LUA51" lua5.4 -lluacov harness.lua "$ROOT" > /dev/null 2>&1

LUA_PATH="$LUA51" lua5.4 -e 'require("luacov.reporter").report()' > /dev/null 2>&1

TOTAL=$(grep -E "^Total" luacov.report.out | awk '{print $NF}' | tr -d '%')

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
