-- Providers/BlizzardWorld.lua
-- Completion Navigator :: professions, the vault, currencies, instances and the world.
--
-- SPLIT OUT OF Providers/Blizzard.lua IN 0.45.0.
--
-- That file had grown to 2,250 lines and held every call this addon makes
-- into the client. The original argument for one file was sound -- a patch
-- that renames an API is a one-file fix rather than a hunt -- and it stopped
-- being true somewhere around the point where finding the function you wanted
-- required a search rather than a scroll.
--
-- The three files divide by what the client is being asked ABOUT, which is
-- also how patches break things: a collections patch breaks collection APIs.
-- `CN.Blizzard` is still one table; only the source is divided.

local ADDON_NAME, CN = ...

local Blizzard = CN.Blizzard

-- PROFESSIONS AND RECIPES
------------------------------------------------------------

function Blizzard.GetProfessionSkillLines()
    local lines = {}

    if not GetProfessions then
        return lines
    end

    -- Same nil-hole problem as above: index the five slots explicitly
    -- rather than iterating, or missing professions truncate the list.
    local slots = { GetProfessions() }

    for slot = 1, 5 do
        local index = slots[slot]

        if index then
            local name, _, rank, maxRank, _, _, skillLineID, _, _, _ = GetProfessionInfo(index)

            if name and skillLineID then
                table.insert(lines, {
                    name        = name,
                    rank        = rank,
                    maxRank     = maxRank,
                    skillLineID = skillLineID,
                })
            end
        end
    end

    return lines
end

-- Recipe enumeration only works while a trade skill window is open. This
-- is a hard client restriction, not a choice; callers must handle false.
function Blizzard.IsTradeSkillReady()
    if C_TradeSkillUI and C_TradeSkillUI.IsTradeSkillReady then
        return C_TradeSkillUI.IsTradeSkillReady() and true or false
    end

    return false
end

function Blizzard.GetOpenTradeSkillLine()
    if C_TradeSkillUI and C_TradeSkillUI.GetBaseProfessionInfo then
        local info = C_TradeSkillUI.GetBaseProfessionInfo()

        if info and info.professionID then
            return info.professionID, info.professionName
        end
    end

    if C_TradeSkillUI and C_TradeSkillUI.GetTradeSkillLine then
        return C_TradeSkillUI.GetTradeSkillLine()
    end

    return nil, nil
end

function Blizzard.GetAllRecipeIDs()
    if C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs then
        local ok, ids = pcall(C_TradeSkillUI.GetAllRecipeIDs)

        if ok and type(ids) == "table" then
            return ids
        end
    end

    return {}
end

function Blizzard.GetRecipeInfo(recipeID)
    if not C_TradeSkillUI or not C_TradeSkillUI.GetRecipeInfo then
        return nil
    end

    local ok, info = pcall(C_TradeSkillUI.GetRecipeInfo, recipeID)

    if not ok or type(info) ~= "table" then
        return nil
    end

    return info
end

------------------------------------------------------------
-- TIME-SENSITIVE CONTENT
------------------------------------------------------------

function Blizzard.GetSecondsUntilDailyReset()
    if GetQuestResetTime then
        local ok, seconds = pcall(GetQuestResetTime)

        if ok and type(seconds) == "number" and seconds > 0 then
            return seconds
        end
    end

    return nil
end

function Blizzard.GetSecondsUntilWeeklyReset()
    if C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset then
        local ok, seconds = pcall(C_DateAndTime.GetSecondsUntilWeeklyReset)

        if ok and type(seconds) == "number" and seconds > 0 then
            return seconds
        end
    end

    return nil
end

------------------------------------------------------------
-- GREAT VAULT
------------------------------------------------------------

-- The weekly reward chest. Three rows -- raid, dungeons, world -- each with
-- three thresholds, and you pick ONE item from everything unlocked.
--
-- This is the only system in the game that hands the addon all three things
-- it normally has to guess at: a hard deadline, a known denominator, and a
-- known reward. Everywhere else the addon reports counts because a percentage
-- would need a denominator the client will not supply; here the thresholds
-- are fixed and the client reports progress against them, so "3 of 4" is a
-- fact rather than an estimate.
--
-- The enum has been renamed across expansions, so the row type is resolved by
-- probing rather than assumed.
local function ThresholdEnum()
    if not Enum then
        return {}
    end

    return Enum.WeeklyRewardChestThresholdType
        or Enum.WeeklyRewardChestThreshold
        or {}
end

function Blizzard.HasWeeklyRewards()
    return C_WeeklyRewards ~= nil and C_WeeklyRewards.GetActivities ~= nil
end

-- Maps the client's row enum onto stable names of our own, so nothing
-- downstream depends on Blizzard's numbering.
function Blizzard.WeeklyRewardRowName(activityType)
    local enum = ThresholdEnum()

    if enum.Raid and activityType == enum.Raid then
        return "RAID"
    end

    -- Mythic+ is called "Activities" in the enum, which is uselessly generic.
    if enum.Activities and activityType == enum.Activities then
        return "DUNGEON"
    end

    if enum.World and activityType == enum.World then
        return "WORLD"
    end

    -- Older builds exposed a PvP row; treat it as world content rather than
    -- dropping it, so nothing silently disappears.
    if enum.RankedPvP and activityType == enum.RankedPvP then
        return "PVP"
    end

    return "UNKNOWN"
end

-- Returns an array of rows:
--   { row, index, threshold, progress, level, unlocked, rewardID }
function Blizzard.GetWeeklyRewardActivities()
    if not Blizzard.HasWeeklyRewards() then
        return {}
    end

    local ok, activities = pcall(C_WeeklyRewards.GetActivities)

    if not ok or type(activities) ~= "table" then
        return {}
    end

    local rows = {}

    for _, activity in ipairs(activities) do
        if type(activity) == "table" then
            local threshold = activity.threshold or 0
            local progress  = activity.progress or 0

            table.insert(rows, {
                row       = Blizzard.WeeklyRewardRowName(activity.type),
                index     = activity.index,
                threshold = threshold,
                progress  = progress,
                level     = activity.level,
                unlocked  = threshold > 0 and progress >= threshold,
                rewardID  = activity.id,
            })
        end
    end

    table.sort(rows, function(a, b)
        if a.row ~= b.row then
            return a.row < b.row
        end

        return (a.threshold or 0) < (b.threshold or 0)
    end)

    return rows
end

function Blizzard.HasAvailableWeeklyRewards()
    if not C_WeeklyRewards then
        return false
    end

    if C_WeeklyRewards.HasAvailableRewards then
        local ok, available = pcall(C_WeeklyRewards.HasAvailableRewards)

        if ok then
            return available and true or false
        end
    end

    return false
end

function Blizzard.IsWorldQuest(questID)
    if C_QuestLog and C_QuestLog.IsWorldQuest then
        local ok, result = pcall(C_QuestLog.IsWorldQuest, questID)

        return ok and result and true or false
    end

    return false
end

-- Seconds remaining on a world quest, or nil when it is not time-limited.
function Blizzard.GetQuestTimeLeft(questID)
    if not C_TaskQuest then
        return nil
    end

    if C_TaskQuest.GetQuestTimeLeftSeconds then
        local ok, seconds = pcall(C_TaskQuest.GetQuestTimeLeftSeconds, questID)

        if ok and type(seconds) == "number" and seconds > 0 then
            return seconds
        end
    end

    if C_TaskQuest.GetQuestTimeLeftMinutes then
        local ok, minutes = pcall(C_TaskQuest.GetQuestTimeLeftMinutes, questID)

        if ok and type(minutes) == "number" and minutes > 0 then
            return minutes * 60
        end
    end

    return nil
end

-- World quests currently up on a map. The field naming has changed between
-- versions (questId vs questID), so both are accepted.
function Blizzard.GetWorldQuestsOnMap(uiMapID)
    local results = {}

    if not uiMapID or not C_TaskQuest or not C_TaskQuest.GetQuestsForPlayerByMapID then
        return results
    end

    local ok, tasks = pcall(C_TaskQuest.GetQuestsForPlayerByMapID, uiMapID)

    if not ok or type(tasks) ~= "table" then
        return results
    end

    for _, task in ipairs(tasks) do
        local questID = task.questID or task.questId

        if questID then
            table.insert(results, {
                questID = questID,
                mapID   = task.mapID or uiMapID,
                x       = task.x,
                y       = task.y,
                inArea  = task.inProgress,
            })
        end
    end

    return results
end

function Blizzard.GetWorldQuestInfo(questID)
    local info = {}

    if C_TaskQuest and C_TaskQuest.GetQuestInfoByQuestID then
        local ok, title, factionID = pcall(C_TaskQuest.GetQuestInfoByQuestID, questID)

        if ok then
            info.title     = title
            info.factionID = factionID
        end
    end

    if C_QuestLog and C_QuestLog.GetQuestTagInfo then
        local ok, tag = pcall(C_QuestLog.GetQuestTagInfo, questID)

        if ok and type(tag) == "table" then
            info.tagName        = tag.tagName
            info.worldQuestType = tag.worldQuestType
            info.quality        = tag.quality
            info.isElite        = tag.isElite
        end
    end

    return info
end

-- Calendar events happening today. Requires the calendar to have been
-- opened at least once; the call is cheap and safe to repeat.
function Blizzard.GetTodaysEvents()
    local events = {}

    if not C_Calendar or not C_DateAndTime then
        return events
    end

    pcall(function()
        if C_Calendar.OpenCalendar then
            C_Calendar.OpenCalendar()
        end
    end)

    local ok, today = pcall(C_DateAndTime.GetCurrentCalendarTime)

    if not ok or type(today) ~= "table" or not today.monthDay then
        return events
    end

    local gotCount, count = pcall(C_Calendar.GetNumDayEvents, 0, today.monthDay)

    if not gotCount or type(count) ~= "number" then
        return events
    end

    for index = 1, count do
        local gotEvent, event = pcall(C_Calendar.GetDayEvent, 0, today.monthDay, index)

        if gotEvent and type(event) == "table" and event.title then
            -- sequenceType is "ONGOING" or "START" while an event is live.
            local ongoing = event.sequenceType == "ONGOING"
                or event.sequenceType == "START"
                or event.sequenceType == ""

            -- WHEN IT ENDS, where the calendar says so.
            --
            -- Without this an active event is just a name, and the ranking
            -- has nothing to weigh: "Timewalking is on" and "Timewalking ends
            -- in four hours" are different pieces of advice. Some builds omit
            -- the end time entirely, and nil is then the right answer rather
            -- than a guessed week.
            local endsAt, endsIn

            -- Gated on the end time itself, which is all this block reads.
            -- It used to also require C_DateAndTime.GetSecondsUntilWeeklyReset
            -- -- a function it never calls -- so on any build lacking that
            -- unrelated API every calendar event silently lost its deadline,
            -- and with it the urgency weighting and the "ends in" line.
            if type(event.endTime) == "table" and event.endTime.monthDay then

                local finish = event.endTime

                local nowStamp = time()

                local okStamp, stamp = pcall(time, {
                    year  = finish.year   or 0,
                    month = finish.month  or 1,
                    day   = finish.monthDay,
                    hour  = finish.hour   or 0,
                    min   = finish.minute or 0,
                })

                if okStamp and stamp and stamp > nowStamp then
                    endsAt = stamp
                    endsIn = stamp - nowStamp
                end
            end

            -- THE ABSOLUTE TIME AS WELL AS THE RELATIVE ONE.
            --
            -- `endsIn` is computed here, at SCAN time, and the caller caches
            -- the whole list for thirty minutes -- so a deadline could be
            -- half an hour stale on the heaviest-weighted term in the
            -- scorer, whose steep ramp lives entirely inside the last two
            -- hours. "Ends in 40m" printed ten minutes after it ended.
            --
            -- `endsAt` does not go stale, so the reader can derive a fresh
            -- `endsIn` from it however long the list has been held.
            table.insert(events, {
                title        = event.title,
                -- The client supplies one on retail; carried through so the
                -- consumer can key on it rather than on a translated title.
                -- Nil elsewhere, and the consumer composes a stable key from
                -- the three type fields in that case.
                eventID      = event.eventID,
                eventType    = event.eventType,
                calendarType = event.calendarType,
                sequenceType = event.sequenceType,
                ongoing      = ongoing,
                endsAt       = endsAt,
                endsIn       = endsIn,
            })
        end
    end

    return events
end

------------------------------------------------------------
-- VIGNETTES (RARES AND TREASURES)
------------------------------------------------------------

-- Vignettes are the skull and chest icons the client puts on the minimap.
-- They are the only live signal that a rare is actually up right now, which
-- is what makes them worth more than any static rare database.
function Blizzard.GetVignettes(uiMapID)
    local results = {}

    if not C_VignetteInfo or not C_VignetteInfo.GetVignettes then
        return results
    end

    local ok, guids = pcall(C_VignetteInfo.GetVignettes)

    if not ok or type(guids) ~= "table" then
        return results
    end

    for _, guid in ipairs(guids) do
        local gotInfo, info = pcall(C_VignetteInfo.GetVignetteInfo, guid)

        if gotInfo and type(info) == "table" and info.name then
            local entry = {
                guid        = guid,
                vignetteID  = info.vignetteID,
                name        = info.name,
                atlas       = info.atlasName,
                objectGUID  = info.objectGUID,
                isDead      = info.isDead and true or false,
                onMinimap   = info.onMinimap,
                inFogOfWar  = info.inFogOfWar,
            }

            if uiMapID and C_VignetteInfo.GetVignettePosition then
                local gotPosition, position =
                    pcall(C_VignetteInfo.GetVignettePosition, guid, uiMapID)

                if gotPosition and position and position.GetXY then
                    local x, y = position:GetXY()

                    entry.mapID = uiMapID
                    entry.x     = x
                    entry.y     = y
                end
            end

            table.insert(results, entry)
        end
    end

    return results
end

-- Treasure chests and rare creatures use different atlas art. The atlas
-- name is the only reliable discriminator the client exposes.
function Blizzard.ClassifyVignette(atlasName)
    if type(atlasName) ~= "string" then
        return "UNKNOWN"
    end

    local lower = string.lower(atlasName)

    if string.find(lower, "chest", 1, true)
        or string.find(lower, "treasure", 1, true)
        or string.find(lower, "lootcontainer", 1, true) then
        return "TREASURE"
    end

    if string.find(lower, "vignetteskull", 1, true)
        or string.find(lower, "vignetteboss", 1, true)
        or string.find(lower, "elite", 1, true) then
        return "RARE"
    end

    if string.find(lower, "vignette", 1, true) then
        return "RARE"
    end

    return "UNKNOWN"
end

------------------------------------------------------------
-- CURRENCIES
------------------------------------------------------------

function Blizzard.GetCurrencyList()
    local results = {}

-- The currency id for a row of the currency list.
--
-- GetCurrencyListInfo returns a display record with no id in it. The link is
-- the only thing that carries one, and it has to be dug out of the hyperlink
-- -- `|Hcurrency:2245|h[Flightstones]|h` -- because the client offers no
-- direct accessor. Guarded and pcall'd at every step: this runs once per
-- currency on every scan, and a client that will not produce a link should
-- cost the row, not the scan.
local function CurrencyIDFromList(index)
    if not C_CurrencyInfo or not C_CurrencyInfo.GetCurrencyListLink then
        return nil
    end

    local ok, link = pcall(C_CurrencyInfo.GetCurrencyListLink, index)

    if not ok or type(link) ~= "string" then
        return nil
    end

    return tonumber(string.match(link, "currency:(%d+)"))
end

    if not C_CurrencyInfo or not C_CurrencyInfo.GetCurrencyListSize then
        return results
    end

    -- A COLLAPSED HEADER HIDES ITS ROWS FROM THE COUNT.
    --
    -- `GetCurrencyListSize` counts only rows under EXPANDED headers, exactly
    -- like the faction list. The reputation path has handled this since
    -- 0.30.0 with `WithAllFactionsExpanded`; the currency path never did, and
    -- there was no `ExpandCurrencyList` call anywhere in the addon. A player
    -- who had collapsed an expansion group in their Currency tab lost every
    -- currency underneath it from `/cn currencies`, from `/cn clock` and from
    -- the weekly-cap warnings, with nothing on screen saying so.
    --
    -- Expanded, scanned, put back -- the same shape, and the same obligation:
    -- what this addon changes to read, it changes back.
    local collapsed = {}

    if C_CurrencyInfo.ExpandCurrencyList then
        local counted, initial = pcall(C_CurrencyInfo.GetCurrencyListSize)

        if counted and type(initial) == "number" then
            for index = initial, 1, -1 do
                local asked, row = pcall(C_CurrencyInfo.GetCurrencyListInfo, index)

                if asked and type(row) == "table" and row.isHeader
                    and row.isHeaderExpanded == false then

                    table.insert(collapsed, row.name)

                    pcall(C_CurrencyInfo.ExpandCurrencyList, index, true)
                end
            end
        end
    end

    local ok, size = pcall(C_CurrencyInfo.GetCurrencyListSize)

    if not ok or type(size) ~= "number" then
        return results
    end

    for index = 1, size do
        local gotInfo, info = pcall(C_CurrencyInfo.GetCurrencyListInfo, index)


        if gotInfo and type(info) == "table" and not info.isHeader and info.name then
            -- THE LIST ROW DOES NOT CARRY AN ID.
            --
            -- CurrencyDisplayInfo -- what GetCurrencyListInfo returns -- has
            -- a name, quantities and flags and NO currencyID. Reading one
            -- gave nil for every row, and Currencies.Scan drops any row
            -- without an id, so the character currency store has always been
            -- empty and `/cn currencies` has always said "no currency data
            -- yet". The stub returned fixture tables that did carry the
            -- field, so the suite never saw it.
            --
            -- The id comes from the list LINK. Kept tolerant of a client that
            -- does supply it directly, because being wrong in that direction
            -- costs nothing.
            local currencyID = info.currencyID or CurrencyIDFromList(index)

            table.insert(results, {
                currencyID   = currencyID,
                name         = info.name,
                quantity     = info.quantity or 0,
                maxQuantity  = info.maxQuantity or 0,
                totalEarned  = info.totalEarned or 0,
                quality      = info.quality,
                discovered   = info.discovered ~= false,

                -- Weekly caps are the actionable part: a capped currency is
                -- earning potential being thrown away every week it sits.
                canEarnPerWeek     = info.canEarnPerWeek and true or false,
                earnedThisWeek     = info.quantityEarnedThisWeek or 0,
                maxWeeklyQuantity  = info.maxWeeklyQuantity or 0,

                useTotalEarnedForMaxQty = info.useTotalEarnedForMaxQty and true or false,

                -- Warband currencies. The client flags them and the addon
                -- ignored the flag until 0.43.0, so one capped on your main
                -- was recommended again on every alt.
                -- TRANSFERABLE IS NOT SHARED. 0.63.0.
                --
                -- `isAccountTransferable` means the balance can be MOVED
                -- between characters, for a fee, one deliberate action at a
                -- time. `isAccountWide` means every character sees the same
                -- balance. Treating the first as the second told the ranking
                -- that a currency belonging to exactly one character was
                -- everybody's -- so `Warband.Decorate` short-circuited to
                -- "account-wide" and dropped the character verdict, and the
                -- row printed "(Warband)".
                --
                -- Both are carried, because the second one is worth SAYING --
                -- "you can move this to the character who needs it" is useful
                -- and is not the same sentence.
                accountWide     = info.isAccountWide and true or false,
                transferable    = info.isAccountTransferable and true or false,
            })
        end
    end

    -- Put the headers back the way the player had them.
    if #collapsed > 0 and C_CurrencyInfo.ExpandCurrencyList then
        local wanted = {}

        for _, name in ipairs(collapsed) do
            wanted[name] = true
        end

        local counted, final = pcall(C_CurrencyInfo.GetCurrencyListSize)

        if counted and type(final) == "number" then
            for index = final, 1, -1 do
                local asked, row = pcall(C_CurrencyInfo.GetCurrencyListInfo, index)

                if asked and type(row) == "table" and row.isHeader
                    and row.name and wanted[row.name] then

                    pcall(C_CurrencyInfo.ExpandCurrencyList, index, false)
                end
            end
        end
    end

    return results
end

function Blizzard.GetCurrency(currencyID)
    if not C_CurrencyInfo or not C_CurrencyInfo.GetCurrencyInfo then
        return nil
    end

    local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, currencyID)

    if not ok or type(info) ~= "table" then
        return nil
    end

    return info
end

------------------------------------------------------------
-- EXPLORATION
------------------------------------------------------------

-- Blizzard exposes explored overlay textures but never a total, so a raw
-- "percent explored" cannot be computed from the map API. The Exploration
-- achievement category does carry per-subzone criteria, which is the only
-- countable exploration data the client offers.
CN_EXPLORATION_CATEGORY = 97

function Blizzard.GetExplorationAchievements()
    local results = {}

    if not GetCategoryNumAchievements then
        return results
    end

    local total = Blizzard.GetCategoryCounts(CN_EXPLORATION_CATEGORY)

    for index = 1, total do
        local achievement =
            Blizzard.GetAchievementInCategory(CN_EXPLORATION_CATEGORY, index)

        if achievement then
            local done, criteria =
                Blizzard.GetAchievementProgress(achievement.achievementID)

            table.insert(results, {
                achievementID = achievement.achievementID,
                name          = achievement.name,
                completed     = achievement.completed,
                done          = done,
                criteria      = criteria,
            })
        end
    end

    return results
end

-- The unfinished criteria of one achievement, by name. For exploration
-- achievements these are the subzone names still undiscovered.
function Blizzard.GetIncompleteCriteria(achievementID, limit)
    local missing = {}

    if not GetAchievementNumCriteria or not GetAchievementCriteriaInfo then
        return missing
    end

    local total = GetAchievementNumCriteria(achievementID) or 0

    for index = 1, total do
        local ok, description, _, completed =
            pcall(GetAchievementCriteriaInfo, achievementID, index)

        if ok and not completed and description and description ~= "" then
            table.insert(missing, description)

            if limit and #missing >= limit then
                break
            end
        end
    end

    return missing
end

-- Every criterion, with its state, not only the missing ones.
--
-- GetIncompleteCriteria answers "what is left". A chain needs "what is the
-- whole path, and where on it am I" -- the done ones are what make progress
-- legible, and dropping them means the player sees five things left and no
-- sense of whether that is five out of six or five out of fifty.
--
-- `limit` BOUNDS THE LIST, NOT THE COUNT. FIXED IN 0.61.0.
--
-- The loop used to `break` at the limit, so a caller that passed 25 and then
-- counted the returned rows was counting a WINDOW and calling it a total.
-- Chase.lua did exactly that: "Glory of the Dragonflight Raider" has 31
-- criteria, so an achievement 9 of 31 done printed 9/25 -- 36% for something
-- 29% done -- and the moment a player crossed 25 criteria it printed 100%
-- with steps still outstanding. Every meta achievement in the game is past
-- the cap, and metas are precisely what a chase list is for.
--
-- The walk is cheap and bounded by the client (no achievement has more than
-- a few dozen criteria), so it now always completes and the limit is applied
-- only to what is APPENDED. The second return value carries the honest
-- figures.
--
-- Returns: criteria, summary
--   summary = { total = n, completed = c, truncated = bool }
function Blizzard.GetAchievementCriteriaList(achievementID, limit)
    local criteria = {}
    local summary  = { total = 0, completed = 0, truncated = false }

    if not GetAchievementNumCriteria or not GetAchievementCriteriaInfo then
        return criteria, summary
    end

    local count = GetAchievementNumCriteria(achievementID) or 0

    for index = 1, count do
        local ok, description, _, completed, quantity, required =
            pcall(GetAchievementCriteriaInfo, achievementID, index)

        if ok and description and description ~= "" then
            completed = completed and true or false

            summary.total = summary.total + 1

            if completed then
                summary.completed = summary.completed + 1
            end

            if limit and #criteria >= limit then
                summary.truncated = true
            else
                table.insert(criteria, {
                    index       = index,
                    description = description,
                    completed   = completed,
                    quantity    = quantity,
                    required    = required,
                })
            end
        end
    end

    return criteria, summary
end

-- How much standing remains before the next rank, and what that rank is.
--
-- Reputation is one of the few things in the game with a denominator the
-- client will actually vouch for, which is why it gets a real number here
-- while most of this addon refuses to invent one.
function Blizzard.GetReputationRemaining(factionID)
    local data = Blizzard.GetFactionByID(factionID)

    if not data then
        return nil
    end

    local current   = data.currentStanding or data.currentReactionThreshold
    local threshold = data.nextReactionThreshold
    local floor     = data.currentReactionThreshold

    if not current or not threshold or not floor then
        return nil
    end

    local earned = current - floor
    local needed = threshold - floor

    if needed <= 0 then
        return nil
    end

    return {
        earned    = earned,
        needed    = needed,
        remaining = math.max(0, needed - earned),
        standing  = data.reaction,
        name      = data.name,

        -- The rank being worked toward, so a band can be reported as a band
        -- -- "11,999 of 12,000 to Revered" -- rather than as a fraction of a
        -- goal the client will not vouch for.
        nextRankName = data.nextReactionName or data.nextRank,
    }
end

-- Every way the game knows of to obtain an appearance.
--
-- An appearance is not one item. It is a set of sources -- a drop here, a
-- vendor there, a quest reward -- and "which of these can I actually still
-- get" is the question a transmog hunter is asking.
function Blizzard.GetAppearanceSources(appearanceID)
    local sources = {}

    if not C_TransmogCollection or not C_TransmogCollection.GetAppearanceSources then
        return sources
    end

    local ok, results = pcall(C_TransmogCollection.GetAppearanceSources, appearanceID)

    if not ok or type(results) ~= "table" then
        return sources
    end

    for _, source in ipairs(results) do
        table.insert(sources, {
            sourceID    = source.sourceID,
            name        = source.name,
            collected   = source.isCollected and true or false,
            sourceType  = source.sourceType,
            itemID      = source.itemID,
        })
    end

    return sources
end

------------------------------------------------------------
-- MAP TOPOLOGY
------------------------------------------------------------

-- The map you are standing on is not necessarily the map a quest giver is
-- registered against.
--
-- GetBestMapForUnit answers with the most SPECIFIC map containing you, which
-- in a city or a cave is a small child map. Quest starts belonging to the
-- surrounding zone are registered on the PARENT, so a player standing in
-- front of an exclamation mark in a city can be told there is nothing here.
-- Reported from live play, exactly that way.
function Blizzard.GetMapInfo(mapID)
    if not mapID or not C_Map or not C_Map.GetMapInfo then
        return nil
    end

    local ok, info = pcall(C_Map.GetMapInfo, mapID)

    return ok and info or nil
end

-- WHICH ZONE THE PLAYER IS IN, AS AN ID. 0.73.0.
--
-- `GetBestMapForUnit` answers with the most SPECIFIC map containing you: in
-- Dornogal it says Dornogal, in a cave it says the cave. That is the right
-- answer for "where exactly am I" and the wrong one for "which zone is this",
-- and three releases running have used it for the second question:
--
--   0.70.0 matched achievements against `GetMapName(GetBestMapForUnit())`,
--          so nothing matched indoors;
--   0.71.0 matched on `GetZoneText()` and then CACHED under the same wrong
--          id, so the cache never converged and wrote a different value on
--          each side of a doorway;
--   0.72.0 dropped the id entirely and keyed on the zone NAME, which is
--          right for the match and cannot separate Outland's Nagrand from
--          Draenor's -- a distinction `Exploration` documents by name and
--          which had been held, until then, by the id.
--
-- The answer to the actual question is up the parent chain: the first
-- ancestor the client itself calls a zone. `mapType` 3 is Zone; 4 and above
-- are dungeon and micro maps, which is where a capital's interior lives. Two
-- or three hops, no allocation, and unlike a name it cannot be duplicated.
--
-- Falls back to the specific map when the walk finds no zone above it, so a
-- caller always gets the best available identity rather than nothing.
Blizzard.zoneMapType = 3

function Blizzard.ZoneMapID(mapID)
    if not mapID then
        return nil
    end

    local current = mapID
    local guard   = 0

    while current and guard < 8 do
        local info = Blizzard.GetMapInfo(current)

        if not info then
            return mapID
        end

        if (info.mapType or 0) == Blizzard.zoneMapType then
            return current
        end

        -- Above a zone: a continent or the world. The specific map is the
        -- closest thing to a zone identity there is.
        if (info.mapType or 0) < Blizzard.zoneMapType then
            return mapID
        end

        local parentID = info.parentMapID

        if not parentID or parentID <= 0 then
            return mapID
        end

        current = parentID
        guard   = guard + 1
    end

    return mapID
end

-- The name of the continent the player is on, from the client. Used to break
-- a tie between two zones that genuinely share a name -- see
-- `Loremaster.BetterZoneMatch`. Nil rather than a guess when the walk cannot
-- reach one.
Blizzard.continentMapType = 2

function Blizzard.ContinentName(mapID)
    if not mapID then
        return nil
    end

    local current = mapID
    local guard   = 0

    while current and guard < 10 do
        local info = Blizzard.GetMapInfo(current)

        if not info then
            return nil
        end

        if (info.mapType or 0) == Blizzard.continentMapType then
            return info.name
        end

        local parentID = info.parentMapID

        if not parentID or parentID <= 0 then
            return nil
        end

        current = parentID
        guard   = guard + 1
    end

    return nil
end

function Blizzard.GetMapChildren(mapID)
    if not mapID or not C_Map or not C_Map.GetMapChildrenInfo then
        return {}
    end

    local ok, children = pcall(C_Map.GetMapChildrenInfo, mapID)

    if not ok or type(children) ~= "table" then
        return {}
    end

    return children
end

-- Every map worth asking about when the question is "what is around me":
-- the map itself, its parent, and the parent's other children. Ordered
-- nearest-first and deduplicated.
function Blizzard.RelatedMapIDs(mapID)
    local ordered, seen = {}, {}

    local function add(id)
        if id and not seen[id] then
            seen[id] = true
            table.insert(ordered, id)
        end
    end

    add(mapID)

    local info = Blizzard.GetMapInfo(mapID)

    local parentID = info and info.parentMapID

    -- A continent or world map has thousands of descendants; walking those
    -- would be a scan, not a lookup. Zone and below only.
    if parentID and parentID > 0 then
        local parent = Blizzard.GetMapInfo(parentID)

        -- 3 = zone, 4 = dungeon/micro. Anything broader is a continent.
        if parent and (parent.mapType or 0) >= 3 then
            add(parentID)

            for _, child in ipairs(Blizzard.GetMapChildren(parentID)) do
                add(child.mapID)
            end
        end
    end

    for _, child in ipairs(Blizzard.GetMapChildren(mapID)) do
        add(child.mapID)
    end

    return ordered
end

------------------------------------------------------------
-- QUEST COMPLETION HISTORY
------------------------------------------------------------

-- Every quest this character has ever completed.
--
-- This is a real number the client will vouch for, unlike anything the addon
-- counts about itself, and it is the number a player who has done three
-- hundred quests in a weekend actually wants to see.
function Blizzard.GetAllCompletedQuestIDs()
    if not C_QuestLog or not C_QuestLog.GetAllCompletedQuestIDs then
        return nil
    end

    local ok, ids = pcall(C_QuestLog.GetAllCompletedQuestIDs)

    -- AN EMPTY LIST EARLY IN A LOGIN IS "NOT YET", NOT "NONE". 0.62.0.
    --
    -- The client returns an EMPTY TABLE, not nil, before it has finished
    -- loading quest data. This accepted any table, so `Progress.BeginSession`
    -- snapshotted a lifetime baseline of zero at `PLAYER_LOGIN`, and when the
    -- real list arrived every quest the character had ever completed counted
    -- as done "this session": `/cn progress` printed "This session: 34,812"
    -- and a per-hour rate derived from it.
    --
    -- The nil path was handled and the empty-table path was not, which is the
    -- same shape as the map that was always square: the case the fixture
    -- could not express.
    --
    -- Zero completed quests is a real state for a brand-new character, so it
    -- is not an error -- it is UNKNOWN until the client says something. The
    -- caller re-asks; nothing here has to guess.
    if ok and type(ids) == "table" and #ids > 0 then
        return ids
    end

    return nil
end

-- Quests offered by the NPC currently being spoken to.
--
-- The most reliable "there is a quest right here" signal there is: the player
-- is standing in the conversation. Map data can be missing or registered
-- against a map we did not think to ask about; this cannot be wrong.
function Blizzard.GetGossipAvailableQuests()
    local offered = {}

    if not C_GossipInfo then
        return offered
    end

    local sources = {}

    if C_GossipInfo.GetAvailableQuests then
        table.insert(sources, C_GossipInfo.GetAvailableQuests)
    end

    for _, source in ipairs(sources) do
        local ok, quests = pcall(source)

        if ok and type(quests) == "table" then
            for _, quest in ipairs(quests) do
                if type(quest) == "table" and quest.questID then
                    table.insert(offered, {
                        questID   = quest.questID,
                        title     = quest.title,
                        isDaily   = quest.frequency == 2 or quest.isDaily,
                        isRepeatable = quest.repeatable and true or false,
                    })
                end
            end
        end
    end

    return offered
end

-- Quests the questgiver window is offering right now (the non-gossip case:
-- an NPC with a single quest opens the detail frame directly).
function Blizzard.GetActiveQuestOffer()
    if not GetQuestID then
        return nil
    end

    local ok, questID = pcall(GetQuestID)

    if ok and questID and questID > 0 then
        return questID
    end

    return nil
end

-- Bonus objectives and world quests keyed to a map. These are "available"
-- in every sense a player means, and they are not quest starts.
function Blizzard.GetTaskQuestsOnMap(uiMapID)
    local tasks = {}

    if not uiMapID or not C_TaskQuest or not C_TaskQuest.GetQuestsForPlayerByMapID then
        return tasks
    end

    local ok, results = pcall(C_TaskQuest.GetQuestsForPlayerByMapID, uiMapID)

    if not ok or type(results) ~= "table" then
        return tasks
    end

    for _, task in ipairs(results) do
        if type(task) == "table" and task.questId then
            table.insert(tasks, {
                questID = task.questId,
                x       = task.x,
                y       = task.y,
                mapID   = task.mapID or uiMapID,
                inProgress = task.inProgress and true or false,
            })
        end
    end

    return tasks
end

------------------------------------------------------------
-- CAMPAIGNS
------------------------------------------------------------

-- The main story, as distinct from everything else.
--
-- A player working through an expansion says "the story" and "the side
-- quests" and means two genuinely different things; the client knows which
-- is which and the addon should stop pretending they are one pile.
function Blizzard.GetCampaignID(questID)
    if not questID or not C_CampaignInfo or not C_CampaignInfo.GetCampaignID then
        return nil
    end

    local ok, campaignID = pcall(C_CampaignInfo.GetCampaignID, questID)

    if ok and campaignID and campaignID > 0 then
        return campaignID
    end

    return nil
end

function Blizzard.GetCampaignInfo(campaignID)
    if not campaignID or not C_CampaignInfo or not C_CampaignInfo.GetCampaignInfo then
        return nil
    end

    local ok, info = pcall(C_CampaignInfo.GetCampaignInfo, campaignID)

    return ok and info or nil
end

function Blizzard.GetCampaignChapters(campaignID)
    if not campaignID or not C_CampaignInfo or not C_CampaignInfo.GetChapterIDs then
        return {}
    end

    local ok, chapters = pcall(C_CampaignInfo.GetChapterIDs, campaignID)

    return (ok and type(chapters) == "table") and chapters or {}
end

function Blizzard.IsQuestCampaign(questID)
    return Blizzard.GetCampaignID(questID) ~= nil
end

------------------------------------------------------------
-- MERCHANTS
------------------------------------------------------------

-- Vendor inventories are only readable while the merchant window is open,
-- exactly like trade skill recipes. Everything here is opportunistic.
function Blizzard.GetMerchantItems()
    local items = {}

    if not GetMerchantNumItems then
        return items
    end

    local ok, count = pcall(GetMerchantNumItems)

    if not ok or type(count) ~= "number" then
        return items
    end

    for index = 1, count do
        local gotInfo, name, texture, price, quantity, numAvailable,
              isPurchasable, isUsable, extendedCost =
              pcall(GetMerchantItemInfo, index)

        if gotInfo and name then
            local itemID

            if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
                local gotItem, info = pcall(C_MerchantFrame.GetItemInfo, index)

                if gotItem and type(info) == "table" then
                    itemID = info.itemID
                end
            end

            if not itemID and GetMerchantItemLink then
                local gotLink, link = pcall(GetMerchantItemLink, index)

                if gotLink and type(link) == "string" then
                    itemID = tonumber(link:match("item:(%d+)"))
                end
            end

            table.insert(items, {
                index         = index,
                itemID        = itemID,
                name          = name,
                price         = price,
                available     = numAvailable,
                isPurchasable = isPurchasable and true or false,
                extendedCost  = extendedCost and true or false,
            })
        end
    end

    return items
end

-- The creature ID behind any unit token. The GUID carries it, and it is the
-- only stable identifier for an NPC.
function Blizzard.GetUnitNPCID(unit)
    if not unit or not UnitExists or not UnitExists(unit) then
        return nil, nil
    end

    local name = UnitName and UnitName(unit) or nil

    local guid = UnitGUID and UnitGUID(unit)

    if not guid then
        return nil, name
    end

    -- GUID form: Creature-0-serverID-instanceID-zoneUID-npcID-spawnUID
    --
    -- The extra parentheses matter: select(6, ...) returns every value from
    -- position 6 onward, so without them tonumber receives the spawn UID as
    -- its `base` argument and throws.
    local npcID = tonumber((select(6, strsplit("-", guid))))

    return npcID, name
end

-- The NPC currently being interacted with.
function Blizzard.GetInteractingNPC()
    return Blizzard.GetUnitNPCID("npc")
end

------------------------------------------------------------
-- ITEM IDENTITY
------------------------------------------------------------

-- Items that teach a collectible do not announce themselves as such; each
-- collection API has its own item lookup. All three are optional and all
-- three have changed shape before, so each is probed rather than assumed.

function Blizzard.GetMountFromItem(itemID)
    if not itemID or not C_MountJournal or not C_MountJournal.GetMountFromItem then
        return nil
    end

    return C_MountJournal.GetMountFromItem(itemID)
end

function Blizzard.GetPetSpeciesFromItem(itemID)
    if not itemID or not C_PetJournal or not C_PetJournal.GetPetInfoByItemID then
        return nil, nil
    end

    local name, icon, petType, companionID, tooltipSource, description,
          isWild, canBattle, isTradeable, isUnique, obtainable, creatureDisplayID,
          speciesID = C_PetJournal.GetPetInfoByItemID(itemID)

    -- The species ID has moved position in this return list before. Falling
    -- back to the companion ID keeps the lookup working either way.
    return speciesID or companionID, name
end

-- Returns true/false only for items that actually have an appearance, and nil
-- for everything else.
--
-- The gate matters. PlayerHasTransmogByItemInfo answers false for a stack of
-- ore just as readily as for an unlearned tabard, so using it alone would
-- stamp "appearance not yet known" on every trade good in the game.
function Blizzard.HasTransmogByItem(itemID)
    if not itemID or not C_TransmogCollection then
        return nil
    end

    if not C_TransmogCollection.GetItemInfo then
        return nil
    end

    local ok, appearanceID = pcall(C_TransmogCollection.GetItemInfo, itemID)

    if not ok or not appearanceID then
        return nil
    end

    if C_TransmogCollection.PlayerHasTransmogByItemInfo then
        local hasOk, has = pcall(C_TransmogCollection.PlayerHasTransmogByItemInfo, itemID)

        if hasOk then
            return has and true or false
        end
    end

    return nil
end

function Blizzard.GetItemName(itemID)
    if not itemID then
        return nil
    end

    if C_Item and C_Item.GetItemNameByID then
        return C_Item.GetItemNameByID(itemID)
    end

    if GetItemInfo then
        return (GetItemInfo(itemID))
    end

    return nil
end

------------------------------------------------------------
-- SAVED INSTANCES
------------------------------------------------------------

-- What you are locked to this week, straight from the client.
--
-- NEVER PERSISTED. A lockout is a fact with an expiry on it, the client
-- always knows it, and a stale copy on disk would be worse than no copy at
-- all: "you have 6 of 8 bosses down in there" is actively harmful advice
-- after the reset it did not know about.
--
-- Returns an array of:
--   { name, id, reset, difficultyID, difficulty, defeated, encounters,
--     locked, extended, raid }
function Blizzard.GetSavedInstances()
    local results = {}

    if not GetNumSavedInstances or not GetSavedInstanceInfo then
        return results
    end

    local ok, count = pcall(GetNumSavedInstances)

    if not ok or not count then
        return results
    end

    for index = 1, count do
        -- POSITION 11 IS THE TOTAL AND 12 IS THE PROGRESS, NOT THE REVERSE.
        --
        -- The client returns ... difficultyName, numEncounters,
        -- encounterProgress. This read them the other way round, so a raid
        -- with six of eight bosses down came back as defeated=8, encounters=6
        -- -- which made `remaining` clamp to zero, `complete` true, and the
        -- provider return NOTHING. The Instances module's whole stated purpose
        -- is that a part-finished lockout is the cheapest progress in the
        -- game, and it has never once produced a candidate.
        --
        -- The stub had the same belief written into its fixture comment, so
        -- the suite agreed. Eighth time in this project that a stub and the
        -- code shared one wrong assumption.
        -- TWO DIFFERENT ID SPACES, AND THE ADDON USED THE WRONG ONE.
        --
        -- Return #2 is the LOCKOUT id -- a large opaque save identifier. The
        -- Encounter Journal's instance id is return #14. The addon stored #2
        -- as `id` and then handed it to `EJ_SelectInstance` and
        -- `EJ_GetEncounterInfoByIndex`, which have never heard of it: in game
        -- the boss list came back empty on the first iteration and
        -- `RemainingBosses` always answered "the Adventure Guide has no boss
        -- list for this instance".
        --
        -- The fixture put Encounter Journal instance ids in slot 2, so the
        -- stub and the code shared one wrong belief and the self-test asserted
        -- against it. Ninth time in this project.
        --
        -- Both are kept now, under names that say which is which, and the
        -- journal is asked with the journal's id.
        local gotInfo, name, lockoutID, reset, difficultyID, locked, extended,
            _, isRaid, _, difficultyName, encounters, defeated, _,
            journalInstanceID =
                pcall(GetSavedInstanceInfo, index)

        if gotInfo and name then
            table.insert(results, {
                name         = name,
                id           = lockoutID,
                instanceID   = journalInstanceID,
                reset        = reset,
                difficultyID = difficultyID,
                difficulty   = difficultyName,
                locked       = locked and true or false,
                extended     = extended and true or false,
                raid         = isRaid and true or false,
                defeated     = defeated or 0,
                encounters   = encounters or 0,
            })
        end
    end

    return results
end

------------------------------------------------------------
-- THE ENCOUNTER JOURNAL
------------------------------------------------------------

-- READING THIS API CHANGES WHAT THE PLAYER IS LOOKING AT.
--
-- EJ_SelectInstance and EJ_SelectEncounter are not queries. They set the
-- journal's current selection, which is the same selection the Adventure
-- Guide window is displaying. Scanning it while that window is open would
-- move the player's view out from under them -- an addon reaching into the
-- interface and changing what somebody is reading, which is exactly the kind
-- of thing this addon does not do.
--
-- So: refuse while the journal is visible, and put the selection back
-- afterwards when it is not.
function Blizzard.HasEncounterJournal()
    return EJ_SelectInstance ~= nil
        and EJ_GetEncounterInfoByIndex ~= nil
        and EJ_GetInstanceInfo ~= nil
end

function Blizzard.IsEncounterJournalOpen()
    return EncounterJournal ~= nil
        and EncounterJournal.IsShown ~= nil
        and EncounterJournal:IsShown() and true or false
end

local function WithJournal(work)
    if not Blizzard.HasEncounterJournal() then
        return nil, "the Adventure Guide is not available"
    end

    if Blizzard.IsEncounterJournalOpen() then
        return nil, "the Adventure Guide is open" .. CN.DASH .. "close it and try again"
    end

    local restoreInstance

    if EJ_GetCurrentInstance then
        local gotCurrent, current = pcall(EJ_GetCurrentInstance)

        if gotCurrent then
            restoreInstance = current
        end
    end

    local ok, result = pcall(work)

    -- Put it back even when the work threw, or the player's next visit to
    -- the Adventure Guide opens on whatever this addon was reading last.
    --
    -- AND "NOTHING WAS SELECTED" IS A STATE TO RESTORE.
    --
    -- The restore was guarded on `restoreInstance`, and
    -- `EJ_GetCurrentInstance` returns nil whenever the player has not opened
    -- the Adventure Guide this session -- which is the ordinary case, since
    -- this function refuses to run at all while the window is up. So on
    -- virtually every real invocation nothing was restored and the player's
    -- next visit opened on whatever this addon read last: exactly the outcome
    -- the comment above says it exists to prevent.
    if restoreInstance then
        if EJ_SelectInstance then
            pcall(EJ_SelectInstance, restoreInstance)
        end
    elseif EJ_ClearSearch then
        -- Nothing was selected before, so nothing should be selected after.
        -- Clearing the search is the only lever the client offers for that,
        -- and it also drops the search string this addon may have set.
        pcall(EJ_ClearSearch)
    end

    if not ok then
        return nil, tostring(result)
    end

    return result
end

Blizzard.WithEncounterJournal = WithJournal

-- Bosses in an instance, in the order the journal lists them:
--   { encounterID, name, order }
function Blizzard.GetInstanceEncounters(instanceID)
    if not instanceID then
        return {}
    end

    local encounters = WithJournal(function()
        EJ_SelectInstance(instanceID)

        local list = {}

        local index = 1

        while true do
            local name, _, encounterID = EJ_GetEncounterInfoByIndex(index, instanceID)

            if not name then
                break
            end

            table.insert(list, {
                encounterID = encounterID,
                name        = name,
                order       = index,
            })

            index = index + 1

            -- No instance in the game has anything like this many bosses.
            -- The guard is against an API that returns a name forever.
            if index > 40 then
                break
            end
        end

        return list
    end)

    return encounters or {}
end

-- Where does this drop?
--
-- Uses the journal's own search rather than building a reverse index of every
-- item in the game. An index would be tens of thousands of rows to answer a
-- question the player asks a handful of times a session, and it would be
-- stale the day a patch changed a loot table. The search is what the
-- Adventure Guide itself uses.
--
-- Returns an array of { instanceID, instance, encounterID, encounter }.
function Blizzard.SearchEncounterJournal(text, limit)
    if not text or text == "" then
        return {}
    end

    if not EJ_SetSearch or not EJ_GetSearchResult or not EJ_GetNumSearchResults then
        return {}
    end

    limit = limit or 8

    local results = WithJournal(function()
        EJ_SetSearch(text)

        local found = {}

        -- THE SEARCH IS ASYNCHRONOUS.
        --
        -- `EJ_SEARCH_RESULT_UPDATE` exists because `EJ_SetSearch` does not
        -- finish before it returns; Blizzard's own Encounter Journal listens
        -- for it. Read in the same frame, `EJ_GetNumSearchResults` answers
        -- zero on a cold search. The caller then memoised that zero for the
        -- session, so a second query after the results arrived still got
        -- nothing back.
        --
        -- There is no synchronous form to switch to, so the fix is on the
        -- caching side: a zero here is "not yet", not "nothing", and is
        -- reported as such rather than remembered. The stub answered
        -- synchronously, so no test could reach this.
        local total = EJ_GetNumSearchResults() or 0

        for index = 1, math.min(total, limit) do
            local id, stype, _, _, _, instanceID = EJ_GetSearchResult(index)

            -- Type 1 is an encounter in every build that has exposed this.
            if stype == 1 and id then
                local instanceName

                if instanceID and EJ_GetInstanceInfo then
                    instanceName = EJ_GetInstanceInfo(instanceID)
                end

                local encounterName = EJ_GetEncounterInfo and EJ_GetEncounterInfo(id)

                -- The journal's current difficulty, where the build exposes
                -- it. Reported rather than assumed: a nil here means the
                -- client did not say, which is different from "any".
                local difficulty

                if EJ_GetDifficulty and GetDifficultyInfo then
                    local gotDifficulty, difficultyID = pcall(EJ_GetDifficulty)

                    if gotDifficulty and difficultyID then
                        local gotName, name = pcall(GetDifficultyInfo, difficultyID)

                        if gotName then
                            difficulty = name
                        end
                    end
                end

                table.insert(found, {
                    encounterID = id,
                    encounter   = encounterName,
                    instanceID  = instanceID,
                    instance    = instanceName,
                    difficulty  = difficulty,
                })
            end
        end

        if EJ_ClearSearch then
            EJ_ClearSearch()
        end

        return found
    end)

    return results or {}
end

function Blizzard.GetInstanceName(instanceID)
    if not instanceID or not EJ_GetInstanceInfo then
        return nil
    end

    local ok, name = pcall(EJ_GetInstanceInfo, instanceID)

    return ok and name or nil
end
