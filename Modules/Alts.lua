-- Modules/Alts.lua
-- Completion Navigator :: which character should be doing this.
--
-- The addon has known the answer for a while and had no way to volunteer it.
-- `Warband.WhoShould` answers one objective at a time, when asked, buried in
-- `/cn why`. The question a player actually has is the other way round:
--
--   "Is the character I am logged into the right one to be playing tonight?"
--
-- Nothing answered that. Every recommendation was implicitly "do this, here,
-- now, as you", even when the honest answer was "your Druid is two quests
-- from the same reward and this reputation does not carry across anyway".
--
-- WHAT THIS CAN AND CANNOT KNOW.
--
-- Everything here is built from what each character recorded the last time it
-- logged in. That is a real limitation and it is not a small one: a character
-- last seen three weeks ago is described as it was three weeks ago. The addon
-- says so rather than presenting stale data as current, and weights a
-- recommendation down as it ages -- a suggestion to switch to a character
-- whose data predates a patch is worth less than one about yesterday's.
--
-- It also refuses to recommend switching for anything account-wide. If the
-- progress carries across the Warband, the character doing it is irrelevant
-- and saying otherwise would be advice that costs a loading screen and buys
-- nothing.

local ADDON_NAME, CN = ...

local Alts = CN:RegisterModule("Alts")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint

------------------------------------------------------------
-- STALENESS
------------------------------------------------------------

-- How old a character's data is, in days.
function Alts.AgeDays(character)
    if not character or not character.lastSeen then
        return nil
    end

    return (time() - character.lastSeen) / 86400
end

-- Past this, the addon still reports what it knows but stops making
-- suggestions from it. A month-old snapshot of a character is a description
-- of a character that may not exist in that form any more.
Alts.staleDays = 30

function Alts.DescribeAge(character)
    local days = Alts.AgeDays(character)

    if not days then
        return "never seen"
    end

    if days < 1 then
        return "today"
    end

    if days < 2 then
        return "yesterday"
    end

    if days < 14 then
        return string.format("%d days ago", math.floor(days))
    end

    return string.format("%d weeks ago", math.floor(days / 7))
end

------------------------------------------------------------
-- WHAT IS WORTH SWITCHING FOR
------------------------------------------------------------

-- Only character-specific work can justify a switch. Account-wide progress
-- is, by definition, indifferent to who does it.
Alts.switchableTypes = {
    REPUTATION = true,
    RECIPE     = true,
    PROFESSION = true,
    TITLE      = true,
    QUEST      = true,
}

-- One assignment: a character, a reason, and what it is for.
local function NewAssignment(key, character, objective, reason)
    return {
        key       = key,
        name      = character and character.name or key,
        realm     = character and character.realm,
        class     = character and character.class,
        level     = character and character.level,
        ageDays   = Alts.AgeDays(character),
        objective = objective,
        reason    = reason,
    }
end

-- For each of the top recommendations, ask whether somebody else should be
-- doing it.
--
-- Bounded deliberately: this walks the roster per objective, and answering
-- for two hundred candidates would cost more than the answer is worth. The
-- things a player will actually do next are the things worth asking about.
Alts.considered = 20

function Alts.Assignments()
    local assignments = {}

    if not CN.Recommend then
        return assignments
    end

    local warband = CN:GetModule("Warband")

    if not warband or not warband.WhoShould then
        return assignments
    end

    local seen = {}

    for _, objective in ipairs(CN.Recommend(Alts.considered) or {}) do
        if Alts.switchableTypes[objective.type] then
            local ok, bestKey, detail, scope =
                pcall(warband.WhoShould, objective.type, objective.id)

            -- "account-wide" is a real answer meaning the question does not
            -- apply, and must never become a suggestion to switch.
            if ok and bestKey and scope ~= "account-wide"
                and bestKey ~= CN.characterKey then

                local character = CN.db and CN.db.characters
                    and CN.db.characters[bestKey]

                local age = Alts.AgeDays(character)

                if not age or age <= Alts.staleDays then
                    local key = bestKey .. "|" .. tostring(objective.type)
                        .. "|" .. tostring(objective.id)

                    if not seen[key] then
                        seen[key] = true

                        table.insert(assignments,
                            NewAssignment(bestKey, character, objective,
                                detail and (scope .. ": " .. detail) or scope))
                    end
                end
            end
        end
    end

    return assignments
end

-- Grouped by character, because "switch to this one" is the decision, and
-- three reasons to switch to the same character is a stronger case than one.
function Alts.ByCharacter()
    local grouped, order = {}, {}

    for _, assignment in ipairs(Alts.Assignments()) do
        if not grouped[assignment.key] then
            grouped[assignment.key] = {
                key     = assignment.key,
                name    = assignment.name,
                realm   = assignment.realm,
                class   = assignment.class,
                level   = assignment.level,
                ageDays = assignment.ageDays,
                items   = {},
            }

            table.insert(order, assignment.key)
        end

        table.insert(grouped[assignment.key].items, assignment)
    end

    local rows = {}

    for _, key in ipairs(order) do
        table.insert(rows, grouped[key])
    end

    -- The strongest case first: most reasons, then freshest data.
    table.sort(rows, function(a, b)
        if #a.items ~= #b.items then
            return #a.items > #b.items
        end

        return (a.ageDays or math.huge) < (b.ageDays or math.huge)
    end)

    return rows
end

------------------------------------------------------------
-- THE VERDICT
------------------------------------------------------------

-- Should you be playing somebody else?
--
-- Answers "no" far more often than "yes", and that is correct. A tool that
-- suggests a loading screen every time you log in is a tool people turn off.
Alts.minimumReasons = 2

function Alts.Verdict()
    local rows = Alts.ByCharacter()

    if #rows == 0 then
        return nil, "This character is the right one for everything on the list."
    end

    local best = rows[1]

    if #best.items < Alts.minimumReasons then
        return nil, string.format(
            "Nothing worth a loading screen. %s could do 1 of these, which is "
            .. "not enough to switch for.", tostring(best.name))
    end

    return best, string.format("%s could do %d of these.",
        tostring(best.name), #best.items)
end

------------------------------------------------------------
-- COMMAND
------------------------------------------------------------

CN:RegisterCommand{
    name    = "alts",
    -- No aliases. `who` and `warband` were declared here and both are real
    -- commands registered by Modules/Warband.lua, which loads later and
    -- overwrote them -- so these two entries have never resolved to anything
    -- in this file, while the help listed all three side by side as if they
    -- were different answers.
    aliases = { "alt", "characters" },
    order   = 12,
    help    = "Which character should be doing what, and whether to switch.",
    handler = function()
        local warband = CN:GetModule("Warband")

        if not warband then
            Print("The Warband module is not loaded.")
            return
        end

        local roster = warband.Roster()

        if #roster <= 1 then
            Print("Only this character has been seen. Log in on another and "
                .. "it will be recorded.")
            return
        end

        local best, verdict = Alts.Verdict()

        Print(verdict)

        if best then
            Print("|cffffc74f" .. tostring(best.name) .. "|r"
                .. (best.level and (" (" .. best.level .. ")") or "")
                .. " |cff8a8f96last played "
                .. Alts.DescribeAge({ lastSeen = time() - ((best.ageDays or 0) * 86400) })
                .. "|r")

            for _, item in ipairs(best.items) do
                CN.PrintLine("  |cffffc74f" .. tostring(item.objective.name)
                    .. "|r |cff8a8f96" .. tostring(item.reason) .. "|r")
            end
        end

        Print(" ")
        Print("Your Warband:")

        for _, row in ipairs(roster) do
            local character = CN.db and CN.db.characters
                and CN.db.characters[row.key]

            CN.PrintLine(string.format("  %s%-18s|r %-4s %-10s |cff8a8f96%s|r",
                row.isCurrent and "|cff73b873" or "|cfff2f4f6",
                tostring(row.name),
                tostring(row.level or "?"),
                tostring(row.class or ""),
                Alts.DescribeAge(character)))
        end

        Print("|cff8a8f96Everything here is what each character recorded the "
            .. "last time it logged in.|r")
    end,
}

return Alts
