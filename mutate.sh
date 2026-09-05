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

# A BACKTICK IN AN ANCHOR IS A COMMAND, NOT A CHARACTER. 0.77.0.
#
# The anchors are double-quoted, so the shell runs anything between backticks
# and substitutes its output -- and this file's own prose style puts Lua names
# in backticks everywhere. A 0.77.0 anchor copied a comment line verbatim,
# the shell tried to run `EffectiveWeights`, and the mutation silently became
# inapplicable rather than failing: it was reported as stale, which reads like
# a re-anchoring chore rather than a bug in this script.
#
# Refuse the whole run rather than quietly testing one thing fewer.
mutate() {
    local file="$1" from="$2" to="$3" label="$4"

    case "$from$to" in
        *'`'*)
            echo "ANCHOR CONTAINS A BACKTICK, which the shell would run: $label"
            exit 2
            ;;
    esac

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
    "                        if ranking < bestRanking then" \
    "                        if true then" \
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

# RE-ANCHORED IN 0.89.0: the boundary case is refused now, so the comparison
# is `<=` rather than `<`.
mutate "Modules/Chase.lua" \
    "    if timed == 0 or (timed / outstanding) <= Chase.estimateCoverage then" \
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
    "        if item.startsQuest and not item.questActive then" \
    "        if item.startsQuest then" \
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
    "        if math.abs(term.value) > 0.001 or term.keepAtZero then" \
    "        if true then" \
    "the ranking explanation lists terms worth nothing"

mutate "Modules/Group.lua" \
    "        return score * Group.instancedPenalty" \
    "        return score" \
    "outside work is not ranked down inside an instance"

mutate "Modules/Session.lua" \
    "    if situation == \"dead\" or inside then" \
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
        panel.list.emptyText = \"Nothing actionable is known yet. /cn setup reads everything the client will answer for.\"" \
    "        panel.list = CreateList(panel)
        panel.list.emptyText = \"Nothing actionable is known yet. /cn setup reads everything the client will answer for.\"" \
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
    "            if (bestPossibleDiscount * floor) < bestRanking then" \
    "            if walkOut < (bestRanking * 0.5) then" \
    "the pruning bound discards a route that would have won"

mutate "Modules/Travel.lua" \
    "    nodeCache      = {}
    neighbourCache = {}
    pathCache      = {}" \
    "    nodeCache      = {}" \
    "the flight network outlives the node list it describes"

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
    "            if (bestPossibleDiscount * floor) < bestRanking then" \
    "            if floor < bestRanking then" \
    "the pruning bound ignores the known-route discount"

# NOT a mutation, and here is why, because the absence of one is a decision.
#
# 0.59.0 split the pruning bound: the early exit now uses a floor that is
# MONOTONE in `walkOut` -- the continent-wide minimum outgoing edge rather
# than the origin's own -- and the per-origin floor became an exact filter.
# The obvious mutation is to put `minOutgoing[i]` back into the break.
#
# It survives, and it survives honestly. Reaching a case where it changes the
# answer requires a later origin whose floor is lower, i.e. a saving of
# `m / flightSpeed` exceeding an extra walk of `d / runSpeed` -- so
# `m > 3.6 * d`. But `m` is bounded by the distance from that origin to its
# nearest node, and the triangle inequality bounds THAT by `d` plus the later
# origin's own minimum. The two constraints cannot both hold. An independent
# search over five and a half thousand randomised continents found no case
# either.
#
# So the unsound break was almost certainly harmless. It was still changed,
# because "almost certainly" is not an argument you can check, the correct
# version is two lines, and it measured FASTER. Same shape as the math.fmod
# note above: a mutation that cannot be killed because it is not a defect
# does not belong in this file.

mutate "Modules/Travel.lua" \
    "for _, event in ipairs({ \"ZONE_CHANGED_NEW_AREA\", \"PLAYER_ENTERING_WORLD\" }) do
    CN:RegisterEvent(event, NoteWhereWeAre)
end" \
    "for _, event in ipairs({}) do
    CN:RegisterEvent(event, NoteWhereWeAre)
end" \
    "nothing ever observes whether a zone allows flying"

mutate "Modules/Inventory.lua" \
    "                        questItem = questInfo
                            and (questInfo.isQuestItem or questInfo.questID)
                            and true or false," \
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
    "    if mapID == nil or playerMap == nil or mapID ~= playerMap then
        return false
    end" \
    "    if mapID == nil or playerMap == nil then
        return false
    end" \
    "looking at another zone's map strips the batching off the one you are in"

mutate "Routing.lua" \
    "        Publish(mapID, held.sizes)

        return held.route, held.skipped, held.hubs" \
    "        return held.route, held.skipped, held.hubs" \
    "a cached route is drawn as batched while nothing is scored as batched"

mutate "Routing.lua" \
    "    CN.batchSizes = setmetatable({}, { __mode = \"k\" })
    CN.batchMapID = nil

    CN.InvalidateRanking()

    return true" \
    "    return true" \
    "the zone you walked out of keeps its batch bonus"

mutate "Modules/Harvest.lua" \
    "        if record.observed and next(record.observed) then
            counts.withGuesses = counts.withGuesses + 1
        end" \
    "        if record.maybeRequires then
            counts.withGuesses = counts.withGuesses + 1
        end" \
    "the harvest summary counts a field nothing writes"


# The 0.49.0 audit: four features that had been silently off, and the two
# stubs that agreed with them.
mutate "Providers/BlizzardWorld.lua" \
    "            _, isRaid, _, difficultyName, encounters, defeated, _,
            journalInstanceID =" \
    "            _, isRaid, _, difficultyName, defeated, encounters, _,
            journalInstanceID =" \
    "lockout progress and total are read in the wrong order"

mutate "Modules/Waiting.lua" \
    "    if not currencies or not currencies.CharacterStore then
        return rows
    end" \
    "    if not currencies or not currencies.Store then
        return rows
    end" \
    "weekly profession knowledge is never listed"

mutate "Modules/Currencies.lua" \
    "                accountWide = record.accountWide and true or false," \
    "" \
    "a Warband currency loses its flag on the way out of the query"

mutate "Modules/Professions.lua" \
    "            recipeTotal  = existing and existing.recipeTotal or nil," \
    "            recipeTotal  = nil," \
    "recipe counts are discarded on every login"

mutate "Providers/BlizzardCollections.lua" \
    "        if gotCollected then
            collected = wasCollected and true or false
        end" \
    "        collected = gotCollected and wasCollected or nil" \
    "a journal filter the player turned off is left on"

mutate "Providers/BtWQuests.lua" \
    "    for index = 1, 3 do
        local candidate = candidates[index]" \
    "    for index, candidate in ipairs(candidates) do" \
    "the BtWQuests database fallbacks are unreachable"

mutate "Modules/Filters.lua" \
    "    if not settings.mode then
        settings.modePrevious = {" \
    "    if true then
        settings.modePrevious = {" \
    "switching focus overwrites what off would restore"


# The 0.50.0 audit: defects that only appear across a sequence of actions.
mutate "Modules/Hud.lua" \
    "local function Preferences()" \
    "local function Settings()" \
    "the options-panel registration indexes a local function"

mutate "Scoring.lua" \
    "    objective[field][key] = text

    return true
end

local function Withdraw(objective, field, key)" \
    "    objective[field][#objective[field] + 1] = text

    return true
end

local function Withdraw(objective, field, key)" \
    "an adjuster's reason is appended on every rescore"

mutate "Database.lua" \
    "    mounts       = { \"Mounts\" },
    toys         = { \"Toys\" }," \
    "    toys         = { \"Toys\" }," \
    "a mount scan is invisible to the recommendation"

mutate "Modules/Filters.lua" \
    "    if not previous and not settings.mode then
        return false
    end" \
    "    if false then
        return false
    end" \
    "clearing an unset focus unhides what the player hid"

mutate "Modules/Follow.lua" \
    "    if CN.ClearWaypoints then
        pcall(CN.ClearWaypoints)
    end" \
    "    if false then
        pcall(CN.ClearWaypoints)
    end" \
    "stopping follow mode leaves the arrow up"

mutate "Modules/Session.lua" \
    "CN.RegisterCandidateDecorator(\"Session\", function(objective)
    if type(objective) == \"table\" and objective.type then" \
    "CN.RegisterCandidateDecorator(\"Session\", function(objective)
    if false then" \
    "nothing ever sets how long a thing takes"


# The 0.51.0 audit: numbers the addon showed that were wrong.
mutate "Scoring.lua" \
    "        worth = worth * profile.types[objective.type]" \
    "        worth = (worth + cost) * profile.types[objective.type] - cost" \
    "a focus multiplies a total that crosses zero"

# RETIRED IN 0.77.0: a duplicate of "running the whole way is quoted at
# flying speed", below, which anchors on the same line at its real
# indentation.

mutate "Modules/Travel.lua" \
    "CN.fallbackZoneCost = 40" \
    "CN.fallbackZoneCost = 25" \
    "another continent is cheaper than across your own zone"

mutate "Modules/Session.lua" \
    "    local elapsed = span - (started.travel or 0)" \
    "    local elapsed = span - 0" \
    "the journey is counted in the task time and again in the plan"

mutate "Modules/Chase.lua" \
    "        done         = nil,
        total        = nil," \
    "        done         = standing.earned,
        total        = standing.needed," \
    "progress inside a rank is shown as progress toward the goal"

mutate "Modules/Preference.lua" \
    "            refinedRow.acted = (refinedRow.acted or 0) + 1" \
    "" \
    "a player who does everything is recorded as doing nothing"


# The 0.52.0 backlog work.
mutate "Modules/Hud.lua" \
    "        return CN.L[\"ahead\"]" \
    "        return \"ahead\"" \
    "a translated string is printed as an English literal"

mutate "Modules/Group.lua" \
    "        if objective and objective.corpse then
            return score
        end" \
    "        if false then
            return score
        end" \
    "a ghost's body is ranked down with everything else"

mutate "Scoring.lua" \
    "        if objective.corpse
            or not CN.IsObjectiveTypeEnabled" \
    "        if not CN.IsObjectiveTypeEnabled" \
    "a type filter can hide your own corpse"

mutate "Modules/Navigation.lua" \
    "    if hud and hud.IsColourblind and hud.IsColourblind() then
        return Navigation.colorblindColors
    end" \
    "    if false then
        return Navigation.colorblindColors
    end" \
    "colourblind mode leaves the palette alone"

mutate "Modules/Travel.lua" \
    "    { kind = \"spell\", id = 50977,  label = \"Death Gate\",              mapID = 118 }," \
    "    { kind = \"spell\", id = 50977,  label = \"Death Gate\" }," \
    "a teleport loses the destination that makes it costable"


# 0.53.0: multi-hop routing, and the state and honesty audits.
mutate "Modules/Travel.lua" \
    "                local flightYards = (i ~= j) and path.dist[j] or nil" \
    "                local flightYards = (i ~= j) and Spans(continent, nodes)[i][j] or nil" \
    "the flight leg is a straight line again instead of a route"

mutate "Modules/Travel.lua" \
    "            if not back.held[i] then
                back.held[i] = true

                table.insert(back, { index = i, yards = edge.yards })
            end" \
    "            if false then
                back.held[i] = true

                table.insert(back, { index = i, yards = edge.yards })
            end" \
    "the flight network is directed, so an outpost has no way in"

mutate "Modules/Travel.lua" \
    "    if #usable > 0 then
        nodeCache[continent] = usable
    end" \
    "    nodeCache[continent] = usable" \
    "an empty flight-point list is remembered for the session"

mutate "Objectives.lua" \
    "local function Rebuild()
    if CN.InvalidateCandidates then
        CN.InvalidateCandidates()
    end
end" \
    "local function Rebuild()
end" \
    "ignoring something does not take effect until something else changes"

mutate "Scoring.lua" \
    "            or (provider.volatile and cooled" \
    "            or (provider.volatile and true" \
    "a volatile provider ignores the cooldown it asked for"

mutate "Modules/Errors.lua" \
    "    if #ring == 0 then
        return 0
    end" \
    "    if false then
        return 0
    end" \
    "a clean session erases the previous session's error record"

mutate "Modules/Achievements.lua" \
    "        Achievements.revision = Achievements.revision + 1

        DebugPrint(\"Achievement earned: \" .. tostring(achievementID))" \
    "        DebugPrint(\"Achievement earned: \" .. tostring(achievementID))" \
    "an earned achievement stays in the shortlist and is offered again"

mutate "Modules/Rares.lua" \
    "            elseif entry.yards and entry.yards <= Rares.clearedWithinYards then" \
    "            elseif true then" \
    "riding past a rare marks it cleared for this character"

mutate "Providers/TomTom.lua" \
    "        if asked and not allowed then
            return false, \"the game does not allow a waypoint on this map\"
        end" \
    "        if false then
            return false, \"the game does not allow a waypoint on this map\"
        end" \
    "a waypoint the client refuses is reported as set"

mutate "Modules/Navigation.lua" \
    "    if Navigation.ownsUserWaypoint and C_Map and C_Map.ClearUserWaypoint then" \
    "    if C_Map and C_Map.ClearUserWaypoint then" \
    "clearing waypoints deletes a pin the player placed by hand"

mutate "Providers/BlizzardCollections.lua" \
    "    if shown == 0 and (owned or 0) > 0 then" \
    "    if true then" \
    "the pet journal's source and type filters are widened on every scan"

mutate "Providers/Blizzard.lua" \
    "        if data.factionID and data.factionID ~= 0 then
            return \"id:\" .. tostring(data.factionID)
        end" \
    "        if data.factionID then
            return \"id:\" .. tostring(data.factionID)
        end" \
    "every reputation header collides on factionID zero"

mutate "Providers/HandyNotes.lua" \
    "        for name in step, state, control do" \
    "        for name in step do" \
    "the HandyNotes plugin iterator drops its state table"

mutate "Modules/Instances.lua" \
    "                instanceID   = saved.instanceID," \
    "                instanceID   = saved.id," \
    "the Adventure Guide is asked with a lockout id"

# 0.54.0: the performance pass, the design system and the first five minutes.
mutate "Routing.lua" \
    "                    if swapped < (entering + leaving) - 1e-9 then" \
    "                    if swapped < (entering + leaving) + 1e9 then" \
    "2-opt accepts a swap that lengthens the route"

mutate "Routing.lua" \
    "                        while low < high do
                            route[low], route[high] = route[high], route[low]" \
    "                        while low < high - 1 do
                            route[low], route[high] = route[high], route[low]" \
    "the in-place reversal leaves the middle of the segment unreversed"

mutate "Routing.lua" \
    "        for offsetX = -1, 1 do
            for offsetY = -1, 1 do" \
    "        for offsetX = 0, 0 do
            for offsetY = 0, 0 do" \
    "clustering only looks in its own cell, so a hub is split at a boundary"

mutate "Scoring.lua" \
    "            if previous
                and entry.decorated == CN.decoratorGeneration
                and Identical(previous, entry.candidates) then" \
    "            if previous then" \
    "an actually-changed provider is treated as unchanged"

mutate "Scoring.lua" \
    "    if aggregate.candidates
        and rebuilt == 0
        and aggregate.providers == providerCount then" \
    "    if aggregate.candidates and rebuilt == 0 then" \
    "a provider that has gone away leaves its rows in the aggregate"

mutate "Objectives.lua" \
    "    local byType = ignored[objectiveType]

    return (byType ~= nil) and (byType[id] ~= nil)" \
    "    return false" \
    "nothing is ever ignored"

mutate "Objectives.lua" \
    "    if byType and next(byType) == nil then
        store[objectiveType] = nil
    end" \
    "    if false then
        store[objectiveType] = nil
    end" \
    "an emptied type bucket lingers, so the empty fast path stops firing"

mutate "Modules/Travel.lua" \
    "    if moved then
        costCache, costCacheCount = {}, 0" \
    "    if false then
        costCache, costCacheCount = {}, 0" \
    "travel costs are remembered after the player has moved away"

mutate "Modules/Quests.lua" \
    "    if CN.NoteSetupStep then
        CN.NoteSetupStep(\"quests\")
    end" \
    "    if false then
        CN.NoteSetupStep(\"quests\")
    end" \
    "a completed quest scan is not recorded, so setup asks for it forever"

mutate "Database.lua" \
    "    if CN.NoteSetupStep then
        CN.NoteSetupStep(key)
    end" \
    "    if false then
        CN.NoteSetupStep(key)
    end" \
    "a scan run from the window does not count as a scan"

mutate "Objectives.lua" \
    "    local resolved = module.Resolve(text)

    if resolved then
        return resolved
    end" \
    "    if false then
        return nil
    end" \
    "a goal can only be named by its id again"

mutate "Modules/Quests.lua" \
    "    if #available < Quests.arrivalMinimum then
        return false
    end" \
    "    if false then
        return false
    end" \
    "arriving anywhere prompts, however little there is to do"

mutate "Modules/Quests.lua" \
    "    if announcedAt and (now - announcedAt) < Quests.arrivalMemorySeconds then
        return false
    end" \
    "    if announcedAt then
        return false
    end" \
    "a zone re-entered hours later never prompts again"

mutate "UI/List.lua" \
    "                row.bar:SetWidth(math.max(1, (width - 12) * fraction))" \
    "                row.bar:SetWidth(math.max(1, width - 12))" \
    "a progress bar is always full"


############################################################
# 0.55.0
############################################################

mutate "Modules/Session.lua" \
    "        if span > Session.instantSpanSeconds then
            return nil
        end

        elapsed = Session.minimumWorkSeconds" \
    "        if span > Session.instantSpanSeconds then
            return nil
        end

        return nil" \
    "a fast objective is discarded instead of floored"

mutate "Modules/Preference.lua" \
    "    if not Preference.IsCreditable(objectiveType) then
        return 1, nil
    end" \
    "    if false then
        return 1, nil
    end" \
    "a type the addon cannot watch is demoted for not being watched"

mutate "Routing.lua" \
    "CN.fallbackZoneYards = 2000" \
    "CN.fallbackZoneYards = 1" \
    "a zone whose size the client will not report becomes one hub"

mutate "Dependencies.lua" \
    "    if type(provider.IsAvailable) ~= \"function\" then" \
    "    if false then" \
    "a quest data provider with no IsAvailable is accepted and never asked"

mutate "Modules/Capture.lua" \
    "    if type(definition.name) ~= \"string\" or definition.name == \"\" then" \
    "    if false then" \
    "a capture with no name is filed under nil"

mutate "Modules/Harvest.lua" \
    "        return a.seen < b.seen" \
    "        return a.id < b.id" \
    "the harvest evicts the lowest quest ids, which is a levelling alt's zone"

mutate "UI.lua" \
    "        CN.Settings().selectedTabName = tab.name" \
    "        CN.Settings().selectedTabName = nil" \
    "the remembered tab is an array index again"

mutate "Events.lua" \
    "        Dispatch(event, ...)

        return
    end

    if event == \"PLAYER_LOGIN\" then" \
    "        return
    end

    if event == \"PLAYER_LOGIN\" then" \
    "ADDON_LOADED handlers are accepted and never called"

mutate "Modules/Harvest.lua" \
    "            Count(record.requires)
            Count(record.observedRequires)" \
    "            Count(record.requires)" \
    "what a quest unlocks ignores everything this addon harvested itself"

mutate "Routing.lua" \
    "        if ok and measured" \
    "        if ok" \
    "a refusal to convert is accepted as a scale of one yard per map unit"

mutate "Modules/Session.lua" \
    "    if span > 1200 then" \
    "    if elapsed > 1200 then" \
    "an implausible span passes once its journey is subtracted"

mutate "Modules/Preference.lua" \
    "    if multiplier == 1 then
        CN.ClearAdjusterReason(objective, \"preference\")

        return score
    end" \
    "    if multiplier == 1 then
        return score
    end" \
    "a withdrawn preference keeps saying you rarely act on these"

# 0.59.0 moved the enabled check above the work. Both halves matter: the gate
# must withdraw the sentence, and it must run before the client call.
mutate "Modules/Preference.lua" \
    "    if not Preference.IsEnabled() then
        CN.ClearAdjusterReason(objective, \"preference\")

        return score
    end" \
    "    if false then
        CN.ClearAdjusterReason(objective, \"preference\")

        return score
    end" \
    "learning that is switched off is still paid for on every pass"


mutate "UI.lua" \
    "        CN.Settings().selectedTabName = tab.name" \
    "        CN.Settings().selectedTabName = nil" \
    "the remembered tab name is not recorded"


############################################################
# 0.56.0
############################################################

# RE-ANCHORED IN 0.70.0: the ceiling test moved into `CN.SecondsNeeded`, which
# is now the one place that decides whether a cost is a measurement.
# NOT MUTATED: the ceiling test moved into `CN.SecondsNeeded` in 0.70.0, and
# `travelKnown` is now a restatement of "did that function answer". Forcing it
# true changes only which of two nil-producing paths is taken, so no assertion
# can see the difference. The property that matters -- one copy of the rule --
# is asserted as a source rule in the 0.70.0 block, with a negative control.



mutate "Modules/Session.lua" \
    "        if span > Session.instantSpanSeconds then" \
    "        if false then" \
    "a stale journey estimate flattens a real sample to the floor"




mutate "Modules/Group.lua" \
    "        local isSelf = UnitIsUnit and UnitIsUnit(unit, \"player\")" \
    "        local isSelf = false" \
    "you are counted as somebody else on your own quest"

mutate "Modules/Group.lua" \
    "    if not sharing or sharing <= 0 then
        CN.ClearAdjusterReason(objective, \"groupShared\")

        return score
    end" \
    "    if not sharing or sharing <= 0 then
        return score
    end" \
    "a sentence about a group you have left is never withdrawn"

mutate "Modules/Group.lua" \
    "    if #units == 0 then
        return nil
    end" \
    "    if #units == 0 then
        return 0
    end" \
    "solo reads as nobody-else-needs-this rather than as nobody-else"

mutate "Modules/Inventory.lua" \
    "    character.bank = character.bank or {}

    return character.bank" \
    "    return CN.Account(\"bank\")" \
    "every alt reads the main's bank as its own"

mutate "Modules/Harvest.lua" \
    "    if held <= (Harvest.cap + Harvest.pruneSlack) then" \
    "    if held <= Harvest.cap then" \
    "the harvest sorts its whole store on every capture at the ceiling"

mutate "Dependencies.lua" \
    "                heldSequence = CN.questDataOrder[index].sequence or heldSequence" \
    "                heldSequence = nil" \
    "a provider that re-registers loses its place in the queue"

mutate "Commands.lua" \
    "            .. table.concat(definition.aliases or {}, \" \") .. \" \"" \
    "            .. \" \"" \
    "the help search cannot find a command by its alias"

mutate "UI/List.lua" \
    "        if #entries == 0 then
            local row = self:GetRow(1)" \
    "        if false then
            local row = self:GetRow(1)" \
    "an empty tab draws nothing at all"

mutate "Modules/Hud.lua" \
    "            if CN.UI then
                CN.UI.persistedFilter = nil
            end" \
    "            if false then
                CN.UI.persistedFilter = nil
            end" \
    "keepfilter off leaves the filter it says it forgot"

mutate "Objectives.lua" \
    "    return CN.stateLabels[state] or string.lower(tostring(state))" \
    "    return tostring(state)" \
    "the state enum is printed to the player"

mutate "Database.lua" \
    "        if db.characters == nil then
            db.characters = {}
        end

        if type(db.characters) ~= \"table\" then
            error(\"db.characters is a \" .. type(db.characters)
                .. \", not a table\" .. CN.DASH .. \"refusing to replace it\")
        end" \
    "        if type(db.characters) ~= \"table\" then
            db.characters = {}
        end" \
    "a corrupt characters table is silently replaced with an empty one"


mutate "Modules/Goals.lua" \
    "        objective.goalPreference = Goals.goalPreference
        objective.userPreference = own + Goals.goalPreference" \
    "        objective.goalPreference = Goals.goalPreference
        objective.userPreference = (objective.userPreference or 0)
            + Goals.goalPreference" \
    "a pinned goal's preference compounds on every rebuild"

mutate "Modules/Goals.lua" \
    "    if not store or next(store) == nil then
        return Goals.Withdraw(objective)
    end" \
    "    if not store or next(store) == nil then
        return objective
    end" \
    "unpinning every goal leaves their weighting behind"



mutate "Modules/Harvest.lua" \
    "    Harvest.unlockGeneration = Harvest.unlockGeneration + 1

    CN.NoteDecoratorsChanged()" \
    "    Harvest.unlockGeneration = Harvest.unlockGeneration + 1

    CN.InvalidateCandidates()" \
    "a harvested unlock never reaches the ranking"

mutate "Modules/Inventory.lua" \
    "        if answered[bag] then
            store.containers[bag] = {}
            store.seenAt[bag]     = now
        end" \
    "        if true then
            store.containers[bag] = {}
            store.seenAt[bag]     = now
        end" \
    "a bank tab the client stops describing is emptied"

mutate "Modules/Session.lua" \
    "        if travelKnown and (not held.known or travelSeconds < held.travel) then" \
    "        if false then" \
    "the journey estimate is frozen at the first sighting"

mutate "Modules/Group.lua" \
    "    if held ~= nil and (Group.Now() - held.at) < Group.sharedCacheSeconds then
        return held.value
    end" \
    "    if held ~= nil then
        return held.value
    end" \
    "a party member finishing a quest never stops counting toward it"


############################################################
# 0.57.0
############################################################

mutate "Scoring.lua" \
    "    for _, field in ipairs(REASON_SOURCES) do" \
    "    for _, field in ipairs({}) do" \
    "the composed answer leaves out every derived sentence"

mutate "Scoring.lua" \
    "    if objective[field][key] == text then
        return false
    end" \
    "    if objective[field][key] ~= nil then
        return false
    end" \
    "a reason carrying a number freezes at the first number"

mutate "Scoring.lua" \
    "    local merged = objective.mergedCompletionValue

    if merged and merged > own then
        return merged
    end" \
    "    local merged = nil

    if merged and merged > own then
        return merged
    end" \
    "what another provider says a thing is worth is ignored"

mutate "Scoring.lua" \
    "    local function Reset(objective)
        if touched[objective] then
            return
        end

        touched[objective]              = true
        objective.mergedReasons         = nil
        objective.mergedCompletionValue = nil
    end" \
    "    local function Reset(objective)
        if touched[objective] then
            return
        end

        touched[objective] = true
    end" \
    "a contribution another provider has stopped making never goes away"

mutate "Modules/Goals.lua" \
    "    CN.NoteDecoratorsChanged(true)
end" \
    "    CN.InvalidateCandidates()
end" \
    "pinning a goal never reaches a row that is already built"

mutate "Routing.lua" \
    "    if moved then
        CN.InvalidateRanking()
    end" \
    "    CN.InvalidateRanking()
    if moved then
    end" \
    "routing the same zone re-ranks the whole addon every two seconds"

mutate "Scoring.lua" \
    "CN.unknownLocationCost = 8" \
    "CN.unknownLocationCost = 3" \
    "not knowing where something is is cheaper than seeing it"

mutate "Objectives.lua" \
    "    if objective.mapID and objective.x and objective.y then
        return false
    end" \
    "    if false then
        return false
    end" \
    "a currency with coordinates is still treated as being nowhere"

mutate "Modules/Inventory.lua" \
    "        if item.startsQuest and not item.questActive then" \
    "        if item.startsQuest then" \
    "quest starters already accepted are offered again"

mutate "Modules/Inventory.lua" \
    "    if held.mount or held.species then
        itemKinds[itemID] = held
    end

    return held" \
    "    itemKinds[itemID] = held

    return held" \
    "an item that is neither a mount nor a pet is remembered as neither forever"

mutate "Routing.lua" \
    "    if now and positionAt == now and positionMap == mapID then" \
    "    if false then" \
    "the client is asked where you are once per call"

mutate "Routing.lua" \
    "    local now = GetTime and GetTime()

    if now and positionAt == now and positionMap == mapID then
        return mapID, positionX, positionY
    end" \
    "    local now = GetTime and GetTime()

    if now and positionAt == now then
        return positionMap, positionX, positionY
    end" \
    "walking into a building leaves the arrow on the zone map"

mutate "Modules/Session.lua" \
    "    if held ~= nil and held.count == count then
        return held.median
    end" \
    "    if held ~= nil then
        return held.median
    end" \
    "a learned duration is memoised past the sample that changed it"

mutate "Modules/Breakdown.lua" \
    "        if reportCache and reportGeneration == CacheKey() then
            return reportCache
        end" \
    "        if reportCache then
            return reportCache
        end" \
    "the remaining counts never notice a new collection"

mutate "Database.lua" \
    "    raw.rescuedCharacters = raw.characters
    raw.characters        = nil" \
    "    raw.characters        = nil" \
    "data the migration refused to destroy is dropped anyway"

############################################################
# 0.58.0
############################################################

mutate "UI/List.lua" \
    "                while index <= count and entries[index].group == group do
                    table.insert(block, entries[index])

                    index = index + 1
                end" \
    "                while false do
                    table.insert(block, entries[index])

                    index = index + 1
                end" \
    "a goal's chain is scattered through the list when it is sorted"

mutate "UI/List.lua" \
    "                if a.pinned ~= b.pinned then
                    return a.pinned
                end" \
    "                if false then
                    return a.pinned
                end" \
    "a section heading is alphabetised against the rows it introduces"

mutate "UI/List.lua" \
    "                if a.key == b.key then
                    return a.order < b.order
                end" \
    "                if false then
                    return a.order < b.order
                end" \
    "two rows that read the same swap places on every refresh"

mutate "UI/List.lua" \
    "            if hit then
                for _, entry in ipairs(block) do
                    table.insert(kept, entry)
                end
            end" \
    "            if hit then
                for _, entry in ipairs(block) do
                    if self:Matches(entry) then
                        table.insert(kept, entry)
                    end
                end
            end" \
    "filtering shows a chain step without the goal it belongs to"

mutate "UI/List.lua" \
    "    if parent then
        UI.listPanels[parent] = list
    end" \
    "    if false then
        UI.listPanels[parent] = list
    end" \
    "the window forgets which tabs have a list at all"

mutate "Core.lua" \
    "    if seconds < 60 then
        return \"just now\"
    end" \
    "    if seconds < 0 then
        return \"just now\"
    end" \
    "a clock that moved backwards prints a negative age"

mutate "Core.lua" \
    "    return days .. CN.Pluralize(days, \" day ago\", \" days ago\")" \
    "    return days .. \" days ago\"" \
    "one day ago is reported in the plural"

mutate "UI.lua" \
    "    if window and window:IsShown() and window.answer then
        window.answer:SetText(CN.Body(text))" \
    "    if false then
        window.answer:SetText(CN.Body(text))" \
    "a button answers into chat behind the window that was clicked"

mutate "UI.lua" \
    "                    elseif step.state == \"BLOCKED\" then
                        marker = \"! \"" \
    "                    elseif false then
                        marker = \"! \"" \
    "a blocked step is marked by its colour and nothing else"

mutate "Modules/Welcome.lua" \
    "    if UISpecialFrames then
        table.insert(UISpecialFrames, \"CompletionNavigatorWelcome\")
    end" \
    "    if false then
        table.insert(UISpecialFrames, \"CompletionNavigatorWelcome\")
    end" \
    "escape does not close the one frame every player is shown"

# NOT `if held then` in place of `if held ~= nil then`: nothing stores `false`
# in this cache any more, and in Lua zero is truthy -- so that mutation is
# behaviourally identical and survived for the honest reason that it is not a
# defect. Same shape as the math.fmod note above. What IS a defect is the
# cache never being written, which the derived-count assertion catches.
mutate "Modules/Travel.lua" \
    "    costCache[key]  = cost
    costCacheCount  = costCacheCount + 1" \
    "    costCacheCount  = costCacheCount + 1" \
    "a travel cost is derived again on every single read"

# RE-ANCHORED IN 0.66.0: the three gsubs here became `CN.Strip`, which is now
# the one definition of "what this says without its colours".
mutate "Core.lua" \
    "    text = text:gsub(\"|c%x%x%x%x%x%x%x%x\", \"\")" \
    "    text = text" \
    "the list sorts on the colour in front of a name instead of the name"

mutate "Core.lua" \
    "    text = text:gsub(\"^[%s%p%d]+\", \"\")" \
    "    text = text" \
    "a route number sorts ahead of the name it belongs to"

mutate "UI.lua" \
    "    if leavingList and not (CN.Settings() and CN.Settings().keepFilter) then
        leavingList:SetFilter(\"\")
    end" \
    "    if false then
        leavingList:SetFilter(\"\")
    end" \
    "the tab you leave keeps a filter its own box no longer shows"

mutate "UI.lua" \
    "        local held = UI.persistedFilter

        window.search:SetText(\"\")
        window.search:ClearFocus()

        UI.persistedFilter = held" \
    "        window.search:SetText(\"\")
        window.search:ClearFocus()" \
    "visiting a tab with no list throws away the filter you asked to keep"

mutate "UI.lua" \
    "                local ok, err = pcall(work)" \
    "                local ok, err = true, work()" \
    "a scan that throws disables its own button for the session"

mutate "UI.lua" \
    "    Stored(\"Quests known\", \"quests\", \"scanquests\"," \
    "    Stored(\"Quests known\", \"quests\", \"discoveractive\"," \
    "a source row runs a scan that cannot clear its own staleness"

############################################################
# 0.59.0
############################################################

# RE-ANCHORED IN 0.88.0: the freshener now also decides whether the row stays
# in the list at all, so the block it guards has one more statement in it.
mutate "Modules/Opportunities.lua" \
    "            if event.endsAt then
                local left = event.endsAt - now" \
    "            if false then
                local left = event.endsAt - now" \
    "a world event's deadline is frozen for half an hour at a time"

mutate "Modules/Opportunities.lua" \
    "                event.endsIn = (left > 0) and left or nil" \
    "                event.endsIn = left" \
    "an event that has finished is given a negative amount of time left"

mutate "Modules/Opportunities.lua" \
    "        local id = Opportunities.EventKey(event)" \
    "        local id = event.title" \
    "a world event is filed under its translated name"

mutate "Modules/Quests.lua" \
    "            travel = CN.unknownLocationCost" \
    "            travel = 5" \
    "a quest with no location is cheaper than one you can see"

mutate "Modules/Rares.lua" \
    "                travel, costed = CN.TravelCost(vignette.mapID, vignette.x, vignette.y)" \
    "                travel, costed = 1, true" \
    "a rare is priced by a number rather than by the journey"

mutate "Core.lua" \
    "    if state and (now - state.ranAt) < seconds then" \
    "    if false then" \
    "a reputation tick re-decorates every candidate in the addon"

mutate "Core.lua" \
    "    debounced[key] = { ranAt = now, pending = false }

    work()" \
    "    debounced[key] = { ranAt = now, pending = false }" \
    "the first event of a burst is swallowed instead of answered"

mutate "Modules/Session.lua" \
    "    local budgetMinutes = math.floor(((requested
        or Session.TypicalSessionMinutes()) or 0) + 0.5)" \
    "    local budgetMinutes = (requested or Session.TypicalSessionMinutes()) or 0" \
    "a fractional plan budget throws on one interpreter and lies on the other"

mutate "Modules/Travel.lua" \
    "    if unit == \"player\" and Travel.hearthSpells[spellID] then
        hearthPending = true
    end" \
    "    if Travel.hearthSpells[spellID] then
        hearthPending = true
    end" \
    "somebody else hearthing teaches the addon where YOUR bind point is"

mutate "Modules/Travel.lua" \
    "    if Travel.NoteHearthArrival() then
        hearthPending = false

        return
    end" \
    "    if Travel.NoteHearthArrival() then
        return
    end" \
    "every loading screen after one hearth is recorded as a bind point"

mutate "Modules/Navigation.lua" \
    "    if angle ~= angle or angle == math.huge or angle == -math.huge then
        return 0
    end" \
    "    if false then
        return 0
    end" \
    "a non-finite bearing reaches the arrow's ten-per-second ticker"

mutate "Modules/Quests.lua" \
    "    discovered[questID] = true" \
    "    discovered[questID] = { firstSeen = time(), source = source }" \
    "a discovered quest carries three fields nothing reads"

mutate "Database.lua" \
    "                    discovered[questID] = true
                    collapsed = collapsed + 1" \
    "                    collapsed = collapsed + 1" \
    "the migration counts records it did not collapse"

# RETARGETED IN 0.61.0, ONTO THE MIGRATION THAT NOW OBSERVABLY DOES THIS.
#
# The old target was migration 12's strip, and it went stale twice over: a
# second `record.questID = nil` appeared in migration 15 so the text matched
# twice, and once re-anchored the mutation SURVIVED -- because migration 15
# replaces a client-supplied row with the name itself, so whether migration 12
# stripped its fields first is no longer observable from outside. A mutation
# that survives because the code it targets is now dead is not a hole in the
# suite; it is a mutation pointed at the wrong line.
#
# Migration 15's strip is the one that still matters, on the one row shape
# that survives as a table: a name the player typed.
mutate "Database.lua" \
    "                if record.source == \"manual\" then
                    -- Left as a table, but without the fields nothing reads.
                    record.questID  = nil
                    record.lastSeen = nil" \
    "                if record.source == \"manual\" then" \
    "a quest name the player typed keeps the key it is already filed under"

mutate "UI/List.lua" \
    "            if filterText and #(lastEntries or {}) > 0 then" \
    "            if false then" \
    "a search that matched nothing tells you to run a scan"

mutate "UI/List.lua" \
    "            row.chevron:SetShown(actionable)" \
    "            row.chevron:SetShown(false)" \
    "whether a row does anything is carried by brightness alone"

mutate "Modules/Hud.lua" \
    "        local objective = clicked.objective or CN.currentRecommendation" \
    "        local objective = CN.currentRecommendation" \
    "the heads-up line names one thing and acts on another"

mutate "UI.lua" \
    "        UI.SetActionsEnabled(panel, #results > 0)" \
    "        UI.SetActionsEnabled(panel, true)" \
    "three buttons stay live above an empty list"

mutate "Modules/Setup.lua" \
    "                if unit then
                    value = value .. \" \" .. unit
                end" \
    "                if false then
                    value = value .. \" \" .. unit
                end" \
    "setup reports eleven numbers that count different things"

mutate "Modules/Preference.lua" \
    "    objective.preferenceBucket = bucket

    return bucket" \
    "    return bucket" \
    "what a quest is is asked of the client once per scoring pass"

mutate "Modules/Tooltips.lua" \
    "        local isToy = CN.Account(\"toys\")[itemID] ~= nil" \
    "        local isToy = false" \
    "a toy hovers without saying why it matters"

mutate "UI.lua" \
    "        panel.selected = false

        for _, objective in ipairs(results) do" \
    "        panel.selected = nil

        for _, objective in ipairs(results) do" \
    "clearing a panel field lets the frame answer for it again"

mutate "UI.lua" \
    "        panel.filtering = false

        -- Type filter." \
    "        -- Type filter." \
    "the Next tab reads a field before anything has written it"

# The regressions the 0.59.0 review found in 0.59.0's own changes.

mutate "Modules/Opportunities.lua" \
    "        if not CN.IsIgnored(CN.objectiveTypes.CURRENCY, id)
            and not CN.IsDeferred(CN.objectiveTypes.CURRENCY, id) then" \
    "        if not CN.IsIgnored(CN.objectiveTypes.CURRENCY, event.title)
            and not CN.IsDeferred(CN.objectiveTypes.CURRENCY, event.title) then" \
    "hiding a world event does nothing, because the key is read twice"

mutate "Modules/Opportunities.lua" \
    "        .. \":\" .. tostring(event.title or \"?\")" \
    "        .. \"\"" \
    "two world events on one day collapse into a single row"

mutate "Modules/Opportunities.lua" \
    "    if type(event.eventID) == \"number\" and event.eventID > 0 then" \
    "    if event.eventID then" \
    "an eventID of zero gives every holiday the same id"

mutate "Scoring.lua" \
    "    local batched = CN.batchSizes[objective]

    if batched and batched > 1 then
        table.insert(terms, {" \
    "    local batched = objective.hubSize

    if batched and batched > 1 then
        table.insert(terms, {" \
    "the ranking explanation leaves out the term worth the most"

mutate "Modules/Travel.lua" \
    "    if Travel.NoteHearthArrival() then
        hearthPending = false

        return
    end" \
    "    hearthPending = false

    Travel.NoteHearthArrival()

    if true then
        return
    end" \
    "a hearth that lands before the client is ready is thrown away"

mutate "Modules/Travel.lua" \
    "    if hearthAttempts >= Travel.hearthRetries then
        hearthPending  = false
        hearthAttempts = 0

        return
    end" \
    "    if false then
        hearthPending  = false
        hearthAttempts = 0

        return
    end" \
    "a hearth the client cannot place leaves the flag armed for ever"

mutate "Modules/Travel.lua" \
    "    if held == nil and CN.CountKeys(BindPoints()) >= Travel.bindPointCap then" \
    "    if false then" \
    "the bind point store grows without a ceiling"

mutate "Modules/Session.lua" \
    "    if budgetMinutes < 1 then
        budgetMinutes = 1
    end" \
    "    if false then
        budgetMinutes = 1
    end" \
    "a plan is built for no time at all"

mutate "Modules/Session.lua" \
    "    local budget = budgetMinutes * 60" \
    "    local budget = (requested or Session.TypicalSessionMinutes()) * 60" \
    "the plan's headline and its budget are two different numbers"

mutate "Modules/Navigation.lua" \
    "    if angle ~= angle or angle == math.huge or angle == -math.huge then" \
    "    if angle ~= angle then" \
    "an infinite bearing becomes a NaN on the arrow's ticker"

############################################################
# 0.60.0 -- everything that could go stale and had no way of being told
############################################################

mutate "Modules/Inventory.lua" \
    "        \"BAG_UPDATE_DELAYED\", \"PLAYER_ENTERING_WORLD\",
        \"QUEST_TURNED_IN\", \"QUEST_REMOVED\", \"QUEST_ACCEPTED\",
        \"QUEST_LOG_UPDATE\"," \
    "        \"BAG_UPDATE_DELAYED\", \"PLAYER_ENTERING_WORLD\"," \
    "a quest you handed in stays on the list and on the route"

# The declaration as it shipped for eleven releases: one event, for a provider
# whose rows can be about six different systems.
mutate "Modules/Goals.lua" \
    "    events = {
        \"ZONE_CHANGED_NEW_AREA\",
        \"QUEST_TURNED_IN\", \"QUEST_REMOVED\", \"QUEST_ACCEPTED\",
        \"NEW_MOUNT_ADDED\", \"NEW_PET_ADDED\", \"NEW_TOY_ADDED\",
        \"ACHIEVEMENT_EARNED\", \"UPDATE_FACTION\",
    }," \
    "    events = { \"ZONE_CHANGED_NEW_AREA\" }," \
    "a goal you finished never leaves the list, and follow mode sticks on it"

mutate "Modules/Toys.lua" \
    "    events = { \"NEW_TOY_ADDED\", \"MERCHANT_SHOW\", \"ZONE_CHANGED_NEW_AREA\" }" \
    "    events = { \"NEW_TOY_ADDED\", \"MERCHANT_SHOW\" }" \
    "a toy keeps the travel cost it had in the zone you left"

mutate "Scoring.lua" \
    "    return universalEvents[reason] == true" \
    "    return false" \
    "the events that must reach every provider reach none of them"

mutate "Scoring.lua" \
    "        if universal or not provider.events or provider.events[reason] then" \
    "        if not reason or not provider.events or provider.events[reason] then" \
    "levelling up invalidates nothing at all"

mutate "Scoring.lua" \
    "            CN.NoteDecoratorsChanged(true)" \
    "            CN.decoratorGeneration = CN.decoratorGeneration + 1" \
    "a decorator registered late never reaches the rows already built"

mutate "Modules/Filters.lua" \
    "        -- Something is actionable again that was not a moment ago, which is
        -- exactly what a deliberate invalidation means.
        CN.InvalidateCandidates()" \
    "        local told = nil" \
    "a deferral that runs out never brings the objective back"

mutate "Modules/Currencies.lua" \
    "        if record.capped and IsCurrent(record, character) then" \
    "        if record.capped then" \
    "a currency retired two seasons ago is still recommended"

mutate "Modules/Currencies.lua" \
    "    return record.serial == CurrentSerial(character)" \
    "    return true" \
    "every currency the store has ever held is reported as current"

mutate "Modules/Group.lua" \
    "    if held ~= nil and (Group.Now() - held.at) < Group.sharedCacheSeconds then
        return held.value
    end" \
    "    if held ~= nil then
        return held.value
    end" \
    "a party member finishing a quest never stops counting toward it"

mutate "Modules/Warband.lua" \
    "        if age and age > alts.staleDays then
            return 0, nil
        end" \
    "        if false then
            return 0, nil
        end" \
    "a character deleted a month ago still reorders today's list"

mutate "Modules/Travel.lua" \
    "        if (time() - (held.at or 0)) > (Travel.flyableDenialDays * 86400) then
            return nil
        end" \
    "        if false then
            return nil
        end" \
    "a zone that refused flight before your unlock refuses it for ever"

mutate "Modules/Travel.lua" \
    "    FlightMemory()[mapID] = { flyable = false, at = time() }" \
    "    FlightMemory()[mapID] = false" \
    "a flight refusal is recorded with no way to tell how old it is"

mutate "Modules/Exploration.lua" \
    "        if RefreshCurrentZone() then
            CN.InvalidateProvider(\"Exploration\")
        end" \
    "        local refreshed = nil" \
    "the subzone count is frozen from the moment you enter the zone"

mutate "Modules/Exploration.lua" \
    "    Exploration.NoteProgress(record, done, done and done >= criteria)" \
    "    Exploration.NoteProgress(record, done, nil)" \
    "a zone you finished sits at the top of the list reading zero left"

mutate "Modules/Orders.lua" \
    "    volatile = true,
    cooldown = 30," \
    "    cooldown = 30," \
    "a crafting order still says it expires in six hours, six hours later"

mutate "Modules/Hud.lua" \
    "    frame:SetFrameStrata(\"MEDIUM\")" \
    "    frame:SetFrameStrata(\"BACKGROUND\")" \
    "the heads-up line sits below everything and cannot be clicked"

mutate "Modules/Hud.lua" \
    "            Hud.SetEnabled(false)

            CN.Print(\"Heads-up line off. \" .. CN.Aside(CN.Accent(\"/cn hud\")" \
    "            frame:Hide()

            CN.Print(\"Heads-up line off. \" .. CN.Aside(CN.Accent(\"/cn hud\")" \
    "the x hides the heads-up line and the next refresh brings it back"

mutate "UI.lua" \
    "    local existingEnter = frame:GetScript(\"OnEnter\")" \
    "    local existingEnter = nil" \
    "attaching a tooltip silently deletes the hover handler already there"

mutate "UI.lua" \
    "    for _, provider in pairs(CN.candidateProviders or {}) do
        for event in pairs(provider.events or {}) do
            wanted[event] = true
        end
    end" \
    "    for _, provider in pairs({}) do
        for event in pairs(provider.events or {}) do
            wanted[event] = true
        end
    end" \
    "the window redraws for six events and misses everything else"

# The regressions the 0.60.0 review found in 0.60.0's own changes.

mutate "Scoring.lua" \
    "    CN.InvalidateCandidates(nil, not deliberate)" \
    "    CN.InvalidateCandidates()" \
    "a reputation tick forces every provider to drop its own cooldown"

mutate "Scoring.lua" \
    "    local deliberate = (not patient)
        and ((reason == nil) or CN.deliberateEvents[reason] or false)" \
    "    local deliberate = (reason == nil) or CN.deliberateEvents[reason] or false" \
    "asking for patience is ignored"

mutate "Scoring.lua" \
    "CN.baseInvalidationEvents = {" \
    "CN.baseInvalidationEvents = {
    \"ZONE_CHANGED_NEW_AREA\"," \
    "walking into a cave rebuilds every provider in the addon"

mutate "Modules/Travel.lua" \
    "    if FlightMemory()[mapID] == true then
        return false
    end" \
    "    if false then
        return false
    end" \
    "a cave revokes a zone's flight permission for a day"

# RETARGETED IN 0.62.0. The exact-match line this pointed at could never
# match anything -- an achievement name is not a zone name -- and was replaced
# by a trailing whole-word-run rule. The property being protected is the same:
# "Shadowmoon" must not match "Explore Shadowmoon Valley".
mutate "Modules/Exploration.lua" \
    "        return string.sub(candidate, -(#needle + 1)) == (\" \" .. needle)" \
    "        return string.find(candidate, needle, 1, true) ~= nil" \
    "two zones with the same name overwrite each other's progress"

mutate "Modules/Exploration.lua" \
    "    if matched and mapID and count == 1 then
        -- Learned, so the ambiguity is resolved once rather than every time
        -- -- and only where there was no ambiguity to begin with.
        matched.mapID = mapID
    end" \
    "    if false then
        matched.mapID = mapID
    end" \
    "which of two zones with one name you get is a coin toss every time"

mutate "Modules/Exploration.lua" \
    "    if not criteria or criteria <= 0 then
        return false
    end" \
    "    if false then
        return false
    end" \
    "a client that will not answer overwrites a scanned count with nothing"

mutate "Database.lua" \
    "                    if type(record) == \"table\" and record.serial == nil then
                        record.serial = 0" \
    "                    if false then
                        record.serial = 0" \
    "every currency stored before this release is assumed still to exist"

mutate "Modules/Warband.lua" \
    "            return Freshest(holders), table.concat(holders, \", \"),
                \"already known by another character\", false" \
    "            return holders[1], table.concat(holders, \", \"),
                \"already known by another character\", false" \
    "a deleted alt sorting first hides a character you played yesterday"

mutate "Modules/Hud.lua" \
    "    frame.label:SetPoint(\"TOPRIGHT\", -(inset + CN.CLOSE_WIDTH), -inset)" \
    "    frame.label:SetPoint(\"TOPRIGHT\", -inset, -inset)" \
    "the close button sits on top of the end of the objective's name"

mutate "Modules/Appearances.lua" \
    "        if held and (held.collected or 0) > collected then
            collected = held.collected
        end" \
    "        if false then
            collected = held.collected
        end" \
    "a wardrobe that has not loaded erases every scanned count"

# ------------------------------------------------------------
# 0.61.0
# ------------------------------------------------------------

mutate "Core.lua" \
    "    if percent >= 100 and fraction < 1 then
        percent = 100 - (1 / scale)
    end" \
    "    if false then
        percent = 100 - (1 / scale)
    end" \
    "999 of 1,000 reads as finished"

mutate "Core.lua" \
    "    if filled >= width and fraction < 1 then
        filled = width - 1
    end" \
    "    if false then
        filled = width - 1
    end" \
    "a bar 39 of 40 full is drawn as a finished one"

mutate "Providers/BlizzardWorld.lua" \
    "            if limit and #criteria >= limit then
                summary.truncated = true
            else" \
    "            if false then
                summary.truncated = true
            else" \
    "the criteria list ignores its own cap"

mutate "Providers/BlizzardWorld.lua" \
    "            summary.total = summary.total + 1" \
    "            summary.total = summary.total" \
    "an achievement reports a denominator of zero"

mutate "Modules/Reputations.lua" \
    "            cycles = math.floor(value / threshold)
            within = value % threshold" \
    "            cycles = math.floor(value / threshold)
            within = value" \
    "paragon prints the sum of every cache ever earned"

mutate "Modules/Reputations.lua" \
    "            if pending then
                -- The finished cycle, not the one it has already rolled into.
                within = threshold" \
    "            if false then
                within = threshold" \
    "a paragon cache that is ready shows a nearly empty bar"

mutate "Modules/Sets.lua" \
    "        local key = \"set:\" .. tostring(set.setID)" \
    "        local key = set.setID" \
    "a transmog set is filed under an appearance category's id"

# RETARGETED IN 0.63.0. The English match is gone rather than demoted, so the
# property to protect is the locale-free one that replaced it: knowledge first
# by id, then by how much of the week's cap is still unclaimed.
mutate "Modules/Waiting.lua" \
    "            local knowledge = Waiting.knowledgeCurrencies[currencyID] == true" \
    "            local knowledge = false" \
    "knowledge is identified only by an English word"

# NOT MUTATED: the `open` preference in `LockoutFor`.
#
# `Instances.Lockouts` sorts incomplete lockouts first, so in every path the
# game takes, the first name match IS the open one and removing the
# preference changes nothing observable. The preference stays -- relying on
# another function's sort order for correctness here is precisely the "two
# lists, one of which nobody checks" defect this project keeps finding -- but
# a mutation that cannot be killed by construction does not belong in this
# file. The difficulty match below is the part that is observable.
mutate "Modules/Instances.lua" \
    "            if difficulty and lockout.difficulty == difficulty then
                exact = exact or lockout
            end" \
    "            if false then
                exact = exact or lockout
            end" \
    "a lockout answers for a difficulty other than the one asked about"

mutate "Modules/Instances.lua" \
    "        local text = vault.FormatReset(seconds)

        if text then
            return text
        end" \
    "        return vault.FormatReset(seconds)" \
    "an unknown reset time is concatenated as a nil"

mutate "Modules/Achievements.lua" \
    "            names[record] = NameOf(achievementID, record) or \"\"" \
    "            record.resolvedName = NameOf(achievementID, record) or \"\"
            names[record] = record.resolvedName" \
    "a client-supplied achievement name is written to the database"

mutate "Modules/Loremaster.lua" \
    "    if characterKey == (CN.characterKey or CN.GetCharacterKey()) then
        return record.done or 0
    end

    return nil" \
    "    return record.done or 0" \
    "another character is shown whichever character scanned last"

mutate "Modules/Loremaster.lua" \
    "    if #name ~= #bestName then
        return #name < #bestName
    end

    return id < bestID" \
    "    return false" \
    "a zone picks a different achievement on every login"

mutate "Modules/Loremaster.lua" \
    "    if #name ~= #bestName then
        return #name < #bestName
    end" \
    "    if #name ~= #bestName then
        return #name > #bestName
    end" \
    "the zone shows its side-collection achievement instead of its story"

mutate "Modules/Loremaster.lua" \
    "    if heldDone ~= mineDone then
        return not mineDone
    end" \
    "    if heldDone ~= mineDone then
        return mineDone
    end" \
    "a finished zone achievement hides the one still in progress"

mutate "Modules/Progress.lua" \
    "    elseif Progress.knownResetAt then" \
    "    elseif false then" \
    "a loading screen moves today's count into yesterday"

mutate "Modules/Capture.lua" \
    "        elseif type(key) == \"string\" then
            if described < width then
                described = described + 1" \
    "        elseif type(key) == \"string\" then
            if shape.count <= width then
                described = described + 1" \
    "a capture spends its field budget on array entries"

mutate "Providers/TomTom.lua" \
    "            if current.position and not samePlace then" \
    "            if false then" \
    "a pin the player dragged is deleted as though it were the addon's"

mutate "Routing.lua" \
    "        CN.ForgetBatching()
        CN.ForgetRoutes()" \
    "        CN.ForgetBatching()" \
    "the routes for the zone behind you are held for the session"

# SUPERSEDED IN 0.63.0 by "discovering a quest rewalks your whole quest
# history" below: the snapshot is no longer keyed on the set's size, because
# the size changes dozens of times on walking into new content.
mutate "Modules/Breakdown.lua" \
    "    if held then
        return held.completed
    end" \
    "    if false then
        return held.completed
    end" \
    "the Remaining tab walks thirty thousand quests on every refresh"

# The five defects the 0.61.0 review found in 0.61.0's own changes.

mutate "Modules/Vendors.lua" \
    "            local recipeName = names[recipeID]" \
    "            local recipeName = sellable[itemID]" \
    "a recipe row is named after the table of vendors that sell it"

mutate "Scoring.lua" \
    "    CN.collectionGeneration = (CN.collectionGeneration or 0) + 1" \
    "    CN.collectionGeneration = (CN.collectionGeneration or 0)" \
    "the Scans tab says not scanned after you scan"

mutate "Modules/Breakdown.lua" \
    "    -- The client is the authority on whether this actually completed. A
    -- repeatable quest answers false here and is correctly not credited.
    if not quests.IsCompletedByCharacter(questID) then" \
    "    if false then" \
    "a repeatable turn-in counts as a completed quest"

mutate "Modules/Breakdown.lua" \
    "    held.counted = held.counted or {}

    if held.counted[questID] then
        return
    end

    local quests = CN:GetModule(\"Quests\")

    if not quests or not quests.IsCompletedByCharacter then
        return
    end

    -- The client is the authority" \
    "    held.counted = held.counted or {}

    local quests = CN:GetModule(\"Quests\")

    if not quests or not quests.IsCompletedByCharacter then
        return
    end

    -- The client is the authority" \
    "handing the same quest in twice counts it twice"

mutate "Modules/Progress.lua" \
    "    if seconds then
        Progress.resetIsEstimate = false
    end" \
    "    if false then
        Progress.resetIsEstimate = false
    end" \
    "the estimated day key is never promoted to the real one"

mutate "Modules/Progress.lua" \
    "    if store.dayKey ~= today and estimatedKey
        and not Progress.resetIsEstimate then

        store.dayKey = today
    end" \
    "    if false then
        store.dayKey = today
    end" \
    "correcting an estimated day key is treated as a new day"

# And the two defects the SECOND review found in the first review's fixes.

mutate "Modules/Progress.lua" \
    "    if store.dayKey ~= today and estimatedKey" \
    "    if store.dayKey ~= today and store.dayKeyWasEstimate" \
    "the provisional day-key flag is read from the database"

mutate "Modules/Breakdown.lua" \
    "    if force then
        Breakdown.ForgetQuestCounts()
    end" \
    "    if false then
        Breakdown.ForgetQuestCounts()
    end" \
    "pressing Refresh does not recount the quests"

# ------------------------------------------------------------
# 0.62.0
# ------------------------------------------------------------

mutate "Modules/Exploration.lua" \
    "        return string.sub(candidate, -(#needle + 1)) == (\" \" .. needle)" \
    "        return false" \
    "the exploration lookup finds nothing in any zone"

mutate "Modules/Mounts.lua" \
    "    local kind = record and Mounts.sourceTypes[record.sourceType]" \
    "    local kind = nil" \
    "a mount is ranked by an English sentence"

mutate "Modules/Breakdown.lua" \
    "    return Breakdown.generation .. \":\" .. tostring(CN.collectionGeneration or 0)" \
    "    return Breakdown.generation" \
    "learning a recipe leaves the Remaining tab stale"

mutate "Modules/Pets.lua" \
    "                if not counted[pet.speciesID] then" \
    "                if true then" \
    "the pet scan counts a species once per copy held"

mutate "Providers/BlizzardWorld.lua" \
    "    if ok and type(ids) == \"table\" and #ids > 0 then" \
    "    if ok and type(ids) == \"table\" then" \
    "an empty completed list becomes a session baseline of zero"

mutate "Modules/Currencies.lua" \
    "            local against = currency.useTotalEarnedForMaxQty
                and (currency.totalEarned or 0)
                or currency.quantity" \
    "            local against = currency.quantity" \
    "a currency capped on earnings is measured against the balance"

mutate "Modules/Achievements.lua" \
    "            if (watched[achievementID] or approaching)
                and record.criteria and record.criteria > 0 then" \
    "            if record.criteria and record.criteria > 0 then" \
    "the criteria sweep polls every tracked achievement every five seconds"

mutate "Modules/Achievements.lua" \
    "            if (watched[achievementID] or approaching)" \
    "            if (watched[achievementID])" \
    "an achievement can only enter the shortlist if it was already on it"

mutate "Modules/Appearances.lua" \
    "    local live = Blizzard.GetAppearanceCategoryName
        and Blizzard.GetAppearanceCategoryName(categoryID)

    if live then
        return live
    end" \
    "    local record = Store()[categoryID]

    if record and record.name then
        return record.name
    end" \
    "an appearance slot is named from disk instead of from the client"

mutate "Modules/Appearances.lua" \
    "    lastRescan = time()" \
    "" \
    "a login scan leaves the transmog throttle unstamped"

mutate "Database.lua" \
    "        for _, profile in pairs(db.characters or {}) do
            if type(profile) == \"table\" then
                strip(profile.reputations)
            end
        end" \
    "" \
    "migration 37 strips account names and leaves every character's behind"

mutate "Character.lua" \
    "    return tostring(realm or \"UnknownRealm\") .. \"-\" .. tostring(name or \"Unknown\")" \
    "    return tostring(name or \"Unknown\") .. \"-\" .. tostring(realm or \"UnknownRealm\")" \
    "a character key is built name-first"

# ------------------------------------------------------------
# 0.63.0
# ------------------------------------------------------------

mutate "Modules/Currencies.lua" \
    "                quantity   = record.cappedAgainst or record.quantity," \
    "                quantity   = record.quantity," \
    "a capped currency prints the balance it was not measured against"

mutate "Providers/BlizzardWorld.lua" \
    "                accountWide     = info.isAccountWide and true or false," \
    "                accountWide     = (info.isAccountWide
                    or info.isAccountTransferable) and true or false," \
    "a currency you can move is treated as one everybody has"

mutate "Modules/Quests.lua" \
    "    if source == \"blizzard\" or source == \"questlog\" then" \
    "    if source ~= \"manual\" then" \
    "a map-pin guess outranks the quest log and cannot be corrected"

mutate "Modules/Opportunities.lua" \
    "            travelCost       = travel,
            travelCosted     = costed or nil," \
    "            limitedTimeBonus = Opportunities.Urgency(worldQuest.secondsLeft),
            travelCost       = travel,
            travelCosted     = costed or nil," \
    "one deadline is charged twice through two curves"

mutate "Modules/Breakdown.lua" \
    "    if held then
        return held.completed
    end" \
    "    if held and held.size == CN.CountKeys(discovered) then
        return held.completed
    end" \
    "discovering a quest rewalks your whole quest history"

mutate "Modules/Harvest.lua" \
    "    if CN.SameIDList(record.observedRequires, prerequisites) then
        return false
    end" \
    "    if record.observedRequires then
        return false
    end" \
    "an inferred ordering can never be corrected"

mutate "Modules/Progress.lua" \
    "    if not ids then
        lifetimeCache.valid = false
        lifetimeCache.value = nil

        return nil
    end" \
    "    if not ids then
        lifetimeCache.valid = true
        lifetimeCache.value = nil

        return nil
    end" \
    "a login that answers late never gets a session baseline"

mutate "Modules/Alts.lua" \
    "CN.TokenLabel(row.class or \"\")" \
    "tostring(row.class or \"\")" \
    "/cn alts prints a raw class token"

# ------------------------------------------------------------
# 0.64.0
# ------------------------------------------------------------

mutate "Modules/Exploration.lua" \
    "    if characterKey == (CN.characterKey or CN.GetCharacterKey()) then
        return record.done or 0, record.completed and true or false
    end

    return nil, nil" \
    "    return record.done or 0, record.completed and true or false" \
    "an alt is shown whichever character explored last"

mutate "Modules/Exploration.lua" \
    "        if Names(Exploration.NameOf(achievementID, record)) then" \
    "        if Names(record.name) then" \
    "the zone lookup reads a name frozen at the last scan's language"

mutate "Scoring.lua" \
    "        if bursty then
            CN.Debounce(\"collectionGeneration.\" .. event,
                CN.collectionBurstSeconds, CN.NoteCollectionChanged)
            return
        end" \
    "        if false then
            return
        end" \
    "a reputation tick rebuilds every store in the addon"

# RE-ANCHORED IN 0.66.0: the throttle, the deferral and the scan moved into
# `SweepIfDue`, so the frame check lives there now.
mutate "Modules/Currencies.lua" \
    "    if CurrencyFrameOpen() then
        return false
    end" \
    "    if false then
        return false
    end" \
    "the currency sweep reopens the player's collapsed headers"

mutate "Modules/Currencies.lua" \
    "    local ok = pcall(frame.HookScript, frame, \"OnHide\", function()
        pcall(Currencies.SweepIfDue)
    end)" \
    "    local ok = true" \
    "closing the currency window never collects the sweep it deferred"

mutate "Modules/Waiting.lua" \
    "        if currencies.IsCurrent(record)
            and record.maxWeeklyQuantity and record.maxWeeklyQuantity > 0" \
    "        if record.maxWeeklyQuantity and record.maxWeeklyQuantity > 0" \
    "/cn clock reports a currency the client has retired"

mutate "Providers/StaticData.lua" \
    "        return false, classReason, \"CLASS\"" \
    "        return false, classReason" \
    "the block reason has to be parsed back out of English prose"

mutate "Modules/Loremaster.lua" \
    "            local heldName = (live and live ~= \"\" and live)
                or Loremaster.NameOf(id, record)" \
    "            local heldName = record.name" \
    "the zone achievement is matched against a stored name"

mutate "Core.lua" \
    "    local global = CN.factionGlobals[token]" \
    "    local global = nil" \
    "the roster prints an untranslated faction token"

# ------------------------------------------------------------
# 0.65.0
# ------------------------------------------------------------

mutate "Modules/Exploration.lua" \
    "                name            = Exploration.NameOf(record.achievementID,
                    record)," \
    "                name            = record.name," \
    "every exploration row renders as its achievement id"

mutate "Modules/Vendors.lua" \
    "        zone  = record.mapID and CN.Blizzard.GetMapName(record.mapID)
            or record.zone," \
    "        zone  = record.zone," \
    "a recommended recipe loses the zone its vendor is in"

mutate "Modules/Goals.lua" \
    "            plan.source = mounts and mounts.SourceText
                and mounts.SourceText(goal.id, record)" \
    "            plan.source = record.source" \
    "a mount goal stops saying where the mount comes from"

mutate "Modules/Exploration.lua" \
    "            local hereDone, hereComplete = Exploration.DoneFor(here)" \
    "            local hereDone, hereComplete = here.done, here.completed" \
    "the this-zone line shows another character's exploration"

mutate "Modules/Reputations.lua" \
    "        return CN.RenownLabel(record.renownLevel or record.renown or 0)" \
    "        return \"Renown \" .. tostring(record.renownLevel or record.renown or 0)" \
    "renown is printed in English beside translated standings"

# NOT MUTATED: `CN.scopes.ACCOUNT` and the literal are the same string today,
# so swapping them cannot change behaviour -- the whole point is that they stop
# being the same the moment the sentence is translated. A mutation that cannot
# fail does not belong here; the property is asserted as a source rule in the
# 0.65.0 block instead.

# RE-ANCHORED IN 0.66.0: `Resolve` searches the client's whole list rather than
# what this character holds, so the language property is asserted on the name
# the client hands back rather than on which table is walked.
mutate "Modules/Titles.lua" \
    "        local name = title.name or Titles.NameOf(title.titleID)" \
    "        local name = CN.Account(\"titleNames\")[title.titleID]" \
    "a title cannot be found by name after a language change"

# RE-ANCHORED IN 0.88.0: the throttle is stamped AFTER the refusal guard, so
# that a sweep the client would not answer is retried rather than waited out.
mutate "Modules/Currencies.lua" \
    "    lastScan = time()

    local serial = NextSerial()" \
    "    local serial = NextSerial()" \
    "a manual scan arms a second sweep a second later"

mutate "UI.lua" \
    "        local held = CN.Memo(\"ui:sources:stored\", CN.collectionGeneration,
            function() return UI.Sources(\"stored\") end)" \
    "        local held = UI.Sources(\"stored\")" \
    "the Sources tab rewalks ten stores every two seconds"

mutate "UI.lua" \
    "        for _, row in ipairs(UI.Sources(\"live\")) do" \
    "        for _, row in ipairs({}) do" \
    "the live rows on the Scans tab are never rebuilt"

mutate "Modules/Quests.lua" \
    "    if isNew and CN.CountKeys(store) > Quests.rememberedCap then" \
    "    if CN.CountKeys(store) > Quests.rememberedCap then" \
    "every quest pin walks the whole remembered store"

############################################################
# 0.66.0
############################################################

mutate "Modules/Harvest.lua" \
    "            table.insert(lines, \"        -- \" .. zone)" \
    "            table.insert(lines, \"       \" .. CN.DASH .. \"\" .. zone)" \
    "the export writes a display glyph where a Lua comment belongs"

mutate "Modules/Rares.lua" \
    "    if time() - previous >= Rares.sightingGap then
        record.sightings = (record.sightings or 0) + 1
    end" \
    "    record.sightings = (record.sightings or 0) + 1" \
    "a sighting counts event dispatches instead of encounters"

mutate "Modules/Rares.lua" \
    "    CN.Debounce(\"Rares.vignettes\", 1, VignetteWork)" \
    "    VignetteWork()" \
    "the vignette handler runs several times a second"

mutate "Modules/Rares.lua" \
    "        if Rares.IsClearedByCharacter(vignetteID) then" \
    "        if kills[vignetteID] then" \
    "an expired clear is still counted as cleared"

mutate "Modules/Reputations.lua" \
    "    if record.kind == \"RENOWN\" then
        return CN.RenownLabel(record.renownLevel or record.renown or 0)
    end" \
    "    if false then
        return nil
    end" \
    "a renown standing is read off the field a migration deletes"

mutate "Modules/Goals.lua" \
    "        if Blizzard.IsAccountWideReputation(goal.id) then" \
    "        if CN.Account(\"reputations\")[goal.id] then" \
    "a goal decides scope from the store the answer sorts into"

mutate "Modules/Titles.lua" \
    "    for _, title in ipairs(Blizzard.GetTitles()) do
        local name = title.name or Titles.NameOf(title.titleID)" \
    "    for title in pairs(CharacterStore() or {}) do
        local name = Titles.NameOf(title)" \
    "a title is findable only if this character already has it"

mutate "Modules/Filters.lua" \
    "        return record and record.name
            or (CN.TypeBadge(objectiveType) .. \" \" .. numericID)" \
    "        return record and record.name or (objectiveType .. \" \" .. numericID)" \
    "a hidden rare is described with the internal enum"

mutate "Modules/Quests.lua" \
    "    for _, pin in ipairs(Quests.OffMapOffers()) do" \
    "    for _, pin in ipairs({}) do" \
    "quests in the next zone are never offered"

mutate "Modules/Quests.lua" \
    "            and not Blizzard.IsQuestInLog(pin.questID) then" \
    "            then" \
    "a quest already in the log is offered as one to go and get"

mutate "Design.lua" \
    "    object:SetFont(file, math.floor(size * scale + 0.5), flags)" \
    "    object:SetFont(file, size, flags)" \
    "the text-size setting derives a font at the same size"

mutate "Design.lua" \
    "    for fontString, role in pairs(textStrings) do
        ApplyRole(fontString, role)

        touched = touched + 1
    end" \
    "    for _ in pairs(textStrings) do
        touched = touched + 1
    end" \
    "text already on screen keeps its old size"

mutate "Modules/Exploration.lua" \
    "    record.progress      = record.progress or {}
    record.progress[key] = {" \
    "    record.progress      = record.progress or {}
    record.done          = done
    record.completed     = completed and true or false
    record.progress[key] = {" \
    "an alt is handed the last character's zone progress"

############################################################
# 0.67.0
############################################################

mutate "UI.lua" \
    "        local sources = {}

        for _, row in ipairs(held) do
            table.insert(sources, row)
        end" \
    "        local sources = held" \
    "the Scans tab grows by five rows every two seconds"

mutate "Core.lua" \
    "        if held.count == nil or held.count == #held.value then
            return held.value
        end" \
    "        return held.value" \
    "a memoized value mutated by its reader is served anyway"

# NOT MUTATED: `UI.RefreshAllTabs` builds the window before refreshing, and by
# the time any test reaches it the window already exists -- every earlier block
# opens it. The property only differs on a FRESH login, which a single-process
# suite has exactly one of, and it is spent before this code is reachable.
# Asserted as a source rule in the 0.67.0 block instead.

mutate "UI.lua" \
    "    for _, tab in ipairs(UI.tabs) do
        UI.BuildPanel(tab)

        if tab.refresh and tab.panel then" \
    "    for _, tab in ipairs(UI.tabs) do
        if tab.refresh and tab.panel then" \
    "the search is blind to every tab the player has not clicked"

mutate "Design.lua" \
    "    if type(object) == \"string\" then
        object = _G and _G[object]
    end" \
    "    if false then
        object = nil
    end" \
    "text size can be raised but never lowered"

mutate "Design.lua" \
    "    local applied = pcall(fontString.SetFont, fontString, face,
        math.floor(asked * CN.TextScale() + 0.5), \"OUTLINE\")" \
    "    local applied = pcall(fontString.SetFont, fontString, face, asked,
        \"OUTLINE\")" \
    "text drawn over the world ignores the text-size setting"

mutate "Modules/Currencies.lua" \
    "    return frame:IsVisible() and true or false" \
    "    return frame:IsShown() and true or false" \
    "opening the currency tab once disables the sweep for the session"

mutate "Modules/Currencies.lua" \
    "    local frame = _G.TokenFrame

    if not frame or not frame.HookScript then" \
    "    local frame = _G.TokenFrame or _G.CharacterFrame

    if not frame or not frame.HookScript then" \
    "the currency hook lands on whatever frame exists at login"

mutate "Modules/Quests.lua" \
    "        if mapID and not Skip(mapID)
            and not Quests.IsCompletedByCharacter(questID)" \
    "        if mapID and not Skip(mapID)
            and not Quests.IsCompletedOnAccount(questID)" \
    "an alt is offered nothing its main has already finished"

mutate "Modules/Quests.lua" \
    "        if mapID and not Skip(mapID)" \
    "        if mapID and mapID ~= playerMap" \
    "a quest in the zone you are standing in is priced as a journey"

mutate "Modules/Quests.lua" \
    "        .. \":\" .. tostring(Quests.pinRevision)" \
    "        .. \":\" .. tostring(CN.CountKeys(Remembered()))" \
    "the off-map cache key walks the whole remembered store"

mutate "Modules/Achievements.lua" \
    "                if criteria and criteria > 0
                    and done ~= (Achievements.DoneFor(record) or 0) then" \
    "                if done ~= (Achievements.DoneFor(record) or 0) then" \
    "a refusal from the criteria API is written in as progress"

mutate "Modules/Filters.lua" \
    "        local stored = CN.Account(\"recipeNames\")[numericID]

        if stored and stored ~= \"\" then
            return stored
        end" \
    "        local stored = nil

        if stored then
            return stored
        end" \
    "a recipe id is looked up as though it were an item id"

mutate "Modules/Filters.lua" \
    "    return CN.TypeBadge(objectiveType) .. \" \" .. tostring(id)" \
    "    return tostring(objectiveType) .. \" \" .. tostring(id)" \
    "an id that is not a number is described with the internal enum"

mutate "Modules/Setup.lua" \
    "    { key = \"loremaster\",  label = \"Loremaster\",  module = \"Loremaster\",  fn = \"Scan\",     unit = \"quest achievements\", measured = true, retry = \"scanlore\", perCharacter = \"HasScanned\" }," \
    "" \
    "a new character never scans the one store with a per-character split"

############################################################
# 0.68.0
############################################################

mutate "Events.lua" \
    "        if loadedAddon ~= ADDON_NAME then
            Dispatch(event, ...)

            return
        end" \
    "        if loadedAddon ~= ADDON_NAME then
            return
        end" \
    "a handler waiting for another addon to load is never called"

mutate "Scoring.lua" \
    "    if quiet then
        return results
    end" \
    "    if false then
        return results
    end" \
    "counting the ranking tells the player it was offered"

mutate "Scoring.lua" \
    "    if type(secondsNeeded) == \"number\" and secondsNeeded > 0
        and secondsLeft < secondsNeeded then

        return 0
    end" \
    "    if false then
        return 0
    end" \
    "a deadline the player cannot reach is scored as urgent"

mutate "Scoring.lua" \
    "    return cost * CN.secondsPerCostPoint
end" \
    "    return cost
end" \
    "a journey in cost points is treated as a journey in seconds"

mutate "Database.lua" \
    "        for _, record in pairs(db.account.loremaster or {}) do
            if type(record) == \"table\" and record.done ~= nil then
                record.done = nil" \
    "        for _, record in pairs(db.account.loremaster or {}) do
            if type(record) == \"table\" and record.done ~= nil then
                record.done      = nil
                record.completed = nil" \
    "a migration deletes an account-wide flag nothing rewrites"

mutate "Modules/Loremaster.lua" \
    "        if type(record) == \"table\" and record.completed == nil then
            Loremaster.Scan()

            return
        end" \
    "        if false then
            return
        end" \
    "a store missing a field is never rebuilt"

mutate "UI.lua" \
    "        local results = CN.Recommend(UI.listLimit,
            not (window and window:IsShown()))" \
    "        local results = CN.Recommend(UI.listLimit)" \
    "a text search starts session clocks on twelve objectives"

mutate "UI.lua" \
    "        if button.GetFontString then
            CN.AdoptLabel(button:GetFontString(), \"CAPTION\")
        end" \
    "        if false then
            CN.AdoptLabel(nil, \"CAPTION\")
        end" \
    "the tab captions ignore the text-size setting"

mutate "UI.lua" \
    "        if check.Fit then
            check.Fit()
        end" \
    "        if false then
            check.Fit()
        end" \
    "a checkbox hit area is measured once and never again"

mutate "Modules/Quests.lua" \
    "        for _, pin in ipairs(pins) do
            if pin.x and pin.y then
                sample = pin
                break
            end
        end" \
    "        sample = pins[1]" \
    "a zone is priced from a pin that has no position"

############################################################
# 0.69.0
############################################################

mutate "Modules/Loremaster.lua" \
    "CN:RegisterEvent(\"CRITERIA_UPDATE\", function()
    CN.Debounce(\"Loremaster.zone\", 2, function()
        local ok, moved = pcall(Loremaster.RefreshCurrentZone)

        if ok and moved then
            CN.InvalidateProvider(\"Loremaster\")
        end
    end)
end)" \
    "" \
    "handing a quest in leaves the journey saying what it said at login"

mutate "Modules/Loremaster.lua" \
    "    if not criteria or criteria <= 0 then
        return learned
    end

    local key = CN.characterKey or CN.GetCharacterKey()" \
    "    local key = CN.characterKey or CN.GetCharacterKey()" \
    "a refusal from the criteria API wipes the zone row"

mutate "Scoring.lua" \
    "    if not objective.travelCosted then
        return nil
    end" \
    "    if false then
        return nil
    end" \
    "a journey the model could not cost is treated as twenty minutes"

mutate "Scoring.lua" \
    "        if needed and objective.expiresIn < needed then
            composed[#composed + 1] =" \
    "        if false then
            composed[#composed + 1] =" \
    "a deadline that counts for nothing is never explained"

mutate "Modules/Loremaster.lua" \
    "    if not CN.Account(\"loremasterScans\")[key] then
        Loremaster.Scan()

        return
    end" \
    "    if false then
        return
    end" \
    "an alt is locked out of the repair by the character before it"

mutate "Database.lua" \
    "    [21] = function()" \
    "    [21] = function(db) db.account.loremaster = {}" \
    "a migration throws away every alt's progress to repair a flag"

mutate "Modules/Alts.lua" \
    "    for _, objective in ipairs(CN.Recommend(Alts.considered, true) or {}) do" \
    "    for _, objective in ipairs(CN.Recommend(Alts.considered) or {}) do" \
    "asking which alt should do something counts as offering it"

mutate "Modules/Goals.lua" \
    "            if record.sightings then
                step(\"Seen \" .. record.sightings .. \" time\"" \
    "            if true then
                step(\"Seen \" .. (record.sightings or 1) .. \" time\"" \
    "a rare with no stored count is reported as seen once"

mutate "UI.lua" \
    "            table.insert(parts,
                (CN.L[hit.tab] or hit.tab) .. \" (\" .. hit.count .. \")\")" \
    "            table.insert(parts, hit.tab .. \" (\" .. hit.count .. \")\")" \
    "the search names tabs in English beside a translated tab strip"

############################################################
# 0.70.0
############################################################

mutate "Modules/Loremaster.lua" \
    "    local earned = Blizzard.IsAchievementEarned and Blizzard.IsAchievementEarned(id)

    if earned ~= nil then
        record.completed = earned
    end" \
    "    record.completed = (done >= criteria) and true or false" \
    "an alt part-way through a zone un-earns the account's achievement"

# RETIRED IN 0.72.0. This mutated `best.mapID = mapID` -- the persisted map
# stamp, which 0.72.0 removed outright because the value came from
# `GetBestMapForUnit` and was therefore the city map indoors. Its successor is
# "every criteria update walks the whole achievement store again", below,
# which mutates the session index that replaced it.

mutate "Modules/Loremaster.lua" \
    "                if criteria and criteria > 0 then
                    held.criteria = criteria" \
    "                if true then
                    held.criteria = criteria" \
    "a scan at a cold moment empties the whole journey"

mutate "Scoring.lua" \
    "    if seconds >= ceiling then
        return nil
    end" \
    "    if false then
        return nil
    end" \
    "a clamped journey is printed as though it were a duration"

mutate "Modules/Session.lua" \
    "    local travelSeconds = CN.SecondsNeeded and CN.SecondsNeeded(objective)" \
    "    local travelSeconds = objective.travelCost
        and objective.travelCost * CN.secondsPerCostPoint" \
    "an invented journey is subtracted from a measured span"

mutate "Modules/Quests.lua" \
    "                if not quiet then
                    Quests.RememberOffer(poi)
                end" \
    "                Quests.RememberOffer(poi)" \
    "a text search writes quest pins to disk"

mutate "Modules/Reputations.lua" \
    "        local name = Reputations.NameOf(id)" \
    "        local name = NameStore()[id]" \
    "a faction cannot be found by name after a language change"

############################################################
# 0.71.0
############################################################

mutate "Providers/BlizzardCollections.lua" \
    "    local ok, id, _, _, completed = pcall(GetAchievementInfo, achievementID)" \
    "    local ok, _, _, _, completed = pcall(GetAchievementInfo, achievementID)
    local id = true" \
    "an achievement the client cannot answer about is reported unearned"

mutate "Modules/Loremaster.lua" \
    "        return scanned, 0
    end" \
    "    end" \
    "a scan that measured nothing records itself as done"

mutate "Modules/Loremaster.lua" \
    "        return string.sub(candidate, -(#needle + 1)) == (\" \" .. needle)" \
    "        return string.find(candidate, needle, 1, true) ~= nil" \
    "the zone match is an unanchored substring again"

mutate "Modules/Loremaster.lua" \
    "        zone = GetZoneText and GetZoneText()" \
    "        zone = Blizzard.GetMapName(CN.GetPlayerPosition())" \
    "standing in a city finds no zone at all"

mutate "Modules/Loremaster.lua" \
    "        if not record.completed and (record.criteria or 0) > 0
            and done < record.criteria then" \
    "        if not record.completed and (record.criteria or 0) > 0 then" \
    "a zone with nothing left is the closest thing to finishing"

mutate "Scoring.lua" \
    "    \"travelCost\", \"travelCosted\", \"mapID\", \"x\", \"y\"," \
    "    \"travelCost\", \"mapID\", \"x\", \"y\"," \
    "a reused candidate carries a stale answer about its own journey"

mutate "Modules/Travel.lua" \
    "        return cost, confident and true or false" \
    "        return cost, true" \
    "a route the model is unsure of is reported as measured"

mutate "Modules/Reputations.lua" \
    "            name            = Reputations.NameOf(record.factionID)," \
    "            name            = record.name," \
    "a faction is listed under the language that last scanned it"

# ---- 0.72.0 ----

mutate "Modules/Loremaster.lua" \
    "    local matches = held and held.zone == needle and held.matches or nil" \
    "    local matches = nil" \
    "every criteria update walks the whole achievement store again"

mutate "Modules/Loremaster.lua" \
    "            zoneIndex[slot] = { zone = needle, matches = matches }" \
    "            if #matches > 0 then zoneIndex[slot] = { zone = needle, matches = matches } end" \
    "a zone with no achievement pays the full walk on every event"

mutate "Modules/Loremaster.lua" \
    "    local rows = Loremaster.Closest(50, 12)" \
    "    local rows = Loremaster.Closest(50)" \
    "a zone never begun cannot be recommended to a player who has begun many"

mutate "Modules/Loremaster.lua" \
    "        row.name     = Loremaster.NameOf(row.id, row.record)" \
    "        row.name     = tostring(row.id)" \
    "the zone list shows achievement ids instead of names"

mutate "Modules/Loremaster.lua" \
    "        return scanned, 0" \
    "        return scanned, 1" \
    "a scan that recorded nothing reports a count as though it had"

mutate "Modules/Session.lua" \
    "        travelKnown = cost == nil or cost == 0
            or (objective.mapID == nil
                and objective.x == nil and objective.y == nil)" \
    "        travelKnown = cost == nil or cost == 0" \
    "the planner can never learn how long an instance takes"

mutate "Modules/Session.lua" \
    "        travelKnown = cost == nil or cost == 0
            or (objective.mapID == nil
                and objective.x == nil and objective.y == nil)" \
    "        travelKnown = true" \
    "a journey the model stopped counting is subtracted from a measured span"

mutate "Scoring.lua" \
    "    if CN.MinimumSecondsNeeded(objective) then" \
    "    if false then" \
    "the farthest objectives show no distance at all, reading as unknown"

mutate "Modules/Reputations.lua" \
    "        return record.friendshipStanding" \
    "        return nil" \
    "a friendship rank is lost, and it is the one the client will not re-supply"

mutate "Modules/Quests.lua" \
    "    local store = Remembered()

    if store[questID] then
        store[questID] = nil" \
    "    local store = Remembered()

    if false then
        store[questID] = nil" \
    "a quest handed in is left on the map until something else prunes it"

mutate "Modules/Exploration.lua" \
    "    return before ~= done" \
    "    return true" \
    "every criteria update throws away the exploration provider's cached rows"

# ---- 0.73.0 ----

mutate "Providers/BlizzardWorld.lua" \
    "        if (info.mapType or 0) == Blizzard.zoneMapType then
            return current, true
        end" \
    "        if true then
            return current, true
        end" \
    "the zone a player is in is the room they are standing in again"

# RETIRED IN 0.74.0. Both mutated the continent comparison, which was inert:
# on retail a quest category is an EXPANSION ("Warlords of Draenor"), never a
# continent ("Draenor"), so neither side ever matched and the branch could not
# fire in any case it was written for. Its successors are the two evidence
# mutations below.

mutate "Modules/Loremaster.lua" \
    "        if record and (not belongsTo or belongsTo == here)" \
    "        if record" \
    "standing in one Nagrand shows progress for the other one"

mutate "Modules/Loremaster.lua" \
    "    if movers ~= 1 then
        return false
    end" \
    "    if movers < 1 then
        return false
    end" \
    "two same-named zones moving at once teaches the addon a guess"

mutate "Modules/Loremaster.lua" \
    "        local decisive = (named == rows)" \
    "        local decisive = named > 0" \
    "a zone walked while the client was half awake is kept for the session"

mutate "Modules/Loremaster.lua" \
    "    local fresh = math.min(#untouched, freshShare or 0)" \
    "    local fresh = math.min(#untouched, freshShare or math.floor(limit / 4))" \
    "a list headed closest to finished holds zones never begun"

mutate "Modules/Loremaster.lua" \
    "    local before = record and (Loremaster.DoneFor(record) or 0)" \
    "    local before = record and record.progress
        and record.progress[CN.characterKey or CN.GetCharacterKey()]" \
    "the first sight of a zone is reported as a change to it"

mutate "Modules/Loremaster.lua" \
    "        local named = Blizzard.GetMapName(mapID)

        if not named or named == \"\" then
            return nil
        end" \
    "        local named = Blizzard.GetMapName(mapID)" \
    "asking about an unknown map answers about the zone you are standing in"

mutate "Modules/Session.lua" \
    "            or (objective.mapID == nil
                and objective.x == nil and objective.y == nil)" \
    "            or not (objective.mapID and objective.x and objective.y)" \
    "a quest whose pin has not resolved teaches the planner a zero journey"

mutate "Database.lua" \
    "                        record.friendshipStanding = record.standing" \
    "                        record.friendshipStanding = nil" \
    "upgrading destroys every alt's friendship rank"

mutate "Modules/Setup.lua" \
    "        and (measured == 0 or measured == false or measured == nil) then" \
    "        and false then" \
    "setup reports a clean bill for scans that recorded nothing"

mutate "Modules/Setup.lua" \
    "        and (measured == 0 or measured == false or measured == nil) then" \
    "        and (measured == 0) then" \
    "a boolean refusal from a scan reads as a success"

mutate "Modules/Achievements.lua" \
    "        if crossed then
            CN.InvalidateProvider(\"Achievements\")
        end" \
    "        if false then
            CN.InvalidateProvider(\"Achievements\")
        end" \
    "an achievement that became nearly done does not reach the ranking"

# RETIRED IN 0.74.0. This mutated the pin removal 0.73.0 added to
# QUEST_ACCEPTED, which 0.74.0 reverted: `Remembered()` is account-wide, so
# one character picking a quest up erased the location every alt still needed.
# Its successor is "logging in on a main erases the quest pins every alt still
# needs", below.

mutate "Scoring.lua" \
    "        return text and (\"over \" .. text) or nil, false, text" \
    "        return text and (\"over \" .. text) or nil, false" \
    "the tooltip parses the far-away figure back out of its own sentence"

mutate "Modules/Harvest.lua" \
    "    if not questID then
        return
    end

    table.insert(recentTurnIns, 1, { questID = questID, at = time() })" \
    "    table.insert(recentTurnIns, 1, { questID = questID, at = time() })" \
    "a turn-in the client did not name throws on the next quest accepted"

# ---- 0.74.0 ----

mutate "Modules/Loremaster.lua" \
    "            local heldName = (live and live ~= \"\" and live)
                or Loremaster.NameOf(id, record)" \
    "            local heldName = Loremaster.NameOf(id, record)" \
    "the zone walk asks the client for every name twice"

mutate "Modules/Loremaster.lua" \
    "    local slot = tostring(key) .. \"|\" .. needle" \
    "    local slot = tostring(key)" \
    "a lookup for a room inside a zone blanks the zone"

mutate "Modules/Loremaster.lua" \
    "        if Loremaster.coldAttempts <= Loremaster.maximumColdAttempts
            and C_Timer and C_Timer.After then" \
    "        if false then" \
    "a scan the game was not ready for leaves the tab empty until logout"

mutate "Modules/Loremaster.lua" \
    "        if Loremaster.coldAttempts <= Loremaster.maximumColdAttempts
            and C_Timer and C_Timer.After then" \
    "        if C_Timer and C_Timer.After then" \
    "a client that will never answer is asked forever"

# RETIRED IN 0.75.0. This mutated the counter reset at the END of a
# successful scan. 0.75.0 resets at the START of any scan the player asked
# for, which is the property that matters and is mutated by "three cold scans
# spend the session's retries and the rest are silent", below.

mutate "Modules/Loremaster.lua" \
    "    for index = 1, math.min(#untouched, fresh, limit - #ordered) do" \
    "    for index = 1, math.min(#untouched, limit - #ordered) do" \
    "a list headed closest to finished fills its tail with zones never begun"

mutate "Modules/Quests.lua" \
    "        if Quests.IsCompletedOnAccount(questID) then" \
    "        if Quests.IsCompletedOnAccount(questID)
            or Blizzard.IsQuestInLog(questID) then" \
    "logging in on a main erases the quest pins every alt still needs"

mutate "Modules/Quests.lua" \
    "    if not Quests.IsCompletedOnAccount(questID) then
        return
    end" \
    "    if false then
        return
    end" \
    "one character handing a quest in erases where it is for the others"

mutate "Modules/Exploration.lua" \
    "    if matched and mapID and count == 1 then" \
    "    if matched and mapID then" \
    "the wrong Nagrand is bound to this zone and written through"

mutate "Modules/Exploration.lua" \
    "    local mapID = Blizzard.ZoneMapID
        and Blizzard.ZoneMapID(CN.GetPlayerPosition())" \
    "    local mapID = CN.GetPlayerPosition()" \
    "exploration learns the building it was standing in, not the zone"

mutate "Modules/Exploration.lua" \
    "            if not matchedID or achievementID < matchedID then" \
    "            if not matchedID then" \
    "which zone achievement is answered with depends on hash order"

mutate "Providers/BlizzardWorld.lua" \
    "    local held = zoneOf[mapID]

    if held ~= nil then
        return held
    end" \
    "    local held = nil

    if held ~= nil then
        return held
    end" \
    "the map ancestry is walked again for every question about it"

mutate "Modules/Achievements.lua" \
    "    local remaining = criteria - (Achievements.DoneFor(record) or 0)

    return remaining > 0" \
    "    local remaining = criteria - (record.done or 0)

    return remaining > 0" \
    "an alt is told it is two criteria from the main's progress"

mutate "Modules/Achievements.lua" \
    "    record.progress = record.progress or {}
    record.progress[key] = done" \
    "    record.done = done" \
    "whichever character scanned last owns every achievement's progress"

mutate "Modules/Setup.lua" \
    "        return nil, \"the game was not ready yet\"" \
    "        return false, \"the game was not ready yet\"" \
    "a client still loading is reported to the player as a defect"

mutate "Modules/Setup.lua" \
    "                if failed + notReady < #results and notReady == 0 then" \
    "                if failed + notReady < #results then" \
    "a setup run the game was not ready for silences the reminder forever"

mutate "Database.lua" \
    "        if lost > 0 then" \
    "        if false then" \
    "the ranks a defect destroyed are never mentioned to the player"

mutate "Modules/Errors.lua" \
    "        if type(notice) == \"table\" and not notice.seen and notice.text then" \
    "        if type(notice) == \"table\" and notice.text then" \
    "a one-time notice is shown at every single login"

# ---- 0.75.0 ----

# RE-ANCHORED IN 0.89.0: the two arms this sat inside were dead once the zero
# case moved out of the loop, so the write is one level shallower.
mutate "Modules/Achievements.lua" \
    "                        held.criteria = criteria

                        Achievements.NoteProgress(held, done)" \
    "                        held.criteria = criteria

                        held.done = done" \
    "the achievement scan writes a figure every other character inherits"

mutate "Modules/Achievements.lua" \
    "    for achievementID, record in pairs(store) do
        local categoryID = type(record) == \"table\" and record.categoryID

        if not seen[achievementID] and categoryID
            and answeringCategories[categoryID] then

            store[achievementID] = nil
        end
    end" \
    "    for achievementID in pairs(store) do
        store[achievementID] = nil
    end" \
    "one character's achievement scan destroys every other character's"

mutate "Modules/Achievements.lua" \
    "        local aLeft = left[a] or 0
        local bLeft = left[b] or 0" \
    "        local aLeft = a.criteria - (a.done or 0)
        local bLeft = b.criteria - (b.done or 0)" \
    "the closest list is ordered by a different character's numbers"

mutate "Modules/Achievements.lua" \
    "    CN.Account(\"achievementScans\")[CN.characterKey or CN.GetCharacterKey()] =
        time()" \
    "    local unused = 0" \
    "an alt is never prompted to read its own achievement progress"

mutate "Modules/Loremaster.lua" \
    "        local before = record and record.progress
            and record.progress[characterKey]

        if before ~= nil then" \
    "        local before = Loremaster.DoneFor(record) or 0

        if true then" \
    "a criteria update anywhere binds the wrong one of two same-named zones"

mutate "Modules/Loremaster.lua" \
    "                if done > before then" \
    "                if done ~= before then" \
    "progress going backwards is taken as evidence about a zone"

# RETIRED IN 0.76.0. This mutated the "provisionally retired" bookkeeping,
# which existed only because `Loremaster.Scan` never deleted a row for an
# achievement the game had retired. 0.76.0 deletes the row, so the exact test
# is reachable again and the whole mechanism is gone. Its successor is
# "a retired achievement keeps its row and the client never names it again",
# below.

mutate "Modules/Loremaster.lua" \
    "    for achievementID in pairs(bindings) do
        if not store[achievementID] then
            bindings[achievementID] = nil
        end
    end" \
    "    for achievementID in pairs(bindings) do
        if false then
            bindings[achievementID] = nil
        end
    end" \
    "a zone stays bound to an achievement the game has retired"

mutate "Modules/Loremaster.lua" \
    "    if not fromRetry then
        Loremaster.coldAttempts = 0
    end" \
    "    if false then
        Loremaster.coldAttempts = 0
    end" \
    "three cold scans spend the session's retries and the rest are silent"

mutate "Providers/BlizzardWorld.lua" \
    "    if resolved then
        zoneOf[mapID] = answer
    end" \
    "    zoneOf[mapID] = answer" \
    "one refused map lookup pins a building to itself for the session"

mutate "Modules/Errors.lua" \
    "            if rejected > 0 or shown > 0 then" \
    "            if rejected > 0 then" \
    "the errors command contradicts itself two lines apart"

mutate "Modules/Errors.lua" \
    "                if type(notice) == \"table\" and notice.seen then
                    table.remove(notices, index)" \
    "                if type(notice) == \"table\" then
                    table.remove(notices, index)" \
    "a notice the player has not read yet is discarded by /cn errors clear"

mutate "Database.lua" \
    "            if key ~= mine and type(character) == \"table\"" \
    "            if type(character) == \"table\"" \
    "the loss notice counts rows about to be restored on this character"

mutate "Modules/Goals.lua" \
    "            local done = (achievements and achievements.DoneFor
                and achievements.DoneFor(record)) or 0" \
    "            local done = record.done or 0" \
    "a pinned achievement reports another character's criteria"

# ---- 0.76.0 ----

mutate "Modules/Loremaster.lua" \
    "    for id, record in pairs(store) do
        local categoryID = type(record) == \"table\" and record.categoryID

        if not seen[id] and categoryID and answeringCategories[categoryID] then
            store[id] = nil
        end
    end" \
    "    for id, record in pairs(store) do
        local categoryID = record

        if false then
            store[id] = nil
        end
    end" \
    "a retired achievement keeps its row and the client never names it again"

mutate "Modules/Loremaster.lua" \
    "                record.progress[characterKey] = done" \
    "                local unused = done" \
    "a losing candidate's baseline goes stale and nothing can be learned"

mutate "Modules/Loremaster.lua" \
    "    local before = record and (Loremaster.DoneFor(record) or 0)

    local learned = LearnZoneBinding(matches, zoneMap)" \
    "    local learned = LearnZoneBinding(matches, zoneMap)

    local before = record and (Loremaster.DoneFor(record) or 0)" \
    "a turn-in never reports that it moved anything, ever again"

mutate "Modules/Loremaster.lua" \
    "    if not unknown then
        return false
    end" \
    "    if false then
        return false
    end" \
    "the learning sweep runs in every zone on every criteria burst"

mutate "Modules/Loremaster.lua" \
    "    if learnedAt[key] and now - learnedAt[key] < Loremaster.learnIntervalSeconds then
        return false
    end" \
    "    if false then
        return false
    end" \
    "a zone that has nothing to teach is asked again every two seconds"

mutate "Modules/Loremaster.lua" \
    "                        Print(\"Zone progress read: \" .. got .. \" of \"" \
    "                        Print(\"Zone progress read: \" .. retried .. \" of \"" \
    "the retry announces the rows it walked past, not the rows it read"

mutate "Modules/Achievements.lua" \
    "                answeringCategories[categoryID] = true" \
    "                local unusedCategory = categoryID" \
    "an alt's scan deletes every achievement row the main had progress on"

mutate "Modules/Achievements.lua" \
    "    if answered == 0 then" \
    "    if false then" \
    "a cold achievement scan prunes the store and stamps itself done"

# RE-ANCHORED IN 0.89.0: the guard moved up a level. A zero never reaches the
# branch that writes a count; it is held back until the sweep has proved the
# criteria API answers, and the "never overwrite a stored count" test lives in
# the loop that runs after that guard.
mutate "Modules/Achievements.lua" \
    "        if held.criteria == nil then
            held.criteria = 0" \
    "        if true then
            held.criteria = 0" \
    "a client that answers nothing overwrites real criteria with zero"

mutate "Modules/Setup.lua" \
    "local function StepDoneHere(step)
    if step.perCharacter then" \
    "local function StepDoneHere(step)
    if false then" \
    "an alt is never asked to read its own progress"

mutate "Modules/Setup.lua" \
    "function Setup.StampFor(step)
    if type(step) ~= \"table\" then
        return nil
    end

    if step.perCharacter then" \
    "function Setup.StampFor(step)
    if type(step) ~= \"table\" then
        return nil
    end

    if false then" \
    "a per-character source is dated from the account-wide stamp"

mutate "Modules/Setup.lua" \
    "        if step.perCharacter and not StepDoneHere(step) then
            return false
        end" \
    "        if false then
            return false
        end" \
    "a main that ran setup silences the reminder for every alt"

mutate "Modules/Errors.lua" \
    "                notice.seen = true

                shown = shown + 1" \
    "                shown = shown + 1" \
    "a notice read from the command cannot be cleared by the command"

mutate "Database.lua" \
    "        if db.friendshipRanksCarried then
            return
        end" \
    "        if false then
            return
        end" \
    "a database that lost nothing is accused of losing something"

mutate "Database.lua" \
    "        if blanked > 0 then" \
    "        if false then" \
    "achievement recommendations vanish and nothing says why"

mutate "Modules/Loremaster.lua" \
    "            for _, zoneMapID in pairs(Loremaster.Bindings()) do
                zones[zoneMapID] = true
            end" \
    "            for achievementID in pairs(Loremaster.Bindings()) do
                zones[achievementID] = true
            end" \
    "forgetting one zone reports having forgotten three"

# ---- 0.77.0 ----

mutate "Modules/Loremaster.lua" \
    "        if not seen[id] and categoryID and answeringCategories[categoryID] then" \
    "        if not seen[id] then" \
    "a half-warm scan deletes every zone row in the categories that stayed quiet"

mutate "Modules/Achievements.lua" \
    "        if not seen[achievementID] and categoryID
            and answeringCategories[categoryID] then" \
    "        if not seen[achievementID] then" \
    "a half-warm scan deletes every achievement row in the quiet categories"

mutate "Design.lua" \
    "    local point, _, relativePoint, x, y = frame:GetPoint()" \
    "    local point, _, _, x, y = frame:GetPoint()
    local relativePoint = point" \
    "a frame the player moved comes back a screen away from where they left it"

mutate "Design.lua" \
    "    frame:ClearAllPoints()

    frame:SetPoint(
        placement.point or \"CENTER\"," \
    "    frame:SetPoint(
        placement.point or \"CENTER\"," \
    "a frame restored twice accumulates anchors instead of moving"

mutate "Design.lua" \
    "    close:RegisterForDrag(\"LeftButton\")" \
    "    local unusedDrag = \"LeftButton\"" \
    "the corner with the x in it is a dead zone for dragging"

mutate "Design.lua" \
    "    close:SetScript(\"OnClick\", function()
        if onClose then
            onClose()
        end
    end)" \
    "    close:SetScript(\"OnClick\", function()
    end)" \
    "the x on a frame drawn over the world does nothing"

mutate "Core.lua" \
    "function CN.SortKey(text)
    text = CN.Strip(text)" \
    "function CN.SortKey(text)
    text = tostring(text or \"\")" \
    "a search for a colour code matches every row on every tab"

mutate "UI/List.lua" \
    "        local haystack = CN.SearchKey(entry.text, entry.value)" \
    "        local haystack = CN.SortKey(entry.text)" \
    "a tab counted as matching says nothing here matches"

mutate "UI.lua" \
    "        local reset = string.lower(CN.Trim(args or \"\")) == \"reset\"

        if frame and reset then" \
    "        local reset = true

        if frame and reset then" \
    "running the window diagnostic throws away the saved window position"

mutate "UI.lua" \
    "        if not UI.subscribedRefreshEvents[event] then
            UI.subscribedRefreshEvents[event] = true

            CN:RegisterEvent(event, function()
                UI.RequestRefresh()
            end)
        end" \
    "        CN:RegisterEvent(event, function()
            UI.RequestRefresh()
        end)" \
    "every late provider adds another forty redraw handlers"

mutate "Scoring.lua" \
    "    -- stopped building this per objective in the first place.
    local w = EffectiveWeights(mode, profile)" \
    "    local w = {}" \
    "the explanation of a score is not the score"

mutate "Modules/Inventory.lua" \
    "        local ok, _, _, _, _, _, classID =
            pcall(C_Item.GetItemInfoInstant, item.itemID)" \
    "        local ok, _, _, _, _, classID =
            pcall(C_Item.GetItemInfoInstant, item.itemID)" \
    "a recipe in your bags is never found"

mutate "Modules/Inventory.lua" \
    "            return CN.Ago(store and store.scannedAt) or \"never\"" \
    "            return math.floor(math.max(0, time() - store.scannedAt) / 3600)" \
    "a bank read a fortnight ago is described as 336 hours"

mutate "Modules/Travel.lua" \
    "                runSpeed, runMeasured = session.Speed(false)" \
    "                runSpeed, runMeasured = session.Speed()" \
    "running the whole way is quoted at flying speed"

mutate "Routing.lua" \
    "    if why then
        CN.PrintLine(CN.Muted(tostring(why)))
    end

    return true
end" \
    "    if false then
        CN.PrintLine(CN.Muted(tostring(why)))
    end

    return true
end" \
    "a waypoint with no map pin is reported as a waypoint with one"

mutate "Routing.lua" \
    "        CN.Debounce(\"Routing.autoAdvance.\" .. event, 2, function()
            CN.AutoAdvance(event)
        end)" \
    "        CN.AutoAdvance(event)" \
    "every minimap vignette rescans the whole candidate list"

# RETIRED IN 0.78.0: the whole tail is a translated key now, and its
# successor is "a translated headline is followed by untranslated prose",
# which mutates the key lookup back into the hardcoded English.

# ---- 0.78.0 ----

mutate "Core.lua" \
    "    return CN.SortKey(text) .. \" \" .. string.lower(CN.Strip(value))" \
    "    return CN.SortKey(text) .. \" \" .. CN.SortKey(value)" \
    "filtering the window by any number matches nothing"

mutate "Database.lua" \
    "            Reset(db.settings, key)" \
    "            Reset(db.account and db.account.settings, key)" \
    "the frame reset looks in a table that does not exist"

mutate "Database.lua" \
    "        if type(db.account) == \"table\"
            and type(db.account.progress) == \"table\" then

            db.account.progress.total = nil
        end" \
    "        if false then
            db.account.progress.total = nil
        end" \
    "a count the client already keeps stays on disk for ever"

mutate "Modules/Travel.lua" \
    "                    and CN.WithConfidence(onFoot,
                        CN.ConfidenceFor(runMeasured))" \
    "                    and CN.WithConfidence(onFoot, runMeasured)" \
    "an estimated walking time is printed as a measured one"

mutate "Routing.lua" \
    "    return true, type(why) == \"string\" and why or nil" \
    "    if why then
        CN.PrintLine(CN.Muted(tostring(why)))
    end

    return true" \
    "a caveat prints above the headline it belongs under"

mutate "Routing.lua" \
    "        if not CN.IsAutoWaypointEnabled() then
            return
        end" \
    "        if false then
            return
        end" \
    "a player with auto-waypoint off pays for every minimap vignette"

mutate "Routing.lua" \
    "        if not throttled then
            CN.AutoAdvance(event)
            return
        end" \
    "        if false then
            CN.AutoAdvance(event)
            return
        end" \
    "a turn-in during a vignette burst is answered two seconds late"

mutate "Modules/Navigation.lua" \
    "        if not Navigation.IsArrowEnabled() then
            Navigation.StopTicker()
        end" \
    "        if false then
            Navigation.StopTicker()
        end" \
    "turning the arrow off leaves it redrawing ten times a second"

mutate "Modules/Rares.lua" \
    "            isDead     = vignette.isDead and true or false," \
    "            isDead     = nil," \
    "a rare somebody else killed is recommended for ever"

mutate "Modules/Rares.lua" \
    "    local active = Rares.GetAll(mapID)" \
    "    local active = Rares.GetActive(mapID)" \
    "the learning pass never sees a vignette the client flagged dead"

mutate "Modules/Rares.lua" \
    "        if not vignette.isDead then
            table.insert(active, vignette)
        end" \
    "        table.insert(active, vignette)" \
    "a dead rare is offered as something to go and kill"

mutate "Modules/Rares.lua" \
    "CN.RegisterEligibilityChecker(CN.objectiveTypes.TREASURE, Eligibility)" \
    "local unusedChecker = Eligibility" \
    "half of what this module offers cannot be explained"

mutate "Modules/Vault.lua" \
    "    if Blizzard.HasAvailableWeeklyRewards()
        and not CN.IsIgnored(CN.objectiveTypes.CURRENCY, \"vault\")
        and not CN.IsDeferred(CN.objectiveTypes.CURRENCY, \"vault\") then" \
    "    if Blizzard.HasAvailableWeeklyRewards() then" \
    "deferring the vault reward says it worked and it did not"

mutate "Modules/Orders.lua" \
    "    if Orders.HasClaimable()
        and not CN.IsIgnored(CN.objectiveTypes.RECIPE, \"claim\")
        and not CN.IsDeferred(CN.objectiveTypes.RECIPE, \"claim\") then" \
    "    if Orders.HasClaimable() then" \
    "deferring a finished crafting order says it worked and it did not"

mutate "Modules/Currencies.lua" \
    "volatile = true, cooldown = 30 })" \
    "volatile = true })" \
    "every coin picked up rebuilds the currency candidates"

mutate "Modules/Currencies.lua" \
    "            if #weekly > 8 then" \
    "            if false then" \
    "a list of fourteen announces fourteen and shows eight"

mutate "Modules/Follow.lua" \
    "        local tail = total == 1
            and CN.L[\"All 1 stop done.\"]
            or string.format(CN.L[\"All %d stops done.\"], total)" \
    "        local tail = CN.Count(total, \"stop\") .. \", all done.\"" \
    "a translated headline is followed by untranslated prose"

mutate "Modules/Follow.lua" \
    "    frame.header:SetPoint(\"TOPRIGHT\", -(inset + CN.CLOSE_WIDTH), -CN.SPACE.S)" \
    "    local unusedStop = CN.CLOSE_WIDTH" \
    "the right end of the follow header is a click that stops the route"

# ---- 0.79.0 ----

mutate "Modules/Chase.lua" \
    "        return CN.SetWaypointAndSay(step.mapID, step.x, step.y, step.text,
            \"Next step: \" .. tostring(step.text or \"here\"))" \
    "        return CN.SetWaypoint(step.mapID, step.x, step.y, step.text)" \
    "the Goals tab's next-step button places a waypoint and says nothing"

mutate "Modules/Follow.lua" \
    "        CN.SetWaypointAndSay(hub.mapID, hub.x, hub.y, label, false)" \
    "        CN.SetWaypoint(hub.mapID, hub.x, hub.y, label)" \
    "a hub advance the client refused reports nothing at all"

mutate "Routing.lua" \
    "    if headline == false then" \
    "    if false then" \
    "a caller that does not narrate is also not told the pin was refused"

mutate "Modules/Filters.lua" \
    "    return CN.TypeBadge(objectiveType) .. \" \" .. tostring(id)" \
    "    return tostring(objectiveType) .. \" \" .. tostring(id)" \
    "an odd id is described with the internal enum"

mutate "Scoring.lua" \
    "    return math.abs(left - right) <= DEADLINE_TOLERANCE" \
    "    return left == right" \
    "a countdown ticking down makes every row a different row"

mutate "Core.lua" \
    "    return CN.SortKey(text) .. \" \" .. string.lower(CN.Strip(value))" \
    "    return CN.SortKey(text)" \
    "the window cannot be filtered by anything in the value column"

mutate "Modules/Navigation.lua" \
    "    if not Navigation.IsTicking() then
        Navigation.StartTicker()
    end" \
    "    if false then
        Navigation.StartTicker()
    end" \
    "turning the arrow on leaves it frozen where it was"

mutate "Modules/Rares.lua" \
    "        return states.UNKNOWN, \"Not up right now\", record.name" \
    "        return states.AVAILABLE, nil, record.name" \
    "a rare the client is not reporting is offered as one to go and kill"

# ---- 0.80.0 ----

mutate "Modules/Group.lua" \
    "    if inside and Group.InGroup()
        and (kind == \"party\" or kind == \"raid\" or kind == \"scenario\") then" \
    "    if inside
        and (kind == \"party\" or kind == \"raid\" or kind == \"scenario\") then" \
    "soloing an old raid buries the mount you went in for"

mutate "Modules/Group.lua" \
    "    local where = (kind == \"raid\" and \"a raid\" or \"an instance\")" \
    "    local where = (kind == \"raid\" and \"raid\" or \"instance\")" \
    "/cn situation says you are in a instance"

mutate "Modules/Professions.lua" \
    "function Professions.RecipeForItem(itemName)" \
    "function Professions.RecipeForItem(itemName)
    if RecipeNames()[itemName] then
        return itemName
    end" \
    "an item id is looked up in a table of recipe ids"

mutate "Modules/Instances.lua" \
    "        dropCache[name] = { at = time() }" \
    "        dropCache[name] = nil" \
    "a mouseover of a non-drop re-searches the whole journal"

mutate "Modules/Instances.lua" \
    "CN:RegisterEvent(\"PLAYER_ENTERING_WORLD\", function()
    Instances.ForgetDrops()
end)" \
    "" \
    "nothing ever clears a cached journal answer"

mutate "Modules/Broker.lua" \
    "        CN.Debounce(\"Broker.alerts\", 1, function()" \
    "        do" \
    "every minimap vignette runs a full rare-alert sweep"

mutate "Locale.lua" \
    "        if stats.missing > 0 and not english then" \
    "        if stats.missing > 0 then" \
    "an English client is told to translate English"

mutate "Modules/Appearances.lua" \
    "            total      = category.total,
        }" \
    "            total      = category.total,
            lastSeen   = time(),
        }" \
    "every appearance scan writes a timestamp nothing reads"

# RE-ANCHORED IN 0.89.0: migration 33 sweeps the exploration store with the
# same loop, so the guard needs the line after it to stay unique.
mutate "Database.lua" \
    "            if type(record) == \"table\" and record.lastSeen ~= nil then
                record.lastSeen = nil
                dropped = dropped + 1" \
    "            if false then
                record.lastSeen = nil
                dropped = dropped + 1" \
    "the appearance timestamps already on disk stay there"

mutate "Database.lua" \
    "        local store = db.account and db.account.exploration" \
    "        local store = db.account and db.account.mounts" \
    "the exploration timestamps already on disk stay there"

# ---- 0.81.0 ----

mutate "Modules/Group.lua" \
    "    if not Group.InsideInstance() then
        return false
    end

    local here = select(1, CN.GetPlayerPosition())" \
    "    if true then
        return false
    end

    local here = select(1, CN.GetPlayerPosition())" \
    "a solo instance run offers you a world quest outside"

mutate "Modules/Group.lua" \
    "    local walk = CN.Blizzard and CN.Blizzard.InstanceMapID" \
    "    local walk = CN.Blizzard and CN.Blizzard.ZoneMapID" \
    "the world quest outside the door counts as being in here with you"

mutate "Modules/Group.lua" \
    "    local here = select(1, CN.GetPlayerPosition())

    if not here then
        return false
    end" \
    "    local here = select(1, CN.GetPlayerPosition())

    if not here then
        return true
    end" \
    "a loading screen ranks down everything the addon knows where to find"

mutate "Modules/Group.lua" \
    "    if not outside then
        CN.ClearAdjusterReason(objective, \"groupOutside\")
    end" \
    "    if not Group.InsideInstance() then
        CN.ClearAdjusterReason(objective, \"groupOutside\")
    end" \
    "the outside sentence outlives the multiplier that put it there"

mutate "Modules/Session.lua" \
    "    if situation == \"dead\" or inside then" \
    "    if situation == \"dead\" or situation == \"instanced\" then" \
    "a solo raid clear is handed a walking route through the open world"

mutate "Modules/Vendors.lua" \
    "            if not recipeID or known[recipeID] or not names[recipeID] then" \
    "            if known[itemID] or not names[itemID] then" \
    "a vendor-sold recipe is found only where two id spaces collide"

mutate "Modules/Instances.lua" \
    "    elseif not Blizzard.HasEncounterJournal()
        or Blizzard.IsEncounterJournalOpen() then
        dropCache[name] = nil
    elseif cached and cached.asked then" \
    "    elseif false then
        dropCache[name] = nil
    elseif true then" \
    "a search the journal refused is remembered as an answer"

mutate "Providers/BlizzardWorld.lua" \
    "        if (info.mapType or 0) > Blizzard.zoneMapType then
            found = current
        else
            break
        end" \
    "        if (info.mapType or 0) >= Blizzard.zoneMapType then
            found = current
        else
            break
        end" \
    "an outdoor zone is reported as being inside an instance"

# ---- 0.82.0 ----

mutate "Modules/Waiting.lua" \
    "    if #expiring > 0
        and not CN.IsIgnored(CN.objectiveTypes.CURRENCY, \"mail\")
        and not CN.IsDeferred(CN.objectiveTypes.CURRENCY, \"mail\") then" \
    "    if #expiring > 0 then" \
    "the mail row cannot be hidden and says it was"

mutate "Modules/Capture.lua" \
    "        if not measured then
            return nil, \"the client would not convert this map\"
        end" \
    "        if false then
            return nil, \"the client would not convert this map\"
        end" \
    "a bug report records every map as one yard square"

mutate "Modules/Contribute.lua" \
    "        local dependency = CN.GetDependency(
            CN.ObjectiveKey(CN.objectiveTypes.QUEST, questID))" \
    "        local dependency = nil" \
    "forgetting an imported chain leaves every edge it created"

mutate "Modules/Harvest.lua" \
    "            observedRequires = prerequisites,
            origin           = \"harvested\",
        })" \
    "            observedRequires = prerequisites,
        })" \
    "your own observation is reported as somebody else's import"

mutate "Providers/BlizzardCollections.lua" \
    "        name = (name:gsub(\"^%s+\", \"\"):gsub(\"%s+$\", \"\"))" \
    "        name = name" \
    "every title is printed with the client's padding"

# RE-ANCHORED IN 0.91.0: the gate reads either vocabulary now, through a local.
mutate "Providers/StaticData.lua" \
    "        return false, CN.FactionLabel(faction) .. \" only\", \"FACTION\"" \
    "        return false, CN.TokenLabel(faction) .. \" only\", \"FACTION\"" \
    "a faction gate is the one untranslated word on the screen"

mutate "Modules/Warband.lua" \
    "            spec     = CN.Blizzard.GetSpecName(character.specID)," \
    "            spec     = nil," \
    "the Warband list drops the specialization it collected"

mutate "Database.lua" \
    "        local dead = {
            mounts      = { \"firstSeen\", \"lastSeen\" }," \
    "        local dead = {
            mountsNotAStore = { \"firstSeen\", \"lastSeen\" }," \
    "nine hundred mount timestamps stay on disk for ever"

mutate "Modules/Mounts.lua" \
    "                collected         = mount.isCollected," \
    "                collected         = mount.isCollected,
                lastSeen          = time()," \
    "every login writes nine hundred timestamps nothing reads"

mutate "Modules/Sets.lua" \
    "            Print(CN.Count(#rows, \"set\") .. \" read\"" \
    "            Print(#rows .. \" sets read\"" \
    "/cn sets says 1 sets"

mutate "Modules/Vendors.lua" \
    "                id              = recipeID,
                itemID          = itemID," \
    "                id              = itemID,
                itemID          = itemID," \
    "a vendor recipe is explained by asking a recipe table an item question"

# ---- 0.83.0 ----

mutate "Modules/Filters.lua" \
    "        mail     = \"Expiring mail\"," \
    "" \
    "/cn hidden names the mail row Currency mail"

mutate "Modules/Filters.lua" \
    "        keystone = \"Your Mythic+ keystone\"," \
    "" \
    "/cn hidden names the keystone row Dungeon keystone"

mutate "Modules/Filters.lua" \
    "        RAID     = \"Great Vault: raid progress\"," \
    "" \
    "/cn hidden names a vault row Currency RAID"

mutate "Modules/Filters.lua" \
    "        local orderID = id:match(\"^order:(%d+)\$\")" \
    "        local orderID = nil" \
    "/cn hidden names a crafting order Recipe order:412"

mutate "Modules/Orders.lua" \
    "        local rowID = \"order:\" .. tostring(order.orderID)" \
    "        local rowID = order.orderID" \
    "a crafting order is retired because a recipe shares its number"

mutate "Modules/Contribute.lua" \
    "    if harvest and harvest.PublishConfident then
        pcall(harvest.PublishConfident)
    end" \
    "    if false then
        pcall(harvest.PublishConfident)
    end" \
    "forgetting an import deletes what you observed yourself"

mutate "Database.lua" \
    "                strip(character.reputations, dead.reputations)" \
    "                strip(nil, dead.reputations)" \
    "the larger half of the reputation store keeps its dead field"

# ---- 0.84.0 ----

# RETIRED IN 0.84.0: three mutations that each moved one Settings control
# back where it overflowed. All three were killed only by the panel being too
# short for its column; making the window forty pixels taller removed the
# whole class, so reverting any single control no longer produces a
# collision. The invariant that matters is below -- the column must fit the
# panel -- and shrinking the window is the mutation that breaks it.

mutate "UI.lua" \
    "UI.WINDOW_HEIGHT = 560" \
    "UI.WINDOW_HEIGHT = 480" \
    "the settings column is taller than the panel it is drawn in"

mutate "UI.lua" \
    "    if window.answer then
        window.answer:SetText(\"\")
    end

    FadeIn(window)" \
    "    FadeIn(window)" \
    "reopening the window greets you with an answer from an hour ago"

mutate "Modules/Goals.lua" \
    "        if ok and best and switchable ~= false then" \
    "        if ok and best then" \
    "the goal plan sends you to the character who already has it"

mutate "Database.lua" \
    "    CN.NoteCollectionChanged()" \
    "    CN.collectionGeneration = (CN.collectionGeneration or 0) + 1" \
    "the collection counter has two writers again"

mutate "Modules/Quests.lua" \
    "    if CN.NoteCollectionChanged then
        CN.NoteCollectionChanged()
    end" \
    "    if false then
        CN.NoteCollectionChanged()
    end" \
    "scanning quests can never clear its own stale mark"

mutate "UI.lua" \
    "        local available = quests.AvailableCount(nil,
            not (window and window:IsShown()))" \
    "        local available = quests.AvailableCount()" \
    "a search with the window shut writes quest pins to disk"

mutate "Modules/MapPins.lua" \
    "    return pins, math.max(0, total - #pins)" \
    "    return pins" \
    "the map drops stops past forty and reports the total as forty"

mutate "UI/List.lua" \
    "        self:SetEntries({}, text)" \
    "        self:SetEntries({})" \
    "a tab whose module is missing tells you to pin a goal"

# ---- 0.85.0 ----

mutate "UI.lua" \
    "        if chase and selectedChain then" \
    "        if selectedChain then" \
    "the Goals tab throws when the Chase module is missing"

mutate "Modules/Hud.lua" \
    "            if height > 0 and room > 0 and (height * applied) > room then
                applied = room / height
            end" \
    "            if false then
                applied = room / height
            end" \
    "the largest text size puts the window off the screen"

mutate "UI/List.lua" \
    "            local message = emptyOverride or self.emptyText" \
    "            local message = self.emptyText" \
    "one keystroke restores the empty sentence that cannot help"

mutate "UI/List.lua" \
    "        emptyOverride = override or nil" \
    "        emptyOverride = emptyOverride or nil" \
    "an empty sentence for one situation is stuck on the list for ever"

mutate "Modules/MapPins.lua" \
    "    return placed, dropped or 0" \
    "    return placed" \
    "/cn pins refresh reports the capped count as the total"

mutate "UI.lua" \
    "            panel.keepFilter.Text:SetWidth(COLUMN - CN.SPACE.M - 30)" \
    "            panel.keepFilter.Text:SetWidth(400)" \
    "a settings label is drawn across the column beside it"

# ---- 0.86.0 ----

mutate "Providers/BlizzardWorld.lua" \
    "    return pets and pets.SpeciesByName and pets.SpeciesByName(name) or nil,
        name" \
    "    return select(4, C_PetJournal.GetPetInfoByItemID(itemID)), name" \
    "a caged pet in your bags is looked up by companion id"

mutate "Modules/Inventory.lua" \
    "                travelCost       = travel or CN.unknownLocationCost," \
    "                travelCost       = CN.placelessCost," \
    "a quest one step from done is priced as if it were in your pocket"

mutate "Modules/Inventory.lua" \
    "                mapID            = mapID,
                x                = x,
                y                = y,

                -- Worth more the closer it is, which is the entire point." \
    "                -- Worth more the closer it is, which is the entire point." \
    "the nearly-done row wins the dedup and throws the coordinates away"

mutate "Modules/Setup.lua" \
    "    if step.measuredAt == 1 then
        measured = first
    elseif step.measuredAt == 3 then
        measured = third
    elseif step.measuredAt == 4 then
        measured = fourth
    end" \
    "" \
    "a cold achievement scan is reported as a success"

mutate "Modules/Achievements.lua" \
    "                    if criteria and criteria > 0 then
                        answered = answered + 1
                    end" \
    "" \
    "a fresh character is nagged to scan for ever"

mutate "Modules/SelfTest.lua" \
    "            if not SelfTest.optionalApi[path] then" \
    "            if true then" \
    "/cn selftest reports FAIL on every client it ships to"

mutate "Modules/SelfTest.lua" \
    "        table.sort(ids, CN.IdBefore)" \
    "" \
    "a diagnostic answers differently on different sessions"

mutate "Modules/Travel.lua" \
    "    pcall(CN.eventFrame.RegisterUnitEvent, CN.eventFrame,
        \"UNIT_SPELLCAST_SUCCEEDED\", \"player\")" \
    "    local unusedNarrowing = CN.eventFrame" \
    "every cast by every unit in a raid is dispatched through a pcall"

mutate "Modules/Preference.lua" \
    "Preference.actionWindows = {
    [CN.objectiveTypes.ACHIEVEMENT] = 3600,
}" \
    "Preference.actionWindows = {
    [CN.objectiveTypes.ACHIEVEMENT] = 3600,
    [CN.objectiveTypes.INSTANCE]    = 5400,
}" \
    "a tuning table holds a number nothing can read"

# ---- 0.87.0 ----

mutate "Modules/Pets.lua" \
    "    return CN.Shortlist(\"PetNames\", Pets.nameRevision, function()" \
    "    return CN.Shortlist(\"PetNames\", CN.collectionGeneration, function()" \
    "the pet name index is rebuilt by every unrelated collection event"

mutate "Modules/Pets.lua" \
    "            local name = CN.Blizzard.GetPetName(id)" \
    "            local name = NameOf(id, Store()[id])" \
    "a cold journal is indexed as eighteen hundred placeholders"

mutate "Modules/Pets.lua" \
    "    Pets.nameRevision = (Pets.nameRevision or 0) + 1" \
    "    Pets.nameRevision = (Pets.nameRevision or 0)" \
    "a pet scan leaves the name index stale"

mutate "Providers/BlizzardWorld.lua" \
    "    return pets and pets.SpeciesByName and pets.SpeciesByName(name) or nil," \
    "    return pets and pets.Resolve and pets.Resolve(name) or nil," \
    "every item tooltip searches the whole pet journal"

mutate "Modules/Inventory.lua" \
    "                mapID, x, y = questModule.GetLocation(row.questID)" \
    "                mapID, x, y = Blizzard.GetQuestWaypoint(row.questID)" \
    "the nearly-done row throws away a location you recorded by hand"

mutate "Modules/Inventory.lua" \
    "            if mapID then
                travel, costed = CN.TravelCost(mapID, x, y)
            end" \
    "            if mapID and x and y then
                travel, costed = CN.TravelCost(mapID, x, y)
            end" \
    "a quest on another continent is charged the near cost"

mutate "Modules/Achievements.lua" \
    "        if (answered or 0) == 0 then
            Print(\"The game would not answer about achievement criteria just \"" \
    "        if false then
            Print(\"The game would not answer about achievement criteria just \"" \
    "/cn achievescan reports a refused scan as a success"

mutate "UI.lua" \
    "                local scanned, completed, _, answered = module.Scan()" \
    "                local scanned, completed = module.Scan()
                local answered = 1" \
    "the achievement button reports a refused scan as a success"

mutate "Modules/Setup.lua" \
    "                        .. (retry[result.label] or \"setup\")" \
    "                        .. \"scanlore\"" \
    "a not-ready achievement scan sends you to the wrong command"

mutate "Modules/Currencies.lua" \
    "    if #list == 0 then
        DebugPrint(\"Currency sweep answered for nothing; not recording it.\")

        return 0, 0, 0
    end" \
    "    if false then
        DebugPrint(\"Currency sweep answered for nothing; not recording it.\")

        return 0, 0, 0
    end" \
    "a refused currency sweep retires every stored currency"

mutate "Modules/Currencies.lua" \
    "    local list = Blizzard.GetCurrencyList()" \
    "    lastScan = time()
    local list = Blizzard.GetCurrencyList()" \
    "a refused currency sweep stamps the throttle it never earned"

mutate "Modules/Currencies.lua" \
    "    if time() - lastScan < Currencies.rescanSeconds then" \
    "    if false then" \
    "the currency throttle does not throttle"

mutate "Modules/Vault.lua" \
    "            limitedTimeBonus = Urgency(row.remaining)," \
    "            limitedTimeBonus = Urgency(row.remaining, resetsIn)," \
    "the vault charges the weekly reset through two curves"

# RE-ANCHORED IN 0.95.0. The reset used to be a third PARAMETER of `Urgency`,
# passed as nil since 0.88.0; that release left the parameter and its branch
# in place, dead, and 0.95.0 deleted both. The invariant is unchanged -- the
# reset is charged once, through `expiresIn` -- so the mutation now adds the
# second charge at the call site rather than re-enabling a branch that no
# longer exists.
mutate "Modules/Instances.lua" \
    "                limitedTimeBonus = Urgency(lockout.remaining,
                    lockout.defeated)," \
    "                limitedTimeBonus = Urgency(lockout.remaining,
                    lockout.defeated)
                    + (((lockout.resetsIn or math.huge) <= 86400) and 3 or 0)," \
    "a lockout charges the weekly reset through two curves"

mutate "Modules/Warband.lua" \
    "    if scope == CN.scopes.ACCOUNT or not bestKey or switchable == false then" \
    "    if scope == CN.scopes.ACCOUNT or not bestKey then" \
    "the only character who can still learn a recipe is ranked down for it"

mutate "Modules/Opportunities.lua" \
    "                keep = left > 0" \
    "                keep = true" \
    "an event that has ended outranks every event still running"

mutate "Modules/Opportunities.lua" \
    "    return Freshen(active)" \
    "    return active" \
    "a freshly read event list is never dated"

mutate "Modules/Filters.lua" \
    "            if duration.computed == \"weeklyReset\" then
                return CN.Blizzard.GetSecondsUntilWeeklyReset() or DAY
            end" \
    "            if duration.computed == \"weeklyReset\" then
                return nil
            end" \
    "until reset defers for nothing at all"

mutate "Modules/Filters.lua" \
    "    return HOUR
end

-- The labels, for a command" \
    "    return nil
end

-- The labels, for a command" \
    "an unknown duration defers forever"

mutate "Modules/Filters.lua" \
    "    if seconds == math.huge then
        return \"indefinitely\"
    end" \
    "    if seconds == -1 then
        return \"indefinitely\"
    end" \
    "the duration that never runs out prints as infd"

mutate "Modules/Filters.lua" \
    "        local seconds = Filters.DurationSeconds(key)" \
    "        local seconds = 3600" \
    "/cn defer ignores the duration it was given"

mutate "Modules/Vendors.lua" \
    "    CN.Debounce(\"Vendors.merchant\", Vendors.recaptureSeconds,
        Vendors.CaptureOpenMerchant)" \
    "    Vendors.CaptureOpenMerchant()" \
    "every item sold to a vendor re-reads the whole merchant"

mutate "Modules/Opportunities.lua" \
    "                and CN.Aside(Opportunities.FormatTimeLeft(event.endsIn))" \
    "                and CN.Aside(tostring(event.sequenceType))" \
    "/cn events prints the client token instead of when it ends"

mutate "Modules/Hud.lua" \
    "    args    = \"<100 to 200>\"," \
    "    args    = \"<100 to 150>\"," \
    "/cn help understates the largest text the addon allows"

mutate "Modules/Vault.lua" \
    "        return text .. \" |cff73b873\" .. CN.DASH .. \" all \"" \
    "        return text .. \" |cff73b873\" .. CN.DASH .. \"all \"" \
    "the vault line puts a space on one side of the dash only"

mutate "UI.lua" \
    "                (filters and filters.DurationSeconds(\"hour\")) or 3600)" \
    "                3600)" \
    "the defer button writes its own copy of what an hour is"

mutate "Modules/Waiting.lua" \
    "            completionValue  = 6,
" \
    "            completionValue  = 6,
            limitedTimeBonus = 3,
" \
    "expiring mail charges its deadline through two curves"

mutate "Modules/Waiting.lua" \
    "            -- ONE DEADLINE, ONE CURVE. 0.89.0. See the mail row above.
            limitedTimeBonus = 0,
            travelCost       = 3,
            expiresIn        = keystone.expiresIn," \
    "            limitedTimeBonus = 2,
            travelCost       = 3,
            expiresIn        = keystone.expiresIn," \
    "the keystone charges the reset through two curves"

mutate "Modules/Waiting.lua" \
    "                -- ONE DEADLINE, ONE CURVE. 0.89.0. See the mail row above.
                limitedTimeBonus = 0," \
    "                limitedTimeBonus = 2," \
    "weekly knowledge charges the reset through two curves"

mutate "Modules/Currencies.lua" \
    "                limitedTimeBonus = 0,
                travelCost       = 0," \
    "                limitedTimeBonus = 1,
                travelCost       = 0," \
    "a capped currency charges the reset through two curves"

mutate "Modules/Orders.lua" \
    "                limitedTimeBonus = 0,
                travelCost       = CN.placelessCost,
                expiresIn        = order.expiresIn," \
    "                limitedTimeBonus = 2,
                travelCost       = CN.placelessCost,
                expiresIn        = order.expiresIn," \
    "a crafting order charges its expiry through two curves"

mutate "Modules/Achievements.lua" \
    "        if record.criteria and record.criteria > 0 and done > 0
            and done < record.criteria then" \
    "        if record.criteria and record.criteria > 0 and done > 0 then" \
    "an achievement with nothing left is offered as closest to finishing"

mutate "Modules/Achievements.lua" \
    "                    if criteria == 0 then
                        table.insert(criteriaLess, {" \
    "                    if false then
                        table.insert(criteriaLess, {" \
    "a cold sweep writes a criteria-less row for every achievement"

mutate "Modules/Achievements.lua" \
    "    for _, row in ipairs(criteriaLess) do" \
    "    for _, row in ipairs({}) do" \
    "a genuinely criteria-less achievement is never recorded"

mutate "Modules/Session.lua" \
    "local function Mounted()
    if UnitOnTaxi and UnitOnTaxi(\"player\") then
        return false
    end" \
    "local function Mounted()
    if UnitOnTaxi and UnitOnTaxi(\"player\") then
        return true
    end" \
    "a flight path is sampled as ground-mount speed"

mutate "Modules/Quests.lua" \
    "        if record.mapID and nearby[record.mapID] then" \
    "        if true then" \
    "a quest offered on another continent is available in this zone"

mutate "Modules/Professions.lua" \
    "                if names[recipeID] ~= info.name then" \
    "                if true then" \
    "every profession list update stales the whole name index"

mutate "Modules/Exploration.lua" \
    "        held.lastSeen = nil" \
    "        held.lastSeen = time()" \
    "an exploration row persists a timestamp nothing reads"

mutate "Modules/Chase.lua" \
    "    if timed == 0 or (timed / outstanding) <= Chase.estimateCoverage then" \
    "    if timed == 0 or (timed / outstanding) < Chase.estimateCoverage then" \
    "half the steps timed is enough for a confident estimate"

mutate "Modules/Group.lua" \
    "        local others = math.max(0, Group.Size() - 1)" \
    "        local others = Group.Size()" \
    "the group sentence counts the player among the people they are with"

mutate "Scoring.lua" \
    "    local index = CN.Memo(\"CandidateIndex\", aggregate.generation, function()" \
    "    local index = CN.Memo(\"CandidateIndex\", 1, function()" \
    "the candidate index never notices a rebuild"

# NOT A MUTATION: the aggregate dedupes by type-and-id before this index is
# built, so first-match and last-match cannot differ. The `built[key] == nil`
# check preserves the walk's documented semantics against a future aggregate
# that stops deduping; it is not a behaviour any fixture can distinguish today.

mutate "Modules/Vault.lua" \
    "                limitedTimeBonusIsProgress = true," \
    "" \
    "the vault's threshold term is undeclared and reads as a second deadline"

mutate "Modules/Navigation.lua" \
    "    local hudModule = CN:GetModule(\"Hud\")

    if hudModule and hudModule.ApplyScale then
        hudModule.ApplyScale()
    end

    return arrow" \
    "    return arrow" \
    "the arrow is drawn at 100% however the player set the scale"

mutate "Modules/Follow.lua" \
    "    local hudModule = CN:GetModule(\"Hud\")

    if hudModule and hudModule.ApplyScale then
        hudModule.ApplyScale()
    end

    return frame" \
    "    return frame" \
    "the follow frame is drawn at 100% however the player set the scale"

mutate "Modules/Welcome.lua" \
    "    local hudModule = CN:GetModule(\"Hud\")

    if hudModule and hudModule.ApplyScale then
        hudModule.ApplyScale()
    end

    return frame" \
    "    return frame" \
    "the welcome screen is drawn at 100% however the player set the scale"

mutate "Modules/Navigation.lua" \
    "    add(\"map scale\", scaleMeasured" \
    "    add(\"map scale\", true" \
    "/cn navdiag prints an unmeasured map scale as a fact"

mutate "Design.lua" \
    "        if CN.UI.RebuildTabs then
            CN.UI.RebuildTabs()
        end" \
    "        if false then
            CN.UI.RebuildTabs()
        end" \
    "the tab strip is never re-measured after a text-size change"

mutate "Design.lua" \
    "        if CN.UI.RelayoutLists then
            CN.UI.RelayoutLists()
        end" \
    "        if false then
            CN.UI.RelayoutLists()
        end" \
    "the rows already built keep the pitch they were built at"

mutate "UI/List.lua" \
    "    return math.floor(ROW_HEIGHT * scale + 0.5)" \
    "    return ROW_HEIGHT" \
    "a 24 point row is drawn on a 20 pixel pitch"

mutate "UI/List.lua" \
    "    scroll:SetPoint(\"TOPLEFT\", 0, -CaptionHeight())" \
    "    scroll:SetPoint(\"TOPLEFT\")" \
    "the sort caption is drawn on top of the first row"

mutate "UI/List.lua" \
    "    return math.floor(14 * scale + 0.5)" \
    "    return 14" \
    "the caption outgrows the band reserved for it"

mutate "Modules/MapPins.lua" \
    "    local generation = RouteGeneration()
        .. \":\" .. tostring(math.floor((startX or 0.5) / CN.routeCacheStep))
        .. \":\" .. tostring(math.floor((startY or 0.5) / CN.routeCacheStep))" \
    "    local generation = RouteGeneration()" \
    "the map route stays ordered from where you were an hour ago"

mutate "Modules/MapPins.lua" \
    "        .. \":\" .. tostring(math.floor((startX or 0.5) / CN.routeCacheStep))" \
    "        .. \":\" .. tostring(startX)" \
    "the zone route is rebuilt on every frame the map is open"

mutate "Modules/Tooltips.lua" \
    "        if mountModule.IsUsableByCharacter(record) then
            return
        end" \
    "        if false then
            return
        end" \
    "a mount of your own faction is flagged as locked to somebody else"

mutate "Modules/Tooltips.lua" \
    "        FactionLine(mount.isFactionSpecific, mount)" \
    "" \
    "one mount says two different things depending on whether you scanned"

mutate "Modules/Harvest.lua" \
    "        Print(\"Harvested \" .. CN.Count(seen, \"quest\")" \
    "        Print(\"Harvested \" .. CN.Count(learned, \"quest\")" \
    "/cn harvestnow reports zero after harvesting a full log"

mutate "Modules/Harvest.lua" \
    "                candidate = { characters = {} }" \
    "                candidate = { seen = 0, characters = {} }" \
    "a sighting counter nothing reads is stored again"

mutate "Database.lua" \
    "        local store = db.account and db.account.questHarvest" \
    "        local store = db.account and db.account.questObservations" \
    "the harvest counters already on disk stay there"

mutate "Modules/Alts.lua" \
    "                .. Alts.DescribeAge(CN.db and CN.db.characters
                    and CN.db.characters[best.key])" \
    "                .. Alts.DescribeAge({ lastSeen = time()
                    - ((best.ageDays or 0) * 86400) })" \
    "a character with no timestamp is reported as played today"

# The Journey tab's copy; the Next tab's carries the note above it, so the
# anchor includes the line before to stay unique.
mutate "UI.lua" \
    "        for index, objective in ipairs(route) do
            table.insert(entries, {
                text = string.format(\"|cff8a8f96%d.|r" \
    "        for index, objective in ipairs(route) do
            table.insert(entries, {
                text = string.format(\"|cff8a8f96%2d.|r" \
    "a window list pads its numbers with spaces"

mutate "Modules/Mounts.lua" \
    "    return token and CN.FactionLabel(token) or nil" \
    "    return token" \
    "the mount tooltip names a faction in English beside translated text"

mutate "Modules/Capture.lua" \
    "            if not optional[path] then" \
    "            if true then" \
    "/cn capture records five probed APIs as gone from the client"

mutate "Modules/Breakdown.lua" \
    "                    if counts and counts.located then
                        return counts.located .. \" harvested with a location\"
                    end" \
    "                    if false then
                        return counts.located .. \" harvested with a location\"
                    end" \
    "/cn breakdown claims a location count it never computed"

mutate "Modules/Quests.lua" \
    "        if static.breadcrumb and type(static.unlocks) == \"table\" then" \
    "        if false and type(static.unlocks) == \"table\" then" \
    "a breadcrumb you can no longer take is offered as available"

mutate "Modules/Quests.lua" \
    "                if Quests.IsCompletedByCharacter(targetID)
                    or Blizzard.IsQuestInLog(targetID) then" \
    "                if false then" \
    "a breadcrumb whose target is finished is still offered"

mutate "Modules/Quests.lua" \
    "        or static.requiresLevel or static.minLevel
        or static.faction or static.requiresFaction
        or static.breadcrumb) then" \
    "        or static.requiresLevel) then" \
    "a curated row written to the documented schema loses to an external addon"

mutate "Modules/Quests.lua" \
    "    local pending = CN.Shortlist(\"Quests.Curated\"," \
    "    local pending = CN.NotAShortlist(\"Quests.Curated\"," \
    "the whole curated database is walked on every quest log update"

mutate "Modules/Quests.lua" \
    "    if completed[questID] ~= byCharacter then" \
    "    if true then" \
    "re-reading an unchanged quest destroys the curated shortlist"

mutate "Modules/Quests.lua" \
    "        completed[questID] = byCharacter

        Quests.completionRevision = (Quests.completionRevision or 0) + 1" \
    "        completed[questID] = byCharacter" \
    "handing a quest in leaves it in the curated shortlist"

mutate "Providers/StaticData.lua" \
    "    if type(questID) ~= \"number\" then" \
    "    if false then" \
    "a quest row filed under a string key is stored and never matched"

mutate "Providers/StaticData.lua" \
    "        if not VALID_FIELDS[field] then" \
    "        if false then" \
    "a field this addon does not read is accepted and silently discarded"

mutate "Providers/StaticData.lua" \
    "    record.origin = origin or record.origin or \"curated\"" \
    "    record.origin = \"curated\"" \
    "a supplier's rows are recorded as checked by hand"

mutate "Providers/StaticData.lua" \
    "        table.insert(Static.collisions, {" \
    "        table.insert({}, {" \
    "two suppliers claiming one quest is resolved silently"

# RE-ANCHORED IN 0.92.0: `UnregisterOrigin` bumps the revision too, so the
# anchor needs the line above it to stay unique.
mutate "Providers/StaticData.lua" \
    "    if added > 0 then
        Static.revision = Static.revision + 1" \
    "    if added > 0 then" \
    "a row registered late is ignored for the rest of the session"

# RE-ANCHORED IN 0.92.0: withdrawal invalidates too, so the anchor carries
# the harvest call that only the registration path makes.
mutate "Providers/StaticData.lua" \
    "        local harvest = CN.modules and CN:GetModule(\"Harvest\")" \
    "        local harvest = nil" \
    "a late registration leaves the unlock index holding the old answer"

mutate "Providers/StaticData.lua" \
    "    if schemaVersion and schemaVersion ~= Static.schemaVersion then" \
    "    if false then" \
    "a supplier built for another schema is never told"

mutate "Providers/StaticData.lua" \
    "    local faction  = record.faction or record.requiresFaction
    local minLevel = record.minLevel or record.requiresLevel" \
    "    local faction  = record.faction
    local minLevel = record.minLevel" \
    "a row written in the vocabulary /cn export emits gates through nothing"

mutate "Modules/Contribute.lua" \
    "        if CN.Static and CN.Static.Count then
            total, curated = CN.Static.Count()
        end" \
    "        if CN.Static and CN.Static.Count then
            total = CN.Static.Count()
            curated = total
        end" \
    "/cn provenance counts a supplier's rows as checked by hand"

mutate "Modules/Currencies.lua" \
    "            serial            = serial," \
    "            serial            = serial,
            lastSeen          = time()," \
    "a currency stores a timestamp nothing reads"

mutate "Modules/Progress.lua" \
    "        store.previousDay    = store.today or 0" \
    "        store.previousDay    = store.today or 0
        store.previousDayKey = store.dayKey" \
    "progress stores a day key nothing reads"

mutate "Modules/Harvest.lua" \
    "    record.lastSeen = time()" \
    "    record.lastSeen = time()
    record.reason = reason" \
    "a harvest row stores a capture reason nothing reads"

# NOT A MUTATION: `CN.ScoreObjective(objective)` resolves the identical value
# through the database metamethod, so no fixture can tell the two apart -- the
# difference is cost, not behaviour. The contract is asserted in the harness
# where it is written instead.

mutate "Scoring.lua" \
    "        note    = \"Quests and exploration only, with quests weighted up.\"," \
    "        note    = \"Quests and exploration only, weighted toward fast travel.\"," \
    "/cn mode leveling advertises a weighting its profile does not carry"

mutate "Objectives.lua" \
    "    if seconds ~= math.huge then
        expires = time() + seconds
    end" \
    "    expires = time() + seconds" \
    "an endless deferral stores a deadline that cannot be read back"

mutate "Modules/Pets.lua" \
    "    if seen == 0 then
        DebugPrint(\"Pet journal answered for nothing; not recording it.\")

        return 0, 0, 0
    end" \
    "    if false then
        DebugPrint(\"Pet journal answered for nothing; not recording it.\")

        return 0, 0, 0
    end" \
    "a cold pet journal is recorded as an empty collection"

mutate "Modules/Pets.lua" \
    "    Pets.lastScan = time()" \
    "    Pets.lastScan = 0" \
    "caging a pet scans the whole journal twice"

mutate "Modules/Pets.lua" \
    "CN:RegisterEvent(\"PET_JOURNAL_LIST_UPDATE\", SweepIfDue)" \
    "CN:RegisterEvent(\"PET_JOURNAL_LIST_UPDATE\", Pets.Scan)" \
    "every pet journal update rescans the whole journal"

mutate "Modules/Warband.lua" \
    "        if switchable == false then
            Print(\"Nothing to switch for.\")" \
    "        if false then
            Print(\"Nothing to switch for.\")" \
    "/cn who names the character who already did it as the one to switch to"

mutate "Modules/Rares.lua" \
    "                if vignette.mapID and vignette.mapID == playerMap then" \
    "                if playerX and playerY then" \
    "a rare on another map is reported as in your current zone"

mutate "Modules/Vendors.lua" \
    "    local record = store[npcID] or { npcID = npcID }" \
    "    local record = store[npcID] or { npcID = npcID, firstSeen = time() }" \
    "a vendor stores a timestamp nothing reads"

mutate "Modules/Rares.lua" \
    "    local record = existing or {
        vignetteID = vignette.vignetteID,
        sightings  = 0,
    }" \
    "    local record = existing or {
        vignetteID = vignette.vignetteID,
        firstSeen  = time(),
        sightings  = 0,
    }" \
    "a rare stores a timestamp nothing reads"

mutate "Providers/StaticData.lua" \
    "Static.apiVersion = 1" \
    "Static.apiVersionUnpublished = 1" \
    "a supplier cannot tell what this registrar promises"

mutate "Providers/StaticData.lua" \
    "    if refused > 0 then" \
    "    if false then" \
    "a supplier's refused rows are never reported at all"

mutate "Providers/StaticData.lua" \
    "            firstRefusal = firstRefusal or why" \
    "            firstRefusal = why

            local errors = CN.modules and CN:GetModule(\"Errors\")

            if errors and errors.Record then
                errors.Record(\"a curated quest row was refused\",
                    tostring(origin or \"unknown\") .. \": \" .. tostring(why))
            end" \
    "a bad supplier evicts every other error in the ring"

mutate "Providers/StaticData.lua" \
    "        if record.origin == origin then
            Static.quests[questID] = nil

            removed = removed + 1
        end" \
    "        if false then
            Static.quests[questID] = nil

            removed = removed + 1
        end" \
    "a supplier cannot take its own rows back"

mutate "Modules/Harvest.lua" \
    "        Print(\"Curated row suppliers:\")" \
    "        if false then Print(\"Curated row suppliers:\") end" \
    "/cn providers cannot answer the question its help line asks"

mutate "Modules/Harvest.lua" \
    "            if provider then

            local ok, isAvailable = pcall(provider.IsAvailable)" \
    "            if true then

            local ok, isAvailable = pcall(provider.IsAvailable)" \
    "/cn providers throws when a provider has been withdrawn"

# RE-ANCHORED IN 0.92.0: the parameter was renamed to stop it shadowing an
# upvalue of the same name in the registrar above.
mutate "Dependencies.lua" \
    "        if CN.questDataOrder[index].name == providerName then
            table.remove(CN.questDataOrder, index)
        end" \
    "        if false then
            table.remove(CN.questDataOrder, index)
        end" \
    "withdrawing a provider leaves it in the order list"

mutate "Modules/SelfTest.lua" \
    "        local rows = CN.commandCollisions or {}

        if #rows == 0 then
            return PASS, \"every command and alias is claimed once\"
        end" \
    "        local rows = {}

        if #rows == 0 then
            return PASS, \"every command and alias is claimed once\"
        end" \
    "a command name claimed twice is recorded where nobody looks"

mutate "Modules/SelfTest.lua" \
    "        local rows = (CN.Static and CN.Static.collisions) or {}" \
    "        local rows = {}" \
    "two suppliers claiming one quest is never named"

mutate "UI/List.lua" \
    "            row:EnableMouse(false)
            row.highlight:SetAlpha(0)" \
    "            row.highlight:SetAlpha(0)" \
    "the truncation row takes the mouse from the row it replaced"

mutate "UI/List.lua" \
    "        local trimmed = CN.Trim(needle)

        filterText = (trimmed ~= \"\") and string.lower(trimmed) or nil" \
    "        filterText = string.lower(needle)" \
    "a trailing space makes the cross-tab count disagree with the tab"

mutate "Modules/Vendors.lua" \
    "            seller.price, seller.extendedCost = Vendors.PriceOf(record, itemID)" \
    "            seller.price = Vendors.PriceOf(record, itemID)" \
    "/cn sells cannot tell a gold price from a currency cost"

mutate "Modules/Professions.lua" \
    "    if seen == 0 then
        return false, 0, 0
    end" \
    "" \
    "a recipe list the client never sent is recorded as a complete read"

mutate "Modules/Quests.lua" \
    "    -- Stamped by the function that does the work, whoever called it.
    lastLogScan = time()" \
    "" \
    "the login quest sweep leaves its throttle unarmed and runs twice"

mutate "Modules/Quests.lua" \
    "    return seen, new, #available" \
    "    return seen, new" \
    "/cn discoveractive walks every related map a second time to count it"

mutate "Providers/StaticData.lua" \
    "        return false, \"quest \" .. questID .. \" is already supplied by \"
            .. kept .. \"; the first registration is kept\"" \
    "" \
    "the last supplier to load overwrites the row the record says was kept"

mutate "Modules/Currencies.lua" \
    "            local spendable = not currency.usesTotalEarned" \
    "            local spendable = true" \
    "a cap on lifetime earnings tells the player to spend their way out"

mutate "Modules/Setup.lua" \
    "    if step.measuredAt == 1 then
        measured = first
    elseif step.measuredAt == 3 then" \
    "    if step.measuredAt == 3 then" \
    "a currency read the client refused completes setup for ever"

mutate "Modules/Tooltips.lua" \
    "    collectible = MountLines(lines, itemID, mountID)  or collectible" \
    "    collectible = MountLines(lines, itemID, Blizzard.GetMountFromItem(itemID))  or collectible" \
    "every mouseover resolves the same item into a mount twice"

mutate "Providers/BlizzardWorld.lua" \
    "    if not ok or type(size) ~= \"number\" then
        Restore()" \
    "    if not ok or type(size) ~= \"number\" then" \
    "a refused currency list leaves the player's headers forced open"

mutate "Providers/BlizzardCollections.lua" \
    "    if shown == 0 and (owned or 0) > 0 then" \
    "    if shown == 0 then" \
    "a cold pet journal has the player's filters wiped at every login"

mutate "Providers/BlizzardCollections.lua" \
    "    if Blizzard.GetNumToys() == 0
        and Blizzard.GetNumOwnableToys() > 0
        and C_ToyBox.SetAllSourceTypeFilters then" \
    "    if Blizzard.GetNumToys() == 0
        and C_ToyBox.SetAllSourceTypeFilters then" \
    "a cold toy box has the player's source filters wiped at every login"

mutate "Modules/Sets.lua" \
    "    if examined == 0 then
        return rows, true, 0
    end" \
    "" \
    "a wardrobe that had not loaded is cached as an empty one for the session"

mutate "Modules/Toys.lua" \
    "    if seen == 0 then
        return 0, 0, 0
    end" \
    "" \
    "a cold toy scan is recorded as a completed read"

mutate "Modules/Mounts.lua" \
    "    if seen == 0 then
        return 0, 0, 0
    end" \
    "" \
    "a cold mount scan is recorded as a completed read"

mutate "Modules/Titles.lua" \
    "    if seen == 0 then
        return 0, 0
    end" \
    "" \
    "a cold title scan is recorded as a completed read"

mutate "Modules/Instances.lua" \
    "        if saved.locked ~= false and (not saved.reset or saved.reset > 0) then" \
    "        if not saved.reset or saved.reset > 0 then" \
    "a lockout you are no longer saved to is offered as spent effort"

mutate "Modules/Pets.lua" \
    "    CN.Debounce(\"Pets.journal\", 2, function()
        Pets.Scan()

        DebugPrint(\"Pet added; journal rescanned.\")
    end)" \
    "    Pets.Scan()" \
    "a bag of caged pets costs one full journal sweep per pet"

mutate "Modules/Progress.lua" \
    "    if Progress.resetIsEstimate and type(store.dayKey) == \"number\" then
        return store.dayKey
    end" \
    "" \
    "a reload before the client speaks moves today's count into yesterday"

mutate "Modules/Progress.lua" \
    "    if Progress.resetIsEstimate and type(store.dayKey) == \"number\" then" \
    "    if Progress.resetIsEstimate and store.dayKey ~= nil then" \
    "a corrupt day key is held for ever instead of rolling over"

mutate "Modules/Inventory.lua" \
    "    store.scannedAt = oldest" \
    "    store.scannedAt = oldest or time()" \
    "a bank the client would not describe is reported as seen just now"

mutate "UI/List.lua" \
    "            local valueWidth = CN.UI.VALUE_WIDTH
                * ((CN.TextScale and CN.TextScale()) or 1)" \
    "            local valueWidth = CN.UI.VALUE_WIDTH" \
    "the value column ignores the text size and overflows its row"

mutate "UI.lua" \
    "                .. \"been scanned; /cn setup fills them.|r\")" \
    "                .. \"been scanned; /cn scan fills them.|r\")" \
    "the empty-search message names a command that does not exist"

mutate "Modules/Exploration.lua" \
    "        if achievement.criteria and achievement.criteria > 0 then" \
    "        if true then" \
    "a cold criteria API zeroes every measured exploration count"

mutate "Modules/Exploration.lua" \
    "    if seen == 0 then
        DebugPrint(\"Exploration sweep answered for nothing; not recording it.\")

        return 0, 0
    end" \
    "" \
    "an exploration sweep that read nothing silences the setup reminder"

mutate "Modules/Reputations.lua" \
    "    -- Stamped by the function that does the work, whoever called it.
    lastScan = time()" \
    "" \
    "a renown level-up costs two full faction sweeps"

mutate "Modules/Reputations.lua" \
    "    if total == 0 then
        DebugPrint(\"Faction sweep answered for nothing; not recording it.\")

        return 0, 0, 0, 0
    end" \
    "" \
    "a cold faction sweep silences the setup reminder for ever"

mutate "Modules/Instances.lua" \
    "        if instanceID then
            same = lockout.instanceID == instanceID
        else
            same = lockout.name == instanceName
        end" \
    "        same = lockout.name == instanceName" \
    "a lockout is matched on a translated name instead of the journal id"

mutate "Modules/Opportunities.lua" \
    "    if #active > 0 then
        eventCache    = active
        eventCachedAt = time()
    else
        eventCache    = nil
        eventCachedAt = 0
    end" \
    "    eventCache    = active
    eventCachedAt = time()" \
    "a calendar that had not replied is cached as an event-free day"

mutate "Modules/Broker.lua" \
    "            and not CN.IsDeferred(CN.objectiveTypes.RARE, id) then" \
    "            then" \
    "a rare the player put off is still announced out loud"

mutate "Modules/Goals.lua" \
    "                    zone            = plan.zone," \
    "                    zone            = plan.zone,
                    accountWide     = true," \
    "pinning a reputation switches off its Warband verdict"

mutate "Modules/Mounts.lua" \
    "                isFactionSpecific = mount.isFactionSpecific," \
    "                spellID           = mount.spellID,
                isFactionSpecific = mount.isFactionSpecific," \
    "nine hundred mount spell ids go back onto the disk"

mutate "Providers/StaticData.lua" \
    "        Static.Complain(\"curated quest rows were refused\"," \
    "        local errors = CN.modules and CN:GetModule(\"Errors\")

        if not errors or not errors.Record then
            return added, refused
        end

        errors.Record(\"curated quest rows were refused\"," \
    "a refusal before the error collector loads is dropped on the floor"

mutate "Data/Quests.lua" \
    "        name      = \"Vanquish the Invaders!\"," \
    "        name      = \"Vanquish the Invaders!\",
        expansion = \"Classic\"," \
    "the addon's own curated row carries a field the registrar refuses"

mutate "Modules/Setup.lua" \
    "    { key = \"toys\",        label = \"Toys\",        module = \"Toys\",        fn = \"Scan\",     unit = \"toys\", measured = true, measuredAt = 1, retry = \"toyscan\" }," \
    "    { key = \"toys\",        label = \"Toys\",        module = \"Toys\",        fn = \"Scan\",     unit = \"toys\" }," \
    "a cold toy box completes setup and silences the reminder for ever"

mutate "Modules/Appearances.lua" \
    "    if #categories == 0 then
        DebugPrint(\"Appearance sweep answered for nothing; not recording it.\")

        return 0
    end" \
    "" \
    "a wardrobe that had not loaded is recorded as a completed scan"

mutate "UI.lua" \
    "                        if ok and ((read or 0) > 0 or answered == true) then" \
    "                        if ok then" \
    "Scan everything counts a scan that read nothing"

mutate "UI.lua" \
    "                        if ok and ((read or 0) > 0 or answered == true) then" \
    "                        if ok and (read or 0) > 0 then" \
    "a profession scan on a character with none reads as a refusal"

mutate "Modules/Harvest.lua" \
    "    if reason == \"turnedin\" and mapID and x and y then" \
    "    if false and mapID and x and y then" \
    "where a quest was handed in is never recorded"

mutate "Modules/Harvest.lua" \
    "        if elsewhere and record.turnInMapID == nil then" \
    "        if record.turnInMapID == nil then" \
    "a quest handed in where it was taken carries three redundant numbers"

mutate "UI.lua" \
    "        if at and at ~= entry.was then" \
    "        if true then" \
    "refreshing stale sources counts a scan the client refused"

mutate "Modules/Harvest.lua" \
    "        if firstSighting then
            record.x = nil
            record.y = nil
        end" \
    "        if false then
            record.x = nil
            record.y = nil
        end" \
    "a quest met at its hand-in is exported as being offered there"

mutate "Modules/Harvest.lua" \
    "    if record.x and record.y then
        return true
    end

    return (record.turnInMapID and record.turnInX and record.turnInY) and true
        or false" \
    "    if record.x and record.y then
        return true
    end

    return false" \
    "a row located only by its hand-in is dropped from the export"

mutate "Modules/Inventory.lua" \
    "        \"GET_ITEM_INFO_RECEIVED\",
    }," \
    "    }," \
    "the bag provider never hears that an item name arrived"

mutate "Scoring.lua" \
    "        local gather = CN.burstInvalidationEvents[event]" \
    "        local gather = nil" \
    "every item the client resolves walks every provider"

mutate "Providers/BlizzardWorld.lua" \
    "    Blizzard.RequestSavedInstances()" \
    "    -- Blizzard.RequestSavedInstances()" \
    "the lockout list is read without ever being asked for"

mutate "Providers/BlizzardWorld.lua" \
    "    if requestedRaidInfo and not force then
        return false
    end" \
    "    if false then
        return false
    end" \
    "every lockout read is a server round trip"

mutate "Modules/Instances.lua" \
    "    CN.Blizzard.ForgetSavedInstanceRequest()
    CN.Blizzard.RequestSavedInstances()" \
    "    CN.Blizzard.ForgetSavedInstanceRequest()" \
    "a loading screen re-arms the lockout request and never sends it"

mutate "Modules/Quests.lua" \
    "    DebugPrint(\"Quest \" .. questID .. \" resolved: \" .. title)" \
    "    Print(\"Quest \" .. questID .. \" resolved: \" .. title)" \
    "a quest title fetched in the background is announced in chat"

mutate "Modules/Quests.lua" \
    "        \"QUEST_DATA_LOAD_RESULT\",
    },
    cooldown = 2," \
    "    },
    cooldown = 2," \
    "the provider that asks for a quest title is not told it arrived"

mutate "Scoring.lua" \
    "    QUEST_DATA_LOAD_RESULT = 0.75," \
    "" \
    "forty quest titles arriving cost forty invalidation passes"

mutate "Modules/Waiting.lua" \
    "    CN.Blizzard.RequestKeystoneInfo()

    local level, mapID" \
    "    local level, mapID" \
    "the keystone is read without ever being asked for"

mutate "Providers/BlizzardWorld.lua" \
    "    if requestedKeystone and not force then
        return false
    end" \
    "    if false then
        return false
    end" \
    "every keystone read is a server round trip"

mutate "Modules/Waiting.lua" \
    "    CN.Blizzard.ForgetKeystoneRequest()
    CN.Blizzard.RequestKeystoneInfo()" \
    "    CN.Blizzard.ForgetKeystoneRequest()" \
    "a loading screen re-arms the keystone request and never sends it"

mutate "Modules/Waiting.lua" \
    "    Blizzard.RequestMail()

    local ok, count = pcall(GetInboxNumItems)" \
    "    local ok, count = pcall(GetInboxNumItems)" \
    "the inbox is read without ever being asked for"

mutate "Providers/BlizzardWorld.lua" \
    "    if requestedMail and not force then
        return false
    end" \
    "    if false then
        return false
    end" \
    "every mail read is a server round trip"

mutate "Modules/Waiting.lua" \
    "        return items, true, Waiting.inboxAnswered" \
    "        return items, true, true" \
    "an inbox that has not answered yet reads as no mail"

mutate "Modules/Waiting.lua" \
    "    CN.Blizzard.ForgetMailRequest()
    CN.Blizzard.RequestMail()" \
    "    CN.Blizzard.ForgetMailRequest()" \
    "a loading screen re-arms the mail request and never sends it"

mutate "Providers/BlizzardWorld.lua" \
    "        if C_Item.RequestLoadItemDataByID and not askedForItem[itemID] then
            askedForItem[itemID] = true

            pcall(C_Item.RequestLoadItemDataByID, itemID)
        end" \
    "        if false then
            askedForItem[itemID] = true

            pcall(C_Item.RequestLoadItemDataByID, itemID)
        end" \
    "an item name the client has not cached is never asked for"

mutate "Providers/BlizzardWorld.lua" \
    "        if C_Item.RequestLoadItemDataByID and not askedForItem[itemID] then
            askedForItem[itemID] = true" \
    "        if C_Item.RequestLoadItemDataByID then
            askedForItem[itemID] = true" \
    "an uncached item name is asked for again on every look"

mutate "Modules/Instances.lua" \
    "    return lockouts, Instances.answered" \
    "    return lockouts, true" \
    "an unanswered lockout list reads as a clear week"

mutate "Modules/Instances.lua" \
    "    if #raw > 0 then
        Instances.answered = true
    end" \
    "    if false then
        Instances.answered = true
    end" \
    "a lockout list that arrived before the addon loaded waits for ever"

mutate "Modules/Instances.lua" \
    "CN:RegisterEvent(\"UPDATE_INSTANCE_INFO\", function()
    Instances.answered = true
end)" \
    "CN:RegisterEvent(\"UPDATE_INSTANCE_INFO\", function()
end)" \
    "the client saying the lockout list is in hand is ignored"

mutate "Providers/Blizzard.lua" \
    "        if not CN.pendingQuestLoads[questID]
            and not CN.refusedQuestLoads[questID] then
" \
    "        if not CN.pendingQuestLoads[questID] then
" \
    "a quest the server refused is asked about again on every rebuild"

mutate "Modules/Quests.lua" \
    "    if not success then
        CN.refusedQuestLoads[questID] = true
" \
    "    if not success then
" \
    "a server saying no is not remembered"

mutate "Modules/Quests.lua" \
    "    if not title then
        CN.refusedQuestLoads[questID] = true
" \
    "    if not title then
" \
    "a load that answered with no title is not remembered"

mutate "Modules/Quests.lua" \
    "CN:RegisterEvent(\"PLAYER_ENTERING_WORLD\", function()
    CN.pendingQuestLoads = {}
    CN.refusedQuestLoads = {}
end)" \
    "CN:RegisterEvent(\"PLAYER_ENTERING_WORLD\", function()
end)" \
    "a transient refusal becomes permanent for the session"

mutate "Core.lua" \
    "        local askedOk, asked = pcall(request.asked)

        if askedOk and asked then" \
    "        local askedOk, asked = pcall(request.asked)

        if true then" \
    "a request the client cannot send is reported as waiting for a reply"

mutate "Core.lua" \
    "            if answeredOk and not answered then" \
    "            if answeredOk then" \
    "a request that was answered is still reported as outstanding"

mutate "Modules/Instances.lua" \
    "CN.RegisterServerRequest{
    label    = \"the lockout list\"," \
    "local _unregistered = {
    label    = \"the lockout list\"," \
    "the lockout list is never registered as a server request"

mutate "Modules/Waiting.lua" \
    "CN.RegisterServerRequest{
    label    = \"your mailbox\"," \
    "local _unregistered = {
    label    = \"your mailbox\"," \
    "the mailbox is never registered as a server request"

mutate "Modules/Instances.lua" \
    "    Instances.answered = false

    CN.Blizzard.ForgetSavedInstanceRequest()" \
    "    CN.Blizzard.ForgetSavedInstanceRequest()" \
    "a loading screen keeps the previous segment's lockout answer"

mutate "Scoring.lua" \
    "            .. CN.Accent(\"/cn clock\") .. \" for what is on a timer.\")" \
    "            .. CN.Accent(\"/cn waiting\") .. \" for what is on a timer.\")" \
    "the empty-list explanation points at the wrong command"

echo
echo "$PASSED killed, $SURVIVED survived."

if [ "$SURVIVED" -gt 0 ]; then
    echo
    echo "A surviving mutation is a hole in the suite. Write the assertion."
    exit 1
fi
