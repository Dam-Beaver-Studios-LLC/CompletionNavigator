#!/bin/bash
# End-to-end test of cn.ps1 against a real PowerShell host and a real git
# remote. This is what was missing when a broken release path shipped.
set -e
PWSH=/opt/pwsh/pwsh
SRC=/home/claude/cn/out/cn.ps1
WORK=$(mktemp -d)
REMOTE=$(mktemp -d)/remote.git
VERSION=$(grep -oP 'ToolkitVersion = .\K[0-9.]+' "$SRC" | head -1)

echo "Toolkit version: $VERSION"

$PWSH -NoProfile -Command "
\$e=\$null;\$t=\$null
[System.Management.Automation.Language.Parser]::ParseFile('$SRC',[ref]\$t,[ref]\$e)|Out-Null
if(\$e){\$e|%{Write-Host (\"line {0}: {1}\" -f \$_.Extent.StartLineNumber,\$_.Message)};exit 1}
Write-Host '  parse ok'"

cp "$SRC" "$WORK/cn.ps1"
cd "$WORK"

echo "  init"
$PWSH -NoProfile -File ./cn.ps1 init > init.log 2>&1
FILES=$(grep -cE "wrote  .*\.lua$" init.log)
echo "    $FILES lua files scaffolded"
# Count the ORDER list specifically, not every quoted .lua string in gen.py.
# Grepping the whole file counted names that appear elsewhere in it and made
# this check fail for a reason that had nothing to do with the scaffold.
EXPECTED=$(python3 -c "
import re
text = open('/home/claude/cn/gen.py').read()
block = re.search(r'^ORDER = \[(.*?)^\]', text, re.S | re.M).group(1)
print(len(re.findall(r'\"[^\"]+\.lua\"', block)))
")
[ "$FILES" -eq "$EXPECTED" ] || { echo "FAIL: expected $EXPECTED lua files, scaffolded $FILES"; exit 1; }

# The .toc must list only what the CLIENT loads. harness.lua stubs the whole
# client API; listing it would replace live functions with fakes in game.
grep -q 'harness.lua' CompletionNavigator.toc && { echo "FAIL: harness.lua is in the .toc"; exit 1; }
grep -q 'bench.lua'   CompletionNavigator.toc && { echo "FAIL: bench.lua is in the .toc"; exit 1; }
[ -f harness.lua ] || { echo "FAIL: harness.lua was not scaffolded"; exit 1; }
echo "    test tooling present and excluded from the .toc"
[ -f Media/Logo.tga ] || { echo "FAIL: Media/Logo.tga not scaffolded"; exit 1; }

echo "  check"
$PWSH -NoProfile -File ./cn.ps1 check > check.log 2>&1
grep -q "All checks passed" check.log || { echo "FAIL: fresh scaffold does not pass check"; cat check.log; exit 1; }

echo "  release guard: the project page must be reviewed"
# A release with no user-visible change legitimately needs no new copy -- but
# that has to be a decision somebody made. It was not; it was an omission, and
# the author had to ask why the description had not been updated.
cp _curseforge/REVIEWED.txt _curseforge/REVIEWED.bak
printf '0.0.1\n' > _curseforge/REVIEWED.txt
$PWSH -NoProfile -File ./cn.ps1 check 2>&1 | grep -q "last reviewed for 0.0.1" \
  || { echo "FAIL: a stale project-page review must block the release"; exit 1; }
mv _curseforge/REVIEWED.bak _curseforge/REVIEWED.txt
$PWSH -NoProfile -File ./cn.ps1 check > check2.log 2>&1
grep -q "All checks passed" check2.log \
  || { echo "FAIL: check does not pass once the page is reviewed"; cat check2.log; exit 1; }

echo "  release guard: wrong version"
$PWSH -NoProfile -File ./cn.ps1 release 9.9.9 2>&1 | grep -q "carries version $VERSION" \
  || { echo "FAIL: wrong-version guard"; exit 1; }
grep -q "## Version: $VERSION" CompletionNavigator.toc || { echo "FAIL: guard modified the tree"; exit 1; }

git init -q -b main . && git config user.email t@e.com && git config user.name T
git add -A >/dev/null 2>&1 && git commit -qm init
git init -q --bare "$REMOTE" && git remote add origin "$REMOTE" && git push -q -u origin main

echo "  release: happy path"
$PWSH -NoProfile -File ./cn.ps1 release "$VERSION" > release.log 2>&1
grep -q "Pushed v$VERSION" release.log || { echo "FAIL: release did not push"; cat release.log; exit 1; }
grep -q "RemoteException" release.log && { echo "FAIL: git output rendered as exception type"; exit 1; }

echo "  release guard: duplicate tag"
$PWSH -NoProfile -File ./cn.ps1 release "$VERSION" 2>&1 | grep -q "already exists" \
  || { echo "FAIL: duplicate-tag guard"; exit 1; }

echo "  doctor"
$PWSH -NoProfile -File ./cn.ps1 doctor > doctor.log 2>&1
grep -q "v$VERSION is on the remote" doctor.log || { echo "FAIL: doctor"; cat doctor.log; exit 1; }

echo "  harvest: SavedVariables -> Data\\Quests.lua"
cat > sv.lua <<'SAVEDVARS'

CompletionNavigatorDB = {
	["account"] = {
		["questHarvest"] = {
			[8237] = {
				["name"] = "Already Curated",
				["mapID"] = 94,
				["x"] = 0.42,
				["y"] = 0.55,
			},
			[71234] = {
				["name"] = "A Quest With \"Quotes\" In It",
				["zone"] = "Valdrakken",
				["mapID"] = 2112,
				["x"] = 0.611,
				["y"] = 0.482,
				["maybeRequires"] = {
					1, 2,
				},
			},
			[99001] = {
				["name"] = "No Coordinates Known",
			},
		},
		["questMetadata"] = {
			[555] = { ["name"] = "Must Not Be Imported" },
		},
	},
}
SAVEDVARS

$PWSH -NoProfile -File ./cn.ps1 harvest ./sv.lua > harvest.log 2>&1
grep -q "new rows to add            1" harvest.log \
  || { echo "FAIL: harvest should add exactly one located, uncurated quest"; cat harvest.log; exit 1; }

grep -q '71234' Data/Quests.lua || { echo "FAIL: harvested quest not written"; exit 1; }
grep -q '555'   Data/Quests.lua && { echo "FAIL: questMetadata leaked into the static database"; exit 1; }
grep -q '99001' Data/Quests.lua && { echo "FAIL: unlocated quest added without -Force"; exit 1; }

# Escaped quotes must survive the round trip, and the file must still be Lua.
grep -q 'A Quest With .* In It' Data/Quests.lua || { echo "FAIL: quoted name mangled"; exit 1; }
luac5.4 -p Data/Quests.lua || { echo "FAIL: harvest produced invalid Lua"; exit 1; }

# Running it again must add nothing.
$PWSH -NoProfile -File ./cn.ps1 harvest ./sv.lua > harvest2.log 2>&1
grep -q "Nothing to add" harvest2.log || { echo "FAIL: harvest is not idempotent"; cat harvest2.log; exit 1; }

# -Force reaches the unlocated ones.
$PWSH -NoProfile -File ./cn.ps1 harvest ./sv.lua -Force > harvest3.log 2>&1
grep -q '99001' Data/Quests.lua || { echo "FAIL: -Force did not include unlocated quests"; exit 1; }
luac5.4 -p Data/Quests.lua || { echo "FAIL: -Force harvest produced invalid Lua"; exit 1; }

# Leave the tree clean for the release steps below.
git checkout -- Data/Quests.lua 2>/dev/null || true
rm -f sv.lua harvest*.log

echo "  harness runs exactly as CI runs it"
# CI invokes `lua5.4 harness.lua .` from the repository root. Everything else
# here runs it from the development tree with a path argument, so this is the
# one check that matches what the runner actually does.
(cd "$WORK" && lua5.4 harness.lua . > ciharness.log 2>&1) || {
  echo "FAIL: the harness does not pass the way CI runs it"
  tail -20 "$WORK/ciharness.log"; exit 1; }
grep -q "ALL HARNESS CHECKS PASSED" "$WORK/ciharness.log" || {
  echo "FAIL: harness did not report success"; tail -20 "$WORK/ciharness.log"; exit 1; }
echo "    passed from the repository root"

echo "  luacheck runs exactly as CI runs it"
if command -v luacheck >/dev/null 2>&1; then
  (cd "$WORK" && luacheck . --no-color > cilint.log 2>&1) || {
    echo "FAIL: luacheck does not pass the way CI runs it"
    tail -20 "$WORK/cilint.log"; exit 1; }
  echo "    $(grep -oE 'Total: [0-9]+ warnings / [0-9]+ errors' "$WORK/cilint.log")"
fi

echo "  the project page ships with the code"
[ -f "$WORK/_curseforge/DESCRIPTION.md" ] || {
  echo "FAIL: the CurseForge description was not scaffolded"; exit 1; }
[ -f "$WORK/_curseforge/SUMMARY.txt" ] || {
  echo "FAIL: the CurseForge summary was not scaffolded"; exit 1; }

# The packaged addon must NOT contain it. It belongs in the repository, not
# in a player's AddOns folder.
grep -q "_curseforge" "$WORK/.pkgmeta" || {
  echo "FAIL: .pkgmeta does not exclude _curseforge from the package"; exit 1; }

# House rules, enforced rather than merely written down. Public-facing copy
# for this project carries a heightened bar: no superlatives, no claims of
# being the best or only anything, no promises about outcomes.
#
# Two hard limits sit alongside them. The summary has a length CurseForge
# will reject beyond, and the description is pasted verbatim -- so an HTML
# comment in it is a private note published by accident, invisible when
# rendered and plainly readable to anyone who opens the file.
python3 - "$WORK/_curseforge/DESCRIPTION.md" "$WORK/_curseforge/SUMMARY.txt" <<'COPYLINT'
import re, sys

banned = [
    r"\bthe best\b", r"\bbest[- ]in[- ]class\b", r"\bworld[- ]class\b",
    r"\bultimate\b", r"\bunmatched\b", r"\bunrivall?ed\b",
    r"\bsuperior to\b", r"\bbetter than\b", r"\bthe only addon\b",
    r"\bguarantee[ds]?\b", r"\bwill ensure\b", r"\bnever miss\b",
    r"\bperfect\b", r"\bflawless\b", r"\brevolutionary\b",
    r"\bgame[- ]changing\b", r"\bmust[- ]have\b",
]

problems = []

for path in sys.argv[1:]:
    text = open(path, encoding="utf-8").read()

    # The comment block states the rules; it is allowed to name them.
    body = re.sub(r"<!--.*?-->", "", text, flags=re.S)

    for pattern in banned:
        for match in re.finditer(pattern, body, re.I):
            line = body.count("\n", 0, match.start()) + 1
            problems.append("%s:%d: %s" % (path.split("/")[-1], line, match.group(0)))

description, summary = sys.argv[1], sys.argv[2]

# CurseForge rejects a summary over 256 characters outright.
summary_text = open(summary, encoding="utf-8").read().strip()

if len(summary_text) > 256:
    problems.append("SUMMARY.txt is %d characters; the limit is 256"
                    % len(summary_text))

if "\n" in summary_text:
    problems.append("SUMMARY.txt must be a single line")

# The description is pasted verbatim into a public page. Nothing internal
# belongs in it, including inside a comment nobody expected to be read.
body = open(description, encoding="utf-8").read()

if re.search(r"<!--", body):
    problems.append("DESCRIPTION.md contains an HTML comment; internal notes "
                    "belong in RULES.md, which is not published")

if not body.lstrip().startswith("# Completion Navigator"):
    problems.append("DESCRIPTION.md must open with the title heading")

if problems:
    print("FAIL: public-facing copy breaks the house rules")
    for problem in problems:
        print("  " + problem)
    sys.exit(1)

print("    copy passes the house rules (%d/256 chars)" % len(summary_text))
COPYLINT

echo "  CI ignores the toolchain it installs into the workspace"
# CI builds Lua and LuaRocks into .lua/ in the repository root. Two distinct
# problems follow, and a release failed on both at once:
#
#   1. The install directory is itself named `.lua`, so `-name '*.lua'` matched
#      a DIRECTORY and luac was handed it. "cannot read ./.lua: Is a directory".
#   2. Under it sit thousands of third-party files, some deliberately malformed
#      because they are another project's test fixtures.
#
# Poison the tree the same way the runner does -- a directory named .lua, and a
# broken file inside it -- and prove the checks skip both.
mkdir -p "$WORK/.lua/share/lua/5.4"
printf 'this is not ) valid lua ((\n' > "$WORK/.lua/share/lua/5.4/fixture.lua"

(cd "$WORK" && \
  find . -type f -name '*.lua' -not -path './.*' -exec luac5.4 -p {} + > poison.log 2>&1) || {
  echo "FAIL: the syntax check walks into the installed toolchain"
  tail -10 "$WORK/poison.log"; exit 1; }

if command -v luacheck >/dev/null 2>&1; then
  (cd "$WORK" && luacheck . --no-color > poisonlint.log 2>&1) || {
    echo "FAIL: luacheck analyses the installed toolchain"
    tail -10 "$WORK/poisonlint.log"; exit 1; }
fi

rm -rf "$WORK/.lua" "$WORK/poison.log" "$WORK/poisonlint.log"
echo "    third-party .lua files under dotted directories are skipped"

echo "  CI: no Lua search may walk the workspace toolchain"
python3 - "$WORK/.github/workflows/release.yml" <<'FINDLINT'
import re, sys

text = open(sys.argv[1], encoding="utf-8").read()

searches = [line.strip() for line in text.splitlines()
            if re.search(r"find .*-name '\*\.lua'", line)]

if not searches:
    print("FAIL: no Lua file search found; this lint is checking nothing.")
    sys.exit(1)

bad = [line for line in searches
       if "-not -path './.*'" not in line or "-type f" not in line]

if bad:
    print("FAIL: a Lua file search is not scoped to our own files")
    for line in bad:
        print("  " + line)
    print("  Needs -type f (the install directory is NAMED .lua) and")
    print("  -not -path './.*' (the toolchain lives inside it).")
    sys.exit(1)

print("    every Lua search is scoped to our own files")
FINDLINT

echo "  coverage: harness exercises the addon"
if command -v luacov >/dev/null 2>&1; then
  # Run against the scaffolded tree, which is what actually ships.
  # init writes files without the execute bit; invoke through the shell.
  (cd "$WORK" && bash coverage.sh . 80 > coverage.log 2>&1) || {
    echo "FAIL: coverage below floor"; tail -15 "$WORK/coverage.log"; exit 1; }
  echo "    $(grep '^Total:' "$WORK/coverage.log")"
else
  echo "    luacov not installed; skipped"
fi

echo "  luacheck: static analysis of the scaffolded tree"
if command -v luacheck >/dev/null 2>&1; then
  cp /home/claude/cn/build/CompletionNavigator/.luacheckrc "$WORK/.luacheckrc"
  (cd "$WORK" && luacheck . --no-color > luacheck.log 2>&1) || {
    echo "FAIL: luacheck reported problems"; tail -30 "$WORK/luacheck.log"; exit 1; }
  echo "    $(grep -oE 'Total: [0-9]+ warnings / [0-9]+ errors' "$WORK/luacheck.log")"
else
  echo "    luacheck not installed; skipped"
fi

echo "  coverage degrades instead of blocking"
# A developer tool being absent must never stop a release. This exact failure
# shipped: coverage.sh hardcoded a luacov path, died on the CI runner, and the
# packager never ran -- so a tagged release never reached CurseForge.
#
# Every way coverage.sh can find luacov must be blinded, or this passes while
# proving nothing: once it learned to ask luarocks, blanking the hardcoded
# directories alone left it finding luacov anyway.
(cd "$WORK" && sed 's#/usr/local/share/lua#/nonexistent/share/lua#g; s#/usr/share/lua#/nonexistent2/share/lua#g; s#$HOME/.luarocks/share/lua#/nonexistent3#g; s#command -v luarocks#command -v definitely-not-luarocks#g' coverage.sh > coverage_nolua.sh \
  && bash coverage_nolua.sh . 80 > nolua.log 2>&1)
NOLUA=$?
if [ "$NOLUA" -ne 0 ]; then
  echo "FAIL: coverage.sh exits non-zero when luacov is missing; that blocks releases"
  cat "$WORK/nolua.log"
  exit 1
fi
grep -q "skipping" "$WORK/nolua.log" || {
  echo "FAIL: coverage.sh must say why it skipped"; cat "$WORK/nolua.log"; exit 1; }
echo "    $(head -1 "$WORK/nolua.log")"

echo "  CI: the job cannot hang indefinitely"
python3 - "$WORK/.github/workflows/release.yml" <<'TIMEOUT'
import re, sys

text = open(sys.argv[1], encoding="utf-8").read()

if not re.search(r"^\s*timeout-minutes:\s*\d+", text, re.M):
    print("FAIL: the workflow has no timeout-minutes anywhere.")
    print("  A hung step runs for six hours and looks identical to a working one.")
    sys.exit(1)

# The job itself must be bounded, not only individual steps.
job_timeout = re.search(r"runs-on:.*?\n(?:.*?\n)*?\s*timeout-minutes:\s*(\d+)", text)

if not job_timeout:
    print("FAIL: the job has no timeout-minutes; only steps are bounded.")
    sys.exit(1)

minutes = int(job_timeout.group(1))

if minutes > 60:
    print("FAIL: job timeout of %d minutes is too generous to notice a hang" % minutes)
    sys.exit(1)

print("    job bounded at %d minutes" % minutes)
TIMEOUT

echo "  CI: the toolchain does not come from the runner's package manager"
python3 - "$WORK/.github/workflows/release.yml" <<'APTLOCK'
import re, sys

text = open(sys.argv[1], encoding="utf-8").read()

# A fresh runner holds the dpkg lock via unattended-upgrades. apt-get has no
# default timeout on that lock: it waits silently, forever. One release wedged
# there for thirty-eight minutes. Bounding the wait did not help -- the lock
# was still held, so the install failed instead of hanging.
#
# The toolchain now comes from setup actions that build into the workspace,
# contending with nothing. Any apt-get reintroduced here must at minimum bound
# the lock wait, and must not be how Lua itself arrives.
calls = [line.strip() for line in text.splitlines()
         if re.search(r"\bapt-get\b", line)
         and not line.strip().startswith("#")]

unbounded = [c for c in calls if "DPkg::Lock::Timeout" not in c]

if unbounded:
    print("FAIL: apt-get invocation with no dpkg lock timeout")
    for call in unbounded:
        print("  " + call)
    print("  Add -o DPkg::Lock::Timeout=<seconds>; without it apt waits forever.")
    sys.exit(1)

if re.search(r"apt-get[^\n]*\b(lua5\.\d|lua-check|luarocks)\b", text):
    print("FAIL: the Lua toolchain is being installed with apt-get.")
    print("  That is the dpkg-lock hang. Use the setup actions instead.")
    sys.exit(1)

if not re.search(r"uses:\s*leafo/gh-actions-lua", text):
    print("FAIL: no Lua setup action; something replaced it.")
    sys.exit(1)

print("    Lua from a setup action, %d bounded apt-get call(s)" % len(calls))
APTLOCK

echo "  CI: only real failures may block the packager"
# Any blocking CI step must be one that indicates broken code. Optional
# tooling steps must carry continue-on-error.
python3 - "$WORK/.github/workflows/release.yml" <<'CILINT'
import re, sys

text = open(sys.argv[1], encoding="utf-8").read()

# Steps that are allowed to block a release, because they mean the addon is
# actually broken.
blocking_allowed = {
    "Check out", "Fetch tags", "Verify a tag points at HEAD", "Install Lua",
    "Install LuaRocks", "Install Lua tooling",
    "Syntax check every Lua file", "Verify the .toc lists every Lua file",
    "Lint", "Run the offline harness",
    "Verify the CurseForge token is available", "Package and upload",
}

steps = re.findall(r"- name: (.+?)\n(.*?)(?=\n      - name: |\Z)", text, re.S)

problems = []

for name, body in steps:
    name = name.strip()
    optional = "continue-on-error: true" in body

    if name not in blocking_allowed and not optional:
        problems.append("step '%s' can block a release but is not in the "
                        "allow-list; add continue-on-error or justify it" % name)

if problems:
    print("FAIL: CI would block a release on a non-essential step")
    for problem in problems:
        print("  " + problem)
    sys.exit(1)

print("    %d steps checked" % len(steps))
CILINT

echo "  lint: no unguarded native invocations"
# Structural guarantee, not a behavioural one. Every native command must go
# through Invoke-CNNative; a stray `2>&1` or a bare `git` call reintroduces
# exactly the Windows PowerShell 5.1 failure this exists to prevent.
python3 - /home/claude/cn/ps/cn.head.ps1 /home/claude/cn/ps/cn.body.ps1 <<'LINT'
import re, sys

problems  = []
redirects = []
bare_git  = []

lines = []

for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as fh:
        for number, line in enumerate(fh, 1):
            lines.append(("%s:%d" % (path.split("/")[-1], number), line))

for number, line in lines:
    stripped = line.strip()

    # Comments are documentation, not invocations.
    if stripped.startswith("#") or stripped.startswith("<#"):
        continue

    if "2>&1" in line:
        redirects.append((number, stripped))

    # A native git call that is not routed through the wrapper.
    if re.match(r"^(\$\w+\s*=\s*)?(&\s*)?git\s+\S", stripped):
        bare_git.append((number, stripped))

# Exactly one redirect is allowed: the one inside Invoke-CNNative.
if len(redirects) != 1 or "$Executable @Arguments" not in redirects[0][1]:
    problems.append("2>&1 must appear exactly once, inside Invoke-CNNative:")
    problems += ["    %s: %s" % r for r in redirects]

if bare_git:
    problems.append("git must be called through Invoke-CNGit:")
    problems += ["    %s: %s" % r for r in bare_git]

if problems:
    print("FAIL: unguarded native invocation")
    for problem in problems:
        print("  " + problem)
    sys.exit(1)
LINT

echo "  strict native error handling (approximates Windows PowerShell 5.1)"
# On Windows PowerShell 5.1, stderr from a native command under 2>&1 becomes a
# terminating error when $ErrorActionPreference is Stop. PowerShell 7 only does
# this with $PSNativeCommandUseErrorActionPreference, so turn it on: without
# it, this suite passes a script that dies on the user's machine. It already
# did exactly that once.
cd "$WORK"
$PWSH -NoProfile -Command "
\$PSNativeCommandUseErrorActionPreference = \$true
\$ErrorActionPreference = 'Stop'
& '$WORK/cn.ps1' doctor
if (\$LASTEXITCODE -ne 0) { exit 1 }
" > strict.log 2>&1 || { echo "FAIL: doctor dies under strict native error handling"; cat strict.log; exit 1; }

grep -q "is on the remote" strict.log || { echo "FAIL: strict-mode doctor output wrong"; cat strict.log; exit 1; }

# And the part that actually broke: a push, under strict handling.
git tag -d "v$VERSION" >/dev/null 2>&1
git push --delete origin "v$VERSION" >/dev/null 2>&1
echo "probe" > probe.txt && git add probe.txt && git commit -qm probe

$PWSH -NoProfile -Command "
\$PSNativeCommandUseErrorActionPreference = \$true
\$ErrorActionPreference = 'Stop'
& '$WORK/cn.ps1' release '$VERSION'
" > strictrelease.log 2>&1 || true

grep -q "Pushed v$VERSION" strictrelease.log \
  || { echo "FAIL: release does not survive strict native error handling"; cat strictrelease.log; exit 1; }

echo "ALL POWERSHELL CHECKS PASSED"
rm -rf "$WORK" "$(dirname "$REMOTE")"
