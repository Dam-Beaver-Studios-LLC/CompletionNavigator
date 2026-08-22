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

-- A WEIGHT WITH NO PRODUCER IS A LIE IN THE FORMULA.
--
-- `difficultyCost` and `dependencyCost` were declared here, summed in
-- ScoreObjective, listed in this file's header formula and printed by
-- `/cn order` -- and nothing in the addon has ever set either field on an
-- objective. They contributed exactly zero to every score ever computed,
-- while making the documented formula longer and the explanation of the
-- ranking less true. Removed in 0.48.0.
--
-- `estimatedTime` was in the same state, but with a difference: `/cn mode
-- fastest` advertises it as one of its two levers, so leaving it inert made
-- the mode half a feature. It now has a producer -- see the decorator below
-- -- and stays.
CN.scoreWeights = {
    completionValue     = 1.0,
    unlockValue         = 1.5,
    limitedTimeBonus    = 3.0,
    nearbyBonus         = 1.0,
    userPreference      = 1.0,
    characterSuitability = 1.0,
    travelCost          = -1.0,
    estimatedTime       = -0.5,
}

-- An objective with no known coordinates costs nothing to travel to, which
-- would let every unlocated objective outrank every located one. Charge a
-- baseline instead: not knowing where something is has a real cost.
CN.unknownLocationCost = 3

-- Doing something at a place you are going to anyway is cheaper than doing it
-- somewhere else, and the engine should say so rather than leaving it to the
-- route display. This is what stops a recommendation sending you across the
-- zone for one quest when four things sit together on the way.
CN.batchBonusPerNeighbour = 0.6
CN.batchBonusCap          = 3

-- URGENCY.
--
-- "This is gone in six hours" is the strongest signal the game gives, and
-- until now the addon treated it as a flag rather than a gradient: a world
-- quest with four days left and one with nine minutes left scored the same.
-- That is exactly backwards at the moment it matters.
--
-- The curve is deliberately steep and late. Something with a day left is not
-- urgent -- saying so would make everything urgent, which is the same as
-- nothing being urgent. Inside two hours it climbs hard.
CN.urgencyHorizonSeconds = 7200
CN.urgencyWeight         = 4.0

-- A SECOND HORIZON, ADDED IN 0.43.0.
--
-- Two hours was the right window when everything with a deadline was a world
-- quest. It stopped being right when lockouts and the Great Vault arrived:
-- both expire at the weekly reset, so both sat at exactly zero urgency for
-- six and a half days and then jumped. A raid you are six bosses into, with
-- eighteen hours left on it, is genuinely more urgent than the same raid on
-- Wednesday -- and the curve could not say so.
--
-- So: a long ramp that starts a week out and carries a small amount of
-- weight, and the original short ramp on top of it for the last two hours.
-- The short one still dominates, which is the point -- a world quest with ten
-- minutes on it should still beat a lockout with four days.
CN.urgencyLongHorizonSeconds = 7 * 86400
CN.urgencyLongShare          = 0.35

function CN.UrgencyBonus(secondsLeft)
    if type(secondsLeft) ~= "number" or secondsLeft <= 0 then
        return 0
    end

    local value = 0

    if secondsLeft < CN.urgencyLongHorizonSeconds then
        -- Linear across the week. Deliberately not squared: the point of this
        -- term is to break ties between things that are all days away, and a
        -- squared curve would leave them all at nearly zero, which is the
        -- behaviour being fixed.
        local remaining = 1 - (secondsLeft / CN.urgencyLongHorizonSeconds)

        value = remaining * CN.urgencyLongShare
    end

    if secondsLeft < CN.urgencyHorizonSeconds then
        -- Squared, so the last twenty minutes are worth much more than the
        -- first hour of the window.
        local remaining = 1 - (secondsLeft / CN.urgencyHorizonSeconds)

        value = value + (remaining * remaining)
    end

    return value
end

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
}

-- MODES.
--
-- A profile changes the weighting. A mode changes the weighting AND what is
-- shown, because "I am levelling tonight" means both "prefer quests" and
-- "stop showing me pets". Two commands to say one thing is the addon making
-- the player do its filing.
--
-- Every mode is reversible in one word, and `/cn mode` with no argument says
-- which one is on and what it did.
CN.modes = {
    leveling = {
        label   = "Levelling",
        profile = "quests",
        show    = { "QUEST", "EXPLORATION" },
        note    = "Quests and exploration only, weighted toward fast travel.",
    },

    collecting = {
        label   = "Collecting",
        profile = "collections",
        show    = { "PET", "MOUNT", "TOY", "APPEARANCE", "RARE", "TREASURE" },
        note    = "Pets, mounts, toys, appearances and the rares that drop them.",
    },

    reputation = {
        label   = "Reputation",
        profile = "reputation",
        show    = { "REPUTATION", "RENOWN", "QUEST", "CURRENCY" },
        note    = "Standing and the quests that raise it.",
    },

    achievements = {
        label   = "Achievements",
        profile = "achievements",
        show    = { "ACHIEVEMENT", "EXPLORATION", "QUEST" },
        note    = "Criteria you are close to finishing.",
    },

    professions = {
        label   = "Professions",
        profile = "professions",
        show    = { "PROFESSION", "RECIPE", "VENDOR" },
        note    = "Skill-ups, missing recipes and who sells them.",
    },

    everything = {
        label   = "Everything",
        profile = "balanced",
        show    = nil,   -- nil means "clear the filter", not "show nothing"
        note    = "All types, balanced weighting.",
    },
}

------------------------------------------------------------
-- SCORING
------------------------------------------------------------

-- Modules that want a say in the final score without this file knowing about
-- them. Ordered by registration, so the result does not depend on table
-- iteration order -- two players with the same data must get the same list.
CN.scoreAdjusters     = CN.scoreAdjusters or {}
CN.scoreAdjusterOrder = CN.scoreAdjusterOrder or {}

function CN.RegisterScoreAdjuster(name, adjuster)
    if type(name) ~= "string" or type(adjuster) ~= "function" then
        return false
    end

    if not CN.scoreAdjusters[name] then
        table.insert(CN.scoreAdjusterOrder, name)
    end

    CN.scoreAdjusters[name] = adjuster

    return true
end

-- Bumped when something that changes the ORDER changes, without any candidate
-- having changed. Rebuilding every provider to reorder a list nobody's data
-- moved in would cost milliseconds to achieve nothing.
CN.rankingGeneration = CN.rankingGeneration or 0

-- A REASON AN ADJUSTER ADDS, ADDED ONCE.
--
-- Scoring runs repeatedly over the SAME cached objective tables -- ranking
-- re-scores them on every rebuild, and every zone route bumps the ranking
-- generation. An adjuster that did `table.insert(objective.reasons, ...)`
-- therefore appended on every pass: one objective was measured carrying
-- sixty-two reasons after thirty rounds of ordinary play, and `/cn why`
-- printed the same sentence sixty times over.
--
-- This is the identical defect recorded as fixed for DECORATORS further down
-- this file. That fix was applied to decorators and nobody looked at the
-- adjuster path, which runs far more often.
function CN.AddAdjusterReason(objective, key, text)
    if type(objective) ~= "table" or not text then
        return false
    end

    objective.adjusterReasons = objective.adjusterReasons or {}

    if objective.adjusterReasons[key] then
        return false
    end

    -- The text itself, not a boolean, so it can be taken back out again --
    -- see CN.ClearAdjusterReason.
    objective.adjusterReasons[key] = text
    objective.reasons = objective.reasons or {}

    table.insert(objective.reasons, text)

    return true
end

-- AND A REASON ABOUT RIGHT NOW HAS TO BE REMOVABLE.
--
-- Adjusters describe the player's situation -- dead, in an instance, in a
-- group -- and stamp a sentence explaining the score they returned. The
-- objectives they stamp it on live in the per-provider cache, which outlives
-- the situation by a long way.
--
-- So: die in the open world, and every cached candidate is marked "you are
-- dead -- this is for after". Resurrect, and the adjuster stops applying the
-- penalty -- but the sentence stays, because appending was the only operation
-- there was. `/cn why` then told a living player their recommendation was for
-- later, and for a provider that rarely rebuilds it said so for hours.
function CN.ClearAdjusterReason(objective, key)
    if type(objective) ~= "table" or not objective.adjusterReasons then
        return false
    end

    local text = objective.adjusterReasons[key]

    if text == nil then
        return false
    end

    objective.adjusterReasons[key] = nil

    for index = #(objective.reasons or {}), 1, -1 do
        if objective.reasons[index] == text then
            table.remove(objective.reasons, index)
            break
        end
    end

    return true
end

function CN.InvalidateRanking()
    CN.rankingGeneration = (CN.rankingGeneration or 0) + 1
end

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

    -- WORTH AND COST ARE SUMMED SEPARATELY, AND ONLY WORTH IS MULTIPLIED.
    --
    -- Everything used to go into one running total which was then multiplied
    -- by the focus weighting and by the learned multiplier. That total
    -- crosses zero: travel is weighted -1 against a cost that reaches 40,
    -- while what finishing something is worth tops out around 8. So anything
    -- more than a few minutes away scored negative, and multiplying a
    -- negative by 2.0 pushes it DOWN.
    --
    -- `/cn mode quests` therefore ranked a distant quest twenty-seven points
    -- BELOW a distant pet -- the precise opposite of what the player asked
    -- for -- and the learned multiplier did the same thing in reverse,
    -- promoting the types it had decided you avoid, as long as they were far
    -- away. Both features were not merely weak at distance; they inverted.
    --
    -- Worth and cost are now kept apart. A focus doubles what a thing is
    -- worth to you. It does not double how far away it is, and it cannot
    -- reverse the sign of anything.
    local worth = 0

    worth = worth + (objective.completionValue      or 1) * w.completionValue
    worth = worth + (objective.unlockValue          or 0) * w.unlockValue
    worth = worth + (objective.limitedTimeBonus     or 0) * w.limitedTimeBonus

    -- A deadline the objective actually carries, weighted by how close it is.
    -- `expiresIn` is the established field name; providers that know a
    -- deadline already set it.
    if objective.expiresIn then
        worth = worth + CN.UrgencyBonus(objective.expiresIn) * CN.urgencyWeight
    end
    -- `objective.nearbyBonus` used to be summed here as a term of its own.
    -- Nothing ever set it. The WEIGHT is live -- it scales the batch bonus
    -- just below -- but the field was a third dead input alongside
    -- difficultyCost and dependencyCost.

    -- Everything else at the same place makes this stop worth more.
    if objective.hubSize and objective.hubSize > 1 then
        worth = worth + math.min(CN.batchBonusCap,
            (objective.hubSize - 1) * CN.batchBonusPerNeighbour) * w.nearbyBonus
    end
    worth = worth + (objective.userPreference       or 0) * w.userPreference
    worth = worth + (objective.characterSuitability or 0) * w.characterSuitability

    local cost = 0

    cost = cost + travel                          * w.travelCost
    cost = cost + (objective.estimatedTime or 0)  * w.estimatedTime

    if profile.types and objective.type and profile.types[objective.type] then
        worth = worth * profile.types[objective.type]
    end


    -- LAST, AND DELIBERATELY AFTER THE PROFILE.
    --
    -- Adjusters are how a module changes the ranking without this file having
    -- to know it exists. They run after the profile's own type weighting so
    -- that a focus the player CHOSE always outranks a habit something merely
    -- inferred -- "I am levelling tonight" must not be argued with by a
    -- counter.
    -- SCORING RUNS AGAIN AND AGAIN OVER THE SAME TABLES.
    --
    -- The candidate list is cached; ranking re-scores those same objective
    -- tables on every rebuild, and every zone route bumps the ranking
    -- generation. Adjusters that append to `objective.reasons` therefore
    -- appended once per rebuild, forever -- one objective was measured
    -- carrying sixty-two reasons after thirty rounds of ordinary play, and
    -- `/cn why` printed the same sentence sixty times.
    --
    -- This is the identical defect the decorator comment below records as
    -- fixed. The fix was applied to decorators and nobody looked at the
    -- adjuster path. So: mark where the objective's own reasons end, and let
    -- an adjuster append only if it has not already done so for this
    -- objective.
    for index = 1, #CN.scoreAdjusterOrder do
        local adjuster = CN.scoreAdjusters[CN.scoreAdjusterOrder[index]]

        if adjuster then
            -- ADJUSTERS SEE THE WORTH, NOT THE SIGNED TOTAL.
            --
            -- Every adjuster in this addon multiplies. Handing them a total
            -- that crosses zero meant a penalty of 0.8 RAISED the score of
            -- anything far enough away to be negative, and a preference of
            -- 1.25 lowered it. The contract is now "here is what this is
            -- worth; return what you think it is worth", which is what both
            -- of them were written to express.
            local adjusted = adjuster(objective, worth)

            -- An adjuster that returns nothing, or something that is not a
            -- number, is ignored rather than allowed to zero the score.
            if type(adjusted) == "number" then
                worth = adjusted
            end
        end
    end

    local score = worth + cost

    -- Kept for `/cn order`, which has to show the same arithmetic.
    objective.scoreWorth = worth
    objective.scoreCost  = cost

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
-- SHORTLISTS.
--
-- Several providers own a store with thousands of rows of which a handful are
-- ever actionable: three thousand achievements, of which the ones within two
-- criteria of done might number twelve. Walking all three thousand on every
-- rebuild -- which is what Achievements and Reputations each did, at nearly
-- three milliseconds apiece -- spends the overwhelming majority of that time
-- rejecting rows that were rejected identically last time.
--
-- A shortlist is that filtered subset, held against a revision number the
-- owning module bumps when it writes. Between writes the provider iterates
-- the short list; after a write it rebuilds once.
--
-- Deliberately keyed on an explicit revision rather than on a timestamp: a
-- store that changed twice inside one second must not serve a stale list, and
-- a store that has not changed for an hour must not rebuild on a clock.
local shortlists = {}

function CN.Shortlist(name, revision, build)
    local held = shortlists[name]

    if held and held.revision == revision then
        return held.list, false
    end

    local list = build() or {}

    shortlists[name] = { revision = revision, list = list }

    return list, true
end

function CN.ClearShortlist(name)
    if name then
        shortlists[name] = nil
    else
        shortlists = {}
    end
end

function CN.ShortlistState(name)
    local held = shortlists[name]

    return held and #held.list or nil, held and held.revision or nil
end

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
    filter     = -1,
}

CN.candidateCacheSeconds = 5

-- Per-provider timings, so a slow provider can be identified rather than
-- guessed at.
CN.providerTimings = CN.providerTimings or {}

-- What each provider dropped to stay inside its budget. Reported by
-- /cn perf, because a cap nobody can see reads as "that is everything".
CN.providerTruncation = CN.providerTruncation or {}

-- Readable from outside, because "did this event actually invalidate the
-- provider that asked for it" is the property that matters and nothing could
-- ask it. Nine declared-but-unwired events survived four releases behind that
-- gap.
function CN.ProviderState(name)
    return providerCache[name]
end

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

-- Anything that can change what is actionable.
--
-- SUBSCRIBED FROM WHAT THE PROVIDERS DECLARE, NOT FROM A LIST HERE.
--
-- This was a hand-written list of seventeen event names, and providers
-- registered with `events = { ... }` telling the invalidator which of them
-- they cared about. Two separate lists, one of which nobody was checking
-- against the other -- so five providers ended up declaring nine events that
-- nothing ever dispatched.
--
-- That is worse than declaring none at all: InvalidateCandidates skips a
-- provider that HAS an events table and was not named, so Orders and
-- Inventory, both non-volatile, never refreshed after login at all. A quest
-- item looted into your bags did not become a candidate. A crafting order you
-- collected stayed on the list until you reloaded.
--
-- The provider's declaration is now the only list. This file no longer has an
-- opinion about which events matter -- it asks.
--
-- Deferred to ADDON_LOADED because Scoring.lua loads long before the modules
-- that register providers; at the point this file executes, the registry is
-- empty.
CN.baseInvalidationEvents = {
    -- Events that must invalidate EVERYTHING regardless of who declared
    -- what: the world changed under all of them.
    "PLAYER_LEVEL_UP",
    "ZONE_CHANGED_NEW_AREA",
}

function CN.SubscribeToInvalidationEvents()
    local wanted = {}

    for _, event in ipairs(CN.baseInvalidationEvents) do
        wanted[event] = true
    end

    for _, provider in pairs(CN.candidateProviders) do
        for event in pairs(provider.events or {}) do
            wanted[event] = true
        end
    end

    local subscribed = {}

    for event in pairs(wanted) do
        table.insert(subscribed, event)
    end

    -- Sorted so the registration order is the same on every login, which
    -- matters only for making a bug report reproducible -- but that is
    -- exactly when it matters.
    table.sort(subscribed)

    for _, event in ipairs(subscribed) do
        CN:RegisterEvent(event, function()
            CN.InvalidateCandidates(event)
        end)
    end

    return subscribed
end

CN:OnInitialize(function()
    CN.SubscribeToInvalidationEvents()
end)

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
        -- RECORDED, NOT ONLY DEBUG-PRINTED.
        --
        -- `/cn errors` promises "anything that went wrong inside the addon
        -- this session", and the Errors module's own header names a failing
        -- candidate provider as the case it was written for -- while this,
        -- the actual site, routed to DebugPrint, which is off by default. So
        -- a provider that crashed contributed nothing, the list got shorter,
        -- and `/cn errors` said nothing had gone wrong.
        local errors = CN:GetModule("Errors")

        if errors and errors.Record then
            pcall(errors.Record, "provider:" .. name, tostring(result))
        end

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
                local errors = CN:GetModule("Errors")

                if errors and errors.Record then
                    pcall(errors.Record, "decorator:" .. name, tostring(err))
                end

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

        -- `volatile` USED TO DEFEAT `cooldown` ENTIRELY.
        --
        -- The volatile clause was a peer of the dirty clause rather than
        -- subordinate to `cooled`, so a provider declaring both was rebuilt
        -- every `candidateCacheSeconds` no matter what cooldown it asked for.
        -- The two providers that declare both -- `Waiting`, which walks the
        -- mail inbox, the bags, the heirlooms and the currency store, and
        -- `Instances`, which walks every saved lockout -- each asked for
        -- thirty seconds and got five, six times more often than declared,
        -- for as long as the main window stayed open.
        --
        -- Volatile means "this goes stale on its own even when nothing tells
        -- us". It does not mean "ignore what this provider costs".
        local stale = force
            or entry.candidates == nil
            or (entry.dirty and cooled)
            or (provider.volatile and cooled
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

    -- ONE OBJECTIVE, ONE ROW.
    --
    -- Each provider dedupes its own list; the aggregate simply concatenated
    -- them, so an objective two providers both know about appeared twice.
    -- The common case is a pinned goal: `/cn goal quest 12345` for a quest
    -- already in your log emits it from the Quests provider AND from the
    -- Goals provider, so `/cn list` showed the same quest on two lines.
    --
    -- Worse than cosmetic. `BuildZoneRoute` groups stops by position, and two
    -- copies of one objective share a position exactly -- so the hub reported
    -- a size of two for one real stop, and the batch bonus paid out for a
    -- batching that does not exist. `CN.FindCandidate` returned whichever
    -- copy `pairs` happened to reach first.
    --
    -- Merged rather than dropped: the higher completionValue wins and the
    -- reasons are unioned, so the pinned goal's "you asked for this" survives
    -- onto the row the owning provider built.
    local candidates = {}
    local byKey      = {}

    for name in pairs(CN.candidateProviders) do
        local list = providerCache[name] and providerCache[name].candidates

        if list then
            for index = 1, #list do
                local objective = list[index]
                local key       = objective and objective.type ~= nil
                    and objective.id ~= nil
                    and CN.ObjectiveKey(objective.type, objective.id)
                    or nil

                local existing = key and byKey[key]

                if existing then
                    if (objective.completionValue or 0)
                        > (existing.completionValue or 0) then

                        existing.completionValue = objective.completionValue
                    end

                    for _, reason in ipairs(objective.reasons or {}) do
                        local seen = false

                        for _, held in ipairs(existing.reasons or {}) do
                            if held == reason then
                                seen = true
                                break
                            end
                        end

                        if not seen then
                            existing.reasons = existing.reasons or {}
                            table.insert(existing.reasons, reason)
                        end
                    end
                else
                    if key then
                        byKey[key] = objective
                    end

                    candidates[#candidates + 1] = objective
                end
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

    local filterGeneration = CN.typeFilterGeneration or 0

    if ranked.list
        and ranked.generation == aggregate.generation
        and ranked.mode == mode
        and ranked.filter == filterGeneration
        and ranked.ranking == (CN.rankingGeneration or 0) then

        return ranked.list
    end

    -- Sorting a copy, not the aggregate. Callers that walk the candidate
    -- list -- zone routing, for one -- must not have it reordered under
    -- them as a side effect of somebody asking for a recommendation.
    -- The type filter is a display preference, applied here rather than in the
    -- providers. Filtering earlier would mean rebuilding providers whenever it
    -- changed, and would leak a presentation choice into data collection --
    -- /cn breakdown and the Collections tab must still see everything.
    local list = {}

    for index = 1, #candidates do
        local objective = candidates[index]

        CN.ScoreObjective(objective)

        -- A DISPLAY PREFERENCE CANNOT HIDE YOUR OWN BODY.
        --
        -- The type filter is what a player chose to be shown. The corpse is
        -- not a kind of content they can have an opinion about -- while they
        -- are a ghost it is the only actionable thing there is, and a filter
        -- set weeks ago should not be able to suppress it.
        if objective.corpse
            or not CN.IsObjectiveTypeEnabled
            or CN.IsObjectiveTypeEnabled(objective.type) then

            list[#list + 1] = objective
        end
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
    ranked.filter     = filterGeneration
    ranked.ranking    = CN.rankingGeneration or 0

    return list
end

CN.RankedCandidates = Ranked

-- The live candidate for a type and id, or nil.
--
-- Chains reference objectives by identity rather than by value, because the
-- interesting thing about a step is usually where it currently IS -- and that
-- moves. Looking it up at navigation time gets the coordinates the providers
-- have now, instead of the ones they had when the chain was drawn.
function CN.FindCandidate(objectiveType, id)
    if not objectiveType or not id then
        return nil
    end

    for _, objective in ipairs(CN.CollectCandidates() or {}) do
        if objective.type == objectiveType and objective.id == id then
            return objective
        end
    end

    return nil
end

-- Things that want to know what was actually put in front of the player, as
-- opposed to what the addon merely knows about.
--
-- The distinction is not pedantic. Duration learning hung off a candidate
-- decorator in 0.28.0 and therefore timed all two hundred candidates on every
-- rebuild, including the hundred and seventy nobody ever saw. A hook here
-- runs on the handful that were genuinely shown.
CN.recommendationHooks = CN.recommendationHooks or {}

function CN.RegisterRecommendationHook(name, handler)
    CN.recommendationHooks[name] = handler
end

function CN.Recommend(limit)
    limit = limit or 1

    local list = Ranked()

    local results = {}

    for index = 1, math.min(limit, #list) do
        results[index] = list[index]
    end

    for _, handler in pairs(CN.recommendationHooks) do
        pcall(handler, results)
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

-- WHY IS THE LIST IN THIS ORDER?
--
-- `/cn why` has always explained ONE line: what is blocking it, what it is
-- worth. Nobody asks that first. The first question anybody asks of a ranked
-- list is why the thing at the top is at the top, and specifically why it is
-- above the thing they expected to see there -- which is a question about two
-- objectives and the weights between them, and the addon could not answer it
-- at all.
--
-- This takes the scoring apart for one objective and shows every term that
-- contributed, biggest first, with the weight applied. It is the same
-- arithmetic ScoreObjective does; if the two ever disagree, this is wrong.
function CN.ExplainScore(objective)
    if type(objective) ~= "table" then
        return {}
    end

    local settings = CN.Settings()
    local mode     = (settings and settings.priorityMode) or "balanced"
    local profile  = CN.priorityProfiles[mode] or {}

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

    local terms = {
        { label = "what finishing it is worth",
          value = (objective.completionValue or 1) * w.completionValue },
        { label = "what it unlocks",
          value = (objective.unlockValue or 0) * w.unlockValue },
        { label = "limited time",
          value = (objective.limitedTimeBonus or 0) * w.limitedTimeBonus },
        { label = "your stated preference",
          value = (objective.userPreference or 0) * w.userPreference },
        { label = "suits this character",
          value = (objective.characterSuitability or 0) * w.characterSuitability },
        { label = "getting there",
          value = travel * w.travelCost },
        { label = "how long it takes",
          value = (objective.estimatedTime or 0) * w.estimatedTime },
    }

    if objective.expiresIn then
        table.insert(terms, {
            label = "deadline",
            value = CN.UrgencyBonus(objective.expiresIn) * CN.urgencyWeight,
        })
    end

    if objective.hubSize and objective.hubSize > 1 then
        table.insert(terms, {
            label = "batches with " .. (objective.hubSize - 1) .. " other thing(s)",
            value = math.min(CN.batchBonusCap,
                (objective.hubSize - 1) * CN.batchBonusPerNeighbour) * w.nearbyBonus,
        })
    end

    -- THE TWO STEPS THIS USED TO LEAVE OUT.
    --
    -- The comment above this function promises "the same arithmetic
    -- ScoreObjective does; if the two ever disagree, this is wrong". They
    -- disagreed. ScoreObjective multiplies the running total by the profile's
    -- type weighting and then hands it to every registered adjuster; neither
    -- appeared here. So `/cn mode quests` printed a headline of 6.0 above a
    -- list of terms summing to 3.0, and any release where the Group or
    -- Preference adjuster fired did the same in balanced mode.
    --
    -- Both are multiplicative on the whole score rather than additive terms,
    -- so they are shown as what they are: a line saying what the running
    -- total was multiplied by, and by how much it moved the number.
    -- THE SAME SPLIT THE SCORER MAKES.
    --
    -- Worth is multiplied; cost is not. Explaining it any other way would put
    -- this function back in disagreement with ScoreObjective, which is the
    -- thing its own comment promises cannot happen.
    local costLabels = {
        ["getting there"]      = true,
        ["how long it takes"]  = true,
    }

    local worth, cost = 0, 0

    for _, term in ipairs(terms) do
        if costLabels[term.label] then
            cost = cost + term.value
        else
            worth = worth + term.value
        end
    end

    if profile.types and objective.type and profile.types[objective.type] then
        local factor = profile.types[objective.type]

        local after = worth * factor

        table.insert(terms, {
            label = string.format("%s focus (what it is worth x%.2f)",
                mode, factor),
            value = after - worth,
        })

        worth = after
    end

    for index = 1, #CN.scoreAdjusterOrder do
        local name = CN.scoreAdjusterOrder[index]

        local adjuster = CN.scoreAdjusters[name]

        if adjuster then
            local adjusted = adjuster(objective, worth)

            if type(adjusted) == "number" then
                if math.abs(adjusted - worth) > 0.0005 then
                    table.insert(terms, {
                        label = name .. " adjustment",
                        value = adjusted - worth,
                    })
                end

                worth = adjusted
            end
        end
    end

    local kept = {}

    for _, term in ipairs(terms) do
        if math.abs(term.value) > 0.001 then
            table.insert(kept, term)
        end
    end

    table.sort(kept, function(a, b)
        return math.abs(a.value) > math.abs(b.value)
    end)

    return kept
end

CN:RegisterCommand{
    name    = "urgency",
    order   = 18,
    help    = "How much a deadline is worth, at every distance from it.",
    handler = function()
        -- THE CURVE HAS NEVER BEEN LOOKED AT, ONLY REASONED ABOUT.
        --
        -- It has two ramps, four constants, and an exponent, and the only way
        -- to know what it does at four hours was to work it out on paper. A
        -- shape nobody can see is a shape nobody can question -- and this one
        -- decides the order of the list.
        local points = {
            { label = "1 minute",  seconds = 60 },
            { label = "10 minutes", seconds = 600 },
            { label = "30 minutes", seconds = 1800 },
            { label = "1 hour",    seconds = 3600 },
            { label = "2 hours",   seconds = 7200 },
            { label = "6 hours",   seconds = 21600 },
            { label = "1 day",     seconds = 86400 },
            { label = "3 days",    seconds = 3 * 86400 },
            { label = "6 days",    seconds = 6 * 86400 },
            { label = "8 days",    seconds = 8 * 86400 },
        }

        CN.Print("What a deadline is worth, by how far away it is:")

        local width = 30

        for _, point in ipairs(points) do
            local value = CN.UrgencyBonus(point.seconds)

            local scaled = math.floor((value / (1 + CN.urgencyLongShare))
                * width + 0.5)

            CN.Print(string.format("  %-11s |cff5dd2fb%s|r|cff444444%s|r %.2f",
                point.label,
                string.rep("=", scaled),
                string.rep("-", width - scaled),
                value))
        end

        CN.Print("|cff999999Multiplied by " .. CN.urgencyWeight
            .. " and added to the score. The steep ramp starts at "
            .. math.floor(CN.urgencyHorizonSeconds / 3600)
            .. " hours; the shallow one at "
            .. math.floor(CN.urgencyLongHorizonSeconds / 86400) .. " days.|r")
    end,
}

CN:RegisterCommand{
    name    = "order",
    aliases = { "ranking" },
    args    = "[how many]",
    order   = 17,
    help    = "Why the list is in the order it is in.",
    handler = function(args)
        local asked  = tonumber(CN.Trim(args or ""))
        local wanted = math.max(1, math.min(5, asked or 3))

        -- A CAP NOBODY IS TOLD ABOUT READS AS A WRONG ANSWER.
        --
        -- `args = "[how many]"` implies the number is honoured; `/cn order
        -- 20` silently gave five. Five is the right ceiling -- this prints a
        -- full score breakdown per row -- but saying so costs one line.
        if asked and asked > wanted then
            CN.Print("|cff999999Showing " .. wanted .. ": the breakdown is "
                .. "long, so this tops out there. |cffffff00/cn list "
                .. asked .. "|r|cff999999 gives the plain ranking.|r")
        end

        local results = CN.Recommend(wanted)

        if #results == 0 then
            CN.Print("Nothing is being recommended, so there is no order to "
                .. "explain.")
            return
        end

        local settings = CN.Settings()

        CN.Print("Focus: |cffffff00"
            .. tostring((settings and settings.priorityMode) or "balanced")
            .. "|r")

        for index, objective in ipairs(results) do
            CN.Print(string.format("%d. |cffffffff%s|r |cff999999%.1f|r",
                index, tostring(objective.name or objective.id),
                objective.priorityWeight or 0))

            for _, term in ipairs(CN.ExplainScore(objective)) do
                CN.Print(string.format("     %s%+.1f|r  %s",
                    term.value >= 0 and "|cff73b873" or "|cfff56b61",
                    term.value, term.label))
            end
        end

        CN.Print("|cff999999Every line above is a term in the same sum. "
            .. "|cffffff00/cn mode|r changes the weights; |cffffff00/cn why|r "
            .. "explains one objective in detail.|r")
    end,
}

------------------------------------------------------------
-- COMMAND
------------------------------------------------------------

-- ONE EXPLANATION FOR AN EMPTY LIST, USED BY EVERY SURFACE THAT SHOWS ONE.
--
-- There were four, and they disagreed. `/cn next` said "quests are the only
-- subsystem currently online" -- a leftover from an early build that has been
-- false since the second release and is very likely the first sentence a new
-- player ever reads from this addon. `/cn zone` named two of eleven scans.
-- The window named the type filter. The broker and the minimap said "Run /cn
-- setup once" whether or not setup had run.
--
-- Worse, none of them could tell an empty list from a broken engine: a
-- provider that throws contributes nothing, and nothing looks exactly like
-- "you have done everything".
--
-- Returns an array of lines, most useful first.
function CN.ExplainEmptyList()
    local lines = {}

    local filters = CN:GetModule("Filters")
    local hidden  = filters and filters.HiddenTypeCount and filters.HiddenTypeCount() or 0

    if hidden > 0 then
        table.insert(lines, hidden .. " objective type"
            .. (hidden == 1 and " is" or "s are")
            .. " hidden by your filter. /cn show lists them.")
    end

    -- A FAILURE IS NOT AN EMPTY RESULT, AND MUST NOT READ AS ONE.
    local errors = CN:GetModule("Errors")

    local failures = errors and errors.Count and errors.Count() or 0

    if failures > 0 then
        table.insert(lines, failures .. " thing"
            .. (failures == 1 and " has" or "s have")
            .. " gone wrong inside the addon this session, which is enough "
            .. "to empty this list. /cn errors has the detail.")
    end

    local setup = CN:GetModule("Setup")

    if setup and setup.HasRun and not setup.HasRun() then
        table.insert(lines, "Nothing has been scanned yet. /cn setup reads "
            .. "everything the client will answer for on its own.")
    elseif #lines == 0 then
        table.insert(lines, "Every provider answered and none of them had "
            .. "anything to offer, which usually means you are between "
            .. "things: try a different zone, or /cn waiting for what is on "
            .. "a timer.")
    end

    return lines
end

CN:RegisterCommand{
    name    = "next",
    order   = 10,
    help    = "Recommend the next objective.",
    handler = function()
        local results = CN.Recommend(1)

        if #results == 0 then
            CN.Print("No actionable objectives are known yet.")

            for _, line in ipairs(CN.ExplainEmptyList()) do
                CN.Print("|cff999999" .. line .. "|r")
            end
            return
        end

        local objective = results[1]

        CN.currentRecommendation = objective

        -- SAY IT FIRST WHEN THE PLAYER CANNOT ACT ON THE ANSWER.
        --
        -- Recommending a battle pet to a corpse is the clearest possible
        -- signal that the addon is not watching. The line goes above the
        -- recommendation rather than below it, because it changes how to read
        -- what follows.
        local group = CN:GetModule("Group")

        local notice = group and group.Notice()

        if notice then
            CN.Print("|cffffd100" .. notice .. "|r")
        end

        CN.Print("Recommended next: " .. tostring(objective.name or objective.id)
            .. " |cff999999(" .. CN.TypeLabel(objective.type) .. ")|r")

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
                .. " |cff999999[" .. CN.TypeLabel(objective.type)
                .. " " .. string.format("%.1f", objective.priorityWeight or 0) .. "]|r")
        end
    end,
}
