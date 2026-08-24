-- Modules/Contribute.lua
-- Completion Navigator :: sharing what you learned, without a server.
--
-- THE PROBLEM.
--
-- The addon learns quest orderings from play, and that knowledge dies on the
-- machine that learned it. One player's evening becomes better advice for
-- that player and for nobody else. The obvious fix is a central database that
-- collects everyone's observations -- and the obvious fix is wrong here, for
-- reasons worth writing down rather than re-deriving:
--
--   * A World of Warcraft addon has NO network access. None. So "upload"
--     necessarily means a second product -- a desktop application, an
--     installer, an update channel -- and that is a larger undertaking than
--     this addon.
--   * Character name, realm and play times are personal data. Collecting them
--     makes the publisher a data controller, with a privacy policy, deletion
--     requests and breach obligations attached.
--   * The project page promises, twice, that nothing leaves your machine.
--
-- So: a one-way, opt-in, de-identified export the player chooses to attach to
-- a bug report. No server, no account, no personal data, and the promise on
-- the store page stays true, because nothing leaves the machine unless the
-- player themselves moves it.
--
-- WHAT IS IN AN EXPORT.
--
-- Quest IDs and orderings. That is all. No names, no realm, no character, no
-- timestamps, no coordinates, no play history. The receiving end can verify
-- what it is by reading it, which is a property worth more than any assurance
-- in a privacy policy.

local ADDON_NAME, CN = ...

local Contribute = CN:RegisterModule("Contribute")

local Print = CN.Print

------------------------------------------------------------
-- THE FORMAT
------------------------------------------------------------

-- Version first, so a future format change is detectable rather than
-- misparsed. Deliberately plain text: a player can read it before deciding to
-- send it, and anybody who has ever been asked to paste an opaque blob into a
-- form knows why that matters.
--
--   CN1 <questID>:<prerequisiteID>,<prerequisiteID> ...
Contribute.formatVersion = "CN1"

function Contribute.Build()
    local harvest = CN:GetModule("Harvest")

    if not harvest or not harvest.AllConfident then
        return nil, "the harvest module is not loaded"
    end

    local edges = harvest.AllConfident()

    local ids = {}

    for questID in pairs(edges) do
        table.insert(ids, questID)
    end

    table.sort(ids)

    if #ids == 0 then
        return nil, "nothing is confident yet" .. CN.DASH .. "a chain has to hold on "
            .. (harvest.confidenceThreshold or 3)
            .. " characters before it is worth sending"
    end

    local parts = { Contribute.formatVersion }

    for _, questID in ipairs(ids) do
        local prerequisites = edges[questID]

        table.sort(prerequisites)

        table.insert(parts, questID .. ":" .. table.concat(prerequisites, ","))
    end

    return table.concat(parts, " "), nil, #ids
end

-- Reads an export back. Returns a table of questID -> { prerequisiteIDs }.
--
-- Strict: anything malformed is rejected outright rather than partially
-- accepted. A half-parsed contribution is worse than a refused one, because
-- it silently teaches the addon a chain nobody wrote.
function Contribute.Parse(text)
    if type(text) ~= "string" then
        return nil, "not text"
    end

    text = CN.Trim(text)

    local version, body = text:match("^(%u%u%d)%s+(.+)$")

    if version ~= Contribute.formatVersion then
        return nil, "not a Completion Navigator export "
            .. "(expected " .. Contribute.formatVersion .. ")"
    end

    local edges = {}

    local count = 0

    for entry in body:gmatch("%S+") do
        local questID, list = entry:match("^(%d+):([%d,]+)$")

        if not questID then
            return nil, "malformed entry: " .. entry
        end

        local prerequisites = {}

        for id in list:gmatch("%d+") do
            table.insert(prerequisites, tonumber(id))
        end

        if #prerequisites == 0 then
            return nil, "entry with no prerequisites: " .. entry
        end

        edges[tonumber(questID)] = prerequisites

        count = count + 1
    end

    if count == 0 then
        return nil, "no entries"
    end

    return edges, nil, count
end

------------------------------------------------------------
-- IMPORTING
------------------------------------------------------------

-- Imported chains land in their OWN store and are published as
-- observedRequires, never as requires.
--
-- The distinction is the whole safety model: curated data is something a
-- human checked, an observation is something the addon watched, and a
-- contribution is something a stranger's addon watched. The third must never
-- be able to present itself as the first, and /cn why has to be able to tell
-- the player which it is looking at.
function Contribute.Import(text)
    local edges, err, count = Contribute.Parse(text)

    if not edges then
        return false, err
    end

    local store = CN.Account("contributed")

    local added = 0

    for questID, prerequisites in pairs(edges) do
        if not store[questID] then
            added = added + 1
        end

        store[questID] = prerequisites

        -- TAGGED WITH WHERE IT CAME FROM.
        --
        -- The command promises that `/cn why` "will say the chain came from a
        -- contribution rather than from curated data", and it did not: an
        -- imported edge was indistinguishable from a locally observed one, so
        -- the eligibility checker formatted it as "seen first on N
        -- characters" -- with N read from the harvest store, which has no
        -- record of an imported quest and therefore answered zero. The player
        -- was told the addon had watched the ordering hold on ZERO
        -- characters, which is both a false provenance claim and nonsense as
        -- evidence.
        CN.AddDependency(CN.ObjectiveKey(CN.objectiveTypes.QUEST, questID), {
            observedRequires = prerequisites,
            origin           = "contributed",
        })
    end

    CN.InvalidateCandidates()

    return true, nil, count, added
end

function Contribute.Forget()
    local store = CN.Account("contributed")

    local count = CN.CountKeys(store)

    for questID in pairs(store) do
        store[questID] = nil
    end

    return count
end

CN:OnLogin(function()
    -- Re-publish on login, because the dependency graph is rebuilt from
    -- scratch each session and imported edges would otherwise silently stop
    -- applying the next time the player logged in.
    local store = CN.Account("contributed")

    for questID, prerequisites in pairs(store) do
        CN.AddDependency(CN.ObjectiveKey(CN.objectiveTypes.QUEST, questID), {
            observedRequires = prerequisites,
            origin           = "contributed",
        })
    end
end)

------------------------------------------------------------
-- COMMAND
------------------------------------------------------------

CN:RegisterCommand{
    name    = "contribute",
    args    = "[import <text>, or forget]",
    order   = 37,
    help    = "Share the quest chains you have learned, or take somebody "
        .. "else's.",
    handler = function(args)
        args = CN.Trim(args or "")

        local verb, rest = args:match("^(%S+)%s*(.*)$")

        verb = verb and string.lower(verb) or ""

        if verb == "forget" then
            Print("Forgot " .. CN.Count(Contribute.Forget(), "imported chain")
                .. ".")
            return
        end

        if verb == "import" then
            local ok, err, count, added = Contribute.Import(rest)

            if not ok then
                Print("|cffe2564cNot imported:|r " .. tostring(err))
                return
            end

            Print("Imported " .. CN.Count(count, "chain")
                .. ", " .. added .. " new.")
            Print("|cff8a8f96They are recorded as observations, not as facts: "
                .. "|cffffc74f/cn why|r will say the chain came from a "
                .. "contribution rather than from curated data.|r")
            return
        end

        local export, err, count = Contribute.Build()

        if not export then
            Print("Nothing to contribute yet.")
            Print("|cff8a8f96" .. tostring(err) .. "|r")
            return
        end

        Print(CN.Count(count, "chain")
            .. " ready to share. This text and nothing else:")
        Print("|cffffc74f" .. export .. "|r")
        Print("|cff8a8f96It contains quest IDs and orderings. No character "
            .. "name, no realm, no timestamps, no coordinates" .. CN.DASH .. "read it "
            .. "before you send it, which is rather the point of a format you "
            .. "can read.|r")
        Print("Paste it into an issue on the tracker and it ships to everyone "
            .. "in a later release.")
    end,
}

return Contribute
