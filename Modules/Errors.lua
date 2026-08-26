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

function Errors.All()
    return ring
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
            local cleared = Errors.Clear()

            Print("Cleared " .. cleared
                .. CN.Pluralize(cleared, " recorded error.", " recorded errors."))
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

            if rejected > 0 then
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
