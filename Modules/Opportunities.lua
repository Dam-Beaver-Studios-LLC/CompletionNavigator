-- Modules/Opportunities.lua
-- Completion Navigator :: things that expire.
--
-- The scoring formula gives limitedTimeBonus the heaviest weight of any
-- term (3.0), and until this module existed nothing ever set it. The engine
-- was built to prioritise content that disappears and had no idea what
-- disappears.
--
-- That is the whole point of the module: a world quest with two hours left
-- and a permanent quest in the same zone are not equally urgent, and the
-- recommendation should say so.

local ADDON_NAME, CN = ...

local Opportunities = CN:RegisterModule("Opportunities")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

local HOUR = 3600
local DAY  = 86400

------------------------------------------------------------
-- URGENCY
------------------------------------------------------------

-- Converts "seconds remaining" into the bonus the scorer multiplies by 3.0.
-- Deliberately steep: something with an hour left should dominate, something
-- with three days left should barely register.
function Opportunities.Urgency(secondsLeft)
    if not secondsLeft or secondsLeft <= 0 then
        return 0
    end

    if secondsLeft <= HOUR then
        return 3
    elseif secondsLeft <= 6 * HOUR then
        return 2
    elseif secondsLeft <= DAY then
        return 1.25
    elseif secondsLeft <= 3 * DAY then
        return 0.5
    end

    return 0.25
end

function Opportunities.FormatTimeLeft(seconds)
    -- "UNKNOWN" AND "EXPIRED" ARE DIFFERENT ANSWERS.
    --
    -- `Blizzard.GetQuestTimeLeft` returns nil when the client will not say,
    -- and this collapsed that into "expired". The sort puts unknowns LAST
    -- using `or math.huge`, so a live world quest appeared at the bottom of a
    -- list headed "soonest to expire", labelled expired -- contradicting
    -- itself on the same screen.
    --
    -- The addon has a convention for exactly this and it is used here now.
    if not seconds then
        return CN.WithConfidence(nil, CN.confidence.UNKNOWN) .. " time left"
    end

    if seconds <= 0 then
        return "expired"
    end

    if seconds < HOUR then
        return math.floor(seconds / 60) .. "m left"
    end

    if seconds < DAY then
        return math.floor(seconds / HOUR) .. "h left"
    end

    return math.floor(seconds / DAY) .. "d left"
end

------------------------------------------------------------
-- WORLD QUESTS
------------------------------------------------------------

-- World quests are the largest source of expiring content and the addon
-- could not see a single one before this.
function Opportunities.GetWorldQuests(mapID)
    mapID = mapID or select(1, CN.GetPlayerPosition())

    if not mapID then
        return {}
    end

    local results = {}

    for _, task in ipairs(Blizzard.GetWorldQuestsOnMap(mapID)) do
        local questID = task.questID

        if not Blizzard.IsQuestCompletedByCharacter(questID)
            and not CN.IsIgnored(CN.objectiveTypes.QUEST, questID)
            and not CN.IsDeferred(CN.objectiveTypes.QUEST, questID) then

            local secondsLeft = Blizzard.GetQuestTimeLeft(questID)
            local info        = Blizzard.GetWorldQuestInfo(questID)

            table.insert(results, {
                questID     = questID,
                mapID       = task.mapID,
                x           = task.x,
                y           = task.y,
                name        = info.title or CN.GetQuestName(questID) or ("World quest " .. questID),
                tagName     = info.tagName,
                isElite     = info.isElite,
                secondsLeft = secondsLeft,
            })
        end
    end

    table.sort(results, function(a, b)
        return (a.secondsLeft or math.huge) < (b.secondsLeft or math.huge)
    end)

    return results
end

------------------------------------------------------------
-- RESETS
------------------------------------------------------------

function Opportunities.GetResets()
    return {
        daily  = Blizzard.GetSecondsUntilDailyReset(),
        weekly = Blizzard.GetSecondsUntilWeeklyReset(),
    }
end

------------------------------------------------------------
-- WORLD EVENTS
------------------------------------------------------------

-- Calendar reads are relatively expensive and the answer changes daily, not
-- minute to minute.
local eventCache, eventCachedAt = nil, 0

function Opportunities.GetActiveEvents(force)
    if not force and eventCache and (time() - eventCachedAt) < 1800 then
        return eventCache
    end

    local active = {}

    for _, event in ipairs(Blizzard.GetTodaysEvents()) do
        if event.ongoing then
            table.insert(active, event)
        end
    end

    eventCache    = active
    eventCachedAt = time()

    return active
end

------------------------------------------------------------
-- CANDIDATES
------------------------------------------------------------

CN.RegisterCandidateProvider("Opportunities", function()
    local candidates = {}

    -- Only the map is needed now: travel cost is computed by CN.TravelCost,
    -- which reads the player's position itself so every provider costs a
    -- journey the same way.
    local playerMap = CN.GetPlayerPosition()

    for _, worldQuest in ipairs(Opportunities.GetWorldQuests(playerMap)) do
        local reasons = {}

        local urgency = Opportunities.Urgency(worldQuest.secondsLeft)

        if worldQuest.secondsLeft then
            table.insert(reasons, "world quest, "
                .. Opportunities.FormatTimeLeft(worldQuest.secondsLeft))
        else
            table.insert(reasons, "world quest")
        end

        if worldQuest.tagName then
            table.insert(reasons, worldQuest.tagName)
        end

        -- Costed through the real travel model rather than a straight line
        -- and a flat out-of-zone penalty, the same way quests have been
        -- since 0.42.0. World quests are exactly where this matters: they
        -- are scattered across a continent and they expire.
        local travel = CN.TravelCost(worldQuest.mapID, worldQuest.x, worldQuest.y)

        if worldQuest.mapID == playerMap then
            table.insert(reasons, "in your current zone")
        end

        table.insert(candidates, CN.NewObjective({
            id               = worldQuest.questID,
            type             = CN.objectiveTypes.QUEST,
            name             = worldQuest.name,
            mapID            = worldQuest.mapID,
            x                = worldQuest.x,
            y                = worldQuest.y,
            state            = CN.objectiveStates.AVAILABLE,
            completionValue  = 1,
            limitedTimeBonus = urgency,
            travelCost       = travel,
            expiresIn        = worldQuest.secondsLeft,
            reasons          = reasons,
        }))
    end

    -- ACTIVE EVENTS (0.43.0).
    --
    -- The calendar has been read since 0.20.0 and its answers went into
    -- `/cn events` and nowhere else. A holiday or a Timewalking week is a
    -- deadline in exactly the sense the ranking already understands -- it is
    -- gone on a known date and it is not coming back for a year -- so it
    -- belongs in the list rather than in a separate command.
    for _, event in ipairs(Opportunities.GetActiveEvents()) do
        if not CN.IsIgnored(CN.objectiveTypes.CURRENCY, event.title)
            and not CN.IsDeferred(CN.objectiveTypes.CURRENCY, event.title) then

            local reasons = { "world event, on now" }

            if event.endsIn then
                table.insert(reasons, "ends in "
                    .. Opportunities.FormatTimeLeft(event.endsIn))
            end

            -- Deliberately modest. The addon knows the event is running; it
            -- does not know which of its quests you have done, so claiming
            -- this is your most valuable next action would be a guess.
            table.insert(candidates, CN.NewObjective({
                id               = event.title,
                type             = CN.objectiveTypes.CURRENCY,
                name             = event.title,
                completionValue  = 2,
                limitedTimeBonus = event.endsIn
                    and Opportunities.Urgency(event.endsIn) or 1,
                travelCost       = CN.unknownLocationCost,
                expiresIn        = event.endsIn,
                reasons          = reasons,
            }))
        end
    end

    return candidates
end, { events = { "QUEST_LOG_UPDATE", "ZONE_CHANGED_NEW_AREA" }, volatile = true })

------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

CN:RegisterEvent("QUEST_LOG_UPDATE", function()
    -- World quest availability changes constantly; nothing to persist, the
    -- candidate provider reads live each time it is asked.
end)

CN:OnLogin(function()
    -- Warm the calendar so the first /cn events call has data.
    Opportunities.GetActiveEvents(true)
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "now",
    aliases = { "opportunities" },
    order   = 15,
    help    = "Show everything expiring soon.",
    handler = function()
        local resets = Opportunities.GetResets()

        if resets.daily then
            Print("Daily reset: " .. Opportunities.FormatTimeLeft(resets.daily))
        end

        if resets.weekly then
            Print("Weekly reset: " .. Opportunities.FormatTimeLeft(resets.weekly))
        end

        local events = Opportunities.GetActiveEvents()

        if #events > 0 then
            Print("Active events:")

            for _, event in ipairs(events) do
                Print("  " .. event.title)
            end
        end

        local worldQuests = Opportunities.GetWorldQuests()

        if #worldQuests == 0 then
            Print("No world quests available on your current map.")
            return
        end

        Print("World quests here (" .. #worldQuests .. "), soonest to expire:")

        for index = 1, math.min(#worldQuests, 10) do
            local worldQuest = worldQuests[index]

            Print("  " .. index .. ". " .. worldQuest.name
                .. " |cff8a8f96(" .. Opportunities.FormatTimeLeft(worldQuest.secondsLeft)
                .. (worldQuest.tagName and (", " .. worldQuest.tagName) or "") .. ")|r")
        end

        if #worldQuests > 10 then
            Print("  |cff8a8f96... and " .. (#worldQuests - 10) .. " more.|r")
        end
    end,
}

CN:RegisterCommand{
    name    = "events",
    order   = 16,
    help    = "List world events active today.",
    handler = function()
        local events = Opportunities.GetActiveEvents(true)

        if #events == 0 then
            Print("No world events detected as active today.")
            Print("|cff8a8f96The calendar may not have loaded yet; open it once and retry.|r")
            return
        end

        for _, event in ipairs(events) do
            Print("  " .. event.title
                .. " |cff8a8f96(" .. tostring(event.sequenceType) .. ")|r")
        end
    end,
}

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
