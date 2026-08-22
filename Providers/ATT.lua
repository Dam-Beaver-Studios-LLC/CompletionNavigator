-- Providers/ATT.lua
-- Completion Navigator :: AllTheThings interoperability.
--
-- ATT is the largest completion data corpus in the ecosystem. Duplicating it
-- would be pointless and rude; reading it when the player already has it
-- installed is the right relationship. Completion Navigator stays the
-- decision layer.
--
-- IMPORTANT: third-party addon APIs are not stable and are not documented as
-- public contracts. Every entry point below is probed at runtime and wrapped
-- in pcall. If ATT changes shape, this provider reports itself unavailable
-- and the addon carries on with its own data. It must never take the addon
-- down with it.
--
-- Run /cn providers in game to see exactly which entry points resolved.

local ADDON_NAME, CN = ...

local ATT = {}

CN.ATT = ATT

-- Candidate globals, newest naming first.
local GLOBALS = { "AllTheThings", "ATTC", "ATT" }

local resolved   = nil
local probeNotes = {}

local function Root()
    if resolved then
        return resolved
    end

    for _, name in ipairs(GLOBALS) do
        local candidate = _G[name]

        if type(candidate) == "table" then
            resolved = candidate

            table.insert(probeNotes, "global: " .. name)

            return resolved
        end
    end

    return nil
end

function ATT.IsAvailable()
    return Root() ~= nil
end

------------------------------------------------------------
-- SEARCH
------------------------------------------------------------

-- ATT's field search is the one entry point that has survived several
-- rewrites. It returns an array of "groups" describing everything ATT knows
-- about that ID.
local function Search(field, id)
    local root = Root()

    if not root or not id then
        return nil
    end

    local search = root.SearchForField or root.SearchForFieldContainer

    if type(search) ~= "function" then
        return nil
    end

    local ok, results = pcall(search, field, id)

    if not ok or type(results) ~= "table" then
        return nil
    end

    return results
end

ATT.Search = Search

------------------------------------------------------------
-- QUEST DATA
------------------------------------------------------------

-- Walks the groups ATT returns for a quest and pulls out whatever is useful.
-- Every field is optional; ATT groups are heterogeneous.
function ATT.GetQuestData(questID)
    local groups = Search("questID", questID)

    if not groups or #groups == 0 then
        return nil
    end

    local data = { source = "ATT" }

    for _, group in ipairs(groups) do
        if type(group) == "table" then
            if not data.name and type(group.name) == "string" and group.name ~= "" then
                data.name = group.name
            end

            if not data.mapID then
                data.mapID = group.mapID or group.coord and group.coord[3] or nil
            end

            -- ATT stores coordinates as {x, y, mapID} in `coord`, or a list
            -- of those in `coords`. Values are 0-100.
            local coord = group.coord

            if not coord and type(group.coords) == "table" then
                coord = group.coords[1]
            end

            if not data.x and type(coord) == "table" and coord[1] and coord[2] then
                data.x     = coord[1] / 100
                data.y     = coord[2] / 100
                data.mapID = coord[3] or data.mapID
            end

            if not data.requires and type(group.sourceQuests) == "table"
                and #group.sourceQuests > 0 then

                data.requires = {}

                for _, prerequisiteID in ipairs(group.sourceQuests) do
                    if type(prerequisiteID) == "number" then
                        table.insert(data.requires, prerequisiteID)
                    end
                end

                if #data.requires == 0 then
                    data.requires = nil
                end
            end

            -- FIRST WINS, like every other field in this loop.
            --
            -- The guard tested `data.lvl`, which nothing in this file ever
            -- assigns, so it was always true and the LAST matching group won
            -- -- alone among the six fields merged here, all of which use
            -- `if not data.<field>`. Two ATT groups with different level
            -- requirements produced whichever happened to be iterated last,
            -- and that feeds the "too low level" block reason.
            if data.requiresLevel == nil and type(group.lvl) == "number" then
                data.requiresLevel = group.lvl
            end
        end
    end

    if not (data.name or data.requires or data.x) then
        return nil
    end

    return data
end

------------------------------------------------------------
-- DIAGNOSTICS
------------------------------------------------------------

function ATT.Describe()
    local root = Root()

    if not root then
        return "not installed"
    end

    local entries = {}

    for _, note in ipairs(probeNotes) do
        table.insert(entries, note)
    end

    table.insert(entries, "SearchForField: "
        .. (type(root.SearchForField) == "function" and "yes" or "no"))

    return table.concat(entries, ", ")
end

------------------------------------------------------------
-- REGISTRATION
------------------------------------------------------------

CN.RegisterQuestDataProvider("ATT", {
    IsAvailable  = ATT.IsAvailable,
    GetQuestData = ATT.GetQuestData,
    Describe     = ATT.Describe,
    priority     = 20,
})
