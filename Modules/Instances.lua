-- Modules/Instances.lua
-- Completion Navigator :: dungeons and raids, which the addon could not see.
--
-- WHAT WAS MISSING.
--
-- Until now this addon knew everything about the open world and nothing about
-- the inside of a dungeon. A mount that drops from a raid boss was a line of
-- free text out of the mount journal: no boss, no instance, no difficulty, no
-- idea whether you had already killed the thing this week. `/cn chase` on such
-- a mount produced a goal with no path to it, which is the one thing this
-- addon is supposed to never do.
--
-- Worse, lockouts are the strongest deadline in the game -- stronger than a
-- daily, because a missed raid week is gone for a week rather than a day --
-- and the ranking could not see them at all, so a world quest expiring in an
-- hour outranked a raid you were six bosses into with two days left on it.
--
-- WHAT THIS DOES NOT DO.
--
-- It does not queue for anything, invite anyone, or set foot in an instance.
-- It reads three things and reports them: what you are locked to, which
-- bosses in that lockout are still alive, and where a given drop comes from.
--
-- AND WHAT IT REFUSES TO STORE.
--
-- Nothing. A lockout expires, the client always knows it, and a stale copy is
-- worse than none: "6 of 8 down in there" is actively wrong advice the moment
-- the reset it never heard about happens. The same goes for loot tables,
-- which change with patches. Everything here is read live and cached in
-- memory for the session at most.

local ADDON_NAME, CN = ...

local Instances = CN:RegisterModule("Instances")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

------------------------------------------------------------
-- LOCKOUTS
------------------------------------------------------------

-- An unfinished lockout is the cheapest progress in the game: the bosses you
-- already killed stay dead, so the remaining ones cost a fraction of a fresh
-- clear. A finished one is worth nothing until it resets. That difference is
-- the entire reason this module scores anything.
function Instances.Lockouts()
    local raw = Blizzard.GetSavedInstances()

    local lockouts = {}

    for _, saved in ipairs(raw) do
        -- An expired lockout is still listed for a while. Anything with no
        -- time left on it is not a lockout, it is a memory.
        if not saved.reset or saved.reset > 0 then
            local encounters = saved.encounters or 0
            local defeated   = saved.defeated or 0

            table.insert(lockouts, {
                name         = saved.name,

                -- Two ids, deliberately both carried and deliberately named
                -- differently: `id` is the lockout save, `instanceID` is the
                -- Encounter Journal's. Handing the first to the journal is
                -- the defect this pair exists to make impossible.
                id           = saved.id,
                instanceID   = saved.instanceID,
                difficulty   = saved.difficulty,
                difficultyID = saved.difficultyID,
                raid         = saved.raid,
                defeated     = defeated,
                encounters   = encounters,
                remaining    = math.max(0, encounters - defeated),
                resetsIn     = saved.reset,
                extended     = saved.extended,
                complete     = encounters > 0 and defeated >= encounters,
            })
        end
    end

    table.sort(lockouts, function(a, b)
        -- Most nearly finished first: that is the order they are worth doing.
        if a.complete ~= b.complete then
            return b.complete
        end

        if a.remaining ~= b.remaining then
            return a.remaining < b.remaining
        end

        return (a.resetsIn or math.huge) < (b.resetsIn or math.huge)
    end)

    return lockouts
end

function Instances.Summary()
    local lockouts = Instances.Lockouts()

    local summary = {
        total      = #lockouts,
        unfinished = 0,
        soonest    = nil,
        bosses     = 0,
    }

    for _, lockout in ipairs(lockouts) do
        if not lockout.complete then
            summary.unfinished = summary.unfinished + 1
            summary.bosses     = summary.bosses + lockout.remaining

            if not summary.soonest
                or (lockout.resetsIn or math.huge) < (summary.soonest.resetsIn or math.huge) then
                summary.soonest = lockout
            end
        end
    end

    return summary
end

-- WHICH bosses are still alive in a lockout the player is part-way through.
--
-- The client reports a count, not a list, so the names come from the
-- Adventure Guide and the state comes from the count. Where the two cannot be
-- reconciled -- a boss killed out of order, which is normal -- this says how
-- many are left rather than inventing which ones. An invented name is worse
-- than a number.
function Instances.RemainingBosses(lockout)
    if not lockout or lockout.remaining <= 0 then
        return {}, nil
    end

    if not lockout.id then
        return {}, "the client did not name this instance"
    end

    -- The JOURNAL's id, not the lockout id. See GetSavedInstances.
    if not lockout.instanceID then
        return {}, "the client did not give an Adventure Guide id for this "
            .. "instance"
    end

    local encounters = Blizzard.GetInstanceEncounters(lockout.instanceID)

    if #encounters == 0 then
        return {}, "the Adventure Guide has no boss list for this instance"
    end

    -- Only when nothing has been killed can each boss be named with
    -- confidence. Past that, the client tells us how many, not which.
    if lockout.defeated == 0 then
        return encounters, nil
    end

    return {}, lockout.remaining .. " of " .. lockout.encounters
        .. " still up (the client does not say which)"
end

------------------------------------------------------------
-- WHERE DOES IT DROP
------------------------------------------------------------

-- Answers for a name rather than an ID, because that is what the collection
-- journals hand us, and because the Adventure Guide's own search works that
-- way. Cached for the session: the answer does not change until a patch does,
-- and the search is not free.
local dropCache = {}

function Instances.ForgetDrops()
    dropCache = {}
end

function Instances.WhereDoesItDrop(name)
    if type(name) ~= "string" or name == "" then
        return {}
    end

    local cached = dropCache[name]

    if cached then
        return cached
    end

    local results = Blizzard.SearchEncounterJournal(name, 6)

    -- A ZERO IS "NOT YET", NOT "NOTHING".
    --
    -- The journal's search is asynchronous, so the first query for a name
    -- reliably returns nothing. Caching that made the emptiness permanent for
    -- the session: every later ask returned the memoised zero and the search
    -- that had by then completed was never read.
    --
    -- Only an answer is remembered. The cost of asking again is one search
    -- the player triggered themselves.
    if #results > 0 then
        dropCache[name] = results
    end

    return results
end

-- The one-line version, for a tooltip or a chase step.
function Instances.DescribeSource(name)
    local results = Instances.WhereDoesItDrop(name)

    if #results == 0 then
        return nil
    end

    local first = results[1]

    local text = tostring(first.encounter or "a boss")

    if first.instance then
        text = text .. " in " .. first.instance
    end

    -- THE DIFFICULTY THIS REPORTED WAS NOT THE DROP'S.
    --
    -- It came from `EJ_GetDifficulty()`, which answers with the difficulty
    -- the Encounter Journal happens to be SET to -- a window the player may
    -- have opened once and left on Normal. So a Mythic-only mount was
    -- confidently labelled "Normal", and the sentence below explaining why
    -- that distinction matters made the wrong label worse: it told the reader
    -- to trust it.
    --
    -- A mount that only drops on Mythic is indeed a different plan from one
    -- that drops on Normal -- which is exactly why a guess is not good enough
    -- here. The client offers no per-item difficulty, so the label is now
    -- shown only when the journal's setting is genuinely what was queried,
    -- and is named as such rather than presented as a property of the drop.
    if first.difficulty then
        -- The convention's own word, not a fifth phrasing of it. This is an
        -- answer about one difficulty presented as an answer about the drop,
        -- which is exactly what "estimated" is for.
        text = CN.WithConfidence(text, CN.confidence.ESTIMATED)
            .. " " .. CN.Muted("(searched on " .. first.difficulty .. ")")
    end

    if #results > 1 then
        text = text .. " (and " .. (#results - 1) .. " other "
            .. (#results == 2 and "encounter" or "encounters") .. ")"
    end

    return text, first
end

-- Is the player locked to the instance a drop comes from? This is the
-- difference between "go and kill it" and "not until Tuesday".
-- ONE NAME, SEVERAL LOCKOUTS. FIXED IN 0.61.0.
--
-- The client returns one saved-instance row PER DIFFICULTY, and they all
-- carry the same name. This returned the first one it walked past, so a
-- player who had cleared Heroic and never set foot in Normal was told they
-- were locked out of the drop -- and a player who had cleared Mythic but not
-- Normal was told they could still go. Wrong in both directions, and the
-- direction depended on the order the client happened to hand back its rows.
--
-- The caller knows the difficulty only sometimes, so:
--
--   * given a difficulty, match it exactly;
--   * otherwise prefer a lockout that is NOT complete, because an open
--     difficulty means the answer to "can I go and kill it" is yes;
--   * otherwise the first, which is now known to be one of several closed
--     ones and says the same thing whichever it is.
--
-- Returns lockout, count -- where count is how many share the name, so a
-- caller can say "on this difficulty" rather than implying there is only one.
function Instances.LockoutFor(instanceName, difficulty)
    if not instanceName then
        return nil, 0
    end

    local matches, first, open, exact = 0, nil, nil, nil

    for _, lockout in ipairs(Instances.Lockouts()) do
        if lockout.name == instanceName then
            matches = matches + 1

            first = first or lockout

            if difficulty and lockout.difficulty == difficulty then
                exact = exact or lockout
            end

            if not lockout.complete then
                open = open or lockout
            end
        end
    end

    if matches == 0 then
        return nil, 0
    end

    return exact or open or first, matches
end

------------------------------------------------------------
-- FORMATTING
------------------------------------------------------------

-- ALWAYS A STRING. FIXED IN 0.61.0.
--
-- `Vault.FormatReset` returns nil for a nil input -- deliberately, so the
-- Vault can decide whether to print a row at all -- and this delegated to it
-- and returned that nil straight through, past its own "unknown" fallback.
-- Both call sites below CONCATENATE the answer, so any lockout the client
-- had not yet given a reset time for threw
-- "attempt to concatenate a nil value" out of `/cn drops` and out of the
-- instance list, which is exactly the moment right after a loading screen
-- when a player is most likely to be looking at either.
--
-- The nil check goes AFTER the delegation, not instead of it.
function Instances.FormatReset(seconds)
    local vault = CN:GetModule("Vault")

    if vault and vault.FormatReset then
        local text = vault.FormatReset(seconds)

        if text then
            return text
        end
    end

    if not seconds then
        return "unknown"
    end

    return math.max(1, math.floor(seconds / 3600)) .. "h"
end

function Instances.Describe(lockout)
    local text = lockout.name

    if lockout.difficulty then
        text = text .. " |cff8a8f96(" .. lockout.difficulty .. ")|r"
    end

    if lockout.encounters > 0 then
        text = text .. ": " .. lockout.defeated .. " of " .. lockout.encounters
    end

    if lockout.complete then
        return text .. " |cff73b873cleared|r"
    end

    return text .. " |cffffc74f" .. lockout.remaining .. " left|r"
        .. " |cff8a8f96resets in " .. Instances.FormatReset(lockout.resetsIn) .. "|r"
end

------------------------------------------------------------
-- CANDIDATES
------------------------------------------------------------

-- How near the reset the lockout has to be, and how few bosses have to be
-- left, before an unfinished lockout is a next action rather than a plan for
-- the week. Same shape as the Vault's rule, and for the same reason.
Instances.maxRemaining = 6

local function Urgency(remaining, resetsIn, defeated)
    local value = 0

    -- Already started is the whole point: those kills are spent effort that
    -- expires. Nothing started is just "a dungeon exists".
    if defeated and defeated > 0 then
        value = value + 2
    end

    if remaining then
        if remaining <= 1 then
            value = value + 3
        elseif remaining <= 3 then
            value = value + 2
        else
            value = value + 1
        end
    end

    if resetsIn then
        local days = resetsIn / 86400

        if days <= 1 then
            value = value + 3
        elseif days <= 2 then
            value = value + 2
        elseif days <= 4 then
            value = value + 1
        end
    end

    return value
end

Instances.Urgency = Urgency

CN.RegisterCandidateProvider("Instances", function()
    local candidates = {}

    for _, lockout in ipairs(Instances.Lockouts()) do
        -- THE LOCKOUT'S OWN ID, NOT ITS LOCALIZED NAME.
        --
        -- The objective's `id` was `lockout.name` -- the display string. Two
        -- lockouts of the same instance at different difficulties are the
        -- ordinary case in retail, and both produced the key INSTANCE:<name>,
        -- so the aggregate deduplicated them and ONE OF THE TWO SILENTLY
        -- VANISHED from every list -- with the loser's reasons ("3 of 8
        -- already defeated") merged onto the wrong difficulty.
        --
        -- It also meant the ignore store was keyed on a translated string:
        -- ignoring Heroic ignored Normal too, and every ignore was lost the
        -- day the player changed client language.
        local key = lockout.id
            or (tostring(lockout.instanceID or lockout.name) .. ":"
                .. tostring(lockout.difficultyID or 0))

        -- A cleared lockout is not an objective, and a lockout nobody has
        -- started is a decision about the evening rather than a next action.
        if not lockout.complete
            and lockout.defeated > 0
            and lockout.remaining > 0
            and lockout.remaining <= Instances.maxRemaining
            and not CN.IsIgnored(CN.objectiveTypes.INSTANCE, key)
            and not CN.IsDeferred(CN.objectiveTypes.INSTANCE, key) then

            local reasons = {
                lockout.defeated .. " of " .. lockout.encounters
                    .. " already defeated" .. CN.DASH .. "those kills expire at the reset",
                lockout.remaining .. " "
                    .. (lockout.remaining == 1 and "boss" or "bosses") .. " left",
            }

            if lockout.resetsIn then
                table.insert(reasons, "resets in " .. Instances.FormatReset(lockout.resetsIn))
            end

            if lockout.extended then
                table.insert(reasons, "you extended this lockout deliberately")
            end

            table.insert(candidates, CN.NewObjective({
                id               = key,
                type             = CN.objectiveTypes.INSTANCE,
                name             = lockout.name
                    .. (lockout.difficulty and (" (" .. lockout.difficulty .. ")") or ""),
                accountWide      = false,
                completionValue  = lockout.raid and 6 or 4,
                limitedTimeBonus = Urgency(lockout.remaining, lockout.resetsIn, lockout.defeated),
                -- No map coordinate, but not "location unknown" either: the
                -- group finder is one click. Same figure the Vault uses.
                travelCost       = 3,
                expiresIn        = lockout.resetsIn,
                reasons          = reasons,
            }))
        end
    end

    return candidates
end, {
    -- A lockout changes when a boss dies or when the reset happens, and
    -- nothing else. UPDATE_INSTANCE_INFO is the client saying so.
    events   = { "UPDATE_INSTANCE_INFO", "BOSS_KILL", "ENCOUNTER_END" },
    volatile = true,
    cooldown = 30,
})

------------------------------------------------------------
-- COMMAND
------------------------------------------------------------

CN:RegisterCommand{
    name    = "instances",
    aliases = { "lockouts", "saved" },
    order   = 24,
    help    = "What you are saved to, and how much of it is left.",
    handler = function()
        local lockouts = Instances.Lockouts()

        if #lockouts == 0 then
            Print("You are not saved to anything.")
            Print("|cff8a8f96Lockouts appear here as soon as you kill a boss "
                .. "in a dungeon or raid that saves you.|r")
            return
        end

        Print("Saved to " .. #lockouts
            .. (#lockouts == 1 and " instance:" or " instances:"))

        for _, lockout in ipairs(lockouts) do
            CN.PrintLine("  " .. Instances.Describe(lockout))

            local bosses, note = Instances.RemainingBosses(lockout)

            for _, boss in ipairs(bosses) do
                CN.PrintLine("      |cff8a8f96" .. boss.name .. "|r")
            end

            if note then
                CN.PrintLine("      |cff8a8f96" .. note .. "|r")
            end
        end

        local summary = Instances.Summary()

        if summary.unfinished > 0 then
            Print(summary.bosses .. " "
                .. (summary.bosses == 1 and "boss" or "bosses")
                .. " still available across "
                .. summary.unfinished
                .. (summary.unfinished == 1 and " lockout." or " lockouts."))
        else
            Print("|cff8a8f96Everything you are saved to is cleared.|r")
        end
    end,
}

CN:RegisterCommand{
    name    = "drops",
    args    = "<name>",
    order   = 25,
    help    = "Which boss drops something, and whether you are locked to it.",
    handler = function(args)
        args = CN.Trim(args or "")

        if args == "" then
            Print("Usage: /cn drops <name of a mount, pet or item>")
            return
        end

        if not Blizzard.HasEncounterJournal() then
            Print("The Adventure Guide is not available in this client.")
            return
        end

        if Blizzard.IsEncounterJournalOpen() then
            -- Reading the journal moves its selection, which is what the
            -- player is looking at. Refuse rather than reach into it.
            Print("Close the Adventure Guide first" .. CN.DASH .. "reading it would change "
                .. "what you are looking at.")
            return
        end

        local results = Instances.WhereDoesItDrop(args)

        if #results == 0 then
            Print("Nothing in the Adventure Guide matches \"" .. args .. "\".")
            Print("|cff8a8f96Not everything drops from a boss; try the exact "
                .. "name the journal uses.|r")
            return
        end

        Print("\"" .. args .. "\" " .. CN.DASH .. " " .. #results
            .. (#results == 1 and " encounter:" or " encounters:"))

        for _, result in ipairs(results) do
            local line = "  " .. tostring(result.encounter or "?")

            if result.instance then
                line = line .. " |cff8a8f96in " .. result.instance .. "|r"
            end

            -- `x and f()` TRUNCATES TO ONE VALUE.
            --
            -- Written as `local a, b = cond and f()`, Lua adjusts the `and`
            -- expression to a single result, so `sharing` was always nil and
            -- the "on Heroic" clause below could never appear. Caught by
            -- luacheck as "variable is never set", which is exactly what it
            -- was -- and would have been invisible in play, because a missing
            -- clause looks like a lockout that is simply not shared.
            local lockout, sharing

            if result.instance then
                lockout, sharing = Instances.LockoutFor(result.instance)
            end

            if lockout then
                if lockout.complete then
                    -- "locked until 2d 3h" reads as a date and is a
                    -- DURATION. `FormatReset` returns "2d 3h"; the only
                    -- preposition that fits it is "for", and "resets in" is
                    -- the phrasing every other lockout line in the addon
                    -- already uses. 0.61.0.
                    line = line .. " |cffe2564clocked, resets in "
                        .. Instances.FormatReset(lockout.resetsIn)
                        .. ((sharing or 1) > 1
                            and (" on " .. tostring(lockout.difficulty
                                or "this difficulty"))
                            or "")
                        .. "|r"
                else
                    line = line .. " |cffffc74f" .. lockout.remaining
                        .. " left on your lockout|r"
                end
            end

            CN.PrintLine(line)
        end
    end,
}

return Instances
