-- Modules/Loremaster.lua
-- Completion Navigator :: finishing zones, continents and expansions.
--
-- FROM A PLAYER'S OWN STATED PLAN:
--
--   "Once I finish the story this weekend, I'm gonna do all the side quests
--    on the continent I'm currently on. Then I'll move from one continent to
--    another. After that, I'm gonna switch timelines and work backwards to
--    the previous expansion... Basically, I'm gonna try to complete every
--    main quest and side quest in the entire game."
--
-- That is a two-year project measured in zones and continents, and the addon
-- had nothing to say about it. It could tell him what to do in the next
-- hundred yards and nothing about where he was in the campaign.
--
-- THE DENOMINATOR PROBLEM, AND WHY THIS WORKS ANYWAY.
--
-- The client will not tell you how many quests exist in a zone. Counting
-- "quests I know about" would produce a denominator that grows as you play,
-- so your percentage would go DOWN as you did more -- which is worse than no
-- percentage at all, and this addon has a standing rule against inventing
-- one.
--
-- But the game already ships the exact tracker this player needs: the quest
-- achievements. "Loremaster of Khaz Algar", the per-zone story achievements,
-- the exploration-style quest counts. Those have criteria the client
-- enumerates and vouches for. So the progress here is real, and it is real
-- because we did not compute it -- we read it.

local ADDON_NAME, CN = ...

local Loremaster = CN:RegisterModule("Loremaster")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint

local Blizzard = CN.Blizzard

-- Blizzard's "Quests" achievement category. A stable constant for many
-- years, and everything below degrades to "nothing found" rather than to an
-- error if it ever moves.
Loremaster.questCategoryID = 96

------------------------------------------------------------
-- THE CATEGORY TREE
------------------------------------------------------------

-- Every category descending from Quests: one per expansion, and below those,
-- per continent. Walked rather than hardcoded, so a new expansion needs no
-- code.
function Loremaster.QuestCategories()
    local categories = {}

    if not GetCategoryList or not GetCategoryInfo then
        return categories
    end

    local ok, list = pcall(GetCategoryList)

    if not ok or type(list) ~= "table" then
        return categories
    end

    -- Parentage is only one level per lookup, so resolve to a root by
    -- walking upward. Cheap: the tree is three deep at most.
    local function rootOf(categoryID)
        local guard = 0
        local current = categoryID

        while current and guard < 8 do
            local name, parent = GetCategoryInfo(current)

            if not name then
                return nil
            end

            if current == Loremaster.questCategoryID then
                return current
            end

            if not parent or parent <= 0 then
                return nil
            end

            current = parent
            guard   = guard + 1
        end

        return nil
    end

    for _, categoryID in ipairs(list) do
        if rootOf(categoryID) == Loremaster.questCategoryID then
            local name, parent = GetCategoryInfo(categoryID)

            table.insert(categories, {
                categoryID = categoryID,
                name       = name,
                parentID   = parent,
            })
        end
    end

    return categories
end

------------------------------------------------------------
-- SCANNING
------------------------------------------------------------

local function Records()
    return CN.Account("loremaster")
end

Loremaster.Records = Records

-- Reads every quest achievement and stores what the client says about it.
-- Stored rather than recomputed because walking the achievement tree is not
-- something to do on every frame, and because it lets the Warband view show
-- what other characters have finished.
function Loremaster.Scan()
    local store = Records()

    local scanned = 0

    for _, category in ipairs(Loremaster.QuestCategories()) do
        local total = select(1, Blizzard.GetCategoryCounts(category.categoryID))

        for index = 1, (total or 0) do
            local achievement = Blizzard.GetAchievementInCategory(
                category.categoryID, index)

            if achievement and achievement.achievementID then
                local id = achievement.achievementID

                local done, criteria = Blizzard.GetAchievementProgress(id)

                store[id] = {
                    name      = achievement.name,
                    category  = category.name,
                    completed = achievement.completed and true or false,
                    done      = done,
                    criteria  = criteria,
                }

                scanned = scanned + 1
            end
        end
    end

    CN.MarkScanned("loremaster")

    DebugPrint("Loremaster scan: " .. scanned .. " quest achievements.")

    return scanned
end

------------------------------------------------------------
-- GROUPING
------------------------------------------------------------

-- Quest achievements grouped by the category they live in -- which is to say,
-- by expansion and continent, because that is how Blizzard files them and
-- how the player thinks about them.
function Loremaster.ByCategory(includeCompleted)
    local groups, order = {}, {}

    for id, record in pairs(Records()) do
        if includeCompleted or not record.completed then
            local key = record.category or "Other"

            if not groups[key] then
                groups[key] = {}
                table.insert(order, key)
            end

            table.insert(groups[key], {
                id        = id,
                name      = record.name,
                completed = record.completed,
                done      = record.done or 0,
                criteria  = record.criteria or 0,
            })
        end
    end

    table.sort(order)

    for _, key in pairs(order) do
        table.sort(groups[key], function(a, b)
            local left  = (a.criteria or 0) > 0 and (a.done / a.criteria) or -1
            local right = (b.criteria or 0) > 0 and (b.done / b.criteria) or -1

            if left ~= right then
                return left > right
            end

            return tostring(a.name) < tostring(b.name)
        end)
    end

    return groups, order
end

-- The ones worth finishing next: started, not finished, closest first.
-- An untouched zone is not "nearly done", so it sorts below one you have
-- already put an evening into.
-- The zones nearest to finished.
--
-- TWO BUGS LIVED HERE.
--
-- The first: this sorted candidates carefully by completion fraction and then
-- handed the list to CN.CapCandidates, which re-sorts by `completionValue` --
-- a field these rows do not have. Every row therefore compared equal and the
-- tie-break took over, silently reordering the whole list alphabetically by
-- achievement ID whenever there were more rows than the limit. The careful
-- ordering above it was thrown away exactly when it mattered.
--
-- The second was worse for anyone actually working through content: rows with
-- `done == 0` were excluded, so a zone you had never set foot in could never
-- be recommended. For a player sweeping a continent, the untouched zones are
-- precisely the ones they need to be pointed at.
--
-- Untouched zones are now included and ranked separately, because "you are
-- 90% through this one" and "you have not started this one" are different
-- suggestions and blending them by fraction would bury every fresh zone under
-- every half-finished one forever.
function Loremaster.Closest(limit)
    local started, untouched = {}, {}

    for id, record in pairs(Records()) do
        if not record.completed and (record.criteria or 0) > 0 then
            local row = {
                id       = id,
                name     = record.name,
                category = record.category,
                done     = record.done or 0,
                criteria = record.criteria,
                fraction = (record.done or 0) / record.criteria,
            }

            if row.done > 0 then
                table.insert(started, row)
            else
                table.insert(untouched, row)
            end
        end
    end

    local function byProgress(a, b)
        if a.fraction ~= b.fraction then
            return a.fraction > b.fraction
        end

        return (a.criteria - a.done) < (b.criteria - b.done)
    end

    table.sort(started, byProgress)

    -- Smallest first among the untouched: a fresh zone with twenty quests is
    -- a better next step than one with ninety.
    table.sort(untouched, function(a, b)
        if a.criteria ~= b.criteria then
            return a.criteria < b.criteria
        end

        return tostring(a.name) < tostring(b.name)
    end)

    local ordered = {}

    for _, row in ipairs(started) do
        table.insert(ordered, row)
    end

    for _, row in ipairs(untouched) do
        table.insert(ordered, row)
    end

    -- Truncate. Deliberately NOT CN.CapCandidates: that re-sorts, and the
    -- ordering above is the entire product of this function.
    limit = limit or 10

    while #ordered > limit do
        table.remove(ordered)
    end

    return ordered, #started, #untouched
end

-- The quest achievement that matches the zone you are standing in.
--
-- Matched by name, which is imperfect and honest about being so: the client
-- does not link an achievement to a map. "Loremaster of Khaz Algar" will not
-- match "Isle of Dorn", and it is not supposed to -- the per-zone achievement
-- is the one that will.
function Loremaster.ForZone(mapID)
    mapID = mapID or select(1, CN.GetPlayerPosition())

    if not mapID then
        return nil
    end

    local zoneName = Blizzard.GetMapName(mapID)

    if not zoneName or zoneName == "" then
        return nil
    end

    local best

    for id, record in pairs(Records()) do
        if record.name and string.find(record.name, zoneName, 1, true) then
            -- Prefer an unfinished one; a completed zone achievement is not
            -- the thing you want to be shown while standing in it.
            if not best or (best.completed and not record.completed) then
                best = {
                    id        = id,
                    name      = record.name,
                    completed = record.completed,
                    done      = record.done or 0,
                    criteria  = record.criteria or 0,
                }
            end
        end
    end

    return best
end

------------------------------------------------------------
-- WHICH ZONE NEXT
------------------------------------------------------------

-- The addon could answer "what next" and "where in this zone", and had
-- nothing at all to say about "which zone".
--
-- That is the question somebody working through a continent asks every time
-- they finish one, and answering it badly is worse than not answering: the
-- wrong zone is twenty minutes of flying and a level range that wastes the
-- quests. So it is built from things the client will actually vouch for --
-- how much of each zone's quest achievement is done, how big what remains
-- is, and whether the zone feeds something you said you were chasing -- and
-- it says which of those reasons applied.

-- A zone you are most of the way through beats a fresh one, because
-- finishing is cheaper than starting and leaves fewer loose ends behind.
Loremaster.nearlyDoneFraction = 0.6

function Loremaster.NextZones(limit)
    local rows = Loremaster.Closest(50)

    local chased = {}

    -- Anything pinned as a goal makes the zone that serves it worth more.
    local goals = CN:GetModule("Goals")

    if goals then
        for _, goal in ipairs(goals.List()) do
            if goal.type == CN.objectiveTypes.ACHIEVEMENT then
                chased[goal.id] = true
            end
        end
    end

    local currentZone = Loremaster.ForZone()

    local scored = {}

    for _, row in ipairs(rows) do
        local reasons = {}

        local value = 0

        if row.fraction >= Loremaster.nearlyDoneFraction then
            value = value + 3
            table.insert(reasons, string.format(
                "%d%% done -- finishing is cheaper than starting",
                math.floor(row.fraction * 100)))
        elseif row.done > 0 then
            value = value + 1
            table.insert(reasons, string.format("%d of %d done",
                row.done, row.criteria))
        else
            table.insert(reasons, string.format(
                "not started, %d to do", row.criteria))
        end

        if chased[row.id] then
            value = value + 4
            table.insert(reasons, "you are chasing this")
        end

        -- The zone you are standing in costs nothing to reach.
        if currentZone and currentZone.id == row.id then
            value = value + 2
            table.insert(reasons, "you are already here")
        end

        -- A small remainder is a session; a large one is a project.
        local remaining = row.criteria - row.done

        if remaining <= 5 then
            value = value + 1
            table.insert(reasons, remaining .. " left")
        end

        table.insert(scored, {
            id        = row.id,
            name      = row.name,
            done      = row.done,
            criteria  = row.criteria,
            fraction  = row.fraction,
            remaining = remaining,
            value     = value,
            here      = currentZone and currentZone.id == row.id or false,
            reasons   = reasons,
        })
    end

    table.sort(scored, function(a, b)
        if a.value ~= b.value then
            return a.value > b.value
        end

        if a.fraction ~= b.fraction then
            return a.fraction > b.fraction
        end

        return tostring(a.name) < tostring(b.name)
    end)

    limit = limit or 5

    while #scored > limit do
        table.remove(scored)
    end

    return scored
end

CN:RegisterCommand{
    name    = "zones",
    aliases = { "nextzone", "wherenext" },
    order   = 15,
    help    = "Which zone to work on next, and why.",
    handler = function()
        local rows = Loremaster.NextZones(6)

        if #rows == 0 then
            Print("No unfinished zone achievements are recorded yet.")
            -- `/cn loremaster scan` is not a command. `loremaster` treats
            -- any argument that is not `all` or `zone` as a NAME FILTER, so
            -- that line sent the player to "Nothing matched."
            Print("|cff8a8f96Run |cffffc74f/cn scanlore|r"
                .. "|cff8a8f96 to read them from the game.|r")
            return
        end

        Print("Zones worth doing next:")

        for index, row in ipairs(rows) do
            Print(string.format("  %d. %s%s|r  |cff8a8f96%d/%d|r",
                index,
                row.here and "|cff5dd2fb" or "|cffffc74f",
                tostring(row.name),
                row.done, row.criteria))

            Print("     |cff8a8f96" .. table.concat(row.reasons, "; ") .. "|r")
        end

        Print("|cff8a8f96Ordered by what is cheapest to finish, not by size. "
            .. "Zones you have not started are included -- an earlier version "
            .. "left them out entirely.|r")
    end,
}

------------------------------------------------------------
-- THE STORY, AS DISTINCT FROM EVERYTHING ELSE
------------------------------------------------------------

-- "Finish the story, then do the side quests" is how players actually talk,
-- and the client knows which quests are campaign quests. Splitting the zone's
-- work along that line costs one API call per quest and matches the plan the
-- player already has in their head.
function Loremaster.SplitZoneWork(mapID)
    local quests = CN:GetModule("Quests")

    if not quests then
        return { story = {}, side = {} }
    end

    local split = { story = {}, side = {} }

    for _, poi in ipairs(quests.AvailableOnMap(mapID)) do
        if Blizzard.IsQuestCampaign(poi.questID) then
            table.insert(split.story, poi)
        else
            table.insert(split.side, poi)
        end
    end

    return split
end

------------------------------------------------------------
-- CANDIDATES
------------------------------------------------------------

-- A zone achievement you are most of the way through is a genuine next
-- action: three quests from Loremaster is worth knowing about while you are
-- standing in the zone, and worthless as a line in a list of four hundred.
CN.RegisterCandidateProvider("Loremaster", function()
    local candidates = {}

    local zone = Loremaster.ForZone()

    if not zone or zone.completed or (zone.criteria or 0) == 0 then
        return candidates
    end

    local remaining = zone.criteria - zone.done

    if remaining <= 0 or remaining > 10 then
        return candidates
    end

    local mapID = select(1, CN.GetPlayerPosition())

    table.insert(candidates, CN.NewObjective({
        id              = zone.id,
        type            = CN.objectiveTypes.ACHIEVEMENT,
        name            = zone.name,
        mapID           = mapID,
        accountWide     = false,
        completionValue = 4,
        reasons         = {
            remaining .. " of " .. zone.criteria .. " left in this zone",
        },
    }))

    return candidates
end, { events = { "ZONE_CHANGED_NEW_AREA", "CRITERIA_UPDATE" }, cooldown = 5 })

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

local function PrintAchievement(entry, indent)
    local bar = ""

    if (entry.criteria or 0) > 0 then
        local fraction = entry.done / entry.criteria

        bar = " |cff5dd2fb" .. CN.ProgressBar(fraction, 12) .. "|r "
            .. entry.done .. "/" .. entry.criteria
    end

    Print((indent or "  ")
        .. (entry.completed and "|cff73b873" or "|cffffc74f")
        .. tostring(entry.name) .. "|r" .. bar)
end

CN:RegisterCommand{
    name    = "loremaster",
    -- "zones" REMOVED. It was registered as its own command 120 lines up --
    -- "Which zone to work on next, and why" -- and this alias, loading later,
    -- overwrote it. So `/cn zones` printed the quest-completion-by-zone
    -- report while `/cn help` and the store page both described the zone
    -- ranking, and the real command was reachable only as `/cn nextzone`.
    aliases = { "lore" },
    args    = "[all, zone, or a name to filter]",
    order   = 12,
    help    = "Quest completion by zone, continent and expansion.",
    handler = function(args)
        args = CN.Trim(args or "")

        if CN.CountKeys(Records()) == 0 then
            Print("No quest achievements scanned yet. Running a scan now.")
            Loremaster.Scan()
        end

        if string.lower(args) == "zone" or args == "" then
            local zone = Loremaster.ForZone()

            if zone then
                Print("This zone:")
                PrintAchievement(zone)
            end

            local split = Loremaster.SplitZoneWork()

            if #split.story > 0 or #split.side > 0 then
                Print("Available here: |cffffc74f" .. #split.story
                    .. "|r story, |cffffc74f" .. #split.side .. "|r side.")
            end

            if args ~= "" then
                return
            end

            Print("Closest to finished:")

            for _, entry in ipairs(Loremaster.Closest(8)) do
                PrintAchievement(entry)
            end

            Print("|cff8a8f96/cn loremaster all|r lists everything by expansion.")

            return
        end

        local includeCompleted = string.lower(args) == "all"

        local filter = (not includeCompleted) and string.lower(args) or nil

        local groups, order = Loremaster.ByCategory(includeCompleted)

        local shown = 0

        for _, key in ipairs(order) do
            if not filter or string.find(string.lower(key), filter, 1, true) then
                Print("|cffffc74f" .. key .. "|r")

                for _, entry in ipairs(groups[key]) do
                    PrintAchievement(entry, "    ")
                    shown = shown + 1
                end
            end
        end

        if shown == 0 then
            Print("Nothing matched. Try |cffffc74f/cn loremaster all|r.")
        end
    end,
}

CN:RegisterCommand{
    name    = "scanlore",
    order   = 27,
    help    = "Rescan quest achievements by zone and expansion.",
    handler = function()
        Print("Quest achievements scanned: " .. Loremaster.Scan() .. ".")
    end,
}

CN:OnLogin(function()
    if CN.CountKeys(Records()) == 0 then
        Loremaster.Scan()
    end
end)

return Loremaster
