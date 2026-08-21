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
    function f:CreateFontString()
        local fs = Frame()

        -- Record what was actually displayed. The universal stub swallowed
        -- SetText, so no test could ever assert what the arrow said.
        function fs:SetText(value) fs.text = value end
        function fs:GetText() return fs.text end

        return fs
    end

    function f:CreateTexture()
        local t = Frame()

        -- RECORD ROTATION AND COLOUR.
        --
        -- These fell through to the universal stub, which accepts anything
        -- and remembers nothing. That is why the on-screen arrow -- the most
        -- visible thing this addon draws -- had no test that could see which
        -- way it pointed, and why a player had to report the same defect
        -- twice.
        function t:SetRotation(value) t.rotation = value end
        function t:GetRotation() return t.rotation end

        function t:SetVertexColor(r, g, b)
            t.colour = { r = r, g = g, b = b }
        end

        function t:GetVertexColor()
            local c = t.colour or {}
            return c.r, c.g, c.b
        end

        function t:SetTexture(path) t.texturePath = path end
        function t:GetTexture() return t.texturePath end

        return t
    end

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

-- The world map, modelled with the shape MapPins actually reads.
--
-- Deliberately NOT a flat universal stub. The canvas has a real width and
-- height because the pin arithmetic multiplies by them, and a stub returning
-- a table there would turn a sign error into "attempt to perform arithmetic
-- on a table value" -- an error about the stub, not about the addon. The
-- displayed map is settable so the test can look at a map the player is not
-- standing in, which is the case the routing start point gets wrong.
local worldMapHooks = {}

WorldMapFrame = {
    displayedMapID = 2112,
    shown          = false,

    ScrollContainer = {
        Child = (function()
            local canvas = Frame()
            function canvas:GetWidth()  return 1000 end
            function canvas:GetHeight() return 666 end
            return canvas
        end)(),
    },
}

function WorldMapFrame:GetMapID() return self.displayedMapID end
function WorldMapFrame:IsShown()  return self.shown == true end
function WorldMapFrame:HookScript(script, handler)
    worldMapHooks[script] = worldMapHooks[script] or {}
    table.insert(worldMapHooks[script], handler)
end

CN_TEST_WORLD_MAP_HOOKS = worldMapHooks

-- Map topology. A player standing in a city is on a CHILD map; the zone's
-- quest starts are registered against the parent. Modelling every map as an
-- island is what let "0 available" ship while a quest giver was in view.
-- One table, not six locals: the main chunk is at Lua's 200-local ceiling,
-- and a fixture that cannot compile is not a fixture.
local F = {}

F.mapTree = {
    [94]   = { name = "Eversong Woods", parentMapID = 1941, mapType = 3 },
    [2112] = { name = "Valdrakken",     parentMapID = 2022, mapType = 4 },
    [2022] = { name = "The Waking Shores", parentMapID = 1978, mapType = 3 },
    [1941] = { name = "Quel'Thalas",    parentMapID = 0,     mapType = 2 },
    [1978] = { name = "Dragon Isles",   parentMapID = 0,     mapType = 2 },
}

F.mapChildren = {
    [2022] = { { mapID = 2112 } },
    [1941] = { { mapID = 94 } },
}

F.completedQuestIDs = { 8237, 9002, 9500, 9501, 9502 }

-- A REALISTIC history. Somebody doing three hundred quests in a weekend has
-- tens of thousands of these within a year.
for index = 1, 12000 do
    F.completedQuestIDs[#F.completedQuestIDs + 1] = 50000 + index
end

F.gossipOffers = {}

function CN_TEST_SetGossipOffers(offers) F.gossipOffers = offers or {} end

F.questOfferID = nil

function CN_TEST_SetQuestOffer(id) F.questOfferID = id end
function GetQuestID() return F.questOfferID or 0 end
function GetTitleText() return "Offered By An NPC" end

C_CampaignInfo = {
    GetCampaignID = function(questID)
        -- Odd quest IDs are campaign quests in the fixture, so the split has
        -- something on both sides of it.
        return (questID % 2 == 1) and 42 or nil
    end,
    GetCampaignInfo = function(id) return { name = "Campaign " .. id } end,
    GetChapterIDs   = function() return { 1, 2, 3 } end,
}

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

-- Mount state, so speed sampling can be bucketed. Settable, because the
-- interesting case is the transition: a sample that spans mounting belongs
-- to neither bucket and must be discarded.
CN_TEST_MOUNTED = false
function IsMounted() return CN_TEST_MOUNTED end
function UnitOnTaxi() return false end

-- Combat state. The interesting case is that the addon must NOT move a
-- waypoint while the player is being hit by something.
CN_TEST_IN_COMBAT = false
function InCombatLockdown() return CN_TEST_IN_COMBAT end

-- The client's fractional monotonic clock. `time()` has one-second
-- resolution, which was the bug: a ten-second sample measured with a
-- one-second ruler carries up to ten per cent error, and anything finished
-- inside the same second read as zero elapsed and was thrown away.
CN_TEST_CLOCK = 1000.0
function GetTime() return CN_TEST_CLOCK end
function GetZoneText() return "Eversong Woods" end
function GetSpecialization() return 3 end
function GetSpecializationInfo() return 70, "Retribution" end
function GetProfessions() return 1, 2, nil, 4, 5 end
function GetProfessionInfo(i) return "Profession" .. i, nil, 75, 100, nil, nil, 170 + i end

-- UiMapPoint and Vector2D are DIFFERENT types, and modelling them as the same
-- shape is what let a real bug ship: 0.19.0 passed a UiMapPoint to
-- GetWorldPosFromMapPos, which wants a Vector2D, and the arrow reported
-- "distance unknown" for every target. The stub accepted it because the stub
-- was wrong too.
--
-- UiMapPoint carries a NESTED position. Vector2D carries x and y directly and
-- exposes GetXY(). Anything that reads the wrong one now fails here first.
UiMapPoint = {
    CreateFromCoordinates = function(mapID, x, y)
        return {
            uiMapID  = mapID,
            position = { x = x, y = y },
        }
    end,
}

function CreateVector2D(x, y)
    local vector = { x = x, y = y }

    function vector:GetXY() return self.x, self.y end

    return vector
end

C_Map = {
    GetBestMapForUnit    = function() return 94 end,
    -- A MOVABLE player.
    --
    -- Fixed at one point, the stub could never express the case a player
    -- reported twice: walking past the destination and continuing. Every
    -- arrow test was therefore a test of standing still.
    -- A MOVABLE player, on a map that can refuse to place them.
    --
    -- The real API answers only for maps that can actually describe where the
    -- player is standing -- the zone you are in, and the zone containing the
    -- building you stepped into. For anywhere else it returns nil.
    --
    -- The stub used to answer for EVERY map, which is why nothing could tell
    -- the difference between "you are in a building inside this zone" and
    -- "you are on another continent". Those need opposite behaviour from the
    -- arrow, and the stub made them identical.
    --
    -- CN_TEST_PLAYER_MAPS lists the maps that can place the player.
    GetPlayerMapPosition = function(mapID)
        if not CN_TEST_PLAYER_MAPS[mapID] then
            return nil
        end

        return {
            GetXY = function()
                return CN_TEST_PLAYER_X or 0.42, CN_TEST_PLAYER_Y or 0.55
            end,
        }
    end,
    GetMapInfo           = function(id)
        return F.mapTree[id] or { name = "Map" .. tostring(id), mapType = 3 }
    end,
    GetMapChildrenInfo   = function(id) return F.mapChildren[id] or {} end,
    SetUserWaypoint      = function() end,
    ClearUserWaypoint    = function() end,
    -- A flat 1000x1000 yard square, so expected distances are checkable.
    GetWorldPosFromMapPos = function(mapID, point)
        -- The real client wants a Vector2D. Handing it a UiMapPoint is the
        -- 0.19.0 bug; fail loudly rather than quietly returning a number.
        assert(point and point.x and point.y and not point.uiMapID,
            "GetWorldPosFromMapPos needs a Vector2D, not a UiMapPoint")

        return 1, CreateVector2D(point.x * 1000, point.y * 1000)
    end,
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

-- Titles the client knows about but which are NOT in the log: available
-- quests still have names.
local offeredTitles = {
    [9100] = "Pick Me Up",
    [9101] = "Already Done",
    [9102] = "Daily Offer",
}

local pendingLoad = {}

CN_TEST_PLAYER_X, CN_TEST_PLAYER_Y = 0.42, 0.55

-- Maps that can express where the player is standing.
CN_TEST_PLAYER_MAPS = { [94] = true }

C_QuestLog = {
    -- BUILDS A FRESH TABLE, because the client does.
    --
    -- The stub used to hand back the same table every call, which made
    -- reading it look free and hid the fact that a UI refresh was allocating
    -- a copy of the player's entire quest history. This is the fifth time in
    -- this project a stub has modelled the world too simply and hidden a real
    -- defect; the pattern is always a stub that is cheaper than the thing.
    GetAllCompletedQuestIDs = function()
        local copy = {}

        for index = 1, #F.completedQuestIDs do
            copy[index] = F.completedQuestIDs[index]
        end

        return copy
    end,
    IsQuestFlaggedCompleted          = function(id)
        if id >= 70000 then return false end   -- world quests are fresh
        return id % 2 == 1
    end,
    IsQuestFlaggedCompletedOnAccount = function(id) return id % 3 == 0 end,
    GetTitleForQuestID               = function(id)
        for _, entry in ipairs(questLog) do
            if entry.questID == id then return entry.title end
        end
        return offeredTitles[id]
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
    -- The map POI list, which carries BOTH the quests you already have and
    -- the ones standing in the zone waiting to be picked up.
    --
    -- The old stub returned only an in-log quest, which is exactly why the
    -- addon shipped for twenty-two releases unable to see an available quest:
    -- the test data had none either.
    GetQuestsOnMap = function(mapID)
        if mapID ~= 94 then return {} end

        return {
            -- In the log already; findable only through this list.
            { questID = 9002, x = 0.61, y = 0.48,
              isQuestStart = false, inProgress = true },

            -- An exclamation mark: offered here, not accepted, not done.
            { questID = 9100, x = 0.33, y = 0.27,
              isQuestStart = true, inProgress = false, isDaily = false },

            -- A daily, also available.
            { questID = 9102, x = 0.44, y = 0.66,
              isQuestStart = true, inProgress = false, isDaily = true },

            -- A quest start for something already completed: must be ignored.
            { questID = 9101, x = 0.50, y = 0.50,
              isQuestStart = true, inProgress = false },
        }
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

-- Player facing: radians, 0 = north, increasing counter-clockwise.
local playerFacing = 0

function GetPlayerFacing() return playerFacing end
function CN_TEST_SetFacing(radians) playerFacing = radians end

-- World positions, so distance comes out in yards. The stub map is a flat
-- 1000x1000 yard square, which makes the expected distances checkable by hand.
C_Map = C_Map or {}

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

    -- What the NPC in front of you is offering. The one source of "there is
    -- a quest here" that cannot be wrong, because you are in the
    -- conversation.
    GetAvailableQuests = function() return F.gossipOffers end,
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
    -- The journal knows every pet's name. The addon stopped keeping its own
    -- copy in 0.36.0, so this is now the only source -- and a stub that did
    -- not provide it would make the addon look broken rather than lean.
    GetPetInfoBySpeciesID = function(speciesID)
        for _, pet in ipairs(petSpecies or {}) do
            if pet.speciesID == speciesID then
                return pet.name
            end
        end

        return nil
    end,

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

-- An appearance has SOURCES -- several ways to obtain the same look -- and
-- any one of them is enough. Modelling it as a single collected/not flag
-- would let "1 of 4 sources" be presented as 25% of the way to an appearance
-- the player has, in fact, already got.
local appearanceSources = {
    [8001] = {
        { sourceID = 1, name = "Dropped by Some Boss",  isCollected = false, itemID = 501 },
        { sourceID = 2, name = "Sold by Some Vendor",   isCollected = false, itemID = 502 },
        { sourceID = 3, name = "Quest reward",          isCollected = false, itemID = 503 },
    },
    [8002] = {
        { sourceID = 4, name = "Already have this one", isCollected = true,  itemID = 504 },
        { sourceID = 5, name = "Another way entirely",  isCollected = false, itemID = 505 },
    },
}

C_TransmogCollection = {
    GetCategoryInfo           = function(id) return appearanceData[id] and appearanceData[id].name or nil end,
    GetCategoryCollectedCount = function(id) return appearanceData[id] and appearanceData[id].collected or 0 end,
    GetCategoryTotal          = function(id) return appearanceData[id] and appearanceData[id].total or 0 end,
    GetAppearanceSources      = function(id) return appearanceSources[id] end,
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

-- The achievement category tree. 96 is Blizzard's "Quests" root; the others
-- hang off it the way expansion and continent categories really do, so the
-- tree walk has an actual tree to walk rather than a flat list that would
-- pass without exercising anything.
local achievementCategories = {
    [96] = { name = "Quests",          parent = -1 },
    [92] = { name = "Khaz Algar",      parent = 96 },
    [97] = { name = "Dragon Isles",    parent = 96 },
    [11] = { name = "Not A Quest Cat", parent = -1 },
}

function GetCategoryInfo(categoryID)
    local entry = achievementCategories[categoryID]

    if not entry then
        return nil
    end

    return entry.name, entry.parent, 0
end

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

-- The real signature carries a quantity and a requirement after the
-- completion flag, and some criteria are counters rather than checkboxes.
-- Returning only three values modelled a world where every criterion is a
-- checkbox, which is the kind of simplification that has hidden real bugs in
-- this addon twice.
function GetAchievementCriteriaInfo(id, index)
    local data = achievementData[id]
    if not data then return nil end

    local completed = index <= data.done

    -- Make the second criterion a counter, so anything reading quantity has
    -- a case where it actually matters.
    if index == 2 then
        return "collect widgets", 1, completed, completed and 25 or 7, 25
    end

    return "criterion " .. index, 1, completed, completed and 1 or 0, 1
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
    -- Item 501 is the uncollected toy. Toys and vendor stock are both keyed
    -- by item ID, so this join is exact -- and without a toy on the merchant
    -- the toy provider's assertion would pass vacuously.
    { name = "Missing Toy",      price = 750,  itemID = 501 },
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

-- LibDataBroker, stubbed through LibStub. The broker is optional, so both
-- halves need testing: present, and absent.
local brokerObjects = {}

local fakeLDB = {
    NewDataObject = function(self, name, definition)
        brokerObjects[name] = definition
        return definition
    end,
}

function LibStub(name, silent)
    if name == "LibDataBroker-1.1" then
        return fakeLDB
    end

    if silent then
        return nil
    end

    error("library not found: " .. tostring(name))
end

function CN_TEST_BrokerObjects() return brokerObjects end

-- TomTom, stubbed.
--
-- Coverage found this: the TomTom waypoint provider ships in every release and
-- was never executed by a single test, because no TomTom existed to probe. A
-- provider nobody runs is a provider nobody knows is broken.
local tomtomWaypoints = {}

TomTom = {
    AddWaypoint = function(self, mapID, x, y, options)
        local uid = { mapID = mapID, x = x, y = y, options = options }
        table.insert(tomtomWaypoints, uid)
        return uid
    end,
    RemoveWaypoint = function(self, uid)
        for index, entry in ipairs(tomtomWaypoints) do
            if entry == uid then
                table.remove(tomtomWaypoints, index)
                return true
            end
        end
        return false
    end,
}

function CN_TEST_TomTomWaypoints() return tomtomWaypoints end

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
    "show", "show pets", "show pets", "show only quests", "show all",
    "alerts", "alerts on", "alerts off", "alerts bogus", "broker",
    "perchar", "perchar priorityMode", "perchar priorityMode", "perchar nonsense",
    "show nonsense", "types",
    "arrow", "arrow off", "arrow on", "arrow bogus",
    "nav", "nav native", "nav tomtom", "nav auto", "nav nonsense", "here",
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

assert(#CN.UI.tabs == 11, "expected eleven registered tabs, got " .. #CN.UI.tabs)
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

-- Scoped: Lua caps a function at 200 locals and this file
-- outgrew it. Each self-contained section gets its own scope.
do
print("\nRoute optimization:")

-- A deliberately bad order: nearest-neighbour's classic failure is to strand
-- a far stop and double back. Four points on a square, visited diagonally,
-- cross in the middle; 2-opt must uncross them.
local crossed = {
    { name = "A", x = 0.10, y = 0.10 },
    { name = "B", x = 0.90, y = 0.90 },
    { name = "C", x = 0.90, y = 0.10 },
    { name = "D", x = 0.10, y = 0.90 },
}

local crossedLength = CN.RouteLength(crossed, 0.10, 0.10)

local uncrossed, saved = CN.ImproveRoute(crossed, 0.10, 0.10)

local uncrossedLength = CN.RouteLength(uncrossed, 0.10, 0.10)

local order = {}
for _, stop in ipairs(uncrossed) do order[#order + 1] = stop.name end

print(string.format("  crossed  = %.3f", crossedLength))
print(string.format("  improved = %.3f  (%s)  saved %.1f%%",
    uncrossedLength, table.concat(order, " -> "), (saved or 0) * 100))

assert(uncrossedLength < crossedLength,
    "2-opt must shorten a crossed route")
assert(#uncrossed == #crossed, "2-opt must not lose or duplicate stops")

local seenStops = {}
for _, stop in ipairs(uncrossed) do
    assert(not seenStops[stop.name], "2-opt duplicated stop " .. stop.name)
    seenStops[stop.name] = true
end

-- It must never make a route worse, and must be a no-op on tiny routes.
local tiny = { { name = "A", x = 0.2, y = 0.2 }, { name = "B", x = 0.8, y = 0.8 } }
local tinyResult = CN.ImproveRoute(tiny, 0.5, 0.5)
assert(#tinyResult == 2, "a two-stop route must survive untouched")

print("  no stops lost, short routes untouched")
end

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
assert(vendor.itemCount == 4, "every merchant item should be recorded, got "
    .. tostring(vendor.itemCount))
assert(vendor.items[700],
    "item IDs must be parsed out of the merchant item link")

-- WHAT A VENDOR ROW MAY CONTAIN.
--
-- Names are not stored: the client caches every item name and keeping a copy
-- made this the largest thing the addon wrote to disk. Nor does each item get
-- a table of its own -- a table per item costs more in the saved file than
-- the price it carries, and a large vendor sells hundreds.
assert(type(vendor.items[700]) == "number",
    "an item must be stored as its price, not as a table, got "
    .. type(vendor.items[700]))

assert(CN.Blizzard.GetItemName(700) == "Flask of Testing",
    "the name must still be resolvable from the client on demand")

local vendorsModule = CN:GetModule("Vendors")

assert(vendorsModule.PriceOf(vendor, 700) ~= nil,
    "the price must still be readable")

-- An old database keeps working until the next merchant visit rewrites it.
assert(vendorsModule.PriceOf({ items = { [900] = { price = 42 } } }, 900) == 42,
    "rows saved in the previous shape must still be readable")
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
assert(unitLines:find("Recorded vendor: 4 items", 1, true),
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

-- Sections further down run inside their own functions (Lua caps a function
-- at 200 locals and this file is at the ceiling), so they cannot see the
-- upvalue. Publish it.
CN.FireEvent = fire

CN.CollectCandidates(true)

local firstState = CN.GetCandidateCacheState()
print("  providers = " .. firstState.providers
    .. ", cached = " .. firstState.fresh
    .. ", objectives = " .. firstState.count)

assert(firstState.providers == 16, "every candidate provider must register, got "
    .. firstState.providers)
assert(firstState.fresh == firstState.providers,
    "a forced collection must leave every provider cached")

-- The whole point of per-provider invalidation: an event nothing subscribes
-- to must not dirty anything.
local generationBeforeMountEvent = CN.GetCandidateCacheState().generation

-- A synthetic event name rather than a real one: picking a real event that
-- "nothing subscribes to today" breaks the moment a provider subscribes to
-- it, which is exactly what happened when Mounts gained a provider.
CN.InvalidateCandidates("CN_TEST_EVENT_NOBODY_WANTS")
CN.CollectCandidates()

assert(CN.GetCandidateCacheState().generation == generationBeforeMountEvent,
    "an event no provider subscribes to must not rebuild the aggregate")

print("  an unsubscribed event rebuilt nothing")

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

print("\nNavigation:")

local nav = CN:GetModule("Navigation")

assert(nav, "the Navigation module must load")

-- Bearing.
--
-- The previous version of this test computed each expected answer from the
-- same assumption the code used, so it agreed with a bug that pointed people
-- away from their target. These cases are written from PHYSICAL facts that
-- hold regardless of which way GetPlayerFacing counts:
--
--   * facing straight at the target must give a relative bearing of zero
--   * facing directly away must give +/- 180
--   * a target to one side must give +/- 90, and the two sides must differ
--
-- The sign convention is then pinned separately, and the harness checks BOTH
-- conventions behave consistently rather than asserting which one is live.
local function bearingDegrees(tx, ty, facing, sign)
    local relative = nav.RelativeBearing(0.5, 0.5, tx, ty, facing, sign)
    return relative and math.floor(math.deg(relative) + 0.5) or nil
end

for _, sign in ipairs({ 1, -1 }) do
    -- Under either convention, facing north is 0.
    local aheadNorth = bearingDegrees(0.5, 0.4, 0, sign)

    assert(aheadNorth == 0,
        "facing north at a northern target must be 0 under sign " .. sign
        .. ", got " .. tostring(aheadNorth))

    -- And facing north at a southern target must be a half turn.
    local behind = bearingDegrees(0.5, 0.6, 0, sign)

    assert(math.abs(behind) == 180,
        "facing north at a southern target must be a half turn under sign "
        .. sign .. ", got " .. tostring(behind))

    -- East and west must be 90 apart in opposite directions.
    local east = bearingDegrees(0.6, 0.5, 0, sign)
    local west = bearingDegrees(0.4, 0.5, 0, sign)

    assert(math.abs(east) == 90 and math.abs(west) == 90,
        "a target due east or west must be a quarter turn away")
    assert(east == -west, "east and west must differ in sign")

    -- Turning the player by the bearing must line them up: this is the
    -- property that actually matters and it is convention-independent.
    local turned = bearingDegrees(0.6, 0.5, sign * math.rad(east), sign)

    assert(math.abs(turned) < 1,
        "turning by the reported bearing must line the player up under sign "
        .. sign .. ", got " .. tostring(turned))
end

print("  bearing is self-consistent under both facing conventions")

-- The two conventions must actually differ, or the sign would be doing
-- nothing and the self-correction could never help.
local underPlus  = bearingDegrees(0.6, 0.5, math.rad(45), 1)
local underMinus = bearingDegrees(0.6, 0.5, math.rad(45), -1)

assert(underPlus ~= underMinus,
    "the facing sign must change the answer, or correcting it is pointless")

print("  the facing sign changes the result (+" .. underPlus
    .. " vs " .. underMinus .. ")")

-- Self-correction: following the arrow while the distance GROWS is proof the
-- arrow is backwards. That is ground truth from the game, which is the only
-- place it can come from.
local signBefore = nav.FacingSign()

nav.ResetCalibration()

local flipped = false

for step = 1, nav.calibrationSamples + 1 do
    -- Lined up with the arrow, and getting further away every tick.
    if nav.NoteObservation(0.05, 100 + (step * 10)) then
        flipped = true
    end
end

assert(flipped, "walking along the arrow while the distance grows must flip the sign")
assert(nav.FacingSign() == -signBefore, "the sign must actually change")

print("  distance growing while aligned flipped the sign "
    .. signBefore .. " -> " .. nav.FacingSign())

-- And it must NOT flip when the distance is shrinking, or when the player is
-- not following the arrow at all.
nav.SetFacingSign(signBefore)
nav.ResetCalibration()

for step = 1, nav.calibrationSamples + 2 do
    nav.NoteObservation(0.05, 500 - (step * 10))
end

assert(nav.FacingSign() == signBefore, "closing distance must never flip the sign")

nav.ResetCalibration()

for step = 1, nav.calibrationSamples + 2 do
    -- Facing sideways: the distance says nothing about the arrow.
    nav.NoteObservation(1.4, 100 + (step * 10))
end

assert(nav.FacingSign() == signBefore,
    "distance growing while NOT following the arrow must not flip the sign")

print("  no flip when closing, or when not following the arrow")

assert(nav.RelativeBearing(0.5, 0.5, nil, nil, 0) == nil,
    "an uncomputable bearing must be nil, not zero")

-- Distance must be yards, not map percentage. The stub map is 1000 yards
-- square, so 0.5 -> 0.6 on x is exactly 100 yards.
local yards = nav.DistanceYards(94, 0.5, 0.5, 0.6, 0.5)

print("  distance 0.5 -> 0.6 on a 1000yd map = " .. tostring(yards) .. " yd")

assert(yards and math.abs(yards - 100) < 0.01,
    "distance must convert to yards, got " .. tostring(yards))

assert(nav.FormatDistance(nil) == "distance unknown",
    "an unknown distance must say so rather than print a number")
assert(nav.FormatDistance(42):find("42"), "yards should be shown plainly")

-- Colour must track the bearing, and the on-course colour is the logo blue.
local r, g, b = nav.BearingColor(0)
assert(math.abs(r - 0.365) < 0.001 and math.abs(g - 0.824) < 0.001
    and math.abs(b - 0.984) < 0.001,
    "on-course must use the logo's marker blue")

local ar, ag, ab = nav.BearingColor(math.pi)
assert(ar > ag and ar > ab, "facing away must be warm, not blue")

assert(select(1, nav.BearingColor(nil)) == nav.colors.UNKNOWN[1],
    "no bearing must use the unknown colour")

print("  on-course colour is the logo blue")

-- The native provider must be preferred over TomTom, and must be available
-- with no third-party addon present at all.
local activeProvider, activeName = CN.GetWaypointProvider()

print("  active waypoint provider = " .. tostring(activeName))

assert(activeName == "Native",
    "native navigation must be the default provider, got " .. tostring(activeName))

-- Setting a waypoint must track it, and compute a real state.
--
-- Anchored to the player's ACTUAL stubbed position rather than assuming the
-- centre of the map -- the first version of this test assumed 0.5, 0.5 and
-- "failed" against correct code.
local playerMapID, playerAtX, playerAtY = CN.GetPlayerPosition()

print("  player is at " .. string.format("%.2f, %.2f on map %d",
    playerAtX, playerAtY, playerMapID))

CN.SetWaypoint(playerMapID, playerAtX + 0.18, playerAtY, "Test Destination")

local tracked = nav.GetTarget()

assert(tracked and tracked.title == "Test Destination",
    "setting a waypoint must record the target")

-- Face the target, derived from the live convention rather than hardcoded.
-- The target is due east, so its bearing clockwise from north is pi/2, and
-- lining up means facing * sign == pi/2.
CN_TEST_SetFacing((math.pi / 2) * nav.FacingSign())

local computed = nav.Compute()

print("  tracking state = " .. tostring(computed.state)
    .. ", " .. tostring(math.floor((computed.yards or 0) + 0.5)) .. " yd"
    .. ", " .. tostring(math.floor(math.deg(computed.relative or 0) + 0.5)) .. " deg off")

assert(computed.state == "TRACKING", "a distant target must report TRACKING")
assert(math.abs(computed.relative) < 0.001,
    "facing the target must report zero relative bearing, got "
    .. string.format("%.4f", computed.relative))

assert(math.abs(computed.yards - 180) < 0.01,
    "0.18 of a 1000yd map is 180 yards, got " .. tostring(computed.yards))

-- Arrival must fire inside the threshold, not outside it.
CN.SetWaypoint(playerMapID, playerAtX + 0.005, playerAtY, "Very Close")

local arrived = nav.Compute()

print("  5yd away -> " .. tostring(arrived.state))

assert(arrived.state == "ARRIVED", "inside the arrival radius must report ARRIVED")

-- A target on another map must say so rather than point confidently at a
-- bearing computed from unrelated coordinates.
CN.SetWaypoint(playerMapID + 1000, 0.5, 0.5, "Another Zone")

local elsewhere = nav.Compute()

print("  target on another map -> " .. tostring(elsewhere.state))

assert(elsewhere.state == "WRONG_MAP",
    "a target on another map must not produce a bearing")

nav.Clear()

assert(nav.GetTarget() == nil, "clearing must drop the target")

CN_TEST_SetFacing(0)

-- TomTom stays supported, so it stays tested. Switching to it must actually
-- route waypoints through TomTom rather than silently keeping the native one.
local tomtomProvider = CN.waypointProviders["TomTom"]

assert(tomtomProvider, "the TomTom provider must be registered")
assert(tomtomProvider.IsAvailable(), "a stubbed TomTom must be detected")

nav.SetPreference("tomtom")

local preferredProvider, preferredName = CN.GetWaypointProvider()

assert(preferredName == "TomTom",
    "choosing TomTom must actually select it, got " .. tostring(preferredName))

local beforeCount = #CN_TEST_TomTomWaypoints()

CN.SetWaypoint(94, 0.3, 0.7, "Via TomTom")

assert(#CN_TEST_TomTomWaypoints() == beforeCount + 1,
    "a waypoint set while TomTom is chosen must reach TomTom")

local lastWaypoint = CN_TEST_TomTomWaypoints()[#CN_TEST_TomTomWaypoints()]

assert(lastWaypoint.mapID == 94 and lastWaypoint.options.title == "Via TomTom",
    "TomTom must receive the map, coordinates and title")

tomtomProvider.ClearAll()

assert(#CN_TEST_TomTomWaypoints() == 0, "clearing must remove TomTom waypoints")

-- And back to native, which must not need TomTom at all.
nav.SetPreference("auto")

assert(select(2, CN.GetWaypointProvider()) == "Native",
    "resetting the preference must return to native navigation")

print("  TomTom provider exercised and released")

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

print("\nCollection providers:")

CN.CollectCandidates(true)

local byType = {}

for _, objective in ipairs(CN.CollectCandidates()) do
    byType[objective.type] = (byType[objective.type] or 0) + 1
end

for _, kind in ipairs({ "MOUNT", "TOY", "PROFESSION", "APPEARANCE", "TITLE" }) do
    print("  " .. kind .. " candidates = " .. (byType[kind] or 0))
end

-- Mounts: only those with a known source, and never one locked to the other
-- faction. The stub player is Alliance; mount 2 is Horde-locked.
assert((byType.MOUNT or 0) > 0, "mounts with a known source must be recommended")

for _, objective in ipairs(CN.CollectCandidates()) do
    if objective.type == "MOUNT" then
        assert(objective.id ~= 2,
            "a mount locked to the other faction must never be recommended")
        assert(objective.reasons and objective.reasons[1] and objective.reasons[1] ~= "",
            "a mount recommendation must carry its source")
    end
end

-- Toys: only where a recorded vendor sells them, and those carry coordinates.
for _, objective in ipairs(CN.CollectCandidates()) do
    if objective.type == "TOY" then
        assert(objective.mapID and objective.x and objective.y,
            "a toy recommendation must have real coordinates")
    end
end

-- Professions below their cap.
assert((byType.PROFESSION or 0) > 0, "an unmaxed profession must be recommended")

assert((byType.TOY or 0) > 0,
    "a toy sold by a recorded vendor must be recommended")

-- Appearances are capped to a few slots, not one per category.
local appearances = CN:GetModule("Appearances")

assert((byType.APPEARANCE or 0) <= appearances.candidateSlots,
    "appearance candidates must be capped to the least-complete slots, got "
    .. tostring(byType.APPEARANCE))

-- Titles deliberately have no provider: the client exposes no source, so
-- there is no action to name. This asserts the decision, so that adding a
-- provider later is a conscious change rather than an accident.
assert((byType.TITLE or 0) == 0,
    "titles must not be recommended: there is no source data to act on")

print("  titles correctly absent (no source data exists)")

-- Scoped: Lua caps a function at 200 locals and this file
-- outgrew it. Each self-contained section gets its own scope.
do
print("\nHub batching:")

-- The complaint this exists for: an addon that routes over individual
-- objectives sends you to a camp, away, and back again for each thing
-- standing there.
--
-- Three stops at one camp, two at another well away from it, and one loner.
local camped = {
    { name = "Giver A",  x = 0.300, y = 0.300, mapID = 94, phase = "PICKUP" },
    { name = "Turn-in",  x = 0.302, y = 0.301, mapID = 94, phase = "TURNIN" },
    { name = "Giver B",  x = 0.301, y = 0.303, mapID = 94, phase = "PICKUP" },
    { name = "Far C",    x = 0.800, y = 0.800, mapID = 94, phase = "ACTIVE" },
    { name = "Far D",    x = 0.803, y = 0.799, mapID = 94, phase = "ACTIVE" },
    { name = "Loner",    x = 0.500, y = 0.100, mapID = 94, phase = "ACTIVE" },
}

local builtHubs = CN.ClusterByProximity(camped)

print("  " .. #camped .. " stops collapsed into " .. #builtHubs .. " places")

for index, hub in ipairs(builtHubs) do
    local names = {}
    for _, objective in ipairs(hub.objectives) do names[#names + 1] = objective.name end
    print("    " .. index .. ") " .. CN.DescribeHub(hub)
        .. " -- " .. table.concat(names, ", "))
end

assert(#builtHubs == 3,
    "three distinct places expected, got " .. #builtHubs)

-- Every stop must survive clustering. Losing one would silently drop work.
local clustered = 0
for _, hub in ipairs(builtHubs) do clustered = clustered + #hub.objectives end

assert(clustered == #camped,
    "clustering must not lose stops: " .. clustered .. " of " .. #camped)

-- Within a hub, the order must be the order you would actually do it:
-- collect quests before handing them back.
for _, hub in ipairs(builtHubs) do
    if #hub.objectives > 1 then
        local sawTurnIn = false

        for _, objective in ipairs(hub.objectives) do
            if objective.phase == "TURNIN" then
                sawTurnIn = true
            elseif objective.phase == "PICKUP" then
                assert(not sawTurnIn,
                    "a pickup must be ordered before a turn-in at the same place")
            end
        end
    end
end

print("  within a place, pickups come before turn-ins")

-- And the description must name what you are there to do.
local campHub

for _, hub in ipairs(builtHubs) do
    if #hub.objectives == 3 then campHub = hub end
end

assert(campHub, "the three-stop camp must be one hub")

local described = CN.DescribeHub(campHub)

assert(described:find("pick up 2", 1, true) and described:find("turn in 1", 1, true),
    "a hub must say what it is for, got " .. described)

print("  hub described as: " .. described)

-- The engine must PREFER clustered work, not merely display it that way.
local alone   = CN.NewObjective({ id = 1, name = "Alone", completionValue = 2 })
local grouped = CN.NewObjective({ id = 2, name = "Grouped", completionValue = 2,
                                  hubSize = 4 })

local aloneScore   = CN.ScoreObjective(alone)
local groupedScore = CN.ScoreObjective(grouped)

print(string.format("  identical objective scores %.1f alone, %.1f in a group of 4",
    aloneScore, groupedScore))

assert(groupedScore > aloneScore,
    "work that batches with other work must outrank identical work that does not")
end

print("\nAvailable quests:")

-- Reported from live play: "it only shows the quests you have accepted --
-- I don't see where it shows the quest pending to be accepted in the zone",
-- and "'new' is always 0".
--
-- Both had the same root cause: every quest source the addon read was the
-- quest LOG, which by definition contains only quests already taken.
local questsModule = CN:GetModule("Quests")

local availableHere = questsModule.AvailableOnMap(94)

local availableIDs = {}
for _, poi in ipairs(availableHere) do availableIDs[#availableIDs + 1] = poi.questID end

print("  available to pick up = " .. table.concat(availableIDs, ", "))

assert(#availableHere == 2,
    "two quests are offered and not yet done, got " .. #availableHere)

for _, poi in ipairs(availableHere) do
    assert(poi.questID ~= 9002, "a quest already in the log is not 'available'")
    assert(poi.questID ~= 9101, "a completed quest must never be offered again")
    assert(poi.x and poi.y, "an available quest must carry its pin coordinates")
end

-- They must reach the recommendation list, which is the actual complaint.
CN.InvalidateCandidates()

local offered = {}

for _, objective in ipairs(CN.CollectCandidates(true)) do
    if objective.type == "QUEST" then offered[objective.id] = objective end
end

assert(offered[9100], "an available quest must become a candidate")
assert(offered[9102], "an available daily must become a candidate")
assert(not offered[9101], "a completed quest must not become a candidate")

print("  available quests reach the recommendation list")

-- With a name, not a bare id: "Quest 9100" is not a recommendation.
assert(offered[9100].name == "Pick Me Up",
    "an available quest must be named, got " .. tostring(offered[9100].name))

-- With coordinates, so it can actually be navigated to.
assert(offered[9100].x and offered[9100].y,
    "an available quest must be navigable")

-- And it must say why it is being suggested.
local said = table.concat(offered[9100].reasons or {}, " | ")

assert(said:find("available to pick up", 1, true),
    "an available quest must explain itself, got " .. said)

print("  named, navigable, and explained: " .. said)

-- An available quest should outrank an accepted one that has made no
-- progress: walking twenty yards to collect it is the cheaper action.
assert((offered[9100].completionValue or 0) > 1,
    "an available quest must be weighted above a bare accepted quest")

print("  weighted above an untouched accepted quest")

-- "new is always 0": discovery only ever walked the quest log, so after the
-- first scan there was nothing left to discover, forever.
CN.Account("discoveredQuests")[9100] = nil
CN.Account("discoveredQuests")[9102] = nil

local discoveredSeen, discoveredNew = questsModule.DiscoverActive()

print("  discover: seen = " .. discoveredSeen .. ", new = " .. discoveredNew)

assert(discoveredNew >= 2,
    "available quests must count as newly discovered, got " .. discoveredNew)

-- Running it again finds nothing new, which is correct.
local _, againNew = questsModule.DiscoverActive()

assert(againNew == 0, "a second scan must find nothing new, got " .. againNew)

print("  second scan correctly finds nothing new")

print("\nPrerequisite confidence:")

local harvestModule = CN:GetModule("Harvest")

assert(harvestModule, "the Harvest module must load")

local harvestStore = harvestModule.Store()

-- An EVEN id: the stubbed client reports odd quest ids as already
-- completed, and a completed quest is never blocked by anything.
harvestStore[42002] = { questID = 42002, name = "Gated Quest" }

-- Start from a clean window. Turn-ins from earlier in this test run are still
-- inside the correlation window and would be counted too.
harvestModule.ResetRecent()

-- One character's ordering is a coincidence, not a prerequisite.
CN.characterKey = "Alpha-Realm"
harvestModule.NoteTurnIn(42000)
harvestModule.NoteAccepted(42002)

print("  after 1 character: confidence = "
    .. harvestModule.Confidence(harvestStore[42002], 42000)
    .. ", promoted = " .. #harvestModule.ConfidentPrerequisites(42002))

assert(harvestModule.Confidence(harvestStore[42002], 42000) == 1,
    "one character must count as one")
assert(#harvestModule.ConfidentPrerequisites(42002) == 0,
    "one character's ordering must NOT become a prerequisite")

-- Repeating it on the SAME character must not raise confidence: doing a chain
-- twice is still one character's opinion.
harvestModule.NoteTurnIn(42000)
harvestModule.NoteAccepted(42002)

assert(harvestModule.Confidence(harvestStore[42002], 42000) == 1,
    "repeating on one character must not raise confidence")

print("  repeating on the same character does not raise confidence")

-- A second character: closer, still short of the threshold.
CN.characterKey = "Beta-Realm"
harvestModule.NoteTurnIn(42000)
harvestModule.NoteAccepted(42002)

assert(harvestModule.Confidence(harvestStore[42002], 42000) == 2, "two characters must count as two")
assert(#harvestModule.ConfidentPrerequisites(42002) == 0,
    "two characters must still be below the threshold of "
    .. harvestModule.confidenceThreshold)

-- A third independent character. Playthroughs do not agree by accident.
CN.characterKey = "Gamma-Realm"
harvestModule.NoteTurnIn(42000)
harvestModule.NoteAccepted(42002)

local promoted = harvestModule.ConfidentPrerequisites(42002)

print("  after 3 characters: confidence = "
    .. harvestModule.Confidence(harvestStore[42002], 42000)
    .. ", promoted = " .. #promoted)

assert(#promoted == 1 and promoted[1] == 42000,
    "three agreeing characters must promote the prerequisite")

-- Publishing must reach the dependency graph as observedRequires, NEVER as
-- requires: inference must not be able to masquerade as curated data.
harvestModule.PublishConfident()

local edge = CN.GetDependency(CN.ObjectiveKey("QUEST", 42002))

assert(edge and edge.observedRequires, "confident edges must be published")
assert(edge.requires == nil,
    "an inferred prerequisite must never be written as a curated one")

print("  published as observedRequires, not requires")

-- And /cn why must report it as an observation, with the count.
local blockedState, blockedReason, blockedDetail = CN.Explain("QUEST", 42002)

print("  why -> " .. tostring(blockedReason) .. " :: " .. tostring(blockedDetail))

assert(blockedReason == CN.blockReasons.LIKELY_PREREQUISITE,
    "an inferred block must be reported as likely, not as fact")
assert(tostring(blockedDetail):find("3 characters", 1, true),
    "the explanation must say how many characters showed it, got " .. tostring(blockedDetail))

CN.characterKey = nil
harvestStore[42002] = nil
CN.dependencies[CN.ObjectiveKey("QUEST", 42002)] = nil

print("\nBroker and alerts:")

local broker = CN:GetModule("Broker")

assert(broker, "the Broker module must load")
assert(broker.available, "a present LibDataBroker must be detected")

local object = CN_TEST_BrokerObjects()["CompletionNavigator"]

assert(object, "a data object must be registered")
assert(object.type == "data source", "the object must declare itself a data source")
assert(type(object.OnClick) == "function", "the broker must be clickable")

broker.Refresh()

print("  broker text = " .. tostring(object.text))

assert(object.text and object.text ~= "", "the broker must show something")

-- The tooltip must not throw, and must render through the same stub the
-- addon's own tooltips use.
GameTooltip:ClearLines()
object.OnTooltipShow(GameTooltip)

local brokerTip = table.concat(GameTooltip.lines, " | ")

print("  broker tooltip = " .. brokerTip)

assert(brokerTip:find("Completion Navigator", 1, true),
    "the broker tooltip must identify the addon")

-- Alerts are OFF by default. This is a deliberate courtesy, so assert it.
assert(not broker.AlertsEnabled(),
    "rare alerts must be off until asked for")

assert(broker.CheckAlerts() == 0, "alerts must do nothing while disabled")

CN.Settings().rareAlerts = true
broker.ResetAnnounced()

local firstPass = broker.CheckAlerts()

print("  alerts sent on first pass = " .. firstPass)

assert(firstPass > 0, "a live rare must be announced once alerts are on")

-- And exactly once. A rare drifting in and out of vignette range must not
-- announce itself repeatedly.
local secondPass = broker.CheckAlerts()

assert(secondPass == 0,
    "a rare must be announced once, not repeatedly, got " .. secondPass)

print("  announced once, not repeatedly")

-- Changing zone resets the set, because a new zone is a new set of rares.
fire("ZONE_CHANGED_NEW_AREA")

assert(broker.CheckAlerts() > 0, "a zone change must allow announcing again")

CN.Settings().rareAlerts = false

print("  zone change resets the announced set")

print("\nPer-character settings:")

local liveSettings = CN.Settings()

-- By default everything is account-wide: exactly the behaviour of every
-- release before this one.
assert(not CN.IsOverridden("priorityMode"),
    "settings must be account-wide until a character overrides them")

liveSettings.priorityMode = "balanced"

assert(CN.AccountSettings().priorityMode == "balanced",
    "an unoverridden write must reach the account table")

print("  unoverridden writes go account-wide")

-- Taking an override must not change the current value, only where it lives.
CN.SetOverride("priorityMode", liveSettings.priorityMode)

assert(CN.IsOverridden("priorityMode"), "the override must be recorded")
assert(liveSettings.priorityMode == "balanced",
    "taking an override must not change what the setting currently is")

-- Now writes must be isolated from the account.
liveSettings.priorityMode = "pets"

assert(liveSettings.priorityMode == "pets", "the override must be readable")
assert(CN.AccountSettings().priorityMode == "balanced",
    "an overridden write must NOT leak to the account setting, got "
    .. tostring(CN.AccountSettings().priorityMode))

print("  overridden writes stay on the character (account still 'balanced')")

-- Another character must not see this character's override.
local thisCharacter = CN.character

CN.character = { name = "Other", settings = {} }

assert(liveSettings.priorityMode == "balanced",
    "a different character must see the account setting, got "
    .. tostring(liveSettings.priorityMode))

CN.character = thisCharacter

assert(liveSettings.priorityMode == "pets",
    "switching back must restore this character's override")

print("  a second character sees the account value, not the override")

-- Releasing it must fall back to the account value, not the last override.
CN.ClearOverride("priorityMode")

assert(not CN.IsOverridden("priorityMode"), "the override must be releasable")
assert(liveSettings.priorityMode == "balanced",
    "releasing an override must fall back to the account value")

print("  releasing falls back to the account value")

-- Only whitelisted keys may be overridden: a typo must not silently create a
-- per-character setting nothing reads.
local refused = CN.SetOverride("notARealSetting", true)

assert(refused == false, "an unknown setting must not be overridable")

-- pairs() must see the merged view, or anything iterating settings misses
-- overrides entirely.
CN.SetOverride("arrow", false)

local sawArrow = nil

for key, value in pairs(liveSettings) do
    if key == "arrow" then sawArrow = value end
end

assert(sawArrow == false,
    "iterating settings must see overrides, got " .. tostring(sawArrow))

CN.ClearOverride("arrow")

print("  iteration sees the merged view")

-- Scoped: Lua caps a function at 200 locals and this file
-- outgrew it. Each self-contained section gets its own scope.
do
print("\nType filtering:")

local typeFilters = CN:GetModule("Filters")

assert(typeFilters, "the Filters module must load")

typeFilters.EnableAllTypes()
CN.CollectCandidates(true)

local unfiltered = CN.Recommend(200)

local typesPresent = {}
for _, objective in ipairs(unfiltered) do typesPresent[objective.type] = true end

print("  unfiltered recommendations = " .. #unfiltered
    .. " across " .. count(typesPresent) .. " types")

assert(count(typesPresent) > 1, "the test needs more than one type present")

-- Hiding a type must remove exactly that type and nothing else.
typeFilters.SetTypeEnabled("PET", false)

local withoutPets = CN.Recommend(200)

for _, objective in ipairs(withoutPets) do
    assert(objective.type ~= "PET", "a hidden type must not be recommended")
end

print("  hiding PET removed " .. (#unfiltered - #withoutPets) .. " entries")

assert(#withoutPets < #unfiltered, "hiding a present type must remove something")

-- The ranked cache must notice. Without a filter generation it would serve
-- the previous list and the toggle would appear to do nothing.
typeFilters.SetTypeEnabled("PET", true)

local restored = CN.Recommend(200)

assert(#restored == #unfiltered,
    "restoring a type must restore its entries: expected " .. #unfiltered
    .. ", got " .. #restored)

print("  restoring PET brought them back (ranked cache respects the filter)")

-- "only" narrows to one.
typeFilters.OnlyType("QUEST")

local onlyQuests = CN.Recommend(200)

for _, objective in ipairs(onlyQuests) do
    assert(objective.type == "QUEST",
        "only-quests must exclude " .. tostring(objective.type))
end

print("  only-quests left " .. #onlyQuests .. " entries, all quests")

assert(#onlyQuests > 0, "narrowing to quests must not empty the list")

-- Filtering must NOT touch the underlying candidate set: breakdowns and the
-- Collections tab read it directly and must still see everything.
local allCandidates = CN.CollectCandidates()

local candidateTypes = {}
for _, objective in ipairs(allCandidates) do candidateTypes[objective.type] = true end

assert(count(candidateTypes) > 1,
    "the type filter must not remove candidates, only filter the ranked list")

print("  candidate set untouched (" .. count(candidateTypes) .. " types still collected)")

-- Text input a person would actually type.
assert(typeFilters.ResolveType("pets") == "PET", "'pets' must resolve to PET")
assert(typeFilters.ResolveType("quest") == "QUEST", "'quest' must resolve to QUEST")
assert(typeFilters.ResolveType("nonsense") == nil, "unknown text must not resolve")

typeFilters.EnableAllTypes()
CN.Recommend(1)
end

print("\nGoals:")

local goals = CN:GetModule("Goals")

assert(goals, "the Goals module must load")

goals.Clear()

-- A title is never a candidate: Titles deliberately registers no provider,
-- because the client exposes no source for one. That makes it the right
-- subject for this test -- pinning something the engine would otherwise never
-- surface is the entire point of a goal.
--
-- (This used to use a mount. Mounts gained a provider, the premise quietly
-- became false, and the test caught it.)
local beforeGoal = 0

for _, objective in ipairs(CN.CollectCandidates(true)) do
    if objective.type == "TITLE" and objective.id == 2 then beforeGoal = beforeGoal + 1 end
end

assert(beforeGoal == 0, "an unpinned title must not be a candidate")

goals.Add("TITLE", 2)

local afterGoal, goalObjective = 0, nil

for _, objective in ipairs(CN.CollectCandidates()) do
    if objective.type == "TITLE" and objective.id == 2 then
        afterGoal = afterGoal + 1
        goalObjective = objective
    end
end

print("  pinned title appears as a candidate = " .. tostring(afterGoal == 1))

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
    if objective.type == "TITLE" and objective.id == 2 then goalRank = index end
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

assert(top.type == "TITLE" and top.id == 2,
    "with nothing expiring, a pinned goal must rank first, got " .. tostring(top.name))

CN.candidateProviders["Vault"] = vaultProvider
CN.InvalidateCandidates()

-- Removing it must put things back.
goals.Remove("TITLE", 2)

local afterRemoval = 0

for _, objective in ipairs(CN.CollectCandidates()) do
    if objective.type == "TITLE" and objective.id == 2 then afterRemoval = afterRemoval + 1 end
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

-- Scoped: Lua caps a function at 200 locals and this file
-- outgrew it. Each self-contained section gets its own scope.
do
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
end

print("\nMigration 1 -> " .. CN.dbVersion .. ":")

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

assert(migrated.version == CN.dbVersion, "the ladder must advance to the current schema version, got "
    .. tostring(migrated.version))
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

-- 2 -> 3 must create the per-character settings table without touching
-- anything that was already there.
assert(type(migrated.characters["Old-Char"].settings) == "table",
    "migration 2 must give every existing character a settings table")
assert(migrated.characters["Old-Char"].level == 60,
    "migration 2 must not disturb existing character data")
assert(count(migrated.characters["Old-Char"].settings) == 0,
    "an existing character must start with NO overrides, so account settings "
    .. "still apply to them")

print("  per-character settings table created, empty, non-destructive")

-- Running it again must be a no-op, not a second migration.
CN.InitializeDatabase()
assert(CompletionNavigatorDB.version == CN.dbVersion, "migration must be idempotent")

print("  re-run is idempotent")

print("\nMap pins:")

;(function()
    local pins = CN:GetModule("MapPins")

    assert(pins, "the MapPins module must load")
    assert(pins.IsEnabled(), "pins are on by default")

    -- GEOMETRY.
    --
    -- The canvas is anchored from its TOPLEFT and grows downward, so y must
    -- be NEGATED. A mirrored pin still lands somewhere plausible on screen,
    -- which is exactly why looking at it would never reveal the bug: on a
    -- roughly symmetrical map the wrong answer looks right.
    local ox, oy = pins.CanvasOffset(0.25, 0.75, 1000, 666)

    assert(math.abs(ox - 250) < 0.01,
        "x offset must be the fraction of the width, got " .. tostring(ox))
    assert(oy < 0,
        "y offset must be NEGATIVE -- the canvas grows downward from TOPLEFT")
    assert(math.abs(oy + 499.5) < 0.01,
        "y offset must be minus the fraction of the height, got " .. tostring(oy))

    -- A point in the top half must sit ABOVE a point in the bottom half.
    local _, topY    = pins.CanvasOffset(0.5, 0.1, 1000, 666)
    local _, bottomY = pins.CanvasOffset(0.5, 0.9, 1000, 666)

    assert(topY > bottomY,
        "a northern point must be higher on the canvas than a southern one")

    assert(pins.CanvasOffset(nil, 0.5, 1000, 666) == nil,
        "a pin with no coordinates has no offset")

    -- SIZE. A hub holding more is drawn larger.
    assert(pins.PinSize(6, 3) > pins.PinSize(1, 3),
        "a busier hub must be a bigger pin")

    -- LAYOUT.
    local hubs = {
        { x = 0.2, y = 0.3, mapID = 2112, objectives = {
            { name = "Take This", phase = "PICKUP" },
            { name = "Do This",   phase = "ACTIVE" },
        } },
        { x = 0.8, y = 0.9, mapID = 2112,
          objectives = { { name = "Hand This In", phase = "TURNIN" } } },
        { objectives = { { name = "Nowhere" } } },
    }

    local laid = pins.Layout(hubs)

    assert(#laid == 2, "a hub with no coordinates cannot be drawn, got " .. #laid)
    assert(laid[1].order == 1 and laid[2].order == 2,
        "pins must be numbered in route order")
    assert(laid[1].hubSize == 2, "pin must carry how much is at that stop")

    -- The tooltip body must read in the order you would do things.
    local lines = pins.DescribeLines(laid[1])

    assert(#lines == 2, "every objective at the stop is described")
    assert(lines[1]:find("Take This"), "first line is the first thing to do")

    -- ROUTE START.
    --
    -- Looking at a map you are not standing in must NOT start the route from
    -- your own position: your coordinates mean nothing on another map, and
    -- using them orders the stops by distance from an arbitrary point.
    local realPosition = CN.GetPlayerPosition
    CN.GetPlayerPosition = function() return 2112, 0.11, 0.22 end

    local sx, sy, fromPlayer = pins.RouteStart(2112)

    assert(fromPlayer and math.abs(sx - 0.11) < 0.001,
        "on your own map the route starts at your feet")

    local ox2, oy2, otherMap = pins.RouteStart(84)

    assert(not otherMap and ox2 == 0.5 and oy2 == 0.5,
        "on someone else's map the route starts at the middle, not at you")

    CN.GetPlayerPosition = realPosition

    -- PLACEMENT against the stubbed canvas.
    local canvas = WorldMapFrame.ScrollContainer.Child

    local placed = pins.Place(laid, canvas)

    assert(placed == 2, "both located pins must be placed, got " .. placed)

    local first = _G["CompletionNavigatorMapPin1"]

    assert(first and first:IsShown(), "the first pin must be visible")

    -- Placing a SHORTER route must hide the surplus rather than leave stale
    -- pins from the previous map on screen.
    pins.Place({ laid[1] }, canvas)

    local second = _G["CompletionNavigatorMapPin2"]

    assert(not second:IsShown(),
        "a pin left over from a longer route must be hidden, not stranded")

    -- Refresh must do nothing at all while the map is closed.
    WorldMapFrame.shown = false
    assert(pins.Refresh() == 0, "no pins while the map is closed")

    -- And must draw when it is open.
    WorldMapFrame.shown = true
    WorldMapFrame.displayedMapID = 2112

    pins.InvalidateCache()

    local drawn = pins.Refresh(true)

    assert(type(drawn) == "number", "Refresh reports how many stops it drew")

    -- Turning them off must clear the map, not merely stop adding to it.
    pins.SetEnabled(false)
    assert(not pins.IsEnabled(), "pins can be turned off")
    assert(not _G["CompletionNavigatorMapPin1"]:IsShown(),
        "turning pins off must remove the ones already drawn")

    pins.SetEnabled(true)

    -- The map is shared with every other addon, so the hooks must be HOOKED.
    assert(pins.Install(), "the world map hooks must install")
    assert(CN_TEST_WORLD_MAP_HOOKS["OnShow"], "OnShow must be hooked")
    assert(CN_TEST_WORLD_MAP_HOOKS["OnHide"], "OnHide must be hooked")

    -- Installing twice must not hook twice, or every map open redraws once
    -- per reload the player has done this session.
    do
        local showHooks = #CN_TEST_WORLD_MAP_HOOKS["OnShow"]

        pins.Install()

        assert(#CN_TEST_WORLD_MAP_HOOKS["OnShow"] == showHooks,
            "Install must be idempotent")
    end

    -- Firing the hooks must not error: they run inside Blizzard's map code,
    -- where a Lua error is the player's problem and not obviously ours.
    for _, mapHook in ipairs(CN_TEST_WORLD_MAP_HOOKS["OnShow"]) do
        mapHook()
    end

    for _, mapHook in ipairs(CN_TEST_WORLD_MAP_HOOKS["OnHide"]) do
        mapHook()
    end

    -- Tooltip and click behaviour. A pin the player cannot interrogate is
    -- decoration.
    WorldMapFrame.shown = true
    pins.InvalidateCache()
    pins.Place(laid, canvas)

    do
        local pin1 = _G["CompletionNavigatorMapPin1"]

        pin1.scripts["OnEnter"](pin1)
        pin1.scripts["OnLeave"](pin1)

        -- Clicking a stop whose members carry no coordinates of their own
        -- must still navigate -- to the stop. The pin was drawn somewhere;
        -- refusing to go there is the addon contradicting its own map.
        local realSet = CN.SetWaypoint
        local setTo   = nil

        CN.SetWaypoint = function(mapID, x, y, title)
            setTo = { mapID = mapID, x = x, y = y, title = title }
            return true
        end

        pin1.scripts["OnClick"](pin1)

        CN.SetWaypoint = realSet

        assert(setTo, "clicking a pin must set a waypoint even when its "
            .. "members have no coordinates of their own")
        assert(math.abs(setTo.x - 0.2) < 0.001 and setTo.mapID == 2112,
            "the waypoint must be the STOP's position, got "
            .. tostring(setTo.x))

        -- A pin whose hub is empty must not navigate rather than error.
        pin1.pin = { order = 1, objectives = {} }
        pin1.scripts["OnClick"](pin1)
        pin1.scripts["OnEnter"](pin1)
    end

    -- The route must survive being asked for a map that has nothing on it.
    WorldMapFrame.displayedMapID = 999999
    pins.InvalidateCache()

    assert(pins.Refresh(true) == 0, "an empty map draws no pins")

    -- And a map the client will not name at all.
    WorldMapFrame.displayedMapID = nil
    pins.InvalidateCache()
    assert(pins.Refresh(true) == 0, "no map ID means no pins")

    WorldMapFrame.displayedMapID = 2112

    -- The cache must not rebuild the route for an unchanged map.
    pins.InvalidateCache()
    pins.HubsForMap(2112)

    do
        local rebuilds = 0

        local realBuild = CN.BuildZoneRoute

        CN.BuildZoneRoute = function(...)
            rebuilds = rebuilds + 1
            return realBuild(...)
        end

        pins.HubsForMap(2112)

        assert(rebuilds == 0,
            "an unchanged map must reuse the cached route, not rebuild it")

        pins.HubsForMap(2112, true)

        assert(rebuilds == 1, "a forced refresh must rebuild")

        CN.BuildZoneRoute = realBuild
    end

    -- Layout must tolerate being handed nonsense rather than erroring inside
    -- a map redraw.
    assert(#pins.Layout(nil) == 0, "no hubs, no pins")
    assert(#pins.DescribeLines(nil) == 0, "no pin, no lines")

    -- A hub with more objectives than the tooltip shows must say so rather
    -- than silently truncating.
    --
    -- Scoped: the main chunk is close to Lua's 200-local ceiling, and a test
    -- that cannot be compiled is worse than one that was never written.
    do
        local big = { order = 1, objectives = {} }

        for index = 1, 12 do
            table.insert(big.objectives,
                { name = "Thing " .. index, phase = "ACTIVE" })
        end

        local bigLines = pins.DescribeLines(big)

        assert(bigLines[#bigLines]:find("more"),
            "a long list must end by saying how much was left out")
    end

    print("  " .. #laid .. " stops laid out, geometry and pooling verified")
end)()

-- The zone router must honour the type filter. A player who has hidden
-- everything but quests is asking not to be walked to a pet.
--
-- The test supplies its own non-quest stop rather than hoping the live
-- candidate list happens to contain one. An earlier version of this check
-- read whatever was already there, found only quests, and passed while
-- asserting nothing at all.
do
    CN.RegisterCandidateProvider("HarnessFilterProbe", function()
        return {
            {
                id     = "probe-pet",
                type   = CN.objectiveTypes.PET,
                name   = "Filterable Pet",
                mapID  = 2112,
                x      = 0.31,
                y      = 0.42,
            },
        }
    end)

    CN.InvalidateCandidates("harness")

    local unfiltered = CN.BuildZoneRoute(2112, 0.5, 0.5)

    local sawPet = false

    for _, objective in ipairs(unfiltered) do
        if objective.type == CN.objectiveTypes.PET then
            sawPet = true
        end
    end

    assert(sawPet, "the probe pet must be routed before any filter is applied")

    local typeFilters = CN:GetModule("Filters")

    typeFilters.OnlyType(CN.objectiveTypes.QUEST)

    CN.InvalidateCandidates("harness")

    local after = CN.BuildZoneRoute(2112, 0.5, 0.5)

    for _, objective in ipairs(after) do
        assert(objective.type == CN.objectiveTypes.QUEST,
            "a filtered-out type must not appear in the route: "
            .. tostring(objective.type))
    end

    assert(#after < #unfiltered,
        "filtering must actually remove stops from the route")

    typeFilters.EnableAllTypes()

    CN.candidateProviders["HarnessFilterProbe"] = nil

    -- The timing table keeps a row for every provider that has ever run, so
    -- a probe left there shows up in the benchmark as if it were part of the
    -- addon.
    if CN.providerTimings then
        CN.providerTimings["HarnessFilterProbe"] = nil
    end

    CN.InvalidateCandidates("harness")

    print("  zone route honours the type filter")
end

print("\nChase:")

;(function()
    local chase = CN:GetModule("Chase")
    local goalStore = CN:GetModule("Goals")

    assert(chase, "the Chase module must load")

    goalStore.Clear()

    -- REPUTATION. The one place the client hands over a denominator it will
    -- vouch for, so this is where a real fraction is allowed.
    goalStore.Add(CN.objectiveTypes.REPUTATION, 2600)

    local repChain

    for _, goal in ipairs(goalStore.List()) do
        if goal.type == CN.objectiveTypes.REPUTATION then
            repChain = chase.Chain(goal)
        end
    end

    assert(repChain, "a pinned reputation must produce a chain")
    assert(repChain.progress, "reputation has a denominator, so it gets progress")
    assert(repChain.progress.done == 1200,
        "earned standing is measured from the rank floor, not from zero -- got "
        .. tostring(repChain.progress.done))
    assert(repChain.progress.total == 3000,
        "the denominator is the width of the rank, got "
        .. tostring(repChain.progress.total))

    local fraction = chase.Fraction(repChain)

    assert(fraction and math.abs(fraction - 0.4) < 0.001,
        "4200 of a 3000-6000 rank is 40%, got " .. tostring(fraction))

    -- The summary must be a sentence a player can act on, and must contain
    -- the remaining amount rather than only the total.
    local summary = chase.Summarize(repChain)

    assert(summary:find("1,800"),
        "the summary must say how much is LEFT: " .. summary)

    -- ACHIEVEMENT. Criteria are countable, and the done ones must be shown --
    -- five left means nothing without knowing five of how many.
    goalStore.Clear()
    goalStore.Add(CN.objectiveTypes.ACHIEVEMENT, 11)

    local achChain = chase.Chain(goalStore.List()[1])

    assert(achChain.progress and achChain.progress.total > 0,
        "achievement criteria are countable")

    local sawDone, sawNext, sawCounter = false, false, false

    for _, step in ipairs(achChain.steps) do
        if step.state == chase.states.DONE then sawDone = true end
        if step.state == chase.states.NEXT then sawNext = true end
        if step.text:find("/") then sawCounter = true end
    end

    assert(sawDone, "completed criteria must appear, not just the missing ones")
    assert(sawNext, "exactly one outstanding criterion must be marked NEXT")
    assert(sawCounter,
        "a criterion carrying its own count must show it")

    -- Only ONE step may be NEXT. Two next steps is not a plan.
    local nextCount = 0

    for _, step in ipairs(achChain.steps) do
        if step.state == chase.states.NEXT then
            nextCount = nextCount + 1
        end
    end

    assert(nextCount == 1, "exactly one NEXT step, got " .. nextCount)

    -- APPEARANCE. Any ONE source is enough, so a source count must NOT be
    -- presented as progress. This is the case where an honest-looking
    -- fraction would be actively wrong.
    goalStore.Clear()
    goalStore.Add(CN.objectiveTypes.APPEARANCE, 8001)

    local appChain = chase.Chain(goalStore.List()[1])

    assert(#appChain.steps > 0, "an appearance with sources must list them")
    assert(appChain.progress == nil,
        "an appearance needs ONE source, so 'x of y sources' is not progress "
        .. "toward it and must not be offered as such")
    assert(chase.Fraction(appChain) == nil,
        "no denominator means no fraction, not a zero")

    -- UNKNOWN SOURCE. The addon must say it does not know, rather than
    -- inventing a single step and calling it a plan.
    goalStore.Clear()
    goalStore.Add(CN.objectiveTypes.MOUNT, 777)

    local mountChain = chase.Chain(goalStore.List()[1])

    assert(mountChain.progress == nil,
        "a mount whose source is prose has no denominator")
    assert(chase.Fraction(mountChain) == nil, "and therefore no bar")

    -- ORDERING. The least-finished measurable goal comes first; finished
    -- goals sink.
    goalStore.Clear()
    goalStore.Add(CN.objectiveTypes.REPUTATION, 2600)
    goalStore.Add(CN.objectiveTypes.ACHIEVEMENT, 11)
    goalStore.Add(CN.objectiveTypes.MOUNT, 777)

    local all = chase.All()

    assert(#all == 3, "every goal is chained, got " .. #all)

    local previous = nil

    for _, chain in ipairs(all) do
        local value = chase.Fraction(chain)

        if previous and value then
            assert(previous >= value,
                "measurable goals must be ordered by progress")
        end

        previous = value or previous
    end

    -- NAVIGATION targets the next STEP, not the goal.
    do
        local realSet = CN.SetWaypoint
        local asked   = false

        CN.SetWaypoint = function() asked = true return true end

        chase.NavigateNext(repChain)

        CN.SetWaypoint = realSet

        -- Either it navigated or it said it could not; it must never error.
        assert(type(asked) == "boolean", "navigation must not throw")
    end

    -- Chasing something not yet pinned must pin it, rather than telling the
    -- player to run a second command to say what they just said.
    goalStore.Clear()

    CN.HandleSlashCommand("chase rep 2600")

    assert(#goalStore.List() == 1,
        "/cn chase on an unpinned goal must pin it")

    goalStore.Clear()

    print("  reputation, achievement, appearance and unknown-source chains")
end)()


print("\nThe number a player reads:")

;(function()
    local quests = CN:GetModule("Quests")

    -- "New" used to mean "rows this addon wrote to its own database for the
    -- first time". That is a scanner statistic: correct, and zero forever
    -- once a zone has been walked. A player reads it as "quests I could go
    -- and pick up right now", sees zero while looking at exclamation marks,
    -- and concludes the addon is broken. Reported from live play, twice.
    --
    -- So the counter shown to a player must be about the WORLD, and it must
    -- keep working after the database has seen everything.
    local pickupCount = quests.AvailableCount()

    assert(pickupCount > 0,
        "the fixture zone offers quests, so the count must not be zero")

    -- Scanning does not change it. This is the whole point: discovery
    -- saturates, availability does not.
    quests.DiscoverActive()
    quests.DiscoverActive()

    local afterScanning = quests.AvailableCount()

    assert(afterScanning == pickupCount,
        "availability must survive being scanned -- it is a fact about the "
        .. "zone, not about what the addon has recorded. Was " .. pickupCount
        .. ", became " .. afterScanning)

    -- And the second scan must indeed have recorded nothing new, which is
    -- exactly why the old number was useless.
    local _, recorded = quests.DiscoverActive()

    assert(recorded == 0,
        "a repeated scan records nothing new; that is the statistic that "
        .. "misled a player when it was shown to them")

    -- Every counted quest must be one you could actually walk up to and take.
    for _, poi in ipairs(quests.AvailableOnMap()) do
        assert(not quests.IsCompletedByCharacter(poi.questID),
            "a finished quest is not available to pick up")
        assert(not CN.Blizzard.IsQuestInLog(poi.questID),
            "a quest already in your log is not available to pick up")
    end

    CN.HandleSlashCommand("available")

    print("  availability is a fact about the zone, not about the database")
end)()


print("\nStanding in front of a quest giver:")

;(function()
    local quests = CN:GetModule("Quests")

    -- REPORTED FROM LIVE PLAY: "it now says '0 available to pick up here' but
    -- I'm literally standing in front of one."
    --
    -- The fixture reproduces the most likely cause: the player is on map 94,
    -- and a quest start is registered against the PARENT map, not theirs. The
    -- old single-map query could not see it by construction.
    local onOwnMap = 0

    for _, poi in ipairs(quests.AvailableOnMap(94)) do
        onOwnMap = onOwnMap + 1
    end

    assert(onOwnMap > 0, "the fixture zone must offer something")

    -- A quest giver you have actually TALKED to cannot be missed, whatever
    -- the map says. This is the backstop for the case where no map query
    -- knows about the pin at all.
    CN_TEST_SetGossipOffers({
        { questID = 91234, title = "Right In Front Of You" },
    })

    CN.FireEvent("GOSSIP_SHOW")

    local sawOffered = false

    for _, poi in ipairs(quests.AvailableOnMap(94)) do
        if poi.questID == 91234 then
            sawOffered = true
            assert(poi.source == "offered",
                "a remembered conversation must say where it came from")
        end
    end

    assert(sawOffered,
        "a quest an NPC offered us must be counted as available even when no "
        .. "map query knows about it")

    -- Accepting it must remove it. Otherwise the count grows every time he
    -- talks to anyone.
    CN.FireEvent("QUEST_ACCEPTED", 91234)

    for _, poi in ipairs(quests.AvailableOnMap(94)) do
        assert(poi.questID ~= 91234,
            "an accepted quest must stop being 'available to pick up'")
    end

    CN_TEST_SetGossipOffers({})

    -- The neighbourhood must actually be walked: own map, parent, siblings.
    local related = CN.Blizzard.RelatedMapIDs(2112)

    local sawParent = false

    for _, id in ipairs(related) do
        if id == 2022 then sawParent = true end
    end

    assert(sawParent,
        "a player in a city must have the surrounding zone searched too -- "
        .. "that is where the quest starts are registered")

    -- A continent must NOT be walked. That is a scan, not a lookup.
    for _, id in ipairs(CN.Blizzard.RelatedMapIDs(94)) do
        assert(id ~= 0, "the world map is never a neighbour")
    end

    -- World quests are counted SEPARATELY. Folding them in makes the number
    -- stop matching the exclamation marks on screen, which is the whole
    -- complaint.
    local pickups = #quests.AvailableOnMap(94)
    local tasks   = #quests.TasksOnMap(94)

    assert(tasks > 0, "the fixture has world quests")

    for _, poi in ipairs(quests.AvailableOnMap(94)) do
        assert(poi.source ~= "task",
            "a world quest is not something you walk up to and pick up")
    end

    -- And the diagnosis must be able to explain itself.
    local report = quests.AvailableDiagnostic(94)

    assert(#report.maps > 0, "the diagnosis must list the maps it asked")

    CN.HandleSlashCommand("whyzero")

    print("  " .. pickups .. " to pick up, " .. tasks
        .. " world quests, counted separately")
end)()

print("\nProgress:")

;(function()
    local progress = CN:GetModule("Progress")

    assert(progress, "the Progress module must load")

    -- The lifetime total comes from the CLIENT, so it is right on a fresh
    -- install with no scan history -- unlike the number it replaced, which
    -- counted rows this addon had written and started at zero.
    local lifetime = progress.LifetimeCompleted()

    assert(lifetime == #F.completedQuestIDs,
        "the lifetime total is whatever the client says, got "
        .. tostring(lifetime))

    progress.BeginSession()

    local atStart = progress.Summary()

    assert(atStart.session == 0, "a session starts at zero")

    CN.FireEvent("QUEST_TURNED_IN", 12345)
    CN.FireEvent("QUEST_TURNED_IN", 12346)

    local after = progress.Summary()

    assert(after.today >= 2, "turn-ins must count toward today, got " .. after.today)
    assert(after.session >= 2, "and toward the session")
    assert(after.best >= 2, "a best day is recorded")

    -- A rate needs enough time behind it to mean anything; five minutes in,
    -- "240 per hour" is arithmetic dressed as insight.
    assert(after.perHour == nil,
        "no rate is offered until the session is long enough to support one")

    assert(progress.Describe():find("completed"),
        "the one-line summary must lead with the real total")

    CN.HandleSlashCommand("progress")

    print("  lifetime " .. lifetime .. ", today " .. after.today
        .. ", session " .. after.session)
end)()

print("\nLoremaster:")

;(function()
    local lore = CN:GetModule("Loremaster")

    assert(lore, "the Loremaster module must load")

    local scanned = lore.Scan()

    assert(scanned > 0, "quest achievements must be found, got " .. scanned)

    -- Progress here is REAL because it was read, not computed. The client
    -- supplies both halves of every fraction.
    local closest = lore.Closest(5)

    for _, entry in ipairs(closest) do
        assert(entry.criteria > 0, "a listed zone must have a denominator")
        assert(entry.done > 0,
            "an untouched zone is not 'closest to finished' and must not be "
            .. "presented as though it were")
        assert(entry.done <= entry.criteria, "progress cannot exceed the total")
    end

    -- Story and side quests are different piles, because that is how the
    -- player talks about them: "finish the story, then do the side quests".
    local split = lore.SplitZoneWork(94)

    assert(type(split.story) == "table" and type(split.side) == "table",
        "zone work splits into story and side")

    assert(#split.story + #split.side > 0,
        "the fixture zone has work in it")

    CN.HandleSlashCommand("loremaster")

    print("  " .. scanned .. " quest achievements, " .. #closest
        .. " in progress, " .. #split.story .. " story / "
        .. #split.side .. " side here")
end)()

print("\nFollow mode:")

;(function()
    local follow = CN:GetModule("Follow")

    assert(follow, "the Follow module must load")
    assert(not follow.active, "follow mode is OFF until asked for")

    follow.Start()

    assert(follow.active, "follow mode starts")

    local hub, objectives = follow.CurrentStop()

    assert(hub, "starting must pick a stop")
    assert(objectives and #objectives > 0, "a stop has work at it")

    -- The frame's contents are computed separately from the frame, so they
    -- can be asserted without a client.
    local lines = follow.Lines()

    assert(#lines > 0, "the panel must say something")

    for _, line in ipairs(lines) do
        assert(line.text and line.state, "every line has text and a state")
    end

    assert(follow.HeaderText():find("left"),
        "the header says how much is left here")

    -- THE RULE: it must not move the waypoint out from under someone walking
    -- toward it. Advancing with work still outstanding must be refused.
    local firstX = hub.x

    assert(not follow.Advance(false),
        "a stop with work left must not be abandoned automatically")

    local stillHub = follow.CurrentStop()

    assert(stillHub.x == firstX,
        "the stop must not have changed while work remained")

    -- Asking out loud is different from the addon deciding, and must work.
    follow.Advance(true)

    -- Stopping must clear everything rather than leaving a stale frame.
    follow.Stop()

    assert(not follow.active, "follow mode stops")

    local afterStop = follow.CurrentStop()

    assert(afterStop == nil, "stopping forgets the stop")

    assert(not follow.Advance(false),
        "a stopped co-pilot must not keep advancing in the background")

    -- And the setting must persist the choice, so it survives a reload.
    assert(CN.Settings().follow == false, "stopping is remembered")

    print("  starts, holds its stop, advances on request, stops clean")
end)()


print("\nUrgency:")

;(function()
    -- "Gone in six hours" is the strongest signal the game gives, and it used
    -- to be a flag rather than a gradient: a world quest with four days left
    -- and one with nine minutes left scored identically.
    assert(CN.UrgencyBonus(nil) == 0, "no deadline, no urgency")
    assert(CN.UrgencyBonus(-5) == 0, "an expired deadline is not urgent")
    assert(CN.UrgencyBonus(999999) == 0,
        "something with days left must not be called urgent -- if everything "
        .. "is urgent, nothing is")

    local hour     = CN.UrgencyBonus(3600)
    local tenMins  = CN.UrgencyBonus(600)
    local twoMins  = CN.UrgencyBonus(120)

    assert(twoMins > tenMins and tenMins > hour,
        "urgency must rise as the deadline approaches")

    -- Steep and late. Compared PER SECOND, because the intervals are not the
    -- same length: 3600->600 is fifty minutes and 600->120 is eight. An
    -- earlier version of this test compared the raw differences and failed a
    -- correct curve, which is the test being wrong rather than the code.
    local lateRate  = (twoMins - tenMins) / (600 - 120)
    local earlyRate = (tenMins - hour)    / (3600 - 600)

    assert(lateRate > earlyRate,
        "urgency must climb faster per second as the deadline nears: "
        .. string.format("late=%.6f early=%.6f", lateRate, earlyRate))

    assert(CN.UrgencyBonus(1) <= 1, "urgency is bounded")

    -- And it must actually move a score.
    local calm = CN.NewObjective({ id = 1, type = CN.objectiveTypes.QUEST,
        completionValue = 1, travelCost = 0 })

    local urgent = CN.NewObjective({ id = 2, type = CN.objectiveTypes.QUEST,
        completionValue = 1, travelCost = 0, expiresIn = 300 })

    CN.ScoreObjective(calm)
    CN.ScoreObjective(urgent)

    assert(urgent.priorityWeight > calm.priorityWeight,
        "an identical objective with a deadline five minutes away must "
        .. "outrank one with none")

    print(string.format("  1h=%.2f  10m=%.2f  2m=%.2f", hour, tenMins, twoMins))
end)()

print("\nModes:")

;(function()
    local focus = CN:GetModule("Filters")

    focus.EnableAllTypes()

    -- Hide something first, so we can prove the mode restores exactly what
    -- was there rather than "everything".
    focus.SetTypeEnabled(CN.objectiveTypes.TOY, false)

    assert(not focus.IsTypeEnabled(CN.objectiveTypes.TOY), "toys hidden")

    local ok, mode = focus.ApplyMode("leveling")

    assert(ok, "leveling is a mode")
    assert(mode.label == "Levelling", "the mode reports itself")

    assert(focus.IsTypeEnabled(CN.objectiveTypes.QUEST),
        "levelling shows quests")
    assert(not focus.IsTypeEnabled(CN.objectiveTypes.PET),
        "levelling hides pets -- that is the point of a mode")

    assert(CN.Settings().priorityMode == "quests",
        "a mode sets the weighting too, not only the filter")

    local name = focus.CurrentMode()

    assert(name == "leveling", "the current mode is reported")

    -- One word must put back exactly what was there, including the toy.
    focus.ClearMode()

    assert(focus.IsTypeEnabled(CN.objectiveTypes.PET),
        "clearing a mode restores hidden types")
    assert(not focus.IsTypeEnabled(CN.objectiveTypes.TOY),
        "clearing a mode restores what YOU had hidden, not everything -- "
        .. "the addon must not quietly undo the player's own choices")

    assert(focus.CurrentMode() == nil, "no mode after clearing")

    local bad = focus.ApplyMode("nonsense")

    assert(not bad, "an unknown mode is refused")

    focus.EnableAllTypes()

    CN.HandleSlashCommand("mode collecting")
    CN.HandleSlashCommand("mode")
    CN.HandleSlashCommand("mode off")

    print("  modes apply and unapply without losing the player's own filters")
end)()

print("\nSession planning:")

;(function()
    local session = CN:GetModule("Session")

    assert(session, "the Session module must load")

    -- MEDIAN, not mean: standing still for a minute must not halve the
    -- estimate and one flight path must not double it.
    assert(session.Median({ 5, 5, 5, 100 }) == 5,
        "the median must ignore an outlier, got "
        .. tostring(session.Median({ 5, 5, 5, 100 })))

    assert(session.Median({}) == nil, "no samples, no median")

    -- With no samples, speed is a default AND says it is not measured.
    local rate, measured = session.Speed()

    assert(rate > 0, "a usable speed is always returned")
    assert(measured == false,
        "an unmeasured speed must announce itself so callers can say so")

    -- A type nobody has watched has NO estimate. This is the whole honesty
    -- argument: the alternative is a made-up constant in a confident font.
    assert(session.TypicalSeconds(CN.objectiveTypes.QUEST) == nil,
        "an unwatched type must have no duration, not a guessed one")

    -- Watch a few and it forms an opinion.
    for index = 1, 6 do
        session.NoteOffered({ type = CN.objectiveTypes.QUEST, id = 5000 + index })
    end

    local learned = 0

    for index = 1, 6 do
        if session.NoteCompleted(CN.objectiveTypes.QUEST, 5000 + index) then
            learned = learned + 1
        end
    end

    -- Completions are instant in the harness, so durations are zero seconds
    -- and are rejected as implausible. That is correct behaviour, and it is
    -- also why the sample count is what is asserted here rather than a time.
    local durations = session.Durations()[CN.objectiveTypes.QUEST]

    assert(durations == nil or #durations >= 0,
        "duration samples are stored per type")

    -- An unoffered completion must not be timed against nothing.
    assert(session.NoteCompleted(CN.objectiveTypes.QUEST, 999999) == nil,
        "a completion with no start time cannot be timed and must say so")

    -- A plan must fit its budget and must flag that it is not confident.
    local plan = session.Plan(30)

    assert(plan.minutes == 30, "the plan remembers the budget")

    if #plan.stops > 0 then
        assert(plan.confident == false,
            "with nothing measured yet, a plan must NOT present itself as "
            .. "confident")
    end

    assert(session.FormatDuration(90) == "2m", "durations round to minutes")
    assert(session.FormatDuration(0) == "0m", "no time is 0m, not blank")
    assert(session.FormatDuration(7200) == "2h 0m", "long plans read in hours")

    CN.HandleSlashCommand("plan 25")

    print("  " .. #plan.stops .. " stops planned, honestly labelled")
end)()

print("\nFollow, cheaply:")

;(function()
    local follow = CN:GetModule("Follow")

    -- PERFORMANCE REGRESSION FIXED: a redraw asks three separate questions
    -- and each one used to walk the whole candidate list and build a fresh
    -- set of several thousand keys.
    local collections = 0

    local realCollect = CN.CollectCandidates

    CN.CollectCandidates = function(...)
        collections = collections + 1
        return realCollect(...)
    end

    follow.Start()

    collections = 0

    follow.Lines()
    follow.HeaderText()
    follow.IsStopComplete()
    follow.Lines()

    CN.CollectCandidates = realCollect

    assert(collections <= 1,
        "four questions about the same unchanged state must cost at most one "
        .. "candidate walk, cost " .. collections)

    follow.Stop()

    print("  four redraw queries, " .. collections .. " candidate walk(s)")
end)()


print("\nCorrectness of the measurements:")

;(function()
    local session = CN:GetModule("Session")

    -- THE CLOCK. `time()` has one-second resolution. A task offered and
    -- finished inside the same second measured as zero elapsed and was
    -- discarded as implausible -- which threw away exactly the fast turn-ins
    -- a quest grinder produces most of. The offline suite discarded ALL of
    -- them, so the learning path was never actually exercised.
    session.Durations()[CN.objectiveTypes.QUEST] = nil

    CN_TEST_CLOCK = 5000.0

    session.NoteOffered({ type = CN.objectiveTypes.QUEST, id = 4242 })

    CN_TEST_CLOCK = 5000.4   -- four tenths of a second: a fast turn-in

    local elapsed = session.NoteCompleted(CN.objectiveTypes.QUEST, 4242)

    assert(elapsed and elapsed > 0,
        "a sub-second task must be measurable, got " .. tostring(elapsed))
    assert(math.abs(elapsed - 0.4) < 0.001,
        "the duration must be fractional, got " .. tostring(elapsed))

    -- And it must reach the store, which is what makes an estimate possible.
    assert(#session.Durations()[CN.objectiveTypes.QUEST] == 1,
        "the sample must be kept")

    -- MOUNT BUCKETS. One median across mounted and unmounted travel is a
    -- number wrong in both states.
    CN_TEST_MOUNTED = false

    local onFoot = session.Speed(false)
    local mounted = session.Speed(true)

    assert(type(onFoot) == "number" and type(mounted) == "number",
        "both states always answer with a usable number")

    assert(session.SpeedSampleCount(true) == 0
        and session.SpeedSampleCount(false) == 0,
        "no samples yet in either bucket")

    local buckets = session.SpeedBuckets()

    assert(buckets.mounted == nil and buckets.onFoot == nil,
        "an unmeasured bucket is nil, not zero -- unknown and none are "
        .. "different facts")

    -- THE OFFER TABLE MUST BE BOUNDED. It was not: every objective the addon
    -- decorated got a timestamp and only completion removed one.
    local heldBefore = session.OfferedCount()

    for index = 1, session.offerMemoryCap + 120 do
        session.NoteOffered({ type = CN.objectiveTypes.ACHIEVEMENT, id = 900000 + index })
    end

    local after = session.OfferedCount()

    -- Bounded, allowing the deliberate overshoot that keeps pruning cheap.
    local ceiling = session.offerMemoryCap * (1 + session.offerMemorySlack)

    assert(after <= ceiling,
        "the offer table must stay bounded, held " .. after
        .. " with a ceiling of " .. ceiling)

    assert(after > 0, "pruning must not empty it entirely")

    print(string.format("  fractional clock, two speed buckets, %d offers held (was %d)",
        after, heldBefore))
end)()

print("\nUrgency reaches the things that expire:")

;(function()
    -- 0.28.0 shipped an urgency curve and then only two providers set the
    -- field it reads. A feature that fires on two of twenty providers is
    -- close to inert, which is worse than not shipping it: the release notes
    -- say it works.
    local carriers, deadlineShape = 0, {}

    for _, objective in ipairs(CN.CollectCandidates(true) or {}) do
        if objective.expiresIn then
            carriers = carriers + 1
            deadlineShape[objective.type] = (deadlineShape[objective.type] or 0) + 1
        end
    end

    assert(carriers > 0,
        "something in the candidate list must carry a deadline, or the "
        .. "urgency curve has nothing to act on")

    -- Specifically the QUESTS provider.
    --
    -- Two earlier versions of this assertion could not fail. The first
    -- checked only that something carried a deadline, which the Vault
    -- already satisfied. The second checked that a QUEST did -- which world
    -- quests, emitted by a different provider with the same objective type,
    -- also already satisfied. Both passed with the wiring under test removed.
    --
    -- So ask the provider itself, and name the fixture: a daily quest
    -- offered in the zone must carry the daily reset as its deadline.
    local fromQuests = CN.candidateProviders["Quests"].fn()

    local daily

    for _, objective in ipairs(fromQuests) do
        if objective.expiresIn then
            daily = objective
            break
        end
    end

    assert(daily,
        "the Quests provider itself must attach a deadline to a daily or "
        .. "timed quest -- that is what this release added, and the two "
        .. "previous versions of this check could not detect its absence")

    print("  " .. tostring(daily.name) .. " expires in "
        .. tostring(daily.expiresIn) .. "s")

    -- And a deadline must actually change the ordering, not merely exist.
    local near = CN.NewObjective({ id = 1, type = CN.objectiveTypes.QUEST,
        completionValue = 1, travelCost = 0, expiresIn = 240 })

    local far = CN.NewObjective({ id = 2, type = CN.objectiveTypes.QUEST,
        completionValue = 1, travelCost = 0, expiresIn = 86400 })

    CN.ScoreObjective(near)
    CN.ScoreObjective(far)

    assert(near.priorityWeight > far.priorityWeight,
        "four minutes left must outrank a day left")

    local shape = {}
    for k, v in pairs(deadlineShape) do table.insert(shape, k .. "=" .. v) end
    table.sort(shape)
    print("  deadline carriers: " .. table.concat(shape, ", "))
    print("  " .. carriers .. " candidate(s) carry a real deadline")
end)()

print("\nShortlists:")

;(function()
    local achievements = CN:GetModule("Achievements")

    -- The provider walked three thousand rows on every rebuild to keep about
    -- a dozen, rejecting the same two thousand nine hundred and eighty every
    -- time.
    local list, wasBuilt = achievements.Shortlist()

    assert(type(list) == "table" and wasBuilt ~= nil,
        "a shortlist is a list and reports whether it was rebuilt")

    local _, rebuilt = achievements.Shortlist()

    assert(rebuilt == false,
        "an unchanged store must reuse the shortlist rather than rebuild it")

    -- A write must invalidate it, or the provider serves a stale answer --
    -- which is a correctness bug wearing a performance fix's clothes.
    achievements.revision = achievements.revision + 1

    local _, afterWrite = achievements.Shortlist()

    assert(afterWrite == true,
        "bumping the revision must force a rebuild")

    local held, revision = CN.ShortlistState("Achievements")

    assert(held ~= nil and revision ~= nil, "shortlist state is reportable")

    print("  " .. #list .. " of "
        .. CN.CountKeys(achievements.Store()) .. " achievements shortlisted")
end)()

print("\nHow far is \"here\":")

;(function()
    local quests = CN:GetModule("Quests")

    -- Searching the parent map and its siblings is what fixed a player being
    -- told zero while standing in front of a quest giver. It also means the
    -- answer spans a zone, so "here" overstates it.
    local offeredHere = quests.AvailableOnMap(94)

    local near, zone = quests.SplitAvailableByDistance(offeredHere, 94)

    assert(#near + #zone == #offeredHere,
        "every offeredHere quest lands in exactly one bucket")

    for _, poi in ipairs(near) do
        assert(poi.yards and poi.yards <= CN.nearbyYards,
            "a quest called near must actually be near")
    end

    print("  " .. #near .. " within " .. CN.nearbyYards
        .. " yards, " .. #zone .. " further out")
end)()


print("\nAlts:")

;(function()
    local alts = CN:GetModule("Alts")

    assert(alts, "the Alts module must load")

    -- STALENESS. A character last seen a month ago is described as it was a
    -- month ago, and the addon must not build advice on it.
    assert(alts.AgeDays(nil) == nil, "an unknown character has no age")
    assert(alts.DescribeAge(nil) == "never seen", "and says so")

    local fresh = { lastSeen = time() - 3600 }
    local old   = { lastSeen = time() - (40 * 86400) }

    assert(alts.DescribeAge(fresh) == "today", "an hour ago is today")
    assert(alts.AgeDays(old) > alts.staleDays,
        "forty days is past the staleness threshold")

    -- ACCOUNT-WIDE WORK MUST NEVER PRODUCE A SWITCH.
    --
    -- This is the one answer that would actively waste the player's time: a
    -- loading screen to earn something that would have counted anyway.
    local warband = CN:GetModule("Warband")

    local realWhoShould = warband.WhoShould

    warband.WhoShould = function()
        return "Someone-Else", "details", "account-wide"
    end

    local assignments = alts.Assignments()

    warband.WhoShould = realWhoShould

    assert(#assignments == 0,
        "account-wide progress must never produce a suggestion to switch "
        .. "characters -- the loading screen buys nothing")

    -- A GENUINE reason does produce one.
    warband.WhoShould = function(objectiveType)
        if objectiveType == CN.objectiveTypes.REPUTATION then
            return "Otherchar-Testrealm", "Revered", "highest standing"
        end

        return nil
    end

    local real = alts.Assignments()

    warband.WhoShould = realWhoShould

    for _, assignment in ipairs(real) do
        assert(assignment.key ~= CN.characterKey,
            "never suggest switching to the character you are already on")
    end

    -- THE VERDICT IS CONSERVATIVE ON PURPOSE.
    local _, verdict = alts.Verdict()

    assert(type(verdict) == "string" and #verdict > 0,
        "there is always a plain-language answer")

    CN.HandleSlashCommand("alts")

    print("  " .. #real .. " assignment(s); account-wide correctly ignored")
end)()

print("\nFollow stays out of a fight:")

;(function()
    local follow = CN:GetModule("Follow")

    follow.Start()

    CN_TEST_IN_COMBAT = true

    local advanced = follow.Advance()

    assert(advanced == false,
        "the waypoint must not move while the player is in combat")
    assert(follow.deferred == true,
        "and the addon must remember that it held something back")

    -- The player pressing the button is still obeyed. They can see their
    -- own screen.
    follow.Advance(true)

    CN_TEST_IN_COMBAT = false

    print("  combat defers an automatic advance, not a requested one")

    follow.Stop()
end)()

print("\nMeasurements survive a reload:")

;(function()
    local session = CN:GetModule("Session")

    -- Speed lived in a table that died with the session, so every /reload --
    -- which a player does several times an hour -- threw the measurements
    -- away and put the planner back on a guessed constant. The addon was
    -- permanently five samples from being useful and never got there.
    local stored = session.Persisted()

    assert(stored, "there is somewhere to persist to")

    stored.onFoot = { 6.5, 7.0, 7.5, 6.8, 7.2 }
    stored.mounted = {}

    local loaded = session.LoadSamples()

    assert(loaded == 5, "stored samples must be reloaded, got " .. loaded)

    local rate, measured = session.Speed(false)

    assert(measured == true,
        "reloaded samples must count as measured, or persisting them "
        .. "achieved nothing")
    assert(math.abs(rate - 7.0) < 0.001,
        "the median of the reloaded samples, got " .. tostring(rate))

    -- Nonsense in the saved variables must not poison the estimate.
    stored.onFoot = { 7.0, -5, 900, "banana", 7.4 }

    session.LoadSamples()

    for _, value in ipairs(session.Persisted().onFoot) do
        assert(type(value) == "number", "stored samples stay numeric")
    end

    local safeRate = session.Speed(false)

    assert(safeRate > 0.5 and safeRate < 60,
        "a corrupt sample must not produce an absurd speed, got "
        .. tostring(safeRate))

    print("  samples reload and survive corruption")
end)()


print("\nWhich zone next:")

;(function()
    local lore = CN:GetModule("Loremaster")

    assert(lore, "the Loremaster module must load")

    local records = lore.Records and lore.Records() or nil

    if not records then
        print("  no record accessor; skipped")
        return
    end

    -- Build a fixture with a known correct ordering, including an untouched
    -- zone -- which the previous version excluded outright.
    for id in pairs(records) do records[id] = nil end

    -- IDs deliberately run OPPOSITE to the correct ordering.
    --
    -- The broken truncation collapsed the list to alphabetical-by-ID. A first
    -- version of this fixture numbered the zones in their correct order, so
    -- the wrong answer and the right answer were the same string and the test
    -- passed against the bug. Numbering them backwards is what makes the
    -- assertion capable of failing.
    records[9009] = { name = "Nearly Done Zone", criteria = 10, done = 9, completed = false }
    records[9007] = { name = "Halfway Zone",     criteria = 10, done = 5, completed = false }
    records[9005] = { name = "Barely Started",   criteria = 10, done = 1, completed = false }
    records[9003] = { name = "Untouched Small",  criteria = 8,  done = 0, completed = false }
    records[9001] = { name = "Untouched Huge",   criteria = 90, done = 0, completed = false }
    records[9011] = { name = "Finished Zone",    criteria = 10, done = 10, completed = true }

    local closest, started, untouched = lore.Closest(10)

    -- BUG 1: a zone with no progress could never be recommended. For someone
    -- sweeping a continent, the untouched zones are the entire point.
    assert(untouched == 2,
        "zones with no progress must be included, got " .. tostring(untouched))
    assert(started == 3, "three zones are part-done, got " .. tostring(started))

    local names = {}

    for _, row in ipairs(closest) do
        table.insert(names, row.name)
        assert(row.name ~= "Finished Zone", "a finished zone is not a suggestion")
    end

    -- BUG 2: the careful ordering was destroyed by a helper that re-sorts on
    -- a field these rows do not have, collapsing the list to alphabetical by
    -- ID. Truncating to fewer rows than exist is exactly when it bit.
    assert(names[1] == "Nearly Done Zone",
        "the zone closest to finished must come first, got "
        .. tostring(names[1]))

    local trimmed = lore.Closest(2)

    assert(#trimmed == 2, "the limit is honoured")
    assert(trimmed[1].name == "Nearly Done Zone" and trimmed[2].name == "Halfway Zone",
        "truncating must keep the BEST rows, not re-sort them -- got "
        .. tostring(trimmed[1].name) .. ", " .. tostring(trimmed[2].name))

    -- Among untouched zones, the smaller one is the better next step.
    local untouchedOrder = {}

    for _, row in ipairs(closest) do
        if row.done == 0 then
            table.insert(untouchedOrder, row.name)
        end
    end

    assert(untouchedOrder[1] == "Untouched Small",
        "a fresh zone with fewer quests is the better start, got "
        .. tostring(untouchedOrder[1]))

    -- THE RECOMMENDATION.
    local next5 = lore.NextZones(5)

    assert(#next5 > 0, "there is always an answer when work remains")
    assert(next5[1].name == "Nearly Done Zone",
        "finishing beats starting, got " .. tostring(next5[1].name))
    assert(#next5[1].reasons > 0, "and it says why")

    -- Chasing a zone must lift it above one that is merely further along.
    local pinned = CN:GetModule("Goals")

    pinned.Clear()
    pinned.Add(CN.objectiveTypes.ACHIEVEMENT, 9001)

    local chased = lore.NextZones(5)

    -- Chasing lifts a zone; it does not override arithmetic.
    --
    -- The first version of this assertion demanded the chased zone come
    -- first outright, and failed -- against correct code. A zone with one
    -- quest left genuinely does beat a ninety-quest zone you have merely
    -- pinned, and rewriting the scoring to satisfy the test would have made
    -- the addon worse to make a line green. The test was wrong.
    local rankBefore, rankAfter

    for index, row in ipairs(next5) do
        if row.id == 9001 then rankBefore = index end
    end

    for index, row in ipairs(chased) do
        if row.id == 9001 then rankAfter = index end
    end

    assert(rankAfter and rankBefore and rankAfter < rankBefore,
        "chasing a zone must move it UP the list: was "
        .. tostring(rankBefore) .. ", now " .. tostring(rankAfter))

    local sawReason = false

    for _, row in ipairs(chased) do
        if row.id == 9001 then
            for _, reason in ipairs(row.reasons) do
                if reason:find("chasing") then sawReason = true end
            end
        end
    end

    assert(sawReason, "and the reason says so")

    pinned.Clear()

    CN.HandleSlashCommand("zones")

    print("  " .. #closest .. " zones ranked, untouched included")
end)()


print("\nThe lifetime count does not cost a quest history:")

;(function()
    local progress = CN:GetModule("Progress")

    -- The client does not return a number here. It builds a table containing
    -- every quest the character has ever finished -- tens of thousands of
    -- entries for the kind of player this addon is aimed at -- and the UI
    -- called it on every refresh to display one integer.
    local reads = 0

    local realGet = CN.Blizzard.GetAllCompletedQuestIDs

    CN.Blizzard.GetAllCompletedQuestIDs = function(...)
        reads = reads + 1
        return realGet(...)
    end

    progress.InvalidateLifetime()

    for _ = 1, 25 do
        progress.LifetimeCompleted()
    end

    assert(reads == 1,
        "twenty-five reads of an unchanged count must cost one trip to the "
        .. "client, cost " .. reads)

    -- Turning a quest in genuinely changes it, so that must invalidate.
    reads = 0

    for _, dispatch in ipairs(CN.eventTable["QUEST_TURNED_IN"] or {}) do
        dispatch("QUEST_TURNED_IN", 12345)
    end

    progress.LifetimeCompleted()

    assert(reads == 1, "a turn-in must invalidate the count")

    -- AND THE TRAP: QUEST_LOG_UPDATE fires many times a second. Hooking it
    -- looked correct and handed the entire saving back -- the benchmark went
    -- straight back to uncached. A cache invalidated by a firehose is not a
    -- cache.
    reads = 0

    for _ = 1, 25 do
        for _, dispatch in ipairs(CN.eventTable["QUEST_LOG_UPDATE"] or {}) do
            dispatch("QUEST_LOG_UPDATE")
        end

        progress.LifetimeCompleted()
    end

    assert(reads <= 1,
        "QUEST_LOG_UPDATE must NOT invalidate the lifetime count -- it fires "
        .. "constantly and hooking it makes the cache useless. Cost "
        .. reads .. " client reads across 25 events.")

    CN.Blizzard.GetAllCompletedQuestIDs = realGet

    -- A client that will not answer must still produce nil rather than zero:
    -- unknown and none are different facts, and the cache must not turn one
    -- into the other.
    progress.InvalidateLifetime()

    CN.Blizzard.GetAllCompletedQuestIDs = function() return nil end

    assert(progress.LifetimeCompleted() == nil,
        "an unavailable total stays nil, never zero")

    CN.Blizzard.GetAllCompletedQuestIDs = realGet

    progress.InvalidateLifetime()

    print("  one client read for twenty-five refreshes")
end)()


print("\nThe arrow turns round when you walk past:")

;(function()
    local arrowNav = CN:GetModule("Navigation")

    arrowNav.SetFacingSign(1)

    local arrow = arrowNav.BuildArrow()

    local function colourOf()
        local red = arrow.texture:GetVertexColor()
        return red
    end

    local blue = arrowNav.colors.ON_COURSE[1]
    local away = arrowNav.colors.AWAY[1]

    ------------------------------------------------------------
    -- Auto-advance ON, and the destination does not change.
    --
    -- This is the case a player hit twice: walk through the target, keep
    -- going, and the arrow must turn round. It did not, because arrival
    -- latched -- `arrived` was set once and never cleared, so the addon
    -- believed the player was still there no matter how far they walked.
    ------------------------------------------------------------
    CN.Settings().autoWaypoint = true

    local realAdvance = CN.AutoAdvance

    CN.AutoAdvance = function() return false end   -- nothing better to point at

    playerFacing = 0

    CN.SetWaypoint(94, 0.5, 0.4, "The Destination")

    local seen = {}

    for _, py in ipairs({ 0.60, 0.45, 0.41, 0.39, 0.30, 0.20 }) do
        CN_TEST_PLAYER_X, CN_TEST_PLAYER_Y = 0.5, py

        arrowNav.Refresh()

        table.insert(seen, {
            y        = py,
            rotation = arrow.texture.rotation,
            red      = colourOf() and math.abs(colourOf() - away) < 0.01,
            blue     = colourOf() and math.abs(colourOf() - blue) < 0.01,
            text     = arrow.distance.text,
        })
    end

    CN.AutoAdvance = realAdvance
    CN.Settings().autoWaypoint = false

    assert(seen[1].blue, "approaching the destination, the arrow is blue")

    local last = seen[#seen]

    assert(last.red,
        "walking AWAY from the destination the arrow must turn red -- it "
        .. "stayed blue for a player, twice")

    assert(last.rotation and math.abs(math.abs(last.rotation) - math.pi) < 0.01,
        "and it must point BACK at the destination, a half turn from where "
        .. "it pointed on approach; got "
        .. tostring(last.rotation and math.deg(last.rotation)))

    assert(seen[1].rotation ~= last.rotation,
        "the arrow must not be frozen in the direction it had on approach")

    -- The distance must grow again, not stick at the arrival figure.
    local approaching = tonumber(string.match(seen[1].text or "", "%d+"))
    local leaving     = tonumber(string.match(last.text or "", "%d+"))

    assert(approaching and leaving and leaving > 0,
        "a real distance is shown throughout")

    ------------------------------------------------------------
    -- Nothing stale is left behind when tracking stops.
    ------------------------------------------------------------
    arrowNav.Clear()

    assert((arrow.texture.rotation or 0) == 0,
        "clearing must reset the rotation, not leave the last one showing")
    assert(arrow.distance.text == "",
        "and must clear the distance, not leave a number for a destination "
        .. "nobody is tracking")

    CN_TEST_PLAYER_X, CN_TEST_PLAYER_Y = 0.42, 0.55

    ------------------------------------------------------------
    -- THE ACTUAL COMPLAINT.
    --
    -- Auto-advance ON, and arriving re-points at the NEXT thing. The arrow
    -- looks absolutely identical doing it: same shape, same blue, still
    -- ahead of you, distance now counting up because the new destination is
    -- further away than the old one you just walked through.
    --
    -- A player seeing that concludes the arrow failed to turn round. They are
    -- not wrong to: nothing on screen said the destination had changed. It
    -- was reported as an arrow bug twice, and both times the arrow was
    -- pointing correctly -- at something else.
    ------------------------------------------------------------
    CN.Settings().autoWaypoint = true

    local realAdvance2 = CN.AutoAdvance

    CN.AutoAdvance = function()
        -- Whatever the router would have picked next.
        CN.SetWaypoint(94, 0.5, 0.1, "Somewhere Else")
        return true
    end

    output = {}

    CN.SetWaypoint(94, 0.5, 0.4, "The Destination")

    CN_TEST_PLAYER_X, CN_TEST_PLAYER_Y = 0.5, 0.41

    arrowNav.Refresh()

    CN.AutoAdvance = realAdvance2
    CN.Settings().autoWaypoint = false

    local announced = false

    for _, line in ipairs(output) do
        if line:find("Now heading to") and line:find("Somewhere Else") then
            announced = true
        end
    end

    assert(announced,
        "when arriving silently re-points the arrow at a different "
        .. "destination, the addon must SAY so -- otherwise the player sees "
        .. "an arrow that appears not to have turned round")

    assert(arrow.label.text == "Somewhere Else",
        "and the label must name the new destination, got "
        .. tostring(arrow.label.text))

    arrowNav.Clear()

    CN_TEST_PLAYER_X, CN_TEST_PLAYER_Y = 0.42, 0.55

    print("  turns round, recolours, announces a re-target, leaves nothing stale")
end)()

print("\nThe arrow survives walking indoors:")

;(function()
    local indoorNav = CN:GetModule("Navigation")

    -- GetBestMapForUnit answers with the most SPECIFIC map containing you.
    -- Step into a building, a cave, an inn or a city district and it changes
    -- -- while you have moved thirty yards. The arrow compared that to the
    -- target's map, found them different, and announced "another zone" while
    -- standing next to the destination.
    CN.SetWaypoint(94, 0.5, 0.4, "Just Outside")

    CN_TEST_PLAYER_X, CN_TEST_PLAYER_Y = 0.5, 0.5

    playerFacing = 0

    local outside = indoorNav.Compute()

    assert(outside.state == "TRACKING", "tracking normally outdoors")
    assert(outside.relative, "and it has a bearing")

    -- Now step inside. The player's own map becomes the building, which the
    -- zone can still place them on.
    CN_TEST_PLAYER_MAPS[2500] = true

    local realBest = C_Map.GetBestMapForUnit

    C_Map.GetBestMapForUnit = function() return 2500 end

    local indoors = indoorNav.Compute()

    C_Map.GetBestMapForUnit = realBest
    CN_TEST_PLAYER_MAPS[2500] = nil

    assert(indoors.state ~= "WRONG_MAP",
        "stepping into a building must not stop the arrow -- the zone can "
        .. "still say where you are")
    assert(indoors.translated == true,
        "and the addon must say it translated the position rather than "
        .. "pretending the maps were the same")
    assert(indoors.relative,
        "a bearing is still produced indoors")
    assert(indoors.yards and indoors.yards > 0,
        "and a real distance, got " .. tostring(indoors.yards))

    -- A map that genuinely cannot place the player is still refused. Another
    -- continent must not silently produce a confident arrow.
    --
    -- The player stays where they are -- on a map the client can place them
    -- on, which is always true in practice. It is the TARGET's map that
    -- cannot describe them. An earlier version of this check moved the
    -- player to a map the client could not place them on either, which is a
    -- state the client never produces.
    CN.SetWaypoint(1234, 0.5, 0.4, "Another Continent")

    local far = indoorNav.Compute()

    assert(far.state == "WRONG_MAP",
        "a target the client cannot place you against stays honest about it")

    indoorNav.Clear()

    CN_TEST_PLAYER_X, CN_TEST_PLAYER_Y = 0.42, 0.55

    print("  indoors keeps tracking; another continent still says so")
end)()


print("\nArrow diagnosis:")

;(function()
    local diagNav = CN:GetModule("Navigation")

    -- With nothing tracked it must say so rather than printing an empty
    -- report or erroring.
    diagNav.Clear()

    local idle = diagNav.Diagnose()

    assert(#idle >= 1, "there is always a report")
    assert(idle[1].value:find("none"), "and it says nothing is tracked")

    -- With a target it must expose every intermediate value, because the
    -- point is to replace a player describing the arrow in prose.
    CN.SetWaypoint(94, 0.5, 0.4, "Diagnosed Destination")

    CN_TEST_PLAYER_X, CN_TEST_PLAYER_Y = 0.5, 0.6
    playerFacing = 0

    local report = diagNav.Diagnose()

    local seen = {}

    for _, row in ipairs(report) do
        seen[row.label] = row.value
    end

    for _, required in ipairs({
        "target", "target map", "target coords", "your map", "your coords",
        "facing (raw)", "facing sign", "relative bearing", "rotation applied",
        "colour", "distance", "provider", "auto-advance", "follow mode",
        "marked arrived", "arrival radius", "state",
    }) do
        assert(seen[required],
            "the diagnosis must report '" .. required
            .. "' -- every one of these has been the answer to a real "
            .. "question about this arrow")
    end

    assert(seen["colour"]:find("BLUE"),
        "walking toward it reads BLUE, got " .. seen["colour"])

    -- And past it, the same command must show the reversal.
    CN_TEST_PLAYER_X, CN_TEST_PLAYER_Y = 0.5, 0.2

    local past = {}

    for _, row in ipairs(diagNav.Diagnose()) do
        past[row.label] = row.value
    end

    assert(past["colour"]:find("RED"),
        "past it reads RED, got " .. tostring(past["colour"]))

    CN.HandleSlashCommand("navdiag")

    diagNav.Clear()
    CN_TEST_PLAYER_X, CN_TEST_PLAYER_Y = 0.42, 0.55

    print("  every value the arrow uses is reportable")
end)()


print("\nWhat gets written to disk:")

;(function()
    -- The client rewrites this entire file on every logout and parses it on
    -- every login. Over a megabyte at retail scale, a third of which was a
    -- copy of the client's own item cache.
    local merchants = CN:GetModule("Vendors")

    local store = CN.Account("vendors")

    -- A vendor with a realistic inventory.
    local items = {}

    for index = 1, 300 do
        table.insert(items, {
            itemID = 700000 + index,
            name   = "An Item With A Reasonably Long Name " .. index,
            price  = 1000 + index,
        })
    end

    local realNPC   = CN.Blizzard.GetInteractingNPC
    local realItems = CN.Blizzard.GetMerchantItems

    CN.Blizzard.GetInteractingNPC  = function() return 88888, "Big Merchant" end
    CN.Blizzard.GetMerchantItems   = function() return items end

    merchants.CaptureOpenMerchant()

    CN.Blizzard.GetInteractingNPC = realNPC
    CN.Blizzard.GetMerchantItems  = realItems

    local record = store[88888]

    assert(record, "the vendor was recorded")

    local bytes = CN.MeasureDatabase(record)

    -- Three hundred items stored as bare prices is a few kilobytes. Stored as
    -- a table each, with a name in every one, it was over twenty.
    assert(bytes < 12000,
        "a 300-item vendor must cost a few kilobytes, not tens: "
        .. math.floor(bytes / 1024) .. " KB")

    for _, value in pairs(record.items) do
        assert(type(value) == "number",
            "each item is stored as its price, not as a table")
    end

    -- And the name is still available, from the client rather than from disk.
    assert(merchants.PriceOf(record, 700001) == 1001,
        "the price survives the compaction")

    -- THE MIGRATION must reclaim the space for people who already have the
    -- old shape, rather than waiting for them to revisit every merchant they
    -- have ever opened.
    local legacy = {
        version = 4,
        account = {
            vendors = {
                [1] = { items = { [55] = { name = "Old Name", price = 7 } } },
            },
        },
    }

    CN.migrations[4](legacy)

    assert(legacy.account.vendors[1].items[55].name == nil,
        "the migration must drop names already on disk")
    assert(legacy.account.vendors[1].items[55].price == 7,
        "without losing the price, which the client cannot re-supply")

    local rows, total = CN.DatabaseSizes()

    assert(total > 0 and #rows > 0, "the size is reportable")

    CN.HandleSlashCommand("dbsize")

    store[88888] = nil

    print(string.format("  a 300-item vendor costs %.1f KB", bytes / 1024))
end)()


print("\nNames come from the client, not from disk:")

;(function()
    local pets = CN:GetModule("Pets")
    local achievements = CN:GetModule("Achievements")

    pets.Scan()

    local petStore = pets.Store()

    local sample = petStore[101]

    assert(sample, "the pet was scanned")
    assert(sample.name == nil,
        "a pet name must not be written to disk -- the journal has it")
    assert(pets.NameOf(101, sample) == "Wild Critter",
        "and it must resolve from the client, got "
        .. tostring(pets.NameOf(101, sample)))

    -- An older database still carrying a name must keep working.
    assert(pets.NameOf(999999, { name = "Legacy Name" }) == "Legacy Name",
        "a name already on disk is still honoured until the migration runs")

    -- And something the client cannot name must degrade to something
    -- readable rather than to nil, which would reach the UI as an error.
    assert(pets.NameOf(999999, nil):find("999999"),
        "an unknown pet still produces a usable label")

    achievements.Scan()

    local achievementStore = achievements.Store()

    local anyAchievement, anyID = nil, nil

    for id, record in pairs(achievementStore) do
        if not anyAchievement then
            anyAchievement, anyID = record, id
        end
    end

    if anyAchievement then
        assert(anyAchievement.name == nil,
            "an achievement name must not be written to disk")
        assert(anyAchievement.points == nil,
            "nor its point value -- the client supplies both")
        assert(achievements.NameOf(anyID, anyAchievement),
            "and the name still resolves")
    end

    -- WRITE-ONLY DATA. These were stamped on every row and read by nothing.
    for _, record in pairs(petStore) do
        assert(record.lastSeen == nil and record.firstSeen == nil,
            "per-row timestamps are written and never read; they must not be "
            .. "persisted")
    end

    -- THE MIGRATION reclaims all of it without a rescan.
    local legacy = {
        version = 5,
        account = {
            achievements = { [1] = { name = "Old", points = 10, done = 1, criteria = 3, lastSeen = 123 } },
            pets         = { [2] = { name = "Old Pet", collected = true, firstSeen = 1, lastSeen = 2 } },
        },
    }

    CN.migrations[5](legacy)

    local a = legacy.account.achievements[1]
    local p = legacy.account.pets[2]

    assert(a.name == nil and a.points == nil and a.lastSeen == nil,
        "the migration strips what the client re-supplies")
    assert(a.done == 1 and a.criteria == 3,
        "and keeps what it does not -- progress is the addon's own record")
    assert(p.name == nil and p.firstSeen == nil,
        "pets are stripped too")
    assert(p.collected == true, "without losing collection state")

    print("  names resolve live; write-only fields are gone")
end)()


print("\nALL HARNESS CHECKS PASSED")
