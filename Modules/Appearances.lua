-- Modules/Appearances.lua
-- Completion Navigator :: transmog appearance progress.
--
-- Deliberately category-level rather than item-level. Enumerating every
-- appearance source is tens of thousands of entries and would bloat
-- SavedVariables for no decision-making benefit: the useful question is
-- "which slot am I furthest from finishing", not "which of 40,000 sources
-- do I lack". Per-item work belongs to a wardrobe addon.

local ADDON_NAME, CN = ...

local Appearances = CN:RegisterModule("Appearances")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

local function Store()
    return CN.Account("appearances")
end

Appearances.Store = Store

-- THE LIVE NAME, NEVER A STORED ONE. 0.93.0.
--
-- `C_TransmogCollection.GetCategoryInfo` re-supplies the localized slot name
-- instantly, so persisting it bought nothing and cost correctness: a player
-- who changed client language kept reading the old language off disk until
-- the next scan. Same argument `Appearances.lua` itself made in 0.58.0 for
-- other stores, applied at last to this one.
--
-- The fallback is deliberately an English-free identifier plus the ID rather
-- than a localized guess -- callers append " appearances", and a wrong
-- language is worse than a plain slot number.
function Appearances.NameOf(categoryID)
    local live = Blizzard.GetAppearanceCategoryName
        and Blizzard.GetAppearanceCategoryName(categoryID)

    if live then
        return live
    end

    return "Slot " .. tostring(categoryID)
end

------------------------------------------------------------
-- SCAN
------------------------------------------------------------

-- THE FUNCTION THAT DOES THE WORK STAMPS THE THROTTLE. 0.93.0.
--
-- The stamp used to live in the `TRANSMOG_COLLECTION_UPDATED` handler, so
-- only that one path advanced it. The login scan and `/cn appearancescan`
-- both walked every category and left `lastRescan` untouched, which meant a
-- login scan followed seconds later by a looted appearance ran the whole
-- walk twice. Declared here so `Scan` -- the thing that actually spends the
-- time -- owns it.
local lastRescan = 0

function Appearances.Scan()
    if not C_TransmogCollection then
        return 0
    end

    lastRescan = time()

    local store      = Store()
    local categories = Blizzard.GetAppearanceCategories()

    for _, category in ipairs(categories) do
        local held = store[category.categoryID]

        -- A ZERO FROM A CLIENT THAT HAS NOT LOADED THE WARDROBE IS NOT A
        -- MEASUREMENT.
        --
        -- `GetCategoryCollectedCount` falls back to zero when the collection
        -- is not ready, and this scan now runs at login -- so overwriting a
        -- scanned "184 of 260" with "0 of 260" would make the addon
        -- recommend every slot the player has already finished, until
        -- something transmoggable happened to fire the collection event.
        --
        -- Keeping the higher of the two is the honest reading: a count can
        -- only go up, and a refusal reads as zero.
        local collected = category.collected or 0

        if held and (held.collected or 0) > collected then
            collected = held.collected
        end

        -- NO `lastSeen`. 0.80.0.
        --
        -- Nothing has ever read an appearance record's `lastSeen`. Migration
        -- 5 stripped exactly this field from `achievements`, `pets`, `toys`
        -- and `achievementTotals` -- under a header about values "being
        -- written to disk on every logout and parsed again on every login" --
        -- and this store was the one it missed. Stripping alone would not
        -- have held anyway, because the writer here was never changed: the
        -- login scan and the ten-minute rescan would have put it straight
        -- back.
        store[category.categoryID] = {
            categoryID = category.categoryID,

            -- `name` IS NOT STORED. 0.93.0.
            --
            -- Nine modules in this addon have a live-name accessor with a
            -- store fallback, and three of them -- Toys, Mounts, Pets --
            -- carry a comment saying "`Appearances.lua` made exactly this
            -- argument in 0.58.0 and the same argument applies here." This
            -- file made the argument and was never swept: it had no
            -- accessor, and `Summary`, `Remaining` and the candidate provider
            -- all took the localized name straight off disk.
            --
            -- `C_TransmogCollection.GetCategoryInfo` re-supplies it instantly
            -- and in the player's own language, so a player who changed
            -- client language read "Schulter appearances" in `/cn next` until
            -- the next scan.
            collected  = collected,
            total      = category.total,
        }
    end

    CN.MarkScanned("appearances")

    return #categories
end

------------------------------------------------------------
-- SUMMARY
------------------------------------------------------------

function Appearances.Summary()
    local counts = {
        categories = 0,
        collected  = 0,
        total      = 0,
        complete   = 0,
    }

    for _, record in pairs(Store()) do
        counts.categories = counts.categories + 1
        counts.collected  = counts.collected + (record.collected or 0)
        counts.total      = counts.total + (record.total or 0)

        if record.total and record.total > 0 and record.collected >= record.total then
            counts.complete = counts.complete + 1
        end
    end

    return counts
end

-- Categories sorted by how many appearances remain, most first.
function Appearances.Remaining()
    local rows = {}

    for _, record in pairs(Store()) do
        local remaining = (record.total or 0) - (record.collected or 0)

        if remaining > 0 then
            table.insert(rows, {
                name      = Appearances.NameOf(record.categoryID),
                collected = record.collected,
                total     = record.total,
                remaining = remaining,
            })
        end
    end

    table.sort(rows, function(a, b) return a.remaining > b.remaining end)

    return rows
end

------------------------------------------------------------
-- CANDIDATES
------------------------------------------------------------

-- How many slots are worth surfacing. Beyond a few, "your least complete
-- slot" stops being a next action and becomes a table.
Appearances.candidateSlots = 3

-- Appearances are tracked per category, not per item -- enumerating every
-- appearance source is tens of thousands of entries. So the objective here is
-- the honest one the data supports: which slot is furthest from done.
--
-- It is deliberately low-valued. "Your chest slot is least complete" is a
-- direction to point yourself in, not a task, and it should never outrank
-- something with coordinates or a deadline.
CN.RegisterCandidateProvider("Appearances", function()
    local rows = {}

    for categoryID, record in pairs(Store()) do
        local total     = record.total or 0
        local collected = record.collected or 0

        if total > 0
            and collected < total
            and not CN.IsIgnored(CN.objectiveTypes.APPEARANCE, categoryID)
            and not CN.IsDeferred(CN.objectiveTypes.APPEARANCE, categoryID) then

            table.insert(rows, {
                categoryID = categoryID,
                name       = Appearances.NameOf(record.categoryID),
                collected  = collected,
                total      = total,
                remaining  = total - collected,
                fraction   = collected / total,
            })
        end
    end

    -- Least complete first; ties by ID so the list does not reshuffle.
    table.sort(rows, function(a, b)
        if a.fraction ~= b.fraction then
            return a.fraction < b.fraction
        end

        return a.categoryID < b.categoryID
    end)

    local candidates = {}

    for index = 1, math.min(Appearances.candidateSlots, #rows) do
        local row = rows[index]

        table.insert(candidates, CN.NewObjective({
            id              = row.categoryID,
            type            = CN.objectiveTypes.APPEARANCE,
            name            = tostring(row.name) .. " appearances",
            accountWide     = true,
            completionValue = 1,
            reasons         = {
                row.collected .. " of " .. row.total .. " collected",
                row.remaining .. " remaining in this slot",
            },
        }))
    end

    CN.providerTruncation["Appearances"] = {
        considered = #rows,
        dropped    = math.max(0, #rows - #candidates),
    }

    return candidates
end, { events = { "TRANSMOG_COLLECTION_UPDATED" }, cooldown = 10 })

------------------------------------------------------------
-- KEEPING UP
------------------------------------------------------------

-- THE ONE SETUP STEP WITH NO REFRESH PATH AT ALL.
--
-- Every other scan has something that renews it: an event, a login hook, or
-- a command a player has a reason to run. Appearances had the provider's
-- invalidation -- which rebuilds the CANDIDATES from the store -- and nothing
-- that ever rebuilt the STORE. So it was read once by `/cn setup` and then
-- silently rotted: a month of collecting left the addon recommending
-- appearances the player already had.
--
-- Throttled hard, because the transmog event fires on every piece looted and
-- the scan walks every category.
Appearances.rescanSeconds = 600

-- AND ONCE AT LOGIN, which is the one path this store did not have.
--
-- Every other setup-scanned store -- currencies, reputations, titles,
-- professions, quests -- refreshes itself on login. This one relied on
-- `TRANSMOG_COLLECTION_UPDATED`, which covers appearances collected while
-- this session is running and nothing collected on another character or in a
-- session where the addon was not loaded. A player who logs in and loots
-- nothing transmoggable never fires it, and the counts stay as they were
-- whenever `/cn setup` last ran -- which is the "silently rotted" state this
-- file's own header describes.
CN:OnLogin(function()
    -- Protected and quiet: this is a journal walk, and a client that refuses
    -- it must not take the login sequence with it.
    CN.Guard("Appearances.Scan", Appearances.Scan)
end)

CN:RegisterEvent("TRANSMOG_COLLECTION_UPDATED", function()
    local now = time()

    if (now - lastRescan) < Appearances.rescanSeconds then
        return
    end

    pcall(Appearances.Scan)
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "appearancescan",
    aliases = { "transmogscan" },
    order   = 59,
    help    = "Scan transmog appearance categories.",
    handler = function()
        local categories = Appearances.Scan()

        Print("Scanned " .. categories .. " appearance categories.")
    end,
}

CN:RegisterCommand{
    name    = "appearances",
    aliases = { "transmog" },
    order   = 60,
    help    = "Summarize transmog appearance progress.",
    handler = function()
        local counts = Appearances.Summary()

        if counts.categories == 0 then
            Print("No appearance data yet. Run /cn appearancescan.")
            return
        end

        Print("Appearances: " .. counts.collected .. " / " .. counts.total
            .. " (" .. CN.PercentText(
                counts.total > 0 and (counts.collected / counts.total) or 0, 1)
            .. ")")

        Print("Categories complete: " .. counts.complete .. " / " .. counts.categories)

        local rows = Appearances.Remaining()

        for index = 1, math.min(5, #rows) do
            local row = rows[index]

            CN.PrintLine("  " .. row.name .. ": " .. row.collected .. " / " .. row.total
                .. " |cff8a8f96(" .. row.remaining .. " left)|r")
        end

        if #rows > 5 then
            Print("  |cff8a8f96... and " .. (#rows - 5) .. " more categories.|r")
        end
    end,
}
