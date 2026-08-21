-- Providers/Blizzard.lua
-- Completion Navigator :: thin, defensive wrappers over Blizzard APIs.
--
-- Every call into the client goes through this FILE SET. Blizzard renames and
-- removes APIs between patches; keeping the surface area together means a
-- patch break is a contained fix rather than a hunt through the addon.
--
-- Split into three in 0.45.0, at 2,250 lines, when "keep it in one file"
-- stopped meaning "easy to find" and started meaning "search, do not scroll":
--
--   Blizzard.lua             quests, reputation, character, map
--   BlizzardCollections.lua  pets, mounts, toys, appearances, titles
--   BlizzardWorld.lua        professions, the vault, currencies, instances
--
-- Divided by what the client is asked ABOUT, because that is also how patches
-- break things -- a collections patch breaks collection APIs. `CN.Blizzard`
-- remains a single table; only the source is divided.

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

    -- pcall'd like every other call in this file set. This one was neither
    -- existence-checked nor protected, in a file whose header promises that
    -- "every call into the client goes through this FILE SET" precisely so a
    -- patch break is a contained fix rather than a broken quest log.
    for index = 1, count do
        local gotInfo, info = pcall(C_QuestLog.GetInfo, index)

        if gotInfo and info and not info.isHeader
            and info.questID and info.questID > 0 then
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

-- Objectives that are COUNTING something, with where they stand.
--
-- "3/12 Sunscale Feathers" is a different piece of advice from "not started"
-- and from "finished", and the addon has only ever known the middle one
-- existed in aggregate. Returns an array of:
--   { text, type, done, required, remaining, finished }
function Blizzard.GetCountingObjectives(questID)
    local rows = {}

    if not C_QuestLog or not C_QuestLog.GetQuestObjectives then
        return rows
    end

    local ok, objectives = pcall(C_QuestLog.GetQuestObjectives, questID)

    if not ok or type(objectives) ~= "table" then
        return rows
    end

    for _, objective in ipairs(objectives) do
        local required = objective.numRequired or 0

        if required > 1 then
            local done = objective.numFulfilled or 0

            table.insert(rows, {
                text      = objective.text,
                type      = objective.type,
                done      = done,
                required  = required,
                remaining = math.max(0, required - done),
                finished  = objective.finished and true or false,
            })
        end
    end

    return rows
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
