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

local function Store()
    return CN.Account("achievements")
end

local function Totals()
    return CN.Account("achievementTotals")
end

Achievements.Store = Store

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
            lastSeen  = time(),
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
                            name          = achievement.name,
                            points        = achievement.points,
                            categoryID    = categoryID,
                            done          = done,
                            criteria      = criteria,
                            lastSeen      = time(),
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
        pointsLeft  = 0,
    }

    for _, record in pairs(Store()) do
        counts.inProgress = counts.inProgress + 1
        counts.pointsLeft = counts.pointsLeft + (record.points or 0)

        if record.criteria > 0 and record.done >= record.criteria - 2 then
            counts.nearlyDone = counts.nearlyDone + 1
        end
    end

    return counts
end

-- Incomplete achievements sorted by how close they are to finishing.
function Achievements.Closest(limit)
    local rows = {}

    for _, record in pairs(Store()) do
        if record.criteria and record.criteria > 0 and record.done > 0 then
            table.insert(rows, record)
        end
    end

    table.sort(rows, function(a, b)
        local aLeft = a.criteria - a.done
        local bLeft = b.criteria - b.done

        if aLeft == bLeft then
            return (a.name or "") < (b.name or "")
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
        if record.name and string.find(string.lower(record.name), needle, 1, true) then
            table.insert(matches, { id = id, name = record.name })
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
                name            = record.name,
                accountWide     = true,
                completionValue = value,
                reasons         = {
                    remaining .. " of " .. record.criteria .. " criteria left",
                    tostring(record.points or 0) .. " achievement points",
                },
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
                record.lastSeen = time()

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
            Print("  " .. record.name .. " |cff999999("
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
            Print(index .. ". " .. record.name .. " |cff999999("
                .. record.done .. "/" .. record.criteria .. ", "
                .. record.points .. " points)|r")
        end
    end,
}
