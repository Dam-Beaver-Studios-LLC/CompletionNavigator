-- Modules/Professions.lua
-- Completion Navigator :: professions, skill levels, and recipes.
--
-- Two important constraints shape this module.
--
-- 1. Professions are character-specific. Which alt has Alchemy at what
--    skill is exactly the Warband question, so profession state is stored
--    on the character profile.
--
-- 2. Recipe enumeration ONLY works while a trade skill window is open.
--    C_TradeSkillUI.GetAllRecipeIDs returns nothing otherwise. This is a
--    hard client restriction, not a design choice, so recipes are captured
--    opportunistically whenever the player opens a profession and are then
--    persisted. The addon tells the player which professions it is still
--    waiting to see rather than silently reporting zero.

local ADDON_NAME, CN = ...

local Professions = CN:RegisterModule("Professions")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

------------------------------------------------------------
-- STORAGE
------------------------------------------------------------

local function CharacterStore(character)
    character = character or CN.character

    if not character then
        return nil
    end

    character.professions = character.professions or {}

    return character.professions
end

-- Recipes are keyed by skill line, then recipe ID. Known-ness is per
-- character, so it lives under the character; the recipe's name is shared.
local function RecipeNames()
    return CN.Account("recipeNames")
end

local function CharacterRecipes(character)
    character = character or CN.character

    if not character then
        return nil
    end

    character.recipes = character.recipes or {}

    return character.recipes
end

Professions.CharacterStore   = CharacterStore
Professions.RecipeNames      = RecipeNames
Professions.CharacterRecipes = CharacterRecipes

------------------------------------------------------------
-- PROFESSION SCAN
------------------------------------------------------------

function Professions.Scan()
    local store = CharacterStore()

    if not store then
        return 0
    end

    local lines = Blizzard.GetProfessionSkillLines()

    for _, line in ipairs(lines) do
        local existing = store[line.skillLineID]

        -- WHAT WAS CAPTURED SURVIVES THE RESCAN.
        --
        -- This rebuilt the row wholesale and carried over only
        -- `recipesSeen`, so opening your Alchemy window (which records how
        -- many recipes you know of how many there are) and then logging out
        -- lost both numbers -- Scan runs on every login. The display branches
        -- on `recipesSeen` alone, so it then printed "(nil of nil recipes)".
        --
        -- Rank and name come from the client and are refreshed; the recipe
        -- counts come from a window the player has to open and cannot be.
        store[line.skillLineID] = {
            skillLineID  = line.skillLineID,
            name         = line.name,
            rank         = line.rank,
            maxRank      = line.maxRank,
            recipesSeen  = existing and existing.recipesSeen or false,
            recipeTotal  = existing and existing.recipeTotal or nil,
            recipeKnown  = existing and existing.recipeKnown or nil,
            recipesAt    = existing and existing.recipesAt or nil,
        }
    end

    if CN.character then
        CN.character.professionsScanned = time()
    end

    -- The Professions provider reads this store, and nothing told it the
    -- store had been rewritten -- so a scan left the recommendations built
    -- from the state before it.
    CN.MarkScanned("professions")

    return #lines
end

------------------------------------------------------------
-- RECIPE CAPTURE
------------------------------------------------------------

-- Called when a trade skill window is open and ready. Everything about
-- this function is opportunistic by necessity.
function Professions.CaptureOpenProfession()
    if not Blizzard.IsTradeSkillReady() then
        return false, 0, 0
    end

    local skillLineID, professionName = Blizzard.GetOpenTradeSkillLine()

    if not skillLineID then
        return false, 0, 0
    end

    local names    = RecipeNames()
    local mine     = CharacterRecipes()
    local store    = CharacterStore()

    if not mine or not store then
        return false, 0, 0
    end

    local recipeIDs = Blizzard.GetAllRecipeIDs()

    local seen, known = 0, 0

    for _, recipeID in ipairs(recipeIDs) do
        local info = Blizzard.GetRecipeInfo(recipeID)

        if info then
            seen = seen + 1

            if info.name and info.name ~= "" then
                names[recipeID] = info.name

                -- The name index is now stale.
                Professions.nameRevision = (Professions.nameRevision or 0) + 1
            end

            if info.learned then
                known = known + 1

                mine[recipeID] = skillLineID
            else
                mine[recipeID] = nil
            end
        end
    end

    store[skillLineID] = store[skillLineID] or {
        skillLineID = skillLineID,
        name        = professionName,
    }

    store[skillLineID].recipesSeen  = true
    store[skillLineID].recipeTotal  = seen
    store[skillLineID].recipeKnown  = known
    store[skillLineID].recipesAt    = time()

    CN.MarkScanned("recipes")

    return true, seen, known
end

------------------------------------------------------------
-- SUMMARY
------------------------------------------------------------

function Professions.Summary(character)
    local store = CharacterStore(character) or {}

    local rows = {}

    for _, record in pairs(store) do
        table.insert(rows, record)
    end

    table.sort(rows, function(a, b) return (a.name or "") < (b.name or "") end)

    return rows
end

-- Professions this character has but whose recipe list has never been seen.
function Professions.AwaitingRecipeCapture(character)
    local waiting = {}

    for _, record in pairs(CharacterStore(character) or {}) do
        if not record.recipesSeen then
            table.insert(waiting, record.name or ("skill line " .. record.skillLineID))
        end
    end

    table.sort(waiting)

    return waiting
end

-- Which characters know a recipe, for the Warband question.
function Professions.WhoKnows(recipeID)
    local holders = {}

    for key, character in CN.Characters() do
        if character.recipes and character.recipes[recipeID] then
            table.insert(holders, key)
        end
    end

    table.sort(holders)

    return holders
end

-- Best character for a profession, by skill rank.
function Professions.BestCharacterFor(skillLineID)
    local bestKey, bestRecord

    for key, character in CN.Characters() do
        local record = character.professions and character.professions[skillLineID]

        if record and (not bestRecord or (record.rank or 0) > (bestRecord.rank or 0)) then
            bestKey    = key
            bestRecord = record
        end
    end

    return bestKey, bestRecord
end

------------------------------------------------------------
-- ELIGIBILITY
------------------------------------------------------------

------------------------------------------------------------
-- CANDIDATES
------------------------------------------------------------

-- A profession below its cap is one of the few completion objectives that is
-- unambiguously actionable: you know the skill, you know the number, and the
-- work is entirely in your hands.
--
-- Character-scoped on purpose. Professions do not carry across a Warband, and
-- pretending otherwise would put an alt's blacksmithing in front of you.
CN.RegisterCandidateProvider("Professions", function()
    local store = CharacterStore()

    if not store then
        return {}
    end

    local candidates = {}

    for skillLineID, record in pairs(store) do
        local rank    = record.rank or 0
        local maxRank = record.maxRank or 0

        local remaining = maxRank - rank

        if maxRank > 0
            and remaining > 0
            and not CN.IsIgnored(CN.objectiveTypes.PROFESSION, skillLineID)
            and not CN.IsDeferred(CN.objectiveTypes.PROFESSION, skillLineID) then

            local fraction = rank / maxRank

            -- Nearly finished is worth more than barely started: the last few
            -- points are the ones a nudge actually completes.
            local value = (fraction >= 0.9) and 3 or (fraction >= 0.5) and 2 or 1

            local reasons = {
                rank .. " of " .. maxRank .. ", " .. remaining .. " to go",
            }

            if not record.recipesSeen then
                table.insert(reasons,
                    "open its window once so recipes can be recorded")
            end

            table.insert(candidates, CN.NewObjective({
                id              = skillLineID,
                type            = CN.objectiveTypes.PROFESSION,
                name            = record.name,
                accountWide     = false,
                characterSpecific = true,
                completionValue = value,
                reasons         = reasons,
            }))
        end
    end

    local kept, dropped = CN.CapCandidates(candidates)

    CN.providerTruncation["Professions"] = {
        considered = #kept + dropped,
        dropped    = dropped,
    }

    return kept
end, { events = { "TRADE_SKILL_LIST_UPDATE" }, cooldown = 5 })

CN.RegisterEligibilityChecker(CN.objectiveTypes.RECIPE, function(recipeID)
    local states = CN.objectiveStates
    local mine   = CharacterRecipes()

    if mine and mine[recipeID] then
        return states.COMPLETED, "Already known by this character", RecipeNames()[recipeID]
    end

    local holders = Professions.WhoKnows(recipeID)

    if #holders > 0 then
        return states.REQUIRES_OTHER_CHARACTER,
               CN.blockReasons.BETTER_CHARACTER,
               table.concat(holders, ", ")
    end

    return states.UNKNOWN, "No recipe data; open the profession window once", nil
end)

CN.RegisterEligibilityChecker(CN.objectiveTypes.PROFESSION, function(skillLineID)
    local states = CN.objectiveStates
    local store  = CharacterStore()
    local record = store and store[skillLineID]

    if not record then
        local bestKey = Professions.BestCharacterFor(skillLineID)

        if bestKey then
            return states.REQUIRES_OTHER_CHARACTER,
                   CN.blockReasons.MISSING_PROFESSION,
                   bestKey
        end

        return states.INELIGIBLE, CN.blockReasons.MISSING_PROFESSION, nil
    end

    if record.maxRank and record.rank and record.rank >= record.maxRank then
        return states.COMPLETED, "Skill is maxed for this expansion", record.name
    end

    return states.AVAILABLE, nil, nil
end)

------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

CN:RegisterEvent("TRADE_SKILL_SHOW", function()
    -- The list is not populated yet at SHOW; wait for the list update.
    DebugPrint("Trade skill window opened.")
end)

CN:RegisterEvent("TRADE_SKILL_LIST_UPDATE", function()
    local captured, seen, known = Professions.CaptureOpenProfession()

    if captured then
        DebugPrint("Captured " .. seen .. " recipes (" .. known .. " known).")
    end
end)

CN:RegisterEvent("SKILL_LINES_CHANGED", function()
    Professions.Scan()
end)

CN:OnLogin(function()
    Professions.Scan()
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "profscan",
    order   = 70,
    help    = "Rescan this character's professions.",
    handler = function()
        local count = Professions.Scan()

        Print("Found " .. count .. " professions on this character.")

        local waiting = Professions.AwaitingRecipeCapture()

        if #waiting > 0 then
            Print("Recipe lists not captured yet for: " .. table.concat(waiting, ", "))
            Print("Open each profession window once; the client only exposes "
                .. "recipes while that window is open.")
        end
    end,
}

CN:RegisterCommand{
    name    = "professions",
    aliases = { "profs" },
    order   = 71,
    help    = "Show profession skill and recipe counts.",
    handler = function()
        local rows = Professions.Summary()

        if #rows == 0 then
            Print("No professions recorded. Run /cn profscan.")
            return
        end

        for _, record in ipairs(rows) do
            local line = record.name .. ": " .. tostring(record.rank)
                .. " / " .. tostring(record.maxRank)

            if record.recipesSeen then
                line = line .. " |cff8a8f96(" .. tostring(record.recipeKnown)
                    .. " of " .. tostring(record.recipeTotal) .. " recipes)|r"
            else
                line = line .. " |cffffc74f(recipes not captured)|r"
            end

            CN.PrintLine(line)
        end

        local waiting = Professions.AwaitingRecipeCapture()

        if #waiting > 0 then
            Print("Open the profession window once for: " .. table.concat(waiting, ", "))
        end
    end,
}

CN:RegisterCommand{
    name    = "recipes",
    order   = 72,
    help    = "Summarize recipe knowledge across the Warband.",
    handler = function()
        local names = RecipeNames()
        local total = CN.CountKeys(names)

        if total == 0 then
            Print("No recipes recorded yet.")
            Print("Open each profession window once with the addon loaded.")
            return
        end

        Print("Recipes seen: " .. total)

        for key, character in CN.Characters() do
            local count = CN.CountKeys(character.recipes)

            if count > 0 then
                CN.PrintLine("  " .. key .. ": " .. count .. " known")
            end
        end
    end,
}

CN:RegisterCommand{
    name    = "recipe",
    args    = "<recipeID or name>",
    order   = 73,
    help    = "Show which characters know a recipe.",
    handler = function(args)
        if args == "" then
            Print("Usage: /cn recipe <recipeID or name>")
            return
        end

        local names    = RecipeNames()
        local recipeID = CN.ToID(args)

        if not recipeID or not names[recipeID] then
            local needle = string.lower(args)

            for id, name in pairs(names) do
                if name and string.find(string.lower(name), needle, 1, true) then
                    recipeID = id
                    break
                end
            end
        end

        if not recipeID or not names[recipeID] then
            Print("No known recipe matches: " .. args)
            return
        end

        Print(names[recipeID] .. " |cff8a8f96(" .. recipeID .. ")|r")

        local holders = Professions.WhoKnows(recipeID)

        if #holders == 0 then
            Print("Not known by any recorded character.")
        else
            Print("Known by: " .. table.concat(holders, ", "))
        end
    end,
}

------------------------------------------------------------
-- NAME LOOKUP
------------------------------------------------------------

-- Lowercased recipe name -> recipeID.
--
-- WHY THIS EXISTS. The item tooltip needed to answer "is this item a recipe
-- I know?", and the only way it could was to walk every recipe name looking
-- for a match -- two string allocations and a substring search per entry,
-- twenty-five hundred of them, on EVERY mouseover. Measured at 0.54ms per
-- tooltip, which is three per cent of a frame for hovering one item, and
-- sweeping a bag or an auction list fires dozens in a second.
--
-- Built once against a revision the scanner bumps, and consulted with two
-- hash lookups.
Professions.nameRevision = Professions.nameRevision or 0

function Professions.NameIndex()
    return CN.Shortlist("RecipeNames", Professions.nameRevision, function()
        local index = {}

        for recipeID, name in pairs(RecipeNames()) do
            if type(name) == "string" and name ~= "" then
                index[string.lower(name)] = recipeID
            end
        end

        return index
    end)
end

-- The words the game puts in front of a recipe's name on the item that
-- teaches it. "Recipe: Flask of Testing" teaches "Flask of Testing".
Professions.teachingPrefixes = {
    "recipe: ", "pattern: ", "plans: ", "formula: ", "schematic: ",
    "design: ", "technique: ", "manuscript: ", "method: ", "glyph: ",
}

-- The recipe an item teaches, or nil. O(1) rather than O(every recipe).
function Professions.RecipeForItem(itemID, itemName)
    local names = RecipeNames()

    -- The item IS the recipe, which is the cheapest case and worth checking
    -- before building anything.
    if itemID and names[itemID] then
        return itemID, false
    end

    if type(itemName) ~= "string" or itemName == "" then
        return nil
    end

    local index = Professions.NameIndex()

    local needle = string.lower(itemName)

    local direct = index[needle]

    if direct then
        return direct, true
    end

    -- Strip a teaching prefix and try again. This replaces a scan over every
    -- recipe with one lookup per known prefix.
    for _, prefix in ipairs(Professions.teachingPrefixes) do
        if string.sub(needle, 1, #prefix) == prefix then
            local taught = index[string.sub(needle, #prefix + 1)]

            if taught then
                return taught, true
            end
        end
    end

    return nil
end
