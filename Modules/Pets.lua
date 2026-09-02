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

-- A pet's name, from the client, falling back to anything an older database
-- still carries.
--
-- The name used to be stored for all eighteen hundred pets -- 274 KB of a
-- file the game rewrites on every logout, duplicating a journal the client
-- keeps in memory anyway. Persist only what the client cannot re-supply.
local function NameOf(speciesID, record)
    local live = CN.Blizzard.GetPetName(speciesID)

    if live then
        return live
    end

    -- Databases written before 0.36.0 still hold one.
    return (record and record.name) or ("Pet " .. tostring(speciesID))
end

local function Store()
    return CN.Account("pets")
end

Pets.Store  = Store
Pets.NameOf = NameOf

------------------------------------------------------------
-- SCAN
------------------------------------------------------------

function Pets.Scan()
    if not C_PetJournal then
        return 0, 0, 0
    end

    local store = Store()

    local seen, owned, missing = 0, 0, 0

    -- Which species this scan has already counted. See the note below.
    local counted = {}

    Blizzard.WithAllPetsShown(function()
        local total = select(1, Blizzard.GetNumPets())

        for index = 1, total do
            local pet = Blizzard.GetPetByIndex(index)

            if pet and pet.speciesID then
                local collected, limit = Blizzard.GetPetCollectedCount(pet.speciesID)

                store[pet.speciesID] = {
                    speciesID  = pet.speciesID,
                    -- `petType` IS NOT STORED. 0.98.0. Same as the mount
                    -- `spellID` beside it: eighteen hundred integers with no
                    -- reader anywhere in the tree, written every logout and
                    -- parsed every login. The journal answers it for free.
                    isWild     = pet.isWild,
                    canBattle  = pet.canBattle,
                    obtainable = pet.obtainable,
                    collected  = (collected or 0) > 0,
                    count      = collected or 0,
                    limit      = limit or 3,
                }

                -- ONE COUNT PER SPECIES, NOT PER JOURNAL ROW. 0.62.0.
                --
                -- `GetNumPets` returns DISPLAYED ENTRIES, and an owned
                -- species appears once per copy held -- which is exactly why
                -- `GetPetCollectedCount` returns `collected, limit`. These
                -- counters incremented per entry while `store` is keyed per
                -- species, so a player holding duplicates got two commands
                -- that disagreed about the same journal:
                --
                --   /cn petscan -> "Scanned 2,146 pets. Collected: 1,104"
                --   /cn pets    -> "known to the journal: 1,842. Collected: 802"
                --
                -- Counted off the store, which is the thing the rest of the
                -- addon reads.
                if not counted[pet.speciesID] then
                    counted[pet.speciesID] = true

                    seen = seen + 1

                    if (collected or 0) > 0 then
                        owned = owned + 1
                    elseif pet.obtainable then
                        missing = missing + 1
                    end
                end
            end
        end
    end)

    -- A REFUSAL IS NOT AN EMPTY JOURNAL. 0.92.0.
    --
    -- `GetNumPets` answers 0 while the journal is cold, which is exactly the
    -- state at login -- and `CN:OnLogin` runs this. Recording that as a scan
    -- costs three things:
    --
    --   * `nameRevision` is the key of the `PetNames` shortlist, so bumping
    --     it throws away the index and forces ~1,800 protected client calls
    --     to rebuild it, on the tooltip path. That is the exact cost the
    --     0.87.0 note above the index says it exists to avoid.
    --   * `CN.MarkScanned` invalidates three tabs' memoised summaries and
    --     marks the setup step done, so the login reminder stops asking for a
    --     scan that never happened.
    --   * `/cn petscan` prints "Scanned 0 pet species" while `/cn pets`,
    --     reading the store a second later, reports the full collection --
    --     two commands contradicting each other about one journal.
    --
    -- `Currencies` has carried this guard since 0.88.0, `Achievements` since
    -- 0.76.0, `Exploration` since 0.61.0, `Loremaster` since 0.71.0. Fifth
    -- writer, no guard.
    if seen == 0 then
        DebugPrint("Pet journal answered for nothing; not recording it.")

        return 0, 0, 0
    end

    -- THE THROTTLE IS STAMPED HERE, BY THE ONE FUNCTION THAT SCANS. 0.92.0.
    --
    -- `NEW_PET_ADDED` set `lastScan = 0` and then called this, which makes the
    -- throttle test in the sibling handler false -- so caging a pet ran the
    -- whole sweep, then `PET_JOURNAL_LIST_UPDATE` arrived and ran it again.
    -- Each sweep widens and restores the player's own journal filters.
    --
    -- `Modules/Currencies.lua` records fixing this exact shape in 0.65.0, in
    -- as many words: "resetting the timestamp BEFORE scanning sets it to
    -- zero, which makes the throttle test false ... and guarantees the very
    -- double sweep the comment says it prevents."
    Pets.lastScan = time()

    -- The name index is now stale. See `Pets.NameIndex`.
    Pets.nameRevision = (Pets.nameRevision or 0) + 1

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

-- SPECIES BY EXACT NAME, IN ONE LOOKUP. 0.87.0.
--
-- `Pets.Resolve` is a substring search over every species the journal has --
-- roughly eighteen hundred rows, lowercasing each name, allocating a table
-- per match and sorting the result. That is the right shape for a player
-- typing `/cn chase pet frost`, and the wrong one for a tooltip.
--
-- 0.86.0 correctly stopped reading a species id the client does not return
-- and started resolving the NAME instead -- and routed the tooltip and the
-- bag sweep through that search. This addon has removed exactly that from
-- two other hot paths and left a note each time: "twenty-five hundred
-- iterations and five thousand string allocations to answer a question about
-- one item... three per cent of a frame, per mouseover, and a bag sweep
-- fires dozens a second."
--
-- A caged pet's item name IS the species name, so the hot path wants an
-- exact match and nothing else. Built once per scan, on the counter the
-- store already bumps, in the same idiom `Professions.NameIndex` uses.
-- ON THE REVISION THIS STORE BUMPS, NOT THE COLLECTION COUNTER. 0.87.0.
--
-- The first version of this index keyed on `CN.collectionGeneration`, on the
-- reasoning that it is "the counter the store already bumps". It is not:
-- twelve client events move it -- a quest turn-in, a reputation tick, a
-- transmog, entering the world -- and none of them writes the pet store.
-- Each rebuild is one protected client call per species, so on an
-- eighteen-hundred-species account the index was rebuilt at roughly TWICE
-- the cost of the single search it exists to replace, in the tooltip path
-- that fires dozens of times a second.
--
-- `Professions.nameRevision` is the idiom this claimed to copy, and it is
-- bumped only where its store is written. So is this.
Pets.nameRevision = Pets.nameRevision or 0

function Pets.NameIndex()
    return CN.Shortlist("PetNames", Pets.nameRevision, function()
        local index = {}

        for id in pairs(Store()) do
            -- THE JOURNAL'S OWN NAME, NOT `NameOf`'s PLACEHOLDER. 0.87.0.
            --
            -- `NameOf` never returns nil: it falls back to "Pet 1234" for a
            -- species the client has not named yet. So a gate on "is this a
            -- non-empty string" cannot tell a cold journal from a loaded
            -- one, and an index built in the seconds after login -- against
            -- a store that is already full, because it is persisted -- was
            -- eighteen hundred placeholders that match no item name.
            --
            -- `Inventory.KindOf` refuses to cache exactly this miss one
            -- layer up; caching it here would have defeated that.
            local name = CN.Blizzard.GetPetName(id)

            if type(name) == "string" and name ~= "" then
                index[string.lower(name)] = id
            end
        end

        return index
    end)
end

function Pets.SpeciesByName(text)
    if type(text) ~= "string" or text == "" then
        return nil
    end

    return Pets.NameIndex()[string.lower(text)]
end

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
        local name = NameOf(id, record)

        if name and string.find(string.lower(name), needle, 1, true) then
            table.insert(matches, { id = id, name = name })
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
        return states.COMPLETED, "Already collected", NameOf(speciesID, record)
    end

    if record.obtainable == false then
        return states.UNOBTAINABLE, CN.blockReasons.UNOBTAINABLE, NameOf(speciesID, record)
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
                name            = NameOf(speciesID, record),
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

-- ONE WRITER. `Pets.Scan` stamps it, because `Pets.Scan` is what scans.
Pets.lastScan     = 0
Pets.rescanSeconds = 30

local function SweepIfDue()
    if time() - (Pets.lastScan or 0) < Pets.rescanSeconds then
        return false
    end

    local seen = Pets.Scan()

    DebugPrint("Pet journal scan: " .. tostring(seen) .. " species.")

    return true
end

-- Caging or learning a pet is the player acting, and no cooldown may delay
-- it. The scan stamps the throttle itself, so the `PET_JOURNAL_LIST_UPDATE`
-- that follows finds it fresh instead of running the same sweep again.
--
-- ONE PET IS AN EVENT; A BAG OF THEM IS A BURST. 0.95.0.
--
-- `bench.lua` measures this handler at 2.554 ms against 1,800 species -- the
-- most expensive single event in the whole benchmark by a factor of forty,
-- the next being `NEW_MOUNT_ADDED` at 0.065 -- and every sweep also drives
-- `WithAllPetsShown`, which saves, clears and restores the player's own
-- search box and collected checkboxes. Unthrottled, that ran once per pet.
--
-- `Routing.lua` debounces its own handler for this event and says why in as
-- many words: "`Modules/Pets.lua` already runs a full journal rescan on it
-- with no throttle, so a mass loot cost two full scans and an unthrottled
-- recommendation pass per pet". The tree documented the problem next door and
-- left it here.
--
-- `CN.Debounce` answers the first pet immediately -- which is the half that
-- must not be delayed -- and collapses the rest of the burst into one
-- trailing sweep.
CN:RegisterEvent("NEW_PET_ADDED", function()
    CN.Debounce("Pets.journal", 2, function()
        Pets.Scan()

        DebugPrint("Pet added; journal rescanned.")
    end)
end)

CN:RegisterEvent("PET_JOURNAL_LIST_UPDATE", SweepIfDue)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "petscan",
    order   = 50,
    help    = "Scan the pet journal.",
    handler = function()
        local seen, owned, missing = Pets.Scan()

        -- THE THREE NUMBERS ADD UP. 0.82.0.
        --
        -- `missing` counts only species the client calls OBTAINABLE, so an
        -- unobtainable uncollected species landed in `seen` and in neither
        -- of the other two: "Scanned 1,842. Collected: 802  Missing: 940",
        -- which is 1,742. `/cn pets`, run a second later, accounted for all
        -- of them -- the surviving half of the 0.62.0 defect this file
        -- documents, where the store-side count was fixed and the printed
        -- arithmetic was not.
        local counts = Pets.Summary()

        Print("Scanned " .. CN.Count(seen, "pet species", "pet species") .. ".")
        -- NO COLUMN PADDING. 0.92.0. See the note in
        -- `Modules/Currencies.lua`: three spaces after a one-digit count and
        -- after a four-digit count are two different widths.
        Print("Collected: " .. owned .. " " .. CN.DOT .. " Missing: " .. missing
            .. ((counts and (counts.unobtainable or 0) > 0)
                and (" " .. CN.DOT .. " Unobtainable: " .. counts.unobtainable)
                or ""))
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

        Print(NameOf(speciesID, record) .. " |cff8a8f96(" .. speciesID .. ")|r")
        Print("Collected: " .. CN.YesNo(record.collected)
            .. (record.collected and (" (" .. record.count .. "/" .. record.limit .. ")") or ""))
        Print("Wild: " .. CN.YesNo(record.isWild)
            .. " " .. CN.DOT .. " battle pet: " .. CN.YesNo(record.canBattle))

        if record.obtainable == false then
            Print("|cffe2564cCurrently unobtainable.|r")
        end
    end,
}

-- AND ONCE AT LOGIN. 0.62.0.
--
-- This store relied entirely on `NEW_PET_ADDED`, which covers
-- collections made while this session is running and nothing collected in a
-- session where the addon was not loaded. The store is persisted account-wide,
-- so a player who turns addons off for a raid night, collects three, and turns
-- them back on is recommended things they already own until they happen to run
-- the scan by hand.
--
-- `Appearances.lua` made exactly this argument in 0.58.0 and the same argument
-- applies verbatim here; three stores were left behind.
--
-- Guarded and quiet: this is a journal walk, and a client that refuses it must
-- not take the login sequence with it.
CN:OnLogin(function()
    CN.Guard("Pets.Scan", Pets.Scan)
end)
