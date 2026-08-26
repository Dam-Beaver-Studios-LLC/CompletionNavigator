#!/bin/bash
# cisim.sh -- run the release workflow's own steps, locally, before tagging.
#
# WHY THIS EXISTS.
#
# Four consecutive releases were tagged, pushed, reported as published, and
# never reached CurseForge. Each died at a different step of the GitHub
# workflow -- the .toc audit, then Lint, then the offline harness -- and each
# was discovered only by pushing a tag, waiting, and reading a web page. Every
# one of them was reproducible in seconds on this machine, and nothing here
# ran them.
#
# The local suite ran *equivalents* of those steps: `luacheck build/...`,
# `lua5.4 harness.lua build/...`. The workflow runs `luacheck .` and
# `lua5.4 harness.lua .` against a SCAFFOLDED TREE, from the repository root,
# with whatever else happens to be in the working directory. Those are not the
# same command in the same place, and the difference is exactly where all four
# failures lived.
#
# So this does not re-implement the workflow. It EXTRACTS each `run:` block
# from .github/workflows/release.yml and executes it, in a scaffolded tree, in
# order, stopping at the first non-zero exit -- the same way the runner does.
#
# Usage:  ./cisim.sh [path-to-cn.ps1]
set -u

SRC=${1:-/home/claude/cn/out/cn.ps1}
PWSH=/opt/pwsh/pwsh

WORK=$(mktemp -d)

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

echo "CI simulation :: $(basename "$SRC")"

cp "$SRC" "$WORK/cn.ps1"
cd "$WORK" || exit 1

$PWSH -NoProfile -File ./cn.ps1 init > init.log 2>&1 || {
    echo "  FAIL  scaffold failed"; cat init.log; exit 1; }

# The runner checks the repository out with LF endings -- .gitattributes
# normalizes on the way in. The scaffold writes CRLF, and comparing CRLF text
# with grep -qxF reports every file in the addon as missing from the .toc.
# Simulating the workflow without simulating the checkout tests nothing.
find . -type f \( -name '*.lua' -o -name '*.toc' -o -name '*.xml' \
    -o -name '*.md' -o -name '*.sh' -o -name '.pkgmeta' -o -name '*.yml' \) \
    -exec sed -i 's/\r$//' {} \; 2>/dev/null

# THE RECORDING GOES IN TOO.
#
# The repository has one, and the step that finally exposed the broken
# fixtures writer was the offline harness reading it. A simulation of a
# repository that omits the file the repository actually contains is a
# simulation of a different repository.
if [ -f /home/claude/cn/build/fixtures/captured.lua ]; then
    mkdir -p fixtures
    cp /home/claude/cn/build/fixtures/captured.lua fixtures/captured.lua
fi

# A git repository, because a step asks git what tag points at HEAD.
git init -q -b main . 2>/dev/null
git config user.email ci@example.com
git config user.name CI
git add -A >/dev/null 2>&1
git commit -qm "ci simulation" >/dev/null 2>&1
git tag v0.0.0-cisim 2>/dev/null

export GITHUB_REF="refs/tags/v0.0.0-cisim"
export GITHUB_REF_NAME="v0.0.0-cisim"
export CF_API_KEY="cisim-placeholder"

# Extract every `run:` block from the workflow, with the step name that owns
# it, and execute them in order.
python3 - <<'EXTRACT'
import re, os

text = open('.github/workflows/release.yml', encoding='utf-8').read()

lines = text.split('\n')

steps = []
name = None
limit = None
soft = False
i = 0

while i < len(lines):
    line = lines[i]

    match = re.match(r'^\s*-\s+name:\s*(.+?)\s*$', line)

    if match:
        name = match.group(1)
        limit = None
        soft = False
        i += 1
        continue

    # THE RUNNER'S OWN LIMITS, CARRIED THROUGH. 0.67.1.
    #
    # This script existed to stop a step passing here and failing there, and
    # it read only the commands -- so the two constraints the runner enforces
    # around them were invisible to it. A step with `timeout-minutes: 8` that
    # takes nine here was reported as passing, and a step marked
    # `continue-on-error` was treated as fatal, which is the opposite of what
    # the runner does with it.
    cap = re.match(r'^\s*timeout-minutes:\s*(\d+)\s*$', line)

    if cap:
        limit = int(cap.group(1))
        i += 1
        continue

    soften = re.match(r'^\s*continue-on-error:\s*(true|false)\s*$', line)

    if soften:
        soft = soften.group(1) == 'true'
        i += 1
        continue

    # `run: |` opens a block; `run: something` is a one-liner.
    block = re.match(r'^(\s*)run:\s*\|\s*$', line)

    if block:
        indent = len(block.group(1))
        body = []
        i += 1

        while i < len(lines):
            nxt = lines[i]

            if nxt.strip() == '':
                body.append('')
                i += 1
                continue

            if len(nxt) - len(nxt.lstrip()) <= indent:
                break

            body.append(nxt)
            i += 1

        # Strip the common indent.
        trim = min((len(b) - len(b.lstrip()) for b in body if b.strip()),
                   default=0)

        steps.append((name, '\n'.join(b[trim:] for b in body), limit, soft))
        continue

    inline = re.match(r'^\s*run:\s*(\S.*?)\s*$', line)

    if inline:
        steps.append((name, inline.group(1), limit, soft))

    i += 1

with open('.cisim-steps', 'w', encoding='utf-8') as fh:
    for index, (label, body, limit, soft) in enumerate(steps):
        fh.write('=== %d\t%s\t%s\t%s\n' % (index, label or '(unnamed)',
                                              limit if limit else '0',
                                              '1' if soft else '0'))
        fh.write(body)
        fh.write('\n=== end\n')

print('  %d run-steps extracted' % len(steps))
EXTRACT

[ -f .cisim-steps ] || { echo "  FAIL  could not read the workflow"; exit 1; }

# Steps that cannot be simulated here, with the reason stated rather than
# silently skipped. A skip nobody can see is how a step stops being checked.
SKIP_PATTERN='^(Fetch tags|Verify a tag points at HEAD)$'

status=0
ran=0
skipped=0

# ------------------------------------------------------------
# PREFLIGHT: A COMMAND NOTHING INSTALLS IS AN EXIT 127 WAITING FOR A TAG.
#
# 0.61.0 died on the runner with "Process completed with exit code 127" --
# command not found. The Performance budgets step called `lua5.1` directly,
# the runner does not have it, and nothing here noticed because THIS MACHINE
# does. That is precisely the failure mode this whole script exists to
# prevent: a step that passes locally and cannot pass there.
#
# So the steps are read for bare invocations of the interpreters and tools
# this workflow depends on, and each one must either be installed by the
# workflow's own "Install Lua tooling" step or be guarded by `command -v`.
# Whether it happens to exist locally is not evidence about the runner.
# ------------------------------------------------------------
# ONLY LINES THAT ACTUALLY INSTALL SOMETHING.
#
# The first version of this grepped the whole Install step for the tool's
# name, and the step's own comment and its "could not be installed" warning
# both contain it -- so the check passed on prose and the preflight said
# nothing. Comments and echoes are stripped, and what remains must be an
# install or a symlink.
# THE END MARKER MATCHES THE START PATTERN, SO IT IS TESTED FIRST.
#
# Steps are delimited `=== <n>\t<label>` ... `=== end`, and `/^=== /` matches
# BOTH. With the start rule first, every `=== end` reset the body before the
# end rule could read it, so the body was always empty and the preflight
# checked nothing while reporting success -- a check that cannot fail, which
# is worse than no check.
install_body=$(awk '
    /^=== end/{ collecting = 0; next }
    /^=== /{ collecting = ($0 ~ /Install Lua tooling/) ? 1 : 0; next }
    !collecting { next }
    /^ *#/ { next }
    /echo / { next }
    /(apt-get +install|luarocks +install|ln +-sf|apk +add|brew +install)/ { print }
' .cisim-steps)

preflight=0

for tool in lua5.1 lua5.2 lua5.3 lua5.4 luac5.1 luac5.4 luacheck luacov busted; do
    # Every step that invokes the tool as a command.
    if ! grep -qE "(^|[^-[:alnum:]_./])${tool}[[:space:]]" .cisim-steps 2>/dev/null; then
        continue
    fi

    # Installed by the workflow itself?
    if printf '%s' "$install_body" | grep -q "$tool"; then
        continue
    fi

    # Every invocation guarded by a presence check in its own step?
    # `&&` TRAILS THE LINE. mawk continues a condition after a trailing
    # operator and refuses one that begins with it, which is how the first
    # version of this printed six syntax errors and checked nothing.
    unguarded=$(awk -v tool="$tool" '
        /^=== end/{
            uses = (body ~ ("(^|[^-[:alnum:]_./])" tool "[ \t]"))
            seen = (body ~ ("command -v " tool)) ||
                   (body ~ ("which " tool)) ||
                   (body ~ ("hash " tool))
            # The Install step naming a tool is it INSTALLING the tool, not
            # depending on one that may be absent.
            if (uses && !seen && label !~ /Install Lua tooling/) {
                sub(/^=== [0-9]*\t?/, "", label)
                print label
            }
            next
        }
        /^=== /{ label = $0; body = ""; next }
        { body = body $0 " " }
    ' .cisim-steps)

    if [ -n "$unguarded" ]; then
        echo "  PREFLIGHT FAIL  '$tool' is neither installed by the workflow"
        echo "                  nor guarded, in: $unguarded"
        echo "                  On a runner without it that step exits 127."
        preflight=1
    fi
done

if [ "$preflight" -ne 0 ]; then
    echo ""
    echo "A workflow step would fail on the runner with command-not-found."
    exit 1
fi

label=""
body=""
collecting=0

while IFS= read -r line; do
    case "$line" in
        "=== end")
            collecting=0

            if [[ "$label" =~ $SKIP_PATTERN ]]; then
                echo "  skip  $label  (needs the real tag push)"
                skipped=$((skipped + 1))
            else
                printf '  ....  %s\r' "$label"

                # THE RUNNER'S OWN CLOCK. 0.67.1.
                #
                # `timeout-minutes` is the constraint this script was blindest
                # to: a step that takes nine minutes here and is capped at
                # eight there passed locally and was killed on the runner,
                # which is exactly the "passes here, fails there" shape the
                # whole script exists to prevent. Enforced with a margin of
                # ZERO -- this machine is FASTER than a two-core runner, so a
                # step that only just fits here does not fit there.
                started=$(date +%s)

                if [ "${limit:-0}" != "0" ] && command -v timeout >/dev/null 2>&1; then
                    timeout "${limit}m" bash -c "$body" > step.log 2>&1
                    code=$?
                else
                    bash -c "$body" > step.log 2>&1
                    code=$?
                fi

                elapsed=$(( $(date +%s) - started ))

                if [ "$code" -eq 0 ]; then
                    # A STEP THAT ONLY JUST FITS IS A STEP THAT WILL NOT.
                    #
                    # The runner has two cores and this machine has more, so
                    # anything past two thirds of its budget here is over
                    # budget there. Said out loud rather than left to be
                    # discovered by a failed release.
                    if [ "${limit:-0}" != "0" ] \
                        && [ "$elapsed" -gt $(( limit * 40 )) ]; then

                        printf '  ok    %s  <-- %ss of a %sm budget; the runner is slower\n' \
                            "$label" "$elapsed" "$limit"
                    else
                        printf '  ok    %s\n' "$label"
                    fi

                    ran=$((ran + 1))
                elif [ "$code" -eq 124 ]; then
                    printf '  TIMEOUT  %s  (killed at %s minutes, as the runner would)\n' \
                        "$label" "$limit"
                    echo ''
                    tail -20 step.log | sed 's/^/        /'

                    if [ "${soft:-0}" = "1" ]; then
                        echo '        this step is continue-on-error, so the runner would'
                        echo '        not fail the job -- it would simply stop running.'
                        ran=$((ran + 1))
                    else
                        status=1
                        break
                    fi
                else
                    if [ "${soft:-0}" = "1" ]; then
                        # THE RUNNER DOES NOT FAIL ON THESE, SO NEITHER DOES
                        # THIS -- but silence is how a step stops being
                        # checked, so it is named.
                        printf '  warn  %s  (failed; continue-on-error, as on the runner)\n' \
                            "$label"
                        grep -vE 'OK$' step.log | sed 's/^/        /' | tail -12
                        ran=$((ran + 1))
                    else
                        printf '  FAIL  %s\n' "$label"
                        echo ''
                        # OK lines are the ones that did NOT fail, and a
                        # 25-line tail of a 200-file lint run shows nothing but
                        # those -- which is how a failing step got reported with
                        # no failure visible in it. 0.61.0.
                        grep -vE 'OK$' step.log | sed 's/^/        /' | tail -40
                        status=1
                        break
                    fi
                fi
            fi

            label=""
            body=""
            ;;
        "=== "*)
            label=$(printf '%s' "$line" | cut -f2)
            limit=$(printf '%s' "$line" | cut -f3)
            soft=$(printf '%s' "$line" | cut -f4)
            collecting=1
            body=""
            ;;
        *)
            if [ "$collecting" -eq 1 ]; then
                body="$body$line"$'\n'
            fi
            ;;
    esac
done < .cisim-steps

echo ""

if [ "$status" -eq 0 ]; then
    echo "Every simulated workflow step passed. ($ran ran, $skipped skipped)"
else
    echo "A workflow step failed HERE, which means it would fail on the runner."
fi

exit $status
