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

-- Known/unknown is per character. Names are not stored at all: see
-- `Titles.NameOf`.
local function CharacterStore(character)
    character = character or CN.character

    if not character then
        return nil
    end

    character.titles = character.titles or {}

    return character.titles
end

Titles.CharacterStore = CharacterStore

------------------------------------------------------------
-- SCAN
------------------------------------------------------------

function Titles.Scan()
    local mine = CharacterStore()

    if not mine then
        return 0, 0
    end

    local seen, known = 0, 0

    for _, title in ipairs(Blizzard.GetTitles()) do
        -- `titleNames` IS NOT WRITTEN ANY MORE. 0.65.0.
        --
        -- 0.64.0 gave the hidden-objectives list a live client path for
        -- titles and left this writer alone, so the store went on filling
        -- with names frozen at whatever language last scanned -- and
        -- `Titles.Resolve` searched only that store, so a player who changed
        -- client language could not find their own titles by name.
        --
        -- Eighth store to lose a name it did not need to keep.

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

-- `known` IS THE CLIENT'S OWN LIST LENGTH, NOT A STORED COUNT. 0.65.0.
--
-- It used to be `CountKeys(titleNames)` -- the store this version stopped
-- writing. Left alone it would have been zero on every character forever,
-- which is the number `/cn titles` and the Titles breakdown both branch on:
-- both would have told a player who had just scanned to go and scan.
--
-- `scanned` is what "no data yet" actually means. The client always knows how
-- many titles exist; only whether THIS character's known/unknown flags have
-- been read is a thing the addon has to remember.
function Titles.Summary()
    local mine = CharacterStore() or {}

    local counts = {
        known     = #(Blizzard.GetTitles and Blizzard.GetTitles() or {}),
        onThisOne = CN.CountKeys(mine),
        onAccount = 0,
        scanned   = (CN.Account("collectionScans") or {}).titles ~= nil,
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

-- A title's name, from the client. Eighth of these; see `Achievements.NameOf`
-- for the first. 0.65.0.
--
-- NO FALLBACK TO A STORE, for the reason spelled out in `Currencies.NameOf`:
-- `CN.Account(key)` creates the table it is asked for, so a reader left
-- pointing at `titleNames` puts back the store migration 18 deleted.
function Titles.NameOf(titleID)
    local live = Blizzard.GetTitleName and Blizzard.GetTitleName(titleID)

    if live and live ~= "" then
        return live
    end

    return "Title " .. tostring(titleID)
end

-- OVER THE CLIENT'S WHOLE LIST, NOT OVER WHAT THIS CHARACTER HOLDS. 0.66.0.
--
-- 0.65.0 moved this off the `titleNames` store, which held every title the
-- scan had seen, and onto the character store -- which `Scan` writes only for
-- titles this character KNOWS. Both resolution paths then returned an id only
-- when the logged-in character already had the title, so `/cn title
-- Loremaster` on an alt answered "No known title matches" for a title the
-- main holds. The command's own help is "Show which characters have a title",
-- which is a question about the OTHER characters.
--
-- It also made one branch of the command unreachable: `WhoHas` always
-- includes the current character, so "Not earned by any known character"
-- could never print.
--
-- `Blizzard.GetTitles()` is the full list and is free.
function Titles.Resolve(text)
    local titleID = CN.ToID(text)

    if titleID then
        return titleID
    end

    if not text or text == "" then
        return nil
    end

    local needle  = string.lower(text)
    local matches = {}

    for _, title in ipairs(Blizzard.GetTitles()) do
        local name = title.name or Titles.NameOf(title.titleID)

        if name and string.find(string.lower(name), needle, 1, true) then
            table.insert(matches, { id = title.titleID, name = name })
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
        return states.COMPLETED, "Already earned by this character",
               Titles.NameOf(titleID)
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

        if not counts.scanned then
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

        Print(Titles.NameOf(titleID) .. " |cff8a8f96(" .. titleID .. ")|r")

        local holders = Titles.WhoHas(titleID)

        if #holders == 0 then
            Print("Not earned by any known character.")
        else
            Print("Earned by: " .. table.concat(holders, ", "))
        end
    end,
}
