-- Modules/Quests.lua
-- Completion Navigator :: quest subsystem.
--
-- Roadmap position: automatic discovery, event-driven refresh, persistent
-- metadata and status, source-ranked metadata writes.

local ADDON_NAME, CN = ...

local Quests = CN:RegisterModule("Quests")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

CN.pendingQuestLoads = CN.pendingQuestLoads or {}

------------------------------------------------------------
-- COMPLETION STATE
------------------------------------------------------------

function Quests.IsCompletedByCharacter(questID)
    return Blizzard.IsQuestCompletedByCharacter(questID)
end

function Quests.IsCompletedOnAccount(questID)
    return Blizzard.IsQuestCompletedOnAccount(questID)
end

-- Kept for backwards compatibility with the single-file prototype.
CN.IsQuestCompletedByCharacter = Quests.IsCompletedByCharacter
CN.IsQuestCompletedOnAccount   = Quests.IsCompletedOnAccount

------------------------------------------------------------
-- METADATA
------------------------------------------------------------

-- Writes a name only when the incoming source is at least as
-- authoritative as the stored one. Manual entries never clobber Blizzard.
function Quests.SetMetadata(questID, name, source)
    if not questID or not name or name == "" then
        return false
    end

    local metadata = CN.Account("questMetadata")
    local existing = metadata[questID]

    source = source or "manual"

    if existing and existing.name and not CN.IsBetterSource(source, existing.source) then
        DebugPrint("Kept existing " .. tostring(existing.source)
            .. " name for quest " .. questID .. "; rejected " .. source .. ".")
        return false
    end

    metadata[questID] = {
        questID  = questID,
        name     = name,
        lastSeen = time(),
        source   = source,
    }

    return true
end

function Quests.GetMetadata(questID)
    return CN.Account("questMetadata")[questID]
end

-- Resolution order: cache -> live client -> static data -> async request.
function Quests.GetName(questID, requestIfMissing)
    if not questID then
        return nil
    end

    local cached = Quests.GetMetadata(questID)

    if cached and cached.name then
        return cached.name
    end

    local title = Blizzard.GetQuestTitle(questID, false)

    if title then
        Quests.SetMetadata(questID, title, "blizzard")
        return title
    end

    local static = CN.Static.GetQuestName(questID)

    if static then
        Quests.SetMetadata(questID, static, "static")
        return static
    end

    if requestIfMissing then
        Blizzard.GetQuestTitle(questID, true)
    end

    return nil
end

CN.GetQuestName = Quests.GetName

------------------------------------------------------------
-- DISCOVERY
------------------------------------------------------------

function Quests.RecordDiscovered(questID, source)
    questID = CN.ToID(questID)

    if not questID then
        return false
    end

    local discovered = CN.Account("discoveredQuests")
    local existing   = discovered[questID]

    discovered[questID] = {
        firstSeen = existing and existing.firstSeen or time(),
        lastSeen  = time(),
        source    = source or (existing and existing.source) or "manual",
    }

    if not existing then
        DebugPrint("Discovered quest " .. questID .. " (" .. tostring(source or "manual") .. ").")
    end

    return existing == nil
end

CN.RecordDiscoveredQuest = Quests.RecordDiscovered

-- Quests you could walk up to and accept right now, on one map.
--
-- These are the exclamation marks. Until 0.23.0 the addon could not see them
-- at all: it read the quest LOG, which by definition contains only quests you
-- have already taken. "What should I do next?" cannot be answered honestly
-- while the answer "pick up that quest twenty yards away" is invisible.
------------------------------------------------------------
-- LIFECYCLE PHASE
------------------------------------------------------------

-- A quest is not one place. It is three, in order:
--
--   PICKUP  -- the exclamation mark, where you accept it
--   ACTIVE  -- wherever its objectives actually are
--   TURNIN  -- the question mark, where you hand it back
--
-- Treating a quest as a single point is why an addon sends you back and forth:
-- it cannot tell that two quests share a giver, or that four you are carrying
-- all hand in at the same NPC. Naming the phase is what makes batching
-- possible at all.
CN.questPhases = {
    PICKUP = "PICKUP",
    ACTIVE = "ACTIVE",
    TURNIN = "TURNIN",
}

CN.questPhaseVerbs = {
    PICKUP = "pick up",
    ACTIVE = "work on",
    TURNIN = "turn in",
}

function Quests.Phase(questID)
    if not questID then
        return nil
    end

    if Blizzard.IsQuestReadyForTurnIn(questID) then
        return CN.questPhases.TURNIN
    end

    if Blizzard.IsQuestInLog(questID) then
        return CN.questPhases.ACTIVE
    end

    if Quests.IsCompletedByCharacter(questID) then
        return nil
    end

    return CN.questPhases.PICKUP
end

function Quests.PhaseVerb(phase)
    return CN.questPhaseVerbs[phase] or "do"
end

function Quests.AvailableOnMap(mapID)
    mapID = mapID or select(1, CN.GetPlayerPosition())

    if not mapID then
        return {}
    end

    local available = {}

    for _, poi in ipairs(Blizzard.GetQuestPOIsOnMap(mapID)) do
        -- A quest start you have not taken and have not already finished.
        if poi.isQuestStart
            and not poi.inProgress
            and not Blizzard.IsQuestInLog(poi.questID)
            and not Quests.IsCompletedByCharacter(poi.questID) then

            table.insert(available, poi)
        end
    end

    table.sort(available, function(a, b) return a.questID < b.questID end)

    return available
end

-- How many quests are on offer here that you have not taken.
--
-- This is the number a player means by "new", and it took a fourteen-year-old
-- to say so plainly. The addon used to report how many quests it had written
-- into its own database for the first time -- a scanner statistic, correct and
-- useless, which drops to zero forever once a zone has been walked. He read
-- "0 new" in a zone with exclamation marks visible on his screen and
-- concluded, reasonably, that the addon was broken.
--
-- A number shown to a player has to be about the player's world. If it is
-- about the addon's bookkeeping it belongs in debug output.
function Quests.AvailableCount(mapID)
    return #Quests.AvailableOnMap(mapID)
end

function Quests.DiscoverActive()
    local entries = Blizzard.GetQuestLogEntries()

    if #entries == 0 and not C_QuestLog then
        Print("Quest Log API is unavailable.")
        return 0, 0
    end

    local seen = 0
    local new  = 0

    for _, info in ipairs(entries) do
        if Quests.RecordDiscovered(info.questID, "questlog") then
            new = new + 1
        end

        if info.title and info.title ~= "" then
            Quests.SetMetadata(info.questID, info.title, "questlog")
        end

        seen = seen + 1
    end

    -- Quests offered in this zone but not yet accepted.
    --
    -- Without these, "new" settled at zero permanently after the first scan:
    -- the only thing being discovered was your own quest log, which stops
    -- changing the moment you have scanned it once.
    for _, poi in ipairs(Quests.AvailableOnMap()) do
        if Quests.RecordDiscovered(poi.questID, "available") then
            new = new + 1
        end

        local title = Blizzard.GetQuestTitle(poi.questID, true)

        if title and title ~= "" then
            Quests.SetMetadata(poi.questID, title, "available")
        end

        if poi.x and poi.y then
            Quests.SetLocation(poi.questID, poi.mapID, poi.x, poi.y, "available")
        end

        seen = seen + 1
    end

    return seen, new
end

------------------------------------------------------------
-- STATUS
------------------------------------------------------------

function Quests.RecordStatus(questID)
    local characterCompleted = Quests.IsCompletedByCharacter(questID)
    local accountCompleted   = Quests.IsCompletedOnAccount(questID)

    CN.Account("questStatus")[questID] = {
        characterCompleted = characterCompleted,
        accountCompleted   = accountCompleted,
        lastChecked        = time(),
    }

    return characterCompleted, accountCompleted
end

function Quests.ScanKnown()
    local scanned, byCharacter, onAccount = 0, 0, 0

    for questID in pairs(CN.Account("discoveredQuests")) do
        local characterCompleted, accountCompleted = Quests.RecordStatus(questID)

        scanned = scanned + 1

        if characterCompleted then
            byCharacter = byCharacter + 1
        end

        if accountCompleted then
            onAccount = onAccount + 1
        end
    end

    return scanned, byCharacter, onAccount
end

------------------------------------------------------------
-- ELIGIBILITY
------------------------------------------------------------

-- Curated static data first, then whatever external addons know, then
-- anything harvested from this account's own play. Static wins because it is
-- the only source this addon controls and ships.
function Quests.GetRecord(questID)
    local static = CN.Static.GetQuest(questID)

    if static and (static.requires or static.obsolete or static.requiresLevel) then
        return static, "static"
    end

    local external = CN.QueryQuestDataProviders(questID)

    if external and (external.requires or external.requiresLevel) then
        return external, table.concat(external.providers or { "external" }, "+")
    end

    local harvested = CN.Account("questHarvest")[questID]

    if harvested and harvested.requires then
        return harvested, "harvested"
    end

    return static, static and "static" or nil
end

CN.RegisterEligibilityChecker(CN.objectiveTypes.QUEST, function(questID)
    local states = CN.objectiveStates

    if Quests.IsCompletedByCharacter(questID) then
        return states.COMPLETED, "Already completed by this character", nil
    end

    local static = Quests.GetRecord(questID)

    if static then
        if static.obsolete then
            return states.UNOBTAINABLE, CN.blockReasons.OBSOLETE, nil
        end

        if static.requires then
            for _, prerequisiteID in ipairs(static.requires) do
                if not Quests.IsCompletedByCharacter(prerequisiteID) then
                    return states.LOCKED,
                           CN.blockReasons.PREREQUISITE_QUEST,
                           Quests.GetName(prerequisiteID) or ("quest " .. prerequisiteID)
                end
            end
        end



        if static.requiresLevel and UnitLevel("player") < static.requiresLevel then
            return states.LOCKED, CN.blockReasons.LEVEL_TOO_LOW, tostring(static.requiresLevel)
        end

        if static.requiresFaction and CN.character
            and CN.character.faction ~= static.requiresFaction then
            return states.INELIGIBLE, CN.blockReasons.WRONG_FACTION, static.requiresFaction
        end
    end

    -- Prerequisites nobody curated, inferred from repeated observation
    -- across characters.
    --
    -- Reported as LIKELY_PREREQUISITE, never as PREREQUISITE_QUEST. The
    -- addon has watched an ordering hold on several characters; that is
    -- strong evidence and it is still not the same claim as knowing. It
    -- must not be possible to mistake one for the other in the output.
    local dependency = CN.GetDependency(
        CN.ObjectiveKey(CN.objectiveTypes.QUEST, questID))

    if dependency and dependency.observedRequires then
        local harvest = CN:GetModule("Harvest")

        for _, prerequisiteID in ipairs(dependency.observedRequires) do
            if not Quests.IsCompletedByCharacter(prerequisiteID) then
                local characters = harvest
                    and harvest.Confidence(harvest.Store()[questID], prerequisiteID)
                    or 0

                return states.LOCKED,
                       CN.blockReasons.LIKELY_PREREQUISITE,
                       (Quests.GetName(prerequisiteID) or ("quest " .. prerequisiteID))
                           .. " (seen first on " .. characters .. " characters)"
            end
        end
    end

    return states.AVAILABLE, nil, nil
end)

------------------------------------------------------------
-- LOCATION
------------------------------------------------------------

-- Coordinates the player supplied by hand, for quests the client will not
-- answer for. Persisted account-wide: a location is a fact about the world,
-- not about one character.
local function Overrides()
    return CN.Account("questLocations")
end

Quests.Overrides = Overrides

function Quests.SetLocation(questID, mapID, x, y)
    if not questID or not mapID or not x or not y then
        return false
    end

    -- Accept either 0-1 or 0-100; the map API wants 0-1.
    if x > 1 then x = x / 100 end
    if y > 1 then y = y / 100 end

    if x <= 0 or x >= 1 or y <= 0 or y >= 1 then
        return false
    end

    Overrides()[questID] = {
        mapID = mapID,
        x     = x,
        y     = y,
        setAt = time(),
    }

    return true
end

function Quests.ClearLocation(questID)
    Overrides()[questID] = nil
end

-- Live client data first, then the player's own override, then curated
-- static data. Live wins because it tracks the quest's *current* step.
function Quests.GetLocation(questID)
    local mapID, x, y = Blizzard.GetQuestWaypoint(questID)

    if mapID and x and y then
        return mapID, x, y, "blizzard"
    end

    local override = Overrides()[questID]

    if override and override.mapID and override.x and override.y then
        return override.mapID, override.x, override.y, "manual"
    end

    local staticMap, staticX, staticY = CN.Static.GetQuestLocation(questID)

    if staticMap and staticX and staticY then
        return staticMap, staticX, staticY, "static"
    end

    return mapID or staticMap, nil, nil, nil
end

------------------------------------------------------------
-- CANDIDATES
------------------------------------------------------------

CN.RegisterCandidateProvider("Quests", function()
    local candidates = {}

    local playerMap, playerX, playerY = CN.GetPlayerPosition()

    local seen = {}

    local function add(questID, name, isActive, availablePOI)
        if not questID or seen[questID] then
            return
        end

        if CN.IsIgnored(CN.objectiveTypes.QUEST, questID)
            or CN.IsDeferred(CN.objectiveTypes.QUEST, questID) then
            return
        end

        seen[questID] = true

        local mapID, x, y, source = Quests.GetLocation(questID)

        local reasons = {}
        local value   = 1
        local travel  = 0

        -- An available quest carries its own pin, which is more current than
        -- anything recorded earlier.
        if availablePOI then
            mapID  = availablePOI.mapID or mapID
            x      = availablePOI.x or x
            y      = availablePOI.y or y
            source = "available"

            -- Weighted above an accepted quest you have not started: going to
            -- get a quest is cheap, it is right here, and it unlocks
            -- everything that quest leads to.
            value = value + 2

            table.insert(reasons, "available to pick up in this zone")

            if availablePOI.isDaily then
                table.insert(reasons, "daily")
            end
        end

        if isActive then
            if Blizzard.IsQuestReadyForTurnIn(questID) then
                value = value + 3
                table.insert(reasons, "ready to turn in")
            else
                local done, total = Blizzard.GetQuestObjectiveProgress(questID)

                if total > 0 and done > 0 then
                    value = value + 1
                    table.insert(reasons, done .. " of " .. total .. " objectives already done")
                end
            end
        end

        local static = CN.Static.GetQuest(questID)

        if static and static.unlocks and #static.unlocks > 0 then
            value = value + #static.unlocks
            table.insert(reasons, "unlocks " .. #static.unlocks .. " further quest(s)")
        end

        if mapID and playerMap then
            if mapID == playerMap then
                table.insert(reasons, "in your current zone")

                if x and y and playerX and playerY then
                    local dx = x - playerX
                    local dy = y - playerY

                    travel = math.sqrt((dx * dx) + (dy * dy)) * 10
                end
            else
                travel = 25
            end
        elseif not mapID then
            -- Unknown location: usable as a suggestion, useless for routing.
            travel = 5
        end

        table.insert(candidates, CN.NewObjective({
            id                = questID,
            type              = CN.objectiveTypes.QUEST,
            name              = name or Quests.GetName(questID) or ("Quest " .. questID),
            mapID             = mapID,
            x                 = x,
            y                 = y,
            source            = source,
            phase             = Quests.Phase(questID),
            state             = CN.objectiveStates.AVAILABLE,
            completionValue   = value,
            travelCost        = travel,
            reasons           = reasons,
        }))
    end

    for _, info in ipairs(Blizzard.GetQuestLogEntries()) do
        add(info.questID, info.title, true)
    end

    -- Quests standing in this zone waiting to be picked up.
    --
    -- This is the fix for the most basic possible complaint: the addon showed
    -- only quests you had already accepted, so it could never tell you to go
    -- and get one. Picking up a quest twenty yards away is often the single
    -- best next action available, and it was invisible.
    for _, poi in ipairs(Quests.AvailableOnMap(playerMap)) do
        local name = Quests.GetName(poi.questID)
            or Blizzard.GetQuestTitle(poi.questID, true)
            or ("Quest " .. poi.questID)

        add(poi.questID, name, false, poi)
    end

    -- Curated quests that are not in the log and not yet completed.
    for questID, record in pairs(CN.Static.quests) do
        if not record.obsolete and not Quests.IsCompletedByCharacter(questID) then
            local state = CN.Explain(CN.objectiveTypes.QUEST, questID)

            if state == CN.objectiveStates.AVAILABLE then
                add(questID, record.name, false)
            end
        end
    end

    return candidates
end, { events = { "QUEST_ACCEPTED", "QUEST_TURNED_IN", "QUEST_REMOVED", "QUEST_LOG_UPDATE", "ZONE_CHANGED_NEW_AREA" }, cooldown = 2 })

------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

CN:RegisterEvent("QUEST_DATA_LOAD_RESULT", function(event, questID, success)
    if not CN.pendingQuestLoads[questID] then
        return
    end

    CN.pendingQuestLoads[questID] = nil

    if not success then
        DebugPrint("Quest " .. tostring(questID) .. " metadata was unavailable from Blizzard.")
        return
    end

    local title = Blizzard.GetQuestTitle(questID, false)

    if title then
        Quests.SetMetadata(questID, title, "blizzard")
        Print("Quest " .. questID .. " - " .. title)
    else
        DebugPrint("Quest " .. questID .. " loaded, but no title was returned.")
    end
end)

CN:RegisterEvent("QUEST_ACCEPTED", function(event, questID)
    if not questID then
        return
    end

    Quests.RecordDiscovered(questID, "questlog")

    local title = Blizzard.GetQuestTitle(questID, true)

    if title then
        Quests.SetMetadata(questID, title, "questlog")
    end

    Quests.RecordStatus(questID)

    DebugPrint("Quest accepted: " .. questID)
end)

CN:RegisterEvent("QUEST_TURNED_IN", function(event, questID)
    if not questID then
        return
    end

    Quests.RecordDiscovered(questID, "questlog")
    Quests.RecordStatus(questID)

    DebugPrint("Quest turned in: " .. questID)
end)

CN:RegisterEvent("QUEST_REMOVED", function(event, questID)
    if not questID then
        return
    end

    Quests.RecordStatus(questID)

    DebugPrint("Quest removed from log: " .. questID)
end)

-- QUEST_LOG_UPDATE fires constantly; throttle a full rescan.
local lastLogScan = 0

CN:RegisterEvent("QUEST_LOG_UPDATE", function()
    local now = time()

    if now - lastLogScan < 10 then
        return
    end

    lastLogScan = now

    local seen, new = Quests.DiscoverActive()

    if new > 0 then
        DebugPrint("Quest Log scan discovered " .. new .. " new quests (" .. seen .. " active).")
    end
end)

CN:OnLogin(function()
    local seen, new = Quests.DiscoverActive()

    DebugPrint("Login quest scan: " .. seen .. " active, "
        .. new .. " newly recorded.")
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "quest",
    aliases = { "q" },
    args    = "<questID>",
    order   = 20,
    help    = "Check whether a quest is completed.",
    handler = function(args)
        local questID = CN.ToID(args)

        if not questID then
            Print("Usage: /cn quest <questID>")
            return
        end

        Quests.RecordDiscovered(questID, "manual")

        local characterCompleted, accountCompleted = Quests.RecordStatus(questID)

        local name = Quests.GetName(questID, true)

        if name then
            Print("Quest " .. questID .. " - " .. name .. ":")
        else
            Print("Quest " .. questID .. ":")
        end

        Print("Character completion: " .. CN.YesNo(characterCompleted))

        if Blizzard.HasAccountQuestAPI() then
            Print("Account/Warband completion: " .. CN.YesNo(accountCompleted))
        else
            Print("Account/Warband completion: |cffffff00API unavailable|r")
        end

        local state, reason, detail = CN.Explain(CN.objectiveTypes.QUEST, questID)

        Print("State: " .. state .. (reason and (" - " .. reason) or "")
            .. (detail and (" (" .. detail .. ")") or ""))
    end,
}

CN:RegisterCommand{
    name    = "cache",
    args    = "<questID>",
    order   = 21,
    help    = "Show cached quest metadata.",
    handler = function(args)
        local questID = CN.ToID(args)

        if not questID then
            Print("Usage: /cn cache <questID>")
            return
        end

        local cached = Quests.GetMetadata(questID)

        if cached and cached.name then
            Print("Cached quest " .. questID .. ": " .. cached.name
                .. " |cff999999[" .. tostring(cached.source) .. "]|r")
        else
            Print("No cached metadata for quest " .. questID .. ".")
        end
    end,
}

CN:RegisterCommand{
    name    = "setquest",
    args    = "<questID> <name>",
    order   = 22,
    help    = "Manually save quest metadata.",
    handler = function(args)
        local questIDText, name = args:match("^(%d+)%s+(.+)$")

        local questID = CN.ToID(questIDText)

        if not questID or not name or name == "" then
            Print("Usage: /cn setquest <questID> <name>")
            return
        end

        if Quests.SetMetadata(questID, name, "manual") then
            Print("Saved quest " .. questID .. ": " .. name)
        else
            Print("Kept the existing, more authoritative name for quest " .. questID .. ".")
        end
    end,
}

CN:RegisterCommand{
    name    = "queststatus",
    args    = "<questID>",
    order   = 23,
    help    = "Show the stored quest completion state.",
    handler = function(args)
        local questID = CN.ToID(args)

        if not questID then
            Print("Usage: /cn queststatus <questID>")
            return
        end

        local status = CN.Account("questStatus")[questID]

        if not status then
            Print("No stored quest status for quest " .. questID .. ".")
            return
        end

        Print("Stored quest " .. questID .. " status:")
        Print("Character completion: " .. CN.YesNo(status.characterCompleted))
        Print("Account/Warband completion: " .. CN.YesNo(status.accountCompleted))
        Print("Last checked: " .. date("%Y-%m-%d %H:%M", status.lastChecked or 0))
    end,
}

CN:RegisterCommand{
    name    = "scanquests",
    order   = 24,
    help    = "Scan known quest IDs for completion.",
    handler = function()
        local scanned, byCharacter, onAccount = Quests.ScanKnown()

        Print("Scanned " .. scanned .. " known quests.")
        Print("Character completed: " .. byCharacter)
        Print("Account/Warband completed: " .. onAccount)
    end,
}

CN:RegisterCommand{
    name    = "discovered",
    order   = 25,
    help    = "Show the number of discovered quests.",
    handler = function()
        Print("Discovered quests: " .. CN.CountKeys(CN.Account("discoveredQuests")))
        Print("Cached quest names: " .. CN.CountKeys(CN.Account("questMetadata")))
        Print("Stored quest statuses: " .. CN.CountKeys(CN.Account("questStatus")))
    end,
}

CN:RegisterCommand{
    name    = "available",
    aliases = { "pickup", "offered" },
    args    = "[zone name is not needed; uses the zone you are in]",
    order   = 13,
    help    = "List the quests offered here that you have not accepted.",
    handler = function()
        local mapID = select(1, CN.GetPlayerPosition())

        local available = Quests.AvailableOnMap(mapID)

        if #available == 0 then
            Print("Nothing here is offering you a quest you have not taken.")
            Print("|cff999999That counts quest starts the map is showing. A "
                .. "giver you have not walked past yet is not on the map, so "
                .. "it is not counted.|r")
            return
        end

        Print(#available .. " quest"
            .. (#available == 1 and "" or "s")
            .. " available to pick up here:")

        for _, poi in ipairs(available) do
            local title = Quests.GetName(poi.questID)
                or Blizzard.GetQuestTitle(poi.questID, true)
                or ("Quest " .. poi.questID)

            local where = ""

            if poi.x and poi.y then
                where = string.format(" |cff999999(%.1f, %.1f)|r",
                    poi.x * 100, poi.y * 100)
            end

            Print("  |cffffff00" .. title .. "|r" .. where)
        end

        Print("|cff999999These are in your recommendations and in |r/cn zone"
            .. "|cff999999 too.|r")
    end,
}

CN:RegisterCommand{
    name    = "discoveractive",
    order   = 26,
    help    = "Discover quests currently in the Quest Log.",
    handler = function()
        local seen, recorded = Quests.DiscoverActive()

        local available = Quests.AvailableCount()

        Print("Quests: " .. seen .. " in your log, "
            .. "|cffffff00" .. available .. "|r available to pick up here.")

        DebugPrint(recorded .. " newly recorded in the database.")
    end,
}

CN:RegisterCommand{
    name    = "where",
    args    = "<questID>",
    order   = 28,
    help    = "Show what location is known for a quest.",
    handler = function(args)
        local questID = CN.ToID(args)

        if not questID then
            Print("Usage: /cn where <questID>")
            return
        end

        local mapID, x, y, source = Quests.GetLocation(questID)

        Print("Quest " .. questID .. " - "
            .. (Quests.GetName(questID, true) or "unknown name"))

        if mapID and x and y then
            Print(string.format("Location: map %d at %.1f, %.1f |cff999999[%s]|r",
                mapID, x * 100, y * 100, tostring(source)))
        elseif mapID then
            Print("Map " .. mapID .. " |cffffff00(no coordinates)|r")
        else
            Print("|cffff4444No location is known.|r")
        end

        Print("In your quest log: " .. CN.YesNo(Blizzard.IsQuestInLog(questID)))
    end,
}

CN:RegisterCommand{
    name    = "setloc",
    args    = "<questID> <mapID> <x> <y>",
    order   = 29,
    help    = "Record coordinates for a quest by hand.",
    handler = function(args)
        local questID, mapID, x, y =
            args:match("^(%d+)%s+(%d+)%s+([%d%.]+)%s+([%d%.]+)$")

        questID = CN.ToID(questID)
        mapID   = CN.ToID(mapID)
        x       = tonumber(x)
        y       = tonumber(y)

        if not questID or not mapID or not x or not y then
            Print("Usage: /cn setloc <questID> <mapID> <x> <y>")
            Print("Coordinates may be 0-1 or 0-100. Find the map ID with "
                .. "|cffffff00/cn where|r or /dump C_Map.GetBestMapForUnit(\"player\")")
            return
        end

        if Quests.SetLocation(questID, mapID, x, y) then
            Print("Saved location for quest " .. questID .. ".")
        else
            Print("Those coordinates are out of range.")
        end
    end,
}

CN:RegisterCommand{
    name    = "why",
    args    = "<questID>",
    order   = 27,
    help    = "Explain why a quest is not available.",
    handler = function(args)
        local questID = CN.ToID(args)

        if not questID then
            Print("Usage: /cn why <questID>")
            return
        end

        local state, reason, detail = CN.Explain(CN.objectiveTypes.QUEST, questID)

        Print("Quest " .. questID .. " - " .. (Quests.GetName(questID, true) or "unknown name"))
        Print("State: " .. state)

        if reason then
            Print("Reason: " .. reason .. (detail and (" (" .. detail .. ")") or ""))
        end

        local record, source = Quests.GetRecord(questID)

        if record and source then
            Print("Data source: |cff999999" .. source .. "|r")
        else
            Print("|cff999999No prerequisite data for this quest. "
                .. "Install AllTheThings or BtWQuests, or add a row with /cn setloc.|r")
        end
    end,
}

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
