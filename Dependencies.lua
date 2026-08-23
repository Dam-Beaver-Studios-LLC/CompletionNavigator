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

    -- Deliberately worded as an observation rather than a fact. The addon
    -- inferred this from the same ordering repeating across several
    -- characters; that is good evidence and it is not curated data, and the
    -- wording has to carry that difference.
    LIKELY_PREREQUISITE  = "Probably needs another quest first",
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
--       observedRequires = { questID, ... },  -- inferred, not curated
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

-- THE CONTRACT IS TWO FUNCTIONS; ONLY ONE OF THEM WAS CHECKED.
--
-- `GetAvailableQuestDataProviders` calls `provider.IsAvailable()` on every
-- registered provider, unconditionally. A provider registered without one --
-- which this accepted -- made that a call on nil inside a pcall, so it did
-- not crash: it silently reported the provider as unavailable, for ever, with
-- no message anywhere. A third-party data source that shipped a typo in one
-- field name would simply never be consulted and nobody would ever find out.
--
-- Both halves are required now, and a rejection says so.
--
-- Re-registration under a live name is a replacement, not a second row. It
-- used to append to the order list either way, so registering twice put the
-- name in the priority order twice and every consumer iterating the order got
-- the provider twice.
function CN.RegisterQuestDataProvider(name, provider)
    if type(name) ~= "string" or name == "" then
        return false, "a quest data provider needs a name"
    end

    if type(provider) ~= "table" then
        return false, "provider must be a table"
    end

    if type(provider.GetQuestData) ~= "function" then
        return false, name .. " has no GetQuestData"
    end

    if type(provider.IsAvailable) ~= "function" then
        return false, name .. " has no IsAvailable, which is asked before "
            .. "every read"
    end

    local replacing = CN.questDataProviders[name] ~= nil

    CN.questDataProviders[name] = provider

    -- A REPLACEMENT KEEPS ITS PLACE IN THE QUEUE.
    --
    -- Removing the row and minting a fresh sequence moved the provider to the
    -- back of its priority band, which is the exact symptom the tiebreak was
    -- added to prevent -- and it only happens on the path this release opened
    -- up. An addon that re-registers to swap in a better implementation must
    -- not thereby hand over which addon supplies a quest's name.
    local heldSequence

    if replacing then
        for index = #CN.questDataOrder, 1, -1 do
            if CN.questDataOrder[index].name == name then
                heldSequence = CN.questDataOrder[index].sequence or heldSequence

                table.remove(CN.questDataOrder, index)
            end
        end
    end

    -- A STABLE ORDER, BECAUSE `table.sort` IS NOT STABLE.
    --
    -- The list is re-sorted on every registration, so two providers that omit
    -- `priority` -- which every third-party provider will -- can swap places
    -- merely because a third one registered. `QueryQuestDataProviders` merges
    -- on "first answer per field wins", so that silently changes which
    -- provider supplies a quest's name or coordinates. Tie-break on
    -- registration order, which is deterministic and is what the priorities
    -- were expressing in the first place.
    if not heldSequence then
        CN.questDataSequence = (CN.questDataSequence or 0) + 1

        heldSequence = CN.questDataSequence
    end

    table.insert(CN.questDataOrder, {
        name     = name,
        priority = provider.priority or 100,
        sequence = heldSequence,
    })

    table.sort(CN.questDataOrder, function(a, b)
        if a.priority == b.priority then
            return (a.sequence or 0) < (b.sequence or 0)
        end

        return a.priority < b.priority
    end)

    return true
end

function CN.GetAvailableQuestDataProviders()
    local available = {}

    for _, entry in ipairs(CN.questDataOrder) do
        local provider = CN.questDataProviders[entry.name]

        -- Not `provider and pcall(...)`: `and` truncates a multiple return to
        -- its first value, so the second result would always be nil and every
        -- provider would read as unavailable.
        local ok, isAvailable = false, false

        if type(provider) == "table"
            and type(provider.IsAvailable) == "function" then

            ok, isAvailable = pcall(provider.IsAvailable)
        end

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

        -- The index happens BEFORE the pcall, so `pcall(provider.IsAvailable)`
        -- on a provider that has gone away throws out of whatever called this
        -- -- which includes a `QUEST_ACCEPTED` handler.
        local ok, isAvailable = false, false

        if type(provider) == "table"
            and type(provider.IsAvailable) == "function" then

            ok, isAvailable = pcall(provider.IsAvailable)
        end

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

-- Every quest that must be finished before this one, from whichever source
-- knows: curated data, an external addon, or this account's own observed
-- play. Observed prerequisites are included only once they have been seen
-- often enough to be believed.
function CN.GetPrerequisites(questID)
    local quests = CN:GetModule("Quests")

    if not quests or not quests.GetRecord then
        return {}
    end

    local record = quests.GetRecord(questID)

    local seen, ordered = {}, {}

    local function add(list)
        for _, prerequisiteID in ipairs(list or {}) do
            if not seen[prerequisiteID] then
                seen[prerequisiteID] = true
                table.insert(ordered, prerequisiteID)
            end
        end
    end

    if record then
        add(record.requires)
    end

    local harvest = CN.Account and CN.Account("questHarvest")

    if harvest and harvest[questID] then
        add(harvest[questID].observedRequires)
    end

    -- Chains other players contributed, shipped in Data/Community.lua or
    -- imported by hand. Added LAST and never as curated data: they are the
    -- weakest of the three sources and the ordering here is the order of
    -- authority.
    if CN.Static and CN.Static.GetCommunity then
        local community = CN.Static.GetCommunity(questID)

        if community then
            add(community.requires)
        end
    end

    local contributed = CN.Account and CN.Account("contributed")

    if contributed and contributed[questID] then
        add(contributed[questID])
    end

    return ordered
end

-- Whether this character has finished a quest. Thin, but Chase should not
-- have to know which module owns the answer.
function CN.IsQuestComplete(questID)
    local quests = CN:GetModule("Quests")

    if quests and quests.IsCompletedByCharacter then
        return quests.IsCompletedByCharacter(questID) and true or false
    end

    return false
end

function CN.Explain(objectiveType, id)
    if CN.IsIgnored(objectiveType, id) then
        return CN.objectiveStates.IGNORED,
            "you ignored this" .. CN.DASH .. "/cn unhide " .. tostring(id) .. " restores it",
            nil
    end

    if CN.IsDeferred(objectiveType, id) then
        return CN.objectiveStates.DEFERRED,
            "you deferred this" .. CN.DASH .. "/cn unhide " .. tostring(id)
            .. " restores it now", nil
    end

    local checker = CN.eligibilityCheckers[objectiveType]

    if not checker then
        -- NOT "no eligibility checker registered for CURRENCY", which names
        -- a registry the player has never heard of and cannot act on.
        return CN.objectiveStates.UNKNOWN,
            "this addon cannot check whether "
            .. string.lower(CN.TypeLabel(objectiveType))
            .. " are still available", nil
    end

    return checker(id)
end
