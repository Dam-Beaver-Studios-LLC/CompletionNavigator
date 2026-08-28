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
        -- `standing` IS NOT STORED. 0.72.0. See `StandingText`.
        current     = (data.currentStanding or 0) - (data.currentReactionThreshold or 0),
        maximum     = (data.nextReactionThreshold or 0) - (data.currentReactionThreshold or 0),
        raw         = data.currentStanding,
        accountWide = Blizzard.IsAccountWideReputation(factionID),
        lastSeen    = time(),
    }

    local friendship = Blizzard.GetFriendshipReputation(factionID)

    if friendship then
        record.kind     = "FRIENDSHIP"
        -- THE ONE STANDING THAT MUST BE KEPT, AND NAMED SO IT IS OBVIOUS.
        --
        -- A friendship's rank is a free-text string the client supplies -- "Best
        -- Friend", "Trusted" -- and it supplies it only for the character
        -- currently logged in. There is no number to re-derive it from, so
        -- this is the single case where the word itself is the data, and it
        -- is what lets the Warband view say where an ALT stands. It is
        -- deliberately not called `standing`, so that nothing reaches for it
        -- as though it were the general case.
        record.friendshipStanding = friendship.reaction
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
            -- THE CLIENT'S OWN WORD FOR IT. 0.65.0.
            --
            -- Every other `standing` on a record is localized -- the client's
            -- `FACTION_STANDING_LABEL<n>` for a standard faction, its own
            -- friendship reaction for a friendship one -- and this one was
            -- hardcoded English AND persisted, so an alt's row was also
            -- frozen at whatever language that character last scanned in. A
            -- German player read "Standing: Renown 12" for one faction and
            -- "Standing: EhrfÃ¼rchtig" for the next.
            --
            -- Same defect 0.64.0 fixed for Alliance and Horde on the Warband
            -- roster, one file over. `RENOWN_LEVEL_LABEL` is a client global.
            record.renownLevel = major.renownLevel or 0
        end
    else
        record.kind = "STANDARD"
    end

    if Blizzard.IsFactionParagon(factionID) then
        local value, threshold, questID, pending = Blizzard.GetParagonInfo(factionID)

        -- PARAGON VALUE IS CUMULATIVE. THE BAR IS NOT. FIXED IN 0.61.0.
        --
        -- `C_Reputation.GetFactionParagonInfo` returns the total reputation
        -- earned since the faction went Paragon, ACROSS every cache already
        -- collected -- it does not reset. The addon stored it raw and printed
        -- it against the threshold, so a player three caches in read
        -- "Paragon: 34500/10000". Nonsense on its face, and worse than
        -- nonsense as a progress source: anything reading it as a fraction
        -- saw 345% and clamped to a full bar forever.
        --
        -- The threshold is the size of ONE cycle, so the position inside the
        -- current cycle is the remainder, and the number of completed cycles
        -- is the quotient -- which is itself worth showing, because "you have
        -- had eleven caches out of this" is exactly the kind of thing a
        -- completionist wants to know.
        --
        -- One subtlety: when a cache is PENDING the value has already crossed
        -- the threshold and the remainder has wrapped to near zero. Showing a
        -- nearly empty bar next to "REWARD READY" reads as a contradiction,
        -- so a pending cycle is reported as full.
        local within, cycles = value, 0

        if type(value) == "number" and type(threshold) == "number"
            and threshold > 0 then

            cycles = math.floor(value / threshold)
            within = value % threshold

            if pending then
                -- The finished cycle, not the one it has already rolled into.
                within = threshold
                cycles = math.max(0, cycles - 1)
            end
        end

        record.paragon = {
            -- What to draw and print.
            value     = within,
            threshold = threshold,

            -- How many caches this faction has already produced.
            cycles    = cycles,

            -- Kept because it is the only thing the client actually said,
            -- and `/cn navdiag` compares stored values against live ones.
            rawValue  = value,

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

    -- NAMED LIVE, LIKE TITLES AND CURRENCIES. 0.70.0.
    --
    -- Migration 18 converted `Titles.Resolve` and `Currencies.Resolve` off
    -- their persisted name stores, because a store fills with names frozen at
    -- whatever language last scanned -- so a player who changed client
    -- language could not find their own by name. This is the third `Resolve`
    -- of the same shape and it was not converted: `/cn rep Ehrenfeste` and
    -- `/cn goal reputation Ehrenfeste` answered nothing, in the same session
    -- where `/cn hidden` -- which asks the client first -- printed the German
    -- name correctly.
    --
    -- The store is still the fallback: unlike titles and currencies, the
    -- client will not name a faction the character has never encountered.
    for id in pairs(NameStore()) do
        local name = Reputations.NameOf(id)

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

-- A RECORD'S STANDING, DERIVED, NOT READ. 0.66.0.
--
-- Migration 18 dropped `standing` from every Renown record, because it had
-- been persisted as hardcoded English. That was right, and the WRITER was
-- given `CN.RenownLabel` in the same release -- but four readers went on
-- printing the field through `tostring`, which renders a missing value as the
-- four-letter word. Only the logged-in character's rows are rewritten at
-- login, so every ALT's major-faction row printed `Best character:
-- Ravencrest-Zeddicus (nil)` in `/cn rep`, `/cn who rep` and `/cn alts` until
-- that alt was played.
--
-- Tenth application of one rule: derive what the client can name, in the
-- language of whoever is READING it, from the number that was worth keeping.
function Reputations.StandingText(record)
    if type(record) ~= "table" then
        return nil
    end

    if record.kind == "RENOWN" then
        return CN.RenownLabel(record.renownLevel or record.renown or 0)
    end

    -- ONLY THE ONE THE CLIENT CANNOT RE-SUPPLY. 0.72.0.
    --
    -- This read `record.standing` in preference to deriving, and
    -- `BuildRecord` wrote that field on every scan -- including for RENOWN,
    -- which migration 18 exists to strip. So the migration was undone by the
    -- next `/cn repscan`, and every alt's row was frozen at the language and
    -- the rank that character last scanned in: a German player reading
    -- "EhrfÃ¼rchtig" for one faction and "Renown 12" for the next, which is
    -- the exact symptom 0.65.0 and 0.66.0 were both written to end.
    --
    -- `reaction` and `renownLevel` are numbers and are kept. The word is
    -- derived, in the language of whoever is reading it.
    if record.kind == "FRIENDSHIP" and record.friendshipStanding
        and record.friendshipStanding ~= "" then

        return record.friendshipStanding
    end

    return Blizzard.GetStandingLabel(record.reaction)
end

-- A FACTION'S NAME, FROM THE CLIENT, FALLING BACK TO THE STORE. 0.70.0.
--
-- Eleventh of these; see `Achievements.NameOf` for the first. The fallback is
-- real here in a way it was not for titles and currencies: `GetFactionByID`
-- answers for factions the character has met, and the store is how the addon
-- can still name one an alt has never encountered.
function Reputations.NameOf(factionID)
    local data = Blizzard.GetFactionByID and Blizzard.GetFactionByID(factionID)

    if data and data.name and data.name ~= "" then
        return data.name
    end

    return NameStore()[factionID]
end

-- Returns the best-standing character for a character-specific faction, so
-- the recommendation engine can say "switch to this alt instead".
function Reputations.BestCharacterFor(factionID)
    if AccountStore()[factionID] then
        return nil, nil, CN.scopes.ACCOUNT
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
            return states.LOCKED, CN.blockReasons.CAMPAIGN_INCOMPLETE,
                   Reputations.NameOf(factionID)
        end

        if record.maxedOut and not (record.paragon and record.paragon.pending) then
            return states.COMPLETED, "Maximum Renown reached",
                   Reputations.NameOf(factionID)
        end

        return states.AVAILABLE, nil, nil
    end

    if record.reaction and record.reaction >= 8
        and not (record.paragon and record.paragon.pending) then
        return states.COMPLETED, "Exalted", Reputations.NameOf(factionID)
    end

    if scope == "character" then
        local bestKey, bestRecord = Reputations.BestCharacterFor(factionID)

        if bestKey and bestKey ~= CN.characterKey and bestRecord then
            local mine = record.reaction or 0

            if (bestRecord.reaction or 0) > mine then
                return states.REQUIRES_OTHER_CHARACTER,
                       CN.blockReasons.BETTER_CHARACTER,
                       bestKey .. " is "
                           .. tostring(Reputations.StandingText(bestRecord))
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
                    "%s of the way to the next standing",
                    CN.PercentText(fraction)))
            end
        end

        return CN.NewObjective({
            id              = record.factionID,
            type            = CN.objectiveTypes.REPUTATION,
            -- NAMED LIVE. 0.71.0: the store holds whatever language last
            -- scanned, and only factions THIS character has met are
            -- rewritten -- so an account-wide row met by the main kept its
            -- old name on every other character and in every other language.
            name            = Reputations.NameOf(record.factionID),
            accountWide     = accountWide,
            completionValue = value,
            reasons         = reasons,
        })
    end

    -- AND THE WRAPPERS WENT TOO. 0.61.0.
    --
    -- 0.57.0 stopped BUILDING five hundred objectives to keep sixty, which
    -- was the expensive half. What it left behind was five hundred little
    -- `{ record, accountWide, value }` tables -- one per surviving faction,
    -- allocated on every rebuild, existing only to be sorted and then
    -- dropped. Measured at retail scale: 138 KB of the 482 KB this addon
    -- allocated per cold rebuild came from this one loop.
    --
    -- An index array with two parallel flat arrays sorts exactly as well and
    -- allocates three tables instead of five hundred. The comparator reads
    -- the same two fields; it just reaches them by index.
    local order       = {}
    local scoredValue = {}
    local scoredWide  = {}

    local function gather(store, accountWide)
        for _, record in pairs(store or {}) do
            local value = evaluate(record, accountWide)

            if value then
                local slot = #scored + 1

                scored[slot]      = record
                scoredValue[slot] = value
                scoredWide[slot]  = accountWide

                order[#order + 1] = slot
            end
        end
    end

    gather(AccountStore(), true)
    gather(CharacterStore(), false)

    -- Highest value first, ties broken by faction so the cut is stable
    -- between rebuilds rather than shuffling.
    table.sort(order, function(a, b)
        if scoredValue[a] == scoredValue[b] then
            return (scored[a].factionID or 0) < (scored[b].factionID or 0)
        end

        return scoredValue[a] > scoredValue[b]
    end)

    local limit = math.min(#order, CN.providerCandidateCap)

    local candidates = {}

    for index = 1, limit do
        local slot = order[index]

        candidates[index] =
            build(scored[slot], scoredWide[slot], scoredValue[slot])
    end

    CN.providerTruncation["Reputations"] = {
        considered = #order,
        dropped    = #order - limit,
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
            Print("Paragon rewards waiting: |cff73b873" .. paragon .. "|r")
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
            Print("Paragon rewards waiting: |cff73b873" .. counts.paragonPending .. "|r")
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

        Print(Reputations.NameOf(factionID) .. " |cff8a8f96(" .. factionID .. ")|r")
        Print("Standing: " .. tostring(Reputations.StandingText(record))
            .. " - " .. tostring(record.current) .. "/" .. tostring(record.maximum))
        Print("Scope: " .. (record.accountWide
            and "|cff73b873account-wide (Warband)|r"
            or "|cffffc74fcharacter-specific|r"))

        if record.kind == "RENOWN" then
            Print("Renown: " .. tostring(record.renown)
                .. (record.maxedOut and " |cff73b873(maximum)|r" or ""))
        end

        if record.paragon then
            local cycles = record.paragon.cycles or 0

            Print("Paragon: " .. tostring(record.paragon.value)
                .. "/" .. tostring(record.paragon.threshold)
                .. (cycles > 0 and CN.Muted(
                    "  (" .. cycles .. (cycles == 1
                        and " cache already earned)"
                        or " caches already earned)")) or "")
                .. (record.paragon.pending and " |cff73b873REWARD READY|r" or ""))
        end

        if scope == "character" then
            local bestKey, bestRecord = Reputations.BestCharacterFor(factionID)

            if bestKey and bestKey ~= CN.characterKey and bestRecord then
                Print("Best character: " .. bestKey
                    .. " (" .. tostring(Reputations.StandingText(bestRecord))
                    .. ")")
            end
        end

        if matches and #matches > 1 then
            Print("|cff8a8f96" .. (#matches - 1) .. " other name match(es); use the ID to be exact.|r")
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
                    CN.PrintLine(Reputations.NameOf(factionID)
                        .. " |cff8a8f96(" .. scopeLabel .. ")|r"
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
