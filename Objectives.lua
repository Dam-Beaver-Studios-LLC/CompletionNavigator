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

    -- YOUR BODY, WHICH IS NOT A QUEST.
    --
    -- The corpse run was emitted as `QUEST` with `id = 1`, and quest 1 is a
    -- real id in the client's namespace. Three things went wrong with that:
    -- the auto-advance staleness check asked the quest checker whether quest
    -- 1 was complete and moved the arrow off the player's body if it said
    -- yes; any other provider emitting QUEST:1 could win the dedup and take
    -- the `corpse` flag with it, which is what exempts the body from the type
    -- filter and from the death penalty; and every corpse run was filed as
    -- quest-habit data by the preference learner.
    CORPSE      = "CORPSE",
}

-- HOW A PERSON READS A TYPE, AS OPPOSED TO HOW THE CODE THINKS ABOUT ONE.
--
-- This table lived in Modules/Filters.lua, which is loaded far too late for
-- most of the places that print a type: `/cn next`, `/cn list`, `/cn zone`,
-- the Next and Zone tabs and the broker all showed the raw enum. The broker
-- in particular set it as the LDB `label`, so Titan Panel and ElvUI rendered
-- the bar as "MOUNT" where the feed's name belongs.
--
-- Moved here, beside the enum it names, and completed: RENOWN, VENDOR and
-- COLLECTIBLE had no entry at all and fell through to the raw string.
CN.typeLabels = {
    QUEST       = "Quests",
    ACHIEVEMENT = "Achievements",
    REPUTATION  = "Reputations",
    RENOWN      = "Renown",
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
    VENDOR      = "Vendors",
    COLLECTIBLE = "Collectibles",
    INSTANCE    = "Dungeons & raids",
    CORPSE      = "Corpse runs",
}

function CN.TypeLabel(objectiveType)
    return CN.typeLabels[objectiveType] or tostring(objectiveType)
end

-- AND THE SINGULAR, BECAUSE A BADGE ON ONE ROW IS NOT A CATEGORY HEADING.
--
-- The labels above are plurals, which is right for a filter checklist and a
-- section heading and wrong on a row: `/cn next` printed "Kill Ten Rats
-- (Quests)" and the Next tab put "Quests" under a single quest's name. A
-- small grammatical wrongness the player notices without being able to name.
CN.typeBadges = {
    QUEST       = "Quest",
    ACHIEVEMENT = "Achievement",
    REPUTATION  = "Reputation",
    RENOWN      = "Renown",
    PET         = "Battle pet",
    MOUNT       = "Mount",
    TOY         = "Toy",
    APPEARANCE  = "Appearance",
    RECIPE      = "Recipe",
    PROFESSION  = "Profession",
    RARE        = "Rare",
    TREASURE    = "Treasure",
    EXPLORATION = "Exploration",
    TITLE       = "Title",
    CURRENCY    = "Currency",
    VENDOR      = "Vendor",
    COLLECTIBLE = "Collectible",
    INSTANCE    = "Dungeon",
    CORPSE      = "Corpse run",
}

-- ONE PLACE THAT TURNS WHAT A PLAYER TYPED INTO AN ID.
--
-- Six modules had a `Resolve` that accepts a name, and the two commands most
-- likely to be handed a name -- `/cn goal` and `/cn chase`, which are the
-- store page's headline feature -- called `CN.ToID` and refused anything that
-- was not already a number. So the addon shipped a resolver per collection
-- and asked players to look the id up on a website anyway.
--
-- Returns the id, or nil and a sentence saying why not. The sentence matters:
-- "that recipe does not exist" and "recipes are looked up by id" send the
-- player to completely different places.
-- THINGS THAT ARE NOT ANYWHERE.
--
-- A currency, a reputation, a renown track, a profession skill line, a
-- Warband row: none of these has a place you walk to. Their provider emits no
-- coordinates, and the addon has always read "no coordinates" as "somewhere
-- unknown" and charged them a baseline for the journey.
--
-- Which produced the wrong answer TWICE, in opposite directions. Measured
-- over a real collection before 0.57.0: the unknown-journey cost was 3 and
-- the far side of the player's own zone costs 3.3 -- so an objective with no
-- location was CHEAPER to reach than one you can see from where you are
-- standing, and twenty of the top thirty recommendations had no coordinates
-- at all. And an objective that genuinely should have a location and has not
-- resolved one was charged the same 3 as a currency, when the honest reading
-- there is that the addon does not know and should not be optimistic.
--
-- Two different states, so two different costs. A thing that is not anywhere
-- costs nothing to travel to, because there is no journey; a thing that is
-- somewhere the addon cannot name is charged the pessimistic fallback, the
-- same way `Travel.CostFor` charges one when it cannot cost a journey.
-- WHICH IS EVERY TYPE WHOSE PROVIDER EMITS NO COORDINATES BY NATURE.
--
-- 0.57.0 listed seven and left out the five that matter most by volume:
-- PET, MOUNT, TOY, APPEARANCE and RECIPE. Their own provider says so in as
-- many words -- "1200 uncollected pets, say, none of which has a known
-- location" -- and raising the unknown-journey cost from 3 to 8 therefore
-- charged every one of them five points it should never have paid, against a
-- completionValue that tops out around 8. Measured: an uncollected pet
-- scored -6.0 where a reputation with the same completion value scored +2.0.
-- The release meant to push things with no location DOWN and pushed exactly
-- the wrong half of them off the list.
CN.placelessTypes = {
    CURRENCY    = true,
    REPUTATION  = true,
    RENOWN      = true,
    PROFESSION  = true,
    TITLE       = true,
    ACHIEVEMENT = true,
    COLLECTIBLE = true,

    -- A collection entry is a thing you own or do not own. Where it can be
    -- got is a separate question the chase chain answers; the row itself is
    -- not a place, and it is not a journey.
    PET         = true,
    MOUNT       = true,
    TOY         = true,
    APPEARANCE  = true,
    RECIPE      = true,
}

function CN.IsPlaceless(objective)
    if type(objective) ~= "table" then
        return false
    end

    -- Something the provider gave coordinates for is somewhere, whatever its
    -- type says.
    if objective.mapID and objective.x and objective.y then
        return false
    end

    -- An item in your bag is not anywhere either -- it is already with you --
    -- and its provider says so by costing the journey at zero.
    --
    -- Reached only when the test above did not fire, so a row the provider
    -- gave coordinates for never lands here whatever its journey costs.
    -- 0.86.0 added a second copy of that test here before noticing the first,
    -- and removed it again; the note stays because the invariant is worth
    -- stating and the duplicate was not.
    if objective.travelCost == 0 then
        return true
    end

    return CN.placelessTypes[objective.type] == true
end

-- AND WHICH SCAN FILLS EACH ONE.
--
-- "It may need scanning first" was the whole of the advice, in an addon with
-- eleven scans. Naming the one that applies turns a dead end into a step.
CN.scanCommands = {
    MOUNT       = "mountscan",
    PET         = "petscan",
    TOY         = "toyscan",
    TITLE       = "titlescan",
    REPUTATION  = "repscan",
    RENOWN      = "repscan",
    CURRENCY    = "currencyscan",
    ACHIEVEMENT = "achievescan",
    APPEARANCE  = "appearancescan",
    RECIPE      = "profscan",
    PROFESSION  = "profscan",
    EXPLORATION = "explorescan",
}

CN.objectiveResolvers = {
    MOUNT       = "Mounts",
    PET         = "Pets",
    TOY         = "Toys",
    TITLE       = "Titles",
    REPUTATION  = "Reputations",
    RENOWN      = "Reputations",
    CURRENCY    = "Currencies",
    ACHIEVEMENT = "Achievements",
}

function CN.ResolveObjective(objectiveType, text)
    text = CN.Trim(tostring(text or ""))

    if text == "" then
        return nil, "Nothing to look up."
    end

    -- A number is a number, whatever the type.
    local numeric = CN.ToID(text)

    if numeric then
        return numeric
    end

    local moduleName = CN.objectiveResolvers[objectiveType]

    if not moduleName then
        return nil, CN.TypeBadge(objectiveType)
            .. "s are looked up by id, not by name: " .. text
    end

    local module = CN:GetModule(moduleName)

    if not module or not module.Resolve then
        -- "MODULE" IS THIS ADDON'S WORD FOR ITS OWN FILES. A player who reads
        -- "The Mounts module is not loaded" has been told the name of
        -- something they cannot see, act on, or report.
        return nil, "This addon cannot look up "
            .. string.lower(CN.TypeBadge(objectiveType))
            .. "s right now. " .. CN.Accent("/cn selftest")
            .. " says what is missing."
    end

    local resolved = module.Resolve(text)

    if resolved then
        return resolved
    end

    -- "Nothing mounts matches" -- the module's own name dropped into a
    -- sentence as though it were a noun, on the failure path of `/cn goal`
    -- and `/cn chase`, which is the store page's headline feature. And "it
    -- may need scanning first" named no scan, in an addon with eleven of
    -- them.
    local scan = CN.scanCommands and CN.scanCommands[objectiveType]

    return nil, "No " .. string.lower(CN.TypeBadge(objectiveType))
        .. " matches \"" .. text .. "\"."
        .. (scan and (" " .. CN.Accent("/cn " .. scan)
            .. " reads them from the client.") or "")
end

function CN.TypeBadge(objectiveType)
    return CN.typeBadges[objectiveType]
        or CN.typeLabels[objectiveType]
        or tostring(objectiveType)
end

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

-- AND WHAT EACH OF THEM IS CALLED IN FRONT OF A PLAYER.
--
-- The enum is the addon's vocabulary. `/cn queststatus` and `/cn why` printed
-- it raw, so a player read "State: REQUIRES_OTHER_CHARACTER" and
-- "State: TEMPORARILY_UNAVAILABLE" -- SHOUTING, in underscores, about
-- something they are perfectly capable of being told in words.
--
-- The same split `CN.typeLabels` and `CN.typeBadges` already make: one table
-- is what the code compares against, another is what a person reads.
CN.stateLabels = {
    UNKNOWN                  = "not known",
    AVAILABLE                = "available",
    COMPLETED                = "done",
    LOCKED                   = "locked behind something else",
    DEFERRED                 = "deferred by you",
    IGNORED                  = "ignored by you",
    INELIGIBLE               = "not for this character",
    TEMPORARILY_UNAVAILABLE  = "not available right now",
    UNOBTAINABLE             = "no longer obtainable",
    REQUIRES_OTHER_CHARACTER = "another character has to do this",
}

function CN.StateLabel(state)
    if not state then
        return CN.stateLabels.UNKNOWN
    end

    return CN.stateLabels[state] or string.lower(tostring(state))
end

------------------------------------------------------------
-- SOURCE CONFIDENCE
------------------------------------------------------------

-- Lower number means higher authority. Manual overrides must never
-- silently replace a more authoritative source.
-- Lower wins. Two sources were being written and were absent from this
-- table, which made them rank 99 -- worse than everything, including each
-- other, so whichever arrived first could never be corrected. 0.63.0.
CN.sourceRank = {
    ["blizzard"]  = 1,
    ["questlog"]  = 2,

    -- Read from a gossip window: the NPC is offering it, so the title is the
    -- client's, but it is not the quest log's.
    ["offered"]   = 3,

    -- Read from a map pin. The same title by a longer road, and the one most
    -- likely to be superseded.
    ["available"] = 4,

    ["observed"]  = 5,
    ["static"]    = 6,
    ["external"]  = 7,
    ["manual"]    = 8,
}

-- Two id lists, same members, same order. Used where a stored inference is
-- rewritten only when it actually changed.
function CN.SameIDList(a, b)
    if a == b then
        return true
    end

    if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then
        return false
    end

    for index = 1, #a do
        if a[index] ~= b[index] then
            return false
        end
    end

    return true
end

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

-- A STABLE TIE-BREAK THAT DOES NOT BUILD A STRING.
--
-- Three comparators in this file broke ties with `tostring(a) < tostring(b)`
-- over ids that are numbers -- two string allocations per comparison, inside
-- `table.sort`. Scoring.lua carries a comment about having removed exactly
-- this from the ranked comparator ("built 1,886 strings to do it: 0.35 ms and
-- 4.1 KB per re-rank"); the fix was applied there and not here.
--
-- Measured on the game's own Lua 5.1 at retail scale: the Pets provider went
-- from 4.53 ms to 2.69 ms and a cold rebuild of every candidate from 10.74 ms
-- to 9.31 ms -- thirteen per cent, for three lines.
--
-- Mixed types still need the string form: a quest id is a number and a
-- lockout id is a string, and `1 < "a"` is an error rather than an ordering.
local function IdBefore(a, b)
    if type(a) == type(b) then
        return a < b
    end

    return tostring(a) < tostring(b)
end

CN.IdBefore = IdBefore

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
            return IdBefore(a.id, b.id)
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

        table.sort(atThreshold, IdBefore)

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

-- NESTED BY TYPE, NOT KEYED ON A STRING.
--
-- These two are called twice for every candidate a provider considers, which
-- at retail scale is four thousand of each per rebuild. Each call built a
-- "TYPE:id" string, so the work was eight thousand string allocations to look
-- up a table with, typically, one row in it.
--
-- 0.44.0 fixed the common case with `next(t) == nil` -- if the player has
-- never hidden anything, do not build the key at all -- and that is genuinely
-- right and stays. But it covers only the empty case, and the moment a player
-- clicks Ignore ONCE, every rebuild pays the full cost again: measured at
-- +2.2 ms per rebuild, a 53% increase, for the population the feature exists
-- for.
--
-- Two levels instead: `store[objectiveType][id]`. No string is built at all,
-- and the lookup is two hash indexes. Measured 32 times faster on the
-- non-empty path. Migration 8 converts the flat keys.
--
-- The store references are hoisted too. `CN.Account("ignoredObjectives")` was
-- called nearly nine thousand times per rebuild, each one an `or {}`
-- assignment into the database table.
local function ObjectiveKey(objectiveType, id)
    return tostring(objectiveType) .. ":" .. tostring(id)
end

CN.ObjectiveKey = ObjectiveKey

local ignoredStore, deferredStore

-- Refreshed whenever the database is (re)built, because the table identity
-- changes with it.
function CN.RefreshFilterStores()
    ignoredStore  = CN.Account("ignoredObjectives")
    deferredStore = CN.Account("deferredObjectives")

    return ignoredStore, deferredStore
end

local function Ignored()
    return ignoredStore or CN.RefreshFilterStores()
end

local function Deferred()
    local _, store = nil, deferredStore

    if not store then
        _, store = CN.RefreshFilterStores()
    end

    return store
end

-- next(t) == nil answers "is this table empty" without touching a key.
function CN.IsIgnored(objectiveType, id)
    local ignored = Ignored()

    if not ignored or next(ignored) == nil then
        return false
    end

    local byType = ignored[objectiveType]

    return (byType ~= nil) and (byType[id] ~= nil)
end

-- HIDING SOMETHING HAS TO TAKE EFFECT NOW.
--
-- `CN.IsIgnored` and `CN.IsDeferred` are consulted inside candidate
-- providers, at build time -- which means the ignore list is baked into the
-- cached candidate list, and changing it changes nothing until something
-- unrelated happens to make a provider dirty.
--
-- It looked like it worked because most providers are chatty: some event
-- rebuilds them within seconds and the row disappears. For a provider that
-- is not -- `Mounts` waits on NEW_MOUNT_ADDED, `Sets` on a sixty-second
-- cooldown -- clicking Ignore could go unhonoured for the rest of the
-- session, with the thing the player just dismissed still sitting at the top
-- of the list.
--
-- Urgent, with no reason given, because this is an explicit player action and
-- an explicit player action is precisely what bypasses cooldowns.
local function Rebuild()
    if CN.InvalidateCandidates then
        CN.InvalidateCandidates()
    end
end

-- Empties a type bucket that has nothing left in it, so `next(store) == nil`
-- keeps meaning "nothing is hidden" after the last row is restored.
local function Trim(store, objectiveType)
    local byType = store[objectiveType]

    if byType and next(byType) == nil then
        store[objectiveType] = nil
    end
end

function CN.SetIgnored(objectiveType, id, value)
    local ignored = Ignored()

    if value then
        ignored[objectiveType] = ignored[objectiveType] or {}
        ignored[objectiveType][id] = { since = time() }
    elseif ignored[objectiveType] then
        ignored[objectiveType][id] = nil

        Trim(ignored, objectiveType)
    end

    Rebuild()
end

function CN.IsDeferred(objectiveType, id)
    local deferred = Deferred()

    if not deferred or next(deferred) == nil then
        return false
    end

    local byType = deferred[objectiveType]

    local entry = byType and byType[id]

    if not entry then
        return false
    end

    if entry.until_ and entry.until_ <= time() then
        byType[id] = nil

        Trim(deferred, objectiveType)

        return false
    end

    return true
end

function CN.SetDeferred(objectiveType, id, seconds)
    local deferred = Deferred()

    if not seconds then
        if deferred[objectiveType] then
            deferred[objectiveType][id] = nil

            Trim(deferred, objectiveType)
        end

        Rebuild()

        return
    end

    deferred[objectiveType] = deferred[objectiveType] or {}

    deferred[objectiveType][id] = {
        since  = time(),
        until_ = time() + seconds,
    }

    Rebuild()
end

-- Walks both stores as flat (type, id, entry) triples, so the commands and
-- the filter module do not each have to know the shape.
function CN.EachFiltered(store)
    local types = {}

    for objectiveType in pairs(store or {}) do
        table.insert(types, objectiveType)
    end

    table.sort(types)

    local typeIndex, ids, idIndex = 0, nil, 0

    return function()
        while true do
            if ids and idIndex < #ids then
                idIndex = idIndex + 1

                local objectiveType = types[typeIndex]
                local id            = ids[idIndex]

                return objectiveType, id, store[objectiveType][id]
            end

            typeIndex = typeIndex + 1

            if typeIndex > #types then
                return nil
            end

            ids, idIndex = {}, 0

            for id in pairs(store[types[typeIndex]] or {}) do
                table.insert(ids, id)
            end

            table.sort(ids, IdBefore)
        end
    end
end
