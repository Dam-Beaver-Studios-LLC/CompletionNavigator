-- Modules/Preference.lua
-- Completion Navigator :: learning what you actually do.
--
-- THE PROBLEM.
--
-- The ranking has always been the addon's opinion. It is a good opinion --
-- deadlines first, batching second, travel cost third -- but it is the same
-- opinion for everybody, and people do not play the same way. Somebody who
-- has never once gone out of their way for a battle pet gets pets in their
-- list forever, and the addon never notices.
--
-- Hiding the type is the blunt fix and it already exists. This is the fine
-- one: notice what you take up, notice what you scroll past, and lean.
--
-- WHAT IS MEASURED.
--
--   shown   -- the objective was actually put in front of you, via the
--              recommendation hook, which fires on the handful that were
--              displayed rather than the two hundred that were considered.
--   acted   -- it was completed, or its type was, within the window below.
--
-- A ratio of those two, per objective TYPE, on this character.
--
-- WHY TYPE AND NOT THE OBJECTIVE ITSELF.
--
-- Because an individual objective is shown a handful of times before it is
-- either done or gone, which is far too little to learn anything from. A type
-- accumulates hundreds of observations in a week of play. Learning per
-- objective would be learning noise, and dressing it up as personalisation.
--
-- THE GUARDRAILS, WHICH MATTER MORE THAN THE LEARNING.
--
--   * Nothing happens below `minimumObservations`. Until then the multiplier
--     is exactly 1 and the addon behaves as it always did.
--   * The adjustment is CLAMPED, hard. A type you ignore is quieter, never
--     silent -- silencing a type is a decision for you to make in /cn show,
--     not one for a counter to make on your behalf.
--   * It is EXPLAINED. Every adjusted line carries a reason saying so. A
--     ranking that changed for reasons the player cannot see is a ranking
--     they cannot trust.
--   * It DECAYS. Somebody who spent a month on transmog and has now moved on
--     should not be arguing with a month-old opinion forever.
--   * `/cn learned` shows the whole table, and `/cn learned reset` throws it
--     away. Nothing here is permanent and nothing here is hidden.

local ADDON_NAME, CN = ...

local Preference = CN:RegisterModule("Preference")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint

------------------------------------------------------------
-- TUNING
------------------------------------------------------------

-- How many times a type has to have been shown before its ratio is allowed
-- to move anything at all. Deliberately high: the cost of learning too early
-- is a ranking that lurches around in the player's first evening, which reads
-- as the addon being unreliable rather than adaptive.
Preference.minimumObservations = 25

-- The window in which finishing something counts as having acted on it.
--
-- Twenty minutes suits a quest. It does not suit a raid lockout, which takes
-- an evening, or a reputation, which takes a week -- and crediting those at
-- twenty minutes meant the addon concluded the player ignores exactly the
-- things that take longest to do.
--
-- Per type, therefore, with the old figure as the default. These are not
-- measured -- they are how long the ACTIVITY takes, which the addon cannot
-- observe before the fact -- so they are stated plainly as judgements rather
-- than dressed up as data.
Preference.actionWindowSeconds = 1200

-- ONLY THE TYPES THAT CAN BE CREDITED. 0.86.0.
--
-- `WindowFor` is reached only after `Preference.IsCreditable` has passed, and
-- from `NoteCompleted`, whose only caller is the completion-event loop at the
-- bottom of this file. `Preference.creditableTypes` is QUEST, ACHIEVEMENT,
-- PET, MOUNT and TOY -- so INSTANCE, REPUTATION, RENOWN, PROFESSION and
-- APPEARANCE could never reach this table. Five of the six entries added in
-- 0.46.0 became unreachable when 0.55.0 added the creditability gate, and the
-- header above still explains at length why a raid needs a longer window than
-- an appearance.
--
-- Nothing on screen changed; what changed is that the next reader will not
-- retune a number and watch nothing happen. They go back in the same change
-- that starts crediting one of those types, and not before.
Preference.actionWindows = {
    [CN.objectiveTypes.ACHIEVEMENT] = 3600,
}

function Preference.WindowFor(objectiveType)
    return Preference.actionWindows[objectiveType]
        or Preference.actionWindowSeconds
end

-- The full range of the multiplier. A type you always act on gets a modest
-- push; one you never touch gets a modest shove. Both are small on purpose --
-- this is a thumb on the scale, not a second scoring system.
Preference.minMultiplier = 0.80
Preference.maxMultiplier = 1.25

-- Above this ratio the type is "one you act on", below it "one you skip".
-- Not 0.5: most recommendations are not acted on immediately by anybody,
-- because the list is longer than the evening.
Preference.actedThreshold = 0.25

-- Counters are halved when either passes this, so the table reflects how you
-- play now rather than how you played in June.
Preference.decayAt = 400

------------------------------------------------------------
-- THE STORE
------------------------------------------------------------

-- Per character, because how you play a levelling alt is not how you play the
-- character you raid on. Two integers per type: about as cheap as a store in
-- this addon gets, and nothing here cannot be thrown away.
local function Store()
    local character = CN.character

    if not character then
        return nil
    end

    character.preference = character.preference or {}

    return character.preference
end

Preference.Store = Store

local function Row(objectiveType)
    local store = Store()

    if not store or not objectiveType then
        return nil
    end

    store[objectiveType] = store[objectiveType] or { shown = 0, acted = 0 }

    return store[objectiveType]
end

function Preference.IsEnabled()
    local settings = CN.Settings()

    -- On by default, but a real setting: someone who wants the addon's
    -- opinion and only the addon's opinion is entitled to have it.
    return not settings or settings.learnPreferences ~= false
end

function Preference.SetEnabled(enabled)
    local settings = CN.Settings()

    if settings then
        -- Store false to turn it OFF and nil to turn it back on: the default
        -- is on, so "nil" and "off" must not be the same stored value.
        --
        -- Written as an if rather than as `x and false or nil`, which is how
        -- it was written first: in Lua that expression can never produce
        -- false, because `and false` is falsy and falls straight through to
        -- the `or`. It read correctly and did nothing.
        if enabled then
            settings.learnPreferences = nil
        else
            settings.learnPreferences = false
        end
    end

    -- The observation generation is what the multiplier cache is keyed on
    -- now, and switching the whole feature off changes every multiplier.
    Preference.observationGeneration = Preference.observationGeneration + 1

    CN.InvalidateRanking()
end

------------------------------------------------------------
-- MEMOISATION
------------------------------------------------------------

-- MEMOISED, because this runs on every candidate in the list.
--
-- Ranking scores a few thousand objectives, and without this each one of them
-- resolved the settings proxy, found the character table and did the
-- arithmetic again for an answer that changes a few times an hour. Measured,
-- the uncached version doubled the cost of Recommend(25).
--
-- The key is both generations: the ranking one, bumped when something the
-- player did changes the order, and the observation one, bumped whenever a
-- counter moves. Between them nothing can go stale.
local multiplierCache   = {}

Preference.observationGeneration = 0

local function Observed()
    Preference.observationGeneration = Preference.observationGeneration + 1
end

-- Published, because the multiplier cache is keyed on this generation and
-- anything that writes the preference store from outside this file -- the
-- test suite, a future import -- has to be able to say so. Before 0.54.0 the
-- key also carried `CN.rankingGeneration`, so a bare `InvalidateRanking()`
-- happened to clear the cache; that was never the contract, it was a side
-- effect of a key that threw the cache away every two seconds.
Preference.NoteStoreChanged = Observed

-- TWO NUMBERS COMPARED, NOT A STRING BUILT TO COMPARE.
--
-- `Multiplier` is asked twice per objective in the ordinary case, and this
-- built a fresh string on every call purely so it could be compared against
-- the previous one. Measured over a hundred and fifty calls: 81% of the
-- function's entire cost was the string, against 6% for the comparison it
-- existed to perform.
--
-- AND `rankingGeneration` DOES NOT BELONG IN THE KEY. The multiplier is a
-- function of the preference store and the learn setting; the store is what
-- `observationGeneration` tracks. `rankingGeneration` is bumped by every
-- `BuildZoneRoute`, so opening the Zone tab threw away a cache of at most
-- twenty entries that could otherwise have stood for minutes.
local multiplierObservation = -1

------------------------------------------------------------
-- OBSERVING
------------------------------------------------------------

-- What was shown, and when. In memory only: this is a question about the last
-- twenty minutes, and twenty minutes does not survive a logout in any useful
-- form.
local shownAt = {}

-- Which sub-bucket each sighting was filed under, so the completion side can
-- credit the same bucket the showing side incremented.
local shownRefinement = {}

-- BOUNDED, THE SAME WAY SESSION'S OFFER MEMORY IS.
--
-- `shownAt` gained an entry per distinct objective ever put in front of the
-- player and lost one only on a successful action or on the expired branch,
-- so anything shown and never acted on stayed forever. `shownRefinement` was
-- worse: the success path cleared `shownAt[key]` and left the refinement
-- entry behind unconditionally -- and that is the table the fallback match
-- loop runs a `string.sub` over on every NEW_PET_ADDED, NEW_MOUNT_ADDED and
-- NEW_TOY_ADDED.
--
-- Session next door carries the identical structure with an expiry and a cap
-- and a comment calling the unbounded version "a slow leak I shipped in
-- 0.28.0". The same shape was reintroduced here. Same two bounds, same
-- hysteresis, same reason.
local shownCount = 0

Preference.sightingCap     = 400
Preference.sightingSeconds = 1800
Preference.sightingSlack   = 0.25

-- Removing a sighting means removing it from both tables. Every path that
-- used to touch only one of them is why this is a function.
local function Forget(key)
    if shownAt[key] ~= nil then
        shownCount = shownCount - 1
    end

    shownAt[key]         = nil
    shownRefinement[key] = nil
end

Preference.Forget = Forget

local function Now()
    return (GetTime and GetTime()) or (time and time()) or 0
end

Preference.Now = Now

-- Overshoot by a quarter, then sweep back to the cap -- pruning on every
-- insert would walk four hundred entries per recommendation, which is the
-- trade Session already refused to make.
function Preference.Prune(force)
    local trigger = Preference.sightingCap * (1 + Preference.sightingSlack)

    if not force and shownCount <= trigger then
        return 0
    end

    local now     = Now()
    local removed = 0

    for key, at in pairs(shownAt) do
        if (now - at) > Preference.sightingSeconds then
            Forget(key)
            removed = removed + 1
        end
    end

    if shownCount > Preference.sightingCap then
        local ordered = {}

        for key, at in pairs(shownAt) do
            table.insert(ordered, { key = key, at = at })
        end

        table.sort(ordered, function(a, b)
            if a.at == b.at then
                return a.key < b.key
            end

            return a.at < b.at
        end)

        for index = 1, shownCount - Preference.sightingCap do
            if ordered[index] then
                Forget(ordered[index].key)
                removed = removed + 1
            end
        end
    end

    -- A refinement entry with no sighting behind it is unreachable, and this
    -- is the table the fallback loop walks.
    for key in pairs(shownRefinement) do
        if shownAt[key] == nil then
            shownRefinement[key] = nil
        end
    end

    return removed
end

function Preference.SightingCount()
    return shownCount
end

-- Hung on the recommendation hook rather than a decorator, deliberately.
-- Duration learning made exactly this mistake in 0.28.0 and timed all two
-- hundred candidates on every rebuild, including the hundred and seventy
-- nobody ever saw.
CN.RegisterRecommendationHook("Preference", function(results)
    if not Preference.IsEnabled() then
        return
    end

    local now = Now()

    local store = Store()

    if not store then
        return
    end

    for _, objective in ipairs(results or {}) do
        local objectiveType = objective and objective.type

        -- Don't count sightings the addon can never pair with a completion.
        -- A row that can only ever read "0 of 300" is not data; it is a
        -- persisted misunderstanding, and it was being spent on every one of
        -- the thirteen uncreditable types. See `Preference.creditableTypes`.
        if objectiveType and not Preference.IsCreditable(objectiveType) then
            objectiveType = nil
        end

        if objectiveType then
            local row = store[objectiveType]

            if not row then
                row = { shown = 0, acted = 0 }

                store[objectiveType] = row
            end

            if row then
                -- ONE OBSERVATION PER APPEARANCE, NOT PER REDRAW.
                --
                -- The window redraws on a great many events, and the same
                -- three lines are "shown" on every one of them. Counting
                -- those would mean an open window taught the addon that you
                -- ignore everything, at a rate of several observations a
                -- second, purely for leaving it open.
                -- Built once and kept on the objective. This runs on
                -- every redraw of an open window, and the concatenation was
                -- the most expensive thing in it -- for a string that cannot
                -- change while the objective exists.
                local key = objective.preferenceKey

                if not key then
                    key = objectiveType .. ":" .. tostring(objective.id)

                    objective.preferenceKey = key
                end

                local last = shownAt[key]

                -- FINER THAN A TYPE, WHERE THE TYPE IS TOO COARSE.
                --
                -- "Quests" is one bucket containing two quite different
                -- habits: people who follow the story, and people who clear
                -- everything. Somebody who always does the campaign and never
                -- touches side quests looks, at type resolution, like
                -- somebody with no opinion at all -- the rate averages to the
                -- middle and nothing moves.
                --
                -- Only quests get this. Every other type is one habit, and
                -- six buckets that each learn nothing beat none at all.
                local refined = Preference.Refine(objective)

                -- Keyed on `key`, which is what `shownAt` is keyed on and
                -- what the completion side matches against. It used to
                -- rebuild the string from the type and id, which is the same
                -- thing only while `objective.preferenceKey` has not been set
                -- to something else -- and a refinement filed under a key
                -- nothing looks up is a refinement that never credits.
                shownRefinement[key] = refined

                if refined ~= objectiveType then
                    local refinedRow = store[refined]

                    if not refinedRow then
                        refinedRow = { shown = 0, acted = 0 }

                        store[refined] = refinedRow
                    end

                    -- The SAME window as the counter twelve lines below, and
                    -- for the same reason. This one kept the flat default
                    -- that 0.46.0 replaced with per-type windows, so the
                    -- moment a quest window is added to Preference.
                    -- actionWindows the two counters silently disagree and
                    -- the refined buckets over-count what was shown.
                    if not last
                        or (now - last) > Preference.WindowFor(objectiveType) then

                        refinedRow.shown = refinedRow.shown + 1
                    end
                end

                if not last
                    or (now - last) > Preference.WindowFor(objectiveType) then

                    row.shown = row.shown + 1

                    Observed()

                    -- Only when a counter actually moved. Decaying on every
                    -- call meant walking the whole table on every redraw of
                    -- the window to discover, almost always, that nothing had
                    -- reached the threshold -- the same shape of waste the
                    -- 0.28.0 duration bug was.
                    Preference.Decay()
                end

                if shownAt[key] == nil then
                    shownCount = shownCount + 1
                end

                shownAt[key] = now

                Preference.Prune()
            end
        end
    end
end)

-- Types whose completion event carries the same id the recommendation did.
-- For these an inexact match is not evidence of anything.
Preference.exactIdEvents = {
    [CN.objectiveTypes.QUEST]       = true,
    [CN.objectiveTypes.ACHIEVEMENT] = true,
}

------------------------------------------------------------
-- WHAT THE ADDON CAN ACTUALLY WATCH YOU DO
------------------------------------------------------------

-- THE HALF OF THE SUBJECT MATTER THAT WAS BEING PUNISHED FOR THE ADDON'S OWN
-- DEAFNESS.
--
-- `shown` was counted for every type a provider emits. `acted` was counted
-- only for the five types the client announces a completion for -- quests,
-- achievements, pets, mounts and toys. For the other thirteen the ratio was
-- structurally, permanently zero: not "you ignore these", but "nobody is
-- listening". Past `minimumObservations` sightings, every one of them settled
-- on the 0.80 floor and stayed there for the life of the character.
--
-- Two things were wrong with that, and the second is worse than the first.
--
--   * A uniform, invisible, unearned demotion of reputations, renown,
--     appearances, recipes, professions, rares, treasures, exploration,
--     titles, currencies, vendors, collectibles and lockouts -- against
--     quests and achievements, which could be credited. The addon's own
--     ranking quietly decided that half of what it recommends is not worth
--     doing, on no evidence at all.
--
--   * `/cn learned` then printed "you rarely act on these" beside them. That
--     is a statement about the player, and it is false. The addon has never
--     been able to see whether you collected that appearance. Saying
--     otherwise on the strength of a counter that cannot move is the one
--     thing this addon promises never to do.
--
-- So: a type earns an opinion only if there is a path by which it could be
-- credited. Everything else returns a flat 1 and says nothing. When a future
-- release learns to observe a type -- a currency threshold crossed, a rare's
-- loot received -- it is added here in the same commit that starts crediting
-- it, and not before.
Preference.creditableTypes = {
    [CN.objectiveTypes.QUEST]       = true,
    [CN.objectiveTypes.ACHIEVEMENT] = true,
    [CN.objectiveTypes.PET]         = true,
    [CN.objectiveTypes.MOUNT]       = true,
    [CN.objectiveTypes.TOY]         = true,

    -- The refinements of QUEST, which are credited through the same event.
    QUEST_CAMPAIGN = true,
    QUEST_SIDE     = true,
}

-- Whether a preference multiplier may be computed for this type at all.
function Preference.IsCreditable(objectiveType)
    if not objectiveType then
        return false
    end

    return Preference.creditableTypes[objectiveType] == true
end

-- Called when something is genuinely finished. Credited only if the addon had
-- recommended it recently -- otherwise every quest anybody turns in would
-- count as the addon's advice being taken, which would teach it that its
-- opinion is always right.
-- The sub-bucket an objective belongs in, or its plain type when it has none.
--
-- MEMOISED ON THE OBJECTIVE, like `preferenceKey` twenty lines below and for
-- exactly the same reason. This is one protected client call --
-- `C_CampaignInfo.GetCampaignID` -- and the adjuster's first statement, so
-- it ran once per quest candidate per scoring pass: measured at 130 calls
-- for `Recommend(5)` over 148 candidates, and 130 again on the next re-rank
-- with nothing changed, while `BuildZoneRoute` bumps the ranking generation
-- from the Zone tab's two-second refresh, follow mode's ticker and every map
-- open.
--
-- Whether a quest is part of a campaign is a fact about the quest and does
-- not change while the client is running, so the answer is kept for the
-- session -- on the objective, so it dies with the candidate.
function Preference.Refine(objective)
    if not objective or objective.type ~= CN.objectiveTypes.QUEST then
        return objective and objective.type
    end

    local held = objective.preferenceBucket

    if held then
        return held
    end

    -- The game's own campaign data, which is what Loremaster already uses to
    -- keep "the story" and "everything else" apart.
    local bucket = "QUEST_SIDE"

    if CN.Blizzard and CN.Blizzard.IsQuestCampaign
        and CN.Blizzard.IsQuestCampaign(objective.id) then

        bucket = "QUEST_CAMPAIGN"
    end

    objective.preferenceBucket = bucket

    return bucket
end

-- Which sub-bucket a recorded sighting belonged to.
--
-- The showing side files an objective under both its plain type and its
-- refinement; the completion side sees only a type and an id, and the id is
-- not always the one that was recommended. So the refinement is remembered
-- when the sighting is recorded, keyed the same way.
function Preference.RefinedKeyFor(key, objectiveType)
    local remembered = shownRefinement[key]

    if remembered then
        return remembered
    end

    return objectiveType
end

function Preference.NoteCompleted(objectiveType, objectiveID)
    if not Preference.IsEnabled() or not objectiveType then
        return false
    end

    local now = Now()

    local key = objectiveType .. ":" .. tostring(objectiveID)

    local last = shownAt[key]

    -- THE ID THE EVENT CARRIES IS NOT ALWAYS THE ID THAT WAS RECOMMENDED.
    --
    -- NEW_PET_ADDED reports the unique pet you now own; the recommendation was
    -- about the species. NEW_MOUNT_ADDED and the transmog events have the same
    -- shape of mismatch. For those, fall back to "was anything of this type
    -- recommended in the window", since what is being learned is per type
    -- anyway.
    --
    -- NOT for quests and achievements. Those events carry exactly the id that
    -- was recommended, so a fallback there would credit the addon for every
    -- quest anybody turns in merely because it had mentioned some other quest
    -- in the last twenty minutes -- and on a levelling character it has always
    -- mentioned some other quest in the last twenty minutes. That is not
    -- learning, it is a counter that only goes up.
    if not last and not Preference.exactIdEvents[objectiveType] then
        local fallbackKey

        for candidateKey, when in pairs(shownAt) do
            if (now - when) <= Preference.WindowFor(objectiveType)
                and string.sub(candidateKey, 1, #objectiveType + 1)
                    == (objectiveType .. ":") then

                -- The most recently shown one, so a stale sighting from
                -- nineteen minutes ago does not get the credit.
                if not fallbackKey or when > shownAt[fallbackKey] then
                    fallbackKey = candidateKey
                end
            end
        end

        if not fallbackKey then
            return false
        end

        key  = fallbackKey
        last = shownAt[fallbackKey]
    end

    -- Still nothing: this was never recommended, so it teaches us nothing.
    -- Reaching the arithmetic below with a nil here threw inside a
    -- QUEST_TURNED_IN handler -- a learning feature breaking quest turn-ins
    -- would be a spectacularly bad trade.
    if not last then
        return false
    end

    if (now - last) > Preference.WindowFor(objectiveType) then
        Forget(key)

        return false
    end

    local row = Row(objectiveType)

    if not row then
        return false
    end

    row.acted = row.acted + 1

    -- AND THE REFINED BUCKET, WHICH WAS NEVER CREDITED AT ALL.
    --
    -- The showing side increments both the plain type and the campaign/side
    -- sub-bucket; this side incremented only the plain type. So the refined
    -- rows accumulated sightings and no actions, drifted to the floor
    -- multiplier, and the score adjuster PREFERS the refined row whenever its
    -- multiplier is not 1 -- meaning the plain row that held the true answer
    -- was correct and unreachable.
    --
    -- Measured: a player who turned in all 120 quests they were shown was
    -- told, after an hour or two, that they "rarely act on these", and every
    -- quest was multiplied by 0.80 permanently.
    --
    -- The id is not always available here (some events carry a different one
    -- than was recommended), so the bucket is recovered from the key that was
    -- actually matched.
    local refined = Preference.RefinedKeyFor(key, objectiveType)

    if refined and refined ~= objectiveType then
        local store = Store()

        local refinedRow = store and store[refined]

        if refinedRow then
            refinedRow.acted = (refinedRow.acted or 0) + 1
        end
    end

    Observed()

    -- BOTH TABLES. Clearing only `shownAt` here is what left an entry in
    -- `shownRefinement` for every objective the player ever acted on.
    Forget(key)

    CN.InvalidateRanking()

    DebugPrint("Acted on a " .. objectiveType .. " that was recommended.")

    return true
end

-- Halve everything once the counts get large, so the table tracks how you
-- play now. Halving keeps the RATIO and forgets the certainty, which is
-- exactly the right thing to forget.
function Preference.Decay()
    local store = Store()

    if not store then
        return false
    end

    local decayed = false

    for _, row in pairs(store) do
        if row.shown >= Preference.decayAt then
            row.shown = math.floor(row.shown / 2)
            row.acted = math.floor(row.acted / 2)

            Observed()

            decayed = true
        end
    end

    return decayed
end

------------------------------------------------------------
-- THE ADJUSTMENT
------------------------------------------------------------

-- Returns the multiplier and, when it is not 1, a sentence saying why.
function Preference.Multiplier(objectiveType)
    if not objectiveType then
        return 1, nil
    end

    if multiplierObservation ~= Preference.observationGeneration then
        multiplierCache        = {}
        multiplierObservation  = Preference.observationGeneration
    end

    local cached = multiplierCache[objectiveType]

    if cached then
        return cached[1], cached[2]
    end

    local multiplier, reason = Preference.Compute(objectiveType)

    multiplierCache[objectiveType] = { multiplier, reason }

    return multiplier, reason
end

function Preference.Compute(objectiveType)
    if not Preference.IsEnabled() then
        return 1, nil
    end

    -- No completion path, no opinion. See `Preference.creditableTypes`.
    if not Preference.IsCreditable(objectiveType) then
        return 1, nil
    end

    local store = Store()

    local row = store and store[objectiveType]

    if not row or row.shown < Preference.minimumObservations then
        return 1, nil
    end

    local ratio = row.acted / row.shown

    if ratio >= Preference.actedThreshold then
        -- Scale across the range above the threshold rather than jumping to
        -- the cap the moment it is crossed.
        local above = math.min(1, (ratio - Preference.actedThreshold)
            / (1 - Preference.actedThreshold))

        local multiplier = 1 + (Preference.maxMultiplier - 1) * above

        return multiplier, "you usually act on these"
    end

    local below = 1 - (ratio / Preference.actedThreshold)

    local multiplier = 1 - (1 - Preference.minMultiplier) * below

    return multiplier, "you rarely act on these"
end

-- Applied in scoring, after the profile's own type weighting, so a focus you
-- chose deliberately always outranks a habit the addon inferred.
CN.RegisterScoreAdjuster("Preference", function(objective, score)
    -- THE GATE BEFORE THE WORK.
    --
    -- `Refine` was called first and `IsEnabled` afterwards, so a player who
    -- had turned learning OFF paid the whole cost of it on every pass and
    -- got nothing. Withdraw first, because a sentence stamped while learning
    -- was on must not outlive it.
    if not Preference.IsEnabled() then
        CN.ClearAdjusterReason(objective, "preference")

        return score
    end

    -- The finer bucket first, and only if it has earned an opinion of its
    -- own. Falling back to the type means a player whose quest habits are
    -- undifferentiated is treated exactly as before.
    local refined = Preference.Refine(objective)

    local multiplier, reason = 1, nil

    if refined and refined ~= (objective and objective.type) then
        multiplier, reason = Preference.Multiplier(refined)
    end

    if multiplier == 1 then
        multiplier, reason = Preference.Multiplier(objective and objective.type)
    end

    -- WHAT IS NO LONGER TRUE IS WITHDRAWN FIRST, which this adjuster never
    -- did and the Group adjuster has since 0.51.0.
    --
    -- The sentence is stamped onto objectives that live in the per-provider
    -- cache, and the cache outlives the opinion. So `/cn learned reset` said
    -- "Forgotten. The ranking is back to its defaults." while `/cn why` went
    -- on printing "you rarely act on these" until some unrelated rebuild
    -- happened to produce a different list. `/cn learned off` did the same,
    -- and so does anything that stops being creditable.
    if multiplier == 1 then
        CN.ClearAdjusterReason(objective, "preference")

        return score
    end

    -- SAY SO. A list that quietly reordered itself is a list nobody can
    -- argue with, and this addon's whole contract is that every line has a
    -- stated reason.
    if reason then
        CN.AddAdjusterReason(objective, "preference", reason)
    end

    return score * multiplier
end)

------------------------------------------------------------
-- WHAT COUNTS AS HAVING ACTED
------------------------------------------------------------

-- Only completions the game announces. Nothing here infers that you did
-- something because you walked near it.
local completionEvents = {
    { event = "QUEST_TURNED_IN",   type = CN.objectiveTypes.QUEST },
    { event = "ACHIEVEMENT_EARNED", type = CN.objectiveTypes.ACHIEVEMENT },
    { event = "NEW_PET_ADDED",     type = CN.objectiveTypes.PET },
    { event = "NEW_MOUNT_ADDED",   type = CN.objectiveTypes.MOUNT },
    { event = "NEW_TOY_ADDED",     type = CN.objectiveTypes.TOY },
}

for _, entry in ipairs(completionEvents) do
    CN:RegisterEvent(entry.event, function(_, id)
        Preference.NoteCompleted(entry.type, id)
    end)
end

Preference.completionEvents = completionEvents

------------------------------------------------------------
-- COMMAND
------------------------------------------------------------

CN:RegisterCommand{
    name    = "learned",
    args    = "[reset or off or on]",
    order   = 34,
    help    = "What the addon has worked out about how you play.",
    handler = function(args)
        args = string.lower(CN.Trim(args or ""))

        if args == "reset" then
            local character = CN.character

            if character then
                character.preference = nil
            end

            Preference.observationGeneration =
                Preference.observationGeneration + 1

            CN.InvalidateRanking()

            Print("Forgotten. The ranking is back to its defaults.")
            return
        end

        if args == "off" or args == "on" then
            Preference.SetEnabled(args == "on")

            Print("Learning from what you do: "
                .. CN.YesNo(Preference.IsEnabled()))
            return
        end

        local store = Store()

        if not store or next(store) == nil then
            Print("Nothing learned yet.")
            Print("|cff8a8f96The addon watches which kinds of thing you "
                .. "actually go and do, and needs "
                .. Preference.minimumObservations
                .. " sightings of a kind before it acts on anything.|r")
            return
        end

        if not Preference.IsEnabled() then
            Print("|cff8a8f96Learning is switched off; the figures below are "
                .. "not affecting your ranking. |cffffc74f/cn learned on|r "
                .. "re-enables it.|r")
        end

        local filters = CN:GetModule("Filters")

        local rows = {}

        for objectiveType, row in pairs(store) do
            table.insert(rows, { type = objectiveType, row = row })
        end

        table.sort(rows, function(a, b)
            return (a.row.shown or 0) > (b.row.shown or 0)
        end)

        Print("What this character actually does:")

        for _, entry in ipairs(rows) do
            local labels = {
                QUEST_CAMPAIGN = "Story quests",
                QUEST_SIDE     = "Side quests",
            }

            local label = labels[entry.type]
                or (filters and filters.TypeLabel(entry.type))
                or entry.type

            local multiplier, reason = Preference.Multiplier(entry.type)

            -- NO COLUMN PADDING. 0.77.0. See the note in `Routing.lua`.
            local line = "  " .. CN.Body(label) .. "  "
                .. entry.row.acted .. " of " .. entry.row.shown
                .. " acted on"

            if not Preference.IsCreditable(entry.type) then
                -- Only reachable from a database written before 0.55.0 and
                -- not yet migrated. Say what it is rather than implying the
                -- counter is on its way somewhere.
                line = line .. " |cff8a8f96(not watched" .. CN.DASH .. "the addon cannot "
                    .. "see when you finish one of these)|r"
            elseif multiplier == 1 then
                local short = Preference.minimumObservations - entry.row.shown

                line = line .. " |cff8a8f96(no effect"
                    .. (short > 0 and (" " .. CN.DASH .. " " .. short .. " more sightings needed")
                        or "")
                    .. ")|r"
            else
                line = line .. string.format(" |cffffc74fx%.2f|r |cff8a8f96%s|r",
                    multiplier, reason or "")
            end

            CN.PrintLine(line)
        end

        Print("|cff8a8f96" .. "/cn learned reset" .. " forgets all of it. "
            .. "Hiding a type outright is |cffffc74f/cn show|r.|r")
    end,
}

return Preference
