-- Routing.lua
-- Completion Navigator :: waypoint creation and zone clustering.
--
-- Navigation is delegated to a provider. Native navigation is preferred and
-- needs nothing installed; TomTom and Blizzard map pins remain available and
-- a player can insist on either with /cn nav. This file only decides WHERE to
-- point.

local ADDON_NAME, CN = ...

------------------------------------------------------------
-- PROVIDER REGISTRY
------------------------------------------------------------

CN.waypointProviders = CN.waypointProviders or {}
CN.waypointOrder     = CN.waypointOrder or {}

-- provider = {
--     IsAvailable = function() return boolean end,
--     SetWaypoint = function(mapID, x, y, title) end,
--     ClearAll    = function() end,
-- }
function CN.RegisterWaypointProvider(name, provider, priority)
    CN.waypointProviders[name] = provider

    table.insert(CN.waypointOrder, { name = name, priority = priority or 100 })

    table.sort(CN.waypointOrder, function(a, b)
        return a.priority < b.priority
    end)
end

function CN.GetWaypointProvider()
    -- An explicit choice beats the priority order. Someone who runs TomTom and
    -- prefers its arrow said so on purpose, and "whichever addon happens to be
    -- loaded" is not a preference.
    if CN.GetPreferredWaypointProvider then
        local preferred, preferredName = CN.GetPreferredWaypointProvider()

        if preferred then
            return preferred, preferredName
        end
    end

    for _, entry in ipairs(CN.waypointOrder) do
        local provider = CN.waypointProviders[entry.name]

        if provider and provider.IsAvailable and provider.IsAvailable() then
            return provider, entry.name
        end
    end

    return nil, nil
end

------------------------------------------------------------
-- WAYPOINTS
------------------------------------------------------------

function CN.SetWaypoint(mapID, x, y, title)
    if not mapID or not x or not y then
        CN.Print("No coordinates are known for that objective.")
        return false
    end

    local provider, name = CN.GetWaypointProvider()

    if not provider then
        -- Native navigation needs only the map API, so reaching this means
        -- something is badly wrong rather than merely uninstalled.
        CN.Print("No waypoint provider is available.")
        CN.Print("|cff999999Try |cffffff00/cn nav auto|r to reset the choice.|r")
        return false
    end

    provider.SetWaypoint(mapID, x, y, title)

    CN.DebugPrint("Waypoint set via " .. tostring(name) .. ".")

    return true
end

-- The single entry point for "take me there", used by /cn go, the Navigate
-- button, the zone list, and the minimap button.
--
-- Order of preference:
--   1. Real coordinates -> a waypoint in TomTom or a Blizzard map pin.
--   2. An active quest with no coordinates -> hand it to Blizzard's own
--      quest tracking arrow, which knows where its own quests are.
--   3. Nothing -> say so plainly and explain why.
function CN.NavigateToObjective(objective)
    if type(objective) ~= "table" then
        CN.Print("Nothing to navigate to.")
        return false
    end

    local name = tostring(objective.name or objective.id or "that objective")

    if objective.mapID and objective.x and objective.y then
        if CN.SetWaypoint(objective.mapID, objective.x, objective.y, name) then
            CN.Print("Waypoint set: " .. name)
            return true
        end

        return false
    end

    -- Re-resolve: coordinates often appear once the player is on the right
    -- map, and the objective may have been built somewhere else.
    if objective.type == CN.objectiveTypes.QUEST and objective.id then
        local quests = CN:GetModule("Quests")

        if quests then
            local mapID, x, y = quests.GetLocation(objective.id)

            if mapID and x and y then
                objective.mapID, objective.x, objective.y = mapID, x, y

                if CN.SetWaypoint(mapID, x, y, name) then
                    CN.Print("Waypoint set: " .. name)
                    return true
                end

                return false
            end
        end

        if CN.Blizzard.IsQuestInLog(objective.id)
            and CN.Blizzard.SuperTrackQuest(objective.id) then

            CN.Print("No map coordinates for " .. name
                .. "; using Blizzard's quest tracking arrow instead.")

            return true
        end

        CN.Print("No coordinates are known for " .. name .. ".")
        CN.Print("The client exposes none for this quest and it is not in your log. "
            .. "Add them with |cffffff00/cn setloc " .. tostring(objective.id)
            .. " <mapID> <x> <y>|r.")

        return false
    end

    CN.Print("No coordinates are known for " .. name .. ".")

    if objective.type == CN.objectiveTypes.REPUTATION then
        CN.Print("Reputations have no single location.")
    end

    return false
end

function CN.ClearWaypoints()
    local provider = CN.GetWaypointProvider()

    if provider and provider.ClearAll then
        provider.ClearAll()
    end
end

------------------------------------------------------------
-- CLUSTERING
------------------------------------------------------------

-- Groups objectives by mapID so a zone sweep can be planned.
function CN.ClusterByMap(objectives)
    local clusters = {}

    for _, objective in ipairs(objectives) do
        if objective.mapID then
            clusters[objective.mapID] = clusters[objective.mapID] or {}
            table.insert(clusters[objective.mapID], objective)
        end
    end

    return clusters
end

------------------------------------------------------------
-- HUBS
------------------------------------------------------------

-- How close two stops must be to count as the same place, in yards.
--
-- Roughly "you can see both without moving". Quest givers standing together
-- at a camp, and the NPC you hand four quests back to, are the cases this
-- exists for.
CN.hubRadiusYards = 70

-- Distance between two objectives in real yards where the client can convert,
-- falling back to normalized map units scaled to a plausible zone size.
--
-- The fallback matters: map coordinates are normalized per map, so the same
-- 0.01 is a different real distance in every zone, and clustering on raw
-- normalized distance would make hubs enormous in small zones and useless in
-- large ones.
function CN.ObjectiveDistanceYards(a, b)
    if not (a and b and a.x and a.y and b.x and b.y) then
        return nil
    end

    if a.mapID and b.mapID and a.mapID ~= b.mapID then
        return nil
    end

    local navigation = CN:GetModule("Navigation")

    if navigation and a.mapID then
        local yards = navigation.DistanceYards(a.mapID, a.x, a.y, b.x, b.y)

        if yards then
            return yards
        end
    end

    -- Fallback: assume a zone is about 2000 yards across. Crude, and only
    -- used when the client will not convert.
    local dx = a.x - b.x
    local dy = a.y - b.y

    return math.sqrt((dx * dx) + (dy * dy)) * 2000
end

-- Groups objectives that share a place.
--
-- This is the heart of not running back and forth. A route over individual
-- objectives visits a camp three times if three things are there; a route
-- over HUBS visits it once and does all three.
--
-- Single-link clustering: a stop joins a hub if it is within the radius of
-- ANY member, which is what makes a row of quest givers along a road become
-- one stop rather than four.
function CN.ClusterByProximity(objectives, radiusYards)
    radiusYards = radiusYards or CN.hubRadiusYards

    local hubs = {}

    for _, objective in ipairs(objectives) do
        local joined = nil

        for _, hub in ipairs(hubs) do
            for _, member in ipairs(hub.objectives) do
                local distance = CN.ObjectiveDistanceYards(objective, member)

                if distance and distance <= radiusYards then
                    joined = hub
                    break
                end
            end

            if joined then break end
        end

        if joined then
            table.insert(joined.objectives, objective)
        else
            table.insert(hubs, {
                mapID      = objective.mapID,
                objectives = { objective },
            })
        end
    end

    -- A hub's position is the centre of what it contains, so routing between
    -- hubs is routing between places rather than between arbitrary members.
    for _, hub in ipairs(hubs) do
        local sumX, sumY = 0, 0

        for _, objective in ipairs(hub.objectives) do
            sumX = sumX + objective.x
            sumY = sumY + objective.y
        end

        hub.x = sumX / #hub.objectives
        hub.y = sumY / #hub.objectives

        -- Within a hub, order by what you would naturally do: collect quests,
        -- do the work, hand them back.
        local phaseOrder = { PICKUP = 1, ACTIVE = 2, TURNIN = 3 }

        table.sort(hub.objectives, function(a, b)
            local left  = phaseOrder[a.phase or ""] or 2
            local right = phaseOrder[b.phase or ""] or 2

            if left ~= right then
                return left < right
            end

            return tostring(a.name) < tostring(b.name)
        end)
    end

    return hubs
end

-- Describes what a hub is for, in the order you would do it.
function CN.DescribeHub(hub)
    local counts, order = {}, {}

    for _, objective in ipairs(hub.objectives) do
        local phase = objective.phase or "ACTIVE"

        if not counts[phase] then
            counts[phase] = 0
            table.insert(order, phase)
        end

        counts[phase] = counts[phase] + 1
    end

    local phaseOrder = { PICKUP = 1, ACTIVE = 2, TURNIN = 3 }

    table.sort(order, function(a, b)
        return (phaseOrder[a] or 2) < (phaseOrder[b] or 2)
    end)

    local parts = {}

    local quests = CN:GetModule("Quests")

    for _, phase in ipairs(order) do
        local verb = quests and quests.PhaseVerb(phase) or "do"

        table.insert(parts, verb .. " " .. counts[phase])
    end

    return table.concat(parts, ", ")
end

-- Nearest-neighbour ordering from a starting point. Good enough for a
-- zone sweep; a proper route solver can replace this later.
-- Squared distance is enough for comparisons and avoids a sqrt per pair.
local function Distance2(ax, ay, bx, by)
    local dx = (ax or 0.5) - (bx or 0.5)
    local dy = (ay or 0.5) - (by or 0.5)

    return (dx * dx) + (dy * dy)
end

-- Total length of a route starting from the player.
local function RouteLength(route, startX, startY)
    local total = 0

    local x, y = startX or 0.5, startY or 0.5

    for index = 1, #route do
        total = total + math.sqrt(Distance2(x, y, route[index].x, route[index].y))

        x, y = route[index].x or 0.5, route[index].y or 0.5
    end

    return total
end

CN.RouteLength = RouteLength

-- 2-opt improvement.
--
-- Nearest-neighbour has a characteristic failure: it takes the locally cheap
-- step every time and strands one far objective, then doubles back for it at
-- the end. On a twelve-stop zone sweep that is a visible, irritating detour.
--
-- 2-opt repeatedly reverses any segment that shortens the route. It converges
-- in milliseconds at this size and removes exactly that kind of crossing.
-- Bounded by passes so a pathological set cannot spin.
CN.routeOptimizePasses = 12

function CN.ImproveRoute(route, startX, startY)
    local count = #route

    if count < 4 then
        return route, 0
    end

    local before = RouteLength(route, startX, startY)

    for _ = 1, CN.routeOptimizePasses do
        local improved = false

        for i = 1, count - 1 do
            for k = i + 1, count do
                -- Reverse the segment i..k and keep it only if shorter.
                local candidate = {}

                for index = 1, i - 1 do
                    candidate[#candidate + 1] = route[index]
                end

                for index = k, i, -1 do
                    candidate[#candidate + 1] = route[index]
                end

                for index = k + 1, count do
                    candidate[#candidate + 1] = route[index]
                end

                if RouteLength(candidate, startX, startY) < RouteLength(route, startX, startY) - 1e-9 then
                    route = candidate
                    improved = true
                end
            end
        end

        if not improved then
            break
        end
    end

    local after = RouteLength(route, startX, startY)

    return route, before > 0 and ((before - after) / before) or 0
end

function CN.OrderByProximity(objectives, startX, startY)
    local remaining = {}

    for _, objective in ipairs(objectives) do
        table.insert(remaining, objective)
    end

    local ordered = {}
    local currentX, currentY = startX or 0.5, startY or 0.5

    while #remaining > 0 do
        local bestIndex, bestDistance

        for index, objective in ipairs(remaining) do
            local dx = (objective.x or 0.5) - currentX
            local dy = (objective.y or 0.5) - currentY
            local distance = (dx * dx) + (dy * dy)

            if not bestDistance or distance < bestDistance then
                bestDistance = distance
                bestIndex    = index
            end
        end

        local chosen = table.remove(remaining, bestIndex)

        table.insert(ordered, chosen)

        currentX = chosen.x or currentX
        currentY = chosen.y or currentY
    end

    return ordered
end

------------------------------------------------------------
-- ZONE ROUTES
------------------------------------------------------------

-- Builds an ordered sweep of everything currently actionable in one map.
-- Returns route, skipped -- where skipped are objectives that belong to the
-- zone conceptually but have no coordinates to route to.
function CN.BuildZoneRoute(mapID, startX, startY)
    local candidates = CN.CollectCandidates()

    local located, skipped = {}, {}

    for _, objective in ipairs(candidates) do
        CN.ScoreObjective(objective)

        -- Honour the type filter. A player who has hidden everything but
        -- quests is asking not to be routed to a pet, and a route that
        -- ignores that sends them somewhere they deliberately said they did
        -- not want to go. The filter is applied here rather than in the
        -- providers for the same reason it is applied in ranking: it is a
        -- display preference, and /cn breakdown must still see everything.
        local visible = (not CN.IsObjectiveTypeEnabled)
            or CN.IsObjectiveTypeEnabled(objective.type)

        if objective.mapID == mapID and visible then
            if objective.x and objective.y then
                table.insert(located, objective)
            else
                table.insert(skipped, objective)
            end
        end
    end

    -- Route between PLACES, not between objectives.
    --
    -- Ordering individual objectives sends you to a camp, away, and back again
    -- for each thing standing there. Grouping them first means you arrive
    -- once, do everything -- collect the quests, then the work, then hand them
    -- back -- and leave.
    local hubs = CN.ClusterByProximity(located)

    local orderedHubs = CN.OrderByProximity(hubs, startX, startY)

    local improvedHubs, saved = CN.ImproveRoute(orderedHubs, startX, startY)

    orderedHubs = improvedHubs

    if saved and saved > 0.001 then
        CN.DebugPrint(string.format("Route shortened by %.1f%% by 2-opt.", saved * 100))
    end

    -- Flatten back to a stop list, hub by hub, so every existing caller keeps
    -- working -- but the ORDER now keeps each place together.
    local route = {}

    for hubIndex, hub in ipairs(orderedHubs) do
        for _, objective in ipairs(hub.objectives) do
            objective.hub      = hubIndex
            objective.hubSize  = #hub.objectives

            table.insert(route, objective)
        end
    end

    CN.currentRoute = route
    CN.currentHubs  = orderedHubs

    return route, skipped, orderedHubs
end

-- Counts what remains in the zone, grouped by objective type. Deliberately
-- not a percentage: a percentage needs a trustworthy denominator, and the
-- static database is nowhere near complete enough to provide one.
function CN.SummarizeZone(route, skipped)
    local counts, order = {}, {}

    local function tally(list)
        for _, objective in ipairs(list) do
            local key = objective.type or "UNKNOWN"

            if not counts[key] then
                counts[key] = 0
                table.insert(order, key)
            end

            counts[key] = counts[key] + 1
        end
    end

    tally(route)
    tally(skipped)

    table.sort(order)

    return counts, order
end

------------------------------------------------------------
-- AUTO-ADVANCE
------------------------------------------------------------

-- Hands-free mode: when the thing you were pointed at is done, point at the
-- next one automatically.
--
-- Off by default and deliberately so. Taking over the waypoint without being
-- asked is hostile -- the player may be following a route of their own, and
-- TomTom arrows are shared with every other addon.
--
-- The rule for re-pointing is "the objective changed", not "time passed". A
-- waypoint that silently moves while you are walking to it is worse than one
-- that never moves at all.

local ticker
local lastAnnounced

function CN.IsAutoWaypointEnabled()
    local settings = CN.Settings()

    return settings and settings.autoWaypoint == true
end

-- Returns true when the objective we were pointing at is no longer the one
-- worth doing.
local function CurrentIsStale()
    local current = CN.currentRecommendation

    if not current then
        return true
    end

    -- Completed, or otherwise no longer available.
    if current.id and current.type then
        local state = CN.Explain(current.type, current.id)

        local states = CN.objectiveStates

        if state == states.COMPLETED
            or state == states.IGNORED
            or state == states.DEFERRED
            or state == states.UNOBTAINABLE then
            return true
        end
    end

    return false
end

function CN.AutoAdvance(reason, force)
    if not CN.IsAutoWaypointEnabled() then
        return false
    end

    if not force and not CurrentIsStale() then
        return false
    end

    local results = CN.Recommend(1)

    if #results == 0 then
        return false
    end

    local objective = results[1]

    -- Do not re-announce the same objective over and over.
    local signature = tostring(objective.type) .. ":" .. tostring(objective.id)

    if signature == lastAnnounced and not force then
        return false
    end

    CN.currentRecommendation = objective

    local navigated = CN.NavigateToObjective(objective)

    if navigated then
        lastAnnounced = signature

        CN.DebugPrint("Auto-advanced (" .. tostring(reason) .. ").")
    end

    return navigated
end

-- Completion events are the honest trigger: something finished, so what is
-- next may have changed.
for _, event in ipairs({
    "QUEST_TURNED_IN",
    "QUEST_REMOVED",
    "ACHIEVEMENT_EARNED",
    "NEW_PET_ADDED",
    "NEW_MOUNT_ADDED",
    "NEW_TOY_ADDED",
    "VIGNETTE_MINIMAP_UPDATED",
    "ZONE_CHANGED_NEW_AREA",
}) do
    CN:RegisterEvent(event, function()
        CN.AutoAdvance(event)
    end)
end

-- A slow backstop for objectives that expire rather than complete: a world
-- quest can run out while you are standing still, and no event fires for it.
function CN.StartAutoWaypointTicker()
    if ticker or not C_Timer or not C_Timer.NewTicker then
        return
    end

    ticker = C_Timer.NewTicker(60, function()
        if CN.IsAutoWaypointEnabled() then
            CN.AutoAdvance("ticker")
        end
    end)
end

function CN.StopAutoWaypointTicker()
    if ticker and ticker.Cancel then
        ticker:Cancel()
    end

    ticker = nil
end

CN:OnLogin(function()
    if CN.IsAutoWaypointEnabled() then
        CN.StartAutoWaypointTicker()
    end
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "zone",
    args    = "[stopNumber]",
    order   = 14,
    help    = "Route everything obtainable in this zone.",
    handler = function(args)
        local mapID, playerX, playerY = CN.GetPlayerPosition()

        if not mapID then
            CN.Print("Your current map could not be determined.")
            return
        end

        local zoneName = CN.Blizzard.GetMapName(mapID) or "this zone"

        local stop = CN.ToID(args)

        -- Re-routing on every call keeps the sweep honest as things complete.
        local route, skipped, hubs = CN.BuildZoneRoute(mapID, playerX, playerY)

        if stop then
            local objective = route[stop]

            if not objective then
                CN.Print("There is no stop " .. stop .. " in the current route.")
                return
            end

            CN.currentRecommendation = objective

            CN.NavigateToObjective(objective)

            return
        end

        if #route == 0 and #skipped == 0 then
            CN.Print(zoneName .. ": nothing actionable is known here.")
            CN.Print("Run |cffffff00/cn discoveractive|r and |cffffff00/cn repscan|r, "
                .. "then try again.")
            return
        end

        local counts, order = CN.SummarizeZone(route, skipped)

        local parts = {}

        for _, key in ipairs(order) do
            table.insert(parts, counts[key] .. " " .. string.lower(key))
        end

        CN.Print(zoneName .. " |cff999999(map " .. mapID .. ")|r - remaining: "
            .. table.concat(parts, ", "))

        -- Printed by PLACE, not by stop.
        --
        -- The stop numbers still run straight through the whole route, so
        -- /cn zone <n> keeps working, but the grouping is what tells you that
        -- four of them happen without moving.
        local stopNumber = 0
        local shown      = 0

        local quests = CN:GetModule("Quests")

        for hubIndex, hub in ipairs(hubs or {}) do
            if shown >= 10 then
                break
            end

            if #hub.objectives > 1 then
                CN.Print("|cff5DD2FB" .. hubIndex .. ") " .. #hub.objectives
                    .. " things here|r |cff999999-- " .. CN.DescribeHub(hub) .. "|r")
            end

            for _, objective in ipairs(hub.objectives) do
                stopNumber = stopNumber + 1

                if shown < 10 then
                    local verb = objective.phase and quests
                        and quests.PhaseVerb(objective.phase)

                    CN.Print((#hub.objectives > 1 and "   " or "")
                        .. stopNumber .. ". "
                        .. (verb and ("|cffffff00" .. verb .. "|r ") or "")
                        .. tostring(objective.name or objective.id)
                        .. " |cff999999[" .. tostring(objective.type) .. "]|r")

                    shown = shown + 1
                end
            end
        end

        if #route > shown then
            CN.Print("|cff999999... and " .. (#route - shown) .. " more.|r")
        end

        -- The whole point, stated plainly when it applies.
        local batched = 0

        for _, hub in ipairs(hubs or {}) do
            if #hub.objectives > 1 then
                batched = batched + #hub.objectives
            end
        end

        if batched > 0 then
            CN.Print("|cff999999" .. batched .. " of " .. #route
                .. " stops share a place with something else, so they are "
                .. "grouped rather than visited twice.|r")
        end

        if #skipped > 0 then
            CN.Print("|cff999999" .. #skipped
                .. " objective(s) here have no coordinates and cannot be routed.|r")
        end

        if #route > 0 then
            CN.currentRecommendation = route[1]

            CN.Print("|cffffff00/cn go|r for stop 1, or |cffffff00/cn zone <n>|r for another.")
        end
    end,
}

CN:RegisterCommand{
    name    = "go",
    args    = "[questID]",
    order   = 12,
    help    = "Set a waypoint to the recommendation, or to a quest.",
    handler = function(args)
        local objective

        local questID = CN.ToID(args)

        if questID then
            local quests = CN:GetModule("Quests")

            if not quests then
                CN.Print("The quest module is not loaded.")
                return
            end

            local mapID, x, y = quests.GetLocation(questID)

            -- id and type are load-bearing: without them
            -- NavigateToObjective cannot take the quest-specific path and
            -- falls through to the generic "no location" message.
            objective = {
                id    = questID,
                type  = CN.objectiveTypes.QUEST,
                name  = quests.GetName(questID, true) or ("Quest " .. questID),
                mapID = mapID,
                x     = x,
                y     = y,
            }
        else
            objective = CN.currentRecommendation

            if not objective then
                CN.Print("Nothing recommended yet. Run |cffffff00/cn next|r first.")
                return
            end
        end

        CN.NavigateToObjective(objective)
    end,
}

CN:RegisterCommand{
    name    = "auto",
    order   = 11,
    help    = "Toggle automatically re-pointing the waypoint as you finish things.",
    handler = function()
        local settings = CN.Settings()

        settings.autoWaypoint = not settings.autoWaypoint

        if settings.autoWaypoint then
            CN.StartAutoWaypointTicker()

            CN.Print("Auto-waypoint |cff00ff00on|r. "
                .. "The waypoint moves to the next objective as you finish things.")

            CN.AutoAdvance("enabled", true)
        else
            CN.StopAutoWaypointTicker()

            CN.Print("Auto-waypoint |cffff4444off|r. Waypoints stay where you put them.")
        end
    end,
}

CN:RegisterCommand{
    name    = "clearway",
    order   = 13,
    help    = "Clear waypoints this addon created.",
    handler = function()
        CN.ClearWaypoints()
        CN.Print("Waypoints cleared.")
    end,
}

------------------------------------------------------------
-- PLAYER POSITION
------------------------------------------------------------

function CN.GetPlayerPosition()
    if not C_Map then
        return nil, nil, nil
    end

    local mapID = C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")

    if not mapID then
        return nil, nil, nil
    end

    local position = C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(mapID, "player")

    if not position then
        return mapID, nil, nil
    end

    local x, y = position:GetXY()

    return mapID, x, y
end
