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

-- The achievement's name, and its category's, from the client. See the note
-- in `Scan`. The stored fallbacks keep an older database readable until its
-- first rescan.
function Loremaster.NameOf(achievementID, record)
    local live = Blizzard.GetAchievementName
        and Blizzard.GetAchievementName(achievementID)

    if live and live ~= "" then
        return live
    end

    return (record and record.name)
        or ("Achievement " .. tostring(achievementID))
end

function Loremaster.CategoryOf(record)
    if type(record) ~= "table" then
        return "Other"
    end

    if record.categoryID and Blizzard.GetCategoryName then
        local live = Blizzard.GetCategoryName(record.categoryID)

        if live and live ~= "" then
            return live
        end
    end

    return record.category or "Other"
end

-- THE STORE HAD NO CHARACTER DIMENSION, AND SAID IT DID. FIXED IN 0.61.0.
--
-- `Loremaster.Scan`'s own comment says the store exists "so the Warband view
-- can show what other characters have finished". It could not: every row was
-- written into the ACCOUNT store under the achievement id alone, so whichever
-- character logged in last overwrote every other character's progress.
--
-- Two players on two characters saw the second one's numbers attributed to
-- both, and the Warband column that this was built for showed the same figure
-- in every row. Nothing caught it because the fixture has one character, and
-- one character cannot overwrite anybody.
--
-- The split follows what the game actually scopes:
--
--   name, category, criteria  -- properties of the achievement. Account.
--   completed                 -- achievements are earned account-wide. Account.
--   done                      -- criteria progress on quest achievements is
--                                CHARACTER-specific. Per character.
--
-- `progress` is a table keyed by character key. `record.done` is kept as the
-- current character's value so nothing downstream had to change shape, and so
-- a database written by an older version still reads correctly until the
-- migration runs.
function Loremaster.DoneFor(record, characterKey)
    if type(record) ~= "table" then
        return 0
    end

    characterKey = characterKey or CN.characterKey or CN.GetCharacterKey()

    if record.progress and record.progress[characterKey] ~= nil then
        return record.progress[characterKey]
    end

    -- No per-character figure: either this character has never scanned, or
    -- the row predates the split. Only the CURRENT character may fall back to
    -- the flat field, because that field holds whoever scanned last -- which
    -- is exactly the bug, and attributing it to a named other character would
    -- keep telling the lie in a new place.
    if characterKey == (CN.characterKey or CN.GetCharacterKey()) then
        return record.done or 0
    end

    return nil
end

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

                local held = store[id] or {}

                -- NEITHER NAME IS STORED. 0.64.0.
                --
                -- Both are LOCALIZED strings the client answers instantly,
                -- and both were being branched on: `ByCategory` groups on the
                -- stored category and `ForZone` substring-matches the stored
                -- achievement name against a LIVE zone name. So a player who
                -- switched client language read English achievement names
                -- under English headings, and `ForZone` matched nothing at
                -- all -- the "This zone" block and the already-here bonus in
                -- `/cn zones` simply disappeared until a rescan.
                --
                -- Sixth store to lose a name it did not need to keep;
                -- migrations 4, 5, 14, 15 and 16 were the others.
                held.categoryID = category.categoryID
                held.completed = achievement.completed and true or false
                held.criteria  = criteria

                -- THE FLAT FIELD IS NO LONGER WRITTEN. 0.66.0. See the same
                -- change in `Exploration.NoteProgress`.
                --
                -- It was kept so pre-migration databases still read, and
                -- `DoneFor` still reads it for that reason -- but writing it
                -- here meant the fallback returned whoever scanned last
                -- rather than something old, so an alt with no entry of its
                -- own was handed the main's criteria count as its own.
                held.progress  = held.progress or {}
                held.progress[CN.characterKey or CN.GetCharacterKey()] = done

                store[id] = held

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
            local key = Loremaster.CategoryOf(record)

            if not groups[key] then
                groups[key] = {}
                table.insert(order, key)
            end

            table.insert(groups[key], {
                id        = id,
                name      = Loremaster.NameOf(id, record),
                completed = record.completed,
                done      = Loremaster.DoneFor(record) or 0,
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
            local done = Loremaster.DoneFor(record) or 0

            local row = {
                id       = id,
                name     = Loremaster.NameOf(id, record),
                category = Loremaster.CategoryOf(record),
                done     = done,
                criteria = record.criteria,
                fraction = done / record.criteria,
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

    -- A DETERMINISTIC PICK, NOT WHATEVER `pairs` HANDED BACK FIRST. 0.61.0.
    --
    -- The zone name is a SUBSTRING match, so standing in Dalaran matched
    -- every achievement with "Dalaran" in its name, and the tie-break was
    -- only "prefer an unfinished one". Among several unfinished matches the
    -- winner was whichever `pairs` reached first -- which Lua does not
    -- promise to keep stable, and which in practice changed between sessions.
    -- The Journey tab showed a different zone achievement for the same zone
    -- on different logins, with nothing in the game having changed.
    --
    -- The ordering, in full:
    --
    --   1. Unfinished before finished. A completed zone achievement is not
    --      what you want while standing in the zone.
    --   2. The SHORTEST matching name. "Loremaster of Khaz Algar" contains
    --      no zone name; "Isle of Dorn Explorer" and "Isle of Dorn" both
    --      match a player on the Isle of Dorn, and the shorter one is the
    --      one that is ABOUT the zone rather than about the zone plus
    --      something else.
    --   3. Lowest id. Arbitrary, but the same arbitrary answer every time,
    --      which is the whole point.
    local best, bestRecord, bestName

    for id, record in pairs(Records()) do
        local heldName = Loremaster.NameOf(id, record)

        if heldName and string.find(heldName, zoneName, 1, true) then
            local better

            if not bestRecord then
                better = true
            elseif (bestRecord.completed and true or false)
                ~= (record.completed and true or false) then

                better = not record.completed
            elseif #heldName ~= #bestName then
                better = #heldName < #bestName
            else
                better = id < best.id
            end

            if better then
                bestRecord = record
                bestName   = heldName

                best = {
                    id        = id,
                    name      = heldName,
                    completed = record.completed,
                    done      = Loremaster.DoneFor(record) or 0,
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
                "%s done" .. CN.DASH .. "finishing is cheaper than starting",
                CN.PercentText(row.fraction)))
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
            CN.PrintLine(string.format("  %d. %s%s|r  |cff8a8f96%d/%d|r",
                index,
                row.here and "|cff5dd2fb" or "|cffffc74f",
                tostring(row.name),
                row.done, row.criteria))

            CN.PrintLine("     " .. CN.Muted(table.concat(CN.Reasons(row), "; ")))
        end

        Print("|cff8a8f96Ordered by what is cheapest to finish, not by size. "
            .. "Zones you have not started are included" .. CN.DASH .. "an earlier version "
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

    -- THE ONE PROVIDER THAT DID NOT HONOUR THE IGNORE LIST.
    --
    -- Twenty-one of the twenty-two check these at build time; nothing
    -- downstream filters an ignored objective, so a provider that skips the
    -- check makes Ignore a silent no-op for its rows.
    --
    -- Worse here than elsewhere: this emits a real achievement id in the same
    -- namespace the Achievements provider uses, so hiding a zone achievement
    -- removed it from Achievements, this re-emitted it, and the aggregate
    -- kept it. The player hid something and it stayed.
    if CN.IsIgnored(CN.objectiveTypes.ACHIEVEMENT, zone.id)
        or CN.IsDeferred(CN.objectiveTypes.ACHIEVEMENT, zone.id) then

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
                CN.PrintLine("|cffffc74f" .. key .. "|r")

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

-- SCANNED WHEN THE STORE IS EMPTY, OR WHEN IT IS INCOMPLETE. 0.68.0.
--
-- "Empty" was the only trigger, and after the first character it is never
-- empty again -- so a store that lost a field, or one written by a version
-- that did not record something this one reads, stayed wrong for the life of
-- the account unless the player found `/cn scanlore`. Migration 20 produced
-- exactly that state and the addon had no way back out of it.
--
-- A row with no `completed` flag is the shape of that damage, and it is also
-- the shape of a row written before the flag existed. Both want the same
-- thing.
-- THE ZONE YOU ARE IN, WHEN YOU HAND SOMETHING IN. 0.69.0.
--
-- The store was written by `Loremaster.Scan` and by nothing else, and `Scan`
-- ran at login, on `/cn scanlore`, and from the Journey tab's "Rescan zones"
-- button. So turning in a quest moved nothing: the Journey tab went on
-- reading the count it had at login, and the zone the player had just
-- advanced still said what it said an hour ago.
--
-- That is a reported symptom -- "the completion of a quest does not appear to
-- remove it from the journey" -- and it is not the recommendation list, which
-- has always been invalidated on `QUEST_TURNED_IN`. It is this store, which
-- nothing invalidated at all.
--
-- ONE ACHIEVEMENT, NOT THE TREE. A full scan walks every quest achievement in
-- the game and is why it was never put on an event. The zone the player is
-- standing in is the only row a turn-in can move, and refreshing it is two
-- client calls -- the same shape `Exploration.RefreshCurrentZone` has used
-- since 0.61.0, in the sibling store this fix never reached.
--
-- Debounced, because a quest chain can hand in three at once.
function Loremaster.RefreshCurrentZone()
    local here = Loremaster.ForZone()

    if not here or not here.id then
        return false
    end

    local record = Records()[here.id]

    if not record then
        return false
    end

    local done, criteria = Blizzard.GetAchievementProgress(here.id)

    -- NOT OVER GOOD DATA WITH NOTHING. A refusal from the criteria API
    -- answers `0, 0`, and writing that in loses the row -- the guard
    -- `Exploration` carries, and the one `Achievements` was given in 0.68.0
    -- after it did exactly this.
    if not criteria or criteria <= 0 then
        return false
    end

    record.criteria = criteria

    record.progress = record.progress or {}
    record.progress[CN.characterKey or CN.GetCharacterKey()] = done

    -- SET AND CLEARED BOTH, so a zone that gains a criterion in a patch can
    -- stop being finished.
    record.completed = (done >= criteria) and true or false

    return true
end

CN:RegisterEvent("QUEST_TURNED_IN", function()
    CN.Debounce("Loremaster.zone", 2, function()
        pcall(Loremaster.RefreshCurrentZone)
    end)
end)

CN:OnLogin(function()
    local records = Records()

    if CN.CountKeys(records) == 0 then
        Loremaster.Scan()

        return
    end

    -- AND ON THIS CHARACTER'S OWN DIMENSION. 0.69.0.
    --
    -- `completed` is account-wide, so once ANY character has repaired it no
    -- other character ever triggers a rescan again -- and `progress` is
    -- per-character, which is precisely what an alt is missing. So the first
    -- character to log in after the upgrade fixed the store for itself and
    -- locked every other character out of the repair: `/cn zones` reported
    -- "not started, 120 to do" for zones an alt had fully quested, with no
    -- way back short of finding `/cn scanlore`.
    --
    -- A scan is cheap and runs once per login. Two conditions, both about
    -- something that is genuinely absent.
    local key = CN.characterKey or CN.GetCharacterKey()

    for _, record in pairs(records) do
        if type(record) == "table" then
            if record.completed == nil then
                Loremaster.Scan()

                return
            end

            if type(record.progress) ~= "table"
                or record.progress[key] == nil then

                Loremaster.Scan()

                return
            end
        end
    end
end)

return Loremaster
