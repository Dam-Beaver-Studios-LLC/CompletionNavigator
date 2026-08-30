-- Modules/Warband.lua
-- Completion Navigator :: which character should do this.
--
-- The per-character data already exists: reputations, titles, professions
-- and recipes are stored on the character that owns them. What was missing
-- is anything that reads across all of them and answers the question the
-- whole design was built around.
--
-- This module also feeds `characterSuitability`, the second scoring term
-- that was weighted in the formula but never set by anything. An objective
-- your current character is poorly suited to should rank below one they can
-- act on now, and the reason should say why.

local ADDON_NAME, CN = ...

local Warband = CN:RegisterModule("Warband")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint

------------------------------------------------------------
-- ROSTER
------------------------------------------------------------

function Warband.Roster()
    local rows = {}

    for key, character in CN.Characters() do
        table.insert(rows, {
            key      = key,
            name     = character.name,
            realm    = character.realm,
            class    = character.class,
            race     = character.race,
            level    = character.level,
            faction  = character.faction,
            spec     = character.specName,
            lastSeen = character.lastSeen,
            isCurrent = (key == CN.characterKey),

            professions  = CN.CountKeys(character.professions),
            recipes      = CN.CountKeys(character.recipes),
            titles       = CN.CountKeys(character.titles),
            reputations  = CN.CountKeys(character.reputations),
        })
    end

    table.sort(rows, function(a, b)
        if (a.level or 0) ~= (b.level or 0) then
            return (a.level or 0) > (b.level or 0)
        end

        return (a.key or "") < (b.key or "")
    end)

    return rows
end

------------------------------------------------------------
-- WHO SHOULD DO THIS
------------------------------------------------------------

-- Answers for any objective type that has per-character state. Returns
-- bestKey, detail, scope -- where scope explains why the answer is what it
-- is, including "account-wide" meaning the question does not apply.
--
-- THE SCOPE IS A TOKEN. 0.65.0.
--
-- Three places branch on `scope == "account-wide"` and three others PRINT the
-- same value to the player. That is a string doing two jobs, and the addon
-- has ten locale tables: the first translation of that sentence turns all
-- three guards false at once, and `/cn alts` starts recommending a loading
-- screen to switch characters for account-wide progress -- which the file
-- that does the recommending says "must never become a suggestion to switch".
--
-- The tokens are these, and `CN.ScopeText` turns one into a sentence.
CN.scopes = {
    ACCOUNT   = "account-wide",
    CHARACTER = "character",
    UNKNOWN   = "unknown",
}

function CN.ScopeText(scope)
    if scope == CN.scopes.ACCOUNT then
        return CN.L["account-wide"]
    end

    return scope
end
-- THE FRESHEST HOLDER, NOT THE ALPHABETICALLY FIRST.
--
-- `WhoKnows` and `WhoHas` both `table.sort` their holders, which orders them
-- by realm-name and by nothing else. So a deleted alt called Aaathrowaway
-- came back ahead of a main called Zeddicus -- and `Suitability`, seeing a
-- record older than the staleness line, dropped the penalty entirely and
-- concluded nobody was better suited, when somebody played yesterday already
-- knew the thing.
--
-- Fresh first, then alphabetical among equals so the answer is stable.
local function Freshest(holders)
    if type(holders) ~= "table" or #holders == 0 then
        return nil
    end

    local alts = CN:GetModule("Alts")

    if not alts or not alts.AgeDays then
        return holders[1]
    end

    local best, bestAge

    for _, key in ipairs(holders) do
        local record = CN.db and CN.db.characters and CN.db.characters[key]

        -- No stamp is not evidence of age. Treated as fresh, which is the
        -- fail-open direction -- the same one `Suitability` takes.
        local age = alts.AgeDays(record) or 0

        if not best or age < bestAge then
            best, bestAge = key, age
        end
    end

    return best or holders[1]
end

Warband.Freshest = Freshest

-- Returns `bestKey, detail, scope, switchable`.
--
-- THE FOURTH RETURN, AND WHY IT HAD TO EXIST. 0.79.0.
--
-- Two consumers ask this one question and mean different things by it.
--
-- `Warband.Suitability` is a score adjuster: "is this worth doing on THIS
-- character". A recipe another character already knows is worth less here,
-- so it wants the holder and the answer is right.
--
-- `Alts.Assignments` is `/cn alts`, whose entire job is "should you be
-- playing somebody else". For a recipe or a title, the holder is the
-- character who has ALREADY done it -- switching to them cannot do it again,
-- and titles in particular are per-character and unrepeatable. So that
-- surface printed, under the header "Bob could do 2 of these":
--
--     Flask of Alchemical Chaos   already knows it: Bob, Carol
--
-- The addon contradicting itself on one line, in the command written to stop
-- the player wondering.
--
-- `switchable` is false when the named character is the one who has already
-- done it. Absent means true, so every other branch is unchanged.
function Warband.WhoShould(objectiveType, id)
    local types = CN.objectiveTypes

    if objectiveType == types.REPUTATION then
        local module = CN:GetModule("Reputations")

        if not module then
            return nil, nil, "no reputation data"
        end

        local bestKey, bestRecord, accountWide = module.BestCharacterFor(id)

        if accountWide then
            return nil, nil, CN.scopes.ACCOUNT
        end

        if bestKey then
            return bestKey,
                   tostring(module.StandingText(bestRecord)),
                   "highest standing"
        end

        return nil, nil, "no character has this faction recorded"
    end

    if objectiveType == types.RECIPE then
        local module = CN:GetModule("Professions")

        if not module then
            return nil, nil, "no profession data"
        end

        local holders = module.WhoKnows(id)

        -- SOMEBODY ALREADY HAS IT, SO THERE IS NOBODY TO SWITCH TO. 0.79.0.
        --
        -- This returned the holder as the character who SHOULD do it, with
        -- "already knows it" as the reason -- so `/cn alts`, whose entire job
        -- is "should you be playing somebody else", printed
        --
        --     Flask of Alchemical Chaos   already knows it: Bob, Carol
        --
        -- under the header "Bob could do 2 of these". The function answered
        -- "who has this" to a question that asked "who should do this".
        --
        -- A recipe one character knows is not work for another character;
        -- whether some THIRD character with the profession could also learn
        -- it is a question this data cannot answer, and inventing an answer
        -- is worse than saying there is nothing to switch for.
        if #holders > 0 then
            return Freshest(holders), table.concat(holders, ", "),
                "already known by another character", false
        end

        return nil, nil, "no character knows this recipe"
    end

    if objectiveType == types.TITLE then
        local module = CN:GetModule("Titles")

        if not module then
            return nil, nil, "no title data"
        end

        local holders = module.WhoHas(id)

        -- AND A TITLE CANNOT BE EARNED TWICE. 0.79.0. Same correction as the
        -- recipe branch above: switching to the character who already has it
        -- cannot earn it again, so there is nothing to switch for.
        if #holders > 0 then
            return Freshest(holders), table.concat(holders, ", "),
                "already earned by another character", false
        end

        return nil, nil, "no character has this title"
    end

    if objectiveType == types.PROFESSION then
        local module = CN:GetModule("Professions")

        if not module then
            return nil, nil, "no profession data"
        end

        local bestKey, bestRecord = module.BestCharacterFor(id)

        if bestKey then
            return bestKey,
                   tostring(bestRecord and bestRecord.rank) .. " skill",
                   "highest skill"
        end

        return nil, nil, "no character has this profession"
    end

    if objectiveType == types.PET or objectiveType == types.MOUNT
        or objectiveType == types.TOY or objectiveType == types.ACHIEVEMENT
        or objectiveType == types.APPEARANCE then
        return nil, nil, CN.scopes.ACCOUNT
    end

    return nil, nil, "not tracked per character"
end

------------------------------------------------------------
-- SUITABILITY
------------------------------------------------------------

-- Positive when the logged-in character is the right one, negative when
-- somebody else is. Fed into the scoring formula so recommendations stop
-- pointing at work this character cannot usefully do.
function Warband.Suitability(objectiveType, id)
    -- The second return -- the list of character names -- is deliberately
    -- not bound: see the note above this function's return for why it must
    -- not appear in the sentence. 0.79.0.
    local bestKey, _, scope = Warband.WhoShould(objectiveType, id)

    if scope == CN.scopes.ACCOUNT or not bestKey then
        return 0, nil
    end

    if bestKey == CN.characterKey then
        return 1, "you are the best character for this"
    end

    -- A MONTH-OLD SNAPSHOT IS NOT A CHARACTER.
    --
    -- `Alts.staleDays` is 30 and its own comment says why: "Past this, the
    -- addon still reports what it knows but stops making suggestions from
    -- it. A month-old snapshot of a character is a description of a character
    -- that may not exist in that form any more."
    --
    -- The Alts SUGGESTION path honoured that. This one -- which silently
    -- reorders every list, at a penalty of two points, and prints the other
    -- character's name as the reason -- did not, and nothing anywhere in the
    -- addon ever removes a character from the roster. So a deleted or
    -- transferred alt went on penalising every recipe, reputation, title and
    -- profession objective it used to cover, for ever.
    local alts = CN:GetModule("Alts")

    -- `CN.db.characters[key]`, not `CN.Characters()[key]`: that function
    -- returns an ITERATOR, and Alts.lua reads the table directly for the same
    -- reason two files over.
    local record = CN.db and CN.db.characters and CN.db.characters[bestKey]

    if alts and alts.AgeDays and alts.staleDays then
        local age = alts.AgeDays(record)

        if age and age > alts.staleDays then
            return 0, nil
        end
    end

    -- THE SCOPE SENTENCE, NOT A LIST OF NAMES. 0.79.0.
    --
    -- `detail` is a comma-separated list of characters, and this rendered it
    -- as though it explained something: "Bob is better suited (Bob, Carol)".
    -- `scope` is the written reason and is what belongs in a `/cn why` line.
    return -2, bestKey .. " is better suited"
        .. (scope and (" -- " .. tostring(scope)) or "")
end

-- Applied to every candidate before scoring, so no module has to remember
-- to do it.
function Warband.Decorate(objective)
    if type(objective) ~= "table" or not objective.type or not objective.id then
        return objective
    end

    -- WITHDRAWN HERE TOO. This was the one branch in the file that returned
    -- without cleaning up, so an objective that became account-wide kept a
    -- verdict about a character that no longer needs to do it.
    if objective.accountWide then
        objective.characterSuitability = nil

        CN.ClearDecoratorReason(objective, "warband")

        return objective
    end

    local suitability, reason = Warband.Suitability(objective.type, objective.id)

    if suitability == 0 then
        -- No verdict now means no sentence now. Withdrawn rather than left
        -- behind, the same way every adjuster reason has been since 0.51.0.
        objective.characterSuitability = nil

        CN.ClearDecoratorReason(objective, "warband")
    else
        objective.characterSuitability = suitability

        if reason then
            -- Through the keyed mechanism, so the sentence is replaced when
            -- the verdict changes and withdrawn when it stops applying --
            -- rather than appended once per rebuild now that a provider's
            -- tables are reused.
            CN.AddDecoratorReason(objective, "warband", reason)
        end
    end

    return objective
end

CN.RegisterCandidateDecorator("Warband", Warband.Decorate)

------------------------------------------------------------
-- COVERAGE
------------------------------------------------------------

-- What the Warband collectively has, versus what any one character has.
-- This is the number that matters for account completion; a single
-- character's totals understate it.
function Warband.Coverage()
    local professions, recipes, titles = {}, {}, {}

    local characters = 0

    for _, character in CN.Characters() do
        characters = characters + 1

        for skillLineID in pairs(character.professions or {}) do
            professions[skillLineID] = true
        end

        for recipeID in pairs(character.recipes or {}) do
            recipes[recipeID] = true
        end

        for titleID in pairs(character.titles or {}) do
            titles[titleID] = true
        end
    end

    return {
        characters  = characters,
        professions = CN.CountKeys(professions),
        recipes     = CN.CountKeys(recipes),
        titles      = CN.CountKeys(titles),
    }
end

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "warband",
    aliases = { "roster" },
    order   = 17,
    help    = "Show every known character and what they cover.",
    handler = function()
        local rows = Warband.Roster()

        if #rows == 0 then
            Print("No characters recorded yet.")
            return
        end

        Print("Warband (" .. #rows .. " character"
            .. CN.Pluralize(#rows, "") .. "):")

        for _, row in ipairs(rows) do
            local marker = row.isCurrent and "|cff73b873>|r " or "  "

            CN.PrintLine(marker .. row.key
                .. " |cff8a8f96" .. tostring(row.level) .. " "
                .. CN.TokenLabel(row.class or "?")
                .. (row.faction
                    and (" " .. CN.FactionLabel(row.faction)) or "") .. "|r")

            CN.PrintLine("      professions " .. row.professions
                .. ", recipes " .. row.recipes
                .. ", titles " .. row.titles
                .. ", reputations " .. row.reputations)
        end

        local coverage = Warband.Coverage()

        -- THE CAVEAT BELONGS ON THE NUMBER, NOT ONLY ON THE ONE-CHARACTER
        -- CASE.
        --
        -- `CN.Characters()` holds the characters that have logged in with
        -- this addon installed, which for most people is a fraction of the
        -- account. With three of ten alts seen the figure was printed as
        -- plain fact and only the `#rows == 1` case was hedged.
        Print("Combined coverage across the " .. #rows .. " character"
            .. CN.Pluralize(#rows, "") .. " this addon has seen: "
            .. coverage.professions .. " professions, "
            .. coverage.recipes .. " recipes, " .. coverage.titles .. " titles.")

        if #rows == 1 then
            Print("|cffffc74fOnly one character has been seen. Log in on your alts "
                .. "with the addon loaded to make these comparisons useful.|r")
        else
            Print("|cff8a8f96An alt that has never logged in with the addon "
                .. "loaded is not in this total.|r")
        end
    end,
}

CN:RegisterCommand{
    name    = "who",
    args    = "<type> <id>",
    order   = 18,
    help    = "Which character should do something. Types: rep, recipe, title, profession.",
    handler = function(args)
        local kind, value = args:match("^(%S+)%s+(.+)$")

        if not kind or not value then
            -- NAMES RESOLVE FOR TWO OF THE FOUR, AND THE USAGE LINE SAID
            -- FOUR. `RECIPE` and `PROFESSION` have no resolver, so a name
            -- there fell through to "Could not resolve" -- which reads as
            -- "that recipe does not exist" rather than "give me the id".
            Print("Usage: /cn who <rep|title> <id or name>")
            Print("|cff8a8f96       /cn who <recipe|profession> <id>|r")
            Print("|cff8a8f96Recipes and professions are looked up by id "
                .. "only; |cffffc74f/cn recipes|r|cff8a8f96 lists yours.|r")
            return
        end

        kind = string.lower(kind)

        local types = CN.objectiveTypes

        local map = {
            rep        = types.REPUTATION,
            reputation = types.REPUTATION,
            recipe     = types.RECIPE,
            title      = types.TITLE,
            profession = types.PROFESSION,
            prof       = types.PROFESSION,
        }

        local objectiveType = map[kind]

        if not objectiveType then
            Print("Unknown type: " .. kind)
            Print("Use one of: rep, recipe, title, profession")
            return
        end

        -- Resolve names to IDs through the owning module where possible.
        local id = CN.ToID(value)

        if not id then
            if objectiveType == types.REPUTATION then
                local module = CN:GetModule("Reputations")
                id = module and module.Resolve(value)
            elseif objectiveType == types.TITLE then
                local module = CN:GetModule("Titles")
                id = module and module.Resolve(value)
            end
        end

        if not id then
            if objectiveType == types.RECIPE
                or objectiveType == types.PROFESSION then

                Print("Recipes and professions are looked up by id, not by "
                    .. "name: " .. value)
                Print("|cff8a8f96|cffffc74f/cn recipes|r|cff8a8f96 lists the "
                    .. "ones this addon knows about, with their ids.|r")
            else
                Print("Could not resolve: " .. value)
            end

            return
        end

        local bestKey, detail, scope = Warband.WhoShould(objectiveType, id)

        if scope == CN.scopes.ACCOUNT then
            Print("That is account-wide; any character counts.")
            return
        end

        if not bestKey then
            -- The SENTENCE, from the token. See `CN.scopes` above: the same
            -- string was doing both jobs, so translating it would have turned
            -- three guards false at once. 0.65.0.
            Print(CN.ScopeText(scope) .. ".")
            return
        end

        -- BOTH FACTS, EACH IN ITS OWN PLACE. 0.79.0.
        --
        -- This printed `detail` -- the list of characters -- in the
        -- parentheses and threw `scope`, the sentence that explains the
        -- answer, away entirely.
        if bestKey == CN.characterKey then
            Print("This character is the best one for it.")
        else
            Print("Best character: " .. bestKey)
        end

        if scope then
            CN.PrintLine(CN.Muted(tostring(scope)))
        end

        if detail and detail ~= bestKey then
            CN.PrintLine(CN.Muted("Held by: " .. tostring(detail)))
        end
    end,
}

-- WHEN ANOTHER CHARACTER'S PICTURE CHANGES, SAY SO LOUDLY ENOUGH.
--
-- `Warband.Decorate` stamps `characterSuitability` and the "your Druid could
-- do four of these" sentence, and a provider whose rows are unchanged takes
-- the unchanged-provider shortcut and is never re-decorated -- which 0.57.0
-- made the common case. So logging in on an alt, or that alt learning a
-- profession, never reached the rows already on the list.
--
-- `CN.decoratorGeneration` is the hook that defeats the shortcut; Goals,
-- Harvest and Session all use it for the same reason.
--
-- DEBOUNCED, because `UPDATE_FACTION` is in this list and it fires on nearly
-- every reputation tick -- which this addon states in three other files, one
-- of which gives its own provider a five-second cooldown for exactly this
-- reason. Bumping `decoratorGeneration` on every tick turns the
-- unchanged-provider shortcut permanently off while the player is questing,
-- which is when they are gaining reputation continuously and also when they
-- most want `/cn next` to be fast.
-- Five seconds, matching the Reputations provider's own cooldown: the two
-- are answering the same burst.
Warband.rescanSeconds = 5

for _, event in ipairs({
    "PLAYER_ENTERING_WORLD", "UPDATE_FACTION", "SKILL_LINES_CHANGED",
}) do
    CN:RegisterEvent(event, function()
        CN.Debounce("Warband.suitability", Warband.rescanSeconds, function()
            -- Both halves: the counter defeats the identical-list reuse,
            -- and the invalidation is what makes a clean provider rebuild so
            -- that reuse is reached at all. See CN.NoteDecoratorsChanged.
            CN.NoteDecoratorsChanged()
        end)
    end)
end

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
