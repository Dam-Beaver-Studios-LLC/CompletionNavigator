-- Modules/Inventory.lua
-- Completion Navigator :: what you are already carrying.
--
-- WHAT WAS MISSING.
--
-- `C_Container` appeared nowhere in this addon. Twenty-nine releases of
-- answering "what should I do next?" without ever looking in the player's
-- bags, which is where a surprising amount of the answer already is:
--
--   * The item that STARTS a quest, sitting in a bag since a boss dropped it.
--   * Forty of the fifty things a quest wants, so the answer is "ten more",
--     not "go and do that quest".
--   * A recipe you already own and have not learned.
--   * A mount, a pet or a toy in item form, uncollected and in a bag.
--
-- Every one of those is a next action the addon could not see, and three of
-- them are the cheapest actions available: the walk is zero yards.
--
-- WHAT IT DOES NOT DO.
--
-- It does not use anything, learn anything, sell anything or move anything. It
-- reads. The standing rule in this addon is that it prompts and never acts,
-- and an addon that starts using items out of your bags is an addon that will
-- eventually use the wrong one.

local ADDON_NAME, CN = ...

local Inventory = CN:RegisterModule("Inventory")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

------------------------------------------------------------
-- READING THE BAGS
------------------------------------------------------------

-- Backpack plus four bags, and the reagent bag where the client has one.
-- Numbers rather than a constant because the constants have been renamed
-- twice and the numbers have not changed since 2004.
Inventory.bagIDs = { 0, 1, 2, 3, 4, 5 }

-- Bank containers. Read only while the bank is open -- the client refuses
-- otherwise, and a cached answer about a bank you are not standing at is a
-- claim the addon cannot support.
Inventory.bankIDs = { -1, 6, 7, 8, 9, 10, 11, 12 }

function Inventory.IsAvailable()
    return C_Container ~= nil
        and C_Container.GetContainerNumSlots ~= nil
        and C_Container.GetContainerItemInfo ~= nil
end

-- Every item in a set of containers, as { itemID, count, link, quality, bag,
-- slot, questItem, questID, isUsable }.
function Inventory.Scan(containers)
    local items = {}

    if not Inventory.IsAvailable() then
        return items
    end

    for _, bag in ipairs(containers or Inventory.bagIDs) do
        local gotSlots, slots = pcall(C_Container.GetContainerNumSlots, bag)

        if gotSlots and type(slots) == "number" and slots > 0 then
            for slot = 1, slots do
                local gotInfo, info =
                    pcall(C_Container.GetContainerItemInfo, bag, slot)

                if gotInfo and type(info) == "table" and info.itemID then
                    table.insert(items, {
                        itemID   = info.itemID,
                        count    = info.stackCount or 1,
                        link     = info.hyperlink,
                        quality  = info.quality,
                        bag      = bag,
                        slot     = slot,
                        questItem = info.hasNoValue and true or false,
                    })
                end
            end
        end
    end

    return items
end

-- How many of an item the player is carrying, across every bag.
function Inventory.Count(itemID)
    if not itemID then
        return 0
    end

    if C_Item and C_Item.GetItemCount then
        local ok, count = pcall(C_Item.GetItemCount, itemID)

        if ok and count then
            return count
        end
    end

    if GetItemCount then
        local ok, count = pcall(GetItemCount, itemID)

        if ok and count then
            return count
        end
    end

    return 0
end

------------------------------------------------------------
-- WHAT IS ACTIONABLE IN THERE
------------------------------------------------------------

-- Items that start a quest. The client will say so directly, which makes this
-- the single most reliable thing in the file -- and the addon has been
-- ignoring it since the first build.
function Inventory.QuestStarters()
    local starters = {}

    if not Inventory.IsAvailable() or not C_Container.GetContainerItemQuestInfo then
        return starters
    end

    for _, item in ipairs(Inventory.Scan()) do
        local ok, info = pcall(C_Container.GetContainerItemQuestInfo,
            item.bag, item.slot)

        if ok and type(info) == "table" and info.questID and not info.isActive then
            item.questID = info.questID

            table.insert(starters, item)
        end
    end

    return starters
end

-- Collectible items sitting in a bag: a mount, a pet, a toy or a recipe the
-- player owns and has not used. Zero yards from where they are standing.
function Inventory.UncollectedItems()
    local found = {}

    for _, item in ipairs(Inventory.Scan()) do
        -- Collection state comes from the journals, which are the authority.
        -- Asking "is this item a mount" and "do I own that mount" are two
        -- different questions and only the second one keeps the addon from
        -- telling somebody to learn what they already have.
        local mountID = Blizzard.GetMountFromItem(item.itemID)

        local mount = mountID and Blizzard.GetMountByID(mountID)

        if mount and not mount.collected then
            item.kind = CN.objectiveTypes.MOUNT
            item.collectibleID = mountID

            table.insert(found, item)
        else
            local speciesID = Blizzard.GetPetSpeciesFromItem(item.itemID)

            local pets = CN:GetModule("Pets")

            if speciesID and pets and pets.Store()[speciesID]
                and not pets.Store()[speciesID].collected then

                item.kind = CN.objectiveTypes.PET
                item.collectibleID = speciesID

                table.insert(found, item)
            elseif PlayerHasToy and C_ToyBox and C_ToyBox.GetToyInfo then
                local isToy = select(2, pcall(C_ToyBox.GetToyInfo, item.itemID))

                local owned = select(2, pcall(PlayerHasToy, item.itemID))

                if isToy and not owned then
                    item.kind = CN.objectiveTypes.TOY
                    item.collectibleID = item.itemID

                    table.insert(found, item)
                end
            end
        end
    end

    return found
end

function Inventory.Summary()
    local items = Inventory.Scan()

    return {
        items    = #items,
        starters = #Inventory.QuestStarters(),
        uncollected = #Inventory.UncollectedItems(),
    }
end

------------------------------------------------------------
-- CANDIDATES
------------------------------------------------------------

-- The cheapest actions the addon can offer: the walk is zero.
CN.RegisterCandidateProvider("Inventory", function()
    local candidates = {}

    if not Inventory.IsAvailable() then
        return candidates
    end

    for _, item in ipairs(Inventory.QuestStarters()) do
        if not CN.IsIgnored(CN.objectiveTypes.QUEST, item.questID)
            and not CN.IsDeferred(CN.objectiveTypes.QUEST, item.questID) then

            table.insert(candidates, CN.NewObjective({
                id               = item.questID,
                type             = CN.objectiveTypes.QUEST,
                name             = "Start: " .. (Blizzard.GetItemName(item.itemID)
                    or ("item " .. item.itemID)),
                state            = CN.objectiveStates.AVAILABLE,
                completionValue  = 3,
                unlockValue      = 1,

                -- Zero, and it is the honest number: the item is in your bag.
                travelCost       = 0,
                reasons          = {
                    "a quest starter in your bags -- right-click it",
                },
            }))
        end
    end

    for _, item in ipairs(Inventory.UncollectedItems()) do
        if not CN.IsIgnored(item.kind, item.collectibleID)
            and not CN.IsDeferred(item.kind, item.collectibleID) then

            table.insert(candidates, CN.NewObjective({
                id               = item.collectibleID,
                type             = item.kind,
                name             = Blizzard.GetItemName(item.itemID)
                    or ("item " .. item.itemID),
                completionValue  = 4,
                travelCost       = 0,
                reasons          = {
                    "already in your bags, uncollected",
                },
            }))
        end
    end

    return candidates
end, {
    events   = { "BAG_UPDATE_DELAYED", "PLAYER_ENTERING_WORLD" },
    cooldown = 5,
})

------------------------------------------------------------
-- COMMAND
------------------------------------------------------------

CN:RegisterCommand{
    name    = "bags",
    aliases = { "inventory" },
    order   = 28,
    help    = "What is in your bags that you could act on right now.",
    handler = function()
        if not Inventory.IsAvailable() then
            Print("This client does not expose container contents.")
            return
        end

        local summary = Inventory.Summary()

        Print(summary.items .. " items carried.")

        local starters = Inventory.QuestStarters()

        if #starters > 0 then
            Print(#starters .. " of them start a quest:")

            for _, item in ipairs(starters) do
                Print("  " .. (Blizzard.GetItemName(item.itemID)
                    or ("item " .. item.itemID))
                    .. " |cff999999bag " .. item.bag .. ", slot " .. item.slot .. "|r")
            end
        end

        local uncollected = Inventory.UncollectedItems()

        if #uncollected > 0 then
            Print(#uncollected .. " are collectibles you have not learned:")

            for _, item in ipairs(uncollected) do
                Print("  " .. (Blizzard.GetItemName(item.itemID)
                    or ("item " .. item.itemID))
                    .. " |cff999999" .. tostring(item.kind) .. "|r")
            end
        end

        if #starters == 0 and #uncollected == 0 then
            Print("|cff999999Nothing in there needs doing.|r")
        end

        Print("|cff999999Nothing is used, learned or moved on your behalf.|r")
    end,
}

return Inventory
