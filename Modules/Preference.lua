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

Preference.actionWindows = {
    [CN.objectiveTypes.INSTANCE]   = 5400,   -- an evening's raid
    [CN.objectiveTypes.REPUTATION] = 5400,
    [CN.objectiveTypes.RENOWN]     = 5400,
    [CN.objectiveTypes.ACHIEVEMENT] = 3600,
    [CN.objectiveTypes.PROFESSION] = 3600,
    [CN.objectiveTypes.APPEARANCE] = 2400,
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
local multiplierKey     = nil

Preference.observationGeneration = 0

local function Observed()
    Preference.observationGeneration = Preference.observationGeneration + 1
end

local function CacheKey()
    return tostring(CN.rankingGeneration or 0) .. ":"
        .. tostring(Preference.observationGeneration)
end

------------------------------------------------------------
-- OBSERVING
------------------------------------------------------------

-- What was shown, and when. In memory only: this is a question about the last
-- twenty minutes, and twenty minutes does not survive a logout in any useful
-- form.
local shownAt = {}

local function Now()
    return (GetTime and GetTime()) or (time and time()) or 0
end

Preference.Now = Now

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

                shownAt[key] = now
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

-- Called when something is genuinely finished. Credited only if the addon had
-- recommended it recently -- otherwise every quest anybody turns in would
-- count as the addon's advice being taken, which would teach it that its
-- opinion is always right.
-- The sub-bucket an objective belongs in, or its plain type when it has none.
function Preference.Refine(objective)
    if not objective or objective.type ~= CN.objectiveTypes.QUEST then
        return objective and objective.type
    end

    -- The game's own campaign data, which is what Loremaster already uses to
    -- keep "the story" and "everything else" apart.
    if CN.Blizzard and CN.Blizzard.IsQuestCampaign
        and CN.Blizzard.IsQuestCampaign(objective.id) then

        return "QUEST_CAMPAIGN"
    end

    return "QUEST_SIDE"
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
        shownAt[key] = nil

        return false
    end

    local row = Row(objectiveType)

    if not row then
        return false
    end

    row.acted = row.acted + 1

    Observed()

    shownAt[key] = nil

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

    local key = CacheKey()

    if key ~= multiplierKey then
        multiplierCache = {}
        multiplierKey   = key
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

    if multiplier == 1 then
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
            Print("|cff999999The addon watches which kinds of thing you "
                .. "actually go and do, and needs "
                .. Preference.minimumObservations
                .. " sightings of a kind before it acts on anything.|r")
            return
        end

        if not Preference.IsEnabled() then
            Print("|cff999999Learning is switched off; the figures below are "
                .. "not affecting your ranking. |cffffff00/cn learned on|r "
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

            local line = string.format("  %-16s %d of %d acted on",
                label, entry.row.acted, entry.row.shown)

            if multiplier == 1 then
                local short = Preference.minimumObservations - entry.row.shown

                line = line .. " |cff999999(no effect"
                    .. (short > 0 and (" -- " .. short .. " more sightings needed")
                        or "")
                    .. ")|r"
            else
                line = line .. string.format(" |cffffff00x%.2f|r |cff999999%s|r",
                    multiplier, reason or "")
            end

            Print(line)
        end

        Print("|cff999999" .. "/cn learned reset" .. " forgets all of it. "
            .. "Hiding a type outright is |cffffff00/cn show|r.|r")
    end,
}

return Preference
