-- Modules/Toys.lua
-- Completion Navigator :: toy box.
--
-- Account-wide. The toy box, like the pet journal, only reports what the
-- player's current filters allow, so the scan widens them first.

local ADDON_NAME, CN = ...

local Toys = CN:RegisterModule("Toys")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

local function Store()
    return CN.Account("toys")
end

Toys.Store = Store

------------------------------------------------------------
-- SCAN
------------------------------------------------------------

function Toys.Scan()
    if not C_ToyBox then
        return 0, 0, 0
    end

    local store = Store()

    local seen, collected, missing = 0, 0, 0

    Blizzard.WithAllToysShown(function()
        local total = Blizzard.GetNumToys()

        for index = 1, total do
            local toy = Blizzard.GetToyByIndex(index)

            if toy and toy.itemID then
                local existing = store[toy.itemID]

                store[toy.itemID] = {
                    itemID    = toy.itemID,
                    name      = toy.name,
                    collected = toy.collected,
                    firstSeen = existing and existing.firstSeen or time(),
                    lastSeen  = time(),
                }

                seen = seen + 1

                if toy.collected then
                    collected = collected + 1
                else
                    missing = missing + 1
                end
            end
        end
    end)

    CN.MarkScanned("toys")

    return seen, collected, missing
end

------------------------------------------------------------
-- SUMMARY
------------------------------------------------------------

function Toys.Summary()
    local counts = { known = 0, collected = 0, missing = 0 }

    for _, record in pairs(Store()) do
        counts.known = counts.known + 1

        if record.collected then
            counts.collected = counts.collected + 1
        else
            counts.missing = counts.missing + 1
        end
    end

    return counts
end

function Toys.Resolve(text)
    local itemID = CN.ToID(text)

    if itemID and Store()[itemID] then
        return itemID
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

    return matches[1].id
end

------------------------------------------------------------
-- CANDIDATES
------------------------------------------------------------

-- Toys are the one collection whose IDs line up with the vendor database:
-- both are keyed by item ID, so "which recorded vendor sells this toy" is an
-- exact join rather than a guess. That turns an uncollected toy into an
-- objective with real coordinates.
--
-- Toys with no recorded seller are deliberately NOT emitted. The toy box has
-- no source field, so without a vendor there is nothing to say beyond "you do
-- not have this", which the Collections tab already covers.
CN.RegisterCandidateProvider("Toys", function()
    local vendors = CN:GetModule("Vendors")

    if not vendors then
        return {}
    end

    local playerMap = select(1, CN.GetPlayerPosition())

    local candidates, considered, dropped = CN.CollectBounded(Store(), nil,
        function(itemID, record)
            if record.collected then
                return nil
            end

            if CN.IsIgnored(CN.objectiveTypes.TOY, itemID)
                or CN.IsDeferred(CN.objectiveTypes.TOY, itemID) then
                return nil
            end

            local seller = vendors.FirstLocatedSeller(itemID)

            if not seller then
                return nil
            end

            return (seller.mapID == playerMap) and 3 or 2
        end,
        function(itemID, record, value)
            local seller = vendors.FirstLocatedSeller(itemID)

            if not seller then
                return nil
            end

            local reasons = { "sold by " .. tostring(seller.name) }

            if seller.zone then
                table.insert(reasons, "in " .. seller.zone)
            end

            return CN.NewObjective({
                id              = itemID,
                type            = CN.objectiveTypes.TOY,
                name            = record.name,
                mapID           = seller.mapID,
                x               = seller.x,
                y               = seller.y,
                zone            = seller.zone,
                accountWide     = true,
                completionValue = value,
                travelCost      = (seller.mapID == playerMap) and 2 or 25,
                reasons         = reasons,
            })
        end)

    CN.providerTruncation["Toys"] = { considered = considered, dropped = dropped }

    return candidates
end, { events = { "NEW_TOY_ADDED", "MERCHANT_SHOW" }, cooldown = 5 })

------------------------------------------------------------
-- ELIGIBILITY
------------------------------------------------------------

CN.RegisterEligibilityChecker(CN.objectiveTypes.TOY, function(itemID)
    local states = CN.objectiveStates
    local record = Store()[itemID]

    if not record then
        return states.UNKNOWN, "No toy data; run /cn toyscan", nil
    end

    if record.collected then
        return states.COMPLETED, "Already collected", record.name
    end

    return states.AVAILABLE, nil, nil
end)

------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

CN:RegisterEvent("NEW_TOY_ADDED", function()
    Toys.Scan()
    DebugPrint("Toy added; toy box rescanned.")
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "toyscan",
    order   = 56,
    help    = "Scan the toy box.",
    handler = function()
        local seen, collected, missing = Toys.Scan()

        Print("Scanned " .. seen .. " toys.")
        Print("Collected: " .. collected .. "   Missing: " .. missing)
    end,
}

CN:RegisterCommand{
    name    = "toys",
    order   = 57,
    help    = "Summarize toy collection.",
    handler = function()
        local counts = Toys.Summary()

        if counts.known == 0 then
            Print("No toy data yet. Run /cn toyscan.")
            return
        end

        Print("Toys known to the toy box: " .. counts.known)
        Print("Collected: " .. counts.collected .. "   Missing: " .. counts.missing)
    end,
}

CN:RegisterCommand{
    name    = "toy",
    args    = "<itemID or name>",
    order   = 58,
    help    = "Show one toy's collection state.",
    handler = function(args)
        if args == "" then
            Print("Usage: /cn toy <itemID or name>")
            return
        end

        local itemID = Toys.Resolve(args)

        if not itemID then
            Print("No known toy matches: " .. args)
            return
        end

        local record = Store()[itemID]

        Print(record.name .. " |cff999999(" .. itemID .. ")|r")
        Print("Collected: " .. CN.YesNo(record.collected))
    end,
}
