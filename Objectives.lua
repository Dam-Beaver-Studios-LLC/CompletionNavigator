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
