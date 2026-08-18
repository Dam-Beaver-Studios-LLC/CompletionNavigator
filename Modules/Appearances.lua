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

------------------------------------------------------------
-- SCAN
------------------------------------------------------------

function Appearances.Scan()
    if not C_TransmogCollection then
        return 0
    end

    local store      = Store()
    local categories = Blizzard.GetAppearanceCategories()

    for _, category in ipairs(categories) do
        store[category.categoryID] = {
            categoryID = category.categoryID,
            name       = category.name,
            collected  = category.collected,
            total      = category.total,
            lastSeen   = time(),
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
                name      = record.name,
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
                name       = record.name,
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
            .. string.format(" (%.1f%%)",
                counts.total > 0 and (counts.collected / counts.total * 100) or 0))

        Print("Categories complete: " .. counts.complete .. " / " .. counts.categories)

        local rows = Appearances.Remaining()

        for index = 1, math.min(5, #rows) do
            local row = rows[index]

            Print("  " .. row.name .. ": " .. row.collected .. " / " .. row.total
                .. " |cff999999(" .. row.remaining .. " left)|r")
        end

        if #rows > 5 then
            Print("  |cff999999... and " .. (#rows - 5) .. " more categories.|r")
        end
    end,
}
