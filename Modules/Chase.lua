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

-- THE ROLE PER STATE, NOT A SECOND PALETTE.
--
-- This held five hand-written RGB triples, three of them colours Design.lua
-- says were retired -- a complete second palette in a file that is not
-- allowed to have one, and read by nothing: the same five states are declared
-- again with palette codes in the Goals tab. Roles are named here so the two
-- cannot drift, and so the one place that renders them has something to ask.
Chase.stateRoles = {
    NEXT    = "BRAND",
    TODO    = "BODY",
    BLOCKED = "BAD",
    DONE    = "GOOD",
    NOTE    = "MUTED",
}

-- And as a wrapped string, for chat and for a list label.
function Chase.StateText(state, text)
    local role = Chase.stateRoles[state] or "BODY"

    return "|cff" .. CN.C[role] .. tostring(text) .. "|r"
end

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

    -- THE SECOND RETURN IS THE HONEST COUNT. 0.61.0.
    --
    -- The list is capped at 25 rows because a chain with sixty lines in it is
    -- not a chain any more, it is a wall. But the PROGRESS must describe the
    -- achievement, not the window -- see the note on
    -- `Blizzard.GetAchievementCriteriaList`, which used to break out of its
    -- own loop at the cap and hand back a total of 25 for a 31-criterion
    -- meta. This printed 36% for something 29% done, and 100% for anything
    -- whose first 25 criteria happened to be finished.
    local criteria, summary = Blizzard.GetAchievementCriteriaList(goal.id, 25)

    criteria = criteria or {}
    summary  = summary or { total = #criteria, completed = 0 }

    if summary.total == 0 then
        return steps, nil
    end

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

    -- SAY SO WHEN THE LIST IS SHORTER THAN THE ACHIEVEMENT.
    --
    -- Without this the last visible row reads as the end of the chain, and a
    -- player who counts the rows gets the same wrong denominator by hand that
    -- the code used to compute.
    if summary.truncated then
        table.insert(steps, NewStep(Chase.states.NOTE, string.format(
            "%d more criteria not shown.",
            summary.total - #criteria)))
    end

    return steps, {
        done  = summary.completed,
        total = summary.total,
        unit  = "criteria",
    }
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

    -- NO FRACTION, BECAUSE THIS ONE IS NOT A FRACTION OF THE GOAL.
    --
    -- `earned` and `needed` describe the CURRENT RANK ONLY -- how far into
    -- Honored you are, not how far along the ladder to Exalted. Returning
    -- them as done/total made `/cn chase` draw a full bar and print "100%"
    -- for somebody standing at 21,000 of the 42,000 the ladder needs, and
    -- made `Chase.All` -- which sorts by exactly that fraction -- rank a
    -- faction one point short of Honored above an appearance genuinely eighty
    -- percent collected.
    --
    -- The client will vouch for progress inside a band and not for progress
    -- across the ladder, so the band is reported as a count, with the rank
    -- named, and no denominator is invented for the rest. That is this
    -- addon's standing rule, applied to the one place that was breaking it
    -- most visibly.
    return steps, {
        done         = nil,
        total        = nil,
        unit         = "reputation",
        bandEarned   = standing.earned,
        bandNeeded   = standing.needed,
        nextRank     = standing.nextRankName,
        unknownTotal = "the client reports progress inside a rank, not "
            .. "across the whole standing",
    }
end

-- NO APPEARANCE BUILDER. 0.89.0.
--
-- Thirty-five lines walking an appearance's sources sat here, unreachable
-- since the file was written: a builder is keyed on `goal.type`, goals are
-- created only through `Goals.Add`, and `Goals.types` has no appearance
-- entry. `Modules/Tooltips.lua` recorded that fact in 0.80.0 and deleted its
-- own unreachable branch; this pair was not swept with it.
--
-- Wiring it up is not the fix either. It called
-- `Blizzard.GetAppearanceSources(goal.id)`, which takes an appearance VISUAL
-- id, while every APPEARANCE row the addon produces is keyed `"set:<setID>"`
-- or by a transmog categoryID -- three different numbers. A goal made from
-- any of them would chase the wrong one. Dead code that reads as a live
-- feature is worse than an absent one, so it is gone.
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
                            .. " and it is cleared" .. CN.DASH .. "resets in "
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

    elseif chain.progress and chain.progress.bandNeeded then
        -- A band with the rank named, rather than a fraction of the goal
        -- that the client will not vouch for. "11,999 of 12,000 to Revered"
        -- is a fact; "100%" of a half-finished ladder is not.
        table.insert(parts, string.format("%s of %s %s%s",
            CN.Comma(chain.progress.bandEarned or 0),
            CN.Comma(chain.progress.bandNeeded),
            chain.progress.unit or "steps",
            chain.progress.nextRank
                and (" to " .. tostring(chain.progress.nextRank)) or ""))
    end

    local nextStep = chain.next or Chase.NextStep(chain)

    if nextStep then
        table.insert(parts, "next: " .. tostring(nextStep.text))
    elseif #parts == 0 then
        -- SPACED, like the line four below it. 0.96.0. Both put a value
        -- after a name, which is the job `CN.Aside` spaces; this one read
        -- "Invincible\226\128\148the game does not say".
        return tostring(chain.name)
            .. " " .. CN.DASH .. " "
            .. "the game does not say how this is obtained."
    end

    return tostring(chain.name) .. " " .. CN.DASH .. " " .. table.concat(parts, ", ")
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

-- Every goal, chained, with the NEAREST-FINISHED first.
--
-- The header used to say the opposite -- "least-finished first: the thing you
-- are furthest from is the thing most in need of a plan" -- while the
-- comparator eight lines below, and its own inline comment, did and described
-- the reverse. Two comments in one function, disagreeing.
--
-- The code is right and the header was wrong. Everything else in this addon
-- ranks the nearly-finished thing above the barely-begun one: a set two
-- pieces short, a quest three kills from done, a lockout part-way through.
-- A goal you are eighty percent through is the one worth an evening; one you
-- have not started is a decision, not a next action.
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

    -- SAY SOMETHING. 0.79.0. The Goals tab's "Next step" button reached
    -- these two lines and produced no chat output whatsoever, so a player
    -- who clicked it had no way to tell whether anything had happened.
    if step and step.mapID and step.x and step.y then
        return CN.SetWaypointAndSay(step.mapID, step.x, step.y, step.text,
            "Next step: " .. tostring(step.text or "here"))
    end

    if chain and chain.mapID and chain.x and chain.y then
        return CN.SetWaypointAndSay(chain.mapID, chain.x, chain.y, chain.name,
            "Waypoint set: " .. tostring(chain.name or "that goal"))
    end

    Print("No location is known for the next step of "
        .. tostring(chain and chain.name or "that goal") .. ".")

    return false
end

------------------------------------------------------------
-- HOW LONG IS THIS GOING TO TAKE
------------------------------------------------------------

-- The addon already measures two things and never multiplied them together:
-- how long each kind of objective takes this player (Session, from watching)
-- and how long it takes to get anywhere (Travel, from flight paths and
-- measured speed). A chain is a list of steps of known types in known places.
--
-- RULES, WHICH ARE THE SAME RULES AS EVERYWHERE ELSE IN THIS ADDON.
--
--   * A step whose type has never been timed is COUNTED as unknown, reported
--     as such, and charged at the average of the steps that have been timed
--     -- because it still has to happen, and pretending it is free would
--     understate the chain rather than widen the range.
--   * The result is a RANGE, not a figure. Anybody who has played knows that
--     "four hours" is a claim nobody can make; "three to six hours" is one
--     the data actually supports.
--   * If more steps are unknown than known, no estimate is offered at all.
--     Half an answer stated confidently is worse than "not enough to say".

-- How wide the range is either side of the estimate. Chosen to be honest
-- rather than flattering: task times in this game vary by more than a third
-- depending on competition for mobs, group size and luck.
Chase.estimateSpread = 0.4

-- Below this proportion of steps timed, say nothing.
Chase.estimateCoverage = 0.5

function Chase.Estimate(chain)
    if type(chain) ~= "table" or #(chain.steps or {}) == 0 then
        return nil
    end

    local session = CN:GetModule("Session")

    if not session or not session.TypicalSeconds then
        return nil
    end

    local seconds, timed, unknown = 0, 0, 0

    for _, step in ipairs(chain.steps) do
        -- Notes are context and done steps are behind you; neither is work.
        if step.state ~= Chase.states.DONE and step.state ~= Chase.states.NOTE then
            local objectiveType = step.objectiveType or chain.type

            local typical = objectiveType and session.TypicalSeconds(objectiveType)

            if typical then
                seconds = seconds + typical
                timed   = timed + 1
            else
                unknown = unknown + 1
            end
        end
    end

    local outstanding = timed + unknown

    if outstanding == 0 then
        return nil
    end

    -- TRAVEL, LEG BY LEG (0.43.0).
    --
    -- The first version costed one journey -- player to the next step -- and
    -- said so. That understated any chain whose steps are in different
    -- places, which is most of them: a chain across three zones is three
    -- journeys, and pretending it is one makes the estimate confidently short
    -- in exactly the cases where the player most needs it to be right.
    --
    -- Walked in the order the steps are listed, which is the order the addon
    -- would route them, starting from where the player actually is. Steps
    -- with no location contribute no travel rather than a guessed hop.
    local travelSeconds = 0

    local travel = CN:GetModule("Travel")

    local playerMap, playerX, playerY = CN.GetPlayerPosition()

    if travel and playerMap then
        -- NEAREST-FIRST, not listed-order.
        --
        -- 0.42.0 costed one journey; 0.43.0 costed every leg but walked them
        -- in the order the steps happened to be listed, which is the order a
        -- criteria list came back in -- no relation to geography. On a chain
        -- whose steps are scattered that overstates the total badly.
        --
        -- This is the same greedy nearest-neighbour walk the zone router
        -- uses, and it is an ESTIMATE either way: the point is not to find
        -- the optimal tour, it is to stop pretending the player will walk a
        -- deliberately silly one.
        local pending = {}

        for _, step in ipairs(chain.steps) do
            if step.state ~= Chase.states.DONE
                and step.state ~= Chase.states.NOTE then

                local toMap = step.mapID or chain.mapID
                local toX   = step.x or chain.x
                local toY   = step.y or chain.y

                if toMap and toX and toY then
                    table.insert(pending, { mapID = toMap, x = toX, y = toY })
                end
            end
        end

        local fromMap, fromX, fromY = playerMap, playerX, playerY

        while #pending > 0 and fromX do
            local bestIndex, bestSeconds

            for index, target in ipairs(pending) do
                local leg = travel.EstimateSeconds(
                    fromMap, fromX, fromY, target.mapID, target.x, target.y)

                if leg and (not bestSeconds or leg < bestSeconds) then
                    bestIndex, bestSeconds = index, leg
                end
            end

            if not bestIndex then
                break
            end

            local chosen = table.remove(pending, bestIndex)

            travelSeconds = travelSeconds + bestSeconds

            fromMap, fromX, fromY = chosen.mapID, chosen.x, chosen.y
        end
    end

    -- THE BOUNDARY THE RULE BELOW ACTUALLY STATES. 0.89.0.
    --
    -- "no estimate at all is offered unless more steps are timed than are
    -- not" -- and at exactly half, two timed and two untimed, `0.5 < 0.5` is
    -- false, so the guard passed and `/cn chase` printed a confident range in
    -- which half the total was extrapolation.
    if timed == 0 or (timed / outstanding) <= Chase.estimateCoverage then
        return {
            seconds     = nil,
            timed       = timed,
            unknown     = unknown,
            travel      = travelSeconds,
            enough      = false,
        }
    end

    -- Steps that have never been timed still have to happen. Charging them at
    -- the average of the ones that have is the least-wrong option available,
    -- and it widens the range rather than hiding in it.
    --
    -- The RULES block at the top of this section used to say the opposite --
    -- that an untimed step "contributes nothing" -- which would have meant
    -- quoting four hours for a chain whose second half the addon has simply
    -- never watched. The guard that makes this honest is the one above: no
    -- estimate at all is offered unless more steps are timed than are not,
    -- and the count of untimed ones is reported alongside the number.
    local perStep = seconds / timed

    local total = seconds + (unknown * perStep) + travelSeconds

    return {
        seconds = total,
        low     = total * (1 - Chase.estimateSpread),
        high    = total * (1 + Chase.estimateSpread),
        timed   = timed,
        unknown = unknown,
        travel  = travelSeconds,
        enough  = true,
    }
end

function Chase.DescribeEstimate(chain)
    local estimate = Chase.Estimate(chain)

    if not estimate then
        return nil
    end

    local session = CN:GetModule("Session")

    local function format(seconds)
        return session and session.FormatDuration
            and session.FormatDuration(seconds)
            or (math.floor((seconds or 0) / 60) .. "m")
    end

    if not estimate.enough then
        return CN.WithConfidence(nil, CN.confidence.UNKNOWN) .. " time |cff8a8f96-- "
            .. estimate.unknown .. " of "
            .. (estimate.timed + estimate.unknown)
            .. " steps are kinds of thing this addon has not watched you do "
            .. "often enough to time|r"
    end

    -- THROUGH THE CONVENTION, like every other number this addon prints.
    --
    -- "roughly X to Y" was a fourth grammar for hedging, alongside
    -- `CN.WithConfidence`, "(searched on Normal)" and a bare number -- and
    -- the whole point of a convention is that a player learns it once. A
    -- range IS an estimate; saying so with the addon's own word for it costs
    -- nothing and means the word keeps meaning one thing.
    local text = CN.WithConfidence(
        format(estimate.low) .. " to " .. format(estimate.high),
        CN.confidence.ESTIMATED)

    if estimate.travel > 60 then
        text = text .. " " .. CN.Muted("including " .. format(estimate.travel)
            .. " to get there")
    end

    if estimate.unknown > 0 then
        text = text .. " " .. CN.Muted("(" .. estimate.unknown
            .. (estimate.unknown == 1 and " step untimed, charged at the "
                or " steps untimed, charged at the ")
            .. "rate of the rest)")
    end

    return text
end

------------------------------------------------------------
-- COMMAND
------------------------------------------------------------

local function PrintChain(chain)
    Print(Chase.Summarize(chain))

    local fraction = Chase.Fraction(chain)

    if fraction then
        Print(string.format("  |cff5dd2fb%s|r %s",
            CN.ProgressBar and CN.ProgressBar(fraction, 20) or "",
            CN.PercentText(fraction)))
    end

    local shown = 0

    for _, step in ipairs(chain.steps) do
        if shown >= 12 then
            CN.PrintLine("  |cff8a8f96... and " .. (#chain.steps - shown) .. " more|r")
            break
        end

        -- THE THIRD DECLARATION OF THE SAME FIVE STATES, now the only one.
        --
        -- This file held one as RGB triples, the Goals tab held one as
        -- palette hex, and this chain of `elseif`s held a third -- so a state
        -- could be given a colour in one place and keep two old ones.
        local label = Chase.stateLabels[step.state] or ""

        CN.PrintLine(Chase.StateText(step.state,
            "  " .. (label ~= "" and ("[" .. label .. "] ") or "")
            .. tostring(step.text)))

        shown = shown + 1
    end

    local estimate = Chase.DescribeEstimate(chain)

    if estimate then
        Print("  |cffffc74fTime:|r " .. estimate)
    end

    if chain.character then
        Print("  |cff8a8f96Best character: " .. tostring(chain.character) .. "|r")
    end
end

Chase.PrintChain = PrintChain

CN:RegisterCommand{
    name    = "chase",
    aliases = { "chain", "path" },
    args    = "[<type> <name or id>, or nothing for all goals]",
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
            -- BY NAME, NOT ONLY BY ID.
            --
            -- The store page leads with `/cn chase rep 2600`, and nobody
            -- knows that faction 2600 is the Severed Threads. Meanwhile
            -- `/cn rep`, `/cn mount`, `/cn pet`, `/cn toy`, `/cn title` and
            -- `/cn recipe` had all accepted names for releases -- the
            -- resolvers existed, and the flagship feature did not call them.
            --
            -- The name may contain spaces, so the split takes the first word
            -- as the type and everything after it as the thing.
            local typeText, idText = string.match(args, "^(%S+)%s+(.+)$")

            local objectiveType = typeText and goals.ResolveType(typeText)

            local id, why

            if objectiveType then
                id, why = CN.ResolveObjective(objectiveType, idText)
            end

            if not objectiveType or not id then
                CN.PrintBlock("Usage: " .. CN.Accent("/cn chase <type> <name or id>"), {
                    CN.Muted("e.g. ") .. CN.Accent("/cn chase mount Invincible"),
                    CN.Muted("Types: quest, achievement, mount, pet, toy, "
                        .. "recipe, title, rep, rare, currency"),
                })

                if why then
                    CN.PrintLine(CN.Muted(why))
                end

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
            Print("Nothing pinned. Try |cffffc74f/cn chase mount 1234|r, or")
            Print("|cffffc74f/cn goal <type> <id>|r to pin something first.")
            return
        end

        for _, chain in ipairs(chains) do
            PrintChain(chain)
        end
    end,
}

return Chase
