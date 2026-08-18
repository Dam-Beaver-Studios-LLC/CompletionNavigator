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

function Static.GetQuest(questID)
    return Static.quests[questID]
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
