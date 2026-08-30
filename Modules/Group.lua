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

    -- WITH A GROUP. 0.80.0.
    --
    -- The header of this file states the premise: "Somebody in an instance
    -- WITH A GROUP is not about to go and pick a herb in Durotar." This test
    -- never asked about the group, so it returned "instanced" for a player
    -- standing alone in an old raid -- which is the single most common way
    -- mounts, pets, toys and appearances are farmed in this game, and every
    -- one of those types is in `Group.instancedTypes`. The addon buried the
    -- mount you walked in for by 65%, and explained it with "you are in an
    -- instance with a group", to a player with nobody else there. `/cn
    -- situation` said so out loud: "in a instance with 0 people".
    --
    -- The harness never caught it because its fixture sets the instance and
    -- a party of five together, so the two conditions were never separable.
    if inside and Group.InGroup()
        and (kind == "party" or kind == "raid" or kind == "scenario") then

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

-- INSIDE, WHETHER OR NOT ANYBODY IS WITH YOU. 0.81.0.
--
-- Two different facts were being answered by one word. `Situation()` answers
-- a SOCIAL question -- are other people waiting on you -- and 0.80.0 fixed it
-- to require a group, correctly: soloing an old raid for its mount is not
-- "four people waiting at a boss".
--
-- But it left the OTHER fact unasked. Standing inside any instance, alone or
-- not, a herb in Durotar is not something you can go and do; it is something
-- you can do after a loading screen. Nothing in the ranking knew that, so a
-- solo player in Firelands could be handed an outdoor world quest as the best
-- next thing.
--
-- These are answered separately now, because they are separate questions.
Group.outsidePenalty = 0.5

function Group.InsideInstance()
    local inside, kind = Group.Instance()

    return inside
        and (kind == "party" or kind == "raid" or kind == "scenario")
        or false
end

-- Is this objective somewhere the player would have to leave to reach?
--
-- Answers FALSE for everything when the addon does not know where the player
-- is standing, which is the honest reading of a nil map. `GetPlayerPosition`
-- returns nothing during a loading screen -- and `PLAYER_ENTERING_WORLD`
-- invalidates the ranking, so a re-score is scheduled at exactly that moment.
-- Treating "I do not know yet" as "outside" would halve the score of the boss
-- in the room the player had just loaded into and stamp a sentence saying so.
--
-- UNKNOWN IS NOT OUTSIDE. The same reading applies one level down: the
-- instance-identity walk refuses rather than guessing while `C_Map` is still
-- coming up, and a refusal here means no penalty.
function Group.Outside(objective)
    if type(objective) ~= "table" or not objective.mapID then
        return false
    end

    -- NOT MEMOISED, DELIBERATELY -- AND THIS IS THE SECOND ATTEMPT.
    --
    -- The first stamped the answer with `GetTime()`, on the reasoning that
    -- the player cannot move between two candidates in the same frame. True
    -- in the client and false everywhere else: the offline suite drives many
    -- scenarios inside one frame, so the memo answered the FIRST scenario's
    -- question for all of them and the whole branch silently did nothing.
    --
    -- The cost this was avoiding is one `pcall(IsInInstance)`; the position
    -- read underneath already carries its own single-frame memo. That is not
    -- worth a cache whose correctness depends on the clock advancing.
    if not Group.InsideInstance() then
        return false
    end

    local here = select(1, CN.GetPlayerPosition())

    if not here then
        return false
    end

    if objective.mapID == here then
        return false
    end

    -- AT INSTANCE LEVEL, NOT ZONE LEVEL. 0.81.0's first attempt compared
    -- `ZoneMapID`, which walks up to the first ancestor the client calls a
    -- ZONE -- and most modern instance maps parent into the outdoor zone
    -- around them. So the world quest on the other side of the door compared
    -- EQUAL to the boss in front of the player, and nothing outside was
    -- ranked down at all: the exact opposite of what this branch is for.
    -- `Loremaster.lua` records the same trap for the same function.
    local walk = CN.Blizzard and CN.Blizzard.InstanceMapID

    if not walk then
        return false
    end

    local hereInstance = walk(here)

    if not hereInstance then
        return false
    end

    -- A multi-floor dungeon is several maps and one instance, so two floors
    -- of the same instance compare equal and walking downstairs does not
    -- demote the treasure upstairs.
    return walk(objective.mapID) ~= hereInstance
end

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

------------------------------------------------------------
-- WORK THE GROUP SHARES
------------------------------------------------------------

-- THE OTHER HALF OF PARTY AWARENESS, WHICH WAS NEVER BUILT.
--
-- The addon has known since 0.44.0 that you are in a group and has used that
-- to stop offering solo detours mid-dungeon. It has never used it for the
-- thing a group is actually for: four people standing in a zone, and one of
-- the six quests on the list is one all four of them are carrying.
--
-- That one is worth four times the work of a quest only you have, and every
-- player already knows it -- it is why people say "anyone else need Bloodfen?"
-- out loud. The addon had the information and said nothing.
--
-- LOCAL ONLY, WHICH IS THE WHOLE DESIGN. `C_QuestLog.IsUnitOnQuest` answers
-- from your own client about a unit already in your group. Nothing is sent,
-- no protocol is agreed, no other machine has to be running this addon, and
-- it degrades to silence outside a group. The DECLINED backlog item is
-- addon-to-addon route sharing; this is not that.
Group.sharedBonusPerMember = 0.12
Group.sharedBonusCap       = 0.45

-- HELD ACROSS RANKING PASSES, NOT WITHIN ONE.
--
-- The first version keyed this on `CN.rankingGeneration`, which is bumped by
-- `InvalidateRanking` -- the very thing that triggers a re-rank. So the cache
-- was cleared at exactly the moment it would have been used, and every pass
-- asked the client afresh: measured at 8,151 `IsUnitOnQuest` calls and 7.2 ms
-- for one pass over two hundred candidates in a forty-person raid, against a
-- 0.4 ms budget for `Recommend(25)`.
--
-- The answer changes when the ROSTER changes or when somebody accepts or
-- turns in a quest, and both of those already announce themselves. So the
-- cache lives until one of them does.
local sharedCache = {}
local unitCache   = nil

-- How long an answer about somebody else's quest log is worth trusting. See
-- the header inside `SharedWith`.
Group.sharedCacheSeconds = 30

-- The client's fractional clock where it exists, wall clock otherwise. Split
-- out so a test can move it.
function Group.Now()
    return (GetTime and GetTime()) or (time and time()) or 0
end

function Group.ForgetShared()
    sharedCache = {}
    unitCache   = nil
end

-- The unit tokens of the rest of the group, in the order the client lists
-- them. Empty when solo, which is what makes every path below free.
-- Built once per roster rather than once per candidate. This was called
-- before the cache lookup, so a forty-person raid allocated a forty-entry
-- table and forty concatenated strings for every objective on every pass --
-- 8,400 transient strings per ranking, for a list that changes when somebody
-- joins or leaves.
function Group.Units()
    if unitCache then
        return unitCache
    end

    local size = Group.Size()

    if size < 2 then
        unitCache = {}

        return unitCache
    end

    local units = {}

    if Group.InRaid() then
        for index = 1, math.min(size, 40) do
            table.insert(units, "raid" .. index)
        end
    else
        for index = 1, math.min(size - 1, 4) do
            table.insert(units, "party" .. index)
        end
    end

    unitCache = units

    return units
end

-- How many OTHER people in your group are on this quest.
--
-- Nil rather than zero when the question cannot be asked -- solo, or a client
-- without the API -- because "nobody else needs this" and "there is nobody
-- else" are different statements and only one of them should reach the
-- scorer.
function Group.SharedWith(questID)
    questID = CN.ToID(questID)

    if not questID then
        return nil
    end

    if not C_QuestLog or not C_QuestLog.IsUnitOnQuest then
        return nil
    end

    local units = Group.Units()

    if #units == 0 then
        return nil
    end

    -- BOUNDED BY AGE, BECAUSE NO EVENT CAN INVALIDATE THIS.
    --
    -- The answer comes from `C_QuestLog.IsUnitOnQuest(unit, questID)` -- a
    -- question about somebody ELSE'S quest log -- and the client fires no
    -- event when a party member accepts or hands one in. The invalidation
    -- below subscribes to `QUEST_ACCEPTED` and `QUEST_TURNED_IN`, which fire
    -- only for the player, so it never cleared this at all.
    --
    -- Four people in your group finish the quest and stay grouped: your list
    -- kept the shared-work multiplier and `/cn why` kept saying "4 others
    -- here are on this quest" until somebody left the party.
    --
    -- There is no event to wait for, so the honest answer is a short life
    -- rather than a claim of coverage. Thirty seconds is far cheaper than the
    -- per-candidate cost this cache exists to avoid and far fresher than
    -- "until the roster changes".
    local held = sharedCache[questID]

    if held ~= nil and (Group.Now() - held.at) < Group.sharedCacheSeconds then
        return held.value
    end

    local sharing = 0

    for _, unit in ipairs(units) do
        -- Not the player themselves: `raid1` may be you.
        local isSelf = UnitIsUnit and UnitIsUnit(unit, "player")

        if not isSelf then
            local ok, onIt = pcall(C_QuestLog.IsUnitOnQuest, unit, questID)

            if ok and onIt then
                sharing = sharing + 1
            end
        end
    end

    sharedCache[questID] = { value = sharing, at = Group.Now() }

    return sharing
end

CN.RegisterScoreAdjuster("GroupShared", function(objective, score)
    if not objective or objective.type ~= CN.objectiveTypes.QUEST then
        return score
    end

    local sharing = Group.SharedWith(objective.id)

    -- WITHDRAWN FIRST, like every other adjuster reason in this addon. A
    -- party member logging out has to take their sentence with them, and the
    -- objectives it was stamped on outlive the group.
    if not sharing or sharing <= 0 then
        CN.ClearAdjusterReason(objective, "groupShared")

        return score
    end

    local bonus = math.min(Group.sharedBonusCap,
        sharing * Group.sharedBonusPerMember)

    CN.AddAdjusterReason(objective, "groupShared",
        sharing == 1 and "one other person here is on this quest"
        or (sharing .. " others here are on this quest"))

    return score * (1 + bonus)
end)

CN.RegisterScoreAdjuster("Group", function(objective, score)
    local situation = Group.Situation()

    -- WHAT IS NO LONGER TRUE IS WITHDRAWN FIRST.
    --
    -- Both sentences below describe the player's situation at the moment of
    -- scoring, and both used to be one-way: once stamped onto a cached
    -- objective they stayed there through every later pass. Every pass now
    -- starts by taking back the ones that do not apply, so the explanation
    -- and the multiplier always agree.
    if situation ~= "dead" then
        CN.ClearAdjusterReason(objective, "groupDead")
    end

    if situation ~= "instanced" then
        CN.ClearAdjusterReason(objective, "groupInstanced")
    end

    -- THE LOCATION SENTENCE IS WITHDRAWN ON THE BRANCH'S OWN TERMS.
    --
    -- Withdrawing it only on LEAVING the instance was the same one-way
    -- stamping this function's own doctrine forbids sixty lines above: the
    -- branch below can decline for reasons other than the doorway -- the
    -- player's map has not resolved yet, the objective turns out to be in
    -- here -- and in every one of those the sentence outlived its multiplier
    -- for the rest of the run.
    --
    -- Computed first, cleared first, applied last. `Outside` is nil-safe on
    -- a nil objective, which is how this function is called by the reason
    -- sweep.
    local outside = Group.Outside(objective)

    if not outside then
        CN.ClearAdjusterReason(objective, "groupOutside")
    end

    if situation == "dead" then
        -- EXCEPT THE BODY.
        --
        -- The corpse is the one thing that IS actionable while dead;
        -- demoting it with everything else would bury the answer under the
        -- list it is supposed to replace.
        if objective and objective.corpse then
            return score
        end

        -- Unguarded on `objective.reasons`, deliberately. The guard used to
        -- be here and not on the instanced branch below, and most providers
        -- build objectives with no `reasons` field -- so for those the
        -- fivefold penalty was applied with nothing on screen saying why.
        -- `AddAdjusterReason` creates the table itself.
        CN.AddAdjusterReason(objective, "groupDead",
            "you are dead" .. CN.DASH .. "this is for after")

        return score * Group.deadPenalty
    end

    if situation == "instanced"
        and objective
        and Group.instancedTypes[objective.type] then

        CN.AddAdjusterReason(objective, "groupInstanced",
            "outside work, and you are in an instance with a group")

        return score * Group.instancedPenalty
    end

    -- BY WHERE IT IS, NOT BY WHAT IT IS. 0.81.0.
    --
    -- The branch above works from a list of TYPES, which is a proxy for
    -- "outdoors" and a bad one in both directions: it demotes the mount that
    -- drops from the boss you are standing next to, and it says nothing
    -- about the world quest three zones away, because QUEST is not on the
    -- list.
    --
    -- The addon already knows where things are. Inside an instance, anything
    -- with a KNOWN map that is not this instance's map needs a loading screen
    -- first, and that is true of every type equally. Anything with no map --
    -- a collection, a currency, the mount off this raid's last boss -- is not
    -- location-bound and is left exactly where it was, which is the case the
    -- type list got wrong.
    if outside then
        CN.AddAdjusterReason(objective, "groupOutside",
            "outside" .. CN.DASH .. "you would have to leave first")

        return score * Group.outsidePenalty
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
-- WHERE YOUR BODY IS.
--
-- The addon has recognised death since 0.43.0 and ranked everything else down
-- for it -- which is right, and is only half an answer. A dead player's next
-- action is a corpse run, and the addon knew that, said so in a sentence, and
-- then could not point at the one place that mattered.
--
-- `C_DeathInfo.GetCorpseMapPosition` answers with the map position of your
-- own corpse. Guarded like every other client call: a client that will not
-- say returns nothing and the sentence stays a sentence.
function Group.CorpseTarget()
    if not Group.IsGhost() then
        return nil
    end

    if not C_DeathInfo or not C_DeathInfo.GetCorpseMapPosition then
        return nil
    end

    local mapID = CN.GetPlayerPosition()

    if not mapID then
        return nil
    end

    local ok, position = pcall(C_DeathInfo.GetCorpseMapPosition, mapID)

    if not ok or not position then
        return nil
    end

    local x, y

    if position.GetXY then
        local gotXY, gx, gy = pcall(position.GetXY, position)

        if gotXY then
            x, y = gx, gy
        end
    end

    x = x or position.x
    y = y or position.y

    if not x or not y or (x == 0 and y == 0) then
        return nil
    end

    return { mapID = mapID, x = x, y = y, title = "Your corpse" }
end

------------------------------------------------------------
-- THE ONE THING WORTH DOING WHILE YOU ARE DEAD
------------------------------------------------------------

-- A dead player's next action is not the recommendation list -- it is their
-- body. The addon has said so in a sentence since 0.43.0 while ranking
-- everything else down, and never once pointed at the place.
--
-- Offered as an ordinary candidate, so the arrow, the map pin, `/cn go` and
-- the heads-up display all pick it up without any of them needing to know
-- what a corpse is. Weighted far above anything else, because while you are a
-- ghost nothing else is actionable at all.
CN.RegisterCandidateProvider("Corpse", function()
    local corpse = Group.CorpseTarget()

    if not corpse then
        return {}
    end

    return {
        CN.NewObjective({
            id              = "body",
            type            = CN.objectiveTypes.CORPSE,
            name            = "Run to your body",
            completionValue = 40,
            travelCost      = 0,
            mapID           = corpse.mapID,
            x               = corpse.x,
            y               = corpse.y,
            corpse          = true,
            reasons         = { "you are a ghost; everything else keeps" },
        }),
    }
end, { volatile = true, events = { "PLAYER_DEAD", "PLAYER_ALIVE",
                                   "PLAYER_UNGHOST" } })

function Group.Notice()
    local situation = Group.Situation()

    if situation == "dead" then
        if Group.IsGhost() then
            local corpse = Group.CorpseTarget()

            if corpse then
                return "You are a ghost. Your body is marked" .. CN.DASH .. "the rest of "
                    .. "this keeps."
            end

            return "You are a ghost. Your body first" .. CN.DASH .. "the rest of this "
                .. "keeps."
        end

        return "You are dead. Release or accept a resurrection first."
    end

    local _, kind = Group.Instance()

    local where = (kind == "raid" and "a raid" or "an instance")

    if situation == "instanced" then
        -- "a instance". 0.80.0. Two words, one article, and it had been in
        -- every `/cn situation` since 0.44.0.
        return "You are in " .. where
            .. " with " .. Group.Size() .. " people; outside work is ranked "
            .. "down until you leave."
    end

    -- AND ALONE INSIDE IS STILL INSIDE. 0.81.0.
    --
    -- 0.80.0 stopped calling a solo instance run "instanced", which was
    -- right, and left this function with nothing to say about it -- so
    -- `/cn situation` reported "solo", and `/cn plan` refused with the
    -- generic "not while you are in the middle of that". The doorway is a
    -- fact about the player whether or not anybody came with them.
    if Group.InsideInstance() then
        return "You are in " .. where .. " on your own; what is out in the "
            .. "world is ranked down until you leave, and what is in here "
            .. "with you is not."
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
        Group.ForgetShared()

        CN.InvalidateRanking()
    end)
end

-- AND WHEN YOUR OWN QUEST LOG CHANGES.
--
-- Not theirs: the client fires no event for another unit's quest log, which
-- is why the cache above has a life rather than an invalidation. This still
-- earns its place -- accepting a quest yourself is the moment you start
-- asking whether the group is on it. Held across ranking passes otherwise: the cache exists
-- because a forty-person raid is forty client calls per quest, and clearing
-- it on the event that triggers the re-rank would mean it never hit.
for _, event in ipairs({ "QUEST_ACCEPTED", "QUEST_TURNED_IN" }) do
    CN:RegisterEvent(event, function()
        Group.ForgetShared()
    end)
end

CN:RegisterCommand{
    name    = "situation",
    aliases = { "state" },
    order   = 36,
    help    = "What the addon thinks you are in the middle of.",
    handler = function()
        local situation = Group.Situation()

        -- TRANSLATED WHERE IT IS SHOWN, NOT WHERE IT IS DECIDED.
        --
        -- `Situation()` returns an identifier that four call sites compare
        -- against; translating the return value would break every one of
        -- them. The four words are translated in all ten locale files and
        -- were never looked up, because the only place a player reads them is
        -- here.
        Print("Situation: |cffffc74f" .. CN.L[situation] .. "|r")

        local inside, kind = Group.Instance()

        Print("  group: " .. (Group.InGroup()
            and (Group.Size() .. (Group.InRaid() and " (raid)" or " (party)"))
            or CN.L["solo"]))
        Print("  instance: " .. (inside and kind or "no"))
        Print("  alive: " .. CN.YesNo(not Group.IsDead()))

        local notice = Group.Notice()

        if notice then
            Print("|cffffc74f" .. notice .. "|r")
        else
            Print("|cff8a8f96Nothing about your situation is changing the "
                .. "ranking right now.|r")
        end
    end,
}

return Group
