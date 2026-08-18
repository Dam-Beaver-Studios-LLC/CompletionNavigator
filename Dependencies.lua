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
