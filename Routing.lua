-- Routing.lua
-- Completion Navigator :: waypoint creation and zone clustering.
--
-- Navigation is delegated to a provider (TomTom first, Blizzard map pins
-- as fallback) rather than reimplemented. This file only decides WHERE to
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
        CN.Print("No waypoint provider is available. Install TomTom for navigation.")
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

-- Nearest-neighbour ordering from a starting point. Good enough for a
-- zone sweep; a proper route solver can replace this later.
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

        if objective.mapID == mapID then
            if objective.x and objective.y then
                table.insert(located, objective)
            else
                table.insert(skipped, objective)
            end
        end
    end

    local route = CN.OrderByProximity(located, startX, startY)

    CN.currentRoute = route

    return route, skipped
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
        local route, skipped = CN.BuildZoneRoute(mapID, playerX, playerY)

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

        local shown = math.min(#route, 10)

        for index = 1, shown do
            local objective = route[index]

            CN.Print(index .. ". " .. tostring(objective.name or objective.id)
                .. " |cff999999[" .. tostring(objective.type) .. "]|r")
        end

        if #route > shown then
            CN.Print("|cff999999... and " .. (#route - shown) .. " more.|r")
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
