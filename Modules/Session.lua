-- Modules/Session.lua
-- Completion Navigator :: "I have forty minutes. What should I do?"
--
-- The single most common shape a play session actually has, and the addon
-- had nothing to say about it. It could rank everything and route between
-- stops, and it could not answer the one question a person with a job and a
-- bedtime asks before logging in.
--
-- WHY THIS IS HARD TO DO HONESTLY.
--
-- A plan that fits in forty minutes requires knowing how long things take,
-- and the client does not say. The tempting move is to make numbers up --
-- "quests take four minutes" -- and present them in a font that looks like
-- measurement. This addon has a standing rule against exactly that.
--
-- So the estimate is built from two halves, and only one of them is guessed:
--
--   TRAVEL is computed. The router already knows the real yard distance
--   between stops, and this module measures how fast you actually move by
--   watching your position. That is arithmetic on observations.
--
--   TASK TIME is learned. Every completion is timed against when the
--   objective was first offered as the current stop, and the median per type
--   is kept. Until a type has been seen enough times, it has NO estimate and
--   the plan says so rather than inventing one.
--
-- A plan therefore starts out honest and vague -- "these stops, distance
-- known, duration not yet" -- and sharpens as it watches you play. That is
-- slower to become useful than a table of invented constants, and it is the
-- only version that is ever true.

local ADDON_NAME, CN = ...

local Session = CN:RegisterModule("Session")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint

------------------------------------------------------------
-- MEASURED TRAVEL SPEED
------------------------------------------------------------

-- Yards per second. Seeded with a walking-speed figure that is immediately
-- replaced by measurement; it exists so the first plan is not divided by nil.
Session.defaultSpeed = 7

Session.minSamples = 5

local speed = {
    lastMapID = nil,
    lastX     = nil,
    lastY     = nil,
    lastAt    = nil,
    samples   = {},
}

Session.speedSampleCap = 40

-- Called on a slow clock. Measures the distance covered since the last look.
--
-- Deliberately discards anything implausible: a teleport, a flight path, a
-- hearthstone or a zone change would otherwise register as a very fast
-- player and make every estimate useless.
function Session.Observe()
    local mapID, x, y = CN.GetPlayerPosition()

    local now = time()

    if not mapID or not x or not y then
        return nil
    end

    local previousMap, previousX, previousY, previousAt =
        speed.lastMapID, speed.lastX, speed.lastY, speed.lastAt

    speed.lastMapID, speed.lastX, speed.lastY, speed.lastAt = mapID, x, y, now

    if previousMap ~= mapID or not previousAt then
        return nil
    end

    local elapsed = now - previousAt

    if elapsed <= 0 or elapsed > 30 then
        return nil
    end

    local nav = CN:GetModule("Navigation")

    if not nav or not nav.DistanceYards then
        return nil
    end

    local yards = nav.DistanceYards(mapID, previousX, previousY, x, y)

    if not yards or yards <= 0 then
        return nil
    end

    local observed = yards / elapsed

    -- A player on foot does about 7 yards a second; mounted, roughly 14 to
    -- 20. Anything above 60 is not travel, it is a loading screen.
    if observed < 0.5 or observed > 60 then
        return nil
    end

    table.insert(speed.samples, observed)

    while #speed.samples > Session.speedSampleCap do
        table.remove(speed.samples, 1)
    end

    return observed
end

-- The median, not the mean: standing still for a minute should not halve the
-- estimate, and one flight path should not double it.
local function Median(values)
    if #values == 0 then
        return nil
    end

    local sorted = {}

    for index = 1, #values do
        sorted[index] = values[index]
    end

    table.sort(sorted)

    local middle = math.floor(#sorted / 2) + 1

    if #sorted % 2 == 1 then
        return sorted[middle]
    end

    return (sorted[middle - 1] + sorted[middle]) / 2
end

Session.Median = Median

function Session.Speed()
    if #speed.samples >= Session.minSamples then
        return Median(speed.samples), true
    end

    return Session.defaultSpeed, false
end

function Session.SpeedSampleCount()
    return #speed.samples
end

------------------------------------------------------------
-- LEARNED TASK DURATION
------------------------------------------------------------

local function Durations()
    return CN.Account("taskDurations")
end

Session.Durations = Durations

Session.minDurationSamples = 4
Session.durationSampleCap  = 25

-- When each objective was first put in front of the player. A completion
-- timed from here is "how long it took once it was the thing to do", which is
-- the number a plan needs.
local offeredAt = {}

function Session.NoteOffered(objective)
    if type(objective) ~= "table" or not objective.type or not objective.id then
        return
    end

    local key = tostring(objective.type) .. ":" .. tostring(objective.id)

    offeredAt[key] = offeredAt[key] or time()
end

function Session.NoteCompleted(objectiveType, id)
    if not objectiveType or not id then
        return nil
    end

    local key = tostring(objectiveType) .. ":" .. tostring(id)

    local started = offeredAt[key]

    offeredAt[key] = nil

    if not started then
        return nil
    end

    local elapsed = time() - started

    -- Anything over twenty minutes was not "doing the thing", it was living
    -- your life with the thing still on the list.
    if elapsed <= 0 or elapsed > 1200 then
        return nil
    end

    local store = Durations()

    store[objectiveType] = store[objectiveType] or {}

    table.insert(store[objectiveType], elapsed)

    while #store[objectiveType] > Session.durationSampleCap do
        table.remove(store[objectiveType], 1)
    end

    DebugPrint(objectiveType .. " took " .. elapsed .. "s ("
        .. #store[objectiveType] .. " samples).")

    return elapsed
end

-- Seconds this type usually takes, or NIL when the addon has not watched it
-- often enough to have an opinion. Nil is a real answer here and every
-- caller must handle it rather than substituting a guess.
function Session.TypicalSeconds(objectiveType)
    local samples = Durations()[objectiveType]

    if not samples or #samples < Session.minDurationSamples then
        return nil
    end

    return Median(samples)
end

function Session.HasEnoughData()
    for _, samples in pairs(Durations()) do
        if #samples >= Session.minDurationSamples then
            return true
        end
    end

    return false
end

------------------------------------------------------------
-- THE PLAN
------------------------------------------------------------

-- Estimates a stop: travel to it, plus the work at it.
--
-- Returns seconds and a confidence flag. `false` means part of this was not
-- measured, and callers must say so out loud.
function Session.EstimateHub(hub, fromX, fromY)
    local confident = true

    local nav = CN:GetModule("Navigation")

    local travelSeconds = 0

    if nav and nav.DistanceYards and hub.mapID and hub.x and hub.y
        and fromX and fromY then

        local yards = nav.DistanceYards(hub.mapID, fromX, fromY, hub.x, hub.y)

        if yards then
            local rate, measured = Session.Speed()

            travelSeconds = yards / math.max(0.5, rate)

            if not measured then
                confident = false
            end
        else
            confident = false
        end
    else
        confident = false
    end

    local workSeconds = 0

    for _, objective in ipairs(hub.objectives or {}) do
        local typical = Session.TypicalSeconds(objective.type)

        if typical then
            workSeconds = workSeconds + typical
        else
            confident = false
        end
    end

    return travelSeconds + workSeconds, confident, travelSeconds, workSeconds
end

-- Builds a route and takes stops from the front of it until the budget is
-- spent.
--
-- Takes from the FRONT rather than choosing the best-fitting subset. The
-- route is already ordered to minimise walking; cherry-picking stops out of
-- it produces a plan that fits the clock and makes you cross the zone twice.
function Session.Plan(minutes)
    local budget = (tonumber(minutes) or 30) * 60

    local mapID, x, y = CN.GetPlayerPosition()

    local plan = {
        minutes   = budget / 60,
        stops     = {},
        seconds   = 0,
        confident = true,
        skipped   = 0,
    }

    if not mapID then
        return plan
    end

    local _, _, hubs = CN.BuildZoneRoute(mapID, x or 0.5, y or 0.5)

    if type(hubs) ~= "table" then
        return plan
    end

    local currentX, currentY = x or 0.5, y or 0.5

    for _, hub in ipairs(hubs) do
        local seconds, confident, travel, work =
            Session.EstimateHub(hub, currentX, currentY)

        if plan.seconds + seconds > budget and #plan.stops > 0 then
            plan.skipped = plan.skipped + 1
        else
            table.insert(plan.stops, {
                hub       = hub,
                seconds   = seconds,
                travel    = travel,
                work      = work,
                summary   = CN.DescribeHub and CN.DescribeHub(hub) or nil,
                confident = confident,
            })

            plan.seconds = plan.seconds + seconds

            if not confident then
                plan.confident = false
            end

            currentX, currentY = hub.x or currentX, hub.y or currentY
        end
    end

    return plan
end

function Session.FormatDuration(seconds)
    if not seconds or seconds <= 0 then
        return "0m"
    end

    local minutes = math.floor(seconds / 60 + 0.5)

    if minutes < 60 then
        return minutes .. "m"
    end

    return string.format("%dh %dm", math.floor(minutes / 60), minutes % 60)
end

------------------------------------------------------------
-- WIRING
------------------------------------------------------------

-- Everything recommended is something the player has been offered, so this
-- is where the clock starts for duration learning.
CN.RegisterCandidateDecorator("SessionTiming", function(objective)
    Session.NoteOffered(objective)

    return objective
end)

CN:RegisterEvent("QUEST_TURNED_IN", function(_, questID)
    Session.NoteCompleted(CN.objectiveTypes.QUEST, questID)
end)

CN:RegisterEvent("NEW_PET_ADDED", function()
    -- The client does not say which pet, so nothing can be timed here
    -- honestly. Left deliberately unhandled rather than attributing the
    -- elapsed time to a guess.
end)

local ticker

CN:OnLogin(function()
    Session.Observe()

    if C_Timer and C_Timer.NewTicker and not ticker then
        ticker = C_Timer.NewTicker(10, Session.Observe)
    end
end)

------------------------------------------------------------
-- COMMAND
------------------------------------------------------------

CN:RegisterCommand{
    name    = "plan",
    aliases = { "time", "budget" },
    args    = "<minutes>",
    order   = 13,
    help    = "What fits in the time you actually have.",
    handler = function(args)
        local minutes = tonumber(CN.Trim(args or ""))

        if not minutes or minutes <= 0 then
            Print("Usage: |cffffff00/cn plan 30|r")
            return
        end

        local plan = Session.Plan(minutes)

        if #plan.stops == 0 then
            Print("Nothing here to plan around.")
            return
        end

        Print(string.format("%d stop%s, about %s of the %dm you have:",
            #plan.stops,
            #plan.stops == 1 and "" or "s",
            Session.FormatDuration(plan.seconds),
            minutes))

        for index, stop in ipairs(plan.stops) do
            Print(string.format("  %d. |cffffff00%s|r |cff999999%s|r",
                index,
                tostring(stop.summary or "stop"),
                stop.confident and Session.FormatDuration(stop.seconds)
                    or "time unknown"))
        end

        if plan.skipped > 0 then
            Print("|cff999999" .. plan.skipped
                .. " further stop(s) did not fit.|r")
        end

        if not plan.confident then
            local rate, measured = Session.Speed()

            Print("|cffffff00Some of this is not measured yet.|r "
                .. "|cff999999Travel speed: "
                .. (measured and string.format("%.0f yd/s from %d samples",
                        rate, Session.SpeedSampleCount())
                    or "still learning")
                .. ". Task times are learned from your own play, so the "
                .. "estimate sharpens as you go rather than starting from "
                .. "numbers nobody measured.|r")
        end
    end,
}

return Session
