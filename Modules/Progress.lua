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

    if not seconds then
        return tonumber(date("%Y%m%d"))
    end

    -- The reset that is coming, as an absolute time, identifies the day
    -- unambiguously without needing to know the server's timezone.
    return math.floor((time() + seconds) / 86400)
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

    local today = Progress.CurrentDayKey()

    if store.dayKey ~= today then
        -- A new day. Keep yesterday so "yesterday you did 84" is possible
        -- later, but do not accumulate an unbounded history.
        store.previousDay      = store.today or 0
        store.previousDayKey   = store.dayKey
        store.today            = 0
        store.dayKey           = today
    end

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
        local today = Progress.CurrentDayKey()

        if store.dayKey ~= today then
            store.previousDay    = store.today or 0
            store.previousDayKey = store.dayKey
            store.today          = 0
            store.dayKey         = today
        end
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
            Print("|cffffd100" .. CN.Comma(summary.lifetime)
                .. "|r quests completed on this character.")
        else
            Print("The client will not report a lifetime total right now.")
        end

        Print("Today: |cffffff00" .. summary.today .. "|r"
            .. (summary.best > 0 and ("   |cff999999best day: "
                .. summary.best .. "|r") or ""))

        if summary.session > 0 then
            local line = "This session: |cffffff00" .. summary.session .. "|r"

            if summary.perHour then
                line = line .. string.format(
                    "   |cff999999%.0f per hour|r", summary.perHour)
            end

            Print(line)
        end

        if summary.previous then
            Print("|cff999999Previous day: " .. summary.previous .. "|r")
        end
    end,
}

return Progress
