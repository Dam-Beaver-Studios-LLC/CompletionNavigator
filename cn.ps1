<#
.SYNOPSIS
    Completion Navigator build and authoring toolkit.

.DESCRIPTION
    Manages the Completion Navigator WoW addon from PowerShell instead of by
    hand-editing Lua. Place this file in the addon folder:

        ...\_retail_\Interface\AddOns\CompletionNavigator\cn.ps1

    Then run commands from that folder:

        .\cn.ps1 init
        .\cn.ps1 new module Pets
        .\cn.ps1 cmd pets -Module Pets -Usage "<petID>" -Help "Check a pet."
        .\cn.ps1 event PET_JOURNAL_LIST_UPDATE -Module Pets
        .\cn.ps1 sync
        .\cn.ps1 check

.NOTES
    Completion Navigator
    Author: Travis A. Bryan I
    Copyright (c) 2026 Dam Beaver Studios, LLC. Released under the MIT License.
    Owned, published and maintained by Dam Beaver Studios, LLC.

    The addon folder lives under C:\Program Files (x86)\... on this machine,
    which is ACL-protected. Run PowerShell as Administrator, or move the addon
    to a writable location and symlink it back.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string] $Command = 'help',
    [Parameter(Position = 1)] [string] $Target,
    [Parameter(Position = 2)] [string] $Value,

    [string] $Name,
    [string] $Usage,
    [string] $Help,
    [string] $Module,
    [int]    $Order = 50,
    [string] $Expansion,
    [int]    $MapID,
    [double] $X,
    [double] $Y,
    [string] $Requires,
    [string] $Email,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

$script:Root       = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:BackupDir  = Join-Path $script:Root '_backups'
$script:TocPath    = Join-Path $script:Root 'CompletionNavigator.toc'
$script:BeginMark  = '# CN:FILES:BEGIN -- managed by cn.ps1 sync; do not edit by hand.'
$script:EndMark    = '# CN:FILES:END'
$script:AppendMark = '-- CN:APPEND'
$script:DataMark   = '-- CN:DATA:QUESTS'

# Fixed load order for root-level files. Anything not listed here sorts after
# these, alphabetically, inside its own folder group.
$script:RootOrder = @(
    'Core.lua',
    'Database.lua',
    'Objectives.lua',
    'Dependencies.lua',
    'Character.lua',
    'Events.lua',
    'Commands.lua',
    'Scoring.lua',
    'Routing.lua',
    'UI.lua'
)

# Providers must load before Data: Data files call CN.Static.Register* at
# file scope, and CN.Static is created by Providers\StaticData.lua.
$script:FolderOrder = @('Providers', 'Data', 'Modules')

$Embedded = [ordered]@{}

$Embedded['Core.lua'] = @'
-- Core.lua
-- Completion Navigator :: namespace, logging, and registries.
--
-- Load order: FIRST. Nothing may be added above this file.
--
-- This file intentionally contains no gameplay logic. It exists so that
-- every other file can register itself declaratively:
--
--   CN:RegisterCommand{ ... }
--   CN:RegisterEvent("EVENT_NAME", handler)
--   CN:RegisterModule("Quests")
--
-- That makes the codebase append-only for tooling purposes: adding a
-- command or an event never requires editing a dispatcher.

local ADDON_NAME, CN = ...

_G.CompletionNavigator = CN

CN.name        = ADDON_NAME
CN.version     = "0.13.0"
CN.dbVersion   = 2

-- Where the addon's own textures live. Referenced by the .toc IconTexture
-- line and the minimap button.
CN.MEDIA_PATH  = "Interface\\AddOns\\CompletionNavigator\\Media\\"

------------------------------------------------------------
-- REGISTRIES
------------------------------------------------------------

CN.modules     = {}   -- [name]  = module table
CN.commands    = {}   -- [name]  = command definition
CN.commandList = {}   -- ordered list of command definitions (for /cn help)
CN.eventTable  = {}   -- [event] = { handler, handler, ... }
CN.initHooks   = {}   -- functions run on ADDON_LOADED, after the DB exists
CN.loginHooks  = {}   -- functions run on PLAYER_LOGIN
CN.logoutHooks = {}   -- functions run on PLAYER_LOGOUT

------------------------------------------------------------
-- OUTPUT
------------------------------------------------------------

local PREFIX       = "|cff33ff99Completion Navigator|r: "
local DEBUG_PREFIX = "|cff999999Completion Navigator Debug|r: "

function CN.Print(message)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. tostring(message))
end

function CN.DebugPrint(message)
    if CN.db and CN.db.settings and CN.db.settings.debug then
        DEFAULT_CHAT_FRAME:AddMessage(DEBUG_PREFIX .. tostring(message))
    end
end

local Print      = CN.Print
local DebugPrint = CN.DebugPrint

-- Colorized yes/no used throughout the completion output.
function CN.YesNo(value)
    if value then
        return "|cff00ff00YES|r"
    end

    return "|cffff4444NO|r"
end

------------------------------------------------------------
-- MODULE REGISTRY
------------------------------------------------------------

-- Returns a table that a module file can hang its functions on.
-- Calling it twice with the same name returns the same table, so module
-- files can be split later without breaking references.
function CN:RegisterModule(name)
    if CN.modules[name] then
        return CN.modules[name]
    end

    local module = {
        name   = name,
        Print  = CN.Print,
        Debug  = CN.DebugPrint,
    }

    CN.modules[name] = module

    return module
end

function CN:GetModule(name)
    return CN.modules[name]
end

------------------------------------------------------------
-- COMMAND REGISTRY
------------------------------------------------------------

-- definition = {
--     name    = "quest",              -- required, lowercase
--     aliases = { "q" },              -- optional
--     args    = "<questID>",          -- optional, shown in /cn help
--     help    = "Check a quest.",     -- optional, shown in /cn help
--     order   = 50,                   -- optional sort weight for help
--     handler = function(args) end,   -- required
-- }
function CN:RegisterCommand(definition)
    if type(definition) ~= "table" then
        return
    end

    if not definition.name or type(definition.handler) ~= "function" then
        Print("Internal error: malformed command registration.")
        return
    end

    definition.name  = string.lower(definition.name)
    definition.order = definition.order or 100

    CN.commands[definition.name] = definition

    if definition.aliases then
        for _, alias in ipairs(definition.aliases) do
            CN.commands[string.lower(alias)] = definition
        end
    end

    table.insert(CN.commandList, definition)
end

------------------------------------------------------------
-- EVENT REGISTRY
------------------------------------------------------------

-- Multiple files may register the same event. Every handler is called
-- with (event, ...) in registration order.
function CN:RegisterEvent(event, handler)
    if type(event) ~= "string" or type(handler) ~= "function" then
        return
    end

    if not CN.eventTable[event] then
        CN.eventTable[event] = {}
    end

    table.insert(CN.eventTable[event], handler)

    -- Events.lua may not have created the frame yet; if it has, register
    -- with the client immediately.
    if CN.eventFrame then
        CN.eventFrame:RegisterEvent(event)
    end
end

------------------------------------------------------------
-- LIFECYCLE HOOKS
------------------------------------------------------------

function CN:OnInitialize(handler)
    table.insert(CN.initHooks, handler)
end

function CN:OnLogin(handler)
    table.insert(CN.loginHooks, handler)
end

function CN:OnLogout(handler)
    table.insert(CN.logoutHooks, handler)
end

function CN.RunHooks(list, ...)
    for _, handler in ipairs(list) do
        local ok, err = pcall(handler, ...)

        if not ok then
            Print("Error: " .. tostring(err))
        end
    end
end

------------------------------------------------------------
-- SHARED UTILITIES
------------------------------------------------------------

-- Recursively fills missing keys in destination from source.
function CN.CopyDefaults(source, destination)
    if type(destination) ~= "table" then
        destination = {}
    end

    for key, value in pairs(source) do
        if type(value) == "table" then
            destination[key] = CN.CopyDefaults(value, destination[key])
        elseif destination[key] == nil then
            destination[key] = value
        end
    end

    return destination
end

-- Normalizes user input into a positive integer ID, or nil.
function CN.ToID(text)
    local id = tonumber(text)

    if not id then
        return nil
    end

    id = math.floor(id)

    if id <= 0 then
        return nil
    end

    return id
end

function CN.CountKeys(tbl)
    local count = 0

    if type(tbl) ~= "table" then
        return 0
    end

    for _ in pairs(tbl) do
        count = count + 1
    end

    return count
end

function CN.Trim(text)
    if not text then
        return ""
    end

    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end
'@

$Embedded['Database.lua'] = @'
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
'@

$Embedded['Objectives.lua'] = @'
-- Objectives.lua
-- Completion Navigator :: the universal objective model.
--
-- Everything the addon eventually tracks (quests, achievements, pets,
-- recipes, rares, treasures, appearances, ...) is normalized into an
-- objective so the scoring and routing layers only ever have to reason
-- about one shape.

local ADDON_NAME, CN = ...

------------------------------------------------------------
-- TYPES
------------------------------------------------------------

CN.objectiveTypes = {
    QUEST       = "QUEST",
    ACHIEVEMENT = "ACHIEVEMENT",
    REPUTATION  = "REPUTATION",
    RENOWN      = "RENOWN",
    PET         = "PET",
    MOUNT       = "MOUNT",
    TOY         = "TOY",
    APPEARANCE  = "APPEARANCE",
    RECIPE      = "RECIPE",
    PROFESSION  = "PROFESSION",
    RARE        = "RARE",
    TREASURE    = "TREASURE",
    EXPLORATION = "EXPLORATION",
    TITLE       = "TITLE",
    CURRENCY    = "CURRENCY",
    VENDOR      = "VENDOR",
    COLLECTIBLE = "COLLECTIBLE",
}

------------------------------------------------------------
-- STATES
------------------------------------------------------------

CN.objectiveStates = {
    UNKNOWN                   = "UNKNOWN",
    AVAILABLE                 = "AVAILABLE",
    COMPLETED                 = "COMPLETED",
    LOCKED                    = "LOCKED",
    DEFERRED                  = "DEFERRED",
    IGNORED                   = "IGNORED",
    INELIGIBLE                = "INELIGIBLE",
    TEMPORARILY_UNAVAILABLE   = "TEMPORARILY_UNAVAILABLE",
    UNOBTAINABLE              = "UNOBTAINABLE",
    REQUIRES_OTHER_CHARACTER  = "REQUIRES_OTHER_CHARACTER",
}

------------------------------------------------------------
-- SOURCE CONFIDENCE
------------------------------------------------------------

-- Lower number means higher authority. Manual overrides must never
-- silently replace a more authoritative source.
CN.sourceRank = {
    ["blizzard"] = 1,
    ["questlog"] = 2,
    ["observed"] = 3,
    ["static"]   = 4,
    ["external"] = 5,
    ["manual"]   = 6,
}

function CN.IsBetterSource(newSource, existingSource)
    if not existingSource then
        return true
    end

    local newRank      = CN.sourceRank[newSource] or 99
    local existingRank = CN.sourceRank[existingSource] or 99

    return newRank <= existingRank
end

------------------------------------------------------------
-- PRIORITY MODES
------------------------------------------------------------

CN.priorityModes = {
    "balanced",
    "fastest",
    "zone",
    "quests",
    "achievements",
    "reputation",
    "pets",
    "professions",
    "recipes",
    "collections",
    "legacy",
}

------------------------------------------------------------
-- CONSTRUCTOR
------------------------------------------------------------

-- Objectives are transient by design: they are rebuilt from persisted
-- state rather than stored, so the schema can evolve freely.
function CN.NewObjective(fields)
    local objective = {
        id               = nil,
        type             = CN.objectiveTypes.QUEST,
        name             = nil,
        expansion        = nil,
        zone             = nil,
        mapID            = nil,
        x                = nil,
        y                = nil,
        state            = CN.objectiveStates.UNKNOWN,
        accountWide      = false,
        characterSpecific = true,
        eligibility      = nil,
        prerequisites    = nil,
        unlocks          = nil,
        acquisitionMethod = nil,
        source           = nil,
        availability     = nil,
        estimatedTime    = nil,
        travelCost       = nil,
        priorityWeight   = 0,
        rewards          = nil,
    }

    if type(fields) == "table" then
        for key, value in pairs(fields) do
            objective[key] = value
        end
    end

    return objective
end

------------------------------------------------------------
-- IGNORE / DEFER
------------------------------------------------------------

local function ObjectiveKey(objectiveType, id)
    return tostring(objectiveType) .. ":" .. tostring(id)
end

CN.ObjectiveKey = ObjectiveKey

function CN.IsIgnored(objectiveType, id)
    local ignored = CN.Account("ignoredObjectives")

    return ignored[ObjectiveKey(objectiveType, id)] ~= nil
end

function CN.SetIgnored(objectiveType, id, value)
    local ignored = CN.Account("ignoredObjectives")
    local key     = ObjectiveKey(objectiveType, id)

    if value then
        ignored[key] = { since = time() }
    else
        ignored[key] = nil
    end
end

function CN.IsDeferred(objectiveType, id)
    local deferred = CN.Account("deferredObjectives")
    local entry    = deferred[ObjectiveKey(objectiveType, id)]

    if not entry then
        return false
    end

    if entry.until_ and entry.until_ <= time() then
        deferred[ObjectiveKey(objectiveType, id)] = nil
        return false
    end

    return true
end

function CN.SetDeferred(objectiveType, id, seconds)
    local deferred = CN.Account("deferredObjectives")
    local key      = ObjectiveKey(objectiveType, id)

    if not seconds then
        deferred[key] = nil
        return
    end

    deferred[key] = {
        since  = time(),
        until_ = time() + seconds,
    }
end
'@

$Embedded['Dependencies.lua'] = @'
-- Dependencies.lua
-- Completion Navigator :: the dependency graph and objective forensics.
--
-- Answers "why can't I do this yet?" by walking prerequisites until it
-- finds the first unmet one.

local ADDON_NAME, CN = ...

------------------------------------------------------------
-- BLOCKER REASONS
------------------------------------------------------------

CN.blockReasons = {
    PREREQUISITE_QUEST   = "Prerequisite quest incomplete",
    REPUTATION_TOO_LOW   = "Reputation too low",
    MISSING_PROFESSION   = "Required profession missing",
    PROFESSION_SKILL     = "Profession skill too low",
    WRONG_CLASS          = "Wrong class",
    WRONG_RACE           = "Wrong race",
    WRONG_FACTION        = "Wrong faction",
    LEVEL_TOO_LOW        = "Level too low",
    CAMPAIGN_INCOMPLETE  = "Campaign chapter incomplete",
    EVENT_INACTIVE       = "Required event is not active",
    WRONG_PHASE          = "Wrong phase",
    MUTUALLY_EXCLUSIVE   = "A mutually exclusive choice was already made",
    BREADCRUMB_SKIPPED   = "Breadcrumb permanently skipped",
    OBSOLETE             = "Objective is obsolete",
    UNOBTAINABLE         = "Objective is currently unobtainable",
    BETTER_CHARACTER     = "Another character is better suited",
}

------------------------------------------------------------
-- GRAPH STORAGE
------------------------------------------------------------

-- Populated by Data/*.lua files. Shape:
--   CN.dependencies[objectiveKey] = {
--       requires = { objectiveKey, ... },
--       unlocks  = { objectiveKey, ... },
--       requiresReputation = { factionID = , standing = },
--       requiresProfession = { professionID = , skill = },
--       requiresLevel = 70,
--       requiresFaction = "Alliance",
--   }
CN.dependencies = CN.dependencies or {}

function CN.AddDependency(key, definition)
    CN.dependencies[key] = CN.dependencies[key] or {}

    for field, value in pairs(definition) do
        CN.dependencies[key][field] = value
    end
end

function CN.GetDependency(key)
    return CN.dependencies[key]
end

------------------------------------------------------------
-- EXTERNAL DATA PROVIDERS
------------------------------------------------------------

-- Other addons hold data this one deliberately does not duplicate. A
-- provider is asked for a quest record and may answer with any subset of
-- { name, mapID, x, y, requires, requiresLevel }.
--
-- Lower priority number wins when two providers answer the same field.
-- Curated static data always outranks all of them, because it is the only
-- source this addon controls.
CN.questDataProviders = CN.questDataProviders or {}
CN.questDataOrder     = CN.questDataOrder or {}

function CN.RegisterQuestDataProvider(name, provider)
    if type(provider) ~= "table" or type(provider.GetQuestData) ~= "function" then
        return
    end

    CN.questDataProviders[name] = provider

    table.insert(CN.questDataOrder, { name = name, priority = provider.priority or 100 })

    table.sort(CN.questDataOrder, function(a, b)
        return a.priority < b.priority
    end)
end

function CN.GetAvailableQuestDataProviders()
    local available = {}

    for _, entry in ipairs(CN.questDataOrder) do
        local provider = CN.questDataProviders[entry.name]

        local ok, isAvailable = pcall(provider.IsAvailable)

        if ok and isAvailable then
            table.insert(available, entry.name)
        end
    end

    return available
end

-- Merges every available provider's answer for one quest, first answer per
-- field winning. Returns nil when nothing knows anything.
function CN.QueryQuestDataProviders(questID)
    local merged, contributors = nil, {}

    for _, entry in ipairs(CN.questDataOrder) do
        local provider = CN.questDataProviders[entry.name]

        local ok, isAvailable = pcall(provider.IsAvailable)

        if ok and isAvailable then
            local gotData, data = pcall(provider.GetQuestData, questID)

            if gotData and type(data) == "table" then
                merged = merged or {}

                local used = false

                for field, value in pairs(data) do
                    if field ~= "source" and merged[field] == nil then
                        merged[field] = value
                        used = true
                    end
                end

                if used then
                    table.insert(contributors, entry.name)
                end
            end
        end
    end

    if merged then
        merged.providers = contributors
    end

    return merged
end

------------------------------------------------------------
-- FORENSICS
------------------------------------------------------------

-- Returns state, reason, detail.
-- Checkers are registered per objective type by the owning module, so this
-- file never needs to know about quests, recipes, or pets specifically.
CN.eligibilityCheckers = CN.eligibilityCheckers or {}

function CN.RegisterEligibilityChecker(objectiveType, checker)
    CN.eligibilityCheckers[objectiveType] = checker
end

function CN.Explain(objectiveType, id)
    if CN.IsIgnored(objectiveType, id) then
        return CN.objectiveStates.IGNORED, "Ignored by user", nil
    end

    if CN.IsDeferred(objectiveType, id) then
        return CN.objectiveStates.DEFERRED, "Deferred by user", nil
    end

    local checker = CN.eligibilityCheckers[objectiveType]

    if not checker then
        return CN.objectiveStates.UNKNOWN, "No eligibility checker registered for " .. tostring(objectiveType), nil
    end

    return checker(id)
end
'@

$Embedded['Character.lua'] = @'
-- Character.lua
-- Completion Navigator :: per-character profiles.
--
-- Warband-aware logic depends on knowing what every character can do, not
-- just the one currently logged in. Every field written here is persisted
-- so an offline character can still be evaluated as a candidate for an
-- objective.

local ADDON_NAME, CN = ...

local DebugPrint = CN.DebugPrint

------------------------------------------------------------
-- IDENTITY
------------------------------------------------------------

function CN.GetCharacterKey()
    local name  = UnitName("player") or "Unknown"
    local realm = GetRealmName() or "UnknownRealm"

    return realm .. "-" .. name
end

------------------------------------------------------------
-- PROFILE
------------------------------------------------------------

function CN.InitializeCharacter()
    local key = CN.GetCharacterKey()

    CN.db.characters[key] = CN.db.characters[key] or {}

    local character = CN.db.characters[key]

    character.name    = UnitName("player")
    character.realm   = GetRealmName()
    character.class   = select(2, UnitClass("player"))
    character.race    = select(2, UnitRace("player"))
    character.level   = UnitLevel("player")
    character.sex     = UnitSex("player")
    character.lastSeen = time()

    if UnitFactionGroup then
        character.faction = UnitFactionGroup("player")
    end

    if GetSpecialization and GetSpecializationInfo then
        local index = GetSpecialization()

        if index then
            local specID, specName = GetSpecializationInfo(index)

            character.specID   = specID
            character.specName = specName
        end
    end

    CN.characterKey = key
    CN.character    = character

    DebugPrint("Character initialized: " .. tostring(key))
end

------------------------------------------------------------
-- REFRESH
------------------------------------------------------------

function CN.TouchCharacter()
    if not CN.character then
        return
    end

    CN.character.level    = UnitLevel("player")
    CN.character.lastSeen = time()
end

------------------------------------------------------------
-- WARBAND HELPERS
------------------------------------------------------------

-- Iterates every known character profile: for key, character in CN.Characters()
function CN.Characters()
    if not CN.db or not CN.db.characters then
        return function() return nil end
    end

    return pairs(CN.db.characters)
end

function CN.GetCharacterCount()
    return CN.CountKeys(CN.db and CN.db.characters)
end

------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------

CN:OnLogin(function()
    CN.InitializeCharacter()
end)

CN:OnLogout(function()
    CN.TouchCharacter()
end)

CN:RegisterEvent("PLAYER_LEVEL_UP", function(event, newLevel)
    if CN.character then
        CN.character.level    = newLevel
        CN.character.lastSeen = time()
    end

    DebugPrint("Character level updated to " .. tostring(newLevel))
end)

CN:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED", function(event, unit)
    if unit ~= "player" then
        return
    end

    if CN.character and GetSpecialization and GetSpecializationInfo then
        local index = GetSpecialization()

        if index then
            local specID, specName = GetSpecializationInfo(index)

            CN.character.specID   = specID
            CN.character.specName = specName

            DebugPrint("Specialization updated to " .. tostring(specName))
        end
    end
end)
'@

$Embedded['Events.lua'] = @'
-- Events.lua
-- Completion Navigator :: single event frame and dispatcher.
--
-- No other file should call CreateFrame for event handling. Register with
-- CN:RegisterEvent("EVENT", handler) instead; handlers receive
-- (event, ...) and multiple handlers per event are supported.

local ADDON_NAME, CN = ...

local Print      = CN.Print
local DebugPrint = CN.DebugPrint

------------------------------------------------------------
-- FRAME
------------------------------------------------------------

local eventFrame = CreateFrame("Frame", "CompletionNavigatorEventFrame")

CN.eventFrame = eventFrame

------------------------------------------------------------
-- CORE LIFECYCLE EVENTS
------------------------------------------------------------

local CORE_EVENTS = {
    "ADDON_LOADED",
    "PLAYER_LOGIN",
    "PLAYER_LOGOUT",
}

for _, event in ipairs(CORE_EVENTS) do
    eventFrame:RegisterEvent(event)
end

-- Anything registered before this file loaded still needs to be told to
-- the client.
for event in pairs(CN.eventTable) do
    eventFrame:RegisterEvent(event)
end

------------------------------------------------------------
-- DISPATCH
------------------------------------------------------------

local function Dispatch(event, ...)
    local handlers = CN.eventTable[event]

    if not handlers then
        return
    end

    for _, handler in ipairs(handlers) do
        local ok, err = pcall(handler, event, ...)

        if not ok then
            Print("Error in " .. event .. " handler: " .. tostring(err))
        end
    end
end

CN.Dispatch = Dispatch

------------------------------------------------------------
-- HANDLER
------------------------------------------------------------

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...

        if loadedAddon ~= ADDON_NAME then
            return
        end

        CN.InitializeDatabase()
        CN.RunHooks(CN.initHooks)

        DebugPrint("Initialization hooks complete.")

        return
    end

    if event == "PLAYER_LOGIN" then
        -- Banner first: login hooks print their own findings, and those
        -- read as noise before the addon has said it loaded.
        Print("v" .. CN.version .. " loaded. Type |cffffff00/cn|r for status.")

        CN.RunHooks(CN.loginHooks)

        Dispatch(event, ...)

        return
    end

    if event == "PLAYER_LOGOUT" then
        CN.RunHooks(CN.logoutHooks)

        Dispatch(event, ...)

        return
    end

    Dispatch(event, ...)
end)
'@

$Embedded['Commands.lua'] = @'
-- Commands.lua
-- Completion Navigator :: slash command dispatcher and built-in commands.
--
-- To add a command, do NOT edit this file. In the owning module call:
--
--   CN:RegisterCommand{
--       name    = "example",
--       args    = "<id>",
--       help    = "Does the example thing.",
--       order   = 50,
--       handler = function(args) ... end,
--   }
--
-- Help output and dispatch pick it up automatically.

local ADDON_NAME, CN = ...

local Print = CN.Print

------------------------------------------------------------
-- HELP
------------------------------------------------------------

local function ShowHelp()
    Print("Commands:")

    local sorted = {}

    for _, definition in ipairs(CN.commandList) do
        table.insert(sorted, definition)
    end

    table.sort(sorted, function(a, b)
        if a.order == b.order then
            return a.name < b.name
        end

        return a.order < b.order
    end)

    for _, definition in ipairs(sorted) do
        local line = "|cffffff00/cn " .. definition.name

        if definition.args and definition.args ~= "" then
            line = line .. " " .. definition.args
        end

        line = line .. "|r"

        if definition.help and definition.help ~= "" then
            line = line .. " - " .. definition.help
        end

        Print(line)
    end
end

CN.ShowHelp = ShowHelp

------------------------------------------------------------
-- STATUS
------------------------------------------------------------

local function ShowStatus()
    Print("Version " .. CN.version .. " is loaded.")

    if CN.character then
        Print("Active character: "
            .. tostring(CN.character.name or "Unknown")
            .. " (Level " .. tostring(CN.character.level or "?") .. ")")
    end

    local settings = CN.Settings()

    if settings then
        Print("Priority mode: " .. tostring(settings.priorityMode))
        Print("Debug mode: " .. (settings.debug and "enabled" or "disabled"))
    end

    Print("Known characters: " .. CN.GetCharacterCount())

    local moduleNames = {}

    for name in pairs(CN.modules) do
        table.insert(moduleNames, name)
    end

    table.sort(moduleNames)

    if #moduleNames > 0 then
        Print("Modules: " .. table.concat(moduleNames, ", "))
    end
end

CN.ShowStatus = ShowStatus

------------------------------------------------------------
-- DISPATCHER
------------------------------------------------------------

local function HandleSlashCommand(message)
    message = CN.Trim(message)

    local command, arguments = message:match("^(%S*)%s*(.-)$")

    command   = string.lower(command or "")
    arguments = CN.Trim(arguments)

    if command == "" then
        ShowStatus()
        return
    end

    local definition = CN.commands[command]

    if definition then
        local ok, err = pcall(definition.handler, arguments)

        if not ok then
            Print("Error in /cn " .. command .. ": " .. tostring(err))
        end

        return
    end

    Print("Unknown command: " .. tostring(command))

    ShowHelp()
end

CN.HandleSlashCommand = HandleSlashCommand

------------------------------------------------------------
-- REGISTRATION
------------------------------------------------------------

SLASH_COMPLETIONNAVIGATOR1 = "/cn"
SLASH_COMPLETIONNAVIGATOR2 = "/completionnavigator"

SlashCmdList.COMPLETIONNAVIGATOR = HandleSlashCommand

------------------------------------------------------------
-- BUILT-IN COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "status",
    order   = 1,
    help    = "Show addon status.",
    handler = function()
        ShowStatus()
    end,
}

CN:RegisterCommand{
    name    = "help",
    order   = 2,
    help    = "Show this help.",
    handler = function()
        ShowHelp()
    end,
}

CN:RegisterCommand{
    name    = "debug",
    order   = 3,
    help    = "Toggle debug mode.",
    handler = function()
        local settings = CN.Settings()

        settings.debug = not settings.debug

        Print("Debug mode " .. (settings.debug and "enabled." or "disabled."))
    end,
}

CN:RegisterCommand{
    name    = "mode",
    args    = "[modeName]",
    order   = 4,
    help    = "Show or set the priority mode.",
    handler = function(args)
        local settings = CN.Settings()

        if args == "" then
            Print("Priority mode: " .. tostring(settings.priorityMode))
            Print("Available: " .. table.concat(CN.priorityModes, ", "))
            return
        end

        local requested = string.lower(args)

        for _, mode in ipairs(CN.priorityModes) do
            if mode == requested then
                settings.priorityMode = requested
                Print("Priority mode set to " .. requested .. ".")
                return
            end
        end

        Print("Unknown priority mode: " .. requested)
        Print("Available: " .. table.concat(CN.priorityModes, ", "))
    end,
}
'@

$Embedded['Scoring.lua'] = @'
-- Scoring.lua
-- Completion Navigator :: the recommendation engine.
--
-- Priority Score =
--     Completion Value
--   + Unlock Value
--   + Limited-Time Bonus
--   + Nearby Objective Bonus
--   + User Preference Weight
--   + Character Suitability
--   - Travel Cost
--   - Estimated Time
--   - Difficulty Cost
--   - Dependency Cost

local ADDON_NAME, CN = ...

------------------------------------------------------------
-- WEIGHTS
------------------------------------------------------------

CN.scoreWeights = {
    completionValue     = 1.0,
    unlockValue         = 1.5,
    limitedTimeBonus    = 3.0,
    nearbyBonus         = 1.0,
    userPreference      = 1.0,
    characterSuitability = 1.0,
    travelCost          = -1.0,
    estimatedTime       = -0.5,
    difficultyCost      = -0.5,
    dependencyCost      = -1.0,
}

-- An objective with no known coordinates costs nothing to travel to, which
-- would let every unlocated objective outrank every located one. Charge a
-- baseline instead: not knowing where something is has a real cost.
CN.unknownLocationCost = 3

-- Priority profiles have two independent levers:
--   weights = override entries in scoreWeights (affects every objective)
--   types   = multiply the final score for a given objective type
-- Keeping them separate matters: an earlier version put weight names in the
-- type table, where they silently did nothing.
CN.priorityProfiles = {
    balanced     = {},
    fastest      = { weights = { travelCost = -2.5, estimatedTime = -1.5 } },
    zone         = { weights = { travelCost = -3.0, nearbyBonus = 2.0 } },
    quests       = { types = { QUEST = 2.0 } },
    achievements = { types = { ACHIEVEMENT = 2.0 } },
    reputation   = { types = { REPUTATION = 2.0, RENOWN = 2.0 } },
    pets         = { types = { PET = 2.0 } },
    professions  = { types = { PROFESSION = 2.0, RECIPE = 1.5 } },
    recipes      = { types = { RECIPE = 2.0 } },
    collections  = { types = { PET = 1.5, MOUNT = 1.5, TOY = 1.5, APPEARANCE = 1.5 } },
    legacy       = {},
}

------------------------------------------------------------
-- SCORING
------------------------------------------------------------

function CN.ScoreObjective(objective)
    if type(objective) ~= "table" then
        return 0
    end

    local settings = CN.Settings()
    local mode     = (settings and settings.priorityMode) or "balanced"
    local profile  = CN.priorityProfiles[mode] or {}

    -- Effective weights: defaults, then this profile's overrides.
    local w = {}

    for key, value in pairs(CN.scoreWeights) do
        w[key] = value
    end

    if profile.weights then
        for key, value in pairs(profile.weights) do
            w[key] = value
        end
    end

    local travel = objective.travelCost

    if travel == nil then
        travel = CN.unknownLocationCost
    end

    local score = 0

    score = score + (objective.completionValue      or 1) * w.completionValue
    score = score + (objective.unlockValue          or 0) * w.unlockValue
    score = score + (objective.limitedTimeBonus     or 0) * w.limitedTimeBonus
    score = score + (objective.nearbyBonus          or 0) * w.nearbyBonus
    score = score + (objective.userPreference       or 0) * w.userPreference
    score = score + (objective.characterSuitability or 0) * w.characterSuitability
    score = score + travel                                * w.travelCost
    score = score + (objective.estimatedTime        or 0) * w.estimatedTime
    score = score + (objective.difficultyCost       or 0) * w.difficultyCost
    score = score + (objective.dependencyCost       or 0) * w.dependencyCost

    if profile.types and objective.type and profile.types[objective.type] then
        score = score * profile.types[objective.type]
    end

    -- Normalize -0.0, which formats as "-0.0" and reads like a bug.
    if score == 0 then
        score = 0
    end

    objective.priorityWeight = score

    return score
end

------------------------------------------------------------
-- CANDIDATE COLLECTION
------------------------------------------------------------

-- Modules contribute actionable objectives by registering a provider.
-- Each provider returns an array of objective tables.
CN.candidateProviders = CN.candidateProviders or {}

function CN.RegisterCandidateProvider(name, provider)
    CN.candidateProviders[name] = provider
end

-- Decorators get a pass over every candidate after collection and before
-- scoring. This is how cross-cutting concerns -- Warband suitability, for
-- one -- apply to objectives from modules that know nothing about them.
CN.candidateDecorators = CN.candidateDecorators or {}

function CN.RegisterCandidateDecorator(name, decorator)
    if type(decorator) == "function" then
        CN.candidateDecorators[name] = decorator
    end
end

function CN.CollectCandidates()
    local candidates = {}

    for name, provider in pairs(CN.candidateProviders) do
        local ok, result = pcall(provider)

        if ok and type(result) == "table" then
            for _, objective in ipairs(result) do
                table.insert(candidates, objective)
            end
        elseif not ok then
            CN.DebugPrint("Candidate provider " .. name .. " failed: " .. tostring(result))
        end
    end

    for name, decorator in pairs(CN.candidateDecorators) do
        for _, objective in ipairs(candidates) do
            local ok, err = pcall(decorator, objective)

            if not ok then
                CN.DebugPrint("Candidate decorator " .. name .. " failed: " .. tostring(err))
            end
        end
    end

    return candidates
end

------------------------------------------------------------
-- RECOMMENDATION
------------------------------------------------------------

function CN.Recommend(limit)
    limit = limit or 1

    local candidates = CN.CollectCandidates()

    for _, objective in ipairs(candidates) do
        CN.ScoreObjective(objective)
    end

    table.sort(candidates, function(a, b)
        return (a.priorityWeight or 0) > (b.priorityWeight or 0)
    end)

    local results = {}

    for index = 1, math.min(limit, #candidates) do
        table.insert(results, candidates[index])
    end

    return results
end

------------------------------------------------------------
-- EXPLANATION
------------------------------------------------------------

function CN.ExplainRecommendation(objective)
    local lines = {}

    if objective.reasons then
        for _, reason in ipairs(objective.reasons) do
            table.insert(lines, "- " .. reason)
        end
    end

    if #lines == 0 then
        table.insert(lines, "- highest available priority score")
    end

    return lines
end

------------------------------------------------------------
-- COMMAND
------------------------------------------------------------

CN:RegisterCommand{
    name    = "next",
    order   = 10,
    help    = "Recommend the next objective.",
    handler = function()
        local results = CN.Recommend(1)

        if #results == 0 then
            CN.Print("No actionable objectives are known yet.")
            CN.Print("The recommendation engine needs candidate providers; quests are the only subsystem currently online.")
            return
        end

        local objective = results[1]

        CN.currentRecommendation = objective

        CN.Print("Recommended next: " .. tostring(objective.name or objective.id)
            .. " |cff999999(" .. tostring(objective.type) .. ")|r")

        for _, line in ipairs(CN.ExplainRecommendation(objective)) do
            CN.Print(line)
        end

        if objective.mapID and objective.x and objective.y then
            CN.Print("|cffffff00/cn go|r to set a waypoint.")
        end
    end,
}

CN:RegisterCommand{
    name    = "list",
    args    = "[count]",
    order   = 11,
    help    = "Show the top scored objectives.",
    handler = function(args)
        local limit = CN.ToID(args) or 5

        local results = CN.Recommend(limit)

        if #results == 0 then
            CN.Print("No actionable objectives are known yet.")
            return
        end

        for index, objective in ipairs(results) do
            CN.Print(index .. ". " .. tostring(objective.name or objective.id)
                .. " |cff999999[" .. tostring(objective.type)
                .. " " .. string.format("%.1f", objective.priorityWeight or 0) .. "]|r")
        end
    end,
}
'@

$Embedded['Routing.lua'] = @'
-- Routing.lua
-- Completion Navigator :: waypoint creation and zone clustering.
--
-- Navigation is delegated to a provider (TomTom first, Blizzard map pins
-- as fallback) rather than reimplemented. This file only decides WHERE to
-- point.

local ADDON_NAME, CN = ...

------------------------------------------------------------
-- PROVIDER REGISTRY
------------------------------------------------------------

CN.waypointProviders = CN.waypointProviders or {}
CN.waypointOrder     = CN.waypointOrder or {}

-- provider = {
--     IsAvailable = function() return boolean end,
--     SetWaypoint = function(mapID, x, y, title) end,
--     ClearAll    = function() end,
-- }
function CN.RegisterWaypointProvider(name, provider, priority)
    CN.waypointProviders[name] = provider

    table.insert(CN.waypointOrder, { name = name, priority = priority or 100 })

    table.sort(CN.waypointOrder, function(a, b)
        return a.priority < b.priority
    end)
end

function CN.GetWaypointProvider()
    for _, entry in ipairs(CN.waypointOrder) do
        local provider = CN.waypointProviders[entry.name]

        if provider and provider.IsAvailable and provider.IsAvailable() then
            return provider, entry.name
        end
    end

    return nil, nil
end

------------------------------------------------------------
-- WAYPOINTS
------------------------------------------------------------

function CN.SetWaypoint(mapID, x, y, title)
    if not mapID or not x or not y then
        CN.Print("No coordinates are known for that objective.")
        return false
    end

    local provider, name = CN.GetWaypointProvider()

    if not provider then
        CN.Print("No waypoint provider is available. Install TomTom for navigation.")
        return false
    end

    provider.SetWaypoint(mapID, x, y, title)

    CN.DebugPrint("Waypoint set via " .. tostring(name) .. ".")

    return true
end

-- The single entry point for "take me there", used by /cn go, the Navigate
-- button, the zone list, and the minimap button.
--
-- Order of preference:
--   1. Real coordinates -> a waypoint in TomTom or a Blizzard map pin.
--   2. An active quest with no coordinates -> hand it to Blizzard's own
--      quest tracking arrow, which knows where its own quests are.
--   3. Nothing -> say so plainly and explain why.
function CN.NavigateToObjective(objective)
    if type(objective) ~= "table" then
        CN.Print("Nothing to navigate to.")
        return false
    end

    local name = tostring(objective.name or objective.id or "that objective")

    if objective.mapID and objective.x and objective.y then
        if CN.SetWaypoint(objective.mapID, objective.x, objective.y, name) then
            CN.Print("Waypoint set: " .. name)
            return true
        end

        return false
    end

    -- Re-resolve: coordinates often appear once the player is on the right
    -- map, and the objective may have been built somewhere else.
    if objective.type == CN.objectiveTypes.QUEST and objective.id then
        local quests = CN:GetModule("Quests")

        if quests then
            local mapID, x, y = quests.GetLocation(objective.id)

            if mapID and x and y then
                objective.mapID, objective.x, objective.y = mapID, x, y

                if CN.SetWaypoint(mapID, x, y, name) then
                    CN.Print("Waypoint set: " .. name)
                    return true
                end

                return false
            end
        end

        if CN.Blizzard.IsQuestInLog(objective.id)
            and CN.Blizzard.SuperTrackQuest(objective.id) then

            CN.Print("No map coordinates for " .. name
                .. "; using Blizzard's quest tracking arrow instead.")

            return true
        end

        CN.Print("No coordinates are known for " .. name .. ".")
        CN.Print("The client exposes none for this quest and it is not in your log. "
            .. "Add them with |cffffff00/cn setloc " .. tostring(objective.id)
            .. " <mapID> <x> <y>|r.")

        return false
    end

    CN.Print("No coordinates are known for " .. name .. ".")

    if objective.type == CN.objectiveTypes.REPUTATION then
        CN.Print("Reputations have no single location.")
    end

    return false
end

function CN.ClearWaypoints()
    local provider = CN.GetWaypointProvider()

    if provider and provider.ClearAll then
        provider.ClearAll()
    end
end

------------------------------------------------------------
-- CLUSTERING
------------------------------------------------------------

-- Groups objectives by mapID so a zone sweep can be planned.
function CN.ClusterByMap(objectives)
    local clusters = {}

    for _, objective in ipairs(objectives) do
        if objective.mapID then
            clusters[objective.mapID] = clusters[objective.mapID] or {}
            table.insert(clusters[objective.mapID], objective)
        end
    end

    return clusters
end

-- Nearest-neighbour ordering from a starting point. Good enough for a
-- zone sweep; a proper route solver can replace this later.
function CN.OrderByProximity(objectives, startX, startY)
    local remaining = {}

    for _, objective in ipairs(objectives) do
        table.insert(remaining, objective)
    end

    local ordered = {}
    local currentX, currentY = startX or 0.5, startY or 0.5

    while #remaining > 0 do
        local bestIndex, bestDistance

        for index, objective in ipairs(remaining) do
            local dx = (objective.x or 0.5) - currentX
            local dy = (objective.y or 0.5) - currentY
            local distance = (dx * dx) + (dy * dy)

            if not bestDistance or distance < bestDistance then
                bestDistance = distance
                bestIndex    = index
            end
        end

        local chosen = table.remove(remaining, bestIndex)

        table.insert(ordered, chosen)

        currentX = chosen.x or currentX
        currentY = chosen.y or currentY
    end

    return ordered
end

------------------------------------------------------------
-- ZONE ROUTES
------------------------------------------------------------

-- Builds an ordered sweep of everything currently actionable in one map.
-- Returns route, skipped -- where skipped are objectives that belong to the
-- zone conceptually but have no coordinates to route to.
function CN.BuildZoneRoute(mapID, startX, startY)
    local candidates = CN.CollectCandidates()

    local located, skipped = {}, {}

    for _, objective in ipairs(candidates) do
        CN.ScoreObjective(objective)

        if objective.mapID == mapID then
            if objective.x and objective.y then
                table.insert(located, objective)
            else
                table.insert(skipped, objective)
            end
        end
    end

    local route = CN.OrderByProximity(located, startX, startY)

    CN.currentRoute = route

    return route, skipped
end

-- Counts what remains in the zone, grouped by objective type. Deliberately
-- not a percentage: a percentage needs a trustworthy denominator, and the
-- static database is nowhere near complete enough to provide one.
function CN.SummarizeZone(route, skipped)
    local counts, order = {}, {}

    local function tally(list)
        for _, objective in ipairs(list) do
            local key = objective.type or "UNKNOWN"

            if not counts[key] then
                counts[key] = 0
                table.insert(order, key)
            end

            counts[key] = counts[key] + 1
        end
    end

    tally(route)
    tally(skipped)

    table.sort(order)

    return counts, order
end

------------------------------------------------------------
-- AUTO-ADVANCE
------------------------------------------------------------

-- Hands-free mode: when the thing you were pointed at is done, point at the
-- next one automatically.
--
-- Off by default and deliberately so. Taking over the waypoint without being
-- asked is hostile -- the player may be following a route of their own, and
-- TomTom arrows are shared with every other addon.
--
-- The rule for re-pointing is "the objective changed", not "time passed". A
-- waypoint that silently moves while you are walking to it is worse than one
-- that never moves at all.

local ticker
local lastAnnounced

function CN.IsAutoWaypointEnabled()
    local settings = CN.Settings()

    return settings and settings.autoWaypoint == true
end

-- Returns true when the objective we were pointing at is no longer the one
-- worth doing.
local function CurrentIsStale()
    local current = CN.currentRecommendation

    if not current then
        return true
    end

    -- Completed, or otherwise no longer available.
    if current.id and current.type then
        local state = CN.Explain(current.type, current.id)

        local states = CN.objectiveStates

        if state == states.COMPLETED
            or state == states.IGNORED
            or state == states.DEFERRED
            or state == states.UNOBTAINABLE then
            return true
        end
    end

    return false
end

function CN.AutoAdvance(reason, force)
    if not CN.IsAutoWaypointEnabled() then
        return false
    end

    if not force and not CurrentIsStale() then
        return false
    end

    local results = CN.Recommend(1)

    if #results == 0 then
        return false
    end

    local objective = results[1]

    -- Do not re-announce the same objective over and over.
    local signature = tostring(objective.type) .. ":" .. tostring(objective.id)

    if signature == lastAnnounced and not force then
        return false
    end

    CN.currentRecommendation = objective

    local navigated = CN.NavigateToObjective(objective)

    if navigated then
        lastAnnounced = signature

        CN.DebugPrint("Auto-advanced (" .. tostring(reason) .. ").")
    end

    return navigated
end

-- Completion events are the honest trigger: something finished, so what is
-- next may have changed.
for _, event in ipairs({
    "QUEST_TURNED_IN",
    "QUEST_REMOVED",
    "ACHIEVEMENT_EARNED",
    "NEW_PET_ADDED",
    "NEW_MOUNT_ADDED",
    "NEW_TOY_ADDED",
    "VIGNETTE_MINIMAP_UPDATED",
    "ZONE_CHANGED_NEW_AREA",
}) do
    CN:RegisterEvent(event, function()
        CN.AutoAdvance(event)
    end)
end

-- A slow backstop for objectives that expire rather than complete: a world
-- quest can run out while you are standing still, and no event fires for it.
function CN.StartAutoWaypointTicker()
    if ticker or not C_Timer or not C_Timer.NewTicker then
        return
    end

    ticker = C_Timer.NewTicker(60, function()
        if CN.IsAutoWaypointEnabled() then
            CN.AutoAdvance("ticker")
        end
    end)
end

function CN.StopAutoWaypointTicker()
    if ticker and ticker.Cancel then
        ticker:Cancel()
    end

    ticker = nil
end

CN:OnLogin(function()
    if CN.IsAutoWaypointEnabled() then
        CN.StartAutoWaypointTicker()
    end
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "zone",
    args    = "[stopNumber]",
    order   = 14,
    help    = "Route everything obtainable in this zone.",
    handler = function(args)
        local mapID, playerX, playerY = CN.GetPlayerPosition()

        if not mapID then
            CN.Print("Your current map could not be determined.")
            return
        end

        local zoneName = CN.Blizzard.GetMapName(mapID) or "this zone"

        local stop = CN.ToID(args)

        -- Re-routing on every call keeps the sweep honest as things complete.
        local route, skipped = CN.BuildZoneRoute(mapID, playerX, playerY)

        if stop then
            local objective = route[stop]

            if not objective then
                CN.Print("There is no stop " .. stop .. " in the current route.")
                return
            end

            CN.currentRecommendation = objective

            CN.NavigateToObjective(objective)

            return
        end

        if #route == 0 and #skipped == 0 then
            CN.Print(zoneName .. ": nothing actionable is known here.")
            CN.Print("Run |cffffff00/cn discoveractive|r and |cffffff00/cn repscan|r, "
                .. "then try again.")
            return
        end

        local counts, order = CN.SummarizeZone(route, skipped)

        local parts = {}

        for _, key in ipairs(order) do
            table.insert(parts, counts[key] .. " " .. string.lower(key))
        end

        CN.Print(zoneName .. " |cff999999(map " .. mapID .. ")|r - remaining: "
            .. table.concat(parts, ", "))

        local shown = math.min(#route, 10)

        for index = 1, shown do
            local objective = route[index]

            CN.Print(index .. ". " .. tostring(objective.name or objective.id)
                .. " |cff999999[" .. tostring(objective.type) .. "]|r")
        end

        if #route > shown then
            CN.Print("|cff999999... and " .. (#route - shown) .. " more.|r")
        end

        if #skipped > 0 then
            CN.Print("|cff999999" .. #skipped
                .. " objective(s) here have no coordinates and cannot be routed.|r")
        end

        if #route > 0 then
            CN.currentRecommendation = route[1]

            CN.Print("|cffffff00/cn go|r for stop 1, or |cffffff00/cn zone <n>|r for another.")
        end
    end,
}

CN:RegisterCommand{
    name    = "go",
    args    = "[questID]",
    order   = 12,
    help    = "Set a waypoint to the recommendation, or to a quest.",
    handler = function(args)
        local objective

        local questID = CN.ToID(args)

        if questID then
            local quests = CN:GetModule("Quests")

            if not quests then
                CN.Print("The quest module is not loaded.")
                return
            end

            local mapID, x, y = quests.GetLocation(questID)

            -- id and type are load-bearing: without them
            -- NavigateToObjective cannot take the quest-specific path and
            -- falls through to the generic "no location" message.
            objective = {
                id    = questID,
                type  = CN.objectiveTypes.QUEST,
                name  = quests.GetName(questID, true) or ("Quest " .. questID),
                mapID = mapID,
                x     = x,
                y     = y,
            }
        else
            objective = CN.currentRecommendation

            if not objective then
                CN.Print("Nothing recommended yet. Run |cffffff00/cn next|r first.")
                return
            end
        end

        CN.NavigateToObjective(objective)
    end,
}

CN:RegisterCommand{
    name    = "auto",
    order   = 11,
    help    = "Toggle automatically re-pointing the waypoint as you finish things.",
    handler = function()
        local settings = CN.Settings()

        settings.autoWaypoint = not settings.autoWaypoint

        if settings.autoWaypoint then
            CN.StartAutoWaypointTicker()

            CN.Print("Auto-waypoint |cff00ff00on|r. "
                .. "The waypoint moves to the next objective as you finish things.")

            CN.AutoAdvance("enabled", true)
        else
            CN.StopAutoWaypointTicker()

            CN.Print("Auto-waypoint |cffff4444off|r. Waypoints stay where you put them.")
        end
    end,
}

CN:RegisterCommand{
    name    = "clearway",
    order   = 13,
    help    = "Clear waypoints this addon created.",
    handler = function()
        CN.ClearWaypoints()
        CN.Print("Waypoints cleared.")
    end,
}

------------------------------------------------------------
-- PLAYER POSITION
------------------------------------------------------------

function CN.GetPlayerPosition()
    if not C_Map then
        return nil, nil, nil
    end

    local mapID = C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")

    if not mapID then
        return nil, nil, nil
    end

    local position = C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(mapID, "player")

    if not position then
        return mapID, nil, nil
    end

    local x, y = position:GetXY()

    return mapID, x, y
end
'@

$Embedded['UI.lua'] = @'
-- UI.lua
-- Completion Navigator :: minimap button, main window, and tab framework.
--
-- Every command in this addon is reachable by clicking. Typing is the
-- power-user path, not the required path.
--
-- Tabs are registered, not hardcoded, so a module can contribute its own
-- panel without this file knowing it exists:
--
--   CN.UI.RegisterTab{
--       name    = "Pets",
--       order   = 40,
--       build   = function(content) end,   -- once, on first show
--       refresh = function(content) end,   -- every time it becomes visible
--   }
--
-- No external libraries. LibDBIcon and Ace would each drag in an embedded
-- library tree, and the minimap button below is about eighty lines.

local ADDON_NAME, CN = ...

local UI = {}

CN.UI = UI

local Print = CN.Print

local WINDOW_WIDTH  = 560
local WINDOW_HEIGHT = 440
local ROW_HEIGHT    = 20

local window, minimapButton

------------------------------------------------------------
-- TEMPLATE SAFETY
------------------------------------------------------------

-- Blizzard renames and retires XML templates between expansions. A missing
-- template makes CreateFrame throw, which would take the entire window with
-- it. Every templated frame in this file goes through here so a retired
-- template degrades to a plain frame instead of no UI at all.
local function SafeCreateFrame(frameType, name, parent, template)
    if template then
        local ok, frame = pcall(CreateFrame, frameType, name, parent, template)

        if ok and frame then
            return frame, true
        end

        CN.DebugPrint("Template '" .. tostring(template)
            .. "' is unavailable; falling back to a plain frame.")
    end

    return CreateFrame(frameType, name, parent), false
end

UI.SafeCreateFrame = SafeCreateFrame

-- Draws a background and a one-pixel border with plain textures. Owes
-- nothing to any template or to the Backdrop system.
local function PaintPanel(frame, r, g, b, a)
    local background = frame:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints()
    background:SetColorTexture(r or 0.05, g or 0.05, b or 0.06, a or 0.94)

    local edges = {
        { "TOPLEFT", "TOPRIGHT", 0, 0, 0, -1 },
        { "BOTTOMLEFT", "BOTTOMRIGHT", 0, 1, 0, 0 },
        { "TOPLEFT", "BOTTOMLEFT", 0, 0, 1, 0 },
        { "TOPRIGHT", "BOTTOMRIGHT", -1, 0, 0, 0 },
    }

    for _, edge in ipairs(edges) do
        local line = frame:CreateTexture(nil, "BORDER")
        line:SetColorTexture(0.35, 0.35, 0.38, 1)
        line:SetPoint(edge[1], edge[3], edge[4])
        line:SetPoint(edge[2], edge[5], edge[6])

        if edge[1] == "TOPLEFT" and edge[2] == "TOPRIGHT" then
            line:SetHeight(1)
        elseif edge[1] == "BOTTOMLEFT" then
            line:SetHeight(1)
        else
            line:SetWidth(1)
        end
    end

    return background
end

UI.PaintPanel = PaintPanel

------------------------------------------------------------
-- TAB REGISTRY
------------------------------------------------------------

UI.tabs = {}

function UI.RegisterTab(definition)
    if type(definition) ~= "table" or not definition.name then
        return
    end

    definition.order = definition.order or 100

    table.insert(UI.tabs, definition)

    table.sort(UI.tabs, function(a, b)
        if a.order == b.order then
            return a.name < b.name
        end

        return a.order < b.order
    end)

    -- A tab registered after the window was built still needs a button.
    if window then
        UI.RebuildTabs()
    end
end

------------------------------------------------------------
-- SCROLLING LIST
------------------------------------------------------------

-- Creates a reusable row list. Rows are pooled; SetRows swaps the data.
local function CreateList(parent)
    local list = CreateFrame("Frame", nil, parent)

    list:SetPoint("TOPLEFT", 8, -8)
    list:SetPoint("BOTTOMRIGHT", -8, 8)

    local scroll = SafeCreateFrame("ScrollFrame", nil, list, "UIPanelScrollFrameTemplate")

    scroll:SetPoint("TOPLEFT")
    scroll:SetPoint("BOTTOMRIGHT", -26, 0)

    local content = CreateFrame("Frame", nil, scroll)

    content:SetSize(1, 1)
    scroll:SetScrollChild(content)

    list.rows = {}

    function list:GetRow(index)
        if self.rows[index] then
            return self.rows[index]
        end

        local row = CreateFrame("Button", nil, content)

        row:SetHeight(ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 0, -((index - 1) * ROW_HEIGHT))
        row:SetPoint("TOPRIGHT", 0, -((index - 1) * ROW_HEIGHT))

        row.highlight = row:CreateTexture(nil, "HIGHLIGHT")
        row.highlight:SetAllPoints()
        row.highlight:SetColorTexture(1, 1, 1, 0.10)

        row.label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightLeft")
        row.label:SetPoint("LEFT", 4, 0)
        row.label:SetPoint("RIGHT", -4, 0)
        row.label:SetJustifyH("LEFT")

        self.rows[index] = row

        return row
    end

    -- entries = { { text = , onClick = , tooltip = }, ... }
    function list:SetEntries(entries)
        local width = scroll:GetWidth() or (WINDOW_WIDTH - 60)

        content:SetSize(width, math.max(1, #entries * ROW_HEIGHT))

        for index, entry in ipairs(entries) do
            local row = self:GetRow(index)

            row.label:SetText(entry.text or "")
            row.entry = entry

            row:SetScript("OnClick", function()
                if entry.onClick then
                    entry.onClick()
                end
            end)

            if entry.tooltip then
                row:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText(entry.tooltip, nil, nil, nil, nil, true)
                    GameTooltip:Show()
                end)

                row:SetScript("OnLeave", function()
                    GameTooltip:Hide()
                end)
            else
                row:SetScript("OnEnter", nil)
                row:SetScript("OnLeave", nil)
            end

            row:Show()
        end

        for index = #entries + 1, #self.rows do
            self.rows[index]:Hide()
        end
    end

    return list
end

UI.CreateList = CreateList

------------------------------------------------------------
-- BUTTON HELPERS
------------------------------------------------------------

local function AddButton(parent, text, width, onClick)
    local button, templated = SafeCreateFrame("Button", nil, parent, "UIPanelButtonTemplate")

    button:SetSize(width or 110, 22)

    if not templated then
        -- A plain Button has no artwork and no font string of its own.
        PaintPanel(button, 0.16, 0.16, 0.19, 1)

        local label = button:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        label:SetPoint("CENTER")
        button:SetFontString(label)

        local highlight = button:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetAllPoints()
        highlight:SetColorTexture(1, 1, 1, 0.12)
    end

    button:SetText(text)
    button:SetScript("OnClick", onClick)

    return button
end

local function AddCheckbox(parent, text, getter, setter)
    local check, templated = SafeCreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")

    check:SetSize(24, 24)

    if check.Text then
        check.Text:SetText(text)
    else
        local label = check:CreateFontString(nil, "ARTWORK", "GameFontHighlightLeft")
        label:SetPoint("LEFT", check, "RIGHT", 2, 0)
        label:SetText(text)
        check.Text = label
    end

    check:SetScript("OnClick", function(self)
        setter(self:GetChecked() and true or false)
    end)

    check.Refresh = function()
        check:SetChecked(getter() and true or false)
    end

    return check
end

UI.AddButton   = AddButton
UI.AddCheckbox = AddCheckbox

------------------------------------------------------------
-- WINDOW
------------------------------------------------------------

local function BuildWindow()
    if window then
        return window
    end

    -- Prefer Blizzard's frame so the window matches the rest of the game.
    -- The hand-painted fallback below only runs if that template is ever
    -- retired or renamed, which has happened to other templates before.
    local templated

    window, templated = SafeCreateFrame("Frame", "CompletionNavigatorFrame", UIParent,
        "BasicFrameTemplateWithInset")

    window:SetSize(WINDOW_WIDTH, WINDOW_HEIGHT)
    window:SetPoint("CENTER")
    window:SetMovable(true)
    window:EnableMouse(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", window.StartMoving)
    window:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        UI.SavePosition()
    end)
    window:SetClampedToScreen(true)
    window:SetFrameStrata("DIALOG")
    window:SetToplevel(true)
    window:Hide()

    if templated and window.TitleText then
        window.TitleText:SetText("Completion Navigator")
    else
        PaintPanel(window)

        local titleBar = CreateFrame("Frame", nil, window)
        titleBar:SetPoint("TOPLEFT", 1, -1)
        titleBar:SetPoint("TOPRIGHT", -1, -1)
        titleBar:SetHeight(24)

        local titleBackground = titleBar:CreateTexture(nil, "ARTWORK")
        titleBackground:SetAllPoints()
        titleBackground:SetColorTexture(0.13, 0.13, 0.16, 1)

        local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("LEFT", 10, 0)
        title:SetText("Completion Navigator")

        local close = CreateFrame("Button", nil, window)
        close:SetSize(22, 22)
        close:SetPoint("TOPRIGHT", -3, -2)

        local closeLabel = close:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        closeLabel:SetPoint("CENTER")
        closeLabel:SetText("x")
        close:SetFontString(closeLabel)

        local closeHighlight = close:CreateTexture(nil, "HIGHLIGHT")
        closeHighlight:SetAllPoints()
        closeHighlight:SetColorTexture(0.8, 0.1, 0.1, 0.4)

        close:SetScript("OnClick", function()
            window:Hide()
        end)
    end

    -- Escape should close it, like every other panel in the game.
    if UISpecialFrames then
        table.insert(UISpecialFrames, "CompletionNavigatorFrame")
    end

    window.tabButtons = {}

    window.body = CreateFrame("Frame", nil, window)
    window.body:SetPoint("TOPLEFT", 10, -58)
    window.body:SetPoint("BOTTOMRIGHT", -10, 34)

    window.footer = window:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    window.footer:SetPoint("BOTTOMLEFT", 14, 14)
    window.footer:SetText("/cn help for the full command list")

    UI.RebuildTabs()

    return window
end

UI.BuildWindow = BuildWindow

function UI.SavePosition()
    if not window or not CN.db then
        return
    end

    local point, _, relativePoint, x, y = window:GetPoint()

    CN.Settings().window = {
        point         = point,
        relativePoint = relativePoint,
        x             = x,
        y             = y,
    }
end

function UI.RestorePosition()
    local saved = CN.Settings() and CN.Settings().window

    if not window or not saved or not saved.point then
        return
    end

    window:ClearAllPoints()
    window:SetPoint(saved.point, UIParent, saved.relativePoint, saved.x, saved.y)
end

------------------------------------------------------------
-- TABS
------------------------------------------------------------

function UI.RebuildTabs()
    if not window then
        return
    end

    for _, button in ipairs(window.tabButtons) do
        button:Hide()
    end

    local previous
    local row, rowWidth = 0, 0

    for index, tab in ipairs(UI.tabs) do
        local button = window.tabButtons[index]

        if not button then
            button = SafeCreateFrame("Button", nil, window, "UIPanelButtonTemplate")
            button:SetHeight(22)
            window.tabButtons[index] = button
        end

        button:SetText(tab.name)

        -- GetTextWidth exists on Button, but guard anyway: a nil or
        -- non-numeric return here would break the whole window.
        local textWidth = button.GetTextWidth and button:GetTextWidth()

        if type(textWidth) ~= "number" then
            textWidth = 60
        end

        local buttonWidth = math.max(64, textWidth + 18)

        button:SetWidth(buttonWidth)
        button:ClearAllPoints()

        -- Wrap to a new row rather than running off the edge. Tabs are a
        -- registry, so the count grows as modules are added and a fixed
        -- single row would eventually overflow silently.
        if previous and (rowWidth + buttonWidth + 4) > (WINDOW_WIDTH - 24) then
            row      = row + 1
            rowWidth = 0
            previous = nil
        end

        if previous then
            button:SetPoint("LEFT", previous, "RIGHT", 4, 0)
        else
            button:SetPoint("TOPLEFT", 12, -30 - (row * 26))
        end

        rowWidth = rowWidth + buttonWidth + 4

        button:SetScript("OnClick", function()
            UI.SelectTab(index)
        end)

        button:Show()

        previous = button
    end

    -- Push the body down so a second row of tabs does not overlap it.
    if window.body then
        window.body:ClearAllPoints()
        window.body:SetPoint("TOPLEFT", 10, -58 - (row * 26))
        window.body:SetPoint("BOTTOMRIGHT", -10, 34)
    end

    UI.SelectTab(UI.selectedTab or 1)
end

function UI.SelectTab(index)
    local tab = UI.tabs[index]

    if not tab or not window then
        return
    end

    UI.selectedTab = index

    for buttonIndex, button in ipairs(window.tabButtons) do
        if buttonIndex == index then
            button:SetEnabled(false)
        else
            button:SetEnabled(true)
        end
    end

    for _, other in ipairs(UI.tabs) do
        if other.panel then
            other.panel:Hide()
        end
    end

    if not tab.panel then
        tab.panel = CreateFrame("Frame", nil, window.body)
        tab.panel:SetAllPoints()

        if tab.build then
            local ok, err = pcall(tab.build, tab.panel)

            if not ok then
                Print("Error building the " .. tab.name .. " tab: " .. tostring(err))
            end
        end
    end

    tab.panel:Show()

    UI.Refresh()
end

------------------------------------------------------------
-- REFRESH
------------------------------------------------------------

function UI.Refresh()
    if not window or not window:IsShown() then
        return
    end

    local tab = UI.tabs[UI.selectedTab or 1]

    if tab and tab.refresh and tab.panel then
        local ok, err = pcall(tab.refresh, tab.panel)

        if not ok then
            Print("Error refreshing the " .. tab.name .. " tab: " .. tostring(err))
        end
    end
end

-- Called from data events. Cheap when the window is closed.
local lastRefresh = 0

function UI.RequestRefresh()
    if not window or not window:IsShown() then
        return
    end

    local now = time()

    if now - lastRefresh < 2 then
        return
    end

    lastRefresh = now

    UI.Refresh()
end

------------------------------------------------------------
-- SHOW / HIDE
------------------------------------------------------------

function UI.Toggle()
    BuildWindow()

    if window:IsShown() then
        window:Hide()
        return
    end

    UI.RestorePosition()
    window:Show()
    UI.Refresh()

    -- If the frame refuses to show, say so. Silence here is what makes a
    -- missing window look like a command that did nothing.
    if not window:IsShown() then
        Print("The window could not be shown. Run |cffffff00/cn uistatus|r.")
    end
end

function UI.Show()
    BuildWindow()
    UI.RestorePosition()
    window:Show()
    UI.Refresh()
end

function UI.Hide()
    if window then
        window:Hide()
    end
end

-- Backwards compatibility with the earlier single-frame version.
CN.ToggleUI  = UI.Toggle
CN.RefreshUI = UI.Refresh

------------------------------------------------------------
-- TAB: NEXT
------------------------------------------------------------

UI.RegisterTab{
    name  = "Next",
    order = 10,

    build = function(panel)
        panel.title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
        panel.title:SetPoint("TOPLEFT", 8, -8)
        panel.title:SetPoint("TOPRIGHT", -8, -8)
        panel.title:SetJustifyH("LEFT")

        panel.type = panel:CreateFontString(nil, "ARTWORK", "GameFontDisable")
        panel.type:SetPoint("TOPLEFT", panel.title, "BOTTOMLEFT", 0, -2)

        panel.why = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightLeft")
        panel.why:SetPoint("TOPLEFT", panel.type, "BOTTOMLEFT", 0, -12)
        panel.why:SetPoint("RIGHT", -8, 0)
        panel.why:SetJustifyH("LEFT")
        panel.why:SetJustifyV("TOP")

        panel.navigate = AddButton(panel, "Navigate", 110, function()
            local objective = CN.currentRecommendation

            if not objective then
                return
            end

            CN.NavigateToObjective(objective)
        end)
        panel.navigate:SetPoint("BOTTOMLEFT", 8, 8)

        panel.skip = AddButton(panel, "Defer 1 hour", 110, function()
            local objective = CN.currentRecommendation

            if not objective then
                return
            end

            CN.SetDeferred(objective.type, objective.id, 3600)
            Print("Deferred: " .. tostring(objective.name))
            UI.Refresh()
        end)
        panel.skip:SetPoint("LEFT", panel.navigate, "RIGHT", 6, 0)

        panel.ignore = AddButton(panel, "Ignore", 110, function()
            local objective = CN.currentRecommendation

            if not objective then
                return
            end

            CN.SetIgnored(objective.type, objective.id, true)
            Print("Ignored: " .. tostring(objective.name))
            UI.Refresh()
        end)
        panel.ignore:SetPoint("LEFT", panel.skip, "RIGHT", 6, 0)

        panel.list = CreateList(panel)
        panel.list:ClearAllPoints()
        panel.list:SetPoint("TOPLEFT", panel.why, "BOTTOMLEFT", -4, -14)
        panel.list:SetPoint("BOTTOMRIGHT", -8, 38)
    end,

    refresh = function(panel)
        local results = CN.Recommend(12)

        if #results == 0 then
            panel.title:SetText("Nothing actionable yet")
            panel.type:SetText("")
            panel.why:SetText("Run a scan from the Scans tab, or pick up a quest.")
            panel.list:SetEntries({})

            CN.currentRecommendation = nil

            return
        end

        local best = results[1]

        CN.currentRecommendation = best

        panel.title:SetText(tostring(best.name or best.id))
        panel.type:SetText(tostring(best.type))
        panel.why:SetText("Why:\n" .. table.concat(CN.ExplainRecommendation(best), "\n"))

        local entries = {}

        for index = 2, #results do
            local objective = results[index]

            table.insert(entries, {
                text = string.format("|cff999999%2d.|r %s |cff808080[%s]|r",
                    index, tostring(objective.name or objective.id),
                    tostring(objective.type)),

                tooltip = table.concat(CN.ExplainRecommendation(objective), "\n"),

                onClick = function()
                    CN.currentRecommendation = objective

                    panel.title:SetText(tostring(objective.name or objective.id))
                    panel.type:SetText(tostring(objective.type))
                    panel.why:SetText("Why:\n"
                        .. table.concat(CN.ExplainRecommendation(objective), "\n"))
                end,
            })
        end

        panel.list:SetEntries(entries)
    end,
}

------------------------------------------------------------
-- TAB: ZONE
------------------------------------------------------------

UI.RegisterTab{
    name  = "Zone",
    order = 20,

    build = function(panel)
        panel.header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        panel.header:SetPoint("TOPLEFT", 8, -8)
        panel.header:SetPoint("TOPRIGHT", -8, -8)
        panel.header:SetJustifyH("LEFT")

        panel.list = CreateList(panel)
        panel.list:ClearAllPoints()
        panel.list:SetPoint("TOPLEFT", 4, -32)
        panel.list:SetPoint("BOTTOMRIGHT", -8, 38)

        panel.route = AddButton(panel, "Re-route", 110, function()
            UI.Refresh()
        end)
        panel.route:SetPoint("BOTTOMLEFT", 8, 8)

        panel.clear = AddButton(panel, "Clear waypoints", 130, function()
            CN.ClearWaypoints()
        end)
        panel.clear:SetPoint("LEFT", panel.route, "RIGHT", 6, 0)
    end,

    refresh = function(panel)
        local mapID, x, y = CN.GetPlayerPosition()

        if not mapID then
            panel.header:SetText("Current map unknown.")
            panel.list:SetEntries({})
            return
        end

        local zoneName = CN.Blizzard.GetMapName(mapID) or "This zone"

        local route, skipped = CN.BuildZoneRoute(mapID, x, y)

        local counts, order = CN.SummarizeZone(route, skipped)

        local parts = {}

        for _, key in ipairs(order) do
            table.insert(parts, counts[key] .. " " .. string.lower(key))
        end

        if #parts == 0 then
            panel.header:SetText(zoneName .. " - nothing actionable is known here.")
        else
            panel.header:SetText(zoneName .. " - remaining: " .. table.concat(parts, ", "))
        end

        local entries = {}

        for index, objective in ipairs(route) do
            table.insert(entries, {
                text = string.format("|cff999999%2d.|r %s |cff808080[%s]|r",
                    index, tostring(objective.name or objective.id),
                    tostring(objective.type)),

                tooltip = "Click to set a waypoint.\n"
                    .. table.concat(CN.ExplainRecommendation(objective), "\n"),

                onClick = function()
                    CN.currentRecommendation = objective
                    CN.NavigateToObjective(objective)
                end,
            })
        end

        for _, objective in ipairs(skipped) do
            table.insert(entries, {
                text = "|cff808080     " .. tostring(objective.name or objective.id)
                    .. " (no coordinates)|r",
            })
        end

        panel.list:SetEntries(entries)
    end,
}

------------------------------------------------------------
-- TAB: SCANS
------------------------------------------------------------

UI.RegisterTab{
    name  = "Scans",
    order = 30,

    build = function(panel)
        panel.status = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightLeft")
        panel.status:SetPoint("TOPLEFT", 8, -8)
        panel.status:SetPoint("RIGHT", -8, 0)
        panel.status:SetJustifyH("LEFT")
        panel.status:SetJustifyV("TOP")

        local quests = AddButton(panel, "Scan quests", 130, function()
            local module = CN:GetModule("Quests")

            if module then
                local seen, new = module.DiscoverActive()
                local scanned   = module.ScanKnown()

                Print("Quest scan: " .. seen .. " active, " .. new .. " new, "
                    .. scanned .. " checked.")
            end

            UI.Refresh()
        end)
        quests:SetPoint("BOTTOMLEFT", 8, 8)

        local reps = AddButton(panel, "Scan reputations", 150, function()
            local module = CN:GetModule("Reputations")

            if module then
                local total = module.Scan()

                Print("Reputation scan: " .. total .. " factions.")
            end

            UI.Refresh()
        end)
        reps:SetPoint("LEFT", quests, "RIGHT", 6, 0)
    end,

    refresh = function(panel)
        local lines = {}

        table.insert(lines, "|cffffd100Quests|r")
        table.insert(lines, "Discovered: " .. CN.CountKeys(CN.Account("discoveredQuests")))
        table.insert(lines, "Names cached: " .. CN.CountKeys(CN.Account("questMetadata")))
        table.insert(lines, "Statuses stored: " .. CN.CountKeys(CN.Account("questStatus")))
        table.insert(lines, " ")

        local reputations = CN:GetModule("Reputations")

        if reputations then
            local counts = reputations.Summary()

            table.insert(lines, "|cffffd100Reputations|r")
            table.insert(lines, "Account-wide: " .. counts.account)
            table.insert(lines, "Character-specific: " .. counts.character)
            table.insert(lines, "Renown: " .. counts.renown
                .. " (" .. counts.maxedRenown .. " maxed)")
            table.insert(lines, "Exalted: " .. counts.exalted)

            if counts.paragonPending > 0 then
                table.insert(lines, "|cff00ff00Paragon rewards waiting: "
                    .. counts.paragonPending .. "|r")
            end

            table.insert(lines, " ")
        end

        table.insert(lines, "|cffffd100Warband|r")
        table.insert(lines, "Known characters: " .. CN.GetCharacterCount())

        panel.status:SetText(table.concat(lines, "\n"))
    end,
}

------------------------------------------------------------
-- TAB: NOW
------------------------------------------------------------

-- Everything with a clock on it, in one place. Nothing added since 0.9 was
-- reachable without typing, which broke the rule this file opens with.
UI.RegisterTab{
    name  = "Now",
    order = 15,

    build = function(panel)
        panel.header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        panel.header:SetPoint("TOPLEFT", 8, -8)
        panel.header:SetPoint("TOPRIGHT", -8, -8)
        panel.header:SetJustifyH("LEFT")

        panel.list = CreateList(panel)
        panel.list:ClearAllPoints()
        panel.list:SetPoint("TOPLEFT", 4, -32)
        panel.list:SetPoint("BOTTOMRIGHT", -8, 38)

        panel.refresh = AddButton(panel, "Refresh", 110, function()
            UI.Refresh()
        end)
        panel.refresh:SetPoint("BOTTOMLEFT", 8, 8)

        panel.scanCurrency = AddButton(panel, "Rescan currencies", 150, function()
            local module = CN:GetModule("Currencies")

            if module then
                module.Scan()
            end

            UI.Refresh()
        end)
        panel.scanCurrency:SetPoint("LEFT", panel.refresh, "RIGHT", 6, 0)
    end,

    refresh = function(panel)
        local entries = {}

        local opportunities = CN:GetModule("Opportunities")

        if opportunities then
            local resets = opportunities.GetResets()

            local parts = {}

            if resets.daily then
                table.insert(parts, "daily in " .. opportunities.FormatTimeLeft(resets.daily))
            end

            if resets.weekly then
                table.insert(parts, "weekly in " .. opportunities.FormatTimeLeft(resets.weekly))
            end

            if #parts > 0 then
                panel.header:SetText("Resets: " .. table.concat(parts, ", "))
            else
                panel.header:SetText("Expiring soon")
            end

            for _, event in ipairs(opportunities.GetActiveEvents()) do
                table.insert(entries, {
                    text = "|cffffd100EVENT|r  " .. tostring(event.title),
                })
            end

            local worldQuests = opportunities.GetWorldQuests()

            for _, worldQuest in ipairs(worldQuests) do
                table.insert(entries, {
                    text = string.format("|cff33ff99WQ|r     %s  |cff999999%s%s|r",
                        tostring(worldQuest.name),
                        opportunities.FormatTimeLeft(worldQuest.secondsLeft),
                        worldQuest.tagName and (", " .. worldQuest.tagName) or ""),

                    tooltip = "Click to set a waypoint.",

                    onClick = function()
                        CN.NavigateToObjective({
                            id    = worldQuest.questID,
                            type  = CN.objectiveTypes.QUEST,
                            name  = worldQuest.name,
                            mapID = worldQuest.mapID,
                            x     = worldQuest.x,
                            y     = worldQuest.y,
                        })
                    end,
                })
            end
        else
            panel.header:SetText("Expiring soon")
        end

        local rares = CN:GetModule("Rares")

        if rares then
            for _, vignette in ipairs(rares.GetActive()) do
                table.insert(entries, {
                    text = string.format("|cffff8040%s|r  %s",
                        vignette.kind == "TREASURE" and "CHEST " or "RARE  ",
                        tostring(vignette.name)),

                    tooltip = "Up right now. Click to set a waypoint.",

                    onClick = function()
                        CN.NavigateToObjective({
                            id    = vignette.vignetteID,
                            type  = vignette.kind == "TREASURE"
                                and CN.objectiveTypes.TREASURE
                                or CN.objectiveTypes.RARE,
                            name  = vignette.name,
                            mapID = vignette.mapID,
                            x     = vignette.x,
                            y     = vignette.y,
                        })
                    end,
                })
            end
        end

        local currencies = CN:GetModule("Currencies")

        if currencies then
            for _, currency in ipairs(currencies.Capped()) do
                table.insert(entries, {
                    text = "|cffff4444CAP|r    " .. tostring(currency.name)
                        .. " |cff999999" .. currency.quantity
                        .. " / " .. currency.maximum .. " -- spend it|r",
                })
            end

            for _, currency in ipairs(currencies.WeeklyUnfilled()) do
                table.insert(entries, {
                    text = "|cff999999WEEK|r   " .. tostring(currency.name)
                        .. " |cff999999" .. currency.remaining .. " left this week|r",
                })
            end
        end

        if #entries == 0 then
            table.insert(entries, { text = "Nothing is expiring nearby." })
            table.insert(entries, {
                text = "|cff999999World quests and rares only appear for your current map.|r",
            })
        end

        panel.list:SetEntries(entries)
    end,
}

------------------------------------------------------------
-- TAB: WARBAND
------------------------------------------------------------

UI.RegisterTab{
    name  = "Warband",
    order = 22,

    build = function(panel)
        panel.header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        panel.header:SetPoint("TOPLEFT", 8, -8)
        panel.header:SetPoint("TOPRIGHT", -8, -8)
        panel.header:SetJustifyH("LEFT")

        panel.list = CreateList(panel)
        panel.list:ClearAllPoints()
        panel.list:SetPoint("TOPLEFT", 4, -32)
        panel.list:SetPoint("BOTTOMRIGHT", -8, 38)

        panel.note = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
        panel.note:SetPoint("BOTTOMLEFT", 12, 12)
        panel.note:SetPoint("RIGHT", -12, 0)
        panel.note:SetJustifyH("LEFT")
    end,

    refresh = function(panel)
        local module = CN:GetModule("Warband")

        if not module then
            panel.header:SetText("Warband module not loaded.")
            panel.list:SetEntries({})
            return
        end

        local rows     = module.Roster()
        local coverage = module.Coverage()

        panel.header:SetText(string.format(
            "%d character%s  |cff999999combined: %d professions, %d recipes, %d titles|r",
            #rows, #rows == 1 and "" or "s",
            coverage.professions, coverage.recipes, coverage.titles))

        local entries = {}

        for _, row in ipairs(rows) do
            local marker = row.isCurrent and "|cff00ff00>|r " or "  "

            table.insert(entries, {
                text = marker .. row.key
                    .. string.format("  |cff999999%s %s%s|r",
                        tostring(row.level), tostring(row.class or "?"),
                        row.faction and (" " .. row.faction) or ""),

                tooltip = string.format(
                    "professions %d\nrecipes %d\ntitles %d\nreputations %d",
                    row.professions, row.recipes, row.titles, row.reputations),
            })

            table.insert(entries, {
                text = "      |cff999999professions " .. row.professions
                    .. ", recipes " .. row.recipes
                    .. ", titles " .. row.titles
                    .. ", reputations " .. row.reputations .. "|r",
            })
        end

        panel.list:SetEntries(entries)

        if #rows == 1 then
            panel.note:SetText("|cffffff00Only one character has been seen. "
                .. "Log in on your alts with the addon loaded to make these "
                .. "comparisons useful.|r")
        else
            panel.note:SetText("")
        end
    end,
}

------------------------------------------------------------
-- TAB: REMAINING
------------------------------------------------------------

UI.RegisterTab{
    name  = "Remaining",
    order = 27,

    build = function(panel)
        panel.header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        panel.header:SetPoint("TOPLEFT", 8, -8)
        panel.header:SetPoint("TOPRIGHT", -8, -8)
        panel.header:SetJustifyH("LEFT")

        panel.list = CreateList(panel)
        panel.list:ClearAllPoints()
        panel.list:SetPoint("TOPLEFT", 4, -32)
        panel.list:SetPoint("BOTTOMRIGHT", -8, 38)

        panel.refresh = AddButton(panel, "Refresh", 110, function()
            UI.Refresh()
        end)
        panel.refresh:SetPoint("BOTTOMLEFT", 8, 8)
    end,

    refresh = function(panel)
        local module = CN:GetModule("Breakdown")

        if not module then
            panel.header:SetText("Breakdown module not loaded.")
            panel.list:SetEntries({})
            return
        end

        panel.header:SetText("What is left, and why")

        local entries = {}

        for _, row in ipairs(module.Report()) do
            local headline

            if row.total and row.total > 0 then
                headline = string.format("|cffffd100%-14s|r %6d / %-6d  |cff999999%.1f%%|r",
                    row.name, row.collected or 0, row.total,
                    (row.collected or 0) / row.total * 100)
            else
                headline = string.format("|cffffd100%-14s|r %6d collected",
                    row.name, row.collected or 0)
            end

            table.insert(entries, {
                text    = headline,
                tooltip = row.unknownTotal
                    and ("No percentage is shown because " .. row.unknownTotal .. ".")
                    or nil,
            })

            if row.unknownTotal then
                table.insert(entries, {
                    text = "      |cff808080no percentage: " .. row.unknownTotal .. "|r",
                })
            end

            for _, reason in ipairs(row.reasons or {}) do
                table.insert(entries, { text = "      " .. reason })
            end

            if row.action then
                table.insert(entries, {
                    text = "      |cffffff00-> " .. row.action .. "|r",
                })
            end
        end

        if #entries == 0 then
            table.insert(entries, { text = "Nothing to report yet. Run the scans first." })
        end

        panel.list:SetEntries(entries)
    end,
}

------------------------------------------------------------
-- TAB: COLLECTIONS
------------------------------------------------------------

-- The account dashboard. Every row is "collected / known", never a
-- fabricated percentage of some total the addon cannot verify.
UI.RegisterTab{
    name  = "Collections",
    order = 25,

    build = function(panel)
        panel.header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        panel.header:SetPoint("TOPLEFT", 8, -8)
        panel.header:SetPoint("TOPRIGHT", -8, -8)
        panel.header:SetJustifyH("LEFT")

        panel.list = CreateList(panel)
        panel.list:ClearAllPoints()
        panel.list:SetPoint("TOPLEFT", 4, -32)
        panel.list:SetPoint("BOTTOMRIGHT", -8, 38)

        panel.scanAll = AddButton(panel, "Scan everything", 140, function()
            Print("Scanning all collections; this takes a moment.")

            for _, moduleName in ipairs({ "Pets", "Mounts", "Toys", "Appearances",
                                          "Titles", "Professions" }) do
                local module = CN:GetModule(moduleName)

                if module and module.Scan then
                    pcall(module.Scan)
                end
            end

            Print("Collection scan complete.")
            UI.Refresh()
        end)
        panel.scanAll:SetPoint("BOTTOMLEFT", 8, 8)

        panel.achieve = AddButton(panel, "Scan achievements", 150, function()
            local module = CN:GetModule("Achievements")

            if module then
                Print("Scanning achievements; this takes a moment.")

                local scanned, completed = module.Scan()

                Print("Scanned " .. scanned .. ", completed " .. completed .. ".")
            end

            UI.Refresh()
        end)
        panel.achieve:SetPoint("LEFT", panel.scanAll, "RIGHT", 6, 0)
    end,

    refresh = function(panel)
        local entries = {}

        local function row(label, collected, total, note)
            local text

            if total and total > 0 then
                text = string.format("%-16s %6d / %-6d  |cff999999%.1f%%|r",
                    label, collected, total, collected / total * 100)
            else
                text = string.format("%-16s %6s        |cff999999%s|r",
                    label, "-", note or "not scanned")
            end

            table.insert(entries, { text = text })
        end

        local pets = CN:GetModule("Pets")

        if pets then
            local counts = pets.Summary()
            row("Pets", counts.collected, counts.known)
        end

        local mounts = CN:GetModule("Mounts")

        if mounts then
            local counts = mounts.Summary()
            row("Mounts", counts.collected, counts.known)
        end

        local toys = CN:GetModule("Toys")

        if toys then
            local counts = toys.Summary()
            row("Toys", counts.collected, counts.known)
        end

        local appearances = CN:GetModule("Appearances")

        if appearances then
            local counts = appearances.Summary()
            row("Appearances", counts.collected, counts.total)
        end

        local titles = CN:GetModule("Titles")

        if titles then
            local counts = titles.Summary()
            row("Titles", counts.onAccount, counts.known)
        end

        local achievements = CN:GetModule("Achievements")

        if achievements then
            local counts = achievements.Summary()
            row("Achievements", counts.completed, counts.total)
        end

        local reputations = CN:GetModule("Reputations")

        if reputations then
            local counts = reputations.Summary()

            table.insert(entries, {
                text = string.format("%-16s %6d account-wide, %d character-specific",
                    "Reputations", counts.account, counts.character),
            })
        end

        table.insert(entries, { text = " " })

        local quests = CN:GetModule("Quests")

        if quests then
            table.insert(entries, {
                text = string.format("%-16s %6d discovered",
                    "Quests", CN.CountKeys(CN.Account("discoveredQuests"))),
            })
        end

        local professions = CN:GetModule("Professions")

        if professions then
            for _, record in ipairs(professions.Summary()) do
                local note = record.recipesSeen
                    and (record.recipeKnown .. " of " .. record.recipeTotal .. " recipes")
                    or "|cffffff00open its window once|r"

                table.insert(entries, {
                    text = string.format("%-16s %6s / %-6s  |cff999999%s|r",
                        record.name or "?", tostring(record.rank),
                        tostring(record.maxRank), note),
                })
            end

            local waiting = professions.AwaitingRecipeCapture()

            if #waiting > 0 then
                table.insert(entries, { text = " " })
                table.insert(entries, {
                    text = "|cffffff00Recipes need the profession window open: "
                        .. table.concat(waiting, ", ") .. "|r",
                    tooltip = "The client only exposes a recipe list while that "
                        .. "profession's window is open. Open each one once and "
                        .. "the addon captures it automatically.",
                })
            end
        end

        panel.header:SetText("Account completion  |cff999999(collected / known)|r")
        panel.list:SetEntries(entries)
    end,
}

------------------------------------------------------------
-- TAB: SETTINGS
------------------------------------------------------------

UI.RegisterTab{
    name  = "Settings",
    order = 40,

    build = function(panel)
        panel.modeLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        panel.modeLabel:SetPoint("TOPLEFT", 8, -12)

        -- A cycling button instead of a dropdown: dropdown templates have
        -- been renamed twice in recent expansions, this has not.
        panel.modeButton = AddButton(panel, "balanced", 160, function()
            local settings = CN.Settings()
            local modes    = CN.priorityModes

            local currentIndex = 1

            for index, mode in ipairs(modes) do
                if mode == settings.priorityMode then
                    currentIndex = index
                    break
                end
            end

            settings.priorityMode = modes[(currentIndex % #modes) + 1]

            UI.Refresh()
        end)
        panel.modeButton:SetPoint("TOPLEFT", panel.modeLabel, "BOTTOMLEFT", 0, -6)

        panel.modeHelp = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
        panel.modeHelp:SetPoint("LEFT", panel.modeButton, "RIGHT", 8, 0)
        panel.modeHelp:SetText("Click to cycle")

        panel.debug = AddCheckbox(panel, "Debug output",
            function() return CN.Settings().debug end,
            function(value) CN.Settings().debug = value end)
        panel.debug:SetPoint("TOPLEFT", panel.modeButton, "BOTTOMLEFT", 0, -16)

        panel.auto = AddCheckbox(panel, "Auto-advance waypoint as I finish things",
            function() return CN.IsAutoWaypointEnabled() end,
            function(value)
                CN.Settings().autoWaypoint = value

                if value then
                    CN.StartAutoWaypointTicker()
                    CN.AutoAdvance("settings", true)
                else
                    CN.StopAutoWaypointTicker()
                end
            end)
        panel.auto:SetPoint("TOPLEFT", panel.debug, "BOTTOMLEFT", 0, -6)

        panel.minimap = AddCheckbox(panel, "Show minimap button",
            function() return not CN.Settings().minimap.hide end,
            function(value)
                CN.Settings().minimap.hide = not value
                UI.UpdateMinimapButton()
            end)
        panel.minimap:SetPoint("TOPLEFT", panel.auto, "BOTTOMLEFT", 0, -6)

        panel.reset = AddButton(panel, "Reset window position", 180, function()
            CN.Settings().window = nil

            if window then
                window:ClearAllPoints()
                window:SetPoint("CENTER")
            end
        end)
        panel.reset:SetPoint("BOTTOMLEFT", 8, 8)

        panel.about = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
        panel.about:SetPoint("BOTTOMRIGHT", -8, 14)
    end,

    refresh = function(panel)
        local settings = CN.Settings()

        panel.modeLabel:SetText("Priority mode")
        panel.modeButton:SetText(tostring(settings.priorityMode))

        panel.debug.Refresh()
        panel.auto.Refresh()
        panel.minimap.Refresh()

        panel.about:SetText("Completion Navigator v" .. CN.version)
    end,
}

------------------------------------------------------------
-- MINIMAP BUTTON
------------------------------------------------------------

local function UpdateMinimapPosition()
    if not minimapButton then
        return
    end

    local angle  = math.rad(CN.Settings().minimap.angle or 225)
    local radius = 80

    minimapButton:SetPoint("CENTER", Minimap, "CENTER",
        math.cos(angle) * radius, math.sin(angle) * radius)
end

local function BuildMinimapButton()
    if minimapButton or not Minimap then
        return minimapButton
    end

    minimapButton = CreateFrame("Button", "CompletionNavigatorMinimapButton", Minimap)

    minimapButton:SetSize(31, 31)
    minimapButton:SetFrameStrata("MEDIUM")
    minimapButton:SetFrameLevel(8)
    minimapButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    minimapButton:RegisterForDrag("LeftButton")
    minimapButton:SetMovable(true)

    local overlay = minimapButton:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT")

    local icon = minimapButton:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", -1, 1)

    -- Prefer the addon's own artwork. SetTexture fails silently on a missing
    -- file and leaves the texture blank, so verify it took and fall back to
    -- a stock icon rather than shipping an invisible button.
    icon:SetTexture(CN.MEDIA_PATH .. "Logo")

    if not icon:GetTexture() then
        icon:SetTexture("Interface\\Icons\\INV_Misc_Map_01")
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    else
        -- The supplied art is a circular badge already; trimming the corners
        -- keeps it round inside the minimap ring.
        icon:SetTexCoord(0.06, 0.94, 0.06, 0.94)
    end

    minimapButton:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            local results = CN.Recommend(1)

            if #results > 0 then
                CN.currentRecommendation = results[1]

                local objective = results[1]

                Print("Recommended: " .. tostring(objective.name))
                CN.NavigateToObjective(objective)
            else
                Print("Nothing actionable is known yet.")
            end

            return
        end

        UI.Toggle()
    end)

    -- Drag around the minimap edge; the angle is what gets persisted.
    minimapButton:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local px, py = GetCursorPosition()
            local scale  = Minimap:GetEffectiveScale()

            px, py = px / scale, py / scale

            CN.Settings().minimap.angle = math.deg(math.atan(py - my, px - mx))

            UpdateMinimapPosition()
        end)
    end)

    minimapButton:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    minimapButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Completion Navigator")
        GameTooltip:AddLine("|cffffffffLeft-click|r open the window", 1, 1, 1)
        GameTooltip:AddLine("|cffffffffRight-click|r navigate to the next objective", 1, 1, 1)
        GameTooltip:AddLine("|cffffffffDrag|r reposition this button", 1, 1, 1)
        GameTooltip:Show()
    end)

    minimapButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    UpdateMinimapPosition()

    return minimapButton
end

function UI.UpdateMinimapButton()
    BuildMinimapButton()

    if not minimapButton then
        return
    end

    if CN.Settings().minimap.hide then
        minimapButton:Hide()
    else
        minimapButton:Show()
        UpdateMinimapPosition()
    end
end

------------------------------------------------------------
-- KEYBINDING ENTRY POINTS
------------------------------------------------------------

function CompletionNavigator_ToggleUI()
    UI.Toggle()
end

function CompletionNavigator_NextObjective()
    local handler = SlashCmdList and SlashCmdList.COMPLETIONNAVIGATOR

    if handler then
        handler("next")
    end
end

function CompletionNavigator_Navigate()
    local handler = SlashCmdList and SlashCmdList.COMPLETIONNAVIGATOR

    if handler then
        handler("go")
    end
end

BINDING_HEADER_COMPLETIONNAVIGATOR       = "Completion Navigator"
BINDING_NAME_COMPLETIONNAVIGATOR_TOGGLE  = "Toggle window"
BINDING_NAME_COMPLETIONNAVIGATOR_NEXT    = "Recommend next objective"
BINDING_NAME_COMPLETIONNAVIGATOR_GO      = "Navigate to recommendation"

------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------

CN:OnLogin(function()
    UI.UpdateMinimapButton()

    -- Say once where the interface actually is. A minimap button nobody
    -- notices is the same as no interface at all.
    local settings = CN.Settings()

    if not settings.seenWelcome then
        settings.seenWelcome = true

        Print("Click the |cffffff00map icon on your minimap|r to open the window, "
            .. "or type |cffffff00/cn ui|r.")
        Print("Right-click that icon to navigate straight to the next objective.")
    end
end)

-- Keep an open window current without polling.
for _, event in ipairs({
    "QUEST_TURNED_IN",
    "QUEST_ACCEPTED",
    "QUEST_REMOVED",
    "UPDATE_FACTION",
    "ZONE_CHANGED_NEW_AREA",
    "MAJOR_FACTION_RENOWN_LEVEL_CHANGED",
}) do
    CN:RegisterEvent(event, function()
        UI.RequestRefresh()
    end)
end

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "ui",
    aliases = { "show", "window" },
    order   = 5,
    help    = "Open the main window.",
    handler = function()
        UI.Toggle()
    end,
}

CN:RegisterCommand{
    name    = "uistatus",
    order   = 7,
    help    = "Diagnose the window and minimap button.",
    handler = function()
        Print("UI diagnostics:")
        Print("Window object: " .. (CompletionNavigatorFrame and "created" or "|cffff4444not created|r"))

        if CompletionNavigatorFrame then
            Print("  shown: " .. tostring(CompletionNavigatorFrame:IsShown()))
            Print("  size: " .. math.floor(CompletionNavigatorFrame:GetWidth() or 0)
                .. " x " .. math.floor(CompletionNavigatorFrame:GetHeight() or 0))
            Print("  strata: " .. tostring(CompletionNavigatorFrame:GetFrameStrata()))

            local point, _, _, x, y = CompletionNavigatorFrame:GetPoint()

            Print("  anchored: " .. tostring(point)
                .. " at " .. math.floor(x or 0) .. ", " .. math.floor(y or 0))
        end

        Print("Minimap button: "
            .. (CompletionNavigatorMinimapButton and "created" or "|cffff4444not created|r"))

        if CompletionNavigatorMinimapButton then
            Print("  shown: " .. tostring(CompletionNavigatorMinimapButton:IsShown()))
            Print("  hidden by setting: " .. tostring(CN.Settings().minimap.hide))
            Print("  angle: " .. tostring(CN.Settings().minimap.angle))
        end

        Print("Registered tabs: " .. #UI.tabs)
        Print("Minimap frame exists: " .. tostring(Minimap ~= nil))

        if CompletionNavigatorFrame and not CompletionNavigatorFrame:IsShown() then
            Print("Forcing the window open and centering it.")

            CN.Settings().window = nil

            CompletionNavigatorFrame:ClearAllPoints()
            CompletionNavigatorFrame:SetPoint("CENTER")
            CompletionNavigatorFrame:Show()
        end
    end,
}

CN:RegisterCommand{
    name    = "minimap",
    order   = 6,
    help    = "Toggle the minimap button.",
    handler = function()
        local settings = CN.Settings()

        settings.minimap.hide = not settings.minimap.hide

        UI.UpdateMinimapButton()

        Print("Minimap button " .. (settings.minimap.hide and "hidden." or "shown."))
    end,
}
'@

$Embedded['Data\Quests.lua'] = @'
-- Data/Quests.lua
-- Completion Navigator :: curated static quest data.
--
-- Blizzard does not reliably return metadata for historical quests, so
-- anything the client cannot answer lives here. Keys are quest IDs.
--
-- Fields:
--   name       (string)  quest title
--   mapID      (number)  UiMapID the quest is picked up or completed in
--   x, y       (number)  0-1 normalized map coordinates
--   expansion  (string)  short expansion tag
--   requires   (table)   array of prerequisite quest IDs
--   unlocks    (table)   array of quest IDs this one opens
--   breadcrumb (boolean) skippable and permanently missable
--   obsolete   (boolean) no longer obtainable
--
-- Add rows with:  .\cn.ps1 data quest <id> -Name "<title>"

local ADDON_NAME, CN = ...

CN.Static.RegisterQuests({

    [8237] = {
        name      = "Vanquish the Invaders!",
        expansion = "Classic",
    },

    -- CN:DATA:QUESTS -- new rows are inserted above this marker.
})
'@

$Embedded['Providers\Blizzard.lua'] = @'
-- Providers/Blizzard.lua
-- Completion Navigator :: thin, defensive wrappers over Blizzard APIs.
--
-- Every call into the client goes through here. Blizzard renames and
-- removes APIs between patches; keeping the surface area in one file means
-- a patch break is a one-file fix rather than a hunt.

local ADDON_NAME, CN = ...

local Blizzard = {}

CN.Blizzard = Blizzard

------------------------------------------------------------
-- QUESTS
------------------------------------------------------------

function Blizzard.IsQuestCompletedByCharacter(questID)
    if not questID then
        return false
    end

    if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted then
        return C_QuestLog.IsQuestFlaggedCompleted(questID) and true or false
    end

    return false
end

function Blizzard.HasAccountQuestAPI()
    return (C_QuestLog and C_QuestLog.IsQuestFlaggedCompletedOnAccount) and true or false
end

function Blizzard.IsQuestCompletedOnAccount(questID)
    if not questID then
        return false
    end

    if C_QuestLog and C_QuestLog.IsQuestFlaggedCompletedOnAccount then
        return C_QuestLog.IsQuestFlaggedCompletedOnAccount(questID) and true or false
    end

    return false
end

-- Returns a title if the client already has it cached. Otherwise requests
-- an asynchronous load and returns nil; QUEST_DATA_LOAD_RESULT follows.
function Blizzard.GetQuestTitle(questID, requestIfMissing)
    if not questID then
        return nil
    end

    if C_QuestLog and C_QuestLog.GetTitleForQuestID then
        local title = C_QuestLog.GetTitleForQuestID(questID)

        if title and title ~= "" then
            return title
        end
    end

    if requestIfMissing and C_QuestLog and C_QuestLog.RequestLoadQuestByID then
        CN.pendingQuestLoads = CN.pendingQuestLoads or {}
        CN.pendingQuestLoads[questID] = true

        C_QuestLog.RequestLoadQuestByID(questID)
    end

    return nil
end

function Blizzard.GetQuestLogEntries()
    local entries = {}

    if not C_QuestLog or not C_QuestLog.GetNumQuestLogEntries then
        return entries
    end

    local count = C_QuestLog.GetNumQuestLogEntries()

    for index = 1, count do
        local info = C_QuestLog.GetInfo(index)

        if info and not info.isHeader and info.questID and info.questID > 0 then
            table.insert(entries, info)
        end
    end

    return entries
end

-- Scans the map's quest POIs for one quest. This is the source that
-- actually covers ordinary quests; GetNextWaypoint only answers for quests
-- Blizzard has given an explicit waypoint.
function Blizzard.GetQuestPOIOnMap(questID, uiMapID)
    if not questID or not uiMapID or not C_QuestLog or not C_QuestLog.GetQuestsOnMap then
        return nil, nil
    end

    local ok, quests = pcall(C_QuestLog.GetQuestsOnMap, uiMapID)

    if not ok or type(quests) ~= "table" then
        return nil, nil
    end

    for _, info in ipairs(quests) do
        if info.questID == questID and info.x and info.y then
            return info.x, info.y
        end
    end

    return nil, nil
end

-- Returns mapID, x, y for the next thing the player must physically do for
-- this quest, trying every source the client exposes before giving up.
function Blizzard.GetQuestWaypoint(questID, preferredMapID)
    if not questID then
        return nil, nil, nil
    end

    -- 1. An explicit waypoint, if the quest has one.
    if C_QuestLog and C_QuestLog.GetNextWaypoint then
        local mapID, x, y = C_QuestLog.GetNextWaypoint(questID)

        if mapID and x and y then
            return mapID, x, y
        end
    end

    local playerMap = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")

    local candidateMaps = {}

    if preferredMapID then
        table.insert(candidateMaps, preferredMapID)
    end

    if playerMap and playerMap ~= preferredMapID then
        table.insert(candidateMaps, playerMap)
    end

    local zoneMap = Blizzard.GetQuestZone(questID)

    if zoneMap and zoneMap ~= playerMap and zoneMap ~= preferredMapID then
        table.insert(candidateMaps, zoneMap)
    end

    for _, mapID in ipairs(candidateMaps) do
        -- 2. The quest's next waypoint expressed on this specific map.
        if C_QuestLog and C_QuestLog.GetNextWaypointForMap then
            local x, y = C_QuestLog.GetNextWaypointForMap(questID, mapID)

            if x and y then
                return mapID, x, y
            end
        end

        -- 3. The quest's POI blip on this map.
        local x, y = Blizzard.GetQuestPOIOnMap(questID, mapID)

        if x and y then
            return mapID, x, y
        end

        -- 4. World-quest style task location.
        if C_TaskQuest and C_TaskQuest.GetQuestLocation then
            local taskX, taskY = C_TaskQuest.GetQuestLocation(questID, mapID)

            if taskX and taskY then
                return mapID, taskX, taskY
            end
        end
    end

    return zoneMap or playerMap, nil, nil
end

-- Blizzard's own quest tracking arrow. The correct answer when we have no
-- coordinates but the game does: it knows where its own quests are.
function Blizzard.SuperTrackQuest(questID)
    if not questID or not C_SuperTrack then
        return false
    end

    if C_SuperTrack.SetSuperTrackedQuestID then
        C_SuperTrack.SetSuperTrackedQuestID(questID)
        return true
    end

    return false
end

function Blizzard.IsQuestInLog(questID)
    if not questID or not C_QuestLog or not C_QuestLog.GetLogIndexForQuestID then
        return false
    end

    return C_QuestLog.GetLogIndexForQuestID(questID) ~= nil
end

function Blizzard.IsQuestReadyForTurnIn(questID)
    if C_QuestLog and C_QuestLog.ReadyForTurnIn then
        return C_QuestLog.ReadyForTurnIn(questID) and true or false
    end

    return false
end

function Blizzard.IsQuestComplete(questID)
    if C_QuestLog and C_QuestLog.IsComplete then
        return C_QuestLog.IsComplete(questID) and true or false
    end

    return false
end

-- Returns completed, total for a quest's objectives.
function Blizzard.GetQuestObjectiveProgress(questID)
    if not C_QuestLog or not C_QuestLog.GetQuestObjectives then
        return 0, 0
    end

    local objectives = C_QuestLog.GetQuestObjectives(questID)

    if not objectives then
        return 0, 0
    end

    local done, total = 0, 0

    for _, objective in ipairs(objectives) do
        total = total + 1

        if objective.finished then
            done = done + 1
        end
    end

    return done, total
end

function Blizzard.GetQuestZone(questID)
    if C_TaskQuest and C_TaskQuest.GetQuestZoneID then
        local mapID = C_TaskQuest.GetQuestZoneID(questID)

        if mapID then
            return mapID
        end
    end

    if C_QuestLog and C_QuestLog.GetQuestAdditionalHighlights then
        local mapID = C_QuestLog.GetQuestAdditionalHighlights(questID)

        if mapID then
            return mapID
        end
    end

    return nil
end

------------------------------------------------------------
-- REPUTATION
------------------------------------------------------------

-- Retail moved everything to C_Reputation / C_MajorFactions in 11.0.
-- GetFactionInfoByID is gone; never reintroduce it.

function Blizzard.GetNumFactions()
    if C_Reputation and C_Reputation.GetNumFactions then
        return C_Reputation.GetNumFactions()
    end

    return 0
end

function Blizzard.GetFactionByIndex(index)
    if C_Reputation and C_Reputation.GetFactionDataByIndex then
        return C_Reputation.GetFactionDataByIndex(index)
    end

    return nil
end

function Blizzard.GetFactionByID(factionID)
    if C_Reputation and C_Reputation.GetFactionDataByID then
        return C_Reputation.GetFactionDataByID(factionID)
    end

    return nil
end

-- True when the standing is shared across the Warband rather than earned
-- per character. This is the single most important flag for deciding
-- which character should do reputation work.
function Blizzard.IsAccountWideReputation(factionID)
    if C_Reputation and C_Reputation.IsAccountWideReputation then
        return C_Reputation.IsAccountWideReputation(factionID) and true or false
    end

    return false
end

function Blizzard.IsMajorFaction(factionID)
    if C_Reputation and C_Reputation.IsMajorFaction then
        return C_Reputation.IsMajorFaction(factionID) and true or false
    end

    return false
end

function Blizzard.GetMajorFactionData(factionID)
    if C_MajorFactions and C_MajorFactions.GetMajorFactionData then
        return C_MajorFactions.GetMajorFactionData(factionID)
    end

    return nil
end

function Blizzard.HasMaximumRenown(factionID)
    if C_MajorFactions and C_MajorFactions.HasMaximumRenown then
        return C_MajorFactions.HasMaximumRenown(factionID) and true or false
    end

    return false
end

function Blizzard.IsFactionParagon(factionID)
    if C_Reputation and C_Reputation.IsFactionParagon then
        return C_Reputation.IsFactionParagon(factionID) and true or false
    end

    return false
end

-- Returns currentValue, threshold, rewardQuestID, hasRewardPending.
function Blizzard.GetParagonInfo(factionID)
    if C_Reputation and C_Reputation.GetFactionParagonInfo then
        return C_Reputation.GetFactionParagonInfo(factionID)
    end

    return nil
end

-- Friendship-style reputations (Brann, tenders, and similar) do not use
-- the standard 1-8 reaction scale.
function Blizzard.GetFriendshipReputation(factionID)
    if C_GossipInfo and C_GossipInfo.GetFriendshipReputation then
        local info = C_GossipInfo.GetFriendshipReputation(factionID)

        if info and info.friendshipFactionID and info.friendshipFactionID > 0 then
            return info
        end
    end

    return nil
end

function Blizzard.GetStandingLabel(reaction)
    if not reaction then
        return "Unknown"
    end

    return _G["FACTION_STANDING_LABEL" .. reaction] or ("Standing " .. reaction)
end

-- The faction list only reports rows whose headers are expanded, so a
-- complete scan has to expand everything and then put it back.
function Blizzard.WithAllFactionsExpanded(scan)
    local collapsed = {}

    if C_Reputation and C_Reputation.GetNumFactions then
        for index = C_Reputation.GetNumFactions(), 1, -1 do
            local data = Blizzard.GetFactionByIndex(index)

            if data and data.isCollapsed then
                collapsed[data.factionID or index] = true
            end
        end
    end

    if C_Reputation and C_Reputation.ExpandAllFactionHeaders then
        C_Reputation.ExpandAllFactionHeaders()
    end

    local ok, err = pcall(scan)

    if C_Reputation and C_Reputation.CollapseFactionHeader then
        for index = Blizzard.GetNumFactions(), 1, -1 do
            local data = Blizzard.GetFactionByIndex(index)

            if data and data.factionID and collapsed[data.factionID] then
                C_Reputation.CollapseFactionHeader(index)
            end
        end
    end

    if not ok then
        error(err, 0)
    end
end

------------------------------------------------------------
-- CHARACTER
------------------------------------------------------------

function Blizzard.GetProfessions()
    local result = {}

    if not GetProfessions then
        return result
    end

    -- GetProfessions returns nil for any slot the character lacks, and
    -- ipairs stops at the first nil. A character without Archaeology would
    -- silently lose Fishing and Cooking. Index the slots explicitly.
    local slots = { GetProfessions() }

    for slot = 1, 5 do
        local index = slots[slot]

        if index then
            local name, _, rank, maxRank, _, _, skillLineID = GetProfessionInfo(index)

            if name then
                table.insert(result, {
                    name        = name,
                    rank        = rank,
                    maxRank     = maxRank,
                    skillLineID = skillLineID,
                })
            end
        end
    end

    return result
end

------------------------------------------------------------
-- MAP
------------------------------------------------------------

function Blizzard.GetMapName(mapID)
    if not mapID or not C_Map or not C_Map.GetMapInfo then
        return nil
    end

    local info = C_Map.GetMapInfo(mapID)

    return info and info.name or nil
end

------------------------------------------------------------
-- BATTLE PETS
------------------------------------------------------------

-- The pet journal reports only what the player's current filters allow, so
-- any complete scan must widen the filters and then put them back.
function Blizzard.WithAllPetsShown(scan)
    if not C_PetJournal then
        return
    end

    local search = C_PetJournal.GetSearchFilter and C_PetJournal.GetSearchFilter() or ""

    if C_PetJournal.SetSearchFilter then
        C_PetJournal.SetSearchFilter("")
    end

    if C_PetJournal.SetAllPetSourcesChecked then
        C_PetJournal.SetAllPetSourcesChecked(true)
    end

    if C_PetJournal.SetAllPetTypesChecked then
        C_PetJournal.SetAllPetTypesChecked(true)
    end

    if C_PetJournal.SetFilterChecked and LE_PET_JOURNAL_FILTER_COLLECTED then
        C_PetJournal.SetFilterChecked(LE_PET_JOURNAL_FILTER_COLLECTED, true)
        C_PetJournal.SetFilterChecked(LE_PET_JOURNAL_FILTER_NOT_COLLECTED, true)
    end

    local ok, err = pcall(scan)

    if C_PetJournal.SetSearchFilter and search ~= "" then
        C_PetJournal.SetSearchFilter(search)
    end

    if not ok then
        error(err, 0)
    end
end

function Blizzard.GetNumPets()
    if C_PetJournal and C_PetJournal.GetNumPets then
        return C_PetJournal.GetNumPets()
    end

    return 0, 0
end

function Blizzard.GetPetByIndex(index)
    if not C_PetJournal or not C_PetJournal.GetPetInfoByIndex then
        return nil
    end

    local petID, speciesID, owned, customName, level, favorite, isRevoked,
          speciesName, icon, petType, companionID, tooltip, description,
          isWild, canBattle, isTradeable, isUnique, obtainable =
          C_PetJournal.GetPetInfoByIndex(index)

    if not speciesID then
        return nil
    end

    return {
        petID       = petID,
        speciesID   = speciesID,
        owned       = owned and true or false,
        level       = level,
        favorite    = favorite and true or false,
        name        = speciesName,
        icon        = icon,
        petType     = petType,
        isWild      = isWild and true or false,
        canBattle   = canBattle and true or false,
        obtainable  = obtainable ~= false,
        description = description,
    }
end

function Blizzard.GetPetCollectedCount(speciesID)
    if C_PetJournal and C_PetJournal.GetNumCollectedInfo then
        return C_PetJournal.GetNumCollectedInfo(speciesID)
    end

    return 0, 0
end

------------------------------------------------------------
-- MOUNTS
------------------------------------------------------------

function Blizzard.GetMountIDs()
    if C_MountJournal and C_MountJournal.GetMountIDs then
        return C_MountJournal.GetMountIDs()
    end

    return {}
end

function Blizzard.GetMountByID(mountID)
    if not C_MountJournal or not C_MountJournal.GetMountInfoByID then
        return nil
    end

    local name, spellID, icon, isActive, isUsable, sourceType, isFavorite,
          isFactionSpecific, faction, shouldHideOnChar, isCollected =
          C_MountJournal.GetMountInfoByID(mountID)

    if not name then
        return nil
    end

    local source, description

    if C_MountJournal.GetMountInfoExtraByID then
        local _, extraDescription, extraSource = C_MountJournal.GetMountInfoExtraByID(mountID)

        description = extraDescription
        source      = extraSource
    end

    return {
        mountID           = mountID,
        name              = name,
        spellID           = spellID,
        icon              = icon,
        sourceType        = sourceType,
        isFactionSpecific = isFactionSpecific and true or false,
        faction           = faction,
        hiddenOnCharacter = shouldHideOnChar and true or false,
        isCollected       = isCollected and true or false,
        source            = source,
        description       = description,
    }
end

------------------------------------------------------------
-- TOYS
------------------------------------------------------------

-- Same filter problem as the pet journal.
function Blizzard.WithAllToysShown(scan)
    if not C_ToyBox then
        return
    end

    if C_ToyBox.SetFilterString then
        C_ToyBox.SetFilterString("")
    end

    if C_ToyBox.SetCollectedShown then
        C_ToyBox.SetCollectedShown(true)
    end

    if C_ToyBox.SetUncollectedShown then
        C_ToyBox.SetUncollectedShown(true)
    end

    if C_ToyBox.SetAllSourceTypeFilters then
        C_ToyBox.SetAllSourceTypeFilters(true)
    end

    local ok, err = pcall(scan)

    if not ok then
        error(err, 0)
    end
end

function Blizzard.GetNumToys()
    if C_ToyBox and C_ToyBox.GetNumFilteredToys then
        return C_ToyBox.GetNumFilteredToys()
    end

    if C_ToyBox and C_ToyBox.GetNumToys then
        return C_ToyBox.GetNumToys()
    end

    return 0
end

function Blizzard.GetToyByIndex(index)
    if not C_ToyBox or not C_ToyBox.GetToyFromIndex then
        return nil
    end

    local itemID = C_ToyBox.GetToyFromIndex(index)

    if not itemID or itemID == 0 then
        return nil
    end

    local _, name, icon = C_ToyBox.GetToyInfo(itemID)

    return {
        itemID    = itemID,
        name      = name,
        icon      = icon,
        collected = PlayerHasToy and PlayerHasToy(itemID) and true or false,
    }
end

------------------------------------------------------------
-- APPEARANCES (TRANSMOG)
------------------------------------------------------------

-- Appearance counts are reported per category. Individual appearance
-- enumeration is enormous; the per-category totals are what a completion
-- dashboard actually needs.
function Blizzard.GetAppearanceCategories()
    local categories = {}

    if not C_TransmogCollection then
        return categories
    end

    local names = C_TransmogCollection.GetCategoryInfo
        and Enum and Enum.TransmogCollectionType

    if not names then
        return categories
    end

    for _, categoryID in pairs(Enum.TransmogCollectionType) do
        if type(categoryID) == "number" then
            local name = C_TransmogCollection.GetCategoryInfo(categoryID)

            if name then
                local collected = C_TransmogCollection.GetCategoryCollectedCount
                    and C_TransmogCollection.GetCategoryCollectedCount(categoryID) or 0

                local total = C_TransmogCollection.GetCategoryTotal
                    and C_TransmogCollection.GetCategoryTotal(categoryID) or 0

                if total and total > 0 then
                    table.insert(categories, {
                        categoryID = categoryID,
                        name       = name,
                        collected  = collected,
                        total      = total,
                    })
                end
            end
        end
    end

    table.sort(categories, function(a, b) return a.name < b.name end)

    return categories
end

------------------------------------------------------------
-- TITLES
------------------------------------------------------------

function Blizzard.GetTitles()
    local titles = {}

    if not GetNumTitles then
        return titles
    end

    for index = 1, GetNumTitles() do
        local name = GetTitleName and GetTitleName(index)

        if name and name ~= "" then
            table.insert(titles, {
                titleID = index,
                name    = (name:gsub("^%s+", ""):gsub("%s+$", "")),
                known   = IsTitleKnown and IsTitleKnown(index) and true or false,
            })
        end
    end

    return titles
end

------------------------------------------------------------
-- ACHIEVEMENTS
------------------------------------------------------------

function Blizzard.GetAchievementCategories()
    if GetCategoryList then
        return GetCategoryList()
    end

    return {}
end

function Blizzard.GetCategoryCounts(categoryID)
    if not GetCategoryNumAchievements then
        return 0, 0
    end

    local total, completed = GetCategoryNumAchievements(categoryID, true)

    return total or 0, completed or 0
end

function Blizzard.GetAchievementInCategory(categoryID, index)
    if not GetAchievementInfo then
        return nil
    end

    local id, name, points, completed, _, _, _, description, flags, icon =
        GetAchievementInfo(categoryID, index)

    if not id then
        return nil
    end

    return {
        achievementID = id,
        name          = name,
        points        = points or 0,
        completed     = completed and true or false,
        description   = description,
        icon          = icon,
        flags         = flags,
    }
end

-- Returns completedCriteria, totalCriteria for one achievement.
function Blizzard.GetAchievementProgress(achievementID)
    if not GetAchievementNumCriteria or not GetAchievementCriteriaInfo then
        return 0, 0
    end

    local total = GetAchievementNumCriteria(achievementID) or 0
    local done  = 0

    for index = 1, total do
        local _, _, criteriaCompleted = GetAchievementCriteriaInfo(achievementID, index)

        if criteriaCompleted then
            done = done + 1
        end
    end

    return done, total
end

function Blizzard.GetAchievementTotals()
    if GetNumCompletedAchievements then
        local total, completed = GetNumCompletedAchievements(true)
        return total or 0, completed or 0
    end

    return 0, 0
end

------------------------------------------------------------
-- PROFESSIONS AND RECIPES
------------------------------------------------------------

function Blizzard.GetProfessionSkillLines()
    local lines = {}

    if not GetProfessions then
        return lines
    end

    -- Same nil-hole problem as above: index the five slots explicitly
    -- rather than iterating, or missing professions truncate the list.
    local slots = { GetProfessions() }

    for slot = 1, 5 do
        local index = slots[slot]

        if index then
            local name, _, rank, maxRank, _, _, skillLineID, _, _, _ = GetProfessionInfo(index)

            if name and skillLineID then
                table.insert(lines, {
                    name        = name,
                    rank        = rank,
                    maxRank     = maxRank,
                    skillLineID = skillLineID,
                })
            end
        end
    end

    return lines
end

-- Recipe enumeration only works while a trade skill window is open. This
-- is a hard client restriction, not a choice; callers must handle false.
function Blizzard.IsTradeSkillReady()
    if C_TradeSkillUI and C_TradeSkillUI.IsTradeSkillReady then
        return C_TradeSkillUI.IsTradeSkillReady() and true or false
    end

    return false
end

function Blizzard.GetOpenTradeSkillLine()
    if C_TradeSkillUI and C_TradeSkillUI.GetBaseProfessionInfo then
        local info = C_TradeSkillUI.GetBaseProfessionInfo()

        if info and info.professionID then
            return info.professionID, info.professionName
        end
    end

    if C_TradeSkillUI and C_TradeSkillUI.GetTradeSkillLine then
        return C_TradeSkillUI.GetTradeSkillLine()
    end

    return nil, nil
end

function Blizzard.GetAllRecipeIDs()
    if C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs then
        local ok, ids = pcall(C_TradeSkillUI.GetAllRecipeIDs)

        if ok and type(ids) == "table" then
            return ids
        end
    end

    return {}
end

function Blizzard.GetRecipeInfo(recipeID)
    if not C_TradeSkillUI or not C_TradeSkillUI.GetRecipeInfo then
        return nil
    end

    local ok, info = pcall(C_TradeSkillUI.GetRecipeInfo, recipeID)

    if not ok or type(info) ~= "table" then
        return nil
    end

    return info
end

------------------------------------------------------------
-- TIME-SENSITIVE CONTENT
------------------------------------------------------------

function Blizzard.GetSecondsUntilDailyReset()
    if GetQuestResetTime then
        local ok, seconds = pcall(GetQuestResetTime)

        if ok and type(seconds) == "number" and seconds > 0 then
            return seconds
        end
    end

    return nil
end

function Blizzard.GetSecondsUntilWeeklyReset()
    if C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset then
        local ok, seconds = pcall(C_DateAndTime.GetSecondsUntilWeeklyReset)

        if ok and type(seconds) == "number" and seconds > 0 then
            return seconds
        end
    end

    return nil
end

function Blizzard.IsWorldQuest(questID)
    if C_QuestLog and C_QuestLog.IsWorldQuest then
        local ok, result = pcall(C_QuestLog.IsWorldQuest, questID)

        return ok and result and true or false
    end

    return false
end

-- Seconds remaining on a world quest, or nil when it is not time-limited.
function Blizzard.GetQuestTimeLeft(questID)
    if not C_TaskQuest then
        return nil
    end

    if C_TaskQuest.GetQuestTimeLeftSeconds then
        local ok, seconds = pcall(C_TaskQuest.GetQuestTimeLeftSeconds, questID)

        if ok and type(seconds) == "number" and seconds > 0 then
            return seconds
        end
    end

    if C_TaskQuest.GetQuestTimeLeftMinutes then
        local ok, minutes = pcall(C_TaskQuest.GetQuestTimeLeftMinutes, questID)

        if ok and type(minutes) == "number" and minutes > 0 then
            return minutes * 60
        end
    end

    return nil
end

-- World quests currently up on a map. The field naming has changed between
-- versions (questId vs questID), so both are accepted.
function Blizzard.GetWorldQuestsOnMap(uiMapID)
    local results = {}

    if not uiMapID or not C_TaskQuest or not C_TaskQuest.GetQuestsForPlayerByMapID then
        return results
    end

    local ok, tasks = pcall(C_TaskQuest.GetQuestsForPlayerByMapID, uiMapID)

    if not ok or type(tasks) ~= "table" then
        return results
    end

    for _, task in ipairs(tasks) do
        local questID = task.questID or task.questId

        if questID then
            table.insert(results, {
                questID = questID,
                mapID   = task.mapID or uiMapID,
                x       = task.x,
                y       = task.y,
                inArea  = task.inProgress,
            })
        end
    end

    return results
end

function Blizzard.GetWorldQuestInfo(questID)
    local info = {}

    if C_TaskQuest and C_TaskQuest.GetQuestInfoByQuestID then
        local ok, title, factionID = pcall(C_TaskQuest.GetQuestInfoByQuestID, questID)

        if ok then
            info.title     = title
            info.factionID = factionID
        end
    end

    if C_QuestLog and C_QuestLog.GetQuestTagInfo then
        local ok, tag = pcall(C_QuestLog.GetQuestTagInfo, questID)

        if ok and type(tag) == "table" then
            info.tagName        = tag.tagName
            info.worldQuestType = tag.worldQuestType
            info.quality        = tag.quality
            info.isElite        = tag.isElite
        end
    end

    return info
end

-- Calendar events happening today. Requires the calendar to have been
-- opened at least once; the call is cheap and safe to repeat.
function Blizzard.GetTodaysEvents()
    local events = {}

    if not C_Calendar or not C_DateAndTime then
        return events
    end

    pcall(function()
        if C_Calendar.OpenCalendar then
            C_Calendar.OpenCalendar()
        end
    end)

    local ok, today = pcall(C_DateAndTime.GetCurrentCalendarTime)

    if not ok or type(today) ~= "table" or not today.monthDay then
        return events
    end

    local gotCount, count = pcall(C_Calendar.GetNumDayEvents, 0, today.monthDay)

    if not gotCount or type(count) ~= "number" then
        return events
    end

    for index = 1, count do
        local gotEvent, event = pcall(C_Calendar.GetDayEvent, 0, today.monthDay, index)

        if gotEvent and type(event) == "table" and event.title then
            -- sequenceType is "ONGOING" or "START" while an event is live.
            local ongoing = event.sequenceType == "ONGOING"
                or event.sequenceType == "START"
                or event.sequenceType == ""

            table.insert(events, {
                title        = event.title,
                eventType    = event.eventType,
                calendarType = event.calendarType,
                sequenceType = event.sequenceType,
                ongoing      = ongoing,
            })
        end
    end

    return events
end

------------------------------------------------------------
-- VIGNETTES (RARES AND TREASURES)
------------------------------------------------------------

-- Vignettes are the skull and chest icons the client puts on the minimap.
-- They are the only live signal that a rare is actually up right now, which
-- is what makes them worth more than any static rare database.
function Blizzard.GetVignettes(uiMapID)
    local results = {}

    if not C_VignetteInfo or not C_VignetteInfo.GetVignettes then
        return results
    end

    local ok, guids = pcall(C_VignetteInfo.GetVignettes)

    if not ok or type(guids) ~= "table" then
        return results
    end

    for _, guid in ipairs(guids) do
        local gotInfo, info = pcall(C_VignetteInfo.GetVignetteInfo, guid)

        if gotInfo and type(info) == "table" and info.name then
            local entry = {
                guid        = guid,
                vignetteID  = info.vignetteID,
                name        = info.name,
                atlas       = info.atlasName,
                objectGUID  = info.objectGUID,
                isDead      = info.isDead and true or false,
                onMinimap   = info.onMinimap,
                inFogOfWar  = info.inFogOfWar,
            }

            if uiMapID and C_VignetteInfo.GetVignettePosition then
                local gotPosition, position =
                    pcall(C_VignetteInfo.GetVignettePosition, guid, uiMapID)

                if gotPosition and position and position.GetXY then
                    local x, y = position:GetXY()

                    entry.mapID = uiMapID
                    entry.x     = x
                    entry.y     = y
                end
            end

            table.insert(results, entry)
        end
    end

    return results
end

-- Treasure chests and rare creatures use different atlas art. The atlas
-- name is the only reliable discriminator the client exposes.
function Blizzard.ClassifyVignette(atlasName)
    if type(atlasName) ~= "string" then
        return "UNKNOWN"
    end

    local lower = string.lower(atlasName)

    if string.find(lower, "chest", 1, true)
        or string.find(lower, "treasure", 1, true)
        or string.find(lower, "lootcontainer", 1, true) then
        return "TREASURE"
    end

    if string.find(lower, "vignetteskull", 1, true)
        or string.find(lower, "vignetteboss", 1, true)
        or string.find(lower, "elite", 1, true) then
        return "RARE"
    end

    if string.find(lower, "vignette", 1, true) then
        return "RARE"
    end

    return "UNKNOWN"
end

------------------------------------------------------------
-- CURRENCIES
------------------------------------------------------------

function Blizzard.GetCurrencyList()
    local results = {}

    if not C_CurrencyInfo or not C_CurrencyInfo.GetCurrencyListSize then
        return results
    end

    local ok, size = pcall(C_CurrencyInfo.GetCurrencyListSize)

    if not ok or type(size) ~= "number" then
        return results
    end

    for index = 1, size do
        local gotInfo, info = pcall(C_CurrencyInfo.GetCurrencyListInfo, index)

        if gotInfo and type(info) == "table" and not info.isHeader and info.name then
            table.insert(results, {
                currencyID   = info.currencyID,
                name         = info.name,
                quantity     = info.quantity or 0,
                maxQuantity  = info.maxQuantity or 0,
                totalEarned  = info.totalEarned or 0,
                quality      = info.quality,
                discovered   = info.discovered ~= false,

                -- Weekly caps are the actionable part: a capped currency is
                -- earning potential being thrown away every week it sits.
                canEarnPerWeek     = info.canEarnPerWeek and true or false,
                earnedThisWeek     = info.quantityEarnedThisWeek or 0,
                maxWeeklyQuantity  = info.maxWeeklyQuantity or 0,

                useTotalEarnedForMaxQty = info.useTotalEarnedForMaxQty and true or false,
            })
        end
    end

    return results
end

function Blizzard.GetCurrency(currencyID)
    if not C_CurrencyInfo or not C_CurrencyInfo.GetCurrencyInfo then
        return nil
    end

    local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, currencyID)

    if not ok or type(info) ~= "table" then
        return nil
    end

    return info
end

------------------------------------------------------------
-- EXPLORATION
------------------------------------------------------------

-- Blizzard exposes explored overlay textures but never a total, so a raw
-- "percent explored" cannot be computed from the map API. The Exploration
-- achievement category does carry per-subzone criteria, which is the only
-- countable exploration data the client offers.
CN_EXPLORATION_CATEGORY = 97

function Blizzard.GetExplorationAchievements()
    local results = {}

    if not GetCategoryNumAchievements then
        return results
    end

    local total = Blizzard.GetCategoryCounts(CN_EXPLORATION_CATEGORY)

    for index = 1, total do
        local achievement =
            Blizzard.GetAchievementInCategory(CN_EXPLORATION_CATEGORY, index)

        if achievement then
            local done, criteria =
                Blizzard.GetAchievementProgress(achievement.achievementID)

            table.insert(results, {
                achievementID = achievement.achievementID,
                name          = achievement.name,
                completed     = achievement.completed,
                done          = done,
                criteria      = criteria,
            })
        end
    end

    return results
end

-- The unfinished criteria of one achievement, by name. For exploration
-- achievements these are the subzone names still undiscovered.
function Blizzard.GetIncompleteCriteria(achievementID, limit)
    local missing = {}

    if not GetAchievementNumCriteria or not GetAchievementCriteriaInfo then
        return missing
    end

    local total = GetAchievementNumCriteria(achievementID) or 0

    for index = 1, total do
        local ok, description, _, completed =
            pcall(GetAchievementCriteriaInfo, achievementID, index)

        if ok and not completed and description and description ~= "" then
            table.insert(missing, description)

            if limit and #missing >= limit then
                break
            end
        end
    end

    return missing
end
'@

$Embedded['Providers\StaticData.lua'] = @'
-- Providers/StaticData.lua
-- Completion Navigator :: access layer for the curated static database.
--
-- Data/*.lua files call CN.Static.Register* to contribute rows. Nothing
-- reads those tables directly; everything goes through the accessors here
-- so the storage shape can change without touching consumers.

local ADDON_NAME, CN = ...

local Static = {}

CN.Static = Static

Static.quests    = {}
Static.recipes   = {}
Static.vendors   = {}
Static.rares     = {}
Static.treasures = {}

------------------------------------------------------------
-- REGISTRATION
------------------------------------------------------------

-- record = { name =, mapID =, x =, y =, expansion =, requires = {}, unlocks = {} }
function Static.RegisterQuest(questID, record)
    if not questID or type(record) ~= "table" then
        return
    end

    Static.quests[questID] = record
end

function Static.RegisterQuests(records)
    for questID, record in pairs(records) do
        Static.RegisterQuest(questID, record)
    end
end

function Static.RegisterRecipe(itemID, record)
    Static.recipes[itemID] = record
end

function Static.RegisterVendor(npcID, record)
    Static.vendors[npcID] = record
end

function Static.RegisterRare(npcID, record)
    Static.rares[npcID] = record
end

function Static.RegisterTreasure(id, record)
    Static.treasures[id] = record
end

------------------------------------------------------------
-- ACCESS
------------------------------------------------------------

function Static.GetQuest(questID)
    return Static.quests[questID]
end

function Static.GetQuestName(questID)
    local record = Static.quests[questID]

    return record and record.name or nil
end

function Static.GetQuestLocation(questID)
    local record = Static.quests[questID]

    if not record then
        return nil, nil, nil
    end

    return record.mapID, record.x, record.y
end

function Static.Count()
    return CN.CountKeys(Static.quests),
           CN.CountKeys(Static.recipes),
           CN.CountKeys(Static.vendors),
           CN.CountKeys(Static.rares),
           CN.CountKeys(Static.treasures)
end
'@

$Embedded['Providers\TomTom.lua'] = @'
-- Providers/TomTom.lua
-- Completion Navigator :: TomTom waypoint provider.
--
-- TomTom stays the navigation engine. Completion Navigator only decides
-- which waypoint is worth setting.

local ADDON_NAME, CN = ...

local provider = {}

local active = {}

function provider.IsAvailable()
    return _G.TomTom ~= nil and _G.TomTom.AddWaypoint ~= nil
end

function provider.SetWaypoint(mapID, x, y, title)
    if not provider.IsAvailable() then
        return
    end

    local uid = _G.TomTom:AddWaypoint(mapID, x, y, {
        title       = title or "Completion Navigator",
        persistent  = false,
        minimap     = true,
        world       = true,
        crazy       = true,
    })

    table.insert(active, uid)

    return uid
end

function provider.ClearAll()
    if not provider.IsAvailable() then
        return
    end

    for _, uid in ipairs(active) do
        pcall(_G.TomTom.RemoveWaypoint, _G.TomTom, uid)
    end

    active = {}
end

CN.RegisterWaypointProvider("TomTom", provider, 10)

------------------------------------------------------------
-- BLIZZARD MAP PIN FALLBACK
------------------------------------------------------------

local blizzardProvider = {}

function blizzardProvider.IsAvailable()
    return C_Map ~= nil and C_Map.SetUserWaypoint ~= nil
end

function blizzardProvider.SetWaypoint(mapID, x, y)
    if not blizzardProvider.IsAvailable() then
        return
    end

    local point = UiMapPoint and UiMapPoint.CreateFromCoordinates(mapID, x, y)

    if not point then
        return
    end

    C_Map.SetUserWaypoint(point)

    if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
        C_SuperTrack.SetSuperTrackedUserWaypoint(true)
    end
end

function blizzardProvider.ClearAll()
    if C_Map and C_Map.ClearUserWaypoint then
        C_Map.ClearUserWaypoint()
    end
end

CN.RegisterWaypointProvider("Blizzard", blizzardProvider, 20)
'@

$Embedded['Providers\ATT.lua'] = @'
-- Providers/ATT.lua
-- Completion Navigator :: AllTheThings interoperability.
--
-- ATT is the largest completion data corpus in the ecosystem. Duplicating it
-- would be pointless and rude; reading it when the player already has it
-- installed is the right relationship. Completion Navigator stays the
-- decision layer.
--
-- IMPORTANT: third-party addon APIs are not stable and are not documented as
-- public contracts. Every entry point below is probed at runtime and wrapped
-- in pcall. If ATT changes shape, this provider reports itself unavailable
-- and the addon carries on with its own data. It must never take the addon
-- down with it.
--
-- Run /cn providers in game to see exactly which entry points resolved.

local ADDON_NAME, CN = ...

local ATT = {}

CN.ATT = ATT

-- Candidate globals, newest naming first.
local GLOBALS = { "AllTheThings", "ATTC", "ATT" }

local resolved   = nil
local probeNotes = {}

local function Root()
    if resolved then
        return resolved
    end

    for _, name in ipairs(GLOBALS) do
        local candidate = _G[name]

        if type(candidate) == "table" then
            resolved = candidate

            table.insert(probeNotes, "global: " .. name)

            return resolved
        end
    end

    return nil
end

function ATT.IsAvailable()
    return Root() ~= nil
end

------------------------------------------------------------
-- SEARCH
------------------------------------------------------------

-- ATT's field search is the one entry point that has survived several
-- rewrites. It returns an array of "groups" describing everything ATT knows
-- about that ID.
local function Search(field, id)
    local root = Root()

    if not root or not id then
        return nil
    end

    local search = root.SearchForField or root.SearchForFieldContainer

    if type(search) ~= "function" then
        return nil
    end

    local ok, results = pcall(search, field, id)

    if not ok or type(results) ~= "table" then
        return nil
    end

    return results
end

ATT.Search = Search

------------------------------------------------------------
-- QUEST DATA
------------------------------------------------------------

-- Walks the groups ATT returns for a quest and pulls out whatever is useful.
-- Every field is optional; ATT groups are heterogeneous.
function ATT.GetQuestData(questID)
    local groups = Search("questID", questID)

    if not groups or #groups == 0 then
        return nil
    end

    local data = { source = "ATT" }

    for _, group in ipairs(groups) do
        if type(group) == "table" then
            if not data.name and type(group.name) == "string" and group.name ~= "" then
                data.name = group.name
            end

            if not data.mapID then
                data.mapID = group.mapID or group.coord and group.coord[3] or nil
            end

            -- ATT stores coordinates as {x, y, mapID} in `coord`, or a list
            -- of those in `coords`. Values are 0-100.
            local coord = group.coord

            if not coord and type(group.coords) == "table" then
                coord = group.coords[1]
            end

            if not data.x and type(coord) == "table" and coord[1] and coord[2] then
                data.x     = coord[1] / 100
                data.y     = coord[2] / 100
                data.mapID = coord[3] or data.mapID
            end

            if not data.requires and type(group.sourceQuests) == "table"
                and #group.sourceQuests > 0 then

                data.requires = {}

                for _, prerequisiteID in ipairs(group.sourceQuests) do
                    if type(prerequisiteID) == "number" then
                        table.insert(data.requires, prerequisiteID)
                    end
                end

                if #data.requires == 0 then
                    data.requires = nil
                end
            end

            if data.lvl == nil and type(group.lvl) == "number" then
                data.requiresLevel = group.lvl
            end
        end
    end

    if not (data.name or data.requires or data.x) then
        return nil
    end

    return data
end

------------------------------------------------------------
-- DIAGNOSTICS
------------------------------------------------------------

function ATT.Describe()
    local root = Root()

    if not root then
        return "not installed"
    end

    local entries = {}

    for _, note in ipairs(probeNotes) do
        table.insert(entries, note)
    end

    table.insert(entries, "SearchForField: "
        .. (type(root.SearchForField) == "function" and "yes" or "no"))

    return table.concat(entries, ", ")
end

------------------------------------------------------------
-- REGISTRATION
------------------------------------------------------------

CN.RegisterQuestDataProvider("ATT", {
    IsAvailable  = ATT.IsAvailable,
    GetQuestData = ATT.GetQuestData,
    Describe     = ATT.Describe,
    priority     = 20,
})
'@

$Embedded['Providers\BtWQuests.lua'] = @'
-- Providers/BtWQuests.lua
-- Completion Navigator :: BtWQuests interoperability.
--
-- BtWQuests knows quest chains. Completion Navigator knows what you have
-- done and where you are. The useful combination is: given the chain, which
-- link is the next one you can actually act on.
--
-- Same caution as the ATT provider: this reads another addon's internals,
-- which are not a published contract. Every access is probed and wrapped, so
-- a BtWQuests update can make this provider go quiet but cannot break
-- Completion Navigator.
--
-- /cn providers reports exactly what resolved.

local ADDON_NAME, CN = ...

local BtW = {}

CN.BtWQuests = BtW

local probeNotes = {}

local function Database()
    -- The database has lived in a couple of places across versions.
    local candidates = {
        _G.BtWQuestsDatabase,
        _G.BtWQuests and _G.BtWQuests.Database,
        _G.BtWQuests and _G.BtWQuests.database,
    }

    for index, candidate in ipairs(candidates) do
        if type(candidate) == "table" then
            if #probeNotes == 0 then
                table.insert(probeNotes, "database slot " .. index)
            end

            return candidate
        end
    end

    return nil
end

function BtW.IsAvailable()
    return _G.BtWQuests ~= nil and Database() ~= nil
end

------------------------------------------------------------
-- QUEST LOOKUP
------------------------------------------------------------

local function GetQuestItem(questID)
    local database = Database()

    if not database or not questID then
        return nil
    end

    local getter = database.GetQuestByID or database.GetQuest

    if type(getter) ~= "function" then
        return nil
    end

    local ok, item = pcall(getter, database, questID)

    if not ok or type(item) ~= "table" then
        return nil
    end

    return item
end

BtW.GetQuestItem = GetQuestItem

-- Normalizes whatever shape prerequisites come back in into a flat array of
-- quest IDs. BtWQuests expresses them as condition tables, which may nest.
local function CollectQuestIDs(node, out, depth)
    if type(node) ~= "table" or depth > 4 then
        return
    end

    if type(node.questID) == "number" then
        out[node.questID] = true
    end

    if type(node.id) == "number" and node.type == "quest" then
        out[node.id] = true
    end

    for _, child in pairs(node) do
        if type(child) == "table" then
            CollectQuestIDs(child, out, depth + 1)
        end
    end
end

function BtW.GetQuestData(questID)
    local item = GetQuestItem(questID)

    if not item then
        return nil
    end

    local data = { source = "BtWQuests" }

    -- Name.
    local nameGetter = item.GetName

    if type(nameGetter) == "function" then
        local ok, name = pcall(nameGetter, item)

        if ok and type(name) == "string" and name ~= "" then
            data.name = name
        end
    elseif type(item.name) == "string" then
        data.name = item.name
    end

    -- Prerequisites.
    local prerequisites = item.prerequisites or item.restrictions

    local getter = item.GetPrerequisites

    if type(getter) == "function" then
        local ok, result = pcall(getter, item)

        if ok and type(result) == "table" then
            prerequisites = result
        end
    end

    if type(prerequisites) == "table" then
        local ids = {}

        CollectQuestIDs(prerequisites, ids, 0)

        ids[questID] = nil   -- never list a quest as its own prerequisite

        local list = {}

        for id in pairs(ids) do
            table.insert(list, id)
        end

        table.sort(list)

        if #list > 0 then
            data.requires = list
        end
    end

    if not (data.name or data.requires) then
        return nil
    end

    return data
end

------------------------------------------------------------
-- DIAGNOSTICS
------------------------------------------------------------

function BtW.Describe()
    if not _G.BtWQuests then
        return "not installed"
    end

    local database = Database()

    if not database then
        return "loaded, but no database found"
    end

    local entries = {}

    for _, note in ipairs(probeNotes) do
        table.insert(entries, note)
    end

    table.insert(entries, "GetQuestByID: "
        .. (type(database.GetQuestByID) == "function" and "yes" or "no"))

    return table.concat(entries, ", ")
end

------------------------------------------------------------
-- REGISTRATION
------------------------------------------------------------

CN.RegisterQuestDataProvider("BtWQuests", {
    IsAvailable  = BtW.IsAvailable,
    GetQuestData = BtW.GetQuestData,
    Describe     = BtW.Describe,
    priority     = 30,
})
'@

$Embedded['Providers\HandyNotes.lua'] = @'
-- Providers/HandyNotes.lua
-- Completion Navigator :: HandyNotes interoperability.
--
-- HandyNotes and its plugins hold coordinates for treasures, rares, vendors
-- and collectibles that no Blizzard API reports. Where vignettes only tell
-- you about something in range, HandyNotes knows where things are before you
-- get near them.
--
-- Same caution as the other external providers: this reads another addon's
-- internals, which are not a published contract. Every access is probed and
-- wrapped, so a HandyNotes update can make this go quiet but cannot break
-- Completion Navigator. /cn providers reports what resolved.

local ADDON_NAME, CN = ...

local HandyNotes = {}

CN.HandyNotes = HandyNotes

local probeNotes = {}

local function Root()
    local candidate = _G.HandyNotes

    if type(candidate) == "table" then
        return candidate
    end

    return nil
end

function HandyNotes.IsAvailable()
    return Root() ~= nil
end

------------------------------------------------------------
-- PLUGINS
------------------------------------------------------------

-- HandyNotes itself holds almost no data. The plugins do, and they register
-- with the parent under names like "HandyNotes_Treasures".
function HandyNotes.GetPlugins()
    local root = Root()

    if not root then
        return {}
    end

    local names = {}

    -- Ace-style addon with a plugin registry.
    local iterate = root.IteratePlugins

    if type(iterate) == "function" then
        local ok, iterator = pcall(iterate, root)

        if ok and type(iterator) == "function" then
            local safe = 0

            for name in iterator do
                table.insert(names, name)

                safe = safe + 1

                if safe > 200 then
                    break
                end
            end
        end
    end

    if #names == 0 and type(root.plugins) == "table" then
        for name in pairs(root.plugins) do
            table.insert(names, name)
        end
    end

    table.sort(names)

    return names
end

------------------------------------------------------------
-- NODE LOOKUP
------------------------------------------------------------

-- Asks every registered plugin what it knows about a map. Plugin node
-- iterators are HandyNotes' documented extension point, so this is the most
-- stable surface available -- but it is still another addon's internals.
function HandyNotes.GetNodesOnMap(uiMapID)
    local root = Root()

    if not root or not uiMapID then
        return {}
    end

    local nodes = {}

    local iterate = root.IteratePlugins

    if type(iterate) ~= "function" then
        return nodes
    end

    local ok, iterator = pcall(iterate, root)

    if not ok or type(iterator) ~= "function" then
        return nodes
    end

    local pluginCount = 0

    for name, handler in iterator do
        pluginCount = pluginCount + 1

        if pluginCount > 50 then
            break
        end

        if type(handler) == "table" and type(handler.GetNodes2) == "function" then
            local gotNodes, nodeIterator = pcall(handler.GetNodes2, handler, uiMapID, false)

            if gotNodes and type(nodeIterator) == "function" then
                local safe = 0

                -- HandyNotes coords pack x and y into one integer.
                local success = pcall(function()
                    for coord, node in nodeIterator do
                        safe = safe + 1

                        if safe > 500 then
                            break
                        end

                        if type(coord) == "number" then
                            local x = math.floor(coord / 10000) / 10000
                            local y = (coord % 10000) / 10000

                            table.insert(nodes, {
                                plugin = name,
                                x      = x,
                                y      = y,
                                mapID  = uiMapID,
                                label  = type(node) == "table" and node.label or nil,
                            })
                        end
                    end
                end)

                if not success then
                    CN.DebugPrint("HandyNotes plugin " .. tostring(name)
                        .. " node iteration failed.")
                end
            end
        end
    end

    return nodes
end

------------------------------------------------------------
-- DIAGNOSTICS
------------------------------------------------------------

function HandyNotes.Describe()
    local root = Root()

    if not root then
        return "not installed"
    end

    local plugins = HandyNotes.GetPlugins()

    if #plugins == 0 then
        return "loaded, no plugins registered"
    end

    local noun = (#plugins == 1) and " plugin" or " plugins"

    if #plugins <= 3 then
        return #plugins .. noun .. ": " .. table.concat(plugins, ", ")
    end

    return #plugins .. noun
end

------------------------------------------------------------
-- REGISTRATION
------------------------------------------------------------

-- Registered as a quest data provider so it appears in /cn providers, even
-- though it answers about locations rather than quests. It never claims to
-- know a quest, so it can never contribute wrong prerequisite data.
CN.RegisterQuestDataProvider("HandyNotes", {
    IsAvailable  = HandyNotes.IsAvailable,
    GetQuestData = function() return nil end,
    Describe     = HandyNotes.Describe,
    priority     = 90,
})
'@

$Embedded['Modules\Quests.lua'] = @'
-- Modules/Quests.lua
-- Completion Navigator :: quest subsystem.
--
-- Roadmap position: automatic discovery, event-driven refresh, persistent
-- metadata and status, source-ranked metadata writes.

local ADDON_NAME, CN = ...

local Quests = CN:RegisterModule("Quests")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

CN.pendingQuestLoads = CN.pendingQuestLoads or {}

------------------------------------------------------------
-- COMPLETION STATE
------------------------------------------------------------

function Quests.IsCompletedByCharacter(questID)
    return Blizzard.IsQuestCompletedByCharacter(questID)
end

function Quests.IsCompletedOnAccount(questID)
    return Blizzard.IsQuestCompletedOnAccount(questID)
end

-- Kept for backwards compatibility with the single-file prototype.
CN.IsQuestCompletedByCharacter = Quests.IsCompletedByCharacter
CN.IsQuestCompletedOnAccount   = Quests.IsCompletedOnAccount

------------------------------------------------------------
-- METADATA
------------------------------------------------------------

-- Writes a name only when the incoming source is at least as
-- authoritative as the stored one. Manual entries never clobber Blizzard.
function Quests.SetMetadata(questID, name, source)
    if not questID or not name or name == "" then
        return false
    end

    local metadata = CN.Account("questMetadata")
    local existing = metadata[questID]

    source = source or "manual"

    if existing and existing.name and not CN.IsBetterSource(source, existing.source) then
        DebugPrint("Kept existing " .. tostring(existing.source)
            .. " name for quest " .. questID .. "; rejected " .. source .. ".")
        return false
    end

    metadata[questID] = {
        questID  = questID,
        name     = name,
        lastSeen = time(),
        source   = source,
    }

    return true
end

function Quests.GetMetadata(questID)
    return CN.Account("questMetadata")[questID]
end

-- Resolution order: cache -> live client -> static data -> async request.
function Quests.GetName(questID, requestIfMissing)
    if not questID then
        return nil
    end

    local cached = Quests.GetMetadata(questID)

    if cached and cached.name then
        return cached.name
    end

    local title = Blizzard.GetQuestTitle(questID, false)

    if title then
        Quests.SetMetadata(questID, title, "blizzard")
        return title
    end

    local static = CN.Static.GetQuestName(questID)

    if static then
        Quests.SetMetadata(questID, static, "static")
        return static
    end

    if requestIfMissing then
        Blizzard.GetQuestTitle(questID, true)
    end

    return nil
end

CN.GetQuestName = Quests.GetName

------------------------------------------------------------
-- DISCOVERY
------------------------------------------------------------

function Quests.RecordDiscovered(questID, source)
    questID = CN.ToID(questID)

    if not questID then
        return false
    end

    local discovered = CN.Account("discoveredQuests")
    local existing   = discovered[questID]

    discovered[questID] = {
        firstSeen = existing and existing.firstSeen or time(),
        lastSeen  = time(),
        source    = source or (existing and existing.source) or "manual",
    }

    if not existing then
        DebugPrint("Discovered quest " .. questID .. " (" .. tostring(source or "manual") .. ").")
    end

    return existing == nil
end

CN.RecordDiscoveredQuest = Quests.RecordDiscovered

function Quests.DiscoverActive()
    local entries = Blizzard.GetQuestLogEntries()

    if #entries == 0 and not C_QuestLog then
        Print("Quest Log API is unavailable.")
        return 0, 0
    end

    local seen = 0
    local new  = 0

    for _, info in ipairs(entries) do
        if Quests.RecordDiscovered(info.questID, "questlog") then
            new = new + 1
        end

        if info.title and info.title ~= "" then
            Quests.SetMetadata(info.questID, info.title, "questlog")
        end

        seen = seen + 1
    end

    return seen, new
end

------------------------------------------------------------
-- STATUS
------------------------------------------------------------

function Quests.RecordStatus(questID)
    local characterCompleted = Quests.IsCompletedByCharacter(questID)
    local accountCompleted   = Quests.IsCompletedOnAccount(questID)

    CN.Account("questStatus")[questID] = {
        characterCompleted = characterCompleted,
        accountCompleted   = accountCompleted,
        lastChecked        = time(),
    }

    return characterCompleted, accountCompleted
end

function Quests.ScanKnown()
    local scanned, byCharacter, onAccount = 0, 0, 0

    for questID in pairs(CN.Account("discoveredQuests")) do
        local characterCompleted, accountCompleted = Quests.RecordStatus(questID)

        scanned = scanned + 1

        if characterCompleted then
            byCharacter = byCharacter + 1
        end

        if accountCompleted then
            onAccount = onAccount + 1
        end
    end

    return scanned, byCharacter, onAccount
end

------------------------------------------------------------
-- ELIGIBILITY
------------------------------------------------------------

-- Curated static data first, then whatever external addons know, then
-- anything harvested from this account's own play. Static wins because it is
-- the only source this addon controls and ships.
function Quests.GetRecord(questID)
    local static = CN.Static.GetQuest(questID)

    if static and (static.requires or static.obsolete or static.requiresLevel) then
        return static, "static"
    end

    local external = CN.QueryQuestDataProviders(questID)

    if external and (external.requires or external.requiresLevel) then
        return external, table.concat(external.providers or { "external" }, "+")
    end

    local harvested = CN.Account("questHarvest")[questID]

    if harvested and harvested.requires then
        return harvested, "harvested"
    end

    return static, static and "static" or nil
end

CN.RegisterEligibilityChecker(CN.objectiveTypes.QUEST, function(questID)
    local states = CN.objectiveStates

    if Quests.IsCompletedByCharacter(questID) then
        return states.COMPLETED, "Already completed by this character", nil
    end

    local static = Quests.GetRecord(questID)

    if static then
        if static.obsolete then
            return states.UNOBTAINABLE, CN.blockReasons.OBSOLETE, nil
        end

        if static.requires then
            for _, prerequisiteID in ipairs(static.requires) do
                if not Quests.IsCompletedByCharacter(prerequisiteID) then
                    return states.LOCKED,
                           CN.blockReasons.PREREQUISITE_QUEST,
                           Quests.GetName(prerequisiteID) or ("quest " .. prerequisiteID)
                end
            end
        end

        if static.requiresLevel and UnitLevel("player") < static.requiresLevel then
            return states.LOCKED, CN.blockReasons.LEVEL_TOO_LOW, tostring(static.requiresLevel)
        end

        if static.requiresFaction and CN.character
            and CN.character.faction ~= static.requiresFaction then
            return states.INELIGIBLE, CN.blockReasons.WRONG_FACTION, static.requiresFaction
        end
    end

    return states.AVAILABLE, nil, nil
end)

------------------------------------------------------------
-- LOCATION
------------------------------------------------------------

-- Coordinates the player supplied by hand, for quests the client will not
-- answer for. Persisted account-wide: a location is a fact about the world,
-- not about one character.
local function Overrides()
    return CN.Account("questLocations")
end

Quests.Overrides = Overrides

function Quests.SetLocation(questID, mapID, x, y)
    if not questID or not mapID or not x or not y then
        return false
    end

    -- Accept either 0-1 or 0-100; the map API wants 0-1.
    if x > 1 then x = x / 100 end
    if y > 1 then y = y / 100 end

    if x <= 0 or x >= 1 or y <= 0 or y >= 1 then
        return false
    end

    Overrides()[questID] = {
        mapID = mapID,
        x     = x,
        y     = y,
        setAt = time(),
    }

    return true
end

function Quests.ClearLocation(questID)
    Overrides()[questID] = nil
end

-- Live client data first, then the player's own override, then curated
-- static data. Live wins because it tracks the quest's *current* step.
function Quests.GetLocation(questID)
    local mapID, x, y = Blizzard.GetQuestWaypoint(questID)

    if mapID and x and y then
        return mapID, x, y, "blizzard"
    end

    local override = Overrides()[questID]

    if override and override.mapID and override.x and override.y then
        return override.mapID, override.x, override.y, "manual"
    end

    local staticMap, staticX, staticY = CN.Static.GetQuestLocation(questID)

    if staticMap and staticX and staticY then
        return staticMap, staticX, staticY, "static"
    end

    return mapID or staticMap, nil, nil, nil
end

------------------------------------------------------------
-- CANDIDATES
------------------------------------------------------------

CN.RegisterCandidateProvider("Quests", function()
    local candidates = {}

    local playerMap, playerX, playerY = CN.GetPlayerPosition()

    local seen = {}

    local function add(questID, name, isActive)
        if not questID or seen[questID] then
            return
        end

        if CN.IsIgnored(CN.objectiveTypes.QUEST, questID)
            or CN.IsDeferred(CN.objectiveTypes.QUEST, questID) then
            return
        end

        seen[questID] = true

        local mapID, x, y, source = Quests.GetLocation(questID)

        local reasons = {}
        local value   = 1
        local travel  = 0

        if isActive then
            if Blizzard.IsQuestReadyForTurnIn(questID) then
                value = value + 3
                table.insert(reasons, "ready to turn in")
            else
                local done, total = Blizzard.GetQuestObjectiveProgress(questID)

                if total > 0 and done > 0 then
                    value = value + 1
                    table.insert(reasons, done .. " of " .. total .. " objectives already done")
                end
            end
        end

        local static = CN.Static.GetQuest(questID)

        if static and static.unlocks and #static.unlocks > 0 then
            value = value + #static.unlocks
            table.insert(reasons, "unlocks " .. #static.unlocks .. " further quest(s)")
        end

        if mapID and playerMap then
            if mapID == playerMap then
                table.insert(reasons, "in your current zone")

                if x and y and playerX and playerY then
                    local dx = x - playerX
                    local dy = y - playerY

                    travel = math.sqrt((dx * dx) + (dy * dy)) * 10
                end
            else
                travel = 25
            end
        elseif not mapID then
            -- Unknown location: usable as a suggestion, useless for routing.
            travel = 5
        end

        table.insert(candidates, CN.NewObjective({
            id                = questID,
            type              = CN.objectiveTypes.QUEST,
            name              = name or Quests.GetName(questID) or ("Quest " .. questID),
            mapID             = mapID,
            x                 = x,
            y                 = y,
            source            = source,
            state             = CN.objectiveStates.AVAILABLE,
            completionValue   = value,
            travelCost        = travel,
            reasons           = reasons,
        }))
    end

    for _, info in ipairs(Blizzard.GetQuestLogEntries()) do
        add(info.questID, info.title, true)
    end

    -- Curated quests that are not in the log and not yet completed.
    for questID, record in pairs(CN.Static.quests) do
        if not record.obsolete and not Quests.IsCompletedByCharacter(questID) then
            local state = CN.Explain(CN.objectiveTypes.QUEST, questID)

            if state == CN.objectiveStates.AVAILABLE then
                add(questID, record.name, false)
            end
        end
    end

    return candidates
end)

------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

CN:RegisterEvent("QUEST_DATA_LOAD_RESULT", function(event, questID, success)
    if not CN.pendingQuestLoads[questID] then
        return
    end

    CN.pendingQuestLoads[questID] = nil

    if not success then
        DebugPrint("Quest " .. tostring(questID) .. " metadata was unavailable from Blizzard.")
        return
    end

    local title = Blizzard.GetQuestTitle(questID, false)

    if title then
        Quests.SetMetadata(questID, title, "blizzard")
        Print("Quest " .. questID .. " - " .. title)
    else
        DebugPrint("Quest " .. questID .. " loaded, but no title was returned.")
    end
end)

CN:RegisterEvent("QUEST_ACCEPTED", function(event, questID)
    if not questID then
        return
    end

    Quests.RecordDiscovered(questID, "questlog")

    local title = Blizzard.GetQuestTitle(questID, true)

    if title then
        Quests.SetMetadata(questID, title, "questlog")
    end

    Quests.RecordStatus(questID)

    DebugPrint("Quest accepted: " .. questID)
end)

CN:RegisterEvent("QUEST_TURNED_IN", function(event, questID)
    if not questID then
        return
    end

    Quests.RecordDiscovered(questID, "questlog")
    Quests.RecordStatus(questID)

    DebugPrint("Quest turned in: " .. questID)
end)

CN:RegisterEvent("QUEST_REMOVED", function(event, questID)
    if not questID then
        return
    end

    Quests.RecordStatus(questID)

    DebugPrint("Quest removed from log: " .. questID)
end)

-- QUEST_LOG_UPDATE fires constantly; throttle a full rescan.
local lastLogScan = 0

CN:RegisterEvent("QUEST_LOG_UPDATE", function()
    local now = time()

    if now - lastLogScan < 10 then
        return
    end

    lastLogScan = now

    local seen, new = Quests.DiscoverActive()

    if new > 0 then
        DebugPrint("Quest Log scan discovered " .. new .. " new quests (" .. seen .. " active).")
    end
end)

CN:OnLogin(function()
    local seen, new = Quests.DiscoverActive()

    DebugPrint("Login quest scan: " .. seen .. " active, " .. new .. " new.")
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "quest",
    aliases = { "q" },
    args    = "<questID>",
    order   = 20,
    help    = "Check whether a quest is completed.",
    handler = function(args)
        local questID = CN.ToID(args)

        if not questID then
            Print("Usage: /cn quest <questID>")
            return
        end

        Quests.RecordDiscovered(questID, "manual")

        local characterCompleted, accountCompleted = Quests.RecordStatus(questID)

        local name = Quests.GetName(questID, true)

        if name then
            Print("Quest " .. questID .. " - " .. name .. ":")
        else
            Print("Quest " .. questID .. ":")
        end

        Print("Character completion: " .. CN.YesNo(characterCompleted))

        if Blizzard.HasAccountQuestAPI() then
            Print("Account/Warband completion: " .. CN.YesNo(accountCompleted))
        else
            Print("Account/Warband completion: |cffffff00API unavailable|r")
        end

        local state, reason, detail = CN.Explain(CN.objectiveTypes.QUEST, questID)

        Print("State: " .. state .. (reason and (" - " .. reason) or "")
            .. (detail and (" (" .. detail .. ")") or ""))
    end,
}

CN:RegisterCommand{
    name    = "cache",
    args    = "<questID>",
    order   = 21,
    help    = "Show cached quest metadata.",
    handler = function(args)
        local questID = CN.ToID(args)

        if not questID then
            Print("Usage: /cn cache <questID>")
            return
        end

        local cached = Quests.GetMetadata(questID)

        if cached and cached.name then
            Print("Cached quest " .. questID .. ": " .. cached.name
                .. " |cff999999[" .. tostring(cached.source) .. "]|r")
        else
            Print("No cached metadata for quest " .. questID .. ".")
        end
    end,
}

CN:RegisterCommand{
    name    = "setquest",
    args    = "<questID> <name>",
    order   = 22,
    help    = "Manually save quest metadata.",
    handler = function(args)
        local questIDText, name = args:match("^(%d+)%s+(.+)$")

        local questID = CN.ToID(questIDText)

        if not questID or not name or name == "" then
            Print("Usage: /cn setquest <questID> <name>")
            return
        end

        if Quests.SetMetadata(questID, name, "manual") then
            Print("Saved quest " .. questID .. ": " .. name)
        else
            Print("Kept the existing, more authoritative name for quest " .. questID .. ".")
        end
    end,
}

CN:RegisterCommand{
    name    = "queststatus",
    args    = "<questID>",
    order   = 23,
    help    = "Show the stored quest completion state.",
    handler = function(args)
        local questID = CN.ToID(args)

        if not questID then
            Print("Usage: /cn queststatus <questID>")
            return
        end

        local status = CN.Account("questStatus")[questID]

        if not status then
            Print("No stored quest status for quest " .. questID .. ".")
            return
        end

        Print("Stored quest " .. questID .. " status:")
        Print("Character completion: " .. CN.YesNo(status.characterCompleted))
        Print("Account/Warband completion: " .. CN.YesNo(status.accountCompleted))
        Print("Last checked: " .. date("%Y-%m-%d %H:%M", status.lastChecked or 0))
    end,
}

CN:RegisterCommand{
    name    = "scanquests",
    order   = 24,
    help    = "Scan known quest IDs for completion.",
    handler = function()
        local scanned, byCharacter, onAccount = Quests.ScanKnown()

        Print("Scanned " .. scanned .. " known quests.")
        Print("Character completed: " .. byCharacter)
        Print("Account/Warband completed: " .. onAccount)
    end,
}

CN:RegisterCommand{
    name    = "discovered",
    order   = 25,
    help    = "Show the number of discovered quests.",
    handler = function()
        Print("Discovered quests: " .. CN.CountKeys(CN.Account("discoveredQuests")))
        Print("Cached quest names: " .. CN.CountKeys(CN.Account("questMetadata")))
        Print("Stored quest statuses: " .. CN.CountKeys(CN.Account("questStatus")))
    end,
}

CN:RegisterCommand{
    name    = "discoveractive",
    order   = 26,
    help    = "Discover quests currently in the Quest Log.",
    handler = function()
        local seen, new = Quests.DiscoverActive()

        Print("Active quests discovered: " .. seen .. " (" .. new .. " new).")
    end,
}

CN:RegisterCommand{
    name    = "where",
    args    = "<questID>",
    order   = 28,
    help    = "Show what location is known for a quest.",
    handler = function(args)
        local questID = CN.ToID(args)

        if not questID then
            Print("Usage: /cn where <questID>")
            return
        end

        local mapID, x, y, source = Quests.GetLocation(questID)

        Print("Quest " .. questID .. " - "
            .. (Quests.GetName(questID, true) or "unknown name"))

        if mapID and x and y then
            Print(string.format("Location: map %d at %.1f, %.1f |cff999999[%s]|r",
                mapID, x * 100, y * 100, tostring(source)))
        elseif mapID then
            Print("Map " .. mapID .. " |cffffff00(no coordinates)|r")
        else
            Print("|cffff4444No location is known.|r")
        end

        Print("In your quest log: " .. CN.YesNo(Blizzard.IsQuestInLog(questID)))
    end,
}

CN:RegisterCommand{
    name    = "setloc",
    args    = "<questID> <mapID> <x> <y>",
    order   = 29,
    help    = "Record coordinates for a quest by hand.",
    handler = function(args)
        local questID, mapID, x, y =
            args:match("^(%d+)%s+(%d+)%s+([%d%.]+)%s+([%d%.]+)$")

        questID = CN.ToID(questID)
        mapID   = CN.ToID(mapID)
        x       = tonumber(x)
        y       = tonumber(y)

        if not questID or not mapID or not x or not y then
            Print("Usage: /cn setloc <questID> <mapID> <x> <y>")
            Print("Coordinates may be 0-1 or 0-100. Find the map ID with "
                .. "|cffffff00/cn where|r or /dump C_Map.GetBestMapForUnit(\"player\")")
            return
        end

        if Quests.SetLocation(questID, mapID, x, y) then
            Print("Saved location for quest " .. questID .. ".")
        else
            Print("Those coordinates are out of range.")
        end
    end,
}

CN:RegisterCommand{
    name    = "why",
    args    = "<questID>",
    order   = 27,
    help    = "Explain why a quest is not available.",
    handler = function(args)
        local questID = CN.ToID(args)

        if not questID then
            Print("Usage: /cn why <questID>")
            return
        end

        local state, reason, detail = CN.Explain(CN.objectiveTypes.QUEST, questID)

        Print("Quest " .. questID .. " - " .. (Quests.GetName(questID, true) or "unknown name"))
        Print("State: " .. state)

        if reason then
            Print("Reason: " .. reason .. (detail and (" (" .. detail .. ")") or ""))
        end

        local record, source = Quests.GetRecord(questID)

        if record and source then
            Print("Data source: |cff999999" .. source .. "|r")
        else
            Print("|cff999999No prerequisite data for this quest. "
                .. "Install AllTheThings or BtWQuests, or add a row with /cn setloc.|r")
        end
    end,
}

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
'@

$Embedded['Modules\Reputations.lua'] = @'
-- Modules/Reputations.lua
-- Completion Navigator :: reputation, Renown, and Paragon subsystem.
--
-- The point of this module is not to show standings. The game already does
-- that. The point is to record WHERE each standing lives -- account-wide or
-- on one specific character -- because that is what decides which character
-- should do a piece of reputation work.
--
-- Storage split:
--   CN.Account("reputations")[factionID]        account-wide standings
--   character.reputations[factionID]            character-specific standings
--   CN.Account("factionNames")[factionID]       shared name cache
--
-- That split is what lets an offline alt be evaluated as a candidate.

local ADDON_NAME, CN = ...

local Reputations = CN:RegisterModule("Reputations")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

------------------------------------------------------------
-- STORAGE
------------------------------------------------------------

local function AccountStore()
    return CN.Account("reputations")
end

local function NameStore()
    return CN.Account("factionNames")
end

local function CharacterStore(character)
    character = character or CN.character

    if not character then
        return nil
    end

    character.reputations = character.reputations or {}

    return character.reputations
end

Reputations.AccountStore   = AccountStore
Reputations.CharacterStore = CharacterStore

------------------------------------------------------------
-- STANDING MODEL
------------------------------------------------------------

-- Normalizes the three different standing systems (classic 1-8 reactions,
-- friendship reputations, and Renown) into one comparable shape.
local function BuildRecord(data)
    local factionID = data.factionID

    local record = {
        factionID   = factionID,
        name        = data.name,
        reaction    = data.reaction,
        standing    = Blizzard.GetStandingLabel(data.reaction),
        current     = (data.currentStanding or 0) - (data.currentReactionThreshold or 0),
        maximum     = (data.nextReactionThreshold or 0) - (data.currentReactionThreshold or 0),
        raw         = data.currentStanding,
        accountWide = Blizzard.IsAccountWideReputation(factionID),
        lastSeen    = time(),
    }

    local friendship = Blizzard.GetFriendshipReputation(factionID)

    if friendship then
        record.kind     = "FRIENDSHIP"
        record.standing = friendship.reaction or record.standing
        record.current  = (friendship.standing or 0) - (friendship.reactionThreshold or 0)
        record.maximum  = (friendship.nextThreshold or 0) - (friendship.reactionThreshold or 0)
    elseif Blizzard.IsMajorFaction(factionID) then
        local major = Blizzard.GetMajorFactionData(factionID)

        record.kind = "RENOWN"

        if major then
            record.renown     = major.renownLevel
            record.current    = major.renownReputationEarned
            record.maximum    = major.renownLevelThreshold
            record.expansion  = major.expansionID
            record.unlocked   = major.isUnlocked
            record.maxedOut   = Blizzard.HasMaximumRenown(factionID)
            record.standing   = "Renown " .. tostring(major.renownLevel or 0)
        end
    else
        record.kind = "STANDARD"
    end

    if Blizzard.IsFactionParagon(factionID) then
        local value, threshold, questID, pending = Blizzard.GetParagonInfo(factionID)

        record.paragon = {
            value     = value,
            threshold = threshold,
            questID   = questID,
            pending   = pending and true or false,
        }
    end

    return record
end

Reputations.BuildRecord = BuildRecord

------------------------------------------------------------
-- SCAN
------------------------------------------------------------

function Reputations.Scan()
    local accountStore   = AccountStore()
    local characterStore = CharacterStore()
    local nameStore      = NameStore()

    local total, accountWide, characterSpecific, pendingParagon = 0, 0, 0, 0

    Blizzard.WithAllFactionsExpanded(function()
        for index = 1, Blizzard.GetNumFactions() do
            local data = Blizzard.GetFactionByIndex(index)

            -- Plain headers carry no standing; headers WITH rep do.
            local hasStanding = data
                and data.factionID
                and data.factionID > 0
                and ((not data.isHeader) or data.isHeaderWithRep)

            if hasStanding then
                local record = BuildRecord(data)

                nameStore[data.factionID] = record.name

                if record.accountWide then
                    accountStore[data.factionID] = record
                    accountWide = accountWide + 1
                elseif characterStore then
                    characterStore[data.factionID] = record
                    characterSpecific = characterSpecific + 1
                end

                if record.paragon and record.paragon.pending then
                    pendingParagon = pendingParagon + 1
                end

                total = total + 1
            end
        end
    end)

    if CN.character then
        CN.character.reputationsScanned = time()
    end

    return total, accountWide, characterSpecific, pendingParagon
end

------------------------------------------------------------
-- LOOKUP
------------------------------------------------------------

function Reputations.Get(factionID, character)
    local account = AccountStore()[factionID]

    if account then
        return account, "account"
    end

    local store = CharacterStore(character)

    if store and store[factionID] then
        return store[factionID], "character"
    end

    return nil, nil
end

-- Accepts a faction ID or a case-insensitive name fragment.
function Reputations.Resolve(text)
    local factionID = CN.ToID(text)

    if factionID then
        return factionID
    end

    if not text or text == "" then
        return nil
    end

    local needle  = string.lower(text)
    local matches = {}

    for id, name in pairs(NameStore()) do
        if name and string.find(string.lower(name), needle, 1, true) then
            table.insert(matches, { id = id, name = name })
        end
    end

    if #matches == 0 then
        return nil, matches
    end

    table.sort(matches, function(a, b) return #a.name < #b.name end)

    return matches[1].id, matches
end

------------------------------------------------------------
-- WARBAND
------------------------------------------------------------

-- Returns the best-standing character for a character-specific faction, so
-- the recommendation engine can say "switch to this alt instead".
function Reputations.BestCharacterFor(factionID)
    if AccountStore()[factionID] then
        return nil, nil, "account-wide"
    end

    local bestKey, bestRecord

    for key, character in CN.Characters() do
        local record = character.reputations and character.reputations[factionID]

        if record then
            local better = false

            if not bestRecord then
                better = true
            elseif (record.renown or 0) ~= (bestRecord.renown or 0) then
                better = (record.renown or 0) > (bestRecord.renown or 0)
            elseif (record.reaction or 0) ~= (bestRecord.reaction or 0) then
                better = (record.reaction or 0) > (bestRecord.reaction or 0)
            else
                better = (record.raw or 0) > (bestRecord.raw or 0)
            end

            if better then
                bestKey    = key
                bestRecord = record
            end
        end
    end

    return bestKey, bestRecord, nil
end

------------------------------------------------------------
-- SUMMARY
------------------------------------------------------------

function Reputations.Summary()
    local account   = AccountStore()
    local character = CharacterStore() or {}

    local counts = {
        account          = CN.CountKeys(account),
        character        = CN.CountKeys(character),
        renown           = 0,
        maxedRenown      = 0,
        paragonPending   = 0,
        exalted          = 0,
    }

    local function tally(store)
        for _, record in pairs(store) do
            if record.kind == "RENOWN" then
                counts.renown = counts.renown + 1

                if record.maxedOut then
                    counts.maxedRenown = counts.maxedRenown + 1
                end
            end

            if record.reaction and record.reaction >= 8 then
                counts.exalted = counts.exalted + 1
            end

            if record.paragon and record.paragon.pending then
                counts.paragonPending = counts.paragonPending + 1
            end
        end
    end

    tally(account)
    tally(character)

    return counts
end

------------------------------------------------------------
-- ELIGIBILITY
------------------------------------------------------------

CN.RegisterEligibilityChecker(CN.objectiveTypes.REPUTATION, function(factionID)
    local states = CN.objectiveStates

    local record, scope = Reputations.Get(factionID)

    if not record then
        return states.UNKNOWN, "No standing recorded; run /cn repscan", nil
    end

    if record.kind == "RENOWN" then
        if record.unlocked == false then
            return states.LOCKED, CN.blockReasons.CAMPAIGN_INCOMPLETE, record.name
        end

        if record.maxedOut and not (record.paragon and record.paragon.pending) then
            return states.COMPLETED, "Maximum Renown reached", record.name
        end

        return states.AVAILABLE, nil, nil
    end

    if record.reaction and record.reaction >= 8
        and not (record.paragon and record.paragon.pending) then
        return states.COMPLETED, "Exalted", record.name
    end

    if scope == "character" then
        local bestKey, bestRecord = Reputations.BestCharacterFor(factionID)

        if bestKey and bestKey ~= CN.characterKey and bestRecord then
            local mine = record.reaction or 0

            if (bestRecord.reaction or 0) > mine then
                return states.REQUIRES_OTHER_CHARACTER,
                       CN.blockReasons.BETTER_CHARACTER,
                       bestKey .. " is " .. tostring(bestRecord.standing)
            end
        end
    end

    return states.AVAILABLE, nil, nil
end)

------------------------------------------------------------
-- CANDIDATES
------------------------------------------------------------

CN.RegisterCandidateProvider("Reputations", function()
    local candidates = {}

    local function consider(record, accountWide)
        if not record or not record.factionID then
            return
        end

        if CN.IsIgnored(CN.objectiveTypes.REPUTATION, record.factionID)
            or CN.IsDeferred(CN.objectiveTypes.REPUTATION, record.factionID) then
            return
        end

        local reasons = {}
        local value   = 1

        if record.paragon and record.paragon.pending then
            value = value + 3
            table.insert(reasons, "a Paragon reward is waiting to be collected")
        elseif record.kind == "RENOWN" and record.maxedOut then
            return
        elseif record.reaction and record.reaction >= 8 then
            return
        end

        if accountWide then
            value = value + 1
            table.insert(reasons, "account-wide, so any character's progress counts")
        end

        if record.maximum and record.maximum > 0 and record.current then
            local fraction = record.current / record.maximum

            if fraction >= 0.75 then
                value = value + 1
                table.insert(reasons, string.format(
                    "%d%% of the way to the next standing", math.floor(fraction * 100)))
            end
        end

        table.insert(candidates, CN.NewObjective({
            id              = record.factionID,
            type            = CN.objectiveTypes.REPUTATION,
            name            = record.name,
            accountWide     = accountWide,
            completionValue = value,
            reasons         = reasons,
        }))
    end

    for _, record in pairs(AccountStore()) do
        consider(record, true)
    end

    local characterStore = CharacterStore()

    if characterStore then
        for _, record in pairs(characterStore) do
            consider(record, false)
        end
    end

    return candidates
end)

------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

-- UPDATE_FACTION fires on nearly every reputation tick. Throttle hard.
local lastScan = 0

CN:RegisterEvent("UPDATE_FACTION", function()
    local now = time()

    if now - lastScan < 15 then
        return
    end

    lastScan = now

    local total = Reputations.Scan()

    DebugPrint("Reputation scan: " .. total .. " factions.")
end)

CN:RegisterEvent("MAJOR_FACTION_RENOWN_LEVEL_CHANGED", function(event, factionID, newLevel)
    lastScan = 0

    DebugPrint("Renown changed for faction " .. tostring(factionID)
        .. " to " .. tostring(newLevel) .. ".")

    Reputations.Scan()
end)

CN:RegisterEvent("MAJOR_FACTION_UNLOCKED", function(event, factionID)
    lastScan = 0

    Reputations.Scan()

    DebugPrint("Major faction unlocked: " .. tostring(factionID))
end)

CN:OnLogin(function()
    local total, accountWide, characterSpecific = Reputations.Scan()

    DebugPrint("Login reputation scan: " .. total .. " factions ("
        .. accountWide .. " account-wide, " .. characterSpecific .. " character).")
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "repscan",
    order   = 40,
    help    = "Rescan every reputation and record its scope.",
    handler = function()
        local total, accountWide, characterSpecific, paragon = Reputations.Scan()

        Print("Scanned " .. total .. " factions.")
        Print("Account-wide: " .. accountWide)
        Print("Character-specific: " .. characterSpecific)

        if paragon > 0 then
            Print("Paragon rewards waiting: |cff00ff00" .. paragon .. "|r")
        end
    end,
}

CN:RegisterCommand{
    name    = "reps",
    order   = 41,
    help    = "Summarize reputation progress.",
    handler = function()
        local counts = Reputations.Summary()

        if counts.account + counts.character == 0 then
            Print("No reputation data yet. Run /cn repscan.")
            return
        end

        Print("Account-wide factions: " .. counts.account)
        Print("Character-specific factions: " .. counts.character)
        Print("Renown factions: " .. counts.renown
            .. " (" .. counts.maxedRenown .. " maxed)")
        Print("Exalted: " .. counts.exalted)

        if counts.paragonPending > 0 then
            Print("Paragon rewards waiting: |cff00ff00" .. counts.paragonPending .. "|r")
        end
    end,
}

CN:RegisterCommand{
    name    = "rep",
    args    = "<factionID or name>",
    order   = 42,
    help    = "Show one faction's standing and scope.",
    handler = function(args)
        if args == "" then
            Print("Usage: /cn rep <factionID or name>")
            return
        end

        local factionID, matches = Reputations.Resolve(args)

        if not factionID then
            Print("No known faction matches: " .. args)
            Print("Run /cn repscan first if you have not this session.")
            return
        end

        local record, scope = Reputations.Get(factionID)

        if not record then
            Print("No standing recorded for faction " .. factionID .. ".")
            return
        end

        Print(record.name .. " |cff999999(" .. factionID .. ")|r")
        Print("Standing: " .. tostring(record.standing)
            .. " - " .. tostring(record.current) .. "/" .. tostring(record.maximum))
        Print("Scope: " .. (record.accountWide
            and "|cff00ff00account-wide (Warband)|r"
            or "|cffffff00character-specific|r"))

        if record.kind == "RENOWN" then
            Print("Renown: " .. tostring(record.renown)
                .. (record.maxedOut and " |cff00ff00(maximum)|r" or ""))
        end

        if record.paragon then
            Print("Paragon: " .. tostring(record.paragon.value)
                .. "/" .. tostring(record.paragon.threshold)
                .. (record.paragon.pending and " |cff00ff00REWARD READY|r" or ""))
        end

        if scope == "character" then
            local bestKey, bestRecord = Reputations.BestCharacterFor(factionID)

            if bestKey and bestKey ~= CN.characterKey and bestRecord then
                Print("Best character: " .. bestKey
                    .. " (" .. tostring(bestRecord.standing) .. ")")
            end
        end

        if matches and #matches > 1 then
            Print("|cff999999" .. (#matches - 1) .. " other name match(es); use the ID to be exact.|r")
        end
    end,
}

CN:RegisterCommand{
    name    = "paragon",
    order   = 43,
    help    = "List Paragon rewards ready to collect.",
    handler = function()
        local found = 0

        local function report(store, scopeLabel)
            for factionID, record in pairs(store) do
                if record.paragon and record.paragon.pending then
                    Print(record.name .. " |cff999999(" .. scopeLabel .. ")|r"
                        .. " - reward ready")
                    found = found + 1
                end
            end
        end

        report(AccountStore(), "account")

        local characterStore = CharacterStore()

        if characterStore then
            report(characterStore, "character")
        end

        if found == 0 then
            Print("No Paragon rewards are waiting.")
        end
    end,
}

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
'@

$Embedded['Modules\Achievements.lua'] = @'
-- Modules/Achievements.lua
-- Completion Navigator :: achievements and their criteria.
--
-- Achievements are account-wide in retail, so completion lives in account
-- storage. Only incomplete achievements are stored in detail: keeping a row
-- for all ~3000 completed ones would triple the SavedVariables file to say
-- something the client can answer instantly.
--
-- The useful signal here is *near-completion*: an achievement sitting at
-- 9 of 10 criteria is worth far more attention than one at 0 of 10, and
-- nothing else in the addon surfaces that.

local ADDON_NAME, CN = ...

local Achievements = CN:RegisterModule("Achievements")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

-- wipe() is a WoW global; not relying on it keeps this file testable
-- outside the client.
local function Wipe(tbl)
    for key in pairs(tbl) do
        tbl[key] = nil
    end
end

local function Store()
    return CN.Account("achievements")
end

local function Totals()
    return CN.Account("achievementTotals")
end

Achievements.Store = Store

------------------------------------------------------------
-- SCAN
------------------------------------------------------------

-- Walking every category is a few thousand calls. That is fine on demand,
-- but it must never run on a frequent event.
function Achievements.Scan()
    if not GetCategoryList then
        return 0, 0, 0
    end

    local store  = Store()
    local totals = Totals()

    Wipe(store)

    local scanned, completed, nearlyDone = 0, 0, 0

    for _, categoryID in ipairs(Blizzard.GetAchievementCategories()) do
        local total, categoryCompleted = Blizzard.GetCategoryCounts(categoryID)

        totals[categoryID] = {
            total     = total,
            completed = categoryCompleted,
            lastSeen  = time(),
        }

        for index = 1, total do
            local achievement = Blizzard.GetAchievementInCategory(categoryID, index)

            if achievement then
                scanned = scanned + 1

                if achievement.completed then
                    completed = completed + 1
                else
                    local done, criteria =
                        Blizzard.GetAchievementProgress(achievement.achievementID)

                    -- Store only what is unfinished, and only if there is
                    -- real progress or it is small enough to be actionable.
                    if criteria == 0 or done > 0 then
                        store[achievement.achievementID] = {
                            achievementID = achievement.achievementID,
                            name          = achievement.name,
                            points        = achievement.points,
                            categoryID    = categoryID,
                            done          = done,
                            criteria      = criteria,
                            lastSeen      = time(),
                        }

                        if criteria > 0 and done >= criteria - 2 then
                            nearlyDone = nearlyDone + 1
                        end
                    end
                end
            end
        end
    end

    CN.Account("collectionScans").achievements = time()

    return scanned, completed, nearlyDone
end

------------------------------------------------------------
-- SUMMARY
------------------------------------------------------------

function Achievements.Summary()
    local total, completed = Blizzard.GetAchievementTotals()

    local counts = {
        total       = total,
        completed   = completed,
        inProgress  = 0,
        nearlyDone  = 0,
        pointsLeft  = 0,
    }

    for _, record in pairs(Store()) do
        counts.inProgress = counts.inProgress + 1
        counts.pointsLeft = counts.pointsLeft + (record.points or 0)

        if record.criteria > 0 and record.done >= record.criteria - 2 then
            counts.nearlyDone = counts.nearlyDone + 1
        end
    end

    return counts
end

-- Incomplete achievements sorted by how close they are to finishing.
function Achievements.Closest(limit)
    local rows = {}

    for _, record in pairs(Store()) do
        if record.criteria and record.criteria > 0 and record.done > 0 then
            table.insert(rows, record)
        end
    end

    table.sort(rows, function(a, b)
        local aLeft = a.criteria - a.done
        local bLeft = b.criteria - b.done

        if aLeft == bLeft then
            return (a.name or "") < (b.name or "")
        end

        return aLeft < bLeft
    end)

    local results = {}

    for index = 1, math.min(limit or 10, #rows) do
        table.insert(results, rows[index])
    end

    return results
end

function Achievements.Resolve(text)
    local achievementID = CN.ToID(text)

    if achievementID then
        return achievementID
    end

    if not text or text == "" then
        return nil
    end

    local needle  = string.lower(text)
    local matches = {}

    for id, record in pairs(Store()) do
        if record.name and string.find(string.lower(record.name), needle, 1, true) then
            table.insert(matches, { id = id, name = record.name })
        end
    end

    if #matches == 0 then
        return nil
    end

    table.sort(matches, function(a, b) return #a.name < #b.name end)

    return matches[1].id
end

------------------------------------------------------------
-- ELIGIBILITY
------------------------------------------------------------

CN.RegisterEligibilityChecker(CN.objectiveTypes.ACHIEVEMENT, function(achievementID)
    local states = CN.objectiveStates
    local record = Store()[achievementID]

    if not record then
        -- Absent from the incomplete store means either completed or never
        -- scanned. Ask the client rather than guessing.
        local info = GetAchievementInfo and select(4, GetAchievementInfo(achievementID))

        if info then
            return states.COMPLETED, "Already earned", nil
        end

        return states.UNKNOWN, "No achievement data; run /cn achievescan", nil
    end

    return states.AVAILABLE, nil, nil
end)

------------------------------------------------------------
-- CANDIDATES
------------------------------------------------------------

-- Only near-complete achievements become candidates. A zero-progress
-- achievement is a project, not a next action, and flooding the
-- recommendation list with thousands of them would bury everything else.
CN.RegisterCandidateProvider("Achievements", function()
    local candidates = {}

    for achievementID, record in pairs(Store()) do
        local remaining = (record.criteria or 0) - (record.done or 0)

        if record.criteria and record.criteria > 0
            and remaining > 0 and remaining <= 2
            and not CN.IsIgnored(CN.objectiveTypes.ACHIEVEMENT, achievementID)
            and not CN.IsDeferred(CN.objectiveTypes.ACHIEVEMENT, achievementID) then

            table.insert(candidates, CN.NewObjective({
                id              = achievementID,
                type            = CN.objectiveTypes.ACHIEVEMENT,
                name            = record.name,
                accountWide     = true,
                completionValue = 3 - remaining,
                reasons         = {
                    remaining .. " of " .. record.criteria .. " criteria left",
                    record.points .. " achievement points",
                },
            }))
        end
    end

    return candidates
end)

------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

CN:RegisterEvent("ACHIEVEMENT_EARNED", function(event, achievementID)
    if achievementID then
        Store()[achievementID] = nil

        DebugPrint("Achievement earned: " .. tostring(achievementID))
    end
end)

-- Criteria updates fire constantly during play. Refresh the tracked rows
-- rather than rescanning thousands of achievements, and throttle even that.
local lastCriteriaSweep = 0

CN:RegisterEvent("CRITERIA_UPDATE", function()
    local now = time()

    if now - lastCriteriaSweep < 5 then
        return
    end

    lastCriteriaSweep = now

    local store = Store()

    for achievementID, record in pairs(store) do
        if record.criteria and record.criteria > 0 then
            local done = Blizzard.GetAchievementProgress(achievementID)

            if done ~= record.done then
                record.done     = done
                record.lastSeen = time()
            end
        end
    end
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "achievescan",
    order   = 64,
    help    = "Scan every achievement category.",
    handler = function()
        Print("Scanning achievements; this takes a moment.")

        local scanned, completed, nearlyDone = Achievements.Scan()

        Print("Scanned " .. scanned .. " achievements.")
        Print("Completed: " .. completed)
        Print("Within two criteria of finishing: " .. nearlyDone)
    end,
}

CN:RegisterCommand{
    name    = "achievements",
    aliases = { "achieve" },
    order   = 65,
    help    = "Summarize achievement progress.",
    handler = function()
        local counts = Achievements.Summary()

        if counts.total == 0 and counts.inProgress == 0 then
            Print("No achievement data yet. Run /cn achievescan.")
            return
        end

        Print("Achievements: " .. counts.completed .. " / " .. counts.total
            .. string.format(" (%.1f%%)",
                counts.total > 0 and (counts.completed / counts.total * 100) or 0))

        Print("Tracked in progress: " .. counts.inProgress)
        Print("Within two criteria of finishing: " .. counts.nearlyDone)

        local closest = Achievements.Closest(5)

        for _, record in ipairs(closest) do
            Print("  " .. record.name .. " |cff999999("
                .. record.done .. "/" .. record.criteria .. ")|r")
        end
    end,
}

CN:RegisterCommand{
    name    = "closest",
    args    = "[count]",
    order   = 66,
    help    = "List the achievements closest to completion.",
    handler = function(args)
        local limit   = CN.ToID(args) or 10
        local closest = Achievements.Closest(limit)

        if #closest == 0 then
            Print("No achievements in progress. Run /cn achievescan.")
            return
        end

        for index, record in ipairs(closest) do
            Print(index .. ". " .. record.name .. " |cff999999("
                .. record.done .. "/" .. record.criteria .. ", "
                .. record.points .. " points)|r")
        end
    end,
}
'@

$Embedded['Modules\Pets.lua'] = @'
-- Modules/Pets.lua
-- Completion Navigator :: battle pet collection.
--
-- Pets are account-wide, so everything here lives in account storage. The
-- journal is filtered by whatever the player last set in the UI, which is
-- why the scan widens the filters and restores them afterwards.

local ADDON_NAME, CN = ...

local Pets = CN:RegisterModule("Pets")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

------------------------------------------------------------
-- STORAGE
------------------------------------------------------------

local function Store()
    return CN.Account("pets")
end

Pets.Store = Store

------------------------------------------------------------
-- SCAN
------------------------------------------------------------

function Pets.Scan()
    if not C_PetJournal then
        return 0, 0, 0
    end

    local store = Store()

    local seen, owned, missing = 0, 0, 0

    Blizzard.WithAllPetsShown(function()
        local total = select(1, Blizzard.GetNumPets())

        for index = 1, total do
            local pet = Blizzard.GetPetByIndex(index)

            if pet and pet.speciesID then
                local collected, limit = Blizzard.GetPetCollectedCount(pet.speciesID)

                local existing = store[pet.speciesID]

                store[pet.speciesID] = {
                    speciesID  = pet.speciesID,
                    name       = pet.name,
                    petType    = pet.petType,
                    isWild     = pet.isWild,
                    canBattle  = pet.canBattle,
                    obtainable = pet.obtainable,
                    collected  = (collected or 0) > 0,
                    count      = collected or 0,
                    limit      = limit or 3,
                    firstSeen  = existing and existing.firstSeen or time(),
                    lastSeen   = time(),
                }

                seen = seen + 1

                if (collected or 0) > 0 then
                    owned = owned + 1
                elseif pet.obtainable then
                    missing = missing + 1
                end
            end
        end
    end)

    CN.Account("collectionScans").pets = time()

    return seen, owned, missing
end

------------------------------------------------------------
-- SUMMARY
------------------------------------------------------------

function Pets.Summary()
    local store = Store()

    local counts = {
        known       = 0,
        collected   = 0,
        missing     = 0,
        unobtainable = 0,
        wildMissing = 0,
        maxed       = 0,
    }

    for _, record in pairs(store) do
        counts.known = counts.known + 1

        if record.collected then
            counts.collected = counts.collected + 1

            if record.count and record.limit and record.count >= record.limit then
                counts.maxed = counts.maxed + 1
            end
        elseif record.obtainable == false then
            counts.unobtainable = counts.unobtainable + 1
        else
            counts.missing = counts.missing + 1

            if record.isWild then
                counts.wildMissing = counts.wildMissing + 1
            end
        end
    end

    return counts
end

------------------------------------------------------------
-- LOOKUP
------------------------------------------------------------

function Pets.Resolve(text)
    local speciesID = CN.ToID(text)

    if speciesID and Store()[speciesID] then
        return speciesID
    end

    if not text or text == "" then
        return nil
    end

    local needle  = string.lower(text)
    local matches = {}

    for id, record in pairs(Store()) do
        if record.name and string.find(string.lower(record.name), needle, 1, true) then
            table.insert(matches, { id = id, name = record.name })
        end
    end

    if #matches == 0 then
        return nil
    end

    table.sort(matches, function(a, b) return #a.name < #b.name end)

    return matches[1].id, matches
end

------------------------------------------------------------
-- ELIGIBILITY
------------------------------------------------------------

CN.RegisterEligibilityChecker(CN.objectiveTypes.PET, function(speciesID)
    local states = CN.objectiveStates
    local record = Store()[speciesID]

    if not record then
        return states.UNKNOWN, "No pet data; run /cn petscan", nil
    end

    if record.collected then
        return states.COMPLETED, "Already collected", record.name
    end

    if record.obtainable == false then
        return states.UNOBTAINABLE, CN.blockReasons.UNOBTAINABLE, record.name
    end

    return states.AVAILABLE, nil, nil
end)

------------------------------------------------------------
-- CANDIDATES
------------------------------------------------------------

-- Wild pets are the only ones this addon can currently point at, because a
-- wild pet's location is a zone rather than a vendor or a boss drop. Vendor
-- and drop sources need the static database.
CN.RegisterCandidateProvider("Pets", function()
    local candidates = {}

    for speciesID, record in pairs(Store()) do
        if not record.collected
            and record.obtainable ~= false
            and not CN.IsIgnored(CN.objectiveTypes.PET, speciesID)
            and not CN.IsDeferred(CN.objectiveTypes.PET, speciesID) then

            local reasons = {}
            local value   = 1

            if record.isWild then
                value = value + 1
                table.insert(reasons, "wild pet, catchable in the world")
            end

            table.insert(candidates, CN.NewObjective({
                id              = speciesID,
                type            = CN.objectiveTypes.PET,
                name            = record.name,
                accountWide     = true,
                completionValue = value,
                reasons         = reasons,
            }))
        end
    end

    return candidates
end)

------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

local lastScan = 0

CN:RegisterEvent("NEW_PET_ADDED", function()
    lastScan = 0
    Pets.Scan()
    DebugPrint("Pet added; journal rescanned.")
end)

CN:RegisterEvent("PET_JOURNAL_LIST_UPDATE", function()
    local now = time()

    if now - lastScan < 30 then
        return
    end

    lastScan = now

    local seen = Pets.Scan()

    DebugPrint("Pet journal scan: " .. seen .. " species.")
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "petscan",
    order   = 50,
    help    = "Scan the pet journal.",
    handler = function()
        local seen, owned, missing = Pets.Scan()

        Print("Scanned " .. seen .. " pet species.")
        Print("Collected: " .. owned .. "   Missing: " .. missing)
    end,
}

CN:RegisterCommand{
    name    = "pets",
    order   = 51,
    help    = "Summarize battle pet collection.",
    handler = function()
        local counts = Pets.Summary()

        if counts.known == 0 then
            Print("No pet data yet. Run /cn petscan.")
            return
        end

        Print("Pets known to the journal: " .. counts.known)
        Print("Collected: " .. counts.collected .. " (" .. counts.maxed .. " at max count)")
        Print("Missing and obtainable: " .. counts.missing
            .. " (" .. counts.wildMissing .. " wild)")

        if counts.unobtainable > 0 then
            Print("Missing but unobtainable: " .. counts.unobtainable)
        end
    end,
}

CN:RegisterCommand{
    name    = "pet",
    args    = "<speciesID or name>",
    order   = 52,
    help    = "Show one pet's collection state.",
    handler = function(args)
        if args == "" then
            Print("Usage: /cn pet <speciesID or name>")
            return
        end

        local speciesID = Pets.Resolve(args)

        if not speciesID then
            Print("No known pet matches: " .. args)
            return
        end

        local record = Store()[speciesID]

        Print(record.name .. " |cff999999(" .. speciesID .. ")|r")
        Print("Collected: " .. CN.YesNo(record.collected)
            .. (record.collected and (" (" .. record.count .. "/" .. record.limit .. ")") or ""))
        Print("Wild: " .. CN.YesNo(record.isWild)
            .. "   Battle pet: " .. CN.YesNo(record.canBattle))

        if record.obtainable == false then
            Print("|cffff4444Currently unobtainable.|r")
        end
    end,
}
'@

$Embedded['Modules\Mounts.lua'] = @'
-- Modules/Mounts.lua
-- Completion Navigator :: mount collection.
--
-- Mounts are account-wide, but a mount can be faction-locked or hidden on
-- the current character. Both matter for "which character should get this",
-- so both are recorded rather than filtered away at scan time.

local ADDON_NAME, CN = ...

local Mounts = CN:RegisterModule("Mounts")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

------------------------------------------------------------
-- STORAGE
------------------------------------------------------------

local function Store()
    return CN.Account("mounts")
end

Mounts.Store = Store

------------------------------------------------------------
-- SCAN
------------------------------------------------------------

function Mounts.Scan()
    if not C_MountJournal then
        return 0, 0, 0
    end

    local store = Store()

    local seen, collected, missing = 0, 0, 0

    for _, mountID in ipairs(Blizzard.GetMountIDs()) do
        local mount = Blizzard.GetMountByID(mountID)

        if mount then
            local existing = store[mountID]

            store[mountID] = {
                mountID           = mountID,
                name              = mount.name,
                spellID           = mount.spellID,
                sourceType        = mount.sourceType,
                source            = mount.source,
                isFactionSpecific = mount.isFactionSpecific,
                faction           = mount.faction,
                collected         = mount.isCollected,
                firstSeen         = existing and existing.firstSeen or time(),
                lastSeen          = time(),
            }

            seen = seen + 1

            if mount.isCollected then
                collected = collected + 1
            else
                missing = missing + 1
            end
        end
    end

    CN.Account("collectionScans").mounts = time()

    return seen, collected, missing
end

------------------------------------------------------------
-- ELIGIBILITY
------------------------------------------------------------

-- faction is 0 for Horde and 1 for Alliance in the mount journal.
local FACTION_NAMES = { [0] = "Horde", [1] = "Alliance" }

function Mounts.IsUsableByCharacter(record, character)
    if not record.isFactionSpecific then
        return true
    end

    character = character or CN.character

    if not character or not character.faction then
        return true
    end

    return FACTION_NAMES[record.faction] == character.faction
end

CN.RegisterEligibilityChecker(CN.objectiveTypes.MOUNT, function(mountID)
    local states = CN.objectiveStates
    local record = Store()[mountID]

    if not record then
        return states.UNKNOWN, "No mount data; run /cn mountscan", nil
    end

    if record.collected then
        return states.COMPLETED, "Already collected", record.name
    end

    if not Mounts.IsUsableByCharacter(record) then
        return states.REQUIRES_OTHER_CHARACTER,
               CN.blockReasons.WRONG_FACTION,
               FACTION_NAMES[record.faction] or "the other faction"
    end

    return states.AVAILABLE, nil, nil
end)

------------------------------------------------------------
-- SUMMARY
------------------------------------------------------------

function Mounts.Summary()
    local counts = {
        known        = 0,
        collected    = 0,
        missing      = 0,
        wrongFaction = 0,
    }

    for _, record in pairs(Store()) do
        counts.known = counts.known + 1

        if record.collected then
            counts.collected = counts.collected + 1
        else
            counts.missing = counts.missing + 1

            if not Mounts.IsUsableByCharacter(record) then
                counts.wrongFaction = counts.wrongFaction + 1
            end
        end
    end

    return counts
end

------------------------------------------------------------
-- LOOKUP
------------------------------------------------------------

function Mounts.Resolve(text)
    local mountID = CN.ToID(text)

    if mountID and Store()[mountID] then
        return mountID
    end

    if not text or text == "" then
        return nil
    end

    local needle  = string.lower(text)
    local matches = {}

    for id, record in pairs(Store()) do
        if record.name and string.find(string.lower(record.name), needle, 1, true) then
            table.insert(matches, { id = id, name = record.name })
        end
    end

    if #matches == 0 then
        return nil
    end

    table.sort(matches, function(a, b) return #a.name < #b.name end)

    return matches[1].id, matches
end

------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

CN:RegisterEvent("NEW_MOUNT_ADDED", function()
    Mounts.Scan()
    DebugPrint("Mount added; journal rescanned.")
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "mountscan",
    order   = 53,
    help    = "Scan the mount journal.",
    handler = function()
        local seen, collected, missing = Mounts.Scan()

        Print("Scanned " .. seen .. " mounts.")
        Print("Collected: " .. collected .. "   Missing: " .. missing)
    end,
}

CN:RegisterCommand{
    name    = "mounts",
    order   = 54,
    help    = "Summarize mount collection.",
    handler = function()
        local counts = Mounts.Summary()

        if counts.known == 0 then
            Print("No mount data yet. Run /cn mountscan.")
            return
        end

        Print("Mounts known to the journal: " .. counts.known)
        Print("Collected: " .. counts.collected .. "   Missing: " .. counts.missing)

        if counts.wrongFaction > 0 then
            Print("Missing and locked to the other faction: " .. counts.wrongFaction)
        end
    end,
}

CN:RegisterCommand{
    name    = "mount",
    args    = "<mountID or name>",
    order   = 55,
    help    = "Show one mount's collection state.",
    handler = function(args)
        if args == "" then
            Print("Usage: /cn mount <mountID or name>")
            return
        end

        local mountID = Mounts.Resolve(args)

        if not mountID then
            Print("No known mount matches: " .. args)
            return
        end

        local record = Store()[mountID]

        Print(record.name .. " |cff999999(" .. mountID .. ")|r")
        Print("Collected: " .. CN.YesNo(record.collected))

        if record.source and record.source ~= "" then
            Print("Source: " .. record.source:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
        end

        if record.isFactionSpecific then
            Print("Faction: " .. (FACTION_NAMES[record.faction] or "unknown")
                .. (Mounts.IsUsableByCharacter(record) and "" or " |cffff4444(not this character)|r"))
        end
    end,
}
'@

$Embedded['Modules\Toys.lua'] = @'
-- Modules/Toys.lua
-- Completion Navigator :: toy box.
--
-- Account-wide. The toy box, like the pet journal, only reports what the
-- player's current filters allow, so the scan widens them first.

local ADDON_NAME, CN = ...

local Toys = CN:RegisterModule("Toys")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

local function Store()
    return CN.Account("toys")
end

Toys.Store = Store

------------------------------------------------------------
-- SCAN
------------------------------------------------------------

function Toys.Scan()
    if not C_ToyBox then
        return 0, 0, 0
    end

    local store = Store()

    local seen, collected, missing = 0, 0, 0

    Blizzard.WithAllToysShown(function()
        local total = Blizzard.GetNumToys()

        for index = 1, total do
            local toy = Blizzard.GetToyByIndex(index)

            if toy and toy.itemID then
                local existing = store[toy.itemID]

                store[toy.itemID] = {
                    itemID    = toy.itemID,
                    name      = toy.name,
                    collected = toy.collected,
                    firstSeen = existing and existing.firstSeen or time(),
                    lastSeen  = time(),
                }

                seen = seen + 1

                if toy.collected then
                    collected = collected + 1
                else
                    missing = missing + 1
                end
            end
        end
    end)

    CN.Account("collectionScans").toys = time()

    return seen, collected, missing
end

------------------------------------------------------------
-- SUMMARY
------------------------------------------------------------

function Toys.Summary()
    local counts = { known = 0, collected = 0, missing = 0 }

    for _, record in pairs(Store()) do
        counts.known = counts.known + 1

        if record.collected then
            counts.collected = counts.collected + 1
        else
            counts.missing = counts.missing + 1
        end
    end

    return counts
end

function Toys.Resolve(text)
    local itemID = CN.ToID(text)

    if itemID and Store()[itemID] then
        return itemID
    end

    if not text or text == "" then
        return nil
    end

    local needle  = string.lower(text)
    local matches = {}

    for id, record in pairs(Store()) do
        if record.name and string.find(string.lower(record.name), needle, 1, true) then
            table.insert(matches, { id = id, name = record.name })
        end
    end

    if #matches == 0 then
        return nil
    end

    table.sort(matches, function(a, b) return #a.name < #b.name end)

    return matches[1].id
end

------------------------------------------------------------
-- ELIGIBILITY
------------------------------------------------------------

CN.RegisterEligibilityChecker(CN.objectiveTypes.TOY, function(itemID)
    local states = CN.objectiveStates
    local record = Store()[itemID]

    if not record then
        return states.UNKNOWN, "No toy data; run /cn toyscan", nil
    end

    if record.collected then
        return states.COMPLETED, "Already collected", record.name
    end

    return states.AVAILABLE, nil, nil
end)

------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

CN:RegisterEvent("NEW_TOY_ADDED", function()
    Toys.Scan()
    DebugPrint("Toy added; toy box rescanned.")
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "toyscan",
    order   = 56,
    help    = "Scan the toy box.",
    handler = function()
        local seen, collected, missing = Toys.Scan()

        Print("Scanned " .. seen .. " toys.")
        Print("Collected: " .. collected .. "   Missing: " .. missing)
    end,
}

CN:RegisterCommand{
    name    = "toys",
    order   = 57,
    help    = "Summarize toy collection.",
    handler = function()
        local counts = Toys.Summary()

        if counts.known == 0 then
            Print("No toy data yet. Run /cn toyscan.")
            return
        end

        Print("Toys known to the toy box: " .. counts.known)
        Print("Collected: " .. counts.collected .. "   Missing: " .. counts.missing)
    end,
}

CN:RegisterCommand{
    name    = "toy",
    args    = "<itemID or name>",
    order   = 58,
    help    = "Show one toy's collection state.",
    handler = function(args)
        if args == "" then
            Print("Usage: /cn toy <itemID or name>")
            return
        end

        local itemID = Toys.Resolve(args)

        if not itemID then
            Print("No known toy matches: " .. args)
            return
        end

        local record = Store()[itemID]

        Print(record.name .. " |cff999999(" .. itemID .. ")|r")
        Print("Collected: " .. CN.YesNo(record.collected))
    end,
}
'@

$Embedded['Modules\Appearances.lua'] = @'
-- Modules/Appearances.lua
-- Completion Navigator :: transmog appearance progress.
--
-- Deliberately category-level rather than item-level. Enumerating every
-- appearance source is tens of thousands of entries and would bloat
-- SavedVariables for no decision-making benefit: the useful question is
-- "which slot am I furthest from finishing", not "which of 40,000 sources
-- do I lack". Per-item work belongs to a wardrobe addon.

local ADDON_NAME, CN = ...

local Appearances = CN:RegisterModule("Appearances")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

local function Store()
    return CN.Account("appearances")
end

Appearances.Store = Store

------------------------------------------------------------
-- SCAN
------------------------------------------------------------

function Appearances.Scan()
    if not C_TransmogCollection then
        return 0
    end

    local store      = Store()
    local categories = Blizzard.GetAppearanceCategories()

    for _, category in ipairs(categories) do
        store[category.categoryID] = {
            categoryID = category.categoryID,
            name       = category.name,
            collected  = category.collected,
            total      = category.total,
            lastSeen   = time(),
        }
    end

    CN.Account("collectionScans").appearances = time()

    return #categories
end

------------------------------------------------------------
-- SUMMARY
------------------------------------------------------------

function Appearances.Summary()
    local counts = {
        categories = 0,
        collected  = 0,
        total      = 0,
        complete   = 0,
    }

    for _, record in pairs(Store()) do
        counts.categories = counts.categories + 1
        counts.collected  = counts.collected + (record.collected or 0)
        counts.total      = counts.total + (record.total or 0)

        if record.total and record.total > 0 and record.collected >= record.total then
            counts.complete = counts.complete + 1
        end
    end

    return counts
end

-- Categories sorted by how many appearances remain, most first.
function Appearances.Remaining()
    local rows = {}

    for _, record in pairs(Store()) do
        local remaining = (record.total or 0) - (record.collected or 0)

        if remaining > 0 then
            table.insert(rows, {
                name      = record.name,
                collected = record.collected,
                total     = record.total,
                remaining = remaining,
            })
        end
    end

    table.sort(rows, function(a, b) return a.remaining > b.remaining end)

    return rows
end

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "appearancescan",
    aliases = { "transmogscan" },
    order   = 59,
    help    = "Scan transmog appearance categories.",
    handler = function()
        local categories = Appearances.Scan()

        Print("Scanned " .. categories .. " appearance categories.")
    end,
}

CN:RegisterCommand{
    name    = "appearances",
    aliases = { "transmog" },
    order   = 60,
    help    = "Summarize transmog appearance progress.",
    handler = function()
        local counts = Appearances.Summary()

        if counts.categories == 0 then
            Print("No appearance data yet. Run /cn appearancescan.")
            return
        end

        Print("Appearances: " .. counts.collected .. " / " .. counts.total
            .. string.format(" (%.1f%%)",
                counts.total > 0 and (counts.collected / counts.total * 100) or 0))

        Print("Categories complete: " .. counts.complete .. " / " .. counts.categories)

        local rows = Appearances.Remaining()

        for index = 1, math.min(5, #rows) do
            local row = rows[index]

            Print("  " .. row.name .. ": " .. row.collected .. " / " .. row.total
                .. " |cff999999(" .. row.remaining .. " left)|r")
        end

        if #rows > 5 then
            Print("  |cff999999... and " .. (#rows - 5) .. " more categories.|r")
        end
    end,
}
'@

$Embedded['Modules\Titles.lua'] = @'
-- Modules/Titles.lua
-- Completion Navigator :: player titles.
--
-- Titles are character-specific, not account-wide: the client's IsTitleKnown
-- answers for the logged-in character only. Storing them per character is
-- what lets the Warband layer say which alt already has one.

local ADDON_NAME, CN = ...

local Titles = CN:RegisterModule("Titles")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

------------------------------------------------------------
-- STORAGE
------------------------------------------------------------

-- Names are shared; known/unknown is per character.
local function NameStore()
    return CN.Account("titleNames")
end

local function CharacterStore(character)
    character = character or CN.character

    if not character then
        return nil
    end

    character.titles = character.titles or {}

    return character.titles
end

Titles.NameStore      = NameStore
Titles.CharacterStore = CharacterStore

------------------------------------------------------------
-- SCAN
------------------------------------------------------------

function Titles.Scan()
    local names = NameStore()
    local mine  = CharacterStore()

    if not mine then
        return 0, 0
    end

    local seen, known = 0, 0

    for _, title in ipairs(Blizzard.GetTitles()) do
        names[title.titleID] = title.name

        mine[title.titleID] = title.known or nil

        seen = seen + 1

        if title.known then
            known = known + 1
        end
    end

    CN.Account("collectionScans").titles = time()

    if CN.character then
        CN.character.titlesKnown = known
    end

    return seen, known
end

------------------------------------------------------------
-- SUMMARY
------------------------------------------------------------

function Titles.Summary()
    local names = NameStore()
    local mine  = CharacterStore() or {}

    local counts = {
        known     = CN.CountKeys(names),
        onThisOne = CN.CountKeys(mine),
        onAccount = 0,
    }

    -- A title counted once if any character has it.
    local anyCharacter = {}

    for _, character in CN.Characters() do
        if character.titles then
            for titleID in pairs(character.titles) do
                anyCharacter[titleID] = true
            end
        end
    end

    counts.onAccount = CN.CountKeys(anyCharacter)

    return counts
end

-- Which characters, if any, already have a title.
function Titles.WhoHas(titleID)
    local holders = {}

    for key, character in CN.Characters() do
        if character.titles and character.titles[titleID] then
            table.insert(holders, key)
        end
    end

    table.sort(holders)

    return holders
end

function Titles.Resolve(text)
    local titleID = CN.ToID(text)

    if titleID and NameStore()[titleID] then
        return titleID
    end

    if not text or text == "" then
        return nil
    end

    local needle  = string.lower(text)
    local matches = {}

    for id, name in pairs(NameStore()) do
        if name and string.find(string.lower(name), needle, 1, true) then
            table.insert(matches, { id = id, name = name })
        end
    end

    if #matches == 0 then
        return nil
    end

    table.sort(matches, function(a, b) return #a.name < #b.name end)

    return matches[1].id
end

------------------------------------------------------------
-- ELIGIBILITY
------------------------------------------------------------

CN.RegisterEligibilityChecker(CN.objectiveTypes.TITLE, function(titleID)
    local states = CN.objectiveStates
    local mine   = CharacterStore()

    if mine and mine[titleID] then
        return states.COMPLETED, "Already earned by this character", NameStore()[titleID]
    end

    local holders = Titles.WhoHas(titleID)

    if #holders > 0 then
        return states.REQUIRES_OTHER_CHARACTER,
               CN.blockReasons.BETTER_CHARACTER,
               table.concat(holders, ", ")
    end

    return states.AVAILABLE, nil, nil
end)

------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

CN:RegisterEvent("KNOWN_TITLES_UPDATE", function()
    local seen, known = Titles.Scan()

    DebugPrint("Title scan: " .. known .. " known of " .. seen .. ".")
end)

CN:OnLogin(function()
    Titles.Scan()
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "titlescan",
    order   = 61,
    help    = "Scan this character's titles.",
    handler = function()
        local seen, known = Titles.Scan()

        Print("Scanned " .. seen .. " titles.")
        Print("Known by this character: " .. known)
    end,
}

CN:RegisterCommand{
    name    = "titles",
    order   = 62,
    help    = "Summarize title progress.",
    handler = function()
        local counts = Titles.Summary()

        if counts.known == 0 then
            Print("No title data yet. Run /cn titlescan.")
            return
        end

        Print("Titles in the game: " .. counts.known)
        Print("Known by this character: " .. counts.onThisOne)
        Print("Known by any character: " .. counts.onAccount)
    end,
}

CN:RegisterCommand{
    name    = "title",
    args    = "<titleID or name>",
    order   = 63,
    help    = "Show which characters have a title.",
    handler = function(args)
        if args == "" then
            Print("Usage: /cn title <titleID or name>")
            return
        end

        local titleID = Titles.Resolve(args)

        if not titleID then
            Print("No known title matches: " .. args)
            return
        end

        Print(NameStore()[titleID] .. " |cff999999(" .. titleID .. ")|r")

        local holders = Titles.WhoHas(titleID)

        if #holders == 0 then
            Print("Not earned by any known character.")
        else
            Print("Earned by: " .. table.concat(holders, ", "))
        end
    end,
}
'@

$Embedded['Modules\Professions.lua'] = @'
-- Modules/Professions.lua
-- Completion Navigator :: professions, skill levels, and recipes.
--
-- Two important constraints shape this module.
--
-- 1. Professions are character-specific. Which alt has Alchemy at what
--    skill is exactly the Warband question, so profession state is stored
--    on the character profile.
--
-- 2. Recipe enumeration ONLY works while a trade skill window is open.
--    C_TradeSkillUI.GetAllRecipeIDs returns nothing otherwise. This is a
--    hard client restriction, not a design choice, so recipes are captured
--    opportunistically whenever the player opens a profession and are then
--    persisted. The addon tells the player which professions it is still
--    waiting to see rather than silently reporting zero.

local ADDON_NAME, CN = ...

local Professions = CN:RegisterModule("Professions")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

------------------------------------------------------------
-- STORAGE
------------------------------------------------------------

local function CharacterStore(character)
    character = character or CN.character

    if not character then
        return nil
    end

    character.professions = character.professions or {}

    return character.professions
end

-- Recipes are keyed by skill line, then recipe ID. Known-ness is per
-- character, so it lives under the character; the recipe's name is shared.
local function RecipeNames()
    return CN.Account("recipeNames")
end

local function CharacterRecipes(character)
    character = character or CN.character

    if not character then
        return nil
    end

    character.recipes = character.recipes or {}

    return character.recipes
end

Professions.CharacterStore   = CharacterStore
Professions.RecipeNames      = RecipeNames
Professions.CharacterRecipes = CharacterRecipes

------------------------------------------------------------
-- PROFESSION SCAN
------------------------------------------------------------

function Professions.Scan()
    local store = CharacterStore()

    if not store then
        return 0
    end

    local lines = Blizzard.GetProfessionSkillLines()

    for _, line in ipairs(lines) do
        local existing = store[line.skillLineID]

        store[line.skillLineID] = {
            skillLineID = line.skillLineID,
            name        = line.name,
            rank        = line.rank,
            maxRank     = line.maxRank,
            recipesSeen = existing and existing.recipesSeen or false,
            lastSeen    = time(),
        }
    end

    if CN.character then
        CN.character.professionsScanned = time()
    end

    return #lines
end

------------------------------------------------------------
-- RECIPE CAPTURE
------------------------------------------------------------

-- Called when a trade skill window is open and ready. Everything about
-- this function is opportunistic by necessity.
function Professions.CaptureOpenProfession()
    if not Blizzard.IsTradeSkillReady() then
        return false, 0, 0
    end

    local skillLineID, professionName = Blizzard.GetOpenTradeSkillLine()

    if not skillLineID then
        return false, 0, 0
    end

    local names    = RecipeNames()
    local mine     = CharacterRecipes()
    local store    = CharacterStore()

    if not mine or not store then
        return false, 0, 0
    end

    local recipeIDs = Blizzard.GetAllRecipeIDs()

    local seen, known = 0, 0

    for _, recipeID in ipairs(recipeIDs) do
        local info = Blizzard.GetRecipeInfo(recipeID)

        if info then
            seen = seen + 1

            if info.name and info.name ~= "" then
                names[recipeID] = info.name
            end

            if info.learned then
                known = known + 1

                mine[recipeID] = skillLineID
            else
                mine[recipeID] = nil
            end
        end
    end

    store[skillLineID] = store[skillLineID] or {
        skillLineID = skillLineID,
        name        = professionName,
    }

    store[skillLineID].recipesSeen  = true
    store[skillLineID].recipeTotal  = seen
    store[skillLineID].recipeKnown  = known
    store[skillLineID].recipesAt    = time()

    CN.Account("collectionScans").recipes = time()

    return true, seen, known
end

------------------------------------------------------------
-- SUMMARY
------------------------------------------------------------

function Professions.Summary(character)
    local store = CharacterStore(character) or {}

    local rows = {}

    for _, record in pairs(store) do
        table.insert(rows, record)
    end

    table.sort(rows, function(a, b) return (a.name or "") < (b.name or "") end)

    return rows
end

-- Professions this character has but whose recipe list has never been seen.
function Professions.AwaitingRecipeCapture(character)
    local waiting = {}

    for _, record in pairs(CharacterStore(character) or {}) do
        if not record.recipesSeen then
            table.insert(waiting, record.name or ("skill line " .. record.skillLineID))
        end
    end

    table.sort(waiting)

    return waiting
end

-- Which characters know a recipe, for the Warband question.
function Professions.WhoKnows(recipeID)
    local holders = {}

    for key, character in CN.Characters() do
        if character.recipes and character.recipes[recipeID] then
            table.insert(holders, key)
        end
    end

    table.sort(holders)

    return holders
end

-- Best character for a profession, by skill rank.
function Professions.BestCharacterFor(skillLineID)
    local bestKey, bestRecord

    for key, character in CN.Characters() do
        local record = character.professions and character.professions[skillLineID]

        if record and (not bestRecord or (record.rank or 0) > (bestRecord.rank or 0)) then
            bestKey    = key
            bestRecord = record
        end
    end

    return bestKey, bestRecord
end

------------------------------------------------------------
-- ELIGIBILITY
------------------------------------------------------------

CN.RegisterEligibilityChecker(CN.objectiveTypes.RECIPE, function(recipeID)
    local states = CN.objectiveStates
    local mine   = CharacterRecipes()

    if mine and mine[recipeID] then
        return states.COMPLETED, "Already known by this character", RecipeNames()[recipeID]
    end

    local holders = Professions.WhoKnows(recipeID)

    if #holders > 0 then
        return states.REQUIRES_OTHER_CHARACTER,
               CN.blockReasons.BETTER_CHARACTER,
               table.concat(holders, ", ")
    end

    return states.UNKNOWN, "No recipe data; open the profession window once", nil
end)

CN.RegisterEligibilityChecker(CN.objectiveTypes.PROFESSION, function(skillLineID)
    local states = CN.objectiveStates
    local store  = CharacterStore()
    local record = store and store[skillLineID]

    if not record then
        local bestKey = Professions.BestCharacterFor(skillLineID)

        if bestKey then
            return states.REQUIRES_OTHER_CHARACTER,
                   CN.blockReasons.MISSING_PROFESSION,
                   bestKey
        end

        return states.INELIGIBLE, CN.blockReasons.MISSING_PROFESSION, nil
    end

    if record.maxRank and record.rank and record.rank >= record.maxRank then
        return states.COMPLETED, "Skill is maxed for this expansion", record.name
    end

    return states.AVAILABLE, nil, nil
end)

------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

CN:RegisterEvent("TRADE_SKILL_SHOW", function()
    -- The list is not populated yet at SHOW; wait for the list update.
    DebugPrint("Trade skill window opened.")
end)

CN:RegisterEvent("TRADE_SKILL_LIST_UPDATE", function()
    local captured, seen, known = Professions.CaptureOpenProfession()

    if captured then
        DebugPrint("Captured " .. seen .. " recipes (" .. known .. " known).")
    end
end)

CN:RegisterEvent("SKILL_LINES_CHANGED", function()
    Professions.Scan()
end)

CN:OnLogin(function()
    Professions.Scan()
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "profscan",
    order   = 70,
    help    = "Rescan this character's professions.",
    handler = function()
        local count = Professions.Scan()

        Print("Found " .. count .. " professions on this character.")

        local waiting = Professions.AwaitingRecipeCapture()

        if #waiting > 0 then
            Print("Recipe lists not captured yet for: " .. table.concat(waiting, ", "))
            Print("Open each profession window once; the client only exposes "
                .. "recipes while that window is open.")
        end
    end,
}

CN:RegisterCommand{
    name    = "professions",
    aliases = { "profs" },
    order   = 71,
    help    = "Show profession skill and recipe counts.",
    handler = function()
        local rows = Professions.Summary()

        if #rows == 0 then
            Print("No professions recorded. Run /cn profscan.")
            return
        end

        for _, record in ipairs(rows) do
            local line = record.name .. ": " .. tostring(record.rank)
                .. " / " .. tostring(record.maxRank)

            if record.recipesSeen then
                line = line .. " |cff999999(" .. tostring(record.recipeKnown)
                    .. " of " .. tostring(record.recipeTotal) .. " recipes)|r"
            else
                line = line .. " |cffffff00(recipes not captured)|r"
            end

            Print(line)
        end

        local waiting = Professions.AwaitingRecipeCapture()

        if #waiting > 0 then
            Print("Open the profession window once for: " .. table.concat(waiting, ", "))
        end
    end,
}

CN:RegisterCommand{
    name    = "recipes",
    order   = 72,
    help    = "Summarize recipe knowledge across the Warband.",
    handler = function()
        local names = RecipeNames()
        local total = CN.CountKeys(names)

        if total == 0 then
            Print("No recipes recorded yet.")
            Print("Open each profession window once with the addon loaded.")
            return
        end

        Print("Recipes seen: " .. total)

        for key, character in CN.Characters() do
            local count = CN.CountKeys(character.recipes)

            if count > 0 then
                Print("  " .. key .. ": " .. count .. " known")
            end
        end
    end,
}

CN:RegisterCommand{
    name    = "recipe",
    args    = "<recipeID or name>",
    order   = 73,
    help    = "Show which characters know a recipe.",
    handler = function(args)
        if args == "" then
            Print("Usage: /cn recipe <recipeID or name>")
            return
        end

        local names    = RecipeNames()
        local recipeID = CN.ToID(args)

        if not recipeID or not names[recipeID] then
            local needle = string.lower(args)

            for id, name in pairs(names) do
                if name and string.find(string.lower(name), needle, 1, true) then
                    recipeID = id
                    break
                end
            end
        end

        if not recipeID or not names[recipeID] then
            Print("No known recipe matches: " .. args)
            return
        end

        Print(names[recipeID] .. " |cff999999(" .. recipeID .. ")|r")

        local holders = Professions.WhoKnows(recipeID)

        if #holders == 0 then
            Print("Not known by any recorded character.")
        else
            Print("Known by: " .. table.concat(holders, ", "))
        end
    end,
}
'@

$Embedded['Modules\Harvest.lua'] = @'
-- Modules/Harvest.lua
-- Completion Navigator :: build the static database from your own play.
--
-- The curated database is the addon's bottleneck: prerequisite forensics,
-- zone percentages and unlock scoring all need quest records that nobody has
-- typed in yet. External providers help only if the player has those addons
-- installed.
--
-- This module needs nothing. Every quest you pick up gets its name, zone,
-- coordinates and level recorded permanently, account-wide. Playing the game
-- fills the database.
--
-- /cn export then emits it as a Data\Quests.lua block, so what you harvest
-- can be committed and shipped to everyone.

local ADDON_NAME, CN = ...

local Harvest = CN:RegisterModule("Harvest")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

local function Store()
    return CN.Account("questHarvest")
end

Harvest.Store = Store

------------------------------------------------------------
-- CAPTURE
------------------------------------------------------------

-- Records everything currently knowable about a quest. Safe to call
-- repeatedly: fields are only filled in, never blanked, because the client
-- answers for a quest in the log and goes quiet once it is turned in.
function Harvest.Capture(questID, reason)
    questID = CN.ToID(questID)

    if not questID then
        return false
    end

    local store  = Store()
    local record = store[questID] or { questID = questID, firstSeen = time() }

    local changed = false

    local function set(field, value)
        if value ~= nil and record[field] == nil then
            record[field] = value
            changed = true
        end
    end

    local quests = CN:GetModule("Quests")

    if quests then
        set("name", quests.GetName(questID, false))
    end

    local mapID, x, y = Blizzard.GetQuestWaypoint(questID)

    set("mapID", mapID)

    if x and y then
        set("x", math.floor(x * 10000 + 0.5) / 10000)
        set("y", math.floor(y * 10000 + 0.5) / 10000)
    end

    if mapID then
        set("zone", Blizzard.GetMapName(mapID))
    end

    -- The level the character was when the quest became available is a
    -- usable lower bound on the quest's own level requirement.
    if record.observedLevel == nil then
        record.observedLevel = UnitLevel("player")
        changed = true
    end

    if CN.character and record.faction == nil then
        record.faction = CN.character.faction
        changed = true
    end

    -- Anything an installed provider knows, captured once so it survives
    -- that addon being uninstalled later.
    if not record.requires then
        local external = CN.QueryQuestDataProviders(questID)

        if external then
            set("name", external.name)
            set("mapID", external.mapID)
            set("x", external.x)
            set("y", external.y)
            set("requiresLevel", external.requiresLevel)

            if external.requires then
                record.requires  = external.requires
                record.requiredBy = external.providers
                changed = true
            end
        end
    end

    record.lastSeen = time()
    record.reason   = record.reason or reason

    store[questID] = record

    if changed then
        DebugPrint("Harvested quest " .. questID
            .. (record.name and (" (" .. record.name .. ")") or ""))
    end

    return changed
end

------------------------------------------------------------
-- INFERRED PREREQUISITES
------------------------------------------------------------

-- When a quest is accepted, every quest completed immediately beforehand in
-- the same zone is a *candidate* prerequisite. This is a correlation, not a
-- fact, so it is stored separately from real prerequisite data and is never
-- fed to the eligibility checker. It exists to make curation quicker: the
-- export marks these as comments for a human to confirm.
local recentTurnIns = {}

function Harvest.NoteTurnIn(questID)
    table.insert(recentTurnIns, 1, { questID = questID, at = time() })

    for index = #recentTurnIns, 6, -1 do
        table.remove(recentTurnIns, index)
    end
end

function Harvest.NoteAccepted(questID)
    local record = Store()[questID]

    if not record then
        return
    end

    local candidates = {}

    for _, entry in ipairs(recentTurnIns) do
        -- Only within a short window; anything older is coincidence.
        if time() - entry.at <= 300 and entry.questID ~= questID then
            table.insert(candidates, entry.questID)
        end
    end

    if #candidates > 0 then
        record.maybeRequires = candidates
    end
end

------------------------------------------------------------
-- SUMMARY
------------------------------------------------------------

function Harvest.Summary()
    local counts = {
        total       = 0,
        named       = 0,
        located     = 0,
        withRequires = 0,
        withGuesses = 0,
    }

    for _, record in pairs(Store()) do
        counts.total = counts.total + 1

        if record.name then counts.named = counts.named + 1 end
        if record.x and record.y then counts.located = counts.located + 1 end
        if record.requires then counts.withRequires = counts.withRequires + 1 end
        if record.maybeRequires then counts.withGuesses = counts.withGuesses + 1 end
    end

    return counts
end

------------------------------------------------------------
-- EXPORT
------------------------------------------------------------

-- Emits harvested rows in the exact shape Data\Quests.lua expects, so the
-- output can be pasted straight in and committed.
function Harvest.BuildExport(onlyLocated)
    local rows = {}

    for questID, record in pairs(Store()) do
        if not onlyLocated or (record.x and record.y) then
            table.insert(rows, record)
        end
    end

    table.sort(rows, function(a, b) return a.questID < b.questID end)

    local lines = {}

    for _, record in ipairs(rows) do
        table.insert(lines, "    [" .. record.questID .. "] = {")

        if record.name then
            table.insert(lines, '        name      = "'
                .. record.name:gsub('"', '\\"') .. '",')
        end

        if record.zone then
            table.insert(lines, '        -- ' .. record.zone)
        end

        if record.mapID then
            table.insert(lines, "        mapID     = " .. record.mapID .. ",")
        end

        if record.x and record.y then
            table.insert(lines, "        x         = " .. record.x .. ",")
            table.insert(lines, "        y         = " .. record.y .. ",")
        end

        if record.requiresLevel then
            table.insert(lines, "        requiresLevel = " .. record.requiresLevel .. ",")
        end

        if record.requires and #record.requires > 0 then
            table.insert(lines, "        requires  = { "
                .. table.concat(record.requires, ", ") .. " },")
        end

        if record.maybeRequires and #record.maybeRequires > 0 then
            table.insert(lines, "        -- unconfirmed, observed order only: requires = { "
                .. table.concat(record.maybeRequires, ", ") .. " },")
        end

        table.insert(lines, "    },")
    end

    return table.concat(lines, "\n"), #rows
end

------------------------------------------------------------
-- EXPORT WINDOW
------------------------------------------------------------

local exportFrame

local function ShowExport(text, count)
    if not exportFrame then
        exportFrame = CN.UI.SafeCreateFrame("Frame", "CompletionNavigatorExportFrame",
            UIParent, "BasicFrameTemplateWithInset")

        exportFrame:SetSize(600, 420)
        exportFrame:SetPoint("CENTER")
        exportFrame:SetMovable(true)
        exportFrame:EnableMouse(true)
        exportFrame:RegisterForDrag("LeftButton")
        exportFrame:SetScript("OnDragStart", exportFrame.StartMoving)
        exportFrame:SetScript("OnDragStop", exportFrame.StopMovingOrSizing)
        exportFrame:SetFrameStrata("DIALOG")

        if exportFrame.TitleText then
            exportFrame.TitleText:SetText("Completion Navigator - Export")
        end

        local scroll = CN.UI.SafeCreateFrame("ScrollFrame", nil, exportFrame,
            "UIPanelScrollFrameTemplate")

        scroll:SetPoint("TOPLEFT", 12, -32)
        scroll:SetPoint("BOTTOMRIGHT", -32, 40)

        local edit = CreateFrame("EditBox", nil, scroll)

        edit:SetMultiLine(true)
        edit:SetFontObject("GameFontHighlightSmall")
        edit:SetWidth(540)
        edit:SetAutoFocus(false)
        edit:SetScript("OnEscapePressed", function() exportFrame:Hide() end)

        scroll:SetScrollChild(edit)

        exportFrame.edit = edit

        local hint = exportFrame:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
        hint:SetPoint("BOTTOMLEFT", 14, 14)
        hint:SetText("Ctrl+A then Ctrl+C, and paste into Data\\Quests.lua")

        table.insert(UISpecialFrames, "CompletionNavigatorExportFrame")
    end

    exportFrame.edit:SetText(text)
    exportFrame.edit:HighlightText()
    exportFrame.edit:SetFocus()
    exportFrame:Show()

    Print("Exported " .. count .. " harvested quests.")
end

------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

CN:RegisterEvent("QUEST_ACCEPTED", function(event, questID)
    Harvest.Capture(questID, "accepted")
    Harvest.NoteAccepted(questID)
end)

CN:RegisterEvent("QUEST_TURNED_IN", function(event, questID)
    -- Capture before noting: the client still answers for it right now, and
    -- stops shortly afterwards.
    Harvest.Capture(questID, "turnedin")
    Harvest.NoteTurnIn(questID)
end)

-- Quests already in the log when the addon loads would otherwise be missed.
CN:OnLogin(function()
    for _, info in ipairs(Blizzard.GetQuestLogEntries()) do
        Harvest.Capture(info.questID, "login")
    end
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "harvest",
    order   = 80,
    help    = "Show what has been harvested from play.",
    handler = function()
        local counts = Harvest.Summary()

        if counts.total == 0 then
            Print("Nothing harvested yet. Pick up and turn in quests with the addon loaded.")
            return
        end

        Print("Harvested quests: " .. counts.total)
        Print("  with names: " .. counts.named)
        Print("  with coordinates: " .. counts.located)
        Print("  with confirmed prerequisites: " .. counts.withRequires)
        Print("  with unconfirmed prerequisite guesses: " .. counts.withGuesses)
        Print("Use |cffffff00/cn export|r to emit them as Data\\Quests.lua rows.")
    end,
}

CN:RegisterCommand{
    name    = "harvestnow",
    order   = 81,
    help    = "Harvest every quest currently in the log.",
    handler = function()
        local captured = 0

        for _, info in ipairs(Blizzard.GetQuestLogEntries()) do
            if Harvest.Capture(info.questID, "manual") then
                captured = captured + 1
            end
        end

        Print("Harvested " .. captured .. " quests from the current log.")
    end,
}

CN:RegisterCommand{
    name    = "export",
    args    = "[all]",
    order   = 82,
    help    = "Emit harvested quests as Data\\Quests.lua rows.",
    handler = function(args)
        local onlyLocated = string.lower(args or "") ~= "all"

        local text, count = Harvest.BuildExport(onlyLocated)

        if count == 0 then
            Print("Nothing to export yet."
                .. (onlyLocated and " Try |cffffff00/cn export all|r to include "
                    .. "quests with no coordinates." or ""))
            return
        end

        ShowExport(text, count)
    end,
}

CN:RegisterCommand{
    name    = "providers",
    order   = 83,
    help    = "Show which external data addons were detected.",
    handler = function()
        Print("Quest data providers:")

        for _, entry in ipairs(CN.questDataOrder) do
            local provider = CN.questDataProviders[entry.name]

            local ok, isAvailable = pcall(provider.IsAvailable)

            local status = (ok and isAvailable)
                and "|cff00ff00available|r"
                or "|cff999999unavailable|r"

            local detail = ""

            if provider.Describe then
                local described, text = pcall(provider.Describe)

                if described and text then
                    detail = " |cff999999(" .. text .. ")|r"
                end
            end

            Print("  " .. entry.name .. ": " .. status .. detail)
        end

        Print("Waypoint providers:")

        for _, entry in ipairs(CN.waypointOrder) do
            local provider = CN.waypointProviders[entry.name]

            local ok, isAvailable = pcall(provider.IsAvailable)

            Print("  " .. entry.name .. ": "
                .. ((ok and isAvailable) and "|cff00ff00available|r" or "|cff999999unavailable|r"))
        end
    end,
}

CN:RegisterCommand{
    name    = "lookup",
    args    = "<questID>",
    order   = 84,
    help    = "Ask every external provider about a quest.",
    handler = function(args)
        local questID = CN.ToID(args)

        if not questID then
            Print("Usage: /cn lookup <questID>")
            return
        end

        local data = CN.QueryQuestDataProviders(questID)

        if not data then
            Print("No external provider knows quest " .. questID .. ".")
            Print("Run |cffffff00/cn providers|r to see what is installed.")
            return
        end

        Print("Quest " .. questID .. " |cff999999via "
            .. table.concat(data.providers or {}, ", ") .. "|r")

        if data.name then Print("  name: " .. data.name) end

        if data.mapID then
            Print("  map: " .. data.mapID
                .. (data.x and string.format(" at %.1f, %.1f", data.x * 100, data.y * 100) or ""))
        end

        if data.requiresLevel then Print("  level: " .. data.requiresLevel) end

        if data.requires then
            Print("  requires: " .. table.concat(data.requires, ", "))
        end
    end,
}

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
'@

$Embedded['Modules\Opportunities.lua'] = @'
-- Modules/Opportunities.lua
-- Completion Navigator :: things that expire.
--
-- The scoring formula gives limitedTimeBonus the heaviest weight of any
-- term (3.0), and until this module existed nothing ever set it. The engine
-- was built to prioritise content that disappears and had no idea what
-- disappears.
--
-- That is the whole point of the module: a world quest with two hours left
-- and a permanent quest in the same zone are not equally urgent, and the
-- recommendation should say so.

local ADDON_NAME, CN = ...

local Opportunities = CN:RegisterModule("Opportunities")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

local HOUR = 3600
local DAY  = 86400

------------------------------------------------------------
-- URGENCY
------------------------------------------------------------

-- Converts "seconds remaining" into the bonus the scorer multiplies by 3.0.
-- Deliberately steep: something with an hour left should dominate, something
-- with three days left should barely register.
function Opportunities.Urgency(secondsLeft)
    if not secondsLeft or secondsLeft <= 0 then
        return 0
    end

    if secondsLeft <= HOUR then
        return 3
    elseif secondsLeft <= 6 * HOUR then
        return 2
    elseif secondsLeft <= DAY then
        return 1.25
    elseif secondsLeft <= 3 * DAY then
        return 0.5
    end

    return 0.25
end

function Opportunities.FormatTimeLeft(seconds)
    if not seconds or seconds <= 0 then
        return "expired"
    end

    if seconds < HOUR then
        return math.floor(seconds / 60) .. "m left"
    end

    if seconds < DAY then
        return math.floor(seconds / HOUR) .. "h left"
    end

    return math.floor(seconds / DAY) .. "d left"
end

------------------------------------------------------------
-- WORLD QUESTS
------------------------------------------------------------

-- World quests are the largest source of expiring content and the addon
-- could not see a single one before this.
function Opportunities.GetWorldQuests(mapID)
    mapID = mapID or select(1, CN.GetPlayerPosition())

    if not mapID then
        return {}
    end

    local results = {}

    for _, task in ipairs(Blizzard.GetWorldQuestsOnMap(mapID)) do
        local questID = task.questID

        if not Blizzard.IsQuestCompletedByCharacter(questID)
            and not CN.IsIgnored(CN.objectiveTypes.QUEST, questID)
            and not CN.IsDeferred(CN.objectiveTypes.QUEST, questID) then

            local secondsLeft = Blizzard.GetQuestTimeLeft(questID)
            local info        = Blizzard.GetWorldQuestInfo(questID)

            table.insert(results, {
                questID     = questID,
                mapID       = task.mapID,
                x           = task.x,
                y           = task.y,
                name        = info.title or CN.GetQuestName(questID) or ("World quest " .. questID),
                tagName     = info.tagName,
                isElite     = info.isElite,
                secondsLeft = secondsLeft,
            })
        end
    end

    table.sort(results, function(a, b)
        return (a.secondsLeft or math.huge) < (b.secondsLeft or math.huge)
    end)

    return results
end

------------------------------------------------------------
-- RESETS
------------------------------------------------------------

function Opportunities.GetResets()
    return {
        daily  = Blizzard.GetSecondsUntilDailyReset(),
        weekly = Blizzard.GetSecondsUntilWeeklyReset(),
    }
end

------------------------------------------------------------
-- WORLD EVENTS
------------------------------------------------------------

-- Calendar reads are relatively expensive and the answer changes daily, not
-- minute to minute.
local eventCache, eventCachedAt = nil, 0

function Opportunities.GetActiveEvents(force)
    if not force and eventCache and (time() - eventCachedAt) < 1800 then
        return eventCache
    end

    local active = {}

    for _, event in ipairs(Blizzard.GetTodaysEvents()) do
        if event.ongoing then
            table.insert(active, event)
        end
    end

    eventCache    = active
    eventCachedAt = time()

    return active
end

------------------------------------------------------------
-- CANDIDATES
------------------------------------------------------------

CN.RegisterCandidateProvider("Opportunities", function()
    local candidates = {}

    local playerMap, playerX, playerY = CN.GetPlayerPosition()

    for _, worldQuest in ipairs(Opportunities.GetWorldQuests(playerMap)) do
        local reasons = {}

        local urgency = Opportunities.Urgency(worldQuest.secondsLeft)

        if worldQuest.secondsLeft then
            table.insert(reasons, "world quest, "
                .. Opportunities.FormatTimeLeft(worldQuest.secondsLeft))
        else
            table.insert(reasons, "world quest")
        end

        if worldQuest.tagName then
            table.insert(reasons, worldQuest.tagName)
        end

        local travel = 0

        if worldQuest.x and worldQuest.y and playerX and playerY
            and worldQuest.mapID == playerMap then

            local dx = worldQuest.x - playerX
            local dy = worldQuest.y - playerY

            travel = math.sqrt((dx * dx) + (dy * dy)) * 10

            table.insert(reasons, "in your current zone")
        elseif worldQuest.mapID ~= playerMap then
            travel = 25
        end

        table.insert(candidates, CN.NewObjective({
            id               = worldQuest.questID,
            type             = CN.objectiveTypes.QUEST,
            name             = worldQuest.name,
            mapID            = worldQuest.mapID,
            x                = worldQuest.x,
            y                = worldQuest.y,
            state            = CN.objectiveStates.AVAILABLE,
            completionValue  = 1,
            limitedTimeBonus = urgency,
            travelCost       = travel,
            expiresIn        = worldQuest.secondsLeft,
            reasons          = reasons,
        }))
    end

    return candidates
end)

------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

CN:RegisterEvent("QUEST_LOG_UPDATE", function()
    -- World quest availability changes constantly; nothing to persist, the
    -- candidate provider reads live each time it is asked.
end)

CN:OnLogin(function()
    -- Warm the calendar so the first /cn events call has data.
    Opportunities.GetActiveEvents(true)
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "now",
    aliases = { "opportunities" },
    order   = 15,
    help    = "Show everything expiring soon.",
    handler = function()
        local resets = Opportunities.GetResets()

        if resets.daily then
            Print("Daily reset: " .. Opportunities.FormatTimeLeft(resets.daily))
        end

        if resets.weekly then
            Print("Weekly reset: " .. Opportunities.FormatTimeLeft(resets.weekly))
        end

        local events = Opportunities.GetActiveEvents()

        if #events > 0 then
            Print("Active events:")

            for _, event in ipairs(events) do
                Print("  " .. event.title)
            end
        end

        local worldQuests = Opportunities.GetWorldQuests()

        if #worldQuests == 0 then
            Print("No world quests available on your current map.")
            return
        end

        Print("World quests here (" .. #worldQuests .. "), soonest to expire:")

        for index = 1, math.min(#worldQuests, 10) do
            local worldQuest = worldQuests[index]

            Print("  " .. index .. ". " .. worldQuest.name
                .. " |cff999999(" .. Opportunities.FormatTimeLeft(worldQuest.secondsLeft)
                .. (worldQuest.tagName and (", " .. worldQuest.tagName) or "") .. ")|r")
        end

        if #worldQuests > 10 then
            Print("  |cff999999... and " .. (#worldQuests - 10) .. " more.|r")
        end
    end,
}

CN:RegisterCommand{
    name    = "events",
    order   = 16,
    help    = "List world events active today.",
    handler = function()
        local events = Opportunities.GetActiveEvents(true)

        if #events == 0 then
            Print("No world events detected as active today.")
            Print("|cff999999The calendar may not have loaded yet; open it once and retry.|r")
            return
        end

        for _, event in ipairs(events) do
            Print("  " .. event.title
                .. " |cff999999(" .. tostring(event.sequenceType) .. ")|r")
        end
    end,
}

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
'@

$Embedded['Modules\Warband.lua'] = @'
-- Modules/Warband.lua
-- Completion Navigator :: which character should do this.
--
-- The per-character data already exists: reputations, titles, professions
-- and recipes are stored on the character that owns them. What was missing
-- is anything that reads across all of them and answers the question the
-- whole design was built around.
--
-- This module also feeds `characterSuitability`, the second scoring term
-- that was weighted in the formula but never set by anything. An objective
-- your current character is poorly suited to should rank below one they can
-- act on now, and the reason should say why.

local ADDON_NAME, CN = ...

local Warband = CN:RegisterModule("Warband")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint

------------------------------------------------------------
-- ROSTER
------------------------------------------------------------

function Warband.Roster()
    local rows = {}

    for key, character in CN.Characters() do
        table.insert(rows, {
            key      = key,
            name     = character.name,
            realm    = character.realm,
            class    = character.class,
            race     = character.race,
            level    = character.level,
            faction  = character.faction,
            spec     = character.specName,
            lastSeen = character.lastSeen,
            isCurrent = (key == CN.characterKey),

            professions  = CN.CountKeys(character.professions),
            recipes      = CN.CountKeys(character.recipes),
            titles       = CN.CountKeys(character.titles),
            reputations  = CN.CountKeys(character.reputations),
        })
    end

    table.sort(rows, function(a, b)
        if (a.level or 0) ~= (b.level or 0) then
            return (a.level or 0) > (b.level or 0)
        end

        return (a.key or "") < (b.key or "")
    end)

    return rows
end

------------------------------------------------------------
-- WHO SHOULD DO THIS
------------------------------------------------------------

-- Answers for any objective type that has per-character state. Returns
-- bestKey, detail, scope -- where scope explains why the answer is what it
-- is, including "account-wide" meaning the question does not apply.
function Warband.WhoShould(objectiveType, id)
    local types = CN.objectiveTypes

    if objectiveType == types.REPUTATION then
        local module = CN:GetModule("Reputations")

        if not module then
            return nil, nil, "no reputation data"
        end

        local bestKey, bestRecord, accountWide = module.BestCharacterFor(id)

        if accountWide then
            return nil, nil, "account-wide"
        end

        if bestKey then
            return bestKey, tostring(bestRecord and bestRecord.standing), "highest standing"
        end

        return nil, nil, "no character has this faction recorded"
    end

    if objectiveType == types.RECIPE then
        local module = CN:GetModule("Professions")

        if not module then
            return nil, nil, "no profession data"
        end

        local holders = module.WhoKnows(id)

        if #holders > 0 then
            return holders[1], table.concat(holders, ", "), "already knows it"
        end

        return nil, nil, "no character knows this recipe"
    end

    if objectiveType == types.TITLE then
        local module = CN:GetModule("Titles")

        if not module then
            return nil, nil, "no title data"
        end

        local holders = module.WhoHas(id)

        if #holders > 0 then
            return holders[1], table.concat(holders, ", "), "already earned it"
        end

        return nil, nil, "no character has this title"
    end

    if objectiveType == types.PROFESSION then
        local module = CN:GetModule("Professions")

        if not module then
            return nil, nil, "no profession data"
        end

        local bestKey, bestRecord = module.BestCharacterFor(id)

        if bestKey then
            return bestKey,
                   tostring(bestRecord and bestRecord.rank) .. " skill",
                   "highest skill"
        end

        return nil, nil, "no character has this profession"
    end

    if objectiveType == types.PET or objectiveType == types.MOUNT
        or objectiveType == types.TOY or objectiveType == types.ACHIEVEMENT
        or objectiveType == types.APPEARANCE then
        return nil, nil, "account-wide"
    end

    return nil, nil, "not tracked per character"
end

------------------------------------------------------------
-- SUITABILITY
------------------------------------------------------------

-- Positive when the logged-in character is the right one, negative when
-- somebody else is. Fed into the scoring formula so recommendations stop
-- pointing at work this character cannot usefully do.
function Warband.Suitability(objectiveType, id)
    local bestKey, detail, scope = Warband.WhoShould(objectiveType, id)

    if scope == "account-wide" or not bestKey then
        return 0, nil
    end

    if bestKey == CN.characterKey then
        return 1, "you are the best character for this"
    end

    return -2, bestKey .. " is better suited (" .. tostring(detail) .. ")"
end

-- Applied to every candidate before scoring, so no module has to remember
-- to do it.
function Warband.Decorate(objective)
    if type(objective) ~= "table" or not objective.type or not objective.id then
        return objective
    end

    if objective.accountWide then
        return objective
    end

    local suitability, reason = Warband.Suitability(objective.type, objective.id)

    if suitability ~= 0 then
        objective.characterSuitability = suitability

        if reason then
            objective.reasons = objective.reasons or {}
            table.insert(objective.reasons, reason)
        end
    end

    return objective
end

CN.RegisterCandidateDecorator("Warband", Warband.Decorate)

------------------------------------------------------------
-- COVERAGE
------------------------------------------------------------

-- What the Warband collectively has, versus what any one character has.
-- This is the number that matters for account completion; a single
-- character's totals understate it.
function Warband.Coverage()
    local professions, recipes, titles = {}, {}, {}

    local characters = 0

    for _, character in CN.Characters() do
        characters = characters + 1

        for skillLineID in pairs(character.professions or {}) do
            professions[skillLineID] = true
        end

        for recipeID in pairs(character.recipes or {}) do
            recipes[recipeID] = true
        end

        for titleID in pairs(character.titles or {}) do
            titles[titleID] = true
        end
    end

    return {
        characters  = characters,
        professions = CN.CountKeys(professions),
        recipes     = CN.CountKeys(recipes),
        titles      = CN.CountKeys(titles),
    }
end

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "warband",
    aliases = { "roster" },
    order   = 17,
    help    = "Show every known character and what they cover.",
    handler = function()
        local rows = Warband.Roster()

        if #rows == 0 then
            Print("No characters recorded yet.")
            return
        end

        Print("Warband (" .. #rows .. " character"
            .. (#rows == 1 and "" or "s") .. "):")

        for _, row in ipairs(rows) do
            local marker = row.isCurrent and "|cff00ff00>|r " or "  "

            Print(marker .. row.key
                .. " |cff999999" .. tostring(row.level) .. " "
                .. tostring(row.class or "?")
                .. (row.faction and (" " .. row.faction) or "") .. "|r")

            Print("      professions " .. row.professions
                .. ", recipes " .. row.recipes
                .. ", titles " .. row.titles
                .. ", reputations " .. row.reputations)
        end

        local coverage = Warband.Coverage()

        Print("Combined coverage: " .. coverage.professions .. " professions, "
            .. coverage.recipes .. " recipes, " .. coverage.titles .. " titles.")

        if #rows == 1 then
            Print("|cffffff00Only one character has been seen. Log in on your alts "
                .. "with the addon loaded to make these comparisons useful.|r")
        end
    end,
}

CN:RegisterCommand{
    name    = "who",
    args    = "<type> <id>",
    order   = 18,
    help    = "Which character should do something. Types: rep, recipe, title, profession.",
    handler = function(args)
        local kind, value = args:match("^(%S+)%s+(.+)$")

        if not kind or not value then
            Print("Usage: /cn who <rep, recipe, title or profession> <id or name>")
            return
        end

        kind = string.lower(kind)

        local types = CN.objectiveTypes

        local map = {
            rep        = types.REPUTATION,
            reputation = types.REPUTATION,
            recipe     = types.RECIPE,
            title      = types.TITLE,
            profession = types.PROFESSION,
            prof       = types.PROFESSION,
        }

        local objectiveType = map[kind]

        if not objectiveType then
            Print("Unknown type: " .. kind)
            Print("Use one of: rep, recipe, title, profession")
            return
        end

        -- Resolve names to IDs through the owning module where possible.
        local id = CN.ToID(value)

        if not id then
            if objectiveType == types.REPUTATION then
                local module = CN:GetModule("Reputations")
                id = module and module.Resolve(value)
            elseif objectiveType == types.TITLE then
                local module = CN:GetModule("Titles")
                id = module and module.Resolve(value)
            end
        end

        if not id then
            Print("Could not resolve: " .. value)
            return
        end

        local bestKey, detail, scope = Warband.WhoShould(objectiveType, id)

        if scope == "account-wide" then
            Print("That is account-wide; any character counts.")
            return
        end

        if not bestKey then
            Print(tostring(scope) .. ".")
            return
        end

        if bestKey == CN.characterKey then
            Print("This character is the best one for it (" .. tostring(detail) .. ").")
        else
            Print("Best character: " .. bestKey .. " |cff999999(" .. tostring(detail) .. ")|r")
        end
    end,
}

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
'@

$Embedded['Modules\Rares.lua'] = @'
-- Modules/Rares.lua
-- Completion Navigator :: rares and treasures.
--
-- Most rare-tracking addons ship a static database of where rares spawn.
-- That answers "where is it", which is only half the question, and it goes
-- stale every patch.
--
-- This module leads with the client's vignette data instead, because a
-- vignette is the one live signal that a rare is *up right now*. Something
-- that exists this minute and may be dead in five is exactly the kind of
-- objective the opportunity scoring was built for.
--
-- Everything seen is also recorded permanently, so the addon accumulates its
-- own spawn database from play -- same approach as quest harvesting, and it
-- never goes stale because it comes from the live game.

local ADDON_NAME, CN = ...

local Rares = CN:RegisterModule("Rares")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

------------------------------------------------------------
-- STORAGE
------------------------------------------------------------

-- Everything ever seen, keyed by vignetteID. Account-wide: where a rare
-- spawns is a fact about the world.
local function Store()
    return CN.Account("rares")
end

-- Which vignettes this character has already dealt with. Rares are usually
-- once-per-character, so this is character state, not account state.
local function CharacterKills(character)
    character = character or CN.character

    if not character then
        return nil
    end

    character.raresKilled = character.raresKilled or {}

    return character.raresKilled
end

Rares.Store          = Store
Rares.CharacterKills = CharacterKills

------------------------------------------------------------
-- LIVE STATE
------------------------------------------------------------

-- Vignettes currently visible, classified and located.
function Rares.GetActive(mapID)
    mapID = mapID or select(1, CN.GetPlayerPosition())

    local active = {}

    for _, vignette in ipairs(Blizzard.GetVignettes(mapID)) do
        local kind = Blizzard.ClassifyVignette(vignette.atlas)

        if not vignette.isDead then
            table.insert(active, {
                guid       = vignette.guid,
                vignetteID = vignette.vignetteID,
                name       = vignette.name,
                kind       = kind,
                mapID      = vignette.mapID,
                x          = vignette.x,
                y          = vignette.y,
                inFogOfWar = vignette.inFogOfWar,
            })
        end
    end

    table.sort(active, function(a, b)
        if a.kind ~= b.kind then
            return a.kind < b.kind
        end

        return (a.name or "") < (b.name or "")
    end)

    return active
end

------------------------------------------------------------
-- RECORDING
------------------------------------------------------------

function Rares.Record(vignette)
    if not vignette or not vignette.vignetteID then
        return false
    end

    local store    = Store()
    local existing = store[vignette.vignetteID]

    local record = existing or {
        vignetteID = vignette.vignetteID,
        firstSeen  = time(),
        sightings  = 0,
    }

    record.name      = vignette.name or record.name
    record.kind      = vignette.kind or record.kind
    record.lastSeen  = time()
    record.sightings = (record.sightings or 0) + 1

    -- Keep the first coordinates seen; rares roam, and the spawn point is
    -- more useful than wherever it happened to be standing.
    if vignette.mapID and vignette.x and vignette.y then
        if not record.mapID then
            record.mapID = vignette.mapID
            record.x     = math.floor(vignette.x * 10000 + 0.5) / 10000
            record.y     = math.floor(vignette.y * 10000 + 0.5) / 10000
            record.zone  = Blizzard.GetMapName(vignette.mapID)
        end
    end

    store[vignette.vignetteID] = record

    return existing == nil
end

function Rares.Sweep()
    local mapID = select(1, CN.GetPlayerPosition())

    local seen, new = 0, 0

    for _, vignette in ipairs(Rares.GetActive(mapID)) do
        if Rares.Record(vignette) then
            new = new + 1
        end

        seen = seen + 1
    end

    return seen, new
end

------------------------------------------------------------
-- KILL TRACKING
------------------------------------------------------------

-- A vignette that was present and is now gone, while the player was nearby,
-- is very likely dealt with. This is inference, so it is recorded as
-- "cleared by this character" rather than presented as fact.
local lastSeenGuids = {}

function Rares.NoteDisappearances(currentGuids)
    local kills = CharacterKills()

    if not kills then
        return
    end

    for guid, entry in pairs(lastSeenGuids) do
        if not currentGuids[guid] and entry.vignetteID then
            kills[entry.vignetteID] = time()

            DebugPrint("Vignette gone, marking cleared: " .. tostring(entry.name))
        end
    end
end

function Rares.IsClearedByCharacter(vignetteID)
    local kills = CharacterKills()

    return kills and kills[vignetteID] ~= nil
end

------------------------------------------------------------
-- SUMMARY
------------------------------------------------------------

function Rares.Summary()
    local counts = {
        known     = 0,
        rares     = 0,
        treasures = 0,
        located   = 0,
        cleared   = 0,
    }

    local kills = CharacterKills() or {}

    for vignetteID, record in pairs(Store()) do
        counts.known = counts.known + 1

        if record.kind == "TREASURE" then
            counts.treasures = counts.treasures + 1
        else
            counts.rares = counts.rares + 1
        end

        if record.x and record.y then
            counts.located = counts.located + 1
        end

        if kills[vignetteID] then
            counts.cleared = counts.cleared + 1
        end
    end

    return counts
end

------------------------------------------------------------
-- ELIGIBILITY
------------------------------------------------------------

CN.RegisterEligibilityChecker(CN.objectiveTypes.RARE, function(vignetteID)
    local states = CN.objectiveStates
    local record = Store()[vignetteID]

    if not record then
        return states.UNKNOWN, "Never seen this rare", nil
    end

    if Rares.IsClearedByCharacter(vignetteID) then
        return states.COMPLETED, "Cleared by this character", record.name
    end

    return states.AVAILABLE, nil, nil
end)

------------------------------------------------------------
-- CANDIDATES
------------------------------------------------------------

-- Only what is actually up right now becomes a candidate. A rare that is
-- not spawned is not a next action, and the whole point of using vignettes
-- is knowing the difference.
CN.RegisterCandidateProvider("Rares", function()
    local candidates = {}

    local playerMap, playerX, playerY = CN.GetPlayerPosition()

    for _, vignette in ipairs(Rares.GetActive(playerMap)) do
        local objectiveType = vignette.kind == "TREASURE"
            and CN.objectiveTypes.TREASURE
            or CN.objectiveTypes.RARE

        local id = vignette.vignetteID

        if id
            and not Rares.IsClearedByCharacter(id)
            and not CN.IsIgnored(objectiveType, id)
            and not CN.IsDeferred(objectiveType, id) then

            local reasons = {}
            local travel  = 0

            table.insert(reasons, vignette.kind == "TREASURE"
                and "treasure is up right now"
                or "rare is up right now")

            if vignette.x and vignette.y and playerX and playerY then
                local dx = vignette.x - playerX
                local dy = vignette.y - playerY

                travel = math.sqrt((dx * dx) + (dy * dy)) * 10

                table.insert(reasons, "in your current zone")
            end

            table.insert(candidates, CN.NewObjective({
                id               = id,
                type             = objectiveType,
                name             = vignette.name,
                mapID            = vignette.mapID,
                x                = vignette.x,
                y                = vignette.y,
                accountWide      = false,
                state            = CN.objectiveStates.AVAILABLE,
                completionValue  = 2,

                -- Up now, gone when someone else kills it. That is exactly
                -- what the limited-time term is for.
                limitedTimeBonus = 1.5,

                travelCost       = travel,
                reasons          = reasons,
            }))
        end
    end

    return candidates
end)

------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

local function OnVignetteUpdate()
    local mapID = select(1, CN.GetPlayerPosition())

    local currentGuids = {}

    for _, vignette in ipairs(Rares.GetActive(mapID)) do
        currentGuids[vignette.guid] = true

        Rares.Record(vignette)
    end

    Rares.NoteDisappearances(currentGuids)

    -- Rebuild the seen set for the next comparison.
    local nextSeen = {}

    for _, vignette in ipairs(Rares.GetActive(mapID)) do
        nextSeen[vignette.guid] = {
            vignetteID = vignette.vignetteID,
            name       = vignette.name,
        }
    end

    lastSeenGuids = nextSeen
end

CN:RegisterEvent("VIGNETTE_MINIMAP_UPDATED", OnVignetteUpdate)
CN:RegisterEvent("VIGNETTES_UPDATED", OnVignetteUpdate)

CN:RegisterEvent("ZONE_CHANGED_NEW_AREA", function()
    -- Vignettes from the previous zone are meaningless now.
    lastSeenGuids = {}
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "rares",
    order   = 74,
    help    = "Show rares and treasures up right now.",
    handler = function()
        local active = Rares.GetActive()

        if #active == 0 then
            Print("Nothing is up nearby.")
            Print("|cff999999Vignettes only appear for content in range; "
                .. "move around the zone.|r")
            return
        end

        Print("Up right now (" .. #active .. "):")

        for index, vignette in ipairs(active) do
            local cleared = vignette.vignetteID
                and Rares.IsClearedByCharacter(vignette.vignetteID)

            Print("  " .. index .. ". " .. tostring(vignette.name)
                .. " |cff999999[" .. tostring(vignette.kind) .. "]|r"
                .. (cleared and " |cff999999(already cleared)|r" or "")
                .. (vignette.x and string.format(" |cff999999%.1f, %.1f|r",
                    vignette.x * 100, vignette.y * 100) or ""))
        end

        Print("|cffffff00/cn rare <number>|r to set a waypoint.")
    end,
}

CN:RegisterCommand{
    name    = "rare",
    args    = "<number>",
    order   = 75,
    help    = "Navigate to something that is up right now.",
    handler = function(args)
        local index = CN.ToID(args)

        if not index then
            Print("Usage: /cn rare <number from /cn rares>")
            return
        end

        local active = Rares.GetActive()
        local vignette = active[index]

        if not vignette then
            Print("There is no number " .. index .. " in the current list.")
            return
        end

        CN.NavigateToObjective({
            id    = vignette.vignetteID,
            type  = vignette.kind == "TREASURE"
                and CN.objectiveTypes.TREASURE
                or CN.objectiveTypes.RARE,
            name  = vignette.name,
            mapID = vignette.mapID,
            x     = vignette.x,
            y     = vignette.y,
        })
    end,
}

CN:RegisterCommand{
    name    = "raredb",
    order   = 76,
    help    = "Summarize every rare and treasure recorded from play.",
    handler = function()
        local counts = Rares.Summary()

        if counts.known == 0 then
            Print("Nothing recorded yet. Rares and treasures are captured "
                .. "automatically as you encounter them.")
            return
        end

        Print("Recorded: " .. counts.known
            .. " (" .. counts.rares .. " rares, " .. counts.treasures .. " treasures)")
        Print("With coordinates: " .. counts.located)
        Print("Cleared by this character: " .. counts.cleared)
    end,
}

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
'@

$Embedded['Modules\Currencies.lua'] = @'
-- Modules/Currencies.lua
-- Completion Navigator :: currencies, caps, and wasted earning potential.
--
-- A currency total on its own is not a decision. What matters is whether you
-- are at a cap, because a capped currency is earning potential you are
-- throwing away, and a weekly cap you have not filled resets in a few days
-- whether you use it or not.
--
-- Both of those are time-sensitive, which is why this module contributes to
-- the opportunity side of the scoring rather than sitting in a list.

local ADDON_NAME, CN = ...

local Currencies = CN:RegisterModule("Currencies")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

-- Currency quantities are character state; which currencies exist is not.
local function NameStore()
    return CN.Account("currencyNames")
end

local function CharacterStore(character)
    character = character or CN.character

    if not character then
        return nil
    end

    character.currencies = character.currencies or {}

    return character.currencies
end

Currencies.NameStore      = NameStore
Currencies.CharacterStore = CharacterStore

------------------------------------------------------------
-- SCAN
------------------------------------------------------------

function Currencies.Scan()
    local names = NameStore()
    local mine  = CharacterStore()

    if not mine then
        return 0, 0, 0
    end

    local seen, atCap, weeklyRemaining = 0, 0, 0

    for _, currency in ipairs(Blizzard.GetCurrencyList()) do
        if currency.currencyID then
            names[currency.currencyID] = currency.name

            local capped = currency.maxQuantity > 0
                and currency.quantity >= currency.maxQuantity

            local weeklyLeft = 0

            if currency.maxWeeklyQuantity > 0 then
                weeklyLeft = math.max(0,
                    currency.maxWeeklyQuantity - currency.earnedThisWeek)
            end

            mine[currency.currencyID] = {
                currencyID        = currency.currencyID,
                quantity          = currency.quantity,
                maxQuantity       = currency.maxQuantity,
                totalEarned       = currency.totalEarned,
                earnedThisWeek    = currency.earnedThisWeek,
                maxWeeklyQuantity = currency.maxWeeklyQuantity,
                capped            = capped,
                weeklyRemaining   = weeklyLeft,
                lastSeen          = time(),
            }

            seen = seen + 1

            if capped then
                atCap = atCap + 1
            end

            if weeklyLeft > 0 then
                weeklyRemaining = weeklyRemaining + 1
            end
        end
    end

    CN.Account("collectionScans").currencies = time()

    return seen, atCap, weeklyRemaining
end

------------------------------------------------------------
-- QUERIES
------------------------------------------------------------

function Currencies.Capped(character)
    local capped = {}

    for currencyID, record in pairs(CharacterStore(character) or {}) do
        if record.capped then
            table.insert(capped, {
                currencyID = currencyID,
                name       = NameStore()[currencyID],
                quantity   = record.quantity,
                maximum    = record.maxQuantity,
            })
        end
    end

    table.sort(capped, function(a, b) return (a.name or "") < (b.name or "") end)

    return capped
end

function Currencies.WeeklyUnfilled(character)
    local rows = {}

    for currencyID, record in pairs(CharacterStore(character) or {}) do
        if record.weeklyRemaining and record.weeklyRemaining > 0 then
            table.insert(rows, {
                currencyID = currencyID,
                name       = NameStore()[currencyID],
                remaining  = record.weeklyRemaining,
                earned     = record.earnedThisWeek,
                maximum    = record.maxWeeklyQuantity,
            })
        end
    end

    table.sort(rows, function(a, b) return (a.remaining or 0) > (b.remaining or 0) end)

    return rows
end

function Currencies.Summary(character)
    local store = CharacterStore(character) or {}

    return {
        known           = CN.CountKeys(store),
        capped          = #Currencies.Capped(character),
        weeklyUnfilled  = #Currencies.WeeklyUnfilled(character),
    }
end

function Currencies.Resolve(text)
    local currencyID = CN.ToID(text)

    if currencyID and NameStore()[currencyID] then
        return currencyID
    end

    if not text or text == "" then
        return nil
    end

    local needle  = string.lower(text)
    local matches = {}

    for id, name in pairs(NameStore()) do
        if name and string.find(string.lower(name), needle, 1, true) then
            table.insert(matches, { id = id, name = name })
        end
    end

    if #matches == 0 then
        return nil
    end

    table.sort(matches, function(a, b) return #a.name < #b.name end)

    return matches[1].id
end

------------------------------------------------------------
-- CANDIDATES
------------------------------------------------------------

-- A capped currency is not a place to travel to, so these carry no
-- coordinates. They surface as high-priority advisories: stop earning this
-- and go spend it.
CN.RegisterCandidateProvider("Currencies", function()
    local candidates = {}

    for _, currency in ipairs(Currencies.Capped()) do
        if not CN.IsIgnored(CN.objectiveTypes.CURRENCY, currency.currencyID)
            and not CN.IsDeferred(CN.objectiveTypes.CURRENCY, currency.currencyID) then

            table.insert(candidates, CN.NewObjective({
                id               = currency.currencyID,
                type             = CN.objectiveTypes.CURRENCY,
                name             = "Spend " .. tostring(currency.name),
                accountWide      = false,
                completionValue  = 2,
                limitedTimeBonus = 1,
                travelCost       = 0,
                reasons          = {
                    "at cap: " .. tostring(currency.quantity)
                        .. " / " .. tostring(currency.maximum),
                    "further earning is wasted until you spend it",
                },
            }))
        end
    end

    return candidates
end)

------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

local lastScan = 0

CN:RegisterEvent("CURRENCY_DISPLAY_UPDATE", function()
    local now = time()

    if now - lastScan < 10 then
        return
    end

    lastScan = now

    Currencies.Scan()
end)

CN:OnLogin(function()
    Currencies.Scan()
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "currencies",
    aliases = { "currency" },
    order   = 77,
    help    = "Show currency caps and unfilled weekly earning.",
    handler = function()
        local counts = Currencies.Summary()

        if counts.known == 0 then
            Print("No currency data yet. Run /cn currencyscan.")
            return
        end

        Print("Currencies tracked: " .. counts.known)

        local capped = Currencies.Capped()

        if #capped > 0 then
            Print("|cffff4444At cap (" .. #capped .. ") - spend these:|r")

            for _, currency in ipairs(capped) do
                Print("  " .. tostring(currency.name)
                    .. " |cff999999" .. currency.quantity
                    .. " / " .. currency.maximum .. "|r")
            end
        end

        local weekly = Currencies.WeeklyUnfilled()

        if #weekly > 0 then
            Print("Weekly earning still available (" .. #weekly .. "):")

            for index = 1, math.min(#weekly, 8) do
                local currency = weekly[index]

                Print("  " .. tostring(currency.name)
                    .. " |cff999999" .. currency.earned .. " / " .. currency.maximum
                    .. ", " .. currency.remaining .. " left this week|r")
            end
        end

        if #capped == 0 and #weekly == 0 then
            Print("Nothing capped, nothing left to earn this week.")
        end
    end,
}

CN:RegisterCommand{
    name    = "currencyscan",
    order   = 78,
    help    = "Rescan currencies for this character.",
    handler = function()
        local seen, atCap, weekly = Currencies.Scan()

        Print("Scanned " .. seen .. " currencies.")
        Print("At cap: " .. atCap .. "   With weekly earning left: " .. weekly)
    end,
}

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
'@

$Embedded['Modules\Breakdown.lua'] = @'
-- Modules/Breakdown.lua
-- Completion Navigator :: "why isn't this 100%?"
--
-- Every other module answers what it tracks. None of them answer the
-- question a completionist actually asks, which is why a category is not
-- finished and what specifically is in the way.
--
-- Two rules shape this module.
--
-- 1. A percentage is only shown where the denominator is trustworthy. The
--    client knows exactly how many mounts exist; nobody knows how many
--    quests exist. Where the denominator is unknown, counts are shown and
--    the reason is stated, rather than inventing a number that looks
--    authoritative and is not.
--
-- 2. Every line says what to do next, not just what is missing. "4 vendor
--    recipes" is trivia; "4 recipes, open the profession window to see
--    which" is an instruction.

local ADDON_NAME, CN = ...

local Breakdown = CN:RegisterModule("Breakdown")

local Print = CN.Print

-- "1 are locked" reads as a bug even when the number is right.
local function Are(count)
    return count == 1 and "is" or "are"
end

local function Plural(count, singular, plural)
    return count == 1 and singular or (plural or (singular .. "s"))
end

------------------------------------------------------------
-- REGISTRY
------------------------------------------------------------

-- Each category reports: collected, total (or nil when unknowable),
-- remaining lines, and the next action.
Breakdown.categories = {}

function Breakdown.Register(definition)
    if type(definition) ~= "table" or not definition.name then
        return
    end

    definition.order = definition.order or 100

    table.insert(Breakdown.categories, definition)

    table.sort(Breakdown.categories, function(a, b)
        if a.order == b.order then
            return a.name < b.name
        end

        return a.order < b.order
    end)
end

------------------------------------------------------------
-- REPORT
------------------------------------------------------------

local function Percentage(collected, total)
    if not total or total <= 0 then
        return nil
    end

    return collected / total * 100
end

function Breakdown.Report(categoryName)
    local rows = {}

    for _, category in ipairs(Breakdown.categories) do
        if not categoryName
            or string.lower(category.name) == string.lower(categoryName) then

            local ok, result = pcall(category.report)

            if ok and type(result) == "table" then
                result.name  = category.name
                result.order = category.order

                table.insert(rows, result)
            end
        end
    end

    return rows
end

------------------------------------------------------------
-- BUILT-IN CATEGORIES
------------------------------------------------------------

Breakdown.Register{
    name  = "Mounts",
    order = 10,
    report = function()
        local module = CN:GetModule("Mounts")

        if not module then return nil end

        local counts = module.Summary()

        local reasons = {}

        if counts.wrongFaction > 0 then
            table.insert(reasons, counts.wrongFaction .. " " .. Are(counts.wrongFaction)
                .. " locked to the opposite faction")
        end

        return {
            collected = counts.collected,
            total     = counts.known,
            remaining = counts.missing,
            reasons   = reasons,
            action    = counts.known == 0 and "/cn mountscan" or nil,
        }
    end,
}

Breakdown.Register{
    name  = "Pets",
    order = 11,
    report = function()
        local module = CN:GetModule("Pets")

        if not module then return nil end

        local counts = module.Summary()

        local reasons = {}

        if counts.unobtainable > 0 then
            table.insert(reasons, counts.unobtainable .. " " .. Are(counts.unobtainable)
                .. " no longer obtainable and can never be collected")
        end

        if counts.wildMissing > 0 then
            table.insert(reasons, counts.wildMissing .. " " .. Are(counts.wildMissing) .. " "
                .. Plural(counts.wildMissing, "a wild pet", "wild pets")
                .. " you can catch in the world")
        end

        return {
            collected = counts.collected,
            total     = counts.known,
            remaining = counts.missing,
            reasons   = reasons,
            action    = counts.known == 0 and "/cn petscan" or nil,
        }
    end,
}

Breakdown.Register{
    name  = "Toys",
    order = 12,
    report = function()
        local module = CN:GetModule("Toys")

        if not module then return nil end

        local counts = module.Summary()

        return {
            collected = counts.collected,
            total     = counts.known,
            remaining = counts.missing,
            action    = counts.known == 0 and "/cn toyscan" or nil,
        }
    end,
}

Breakdown.Register{
    name  = "Appearances",
    order = 13,
    report = function()
        local module = CN:GetModule("Appearances")

        if not module then return nil end

        local counts = module.Summary()
        local rows   = module.Remaining()

        local reasons = {}

        for index = 1, math.min(3, #rows) do
            table.insert(reasons, rows[index].name .. ": "
                .. rows[index].remaining .. " left")
        end

        return {
            collected = counts.collected,
            total     = counts.total,
            remaining = counts.total - counts.collected,
            reasons   = reasons,
            action    = counts.categories == 0 and "/cn appearancescan" or nil,
        }
    end,
}

Breakdown.Register{
    name  = "Achievements",
    order = 14,
    report = function()
        local module = CN:GetModule("Achievements")

        if not module then return nil end

        local counts = module.Summary()

        local reasons = {}

        if counts.nearlyDone > 0 then
            table.insert(reasons, counts.nearlyDone .. " " .. Are(counts.nearlyDone)
                .. " within two criteria of finishing")
        end

        return {
            collected = counts.completed,
            total     = counts.total,
            remaining = counts.total - counts.completed,
            reasons   = reasons,
            action    = counts.total == 0 and "/cn achievescan"
                or (counts.nearlyDone > 0 and "/cn closest" or nil),
        }
    end,
}

Breakdown.Register{
    name  = "Titles",
    order = 15,
    report = function()
        local module = CN:GetModule("Titles")

        if not module then return nil end

        local counts = module.Summary()

        local reasons = {}

        if counts.onAccount > counts.onThisOne then
            local elsewhere = counts.onAccount - counts.onThisOne

            table.insert(reasons, elsewhere .. " " .. Are(elsewhere)
                .. " held by another character, not this one")
        end

        return {
            collected = counts.onAccount,
            total     = counts.known,
            remaining = counts.known - counts.onAccount,
            reasons   = reasons,
            action    = counts.known == 0 and "/cn titlescan" or nil,
        }
    end,
}

Breakdown.Register{
    name  = "Reputations",
    order = 16,
    report = function()
        local module = CN:GetModule("Reputations")

        if not module then return nil end

        local counts = module.Summary()

        local reasons = {}

        if counts.paragonPending > 0 then
            table.insert(reasons, counts.paragonPending .. " " .. Plural(counts.paragonPending, "has", "have")
                .. " a Paragon reward waiting to be collected")
        end

        if counts.character > 0 then
            table.insert(reasons, counts.character .. " " .. Are(counts.character)
                .. " character-specific, so an alt may be further ahead")
        end

        -- Total factions in the game is not knowable from the client.
        return {
            collected = counts.exalted + counts.maxedRenown,
            total     = nil,
            remaining = nil,
            unknownTotal = "the client does not expose how many factions exist",
            reasons   = reasons,
            action    = (counts.account + counts.character) == 0
                and "/cn repscan"
                or (counts.paragonPending > 0 and "/cn paragon" or nil),
        }
    end,
}

Breakdown.Register{
    name  = "Recipes",
    order = 17,
    report = function()
        local module = CN:GetModule("Professions")

        if not module then return nil end

        local waiting = module.AwaitingRecipeCapture()

        local reasons = {}

        if #waiting > 0 then
            table.insert(reasons, "recipe lists not captured for: "
                .. table.concat(waiting, ", "))
        end

        local known = 0

        for _, record in ipairs(module.Summary()) do
            known = known + (record.recipeKnown or 0)
        end

        return {
            collected    = known,
            total        = nil,
            unknownTotal = "recipes are only countable while a profession window is open",
            reasons      = reasons,
            action       = #waiting > 0 and "open each profession window once" or nil,
        }
    end,
}

Breakdown.Register{
    name  = "Quests",
    order = 18,
    report = function()
        local discovered = CN.CountKeys(CN.Account("discoveredQuests"))

        local completed = 0

        for _, status in pairs(CN.Account("questStatus")) do
            if status.characterCompleted then
                completed = completed + 1
            end
        end

        return {
            collected    = completed,
            total        = nil,
            unknownTotal = "no API reports how many quests exist; "
                .. "only quests this addon has seen can be counted",
            reasons      = {
                discovered .. " quests discovered so far",
                CN.CountKeys(CN.Account("questHarvest")) .. " harvested with location data",
            },
            action = "/cn harvest",
        }
    end,
}

Breakdown.Register{
    name  = "Currencies",
    order = 19,
    report = function()
        local module = CN:GetModule("Currencies")

        if not module then return nil end

        local counts = module.Summary()

        local reasons = {}

        if counts.capped > 0 then
            table.insert(reasons, counts.capped .. " " .. Are(counts.capped)
                .. " at cap; further earning is wasted")
        end

        if counts.weeklyUnfilled > 0 then
            table.insert(reasons, counts.weeklyUnfilled .. " still " .. Plural(counts.weeklyUnfilled, "has", "have")
                .. " weekly earning available")
        end

        return {
            collected    = counts.known - counts.capped,
            total        = nil,
            unknownTotal = "currencies are a state to manage, not a set to complete",
            reasons      = reasons,
            action       = counts.capped > 0 and "/cn currencies" or nil,
        }
    end,
}

------------------------------------------------------------
-- COMMAND
------------------------------------------------------------

local function PrintRow(row)
    local percentage = Percentage(row.collected, row.total)

    if percentage then
        Print(string.format("|cffffd100%s|r  %d / %d  (%.1f%%)",
            row.name, row.collected, row.total, percentage))
    else
        Print(string.format("|cffffd100%s|r  %d collected",
            row.name, row.collected or 0))

        if row.unknownTotal then
            Print("    |cff999999no percentage: " .. row.unknownTotal .. "|r")
        end
    end

    for _, reason in ipairs(row.reasons or {}) do
        Print("    " .. reason)
    end

    if row.action then
        Print("    |cffffff00-> " .. row.action .. "|r")
    end
end

CN:RegisterCommand{
    name    = "breakdown",
    aliases = { "remaining" },
    args    = "[category]",
    order   = 19,
    help    = "Explain what is left in each category, and why.",
    handler = function(args)
        local requested = args ~= "" and args or nil

        local rows = Breakdown.Report(requested)

        if #rows == 0 then
            if requested then
                Print("No category matches: " .. requested)

                local names = {}

                for _, category in ipairs(Breakdown.categories) do
                    table.insert(names, category.name)
                end

                Print("Try: " .. table.concat(names, ", "))
            else
                Print("Nothing to report yet. Run the scans first.")
            end

            return
        end

        Print("What is left, and why:")

        for _, row in ipairs(rows) do
            PrintRow(row)
        end

        if not requested then
            Print("|cff999999/cn breakdown <category> for one at a time.|r")
        end
    end,
}

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
'@

$Embedded['Modules\Exploration.lua'] = @'
-- Modules/Exploration.lua
-- Completion Navigator :: map exploration.
--
-- The map API exposes which overlay textures you have revealed but never how
-- many exist, so a genuine "percent explored" cannot be computed from it.
-- The Exploration achievement category does carry one criterion per subzone,
-- which is the only countable exploration data the client offers -- and each
-- unfinished criterion is the literal name of a place you have not been.
--
-- That turns out to be the more useful shape anyway: "Eversong Woods, 3 of
-- 12 subzones, missing Sunsail Anchorage" is actionable. "78% explored" is
-- not.

local ADDON_NAME, CN = ...

local Exploration = CN:RegisterModule("Exploration")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

local function Store()
    return CN.Account("exploration")
end

Exploration.Store = Store

------------------------------------------------------------
-- SCAN
------------------------------------------------------------

function Exploration.Scan()
    local store = Store()

    local seen, complete = 0, 0

    for _, achievement in ipairs(Blizzard.GetExplorationAchievements()) do
        store[achievement.achievementID] = {
            achievementID = achievement.achievementID,
            name          = achievement.name,
            completed     = achievement.completed,
            done          = achievement.done,
            criteria      = achievement.criteria,
            lastSeen      = time(),
        }

        seen = seen + 1

        if achievement.completed then
            complete = complete + 1
        end
    end

    CN.Account("collectionScans").exploration = time()

    return seen, complete
end

------------------------------------------------------------
-- QUERIES
------------------------------------------------------------

function Exploration.Summary()
    local counts = {
        zones     = 0,
        complete  = 0,
        criteria  = 0,
        done      = 0,
    }

    for _, record in pairs(Store()) do
        counts.zones    = counts.zones + 1
        counts.criteria = counts.criteria + (record.criteria or 0)
        counts.done     = counts.done + (record.done or 0)

        if record.completed then
            counts.complete = counts.complete + 1
        end
    end

    return counts
end

-- Zones with the fewest subzones left, so the cheapest wins come first.
function Exploration.Closest(limit)
    local rows = {}

    for _, record in pairs(Store()) do
        if not record.completed and (record.criteria or 0) > 0 then
            table.insert(rows, {
                achievementID = record.achievementID,
                name          = record.name,
                done          = record.done,
                criteria      = record.criteria,
                remaining     = record.criteria - record.done,
            })
        end
    end

    table.sort(rows, function(a, b)
        if a.remaining == b.remaining then
            return (a.name or "") < (b.name or "")
        end

        return a.remaining < b.remaining
    end)

    local results = {}

    for index = 1, math.min(limit or 10, #rows) do
        table.insert(results, rows[index])
    end

    return results
end

-- The exploration achievement matching the zone the player is standing in,
-- matched on name because no API maps a UiMapID to its achievement.
function Exploration.ForCurrentZone()
    local zone = GetZoneText and GetZoneText()

    if not zone or zone == "" then
        return nil
    end

    local needle = string.lower(zone)

    for _, record in pairs(Store()) do
        if record.name and string.find(string.lower(record.name), needle, 1, true) then
            return record
        end
    end

    return nil
end

------------------------------------------------------------
-- CANDIDATES
------------------------------------------------------------

-- Only the zone the player is already in. Exploration elsewhere is a
-- project, and the criteria carry no coordinates to route to.
CN.RegisterCandidateProvider("Exploration", function()
    local candidates = {}

    local record = Exploration.ForCurrentZone()

    if record and not record.completed and (record.criteria or 0) > 0 then
        local remaining = record.criteria - record.done

        if remaining > 0
            and not CN.IsIgnored(CN.objectiveTypes.EXPLORATION, record.achievementID)
            and not CN.IsDeferred(CN.objectiveTypes.EXPLORATION, record.achievementID) then

            local reasons = {
                remaining .. " subzone" .. (remaining == 1 and "" or "s")
                    .. " left in this zone",
            }

            local missing = Blizzard.GetIncompleteCriteria(record.achievementID, 3)

            if #missing > 0 then
                table.insert(reasons, "missing: " .. table.concat(missing, ", "))
            end

            table.insert(candidates, CN.NewObjective({
                id              = record.achievementID,
                type            = CN.objectiveTypes.EXPLORATION,
                name            = record.name,
                accountWide     = true,
                completionValue = math.max(1, 4 - remaining),
                travelCost      = 0,
                reasons         = reasons,
            }))
        end
    end

    return candidates
end)

------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

CN:RegisterEvent("ZONE_CHANGED_NEW_AREA", function()
    -- Discovering a subzone fires criteria updates; the Achievements module
    -- already throttles those, so only refresh the exploration view.
    local record = Exploration.ForCurrentZone()

    if record then
        local done, criteria = Blizzard.GetAchievementProgress(record.achievementID)

        record.done     = done
        record.criteria = criteria
    end
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "explorescan",
    order   = 67,
    help    = "Scan exploration achievements.",
    handler = function()
        local seen, complete = Exploration.Scan()

        Print("Scanned " .. seen .. " exploration achievements.")
        Print("Complete: " .. complete)
    end,
}

CN:RegisterCommand{
    name    = "exploration",
    aliases = { "explore" },
    args    = "[count]",
    order   = 68,
    help    = "Show zones with the least exploration left.",
    handler = function(args)
        local counts = Exploration.Summary()

        if counts.zones == 0 then
            Print("No exploration data yet. Run /cn explorescan.")
            return
        end

        Print("Exploration: " .. counts.complete .. " / " .. counts.zones .. " zones")

        if counts.criteria > 0 then
            Print(string.format("Subzones discovered: %d / %d (%.1f%%)",
                counts.done, counts.criteria, counts.done / counts.criteria * 100))
        end

        local here = Exploration.ForCurrentZone()

        if here then
            if here.completed then
                Print("This zone: |cff00ff00fully explored|r")
            else
                Print("This zone: " .. here.done .. " / " .. here.criteria)

                local missing = Blizzard.GetIncompleteCriteria(here.achievementID, 6)

                for _, name in ipairs(missing) do
                    Print("  missing: " .. name)
                end
            end
        end

        local closest = Exploration.Closest(CN.ToID(args) or 5)

        if #closest > 0 then
            Print("Closest to finishing:")

            for _, row in ipairs(closest) do
                Print("  " .. row.name .. " |cff999999("
                    .. row.done .. "/" .. row.criteria .. ")|r")
            end
        end
    end,
}

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
'@

$Embedded['Bindings.xml'] = @'
<Bindings>
    <Binding name="COMPLETIONNAVIGATOR_TOGGLE" header="COMPLETIONNAVIGATOR" category="ADDONS">
        CompletionNavigator_ToggleUI()
    </Binding>
    <Binding name="COMPLETIONNAVIGATOR_NEXT" category="ADDONS">
        CompletionNavigator_NextObjective()
    </Binding>
    <Binding name="COMPLETIONNAVIGATOR_GO" category="ADDONS">
        CompletionNavigator_Navigate()
    </Binding>
</Bindings>
'@

$Embedded['CompletionNavigator.toc'] = @'
## Interface: 120100
## Title: Completion Navigator
## Notes: Intelligent completion planning, prioritization, and navigation.
## Author: Travis A. Bryan I
## Version: 0.13.0
## SavedVariables: CompletionNavigatorDB
## OptionalDeps: TomTom, AllTheThings, BtWQuests, HandyNotes
## X-Category: Quests & Leveling
## X-License: MIT
## X-Copyright: Copyright (c) 2026 Dam Beaver Studios, LLC
## X-Publisher: Dam Beaver Studios, LLC
## X-Email: developer@dambeaverstudios.com
## IconTexture: Interface\AddOns\CompletionNavigator\Media\Logo
## X-Curse-Project-ID: 1657613
# ## X-Wago-ID:   (set this if the addon is also published to Wago)

# CN:FILES:BEGIN -- managed by cn.ps1 sync; do not edit by hand.
Core.lua
Database.lua
Objectives.lua
Dependencies.lua
Character.lua
Events.lua
Commands.lua
Scoring.lua
Routing.lua
UI.lua
Providers\Blizzard.lua
Providers\HandyNotes.lua
Providers\StaticData.lua
Providers\ATT.lua
Providers\BtWQuests.lua
Providers\TomTom.lua
Data\Quests.lua
Modules\Achievements.lua
Modules\Appearances.lua
Modules\Breakdown.lua
Modules\Currencies.lua
Modules\Exploration.lua
Modules\Harvest.lua
Modules\Mounts.lua
Modules\Opportunities.lua
Modules\Pets.lua
Modules\Professions.lua
Modules\Quests.lua
Modules\Rares.lua
Modules\Reputations.lua
Modules\Titles.lua
Modules\Toys.lua
Modules\Warband.lua
# CN:FILES:END
'@

$Embedded['LICENSE'] = @'
MIT License

Copyright (c) 2026 Dam Beaver Studios, LLC
Authored by Travis A. Bryan I. All rights are held by Dam Beaver Studios, LLC.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
'@

$Embedded['README.md'] = @'
# Completion Navigator

A completion planning and navigation engine for World of Warcraft Retail.

Authored by **Travis A. Bryan I**. Owned, published and maintained by **Dam Beaver Studios, LLC**.

Most completion addons answer *what am I missing?* Completion Navigator is built to answer a different question:

> Given everything I have already completed, everything I can currently obtain, my current character, location, restrictions and prerequisites — **what should I do next?**

## What it does

Type `/cn next` or click the minimap button. The addon scores every objective it knows to be currently actionable and tells you which one is worth doing, and why.

- **Explains itself.** Every recommendation comes with its reasons: *ready to turn in*, *in your current zone*, *a Paragon reward is waiting*, *unlocks four further quests*.
- **Navigates.** Sets a TomTom waypoint if you have TomTom, a Blizzard map pin if you don't, and falls back to the game's own quest tracking arrow when no coordinates exist.
- **Routes a zone.** `/cn zone` clusters everything obtainable on your current map and orders it nearest-first.
- **Knows your Warband.** Reputations, titles, professions and recipes are recorded per character where the game scopes them that way, so the addon can tell you when a different character is the right one for a job.
- **Explains blockers.** `/cn why <questID>` reports the first unmet prerequisite rather than just saying "not available", and names which data source produced the answer.
- **Learns from your play.** Every quest you accept or turn in has its name, zone, coordinates and level recorded permanently and account-wide. `/cn export` emits them as ready-to-paste `Data\Quests.lua` rows, so playing the game grows the shipped database.
- **Reads other addons rather than duplicating them.** AllTheThings and BtWQuests are consumed at runtime for quest names, coordinates and prerequisite chains when installed. Neither is required.

## Tracked

| Subsystem | Notes |
|---|---|
| Quests | Event-driven discovery, account vs character completion, coordinates from four client sources |
| Reputations | Standing, Renown, Paragon; account-wide vs character-specific scope |
| Achievements | Focused on near-completion — what is within two criteria of finishing |
| Battle pets | Collected counts, wild/obtainable classification |
| Mounts | Faction-lock detection |
| Toys | Collection state |
| Appearances | Transmog progress per category |
| Titles | Per character, so you can see which alt has one |
| Professions & recipes | Skill levels and which characters know which recipe |
| Harvested data | Names, zones, coordinates and levels captured from your own play |

## Commands

`/cn` for status, `/cn help` for the full list, `/cn ui` for the window.

The window has five tabs — Next, Zone, Collections, Scans, Settings — and everything the slash commands do is reachable by clicking. Keybindings live under Key Bindings → AddOns.

## Known limitations

These are honest constraints, not oversights:

- **Recipes require the profession window.** `C_TradeSkillUI` only exposes a recipe list while that profession's window is open. The addon captures each one automatically the first time you open it and tells you which are still outstanding. It will not silently report zero.
- **No completion percentages for zones.** A percentage needs a trustworthy denominator, and the curated static database does not yet have zone coverage. The addon reports counts of what remains instead of inventing a number you would act on.
- **Appearances are tracked per category, not per item.** Enumerating every appearance source is tens of thousands of entries; the actionable question is which slot is furthest from done.
- **Achievements only become recommendations when nearly complete.** A zero-progress achievement is a project, not a next action.

## Optional integrations

**TomTom** for waypoints. Without it, navigation falls back to Blizzard map pins and the quest tracking arrow.

**AllTheThings** and **BtWQuests** are read at runtime for quest names, coordinates, source quests and prerequisite chains. Their internals are not published contracts, so every access is probed and wrapped: an update to either can make a provider go quiet, but cannot break Completion Navigator. `/cn providers` reports exactly what resolved.

None are required.

## Development

The addon is managed by `cn.ps1`, a PowerShell toolkit that carries the whole source tree inside it.

```powershell
.\cn.ps1 init                    # scaffold the modular tree
.\cn.ps1 new module Pets         # create a module and sync the .toc
.\cn.ps1 cmd pets -Module Pets   # register a slash command stub
.\cn.ps1 event NEW_PET_ADDED -Module Pets
.\cn.ps1 sync                    # rewrite the .toc load order from disk
.\cn.ps1 check                   # validate .toc, BOMs, duplicates, Lua syntax
.\cn.ps1 package                 # build a distributable zip
.\cn.ps1 release 0.9.0           # bump, commit, tag and push
```

Architecture is registry-based: `CN:RegisterCommand{}`, `CN:RegisterEvent()`, `CN:RegisterModule()`, `CN.RegisterCandidateProvider()`, `CN.RegisterEligibilityChecker()`, `CN.UI.RegisterTab{}`. Adding a subsystem never means editing a dispatcher. All client API calls live in `Providers/Blizzard.lua`, so a patch break is a one-file fix.

Load order is enforced by `sync`: fixed root order, then `Providers\`, then `Data\`, then `Modules\`.

## Contact

Bug reports and feature requests: open an issue on the repository, or email
developer@dambeaverstudios.com.

## License

Released under the MIT License.

Copyright (c) 2026 **Dam Beaver Studios, LLC**. All right, title and interest in
this work — including the copyright, the project, and its distribution channels —
is held and controlled by Dam Beaver Studios, LLC. Authorship credit: Travis A. Bryan I.

See [LICENSE](LICENSE).
'@

$Embedded['CHANGELOG.md'] = @'
# Changelog

All notable changes to Completion Navigator are recorded here.

Completion Navigator is a product of Dam Beaver Studios, LLC.
Authored by Travis A. Bryan I.

## [Unreleased]

## [0.13.0]

### Added

- **Auto-advancing waypoints.** `/cn auto`, or the Settings checkbox. When
  the thing you were pointed at is finished, the waypoint moves to whatever
  is worth doing next. Off by default: taking over the waypoint uninvited
  is hostile, and TomTom arrows are shared with every other addon.
  It re-points when the objective *changes*, not on a timer, because a
  waypoint that silently moves while you walk to it is worse than one that
  never moves. A slow backstop ticker covers objectives that expire rather
  than complete, such as a world quest running out while you stand still.
- **Three new tabs: Now, Warband and Remaining.** Everything added since
  0.9 was reachable only by typing, which broke this addon's own rule that
  the keyboard is the power-user path and not the required one.
  The Now tab merges world quests, live rares, capped currencies and
  unfilled weekly earning into one clickable list.
- **Exploration.** Per-zone subzone discovery, with the names of the places
  you have not been. Zones closest to finishing are surfaced first.
  `/cn exploration`, `/cn explorescan`.
- **HandyNotes provider.** Reads registered HandyNotes plugins for treasure
  and rare coordinates. It never answers quest lookups, so it cannot
  contribute wrong prerequisite data.

### Fixed

- Tab buttons ran off the edge of the window once there were more than about
  six. Tabs are a registry any module can add to, so they now wrap to a
  second row and the panel below moves down to match, rather than the window
  being widened to fit today's count.
- "1 plugins" in provider diagnostics.

### Notes

- The exploration achievement category is the only countable exploration
  data the client exposes. The map API reports which overlays you have
  revealed but never how many exist, so a true "percent explored" cannot be
  computed. Per-subzone criteria are more actionable anyway: they name the
  place you have not been.


## [0.12.0]

### Added

- **"Why isn't this 100%?"** `/cn breakdown` explains what is left in every
  category and why, with a concrete next action per line rather than a bare
  count. `/cn breakdown <category>` for one at a time.
  Percentages appear only where the denominator is trustworthy. The client
  knows how many mounts exist; nothing knows how many quests exist. Where a
  total is unknowable the addon says so and shows counts, instead of
  inventing a number that looks authoritative.
- **Currencies.** Caps and weekly earning, tracked per character.
  A capped currency is earning potential being thrown away, so it surfaces
  as a time-sensitive recommendation to go spend it. Unfilled weekly caps
  are reported because they reset whether you use them or not.
  `/cn currencies`, `/cn currencyscan`.

### Fixed

- Singular/plural agreement in breakdown output. "1 are locked to the
  opposite faction" reads as a bug even when the number is correct.


## [0.11.0]

### Added

- **Rares and treasures**, driven by the client's vignette data rather than a
  static spawn database. A vignette is the only live signal that a rare is
  actually up right now, which is the half of the question static data
  cannot answer and which goes stale every patch.
  `/cn rares` lists what is up, `/cn rare <n>` routes to it, `/cn raredb`
  summarizes everything recorded.
- Rares and treasures feed the recommendation engine as time-sensitive
  objectives, because something that is up now and dead when someone else
  finds it is exactly what the limited-time term is for.
- Everything seen is recorded permanently and account-wide, so the addon
  accumulates its own spawn database from play. It cannot go stale, because
  it comes from the live game.
- Vignettes that disappear while the player is nearby are inferred as
  cleared by that character. Recorded as inference, not asserted as fact.
- **Addon artwork.** The .toc IconTexture and the minimap button now use the
  project logo. `.\cn.ps1 icon <file.png>` regenerates `Media\Logo.tga`.

### Fixed

- `check` now verifies that the file `IconTexture` points at actually
  exists. WoW fails silently on a missing texture, so a typo produced a
  blank icon and no error anywhere.
- The minimap button verifies its texture loaded and falls back to a stock
  icon rather than rendering an invisible button.


## [0.10.0]

### Added

- **Opportunity scanner.** World quests, daily and weekly resets, and active
  world events. Urgency is scaled steeply: something with an hour left
  dominates, something with three days left barely registers.
  `/cn now` lists everything expiring, soonest first. `/cn events` lists
  active world events.
- **Warband intelligence.** `/cn warband` shows every known character with
  what each covers, plus the combined coverage across all of them.
  `/cn who <rep, recipe, title or profession> <id or name>` answers which
  character should do a given thing.
- **Candidate decorators.** Cross-cutting concerns now apply to objectives
  from modules that know nothing about them. Warband suitability is the
  first user.

### Fixed

- `limitedTimeBonus` carries the heaviest weight in the scoring formula
  (3.0) and nothing ever set it. The engine was built to prioritise
  expiring content and had no idea what expires.
- `characterSuitability` was likewise weighted and never set.
- **Migrations ran after defaults were merged**, which meant `CopyDefaults`
  had already discarded any stored value whose type no longer matched the
  default. A migration existing to read a legacy value would silently find
  nothing. Migrations now run on the raw saved data first. This affected no
  shipped migration yet; it would have broken every future one.
- Literal `|` characters in command help and usage text were eaten by the
  chat frame as escape sequences: `<factionID|name>` rendered as
  `<factionIDame>`. Every affected string now reads `<factionID or name>`.

### Notes

- Database schema is now version 2. The 1 to 2 migration creates the account
  tables the collection modules added and moves the flat minimap setting into
  its nested form, preserving the player's choice. It is idempotent and is
  covered by a test that starts from a real version 1 database.


## [0.9.0]

### Added

- **Harvesting.** Every quest you pick up or turn in now has its name, zone,
  map, coordinates and observed level recorded permanently and account-wide.
  Playing the game fills the static database. `/cn harvest` shows what has
  been collected; `/cn harvestnow` sweeps the current log.
- **Export.** `/cn export` emits harvested quests as ready-to-paste
  `Data\Quests.lua` rows, so what one player harvests can be committed and
  shipped to everyone. `/cn export all` includes quests with no coordinates.
- **AllTheThings provider.** Reads quest names, coordinates, source quests
  and level requirements from ATT when the player has it installed.
- **BtWQuests provider.** Reads quest names and prerequisite chains,
  including nested prerequisite conditions.
- **Provider registry.** External data sources are merged by priority behind
  one interface. Curated static data always outranks them, because it is the
  only source this addon ships.
- `/cn providers` reports which external addons were detected and which entry
  points resolved. `/cn lookup <questID>` asks all of them about one quest.
- `/cn why` now reports which data source produced its answer, or says
  plainly that no prerequisite data exists for that quest.

### Notes

- Third-party addon internals are not published contracts. Every provider
  access is probed and wrapped, so an ATT or BtWQuests update can make a
  provider go quiet but cannot break Completion Navigator. `/cn providers` is
  how you tell which happened.
- Prerequisites inferred from the order you completed quests are recorded
  separately, never fed to the eligibility checker, and appear in exports as
  commented suggestions for a human to confirm. Correlation is not a
  prerequisite.

## [0.8.0]

### Added

- Battle pet collection tracking, including wild/obtainable classification
  and per-species collected counts.
- Mount collection tracking with faction-lock detection, so a mount your
  current character can never use is reported as such rather than as simply
  missing.
- Toy box tracking.
- Transmog appearance progress, reported per category.
- Title tracking, stored per character so the addon can say which alt
  already earned one.
- Achievement tracking focused on near-completion: achievements within two
  criteria of finishing are surfaced and fed to the recommendation engine.
- Profession and recipe tracking, including which characters know which
  recipe.
- A Collections tab showing account-wide completion per category.
- Slash commands for every subsystem: `/cn pets`, `/cn mounts`, `/cn toys`,
  `/cn appearances`, `/cn titles`, `/cn achievements`, `/cn closest`,
  `/cn professions`, `/cn recipes`, and per-item lookups.

### Fixed

- Profession enumeration walked the five profession slots with `ipairs`,
  which stops at the first empty slot. A character without Archaeology
  silently lost Fishing and Cooking.

### Notes

- Recipe lists can only be read while a profession window is open. This is a
  client restriction. The addon captures them automatically the first time
  you open each profession and tells you which are still outstanding rather
  than reporting zero.

## [0.7.0]

### Fixed

- Quest coordinates now come from four client sources rather than one.
  `GetNextWaypoint` answers for very few quests; the map POI list covers
  ordinary ones.
- Quests with no coordinates fall back to Blizzard's own tracking arrow
  instead of refusing to navigate.

### Added

- `/cn where` and `/cn setloc` for inspecting and recording quest locations.

## [0.6.0]

### Added

- Minimap button, tabbed main window, clickable objective lists, and
  keybindings.

## [0.5.0]

### Added

- `/cn zone`: clusters and routes everything obtainable in the current map.

## [0.4.0]

### Added

- Quests feed the recommendation engine; `/cn go` sets waypoints.

### Fixed

- Priority profiles applied weight names to an objective-type lookup, so
  `/cn mode fastest` did nothing.
- Objectives with no known location paid no travel cost and structurally
  outranked located ones.

## [0.3.0]

### Added

- Reputation, Renown and Paragon tracking, scoped account-wide versus
  character-specific.

## [0.1.0]

### Added

- Modular rewrite with registry-based commands, events and modules.
- Source-ranked quest metadata.
- Event-driven quest discovery.
'@

$Embedded['.pkgmeta'] = @'
package-as: CompletionNavigator

enable-nolib-creation: no

# Everything the game does not load. The build toolkit, CI config, backups
# and the CurseForge project-page copy all belong in the repository but not
# in a user's AddOns folder.
ignore:
  - .github
  - _curseforge
  - _backups
  - cn.ps1
  - README.md
'@

$Embedded['.github\workflows\release.yml'] = @'
name: Package and release

# Fires when you push a version tag, e.g.  git tag v0.8.0 && git push --tags
on:
  push:
    tags:
      - 'v*'

permissions:
  contents: write

jobs:
  release:
    runs-on: ubuntu-latest

    steps:
      - name: Check out
        uses: actions/checkout@v4
        with:
          fetch-depth: 0
          # Without this the tag object may not be present in the checkout,
          # and the packager decides the release type from
          # `git tag --points-at HEAD`. No tag means it uploads as ALPHA.
          fetch-tags: true

      # Belt and braces: force-fetch tags even if the checkout missed them.
      - name: Fetch tags
        run: git fetch --force --tags --prune --prune-tags

      # If no tag points at HEAD the packager silently publishes an alpha,
      # which then hides behind "Show alpha files" on CurseForge. Fail
      # instead, and print what git actually sees.
      - name: Verify a tag points at HEAD
        run: |
          echo "GITHUB_REF      = $GITHUB_REF"
          echo "GITHUB_REF_NAME = $GITHUB_REF_NAME"
          echo "HEAD            = $(git rev-parse HEAD)"
          echo "tags at HEAD    = $(git tag --points-at HEAD | tr '\n' ' ')"

          if [ -z "$(git tag --points-at HEAD)" ]; then
            echo "::error::No tag points at HEAD, so the packager would upload this as an ALPHA."
            echo "The release type is derived entirely from the tag; there is no flag to override it."
            exit 1
          fi

          # A tag containing alpha or beta is an intentional pre-release, but
          # say so out loud rather than surprising anyone.
          for t in $(git tag --points-at HEAD); do
            case "${t,,}" in
              *alpha*) echo "::warning::Tag $t contains 'alpha'; this will publish as an alpha file." ;;
              *beta*)  echo "::warning::Tag $t contains 'beta'; this will publish as a beta file." ;;
              *)       echo "Tag $t will publish as a RELEASE file." ;;
            esac
          done

      # Fails the build before publishing if any Lua file is malformed.
      - name: Install Lua
        run: sudo apt-get update && sudo apt-get install -y lua5.4

      - name: Syntax check every Lua file
        run: |
          status=0
          while IFS= read -r file; do
            if ! luac5.4 -p "$file"; then
              echo "SYNTAX ERROR: $file"
              status=1
            fi
          done < <(find . -name '*.lua' -not -path './.git/*')
          exit $status

      - name: Verify the .toc lists every Lua file
        run: |
          status=0
          toc=CompletionNavigator.toc
          while IFS= read -r file; do
            rel="${file#./}"
            win="${rel//\//\\}"
            if ! grep -qxF "$win" "$toc" && ! grep -qxF "$rel" "$toc"; then
              echo "NOT IN TOC: $rel"
              status=1
            fi
          done < <(find . -name '*.lua' -not -path './.git/*')
          exit $status

      # The packager SKIPS the CurseForge upload silently when CF_API_KEY is
      # missing -- the build still goes green and no file appears. Fail here
      # instead, so a missing or misnamed secret is obvious.
      - name: Verify the CurseForge token is available
        env:
          CF_API_KEY: ${{ secrets.CF_API_KEY }}
        run: |
          if [ -z "$CF_API_KEY" ]; then
            echo "::error::CF_API_KEY is empty or not visible to this workflow."
            echo ""
            echo "Check all three:"
            echo "  1. The secret is named exactly CF_API_KEY (case sensitive)."
            echo "  2. It is a REPOSITORY secret, or an organization secret with"
            echo "     this repository granted access."
            echo "  3. It is under Secrets, not Variables."
            exit 1
          fi
          echo "CF_API_KEY is present (${#CF_API_KEY} characters)."

      # BigWigs' packager is the standard tool; it reads .pkgmeta, builds the
      # zip, and uploads to CurseForge, WoWInterface and Wago as configured.
      - name: Package and upload
        uses: BigWigsMods/packager@master
        env:
          CF_API_KEY: ${{ secrets.CF_API_KEY }}
          GITHUB_OAUTH: ${{ secrets.GITHUB_TOKEN }}
'@

$Embedded['.gitattributes'] = @'
# Shell and YAML must be LF in the repository. A CRLF workflow file reaches
# the Linux runner with trailing carriage returns and every `run:` step dies
# with "$'\r': command not found".
*.yml   text eol=lf
*.yaml  text eol=lf
*.sh    text eol=lf
.pkgmeta text eol=lf

# Lua and docs are edited on Windows; leave them to git's normalization.
*.lua   text
*.toc   text
*.xml   text
*.md    text
*.ps1   text

*.png   binary
*.jpg   binary
*.zip   binary
'@


############################################################
# TEMPLATES
############################################################

$Templates = [ordered]@{}

$Templates['Module'] = @'
-- Modules/__NAME__.lua
-- Completion Navigator :: __NAME__ subsystem.

local ADDON_NAME, CN = ...

local __NAME__ = CN:RegisterModule("__NAME__")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

------------------------------------------------------------
-- STATE
------------------------------------------------------------

-- Persistent storage for this module. CN.Account() creates the table on
-- first use, so no database migration is required to add a subsystem.
local function Store()
    return CN.Account("__STORE__")
end

__NAME__.Store = Store

------------------------------------------------------------
-- API
------------------------------------------------------------

function __NAME__.Scan()
    -- TODO: read live state, persist it, return counts.
    return 0
end

------------------------------------------------------------
-- ELIGIBILITY
------------------------------------------------------------

-- CN.RegisterEligibilityChecker(CN.objectiveTypes.__TYPE__, function(id)
--     return CN.objectiveStates.AVAILABLE, nil, nil
-- end)

------------------------------------------------------------
-- CANDIDATES
------------------------------------------------------------

-- CN.RegisterCandidateProvider("__NAME__", function()
--     return {}
-- end)

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
'@

$Templates['Provider'] = @'
-- Providers/__NAME__.lua
-- Completion Navigator :: __NAME__ integration.
--
-- Providers are optional. Every entry point must degrade silently when the
-- external addon is absent.

local ADDON_NAME, CN = ...

local __NAME__ = {}

CN.__NAME__ = __NAME__

function __NAME__.IsAvailable()
    return _G.__NAME__ ~= nil
end

------------------------------------------------------------
-- API
------------------------------------------------------------

function __NAME__.Query(id)
    if not __NAME__.IsAvailable() then
        return nil
    end

    -- TODO: read from the external addon.
    return nil
end

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
'@

$Templates['Data'] = @'
-- Data/__NAME__.lua
-- Completion Navigator :: curated static __NAME__ data.
--
-- Rows here fill the gaps Blizzard APIs cannot answer. Keys are IDs.

local ADDON_NAME, CN = ...

CN.Static.__NAME__ = CN.Static.__NAME__ or {}

local rows = {

    -- CN:DATA:__UPPER__ -- new rows are inserted above this marker.
}

for id, record in pairs(rows) do
    CN.Static.__NAME__[id] = record
end
'@

$Templates['Command'] = @'

CN:RegisterCommand{
    name    = "__CMD__",
    args    = "__USAGE__",
    order   = __ORDER__,
    help    = "__HELP__",
    handler = function(args)
        -- TODO: implement /cn __CMD__
        Print("/cn __CMD__ called with: " .. tostring(args))
    end,
}
'@

$Templates['Event'] = @'

CN:RegisterEvent("__EVENT__", function(event, ...)
    -- TODO: implement __EVENT__ handling.
    DebugPrint("__EVENT__ fired.")
end)
'@

############################################################
# IO HELPERS
############################################################

function Write-CNFile {
    param([string] $Relative, [string] $Content)

    $full = Join-Path $script:Root $Relative
    $dir  = Split-Path -Parent $full

    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if (-not $Content.EndsWith("`n")) { $Content += "`r`n" }

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($full, ($Content -replace "`r`n", "`n" -replace "`n", "`r`n"), $encoding)
}

function Read-CNFile {
    param([string] $Relative)

    $full = Join-Path $script:Root $Relative

    if (-not (Test-Path -LiteralPath $full)) { return $null }

    return [System.IO.File]::ReadAllText($full)
}

function Test-CNWritable {
    $probe = Join-Path $script:Root ('.cn-write-test-' + [guid]::NewGuid().ToString('N') + '.tmp')

    try {
        [System.IO.File]::WriteAllText($probe, 'x')
        Remove-Item -LiteralPath $probe -Force
        return $true
    }
    catch {
        return $false
    }
}

function Assert-CNWritable {
    if (Test-CNWritable) { return }

    Write-Host ''
    Write-Host 'ERROR: this folder is not writable by the current process.' -ForegroundColor Red
    Write-Host "  $script:Root" -ForegroundColor DarkGray
    Write-Host ''
    Write-Host 'Fix: close this window, right-click PowerShell, "Run as administrator", then re-run.' -ForegroundColor Yellow
    Write-Host 'Better long-term fix: keep the source in a writable folder and junction it here:' -ForegroundColor Yellow
    Write-Host '  mklink /J "C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\CompletionNavigator" "C:\dev\CompletionNavigator"' -ForegroundColor DarkGray
    Write-Host ''

    exit 1
}

function Get-CNLuaFiles {
    Get-ChildItem -LiteralPath $script:Root -Recurse -Filter '*.lua' -File |
        Where-Object { $_.FullName -notmatch '[\\/]_backups[\\/]' } |
        ForEach-Object {
            $_.FullName.Substring($script:Root.Length).TrimStart('\', '/').Replace('/', '\')
        }
}

function Get-CNLoadOrder {
    $all = @(Get-CNLuaFiles)

    $ordered = New-Object System.Collections.Generic.List[string]

    foreach ($file in $script:RootOrder) {
        if ($all -contains $file) { $ordered.Add($file) | Out-Null }
    }

    # Any unlisted root-level file, alphabetically, after the fixed set.
    $all | Where-Object { $_ -notmatch '\\' -and $script:RootOrder -notcontains $_ } |
        Sort-Object | ForEach-Object { $ordered.Add($_) | Out-Null }

    foreach ($folder in $script:FolderOrder) {
        $all | Where-Object { $_ -like "$folder\*" } |
            Sort-Object | ForEach-Object { $ordered.Add($_) | Out-Null }
    }

    # Any other subfolder not in FolderOrder, last.
    $all | Where-Object {
            $_ -match '\\' -and
            ($script:FolderOrder -notcontains ($_ -split '\\')[0])
        } | Sort-Object | ForEach-Object { $ordered.Add($_) | Out-Null }

    return $ordered
}

function Resolve-CNModulePath {
    param([string] $ModuleName)

    if (-not $ModuleName) { return $null }

    if ($ModuleName -like '*.lua') {
        if (Test-Path -LiteralPath (Join-Path $script:Root $ModuleName)) { return $ModuleName }
    }

    $candidates = @(
        "Modules\$ModuleName.lua",
        "Providers\$ModuleName.lua",
        "$ModuleName.lua"
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $script:Root $candidate)) { return $candidate }
    }

    return $null
}

function Add-CNBlock {
    param([string] $Relative, [string] $Block, [string] $Marker = $script:AppendMark)

    $content = Read-CNFile $Relative

    if ($null -eq $content) { throw "File not found: $Relative" }

    $index   = $content.IndexOf($Marker)
    $trimmed = $Block.Trim("`r", "`n")

    if ($index -ge 0) {
        # Insert immediately above the marker line.
        $lineStart = $content.LastIndexOf("`n", $index)
        if ($lineStart -lt 0) { $lineStart = 0 } else { $lineStart += 1 }

        $content = $content.Substring(0, $lineStart) +
                   $trimmed + "`n`n" +
                   $content.Substring($lineStart)
    }
    else {
        $content = $content.TrimEnd() + "`n`n" + $trimmed + "`n"
    }

    Write-CNFile $Relative $content
}


############################################################
# GIT
############################################################

# git is frequently installed but absent from PATH -- GitHub Desktop ships
# its own copy, and the standalone installer does not always update PATH for
# an already-open shell. Look in the usual places before giving up.
function Resolve-CNGit {
    $command = Get-Command git -ErrorAction SilentlyContinue

    if ($command) { return $command.Source }

    $candidates = @(
        "$env:ProgramFiles\Git\cmd\git.exe",
        "${env:ProgramFiles(x86)}\Git\cmd\git.exe",
        "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe",
        "$env:ProgramW6432\Git\cmd\git.exe"
    )

    # GitHub Desktop bundles git under a versioned folder.
    $desktopRoot = "$env:LOCALAPPDATA\GitHubDesktop"

    if (Test-Path -LiteralPath $desktopRoot) {
        Get-ChildItem -LiteralPath $desktopRoot -Filter 'app-*' -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            ForEach-Object {
                $candidates += (Join-Path $_.FullName 'resources\app\git\cmd\git.exe')
            }
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            $binDirectory = Split-Path -Parent $candidate

            # Make it usable for the rest of this session, not just here.
            $env:PATH = "$binDirectory;$env:PATH"

            Write-Host "Found git at $candidate and added it to PATH for this session." -ForegroundColor DarkGray

            return $candidate
        }
    }

    return $null
}

function Assert-CNGit {
    $git = Resolve-CNGit

    if ($git) { return $git }

    Write-Host ''
    Write-Host 'git is not installed, or not on PATH.' -ForegroundColor Red
    Write-Host ''
    Write-Host 'Install it:' -ForegroundColor Yellow
    Write-Host '  winget install --id Git.Git -e --source winget' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host 'Then CLOSE and REOPEN PowerShell. An already-open shell keeps its' -ForegroundColor Yellow
    Write-Host 'old PATH, so git stays invisible until you restart it.' -ForegroundColor Yellow
    Write-Host ''

    return $null
}

############################################################
# COMMANDS
############################################################

function Invoke-CNInit {
    Assert-CNWritable

    $legacy = Join-Path $script:Root 'CompletionNavigator.lua'
    $hasTree = Test-Path -LiteralPath (Join-Path $script:Root 'Core.lua')

    if ($hasTree -and -not $Force) {
        Write-Host 'Core.lua already exists. Re-run with -Force to overwrite the whole tree.' -ForegroundColor Yellow
        Write-Host 'Existing SavedVariables are untouched either way.' -ForegroundColor DarkGray
        return
    }

    Invoke-CNBackup -Quiet

    foreach ($relative in $Embedded.Keys) {
        Write-CNFile $relative $Embedded[$relative]
        Write-Host "  wrote  $relative" -ForegroundColor DarkGray
    }

    if (Test-Path -LiteralPath $legacy) {
        $retired = Join-Path $script:BackupDir 'CompletionNavigator.lua.single-file'
        New-Item -ItemType Directory -Path $script:BackupDir -Force | Out-Null
        Move-Item -LiteralPath $legacy -Destination $retired -Force
        Write-Host "  retired CompletionNavigator.lua -> _backups\CompletionNavigator.lua.single-file" -ForegroundColor DarkGray
    }

    Invoke-CNSync
    Write-Host ''
    Write-Host 'Scaffold complete. In game: /reload then /cn help' -ForegroundColor Green
}

function Invoke-CNSync {
    Assert-CNWritable

    $toc = Read-CNFile 'CompletionNavigator.toc'

    if ($null -eq $toc) { throw 'CompletionNavigator.toc not found. Run: .\cn.ps1 init' }

    # Bindings.xml is deliberately NOT listed. The client loads it directly
    # from the addon folder; putting it in the .toc routes it through the
    # FrameXML parser instead, which rejects <Binding> with
    # "Unrecognized XML: Binding".
    $files = Get-CNLoadOrder

    $block = ($script:BeginMark + "`n" + (($files) -join "`n") + "`n" + $script:EndMark)

    $startIndex = $toc.IndexOf($script:BeginMark)
    $endIndex   = $toc.IndexOf($script:EndMark)

    if ($startIndex -ge 0 -and $endIndex -gt $startIndex) {
        $head = $toc.Substring(0, $startIndex)
        $tail = $toc.Substring($endIndex + $script:EndMark.Length)
        $toc  = $head + $block + $tail
    }
    else {
        $toc = $toc.TrimEnd() + "`n`n" + $block + "`n"
    }

    Write-CNFile 'CompletionNavigator.toc' $toc

    Write-Host "Synced .toc with $($files.Count) Lua files." -ForegroundColor Green
    $files | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
}

function Invoke-CNNew {
    Assert-CNWritable

    $kind = if ($Target) { $Target.ToLower() } else { '' }
    $itemName = if ($Name) { $Name } else { $Value }

    if (-not $itemName) {
        Write-Host 'Usage: .\cn.ps1 new <module|provider|data> <Name>' -ForegroundColor Yellow
        return
    }

    switch ($kind) {
        'module' {
            $relative = "Modules\$itemName.lua"
            $body = $Templates['Module'] -replace '__NAME__', $itemName `
                                          -replace '__STORE__', $itemName.ToLower() `
                                          -replace '__TYPE__', $itemName.ToUpper()
        }
        'provider' {
            $relative = "Providers\$itemName.lua"
            $body = $Templates['Provider'] -replace '__NAME__', $itemName
        }
        'data' {
            $relative = "Data\$itemName.lua"
            $body = $Templates['Data'] -replace '__NAME__', $itemName `
                                        -replace '__UPPER__', $itemName.ToUpper()
        }
        default {
            Write-Host 'Usage: .\cn.ps1 new <module|provider|data> <Name>' -ForegroundColor Yellow
            return
        }
    }

    if ((Test-Path -LiteralPath (Join-Path $script:Root $relative)) -and -not $Force) {
        Write-Host "$relative already exists. Use -Force to overwrite." -ForegroundColor Yellow
        return
    }

    Write-CNFile $relative $body

    Write-Host "Created $relative" -ForegroundColor Green

    Invoke-CNSync
}

function Invoke-CNCommand {
    Assert-CNWritable

    $cmdName = if ($Name) { $Name } else { $Target }

    if (-not $cmdName) {
        Write-Host 'Usage: .\cn.ps1 cmd <name> -Module <Module> [-Usage "<id>"] [-Help "..."] [-Order 50]' -ForegroundColor Yellow
        return
    }

    if (-not $Module) {
        Write-Host 'A target file is required: -Module <ModuleName|Providers\X|Commands.lua>' -ForegroundColor Yellow
        return
    }

    $relative = Resolve-CNModulePath $Module

    if (-not $relative) {
        Write-Host "Could not find a file for module '$Module'." -ForegroundColor Red
        Write-Host "Create it first: .\cn.ps1 new module $Module" -ForegroundColor Yellow
        return
    }

    $existing = Read-CNFile $relative

    if ($existing -match ('name\s*=\s*"' + [regex]::Escape($cmdName.ToLower()) + '"')) {
        Write-Host "/cn $cmdName is already registered in $relative." -ForegroundColor Yellow
        return
    }

    $block = $Templates['Command'] -replace '__CMD__', $cmdName.ToLower() `
                                    -replace '__USAGE__', ($Usage -replace '"', '\"') `
                                    -replace '__HELP__', (($Help -replace '"', '\"')) `
                                    -replace '__ORDER__', $Order

    Add-CNBlock -Relative $relative -Block $block

    Write-Host "Registered /cn $($cmdName.ToLower()) in $relative" -ForegroundColor Green
    Write-Host 'Fill in the handler, then /reload in game.' -ForegroundColor DarkGray
}

function Invoke-CNEvent {
    Assert-CNWritable

    $eventName = if ($Name) { $Name } else { $Target }

    if (-not $eventName) {
        Write-Host 'Usage: .\cn.ps1 event <EVENT_NAME> -Module <Module>' -ForegroundColor Yellow
        return
    }

    if (-not $Module) {
        Write-Host 'A target file is required: -Module <ModuleName>' -ForegroundColor Yellow
        return
    }

    $relative = Resolve-CNModulePath $Module

    if (-not $relative) {
        Write-Host "Could not find a file for module '$Module'." -ForegroundColor Red
        return
    }

    $eventName = $eventName.ToUpper()
    $existing  = Read-CNFile $relative

    if ($existing -match ('RegisterEvent\("' + [regex]::Escape($eventName) + '"')) {
        Write-Host "$eventName is already handled in $relative." -ForegroundColor Yellow
        return
    }

    $block = $Templates['Event'] -replace '__EVENT__', $eventName

    Add-CNBlock -Relative $relative -Block $block

    Write-Host "Registered $eventName in $relative" -ForegroundColor Green
}

function Invoke-CNData {
    Assert-CNWritable

    $kind = if ($Target) { $Target.ToLower() } else { '' }

    if ($kind -ne 'quest') {
        Write-Host 'Usage: .\cn.ps1 data quest <questID> -Name "Title" [-Expansion "TWW"] [-MapID 84] [-X 0.55] [-Y 0.42] [-Requires "123,456"]' -ForegroundColor Yellow
        return
    }

    $id = 0

    if (-not [int]::TryParse($Value, [ref] $id) -or $id -le 0) {
        Write-Host 'A positive quest ID is required.' -ForegroundColor Yellow
        return
    }

    $relative = 'Data\Quests.lua'
    $content  = Read-CNFile $relative

    if ($null -eq $content) { throw "$relative not found. Run: .\cn.ps1 init" }

    if ($content -match ('\[\s*' + $id + '\s*\]\s*=')) {
        Write-Host "Quest $id is already present in $relative." -ForegroundColor Yellow
        return
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("    [$id] = {") | Out-Null

    if ($Name)      { $lines.Add('        name      = "' + ($Name -replace '"', '\"') + '",') | Out-Null }
    if ($Expansion) { $lines.Add('        expansion = "' + $Expansion + '",') | Out-Null }
    if ($MapID)     { $lines.Add("        mapID     = $MapID,") | Out-Null }
    if ($X)         { $lines.Add("        x         = $X,") | Out-Null }
    if ($Y)         { $lines.Add("        y         = $Y,") | Out-Null }

    if ($Requires) {
        $ids = ($Requires -split '[,\s]+' | Where-Object { $_ }) -join ', '
        $lines.Add("        requires  = { $ids },") | Out-Null
    }

    $lines.Add('    },') | Out-Null

    Add-CNBlock -Relative $relative -Block (($lines -join "`n")) -Marker $script:DataMark

    Write-Host "Added quest $id to $relative" -ForegroundColor Green
}

function Invoke-CNVersion {
    Assert-CNWritable

    $new = if ($Target) { $Target } else { $Value }

    if (-not $new) {
        $toc = Read-CNFile 'CompletionNavigator.toc'
        $core = Read-CNFile 'Core.lua'

        $tocVersion  = if ($toc  -match '(?m)^##\s*Version:\s*(.+)$') { $Matches[1].Trim() } else { '?' }
        $coreVersion = if ($core -match 'CN\.version\s*=\s*"([^"]+)"') { $Matches[1] } else { '?' }

        Write-Host "toc:  $tocVersion"
        Write-Host "lua:  $coreVersion"

        if ($tocVersion -ne $coreVersion) {
            Write-Host 'MISMATCH. Fix with: .\cn.ps1 version <x.y.z>' -ForegroundColor Yellow
        }

        return
    }

    if ($new -notmatch '^\d+\.\d+\.\d+$') {
        Write-Host 'Version must look like 0.1.0' -ForegroundColor Yellow
        return
    }

    $toc = Read-CNFile 'CompletionNavigator.toc'
    $toc = [regex]::Replace($toc, '(?m)^##\s*Version:\s*.+$', "## Version: $new")
    Write-CNFile 'CompletionNavigator.toc' $toc

    $core = Read-CNFile 'Core.lua'
    $core = [regex]::Replace($core, 'CN\.version\s*=\s*"[^"]*"', ('CN.version     = "' + $new + '"'))
    Write-CNFile 'Core.lua' $core

    Write-Host "Version set to $new in both .toc and Core.lua." -ForegroundColor Green
}

function Invoke-CNBackup {
    param([switch] $Quiet)

    if (-not (Test-Path -LiteralPath (Join-Path $script:Root 'CompletionNavigator.toc'))) { return }

    New-Item -ItemType Directory -Path $script:BackupDir -Force | Out-Null

    $stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
    $archive = Join-Path $script:BackupDir "CompletionNavigator-$stamp.zip"

    $items = Get-ChildItem -LiteralPath $script:Root |
        Where-Object { $_.Name -ne '_backups' -and $_.Name -ne '.git' }

    if (-not $items) { return }

    Compress-Archive -Path $items.FullName -DestinationPath $archive -Force

    if (-not $Quiet) {
        Write-Host "Backup written: _backups\CompletionNavigator-$stamp.zip" -ForegroundColor Green
    }
    else {
        Write-Host "  backup  _backups\CompletionNavigator-$stamp.zip" -ForegroundColor DarkGray
    }
}

function Invoke-CNRestore {
    Assert-CNWritable

    if (-not (Test-Path -LiteralPath $script:BackupDir)) {
        Write-Host 'No backups exist.' -ForegroundColor Yellow
        return
    }

    $archive = Get-ChildItem -LiteralPath $script:BackupDir -Filter '*.zip' |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if (-not $archive) {
        Write-Host 'No backup archives found.' -ForegroundColor Yellow
        return
    }

    if (-not $Force) {
        Write-Host "Would restore: $($archive.Name)" -ForegroundColor Yellow
        Write-Host 'Re-run with -Force to overwrite the current files.' -ForegroundColor Yellow
        return
    }

    Expand-Archive -LiteralPath $archive.FullName -DestinationPath $script:Root -Force

    Write-Host "Restored $($archive.Name)" -ForegroundColor Green
}

function Invoke-CNCheck {
    $problems = 0

    Write-Host 'Completion Navigator :: check' -ForegroundColor Cyan
    Write-Host ''

    $toc = Read-CNFile 'CompletionNavigator.toc'

    if ($null -eq $toc) {
        Write-Host '  FAIL  CompletionNavigator.toc is missing.' -ForegroundColor Red
        return
    }

    if ($toc -notmatch [regex]::Escape($script:BeginMark)) {
        Write-Host '  FAIL  .toc is missing the CN:FILES markers. Re-run init or add them by hand.' -ForegroundColor Red
        $problems++
    }

    $listed = @()

    $startIndex = $toc.IndexOf($script:BeginMark)
    $endIndex   = $toc.IndexOf($script:EndMark)

    if ($startIndex -ge 0 -and $endIndex -gt $startIndex) {
        $inner = $toc.Substring($startIndex + $script:BeginMark.Length,
                                $endIndex - $startIndex - $script:BeginMark.Length)

        $listed = @($inner -split "`r?`n" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and $_ -notmatch '^#' })
    }

    $onDisk = @(Get-CNLuaFiles)

    foreach ($file in $listed) {
        if (-not (Test-Path -LiteralPath (Join-Path $script:Root $file))) {
            Write-Host "  FAIL  .toc lists a missing file: $file" -ForegroundColor Red
            $problems++
        }
    }

    # The client loads Bindings.xml on its own. Listing it sends it to the
    # FrameXML parser, which errors with "Unrecognized XML: Binding".
    if ($listed -contains 'Bindings.xml') {
        Write-Host '  FAIL  Bindings.xml must not be listed in the .toc (run: .\cn.ps1 sync)' -ForegroundColor Red
        $problems++
    }

    foreach ($file in $onDisk) {
        if ($listed -notcontains $file) {
            Write-Host "  WARN  on disk but not in .toc: $file  (run: .\cn.ps1 sync)" -ForegroundColor Yellow
            $problems++
        }
    }

    # The .toc can point IconTexture at addon art. WoW fails silently on a
    # missing texture, so a typo here produces a blank icon and no error.
    if ($toc -match '(?m)^##\s*IconTexture:\s*(.+)$') {
        $iconPath = $Matches[1].Trim()

        if ($iconPath -match 'AddOns\\CompletionNavigator\\(.+)$') {
            $relativeIcon = $Matches[1] -replace '/', '\'

            $found = $false

            foreach ($extension in @('.tga', '.blp', '')) {
                if (Test-Path -LiteralPath (Join-Path $script:Root ($relativeIcon + $extension))) {
                    $found = $true
                    break
                }
            }

            if (-not $found) {
                Write-Host "  FAIL  IconTexture points at a missing file: $relativeIcon(.tga)" -ForegroundColor Red
                $problems++
            }
            else {
                Write-Host "  ok    IconTexture resolves to $relativeIcon.tga" -ForegroundColor DarkGray
            }
        }
    }

    # Byte-order marks break some Lua parsers and look like garbage in game.
    foreach ($file in $onDisk) {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $script:Root $file))

        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            Write-Host "  FAIL  UTF-8 BOM in $file" -ForegroundColor Red
            $problems++
        }
    }

    # Duplicate slash command registrations.
    $seen = @{}

    foreach ($file in $onDisk) {
        $content = Read-CNFile $file

        foreach ($match in [regex]::Matches($content, '(?m)^CN:RegisterCommand\s*\{\s*name\s*=\s*"([^"]+)"')) {
            $cmd = $match.Groups[1].Value

            if ($seen.ContainsKey($cmd)) {
                Write-Host "  FAIL  /cn $cmd registered twice ($($seen[$cmd]) and $file)" -ForegroundColor Red
                $problems++
            }
            else {
                $seen[$cmd] = $file
            }
        }
    }

    # Version agreement.
    $core = Read-CNFile 'Core.lua'

    if ($core) {
        $tocVersion  = if ($toc  -match '(?m)^##\s*Version:\s*(.+)$') { $Matches[1].Trim() } else { $null }
        $coreVersion = if ($core -match 'CN\.version\s*=\s*"([^"]+)"') { $Matches[1] } else { $null }

        if ($tocVersion -and $coreVersion -and $tocVersion -ne $coreVersion) {
            Write-Host "  WARN  version mismatch: .toc $tocVersion vs Core.lua $coreVersion" -ForegroundColor Yellow
            $problems++
        }
    }

    # Optional real syntax check if a Lua binary is on PATH.
    $luac = Get-Command 'luac54.exe', 'luac.exe', 'luac', 'luac5.4', 'luac5.3' -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($luac) {
        foreach ($file in $onDisk) {
            $output = & $luac.Source -p (Join-Path $script:Root $file) 2>&1

            if ($LASTEXITCODE -ne 0) {
                Write-Host "  FAIL  $file :: $output" -ForegroundColor Red
                $problems++
            }
        }

        Write-Host "  ok    syntax checked with $($luac.Name)" -ForegroundColor DarkGray
    }
    else {
        Write-Host '  note  no luac on PATH; syntax not verified. (winget install DEVCOM.Lua)' -ForegroundColor DarkGray
    }

    Write-Host ''

    if ($problems -eq 0) {
        Write-Host "All checks passed. $($onDisk.Count) Lua files." -ForegroundColor Green
    }
    else {
        Write-Host "$problems problem(s) found." -ForegroundColor Yellow
    }
}

function Invoke-CNList {
    $files = @(Get-CNLoadOrder)

    Write-Host ''
    Write-Host 'Load order' -ForegroundColor Cyan

    $index = 1

    foreach ($file in $files) {
        $size = (Get-Item -LiteralPath (Join-Path $script:Root $file)).Length
        Write-Host ("  {0,2}. {1,-32} {2,7} bytes" -f $index, $file, $size)
        $index++
    }

    Write-Host ''
    Write-Host 'Slash commands' -ForegroundColor Cyan

    foreach ($file in $files) {
        $content = Read-CNFile $file

        foreach ($match in [regex]::Matches($content, '(?ms)^CN:RegisterCommand\s*\{(?<body>.*?)^\}')) {
            $body = $match.Groups['body'].Value

            $cmd   = if ($body -match 'name\s*=\s*"([^"]*)"') { $Matches[1] } else { '?' }
            $usage = if ($body -match 'args\s*=\s*"([^"]*)"') { $Matches[1] } else { '' }
            $desc  = if ($body -match 'help\s*=\s*"([^"]*)"') { $Matches[1] } else { '' }

            Write-Host ("  /cn {0,-16} {1,-18} {2}" -f $cmd, $usage, $desc)
        }
    }

    Write-Host ''
    Write-Host 'Events' -ForegroundColor Cyan

    foreach ($file in $files) {
        $content = Read-CNFile $file

        foreach ($match in [regex]::Matches($content, '(?m)^CN:RegisterEvent\("([A-Z_]+)"')) {
            Write-Host ("  {0,-38} {1}" -f $match.Groups[1].Value, $file)
        }
    }

    Write-Host ''
}

function Invoke-CNSavedVars {
    # ...\_retail_\Interface\AddOns\CompletionNavigator -> ...\_retail_
    $retail = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $script:Root))
    $wtf    = Join-Path $retail 'WTF\Account'

    if (-not (Test-Path -LiteralPath $wtf)) {
        Write-Host "WTF folder not found at: $wtf" -ForegroundColor Yellow
        return
    }

    $found = Get-ChildItem -LiteralPath $wtf -Recurse -Filter 'CompletionNavigator.lua' -File -ErrorAction SilentlyContinue

    if (-not $found) {
        Write-Host 'No SavedVariables written yet. Log in and /reload once.' -ForegroundColor Yellow
        return
    }

    foreach ($file in $found) {
        Write-Host ("{0,10:N0} bytes  {1}  {2}" -f $file.Length, $file.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $file.FullName)
    }

    if ($Force) { & notepad.exe $found[0].FullName }
}

function Invoke-CNGitInit {
    Assert-CNWritable

    if (-not (Assert-CNGit)) { return }

    if (Test-Path -LiteralPath (Join-Path $script:Root '.git')) {
        Write-Host 'Already a git repository.' -ForegroundColor Yellow
        return
    }

    $ignore = @'
_backups/
*.zip
*.bak
Thumbs.db
desktop.ini
'@

    Write-CNFile '.gitignore' $ignore

    Push-Location $script:Root

    try {
        git init -b main | Out-Null

        # Set the repository identity BEFORE the first commit. Inheriting a
        # machine-wide identity here silently stamps the wrong address onto
        # the initial commit, and correcting it afterwards means rewriting
        # history.
        $commitName  = if ($Name)  { $Name }  else { 'Travis A. Bryan I' }
        $commitEmail = if ($Email) { $Email } else { 'developer@dambeaverstudios.com' }

        git config user.name  $commitName  | Out-Null
        git config user.email $commitEmail | Out-Null

        git add -A | Out-Null
        git commit -m 'Completion Navigator: initial commit' | Out-Null

        Write-Host "Git repository initialized." -ForegroundColor Green
        Write-Host "  identity: $commitName <$commitEmail>" -ForegroundColor DarkGray
        Write-Host '  (override with -Name and -Email)' -ForegroundColor DarkGray
    }
    finally {
        Pop-Location
    }
}

function Invoke-CNPackage {
    $toc = Read-CNFile 'CompletionNavigator.toc'

    if ($null -eq $toc) {
        Write-Host 'CompletionNavigator.toc not found. Nothing to package.' -ForegroundColor Red
        return
    }

    $version = if ($toc -match '(?m)^##\s*Version:\s*(.+)$') { $Matches[1].Trim() } else { '0.0.0' }

    # Run the validator first: shipping a broken .toc to someone else wastes
    # their time, not yours.
    Write-Host 'Validating before packaging...' -ForegroundColor Cyan
    Invoke-CNCheck
    Write-Host ''

    # [System.IO.Path]::GetTempPath() works everywhere; $env:TEMP is not set
    # on every host PowerShell runs on.
    $staging = Join-Path ([System.IO.Path]::GetTempPath()) ("cn-package-" + [guid]::NewGuid().ToString('N'))
    $inner   = Join-Path $staging 'CompletionNavigator'

    New-Item -ItemType Directory -Path $inner -Force | Out-Null

    # Ship only what the game loads. The toolkit, backups, git metadata and
    # scratch folders are yours, not the recipient's.
    $excludedNames      = @('_backups', '.git', '.gitignore', '_to_delete',
                            '.github', '.pkgmeta', '_curseforge')
    $excludedExtensions = @('.ps1', '.psm1', '.zip', '.bak')

    $shipped = 0

    Get-ChildItem -LiteralPath $script:Root |
        Where-Object {
            $excludedNames -notcontains $_.Name -and
            $excludedExtensions -notcontains $_.Extension
        } |
        ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $inner -Recurse -Force
            $shipped++
        }

    New-Item -ItemType Directory -Path $script:BackupDir -Force | Out-Null

    $archiveName = "CompletionNavigator-$version.zip"
    $out         = Join-Path $script:BackupDir $archiveName

    Compress-Archive -Path $inner -DestinationPath $out -Force

    # Verify the archive really contains CompletionNavigator/*.toc at the
    # top level. Anything else will not load when it is unzipped.
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    $entries = $null

    try {
        $zip     = [System.IO.Compression.ZipFile]::OpenRead($out)
        $entries = @($zip.Entries | ForEach-Object { $_.FullName })
        $zip.Dispose()
    }
    catch {
        Write-Host "  WARN  could not read back the archive: $_" -ForegroundColor Yellow
    }

    Remove-Item -LiteralPath $staging -Recurse -Force

    Write-Host "Packaged: _backups\$archiveName" -ForegroundColor Green
    Write-Host "  version: $version"
    Write-Host "  top-level items: $shipped"

    if ($entries) {
        $hasToc = $entries | Where-Object { $_ -match '^CompletionNavigator/.*\.toc$' }

        if ($hasToc) {
            Write-Host "  structure: OK (CompletionNavigator\ at the root)" -ForegroundColor Green
        }
        else {
            Write-Host '  FAIL  the archive does not contain CompletionNavigator\*.toc at its root.' -ForegroundColor Red
        }

        Write-Host "  files in archive: $($entries.Count)"
    }

    Write-Host ''
    Write-Host 'Send that zip. The recipient unzips it into:' -ForegroundColor Cyan
    Write-Host '  <World of Warcraft>\_retail_\Interface\AddOns\' -ForegroundColor DarkGray
    Write-Host 'so they end up with ...\AddOns\CompletionNavigator\CompletionNavigator.toc' -ForegroundColor DarkGray
    Write-Host 'Then /reload, or restart the client if it was running.' -ForegroundColor DarkGray
}


function Invoke-CNRelease {
    Assert-CNWritable

    $new = if ($Target) { $Target } else { $Value }

    if (-not $new -or $new -notmatch '^\d+\.\d+\.\d+$') {
        Write-Host 'Usage: .\cn.ps1 release <x.y.z>' -ForegroundColor Yellow
        return
    }

    if (-not (Assert-CNGit)) { return }

    if (-not (Test-Path -LiteralPath (Join-Path $script:Root '.git'))) {
        Write-Host 'Not a git repository. Run: .\cn.ps1 gitinit' -ForegroundColor Yellow
        return
    }

    # Never tag something that does not pass its own validator.
    Write-Host 'Validating...' -ForegroundColor Cyan
    Invoke-CNCheck
    Write-Host ''

    $Target = $new
    Invoke-CNVersion

    $changelog = Read-CNFile 'CHANGELOG.md'

    if ($changelog -and $changelog -notmatch [regex]::Escape("## [$new]")) {
        Write-Host "WARN  CHANGELOG.md has no '## [$new]' section." -ForegroundColor Yellow

        if (-not $Force) {
            Write-Host 'Add one, or re-run with -Force to tag anyway.' -ForegroundColor Yellow
            return
        }
    }

    Push-Location $script:Root

    try {
        git add -A | Out-Null
        git commit -m "Release $new" | Out-Null
        git tag "v$new"

        Write-Host "Committed and tagged v$new." -ForegroundColor Green

        $remote = git remote 2>$null

        if ($remote) {
            git push
            git push --tags

            Write-Host 'Pushed. The GitHub Actions workflow packages and uploads to CurseForge.' -ForegroundColor Green
        }
        else {
            Write-Host 'No git remote configured, so nothing was pushed.' -ForegroundColor Yellow
            Write-Host '  git remote add origin <url>' -ForegroundColor DarkGray
            Write-Host '  git push -u origin main --tags' -ForegroundColor DarkGray
        }
    }
    finally {
        Pop-Location
    }
}


function Invoke-CNRelocate {
    $destination = if ($Target) { $Target } else { $Value }

    if (-not $destination) {
        Write-Host 'Usage: .\cn.ps1 relocate C:\dev\CompletionNavigator' -ForegroundColor Yellow
        Write-Host ''
        Write-Host 'Copies the source out of Program Files to a writable folder, then tells' -ForegroundColor DarkGray
        Write-Host 'you how to junction it back so the game still loads it. Working under' -ForegroundColor DarkGray
        Write-Host 'Program Files means every git commit needs an elevated shell.' -ForegroundColor DarkGray
        return
    }

    if (Test-Path -LiteralPath $destination) {
        $existing = @(Get-ChildItem -LiteralPath $destination -Force -ErrorAction SilentlyContinue)

        if ($existing.Count -gt 0 -and -not $Force) {
            Write-Host "$destination already exists and is not empty." -ForegroundColor Yellow
            Write-Host 'Re-run with -Force to copy into it anyway.' -ForegroundColor Yellow
            return
        }
    }
    else {
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
    }

    $copied = 0

    Get-ChildItem -LiteralPath $script:Root -Force |
        Where-Object { $_.Name -ne '_backups' } |
        ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $destination -Recurse -Force
            $copied++
        }

    # Verify rather than assume: compare Lua file counts on both sides.
    $sourceCount = @(Get-CNLuaFiles).Count

    $destinationCount = @(
        Get-ChildItem -LiteralPath $destination -Recurse -Filter '*.lua' -File -ErrorAction SilentlyContinue
    ).Count

    Write-Host "Copied $copied top-level items to $destination" -ForegroundColor Green
    Write-Host "  Lua files: $sourceCount here, $destinationCount there"

    if ($sourceCount -ne $destinationCount) {
        Write-Host '  FAIL  the copy is incomplete. Do not continue.' -ForegroundColor Red
        return
    }

    Write-Host '  copy verified' -ForegroundColor Green
    Write-Host ''
    Write-Host 'Now replace this folder with a junction. PowerShell cannot delete the' -ForegroundColor Cyan
    Write-Host 'directory it is currently running from, so run these from elsewhere,' -ForegroundColor Cyan
    Write-Host 'in an ADMINISTRATOR Command Prompt:' -ForegroundColor Cyan
    Write-Host ''
    Write-Host "  cd /d C:\" -ForegroundColor DarkGray
    Write-Host "  rmdir /S /Q `"$script:Root`"" -ForegroundColor DarkGray
    Write-Host "  mklink /J `"$script:Root`" `"$destination`"" -ForegroundColor DarkGray
    Write-Host ''
    Write-Host 'After that, work in the new folder. The game reads it through the' -ForegroundColor Cyan
    Write-Host 'junction, and git no longer needs an elevated shell.' -ForegroundColor Cyan
    Write-Host ''
    Write-Host "A backup of the current folder is in _backups if you want one first:" -ForegroundColor DarkGray
    Write-Host '  .\cn.ps1 backup' -ForegroundColor DarkGray
}


function Invoke-CNIcon {
    Assert-CNWritable

    $source = if ($Target) { $Target } else { $Value }

    if (-not $source) {
        # Default to the logo dropped into the CurseForge assets folder.
        $source = Join-Path $script:Root '_curseforge\logo.png'
    }

    if (-not (Test-Path -LiteralPath $source)) {
        Write-Host "Source image not found: $source" -ForegroundColor Yellow
        Write-Host 'Usage: .\cn.ps1 icon <path-to-png>' -ForegroundColor Yellow
        Write-Host 'Or drop logo.png into _curseforge\ and run: .\cn.ps1 icon' -ForegroundColor DarkGray
        return
    }

    # System.Drawing exists on Windows PowerShell but is unavailable on other
    # hosts, and it fails at first use rather than at load, so probing the
    # type is not enough -- actually try to use it.
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $null = New-Object System.Drawing.Bitmap(1, 1)
    }
    catch {
        Write-Host 'System.Drawing is not usable on this PowerShell host, so the' -ForegroundColor Red
        Write-Host 'TGA cannot be generated here.' -ForegroundColor Red
        Write-Host ''
        Write-Host 'Media\Logo.tga is committed to the repository, so unless you are' -ForegroundColor Yellow
        Write-Host 'replacing the artwork you do not need this command at all.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host 'To replace it by hand: export a 128x128 uncompressed 32-bit TGA' -ForegroundColor DarkGray
        Write-Host 'and save it as Media\Logo.tga' -ForegroundColor DarkGray
        return
    }

    $mediaDirectory = Join-Path $script:Root 'Media'

    if (-not (Test-Path -LiteralPath $mediaDirectory)) {
        New-Item -ItemType Directory -Path $mediaDirectory -Force | Out-Null
    }

    $size = 128

    try {
        $original = [System.Drawing.Bitmap]::FromFile((Resolve-Path -LiteralPath $source))
    }
    catch {
        Write-Host "Could not read the image: $_" -ForegroundColor Red
        return
    }

    try {
        # WoW requires power-of-two dimensions. 128x128 is the standard for an
        # addon icon and stays crisp on the minimap button.
        $resized = New-Object System.Drawing.Bitmap($size, $size)

        $graphics = [System.Drawing.Graphics]::FromImage($resized)
        $graphics.InterpolationMode  = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.SmoothingMode      = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.PixelOffsetMode    = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.DrawImage($original, 0, 0, $size, $size)
        $graphics.Dispose()

        # Uncompressed 32-bit BGRA TGA, bottom-up. The client will not read a
        # PNG, and it fails silently rather than erroring.
        $pixels = New-Object 'System.Collections.Generic.List[byte]'

        for ($y = $size - 1; $y -ge 0; $y--) {
            for ($x = 0; $x -lt $size; $x++) {
                $pixel = $resized.GetPixel($x, $y)

                $pixels.Add($pixel.B)
                $pixels.Add($pixel.G)
                $pixels.Add($pixel.R)
                $pixels.Add($pixel.A)
            }
        }

        $header = [byte[]]@(
            0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            ($size -band 0xFF), (($size -shr 8) -band 0xFF),
            ($size -band 0xFF), (($size -shr 8) -band 0xFF),
            32, 8
        )

        $output = Join-Path $mediaDirectory 'Logo.tga'

        $stream = [System.IO.File]::Create($output)
        $stream.Write($header, 0, $header.Length)
        $stream.Write($pixels.ToArray(), 0, $pixels.Count)
        $stream.Close()

        $resized.Dispose()

        Write-Host "Wrote Media\Logo.tga  ($size x $size, 32-bit uncompressed)" -ForegroundColor Green
        Write-Host '  used by the .toc IconTexture line and the minimap button'
        Write-Host '  /reload in game to see it'
    }
    finally {
        $original.Dispose()
    }

    Invoke-CNSync
}

function Invoke-CNOpen {
    Start-Process explorer.exe $script:Root
}

function Show-CNHelp {
    Write-Host ''
    Write-Host 'Completion Navigator toolkit' -ForegroundColor Cyan
    Write-Host "  $script:Root" -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  init                            Scaffold the modular tree (backs up first).'
    Write-Host '  sync                            Rewrite the .toc file list from what is on disk.'
    Write-Host '  check                           Validate .toc, BOMs, duplicate commands, versions, syntax.'
    Write-Host '  list                            Show load order, slash commands, and events.'
    Write-Host ''
    Write-Host '  new module <Name>               Create Modules\<Name>.lua and sync.'
    Write-Host '  new provider <Name>             Create Providers\<Name>.lua and sync.'
    Write-Host '  new data <Name>                 Create Data\<Name>.lua and sync.'
    Write-Host ''
    Write-Host '  cmd <name> -Module <M>          Register a /cn subcommand stub.'
    Write-Host '        [-Usage "<id>"] [-Help "text"] [-Order 50]'
    Write-Host '  event <EVENT> -Module <M>       Register an event handler stub.'
    Write-Host '  data quest <id> -Name "Title"   Add a curated quest row.'
    Write-Host '        [-Expansion X] [-MapID N] [-X 0.5] [-Y 0.5] [-Requires "1,2"]'
    Write-Host ''
    Write-Host '  version [x.y.z]                 Show or set the version in .toc and Core.lua.'
    Write-Host '  backup                          Zip the addon into _backups.'
    Write-Host '  restore -Force                  Restore the newest backup.'
    Write-Host '  package                         Build a distributable zip.'
    Write-Host '  savedvars [-Force]              Locate SavedVariables (-Force opens it).'
    Write-Host '  release <x.y.z>                Bump, commit, tag and push a release.'
    Write-Host '  relocate <path>                Copy the source out of Program Files.'
    Write-Host '  icon [path.png]                Convert a PNG into Media\Logo.tga for in-game use.'
    Write-Host '  gitinit                         Initialize git with a sane .gitignore.'
    Write-Host '  open                            Open the folder in Explorer.'
    Write-Host ''
    Write-Host 'Examples' -ForegroundColor Cyan
    Write-Host '  .\cn.ps1 init'
    Write-Host '  .\cn.ps1 new module Pets'
    Write-Host '  .\cn.ps1 cmd pets -Module Pets -Usage "<speciesID>" -Help "Check a battle pet." -Order 30'
    Write-Host '  .\cn.ps1 event PET_JOURNAL_LIST_UPDATE -Module Pets'
    Write-Host '  .\cn.ps1 data quest 8238 -Name "The Battle for Andorhal" -Expansion "Classic"'
    Write-Host '  .\cn.ps1 version 0.2.0; .\cn.ps1 check'
    Write-Host ''
}

############################################################
# DISPATCH
############################################################

switch ($Command.ToLower()) {
    'init'      { Invoke-CNInit }
    'sync'      { Invoke-CNSync }
    'check'     { Invoke-CNCheck }
    'list'      { Invoke-CNList }
    'new'       { Invoke-CNNew }
    'cmd'       { Invoke-CNCommand }
    'command'   { Invoke-CNCommand }
    'event'     { Invoke-CNEvent }
    'data'      { Invoke-CNData }
    'version'   { Invoke-CNVersion }
    'backup'    { Invoke-CNBackup }
    'restore'   { Invoke-CNRestore }
    'package'   { Invoke-CNPackage }
    'savedvars' { Invoke-CNSavedVars }
    'sv'        { Invoke-CNSavedVars }
    'release'   { Invoke-CNRelease }
    'relocate'  { Invoke-CNRelocate }
    'icon'      { Invoke-CNIcon }
    'gitinit'   { Invoke-CNGitInit }
    'git-init'  { Invoke-CNGitInit }
    'open'      { Invoke-CNOpen }
    'help'      { Show-CNHelp }
    default {
        Write-Host "Unknown command: $Command" -ForegroundColor Red
        Show-CNHelp
    }
}
