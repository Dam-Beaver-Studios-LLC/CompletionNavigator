-- Providers/TomTom.lua
-- Completion Navigator :: TomTom waypoint provider.
--
-- TomTom stays the navigation engine. Completion Navigator only decides
-- which waypoint is worth setting.

local ADDON_NAME, CN = ...

local provider = {}

local active = {}

function provider.IsAvailable()
    return _G.TomTom ~= nil and _G.TomTom.AddWaypoint ~= nil
end

function provider.SetWaypoint(mapID, x, y, title)
    if not provider.IsAvailable() then
        return
    end

    local uid = _G.TomTom:AddWaypoint(mapID, x, y, {
        title       = title or "Completion Navigator",
        persistent  = false,
        minimap     = true,
        world       = true,
        crazy       = true,
    })

    table.insert(active, uid)

    return uid
end

function provider.ClearAll()
    if not provider.IsAvailable() then
        return
    end

    for _, uid in ipairs(active) do
        pcall(_G.TomTom.RemoveWaypoint, _G.TomTom, uid)
    end

    active = {}
end

CN.RegisterWaypointProvider("TomTom", provider, 10)

------------------------------------------------------------
-- BLIZZARD MAP PIN FALLBACK
------------------------------------------------------------

local blizzardProvider = {}

function blizzardProvider.IsAvailable()
    return C_Map ~= nil and C_Map.SetUserWaypoint ~= nil
end

function blizzardProvider.SetWaypoint(mapID, x, y)
    if not blizzardProvider.IsAvailable() then
        return
    end

    local point = UiMapPoint and UiMapPoint.CreateFromCoordinates(mapID, x, y)

    if not point then
        return
    end

    C_Map.SetUserWaypoint(point)

    if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
        C_SuperTrack.SetSuperTrackedUserWaypoint(true)
    end
end

function blizzardProvider.ClearAll()
    if C_Map and C_Map.ClearUserWaypoint then
        C_Map.ClearUserWaypoint()
    end
end

CN.RegisterWaypointProvider("Blizzard", blizzardProvider, 20)
