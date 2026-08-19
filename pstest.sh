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
EXPECTED=$(grep -cE '^\s*"[A-Za-z/]+\.lua",' /home/claude/cn/gen.py)
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
