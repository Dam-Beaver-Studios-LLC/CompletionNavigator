-- Providers/BtWQuests.lua
-- Completion Navigator :: BtWQuests interoperability.
--
-- BtWQuests knows quest chains. Completion Navigator knows what you have
-- done and where you are. The useful combination is: given the chain, which
-- link is the next one you can actually act on.
--
-- Same caution as the ATT provider: this reads another addon's internals,
-- which are not a published contract. Every access is probed and wrapped, so
-- a BtWQuests update can make this provider go quiet but cannot break
-- Completion Navigator.
--
-- /cn providers reports exactly what resolved.

local ADDON_NAME, CN = ...

local BtW = {}

CN.BtWQuests = BtW

local probeNotes = {}

local function Database()
    -- The database has lived in a couple of places across versions.
    local candidates = {
        _G.BtWQuestsDatabase,
        _G.BtWQuests and _G.BtWQuests.Database,
        _G.BtWQuests and _G.BtWQuests.database,
    }

    -- A NUMERIC LOOP, NOT ipairs.
    --
    -- The first slot is nil whenever the global is absent -- which the
    -- comment above says is the normal case on recent versions -- and ipairs
    -- stops at the first nil. So the two fallbacks this list exists to
    -- provide were unreachable in exactly the situation they were written
    -- for, and the provider reported BtWQuests as unavailable to anyone
    -- running a version that had moved it.
    --
    -- The interpreters do not even agree on how long the list is: 5.4 says
    -- two, the game's 5.1 says zero. BlizzardWorld.lua already avoids this
    -- with a numeric loop and a comment naming "the same nil-hole problem".
    for index = 1, 3 do
        local candidate = candidates[index]

        if type(candidate) == "table" then
            if #probeNotes == 0 then
                table.insert(probeNotes, "database slot " .. index)
            end

            return candidate
        end
    end

    return nil
end

function BtW.IsAvailable()
    return _G.BtWQuests ~= nil and Database() ~= nil
end

------------------------------------------------------------
-- QUEST LOOKUP
------------------------------------------------------------

local function GetQuestItem(questID)
    local database = Database()

    if not database or not questID then
        return nil
    end

    local getter = database.GetQuestByID or database.GetQuest

    if type(getter) ~= "function" then
        return nil
    end

    local ok, item = pcall(getter, database, questID)

    if not ok or type(item) ~= "table" then
        return nil
    end

    return item
end

BtW.GetQuestItem = GetQuestItem

-- Normalizes whatever shape prerequisites come back in into a flat array of
-- quest IDs. BtWQuests expresses them as condition tables, which may nest.
local function CollectQuestIDs(node, out, depth)
    if type(node) ~= "table" or depth > 4 then
        return
    end

    if type(node.questID) == "number" then
        out[node.questID] = true
    end

    if type(node.id) == "number" and node.type == "quest" then
        out[node.id] = true
    end

    for _, child in pairs(node) do
        if type(child) == "table" then
            CollectQuestIDs(child, out, depth + 1)
        end
    end
end

function BtW.GetQuestData(questID)
    local item = GetQuestItem(questID)

    if not item then
        return nil
    end

    local data = { source = "BtWQuests" }

    -- Name.
    local nameGetter = item.GetName

    if type(nameGetter) == "function" then
        local ok, name = pcall(nameGetter, item)

        if ok and type(name) == "string" and name ~= "" then
            data.name = name
        end
    elseif type(item.name) == "string" then
        data.name = item.name
    end

    -- Prerequisites.
    local prerequisites = item.prerequisites or item.restrictions

    local getter = item.GetPrerequisites

    if type(getter) == "function" then
        local ok, result = pcall(getter, item)

        if ok and type(result) == "table" then
            prerequisites = result
        end
    end

    if type(prerequisites) == "table" then
        local ids = {}

        CollectQuestIDs(prerequisites, ids, 0)

        ids[questID] = nil   -- never list a quest as its own prerequisite

        local list = {}

        for id in pairs(ids) do
            table.insert(list, id)
        end

        table.sort(list)

        if #list > 0 then
            data.requires = list
        end
    end

    if not (data.name or data.requires) then
        return nil
    end

    return data
end

------------------------------------------------------------
-- DIAGNOSTICS
------------------------------------------------------------

function BtW.Describe()
    if not _G.BtWQuests then
        return "not installed"
    end

    local database = Database()

    if not database then
        return "loaded, but no database found"
    end

    local entries = {}

    for _, note in ipairs(probeNotes) do
        table.insert(entries, note)
    end

    table.insert(entries, "GetQuestByID: "
        .. (type(database.GetQuestByID) == "function" and "yes" or "no"))

    return table.concat(entries, ", ")
end

------------------------------------------------------------
-- REGISTRATION
------------------------------------------------------------

CN.RegisterQuestDataProvider("BtWQuests", {
    IsAvailable  = BtW.IsAvailable,
    GetQuestData = BtW.GetQuestData,
    Describe     = BtW.Describe,
    priority     = 30,
})
