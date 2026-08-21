-- Modules/Chase.lua
-- Completion Navigator :: what stands between you and the thing you want.
--
-- `/cn goal` has always been able to say "I want that" and re-weight the
-- list accordingly. What it could never say is what the PATH is. A player
-- chasing a mount got a line saying the mount was a goal, and nothing about
-- which four things had to happen first, how many of them were already done,
-- or which one to go and do now.
--
-- This is that path. Chase turns a goal into an ordered chain of steps, each
-- one carrying a state -- done, next, blocked, or simply outstanding -- and,
-- where the game will tell us, a real count.
--
-- ON NUMBERS. The addon's standing rule is that it does not invent a
-- denominator. That rule is doing real work here, because a progress bar is
-- exactly the kind of thing that begs to be faked. So:
--
--   * Achievement criteria, appearance sources, and reputation standing have
--     denominators the client vouches for. Those get a fraction.
--   * A mount whose source is a sentence of English does not. It gets the
--     sentence, and no bar.
--
-- Showing "1 of 1 steps" for something we know nothing about would be a lie
-- told in a font that looks like a fact.

local ADDON_NAME, CN = ...

local Chase = CN:RegisterModule("Chase")

local Print = CN.Print

local Blizzard = CN.Blizzard

------------------------------------------------------------
-- STEP STATES
------------------------------------------------------------

-- Ordered by how much the player needs to look at them.
Chase.states = {
    NEXT    = "NEXT",     -- go and do this one
    TODO    = "TODO",     -- outstanding, but not the immediate move
    BLOCKED = "BLOCKED",  -- cannot be done yet, and we know why
    DONE    = "DONE",     -- already behind you
    NOTE    = "NOTE",     -- context, not a step
}

Chase.stateLabels = {
    NEXT    = "next",
    TODO    = "to do",
    BLOCKED = "blocked",
    DONE    = "done",
    NOTE    = "",
}

Chase.stateColors = {
    NEXT    = { 0.365, 0.824, 0.984 },
    TODO    = { 0.85, 0.85, 0.85 },
    BLOCKED = { 0.96, 0.42, 0.38 },
    DONE    = { 0.45, 0.72, 0.45 },
    NOTE    = { 0.6, 0.6, 0.6 },
}

local function NewStep(state, text, extra)
    local step = extra or {}

    step.state = state
    step.text  = text

    return step
end

------------------------------------------------------------
-- PER-TYPE CHAINS
------------------------------------------------------------

-- Each builder returns steps and, optionally, a progress table:
--   { done = n, total = m, unit = "criteria" }
--
-- Returning no progress table is a positive statement -- "the game does not
-- give me a trustworthy count here" -- not an oversight.

local builders = {}

builders.ACHIEVEMENT = function(goal)
    local steps = {}

    local criteria = Blizzard.GetAchievementCriteriaList(goal.id, 25) or {}

    if #criteria == 0 then
        return steps, nil
    end

    local done = 0
    local first = true

    for _, criterion in ipairs(criteria) do
        local text = criterion.description

        -- Some criteria carry their own counter. Where they do, it is the
        -- most useful thing on the line.
        if criterion.required and criterion.required > 1 and criterion.quantity then
            text = string.format("%s (%d/%d)",
                text, criterion.quantity, criterion.required)
        end

        if criterion.completed then
            done = done + 1

            table.insert(steps, NewStep(Chase.states.DONE, text))
        else
            local state = Chase.states.TODO

            if first then
                state = Chase.states.NEXT
                first = false
            end

            table.insert(steps, NewStep(state, text))
        end
    end

    return steps, { done = done, total = #criteria, unit = "criteria" }
end

builders.REPUTATION = function(goal)
    local steps = {}

    local standing = Blizzard.GetReputationRemaining(goal.id)

    if not standing then
        return steps, nil
    end

    if Blizzard.IsAccountWideReputation(goal.id) then
        table.insert(steps, NewStep(Chase.states.NOTE,
            "Account-wide: any character's progress counts."))
    else
        table.insert(steps, NewStep(Chase.states.NOTE,
            "Character-specific: progress does not carry across your Warband."))
    end

    table.insert(steps, NewStep(Chase.states.NEXT, string.format(
        "%s reputation to the next rank", CN.Comma(standing.remaining))))

    return steps, {
        done  = standing.earned,
        total = standing.needed,
        unit  = "reputation",
    }
end

builders.APPEARANCE = function(goal)
    local steps = {}

    local sources = Blizzard.GetAppearanceSources(goal.id) or {}

    if #sources == 0 then
        return steps, nil
    end

    local collected = 0
    local first = true

    for _, source in ipairs(sources) do
        local name = source.name or ("item " .. tostring(source.itemID or "?"))

        if source.collected then
            collected = collected + 1

            table.insert(steps, NewStep(Chase.states.DONE, name))
        else
            local state = Chase.states.TODO

            if first then
                state = Chase.states.NEXT
                first = false
            end

            table.insert(steps, NewStep(state, name, { itemID = source.itemID }))
        end
    end

    -- An appearance needs ONE of its sources, not all of them, so the count
    -- is deliberately not offered as progress toward the appearance. Saying
    -- "1 of 9" would suggest eight more to go when in fact you are finished.
    table.insert(steps, 1, NewStep(Chase.states.NOTE,
        collected > 0
            and "Collected. Any one source is enough."
            or string.format("Any ONE of these %d sources unlocks it.", #sources)))

    return steps, nil
end

builders.QUEST = function(goal)
    local steps = {}

    local dependencies = CN.GetPrerequisites and CN.GetPrerequisites(goal.id)

    if type(dependencies) ~= "table" or #dependencies == 0 then
        return steps, nil
    end

    local done = 0
    local first = true

    for _, questID in ipairs(dependencies) do
        local name = Blizzard.GetQuestTitle(questID, true)
            or ("Quest " .. tostring(questID))

        if CN.IsQuestComplete and CN.IsQuestComplete(questID) then
            done = done + 1

            table.insert(steps, NewStep(Chase.states.DONE, name,
                { objectiveType = CN.objectiveTypes.QUEST, objectiveID = questID }))
        else
            local state = Chase.states.TODO

            if first then
                state = Chase.states.NEXT
                first = false
            end

            table.insert(steps, NewStep(state, name,
                { objectiveType = CN.objectiveTypes.QUEST, objectiveID = questID }))
        end
    end

    return steps, { done = done, total = #dependencies, unit = "prerequisites" }
end

Chase.builders = builders

-- Which goals are worth asking the Adventure Guide about. A reputation does
-- not drop from a boss, and searching for one costs a journal round-trip to
-- learn nothing.
Chase.instanceSourceTypes = {
    [CN.objectiveTypes.MOUNT]      = true,
    [CN.objectiveTypes.PET]        = true,
    [CN.objectiveTypes.TOY]        = true,
    [CN.objectiveTypes.APPEARANCE] = true,
    [CN.objectiveTypes.TITLE]      = true,
}

------------------------------------------------------------
-- THE CHAIN
------------------------------------------------------------

-- The full picture for one goal: where it is, what remains, how far along
-- you are, and which single step to go and do.
function Chase.Chain(goal)
    local chain = {
        name  = goal and goal.name,
        type  = goal and goal.type,
        id    = goal and goal.id,
        steps = {},
    }

    if type(goal) ~= "table" or not goal.type or not goal.id then
        return chain
    end

    local goals = CN:GetModule("Goals")

    -- Location, source and "who should do it" already exist. Reuse them
    -- rather than growing a second, subtly different answer.
    local plan = goals and goals.Plan(goal) or {}

    chain.done      = plan.done
    chain.source    = plan.source
    chain.mapID     = plan.mapID
    chain.x         = plan.x
    chain.y         = plan.y
    chain.zone      = plan.zone
    chain.character = plan.character

    if chain.done then
        table.insert(chain.steps, NewStep(Chase.states.DONE, "Already complete."))

        chain.progress = { done = 1, total = 1, unit = "steps" }

        return chain
    end

    local builder = builders[goal.type]

    if builder then
        local ok, steps, progress = pcall(builder, goal)

        if ok and type(steps) == "table" then
            chain.steps    = steps
            chain.progress = progress
        end
    end

    -- IF IT DROPS FROM A BOSS, SAY WHICH BOSS.
    --
    -- Before this, a raid mount produced a chain whose only content was the
    -- mount journal's source line -- prose, no boss, no instance, and no idea
    -- whether the player was already locked out of the thing this week. That
    -- is the one failure this feature exists to prevent: a goal with no path
    -- to it.
    --
    -- Deliberately additive. The step is appended to whatever the builder
    -- produced rather than replacing it, because the journal's answer is a
    -- location and the builder's answer is the requirement, and a player
    -- needs both.
    local instances = CN:GetModule("Instances")

    if instances and chain.name and Chase.instanceSourceTypes[goal.type] then
        local ok, description, first = pcall(instances.DescribeSource, chain.name)

        if ok and description and first then
            local lockout = first.instance and instances.LockoutFor(first.instance)

            if lockout and lockout.complete then
                table.insert(chain.steps, NewStep(Chase.states.BLOCKED,
                    "Drops from " .. description,
                    {
                        note = "you are saved to " .. first.instance
                            .. " and it is cleared -- resets in "
                            .. instances.FormatReset(lockout.resetsIn),
                    }))
            else
                local state = Chase.states.TODO

                -- Only claim the immediate move if nothing else has.
                if not Chase.NextStep(chain) then
                    state = Chase.states.NEXT
                end

                local step = NewStep(state, "Kill " .. description, {
                    encounterID = first.encounterID,
                    instanceID  = first.instanceID,
                })

                if lockout then
                    step.note = lockout.remaining .. " of " .. lockout.encounters
                        .. " left on your lockout"
                end

                table.insert(chain.steps, step)
            end
        end
    end

    -- Nothing structured? Fall back to what the existing planner knows, which
    -- is prose rather than a chain -- and say so, rather than dressing a
    -- sentence up as a step.
    if #chain.steps == 0 then
        for _, text in ipairs(plan.steps or {}) do
            table.insert(chain.steps, NewStep(Chase.states.NOTE, text))
        end

        if chain.mapID and chain.x and chain.y then
            table.insert(chain.steps, 1,
                NewStep(Chase.states.NEXT, "Travel to " ..
                    (chain.zone or ("map " .. tostring(chain.mapID))), {
                    mapID = chain.mapID,
                    x     = chain.x,
                    y     = chain.y,
                }))
        end
    end

    chain.next = Chase.NextStep(chain)

    return chain
end

-- The one step to go and do. Nil when everything outstanding is blocked or
-- unknown, which is itself worth saying out loud.
function Chase.NextStep(chain)
    for _, step in ipairs(chain and chain.steps or {}) do
        if step.state == Chase.states.NEXT then
            return step
        end
    end

    for _, step in ipairs(chain and chain.steps or {}) do
        if step.state == Chase.states.TODO then
            return step
        end
    end

    return nil
end

-- A single line for chat: where you are, and what to do about it.
function Chase.Summarize(chain)
    if not chain or not chain.name then
        return "Nothing to chase."
    end

    if chain.done then
        return tostring(chain.name) .. " is complete."
    end

    local parts = {}

    if chain.progress and chain.progress.total and chain.progress.total > 0 then
        table.insert(parts, string.format("%s of %s %s",
            CN.Comma(chain.progress.done or 0),
            CN.Comma(chain.progress.total),
            chain.progress.unit or "steps"))
    end

    local nextStep = chain.next or Chase.NextStep(chain)

    if nextStep then
        table.insert(parts, "next: " .. tostring(nextStep.text))
    elseif #parts == 0 then
        return tostring(chain.name)
            .. " -- the game does not say how this is obtained."
    end

    return tostring(chain.name) .. " -- " .. table.concat(parts, ", ")
end

-- Percent complete, or nil. Nil is a real answer and callers must render it
-- as "unknown" rather than as zero.
function Chase.Fraction(chain)
    local progress = chain and chain.progress

    if not progress or not progress.total or progress.total <= 0 then
        return nil
    end

    local fraction = (progress.done or 0) / progress.total

    if fraction < 0 then return 0 end
    if fraction > 1 then return 1 end

    return fraction
end

-- Every goal, chained, with the least-finished first: the thing you are
-- furthest from is the thing most in need of a plan.
function Chase.All()
    local goals = CN:GetModule("Goals")

    if not goals then
        return {}
    end

    local chains = {}

    for _, goal in ipairs(goals.List()) do
        table.insert(chains, Chase.Chain(goal))
    end

    table.sort(chains, function(a, b)
        local left  = Chase.Fraction(a)
        local right = Chase.Fraction(b)

        -- Finished goals sink. Unmeasurable ones sit between measurable
        -- progress and completion, because "no idea" is more actionable than
        -- "done" and less actionable than "you are 80% there".
        local leftDone  = a.done and 1 or 0
        local rightDone = b.done and 1 or 0

        if leftDone ~= rightDone then
            return leftDone < rightDone
        end

        if left and right then
            return left > right
        end

        if left or right then
            return left ~= nil
        end

        return tostring(a.name) < tostring(b.name)
    end)

    return chains
end

------------------------------------------------------------
-- NAVIGATION
------------------------------------------------------------

-- Go to the next step of a chain, not to the goal itself.
--
-- Those differ, and the difference is the whole point: the mount is in a
-- dungeon you cannot enter yet, but the attunement quest is forty yards away.
function Chase.NavigateNext(chain)
    local step = chain and (chain.next or Chase.NextStep(chain))

    if step and step.objectiveType and step.objectiveID then
        local located = CN.FindCandidate
            and CN.FindCandidate(step.objectiveType, step.objectiveID)

        if located then
            return CN.NavigateToObjective(located)
        end
    end

    if step and step.mapID and step.x and step.y then
        return CN.SetWaypoint(step.mapID, step.x, step.y, step.text)
    end

    if chain and chain.mapID and chain.x and chain.y then
        return CN.SetWaypoint(chain.mapID, chain.x, chain.y, chain.name)
    end

    Print("No location is known for the next step of "
        .. tostring(chain and chain.name or "that goal") .. ".")

    return false
end

------------------------------------------------------------
-- COMMAND
------------------------------------------------------------

local function PrintChain(chain)
    Print(Chase.Summarize(chain))

    local fraction = Chase.Fraction(chain)

    if fraction then
        Print(string.format("  |cff5dd2fb%s|r %d%%",
            CN.ProgressBar and CN.ProgressBar(fraction, 20) or "",
            math.floor(fraction * 100 + 0.5)))
    end

    local shown = 0

    for _, step in ipairs(chain.steps) do
        if shown >= 12 then
            Print("  |cff999999... and " .. (#chain.steps - shown) .. " more|r")
            break
        end

        local label = Chase.stateLabels[step.state] or ""

        local colour = "|cffcccccc"

        if step.state == Chase.states.DONE then
            colour = "|cff73b873"
        elseif step.state == Chase.states.NEXT then
            colour = "|cff5dd2fb"
        elseif step.state == Chase.states.BLOCKED then
            colour = "|cfff56b61"
        elseif step.state == Chase.states.NOTE then
            colour = "|cff999999"
        end

        Print(string.format("  %s%s%s|r",
            colour,
            label ~= "" and ("[" .. label .. "] ") or "",
            step.text))

        shown = shown + 1
    end

    if chain.character then
        Print("  |cff999999Best character: " .. tostring(chain.character) .. "|r")
    end
end

Chase.PrintChain = PrintChain

CN:RegisterCommand{
    name    = "chase",
    aliases = { "chain", "path" },
    args    = "[type id, or nothing for all goals]",
    order   = 16,
    help    = "Show what stands between you and a goal, step by step.",
    handler = function(args)
        args = CN.Trim(args or "")

        local goals = CN:GetModule("Goals")

        if not goals then
            Print("The Goals module is not loaded.")
            return
        end

        if args ~= "" then
            local typeText, idText = string.match(args, "^(%S+)%s+(%S+)$")

            local objectiveType = typeText and goals.ResolveType(typeText)
            local id            = idText and CN.ToID(idText)

            if not objectiveType or not id then
                Print("Usage: |cffffff00/cn chase <type> <id>|r"
                    .. "   e.g. /cn chase mount 1234")
                Print("|cff999999Types: quest, achievement, mount, pet, toy, "
                    .. "recipe, title, rep, rare, currency|r")
                return
            end

            -- Chasing something you have not pinned pins it. Asking for the
            -- path to a thing is the clearest possible statement that you
            -- want it, and making the player run two commands to say so once
            -- is the addon being pedantic at the player's expense.
            if not goals.IsGoal(objectiveType, id) then
                goals.Add(objectiveType, id)
            end

            for _, goal in ipairs(goals.List()) do
                if goal.type == objectiveType and goal.id == id then
                    PrintChain(Chase.Chain(goal))
                    return
                end
            end

            Print("Could not pin that as a goal.")
            return
        end

        local chains = Chase.All()

        if #chains == 0 then
            Print("Nothing pinned. Try |cffffff00/cn chase mount 1234|r, or")
            Print("|cffffff00/cn goal <type> <id>|r to pin something first.")
            return
        end

        for _, chain in ipairs(chains) do
            PrintChain(chain)
        end
    end,
}

return Chase
