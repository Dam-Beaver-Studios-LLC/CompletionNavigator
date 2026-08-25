-- Modules/Goals.lua
-- Completion Navigator :: what you are actually working toward.
--
-- Everything else in this addon answers "what should I do next?" from the
-- whole field of what is available. That is the right default, and it is the
-- wrong answer when you have decided you want one specific thing.
--
-- A goal is a target you pin. Once pinned:
--
--   * it becomes a candidate in its own right, even when nothing else would
--     have surfaced it -- an uncollected mount is not normally actionable,
--     but if you have decided you want it, it is;
--   * anything that plausibly leads to it is weighted up, and says so;
--   * /cn goal prints what is actually known about getting it -- the source,
--     where it is, which of your characters is best placed, and what the
--     next concrete step is.
--
-- Goals are account-wide. Deciding you want a mount is not a fact about the
-- character you happened to be playing when you decided it.

local ADDON_NAME, CN = ...

local Goals = CN:RegisterModule("Goals")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

local function Store()
    return CN.Account("goals")
end

Goals.Store = Store

-- How many goals are worth having at once. Beyond a handful, "goal" stops
-- meaning anything and the weighting stops discriminating.
Goals.limit = 10

------------------------------------------------------------
-- TYPES
------------------------------------------------------------

-- Which objective types can be pinned, and what the user types for each.
Goals.types = {
    quest       = CN.objectiveTypes.QUEST,
    achievement = CN.objectiveTypes.ACHIEVEMENT,
    mount       = CN.objectiveTypes.MOUNT,
    pet         = CN.objectiveTypes.PET,
    toy         = CN.objectiveTypes.TOY,
    recipe      = CN.objectiveTypes.RECIPE,
    title       = CN.objectiveTypes.TITLE,
    rep         = CN.objectiveTypes.REPUTATION,
    reputation  = CN.objectiveTypes.REPUTATION,
    rare        = CN.objectiveTypes.RARE,
    currency    = CN.objectiveTypes.CURRENCY,
}

local function ResolveType(text)
    if not text then
        return nil
    end

    return Goals.types[string.lower(text)]
end

Goals.ResolveType = ResolveType

local function Key(objectiveType, id)
    return CN.ObjectiveKey(objectiveType, id)
end

------------------------------------------------------------
-- MANAGING GOALS
------------------------------------------------------------

-- INVALIDATING THE CANDIDATES WAS NOT ENOUGH, AND THE COMMENT SAID IT WAS.
--
-- A goal changes the WEIGHT of rows that are otherwise unchanged, and
-- `userPreference` is not one of the fields the identity comparison looks at
-- -- deliberately, since no provider writes it. So a provider whose rows had
-- not changed took the unchanged-provider shortcut, `Goals.Decorate` never
-- ran, and `/cn goal` did nothing to a quest already in your log while
-- `/cn ungoal` left the +8 and the sentence behind. Both persisted until the
-- owning provider's list actually changed -- which, standing at a vendor
-- managing your goal list, is never.
--
-- `CN.decoratorGeneration` is the hook that defeats the shortcut, and it is
-- what `Harvest.NoteUnlocksChanged` uses one file over for the same reason.
function Goals.NoteChanged()
    Goals.zoneGeneration = (Goals.zoneGeneration or 0) + 1

    -- DELIBERATE: pinning or unpinning is the player acting, and no
    -- provider's cooldown may delay it -- 0.57.0 records that seeing nothing
    -- happen for two seconds reads as the feature being broken.
    --
    -- `NoteDecoratorsChanged` invalidates as well as bumping, so the second
    -- call this used to make is now redundant.
    CN.NoteDecoratorsChanged(true)
end

function Goals.IsGoal(objectiveType, id)
    if not objectiveType or not id then
        return false
    end

    local store = Store()

    if not store or next(store) == nil then
        return false
    end

    return store[Key(objectiveType, id)] ~= nil
end

function Goals.Add(objectiveType, id)
    if not objectiveType or not id then
        return false, "A goal needs a type and an ID."
    end

    local store = Store()

    local key = Key(objectiveType, id)

    if store[key] then
        return false, "That is already a goal."
    end

    if CN.CountKeys(store) >= Goals.limit then
        return false, "You already have " .. Goals.limit
            .. " goals. Clear one first."
    end

    local filters = CN:GetModule("Filters")

    local name = filters and filters.DescribeObjective(objectiveType, id)
        or (objectiveType .. " " .. tostring(id))

    store[key] = {
        type  = objectiveType,
        id    = id,
        name  = name,
        since = time(),
    }

    Goals.NoteChanged()

    return true, name
end

function Goals.Remove(objectiveType, id)
    local store = Store()

    local key = Key(objectiveType, id)

    if not store[key] then
        return false
    end

    local name = store[key].name

    store[key] = nil

    Goals.NoteChanged()

    return true, name
end

function Goals.Clear()
    local store = Store()

    local count = CN.CountKeys(store)

    for key in pairs(store) do
        store[key] = nil
    end

    Goals.NoteChanged()

    return count
end

-- Ordered oldest first, so the list is stable and numbering means something
-- between calls.
function Goals.List()
    local list = {}

    local filters = CN:GetModule("Filters")

    for key, goal in pairs(Store()) do
        -- RE-RESOLVED, NOT FROZEN.
        --
        -- The name was worked out once when the goal was pinned and then
        -- persisted -- and for currencies, recipes, titles, toys and rares
        -- the describer can only answer from a cache the scans fill. Pin one
        -- before the relevant scan and the placeholder was kept forever:
        -- "Currency 3008" in `/cn goals`, in `/cn chase`, and after every
        -- future login, even once the client could name it.
        --
        -- `/cn chase <type> <id>` pins automatically, so hitting this needs
        -- no unusual sequence at all. It undoes, for exactly the cache-only
        -- types, the fix recorded in Filters.lua: "The client knows. Ask it."
        local name = goal.name

        if filters and filters.DescribeObjective then
            local ok, described = pcall(filters.DescribeObjective,
                goal.type, goal.id)

            if ok and described and described ~= "" then
                local placeholder = tostring(goal.type):sub(1, 1)
                    .. tostring(goal.type):sub(2):lower() .. " " .. tostring(goal.id)

                -- Only when the describer has learned something real: a
                -- second placeholder is not an improvement on the first.
                if described ~= placeholder or not name then
                    name = described
                end
            end
        end

        table.insert(list, {
            key   = key,
            type  = goal.type,
            id    = goal.id,
            name  = name,
            since = goal.since or 0,
        })
    end

    table.sort(list, function(a, b)
        if a.since ~= b.since then
            return a.since < b.since
        end

        return tostring(a.key) < tostring(b.key)
    end)

    return list
end

------------------------------------------------------------
-- WHAT IS KNOWN ABOUT GETTING IT
------------------------------------------------------------

-- Everything the addon can say about how to obtain one goal. Deliberately
-- honest: where nothing is known, it says so and names what would make it
-- knowable, rather than inventing a route.
--
-- Returns a table:
--   name, source, mapID, x, y, zone, steps (array of strings),
--   done (boolean), character (string or nil)
function Goals.Plan(goal)
    local plan = {
        name  = goal.name,
        steps = {},
    }

    local types = CN.objectiveTypes

    local function step(text)
        table.insert(plan.steps, text)
    end

    ------------------------------------------------------------
    -- Is it already done?
    ------------------------------------------------------------

    local state, reason = CN.Explain(goal.type, goal.id)

    if state == CN.objectiveStates.COMPLETED then
        plan.done = true

        step(reason or "Already complete.")

        return plan
    end

    ------------------------------------------------------------
    -- Where is it?
    ------------------------------------------------------------

    if goal.type == types.QUEST then
        local quests = CN:GetModule("Quests")

        if quests then
            local mapID, x, y, source = quests.GetLocation(goal.id)

            plan.mapID, plan.x, plan.y = mapID, x, y
            plan.source = source

            if mapID then
                plan.zone = Blizzard.GetMapName(mapID)
            end
        end

        if state == CN.objectiveStates.LOCKED and reason then
            step(reason)
        end
    end

    if goal.type == types.MOUNT then
        local record = CN.Account("mounts")[goal.id]

        if record then
            plan.source = record.source

            if record.isFactionSpecific then
                step("Faction-locked. Only obtainable on one faction.")
            end
        end
    end

    if goal.type == types.PET then
        local record = CN.Account("pets")[goal.id]

        if record and record.isWild then
            step("Wild pet: find and capture it in the world.")
        end
    end

    if goal.type == types.RECIPE then
        local vendors = CN:GetModule("Vendors")

        if vendors then
            local seller = vendors.FirstLocatedSeller(goal.id)

            if seller then
                plan.source = "Sold by " .. tostring(seller.name)
                plan.mapID, plan.x, plan.y = seller.mapID, seller.x, seller.y
                plan.zone = seller.zone

                step("Buy it from " .. tostring(seller.name)
                    .. (seller.zone and (" in " .. seller.zone) or "") .. ".")
            else
                step("No recorded vendor sells this. Open merchants to record them.")
            end
        end
    end

    if goal.type == types.RARE or goal.type == types.TREASURE then
        local record = CN.Account("rares")[goal.id]

        if record then
            plan.mapID, plan.x, plan.y = record.mapID, record.x, record.y
            plan.zone = record.zone

            step("Seen " .. (record.sightings or 1) .. " time"
                .. CN.Pluralize((record.sightings or 1), "") .. " here.")
        end
    end

    if goal.type == types.ACHIEVEMENT then
        local record = CN.Account("achievements")[goal.id]

        if record and record.criteria then
            local remaining = (record.criteria or 0) - (record.done or 0)

            step(remaining .. " of " .. record.criteria .. " criteria left.")

            for _, criterion in ipairs(Blizzard.GetIncompleteCriteria(goal.id, 5) or {}) do
                step("Missing: " .. criterion)
            end
        end
    end

    if goal.type == types.REPUTATION then
        local record = CN.Account("reputations")[goal.id]

        if record then
            if record.accountWide then
                step("Account-wide: any character's progress counts.")
            else
                step("Character-specific: progress does not carry across your Warband.")
            end
        end
    end

    ------------------------------------------------------------
    -- Who should do it?
    ------------------------------------------------------------

    local warband = CN:GetModule("Warband")

    if warband then
        local ok, best, _, why = pcall(warband.WhoShould, goal.type, goal.id)

        if ok and best then
            plan.character = best

            step("Best character: " .. tostring(best)
                .. (why and (" (" .. why .. ")") or ""))
        end
    end

    ------------------------------------------------------------
    -- Fall back to honesty.
    ------------------------------------------------------------

    if plan.mapID and plan.x and plan.y then
        step("Location known: " .. (plan.zone or ("map " .. plan.mapID))
            .. string.format(" (%.1f, %.1f)", plan.x * 100, plan.y * 100))
    elseif #plan.steps == 0 then
        step("Nothing is known about how to obtain this yet.")
        step("The addon learns sources from play: open vendors, scan "
            .. "collections, and travel.")
    end

    return plan
end

------------------------------------------------------------
-- CANDIDATES
------------------------------------------------------------

-- A goal is actionable by definition. Most goals would never surface on their
-- own -- an uncollected mount is not a next action for most people -- which is
-- exactly the point of having said you want it.
CN.RegisterCandidateProvider("Goals", function()
    local candidates = {}

    for _, goal in ipairs(Goals.List()) do
        if not CN.IsIgnored(goal.type, goal.id)
            and not CN.IsDeferred(goal.type, goal.id) then

            local plan = Goals.Plan(goal)

            if not plan.done then
                local reasons = { "you set this as a goal" }

                if plan.source then
                    table.insert(reasons, plan.source)
                end

                local travel

                if plan.mapID then
                    -- Costed like everything else, rather than a flat
                    -- penalty for "not here" while holding the coordinates.
                    travel = CN.TravelCost(plan.mapID, plan.x, plan.y)
                end

                table.insert(candidates, CN.NewObjective({
                    id              = goal.id,
                    type            = goal.type,
                    name            = goal.name,
                    mapID           = plan.mapID,
                    x               = plan.x,
                    y               = plan.y,
                    zone            = plan.zone,
                    accountWide     = true,
                    completionValue = 6,
                    travelCost      = travel,
                    reasons         = reasons,
                }))
            end
        end
    end

    return candidates
end, {
    -- THE EVENTS OF EVERY SYSTEM A GOAL CAN BE ABOUT.
    --
    -- `Goals.Plan` asks `CN.Explain` whether the goal is done, and a goal can
    -- be a quest, a mount, a pet, a toy, an achievement or a reputation. This
    -- declared one event -- the zone change -- so finishing the thing you had
    -- pinned did not take it off the list: the row carries a completionValue
    -- of six, so it stayed near the top of `/cn list` and on the route.
    --
    -- Worse, `Follow.Remaining` decides a stop is finished by asking whether
    -- its objectives are still candidates, so follow mode stuck on a goal the
    -- player had already completed until they crossed a zone boundary.
    --
    -- Same shape as the Inventory defect reported from play in 0.59.0, and
    -- the reason the harness now checks this structurally.
    events = {
        "ZONE_CHANGED_NEW_AREA",
        "QUEST_TURNED_IN", "QUEST_REMOVED", "QUEST_ACCEPTED",
        "NEW_MOUNT_ADDED", "NEW_PET_ADDED", "NEW_TOY_ADDED",
        "ACHIEVEMENT_EARNED", "UPDATE_FACTION",
    },
    cooldown = 2,
})

------------------------------------------------------------
-- WEIGHTING
------------------------------------------------------------

-- Anything that leads to a goal is worth more than it would be otherwise.
-- "Leads to" is deliberately narrow -- three relationships the addon can
-- actually establish, rather than a guess dressed up as a plan.
-- Which maps hold an unfinished goal. Rebuilt when the goal list changes,
-- not when a candidate asks.
local goalZones, goalZoneGeneration = nil, -1

local function GoalZones()
    local generation = Goals.zoneGeneration or 0

    if goalZones and goalZoneGeneration == generation then
        return goalZones
    end

    local zones = {}

    for _, goal in ipairs(Goals.List()) do
        local ok, plan = pcall(Goals.Plan, goal)

        if ok and plan and plan.mapID and not plan.done then
            zones[plan.mapID] = true
        end
    end

    goalZones           = zones
    goalZoneGeneration  = generation

    return zones
end

Goals.zoneGeneration = 0

-- What pinning something is worth, and what leading to something pinned is
-- worth. Named rather than written into the arithmetic, so the decorator can
-- take its own contribution back out again.
Goals.goalPreference        = 8
Goals.unlocksGoalPreference = 5
Goals.zonePreference        = 2

function Goals.Decorate(objective)
    if type(objective) ~= "table" or not objective.type or not objective.id then
        return objective
    end

    local store = Store()

    -- NOTHING PINNED MEANS NOTHING PINNED, INCLUDING WHAT WAS.
    --
    -- Returning early here left the last pin's preference and sentence on
    -- every cached objective it had ever been stamped on -- so `/cn goal
    -- remove` took the goal out of the list and left its weighting behind.
    if not store or next(store) == nil then
        return Goals.Withdraw(objective)
    end

    -- 1. It IS a goal.
    if Goals.IsGoal(objective.type, objective.id) then
        -- SET, NEVER ADD TO ITSELF.
        --
        -- This read the field and incremented it, which was harmless only
        -- while every rebuild produced fresh objective tables. Since 0.55.0
        -- repaired the unchanged-provider shortcut, a provider's tables are
        -- REUSED across rebuilds -- so a pinned goal's preference compounded
        -- by eight on every rebuild, without bound: 8, 16, 24, 32. After
        -- twenty quest turn-ins the goal outweighed everything else on the
        -- list by thirty to one, `/cn next` returned it and nothing could
        -- ever displace it -- including a world boss about to despawn -- and
        -- `/cn breakdown` showed the inflated number as though it were
        -- deliberate. Only a reload cleared it.
        --
        -- `goalPreference` records what this decorator contributed, so the
        -- contribution can be replaced rather than repeated, and so a
        -- provider's own preference underneath it survives.
        local own = (objective.userPreference or 0)
            - (objective.goalPreference or 0)

        objective.goalPreference = Goals.goalPreference
        objective.userPreference = own + Goals.goalPreference

        -- `objective.isGoal` was set here, cleared in Withdraw, set again in
        -- the provider above, and read by nothing anywhere in the tree. What
        -- consumers actually ask is `CN.Reasons(objective)`, which carries
        -- the sentence below -- so the flag was a second, silent answer to a
        -- question already answered, with its own lifetime to get wrong.
        CN.AddDecoratorReason(objective, "goal", "this is one of your goals")

        return objective
    end

    -- 2. It unlocks a goal, per the dependency graph.
    if objective.type == CN.objectiveTypes.QUEST then
        local dependency = CN.GetDependency(CN.ObjectiveKey(objective.type, objective.id))

        if dependency and dependency.unlocks then
            for _, unlocked in ipairs(dependency.unlocks) do
                -- Dependency edges are stored as keys, but static data writes
                -- plain quest IDs. Accept both.
                local unlockedID = tonumber(unlocked)
                    or tonumber(tostring(unlocked):match(":(%d+)$"))

                if unlockedID and Goals.IsGoal(CN.objectiveTypes.QUEST, unlockedID) then
                    -- Same rule as above: replace this decorator's own
                    -- contribution rather than adding to it again.
                    local own = (objective.userPreference or 0)
                        - (objective.goalPreference or 0)

                    objective.goalPreference = Goals.unlocksGoalPreference
                    objective.userPreference = own
                        + Goals.unlocksGoalPreference

                    CN.AddDecoratorReason(objective, "goal",
                        "unlocks a goal")

                    return objective
                end
            end
        end
    end

    -- 3. It is in the same zone as a located goal. Weak, and weighted weakly:
    --    being in the right place is worth something, but it is not progress.
    --
    -- THE ZONES ARE WORKED OUT ONCE, NOT ONCE PER OBJECTIVE.
    --
    -- This looped every pinned goal and called Goals.Plan inside the
    -- decorator, and the decorator runs once per candidate. Goals.Plan asks
    -- the client for a map name, a vendor location, incomplete criteria and a
    -- Warband verdict -- so ten goals against a few hundred candidates was
    -- thousands of client calls per rebuild, on the path a 0.4x refactor
    -- restructured specifically to stop doing work per objective.
    --
    -- The answer only changes when the goals do, which the invalidation
    -- below already announces.
    if objective.mapID then
        local zones = GoalZones()

        if zones[objective.mapID] then
            local own = (objective.userPreference or 0)
                - (objective.goalPreference or 0)

            objective.goalPreference = Goals.zonePreference
            objective.userPreference = own + Goals.zonePreference

            CN.AddDecoratorReason(objective, "goal",
                "in the same zone as a goal")

            return objective
        end
    end

    -- None of the three applied, so anything a previous pass stamped is no
    -- longer true.
    return Goals.Withdraw(objective)
end

-- Takes back everything this decorator contributed, so an objective that
-- stops being a goal -- or stops leading to one -- stops carrying its weight
-- and its sentence. Every adjuster in this addon has done this since 0.51.0;
-- the decorators did not, because until 0.55.0 their tables were thrown away
-- between passes and the question never arose.
function Goals.Withdraw(objective)
    if type(objective) ~= "table" then
        return objective
    end

    if objective.goalPreference then
        objective.userPreference = (objective.userPreference or 0)
            - objective.goalPreference

        objective.goalPreference = nil
    end

    CN.ClearDecoratorReason(objective, "goal")

    return objective
end

CN.RegisterCandidateDecorator("Goals", Goals.Decorate)

------------------------------------------------------------
-- OUTPUT
------------------------------------------------------------

local function PrintPlan(index, goal)
    local plan = Goals.Plan(goal)

    Print(index .. ". |cffffc74f" .. tostring(plan.name) .. "|r"
        .. " |cff8a8f96(" .. tostring(goal.type) .. " " .. tostring(goal.id) .. ")|r"
        .. (plan.done and " |cff73b873done|r" or ""))

    if plan.source then
        Print("   Source: " .. tostring(plan.source))
    end

    for _, step in ipairs(plan.steps) do
        CN.PrintLine("   - " .. step)
    end

    if plan.character then
        Print("   Best character: |cffffc74f" .. tostring(plan.character) .. "|r")
    end

    if plan.mapID and plan.x and plan.y then
        Print("   |cffffc74f/cn gogoal " .. index .. "|r to set a waypoint.")
    end
end

Goals.PrintPlan = PrintPlan

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "goal",
    args    = "<type> <name or id>",
    order   = 12,
    help    = "Pin something as a goal. Types: quest, achievement, mount, pet, toy, recipe, title, rep, rare, currency.",
    handler = function(args)
        -- Everything after the first word is the thing, because a name has
        -- spaces in it. `^(%S+)%s+(%S+)$` accepted only a single word, so
        -- even once names were resolvable "Reins of the Black Drake" could
        -- not be typed.
        local typeText, idText =
            string.match(CN.Trim(args or ""), "^(%S+)%s+(.+)$")

        if not typeText then
            CN.PrintBlock("Usage: " .. CN.Accent("/cn goal <type> <name or id>"), {
                CN.Muted("e.g. ") .. CN.Accent("/cn goal mount Invincible"),
                CN.Muted("Types: quest, achievement, mount, pet, toy, recipe, "
                    .. "title, rep, rare, currency"),
                CN.Accent("/cn goals") .. CN.Muted(" lists what you have pinned."),
            })

            return
        end

        local objectiveType = ResolveType(typeText)

        if not objectiveType then
            Print("Not a goal type: " .. typeText)
            Print("|cff8a8f96Types: quest, achievement, mount, pet, toy, recipe, "
                .. "title, rep, rare, currency|r")
            return
        end

        local id, why = CN.ResolveObjective(objectiveType, idText)

        if not id then
            Print(why or ("Not an ID: " .. idText))
            return
        end

        local added, message = Goals.Add(objectiveType, id)

        if not added then
            Print(message)
            return
        end

        Print("Goal set: |cffffc74f" .. tostring(message) .. "|r")
        Print("|cff8a8f96See the path with |cffffc74f/cn chase " .. typeText
            .. " " .. idText .. "|r")

        local list = Goals.List()

        for index, goal in ipairs(list) do
            if goal.type == objectiveType and goal.id == id then
                PrintPlan(index, goal)
                break
            end
        end
    end,
}

CN:RegisterCommand{
    name    = "goals",
    order   = 13,
    help    = "List your goals and what is known about reaching them.",
    handler = function()
        local list = Goals.List()

        if #list == 0 then
            Print("No goals set.")
            Print("|cffffc74f/cn goal mount 1234|r pins something to work toward.")
            Print("|cff8a8f96A goal becomes actionable even when nothing else "
                .. "would have surfaced it, and anything leading to it ranks higher.|r")
            return
        end

        Print("Goals (" .. #list .. " of " .. Goals.limit .. "):")

        for index, goal in ipairs(list) do
            PrintPlan(index, goal)
        end
    end,
}

CN:RegisterCommand{
    name    = "ungoal",
    args    = "<number or all>",
    order   = 14,
    help    = "Remove a goal.",
    handler = function(args)
        args = CN.Trim(args or "")

        if string.lower(args) == "all" then
            local count = Goals.Clear()

            Print("Cleared " .. CN.Count(count, "goal") .. ".")
            return
        end

        local index = CN.ToID(args)

        local list = Goals.List()

        if not index or not list[index] then
            Print("Usage: /cn ungoal <number or all>")

            if #list > 0 then
                Print("|cff8a8f96Numbers come from |cffffc74f/cn goals|r.|r")
            end

            return
        end

        local goal = list[index]

        local removed, name = Goals.Remove(goal.type, goal.id)

        if removed then
            Print("Goal removed: " .. tostring(name))
        end
    end,
}

CN:RegisterCommand{
    name    = "gogoal",
    args    = "<number>",
    order   = 15,
    help    = "Navigate to a goal.",
    handler = function(args)
        local index = CN.ToID(CN.Trim(args or ""))

        local list = Goals.List()

        if not index or not list[index] then
            Print("Usage: /cn gogoal <number>")
            return
        end

        local goal = list[index]
        local plan = Goals.Plan(goal)

        if not (plan.mapID and plan.x and plan.y) then
            Print("No location is known for " .. tostring(plan.name) .. ".")

            for _, step in ipairs(plan.steps) do
                CN.PrintLine("  - " .. step)
            end

            return
        end

        CN.NavigateToObjective({
            id    = goal.id,
            type  = goal.type,
            name  = plan.name,
            mapID = plan.mapID,
            x     = plan.x,
            y     = plan.y,
        })
    end,
}

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
