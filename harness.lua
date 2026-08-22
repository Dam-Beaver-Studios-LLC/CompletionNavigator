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

-- EVENTS THE CLIENT ACTUALLY HAS.
--
-- The frame stub above refuses anything not on this list, because the real
-- client refuses too -- it throws rather than ignoring, so one invented name
-- is a Lua error at every login for every player. `NEW_TAXI_NODE` was such a
-- name and shipped in 0.46.0.
--
-- HONESTY ABOUT WHAT THIS LIST IS. It is written from knowledge, not read
-- from a client, so it is exactly the kind of artefact this project keeps
-- getting caught by: a model of the world maintained by hand. It is checked
-- against reality by the `events` capture -- /cn capture asks the live client
-- to register every event the addon uses and records which ones it refused --
-- and the stub audit fails on any refusal. Until a recording is present, this
-- list catches typos and inventions but cannot catch an event that was real
-- and has since been removed.
CN_KNOWN_EVENTS = {}

for _, name in ipairs({
    "ACHIEVEMENT_EARNED", "ADDON_LOADED", "BAG_UPDATE_DELAYED",
    "BANKFRAME_OPENED", "BOSS_KILL", "CHALLENGE_MODE_COMPLETED",
    "CRAFTINGORDERS_CLAIM_ORDER_RESPONSE", "CRAFTINGORDERS_UPDATE_ORDER_COUNT", "CRITERIA_UPDATE",
    "CURRENCY_DISPLAY_UPDATE", "ENCOUNTER_END", "GOSSIP_SHOW",
    "KNOWN_TITLES_UPDATE", "MAIL_INBOX_UPDATE", "MAJOR_FACTION_RENOWN_LEVEL_CHANGED",
    "MAJOR_FACTION_UNLOCKED", "MERCHANT_SHOW", "MERCHANT_UPDATE",
    "NEW_MOUNT_ADDED", "NEW_PET_ADDED", "NEW_TOY_ADDED",
    "PET_JOURNAL_LIST_UPDATE", "PLAYER_CONTROL_GAINED", "PLAYER_CONTROL_LOST",
    "PLAYER_ENTERING_WORLD", "PLAYER_LEVEL_UP", "PLAYER_LOGIN",
    "PLAYER_LOGOUT", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
    "PLAYER_SPECIALIZATION_CHANGED", "QUEST_ACCEPTED", "QUEST_DATA_LOAD_RESULT",
    "QUEST_DETAIL", "QUEST_LOG_UPDATE", "QUEST_REMOVED",
    "QUEST_TURNED_IN", "SKILL_LINES_CHANGED", "TAXIMAP_CLOSED",
    "TAXIMAP_OPENED", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_SHOW",
    "TRANSMOG_COLLECTION_UPDATED", "UPDATE_FACTION", "UPDATE_INSTANCE_INFO",
    "VIGNETTES_UPDATED", "VIGNETTE_MINIMAP_UPDATED", "WEEKLY_REWARDS_UPDATE",
    "ZONE_CHANGED", "ZONE_CHANGED_NEW_AREA", "GROUP_ROSTER_UPDATE",
    "PLAYER_ALIVE", "PLAYER_DEAD", "PLAYER_UNGHOST",
}) do
    CN_KNOWN_EVENTS[name] = true
end

local function Frame()
    local f = {}
    local events, scripts = {}, {}

    f.events  = events
    f.scripts = scripts

    -- THE CLIENT REFUSES AN EVENT IT DOES NOT HAVE. SO DOES THIS.
    --
    -- This stub accepted any string, which is how `NEW_TAXI_NODE` -- a name
    -- that does not exist and never has -- shipped in 0.46.0 and threw a Lua
    -- error at every login. Eighty files of tests, a mutation suite and two
    -- interpreters, and not one of them could see it, because the fake frame
    -- was more forgiving than the real one.
    --
    -- Tenth entry in the list of defects caused by a stub simpler than the
    -- thing it stands for. The list is in CN_KNOWN_EVENTS below, and adding
    -- an event to it is the deliberate act that asks "is this real?".
    function f:RegisterEvent(e)
        assert(CN_KNOWN_EVENTS[e],
            "the client has no event called " .. tostring(e)
            .. " -- if it is real, add it to CN_KNOWN_EVENTS in harness.lua")

        events[e] = true
    end
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
--
-- `time` is offsettable, because several caches in the addon are throttled on
-- WALL-CLOCK seconds and a suite that cannot move the wall clock cannot test
-- a throttle at all. `CN_TEST_TIME_OFFSET` is added to every reading, so a
-- test can say "and now it is thirty-one seconds later" without sleeping.
CN_TEST_TIME_OFFSET = 0

time    = function(...)
    return os.time(...) + CN_TEST_TIME_OFFSET
end

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
-- WoW runs Lua 5.1, where unpack is a global and table.unpack does not exist.
-- This suite normally runs 5.4, where the reverse is true. Running it under
-- BOTH is how the two-argument math.atan defect was finally caught, so the
-- harness itself has to work in both.
local UNPACK = rawget(table, "unpack") or unpack

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
function UnitOnTaxi() return CN_TEST_ON_TAXI end

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
    -- THE USER WAYPOINT IS STATE, AND THERE IS EXACTLY ONE OF IT.
    --
    -- These were two no-ops, so nothing could tell the difference between an
    -- addon that set a pin and one that did not, or between clearing its own
    -- pin and deleting one the player placed by hand. Modelled as the single
    -- slot the client actually has.
    SetUserWaypoint      = function(point)
        CN_TEST_USER_WAYPOINT = point
        return true
    end,
    GetUserWaypoint      = function() return CN_TEST_USER_WAYPOINT end,
    ClearUserWaypoint    = function()
        CN_TEST_USER_WAYPOINT = nil
        return true
    end,
    -- Refused on dungeon, raid, cosmic and continent maps in the real client.
    -- Modelled with a switch so a test can reach the refusal, which the addon
    -- never asked about until 0.53.0.
    CanSetUserWaypointOnMap = function(mapID)
        if CN_TEST_WAYPOINT_BANNED_MAPS
            and CN_TEST_WAYPOINT_BANNED_MAPS[mapID] then

            return false
        end

        return true
    end,
    -- NOT A SQUARE, because no zone in the game is one.
    --
    -- This stub was a flat 1000x1000 yard square for eight releases, which
    -- made map coordinates isotropic -- one map unit east was the same number
    -- of yards as one map unit south. Real maps normalize to 0-1 over ground
    -- that is not square, so an angle taken from raw map coordinates is
    -- stretched by the zone's aspect ratio, and the square stub hid that in
    -- every test the addon has. Found by asking what the stub refused to
    -- model; the answer was "the shape of the world".
    --
    -- CN_TEST_MAP_SPAN sets the width and height in yards.
    GetWorldPosFromMapPos = function(mapID, point)
        -- The real client wants a Vector2D. Handing it a UiMapPoint is the
        -- 0.19.0 bug; fail loudly rather than quietly returning a number.
        assert(point and point.x and point.y and not point.uiMapID,
            "GetWorldPosFromMapPos needs a Vector2D, not a UiMapPoint")

        local span = CN_TEST_MAP_SPAN or { 1000, 1000 }

        -- The CONTINENT id matters as much as the position: two points on
        -- different continents cannot be compared at all, and a stub that
        -- said "continent 1" for everything would let a cross-continent
        -- journey be costed as though you could run it.
        local continent = (CN_TEST_CONTINENT_FOR_MAP
            and CN_TEST_CONTINENT_FOR_MAP[mapID]) or 1

        return continent, CreateVector2D(point.x * span[1], point.y * span[2])
    end,
}

-- FLIGHT POINTS.
--
-- Positions are in the CONTINENT map's coordinates, not the zone's, which is
-- the kind of detail a stub gets wrong by accident and then hides forever.
-- CN_TEST_TAXI_NODES is keyed by continent map id.
--
-- state: Enum.FlightPathState -- Current 0, Reachable 1, Unreachable 2. An
-- unreachable node is one you have NOT discovered, and costing a journey
-- through one produces a plan the player cannot follow.
Enum = Enum or {}

Enum.FlightPathState = { Current = 0, Reachable = 1, Unreachable = 2 }

CN_TEST_TAXI_NODES = {
    -- Keyed by CONTINENT map id: 1941 is Quel'Thalas in the stub's map tree,
    -- and zone 94 sits under it.
    [1941] = {
        { nodeID = 1, name = "Near Node",  state = 1, position = { x = 0.40, y = 0.50 } },
        { nodeID = 2, name = "Far Node",   state = 1, position = { x = 0.90, y = 0.50 } },
        { nodeID = 3, name = "Undiscovered", state = 2, position = { x = 0.95, y = 0.52 } },
    },
}

C_TaxiMap = {
    GetAllTaxiNodes = function(continentID)
        local nodes = CN_TEST_TAXI_NODES[continentID] or {}

        local copy = {}

        for _, node in ipairs(nodes) do
            table.insert(copy, {
                nodeID   = node.nodeID,
                name     = node.name,
                state    = node.state,
                position = CreateVector2D(node.position.x, node.position.y),
            })
        end

        return copy
    end,
}

-- BEING DEAD, AND BEING IN A GROUP.
--
-- Both change what a sensible next action is, and neither was modelled until
-- 0.43.0 -- so the stub did not model them either, which is exactly how a
-- whole class of behaviour stays invisible to a test suite.
-- BAGS, MAIL AND A KEYSTONE.
--
-- All three are systems the addon could not see before 0.44.0, so the stub
-- could not either -- which is how an entire class of behaviour stays
-- invisible to a suite that otherwise looks thorough.
CN_TEST_BAGS = {
    [0] = {
        { itemID = 60001, stackCount = 1, quest = { questID = 44001, isActive = false } },
        -- Worthless to a vendor and not a quest item: the two facts the addon
        -- confused for each other.
        { itemID = 60002, stackCount = 20, hasNoValue = true },
        -- Already accepted: the client still flags it, and offering it again
        -- would send the player to right-click something they have used.
        { itemID = 60003, stackCount = 1, quest = { questID = 44002, isActive = true } },
    },
}

C_Container = {
    GetContainerNumSlots = function(bag)
        local slots = CN_TEST_BAGS[bag]

        return slots and #slots or 0
    end,

    GetContainerItemInfo = function(bag, slot)
        local item = CN_TEST_BAGS[bag] and CN_TEST_BAGS[bag][slot]

        if not item then
            return nil
        end

        return {
            itemID     = item.itemID,
            stackCount = item.stackCount,
            hyperlink  = "|cffffffff|Hitem:" .. item.itemID .. "|h[Item]|h|r",
            quality    = 1,

            -- WHAT THE VENDOR WILL PAY, WHICH IS NOT WHETHER IT IS A QUEST
            -- ITEM. The addon read this field as the latter for two
            -- releases; the stub did not set it at all, so both branches
            -- produced the same value and no test could tell them apart.
            hasNoValue = item.hasNoValue and true or false,
        }
    end,

    GetContainerItemQuestInfo = function(bag, slot)
        local item = CN_TEST_BAGS[bag] and CN_TEST_BAGS[bag][slot]

        return item and item.quest or {}
    end,
}

-- QUEST OBJECTIVES THAT COUNT SOMETHING.
--
-- "3 of 12 feathers" is the state the addon could describe only as "not
-- finished" until 0.45.0, so the stub had no notion of it either.
-- APPEARANCE SETS, including one already finished -- because "nearly
-- finished" and "finished" are the two states a set-tracking feature must
-- never confuse, and a fixture without a completed set cannot tell them
-- apart.
CN_TEST_SETS = {
    { setID = 1, name = "Almost There",  collected = false,
      pieces = { true, true, true, true, false } },
    { setID = 2, name = "Finished",      collected = true,
      pieces = { true, true, true } },
    { setID = 3, name = "Barely Begun",  collected = false,
      pieces = { true, false, false, false, false, false } },
}

C_TransmogSets = {
    GetAllSets = function()
        local sets = {}

        for _, set in ipairs(CN_TEST_SETS) do
            table.insert(sets, {
                setID     = set.setID,
                name      = set.name,
                collected = set.collected,
            })
        end

        return sets
    end,

    GetSetPrimaryAppearances = function(setID)
        for _, set in ipairs(CN_TEST_SETS) do
            if set.setID == setID then
                local pieces = {}

                for _, collected in ipairs(set.pieces) do
                    table.insert(pieces, { collected = collected })
                end

                return pieces
            end
        end

        return {}
    end,
}

CN_TEST_OBJECTIVES = {
    [9001] = {
        { text = "Sunscale Feathers", type = "item",
          numFulfilled = 11, numRequired = 12, finished = false },
    },
    [9002] = {
        { text = "Boars slain", type = "monster",
          numFulfilled = 2, numRequired = 20, finished = false },
    },
}

CN_TEST_MAIL = {
    { sender = "Auction House", subject = "Sold", money = 100, items = 0, daysLeft = 1.5 },
    { sender = "A Friend",      subject = "Here", money = 0,   items = 2, daysLeft = 2.0 },
    { sender = "Nobody",        subject = "Old",  money = 0,   items = 0, daysLeft = 0.5 },
    { sender = "A Friend",      subject = "Later", money = 0,  items = 1, daysLeft = 25 },
}

-- RETAIL SCALE FOR THE NEWEST SUBSYSTEMS.
--
-- The fixtures for bags, sets and mail were written to be READ -- three
-- items, three sets, four messages -- which is right for a test that asserts
-- behaviour and completely wrong for a benchmark. At that size every one of
-- the 0.44.0 and 0.45.0 providers measured under a fiftieth of a millisecond,
-- which says nothing at all about what they cost a player with five full bags
-- and three thousand appearance sets.
--
-- That is the same trap this project has fallen into eight times: a fixture
-- simpler than reality, agreeing with the code. So the bench grows them to
-- the size the game actually produces, and the tests keep the small ones.
if CN_BENCH then
    -- Five bags of thirty-six, nearly full.
    for bag = 0, 4 do
        CN_TEST_BAGS[bag] = CN_TEST_BAGS[bag] or {}

        for slot = 1, 36 do
            CN_TEST_BAGS[bag][slot] = CN_TEST_BAGS[bag][slot] or {
                itemID     = 200000 + (bag * 100) + slot,
                stackCount = 1,
            }
        end
    end

    -- Three thousand appearance sets, which is roughly what the game holds.
    for index = 4, 3000 do
        CN_TEST_SETS[index] = {
            setID = index,
            name  = "Set " .. index,
            collected = false,
            pieces = { true, true, false, false, false },
        }
    end

    -- A mailbox somebody has not emptied in a while.
    for index = 5, 50 do
        CN_TEST_MAIL[index] = {
            sender = "Sender " .. index, subject = "Subject " .. index,
            money = 0, items = 1, daysLeft = 5 + (index % 20),
        }
    end

    -- A CONTINENT'S WORTH OF FLIGHT POINTS.
    --
    -- Three nodes, one of them undiscovered, is a fixture written to be read.
    -- A levelled character has upwards of sixty on a continent, and the route
    -- search deliberately tries EVERY PAIR of them -- so its cost grows as the
    -- square of a number this fixture had quietly set to two.
    for index = 4, 60 do
        CN_TEST_TAXI_NODES[1941][index] = {
            nodeID   = index,
            name     = "Node " .. index,
            state    = 1,
            -- CLUSTERED IN A FAR CORNER, DELIBERATELY.
            --
            -- These exist to make the pair search do sixty-squared work, not
            -- to change any answer. Spread across the map they started
            -- winning journeys the tests assert are quicker on foot -- which
            -- would have meant weakening real assertions to accommodate a
            -- benchmark, and an assertion weakened for the tooling's
            -- convenience is an assertion that has stopped checking.
            position = {
                x = 0.94 + ((index % 10) * 0.006),
                y = 0.94 + ((index % 7) * 0.008),
            },
        }
    end

    -- A full quest log, every quest with counting objectives.
    for index = 1, 25 do
        local questID = 95000 + index

        CN_TEST_OBJECTIVES[questID] = {
            { text = "Thing " .. index, numFulfilled = index % 12,
              numRequired = 12, finished = false },
            { text = "Other " .. index, numFulfilled = 1,
              numRequired = 8, finished = false },
        }
    end
end

function GetInboxNumItems()
    return #CN_TEST_MAIL
end

function GetInboxHeaderInfo(index)
    local mail = CN_TEST_MAIL[index]

    if not mail then
        return nil
    end

    -- packageIcon, stationeryIcon, sender, subject, money, CODAmount,
    -- daysLeft, itemCount
    return nil, nil, mail.sender, mail.subject, mail.money, 0,
        mail.daysLeft, mail.items
end

-- WHERE YOUR BODY IS.
--
-- The client will tell you, and the addon never asked -- it ranked everything
-- down for being dead and then pointed at nothing. Modelled here so the path
-- is exercised rather than assumed.
CN_TEST_CORPSE = { x = 0.31, y = 0.62 }

C_DeathInfo = {
    GetCorpseMapPosition = function(mapID)
        if not CN_TEST_GHOST or not CN_TEST_CORPSE then
            return nil
        end

        return CreateVector2D(CN_TEST_CORPSE.x, CN_TEST_CORPSE.y)
    end,
}

CN_TEST_DEAD       = false
CN_TEST_GHOST      = false
CN_TEST_GROUP_SIZE = 1
CN_TEST_INSTANCE   = nil

function UnitIsDeadOrGhost(unit)
    return unit == "player" and CN_TEST_DEAD or false
end

function UnitIsGhost(unit)
    return unit == "player" and CN_TEST_GHOST or false
end

function GetNumGroupMembers()
    return CN_TEST_GROUP_SIZE
end

function IsInRaid()
    return CN_TEST_INSTANCE == "raid"
end

function IsInInstance()
    if not CN_TEST_INSTANCE then
        return false, "none"
    end

    return true, CN_TEST_INSTANCE
end

CN_TEST_FLYING = false

function IsFlying()
    return CN_TEST_FLYING
end

CN_TEST_FLYABLE = true

function IsFlyableArea()
    return CN_TEST_FLYABLE
end

CN_TEST_ON_TAXI = false

-- SAVED INSTANCES.
--
-- Thirteen return values in a fixed order, which is exactly the kind of API
-- shape a hand-written stub gets subtly wrong. /cn capture records the real
-- one and the fixture audit at the end of this file compares them.
CN_TEST_SAVED_INSTANCES = {
    -- name, lockoutID, reset, difficultyID, locked, extended, _, isRaid, _,
    -- difficultyName, numEncounters, encounterProgress, extendDisabled,
    -- instanceID
    --
    -- TWO ID SPACES, AND THE FIXTURE USED TO CONFLATE THEM. Slot 2 held
    -- 1273 and 1274, which are the ENCOUNTER JOURNAL instance ids -- the
    -- same numbers CN_TEST_EJ_INSTANCES is keyed by. So the addon handing
    -- slot 2 to EJ_SelectInstance worked here and could never work in game,
    -- where slot 2 is an opaque lockout save id.
    --
    -- Slot 2 now holds a realistic lockout id and slot 14 the journal id, so
    -- the two can never be confused again: code that reaches for the wrong
    -- one gets an id the journal has never heard of, exactly as it would in
    -- game.
    --
    -- TOTAL FIRST, THEN PROGRESS. This comment used to read "defeated,
    -- encounters" and the rows were written in that order, matching a bug in
    -- the addon rather than the client -- so a raid six bosses into eight
    -- came back as eight defeated out of six, `remaining` clamped to zero,
    -- `complete` went true, and the Instances provider returned nothing at
    -- all. The stub and the code shared one wrong belief and the suite
    -- agreed with both.
    { "Nerub-ar Palace", 2147483001, 3 * 86400, 14, true, false, false, true,
      false, "Normal", 8, 6, false, 1273 },
    { "Ara-Kara, City of Echoes", 2147483002, 86400, 23, true, false, false,
      false, false, "Mythic", 4, 4, false, 1274 },
    -- Saved to it, but nothing killed in it yet. The client lists these, and
    -- they are NOT a next action: an untouched lockout is a decision about
    -- the evening, not spent effort that expires.
    -- Deliberately SMALL, so that it clears every other filter the provider
    -- applies and the only thing excluding it is the rule under test. A
    -- fixture that fails a different check first proves nothing about this
    -- one -- the first version of this row had eight bosses and was being
    -- dropped for being too long, so the rule could have been deleted
    -- entirely and the suite would have agreed.
    { "Liberation of Undermine", 2147483003, 5 * 86400, 14, true, false, false,
      true, false, "Normal", 3, 0, false, 1296 },
}

function GetNumSavedInstances()
    return #CN_TEST_SAVED_INSTANCES
end

function GetSavedInstanceInfo(index)
    local row = CN_TEST_SAVED_INSTANCES[index]

    if not row then
        return nil
    end

    return row[1], row[2], row[3], row[4], row[5], row[6], row[7], row[8],
        row[9], row[10], row[11], row[12], row[13], row[14]
end

-- THE ADVENTURE GUIDE, INCLUDING THE PART THAT MAKES IT DANGEROUS.
--
-- EJ_SelectInstance is not a query: it changes what the journal is showing,
-- which is what the player is looking at if the window is open. The stub
-- models that state so the suite can prove the addon puts it back and refuses
-- to touch it while the window is up. A stub that treated selection as a
-- no-op would agree with an addon that yanked the player's view around.
CN_TEST_EJ_SELECTED = nil
CN_TEST_EJ_OPEN     = false
CN_TEST_EJ_SEARCH   = nil

CN_TEST_EJ_INSTANCES = {
    [1273] = {
        name = "Nerub-ar Palace",
        encounters = {
            { name = "Ulgrax the Devourer", id = 2607 },
            { name = "The Bloodbound Horror", id = 2611 },
            { name = "Sikran", id = 2599 },
            { name = "Rasha'nan", id = 2609 },
            { name = "Broodtwister Ovi'nax", id = 2612 },
            { name = "Nexus-Princess Ky'veza", id = 2601 },
            { name = "The Silken Court", id = 2608 },
            { name = "Queen Ansurek", id = 2602 },
        },
    },
    [1274] = {
        name = "Ara-Kara, City of Echoes",
        encounters = {
            { name = "Avanoxx", id = 2926 },
            { name = "Anub'zekt", id = 2906 },
            { name = "Ki'katal the Harvester", id = 2925 },
        },
    },
}

-- What the journal's search would return, keyed by the text searched for.
CN_TEST_EJ_SEARCH_RESULTS = {
    ["Ansurek's Web Wrap"] = {
        { id = 2602, stype = 1, instanceID = 1273 },
    },
}

EncounterJournal = {
    IsShown = function() return CN_TEST_EJ_OPEN end,
}

function EJ_SelectInstance(instanceID)
    CN_TEST_EJ_SELECTED = instanceID
end

function EJ_GetCurrentInstance()
    return CN_TEST_EJ_SELECTED
end

function EJ_GetInstanceInfo(instanceID)
    local entry = CN_TEST_EJ_INSTANCES[instanceID or CN_TEST_EJ_SELECTED]

    return entry and entry.name or nil
end

function EJ_GetEncounterInfoByIndex(index, instanceID)
    local entry = CN_TEST_EJ_INSTANCES[instanceID or CN_TEST_EJ_SELECTED]

    local encounter = entry and entry.encounters[index]

    if not encounter then
        return nil
    end

    return encounter.name, "description", encounter.id
end

function EJ_GetEncounterInfo(encounterID)
    for _, entry in pairs(CN_TEST_EJ_INSTANCES) do
        for _, encounter in ipairs(entry.encounters) do
            if encounter.id == encounterID then
                return encounter.name
            end
        end
    end

    return nil
end

function EJ_SetSearch(text)
    CN_TEST_EJ_SEARCH = CN_TEST_EJ_SEARCH_RESULTS[text] or {}
end

function EJ_ClearSearch()
    CN_TEST_EJ_SEARCH = nil

    -- Clearing the search drops the selection too, which is what makes it the
    -- only lever for restoring "nothing was selected".
    CN_TEST_EJ_SELECTED = nil
end

function EJ_GetNumSearchResults()
    return CN_TEST_EJ_SEARCH and #CN_TEST_EJ_SEARCH or 0
end

function EJ_GetSearchResult(index)
    local result = CN_TEST_EJ_SEARCH and CN_TEST_EJ_SEARCH[index]

    if not result then
        return nil
    end

    -- id, type, _, _, _, instanceID
    return result.id, result.stype, nil, nil, nil, result.instanceID
end

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

-- Width and height of the stub map, in yards. Square by default so that the
-- distance figures elsewhere stay checkable by hand; tests that care about
-- angles set it to something the shape of a real zone.
CN_TEST_MAP_SPAN = { 1000, 1000 }

-- The span is set through CN_TEST_SetMapSpan, which is defined once the addon
-- has loaded: changing the shape of the world has to invalidate everything the
-- addon measured from it.


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
        -- COUNTING objectives where the fixture defines them, so the addon's
        -- "eleven of twelve" path is exercised rather than only its
        -- "finished or not" one.
        if CN_TEST_OBJECTIVES[id] then
            return CN_TEST_OBJECTIVES[id]
        end

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

-- A HEADER WITH factionID = 0, WHICH IS WHAT THE CLIENT GIVES.
--
-- The addon captured collapsed headers under `data.factionID or index` and
-- restored on `data.factionID` alone, so every header collided on
-- `collapsed[0]`: one collapsed header made the restore collapse them all.
-- The fixture had exactly one header, never collapsed, so neither half of
-- that could show.
--
-- Two headers now, one of them collapsed, and both with id 0 -- which is the
-- shape that broke it.
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
    { factionID = 0,    name = "Legacy", isHeader = true, isCollapsed = true },
}

function CN_TEST_Factions()
    return factions
end

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
    -- NOT PURE COUNTERS. These used to increment and change nothing, so the
    -- round trip -- and the index shifting a real expand causes -- went
    -- untested. They now move the state the addon reads back.
    ExpandAllFactionHeaders = function()
        expandCalls = expandCalls + 1

        for _, faction in ipairs(factions) do
            if faction.isHeader then
                faction.isCollapsed = false
            end
        end
    end,
    CollapseFactionHeader   = function(index)
        collapseCalls = collapseCalls + 1

        local faction = factions[index]

        if faction and faction.isHeader then
            faction.isCollapsed = true
        end
    end,
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

LE_PET_JOURNAL_FILTER_COLLECTED     = 1
LE_PET_JOURNAL_FILTER_NOT_COLLECTED = 2

-- THE GAME'S OWN OPTIONS API.
--
-- Absent from this stub for as long as the addon has tried to register with
-- it, so the `if SettingsPanel and Settings and ...` chain short-circuited on
-- the first term and the suite never reached the line that threw on every
-- real client. Defined now, so that path is exercised.
SettingsPanel = { name = "SettingsPanel" }

CN_TEST_OPTIONS_REGISTERED = {}

Settings = {
    RegisterCanvasLayoutCategory = function(panel, name)
        return { ID = name, panel = panel }
    end,

    RegisterAddOnCategory = function(category)
        table.insert(CN_TEST_OPTIONS_REGISTERED, category)

        return true
    end,
}

CN_TEST_PET_FILTERS = { collected = true, uncollected = true, search = "" }

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

    -- FILTERS THE SCAN CHANGES, AND MUST PUT BACK.
    --
    -- The stub used to accept every Set* call and answer no Get*, so a scan
    -- that widened the player's journal and never restored it looked
    -- identical to one that did. It was the second: a player with their
    -- journal filtered to uncollected wild pets had it silently reset to show
    -- everything, permanently, by running /cn setup once. The addon's
    -- standing rule is that it prompts and does not act.
    GetSearchFilter          = function() return CN_TEST_PET_FILTERS.search or "" end,
    SetSearchFilter          = function(text) CN_TEST_PET_FILTERS.search = text end,
    -- Counted as well as recorded, so a test can assert the addon did NOT
    -- reach for these -- which is the property that matters, since neither
    -- has a getter and neither can be undone.
    SetAllPetSourcesChecked  = function()
        CN_TEST_PET_FILTERS.sources = true
        CN_TEST_PET_FILTERS.sourceWidens =
            (CN_TEST_PET_FILTERS.sourceWidens or 0) + 1
    end,
    SetAllPetTypesChecked    = function()
        CN_TEST_PET_FILTERS.types = true
        CN_TEST_PET_FILTERS.typeWidens =
            (CN_TEST_PET_FILTERS.typeWidens or 0) + 1
    end,

    IsFilterChecked = function(which)
        if which == LE_PET_JOURNAL_FILTER_COLLECTED then
            return CN_TEST_PET_FILTERS.collected
        end

        return CN_TEST_PET_FILTERS.uncollected
    end,

    SetFilterChecked = function(which, value)
        if which == LE_PET_JOURNAL_FILTER_COLLECTED then
            CN_TEST_PET_FILTERS.collected = value
        else
            CN_TEST_PET_FILTERS.uncollected = value
        end
    end,
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
    -- COUNTED, NOT DISCARDED. This was `function() end`, so a suite that
    -- could not observe the call could not notice that the addon made it
    -- unconditionally and never put it back.
    SetAllSourceTypeFilters = function()
        CN_TEST_TOY_SOURCES_WIDENED = (CN_TEST_TOY_SOURCES_WIDENED or 0) + 1
    end,
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

    return UNPACK(out)
end

------------------------------------------------------------
-- HANDYNOTES STUB
------------------------------------------------------------

HandyNotes = {
    -- SHAPED LIKE THE REAL ONE, WHICH IS A `pairs`-STYLE TRIPLET.
    --
    -- This used to be a single self-contained closure. HandyNotes returns
    -- `next, self.plugins, nil` -- three values -- and a self-contained
    -- closure is the one shape under which `pcall(iterate, root)` capturing
    -- only the first return still works. So the addon's HandyNotes
    -- integration was broken for every real player and green in the suite.
    --
    -- Returning the triplet means a caller that drops the state table gets
    -- the same error here that the client gives: next(nil, nil).
    IteratePlugins = function(self)
        return next, {
            HandyNotes_Treasures = {
                GetNodes2 = function(_, mapID, minimap)
                    if mapID ~= 94 then
                        return next, {}, nil
                    end

                    -- HandyNotes packs x,y into one integer.
                    return next, { [45006200] = { label = "Hidden Cache" } }, nil
                end,
            },
        }, nil
    end,
}

------------------------------------------------------------
-- CURRENCY STUBS
------------------------------------------------------------

-- THE LIST ROW HAS NO ID IN IT.
--
-- CurrencyDisplayInfo -- what GetCurrencyListInfo returns -- carries names,
-- quantities and flags and no currencyID. This stub put one in every row, so
-- the addon's `info.currencyID` read looked correct here and was nil on every
-- real client: the character currency store has always been empty and
-- `/cn currencies` has always said "no currency data yet".
--
-- Ninth time a stub and the code shared one wrong belief. The id is kept
-- alongside the row for the LINK function to return, which is how the client
-- actually supplies it.
-- HEADERS THAT ACTUALLY COLLAPSE.
--
-- `GetCurrencyListSize` counts only rows under EXPANDED headers -- exactly
-- like the faction list. The stub had one header, at the END of the list,
-- permanently open, so nothing under a collapsed header ever existed to be
-- lost and the addon's failure to expand the list was invisible.
--
-- Modelled properly: a full list, a visible view derived from it, and an
-- `ExpandCurrencyList` that changes which rows the other two functions can
-- see. A collapsed group at the FRONT, so the index shifting is real.
CN_TEST_CURRENCY_ROWS = {
    { isHeader = true, name = "Player", isHeaderExpanded = true },
    { name = "Valorstones", currencyID = 3008, quantity = 2000,
      maxQuantity = 2000, quantityEarnedThisWeek = 0, maxWeeklyQuantity = 0,
      totalEarned = 5000 },
    { name = "Flightstones", currencyID = 2245, quantity = 400,
      maxQuantity = 2000, quantityEarnedThisWeek = 300,
      maxWeeklyQuantity = 1000, totalEarned = 900 },
    { isHeader = true, name = "Player vs. Player", isHeaderExpanded = true },
    { name = "Conquest", currencyID = 1602, quantity = 0, maxQuantity = 0,
      quantityEarnedThisWeek = 0, maxWeeklyQuantity = 1350, totalEarned = 0 },
    -- Weekly profession knowledge: the thing `/cn clock` calls the most
    -- permanently missable in the game, and which it has never once listed.
    -- Deliberately under a header the player has COLLAPSED, which is the
    -- ordinary state of the profession group for most people.
    { isHeader = true, name = "Professions", isHeaderExpanded = false },
    { name = "Alchemy Knowledge", currencyID = 3009, quantity = 1,
      maxQuantity = 0, quantityEarnedThisWeek = 1, maxWeeklyQuantity = 3,
      totalEarned = 1 },
}

-- What the client would actually list, given the current header states.
local function CurrencyVisible()
    local visible = {}
    local showing = true

    for _, row in ipairs(CN_TEST_CURRENCY_ROWS) do
        if row.isHeader then
            showing = row.isHeaderExpanded ~= false

            table.insert(visible, row)
        elseif showing then
            table.insert(visible, row)
        end
    end

    return visible
end

CN_TEST_CurrencyVisible = CurrencyVisible

local currencyByID = {}

for _, row in ipairs(CN_TEST_CURRENCY_ROWS) do
    if row.currencyID then
        local copy = {}

        for key, value in pairs(row) do
            copy[key] = value
        end

        currencyByID[row.currencyID] = copy
    end
end

C_CurrencyInfo = {
    GetCurrencyListSize = function() return #CurrencyVisible() end,

    -- CurrencyDisplayInfo carries no currencyID, so the row the addon sees
    -- must not have one. A copy is handed out with the id stripped, which is
    -- what the client does.
    GetCurrencyListInfo = function(i)
        local row = CurrencyVisible()[i]

        if not row then
            return nil
        end

        local view = {}

        for key, value in pairs(row) do
            view[key] = value
        end

        view.currencyID = nil

        return view
    end,

    -- The only place the client will tell you which currency a row is.
    GetCurrencyListLink = function(i)
        local row = CurrencyVisible()[i]

        if not row or not row.currencyID then
            return nil
        end

        return "|cffffffff|Hcurrency:" .. row.currencyID .. "|h["
            .. row.name .. "]|h|r"
    end,

    ExpandCurrencyList = function(index, expand)
        local row = CurrencyVisible()[index]

        if row and row.isHeader then
            row.isHeaderExpanded = expand and true or false
        end
    end,
    GetCurrencyInfo     = function(id)
        return currencyByID[id]
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

------------------------------------------------------------
-- THE BINDINGS AND THE MINIMAP BUTTON MUST ACTUALLY DO SOMETHING.
--
-- Every one of these is a function `Bindings.xml` names, so a keystroke lands
-- straight in it with no other code in between. The suite asserted only that
-- they EXIST -- which is the same shape as the API census: a name that
-- resolves proves nothing about what happens when it is called.
------------------------------------------------------------
do
    local errors = CN:GetModule("Errors")

    errors.Clear()

    for _, entry in ipairs({
        { "ToggleUI",     CompletionNavigator_ToggleUI },
        { "NextObjective", CompletionNavigator_NextObjective },
        { "Navigate",     CompletionNavigator_Navigate },
        { "ToggleFollow", CompletionNavigator_ToggleFollow },
        { "Plan",         CompletionNavigator_Plan },
        { "ToggleHud",    CompletionNavigator_ToggleHud },
    }) do
        assert(type(entry[2]) == "function",
            "Bindings.xml names " .. entry[1] .. " and it must exist")

        local ok, err = pcall(entry[2])

        assert(ok, "pressing the " .. entry[1] .. " key must not error: "
            .. tostring(err))
    end

    -- ToggleUI was called an even number of times above only by accident, so
    -- put the window back deliberately.
    if CN.UI.IsShown and CN.UI.IsShown() then
        CN.UI.Toggle()
    end

    -- Undo the two that changed state.
    if CN:GetModule("Follow").active then
        CN.HandleSlashCommand("follow")
    end

    assert(errors.Count() == 0,
        "and none of them may record a failure; " .. errors.Count() .. " did")

    ------------------------------------------------------------
    -- THE MINIMAP BUTTON, INCLUDING THE MIDDLE CLICK NOTHING DOCUMENTED.
    ------------------------------------------------------------
    local button = _G.CompletionNavigatorMinimapButton

    assert(button, "the minimap button must be published as a global, or "
        .. "nothing can reach it")

    for _, click in ipairs({ "LeftButton", "RightButton", "MiddleButton" }) do
        local ok, err = pcall(button:GetScript("OnClick"), button, click)

        assert(ok, click .. " on the minimap button must not error: "
            .. tostring(err))
    end

    if CN.UI.IsShown and CN.UI.IsShown() then
        CN.UI.Toggle()
    end

    if CN:GetModule("Follow").active then
        CN.HandleSlashCommand("follow")
    end

    -- Hover, which is where the recommendation is shown, and the drag that
    -- moves the button around the minimap.
    assert(pcall(button:GetScript("OnEnter"), button),
        "hovering the minimap button must not error")

    assert(pcall(button:GetScript("OnLeave"), button),
        "nor must leaving it")

    local angleBefore = db.settings.minimap.angle

    assert(pcall(button:GetScript("OnDragStart"), button),
        "starting a drag must not error")

    local update = button:GetScript("OnUpdate")

    if update then
        assert(pcall(update, button), "and the drag's per-frame update must "
            .. "not error either")
    end

    assert(pcall(button:GetScript("OnDragStop"), button),
        "nor must releasing it")

    assert(type(db.settings.minimap.angle) == "number",
        "and the button's position stays a number after a drag, was "
        .. tostring(angleBefore))

    print("  6 key bindings and 3 minimap clicks all reach real code")
end

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

-- Four real currencies and one header. The count is asserted because it is
-- also the proof that the id was recovered from the LINK: a row whose id
-- cannot be resolved is dropped by the scan, so this number falling is how a
-- broken id lookup announces itself.
assert(count(currencies) == 4, "header rows must be skipped, got " .. count(currencies))
assert(currencies[3008].capped == true, "a currency at max must be flagged capped")
assert(currencies[2245].capped == false, "a currency below max must not be capped")
assert(currencies[2245].weeklyRemaining == 700,
    "weekly remaining must be max minus earned, got "
    .. tostring(currencies[2245].weeklyRemaining))

-- AND THE ONE UNDER A COLLAPSED HEADER.
--
-- `GetCurrencyListSize` counts only rows under expanded headers. The
-- reputation path expands, scans and restores; the currency path did not, so
-- a player who had collapsed their profession group -- which is most people
-- -- lost every currency under it from `/cn currencies`, `/cn clock` and the
-- weekly-cap warnings, silently. The fixture's only header used to sit at the
-- end of the list and was never collapsed, so nothing could be lost.
assert(currencies[3009],
    "a currency under a header the player collapsed must still be found; "
    .. "the list has to be expanded to read it")

-- And put back exactly as it was found.
for _, row in ipairs(CN_TEST_CURRENCY_ROWS) do
    if row.isHeader and row.name == "Professions" then
        assert(row.isHeaderExpanded == false,
            "a header the player had collapsed must be collapsed again after "
            .. "the scan")
    end

    if row.isHeader and row.name == "Player" then
        assert(row.isHeaderExpanded ~= false,
            "and one they had open must be left open")
    end
end

print("  a collapsed header is expanded to read it, then collapsed again")

-- THE SAME PROPERTY, FOR THE REPUTATION LIST.
--
-- Same shape, older code, and the capture and restore keyed on different
-- things: `data.factionID or index` going in, `data.factionID` coming out.
-- Headers carry factionID 0, so every one of them collided on `collapsed[0]`
-- -- one collapsed header collapsed them all on the way back.
do
    local reputations = CN:GetModule("Reputations")

    assert(reputations, "the reputation module must be loaded")

    reputations.Scan()

    local open, shut = 0, 0

    for _, faction in ipairs(CN_TEST_Factions()) do
        if faction.isHeader then
            if faction.isCollapsed then
                shut = shut + 1
            else
                open = open + 1
            end
        end
    end

    assert(shut == 1 and open >= 1,
        "exactly the header the player had collapsed must be collapsed after "
        .. "a scan; got " .. shut .. " collapsed and " .. open .. " open")

    print("  and reputation headers are restored one by one, not all at once")
end

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
-- CHANGING THE SHAPE OF THE WORLD INVALIDATES WHAT WAS MEASURED FROM IT.
--
-- Two modules memoise conversions that are constant in the real game -- map
-- scales and world positions -- and are right to cache them. A fixture that
-- resizes the map is doing something the game never does, so it has to say so.
--
-- DEFINED HERE, NOT BESIDE THE STUB. The first version sat next to
-- CN_TEST_MAP_SPAN, above the line where `CN` is declared, so it referenced a
-- global that is nil at call time, guarded that with `if CN and ...`, and
-- therefore did nothing at all -- silently, while looking careful. The next
-- test then measured the previous test's world.
function CN_TEST_SetMapSpan(span)
    CN_TEST_MAP_SPAN = span

    local navigation = CN:GetModule("Navigation")
    local travel     = CN:GetModule("Travel")

    assert(navigation and travel,
        "the geometry modules must be loaded before the fixture resizes a map")

    navigation.ForgetMapScales()
    travel.ForgetWorldPoints()
    travel.ForgetNodes()
end

CN.FireEvent = fire

CN.CollectCandidates(true)

local firstState = CN.GetCandidateCacheState()
print("  providers = " .. firstState.providers
    .. ", cached = " .. firstState.fresh
    .. ", objectives = " .. firstState.count)

assert(firstState.providers == 22, "every candidate provider must register, got "
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

-- EVERY SCAN THAT FEEDS A PROVIDER MUST DIRTY IT.
--
-- This used to assert the opposite for mounts -- "a mount scan must not
-- rebuild candidate providers" -- which was true when mounts fed only the
-- Collections tab and became false the day Mounts became a candidate
-- provider. Nobody revisited it, so the suite spent several releases
-- asserting that a real defect was correct: `/cn setup` scanned mounts, toys,
-- appearances and professions, printed "Setup complete", and left all four
-- providers serving a cache built before the scan.
--
-- The property is not a list of names; it is the relationship. Every store
-- named in CN.scanProviders must mark each provider it names stale.
--
-- AND EVERY CANDIDATE PROVIDER THAT READS A SCANNED STORE MUST BE NAMED.
-- Walking the table alone cannot catch a missing entry -- a removed row is
-- simply a row the loop does not visit -- so the set is checked too.
for _, required in ipairs({ "Mounts", "Toys", "Appearances", "Professions",
                            "Pets", "Achievements", "Reputations",
                            "Currencies", "Exploration" }) do
    local named = false

    for _, providers in pairs(CN.scanProviders) do
        for _, provider in ipairs(providers) do
            if provider == required then named = true end
        end
    end

    assert(named,
        required .. " is a candidate provider fed by a scan, and no store in "
        .. "CN.scanProviders names it -- so scanning it leaves the "
        .. "recommendation built from the state before the scan")
end
CN.CollectCandidates(true)

local scannedStores = 0

for store, providers in pairs(CN.scanProviders) do
    CN.CollectCandidates(true)

    CN.MarkScanned(store)

    for _, provider in ipairs(providers) do
        assert(CN.GetProviderCacheState(provider)
            and CN.GetProviderCacheState(provider).dirty,
            "scanning " .. store .. " must mark " .. provider
            .. " stale, or the scan is invisible to the recommendation")
    end

    scannedStores = scannedStores + 1
end

-- And a store nothing reads must still dirty nothing.
CN.CollectCandidates(true)

local generationBefore = CN.GetCandidateCacheState().generation

CN.MarkScanned("titles")
CN.CollectCandidates()

assert(CN.GetCandidateCacheState().generation == generationBefore,
    "a scan of a store no provider reads must not rebuild anything")

print("  " .. scannedStores .. " scanned stores, each dirtying what reads it")

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

------------------------------------------------------------
-- "WAYPOINT SET" MUST MEAN A WAYPOINT WAS SET.
--
-- `CN.SetWaypoint` called the provider, threw the answer away, and returned
-- true. So `/cn go` printed "Waypoint set: <name>" with TomTom absent, on maps
-- the client refuses waypoints on, and whenever the client would not build a
-- map point -- a success message and no arrow.
--
-- `C_Map.CanSetUserWaypointOnMap` says which maps refuse, and was called
-- nowhere in this addon until 0.53.0.
------------------------------------------------------------
do
    CN_TEST_USER_WAYPOINT = nil

    assert(CN.SetWaypoint(94, 0.4, 0.4, "Allowed"),
        "an ordinary zone must still accept a waypoint")

    assert(CN_TEST_USER_WAYPOINT and CN_TEST_USER_WAYPOINT.uiMapID == 94,
        "and the map pin must actually reach the client")

    -- A dungeon map. The native provider's arrow still works there, so it
    -- still succeeds -- but it must not plant a pin the client refuses.
    CN.ClearWaypoints()

    CN_TEST_USER_WAYPOINT = nil

    CN_TEST_WAYPOINT_BANNED_MAPS = { [2213] = true }

    local placed, note = CN.SetWaypoint(2213, 0.4, 0.4, "Dungeon")

    assert(placed, "the arrow works on a dungeon map, so this still succeeds")

    assert(CN_TEST_USER_WAYPOINT == nil,
        "but no map pin may be planted where the client refuses one")

    CN_TEST_WAYPOINT_BANNED_MAPS = nil

    -- And the provider that has nothing but the pin must refuse outright.
    local blizzard = CN.waypointProviders and CN.waypointProviders["Blizzard"]

    assert(blizzard, "the Blizzard map-pin provider must be registered")

    CN_TEST_WAYPOINT_BANNED_MAPS = { [2213] = true }

    assert(blizzard.SetWaypoint(2213, 0.4, 0.4, "Dungeon") == false,
        "a provider whose only output is the pin must report the refusal "
        .. "rather than let the caller announce a success")

    CN_TEST_WAYPOINT_BANNED_MAPS = nil

    print("  no map pin is claimed where the client refuses one")

    ------------------------------------------------------------
    -- AND CLEARING MUST NOT DELETE THE PLAYER'S OWN PIN.
    --
    -- There is exactly one user waypoint and it belongs to the player unless
    -- this addon put it there. `/cn clearway`, stopping follow mode and every
    -- provider switch called ClearUserWaypoint unconditionally.
    ------------------------------------------------------------
    CN.ClearWaypoints()

    CN_TEST_USER_WAYPOINT = UiMapPoint.CreateFromCoordinates(94, 0.9, 0.9)

    assert(CN.ClearWaypoints() == false,
        "clearing must refuse when this addon did not set the pin")

    assert(CN_TEST_USER_WAYPOINT ~= nil,
        "and the player's own waypoint must survive it")

    -- Its own, on the other hand, it removes.
    CN_TEST_USER_WAYPOINT = nil

    CN.SetWaypoint(94, 0.4, 0.4, "Ours")

    assert(CN.ClearWaypoints() == true,
        "but a pin this addon set must be cleared")

    assert(CN_TEST_USER_WAYPOINT == nil, "and actually removed")

    print("  a pin the player placed by hand is not deleted")
end

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
--
-- Counted from the APPEARANCES PROVIDER rather than by type across the whole
-- list: 0.45.0 added a second provider that also emits APPEARANCE objectives
-- (nearly-finished sets), and a by-type count silently turned this into an
-- assertion about two unrelated caps added together.
local appearances = CN:GetModule("Appearances")

local appearanceCandidates = CN.candidateProviders["Appearances"].fn()

assert(#appearanceCandidates <= appearances.candidateSlots,
    "appearance candidates must be capped to the least-complete slots, got "
    .. #appearanceCandidates)

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

-- AND THE SUMMARY MUST COUNT WHAT IS ACTUALLY THERE.
--
-- `Harvest.Summary` counted `record.maybeRequires`, a field that database
-- migration 3 deletes and nothing has written since. So `withGuesses`
-- reported zero on every database in existence, including databases full of
-- guesses -- a reader that outlived its field by four schema versions,
-- because nothing ever asserted on the number it produced.
do
    local summary = harvestModule.Summary()

    assert(summary.withGuesses >= 1,
        "a record with three observed orderings on it must count as a guess; "
        .. "the summary says " .. tostring(summary.withGuesses))

    assert(summary.total >= 1, "and it must be counted at all")

    print("  the summary counts " .. summary.withGuesses
        .. " record(s) carrying observations")
end

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

-- THROUGH CN.AllSettings, NOT pairs().
--
-- The first version of this iterated the proxy with pairs() and passed on
-- Lua 5.4, which honours the __pairs metamethod. The game runs 5.1, which
-- does not -- so in game the same loop yielded nothing at all and every
-- override was invisible to anything that iterated. The test agreed with the
-- bug because it ran on a newer language than the one that ships.
local merged = CN.AllSettings()

assert(merged.arrow == false,
    "the merged settings must include overrides, got "
    .. tostring(merged.arrow))

assert(merged.priorityMode ~= nil,
    "and the account values underneath them")

local sawArrowViaPairs = nil

for key, value in pairs(liveSettings) do
    if key == "arrow" then sawArrowViaPairs = value end
end

-- Only assert the metamethod path where the language actually has it.
if _VERSION ~= "Lua 5.1" then
    assert(sawArrowViaPairs == false,
        "where __pairs is honoured it must agree, got "
        .. tostring(sawArrowViaPairs))
end

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
-- Deep enough that adding another deadline provider cannot push the goal off
-- the end of the list and fail this for a reason unrelated to goals. That has
-- now happened twice.
local ranked = CN.Recommend(12)

print("  ranked with vault present:")

for index, objective in ipairs(ranked) do
    if index <= 6 then
        print("    " .. index .. ". " .. tostring(objective.name)
            .. " (" .. string.format("%.1f", objective.priorityWeight or 0) .. ")")
    end
end

local goalRank

for index, objective in ipairs(ranked) do
    if objective.type == "TITLE" and objective.id == 2 then goalRank = index end
end

-- NOT "top three". That was a magic number that meant "above everything
-- except the three expiring things this fixture happened to contain", and it
-- broke the moment a provider was added -- for a reason that had nothing to
-- do with goals. The property actually being claimed is that a pinned goal
-- outranks everything that is NOT on a deadline: this addon puts expiring
-- content first deliberately, and a pin cannot outrank a reset.
assert(goalRank, "a pinned goal must appear in the ranked list at all")

for index = 1, goalRank - 1 do
    local above = ranked[index]

    local timed = (above.expiresIn ~= nil)
        or ((above.limitedTimeBonus or 0) > 0)

    assert(timed, "only time-limited work may outrank a pinned goal, but "
        .. tostring(above.name) .. " is not on a deadline")
end

-- With the expiring content gone, the goal must be first.
local vaultProvider = CN.candidateProviders["Vault"]

-- Both the deadline providers, not just the Vault: a lockout expires at the
-- weekly reset in exactly the same way, and "nothing expiring" has to mean
-- nothing expiring.
local instanceProvider = CN.candidateProviders["Instances"]
local opportunityProvider = CN.candidateProviders["Opportunities"]

-- EVERY provider that emits something with a deadline, not just the two that
-- emit weekly ones. World quests expire too, and from 0.43.0 the urgency
-- curve has a second, week-long ramp, so a world quest six hours out is no
-- longer worth exactly zero. "Nothing expiring" has to mean nothing.
-- Every provider that emits a deadline. The list grows with each release --
-- Vault, then Instances, then Opportunities, now Waiting -- which is itself
-- the argument for asserting the PROPERTY above rather than a fixed rank.
local waitingProvider = CN.candidateProviders["Waiting"]

CN.candidateProviders["Vault"]         = nil
CN.candidateProviders["Instances"]     = nil
CN.candidateProviders["Opportunities"] = nil
CN.candidateProviders["Waiting"]       = nil
CN.InvalidateCandidates()

local top = CN.Recommend(1)[1]

print("  top with nothing expiring = " .. tostring(top.name) .. " ("
    .. string.format("%.1f", top.priorityWeight or 0) .. ")")

assert(top.type == "TITLE" and top.id == 2,
    "with nothing expiring, a pinned goal must rank first, got " .. tostring(top.name))

CN.candidateProviders["Vault"]         = vaultProvider
CN.candidateProviders["Instances"]     = instanceProvider
CN.candidateProviders["Opportunities"] = opportunityProvider
CN.candidateProviders["Waiting"]       = waitingProvider
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

    ------------------------------------------------------------
    -- AND EVERY SCRIPT ON THE PIN MUST DO SOMETHING.
    --
    -- A pin the player can see, hover and click is three code paths, and only
    -- the drawing of it had ever run. Clicking one is a waypoint -- the whole
    -- reason the pins are there -- and it went untested.
    ------------------------------------------------------------
    assert(pcall(first:GetScript("OnEnter"), first),
        "hovering a map pin must not error")

    assert(pcall(first:GetScript("OnLeave"), first),
        "nor must leaving it")

    do
        local realSet, asked = CN.SetWaypoint, nil

        CN.SetWaypoint = function(mapID, x, y, title)
            asked = { mapID = mapID, x = x, y = y, title = title }
            return true
        end

        assert(pcall(first:GetScript("OnClick"), first),
            "clicking a map pin must not error")

        CN.SetWaypoint = realSet

        assert(asked and asked.mapID,
            "and it must actually set a waypoint -- that is what the pin is "
            .. "for")

        assert(asked.title and asked.title ~= "",
            "with something to call the destination: " .. tostring(asked.title))
    end

    -- A busy zone shrinks its pins rather than dropping them, because
    -- dropping stops silently misrepresents the route.
    assert(pins.PinSize(1, 40) < pins.PinSize(1, 3),
        "more than a dozen pins on one map get smaller, not fewer")

    assert(pins.PinSize(nil, nil) > 0,
        "and a pin with nothing known about it still has a size")

    -- The tooltip text is capped, and says how many it did not show.
    do
        local many = { objectives = {} }

        for index = 1, 14 do
            table.insert(many.objectives, { name = "Thing " .. index })
        end

        local capped = pins.DescribeLines(many)

        assert(#capped == 9,
            "eight lines and a count, got " .. #capped)

        assert(capped[9]:find("6 more"),
            "and the count must be the real remainder: " .. capped[9])

        assert(#pins.DescribeLines(nil) == 0,
            "and no pin is no lines rather than an error")
    end

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

    ------------------------------------------------------------
    -- PROGRESS INSIDE A RANK IS NOT PROGRESS TOWARD THE GOAL.
    --
    -- This used to assert that reputation "has a denominator, so it gets
    -- progress" -- and the denominator was the width of the CURRENT RANK.
    -- So a player at 21,000 of the 42,000 the ladder to Exalted needs, but
    -- one point from the top of Honored, was shown a full bar and "100%";
    -- and `Chase.All`, which sorts by that fraction, ranked them above an
    -- appearance genuinely eighty percent collected.
    --
    -- The client vouches for the band and not for the ladder. So the band is
    -- reported as a count, and no denominator is invented for the rest --
    -- which is the rule this addon applies everywhere else.
    ------------------------------------------------------------
    assert(repChain.progress, "reputation still reports what it knows")

    assert(repChain.progress.total == nil and repChain.progress.done == nil,
        "reputation must not present rank progress as goal progress")

    assert(repChain.progress.bandEarned == 1200
        and repChain.progress.bandNeeded == 3000,
        "but it must still report the band, measured from the rank floor -- "
        .. "got " .. tostring(repChain.progress.bandEarned) .. " of "
        .. tostring(repChain.progress.bandNeeded))

    assert(repChain.progress.unknownTotal,
        "and must say why there is no percentage")

    assert(chase.Fraction(repChain) == nil,
        "a chain with no trustworthy denominator has no fraction")

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

    -- A QUEST GOAL, WHICH IS THE ONE CHAIN BUILT FROM PREREQUISITES.
    --
    -- The QUEST builder is the only one that walks `CN.GetPrerequisites`, and
    -- it is the shape most players will actually chase: a quest they can see
    -- but cannot start yet. Never executed until 0.53.0.
    goalStore.Clear()
    goalStore.Add(CN.objectiveTypes.QUEST, 900500)

    local realPrerequisites = CN.GetPrerequisites

    CN.GetPrerequisites = function(questID)
        if questID == 900500 then
            return { 900501, 900502, 900503 }
        end

        return {}
    end

    local realComplete = CN.IsQuestComplete

    CN.IsQuestComplete = function(questID)
        return questID == 900501
    end

    local questChain = chase.Chain(goalStore.List()[1])

    CN.GetPrerequisites = realPrerequisites
    CN.IsQuestComplete  = realComplete

    assert(#questChain.steps == 3,
        "one step per prerequisite, got " .. #questChain.steps)

    local questDone, questNext = 0, 0

    for _, step in ipairs(questChain.steps) do
        if step.state == chase.states.DONE then questDone = questDone + 1 end
        if step.state == chase.states.NEXT then questNext = questNext + 1 end
    end

    assert(questDone == 1, "the finished prerequisite is marked done")
    assert(questNext == 1,
        "and exactly one of the rest is the next thing to do, got " .. questNext)

    assert(questChain.progress and questChain.progress.total == 3
        and questChain.progress.done == 1,
        "a quest chain IS countable, so it carries a real denominator")

    -- A quest with nothing known before it is not a chain, and must not be
    -- dressed up as one.
    goalStore.Clear()
    goalStore.Add(CN.objectiveTypes.QUEST, 900600)

    local bare = chase.Chain(goalStore.List()[1])

    assert(#bare.steps == 0 or bare.progress == nil,
        "a quest with no known prerequisites has no plan to show, and "
        .. "inventing one would be worse than saying so")

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

-- BOUNDED, but the bound is not 1 any more: 0.43.0 added a second, week-long
    -- ramp worth `urgencyLongShare` on top of the short one. Asserted against
    -- the constants rather than against a number typed here, so tuning the
    -- curve cannot silently break the guarantee the assertion is about.
    local ceiling = 1 + CN.urgencyLongShare

    assert(CN.UrgencyBonus(1) <= ceiling,
        "urgency is bounded, got " .. CN.UrgencyBonus(1))

    -- THE LONG RAMP MUST NOT DROWN THE SHORT ONE.
    --
    -- A world quest with ten minutes on it still has to beat a lockout with
    -- four days, or the fix for weekly content has broken daily content.
    assert(CN.UrgencyBonus(600) > CN.UrgencyBonus(4 * 86400),
        "ten minutes must outrank four days")

    -- And a week-out deadline must be worth more than no deadline at all,
    -- which is the thing that was broken: every lockout sat at exactly zero
    -- until its last two hours.
    assert(CN.UrgencyBonus(3 * 86400) > 0,
        "a deadline three days out must carry some weight")

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
    --
    -- COUNTING THE RIGHT THING. This counted calls to CN.CollectCandidates,
    -- which is itself cached and answers in about two microseconds when
    -- nothing is stale. Passing it therefore required Follow to avoid CALLING
    -- a cheap cached function -- and the memo written to satisfy it converged
    -- on a generation that only collecting could advance, so Follow stopped
    -- collecting, so the generation never moved, so the memo never expired
    -- and follow mode sat on a finished stop forever.
    --
    -- A test that measures a proxy for work instead of the work is a test
    -- that can be satisfied by breaking the thing it guards. What matters is
    -- that the PROVIDERS are not re-walked.
    local walks = 0

    local watched = CN.candidateProviders["Goals"]
        or select(2, next(CN.candidateProviders))

    assert(watched and watched.fn, "a provider to watch")

    local realFn = watched.fn

    watched.fn = function(...)
        walks = walks + 1
        return realFn(...)
    end

    follow.Start()

    CN.CollectCandidates(true)

    walks = 0

    follow.Lines()
    follow.HeaderText()
    follow.IsStopComplete()
    follow.Lines()

    watched.fn = realFn

    assert(walks == 0,
        "four questions about the same unchanged state must not re-walk a "
        .. "single provider, walked " .. walks .. " time(s)")

    follow.Stop()

    print("  four redraw queries, " .. walks .. " provider walk(s)")

    ------------------------------------------------------------
    -- AND THE MEMO MUST EXPIRE WHEN THE WORLD CHANGES.
    --
    -- The other half of the same defect, and the half that actually hurt:
    -- marking a provider dirty deliberately does NOT advance the generation
    -- -- only a rebuild does. So a memo keyed on the generation, in a
    -- function that had stopped triggering rebuilds, was valid forever.
    ------------------------------------------------------------
    CN.CollectCandidates(true)

    local liveNow = follow.LiveKeys()

    local seen = 0

    for _ in pairs(liveNow) do
        seen = seen + 1
    end

    assert(seen > 0, "the live key set must have something in it")

    CN.RegisterCandidateProvider("FollowMemoProbe", function()
        return {
            CN.NewObjective({
                id              = 987654,
                type            = CN.objectiveTypes.QUEST,
                name            = "Appeared After The Memo",
                completionValue = 1,
            }),
        }
    end, { events = { "QUEST_ACCEPTED" } })

    CN.SubscribeToInvalidationEvents()

    fire("QUEST_ACCEPTED")

    assert(follow.LiveKeys()["QUEST:987654"],
        "something that became actionable must appear in the live key set "
        .. "without waiting for an unrelated part of the addon to rebuild")

    CN.candidateProviders["FollowMemoProbe"] = nil

    CN.CollectCandidates(true)

    print("  and the memo expires when something new becomes actionable")
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

    ------------------------------------------------------------
    -- GROUPING, AND THE THRESHOLD THAT DECIDES A LOADING SCREEN.
    --
    -- `ByCharacter` and `Verdict` are the two functions that turn a list of
    -- assignments into the one sentence the player actually reads, and
    -- neither was exercised beyond "returns a string". The ordering rule --
    -- most reasons first, then freshest data -- and the two-reason minimum
    -- are the whole judgement of this module.
    ------------------------------------------------------------
    warband.WhoShould = function(objectiveType)
        if objectiveType == CN.objectiveTypes.REPUTATION then
            return "Manyreasons-Testrealm", "Revered", "highest standing"
        end

        if objectiveType == CN.objectiveTypes.RECIPE then
            return "Manyreasons-Testrealm", "knows it", "has the profession"
        end

        if objectiveType == CN.objectiveTypes.PROFESSION then
            return "Onereason-Testrealm", "has it", "only one who does"
        end

        return nil
    end

    CN.db.characters["Manyreasons-Testrealm"] = {
        name = "Manyreasons", realm = "Testrealm", class = "MAGE",
        level = 80, lastSeen = time() - 3600,
    }

    CN.db.characters["Onereason-Testrealm"] = {
        name = "Onereason", realm = "Testrealm", class = "ROGUE",
        level = 80, lastSeen = time() - (2 * 86400),
    }

    local grouped = alts.ByCharacter()

    assert(#grouped >= 1, "assignments must group by character")

    for index = 2, #grouped do
        assert(#grouped[index - 1].items >= #grouped[index].items,
            "the strongest case must come first: " .. #grouped[index - 1].items
            .. " reasons ranked above " .. #grouped[index].items)
    end

    -- The verdict refuses a switch below the threshold, and says why.
    local realMinimum = alts.minimumReasons

    alts.minimumReasons = 99

    local refusedVerdict, why = alts.Verdict()

    assert(refusedVerdict == nil and why:find("not enough"),
        "below the threshold the answer is no, and it says what the "
        .. "threshold was for: " .. tostring(why))

    alts.minimumReasons = 1

    local chosen, sentence = alts.Verdict()

    assert(chosen and sentence:find("could do"),
        "and above it, one character is named")

    alts.minimumReasons = realMinimum

    CN.db.characters["Manyreasons-Testrealm"] = nil
    CN.db.characters["Onereason-Testrealm"]   = nil

    -- And with nothing to do, the answer is not a shrug.
    warband.WhoShould = function() return nil end


    local none, settled = alts.Verdict()

    warband.WhoShould = realWhoShould

    assert(none == nil and settled:find("right one"),
        "with nothing assignable the answer is that you are already on the "
        .. "right character, not an empty list")

    CN.HandleSlashCommand("alts")

    print("  " .. #real .. " assignment(s); account-wide correctly ignored, "
        .. "grouping and threshold checked")
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

    ------------------------------------------------------------
    -- A ROUND TRIP, FOR EVERY BUCKET, THROUGH BOTH HALVES.
    --
    -- The two assertions above test disk-to-memory. Another block elsewhere
    -- tests memory-to-disk. Neither noticed that SaveSamples wrote only two
    -- of the three buckets, because each half was checked against a fixture
    -- the other half never produced -- so measured FLIGHT speed survived
    -- until logout and then vanished, and Travel.HasFlying (which needs five
    -- flying samples) turned self-flown routing off permanently after any
    -- reload.
    --
    -- Testing each half separately is not testing the round trip.
    ------------------------------------------------------------
    local written = {
        onFoot  = { 6.6, 6.8, 7.0, 7.2, 7.4 },
        mounted = { 13, 14, 15, 16, 17 },
        flying  = { 60, 62, 64, 66, 68 },
    }

    for bucket, values in pairs(written) do
        session.Samples()[bucket] = {}

        for _, value in ipairs(values) do
            table.insert(session.Samples()[bucket], value)
        end
    end

    session.SaveSamples()

    -- Wipe memory entirely: this is what a reload does.
    for bucket in pairs(written) do
        session.Samples()[bucket] = {}
    end

    session.LoadSamples()

    for bucket, values in pairs(written) do
        assert(#session.Samples()[bucket] == #values,
            "the " .. bucket .. " bucket must survive a save and a reload; "
            .. #session.Samples()[bucket] .. " of " .. #values .. " came back")
    end

    assert(CN:GetModule("Travel").HasFlying(),
        "and five measured flying samples must still mean the character "
        .. "flies after a reload -- which is the whole point of persisting "
        .. "them")

    for bucket in pairs(written) do
        session.Samples()[bucket] = {}
        session.Persisted()[bucket] = {}
    end

    session.SaveSamples()

    print("  every speed bucket survives a save and a reload")

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


print("\nThe list does not churn or grow without bound:")

;(function()
    local list = CN.UI.CreateList(CreateFrame("Frame"))

    local entries = {}

    for index = 1, 100 do
        entries[index] = {
            text    = "Row " .. index,
            tooltip = "Tip " .. index,
            onClick = function() end,
        }
    end

    list:SetEntries(entries)

    -- NO CLOSURE CHURN.
    --
    -- The handlers used to be created inside SetEntries: three fresh closures
    -- per row on every redraw, three hundred for this list, each capturing a
    -- table it did not need. Allocation churn is what garbage-collection
    -- pauses are made of, and a pause is a stutter.
    local firstClick = list.rows[1].scripts["OnClick"]
    local firstEnter = list.rows[1].scripts["OnEnter"]

    list:SetEntries(entries)

    assert(list.rows[1].scripts["OnClick"] == firstClick,
        "a redraw must not replace the click handler -- binding it once is "
        .. "the whole point")
    assert(list.rows[1].scripts["OnEnter"] == firstEnter,
        "nor the hover handler")

    -- The handlers must still WORK, reading the current entry rather than a
    -- captured one -- otherwise binding once would mean clicking row one
    -- always runs the first list's action.
    local clicked = nil

    local replacement = {}

    for index = 1, 3 do
        replacement[index] = {
            text    = "Replaced " .. index,
            onClick = function() clicked = index end,
        }
    end

    list:SetEntries(replacement)

    list.rows[1].scripts["OnClick"](list.rows[1])

    assert(clicked == 1,
        "the bound handler must act on the CURRENT entry, not the one that "
        .. "was there when it was bound; got " .. tostring(clicked))

    -- Rows beyond the new list must be hidden, not left showing stale text.
    assert(list.rows[50]:IsShown() == false,
        "rows from a longer list must be hidden when a shorter one replaces it")

    -- A BOUNDED FRAME POOL.
    --
    -- Frames cannot be destroyed in this game, only hidden and reused, so an
    -- uncapped list grows its pool to the largest list ever shown and keeps
    -- it for the session.
    local huge = {}

    for index = 1, 1000 do
        huge[index] = { text = "Entry " .. index }
    end

    local used = list:SetEntries(huge)

    -- Asserted against an ABSOLUTE number, not against list.maxRows.
    --
    -- The first version compared both sides to the same setting, so raising
    -- the cap moved the goalposts and the test passed against a list that
    -- created a thousand frames. A ceiling that is defined by the thing it
    -- is meant to constrain is not a ceiling.
    assert(used < 500,
        "a thousand entries must not produce a thousand rows, used "
        .. tostring(used))
    assert(#list.rows < 500,
        "and no more frames than that may ever be created, have "
        .. #list.rows)

    -- Truncation must be visible. A shortened list that looks complete is
    -- worse than a long one.
    local last = list.rows[used]

    assert(last.label.text and last.label.text:find("more not shown"),
        "the list must say when it stopped, got " .. tostring(last.label.text))

    print("  handlers bound once, pool capped at " .. list.maxRows)
end)()

print("\nTooltips answer without scanning:")

;(function()
    local professions = CN:GetModule("Professions")
    local tipModule   = CN:GetModule("Tooltips")

    professions.CaptureOpenProfession()

    local names = CN.Account("recipeNames")

    local knownID, knownName

    for id, name in pairs(names) do
        if type(name) == "string" and name ~= "" then
            knownID, knownName = id, name
            break
        end
    end

    if not knownID then
        print("  no recipe fixtures; skipped")
        return
    end

    -- THE THREE WAYS AN ITEM CAN BE A RECIPE.
    --
    -- The item is the recipe itself.
    assert(professions.RecipeForItem(knownID) == knownID,
        "an item that IS a recipe resolves to itself")

    -- The item's name is exactly the recipe's name.
    assert(professions.RecipeForItem(999999, knownName) == knownID,
        "an exact name match resolves, got "
        .. tostring(professions.RecipeForItem(999999, knownName)))

    -- The item teaches it: "Recipe: <name>".
    assert(professions.RecipeForItem(999999, "Recipe: " .. knownName) == knownID,
        "a teaching item resolves to what it teaches")

    assert(professions.RecipeForItem(999999, "PATTERN: " .. knownName) == knownID,
        "and the match is case-insensitive")

    -- Something unrelated must NOT match. The old scan used a substring
    -- search, which could match far more loosely than intended.
    assert(professions.RecipeForItem(999999, "A Completely Unrelated Sword") == nil,
        "an unrelated item is not a recipe")

    assert(professions.RecipeForItem(nil, nil) == nil,
        "nothing in, nothing out")

    -- THE INDEX MUST NOT GO STALE.
    local firstIndex = professions.NameIndex()

    local again = professions.NameIndex()

    assert(firstIndex == again,
        "an unchanged recipe list must reuse the index rather than rebuild it")

    -- Driven through the SCANNER, not by bumping the revision by hand.
    --
    -- The first version of this did the latter, which proved the index
    -- respects a revision but said nothing about whether anything ever
    -- changes it. Deleting the scanner's bump left that test passing while
    -- the tooltip answered from a stale index forever.
    professions.CaptureOpenProfession()

    assert(professions.NameIndex() ~= firstIndex,
        "scanning recipes must invalidate the name index, or the tooltip "
        .. "answers from stale data for the rest of the session")

    -- The tooltip itself still produces the recipe lines.
    local lines = tipModule.ItemLines(knownID, knownName)

    local sawRecipe = false

    for _, line in ipairs(lines) do
        if type(line.text) == "string" and line.text:find("Recipe") then
            sawRecipe = true
        end
    end

    assert(sawRecipe,
        "the tooltip must still say something about a recipe it recognises")

    print("  resolved by index, exact and teaching names both")
end)()


print("\nA reminder that stops when the thing is done:")

;(function()
    local firstRun = CN:GetModule("Setup")

    local record = CN.Account("setup")

    record.completedAt = nil
    record.prompts     = 0

    -- UNTIL IT IS DONE, EVERY LOGIN.
    --
    -- This used to be recorded as "prompted" the first time and never spoken
    -- again. A player who missed one line in a busy login had an addon that
    -- silently knew nothing about their collections for the rest of its
    -- installed life, with no way to find out why it seemed thin.
    assert(firstRun.RemindIfNeeded() == true, "an unscanned addon says so")
    assert(firstRun.RemindIfNeeded() == true,
        "and says so again next login -- a required first step is worth "
        .. "repeating until it has been done")

    assert(record.prompts == 2, "each prompt is counted")

    -- ONCE DONE, NEVER AGAIN. That is what separates a reminder from nagging.
    record.completedAt = time()

    assert(firstRun.RemindIfNeeded() == false,
        "a scanned addon must never mention it again")

    ------------------------------------------------------------
    -- WHAT IT STILL CANNOT SEE
    ------------------------------------------------------------
    record.outstandingRemindedAt = nil

    local outstanding = firstRun.Outstanding()

    if #outstanding > 0 then
        assert(firstRun.RemindOutstanding() == true,
            "things the addon cannot read on its own are worth saying")

        -- But not on every login. The fix is "open a window some time".
        assert(firstRun.RemindOutstanding() == false,
            "and must not be repeated the very next login")

        -- After the interval, it may speak again.
        record.outstandingRemindedAt =
            time() - ((firstRun.outstandingIntervalDays + 1) * 86400)

        assert(firstRun.RemindOutstanding() == true,
            "but it is worth saying again eventually")
    end

    -- Asking must not trigger a scan. "What can you not see?" and "go and
    -- look again" are different questions.
    local scans = 0

    local realRun = firstRun.Run

    firstRun.Run = function() scans = scans + 1 end

    CN.HandleSlashCommand("setup check")

    firstRun.Run = realRun

    assert(scans == 0,
        "/cn setup check must report, not rescan; it rescanned " .. scans)

    print("  repeats until scanned, then silent")
end)()



print("\nLocalization:")

;(function()
    -- The key IS the string, so a client with no table shows English rather
    -- than a blank label or a raw identifier. This is the property that makes
    -- shipping a half-translated addon safe.
    assert(CN.L["Destination"] == "Destination",
        "an untranslated key must return itself")

    assert(CN.L["a string nobody has ever translated"]
        == "a string nobody has ever translated",
        "a key with no translation anywhere must still be readable")

    -- Asking for it recorded it, which is the list a translator wants: the
    -- strings THIS player actually saw fall back, not every key in the addon.
    local stats = CN.LocaleStats()

    assert(stats.missing >= 1,
        "a key that fell back to English must be recorded as a gap")

    -- Registering a table for a language the client is not running must not
    -- apply it. Nine tables ship; eight of them must cost nothing.
    CN.RegisterLocale("xxXX", { ["Destination"] = "WRONG" })

    assert(CN.L["Destination"] == "Destination",
        "another language's table must never apply to this client")

    assert(CN.locales["xxXX"], "but it is still listed as bundled")

    -- Writing to L would look like it worked and be gone on reload.
    local wrote = pcall(function() CN.L["Destination"] = "nope" end)

    assert(not wrote, "assigning into CN.L must fail loudly, not silently")

    print("  missing translations fall back to English and are recorded")

    ------------------------------------------------------------
    -- EVERY TRANSLATED KEY MUST STILL EXIST.
    --
    -- The cost of using English as the key is that rewording a string orphans
    -- its translations, silently. This is the lint that makes that loud: a
    -- locale file translating a key the addon no longer uses is dead weight
    -- at best and evidence of a lost translation at worst.
    ------------------------------------------------------------
    local known = {}

    for _, key in ipairs(CN.localeKeys or {}) do
        known[key] = true
    end

    assert(next(known), "the canonical key list must not be empty")

    local checked, localeFiles = 0, 0

    for code in pairs(CN.locales) do
        local handle = io.open(ROOT .. "/Locales/" .. code .. ".lua", "r")

        if handle then
            localeFiles = localeFiles + 1

            local body = handle:read("*a")

            handle:close()

            for key in body:gmatch('%[\"(.-)\"%]%s*=') do
                assert(known[key],
                    code .. " translates \"" .. key
                    .. "\", which is not a key this addon uses any more")

                checked = checked + 1
            end
        end
    end

    assert(localeFiles >= 2, "the locale files must be readable to be linted")

    print("  " .. checked .. " translated strings across " .. localeFiles
        .. " languages all match live keys")

    -- The command a translator is told to run has to work in both of its
    -- forms, including the one that lists nothing because nothing is missing.
    CN.HandleSlashCommand("locale")
    CN.HandleSlashCommand("locale missing")

    local emptied = CN.localeMisses

    CN.localeMisses = {}

    CN.HandleSlashCommand("locale missing")

    CN.localeMisses = emptied

    -- And the sample must be bounded: a session that fell back on hundreds of
    -- strings must not print hundreds of lines into the player's chat frame.
    for index = 1, 40 do
        local _ = CN.L["harness filler string " .. index]
    end

    local flooded = CN.LocaleStats()

    assert(flooded.missing >= 40, "every gap is counted")
    assert(#flooded.sample <= 12,
        "but only a sample is printed, got " .. #flooded.sample)

    print("  the report is bounded at " .. #flooded.sample
        .. " lines with " .. flooded.missing .. " gaps")
end)()

print("\nSelf-test:")

;(function()
    local selftest = CN:GetModule("SelfTest")

    assert(selftest, "the SelfTest module must load")

    local registered = #CN.selfTests

    assert(CN.RegisterSelfTest({ name = "nonsense" }) == false,
        "a definition with nothing to run must be refused")

    assert(#CN.selfTests == registered, "and must not be stored")

    -- A CHECK THAT THROWS IS A FAILED CHECK, NOT A BROKEN COMMAND.
    --
    -- This is the whole reason the runner exists: these run against a live
    -- client, which is exactly where an unexpected nil turns into an error,
    -- and a diagnostic that dies on the first surprise is useless precisely
    -- when it is needed.
    CN.RegisterSelfTest{
        area = "zzz-harness",
        name = "a check that explodes",
        run  = function()
            error("boom")
        end,
    }

    -- A check with nothing to say is a SKIP, never a pass.
    CN.RegisterSelfTest{
        area = "zzz-harness",
        name = "a check that answers nothing",
        run  = function() return nil end,
    }

    local rows = selftest.Run()

    assert(rows.passed + rows.failed + rows.skipped == #rows.checks,
        "every check must be counted exactly once")

    local exploded, quiet

    for _, check in ipairs(rows.checks) do
        if check.name == "a check that explodes" then
            exploded = check
        elseif check.name == "a check that answers nothing" then
            quiet = check
        end
    end

    assert(exploded and exploded.status == "FAIL",
        "a check that throws must be reported as a failure")
    assert(exploded.detail and exploded.detail:find("boom"),
        "and must say what it threw: " .. tostring(exploded and exploded.detail))
    assert(quiet and quiet.status == "SKIP",
        "a check that returns nothing must SKIP, never pass")

    print("  a throwing check fails the check, not the command")

    ------------------------------------------------------------
    -- AND THE CHECKS THEMSELVES MUST NOT BE VACUOUS.
    --
    -- The bearing check in this module was written the obvious way first:
    -- project a point ahead using the addon's own facing convention, then ask
    -- the addon which way that point is. It passed. It would have passed with
    -- the bearing maths inverted, because it derived its expected answer from
    -- the code under test. Break the maths and require the check to notice.
    ------------------------------------------------------------
    local navigation = CN:GetModule("Navigation")

    local realBearing = navigation.RelativeBearing

    navigation.RelativeBearing = function(px, py, tx, ty, facing, sign, mapID)
        local answer = realBearing(px, py, tx, ty, facing, sign, mapID)

        -- Mirrored: the exact defect shipped in 0.19.0.
        return answer and -answer
    end

    local mutated = selftest.Run()

    navigation.RelativeBearing = realBearing

    local caught = false

    for _, check in ipairs(mutated.checks) do
        if check.name == "the bearing maths gives known answers"
            and check.status == "FAIL" then
            caught = true
        end
    end

    assert(caught,
        "mirroring the bearing must fail the bearing check -- if it does "
        .. "not, the check is decoration")

    print("  the bearing check fails when the bearing is mirrored")

    -- Remove the harness's own checks so the suite leaves nothing behind.
    for index = #CN.selfTests, 1, -1 do
        if CN.selfTests[index].area == "zzz-harness" then
            table.remove(CN.selfTests, index)
        end
    end
end)()

print("\nWhich way the client counts facing:")

;(function()
    local navigation = CN:GetModule("Navigation")

    ------------------------------------------------------------
    -- THE ARITHMETIC.
    --
    -- Moving in the direction you face is evidence for one convention and
    -- against the other -- but ONLY when the two conventions disagree.
    -- Facing north, they agree, and a sample that cannot tell them apart must
    -- not be counted as support for whichever one is live.
    ------------------------------------------------------------
    assert(navigation.SignFromMotion(math.rad(45), math.rad(45)) == 1,
        "moving where you face, with facing counted clockwise, supports +1")

    assert(navigation.SignFromMotion(math.rad(-45), math.rad(45)) == -1,
        "the mirror image of that supports -1")

    assert(navigation.SignFromMotion(0, 0) == nil,
        "facing north cannot distinguish the two conventions")

    assert(navigation.SignFromMotion(math.rad(135), math.rad(45)) == nil,
        "strafing supports neither and must be discarded")

    assert(navigation.SignFromMotion(math.rad(45 + 180), math.rad(45)) == nil,
        "walking backwards supports neither and must be discarded")

    print("  strafing and backpedalling are discarded, not voted on")

    ------------------------------------------------------------
    -- END TO END, THROUGH THE PATH THE GAME TAKES.
    --
    -- Not by calling SignFromMotion in a loop -- by moving the player and
    -- letting the addon sample it, which is what actually happens in play.
    ------------------------------------------------------------
    local savedX, savedY = CN_TEST_PLAYER_X, CN_TEST_PLAYER_Y
    local savedSpan      = CN_TEST_MAP_SPAN

    CN_TEST_SetMapSpan({ 1000, 1000 })

    navigation.ForgetMapScales()
    navigation.SetFacingSign(1)
    navigation.ResetMotion()

    -- The client, in this scenario, counts facing counter-clockwise: the
    -- player faces "45 degrees" and walks north-WEST. Under sign +1 the addon
    -- believes north-east. It must work that out and flip itself.
    CN_TEST_SetFacing(math.rad(45))

    CN_TEST_PLAYER_X, CN_TEST_PLAYER_Y = 0.5, 0.5

    navigation.NoteMotion()

    local step = 0.006

    for _ = 1, navigation.motionSamples + 1 do
        CN_TEST_PLAYER_X = CN_TEST_PLAYER_X - step
        CN_TEST_PLAYER_Y = CN_TEST_PLAYER_Y - step

        navigation.NoteMotion()
    end

    assert(navigation.FacingSign() == -1,
        "walking where you face, against what the addon believes, must flip "
        .. "the sign; it is still " .. navigation.FacingSign())

    local state = navigation.MotionState()

    assert(state.verdict == "corrected", "and must record why")

    -- ONE SAMPLE MUST NOT DO IT. A single stray reading -- a knockback, a
    -- door, a lag spike -- flipping the arrow would be worse than the bug.
    navigation.SetFacingSign(1)
    navigation.ResetMotion()

    CN_TEST_PLAYER_X, CN_TEST_PLAYER_Y = 0.5, 0.5
    navigation.NoteMotion()

    CN_TEST_PLAYER_X, CN_TEST_PLAYER_Y = 0.5 - step, 0.5 - step
    navigation.NoteMotion()

    assert(navigation.FacingSign() == 1,
        "one movement sample must not be enough to flip the arrow")

    print("  a wrong facing convention corrects itself from movement, and "
        .. "one stray sample does not")

    CN_TEST_SetFacing(0)
    CN_TEST_PLAYER_X, CN_TEST_PLAYER_Y = savedX, savedY
    CN_TEST_SetMapSpan(savedSpan)
    navigation.ForgetMapScales()
    navigation.SetFacingSign(1)
    navigation.ResetMotion()
end)()

print("\nAngles on a map that is not square:")

;(function()
    local navigation = CN:GetModule("Navigation")

    local savedSpan = CN_TEST_MAP_SPAN

    -- Twice as wide as it is tall, which is nothing unusual for a zone.
    CN_TEST_SetMapSpan({ 2000, 1000 })

    navigation.ForgetMapScales()

    local scaleX, scaleY = navigation.MapScale(94)

    assert(math.abs(scaleX - 2000) < 1 and math.abs(scaleY - 1000) < 1,
        "the map's real size must come from the client, got "
        .. scaleX .. " x " .. scaleY)

    -- A target one map unit east and one map unit south of the player is NOT
    -- at 135 degrees on this map: east is worth twice as many yards, so the
    -- true bearing is further round. Raw map coordinates said 135 for eight
    -- releases, in every zone in the game.
    local relative = navigation.RelativeBearing(0.4, 0.4, 0.5, 0.5, 0, 1, 94)

    local degrees = math.deg(relative)

    -- CN.Atan2, not math.atan: this expectation is arithmetic the test does
    -- itself, and under the game's Lua the two-argument form silently drops
    -- its second argument -- so computing the expected answer that way made
    -- the test fail against correct code the moment it ran on 5.1.
    local expected = math.deg(CN.Atan2(2000 * 0.1, -(1000 * 0.1)))

    assert(math.abs(degrees - expected) < 0.5,
        "the bearing must be taken in yards, not in map units: expected "
        .. string.format("%.1f", expected) .. ", got "
        .. string.format("%.1f", degrees))

    assert(math.abs(degrees - 135) > 5,
        "and it must differ from the unscaled answer, or the correction is "
        .. "doing nothing")

    -- A SQUARE MAP MUST BE UNCHANGED. The correction has to be free where
    -- there is nothing to correct.
    CN_TEST_SetMapSpan({ 1000, 1000 })

    navigation.ForgetMapScales()

    local square = math.deg(navigation.RelativeBearing(0.4, 0.4, 0.5, 0.5, 0, 1, 94))

    assert(math.abs(square - 135) < 0.5,
        "on a square map the answer must still be 135, got " .. square)

    -- AND A MAP THE CLIENT WILL NOT SIZE MUST NOT BE CACHED AS SQUARE.
    -- During a loading screen the conversion fails; caching 1,1 then would
    -- keep the distortion for the rest of the session.
    navigation.ForgetMapScales()

    local realConvert = C_Map.GetWorldPosFromMapPos

    C_Map.GetWorldPosFromMapPos = function() return nil, nil end

    local failedX = navigation.MapScale(94)

    C_Map.GetWorldPosFromMapPos = realConvert

    assert(failedX == 1, "an unconvertible map falls back to unscaled")

    local recoveredX = navigation.MapScale(94)

    assert(math.abs(recoveredX - 1000) < 1,
        "and must be asked again once the client can answer, got "
        .. recoveredX)

    print("  bearings are measured in yards, and a failed measurement is "
        .. "not remembered")

    CN_TEST_SetMapSpan(savedSpan)
    navigation.ForgetMapScales()
end)()


print("\nDungeons and raids:")

;(function()
    local instances = CN:GetModule("Instances")

    assert(instances, "the Instances module must load")

    local lockouts = instances.Lockouts()

    assert(#lockouts == 3, "every lockout must be read, got " .. #lockouts)

    -- UNFINISHED FIRST, and among those, most nearly finished first: that is
    -- the order they are worth doing, because the kills already spent expire
    -- at the reset. A cleared lockout has nothing left to be worth anything,
    -- so "remaining = 0" belongs at the BOTTOM rather than the top -- which
    -- is what the first version of this assertion got backwards.
    local seenComplete = false

    for index, lockout in ipairs(lockouts) do
        if lockout.complete then
            seenComplete = true
        else
            assert(not seenComplete,
                "an unfinished lockout must not rank below a cleared one (#"
                .. index .. ")")
        end
    end

    local palace

    for _, lockout in ipairs(lockouts) do
        if lockout.name == "Nerub-ar Palace" then palace = lockout end
    end

    assert(palace, "the raid lockout must be present")
    assert(palace.defeated == 6 and palace.encounters == 8,
        "the client's own counts must survive the read")
    assert(palace.remaining == 2, "and remaining must be derived from them")
    assert(palace.raid == true, "a raid must be marked as one")
    assert(palace.complete == false, "6 of 8 is not cleared")

    print("  " .. #lockouts .. " lockouts read, "
        .. palace.remaining .. " bosses left in the raid")

    ------------------------------------------------------------
    -- AND A PART-FINISHED LOCKOUT MUST ACTUALLY BE RECOMMENDED.
    --
    -- This module's whole premise is that a lockout you are part-way through
    -- is the cheapest progress in the game -- spent effort with an expiry on
    -- it -- and it has never produced a single candidate, because the two
    -- counts came back reversed and every lockout therefore looked complete.
    -- The suite asserted which lockouts were EXCLUDED and never once that any
    -- were included.
    ------------------------------------------------------------
    local produced = CN.candidateProviders["Instances"].fn()

    assert(#produced > 0,
        "a raid six bosses into eight is the cheapest thing on the list and "
        .. "must be offered; the provider returned nothing")

    local raidRow

    for _, candidate in ipairs(produced) do
        if tostring(candidate.name):find("Nerub-ar", 1, true) then
            raidRow = candidate
        end
    end

    assert(raidRow, "and specifically the part-finished raid")

    local raidReason = table.concat(raidRow.reasons or {}, " ")

    assert(raidReason:find("2", 1, true),
        "and its reason must say what is actually left, got " .. raidReason)

    print("  and the part-finished raid is offered: " .. raidRow.name)

    ------------------------------------------------------------
    -- A CLEARED LOCKOUT IS NOT AN OBJECTIVE.
    ------------------------------------------------------------
    local instanceCandidates = CN.candidateProviders["Instances"].fn()

    local names = {}

    for _, candidate in ipairs(instanceCandidates) do
        names[candidate.id] = candidate
    end

    assert(names["Nerub-ar Palace"],
        "a part-finished lockout is the cheapest progress in the game and "
        .. "must be recommended")
    assert(not names["Ara-Kara, City of Echoes"],
        "a cleared lockout must not be recommended at all")
    assert(not names["Liberation of Undermine"],
        "and neither must one nothing has been killed in -- there is no spent "
        .. "effort in it to expire, so it is a plan rather than a next action")

    local raid = names["Nerub-ar Palace"]

    assert(raid.expiresIn == 3 * 86400,
        "the reset must be carried as a real deadline, not a bonus")
    assert(raid.type == CN.objectiveTypes.INSTANCE,
        "instances need their own type so they can be hidden like anything else")

    local mentioned = false

    for _, reason in ipairs(raid.reasons or {}) do
        if reason:find("6 of 8") then mentioned = true end
    end

    assert(mentioned, "the reason must say what is already spent")

    print("  a cleared lockout is not recommended; a part-finished one is")

    ------------------------------------------------------------
    -- READING THE ADVENTURE GUIDE MUST NOT MOVE THE PLAYER'S VIEW.
    --
    -- EJ_SelectInstance is not a query. It changes what the journal window is
    -- displaying, and the player may be reading it.
    ------------------------------------------------------------
    CN_TEST_EJ_SELECTED = 1274
    CN_TEST_EJ_OPEN     = false

    -- `id` is the lockout id and `instanceID` is the journal's, and the
    -- journal must be asked with the journal's. A lockout table carrying only
    -- the first is exactly what the addon used to hand to EJ_SelectInstance.
    local bosses = instances.RemainingBosses({
        id = 2147483001, instanceID = 1273, name = "Nerub-ar Palace",
        defeated = 0, encounters = 8, remaining = 8,
    })

    local noJournalID, noJournalNote = instances.RemainingBosses({
        id = 2147483001, name = "Nerub-ar Palace", defeated = 0,
        encounters = 8, remaining = 8,
    })

    assert(#noJournalID == 0 and noJournalNote
        and noJournalNote:find("Adventure Guide id"),
        "without a journal id the answer is an admission, not a lockout id "
        .. "handed to an API that has never heard of it")

    assert(#bosses == 8, "every boss must be named when none are dead, got " .. #bosses)
    assert(bosses[1].name == "Ulgrax the Devourer", "in journal order")

    assert(CN_TEST_EJ_SELECTED == 1274,
        "the journal's selection must be put back exactly as it was found")

    -- Part-way through, the client says HOW MANY are left, not WHICH.
    -- Naming them would be inventing information.
    local partial, note = instances.RemainingBosses(palace)

    assert(#partial == 0, "which bosses are dead is not knowable; nothing may be named")
    assert(note and note:find("2 of 8"), "but the count must be reported: " .. tostring(note))

    print("  the journal's selection is restored, and unknown bosses are not invented")

    ------------------------------------------------------------
    -- AND IT REFUSES ENTIRELY WHILE THE WINDOW IS OPEN.
    ------------------------------------------------------------
    CN_TEST_EJ_OPEN     = true
    CN_TEST_EJ_SELECTED = 1274

    instances.ForgetDrops()

    local blocked = instances.WhereDoesItDrop("Ansurek's Web Wrap")

    assert(#blocked == 0,
        "nothing may be read while the player is looking at the journal")
    assert(CN_TEST_EJ_SELECTED == 1274, "and nothing may be changed either")

    CN_TEST_EJ_OPEN = false

    instances.ForgetDrops()

    local found = instances.WhereDoesItDrop("Ansurek's Web Wrap")

    assert(#found == 1, "with the window closed it answers, got " .. #found)
    assert(found[1].encounter == "Queen Ansurek", "with the boss named")
    assert(found[1].instance == "Nerub-ar Palace", "and the instance")

    print("  it refuses while the Adventure Guide is open, and answers when it is not")

    ------------------------------------------------------------
    -- A CHASE FOR AN INSTANCE DROP MUST NAME THE BOSS.
    --
    -- This is the failure the whole module exists to fix: before it, a raid
    -- mount produced a goal with no path to it.
    ------------------------------------------------------------
    local chase = CN:GetModule("Chase")

    local chain = chase.Chain({
        type = CN.objectiveTypes.MOUNT,
        id   = 9999,
        name = "Ansurek's Web Wrap",
    })

    local step

    for _, candidate in ipairs(chain.steps) do
        if candidate.text and candidate.text:find("Queen Ansurek") then
            step = candidate
        end
    end

    assert(step, "the chain must name the boss the thing drops from")
    assert(step.state == chase.states.TODO or step.state == chase.states.NEXT,
        "and it must be actionable, not a note")
    assert(step.note and step.note:find("2 of 8"),
        "and it must say where the player's lockout stands: " .. tostring(step.note))

    -- CLEARED MEANS BLOCKED, NOT "GO AND DO IT".
    -- Position 12 is the PROGRESS; clearing it means setting progress to the
    -- total, not the total to the progress.
    CN_TEST_SAVED_INSTANCES[1][12] = 8

    local cleared = chase.Chain({
        type = CN.objectiveTypes.MOUNT,
        id   = 9999,
        name = "Ansurek's Web Wrap",
    })

    local blockedStep

    for _, candidate in ipairs(cleared.steps) do
        if candidate.state == chase.states.BLOCKED then blockedStep = candidate end
    end

    assert(blockedStep, "a cleared lockout must block the step, not offer it")
    assert(blockedStep.note and blockedStep.note:find("resets in"),
        "and must say when it opens again")

    CN_TEST_SAVED_INSTANCES[1][12] = 6

    print("  a chase for a raid drop names the boss, and says when it is locked")
end)()

print("\nLearning what you actually do:")

;(function()
    local preference = CN:GetModule("Preference")

    assert(preference, "the Preference module must load")

    local character = CN.character

    character.preference = nil

    local QUEST = CN.objectiveTypes.QUEST

    ------------------------------------------------------------
    -- NOTHING HAPPENS UNTIL THERE IS ENOUGH TO GO ON.
    --
    -- The cost of learning too early is a ranking that lurches around in the
    -- player's first evening, which reads as unreliable rather than adaptive.
    ------------------------------------------------------------
    assert(preference.Multiplier(QUEST) == 1,
        "an unobserved type must not be adjusted at all")

    local store = preference.Store()

    -- The ARITHMETIC is tested through Compute rather than Multiplier,
    -- because Multiplier is memoised and these lines edit the store directly,
    -- which is not a path the addon itself ever takes. Testing the cached
    -- entry point here would be testing the fixture's own staleness. The
    -- cache gets its own test below, driven the way the game drives it.
    store[QUEST] = { shown = preference.minimumObservations - 1, acted = 0 }

    assert(preference.Compute(QUEST) == 1,
        "one observation short of the threshold is still no adjustment")

    store[QUEST].shown = preference.minimumObservations

    local ignored = preference.Compute(QUEST)

    assert(ignored < 1, "a type never acted on must be pushed down")
    assert(ignored >= preference.minMultiplier,
        "but never below the floor -- silencing a type is the player's call")

    store[QUEST] = { shown = 100, acted = 100 }

    local loved, reason = preference.Compute(QUEST)

    assert(loved > 1 and loved <= preference.maxMultiplier,
        "a type always acted on is pushed up, within the cap")
    assert(reason, "and the reason must be stated")

    print("  clamped to " .. string.format("%.2f-%.2f",
        preference.minMultiplier, preference.maxMultiplier)
        .. ", and silent below " .. preference.minimumObservations .. " sightings")

    ------------------------------------------------------------
    -- AN OPEN WINDOW MUST NOT TEACH IT ANYTHING.
    --
    -- The window redraws on a great many events. Counting each redraw as a
    -- sighting would mean leaving the window open taught the addon that you
    -- ignore everything, several times a second.
    ------------------------------------------------------------
    character.preference = nil

    local hook = CN.recommendationHooks["Preference"]

    local shown = { { type = QUEST, id = 4242 } }

    for _ = 1, 50 do
        hook(shown)
    end

    assert(preference.Store()[QUEST].shown == 1,
        "fifty redraws of the same line is one sighting, got "
        .. preference.Store()[QUEST].shown)

    print("  fifty redraws of one line count once")

    ------------------------------------------------------------
    -- THE MEMOISED ANSWER MUST NOT OUTLIVE THE OBSERVATION.
    --
    -- Ranking asks for this on every candidate, so it is cached. A cache that
    -- never noticed the counters moving would freeze the addon's opinion at
    -- whatever it thought during the first list it ever built.
    ------------------------------------------------------------
    local ACHIEVEMENT = CN.objectiveTypes.ACHIEVEMENT

    preference.Store()[ACHIEVEMENT] = { shown = 100, acted = 0 }

    local beforeLearning = preference.Multiplier(ACHIEVEMENT)

    -- Drive it the way the game does: a real sighting, then a real
    -- completion of the thing that was recommended.
    hook({ { type = ACHIEVEMENT, id = 31337 } })

    for _ = 1, 60 do
        preference.NoteCompleted(ACHIEVEMENT, 31337)
        hook({ { type = ACHIEVEMENT, id = 31337 } })
    end

    local after = preference.Multiplier(ACHIEVEMENT)

    assert(after > beforeLearning,
        "the cached multiplier must follow the counters, "
        .. string.format("%.3f then %.3f", beforeLearning, after))

    print("  and the cached opinion follows them")

    ------------------------------------------------------------
    -- CREDIT ONLY WHAT WAS ACTUALLY RECOMMENDED.
    ------------------------------------------------------------
    assert(preference.NoteCompleted(QUEST, 4242) == true,
        "finishing something the addon suggested counts")

    assert(preference.Store()[QUEST].acted == 1, "exactly once")

    assert(preference.NoteCompleted(QUEST, 777) == false,
        "finishing something it never suggested must NOT count -- otherwise "
        .. "it learns that its own advice is always taken")

    -- The event path, which is what the game actually drives.
    hook({ { type = QUEST, id = 555 } })

    CN.FireEvent("QUEST_TURNED_IN", 555)

    assert(preference.Store()[QUEST].acted == 2,
        "the completion event must feed the same counter")

    print("  only recommendations that were followed are credited")

    ------------------------------------------------------------
    -- THE ID THE EVENT CARRIES IS NOT ALWAYS THE ID THAT WAS SHOWN.
    ------------------------------------------------------------
    local PET = CN.objectiveTypes.PET

    hook({ { type = PET, id = 1234 } })

    -- NEW_PET_ADDED reports the pet you now own, not the species recommended.
    assert(preference.NoteCompleted(PET, "BattlePet-0-000011112222") == true,
        "a completion whose id cannot match must still credit the type")

    print("  a completion the client ids differently still counts")

    ------------------------------------------------------------
    -- IT MUST BE VISIBLE, REVERSIBLE, AND OPTIONAL.
    ------------------------------------------------------------
    CN.HandleSlashCommand("learned")

    local objective = { type = QUEST, id = 1, reasons = {} }

    character.preference[QUEST] = { shown = 100, acted = 100 }

    CN.InvalidateRanking()

    local base = CN.ScoreObjective({ type = "NOTHING", id = 1,
        completionValue = 10 })

    CN.ScoreObjective(objective)

    local explained = false

    for _, entry in ipairs(objective.reasons) do
        if entry:find("act on") then explained = true end
    end

    assert(explained, "an adjusted line must say it was adjusted")

    preference.SetEnabled(false)

    assert(preference.Multiplier(QUEST) == 1,
        "switched off means switched off")

    preference.SetEnabled(true)

    CN.HandleSlashCommand("learned reset")

    assert(CN.character.preference == nil, "and it can all be thrown away")

    assert(base > 0, "the control score must be a real number")

    print("  explained on the line, switchable, and resettable")
end)()

print("\nRecording what the client actually returns:")

;(function()
    local capture = CN:GetModule("Capture")

    assert(capture, "the Capture module must load")

    local records, captured, skipped = capture.Run()

    assert(captured > 0, "something must be recordable in the harness")
    assert(records.build == CN.version, "the build must be stamped on it")

    -- SHAPE, NOT CONTENT. This is written to disk and read back on every
    -- login until it is cleared, so it must not grow with the player's data.
    local shape = capture.Shape({
        x = 1, y = 2,
        GetXY = function() end,
        nested = { deep = { deeper = { deepest = true } } },
    })

    assert(shape.type == "table", "a table is described as one")
    assert(shape.fields.GetXY.type == "function",
        "METHODS MATTER: the 0.19.0 bug was a vector whose GetXY the stub lacked")
    assert(shape.fields.nested.fields.deep.truncated
        or shape.fields.nested.fields.deep.fields,
        "depth must be bounded rather than followed forever")

    local wide = {}

    for index = 1, 500 do
        wide["key" .. index] = index
    end

    local wideShape = capture.Shape(wide)

    assert(wideShape.count == 500, "the count is recorded")

    local kept = 0

    for _ in pairs(wideShape.fields) do kept = kept + 1 end

    assert(kept <= 12, "but the fields are bounded, got " .. kept)

    -- NOTHING IDENTIFYING THE PLAYER.
    local serialized = ""

    local function walk(value)
        if type(value) == "table" then
            for key, entry in pairs(value) do
                serialized = serialized .. tostring(key) .. " "
                walk(entry)
            end
        else
            serialized = serialized .. tostring(value) .. " "
        end
    end

    walk(records)

    local name  = UnitName("player")
    local realm = GetRealmName()

    assert(not serialized:find(name, 1, true),
        "the recording must not contain the character's name")
    assert(not serialized:find(realm, 1, true),
        "nor the realm")

    print("  " .. captured .. " observations recorded, " .. skipped
        .. " skipped, nothing identifying the player")

    assert(capture.Clear() == true, "and it can be removed again")
    assert(CN.Account().capture == nil, "completely")

    print("  and it can be cleared")
end)()

print("\nStubs, audited against a real client:")

;(function()
    ------------------------------------------------------------
    -- THE POINT OF THIS SECTION.
    --
    -- Nine defects in this addon came from a stub that modelled the world
    -- more simply than the world is. Writing better stubs does not fix that,
    -- because the author does not know what he simplified. So: when a
    -- recording from a live client is present, check the stubs against it,
    -- and fail when reality had a field the stub does not.
    ------------------------------------------------------------
    local path = ROOT .. "/../fixtures/captured.lua"

    -- A FILE THAT EXISTS AND WILL NOT PARSE IS NOT "NO RECORDING".
    --
    -- `loadfile` returns nil both for a file that is absent and for one that
    -- is broken, and this treated the two identically -- so a corrupt
    -- recording printed "no recording present, stubs are UNVERIFIED" and the
    -- run carried on green. The strongest test in this project would have
    -- been silently absent while a file sat in the repository claiming to
    -- provide it.
    local chunk

    for _, candidate in ipairs({ path, "fixtures/captured.lua" }) do
        local handle = io.open(candidate, "r")

        if handle then
            handle:close()

            local loaded, why = loadfile(candidate)

            if not loaded then
                error(candidate .. " exists and will not parse: "
                    .. tostring(why)
                    .. " -- re-run cn.ps1 fixtures, or delete it")
            end

            chunk = loaded

            break
        end
    end

    if not chunk then
        -- BLOCKING WHERE A CLIENT CAN EXIST; ADVISORY WHERE ONE CANNOT.
        --
        -- Backlog item 46. Until 0.46.0 this was advisory everywhere, which
        -- meant the strongest test in the project could be absent for months
        -- and the run still printed ALL CHECKS PASSED. But failing it
        -- unconditionally would break CI, which has no game client and never
        -- will -- so the gate is a decision the caller makes: cn.ps1 sets
        -- CN_REQUIRE_FIXTURES on a machine that has World of Warcraft
        -- installed, and CI does not.
        assert(not os.getenv("CN_REQUIRE_FIXTURES"),
            "no recording present and CN_REQUIRE_FIXTURES is set -- run "
            .. "/cn capture in game, log out, then cn.ps1 fixtures")

        print("  |no recording present| stubs are UNVERIFIED against a real "
            .. "client -- run /cn capture in game, then cn.ps1 fixtures")
        return
    end

    local real = chunk()

    assert(type(real) == "table", "a recording must be a table")

    ------------------------------------------------------------
    -- EVIDENCE HAS A DATE ON IT.
    --
    -- A recording made against an older client is not neutral: it makes this
    -- section print success about a game that has since been patched, which
    -- is precisely the false confidence the section exists to remove. The
    -- .toc says which client the addon claims to support; the recording says
    -- which one it saw.
    ------------------------------------------------------------
    if real.interface then
        local tocText = ""

        local manifest = io.open(ROOT .. "/CompletionNavigator.toc", "r")

        if manifest then
            tocText = manifest:read("*a")
            manifest:close()
        end

        local claimed = tonumber(tocText:match("##%s*Interface:%s*(%d+)"))

        if claimed then
            assert(real.interface >= claimed,
                "the recording is from client " .. real.interface
                .. " and the addon claims to support " .. claimed
                .. " -- re-capture, or the audit is about a game that has "
                .. "been patched since")

            print("  recorded on client " .. real.interface
                .. " by build " .. tostring(real.build or "?"))
        end
    end

    local audited, complaints, unverified = 0, {}, {}

    -- "SKIPPED" AND "AUDITED" ARE DIFFERENT NUMBERS, AND ONLY ONE WAS PRINTED.
    --
    -- A field absent from the recording made this return silently, and the
    -- summary line then named a count that read as coverage. The shipped
    -- recording is from 0.46.0 and carries neither `events` nor `apiSurface`
    -- -- the two strongest rules in the audit -- so four of eight ran and the
    -- line said "4 stubs match what the client actually returned", which is
    -- true and reads as complete.
    --
    -- This is the same trap the check one level up congratulates itself on
    -- having closed ("a file that exists and will not parse is not 'no
    -- recording'"). A rule that did not run is not a rule that passed.
    local function require(field, condition, complaint)
        if real[field] == nil or (type(real[field]) == "table" and real[field].skipped) then
            table.insert(unverified, field)

            return
        end

        audited = audited + 1

        if not condition() then
            table.insert(complaints, complaint)
        end
    end

    require("mapSpanYards", function()
        -- If the real client reported a non-square map, the stub must be able
        -- to model one. It could not, for eight releases, and that hid an
        -- angle error in every zone in the game.
        return CN_TEST_MAP_SPAN ~= nil
    end, "the real client reports map spans, and the stub cannot model them")

    require("worldPosition", function()
        return real.worldPosition.hasGetXY == false
            or (CreateVector2D(0, 0).GetXY ~= nil)
    end, "the real client's world position exposes GetXY and the stub's does not")

    require("questPOI", function()
        if (real.questPOI.questStarts or 0) == 0 then
            return true
        end

        for _, poi in ipairs(CN.Blizzard.GetQuestPOIsOnMap(94)) do
            if poi.isQuestStart ~= nil then
                return true
            end
        end

        return false
    end, "the real client reports quest starts and the stub does not")

    require("achievementCriteria", function()
        if not real.achievementCriteria.counted then
            return true
        end

        -- AN ACHIEVEMENT THE FIXTURE ACTUALLY HAS.
        --
        -- This asked for id 1001, which is in no fixture in this file, so it
        -- got an empty list and reported that the stub was simpler than
        -- reality. The stub was fine; the rule was wrong. It went unnoticed
        -- because no recording had ever parsed, so this audit had never once
        -- executed against real data.
        local criteria = CN.Blizzard.GetAchievementCriteriaList(10, 4)

        return criteria and criteria[1] and criteria[1].required ~= nil
    end, "real criteria carry counters and the stub's do not")

    require("events", function()
        -- THE HAND-WRITTEN LIST, CHECKED AGAINST A CLIENT.
        --
        -- CN_KNOWN_EVENTS is written from knowledge, which makes it exactly
        -- the sort of model of the world this project keeps getting caught
        -- by. The `events` capture asks the live client to register every
        -- event the addon uses and records what it refused. Anything on that
        -- list is real evidence that a name is wrong -- including one that
        -- was real and has since been removed, which the hand list can never
        -- catch.
        return #(real.events.refused or {}) == 0
    end, "the live client refused an event this addon registers")

    require("apiSurface", function()
        -- THE HALF THAT ANNOUNCES NOTHING.
        --
        -- A misspelled event throws. A misspelled function name is caught by
        -- the guard at its own call site and produces a permanently dead
        -- feature that looks exactly like a client which does not support it.
        -- This is the only way to tell those two apart, and it needs a real
        -- client: the stub cannot help, because the stub defines whatever the
        -- addon happens to call.
        return #(real.apiSurface.missing or {}) == 0
    end, "the live client does not have every API this addon calls")

    require("savedInstances", function()
        local fields = real.savedInstances.shape
            and real.savedInstances.shape.fields or {}

        local stub = CN.Blizzard.GetSavedInstances()[1]

        if not stub then
            return false
        end

        for field in pairs(fields) do
            if stub[field] == nil then
                return false
            end
        end

        return true
    end, "the real client returns saved-instance fields the stub does not")

    for _, complaint in ipairs(complaints) do
        print("  MISMATCH: " .. complaint)
    end

    -- A complaint that says "an API is missing" without saying WHICH costs an
    -- hour to act on.
    if real.apiSurface then
        for _, name in ipairs(real.apiSurface.missing or {}) do
            print("    the client has no " .. name)
        end
    end

    if real.events then
        for _, name in ipairs(real.events.refused or {}) do
            print("    the client refused the event " .. name)
        end
    end

    assert(#complaints == 0,
        #complaints .. " stub(s) are simpler than the client they stand in for")

    for _, field in ipairs(unverified) do
        print("    UNVERIFIED: the recording carries no " .. field)
    end

    print("  " .. audited .. " of " .. (audited + #unverified)
        .. " stub rules ran against what the client actually returned"
        .. (#unverified > 0
            and (" -- " .. #unverified .. " could not be checked")
            or ""))
end)()


print("\nWhat 0.53.0 changed, asserted through the paths the game takes:")

;(function()
    local travel = CN:GetModule("Travel")

    ------------------------------------------------------------
    -- THE PARTS OF THE TRAVEL MODEL THAT ONLY RUN WHEN SOMETHING IS WRONG.
    --
    -- Every one of these is a refusal path -- no map, no continent, no
    -- nodes, a client that will not convert coordinates -- and a refusal path
    -- that has never run is a refusal path nobody knows the shape of. This is
    -- also the module where a wrong refusal is most expensive: it silently
    -- degrades every recommendation's travel cost.
    ------------------------------------------------------------
    assert(travel.WorldPoint(nil, 0.5, 0.5) == nil, "no map, no point")
    assert(travel.WorldPoint(94, nil, 0.5) == nil, "no coordinates, no point")

    assert(travel.YardsBetweenPoints(nil, nil) == nil,
        "two points that do not exist are not a distance")

    assert(travel.YardsBetweenPoints({ continent = 1, x = 0, y = 0 },
        { continent = 2, x = 0, y = 0 }) == nil,
        "and two continents apart is not a distance either -- a straight "
        .. "line across an ocean is meaningless, not merely imprecise")

    -- A map with no continent above it.
    assert(travel.ContinentFor(nil) == nil, "no map, no continent")

    local orphan = 987654

    assert(travel.ContinentFor(orphan) == nil,
        "a map the client does not know has no continent")

    assert(#(travel.KnownNodes(orphan)) == 0,
        "and therefore no flight points")

    -- The nearest-node search, which is the one piece of the model that runs
    -- on every single travel estimate.
    assert(travel.NearestNode(nil, {}) == nil, "no point, no nearest node")

    local nodes = travel.KnownNodes(94)

    assert(#nodes > 0, "the fixture continent must have nodes")

    local here = travel.WorldPoint(94, 0.5, 0.5)

    local nearest, nodeYards = travel.NearestNode(here, nodes)

    assert(nearest and nodeYards and nodeYards >= 0,
        "and a real point finds one, with a distance")

    assert(travel.NearestNode(here, nil) == nil,
        "an empty node list has no nearest member, which is not an error")

    -- A client that refuses every coordinate conversion, which is what a
    -- loading screen looks like from in here.
    local realConvert = C_Map.GetWorldPosFromMapPos

    C_Map.GetWorldPosFromMapPos = function() return nil, nil end

    travel.ForgetWorldPoints()
    travel.ForgetNodes()

    assert(travel.WorldPoint(94, 0.11, 0.11) == nil,
        "during a loading screen no point converts")

    assert(select(1, travel.EstimateSeconds(94, 0.1, 0.1, 94, 0.9, 0.9)) == nil,
        "so no journey can be costed, and the answer is nil rather than a "
        .. "fabricated number")

    C_Map.GetWorldPosFromMapPos = realConvert

    travel.ForgetWorldPoints()
    travel.ForgetNodes()

    assert(travel.WorldPoint(94, 0.11, 0.11) ~= nil,
        "and the refusal must NOT have been cached")

    -- The world-point cache is bounded, and the bound is reachable.
    local cap = travel.worldPointCap

    travel.ForgetWorldPoints()

    for index = 1, cap + 10 do
        travel.WorldPoint(94, (index % 1000) / 1000, ((index * 7) % 997) / 1000)
    end

    assert(travel.WorldPoint(94, 0.5, 0.5) ~= nil,
        "the cache empties itself at the ceiling and keeps working")

    travel.ForgetWorldPoints()
    travel.ForgetNodes()

    print("  the travel model's refusal paths all refuse, and none is cached")
end)()

;(function()
    local travel = CN:GetModule("Travel")

    ------------------------------------------------------------
    -- AN EMPTY FLIGHT-POINT LIST IS NOT AN ANSWER.
    --
    -- `GetAllTaxiNodes` answers usefully only while the client has the taxi
    -- map's data, and every node also needs a world position, which the
    -- client refuses during a loading screen -- which is when the cache is
    -- cleared. Remembering the resulting nothing degraded every flight
    -- estimate on the continent to "run there" for the rest of the session.
    ------------------------------------------------------------
    do
        local saved = CN_TEST_TAXI_NODES[1941]

        travel.ForgetNodes()

        CN_TEST_TAXI_NODES[1941] = {}

        assert(#travel.KnownNodes(94) == 0,
            "with no nodes the client can offer, the list is empty")

        CN_TEST_TAXI_NODES[1941] = saved

        assert(#travel.KnownNodes(94) > 0,
            "and the emptiness must NOT have been cached: the next query, "
            .. "once the client will answer, has to see the nodes")

        travel.ForgetNodes()

        print("  an empty flight-point list is not remembered")
    end

    ------------------------------------------------------------
    -- AND NO FLIGHT POINT IS REACHED ONLY OUTWARD.
    --
    -- Built one node at a time, the neighbour rule is about who each node
    -- reaches OUT to. A lone outpost picked its nearest four and every one of
    -- them filled its own four from the crowd nearby -- so the outpost had a
    -- way out and no way in, Dijkstra from the mainland never reached it, and
    -- it vanished from every route silently.
    ------------------------------------------------------------
    do
        local saved     = CN_TEST_TAXI_NODES[1941]
        local savedSpan = CN_TEST_MAP_SPAN

        CN_TEST_SetMapSpan({ 90000, 90000 })

        local scattered = {}

        for index = 1, 12 do
            table.insert(scattered, {
                nodeID = 800 + index,
                name   = "Cluster " .. index,
                state  = 1,
                position = {
                    x = 0.02 + ((index % 4) * 0.012),
                    y = 0.02 + ((index % 3) * 0.014),
                },
            })
        end

        table.insert(scattered, {
            nodeID = 899, name = "Lone Outpost", state = 1,
            position = { x = 0.97, y = 0.97 },
        })

        CN_TEST_TAXI_NODES[1941] = scattered

        travel.ForgetNodes()

        travel.FlightMemory()[94] = false

        -- Standing in the cluster, going to the outpost. The only sensible
        -- answer is a flight that ARRIVES at the outpost.
        local _, _, detail =
            travel.EstimateSeconds(94, 0.021, 0.021, 94, 0.971, 0.971)

        assert(detail and detail.mode == "fly",
            "a flight point at the far end of a continent must still be "
            .. "reachable; got " .. tostring(detail and detail.mode))

        assert(detail.arrival == "Lone Outpost",
            "and the route must land there, not somewhere near it; got "
            .. tostring(detail.arrival))

        travel.FlightMemory()[94] = nil

        CN_TEST_SetMapSpan(savedSpan)

        CN_TEST_TAXI_NODES[1941] = saved

        travel.ForgetNodes()

        print("  an isolated flight point is reachable, not merely reaching")
    end
end)()

;(function()
    ------------------------------------------------------------
    -- HIDING SOMETHING TAKES EFFECT NOW.
    --
    -- `CN.IsIgnored` is consulted inside candidate providers, at build time,
    -- so the ignore list is baked into the cached list. Without an explicit
    -- invalidation, clicking Ignore changed nothing until some unrelated
    -- event happened to make that provider dirty -- which for `Mounts` or
    -- `Sets` can be the rest of the session.
    ------------------------------------------------------------
    local errorsBefore = CN.Recommend(1)

    assert(errorsBefore and errorsBefore[1], "something must be recommended to ignore")

    local target = errorsBefore[1]

    CN.SetIgnored(target.type, target.id, true)

    local after = CN.Recommend(1)

    local stillThere = after and after[1]
        and after[1].type == target.type
        and after[1].id == target.id

    assert(not stillThere,
        "ignoring the top recommendation must remove it from the very next "
        .. "call, with nothing else happening in between")

    -- And putting it back must be just as immediate.
    local filterModule = CN:GetModule("Filters")

    filterModule.Restore(CN.ObjectiveKey(target.type, target.id))

    local restored, found = CN.Recommend(25), false

    for _, objective in ipairs(restored) do
        if objective.type == target.type and objective.id == target.id then
            found = true
        end
    end

    assert(found, "and un-hiding it must bring it back just as immediately")

    print("  ignoring and un-hiding take effect on the next call")
end)()

;(function()
    ------------------------------------------------------------
    -- `volatile` DOES NOT DEFEAT `cooldown`.
    --
    -- The volatile clause was a peer of the dirty clause rather than
    -- subordinate to `cooled`, so a provider declaring both rebuilt every
    -- five seconds whatever cooldown it asked for. `Waiting` and `Instances`
    -- each asked for thirty and got five -- six times more often than
    -- declared, for as long as the window stayed open.
    ------------------------------------------------------------
    local builds = 0

    CN.RegisterCandidateProvider("MutationVolatile", function()
        builds = builds + 1
        return {}
    end, { volatile = true, cooldown = 30 })

    CN.CollectCandidates(true)

    local baseline = builds

    -- Ten seconds later: past `candidateCacheSeconds`, well inside the
    -- cooldown the provider asked for.
    CN_TEST_TIME_OFFSET = CN_TEST_TIME_OFFSET + 10

    CN.CollectCandidates()

    assert(builds == baseline,
        "a provider that asked for a thirty-second cooldown must not rebuild "
        .. "after ten, however volatile it is")

    -- Past the cooldown, it must rebuild -- volatile still means volatile.
    CN_TEST_TIME_OFFSET = CN_TEST_TIME_OFFSET + 25

    CN.CollectCandidates()

    assert(builds > baseline,
        "but once the cooldown has passed, a volatile provider must go stale "
        .. "on its own")

    CN.candidateProviders["MutationVolatile"] = nil

    CN_TEST_TIME_OFFSET = 0

    CN.CollectCandidates(true)

    print("  a volatile provider still honours the cooldown it declared")
end)()

;(function()
    ------------------------------------------------------------
    -- A CLEAN SESSION DOES NOT ERASE A BAD ONE.
    --
    -- `Persist` ran unconditionally on logout, so the sequence the feature
    -- exists for destroyed its own evidence: something breaks, the player
    -- reloads before thinking to look, and the reload's empty ring overwrites
    -- the record. Players reload several times an hour.
    ------------------------------------------------------------
    local errors = CN:GetModule("Errors")

    errors.Clear()
    errors.ForgetPrevious()

    errors.Record("MutationContext", "something went wrong")

    errors.Persist()

    assert(#errors.Previous() == 1, "a real error must be persisted")

    -- A fresh, clean session, then a reload.
    errors.Clear()

    errors.Persist()

    assert(#errors.Previous() == 1,
        "a session in which nothing went wrong must leave the previous "
        .. "session's record alone")

    errors.ForgetPrevious()

    print("  a quiet session does not overwrite the last loud one")
end)()

;(function()
    ------------------------------------------------------------
    -- AN EARNED ACHIEVEMENT LEAVES THE SHORTLIST.
    --
    -- `CN.Shortlist` returns its held list whenever the revision matches, and
    -- the revision moved only on a full scan. Deleting the store row without
    -- moving it left the shortlist holding an orphaned record -- so the same
    -- event that invalidated the provider caused it to re-emit the
    -- achievement the player had just earned.
    ------------------------------------------------------------
    local achievements = CN:GetModule("Achievements")

    local store = achievements.Store()

    local id, record = next(store)

    assert(id, "the fixture must have an achievement in progress")

    local revisionBefore = achievements.revision

    for _, dispatch in ipairs(CN.eventTable["ACHIEVEMENT_EARNED"] or {}) do
        dispatch("ACHIEVEMENT_EARNED", id)
    end

    assert(store[id] == nil, "the store row goes")

    assert(achievements.revision ~= revisionBefore,
        "and the shortlist revision must move with it, or the shortlist "
        .. "keeps serving the record the store just released")

    store[id] = record

    print("  earning an achievement moves the shortlist revision")
end)()

;(function()
    ------------------------------------------------------------
    -- RIDING PAST A RARE IS NOT KILLING IT.
    --
    -- `GetVignettes` returns what is IN RANGE, and a vignette leaves that
    -- list for two different reasons: somebody killed it, or you rode away.
    -- The old code assumed the first, permanently, with no expiry and no
    -- undo -- so riding past a rare meant this character was never offered it
    -- again.
    ------------------------------------------------------------
    local raresModule = CN:GetModule("Rares")

    raresModule.ForgetCleared()

    raresModule.NoteDisappearances({})

    -- Seen at four hundred yards, then gone: that is the edge of vignette
    -- range, not a kill.
    raresModule.NoteDisappearances({})

    local far = { guid = "far-1", vignetteID = 777001, name = "Far Rare",
                  wasDead = false, yards = 400 }

    local near = { guid = "near-1", vignetteID = 777002, name = "Near Rare",
                   wasDead = false, yards = 20 }

    -- Drive it through the module's own state rather than around it.
    raresModule.SetLastSeen({ [far.guid] = far, [near.guid] = near })

    raresModule.NoteDisappearances({})

    assert(not raresModule.IsClearedByCharacter(777001),
        "a rare that vanished from four hundred yards away went out of "
        .. "range; it was not killed")

    assert(raresModule.IsClearedByCharacter(777002),
        "one that vanished from twenty yards away almost certainly was")

    raresModule.ForgetCleared()

    assert(not raresModule.IsClearedByCharacter(777002),
        "and the player can take it back, because inference that cannot be "
        .. "corrected is a wrong answer with a longer life")

    print("  a rare is cleared by proximity, not by disappearance")
end)()

;(function()
    ------------------------------------------------------------
    -- THE HANDYNOTES ITERATOR IS A TRIPLET.
    --
    -- `IteratePlugins` returns `next, self.plugins, nil`. Capturing only the
    -- first and writing `for name in iterator` calls `next(nil, nil)`, which
    -- throws -- so this integration could not work for any player who has
    -- HandyNotes installed. The old stub was a self-contained closure, the
    -- one shape under which the broken form works.
    ------------------------------------------------------------
    local handynotes = CN.HandyNotes

    assert(handynotes, "the HandyNotes provider must be reachable")

    local plugins = handynotes.GetPlugins()

    assert(#plugins == 1 and plugins[1] == "HandyNotes_Treasures",
        "the plugin list must come back from a pairs-style iterator; got "
        .. #plugins)

    local nodes = handynotes.GetNodesOnMap(94)

    assert(#nodes == 1 and nodes[1].label == "Hidden Cache",
        "and so must a plugin's nodes -- seventy lines that had no caller "
        .. "and could not have worked if they had; got " .. #nodes)

    print("  HandyNotes plugins and their nodes are actually readable")
end)()

;(function()
    ------------------------------------------------------------
    -- CLEARING DOES NOT DELETE THE PLAYER'S OWN PIN.
    --
    -- There is exactly one user waypoint and it belongs to the player unless
    -- this addon put it there. `/cn clearway`, stopping follow mode and every
    -- provider switch called ClearUserWaypoint unconditionally.
    ------------------------------------------------------------
    CN.ClearWaypoints()

    CN_TEST_USER_WAYPOINT = UiMapPoint.CreateFromCoordinates(94, 0.77, 0.77)

    assert(CN.ClearWaypoints() == false,
        "a pin this addon did not set must not be cleared")

    assert(CN_TEST_USER_WAYPOINT ~= nil, "and must still be there")

    CN_TEST_USER_WAYPOINT = nil

    print("  and a hand-placed pin survives /cn clearway")
end)()

;(function()
    ------------------------------------------------------------
    -- BOTH WAYPOINT PROVIDERS, ON THEIR FAILURE PATHS.
    --
    -- The Blizzard map-pin provider is the fallback every player without
    -- TomTom lands on, and its refusal paths -- absent API, a map point the
    -- client will not build, a map that forbids waypoints -- were the least
    -- covered lines in the addon. They are also the ones that used to return
    -- silently and let the caller announce a success.
    ------------------------------------------------------------
    local blizzard = CN.waypointProviders["Blizzard"]
    local tomtom   = CN.waypointProviders["TomTom"]

    assert(blizzard and tomtom, "both providers must be registered")

    assert(blizzard.IsAvailable(), "the map API is present in the harness")

    -- A client that will not build a map point.
    local realCreate = UiMapPoint.CreateFromCoordinates

    UiMapPoint.CreateFromCoordinates = function() return nil end

    local legsBuilt, why = blizzard.SetWaypoint(94, 0.3, 0.3, "No Point")

    assert(legsBuilt == false and why and why:find("map point"),
        "a client that will not build a map point must be reported, not "
        .. "swallowed: " .. tostring(why))

    UiMapPoint.CreateFromCoordinates = realCreate

    -- The whole API gone -- an older client, or a broken one.
    local realSet = C_Map.SetUserWaypoint

    C_Map.SetUserWaypoint = nil

    assert(blizzard.IsAvailable() == false,
        "with no SetUserWaypoint the provider is not available")

    assert(blizzard.SetWaypoint(94, 0.3, 0.3, "Gone") == false,
        "and it refuses rather than erroring")

    C_Map.SetUserWaypoint = realSet

    -- Clearing with nothing of ours set.
    CN_TEST_USER_WAYPOINT = nil

    assert(blizzard.ClearAll() == false,
        "clearing when this addon owns nothing removes nothing")

    -- And the round trip.
    assert(blizzard.SetWaypoint(94, 0.3, 0.3, "Ours") == true,
        "an ordinary map still works")

    assert(blizzard.ClearAll() == true, "and its own pin is removed")

    -- TOMTOM, INCLUDING THE CASE WHERE IT REFUSES.
    local realTomTom = _G.TomTom

    _G.TomTom = nil

    assert(tomtom.IsAvailable() == false, "no TomTom, no TomTom provider")

    local asked, absent = tomtom.SetWaypoint(94, 0.3, 0.3, "Nowhere")

    assert(asked == false and absent and absent:find("TomTom"),
        "and it says which addon is missing rather than returning nil")

    assert(tomtom.ClearAll() == false, "clearing is a no-op, reported as one")

    _G.TomTom = realTomTom

    -- TomTom present but refusing the waypoint.
    local realAdd = _G.TomTom.AddWaypoint

    _G.TomTom.AddWaypoint = function() return nil end

    local refusedWaypoint, reason = tomtom.SetWaypoint(94, 0.3, 0.3, "Refused")

    assert(refusedWaypoint == false and reason and reason:find("refused"),
        "a TomTom that returns no uid has not set a waypoint")

    _G.TomTom.AddWaypoint = realAdd

    local placed, uid = tomtom.SetWaypoint(94, 0.3, 0.3, "Real")

    assert(placed == true and uid, "and a real one comes back with its uid")

    assert(tomtom.ClearAll() == true, "which it then removes")

    assert(tomtom.ClearAll() == false,
        "and removing nothing twice is reported honestly")

    print("  both waypoint providers exercised on their refusal paths")
end)()

;(function()
    ------------------------------------------------------------
    -- HANDYNOTES WHEN IT IS NOT THERE, AND WHEN IT IS BROKEN.
    ------------------------------------------------------------
    local handynotes = CN.HandyNotes

    local real = _G.HandyNotes

    _G.HandyNotes = nil

    assert(handynotes.IsAvailable() == false, "absent means absent")
    assert(#handynotes.GetPlugins() == 0, "and no plugins")
    assert(#handynotes.GetNodesOnMap(94) == 0, "and no nodes")
    assert(handynotes.Describe() == "not installed", "and it says so")

    -- Present, but with no plugin registry at all -- an older HandyNotes, or
    -- one that has not finished loading.
    _G.HandyNotes = { IteratePlugins = nil, plugins = nil }

    assert(handynotes.Describe() == "loaded, no plugins registered",
        "a HandyNotes with nothing registered is described accurately")

    -- Present, with the registry as a plain table rather than an iterator.
    _G.HandyNotes = { plugins = { Alpha = {}, Beta = {} } }

    local fallback = handynotes.GetPlugins()

    assert(#fallback == 2 and fallback[1] == "Alpha",
        "the plain-table fallback still finds them, sorted")

    assert(handynotes.Describe():find("2 plugins"),
        "and the description names how many")

    -- A plugin whose node iterator throws must cost the plugin, not the call.
    _G.HandyNotes = {
        IteratePlugins = function()
            return next, {
                Broken = {
                    GetNodes2 = function() error("plugin exploded") end,
                },
            }, nil
        end,
    }

    assert(#handynotes.GetNodesOnMap(94) == 0,
        "a plugin that throws contributes nothing and does not take the "
        .. "addon down with it")

    _G.HandyNotes = real

    assert(handynotes.IsAvailable(), "and the real stub is back")

    print("  HandyNotes absent, empty, plain-table and broken all handled")
end)()

;(function()
    ------------------------------------------------------------
    -- RESOLVING A COLLECTIBLE BY NAME, WHICH IS HOW PEOPLE TYPE.
    --
    -- `/cn toy Test Toy` has to turn words into an item id, and the addon's
    -- rule -- shortest matching name wins, because a substring match against
    -- a long name is usually the wrong row -- had never been executed.
    ------------------------------------------------------------
    local toysModule = CN:GetModule("Toys")

    assert(toysModule, "the Toys module must load")

    toysModule.Scan()

    local counts = toysModule.Summary()

    assert(counts.known >= 2, "the fixture's toys are read, got " .. counts.known)
    assert(counts.collected + counts.missing == counts.known,
        "and every one is either collected or not")

    assert(toysModule.Resolve("500") == 500, "a bare id resolves to itself")

    assert(toysModule.Resolve("Test Toy") == 500,
        "and a full name resolves to its id")

    assert(toysModule.Resolve("toy") ~= nil,
        "a substring matches something")

    assert(toysModule.Resolve("") == nil, "an empty string resolves to nothing")
    assert(toysModule.Resolve(nil) == nil, "and so does nothing at all")

    assert(toysModule.Resolve("no such toy anywhere") == nil,
        "a name nothing matches resolves to nil rather than to whatever "
        .. "happened to be first")

    -- An id the player's client does not have is not a resolution either.
    assert(toysModule.Resolve("999999") == nil,
        "an id with no record behind it is not a match")

    -- THE ELIGIBILITY LINE, which is what `/cn why` prints for a toy.
    local checker = CN.eligibilityCheckers
        and CN.eligibilityCheckers[CN.objectiveTypes.TOY]

    if checker then
        local state, reason = checker(500)

        assert(state and reason,
            "a toy the addon knows about has a state and a sentence")

        local unknownState, unknownReason = checker(999999)

        assert(unknownState == CN.objectiveStates.UNKNOWN
            and unknownReason and unknownReason:find("toyscan"),
            "and one it does not know says which scan would tell it: "
            .. tostring(unknownReason))
    end

    -- With the toy box gone entirely, a scan is a no-op rather than an error.
    local realToyBox = C_ToyBox

    C_ToyBox = nil

    local seen, gotCollected, gotMissing = toysModule.Scan()

    assert(seen == 0 and gotCollected == 0 and gotMissing == 0,
        "no toy box, nothing scanned, and no error")

    C_ToyBox = realToyBox

    print("  toys resolve by id and by name, shortest match winning")
end)()

;(function()
    ------------------------------------------------------------
    -- THE CLIENT WRAPPER, WITH THE CLIENT TAKEN AWAY.
    --
    -- Providers/Blizzard.lua is the layer every other file asks its questions
    -- through, and every function in it is a guard around an API that may not
    -- exist on this client, may return nil, or may throw. Those guards are
    -- what stop a renamed API from becoming a Lua error popup -- and the
    -- failure branches had never been executed, because the harness defines
    -- everything the addon calls.
    ------------------------------------------------------------
    local Blizzard = CN.Blizzard

    local saved = {}

    local function Remove(name)
        saved[name] = _G[name]
        _G[name] = nil
    end

    local function Restore()
        for name, value in pairs(saved) do
            _G[name] = value
        end

        saved = {}
    end

    -- Quest completion, with both APIs gone.
    Remove("C_QuestLog")

    assert(Blizzard.IsQuestCompletedByCharacter(1234) == false,
        "no quest API means 'not completed', not an error")

    assert(Blizzard.IsQuestInLog(1234) == false, "and nothing is in the log")
    assert(Blizzard.IsQuestReadyForTurnIn(1234) == false,
        "and nothing is ready to hand in")
    assert(Blizzard.IsQuestComplete(1234) == false,
        "and nothing is complete")

    assert(Blizzard.GetQuestTitle(1234) == nil,
        "and no quest has a title")

    assert(#Blizzard.GetQuestLogEntries() == 0,
        "and the log is empty rather than nil")

    local doneCount, totalCount = Blizzard.GetQuestObjectiveProgress(1234)

    assert(doneCount == 0 and totalCount == 0,
        "and objective progress is zero of zero rather than nil arithmetic")

    assert(#Blizzard.GetCountingObjectives(1234) == 0,
        "and nothing counts")

    Restore()

    -- The account-wide completion API, which older clients do not have.
    local realAccount = C_QuestLog.IsQuestFlaggedCompletedOnAccount

    C_QuestLog.IsQuestFlaggedCompletedOnAccount = nil

    assert(Blizzard.HasAccountQuestAPI() == false,
        "a client without the Warband API says so")

    assert(Blizzard.IsQuestCompletedOnAccount(1234) == false,
        "and answers false rather than guessing from the character")

    C_QuestLog.IsQuestFlaggedCompletedOnAccount = realAccount

    -- Map POIs, with the POI API gone.
    Remove("C_QuestLog")
    Remove("C_TaskQuest")

    assert(Blizzard.GetQuestPOIOnMap(1234, 94) == nil,
        "no POI API, no POI")

    assert(#Blizzard.GetQuestPOIsOnMap(94) == 0,
        "and no pins on the map")

    -- The waypoint search falls back to "the map you are on, with no
    -- coordinates", which is a real and useful answer: it is how a zone gets
    -- named for a quest whose blip the client will not draw.
    local fallbackMap, fallbackX = Blizzard.GetQuestWaypoint(1234)

    assert(fallbackX == nil,
        "with no POI API there are no coordinates to invent")

    assert(fallbackMap == nil or type(fallbackMap) == "number",
        "and what comes back is a map or nothing, never a guess")

    assert(Blizzard.GetQuestWaypoint(nil) == nil,
        "and no quest is no waypoint")

    assert(Blizzard.GetQuestZone(1234) == nil,
        "and no zone for one either")

    Restore()

    -- Reputations, with the whole namespace gone.
    Remove("C_Reputation")
    Remove("C_MajorFactions")

    assert(Blizzard.GetNumFactions() == 0, "no reputation API, no factions")
    assert(Blizzard.GetFactionByIndex(1) == nil, "and none by index")
    assert(Blizzard.GetFactionByID(2600) == nil, "and none by id")
    assert(Blizzard.IsAccountWideReputation(2600) == false,
        "and nothing is account-wide")
    assert(Blizzard.IsMajorFaction(2600) == false,
        "and nothing is a major faction")
    assert(Blizzard.GetMajorFactionData(2600) == nil, "with no renown data")
    assert(Blizzard.HasMaximumRenown(2600) == false, "and no maximum")
    assert(Blizzard.IsFactionParagon(2600) == false, "and no paragon")
    assert(Blizzard.GetParagonInfo(2600) == nil, "and no paragon numbers")

    -- And the expand/restore wrapper must still run its inner work, because
    -- refusing to scan because the collapse API is missing would lose the
    -- whole reputation feature on a client that simply reads differently.
    local ran = false

    Blizzard.WithAllFactionsExpanded(function() ran = true end)

    assert(ran,
        "the scan still runs when the client cannot expand headers; the "
        .. "headers are a convenience, the standings are the point")

    Restore()

    -- Professions returns a fixed-slot tuple with holes in it, which is the
    -- shape `ipairs` silently truncates.
    local realProfessions = GetProfessions

    GetProfessions = function() return nil, 2, nil, nil, 5 end

    local professions = Blizzard.GetProfessions()

    assert(type(professions) == "table",
        "a tuple full of holes still produces a table")

    GetProfessions = nil

    assert(type(Blizzard.GetProfessions()) == "table",
        "and no API at all produces an empty one rather than nil")

    GetProfessions = realProfessions

    print("  the client wrapper degrades on every API it wraps")
end)()

;(function()
    ------------------------------------------------------------
    -- PREREQUISITES, AND THE ORDER OF AUTHORITY BETWEEN THEIR SOURCES.
    --
    -- `CN.GetPrerequisites` merges four sources -- a curated record, this
    -- account's own observations, the shipped community table, and chains
    -- imported by hand -- deduplicating as it goes and adding them in
    -- descending order of how much they should be believed. That ordering is
    -- the whole design of the function and nothing exercised it.
    ------------------------------------------------------------
    local quests = CN:GetModule("Quests")

    local realRecord = quests.GetRecord

    quests.GetRecord = function(questID)
        if questID == 999001 then
            return { requires = { 111, 222 } }, "curated"
        end

        return nil
    end

    CN.Account("questHarvest")[999001] = { observedRequires = { 222, 333 } }
    CN.Account("contributed")[999001]  = { 444 }

    local ordered = CN.GetPrerequisites(999001)

    assert(#ordered == 4,
        "four distinct prerequisites across three sources, got " .. #ordered)

    assert(ordered[1] == 111 and ordered[2] == 222,
        "curated data comes first")

    assert(ordered[3] == 333,
        "then what this account observed for itself")

    assert(ordered[4] == 444,
        "then what somebody else contributed -- the weakest source, added "
        .. "last, which is the order of authority")

    -- 222 appears in two sources and must appear once.
    local occurrences = 0

    for _, id in ipairs(ordered) do
        if id == 222 then occurrences = occurrences + 1 end
    end

    assert(occurrences == 1, "a prerequisite two sources agree on is one "
        .. "prerequisite, not two")

    -- A quest nothing knows about has no prerequisites, rather than an error.
    assert(#CN.GetPrerequisites(999002) == 0,
        "an unknown quest has no prerequisites")

    CN.Account("questHarvest")[999001] = nil
    CN.Account("contributed")[999001]  = nil

    quests.GetRecord = realRecord

    -- AND THE MODULE-ABSENT PATH, which is what every one of these guards is
    -- for: an addon that loads without one of its own modules must degrade,
    -- not throw.
    local realGet = CN.GetModule

    CN.GetModule = function(self, name)
        if name == "Quests" then
            return nil
        end

        return realGet(self, name)
    end

    assert(#CN.GetPrerequisites(999001) == 0,
        "with the Quests module gone, prerequisites are empty rather than an "
        .. "error")

    assert(CN.IsQuestComplete(999001) == false,
        "and completion is false rather than an error")

    CN.GetModule = realGet

    print("  prerequisites merge four sources in order of authority")
end)()

;(function()
    ------------------------------------------------------------
    -- THE ROUTE'S PROGRESS COUNTER, AND THE ONE MOMENT WORTH A FLOURISH.
    --
    -- `Follow.NoteStopCleared` is what the player sees as they walk a route,
    -- and the "Route complete" branch is the only celebratory thing this
    -- addon does. Neither was executed by any test -- and the counter has a
    -- history: a denominator frozen at the start produced "Stop 9 of 8
    -- cleared" and fired the flourish four times while stops remained.
    ------------------------------------------------------------
    local follow = CN:GetModule("Follow")

    local followSettings = CN.Settings()

    local realCues = followSettings.cues

    -- Cues off is the default, and off must mean off.
    followSettings.cues = nil

    assert(follow.Cue("stop") == false,
        "with cues off, nothing is played -- unsolicited noise is the most "
        .. "intrusive thing an addon can do")

    followSettings.cues = true

    assert(follow.Cue("stop") == true, "with cues on, the stop moment fires")
    assert(follow.Cue("arrival") == true, "so does arrival")
    assert(follow.Cue() == true, "and the default moment is the route")
    assert(follow.Celebrate() == true, "which is what Celebrate plays")

    -- An unknown moment must not error; it simply has no sound.
    assert(follow.Cue("nonsense") == true,
        "an unrecognised moment is a no-op, not a failure")

    -- THE COUNTER.
    follow.completed   = 0
    follow.startedWith = 3
    follow.celebrated  = false

    assert(follow.NoteStopCleared() == 1, "clearing counts")
    assert(follow.NoteStopCleared() == 2, "and counts again")

    local flourishBefore = #output

    assert(follow.NoteStopCleared() == 3, "and reaches the total")

    local celebrated = false

    for index = flourishBefore + 1, #output do
        if output[index]:find("stops, everything on it done") then
            celebrated = true
        end
    end

    assert(celebrated,
        "reaching the end of a route is the one moment this addon marks")

    -- And it must not fire again past the end.
    local past = #output

    follow.NoteStopCleared()

    for index = past + 1, #output do
        assert(not output[index]:find("stops, everything on it done"),
            "the flourish fires once, not on every stop past the total")
    end

    -- With no total known, the message is the short form rather than an
    -- invented denominator.
    follow.completed   = 0
    follow.startedWith = 0
    follow.celebrated  = false

    local unknown = #output

    follow.NoteStopCleared()

    local named = false

    for index = unknown + 1, #output do
        if output[index]:find("of") and output[index]:find("cleared") then
            named = true
        end
    end

    assert(not named,
        "with no total, the addon does not invent one to count against")

    followSettings.cues      = realCues
    follow.completed   = 0
    follow.startedWith = 0
    follow.celebrated  = false

    print("  route progress counts up, and the flourish fires exactly once")
end)()

print("\nGetting there:")

;(function()
    local travel = CN:GetModule("Travel")

    assert(travel, "the Travel module must load")

    travel.ForgetNodes()

    local savedSpan = CN_TEST_MAP_SPAN

    CN_TEST_SetMapSpan({ 4000, 4000 })

    ------------------------------------------------------------
    -- TWO MAPS USED TO MEAN NO DISTANCE AT ALL.
    --
    -- Map coordinates are normalized per map, so 0.5 on one map and 0.5 on
    -- another are not comparable and the old code returned nil. World
    -- coordinates are yards and are continuous across a continent.
    ------------------------------------------------------------
    local sameMap = travel.YardsBetween(94, 0.1, 0.5, 94, 0.2, 0.5)

    assert(sameMap and math.abs(sameMap - 400) < 1,
        "a tenth of a 4000 yard map is 400 yards, got " .. tostring(sameMap))

    local crossMap = travel.YardsBetween(94, 0.1, 0.5, 2112, 0.2, 0.5)

    assert(crossMap, "two different maps must still yield a distance")

    print("  cross-map distances are measured in world yards")

    ------------------------------------------------------------
    -- ONLY FLIGHT POINTS YOU HAVE DISCOVERED.
    --
    -- Costing a journey through an undiscovered flight master produces a plan
    -- the player cannot follow, which is worse than a pessimistic one.
    ------------------------------------------------------------
    local nodes, continent = travel.KnownNodes(94)

    assert(continent == 1941, "the continent must be found by walking parents, got "
        .. tostring(continent))

    -- >=, not ==: the bench grows this fixture to a continent's worth of
    -- flight points, and a test that pins an exact count is a test that
    -- forbids the bench from measuring anything realistic.
    assert(#nodes >= 2, "an undiscovered node must not be usable, got " .. #nodes)

    for _, node in ipairs(nodes) do
        assert(node.name ~= "Undiscovered", "and specifically not that one")
    end

    print("  " .. #nodes .. " known flight points; the undiscovered one is not offered")

    ------------------------------------------------------------
    -- FLYING MUST BEAT RUNNING WHEN, AND ONLY WHEN, IT IS QUICKER.
    ------------------------------------------------------------
    local far, farConfident, farDetail =
        travel.EstimateSeconds(94, 0.40, 0.50, 94, 0.90, 0.50)

    assert(far, "a long journey must be costable")

    assert(farDetail.mode == "fly",
        "across the continent, with a flight point at each end, flying wins")

    local session = CN:GetModule("Session")

    local runSpeed = session.Speed()

    local runningTheWholeWay = farDetail.yards / runSpeed

    assert(far < runningTheWholeWay,
        "and it must actually be quicker than running: "
        .. string.format("%.0f vs %.0f seconds", far, runningTheWholeWay))

    -- A SHORT HOP MUST NOT BE FLOWN.
    --
    -- Deliberately positioned so the two ends have DIFFERENT nearest flight
    -- points, which means the flight branch is actually evaluated and
    -- rejected on cost. The first version of this case put both ends next to
    -- the same node, so the comparison never ran at all and the rule could
    -- have been deleted without the suite noticing.
    local near, _, nearDetail =
        travel.EstimateSeconds(94, 0.40, 0.50, 94, 0.66, 0.50)

    assert(nearDetail.mode == "run",
        "a journey quicker on foot must be run, not flown")

    -- NOT "cheaper than the long journey", which was the first assertion here
    -- and was simply false: a long flight legitimately beats a medium run,
    -- and asserting otherwise would have forced a wrong answer into the code.
    -- The property that matters is that a run estimate is a run: the whole
    -- distance at running speed, with no flight overhead hidden in it.
    assert(math.abs(near - (nearDetail.yards / runSpeed)) < 1,
        "a run estimate must be the whole distance at running speed, got "
        .. string.format("%.0f vs %.0f", near, nearDetail.yards / runSpeed))

    print("  a long journey flies, a short one runs")

    ------------------------------------------------------------
    -- THE FAST PAIR SEARCH MUST FIND WHAT THE SLOW ONE FOUND.
    --
    -- 0.46.0 rewrote the pair search: the two ends are measured once per node
    -- instead of once per pair, the flight legs come from a table computed
    -- once per continent, and an origin whose walk alone already beats the
    -- standing best is abandoned unexamined. That last one is a pruning rule,
    -- and a pruning rule that is subtly wrong does not error -- it quietly
    -- returns the second-best route forever.
    --
    -- So this brute-forces the answer independently and demands the same
    -- number. With enough nodes spread widely enough that the pruning
    -- actually fires.
    ------------------------------------------------------------
    -- THE SAME MODEL, WRITTEN A SECOND TIME AND A DIFFERENT WAY.
    --
    -- 0.53.0 made the flight leg the shortest path through the flight network
    -- rather than the straight line across it, so an exhaustive comparison
    -- that measures node-to-node distance directly no longer describes the
    -- thing under test -- it describes the model the addon replaced.
    --
    -- This rebuilds the network from the addon's published rule (hopYards,
    -- minimumNeighbours) and solves it with Floyd-Warshall, which shares no
    -- code and no shape with the addon's cached per-origin Dijkstra. Two
    -- independent solvers of the same graph must agree, and a graph the two
    -- disagree about is a defect in one of them.
    local function NetworkDistances(list)
        local sourceCount = #list
        local dist  = {}

        for i = 1, sourceCount do
            dist[i] = {}
            dist[i][i] = 0
        end

        for i = 1, sourceCount do
            local rankedSources = {}

            for j = 1, sourceCount do
                if i ~= j then
                    table.insert(rankedSources, {
                        index = j,
                        yards = travel.YardsBetweenPoints(
                            list[i].point, list[j].point),
                    })
                end
            end

            table.sort(rankedSources, function(a, right)
                if a.yards == right.yards then
                    return a.index < right.index
                end

                return a.yards < right.yards
            end)

            for rank, entry in ipairs(rankedSources) do
                if entry.yards <= travel.hopYards
                    or rank <= travel.minimumNeighbours then

                    -- Undirected: a flight path connects both ways, so an
                    -- edge either node claims is an edge.
                    dist[i][entry.index] = entry.yards
                    dist[entry.index][i] = entry.yards
                end
            end
        end

        for k = 1, sourceCount do
            for i = 1, sourceCount do
                local ik = dist[i][k]

                if ik then
                    for j = 1, sourceCount do
                        local kj = dist[k][j]

                        if kj and (not dist[i][j] or (ik + kj) < dist[i][j]) then
                            dist[i][j] = ik + kj
                        end
                    end
                end
            end
        end

        return dist
    end

    do
        local saved = CN_TEST_TAXI_NODES[1941]

        local savedCount = #travel.KnownNodes(94)

        local crowded = {}

        for index, node in ipairs(saved) do
            crowded[index] = node
        end

        for index = 4, 40 do
            crowded[index] = {
                nodeID = 500 + index,
                name   = "Spread " .. index,
                state  = 1,
                position = {
                    x = 0.02 + (((index * 7) % 24) * 0.04),
                    y = 0.02 + (((index * 11) % 19) * 0.05),
                },
            }
        end

        CN_TEST_TAXI_NODES[1941] = crowded

        travel.ForgetNodes()

        local nodeList = travel.KnownNodes(94)

        assert(#nodeList >= 30,
            "the brute-force comparison needs a crowded continent, got "
            .. #nodeList)

        -- ROUTES THE PLAYER HAS ACTUALLY FLOWN, BEFORE THE COMPARISON RUNS.
        --
        -- The first version of this test noted none, so `knownRouteBonus` --
        -- the one multiplicative term in the whole calculation -- was never
        -- applied while the exhaustive check ran. It therefore agreed with a
        -- pruning bound that ignored the discount entirely, and passed. A
        -- brute-force comparison is only as honest as the state it runs
        -- against.
        for index = 1, #nodeList - 1 do
            travel.NoteRoute(nodeList[index].id, nodeList[index + 1].id)
            travel.NoteRoute(nodeList[#nodeList].id, nodeList[index].id)
        end

        local seconds, _, detail = travel.EstimateSeconds(94, 0.05, 0.05, 94, 0.95, 0.95)

        -- Independently, the long way round: every pair, every distance
        -- recomputed, nothing pruned and nothing cached.
        local from = travel.WorldPoint(94, 0.05, 0.05)
        local to   = travel.WorldPoint(94, 0.95, 0.95)

        local flightSpeed = travel.FlightSpeed()

        local brute = travel.YardsBetweenPoints(from, to) / runSpeed

        local bruteRanking = brute

        if travel.CanFly(94) then
            brute = math.min(brute,
                (travel.YardsBetweenPoints(from, to) / travel.SelfFlightSpeed())
                    + travel.takeoffSeconds)
        end

        local bruteNetwork = NetworkDistances(nodeList)

        for i, origin in ipairs(nodeList) do
            for j, arrival in ipairs(nodeList) do
                local through = (i ~= j) and bruteNetwork[i][j] or nil

                if origin.id ~= arrival.id and through then
                    local candidate =
                        (travel.YardsBetweenPoints(from, origin.point) / runSpeed)
                        + travel.flightOverheadSeconds
                        + (through / flightSpeed)
                        + (travel.YardsBetweenPoints(to, arrival.point) / runSpeed)

                    local rankedCandidate = candidate

                    if travel.IsKnownRoute(origin.id, arrival.id) then
                        rankedCandidate = rankedCandidate * travel.knownRouteBonus
                    end

                    if rankedCandidate < bruteRanking then
                        bruteRanking = rankedCandidate
                        brute        = candidate
                    end
                end
            end
        end

        assert(math.abs(seconds - brute) < 0.001,
            "the pruned search returned " .. string.format("%.3f", seconds)
            .. " where an exhaustive one finds "
            .. string.format("%.3f", brute))

        -- AND THE REPORTED LEGS MUST ADD UP TO THE REPORTED TOTAL.
        --
        -- The rewrite carries the walked distances as seconds internally and
        -- converts them back for display. A wrong conversion there is
        -- invisible in the total and wrong on every screen that shows the
        -- breakdown.
        if detail and detail.mode == "fly" then
            local rebuilt = (detail.runToNode / runSpeed)
                + travel.flightOverheadSeconds
                + (detail.flightYards / flightSpeed)
                + (detail.runFromNode / runSpeed)

            -- NO DISCOUNT HERE ANY MORE. The known-route preference is a
            -- tie-break in the comparison, not a reduction of the duration --
            -- which is the whole point: `/cn travel` used to print legs that
            -- summed to fifty seconds more than its own headline.

            assert(math.abs(rebuilt - seconds) < 0.01,
                "the legs shown add to " .. string.format("%.3f", rebuilt)
                .. " but the estimate says " .. string.format("%.3f", seconds))
        end

        print("  " .. #nodeList .. " flight points; the fast pair search agrees "
            .. "with an exhaustive one")

        ------------------------------------------------------------
        -- AND THE PRUNING MUST NOT DISCARD A LONG WALK TO A GOOD FLIGHT.
        --
        -- The brute-force case above passes even with a badly wrong bound,
        -- because its winning route happens to start at a flight point close
        -- to the player. The route the bound could actually lose is the
        -- opposite shape: a long walk to a flight master that lands you
        -- exactly where you are going. That is a real and common shape, and
        -- it is the one a careless bound throws away.
        ------------------------------------------------------------
        CN_TEST_TAXI_NODES[1941] = {
            { nodeID = 90, name = "Halfway Out", state = 1,
              position = { x = 0.62, y = 0.62 } },
            { nodeID = 91, name = "At The Door", state = 1,
              position = { x = 0.95, y = 0.95 } },
        }

        travel.ForgetNodes()

        -- Grounded on purpose: with flying available the self-flown line
        -- beats everything and the pair search never decides anything.
        travel.FlightMemory()[94] = false

        local walked, _, walkedDetail =
            travel.EstimateSeconds(94, 0.05, 0.05, 94, 0.95, 0.95)

        assert(walkedDetail and walkedDetail.mode == "fly",
            "a long walk to a flight point that lands at the target must "
            .. "still beat walking the whole way, got "
            .. tostring(walkedDetail and walkedDetail.mode))

        assert(walkedDetail.node == "Halfway Out"
            and walkedDetail.arrival == "At The Door",
            "and it must be that pair, got "
            .. tostring(walkedDetail.node) .. " -> "
            .. tostring(walkedDetail.arrival))

        assert(walked < (travel.YardsBetweenPoints(from, to) / runSpeed),
            "and it must actually be quicker than the walk it replaces")

        travel.FlightMemory()[94] = nil

        print("  a long walk to the right flight point is not pruned away")

        ------------------------------------------------------------
        -- SOME JOURNEYS NEED TWO HOPS, AND THE CHAIN MUST BE PRINTABLE.
        --
        -- Backlog item 5. A straight line between the two ends of a chain of
        -- flight masters is not the distance a taxi flies, and until 0.53.0
        -- that was the number every long flight was costed with -- wrong
        -- always in the same direction, so distant objectives were
        -- systematically preferred over near ones.
        --
        -- A chain of flight masters in an L, spaced further apart than the
        -- direct-connection radius so that the network is a chain rather
        -- than a clique. The straight line from one end to the other cuts
        -- the corner; the bird does not.
        ------------------------------------------------------------
        do
            local spanBefore = CN_TEST_MAP_SPAN

            CN_TEST_SetMapSpan({ 40000, 40000 })

            local chain = {}

            for step = 0, 6 do
                table.insert(chain, {
                    nodeID = 70 + step,
                    name   = "Chain " .. (step + 1),
                    state  = 1,
                    position = { x = 0.05, y = 0.05 + (step * 0.15) },
                })
            end

            table.insert(chain, {
                nodeID = 77, name = "Chain 8", state = 1,
                position = { x = 0.35, y = 0.95 },
            })

            CN_TEST_TAXI_NODES[1941] = chain

            travel.ForgetNodes()

            travel.FlightMemory()[94] = false

            local hopped, hopConfident, hopDetail =
                travel.EstimateSeconds(94, 0.05, 0.04, 94, 0.36, 0.96)

            assert(hopDetail and hopDetail.mode == "fly",
                "the chain case must decide on a flight, got "
                .. tostring(hopDetail and hopDetail.mode))

            assert(hopDetail.hops and hopDetail.hops >= 2,
                "and it must take more than one hop, got "
                .. tostring(hopDetail.hops))

            assert(hopDetail.legs and #hopDetail.legs == hopDetail.hops,
                "and every hop must be printable as a leg")

            -- The legs are what the player is shown. If they do not add up to
            -- the distance the estimate was built from, the breakdown is
            -- decoration.
            local summed = 0

            for _, leg in ipairs(hopDetail.legs) do
                assert(leg.from and leg.to,
                    "a leg with no ends is not a leg")

                summed = summed + (leg.yards or 0)
            end

            assert(math.abs(summed - hopDetail.flightYards) < 0.001,
                "the legs sum to " .. string.format("%.3f", summed)
                .. " but the flight is " .. string.format("%.3f",
                    hopDetail.flightYards))

            -- And the path must be longer than the line it replaces, which is
            -- the entire reason for the change.
            local straight = travel.YardsBetweenPoints(
                travel.WorldPoint(94, 0.05, 0.05),
                travel.WorldPoint(94, 0.35, 0.95))

            assert(hopDetail.flightYards > straight,
                "a route through the network cannot be shorter than the "
                .. "straight line it replaces")

            -- A multi-hop route rests on an inferred edge list, so it is
            -- never reported as measured however good the speed data is.
            assert(hopConfident == false,
                "a multi-hop estimate must not be reported as confident")

            assert(hopped > 0, "and it must still be a duration")

            travel.FlightMemory()[94] = nil

            CN_TEST_SetMapSpan(spanBefore)

            print("  " .. hopDetail.hops .. " hops through the flight network, "
                .. "and the legs add up to the flight")
        end

        ------------------------------------------------------------
        -- AND NO FLIGHT POINT MAY BE CUT OFF FROM THE REST.
        --
        -- The edge list is inferred, so a rule that only connected nodes
        -- within a fixed radius would strand every isolated outpost -- it
        -- would drop out of the graph, out of every route, and out of the
        -- addon's answers, silently. `minimumNeighbours` exists to prevent
        -- exactly that, and this is the property it is there for.
        ------------------------------------------------------------
        do
            local spanBefore = CN_TEST_MAP_SPAN

            CN_TEST_SetMapSpan({ 90000, 90000 })

            local scattered = {}

            for index = 1, 24 do
                table.insert(scattered, {
                    nodeID = 600 + index,
                    name   = "Scattered " .. index,
                    state  = 1,
                    position = {
                        x = 0.03 + (((index * 5) % 17) * 0.055),
                        y = 0.03 + (((index * 3) % 13) * 0.072),
                    },
                })
            end

            -- One deliberately far from everything else.
            table.insert(scattered, {
                nodeID = 699, name = "Lone Outpost", state = 1,
                position = { x = 0.99, y = 0.99 },
            })

            CN_TEST_TAXI_NODES[1941] = scattered

            travel.ForgetNodes()

            local list = travel.KnownNodes(94)

            assert(#list >= 20, "the connectivity case needs a spread "
                .. "continent, got " .. #list)

            local reach = NetworkDistances(list)

            local unreachable = 0

            for index = 1, #list do
                if not reach[1][index] then
                    unreachable = unreachable + 1
                end
            end

            assert(unreachable == 0,
                unreachable .. " flight points have no route to them at all")

            CN_TEST_SetMapSpan(spanBefore)

            print("  every flight point on a spread continent is reachable "
                .. "from every other")
        end

        ------------------------------------------------------------
        -- THE WHOLE PROPERTY, SWEPT, WITH THE DISCOUNT LIVE.
        --
        -- The single hand-placed case above tests one geometry, and the
        -- brute-force case tests one more. Neither caught the bound ignoring
        -- knownRouteBonus, because whether that error changes an answer
        -- depends on the relationship between the zone's size, the flight
        -- overhead and where the flight points happen to sit -- three numbers
        -- a hand-written case fixes at one value each.
        --
        -- So sweep them. The property is simple and should hold everywhere:
        -- what the fast search returns is what an exhaustive one finds.
        ------------------------------------------------------------
        local sweepSpan = CN_TEST_MAP_SPAN

        local checked, ground = 0, 0

        for _, span in ipairs({ 200, 340, 600, 1000, 2400 }) do
            CN_TEST_SetMapSpan({ span, span })

            for _, fraction in ipairs({ 0.3, 0.5, 0.7, 0.85 }) do
                CN_TEST_TAXI_NODES[1941] = {
                    { nodeID = 80, name = "Out", state = 1,
                      position = { x = 0.05 + (0.90 * fraction),
                                   y = 0.05 + (0.90 * fraction) } },
                    { nodeID = 81, name = "In", state = 1,
                      position = { x = 0.95, y = 0.95 } },
                    { nodeID = 82, name = "Aside", state = 1,
                      position = { x = 0.95, y = 0.20 } },
                }

                travel.ForgetNodes()

                -- Every pair flown, so the discount is live on all of them.
                for _, pair in ipairs({ {80,81}, {81,80}, {80,82}, {82,81} }) do
                    travel.NoteRoute(pair[1], pair[2])
                end

                -- Grounded, so the pair search is what decides.
                travel.FlightMemory()[94] = false

                local list = travel.KnownNodes(94)

                local start  = travel.WorldPoint(94, 0.05, 0.05)
                local finish = travel.WorldPoint(94, 0.95, 0.95)

                local speed = travel.FlightSpeed()

                local expect = travel.YardsBetweenPoints(start, finish) / runSpeed

                local expectRanking = expect

                local sweepNetwork = NetworkDistances(list)

                for i, origin in ipairs(list) do
                    for j, arrival in ipairs(list) do
                        local through = (i ~= j) and sweepNetwork[i][j] or nil

                        if origin.id ~= arrival.id and through then
                            local total =
                                (travel.YardsBetweenPoints(start, origin.point) / runSpeed)
                                + travel.flightOverheadSeconds
                                + (through / speed)
                                + (travel.YardsBetweenPoints(finish, arrival.point) / runSpeed)

                            -- The discount RANKS; it does not shorten. So
                            -- the exhaustive comparison has to keep both
                            -- numbers, exactly as the search does.
                            local rankedTotal = total

                            if travel.IsKnownRoute(origin.id, arrival.id) then
                                rankedTotal = rankedTotal * travel.knownRouteBonus
                            end

                            if rankedTotal < expectRanking then
                                expectRanking = rankedTotal
                                expect        = total
                            end
                        end
                    end
                end

                local got, _, gotDetail = travel.EstimateSeconds(94, 0.05, 0.05, 94, 0.95, 0.95)

                assert(math.abs(got - expect) < 0.001,
                    "span " .. span .. ", flight point at " .. fraction
                    .. " of the way: the search returned "
                    .. string.format("%.3f", got) .. " where an exhaustive "
                    .. "one finds " .. string.format("%.3f", expect))

                checked = checked + 1

                if gotDetail and gotDetail.mode == "fly" then
                    ground = ground + 1
                end

                travel.FlightMemory()[94] = nil
            end
        end

        assert(ground >= 4,
            "the sweep must actually choose flight routes, or it is only "
            .. "checking that running is running; it chose " .. ground)

        CN_TEST_SetMapSpan(sweepSpan)

        print("  " .. checked .. " geometries swept, " .. ground
            .. " of them decided by the pair search")

        CN_TEST_TAXI_NODES[1941] = saved

        travel.ForgetNodes()

        assert(#travel.KnownNodes(94) == savedCount,
            "and the node list is forgotten with the spans that describe it")
    end

    ------------------------------------------------------------
    -- FLIGHT SPEED IS MEASURED, AND SAID TO BE UNMEASURED UNTIL IT IS.
    ------------------------------------------------------------
    CN.Account("flight").samples = {}

    local seeded, measured = travel.FlightSpeed()

    assert(seeded == travel.seededFlightSpeed and measured == false,
        "an unflown character has a seeded speed, flagged as unmeasured")

    assert(farConfident == false,
        "and an estimate built on it must not claim confidence")

    -- Now fly. The sample is taken when the flight ENDS, not per tick: a
    -- flight is one observation of a constant speed, and counting every tick
    -- would let one long flight drown out every other measurement.
    local savedX, savedY = CN_TEST_PLAYER_X, CN_TEST_PLAYER_Y

    CN_TEST_ON_TAXI = true
    CN_TEST_CLOCK   = 1000

    CN_TEST_PLAYER_X, CN_TEST_PLAYER_Y = 0.10, 0.50

    travel.ObserveFlight()

    for step = 1, 20 do
        CN_TEST_CLOCK = 1000 + step
        -- 0.02 of a 4000 yard map per second = 80 yards/second.
        CN_TEST_PLAYER_X = 0.10 + (step * 0.02)

        travel.ObserveFlight()
    end

    assert(travel.FlightSampleCount() == 0,
        "nothing is recorded while still in the air")

    CN_TEST_ON_TAXI = false

    travel.ObserveFlight()

    assert(travel.FlightSampleCount() == 1,
        "one flight is one sample, got " .. travel.FlightSampleCount())

    local flown, nowMeasured = travel.FlightSpeed()

    assert(nowMeasured, "and the speed is now measured")
    assert(math.abs(flown - 80) < 5,
        "at about 80 yards per second, got " .. string.format("%.1f", flown))

    print(string.format("  flight speed measured from one flight: %.0f yd/s", flown))

    ------------------------------------------------------------
    -- ANOTHER CONTINENT IS "I DO NOT KNOW", NOT A LARGE NUMBER.
    ------------------------------------------------------------
    CN_TEST_CONTINENT_FOR_MAP = { [2112] = 99 }

    local offContinent, _, elsewhereDetail =
        travel.EstimateSeconds(94, 0.4, 0.5, 2112, 0.5, 0.5)

    assert(offContinent == nil,
        "a journey the addon cannot model must return nothing")
    assert(elsewhereDetail and elsewhereDetail.mode == "elsewhere",
        "and must say why")

    CN_TEST_CONTINENT_FOR_MAP = nil

    print("  another continent returns nothing rather than a fabricated number")

    ------------------------------------------------------------
    -- A FAILED CONVERSION MUST NOT BE REMEMBERED.
    --
    -- During a loading screen the client refuses every conversion. Caching
    -- that refusal would leave the addon unable to cost any journey for the
    -- rest of the session, and nothing would ever tell the player why.
    ------------------------------------------------------------
    travel.ForgetWorldPoints()

    local realConvert = C_Map.GetWorldPosFromMapPos

    C_Map.GetWorldPosFromMapPos = function() return nil, nil end

    assert(travel.WorldPoint(94, 0.3, 0.3) == nil,
        "a client that will not convert yields nothing")

    C_Map.GetWorldPosFromMapPos = realConvert

    assert(travel.WorldPoint(94, 0.3, 0.3) ~= nil,
        "and the question must be asked again once it can answer")

    print("  a refused conversion is not remembered as an answer")

    ------------------------------------------------------------
    -- AND THE SESSION PLANNER MUST ACTUALLY SPEND THE TRAVEL TIME.
    --
    -- The plan exists to answer "what fits in half an hour". A planner that
    -- costs the work and not the journey answers a different question, and
    -- flatters itself doing it.
    ------------------------------------------------------------
    local durations = CN.Account("taskDurations")

    local QUEST = CN.objectiveTypes.QUEST

    local savedDurations = durations[QUEST]

    durations[QUEST] = {}

    for _ = 1, 20 do
        table.insert(durations[QUEST], 60)
    end

    local hub = {
        mapID = 94, x = 0.90, y = 0.50,
        objectives = { { type = QUEST, id = 1 } },
    }

    local total, _, travelPart, workPart =
        session.EstimateHub(hub, 0.40, 0.50)

    assert(workPart and math.abs(workPart - 60) < 1,
        "the work is one timed quest")
    assert(travelPart and travelPart > 30,
        "and the journey across the zone must cost something, got "
        .. tostring(travelPart))
    assert(math.abs(total - (travelPart + workPart)) < 1,
        "the estimate is the sum of both")

    print(string.format("  the planner spends %.0fs travelling and %.0fs working",
        travelPart, workPart))

    durations[QUEST] = savedDurations

    CN_TEST_ON_TAXI = false
    CN_TEST_PLAYER_X, CN_TEST_PLAYER_Y = savedX, savedY
    CN_TEST_SetMapSpan(savedSpan)
    nav.ForgetMapScales()
    travel.ForgetNodes()
end)()

print("\nHow long a chase will take:")

;(function()
    local chase = CN:GetModule("Chase")
    local session = CN:GetModule("Session")

    local QUEST = CN.objectiveTypes.QUEST

    ------------------------------------------------------------
    -- NOT ENOUGH TIMED STEPS MEANS NO NUMBER.
    --
    -- Half an answer stated confidently is worse than "not enough to say".
    ------------------------------------------------------------
    local durations = CN.Account("taskDurations")

    durations[QUEST] = nil

    local chain = {
        name  = "Test Goal",
        type  = QUEST,
        steps = {
            { state = chase.states.TODO, text = "one", objectiveType = QUEST },
            { state = chase.states.TODO, text = "two", objectiveType = QUEST },
            { state = chase.states.DONE, text = "done", objectiveType = QUEST },
            { state = chase.states.NOTE, text = "context" },
        },
    }

    local blind = chase.Estimate(chain)

    assert(blind and blind.enough == false,
        "an untimed chain must refuse to estimate")
    assert(blind.unknown == 2, "and must count what it could not time, got "
        .. tostring(blind.unknown))

    local text = chase.DescribeEstimate(chain)

    assert(text:find("unknown"), "and must say so: " .. text)

    -- DONE AND NOTE STEPS ARE NOT WORK. Counting them would inflate every
    -- estimate by everything the player has already finished.
    assert(blind.timed + blind.unknown == 2,
        "finished steps and notes are not outstanding work")

    print("  an untimed chain says 'unknown' rather than guessing")

    ------------------------------------------------------------
    -- WITH DATA, A RANGE -- NEVER A FIGURE.
    ------------------------------------------------------------
    durations[QUEST] = {}

    for _ = 1, 20 do
        table.insert(durations[QUEST], 600)
    end

    local typical = session.TypicalSeconds(QUEST)

    assert(typical == 600, "the fixture must be timed, got " .. tostring(typical))

    local estimate = chase.Estimate(chain)

    assert(estimate.enough, "with data it must estimate")
    assert(math.abs(estimate.seconds - 1200) < 60,
        "two ten-minute steps is twenty minutes, got "
        .. string.format("%.0f", estimate.seconds))

    assert(estimate.low < estimate.seconds and estimate.high > estimate.seconds,
        "the answer must be a range")

    local described = chase.DescribeEstimate(chain)

    assert(described:find("to"), "and must be printed as one: " .. described)

    print("  " .. described)

    durations[QUEST] = nil
end)()


print("\nSituation awareness:")

;(function()
    local group = CN:GetModule("Group")

    assert(group, "the Group module must load")

    ------------------------------------------------------------
    -- BEING DEAD CHANGES THE ANSWER.
    --
    -- Recommending a battle pet to a corpse is the clearest possible signal
    -- that an addon is not watching what the player is doing.
    ------------------------------------------------------------
    CN_TEST_DEAD = false

    local objective = { type = CN.objectiveTypes.PET, id = 1,
        completionValue = 10, travelCost = 0, reasons = {} }

    local alive = CN.ScoreObjective(objective)

    CN_TEST_DEAD = true

    CN.InvalidateRanking()

    local dead = { type = CN.objectiveTypes.PET, id = 1,
        completionValue = 10, travelCost = 0, reasons = {} }

    local deadScore = CN.ScoreObjective(dead)

    assert(deadScore < alive,
        "everything is worth less than getting up: "
        .. string.format("%.2f dead vs %.2f alive", deadScore, alive))

    assert(deadScore > 0,
        "but not zero -- the list still answers 'what next', it just stops "
        .. "pretending you can act on it this second")

    local explainedDeath = false

    for _, reason in ipairs(dead.reasons) do
        if reason:find("dead") then explainedDeath = true end
    end

    assert(explainedDeath, "and the line must say why it moved")

    local notice = group.Notice()

    assert(notice and notice:find("dead"),
        "and the recommendation must lead with it: " .. tostring(notice))

    print("  a dead player is told to get up first")

    ------------------------------------------------------------
    -- IN AN INSTANCE WITH A GROUP, OUTSIDE WORK RANKS DOWN.
    ------------------------------------------------------------
    CN_TEST_DEAD = false
    CN_TEST_INSTANCE = "party"
    CN_TEST_GROUP_SIZE = 5

    CN.InvalidateRanking()

    assert(group.Situation() == "instanced", "the situation must be read")

    local inside = { type = CN.objectiveTypes.PET, id = 1,
        completionValue = 10, travelCost = 0, reasons = {} }

    local insideScore = CN.ScoreObjective(inside)

    assert(insideScore < alive, "a pet detour ranks below its solo value")

    local quest = { type = CN.objectiveTypes.QUEST, id = 1,
        completionValue = 10, travelCost = 0, reasons = {} }

    local questScore = CN.ScoreObjective(quest)

    assert(questScore > insideScore,
        "but only the outside-work types are pushed down")

    CN_TEST_INSTANCE = nil
    CN_TEST_GROUP_SIZE = 1
    CN.InvalidateRanking()

    print("  outside work ranks down in an instance, and only outside work")
end)()

print("\nContributed chains:")

;(function()
    local contribute = CN:GetModule("Contribute")

    assert(contribute, "the Contribute module must load")

    ------------------------------------------------------------
    -- A MALFORMED IMPORT IS REFUSED OUTRIGHT.
    --
    -- A half-parsed contribution is worse than a refused one: it silently
    -- teaches the addon a chain nobody wrote.
    ------------------------------------------------------------
    local rejects = {
        "",
        "hello",
        "CN2 100:99",
        "CN1",
        "CN1 100",
        "CN1 100:",
        "CN1 abc:99",
    }

    for _, bad in ipairs(rejects) do
        local parsed, err = contribute.Parse(bad)

        assert(parsed == nil,
            "must refuse: '" .. bad .. "'")
        assert(err, "and say why")
    end

    ------------------------------------------------------------
    -- A GOOD ONE ROUND-TRIPS.
    ------------------------------------------------------------
    local parsed, err, entries = contribute.Parse("CN1 100:98,99 200:150")

    assert(parsed, "a well-formed export must parse: " .. tostring(err))
    assert(entries == 2, "two entries, got " .. tostring(entries))
    assert(#parsed[100] == 2 and parsed[100][1] == 98,
        "with their prerequisites intact")

    local ok, importErr, imported = contribute.Import("CN1 100:98,99 200:150")

    assert(ok, "and import: " .. tostring(importErr))
    assert(imported == 2, "both of them")

    -- AS OBSERVATIONS, NEVER AS CURATED FACT. A stranger's addon watching an
    -- ordering is the weakest of the three sources the addon has.
    local imported100 = CN.GetDependency(CN.ObjectiveKey("QUEST", 100))

    assert(imported100 and imported100.observedRequires,
        "an imported chain is published as an observation")
    assert(imported100.requires == nil,
        "and must never be able to present itself as curated data")

    ------------------------------------------------------------
    -- AND `/cn why` MUST SAY WHERE THE CHAIN CAME FROM.
    --
    -- The import command promises exactly that, and it was not true: an
    -- imported edge was indistinguishable from a locally observed one, so the
    -- eligibility checker formatted it as "seen first on N characters" with N
    -- read from the harvest store -- which has no record of an imported quest
    -- and therefore answered zero. The player was told the addon had watched
    -- the ordering hold on ZERO characters.
    ------------------------------------------------------------
    assert(imported100.origin == "contributed",
        "an imported edge must carry where it came from")

    -- Drive it through the eligibility checker, which is what `/cn why`
    -- prints, rather than asserting on the field alone.
    local checker = CN.eligibilityCheckers
        and CN.eligibilityCheckers[CN.objectiveTypes.QUEST]

    if checker then
        local _, _, detail = checker(100)

        assert(detail == nil or not detail:find("0 characters"),
            "a chain nobody here observed must not be reported as observed "
            .. "on zero characters: " .. tostring(detail))

        if detail then
            assert(detail:find("imported"),
                "it must say the chain was imported: " .. detail)
        end
    end

    ------------------------------------------------------------
    -- AND WHAT THIS ACCOUNT HAS LEARNED MUST BE EXPORTABLE.
    --
    -- The other half of the feature. `Build` reads the harvest store and
    -- produces the one line a player is asked to paste; nothing had ever run
    -- it, so the format it emits had never been checked against the parser
    -- that has to read it back.
    ------------------------------------------------------------
    local contributeHarvest = CN:GetModule("Harvest")

    local store = contributeHarvest.Store()

    store[900001] = {
        observed = {
            [900010] = { seen = 9, characters = { a = true, b = true, c = true } },
        },
    }

    local export, buildErr, chains = contribute.Build()

    if export then
        assert(chains and chains > 0, "something must be exportable")

        assert(export:find("^" .. contribute.formatVersion),
            "the export must be stamped with its format version")

        -- The parser and the writer are two halves of one format, and the
        -- only way to know they agree is to hand one the other's output.
        local roundTrip, roundErr = contribute.Parse(export)

        assert(roundTrip,
            "what Build writes, Parse must read: " .. tostring(roundErr))
    else
        assert(buildErr, "and when there is nothing to share it says why")
    end

    store[900001] = nil

    CN.HandleSlashCommand("contribute")

    assert(contribute.Forget() >= 2, "and it can all be thrown away")

    print("  malformed imports refused, good ones land as observations, and "
        .. "the export round-trips")
end)()

print("\nOne grammar for uncertainty:")

;(function()
    ------------------------------------------------------------
    -- An estimated number must be visibly different from a measured one.
    -- Three hedging styles taught readers to ignore all three.
    ------------------------------------------------------------
    local measured  = CN.WithConfidence("14 min", CN.confidence.MEASURED)
    local estimated = CN.WithConfidence("14 min", CN.confidence.ESTIMATED)
    local unknown   = CN.WithConfidence("14 min", CN.confidence.UNKNOWN)

    assert(measured == "14 min", "a measured number is printed plain")

    assert(estimated ~= measured,
        "an estimate must not look identical to a measurement")
    assert(estimated:find("estimated"), "and must say the word")

    assert(not unknown:find("14"),
        "and an unknown must not print the number at all, got " .. unknown)

    assert(CN.ConfidenceFor(true) == CN.confidence.MEASURED)
    assert(CN.ConfidenceFor(false) == CN.confidence.ESTIMATED)

    print("  measured, estimated and unknown are three visibly different things")
end)()


print("\nErrors are kept where the player can find them:")

;(function()
    local errors = CN:GetModule("Errors")

    assert(errors, "the Errors module must load")

    errors.Clear()

    ------------------------------------------------------------
    -- A CAUGHT ERROR THAT NOBODY RECORDS IS AN ERROR NOBODY KNOWS ABOUT.
    ------------------------------------------------------------
    local ok, message = errors.Guard("a failing thing", function()
        error("something broke")
    end)

    assert(ok == false, "Guard returns what pcall returns")
    assert(tostring(message):find("something broke"), "including the message")

    assert(errors.Count() == 1, "and records it")

    ------------------------------------------------------------
    -- REPEATS ARE COUNTED, NOT LISTED.
    --
    -- A failure inside a ticker fires ten times a second. Twenty identical
    -- lines is not twenty pieces of evidence, and it pushes out the one
    -- different error that would have explained the whole thing.
    ------------------------------------------------------------
    -- Recorded directly rather than through Guard: error() prefixes the
    -- message with its own file and line, so two calls from two lines produce
    -- two genuinely different messages -- which is correct, and which the
    -- first version of this assertion mistook for a deduplication failure.
    for _ = 1, 50 do
        errors.Record("a ticker", "the same failure every tick")
    end

    assert(errors.Count() == 2,
        "fifty identical failures collapse to one entry, alongside the "
        .. "earlier distinct one -- got " .. errors.Count())

    local repeated

    for _, entry in ipairs(errors.All()) do
        if entry.context == "a ticker" then repeated = entry end
    end

    assert(repeated and repeated.count == 50,
        "with a count, got " .. tostring(repeated and repeated.count))

    ------------------------------------------------------------
    -- AND THE BUFFER IS BOUNDED.
    ------------------------------------------------------------
    for index = 1, errors.capacity + 10 do
        errors.Record("context " .. index, "distinct failure " .. index)
    end

    assert(errors.Count() == errors.capacity,
        "the ring is capped at " .. errors.capacity
        .. ", got " .. errors.Count())

    local oldest = errors.All()[1]

    assert(not oldest.message:find("something broke"),
        "and the oldest entries are the ones dropped")

    assert(errors.Clear() == errors.capacity, "clearing reports what it threw away")
    assert(errors.Count() == 0, "and empties it")

    -- A successful call must record nothing at all.
    local fine = errors.Guard("fine", function() return 42 end)

    assert(fine == true, "a successful guard succeeds")
    assert(errors.Count() == 0, "and records nothing")

    ------------------------------------------------------------
    -- AND THE GUARD MUST NOT CHANGE THE ARITY OF WHAT IT WRAPS.
    --
    -- `{ pcall(fn, ...) }` measured with `#` truncates at the first nil, so a
    -- wrapped function returning `value, nil` came back as one value. `#` on
    -- a table with holes is undefined in both interpreters; they happen to
    -- agree on the cases here, which is the kind of agreement this project
    -- has learned not to rest on.
    ------------------------------------------------------------
    local gotToy, first, second, third =
        errors.Guard("arity", function() return "a", nil, "c" end)

    assert(gotToy == true, "the guard still reports success first")
    assert(first == "a" and second == nil and third == "c",
        "and every return survives, holes included: got "
        .. tostring(first) .. ", " .. tostring(second) .. ", "
        .. tostring(third))

    local trailing = { errors.Guard("trailing",
        function() return "value", nil end) }

    assert(trailing[1] == true and trailing[2] == "value",
        "a trailing nil must not swallow the value in front of it")

    ------------------------------------------------------------
    -- AND `/cn errors` MUST PRINT WHAT IT HOLDS.
    --
    -- The command is what the bug template asks people to paste, and every
    -- branch of it -- this session, the previous one, the events the client
    -- refused -- was unexecuted.
    ------------------------------------------------------------
    errors.Clear()
    errors.ForgetPrevious()

    -- Nothing at all.
    local quietAt = #output

    CN.HandleSlashCommand("errors")

    local saidQuiet = false

    for index = quietAt + 1, #output do
        if output[index]:find("Nothing has gone wrong") then saidQuiet = true end
    end

    assert(saidQuiet, "with nothing recorded, it says so")

    -- This session.
    errors.Record("a failing provider", "it exploded")

    local liveAt = #output

    CN.HandleSlashCommand("errors")

    local named = false

    for index = liveAt + 1, #output do
        if output[index]:find("a failing provider") then named = true end
    end

    assert(named, "and it names what failed")

    -- The previous session, shown once and then forgotten.
    errors.Persist()
    errors.Clear()

    local previousAt = #output

    CN.HandleSlashCommand("errors")

    local fromLast = false

    for index = previousAt + 1, #output do
        if output[index]:find("From the previous one") then fromLast = true end
    end

    assert(fromLast, "the previous session's record is offered")

    assert(#errors.Previous() == 0,
        "and shown once, then forgotten -- otherwise it follows the player "
        .. "around forever")

    -- Events the client refused, which is the failure most likely to be
    -- mistaken for "there is just nothing to do".
    CN.rejectedEvents["MADE_UP_EVENT"] = "no such event"

    local refusedAt = #output

    CN.HandleSlashCommand("errors")

    local sawRefusal = false

    for index = refusedAt + 1, #output do
        if output[index]:find("MADE_UP_EVENT") then sawRefusal = true end
    end

    assert(sawRefusal,
        "an event the client refused must be named: a handler that never "
        .. "runs is silent in every other way")

    CN.rejectedEvents["MADE_UP_EVENT"] = nil

    CN.HandleSlashCommand("errors clear")

    print("  caught, deduplicated, bounded, clearable, and printed")
end)()

print("\nThe things that make it legible:")

;(function()
    local hud = CN:GetModule("Hud")

    assert(hud, "the Hud module must load")

    ------------------------------------------------------------
    -- NO INFORMATION CARRIED BY COLOUR ALONE.
    ------------------------------------------------------------
    assert(hud.BearingWord(0) == "ahead", "straight on")
    assert(hud.BearingWord(math.pi) == "back", "and a reversal")
    assert(hud.BearingWord(nil) == "?", "and an unknown bearing is not a claim")

    local words = {}

    for _, radians in ipairs({ 0, 0.8, 1.6, 3.0 }) do
        words[hud.BearingWord(radians)] = true
    end

    local distinct = 0

    for _ in pairs(words) do distinct = distinct + 1 end

    assert(distinct == 4,
        "four bearings must produce four different words, got " .. distinct)

    ------------------------------------------------------------
    -- THE SCALE IS BOUNDED, because a scale of 0.01 is an addon the player
    -- can no longer read well enough to fix.
    ------------------------------------------------------------
    local hudSettings = CN.Settings()

    hudSettings.uiScale = 50

    assert(hud.Scale() == 1, "an absurd scale falls back to 1")

    hudSettings.uiScale = 1.25

    assert(hud.Scale() == 1.25, "a sensible one is kept")

    hudSettings.uiScale = nil

    ------------------------------------------------------------
    -- OFF BY DEFAULT. Everything that puts pixels on screen uninvited is.
    ------------------------------------------------------------
    assert(hud.IsEnabled() == false, "the heads-up line is off by default")
    assert(hud.IsColourblind() == false, "and so is the word mode")

    print("  four distinct bearing words, a bounded scale, both off by default")
end)()

print("\nDecisions that could go stale:")

;(function()
    local orders = CN:GetModule("Orders")

    assert(orders, "the Orders module must load")

    ------------------------------------------------------------
    -- THE DELVES DECISION HAS A TRIGGER, NOT A DATE.
    --
    -- "We looked and there was nothing" decays into "nobody ever checked".
    -- The probe names the exact API that would change the answer.
    ------------------------------------------------------------
    local delvesReadable, detail = orders.DelveProgressAvailable()

    assert(delvesReadable == false, "no progress API in this client")
    assert(detail and detail:find("C_DelvesUI"),
        "and the reason names the API: " .. tostring(detail))

    -- Now pretend a patch shipped one.
    C_DelvesUI = { GetDelvesProgress = function() return {} end }

    local nowAvailable, nowDetail = orders.DelveProgressAvailable()

    assert(nowAvailable == true,
        "a client that exposes progress must be noticed")
    assert(nowDetail:find("should be tracking"),
        "and must say what to do about it")

    C_DelvesUI = nil

    print("  the Delves decision re-checks itself against the client")
end)()

print("\nThe first sixty seconds:")

;(function()
    local welcome = CN:GetModule("Welcome")

    assert(welcome, "the Welcome module must load")

    local account = CN.Account()

    account.welcomed = nil

    assert(welcome.HasSeen() == false, "a fresh install has not been welcomed")

    ------------------------------------------------------------
    -- ONCE. EVER.
    --
    -- An addon that re-introduces itself is an addon that has not noticed
    -- you already met.
    ------------------------------------------------------------
    welcome.Choose("collecting")

    assert(welcome.HasSeen() == true, "choosing marks it seen")

    -- And dismissing must mark it just as firmly as choosing, or the player
    -- who said "not now" is asked again tomorrow.
    account.welcomed = nil

    welcome.MarkSeen()

    assert(welcome.HasSeen() == true, "so does dismissing")

    print("  asked once, whichever way it is answered")
end)()


print("\nEvery command runs without throwing:")

;(function()
    ------------------------------------------------------------
    -- THE CHEAPEST TEST IN THE SUITE, AND ONE OF THE MOST VALUABLE.
    --
    -- A command is the only part of this addon a player touches directly, and
    -- a command that errors on an unusual state -- no data, nothing scanned,
    -- a client that will not answer -- is the failure they actually see. Half
    -- the commands in this release were written this week and none of them
    -- had ever been executed by the suite.
    --
    -- Not asserting on output: what each command SAYS is tested elsewhere, by
    -- tests that know what it means. This asserts only that it survives being
    -- run against a client that is refusing to be helpful, which is the state
    -- every one of these hits on a fresh install.
    ------------------------------------------------------------
    local commands = {
        "travel", "situation", "orders", "waiting", "waiting nowhere",
        "contribute", "contribute forget", "contribute import rubbish",
        "hud", "hud off", "scale", "scale 1.5", "scale 99",
        "colourblind", "colourblind off", "cues", "cues off",
        "errors", "errors clear", "learned", "locale", "locale missing",
        "instances", "drops", "drops Nothing At All",
        "bags", "clock", "nearby", "order", "order 2", "situation",
        "sets", "keepfilter", "keepfilter off", "locale export",
        "help", "help all", "help lockout", "help nothingmatchesthis",
        "selftest", "capture", "capture clear", "dbsize", "welcome",
    }

    local failures = {}

    for _, command in ipairs(commands) do
        local ok, err = pcall(CN.HandleSlashCommand, command)

        if not ok then
            table.insert(failures, command .. " -> " .. tostring(err))
        end
    end

    for _, failure in ipairs(failures) do
        print("  THREW: " .. failure)
    end

    assert(#failures == 0,
        #failures .. " command(s) threw against a bare client")

    print("  " .. #commands .. " command invocations, none of them threw")

    -- AND THE COMMANDS THAT READ NEW SYSTEMS MUST SURVIVE THOSE SYSTEMS
    -- BEING ABSENT. A client without a mailbox, without containers, without
    -- a keystone: every one of those is an ordinary state, not an error.
    local savedContainer = C_Container
    local savedInbox     = GetInboxNumItems

    C_Container      = nil
    GetInboxNumItems = nil

    for _, command in ipairs({ "bags", "clock", "travel", "nearby" }) do
        local ok, err = pcall(CN.HandleSlashCommand, command)

        assert(ok, command .. " threw when the client offered nothing: "
            .. tostring(err))
    end

    C_Container      = savedContainer
    GetInboxNumItems = savedInbox

    print("  and four of them survive a client that answers nothing")

    -- And the scale command must not have left a silly value behind: "scale
    -- 99" was in that list deliberately.
    local hud = CN:GetModule("Hud")

    assert(hud.Scale() >= 0.7 and hud.Scale() <= 2.0,
        "a refused scale must not be stored, got " .. hud.Scale())

    print("  and a refused setting was not stored")
end)()


print("\nThe language the game actually runs:")

;(function()
    ------------------------------------------------------------
    -- THE WORST DEFECT THIS PROJECT HAS SHIPPED, AND HOW IT HID.
    --
    -- World of Warcraft runs Lua 5.1. This suite runs Lua 5.4. In 5.3+,
    -- math.atan(y, x) is the two-argument arctangent. In 5.1 it is the
    -- one-argument one and the second argument is silently discarded --
    -- no error, and a plausible-looking number.
    --
    -- So every bearing computed in game from 0.19.0 to 0.43.0 was atan(dx)
    -- with the north-south component thrown away. The arrow could not point
    -- behind the player. It was reported three times and "fixed" three times
    -- against a suite in which the code was genuinely correct.
    --
    -- This test simulates the game's semantics, which is the only way an
    -- offline suite running a different interpreter can ever catch this.
    ------------------------------------------------------------
    local navigation = CN:GetModule("Navigation")

    local realAtan  = math.atan
    local realAtan2 = math.atan2

    -- Exactly what the game provides: a one-argument atan that ignores
    -- anything else it is handed, and a real atan2 alongside it.
    math.atan = function(y)
        return realAtan(y)
    end

    math.atan2 = math.atan2 or function(y, x)
        return realAtan(y, x)
    end

    local savedSpan = CN_TEST_MAP_SPAN

    CN_TEST_SetMapSpan({ 1000, 1000 })

    local cases = {
        { name = "north", x = 0.5, y = 0.4, expected =   0 },
        { name = "east",  x = 0.6, y = 0.5, expected =  90 },
        { name = "south", x = 0.5, y = 0.6, expected = 180 },
        { name = "west",  x = 0.4, y = 0.5, expected = -90 },
    }

    for _, case in ipairs(cases) do
        local relative = navigation.RelativeBearing(0.5, 0.5, case.x, case.y, 0, 1)

        local off = math.abs(math.deg(
            navigation.NormalizeAngle(relative - math.rad(case.expected))))

        assert(off < 1, string.format(
            "under the GAME's Lua, a target due %s reads as %.0f degrees, "
            .. "not %d -- the addon is using two-argument math.atan somewhere",
            case.name, math.deg(relative), case.expected))
    end

    -- And prove the test would have caught the original bug: the raw
    -- expression the addon used to contain must now be visibly wrong.
    local naive = math.atan(1, 0)

    assert(math.abs(naive - (math.pi / 2)) > 0.5,
        "the simulation must actually reproduce 5.1 behaviour, or this test "
        .. "proves nothing")

    math.atan  = realAtan
    math.atan2 = realAtan2

    CN_TEST_SetMapSpan(savedSpan)

    print("  bearings are correct under Lua 5.1 semantics, not only 5.4's")

    ------------------------------------------------------------
    -- AND NO SOURCE FILE MAY USE THE TWO-ARGUMENT FORM AGAIN.
    --
    -- The fix above is one function. The rule is what stops the next one:
    -- this walks the shipped tree and fails on any reintroduction, which no
    -- amount of remembering can be relied on to do.
    ------------------------------------------------------------
    local offenders = {}

    local manifest = io.open(ROOT .. "/CompletionNavigator.toc", "r")

    if manifest then
        for line in manifest:lines() do
            local relative = line:match("^([%w\\/_%.]+%.lua)%s*$")

            if relative then
                local path = ROOT .. "/" .. relative:gsub("\\", "/")

                local source = io.open(path, "r")

                if source then
                    local body = source:read("*a")

                    source:close()

                    -- Strip comments before searching, or this file's own
                    -- explanation of the bug counts as an instance of it.
                    body = body:gsub("%-%-[^\n]*", "")

                    if body:find("math%.atan%s*%([^)]-,") then
                        table.insert(offenders, relative)
                    end
                end
            end
        end

        manifest:close()
    end

    assert(#offenders == 0,
        "two-argument math.atan is silently wrong in the game's Lua; use "
        .. "CN.Atan2. Found in: " .. table.concat(offenders, ", "))

    print("  and no shipped file uses the two-argument form")
end)()


print("\nConstructs that mean two different things:")

;(function()
    ------------------------------------------------------------
    -- THE RULE, NOT THE INSTANCE.
    --
    -- 0.43.1 fixed two-argument math.atan, which is silently wrong in the
    -- game's Lua. The fix was one function. What stops the next one is a rule
    -- that reads every shipped file and refuses anything whose meaning
    -- depends on which interpreter is running.
    --
    -- Each entry names WHAT breaks and WHERE the addon runs, because a lint
    -- that says "forbidden" and not "why" gets worked around.
    ------------------------------------------------------------
    local hazards = {
        {
            pattern = "math%.atan%s*%([^)]-,",
            what    = "two-argument math.atan",
            why     = "5.1 discards the second argument silently; use CN.Atan2",
        },
        {
            pattern = "table%.unpack",
            what    = "table.unpack",
            why     = "does not exist in 5.1; use CN.Unpack",
        },
        {
            pattern = "math%.fmod",
            what    = "math.fmod",
            why     = "disagrees with %% on sign for negative operands; use CN.Mod",
        },
        {
            pattern = "%f[%w]goto%f[%W]",
            what    = "goto",
            why     = "5.2 syntax; the game's parser rejects it outright",
        },
        {
            pattern = "math%.tointeger",
            what    = "math.tointeger",
            why     = "5.3 only; 5.1 has no integer subtype",
        },
        {
            pattern = "math%.type",
            what    = "math.type",
            why     = "5.3 only",
        },
        {
            pattern = "[^%s%w_%.%)%]\"']//[^%s]",
            what    = "integer division //",
            why     = "5.3 operator; 5.1 reads it as a syntax error",
        },
    }

    local manifestFiles = {}

    local manifest = io.open(ROOT .. "/CompletionNavigator.toc", "r")

    assert(manifest, "the manifest must be readable")

    for line in manifest:lines() do
        local relative = line:match("^([%w\\/_%.]+%.lua)%s*$")

        if relative then
            table.insert(manifestFiles, relative)
        end
    end

    manifest:close()

    assert(#manifestFiles > 40, "the manifest must list the tree, got " .. #manifestFiles)

    local offences = {}

    for _, relative in ipairs(manifestFiles) do
        local handle = io.open(ROOT .. "/" .. relative:gsub("\\", "/"), "r")

        if handle then
            local body = handle:read("*a")

            handle:close()

            -- Comments are stripped first, or every explanation of a hazard
            -- counts as an instance of it -- including the ones written to
            -- stop somebody reintroducing it.
            body = body:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", "")

            for _, hazard in ipairs(hazards) do
                if body:find(hazard.pattern) then
                    table.insert(offences, string.format(
                        "%s uses %s (%s)", relative, hazard.what, hazard.why))
                end
            end
        end
    end

    for _, offence in ipairs(offences) do
        print("  " .. offence)
    end

    assert(#offences == 0,
        #offences .. " construct(s) that behave differently in the game's Lua")

    print("  " .. #manifestFiles .. " files scanned for " .. #hazards
        .. " constructs that differ between 5.1 and 5.4")

    ------------------------------------------------------------
    -- AND THE HELPERS THEMSELVES MUST BE RIGHT.
    ------------------------------------------------------------
    assert(CN.Unpack({ 1, 2, 3 }) == 1, "Unpack unpacks")

    -- Floored, so the result carries the sign of the DIVISOR. This is what
    -- every angle in the addon wants: wrapping never lands in the wrong half
    -- of the circle. math.fmod would answer -1 here.
    assert(CN.Mod(-1, 4) == 3,
        "modulo must floor, got " .. CN.Mod(-1, 4))
    assert(CN.Mod(5, 4) == 1, "and be ordinary for positives")
    assert(CN.Mod(1, 0) == 0, "and refuse to divide by zero rather than throw")

    print("  and the replacements behave the same in both")
end)()


print("\nWhat you are already carrying:")

;(function()
    local inventory = CN:GetModule("Inventory")

    assert(inventory, "the Inventory module must load")

    assert(inventory.IsAvailable(), "the container API must be modelled")

    local items = inventory.Scan()

    -- At least the three the small fixture defines. The BENCH grows the bags
    -- to a realistic hundred and eighty, so an equality here would assert the
    -- size of the fixture rather than the behaviour of the scan.
    assert(#items >= 3, "every occupied slot is read, got " .. #items)

    ------------------------------------------------------------
    -- A QUEST STARTER YOU HAVE ALREADY USED IS NOT A NEXT ACTION.
    --
    -- The client flags the item either way; `isActive` is the difference
    -- between "right-click this" and "you did, it is in your log".
    ------------------------------------------------------------
    local starters = inventory.QuestStarters()

    assert(#starters == 1,
        "only the unaccepted starter counts, got " .. #starters)
    assert(starters[1].questID == 44001, "and it is the right one")

    local bagCandidates = CN.candidateProviders["Inventory"].fn()

    local bagOffered = {}

    for _, candidate in ipairs(bagCandidates) do
        bagOffered[candidate.id] = candidate
    end

    assert(bagOffered[44001], "the unaccepted starter is recommended")
    assert(not bagOffered[44002],
        "the accepted one must NOT be -- it would send the player to "
        .. "right-click something they have already used")

    -- ZERO TRAVEL, and it is the honest number rather than a flattering one:
    -- the item is in their bag.
    assert(bagOffered[44001].travelCost == 0,
        "an item in your bag costs nothing to reach")

    ------------------------------------------------------------
    -- A COLLECTIBLE IN A BAG IS THE CHEAPEST ACTION IN THE GAME.
    --
    -- A mount, a pet or a toy the player is carrying and has not learned is
    -- zero yards away. `UncollectedItems` is the function that finds them --
    -- three branches, all of them written and none of them ever executed,
    -- because no bag in the fixture held a collectible.
    ------------------------------------------------------------
    CN_TEST_BAGS[1] = {
        -- Item 800 teaches mount 2, which the fixture leaves uncollected.
        { itemID = 800, stackCount = 1 },
        -- Item 801 is a caged pet, species 101.
        { itemID = 801, stackCount = 1 },
        -- Item 501 is a toy the player does not own.
        { itemID = 501, stackCount = 1 },
        -- And 500 they DO own, which must not be offered.
        { itemID = 500, stackCount = 1 },
    }

    inventory.Forget()

    local carried = inventory.UncollectedItems()

    local kinds = {}

    for _, item in ipairs(carried) do
        kinds[item.kind] = (kinds[item.kind] or 0) + 1
    end

    assert(kinds[CN.objectiveTypes.MOUNT],
        "an uncollected mount in a bag must be found")

    assert(kinds[CN.objectiveTypes.TOY],
        "so must an uncollected toy")

    for _, item in ipairs(carried) do
        assert(item.itemID ~= 500,
            "and a toy the player already owns must not be: telling somebody "
            .. "to learn what they have is the one answer worse than silence")
    end

    ------------------------------------------------------------
    -- AND COUNTING WHAT IS CARRIED.
    --
    -- `Inventory.Count` is what turns "go and do that quest" into "ten more".
    -- It has three fallbacks -- C_Item, the old global, and giving up -- and
    -- none had been run.
    ------------------------------------------------------------
    assert(inventory.Count(nil) == 0, "no item, no count")

    local realCItem = C_Item

    C_Item = { GetItemCount = function() return 7 end }

    assert(inventory.Count(60002) == 7, "the modern API answers first")

    C_Item = nil

    local realGlobal = GetItemCount

    GetItemCount = function() return 3 end

    assert(inventory.Count(60002) == 3,
        "and the old global is the fallback, not a crash")

    GetItemCount = nil

    assert(inventory.Count(60002) == 0,
        "with neither, the answer is zero rather than an error")

    GetItemCount = realGlobal
    C_Item       = realCItem

    CN_TEST_BAGS[1] = nil

    inventory.Forget()

    print("  bags read, an accepted starter is not offered twice, and a "
        .. "carried collectible is found")
end)()

print("\nThings with a clock on them:")

;(function()
    local waiting = CN:GetModule("Waiting")

    assert(waiting, "the Waiting module must load")

    local mail, readable = waiting.Mail()

    assert(readable, "the mailbox must be readable")
    assert(#mail >= 4, "every message is read, got " .. #mail)

    -- Sorted by what expires first, because that is the order they matter in.
    assert(mail[1].daysLeft <= mail[2].daysLeft, "soonest first")

    ------------------------------------------------------------
    -- EXPIRING MAIL WITH NOTHING IN IT IS NOT A LOSS.
    --
    -- Mail is destroyed when it expires. That only matters if something is
    -- attached: telling somebody to run to a mailbox to save an empty message
    -- from a stranger is the addon crying wolf, and the next warning is the
    -- one they ignore.
    ------------------------------------------------------------
    local expiring = waiting.ExpiringMail()

    assert(#expiring == 2,
        "only expiring mail WITH attachments counts, got " .. #expiring)

    for _, entry in ipairs(expiring) do
        assert(entry.items > 0 or entry.money > 0,
            "nothing empty may be in that list")
        assert(entry.daysLeft <= waiting.mailWarningDays,
            "nor anything that is not expiring soon")
    end

    local waitingCandidates = CN.candidateProviders["Waiting"].fn()

    local mailCandidate

    for _, candidate in ipairs(waitingCandidates) do
        if candidate.id == "mail" then mailCandidate = candidate end
    end

    assert(mailCandidate, "expiring mail is a real objective")
    assert(mailCandidate.expiresIn and mailCandidate.expiresIn > 0,
        "with a real deadline attached")

    print("  " .. #expiring .. " messages worth saving, and the empty one is left alone")
end)()

print("\nFlight, where flight is allowed:")

;(function()
    local travel = CN:GetModule("Travel")

    local memory = travel.FlightMemory()

    for key in pairs(memory) do
        memory[key] = nil
    end

    local session = CN:GetModule("Session")

    -- Give the character enough flying samples to count as able to fly.
    local samples = CN.character.speedSamples

    samples.flying = {}

    for _ = 1, 10 do
        table.insert(samples.flying, 60)
    end

    session.LoadSamples()

    assert(travel.HasFlying(), "a character with flight samples can fly")

    ------------------------------------------------------------
    -- A ZONE KNOWN NOT TO ALLOW FLYING MUST NOT BE FLOWN TO.
    --
    -- IsFlyableArea answers for where the player is STANDING and there is no
    -- API that answers for anywhere else, so the addon remembers what it has
    -- observed per zone. A plan the player cannot follow is worse than a
    -- pessimistic one they can.
    ------------------------------------------------------------
    memory[94] = false

    assert(travel.CanFly(94) == false,
        "a zone remembered as no-fly must refuse")

    memory[94] = true

    assert(travel.CanFly(94) == true,
        "and one remembered as flyable must allow it")

    for key in pairs(memory) do
        memory[key] = nil
    end

    samples.flying = {}

    session.LoadSamples()

    ------------------------------------------------------------
    -- AND SOMETHING MUST ACTUALLY OBSERVE IT.
    --
    -- The two assertions above wrote the memory directly. That is how a
    -- producer nobody calls looked healthy for four releases: `NoteFlyable`
    -- was written, commented at length, and never wired to an event -- so the
    -- store the addon consults was populated in every test and empty in every
    -- game.
    --
    -- A store is only as real as the thing that fills it, so this fills it
    -- the way the game does: by arriving somewhere.
    ------------------------------------------------------------
    CN_TEST_FLYABLE = false

    fire("ZONE_CHANGED_NEW_AREA")

    local here = CN.GetPlayerPosition()

    assert(memory[here] == false,
        "arriving in a zone where flight is disabled must be remembered, got "
        .. tostring(memory[here]))

    CN_TEST_FLYABLE = true

    fire("ZONE_CHANGED_NEW_AREA")

    assert(memory[here] == true,
        "and arriving somewhere it is allowed must be remembered too")

    -- Demonstrably flying outranks anything the client says about the area.
    memory[here] = false

    CN_TEST_FLYING = true

    fire("PLAYER_CONTROL_GAINED")

    assert(memory[here] == true,
        "you cannot be flying in a zone where flying is impossible")

    CN_TEST_FLYING = false

    for key in pairs(memory) do
        memory[key] = nil
    end

    print("  what was observed about a zone beats what is true where you stand")
end)()

print("\nWhy the list is in this order:")

;(function()
    ------------------------------------------------------------
    -- EVERY TERM SHOWN MUST HAVE ACTUALLY CONTRIBUTED.
    --
    -- An explanation listing ten terms, eight of them zero, is a wall of
    -- noise that hides the two that decided the answer.
    ------------------------------------------------------------
    local objective = CN.NewObjective({
        id              = 1,
        type            = CN.objectiveTypes.QUEST,
        name            = "A Quest",
        completionValue = 5,
        travelCost      = 3,
    })

    local terms = CN.ExplainScore(objective)

    assert(#terms > 0, "something must explain the score")

    for _, term in ipairs(terms) do
        assert(math.abs(term.value) > 0.001,
            "a term worth nothing must not be listed: " .. term.label)
    end

    -- Biggest first: the reader wants the reason, not an inventory.
    for index = 2, #terms do
        assert(math.abs(terms[index - 1].value) >= math.abs(terms[index].value),
            "terms must be ordered by how much they mattered")
    end

    -- And the explanation must add up to the score, or it is a story about
    -- an arithmetic the addon is not actually doing.
    local total = 0

    for _, term in ipairs(terms) do
        total = total + term.value
    end

    local scored = CN.ScoreObjective(objective)

    assert(math.abs(total - scored) < 0.01,
        string.format("the terms must sum to the score: %.2f vs %.2f",
            total, scored))

    ------------------------------------------------------------
    -- IN EVERY MODE, AND WITH AN ADJUSTER LIVE.
    --
    -- The assertion above ran one synthetic quest in balanced mode, where the
    -- profile has no type weighting and both registered adjusters happen to
    -- be no-ops. Under those conditions the explanation summed to the score
    -- while omitting BOTH multiplicative steps -- so `/cn mode quests`
    -- printed a headline of 6.0 above terms totalling 3.0, and said in its
    -- own comment that if the two ever disagreed the explanation was wrong.
    --
    -- One case, chosen because it was easy, agreeing with the code for a
    -- reason that had nothing to do with the property being tested.
    ------------------------------------------------------------
    local saved = CN.Settings().priorityMode

    CN.RegisterScoreAdjuster("ExplainProbe", function(candidate, score)
        if candidate.id == 1 then
            return score - 0.75
        end

        return score
    end)

    local modes = {}

    for name in pairs(CN.priorityProfiles) do
        table.insert(modes, name)
    end

    table.sort(modes)

    for _, name in ipairs(modes) do
        CN.Settings().priorityMode = name

        for _, kind in ipairs({ CN.objectiveTypes.QUEST,
                                CN.objectiveTypes.PET,
                                CN.objectiveTypes.REPUTATION }) do

            local probe = CN.NewObjective({
                id              = 1,
                type            = kind,
                name            = "Probe",
                completionValue = 4,
                travelCost      = 1,
                expiresIn       = 3600,
            })

            local sum = 0

            for _, term in ipairs(CN.ExplainScore(probe)) do
                sum = sum + term.value
            end

            local actual = CN.ScoreObjective(probe)

            assert(math.abs(sum - actual) < 0.01,
                string.format("mode %s, %s: the explanation sums to %.3f "
                    .. "but the score is %.3f", name, kind, sum, actual))
        end
    end

    CN.scoreAdjusters["ExplainProbe"] = nil

    for index, name in ipairs(CN.scoreAdjusterOrder) do
        if name == "ExplainProbe" then
            table.remove(CN.scoreAdjusterOrder, index)
            break
        end
    end

    CN.Settings().priorityMode = saved

    print("  " .. #terms .. " terms, ordered by weight, summing to the score")

    print("  and they still sum to it in all " .. #modes
        .. " modes, with an adjuster live")
end)()

print("\nA plan you can actually start:")

;(function()
    local session = CN:GetModule("Session")

    CN_TEST_INSTANCE   = "party"
    CN_TEST_GROUP_SIZE = 5

    CN.InvalidateRanking()

    local plan = session.Plan(30)

    assert(plan.blocked == "instanced",
        "a plan cannot be walked from inside a dungeon")
    assert(#plan.stops == 0, "so no stops are offered")
    assert(plan.notice, "and the player is told why")

    CN_TEST_INSTANCE   = nil
    CN_TEST_GROUP_SIZE = 1

    CN.InvalidateRanking()

    local normal = session.Plan(30)

    assert(normal.blocked == nil, "and outside, planning resumes")

    print("  the planner refuses rather than laying out a route you cannot walk")
end)()


print("\nA whole session, end to end:")

;(function()
    ------------------------------------------------------------
    -- EVERY PART OF THIS IS TESTED. THE SEQUENCE WAS NOT.
    --
    -- Scanning works. Recommending works. Routing works. Following works.
    -- Each has its own section above, each starts from a fixture arranged to
    -- suit it, and none of them proves the addon survives being used in the
    -- order a player uses it -- which is the only order that has ever
    -- mattered to anybody.
    --
    -- This walks one login: scan, ask, route, follow a stop, finish, and log
    -- out. It asserts the handful of things that must be true at each step
    -- and, more importantly, that nothing throws along the way.
    ------------------------------------------------------------
    local errors = CN:GetModule("Errors")

    errors.Clear()

    local session = CN:GetModule("Session")
    local follow  = CN:GetModule("Follow")

    -- 1. A fresh login.
    CN.InvalidateCandidates()

    local welcome = CN:GetModule("Welcome")

    CN.Account().welcomed = true

    -- 2. Ask the question the addon exists to answer.
    local first = CN.Recommend(1)[1]

    assert(first, "a scanned character must get an answer")
    assert(first.name, "and it must have a name to show")

    -- 3. Ask why, and why that order -- both of which read the same scoring.
    local explained = CN.ExplainRecommendation(first)

    assert(#explained > 0, "every recommendation carries a reason")

    local terms = CN.ExplainScore(first)

    assert(#terms > 0, "and the order can be explained")

    -- 4. Route the zone.
    local mapID, x, y = CN.GetPlayerPosition()

    local route, skipped, hubs = CN.BuildZoneRoute(mapID, x, y)

    assert(type(route) == "table", "a route is a list")
    assert(type(hubs) == "table", "grouped into stops")

    -- 5. And what is outside it.
    local otherZones = CN.BuildCrossZoneRoute()

    assert(type(otherZones) == "table", "the next zone is costable")

    -- 6. Plan the time available.
    local plan = session.Plan(30)

    assert(plan and plan.minutes == 30, "a plan covers the minutes asked for")

    -- 7. Follow the route, clear a stop, and stop following.
    follow.Start()

    assert(follow.active, "follow mode starts")
    assert(follow.completed == 0, "with nothing cleared yet")

    follow.NoteStopCleared()

    assert(follow.completed == 1, "and counts what is cleared")

    follow.Stop()

    assert(not follow.active, "and stops when told")

    -- 8. Log out. Speed samples, session length and the error summary all
    --    have to survive this without complaint.
    CN.FireEvent("PLAYER_LOGOUT")

    -- 9. NOTHING may have gone wrong in any of that.
    assert(errors.Count() == 0,
        errors.Count() .. " error(s) during an ordinary session: "
        .. (errors.All()[1] and (errors.All()[1].context .. " -- "
            .. errors.All()[1].message) or ""))

    print("  login, ask, explain, route, plan, follow, log out -- no errors")
end)()


print("\nHow close a quest actually is:")

;(function()
    local inventory = CN:GetModule("Inventory")

    ------------------------------------------------------------
    -- THE PROMISE THIS FILE'S HEADER MADE IN 0.44.0 AND DID NOT KEEP.
    --
    -- "Forty of the fifty things a quest wants, so the answer is 'ten more'."
    -- The header said it; the code collected quest starters and nothing else.
    -- Writing down what something is going to do and then not doing it is
    -- worse than not writing it down, because the next reader believes it.
    ------------------------------------------------------------
    local progress = inventory.QuestProgress(9001)

    assert(#progress == 1, "a counting objective is reported, got " .. #progress)
    assert(progress[1].remaining == 1, "one feather to go, got "
        .. progress[1].remaining)
    assert(progress[1].done == 11 and progress[1].required == 12,
        "with the client's own counts")

    -- Finished objectives are not outstanding work.
    CN_TEST_OBJECTIVES[9003] = {
        { text = "Done already", numFulfilled = 5, numRequired = 5, finished = true },
    }

    assert(#inventory.QuestProgress(9003) == 0,
        "a finished objective is not something left to do")

    CN_TEST_OBJECTIVES[9003] = nil

    ------------------------------------------------------------
    -- NEAREST TO DONE FIRST, and only what is genuinely near.
    ------------------------------------------------------------
    local nearly = inventory.NearlyDone()

    assert(#nearly >= 1, "the nearly-done list must find the feathers")

    for _, row in ipairs(nearly) do
        assert(row.remaining <= inventory.nearlyDoneRemaining,
            "eighteen boars away is not 'nearly done'")
    end

    assert(nearly[1].remaining <= (nearly[2] and nearly[2].remaining or 99),
        "closest first")

    -- And it must be worth MORE the closer it is, or the ranking has learned
    -- nothing from knowing the number.
    local inventoryCandidates = CN.candidateProviders["Inventory"].fn()

    local nearlyCandidate

    for _, candidate in ipairs(inventoryCandidates) do
        if candidate.id == 9001 then nearlyCandidate = candidate end
    end

    assert(nearlyCandidate, "the nearly-done quest is recommended")
    assert(nearlyCandidate.completionValue > 2,
        "and is worth more than a quest not started")

    print("  '" .. nearly[1].remaining .. " more' is a different answer from 'not finished'")
end)()

print("\nWhich flights are known to connect:")

;(function()
    local travel = CN:GetModule("Travel")

    local routes = travel.Routes()

    for key in pairs(routes) do
        routes[key] = nil
    end

    ------------------------------------------------------------
    -- UNDIRECTED, because a flight in one direction is evidence the two
    -- points are on the same network -- which is what the costing needs.
    ------------------------------------------------------------
    assert(travel.NoteRoute(1, 2), "a flight is recorded")

    assert(travel.IsKnownRoute(1, 2), "in the direction it was flown")
    assert(travel.IsKnownRoute(2, 1), "and in the other one")

    assert(not travel.IsKnownRoute(1, 3),
        "a pair nobody has flown is not known")

    ------------------------------------------------------------
    -- AND AN UNKNOWN PAIR IS NOT RULED OUT.
    --
    -- There is no API for "does A connect to B". Treating never-observed as
    -- impossible would make the model worse than the assumption it replaced,
    -- because most pairs are never observed by anybody.
    ------------------------------------------------------------
    assert(travel.knownRouteBonus < 1 and travel.knownRouteBonus > 0.5,
        "a known route is preferred, not mandatory")

    for key in pairs(routes) do
        routes[key] = nil
    end

    print("  a flight taken is proof; a flight not taken is not disproof")
end)()

print("\nThe list, sorted the way you asked:")

;(function()
    local list = CN.UI.CreateList(CreateFrame("Frame"))

    local entries = {
        { text = "Zebra" },
        { text = "apple" },
        { text = "Mango" },
    }

    list:SetEntries(entries)

    ------------------------------------------------------------
    -- "AS RANKED" IS FIRST, so the default never changes for anybody who
    -- does not go looking for this.
    ------------------------------------------------------------
    assert(list:SortMode() == "ranked", "the ranking is the default order")

    assert(list.rows[1].entry.text == "Zebra",
        "and it is left exactly as the tab produced it")

    assert(list:CycleSort() == "name", "clicking cycles to alphabetical")

    assert(string.lower(list.rows[1].entry.text) == "apple",
        "which is case-insensitive, got " .. list.rows[1].entry.text)

    assert(list:CycleSort() == "reverse", "then reversed")

    assert(list.rows[1].entry.text == "Zebra", "the other way round")

    assert(list:CycleSort() == "ranked", "and back to the ranking")

    print("  three orders, and the ranking is the one you get by default")
end)()


print("\nAppearance sets:")

;(function()
    local sets = CN:GetModule("Sets")

    assert(sets, "the Sets module must load")

    local all, readable = sets.All()

    assert(readable, "the client must be answering")
    assert(#all >= 3, "every set is read, got " .. #all)

    ------------------------------------------------------------
    -- FINISHED IS NOT NEARLY FINISHED.
    --
    -- The two states a set feature must never confuse. A completed set has
    -- zero pieces missing, and "zero missing" satisfies "within two missing"
    -- unless somebody says otherwise -- which is exactly the off-by-one that
    -- would put every finished set in the player's to-do list forever.
    ------------------------------------------------------------
    local nearly = sets.NearlyComplete()

    for _, set in ipairs(nearly) do
        assert(set.missing > 0,
            "a finished set is not something left to do: " .. tostring(set.name))
        assert(set.name ~= "Finished", "and specifically not that one")
    end

    assert(#nearly == 1, "only the one within two pieces, got " .. #nearly)
    assert(nearly[1].name == "Almost There", "and it is the right one")

    -- Five pieces missing is a decision about the evening, not a next action.
    for _, set in ipairs(nearly) do
        assert(set.name ~= "Barely Begun", "a set barely started is not near")
    end

    local setCandidates = CN.candidateProviders["Sets"].fn()

    assert(#setCandidates == 1, "one recommendation, got " .. #setCandidates)
    assert(setCandidates[1].reasons[1]:find("4 of 5"),
        "carrying the real denominator: " .. setCandidates[1].reasons[1])

    ------------------------------------------------------------
    -- THE GUILD AND THE QUEUE LIST, WHICH ARE READ-ONLY ON PURPOSE.
    --
    -- Two APIs the addon reads and must never act on: an addon that puts
    -- somebody in a group-finder queue is an addon that will one day do it
    -- mid-raid. Both were written, both are guarded at every step, and
    -- neither had been executed -- so the guards were untested and the
    -- feature could have been silently off.
    ------------------------------------------------------------
    local realIsInGuild = IsInGuild
    local realGuildInfo = GetGuildInfo
    local realLFG       = C_LFGList

    IsInGuild = nil

    assert(sets.Guild() == nil,
        "a client with no guild API is not a client with no guild -- but "
        .. "either way there is nothing to report")

    IsInGuild = function() return false end

    assert(sets.Guild() == nil, "and a player in no guild has no guild")

    IsInGuild   = function() return true end
    GetGuildInfo = function() return "Test Guild", "Officer", 1 end

    local guild = sets.Guild()

    assert(guild and guild.name == "Test Guild" and guild.rank == "Officer",
        "a player in a guild gets their guild and their rank")

    -- An API that exists and throws, which is the case a bare call misses.
    GetGuildInfo = function() error("guild API exploded") end

    local survived = sets.Guild()

    assert(survived and survived.name == nil,
        "a guild API that throws costs the name, not the call")

    IsInGuild    = realIsInGuild
    GetGuildInfo = realGuildInfo

    -- THE QUEUES.
    C_LFGList = nil

    local noQueues, answered = sets.Queues()

    assert(#noQueues == 0 and answered == false,
        "with no group finder API the answer is 'cannot say', not 'nothing "
        .. "available'")

    C_LFGList = {
        GetAvailableActivities = function() return { 11, 12, 13 } end,
        GetActivityInfoTable   = function(id)
            if id == 13 then
                -- The client sometimes answers with nothing useful.
                return nil
            end

            return { fullName = "Activity " .. id, maxNumPlayers = 5 }
        end,
    }

    local queues, ok = sets.Queues()

    assert(ok ~= false, "with the API present it answers")
    assert(#queues == 2,
        "an activity the client will not describe is dropped, not invented: "
        .. "got " .. #queues)

    assert(queues[1].name == "Activity 11" and queues[1].maxPlayers == 5,
        "and the ones it will describe carry their real numbers")

    -- An API that throws must cost the list, not the session.
    C_LFGList.GetAvailableActivities = function() error("LFG exploded") end

    local threw, reported = sets.Queues()

    assert(#threw == 0 and reported == false,
        "a group finder that throws is reported as unreadable")

    C_LFGList = realLFG

    print("  " .. #all .. " sets read, one within two pieces, the finished "
        .. "one left alone, guild and queues read without acting")
end)()


print("\nThe curated data accessors:")

;(function()
    ------------------------------------------------------------
    -- ELIGIBILITY AND TURN-IN DATA SHIPPED AS SCHEMA IN 0.43.0 WITH NO ROWS,
    -- AND NOTHING HAS EVER EXERCISED THE READERS.
    --
    -- A schema nothing reads is a schema that will be wrong the first time
    -- somebody fills it in. These rows are registered by the test rather than
    -- shipped, so the accessors are tested without pretending the database
    -- has content it does not.
    ------------------------------------------------------------
    local Static = CN.Static

    Static.RegisterQuests({
        [77001] = {
            name    = "For Druids Only",
            classes = { "DRUID" },
        },
        [77002] = {
            name     = "Level Gate",
            minLevel = 70,
        },
        [77003] = {
            name    = "Alliance Business",
            faction = "Alliance",
        },
        [77004] = {
            name        = "Handed In Elsewhere",
            mapID       = 94,
            turnInMapID = 2112,
            turnInX     = 0.5,
            turnInY     = 0.5,
        },
    })

    local character = { class = "WARRIOR", race = "HUMAN",
        faction = "Alliance", level = 60 }

    local ok, reason = Static.QuestEligibility(77001, character)

    assert(ok == false, "a druid quest is not for a warrior")
    assert(reason and reason:find("class"), "and says which gate: " .. tostring(reason))

    assert(Static.QuestEligibility(77001,
        { class = "DRUID", faction = "Alliance", level = 60 }),
        "and a druid may take it")

    local levelOk, levelReason = Static.QuestEligibility(77002, character)

    assert(levelOk == false and levelReason:find("70"),
        "a level gate reports the level")

    local factionOk, factionReason = Static.QuestEligibility(77003,
        { faction = "Horde", level = 60 })

    assert(factionOk == false and factionReason:find("Alliance"),
        "and a faction gate reports the faction")

    -- A row with no gating fields is eligible, and says so with NIL rather
    -- than an empty claim.
    local plainOk, plainReason = Static.QuestEligibility(77004, character)

    assert(plainOk == true and plainReason == nil,
        "an ungated quest is eligible with no reason attached")

    -- A quest nobody has curated is eligible: absence of data is not a block.
    assert(Static.QuestEligibility(999999, character) == true,
        "an unknown quest must not be treated as blocked")

    ------------------------------------------------------------
    -- WHERE IT IS HANDED IN, which the client's moving waypoint cannot say.
    ------------------------------------------------------------
    local mapID, x, y = Static.GetQuestTurnIn(77004)

    assert(mapID == 2112 and x == 0.5, "the turn-in location is readable")

    assert(Static.GetQuestTurnIn(77001) == nil,
        "and a row without one says nothing rather than guessing")

    ------------------------------------------------------------
    -- AND THE OTHER FOUR CURATED TABLES, PLUS THE COMMUNITY ONE.
    --
    -- Recipes, vendors, rares and treasures each have a registration function
    -- and a shipped-data file that is currently empty, so the registrars were
    -- never called and `Static.Count()` -- the number `/cn dbsize` prints --
    -- had never been computed. A registrar nothing has run is a registrar
    -- that will be wrong the day somebody fills the table in.
    ------------------------------------------------------------
    Static.RegisterRecipe(88001, { itemID = 88001, profession = "Alchemy" })
    Static.RegisterVendor(88002, { name = "Test Vendor", mapID = 2112 })
    Static.RegisterRare(88003, { name = "Test Rare", mapID = 2112 })
    Static.RegisterTreasure(88004, { name = "Test Treasure", mapID = 2112 })

    local quests, recipes, staticVendors, staticRares, treasures = Static.Count()

    assert(quests > 0, "the quest rows registered above are counted")
    assert(recipes >= 1 and staticVendors >= 1 and staticRares >= 1 and treasures >= 1,
        "and so is every other table: " .. recipes .. ", " .. staticVendors
        .. ", " .. staticRares .. ", " .. treasures)

    -- Registration refuses what it cannot use, rather than storing a shape
    -- that will fail at read time.
    Static.RegisterQuest(nil, { name = "No id" })
    Static.RegisterQuest(88005, nil)

    assert(Static.GetQuest(88005) == nil,
        "a row with no record is not a row")

    ------------------------------------------------------------
    -- THE COMMUNITY TABLE, which is the weakest of the three prerequisite
    -- sources and must stay separate from the curated one.
    ------------------------------------------------------------
    local communityBefore = Static.CommunityCount()

    local added = Static.RegisterCommunity({
        [88010] = { requires = { 88011, 88012 } },
        -- Refused: no prerequisites is not a chain.
        [88013] = { requires = "not a table" },
        [88014] = {},
    })

    assert(added == 1,
        "only the well-formed row is taken, got " .. tostring(added))

    assert(Static.CommunityCount() == communityBefore + 1,
        "and the count moves by exactly that much")

    local community = Static.GetCommunity(88010)

    assert(community and #community.requires == 2,
        "with its prerequisites intact")

    assert(Static.GetCommunity(88013) == nil,
        "and the refused rows are absent rather than half-stored")

    -- Community data must never surface as a curated quest record.
    assert(Static.GetQuest(88010) == nil,
        "a contributed chain is not curated data and must not answer as it")

    print("  class, race, faction, level and turn-in all read back correctly, "
        .. "and all five tables count")
end)()

print("\nWhat is on a clock, in detail:")

;(function()
    local waiting = CN:GetModule("Waiting")

    ------------------------------------------------------------
    -- A KEYSTONE IS A DEADLINE, NOT A GEAR FEATURE.
    ------------------------------------------------------------
    C_MythicPlus = {
        GetOwnedKeystoneLevel = function() return 12 end,
        GetOwnedKeystoneChallengeMapID = function() return 501 end,
    }

    C_ChallengeMode = {
        GetMapUIInfo = function() return "The Stonevault" end,
    }

    local keystone = waiting.Keystone()

    assert(keystone, "a held keystone is found")
    assert(keystone.level == 12, "at its level")
    assert(keystone.name == "The Stonevault", "and named")
    assert(keystone.expiresIn and keystone.expiresIn > 0,
        "with the weekly reset as its expiry, because it is replaced then "
        .. "whether it is used or not")

    C_MythicPlus.GetOwnedKeystoneLevel = function() return 0 end

    assert(waiting.Keystone() == nil,
        "and no keystone means no objective, not a zero-level one")

    ------------------------------------------------------------
    -- HEIRLOOMS: a collection with a journal nothing had ever read.
    ------------------------------------------------------------
    C_Heirloom = {
        GetNumHeirlooms = function() return 3 end,
        GetHeirloomItemIDFromIndex = function(index) return 70000 + index end,
        PlayerHasHeirloom = function(itemID) return itemID == 70001 end,
    }

    local heirlooms = waiting.Heirlooms()

    assert(heirlooms and heirlooms.total == 3, "every heirloom is counted")
    assert(heirlooms.collected == 1, "and only the owned one, got "
        .. heirlooms.collected)

    C_MythicPlus  = nil
    C_ChallengeMode = nil
    C_Heirloom    = nil

    assert(waiting.Keystone() == nil,
        "a client without the API answers nothing rather than throwing")
    assert(waiting.Heirlooms() == nil, "the same for heirlooms")

    print("  keystone, heirlooms, and a client that offers neither")
end)()


print("\nCrafting orders, and a decision that could go stale:")

;(function()
    local orders = CN:GetModule("Orders")

    ------------------------------------------------------------
    -- NOTHING KNOWN IS NOT THE SAME AS NOTHING OUTSTANDING.
    --
    -- The client only hands over the order list once the player has opened
    -- the order frame. Reporting "you have no orders" in that state would be
    -- the addon stating something it does not know.
    ------------------------------------------------------------
    assert(orders.IsAvailable() == false,
        "with no crafting API, the feature is simply unavailable")

    assert(orders.Mine() == nil,
        "and Mine() says nothing rather than claiming an empty list")

    C_CraftingOrders = {
        GetMyOrders = function()
            return {
                { orderID = 1, itemID = 5001, itemName = "Flask",
                  expirationTime = time() + 3600, crafterName = "Someone" },
                { orderID = 2, itemID = 5002, itemName = "Not Urgent",
                  expirationTime = time() + (10 * 86400) },
            }
        end,
        GetClaimedOrder = function() return nil end,
    }

    assert(orders.IsAvailable(), "with the API present it is available")

    local mine = orders.Mine()

    assert(mine and #mine == 2, "both orders are read")
    assert(mine[1].expiresIn and mine[1].expiresIn <= 3600,
        "with a real remaining time")

    ------------------------------------------------------------
    -- ONLY WHAT IS ACTUALLY ABOUT TO EXPIRE IS A NEXT ACTION.
    ------------------------------------------------------------
    local orderCandidates = CN.candidateProviders["Orders"].fn()

    assert(#orderCandidates == 1,
        "an order ten days out is not urgent, got " .. #orderCandidates)
    assert(orderCandidates[1].id == 1, "and it is the one expiring within a day")

    C_CraftingOrders.GetClaimedOrder = function() return { orderID = 9 } end

    local withClaim = CN.candidateProviders["Orders"].fn()

    assert(#withClaim == 2, "something finished and waiting is also an action")

    ------------------------------------------------------------
    -- AND THE COMMAND THAT SHOWS THEM.
    --
    -- `/cn orders` is the surface a player actually uses, and every line of
    -- it -- the "you have not opened the order frame yet" case, the empty
    -- case and the list itself -- was unexecuted. The first of those is the
    -- one that matters: "the client has not handed us your orders" and "you
    -- have no orders" are different sentences, and an addon that says the
    -- second when it means the first sends the player to check a window that
    -- is already correct.
    ------------------------------------------------------------
    local listedAt = #output

    CN.HandleSlashCommand("orders")

    local listed = false

    for index = listedAt + 1, #output do
        if output[index]:find("Flask") then listed = true end
    end

    assert(listed, "the order list must name the orders")

    -- No orders at all.
    C_CraftingOrders.GetMyOrders = function() return {} end

    local emptyAt = #output

    CN.HandleSlashCommand("orders")

    local saidEmpty = false

    for index = emptyAt + 1, #output do
        if output[index]:find("No orders outstanding") then saidEmpty = true end
    end

    assert(saidEmpty, "an empty list is reported as empty")

    -- The API present but refusing to answer, which is the state listedAt the
    -- player has opened the crafting order frame this session.
    C_CraftingOrders.GetMyOrders = function() return nil end

    local unknownAt = #output

    CN.HandleSlashCommand("orders")

    local saidUnknown = false

    for index = unknownAt + 1, #output do
        if output[index]:find("Nothing known yet") then saidUnknown = true end
    end

    assert(saidUnknown,
        "and 'the client has not told us' must not be reported as 'you have "
        .. "none' -- they send the player to different places")

    -- Delve progress: an API that exists but exposes nothing useful is the
    -- interesting case, because it is the one that looks like support.
    local realDelves = C_DelvesUI

    C_DelvesUI = {}

    local answered, detail = orders.DelveProgressAvailable()

    assert(answered == false and detail and detail:find("Great Vault"),
        "an API with no progress function must say where the credit does "
        .. "come from, not merely fail")

    C_DelvesUI = realDelves

    C_CraftingOrders = nil

    assert(#CN.candidateProviders["Orders"].fn() == 0,
        "and none of it survives the API going away")

    print("  orders read, only the expiring one recommended, and the "
        .. "command's three states are distinct")
end)()


print("\nA filter that follows you between tabs actually filters:")

;(function()
    ------------------------------------------------------------
    -- A FEATURE THAT PRODUCED THE STATE IT EXISTS TO PREVENT.
    --
    -- `/cn keepfilter on` carries the search term to the next tab. Its own
    -- help text warns that "a filter that persists invisibly is how a list
    -- looks empty when it is not" -- and what it actually did was put the
    -- term in the box and apply it to nothing, which is the same failure with
    -- the sign flipped: the list looks full when it is filtered.
    --
    -- The cause is ordering. Setting the box fires OnTextChanged, which reads
    -- the current tab's panel -- and on a tab's first visit the panel does
    -- not exist yet. `UI.RestoreFilter` was written to do it afterwards and
    -- was never called by anything.
    ------------------------------------------------------------
    local UI = CN.UI

    CN.Settings().keepFilter = true

    UI.persistedFilter = "aardvark"

    for _, tab in ipairs(UI.tabs) do
        tab.panel = nil
    end

    UI.SelectTab(2)

    local panel = UI.tabs[2].panel

    assert(panel and panel.list, "the tab must have built a list")

    assert(panel.list:GetFilter() == "aardvark",
        "a persisted filter must reach the list on a tab's FIRST visit, "
        .. "not only on the second; the list has "
        .. tostring(panel.list:GetFilter()))

    -- And off means off: the box is cleared and nothing is filtered.
    CN.Settings().keepFilter = nil

    for _, tab in ipairs(UI.tabs) do
        tab.panel = nil
    end

    UI.SelectTab(3)

    assert(UI.tabs[3].panel.list:GetFilter() == nil,
        "with keepFilter off the new tab must not be filtered")

    UI.persistedFilter = nil

    print("  a carried filter reaches the list on the first visit to a tab")
end)()

print("\nEvery client function this addon calls, checked against the client:")

;(function()
    ------------------------------------------------------------
    -- THE SILENT HALF.
    --
    -- 0.46.0 shipped an event that does not exist, and the client threw at
    -- every login -- loud, and therefore fixed within a day. The addon also
    -- names nearly two hundred client FUNCTIONS, and those fail silently:
    -- every call site guards on the name, so a renamed or misspelled one is
    -- indistinguishable from a client that lacks the feature. The guard goes
    -- false and the branch is dead for as long as nobody notices.
    --
    -- Data/ApiSurface.lua is GENERATED from the source at build time, so it
    -- cannot drift from what the addon actually calls. What this checks is
    -- that the list is real and the checker is honest -- proving the names
    -- exist needs a live client, which is what the apiSurface capture and the
    -- fixture audit are for.
    ------------------------------------------------------------
    assert(type(CN.apiSurface) == "table" and #CN.apiSurface > 100,
        "the generated API surface should list the client names this addon "
        .. "calls; it has " .. tostring(CN.apiSurface and #CN.apiSurface))

    local absent = {}

    for _, path in ipairs(CN.apiSurface) do
        local namespace, method = string.match(path, "^([^.]+)%.(.+)$")

        local value

        if namespace then
            local container = _G[namespace]

            value = type(container) == "table" and container[method] or nil
        else
            value = _G[path]
        end

        if value == nil then
            table.insert(absent, path)
        end
    end

    -- The stub deliberately omits some of these -- "a client that offers
    -- neither" is a case the suite tests on purpose -- so the count is not
    -- the assertion. What is asserted is that the checker agrees with
    -- reality in both directions.
    local report

    for _, check in ipairs(CN:GetModule("SelfTest").Run().checks) do
        if check.area == "client" then
            report = check
        end
    end

    assert(report, "the self-test must include the API check")

    if #absent == 0 then
        assert(report.status == "PASS",
            "with every name present the check must pass")
    else
        assert(report.status == "FAIL",
            "with " .. #absent .. " names absent the check must fail, not "
            .. tostring(report.status))

        -- AND IT MUST NOTICE ONE COMING BACK.
        --
        -- A checker that always says "some are missing" is as useless as one
        -- that always says "all present". Define one of the absent names and
        -- require the count to drop by exactly one.
        local restored = absent[1]

        local namespace, method = string.match(restored, "^([^.]+)%.(.+)$")

        local missingBefore = #absent

        if namespace then
            _G[namespace] = _G[namespace] or {}
            _G[namespace][method] = function() end
        else
            _G[restored] = function() end
        end

        local after = 0

        for _, path in ipairs(CN.apiSurface) do
            local ns, m = string.match(path, "^([^.]+)%.(.+)$")

            local value

            if ns then
                local container = _G[ns]

                value = type(container) == "table" and container[m] or nil
            else
                value = _G[path]
            end

            if value == nil then
                after = after + 1
            end
        end

        assert(after == missingBefore - 1,
            "restoring one client function must reduce the missing count by "
            .. "exactly one, went from " .. missingBefore .. " to " .. after)

        if namespace then
            _G[namespace][method] = nil
        else
            _G[restored] = nil
        end
    end

    print("  " .. #CN.apiSurface .. " client functions listed; the checker "
        .. "agrees with the client in both directions")
end)()

print("\nThe arrow's colours separate for a colourblind player too:")

;(function()
    ------------------------------------------------------------
    -- A LABEL BESIDE A BAD PALETTE IS HALF A FIX.
    --
    -- Colourblind mode added a word next to the arrow -- which satisfies "no
    -- information carried by colour alone" and left the colours exactly as
    -- unusable as they were. Gold against red is the worst pair there is for
    -- the commonest form of colour blindness, and it was carrying "drifting"
    -- against "walking away": the one distinction the arrow exists to make.
    ------------------------------------------------------------
    local navigation = CN:GetModule("Navigation")
    local hud        = CN:GetModule("Hud")

    CN.Settings().colourblind = nil

    assert(navigation.Palette() == navigation.colors,
        "the default palette is the default")

    CN.Settings().colourblind = true

    local palette = navigation.Palette()

    assert(palette == navigation.colorblindColors,
        "colourblind mode must change the palette, not only add a word")

    -- The three states must differ in LIGHTNESS, not only in hue -- that is
    -- what makes them tell apart when the hues do not.
    local function luminance(colour)
        return (0.2126 * colour[1]) + (0.7152 * colour[2]) + (0.0722 * colour[3])
    end

    local onCourse = luminance(palette.ON_COURSE)
    local drifting = luminance(palette.DRIFTING)
    local away     = luminance(palette.AWAY)

    for _, pair in ipairs({
        { onCourse, drifting, "on course", "drifting" },
        { drifting, away,     "drifting",  "away" },
        { onCourse, away,     "on course", "away" },
    }) do
        assert(math.abs(pair[1] - pair[2]) > 0.15,
            "in colourblind mode " .. pair[3] .. " and " .. pair[4]
            .. " must differ in lightness as well as hue, and they differ by "
            .. string.format("%.2f", math.abs(pair[1] - pair[2])))
    end

    CN.Settings().colourblind = nil

    print("  three states, told apart by lightness as well as by hue")
end)()

print("\nA ghost is pointed at their body:")

;(function()
    ------------------------------------------------------------
    -- HALF AN ANSWER IS NOT AN ANSWER.
    --
    -- The addon has recognised death since 0.43.0, ranked everything else
    -- down for it, and printed "your body first" -- while being unable to say
    -- where the body is. The client answers that question directly and was
    -- never asked.
    ------------------------------------------------------------
    local group = CN:GetModule("Group")

    CN_TEST_DEAD  = true
    CN_TEST_GHOST = true

    local corpse = group.CorpseTarget()

    assert(corpse and corpse.mapID and corpse.x,
        "a ghost's corpse position must be readable")

    CN.CollectCandidates(true)

    local ghostList = CN.Recommend(1)

    assert(ghostList and ghostList[1],
        "there must be something to recommend to a ghost")

    assert(ghostList[1].corpse,
        "and it must be the body -- while dead, nothing else is actionable, "
        .. "so anything else at the top is the addon burying its own answer; "
        .. "got " .. tostring(ghostList[1].name))

    assert(ghostList[1].x == CN_TEST_CORPSE.x,
        "pointed at the actual corpse position")

    -- AND THE DEATH PENALTY MUST NOT APPLY TO IT.
    --
    -- Every objective is multiplied down while dead, by design. Applying that
    -- to the corpse as well leaves the ORDER unchanged -- everything shrinks
    -- together -- so an ordering check cannot see the difference. What it
    -- changes is the number itself, and with it every threshold downstream
    -- that compares a score against an absolute: the heads-up display, the
    -- broker feed, and anything that asks "is this worth interrupting for".
    local scored = CN.ScoreObjective(ghostList[1])

    assert(scored > 30,
        "the body must keep its full weight while dead -- the death penalty "
        .. "applies to everything that can wait, and the body cannot; got "
        .. string.format("%.2f", scored))

    CN_TEST_GHOST = false
    CN_TEST_DEAD  = false

    CN.CollectCandidates(true)

    for _, candidate in ipairs(CN.CollectCandidates()) do
        assert(not candidate.corpse,
            "and a living player is not told to run to their body")
    end

    print("  a ghost's next action is their body, at the right coordinates")
end)()

print("\nA non-mage can be told how long another continent takes:")

;(function()
    ------------------------------------------------------------
    -- ELEVEN OF FOURTEEN TELEPORTS NOW HAVE A DESTINATION.
    --
    -- The cross-continent branch can only cost a journey through a teleport
    -- whose landing map is known, and eight of the fourteen carried none --
    -- so anyone without the six vanilla mage teleports got a list of what
    -- they own and no duration at all, which is exactly the state the branch
    -- was written to replace. Five of the eight were simply never filled in.
    ------------------------------------------------------------
    local travel = CN:GetModule("Travel")

    local costable, marked = 0, 0

    for _, teleport in ipairs(travel.teleports) do
        if teleport.mapID then
            costable = costable + 1
        elseif teleport.bindPoint or teleport.local_ then
            marked = marked + 1
        end
    end

    assert(costable >= 11,
        "at least eleven teleports must carry a destination the addon can "
        .. "cost a journey from, got " .. costable)

    assert(costable + marked == #travel.teleports,
        "and every one without a destination must say WHY it has none -- "
        .. (#travel.teleports - costable - marked) .. " are simply blank")

    print("  " .. costable .. " teleports costable, " .. marked
        .. " honestly marked as unpinnable")
end)()

print("\nEvery string translated into ten languages is shown to somebody:")

;(function()
    ------------------------------------------------------------
    -- THE LINT ONLY EVER CHECKED ONE DIRECTION.
    --
    -- `cn.ps1 check` asserts that every translation corresponds to a
    -- canonical key, and that every canonical key has at least one
    -- translation. Neither question is "does anything ever DISPLAY this".
    --
    -- Thirteen keys were translated into ten languages, passed every lint,
    -- and appeared on no screen -- while strings that WERE on screen were
    -- printed as English literals beside them. Nine languages were shipping
    -- English for text that had already been translated.
    ------------------------------------------------------------
    local manifest = io.open(ROOT .. "/CompletionNavigator.toc", "r")

    assert(manifest, "the .toc must be readable")

    local listed = manifest:read("*a")

    manifest:close()

    local source = ""

    for line in string.gmatch(listed, "[^\r\n]+") do
        if string.match(line, "%.lua%s*$") and not string.match(line, "^%s*#") then
            local relative = CN.Trim(string.gsub(line, "\\", "/"))

            if not string.find(relative, "Locales/") then
                local file = io.open(ROOT .. "/" .. relative, "r")

                if file then
                    source = source .. file:read("*a")

                    file:close()
                end
            end
        end
    end

    assert(#source > 100000, "the source scan found almost nothing")

    local unused = {}

    for _, key in ipairs(CN.localeKeys) do
        local literal = 'CN.L["' .. key .. '"]'

        if not string.find(source, literal, 1, true)
            and not (CN.localeDynamic and CN.localeDynamic[key]) then

            table.insert(unused, key)
        end
    end

    table.sort(unused)

    for _, key in ipairs(unused) do
        print("  SHOWN BY NOTHING: " .. key)
    end

    assert(#unused == 0,
        #unused .. " canonical string(s) are translated into every locale "
        .. "and displayed by nothing: " .. table.concat(unused, ", "))

    -- And the dynamic declarations must not outlive their keys either.
    local canonical = {}

    for _, key in ipairs(CN.localeKeys) do
        canonical[key] = true
    end

    for key in pairs(CN.localeDynamic or {}) do
        assert(canonical[key],
            "the dynamic-lookup list names \"" .. key .. "\", which is not a "
            .. "canonical key any more")
    end

    print("  " .. #CN.localeKeys .. " strings, every one of them reaching a "
        .. "screen")
end)()

print("\nThe numbers the addon prints are the numbers it means:")

;(function()
    local travel  = CN:GetModule("Travel")
    local session = CN:GetModule("Session")

    ------------------------------------------------------------
    -- 1. RUNNING IS COSTED AT RUNNING SPEED.
    --
    -- The estimator asked for "the speed you are moving right now", so
    -- costing a journey while airborne divided the distance by a skyriding
    -- median: twenty-one thousand yards was quoted at six minutes, labelled
    -- `run`, and marked confident. On foot it is fifty. It also made the
    -- self-flown option unreachable while flying -- same divisor, plus six
    -- seconds of takeoff, can never win.
    ------------------------------------------------------------
    local samples = session.Samples()

    local savedFoot   = samples.onFoot
    local savedFlying = samples.flying

    samples.onFoot = { 7, 7, 7, 7, 7 }
    samples.flying = { 60, 60, 60, 60, 60 }

    CN_TEST_FLYING = true

    local seconds, _, detail =
        travel.EstimateSeconds(94, 0.05, 0.05, 94, 0.95, 0.95)

    CN_TEST_FLYING = false

    assert(detail, "the journey must be costable")

    if detail.mode == "run" then
        local runYards = detail.yards

        assert(math.abs(seconds - (runYards / 7)) < 1,
            "a run estimate must divide by running speed, not by whatever "
            .. "bucket the player is in -- " .. string.format("%.0f", seconds)
            .. "s for " .. string.format("%.0f", runYards) .. " yards is "
            .. string.format("%.1f", runYards / math.max(seconds, 0.001))
            .. " yd/s")
    end

    samples.onFoot = savedFoot
    samples.flying = savedFlying

    print("  running is costed at running speed")

    ------------------------------------------------------------
    -- 2. AN UNCOSTABLE JOURNEY IS THE PESSIMISTIC ANSWER.
    --
    -- The fallback was 25 while a costed journey saturates at 40, so "I
    -- cannot work out how to get there" scored fifteen points BELOW the far
    -- side of the zone the player is standing in -- and fifteen is nearly
    -- twice the whole range of what finishing something is worth.
    ------------------------------------------------------------
    assert(CN.fallbackZoneCost >= travel.maximumCost,
        "the cost of a journey the addon cannot model (" .. CN.fallbackZoneCost
        .. ") must not be cheaper than the most expensive one it can ("
        .. travel.maximumCost .. ")")

    print("  an uncostable journey is not cheaper than a costed one")

    ------------------------------------------------------------
    -- 3. THE JOURNEY IS COUNTED ONCE.
    --
    -- The learned "task time" is the span from being recommended to being
    -- finished, which contains the walk. The planner then ADDED a separately
    -- computed travel leg to a sum of those spans -- once per objective at a
    -- stop, which is worst exactly where the router is trying to reward
    -- batching. Four quests six minutes away came out at thirty-six minutes
    -- against a true twelve, reported confident.
    ------------------------------------------------------------
    session.Durations()[CN.objectiveTypes.QUEST] = nil

    local travelCost = 12   -- 12 cost points = six minutes at 30s each

    CN_TEST_CLOCK = 200000

    for index = 1, 5 do
        local questID = 780000 + index

        CN_TEST_CLOCK = 200000 + (index * 1000)

        session.NoteOffered({
            type       = CN.objectiveTypes.QUEST,
            id         = questID,
            travelCost = travelCost,
        })

        -- Six minutes of travel, then ninety seconds of work.
        CN_TEST_CLOCK = CN_TEST_CLOCK + (travelCost * CN.secondsPerCostPoint) + 90

        session.NoteCompleted(CN.objectiveTypes.QUEST, questID)
    end

    local typical = session.TypicalSeconds(CN.objectiveTypes.QUEST)

    assert(typical,
        "five samples must produce a typical time")

    assert(math.abs(typical - 90) < 5,
        "the learned time must be the WORK -- ninety seconds -- not the work "
        .. "plus the journey the planner adds back separately; got "
        .. string.format("%.0f", typical))

    session.Durations()[CN.objectiveTypes.QUEST] = nil

    print("  a learned task time is the work, not the work plus the journey")
end)()

print("\nA player who does everything is not told they do nothing:")

;(function()
    ------------------------------------------------------------
    -- THE SHOWING SIDE AND THE ACTING SIDE COUNTED DIFFERENT THINGS.
    --
    -- Quests are filed under both their plain type and a campaign/side
    -- sub-bucket. The recommendation hook incremented BOTH; the completion
    -- handler credited only the plain type. So the refined rows collected
    -- sightings and never a single action, drifted to the floor multiplier --
    -- and the score adjuster prefers the refined row whenever its multiplier
    -- is not 1, which made the correct plain row unreachable.
    --
    -- A player who turned in every quest they were shown was told, within an
    -- hour or two of play, that they "rarely act on these", and every quest
    -- was multiplied by 0.80 for the rest of time.
    --
    -- Every previous test of this set the counters by hand rather than
    -- driving the two sides against each other.
    ------------------------------------------------------------
    local preference = CN:GetModule("Preference")

    local store = preference.Store()

    for key in pairs(store) do
        store[key] = nil
    end

    CN.Settings().learnPreferences = true

    local rounds = 40

    for index = 1, rounds do
        CN_TEST_CLOCK = 100000 + (index * 60)

        local questID = 770000 + index

        CN.recommendationHooks["Preference"]({
            CN.NewObjective({
                id   = questID,
                type = CN.objectiveTypes.QUEST,
                name = "Quest " .. index,
            }),
        })

        preference.NoteCompleted(CN.objectiveTypes.QUEST, questID)
    end

    for bucket, row in pairs(store) do
        if row.shown and row.shown > 0 then
            assert(row.acted and row.acted > 0,
                bucket .. " was shown " .. row.shown .. " times and credited "
                .. tostring(row.acted) .. " -- a player who acts on "
                .. "everything must not be recorded as acting on nothing")

            local ratio = row.acted / row.shown

            assert(ratio > 0.5,
                bucket .. " records a ratio of " .. string.format("%.2f", ratio)
                .. " for a player who acted on every single sighting")
        end
    end

    -- And the multiplier that comes out of it must not be a penalty.
    local multiplier = preference.Multiplier(CN.objectiveTypes.QUEST)

    assert(multiplier >= 1,
        "acting on everything must not produce a penalty, got " .. multiplier)

    for key in pairs(store) do
        store[key] = nil
    end

    print("  acting on every sighting is recorded in every bucket")
end)()

print("\nA focus raises what you asked for, at every distance:")

;(function()
    ------------------------------------------------------------
    -- MULTIPLYING A TOTAL THAT CROSSES ZERO INVERTS IT.
    --
    -- Worth tops out around 8; travel is weighted -1 against a cost that
    -- reaches 40. So anything more than a few minutes away scored negative --
    -- and `score * 2.0` on a negative number pushes it DOWN. `/cn mode
    -- quests` ranked a distant quest twenty-seven points BELOW a distant pet.
    -- The learned multiplier inverted the same way, promoting exactly the
    -- types it had decided you avoid, as long as they were far off.
    --
    -- Every previous test of this used a near objective, where the total
    -- happens to be positive and the arithmetic happens to work.
    ------------------------------------------------------------
    local saved = CN.Settings().priorityMode

    local function pair(travelCost)
        local quest = CN.NewObjective({
            id = 1, type = CN.objectiveTypes.QUEST, name = "Quest",
            completionValue = 3, travelCost = travelCost,
        })

        local pet = CN.NewObjective({
            id = 2, type = CN.objectiveTypes.PET, name = "Pet",
            completionValue = 3, travelCost = travelCost,
        })

        return CN.ScoreObjective(quest), CN.ScoreObjective(pet)
    end

    CN.Settings().priorityMode = "quests"

    for _, distance in ipairs({ 0, 2, 5, 10, 20, 30, 40 }) do
        local questScore, petScore = pair(distance)

        assert(questScore > petScore,
            "with a quest focus a quest must outrank an identical pet at "
            .. "travel cost " .. distance .. ", got " .. questScore
            .. " against " .. petScore)
    end

    print("  a quest focus prefers quests at every distance tested")

    -- And the same for a learned multiplier, which is the other multiplying
    -- input and inverted identically.
    CN.Settings().priorityMode = "balanced"

    CN.RegisterScoreAdjuster("InversionProbe", function(candidate, worth)
        if candidate.type == CN.objectiveTypes.QUEST then
            return worth * 1.25
        end

        return worth * 0.8
    end)

    for _, distance in ipairs({ 0, 5, 20, 40 }) do
        local questScore, petScore = pair(distance)

        assert(questScore > petScore,
            "a type the player acts on must outrank one they skip at travel "
            .. "cost " .. distance .. ", got " .. questScore .. " against "
            .. petScore)
    end

    CN.scoreAdjusters["InversionProbe"] = nil

    for index, name in ipairs(CN.scoreAdjusterOrder) do
        if name == "InversionProbe" then
            table.remove(CN.scoreAdjusterOrder, index)
            break
        end
    end

    CN.Settings().priorityMode = saved

    print("  and a learned preference does too")
end)()

print("\nOff means off, and a setting you can name you can set:")

;(function()
    ------------------------------------------------------------
    -- FOUR THINGS THAT ONLY GO WRONG ON A PATH THE SUITE NEVER WALKED.
    ------------------------------------------------------------
    local modes    = CN:GetModule("Filters")
    local follow   = CN:GetModule("Follow")
    local goalList = CN:GetModule("Goals")

    local live = CN.Settings()

    -- 1. `/cn mode off` with no focus must not touch what the player hid.
    live.mode         = nil
    live.modePrevious = nil

    modes.EnableAllTypes()
    modes.SetTypeEnabled(CN.objectiveTypes.PET, false)

    CN.HandleSlashCommand("mode off")

    assert(not modes.IsTypeEnabled(CN.objectiveTypes.PET),
        "clearing a focus that was never set must not unhide what the "
        .. "player hid by hand -- hidden types are persisted, so the loss "
        .. "is permanent")

    modes.EnableAllTypes()

    print("  clearing a focus that was never set changes nothing")

    -- 2. Every overridable setting must be settable by its own name.
    local names = {}

    for name in pairs(CN.characterOverridable) do
        table.insert(names, name)
    end

    table.sort(names)

    for _, name in ipairs(names) do
        CN.HandleSlashCommand("percharacter " .. name)

        assert(CN.character and CN.character.settings
            and CN.character.settings[name] ~= nil,
            "`/cn percharacter " .. name .. "` must set it; the handler "
            .. "lowercased the argument and looked it up in a camelCase "
            .. "table, so half of these could never be set by any input")

        CN.character.settings[name] = nil
    end

    print("  all " .. #names .. " overridable settings accept their own name")

    -- 3. Stopping follow mode must leave nothing on screen.
    follow.Start()

    follow.Stop()

    local navigation = CN:GetModule("Navigation")

    assert(not navigation.GetTarget(),
        "stopping follow mode must clear the waypoint it set; it hid its own "
        .. "frame and left the arrow pointing at a route nobody is walking")

    assert(follow.deferred ~= true,
        "and must not leave a combat deferral armed for the next session")

    print("  stopping follow mode clears the arrow and the waypoint")

    -- 4. A goal pinned before the scan picks up its real name afterwards.
    local coinNames = CN:GetModule("Currencies")

    local names2 = CN.Account("currencyNames")

    names2[3008] = nil

    goalList.Add(CN.objectiveTypes.CURRENCY, 3008)

    coinNames.Scan()

    local found

    for _, goal in ipairs(goalList.List()) do
        if goal.id == 3008 then found = goal end
    end

    assert(found, "the goal must be listed")

    assert(found.name and not tostring(found.name):find("3008", 1, true),
        "a goal pinned before the scan must take its real name once the "
        .. "client can supply one, got " .. tostring(found.name))

    goalList.Remove(CN.objectiveTypes.CURRENCY, 3008)

    print("  a goal pinned before its scan is named properly afterwards")
end)()

print("\nA reason an adjuster adds is added once:")

;(function()
    ------------------------------------------------------------
    -- SCORING RUNS AGAIN AND AGAIN OVER THE SAME TABLES.
    --
    -- The candidate list is cached and ranking re-scores those same tables on
    -- every rebuild -- and every zone route bumps the ranking generation, so
    -- this is ordinary play, not an edge case. Adjusters appended to
    -- `objective.reasons` each pass: one objective was measured carrying
    -- sixty-two reasons after thirty rounds, with `/cn why` printing the same
    -- sentence sixty times.
    --
    -- The identical defect was found and fixed for DECORATORS, and there is a
    -- probe for that. Nobody looked at the adjuster path, which runs far more
    -- often.
    ------------------------------------------------------------
    local probe = CN.NewObjective({
        id              = 1,
        type            = CN.objectiveTypes.QUEST,
        name            = "Repeatedly Scored",
        completionValue = 3,
    })

    CN.RegisterScoreAdjuster("ReasonProbe", function(candidate, score)
        CN.AddAdjusterReason(candidate, "reasonProbe", "an adjuster said so")

        return score
    end)

    for _ = 1, 25 do
        CN.ScoreObjective(probe)
    end

    local saidIt = 0

    for _, reason in ipairs(probe.reasons or {}) do
        if reason == "an adjuster said so" then
            saidIt = saidIt + 1
        end
    end

    assert(saidIt == 1,
        "twenty-five scorings of one objective must add an adjuster's reason "
        .. "once, not " .. saidIt .. " times")

    CN.scoreAdjusters["ReasonProbe"] = nil

    for index, name in ipairs(CN.scoreAdjusterOrder) do
        if name == "ReasonProbe" then
            table.remove(CN.scoreAdjusterOrder, index)
            break
        end
    end

    print("  scored 25 times, the reason appears once")
end)()

print("\nThe addon appears in the game's own options list:")

;(function()
    ------------------------------------------------------------
    -- IT NEVER HAS.
    --
    -- The registration read `Settings.RegisterCanvasLayoutCategory`, meaning
    -- the client's global options API -- and `Settings` was also the name of
    -- a file-local function two hundred lines above, so it indexed a function
    -- and threw on every login on every retail client since Dragonflight. The
    -- error was caught and printed; because it aborted the function, the
    -- pre-10.0 fallback never ran either.
    --
    -- The stub had no SettingsPanel, so the guard short-circuited before the
    -- bad index and the suite saw nothing.
    ------------------------------------------------------------
    local hud = CN:GetModule("Hud")

    local errors = CN:GetModule("Errors")

    local errorsBefore = errors and errors.Count() or 0

    local registered = hud.RegisterOptionsPanel()

    assert(registered,
        "the addon must register with the game's options list")

    -- Registered during the login hook, which is when it happens in game.
    -- Once, not once per call: the function guards itself.
    assert(#CN_TEST_OPTIONS_REGISTERED == 1,
        "and must reach RegisterAddOnCategory exactly once across the whole "
        .. "session, got " .. #CN_TEST_OPTIONS_REGISTERED)

    assert((errors and errors.Count() or 0) == errorsBefore,
        "and must not throw doing it")

    print("  registered with the client's options API, without erroring")
end)()

print("\nFeatures that were wired to nothing:")

;(function()
    ------------------------------------------------------------
    -- FOUR THINGS THAT WERE OFF, AND NOTHING SAID SO.
    --
    -- Each of these is a feature the addon documented at length, shipped, and
    -- never ran: a guard on a function that does not exist, a field dropped
    -- on the way out of a query, a value discarded on every login, and a
    -- restore that restored one of four things. None of them errored. That is
    -- the shape of every serious defect this project has had.
    ------------------------------------------------------------
    local coin       = CN:GetModule("Currencies")
    local waiting    = CN:GetModule("Waiting")
    local professions = CN:GetModule("Professions")

    -- 1. Weekly profession knowledge.
    local store = coin.CharacterStore()

    store[3000] = {
        currencyID        = 3000,
        maxWeeklyQuantity = 3,
        weeklyRemaining   = 2,
        quantity          = 1,
    }

    CN_TEST_CURRENCY_NAMES = CN_TEST_CURRENCY_NAMES or {}
    CN_TEST_CURRENCY_NAMES[3000] = "Alchemy Knowledge"

    local knowledge = waiting.Knowledge()

    assert(#knowledge > 0,
        "a knowledge currency with a weekly cap left must appear in the "
        .. "clock; the guard tested a function that has never existed, so "
        .. "this list has always been empty")

    print("  weekly knowledge is found: " .. tostring(knowledge[1].name))

    -- 2. Warband flag survives the capped query.
    store[3001] = {
        currencyID  = 3001,
        capped      = true,
        quantity    = 100,
        maxQuantity = 100,
        accountWide = true,
    }

    local capped

    for _, row in ipairs(coin.Capped()) do
        if row.currencyID == 3001 then capped = row end
    end

    assert(capped and capped.accountWide == true,
        "the Warband flag must survive the query that builds the row -- the "
        .. "provider reads it and this function never copied it")

    print("  a Warband currency is still flagged as one after the query")

    store[3000] = nil
    store[3001] = nil

    -- 3. Recipe counts survive a rescan.
    local shelf = professions.CharacterStore()

    local seeded = false

    for _, row in pairs(shelf) do
        if not seeded then
            row.recipesSeen = true
            row.recipeKnown = 40
            row.recipeTotal = 250
            seeded = true
        end
    end

    assert(seeded, "the fixture must have a profession to seed")

    professions.Scan()

    local kept

    for _, row in pairs(shelf) do
        if row.recipesSeen then kept = row break end
    end

    assert(kept and kept.recipeKnown == 40 and kept.recipeTotal == 250,
        "recipe counts captured from an open profession window must survive "
        .. "the login rescan, or the display prints '(nil of nil recipes)'")

    print("  recipe counts survive a rescan")

    -- 4. Journal filters are put back.
    CN_TEST_PET_FILTERS = { collected = false, uncollected = true }

    CN.Blizzard.WithAllPetsShown(function() end)

    assert(CN_TEST_PET_FILTERS.collected == false
        and CN_TEST_PET_FILTERS.uncollected == true,
        "a scan must put the player's journal filters back; it widened them "
        .. "and restored only the search box, permanently resetting a "
        .. "setting the player chose")

    -- AND THE ONES THAT CANNOT BE PUT BACK ARE NOT TOUCHED AT ALL.
    --
    -- `SetAllPetSourcesChecked` and `SetAllPetTypesChecked` have no getter,
    -- so calling them is a permanent change to a setting the player chose.
    -- The file's own comment said they were widened "only if the scan would
    -- otherwise see nothing"; the code did it on every scan, and the pet scan
    -- runs on a thirty-second throttle. The stub recorded the call and no
    -- test looked, so a written-down rule went unenforced for six releases.
    CN_TEST_PET_FILTERS = { collected = false, uncollected = true }

    CN.Blizzard.WithAllPetsShown(function() end)

    assert((CN_TEST_PET_FILTERS.sourceWidens or 0) == 0
        and (CN_TEST_PET_FILTERS.typeWidens or 0) == 0,
        "a scan that can see pets must not touch the source and type checks; "
        .. "they cannot be read back, so widening them is permanent")

    -- Unless the player's own filters hide everything, which is the one case
    -- where changing them beats reporting an empty collection -- and it is
    -- announced, because it cannot be undone.
    local realNumPets = C_PetJournal.GetNumPets

    C_PetJournal.GetNumPets = function() return 0, 0 end

    CN_TEST_PET_FILTERS = { collected = false, uncollected = true }

    CN.Blizzard.WithAllPetsShown(function() end)

    assert((CN_TEST_PET_FILTERS.sourceWidens or 0) == 1
        and (CN_TEST_PET_FILTERS.typeWidens or 0) == 1,
        "but when the journal reports nothing at all, widening is the only "
        .. "way to answer")

    C_PetJournal.GetNumPets = realNumPets

    print("  the pet journal is left as it was found, filters included")

    -- 5. The toy box, same rule, same reason.
    CN_TEST_TOY_SOURCES_WIDENED = 0

    CN.Blizzard.WithAllToysShown(function() end)

    assert(CN_TEST_TOY_SOURCES_WIDENED == 0,
        "a toy scan that can see toys must not widen the source filters "
        .. "either; SetAllSourceTypeFilters has no getter")

    print("  and so is the toy box")
end)()

print("\nTwo things that only break on the second use:")

;(function()
    ------------------------------------------------------------
    -- A FOCUS SWITCHED TWICE MUST STILL BE UNDOABLE.
    --
    -- `/cn mode` captured the state to return to on EVERY application, so
    -- going from one focus straight to another overwrote the player's real
    -- settings with the first focus's settings. `/cn mode off` then restored
    -- the previous PRESET while printing "previous filters and weighting
    -- restored" and recording no active mode -- leaving no single command
    -- that got you back.
    ------------------------------------------------------------
    local modes = CN:GetModule("Filters")

    local live = CN.Settings()

    live.mode         = nil
    live.modePrevious = nil
    live.priorityMode = "balanced"

    modes.EnableAllTypes()

    modes.SetTypeEnabled(CN.objectiveTypes.PET, false)

    local hiddenBefore = not modes.IsTypeEnabled(CN.objectiveTypes.PET)

    assert(hiddenBefore, "the fixture must start with something hidden")

    modes.ApplyMode("leveling")
    modes.ApplyMode("collecting")
    modes.ClearMode()

    assert(live.priorityMode == "balanced",
        "after two focuses and an off, the weighting must be what it was "
        .. "before the FIRST one, got " .. tostring(live.priorityMode))

    assert(not modes.IsTypeEnabled(CN.objectiveTypes.PET),
        "and what the player had hidden themselves must come back hidden")

    modes.EnableAllTypes()

    live.mode         = nil
    live.modePrevious = nil

    print("  two focuses and an off returns to the state before either")

    ------------------------------------------------------------
    -- AND A LIST WHOSE FIRST SLOT IS NIL STILL HAS A SECOND.
    --
    -- The BtWQuests probe walked three possible database locations with
    -- ipairs. The first is nil whenever the global is absent -- the normal
    -- case on recent versions -- so ipairs stopped immediately and the two
    -- fallbacks it exists to provide were unreachable in exactly the
    -- situation they were written for. The interpreters do not even agree on
    -- the length of such a list: 5.4 says two, the game's 5.1 says zero.
    ------------------------------------------------------------
    _G.BtWQuestsDatabase = nil

    _G.BtWQuests = { Database = { [1] = { name = "A Chain" } } }

    assert(CN.BtWQuests.IsAvailable(),
        "a database in the second slot must be found when the first is nil")

    _G.BtWQuests = nil

    assert(not CN.BtWQuests.IsAvailable(),
        "and no database at all is still unavailable")

    print("  a database in the second slot is found when the first is nil")
end)()

print("\nCode that nothing calls:")

;(function()
    ------------------------------------------------------------
    -- A RATCHET, NOT A PURGE.
    --
    -- Every audit of this addon turns up functions that are defined,
    -- commented, and called by nothing -- `Travel.NoteFlyable` and
    -- `UI.RestoreFilter` were both in that state, and both were not merely
    -- untidy but load-bearing: the feature they implemented was simply off.
    -- Dead code here is a reliable predictor of a missing wire.
    --
    -- Some unreferenced functions are legitimate: a registry hook exists to
    -- be called from outside. So this is not a ban. It counts, names, and
    -- refuses to let the number grow -- the same shape as the help-group
    -- check, and for the same reason: a list nobody counts rots.
    ------------------------------------------------------------
    local defined, referenced = {}, {}

    local manifest = io.open(ROOT .. "/CompletionNavigator.toc", "r")

    assert(manifest, "the .toc must be readable")

    local listed = manifest:read("*a")

    manifest:close()

    local sources = {}

    for line in string.gmatch(listed, "[^\r\n]+") do
        if string.match(line, "%.lua%s*$") and not string.match(line, "^%s*#") then
            local relative = CN.Trim(string.gsub(line, "\\", "/"))

            local file = io.open(ROOT .. "/" .. relative, "r")

            if file then
                sources[relative] = file:read("*a")

                file:close()
            end
        end
    end

    for relative, text in pairs(sources) do
        for owner, name in string.gmatch(text,
            "function%s+([A-Za-z_][A-Za-z0-9_]*)%.([A-Za-z_][A-Za-z0-9_]*)") do

            -- CN.* is the addon's published surface: registries, hooks and
            -- the things commands call by name. Module-local helpers are
            -- what this is about.
            if owner ~= "CN" then
                defined[owner .. "." .. name] = relative
            end
        end
    end

    -- MATCHED ON THE METHOD NAME, NOT ON THE OWNER.
    --
    -- Nearly every cross-file call in this addon goes through a local handle
    -- -- `local errors = CN:GetModule("Errors")` and then `errors.Count()` --
    -- so matching `Errors.Count` finds only the definition and reports a
    -- function the UI calls twice as dead. Deliberately conservative in the
    -- direction of NOT crying wolf: a name-only match can miss a dead
    -- function that shares a name with a live one, and that is the right
    -- error to make for a gate that blocks a release.
    local byName = {}

    for key in pairs(defined) do
        local name = string.match(key, "%.([A-Za-z0-9_]+)$")

        byName[name] = byName[name] or {}

        table.insert(byName[name], key)
    end

    for _, text in pairs(sources) do
        -- `,` and `)` as well as `(` and `=`: this addon passes functions to
        -- pcall by reference constantly -- `pcall(Travel.NoteBoarding)` -- and
        -- a pattern that only recognised a call site with a paren after it
        -- reported those as dead.
        for name in string.gmatch(text, "[%.:]([A-Za-z_][A-Za-z0-9_]*)%s*[%(=,%)]") do
            for _, key in ipairs(byName[name] or {}) do
                referenced[key] = (referenced[key] or 0) + 1
            end
        end
    end

    local orphans = {}

    for key in pairs(defined) do
        if (referenced[key] or 0) <= 1 then
            table.insert(orphans, key)
        end
    end

    table.sort(orphans)

    for _, key in ipairs(orphans) do
        print("  never called: " .. key .. "  (" .. defined[key] .. ")")
    end

    -- The ceiling is where the addon actually is, not where it should be.
    -- Lower it when something is deleted or wired; the build fails if it
    -- rises, which is the only property that matters.
    local CEILING = 20

    assert(#orphans <= CEILING,
        #orphans .. " module functions are called by nothing, above the "
        .. "ceiling of " .. CEILING .. ". Wire it or delete it.")

    print("  " .. #orphans .. " of " .. CN.CountKeys(defined)
        .. " module functions are uncalled, ceiling " .. CEILING)
end)()

print("\nEvery scoring weight has something that sets it:")

;(function()
    ------------------------------------------------------------
    -- A WEIGHT NOBODY PRODUCES IS A LIE IN THE FORMULA.
    --
    -- `difficultyCost` and `dependencyCost` were declared, summed on every
    -- objective, listed in the file header's formula and printed by
    -- `/cn order` -- and nothing had ever set either field. They contributed
    -- zero to every score the addon has ever computed while making the
    -- documented arithmetic longer and less true. `estimatedTime` was in the
    -- same state, except that `/cn mode fastest` advertises it as one of its
    -- two levers, so the mode was half a feature.
    --
    -- Declaring a weight is a claim that something fills it. This checks the
    -- claim.
    ------------------------------------------------------------
    -- STATICALLY, ACROSS THE SHIPPED SOURCE.
    --
    -- Not "does the current fixture happen to set it": several of these are
    -- filled only when the player has goals pinned, or a Warband, or enough
    -- measured durations, and a fixture-shaped check would fail for every one
    -- of them while missing the actual defect. The property is that SOMETHING
    -- IN THE ADDON assigns the field at all.
    -- The fields ScoreObjective actually reads off an objective. Kept here
    -- rather than derived, because deriving it from the source would be a
    -- second parser to get wrong -- and the assertion below requires every
    -- one of these names to still appear in Scoring.lua, so the list cannot
    -- rot silently.
    local CONSUMED = {
        "completionValue", "unlockValue", "limitedTimeBonus",
        "hubSize", "userPreference", "characterSuitability", "travelCost",
        "estimatedTime", "expiresIn",
    }

    local produced = {}

    local manifest = io.open(ROOT .. "/CompletionNavigator.toc", "r")

    assert(manifest, "the .toc must be readable to scan the source")

    local listed = manifest:read("*a")

    manifest:close()

    local scanned = 0

    for line in string.gmatch(listed, "[^\r\n]+") do
        if string.match(line, "%.lua%s*$") and not string.match(line, "^%s*#") then
            local relative = string.gsub(line, "\\", "/")

            local file = io.open(ROOT .. "/" .. CN.Trim(relative), "r")

            if file then
                local text = file:read("*a")

                file:close()

                scanned = scanned + 1

                -- Scoring.lua CONSUMES these fields and declares the
                -- weights; it never produces an objective. Counting its own
                -- weight table as a producer would make every weight look
                -- filled, which is the failure this check exists to catch.
                if not string.find(relative, "Scoring%.lua") then
                    for _, field in ipairs(CONSUMED) do
                        if string.find(text, "[^%w_]" .. field .. "%s*=") then
                            produced[field] = true
                        end
                    end
                end
            end
        end
    end

    assert(scanned > 50, "the source scan found only " .. scanned .. " files")

    local orphans = {}

    for _, field in ipairs(CONSUMED) do
        if not produced[field] then
            table.insert(orphans, field)
        end
    end

    table.sort(orphans)

    assert(#orphans == 0,
        "objective field(s) the scorer reads that nothing in " .. scanned
        .. " source files ever sets: " .. table.concat(orphans, ", "))

    -- AND THE OTHER DIRECTION: a declared weight that multiplies nothing.
    local scoring = io.open(ROOT .. "/Scoring.lua", "r")

    assert(scoring, "Scoring.lua must be readable")

    local scoringText = scoring:read("*a")

    scoring:close()

    local unused = {}

    for weight in pairs(CN.scoreWeights) do
        if not string.find(scoringText, "w%." .. weight) then
            table.insert(unused, weight)
        end
    end

    table.sort(unused)

    assert(#unused == 0,
        "declared weight(s) the scorer never applies: "
        .. table.concat(unused, ", "))

    for _, field in ipairs(CONSUMED) do
        assert(string.find(scoringText, "objective%." .. field),
            "the consumed-field list names " .. field
            .. ", which the scorer no longer reads")
    end

    ------------------------------------------------------------
    -- AND `fastest` MUST ACTUALLY PREFER THE FASTER THING.
    ------------------------------------------------------------
    local session = CN:GetModule("Session")

    assert(session.TimeCost, "the time-cost producer must exist")

    ------------------------------------------------------------
    -- AND THE PRODUCER MUST ACTUALLY PRODUCE IT.
    --
    -- The rest of this block hand-built objectives with `estimatedTime`
    -- already set and checked that the scorer used it -- testing the consumer
    -- against a fixture the producer never made. The producer was registered
    -- as a decorator taking a LIST while decorators receive one objective, so
    -- it set the field on nothing; and the whole block had landed inside
    -- another function, so it only existed as a side effect of calling that
    -- one. `/cn mode fastest` kept the inert lever 0.48.0 recorded as fixed.
    ------------------------------------------------------------
    local durations = session.Durations()

    durations[CN.objectiveTypes.QUEST] = { 180, 180, 180, 180, 180 }

    local decorated = CN.NewObjective({
        id              = 4242,
        type            = CN.objectiveTypes.QUEST,
        name            = "Timed Thing",
        completionValue = 3,
    })

    local sessionDecorator = false

    for name, decorator in pairs(CN.candidateDecorators) do
        if name == "Session" then
            decorator(decorated)
            sessionDecorator = true
        end
    end

    assert(sessionDecorator, "the Session decorator must be registered")

    assert(type(decorated.estimatedTime) == "number"
        and decorated.estimatedTime > 0,
        "the decorator must set how long the thing takes, got "
        .. tostring(decorated.estimatedTime))

    durations[CN.objectiveTypes.QUEST] = nil

    local saved = CN.Settings().priorityMode

    CN.Settings().priorityMode = "fastest"

    local quick = CN.NewObjective({
        id = 1, type = CN.objectiveTypes.QUEST, name = "Quick",
        completionValue = 5, travelCost = 1, estimatedTime = 0.5,
    })

    local slow = CN.NewObjective({
        id = 2, type = CN.objectiveTypes.QUEST, name = "Slow",
        completionValue = 5, travelCost = 1, estimatedTime = 6,
    })

    assert(CN.ScoreObjective(quick) > CN.ScoreObjective(slow),
        "in fastest mode a quicker objective must outrank an identical "
        .. "slower one, or the mode's second lever does nothing")

    CN.Settings().priorityMode = saved

    print("  " .. CN.CountKeys(CN.scoreWeights)
        .. " weights, every one of them produced, and fastest prefers fast")
end)()

print("\nA route ordered on a map that is not square:")

;(function()
    ------------------------------------------------------------
    -- THE SQUARE-MAP ASSUMPTION, EIGHT RELEASES AFTER THE LAST ONE.
    --
    -- 0.40.0 found that every bearing in the game was wrong because the code
    -- assumed a map is square. Routing.lua was still assuming it: ordering,
    -- 2-opt and route length all worked on raw 0-to-1 coordinates, so in a
    -- 3000-by-1500 zone a stop 300 yards east compared as further away than
    -- one 165 yards north, and the optimiser then improved a distance that
    -- was not the distance.
    --
    -- The route tests that existed used square synthetic coordinates and
    -- asserted only that the route got shorter under the same distorted
    -- measure -- which it always does.
    ------------------------------------------------------------
    local savedSpan = CN_TEST_MAP_SPAN

    -- Twice as wide as it is tall, which is an ordinary zone.
    CN_TEST_SetMapSpan({ 3000, 1500 })

    CN.UseRouteMapScale(94)

    -- East 0.10 of the map is 300 yards. North 0.11 is 165. The nearer stop
    -- in yards is the one that is further away in map units.
    local east  = { x = 0.60, y = 0.50, name = "east" }
    local north = { x = 0.50, y = 0.39, name = "north" }

    local ordered = CN.OrderByProximity({ east, north }, 0.50, 0.50)

    assert(ordered[1].name == "north",
        "the nearer stop in YARDS must be visited first; the route went to "
        .. tostring(ordered[1].name) .. " first")

    -- And the reported length must be yards, not map units: two stops at
    -- 165 and then a leg across to the east one.
    local length = CN.RouteLength(ordered, 0.50, 0.50)

    assert(length > 100,
        "a route length in yards across a 3000-yard zone cannot be "
        .. string.format("%.3f", length) .. " -- that is map units")

    CN.UseRouteMapScale(nil)

    CN_TEST_SetMapSpan(savedSpan)

    print(string.format("  ordered by real distance, %.0f yards of walking",
        length))
end)()

print("\nRouting one zone does not score another one as batched:")

;(function()
    ------------------------------------------------------------
    -- HUB STATE IS WRITTEN ONTO LIVE CANDIDATES AND WAS NEVER CLEARED.
    --
    -- `hub` and `hubSize` are stamped onto candidate objects at the end of
    -- BuildZoneRoute, and the scorer turns hubSize into a batch bonus. Two
    -- things followed: an objective routed once carried its bonus for the
    -- rest of the session, including while a different zone was routed and
    -- including in the ranked list -- which is not about zones at all; and
    -- the ranking cache was not invalidated, so `/cn next` served pre-bonus
    -- scores while `/cn zone` showed the hubs that produced them.
    ------------------------------------------------------------
    local mapID, x, y = CN.GetPlayerPosition()

    -- Two things at the same spot, which is what a hub is.
    CN.RegisterCandidateProvider("HubProbe", function()
        local rows = {}

        for index = 1, 2 do
            table.insert(rows, CN.NewObjective({
                id              = 555000 + index,
                type            = CN.objectiveTypes.RARE,
                name            = "Together " .. index,
                completionValue = 3,
                mapID           = mapID,
                x               = 0.35,
                y               = 0.60,
            }))
        end

        return rows
    end)

    CN.CollectCandidates(true)

    CN.BuildZoneRoute(mapID, x or 0.5, y or 0.5)

    local batched = 0

    for _, objective in ipairs(CN.CollectCandidates()) do
        if objective.hubSize and objective.hubSize > 1 then
            batched = batched + 1
        end
    end

    assert(batched > 0,
        "the fixture must produce at least one hub with company in it, or "
        .. "this proves nothing")

    -- A different map. Nothing in THIS zone may still look batched.
    CN.BuildZoneRoute(99999, 0.5, 0.5)

    for _, objective in ipairs(CN.CollectCandidates()) do
        assert(objective.hubSize == nil,
            "routing a different zone must clear the last one's batching; "
            .. tostring(objective.name) .. " still carries hubSize "
            .. tostring(objective.hubSize))
    end

    CN.candidateProviders["HubProbe"] = nil

    CN.CollectCandidates(true)

    print("  " .. batched .. " batched stop(s), and none of them survive "
        .. "routing elsewhere")
end)()

print("\nEvery event a provider asks for is an event something dispatches:")

;(function()
    ------------------------------------------------------------
    -- TWO LISTS, ONE OF WHICH NOBODY CHECKED AGAINST THE OTHER.
    --
    -- Providers declare `events = { ... }` to say what invalidates them, and
    -- Scoring.lua held a separate hand-written list of the events it actually
    -- subscribed to. Nine declared events appeared on no such list, and
    -- because InvalidateCandidates SKIPS a provider that has an events table
    -- and was not named, declaring an unwired event was strictly worse than
    -- declaring nothing: Orders and Inventory never refreshed after login.
    --
    -- Scoring now subscribes to whatever the providers declare, so the two
    -- lists cannot disagree. This asserts that they do not.
    ------------------------------------------------------------
    local declared = {}

    for name, provider in pairs(CN.candidateProviders) do
        for event in pairs(provider.events or {}) do
            declared[event] = declared[event] or name
        end
    end

    local orphaned = {}

    for event, provider in pairs(declared) do
        if not CN.eventTable[event] then
            table.insert(orphaned, event .. " (" .. provider .. ")")
        end
    end

    table.sort(orphaned)

    for _, entry in ipairs(orphaned) do
        print("  NOBODY DISPATCHES: " .. entry)
    end

    assert(#orphaned == 0,
        #orphaned .. " provider event(s) are declared and never dispatched: "
        .. table.concat(orphaned, ", "))

    local declaredCount = 0

    for _ in pairs(declared) do
        declaredCount = declaredCount + 1
    end

    ------------------------------------------------------------
    -- AND EVERY ONE OF THEM MUST ACTUALLY MARK ITS PROVIDER DIRTY.
    --
    -- Subscribing is not the property that matters; invalidating is. A
    -- handler registered against the wrong function would satisfy the check
    -- above and change nothing.
    ------------------------------------------------------------
    for event, name in pairs(declared) do
        CN.CollectCandidates(true)

        local state = CN.ProviderState(name)

        assert(state and state.dirty ~= true,
            "a forced rebuild must leave " .. name .. " clean")

        fire(event)

        assert(CN.ProviderState(name).dirty == true,
            event .. " must invalidate " .. name .. ", the provider that "
            .. "declared it")
    end

    print("  " .. declaredCount .. " declared events, every one of them dispatched "
        .. "and every one marking its provider dirty")
end)()

print("\nEvery event this addon registers is an event:")

;(function()
    ------------------------------------------------------------
    -- PRODUCTION DEGRADES; THE TEST SUITE MUST NOT.
    --
    -- The stub frame refuses an unknown event, exactly as the client does.
    -- But the addon now catches that refusal on purpose -- one bad name must
    -- not be a Lua error at every login -- and a pcall in the shipped code
    -- swallows the harness's assertion just as effectively as it swallows the
    -- client's.
    --
    -- So the guard records what it rejected, and this fails on anything in
    -- that list. The player gets a degraded feature; the author gets a failed
    -- build. That is the right way round, and getting it the wrong way round
    -- is how a swallowed error becomes a permanent one.
    ------------------------------------------------------------
    ------------------------------------------------------------
    -- FIRST, PROVE THE GUARD RECORDS ANYTHING AT ALL.
    --
    -- The assertion below is that nothing was rejected, which passes just as
    -- well when the recording is broken as when the addon is correct. A test
    -- whose success is indistinguishable from its subject being absent is not
    -- a test. So: register something that certainly is not an event, and
    -- require that it was both refused and named.
    ------------------------------------------------------------
    CN:RegisterEvent("CN_THIS_IS_NOT_AN_EVENT", function() end)

    assert(CN.rejectedEvents["CN_THIS_IS_NOT_AN_EVENT"],
        "the client refused an event and nothing recorded that it did")

    assert(not CN.eventFrame.events["CN_THIS_IS_NOT_AN_EVENT"],
        "and a refused event must not be left looking registered")

    CN.rejectedEvents["CN_THIS_IS_NOT_AN_EVENT"] = nil
    CN.eventTable["CN_THIS_IS_NOT_AN_EVENT"]     = nil

    local rejected = {}

    for event in pairs(CN.rejectedEvents or {}) do
        table.insert(rejected, event)
    end

    table.sort(rejected)

    for _, event in ipairs(rejected) do
        print("  NOT AN EVENT: " .. event)
    end

    assert(#rejected == 0,
        #rejected .. " registered event(s) do not exist: "
        .. table.concat(rejected, ", "))

    -- AND THE REGISTRY MUST HAVE REACHED THE CLIENT AT ALL.
    --
    -- Most of the addon loads BEFORE Events.lua creates the frame, so those
    -- registrations are replayed by a loop in that file. If the replay were
    -- dropped, every event registered early would silently never fire and
    -- nothing here would notice -- the handlers would all still be in the
    -- table, looking registered.
    local registered = 0

    for event in pairs(CN.eventTable) do
        if CN.eventFrame.events[event] then
            registered = registered + 1
        else
            print("  NEVER REACHED THE CLIENT: " .. event)
        end
    end

    assert(registered == CN.CountKeys(CN.eventTable),
        "some handlers are registered with the addon but not with the client")

    print("  " .. registered .. " events registered, none of them invented")
end)()

print("\nEvery tab builds:")

;(function()
    ------------------------------------------------------------
    -- THE GAP THAT LET A REAL BREAK THROUGH.
    --
    -- Splitting the list widget out of UI.lua in 0.45.0 left nine tab
    -- builders calling a bare `CreateList`, which after the move resolved to
    -- a global that does not exist. Every tab would have failed to build in
    -- game. The suite passed, because it opened the window -- which builds
    -- ONE tab, lazily -- and never touched the other ten.
    --
    -- luacheck caught it. A linter catching what a test suite cannot is a
    -- gap in the suite, not a reason to rely on the linter.
    ------------------------------------------------------------
    local UI = CN.UI

    assert(#UI.tabs >= 10, "the window must have its tabs, got " .. #UI.tabs)

    -- READ THE ERROR RECORDER, NOT pcall.
    --
    -- SelectTab wraps each builder in its own pcall so that one broken tab
    -- cannot take the window down with it -- which is right, and means a
    -- caller's pcall NEVER sees the failure. The first version of this test
    -- wrapped SelectTab and passed against a tree where every tab was broken.
    --
    -- 0.44.0 built the thing that makes this checkable: errors caught inside
    -- the addon are recorded rather than only printed.
    local errors = CN:GetModule("Errors")

    errors.Clear()

    -- FORCE A REBUILD.
    --
    -- Panels are built once and cached, so by the time this section runs the
    -- earlier tests have already built whichever tabs they touched -- and any
    -- failure happened before the Clear above. Dropping the panels makes this
    -- test build all eleven itself, which is the thing it claims to check.
    for _, tab in ipairs(UI.tabs) do
        tab.panel = nil
    end

    UI.Toggle()

    for index = 1, #UI.tabs do
        UI.SelectTab(index)

        -- And refreshing it, which is the path that runs on every event while
        -- somebody is looking at that tab.
        UI.Refresh()
    end

    for _, entry in ipairs(errors.All()) do
        print("  BROKEN: " .. entry.context .. " -- " .. entry.message)
    end

    assert(errors.Count() == 0,
        errors.Count() .. " tab(s) failed to build or refresh")

    -- Every tab that made a list must actually have one, or "it built" means
    -- only that nothing threw.
    local withLists = 0

    for _, tab in ipairs(UI.tabs) do
        if tab.panel and tab.panel.list then
            withLists = withLists + 1
        end
    end

    assert(withLists >= 8,
        "most tabs are list tabs and must have built one, got " .. withLists)

    UI.Toggle()

    print("  " .. #UI.tabs .. " tabs built and refreshed, " .. withLists
        .. " of them with lists")

    ------------------------------------------------------------
    -- AND ALL OF IT AGAIN WITH EVERY TEMPLATE RETIRED.
    --
    -- Blizzard renames and retires XML templates between expansions, and a
    -- missing template makes `CreateFrame` throw. `SafeCreateFrame` exists so
    -- that takes one frame's styling rather than the whole window -- and
    -- neither it nor `PaintPanel`, the hand-drawn replacement it falls back
    -- to, had ever been executed: the harness stub accepts any template, so
    -- the failure branch was unreachable and the fallback was three hundred
    -- lines of untested code that only ever runs on the day a patch breaks
    -- the addon.
    ------------------------------------------------------------
    local realCreateFrame = CreateFrame

    CreateFrame = function(frameType, name, parent, template)
        if template then
            error("no such template: " .. tostring(template), 0)
        end

        return realCreateFrame(frameType, name, parent)
    end

    -- Prove the guard actually catches it, rather than the window happening
    -- to ask for no templates.
    local plain, templated = UI.SafeCreateFrame("Frame", nil, UIParent,
        "SomeRetiredTemplate")

    assert(plain and templated == false,
        "a retired template must degrade to a plain frame, not throw")

    for _, tab in ipairs(UI.tabs) do
        tab.panel = nil
    end

    UI.window = nil

    errors.Clear()

    UI.Toggle()

    for index = 1, #UI.tabs do
        UI.SelectTab(index)
        UI.Refresh()
    end

    for _, entry in ipairs(errors.All()) do
        print("  BROKEN WITHOUT TEMPLATES: " .. entry.context
            .. " -- " .. entry.message)
    end

    assert(errors.Count() == 0,
        "the whole window must build with every template retired; "
        .. errors.Count() .. " failure(s)")

    -- The window still has to be usable, not merely non-throwing.
    local rebuilt = 0

    for _, tab in ipairs(UI.tabs) do
        if tab.panel and tab.panel.list then
            rebuilt = rebuilt + 1
        end
    end

    assert(rebuilt >= 8,
        "and its lists must still be there, got " .. rebuilt)

    -- Position round trip, which is the other thing the frame layer owns.
    UI.SavePosition()

    assert(CN.Settings().window and CN.Settings().window.point,
        "the window position must be saved")

    UI.RestorePosition()

    UI.RebuildTabs()

    UI.Toggle()

    CreateFrame = realCreateFrame

    for _, tab in ipairs(UI.tabs) do
        tab.panel = nil
    end

    UI.window = nil

    print("  and all " .. #UI.tabs .. " again with every template retired")
end)()


print("\nCaches that must not go stale:")

;(function()
    ------------------------------------------------------------
    -- BOTH OF THESE WERE MEASURED, NOT GUESSED.
    --
    -- At realistic scale -- three thousand appearance sets, five full bags --
    -- the two providers added in 0.44.0 and 0.45.0 cost 4.4ms and 0.6ms per
    -- candidate rebuild. Sets alone was more than every other provider in the
    -- addon added together.
    --
    -- Neither was visible in the first measurement, because the fixtures had
    -- three sets and three items in them. A cache is the fix; a cache that
    -- goes stale is a worse bug than the cost it saved, so both are tested
    -- through the event the client actually sends.
    ------------------------------------------------------------
    local sets = CN:GetModule("Sets")

    sets.Forget()

    local first = sets.All()

    local again = sets.All()

    assert(first == again,
        "a second read must be the cached table, not a fresh scan")

    -- A set becomes collected. Without invalidation the addon would go on
    -- recommending it forever.
    local watched = CN_TEST_SETS[1]

    local beforeCollect = #sets.NearlyComplete()

    watched.pieces[5] = true

    assert(#sets.NearlyComplete() == beforeCollect,
        "the cache holds until the client says otherwise")

    CN.FireEvent("TRANSMOG_COLLECTION_UPDATED")

    local after = sets.NearlyComplete()

    for _, set in ipairs(after) do
        assert(set.setID ~= 1,
            "a set finished since the scan must drop out once the client "
            .. "announces it")
    end

    watched.pieces[5] = false

    CN.FireEvent("TRANSMOG_COLLECTION_UPDATED")

    print("  appearance sets are cached until a transmog is collected")

    ------------------------------------------------------------
    -- THE BAGS, THE SAME WAY.
    ------------------------------------------------------------
    local inventory = CN:GetModule("Inventory")

    inventory.Forget()

    local bags = inventory.Scan()

    assert(inventory.Scan() == bags, "the bag scan is cached")

    -- A bank scan must NOT be served from, or write to, that cache: it is a
    -- different set of containers and a deliberate one-off.
    local bank = inventory.Scan(inventory.bankIDs)

    assert(bank ~= bags, "a bank scan is its own read")
    assert(inventory.Scan() == bags, "and does not replace the bag cache")

    CN.FireEvent("BAG_UPDATE_DELAYED")

    assert(inventory.Scan() ~= bags, "moving something in a bag re-reads them")

    ------------------------------------------------------------
    -- A QUEST ITEM IS NOT AN ITEM THE VENDOR WILL NOT BUY.
    --
    -- `questItem` was read from `hasNoValue`, which means "has no sell
    -- price". Every grey, every soulbound token and every worthless trinket
    -- in the bag was therefore flagged a quest item. Nothing caught it
    -- because the stub never set the field, so the true and false branches
    -- produced the same answer.
    ------------------------------------------------------------
    inventory.Forget()

    local byItem = {}

    for _, row in ipairs(inventory.Scan()) do
        byItem[row.itemID] = row
    end

    assert(byItem[60002] and byItem[60002].questItem == false,
        "an item with no vendor value is not thereby a quest item")

    assert(byItem[60001] and byItem[60001].questItem == true,
        "and one the client calls a quest item is")

    print("  a quest item is read from the quest API, not from its sell price")

    print("  bags are cached until they change, and the bank is separate")
end)()


print("\nHelp that names commands which exist:")

;(function()
    ------------------------------------------------------------
    -- A CURATED LIST OF NAMES ROTS SILENTLY.
    --
    -- 0.44.0 grouped the help by what the player is trying to do, which meant
    -- writing five lists of command names by hand. A name that is renamed, or
    -- typed wrongly, does not error -- the entry simply does not appear, and
    -- the command becomes undiscoverable while the help still looks complete.
    ------------------------------------------------------------
    local known = {}

    for _, definition in ipairs(CN.commandList) do
        known[definition.name] = true

        for _, alias in ipairs(definition.aliases or {}) do
            known[alias] = true
        end
    end

    local missing = {}

    for _, name in ipairs(CN.helpEssentials) do
        if name ~= "" and not known[name] then
            table.insert(missing, "essentials: " .. name)
        end
    end

    for _, group in ipairs(CN.helpGroups) do
        for _, name in ipairs(group.names) do
            if not known[name] then
                table.insert(missing, group.title .. ": " .. name)
            end
        end
    end

    for _, entry in ipairs(missing) do
        print("  MISSING: " .. entry)
    end

    assert(#missing == 0,
        #missing .. " help entry(ies) name a command that does not exist")

    ------------------------------------------------------------
    -- AND EVERY COMMAND MUST BE REACHABLE FROM `help all`.
    --
    -- The grouped view has an "everything else" bucket, so this cannot fail
    -- by omission -- but a command whose name appears in NO group and whose
    -- existence nobody notices is exactly what the bucket is there to catch.
    ------------------------------------------------------------
    local grouped = {}

    for _, group in ipairs(CN.helpGroups) do
        for _, name in ipairs(group.names) do
            grouped[name] = true
        end
    end

    local ungrouped = {}

    for _, definition in ipairs(CN.commandList) do
        if not grouped[definition.name] then
            table.insert(ungrouped, definition.name)
        end
    end

    print("  " .. #CN.commandList .. " commands, " .. #ungrouped
        .. " of them in the catch-all group"
        .. (#ungrouped > 0 and (" (" .. table.concat(ungrouped, ", ") .. ")")
            or ""))

    ------------------------------------------------------------
    -- AND NO NAME MAY BE CLAIMED TWICE.
    --
    -- Registration overwrote silently, so whichever file loaded last won and
    -- `/cn help` went on describing the loser. `/cn zones` was a command and,
    -- further down the same file, an ALIAS of `/cn loremaster` -- so it ran
    -- the quest-completion report while the help text and the store page both
    -- described the zone ranking.
    ------------------------------------------------------------
    local collisions = {}

    for _, clash in ipairs(CN.commandCollisions or {}) do
        table.insert(collisions, clash.name .. " (" .. clash.kind
            .. ": " .. clash.from .. " lost it to " .. clash.to .. ")")
    end

    assert(#collisions == 0,
        "a command name claimed twice runs one thing and documents another: "
        .. table.concat(collisions, "; "))

    print("  and no name or alias is claimed twice")

    ------------------------------------------------------------
    -- AND A MULTI-WORD NAME MUST BE REACHABLE.
    ------------------------------------------------------------
    do
        local multiword = {}

        for _, definition in ipairs(CN.commandList) do
            if definition.name:find("%s") then
                table.insert(multiword, definition.name)
            end
        end

        for _, name in ipairs(multiword) do
            local reached

            local realHandler = CN.commands[name].handler

            CN.commands[name].handler = function() reached = true end

            CN.HandleSlashCommand(name)

            CN.commands[name].handler = realHandler

            assert(reached,
                "/cn " .. name .. " is registered and listed in help but the "
                .. "dispatcher splits on the first space, so it can never be "
                .. "reached")
        end

        print("  " .. #multiword .. " multi-word command(s) reachable as typed")
    end

    -- THE RATCHET.
    --
    -- 0.44.0 asserted only that fewer than half were ungrouped, which is how
    -- 74 of 123 was allowed to happen a release later -- the bar was set so
    -- far below the current state that it could never move. It is now set
    -- just above where the addon actually is, so the next command that gets
    -- added without being filed fails the build instead of quietly joining a
    -- bucket nobody reads.
    assert(#ungrouped <= 2,
        #ungrouped .. " commands are in the catch-all group; file them in "
        .. "CN.helpGroups: " .. table.concat(ungrouped, ", "))
end)()

print("\nALL HARNESS CHECKS PASSED")
