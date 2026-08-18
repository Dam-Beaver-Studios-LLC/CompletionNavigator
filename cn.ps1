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

# The version of the addon source embedded in THIS file. Written by the
# generator from Core.lua, so it can never drift from what gets scaffolded.
#
# This exists because a stale cn.ps1 is otherwise invisible: it scaffolds a
# previous release over a newer tree, reports success, and every downstream
# step then fails for reasons that look unrelated.
$script:ToolkitVersion = '0.17.0'

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
CN.version     = "0.17.0"
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
-- The full shape an objective may carry. Only the fields with a real default
-- are written; the rest are documentation, and assigning nil to them was
-- twenty wasted stores per objective and a hash part sized for twenty keys
-- when eight get used. At a few thousand objectives per rebuild that is
-- measurable, and this runs on every rebuild.
--
--   id, name, expansion, zone, mapID, x, y, eligibility, prerequisites,
--   unlocks, acquisitionMethod, source, availability, estimatedTime,
--   travelCost, rewards
--
function CN.NewObjective(fields)
    local objective = {
        type              = CN.objectiveTypes.QUEST,
        state             = CN.objectiveStates.UNKNOWN,
        accountWide       = false,
        characterSpecific = true,
        priorityWeight    = 0,
    }

    if type(fields) == "table" then
        for key, value in pairs(fields) do
            objective[key] = value
        end
    end

    return objective
end

------------------------------------------------------------
-- BOUNDED COLLECTION
------------------------------------------------------------

-- How many candidates one provider may contribute.
--
-- A provider that walks an entire collection can emit thousands of
-- objectives that all score identically -- 1200 uncollected pets, say, none
-- of which has a known location. Allocating all of them so that one can rank
-- first is waste, and it is waste paid on every rebuild.
CN.providerCandidateCap = 60

-- The post-hoc form, for providers whose candidates come from more than one
-- store and so cannot be counted in a single pass. The objectives are already
-- built by the time this runs, so it saves the ranking and sorting work
-- rather than the allocation.
--
-- Returns list, dropped.
function CN.CapCandidates(list, limit)
    limit = limit or CN.providerCandidateCap

    if #list <= limit then
        return list, 0
    end

    table.sort(list, function(a, b)
        local left  = a.completionValue or 0
        local right = b.completionValue or 0

        if left == right then
            return tostring(a.id) < tostring(b.id)
        end

        return left > right
    end)

    local dropped = #list - limit

    for index = #list, limit + 1, -1 do
        list[index] = nil
    end

    return list, dropped
end

-- Selects the highest-valued entries of a store without allocating an
-- objective for the ones that lose.
--
--   evaluate(id, record) -> value | nil     nil means "not a candidate"
--   build(id, record, value) -> objective | nil
--
-- Values are bucketed by integer, and the cut is found by counting buckets
-- rather than by sorting, so nothing proportional to the store is allocated.
-- Ties at the cut are broken by ID so the list does not reshuffle between
-- rebuilds.
--
-- Returns candidates, considered, dropped.
function CN.CollectBounded(source, limit, evaluate, build)
    limit = limit or CN.providerCandidateCap

    -- One evaluate call per entry, not three. The values are kept in a
    -- scratch table sized by how many entries qualify, which for every real
    -- store is far smaller than the store itself -- and far smaller than the
    -- objective tables this exists to avoid allocating.
    local values, counts = {}, {}

    local maxBucket, total = nil, 0

    for id, record in pairs(source) do
        local value = evaluate(id, record)

        if value then
            local bucket = math.floor(value)

            values[id]     = value
            counts[bucket] = (counts[bucket] or 0) + 1

            total = total + 1

            if not maxBucket or bucket > maxBucket then
                maxBucket = bucket
            end
        end
    end

    if total == 0 then
        return {}, 0, 0
    end

    -- Emit when bucket > threshold, or when bucket == threshold and the entry
    -- is among the lowest `allowance` IDs in that bucket.
    local threshold, allowance = -math.huge, 0

    if total > limit then
        local running = 0
        local bucket  = maxBucket

        while bucket ~= nil do
            local n = counts[bucket] or 0

            if running + n >= limit then
                threshold = bucket
                allowance = limit - running
                break
            end

            running = running + n

            -- Walk down to the next populated bucket.
            local nextBucket

            for candidate in pairs(counts) do
                if candidate < bucket and (not nextBucket or candidate > nextBucket) then
                    nextBucket = candidate
                end
            end

            bucket = nextBucket
        end
    end

    -- Which IDs in the cut bucket survive. Bounded by that bucket's size,
    -- never by the size of the store.
    local admitted

    if allowance > 0 then
        local atThreshold = {}

        for id, value in pairs(values) do
            if math.floor(value) == threshold then
                atThreshold[#atThreshold + 1] = id
            end
        end

        table.sort(atThreshold, function(a, b) return tostring(a) < tostring(b) end)

        admitted = {}

        for index = 1, math.min(allowance, #atThreshold) do
            admitted[atThreshold[index]] = true
        end
    end

    local candidates = {}

    for id, value in pairs(values) do
        if math.floor(value) > threshold or (admitted and admitted[id]) then
            local objective = build(id, source[id], value)

            if objective then
                candidates[#candidates + 1] = objective
            end
        end
    end

    return candidates, total, total - #candidates
end

------------------------------------------------------------
-- IGNORE / DEFER
------------------------------------------------------------

local function ObjectiveKey(objectiveType, id)
    return tostring(objectiveType) .. ":" .. tostring(id)
end

CN.ObjectiveKey = ObjectiveKey

-- These two are called twice for every candidate a provider considers, which
-- at retail scale is several thousand calls per rebuild. Each call used to
-- build a "TYPE:id" string, so the common case -- both lists empty, which is
-- true for most players most of the time -- was allocating thousands of
-- strings just to look up nothing. Measured at 12ms per 10,000 pairs.
--
-- next(t) == nil answers "is this table empty" without touching a key.
function CN.IsIgnored(objectiveType, id)
    local ignored = CN.Account("ignoredObjectives")

    if not ignored or next(ignored) == nil then
        return false
    end

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

    if not deferred or next(deferred) == nil then
        return false
    end

    local key   = ObjectiveKey(objectiveType, id)
    local entry = deferred[key]

    if not entry then
        return false
    end

    if entry.until_ and entry.until_ <= time() then
        deferred[key] = nil
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
--
-- options = {
--     events   = { "QUEST_ACCEPTED", ... },  -- what makes this provider stale
--     volatile = true,                       -- also expires on the clock
--     cooldown = 5,                          -- rebuild at most this often
-- }
--
-- cooldown is for providers subscribed to chatty events. CRITERIA_UPDATE and
-- UPDATE_FACTION fire many times a second during normal play, and rebuilding
-- a 3000-record provider on each one costs more than the answer is worth. The
-- provider stays marked stale and rebuilds on the first collection after the
-- cooldown expires, so the cost is bounded rather than the work skipped.
--
-- A provider that declares no events is treated as stale on every event. That
-- is the safe default and the old behaviour, but declaring events is what
-- makes an invalidation cost one provider instead of all nine.
CN.candidateProviders = CN.candidateProviders or {}

function CN.RegisterCandidateProvider(name, provider, options)
    options = options or {}

    local events

    if options.events then
        events = {}

        for _, event in ipairs(options.events) do
            events[event] = true
        end
    end

    CN.candidateProviders[name] = {
        name     = name,
        fn       = provider,
        events   = events,
        volatile = options.volatile and true or false,
        cooldown = options.cooldown,
    }
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

------------------------------------------------------------
-- CACHING
------------------------------------------------------------

-- Measured against a retail-scale database -- 1800 pets, 3000 achievements,
-- 500 factions, 2500 recipes -- the naive path cost 45ms to rebuild and,
-- worse, 15ms on every single call even with the candidate list cached,
-- because the whole list was re-scored and re-sorted every time. At 60fps a
-- frame is 16ms. Hovering the minimap button was dropping frames.
--
-- Three caches, each invalidated by the narrowest thing that can change it:
--
--   1. Per provider. NEW_PET_ADDED rebuilds Pets, not Achievements.
--   2. The aggregate list, rebuilt only when some provider actually was.
--   3. The scored and sorted list, reused until the aggregate or the
--      priority mode changes.
--
-- Volatile providers -- world quest timers, live rares, weekly currency
-- earning -- change without any event firing, so those alone also expire on
-- a short clock.

local providerCache = {}   -- [name] = { candidates, builtAt, dirty }

local aggregate = {
    candidates = nil,
    builtAt    = 0,
    generation = 0,
}

local ranked = {
    list       = nil,
    generation = -1,
    mode       = nil,
}

CN.candidateCacheSeconds = 5

-- Per-provider timings, so a slow provider can be identified rather than
-- guessed at.
CN.providerTimings = CN.providerTimings or {}

-- What each provider dropped to stay inside its budget. Reported by
-- /cn perf, because a cap nobody can see reads as "that is everything".
CN.providerTruncation = CN.providerTruncation or {}

local function Entry(name)
    local entry = providerCache[name]

    if not entry then
        entry = { candidates = nil, builtAt = 0, dirty = true, urgent = true }
        providerCache[name] = entry
    end

    return entry
end

-- reason == nil invalidates everything. A named event invalidates only the
-- providers that subscribed to it, plus any that declared no subscription.
--
-- An invalidation with no reason is an explicit one -- a scan finished, a
-- character logged in, a goal was pinned -- and it bypasses cooldowns. A
-- cooldown exists to stop a chatty *event* from causing work; it must never
-- delay something the player just did on purpose. Pinning a goal and not
-- seeing it appear for two seconds reads as the feature being broken.
function CN.InvalidateCandidates(reason)
    local hit = 0

    for name, provider in pairs(CN.candidateProviders) do
        if not reason or not provider.events or provider.events[reason] then
            local entry = Entry(name)

            entry.dirty = true

            if not reason then
                entry.urgent = true
            end

            hit = hit + 1
        end
    end

    if hit > 0 then
        -- Deliberately NOT clearing the aggregate here. Marking a provider
        -- stale is not the same as it having changed: a cooldown may hold the
        -- rebuild off, or the rebuild may produce an identical list. Only
        -- RefreshProviders knows whether anything was actually rebuilt, and
        -- discarding the aggregate here would bust the ranked cache on every
        -- QUEST_LOG_UPDATE for nothing.
        if reason then
            CN.DebugPrint("Candidate cache: " .. reason .. " invalidated " .. hit
                .. " provider" .. (hit == 1 and "" or "s"))
        end
    end
end

function CN.InvalidateProvider(name, urgent)
    if CN.candidateProviders[name] then
        local entry = Entry(name)

        entry.dirty = true

        if urgent then
            entry.urgent = true
        end
    end
end

-- Anything that can change what is actionable. Which providers each event
-- reaches is declared by the providers themselves.
for _, event in ipairs({
    "QUEST_ACCEPTED",
    "QUEST_TURNED_IN",
    "QUEST_REMOVED",
    "QUEST_LOG_UPDATE",
    "ACHIEVEMENT_EARNED",
    "CRITERIA_UPDATE",
    "UPDATE_FACTION",
    "NEW_PET_ADDED",
    "NEW_MOUNT_ADDED",
    "NEW_TOY_ADDED",
    "CURRENCY_DISPLAY_UPDATE",
    "VIGNETTE_MINIMAP_UPDATED",
    "VIGNETTES_UPDATED",
    "ZONE_CHANGED_NEW_AREA",
    "MERCHANT_SHOW",
    "TRADE_SKILL_LIST_UPDATE",
}) do
    CN:RegisterEvent(event, function()
        CN.InvalidateCandidates(event)
    end)
end

-- A different character means different Warband suitability, different
-- character-scoped reputations and a different recipe book.
CN:OnLogin(function()
    CN.InvalidateCandidates()
end)

local function RunProvider(name, provider)
    local startedAt = debugprofilestop and debugprofilestop() or nil

    local ok, result = pcall(provider.fn)

    if startedAt and debugprofilestop then
        local elapsed = debugprofilestop() - startedAt

        local timing = CN.providerTimings[name] or { calls = 0, total = 0, worst = 0 }

        timing.calls = timing.calls + 1
        timing.total = timing.total + elapsed
        timing.worst = math.max(timing.worst, elapsed)
        timing.last  = elapsed

        CN.providerTimings[name] = timing
    end

    if ok and type(result) == "table" then
        return result
    end

    if not ok then
        CN.DebugPrint("Candidate provider " .. name .. " failed: " .. tostring(result))
    end

    return {}
end

-- Decoration happens once per objective, when its provider builds it.
--
-- It used to run over the whole aggregate on every rebuild. That was fine
-- when every collection rebuilt everything, but per-provider caching means
-- the aggregate is mostly the SAME objective tables as last time -- so a
-- decorator that appends a reason (Warband's does) appended it again, and
-- again, and the recommendation grew a stack of identical lines.
local function Decorate(candidates)
    for name, decorator in pairs(CN.candidateDecorators) do
        for index = 1, #candidates do
            local ok, err = pcall(decorator, candidates[index])

            if not ok then
                CN.DebugPrint("Candidate decorator " .. name .. " failed: " .. tostring(err))
                break
            end
        end
    end
end

local function RefreshProviders(force)
    local now     = time()
    local rebuilt = 0

    for name, provider in pairs(CN.candidateProviders) do
        local entry = Entry(name)

        local cooled = entry.urgent
            or provider.cooldown == nil
            or (now - entry.builtAt) >= provider.cooldown

        local stale = force
            or entry.candidates == nil
            or (entry.dirty and cooled)
            or (provider.volatile
                and (now - entry.builtAt) >= CN.candidateCacheSeconds)

        if stale then
            entry.candidates = RunProvider(name, provider)

            -- Decorate here, not over the aggregate: these objectives are
            -- new, and every other provider's are not.
            Decorate(entry.candidates)

            entry.builtAt = now
            entry.dirty   = false
            entry.urgent  = false

            rebuilt = rebuilt + 1
        end
    end

    return rebuilt
end


function CN.CollectCandidates(force)
    local rebuilt = RefreshProviders(force)

    -- Nothing was rebuilt, so the aggregate cannot have changed.
    if aggregate.candidates and rebuilt == 0 then
        return aggregate.candidates
    end

    local candidates = {}

    for name in pairs(CN.candidateProviders) do
        local list = providerCache[name] and providerCache[name].candidates

        if list then
            for index = 1, #list do
                candidates[#candidates + 1] = list[index]
            end
        end
    end

    aggregate.candidates = candidates
    aggregate.builtAt    = time()
    aggregate.generation = aggregate.generation + 1

    return candidates
end

function CN.GetCandidateCacheState()
    local providers, fresh, dirty = 0, 0, 0

    for name in pairs(CN.candidateProviders) do
        providers = providers + 1

        local entry = providerCache[name]

        if entry and entry.candidates and not entry.dirty then
            fresh = fresh + 1
        else
            dirty = dirty + 1
        end
    end

    return {
        cached     = aggregate.candidates ~= nil,
        count      = aggregate.candidates and #aggregate.candidates or 0,
        dirty      = aggregate.candidates == nil or dirty > 0,
        age        = aggregate.candidates and (time() - aggregate.builtAt) or nil,
        generation = aggregate.generation,
        providers  = providers,
        fresh      = fresh,
        stale      = dirty,
        ranked     = ranked.generation == aggregate.generation,
    }
end

function CN.GetProviderCacheState(name)
    local entry = providerCache[name]

    if not entry then
        return nil
    end

    return {
        cached = entry.candidates ~= nil,
        count  = entry.candidates and #entry.candidates or 0,
        dirty  = entry.dirty,
        age    = entry.candidates and (time() - entry.builtAt) or nil,
    }
end

------------------------------------------------------------
-- RECOMMENDATION
------------------------------------------------------------

-- Scoring and sorting a few thousand candidates is not free, and every
-- caller wants the same ordering. Keep the ranked list until either the
-- candidate set or the priority mode changes.
local function Ranked()
    local settings = CN.Settings()
    local mode     = (settings and settings.priorityMode) or "balanced"

    local candidates = CN.CollectCandidates()

    if ranked.list
        and ranked.generation == aggregate.generation
        and ranked.mode == mode then

        return ranked.list
    end

    -- Sorting a copy, not the aggregate. Callers that walk the candidate
    -- list -- zone routing, for one -- must not have it reordered under
    -- them as a side effect of somebody asking for a recommendation.
    local list = {}

    for index = 1, #candidates do
        local objective = candidates[index]

        CN.ScoreObjective(objective)

        list[index] = objective
    end

    table.sort(list, function(a, b)
        local left  = a.priorityWeight or 0
        local right = b.priorityWeight or 0

        if left == right then
            -- Ties must break deterministically or the list shuffles between
            -- refreshes and reads as flicker.
            return tostring(a.id) < tostring(b.id)
        end

        return left > right
    end)

    ranked.list       = list
    ranked.generation = aggregate.generation
    ranked.mode       = mode

    return list
end

CN.RankedCandidates = Ranked

function CN.Recommend(limit)
    limit = limit or 1

    local list = Ranked()

    local results = {}

    for index = 1, math.min(limit, #list) do
        results[index] = list[index]
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
    name    = "perf",
    order   = 90,
    help    = "Show candidate provider timings, cache state and any caps hit.",
    handler = function()
        local state = CN.GetCandidateCacheState()

        CN.Print("Candidate cache: "
            .. (state.cached and (state.count .. " objectives") or "empty")
            .. (state.dirty and " |cffffff00(stale)|r" or "")
            .. (state.age and (" |cff999999" .. state.age .. "s old|r") or ""))

        CN.Print("Providers: " .. state.fresh .. " of " .. state.providers
            .. " cached, ranked list "
            .. (state.ranked and "|cff00ff00reused|r" or "|cffffff00rebuilding|r"))

        local rows = {}

        for name, timing in pairs(CN.providerTimings) do
            local cache = CN.GetProviderCacheState(name)

            table.insert(rows, {
                name    = name,
                average = timing.calls > 0 and (timing.total / timing.calls) or 0,
                worst   = timing.worst,
                calls   = timing.calls,
                cached  = cache and cache.cached and not cache.dirty,
            })
        end

        if #rows == 0 then
            CN.Print("No timings recorded yet. Run |cffffff00/cn next|r first.")
            CN.Print("|cff999999Timings need debugprofilestop, which exists in game "
                .. "but not in offline tests.|r")
            return
        end

        table.sort(rows, function(a, b) return a.average > b.average end)

        CN.Print("Providers, slowest first:")

        for _, row in ipairs(rows) do
            CN.Print(string.format("  %-14s avg %.2fms  worst %.2fms  (%d %s)%s",
                row.name, row.average, row.worst, row.calls,
                row.calls == 1 and "call" or "calls",
                row.cached and "" or " |cffffff00stale|r"))
        end

        -- A cap nobody can see reads as "that was everything".
        local capped = false

        for name, truncation in pairs(CN.providerTruncation) do
            if (truncation.dropped or 0) > 0 then
                if not capped then
                    CN.Print("Capped at " .. CN.providerCandidateCap .. " per provider:")
                    capped = true
                end

                CN.Print("  " .. name .. ": showing " .. CN.providerCandidateCap
                    .. " of " .. truncation.considered
                    .. " |cff999999(" .. truncation.dropped .. " lower-valued dropped)|r")
            end
        end

        if capped then
            CN.Print("|cff999999Dropped entries scored no higher than the ones kept. "
                .. "Full counts are in /cn breakdown.|r")
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
-- TAB: GOALS
------------------------------------------------------------

UI.RegisterTab{
    name  = "Goals",
    order = 15,

    build = function(panel)
        panel.header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        panel.header:SetPoint("TOPLEFT", 8, -8)
        panel.header:SetPoint("TOPRIGHT", -8, -8)
        panel.header:SetJustifyH("LEFT")

        panel.list = CreateList(panel)
        panel.list:ClearAllPoints()
        panel.list:SetPoint("TOPLEFT", 4, -32)
        panel.list:SetPoint("BOTTOMRIGHT", -8, 64)

        panel.navigate = AddButton(panel, "Navigate", 110, function()
            local goals = CN:GetModule("Goals")

            if not goals or not panel.selected then
                return
            end

            local plan = goals.Plan(panel.selected)

            if plan.mapID and plan.x and plan.y then
                CN.NavigateToObjective({
                    id    = panel.selected.id,
                    type  = panel.selected.type,
                    name  = plan.name,
                    mapID = plan.mapID,
                    x     = plan.x,
                    y     = plan.y,
                })
            else
                CN.Print("No location is known for " .. tostring(plan.name) .. ".")
            end
        end)
        panel.navigate:SetPoint("BOTTOMLEFT", 8, 34)

        panel.remove = AddButton(panel, "Remove goal", 110, function()
            local goals = CN:GetModule("Goals")

            if not goals or not panel.selected then
                return
            end

            goals.Remove(panel.selected.type, panel.selected.id)

            panel.selected = nil

            UI.Refresh()
        end)
        panel.remove:SetPoint("LEFT", panel.navigate, "RIGHT", 6, 0)

        panel.note = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
        panel.note:SetPoint("BOTTOMLEFT", 12, 12)
        panel.note:SetPoint("RIGHT", -12, 0)
        panel.note:SetJustifyH("LEFT")
    end,

    refresh = function(panel)
        local goals = CN:GetModule("Goals")

        if not goals then
            panel.header:SetText("Goals module not loaded.")
            panel.list:SetEntries({})
            return
        end

        local list = goals.List()

        panel.header:SetText(#list .. " goal" .. (#list == 1 and "" or "s")
            .. " |cff999999of " .. goals.limit .. "|r")

        if #list == 0 then
            panel.list:SetEntries({})
            panel.note:SetText("|cffffff00Nothing pinned. Use |r/cn goal <type> <id>|cffffff00 "
                .. "to pin something to work toward. A goal becomes actionable even "
                .. "when nothing else would surface it, and anything leading to it "
                .. "ranks higher.|r")
            return
        end

        -- Keep the selection valid across refreshes; a removed goal must not
        -- leave the buttons pointed at nothing.
        if panel.selected then
            local stillThere = false

            for _, goal in ipairs(list) do
                if goal.type == panel.selected.type and goal.id == panel.selected.id then
                    stillThere = true
                    break
                end
            end

            if not stillThere then
                panel.selected = nil
            end
        end

        panel.selected = panel.selected or list[1]

        local entries = {}

        for _, goal in ipairs(list) do
            local plan = goals.Plan(goal)

            local isSelected = panel.selected
                and panel.selected.type == goal.type
                and panel.selected.id == goal.id

            table.insert(entries, {
                text = (isSelected and "|cff00ff00>|r " or "  ")
                    .. (plan.done and "|cff999999" or "|cffffff00")
                    .. tostring(goal.name) .. "|r"
                    .. " |cff999999(" .. tostring(goal.type) .. ")|r"
                    .. (plan.done and " |cff00ff00done|r" or ""),

                tooltip = tostring(goal.name) .. "\n"
                    .. (plan.source and (plan.source .. "\n") or "")
                    .. table.concat(plan.steps, "\n"),

                onClick = function()
                    panel.selected = goal
                    UI.Refresh()
                end,
            })

            if plan.source then
                table.insert(entries, { text = "      |cff999999" .. plan.source .. "|r" })
            end

            for _, step in ipairs(plan.steps) do
                table.insert(entries, { text = "      |cff999999" .. step .. "|r" })
            end
        end

        panel.list:SetEntries(entries)

        local plan = goals.Plan(panel.selected)

        if plan.mapID and plan.x and plan.y then
            panel.note:SetText("|cff999999Selected: " .. tostring(plan.name)
                .. " -- " .. (plan.zone or ("map " .. plan.mapID)) .. "|r")
        else
            panel.note:SetText("|cff999999Selected: " .. tostring(plan.name)
                .. " -- no location known|r")
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

        panel.tooltips = AddCheckbox(panel, "Add lines to item and unit tooltips",
            function() return CN.Settings().tooltips ~= false end,
            function(value) CN.Settings().tooltips = value end)
        panel.tooltips:SetPoint("TOPLEFT", panel.minimap, "BOTTOMLEFT", 0, -6)

        panel.setup = AddButton(panel, "Scan everything now", 180, function()
            local setup = CN:GetModule("Setup")

            if setup then
                setup.Run()
            end
        end)
        panel.setup:SetPoint("TOPLEFT", panel.tooltips, "BOTTOMLEFT", 0, -12)

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
        panel.tooltips.Refresh()

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

        -- The recommendation is the whole point of the addon, so put it where
        -- it costs nothing to read. This is cheap now: candidates are cached,
        -- so hovering the button does not rebuild fourteen providers.
        local ok, results = pcall(CN.Recommend, 1)

        if ok and results and results[1] then
            local objective = results[1]

            GameTooltip:AddLine("Next: " .. tostring(objective.name or objective.id),
                0.2, 1.0, 0.6)

            local reasons = CN.ExplainRecommendation(objective)

            for index, reason in ipairs(reasons) do
                if index > 2 then
                    break
                end

                GameTooltip:AddLine(reason, 0.6, 0.6, 0.6)
            end
        else
            GameTooltip:AddLine("Nothing actionable is known yet.", 0.6, 0.6, 0.6)
            GameTooltip:AddLine("Run /cn setup once.", 0.6, 0.6, 0.6)
        end

        GameTooltip:AddLine(" ")
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

------------------------------------------------------------
-- MERCHANTS
------------------------------------------------------------

-- Vendor inventories are only readable while the merchant window is open,
-- exactly like trade skill recipes. Everything here is opportunistic.
function Blizzard.GetMerchantItems()
    local items = {}

    if not GetMerchantNumItems then
        return items
    end

    local ok, count = pcall(GetMerchantNumItems)

    if not ok or type(count) ~= "number" then
        return items
    end

    for index = 1, count do
        local gotInfo, name, texture, price, quantity, numAvailable,
              isPurchasable, isUsable, extendedCost =
              pcall(GetMerchantItemInfo, index)

        if gotInfo and name then
            local itemID

            if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
                local gotItem, info = pcall(C_MerchantFrame.GetItemInfo, index)

                if gotItem and type(info) == "table" then
                    itemID = info.itemID
                end
            end

            if not itemID and GetMerchantItemLink then
                local gotLink, link = pcall(GetMerchantItemLink, index)

                if gotLink and type(link) == "string" then
                    itemID = tonumber(link:match("item:(%d+)"))
                end
            end

            table.insert(items, {
                index         = index,
                itemID        = itemID,
                name          = name,
                price         = price,
                available     = numAvailable,
                isPurchasable = isPurchasable and true or false,
                extendedCost  = extendedCost and true or false,
            })
        end
    end

    return items
end

-- The creature ID behind any unit token. The GUID carries it, and it is the
-- only stable identifier for an NPC.
function Blizzard.GetUnitNPCID(unit)
    if not unit or not UnitExists or not UnitExists(unit) then
        return nil, nil
    end

    local name = UnitName and UnitName(unit) or nil

    local guid = UnitGUID and UnitGUID(unit)

    if not guid then
        return nil, name
    end

    -- GUID form: Creature-0-serverID-instanceID-zoneUID-npcID-spawnUID
    --
    -- The extra parentheses matter: select(6, ...) returns every value from
    -- position 6 onward, so without them tonumber receives the spawn UID as
    -- its `base` argument and throws.
    local npcID = tonumber((select(6, strsplit("-", guid))))

    return npcID, name
end

-- The NPC currently being interacted with.
function Blizzard.GetInteractingNPC()
    return Blizzard.GetUnitNPCID("npc")
end

------------------------------------------------------------
-- ITEM IDENTITY
------------------------------------------------------------

-- Items that teach a collectible do not announce themselves as such; each
-- collection API has its own item lookup. All three are optional and all
-- three have changed shape before, so each is probed rather than assumed.

function Blizzard.GetMountFromItem(itemID)
    if not itemID or not C_MountJournal or not C_MountJournal.GetMountFromItem then
        return nil
    end

    return C_MountJournal.GetMountFromItem(itemID)
end

function Blizzard.GetPetSpeciesFromItem(itemID)
    if not itemID or not C_PetJournal or not C_PetJournal.GetPetInfoByItemID then
        return nil, nil
    end

    local name, icon, petType, companionID, tooltipSource, description,
          isWild, canBattle, isTradeable, isUnique, obtainable, creatureDisplayID,
          speciesID = C_PetJournal.GetPetInfoByItemID(itemID)

    -- The species ID has moved position in this return list before. Falling
    -- back to the companion ID keeps the lookup working either way.
    return speciesID or companionID, name
end

-- Returns true/false only for items that actually have an appearance, and nil
-- for everything else.
--
-- The gate matters. PlayerHasTransmogByItemInfo answers false for a stack of
-- ore just as readily as for an unlearned tabard, so using it alone would
-- stamp "appearance not yet known" on every trade good in the game.
function Blizzard.HasTransmogByItem(itemID)
    if not itemID or not C_TransmogCollection then
        return nil
    end

    if not C_TransmogCollection.GetItemInfo then
        return nil
    end

    local ok, appearanceID = pcall(C_TransmogCollection.GetItemInfo, itemID)

    if not ok or not appearanceID then
        return nil
    end

    if C_TransmogCollection.PlayerHasTransmogByItemInfo then
        local hasOk, has = pcall(C_TransmogCollection.PlayerHasTransmogByItemInfo, itemID)

        if hasOk then
            return has and true or false
        end
    end

    return nil
end

function Blizzard.GetItemName(itemID)
    if not itemID then
        return nil
    end

    if C_Item and C_Item.GetItemNameByID then
        return C_Item.GetItemNameByID(itemID)
    end

    if GetItemInfo then
        return (GetItemInfo(itemID))
    end

    return nil
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
end, { events = { "QUEST_ACCEPTED", "QUEST_TURNED_IN", "QUEST_REMOVED", "QUEST_LOG_UPDATE", "ZONE_CHANGED_NEW_AREA" }, cooldown = 2 })

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

    CN.MarkScanned("reputations")

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

    -- Two stores, so this one cannot be counted in a single pass; cap after
    -- the fact instead.
    local kept, dropped = CN.CapCandidates(candidates)

    CN.providerTruncation["Reputations"] = {
        considered = #kept + dropped,
        dropped    = dropped,
    }

    return kept
end, { events = { "UPDATE_FACTION" }, cooldown = 5 })

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

    CN.MarkScanned("achievements")

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
    local candidates, considered, dropped = CN.CollectBounded(Store(), nil,
        function(achievementID, record)
            local criteria = record.criteria or 0

            if criteria <= 0 then
                return nil
            end

            local remaining = criteria - (record.done or 0)

            -- A zero-progress achievement is a project, not a next action.
            if remaining <= 0 or remaining > 2 then
                return nil
            end

            if CN.IsIgnored(CN.objectiveTypes.ACHIEVEMENT, achievementID)
                or CN.IsDeferred(CN.objectiveTypes.ACHIEVEMENT, achievementID) then
                return nil
            end

            return 3 - remaining
        end,
        function(achievementID, record, value)
            local remaining = (record.criteria or 0) - (record.done or 0)

            return CN.NewObjective({
                id              = achievementID,
                type            = CN.objectiveTypes.ACHIEVEMENT,
                name            = record.name,
                accountWide     = true,
                completionValue = value,
                reasons         = {
                    remaining .. " of " .. record.criteria .. " criteria left",
                    tostring(record.points or 0) .. " achievement points",
                },
            })
        end)

    CN.providerTruncation["Achievements"] = { considered = considered, dropped = dropped }

    return candidates
end, { events = { "ACHIEVEMENT_EARNED", "CRITERIA_UPDATE" }, cooldown = 5 })

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

    CN.MarkScanned("pets")

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
-- Retail has around 1800 species, of which most players are missing several
-- hundred. Emitting one objective per missing pet meant allocating a thousand
-- tables per rebuild so that at most a handful could ever rank -- and they all
-- score identically anyway, since none of them carries a location. Take the
-- best of them instead, and report what was dropped.
CN.RegisterCandidateProvider("Pets", function()
    local candidates, considered, dropped = CN.CollectBounded(Store(), nil,
        function(speciesID, record)
            if record.collected or record.obtainable == false then
                return nil
            end

            if CN.IsIgnored(CN.objectiveTypes.PET, speciesID)
                or CN.IsDeferred(CN.objectiveTypes.PET, speciesID) then
                return nil
            end

            -- A wild pet is something you can go and catch; anything else is
            -- a wish. That is the whole ranking.
            return record.isWild and 2 or 1
        end,
        function(speciesID, record, value)
            local reasons = {}

            if record.isWild then
                table.insert(reasons, "wild pet, catchable in the world")
            end

            return CN.NewObjective({
                id              = speciesID,
                type            = CN.objectiveTypes.PET,
                name            = record.name,
                accountWide     = true,
                completionValue = value,
                reasons         = reasons,
            })
        end)

    CN.providerTruncation["Pets"] = { considered = considered, dropped = dropped }

    return candidates
end, { events = { "NEW_PET_ADDED" } })

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

    CN.MarkScanned("mounts")

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

    CN.MarkScanned("toys")

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

    CN.MarkScanned("appearances")

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

    CN.MarkScanned("titles")

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

    CN.MarkScanned("recipes")

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
end, { events = { "QUEST_LOG_UPDATE", "ZONE_CHANGED_NEW_AREA" }, volatile = true })

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
end, { events = { "VIGNETTE_MINIMAP_UPDATED", "VIGNETTES_UPDATED", "ZONE_CHANGED_NEW_AREA" }, volatile = true })

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

    CN.MarkScanned("currencies")

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
end, { events = { "CURRENCY_DISPLAY_UPDATE" }, volatile = true })

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

    CN.MarkScanned("exploration")

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
end, { events = { "CRITERIA_UPDATE", "ZONE_CHANGED_NEW_AREA" } })

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

$Embedded['Modules\Filters.lua'] = @'
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
'@

$Embedded['Modules\Vendors.lua'] = @'
-- Modules/Vendors.lua
-- Completion Navigator :: who sells what, and where they stand.
--
-- This is the module the flagship example in the design needs:
--
--   Recipe X is sold by Vendor A. Vendor A is in <zone> at <coords>.
--   The recipe requires Revered with Faction B. This character is Honored.
--   Another character is already Revered and has the profession.
--   -> Switch to that character and buy it.
--
-- Every other piece of that already exists. The missing link was that
-- nothing knew where anything is sold.
--
-- Vendor inventories are only readable while the merchant window is open --
-- the same client restriction as trade skill recipes. So this records every
-- vendor you talk to, permanently and account-wide, and the database grows
-- as you play rather than shipping stale.

local ADDON_NAME, CN = ...

local Vendors = CN:RegisterModule("Vendors")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

local function Store()
    return CN.Account("vendors")
end

-- Reverse index: itemID -> { npcID, npcID, ... }. Rebuilt from the vendor
-- store rather than persisted, so it can never drift out of sync with it.
local itemIndex, itemIndexBuiltAt = nil, 0

Vendors.Store = Store

------------------------------------------------------------
-- RECORDING
------------------------------------------------------------

function Vendors.CaptureOpenMerchant()
    local npcID, npcName = Blizzard.GetInteractingNPC()

    if not npcID then
        return false, 0
    end

    local items = Blizzard.GetMerchantItems()

    if #items == 0 then
        return false, 0
    end

    local store  = Store()
    local record = store[npcID] or { npcID = npcID, firstSeen = time() }

    record.name     = npcName or record.name
    record.lastSeen = time()

    local mapID, x, y = CN.GetPlayerPosition()

    -- Keep the first location seen; vendors do not move, and later readings
    -- are just wherever you happened to be standing when you opened the
    -- window a second time.
    if mapID and x and y and not record.mapID then
        record.mapID = mapID
        record.x     = math.floor(x * 10000 + 0.5) / 10000
        record.y     = math.floor(y * 10000 + 0.5) / 10000
        record.zone  = Blizzard.GetMapName(mapID)
    end

    record.items = {}

    for _, item in ipairs(items) do
        if item.itemID then
            record.items[item.itemID] = {
                name         = item.name,
                price        = item.price,
                extendedCost = item.extendedCost,
            }
        end
    end

    record.itemCount = CN.CountKeys(record.items)

    store[npcID] = record

    -- The reverse index is now stale.
    itemIndex = nil

    CN.MarkScanned("vendors")

    return true, record.itemCount
end

------------------------------------------------------------
-- LOOKUP
------------------------------------------------------------

local function BuildItemIndex()
    local index = {}

    for npcID, record in pairs(Store()) do
        for itemID in pairs(record.items or {}) do
            index[itemID] = index[itemID] or {}
            table.insert(index[itemID], npcID)
        end
    end

    itemIndex        = index
    itemIndexBuiltAt = time()

    return index
end

-- The candidate provider asks this question thousands of times per rebuild,
-- once per known recipe, and almost always gets no answer. WhoSells allocates
-- a result array every time it is called; this does not allocate at all until
-- there is something to return.
function Vendors.FirstLocatedSeller(itemID)
    if not itemID then
        return nil
    end

    local index = itemIndex or BuildItemIndex()

    local npcIDs = index[itemID]

    if not npcIDs then
        return nil
    end

    local store = Store()

    for _, npcID in ipairs(npcIDs) do
        local record = store[npcID]

        if record and record.mapID and record.x and record.y then
            return record, npcID
        end
    end

    return nil
end

function Vendors.WhoSells(itemID)
    if not itemID then
        return {}
    end

    local index = itemIndex or BuildItemIndex()

    local sellers = {}

    for _, npcID in ipairs(index[itemID] or {}) do
        local record = Store()[npcID]

        if record then
            table.insert(sellers, {
                npcID = npcID,
                name  = record.name,
                zone  = record.zone,
                mapID = record.mapID,
                x     = record.x,
                y     = record.y,
                item  = record.items and record.items[itemID],
            })
        end
    end

    return sellers
end

-- Finds an item by name across every recorded vendor. This is what makes
-- "who sells Flask of Testing" work without knowing an item ID.
function Vendors.FindItem(text)
    if not text or text == "" then
        return nil, {}
    end

    local itemID = CN.ToID(text)

    if itemID then
        return itemID, Vendors.WhoSells(itemID)
    end

    local needle  = string.lower(text)
    local matches = {}

    for npcID, record in pairs(Store()) do
        for id, item in pairs(record.items or {}) do
            if item.name and string.find(string.lower(item.name), needle, 1, true) then
                matches[id] = item.name
            end
        end
    end

    local bestID, bestName

    for id, name in pairs(matches) do
        if not bestName or #name < #bestName then
            bestID, bestName = id, name
        end
    end

    if not bestID then
        return nil, {}
    end

    return bestID, Vendors.WhoSells(bestID)
end

function Vendors.Summary()
    local counts = { vendors = 0, items = 0, located = 0 }

    local uniqueItems = {}

    for _, record in pairs(Store()) do
        counts.vendors = counts.vendors + 1

        if record.x and record.y then
            counts.located = counts.located + 1
        end

        for itemID in pairs(record.items or {}) do
            uniqueItems[itemID] = true
        end
    end

    counts.items = CN.CountKeys(uniqueItems)

    return counts
end

------------------------------------------------------------
-- RECIPE LINKING
------------------------------------------------------------

-- The payoff: a recipe this character does not know, sold by a vendor whose
-- location is recorded, becomes an objective with real coordinates.
CN.RegisterCandidateProvider("Vendors", function()
    local professions = CN:GetModule("Professions")

    if not professions then
        return {}
    end

    local known = professions.CharacterRecipes() or {}
    local names = professions.RecipeNames()

    local playerMap = select(1, CN.GetPlayerPosition())

    local candidates, considered, dropped = CN.CollectBounded(names, nil,
        function(itemID)
            if known[itemID] then
                return nil
            end

            if CN.IsIgnored(CN.objectiveTypes.RECIPE, itemID)
                or CN.IsDeferred(CN.objectiveTypes.RECIPE, itemID) then
                return nil
            end

            local seller = Vendors.FirstLocatedSeller(itemID)

            if not seller then
                return nil
            end

            -- A recipe you can walk to in this zone beats one across the
            -- continent, and that is the only distinction worth ranking here.
            return (seller.mapID == playerMap) and 3 or 2
        end,
        function(itemID, recipeName)
            local seller = Vendors.FirstLocatedSeller(itemID)

            if not seller then
                return nil
            end

            local reasons = { "sold by " .. tostring(seller.name) }

            if seller.zone then
                table.insert(reasons, "in " .. seller.zone)
            end

            return CN.NewObjective({
                id              = itemID,
                type            = CN.objectiveTypes.RECIPE,
                name            = recipeName,
                mapID           = seller.mapID,
                x               = seller.x,
                y               = seller.y,
                completionValue = 2,
                travelCost      = (seller.mapID == playerMap) and 2 or 25,
                reasons         = reasons,
            })
        end)

    CN.providerTruncation["Vendors"] = { considered = considered, dropped = dropped }

    return candidates
end, { events = { "MERCHANT_SHOW", "TRADE_SKILL_LIST_UPDATE", "ZONE_CHANGED_NEW_AREA" }, cooldown = 5 })

------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

CN:RegisterEvent("MERCHANT_SHOW", function()
    local captured, count = Vendors.CaptureOpenMerchant()

    if captured then
        DebugPrint("Recorded vendor with " .. count .. " items.")
    end
end)

CN:RegisterEvent("MERCHANT_UPDATE", function()
    Vendors.CaptureOpenMerchant()
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "vendors",
    order   = 79,
    help    = "Summarize recorded vendors.",
    handler = function()
        local counts = Vendors.Summary()

        if counts.vendors == 0 then
            Print("No vendors recorded yet.")
            Print("|cff999999Open a merchant window and the addon records "
                .. "what they sell and where they stand.|r")
            return
        end

        Print("Vendors recorded: " .. counts.vendors
            .. " (" .. counts.located .. " with coordinates)")
        Print("Distinct items seen: " .. counts.items)
    end,
}

CN:RegisterCommand{
    name    = "sells",
    aliases = { "whosells" },
    args    = "<itemID or name>",
    order   = 80,
    help    = "Find which recorded vendor sells something.",
    handler = function(args)
        if args == "" then
            Print("Usage: /cn sells <itemID or name>")
            return
        end

        local itemID, sellers = Vendors.FindItem(args)

        if not itemID or #sellers == 0 then
            Print("Nothing recorded matches: " .. args)
            Print("|cff999999Only vendors you have opened are known.|r")
            return
        end

        Print("Item " .. itemID .. " is sold by:")

        for index, seller in ipairs(sellers) do
            Print("  " .. index .. ". " .. tostring(seller.name)
                .. (seller.zone and (" |cff999999in " .. seller.zone .. "|r") or "")
                .. (seller.x and string.format(" |cff999999%.1f, %.1f|r",
                    seller.x * 100, seller.y * 100) or ""))
        end

        Print("|cffffff00/cn tovendor " .. itemID .. "|r to set a waypoint.")
    end,
}

CN:RegisterCommand{
    name    = "tovendor",
    args    = "<itemID or name>",
    order   = 81,
    help    = "Navigate to a vendor that sells something.",
    handler = function(args)
        if args == "" then
            Print("Usage: /cn tovendor <itemID or name>")
            return
        end

        local itemID, sellers = Vendors.FindItem(args)

        if not itemID or #sellers == 0 then
            Print("Nothing recorded matches: " .. args)
            return
        end

        for _, seller in ipairs(sellers) do
            if seller.mapID and seller.x and seller.y then
                CN.NavigateToObjective({
                    id    = seller.npcID,
                    type  = CN.objectiveTypes.VENDOR,
                    name  = seller.name,
                    mapID = seller.mapID,
                    x     = seller.x,
                    y     = seller.y,
                })

                return
            end
        end

        Print("No recorded seller has coordinates yet.")
    end,
}

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
'@

$Embedded['Modules\Tooltips.lua'] = @'
-- Modules/Tooltips.lua
-- Completion Navigator :: what the addon knows, shown where you are looking.
--
-- Everything in this addon already knows whether you own a toy, which of your
-- characters knows a recipe, and which vendor sells an item. Until now you had
-- to go and ask. A tooltip is where that question actually gets asked -- while
-- hovering the thing in a vendor list, a loot window or the auction house.
--
-- The line-building functions are deliberately separate from the hooks: the
-- lines are pure data, so they can be tested offline, and the hooks are a thin
-- adapter over whichever tooltip API the client is running.

local ADDON_NAME, CN = ...

local Tooltips = CN:RegisterModule("Tooltips")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

local GREEN  = { 0.4, 1.0, 0.4 }
local RED    = { 1.0, 0.4, 0.4 }
local YELLOW = { 1.0, 0.85, 0.3 }
local GREY   = { 0.6, 0.6, 0.6 }

local HEADER = "Completion Navigator"

local function Enabled()
    local settings = CN.Settings()

    return settings and settings.tooltips ~= false
end

Tooltips.Enabled = Enabled

------------------------------------------------------------
-- LINE BUILDERS
------------------------------------------------------------

local function Add(lines, text, color)
    table.insert(lines, { text = text, color = color or GREY })
end

local function CollectedLine(lines, label, collected)
    if collected then
        Add(lines, label .. ": collected", GREEN)
    else
        Add(lines, label .. ": not collected", RED)
    end
end

-- Toys are keyed by item ID in both the toy box and our own store, so this is
-- the one collection lookup that needs no translation.
local function ToyLines(lines, itemID)
    local record = CN.Account("toys")[itemID]

    if record then
        CollectedLine(lines, "Toy", record.collected)
        return true
    end

    -- No scan yet, but the client can still answer for this one item.
    if PlayerHasToy and C_ToyBox and C_ToyBox.GetToyInfo then
        local _, name = C_ToyBox.GetToyInfo(itemID)

        if name then
            CollectedLine(lines, "Toy", PlayerHasToy(itemID))
            return true
        end
    end

    return false
end

local function MountLines(lines, itemID)
    local mountID = Blizzard.GetMountFromItem(itemID)

    if not mountID then
        return false
    end

    local record = CN.Account("mounts")[mountID]

    if record then
        CollectedLine(lines, "Mount", record.collected)

        if record.isFactionSpecific and record.faction then
            Add(lines, "Faction-locked", YELLOW)
        end

        return true
    end

    local mount = Blizzard.GetMountByID(mountID)

    if mount then
        CollectedLine(lines, "Mount", mount.isCollected)
        return true
    end

    return false
end

local function PetLines(lines, itemID)
    local speciesID = Blizzard.GetPetSpeciesFromItem(itemID)

    if not speciesID then
        return false
    end

    local record = CN.Account("pets")[speciesID]

    local count, limit

    if record then
        count, limit = record.count, record.limit
    else
        count, limit = Blizzard.GetPetCollectedCount(speciesID)
    end

    count = count or 0
    limit = limit or 3

    if count > 0 then
        Add(lines, "Battle pet: collected " .. count .. " of " .. limit, GREEN)
    else
        Add(lines, "Battle pet: not collected", RED)
    end

    return true
end

local function AppearanceLines(lines, itemID)
    local has = Blizzard.HasTransmogByItem(itemID)

    if has == nil then
        return false
    end

    if has then
        Add(lines, "Appearance: already known", GREEN)
    else
        Add(lines, "Appearance: not yet known", RED)
    end

    return true
end

-- Recipes are the messy case. The trade skill API keys recipes by recipe ID
-- while a vendor sells an item ID, and the two are not the same number. The
-- ID lookup is tried first because it is exact; the name match is the fallback
-- that actually fires most of the time, and it is reported as a match on name
-- rather than dressed up as certainty.
local function RecipeLines(lines, itemID, itemName)
    local professions = CN:GetModule("Professions")

    if not professions then
        return false
    end

    local names = professions.RecipeNames() or {}
    local mine  = professions.CharacterRecipes() or {}

    local recipeID, matchedOnName

    if names[itemID] then
        recipeID = itemID
    elseif itemName and itemName ~= "" then
        -- "Recipe: Flask of Testing" teaches "Flask of Testing".
        local needle = string.lower(itemName)

        for id, name in pairs(names) do
            if name and name ~= "" then
                local candidate = string.lower(name)

                if candidate == needle or string.find(needle, candidate, 1, true) then
                    recipeID      = id
                    matchedOnName = true
                    break
                end
            end
        end
    end

    if not recipeID then
        return false
    end

    if mine[recipeID] then
        Add(lines, "Recipe: known by this character", GREEN)
    else
        Add(lines, "Recipe: not known by this character", RED)

        local holders = professions.WhoKnows(recipeID) or {}

        if #holders > 0 then
            Add(lines, "Known by: " .. table.concat(holders, ", "), YELLOW)
        end
    end

    if matchedOnName then
        Add(lines, "matched by name", GREY)
    end

    return true
end

local function VendorLines(lines, itemID)
    local vendors = CN:GetModule("Vendors")

    if not vendors then
        return false
    end

    local sellers = vendors.WhoSells(itemID)

    if #sellers == 0 then
        return false
    end

    for index, seller in ipairs(sellers) do
        if index > 3 then
            Add(lines, "and " .. (#sellers - 3) .. " more recorded seller"
                .. ((#sellers - 3) == 1 and "" or "s"), GREY)
            break
        end

        local text = "Sold by " .. tostring(seller.name or seller.npcID)

        if seller.zone then
            text = text .. " in " .. seller.zone
        end

        if seller.x and seller.y then
            text = text .. string.format(" (%.1f, %.1f)", seller.x * 100, seller.y * 100)
        end

        Add(lines, text, YELLOW)
    end

    return true
end

-- The whole item block, as data. Returns an array of { text, color }.
function Tooltips.ItemLines(itemID, itemName)
    local lines = {}

    if not itemID or not CN.db then
        return lines
    end

    itemName = itemName or Blizzard.GetItemName(itemID)

    local collectible = false

    collectible = ToyLines(lines, itemID)         or collectible
    collectible = MountLines(lines, itemID)       or collectible
    collectible = PetLines(lines, itemID)         or collectible
    collectible = RecipeLines(lines, itemID, itemName) or collectible

    -- Appearance state is noise on something that is not gear, so it is only
    -- consulted when nothing else claimed the item.
    if not collectible then
        AppearanceLines(lines, itemID)
    end

    VendorLines(lines, itemID)

    return lines
end

-- Unit tooltips answer a narrower question: have I shopped here, and is this
-- creature one the addon is tracking as a rare.
function Tooltips.UnitLines(npcID)
    local lines = {}

    if not npcID or not CN.db then
        return lines
    end

    local vendors = CN:GetModule("Vendors")

    if vendors then
        local record = vendors.Store()[npcID]

        if record then
            Add(lines, "Recorded vendor: " .. (record.itemCount or 0) .. " items", YELLOW)

            if not record.mapID then
                Add(lines, "no coordinates recorded yet", GREY)
            end
        end
    end

    -- The rare database is keyed by vignette ID, not creature ID, so there is
    -- deliberately nothing to say here about rares. Adding a guess would be
    -- worse than the silence.

    return lines
end

------------------------------------------------------------
-- RENDERING
------------------------------------------------------------

function Tooltips.Render(tooltip, lines)
    if not tooltip or not tooltip.AddLine or #lines == 0 then
        return 0
    end

    tooltip:AddLine(" ")
    tooltip:AddLine(HEADER, 0.2, 1.0, 0.6)

    for _, line in ipairs(lines) do
        tooltip:AddLine(line.text, line.color[1], line.color[2], line.color[3])
    end

    if tooltip.Show then
        tooltip:Show()
    end

    return #lines
end

------------------------------------------------------------
-- HOOKS
------------------------------------------------------------

-- Which tooltip API resolved, reported by /cn tooltips so a silent hook is
-- diagnosable rather than mysterious.
Tooltips.backend = "none"

local function OnItemTooltip(tooltip, itemID, itemName)
    if not Enabled() then
        return
    end

    local ok, err = pcall(function()
        Tooltips.Render(tooltip, Tooltips.ItemLines(itemID, itemName))
    end)

    if not ok then
        DebugPrint("Item tooltip failed: " .. tostring(err))
    end
end

local function OnUnitTooltip(tooltip, unit)
    if not Enabled() then
        return
    end

    local ok, err = pcall(function()
        local npcID = Blizzard.GetUnitNPCID(unit or "mouseover")

        Tooltips.Render(tooltip, Tooltips.UnitLines(npcID))
    end)

    if not ok then
        DebugPrint("Unit tooltip failed: " .. tostring(err))
    end
end

Tooltips.OnItemTooltip = OnItemTooltip
Tooltips.OnUnitTooltip = OnUnitTooltip

function Tooltips.Install()
    if Tooltips.installed then
        return Tooltips.backend
    end

    -- Modern retail: every tooltip is data-driven and post-processed. Post
    -- calls run after the tooltip is rebuilt, so lines are added once per
    -- render rather than accumulating.
    if TooltipDataProcessor
        and TooltipDataProcessor.AddTooltipPostCall
        and Enum and Enum.TooltipDataType then

        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item,
            function(tooltip, data)
                local itemID, itemName

                if data then
                    itemID = data.id
                end

                if TooltipUtil and TooltipUtil.GetDisplayedItem then
                    local name, _, id = TooltipUtil.GetDisplayedItem(tooltip)

                    itemName = name
                    itemID   = itemID or id
                end

                OnItemTooltip(tooltip, itemID, itemName)
            end)

        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit,
            function(tooltip, data)
                local unit

                if TooltipUtil and TooltipUtil.GetDisplayedUnit then
                    unit = select(2, TooltipUtil.GetDisplayedUnit(tooltip))
                end

                OnUnitTooltip(tooltip, unit)
            end)

        Tooltips.installed = true
        Tooltips.backend   = "TooltipDataProcessor"

        return Tooltips.backend
    end

    -- Older clients. Kept because the addon is expected to load on more than
    -- one flavour, and a missing hook here is silent otherwise.
    if GameTooltip and GameTooltip.HookScript then
        GameTooltip:HookScript("OnTooltipSetItem", function(self)
            local name, link = self:GetItem()

            local itemID = link and tonumber(link:match("item:(%d+)"))

            OnItemTooltip(self, itemID, name)
        end)

        GameTooltip:HookScript("OnTooltipSetUnit", function(self)
            local _, unit = self:GetUnit()

            OnUnitTooltip(self, unit)
        end)

        Tooltips.installed = true
        Tooltips.backend   = "OnTooltipSet"

        return Tooltips.backend
    end

    Tooltips.backend = "none"

    return Tooltips.backend
end

CN:OnLogin(function()
    Tooltips.Install()

    DebugPrint("Tooltip backend: " .. tostring(Tooltips.backend))
end)

------------------------------------------------------------
-- COMMAND
------------------------------------------------------------

CN:RegisterCommand{
    name    = "tooltips",
    args    = "[on or off]",
    order   = 82,
    help    = "Toggle addon lines on item and unit tooltips.",
    handler = function(args)
        local settings = CN.Settings()

        args = string.lower(CN.Trim(args))

        if args == "on" then
            settings.tooltips = true
        elseif args == "off" then
            settings.tooltips = false
        elseif args ~= "" then
            Print("Usage: /cn tooltips [on or off]")
            return
        else
            settings.tooltips = not (settings.tooltips ~= false)
        end

        Print("Tooltip lines: " .. CN.YesNo(settings.tooltips ~= false))
        Print("|cff999999Backend: " .. tostring(Tooltips.backend) .. "|r")

        if Tooltips.backend == "none" then
            Print("|cff999999No tooltip API resolved, so nothing will be added.|r")
        end
    end,
}

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
'@

$Embedded['Modules\Setup.lua'] = @'
-- Modules/Setup.lua
-- Completion Navigator :: the first five minutes.
--
-- Every recommendation this addon makes is only as good as what it has
-- scanned, and until now a new install had to discover eleven separate scan
-- commands to get there. Worse, it looked broken in the meantime: an empty
-- database and a confident "nothing actionable is known yet" read as a bug
-- rather than as a first run.
--
-- /cn setup runs every scan in order, one per frame, and then reports what
-- the client genuinely could not answer -- recipes and vendors, which are
-- readable only while their windows are open, and so can never be batched.

local ADDON_NAME, CN = ...

local Setup = CN:RegisterModule("Setup")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint

------------------------------------------------------------
-- STEPS
------------------------------------------------------------

-- Ordered so the cheap scans report first and the journal scans -- which
-- open and filter collection UIs -- come last.
Setup.steps = {
    { key = "reputations", label = "Reputations", module = "Reputations", fn = "Scan" },
    { key = "currencies",  label = "Currencies",  module = "Currencies",  fn = "Scan" },
    { key = "titles",      label = "Titles",      module = "Titles",      fn = "Scan" },
    { key = "professions", label = "Professions", module = "Professions", fn = "Scan" },
    { key = "exploration", label = "Exploration", module = "Exploration", fn = "Scan" },
    { key = "quests",      label = "Quests",      module = "Quests",      fn = "ScanKnown" },
    { key = "achievements",label = "Achievements",module = "Achievements",fn = "Scan" },
    { key = "toys",        label = "Toys",        module = "Toys",        fn = "Scan" },
    { key = "mounts",      label = "Mounts",      module = "Mounts",      fn = "Scan" },
    { key = "pets",        label = "Battle pets", module = "Pets",        fn = "Scan" },
    { key = "appearances", label = "Appearances", module = "Appearances", fn = "Scan" },
}

function Setup.RunStep(step)
    local module = CN:GetModule(step.module)

    if not module or type(module[step.fn]) ~= "function" then
        return false, "module not loaded"
    end

    local ok, first = pcall(module[step.fn])

    if not ok then
        return false, tostring(first)
    end

    return true, first
end

------------------------------------------------------------
-- RUN
------------------------------------------------------------

Setup.running = false

-- Spreading the steps across frames matters: several of these walk the entire
-- pet journal or achievement tree, and doing all eleven inside one frame is a
-- visible stutter on a login that is already busy.
function Setup.Run(onComplete)
    if Setup.running then
        Print("Setup is already running.")
        return false
    end

    Setup.running = true

    local results = {}
    local index   = 0

    local function step()
        index = index + 1

        local entry = Setup.steps[index]

        if not entry then
            Setup.running = false

            CN.Account("setup").completedAt = time()

            Setup.Report(results)

            if onComplete then
                pcall(onComplete, results)
            end

            return
        end

        local ok, value = Setup.RunStep(entry)

        table.insert(results, {
            label = entry.label,
            ok    = ok,
            value = ok and value or nil,
            error = (not ok) and value or nil,
        })

        if C_Timer and C_Timer.After then
            C_Timer.After(0, step)
        else
            step()
        end
    end

    Print("Running setup: " .. #Setup.steps .. " scans.")

    step()

    return true
end

function Setup.Report(results)
    local scanned, failed = 0, 0

    for _, result in ipairs(results) do
        if result.ok then
            scanned = scanned + 1

            Print("  " .. result.label .. ": "
                .. (type(result.value) == "number" and result.value or "done"))
        else
            failed = failed + 1

            Print("  " .. result.label .. ": |cffff4444" .. tostring(result.error) .. "|r")
        end
    end

    Print("Setup complete: " .. scanned .. " scanned"
        .. (failed > 0 and (", " .. failed .. " unavailable") or "") .. ".")

    for _, line in ipairs(Setup.Outstanding()) do
        Print("|cffffff00" .. line .. "|r")
    end

    Print("Now try |cffffff00/cn next|r.")
end

------------------------------------------------------------
-- WHAT SETUP CANNOT DO
------------------------------------------------------------

-- Two subsystems are readable only while their window is open. Saying so is
-- the difference between "this addon does not track recipes" and "open your
-- profession window once".
function Setup.Outstanding()
    local lines = {}

    local professions = CN:GetModule("Professions")

    if professions and professions.AwaitingRecipeCapture then
        local awaiting = professions.AwaitingRecipeCapture()

        if awaiting and #awaiting > 0 then
            local names = {}

            for _, entry in ipairs(awaiting) do
                table.insert(names, tostring(entry))
            end

            table.insert(lines, "Open each profession window once to record recipes: "
                .. table.concat(names, ", "))
        end
    end

    local vendors = CN:GetModule("Vendors")

    if vendors then
        local counts = vendors.Summary()

        if counts.vendors == 0 then
            table.insert(lines,
                "No vendors recorded yet; they are captured as you open merchant windows.")
        end
    end

    return lines
end

function Setup.HasRun()
    local record = CN.Account("setup")

    return (record and record.completedAt) and true or false
end

------------------------------------------------------------
-- FIRST-RUN PROMPT
------------------------------------------------------------

-- Prompt, never act. Running eleven scans uninvited on someone's login is the
-- same discourtesy as seizing their waypoint.
CN:OnLogin(function()
    if Setup.HasRun() then
        return
    end

    local account = CN.Account("setup")

    if account.prompted then
        return
    end

    account.prompted = time()

    if C_Timer and C_Timer.After then
        C_Timer.After(8, function()
            if not Setup.HasRun() then
                Print("First run: type |cffffff00/cn setup|r to scan everything once.")
            end
        end)
    else
        Print("First run: type |cffffff00/cn setup|r to scan everything once.")
    end
end)

------------------------------------------------------------
-- COMMAND
------------------------------------------------------------

CN:RegisterCommand{
    name    = "setup",
    aliases = { "scanall" },
    order   = 5,
    help    = "Scan every subsystem once. Run this first.",
    handler = function()
        Setup.Run()
    end,
}

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
'@

$Embedded['Modules\Goals.lua'] = @'
-- Modules/Goals.lua
-- Completion Navigator :: what you are actually working toward.
--
-- Everything else in this addon answers "what should I do next?" from the
-- whole field of what is available. That is the right default, and it is the
-- wrong answer when you have decided you want one specific thing.
--
-- A goal is a target you pin. Once pinned:
--
--   * it becomes a candidate in its own right, even when nothing else would
--     have surfaced it -- an uncollected mount is not normally actionable,
--     but if you have decided you want it, it is;
--   * anything that plausibly leads to it is weighted up, and says so;
--   * /cn goal prints what is actually known about getting it -- the source,
--     where it is, which of your characters is best placed, and what the
--     next concrete step is.
--
-- Goals are account-wide. Deciding you want a mount is not a fact about the
-- character you happened to be playing when you decided it.

local ADDON_NAME, CN = ...

local Goals = CN:RegisterModule("Goals")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

local function Store()
    return CN.Account("goals")
end

Goals.Store = Store

-- How many goals are worth having at once. Beyond a handful, "goal" stops
-- meaning anything and the weighting stops discriminating.
Goals.limit = 10

------------------------------------------------------------
-- TYPES
------------------------------------------------------------

-- Which objective types can be pinned, and what the user types for each.
Goals.types = {
    quest       = CN.objectiveTypes.QUEST,
    achievement = CN.objectiveTypes.ACHIEVEMENT,
    mount       = CN.objectiveTypes.MOUNT,
    pet         = CN.objectiveTypes.PET,
    toy         = CN.objectiveTypes.TOY,
    recipe      = CN.objectiveTypes.RECIPE,
    title       = CN.objectiveTypes.TITLE,
    rep         = CN.objectiveTypes.REPUTATION,
    reputation  = CN.objectiveTypes.REPUTATION,
    rare        = CN.objectiveTypes.RARE,
    currency    = CN.objectiveTypes.CURRENCY,
}

local function ResolveType(text)
    if not text then
        return nil
    end

    return Goals.types[string.lower(text)]
end

Goals.ResolveType = ResolveType

local function Key(objectiveType, id)
    return CN.ObjectiveKey(objectiveType, id)
end

------------------------------------------------------------
-- MANAGING GOALS
------------------------------------------------------------

function Goals.IsGoal(objectiveType, id)
    if not objectiveType or not id then
        return false
    end

    local store = Store()

    if not store or next(store) == nil then
        return false
    end

    return store[Key(objectiveType, id)] ~= nil
end

function Goals.Add(objectiveType, id)
    if not objectiveType or not id then
        return false, "A goal needs a type and an ID."
    end

    local store = Store()

    local key = Key(objectiveType, id)

    if store[key] then
        return false, "That is already a goal."
    end

    if CN.CountKeys(store) >= Goals.limit then
        return false, "You already have " .. Goals.limit
            .. " goals. Clear one first."
    end

    local filters = CN:GetModule("Filters")

    local name = filters and filters.DescribeObjective(objectiveType, id)
        or (objectiveType .. " " .. tostring(id))

    store[key] = {
        type  = objectiveType,
        id    = id,
        name  = name,
        since = time(),
    }

    -- A goal changes the weight of everything, and objectives are decorated
    -- when their provider builds them. Force a full rebuild so the new
    -- weighting takes effect immediately rather than whenever something
    -- happens to go stale.
    CN.InvalidateCandidates()

    return true, name
end

function Goals.Remove(objectiveType, id)
    local store = Store()

    local key = Key(objectiveType, id)

    if not store[key] then
        return false
    end

    local name = store[key].name

    store[key] = nil

    CN.InvalidateCandidates()

    return true, name
end

function Goals.Clear()
    local store = Store()

    local count = CN.CountKeys(store)

    for key in pairs(store) do
        store[key] = nil
    end

    CN.InvalidateCandidates()

    return count
end

-- Ordered oldest first, so the list is stable and numbering means something
-- between calls.
function Goals.List()
    local list = {}

    for key, goal in pairs(Store()) do
        table.insert(list, {
            key   = key,
            type  = goal.type,
            id    = goal.id,
            name  = goal.name,
            since = goal.since or 0,
        })
    end

    table.sort(list, function(a, b)
        if a.since ~= b.since then
            return a.since < b.since
        end

        return tostring(a.key) < tostring(b.key)
    end)

    return list
end

------------------------------------------------------------
-- WHAT IS KNOWN ABOUT GETTING IT
------------------------------------------------------------

-- Everything the addon can say about how to obtain one goal. Deliberately
-- honest: where nothing is known, it says so and names what would make it
-- knowable, rather than inventing a route.
--
-- Returns a table:
--   name, source, mapID, x, y, zone, steps (array of strings),
--   done (boolean), character (string or nil)
function Goals.Plan(goal)
    local plan = {
        name  = goal.name,
        steps = {},
    }

    local types = CN.objectiveTypes

    local function step(text)
        table.insert(plan.steps, text)
    end

    ------------------------------------------------------------
    -- Is it already done?
    ------------------------------------------------------------

    local state, reason = CN.Explain(goal.type, goal.id)

    if state == CN.objectiveStates.COMPLETED then
        plan.done = true

        step(reason or "Already complete.")

        return plan
    end

    ------------------------------------------------------------
    -- Where is it?
    ------------------------------------------------------------

    if goal.type == types.QUEST then
        local quests = CN:GetModule("Quests")

        if quests then
            local mapID, x, y, source = quests.GetLocation(goal.id)

            plan.mapID, plan.x, plan.y = mapID, x, y
            plan.source = source

            if mapID then
                plan.zone = Blizzard.GetMapName(mapID)
            end
        end

        if state == CN.objectiveStates.LOCKED and reason then
            step(reason)
        end
    end

    if goal.type == types.MOUNT then
        local record = CN.Account("mounts")[goal.id]

        if record then
            plan.source = record.source

            if record.isFactionSpecific then
                step("Faction-locked. Only obtainable on one faction.")
            end
        end
    end

    if goal.type == types.PET then
        local record = CN.Account("pets")[goal.id]

        if record and record.isWild then
            step("Wild pet: find and capture it in the world.")
        end
    end

    if goal.type == types.RECIPE then
        local vendors = CN:GetModule("Vendors")

        if vendors then
            local seller = vendors.FirstLocatedSeller(goal.id)

            if seller then
                plan.source = "Sold by " .. tostring(seller.name)
                plan.mapID, plan.x, plan.y = seller.mapID, seller.x, seller.y
                plan.zone = seller.zone

                step("Buy it from " .. tostring(seller.name)
                    .. (seller.zone and (" in " .. seller.zone) or "") .. ".")
            else
                step("No recorded vendor sells this. Open merchants to record them.")
            end
        end
    end

    if goal.type == types.RARE or goal.type == types.TREASURE then
        local record = CN.Account("rares")[goal.id]

        if record then
            plan.mapID, plan.x, plan.y = record.mapID, record.x, record.y
            plan.zone = record.zone

            step("Seen " .. (record.sightings or 1) .. " time"
                .. ((record.sightings or 1) == 1 and "" or "s") .. " here.")
        end
    end

    if goal.type == types.ACHIEVEMENT then
        local record = CN.Account("achievements")[goal.id]

        if record and record.criteria then
            local remaining = (record.criteria or 0) - (record.done or 0)

            step(remaining .. " of " .. record.criteria .. " criteria left.")

            for _, criterion in ipairs(Blizzard.GetIncompleteCriteria(goal.id, 5) or {}) do
                step("Missing: " .. criterion)
            end
        end
    end

    if goal.type == types.REPUTATION then
        local record = CN.Account("reputations")[goal.id]

        if record then
            if record.accountWide then
                step("Account-wide: any character's progress counts.")
            else
                step("Character-specific: progress does not carry across your Warband.")
            end
        end
    end

    ------------------------------------------------------------
    -- Who should do it?
    ------------------------------------------------------------

    local warband = CN:GetModule("Warband")

    if warband then
        local ok, best, detail, why = pcall(warband.WhoShould, goal.type, goal.id)

        if ok and best then
            plan.character = best

            step("Best character: " .. tostring(best)
                .. (why and (" (" .. why .. ")") or ""))
        end
    end

    ------------------------------------------------------------
    -- Fall back to honesty.
    ------------------------------------------------------------

    if plan.mapID and plan.x and plan.y then
        step("Location known: " .. (plan.zone or ("map " .. plan.mapID))
            .. string.format(" (%.1f, %.1f)", plan.x * 100, plan.y * 100))
    elseif #plan.steps == 0 then
        step("Nothing is known about how to obtain this yet.")
        step("The addon learns sources from play: open vendors, scan "
            .. "collections, and travel.")
    end

    return plan
end

------------------------------------------------------------
-- CANDIDATES
------------------------------------------------------------

-- A goal is actionable by definition. Most goals would never surface on their
-- own -- an uncollected mount is not a next action for most people -- which is
-- exactly the point of having said you want it.
CN.RegisterCandidateProvider("Goals", function()
    local candidates = {}

    for _, goal in ipairs(Goals.List()) do
        if not CN.IsIgnored(goal.type, goal.id)
            and not CN.IsDeferred(goal.type, goal.id) then

            local plan = Goals.Plan(goal)

            if not plan.done then
                local reasons = { "you set this as a goal" }

                if plan.source then
                    table.insert(reasons, plan.source)
                end

                local travel

                if plan.mapID then
                    local playerMap = select(1, CN.GetPlayerPosition())

                    travel = (plan.mapID == playerMap) and 2 or 25
                end

                table.insert(candidates, CN.NewObjective({
                    id              = goal.id,
                    type            = goal.type,
                    name            = goal.name,
                    mapID           = plan.mapID,
                    x               = plan.x,
                    y               = plan.y,
                    zone            = plan.zone,
                    accountWide     = true,
                    completionValue = 6,
                    travelCost      = travel,
                    isGoal          = true,
                    reasons         = reasons,
                }))
            end
        end
    end

    return candidates
end, { events = { "ZONE_CHANGED_NEW_AREA" }, cooldown = 2 })

------------------------------------------------------------
-- WEIGHTING
------------------------------------------------------------

-- Anything that leads to a goal is worth more than it would be otherwise.
-- "Leads to" is deliberately narrow -- three relationships the addon can
-- actually establish, rather than a guess dressed up as a plan.
function Goals.Decorate(objective)
    if type(objective) ~= "table" or not objective.type or not objective.id then
        return objective
    end

    local store = Store()

    if not store or next(store) == nil then
        return objective
    end

    -- 1. It IS a goal.
    if Goals.IsGoal(objective.type, objective.id) then
        objective.userPreference = (objective.userPreference or 0) + 8

        if not objective.isGoal then
            objective.isGoal  = true
            objective.reasons = objective.reasons or {}
            table.insert(objective.reasons, "this is one of your goals")
        end

        return objective
    end

    -- 2. It unlocks a goal, per the dependency graph.
    if objective.type == CN.objectiveTypes.QUEST then
        local dependency = CN.GetDependency(CN.ObjectiveKey(objective.type, objective.id))

        if dependency and dependency.unlocks then
            for _, unlocked in ipairs(dependency.unlocks) do
                -- Dependency edges are stored as keys, but static data writes
                -- plain quest IDs. Accept both.
                local unlockedID = tonumber(unlocked)
                    or tonumber(tostring(unlocked):match(":(%d+)$"))

                if unlockedID and Goals.IsGoal(CN.objectiveTypes.QUEST, unlockedID) then
                    objective.userPreference = (objective.userPreference or 0) + 5
                    objective.reasons = objective.reasons or {}
                    table.insert(objective.reasons, "unlocks a goal")

                    return objective
                end
            end
        end
    end

    -- 3. It is in the same zone as a located goal. Weak, and weighted weakly:
    --    being in the right place is worth something, but it is not progress.
    if objective.mapID then
        for _, goal in ipairs(Goals.List()) do
            local plan = Goals.Plan(goal)

            if plan.mapID == objective.mapID and not plan.done then
                objective.userPreference = (objective.userPreference or 0) + 2
                objective.reasons = objective.reasons or {}
                table.insert(objective.reasons, "in the same zone as a goal")

                return objective
            end
        end
    end

    return objective
end

CN.RegisterCandidateDecorator("Goals", Goals.Decorate)

------------------------------------------------------------
-- OUTPUT
------------------------------------------------------------

local function PrintPlan(index, goal)
    local plan = Goals.Plan(goal)

    Print(index .. ". |cffffff00" .. tostring(plan.name) .. "|r"
        .. " |cff999999(" .. tostring(goal.type) .. " " .. tostring(goal.id) .. ")|r"
        .. (plan.done and " |cff00ff00done|r" or ""))

    if plan.source then
        Print("   Source: " .. tostring(plan.source))
    end

    for _, step in ipairs(plan.steps) do
        Print("   - " .. step)
    end

    if plan.character then
        Print("   Best character: |cffffff00" .. tostring(plan.character) .. "|r")
    end

    if plan.mapID and plan.x and plan.y then
        Print("   |cffffff00/cn gogoal " .. index .. "|r to set a waypoint.")
    end
end

Goals.PrintPlan = PrintPlan

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "goal",
    args    = "<type> <id>",
    order   = 12,
    help    = "Pin something as a goal. Types: quest, achievement, mount, pet, toy, recipe, title, rep, rare, currency.",
    handler = function(args)
        local typeText, idText = string.match(CN.Trim(args or ""), "^(%S+)%s+(%S+)$")

        if not typeText then
            Print("Usage: /cn goal <type> <id>")
            Print("|cff999999Types: quest, achievement, mount, pet, toy, recipe, "
                .. "title, rep, rare, currency|r")
            Print("|cffffff00/cn goals|r lists what you have pinned.")
            return
        end

        local objectiveType = ResolveType(typeText)

        if not objectiveType then
            Print("Not a goal type: " .. typeText)
            Print("|cff999999Types: quest, achievement, mount, pet, toy, recipe, "
                .. "title, rep, rare, currency|r")
            return
        end

        local id = CN.ToID(idText)

        if not id then
            Print("Not an ID: " .. idText)
            return
        end

        local added, message = Goals.Add(objectiveType, id)

        if not added then
            Print(message)
            return
        end

        Print("Goal set: |cffffff00" .. tostring(message) .. "|r")

        local list = Goals.List()

        for index, goal in ipairs(list) do
            if goal.type == objectiveType and goal.id == id then
                PrintPlan(index, goal)
                break
            end
        end
    end,
}

CN:RegisterCommand{
    name    = "goals",
    order   = 13,
    help    = "List your goals and what is known about reaching them.",
    handler = function()
        local list = Goals.List()

        if #list == 0 then
            Print("No goals set.")
            Print("|cffffff00/cn goal mount 1234|r pins something to work toward.")
            Print("|cff999999A goal becomes actionable even when nothing else "
                .. "would have surfaced it, and anything leading to it ranks higher.|r")
            return
        end

        Print("Goals (" .. #list .. " of " .. Goals.limit .. "):")

        for index, goal in ipairs(list) do
            PrintPlan(index, goal)
        end
    end,
}

CN:RegisterCommand{
    name    = "ungoal",
    args    = "<number or all>",
    order   = 14,
    help    = "Remove a goal.",
    handler = function(args)
        args = CN.Trim(args or "")

        if string.lower(args) == "all" then
            local count = Goals.Clear()

            Print("Cleared " .. count .. " goal" .. (count == 1 and "" or "s") .. ".")
            return
        end

        local index = CN.ToID(args)

        local list = Goals.List()

        if not index or not list[index] then
            Print("Usage: /cn ungoal <number or all>")

            if #list > 0 then
                Print("|cff999999Numbers come from |cffffff00/cn goals|r.|r")
            end

            return
        end

        local goal = list[index]

        local removed, name = Goals.Remove(goal.type, goal.id)

        if removed then
            Print("Goal removed: " .. tostring(name))
        end
    end,
}

CN:RegisterCommand{
    name    = "gogoal",
    args    = "<number>",
    order   = 15,
    help    = "Navigate to a goal.",
    handler = function(args)
        local index = CN.ToID(CN.Trim(args or ""))

        local list = Goals.List()

        if not index or not list[index] then
            Print("Usage: /cn gogoal <number>")
            return
        end

        local goal = list[index]
        local plan = Goals.Plan(goal)

        if not (plan.mapID and plan.x and plan.y) then
            Print("No location is known for " .. tostring(plan.name) .. ".")

            for _, step in ipairs(plan.steps) do
                Print("  - " .. step)
            end

            return
        end

        CN.NavigateToObjective({
            id    = goal.id,
            type  = goal.type,
            name  = plan.name,
            mapID = plan.mapID,
            x     = plan.x,
            y     = plan.y,
        })
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
## Version: 0.17.0
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
Providers\ATT.lua
Providers\Blizzard.lua
Providers\BtWQuests.lua
Providers\HandyNotes.lua
Providers\StaticData.lua
Providers\TomTom.lua
Data\Quests.lua
Modules\Achievements.lua
Modules\Appearances.lua
Modules\Breakdown.lua
Modules\Currencies.lua
Modules\Exploration.lua
Modules\Filters.lua
Modules\Goals.lua
Modules\Harvest.lua
Modules\Mounts.lua
Modules\Opportunities.lua
Modules\Pets.lua
Modules\Professions.lua
Modules\Quests.lua
Modules\Rares.lua
Modules\Reputations.lua
Modules\Setup.lua
Modules\Titles.lua
Modules\Tooltips.lua
Modules\Toys.lua
Modules\Vendors.lua
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

Run `/cn setup` once, then type `/cn next` or click the minimap button. The addon scores every objective it knows to be currently actionable and tells you which one is worth doing, and why.

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

The window has eight tabs — Next, Now, Zone, Warband, Collections, Remaining, Scans, Settings — and everything the slash commands do is reachable by clicking. Keybindings live under Key Bindings → AddOns.

## Known limitations

These are honest constraints, not oversights:

- **Recipes require the profession window.** `C_TradeSkillUI` only exposes a recipe list while that profession's window is open. The addon captures each one automatically the first time you open it and tells you which are still outstanding. It will not silently report zero.
- **No completion percentages for zones.** A percentage needs a trustworthy denominator, and the curated static database does not yet have zone coverage. The addon reports counts of what remains instead of inventing a number you would act on.
- **Appearances are tracked per category, not per item.** Enumerating every appearance source is tens of thousands of entries; the actionable question is which slot is furthest from done.
- **Achievements only become recommendations when nearly complete.** A zero-progress achievement is a project, not a next action.
- **Tooltip appearance lines only appear where an item has an appearance.** `PlayerHasTransmogByItemInfo` answers `false` for a stack of ore just as readily as for an unlearned tabard, so the lookup is gated on the item genuinely having an appearance source rather than stamping "not yet known" on every trade good in the game.
- **Recipe tooltips fall back to matching on name.** The trade skill API keys recipes by recipe ID while a vendor sells an item ID, and the two are not the same number. The ID lookup is tried first; when the name match is what fired, the tooltip says so rather than dressing it up as certainty.

## Optional integrations

**TomTom** for waypoints. Without it, navigation falls back to Blizzard map pins and the quest tracking arrow.

**AllTheThings** and **BtWQuests** are read at runtime for quest names, coordinates, source quests and prerequisite chains. Their internals are not published contracts, so every access is probed and wrapped: an update to either can make a provider go quiet, but cannot break Completion Navigator. `/cn providers` reports exactly what resolved.

None are required.

## Goals

`/cn goal <type> <id>` pins a target. It becomes a candidate in its own right, anything leading to it is weighted up and says why, and `/cn goals` reports the known route: source, location, best-placed character, next step. Where nothing is known it says so and names what would make it knowable.

Three relationships count as "leads to a goal", deliberately narrow ones the addon can actually establish: it *is* the goal, it unlocks the goal per the dependency graph, or it is in the same zone as a located goal. The third is weighted weakly — being in the right place is worth something, but it is not progress.

## Performance

The recommendation path is measured, not assumed. `bench.lua` runs the addon
against a retail-scale database (1800 pets, 3000 achievements, 500 factions,
2500 recipes) and times it; `/cn perf` reports the same figures live.

Three caches, each invalidated by the narrowest thing that can change it:
per provider, then the aggregate list, then the scored and sorted list. Each
provider declares which events make it stale, so learning a mount does not
rebuild the achievement candidates. Providers subscribed to chatty events
(`CRITERIA_UPDATE`, `UPDATE_FACTION`) rebuild at most once every five seconds.

Providers that enumerate an entire collection are capped at 60 candidates,
chosen by counting rather than sorting, ties broken by ID. `/cn perf` reports
what was dropped: a cap nobody can see reads as "that was everything".

## Development

The addon is managed by `cn.ps1`, a PowerShell toolkit that carries the whole source tree inside it.

```powershell
.\cn.ps1 init                    # scaffold the modular tree
.\cn.ps1 new module Pets         # create a module and sync the .toc
.\cn.ps1 cmd pets -Module Pets   # register a slash command stub
.\cn.ps1 event NEW_PET_ADDED -Module Pets
.\cn.ps1 sync                    # rewrite the .toc load order from disk
.\cn.ps1 harvest                 # fold harvested quests from SavedVariables into Data
.\cn.ps1 doctor                  # report the whole release chain state
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

## [0.17.0]

### Added

- **Goals.** `/cn goal <type> <id>` pins something you have decided you want.
  A goal becomes a candidate in its own right -- an uncollected mount is not
  normally a next action, which is exactly why saying you want it has to mean
  something -- and anything that leads to it ranks higher and says so.
  `/cn goals` prints what is actually known about reaching each one: the
  source, where it is, which of your characters is best placed, and the next
  concrete step. Where nothing is known it says so, and names what would make
  it knowable, rather than inventing a route.
  `/cn ungoal`, `/cn gogoal <n>` to navigate, and a **Goals** tab.
  Types: quest, achievement, mount, pet, toy, recipe, title, rep, rare,
  currency. Goals are account-wide, because deciding you want a mount is not
  a fact about the character you happened to be playing at the time.
- **`.\cn.ps1 harvest`** reads SavedVariables directly and folds harvested
  quests into `Data\Quests.lua`.
  The addon has recorded the name, zone, coordinates and level of every quest
  you accept since the first build, and the only way to get it out was a copy
  box -- so in practice it stayed in SavedVariables and the curated database
  stayed nearly empty. That is what limits prerequisite forensics, and it was
  a tooling gap, not a data gap. Curated rows are never overwritten:
  hand-checked data outranks observed data, the same source-ranking rule the
  addon applies internally. Quests with no coordinates are skipped unless
  you pass `-Force`.

### Fixed

- **Decorators ran once per rebuild instead of once per objective.** 0.16.0's
  per-provider caching means the aggregate list is mostly the *same* objective
  tables as last time, so Warband's "another character is better suited" was
  appended again on every rebuild and stacked up under the recommendation.
  Decoration now happens when a provider builds its objectives. Regression
  test asserts no objective is ever decorated twice.
- **An explicit action no longer waits on a cooldown.** Cooldowns exist to
  stop a chatty *event* from causing work; they were also delaying things the
  player just did on purpose, so a newly pinned goal could take two seconds to
  appear. Invalidation with no event reason -- a scan finishing, a login, a
  goal changing -- now bypasses cooldowns.

### Notes

- `Data\Quests.lua` still ships nearly empty. `harvest` is the mechanism that
  changes that; it needs people to play with the addon loaded first.

## [0.16.1]

A Windows-only defect in 0.16.0's release path. No addon changes.

### Fixed

- **`release` died mid-push on Windows PowerShell 5.1.** There, stderr from a
  native command under `2>&1` arrives as ErrorRecord objects, and with
  `$ErrorActionPreference = 'Stop'` -- set at the top of `cn.ps1` -- the first
  one becomes a terminating error. git writes its ordinary progress to stderr,
  so `git push 2>&1` killed the script on a push that had *succeeded*, leaving
  the tag unpushed and the release invisible to CurseForge.
  Every native invocation now goes through one helper that neutralizes the
  preference for the duration, renders stderr as its message rather than its
  type name, and returns the real exit code.
  This was not caught because the end-to-end test runs PowerShell 7 on Linux,
  which does not behave this way.
- **`check` had the same defect.** `luac.exe` writes syntax errors to stderr,
  so the first malformed file would have terminated the whole check rather
  than being reported alongside the others.
- **`doctor` sorted remote tags as strings**, which put `v0.9.0` above
  `v0.15.0` and made "newest remote tags" actively misleading. Sorted by
  version number now.
- A failed push prints the two commands that finish the release by hand,
  rather than leaving you to work them out.

## [0.16.0]

Measured, not guessed. A benchmark against a retail-scale database -- 1800
pets, 3000 achievements, 500 factions, 2500 recipes -- drove every change
below. Numbers are from that benchmark.

### Changed

- **The ranked list is cached.** 0.15.0 cached the candidate list but still
  re-scored and re-sorted every candidate on every call, so `/cn next` cost
  **14.8ms** even with a warm cache. It is now **0.01ms**. A frame at 60fps is
  16ms, which means the minimap tooltip added in 0.15.0 was dropping a frame
  every time you hovered it. That was a regression I shipped, and this is the
  fix.
- **Invalidation is per provider.** Each provider declares which events can
  make it stale, so learning a mount no longer rebuilds the achievement
  candidates. `NEW_MOUNT_ADDED` went from **18.3ms to 0.02ms**;
  `UPDATE_FACTION` from **6.6ms to 0.01ms**; `CRITERIA_UPDATE` from **8.5ms to
  1.1ms**.
- **Chatty events are throttled at the cache, not just at the scan.**
  `CRITERIA_UPDATE` and `UPDATE_FACTION` fire many times a second during normal
  play. Providers subscribed to them rebuild at most once every five seconds.
- **Providers that enumerate a whole collection are capped.** Emitting 1200
  uncollected pets so that one can rank first is waste, and every one of them
  scores identically. The highest-valued 60 per provider are kept, chosen by
  counting rather than sorting, with ties broken by ID so the list does not
  reshuffle. Candidate count dropped from **3211 to 189**. `/cn perf` reports
  exactly what was dropped -- a cap nobody can see reads as "that was
  everything".
- **Ignore and defer lookups short-circuit when nothing is hidden.** They were
  building a `TYPE:id` string per call, several thousand times per rebuild,
  to look up nothing. **12ms to 3.5ms** per 10,000 pairs.
- A full rebuild is down from **45.2ms to 16.5ms**, and now only happens on a
  scan or a login rather than on every event.
- Ranking sorts a copy. Zone routing walks the candidate list, and having it
  reordered underneath as a side effect of somebody asking for a
  recommendation was a bug waiting to be found.

### Fixed

- **`release` no longer half-applies.** It bumped the version files and *then*
  checked the changelog, so a stale `CHANGELOG.md` left the tree claiming a
  version whose source had never been scaffolded -- and said so in a yellow
  warning that scrolled past. Every refusal now happens before anything is
  written, and says "nothing has been changed" out loud.
- **A failing `check` aborts the release** instead of printing above it and
  carrying on.
- **`cn.ps1` stamps the version it carries.** A `cn.ps1` older than the tree
  used to scaffold a previous release over the top and report success. `check`
  now fails on it, and `release` refuses a version this file does not carry.
- **An existing tag is detected** rather than letting `git tag` fail into the
  middle of a release.
- **Push failures are caught.** `git push` and `git push --tags` are checked,
  so a tag that never reached the remote is reported rather than assumed.
- git's stderr is rendered as its message rather than
  `System.Management.Automation.RemoteException`.
- **`init` scaffolds `Media\Logo.tga`.** A fresh scaffold previously failed its
  own `check` on a missing IconTexture, which then blocked `release`.
- Rescanning a store no longer invalidates every provider -- only the ones that
  read it. Mounts, toys, appearances and titles feed no candidate provider at
  all, so scanning them now invalidates nothing.

### Added

- **`.\cn.ps1 doctor`** reports the whole release chain in one place: toolkit
  version, tree version, changelog section, HEAD, tags at HEAD, uncommitted
  changes, remote, and whether the expected tag has actually been pushed. Written because diagnosing a release that silently did nothing
  meant assembling five separate commands by hand.
- `/cn perf` reports per-provider cache state and any caps hit.

## [0.15.0]

### Added

- **Tooltips.** Item tooltips now say what the addon already knew: whether a
  toy, mount, battle pet or appearance is collected, whether this character
  knows a recipe and which of your characters does, and which recorded
  vendor sells the item and where they stand. Unit tooltips identify a
  merchant you have already shopped at.
  Nothing is added to items the addon knows nothing about — an appearance
  line only appears where the item genuinely has an appearance source, so
  the addon stays off every stack of ore in the game. `/cn tooltips` toggles
  the whole thing, and reports which tooltip API resolved.
- **`/cn setup`.** Runs all eleven subsystem scans in order, one per frame,
  then names the two things it cannot do for you: recipes and vendor
  inventories are readable only while their windows are open.
  A new install previously had to discover eleven separate scan commands,
  and looked broken until it did. The first login now prints a single
  pointer to this command and then stays quiet.
- The minimap button tooltip shows the current recommendation and its top
  reasons, so the most common question the addon answers no longer requires
  opening anything.
- Settings tab gains a tooltip toggle and a **Scan everything now** button.

### Changed

- **Candidates are cached.** Nine providers were being rebuilt on every
  `/cn next`, every window refresh and every auto-advance tick, several of
  them walking thousands of records. Results are now held for five seconds
  and invalidated by the sixteen events that can actually change an answer.
- `/cn perf` reports cache state and per-provider timings, slowest first, so
  a slow provider can be identified rather than guessed at.

## [0.14.0]

### Added

- **Managing what you hid.** `/cn hidden` lists everything ignored or
  deferred, with real names rather than internal keys. `/cn unhide <id>`
  restores one, `/cn unhide all` restores everything.
  Ignore and defer have existed since the first build with no way to see
  either list or undo anything in them. Ignoring something by accident
  meant it was gone permanently, which is a bug wearing a feature's
  clothes.
- Expired deferrals are pruned at login instead of accumulating in
  SavedVariables forever.
- **Vendors.** Every merchant you open is recorded permanently: what they
  sell, and where they stand. `/cn sells <item>` finds who sells something,
  `/cn tovendor <item>` routes you there, `/cn vendors` summarizes.
- Recipes you do not know that a recorded vendor sells now become
  recommendations with real coordinates. This is the missing link in the
  design's flagship example: everything else it needed already existed, but
  nothing knew where anything was sold.

### Fixed

- **NPC IDs were never parsed.** `tonumber(select(6, strsplit("-", guid)))`
  passes every remaining GUID field to `tonumber`, so the spawn UID arrived
  as the `base` argument and the call threw. Every vendor capture would have
  failed in game. Wrapping the `select` in parentheses truncates it to one
  value.

### Notes

- Vendor inventories, like trade skill recipes, are only readable while the
  window is open. So the vendor database grows as you play rather than
  shipping stale, and only vendors you have actually opened are known.


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

$EmbeddedBinary = [ordered]@{}

$EmbeddedBinary['Media\Logo.tga'] = @(
    'AAACAAAAAAAAAAAAgACAACAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEgAAACcAAAA6AAAASgAAAFgAAABjAAAAawAAAHAAAABzAAAAcwAAAHAAAABrAAAAYwAAAFgAAABK',
    'AAAAOgAAACcAAAASAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAJQAAAEgAAABoAAAAhgAA',
    'AKIAAgS6AAUJ0AAID+MACxb0AA4b/wARIP8BEyT/ARUm/wETJP8BEyT/ARQn/wEUJf8AESH/AA8c/wALFvQABw/jAAUJ0AABA7oAAACiAAAAhgAAAGgAAABI',
    'AAAAJQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACIAAABQAAAAewAAAKQAAwbLAAkS7gEQIP8BFSn/ARgv/wEbNP8AGjT/ABgx/wAVL/8AFC3/ABMs/wAT',
    'LP8AESn/AA8n/wAPJ/8AESr/ABMt/wAVL/8AGDL/ABk0/wAaNv8BHjn/AR02/wEZMP8BFiv/AREh/wAKE+4AAwbLAAAApAAAAHsAAABQAAAAIgAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAKgAAAGAAAACU',
    'AAIExQAIEPQBEB7/ARcs/wAbNv8AGzb/ABYw/wARKP8ADSH/AA8i/wASJf8CFyr/BR4w/wglOP8KLUH/DjRI/xA6UP8UOk//EjhN/w84Tf8LMkf/Cy1B/wgm',
    'Of8FHjD/Ahcq/wASKP8AECj/ABEq/wAUL/8AGjn/AB8//wEgPv8BHDT/ARUm/wAKE/QAAgTFAAAAlAAAAGAAAAAqAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    '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',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAnAAAAewABAc0ADBf/',
    'ARcs/wAWLP8ADyH/ARMm/wQgOf8ILE3/BzJX/wUtUv8DKU3/AyhM/wQoSv8DIDv/BBYn/wMKEf8FBQT/BwMA/wkDAP8LBQD/DgkC/w0KBP8NCgb/EQ4I/xAO',
    'Cf8PDQn/Dg0I/w4MCP8ODQj/DQwI/w4NCf8PDgn/Dg0I/w4NCf8ODgr/DQ0J/w4NCf8PDQj/CgcD/woEAP8JAQD/CAAA/wcEAP8HEA//CSQv/wtCXf8LVH//',
    'C2Od/wlio/8MZKX/FW+n/xx6o/8aaIb/CzhQ/wAXLv8AFTH/ASND/wIkQf8BEyL/AAECzQAAAHsAAQEnAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEKAAAAYwAAALoACBH/ARUp/wEWK/8BDh3/AQ4e/wIaMv8EJ0b/BCRB/wAaMv8AGDD/',
    'ARoy/wEYLf8CESD/AwcL/wUCAP8HAwD/CwcB/w0KBv8ODAj/DgwI/w4MB/8ODAj/DgwI/w4NCP8RDwn/CwkE/w4LBv8ODAb/EAwH/w4LBv8PDAf/DQsG/w0L',
    'Bf8OCwb/Dw0J/xAOCv8PDQj/DQsG/wwKBv8NDAf/DQwI/w0MCP8NDAn/DAsH/wwHAv8KAwD/CAEA/wYIBP8HHiX/Cj9W/wpSfv8HVIz/CFOQ/w1dlv8YcJ7/',
    'FWmN/wk8Vf8AFy3/ABMs/wEmR/8CI0D/AA0Z/wAAALoAAABjAAEBCgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAPQAAAJkABAn0ARMk/wEXLf8BDx//AQsZ/wESI/8CGCz/ARYp/wAPHv8AECH/ABEj/wANGf8ABQn/AgEA/wYBAP8JBQH/CwkF/w4LB/8OCwf/',
    'DQoG/w0KBv8NCgb/DgsG/w8MB/8OCwf/DwwH/xIQC/8NCgX/DAoG/xANCP8RDgj/EA0H/w8MB/8PDQf/EA4I/xAOCP8QDAb/DgsG/w8MBv8PDgn/Dw0J/w4L',
    'B/8OCwb/DwwH/w0KBv8MCgb/DQsH/w0MCP8NDQn/DAoG/woDAP8IAQD/BgwL/wUnNf8HRmb/BlCC/wRIg/8JUYj/D2eU/xJnh/8NPlX/ABMq/wAZNv8BKEn/',
    'AR43/wAGC/QAAACZAAEBPQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEBCgAAAGsAAADLAA0a/wEZMP8AEiX/AAsZ/wAN',
    'HP8ADRr/AAoV/wAGD/8ABQ7/AAcQ/wAGDP8AAgP/AQAA/wQCAP8HBQP/CQcF/wsJBf8KCAX/DAkF/wwJBf8NCgb/DgsG/w4LBv8PDAf/EA0H/xANB/8QDQj/',
    'ERAL/xEPCv8TEgz/ExMO/xESDv8QEQ7/EBIP/xITD/8SExD/EA4I/wsRE/8IFiD/DA4N/w8MBv8QDwv/EBAM/w8PC/8PDAf/DgsH/wwKBv8NCwb/DgsG/w4M',
    'B/8NDAj/DAwI/w0NCf8NCQX/CgIA/wYEAP8EHCP/BT1b/wVIdv8DQXb/BkN2/xNkjv8Yaob/CTRO/wATLP8AHz7/ASdI/wESIf8AAADLAAAAawABAQoAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAS8AAACUAAQJ9wEXLf8BGTH/AA8f/wAQIP8ADhz/AAcQ/wEFDP8AAwf/AAAC/wAAAP8AAAH/AAAA/wAA',
    'AP8CAgH/AwMC/wYEA/8HBgP/CQcD/woHA/8KCAX/CwgF/w0KBv8OCwb/DwwG/xAMB/8PDQf/DwwH/xAOCP8SDwr/DgsH/xANCP8SDwr/DQwI/w0MCf8REAv/',
    'EA4I/xEOB/8PCwT/BxQc/wQWI/8KFBn/EQwE/w8MBf8RDgj/ExQQ/xAQDP8QDgr/EA8L/xAOCf8QDgn/DgwI/w0MCP8MCgf/DAoG/wwKBv8NDQn/DAsH/wgC',
    'AP8GAwD/AxQb/wM1UP8EQm3/Azdp/whCcf8TZIv/Eld2/wMhOv8AFTD/ASdJ/wEeOv8ABQn3AAAAlAABAS8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABQ',
    'AAAAtwENGf8BHTj/ABQq/wAPIf8CHDP/ABEh/wEHDv8FGzP/Ahox/wEPH/8DGzH/AQwX/wAAAP8AAAD/AAAA/wEBAf8BAgH/AwIB/wUEAv8HBQL/CAYD/wgG',
    'A/8KCAT/DAkF/wwKBf8MCQX/DgwG/w8MB/8OCwb/DwwH/xMQCv8PDAf/DQsH/w8NCP8RDwn/EhEM/xEQDP8LDQv/DQ4N/woSF/8FFB//BA4W/wUTHv8MFx3/',
    'DBUZ/woNDf8TDQT/EhAL/xAOCP8QDQb/EA4H/xISDv8QEg//DQ0J/w0LB/8MCwf/DgwI/w4MCP8MCgb/Dg4K/wwLCP8KBQD/BgIA/wIWHv8DOlv/BD5q/wIz',
    'Yv8LS3j/FWuO/wo+Wv8AFC7/ACJD/wIpTP8BDhz/AAAAtwABAVAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAawAAANYAEyX/AR47/wASJf8EGi//ByhF/wIXKv8BBAr/',
    'Axoy/wESJv8ACRT/AAMH/wMXKv8EJEX/Ahoy/wAID/8AAAD/AAAA/wAAAP8BAQH/AgIB/wUEAv8FBAH/BgUC/wcFAv8JBwP/CgkF/woIBf8LCAT/DAkF/w0K',
    'Bv8ODgr/ERAL/xANB/8PDAf/Dg0H/w8NCP8SEAr/EQ0G/wkVHP8FGCf/BRQe/wQUIP8GGyv/BRUi/wQTHv8EEx7/BhYj/w0QD/8RDgj/Dg0J/wgWIP8LExf/',
    'Eg0F/xQSDP8QDwv/DgwI/w8NCf8ODQn/Dw0J/w8NCf8REAv/DQsH/w0MB/8MCgb/CQMA/wUEAf8DIC7/BT1i/wI3Zf8DNGD/EFmB/xBbe/8CITz/ABw5/wMv',
    'Vf8BGC3/AAAA1gAAAGsAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAEBEgAAAIEAAwbuARox/wEdOf8ADyL/CCpF/wo0Vf8BFCb/AAUM/wMUJv8BFCj/Ag8d/wESIv8AAgT/AQwX/wMfPP8CGzf/',
    'Ah04/wMgO/8CER//AAMG/wAAAP8AAAD/AAEB/wICAf8CAgH/BQQC/wYFA/8IBgP/CAYD/wgGA/8KCAT/DAsI/w0MCP8NDAf/DQsG/xEPCf8SEQv/EhAL/xIP',
    'Cf8RDAX/Cxsk/wUVIf8FFSL/CCA0/wgiNv8IHzH/Bxsr/wUWI/8EEx7/BRgm/wcWIP8FFB3/AxMg/wYXJP8JExr/Dw4K/xISDv8QDwv/DgsH/w4MCP8PDQn/',
    'Dg0J/xEQC/8ODQj/DQsH/w0KBv8MCwf/CggF/wcBAP8CCQv/AitD/wQ7Zf8CLFf/CUVw/xhoi/8JNFL/ABUy/wIsUv8DIj3/AAIE7gAAAIEAAQESAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAR8AAACRAAcP/wEg',
    'Pf8AGTT/ABMn/ww3WP8LNlr/ARgv/wAOG/8BCA//Axsy/wEQH/8BFSj/AhIh/wEVKf8EGC3/Bi1T/wMdOP8CHTj/Ax87/wMhQP8DIUD/Axcr/wEHDv8AAAD/',
    'AAAA/wAAAP8BAgH/AwMC/wQDAf8FBAH/BgUD/wkJBv8IBwP/BQgI/wUMD/8GDRL/DQoE/xEOCP8SDwj/EA4H/wsXHv8IHCv/Bxkm/wkjOf8IIDT/CSM6/wgh',
    'Nv8KJz7/CSc+/wcfMf8FFCH/BBMf/wUaKf8HGyr/BBId/wYXJP8ODw3/EhMP/w8QDP8ODQn/DQwI/w0MB/8ODQj/ERAL/w8NCP8ODAj/DQsG/wwJBf8LCAX/',
    'CgkG/wkFAv8EAAD/Axgk/wU8Yf8DMVv/Bzdi/xlljv8UTWv/ABUy/wIpTf8DJ0n/AAYK/wAAAJEAAQEfAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQEnAAAAnAALFf8CJEL/ABUu/wMaMf8RSGz/CTRZ/wEbNP8BFCb/AAMH/wMR',
    'Hv8FITz/ARMj/wAKFf8GJD7/ARct/w0rSP8QPmz/CjFa/wkvVP8FJET/Ax48/wMdOf8DIUD/BCRD/wQdNv8CDxz/AAMF/wAAAP8AAAD/AAAA/wICAf8DAwP/',
    'AwMC/wMDAv8BBwr/AgoR/wIME/8GDRH/CQ4Q/woSFv8JGib/Bhop/wYVIP8KJz3/DCpC/wspQP8KIzj/CilB/wonPv8JJTv/Cic+/wooQP8JIzj/CiQ3/wsj',
    'N/8GFiP/BxUd/xANBv8QDwr/DxAN/xARDv8NDQn/DAoG/wwLBv8PDQn/DgsH/w0LB/8NCwf/DQwJ/w0MCP8MDAn/DAsI/wkIBv8GAQD/AwoO/wQwS/8GOmb/',
    'Ay9b/xZgiP8VWXz/ABs5/wInSv8ELlT/AQkR/wAAAJwAAQInAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAEBKgAAAKIBDRn/ASVF/wASKf8GIjj/F1V6/wo0W/8DIT//ARYp/wAECP8AAAD/ByI8/wcmRf8EGy7/AAUN/wAAAP8CCA//HViF/xpZ',
    'kf8WUoj/FEp5/xFCcf8OOWb/BypQ/wUjRP8EID3/Ax89/wQkRf8EIT7/Ahcq/wELFf8AAwX/AAAA/wAAAP8AAAD/AAMF/wADBv8ABAb/AQcL/wEJD/8DDRb/',
    'BBMf/wUSHP8HFyL/CSI1/wokOf8KJTr/DS5J/wwuSf8JJDr/CSU9/wcbLP8GGin/CSU8/wolOv8KIjT/DCc8/wcZJv8FEx7/Cw8Q/w4LBf8KDAz/CgoI/wwL',
    'B/8MDAj/CgkF/w0LB/8LCQX/DAoH/w4PC/8PDQj/DQsH/w0NCf8ODQr/DAwJ/wsLCv8JBgL/AwEA/wMgNf8GOmH/Ay1Y/xJSfP8ZYoT/AiA//wEjRv8EMFf/',
    'AQoU/wAAAKIAAQIqAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAScAAACiAA0b/wIlRf8AESf/',
    'CSlA/xtgh/8JMVT/BCRD/wMcMv8AAwf/AAAA/wEDBf8NNVr/CSxP/wgjPv8IGyv/Eig3/zJ4pP8+l9H/NIW6/zKFu/8tfrX/JWuj/xZQhP8TToP/EEFw/w04',
    'Yv8JL1X/BCA+/wMeO/8CHzv/AyE//wMgPf8CGS//AQ8c/wEHDf8AAQL/AAAA/wAAAP8AAAD/AAMF/wMKEP8FERv/Bxkm/wgcLP8KIjX/CSAy/wwpQP8MLUX/',
    'Cy5I/wwrQv8KIzf/DS1G/wopP/8IIDP/CiI1/wokOP8KJDj/CB4v/wQQGf8EEh3/BAwS/wQRGv8ECw//BgUB/wgIBP8KCQb/CgkG/wsLB/8NDAn/DQsG/wkL',
    'Cv8GDhP/CA0P/w0LBv8NCwf/DQ0J/wwNC/8KBwT/BAAA/wMWIv8GOWH/BDFd/w5Jcv8daIr/BCRE/wEjR/8EL1j/AQoT/wAAAKIAAQInAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    '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',
    'P/8KM1r/Dz5h/x1ojP8CJUr/CThj/wQdNv8AAADLAAECPQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAQoAAACZAhcr/wMoSv8BFzD/E1V+/wk2X/8EKEr/Axos/wMAAP8KCAT/CwgE/wsJBP8NCgX/DgwH/wgH',
    'A/8FAwD/AwcL/x9gj/8daKP/LYG8/zSFuP8FJED/BCNB/wUrT/8URGf/OZLG/zaOxP9Bn9X/QZzS/zqUyf8+ksX/Oo/D/ziOw/8+l8v/RJ/T/zuRxP8uean/',
    'HFaC/w88Y/8HLE3/G12P/x5lnf8VToD/EUBp/wcJCf8KDgn/ChEN/wwVEv8KEQ3/CRAM/wQFAP8AFin/BT1n/wMrTP8ADRz/BgcB/wsQDP8JERH/DBsh/w0Z',
    'GP8KEQ7/BxAT/wYPEv8BAQD/AxIf/w81Vf82ZYj/HjE+/xMDAP8bEg//Gg8K/wsMDv8LO2D/Cz5l/wMKEP8VDAj/GBIP/w8AAP8dND7/OnSY/wosT/8AFCb/',
    'AQEA/wIHCv8EDRP/BREZ/wgZJv8JGyj/CR0t/wYXIv8LGCH/EhAK/xISDv8QDQj/DwwH/w4MCP8MCQX/BAYH/wowUf8HLVL/F1J0/xdWe/8CI0n/Cjxp/wEM',
    'Ff8AAACZAAEBCgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAYwEJEfQFLlP/ABMt/w9Haf8SS3X/AiRI/wMjQP8BAgT/CgcD/wwKBf8LCQX/DAoF/w0KBf8MCwb/BgUC/wMDAv8AAAD/Gkdl/yNzr/8tf7b/NIvB/x5R',
    'dP8ygbH/IV2E/wMhQP8xgrP/OpPK/0Wg0/9Gm8z/TajY/0Gd0f9EoNT/PpTH/zeIuv85ibz/OpDE/ziQx/8zib//LX60/yZtoP8ia6H/H2KW/xdXj/8OMUv/',
    'BgEA/woMCf8NEAv/Cw4I/wkNCf8IDAj/AwUC/wEkQ/8FPmj/AipL/wAVLP8DAwD/CQ0K/wsRDP8LEQv/ChIO/wsSDv8JDgv/AwMA/wINFv8OM1P/MWOJ/x0v',
    'O/8UBQD/GxMP/xoSD/8dDAL/FEdn/xl1vP8YcLH/DDpc/xYHAP8bEg7/GhIP/xECAP8ZLjj/NW2P/wkpSP8ADyD/AgIB/wUPFf8HFiH/CRwr/wshMv8KHCv/',
    'CRom/xARD/8TEg3/EhIO/xANBv8QDQj/DgsG/w8NCf8KBQD/Aw8Y/ww3Wf8KMFH/H2WJ/wk5Yf8FLVb/CDJX/wAAAfQAAQJjAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAScAAAG6BCZF/wEgQP8DKkr/EFiE/wMkR/8EKUv/',
    'AQsT/wYCAP8KCQX/DAkF/w4LB/8NCwf/CwkF/woJBv8GBQL/AQEA/wkZJ/8bUHb/Jm+n/zWLxP83jcX/PpnR/zqWzv8ygK//AiNC/yVgh/9JrOH/Po+//xZM',
    'ef8oaZb/OYOw/0SXxf9Np9j/R6TY/zaMwP8yg7b/NYq//zGFvP8tfrb/LXmw/yh0q/8cXpL/DS9M/wQJDP8KCQX/CgoG/woMCP8KCgb/CQoH/wUEAf8BChD/',
    'AClR/wVCbf8DLE7/AB07/wEGCP8GBQH/CAsI/wkNCf8KDgn/Cw4K/wgKBf8HEBX/DC5L/y1egP8cNUb/FAQA/x0UD/8ZEAv/IhcT/x8NBf8/Y3L/OaPg/yCJ',
    'zP8XQF3/HwwD/x4UEP8WDgr/GBIP/xIDAP8ZMT3/MWeL/wckP/8BDxz/BgwP/wkaJf8IFiD/Ch4t/wkbKf8JHSz/DxMU/xUSCf8UGBf/EhQQ/xISD/8REAz/',
    'DgwH/w4NCP8FAAD/ByI2/ww4Xf8NOVr/GmKH/wImS/8KOmf/BBku/wAAALoAAQInAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAewIRIP8DK1H/ABo0/w5Ufv8HNVz/BCtQ/wIXKf8DAAD/CggE/wwJBf8NCwf/DgwH/w4MB/8KCAX/',
    'BwcF/wIBAP8FCxH/JWyi/yZ5t/8uf7f/MIa+/zSOyv8/mc//Oo/F/0Kc0f8TPFz/Cy5M/0mk1P9DmMn/Mnah/x9biP8UTn//E0h3/x9Zhv8uc6D/O4y7/z6W',
    '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',
    'cv8IHS7/CwMA/w8KA/8QCgL/EAoC/w8JA/8OCgT/CAIA/wIGCv8AGS//Ahgn/wIUIf8AEB//AA0a/wEPG/8BDBf/AQ0b/wEBAv8FAAD/CAQA/wwJBf8IAAH/',
    'ECw+/ylmlP8NGiX/IxUO/y8hHP80JSH/OSom/z4zMP8zJCD/NnuX/0XL/P82vvb/J2OA/yENBv89LCf/NCQe/yocFv8kGBT/Hg8H/xIfK/8bU3//FSg9/yAR',
    'Bv8XICT/Gicr/yAyOP8mP0z/IjtL/xQnNP8TKDb/Eyw9/xc2Sv8MIC3/Dhsj/yEUAv8lHRD/FBAI/xQPB/8UDwj/EA0H/wwHAv8ECQz/DTJP/wwuTP8XXoT/',
    'Bzdj/wpAb/8FHjL/AAAAtQABAhcAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAVQEMFvQFMFf/AyJB/xFSev8FKEb/BCdF/wEM',
    'FP8FAgD/DAoG/w4MB/8PDQn/Dg4J/woKBv8GAwD/AgwX/wIXL/8CFin/ARYs/wADCf8HJUD/Bi5W/wQiQP8DGTD/AQ8f/wAOHv8BFiv/BCJA/wkxWf8MOmj/',
    'D0J0/xZTi/8bXZf/HWOf/yBlnv8iaqL/JnOs/yp4sv8sebH/Ln20/ypzp/8hX47/HlqK/xE6X/8DGzP/BiRB/wQFBv8JBAD/CgYB/wkFAP8GAgD/AwAA/wAD',
    'Bf8ACRP/ABEg/wEZLv8AHTX/ASA6/wEkQv8BJkT/AiVA/wEiO/8BGzH/ABcp/wANF/8AAwb/AgAA/wEAAP8QLkL/LGua/wwYIv8iFQ7/MiQf/zIkIP86LSr/',
    'RTw7/zUrKf9BlrX/U9b//0XI+f8we53/Hw4K/z4tJ/8wIh3/LB4Y/yUZFf8cDwj/ERwn/xxPd/8eKjr/NhYD/yQeGP8tFw//LR8b/yc0OP8iNT//Gi87/xYt',
    'Ov8SJjL/FCs5/w8hLf8MHSf/FxML/ykfD/8bFQv/GhUM/xYSCf8TDwn/DwwH/wQBAP8KJDb/DC9N/xVIZv8QUHr/BTFf/wk3Xv8AAAH0AAEBVQAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACRBB86/wMmSf8INlf/Dkpv/wIfPv8EHzf/AgEB/woIBP8MCgb/DgwH/w4MB/8ODQn/DAoF/wgG',
    'Av8CEyT/ABQr/wEQIP8BDRn/ARUs/wcgOP8GLlX/AyVL/wUrVP8FKk7/BCE//wIYLv8AECD/ABEi/wEWK/8DID//By9Y/ww7av8PQHH/E0yA/xdWjf8bXZX/',
    'IGSc/x9km/8eYpj/IGSZ/yFkmv8dV4n/Dzhe/wYlN/8ACRH/AQAA/wMCAP8BAAD/AAED/wAKFf8AFSr/AB88/wAlSP8AKU//AChP/wAnUf8AJlH/AChU/wAq',
    'Vv8ALFn/AC5d/wAwXf8ANmX/ATln/wIsUP8BGzP/AAYN/xAvQ/8vb57/DBkj/yEUD/8wIx7/MyYi/zouLP9NRUT/NTU4/1Kx0f9j3f7/TtD8/z2UuP8ZDw7/',
    'QS8o/zcmIf8oGxb/IBYS/xsPCP8QHCj/IFF4/xImN/8hEQT/TR8K/6dbGf+lXiP/UC0h/zM8P/8hND7/GjNB/xQnMv8bNkf/EiUy/wodKP8TJCz/KRwK/x8Z',
    'Df8YEgn/Ew8I/xENB/8PDAf/CQUA/wUQFv8ONVX/DTNP/xhghv8GMFr/CkBv/wIOGv8AAACRAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAKgADBssFLFD/AR49/w9Ncf8HMlT/AyRF/wAOGv8FAQD/DAoH/w0LB/8OCwf/DQsG/w4NCf8NDAj/CgoI/wQaL/8AESX/AQ8d/wkkOf8EJkf/EkFq/xJR',
    'iv8PP2z/Cjln/wUuWv8FL1n/BSxR/wMfPf8CHz3/Ahgw/wEQIf8ADh//ARcu/wQiQP8HLE//CjZg/w09bf8RRXb/FEyA/xROgv8WToH/FUx8/xVKev8IKEn/',
    'DTRE/xdJYP8AAAD/AQID/wAIEf8AEiT/ARoz/wAdOf8AHDv/AB8+/wMpSf8JNFL/Djxa/xVMcP8URGT/Gklo/yBSdf8SQ2b/DT1k/wYzW/8ALFn/ACtZ/wAy',
    'X/8BHjr/DzNK/yVikP8DDhf/GRAK/y8jHv8yJiP/PTEv/0E5Of9GRUn/e9Dp/17f//9Q1///R67W/yAaH/86KSL/MyUg/ywdGf8hFxP/FAkD/wcQGv8bR2z/',
    'DiU4/zEaBP9wKgn/8rtJ///xY//Gejb/ZDgk/y88Qf8gND//HjZE/xowPv8SJjL/Eic0/xseG/8xIAz/IBcK/xkRBv8XEQj/Eg0G/w8MBv8OCwX/BgQC/wss',
    'RP8KK0n/FlZ2/wxDbP8IOWj/BihF/wAAAMsAAQIqAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABgAhAe/wQsUf8EKkv/FFN5/wQjQv8DIz7/',
    'AQQG/wgFAf8NCwf/DgsG/w0MCf8ODwz/DhEP/w0QDv8NDgr/Bx0w/wAKF/8DEyL/CCtJ/wAOIP8aTGr/IXOu/x1rp/8dY5v/Gl+Y/xdVi/8OQXH/CTRe/wc1',
    'Y/8FMmD/BCpQ/wMfPv8BFCr/ABAi/wAPH/8AESL/Ahkx/wQhPf8HKk3/CTJZ/wozW/8LNl7/CjJZ/wUlRf8BEiH/K3CJ/wglPv8AAwv/AQkU/wAPHf8BEiT/',
    'Ax44/wgzU/8RRWT/FEts/xdRdv8YV3//EEJl/xhWeP8XRWH/HlJ2/yl1pP8veqj/Mnei/zNxmf8kX4f/DTxj/wAXMP8RN1P/VZjB/yhEWf8AAAj/DQkG/zAm',
    'IP8+MzH/Qzs7/0A5Of9yhY3/g9/0/3Tf+v9AdIv/NiUi/zkqJf8tIBz/JBgS/w8IBf8AAgf/FCY3/zhpjP8lO03/QyUK/1EtFf+oVB//981g///vav/Ffzb/',
    'Wj4v/y9FT/8lP03/EiMs/xgnLv8uHw3/MR8K/ykbCv8eEwb/HxUJ/xoSCP8VEAf/Eg4H/xANCP8JAwD/Bhck/wouTP8QPl3/FVyG/wUxXP8LPWb/AAIE/wAA',
    'AGAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAJQFIj3/AiRG/ws/ZP8OQ2j/ASA//wIaLv8DAQD/DAoG/w0LBv8ODQn/DxMT/xAQDf8QEAz/',
    'ERAM/wsMCv8GGSr/AAgV/wAEC/8AAAD/KUlc/02x5f9CntP/QprN/z2Txv8pfrf/Kn65/yNyrf8fa6b/FlaM/xFKfv8LPW//CTVh/wcxXP8GLlb/BSdK/wMe',
    'Ov8CFSz/ARAi/wAOH/8ADyD/ARMm/wEVKf8BFi3/Ah45/wAABf8UTWD/JmmO/wAULP8BBAj/AAkT/wEaMP8DJD7/BCQ8/wQjPP8FIj3/CSU9/wwfMf8AFSv/',
    'ElJ6/wgzU/8AESL/EjJI/xhKaP8dY4z/J3en/zOFtf85g6//KmKF/yVJXv9WlrD/Xcfz/0eKqv8VKTz/AAAE/xoVEf84MC3/QDo7/0A4Ov9ZVVf/T05P/z0u',
    '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',
    'Dv8UO1b/DB4r/wUBAP8PEQr/ExYO/xEZFP8RGBH/ESAl/w4hLP8XMDz/HTZF/yE1P/8rPkX/STw2/8CMUf/wwWb/ZEMt/yg9Rv8iPEr/Fy47/xQtPf8TKjr/',
    'Chwn/wwWG/8fGAz/GRUM/xANB/8MBwH/BAoO/wkpQ/8KLUX/Fll//wU0Y/8KPGn/AQQH/wAAAGgAAAAAAAAAAAAAAAAAAAAAAAAAhgQfN/8BJEj/DEFm/wo6',
    'Xf8CJUj/ARYm/wMAAP8NCwf/EA4J/wwPDv8EEh//Bxwz/wkhOv8KJUH/DSxM/w0tTf8OMlP/DzNV/wwoRP8RN1j/GUlx/xhHbP8ZRmr/DzFK/wokNf8LHiD/',
    'DB8e/w4iIf8OHxv/DhsU/w0XE/8EBgL/BhMd/w45XP8UFhT/Hg8A/xgPBP8VDgT/CAQC/wAVKf8AGzT/ABAj/wIZKf8HIDb/EDZU/ylghf8jP03/CAkI/wkb',
    'Jv8GCwn/GW+c/weM1P8xptP/ETJQ/wAiR/8BIkX/AS9Z/wIpQv8BAAD/AgAA/wELEv8DCQ3/EAgA/xQMAf8VDAH/FAwB/xMMAv8XDgP/EQoC/wcCAP8CBgn/',
    'ABIl/w4uR/8eXIL/DxQV/xQGAP8QDwr/FVqF/yh9s/8naJD/ADRk/wdGd/8CFyb/DAMA/xsQA/8jFQT/JRIA/xktOP8SOFT/BggH/woJAv8TGRH/ExwX/w4W',
    'D/8PJTD/DB4n/xMpNv8dPlD/IDtJ/x0tM/8tPUH/U0Ex/2I4Iv8yMC3/KTxD/yQ7R/8dNkb/ESQw/w4gLP8HFyH/EBEQ/x4TBP8ZFAz/Eg4I/wsIA/8DBAT/',
    'ByU9/wgnP/8XWXr/CDtq/wo+bf8CDhf/AAAAhgAAAAAAAAAAAAAAAAAAAAAAAACiBCNA/wEjRv8MR27/BS9S/wImSf8ADRn/BgIA/w4NCf8SDQb/DBMX/wQW',
    'Jv8GGSv/CSE6/wkjPv8KJUH/DSxN/wsnQ/8MKUb/CyhD/xRBZv8ZRmv/FkNo/xZCZf8YRmr/DCc7/w0rQf8NIyn/CyAk/w0gIf8NGBL/CRIO/wMFAf8NL0r/',
    'EzVO/x8PAP8jFQT/HBIE/xIIAP8CDhj/Azdl/wAmT/8MQWP/CzVR/wIWKf8GAAD/DQMA/xACAP8PBgD/Dhwl/wULD/8eVmv/Do/V/xim4v80gaD/ABw//wIr',
    'UP8AIkP/ATJb/wIpQv8AAAD/AQkP/wALFP8HAwD/EAoB/xILAf8SCgH/EAkB/wsFAP8DAQD/AQ4a/wAZM/8NLkb/IGKM/xAyR/8VBgD/FA4E/w8EAP8SICP/',
    'E2Ka/zZ/qv8TVIT/AUJ5/wZBav8DAgP/FgwB/x8TBP8hEQH/GxgQ/xU+Xf8KGyf/BwMA/xAVDv8SGBD/EBcQ/xAnNf8OJjX/DyYz/xg2Sf8WLjv/Gy85/yY3',
    'PP8wQEP/LTEv/z4vJ/8uKyr/Jzg9/x82Qv8RJC//ECUy/wwcJv8MGSH/DRoh/xUSC/8XEgn/DgsF/wMBAP8FHzP/BiQ+/xBQcP8MRXT/Cj9w/wQaK/8AAACi',
    'AAAAAAAAAAAAAAAAAAAAEgACA7oEKUv/ASRH/wxJcf8CJ0n/AyhL/wAID/8IBAD/Dw0J/xMQCv8NDQr/CBgl/wYZJ/8GFyn/ByA5/wcdM/8HGzD/DClG/woj',
    'Of8HHjP/DzJP/xAyUP8QNlX/GUhs/xxNdP8WQWL/ETVQ/w8vRv8LIS7/DSQy/wsWFP8FCAP/BhAV/xFDaf8aISL/JhIA/yMVBf8cEQP/CwQA/wIsTv8BNmf/',
    'Bz1q/xRNbf8ILk//CRMZ/xUKAf8XDgP/GA8E/xkNAf8UEQv/CBUe/xYwNP8Yjsr/DJPW/zO45/8ZRGP/ACNM/wItU/8AJEf/ATFa/wEjOv8AAAD/AAkR/wID',
    'A/8JBQD/DAgB/woGAf8GAgD/AQQI/wATIv8AGTH/CixE/x1agP8PSHP/GBAH/xwPAv8UDAL/Ew0D/w4DAP8QPlf/GGmi/y16o/8CQXb/CUyD/wQfM/8NAgD/',
    'GhAD/x4SA/8eDwD/FzRG/xAyS/8FBAH/DQ8J/xAVDf8RFw//EBgS/w4dJP8QKzz/FzhN/xUvPv8gQVT/Jj5J/yo8Qf8xNzf/gEol/69rLf9YPy//IjA0/xIj',
    'Lf8TKDX/Eik3/w0eKf8JHiz/EBsg/xgRBv8PDAb/BQIA/wMYKf8DHzn/DUVj/w1Ne/8IOmz/BiU+/wAAALoAAQISAAAAAAAAAAAAAAAnAQYM0AQsUf8CKEr/',
    'DEtx/wEiQv8CJUb/AAQH/wkGAf8PCwX/FBAI/xcQBf8XEQf/ExUT/wYaK/8HHjT/CylI/wsnRP8MJ0H/ETVV/wgiOv8OLUb/FDtc/xtOdv8fVH7/GUZr/xZF',
    'Z/8UPFr/Dy9H/w8vSP8LHSf/ChgZ/wQHAf8KJDf/Ez9h/yIVBv8nFgP/IBMF/xUJAP8EEBr/AkBz/wA2af8TVHr/DT1h/wgmPv8OBQD/Fw4C/xkPAv8bEAP/',
    'HBED/xkMAP8QFhj/DRgY/xp3o/8MjdP/GrDs/0Gbv/8EJk7/ATFe/wEsVf8AI0X/ATNb/wImP/8AAAD/AAQH/wIBAP8DAgD/AQEB/wAIEP8AEiH/AA8f/wUZ',
    'Kf8YUHH/EE+B/xEcIf8dDQD/GhAD/xcNAv8TDAL/EggB/w8VEf8PT33/JnOd/xhjlP8DQ3r/C0Zv/wUDA/8WDQH/GxEE/x8OAP8XHyD/ET1b/wcPEv8JCAL/',
    'DRIN/w8WD/8QFg3/Dh0j/w0iLv8WMkT/GjlO/xw6TP8jO0b/JDY7/zMoJv/Ejkr///d8/5VXJv8tKif/GS01/xQnMv8ULDr/DyMw/wsZIf8aGRT/HxYJ/xAN',
    'Bv8HAgD/AhId/wIgPf8INlL/DVF9/wc4af8IL07/AAAA0AABAicAAAAAAAAAAAAAADoCDBXjBC1S/wQsTv8LRm3/ASFC/wIiPv8AAQL/CwcD/w8LBf8TDQX/',
    'HBMH/xwTBv8aEgb/Cx0s/wceNP8LJ0X/DTBS/w4tTP8OLkv/DCpE/xpMc/8cUHn/GERn/xdCZP8XQ2b/ETZS/wsjNv8LJTr/CyEx/wgYHv8HEhH/BAgE/w47',
    'W/8TL0P/IRAA/yIVBf8cEQT/DQMA/wMuT/8CRn3/C059/xVQb/8FMFb/CxMX/xcLAP8bEQT/IRME/yITA/8fEgP/HRED/xgRBv8ICwr/H1px/xOR1v8Rmdb/',
    'N8b0/zBkh/8AJVP/AjBZ/wEsU/8AJ0z/ATRd/wEjOf8AAAD/AAEB/wADBv8AChP/AAgR/wACB/8CEB3/DTdU/ws6X/8ONFD/GQ4A/x4TBf8dEgL/HBEC/xYN',
    'Av8VDgT/EQUA/w01Sv8RVIT/KXSb/wVNh/8PW5H/Bhkl/w4DAP8XDwT/Gg4A/xgTCv8SN1L/Ch0p/wYDAP8KDgz/DBMQ/w0WEv8OISr/Cxwl/xEqOv8WM0f/',
    'GDND/x0zP/8hMzn/MjAs/55fL//+8nv/zY9E/zwjGP8dLTL/EyQs/xEkLv8LHCb/EBkb/yASAv8cFQr/FxEI/wkEAP8BDBT/AiI+/wQqRf8PVYD/Bzps/wk1',
    'Wv8AAADjAAEBOgAAAAAAAAAAAAAASgIRHvQEK1L/BjFT/wtAZf8BIkT/Ax85/wEAAP8LCQT/EAwG/xMOBv8XEAb/HBQI/xsSBv8LHy//BRww/wgfNP8OMVP/',
    'Ejdb/w4sSP8UOlr/H1R9/xtMcf8XQ2X/F0Jk/xM8W/8SNVD/Dy5F/wkfMP8IFyH/CBQX/wUNDv8EEhn/DUBl/xUfIv8jEgD/GxIF/xYLAP8HCQn/BUd4/wJF',
    'f/8VXIb/DTtb/wcnQf8SCQD/HBED/x0RA/8gEwT/JBUE/yETBP8gFAT/HBAD/woFAf8cOD//HIXB/xOV1P8duvD/T7bY/wsyXP8BMV3/AjBZ/wErUv8AJUj/',
    'ATBY/wEhNv8AAAD/AAcO/wAECf8BCxX/CzpK/wISHv8GJj//CC5M/xIVEv8dEAH/IRYG/yIWBv8gFAX/GxED/xYOA/8UCAD/Dx0d/wdDcv8oa5H/FWKW/wlS',
    'iv8IM0//CAAA/xQOBP8VDQP/FAsA/xErPf8MKkD/AwMA/wcGAv8JDw7/Cxkd/woTE/8LGyP/DyY1/xIsPf8aOEz/GjE//x0xOf8uPT7/ekQn//jTcP/txV//',
    'ZUEs/yMxMv8fN0D/EiIp/w8eJv8LGiL/CBUd/wsPEP8ZEQb/CwcB/wEJD/8DIj7/AiM9/w9Uff8IPW//CTli/wAAAfQAAABKAAAAAAAAAAAAAABYAxYn/wQs',
    'Uv8INVj/CTtd/wAjRf8CHDX/AgAA/w0LBf8SDQb/FhAH/xYPBv8dFgv/HhYI/xIbIP8KHSz/Bhor/wspRf8ROFz/FD5l/xdBZv8dSW3/HEty/xdEZ/8UPl7/',
    'EThW/w0rQ/8NKj7/CB4u/wkdK/8GERX/AgUD/wMZKP8JOFv/FBEK/xoPAf8WDwb/DgQA/wUdKv8GTof/BEuD/xNWe/8FLlH/CRkk/xYKAP8eEwb/IRME/x8S',
    'A/8dEgT/JBcF/yMWBP8dEgP/EwoA/xMTDv8jgK3/Do3R/xqn3/85zfn/QYGl/wAvY/8CO2r/AStS/wEnS/8AI0X/AS5T/wEbL/8BAAD/AAQM/wg0Uv8acZb/',
    'AQ0X/wEZLf8JGCP/Fw0A/xwTBf8iFwb/HBMH/xwRBP8dEgT/Fw4D/xUNAv8RCwL/CDpa/xZPd/8kdKL/Bk+J/wxKdf8FBQT/DwgB/xAMBP8QBwH/DBki/wos',
    'Rf8EBwj/BQQB/wYJCf8GDA7/Bg8V/wsbJf8OJzf/ESk6/xQuQP8aNET/JD1J/yU5Pv9KMST/2qZY///vgv96VTX/Lj5C/yQ7Rv8bNEH/Fis3/w8iLf8JGSP/',
    'CxMY/xQPB/8MCAL/AQcL/wMiPP8BIDr/DlJ5/wg8bf8KPGf/AQMF/wAAAFgAAAAAAAAAAAAAAGMEGS3/BCtR/wg4Xf8HNVf/ASRG/wIZLv8DAAD/DgsG/xMO',
    'Bv8YEQf/GBEG/x0VCv8jGgv/IRQC/xoaFP8HHzP/CiI3/xAyU/8RN1v/F0Jp/xlHbP8XQGD/FDxb/xM5WP8PL0j/CiQ4/wcaKP8HGij/BBAZ/wIMEv8BAwP/',
    'ARgp/wMfNf8OCAD/DAYA/wcDAP8CAAD/BS9M/wNPjP8JU4b/DUVl/wEnSP8LDQ3/FwwA/x4TBf8hEwT/IhQE/yMVBP8lFgX/IRUF/xkQA/8WDwT/DAAA/yJh',
    'eP8Pic7/HJXL/yC88f9bzO//GFCD/wA8dv8DOmv/ATFe/wAoTf8BJUf/ACJA/wEQHv8AGTT/EE1t/w5jmv8GJDX/AAkT/w0KBf8XDwT/HRUH/x4VB/8iFwf/',
    'HRMF/x0SBP8ZDwP/Fg8E/xMHAP8MKjr/CDph/ydvl/8MW5r/DFSJ/wMPF/8EAAD/BwIA/wkCAP8FCQz/BiM6/wMMEv8CAQD/AwgK/wMGCP8FDRL/CBUd/wgW',
    'Hv8KGiX/DSIu/xEmMf8cMz//ITM5/y00M/+AVDP/rG84/1BGOP8qO0D/IDU+/xoxPP8VLDr/DyAq/wgYI/8OFRj/Fw4E/wsHAf8CBQf/AyE7/wEeOP8MTnb/',
    'CDtq/wk8Z/8BBgn/AAAAYwAAAAAAAAAAAAAAawUbMP8DKlH/CTth/wc0V/8AIkT/ARYp/wQAAP8PDAb/FA4G/xcQB/8bEwj/GxQI/yEZC/8gFwj/Hh0W/wwt',
    'SP8HIjj/Bxwu/wsoQf8SPWL/EDVU/w0oPv8NKkH/Dy1F/wkiNf8GGCb/BRId/wQPGP8CChD/AQYK/wAAAP8AChT/AAYL/wIBAf8BBw3/AA4d/wAGDv8EQWr/',
    'AVCS/w5biP8IMU3/ACA7/w8JAf8aDwL/HBAD/yATA/8jFQT/JhcF/yUXBf8iFQb/HRIF/xYPBf8KAAD/GzU6/xeLy/8XhL3/H7Dm/zbP/P9On8T/ADVw/wJC',
    'e/8AMmD/ASRF/wEeOv8ADR3/ABo0/wMnRP8SXIP/BUd+/wk5U/8BAAD/DgsD/xQOBf8XEAX/HRQG/yMYB/8eFQf/HRIE/xsRBP8YEAT/EwgA/w4cIv8DMVX/',
    'ImCB/xFel/8JWpb/BSU4/wALGP8AEB7/AAYK/wEBAv8BChP/AAQI/wAAAP8BAwT/AgcJ/wMIC/8EDBH/BQ4T/wcSGP8JFh7/Cxkh/w8eJv8ZKS//JTU6/y40',
    'Mv8/MCX/KzU2/yU5QP8cMDn/FCUu/xIkL/8KGCH/EBUY/x0WDP8bEQT/DAgC/wIEBP8CHzj/ABs2/w1OdP8IO2r/CDxp/wEIDv8AAABrAAAAAAAAAAAAAABw',
    'BR0z/wMpT/8LPmX/BzNW/wAiRf8AFCX/BAEA/xAMBv8XEQj/GREH/xsTCP8fFwr/HhUJ/yIbEf8hGAr/FyUq/xUdHP8QKDn/CCQ6/w4tR/8QM1D/CiY8/wca',
    'Kf8GGCb/BBId/wMME/8BCA7/AAQG/wAAAP8AAQH/AAYL/wAQH/8AFSj/ABw4/wAfPv8AHDn/AQ4a/wZKef8EV5n/D1uG/wMiPP8BFin/EQgA/x4TBf8gEwX/',
    'IxQE/yUWBv8pGgf/JRcG/yAUBv8bEQX/FA0D/w0HAf8OEAv/H4Gy/w+Dx/8gndP/Hbrv/1PS9v8oYZH/ADJn/wIrUf8AIkL/ABQp/wENHP8AGTj/DEZl/w9e',
    'kP8BPHL/DExx/wICA/8JBgH/EQ0E/xMNBP8aEgb/IBYH/xsSBf8bEgT/GxEE/xYOBP8RCQD/CxIS/wAsT/8bUGz/GGGU/wlXk/8KNVD/ABAi/wAkRf8AJEX/',
    'ACE8/wEaLf8BDxr/AAQH/wAAAP8AAAD/AQIC/wIGCf8DCQz/BAsP/wUMD/8HDxP/Cxcc/xIgJf8cLDH/JzMy/zIpIP8wKCX/Jzk+/xotNv8SJCz/DRwk/wwa',
    'Iv8mFQT/KBcG/xgQBv8NCAL/AgMD/wIeN/8AGjT/Dk5z/wg/bv8IO2j/AQoQ/wAAAHAAAAAAAAAAAAAAAHMGHjT/AihO/w5BZ/8IM1b/ACNG/wATJP8EAQD/',
    'EAwH/xUPBv8YEQf/GhMI/x8WCf8fFgn/IRkL/yEaDv8gHBH/JSAR/yQnIf8PKDr/Bxss/wojN/8FGCb/AwwU/wIIDf8BBAf/AQIC/wADBf8ACA//ABMi/wAY',
    'MP8AI0X/AShN/wAmS/8BIED/AB47/wAXMP8CEh3/BlOJ/wVUk/8PVnr/ABox/wANF/8LBQD/Fw8F/yEUBv8kFgb/JhgH/ykaB/8kFwb/GxIF/xIMA/8MBwD/',
    'BwYC/wIAAP8cYn7/D4PJ/xaGw/8eq+H/N9H8/2Ox0P8DJVD/AilM/wEbNf8ADh3/ABMn/wEfPf8TY4n/CVeR/wI5aP8IVon/AxIb/wIAAP8IBgH/DQkC/xMN',
    'A/8aEgX/GBAF/xoSBP8XDwT/EgwE/w0JAv8GBgT/ABoz/w9EYf8XZpj/B0qE/wo9X/8ACxj/AR8+/wEgP/8BJ0r/ASZH/wEoSv8BJET/ABwz/wATIP8ABgv/',
    'AAIC/wEBAP8CAwL/AwYH/wQKDP8IDhH/DRQW/xMdIP8mIh7/i1Qo/6VlLP8/NS7/HTM9/xYpNP8LGyX/EBsh/ysYBP8lFwf/FA0E/w4JAv8BAgL/Ah01/wAZ',
    'Mf8OTnL/CkFx/wk7af8CCxL/AAAAcwAAAAAAAAAAAAAAcwUeNf8DKlH/DkJn/wgxU/8AIUP/ABMk/wQBAP8QDgn/FhIL/xwXDv8dGQ//HxsR/yMfFf8kIRb/',
    'IR8V/yEnIv8gIRr/IRwP/xIlMP8GIjb/Ag4Y/wAFCf8AAgX/AAQK/wALGP8AEyj/ABk0/wAgQv8AI0b/AB08/wAaOf8AIEP/ACJF/wAbOf8AHDn/ABYv/wIX',
    'I/8GWZT/Blub/w5IZf8ACxr/AA4b/wEBAf8FAQD/DQYA/yIVBf8qHAn/JBcG/xYNAf8JBAD/AwIA/wIDBP8ACAz/AAAC/w41Qv8Oer3/CXC0/yGf1v8mu+7/',
    'SM/5/zBeff8AFzr/Ahcr/wEMGP8AFzL/CTRN/xNrnv8DSoL/BT9v/wdSiv8HLUP/AAAB/wAGCP8CAgL/BgMA/woGAP8UDgP/GhIF/xELAv8HAwD/AwEA/wEE',
    'Bv8AECT/CS5D/xlnl/8GUI7/CD1h/wENGP8AIUD/AB08/wAhQv8AHTz/ABs6/wAcO/8AIEL/ACBA/wAdOv8AGjT/ABEk/wAIE/8AAQX/AAAA/wECAP8KCwr/',
    'ERsc/0IgFP/mtFv//95o/24+JP8XJy3/EyQt/w0fKv8PFhn/JxUB/ywbCf8YEAX/DgkD/wICAv8BGzH/ABgy/w5Ncf8LQ3P/CT1s/wINFP8AAABzAAAAAAAA',
    'AAAAAABwBR41/wUtVv8NQWj/Bi9P/wAhQf8AEyP/BQEA/xANCP8WEAj/GBII/xgTCf8dFwz/HhgO/x8aD/8gGg7/ICAW/yQiGP8cGhD/DCIy/wolOv8TKDb/',
    'DSIz/wkeM/8KITr/CiE8/wshPP8KHTb/CBw2/wgfO/8JIT//CyA8/wskQ/8JJUb/CSNB/wkjO/8CGS//BBwp/wdcl/8GYaL/DT9Y/wMJGP8EFSr/AxEi/wEN',
    'G/8JDAz/IxYG/y4eCv8fFQb/BAcI/wIKD/8CCxH/AgwS/wEIDf8AAQT/BRQX/wlfj/8Taqf/EoC//xqi4P8bren/TKzQ/wscNf8ACxv/ARIk/wAZN/8WVnb/',
    'CVaR/wRLgf8EPm3/Bk6G/w5Jaf8AAAH/AQsT/wELEf8ACA7/AwgK/xMOBv8eFgj/FhAG/wUNEv8CEiP/Axgw/wMSKP8JGCT/GWCL/wZUk/8JQWf/AQsU/wsw',
    'Tv8NJUH/DShF/w0oRv8MIzz/CyQ8/wkkPP8KIzr/CSE3/wwjN/8MJjz/DCU7/wwjN/8NIjP/EyUu/xckKf8eKiz/VS0d/92qTv/+3mv/d0gs/yExOv8ZLzv/',
    'ESUx/wsfLP8bFQ7/KBUD/xYOBP8NCQL/AwIC/wIbMv8AGDP/D09y/w1Dc/8KP27/AgwT/wAAAHAAAAAAAAAAAAAAAGsFHjX/BTBb/w9Eav8HME//ACBA/wAT',
    'Jf8EAQD/EA0H/xIOB/8XEQn/GhQK/x4YDf8dGA3/HxkO/x8aD/8lJRr/Kywh/xsbE/8HHC7/DCI0/zFSZP9Cf5X/QYys/zyXw/87ns7/OZrJ/zuaxv88mML/',
    'RKbP/1Cpzv9Rs9f/Trnc/1a63v9OsNf/SLTc/yFTc/8BJj//CGOf/wZYlv8qfJ3/NpG3/yqItP8sibT/LXOQ/yU7Pv8qGwr/Kx0M/ykdDP8cMTz/GUFY/woq',
    'PP8EGCX/Aw0T/wIDBP8BAgH/AydC/wMrUv8BOGb/B0+H/whpq/8hnd3/K150/wAAC/8BGDL/BipG/x9wmv8ESIH/BkyE/wZIfv8ERHv/DVaE/wEMFP8EFiT/',
    'Cik+/xAzSf8XM0P/HRwV/yIWCf8dGRH/K1Jd/zCCov8rjLn/LY24/yiEpv8aY4v/BU+M/wdGcf8CGTH/RJa+/02y3f9Pr9f/SKzV/0Sn0v87ncj/NI+8/y+M',
    'vP8shLf/K32x/zGAsf8vfKr/NHqg/zVykP84ZHb/IzpA/x4tMv9YNyr/36xa//zda/9vRCr/IjQ9/xs1Rf8QJDD/CRsm/xYVEP8mFQP/GRAF/w0IAv8CAgL/',
    'ARow/wAZM/8QUHL/DEFw/wo+bP8CCxH/AAAAawAAAAAAAAAAAAAAYwYfNP8GMVz/DkJp/wgwUP8AIEH/ABQn/wMAAP8PDAf/Ew8I/xcRCf8bFAr/HxgO/yAb',
    'EP8eGxD/HxsR/yMjGv8nKyb/IR4S/w0gLf8IITX/ARMl/wYcLf8PM0j/FENa/x1jg/8ghLL/HZnT/xee4/8Wpur/FaTm/xyy7v8luu//JLvu/x617v8bs/P/',
    'F1+G/wIpRf8HX53/BliY/w9Rcv8LWoX/D2KL/xUxOf8hGg7/KxgF/zAfC/8oGwr/LBwI/yETA/8VEgz/DRsj/wAIGP8ADyX/ABQu/wAjRf8AIUL/ARs3/wMd',
    'Nf8CHzz/AilP/wAzZP8ZY43/CCIz/wAPKP8USGP/EWei/wJCeP8HTYT/B0t//wRFff8LV47/BiIz/wIJD/8LFRv/FRIM/x0SA/8eFAX/GhIH/xoRBf8XDQH/',
    'FRsX/xQ/Tv8LbqL/DFeD/xlfjf8FTYv/BkBq/wYfNv8hksr/GaTj/xyf2v8an9z/GpbX/xKL0f8Pf8b/EX7F/xN3uP8Zb6b/Fld//xE/Wv8PLT3/DiQx/w4h',
    'Lv8VKzj/ITY//0ozKv/hsVz//+p7/2pDLv8fMTv/Fiw4/w0dJ/8KGSP/GxQL/yQUBP8YDwT/DQgC/wECA/8BGzL/ABgx/xFTdv8MQG//Cj5q/wEJD/8AAABj',
    'AAAAAAAAAAAAAABYBh0y/wcyXf8NQGb/CTRT/wAfQf8AFir/AgAA/w4MB/8SDgj/GBMJ/xoUCv8fGQ7/Ih4U/yAdFP8iHhP/HhwS/yAjG/8jJh7/HiMg/xce',
    'Hf8VFhD/Cx8w/wspQv8NK0b/CBkp/w0dK/8WLzz/Hkte/yZti/8vl8D/LrDk/yWz7v8dq+n/Hafj/xWa3P8Tc6L/BiQ7/wdkpP8IZ6z/E05s/wAMIv8CBQr/',
    'FgUA/yQYCP8sHw3/MSAM/zEhDv8rHgv/JxoK/xYMBP9QZW7/XJ+9/zdtkP8wWXv/GEZu/wYzYf8AIEn/ABk//wAdRP8AHD//ABg0/wAkSP8EMlP/BBUn/xlo',
    'jv8GWZv/B0yD/wZKf/8ISXr/BkV6/wtXkP8LPl3/BAAA/xAKAf8TDAH/FxAF/x4VB/8cEwf/GBEF/xUQBv8RCQD/CQAA/wAZNP8LOVr/GGmZ/wVTkv8HPmj/',
    'BiM2/xiGwv8Zhsn/Go7P/xqIyv8eicn/Ioi+/x9tlP8bS2P/FzhF/xUqNP8QJC//Dyc4/xEsQP8RKj3/ECg6/xg0R/8hOkb/MjMx/5lnPv+1f0j/Qjgz/xwv',
    'OP8MHCX/ERof/x0RBP8qGQb/HxIF/xQNBP8OCQL/AQMF/wEcMv8AGDD/EVd8/w1DdP8MQW3/AQYK/wAAAFgAAAAAAAAAAAAAAEoFGSz0CDVh/wxAZ/8JNlb/',
    'AB9A/wEZMP8BAAD/DAoG/xEOCP8ZFAr/GRQK/x4YDf8gHBH/JB8U/yMeEv8eHxf/IiAV/x4hHP8hKij/Iy0r/xodGP8OJjr/CyhA/w8vS/8PNFT/DzRU/wkk',
    'PP8HGSv/CBgm/w4ZIP8aMTj/KGWA/zKIqv8nmMf/GJvg/wyDxf8HLUb/CmOd/wZor/8YYIT/ABcx/wEUJv8TDAL/IRcK/ywdC/81Iw7/NSMO/y4fDP8qHAv/',
    'IRYI/xkOBv9YhJD/Zd///1zJ7f9ry+r/bMbk/2Ooxf9ShaL/OGSA/yFFZP8OLk//AR0//wARMv8HM0r/FW+i/wdSj/8IVZD/B0yE/wdFdv8GRnr/CVCI/w5R',
    'fP8FBAT/DAgC/xAMBP8WEAX/HBMH/xoSBf8YEAX/FA4F/xALBP8IDQz/AC1U/wxAYv8Ua6D/B1mb/wY5Yf8LOln/F4DE/x2Ewv8jfqr/H2CA/xY8S/8SIiX/',
    'EB8l/w8hK/8OJDL/ES9G/xU6Vf8RMEj/FjpU/w4nOv8LHyz/DiEs/xUoM/8pPEP/NzIv/zcpJf8mNjz/ESAo/w4eJv8bGBL/LBcD/ywaCP8cEgX/FA4F/w4J',
    'Af8BBgn/AR00/wAYLv8SWoD/DUR3/wxCbf8AAwT0AAAASgAAAAAAAAAAAAAAOgQUIuMKOGT/DEBp/ws5WP8AHTz/Ah02/wEAAP8LCQX/EQ4I/xYSCv8YFAr/',
    'HhkO/yEbEP8iHBD/HhkN/yQlHP8fHxf/HCYm/x4oJv8kKiX/FiAh/w4sRP8KJTz/FkNn/xZCZ/8QNVX/EThY/w4wTf8LJTr/Bx0u/wAOGf8ALlX/BxYm/yQa',
    'DP8hNjj/GlFn/xA5T/8MXpL/BWKn/xpvnP8CHDb/ABUq/w4IAf8iGQz/LiAO/zgmD/84JQ7/MSEN/y8gDf8pHAz/HhUJ/w4AAP9LaG//Vsz2/0a+6P9gzvD/',
    'cOH//3Pp//955P//heL6/4rT6f9qtdH/YZiw/0d+nf8ANWv/Bz9u/wZMhP8ITob/B1CH/wdMgv8HRHj/DVmO/wYXIf8IAQD/DQoF/xQOBf8YEAX/Fw8E/xYP',
    'BP8UDgX/DwkB/wYRFf8AKlL/EEtt/xFmnP8JW5r/CDpc/xA2TP8hSVj/ICYh/xYQBv8KLUb/Bxwq/woTGf8PKDn/EjFH/xU8WP8UO1j/Dy1D/xEvRv8PKDr/',
    'DSEu/xcYE/8WGhf/EiMr/xsnLf8uJyT/LCkm/xgkKP8NHij/HhgP/zIZAf8wHQr/IhUH/xoQBv8WDwX/DAcA/wAHDf8BHDb/ARwz/xNdg/8NRHj/DUJs/wAA',
    'AOMAAAA6AAAAAAAAAAAAAAAnAw8Z0As5Zf8MQGr/DkBh/wAbOf8BHzr/AAEB/woIBf8QDQf/FRIJ/xgTC/8dGA3/IBsP/xwaEf8dHhj/ISQe/yQoIv8eKCf/',
    'Eh4i/xQeH/8QIy//DjNR/w4xTv8bUHn/GlB6/xQ8Xv8RN1f/DzRT/w8wTP8LJz7/CBch/wlEaf8KQWj/JA4A/ycSAP8jDAD/FQ0B/xJjk/8FZ7L/GnWp/wkl',
    'Ov8AFS//BwYD/yAYC/8uIRD/OScR/zwoD/82JQ//NiUP/yoeDv8kGw3/FxII/wAAAP9DZHX/Z9r+/0vG8f9jv9//Z8jn/2PX+f9h2Pr/Ytn7/17Y/f9y6f//',
    'jN/3/yJQff8ANGf/BkFz/wVCd/8JV5D/D1aH/wdEd/8KVo3/CC1E/wUAAP8LCQX/EgwD/xcQBf8XDwX/FxAG/xMOB/8PBwD/BBYj/wAnT/8VV3v/DmCb/wpa',
    'lv8NMUf/FQUA/xsNAP8iDwD/HR0X/xVKbv8MISz/DR8p/w8pOv8SMkr/FDhU/w8tRP8OKT3/Dyg7/wskOP8WFQ//KCET/yIcEf8UJi//NiUe/4ZEF/9nNxj/',
    'GyAj/w0eJ/8nGQr/MBwH/y0dC/8dEgX/GhEG/xYPBv8KBQD/AAkS/wEbNf8DIjr/FF6I/w1EeP8OQGj/AAAA0AABAScAAAAAAAAAAAAAABICCA66Cjhg/wo6',
    'ZP8QTHD/ABo3/wEiQP8AAwb/CQcD/w4MB/8UEAn/GRUM/xoWDP8eHhb/HR4V/yIgFf8gKin/Iy0s/yMnH/8RJzb/DTJQ/wooP/8LLkv/GEx0/x9Vf/8bTXX/',
    'ETpc/xI3Vf8SOVn/FEBl/w4tRf8IGCT/DDtX/wxXh/8mFQT/Mx8K/yweDf8fDAD/FVZ5/wZtuf8Ve7f/EDtS/wARKf8DBwv/Ew0F/ykfEP8zJBH/PiwU/zkp',
    'E/85KRP/MCMR/yMaC/8PDAX/Ah42/wALIv88V2X/atv8/1PQ+P9jyOn/acjn/2/c+v9i1fj/UMXu/1nO8/9d1vr/fLza/wdCfP8HSX//BUB0/whMgv8NVon/',
    'CU+D/wdIff8LRGn/BQIA/wsIBP8PCwT/Ew4F/xUPBf8UDQX/EAwG/woEAP8BHjb/ASlN/xVgiP8KWZf/DF6Z/w8eJ/8gEgL/IRkO/yMTAv8bKCv/F1B2/wsa',
    'If8LGSH/DCQ2/xQ6Vv8MJDb/DiY5/xccGv8YGBL/HCMj/yUhFf8mJRz/MCQU/yYdE/95PyD//+l4/7R8Nv82Hhb/JR0S/zAYAf8vHAr/IxYH/yEUB/8YDwX/',
    'FA0F/wgDAP8ADhr/ABky/wQpP/8TXIn/DkZ7/ww3Wf8AAAC6AAECEgAAAAAAAAAAAAAAAAECBKIKNlz/CTVg/xJNcv8AHjv/ASNF/wAGDv8GAwD/DgwI/xMP',
    'Cf8XEwv/GhcP/x0bEv8YGBH/Exob/x0iHP8hIhn/HB0V/xAlNf8LKkP/FUNp/xZGb/8aT3n/Il2K/xlHa/8TPF7/HFB4/xA1U/8SOFj/Di9J/wshNP8QMUL/',
    'DmWb/yEfFf84HgL/MiEM/y0SAP8eSlr/DXa7/wl1vP8TVXf/ABMr/wARIP8MBgD/HxgN/yshEv85LBv/OCoX/zYnFP81JhH/GQ8B/wIUI/8CLFD/AB06/wQh',
    'O/9HboL/cdz5/1DS+v9iyez/Zr/g/2jU9P9k2v3/WtH2/1rQ9P+D6///TYqx/wBAff8KTYP/BD90/whLfv8KUIL/BUV7/wxUhf8FDRH/CgUA/wwJBP8QCwX/',
    'FA8G/w8LBP8NCQL/BQcG/wAhQ/8HMlD/FnCg/wZRjv8NVor/ExIM/yAVBv8jGQv/IxIA/xs4Sf8USGr/DBke/xEnN/8SMEX/EzFI/w0pPv8VHiL/IBoM/yIo',
    'I/8oJxz/Kygd/ywgD/82JxT/UCMB/6dfI//++oP/tXQw/1IcAP84Hwb/MBwH/y0bCP8iFAb/IRUI/xYPBf8RDAT/BQIA/wARH/8AFS//CDVP/xRaiv8OSH7/',
    'CCtF/wAAAKIAAAAAAAAAAAAAAAAAAAAAAAAAhgoxVP8HNWL/EUx0/wIiPf8AIkP/AAsX/wQBAP8MCwf/EQ4I/xUTDf8cHBb/HBcM/wwbJ/8IJT3/Dh0l/w4e',
    'J/8KHy//Cic+/xA0Uv8aS3X/Gk11/xtQd/8cUXn/Gkpx/xxLcf8hV4L/GERm/xhFaP8QOFf/DSg+/wwjLv8VbaH/GjE5/zobAP87JQ3/MxoC/yQtKP8bf7z/',
    'BHK8/xp7qv8FHDH/ABcy/wUEAv8SDwj/JR0R/zQnFv89LRj/OSoV/ysdC/8MDAj/AClO/wAjSf8kU3P/JWiS/wAkRf87Ynn/e+D7/2Ha/f9r1fL/b8Dd/2K2',
    '1P9s3/v/Y9j4/17X9/+D3fb/JF+R/wNJg/8LTYL/BkZ6/wY/bf8GRXn/DVaI/wknOv8GAAD/CwkF/w8LBP8QDAX/DQoF/woEAP8BEBr/ABo7/xBKZ/8QaqT/',
    'B1eX/w5EZ/8aDAD/IxkM/yYZCv8gEwP/G05v/xM7Vv8LFx3/Ey5C/xlCYP8WN1D/Dy1E/xogHv8kHA3/Iykl/yAhG/8rHgv/MR8K/zEfC/9UIAL/x4Q7//7x',
    'ev+eVRv/Rh0B/zUeB/8tGgb/KRgG/yMVBv8aEQb/Fw8F/xELBP8CAQD/ARco/wATK/8NQl7/FFaI/w9KgP8HIDL/AAAAhgAAAAAAAAAAAAAAAAAAAAAAAABo',
    'CChE/wg4av8RTXf/BipG/wAfQP8AEyT/AgAA/wsKBv8QDQf/ExIN/xsbFP8WFA7/CBsr/wceMv8JIzn/CCM6/wokPf8PNFT/GEpy/xxOeP8eU37/G1F7/xdG',
    'af8eVX//IVuH/yBTev8eU33/GU12/xI7W/8QM03/DB8r/xthiP8UTm//NxgA/0AnDP86Iwr/KRcE/yR5ov8GeML/FYbF/xVBWP8AFDH/AQ0X/wwIAv8fGhD/',
    'MSUV/zcqF/82KRf/GA8C/wIcM/8AJlP/N2iN/0Wdyf8ga53/GVaB/wAaMP85SEz/fdju/2Tf//9o2vn/Y8Hi/2G/4f9x3fr/adj3/3Pl//9zvNr/Az91/wdH',
    'ef8ISX7/B0R2/wlKff8JUIj/DUJj/wIAAP8JBwT/DAkE/wwJA/8LCAP/BAIA/wAaMv8CHDT/GGqS/wlanf8NYp//Eio2/x4QAf8nHhD/JxcF/x4eFv8cWoL/',
    'EzA+/w0eKf8VNEv/GkRj/xhBX/8OKT3/ESc2/x4XCv8iHxX/Hx0V/yofD/8vHQr/NR8I/1QbAP/itmH//+d6/3IuB/85GwH/LxoG/ykXBv8nFwb/IRQF/xwS',
    'Bf8VDgX/DAcC/wEDBP8BGzH/ABMp/xFPcf8QTYL/EE6D/wQTHv8AAABoAAAAAAAAAAAAAAAAAAAAAAAAAEgGHS/uCjpp/w1HdP8INlf/ABw7/wEaMf8AAAD/',
    'CAcE/w4OC/8UFhP/FxYP/woZJv8FGSv/CiZB/wwpRf8LJT7/DChC/xE8YP8YR23/HEty/xlLc/8UQmf/FUFi/yNhjv8iXIj/HExx/xxUfv8XS3P/ETVS/xE3',
    'VP8LJTn/F0JZ/xlvo/8wIQv/SSoJ/0ArE/83GAD/LlNY/xiN0P8IesH/Inie/wIUKf8AGDD/BAMB/xQRC/8lHhT/MigY/yoeDv8JEhb/ACVS/zhkiP9UvOv/',
    'LJjS/yxwmf8fMzr/HhUI/w4EAP81NzP/f8XX/2ri//9i2fr/Zs/u/3PT8P9z3/z/aNn4/3np//9UjLH/ADxz/wtOgv8JSXv/CUZ3/whPh/8QWoj/AgcK/wYD',
    'AP8KCAT/CggE/wcDAP8CDBP/ABYy/xA5UP8Xdq7/B1eY/w9ajP8VEwz/IhcI/yMbDv8hEQD/GDI//xpVev8MHCL/ECg4/xMwQ/8TMkj/F0Ff/w8sP/8NKDr/',
    'Eic1/w4mNf8kHA//OigQ/zMiDf87JAv/TB8D/7B6Pv/CiEX/XiQD/0MnCv83IAn/MR8L/y4eC/8nGQn/HhQH/xUPBv8JBQD/AAUK/wEaMv8AFiv/FV6G/w5K',
    'f/8QTHz/AgYK7gAAAEgAAAAAAAAAAAAAAAAAAAAAAAAAJQQRG8sKO2n/Cz5r/wtCZv8AGzn/ASE+/wABA/8HBQL/DQsG/xESD/8VFA7/DxUW/wYcL/8GGiz/',
    'Bx8z/wsoQv8OME//Ejlc/xpLc/8bTnf/GEhw/xhHbP8VQWL/GEhu/xI8Xf8XRmv/FUBi/xhIcP8TO1v/EjhX/w0tSP8QKDX/IXit/yE5Q/9GIwH/PykQ/0An',
    'Cv8xJA//MpG9/weCy/8cl9T/Fj9V/wARLf8ADhv/CAQA/xcUDv8iHBL/Eg8I/wAWM/8xW3//VMr7/zms4P85ZXT/KyIS/ywYBP8rHg7/LSMT/xwTBP8fGBD/',
    'XY+d/3Tn//9q3Pr/ddjz/3fZ9P934/z/cdz2/3rO7P8WTH3/AkBz/wpPhf8ITYL/ClCI/xFhmf8IHy7/AwAA/wgHBf8HBQL/AgIC/wAVK/8CFCj/HWqP/w9p',
    'qP8NY6L/EDpS/xwOAP8jGg3/JBkK/x8UBP8WTHD/F0Nd/wwaIf8WNkv/GD5X/xc7VP8aQ2L/GUJf/xMwRf8RLUL/DSU2/x4cFf88JAr/OiUN/zUdBv89IQb/',
    'VyQA/1kjAP9DIgT/Nx4G/y0aB/8rGgf/JRYG/x8TBv8XDwX/EgwE/wYCAP8ACxT/ABgw/wMgNf8XY4//DkmA/w9FbP8AAADLAAEBJQAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAQQHpAs7Z/8LPW7/EU50/wAbNv8BI0P/AAcO/wQCAP8NCgb/Dw8L/xQXFP8VFRD/ERod/w8XGf8IHC7/CCZB/xI7Yv8UPGH/G013/xpIbv8VPFz/',
    'EzhX/w4yT/8TPWH/FT9j/w80U/8MKkT/Ejlb/xVFa/8MK0X/DSpA/w0fLv8jX4D/G2eS/zgcAP9KLxD/Ry8T/zcaAP89Y2b/HZzf/wiL0v8ukLj/CBcq/wAX',
    'Mf8BBAj/CggE/xANB/8ABRD/LFh+/1/R/P85krb/NDkx/zQeBP9GMhf/QjEZ/zEkEP8zJA//LiIR/yQbC/8UCQD/XYON/3rn//9s3/v/dNn0/3TL6v+C4Pj/',
    'fun+/2Wsyv8HRX3/B1CH/wdJff8ITIH/Dl2X/w0/XP8AAAD/BAUE/wIAAP8BDxv/AA4j/w8+Vf8Vca3/DWCf/xFfk/8VFA7/IxgI/yMZDP8hEwP/GCIk/xhW',
    'gP8QJzL/DyAr/xQxRf8aQFr/GkJe/xpBXv8bR2b/Hkdn/xxBXf8TL0P/ESk6/zIfC/9JKgr/PiEF/zoXAP9QKgj/QyUI/zYbBP8yGwb/MhwH/ykZB/8mFgb/',
    'HxMF/xcOBP8SCwP/AwEA/wASIP8AFS3/CDJJ/xRejP8OS4P/DTdV/wAAAKQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB7DTZZ/ws/cf8TVX7/AyI8/wAf',
    'Pv8ADx3/AgAA/woJBv8NCwb/ExEL/xMYF/8XHBj/FRUN/woZJf8GHzb/ETZa/xZEbf8XRm3/HE53/yRgjf8bS27/HlR8/xtLcv8hW4j/F0Fk/woqRf8PM1H/',
    'FkZt/w8zT/8XPlv/DSg+/xo4R/8mhbz/IC4w/0ooBf9ILxH/QyoN/zUkDf82lrv/Co3W/xmg3v8pZoH/AAsh/wEWKv8CAwL/AQAA/yBIZ/9UuN//M2Br/zcg',
    'Cf9CKxD/RDQc/0k5H/9BMRj/OyoT/zkpEv80JRH/MSUS/yUaCv8JFhz/UHJ+/4Xp//914Pv/c9by/3HM6/+D4/r/n/j//16YwP8AQXv/Ck6B/wtPhP8IT4f/',
    'E1WA/wEECP8AAAD/AAYL/wAPI/8GHCz/GW+d/wxbmv8Raqj/EzZI/yAQAP8hGQz/IhkL/xsPAP8WQ2H/F0dn/w0dI/8QJzX/ESo8/xM0S/8UOFP/ECxA/xQ1',
    'Tf8VM0r/FjRJ/w4kM/8QJTH/MCER/1gwCP9mLgT/iUgY/2oxBv9BIgT/Nx0F/zUeBv8xGwf/KxkH/yUWBv8fEwX/GA8F/w4IAf8BAgL/ARgr/wAQJv8PSmX/',
    'ElWI/xJSif8JJDX/AAAAewAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFAJJTz0Cz1v/xBRf/8JN1b/ABs5/wEYLf8AAAD/CAcE/w0LB/8RDgn/ExUT/xcc',
    'Gv8SFxb/CR8x/wolPv8RN1v/FD1j/xlKdP8cT3j/IFeD/yVhjf8qapn/IVV8/x9Xgf8fWob/DjFP/yBRd/8UO1v/G01z/xlDYv8SNE7/DSAt/y5ukv8eZZD/',
    'Nx4C/1Q3Ff9GMRX/NRsC/zVJRP8vqeT/B43S/ymq4P8fPE7/AA0l/wELFv8GGyn/JmmG/xklJP8lEgH/PS8b/0s4IP9LNx3/STUb/zgqFf9GMxr/SDUb/zkr',
    'Ff80JxP/MSEN/x8mIv8JCAP/WGdm/5Lv//9q3/3/b9b0/3za9v+H6fz/m+r5/yplk/8AQ3r/DE+B/wlLgP8RXpH/BBgk/wAAAv8BCxb/AQoV/xNXev8QYZ//',
    'DFqW/xNVff8SCgL/HxgM/yAZDP8hFAP/FSAj/xlahv8RKTX/DR8p/xEqO/8UNEr/ECo8/w8rP/8WOVL/Dyc3/xY3Tf8NJDT/ERkc/y8dCf83Igz/VSEB/69o',
    'J///9If/oGQn/0AaAP88IQj/Mx0H/y0aBv8lFgb/IxUG/x0RBf8XDwX/CwUA/wAGC/8BGTD/ABIl/xZegf8QTYT/FFOG/wMMEvQAAABQAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAIgMQGsULP3D/DUh5/xBMb/8AGDT/ASE9/wADBv8FAwH/DQsH/xEOCP8UFRL/FxcR/xAfKf8GIDf/DChB/xE1WP8TOmD/GUdx/x1P',
    'ev8fWIb/IVmF/yJbh/8oZZP/IlqE/xA6Wv8fU3n/I2GO/xhEZv8cS3D/G0pu/xc9Wv8OK0D/HDI+/ymFuf8jPEL/TSsI/0YwFf87KhL/HAoA/zBmev8isfL/',
    'EJvZ/z+y2f8SJjj/AA4p/wQfNP8AAAD/DAUA/xwbFf8lHxT/OCwa/0k4IP9MOyL/PzAZ/1E6Hf9LNhv/RTIY/zopFP87KxX/LSAO/ysjEv8YDQD/TV5f/4jj',
    '9/9t4f//atr4/3fb9v+L7v//js3k/wtHfv8FRnr/CEN0/wxakv8KMUf/AAAE/wAFDf8JOVL/DlmR/wxWlP8QW5D/CRAS/xMMBP8YEwv/HxYK/xgQBP8WR2r/',
    'F0hm/wwZHP8SLD3/FDFE/xc6Uf8XOlP/DSc3/xAsP/8XOlL/FzpR/w0pOv8XICP/MhoE/z8nEP9zJwD/6bhY//nicP+WSxT/QyAB/zYeB/8zHQf/KxkG/yYX',
    'B/8fFAf/GQ8E/xYOBf8FAgD/AA0Y/wAXLv8EITX/GWeR/w9JgP8TSnT/AAAAxQABASIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIDlA0+Z/8MRnz/',
    'FFiD/wEcNv8BI0X/AA4b/wIAAP8LCgf/Dw0I/xEQDP8WFxP/FxYQ/w0dKf8JJD3/Di9O/xE4Xv8VPWL/FD1g/xdIb/8aT3r/H1eC/yBVfv8gVX7/IFR8/yZk',
    'k/8nZZP/G0tw/xpLc/8aSGv/F0Vp/xM5Vv8LHy3/J114/x99sv8rHw7/SS4P/zEiDf8NCgb/BBAj/z+Ssv8luvX/H770/1rH4v8dMUj/AAgf/wMTI/8CAwT/',
    'CgcD/xQSDf8gHBP/Nisb/zgtG/9FNR7/Sjce/0c0HP9FMhr/QS8X/zUmE/83KRX/LCIS/yUfFP8SCgD/PUVE/4bW5v9p3///a9Ty/4XW7/+c8///Ypu8/wA6',
    'c/8LSn3/CVCJ/w5Kb/8AAAD/Ahwy/wk/aP8HP3D/D1eL/wgoP/8ABxD/DAgD/xgUDP8YDQD/FCw7/xtahf8OISv/DSAr/xUzRv8VNEn/G0Ng/x9Lbf8XOVL/',
    'FjZN/xpCX/8ZQFv/ESw+/xImNP89KBL/UigI/5RQG//+8H3/0JlK/2MjAP9AIwb/NB0H/zIeCv8tGgb/JxgH/xwSBv8XDgX/DwkC/wEBAf8BFSb/AA8l/w0+',
    'WP8YYpT/EU6G/w41Uf8AAACUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABgCyxH/wxEev8TWo3/By9N/wAcO/8BFy3/AAAA/wgHBP8NCwf/',
    'EA0I/xMWFP8bGhP/ExgW/wcgN/8PMlP/EDZa/xE4XP8UQGf/ETdX/xI6W/8XQmX/Gkpw/yBXgv8kXYn/I12I/yVgjf8XRmr/G011/xhEZv8XRGb/FT1d/w4t',
    'Rv8SIiv/MYe3/xpYdv8lEAD/GxEE/wMUI/8BJ07/ChYk/0amxP88zfv/QsPm/2rE2/8iLkH/AAsl/wIXLP8BBgz/BgMA/w8NCP8WEw3/GxcO/zInFv86LRn/',
    'Py8Z/z8uGf87Kxb/NigU/x8WCv8UDwf/IBoP/yAdFP8QCQH/JCYm/37A0f9/7v//cdPw/4Hb8/+g7v3/NWqX/wBDev8KToP/DVeI/wMRHP8AFir/BCpM/wxM',
    'ff8HIzT/AA4e/wEiP/8DBAT/EgsE/w8UFf8WTnf/FTdJ/wwbIv8UMUT/GDpS/xU1TP8bRGL/GkRg/xtHZ/8VNUv/FTFF/xEsPv8MIjH/ESQv/zclEP9NHgT/',
    'yZVN///0iP+PRxX/TyUD/zceB/8vGgb/LBkG/y4bCP8iFQb/GxAE/xcPBP8IBAD/AAUJ/wEbMf8ADyP/FVx9/xNUiv8VWI//Bxci/wAAAGAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACoFEx7LD0h8/w9PhP8QTnD/ABUx/wEdOf8AAgb/BQMB/wwLB/8NCwf/EhQR/xkaE/8NGyX/ByA2/w8wUv8RNlr/',
    'FD1j/w0vS/8QNVP/Dy5H/w8yTf8dUHj/I1yI/xpPdv8XQ2b/Gkty/xVEav8VRmv/Di5I/xExTP8XQGH/FDlV/wokNv8iPUr/KozC/wwpOv8GAAD/Ai1S/wAi',
    'R/8JJUT/I1V3/0+z0P8vwvD/QNj9/2zY7P84T2T/AAch/wAXMP8CEiD/AQMG/wQBAP8MCQT/ExAK/xgVDP8hGxD/KCAS/yshEv8hFAb/FC0z/wsbH/8QCQP/',
    'FRIM/xcVEP8KBgL/EBQV/2mZpP9/7f//bNHv/4vh9v+V1er/EFGJ/wRFef8OXZb/CStC/wAHEv8EKUn/ByxG/wYfMv8AGTD/AiJB/wEXKf8DAAD/Cy5K/xNB',
    'YP8LGR7/DyMw/xIrO/8aQFr/H0xt/x1GY/8aPVX/FDJF/xArPP8NJTT/ECQw/xIgKP8oHA3/QiQK/0QfA/+ESRv/oWAr/1MfAP9IKAn/NRwE/ysYBf8nFwb/',
    'IhUG/x8TBv8YDwT/EQsD/wMBAP8ADBf/ARcw/wQgNf8fcJr/E02E/xZRff8BAgLLAAABKgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAC',
    'ApEQRnD/DUZ9/xZhi/8CHTX/ABw6/wANG/8BAAD/CQgF/w0LBv8RExD/FhgU/w8dJ/8JIDT/CR8y/w4wUv8MLUz/DClA/xEtQ/8SMEn/ETVQ/w8yTv8cUnv/',
    'HFJ7/x9YhP8ZSW//DjFP/w0uSf8ZSXD/FkNn/wwoQP8NKD//ETNM/wobJ/8bRl7/CUBp/wAZL/8AKlj/FTVc/z2ey/8Der7/D05//17B3f9O4///S9z6/3Xq',
    '/f9Zhpr/Dhoz/wALJv8AGTL/AhIh/wEGC/8DAgD/BwMA/woHAv8NCgX/EQ8J/wYAAP8eX3z/DStB/wIAAP8LCgb/CQcD/wkIBP8CAAD/AAAA/0Zsef9/6P//',
    'bNLz/5Xr//9urMz/AER9/w9Yj/8LQWb/AAgU/wIVJf8AESL/EEty/x9TcP8AGTT/AiZF/wANGf8HIzr/BhIY/wgTGf8PIy//Ey9C/xc8VP8cQ1//GkBa/xEr',
    'PP8PJzf/GSIj/xsuNv8tHw7/NBoD/0AjB/9NKAX/SCQE/0UfAP9IHgD/QiMF/0AlCf8tGwf/KhkI/yoZB/8gFAb/HBIG/xQNBf8LBgH/AAIC/wEXKf8ADiT/',
    'D0Rc/x5rnv8VVpD/EDdS/wAAAJEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAVQwtRvQPSoP/E1mK/ww5Vf8AFDH/ARs0/wAB',
    'Av8FBAL/DQsH/w8OCf8VGBb/GRoU/w8YHf8HIjv/CB8z/wglPv8VJS7/HxwR/xYYE/8VLj7/DTRT/xdIb/8bT3j/JWGO/yRgjf8RM07/GUlt/x1Ref8cVID/',
    'ETVW/wonQP8NKT//Ch8v/wMMEf8FHjD/AC1c/xc5ZP9TtNn/G7n4/wyO0/8KXIv/GiMr/2Khq/9t8f//VOD6/3Xx//93ydr/Ol1y/wkcOP8AES//ABYx/wAW',
    'Kf8BEBz/AgkO/wIFB/8CAQH/AA8T/yWEsv8QL03/AAED/wIDA/8BBQj/AQgP/wENGP8ADRv/AAAA/zNMWf+D3vX/f+P9/6Xv/f9Ggav/AEJ7/w9Yif8CCg//',
    'AQUK/wQoQ/8HO2T/KHqt/zVngv8AFzL/Ah00/wEFCP8DCAr/CBQc/w4jL/8VNEf/FzpS/xs+Vv8ZOU//EjFE/xsoLf8uGQL/NiEK/0QkB/9PKgj/WyoF/3Mv',
    'B/9jKAL/VSwH/0oqC/9BJQr/PCML/zkkC/8vHgr/KBsL/yAWCf8ZEQf/EQwF/wYCAP8ACRH/ARsz/wAQJP8caIr/FVWN/xtimP8GFB70AAAAVQAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAXAwwStRJNgf8QT4b/FFh//wAVL/8BHz7/AAoU/wIBAP8KCQb/DgwI/xMTD/8ZGhb/GRsV/xAb',
    'IP8PJjj/DCY9/x4cFP8pKiH/HCMg/xEuQv8PN1f/HFeF/xlNd/8cUHn/JGGP/yBYgv8mYpD/IVZ9/xlLc/8ROVv/CiU8/wwmOv8IHS7/AwoN/wAbOf8YPmv/',
    'Xb/i/y/P//8flMD/IEZR/y4fC/8/Kg7/MyAJ/1d7e/+G6vj/au7//2Dr//9p5///X7/a/z1vh/8aLkP/AhAm/wAMJP8ADyj/ABEp/wAJF/8ANlb/MqHV/xUy',
    'T/8ACx//AAwc/wANIf8ACh3/AAcX/wUTIP8JKD3/ABs9/yxNZf+F2Oj/jvL//53d8P8fXZH/B1aP/wokMv8GAAD/Cw8Q/xM5T/8VYJH/MJ3Y/zVmgv8AFzL/',
    'AgsT/wMEBP8IExj/ECUz/xg6Uf8YOlD/Hkdj/xg3TP8OKjz/Jh8V/0QjBf9JLhT/QiAE/1cfAP+bShj/9d11/6luKv9IGwD/OyAH/zMbBf8zHgj/KhkH/yYX',
    'B/8iFQf/GhEG/xQOBf8MCAL/AQEB/wEUI/8AEyn/CS5E/yNyoP8UU43/F1R7/wAAALUAAQIXAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAABzED9j/w9Mh/8XYZD/CC9K/wAbOv8BFy7/AAAA/wYFA/8LCgb/EBAM/xQYF/8bHRf/IB0R/x0dFf8bHRn/ISEa/yQkG/8aJij/Ez1f/xE4',
    'WP8aTXf/FkRo/xZKc/8eWIb/G01z/yZmlf8mZ5f/HE10/wwrRv8VPV3/Dy9K/wYQF/8ABxL/FT9u/13F6/87yvH/HHWg/w0WGf8wEQD/Sjca/1I9HP9XQR//',
    'SjAN/1ZPQf9/trr/ePD//1bd+v9EzvL/U+X//1nL6/8/hqj/MWmC/yBDWP8SLUP/ChYk/wUoQf8/p9D/EytD/wYQIf8NHCj/Eig3/xU8UP8iYX3/HnSi/w1l',
    'of8FRnz/ACBH/xlBX/96x9v/o/7//4K0zv8ES4j/D0Bf/wUAAP8RDAX/DQMA/wsqOv8Xapj/Qa/l/zxvjf8AECX/AwcH/wYND/8KFh3/Ey5A/xg8VP8YOlH/',
    'FS4+/xAnNf8gHhf/Qh4A/1EqCf9bJwL/kDMG/+vCZP//8nv/nlYc/1AkAf88IQj/MRsG/zcgCf8qGQf/JRcI/x8UB/8aEQb/Ew0F/wgEAP8ABgv/ARsx/wAM',
    'If8cX3z/G1+U/xtimf8MKTv/AAAAcwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAC8HGibLFVuV/xJVjf8YWHj/',
    'ABQv/wEhQP8ACRP/AQAA/wgHBf8NCwf/Dw4K/xQWEv8bHRn/HyEb/yAiHP8cIR//ICgn/xwkIv8TN1L/DS5J/w4zUP8NMlD/DzZV/xlNdP8YRmr/IVuH/yVl',
    'lP8lYpD/Ez1g/xtMc/8SNE7/AAwY/xIzVf9fvOD/OZaw/xElLv8aWYH/Go3G/x0sK/9DJQb/Xkch/1tEIf9mTyj/XEEZ/1Q5F/9jZlj/cq62/13W9f9D2///',
    'LtD//yrJ/f8yy/3/O8Ty/zWy4P8yocz/Jo24/0+kxf8kYYD/KpK+/y2Xxv8qoNn/I5zY/xiT1f8PfcL/EXK1/xhpo/8XTHT/Bh0w/xYXGv93rLn/sv///1KL',
    'tP8AQ3b/CQsL/wkFA/8LJzz/DT9l/wsbJP8YP0v/SqTJ/z5ykf8ADhv/ChQW/w8gKv8QIy//Dh4q/xUyRP8WNUr/ESUx/w0dJf8iHBT/MyYZ/1keBf/Yn0n/',
    '//+H/8J6O/9oIAD/SigG/z8kCv8xHAf/NyIL/ysaCP8kFgf/HBIG/xYOBf8NCQP/AgAA/wERIP8BFiz/AyA1/yR4o/8VU4v/HmKP/wEEBssAAAEvAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIQVS3T/EVKQ/x5rmf8HK0X/ABw8/wEcNP8AAAH/BQQC/woJBf8NCwf/',
    'EA8K/xQUD/8VFxX/GRkV/xkYEv8gJyT/JCcf/yIiGv8RMUv/FDdS/xcpMv8TMkv/ETVS/w4vSv8WRmv/ImOU/x9Xgv8YQ2b/HU52/xI8Xf8eQGH/XJm2/yde',
    'c/8MITX/CSAw/xQpM/8+iqn/P8Ht/yxSXP9AIQf/akwe/3BWKv9xViv/blUr/2VJHf9ZOhX/XlQ//1+Fif9XsMr/SMbv/zrI+/8ww/v/Jb78/xqz9f8WrvT/',
    'JaXi/yGi3/8ZrfH/F5vg/xuX3f8gnN//IpPS/yqGuP8oY4X/IjtH/xsaEv8bFAf/FBAH/w8IBf9ulp7/s/f//yVsov8AFCP/AQ8b/xZLcf8XNkP/DRYT/wwQ',
    'DP8QGhn/R3mI/0Bme/8RIyz/GjI+/xgzRP8QIi3/Dh4p/xMpN/8cNkX/GCoy/xYmLf8YJCn/Zjgg///efP/jrVj/ayMD/zkiDP8nGQj/NB0H/zQdB/8uHAj/',
    'KRgG/yEUBv8XDwX/EgwE/wYDAP8ABQn/ARsw/wAMIf8ZVXD/Hmid/xpdlf8VO1T/AAAAhAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAOgkeLtMYXpf/FVuU/xlZev8AEy7/ASRD/wALFv8BAAD/CAcE/w4NCv8TEg7/FRQO/xcVEP8aGRP/GRkU/x4eGP8mLCf/',
    'Kish/yQmH/8gJSD/IiYe/xoiIv8SO13/DS9K/w4wTf8VQmb/HFB6/yJah/8fVoD/Hkxx/ztfd/8fSWf/EDNR/xM3T/8TNUz/EDFI/xEhLv9BdYr/VNX4/zyP',
    'pf8yLCH/Xj0V/4BiLf93XS3/eV8x/25VKv9nSx7/VTQM/1A0Ff9LRTT/TGBd/0l1gf87eJD/NIep/zKRuf8tkr//LZC8/zGKsP8yfJz/J112/x9GWP8oOzz/',
    'JiQY/yUYBv8kGAf/JyAS/yAcEv8dGhL/GRcO/w4BAP9cc3P/jdDs/wYvT/8CEx//DBwh/w8XFP8SISL/EyIj/xMiJP8NGBj/MERI/yo9R/8bMz//GDE//xct',
    'O/8bM0H/ITlH/yY7R/8jN0D/ITE3/yIqK/84KyT/e0wv/3NDJv9AMyT/ISYh/x4XC/8yGgP/MR0H/ykZBv8jFQX/HBEF/xQNBP8MCAL/AQAA/wERH/8BFi3/',
    'BSAz/yt8pP8UUYv/IGeZ/wQLD9MAAAE6AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAhhtV',
    'ff8SVI//H2+b/wgrRP8AGDb/ARw1/wABAv8CAgH/CgoH/xAQDP8SEQz/FhQQ/xgXE/8ZGRX/GxoT/xgbF/8iKCX/KS0m/yUqJf8lKCH/IS8y/xcxP/8SHyH/',
    'DixE/wonQP8aTXb/H1eE/yRcif8iWIL/Gk51/xpLcf8WPVn/EjRN/xY8WP8VNkv/EzpQ/w0qQP8qS13/V73V/1zO6f89anX/RDMd/2tIGP+FYyv/fmAu/3Va',
    'L/9pUSr/XkYh/001Ff89IgP/GRkS/wk+Xv8KFyH/BwUL/wQIE/8ICQ7/BggN/wEGD/8ADiH/CAQB/x8RAf8rIRH/MCka/y8pHP8tJxr/KiMW/yQZCv8ZDwT/',
    'EiIo/wAYMv9ScIH/YIWd/wQND/8PFxT/Dxwd/xYoK/8VJSf/FCUq/xkvN/8WJi3/HCkv/xsrMv8aLjj/GjE//yI5Rv8mNz//Jior/1E6Mv9bKxr/PSIX/yQn',
    'Jv8fJCT/JCwr/x0lI/8UHR7/FRsb/y0YAv80Hwj/JhcH/xwQA/8VDQP/DwoD/wQBAP8ABw3/Ahow/wAJHf8eWXL/Im2i/xhemv8UQFv/AAAAhgAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA4DCIwzRxlnv8XXpf/IWGB/wAQKv8BI0L/ABAe/wAA',
    'AP8GBgP/CgoH/w8PC/8TEg//FBQR/xgYFP8ZGRP/Gx0X/yEfFf8jIhj/ISEY/yUqJv8jLSr/HDA6/xUiJP8UNEn/DTBP/xpMdf8fVoP/IVmF/yNeiv8jXIj/',
    'HUxx/x1ReP8dTXP/EjRN/xU/XP8cSmn/GkZj/xE1UP8YM0z/R36T/27X7/9jx97/Q215/0Q6KP9fPBL/bEgZ/3BSJf9qTyb/XEYl/0c2Hv8uJxf/Em6g/w56',
    'uf8adZ3/GUJa/wMeN/8AKk//AChN/wEkQv8UEgz/JSAV/ywnGv8yKxz/MScV/ycaCP8eFgr/Gy81/x9aff8hZ5f/HEto/wAQF/8yPT7/Hi8z/xAiJf8VKS//',
    'FCUq/xgsM/8YKzH/GCkx/x8nLP8vGRP/KBgS/xoiJ/8aKTH/IjE5/ycqKf9WIhP/vWYw/+2/W/+JRh7/MCMc/yIdFf8eHhj/FSIk/xQWE/8gFAb/MRsE/ykY',
    'Bf8jFQX/FgwC/xEKAv8HBQH/AAEC/wEUJP8BFCr/BiAy/y6Cq/8UVJH/IWud/wQLD80AAQE4AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB7GE91/xRZl/8mdaT/DjVP/wAWMv8BID3/AAQJ/wIBAP8JCAX/DQwI/xEQDP8UEw//FRUR/xYV',
    'EP8fHxj/IB8V/yIgF/8iHhX/HiMg/yEtLf8dKy//Fh8g/w8sQP8LME//Fkdv/yBaiP8gWYb/IVmG/x5Pdv8fVX7/JWGP/yNbhv8dTXH/HE1y/xpHav8VQWL/',
    'HlF3/xlKbv8QO2D/JE1u/1KMof9z0u3/Xcfn/z6JoP80TlD/QzUg/08wDf9LLQv/SDEU/zAYAP8UTGb/E5Hb/xaj4v9RyPL/HVaG/wAkTP8BKVH/Ahsv/xUK',
    'AP8kGgv/JBYG/yUaCv8iKCT/I0la/ytxmf80h7j/KmmM/xgxOv8RHh7/FCUo/w0fJP8TJi3/Fy45/xgxPf8VKTP/FCUs/xgoLv8aJSn/KxYQ/5VAHP98MRP/',
    'JRQP/yAgIf8pJyX/ViIW/7dhLf/85W3//ON0/5BOKf9BGQH/OxoA/zAXAv8XFxL/HQ8B/zQbA/8wHQn/IBED/yETBP8UDAL/CwcC/wEAAP8AChL/ARov/wAK',
    'Hf8iYXv/IWyj/x9qpf8YQFb/AAAAewAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAACcHFR26HGOZ/xRZlf8jbpH/ABUu/wEfPf8AFiv/AAAA/wQEAv8KCQb/DQwJ/xERDf8UFBD/FBQQ/x0dF/8fHRT/IR4V/ycjF/8kKyf/FiIl/xQi',
    'J/8QGBn/CSI4/xI8Yf8XRW//FD9h/x9bif8WQmb/IViC/yRgjf8jX4v/IluG/ydllP8mYo//HExw/yVij/8jYIz/I1yH/yJbhv8XSW7/EDxh/yNNcP9CdpL/',
    'WK3M/1jH7f9Fs9v/Noio/ytgdf8lQUj/ERYV/xE1Qv8WjM//FZjT/03D7P8ZUYD/ACtZ/wEqU/8DEx//CxIV/xcxPf8kVnD/K3Oe/zCGuP85hrD/L2F7/xsy',
    'Of8RHyP/Dx8k/xMqNP8TKTP/GDI//xgzQf8XMD3/GTA8/xcsN/8TISb/Fhka/yAaFv9dEAT/87k8/9KELf9IBwD/KBQH/zkVDf+6bjP///Rq//bWZv+YRxv/',
    'WR4B/0gfAf82GQL/MBcC/zkdBP8yGwX/LhsI/yUXCP8cDwL/HBEE/w4IAf8EAgD/AAMH/wEXKv8ADyP/DS9C/zGGsv8YWpf/J22Z/wMGCLoAAQInAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGMXRGH0Fl6d/yNxpP8bTWj/',
    'AA8q/wIkQf8ADhv/AAAA/wUFA/8LCgf/Dg0J/xERDf8TEw//GBkT/x8cE/8eGhH/JiIW/yYgEv8UKDX/CCY//wgeMf8LKkb/EDdc/xRCbf8UQGf/DzVU/xlO',
    'eP8lY5P/JGOR/yBah/8lZZX/IFiC/x9Vff8jWoL/J2SR/yptnf8nY5D/JV2I/xxPdv8fXYn/G1R9/xdJcf8YOln/JkZf/zZphP9Bj7D/Q6LK/zSgzv8kkcv/',
    'EVmE/xp/s/8XouL/ScLs/xhWiP8ALV7/ASZH/wQhOP8XV4T/I2qY/y1wlv8wYHn/HzlD/xYmKP8TJy3/FS88/xg3SP8WMkD/FjJB/xUtO/8XM0P/GTNC/xct',
    'Of8TIyv/EyMq/xQbH/8bEwr/NQIA/8FwJ//6oQ//9Jwa/4wyEf80CgD/Qg8D/795Of/rxFn/jjwW/00eB/9BGAH/PRoC/zocA/81GgX/PyAF/zAaBf8eEQT/',
    'IhUI/xwPAv8UDAP/CAQB/wAAAP8BEB7/ARkv/wAMHv8vepj/IGag/yJxq/8RL0H0AAAAYwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQECCgMIDJkiZ5j/F2Cf/yx7pP8JKEH/ABo3/wEiPv8ABQr/AQAA/wYGBP8KCQb/',
    'EA8L/xIRDP8UEw7/FxQN/xsXD/8mIBP/HhsQ/w8jMv8HJD//CylH/w8xU/8SO2L/G1B+/xNBaf8TQWn/Fkdw/x5Vf/8hXoz/IFqH/x5Vfv8jW4X/H1iC/yty',
    'pP8hWYL/Hk91/yRhjf8nZ5b/HVF2/yNgjP8gWob/JGGO/yBch/8ZS3H/F0Jm/xY6WP8VLD7/HDhK/yBEWP8SMkP/H3We/xej5P9Gvej/F1OE/wAuXP8BJUL/',
    'BxYc/xUuN/8WKy//ER8h/w8gJP8SKjT/GDpO/xs9Uv8VNET/FzdJ/x9CWP8hRVr/Hj1O/xEjK/8UJi//FCIp/xMbIP8TExL/GhQN/zEAAP+SQRv//6ge/6Ed',
    'AP/GRwL/4ogf/2gKA/9UFgH/UxgF/1wfC/9EHgv/TCII/0YaAP9FHgL/PhwD/zMYA/8pFAP/KBUE/yERA/8dDwL/Fw0C/w4JAv8BAAD/AAoT/wIbL/8ACRv/',
    'HExh/zGFuf8eZqP/I2KH/wAAAJkBAgIKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAPQwmNsseban/G2qm/y51k/8AEiz/AR88/wAbM/8AAQH/AgIB/wcGBP8MCwf/EA4K/xYVD/8VEgv/FxUP/ykiFP8eIBv/',
    'CCI6/wkkPf8NMlX/DzNX/xE5X/8PNVj/FUNu/xdJdv8aUYH/GEdv/xpNdP8iW4j/HU52/xQ6Wv8XR23/HlR8/yBVff8gU3z/I16L/yJchv8gWIH/Jmuc/yRi',
    'kP8kXIb/JWKO/yFbhf8dUHb/HVJ4/xlKbf8VPl3/DyxC/woYJP8aUWr/HKPk/0q75v8XUoL/AC9c/wIbLP8JEQ//DyIo/xMrNv8UMD3/FDA+/xk8T/8dQlv/',
    'ECQy/xEqOP8iR1z/JENU/yhCTv8nP0n/Gycr/xsiJP8cHBr/IRgT/ygLAv82AAD/lU4f//y2J/+yMQD/hT4b/3AZBv/caQv/134j/1QAAP8qDgL/MhID/z4V',
    'Av9KGgH/UR8B/0QbAf88GQH/MhQB/ycRAv8kEgP/HA4C/xMJAf8QCAH/AwEA/wAFCf8CGi3/ARIm/wskNP9Blb3/G2Ge/y59r/8KGSDLAAAAPQAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAaxlN',
    'bfccaqj/K360/x9Ubf8ADin/AiNB/wASIv8AAAD/AwMC/wgHBf8MCwf/ExEM/xQRCv8TEQr/IR0U/yceD/8TISr/Bx4z/wgeM/8MLEr/CSdE/w83Xv8TQWz/',
    'Ez9p/xlLeP8cUH3/Gkly/xAyUP8YRmz/FEFm/wwvT/8TO13/DS9N/xA2Vf8dU37/F0ds/xlJbv8jYI3/I2GO/yRgi/8paJb/KGqZ/yBYgv8eUHf/HFB3/xhC',
    'Yv8ZPlr/ES1E/xQ0Q/8hn9b/VcXu/xdKd/8ALVn/BBYg/w4eI/8SKzf/FC8+/xc4TP8ZO1D/FDBB/xQzRv8RKjr/Jkti/yZHWP8tQ0v/OkVJ/z03Nv89KiL/',
    'OxkM/00WB/9gFQf/fzgY/7d0Iv/4oCH/zD4A/34pCv/qszP/hTQL/2AMAP/rexP/tmkg/04FA/8tBQD/LA8B/zURAf9DGAH/PhgB/zkYAv80FgL/KRIB/x0O',
    'Af8WCwH/FAoB/wYDAP8AAQP/AhUk/wIbL/8ADyH/N4Ce/yd1r/8oda7/G0JX9wAAAGsAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAQIKAwgLlCRrmf8XZqf/M4aw/xEzSf8AES7/ASJB/wAM',
    'Gf8AAAD/BAQD/wgHBP8ODAn/Eg8J/xMQCv8YFQ7/JRwO/yIZC/8PHSf/CBoo/wcfM/8IIz3/EDdf/xI8Zv8ROmL/F0Vx/xtOe/8iW4z/GEp1/xE0U/8WS3T/',
    'DCtH/xY9X/8UPmH/ETtg/w4xT/8LLUn/HVN8/ytwov8mZZP/I2ST/yZnlv8qbp7/K26e/yttnP8iVn7/IFF2/xtIav8VOlb/ESc3/xl/r/9QxPH/GUt4/wAi',
    'RP8HExf/ESw8/xIyRv8PJjX/Ei0+/xIsO/8TLj7/H0lj/xQvPP8oRlP/O1pn/19XUP+jcD3/uHY3/7ZnL//AcTX/04c2/+WoOP/8tif//4UI/8grAP98Gg3/',
    '3qsZ//KzJf+YMQ3/ZyIB/3YLAP/wdg7/148j/4AvE/9XCQD/SwoA/0wXAP9EGAD/NxUB/y0SAf8jDwH/GAsB/xYKAf8IBAH/AAAA/wISH/8CHTH/AAkb/yhd',
    'c/85lMr/IW2o/ytoiv8BAQGUAQIDCgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAvDSIutyZ3rv8YYJv/MH6g/wUdNf8AGTb/AR87/wAHDv8AAAD/BAQC/woKB/8ODQn/EQ4J/xEP',
    'Cf8bFw//Jx0P/x4bFP8VFhP/FBse/woiN/8JJUH/DzNY/xA2Xf8SPmj/FkRu/xdIdP8dT3z/HlJ+/xE4Wv8SOlz/Dy5J/xhLdP8fWYr/FD5i/w40Vf8ROVn/',
    'GlB6/xxPdv8YSnD/GlF8/xdIb/8fU3v/IlmC/yBVfP8jWoL/HVJ6/xtIbP8RKDn/FWCG/03E8/8YRG7/ABQt/wwaIf8PKTr/FDhQ/w4pO/8UMkf/GTpS/x5G',
    'X/8lUm3/GzhG/y5LVv9DX2n/ZFdP/818Pv//2mP//+lP///UL///wxr//pYE//lhAP/cOQD/eRUA/8iTG///zQ3/6rEv/5ctDf+WKAD/TRMA/4MSAP/uZAT/',
    '85Ug/9N8Jv+rUh3/dyQF/04ZAP81FAH/JA4A/xsLAP8ZCwH/DAYB/wAAAP8EDxj/BB81/wAOIv8YO03/RpzH/yFwrv80hbX/CRMZtwAAAC8AAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAABQGEFY1iBvrP8ZZJ7/LnSR/wEULf8BGzj/ABs2/wAFCv8AAAD/BQUE/woIBf8NCgb/EQ4I/xIQCv8bFg7/JRwM/yAdE/8YGxf/DB4t/wkj',
    'PP8MLE3/EDJV/xE6Y/8SPWb/FD5n/xdEbP8eVIP/HlJ//x5Ug/8aSXP/FUFl/yBcjP8VQmj/FkBj/xE5XP8ML03/EDRT/xI3Vv8VRGr/GEt1/xdEZ/8SN1X/',
    'IVd+/yNbhv8eVH7/Gkpu/xUySv8QRF7/S7/s/xlDaf8ADyD/Eig1/xMxRv8aRGP/FTlR/x1LbP8cRF//IU1o/x0+U/8RIyn/KktZ/zBESf8/S03/Z0g7/69d',
    'Lv/xtUX//ccc//uQAP/1ZAD/9VoC/8ExAv/Mk0X//9I+//7GJv/uuDP/lCgM/48vD/+PQRD/dCME/7EYAP/sWQD//8ow/9qRPv9/Jgn/RxYB/zESAf8iDQD/',
    'HQwA/w8GAf8AAAD/BQ0T/wUdMP8BEyb/CSI0/0GSuv8kdbH/NIvB/xY0Q9YAAABQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABrIFt+7htmpP8oea//',
    'KGN9/wAMJv8CHjr/ABoy/wADB/8AAAD/BgUD/woIBf8OCwf/EA0I/xQPCf8bFQv/Ih4V/xgWD/8KGib/CB40/wwqSv8JJUD/CCI7/wwqSP8SOmH/FEBp/xlI',
    'c/8aSnb/GEp2/x5Xhv8WQGP/GEZt/xZDZ/8iW4b/GlB7/w4vTf8PMlD/CihE/xM9Xv8lZZf/EDRS/yBXfv8qapf/JmOQ/yBWgP8cS2//FztW/wwuQf9GqNP/',
    'GEFj/wESHv8bP1j/G0Je/xEsQP8iT3D/H1Bz/x5Ob/8YOlD/HD9T/x89Tf8iQ1P/N0NF/zxBPv8/SEf/WklA/5FGKP/chjb/+LIo//6TC//5YgL/xSoB/9SZ',
    'Zf/+/Kj//PPJ//fpy//coUf/7Jcj/8VhEf+RKAP/6GwM/+CQJv+bPhn/aw8A/1IYAP80EgD/Jg4A/yINAP8RBwH/AAAA/wYLD/8HHS7/Ahgs/wQUJP9Iiqn/',
    'LIC8/zCFwP8oWHLuAAAAawAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADCAqBKG+Z/xdiov8vhrj/JFZu/wAKI/8CIDv/ARs0/wADB/8BAAD/',
    'BgUD/wkHBP8MCgb/Dw0I/w4NCP8dFw3/HRYK/wwaJv8FGS3/BRcp/wcXJv8KIzr/Bx82/wggN/8NK0j/E0Bp/xVDbv8ZSHT/Gk99/xxUgv8RN1f/Ez9j/yNk',
    'lf8hW4n/FT9j/w40Vf8SOVn/Gkpv/xE2VP8OMEz/IlmC/yNeif8bTHH/G0tx/x1Pd/8aRmf/DixB/0SVt/8XPFn/CB0r/x1Jaf8iVnr/GD1X/yBMbv8dSmr/',
    'HEhp/xpBXP8cQVP/KFNr/yRJXP8oS13/MENI/zNBRP83QUL/TEQ7/3w8JP+qTCL/1nQW/911Bf/bRwD/wjoQ//ffg//996r//Pjq///QQv/1fgr/njQD/7VA',
    'Af+0Uwr/dBUC/1ALAP9BFQH/PRUA/ykOAP8lDQD/EwcB/wAAAP8HCg3/CR0u/wMaLv8ADR3/R4CZ/zmPxv8rg8D/N3OW/wEBAYEAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABIIFRuRK3us/xpwsP81lcX/Hkti/wAOKf8CIT3/ABgw/wACBv8AAAD/BQQC/wkHBP8NCgb/DwwI/xYTDP8cFw3/',
    'HBQH/xEUFP8FGy//FhcT/xcbGf8MGSL/Cx4u/wggN/8NLUz/ETZZ/xM9ZP8UO17/GEZu/xZBZf8SNlb/HVN9/yZikf8UPF7/DjVX/xpMc/8gXIr/HFF7/xdE',
    'aP8UPl7/ETZT/xM9Xv8SOlr/FkRo/xpHav8KJTz/RX+U/xw/Vf8MJjj/G0dn/xtIaP8ZRWT/GEFg/x5Jaf8YPFT/FjlQ/xpBV/8gQ1T/HThE/xkvOP8nPUf/',
    'Jjg+/yw9Q/8qMjT/PDk1/1s6K/90Kxf/giYI/4YpAv+EFQD/xoZV////k//57b///bMw/9ZnB/91IgP/fBoA/18PAP9QFQD/RhYB/zkTAP8qDwD/IQsA/xIG',
    'AP8AAAD/CAsP/wocLP8EGy3/AAwc/0Nyh/9Gnc//K4K//z6Frf8GCw6RAAEBEgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AB8OIy6cL4e8/xx2t/85l8T/GkJY/wALJP8CIDv/ABkx/wAECP8AAAD/BAQC/wkHBP8NCwf/EQ8L/xESD/8aGRL/HRUJ/xsWDP8eHBT/GhsW/x4XCv8XGxr/',
    'CSI4/wwsSP8RNFT/ETZX/xM9Y/8SNFP/EDVU/xlJc/8SM1D/HleE/xA1VP8TPF3/HlN8/xhFaP8UPFv/ETZU/w4tRv8PMEv/EjtZ/xVDZf8OL0n/EzdS/w0z',
    'UP86XnD/Iz1M/xVAX/8YP1r/EjNJ/xhDYf8VOVT/FjtV/xpIZ/8aRF//FjdN/xUuPf8eQVP/HjpJ/yA4RP8gN0D/IjhD/yU4Qf8kLjL/MTEw/zw7OP9PLSD/',
    'VxwJ/2MgCv+DKxP/89+G//zvqP//oSP/mUkG/2QRAP9vHAD/VhgA/0UUAP82EQD/KxAB/ycOAP8PBQH/AAAA/wkLDv8LHS3/BRwv/wAIGP9Ca4D/Tqja/yqF',
    'wv9Ekr//DBccnAAAAB8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACcTLTyiMYvC/x16u/86mcb/Hkdc/wAL',
    'JP8CIDv/ABo0/wAHDv8AAAD/AwMB/wgHA/8KCQb/CwkE/xIRDf8XFQ//HhgN/xkZE/8XHR7/GxwW/xYZFf8IHzP/Di5N/xE3W/8UOV3/FDxg/xM+ZP8UPF7/',
    'GUZt/xtIbv8SNVP/DzBM/xpJbv8aS3L/EjVR/xEyTv8VL0P/GENk/xQzSv8bGxP/Hicn/xg6UP8OKT3/F0Vo/yFJZ/8gSGP/HU1x/yFQdP8ZP1v/ES5E/x9T',
    'eP8ZQ2L/HUtr/x1IZP8iUXP/G0BY/xo6Tv8aNUP/GzRA/yJAT/8eND7/FyUq/xooLf8bJyr/Iygp/yYfG/88KSD/Yjol/2gMAP/Ah1T///Wb/+qIGf9rIgL/',
    'cRYA/1cWAP9HFAD/NBAA/ycMAP8fCwD/DAQA/wAAAP8PERP/ECIy/wIYKv8ADBz/Q22B/1Cp2f8sisf/S57L/xIhKqIAAAAnAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACoWMkCiNZLJ/yODw/9Bo87/I05i/wALI/8CHjv/AB06/wAMGP8AAAD/AgEB/wUF',
    'A/8IBwT/CwkF/w8NCf8QDwv/EQ4J/xcXE/8YGhT/Dhwl/wYgOP8JIDf/DzBR/xE1V/8SNlj/ETVU/xY8XP8cTHT/HU53/xlCZv8dS3D/HEpw/xAxTP8SNlL/',
    'Hiwy/yYeD/8eKi3/ICMd/ycmHP8jHhH/Ex8j/xAyTP8TNE7/FTxa/xlGZ/8bRmb/G0dn/xlAXP8dSWr/H1B0/yBOcf8dRmX/GkJe/x9Pb/8bQVv/GDVI/xg0',
    'Rf8cO0z/Fy04/xQkK/8oMTP/Lywn/y8fFv8hJST/Iikr/zcmHf9JGwn/aRQA/5QzF//93ob/sWER/2ANAP9iGQH/QBAA/zINAP8wDgD/JgwA/wgCAP8BAAD/',
    'ERUZ/xEkNP8GHjL/AA4f/0x0if9Rq93/MJHN/0qh0f8WKjSiAAAAKgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAACcVMD6cNZHG/yGGyP8/otL/K1tx/wALI/8BHDj/ASFA/wAQIP8AAAD/AQAA/wQEA/8HBwT/CgkE/w4MB/8QDQf/FBMN/xgW',
    'Dv8UEw7/ChQb/wcdL/8HHTH/CiI5/xE3Wf8QMU3/FTlX/xY9Xv8XQGX/GEVr/xhBY/8YQWP/ETJN/xMpOP8oIxT/KDEv/yEgF/8jKCP/Jy8s/yYlGv8VJS//',
    'ETFI/w8sQf8OK0H/ETBH/xc/XP8QLUH/FjpV/xtFZP8ZQmD/HEdo/x5LbP8YP1v/Gj9a/xs9Vv8bQFn/FzJE/xUtPP8PISr/Hiku/z4cCP8+FQD/QxQA/z4X',
    'Av80HBD/RxUB/2AcAP9iHAH/cxAA/8yJXf+HOxX/WwwA/0QSAf80DgD/MA4A/x8JAf8DAAD/BAME/xUdI/8OJTj/ABYq/wMSI/9QgZv/UrDh/zCV0P9QptL/',
    'GCo0nAAAACcAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB8ULDmR',
    'OpXH/yGJy/84odb/Mm2I/wEQKP8AGDT/ASJB/wAXLP8AAwf/AAAA/wIDAv8GBgP/CQgE/w0LBv8QDQj/ExMP/xgVDP8REAv/Bxst/wYXJ/8HHC7/CSAz/wwm',
    'Pf8LJz3/CiM4/w8tRf8RM07/DClB/xAtRP8OKj//DixD/x4gG/8jIBT/HR0W/yEnIv8jIRf/Kikd/yIiGP8ZGxb/HB4X/xEsQP8OKTz/Dyo//xEvRf8QLkT/',
    'Dys+/xU3UP8YP1z/GD5a/xU2Tv8WOVH/FzdO/xg3Tv8UL0H/DB0n/xMlLv8sGg7/PhYA/0EeBv8+FgH/SRkA/0sXAP9IFwD/XyEB/0kUAP9XFQD/bB8J/10Y',
    'Bf9CDwD/Nw8A/zAOAP8TBQD/AAAA/wkKC/8WISz/CyQ4/wATJ/8LHjD/V42p/0uq3v80mtX/TZ7I/xUmL5EAAAAfAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABIPIiyBNo697iWR0/82odr/PIKi/wgdNv8ADyn/',
    'AiE9/wAdOP8AChT/AAAA/wEAAP8EBQP/BwcE/woIBP8MDAn/DxIS/w8QDv8RExH/ERMQ/wwSFv8HGSn/Bx0v/w0aI/8SHSP/DSMz/wolO/8OJDT/DCU4/wsi',
    'NP8PHyr/FhgV/yIfFP8iJiH/Jy0n/yEgF/8hIhv/JSYd/ykpHf8lIBH/Eys7/w8vR/8RJDH/GyQl/xosNv8QLkT/Dyc6/w4lNv8PLkT/EzNJ/xU4UP8TMUX/',
    'Ei1A/xIsPf8NIS3/FCEn/y4SAP82FwL/LhMC/zMUAf81EwH/NxQB/zgUAP9DGAH/NA8A/zkRAP85DgD/Og8A/zUOAP8hCQD/BgAA/wEAAP8QExb/EyQz/wsj',
    'N/8ADB//GjBC/2Kiwv9HqN//OqHc/0iVve4RHCOBAAAAEgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAALFRtrPImv1i2Z2f8qldP/SZ7D/xw3Tf8ACCD/AR04/wEjQv8BFCf/AAIG/wAAAP8CAgH/',
    'BQUE/wgGA/8JCgj/Cw8P/w4SEv8SFBH/ERAK/wsUGf8OFhv/IBUF/ycXA/8bFxD/FBse/yAVBv8ZGhX/Exwg/yMWBf8jGw3/Ih4T/yEiG/8mLCj/ISAX/x4e',
    'Fv8iIhr/KCkf/ycmGv8dGQ7/Fhwc/x4cEv8gFwf/HxoO/xwbEv8THyT/Ch8u/w0lN/8QLED/ESs+/w8mN/8OJTP/DyUz/wwbJf8MHSb/HhMK/y0VAv8qFAT/',
    'KBAB/ysRAf8qEAH/KA4A/zQTAf8iCwD/JAsA/ykNAf8pDAH/EQQA/wAAAP8JCAn/GCAn/w8lOf8GHzT/ABMk/ytMYf9erNT/OZrU/0Gj3P9Fh6rWCQ8TawAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAGCAhQO3WQtz+m4P8smdn/S63Z/zRgd/8BDSL/ABUx/wMiQP8BHzz/AA8d/wAAAf8AAAD/AgMC/wUFA/8IBwX/CgwL/w0PDv8QEhH/',
    'ExEM/x0TBf8fFgr/IBkN/yYZCP8jFQX/IhcJ/yMXB/8jFwf/IxsP/yAcE/8bGA7/GxgP/x0gGv8gHBL/IR4U/x8cEv8dGRD/Hx0U/yIfFf8kIBP/Ix4R/x8f',
    'Fv8dGhH/HRYK/xUdHv8LJTj/Ch0q/wseLP8KHir/CRwp/wkbJ/8JGyb/CRcg/wwaI/8WFRL/JBEB/yMTBf8fDQH/IA4B/yANAf8eCwD/Ig0A/xsJAP8cCQD/',
    'EwYA/wMAAP8DAgP/CRAX/xQlNP8NJjn/ABEl/wYWJv9AdY7/V7Xj/zCSzf9Dotr/OGuGtwIDBFAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAvL1RmlDya',
    'z/comdn/R7bp/0eNrP8UKkD/AAwl/wAdOv8CJUb/ABoy/wAJEv8AAAD/AAAA/wICAf8FBQP/CAcE/wkIBv8NDAn/EA0H/xMPCP8WEQn/GBMK/xwVCf8hFwn/',
    'HxgM/x8ZD/8aFQv/FxMM/xgVDP8aFw//Gx0X/x0aEP8eHBL/HBkQ/xkWDv8XFAv/GRUL/xwaEf8cGA7/GBMJ/xoYEP8cGA3/FhkX/xAaH/8MGiP/Bxkl/wka',
    'Jv8TGRr/GhUO/xcWEv8NFx3/FREL/xkOA/8cEQX/GQ0C/xYLAv8WCgH/FwsB/xgKAP8UBwD/DAQA/wMAAP8AAAH/CA0S/wobKf8GITb/ARou/wAJG/8pPVD/',
    'XqDA/0ir3/8zltL/SKDR9yhJWpQAAAAvAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAKGS02a0KWvcs0puH/NKrk/0yq0/8zYHr/Bhkw/wAR',
    'K/8BI0L/AiVG/wAZMP8ACBD/AAAA/wAAAP8BAQD/BAQD/wYFBP8IBwP/DAoF/w0KBf8OCwb/EAwH/xENB/8SDgf/Ew8I/xQPCf8UEAr/FBEK/xcTDP8bGRL/',
    'GBUN/xkWDv8ZFg7/GBUM/xgVDP8XEwv/GhUL/xYTCv8XEgr/GRYO/x0bFP8aFg3/GBEG/xMSDP8MGyX/ERYY/xoPAv8aEAT/GQ4C/xUNA/8YDgT/Fw4F/xYN',
    'A/8RCQH/EAkB/xIIAf8PBgD/CQMA/wIAAP8AAAH/AQgP/wQWJf8HIDX/Ax0z/wAQJf8LGy3/R3KK/2O24P87o93/PZ7a/0WKscsUJC1rAAAACgAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAwNPTVshZlGr+L0Mafl/0Ky5/9Tnb3/KEVc/wAQKf8AFjT/AiVG/wIjQv8BGzP/AAwY/wAB',
    'BP8AAAD/AAAA/wICAf8FBAL/BwYD/wkIBP8LCAT/DAkE/w0KBf8OCwb/DwwH/xENCP8QDgj/EQ4J/xUUD/8UEQr/FRIL/xcUDf8UEQn/FBEK/xYSC/8XEwv/',
    'FRIK/xURCv8UEAn/Eg8J/xQRC/8VEgz/FhMK/xQPBv8VDwb/FxEJ/xIOB/8SDgf/Ew4G/xMMBf8RCwP/DAcC/wsGAf8JBAH/BQIA/wAAAP8AAAL/AQgP/wMU',
    'Iv8EHjL/Ah40/wAPIv8BDyH/L1Bk/2Ooy/9MrOH/Mp3a/0yq3fQ2ZH6ZBQcIPQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAACiM6Q2NNnMG6OK/q/y+q5/9QuOX/UJGu/x89WP8AEjD/ABU1/wElRv8CKkz/ASA7/wASI/8ABgz/AAAB/wAAAP8BAAD/AwMB/wUE',
    'Av8GBQL/BwYD/wgGBP8KCAT/CwkF/w0KBv8NCwb/Dg0J/w0LBv8PDAf/EA0I/xANCP8QDQf/EQ4H/xANB/8QDQf/EA0H/xAMBv8PDAb/DgoG/w4MB/8PDAf/',
    'EQ8K/w8MB/8OCgX/DAgD/w0JA/8NCQP/CwcC/wcEAf8EAgD/AQAA/wAAAP8AAgb/AAkS/wEUJf8DHTT/Ax0z/wAQJP8ADyL/JDxP/1OQrv9XteT/OJ/c/0Ck',
    '3/9Lkbi6HjE8YwAAAAoAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAcICSczX3J7',
    'R6jVzTaz7v83t+//ULzo/0+UtP8nTWn/ABo6/wATNf8AIEH/AypN/wIoSf8BGjH/AA0a/wAECf8AAAD/AAAA/wEAAP8BAQD/AwIB/wUEAv8GBQP/BwYD/wgG',
    'BP8JCAX/CQcE/woHBP8KCAT/CwkF/wsJBf8LCQX/CwkF/wsJBf8LCAT/CggE/wsJBP8LCAT/CQcE/wgGA/8JBwP/CAUC/wcFAv8HBQL/BQMA/wIBAP8AAAD/',
    'AAAA/wABA/8ABg7/AQ8d/wIXK/8DHDP/ABkv/wAMH/8ADyH/HDhM/02Jp/9ZsN3/OZ3a/zme3P9JmsrNMlpwewQGBycAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAARGx44OXSNhke049M+w/r/Q8f4/2HQ9P9fr8n/',
    'N2aE/wsqTP8AEjL/ABo8/wAjRP8CJUb/AR87/wEXLP8ADx7/AAcO/wADBv8AAAH/AAAA/wAAAP8BAAD/AQEA/wMCAf8DAgH/BAMB/wQEAv8FBAP/BgUD/wYF',
    'A/8FBQP/BgUC/wYFA/8FBQL/BQQC/wUEAv8EAwH/AwIA/wIBAP8BAAD/AAAA/wAAAP8AAAP/AAMI/wAIEf8BDhz/ARYp/wIcM/8CGzL/ABEn/wAIG/8GFCf/',
    'J0hf/0+Prv9Vst//O6bh/zOZ2f9CmczTQG6JhhMcIDgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFiQqOkJ+l4RUvejLRMv9/03W//9t4P//bsni/1ONpv8iQ2D/Axgz/wANKf8AFTL/',
    'AB47/wIjQP8CHTf/ARox/wAVKP8AEB//AAsW/wAGDv8AAwf/AAAD/wAAAP8AAAD/AAAA/wAAAP8AAAD/AAAA/wAAAP8AAAD/AAAA/wAAAP8AAAD/AAAA/wAA',
    'Av8AAgX/AAQJ/wAHD/8AChX/AA0c/wEUJ/8CGzD/Ahsy/wAZMP8AEyn/AAoe/wANIP8XLD//PGR8/1Sdv/9OtOX/N6Pg/zmg3v9LpNXLPHSShBYmLToAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    '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',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFy04JSZVaEgyeZdoOZjAhj6r26JAvO66RtD/0Era/+NG3f/0TeP//0/k',
    '//9O5P//TuT//1Hm//9U5///UOT//07g//9I2P//QNL//zzL//Q7x//jPMH50D2987pDtueiSKbQhkCPsWg1bIVIJENRJQAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABopMRImRFInLl5yOjZ2jkpFjKVYSJq3Y02nw2tQq8hwUbDMc1GwznNPrs5wTKnKa0mf',
    'wGNFkK5YOn2ZSjJofzopUWInIDtHEgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=='
) -join ''

$EmbeddedBinary['Media\README.txt'] = @(
    'VGV4dHVyZXMgZm9yIENvbXBsZXRpb24gTmF2aWdhdG9yLgoKTG9nby50Z2EgIC0tIGFkZG9uIGljb24sIHVzZWQgYnkgdGhlIC50b2MgSWNvblRleHR1cmUg',
    'bGluZSBhbmQgdGhlIG1pbmltYXAKICAgICAgICAgICAgIGJ1dHRvbi4gTXVzdCBiZSBhbiB1bmNvbXByZXNzZWQgMzItYml0IFRHQSB3aXRoIHBvd2VyLW9m',
    'LXR3bwogICAgICAgICAgICAgZGltZW5zaW9ucyAoMTI4eDEyOCkuIFdvVyB3aWxsIG5vdCBsb2FkIGEgUE5HLCBhbmQgaXQgZmFpbHMKICAgICAgICAgICAg',
    'IHNpbGVudGx5IHJhdGhlciB0aGFuIGVycm9yaW5nLCBzbyB0aGUgbWluaW1hcCBidXR0b24gdmVyaWZpZXMKICAgICAgICAgICAgIHRoZSB0ZXh0dXJlIGxv',
    'YWRlZCBhbmQgZmFsbHMgYmFjayB0byBhIHN0b2NrIGljb24gaWYgaXQgZGlkIG5vdC4KClJlZ2VuZXJhdGUgZnJvbSBhIHNvdXJjZSBQTkcgd2l0aDogIC5c',
    'Y24ucHMxIGljb24gPHBhdGgtdG8tcG5nPgo='
) -join ''


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

    # Artwork and anything else that is not text. Carried as base64 so a fresh
    # scaffold is complete and releasable -- without this, init produced a tree
    # whose own check failed on a missing IconTexture.
    foreach ($relative in $EmbeddedBinary.Keys) {
        $path = Join-Path $script:Root $relative
        $dir  = Split-Path -Parent $path

        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        [System.IO.File]::WriteAllBytes($path,
            [System.Convert]::FromBase64String($EmbeddedBinary[$relative]))

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

# ---------------------------------------------------------------------------
# HARVEST
# ---------------------------------------------------------------------------
#
# Closing the loop the design always described but never finished.
#
# The addon records the name, zone, coordinates and level of every quest you
# accept or turn in, permanently and account-wide. Until now the only way to
# get that out was /cn export, which prints it into a copy box -- so in
# practice it stayed in SavedVariables and the curated database stayed empty.
# That is what limits prerequisite forensics, and it is a tooling problem, not
# a data problem.
#
# This reads SavedVariables directly and folds anything new into
# Data\Quests.lua. Existing rows are never overwritten without -Force: curated
# data outranks observed data, which is the same source-ranking rule the addon
# itself applies.

# Extracts one balanced { ... } block starting at the first brace at or after
# $StartIndex. Lua tables nest, so a regex cannot do this correctly.
function Get-CNLuaBlock {
    param([string] $Text, [int] $StartIndex)

    $open = $Text.IndexOf('{', $StartIndex)

    if ($open -lt 0) { return $null }

    $depth    = 0
    $inString = $false
    $escaped  = $false

    for ($i = $open; $i -lt $Text.Length; $i++) {
        $char = $Text[$i]

        if ($escaped) { $escaped = $false; continue }

        if ($char -eq '\') { $escaped = $true; continue }

        if ($char -eq '"') { $inString = -not $inString; continue }

        if ($inString) { continue }

        if ($char -eq '{') { $depth++ }
        elseif ($char -eq '}') {
            $depth--

            if ($depth -eq 0) {
                return [PSCustomObject]@{
                    Body  = $Text.Substring($open + 1, $i - $open - 1)
                    End   = $i
                    Start = $open
                }
            }
        }
    }

    return $null
}

# Pulls [id] = { ... } records out of one SavedVariables table body.
function Get-CNSavedRecords {
    param([string] $Body)

    $records = @{}

    $index = 0

    while ($true) {
        $match = [regex]::Match($Body.Substring($index), '\[(\d+)\]\s*=\s*\{')

        if (-not $match.Success) { break }

        $id = [int] $match.Groups[1].Value

        $block = Get-CNLuaBlock -Text $Body -StartIndex ($index + $match.Index)

        if (-not $block) { break }

        $fields = @{}

        foreach ($field in [regex]::Matches($block.Body,
            '\["(\w+)"\]\s*=\s*("(?:[^"\\]|\\.)*"|[-\d.eE+]+|true|false)')) {

            $key   = $field.Groups[1].Value
            $value = $field.Groups[2].Value

            if ($value.StartsWith('"')) {
                $value = $value.Substring(1, $value.Length - 2) -replace '\\"', '"'
            }

            $fields[$key] = $value
        }

        if ($fields.Count -gt 0) { $records[$id] = $fields }

        $index = $block.End + 1

        if ($index -ge $Body.Length) { break }
    }

    return $records
}

# Where WoW keeps SavedVariables. Deriving it from the addon folder only works
# when the toolkit is running from inside AddOns -- and the recommended layout
# is a writable folder elsewhere with a junction back, precisely because
# Program Files is ACL-protected. So try the derivation, then the usual install
# locations.
function Get-CNSavedVariablesRoots {
    $roots = New-Object System.Collections.Generic.List[string]

    $candidate = $script:Root

    for ($i = 0; $i -lt 3; $i++) {
        $candidate = Split-Path -Parent $candidate

        if (-not $candidate) { break }
    }

    if ($candidate) {
        $roots.Add((Join-Path $candidate 'WTF\Account')) | Out-Null
    }

    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, 'C:\', 'D:\')) {
        if (-not $base) { continue }

        foreach ($flavour in @('_retail_', '_ptr_', '_classic_')) {
            $roots.Add((Join-Path $base "World of Warcraft\$flavour\WTF\Account")) | Out-Null
        }
    }

    return @($roots | Select-Object -Unique | Where-Object { Test-Path -LiteralPath $_ })
}

function Invoke-CNHarvest {
    Assert-CNWritable

    $saved = $null

    if ($Target) {
        if (-not (Test-Path -LiteralPath $Target)) {
            Write-Host "Not found: $Target" -ForegroundColor Yellow
            return
        }

        $saved = Get-Item -LiteralPath $Target
    }
    else {
        $roots = @(Get-CNSavedVariablesRoots)

        foreach ($root in $roots) {
            $found = Get-ChildItem -LiteralPath $root -Recurse -Filter 'CompletionNavigator.lua' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1

            if ($found) { $saved = $found; break }
        }

        if (-not $saved) {
            Write-Host 'No SavedVariables found.' -ForegroundColor Yellow
            Write-Host ''

            if ($roots.Count -gt 0) {
                Write-Host '  Looked in:' -ForegroundColor DarkGray
                foreach ($root in $roots) { Write-Host "    $root" -ForegroundColor DarkGray }
            }
            else {
                Write-Host '  No WoW WTF\Account folder could be located.' -ForegroundColor DarkGray
            }

            Write-Host ''
            Write-Host '  Log in with the addon loaded and /reload once, then try again.' -ForegroundColor DarkGray
            Write-Host '  Or point at the file:  .\cn.ps1 harvest <path>' -ForegroundColor DarkGray
            return
        }
    }

    Write-Host "Reading $($saved.FullName)" -ForegroundColor DarkGray
    Write-Host ("  {0:N0} bytes, written {1}" -f $saved.Length,
        $saved.LastWriteTime.ToString('yyyy-MM-dd HH:mm')) -ForegroundColor DarkGray
    Write-Host ''

    $text = [System.IO.File]::ReadAllText($saved.FullName)

    $marker = [regex]::Match($text, '\["questHarvest"\]\s*=\s*\{')

    if (-not $marker.Success) {
        Write-Host 'No harvested quests in SavedVariables yet.' -ForegroundColor Yellow
        Write-Host '  The addon records quests as you accept and turn them in.' -ForegroundColor DarkGray
        return
    }

    $block = Get-CNLuaBlock -Text $text -StartIndex $marker.Index

    if (-not $block) {
        Write-Host 'questHarvest table is malformed; nothing was changed.' -ForegroundColor Red
        return
    }

    $harvested = Get-CNSavedRecords -Body $block.Body

    if ($harvested.Count -eq 0) {
        Write-Host 'No harvested quests found.' -ForegroundColor Yellow
        return
    }

    $relative = 'Data\Quests.lua'
    $existing = Read-CNFile $relative

    if ($null -eq $existing) { throw "$relative not found. Run: .\cn.ps1 init" }

    $added      = 0
    $skipped    = 0
    $unlocated  = 0
    $lines      = New-Object System.Collections.Generic.List[string]

    foreach ($id in ($harvested.Keys | Sort-Object)) {
        $record = $harvested[$id]

        if ($existing -match ('\[\s*' + $id + '\s*\]\s*=')) {
            $skipped++
            continue
        }

        # A quest with no coordinates adds a name and nothing else. Useful,
        # but not what the static database exists for.
        if (-not ($record.ContainsKey('x') -and $record.ContainsKey('y'))) {
            $unlocated++

            if (-not $Force) { continue }
        }

        $lines.Add("    [$id] = {") | Out-Null

        if ($record.name) {
            $lines.Add('        name      = "' + ($record.name -replace '"', '\"') + '",') | Out-Null
        }

        if ($record.zone) { $lines.Add('        -- ' + $record.zone) | Out-Null }

        if ($record.mapID) { $lines.Add("        mapID     = $($record.mapID),") | Out-Null }

        if ($record.x -and $record.y) {
            $lines.Add("        x         = $($record.x),") | Out-Null
            $lines.Add("        y         = $($record.y),") | Out-Null
        }

        if ($record.requiresLevel) {
            $lines.Add("        requiresLevel = $($record.requiresLevel),") | Out-Null
        }

        $lines.Add('    },') | Out-Null

        $added++
    }

    Write-Host "Harvested in SavedVariables: $($harvested.Count)" -ForegroundColor White
    Write-Host "  already in $relative       $skipped" -ForegroundColor DarkGray
    Write-Host "  without coordinates        $unlocated$(if (-not $Force -and $unlocated -gt 0) { '  (skipped; -Force includes them)' })" -ForegroundColor DarkGray
    Write-Host "  new rows to add            $added" -ForegroundColor $(if ($added -gt 0) { 'Green' } else { 'DarkGray' })
    Write-Host ''

    if ($added -eq 0) {
        Write-Host 'Nothing to add.' -ForegroundColor Yellow
        return
    }

    Invoke-CNBackup -Quiet

    Add-CNBlock -Relative $relative -Block ($lines -join "`n") -Marker $script:DataMark

    Write-Host "Added $added quest$(if ($added -eq 1) { '' } else { 's' }) to $relative" -ForegroundColor Green
    Write-Host ''
    Write-Host '  Curated rows are never overwritten: if an ID is already present' -ForegroundColor DarkGray
    Write-Host '  it is left alone, because hand-checked data outranks observed data.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Next:  .\cn.ps1 check' -ForegroundColor DarkGray
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
            Write-Host "  FAIL  version mismatch: .toc $tocVersion vs Core.lua $coreVersion" -ForegroundColor Red
            $problems++
        }

        # A cn.ps1 older than the tree it manages will scaffold a previous
        # release over the top and report success. That failure is otherwise
        # completely silent, so it is worth being loud about.
        if ($coreVersion -and (Compare-CNVersion $script:ToolkitVersion $coreVersion) -lt 0) {
            Write-Host "  FAIL  this cn.ps1 carries $script:ToolkitVersion but the tree is $coreVersion." -ForegroundColor Red
            Write-Host '        Running init would downgrade your source. Get the current cn.ps1.' -ForegroundColor Red
            $problems++
        }
        elseif ($coreVersion -eq $script:ToolkitVersion) {
            Write-Host "  ok    toolkit and tree agree at $script:ToolkitVersion" -ForegroundColor DarkGray
        }
    }

    # Optional real syntax check if a Lua binary is on PATH.
    $luac = Get-Command 'luac54.exe', 'luac.exe', 'luac', 'luac5.4', 'luac5.3' -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($luac) {
        foreach ($file in $onDisk) {
            # Same trap as git: luac writes syntax errors to stderr, so under
            # $ErrorActionPreference = 'Stop' the first bad file would have
            # terminated the whole check instead of being reported.
            $result = Invoke-CNNative -Executable $luac.Source `
                -Arguments @('-p', (Join-Path $script:Root $file)) -Quiet

            if (-not $result.Ok) {
                Write-Host "  FAIL  $file :: $($result.Output -join ' ')" -ForegroundColor Red
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

    return $problems
}

# Returns -1, 0 or 1. Non-numeric or missing parts sort low rather than
# throwing, because a version string is not worth crashing a build over.
function Compare-CNVersion {
    param([string] $Left, [string] $Right)

    $leftParts  = @(($Left  -split '\.') | ForEach-Object { [int]($_ -replace '\D', '0') })
    $rightParts = @(($Right -split '\.') | ForEach-Object { [int]($_ -replace '\D', '0') })

    for ($i = 0; $i -lt 3; $i++) {
        $l = if ($i -lt $leftParts.Count)  { $leftParts[$i] }  else { 0 }
        $r = if ($i -lt $rightParts.Count) { $rightParts[$i] } else { 0 }

        if ($l -lt $r) { return -1 }
        if ($l -gt $r) { return 1 }
    }

    return 0
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
        Invoke-CNGit @('init', '-b', 'main') -Quiet | Out-Null

        # Set the repository identity BEFORE the first commit. Inheriting a
        # machine-wide identity here silently stamps the wrong address onto
        # the initial commit, and correcting it afterwards means rewriting
        # history.
        $commitName  = if ($Name)  { $Name }  else { 'Travis A. Bryan I' }
        $commitEmail = if ($Email) { $Email } else { 'developer@dambeaverstudios.com' }

        Invoke-CNGit @('config', 'user.name', $commitName) -Quiet | Out-Null
        Invoke-CNGit @('config', 'user.email', $commitEmail) -Quiet | Out-Null

        Invoke-CNGit @('add', '-A') -Quiet | Out-Null
        Invoke-CNGit @('commit', '-m', 'Completion Navigator: initial commit') -Quiet | Out-Null

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


# Native commands and $ErrorActionPreference = 'Stop' do not mix.
#
# On Windows PowerShell 5.1, stderr from a native command under 2>&1 arrives
# as ErrorRecord objects, and with the preference set to Stop the FIRST one
# terminates the script. git writes its ordinary progress to stderr, so
# `git push 2>&1` killed a release mid-way through a push that had actually
# succeeded. PowerShell 7 on Linux does not behave this way, which is exactly
# why it was not caught here.
#
# Every native invocation in this file goes through this function: the
# preference is neutralized for the duration, stderr is rendered as its
# message rather than its type name, and the real exit code comes back.
function Invoke-CNNative {
    param(
        [Parameter(Mandatory = $true)] [string] $Executable,
        [string[]] $Arguments = @(),
        [switch] $Quiet
    )

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    $lines = New-Object System.Collections.Generic.List[string]
    $code  = 0

    try {
        $raw = & $Executable @Arguments 2>&1

        $code = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }

        foreach ($item in @($raw)) {
            if ($null -eq $item) { continue }

            $text = if ($item -is [System.Management.Automation.ErrorRecord]) {
                $item.Exception.Message
            }
            else {
                [string] $item
            }

            foreach ($part in ($text -split "`r?`n")) {
                if ($part.Trim()) { $lines.Add($part) | Out-Null }
            }
        }
    }
    catch {
        $lines.Add($_.Exception.Message) | Out-Null
        $code = 1
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    if (-not $Quiet) {
        foreach ($line in $lines) {
            Write-Host "  $line" -ForegroundColor DarkGray
        }
    }

    return [PSCustomObject]@{
        Output   = @($lines)
        ExitCode = $code
        Ok       = ($code -eq 0)
    }
}

# The argument list is passed as ONE array, deliberately.
#
# With ValueFromRemainingArguments, PowerShell still binds by parameter-name
# prefix first -- so `Invoke-CNGit add -A` bound "-A" to the -Arguments
# parameter and failed with "Missing an argument for parameter 'Arguments'".
# git's flags cover most of the alphabet, so there is no safe parameter name.
# Wrapping them in an array removes the ambiguity entirely.
function Invoke-CNGit {
    param(
        [Parameter(Mandatory = $true, Position = 0)] [string[]] $GitArguments,
        [switch] $Quiet
    )

    return Invoke-CNNative -Executable 'git' -Arguments $GitArguments -Quiet:$Quiet
}

# Sorts version-like tags newest first. A plain string sort puts v0.9.0 above
# v0.15.0, which makes "newest remote tags" actively misleading.
function Sort-CNVersionTag {
    param([string[]] $Tags)

    return @($Tags | Sort-Object -Property @{ Expression = {
        $text = $_ -replace '^v', ''
        $parts = @(($text -split '\.') | ForEach-Object { [int]($_ -replace '\D', '0') })

        while ($parts.Count -lt 3) { $parts += 0 }

        ($parts[0] * 1000000) + ($parts[1] * 1000) + $parts[2]
    } } -Descending)
}

function Invoke-CNRelease {
    Assert-CNWritable

    $new = if ($Target) { $Target } else { $Value }

    if (-not $new -or $new -notmatch '^\d+\.\d+\.\d+$') {
        Write-Host 'Usage: .\cn.ps1 release <x.y.z>' -ForegroundColor Yellow
        return
    }

    # ------------------------------------------------------------------
    # Everything that can refuse the release happens BEFORE anything is
    # written, cheapest and most fundamental first.
    #
    # An earlier version bumped the version files and then bailed on a missing
    # changelog section, which left the tree claiming a version whose source
    # was never scaffolded. Nothing downstream could then be trusted, and the
    # only signal was a yellow warning that scrolled past.
    # ------------------------------------------------------------------

    # 1. Does this cn.ps1 even carry the source being released? Checked before
    #    anything else, because every other diagnosis is misleading when the
    #    answer here is no.
    if ($script:ToolkitVersion -ne $new) {
        Write-Host "ERROR  This cn.ps1 carries version $script:ToolkitVersion, not $new." -ForegroundColor Red
        Write-Host ''
        Write-Host '  The addon source is embedded in this file. Releasing a version it' -ForegroundColor DarkGray
        Write-Host '  does not carry would tag whatever happens to be on disk.' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host "  Either get the cn.ps1 for $new, or run:  .\cn.ps1 release $script:ToolkitVersion" -ForegroundColor Yellow
        return
    }

    # 2. Is git usable and is this a repository?
    if (-not (Assert-CNGit)) { return }

    if (-not (Test-Path -LiteralPath (Join-Path $script:Root '.git'))) {
        Write-Host 'Not a git repository. Run: .\cn.ps1 gitinit' -ForegroundColor Yellow
        return
    }

    # 3. Is the changelog ready? Checked before any file is touched.
    $changelog = Read-CNFile 'CHANGELOG.md'

    if ($changelog -and $changelog -notmatch [regex]::Escape("## [$new]")) {
        Write-Host "ERROR  CHANGELOG.md has no '## [$new]' section." -ForegroundColor Red
        Write-Host ''
        Write-Host '  Nothing has been changed. If the changelog on disk is stale, run:' -ForegroundColor DarkGray
        Write-Host '    .\cn.ps1 init -Force' -ForegroundColor Yellow
        Write-Host '  Or re-run with -Force to tag without a changelog entry.' -ForegroundColor DarkGray
        return
    }

    # 4. Does a tag already exist? git tag fails on a duplicate, and the
    #    failure is easy to miss in the middle of a release.
    Push-Location $script:Root

    try {
        $existing = @((Invoke-CNGit @('tag', '--list', "v$new") -Quiet).Output)

        if ($existing.Count -gt 0 -and -not $Force) {
            Write-Host "ERROR  Tag v$new already exists." -ForegroundColor Red
            Write-Host ''
            Write-Host '  Nothing has been changed. To replace it:' -ForegroundColor DarkGray
            Write-Host "    git tag -d v$new" -ForegroundColor Yellow
            Write-Host "    git push --delete origin v$new" -ForegroundColor Yellow
            Write-Host '  Or release the next version instead.' -ForegroundColor DarkGray
            return
        }
    }
    finally {
        Pop-Location
    }

    # 5. Does it pass its own validator? A failing check must stop the
    #    release, not merely print in front of it.
    Write-Host 'Validating...' -ForegroundColor Cyan

    $problems = Invoke-CNCheck

    Write-Host ''

    if ($problems -gt 0 -and -not $Force) {
        Write-Host "ERROR  $problems problem(s) found; not releasing." -ForegroundColor Red
        Write-Host '  Nothing has been changed. Fix them, or re-run with -Force.' -ForegroundColor DarkGray
        return
    }

    # ------------------------------------------------------------------
    # Past this line, the tree gets written to.
    # ------------------------------------------------------------------

    $Target = $new
    Invoke-CNVersion

    Push-Location $script:Root

    try {
        Invoke-CNGit @('add', '-A') -Quiet | Out-Null

        # An empty commit is not an error here: init may have written exactly
        # what was already committed. The tag is what matters.
        Invoke-CNGit @('commit', '-m', "Release $new") | Out-Null

        Invoke-CNGit @('tag', "v$new") | Out-Null

        if (-not @((Invoke-CNGit @('tag', '--list', "v$new") -Quiet).Output)) {
            Write-Host "ERROR  Tag v$new was not created. Not pushing." -ForegroundColor Red
            return
        }

        $head = @((Invoke-CNGit @('rev-parse', '--short', 'HEAD') -Quiet).Output)[0]

        Write-Host "Tagged v$new at $head." -ForegroundColor Green

        # The packager derives the release type from a tag pointing at HEAD.
        # No tag there means it publishes as an alpha, which then hides behind
        # "Show alpha files" on CurseForge.
        $atHead = @((Invoke-CNGit @('tag', '--points-at', 'HEAD') -Quiet).Output)

        if ($atHead -notcontains "v$new") {
            Write-Host "ERROR  v$new does not point at HEAD; CurseForge would get an alpha." -ForegroundColor Red
            Write-Host "  tags at HEAD: $($atHead -join ', ')" -ForegroundColor DarkGray
            return
        }

        $remote = @((Invoke-CNGit @('remote') -Quiet).Output)

        if (-not $remote) {
            Write-Host 'No git remote configured, so nothing was pushed.' -ForegroundColor Yellow
            Write-Host '  git remote add origin <url>' -ForegroundColor DarkGray
            Write-Host '  git push -u origin main --tags' -ForegroundColor DarkGray
            return
        }

        if (-not (Invoke-CNGit @('push')).Ok) {
            Write-Host 'ERROR  git push failed. The tag exists locally but was not pushed.' -ForegroundColor Red
            Write-Host '  Recover with:  git push ; git push --tags' -ForegroundColor Yellow
            return
        }

        if (-not (Invoke-CNGit @('push', '--tags')).Ok) {
            Write-Host 'ERROR  git push --tags failed. CurseForge will not see this release.' -ForegroundColor Red
            Write-Host '  Recover with:  git push --tags' -ForegroundColor Yellow
            return
        }

        Write-Host ''
        Write-Host "Pushed v$new. GitHub Actions packages and uploads to CurseForge." -ForegroundColor Green
        Write-Host '  Watch it:  https://github.com/Dam-Beaver-Studios-LLC/CompletionNavigator/actions' -ForegroundColor DarkGray
        Write-Host '  Confirm:   .\cn.ps1 doctor' -ForegroundColor DarkGray
    }
    finally {
        Pop-Location
    }
}

# Prints the whole release chain in one place. Written because diagnosing a
# release that silently did nothing meant assembling five separate commands
# by hand.
function Invoke-CNDoctor {
    Write-Host 'Completion Navigator :: doctor' -ForegroundColor Cyan
    Write-Host ''

    $toc  = Read-CNFile 'CompletionNavigator.toc'
    $core = Read-CNFile 'Core.lua'

    $tocVersion  = if ($toc  -match '(?m)^##\s*Version:\s*(.+)$') { $Matches[1].Trim() } else { '(none)' }
    $coreVersion = if ($core -match 'CN\.version\s*=\s*"([^"]+)"') { $Matches[1] } else { '(none)' }

    $luaCount = @(Get-CNLuaFiles).Count

    Write-Host 'Toolkit' -ForegroundColor White
    Write-Host "  cn.ps1 carries version   $script:ToolkitVersion"
    Write-Host "  cn.ps1 size              $((Get-Item $PSCommandPath).Length) bytes"
    Write-Host ''

    Write-Host 'Tree' -ForegroundColor White
    Write-Host "  .toc version             $tocVersion"
    Write-Host "  Core.lua version         $coreVersion"
    Write-Host "  Lua files on disk        $luaCount"

    $changelog = Read-CNFile 'CHANGELOG.md'

    $hasSection = $changelog -and $changelog -match [regex]::Escape("## [$coreVersion]")

    Write-Host ("  CHANGELOG [$coreVersion]" + (' ' * [Math]::Max(1, 15 - $coreVersion.Length)) +
        $(if ($hasSection) { 'present' } else { 'MISSING' })) `
        -ForegroundColor $(if ($hasSection) { 'Gray' } else { 'Red' })
    Write-Host ''

    if ((Compare-CNVersion $script:ToolkitVersion $coreVersion) -lt 0) {
        Write-Host '  This cn.ps1 is OLDER than the tree. init would downgrade your source.' -ForegroundColor Red
        Write-Host ''
    }

    if (-not (Test-Path -LiteralPath (Join-Path $script:Root '.git'))) {
        Write-Host 'Git' -ForegroundColor White
        Write-Host '  not a repository' -ForegroundColor Yellow
        return
    }

    if (-not (Assert-CNGit)) { return }

    Push-Location $script:Root

    try {
        Write-Host 'Git' -ForegroundColor White
        $head    = @((Invoke-CNGit @('rev-parse', '--short', 'HEAD') -Quiet).Output)[0]
        $subject = @((Invoke-CNGit @('log', '-1', '--pretty=%s') -Quiet).Output)[0]

        Write-Host "  HEAD                     $head $subject"

        $atHead = @((Invoke-CNGit @('tag', '--points-at', 'HEAD') -Quiet).Output)

        Write-Host ("  tags at HEAD             " +
            $(if ($atHead.Count) { $atHead -join ', ' } else { '(none)' })) `
            -ForegroundColor $(if ($atHead.Count) { 'Gray' } else { 'Yellow' })

        $dirty = @((Invoke-CNGit @('status', '--porcelain') -Quiet).Output)

        Write-Host ("  uncommitted changes      " +
            $(if ($dirty.Count) { "$($dirty.Count) file(s)" } else { 'none' }))

        $remote = @((Invoke-CNGit @('remote') -Quiet).Output)

        if (-not $remote) {
            Write-Host '  remote                   (none)' -ForegroundColor Yellow
            return
        }

        $remoteUrl = @((Invoke-CNGit @('remote', 'get-url', 'origin') -Quiet).Output)[0]

        Write-Host "  remote                   $remoteUrl"

        $lsRemote = Invoke-CNGit @('ls-remote', '--tags', 'origin') -Quiet

        $remoteTags = @()

        if ($lsRemote.Ok) {
            $remoteTags = Sort-CNVersionTag @($lsRemote.Output |
                ForEach-Object { ($_ -split 'refs/tags/')[-1] } |
                Where-Object { $_ -and $_ -notmatch '\^\{\}$' })
        }
        else {
            Write-Host '  (could not read remote tags)' -ForegroundColor Yellow
        }

        Write-Host ("  newest remote tags       " +
            $(if ($remoteTags.Count) { ($remoteTags | Select-Object -First 3) -join ', ' } else { '(none)' }))

        Write-Host ''

        $expected = "v$coreVersion"

        if ($remoteTags -contains $expected) {
            Write-Host "$expected is on the remote. If CurseForge has no file, check the Actions run." -ForegroundColor Green
        }
        else {
            Write-Host "$expected has NOT been pushed. CurseForge cannot have it." -ForegroundColor Yellow
            Write-Host "  Run:  .\cn.ps1 release $coreVersion" -ForegroundColor DarkGray
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
    Write-Host '  doctor                         Report the whole release chain state.'
    Write-Host '  harvest [path]                 Fold harvested quests from SavedVariables into Data.'
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
    'check'     { Invoke-CNCheck | Out-Null }
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
    'harvest'   { Invoke-CNHarvest }
    'release'   { Invoke-CNRelease }
    'doctor'    { Invoke-CNDoctor }
    'status'    { Invoke-CNDoctor }
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
