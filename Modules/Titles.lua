-- Modules/Titles.lua
-- Completion Navigator :: player titles.
--
-- Titles are character-specific, not account-wide: the client's IsTitleKnown
-- answers for the logged-in character only. Storing them per character is
-- what lets the Warband layer say which alt already has one.

local ADDON_NAME, CN = ...

local Titles = CN:RegisterModule("Titles")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

------------------------------------------------------------
-- STORAGE
------------------------------------------------------------

-- Names are shared; known/unknown is per character.
local function NameStore()
    return CN.Account("titleNames")
end

local function CharacterStore(character)
    character = character or CN.character

    if not character then
        return nil
    end

    character.titles = character.titles or {}

    return character.titles
end

Titles.NameStore      = NameStore
Titles.CharacterStore = CharacterStore

------------------------------------------------------------
-- SCAN
------------------------------------------------------------

function Titles.Scan()
    local names = NameStore()
    local mine  = CharacterStore()

    if not mine then
        return 0, 0
    end

    local seen, known = 0, 0

    for _, title in ipairs(Blizzard.GetTitles()) do
        names[title.titleID] = title.name

        mine[title.titleID] = title.known or nil

        seen = seen + 1

        if title.known then
            known = known + 1
        end
    end

    CN.MarkScanned("titles")

    if CN.character then
        CN.character.titlesKnown = known
    end

    return seen, known
end

------------------------------------------------------------
-- SUMMARY
------------------------------------------------------------

function Titles.Summary()
    local names = NameStore()
    local mine  = CharacterStore() or {}

    local counts = {
        known     = CN.CountKeys(names),
        onThisOne = CN.CountKeys(mine),
        onAccount = 0,
    }

    -- A title counted once if any character has it.
    local anyCharacter = {}

    for _, character in CN.Characters() do
        if character.titles then
            for titleID in pairs(character.titles) do
                anyCharacter[titleID] = true
            end
        end
    end

    counts.onAccount = CN.CountKeys(anyCharacter)

    return counts
end

-- Which characters, if any, already have a title.
function Titles.WhoHas(titleID)
    local holders = {}

    for key, character in CN.Characters() do
        if character.titles and character.titles[titleID] then
            table.insert(holders, key)
        end
    end

    table.sort(holders)

    return holders
end

function Titles.Resolve(text)
    local titleID = CN.ToID(text)

    if titleID and NameStore()[titleID] then
        return titleID
    end

    if not text or text == "" then
        return nil
    end

    local needle  = string.lower(text)
    local matches = {}

    for id, name in pairs(NameStore()) do
        if name and string.find(string.lower(name), needle, 1, true) then
            table.insert(matches, { id = id, name = name })
        end
    end

    if #matches == 0 then
        return nil
    end

    table.sort(matches, function(a, b) return #a.name < #b.name end)

    return matches[1].id
end

------------------------------------------------------------
-- WHY THERE IS NO CANDIDATE PROVIDER HERE
------------------------------------------------------------

-- Every other collection module contributes recommendations. Titles
-- deliberately does not, and this comment exists so that absence reads as a
-- decision rather than an oversight.
--
-- A recommendation has to name an action. The client exposes a title's name
-- and whether this character has it, and nothing else -- no source, no
-- coordinates, no criteria. "You do not have Loremaster" is a fact, not a next
-- action, and emitting it would push a row with no location and no route into
-- a list whose entire purpose is to be actionable.
--
-- Titles are still fully tracked and reported: /cn titles, /cn who title, the
-- Collections tab and /cn breakdown all read this store directly. And a title
-- someone actually wants can be pinned with /cn goal title <id>, which is the
-- correct place for "I have decided I want this even though the addon cannot
-- tell me how to get it".

------------------------------------------------------------
-- ELIGIBILITY
------------------------------------------------------------

CN.RegisterEligibilityChecker(CN.objectiveTypes.TITLE, function(titleID)
    local states = CN.objectiveStates
    local mine   = CharacterStore()

    if mine and mine[titleID] then
        return states.COMPLETED, "Already earned by this character", NameStore()[titleID]
    end

    local holders = Titles.WhoHas(titleID)

    if #holders > 0 then
        return states.REQUIRES_OTHER_CHARACTER,
               CN.blockReasons.BETTER_CHARACTER,
               table.concat(holders, ", ")
    end

    return states.AVAILABLE, nil, nil
end)

------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

CN:RegisterEvent("KNOWN_TITLES_UPDATE", function()
    local seen, known = Titles.Scan()

    DebugPrint("Title scan: " .. known .. " known of " .. seen .. ".")
end)

CN:OnLogin(function()
    Titles.Scan()
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "titlescan",
    order   = 61,
    help    = "Scan this character's titles.",
    handler = function()
        local seen, known = Titles.Scan()

        Print("Scanned " .. seen .. " titles.")
        Print("Known by this character: " .. known)
    end,
}

CN:RegisterCommand{
    name    = "titles",
    order   = 62,
    help    = "Summarize title progress.",
    handler = function()
        local counts = Titles.Summary()

        if counts.known == 0 then
            Print("No title data yet. Run /cn titlescan.")
            return
        end

        Print("Titles in the game: " .. counts.known)
        Print("Known by this character: " .. counts.onThisOne)
        Print("Known by any character: " .. counts.onAccount)
    end,
}

CN:RegisterCommand{
    name    = "title",
    args    = "<titleID or name>",
    order   = 63,
    help    = "Show which characters have a title.",
    handler = function(args)
        if args == "" then
            Print("Usage: /cn title <titleID or name>")
            return
        end

        local titleID = Titles.Resolve(args)

        if not titleID then
            Print("No known title matches: " .. args)
            return
        end

        Print(NameStore()[titleID] .. " |cff8a8f96(" .. titleID .. ")|r")

        local holders = Titles.WhoHas(titleID)

        if #holders == 0 then
            Print("Not earned by any known character.")
        else
            Print("Earned by: " .. table.concat(holders, ", "))
        end
    end,
}
