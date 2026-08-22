-- Modules/Achievements.lua
-- Completion Navigator :: achievements and their criteria.
--
-- Achievements are account-wide in retail, so completion lives in account
-- storage. Only incomplete achievements are stored in detail: keeping a row
-- for all ~3000 completed ones would triple the SavedVariables file to say
-- something the client can answer instantly.
--
-- The useful signal here is *near-completion*: an achievement sitting at
-- 9 of 10 criteria is worth far more attention than one at 0 of 10, and
-- nothing else in the addon surfaces that.

local ADDON_NAME, CN = ...

local Achievements = CN:RegisterModule("Achievements")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

-- wipe() is a WoW global; not relying on it keeps this file testable
-- outside the client.
local function Wipe(tbl)
    for key in pairs(tbl) do
        tbl[key] = nil
    end
end

-- An achievement's name, from the client, falling back to whatever an older
-- database still carries.
--
-- Names and point values used to be stored for every tracked achievement --
-- 394 KB at retail scale, in a file the game rewrites on every logout, and
-- every byte of it re-derivable from `GetAchievementInfo` in microseconds.
local function NameOf(achievementID, record)
    local live = CN.Blizzard.GetAchievementName(achievementID)

    if live then
        return live
    end

    return (record and record.name) or ("Achievement " .. tostring(achievementID))
end

local function Store()
    return CN.Account("achievements")
end

local function Totals()
    return CN.Account("achievementTotals")
end

Achievements.Store  = Store
Achievements.NameOf = NameOf

-- Bumped whenever the store is rewritten, so the candidate provider knows
-- when its shortlist is stale. See CN.Shortlist.
Achievements.revision = 0

-- Within two criteria of finished. Everything else is a project rather than
-- a next action, and there are three thousand of them.
Achievements.nearlyDoneThreshold = 2

local function IsNearlyDone(record)
    local criteria = record and record.criteria or 0

    if criteria <= 0 then
        return false
    end

    local remaining = criteria - (record.done or 0)

    return remaining > 0 and remaining <= Achievements.nearlyDoneThreshold
end

Achievements.IsNearlyDone = IsNearlyDone

-- The shortlist: only the rows a provider could possibly use.
function Achievements.Shortlist()
    return CN.Shortlist("Achievements", Achievements.revision, function()
        local list = {}

        for achievementID, record in pairs(Store()) do
            if IsNearlyDone(record) then
                table.insert(list, { id = achievementID, record = record })
            end
        end

        -- Deterministic order, so the cut is stable between rebuilds.
        table.sort(list, function(a, b) return a.id < b.id end)

        return list
    end)
end

------------------------------------------------------------
-- SCAN
------------------------------------------------------------

-- Walking every category is a few thousand calls. That is fine on demand,
-- but it must never run on a frequent event.
function Achievements.Scan()
    if not GetCategoryList then
        return 0, 0, 0
    end

    local store  = Store()
    local totals = Totals()

    Wipe(store)

    Achievements.revision = Achievements.revision + 1

    local scanned, completed, nearlyDone = 0, 0, 0

    for _, categoryID in ipairs(Blizzard.GetAchievementCategories()) do
        local total, categoryCompleted = Blizzard.GetCategoryCounts(categoryID)

        totals[categoryID] = {
            total     = total,
            completed = categoryCompleted,
        }

        for index = 1, total do
            local achievement = Blizzard.GetAchievementInCategory(categoryID, index)

            if achievement then
                scanned = scanned + 1

                if achievement.completed then
                    completed = completed + 1
                else
                    local done, criteria =
                        Blizzard.GetAchievementProgress(achievement.achievementID)

                    -- Store only what is unfinished, and only if there is
                    -- real progress or it is small enough to be actionable.
                    if criteria == 0 or done > 0 then
                        store[achievement.achievementID] = {
                            achievementID = achievement.achievementID,
                            categoryID    = categoryID,
                            done          = done,
                            criteria      = criteria,
                        }

                        if criteria > 0 and done >= criteria - 2 then
                            nearlyDone = nearlyDone + 1
                        end
                    end
                end
            end
        end
    end

    CN.MarkScanned("achievements")

    return scanned, completed, nearlyDone
end

------------------------------------------------------------
-- SUMMARY
------------------------------------------------------------

function Achievements.Summary()
    local total, completed = Blizzard.GetAchievementTotals()

    local counts = {
        total       = total,
        completed   = completed,
        inProgress  = 0,
        nearlyDone  = 0,
    }

    -- `pointsLeft` REMOVED. `record.points` has been nil since 0.36.0 --
    -- migration 5 stripped it as something the client re-supplies -- so this
    -- summed to zero on every client, permanently. Two other readers of the
    -- same field were fixed at the time and this one was missed. Nothing
    -- displayed it, so it was dead state rather than a wrong number on
    -- screen; it is gone rather than revived, because a points total the
    -- addon would have to rebuild from the client is a question the
    -- Achievements panel already answers.
    for _, record in pairs(Store()) do
        counts.inProgress = counts.inProgress + 1

        if record.criteria > 0 and record.done >= record.criteria - 2 then
            counts.nearlyDone = counts.nearlyDone + 1
        end
    end

    return counts
end

-- Incomplete achievements sorted by how close they are to finishing.
function Achievements.Closest(limit)
    local rows = {}

    for achievementID, record in pairs(Store()) do
        if record.criteria and record.criteria > 0 and record.done > 0 then
            -- The name is resolved once, here, rather than left nil for the
            -- caller to trip over. It is not read from disk any more.
            record.resolvedName = NameOf(achievementID, record)

            table.insert(rows, record)
        end
    end

    table.sort(rows, function(a, b)
        local aLeft = a.criteria - a.done
        local bLeft = b.criteria - b.done

        if aLeft == bLeft then
            return (a.resolvedName or "") < (b.resolvedName or "")
        end

        return aLeft < bLeft
    end)

    local results = {}

    for index = 1, math.min(limit or 10, #rows) do
        table.insert(results, rows[index])
    end

    return results
end

function Achievements.Resolve(text)
    local achievementID = CN.ToID(text)

    if achievementID then
        return achievementID
    end

    if not text or text == "" then
        return nil
    end

    local needle  = string.lower(text)
    local matches = {}

    for id, record in pairs(Store()) do
        local name = NameOf(id, record)

        if name and string.find(string.lower(name), needle, 1, true) then
            table.insert(matches, { id = id, name = name })
        end
    end

    if #matches == 0 then
        return nil
    end

    table.sort(matches, function(a, b) return #a.name < #b.name end)

    return matches[1].id
end

------------------------------------------------------------
-- ELIGIBILITY
------------------------------------------------------------

CN.RegisterEligibilityChecker(CN.objectiveTypes.ACHIEVEMENT, function(achievementID)
    local states = CN.objectiveStates
    local record = Store()[achievementID]

    if not record then
        -- Absent from the incomplete store means either completed or never
        -- scanned. Ask the client rather than guessing.
        local info = GetAchievementInfo and select(4, GetAchievementInfo(achievementID))

        if info then
            return states.COMPLETED, "Already earned", nil
        end

        return states.UNKNOWN, "No achievement data; run /cn achievescan", nil
    end

    return states.AVAILABLE, nil, nil
end)

------------------------------------------------------------
-- CANDIDATES
------------------------------------------------------------

-- Only near-complete achievements become candidates. A zero-progress
-- achievement is a project, not a next action, and flooding the
-- recommendation list with thousands of them would bury everything else.
-- The criteria line always; the points line only when the client will say.
local function PointReasons(achievementID, remaining, criteria)
    local reasons = {
        remaining .. " of " .. criteria .. " criteria left",
    }

    local points = Blizzard.GetAchievementPoints
        and Blizzard.GetAchievementPoints(achievementID)

    if type(points) == "number" and points > 0 then
        table.insert(reasons, points .. " achievement points")
    end

    return reasons
end

CN.RegisterCandidateProvider("Achievements", function()
    -- Iterates the shortlist, not the store. At retail scale that is a dozen
    -- rows instead of three thousand, and the three thousand were being
    -- rejected identically on every single rebuild.
    local shortlist = {}

    for _, entry in ipairs(Achievements.Shortlist()) do
        shortlist[entry.id] = entry.record
    end

    local candidates, considered, dropped = CN.CollectBounded(shortlist, nil,
        function(achievementID, record)
            local criteria = record.criteria or 0

            if criteria <= 0 then
                return nil
            end

            local remaining = criteria - (record.done or 0)

            -- A zero-progress achievement is a project, not a next action.
            if remaining <= 0 or remaining > Achievements.nearlyDoneThreshold then
                return nil
            end

            if CN.IsIgnored(CN.objectiveTypes.ACHIEVEMENT, achievementID)
                or CN.IsDeferred(CN.objectiveTypes.ACHIEVEMENT, achievementID) then
                return nil
            end

            return 3 - remaining
        end,
        function(achievementID, record, value)
            local remaining = (record.criteria or 0) - (record.done or 0)

            return CN.NewObjective({
                id              = achievementID,
                type            = CN.objectiveTypes.ACHIEVEMENT,
                name            = NameOf(achievementID, record),
                accountWide     = true,
                completionValue = value,
                -- POINTS ARE READ LIVE, OR NOT MENTIONED.
                --
                -- `record.points` has been nil since 0.36.0 stopped storing
                -- it -- this file says so in a comment a hundred lines below,
                -- where two other readers were fixed. This one was missed,
                -- and `or 0` turned an absent number into a confident false
                -- statement: every near-complete achievement in the addon has
                -- been reporting "0 achievement points".
                --
                -- Silence beats a wrong number. That is the same rule this
                -- addon applies to every denominator it cannot vouch for.
                reasons         = PointReasons(achievementID, remaining,
                    record.criteria),
            })
        end)

    CN.providerTruncation["Achievements"] = { considered = considered, dropped = dropped }

    return candidates
end, { events = { "ACHIEVEMENT_EARNED", "CRITERIA_UPDATE" }, cooldown = 5 })

------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

CN:RegisterEvent("ACHIEVEMENT_EARNED", function(event, achievementID)
    if achievementID then
        Store()[achievementID] = nil

        -- THE SHORTLIST HOLDS THE ROW THE STORE JUST RELEASED.
        --
        -- `CN.Shortlist` returns its held list whenever the revision matches,
        -- and the revision moved only on a full scan or when a criteria tick
        -- crossed the nearly-done boundary. Deleting the store row without
        -- moving it left the shortlist holding a strong reference to an
        -- orphaned record -- so ACHIEVEMENT_EARNED invalidated the provider,
        -- the provider rebuilt, asked for the shortlist, got the cached one
        -- back, and emitted the achievement the player had just earned as a
        -- candidate again. It stayed at the top of `/cn next` until something
        -- unrelated moved the revision.
        Achievements.revision = Achievements.revision + 1

        DebugPrint("Achievement earned: " .. tostring(achievementID))
    end
end)

-- Criteria updates fire constantly during play. Refresh the tracked rows
-- rather than rescanning thousands of achievements, and throttle even that.
local lastCriteriaSweep = 0

CN:RegisterEvent("CRITERIA_UPDATE", function()
    local now = time()

    if now - lastCriteriaSweep < 5 then
        return
    end

    lastCriteriaSweep = now

    local store = Store()

    for achievementID, record in pairs(store) do
        if record.criteria and record.criteria > 0 then
            local done = Blizzard.GetAchievementProgress(achievementID)

            if done ~= record.done then
                local wasNear = IsNearlyDone(record)

                record.done     = done

                -- Only a change that crosses the shortlist boundary can
                -- change what the provider would produce. Bumping the
                -- revision on every criteria tick would rebuild the
                -- shortlist constantly and give back the saving.
                if wasNear ~= IsNearlyDone(record) then
                    Achievements.revision = Achievements.revision + 1
                end
            end
        end
    end
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "achievescan",
    order   = 64,
    help    = "Scan every achievement category.",
    handler = function()
        Print("Scanning achievements; this takes a moment.")

        local scanned, completed, nearlyDone = Achievements.Scan()

        Print("Scanned " .. scanned .. " achievements.")
        Print("Completed: " .. completed)
        Print("Within two criteria of finishing: " .. nearlyDone)
    end,
}

CN:RegisterCommand{
    name    = "achievements",
    aliases = { "achieve" },
    order   = 65,
    help    = "Summarize achievement progress.",
    handler = function()
        local counts = Achievements.Summary()

        if counts.total == 0 and counts.inProgress == 0 then
            Print("No achievement data yet. Run /cn achievescan.")
            return
        end

        Print("Achievements: " .. counts.completed .. " / " .. counts.total
            .. string.format(" (%.1f%%)",
                counts.total > 0 and (counts.completed / counts.total * 100) or 0))

        Print("Tracked in progress: " .. counts.inProgress)
        Print("Within two criteria of finishing: " .. counts.nearlyDone)

        local closest = Achievements.Closest(5)

        for _, record in ipairs(closest) do
            Print("  " .. NameOf(record.achievementID or 0, record) .. " |cff8a8f96("
                .. record.done .. "/" .. record.criteria .. ")|r")
        end
    end,
}

CN:RegisterCommand{
    name    = "closest",
    args    = "[count]",
    order   = 66,
    help    = "List the achievements closest to completion.",
    handler = function(args)
        local limit   = CN.ToID(args) or 10
        local closest = Achievements.Closest(limit)

        if #closest == 0 then
            Print("No achievements in progress. Run /cn achievescan.")
            return
        end

        for index, record in ipairs(closest) do
            -- `points` HAS BEEN NIL SINCE 0.36.0.
            --
            -- That release stopped storing it, correctly -- the client
            -- returns it instantly and a copy on disk was dead weight. Two
            -- other places were updated to read it live or to tolerate its
            -- absence with `or 0`; this one was missed, so the command threw
            -- for anybody whose database had been migrated. It was invisible
            -- because the error is caught by the command dispatcher, printed
            -- once, and looks like a client hiccup.
            --
            -- Read live, and say nothing about points when the client will
            -- not say either.
            local points = record.points
                or Blizzard.GetAchievementPoints(record.achievementID)

            Print(index .. ". " .. NameOf(record.achievementID or 0, record)
                .. " |cff8a8f96(" .. record.done .. "/" .. record.criteria
                .. (points and (", " .. points .. " points") or "")
                .. ")|r")
        end
    end,
}
