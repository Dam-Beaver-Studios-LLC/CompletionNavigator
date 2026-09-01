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

-- Ordered, because they are offered as a list.
--
-- REACHABLE AT LAST. 0.88.0.
--
-- This table had no reader anywhere in the addon: every deferral in the tree
-- was a hardcoded 3600, and there was no command that took a duration -- so
-- the only thing a player could ever do was put something off for an hour.
-- The file header says why the table was written: "Defer also only offered
-- one hour... 'until the weekly reset' is the one that actually matches how
-- the game works."
--
-- Two of the rows could not have worked as written either. `seconds = nil` in
-- a table constructor stores nothing at all, so "until reset" was
-- indistinguishable from a malformed row; and `math.huge` renders through
-- `FormatRemaining` as "infd", which is what `/cn hidden` would have printed
-- the day somebody wired it up. Both are resolved rather than stored now.
Filters.durations = {
    { key = "hour",    label = "1 hour",        seconds = HOUR },
    { key = "day",     label = "Today",         seconds = DAY },
    { key = "tomorrow",label = "Tomorrow",      seconds = 2 * DAY },
    { key = "week",    label = "This week",     seconds = 7 * DAY },
    { key = "reset",   label = "Until reset",   computed = "weeklyReset" },
    { key = "forever", label = "Until I undo it", seconds = math.huge },
}

-- Seconds for a named duration, resolving the one that depends on the clock.
-- Falls back to an hour, which is what every caller used to hardcode.
function Filters.DurationSeconds(key)
    for _, duration in ipairs(Filters.durations) do
        if duration.key == key then
            if duration.computed == "weeklyReset" then
                return CN.Blizzard.GetSecondsUntilWeeklyReset() or DAY
            end

            return duration.seconds
        end
    end

    return HOUR
end

-- The labels, for a command's help and for anything that offers the choice.
function Filters.DurationKeys()
    local keys = {}

    for _, duration in ipairs(Filters.durations) do
        table.insert(keys, duration.key)
    end

    return keys
end

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

-- Friendly names live in Objectives.lua now, beside the enum they name, so
-- that everything which prints a type can reach them -- most of the places
-- that do load long before this file. These two are kept as the names the
-- rest of this module already uses.
Filters.typeLabels = CN.typeLabels

Filters.TypeLabel = CN.TypeLabel

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
    -- THE CLIENT FIRST, THE STORE SECOND. 0.64.0.
    --
    -- This asked the STORE first and the client only when the store was
    -- empty, which is backwards and is the opposite of what the pet, mount
    -- and achievement branches below do. A stored name is frozen at whatever
    -- language last scanned, so `/cn hidden` listed old-locale faction names
    -- beside correctly re-localized pet names in the same list.
    if objectiveType == types.REPUTATION and numericID then
        local data = CN.Blizzard.GetFactionByID(numericID)

        if data and data.name then
            return data.name
        end

        return CN.Account("factionNames")[numericID]
            or ("Faction " .. numericID)
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
        -- The same order as every other branch. It is inert today only
        -- because migration 16 emptied the stored field -- which is to say
        -- the rule was written down twice in one function and the two copies
        -- disagreed, waiting for the next release to reinstate a name. 0.65.0.
        local mounts = CN:GetModule("Mounts")

        if mounts and mounts.NameOf then
            return mounts.NameOf(numericID)
        end

        return "Mount " .. numericID
    end

    if objectiveType == types.TOY and numericID then
        -- CLIENT FIRST, LIKE ITS FOUR NEIGHBOURS. 0.65.0.
        --
        -- 0.64.0 flipped the reputation, currency, recipe and title branches
        -- to ask the client first and left this one reading a field 0.63.0
        -- had stopped writing -- so a hidden toy was unnameable, and
        -- `/cn unhide <name>` could not match it.
        local toys = CN:GetModule("Toys")

        if toys and toys.NameOf then
            return toys.NameOf(numericID)
        end

        return "Toy " .. numericID
    end

    -- THE BADGE, NOT THE ENUM. 0.66.0.
    --
    -- Every other branch in this function produces a title-cased placeholder
    -- -- "Quest 123", "Toy 123", "Faction 123". This one concatenated the raw
    -- uppercase token, so `/cn hidden` listed `RARE 5487` as the name of the
    -- thing the player had hidden: the addon's own internals, which is the
    -- exact defect the APPEARANCE branch below was written to fix.
    --
    -- It broke a second thing at a distance. `Goals.List` decides whether the
    -- describer has learned a real name by comparing against the placeholder
    -- it expects -- "Rare 5487" -- and `"RARE 5487"` never equalled it, so a
    -- pinned rare's placeholder was written over the stored name.
    if (objectiveType == types.RARE or objectiveType == types.TREASURE) and numericID then
        local record = CN.Account("rares")[numericID]

        return record and record.name
            or (CN.TypeBadge(objectiveType) .. " " .. numericID)
    end

    -- APPEARANCE COVERS TWO ID SPACES, AND SAYS WHICH. 0.61.0.
    --
    -- Transmog sets and appearance categories are both filed under
    -- APPEARANCE, distinguished by a `set:` prefix since the two collided.
    -- Without a branch here, a hidden set showed up in `/cn hidden` as
    -- "APPEARANCE set:2314" -- the addon's own internals, offered to the
    -- player as the name of the thing they hid.
    if objectiveType == types.APPEARANCE then
        local setID = type(id) == "string" and tonumber(id:match("^set:(%d+)$"))

        if setID then
            -- The addon's own reader, not a fresh client call: `Sets.All`
            -- already holds a name per set and is cached until a transmog is
            -- collected. Asking the client again here would be a second way
            -- to get the same answer, which is how the two drift.
            local sets = CN:GetModule("Sets")

            for _, set in ipairs(sets and (sets.All()) or {}) do
                if set.setID == setID and set.name then
                    return set.name
                end
            end

            return "Appearance set " .. setID
        end

        if numericID then
            -- Was a full enumeration of every category to find one name.
            -- 0.93.0.
            local appearances = CN:GetModule("Appearances")

            local name = appearances and appearances.NameOf
                and appearances.NameOf(numericID)

            if name and name ~= ("Slot " .. numericID) then
                return name
            end

            return "Appearance slot " .. numericID
        end
    end

    if objectiveType == types.ACHIEVEMENT and numericID then
        local record = CN.Account("achievements")[numericID]

        if record and record.name then
            return record.name
        end

        return CN.Blizzard.GetAchievementName(numericID)
            or ("Achievement " .. numericID)
    end

    -- AND THESE TWO HAD NO LIVE PATH AT ALL. 0.64.0.
    --
    -- Migration 16's header says it removed "the last of the names the client
    -- hands back for free", and these were still being read from disk with no
    -- fallback to the client that answers instantly.
    -- THROUGH THE MODULE, NOT A SECOND COPY OF IT. 0.65.0.
    --
    -- These two each carried their own live-then-store lookup, written before
    -- `Currencies.NameOf` and `Titles.NameOf` existed. Two copies of one rule
    -- drift, and these had already: both still ended at a name store that
    -- migration 18 deletes -- and `CN.Account(key)` CREATES the table it is
    -- asked for, so reading it here put the store back, empty, every login.
    if objectiveType == types.CURRENCY and numericID then
        local currencyModule = CN:GetModule("Currencies")

        if currencyModule and currencyModule.NameOf then
            return currencyModule.NameOf(numericID)
        end

        return "Currency " .. numericID
    end

    -- AND THE THIRD OF THE THREE. 0.66.0.
    --
    -- The note above says "these two had no live path at all" and then gave
    -- CURRENCY and TITLE one. RECIPE is the third member of that group and
    -- was left asking disk first with no client fallback -- the only branch
    -- in this function that does. A hidden vendor recipe read back as
    -- "Recipe 194424" until a profession window had been opened, and after a
    -- client-language change it showed the previous locale's name beside pet
    -- and mount names that had correctly re-localized.
    --
    -- BUT THE STORE FIRST, BECAUSE RECIPE IS THREE ID SPACES. 0.67.0.
    --
    -- 0.66.0 put the client's item lookup ahead of the store on the grounds
    -- that every other branch asks the client first. Every other branch has
    -- ONE id space. This type carries three: a merchant itemID from Vendors,
    -- a trade-skill recipe id from Professions -- which is what
    -- `recipeNames` is keyed by -- and a crafting orderID from Orders.
    --
    -- `GetItemName` on a trade-skill recipe id returns nil, or, where the
    -- number happens to collide with a real item, the name of a wholly
    -- unrelated one -- and being asked first, it BEAT the correct stored
    -- name. So a hidden Alchemy recipe that read back correctly in 0.65.0
    -- read back as some other item entirely, and `/cn unhide <name>` could
    -- not match what the list had printed.
    --
    -- The store is keyed by the one id space that has a name recorded for it;
    -- the client is asked for everything else.
    if objectiveType == types.RECIPE and numericID then
        local stored = CN.Account("recipeNames")[numericID]

        if stored and stored ~= "" then
            return stored
        end

        local live = CN.Blizzard.GetItemName and CN.Blizzard.GetItemName(numericID)

        if live and live ~= "" then
            return live
        end

        return "Recipe " .. numericID
    end

    if objectiveType == types.TITLE and numericID then
        local titleModule = CN:GetModule("Titles")

        if titleModule and titleModule.NameOf then
            return titleModule.NameOf(numericID)
        end

        return "Title " .. numericID
    end

    -- THE SYNTHETIC IDS, BY NAME. 0.79.0.
    --
    -- A handful of rows stand for an ACTION rather than for a thing with an
    -- id -- claiming the vault, collecting a finished crafting order -- and
    -- carry a string id so the filter stores can key on them. 0.78.0 gave
    -- those rows working hide-and-defer guards, which made this display path
    -- reachable for the first time, and it rendered them as "Currency vault"
    -- and "Recipe claim": the addon's own internals offered to the player as
    -- the name of the thing they hid.
    --
    -- Named here rather than by reaching into the modules, because the whole
    -- point of this function is that it answers for a store row long after
    -- the provider that made it has stopped producing one.
    -- ALL OF THEM, NOT THE TWO THAT WERE KNOWN. 0.83.0.
    --
    -- 0.79.0 added this table for the two singleton rows that existed then
    -- and 0.82.0 made a third hideable without adding it, so `/cn hidden`
    -- read "Currency mail [Currency mail]" -- naming the row twice, in the
    -- addon's internal vocabulary, in the one list a player consults to
    -- decide what to restore. Two more were open the whole time: the
    -- keystone row, and the Great Vault's five per-row ids.
    --
    -- Every string id any provider emits belongs here. A test now sweeps
    -- the live candidate list for one that does not.
    local synthetic = {
        mail     = "Expiring mail",
        vault    = "Collect your Great Vault reward",
        claim    = "Collect your finished crafting order",
        keystone = "Your Mythic+ keystone",
        RAID     = "Great Vault: raid progress",
        DUNGEON  = "Great Vault: dungeon progress",
        WORLD    = "Great Vault: world progress",
        PVP      = "Great Vault: PvP progress",
        UNKNOWN  = "Great Vault progress",
    }

    if type(id) == "string" and synthetic[id] then
        return synthetic[id]
    end

    -- A PREFIXED ID IS STILL A ROW WITH A NAME. 0.83.0. `Modules/Orders.lua`
    -- keys a crafting order as "order:<n>" so it cannot be mistaken for a
    -- recipe id; without this the hidden list would read "Recipe order:412".
    if type(id) == "string" then
        local orderID = id:match("^order:(%d+)$")

        if orderID then
            return "Crafting order " .. orderID
        end
    end

    -- THE BADGE, NOT THE ENUM, FOR EVERYTHING THAT REACHES HERE. 0.67.0.
    --
    -- Every branch above produces a title-cased placeholder, and this last
    -- line -- which catches every id that is not a number, such as the
    -- crafting-order row whose id is the string "claim" -- produced
    -- "RECIPE claim". The addon's own internals offered to the player as the
    -- name of the thing they hid, which is the defect two branches above were
    -- rewritten to fix.
    return CN.TypeBadge(objectiveType) .. " " .. tostring(id)
end

-- The stores are nested by type since 0.54.0 -- see CN.IsIgnored for why --
-- so these walk them through `CN.EachFiltered` rather than splitting a string
-- key back apart. `key` is kept on the row because the UI and `/cn unhide`
-- both address a row by it.
function Filters.ListIgnored()
    local rows = {}

    for objectiveType, id, entry in CN.EachFiltered(CN.Account("ignoredObjectives")) do
        table.insert(rows, {
            key   = CN.ObjectiveKey(objectiveType, id),
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

    for objectiveType, id, entry in CN.EachFiltered(CN.Account("deferredObjectives")) do
        local remaining

        if entry and entry.until_ then
            remaining = entry.until_ - now
        end

        table.insert(rows, {
            key       = CN.ObjectiveKey(objectiveType, id),
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
    local objectiveType, id = SplitKey(key)

    if not objectiveType then
        return false
    end

    local ignored  = CN.Account("ignoredObjectives")
    local deferred = CN.Account("deferredObjectives")

    local removed = false

    if ignored[objectiveType] and ignored[objectiveType][id] ~= nil then
        ignored[objectiveType][id] = nil
        removed = true

        if next(ignored[objectiveType]) == nil then
            ignored[objectiveType] = nil
        end
    end

    if deferred[objectiveType] and deferred[objectiveType][id] ~= nil then
        deferred[objectiveType][id] = nil
        removed = true

        if next(deferred[objectiveType]) == nil then
            deferred[objectiveType] = nil
        end
    end

    -- Same reason as CN.SetIgnored: the list a provider built is the list the
    -- player sees, and un-hiding something has to rebuild it.
    if removed and CN.InvalidateCandidates then
        CN.InvalidateCandidates()
    end

    return removed
end

function Filters.RestoreAll()
    local ignored  = CN.Account("ignoredObjectives")
    local deferred = CN.Account("deferredObjectives")

    local count = 0

    for _ in CN.EachFiltered(ignored) do
        count = count + 1
    end

    for _ in CN.EachFiltered(deferred) do
        count = count + 1
    end

    for objectiveType in pairs(ignored) do
        ignored[objectiveType] = nil
    end

    for objectiveType in pairs(deferred) do
        deferred[objectiveType] = nil
    end

    if count > 0 and CN.InvalidateCandidates then
        CN.InvalidateCandidates()
    end

    return count
end

-- Deferrals that have run out are dead weight in SavedVariables.
function Filters.PruneExpired()
    local deferred = CN.Account("deferredObjectives")

    local now, pruned = time(), 0

    for objectiveType, byType in pairs(deferred) do
        for id, entry in pairs(byType) do
            if entry and entry.until_ and entry.until_ <= now then
                byType[id] = nil
                pruned = pruned + 1
            end
        end

        if next(byType) == nil then
            deferred[objectiveType] = nil
        end
    end

    return pruned
end

-- A DEFERRAL THAT EXPIRES HAS TO WAKE SOMETHING UP.
--
-- Setting one invalidates the candidates -- `Objectives.lua` explains why, at
-- length. Nothing fires when one runs out. Every provider consults
-- `CN.IsDeferred` at BUILD time, so the deferral is baked into the cached
-- list; and the providers a deferral is most often used on -- Mounts, Pets,
-- Toys, Sets, Appearances -- are not volatile and subscribe only to their own
-- collection events.
--
-- So: right-click the heads-up line to put a mount off for an hour, and an
-- hour later it does not come back. `/cn hidden` reports the deferral as
-- expired while the objective is still missing from the list, which is the
-- addon contradicting itself about its own state.
--
-- A slow ticker, and only when it actually pruned something. Sixty seconds
-- is well inside the resolution anybody defers anything at.
Filters.pruneSeconds = 60

local pruneTicker

function Filters.StartPruneTicker()
    if pruneTicker or not C_Timer or not C_Timer.NewTicker then
        return false
    end

    pruneTicker = C_Timer.NewTicker(Filters.pruneSeconds, function()
        -- Guarded: a repeating callback that throws is a repeating error box.
        CN.Guard("Filters.PruneExpired", Filters.SweepExpired)
    end)

    return true
end

-- Prunes, and tells the ranking if anything came back. Split out so the
-- ticker and the tests call the same thing.
function Filters.SweepExpired()
    local pruned = Filters.PruneExpired()

    if pruned > 0 then
        DebugPrint("Pruned " .. pruned .. " expired deferral(s).")

        -- Something is actionable again that was not a moment ago, which is
        -- exactly what a deliberate invalidation means.
        CN.InvalidateCandidates()
    end

    return pruned
end

CN:OnLogin(function()
    Filters.SweepExpired()

    Filters.StartPruneTicker()
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

local function FormatRemaining(seconds)
    if not seconds then
        return "indefinitely"
    end

    -- AND SO IS THE SENTINEL FOR IT. 0.88.0. `math.huge` divided by an hour
    -- is still infinite, so this printed "infd" for the one duration whose
    -- whole meaning is that it does not run out.
    if seconds == math.huge then
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
                -- THE BADGE, NOT THE ENUM. `row.type` is the internal name --
                -- "COLLECTIBLE", "EXPLORATION" -- and this is a list a player
                -- reads to decide what to restore.
                CN.PrintLine(row.name .. " " .. CN.Muted("["
                    .. CN.TypeBadge(row.type) .. " " .. tostring(row.id)
                    .. "]"))
            end
        end

        if #deferred > 0 then
            Print("Deferred (" .. #deferred .. "):")

            for _, row in ipairs(deferred) do
                -- AND THE ID, WHICH WAS MISSING.
                --
                -- The footer two lines below says `/cn unhide <id>` restores
                -- one, and `Filters.Restore` matches on the id -- so a
                -- deferred objective could not be restored individually,
                -- because the only place its id would have appeared did not
                -- print it. Every other row in this command carried one.
                CN.PrintLine(row.name .. " " .. CN.Muted("["
                    .. CN.TypeBadge(row.type) .. " " .. tostring(row.id)
                    .. " " .. CN.DOT .. " " .. FormatRemaining(row.remaining)
                    .. " left]"))
            end
        end

        Print("|cffffc74f/cn unhide <id>|r to restore one, "
            .. "|cffffc74f/cn unhide all|r for everything.")
    end,
}

-- PUTTING SOMETHING OFF FOR LONGER THAN AN HOUR. 0.88.0.
--
-- The duration table above has existed for many releases with no reader:
-- every deferral in the addon was a hardcoded hour, and there was no command
-- that took a duration. "Until reset" -- the one the file header calls the
-- duration that actually matches how the game works -- had never been
-- available to anybody.
--
-- Defers the CURRENT recommendation by default, because that is the thing a
-- player has just been told to do and is deciding not to.
CN:RegisterCommand{
    name    = "defer",
    aliases = { "later", "snooze" },
    args    = "[hour|day|tomorrow|week|reset|forever]",
    order   = 22,
    help    = "Put the current recommendation off for longer than an hour.",
    handler = function(args)
        local objective = CN.currentRecommendation

        if not objective or not objective.type or not objective.id then
            Print("Nothing is being recommended right now. "
                .. "Run |cffffc74f/cn next|r first.")
            return
        end

        local key = string.lower(CN.Trim(args or ""))

        if key == "" then
            key = "hour"
        end

        local matched

        for _, duration in ipairs(Filters.durations) do
            if duration.key == key then
                matched = duration
            end
        end

        if not matched then
            Print("Durations: |cffffc74f"
                .. table.concat(Filters.DurationKeys(), "|r, |cffffc74f")
                .. "|r.")
            return
        end

        local seconds = Filters.DurationSeconds(key)

        CN.SetDeferred(objective.type, objective.id, seconds)

        CN.InvalidateCandidates()

        Print("Deferred: " .. tostring(objective.name or objective.id)
            .. CN.Aside(matched.label .. " " .. CN.DOT .. " "
                .. FormatRemaining(seconds)))

        Print("|cff8a8f96|cffffc74f/cn unhide " .. tostring(objective.id)
            .. "|r brings it back sooner.|r")
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
                .. CN.Pluralize(count, "") .. ".")
            return
        end

        local wanted = tostring(CN.ToID(args) or args)

        local restored = 0

        -- Match on the id alone, since the player sees ids and not the
        -- internal TYPE:id key.
        for _, row in ipairs(Filters.ListIgnored()) do
            if tostring(row.id) == wanted then
                if Filters.Restore(row.key) then
                    CN.PrintLine("Restored: " .. row.name)
                    restored = restored + 1
                end
            end
        end

        for _, row in ipairs(Filters.ListDeferred()) do
            if tostring(row.id) == wanted then
                if Filters.Restore(row.key) then
                    CN.PrintLine("Restored: " .. row.name)
                    restored = restored + 1
                end
            end
        end

        if restored == 0 then
            Print("Nothing hidden matches: " .. args)
            Print("Run |cffffc74f/cn hidden|r to see the list.")
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
    --
    -- BUT ONLY IF THERE IS NOT ALREADY A MODE ON.
    --
    -- This captured unconditionally, so switching from one focus straight to
    -- another overwrote the player's real settings with the FIRST focus's
    -- settings. `/cn mode leveling`, then `/cn mode collecting`, then
    -- `/cn mode off` left you in the levelling filter -- thirteen types
    -- hidden -- while printing "Previous filters and weighting restored" and
    -- recording no active mode. There was then no single command that got you
    -- back.
    --
    -- One level deep means one level: the state before the first focus, kept
    -- until a focus is actually cleared.
    if not settings.mode then
        settings.modePrevious = {
            profile = settings.priorityMode,
            hidden  = {},
        }

        for _, objectiveType in ipairs(Filters.TypeOrder()) do
            if not Filters.IsTypeEnabled(objectiveType) then
                table.insert(settings.modePrevious.hidden, objectiveType)
            end
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

    CN.InvalidateCandidates()

    return true, mode
end

function Filters.CurrentMode()
    local settings = CN.Settings()

    return settings and settings.mode, settings and CN.modes[settings.mode]
end

function Filters.ClearMode()
    local settings = CN.Settings()

    local previous = settings.modePrevious

    -- NOTHING TO CLEAR MEANS NOTHING TO CHANGE.
    --
    -- This called EnableAllTypes unconditionally and only then looked for
    -- something to restore -- so `/cn mode off` with no focus active unhid
    -- everything the player had hidden by hand with `/cn show`, and then
    -- printed "Previous filters and weighting restored". Hidden types live in
    -- SavedVariables, so the loss was permanent.
    --
    -- The suite only ever called this after ApplyMode, which is the one path
    -- where there is something to restore.
    if not previous and not settings.mode then
        return false
    end

    Filters.EnableAllTypes()

    if previous then
        settings.priorityMode = previous.profile or "balanced"

        for _, objectiveType in ipairs(previous.hidden or {}) do
            Filters.SetTypeEnabled(objectiveType, false)
        end
    end

    settings.mode         = nil
    settings.modePrevious = nil

    CN.InvalidateCandidates()

    return true
end

CN:RegisterCommand{
    -- `types` promoted. "Show" sounds like "show me things" and means the
    -- objective-type filter; the alias was already the accurate word. The old
    -- name stays, because it is in the docs and in people's macros.
    name    = "types",
    aliases = { "show" },
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
                Print("|cffffc74f/cn show|r lists them.")
                return
            end

            Filters.OnlyType(wanted)

            Print("Showing only " .. Filters.TypeLabel(wanted) .. ".")

        elseif args ~= "" then
            local wanted = Filters.ResolveType(args)

            if not wanted then
                Print("Not a type: " .. args)
                Print("|cffffc74f/cn show|r lists them.")
                return
            end

            local nowEnabled = Filters.ToggleType(wanted)

            Print(Filters.TypeLabel(wanted) .. ": " .. CN.YesNo(nowEnabled))
        end

        local hiddenCount = Filters.HiddenTypeCount()

        Print("Recommendation types"
            .. (hiddenCount > 0 and (" |cffffc74f" .. hiddenCount .. " hidden|r") or ""))

        for _, objectiveType in ipairs(Filters.TypeOrder()) do
            local enabled = Filters.IsTypeEnabled(objectiveType)

            CN.PrintLine("  " .. CN.YesNo(enabled) .. " " .. Filters.TypeLabel(objectiveType)
                .. " |cff8a8f96" .. string.lower(objectiveType) .. "|r")
        end

        Print("|cff8a8f96/cn show pets|r toggles one, |cff8a8f96/cn show only quests|r "
            .. "narrows to one, |cff8a8f96/cn show all|r restores everything.")

        if hiddenCount > 0 then
            Print("|cff8a8f96Hidden types still appear in /cn breakdown and the "
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
        args = CN.Trim(args or "")

        local settings = CN.Settings()

        if args ~= "" then
            -- MATCHED WITHOUT CASE, BECAUSE THE KEYS ARE camelCase.
            --
            -- This lowercased the argument and then looked it up in a table
            -- keyed `priorityMode`, `autoWaypoint`, `mapPins` -- so those
            -- three could never be set by any input, and the command rejected
            -- the exact spelling its own help line prints. Three of the six
            -- overridable settings were unreachable, including the one the
            -- feature was built for: a levelling alt wanting a different
            -- priority mode from a max-level main.
            local key

            for name in pairs(CN.characterOverridable) do
                if string.lower(name) == string.lower(args) then
                    key = name
                    break
                end
            end

            if not key then
                Print("That setting cannot be set per character: " .. args)

                local names = {}

                for name in pairs(CN.characterOverridable) do
                    table.insert(names, name)
                end

                table.sort(names)

                Print("|cff8a8f96Overridable: " .. table.concat(names, ", ") .. "|r")
                return
            end

            args = key

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

        -- EVERY OVERRIDABLE SETTING, NOT A HAND-COPIED FOUR OF THEM.
        --
        -- `CN.characterOverridable` also carries `mapPins` and `follow`, and
        -- the rejection branch above already enumerates the whole table -- so
        -- overriding `mapPins` was accepted and then never listed, and the
        -- status view gave no sign it existed.
        local overridable = {}

        for key in pairs(CN.characterOverridable or {}) do
            table.insert(overridable, key)
        end

        table.sort(overridable)

        for _, key in ipairs(overridable) do
            local overridden = CN.IsOverridden(key)

            CN.PrintLine("  " .. key .. " = " .. tostring(settings[key])
                .. (overridden
                    and " |cffffc74fthis character only|r"
                    or " |cff8a8f96account-wide|r"))
        end

        Print("|cff8a8f96/cn perchar priorityMode|r toggles whether a setting "
            .. "is shared or per character.")
    end,
}

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
