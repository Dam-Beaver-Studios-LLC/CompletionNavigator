-- Modules/Follow.lua
-- Completion Navigator :: stop consulting the addon, start following it.
--
-- Everything this addon knows is currently something you have to ASK for.
-- You type a command, read a list, close it, and play from memory. The
-- routing engine computes stops, orders them, improves the order, and then
-- hands all of that to a player who has to carry it in their head.
--
-- Follow mode makes it present. One small frame showing the stop you are
-- walking to and what you do when you get there, ticking things off as the
-- game reports them, advancing to the next stop when this one is clear, with
-- the arrow already pointed the right way.
--
-- THE RULE THIS FILE IS BUILT AROUND: a co-pilot that fights you is worse
-- than no co-pilot.
--
--   * Off by default. It is started deliberately and stopped with one word.
--   * It never re-points the waypoint while you are walking to something.
--     Advancing happens when the current stop is DONE, not on a timer.
--   * If you wander off and do something it did not suggest, it re-plans
--     around where you actually are rather than herding you back.
--   * It says nothing in chat while it runs. A frame that updates silently
--     is a companion; one that narrates is a nuisance.

local ADDON_NAME, CN = ...

local Follow = CN:RegisterModule("Follow")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint

local function Settings()
    return CN.Settings() or {}
end

------------------------------------------------------------
-- STATE
------------------------------------------------------------

Follow.active = false

-- The stop currently being walked to, and what it held when we set out.
local current = {
    hub        = nil,
    objectives = nil,
    startedAt  = nil,
}

local frame

Follow.recheckSeconds = 3

------------------------------------------------------------
-- WHAT IS LEFT AT THIS STOP
------------------------------------------------------------

-- An objective is done when it is no longer a candidate.
--
-- Deliberately defined by absence rather than by watching for completion
-- events. Events are per-type and there are eleven types; absence is one
-- rule that covers all of them, including the ones added later, and it is
-- also correct when something is finished by means the addon never saw.
-- The live index, memoised against the candidate generation.
--
-- PERFORMANCE, AND A BUG I SHIPPED IN 0.27.0: a single redraw calls this
-- three times -- once to test whether the stop is finished, once for the
-- header, once for the body -- and each call walked the entire candidate list
-- and built a fresh set of several thousand keys. Three full scans, three
-- throwaway tables, every three seconds, for an answer that cannot have
-- changed between them.
--
-- The candidate list already publishes a generation number that increments
-- when anything is rebuilt. Keyed on that, this is built once per actual
-- change instead of once per question.
local liveIndex = { generation = -1, keys = nil }

local function LiveKeys()
    -- COLLECT FIRST, THEN MEMOISE ON WHAT COLLECTING PRODUCED.
    --
    -- This read the generation, compared it to the memo, and returned early
    -- before calling CollectCandidates -- while stamping the memo with the
    -- generation from BEFORE the collect that followed it. Two things then
    -- went wrong together.
    --
    -- Marking a provider dirty deliberately does not advance the generation:
    -- only an actual rebuild does, and only CollectCandidates rebuilds. So
    -- once the stamp converged, this function stopped calling
    -- CollectCandidates, which meant nothing here ever rebuilt, which meant
    -- the generation could never advance, which meant the memo stayed valid
    -- forever. Follow mode stopped noticing that a stop was finished and sat
    -- on it -- unstuck only if something unrelated happened to collect, such
    -- as the heads-up display's timer, which is off by default.
    --
    -- Collecting when nothing is stale costs about two microseconds. Guarding
    -- it was never worth this.
    local candidates = CN.CollectCandidates() or {}

    local generation = 0

    if CN.GetCandidateCacheState then
        local ok, state = pcall(CN.GetCandidateCacheState)

        if ok and state then
            generation = state.generation or 0
        end
    end

    if liveIndex.keys and liveIndex.generation == generation then
        return liveIndex.keys
    end

    local keys = {}

    for _, candidate in ipairs(candidates) do
        keys[tostring(candidate.type) .. ":" .. tostring(candidate.id)] = true
    end

    liveIndex.generation = generation
    liveIndex.keys       = keys

    return keys
end

Follow.LiveKeys = LiveKeys

function Follow.Remaining(objectives)
    local remaining = {}

    if type(objectives) ~= "table" then
        return remaining
    end

    local live = LiveKeys()

    for _, objective in ipairs(objectives) do
        local key = tostring(objective.type) .. ":" .. tostring(objective.id)

        if live[key] then
            table.insert(remaining, objective)
        end
    end

    return remaining
end

function Follow.IsStopComplete()
    if not current.objectives then
        return false
    end

    return #Follow.Remaining(current.objectives) == 0
end

------------------------------------------------------------
-- CHOOSING A STOP
------------------------------------------------------------

-- The next stop is the first stop of a route built from where you are
-- STANDING, recomputed rather than remembered.
--
-- Remembering the route and walking down it would be cheaper and wrong: the
-- player who took a detour, took a flight path, or died and released is no
-- longer on the route that was computed, and the honest answer is to look at
-- where they are now.
function Follow.NextStop()
    local mapID, x, y = CN.GetPlayerPosition()

    if not mapID then
        return nil
    end

    local _, _, hubs = CN.BuildZoneRoute(mapID, x or 0.5, y or 0.5)

    if type(hubs) ~= "table" then
        return nil
    end

    for _, hub in ipairs(hubs) do
        local remaining = Follow.Remaining(hub.objectives)

        if #remaining > 0 then
            return hub, remaining
        end
    end

    return nil
end

function Follow.SetStop(hub, objectives)
    current.hub        = hub
    current.objectives = objectives or (hub and hub.objectives)
    current.startedAt  = time()

    if hub and hub.mapID and hub.x and hub.y then
        local label = CN.DescribeHub and CN.DescribeHub(hub) or "Next stop"

        CN.SetWaypoint(hub.mapID, hub.x, hub.y, label)
    end
end

-- Advance only when there is a reason to.
--
-- `force` exists for the player asking out loud ("/cn follow next"), which is
-- a different thing from the addon deciding on its own.
-- PROGRESS THE PLAYER CAN SEE.
--
-- Follow mode has always advanced silently: the waypoint moved, and that was
-- the only evidence anything had happened. Somebody walking a route for
-- twenty minutes had no sense of getting anywhere, which is the difference
-- between a tool that feels like it is working with you and one that feels
-- like a timer.
--
-- Counted per run rather than persisted -- "how far through tonight's route
-- am I" is a question about tonight.
Follow.completed = 0
Follow.startedWith = 0

function Follow.NoteStopCleared()
    Follow.completed = Follow.completed + 1

    local total = Follow.startedWith

    local text = "Stop cleared"

    if total > 0 then
        text = string.format("Stop %d of %d cleared", Follow.completed, total)
    end

    Print("|cff73b873" .. text .. "|r")

    -- A COMPLETION MOMENT, when there is genuinely nothing left. The route
    -- finishing is the only thing this addon does that is worth a small
    -- flourish, and it happens rarely enough to stay one.
    if total > 0 and Follow.completed >= total then
        Print("|cff5dd2fbRoute complete.|r " .. total .. " stops, "
            .. "everything on it done.")

        Follow.Celebrate()
    end

    return Follow.completed
end

-- Sound and a flash, both OFF by default, because unsolicited noise is the
-- most intrusive thing an addon can do and this addon's standing rule is that
-- nothing is taken over without being asked.
function Follow.Celebrate()
    local settings = CN.Settings()

    if not settings or not settings.cues then
        return false
    end

    if PlaySound and SOUNDKIT and SOUNDKIT.UI_QUEST_ROLLING_FORWARD_01 then
        pcall(PlaySound, SOUNDKIT.UI_QUEST_ROLLING_FORWARD_01)
    end

    if UIFrameFlash and frame then
        pcall(UIFrameFlash, frame, 0.3, 0.3, 1.2, false, 0, 0)
    end

    return true
end

function Follow.Advance(force)
    if not Follow.active then
        return false
    end

    -- NOT DURING A FIGHT.
    --
    -- Advancing mid-combat re-points the arrow and the waypoint at the next
    -- camp while the player is being hit by something at this one. It is the
    -- single most intrusive moment the addon could pick, and there is no
    -- version of "you finished that stop" that is urgent enough to deliver
    -- during a fight. The stop is still finished thirty seconds later.
    --
    -- A forced advance -- the player pressing the button -- is still obeyed.
    -- They can see their own screen.
    if not force and InCombatLockdown and InCombatLockdown() then
        Follow.deferred = true

        return false
    end

    if not force and current.hub and not Follow.IsStopComplete() then
        -- Still work here. Do not move the waypoint out from under someone
        -- who is walking toward it.
        return false
    end

    local hub, remaining = Follow.NextStop()

    if not hub then
        current.hub        = nil
        current.objectives = nil

        return false
    end

    -- Do not re-set the waypoint for the stop we are already on.
    if current.hub
        and current.hub.x == hub.x
        and current.hub.y == hub.y
        and not force then

        current.objectives = remaining

        return false
    end

    -- Something was actually finished if we are moving on from a stop we
    -- were already on and were not forced.
    if current.hub and not force then
        Follow.NoteStopCleared()
    end

    Follow.SetStop(hub, remaining)

    return true
end

------------------------------------------------------------
-- THE FRAME
------------------------------------------------------------

Follow.maxLines = 6

-- What the frame should say, computed separately from the frame itself so it
-- can be asserted without a client.
function Follow.Lines()
    local lines = {}

    if not current.hub then
        table.insert(lines, { text = "Nothing left to route here.", state = "NOTE" })

        return lines
    end

    local remaining = Follow.Remaining(current.objectives)

    local quests = CN:GetModule("Quests")

    local shown = 0

    local open = {}

    for _, objective in ipairs(remaining) do
        open[tostring(objective.type) .. ":" .. tostring(objective.id)] = true
    end

    for _, objective in ipairs(current.objectives or {}) do
        local stillOpen =
            open[tostring(objective.type) .. ":" .. tostring(objective.id)] == true

        if shown >= Follow.maxLines then
            table.insert(lines, {
                text  = "and " .. (#current.objectives - shown) .. " more",
                state = "NOTE",
            })
            break
        end

        local verb = "do"

        if objective.phase and quests and quests.PhaseVerb then
            verb = quests.PhaseVerb(objective.phase)
        end

        table.insert(lines, {
            text  = verb .. ": " .. tostring(objective.name or objective.id),
            state = stillOpen and "OPEN" or "DONE",
        })

        shown = shown + 1
    end

    return lines
end

function Follow.HeaderText()
    if not current.hub then
        return "Completion Navigator"
    end

    local remaining = #Follow.Remaining(current.objectives)

    local total = #(current.objectives or {})

    return string.format("Stop: %d of %d left", remaining, total)
end

local function BuildFrame()
    if frame or not CreateFrame then
        return frame
    end

    frame = CreateFrame("Frame", "CompletionNavigatorFollow", UIParent)

    frame:SetSize(240, 120)
    frame:SetFrameStrata("MEDIUM")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetClampedToScreen(true)

    local saved = Settings()

    saved.followPosition = saved.followPosition or {}

    frame:SetPoint(
        saved.followPosition.point or "TOPLEFT",
        UIParent,
        saved.followPosition.point or "TOPLEFT",
        saved.followPosition.x or 40,
        saved.followPosition.y or -200)

    frame.header = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.header:SetPoint("TOPLEFT", 8, -8)
    frame.header:SetJustifyH("LEFT")

    frame.body = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.body:SetPoint("TOPLEFT", frame.header, "BOTTOMLEFT", 0, -6)
    frame.body:SetJustifyH("LEFT")
    frame.body:SetJustifyV("TOP")

    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)

    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()

        local point, _, _, x, y = self:GetPoint()

        Settings().followPosition = { point = point, x = x, y = y }
    end)

    frame:Hide()

    return frame
end

Follow.BuildFrame = BuildFrame

function Follow.Redraw()
    if not frame then
        return
    end

    frame.header:SetText(Follow.HeaderText())

    local rendered = {}

    for _, line in ipairs(Follow.Lines()) do
        local colour = "|cffcccccc"

        if line.state == "DONE" then
            colour = "|cff73b873"
        elseif line.state == "NOTE" then
            colour = "|cff999999"
        end

        table.insert(rendered, colour
            .. (line.state == "DONE" and "x " or "- ")
            .. line.text .. "|r")
    end

    frame.body:SetText(table.concat(rendered, "\n"))
end

------------------------------------------------------------
-- THE LOOP
------------------------------------------------------------

local ticker

-- Driven by events, with a slow clock as a backstop rather than as the
-- mechanism. Position changes with no event attached -- walking into range of
-- something -- are the only reason the clock exists at all.
local function Tick()
    if not Follow.active then
        return
    end

    Follow.Advance(false)
    Follow.Redraw()
end

function Follow.Start()
    if Follow.active then
        return false
    end

    Follow.active = true

    Follow.completed = 0

    -- How many stops there were when the route started, so progress can be
    -- reported as a fraction rather than as a running count that means
    -- nothing on its own.
    local mapID, x, y = CN.GetPlayerPosition()

    local hubs

    if mapID and CN.BuildZoneRoute then
        local _, _, built = CN.BuildZoneRoute(mapID, x or 0.5, y or 0.5)

        hubs = built
    end

    Follow.startedWith = (type(hubs) == "table") and #hubs or 0

    Settings().follow = true

    BuildFrame()

    if frame then
        frame:Show()
    end

    Follow.Advance(true)
    Follow.Redraw()

    if C_Timer and C_Timer.NewTicker and not ticker then
        ticker = C_Timer.NewTicker(Follow.recheckSeconds, Tick)
    end

    return true
end

function Follow.Stop()
    Follow.active = false

    Settings().follow = false

    current.hub        = nil
    current.objectives = nil

    if ticker then
        ticker:Cancel()
        ticker = nil
    end

    if frame then
        frame:Hide()
    end

    return true
end

function Follow.Toggle()
    if Follow.active then
        Follow.Stop()
        return false
    end

    Follow.Start()

    return true
end

function Follow.CurrentStop()
    return current.hub, current.objectives
end

------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

-- Something finished. Check whether it emptied the stop; the check is cheap
-- and the alternative is a co-pilot that lags behind the player.
local function OnSomethingChanged()
    if Follow.active then
        Follow.Advance(false)
        Follow.Redraw()
    end
end

CN:RegisterEvent("QUEST_TURNED_IN", OnSomethingChanged)
CN:RegisterEvent("QUEST_ACCEPTED", OnSomethingChanged)
CN:RegisterEvent("QUEST_LOG_UPDATE", OnSomethingChanged)

-- A new zone invalidates the route entirely, so re-plan rather than advance.
CN:RegisterEvent("ZONE_CHANGED_NEW_AREA", function()
    if Follow.active then
        Follow.Advance(true)
        Follow.Redraw()
    end
end)

CN:OnLogin(function()
    if Settings().follow then
        Follow.Start()
    end
end)

------------------------------------------------------------
-- COMMAND
------------------------------------------------------------

CN:RegisterCommand{
    name    = "follow",
    aliases = { "copilot", "run" },
    args    = "[on, off, next, or nothing to toggle]",
    order   = 10,
    help    = "Follow the route: current stop on screen, advancing as you finish.",
    handler = function(args)
        args = string.lower(CN.Trim(args or ""))

        if args == "off" or args == "stop" then
            Follow.Stop()
            Print("Follow mode off.")
            return
        end

        if args == "next" or args == "skip" then
            if not Follow.active then
                Print("Follow mode is not running. |cffffff00/cn follow|r starts it.")
                return
            end

            Follow.Advance(true)
            Follow.Redraw()

            local hub = Follow.CurrentStop()

            if hub then
                Print("Moved on: " .. (CN.DescribeHub(hub) or "next stop") .. ".")
            else
                Print("Nothing left to route here.")
            end

            return
        end

        if args == "on" or args == "" then
            if args == "" and Follow.active then
                Follow.Stop()
                Print("Follow mode off.")
                return
            end

            Follow.Start()

            local hub = Follow.CurrentStop()

            if hub then
                Print("Following. First stop: "
                    .. (CN.DescribeHub(hub) or "ahead") .. ".")
                Print("|cff999999It advances when the stop is clear. "
                    .. "|cffffff00/cn follow off|r|cff999999 stops.|r")
            else
                Print("Following, but nothing here needs doing.")
            end

            return
        end

        Print("Usage: /cn follow [on | off | next]")
    end,
}

-- Whatever was held back during the fight happens the moment it ends.
CN:RegisterEvent("PLAYER_REGEN_ENABLED", function()
    if Follow.active and Follow.deferred then
        Follow.deferred = false

        Follow.Advance()
    end
end)

return Follow
