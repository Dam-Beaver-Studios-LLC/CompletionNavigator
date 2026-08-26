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

echo "  the release workflow's own steps, run here"
# FOUR RELEASES WERE TAGGED, PUSHED, AND NEVER PUBLISHED.
#
# Each died at a different workflow step, and each was reproducible in seconds
# on this machine. Everything below ran EQUIVALENTS -- luacheck against the
# build tree, the harness against the build tree -- while the runner runs
# `luacheck .` and `lua5.4 harness.lua .` against a scaffolded tree from the
# repository root. That difference is where all four failures lived.
#
# cisim.sh extracts each `run:` block from the workflow and executes it. It is
# run here so that no release can be cut without the workflow having been
# executed at least once against the tree being released.
if [ -x /home/claude/cn/cisim.sh ]; then
  /home/claude/cn/cisim.sh "$SRC" > cisim.log 2>&1 \
    || { echo "FAIL: a workflow step fails; this release would not publish"; tail -30 cisim.log; exit 1; }
  echo "    $(grep -c 'ok    ' cisim.log) workflow steps executed against a scaffolded tree"
fi

echo "  a captured fixture is loadable Lua"
# EVERY RECORDING THIS COMMAND EVER WROTE WAS MALFORMED.
#
# Get-CNLuaBlock returns the INTERIOR of a block -- correct for its other two
# callers -- and the fixtures writer emitted `return ` followed by that, so
# every captured.lua began `return` then a bare `["worldPosition"] = {`. It
# never loaded. The harness treated an unparseable file exactly like a missing
# one, printed "no recording present", and passed; `check` reported a
# recording was backing the audit because it only regex-scanned the text. The
# strongest test in this project had never once run.
cat > svcapture.sv <<'SAVEDVARS'
CompletionNavigatorDB = {
	["account"] = {
		["capture"] = {
			["build"] = "9.9.9",
			["interface"] = 120100,
			["worldPosition"] = {
				["continentID"] = 2444,
				["hasGetXY"] = true,
			},
			["events"] = {
				["accepted"] = 40,
				["refused"] = {},
			},
		},
	},
}
SAVEDVARS

$PWSH -NoProfile -File ./cn.ps1 fixtures svcapture.sv > fixwrite.log 2>&1
grep -q "wrote  fixtures" fixwrite.log \
  || { echo "FAIL: fixtures did not write a recording"; cat fixwrite.log; exit 1; }

lua5.4 -e 'local f, e = loadfile("fixtures/captured.lua"); if not f then error(e) end; local t = f(); assert(type(t) == "table", "a recording must be a table"); assert(t.interface == 120100, "and must carry what was captured")' \
  || { echo "FAIL: the recording cn.ps1 fixtures wrote is not loadable Lua"; head -12 fixtures/captured.lua; exit 1; }

$PWSH -NoProfile -File ./cn.ps1 check > fixcheck2.log 2>&1
grep -q "All checks passed" fixcheck2.log \
  || { echo "FAIL: check rejects a recording this toolkit just wrote"; cat fixcheck2.log; exit 1; }

rm -rf fixtures svcapture.sv
echo "    written, loadable, and accepted by check"

echo "  a string with no translation anywhere blocks the release"
# THE NOTE THAT PRINTED FOR FOUR RELEASES AND WAS SCROLLED PAST.
#
# "1 of 46 strings have no translation in any locale" appeared in every check
# from 0.45.0 onward. It was true -- "Stop %d of %d cleared" was added to the
# canonical key list and never handed to a translator -- and being a note, it
# was ignored every single time, including by the person who wrote the string.
cp Locales/enUS.lua Locales/enUS.bak
python3 - <<'EOF'
# ANCHORED ON A KEY THAT IS ASSERTED TO EXIST.
#
# This anchored on "cleared", which 0.52.0 removed from the canonical list --
# so the insertion silently did nothing and the test failed reporting that the
# lint was broken. A probe that can no-op is a probe that can pass for the
# wrong reason; this one refuses rather than pretending.
p = 'Locales/enUS.lua'
s = open(p, encoding='utf-8').read()
anchor = '    "ahead",'
assert anchor in s, "the probe anchor is gone from Locales/enUS.lua"
s = s.replace(anchor, anchor + '\n    "untranslated probe",', 1)
open(p, 'w', encoding='utf-8').write(s)
EOF
$PWSH -NoProfile -File ./cn.ps1 check 2>&1 | grep -q 'no translation in ANY locale' \
  || { echo "FAIL: an untranslated string must block the release"; exit 1; }
$PWSH -NoProfile -File ./cn.ps1 check 2>&1 | grep -q '"untranslated probe"' \
  || { echo "FAIL: and it must say WHICH string"; exit 1; }

# A duplicate in the canonical list makes every count reported against it wrong.
cp Locales/enUS.bak Locales/enUS.lua
python3 - <<'EOF'
p = 'Locales/enUS.lua'
s = open(p, encoding='utf-8').read()
anchor = '    "ahead",'
assert anchor in s, "the probe anchor is gone from Locales/enUS.lua"
s = s.replace(anchor, anchor + '\n    "ahead",', 1)
open(p, 'w', encoding='utf-8').write(s)
EOF
$PWSH -NoProfile -File ./cn.ps1 check 2>&1 | grep -q 'more than once' \
  || { echo "FAIL: a duplicated canonical key must block the release"; exit 1; }

mv Locales/enUS.bak Locales/enUS.lua
$PWSH -NoProfile -File ./cn.ps1 check > localecheck.log 2>&1
grep -q "All checks passed" localecheck.log \
  || { echo "FAIL: the shipped locales do not pass their own lint"; cat localecheck.log; exit 1; }
echo "    named, blocking, and the shipped locales are complete"

echo "  four lists of what counts as addon source, agreeing"
# THE FAILURE THAT COST THREE RELEASES.
#
# `cn.ps1 fixtures` writes fixtures/captured.lua -- a recording of a live
# client, read only by the harness. Three separate things decide which .lua
# files are addon source: Get-CNLuaFiles in this toolkit, the find expression
# in the CI workflow, and .pkgmeta's ignore list. 0.47.0 taught the first one
# about fixtures/ and left the other two alone, so every build from that point
# failed at "Verify the .toc lists every Lua file" -- before the packager --
# while `release` printed that it had uploaded to CurseForge.
mkdir -p fixtures
printf 'return { interface = 120100 }\n' > fixtures/captured.lua

$PWSH -NoProfile -File ./cn.ps1 check > fixcheck.log 2>&1
grep -q "All checks passed" fixcheck.log \
  || { echo "FAIL: a captured fixture must not fail check"; cat fixcheck.log; exit 1; }

# THE WORKFLOW'S OWN RULE, NOT A COPY OF IT.
#
# The behavioural check below runs a find expression written out here, which
# is a second copy of the very list this test exists to keep in agreement --
# it would pass while the workflow on the runner still rejected the tree. So
# assert against the workflow file itself first.
fixtureExclusions=$(grep -c "not -path './fixtures/\*'" .github/workflows/release.yml || true)
[ "$fixtureExclusions" -ge 2 ] \
  || { echo "FAIL: the CI workflow does not exclude fixtures/ from both Lua searches (found $fixtureExclusions)"; exit 1; }

# The CI step, run exactly as the workflow runs it -- against an LF copy of
# the .toc, because .gitattributes normalizes it on the way into the
# repository and the runner checks out LF. The scaffold on this disk is CRLF,
# and comparing against that reports every file in the addon as missing.
status=0
toc=$(mktemp)
tr -d '\r' < CompletionNavigator.toc > "$toc"
while IFS= read -r file; do
  rel="${file#./}"
  win="${rel//\//\\}"
  if ! grep -qxF "$win" "$toc" && ! grep -qxF "$rel" "$toc"; then
    echo "  NOT IN TOC: $rel"
    status=1
  fi
done < <(find . -type f -name '*.lua' -not -path './.*' \
           -not -name 'harness.lua' -not -name 'bench.lua' \
           -not -path './fixtures/*')
rm -f "$toc"
[ "$status" -eq 0 ] \
  || { echo "FAIL: CI would reject the tree over a file the toolkit ignores"; exit 1; }

# And luacheck -- the FOURTH list, and the one that was missed. A malformed
# recording is a recording to re-capture, not a syntax error in the addon,
# and it failed the Lint step as though it were.
printf 'return\n["capture"] = {}\n' > fixtures/broken.lua
if command -v luacheck >/dev/null 2>&1; then
  luacheck . --no-color >lintfix.log 2>&1 \
    || { echo "FAIL: luacheck rejects the tree over a file under fixtures/"; tail -4 lintfix.log; exit 1; }
fi
rm -f fixtures/broken.lua

# And the packager must not ship the recording to players.
tr -d '\r' < .pkgmeta | grep -q '^  - fixtures$' \
  || { echo "FAIL: .pkgmeta does not ignore fixtures/"; exit 1; }

rm -rf fixtures
echo "    toolkit, CI, luacheck and .pkgmeta all ignore a captured fixture"

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

echo "  check guard: a tree left behind by a refused init"
# THE FAILURE THAT COST A RELEASE CYCLE.
#
# A new cn.ps1 arrives, `init` refuses because Core.lua already exists, and
# the tree stays a release behind while every other line of `check` reports
# happily on the OLD source. There was a branch for the opposite case -- a
# cn.ps1 older than the tree -- and none at all for this one.
cp Core.lua Core.bak
sed -i 's/^CN.version     = "'"$VERSION"'"/CN.version     = "0.0.1"/' Core.lua
sed -i 's/^## Version: '"$VERSION"'/## Version: 0.0.1/' CompletionNavigator.toc
$PWSH -NoProfile -File ./cn.ps1 check 2>&1 | grep -q "but the tree on disk is 0.0.1" \
  || { echo "FAIL: a tree behind the toolkit must be reported"; exit 1; }
mv Core.bak Core.lua
sed -i 's/^## Version: 0.0.1/## Version: '"$VERSION"'/' CompletionNavigator.toc
$PWSH -NoProfile -File ./cn.ps1 check > check3.log 2>&1
grep -q "All checks passed" check3.log \
  || { echo "FAIL: check does not pass once the tree is current"; cat check3.log; exit 1; }

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
				["observedRequires"] = {
					71230, 71231,
				},
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

# THE CHAIN MUST COME WITH IT.
#
# Prerequisites are the whole reason the harvest exists, and until 0.42.0 the
# toolkit's parser could not see an array field at all -- so the addon wrote
# them, the toolkit silently dropped them, and both halves looked like they
# worked.
grep -q 'requires  = { 71230, 71231 }' Data/Quests.lua \
  || { echo "FAIL: harvested prerequisites were not written"; exit 1; }

# And a guess must NOT: maybeRequires is what the addon calls an ordering it
# has seen too few times to believe.
grep -q 'requires  = { 1, 2 }' Data/Quests.lua \
  && { echo "FAIL: unconfident prerequisites were shipped as fact"; exit 1; }

# Escaped quotes must survive the round trip, and the file must still be Lua.
grep -q 'A Quest With .* In It' Data/Quests.lua || { echo "FAIL: quoted name mangled"; exit 1; }
luac5.4 -p Data/Quests.lua || { echo "FAIL: harvest produced invalid Lua"; exit 1; }

# FOLDING INTO A ROW THAT ALREADY EXISTS.
#
# A row is usually added for its location long before enough characters have
# walked the chain for its prerequisites to be believed. Skipping the whole row
# meant that evidence, when it finally arrived, had nowhere to go.
mkdir -p fixtures-tmp
cat > fixtures-tmp/sv2.lua <<'SAVEDVARS2'

CompletionNavigatorDB = {
	["account"] = {
		["questHarvest"] = {
			[8237] = {
				["name"] = "Already Curated",
				["mapID"] = 94,
				["x"] = 0.42,
				["y"] = 0.55,
				["observedRequires"] = {
					8230,
				},
			},
		},
	},
}
SAVEDVARS2

$PWSH -NoProfile -File ./cn.ps1 harvest ./fixtures-tmp/sv2.lua > harvestfold.log 2>&1
grep -q "chains folded into existing rows 1" harvestfold.log \
  || { echo "FAIL: a chain was not folded into the existing row"; cat harvestfold.log; exit 1; }
grep -q 'requires  = { 8230 }' Data/Quests.lua \
  || { echo "FAIL: the folded chain is not in the file"; exit 1; }
luac5.4 -p Data/Quests.lua || { echo "FAIL: folding produced invalid Lua"; exit 1; }

# And folding must be idempotent: a second run must not duplicate it.
$PWSH -NoProfile -File ./cn.ps1 harvest ./fixtures-tmp/sv2.lua > harvestfold2.log 2>&1
FOLDED=$(grep -c 'requires  = { 8230 }' Data/Quests.lua)
[ "$FOLDED" = "1" ] \
  || { echo "FAIL: folding is not idempotent ($FOLDED copies)"; exit 1; }

# The fixture must not linger where `check` will find it: a stray .lua file in
# the tree is exactly the thing check is supposed to complain about, and a test
# that leaves rubbish behind makes a later test fail for a reason that has
# nothing to do with what it is testing.
rm -rf fixtures-tmp

# A CONTRIBUTION FOLDS INTO THE COMMUNITY FILE, AND ONLY INTO THAT ONE.
#
# Community rows are believed because several installs agreed, not because a
# human checked them. Letting them into Data\Quests.lua would destroy that
# distinction permanently and silently.
$PWSH -NoProfile -File ./cn.ps1 contribution "CN1 100:98,99 200:150" > contrib.log 2>&1
grep -q "new rows to add            2" contrib.log \
  || { echo "FAIL: the contribution was not folded"; cat contrib.log; exit 1; }
grep -q "requires = { 98, 99 }" Data/Community.lua \
  || { echo "FAIL: the chain is not in the community file"; exit 1; }
grep -q "100" Data/Quests.lua \
  && { echo "FAIL: a contribution leaked into the curated database"; exit 1; }
luac5.4 -p Data/Community.lua || { echo "FAIL: contribution produced invalid Lua"; exit 1; }

# Malformed input must change nothing at all, rather than importing the half
# it could parse.
BEFORE=$(md5sum Data/Community.lua | cut -d" " -f1)
$PWSH -NoProfile -File ./cn.ps1 contribution "CN1 100:98 rubbish" > contrib2.log 2>&1
grep -q "malformed" contrib2.log \
  || { echo "FAIL: malformed contribution was not refused"; cat contrib2.log; exit 1; }
AFTER=$(md5sum Data/Community.lua | cut -d" " -f1)
[ "$BEFORE" = "$AFTER" ] \
  || { echo "FAIL: a refused contribution still changed the file"; exit 1; }

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

# AND ON THE LANGUAGE THE GAME ACTUALLY RUNS.
#
# WoW runs Lua 5.1; this suite normally runs 5.4. They are not the same
# language, and the difference concealed the worst defect this project has
# shipped -- two-argument math.atan, silently wrong in game for twenty-four
# releases while the suite agreed the code was correct.
if command -v lua5.1 >/dev/null 2>&1; then
  (cd "$WORK" && lua5.1 harness.lua . > ciharness51.log 2>&1) || {
    echo "FAIL: the harness does not pass on Lua 5.1, which is what the game runs"
    tail -20 "$WORK/ciharness51.log"; exit 1; }
  grep -q "ALL HARNESS CHECKS PASSED" "$WORK/ciharness51.log" || {
    echo "FAIL: the 5.1 harness did not report success"; exit 1; }
  echo "    passed on Lua 5.1, the game's own version"
else
  echo "    lua5.1 not installed; the game's own language went unverified"
fi

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
  (cd "$WORK" && bash coverage.sh . 82 > coverage.log 2>&1) || {
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

# THE PER-STEP CAPS ARE THE HANG DETECTOR; THE JOB CAP IS THE BACKSTOP.
#
# The ceiling here used to be 60, on the reasoning that a generous job cap
# cannot notice a hang. That reasoning belongs to the STEP caps -- every step
# in this workflow carries one, and each is sized to the work it does. The job
# cap only has to be larger than all of them together, or it becomes the real
# limit and kills whichever step happens to be running. 0.67.1.
if minutes > 120:
    print("FAIL: job timeout of %d minutes is too generous to be a backstop" % minutes)
    sys.exit(1)

# AND THE JOB CAP MUST EXCEED THE STEPS IT CONTAINS. 0.67.1.
#
# 0.67.0 shipped with a job capped at 20 minutes containing step caps that add
# to 57. When the job cap is the smaller number the per-step ones are
# decoration: whichever step happens to be running when the job clock runs out
# is killed, no step is marked failed, and the run reports a failure with
# nothing to point at -- which is exactly what `cn.ps1 ci` could not explain.
#
# Only the steps AFTER the job's own line are summed; the job's cap is the
# first `timeout-minutes` in the file.
after = text[job_timeout.end():]

step_caps = [int(m) for m in re.findall(r"^\s*timeout-minutes:\s*(\d+)", after, re.M)]

total = sum(step_caps)

if step_caps and minutes <= total:
    print("FAIL: the job is capped at %d minutes and the steps inside it are"
          % minutes)
    print("  capped at %d in total (%s)." % (total, ", ".join(str(c) for c in step_caps)))
    print("  The job cap is then the real limit, and it kills whichever step")
    print("  happens to be running -- marking nothing as failed.")
    sys.exit(1)

print("    job bounded at %d minutes, over %d minutes of step caps"
      % (minutes, total))
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
    "Run the offline harness on Lua 5.1 (the game's version)",
    # Budgets block, and should: a performance regression is a defect, two
    # have shipped in this project, and both were visible in output nobody
    # was comparing against anything.
    "Performance budgets",
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
