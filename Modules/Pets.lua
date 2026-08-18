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
    args    = "<speciesID|name>",
    order   = 52,
    help    = "Show one pet's collection state.",
    handler = function(args)
        if args == "" then
            Print("Usage: /cn pet <speciesID|name>")
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
