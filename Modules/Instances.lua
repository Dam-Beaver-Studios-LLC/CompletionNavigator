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
        text = text .. " |cff8a8f96(searched on " .. first.difficulty .. ")|r"
    end

    if #results > 1 then
        text = text .. " (and " .. (#results - 1) .. " other "
            .. (#results == 2 and "encounter" or "encounters") .. ")"
    end

    return text, first
end

-- Is the player locked to the instance a drop comes from? This is the
-- difference between "go and kill it" and "not until Tuesday".
function Instances.LockoutFor(instanceName)
    if not instanceName then
        return nil
    end

    for _, lockout in ipairs(Instances.Lockouts()) do
        if lockout.name == instanceName then
            return lockout
        end
    end

    return nil
end

------------------------------------------------------------
-- FORMATTING
------------------------------------------------------------

function Instances.FormatReset(seconds)
    local vault = CN:GetModule("Vault")

    if vault and vault.FormatReset then
        return vault.FormatReset(seconds)
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
        -- A cleared lockout is not an objective, and a lockout nobody has
        -- started is a decision about the evening rather than a next action.
        if not lockout.complete
            and lockout.defeated > 0
            and lockout.remaining > 0
            and lockout.remaining <= Instances.maxRemaining
            and not CN.IsIgnored(CN.objectiveTypes.INSTANCE, lockout.name)
            and not CN.IsDeferred(CN.objectiveTypes.INSTANCE, lockout.name) then

            local reasons = {
                lockout.defeated .. " of " .. lockout.encounters
                    .. " already defeated -- those kills expire at the reset",
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
                id               = lockout.name,
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
            Print("  " .. Instances.Describe(lockout))

            local bosses, note = Instances.RemainingBosses(lockout)

            for _, boss in ipairs(bosses) do
                Print("      |cff8a8f96" .. boss.name .. "|r")
            end

            if note then
                Print("      |cff8a8f96" .. note .. "|r")
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
            Print("Close the Adventure Guide first -- reading it would change "
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

        Print("\"" .. args .. "\" -- " .. #results
            .. (#results == 1 and " encounter:" or " encounters:"))

        for _, result in ipairs(results) do
            local line = "  " .. tostring(result.encounter or "?")

            if result.instance then
                line = line .. " |cff8a8f96in " .. result.instance .. "|r"
            end

            local lockout = result.instance and Instances.LockoutFor(result.instance)

            if lockout then
                if lockout.complete then
                    line = line .. " |cffe2564clocked until "
                        .. Instances.FormatReset(lockout.resetsIn) .. "|r"
                else
                    line = line .. " |cffffc74f" .. lockout.remaining
                        .. " left on your lockout|r"
                end
            end

            Print(line)
        end
    end,
}

return Instances
