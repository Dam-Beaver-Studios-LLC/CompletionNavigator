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

-- WHAT A JOURNEY THE ADDON CANNOT COST IS CHARGED.
--
-- Raised from 3 in 0.57.0, and split from "this is not anywhere" -- see
-- `CN.IsPlaceless`. At 3 it was CHEAPER than the far side of the player's own
-- zone, which costs about 3.3, so "I have no idea where this is" outranked
-- "I can see it from here" and twenty of the top thirty recommendations had
-- no coordinates on them.
--
-- `Travel.CostFor` already reasons this out for a journey it cannot compute
-- and lands on the pessimistic answer. This is the same question about the
-- same kind of ignorance, so it gets the same shape of answer: comfortably
-- above a zone crossing, comfortably below the cross-continent ceiling of 40.
CN.unknownLocationCost = 8

-- And a thing that is not ANYWHERE is not a journey at all.
CN.placelessCost = 0

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

------------------------------------------------------------
-- WHY SOMETHING IS ON THE LIST
------------------------------------------------------------

-- THREE RELEASES IN A ROW BROKE THIS, SO THE SHAPE IS WRONG.
--
-- Every reason -- the provider's own, a decorator's, the aggregate's, an
-- adjuster's -- was appended to one array on the objective. Four writers with
-- four different lifetimes sharing one list, and each of them had to know
-- where its own entries began and ended in order to take them back.
--
-- That produced, in three consecutive releases: sentences repeated once per
-- rebuild; sentences deleted and unrestorable because the key that said "I
-- already said this" outlived the sentence itself; a quest collecting every
-- state it had ever been in; and an unlock count frozen because a rollback
-- nilled half its bookkeeping. Every one was a different symptom of the same
-- cause -- BOUNDARY INDICES INTO A SHARED, MUTATING ARRAY.
--
-- So the array is not shared any more.
--
--   objective.reasons          what the PROVIDER said. Written once, when the
--                              provider builds the row, and never touched by
--                              anything downstream.
--   objective.decoratorReasons keyed, owned by decorators
--   objective.adjusterReasons  keyed, owned by adjusters
--   objective.mergedReasons    a list, rebuilt by the aggregate on every pass
--
-- Nothing writes into anything it does not own, so nothing has to know where
-- anything else's entries are, so there is no index to go stale. `CN.Reasons`
-- composes the four at READ time, which is the only moment the answer is
-- actually wanted.
--
-- Adding a fifth source is now a table and two lines here, rather than a
-- fifth boundary counter and a fourth rollback.

-- Keyed sources, in the order they read best: what it is, then what the
-- addon worked out about it, then what another provider added, then what is
-- true of your situation right now.
local REASON_SOURCES = { "decoratorReasons", "mergedReasons", "adjusterReasons" }

local function Record(objective, field, key, text)
    if type(objective) ~= "table" or not text then
        return false
    end

    objective[field] = objective[field] or {}

    if objective[field][key] == text then
        return false
    end

    -- SAME KEY, DIFFERENT SENTENCE, IS AN UPDATE.
    --
    -- A sentence that carries a NUMBER froze at whatever the number was the
    -- first time: three party members leaving one at a time left "3 others
    -- here are on this quest" on screen while the ranking tracked the truth.
    -- Assignment rather than append means that cannot happen again.
    objective[field][key] = text

    return true
end

local function Withdraw(objective, field, key)
    local held = objective and objective[field]

    if type(held) ~= "table" or held[key] == nil then
        return false
    end

    held[key] = nil

    return true
end

-- Every sentence that applies, in one list, composed fresh.
--
-- Every surface that shows a reason calls this: `/cn why`, the tooltip, the
-- heads-up line, the Remaining tab, the Journey tab and `/cn breakdown`. A
-- surface that read `objective.reasons` directly would see the provider's
-- half and none of the rest -- so there is exactly one way to ask.
function CN.Reasons(objective)
    if type(objective) ~= "table" then
        return {}
    end

    local composed = {}

    for _, reason in ipairs(objective.reasons or {}) do
        composed[#composed + 1] = reason
    end

    for _, field in ipairs(REASON_SOURCES) do
        local held = objective[field]

        if type(held) == "table" then
            -- Sorted by key, so the same objective reads the same way twice
            -- running. `pairs` order is not an order.
            local keys = {}

            for key in pairs(held) do
                keys[#keys + 1] = key
            end

            table.sort(keys)

            for _, key in ipairs(keys) do
                composed[#composed + 1] = held[key]
            end
        end
    end

    return composed
end

-- WHAT FINISHING IT IS WORTH, INCLUDING WHAT ANOTHER PROVIDER SAYS.
--
-- Two providers can know about the same objective and disagree about what it
-- is worth -- a quest in your log that is also a pinned goal, an appearance
-- that is also part of a nearly-finished set. The aggregate takes the higher
-- of the two, and records it separately rather than writing it into the
-- provider's own row: a number another provider contributed is not this
-- provider's answer, and it has to be able to go away when that provider
-- changes its mind.
function CN.CompletionValue(objective)
    if type(objective) ~= "table" then
        return 1
    end

    local own = objective.completionValue or 1

    local merged = objective.mergedCompletionValue

    if merged and merged > own then
        return merged
    end

    return own
end

-- The first sentence, which is what the tooltip and the heads-up line show.
-- Cheaper than composing the whole list for one string.
function CN.FirstReason(objective)
    if type(objective) ~= "table" then
        return nil
    end

    local own = objective.reasons

    if own and own[1] then
        return own[1]
    end

    return CN.Reasons(objective)[1]
end

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
    return Record(objective, "adjusterReasons", key, text)
end

function CN.ClearAdjusterReason(objective, key)
    return Withdraw(objective, "adjusterReasons", key)
end

------------------------------------------------------------
-- THE SAME THING, FOR DECORATORS
------------------------------------------------------------

-- Decorators need the identical contract, for the identical reason: their
-- output lives on objectives that outlive the fact it describes.
function CN.AddDecoratorReason(objective, key, text)
    return Record(objective, "decoratorReasons", key, text)
end

function CN.ClearDecoratorReason(objective, key)
    return Withdraw(objective, "decoratorReasons", key)
end

function CN.InvalidateRanking()
    CN.rankingGeneration = (CN.rankingGeneration or 0) + 1
end

local weightCache = {}

-- Also cleared whenever the weights themselves are replaced, which the test
-- suite does and a future settings surface might.
function CN.ForgetScoreWeights()
    weightCache = {}
end

local function EffectiveWeights(mode, profile)
    local held = weightCache[mode]

    if held then
        return held
    end

    local w = {}

    for key, value in pairs(CN.scoreWeights) do
        w[key] = value
    end

    if profile.weights then
        for key, value in pairs(profile.weights) do
            w[key] = value
        end
    end

    weightCache[mode] = w

    return w
end

function CN.ScoreObjective(objective)
    if type(objective) ~= "table" then
        return 0
    end

    local settings = CN.Settings()
    local mode     = (settings and settings.priorityMode) or "balanced"
    local profile  = CN.priorityProfiles[mode] or {}

    -- MEMOISED ON THE MODE, BECAUSE THAT IS ALL IT DEPENDS ON.
    --
    -- This copied eight keys out of the defaults and eight more out of the
    -- profile, per objective. Measured over a hundred and fifty candidates it
    -- was 28% of the entire scoring pass -- a hundred and fifty table
    -- allocations to produce a hundred and fifty identical tables.
    --
    -- The effective weights are a function of `priorityMode` and nothing
    -- else, so they are built once per mode and reused. Changing the mode
    -- already invalidates the candidates, and the cache key is the mode
    -- itself, so a stale table is not reachable.
    local w = EffectiveWeights(mode, profile)

    local travel = objective.travelCost

    if travel == nil then
        travel = CN.IsPlaceless(objective)
            and CN.placelessCost
            or CN.unknownLocationCost
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

    worth = worth + CN.CompletionValue(objective) * w.completionValue
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
    -- `CN.batchSizes`, not `objective.hubSize`: batching belongs to the
    -- router and to one map, and writing it onto shared candidate tables is
    -- what let panning the world map strip it off the zone you are in. See
    -- the header above `Publish` in Routing.lua.
    local batched = CN.batchSizes[objective]

    if batched and batched > 1 then
        worth = worth + math.min(CN.batchBonusCap,
            (batched - 1) * CN.batchBonusPerNeighbour) * w.nearbyBonus
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
            -- GUARDED, LIKE EVERY OTHER CALLBACK IN THE ADDON.
            --
            -- Providers, decorators, recommendation hooks, quest data
            -- providers, breakdown categories, self-tests and tab builders
            -- are all pcall'd. Adjusters were the one exception, and they sit
            -- on the hottest path: a throw here propagates out of
            -- `ScoreObjective`, out of `Ranked()`, and out to the command
            -- boundary -- where it is caught, so `/cn next` prints an error
            -- and returns an EMPTY LIST, which is indistinguishable from
            -- "you have done everything". Nothing is recorded, so
            -- `ExplainEmptyList` cannot say otherwise either.
            local ok, adjusted = pcall(adjuster, objective, worth)

            if not ok then
                local errors = CN:GetModule("Errors")

                if errors and errors.Record then
                    pcall(errors.Record,
                        "adjuster:" .. tostring(CN.scoreAdjusterOrder[index]),
                        tostring(adjusted))
                end

                adjusted = nil
            end

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

-- ORDERED BY REGISTRATION, for the same reason the adjusters are.
--
-- `CollectCandidates` walked `pairs(CN.candidateProviders)`, so when two
-- providers emit the same objective the winner was decided by hash order --
-- which differs between clients, between sessions, and between Lua versions.
-- Two players with the same data got different lists, and neither could be
-- told why.
--
-- It matters more here than for adjusters, because the aggregate's dedup
-- keeps the FIRST row it meets and merges only two fields from the loser: the
-- coordinates, the travel cost and the expiry of whichever provider lost were
-- discarded. `Opportunities` and `Quests` both emit a world quest -- one with
-- coordinates and an expiry, the other with a phase and a state -- and which
-- half survived was a coin toss.
CN.candidateProviderOrder = CN.candidateProviderOrder or {}

function CN.RegisterCandidateProvider(name, provider, options)
    options = options or {}

    -- VALIDATED. This stored anything, so a provider registered with a nil
    -- function failed inside `pcall` every five seconds forever, recorded
    -- once and counted thereafter -- and `ExplainEmptyList` then blamed the
    -- empty list on the addon in general.
    if type(name) ~= "string" or type(provider) ~= "function" then
        local errors = CN:GetModule("Errors")

        if errors and errors.Record then
            pcall(errors.Record, "RegisterCandidateProvider",
                "refused a provider called " .. tostring(name)
                .. " because it is not a function")
        end

        return false
    end

    local events

    if options.events then
        events = {}

        for _, event in ipairs(options.events) do
            events[event] = true
        end
    end

    if not CN.candidateProviders[name] then
        table.insert(CN.candidateProviderOrder, name)
    end

    CN.candidateProviders[name] = {
        name     = name,
        fn       = provider,
        events   = events,
        volatile = options.volatile and true or false,
        cooldown = options.cooldown,
    }

    -- A PROVIDER REGISTERED AFTER LOGIN STILL GETS ITS EVENTS.
    --
    -- The subscription pass runs once, at initialisation, and wires every
    -- event every provider declared. A provider registered later was never
    -- subscribed -- and because `InvalidateCandidates(reason)` skips any
    -- provider that HAS an events table and was not named, its declared
    -- events were its only invalidation path. It refreshed only if it also
    -- declared `volatile`, and otherwise never at all.
    --
    -- The header on the subscription pass describes this exact failure as
    -- fixed. The fix closed the registry instead of opening it.
    if CN.subscribedToInvalidation and CN.SubscribeToInvalidationEvents then
        CN.SubscribeToInvalidationEvents()
    end

    return true
end

-- Decorators get a pass over every candidate after collection and before
-- scoring. This is how cross-cutting concerns -- Warband suitability, for
-- one -- apply to objectives from modules that know nothing about them.
CN.candidateDecorators = CN.candidateDecorators or {}

-- A NEW DECORATOR HAS TO REACH OBJECTIVES THAT ALREADY EXIST.
--
-- Since 0.54.0 a provider whose rebuild produces an identical list keeps the
-- objective tables it already had, rather than re-decorating fresh ones --
-- which is most of the point, since seven providers expire on a five-second
-- clock and almost always return the same rows.
--
-- But a decorator registered AFTER those tables were built would then never
-- see them: the list never differs, so the tables are never replaced, so
-- nothing is decorated. Every module that registers one does so at load, so
-- this only bites the test suite and anything registering late -- which is
-- exactly the kind of "works everywhere except where somebody looks" defect
-- this project keeps finding.
--
-- The generation moves when the set of decorators does, and a provider whose
-- cached objectives predate it is rebuilt properly.
CN.decoratorGeneration = 0

function CN.RegisterCandidateDecorator(name, decorator)
    if type(name) == "string" and type(decorator) == "function" then
        if not CN.candidateDecorators[name] then
            table.insert(CN.candidateDecoratorOrder, name)
        end

        CN.candidateDecorators[name] = decorator

        CN.decoratorGeneration = CN.decoratorGeneration + 1

        return true
    end

    return false
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

-- IDEMPOTENT, so a provider registering after login can call it again.
--
-- The event registry already allows many handlers per event, so subscribing
-- twice would fire the invalidation twice -- which is harmless but wasteful,
-- and would grow without bound if a module registered providers in a loop.
-- Tracked, so only genuinely new events are wired.
CN.subscribedInvalidationEvents = CN.subscribedInvalidationEvents or {}

function CN.SubscribeToInvalidationEvents()
    CN.subscribedToInvalidation = true

    local wanted = {}

    for _, event in ipairs(CN.baseInvalidationEvents) do
        wanted[event] = true
    end

    for _, provider in pairs(CN.candidateProviders) do
        for event in pairs(provider.events or {}) do
            wanted[event] = true
        end
    end

    for event in pairs(CN.subscribedInvalidationEvents) do
        wanted[event] = nil
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
        CN.subscribedInvalidationEvents[event] = true

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
-- ONE BAD OBJECTIVE COSTS ONE OBJECTIVE.
--
-- The `break` here exited the CANDIDATES loop, not the decorator loop, so a
-- decorator that threw on the third of forty candidates left the other
-- thirty-seven undecorated -- and `Errors.Record` deduplicates, so it looked
-- like one isolated failure rather than thirty-seven silent ones.
--
-- That is not cosmetic: `Session`'s decorator sets `estimatedTime` and
-- `Warband`'s sets `characterSuitability`, both of which are scored. The
-- undecorated tail was scored as though every task were instant and no
-- character were better suited, and outranked the head of its own list.
--
-- Ordered by registration for the same reason the providers and adjusters
-- are: three decorators writing disjoint fields is true today and is not a
-- contract.
CN.candidateDecoratorOrder = CN.candidateDecoratorOrder or {}

-- HOW MANY REASONS THE PROVIDER ITSELF WROTE.
--
-- `Identical` compares a freshly built, UNDECORATED list against a previous,
-- DECORATED one, so anything a decorator adds makes every comparison fail --
-- and the whole reuse shortcut, which is worth 0.2 ms every five seconds,
-- silently stops working for that provider. Recording the boundary lets the
-- comparison ask the only question it actually means: did the PROVIDER change
-- its answer?
--
-- Decorators only ever append, so a count is enough.
-- NOTHING TO ROLL BACK ANY MORE.
--
-- `MarkProviderReasons` and `MarkDecorated` lived here. They recorded where
-- the provider's own sentences ended, truncated back to that boundary before
-- re-decorating, and then had to nil every piece of bookkeeping keyed to the
-- list they had just cut. Three releases in a row shipped a defect from that
-- arrangement, each a different way for a boundary index to go stale.
--
-- Since the derived sentences live in their own tables now (see CN.Reasons),
-- a decorator that runs twice simply assigns the same key twice, and there is
-- nothing to cut, nothing to count, and nothing to reset.

local function Decorate(candidates)

    for _, name in ipairs(CN.candidateDecoratorOrder) do
        local decorator = CN.candidateDecorators[name]

        if decorator then
            local failures = 0

            for index = 1, #candidates do
                local ok, err = pcall(decorator, candidates[index])

                if not ok then
                    failures = failures + 1

                    -- Recorded once per pass with a count, rather than once
                    -- per objective: forty identical entries would push
                    -- everything else out of the ring buffer.
                    if failures == 1 then
                        local errors = CN:GetModule("Errors")

                        if errors and errors.Record then
                            pcall(errors.Record, "decorator:" .. name,
                                tostring(err))
                        end

                        CN.DebugPrint("Candidate decorator " .. name
                            .. " failed: " .. tostring(err))
                    end
                end
            end

            if failures > 1 then
                CN.DebugPrint("Candidate decorator " .. name .. " failed on "
                    .. failures .. " of " .. #candidates .. " objectives.")
            end
        end
    end

end

-- Cheap enough to be worth doing before a full re-rank: one pass over one
-- provider's output, which is capped, against scoring and sorting every
-- candidate in the addon.
--
-- REWRITTEN IN 0.55.0, BECAUSE 0.54.0's VERSION WAS WRONG.
--
-- The original compared five fields and, on a match, kept the PREVIOUS tables
-- and discarded the ones the provider had just built. That is only sound if
-- the compared fields are the only ones a consumer reads. They were not, and
-- one of the five did not exist at all.
--
-- What it missed:
--
--   * `travelCost`. Providers recompute it on every build, and the scorer
--     reads it without recomputing. So a rebuild triggered by walking into a
--     new zone -- which is when travel costs change most -- was thrown away
--     precisely because the quest set had not changed. Costs were measured
--     once, at the first build, and survived the session.
--   * `expiresIn`, which drives the urgency term at the heaviest weight in
--     the table. A world quest froze the value it had when it entered its
--     current urgency bucket, so the steep last-hour ramp never fired.
--   * `mapID`, `x`, `y`. A quest whose coordinates resolve from nil to real
--     kept the nil, so the waypoint and the map pin pointed at nothing.
--   * `name`. A title the client caches a moment later stayed "Quest 84321".
--   * `phase`. PICKUP to ACTIVE changes no other compared field, so the hub
--     kept sorting by the old one.
--
-- And `urgency` is not a field. Nothing in the addon has ever written one:
-- the comparison was `nil ~= nil`, a dead clause standing exactly where
-- `expiresIn` should have been.
--
-- So: compare everything the scorer, the router and the display actually
-- read. That is a longer list and it means the shortcut fires less often --
-- notably not at all while the player is moving, which is the honest answer,
-- because that is exactly when the re-score is needed.
--
-- The optimisation still earns its place. Standing still with the window
-- open, which is the case it was written for, every volatile provider still
-- short-circuits.
-- WHAT THE PROVIDER SAID, AND NOTHING ELSE.
--
-- `unlockValue` and `hubSize` were in this list and are written by a
-- DECORATOR and by `BuildZoneRoute` respectively -- after the build, onto the
-- objects in the previous list. The fresh list therefore always had nil where
-- the previous one had a number, every comparison failed, and the reuse
-- shortcut could never fire for any provider whose rows had been routed or
-- carried an unlock count. The optimisation was present, documented, measured
-- -- and off, which is this project's most repeated defect.
--
-- Both are RESTORED by the reuse rather than lost by it: reusing the previous
-- table keeps the decoration that is already on it, which is the whole point.
local IDENTITY_FIELDS = {
    "type", "id", "name", "phase", "state",
    "completionValue", "limitedTimeBonus", "expiresIn",
    "travelCost", "mapID", "x", "y",
    "accountWide",
}

local function Identical(left, right)
    if #left ~= #right then
        return false
    end

    for index = 1, #left do
        local a, b = left[index], right[index]

        -- A provider is allowed to be wrong; it is not allowed to take
        -- `CN.CollectCandidates` down with it, and this is not inside a
        -- pcall.
        if type(a) ~= "table" or type(b) ~= "table" then
            return false
        end

        for _, field in ipairs(IDENTITY_FIELDS) do
            if a[field] ~= b[field] then
                return false
            end
        end

        -- Reasons are what `/cn why` prints, and a provider that changes its
        -- mind about why something is worth doing has changed the answer.
        --
        -- ONLY THE PROVIDER'S OWN, and now that is simply `a.reasons` --
        -- nothing downstream writes into it, so there is no boundary to
        -- count and no way for the count to be stale.
        local leftReasons  = a.reasons or {}
        local rightReasons = b.reasons or {}

        if #leftReasons ~= #rightReasons then
            return false
        end

        for reason = 1, #leftReasons do
            if leftReasons[reason] ~= rightReasons[reason] then
                return false
            end
        end
    end

    return true
end

local function RefreshProviders(force)
    local now     = time()
    local rebuilt = 0

    for _, name in ipairs(CN.candidateProviderOrder) do
        local provider = CN.candidateProviders[name]

        -- A provider can be removed from the table without being removed from
        -- the order -- the test suite does exactly that.
        if provider then

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
            local previous = entry.candidates

            entry.candidates = RunProvider(name, provider)

            -- A REBUILD THAT PRODUCED THE SAME LIST IS NOT A CHANGE.
            --
            -- `rebuilt > 0` bumps the aggregate generation, and the ranked
            -- list is keyed on that -- so one provider going stale forces a
            -- full re-score and re-sort of everything. Seven providers are
            -- volatile and expire on a five-second clock, and most of the
            -- time they return exactly the rows they returned before: a
            -- lockout with the same bosses left, a currency at the same
            -- quantity, the same rare still up.
            --
            -- Measured, that turned a 0.007 ms answer into a 0.221 ms one,
            -- every five seconds, for no change in what the player sees.
            --
            -- The header above `InvalidateCandidates` already reasons that a
            -- rebuild "may produce an identical list" and declines to clear
            -- the aggregate for that reason. This applies the same reasoning
            -- to the rebuild's own result.
            if previous
                and entry.decorated == CN.decoratorGeneration
                and Identical(previous, entry.candidates) then

                entry.candidates = previous
                entry.builtAt    = now
                entry.dirty      = false
                entry.urgent     = false

                -- Deliberately NOT counted as a rebuild.
                stale = false
            end
        end

        if stale then

            -- Decorate here, not over the aggregate: these objectives are
            -- new, and every other provider's are not.
            Decorate(entry.candidates)

            entry.builtAt   = now
            entry.dirty     = false
            entry.urgent    = false
            entry.decorated = CN.decoratorGeneration

            rebuilt = rebuilt + 1
        end

        end
    end

    return rebuilt
end


function CN.CollectCandidates(force)
    local rebuilt = RefreshProviders(force)

    -- HOW MANY PROVIDERS THERE ARE IS PART OF THE ANSWER.
    --
    -- "Nothing was rebuilt" used to be enough, because a provider that had
    -- gone away left its entry dirty and something always rebuilt. Since a
    -- rebuild producing an identical list no longer counts as a rebuild, that
    -- is no longer true: unregister a provider and every remaining one can
    -- legitimately report no change, leaving the departed provider's rows in
    -- the aggregate for the rest of the session.
    --
    -- Counting is O(providers), which is twenty-two, and it runs once per
    -- collect rather than once per candidate.
    local providerCount = 0

    for _ in pairs(CN.candidateProviders) do
        providerCount = providerCount + 1
    end

    -- Nothing was rebuilt and nothing came or went, so the aggregate cannot
    -- have changed.
    if aggregate.candidates
        and rebuilt == 0
        and aggregate.providers == providerCount then

        return aggregate.candidates
    end

    -- WHAT THE AGGREGATE CONTRIBUTED LAST TIME, RESET FOR EVERY ROW.
    --
    -- 0.57.0 reset only rows that were merged into AGAIN this pass, which
    -- misses the case the reset exists for: the losing provider STOPPING.
    -- Unpin a goal and the Goals provider stops emitting the quest -- so the
    -- quest is never an `existing` again, its merged sentence and merged
    -- value are never cleared, and because the reuse shortcut hands back the
    -- same table they stay for the rest of the session. Exactly the symptom
    -- the release notes claimed to have removed.
    --
    -- Reset on FIRST SIGHT of a row in this pass instead, wherever it is
    -- first seen, so a contribution that is no longer being made is gone
    -- whether or not anything else is still merging into it.
    local touched = {}

    local function Reset(objective)
        if touched[objective] then
            return
        end

        touched[objective]              = true
        objective.mergedReasons         = nil
        objective.mergedCompletionValue = nil
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

    -- REGISTRATION ORDER, NOT HASH ORDER.
    --
    -- The dedup below keeps the first row it meets, so which provider "wins"
    -- an objective two of them know about decided which coordinates, which
    -- travel cost and which expiry survived -- and `pairs` made that a
    -- different answer on different clients.
    for _, name in ipairs(CN.candidateProviderOrder) do
        -- Only providers that are still registered. The order array is
        -- append-only, so a provider removed from the table would otherwise
        -- keep contributing whatever its cache last held.
        local list = CN.candidateProviders[name]
            and providerCache[name]
            and providerCache[name].candidates

        if list then
            for index = 1, #list do
                local objective = list[index]
                local key       = objective and objective.type ~= nil
                    and objective.id ~= nil
                    and CN.ObjectiveKey(objective.type, objective.id)
                    or nil

                local existing = key and byKey[key]

                if objective then
                    Reset(objective)
                end

                if existing then
                    Reset(existing)

                    -- THE MERGE NEVER WRITES INTO THE PROVIDER'S OWN ROW.
                    --
                    -- It used to raise `existing.completionValue` in place
                    -- and append the loser's sentences to `existing.reasons`
                    -- -- into the winner's LIVE CACHED TABLE, with no way
                    -- back. Unpin a goal and the quest kept the pinned-era
                    -- value for the session; the losing provider could stop
                    -- emitting the row entirely and the number stayed. And
                    -- because the raised value then differed from the fresh
                    -- one every pass, that provider could never take the
                    -- unchanged-provider shortcut again -- measured: one
                    -- shipped provider rebuilt on 31 of 31 passes while the
                    -- player stood still, for a value it had not changed.
                    --
                    -- Both go in tables the aggregate owns, cleared at the
                    -- top of this pass, so a contribution that stops being
                    -- made simply stops appearing.
                    if (objective.completionValue or 0)
                        > (existing.completionValue or 0)
                        and (objective.completionValue or 0)
                            > (existing.mergedCompletionValue or 0) then

                        existing.mergedCompletionValue =
                            objective.completionValue
                    end

                    for _, reason in ipairs(objective.reasons or {}) do
                        local seen = false

                        for _, held in ipairs(existing.reasons or {}) do
                            if held == reason then
                                seen = true
                                break
                            end
                        end

                        for _, held in pairs(existing.mergedReasons or {}) do
                            if held == reason then
                                seen = true
                                break
                            end
                        end

                        if not seen then
                            existing.mergedReasons = existing.mergedReasons or {}

                            existing.mergedReasons[reason] = reason
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
    aggregate.providers  = providerCount
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
            --
            -- AND THE TIE IS THE COMMON CASE, NOT THE EDGE CASE. Measured on
            -- a real collection: 134 of 153 candidates share a score with an
            -- earlier one -- sixty pets all at -1.00, sixty reputations all
            -- at 2.00. So this ran 943 times per sort and built 1,886 strings
            -- to do it: 0.35 ms and 4.1 KB per re-rank, for a comparison that
            -- is two numbers in almost every case.
            --
            -- `tostring` only where the two ids are genuinely different
            -- shapes, which is a provider mixing numeric and string ids and
            -- is rare enough to pay for itself there.
            local leftID, rightID = a.id, b.id

            -- `type(nil) == type(nil)`, so two rows with no id reached
            -- `nil < nil` and threw -- taking `/cn next`, `/cn list`, the
            -- HUD, the broker and the Next tab with them. The string form
            -- this replaced was nil-safe by accident; this one has to be
            -- nil-safe on purpose.
            --
            -- No shipped provider emits a nil id, but
            -- `RegisterCandidateProvider` is published and several ids come
            -- straight out of client tables.
            if leftID == nil or rightID == nil then
                return rightID ~= nil
            end

            if type(leftID) == type(rightID) then
                return leftID < rightID
            end

            return tostring(leftID) < tostring(rightID)
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

    for _, reason in ipairs(CN.Reasons(objective)) do
        table.insert(lines, "- " .. reason)
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
        travel = CN.IsPlaceless(objective)
            and CN.placelessCost
            or CN.unknownLocationCost
    end

    local terms = {
        { label = "what finishing it is worth",
          value = CN.CompletionValue(objective) * w.completionValue },
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

    -- `CN.batchSizes`, like `ScoreObjective` fifteen hundred lines above.
    --
    -- This read `objective.hubSize`, which 0.59.0 stopped writing when
    -- batching moved onto a table the router owns -- so the batch term
    -- silently stopped appearing, AND the focus term below it, which is
    -- computed as `after - worth`, was wrong by the same amount. This
    -- function's own header says "It is the same arithmetic ScoreObjective
    -- does; if the two ever disagree, this is wrong."
    local batched = CN.batchSizes[objective]

    if batched and batched > 1 then
        table.insert(terms, {
            label = "batches with " .. (batched - 1)
              .. ((batched - 1) == 1 and " other thing"
                  or " other things"),
            value = math.min(CN.batchBonusCap,
                (batched - 1) * CN.batchBonusPerNeighbour) * w.nearbyBonus,
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

    -- YES, THIS RUNS THE ADJUSTERS AGAIN, AND IT HAS TO.
    --
    -- An adjuster is a function of the objective and the running total; there
    -- is nowhere else its contribution is recorded, so the only way to show
    -- the player what it did is to ask it. The alternative -- caching each
    -- adjuster's delta at scoring time -- would put a second copy of the
    -- number in the objective and reintroduce exactly the drift this function
    -- was fixed to remove.
    --
    -- The contract that makes it safe is that an adjuster must be idempotent
    -- and must not accumulate: both shipped adjusters withdraw the reasons
    -- that no longer apply and add each reason at most once, keyed. The
    -- harness asserts this by explaining the same objective twice and
    -- requiring the reason list not to grow.
    --
    -- Guarded, because an adjuster that throws must not take `/cn why` down
    -- with it -- the same guard `ScoreObjective` has had since 0.55.0.
    for index = 1, #CN.scoreAdjusterOrder do
        local name = CN.scoreAdjusterOrder[index]

        local adjuster = CN.scoreAdjusters[name]

        if adjuster then
            local ran, adjusted = pcall(adjuster, objective, worth)

            if not ran then
                -- RECORDED, like `ScoreObjective` does. An adjuster that
                -- throws only here -- it is handed a different running total
                -- than the scorer hands it -- would otherwise leave no trace
                -- anywhere, and `/cn why` would quietly print an explanation
                -- missing a term.
                local errors = CN:GetModule("Errors")

                if errors and errors.Record then
                    pcall(errors.Record, "explain:" .. tostring(name),
                        tostring(adjusted))
                end

                adjusted = nil
            end

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

            CN.PrintLine(string.format("  %-11s |cff5dd2fb%s|r|cff5a5f66%s|r %.2f",
                point.label,
                string.rep("=", scaled),
                string.rep("-", width - scaled),
                value))
        end

        CN.Print("|cff8a8f96Multiplied by " .. CN.urgencyWeight
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
            CN.Print("|cff8a8f96Showing " .. wanted .. ": the breakdown is "
                .. "long, so this tops out there. |cffffc74f/cn list "
                .. asked .. "|r|cff8a8f96 gives the plain ranking.|r")
        end

        local results = CN.Recommend(wanted)

        if #results == 0 then
            CN.Print("Nothing is being recommended, so there is no order to "
                .. "explain.")
            return
        end

        local settings = CN.Settings()

        -- "Ranking weight", NOT "Focus".
        --
        -- `/cn mode` calls the PRESET the focus, so labelling the weighting
        -- with the same word meant `/cn mode` said "Focus: Collecting" and
        -- `/cn order` said "Focus: collections" about two different settings,
        -- in the same session, with no way to tell them apart.
        CN.Print("Ranking weight: " .. CN.Accent(
            tostring((settings and settings.priorityMode) or "balanced")))

        for index, objective in ipairs(results) do
            CN.PrintLine(string.format("%d. |cfff2f4f6%s|r |cff8a8f96%.1f|r",
                index, tostring(objective.name or objective.id),
                objective.priorityWeight or 0))

            for _, term in ipairs(CN.ExplainScore(objective)) do
                CN.PrintLine(string.format("     %s%+.1f|r  %s",
                    term.value >= 0 and "|cff73b873" or "|cffe2564c",
                    term.value, term.label))
            end
        end

        CN.Print("|cff8a8f96Every line above is a term in the same sum. "
            .. "|cffffc74f/cn mode|r changes the weights; |cffffc74f/cn why|r "
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
            .. " hidden by your filter. " .. CN.Accent("/cn show")
            .. " lists them.")
    end

    -- A FAILURE IS NOT AN EMPTY RESULT, AND MUST NOT READ AS ONE.
    local errors = CN:GetModule("Errors")

    local failures = errors and errors.Count and errors.Count() or 0

    if failures > 0 then
        table.insert(lines, failures .. " thing"
            .. (failures == 1 and " has" or "s have")
            .. " gone wrong inside the addon this session, which is enough "
            .. "to empty this list. " .. CN.Accent("/cn errors")
            .. " has the detail.")
    end

    local setup = CN:GetModule("Setup")

    if setup and setup.HasRun and not setup.HasRun() then
        -- THE ONE REQUIRED FIRST ACTION, IN THE COLOUR RESERVED FOR A THING
        -- TO TYPE.
        --
        -- Every caller wrapped these lines in MUTED, which `Design.lua`
        -- reserves for hints and parentheticals -- so on a fresh install the
        -- single step that makes the addon work rendered in the same grey as
        -- a disabled control. The commands carry ACCENT themselves now and
        -- the callers have stopped wrapping.
        table.insert(lines, "Nothing has been scanned yet. "
            .. CN.Accent("/cn setup")
            .. " reads everything the client will answer for on its own.")
    elseif #lines == 0 then
        table.insert(lines, "Every provider answered and none of them had "
            .. "anything to offer, which usually means you are between "
            .. "things: try a different zone, or "
            .. CN.Accent("/cn waiting") .. " for what is on a timer.")
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
                CN.PrintLine(line)
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
            CN.Print("|cffffc74f" .. notice .. "|r")
        end

        -- One headline, its reasons indented under it. The whole block used
        -- to carry the addon's name on every line.
        CN.PrintBlock(
            "Next: " .. CN.Primary(tostring(objective.name or objective.id))
                .. CN.Aside(CN.TypeBadge(objective.type)),
            CN.ExplainRecommendation(objective))

        if objective.mapID and objective.x and objective.y then
            CN.PrintLine(CN.Accent("/cn go") .. CN.Muted(" to set a waypoint."))
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
            .. (state.dirty and " |cffffc74f(stale)|r" or "")
            .. (state.age and (" |cff8a8f96" .. state.age .. "s old|r") or ""))

        CN.PrintLine("Providers: " .. state.fresh .. " of " .. state.providers
            .. " cached, ranked list "
            .. (state.ranked and CN.Good("reused") or CN.Accent("rebuilding")))

        -- The travel cost cache, which is the largest single term in a
        -- rebuild: every located objective asks for one journey estimate, and
        -- against a real flight network that is most of the work.
        local travel = CN:GetModule("Travel")

        if travel and travel.CostCacheSize then
            CN.PrintLine("Costed journeys held: " .. travel.CostCacheSize()
                .. "|cff8a8f96 of " .. travel.costCacheCap
                .. ", thrown away when you move more than "
                .. travel.costCacheYards .. "yd|r")
        end

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
            CN.Print("No timings recorded yet. Run |cffffc74f/cn next|r first.")
            CN.Print("|cff8a8f96Timings need debugprofilestop, which exists in game "
                .. "but not in offline tests.|r")
            return
        end

        table.sort(rows, function(a, b) return a.average > b.average end)

        CN.Print("Providers, slowest first:")

        for _, row in ipairs(rows) do
            CN.PrintLine(string.format("  %-14s avg %.2fms  worst %.2fms  (%d %s)%s",
                row.name, row.average, row.worst, row.calls,
                row.calls == 1 and "call" or "calls",
                row.cached and "" or " |cffffc74fstale|r"))
        end

        -- A cap nobody can see reads as "that was everything".
        local capped = false

        for name, truncation in pairs(CN.providerTruncation) do
            if (truncation.dropped or 0) > 0 then
                if not capped then
                    CN.PrintLine("Capped at " .. CN.providerCandidateCap
                        .. " per provider:")
                    capped = true
                end

                CN.PrintLine("  " .. name .. ": showing " .. CN.providerCandidateCap
                    .. " of " .. truncation.considered
                    .. " |cff8a8f96(" .. truncation.dropped .. " lower-valued dropped)|r")
            end
        end

        if capped then
            CN.Print("|cff8a8f96Dropped entries scored no higher than the ones kept. "
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
            -- THE SAME EXPLANATION EVERY OTHER SURFACE GIVES.
            --
            -- `CN.ExplainEmptyList` exists under the banner "one explanation
            -- for an empty list, used by every surface that shows one", and
            -- five surfaces used it. `/cn list` -- one of the ten commands in
            -- the essentials block, and the one a new player is most likely
            -- to type first -- was a dead end that named no next step.
            CN.Print("No actionable objectives are known yet.")

            for _, line in ipairs(CN.ExplainEmptyList()) do
                CN.PrintLine(line)
            end

            return
        end

        -- A NUMBER WITH NO UNIT, NO SCALE AND NO MAXIMUM.
        --
        -- Every line ended `[Quest 12.4]`. 12.4 is the internal priority
        -- weight: nothing on the line said what it was of, nothing said what
        -- a good one looks like, and the command that explains it was not
        -- named. `/cn list` is one of the ten day-one commands and the one a
        -- new player types after `/cn next`.
        --
        -- Replaced with the figure the ranking already computed that a person
        -- can act on: how far away it is.
        local session = CN:GetModule("Session")

        CN.Print("The top " .. #results .. ":")

        for index, objective in ipairs(results) do
            local away

            if objective.travelCost and objective.travelCost > 0
                and CN.secondsPerCostPoint and session
                and session.FormatDuration then

                away = session.FormatDuration(objective.travelCost
                    * CN.secondsPerCostPoint)
            end

            CN.PrintLine(index .. ". "
                .. CN.Primary(tostring(objective.name or objective.id))
                .. CN.Muted(" [" .. CN.TypeBadge(objective.type)
                    .. (away and (" " .. CN.DOT .. " " .. away .. " away") or "")
                    .. "]"))
        end

        CN.PrintLine(CN.Muted("") .. CN.Accent("/cn order")
            .. CN.Muted(" shows why this is the order."))
    end,
}
