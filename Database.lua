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
    version = 1,

    settings = {
        enabled      = true,
        debug        = false,
        priorityMode = "balanced",

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
    -- [1] = function(db) ... end,
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
    CompletionNavigatorDB = CN.CopyDefaults(CN.defaults, CompletionNavigatorDB or {})

    CN.db = CompletionNavigatorDB

    Migrate(CN.db)

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
