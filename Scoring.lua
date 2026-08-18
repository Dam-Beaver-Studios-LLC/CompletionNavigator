-- Scoring.lua
-- Completion Navigator :: the recommendation engine.
--
-- Priority Score =
--     Completion Value
--   + Unlock Value
--   + Limited-Time Bonus
--   + Nearby Objective Bonus
--   + User Preference Weight
--   + Character Suitability
--   - Travel Cost
--   - Estimated Time
--   - Difficulty Cost
--   - Dependency Cost

local ADDON_NAME, CN = ...

------------------------------------------------------------
-- WEIGHTS
------------------------------------------------------------

CN.scoreWeights = {
    completionValue     = 1.0,
    unlockValue         = 1.5,
    limitedTimeBonus    = 3.0,
    nearbyBonus         = 1.0,
    userPreference      = 1.0,
    characterSuitability = 1.0,
    travelCost          = -1.0,
    estimatedTime       = -0.5,
    difficultyCost      = -0.5,
    dependencyCost      = -1.0,
}

-- An objective with no known coordinates costs nothing to travel to, which
-- would let every unlocated objective outrank every located one. Charge a
-- baseline instead: not knowing where something is has a real cost.
CN.unknownLocationCost = 3

-- Priority profiles have two independent levers:
--   weights = override entries in scoreWeights (affects every objective)
--   types   = multiply the final score for a given objective type
-- Keeping them separate matters: an earlier version put weight names in the
-- type table, where they silently did nothing.
CN.priorityProfiles = {
    balanced     = {},
    fastest      = { weights = { travelCost = -2.5, estimatedTime = -1.5 } },
    zone         = { weights = { travelCost = -3.0, nearbyBonus = 2.0 } },
    quests       = { types = { QUEST = 2.0 } },
    achievements = { types = { ACHIEVEMENT = 2.0 } },
    reputation   = { types = { REPUTATION = 2.0, RENOWN = 2.0 } },
    pets         = { types = { PET = 2.0 } },
    professions  = { types = { PROFESSION = 2.0, RECIPE = 1.5 } },
    recipes      = { types = { RECIPE = 2.0 } },
    collections  = { types = { PET = 1.5, MOUNT = 1.5, TOY = 1.5, APPEARANCE = 1.5 } },
    legacy       = {},
}

------------------------------------------------------------
-- SCORING
------------------------------------------------------------

function CN.ScoreObjective(objective)
    if type(objective) ~= "table" then
        return 0
    end

    local settings = CN.Settings()
    local mode     = (settings and settings.priorityMode) or "balanced"
    local profile  = CN.priorityProfiles[mode] or {}

    -- Effective weights: defaults, then this profile's overrides.
    local w = {}

    for key, value in pairs(CN.scoreWeights) do
        w[key] = value
    end

    if profile.weights then
        for key, value in pairs(profile.weights) do
            w[key] = value
        end
    end

    local travel = objective.travelCost

    if travel == nil then
        travel = CN.unknownLocationCost
    end

    local score = 0

    score = score + (objective.completionValue      or 1) * w.completionValue
    score = score + (objective.unlockValue          or 0) * w.unlockValue
    score = score + (objective.limitedTimeBonus     or 0) * w.limitedTimeBonus
    score = score + (objective.nearbyBonus          or 0) * w.nearbyBonus
    score = score + (objective.userPreference       or 0) * w.userPreference
    score = score + (objective.characterSuitability or 0) * w.characterSuitability
    score = score + travel                                * w.travelCost
    score = score + (objective.estimatedTime        or 0) * w.estimatedTime
    score = score + (objective.difficultyCost       or 0) * w.difficultyCost
    score = score + (objective.dependencyCost       or 0) * w.dependencyCost

    if profile.types and objective.type and profile.types[objective.type] then
        score = score * profile.types[objective.type]
    end

    -- Normalize -0.0, which formats as "-0.0" and reads like a bug.
    if score == 0 then
        score = 0
    end

    objective.priorityWeight = score

    return score
end

------------------------------------------------------------
-- CANDIDATE COLLECTION
------------------------------------------------------------

-- Modules contribute actionable objectives by registering a provider.
-- Each provider returns an array of objective tables.
CN.candidateProviders = CN.candidateProviders or {}

function CN.RegisterCandidateProvider(name, provider)
    CN.candidateProviders[name] = provider
end

-- Decorators get a pass over every candidate after collection and before
-- scoring. This is how cross-cutting concerns -- Warband suitability, for
-- one -- apply to objectives from modules that know nothing about them.
CN.candidateDecorators = CN.candidateDecorators or {}

function CN.RegisterCandidateDecorator(name, decorator)
    if type(decorator) == "function" then
        CN.candidateDecorators[name] = decorator
    end
end

------------------------------------------------------------
-- CACHING
------------------------------------------------------------

-- Fourteen providers now run on every /cn next, every window refresh and
-- every auto-advance tick, and several of them walk thousands of records.
-- Recomputing all of that several times a second was never the design; the
-- architecture notes called for cached state and dirty flags from the start.
--
-- The cache is invalidated by the events that can actually change an answer,
-- with a short TTL as a backstop for anything that changes without an event
-- (a world quest timer ticking down, for one).
local cache = {
    candidates = nil,
    builtAt    = 0,
    dirty      = true,
}

CN.candidateCacheSeconds = 5

-- Per-provider timings, so a slow provider can be identified rather than
-- guessed at.
CN.providerTimings = CN.providerTimings or {}

function CN.InvalidateCandidates(reason)
    cache.dirty = true

    if reason then
        CN.DebugPrint("Candidate cache invalidated: " .. tostring(reason))
    end
end

-- Anything that can change what is actionable.
for _, event in ipairs({
    "QUEST_ACCEPTED",
    "QUEST_TURNED_IN",
    "QUEST_REMOVED",
    "QUEST_LOG_UPDATE",
    "ACHIEVEMENT_EARNED",
    "CRITERIA_UPDATE",
    "UPDATE_FACTION",
    "NEW_PET_ADDED",
    "NEW_MOUNT_ADDED",
    "NEW_TOY_ADDED",
    "CURRENCY_DISPLAY_UPDATE",
    "VIGNETTE_MINIMAP_UPDATED",
    "VIGNETTES_UPDATED",
    "ZONE_CHANGED_NEW_AREA",
    "MERCHANT_SHOW",
    "TRADE_SKILL_LIST_UPDATE",
}) do
    CN:RegisterEvent(event, function()
        CN.InvalidateCandidates(event)
    end)
end

local function BuildCandidates()
    local candidates = {}

    for name, provider in pairs(CN.candidateProviders) do
        local startedAt = debugprofilestop and debugprofilestop() or nil

        local ok, result = pcall(provider)

        if startedAt and debugprofilestop then
            local elapsed = debugprofilestop() - startedAt

            local timing = CN.providerTimings[name] or { calls = 0, total = 0, worst = 0 }

            timing.calls = timing.calls + 1
            timing.total = timing.total + elapsed
            timing.worst = math.max(timing.worst, elapsed)
            timing.last  = elapsed

            CN.providerTimings[name] = timing
        end

        if ok and type(result) == "table" then
            for _, objective in ipairs(result) do
                table.insert(candidates, objective)
            end
        elseif not ok then
            CN.DebugPrint("Candidate provider " .. name .. " failed: " .. tostring(result))
        end
    end

    for name, decorator in pairs(CN.candidateDecorators) do
        for _, objective in ipairs(candidates) do
            local ok, err = pcall(decorator, objective)

            if not ok then
                CN.DebugPrint("Candidate decorator " .. name .. " failed: " .. tostring(err))
            end
        end
    end

    return candidates
end

function CN.CollectCandidates(force)
    local now = time()

    local fresh = cache.candidates
        and not cache.dirty
        and (now - cache.builtAt) < CN.candidateCacheSeconds

    if fresh and not force then
        return cache.candidates
    end

    cache.candidates = BuildCandidates()
    cache.builtAt    = now
    cache.dirty      = false

    return cache.candidates
end

function CN.GetCandidateCacheState()
    return {
        cached  = cache.candidates ~= nil,
        count   = cache.candidates and #cache.candidates or 0,
        dirty   = cache.dirty,
        age     = cache.candidates and (time() - cache.builtAt) or nil,
    }
end

------------------------------------------------------------
-- RECOMMENDATION
------------------------------------------------------------

function CN.Recommend(limit)
    limit = limit or 1

    local candidates = CN.CollectCandidates()

    for _, objective in ipairs(candidates) do
        CN.ScoreObjective(objective)
    end

    table.sort(candidates, function(a, b)
        return (a.priorityWeight or 0) > (b.priorityWeight or 0)
    end)

    local results = {}

    for index = 1, math.min(limit, #candidates) do
        table.insert(results, candidates[index])
    end

    return results
end

------------------------------------------------------------
-- EXPLANATION
------------------------------------------------------------

function CN.ExplainRecommendation(objective)
    local lines = {}

    if objective.reasons then
        for _, reason in ipairs(objective.reasons) do
            table.insert(lines, "- " .. reason)
        end
    end

    if #lines == 0 then
        table.insert(lines, "- highest available priority score")
    end

    return lines
end

------------------------------------------------------------
-- COMMAND
------------------------------------------------------------

CN:RegisterCommand{
    name    = "next",
    order   = 10,
    help    = "Recommend the next objective.",
    handler = function()
        local results = CN.Recommend(1)

        if #results == 0 then
            CN.Print("No actionable objectives are known yet.")
            CN.Print("The recommendation engine needs candidate providers; quests are the only subsystem currently online.")
            return
        end

        local objective = results[1]

        CN.currentRecommendation = objective

        CN.Print("Recommended next: " .. tostring(objective.name or objective.id)
            .. " |cff999999(" .. tostring(objective.type) .. ")|r")

        for _, line in ipairs(CN.ExplainRecommendation(objective)) do
            CN.Print(line)
        end

        if objective.mapID and objective.x and objective.y then
            CN.Print("|cffffff00/cn go|r to set a waypoint.")
        end
    end,
}

CN:RegisterCommand{
    name    = "perf",
    order   = 90,
    help    = "Show candidate provider timings and cache state.",
    handler = function()
        local state = CN.GetCandidateCacheState()

        CN.Print("Candidate cache: "
            .. (state.cached and (state.count .. " objectives") or "empty")
            .. (state.dirty and " |cffffff00(stale)|r" or "")
            .. (state.age and (" |cff999999" .. state.age .. "s old|r") or ""))

        local rows = {}

        for name, timing in pairs(CN.providerTimings) do
            table.insert(rows, {
                name    = name,
                average = timing.calls > 0 and (timing.total / timing.calls) or 0,
                worst   = timing.worst,
                calls   = timing.calls,
            })
        end

        if #rows == 0 then
            CN.Print("No timings recorded yet. Run |cffffff00/cn next|r first.")
            CN.Print("|cff999999Timings need debugprofilestop, which exists in game "
                .. "but not in offline tests.|r")
            return
        end

        table.sort(rows, function(a, b) return a.average > b.average end)

        CN.Print("Providers, slowest first:")

        for _, row in ipairs(rows) do
            CN.Print(string.format("  %-14s avg %.2fms  worst %.2fms  (%d %s)",
                row.name, row.average, row.worst, row.calls,
                row.calls == 1 and "call" or "calls"))
        end
    end,
}

CN:RegisterCommand{
    name    = "list",
    args    = "[count]",
    order   = 11,
    help    = "Show the top scored objectives.",
    handler = function(args)
        local limit = CN.ToID(args) or 5

        local results = CN.Recommend(limit)

        if #results == 0 then
            CN.Print("No actionable objectives are known yet.")
            return
        end

        for index, objective in ipairs(results) do
            CN.Print(index .. ". " .. tostring(objective.name or objective.id)
                .. " |cff999999[" .. tostring(objective.type)
                .. " " .. string.format("%.1f", objective.priorityWeight or 0) .. "]|r")
        end
    end,
}
