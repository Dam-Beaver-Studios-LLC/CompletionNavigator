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

------------------------------------------------------------
-- TYPE FILTERING
------------------------------------------------------------

-- Which KINDS of objective the recommendation list may contain.
--
-- Distinct from ignore and defer, which hide one specific objective. This is a
-- standing preference about what you want to be told about at all: someone
-- levelling wants quests, someone finishing a collection does not.
--
-- Only DISABLED types are stored. That way a type added in a later release is
-- enabled by default rather than silently invisible to everyone who upgraded,
-- which is the failure mode of storing an allow-list.
local function HiddenTypes()
    local settings = CN.Settings()

    if not settings then
        return {}
    end

    settings.hiddenTypes = settings.hiddenTypes or {}

    return settings.hiddenTypes
end

Filters.HiddenTypes = HiddenTypes

-- Bumped whenever the filter changes, so the ranked list knows to rebuild
-- without invalidating the providers, which have not changed at all.
CN.typeFilterGeneration = 0

local function Bump()
    CN.typeFilterGeneration = (CN.typeFilterGeneration or 0) + 1
end

function Filters.IsTypeEnabled(objectiveType)
    if not objectiveType then
        return true
    end

    local hidden = HiddenTypes()

    if next(hidden) == nil then
        return true
    end

    return not hidden[objectiveType]
end

function Filters.SetTypeEnabled(objectiveType, enabled)
    if not objectiveType then
        return false
    end

    local hidden = HiddenTypes()

    if enabled then
        hidden[objectiveType] = nil
    else
        hidden[objectiveType] = true
    end

    Bump()

    return true
end

function Filters.ToggleType(objectiveType)
    local enabled = Filters.IsTypeEnabled(objectiveType)

    Filters.SetTypeEnabled(objectiveType, not enabled)

    return not enabled
end

function Filters.EnableAllTypes()
    local hidden = HiddenTypes()

    local count = CN.CountKeys(hidden)

    for key in pairs(hidden) do
        hidden[key] = nil
    end

    Bump()

    return count
end

-- Everything except this one.
function Filters.OnlyType(objectiveType)
    local hidden = HiddenTypes()

    for key in pairs(hidden) do
        hidden[key] = nil
    end

    for _, known in ipairs(Filters.TypeOrder()) do
        if known ~= objectiveType then
            hidden[known] = true
        end
    end

    Bump()

    return true
end

-- The types worth offering, in a stable order. Deliberately not every entry in
-- CN.objectiveTypes: VENDOR and COLLECTIBLE are internal plumbing rather than
-- things anyone would choose to be shown.
function Filters.TypeOrder()
    local types = CN.objectiveTypes

    return {
        types.QUEST,
        types.ACHIEVEMENT,
        types.REPUTATION,
        types.PET,
        types.MOUNT,
        types.TOY,
        types.APPEARANCE,
        types.RECIPE,
        types.PROFESSION,
        types.RARE,
        types.TREASURE,
        types.EXPLORATION,
        types.TITLE,
        types.CURRENCY,
        types.INSTANCE,
    }
end

-- Friendly names, because "APPEARANCE" is how the code thinks and not how a
-- person reads a checkbox.
Filters.typeLabels = {
    QUEST       = "Quests",
    ACHIEVEMENT = "Achievements",
    REPUTATION  = "Reputations",
    PET         = "Battle pets",
    MOUNT       = "Mounts",
    TOY         = "Toys",
    APPEARANCE  = "Appearances",
    RECIPE      = "Recipes",
    PROFESSION  = "Professions",
    RARE        = "Rares",
    TREASURE    = "Treasures",
    EXPLORATION = "Exploration",
    TITLE       = "Titles",
    CURRENCY    = "Currencies",
    INSTANCE    = "Dungeons & raids",
}

function Filters.TypeLabel(objectiveType)
    return Filters.typeLabels[objectiveType] or tostring(objectiveType)
end

-- Accepts what a person would actually type.
function Filters.ResolveType(text)
    if not text or text == "" then
        return nil
    end

    local needle = string.lower(CN.Trim(text))

    for _, objectiveType in ipairs(Filters.TypeOrder()) do
        if string.lower(objectiveType) == needle
            or string.lower(Filters.TypeLabel(objectiveType)) == needle then
            return objectiveType
        end

        -- "quest" should match QUEST, "pet" should match PET.
        if string.lower(Filters.TypeLabel(objectiveType)):find(needle, 1, true) then
            return objectiveType
        end
    end

    return nil
end

function Filters.HiddenTypeCount()
    return CN.CountKeys(HiddenTypes())
end

-- Exposed on CN so the scoring layer can consult it without knowing that a
-- Filters module exists.
function CN.IsObjectiveTypeEnabled(objectiveType)
    return Filters.IsTypeEnabled(objectiveType)
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

    -- Cached name first, then ask the client.
    --
    -- Names used to come only from a previous scan, so pinning something the
    -- addon had not seen yet produced "Faction 2600" -- which is the addon
    -- telling the player it does not know what they just asked for. The
    -- client knows. Ask it.
    if objectiveType == types.REPUTATION and numericID then
        local cached = CN.Account("factionNames")[numericID]

        if cached then
            return cached
        end

        local data = CN.Blizzard.GetFactionByID(numericID)

        return (data and data.name) or ("Faction " .. numericID)
    end

    if objectiveType == types.PET and numericID then
        -- The client's journal first: since 0.36.0 the addon no longer keeps
        -- its own copy of every pet name on disk.
        local live = CN.Blizzard.GetPetName(numericID)

        if live then
            return live
        end

        local record = CN.Account("pets")[numericID]

        return (record and record.name) or ("Pet " .. numericID)
    end

    if objectiveType == types.MOUNT and numericID then
        local record = CN.Account("mounts")[numericID]

        if record and record.name then
            return record.name
        end

        local live = CN.Blizzard.GetMountByID(numericID)

        return (live and live.name) or ("Mount " .. numericID)
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

        if record and record.name then
            return record.name
        end

        return CN.Blizzard.GetAchievementName(numericID)
            or ("Achievement " .. numericID)
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

------------------------------------------------------------
-- MODES
------------------------------------------------------------

-- Applying a mode is two existing operations performed together, plus a
-- record of what was on before so it can be undone.
function Filters.ApplyMode(name)
    local mode = CN.modes[name]

    if not mode then
        return false, "No such mode."
    end

    local settings = CN.Settings()

    -- Remember what to go back to. One level deep on purpose: an undo stack
    -- for a display preference is a feature nobody asked for.
    settings.modePrevious = {
        profile = settings.priorityMode,
        hidden  = {},
    }

    for _, objectiveType in ipairs(Filters.TypeOrder()) do
        if not Filters.IsTypeEnabled(objectiveType) then
            table.insert(settings.modePrevious.hidden, objectiveType)
        end
    end

    settings.priorityMode = mode.profile or "balanced"

    Filters.EnableAllTypes()

    if mode.show then
        local wanted = {}

        for _, objectiveType in ipairs(mode.show) do
            wanted[objectiveType] = true
        end

        for _, objectiveType in ipairs(Filters.TypeOrder()) do
            if not wanted[objectiveType] then
                Filters.SetTypeEnabled(objectiveType, false)
            end
        end
    end

    settings.mode = name

    CN.InvalidateCandidates("mode")

    return true, mode
end

function Filters.CurrentMode()
    local settings = CN.Settings()

    return settings and settings.mode, settings and CN.modes[settings.mode]
end

function Filters.ClearMode()
    local settings = CN.Settings()

    local previous = settings.modePrevious

    Filters.EnableAllTypes()

    if previous then
        settings.priorityMode = previous.profile or "balanced"

        for _, objectiveType in ipairs(previous.hidden or {}) do
            Filters.SetTypeEnabled(objectiveType, false)
        end
    end

    settings.mode         = nil
    settings.modePrevious = nil

    CN.InvalidateCandidates("mode")

    return true
end

CN:RegisterCommand{
    name    = "show",
    aliases = { "types" },
    args    = "[type, only <type>, or all]",
    order   = 17,
    help    = "Choose which kinds of objective appear in recommendations.",
    handler = function(args)
        args = CN.Trim(args or "")

        local lowered = string.lower(args)

        if lowered == "all" then
            local restored = Filters.EnableAllTypes()

            Print("Showing every type again"
                .. (restored > 0 and (" (" .. restored .. " restored)") or "") .. ".")

        elseif lowered:match("^only%s+") then
            local wanted = Filters.ResolveType(lowered:gsub("^only%s+", ""))

            if not wanted then
                Print("Not a type: " .. args)
                Print("|cffffff00/cn show|r lists them.")
                return
            end

            Filters.OnlyType(wanted)

            Print("Showing only " .. Filters.TypeLabel(wanted) .. ".")

        elseif args ~= "" then
            local wanted = Filters.ResolveType(args)

            if not wanted then
                Print("Not a type: " .. args)
                Print("|cffffff00/cn show|r lists them.")
                return
            end

            local nowEnabled = Filters.ToggleType(wanted)

            Print(Filters.TypeLabel(wanted) .. ": " .. CN.YesNo(nowEnabled))
        end

        local hiddenCount = Filters.HiddenTypeCount()

        Print("Recommendation types"
            .. (hiddenCount > 0 and (" |cffffff00" .. hiddenCount .. " hidden|r") or ""))

        for _, objectiveType in ipairs(Filters.TypeOrder()) do
            local enabled = Filters.IsTypeEnabled(objectiveType)

            Print("  " .. CN.YesNo(enabled) .. " " .. Filters.TypeLabel(objectiveType)
                .. " |cff999999" .. string.lower(objectiveType) .. "|r")
        end

        Print("|cff999999/cn show pets|r toggles one, |cff999999/cn show only quests|r "
            .. "narrows to one, |cff999999/cn show all|r restores everything.")

        if hiddenCount > 0 then
            Print("|cff999999Hidden types still appear in /cn breakdown and the "
                .. "Collections tab; this only filters recommendations.|r")
        end
    end,
}

CN:RegisterCommand{
    name    = "percharacter",
    aliases = { "perchar" },
    args    = "[setting]",
    order   = 18,
    help    = "Make a setting apply to this character only.",
    handler = function(args)
        args = string.lower(CN.Trim(args or ""))

        local settings = CN.Settings()

        if args ~= "" then
            if not CN.characterOverridable[args] then
                Print("That setting cannot be set per character: " .. args)
                Print("|cff999999Overridable: priorityMode, autoWaypoint, "
                    .. "arrow, tooltips|r")
                return
            end

            if CN.IsOverridden(args) then
                CN.ClearOverride(args)

                Print(args .. " now follows the account setting again ("
                    .. tostring(settings[args]) .. ").")
            else
                -- Seed the override with whatever this character sees now, so
                -- taking control never changes the current behaviour.
                local ok, message = CN.SetOverride(args, settings[args])

                if not ok then
                    Print(message)
                    return
                end

                Print(args .. " is now set for this character only ("
                    .. tostring(settings[args]) .. ").")
            end
        end

        Print("Settings for " .. tostring(CN.characterKey or "this character") .. ":")

        for _, key in ipairs({ "priorityMode", "autoWaypoint", "arrow", "tooltips" }) do
            local overridden = CN.IsOverridden(key)

            Print("  " .. key .. " = " .. tostring(settings[key])
                .. (overridden
                    and " |cffffff00this character only|r"
                    or " |cff999999account-wide|r"))
        end

        Print("|cff999999/cn perchar priorityMode|r toggles whether a setting "
            .. "is shared or per character.")
    end,
}

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
