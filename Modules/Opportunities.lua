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
    if not seconds or seconds <= 0 then
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

    local playerMap, playerX, playerY = CN.GetPlayerPosition()

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

        local travel = 0

        if worldQuest.x and worldQuest.y and playerX and playerY
            and worldQuest.mapID == playerMap then

            local dx = worldQuest.x - playerX
            local dy = worldQuest.y - playerY

            travel = math.sqrt((dx * dx) + (dy * dy)) * 10

            table.insert(reasons, "in your current zone")
        elseif worldQuest.mapID ~= playerMap then
            travel = 25
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

    return candidates
end)

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
                .. " |cff999999(" .. Opportunities.FormatTimeLeft(worldQuest.secondsLeft)
                .. (worldQuest.tagName and (", " .. worldQuest.tagName) or "") .. ")|r")
        end

        if #worldQuests > 10 then
            Print("  |cff999999... and " .. (#worldQuests - 10) .. " more.|r")
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
            Print("|cff999999The calendar may not have loaded yet; open it once and retry.|r")
            return
        end

        for _, event in ipairs(events) do
            Print("  " .. event.title
                .. " |cff999999(" .. tostring(event.sequenceType) .. ")|r")
        end
    end,
}

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
