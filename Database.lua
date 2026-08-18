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

function CN.Settings()
    if not CN.db then
        return nil
    end

    CN.db.settings = CN.db.settings or {}

    return CN.db.settings
end
