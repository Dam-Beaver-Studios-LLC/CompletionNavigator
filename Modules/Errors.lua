-- Modules/Errors.lua
-- Completion Navigator :: what went wrong, kept where the player can find it.
--
-- WHY.
--
-- Every bug report this project has received has been prose. "The arrow does
-- not turn around." I guessed from that description twice and was wrong twice,
-- and the fix both times was to build an instrument -- /cn navdiag, then
-- /cn selftest -- so that the next report could carry evidence instead of
-- adjectives.
--
-- This is the same move applied to errors themselves. The addon already wraps
-- its risky work in pcall, which is why a failure inside a candidate provider
-- does not break the player's session. The cost of that is that the failure is
-- invisible: it happened, something was quietly missing from a list, and
-- nobody will ever know.
--
-- So: keep them. A short ring buffer, in memory, that /cn errors prints.
--
-- WHAT THIS IS NOT.
--
-- It is not telemetry. Nothing is sent anywhere -- an addon cannot send
-- anything anywhere -- and nothing is written to disk, because an error from
-- three weeks ago is noise and a growing error log is a leak.

local ADDON_NAME, CN = ...

local Errors = CN:RegisterModule("Errors")

local Print = CN.Print

-- Twenty is enough to see a pattern and short enough that the memory cost is
-- irrelevant. When it fills, the oldest goes: the recent ones are the ones
-- somebody is trying to explain.
Errors.capacity = 20

local ring = {}

local seen = {}

-- ONE-TIME NOTICES: THINGS THE ADDON OWES THE PLAYER AN EXPLANATION FOR.
-- 0.74.0.
--
-- Distinct from an error, which is a defect caught as it happened. A notice
-- is a statement about something already done and not undoable -- so far,
-- exactly one: the friendship ranks that version 0.72.0's migration deleted
-- from every character that was not logged in at the time.
--
-- Shown once, at login, then kept where `/cn errors` can find it, because a
-- player who logs in during a raid will not read the chat frame and should
-- still be able to go and look.
function Errors.Notices()
    return CN.Account("notices")
end

function Errors.ShowNotices()
    local notices = Errors.Notices()

    local unseen = {}

    for _, notice in ipairs(notices) do
        if type(notice) == "table" and not notice.seen and notice.text then
            table.insert(unseen, notice)
        end
    end

    if #unseen == 0 then
        return 0
    end

    local lines = {}

    for _, notice in ipairs(unseen) do
        notice.seen = true

        table.insert(lines, tostring(notice.text))
    end

    CN.PrintBlock("Something you should know:", lines)

    return #unseen
end

-- DELAYED, so it lands after the login chatter rather than inside it.
-- 0.75.0.
--
-- `OnLogin` handlers run synchronously inside `PLAYER_LOGIN`, immediately
-- after the version banner and every other addon's. This is a one-time
-- explanation of data the addon destroyed and cannot restore, and 0.74.0
-- printed it at the single worst moment and then marked it seen on the way
-- past -- so the one chance to read it was the one moment nobody reads.
--
-- `Setup.RemindIfNeeded` solves exactly this and says so; this is that.
Errors.noticeDelaySeconds = 12

CN:OnLogin(function()
    -- ANYTHING THAT COMPLAINED BEFORE THIS MODULE EXISTED. 0.98.0.
    --
    -- `Providers/StaticData.lua` loads before this file and reports refused
    -- curated rows -- so its complaint reached a nil module and vanished. It
    -- holds them now, and this is where they arrive. Flushed before the
    -- notice sweep below, so a refusal from load time is in the ring by the
    -- time the player is told there is something to read.
    if CN.Static and CN.Static.FlushComplaints then
        CN.Guard("Static.FlushComplaints", CN.Static.FlushComplaints)
    end

    if C_Timer and C_Timer.After then
        C_Timer.After(Errors.noticeDelaySeconds, function()
            CN.Guard("Errors.ShowNotices", Errors.ShowNotices)
        end)
    else
        CN.Guard("Errors.ShowNotices", Errors.ShowNotices)
    end
end)

-- The whole ring, oldest first. Read by the offline suite, which asserts the
-- eviction bound this buffer exists to keep, and by nothing in the addon --
-- `/cn errors` walks the upvalue directly.
function Errors.All()
    return ring
end

function Errors.Record(context, message)
    if not message then
        return false
    end

    message = tostring(message)

    -- REPEATS ARE COUNTED, NOT LISTED.
    --
    -- A failure inside a ticker fires ten times a second. Twenty identical
    -- lines is not twenty pieces of evidence, and it pushes out the one
    -- different error that would have explained the whole thing.
    local key = tostring(context) .. "|" .. message

    if seen[key] then
        seen[key].count = seen[key].count + 1
        seen[key].last  = time()

        return true
    end

    local entry = {
        context = tostring(context or "?"),
        message = message,
        first   = time(),
        last    = time(),
        count   = 1,
    }

    seen[key] = entry

    table.insert(ring, entry)

    while #ring > Errors.capacity do
        local dropped = table.remove(ring, 1)

        seen[tostring(dropped.context) .. "|" .. dropped.message] = nil
    end

    return true
end

function Errors.Count()
    return #ring
end

function Errors.Clear()
    local count = #ring

    ring = {}
    seen = {}

    return count
end

-- Wraps a call so a failure is recorded rather than swallowed. Returns the
-- same thing pcall does, so it is a drop-in replacement at every site that
-- currently discards the error.
local function Pack(...)
    return select("#", ...), { ... }
end

function Errors.Guard(context, fn, ...)
    -- COUNTED, NOT MEASURED WITH `#`.
    --
    -- This was `local results = { pcall(fn, ...) }` followed by
    -- `CN.Unpack(results)`, which truncates at the first nil: a wrapped
    -- function returning `value, nil` came back as one value, so a "drop-in
    -- replacement" silently changed the arity of whatever it wrapped. `#` on
    -- a table with holes is undefined in both interpreters -- 5.1 and 5.4
    -- happen to agree on the cases here, which is precisely the kind of
    -- agreement this project has learned not to rest on.
    --
    -- `table.pack` does not exist in 5.1, so the count is taken with
    -- `select("#", ...)` inside a varargs helper, which does.
    local count, results = Pack(pcall(fn, ...))

    if not results[1] then
        Errors.Record(context, results[2])
    end

    -- CN.Unpack, not a second copy of it. Core.lua states the rule -- "if a
    -- construct means two things, the addon uses neither directly; it uses
    -- one of these" -- and this file quietly kept its own identical shim
    -- outside the one file that gets audited for exactly this class of
    -- mistake. Equivalent today; the point is that there is one place to fix
    -- it when it is not.
    return CN.Unpack(results, 1, count)
end

CN.Guard = Errors.Guard

------------------------------------------------------------
-- THE PREVIOUS SESSION
------------------------------------------------------------

-- ONE SUMMARY LINE PER ERROR, KEPT ACROSS A LOGOUT.
--
-- The ring buffer is in memory, deliberately: a growing error log is a leak,
-- and an error from three weeks ago is noise. But the case that matters most
-- -- something went wrong, and the player relogged before thinking to look --
-- was exactly the case where the evidence was gone.
--
-- So the counts survive, and nothing else: context, message, and how many
-- times. Cleared whenever the player reads them, and capped at the same size
-- as the live ring.
local function Stored()
    return CN.Account("lastErrors")
end

function Errors.Persist()
    -- A CLEAN SESSION MUST NOT ERASE THE RECORD OF A BAD ONE.
    --
    -- This ran unconditionally on logout, including when nothing had gone
    -- wrong -- so the sequence the feature exists for destroyed its own
    -- evidence: something breaks, the player reloads before thinking to look,
    -- and the reload's empty ring overwrites the record. `/cn errors` then
    -- says nothing has gone wrong, which is true of the last four seconds and
    -- false of the thing the player wanted to report.
    --
    -- Players reload several times an hour. An empty ring is not news, so it
    -- is not written.
    if #ring == 0 then
        return 0
    end

    local stored = Stored()

    for key in pairs(stored) do
        stored[key] = nil
    end

    for index, entry in ipairs(ring) do
        stored[index] = {
            context = entry.context,
            message = entry.message,
            count   = entry.count,
        }
    end

    return #ring
end

function Errors.Previous()
    local rows = {}

    for _, entry in ipairs(Stored()) do
        table.insert(rows, entry)
    end

    return rows
end

function Errors.ForgetPrevious()
    local stored = Stored()

    local count = #stored

    for key in pairs(stored) do
        stored[key] = nil
    end

    return count
end

CN:RegisterEvent("PLAYER_LOGOUT", function()
    Errors.Persist()
end)

CN:RegisterCommand{
    name    = "errors",
    aliases = { "log" },
    args    = "[clear]",
    order   = 43,
    help    = "Anything that went wrong inside the addon this session.",
    handler = function(args)
        if string.lower(CN.Trim(args or "")) == "clear" then
            -- AND THE NOTICES THE PLAYER HAS ALREADY READ. 0.75.0.
            --
            -- `Errors.Clear` empties the in-memory ring. A notice lives in a
            -- persisted account store and 0.74.0 gave it no removal path at
            -- all, so a player who had read and understood it saw it in red
            -- at the top of this command for the life of the account.
            --
            -- Only the ones already shown at login: an unread notice is not
            -- something a command about ERRORS should be able to discard by
            -- accident.
            local notices = Errors.Notices()

            local dropped = 0

            for index = #notices, 1, -1 do
                local notice = notices[index]

                if type(notice) == "table" and notice.seen then
                    table.remove(notices, index)
                    dropped = dropped + 1
                end
            end

            local cleared = Errors.Clear()

            Print("Cleared " .. cleared
                .. CN.Pluralize(cleared, " recorded error.", " recorded errors."))

            if dropped > 0 then
                Print("Cleared " .. dropped .. CN.Pluralize(dropped,
                    " notice.", " notices."))
            elseif #Errors.Notices() > 0 then
                -- SAYS WHY, rather than nothing. An unread notice is not
                -- something a command about errors discards by accident, and
                -- silence here reads as a command that did not work.
                Print("|cff8a8f96" .. #Errors.Notices()
                    .. CN.Pluralize(#Errors.Notices(), " notice is",
                        " notices are")
                    .. " still waiting to be read; run |r"
                    .. CN.Accent("/cn errors")
                    .. "|cff8a8f96 first.|r")
            end

            return
        end

        -- EVENT NAMES THE CLIENT REFUSED.
        --
        -- `CN.RegisterWithClient` has recorded these since 0.49.0, with a
        -- comment saying they are kept "so /cn errors can name it". Nothing
        -- read the table. The secondary path -- recording into this module's
        -- ring -- cannot fire for the sixty-odd files that load before this
        -- one, which includes Travel, the very file whose invented
        -- `NEW_TAXI_NODE` the whole mechanism was written for. A bad event
        -- name today would reproduce the original symptom exactly: silent,
        -- and findable only by reading the source.
        --
        -- Printed first and unconditionally, because a handler that never
        -- runs is the failure most likely to be mistaken for "there is just
        -- nothing to do".
        -- A CACHE THAT SOMEBODY WROTE INTO IS WORTH SAYING OUT LOUD. 0.68.0.
        --
        -- `CN.Memo` notices when a reader has modified what it handed out,
        -- rebuilds rather than serving the damage, and records it -- and the
        -- counter it keeps was written and read by nothing, which is the
        -- state five migrations in this addon exist to clean up. It belongs
        -- here: this is the command whose job is "what went wrong that you
        -- did not see".
        -- ANYTHING THE ADDON DID TO THE PLAYER'S DATA THAT IT CANNOT UNDO.
        -- 0.74.0. Printed here whether or not it has been seen, because this
        -- is the command whose job is "what went wrong that you did not see".
        local notices = Errors.Notices()

        local shown = 0

        for _, notice in ipairs(notices) do
            if type(notice) == "table" and notice.text then
                CN.PrintLine(CN.Bad(tostring(notice.text)))

                -- PRINTING IT IS SHOWING IT. 0.76.0.
                --
                -- `seen` was set only by the login pass, which 0.75.0
                -- deferred twelve seconds -- and `clear` removes only seen
                -- notices. So a player who read the notice HERE and followed
                -- the addon's own instruction got "Cleared 0 recorded
                -- errors", the notice stayed, and the login timer printed the
                -- same block again seconds later.
                notice.seen = true

                shown = shown + 1
            end
        end

        if shown > 0 then
            CN.PrintLine("  " .. CN.Muted("Read it? ")
                .. CN.Accent("/cn errors clear")
                .. CN.Muted(CN.Pluralize(shown, " removes it.",
                    " removes them.")))
        end

        if (CN.memoMutations or 0) > 0 then
            CN.PrintLine(CN.Bad(CN.Count(CN.memoMutations,
                "cached list was", "cached lists were")
                .. " modified after being handed out, and rebuilt."))
            CN.PrintLine("  " .. CN.Muted("Harmless to you; it means a list "
                .. "grew every time it was read until this caught it."))
        end

        local rejected = 0

        for event, why in pairs(CN.rejectedEvents or {}) do
            if rejected == 0 then
                CN.PrintLine("|cffe2564cThe client refused to register these "
                    .. "events, so nothing listening for them ever runs:|r")
            end

            rejected = rejected + 1

            CN.PrintLine(CN.Bad(tostring(event)))
            CN.PrintLine("  " .. CN.Muted(tostring(why)))
        end

        if #ring == 0 then
            local previous = Errors.Previous()

            if #previous > 0 then
                Print("Nothing this session. From the previous one:")

                for _, entry in ipairs(previous) do
                    CN.PrintLine(CN.Bad(tostring(entry.context))
                        .. ((entry.count or 1) > 1
                            and (" |cffffc74fx" .. entry.count .. "|r") or ""))
                    CN.PrintLine("  " .. CN.Muted(tostring(entry.message)))
                end

                Errors.ForgetPrevious()

                Print("|cff8a8f96Shown once, then forgotten.|r")
                return
            end

            -- A NOTICE COUNTS TOWARDS "SOMETHING WAS SAID". 0.75.0.
            --
            -- 0.74.0 printed the notice in red at the top of this handler
            -- and then, if the ring happened to be empty, followed it
            -- immediately with "Nothing has gone wrong this session." Two
            -- contradictory statements, adjacent, in the command whose whole
            -- job is to be trustworthy about failures. The `rejected` branch
            -- one line up already knew to say "nothing ELSE".
            if rejected > 0 or shown > 0 then
                Print("Nothing else has gone wrong this session.")
                return
            end

            Print("Nothing has gone wrong this session.")
            Print("|cff8a8f96Errors inside the addon are caught so they "
                .. "cannot break your session" .. CN.DASH .. "which is also why they would "
                .. "otherwise be invisible. They are recorded here instead.|r")
            return
        end

        Print(#ring .. CN.Pluralize(#ring, " error", " errors")
            .. " recorded this session:")

        for _, entry in ipairs(ring) do
            CN.PrintLine(CN.Bad(entry.context)
                .. (entry.count > 1 and (" |cffffc74fx" .. entry.count .. "|r") or ""))
            CN.PrintLine("  " .. CN.Muted(entry.message))
        end

        Print("|cff8a8f96Paste this into a bug report along with "
            .. "|cffffc74f/cn selftest|r output.|r")
    end,
}

return Errors
