-- Modules/Vendors.lua
-- Completion Navigator :: who sells what, and where they stand.
--
-- This is the module the flagship example in the design needs:
--
--   Recipe X is sold by Vendor A. Vendor A is in <zone> at <coords>.
--   The recipe requires Revered with Faction B. This character is Honored.
--   Another character is already Revered and has the profession.
--   -> Switch to that character and buy it.
--
-- Every other piece of that already exists. The missing link was that
-- nothing knew where anything is sold.
--
-- Vendor inventories are only readable while the merchant window is open --
-- the same client restriction as trade skill recipes. So this records every
-- vendor you talk to, permanently and account-wide, and the database grows
-- as you play rather than shipping stale.

local ADDON_NAME, CN = ...

local Vendors = CN:RegisterModule("Vendors")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

local function Store()
    return CN.Account("vendors")
end

-- Reverse index: itemID -> { npcID, npcID, ... }. Rebuilt from the vendor
-- store rather than persisted, so it can never drift out of sync with it.
local itemIndex, itemIndexBuiltAt = nil, 0

Vendors.Store = Store

------------------------------------------------------------
-- RECORDING
------------------------------------------------------------

function Vendors.CaptureOpenMerchant()
    local npcID, npcName = Blizzard.GetInteractingNPC()

    if not npcID then
        return false, 0
    end

    local items = Blizzard.GetMerchantItems()

    if #items == 0 then
        return false, 0
    end

    local store  = Store()
    local record = store[npcID] or { npcID = npcID, firstSeen = time() }

    record.name     = npcName or record.name
    record.lastSeen = time()

    local mapID, x, y = CN.GetPlayerPosition()

    -- Keep the first location seen; vendors do not move, and later readings
    -- are just wherever you happened to be standing when you opened the
    -- window a second time.
    if mapID and x and y and not record.mapID then
        record.mapID = mapID
        record.x     = math.floor(x * 10000 + 0.5) / 10000
        record.y     = math.floor(y * 10000 + 0.5) / 10000
        record.zone  = Blizzard.GetMapName(mapID)
    end

    record.items = {}

    for _, item in ipairs(items) do
        if item.itemID then
            record.items[item.itemID] = {
                name         = item.name,
                price        = item.price,
                extendedCost = item.extendedCost,
            }
        end
    end

    record.itemCount = CN.CountKeys(record.items)

    store[npcID] = record

    -- The reverse index is now stale.
    itemIndex = nil

    CN.Account("collectionScans").vendors = time()

    return true, record.itemCount
end

------------------------------------------------------------
-- LOOKUP
------------------------------------------------------------

local function BuildItemIndex()
    local index = {}

    for npcID, record in pairs(Store()) do
        for itemID in pairs(record.items or {}) do
            index[itemID] = index[itemID] or {}
            table.insert(index[itemID], npcID)
        end
    end

    itemIndex        = index
    itemIndexBuiltAt = time()

    return index
end

function Vendors.WhoSells(itemID)
    if not itemID then
        return {}
    end

    local index = itemIndex or BuildItemIndex()

    local sellers = {}

    for _, npcID in ipairs(index[itemID] or {}) do
        local record = Store()[npcID]

        if record then
            table.insert(sellers, {
                npcID = npcID,
                name  = record.name,
                zone  = record.zone,
                mapID = record.mapID,
                x     = record.x,
                y     = record.y,
                item  = record.items and record.items[itemID],
            })
        end
    end

    return sellers
end

-- Finds an item by name across every recorded vendor. This is what makes
-- "who sells Flask of Testing" work without knowing an item ID.
function Vendors.FindItem(text)
    if not text or text == "" then
        return nil, {}
    end

    local itemID = CN.ToID(text)

    if itemID then
        return itemID, Vendors.WhoSells(itemID)
    end

    local needle  = string.lower(text)
    local matches = {}

    for npcID, record in pairs(Store()) do
        for id, item in pairs(record.items or {}) do
            if item.name and string.find(string.lower(item.name), needle, 1, true) then
                matches[id] = item.name
            end
        end
    end

    local bestID, bestName

    for id, name in pairs(matches) do
        if not bestName or #name < #bestName then
            bestID, bestName = id, name
        end
    end

    if not bestID then
        return nil, {}
    end

    return bestID, Vendors.WhoSells(bestID)
end

function Vendors.Summary()
    local counts = { vendors = 0, items = 0, located = 0 }

    local uniqueItems = {}

    for _, record in pairs(Store()) do
        counts.vendors = counts.vendors + 1

        if record.x and record.y then
            counts.located = counts.located + 1
        end

        for itemID in pairs(record.items or {}) do
            uniqueItems[itemID] = true
        end
    end

    counts.items = CN.CountKeys(uniqueItems)

    return counts
end

------------------------------------------------------------
-- RECIPE LINKING
------------------------------------------------------------

-- The payoff: a recipe this character does not know, sold by a vendor whose
-- location is recorded, becomes an objective with real coordinates.
CN.RegisterCandidateProvider("Vendors", function()
    local candidates = {}

    local professions = CN:GetModule("Professions")

    if not professions then
        return candidates
    end

    local known = professions.CharacterRecipes() or {}
    local names = professions.RecipeNames()

    local playerMap = select(1, CN.GetPlayerPosition())

    for itemID, recipeName in pairs(names) do
        if not known[itemID]
            and not CN.IsIgnored(CN.objectiveTypes.RECIPE, itemID)
            and not CN.IsDeferred(CN.objectiveTypes.RECIPE, itemID) then

            local sellers = Vendors.WhoSells(itemID)

            for _, seller in ipairs(sellers) do
                if seller.mapID and seller.x and seller.y then
                    local reasons = {
                        "sold by " .. tostring(seller.name),
                    }

                    if seller.zone then
                        table.insert(reasons, "in " .. seller.zone)
                    end

                    table.insert(candidates, CN.NewObjective({
                        id              = itemID,
                        type            = CN.objectiveTypes.RECIPE,
                        name            = recipeName,
                        mapID           = seller.mapID,
                        x               = seller.x,
                        y               = seller.y,
                        completionValue = 2,
                        travelCost      = (seller.mapID == playerMap) and 2 or 25,
                        reasons         = reasons,
                    }))

                    break
                end
            end
        end
    end

    return candidates
end)

------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

CN:RegisterEvent("MERCHANT_SHOW", function()
    local captured, count = Vendors.CaptureOpenMerchant()

    if captured then
        DebugPrint("Recorded vendor with " .. count .. " items.")
    end
end)

CN:RegisterEvent("MERCHANT_UPDATE", function()
    Vendors.CaptureOpenMerchant()
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "vendors",
    order   = 79,
    help    = "Summarize recorded vendors.",
    handler = function()
        local counts = Vendors.Summary()

        if counts.vendors == 0 then
            Print("No vendors recorded yet.")
            Print("|cff999999Open a merchant window and the addon records "
                .. "what they sell and where they stand.|r")
            return
        end

        Print("Vendors recorded: " .. counts.vendors
            .. " (" .. counts.located .. " with coordinates)")
        Print("Distinct items seen: " .. counts.items)
    end,
}

CN:RegisterCommand{
    name    = "sells",
    aliases = { "whosells" },
    args    = "<itemID or name>",
    order   = 80,
    help    = "Find which recorded vendor sells something.",
    handler = function(args)
        if args == "" then
            Print("Usage: /cn sells <itemID or name>")
            return
        end

        local itemID, sellers = Vendors.FindItem(args)

        if not itemID or #sellers == 0 then
            Print("Nothing recorded matches: " .. args)
            Print("|cff999999Only vendors you have opened are known.|r")
            return
        end

        Print("Item " .. itemID .. " is sold by:")

        for index, seller in ipairs(sellers) do
            Print("  " .. index .. ". " .. tostring(seller.name)
                .. (seller.zone and (" |cff999999in " .. seller.zone .. "|r") or "")
                .. (seller.x and string.format(" |cff999999%.1f, %.1f|r",
                    seller.x * 100, seller.y * 100) or ""))
        end

        Print("|cffffff00/cn tovendor " .. itemID .. "|r to set a waypoint.")
    end,
}

CN:RegisterCommand{
    name    = "tovendor",
    args    = "<itemID or name>",
    order   = 81,
    help    = "Navigate to a vendor that sells something.",
    handler = function(args)
        if args == "" then
            Print("Usage: /cn tovendor <itemID or name>")
            return
        end

        local itemID, sellers = Vendors.FindItem(args)

        if not itemID or #sellers == 0 then
            Print("Nothing recorded matches: " .. args)
            return
        end

        for _, seller in ipairs(sellers) do
            if seller.mapID and seller.x and seller.y then
                CN.NavigateToObjective({
                    id    = seller.npcID,
                    type  = CN.objectiveTypes.VENDOR,
                    name  = seller.name,
                    mapID = seller.mapID,
                    x     = seller.x,
                    y     = seller.y,
                })

                return
            end
        end

        Print("No recorded seller has coordinates yet.")
    end,
}

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
