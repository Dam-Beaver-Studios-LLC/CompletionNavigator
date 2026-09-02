-- Modules/Opportunities.lua
-- Completion Navigator :: things that expire.
--
-- The scoring formula gives limitedTimeBonus the heaviest weight of any
-- term (3.0), and until this module existed nothing ever set it. The engine
-- was built to prioritise content that disappears and had no idea what
-- disappears.
--
-- That is the whole point of the module: a world quest with two hours left
-- and a permanent quest in the same zone are not equally urgent, and the
-- recommendation should say so.

local ADDON_NAME, CN = ...

local Opportunities = CN:RegisterModule("Opportunities")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

local HOUR = 3600
local DAY  = 86400

------------------------------------------------------------
-- URGENCY
------------------------------------------------------------

-- URGENCY IS THE SCORER'S, AND ONLY THE SCORER'S. 0.88.0.
--
-- `Opportunities.Urgency` lived here, with a header saying it was "now only
-- for callers that have no `expiresIn` to give -- world EVENTS, below". The
-- world-event branch reads `event.endsIn and 0 or 1`, a literal, and has done
-- since 0.63.0: the named caller did not call it, and nothing else in the
-- addon did either.
--
-- Removed rather than kept, because a comment asserting a live contract that
-- does not hold is how the next reader rebuilds a wrong model of the scoring.
-- One deadline, one curve: `expiresIn` and `CN.UrgencyBonus`, which is what
-- `/cn urgency` plots.


-- THE BARE FIGURE, WITH NO CLAUSE ATTACHED.
--
-- `FormatTimeLeft` returns strings that already end in " left", and three
-- callers prepend "in " -- so the Now tab's header read "Resets: daily in 4h
-- left, weekly in 3d left", on every visit, and "daily in unknown time left"
-- when the client would not answer. A formatter that owns the preposition
-- cannot be reused with a different one.
--
-- Same shape as `Vault.FormatReset`, which is what the Vault tab uses for the
-- same clock -- two formats for one quantity in one window.
function Opportunities.FormatSpan(seconds)
    if not seconds then
        return nil
    end

    if seconds <= 0 then
        return nil
    end

    if seconds < HOUR then
        return math.floor(seconds / 60) .. "m"
    end

    if seconds < DAY then
        return math.floor(seconds / HOUR) .. "h"
    end

    return math.floor(seconds / DAY) .. "d"
end

function Opportunities.FormatTimeLeft(seconds)
    -- "UNKNOWN" AND "EXPIRED" ARE DIFFERENT ANSWERS.
    --
    -- `Blizzard.GetQuestTimeLeft` returns nil when the client will not say,
    -- and this collapsed that into "expired". The sort puts unknowns LAST
    -- using `or math.huge`, so a live world quest appeared at the bottom of a
    -- list headed "soonest to expire", labelled expired -- contradicting
    -- itself on the same screen.
    --
    -- The addon has a convention for exactly this and it is used here now.
    if not seconds then
        return CN.WithConfidence(nil, CN.confidence.UNKNOWN) .. " time left"
    end

    if seconds <= 0 then
        return "expired"
    end

    if seconds < HOUR then
        return math.floor(seconds / 60) .. "m left"
    end

    if seconds < DAY then
        return math.floor(seconds / HOUR) .. "h left"
    end

    return math.floor(seconds / DAY) .. "d left"
end

------------------------------------------------------------
-- WORLD QUESTS
------------------------------------------------------------

-- World quests are the largest source of expiring content and the addon
-- could not see a single one before this.
function Opportunities.GetWorldQuests(mapID)
    mapID = mapID or select(1, CN.GetPlayerPosition())

    if not mapID then
        return {}
    end

    local results = {}

    for _, task in ipairs(Blizzard.GetWorldQuestsOnMap(mapID)) do
        local questID = task.questID

        if not Blizzard.IsQuestCompletedByCharacter(questID)
            and not CN.IsIgnored(CN.objectiveTypes.QUEST, questID)
            and not CN.IsDeferred(CN.objectiveTypes.QUEST, questID) then

            local secondsLeft = Blizzard.GetQuestTimeLeft(questID)
            local info        = Blizzard.GetWorldQuestInfo(questID)

            table.insert(results, {
                questID     = questID,
                mapID       = task.mapID,
                x           = task.x,
                y           = task.y,
                name        = info.title or CN.GetQuestName(questID) or ("World quest " .. questID),
                tagName     = info.tagName,
                isElite     = info.isElite,
                secondsLeft = secondsLeft,
            })
        end
    end

    table.sort(results, function(a, b)
        return (a.secondsLeft or math.huge) < (b.secondsLeft or math.huge)
    end)

    return results
end

------------------------------------------------------------
-- RESETS
------------------------------------------------------------

function Opportunities.GetResets()
    return {
        daily  = Blizzard.GetSecondsUntilDailyReset(),
        weekly = Blizzard.GetSecondsUntilWeeklyReset(),
    }
end

------------------------------------------------------------
-- WORLD EVENTS
------------------------------------------------------------

-- Calendar reads are relatively expensive and the answer changes daily, not
-- minute to minute.
-- HOW LONG AN ANSWER IS GOOD FOR, AND HOW LONG A SILENCE IS. 0.98.0.
--
-- The calendar is asynchronous: `C_Calendar.OpenCalendar` asks the server for
-- the month and `GetNumDayEvents` answers zero until it arrives. `CN:OnLogin`
-- warms it by calling this with `force`, which skips the cache READ and then
-- performs the cache WRITE -- so the empty answer was stamped and held for
-- the full half hour.
--
-- For thirty minutes after every login, then, the Darkmoon Faire, a
-- Timewalking week and every holiday were absent from the ranking entirely:
-- no row in `/cn next`, no map pin, no heads-up line, and no "Active events"
-- section in `/cn now`. Only `/cn events` repaired it, because it passes
-- `force` -- and nothing told the player to run it. The addon subscribes to
-- no calendar event, so there was no other invalidator.
--
-- AN EMPTY ANSWER IS NOT CACHED AT ALL.
--
-- The first draft gave a silence a shorter window than an answer, which is
-- what `Instances.dropMissSeconds` does. That is right where re-asking is
-- expensive: the Adventure Guide search is a full `EJ_SetSearch` cycle with a
-- save and restore of the player's own selection.
--
-- Here it is two client calls. `GetNumDayEvents` answers zero and the loop
-- that would walk the events does not run, so re-reading an event-free day
-- costs nothing worth a second constant and a second window to reason about.
-- Not caching it removes the question entirely: an answer is held, a silence
-- is asked again next time, and there is no interval during which the addon
-- is confidently wrong about the Darkmoon Faire.
Opportunities.eventSeconds = 1800

local eventCache, eventCachedAt = nil, 0

-- KEYED ON SOMETHING THE CLIENT'S LANGUAGE CANNOT CHANGE.
--
-- `id = event.title` was a localized string, and Instances.lua carries a
-- header describing that same defect as fixed for lockouts, in as many words:
-- every ignore was lost the day the player changed client language.
--
-- THE FALLBACK STILL HAS TO IDENTIFY THE EVENT. A triple of eventType,
-- calendarType and sequenceType is a description of a KIND of event, not of
-- one -- two ongoing holidays on the same day compose the identical key, and
-- the aggregate dedups on it, so one of them is silently dropped. That is
-- exactly the collapse this was meant to fix. The title goes back into the
-- fallback: it is not stable across languages, but a key that is unstable is
-- better than a key that is not unique, and where the client supplies an
-- eventID neither problem arises.
--
-- `> 0` rather than truthiness: zero is truthy in Lua, so an eventID of 0
-- would give every holiday the same id.
function Opportunities.EventKey(event)
    if type(event) ~= "table" then
        return nil
    end

    if type(event.eventID) == "number" and event.eventID > 0 then
        return event.eventID
    end

    return tostring(event.eventType or "?")
        .. ":" .. tostring(event.calendarType or "?")
        .. ":" .. tostring(event.sequenceType or "?")
        .. ":" .. tostring(event.title or "?")
end

function Opportunities.GetActiveEvents(force)
    -- A DEADLINE IS DERIVED AT READ TIME, NOT AT SCAN TIME.
    --
    -- `endsIn` is a countdown, computed when the calendar was read, and this
    -- list is held for thirty minutes. So the addon printed "ends in 40m"
    -- about an event that had finished ten minutes earlier, and the urgency
    -- ramp -- weight 4.0, and steepest inside the last two hours -- was fed a
    -- figure that could be half an hour wrong exactly where it matters most.
    -- `expiresIn` is an identity field, so the frozen value also let the
    -- provider take the reuse shortcut and nothing corrected it.
    --
    -- `endsAt` is an absolute stamp and cannot go stale.
    -- ENDED IS NOT "NO KNOWN END". 0.88.0.
    --
    -- This correctly nils `endsIn` once the stamp has passed, and left the
    -- row in a cache that lives for thirty minutes. The provider reads a nil
    -- `endsIn` as "an event the client will not date" and awards the flat
    -- bonus for it -- which is worth three points, where a live event three
    -- hours out earns about one and a third. So one nil field ranked a
    -- FINISHED holiday above every event still running, and `/cn now` went
    -- on listing it as active, for up to half an hour.
    --
    -- An event that has ended leaves the list.
    local function Freshen(events)
        local now = time()

        local live = {}

        for _, event in ipairs(events) do
            local keep = true

            if event.endsAt then
                local left = event.endsAt - now

                event.endsIn = (left > 0) and left or nil

                keep = left > 0
            end

            if keep then
                table.insert(live, event)
            end
        end

        return live
    end

    if not force and eventCache
        and (time() - eventCachedAt) < Opportunities.eventSeconds then

        return Freshen(eventCache)
    end

    local active = {}

    for _, event in ipairs(Blizzard.GetTodaysEvents()) do
        if event.ongoing then
            table.insert(active, event)
        end
    end

    if #active > 0 then
        eventCache    = active
        eventCachedAt = time()
    else
        eventCache    = nil
        eventCachedAt = 0
    end

    return Freshen(active)
end

------------------------------------------------------------
-- CANDIDATES
------------------------------------------------------------

CN.RegisterCandidateProvider("Opportunities", function()
    local candidates = {}

    -- Only the map is needed now: travel cost is computed by CN.TravelCost,
    -- which reads the player's position itself so every provider costs a
    -- journey the same way.
    local playerMap = CN.GetPlayerPosition()

    for _, worldQuest in ipairs(Opportunities.GetWorldQuests(playerMap)) do
        local reasons = {}

        if worldQuest.secondsLeft then
            table.insert(reasons, "world quest, "
                .. Opportunities.FormatTimeLeft(worldQuest.secondsLeft))
        else
            table.insert(reasons, "world quest")
        end

        if worldQuest.tagName then
            table.insert(reasons, worldQuest.tagName)
        end

        -- Costed through the real travel model rather than a straight line
        -- and a flat out-of-zone penalty, the same way quests have been
        -- since 0.42.0. World quests are exactly where this matters: they
        -- are scattered across a continent and they expire.
        -- `costed` SAYS WHETHER THE MODEL ANSWERED. See `Rares`. 0.70.0.
        local travel, costed = CN.TravelCost(worldQuest.mapID,
            worldQuest.x, worldQuest.y)

        if worldQuest.mapID == playerMap then
            table.insert(reasons, "in your current zone")
        end

        table.insert(candidates, CN.NewObjective({
            id               = worldQuest.questID,
            type             = CN.objectiveTypes.QUEST,
            name             = worldQuest.name,
            mapID            = worldQuest.mapID,
            x                = worldQuest.x,
            y                = worldQuest.y,
            state            = CN.objectiveStates.AVAILABLE,
            completionValue  = 1,
            -- NOT `limitedTimeBonus`. See the note on `Opportunities.Urgency`:
            -- setting both charged one deadline through two curves, and only
            -- one of them appears in `/cn urgency`.
            travelCost       = travel,
            travelCosted     = costed or nil,
            expiresIn        = worldQuest.secondsLeft,
            reasons          = reasons,
        }))
    end

    -- ACTIVE EVENTS (0.43.0).
    --
    -- The calendar has been read since 0.20.0 and its answers went into
    -- `/cn events` and nowhere else. A holiday or a Timewalking week is a
    -- deadline in exactly the sense the ranking already understands -- it is
    -- gone on a known date and it is not coming back for a year -- so it
    -- belongs in the list rather than in a separate command.
    for _, event in ipairs(Opportunities.GetActiveEvents()) do
        -- THE KEY IS WORKED OUT FIRST, because two things need it.
        --
        -- The ignore and defer guards read one key and the objective was
        -- built with another, so `CN.IsIgnored` looked up a title while
        -- `CN.SetIgnored` had stored an id: hiding a world event did nothing
        -- at all, for ever. Before 0.59.0 the two happened to be the same
        -- string, which is how a change to one of them broke the other.
        local id = Opportunities.EventKey(event)

        if not CN.IsIgnored(CN.objectiveTypes.CURRENCY, id)
            and not CN.IsDeferred(CN.objectiveTypes.CURRENCY, id) then

            local reasons = { "world event, on now" }

            if event.endsIn then
                table.insert(reasons, "ends in "
                    .. Opportunities.FormatTimeLeft(event.endsIn))
            end

            -- Deliberately modest. The addon knows the event is running; it
            -- does not know which of its quests you have done, so claiming
            -- this is your most valuable next action would be a guess.
            table.insert(candidates, CN.NewObjective({
                id               = id,
                type             = CN.objectiveTypes.CURRENCY,
                name             = event.title,
                completionValue  = 2,

                -- THE SAME DOUBLE CHARGE AS THE WORLD QUEST ABOVE. 0.63.0.
                --
                -- This set both terms too, so a Timewalking week was scored
                -- through two independently tuned curves. `expiresIn` is the
                -- one `/cn urgency` plots and the one every other deadline in
                -- the addon uses.
                --
                -- The flat 1 for an event with no known end is kept: an event
                -- the client will not date is still a limited-time thing, and
                -- that is what this term means when there is no deadline to
                -- charge.
                limitedTimeBonus = event.endsIn and 0 or 1,
                travelCost       = CN.placelessCost,
                expiresIn        = event.endsIn,
                reasons          = reasons,
            }))
        end
    end

    return candidates
-- A COOLDOWN, ON EVENTS THAT ARE NOT SINGLE MOMENTS. 0.79.0.
--
-- `QUEST_LOG_UPDATE` fires constantly -- `Modules/Quests.lua` throttles its
-- own handler for that event to ten seconds and says so -- and
-- `CRITERIA_UPDATE` is the canonical chatty one, which `Achievements` and
-- `Loremaster` both give a cooldown and this did not.
--
-- The same defect 0.78.0 fixed for `Modules/Currencies.lua`, left standing
-- two files over. Freshness costs nothing here: a world quest window is
-- hours long and a zone's exploration criteria do not move faster than the
-- player walks.
end, { events = { "QUEST_LOG_UPDATE", "ZONE_CHANGED_NEW_AREA" },
       volatile = true, cooldown = 30 })

------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

CN:RegisterEvent("QUEST_LOG_UPDATE", function()
    -- World quest availability changes constantly; nothing to persist, the
    -- candidate provider reads live each time it is asked.
end)

CN:OnLogin(function()
    -- Warm the calendar so the first /cn events call has data.
    Opportunities.GetActiveEvents(true)
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "now",
    aliases = { "opportunities" },
    order   = 15,
    help    = "Show everything expiring soon.",
    handler = function()
        local resets = Opportunities.GetResets()

        if resets.daily then
            Print("Daily reset: " .. Opportunities.FormatTimeLeft(resets.daily))
        end

        if resets.weekly then
            Print("Weekly reset: " .. Opportunities.FormatTimeLeft(resets.weekly))
        end

        local events = Opportunities.GetActiveEvents()

        if #events > 0 then
            Print("Active events:")

            for _, event in ipairs(events) do
                CN.PrintLine("  " .. event.title)
            end
        end

        local worldQuests = Opportunities.GetWorldQuests()

        if #worldQuests == 0 then
            Print("No world quests available on your current map.")
            return
        end

        Print("World quests here (" .. #worldQuests .. "), soonest to expire:")

        for index = 1, math.min(#worldQuests, 10) do
            local worldQuest = worldQuests[index]

            CN.PrintLine("  " .. index .. ". " .. worldQuest.name
                .. " |cff8a8f96(" .. Opportunities.FormatTimeLeft(worldQuest.secondsLeft)
                .. (worldQuest.tagName and (", " .. worldQuest.tagName) or "") .. ")|r")
        end

        if #worldQuests > 10 then
            Print("  |cff8a8f96... and " .. (#worldQuests - 10) .. " more.|r")
        end
    end,
}

CN:RegisterCommand{
    name    = "events",
    order   = 16,
    help    = "List world events active today.",
    handler = function()
        local events = Opportunities.GetActiveEvents(true)

        if #events == 0 then
            Print("No world events detected as active today.")
            Print("|cff8a8f96The calendar may not have loaded yet; open it once and retry.|r")
            return
        end

        -- WHEN IT ENDS, NOT THE CLIENT'S OWN TOKEN. 0.88.0.
        --
        -- This printed `sequenceType` -- the raw enum string the provider
        -- branches on, "ONGOING" for every row in a list already filtered to
        -- ongoing events. The addon's internals, in brackets, saying nothing
        -- the header did not; the shape `Modules/Filters.lua` records fixing
        -- three separate times.
        --
        -- Meanwhile the one fact worth having -- how long is left, which the
        -- provider two hundred lines up already computes and RANKS on -- was
        -- dropped.
        for _, event in ipairs(events) do
            CN.PrintLine("  " .. event.title
                .. (event.endsIn
                    and CN.Aside(Opportunities.FormatTimeLeft(event.endsIn))
                    or ""))
        end
    end,
}

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
