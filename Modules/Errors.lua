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
function Errors.Guard(context, fn, ...)
    local results = { pcall(fn, ...) }

    if not results[1] then
        Errors.Record(context, results[2])
    end

    -- unpack lives at the top level in the game's Lua 5.1, and on table in
    -- 5.4 where the offline suite runs. Both, so this file works in both.
    local unpackFn = rawget(table, "unpack") or unpack

    return unpackFn(results)
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
            Print("Cleared " .. Errors.Clear() .. " recorded error(s).")
            return
        end

        if #ring == 0 then
            local previous = Errors.Previous()

            if #previous > 0 then
                Print("Nothing this session. From the previous one:")

                for _, entry in ipairs(previous) do
                    Print("  |cfff56b61" .. tostring(entry.context) .. "|r"
                        .. ((entry.count or 1) > 1
                            and (" |cffffff00x" .. entry.count .. "|r") or ""))
                    Print("    |cff999999" .. tostring(entry.message) .. "|r")
                end

                Errors.ForgetPrevious()

                Print("|cff999999Shown once, then forgotten.|r")
                return
            end

            Print("Nothing has gone wrong this session.")
            Print("|cff999999Errors inside the addon are caught so they "
                .. "cannot break your session -- which is also why they would "
                .. "otherwise be invisible. They are recorded here instead.|r")
            return
        end

        Print(#ring .. " error(s) recorded this session:")

        for _, entry in ipairs(ring) do
            Print("  |cfff56b61" .. entry.context .. "|r"
                .. (entry.count > 1 and (" |cffffff00x" .. entry.count .. "|r") or ""))
            Print("    |cff999999" .. entry.message .. "|r")
        end

        Print("|cff999999Paste this into a bug report along with "
            .. "|cffffff00/cn selftest|r output.|r")
    end,
}

return Errors
