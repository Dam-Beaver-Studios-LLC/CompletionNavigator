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

-- Returns true and the uid, or false and why not -- the same contract as the
-- Blizzard provider below, so `CN.SetWaypoint` can tell the player the truth
-- whichever one is in use.
function provider.SetWaypoint(mapID, x, y, title)
    if not provider.IsAvailable() then
        return false, "TomTom is not loaded"
    end

    local uid = _G.TomTom:AddWaypoint(mapID, x, y, {
        title       = title or "Completion Navigator",
        persistent  = false,
        minimap     = true,
        world       = true,
        crazy       = true,
    })

    if not uid then
        return false, "TomTom refused the waypoint"
    end

    table.insert(active, uid)

    return true, uid
end

function provider.ClearAll()
    if not provider.IsAvailable() then
        return false
    end

    local removed = #active

    for _, uid in ipairs(active) do
        pcall(_G.TomTom.RemoveWaypoint, _G.TomTom, uid)
    end

    active = {}

    return removed > 0
end

CN.RegisterWaypointProvider("TomTom", provider, 10)

------------------------------------------------------------
-- BLIZZARD MAP PIN FALLBACK
------------------------------------------------------------

local blizzardProvider = {}

function blizzardProvider.IsAvailable()
    return C_Map ~= nil and C_Map.SetUserWaypoint ~= nil
end

-- WHETHER THIS ACTUALLY WORKED IS NOW REPORTED.
--
-- This returned nothing at all, and every early return was silent -- so
-- `CN.SetWaypoint` discarded the result, returned `true` unconditionally, and
-- `/cn go` printed "Waypoint set: <name>" whether or not a pin appeared.
--
-- And the client refuses more often than the addon assumed. User waypoints
-- cannot be placed on dungeon and raid maps, on the cosmic and continent
-- maps, or on several instanced maps -- `C_Map.CanSetUserWaypointOnMap`
-- exists to say so and was called nowhere in this addon. In every one of
-- those cases the player was told a waypoint had been set and then sent to
-- look for an arrow that was never there.
function blizzardProvider.SetWaypoint(mapID, x, y)
    if not blizzardProvider.IsAvailable() then
        return false
    end

    if C_Map.CanSetUserWaypointOnMap then
        local asked, allowed = pcall(C_Map.CanSetUserWaypointOnMap, mapID)

        if asked and not allowed then
            return false, "the game does not allow a waypoint on this map"
        end
    end

    local point = UiMapPoint and UiMapPoint.CreateFromCoordinates(mapID, x, y)

    if not point then
        return false, "the client would not build a map point"
    end

    -- Guarded, as the identical call in Navigation.lua already was. Same API,
    -- and it was pcall'd in one place and bare in the other.
    local placed = pcall(C_Map.SetUserWaypoint, point)

    if not placed then
        return false, "the client refused the waypoint"
    end

    -- WHOSE PIN THIS IS.
    --
    -- There is exactly one user waypoint, and it belongs to the player unless
    -- this addon put it there. Remembering that is what lets ClearAll below
    -- refuse to delete a pin somebody placed by hand.
    blizzardProvider.owned = { mapID = mapID, x = x, y = y }

    if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
        C_SuperTrack.SetSuperTrackedUserWaypoint(true)
    end

    return true
end

function blizzardProvider.ClearAll()
    if not C_Map or not C_Map.ClearUserWaypoint then
        return false
    end

    -- ONLY IF IT IS OURS.
    --
    -- `ClearUserWaypoint` removes THE user waypoint -- there is one, and it
    -- is the player's. `/cn clearway`, stopping follow mode and every
    -- provider switch called it unconditionally, so an addon whose standing
    -- rule is that it does not act deleted a pin the player had placed by
    -- hand. The TomTom provider next door has always done this correctly: it
    -- tracks the UIDs it created and removes only those.
    if not blizzardProvider.owned then
        return false
    end

    -- And only if it is still the one we set. A player who has moved the pin
    -- since owns it again.
    if C_Map.GetUserWaypoint then
        local asked, current = pcall(C_Map.GetUserWaypoint)

        if asked and current then
            -- THE MAP WAS THE WHOLE COMPARISON, AND IT IS THE PART THAT
            -- DOES NOT CHANGE. FIXED IN 0.61.0.
            --
            -- The comment above says "a player who has moved the pin since
            -- owns it again" -- and then the code checked only the map id.
            -- Moving a pin almost always leaves it on the SAME map: that is
            -- what moving a pin means. So the one case this guard exists for
            -- was the one case it could not detect, and `/cn clearway` went
            -- on deleting a hand-placed pin in the zone the player was
            -- standing in. It caught only the case where the player had
            -- placed a pin in a different zone entirely, which is rare and
            -- which the map-id check would have caught by accident.
            --
            -- The coordinates are compared with a tolerance because the
            -- client round-trips them through its own packing and hands back
            -- values that differ in the last few digits. A hundredth of a map
            -- unit is well inside "the player did not move this" and well
            -- outside any deliberate drag.
            local owned = blizzardProvider.owned

            local sameMap = current.uiMapID == owned.mapID

            local samePlace = sameMap
                and owned.x and owned.y
                and current.position
                and math.abs((current.position.x or -1) - owned.x) < 0.01
                and math.abs((current.position.y or -1) - owned.y) < 0.01

            -- No position from the client is not evidence the pin moved, so
            -- the map check stands alone in that case rather than the
            -- addon refusing to clean up after itself forever.
            if current.position and not samePlace then
                blizzardProvider.owned = nil

                return false
            end

            if not sameMap then
                blizzardProvider.owned = nil

                return false
            end
        end
    end

    pcall(C_Map.ClearUserWaypoint)

    blizzardProvider.owned = nil

    return true
end

CN.RegisterWaypointProvider("Blizzard", blizzardProvider, 20)
