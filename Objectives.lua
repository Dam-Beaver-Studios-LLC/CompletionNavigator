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

    -- A dungeon or raid lockout you are part-way through. Not a place; a
    -- deadline with progress already spent on it.
    INSTANCE    = "INSTANCE",
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
