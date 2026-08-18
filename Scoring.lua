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
--
-- options = {
--     events   = { "QUEST_ACCEPTED", ... },  -- what makes this provider stale
--     volatile = true,                       -- also expires on the clock
--     cooldown = 5,                          -- rebuild at most this often
-- }
--
-- cooldown is for providers subscribed to chatty events. CRITERIA_UPDATE and
-- UPDATE_FACTION fire many times a second during normal play, and rebuilding
-- a 3000-record provider on each one costs more than the answer is worth. The
-- provider stays marked stale and rebuilds on the first collection after the
-- cooldown expires, so the cost is bounded rather than the work skipped.
--
-- A provider that declares no events is treated as stale on every event. That
-- is the safe default and the old behaviour, but declaring events is what
-- makes an invalidation cost one provider instead of all nine.
CN.candidateProviders = CN.candidateProviders or {}

function CN.RegisterCandidateProvider(name, provider, options)
    options = options or {}

    local events

    if options.events then
        events = {}

        for _, event in ipairs(options.events) do
            events[event] = true
        end
    end

    CN.candidateProviders[name] = {
        name     = name,
        fn       = provider,
        events   = events,
        volatile = options.volatile and true or false,
        cooldown = options.cooldown,
    }
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

-- Measured against a retail-scale database -- 1800 pets, 3000 achievements,
-- 500 factions, 2500 recipes -- the naive path cost 45ms to rebuild and,
-- worse, 15ms on every single call even with the candidate list cached,
-- because the whole list was re-scored and re-sorted every time. At 60fps a
-- frame is 16ms. Hovering the minimap button was dropping frames.
--
-- Three caches, each invalidated by the narrowest thing that can change it:
--
--   1. Per provider. NEW_PET_ADDED rebuilds Pets, not Achievements.
--   2. The aggregate list, rebuilt only when some provider actually was.
--   3. The scored and sorted list, reused until the aggregate or the
--      priority mode changes.
--
-- Volatile providers -- world quest timers, live rares, weekly currency
-- earning -- change without any event firing, so those alone also expire on
-- a short clock.

local providerCache = {}   -- [name] = { candidates, builtAt, dirty }

local aggregate = {
    candidates = nil,
    builtAt    = 0,
    generation = 0,
}

local ranked = {
    list       = nil,
    generation = -1,
    mode       = nil,
}

CN.candidateCacheSeconds = 5

-- Per-provider timings, so a slow provider can be identified rather than
-- guessed at.
CN.providerTimings = CN.providerTimings or {}

-- What each provider dropped to stay inside its budget. Reported by
-- /cn perf, because a cap nobody can see reads as "that is everything".
CN.providerTruncation = CN.providerTruncation or {}

local function Entry(name)
    local entry = providerCache[name]

    if not entry then
        entry = { candidates = nil, builtAt = 0, dirty = true, urgent = true }
        providerCache[name] = entry
    end

    return entry
end

-- reason == nil invalidates everything. A named event invalidates only the
-- providers that subscribed to it, plus any that declared no subscription.
--
-- An invalidation with no reason is an explicit one -- a scan finished, a
-- character logged in, a goal was pinned -- and it bypasses cooldowns. A
-- cooldown exists to stop a chatty *event* from causing work; it must never
-- delay something the player just did on purpose. Pinning a goal and not
-- seeing it appear for two seconds reads as the feature being broken.
function CN.InvalidateCandidates(reason)
    local hit = 0

    for name, provider in pairs(CN.candidateProviders) do
        if not reason or not provider.events or provider.events[reason] then
            local entry = Entry(name)

            entry.dirty = true

            if not reason then
                entry.urgent = true
            end

            hit = hit + 1
        end
    end

    if hit > 0 then
        -- Deliberately NOT clearing the aggregate here. Marking a provider
        -- stale is not the same as it having changed: a cooldown may hold the
        -- rebuild off, or the rebuild may produce an identical list. Only
        -- RefreshProviders knows whether anything was actually rebuilt, and
        -- discarding the aggregate here would bust the ranked cache on every
        -- QUEST_LOG_UPDATE for nothing.
        if reason then
            CN.DebugPrint("Candidate cache: " .. reason .. " invalidated " .. hit
                .. " provider" .. (hit == 1 and "" or "s"))
        end
    end
end

function CN.InvalidateProvider(name, urgent)
    if CN.candidateProviders[name] then
        local entry = Entry(name)

        entry.dirty = true

        if urgent then
            entry.urgent = true
        end
    end
end

-- Anything that can change what is actionable. Which providers each event
-- reaches is declared by the providers themselves.
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

-- A different character means different Warband suitability, different
-- character-scoped reputations and a different recipe book.
CN:OnLogin(function()
    CN.InvalidateCandidates()
end)

local function RunProvider(name, provider)
    local startedAt = debugprofilestop and debugprofilestop() or nil

    local ok, result = pcall(provider.fn)

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
        return result
    end

    if not ok then
        CN.DebugPrint("Candidate provider " .. name .. " failed: " .. tostring(result))
    end

    return {}
end

-- Decoration happens once per objective, when its provider builds it.
--
-- It used to run over the whole aggregate on every rebuild. That was fine
-- when every collection rebuilt everything, but per-provider caching means
-- the aggregate is mostly the SAME objective tables as last time -- so a
-- decorator that appends a reason (Warband's does) appended it again, and
-- again, and the recommendation grew a stack of identical lines.
local function Decorate(candidates)
    for name, decorator in pairs(CN.candidateDecorators) do
        for index = 1, #candidates do
            local ok, err = pcall(decorator, candidates[index])

            if not ok then
                CN.DebugPrint("Candidate decorator " .. name .. " failed: " .. tostring(err))
                break
            end
        end
    end
end

local function RefreshProviders(force)
    local now     = time()
    local rebuilt = 0

    for name, provider in pairs(CN.candidateProviders) do
        local entry = Entry(name)

        local cooled = entry.urgent
            or provider.cooldown == nil
            or (now - entry.builtAt) >= provider.cooldown

        local stale = force
            or entry.candidates == nil
            or (entry.dirty and cooled)
            or (provider.volatile
                and (now - entry.builtAt) >= CN.candidateCacheSeconds)

        if stale then
            entry.candidates = RunProvider(name, provider)

            -- Decorate here, not over the aggregate: these objectives are
            -- new, and every other provider's are not.
            Decorate(entry.candidates)

            entry.builtAt = now
            entry.dirty   = false
            entry.urgent  = false

            rebuilt = rebuilt + 1
        end
    end

    return rebuilt
end


function CN.CollectCandidates(force)
    local rebuilt = RefreshProviders(force)

    -- Nothing was rebuilt, so the aggregate cannot have changed.
    if aggregate.candidates and rebuilt == 0 then
        return aggregate.candidates
    end

    local candidates = {}

    for name in pairs(CN.candidateProviders) do
        local list = providerCache[name] and providerCache[name].candidates

        if list then
            for index = 1, #list do
                candidates[#candidates + 1] = list[index]
            end
        end
    end

    aggregate.candidates = candidates
    aggregate.builtAt    = time()
    aggregate.generation = aggregate.generation + 1

    return candidates
end

function CN.GetCandidateCacheState()
    local providers, fresh, dirty = 0, 0, 0

    for name in pairs(CN.candidateProviders) do
        providers = providers + 1

        local entry = providerCache[name]

        if entry and entry.candidates and not entry.dirty then
            fresh = fresh + 1
        else
            dirty = dirty + 1
        end
    end

    return {
        cached     = aggregate.candidates ~= nil,
        count      = aggregate.candidates and #aggregate.candidates or 0,
        dirty      = aggregate.candidates == nil or dirty > 0,
        age        = aggregate.candidates and (time() - aggregate.builtAt) or nil,
        generation = aggregate.generation,
        providers  = providers,
        fresh      = fresh,
        stale      = dirty,
        ranked     = ranked.generation == aggregate.generation,
    }
end

function CN.GetProviderCacheState(name)
    local entry = providerCache[name]

    if not entry then
        return nil
    end

    return {
        cached = entry.candidates ~= nil,
        count  = entry.candidates and #entry.candidates or 0,
        dirty  = entry.dirty,
        age    = entry.candidates and (time() - entry.builtAt) or nil,
    }
end

------------------------------------------------------------
-- RECOMMENDATION
------------------------------------------------------------

-- Scoring and sorting a few thousand candidates is not free, and every
-- caller wants the same ordering. Keep the ranked list until either the
-- candidate set or the priority mode changes.
local function Ranked()
    local settings = CN.Settings()
    local mode     = (settings and settings.priorityMode) or "balanced"

    local candidates = CN.CollectCandidates()

    if ranked.list
        and ranked.generation == aggregate.generation
        and ranked.mode == mode then

        return ranked.list
    end

    -- Sorting a copy, not the aggregate. Callers that walk the candidate
    -- list -- zone routing, for one -- must not have it reordered under
    -- them as a side effect of somebody asking for a recommendation.
    local list = {}

    for index = 1, #candidates do
        local objective = candidates[index]

        CN.ScoreObjective(objective)

        list[index] = objective
    end

    table.sort(list, function(a, b)
        local left  = a.priorityWeight or 0
        local right = b.priorityWeight or 0

        if left == right then
            -- Ties must break deterministically or the list shuffles between
            -- refreshes and reads as flicker.
            return tostring(a.id) < tostring(b.id)
        end

        return left > right
    end)

    ranked.list       = list
    ranked.generation = aggregate.generation
    ranked.mode       = mode

    return list
end

CN.RankedCandidates = Ranked

function CN.Recommend(limit)
    limit = limit or 1

    local list = Ranked()

    local results = {}

    for index = 1, math.min(limit, #list) do
        results[index] = list[index]
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
    help    = "Show candidate provider timings, cache state and any caps hit.",
    handler = function()
        local state = CN.GetCandidateCacheState()

        CN.Print("Candidate cache: "
            .. (state.cached and (state.count .. " objectives") or "empty")
            .. (state.dirty and " |cffffff00(stale)|r" or "")
            .. (state.age and (" |cff999999" .. state.age .. "s old|r") or ""))

        CN.Print("Providers: " .. state.fresh .. " of " .. state.providers
            .. " cached, ranked list "
            .. (state.ranked and "|cff00ff00reused|r" or "|cffffff00rebuilding|r"))

        local rows = {}

        for name, timing in pairs(CN.providerTimings) do
            local cache = CN.GetProviderCacheState(name)

            table.insert(rows, {
                name    = name,
                average = timing.calls > 0 and (timing.total / timing.calls) or 0,
                worst   = timing.worst,
                calls   = timing.calls,
                cached  = cache and cache.cached and not cache.dirty,
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
            CN.Print(string.format("  %-14s avg %.2fms  worst %.2fms  (%d %s)%s",
                row.name, row.average, row.worst, row.calls,
                row.calls == 1 and "call" or "calls",
                row.cached and "" or " |cffffff00stale|r"))
        end

        -- A cap nobody can see reads as "that was everything".
        local capped = false

        for name, truncation in pairs(CN.providerTruncation) do
            if (truncation.dropped or 0) > 0 then
                if not capped then
                    CN.Print("Capped at " .. CN.providerCandidateCap .. " per provider:")
                    capped = true
                end

                CN.Print("  " .. name .. ": showing " .. CN.providerCandidateCap
                    .. " of " .. truncation.considered
                    .. " |cff999999(" .. truncation.dropped .. " lower-valued dropped)|r")
            end
        end

        if capped then
            CN.Print("|cff999999Dropped entries scored no higher than the ones kept. "
                .. "Full counts are in /cn breakdown.|r")
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
