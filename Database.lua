-- Database.lua
-- Completion Navigator :: SavedVariables schema, defaults, and migration.
--
-- Anything that must survive /reload or logout lives in
-- CompletionNavigatorDB. Add new persistent tables to DEFAULTS below and
-- bump CN.dbVersion in Core.lua when the shape changes in a way that
-- requires a migration step.

local ADDON_NAME, CN = ...

local Print      = CN.Print
local DebugPrint = CN.DebugPrint

------------------------------------------------------------
-- DEFAULT DATABASE
------------------------------------------------------------

CN.defaults = {
    -- Kept in step with CN.dbVersion so a fresh install never looks like
    -- an old database that needs migrating.
    version = CN.dbVersion,

    settings = {
        enabled      = true,
        debug        = false,
        priorityMode = "balanced",

        -- Off by default: taking over the waypoint uninvited is hostile,
        -- and TomTom arrows are shared with every other addon.
        autoWaypoint = false,

        -- Addon lines on item and unit tooltips. On by default: these are
        -- additive and read-only, unlike the waypoint.
        tooltips     = true,

        -- The on-screen navigation arrow. On by default, but it only appears
        -- once something is actually being tracked, so it is never in the way
        -- of a player who has not asked for navigation.
        arrow        = true,

        -- Numbered route pins on the world map. On by default: like tooltip
        -- lines they are additive and read-only, they appear only on a map
        -- the player deliberately opened, and they are the only place the
        -- routing engine's work is visible.
        mapPins      = true,

        -- Follow mode. OFF by default and firmly so: it takes over the
        -- waypoint and puts a frame on screen, which is the most intrusive
        -- thing this addon can do. It is started deliberately or not at all.
        follow       = false,

        -- Announcing rares out loud is the noisiest thing this addon could
        -- do, so it is opt-in. Unsolicited sound is worse than an uninvited
        -- waypoint, and the waypoint is already off by default.
        rareAlerts   = false,

        -- Minimap button placement is an angle in degrees around the
        -- minimap edge, so it survives UI scale and minimap size changes.
        minimap = {
            hide  = false,
            angle = 225,
        },
    },

    account = {
        ignoredObjectives  = {},
        deferredObjectives = {},

        questMetadata      = {},
        questStatus        = {},
        discoveredQuests   = {},
        loremaster         = {},
        taskDurations      = {},
    },

    characters = {},
}

------------------------------------------------------------
-- MIGRATIONS
------------------------------------------------------------

-- Each entry migrates FROM the given version TO version + 1.
-- Never destroy user completion history here.
CN.migrations = {
    -- 1 -> 2. The collection modules introduced account tables that older
    -- databases do not have, and the minimap settings moved under a nested
    -- table. CopyDefaults fills both in, so this migration exists to prove
    -- the ladder runs and to normalize anything defaults cannot fix.
    [1] = function(db)
        db.account = db.account or {}

        -- Tables added after the schema was first written. Creating them
        -- here means no module has to guard against their absence.
        for _, key in ipairs({
            "pets", "mounts", "toys", "appearances", "titleNames",
            "achievements", "achievementTotals", "recipeNames",
            "reputations", "factionNames", "questHarvest", "questLocations",
            "collectionScans",
        }) do
            db.account[key] = db.account[key] or {}
        end

        db.settings = db.settings or {}

        -- Very early builds stored the minimap flag flat. Move it, and do
        -- not lose the player's choice in the process.
        if type(db.settings.minimap) ~= "table" then
            local wasHidden = db.settings.minimap == true or db.settings.hideMinimap == true

            db.settings.minimap = {
                hide  = wasHidden and true or false,
                angle = db.settings.minimapAngle or 225,
            }
        end

        db.settings.hideMinimap  = nil
        db.settings.minimapAngle = nil
    end,

    -- 2 -> 3. Per-character setting overrides.
    --
    -- Nothing to convert: every existing setting stays exactly where it is,
    -- account-wide, and characters start with no overrides at all. This entry
    -- exists so the ladder is explicit about the shape change rather than
    -- relying on absence, and so the assertion below documents the intent.
    [2] = function(db)
        db.characters = db.characters or {}

        for _, character in pairs(db.characters) do
            if type(character) == "table" then
                character.settings = character.settings or {}
            end
        end
    end,

    -- 3 -> 4. Observed prerequisites gained a confidence count.
    --
    -- The old shape was a flat array of candidate quest IDs, overwritten on
    -- every sighting, so it carried no idea of how often or on how many
    -- characters an ordering had held. The new shape counts by character.
    --
    -- Existing observations are preserved and credited to one unknown
    -- character each. That is deliberately BELOW the promotion threshold:
    -- data gathered before the addon knew how to count characters must not
    -- be promoted to a prerequisite on the strength of a count it never
    -- actually made.
    [3] = function(db)
        db.account = db.account or {}

        local harvest = db.account.questHarvest

        if type(harvest) ~= "table" then
            return
        end

        for _, record in pairs(harvest) do
            if type(record) == "table" and type(record.maybeRequires) == "table" then
                record.observed = record.observed or {}

                for _, prerequisiteID in ipairs(record.maybeRequires) do
                    record.observed[prerequisiteID] = record.observed[prerequisiteID]
                        or { seen = 1, characters = { ["migrated"] = true } }
                end

                record.maybeRequires = nil
            end
        end
    end,

    -- 4 -> 5: stop carrying a copy of the client's item cache.
    --
    -- Vendor rows stored every item's NAME as well as its ID. The client
    -- knows every item name already, so this was a duplicate of its cache
    -- written to disk, rewritten on every logout and re-parsed on every
    -- login -- and at retail scale it was the single largest thing this addon
    -- saved.
    --
    -- Dropped in place rather than waiting for a rescan, so the saving
    -- arrives on the next login rather than the next time the player happens
    -- to reopen every merchant they have ever visited.
    [4] = function(db)
        db.account = db.account or {}

        local vendors = db.account.vendors

        if type(vendors) ~= "table" then
            return
        end

        local dropped = 0

        for _, record in pairs(vendors) do
            if type(record) == "table" and type(record.items) == "table" then
                for _, item in pairs(record.items) do
                    if type(item) == "table" and item.name then
                        item.name = nil
                        dropped = dropped + 1
                    end
                end
            end
        end

        if dropped > 0 then
            CN.DebugPrint("Dropped " .. dropped
                .. " cached item names the client already knows.")
        end
    end,
}

local function Migrate(db)
    local from = db.version or 1

    while from < CN.dbVersion do
        local migration = CN.migrations[from]

        if migration then
            local ok, err = pcall(migration, db)

            if not ok then
                Print("Database migration " .. from .. " failed: " .. tostring(err))
                return
            end

            DebugPrint("Migrated database from version " .. from .. ".")
        end

        from = from + 1
        db.version = from
    end
end

------------------------------------------------------------
-- INITIALIZATION
------------------------------------------------------------

function CN.InitializeDatabase()
    local raw = CompletionNavigatorDB

    -- A brand new install has nothing to migrate; stamping it at the current
    -- version stops migration 1 running against an empty table.
    local isFresh = type(raw) ~= "table" or next(raw) == nil

    raw = type(raw) == "table" and raw or {}

    if isFresh then
        raw.version = CN.dbVersion
    else
        -- Migrations MUST run on the raw saved data, before defaults are
        -- merged in.
        --
        -- CopyDefaults replaces any stored value whose type no longer matches
        -- the default -- a legacy boolean where the default is now a table
        -- gets discarded outright. Running defaults first would therefore
        -- destroy exactly the values a migration exists to read, and it would
        -- do so silently.
        Migrate(raw)
    end

    CompletionNavigatorDB = CN.CopyDefaults(CN.defaults, raw)

    CN.db = CompletionNavigatorDB

    DebugPrint("Database initialized (schema version " .. tostring(CN.db.version) .. ").")
end

------------------------------------------------------------
-- ACCESSORS
------------------------------------------------------------

-- Safe accessor for account tables. Creates the table if it is missing so
-- new subsystems can be added without a migration.
function CN.Account(key)
    if not CN.db then
        return nil
    end

    CN.db.account = CN.db.account or {}

    if key then
        CN.db.account[key] = CN.db.account[key] or {}
        return CN.db.account[key]
    end

    return CN.db.account
end

-- Which candidate providers read which store. Rescanning your mounts must not
-- rebuild the achievement candidates; measured, that mistake cost 18ms of a
-- 16ms frame every time a mount was learned.
--
-- A store with no entry here feeds no candidate provider at all -- mounts,
-- toys, appearances and titles are reported by /cn breakdown and the
-- Collections tab, which read their stores directly.
CN.scanProviders = {
    pets         = { "Pets" },
    achievements = { "Achievements" },
    reputations  = { "Reputations" },
    currencies   = { "Currencies" },
    exploration  = { "Exploration" },
    loremaster   = { "Loremaster" },
    vendors      = { "Vendors" },

    -- Recipe names are the left-hand side of the vendor recipe join.
    recipes      = { "Vendors" },
}

-- A scan rewrites a store wholesale, and no client event fires to say so.
-- Recording the scan is the one thing every scan already does, which makes it
-- the right place to tell the candidate caches they are stale.
function CN.MarkScanned(key)
    CN.Account("collectionScans")[key] = time()

    -- Scoring.lua loads after this file, so these may not exist yet at load
    -- time. They always do by the time a scan can run.
    if not CN.InvalidateProvider then
        return
    end

    local providers = CN.scanProviders[key]

    if not providers then
        return
    end

    for _, name in ipairs(providers) do
        CN.InvalidateProvider(name)
    end
end

------------------------------------------------------------
-- SETTINGS AND PROFILES
------------------------------------------------------------

-- Settings are account-wide by default. Any single setting can be overridden
-- per character, because some of them are genuinely character-shaped: a max
-- level main and a levelling alt want different priority modes, and the
-- character you happen to be on should decide that, not the last one you
-- changed it on.
--
-- Overrides are stored SPARSELY -- only what a character has explicitly
-- overridden. That means a new default added in a later release reaches every
-- character, instead of being frozen at whatever the value was when the
-- override was created.
-- HOW BIG IS THIS?
--
-- The client rewrites the entire saved-variables file on every logout and
-- parses it again on every login. Nobody had ever measured what this addon
-- contributes to that, and the answer was over a megabyte at retail scale --
-- a third of which was a copy of the client's own item cache.
--
-- Measured rather than guessed, and reportable, so it cannot quietly grow
-- back.
function CN.MeasureDatabase(value, seen)
    seen = seen or {}

    if type(value) == "table" then
        if seen[value] then
            return 0
        end

        seen[value] = true

        local bytes = 8

        for key, entry in pairs(value) do
            bytes = bytes + CN.MeasureDatabase(key, seen)
                + CN.MeasureDatabase(entry, seen) + 4
        end

        return bytes
    end

    if type(value) == "string" then
        return #value + 2
    end

    if type(value) == "number" then
        return 8
    end

    return 4
end

function CN.DatabaseSizes()
    local rows = {}

    local function section(label, contents)
        if type(contents) ~= "table" then
            return
        end

        table.insert(rows, {
            name  = label,
            bytes = CN.MeasureDatabase(contents),
            count = CN.CountKeys(contents),
        })
    end

    for name, contents in pairs((CN.db and CN.db.account) or {}) do
        section(name, contents)
    end

    section("characters", CN.db and CN.db.characters)

    table.sort(rows, function(a, b) return a.bytes > b.bytes end)

    return rows, CN.MeasureDatabase(CN.db)
end

CN:RegisterCommand{
    name    = "dbsize",
    aliases = { "storage" },
    order   = 31,
    help    = "How much this addon writes to disk, and where it goes.",
    handler = function()
        local rows, total = CN.DatabaseSizes()

        Print(string.format("Saved data: |cffffd100%.0f KB|r", total / 1024))
        Print("|cff999999Rewritten in full every time you log out.|r")

        local shown = 0

        for _, row in ipairs(rows) do
            if row.bytes > 4096 and shown < 12 then
                Print(string.format("  %-20s %6.0f KB  |cff999999%d rows|r",
                    row.name, row.bytes / 1024, row.count))

                shown = shown + 1
            end
        end

        if shown == 0 then
            Print("|cff999999Nothing large enough to itemise.|r")
        end
    end,
}

CN.characterOverridable = {
    priorityMode = true,
    autoWaypoint = true,
    arrow        = true,
    tooltips     = true,
    mapPins      = true,
    follow       = true,
}

local function AccountSettings()
    if not CN.db then
        return nil
    end

    CN.db.settings = CN.db.settings or {}

    return CN.db.settings
end

CN.AccountSettings = AccountSettings

local function Overrides(character)
    character = character or CN.character

    if not character then
        return nil
    end

    character.settings = character.settings or {}

    return character.settings
end

CN.SettingOverrides = Overrides

function CN.IsOverridden(key)
    local overrides = Overrides()

    return overrides ~= nil and overrides[key] ~= nil
end

-- Sets a per-character override, or clears it when value is nil.
function CN.SetOverride(key, value)
    if not CN.characterOverridable[key] then
        return false, "That setting is account-wide only."
    end

    local overrides = Overrides()

    if not overrides then
        return false, "No character is loaded yet."
    end

    overrides[key] = value

    return true
end

function CN.ClearOverride(key)
    local overrides = Overrides()

    if overrides then
        overrides[key] = nil
    end

    return true
end

-- The settings table every caller sees.
--
-- A proxy rather than a copy: reads fall through to the account table unless
-- this character has overridden the key, and writes go to whichever level the
-- key already lives at. Copying would have meant every existing call site
-- needing to know which level it was talking to.
local settingsProxy

local function BuildProxy()
    return setmetatable({}, {
        __index = function(_, key)
            local overrides = Overrides()

            if overrides and overrides[key] ~= nil then
                return overrides[key]
            end

            local account = AccountSettings()

            return account and account[key]
        end,

        __newindex = function(_, key, value)
            local overrides = Overrides()

            -- Writing to a key this character has overridden updates the
            -- override. Everything else is account-wide, which is the
            -- behaviour every release before this one had.
            if overrides and overrides[key] ~= nil then
                overrides[key] = value
                return
            end

            local account = AccountSettings()

            if account then
                account[key] = value
            end
        end,

        -- pairs() over settings must see the merged view, or anything that
        -- iterates them silently misses overrides.
        __pairs = function()
            local merged = {}

            for key, value in pairs(AccountSettings() or {}) do
                merged[key] = value
            end

            for key, value in pairs(Overrides() or {}) do
                merged[key] = value
            end

            return next, merged, nil
        end,
    })
end

function CN.Settings()
    if not CN.db then
        return nil
    end

    AccountSettings()

    settingsProxy = settingsProxy or BuildProxy()

    return settingsProxy
end
