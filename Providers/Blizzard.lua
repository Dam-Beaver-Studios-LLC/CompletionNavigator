-- Providers/Blizzard.lua
-- Completion Navigator :: thin, defensive wrappers over Blizzard APIs.
--
-- Every call into the client goes through here. Blizzard renames and
-- removes APIs between patches; keeping the surface area in one file means
-- a patch break is a one-file fix rather than a hunt.

local ADDON_NAME, CN = ...

local Blizzard = {}

CN.Blizzard = Blizzard

------------------------------------------------------------
-- QUESTS
------------------------------------------------------------

function Blizzard.IsQuestCompletedByCharacter(questID)
    if not questID then
        return false
    end

    if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted then
        return C_QuestLog.IsQuestFlaggedCompleted(questID) and true or false
    end

    return false
end

function Blizzard.HasAccountQuestAPI()
    return (C_QuestLog and C_QuestLog.IsQuestFlaggedCompletedOnAccount) and true or false
end

function Blizzard.IsQuestCompletedOnAccount(questID)
    if not questID then
        return false
    end

    if C_QuestLog and C_QuestLog.IsQuestFlaggedCompletedOnAccount then
        return C_QuestLog.IsQuestFlaggedCompletedOnAccount(questID) and true or false
    end

    return false
end

-- Returns a title if the client already has it cached. Otherwise requests
-- an asynchronous load and returns nil; QUEST_DATA_LOAD_RESULT follows.
function Blizzard.GetQuestTitle(questID, requestIfMissing)
    if not questID then
        return nil
    end

    if C_QuestLog and C_QuestLog.GetTitleForQuestID then
        local title = C_QuestLog.GetTitleForQuestID(questID)

        if title and title ~= "" then
            return title
        end
    end

    if requestIfMissing and C_QuestLog and C_QuestLog.RequestLoadQuestByID then
        CN.pendingQuestLoads = CN.pendingQuestLoads or {}
        CN.pendingQuestLoads[questID] = true

        C_QuestLog.RequestLoadQuestByID(questID)
    end

    return nil
end

function Blizzard.GetQuestLogEntries()
    local entries = {}

    if not C_QuestLog or not C_QuestLog.GetNumQuestLogEntries then
        return entries
    end

    local count = C_QuestLog.GetNumQuestLogEntries()

    for index = 1, count do
        local info = C_QuestLog.GetInfo(index)

        if info and not info.isHeader and info.questID and info.questID > 0 then
            table.insert(entries, info)
        end
    end

    return entries
end

-- Scans the map's quest POIs for one quest. This is the source that
-- actually covers ordinary quests; GetNextWaypoint only answers for quests
-- Blizzard has given an explicit waypoint.
function Blizzard.GetQuestPOIOnMap(questID, uiMapID)
    if not questID or not uiMapID or not C_QuestLog or not C_QuestLog.GetQuestsOnMap then
        return nil, nil
    end

    local ok, quests = pcall(C_QuestLog.GetQuestsOnMap, uiMapID)

    if not ok or type(quests) ~= "table" then
        return nil, nil
    end

    for _, info in ipairs(quests) do
        if info.questID == questID and info.x and info.y then
            return info.x, info.y
        end
    end

    return nil, nil
end

-- Every quest POI the client would draw on a map, with its flags.
--
-- This is where the quests you have NOT accepted live. `isQuestStart` marks
-- the exclamation-mark pins -- a quest offered by an NPC standing there -- and
-- `inProgress` distinguishes those from the ones already in your log.
--
-- The addon read this API from the beginning and threw all of that away: it
-- only ever asked "where is this specific quest I already have?". So every
-- quest available in the zone was structurally invisible, which is exactly
-- what a player noticed in game.
function Blizzard.GetQuestPOIsOnMap(uiMapID)
    if not uiMapID or not C_QuestLog or not C_QuestLog.GetQuestsOnMap then
        return {}
    end

    local ok, quests = pcall(C_QuestLog.GetQuestsOnMap, uiMapID)

    if not ok or type(quests) ~= "table" then
        return {}
    end

    local pois = {}

    for _, info in ipairs(quests) do
        if type(info) == "table" and info.questID then
            table.insert(pois, {
                questID      = info.questID,
                x            = info.x,
                y            = info.y,
                mapID        = info.mapID or uiMapID,
                isQuestStart = info.isQuestStart and true or false,
                inProgress   = info.inProgress and true or false,
                isDaily      = info.isDaily and true or false,
                isMeta       = info.isMeta and true or false,
                tagType      = info.questTagType,
            })
        end
    end

    return pois
end

-- Returns mapID, x, y for the next thing the player must physically do for
-- this quest, trying every source the client exposes before giving up.
function Blizzard.GetQuestWaypoint(questID, preferredMapID)
    if not questID then
        return nil, nil, nil
    end

    -- 1. An explicit waypoint, if the quest has one.
    if C_QuestLog and C_QuestLog.GetNextWaypoint then
        local mapID, x, y = C_QuestLog.GetNextWaypoint(questID)

        if mapID and x and y then
            return mapID, x, y
        end
    end

    local playerMap = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")

    local candidateMaps = {}

    if preferredMapID then
        table.insert(candidateMaps, preferredMapID)
    end

    if playerMap and playerMap ~= preferredMapID then
        table.insert(candidateMaps, playerMap)
    end

    local zoneMap = Blizzard.GetQuestZone(questID)

    if zoneMap and zoneMap ~= playerMap and zoneMap ~= preferredMapID then
        table.insert(candidateMaps, zoneMap)
    end

    for _, mapID in ipairs(candidateMaps) do
        -- 2. The quest's next waypoint expressed on this specific map.
        if C_QuestLog and C_QuestLog.GetNextWaypointForMap then
            local x, y = C_QuestLog.GetNextWaypointForMap(questID, mapID)

            if x and y then
                return mapID, x, y
            end
        end

        -- 3. The quest's POI blip on this map.
        local x, y = Blizzard.GetQuestPOIOnMap(questID, mapID)

        if x and y then
            return mapID, x, y
        end

        -- 4. World-quest style task location.
        if C_TaskQuest and C_TaskQuest.GetQuestLocation then
            local taskX, taskY = C_TaskQuest.GetQuestLocation(questID, mapID)

            if taskX and taskY then
                return mapID, taskX, taskY
            end
        end
    end

    return zoneMap or playerMap, nil, nil
end

-- Blizzard's own quest tracking arrow. The correct answer when we have no
-- coordinates but the game does: it knows where its own quests are.
function Blizzard.SuperTrackQuest(questID)
    if not questID or not C_SuperTrack then
        return false
    end

    if C_SuperTrack.SetSuperTrackedQuestID then
        C_SuperTrack.SetSuperTrackedQuestID(questID)
        return true
    end

    return false
end

function Blizzard.IsQuestInLog(questID)
    if not questID or not C_QuestLog or not C_QuestLog.GetLogIndexForQuestID then
        return false
    end

    return C_QuestLog.GetLogIndexForQuestID(questID) ~= nil
end

function Blizzard.IsQuestReadyForTurnIn(questID)
    if C_QuestLog and C_QuestLog.ReadyForTurnIn then
        return C_QuestLog.ReadyForTurnIn(questID) and true or false
    end

    return false
end

function Blizzard.IsQuestComplete(questID)
    if C_QuestLog and C_QuestLog.IsComplete then
        return C_QuestLog.IsComplete(questID) and true or false
    end

    return false
end

-- Returns completed, total for a quest's objectives.
function Blizzard.GetQuestObjectiveProgress(questID)
    if not C_QuestLog or not C_QuestLog.GetQuestObjectives then
        return 0, 0
    end

    local objectives = C_QuestLog.GetQuestObjectives(questID)

    if not objectives then
        return 0, 0
    end

    local done, total = 0, 0

    for _, objective in ipairs(objectives) do
        total = total + 1

        if objective.finished then
            done = done + 1
        end
    end

    return done, total
end

function Blizzard.GetQuestZone(questID)
    if C_TaskQuest and C_TaskQuest.GetQuestZoneID then
        local mapID = C_TaskQuest.GetQuestZoneID(questID)

        if mapID then
            return mapID
        end
    end

    if C_QuestLog and C_QuestLog.GetQuestAdditionalHighlights then
        local mapID = C_QuestLog.GetQuestAdditionalHighlights(questID)

        if mapID then
            return mapID
        end
    end

    return nil
end

------------------------------------------------------------
-- REPUTATION
------------------------------------------------------------

-- Retail moved everything to C_Reputation / C_MajorFactions in 11.0.
-- GetFactionInfoByID is gone; never reintroduce it.

function Blizzard.GetNumFactions()
    if C_Reputation and C_Reputation.GetNumFactions then
        return C_Reputation.GetNumFactions()
    end

    return 0
end

function Blizzard.GetFactionByIndex(index)
    if C_Reputation and C_Reputation.GetFactionDataByIndex then
        return C_Reputation.GetFactionDataByIndex(index)
    end

    return nil
end

function Blizzard.GetFactionByID(factionID)
    if C_Reputation and C_Reputation.GetFactionDataByID then
        return C_Reputation.GetFactionDataByID(factionID)
    end

    return nil
end

-- True when the standing is shared across the Warband rather than earned
-- per character. This is the single most important flag for deciding
-- which character should do reputation work.
function Blizzard.IsAccountWideReputation(factionID)
    if C_Reputation and C_Reputation.IsAccountWideReputation then
        return C_Reputation.IsAccountWideReputation(factionID) and true or false
    end

    return false
end

function Blizzard.IsMajorFaction(factionID)
    if C_Reputation and C_Reputation.IsMajorFaction then
        return C_Reputation.IsMajorFaction(factionID) and true or false
    end

    return false
end

function Blizzard.GetMajorFactionData(factionID)
    if C_MajorFactions and C_MajorFactions.GetMajorFactionData then
        return C_MajorFactions.GetMajorFactionData(factionID)
    end

    return nil
end

function Blizzard.HasMaximumRenown(factionID)
    if C_MajorFactions and C_MajorFactions.HasMaximumRenown then
        return C_MajorFactions.HasMaximumRenown(factionID) and true or false
    end

    return false
end

function Blizzard.IsFactionParagon(factionID)
    if C_Reputation and C_Reputation.IsFactionParagon then
        return C_Reputation.IsFactionParagon(factionID) and true or false
    end

    return false
end

-- Returns currentValue, threshold, rewardQuestID, hasRewardPending.
function Blizzard.GetParagonInfo(factionID)
    if C_Reputation and C_Reputation.GetFactionParagonInfo then
        return C_Reputation.GetFactionParagonInfo(factionID)
    end

    return nil
end

-- Friendship-style reputations (Brann, tenders, and similar) do not use
-- the standard 1-8 reaction scale.
function Blizzard.GetFriendshipReputation(factionID)
    if C_GossipInfo and C_GossipInfo.GetFriendshipReputation then
        local info = C_GossipInfo.GetFriendshipReputation(factionID)

        if info and info.friendshipFactionID and info.friendshipFactionID > 0 then
            return info
        end
    end

    return nil
end

function Blizzard.GetStandingLabel(reaction)
    if not reaction then
        return "Unknown"
    end

    return _G["FACTION_STANDING_LABEL" .. reaction] or ("Standing " .. reaction)
end

-- The faction list only reports rows whose headers are expanded, so a
-- complete scan has to expand everything and then put it back.
function Blizzard.WithAllFactionsExpanded(scan)
    local collapsed = {}

    if C_Reputation and C_Reputation.GetNumFactions then
        for index = C_Reputation.GetNumFactions(), 1, -1 do
            local data = Blizzard.GetFactionByIndex(index)

            if data and data.isCollapsed then
                collapsed[data.factionID or index] = true
            end
        end
    end

    if C_Reputation and C_Reputation.ExpandAllFactionHeaders then
        C_Reputation.ExpandAllFactionHeaders()
    end

    local ok, err = pcall(scan)

    if C_Reputation and C_Reputation.CollapseFactionHeader then
        for index = Blizzard.GetNumFactions(), 1, -1 do
            local data = Blizzard.GetFactionByIndex(index)

            if data and data.factionID and collapsed[data.factionID] then
                C_Reputation.CollapseFactionHeader(index)
            end
        end
    end

    if not ok then
        error(err, 0)
    end
end

------------------------------------------------------------
-- CHARACTER
------------------------------------------------------------

function Blizzard.GetProfessions()
    local result = {}

    if not GetProfessions then
        return result
    end

    -- GetProfessions returns nil for any slot the character lacks, and
    -- ipairs stops at the first nil. A character without Archaeology would
    -- silently lose Fishing and Cooking. Index the slots explicitly.
    local slots = { GetProfessions() }

    for slot = 1, 5 do
        local index = slots[slot]

        if index then
            local name, _, rank, maxRank, _, _, skillLineID = GetProfessionInfo(index)

            if name then
                table.insert(result, {
                    name        = name,
                    rank        = rank,
                    maxRank     = maxRank,
                    skillLineID = skillLineID,
                })
            end
        end
    end

    return result
end

------------------------------------------------------------
-- MAP
------------------------------------------------------------

function Blizzard.GetMapName(mapID)
    if not mapID or not C_Map or not C_Map.GetMapInfo then
        return nil
    end

    local info = C_Map.GetMapInfo(mapID)

    return info and info.name or nil
end

------------------------------------------------------------
-- BATTLE PETS
------------------------------------------------------------

-- The pet journal reports only what the player's current filters allow, so
-- any complete scan must widen the filters and then put them back.
function Blizzard.WithAllPetsShown(scan)
    if not C_PetJournal then
        return
    end

    local search = C_PetJournal.GetSearchFilter and C_PetJournal.GetSearchFilter() or ""

    if C_PetJournal.SetSearchFilter then
        C_PetJournal.SetSearchFilter("")
    end

    if C_PetJournal.SetAllPetSourcesChecked then
        C_PetJournal.SetAllPetSourcesChecked(true)
    end

    if C_PetJournal.SetAllPetTypesChecked then
        C_PetJournal.SetAllPetTypesChecked(true)
    end

    if C_PetJournal.SetFilterChecked and LE_PET_JOURNAL_FILTER_COLLECTED then
        C_PetJournal.SetFilterChecked(LE_PET_JOURNAL_FILTER_COLLECTED, true)
        C_PetJournal.SetFilterChecked(LE_PET_JOURNAL_FILTER_NOT_COLLECTED, true)
    end

    local ok, err = pcall(scan)

    if C_PetJournal.SetSearchFilter and search ~= "" then
        C_PetJournal.SetSearchFilter(search)
    end

    if not ok then
        error(err, 0)
    end
end

function Blizzard.GetNumPets()
    if C_PetJournal and C_PetJournal.GetNumPets then
        return C_PetJournal.GetNumPets()
    end

    return 0, 0
end

function Blizzard.GetPetByIndex(index)
    if not C_PetJournal or not C_PetJournal.GetPetInfoByIndex then
        return nil
    end

    local petID, speciesID, owned, customName, level, favorite, isRevoked,
          speciesName, icon, petType, companionID, tooltip, description,
          isWild, canBattle, isTradeable, isUnique, obtainable =
          C_PetJournal.GetPetInfoByIndex(index)

    if not speciesID then
        return nil
    end

    return {
        petID       = petID,
        speciesID   = speciesID,
        owned       = owned and true or false,
        level       = level,
        favorite    = favorite and true or false,
        name        = speciesName,
        icon        = icon,
        petType     = petType,
        isWild      = isWild and true or false,
        canBattle   = canBattle and true or false,
        obtainable  = obtainable ~= false,
        description = description,
    }
end

-- A pet's name, from the client's own journal.
--
-- Exists so the addon can stop keeping its own copy of eighteen hundred pet
-- names on disk. The journal answers instantly and is always current, which a
-- saved copy is not.
function Blizzard.GetPetName(speciesID)
    if not speciesID or not C_PetJournal or not C_PetJournal.GetPetInfoBySpeciesID then
        return nil
    end

    local ok, name = pcall(C_PetJournal.GetPetInfoBySpeciesID, speciesID)

    if ok and name and name ~= "" then
        return name
    end

    return nil
end

function Blizzard.GetPetCollectedCount(speciesID)
    if C_PetJournal and C_PetJournal.GetNumCollectedInfo then
        return C_PetJournal.GetNumCollectedInfo(speciesID)
    end

    return 0, 0
end

------------------------------------------------------------
-- MOUNTS
------------------------------------------------------------

function Blizzard.GetMountIDs()
    if C_MountJournal and C_MountJournal.GetMountIDs then
        return C_MountJournal.GetMountIDs()
    end

    return {}
end

function Blizzard.GetMountByID(mountID)
    if not C_MountJournal or not C_MountJournal.GetMountInfoByID then
        return nil
    end

    local name, spellID, icon, isActive, isUsable, sourceType, isFavorite,
          isFactionSpecific, faction, shouldHideOnChar, isCollected =
          C_MountJournal.GetMountInfoByID(mountID)

    if not name then
        return nil
    end

    local source, description

    if C_MountJournal.GetMountInfoExtraByID then
        local _, extraDescription, extraSource = C_MountJournal.GetMountInfoExtraByID(mountID)

        description = extraDescription
        source      = extraSource
    end

    return {
        mountID           = mountID,
        name              = name,
        spellID           = spellID,
        icon              = icon,
        sourceType        = sourceType,
        isFactionSpecific = isFactionSpecific and true or false,
        faction           = faction,
        hiddenOnCharacter = shouldHideOnChar and true or false,
        isCollected       = isCollected and true or false,
        source            = source,
        description       = description,
    }
end

------------------------------------------------------------
-- TOYS
------------------------------------------------------------

-- Same filter problem as the pet journal.
function Blizzard.WithAllToysShown(scan)
    if not C_ToyBox then
        return
    end

    if C_ToyBox.SetFilterString then
        C_ToyBox.SetFilterString("")
    end

    if C_ToyBox.SetCollectedShown then
        C_ToyBox.SetCollectedShown(true)
    end

    if C_ToyBox.SetUncollectedShown then
        C_ToyBox.SetUncollectedShown(true)
    end

    if C_ToyBox.SetAllSourceTypeFilters then
        C_ToyBox.SetAllSourceTypeFilters(true)
    end

    local ok, err = pcall(scan)

    if not ok then
        error(err, 0)
    end
end

function Blizzard.GetNumToys()
    if C_ToyBox and C_ToyBox.GetNumFilteredToys then
        return C_ToyBox.GetNumFilteredToys()
    end

    if C_ToyBox and C_ToyBox.GetNumToys then
        return C_ToyBox.GetNumToys()
    end

    return 0
end

function Blizzard.GetToyByIndex(index)
    if not C_ToyBox or not C_ToyBox.GetToyFromIndex then
        return nil
    end

    local itemID = C_ToyBox.GetToyFromIndex(index)

    if not itemID or itemID == 0 then
        return nil
    end

    local _, name, icon = C_ToyBox.GetToyInfo(itemID)

    return {
        itemID    = itemID,
        name      = name,
        icon      = icon,
        collected = PlayerHasToy and PlayerHasToy(itemID) and true or false,
    }
end

------------------------------------------------------------
-- APPEARANCES (TRANSMOG)
------------------------------------------------------------

-- Appearance counts are reported per category. Individual appearance
-- enumeration is enormous; the per-category totals are what a completion
-- dashboard actually needs.
function Blizzard.GetAppearanceCategories()
    local categories = {}

    if not C_TransmogCollection then
        return categories
    end

    local names = C_TransmogCollection.GetCategoryInfo
        and Enum and Enum.TransmogCollectionType

    if not names then
        return categories
    end

    for _, categoryID in pairs(Enum.TransmogCollectionType) do
        if type(categoryID) == "number" then
            local name = C_TransmogCollection.GetCategoryInfo(categoryID)

            if name then
                local collected = C_TransmogCollection.GetCategoryCollectedCount
                    and C_TransmogCollection.GetCategoryCollectedCount(categoryID) or 0

                local total = C_TransmogCollection.GetCategoryTotal
                    and C_TransmogCollection.GetCategoryTotal(categoryID) or 0

                if total and total > 0 then
                    table.insert(categories, {
                        categoryID = categoryID,
                        name       = name,
                        collected  = collected,
                        total      = total,
                    })
                end
            end
        end
    end

    table.sort(categories, function(a, b) return a.name < b.name end)

    return categories
end

------------------------------------------------------------
-- TITLES
------------------------------------------------------------

function Blizzard.GetTitles()
    local titles = {}

    if not GetNumTitles then
        return titles
    end

    for index = 1, GetNumTitles() do
        local name = GetTitleName and GetTitleName(index)

        if name and name ~= "" then
            table.insert(titles, {
                titleID = index,
                name    = (name:gsub("^%s+", ""):gsub("%s+$", "")),
                known   = IsTitleKnown and IsTitleKnown(index) and true or false,
            })
        end
    end

    return titles
end

------------------------------------------------------------
-- ACHIEVEMENTS
------------------------------------------------------------

function Blizzard.GetAchievementCategories()
    if GetCategoryList then
        return GetCategoryList()
    end

    return {}
end

function Blizzard.GetCategoryCounts(categoryID)
    if not GetCategoryNumAchievements then
        return 0, 0
    end

    local total, completed = GetCategoryNumAchievements(categoryID, true)

    return total or 0, completed or 0
end

function Blizzard.GetAchievementInCategory(categoryID, index)
    if not GetAchievementInfo then
        return nil
    end

    local id, name, points, completed, _, _, _, description, flags, icon =
        GetAchievementInfo(categoryID, index)

    if not id then
        return nil
    end

    return {
        achievementID = id,
        name          = name,
        points        = points or 0,
        completed     = completed and true or false,
        description   = description,
        icon          = icon,
        flags         = flags,
    }
end

-- Points for one achievement, live from the client.
--
-- The addon stopped storing points in 0.36.0 because the client answers
-- instantly and a copy on disk was dead weight. That was right, and it left
-- one caller reading a field that no longer exists -- so this is the
-- replacement it should have had at the time.
function Blizzard.GetAchievementPoints(achievementID)
    if not GetAchievementInfo or not achievementID then
        return nil
    end

    local ok, _, _, points = pcall(GetAchievementInfo, achievementID)

    if not ok then
        return nil
    end

    return points
end

-- Returns completedCriteria, totalCriteria for one achievement.
-- The achievement's name, straight from the client.
--
-- Needed because a player can pin an achievement the addon has never scanned,
-- and answering them with "Achievement 12345" is the addon admitting it did
-- not look.
function Blizzard.GetAchievementName(achievementID)
    if not GetAchievementInfo or not achievementID then
        return nil
    end

    local ok, _, name = pcall(GetAchievementInfo, achievementID)

    if ok and name and name ~= "" then
        return name
    end

    return nil
end

function Blizzard.GetAchievementProgress(achievementID)
    if not GetAchievementNumCriteria or not GetAchievementCriteriaInfo then
        return 0, 0
    end

    local total = GetAchievementNumCriteria(achievementID) or 0
    local done  = 0

    for index = 1, total do
        local _, _, criteriaCompleted = GetAchievementCriteriaInfo(achievementID, index)

        if criteriaCompleted then
            done = done + 1
        end
    end

    return done, total
end

function Blizzard.GetAchievementTotals()
    if GetNumCompletedAchievements then
        local total, completed = GetNumCompletedAchievements(true)
        return total or 0, completed or 0
    end

    return 0, 0
end

------------------------------------------------------------
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
            local endsIn

            if type(event.endTime) == "table" and event.endTime.monthDay
                and C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset then

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
                    endsIn = stamp - nowStamp
                end
            end

            table.insert(events, {
                title        = event.title,
                eventType    = event.eventType,
                calendarType = event.calendarType,
                sequenceType = event.sequenceType,
                ongoing      = ongoing,
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

    if not C_CurrencyInfo or not C_CurrencyInfo.GetCurrencyListSize then
        return results
    end

    local ok, size = pcall(C_CurrencyInfo.GetCurrencyListSize)

    if not ok or type(size) ~= "number" then
        return results
    end

    for index = 1, size do
        local gotInfo, info = pcall(C_CurrencyInfo.GetCurrencyListInfo, index)

        if gotInfo and type(info) == "table" and not info.isHeader and info.name then
            table.insert(results, {
                currencyID   = info.currencyID,
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
                accountWide = (info.isAccountWide
                    or info.isAccountTransferable) and true or false,
            })
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
function Blizzard.GetAchievementCriteriaList(achievementID, limit)
    local criteria = {}

    if not GetAchievementNumCriteria or not GetAchievementCriteriaInfo then
        return criteria
    end

    local total = GetAchievementNumCriteria(achievementID) or 0

    for index = 1, total do
        local ok, description, _, completed, quantity, required =
            pcall(GetAchievementCriteriaInfo, achievementID, index)

        if ok and description and description ~= "" then
            table.insert(criteria, {
                index       = index,
                description = description,
                completed   = completed and true or false,
                quantity    = quantity,
                required    = required,
            })

            if limit and #criteria >= limit then
                break
            end
        end
    end

    return criteria
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

    if ok and type(ids) == "table" then
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
        local gotInfo, name, id, reset, difficultyID, locked, extended,
            _, isRaid, _, difficultyName, defeated, encounters =
                pcall(GetSavedInstanceInfo, index)

        if gotInfo and name then
            table.insert(results, {
                name         = name,
                id           = id,
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
        return nil, "the Adventure Guide is open -- close it and try again"
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
    if restoreInstance and EJ_SelectInstance then
        pcall(EJ_SelectInstance, restoreInstance)
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
