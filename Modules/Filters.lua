-- Modules/Filters.lua
-- Completion Navigator :: managing what you told the addon to hide.
--
-- Ignore and defer have existed since the first build, and until now there
-- was no way to see either list or undo anything in them. Ignoring something
-- by accident meant it was gone permanently with no recourse, which is a
-- bug wearing a feature's clothes.
--
-- Defer also only offered one hour. The spec asked for a real set of
-- durations, and "until the weekly reset" is the one that actually matches
-- how the game works.

local ADDON_NAME, CN = ...

local Filters = CN:RegisterModule("Filters")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint

local HOUR = 3600
local DAY  = 86400

------------------------------------------------------------
-- DURATIONS
------------------------------------------------------------

-- Ordered, because they are offered as a list in the UI.
Filters.durations = {
    { key = "hour",    label = "1 hour",        seconds = HOUR },
    { key = "day",     label = "Today",         seconds = DAY },
    { key = "tomorrow",label = "Tomorrow",      seconds = 2 * DAY },
    { key = "week",    label = "This week",     seconds = 7 * DAY },
    { key = "reset",   label = "Until reset",   seconds = nil },  -- computed
    { key = "forever", label = "Until I undo it", seconds = math.huge },
}

function Filters.SecondsFor(key)
    for _, duration in ipairs(Filters.durations) do
        if duration.key == key then
            if duration.key == "reset" then
                local opportunities = CN:GetModule("Opportunities")

                if opportunities then
                    local resets = opportunities.GetResets()

                    -- Weekly if it is sooner than a week away, else daily.
                    return resets.weekly or resets.daily or DAY
                end

                return DAY
            end

            return duration.seconds
        end
    end

    return nil
end

------------------------------------------------------------
-- READING THE LISTS
------------------------------------------------------------

-- Objective keys are "TYPE:id". Splitting them back out is what lets the
-- lists show a name rather than an opaque string.
local function SplitKey(key)
    local objectiveType, id = string.match(tostring(key), "^(.-):(.+)$")

    return objectiveType, tonumber(id) or id
end

Filters.SplitKey = SplitKey

-- Best-effort name for anything the addon might have hidden.
function Filters.DescribeObjective(objectiveType, id)
    local types = CN.objectiveTypes

    local numericID = tonumber(id)

    if objectiveType == types.QUEST and numericID then
        return CN.GetQuestName(numericID) or ("Quest " .. numericID)
    end

    if objectiveType == types.REPUTATION and numericID then
        return CN.Account("factionNames")[numericID] or ("Faction " .. numericID)
    end

    if objectiveType == types.PET and numericID then
        local record = CN.Account("pets")[numericID]
        return record and record.name or ("Pet " .. numericID)
    end

    if objectiveType == types.MOUNT and numericID then
        local record = CN.Account("mounts")[numericID]
        return record and record.name or ("Mount " .. numericID)
    end

    if objectiveType == types.TOY and numericID then
        local record = CN.Account("toys")[numericID]
        return record and record.name or ("Toy " .. numericID)
    end

    if (objectiveType == types.RARE or objectiveType == types.TREASURE) and numericID then
        local record = CN.Account("rares")[numericID]
        return record and record.name or (objectiveType .. " " .. numericID)
    end

    if objectiveType == types.ACHIEVEMENT and numericID then
        local record = CN.Account("achievements")[numericID]
        return record and record.name or ("Achievement " .. numericID)
    end

    if objectiveType == types.CURRENCY and numericID then
        return CN.Account("currencyNames")[numericID] or ("Currency " .. numericID)
    end

    if objectiveType == types.RECIPE and numericID then
        return CN.Account("recipeNames")[numericID] or ("Recipe " .. numericID)
    end

    if objectiveType == types.TITLE and numericID then
        return CN.Account("titleNames")[numericID] or ("Title " .. numericID)
    end

    return tostring(objectiveType) .. " " .. tostring(id)
end

function Filters.ListIgnored()
    local rows = {}

    for key, entry in pairs(CN.Account("ignoredObjectives")) do
        local objectiveType, id = SplitKey(key)

        table.insert(rows, {
            key   = key,
            type  = objectiveType,
            id    = id,
            name  = Filters.DescribeObjective(objectiveType, id),
            since = entry and entry.since,
        })
    end

    table.sort(rows, function(a, b) return (a.name or "") < (b.name or "") end)

    return rows
end

function Filters.ListDeferred()
    local rows = {}

    local now = time()

    for key, entry in pairs(CN.Account("deferredObjectives")) do
        local objectiveType, id = SplitKey(key)

        local remaining

        if entry and entry.until_ then
            remaining = entry.until_ - now
        end

        table.insert(rows, {
            key       = key,
            type      = objectiveType,
            id        = id,
            name      = Filters.DescribeObjective(objectiveType, id),
            remaining = remaining,
            expired   = remaining ~= nil and remaining <= 0,
        })
    end

    table.sort(rows, function(a, b)
        return (a.remaining or math.huge) < (b.remaining or math.huge)
    end)

    return rows
end

------------------------------------------------------------
-- UNDO
------------------------------------------------------------

function Filters.Restore(key)
    local ignored  = CN.Account("ignoredObjectives")
    local deferred = CN.Account("deferredObjectives")

    local removed = false

    if ignored[key] then
        ignored[key] = nil
        removed = true
    end

    if deferred[key] then
        deferred[key] = nil
        removed = true
    end

    return removed
end

function Filters.RestoreAll()
    local ignored  = CN.Account("ignoredObjectives")
    local deferred = CN.Account("deferredObjectives")

    local count = CN.CountKeys(ignored) + CN.CountKeys(deferred)

    for key in pairs(ignored) do
        ignored[key] = nil
    end

    for key in pairs(deferred) do
        deferred[key] = nil
    end

    return count
end

-- Deferrals that have run out are dead weight in SavedVariables.
function Filters.PruneExpired()
    local deferred = CN.Account("deferredObjectives")

    local now, pruned = time(), 0

    for key, entry in pairs(deferred) do
        if entry and entry.until_ and entry.until_ <= now then
            deferred[key] = nil
            pruned = pruned + 1
        end
    end

    return pruned
end

CN:OnLogin(function()
    local pruned = Filters.PruneExpired()

    if pruned > 0 then
        DebugPrint("Pruned " .. pruned .. " expired deferrals.")
    end
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

local function FormatRemaining(seconds)
    if not seconds then
        return "indefinitely"
    end

    if seconds <= 0 then
        return "expired"
    end

    if seconds < HOUR then
        return math.floor(seconds / 60) .. "m"
    end

    if seconds < DAY then
        return math.floor(seconds / HOUR) .. "h"
    end

    return math.floor(seconds / DAY) .. "d"
end

Filters.FormatRemaining = FormatRemaining

CN:RegisterCommand{
    name    = "hidden",
    aliases = { "ignored" },
    order   = 20,
    help    = "Show everything you have ignored or deferred.",
    handler = function()
        local ignored  = Filters.ListIgnored()
        local deferred = Filters.ListDeferred()

        if #ignored == 0 and #deferred == 0 then
            Print("Nothing is hidden.")
            return
        end

        if #ignored > 0 then
            Print("Ignored (" .. #ignored .. "):")

            for _, row in ipairs(ignored) do
                Print("  " .. row.name .. " |cff999999[" .. tostring(row.type)
                    .. " " .. tostring(row.id) .. "]|r")
            end
        end

        if #deferred > 0 then
            Print("Deferred (" .. #deferred .. "):")

            for _, row in ipairs(deferred) do
                Print("  " .. row.name .. " |cff999999["
                    .. FormatRemaining(row.remaining) .. " left]|r")
            end
        end

        Print("|cffffff00/cn unhide <id>|r to restore one, "
            .. "|cffffff00/cn unhide all|r for everything.")
    end,
}

CN:RegisterCommand{
    name    = "unhide",
    aliases = { "restore" },
    args    = "<id or all>",
    order   = 21,
    help    = "Undo an ignore or a deferral.",
    handler = function(args)
        if args == "" then
            Print("Usage: /cn unhide <id or all>")
            return
        end

        if string.lower(args) == "all" then
            local count = Filters.RestoreAll()

            Print("Restored " .. count .. " hidden objective"
                .. (count == 1 and "" or "s") .. ".")
            return
        end

        local wanted = tostring(CN.ToID(args) or args)

        local restored = 0

        -- Match on the id alone, since the player sees ids and not the
        -- internal TYPE:id key.
        for _, row in ipairs(Filters.ListIgnored()) do
            if tostring(row.id) == wanted then
                if Filters.Restore(row.key) then
                    Print("Restored: " .. row.name)
                    restored = restored + 1
                end
            end
        end

        for _, row in ipairs(Filters.ListDeferred()) do
            if tostring(row.id) == wanted then
                if Filters.Restore(row.key) then
                    Print("Restored: " .. row.name)
                    restored = restored + 1
                end
            end
        end

        if restored == 0 then
            Print("Nothing hidden matches: " .. args)
            Print("Run |cffffff00/cn hidden|r to see the list.")
        end
    end,
}

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
