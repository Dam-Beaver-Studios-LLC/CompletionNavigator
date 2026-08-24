-- Modules/Exploration.lua
-- Completion Navigator :: map exploration.
--
-- The map API exposes which overlay textures you have revealed but never how
-- many exist, so a genuine "percent explored" cannot be computed from it.
-- The Exploration achievement category does carry one criterion per subzone,
-- which is the only countable exploration data the client offers -- and each
-- unfinished criterion is the literal name of a place you have not been.
--
-- That turns out to be the more useful shape anyway: "Eversong Woods, 3 of
-- 12 subzones, missing Sunsail Anchorage" is actionable. "78% explored" is
-- not.

local ADDON_NAME, CN = ...

local Exploration = CN:RegisterModule("Exploration")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

local function Store()
    return CN.Account("exploration")
end

Exploration.Store = Store

------------------------------------------------------------
-- SCAN
------------------------------------------------------------

function Exploration.Scan()
    local store = Store()

    local seen, complete = 0, 0

    for _, achievement in ipairs(Blizzard.GetExplorationAchievements()) do
        store[achievement.achievementID] = {
            achievementID = achievement.achievementID,
            name          = achievement.name,
            completed     = achievement.completed,
            done          = achievement.done,
            criteria      = achievement.criteria,
            lastSeen      = time(),
        }

        seen = seen + 1

        if achievement.completed then
            complete = complete + 1
        end
    end

    CN.MarkScanned("exploration")

    return seen, complete
end

------------------------------------------------------------
-- QUERIES
------------------------------------------------------------

function Exploration.Summary()
    local counts = {
        zones     = 0,
        complete  = 0,
        criteria  = 0,
        done      = 0,
    }

    for _, record in pairs(Store()) do
        counts.zones    = counts.zones + 1
        counts.criteria = counts.criteria + (record.criteria or 0)
        counts.done     = counts.done + (record.done or 0)

        if record.completed then
            counts.complete = counts.complete + 1
        end
    end

    return counts
end

-- Zones with the fewest subzones left, so the cheapest wins come first.
function Exploration.Closest(limit)
    local rows = {}

    for _, record in pairs(Store()) do
        if not record.completed and (record.criteria or 0) > 0 then
            table.insert(rows, {
                achievementID = record.achievementID,
                name          = record.name,
                done          = record.done,
                criteria      = record.criteria,
                remaining     = record.criteria - record.done,
            })
        end
    end

    table.sort(rows, function(a, b)
        if a.remaining == b.remaining then
            return (a.name or "") < (b.name or "")
        end

        return a.remaining < b.remaining
    end)

    local results = {}

    for index = 1, math.min(limit or 10, #rows) do
        table.insert(results, rows[index])
    end

    return results
end

-- The exploration achievement matching the zone the player is standing in,
-- matched on name because no API maps a UiMapID to its achievement.
-- THE MAP FIRST, THE NAME ONLY AS A FALLBACK.
--
-- This was a substring match over an UNORDERED walk of every exploration
-- achievement the account has, returning the first hit. Retail has two zones
-- called Nagrand and two called Shadowmoon Valley, each with its own "Explore
-- ..." achievement -- both contain the needle, and which one came back was
-- arbitrary and could differ between sessions.
--
-- That was cosmetic while nothing wrote through it. As of this release
-- `RefreshCurrentZone` DOES write through it, so finishing Draenor's Nagrand
-- would stamp `completed = true` on Outland's record, which then vanishes
-- from the list permanently -- only a full `/cn explorescan` rewrites it, and
-- nothing runs one on its own.
--
-- So: the map id, recorded when the record is next refreshed, is the key.
-- The name match survives as the way a record acquires its map id the first
-- time, and is now exact rather than a substring.
function Exploration.ForCurrentZone()
    local mapID = CN.GetPlayerPosition()

    local store = Store()

    if mapID then
        for _, record in pairs(store) do
            if record.mapID == mapID then
                return record
            end
        end
    end

    local zone = GetZoneText and GetZoneText()

    if not zone or zone == "" then
        return nil
    end

    local needle = string.lower(zone)

    -- EXACT, not a substring: "Nagrand" is a substring of "Explore Nagrand"
    -- and of nothing else useful, but "Explore Shadowmoon Valley" contains
    -- the needle for both of the zones with that name.
    for _, record in pairs(store) do
        if record.name and string.lower(record.name) == needle then
            -- Learned, so the ambiguity is resolved once rather than every
            -- time -- and resolved by the map, which cannot be duplicated.
            if mapID then
                record.mapID = mapID
            end

            return record
        end
    end

    return nil
end

------------------------------------------------------------
-- CANDIDATES
------------------------------------------------------------

-- Only the zone the player is already in. Exploration elsewhere is a
-- project, and the criteria carry no coordinates to route to.
CN.RegisterCandidateProvider("Exploration", function()
    local candidates = {}

    local record = Exploration.ForCurrentZone()

    if record and not record.completed and (record.criteria or 0) > 0 then
        local remaining = record.criteria - record.done

        if remaining > 0
            and not CN.IsIgnored(CN.objectiveTypes.EXPLORATION, record.achievementID)
            and not CN.IsDeferred(CN.objectiveTypes.EXPLORATION, record.achievementID) then

            local reasons = {
                remaining .. " subzone" .. (remaining == 1 and "" or "s")
                    .. " left in this zone",
            }

            local missing = Blizzard.GetIncompleteCriteria(record.achievementID, 3)

            if #missing > 0 then
                table.insert(reasons, "missing: " .. table.concat(missing, ", "))
            end

            table.insert(candidates, CN.NewObjective({
                id              = record.achievementID,
                type            = CN.objectiveTypes.EXPLORATION,
                name            = record.name,
                accountWide     = true,
                completionValue = math.max(1, 4 - remaining),
                travelCost      = 0,
                reasons         = reasons,
            }))
        end
    end

    return candidates
end, { events = { "CRITERIA_UPDATE", "ZONE_CHANGED_NEW_AREA" } })

------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

-- REFRESH IT WHEN IT CHANGES, NOT ONLY WHEN YOU ARRIVE.
--
-- The provider declared `CRITERIA_UPDATE` -- which is exactly the event that
-- fires when you discover a subzone -- and rebuilt on it, reading the same
-- persisted record it had read on entering the zone. So "3 subzones left"
-- was frozen at 3 for as long as the player explored, and only moved when
-- they left the zone and came back.
--
-- Throttled, because a discovery fires several criteria updates in a row and
-- this is a client call per zone. `CN.Debounce` answers the first
-- immediately, which is the one the player is watching for.
Exploration.refreshSeconds = 2

local function RefreshCurrentZone()
    local record = Exploration.ForCurrentZone()

    if not record then
        return false
    end

    local done, criteria = Blizzard.GetAchievementProgress(record.achievementID)

    -- NOT OVER GOOD DATA WITH NOTHING.
    --
    -- `GetAchievementProgress` answers `0, 0` when the criteria API is
    -- unavailable, which is a refusal rather than a measurement -- and this
    -- writes straight into the persisted store. Overwriting a scanned "9
    -- criteria, 4 done" with "0 of 0" loses the record and makes the zone
    -- disappear from the list.
    if not criteria or criteria <= 0 then
        return false
    end

    record.done     = done
    record.criteria = criteria

    -- AND WRITE `completed`, which nothing did.
    --
    -- `Exploration.Closest` filters on `not record.completed` and sorts by
    -- what is left, ascending -- so a zone finished this session sat at the
    -- top of that list reading "0 left" for ever, because the only writer of
    -- the flag was the full scan.
    -- SET AND CLEARED, both. A patch that adds a subzone to a zone you had
    -- finished must be able to un-finish it; a flag that only ever goes one
    -- way is a flag that is wrong for the rest of the account's life.
    record.completed = (done and done >= criteria) or nil

    return true
end

Exploration.RefreshCurrentZone = RefreshCurrentZone

CN:RegisterEvent("ZONE_CHANGED_NEW_AREA", RefreshCurrentZone)

CN:RegisterEvent("CRITERIA_UPDATE", function()
    CN.Debounce("Exploration.criteria", Exploration.refreshSeconds, function()
        if RefreshCurrentZone() then
            CN.InvalidateProvider("Exploration")
        end
    end)
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "explorescan",
    order   = 67,
    help    = "Scan exploration achievements.",
    handler = function()
        local seen, complete = Exploration.Scan()

        Print("Scanned " .. seen .. " exploration achievements.")
        Print("Complete: " .. complete)
    end,
}

CN:RegisterCommand{
    name    = "exploration",
    aliases = { "explore" },
    args    = "[count]",
    order   = 68,
    help    = "Show zones with the least exploration left.",
    handler = function(args)
        local counts = Exploration.Summary()

        if counts.zones == 0 then
            Print("No exploration data yet. Run /cn explorescan.")
            return
        end

        Print("Exploration: " .. counts.complete .. " / " .. counts.zones .. " zones")

        if counts.criteria > 0 then
            -- NO PERCENTAGE. This file's own header says a genuine "percent
            -- explored" is uncomputable and that "78% explored is not
            -- [useful]" -- and then printed one, computed against the sum of
            -- criteria in the achievements this addon happens to have stored.
            -- Not the world; not even every zone, since a zone with no
            -- exploration achievement contributes nothing to either side.
            -- A player reads "73.0%" as the world.
            --
            -- The raw counts are honest and are what remains.
            Print(string.format("Subzones discovered: %d of %d in the "
                .. "exploration achievements this addon has scanned",
                counts.done, counts.criteria))
        end

        local here = Exploration.ForCurrentZone()

        if here then
            if here.completed then
                Print("This zone: |cff73b873fully explored|r")
            else
                Print("This zone: " .. here.done .. " / " .. here.criteria)

                local missing = Blizzard.GetIncompleteCriteria(here.achievementID, 6)

                for _, name in ipairs(missing) do
                    CN.PrintLine("  missing: " .. name)
                end
            end
        end

        local closest = Exploration.Closest(CN.ToID(args) or 5)

        if #closest > 0 then
            Print("Closest to finishing:")

            for _, row in ipairs(closest) do
                CN.PrintLine("  " .. row.name .. " |cff8a8f96("
                    .. row.done .. "/" .. row.criteria .. ")|r")
            end
        end
    end,
}

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
