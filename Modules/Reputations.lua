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

                -- ONE SCOPE PER FACTION, AND THE OTHER ONE IS DELETED.
                --
                -- `Reputations.Get` returns the account record whenever one
                -- exists, and `Scan` only ever ADDED -- so a faction Blizzard
                -- moved from account-wide to character-specific in a patch
                -- kept its stale account row winning forever, and every
                -- character read whichever character last scanned it.
                -- Blizzard has moved factions in both directions across
                -- patches.
                --
                -- Writing one scope now clears the other, so the store can
                -- never hold two answers for one faction.
                if record.accountWide then
                    accountStore[data.factionID] = record

                    if characterStore then
                        characterStore[data.factionID] = nil
                    end

                    accountWide = accountWide + 1
                elseif characterStore then
                    characterStore[data.factionID] = record
                    accountStore[data.factionID]   = nil

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
            local better

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
    -- SCORE FIRST, ALLOCATE SECOND.
    --
    -- The previous version built a full objective -- table, reasons array,
    -- formatted strings -- for every faction that was not yet exalted, then
    -- threw all but sixty of them away. At retail scale that is five hundred
    -- allocations to keep sixty, on every rebuild, and it was the single most
    -- expensive provider in the addon at nearly three milliseconds.
    --
    -- Evaluating is arithmetic on fields that already exist. Only the
    -- survivors are built.
    local scored = {}

    local function evaluate(record, accountWide)
        if not record or not record.factionID then
            return nil
        end

        if CN.IsIgnored(CN.objectiveTypes.REPUTATION, record.factionID)
            or CN.IsDeferred(CN.objectiveTypes.REPUTATION, record.factionID) then
            return nil
        end

        local value = 1

        if record.paragon and record.paragon.pending then
            value = value + 3
        elseif record.kind == "RENOWN" and record.maxedOut then
            return nil
        elseif record.reaction and record.reaction >= 8 then
            return nil
        end

        if accountWide then
            value = value + 1
        end

        if record.maximum and record.maximum > 0 and record.current then
            if (record.current / record.maximum) >= 0.75 then
                value = value + 1
            end
        end

        return value
    end

    local function build(record, accountWide, value)
        local reasons = {}

        if record.paragon and record.paragon.pending then
            table.insert(reasons, "a Paragon reward is waiting to be collected")
        end

        if accountWide then
            table.insert(reasons, "account-wide, so any character's progress counts")
        end

        if record.maximum and record.maximum > 0 and record.current then
            local fraction = record.current / record.maximum

            if fraction >= 0.75 then
                table.insert(reasons, string.format(
                    "%d%% of the way to the next standing", math.floor(fraction * 100)))
            end
        end

        return CN.NewObjective({
            id              = record.factionID,
            type            = CN.objectiveTypes.REPUTATION,
            name            = record.name,
            accountWide     = accountWide,
            completionValue = value,
            reasons         = reasons,
        })
    end

    local function gather(store, accountWide)
        for _, record in pairs(store or {}) do
            local value = evaluate(record, accountWide)

            if value then
                scored[#scored + 1] = {
                    record      = record,
                    accountWide = accountWide,
                    value       = value,
                }
            end
        end
    end

    gather(AccountStore(), true)
    gather(CharacterStore(), false)

    -- Highest value first, ties broken by faction so the cut is stable
    -- between rebuilds rather than shuffling.
    table.sort(scored, function(a, b)
        if a.value == b.value then
            return (a.record.factionID or 0) < (b.record.factionID or 0)
        end

        return a.value > b.value
    end)

    local limit = math.min(#scored, CN.providerCandidateCap)

    local candidates = {}

    for index = 1, limit do
        local entry = scored[index]

        candidates[index] = build(entry.record, entry.accountWide, entry.value)
    end

    CN.providerTruncation["Reputations"] = {
        considered = #scored,
        dropped    = #scored - limit,
    }

    return candidates
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
