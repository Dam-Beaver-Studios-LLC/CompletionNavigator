-- Providers/StaticData.lua
-- Completion Navigator :: access layer for the curated static database.
--
-- Data/*.lua files call CN.Static.Register* to contribute rows. Nothing
-- reads those tables directly; everything goes through the accessors here
-- so the storage shape can change without touching consumers.

local ADDON_NAME, CN = ...

local Static = {}

CN.Static = Static

Static.quests    = {}
Static.recipes   = {}
Static.vendors   = {}
Static.rares     = {}
Static.treasures = {}

------------------------------------------------------------
-- REGISTRATION
------------------------------------------------------------

-- record = { name =, mapID =, x =, y =, expansion =, requires = {}, unlocks = {} }
function Static.RegisterQuest(questID, record)
    if not questID or type(record) ~= "table" then
        return
    end

    Static.quests[questID] = record
end

function Static.RegisterQuests(records)
    for questID, record in pairs(records) do
        Static.RegisterQuest(questID, record)
    end
end

function Static.RegisterRecipe(itemID, record)
    Static.recipes[itemID] = record
end

function Static.RegisterVendor(npcID, record)
    Static.vendors[npcID] = record
end

function Static.RegisterRare(npcID, record)
    Static.rares[npcID] = record
end

function Static.RegisterTreasure(id, record)
    Static.treasures[id] = record
end

------------------------------------------------------------
-- ACCESS
------------------------------------------------------------

-- CONTRIBUTED CHAINS.
--
-- Held apart from the curated table so that the difference between "checked"
-- and "widely observed" survives being written to disk, and so /cn why can
-- say which one it is quoting.
Static.community = Static.community or {}

function Static.RegisterCommunity(records)
    if type(records) ~= "table" then
        return 0
    end

    local added = 0

    for questID, record in pairs(records) do
        if type(record) == "table" and type(record.requires) == "table" then
            Static.community[questID] = record

            added = added + 1
        end
    end

    return added
end

function Static.GetCommunity(questID)
    return Static.community[questID]
end

function Static.CommunityCount()
    local count = 0

    for _ in pairs(Static.community) do
        count = count + 1
    end

    return count
end

function Static.GetQuest(questID)
    return Static.quests[questID]
end

-- ELIGIBILITY, from curated data.
--
-- The client only draws quest pins the character qualifies for, so gating is
-- normally handled by simply not seeing it. That is fine while the player is
-- standing there and useless the moment they ask "why can nobody in my
-- Warband do this?" -- which is exactly what /cn why and /cn alts are for.
--
-- Returns eligible, reason. A record with no gating fields is eligible, and
-- says so with a nil reason rather than an empty claim.
function Static.QuestEligibility(questID, character)
    local record = Static.quests[questID]

    if not record then
        return true, nil
    end

    character = character or CN.character or {}

    -- THE REASON AS A TOKEN, AS WELL AS AS A SENTENCE. 0.64.0.
    --
    -- The caller in Quests.lua recovered WHY a quest was blocked by
    -- pattern-matching this English prose -- `find("^race")`,
    -- `find("Alliance")`. Since 0.61.0 the class and race lists in that
    -- sentence are run through the client's LOCALIZED names, so the string is
    -- already half-translated and the parser survives only because the label
    -- prefixes happen to still be English.
    --
    -- The reason is known here, exactly, at the moment the sentence is built.
    -- Throwing it away and reconstructing it from the display text is the
    -- "branch on a localized string" rule broken by a longer road: the first
    -- translation of "race only" would silently reclassify every race-gated
    -- quest as class-gated, and `/cn alts` would name the wrong alt.
    --
    -- Third return: a stable token. The sentence is unchanged.
    if record.faction and character.faction
        and record.faction ~= character.faction then

        return false, CN.TokenLabel(record.faction) .. " only", "FACTION"
    end

    if record.minLevel and character.level
        and character.level < record.minLevel then

        return false, "level " .. record.minLevel .. " required", "LEVEL"
    end

    local function allowed(list, value, label)
        if type(list) ~= "table" or #list == 0 or not value then
            return true
        end

        for _, entry in ipairs(list) do
            if entry == value then
                return true
            end
        end

        -- "class only: WARRIOR, PALADIN" IS A DATABASE ROW, NOT A SENTENCE.
        -- 0.61.0.
        --
        -- These are the client's uppercase tokens, and they went straight
        -- onto the player's screen. The client already holds the localized
        -- names for exactly these tokens; using them costs one table lookup
        -- and turns the line into something a player reads rather than
        -- decodes.
        local words = {}

        for _, entry in ipairs(list) do
            table.insert(words, CN.TokenLabel(entry))
        end

        return false, label .. " only: " .. CN.Series(words)
    end

    local okClass, classReason = allowed(record.classes, character.class, "class")

    if not okClass then
        return false, classReason, "CLASS"
    end

    local okRace, raceReason = allowed(record.races, character.race, "race")

    if not okRace then
        return false, raceReason, "RACE"
    end

    return true, nil, nil
end

-- Where a quest is HANDED IN, which is not where it is picked up and is not
-- what the client's moving "next waypoint" reports once you are part-way
-- through it.
function Static.GetQuestTurnIn(questID)
    local record = Static.quests[questID]

    if not record or not record.turnInMapID then
        return nil
    end

    return record.turnInMapID, record.turnInX, record.turnInY
end

function Static.GetQuestName(questID)
    local record = Static.quests[questID]

    return record and record.name or nil
end

function Static.GetQuestLocation(questID)
    local record = Static.quests[questID]

    if not record then
        return nil, nil, nil
    end

    return record.mapID, record.x, record.y
end

function Static.Count()
    return CN.CountKeys(Static.quests),
           CN.CountKeys(Static.recipes),
           CN.CountKeys(Static.vendors),
           CN.CountKeys(Static.rares),
           CN.CountKeys(Static.treasures)
end
