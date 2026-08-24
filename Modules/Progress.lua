-- Modules/Progress.lua
-- Completion Navigator :: how much you have actually done.
--
-- REPORTED FROM LIVE PLAY: "It doesn't show how many quests I've completed
-- anymore, which I kinda liked seeing. But my first weekend, I did 350+
-- quests, so I think I can definitely do even more."
--
-- That is the whole design brief in two sentences, and the second one is the
-- important half. He is not asking for a statistic. He is asking for the
-- thing that made him want to beat his own number -- and 0.26.1 took it away
-- while fixing something else, which is a fair trade only if it comes back
-- better.
--
-- Better means: a number the client will vouch for, rather than a count of
-- rows this addon happened to write. `C_QuestLog.GetAllCompletedQuestIDs`
-- returns every quest this character has ever finished. That is the real
-- lifetime total, it is correct on a fresh install with no scan history, and
-- it does not saturate.
--
-- On top of it, the numbers that make a session feel like progress: what you
-- have done since you logged in, what you have done today, and the rate.
-- Those the addon does have to keep itself, so they are stored per character
-- and reset on the game's own clock rather than on a timer of our invention.

local ADDON_NAME, CN = ...

local Progress = CN:RegisterModule("Progress")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint

local Blizzard = CN.Blizzard

------------------------------------------------------------
-- STORAGE
------------------------------------------------------------

local function Store()
    local character = CN.character

    if not character then
        return nil
    end

    character.progress = character.progress or {}

    return character.progress
end

Progress.Store = Store

-- Where the session began. Held in memory only: a session is by definition
-- the thing that ends when you log out.
local sessionStart = {
    completed = nil,
    at        = nil,
}

------------------------------------------------------------
-- THE REAL TOTAL
------------------------------------------------------------

-- Lifetime quests completed by this character, straight from the client.
-- Nil, not zero, when the client will not say -- an unknown total and a
-- total of none are different facts.
--
-- CACHED, and it needed to be.
--
-- `C_QuestLog.GetAllCompletedQuestIDs` does not hand back a number. It builds
-- and returns a table containing every quest the character has ever finished
-- -- tens of thousands of entries for anyone who has played a while, and this
-- addon is aimed squarely at people who have. The Journey tab called it on
-- every refresh to display one integer, allocating and discarding the
-- player's entire quest history to count it.
--
-- The count only changes when a quest is turned in, and the addon already
-- gets told when that happens. So: read it once, keep the number, and throw
-- the cache away on the event that can change it.
-- INVALIDATION, and a trap I walked into while writing it.
--
-- The obvious event list is "anything that could change the count", which
-- includes QUEST_LOG_UPDATE. That event fires many times a second during
-- normal play, so hooking it handed the entire saving straight back -- the
-- benchmark went from 0.000ms to 0.244ms, which is to say back to uncached.
-- A cache invalidated by a firehose is not a cache.
--
-- So: invalidate precisely on the events that certainly change the number,
-- and bound the staleness for anything that slips through. A count that is
-- at most a minute out of date is not a problem; a count that costs the
-- player's entire quest history to display is.
local lifetimeCache = { value = nil, valid = false, at = 0 }

Progress.lifetimeMaxAgeSeconds = 60

function Progress.InvalidateLifetime()
    lifetimeCache.valid = false
    lifetimeCache.value = nil
end

function Progress.LifetimeCompleted()
    if lifetimeCache.valid
        and (time() - lifetimeCache.at) < Progress.lifetimeMaxAgeSeconds then

        return lifetimeCache.value
    end

    local ids = Blizzard.GetAllCompletedQuestIDs()

    -- A nil answer is cached too. The client refusing to say is a stable
    -- fact for the moment, and re-asking on every refresh in the hope of a
    -- different answer is the same waste with extra steps.
    lifetimeCache.value = ids and #ids or nil
    lifetimeCache.valid = true
    lifetimeCache.at    = time()

    return lifetimeCache.value
end

------------------------------------------------------------
-- DAY BOUNDARIES
------------------------------------------------------------

-- "Today" means the game's day, which turns over at the daily reset rather
-- than at your local midnight. Using local midnight would show a player a
-- number that disagrees with everything else the game tells them.
function Progress.CurrentDayKey()
    local seconds = Blizzard.GetSecondsUntilDailyReset()

    -- BOTH BRANCHES ON THE SAME SCALE.
    --
    -- The fallback returned `20260822` where the primary returns about
    -- `20687` -- a day index and a calendar number, two different kinds of
    -- integer. One nil answer from the client, which happens during a loading
    -- screen or early in a login, read as a day rollover: the player's count
    -- for today was moved into "yesterday" mid-session and today restarted at
    -- one. The next genuine reset then compared against a key on the wrong
    -- scale and did it again.
    --
    -- Without the reset time the day boundary is unknowable, so the fallback
    -- uses the same day-index arithmetic with no offset. It can be off by
    -- one against the game's day; it cannot be off by six orders of
    -- magnitude.
    --
    -- SAME SCALE WAS NOT ENOUGH. 0.61.0.
    --
    -- The two branches are now the same KIND of integer, which fixed the six-
    -- orders-of-magnitude version of this bug. They are still not the same
    -- NUMBER: `time() / 86400` and `(time() + seconds) / 86400` land on
    -- different day indices for every hour of the day after the reset offset
    -- pushes past midnight UTC -- which is most of the day, for most realms.
    --
    -- So the smaller version of the original bug survived: one nil answer
    -- during a loading screen still flipped the key, moved today's count into
    -- yesterday, and restarted today at one. A player who zoned into a
    -- dungeon watched their daily total reset, which is precisely the
    -- complaint the first fix was written for.
    --
    -- The reset instant is an ABSOLUTE time and it does not move. Read it
    -- once and it can be carried forward through any number of silent
    -- moments, rolled forward a day at a time as it passes. The client's
    -- silence stops being an event.
    local now = time()

    if seconds then
        Progress.knownResetAt = now + seconds
    elseif Progress.knownResetAt then
        -- Carried forward. A day at a time, so a session left running over
        -- several resets still lands on the right one.
        while Progress.knownResetAt <= now do
            Progress.knownResetAt = Progress.knownResetAt + 86400
        end
    else
        -- NEVER READ ONE THIS SESSION, AND THE FALLBACK MUST NOT BE A
        -- DIFFERENT KIND OF ANSWER.
        --
        -- The first version of this returned `math.floor(now / 86400)` while
        -- the normal path returns `math.floor((now + secondsToReset) / 86400)`
        -- -- and those land on different day indices for most of the day on
        -- most realms. So the original bug survived, narrowed: a quest handed
        -- in during the seconds before the client first answers was filed
        -- under one key, the client then answered, the key moved, and the
        -- rollover branch dutifully shovelled today's count into "yesterday"
        -- and restarted today at one. That is the complaint this was written
        -- to fix, in a smaller window.
        --
        -- The fix is to assume a boundary rather than to assume none. The
        -- reset is somewhere in the next 24 hours by definition, so half a
        -- day is the estimate with the smallest worst-case error -- and it is
        -- REMEMBERED, so every reader this session agrees with every other.
        -- The moment the client speaks, the branch above replaces it with the
        -- real instant.
        --
        -- Replacing an estimate with the truth can still move the key once,
        -- which is a real rollover as far as `NoteCompleted` is concerned. So
        -- the estimate is recorded, and the rollover check below skips a
        -- transition out of it: one provisional key, promoted, not a day
        -- boundary crossed.
        Progress.knownResetAt   = now + 43200
        Progress.resetIsEstimate = true

        return math.floor(Progress.knownResetAt / 86400)
    end

    -- Reached only via the two branches above; the client has now spoken at
    -- some point this session.
    --
    -- WRITTEN AS AN `if`, NOT AS `seconds and false or held`.
    --
    -- That idiom cannot produce `false`: `seconds and false` is `false`, and
    -- `false or held` is `held` -- so the flag stayed true forever and the
    -- provisional key was never promoted. It is the single most common Lua
    -- trap there is and I walked straight into it while fixing a different
    -- bug; the suite caught it because the assertion was written first.
    if seconds then
        Progress.resetIsEstimate = false
    end

    -- The reset that is coming, as an absolute time, identifies the day
    -- unambiguously without needing to know the server's timezone.
    return math.floor(Progress.knownResetAt / 86400)
end

-- Whether the day key this session has handed out so far was the estimate
-- rather than the client's own reset instant. In memory deliberately: see
-- `RollDay`.
local estimatedKey = false

-- ONE ROLLOVER, IN ONE PLACE. 0.61.0.
--
-- The day-boundary rule was written out twice -- once in `NoteCompleted` and
-- once in `BeginSession` -- and 0.61.0 was about to make that three times.
-- This project has now found the same "two copies of a rule, one of which
-- nobody updates" defect in the invalidator, the window's refresh events and
-- the collection generation. It is not going to be introduced here on
-- purpose.
--
-- Returns the current day key, having rolled the store over if the day has
-- genuinely changed.
function Progress.RollDay(store)
    local today = Progress.CurrentDayKey()

    if not store then
        return today
    end

    -- A PROVISIONAL KEY BEING REPLACED IS NOT A NEW DAY.
    --
    -- Before the client has said when the reset is, the key is an estimate
    -- (see `CurrentDayKey`). When the real instant arrives the key can move
    -- once, and shovelling today's count into "yesterday" over that is the
    -- exact bug this whole area exists to prevent. Adopt the corrected key
    -- and keep the count.
    --
    -- THE FLAG IS SESSION STATE, NOT SAVED STATE. This lived on `store` for
    -- one draft, and `store` is SavedVariables -- so a session that ended
    -- while the key was still provisional left the flag set on disk, and the
    -- FOLLOWING day's login promoted a genuinely stale key instead of rolling
    -- it over. The player would come back the next morning and find
    -- yesterday's number labelled "today", which is the bug the login
    -- rollover exists to prevent, reintroduced by the fix for a different
    -- one. It is a local, and a new session starts with it clear.
    if store.dayKey ~= today and estimatedKey
        and not Progress.resetIsEstimate then

        store.dayKey = today
    end

    estimatedKey = Progress.resetIsEstimate and true or false

    if store.dayKey ~= today then
        -- A new day. Keep yesterday so "yesterday you did 84" is possible
        -- later, but do not accumulate an unbounded history.
        store.previousDay    = store.today or 0
        store.previousDayKey = store.dayKey
        store.today          = 0
        store.dayKey         = today
    end

    return today
end

------------------------------------------------------------
-- RECORDING
------------------------------------------------------------

-- Called when the client tells us a quest was turned in.
function Progress.NoteCompleted(questID)
    local store = Store()

    if not store then
        return
    end

    local today = Progress.RollDay(store)

    store.today   = (store.today or 0) + 1
    store.session = (store.session or 0) + 1
    store.total   = (store.total or 0) + 1

    if (store.best or 0) < store.today then
        store.best    = store.today
        store.bestDay = today
    end

    DebugPrint("Quest " .. tostring(questID) .. " completed; "
        .. store.today .. " today.")
end

function Progress.BeginSession()
    local store = Store()

    if store then
        store.session = 0

        -- Roll the day over at login too, so a player who logs in the next
        -- morning does not see yesterday's number labelled "today".
        Progress.RollDay(store)
    end

    sessionStart.completed = Progress.LifetimeCompleted()
    sessionStart.at        = time()
end

------------------------------------------------------------
-- THE NUMBERS
------------------------------------------------------------

-- Everything worth showing, in one table. Fields are nil rather than zero
-- when the client has not answered, so callers can tell the difference.
function Progress.Summary()
    local store = Store() or {}

    local summary = {
        lifetime = Progress.LifetimeCompleted(),
        today    = store.today or 0,
        session  = store.session or 0,
        best     = store.best or 0,
        previous = store.previousDay,
    }

    -- Prefer the client's own delta for the session where we have it: it
    -- counts quests completed by any means, including ones the addon did not
    -- see an event for.
    if sessionStart.completed and summary.lifetime then
        local delta = summary.lifetime - sessionStart.completed

        if delta >= 0 then
            summary.session = math.max(summary.session, delta)
        end
    end

    if sessionStart.at then
        summary.sessionSeconds = time() - sessionStart.at

        -- A rate needs enough time behind it to mean anything. Five minutes
        -- in, "240 quests per hour" is arithmetic, not information.
        if summary.sessionSeconds >= 600 and summary.session > 0 then
            summary.perHour = summary.session / (summary.sessionSeconds / 3600)
        end
    end

    return summary
end

function Progress.Describe()
    local summary = Progress.Summary()

    local parts = {}

    if summary.lifetime then
        table.insert(parts, CN.Comma(summary.lifetime) .. " quests completed")
    end

    table.insert(parts, summary.today .. " today")

    if summary.session > 0 and summary.session ~= summary.today then
        table.insert(parts, summary.session .. " this session")
    end

    if summary.perHour then
        table.insert(parts, string.format("%.0f/hour", summary.perHour))
    end

    return table.concat(parts, ", ")
end

------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

CN:RegisterEvent("QUEST_TURNED_IN", function(_, questID)
    Progress.InvalidateLifetime()

    Progress.NoteCompleted(questID)
end)

-- Abandoning a quest cannot lower the completed count, but a fresh login on
-- a different character certainly changes it, and so does the client
-- finishing its initial data load.
CN:RegisterEvent("PLAYER_ENTERING_WORLD", function()
    Progress.InvalidateLifetime()
end)

-- Deliberately NOT hooked to QUEST_LOG_UPDATE. See the note on the cache:
-- that event fires constantly and hooking it removed the entire benefit.
-- Anything completed by a route the addon cannot see is picked up by the
-- staleness bound instead.

CN:OnLogin(function()
    Progress.BeginSession()
end)

------------------------------------------------------------
-- COMMAND
------------------------------------------------------------

CN:RegisterCommand{
    name    = "progress",
    aliases = { "done", "stats" },
    order   = 11,
    help    = "How many quests you have completed: lifetime, today, this session.",
    handler = function()
        local summary = Progress.Summary()

        if summary.lifetime then
            Print("|cffffc74f" .. CN.Comma(summary.lifetime)
                .. "|r quests completed on this character.")
        else
            Print("The client will not report a lifetime total right now.")
        end

        Print("Today: |cffffc74f" .. summary.today .. "|r"
            .. (summary.best > 0 and ("   |cff8a8f96best day: "
                .. summary.best .. "|r") or ""))

        if summary.session > 0 then
            local line = "This session: |cffffc74f" .. summary.session .. "|r"

            if summary.perHour then
                line = line .. string.format(
                    "   |cff8a8f96%.0f per hour|r", summary.perHour)
            end

            Print(line)
        end

        if summary.previous then
            Print("|cff8a8f96Previous day: " .. summary.previous .. "|r")
        end
    end,
}

return Progress
