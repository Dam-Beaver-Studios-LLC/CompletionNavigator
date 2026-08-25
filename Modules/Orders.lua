-- Modules/Orders.lua
-- Completion Navigator :: crafting orders, and a standing question about
-- Delves.
--
-- CRAFTING ORDERS.
--
-- The addon has tracked recipes since 0.14.0 and never noticed that other
-- people can pay you to use them, or that an order you placed yourself
-- finishes and then sits there. Both are time-limited -- an order expires --
-- and both are knowable from the client.
--
-- What it does NOT do is browse the order board. That requires standing at a
-- crafting table with the frame open, and an addon that pokes at that UI to
-- read it is an addon that fights the player for control of their own window.
-- This reports what the client will answer without being asked to open
-- anything: your own orders, and whether any of them are ready to collect.
--
-- DELVES.
--
-- Assessed twice and deliberately not built, for a reason that is written
-- down rather than remembered: `C_DelvesUI` exposes interface plumbing --
-- minimum level, which button to show -- and not progress. Delve credit
-- toward the Great Vault already flows through the World row, so a Delves
-- module would duplicate working behaviour with guesswork.
--
-- The decision has a trigger rather than a date: if a build ever exposes a
-- progress API, the probe below starts answering and the self-test says so.
-- That is the difference between a decision and a thing everyone forgot.

local ADDON_NAME, CN = ...

local Orders = CN:RegisterModule("Orders")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint

------------------------------------------------------------
-- CRAFTING ORDERS
------------------------------------------------------------

function Orders.IsAvailable()
    return C_CraftingOrders ~= nil
end

-- Orders this character placed, as the client last reported them. The list is
-- populated by the game when the order frame is opened, so this can be empty
-- and empty is not an error -- it means "nothing known yet", and the command
-- says so rather than claiming you have no orders.
function Orders.Mine()
    if not Orders.IsAvailable() or not C_CraftingOrders.GetMyOrders then
        return nil
    end

    local ok, orders = pcall(C_CraftingOrders.GetMyOrders)

    if not ok or type(orders) ~= "table" then
        return nil
    end

    local rows = {}

    for _, order in ipairs(orders) do
        if type(order) == "table" then
            table.insert(rows, {
                orderID    = order.orderID,
                itemID     = order.itemID,
                itemName   = order.itemName,
                expiresIn  = order.expirationTime
                    and math.max(0, order.expirationTime - time()) or nil,
                state      = order.orderState,
                crafter    = order.crafterName,
            })
        end
    end

    return rows
end

-- Whether the client says something is waiting to be collected.
function Orders.HasClaimable()
    if not Orders.IsAvailable() then
        return false
    end

    if C_CraftingOrders.GetClaimedOrder then
        local ok, claimed = pcall(C_CraftingOrders.GetClaimedOrder)

        if ok and claimed then
            return true
        end
    end

    return false
end

------------------------------------------------------------
-- CANDIDATES
------------------------------------------------------------

-- Deliberately narrow. An order that is finished, or one about to expire, is
-- a real next action with a real deadline. "Someone somewhere might want a
-- flask" is not, and the addon does not have the data to say it anyway.
Orders.expiryHorizonSeconds = 86400

CN.RegisterCandidateProvider("Orders", function()
    local candidates = {}

    local mine = Orders.Mine()

    if not mine then
        return candidates
    end

    for _, order in ipairs(mine) do
        if order.expiresIn and order.expiresIn <= Orders.expiryHorizonSeconds
            and not CN.IsIgnored(CN.objectiveTypes.RECIPE, order.orderID)
            and not CN.IsDeferred(CN.objectiveTypes.RECIPE, order.orderID) then

            local session = CN:GetModule("Session")

            table.insert(candidates, CN.NewObjective({
                id               = order.orderID,
                type             = CN.objectiveTypes.RECIPE,
                name             = "Crafting order: "
                    .. tostring(order.itemName or order.itemID or "?"),
                completionValue  = 3,
                limitedTimeBonus = 2,
                travelCost       = CN.placelessCost,
                expiresIn        = order.expiresIn,
                reasons          = {
                    "a crafting order you placed expires in "
                        .. ((session and session.FormatDuration
                            and session.FormatDuration(order.expiresIn))
                            or "less than a day"),
                },
            }))
        end
    end

    if Orders.HasClaimable() then
        table.insert(candidates, CN.NewObjective({
            id               = "claim",
            type             = CN.objectiveTypes.RECIPE,
            name             = "Collect your finished crafting order",
            completionValue  = 5,
            limitedTimeBonus = 2,
            travelCost       = CN.placelessCost,
            reasons          = { "it is done and waiting at a crafting table" },
        }))
    end

    return candidates
end, {
    events   = { "CRAFTINGORDERS_UPDATE_ORDER_COUNT", "CRAFTINGORDERS_CLAIM_ORDER_RESPONSE" },

    -- VOLATILE, BECAUSE THIS CARRIES A DEADLINE.
    --
    -- `expiresIn` is computed at build time and feeds the urgency curve --
    -- the heaviest term in the table -- and is printed verbatim in the
    -- reason. Without this the row rebuilt only when the player touched the
    -- crafting-order system, so six hours later it still said "expires in 6
    -- hours" and still scored as though six hours remained.
    --
    -- Exactly the defect 0.59.0 fixed for calendar events, in the one
    -- deadline-carrying provider that was not volatile. The thirty-second
    -- cooldown already bounds what this costs.
    volatile = true,
    cooldown = 30,
})

------------------------------------------------------------
-- THE DELVES PROBE
------------------------------------------------------------

-- Names the exact API that would change the decision, so that "we looked and
-- there was nothing" does not decay into "nobody ever checked".
Orders.delveProgressAPIs = {
    "GetDelvesProgress",
    "GetDelveProgressInfo",
    "GetSeasonProgress",
}

-- Returns available, detail.
function Orders.DelveProgressAvailable()
    if not C_DelvesUI then
        return false, "C_DelvesUI is not present in this client"
    end

    for _, name in ipairs(Orders.delveProgressAPIs) do
        if type(C_DelvesUI[name]) == "function" then
            return true, "C_DelvesUI." .. name .. " exists" .. CN.DASH .. "Delve progress "
                .. "is now readable, and this addon should be tracking it"
        end
    end

    return false, "C_DelvesUI exists but exposes no progress function; Delve "
        .. "credit still reaches the addon through the Great Vault's World row"
end

CN.RegisterSelfTest{
    area = "instances",
    name = "Delve progress is still unavailable",
    run  = function()
        local available, detail = Orders.DelveProgressAvailable()

        if available then
            -- A PASS would be wrong here. This check exists to notice a
            -- decision going stale, and the answer that needs acting on is
            -- the one that must stand out.
            return "FAIL", detail
        end

        return "SKIP", detail
    end,
}

------------------------------------------------------------
-- COMMAND
------------------------------------------------------------

CN:RegisterCommand{
    name    = "orders",
    order   = 27,
    help    = "Crafting orders you have placed, and anything ready to collect.",
    handler = function()
        if not Orders.IsAvailable() then
            Print("This client has no crafting order system.")
            return
        end

        local mine = Orders.Mine()

        if not mine then
            Print("Nothing known yet.")
            Print("|cff8a8f96The game only hands the addon your order list "
                .. "once you have opened the order frame this session. It is "
                .. "not asked to open on your behalf.|r")
            return
        end

        if #mine == 0 then
            Print("No orders outstanding.")
        else
            Print(#mine .. " order" .. CN.Pluralize(#mine, "") .. ":")

            local session = CN:GetModule("Session")

            for _, order in ipairs(mine) do
                local line = "  " .. tostring(order.itemName or order.itemID)

                if order.crafter then
                    line = line .. " |cff8a8f96claimed by "
                        .. order.crafter .. "|r"
                end

                if order.expiresIn then
                    line = line .. " |cffffc74fexpires in "
                        .. ((session and session.FormatDuration
                            and session.FormatDuration(order.expiresIn))
                            or "soon") .. "|r"
                end

                CN.PrintLine(line)
            end
        end

        if Orders.HasClaimable() then
            Print("|cff73b873Something is finished and waiting to be "
                .. "collected.|r")
        end
    end,
}

return Orders
