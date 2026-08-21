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

-- HOW CLOSE AN ACCEPTED QUEST IS, IN THINGS RATHER THAN IN PERCENT.
--
-- This file's own header has promised since 0.44.0 that the addon would say
-- "ten more" rather than "go and do that quest". It did not: the header
-- described an intention and the code collected quest STARTERS and nothing
-- else. Writing down what a thing is going to do and then not doing it is
-- worse than not writing it down, because the next reader believes it.
--
-- The client counts these itself, which is the whole reason this is cheap:
-- an objective that requires more than one of something reports how many are
-- done. Returns the objectives that are counting and unfinished, nearest to
-- completion first -- because "one more" is a completely different suggestion
-- from "nineteen more".
function Inventory.QuestProgress(questID)
    local rows = {}

    for _, objective in ipairs(Blizzard.GetCountingObjectives(questID)) do
        if not objective.finished then
            table.insert(rows, objective)
        end
    end

    table.sort(rows, function(a, b)
        return a.remaining < b.remaining
    end)

    return rows
end

-- The same question across every quest in the log: what is nearly done?
Inventory.nearlyDoneRemaining = 3

function Inventory.NearlyDone()
    local rows = {}

    for _, entry in ipairs(Blizzard.GetQuestLogEntries()) do
        for _, objective in ipairs(Inventory.QuestProgress(entry.questID)) do
            if objective.remaining <= Inventory.nearlyDoneRemaining then
                table.insert(rows, {
                    questID   = entry.questID,
                    title     = entry.title,
                    text      = objective.text,
                    done      = objective.done,
                    required  = objective.required,
                    remaining = objective.remaining,
                })
            end
        end
    end

    table.sort(rows, function(a, b)
        if a.remaining ~= b.remaining then
            return a.remaining < b.remaining
        end

        return (a.questID or 0) < (b.questID or 0)
    end)

    return rows
end

-- RECIPES YOU OWN AND HAVE NOT LEARNED.
--
-- The other promise this header made and did not keep. An unlearned recipe in
-- a bag is a profession skill-up sitting in your inventory, and the addon has
-- been recommending vendors that sell recipes while ignoring the ones you
-- already bought.
--
-- Item class 9 is Recipe. The client will say whether the character already
-- knows it -- an already-known recipe is greyed in the tooltip -- but there
-- is no clean API for that state, so this reports what is CARRIED and leaves
-- the "already known" question to the tooltip, which answers it visually.
function Inventory.Recipes()
    local recipes = {}

    if not C_Item or not C_Item.GetItemInfoInstant then
        return recipes
    end

    for _, item in ipairs(Inventory.Scan()) do
        local ok, _, _, _, _, classID = pcall(C_Item.GetItemInfoInstant, item.itemID)

        if ok and classID == 9 then
            item.kind = CN.objectiveTypes.RECIPE

            table.insert(recipes, item)
        end
    end

    return recipes
end

------------------------------------------------------------
-- THE BANK
------------------------------------------------------------

-- `bankIDs` has been declared since 0.44.0 and read by nothing -- a list of
-- container numbers sitting there looking like a feature.
--
-- The client refuses to describe bank containers unless the bank frame is
-- open, so this is only answerable while the player is standing at one. The
-- honest shape is therefore: scan when it is open, remember what was seen,
-- and report the remembered set with the date it was taken -- never
-- presenting a week-old snapshot as current.
function Inventory.BankStore()
    return CN.Account("bank")
end

function Inventory.ScanBank()
    local items = Inventory.Scan(Inventory.bankIDs)

    local store = Inventory.BankStore()

    for key in pairs(store) do
        store[key] = nil
    end

    -- Item ids and counts only. The bag and slot of something in a bank is
    -- not worth a byte on disk: it moves, and the player is looking at it.
    for _, item in ipairs(items) do
        store[item.itemID] = (store[item.itemID] or 0) + (item.count or 1)
    end

    store.scannedAt = time()

    return #items
end

function Inventory.InBank(itemID)
    if not itemID then
        return 0
    end

    return Inventory.BankStore()[itemID] or 0
end

CN:RegisterEvent("BANKFRAME_OPENED", function()
    local counted = Inventory.ScanBank()

    DebugPrint("Bank scanned: " .. counted .. " stacks.")
end)

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

    -- NEARLY-FINISHED OBJECTIVES.
    --
    -- "One more Sunscale Feather" is the cheapest quest advice there is, and
    -- the ranking could not distinguish it from a quest not yet started.
    for _, row in ipairs(Inventory.NearlyDone()) do
        if not CN.IsIgnored(CN.objectiveTypes.QUEST, row.questID)
            and not CN.IsDeferred(CN.objectiveTypes.QUEST, row.questID) then

            table.insert(candidates, CN.NewObjective({
                id               = row.questID,
                type             = CN.objectiveTypes.QUEST,
                name             = tostring(row.title or ("Quest " .. row.questID))
                    .. ": " .. row.remaining .. " more",
                state            = CN.objectiveStates.AVAILABLE,

                -- Worth more the closer it is, which is the entire point.
                completionValue  = 2 + (Inventory.nearlyDoneRemaining - row.remaining),
                travelCost       = CN.unknownLocationCost,
                reasons          = {
                    string.format("%s -- %d of %d done",
                        tostring(row.text or "objective"), row.done, row.required),
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

        local recipes = Inventory.Recipes()

        if #recipes > 0 then
            Print(#recipes .. " recipe(s) carried:")

            for _, item in ipairs(recipes) do
                Print("  " .. (Blizzard.GetItemName(item.itemID)
                    or ("item " .. item.itemID)))
            end
        end

        local nearly = Inventory.NearlyDone()

        if #nearly > 0 then
            Print("Nearly finished:")

            for index, row in ipairs(nearly) do
                if index > 8 then
                    Print("  |cff999999... and " .. (#nearly - 8) .. " more|r")
                    break
                end

                Print(string.format("  |cffffff00%d more|r %s |cff999999(%d/%d)|r",
                    row.remaining, tostring(row.text or row.title),
                    row.done, row.required))
            end
        end

        local bank = Inventory.BankStore()

        if bank.scannedAt then
            local age = math.max(0, time() - bank.scannedAt)

            Print("|cff999999Bank: " .. (CN.CountKeys(bank) - 1)
                .. " kinds of item, seen "
                .. math.floor(age / 3600) .. "h ago -- the client only "
                .. "describes it while you are standing at one.|r")
        end

        if #starters == 0 and #uncollected == 0 and #recipes == 0
            and #nearly == 0 then

            Print("|cff999999Nothing in there needs doing.|r")
        end

        Print("|cff999999Nothing is used, learned or moved on your behalf.|r")
    end,
}

return Inventory
