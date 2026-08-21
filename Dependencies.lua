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
