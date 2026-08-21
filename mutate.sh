#!/usr/bin/env bash
# mutate.sh -- does the test suite actually test anything?
#
# WHY THIS EXISTS.
#
# A passing suite proves the code runs. It does not prove the assertions
# would notice if the code were wrong, and this project has repeatedly found
# tests that would not: an assertion comparing a value against the setting
# that produced it, a fixture that failed a different check first, a
# comparison so loose that east reading as west still passed.
#
# Every one of those was found by hand, by breaking the code on purpose and
# seeing whether anything complained. That is a mechanical task and it was
# being done from memory, which means it was being done inconsistently.
#
# Each mutation below is a deliberate, plausible bug. A mutation that SURVIVES
# is a hole in the suite, and the correct response is to write the missing
# assertion -- never to delete the mutation.
#
# Usage:  ./mutate.sh [tree]
set -u

TREE="${1:-build/CompletionNavigator}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASSED=0
SURVIVED=0

mutate() {
    local file="$1" from="$2" to="$3" label="$4"

    rm -rf "$WORK/tree"
    cp -r "$TREE" "$WORK/tree"

    python3 - "$WORK/tree/$file" "$from" "$to" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding="utf-8").read()
if text.count(old) != 1:
    print("MUTATION NOT APPLICABLE: %s (%d matches)" % (old[:60], text.count(old)))
    sys.exit(3)
open(path, "w", encoding="utf-8").write(text.replace(old, new))
PY

    local applied=$?

    if [ "$applied" = "3" ]; then
        printf '  \033[33mstale\033[0m     %s\n' "$label"
        SURVIVED=$((SURVIVED + 1))
        return
    fi

    if lua5.4 harness.lua "$WORK/tree" >/dev/null 2>&1; then
        printf '  \033[31mSURVIVED\033[0m  %s\n' "$label"
        SURVIVED=$((SURVIVED + 1))
    else
        printf '  \033[32mkilled\033[0m    %s\n' "$label"
        PASSED=$((PASSED + 1))
    fi
}

echo "Mutation testing $TREE"
echo

mutate "Modules/Travel.lua" \
    "                if seconds < best.seconds then" \
    "                if true then" \
    "travel always flies, even when running is quicker"

mutate "Modules/Travel.lua" \
    '        return nil, false, {
            mode      = "elsewhere",' \
    '        return 3600, false, {
            mode      = "elsewhere",' \
    "travel invents a cross-continent duration"

mutate "Modules/Instances.lua" \
    "            and lockout.defeated > 0" \
    "            and lockout.defeated >= 0" \
    "a lockout nothing has been killed in is recommended"

mutate "Modules/Preference.lua" \
    "    if not row or row.shown < Preference.minimumObservations then" \
    "    if not row then" \
    "learning acts before it has evidence"

mutate "Modules/Chase.lua" \
    "    if timed == 0 or (timed / outstanding) < Chase.estimateCoverage then" \
    "    if false then" \
    "chase estimates a time from nothing"

mutate "Scoring.lua" \
    "    if secondsLeft < CN.urgencyHorizonSeconds then" \
    "    if false then" \
    "the short urgency ramp is removed"

mutate "Modules/Navigation.lua" \
    "    if math.abs(delta) >= Navigation.smoothingSnapRad then" \
    "    if false then" \
    "the arrow eases through a reversal instead of snapping"

mutate "Modules/Group.lua" \
    '        return score * Group.deadPenalty' \
    "        return score" \
    "recommendations ignore the player being dead"

mutate "Modules/Contribute.lua" \
    '    if version ~= Contribute.formatVersion then' \
    "    if false then" \
    "an import accepts text of any format"

mutate "Core.lua" \
    "    if level == CN.confidence.ESTIMATED then" \
    "    if false then" \
    "estimated numbers are printed as though measured"

mutate "Modules/Inventory.lua" \
    "        if ok and type(info) == \"table\" and info.questID and not info.isActive then" \
    "        if ok and type(info) == \"table\" and info.questID then" \
    "quest starters already accepted are offered again"

mutate "Modules/Waiting.lua" \
    "        if mail.expiring and (mail.items > 0 or mail.money > 0) then" \
    "        if mail.expiring then" \
    "empty expiring mail is treated as something to save"

mutate "Modules/Travel.lua" \
    "    if remembered == false then
        return false
    end" \
    "    if false then
        return false
    end" \
    "flying is offered in a zone known not to allow it"

# NOT `value % divisor`: Lua's own operator is already floored, so that
# mutation is behaviourally identical and survived for the honest reason that
# it was not a defect. math.fmod truncates toward zero, which is the actual
# hazard this helper exists to avoid.
mutate "Core.lua" \
    "    return value - (math.floor(value / divisor) * divisor)" \
    "    return math.fmod(value, divisor)" \
    "modulo truncates toward zero instead of flooring"

mutate "Scoring.lua" \
    "        if math.abs(term.value) > 0.001 then" \
    "        if true then" \
    "the ranking explanation lists terms worth nothing"

mutate "Modules/Group.lua" \
    "        return score * Group.instancedPenalty" \
    "        return score" \
    "outside work is not ranked down inside an instance"

mutate "Modules/Session.lua" \
    "    if situation == \"dead\" or situation == \"instanced\" then" \
    "    if false then" \
    "the planner lays out a route you cannot start"

mutate "Modules/Errors.lua" \
    "    while #ring > Errors.capacity do" \
    "    while false do" \
    "the error ring grows without bound"

mutate "Modules/Inventory.lua" \
    "        if not objective.finished then" \
    "        if true then" \
    "finished objectives are reported as work left"

mutate "Modules/Inventory.lua" \
    "            if objective.remaining <= Inventory.nearlyDoneRemaining then" \
    "            if true then" \
    "everything is called nearly done"

mutate "Modules/Travel.lua" \
    "    if fromID > toID then
        fromID, toID = toID, fromID
    end" \
    "    if false then
        fromID, toID = toID, fromID
    end" \
    "a flight only counts in the direction it was flown"

mutate "UI/List.lua" \
    "        if mode == \"ranked\" then
            return entries
        end" \
    "        if false then
            return entries
        end" \
    "the ranking is re-sorted alphabetically by default"

mutate "Modules/Sets.lua" \
    "        if set.total > 0 and missing > 0 and missing <= maxMissing then" \
    "        if set.total > 0 and missing <= maxMissing then" \
    "a finished set is offered as nearly finished"

# The break the 0.45.0 split actually introduced, kept as a permanent guard:
# the tab builders must reach the list constructor through the table, because
# UI/List.lua loads after UI.lua and a local captured there is nil forever.
mutate "UI.lua" \
    "        panel.list = UI.CreateList(panel)
        panel.list:ClearAllPoints()
        panel.list:SetPoint(\"TOPLEFT\", panel.why, \"BOTTOMLEFT\", -4, -14)" \
    "        panel.list = CreateList(panel)
        panel.list:ClearAllPoints()
        panel.list:SetPoint(\"TOPLEFT\", panel.why, \"BOTTOMLEFT\", -4, -14)" \
    "a tab builder calls the list constructor as a global"

# The two caches added in 0.46.0, after measuring them at realistic scale. A
# cache that never invalidates is a worse bug than the 4.4ms it saved.
mutate "Modules/Sets.lua" \
    "CN:RegisterEvent(\"TRANSMOG_COLLECTION_UPDATED\", function()
    Sets.Forget()
end)" \
    "CN:RegisterEvent(\"TRANSMOG_COLLECTION_UPDATED\", function()
end)" \
    "the appearance set cache never invalidates"

mutate "Modules/Inventory.lua" \
    "CN:RegisterEvent(\"BAG_UPDATE_DELAYED\", function()
    Inventory.Forget()
end)" \
    "CN:RegisterEvent(\"BAG_UPDATE_DELAYED\", function()
end)" \
    "the bag cache never invalidates"

mutate "Modules/Inventory.lua" \
    "    if not containers and bagCache then" \
    "    if bagCache then" \
    "a bank scan is served from the bag cache"

# The pair-search rewrite in 0.46.0. It made the same search twenty times
# cheaper, which is exactly the kind of change that returns a slightly wrong
# answer forever without ever erroring.
mutate "Modules/Travel.lua" \
    "                and (bestPossibleDiscount
                    * (walkOut + Travel.flightOverheadSeconds + cheapestArrival))
                    < best.seconds then" \
    "                and walkOut < (best.seconds * 0.5) then" \
    "the pruning bound discards a route that would have won"

mutate "Modules/Travel.lua" \
    "function Travel.ForgetNodes()
    nodeCache = {}
    spanCache = {}
end" \
    "function Travel.ForgetNodes()
    nodeCache = {}
end" \
    "the flight-leg distances outlive the node list they describe"

mutate "Modules/Travel.lua" \
    "                                runToNode   = walkOut * runSpeed," \
    "                                runToNode   = walkOut," \
    "the walk to the flight master is reported in seconds as yards"


# The event guard added in 0.46.0, after an invented event name threw a Lua
# error at every login and eighty files of tests could not see it.
mutate "Core.lua" \
    "    if CN.eventFrame then
        CN.RegisterWithClient(event)
    end" \
    "    if CN.eventFrame then
        pcall(CN.eventFrame.RegisterEvent, CN.eventFrame, event)
    end" \
    "a rejected event is swallowed without being recorded"

mutate "Events.lua" \
    "for event in pairs(CN.eventTable) do
    CN.RegisterWithClient(event)
end" \
    "for event in pairs(CN.eventTable) do
end" \
    "handlers registered before Events.lua never reach the client"


# The 0.47.0 fixes. Each of these was a real defect found by an end-to-end
# audit, and each was invisible to the suite that existed at the time.
mutate "Modules/Travel.lua" \
    "                and (bestPossibleDiscount
                    * (walkOut + Travel.flightOverheadSeconds + cheapestArrival))
                    < best.seconds then" \
    "                and (walkOut + Travel.flightOverheadSeconds + cheapestArrival)
                    < best.seconds then" \
    "the pruning bound ignores the known-route discount"

mutate "Modules/Travel.lua" \
    "for _, event in ipairs({ \"ZONE_CHANGED_NEW_AREA\", \"PLAYER_ENTERING_WORLD\" }) do
    CN:RegisterEvent(event, NoteWhereWeAre)
end" \
    "for _, event in ipairs({}) do
    CN:RegisterEvent(event, NoteWhereWeAre)
end" \
    "nothing ever observes whether a zone allows flying"

mutate "Modules/Inventory.lua" \
    "                        questItem = QuestItem(bag, slot)," \
    "                        questItem = info.hasNoValue and true or false," \
    "a quest item is read from its vendor sell price"

mutate "UI.lua" \
    "    -- Now that the panel exists, the filter has something to apply to.
    UI.RestoreFilter()" \
    "    -- Now that the panel exists, the filter has something to apply to." \
    "a carried filter is shown but never applied"

mutate "Data/ApiSurface.lua" \
    "CN.apiSurface = {" \
    "CN.apiSurface = {} local ignored = {" \
    "the generated API surface is empty"


# The 0.48.0 audit. Every one of these was live in a shipped release.
mutate "Modules/Session.lua" \
    "    for _, bucket in ipairs({ \"mounted\", \"onFoot\", \"flying\" }) do
        stored[bucket] = {}" \
    "    for _, bucket in ipairs({ \"mounted\", \"onFoot\" }) do
        stored[bucket] = {}" \
    "measured flying speed is never written to disk"

mutate "Scoring.lua" \
    "    for _, provider in pairs(CN.candidateProviders) do
        for event in pairs(provider.events or {}) do
            wanted[event] = true
        end
    end" \
    "    for _, provider in pairs(CN.candidateProviders) do
    end" \
    "providers subscribe to nothing they asked for"

mutate "Modules/Follow.lua" \
    "    local candidates = CN.CollectCandidates() or {}

    local generation = 0" \
    "    local candidates = nil

    local generation = 0" \
    "follow stops collecting and its memo never expires"

mutate "Routing.lua" \
    "    local dx = ((ax or 0.5) - (bx or 0.5)) * routeScaleX
    local dy = ((ay or 0.5) - (by or 0.5)) * routeScaleY" \
    "    local dx = ((ax or 0.5) - (bx or 0.5))
    local dy = ((ay or 0.5) - (by or 0.5))" \
    "routing assumes every map is square"

mutate "Routing.lua" \
    "    for _, objective in ipairs(candidates) do
        objective.hub     = nil
        objective.hubSize = nil
    end" \
    "    for _, objective in ipairs(candidates) do
    end" \
    "last zone's batching survives into this one"

mutate "Modules/Harvest.lua" \
    "        if record.observed and next(record.observed) then
            counts.withGuesses = counts.withGuesses + 1
        end" \
    "        if record.maybeRequires then
            counts.withGuesses = counts.withGuesses + 1
        end" \
    "the harvest summary counts a field nothing writes"


echo
echo "$PASSED killed, $SURVIVED survived."

if [ "$SURVIVED" -gt 0 ]; then
    echo
    echo "A surviving mutation is a hole in the suite. Write the assertion."
    exit 1
fi
