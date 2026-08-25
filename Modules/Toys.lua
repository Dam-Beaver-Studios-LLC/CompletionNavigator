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
                store[toy.itemID] = {
                    itemID    = toy.itemID,
                    name      = toy.name,
                    collected = toy.collected,
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
                -- COSTED, NOT GUESSED. This charged a flat 25 for anything
                -- outside the current zone while holding the seller's exact
                -- coordinates -- so a vendor ninety seconds away in the next
                -- zone was charged twenty-five where a quest at the identical
                -- spot was charged three. A systematic twenty-two point
                -- penalty against exactly the collection types this file
                -- exists to surface.
                travelCost      = CN.TravelCost(seller.mapID, seller.x, seller.y),
                reasons         = reasons,
            })
        end)

    CN.providerTruncation["Toys"] = { considered = considered, dropped = dropped }

    return candidates
end, { -- `ZONE_CHANGED_NEW_AREA` because this provider reads the player's
    -- position: it scores a vendor in your current zone above one elsewhere
    -- and stamps a travel cost from where you are standing. Every other
    -- located provider declares it; this was the only one that did not, so
    -- flying to another zone left every toy carrying the cost it had in the
    -- last one until a loading screen happened along.
    events = { "NEW_TOY_ADDED", "MERCHANT_SHOW", "ZONE_CHANGED_NEW_AREA" }, cooldown = 5 })

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

        Print(record.name .. " |cff8a8f96(" .. itemID .. ")|r")
        Print("Collected: " .. CN.YesNo(record.collected))
    end,
}

-- AND ONCE AT LOGIN. 0.62.0.
--
-- This store relied entirely on `NEW_TOY_ADDED`, which covers
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
    CN.Guard("Toys.Scan", Toys.Scan)
end)
