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

mutate "Modules/Travel.lua" \
    "        runSpeed, runMeasured = session.Speed(false)" \
    "        runSpeed, runMeasured = session.Speed()" \
    "running is costed at whatever speed you are moving now"

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
    "    if select(1, Blizzard.GetNumPets()) == 0 then" \
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

mutate "Modules/Session.lua" \
    "        travelKnown = objective.travelCost < ceiling" \
    "        travelKnown = true" \
    "a journey estimate that hit its ceiling is subtracted anyway"

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

mutate "UI/List.lua" \
    "        text = text:gsub(\"|c%x%x%x%x%x%x%x%x\", \"\")" \
    "        text = text" \
    "the list sorts on the colour in front of a name instead of the name"

mutate "UI/List.lua" \
    "        text = text:gsub(\"^[%s%p%d]+\", \"\")" \
    "        text = text" \
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

mutate "Modules/Opportunities.lua" \
    "            if event.endsAt then
                local left = event.endsAt - now

                event.endsIn = (left > 0) and left or nil
            end" \
    "            if false then
                local left = event.endsAt - now

                event.endsIn = (left > 0) and left or nil
            end" \
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
    "                travel = CN.TravelCost(vignette.mapID, vignette.x, vignette.y)" \
    "                travel = 1" \
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
    "        Hud.SetEnabled(false)

        CN.Print(\"Heads-up line off. \" .. CN.Aside(CN.Accent(\"/cn hud\")" \
    "        frame:Hide()

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
    "            if mapID then
                record.mapID = mapID
            end" \
    "            if false then
                record.mapID = mapID
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
                \"already knows it\"" \
    "            return holders[1], table.concat(holders, \", \"),
                \"already knows it\"" \
    "a deleted alt sorting first hides a character you played yesterday"

mutate "Modules/Hud.lua" \
    "    frame.label:SetPoint(\"TOPRIGHT\", -(inset + Hud.closeWidth), -inset)" \
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
    "            elseif #heldName ~= #bestName then
                better = #heldName < #bestName" \
    "            elseif false then
                better = #record.name < #bestRecord.name" \
    "a zone picks a different achievement on every login"

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
    "            local recipeName = names[itemID]" \
    "            local recipeName = sellable[itemID]" \
    "a recipe row is named after the table of vendors that sell it"

mutate "Database.lua" \
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
    "        if watched[achievementID]
            and record.criteria and record.criteria > 0 then" \
    "        if record.criteria and record.criteria > 0 then" \
    "the criteria sweep polls every tracked achievement every five seconds"

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
            expiresIn        = worldQuest.secondsLeft," \
    "            limitedTimeBonus = Opportunities.Urgency(worldQuest.secondsLeft),
            travelCost       = travel,
            expiresIn        = worldQuest.secondsLeft," \
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

mutate "Modules/Currencies.lua" \
    "    if CurrencyFrameOpen() then
        return
    end" \
    "    if false then
        return
    end" \
    "the currency sweep reopens the player's collapsed headers"

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
    "        local heldName = Loremaster.NameOf(id, record)" \
    "        local heldName = record.name" \
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
    "            record.standing    = CN.RenownLabel(major.renownLevel or 0)" \
    "            record.standing    = \"Renown \" .. tostring(major.renownLevel or 0)" \
    "renown is printed in English beside translated standings"

# NOT MUTATED: `CN.scopes.ACCOUNT` and the literal are the same string today,
# so swapping them cannot change behaviour -- the whole point is that they stop
# being the same the moment the sentence is translated. A mutation that cannot
# fail does not belong here; the property is asserted as a source rule in the
# 0.65.0 block instead.

mutate "Modules/Titles.lua" \
    "    for id in pairs(CharacterStore() or {}) do
        local name = Titles.NameOf(id)" \
    "    for id, name in pairs(CN.Account(\"titleNames\")) do" \
    "a title cannot be found by name after a language change"

mutate "Modules/Currencies.lua" \
    "function Currencies.Scan()
    lastScan = time()" \
    "function Currencies.Scan()" \
    "a manual scan arms a second sweep a second later"

mutate "UI.lua" \
    "        local sources = CN.Memo(\"ui:sources\", CN.collectionGeneration,
            UI.Sources)" \
    "        local sources = UI.Sources()" \
    "the Sources tab rewalks ten stores every two seconds"

mutate "Modules/Quests.lua" \
    "    if isNew and CN.CountKeys(store) > Quests.rememberedCap then" \
    "    if CN.CountKeys(store) > Quests.rememberedCap then" \
    "every quest pin walks the whole remembered store"

echo
echo "$PASSED killed, $SURVIVED survived."

if [ "$SURVIVED" -gt 0 ]; then
    echo
    echo "A surviving mutation is a hole in the suite. Write the assertion."
    exit 1
fi
