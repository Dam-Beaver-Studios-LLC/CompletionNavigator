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

-- A NAME, LIVE. 0.64.0.
--
-- The stored name is an achievement name in whatever language last scanned,
-- and `ForCurrentZone` matches it against `GetZoneText()`, which is live. So a
-- player who changed client language had the whole Exploration feature
-- disappear until they happened to rescan -- which is verbatim the failure
-- 0.62.0 describes as fixed. That release corrected the COMPARISON and left
-- the stored side frozen: one half of the defect.
--
-- Same resolver shape as `Achievements.NameOf`, `Pets.NameOf`, `Mounts.NameOf`
-- and `Toys.NameOf`. Fifth store to get one.
function Exploration.NameOf(achievementID, record)
    local live = Blizzard.GetAchievementName
        and Blizzard.GetAchievementName(achievementID)

    if live and live ~= "" then
        return live
    end

    return (record and record.name)
        or ("Achievement " .. tostring(achievementID))
end

-- PROGRESS THROUGH A ZONE IS ONE CHARACTER'S. 0.64.0.
--
-- `done` and `completed` were written into an ACCOUNT store keyed by the
-- achievement id alone -- exactly the defect fixed in `Loremaster` in 0.61.0,
-- in the identically-shaped sibling store the fix never reached. It is worse
-- here, because `RefreshCurrentZone` is wired to `ZONE_CHANGED_NEW_AREA`, so
-- it does not even take a scan: an alt flying through a zone overwrites the
-- main's progress on the way past.
--
-- The split follows what the game scopes. The achievement's NAME and its
-- criteria COUNT are properties of the achievement. How much of it you have
-- explored is yours.
function Exploration.DoneFor(record, characterKey)
    if type(record) ~= "table" then
        return 0
    end

    characterKey = characterKey or CN.characterKey or CN.GetCharacterKey()

    if record.progress and record.progress[characterKey] then
        return record.progress[characterKey].done or 0,
            record.progress[characterKey].completed and true or false
    end

    -- Only the CURRENT character may fall back to the flat field, which holds
    -- whoever wrote last -- naming another character as its owner would be
    -- telling the same lie somewhere new.
    if characterKey == (CN.characterKey or CN.GetCharacterKey()) then
        return record.done or 0, record.completed and true or false
    end

    return nil, nil
end

-- The one writer, so the two places that record progress cannot drift.
function Exploration.NoteProgress(record, done, completed)
    if type(record) ~= "table" then
        return
    end

    local key = CN.characterKey or CN.GetCharacterKey()

    record.progress      = record.progress or {}
    record.progress[key] = {
        done      = done,
        completed = completed and true or false,
    }

    -- Kept flat as well, so every existing reader works unchanged and a
    -- database written by an older version still reads correctly.
    record.done      = done
    record.completed = completed and true or false
end

------------------------------------------------------------
-- SCAN
------------------------------------------------------------

function Exploration.Scan()
    local store = Store()

    local seen, complete = 0, 0

    for _, achievement in ipairs(Blizzard.GetExplorationAchievements()) do
        local held = store[achievement.achievementID] or {}

        held.achievementID = achievement.achievementID
        held.criteria      = achievement.criteria
        held.lastSeen      = time()

        -- `name` IS NOT STORED. See `Exploration.NameOf`.
        held.name = nil

        Exploration.NoteProgress(held, achievement.done, achievement.completed)

        store[achievement.achievementID] = held

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
        local done, completed = Exploration.DoneFor(record)

        counts.zones    = counts.zones + 1
        counts.criteria = counts.criteria + (record.criteria or 0)
        counts.done     = counts.done + (done or 0)

        if completed then
            counts.complete = counts.complete + 1
        end
    end

    return counts
end

-- Zones with the fewest subzones left, so the cheapest wins come first.
function Exploration.Closest(limit)
    local rows = {}

    for achievementID, record in pairs(Store()) do
        local done, completed = Exploration.DoneFor(record)

        done = done or 0

        if not completed and (record.criteria or 0) > 0 then
            table.insert(rows, {
                achievementID = record.achievementID,
                name          = Exploration.NameOf(achievementID, record),
                done          = done,
                criteria      = record.criteria,
                remaining     = record.criteria - done,
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

    -- THE EXACT MATCH COULD NEVER MATCH. FIXED IN 0.62.0.
    --
    -- `record.name` is an achievement name -- "Explore Eversong Woods" -- and
    -- the needle is a ZONE name, "Eversong Woods". 0.59.0 tightened a working
    -- substring match into an exact one to resolve the two Shadowmoon
    -- Valleys, and in doing so made it compare two strings that are never
    -- equal on any client. Its own comment says the two forms differ.
    --
    -- Everything downstream died silently: `ForCurrentZone` returned nil in
    -- every zone, so the Exploration provider emitted nothing ever, `/cn
    -- exploration` never printed its "This zone" block, and `record.mapID` --
    -- the learned fast path that resolves the ambiguity permanently -- is
    -- only written inside the branch that never ran, so it could never be
    -- learned either.
    --
    -- The harness did not catch it because its fixture fabricates a store row
    -- named after `GetZoneText()` when the lookup fails, which is a stub being
    -- more forgiving than the client. That row is gone and the fixture now
    -- carries the achievement name the client actually returns.
    --
    -- What replaces it keeps the tightening that was wanted. The zone name
    -- must appear as a WHOLE WORD RUN inside the achievement name, anchored
    -- at the end -- "Explore Nagrand" matches "Nagrand", and "Explore
    -- Shadowmoon Valley" matches "Shadowmoon Valley" and not "Shadowmoon".
    -- The genuine duplicate-name case is then resolved by `mapID`, learned on
    -- the first successful lookup, exactly as intended.
    local function Names(candidate)
        if not candidate then
            return false
        end

        candidate = string.lower(candidate)

        if candidate == needle then
            return true
        end

        -- Ends with the zone name, preceded by a space.
        return string.sub(candidate, -(#needle + 1)) == (" " .. needle)
    end

    for achievementID, record in pairs(store) do
        if Names(Exploration.NameOf(achievementID, record)) then
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

    local done, completed = Exploration.DoneFor(record)

    if record and not completed and (record.criteria or 0) > 0 then
        local remaining = record.criteria - (done or 0)

        if remaining > 0
            and not CN.IsIgnored(CN.objectiveTypes.EXPLORATION, record.achievementID)
            and not CN.IsDeferred(CN.objectiveTypes.EXPLORATION, record.achievementID) then

            local reasons = {
                CN.Count(remaining, "subzone")
                    .. " left in this zone",
            }

            local missing = Blizzard.GetIncompleteCriteria(record.achievementID, 3)

            if #missing > 0 then
                table.insert(reasons, "missing: " .. table.concat(missing, ", "))
            end

            table.insert(candidates, CN.NewObjective({
                id              = record.achievementID,
                type            = CN.objectiveTypes.EXPLORATION,
                -- THROUGH THE ACCESSOR. 0.65.0.
                --
                -- `record.name` has been nil since 0.64.0 stopped storing it
                -- and migration 17 deleted it from disk -- and that release
                -- wired the replacement accessor into `Closest` and missed
                -- this, the one place whose output the player actually reads.
                -- So every exploration row rendered as its achievement id:
                -- "1. 1275" in `/cn next`, on the map pin, in the heads-up
                -- line, and "Ignored: nil" when it was hidden.
                name            = Exploration.NameOf(record.achievementID,
                    record),
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
    --
    -- THROUGH THE ONE WRITER, so this and the scan cannot record progress
    -- differently -- and so both file it under the character it belongs to.
    -- This function is wired to `ZONE_CHANGED_NEW_AREA`, so before 0.64.0 an
    -- alt flying through a zone overwrote the main's progress in passing.
    Exploration.NoteProgress(record, done, done and done >= criteria)

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
            -- THROUGH THE PER-CHARACTER ACCESSOR. 0.65.0.
            --
            -- `Summary`, `Closest` and the provider all go through
            -- `DoneFor`; this read the flat fields, which hold whichever
            -- character wrote last. So an alt could type `/cn exploration`
            -- and read another character's numbers on the "This zone" line
            -- while "Closest to finishing" three lines below showed its own.
            local hereDone, hereComplete = Exploration.DoneFor(here)

            if hereComplete then
                Print("This zone: |cff73b873fully explored|r")
            else
                Print("This zone: " .. (hereDone or 0)
                    .. " / " .. (here.criteria or 0))

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
