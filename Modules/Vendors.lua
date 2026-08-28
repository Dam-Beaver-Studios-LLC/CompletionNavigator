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
local itemIndex = nil

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

        -- `zone` IS NOT STORED. 0.63.0.
        --
        -- The map id is right there and the client derives the name from it
        -- instantly, in the language the player is reading. Stored, it froze:
        -- a player who changed client language, or a zone Blizzard renamed,
        -- kept the old name in every tooltip until they happened to reopen
        -- that merchant.
        --
        -- Third copy of the rule migration 7 applied to `questHarvest` and
        -- 0.62.0 applied to rares. Derived at the one place that builds
        -- seller rows, below.
    end

    -- WHAT NOT TO WRITE TO DISK.
    --
    -- This used to store every item's NAME alongside its ID. The client
    -- already knows every item name and hands it back from its own cache in
    -- microseconds; storing them again made this the largest thing the addon
    -- wrote, at roughly twenty-four kilobytes per vendor. The whole
    -- SavedVariables file is rewritten on every logout and re-parsed on every
    -- login, so that is a cost paid twice per session for data the client was
    -- always going to give us for free.
    --
    -- The rule this establishes, and the reason it is worth writing down:
    -- persist only what the client CANNOT tell us. Names, collected states
    -- and completion flags are all re-derivable instantly. Cross-character
    -- knowledge, observations gathered over time and the player's own choices
    -- are not, and those are what this database is actually for.
    record.items = {}

    -- A NUMBER, NOT A TABLE.
    --
    -- Each item used to get a table of its own to hold two fields. A table
    -- per item costs far more in a saved-variables file than the value it
    -- carries, and a large vendor sells hundreds of items. Prices are stored
    -- directly; the handful bought with an extended cost -- tokens, currency
    -- -- are listed separately, because they are the exception.
    --
    -- Price is kept at all because the client only reports it while the
    -- merchant window is open, so unlike the item's name it genuinely cannot
    -- be recovered later.
    record.extendedCost = nil

    for _, item in ipairs(items) do
        if item.itemID then
            record.items[item.itemID] = item.price or 0

            if item.extendedCost then
                record.extendedCost = record.extendedCost or {}
                record.extendedCost[item.itemID] = true
            end
        end
    end

    record.itemCount = CN.CountKeys(record.items)

    store[npcID] = record

    -- The reverse index is now stale.
    Vendors.ForgetItemIndex()

    CN.MarkScanned("vendors")

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

    itemIndex = index

    return index
end

-- Published, because the recipe provider wants the same set: the items some
-- known vendor actually sells. Built on demand and held until the vendor
-- store changes, exactly as `FirstLocatedSeller` already relied on.
function Vendors.ItemIndex()
    return itemIndex or BuildItemIndex()
end

-- The one writer of the vendor store outside this file is a test, and a
-- reverse index nothing can invalidate is a cache that lies. Published for
-- the same reason `Sets.Forget` is.
function Vendors.ForgetItemIndex()
    itemIndex = nil
end

-- The candidate provider asks this question thousands of times per rebuild,
-- once per known recipe, and almost always gets no answer. WhoSells allocates
-- a result array every time it is called; this does not allocate at all until
-- there is something to return.
-- A SELLER ROW, WITH ITS ZONE DERIVED. 0.65.0.
--
-- `FirstLocatedSeller` handed back the raw store record, and migration 16
-- dropped `zone` from those rows because the map id derives it. `WhoSells`
-- was given the live derivation and the three consumers of THIS function were
-- not -- so a recommended recipe read "sold by Zen'shiri" with the zone line
-- silently gone, and the objective's own `zone` field was nil.
--
-- One shape for a seller, built in one place.
function Vendors.SellerFrom(record, npcID)
    if type(record) ~= "table" then
        return nil
    end

    return {
        npcID = npcID,
        name  = record.name,
        zone  = record.mapID and CN.Blizzard.GetMapName(record.mapID)
            or record.zone,
        mapID = record.mapID,
        x     = record.x,
        y     = record.y,
    }
end

function Vendors.FirstLocatedSeller(itemID)
    if not itemID then
        return nil
    end

    local index = itemIndex or BuildItemIndex()

    local npcIDs = index[itemID]

    if not npcIDs then
        return nil
    end

    local store = Store()

    for _, npcID in ipairs(npcIDs) do
        local record = store[npcID]

        if record and record.mapID and record.x and record.y then
            return Vendors.SellerFrom(record, npcID), npcID
        end
    end

    return nil
end

-- What a vendor charges for an item, in the shape callers expect, whichever
-- shape the store happens to be in. Old databases keep working until the
-- next merchant visit rewrites the row.
function Vendors.PriceOf(record, itemID)
    local stored = record and record.items and record.items[itemID]

    if stored == nil then
        return nil
    end

    if type(stored) == "table" then
        return stored.price, stored.extendedCost and true or false
    end

    return stored, (record.extendedCost and record.extendedCost[itemID]) or false
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
            -- Through the one builder, so this and `FirstLocatedSeller`
            -- cannot describe a seller differently again. 0.65.0.
            local seller = Vendors.SellerFrom(record, npcID)

            seller.price = Vendors.PriceOf(record, itemID)

            table.insert(sellers, seller)
        end
    end

    return sellers
end

-- Finds an item by name across every recorded vendor. This is what makes
-- "who sells Flask of Testing" work without knowing an item ID.
--
-- RETURNS THE NAME AS WELL, because both callers print a headline. 0.66.0.
-- This function already resolved the name -- it holds it in `bestName` to
-- pick the shortest match -- and then threw it away, so `/cn sells Traveler's
-- Tundra Mount` answered "Item 44554 is sold by:": the addon reciting the
-- number it had just looked up from the words the player typed.
function Vendors.FindItem(text)
    if not text or text == "" then
        return nil, {}, nil
    end

    local itemID = CN.ToID(text)

    if itemID then
        local named = Blizzard.GetItemName(itemID)

        return itemID, Vendors.WhoSells(itemID),
               (named ~= "" and named) or nil
    end

    local needle  = string.lower(text)
    local matches = {}

    for npcID, record in pairs(Store()) do
        for id in pairs(record.items or {}) do
            -- Resolved from the client's item cache rather than from a copy
            -- of it kept on disk. Unknown names are skipped rather than
            -- guessed; the client fills its cache as items are seen.
            local name = Blizzard.GetItemName(id)

            if name and string.find(string.lower(name), needle, 1, true) then
                matches[id] = name
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
        return nil, {}, nil
    end

    return bestID, Vendors.WhoSells(bestID), bestName
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
    local professions = CN:GetModule("Professions")

    if not professions then
        return {}
    end

    local known = professions.CharacterRecipes() or {}
    local names = professions.RecipeNames()

    local playerMap = select(1, CN.GetPlayerPosition())

    -- WALK WHAT CAN PRODUCE A ROW, NOT WHAT CANNOT. 0.61.0.
    --
    -- This walked `RecipeNames` -- every recipe the addon has ever seen a
    -- name for, 2,503 of them on an established account -- and asked
    -- `FirstLocatedSeller` about each. The answer is nil for all but a
    -- handful, because a recipe only produces a row if some vendor in the
    -- player's own captured vendor data sells it. Measured: 2,503 index
    -- lookups per rebuild to emit one candidate.
    --
    -- The item index is the set of items a KNOWN vendor sells, which is the
    -- necessary condition. It is built from the vendor store either way --
    -- `FirstLocatedSeller` builds it on its first call -- so iterating it
    -- costs nothing extra and skips the 2,400 recipes that could never have
    -- qualified.
    --
    -- The name is still required, so the check moves inside rather than
    -- disappearing: a recipe with a seller and no name has nothing to put on
    -- a row.
    local sellable = Vendors.ItemIndex()

    -- ONE LOOKUP PER ITEM. 0.72.0. See the note in `Modules/Toys.lua`: the
    -- same duplication, in the same shape, missed by the same fix.
    local sellers = {}

    local function SellerFor(itemID)
        local held = sellers[itemID]

        if held == nil then
            held = Vendors.FirstLocatedSeller(itemID) or false
            sellers[itemID] = held
        end

        return held or nil
    end

    local candidates, considered, dropped = CN.CollectBounded(sellable, nil,
        function(itemID)
            if known[itemID] or not names[itemID] then
                return nil
            end

            if CN.IsIgnored(CN.objectiveTypes.RECIPE, itemID)
                or CN.IsDeferred(CN.objectiveTypes.RECIPE, itemID) then
                return nil
            end

            local seller = SellerFor(itemID)

            if not seller then
                return nil
            end

            -- A recipe you can walk to in this zone beats one across the
            -- continent, and that is the only distinction worth ranking here.
            return (seller.mapID == playerMap) and 3 or 2
        end,
        -- THE SECOND ARGUMENT IS THE SOURCE'S VALUE, AND THE SOURCE CHANGED.
        --
        -- `CN.CollectBounded` calls `build(id, source[id], value)`. While the
        -- source was `RecipeNames` that second argument was the name; now the
        -- source is the item index, it is the ARRAY OF NPC IDS that sell the
        -- item. Assigning it to `name` did not throw -- every reader wraps the
        -- name in `tostring` -- it rendered `table: 0x...` on the recommended
        -- row, in the HUD, on the map pin and in the data-broker feed.
        --
        -- A defect that shows a table address to the player and passes every
        -- test, because nothing asserts what a recipe row is CALLED. The name
        -- comes from `names`, which `evaluate` above has already required to
        -- be present.
        function(itemID)
            local seller = SellerFor(itemID)

            if not seller then
                return nil
            end

            local recipeName = names[itemID]

            local reasons = { "sold by " .. tostring(seller.name) }

            if seller.zone then
                table.insert(reasons, "in " .. seller.zone)
            end

            -- ONE CALL, BOTH ANSWERS. 0.71.0.
            --
            -- 0.70.0 added the confidence flag here with a second
            -- `CN.TravelCost` call inside a `select(2, ...)`, and the travel
            -- model deliberately does not cache a refusal -- so for any
            -- seller it could not route, both calls ran a full estimate:
            -- four client conversions and a scan of the flight network,
            -- twice, per row, in the two highest-volume located providers.
            --
            -- Worse than the cost: the two calls are independent, so a
            -- coordinate conversion that failed between them produced a row
            -- with a real measured journey and no flag saying so -- silently
            -- losing its distance line and its deadline guard.
            local travel, costed = CN.TravelCost(seller.mapID, seller.x, seller.y)

            return CN.NewObjective({
                id              = itemID,
                type            = CN.objectiveTypes.RECIPE,
                name            = recipeName,
                mapID           = seller.mapID,
                x               = seller.x,
                y               = seller.y,
                completionValue = 2,
                -- COSTED, NOT GUESSED. This charged a flat 25 for anything
                -- outside the current zone while holding the seller's exact
                -- coordinates -- so a vendor ninety seconds away in the next
                -- zone was charged twenty-five where a quest at the identical
                -- spot was charged three. A systematic twenty-two point
                -- penalty against exactly the collection types this file
                -- exists to surface.
                travelCost      = travel,
                travelCosted    = costed or nil,
                reasons         = reasons,
            })
        end)

    CN.providerTruncation["Vendors"] = { considered = considered, dropped = dropped }

    return candidates
end, { events = { "MERCHANT_SHOW", "TRADE_SKILL_LIST_UPDATE", "ZONE_CHANGED_NEW_AREA" }, cooldown = 5 })

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
            Print("|cff8a8f96Open a merchant window and the addon records "
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

        local itemID, sellers, itemName = Vendors.FindItem(args)

        if not itemID or #sellers == 0 then
            Print("Nothing recorded matches: " .. args)
            Print("|cff8a8f96Only vendors you have opened are known.|r")
            return
        end

        Print(tostring(itemName or ("Item " .. itemID))
            .. " |cff8a8f96(" .. itemID .. ")|r is sold by:")

        for index, seller in ipairs(sellers) do
            CN.PrintLine("  " .. index .. ". " .. tostring(seller.name)
                .. (seller.zone and (" |cff8a8f96in " .. seller.zone .. "|r") or "")
                .. (seller.x and string.format(" |cff8a8f96%.1f, %.1f|r",
                    seller.x * 100, seller.y * 100) or ""))
        end

        Print("|cffffc74f/cn tovendor " .. itemID .. "|r to set a waypoint.")
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

        local itemID, sellers, itemName = Vendors.FindItem(args)

        if not itemID or #sellers == 0 then
            Print("Nothing recorded matches: " .. args)
            return
        end

        for _, seller in ipairs(sellers) do
            if seller.mapID and seller.x and seller.y then
                CN.NavigateToObjective({
                    id    = seller.npcID,
                    type  = CN.objectiveTypes.VENDOR,
                    name  = seller.name
                        .. (itemName and (" (" .. itemName .. ")") or ""),
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
