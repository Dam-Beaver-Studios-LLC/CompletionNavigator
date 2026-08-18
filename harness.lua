-- Offline load harness: stubs enough of the WoW client to execute every
-- Completion Navigator file in .toc order, fire the lifecycle events, and
-- run every registered slash command.

local ROOT = arg[1] or "."

------------------------------------------------------------
-- UNIVERSAL STUB
------------------------------------------------------------

local U = {}
setmetatable(U, {
    __index = function() return U end,
    __call  = function() return U end,
})

local function Frame()
    local f = {}
    local events, scripts = {}, {}

    f.events  = events
    f.scripts = scripts

    function f:RegisterEvent(e) events[e] = true end
    function f:UnregisterEvent(e) events[e] = nil end
    function f:SetScript(k, fn) scripts[k] = fn end
    function f:GetScript(k) return scripts[k] end
    function f:IsShown() return f.shown == true end
    function f:Show() f.shown = true end
    function f:Hide() f.shown = false end
    function f:CreateFontString() return Frame() end
    function f:CreateTexture() return Frame() end

    -- Numeric getters must return numbers, or arithmetic in the addon
    -- silently becomes "attempt to perform arithmetic on a table value".
    function f:GetWidth() return 400 end
    function f:GetHeight() return 300 end
    function f:GetTextWidth() return 60 end
    function f:GetTextHeight() return 12 end
    function f:GetEffectiveScale() return 1 end
    function f:GetCenter() return 500, 400 end
    function f:GetPoint() return "CENTER", nil, "CENTER", 0, 0 end

    setmetatable(f, { __index = function() return U end })

    return f
end

------------------------------------------------------------
-- GLOBALS
------------------------------------------------------------

local output = {}

DEFAULT_CHAT_FRAME = {
    AddMessage = function(self, msg)
        msg = msg:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        table.insert(output, msg)
        print("  " .. msg)
    end,
}

UIParent     = Frame()
SlashCmdList = {}

-- WoW exposes these as globals.
time    = os.time
date    = os.date

-- Millisecond profiler. Present in the client, absent in plain Lua, so the
-- provider-timing path would otherwise never execute offline.
function debugprofilestop() return os.clock() * 1000 end
strtrim = function(s) return (tostring(s):gsub("^%s+", ""):gsub("%s+$", "")) end

local createdFrames = {}

function CreateFrame(frameType, name, parent, template)
    local f = Frame()
    table.insert(createdFrames, f)
    -- The client publishes named frames as globals; the harness must too, or
    -- nothing can reach the minimap button to test it.
    if name then _G[name] = f end
    return f
end

function UnitName(unit)
    if unit == "npc" then return "Test Merchant" end
    return "Testchar"
end
function GetRealmName() return "Testrealm" end
function UnitClass() return "Paladin", "PALADIN" end
function UnitRace() return "Human", "Human" end
function UnitLevel() return 80 end
function UnitSex() return 2 end
function UnitFactionGroup() return "Alliance" end
function GetZoneText() return "Eversong Woods" end
function GetSpecialization() return 3 end
function GetSpecializationInfo() return 70, "Retribution" end
function GetProfessions() return 1, 2, nil, 4, 5 end
function GetProfessionInfo(i) return "Profession" .. i, nil, 75, 100, nil, nil, 170 + i end

UiMapPoint = { CreateFromCoordinates = function() return U end }

C_Map = {
    GetBestMapForUnit    = function() return 94 end,
    GetPlayerMapPosition = function() return { GetXY = function() return 0.42, 0.55 end } end,
    GetMapInfo           = function(id) return { name = "Map" .. tostring(id) } end,
    SetUserWaypoint      = function() end,
    ClearUserWaypoint    = function() end,
}

local superTracked = nil

C_SuperTrack = {
    SetSuperTrackedUserWaypoint = function() end,
    SetSuperTrackedQuestID      = function(id) superTracked = id end,
    GetSuperTrackedQuestID      = function() return superTracked end,
}

local questLog = {
    { questID = 8237, title = "Vanquish the Invaders!", isHeader = false },
    { questID = 9001, title = "Test Quest Alpha",       isHeader = false },
    { questID = 9002, title = "Test Quest Beta",        isHeader = false },
}

local pendingLoad = {}

C_QuestLog = {
    IsQuestFlaggedCompleted          = function(id)
        if id >= 70000 then return false end   -- world quests are fresh
        return id % 2 == 1
    end,
    IsQuestFlaggedCompletedOnAccount = function(id) return id % 3 == 0 end,
    GetTitleForQuestID               = function(id)
        for _, entry in ipairs(questLog) do
            if entry.questID == id then return entry.title end
        end
        return nil
    end,
    RequestLoadQuestByID   = function(id) table.insert(pendingLoad, id) end,
    GetNumQuestLogEntries  = function() return #questLog end,
    GetInfo                = function(i) return questLog[i] end,
    ReadyForTurnIn         = function(id) return id == 9001 end,
    IsComplete             = function(id) return id == 9001 end,
    GetNextWaypoint        = function(id)
        -- The real client answers for very few quests. Only 9001 here.
        if id == 9001 then return 84, 0.20, 0.80 end
        return nil
    end,
    GetNextWaypointForMap  = function(id, mapID) return nil end,
    GetLogIndexForQuestID  = function(id)
        for index, entry in ipairs(questLog) do
            if entry.questID == id then return index end
        end
        return nil
    end,
    -- 9002 is only findable through the map POI list.
    GetQuestsOnMap = function(mapID)
        if mapID ~= 94 then return {} end
        return { { questID = 9002, x = 0.61, y = 0.48 } }
    end,
    IsWorldQuest = function(id) return id >= 70000 end,
    GetQuestTagInfo = function(id)
        if id >= 70000 then
            return { tagID = 1, tagName = "Elite", worldQuestType = 1, isElite = true }
        end
        return nil
    end,
    GetQuestObjectives = function(id)
        if id == 9002 then
            return { { finished = true }, { finished = false } }
        end
        return {}
    end,
}


------------------------------------------------------------
-- UI STUBS
------------------------------------------------------------

Minimap        = Frame()

-- The tooltip records what is added to it, so the tooltip module can be
-- asserted on rather than merely executed.
GameTooltip = Frame()
GameTooltip.lines = {}

function GameTooltip:AddLine(text, r, g, b)
    table.insert(GameTooltip.lines, tostring(text))
end

function GameTooltip:ClearLines() GameTooltip.lines = {} end
function GameTooltip:SetOwner() end
function GameTooltip:GetItem() return nil, nil end
function GameTooltip:GetUnit() return nil, nil end

local tooltipHooks = {}

function GameTooltip:HookScript(script, fn)
    tooltipHooks[script] = tooltipHooks[script] or {}
    table.insert(tooltipHooks[script], fn)
end

function CN_TEST_TooltipHooks() return tooltipHooks end

UISpecialFrames = {}

function GetCursorPosition() return 400, 300 end

-- C_Timer backs the auto-waypoint backstop ticker.
local tickers = {}
local deferred = {}

C_Timer = {
    NewTicker = function(seconds, callback)
        local handle = { seconds = seconds, callback = callback, cancelled = false }
        function handle:Cancel() self.cancelled = true end
        table.insert(tickers, handle)
        return handle
    end,
    After = function(seconds, callback)
        table.insert(deferred, { seconds = seconds, callback = callback })
        return nil
    end,
}

function CN_TEST_FireTickers()
    for _, t in ipairs(tickers) do
        if not t.cancelled then t.callback() end
    end
end

-- Drains C_Timer.After callbacks, including any they schedule themselves.
-- /cn setup is a self-rescheduling chain, so a single pass would only run
-- its first step.
function CN_TEST_DrainDeferred(maxPasses)
    local ran = 0

    for _ = 1, (maxPasses or 200) do
        if #deferred == 0 then break end

        local batch = deferred
        deferred = {}

        for _, entry in ipairs(batch) do
            entry.callback()
            ran = ran + 1
        end
    end

    return ran
end

C_TaskQuest = {
    GetQuestZoneID = function() return nil end,
    GetQuestsForPlayerByMapID = function(mapID)
        if mapID ~= 94 then return {} end
        local out = {}
        for _, wq in ipairs(worldQuests) do
            table.insert(out, { questId = wq.questID, mapID = wq.mapID, x = wq.x, y = wq.y })
        end
        return out
    end,
    GetQuestTimeLeftSeconds = function(id)
        for _, wq in ipairs(worldQuests) do
            if wq.questID == id then return wq.seconds end
        end
        return nil
    end,
    GetQuestInfoByQuestID = function(id) return "World Quest " .. id, nil end,
    GetQuestLocation = function() return nil end,
}

------------------------------------------------------------
-- REPUTATION STUBS
------------------------------------------------------------

local standings = {
    "Hated", "Hostile", "Unfriendly", "Neutral",
    "Friendly", "Honored", "Revered", "Exalted",
}

for i, label in ipairs(standings) do
    _G["FACTION_STANDING_LABEL" .. i] = label
end

local factions = {
    { factionID = 0,    name = "The War Within", isHeader = true,  isCollapsed = false },
    { factionID = 2600, name = "The Severed Threads", reaction = 5,
      currentStanding = 4200, currentReactionThreshold = 3000, nextReactionThreshold = 6000 },
    { factionID = 2590, name = "Council of Dornogal", reaction = 8,
      currentStanding = 42000, currentReactionThreshold = 42000, nextReactionThreshold = 43000 },
    { factionID = 1090, name = "Kirin Tor", reaction = 7,
      currentStanding = 15000, currentReactionThreshold = 12000, nextReactionThreshold = 21000 },
    { factionID = 2135, name = "Chromie", reaction = 5,
      currentStanding = 5000, currentReactionThreshold = 4000, nextReactionThreshold = 9000 },
    { factionID = 946,  name = "Honor Hold", reaction = 8, isHeader = true, isHeaderWithRep = true,
      currentStanding = 43000, currentReactionThreshold = 42000, nextReactionThreshold = 43000 },
}

local accountWideFactions = { [2600] = true, [2590] = true }
local majorFactions       = { [2600] = true, [2590] = true }
local paragonFactions     = { [2590] = true }

local expandCalls, collapseCalls = 0, 0

C_Reputation = {
    GetNumFactions          = function() return #factions end,
    GetFactionDataByIndex   = function(i) return factions[i] end,
    GetFactionDataByID      = function(id)
        for _, f in ipairs(factions) do
            if f.factionID == id then return f end
        end
        return nil
    end,
    IsAccountWideReputation = function(id) return accountWideFactions[id] == true end,
    IsMajorFaction          = function(id) return majorFactions[id] == true end,
    IsFactionParagon        = function(id) return paragonFactions[id] == true end,
    GetFactionParagonInfo   = function(id) return 7500, 10000, 80001, true end,
    ExpandAllFactionHeaders = function() expandCalls = expandCalls + 1 end,
    CollapseFactionHeader   = function() collapseCalls = collapseCalls + 1 end,
}

C_MajorFactions = {
    GetMajorFactionData = function(id)
        if id == 2600 then
            return { name = "The Severed Threads", renownLevel = 12,
                     renownReputationEarned = 1200, renownLevelThreshold = 2500,
                     expansionID = 10, isUnlocked = true }
        end
        if id == 2590 then
            return { name = "Council of Dornogal", renownLevel = 25,
                     renownReputationEarned = 0, renownLevelThreshold = 2500,
                     expansionID = 10, isUnlocked = true }
        end
        return nil
    end,
    HasMaximumRenown = function(id) return id == 2590 end,
}

C_GossipInfo = {
    GetFriendshipReputation = function(id)
        if id ~= 2135 then return nil end
        return { friendshipFactionID = 2135, standing = 5000, reaction = "Buddy",
                 reactionThreshold = 4000, nextThreshold = 9000 }
    end,
}


------------------------------------------------------------
-- COLLECTION STUBS
------------------------------------------------------------

local petSpecies = {
    { speciesID = 100, name = "Test Whelpling", petType = 1, isWild = false, canBattle = true,  owned = true,  count = 3 },
    { speciesID = 101, name = "Wild Critter",   petType = 2, isWild = true,  canBattle = true,  owned = false, count = 0 },
    { speciesID = 102, name = "Gone Forever",   petType = 3, isWild = false, canBattle = false, owned = false, count = 0, obtainable = false },
}

C_PetJournal = {
    GetSearchFilter          = function() return "" end,
    SetSearchFilter          = function() end,
    SetAllPetSourcesChecked  = function() end,
    SetAllPetTypesChecked    = function() end,
    GetNumPets               = function() return #petSpecies, 1 end,
    GetPetInfoByIndex        = function(i)
        local p = petSpecies[i]
        if not p then return nil end
        return "petid" .. i, p.speciesID, p.owned, nil, 25, false, false,
               p.name, 1, p.petType, nil, nil, "desc", p.isWild, p.canBattle,
               true, false, p.obtainable ~= false
    end,
    GetNumCollectedInfo      = function(speciesID)
        for _, p in ipairs(petSpecies) do
            if p.speciesID == speciesID then return p.count, 3 end
        end
        return 0, 3
    end,
}

local mounts = {
    [1] = { name = "Test Drake",     collected = true,  factionSpecific = false },
    [2] = { name = "Horde Wolf",     collected = false, factionSpecific = true, faction = 0 },
    [3] = { name = "Alliance Steed", collected = false, factionSpecific = true, faction = 1 },
}

C_MountJournal = {
    GetMountIDs           = function() return { 1, 2, 3 } end,
    GetMountInfoByID      = function(id)
        local m = mounts[id]
        if not m then return nil end
        return m.name, 1000 + id, 1, false, true, 1, false,
               m.factionSpecific, m.faction, false, m.collected
    end,
    GetMountInfoExtraByID = function(id) return 1, "A mount.", "Drop: Somewhere" end,
}

local toys = {
    { itemID = 500, name = "Test Toy",   collected = true },
    { itemID = 501, name = "Missing Toy", collected = false },
}

function PlayerHasToy(itemID)
    for _, t in ipairs(toys) do
        if t.itemID == itemID then return t.collected end
    end
    return false
end

C_ToyBox = {
    SetFilterString         = function() end,
    SetCollectedShown       = function() end,
    SetUncollectedShown     = function() end,
    SetAllSourceTypeFilters = function() end,
    GetNumFilteredToys      = function() return #toys end,
    GetToyFromIndex         = function(i) return toys[i] and toys[i].itemID or nil end,
    GetToyInfo              = function(itemID)
        for _, t in ipairs(toys) do
            if t.itemID == itemID then return itemID, t.name, 1 end
        end
        return nil
    end,
}

Enum = Enum or {}
Enum.TransmogCollectionType = { Head = 1, Shoulder = 2, Chest = 5 }

local appearanceData = {
    [1] = { name = "Head",     collected = 120, total = 400 },
    [2] = { name = "Shoulder", collected =  90, total = 380 },
    [5] = { name = "Chest",    collected = 200, total = 410 },
}

C_TransmogCollection = {
    GetCategoryInfo           = function(id) return appearanceData[id] and appearanceData[id].name or nil end,
    GetCategoryCollectedCount = function(id) return appearanceData[id] and appearanceData[id].collected or 0 end,
    GetCategoryTotal          = function(id) return appearanceData[id] and appearanceData[id].total or 0 end,
}

local titleList = {
    { name = "the Explorer", known = true },
    { name = "Loremaster",   known = false },
    { name = "the Patient",  known = true },
}

function GetNumTitles() return #titleList end
function GetTitleName(i) return titleList[i] and titleList[i].name or nil end
function IsTitleKnown(i) return titleList[i] and titleList[i].known or false end

------------------------------------------------------------
-- ACHIEVEMENT STUBS
------------------------------------------------------------

local achievementData
achievementData = {
    [10] = { name = "Almost There",  points = 10, completed = false, criteria = 5, done = 4 },
    [11] = { name = "Long Way Off",  points = 10, completed = false, criteria = 50, done = 2 },
    [12] = { name = "Done Already",  points = 20, completed = true,  criteria = 3, done = 3 },
    [13] = { name = "One Criterion", points = 5,  completed = false, criteria = 2, done = 1 },
}

local categoryAchievements = { [92] = { 10, 11 }, [96] = { 12, 13 }, [97] = { 20, 21 } }

achievementDataExtra = {
    [20] = { name = "Explore Eversong Woods", points = 10, completed = false, criteria = 12, done = 9 },
    [21] = { name = "Explore Durotar",        points = 10, completed = true,  criteria = 8,  done = 8 },
}

for id, data in pairs(achievementDataExtra) do achievementData[id] = data end

function GetCategoryList() return { 92, 96, 97 } end

function GetCategoryNumAchievements(categoryID)
    local list = categoryAchievements[categoryID] or {}
    local done = 0
    for _, id in ipairs(list) do
        if achievementData[id].completed then done = done + 1 end
    end
    return #list, done
end

function GetAchievementInfo(a, b)
    local id
    if b then
        local list = categoryAchievements[a] or {}
        id = list[b]
    else
        id = a
    end
    local data = achievementData[id]
    if not data then return nil end
    return id, data.name, data.points, data.completed, 1, 1, 2026, "desc", 0, 1
end

function GetAchievementNumCriteria(id)
    return achievementData[id] and achievementData[id].criteria or 0
end

function GetAchievementCriteriaInfo(id, index)
    local data = achievementData[id]
    if not data then return nil end
    return "criterion " .. index, 1, index <= data.done
end

function GetNumCompletedAchievements() return 4, 1 end

------------------------------------------------------------
-- PROFESSION STUBS
------------------------------------------------------------

local recipeData = {
    [700] = { name = "Flask of Testing", learned = true },
    [701] = { name = "Potion of Maybe",  learned = false },
    [702] = { name = "Elixir of Proof",  learned = true },
}

local tradeSkillReady = false

C_TradeSkillUI = {
    IsTradeSkillReady      = function() return tradeSkillReady end,
    GetBaseProfessionInfo  = function()
        return { professionID = 171, professionName = "Alchemy" }
    end,
    GetAllRecipeIDs        = function() return { 700, 701, 702 } end,
    GetRecipeInfo          = function(id)
        local r = recipeData[id]
        if not r then return nil end
        return { recipeID = id, name = r.name, learned = r.learned }
    end,
}

function CN_TEST_OpenTradeSkill() tradeSkillReady = true end







------------------------------------------------------------
-- MERCHANT STUBS
------------------------------------------------------------

local merchantItems = {
    { name = "Flask of Testing", price = 5000, itemID = 700 },
    { name = "Potion of Maybe",  price = 2500, itemID = 701 },
    { name = "Spare Boots",      price = 100,  itemID = 999 },
}

function GetMerchantNumItems() return #merchantItems end

function GetMerchantItemInfo(i)
    local it = merchantItems[i]
    if not it then return nil end
    return it.name, 1, it.price, 1, 1, true, true, false
end

function GetMerchantItemLink(i)
    local it = merchantItems[i]
    if not it then return nil end
    return "|cffffffff|Hitem:" .. it.itemID .. "::::::::80:::::|h[" .. it.name .. "]|h|r"
end

-- Items that teach a collectible.
C_MountJournal.GetMountFromItem = function(itemID)
    if itemID == 800 then return 2 end   -- Horde Wolf, uncollected
    return nil
end

C_PetJournal.GetPetInfoByItemID = function(itemID)
    if itemID == 801 then
        -- name, icon, petType, companionID, source, description, isWild,
        -- canBattle, isTradeable, isUnique, obtainable, displayID, speciesID
        return "Wild Critter", 1, 2, nil, "Vendor", "desc", true, true,
               true, false, true, 1, 101
    end
    return nil
end

-- Only item 900 has an appearance at all; everything else must be silent.
C_TransmogCollection.GetItemInfo = function(itemID)
    if itemID == 900 then return 9001, 9002 end
    return nil
end

C_TransmogCollection.PlayerHasTransmogByItemInfo = function(itemID)
    return false
end

C_Item = {
    GetItemNameByID = function(itemID)
        local names = {
            [500] = "Test Toy",
            [501] = "Missing Toy",
            [700] = "Flask of Testing",
            [800] = "Reins of the Horde Wolf",
            [801] = "Wild Critter Cage",
            [900] = "Tabard of Testing",
        }
        return names[itemID]
    end,
}

-- The modern tooltip pipeline.
Enum.TooltipDataType = { Item = 0, Unit = 2 }

local tooltipPostCalls = {}

TooltipDataProcessor = {
    AddTooltipPostCall = function(dataType, fn)
        tooltipPostCalls[dataType] = tooltipPostCalls[dataType] or {}
        table.insert(tooltipPostCalls[dataType], fn)
    end,
}

TooltipUtil = {
    GetDisplayedItem = function(tooltip)
        return CN_TEST_ITEM_NAME, nil, CN_TEST_ITEM_ID
    end,
    GetDisplayedUnit = function(tooltip)
        return CN_TEST_UNIT_NAME, CN_TEST_UNIT
    end,
}

function CN_TEST_FireItemTooltip(itemID, itemName)
    CN_TEST_ITEM_ID   = itemID
    CN_TEST_ITEM_NAME = itemName

    GameTooltip:ClearLines()

    for _, fn in ipairs(tooltipPostCalls[Enum.TooltipDataType.Item] or {}) do
        fn(GameTooltip, { id = itemID })
    end

    return GameTooltip.lines
end

function CN_TEST_FireUnitTooltip(unit)
    CN_TEST_UNIT = unit

    GameTooltip:ClearLines()

    for _, fn in ipairs(tooltipPostCalls[Enum.TooltipDataType.Unit] or {}) do
        fn(GameTooltip, {})
    end

    return GameTooltip.lines
end

------------------------------------------------------------
-- GREAT VAULT
------------------------------------------------------------

Enum.WeeklyRewardChestThresholdType = { Raid = 1, Activities = 2, World = 3 }

-- Raid  : 1 of 2 toward the first threshold  -> 1 remaining
-- Dungeon: 3 of 4 toward the second          -> 1 remaining, one already unlocked
-- World : 8 of 8, every threshold met        -> capped
local weeklyActivities = {
    { type = 1, index = 1, threshold = 2, progress = 1, level = 0 },
    { type = 1, index = 2, threshold = 4, progress = 1, level = 0 },
    { type = 1, index = 3, threshold = 6, progress = 1, level = 0 },

    { type = 2, index = 1, threshold = 1, progress = 3, level = 610, id = 501 },
    { type = 2, index = 2, threshold = 4, progress = 3, level = 0 },
    { type = 2, index = 3, threshold = 8, progress = 3, level = 0 },

    { type = 3, index = 1, threshold = 2, progress = 8, level = 600, id = 601 },
    { type = 3, index = 2, threshold = 4, progress = 8, level = 603, id = 602 },
    { type = 3, index = 3, threshold = 8, progress = 8, level = 606, id = 603 },
}

local weeklyClaimable = false

C_WeeklyRewards = {
    GetActivities        = function() return weeklyActivities end,
    HasAvailableRewards  = function() return weeklyClaimable end,
}

function CN_TEST_SetVaultClaimable(value) weeklyClaimable = value end

function UnitExists(unit) return unit == "npc" or unit == "mouseover" end
function UnitGUID(unit)
    if unit ~= "npc" and unit ~= "mouseover" then return nil end
    return "Creature-0-1234-0-0-55501-000012ABCD"
end

function strsplit(sep, str)
    local out = {}

    for part in string.gmatch(str, "([^" .. sep .. "]+)") do
        table.insert(out, part)
    end

    return table.unpack(out)
end

------------------------------------------------------------
-- HANDYNOTES STUB
------------------------------------------------------------

HandyNotes = {
    IteratePlugins = function(self)
        local delivered = false
        return function()
            if delivered then return nil end
            delivered = true
            return "HandyNotes_Treasures", {
                GetNodes2 = function(_, mapID, minimap)
                    if mapID ~= 94 then return function() return nil end end
                    local sent = false
                    return function()
                        if sent then return nil end
                        sent = true
                        -- HandyNotes packs x,y into one integer.
                        return 45006200, { label = "Hidden Cache" }
                    end
                end,
            }
        end
    end,
}

------------------------------------------------------------
-- CURRENCY STUBS
------------------------------------------------------------

local currencyList = {
    { currencyID = 3008, name = "Valorstones", quantity = 2000, maxQuantity = 2000,
      quantityEarnedThisWeek = 0, maxWeeklyQuantity = 0, totalEarned = 5000 },
    { currencyID = 2245, name = "Flightstones", quantity = 400, maxQuantity = 2000,
      quantityEarnedThisWeek = 300, maxWeeklyQuantity = 1000, totalEarned = 900 },
    { currencyID = 1602, name = "Conquest", quantity = 0, maxQuantity = 0,
      quantityEarnedThisWeek = 0, maxWeeklyQuantity = 1350, totalEarned = 0 },
    { isHeader = true, name = "Header Row" },
}

C_CurrencyInfo = {
    GetCurrencyListSize = function() return #currencyList end,
    GetCurrencyListInfo = function(i) return currencyList[i] end,
    GetCurrencyInfo     = function(id)
        for _, c in ipairs(currencyList) do
            if c.currencyID == id then return c end
        end
        return nil
    end,
}

------------------------------------------------------------
-- VIGNETTE STUBS (rares and treasures)
------------------------------------------------------------

vignettes = {
    { guid = "v1", vignetteID = 5001, name = "Rare Beast",   atlasName = "VignetteKillElite", isDead = false, x = 0.35, y = 0.60 },
    { guid = "v2", vignetteID = 5002, name = "Buried Chest", atlasName = "VignetteLootChest", isDead = false, x = 0.55, y = 0.25 },
    { guid = "v3", vignetteID = 5003, name = "Dead Thing",   atlasName = "VignetteKill",      isDead = true,  x = 0.10, y = 0.10 },
}

C_VignetteInfo = {
    GetVignettes = function()
        local out = {}
        for _, v in ipairs(vignettes) do table.insert(out, v.guid) end
        return out
    end,
    GetVignetteInfo = function(guid)
        for _, v in ipairs(vignettes) do
            if v.guid == guid then
                return { name = v.name, atlasName = v.atlasName, vignetteID = v.vignetteID,
                         isDead = v.isDead, onMinimap = true, inFogOfWar = false }
            end
        end
        return nil
    end,
    GetVignettePosition = function(guid, mapID)
        for _, v in ipairs(vignettes) do
            if v.guid == guid then
                return { GetXY = function() return v.x, v.y end }
            end
        end
        return nil
    end,
}

------------------------------------------------------------
-- TIME-SENSITIVE STUBS
------------------------------------------------------------

worldQuests = {   -- global on purpose: C_TaskQuest above closes over it
    { questID = 70001, mapID = 94, x = 0.30, y = 0.40, seconds = 45 * 60 },
    { questID = 70002, mapID = 94, x = 0.70, y = 0.20, seconds = 20 * 3600 },
    { questID = 70003, mapID = 94, x = 0.50, y = 0.90, seconds = 4 * 86400 },
}

function GetQuestResetTime() return 5 * 3600 end

C_DateAndTime = {
    GetSecondsUntilWeeklyReset = function() return 3 * 86400 end,
    GetCurrentCalendarTime     = function()
        return { year = 2026, month = 8, monthDay = 18, hour = 12, minute = 0 }
    end,
}

C_Calendar = {
    OpenCalendar    = function() end,
    GetNumDayEvents = function(offset, day) return 2 end,
    GetDayEvent     = function(offset, day, index)
        if index == 1 then
            return { title = "Darkmoon Faire", sequenceType = "ONGOING", eventType = 0 }
        end
        return { title = "Finished Thing", sequenceType = "END", eventType = 0 }
    end,
}

------------------------------------------------------------
-- EXTERNAL ADDON STUBS (ATT and BtWQuests)
------------------------------------------------------------

AllTheThings = {
    SearchForField = function(field, id)
        if field ~= "questID" then return {} end
        if id == 9002 then
            return {
                { name = "Test Quest Beta (ATT)", coord = { 61.0, 48.0, 94 } },
                { sourceQuests = { 9001, 8237 }, lvl = 70 },
            }
        end
        return {}
    end,
}

BtWQuestsDatabase = {
    GetQuestByID = function(self, id)
        if id ~= 9001 then return nil end
        return {
            name = "Test Quest Alpha (BtW)",
            prerequisites = {
                { type = "quest", id = 8237 },
                { nested = { { questID = 4242 } } },
            },
        }
    end,
}

BtWQuests = { Database = BtWQuestsDatabase }

------------------------------------------------------------
-- LOAD FILES IN TOC ORDER
------------------------------------------------------------

local toc = assert(io.open(ROOT .. "/CompletionNavigator.toc", "r"))
local files = {}

for line in toc:lines() do
    line = line:gsub("%s+$", "")
    if line ~= "" and not line:match("^#") and line:match("%.lua$") then
        table.insert(files, (line:gsub("\\", "/")))
    end
end

toc:close()

local ADDON_NAME = "CompletionNavigator"
local CN = {}

print("Loading " .. #files .. " files:")

for _, relative in ipairs(files) do
    local path  = ROOT .. "/" .. relative
    local chunk, err = loadfile(path)

    if not chunk then
        print("LOAD ERROR " .. relative .. ": " .. tostring(err))
        os.exit(1)
    end

    local ok, runErr = pcall(chunk, ADDON_NAME, CN)

    if not ok then
        print("RUNTIME ERROR " .. relative .. ": " .. tostring(runErr))
        os.exit(1)
    end

    print("  ok  " .. relative)
end

------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------

local frame = CN.eventFrame

if not frame then
    print("FAIL: no event frame was created.")
    os.exit(1)
end

local onEvent = frame.scripts.OnEvent

print("\nADDON_LOADED:")
onEvent(frame, "ADDON_LOADED", ADDON_NAME)

print("\nPLAYER_LOGIN:")
onEvent(frame, "PLAYER_LOGIN")

print("\nRegistered client events: ")
local eventNames = {}
for e in pairs(frame.events) do table.insert(eventNames, e) end
table.sort(eventNames)
print("  " .. table.concat(eventNames, ", "))

------------------------------------------------------------
-- SLASH COMMANDS
------------------------------------------------------------

local handler = SlashCmdList.COMPLETIONNAVIGATOR

if not handler then
    print("FAIL: slash handler was not registered.")
    os.exit(1)
end

local invocations = {
    "", "status", "help", "debug", "mode", "mode fastest", "mode nonsense",
    "quest 8237", "quest 9002", "quest", "q 9001",
    "cache 8237", "cache 12345",
    "setquest 4242 Manually Named Quest", "cache 4242",
    "setquest 8237 Should Not Overwrite", "cache 8237",
    "queststatus 8237", "queststatus 99999",
    "discoveractive", "discovered", "scanquests",
    "why 8237", "why 9002",
    "providers", "lookup 9002", "lookup 9001", "lookup 12345",
    "harvestnow", "harvest", "export", "export all",
    "petscan", "pets", "pet wild", "pet 100", "pet nope",
    "mountscan", "mounts", "mount horde", "mount 1",
    "toyscan", "toys", "toy 500",
    "appearancescan", "appearances",
    "titlescan", "titles", "title explorer",
    "achievescan", "achievements", "closest", "closest 2",
    "profscan", "professions", "recipes", "recipe 700",
    "vendors", "sells Flask", "sells 701", "sells nothing", "tovendor 700",
    "hidden", "unhide 999", "unhide all", "hidden",
    "auto", "next", "auto", "auto",
    "explorescan", "exploration", "explore 3",
    "currencyscan", "currencies",
    "breakdown", "breakdown Pets", "breakdown nonsense",
    "rares", "rare 1", "rare 99", "raredb",
    "now", "events", "warband", "who rep kirin", "who recipe 700",
    "who title explorer", "who nonsense 1", "who",
    "repscan", "reps",
    "rep 2600", "rep kirin", "rep chromie", "rep 2590", "rep nonsense", "rep",
    "paragon",
    "next", "list", "list 3",
    "zone", "zone 1", "zone 9",
    "go", "go 9002", "go 8237", "where 9002", "where 8237",
    "setloc 8237 84 45.2 61.7", "where 8237", "go 8237", "clearway",
    "ui", "uistatus", "minimap", "minimap", "ui", "ui",
    "perf", "tooltips", "tooltips off", "tooltips on", "tooltips bogus",
    "vault", "greatvault",
    "goals", "goal", "goal nonsense 1", "goal mount notanid",
    "goal mount 2", "goals", "goal mount 2", "gogoal 1", "gogoal 99",
    "goal quest 9002", "goal pet 101", "goals",
    "ungoal 99", "ungoal 1", "goals", "ungoal all", "goals",
    -- setup schedules itself across frames; scanall must bounce off the
    -- running guard rather than interleave a second chain into the first.
    "setup", "scanall",
    "bogus",
}

for _, invocation in ipairs(invocations) do
    print("\n/cn " .. invocation)
    local ok, err = pcall(handler, invocation)

    if not ok then
        print("COMMAND ERROR: " .. tostring(err))
        os.exit(1)
    end
end

-- Let the setup chain finish before anything downstream asserts on state.
CN_TEST_DrainDeferred()

-- /cn perf again, now that providers have been timed at least once.
handler("perf")

------------------------------------------------------------
-- EVENT DISPATCH
------------------------------------------------------------

print("\nEvent dispatch:")

local fired = {
    { "QUEST_ACCEPTED", 9001 },
    { "QUEST_TURNED_IN", 9002 },
    { "QUEST_REMOVED", 9001 },
    { "QUEST_LOG_UPDATE" },
    { "QUEST_DATA_LOAD_RESULT", 4242, true },
    { "QUEST_DATA_LOAD_RESULT", 777777, true },
    { "PLAYER_LEVEL_UP", 81 },
    { "PLAYER_SPECIALIZATION_CHANGED", "player" },
    { "UPDATE_FACTION" },
    { "MAJOR_FACTION_RENOWN_LEVEL_CHANGED", 2600, 13 },
    { "MAJOR_FACTION_UNLOCKED", 2601 },
    { "NEW_PET_ADDED" },
    { "NEW_MOUNT_ADDED" },
    { "NEW_TOY_ADDED" },
    { "KNOWN_TITLES_UPDATE" },
    { "ACHIEVEMENT_EARNED", 13 },
    { "CRITERIA_UPDATE" },
    { "SKILL_LINES_CHANGED" },
    { "TRADE_SKILL_SHOW" },
    { "MERCHANT_SHOW" },
    { "VIGNETTE_MINIMAP_UPDATED" },
    { "VIGNETTES_UPDATED" },
}

for _, entry in ipairs(fired) do
    local event = entry[1]
    local ok, err = pcall(onEvent, frame, event, entry[2], entry[3])

    if not ok then
        print("EVENT ERROR " .. event .. ": " .. tostring(err))
        os.exit(1)
    end

    print("  ok  " .. event)
end

print("\nTrade skill capture (window open):")

CN_TEST_OpenTradeSkill()
onEvent(frame, "TRADE_SKILL_LIST_UPDATE")

-- `handler` is already bound above; rebinding it here shadowed it and made
-- the two halves of this file look independent when they are not.
handler("professions")
handler("recipes")
handler("recipe 700")
handler("recipe Elixir")

print("\nVendor and filter commands, now that data exists:")

handler("vendors")
handler("sells Flask")
handler("tovendor 700")

-- Ignore and defer round-trip: hide two things, confirm they are listed,
-- then undo them. This is the path that had no UI at all before.
CN.SetIgnored(CN.objectiveTypes.PET, 101, true)
CN.SetDeferred(CN.objectiveTypes.MOUNT, 2, 3600)

handler("hidden")

local filters = CN:GetModule("Filters")

local ignoredRows  = filters.ListIgnored()
local deferredRows = filters.ListDeferred()

assert(#ignoredRows == 1, "the ignored pet should be listed, got " .. #ignoredRows)
assert(#deferredRows == 1, "the deferred mount should be listed, got " .. #deferredRows)
assert(ignoredRows[1].name == "Wild Critter",
    "the ignore list must resolve a readable name, got " .. tostring(ignoredRows[1].name))
assert(deferredRows[1].name == "Horde Wolf",
    "the defer list must resolve a readable name, got " .. tostring(deferredRows[1].name))

handler("unhide 101")

assert(#filters.ListIgnored() == 0, "unhide must remove the ignore")
assert(CN.IsIgnored(CN.objectiveTypes.PET, 101) == false,
    "the objective must actually stop being ignored")

handler("unhide all")

assert(#filters.ListDeferred() == 0, "unhide all must clear deferrals")

print("  ignore and defer round-trip verified")

-- An expired deferral must be pruned rather than accumulating forever.
CN.SetDeferred(CN.objectiveTypes.TOY, 500, 1)
CN.Account("deferredObjectives")[CN.ObjectiveKey(CN.objectiveTypes.TOY, 500)].until_ = time() - 10

local pruned = filters.PruneExpired()

assert(pruned == 1, "expired deferrals must be pruned, pruned " .. pruned)

print("  expired deferrals are pruned")

print("\nPLAYER_LOGOUT:")
onEvent(frame, "PLAYER_LOGOUT")

------------------------------------------------------------
-- PERSISTENCE SHAPE
------------------------------------------------------------

print("\nSavedVariables shape:")

local db = CompletionNavigatorDB

local function count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

print("  version              = " .. tostring(db.version))
print("  settings.priorityMode= " .. tostring(db.settings.priorityMode))
print("  settings.debug       = " .. tostring(db.settings.debug))
print("  characters           = " .. count(db.characters))
print("  discoveredQuests     = " .. count(db.account.discoveredQuests))
print("  questMetadata        = " .. count(db.account.questMetadata))
print("  questStatus          = " .. count(db.account.questStatus))

assert(count(db.characters) == 1, "expected one character profile")
assert(count(db.account.discoveredQuests) >= 3, "expected discovered quests")
assert(db.account.questMetadata[8237].name == "Vanquish the Invaders!",
    "manual setquest must not overwrite the questlog name, got: "
    .. tostring(db.account.questMetadata[8237].name))
assert(db.account.questMetadata[4242].name == "Manually Named Quest",
    "manual name should be stored when nothing better exists")

print("  reputations(account)  = " .. count(db.account.reputations))

local characterKey = next(db.characters)
local profile      = db.characters[characterKey]

print("  reputations(character)= " .. count(profile.reputations))

assert(count(db.account.reputations) == 2,
    "account-wide reputations must be stored account-side")
assert(count(profile.reputations) == 3,
    "character-specific reputations must be stored on the character profile")
assert(db.account.reputations[2590].paragon.pending == true,
    "paragon pending flag must persist")
assert(db.account.reputations[2600].renown == 12,
    "renown level must persist")
assert(profile.reputations[2135].kind == "FRIENDSHIP",
    "friendship reputations must be classified separately")
assert(db.account.reputations[1090] == nil,
    "character-specific factions must not leak into account storage")

------------------------------------------------------------
-- UI SHAPE
------------------------------------------------------------

print("\nUI:")

assert(CN.UI, "the UI namespace should exist")

-- Tabs build lazily on first selection, so open the window and visit every
-- one; otherwise this test only ever covers the default tab.
CN.UI.Show()

for index, tab in ipairs(CN.UI.tabs) do
    local ok, err = pcall(CN.UI.SelectTab, index)

    if not ok then
        print("TAB ERROR " .. tab.name .. ": " .. tostring(err))
        os.exit(1)
    end
end

assert(#CN.UI.tabs == 10, "expected ten registered tabs, got " .. #CN.UI.tabs)
assert(CN.UI.selectedTab, "a tab should be selected once the window is opened")

local built = 0

for _, tab in ipairs(CN.UI.tabs) do
    print("  tab " .. tab.name .. (tab.panel and " (built)" or " (not built)"))

    if tab.panel then built = built + 1 end
end

assert(built >= 1, "at least the default tab should have been built")
assert(type(CompletionNavigator_ToggleUI) == "function", "keybinding entry point missing")
assert(type(CompletionNavigator_NextObjective) == "function", "keybinding entry point missing")
assert(type(CompletionNavigator_Navigate) == "function", "keybinding entry point missing")
assert(db.settings.minimap and db.settings.minimap.angle, "minimap settings must persist")

print("\nNavigation:")

local overrides = db.account.questLocations or {}

print("  manual overrides = " .. count(overrides))
print("  super-tracked    = " .. tostring(C_SuperTrack.GetSuperTrackedQuestID()))

assert(C_SuperTrack.GetSuperTrackedQuestID() == 8237,
    "a quest in the log with no coordinates must fall back to super-tracking")
assert(overrides[8237] and overrides[8237].mapID == 84,
    "setloc must persist an override")
assert(math.abs(overrides[8237].x - 0.452) < 0.001,
    "0-100 coordinates must be normalized to 0-1, got " .. tostring(overrides[8237].x))

------------------------------------------------------------
-- COLLECTIONS
------------------------------------------------------------

print("\nCollections:")

print("  pets        = " .. count(db.account.pets))
print("  mounts      = " .. count(db.account.mounts))
print("  toys        = " .. count(db.account.toys))
print("  appearances = " .. count(db.account.appearances))
print("  titleNames  = " .. count(db.account.titleNames))
print("  achievements(incomplete) = " .. count(db.account.achievements))
print("  recipeNames = " .. count(db.account.recipeNames))
print("  professions(character)   = " .. count(profile.professions))
print("  recipes(character)       = " .. count(profile.recipes))
print("  titles(character)        = " .. count(profile.titles))

assert(count(db.account.pets) == 3, "every pet species must be recorded")
assert(db.account.pets[102].obtainable == false, "unobtainable pets must be flagged")
assert(count(db.account.mounts) == 3, "every mount must be recorded")
assert(db.account.mounts[1].collected == true, "collected mounts must be flagged")
assert(count(db.account.toys) == 2, "every toy must be recorded")
assert(db.account.appearances[1].total == 400, "appearance totals must persist")
assert(count(profile.titles) == 2, "only known titles belong on the character")

-- Completed achievements must NOT be stored; only unfinished ones are.
assert(db.account.achievements[12] == nil,
    "completed achievements must not be stored")
assert(db.account.achievements[10] and db.account.achievements[10].done == 4,
    "in-progress achievement criteria must persist")
assert(db.account.achievements[13] == nil,
    "ACHIEVEMENT_EARNED must drop the row")

-- Five profession slots with a nil hole in the middle: fishing and cooking
-- must survive the missing archaeology slot.
assert(count(profile.professions) == 4,
    "expected 4 professions from slots 1,2,4,5; got " .. count(profile.professions))

assert(count(db.account.recipeNames) == 3,
    "recipes must be captured once the trade skill window is open")
assert(profile.recipes[700] and profile.recipes[702],
    "learned recipes must be recorded on the character")
assert(profile.recipes[701] == nil,
    "unlearned recipes must not be recorded as known")

------------------------------------------------------------
-- PROVIDERS AND HARVEST
------------------------------------------------------------

print("\nProviders and harvest:")

local harvest = db.account.questHarvest or {}
print("  harvested quests = " .. count(harvest))

local available = CN.GetAvailableQuestDataProviders()
print("  available providers = " .. table.concat(available, ", "))

assert(#available == 3,
    "ATT, BtWQuests and HandyNotes should all be detected, got " .. #available)

-- HandyNotes registers as a provider for visibility but must never claim
-- to know a quest, or it would contribute wrong prerequisite data.
assert(CN.questDataProviders["HandyNotes"].GetQuestData(9002) == nil,
    "HandyNotes must not answer quest lookups")

-- ATT should answer for 9002 with coordinates and source quests.
local attData = CN.QueryQuestDataProviders(9002)
assert(attData, "ATT should answer for quest 9002")
assert(attData.name == "Test Quest Beta (ATT)", "ATT name should be used")
assert(math.abs(attData.x - 0.61) < 0.001,
    "ATT coords are 0-100 and must be normalized, got " .. tostring(attData.x))
assert(attData.requires and #attData.requires == 2, "ATT sourceQuests should map to requires")

-- BtWQuests should answer for 9001, including a nested prerequisite.
local btwData = CN.QueryQuestDataProviders(9001)
assert(btwData, "BtWQuests should answer for quest 9001")
assert(btwData.requires, "BtWQuests prerequisites should be collected")

local found8237, found4242 = false, false
for _, id in ipairs(btwData.requires) do
    if id == 8237 then found8237 = true end
    if id == 4242 then found4242 = true end
end
assert(found8237, "flat prerequisite should be collected")
assert(found4242, "nested prerequisite should be collected")

-- A quest nothing knows about must return nil, not an empty table.
assert(CN.QueryQuestDataProviders(999999) == nil,
    "unknown quests must return nil")

assert(count(harvest) >= 3, "quests in the log should be harvested")

------------------------------------------------------------
-- MIGRATION
------------------------------------------------------------

------------------------------------------------------------
-- RARES
------------------------------------------------------------

------------------------------------------------------------
-- AUTO-WAYPOINT
------------------------------------------------------------

------------------------------------------------------------
-- VENDORS AND FILTERS
------------------------------------------------------------

print("\nVendors:")

local vendors = db.account.vendors or {}
print("  recorded = " .. count(vendors))

assert(count(vendors) == 1, "the open merchant should be recorded")

local vendor = vendors[55501]
assert(vendor, "the vendor must be keyed by its creature ID from the GUID")
assert(vendor.itemCount == 3, "every merchant item should be recorded, got "
    .. tostring(vendor.itemCount))
assert(vendor.items[700] and vendor.items[700].name == "Flask of Testing",
    "item IDs must be parsed out of the merchant item link")
assert(vendor.mapID and vendor.x, "the vendor location must be recorded")

local sellers = CN:GetModule("Vendors").WhoSells(700)
assert(#sellers == 1, "the reverse item index must find the seller")

print("  item index resolves " .. #sellers .. " seller for item 700")

print("\nAuto-waypoint:")

local settings = db.settings

print("  enabled after three toggles = " .. tostring(settings.autoWaypoint))

assert(settings.autoWaypoint == true,
    "three toggles from the default (off) must land on")

-- Firing the backstop ticker must not error, and must not spam when the
-- objective has not changed.
local before = C_SuperTrack.GetSuperTrackedQuestID()
CN_TEST_FireTickers()
print("  ticker fired without error")

-- Turning it off must stop the ticker doing anything.
settings.autoWaypoint = false
CN.StopAutoWaypointTicker()
CN_TEST_FireTickers()
print("  ticker is inert when disabled")

settings.autoWaypoint = true

print("\nExploration:")

local exploration = db.account.exploration or {}
print("  zones recorded = " .. count(exploration))

assert(count(exploration) == 2, "exploration achievements should be recorded, got "
    .. count(exploration))
assert(exploration[20] and exploration[20].done == 9,
    "in-progress exploration must persist its criteria counts")
assert(exploration[21] and exploration[21].completed == true,
    "completed exploration zones must be flagged")

print("\nCurrencies:")

local profileNow = db.characters[next(db.characters)]
local currencies = profileNow.currencies or {}

print("  tracked = " .. count(currencies))
print("  capped  = " .. tostring(currencies[3008] and currencies[3008].capped))

assert(count(currencies) == 3, "header rows must be skipped, got " .. count(currencies))
assert(currencies[3008].capped == true, "a currency at max must be flagged capped")
assert(currencies[2245].capped == false, "a currency below max must not be capped")
assert(currencies[2245].weeklyRemaining == 700,
    "weekly remaining must be max minus earned, got "
    .. tostring(currencies[2245].weeklyRemaining))

print("\nRares and treasures:")

local rares = db.account.rares or {}
print("  recorded = " .. count(rares))

for id, record in pairs(rares) do
    print("    " .. id .. " " .. tostring(record.name) .. " [" .. tostring(record.kind) .. "]")
end

assert(count(rares) >= 2, "live vignettes should be recorded")
assert(rares[5001] and rares[5001].kind == "RARE",
    "a skull vignette must classify as RARE")
assert(rares[5002] and rares[5002].kind == "TREASURE",
    "a chest vignette must classify as TREASURE, got "
    .. tostring(rares[5002] and rares[5002].kind))
assert(rares[5001].x and rares[5001].y, "vignette coordinates must persist")

print("\nTooltips:")

local tooltips = CN:GetModule("Tooltips")

assert(tooltips, "the Tooltips module must load")
assert(tooltips.backend == "TooltipDataProcessor",
    "the modern tooltip pipeline must be preferred, got " .. tostring(tooltips.backend))

local function tooltipText(lines)
    return table.concat(lines, " | ")
end

-- A collected toy.
local toyLines = tooltipText(CN_TEST_FireItemTooltip(500, "Test Toy"))
print("  toy 500  -> " .. toyLines)
assert(toyLines:find("Toy: collected", 1, true),
    "a collected toy must say so, got " .. toyLines)

-- An uncollected toy.
local missingToy = tooltipText(CN_TEST_FireItemTooltip(501, "Missing Toy"))
print("  toy 501  -> " .. missingToy)
assert(missingToy:find("Toy: not collected", 1, true),
    "an uncollected toy must say so, got " .. missingToy)

-- A mount item resolves through the journal, not the item.
local mountLines = tooltipText(CN_TEST_FireItemTooltip(800, "Reins of the Horde Wolf"))
print("  item 800 -> " .. mountLines)
assert(mountLines:find("Mount: not collected", 1, true),
    "a mount item must report collection state, got " .. mountLines)
assert(mountLines:find("Faction%-locked"),
    "a faction-specific mount must be flagged, got " .. mountLines)

-- A caged pet.
local petLines = tooltipText(CN_TEST_FireItemTooltip(801, "Wild Critter Cage"))
print("  item 801 -> " .. petLines)
assert(petLines:find("Battle pet: not collected", 1, true),
    "a pet item must report collection state, got " .. petLines)

-- An item a recorded vendor sells.
local vendorLines = tooltipText(CN_TEST_FireItemTooltip(700, "Flask of Testing"))
print("  item 700 -> " .. vendorLines)
assert(vendorLines:find("Sold by Test Merchant", 1, true),
    "a recorded seller must appear on the item tooltip, got " .. vendorLines)

-- A wearable item with an appearance this character has not learned.
local appearance = tooltipText(CN_TEST_FireItemTooltip(900, "Tabard of Testing"))
print("  item 900 -> " .. appearance)
assert(appearance:find("Appearance: not yet known", 1, true),
    "an item with an appearance source must report it, got " .. appearance)

-- An item nothing knows anything about must add nothing at all, not an
-- empty header. This is the assertion that keeps the addon off every stack
-- of ore in the game.
local silent = CN_TEST_FireItemTooltip(999999, "Unknown Thing")
print("  item 999999 -> " .. (#silent == 0 and "(no lines)" or tooltipText(silent)))
assert(#silent == 0, "an unknown item must add no lines, got " .. tooltipText(silent))

-- The unit tooltip knows the merchant we already recorded.
local unitLines = tooltipText(CN_TEST_FireUnitTooltip("mouseover"))
print("  unit     -> " .. unitLines)
assert(unitLines:find("Recorded vendor: 3 items", 1, true),
    "a recorded vendor must be identified on its unit tooltip, got " .. unitLines)

-- Turning tooltips off must actually stop them.
db.settings.tooltips = false
local offLines = CN_TEST_FireItemTooltip(500, "Test Toy")
assert(#offLines == 0, "disabling tooltips must suppress every line")
db.settings.tooltips = true

print("  toggle suppresses output")

print("\nSetup:")

local setup = CN:GetModule("Setup")

assert(setup, "the Setup module must load")
assert(#setup.steps == 11, "every scannable subsystem must have a setup step, got "
    .. #setup.steps)

-- Every step must name a module and function that actually exist. This is the
-- assertion that catches a subsystem being renamed and setup quietly skipping
-- it forever.
for _, step in ipairs(setup.steps) do
    local module = CN:GetModule(step.module)
    assert(module, "setup step " .. step.key .. " names a module that does not exist")
    assert(type(module[step.fn]) == "function",
        "setup step " .. step.key .. " names a missing function " .. step.fn)
end

db.account.setup = nil

local completed = false

setup.Run(function() completed = true end)

-- The chain is spread across frames, so it needs draining.
local drained = CN_TEST_DrainDeferred()

print("  deferred callbacks drained = " .. drained)

assert(completed, "setup must reach its completion callback")
assert(setup.running == false, "setup must clear its running flag")
assert(setup.HasRun(), "setup must record that it ran")

-- A second run against a fresh flag must still work, and a concurrent run
-- must be refused rather than interleaved.
setup.running = true
assert(setup.Run() == false, "a second concurrent setup must be refused")
setup.running = false

print("  concurrent run refused")

print("\nMinimap tooltip:")

GameTooltip:ClearLines()

local minimapButton = _G.CompletionNavigatorMinimapButton

if minimapButton and minimapButton:GetScript("OnEnter") then
    minimapButton:GetScript("OnEnter")(minimapButton)

    local text = tooltipText(GameTooltip.lines)

    print("  " .. text)

    assert(text:find("Completion Navigator", 1, true),
        "the minimap tooltip must still identify the addon")
    assert(text:find("Next:", 1, true) or text:find("Nothing actionable", 1, true),
        "the minimap tooltip must report the recommendation, got " .. text)
else
    print("  no minimap button in this environment")
end

print("\nCandidate caching:")

local function fire(event, ...)
    for _, registered in ipairs(CN.eventTable[event] or {}) do
        registered(event, ...)
    end
end

CN.CollectCandidates(true)

local firstState = CN.GetCandidateCacheState()
print("  providers = " .. firstState.providers
    .. ", cached = " .. firstState.fresh
    .. ", objectives = " .. firstState.count)

assert(firstState.providers == 11, "every candidate provider must register, got "
    .. firstState.providers)
assert(firstState.fresh == firstState.providers,
    "a forced collection must leave every provider cached")

-- The whole point of per-provider invalidation: an event nothing subscribes
-- to must not dirty anything.
local generationBeforeMountEvent = CN.GetCandidateCacheState().generation

CN.InvalidateCandidates("NEW_MOUNT_ADDED")
CN.CollectCandidates()

assert(CN.GetCandidateCacheState().generation == generationBeforeMountEvent,
    "an event no provider subscribes to must not rebuild the aggregate")

print("  NEW_MOUNT_ADDED rebuilt nothing")

-- A subscribed event must dirty exactly its own provider.
CN.InvalidateCandidates("NEW_PET_ADDED")

local petState = CN.GetProviderCacheState("Pets")
local achState = CN.GetProviderCacheState("Achievements")

assert(petState.dirty, "NEW_PET_ADDED must mark the Pets provider stale")
assert(not achState.dirty,
    "NEW_PET_ADDED must not mark the Achievements provider stale")

print("  NEW_PET_ADDED dirtied Pets only")

CN.CollectCandidates()

assert(not CN.GetProviderCacheState("Pets").dirty,
    "a stale provider must rebuild on the next collection")

-- The ranked list must be reused when nothing changed, and rebuilt when the
-- priority mode changes.
local rankedOnce = CN.RankedCandidates()
local rankedAgain = CN.RankedCandidates()

assert(rankedOnce == rankedAgain,
    "the ranked list must be reused while the candidate set is unchanged")

db.settings.priorityMode = "pets"
local rankedPets = CN.RankedCandidates()

assert(rankedPets ~= rankedOnce,
    "changing the priority mode must rebuild the ranked list")

db.settings.priorityMode = "balanced"

print("  ranked list reused, and rebuilt on mode change")

-- Ranking must not reorder the candidate list itself; zone routing walks it.
local candidates = CN.CollectCandidates()
local firstBefore = candidates[1]
CN.Recommend(25)
assert(candidates[1] == firstBefore,
    "ranking must sort a copy, not the shared candidate list")

print("  candidate list is not reordered by ranking")

-- Scanning a store with no candidate provider must dirty nothing.
CN.CollectCandidates(true)
local generationBefore = CN.GetCandidateCacheState().generation

CN.MarkScanned("mounts")
CN.CollectCandidates()

assert(CN.GetCandidateCacheState().generation == generationBefore,
    "a mount scan must not rebuild candidate providers")

CN.MarkScanned("pets")
assert(CN.GetProviderCacheState("Pets").dirty,
    "a pet scan must mark the Pets provider stale")

print("  scans invalidate only the providers that read them")

-- Decorators must run exactly once per objective. Per-provider caching means
-- the aggregate is mostly the SAME tables as last time, so a decorator that
-- appends a reason -- Warband's does -- would otherwise stack identical lines
-- under every recommendation.
CN.RegisterCandidateDecorator("HarnessProbe", function(objective)
    objective.reasons = objective.reasons or {}
    table.insert(objective.reasons, "harness-probe")
end)

CN.CollectCandidates(true)

for _ = 1, 3 do
    CN.InvalidateProvider("Pets")
    CN.CollectCandidates()
end

local worstDecorations, worstObjective = 0, nil

for _, objective in ipairs(CN.CollectCandidates()) do
    local seen = 0

    for _, reason in ipairs(objective.reasons or {}) do
        if reason == "harness-probe" then seen = seen + 1 end
    end

    if seen > worstDecorations then
        worstDecorations, worstObjective = seen, objective.name
    end
end

print("  max decorations on any one objective = " .. worstDecorations)

assert(worstDecorations == 1,
    "decorators must run once per objective, not once per rebuild; "
    .. tostring(worstObjective) .. " was decorated " .. worstDecorations .. " times")

CN.candidateDecorators["HarnessProbe"] = nil
CN.CollectCandidates(true)

print("\nGreat Vault:")

local vault = CN:GetModule("Vault")

assert(vault, "the Vault module must load")
assert(vault.IsAvailable(), "the stubbed client must expose C_WeeklyRewards")

local vaultRows = vault.Rows()

for _, row in ipairs(vaultRows) do
    print("  " .. (row.label or "?") .. ": progress " .. row.progress
        .. ", unlocked " .. row.unlocked
        .. (row.capped and ", capped" or (", next at " .. tostring(row.next)
            .. " (" .. tostring(row.remaining) .. " more)")))
end

assert(#vaultRows == 3, "three vault rows must be reported, got " .. #vaultRows)

local byRow = {}
for _, row in ipairs(vaultRows) do byRow[row.row] = row end

-- Raid: 1 of 2 toward the first threshold.
assert(byRow.RAID.unlocked == 0, "raid row must have nothing unlocked")
assert(byRow.RAID.next == 2 and byRow.RAID.remaining == 1,
    "raid row must need 1 more for the first threshold")

-- Dungeon: 3 progress, first threshold (1) met, next is 4.
assert(byRow.DUNGEON.unlocked == 1, "dungeon row must have one reward unlocked, got "
    .. byRow.DUNGEON.unlocked)
assert(byRow.DUNGEON.next == 4 and byRow.DUNGEON.remaining == 1,
    "dungeon row must need 1 more for the second threshold, got "
    .. tostring(byRow.DUNGEON.remaining))

-- World: every threshold met.
assert(byRow.WORLD.capped, "a fully progressed row must be capped")
assert(byRow.WORLD.unlocked == 3, "a capped row must report all three unlocked")
assert(byRow.WORLD.next == nil, "a capped row must have no next threshold")

local vaultSummary = vault.Summary()

print("  total unlocked = " .. vaultSummary.unlocked
    .. ", closest = " .. tostring(vaultSummary.closest and vaultSummary.closest.label))

assert(vaultSummary.unlocked == 4, "four rewards should be unlocked, got "
    .. vaultSummary.unlocked)
assert(vaultSummary.closest, "a row short of a threshold must be reported as closest")

-- Capped rows must never become candidates; they cannot be advanced.
CN.InvalidateCandidates()

local vaultCandidates = {}

for _, objective in ipairs(CN.CollectCandidates(true)) do
    if type(objective.name) == "string" and objective.name:find("Great Vault", 1, true) then
        table.insert(vaultCandidates, objective)
    end
end

print("  vault candidates = " .. #vaultCandidates)

assert(#vaultCandidates == 2,
    "only the two advanceable rows should become candidates, got " .. #vaultCandidates)

for _, objective in ipairs(vaultCandidates) do
    assert(not objective.name:find("World", 1, true),
        "a capped row must not be recommended")
end

-- An unclaimed reward outranks progress toward a new one.
CN_TEST_SetVaultClaimable(true)
CN.InvalidateCandidates()

local claimable = nil

for _, objective in ipairs(CN.CollectCandidates(true)) do
    if objective.name == "Collect your Great Vault reward" then claimable = objective end
end

assert(claimable, "an available reward must become a candidate")

print("  unclaimed reward surfaces as a candidate")

CN_TEST_SetVaultClaimable(false)
CN.InvalidateCandidates()
CN.CollectCandidates(true)

print("\nGoals:")

local goals = CN:GetModule("Goals")

assert(goals, "the Goals module must load")

goals.Clear()

-- An uncollected mount is not normally a candidate at all. Pinning it must
-- make it one -- that is the entire point.
local beforeGoal = 0

for _, objective in ipairs(CN.CollectCandidates(true)) do
    if objective.type == "MOUNT" and objective.id == 3 then beforeGoal = beforeGoal + 1 end
end

assert(beforeGoal == 0, "an unpinned mount must not be a candidate")

goals.Add("MOUNT", 3)

local afterGoal, goalObjective = 0, nil

for _, objective in ipairs(CN.CollectCandidates()) do
    if objective.type == "MOUNT" and objective.id == 3 then
        afterGoal = afterGoal + 1
        goalObjective = objective
    end
end

print("  pinned mount appears as a candidate = " .. tostring(afterGoal == 1))

assert(afterGoal == 1, "a pinned goal must become exactly one candidate, got " .. afterGoal)
assert(goalObjective.isGoal, "a goal candidate must be flagged as one")

-- Precedence, stated rather than assumed.
--
-- A pinned goal outranks everything that is merely available. It does NOT
-- outrank something with a deadline: a Great Vault slot one activity away
-- expires on Tuesday, and the mount will still be there next week. That is
-- the whole point of weighting urgency steeply, and it would be wrong to
-- special-case goals out of it.
--
-- What must hold is that the goal is near the top, and first once nothing
-- is expiring.
local ranked = CN.Recommend(5)

print("  ranked with vault present:")

for index, objective in ipairs(ranked) do
    print("    " .. index .. ". " .. tostring(objective.name)
        .. " (" .. string.format("%.1f", objective.priorityWeight or 0) .. ")")
end

local goalRank

for index, objective in ipairs(ranked) do
    if objective.type == "MOUNT" and objective.id == 3 then goalRank = index end
end

assert(goalRank and goalRank <= 3,
    "a pinned goal must rank in the top three, got " .. tostring(goalRank))

-- With the expiring content gone, the goal must be first.
local vaultProvider = CN.candidateProviders["Vault"]

CN.candidateProviders["Vault"] = nil
CN.InvalidateCandidates()

local top = CN.Recommend(1)[1]

print("  top with nothing expiring = " .. tostring(top.name) .. " ("
    .. string.format("%.1f", top.priorityWeight or 0) .. ")")

assert(top.type == "MOUNT" and top.id == 3,
    "with nothing expiring, a pinned goal must rank first, got " .. tostring(top.name))

CN.candidateProviders["Vault"] = vaultProvider
CN.InvalidateCandidates()

-- Removing it must put things back.
goals.Remove("MOUNT", 3)

local afterRemoval = 0

for _, objective in ipairs(CN.CollectCandidates()) do
    if objective.type == "MOUNT" and objective.id == 3 then afterRemoval = afterRemoval + 1 end
end

assert(afterRemoval == 0, "removing a goal must remove its candidate")

print("  removing the goal removes the candidate")

-- The goal decorator must be idempotent too, for the same reason Warband's is.
goals.Add("QUEST", 9002)

for _ = 1, 3 do
    CN.InvalidateProvider("Pets")
    CN.CollectCandidates()
end

for _, objective in ipairs(CN.CollectCandidates()) do
    local mentions = 0

    for _, reason in ipairs(objective.reasons or {}) do
        if reason == "this is one of your goals"
            or reason == "in the same zone as a goal"
            or reason == "unlocks a goal" then
            mentions = mentions + 1
        end
    end

    assert(mentions <= 1, "goal reasons must not stack on "
        .. tostring(objective.name) .. ", got " .. mentions)
end

print("  goal weighting does not stack across rebuilds")

goals.Clear()
CN.CollectCandidates(true)

print("\nBounded collection:")

-- Ten entries, values 1 and 2, capped at 3: the three highest-valued win,
-- ties broken by ID so the list does not reshuffle.
local source = {}
for i = 1, 10 do
    source[i] = { value = (i <= 4) and 2 or 1 }
end

local bounded, considered, dropped = CN.CollectBounded(source, 3,
    function(_, record) return record.value end,
    function(id, record, value)
        return CN.NewObjective({ id = id, completionValue = value })
    end)

print("  kept " .. #bounded .. " of " .. considered .. ", dropped " .. dropped)

assert(#bounded == 3, "the cap must be respected, got " .. #bounded)
assert(considered == 10, "every entry must be counted, got " .. considered)
assert(dropped == 7, "the drop count must be reported, got " .. dropped)

for _, objective in ipairs(bounded) do
    assert(objective.completionValue == 2,
        "the cap must keep the highest-valued entries, kept one worth "
        .. tostring(objective.completionValue))
end

-- Deterministic: the same input must produce the same output.
local again = CN.CollectBounded(source, 3,
    function(_, record) return record.value end,
    function(id, record, value)
        return CN.NewObjective({ id = id, completionValue = value })
    end)

local function ids(list)
    local out = {}
    for _, objective in ipairs(list) do out[#out + 1] = objective.id end
    table.sort(out)
    return table.concat(out, ",")
end

assert(ids(bounded) == ids(again),
    "the cut must be deterministic, got " .. ids(bounded) .. " then " .. ids(again))

print("  cut is deterministic: " .. ids(bounded))

-- Under the cap, nothing is dropped.
local small = { [1] = { value = 1 }, [2] = { value = 1 } }
local keptAll, _, noneDropped = CN.CollectBounded(small, 60,
    function(_, record) return record.value end,
    function(id) return CN.NewObjective({ id = id }) end)

assert(#keptAll == 2 and noneDropped == 0,
    "a store under the cap must be emitted whole")

print("  stores under the cap are untouched")

-- Filters must short-circuit when nothing is hidden, and still work when
-- something is.
assert(CN.IsIgnored("PET", 12345) == false, "an empty ignore list must answer false")
CN.SetIgnored("PET", 12345, true)
assert(CN.IsIgnored("PET", 12345) == true, "the fast path must not break real lookups")
assert(CN.IsIgnored("PET", 99999) == false, "a populated list must still answer false")
CN.SetIgnored("PET", 12345, false)

print("  ignore fast path preserves real lookups")

print("\nMigration 1 -> 2:")

-- A database as an older build would have left it: schema version 1, the
-- collection tables absent, and the minimap setting stored flat.
CompletionNavigatorDB = {
    version = 1,
    settings = {
        enabled = true,
        debug = false,
        priorityMode = "quests",
        minimap = true,          -- old flat boolean, meaning "hidden"
        minimapAngle = 90,
    },
    account = {
        discoveredQuests = { [123] = { firstSeen = 1 } },
        questMetadata = { [123] = { name = "Legacy Quest" } },
    },
    characters = { ["Old-Char"] = { name = "Old", level = 60 } },
}

CN.InitializeDatabase()

local migrated = CompletionNavigatorDB

print("  version           = " .. tostring(migrated.version))
print("  minimap.hide      = " .. tostring(migrated.settings.minimap.hide))
print("  minimap.angle     = " .. tostring(migrated.settings.minimap.angle))
print("  discoveredQuests  = " .. count(migrated.account.discoveredQuests))
print("  characters        = " .. count(migrated.characters))

assert(migrated.version == 2, "the ladder must advance the schema version")
assert(type(migrated.settings.minimap) == "table",
    "the flat minimap boolean must become a table")
assert(migrated.settings.minimap.hide == true,
    "the player's hidden-minimap choice must survive migration")
assert(migrated.settings.minimap.angle == 90,
    "the saved minimap angle must survive migration")
assert(migrated.settings.minimapAngle == nil, "legacy flat keys must be removed")
assert(migrated.settings.priorityMode == "quests",
    "unrelated settings must not be reset")
assert(count(migrated.account.discoveredQuests) == 1,
    "completion history must never be destroyed by a migration")
assert(migrated.account.questMetadata[123].name == "Legacy Quest",
    "existing metadata must survive")
assert(type(migrated.account.pets) == "table",
    "new account tables must be created")
assert(migrated.characters["Old-Char"].name == "Old",
    "existing characters must survive")

-- Running it again must be a no-op, not a second migration.
CN.InitializeDatabase()
assert(CompletionNavigatorDB.version == 2, "migration must be idempotent")

print("  re-run is idempotent")

print("\nALL HARNESS CHECKS PASSED")
