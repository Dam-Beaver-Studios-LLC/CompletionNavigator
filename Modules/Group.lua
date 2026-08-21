-- Modules/Group.lua
-- Completion Navigator :: the state the player is actually in.
--
-- Two facts the addon has never read, both of which change what a sensible
-- next action is, and both of which the client reports for free.
--
-- BEING DEAD.
--
-- A dead player's next action is not "collect a battle pet". It is "get back
-- to your body". Until 0.43.0 the addon carried on recommending as though
-- nothing had happened, which is not merely unhelpful -- it is the clearest
-- possible signal that the addon is not paying attention.
--
-- BEING IN A GROUP.
--
-- The addon behaved identically whether you were alone or standing in a
-- dungeon with four other people. Somebody in an instance with a group is not
-- about to go and pick a herb in Durotar, and a recommendation that says so
-- is noise at best and a reason to close the window at worst.
--
-- WHAT THIS DELIBERATELY IS NOT.
--
-- It is not addon-to-addon communication. No messages are sent, no protocol
-- is defined, and nothing depends on anybody else running this addon. That
-- design needs versioned messages and matching builds on both machines, and
-- it becomes a support burden the moment either side is stale. Everything
-- here is read from the client, about this player, on this machine.

local ADDON_NAME, CN = ...

local Group = CN:RegisterModule("Group")

local Print = CN.Print

------------------------------------------------------------
-- STATE
------------------------------------------------------------

function Group.IsDead()
    if UnitIsDeadOrGhost then
        local ok, dead = pcall(UnitIsDeadOrGhost, "player")

        if ok then
            return dead and true or false
        end
    end

    return false
end

function Group.IsGhost()
    if UnitIsGhost then
        local ok, ghost = pcall(UnitIsGhost, "player")

        if ok then
            return ghost and true or false
        end
    end

    return false
end

function Group.Size()
    if GetNumGroupMembers then
        local ok, count = pcall(GetNumGroupMembers)

        if ok and type(count) == "number" then
            return count
        end
    end

    return 0
end

function Group.InGroup()
    return Group.Size() > 1
end

function Group.InRaid()
    if IsInRaid then
        local ok, raid = pcall(IsInRaid)

        if ok then
            return raid and true or false
        end
    end

    return false
end

-- Returns inInstance, kind ("party", "raid", "scenario", "pvp", "none").
function Group.Instance()
    if not IsInInstance then
        return false, "none"
    end

    local ok, inside, kind = pcall(IsInInstance)

    if not ok then
        return false, "none"
    end

    return inside and true or false, kind or "none"
end

-- One word for what the player is doing, which is all the ranking needs.
function Group.Situation()
    if Group.IsDead() then
        return "dead"
    end

    local inside, kind = Group.Instance()

    if inside and (kind == "party" or kind == "raid" or kind == "scenario") then
        return "instanced"
    end

    if Group.InGroup() then
        return "grouped"
    end

    return "solo"
end

------------------------------------------------------------
-- WHAT IT CHANGES
------------------------------------------------------------

-- Types that make no sense to walk off and do while four other people are
-- waiting at a boss. NOT hidden -- the player asked to see them at some point
-- and the addon does not un-ask that -- just pushed down.
Group.instancedPenalty = 0.35

Group.instancedTypes = {
    [CN.objectiveTypes.PET]         = true,
    [CN.objectiveTypes.TOY]         = true,
    [CN.objectiveTypes.MOUNT]       = true,
    [CN.objectiveTypes.APPEARANCE]  = true,
    [CN.objectiveTypes.EXPLORATION] = true,
    [CN.objectiveTypes.RARE]        = true,
    [CN.objectiveTypes.TREASURE]    = true,
    [CN.objectiveTypes.VENDOR]      = true,
    [CN.objectiveTypes.PROFESSION]  = true,
    [CN.objectiveTypes.RECIPE]      = true,
}

-- While dead, everything is worth less than getting up. The multiplier is
-- deliberately not zero: the list still answers "what next", it just stops
-- pretending the player can act on it this second.
Group.deadPenalty = 0.2

CN.RegisterScoreAdjuster("Group", function(objective, score)
    local situation = Group.Situation()

    if situation == "dead" then
        if objective and objective.reasons then
            table.insert(objective.reasons, "you are dead -- this is for after")
        end

        return score * Group.deadPenalty
    end

    if situation == "instanced"
        and objective
        and Group.instancedTypes[objective.type] then

        if objective.reasons then
            table.insert(objective.reasons,
                "outside work, and you are in an instance with a group")
        end

        return score * Group.instancedPenalty
    end

    return score
end)

------------------------------------------------------------
-- SAYING SO
------------------------------------------------------------

-- The line the recommendation prints above everything else when the situation
-- makes the list beside the point. Nil when there is nothing to say, which is
-- most of the time -- an addon that comments on your circumstances constantly
-- is an addon people turn off.
function Group.Notice()
    local situation = Group.Situation()

    if situation == "dead" then
        if Group.IsGhost() then
            return "You are a ghost. Your body first -- the rest of this "
                .. "keeps."
        end

        return "You are dead. Release or accept a resurrection first."
    end

    if situation == "instanced" then
        local _, kind = Group.Instance()

        return "You are in a " .. (kind == "raid" and "raid" or "instance")
            .. " with " .. Group.Size() .. " people; outside work is ranked "
            .. "down until you leave."
    end

    return nil
end

-- The situation changes what is worth doing, so the order has to be rebuilt.
-- Cheap: this bumps the ranking generation rather than rebuilding providers,
-- because no candidate's data changed -- only its weighting.
for _, event in ipairs({
    "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST",
    "GROUP_ROSTER_UPDATE", "PLAYER_ENTERING_WORLD",
}) do
    CN:RegisterEvent(event, function()
        CN.InvalidateRanking()
    end)
end

CN:RegisterCommand{
    name    = "situation",
    aliases = { "state" },
    order   = 36,
    help    = "What the addon thinks you are in the middle of.",
    handler = function()
        local situation = Group.Situation()

        Print("Situation: |cffffff00" .. situation .. "|r")

        local inside, kind = Group.Instance()

        Print("  group: " .. (Group.InGroup()
            and (Group.Size() .. (Group.InRaid() and " (raid)" or " (party)"))
            or "solo"))
        Print("  instance: " .. (inside and kind or "no"))
        Print("  alive: " .. CN.YesNo(not Group.IsDead()))

        local notice = Group.Notice()

        if notice then
            Print("|cffffd100" .. notice .. "|r")
        else
            Print("|cff999999Nothing about your situation is changing the "
                .. "ranking right now.|r")
        end
    end,
}

return Group
