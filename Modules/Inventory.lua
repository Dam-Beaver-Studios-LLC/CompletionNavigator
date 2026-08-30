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

-- AND THE WARBAND BANK, WHICH IS A DIFFERENT CLAIM ABOUT A DIFFERENT THING.
--
-- The tabs above 12 are the account-wide bank. The distinction is not
-- cosmetic and it is the entire reason these are two lists rather than one:
-- an item in your character bank is reachable by ONE character, and an item
-- in the Warband bank is reachable by every character on the account. This
-- addon's whole subject is what is reachable, so merging the two would make
-- the store say something false about half its rows.
Inventory.accountBankIDs = { 13, 14, 15, 16, 17 }

function Inventory.IsAvailable()
    return C_Container ~= nil
        and C_Container.GetContainerNumSlots ~= nil
        and C_Container.GetContainerItemInfo ~= nil
end

-- Whether the client considers this slot a quest item. Guarded separately
-- from the rest: GetContainerItemQuestInfo is a different call with its own
-- availability, and a client that lacks it should report "not a quest item"
-- rather than erroring on every slot in the bag.
-- ASKED ONCE, AND THE WHOLE ANSWER KEPT.
--
-- This asked the client whether a slot is a quest item and threw away the
-- rest of what came back -- and then `QuestStarters` asked the identical
-- question again about every slot, for the `questID` and `isActive` this call
-- had already been handed. Measured at retail scale: one `BAG_UPDATE_DELAYED`
-- produced 288 calls to `GetContainerItemQuestInfo` for 144 distinct slots.
-- Exactly half of them were wasted.
local function QuestInfo(bag, slot)
    if not C_Container or not C_Container.GetContainerItemQuestInfo then
        return nil
    end

    local ok, info = pcall(C_Container.GetContainerItemQuestInfo, bag, slot)

    if not ok or type(info) ~= "table" then
        return nil
    end

    return info
end

-- Every item in a set of containers, as { itemID, count, link, quality, bag,
-- slot, questItem }.
--
-- The shape above used to claim `questID` and `isUsable` as well. Neither was
-- ever set on these rows. A comment that describes a richer row than the code
-- builds is worse than no comment: the next reader writes `row.questID` and
-- gets nil forever, with nothing anywhere to say why.
-- CACHED FOR THE BAGS, WHICH IS WHERE IT IS ASKED FOR REPEATEDLY.
--
-- The candidate provider calls QuestStarters, NearlyDone and
-- UncollectedItems, and every one of them rescanned all five bags -- three
-- full walks of a hundred and eighty slots per rebuild, each slot costing two
-- client calls.
--
-- Bags announce their own changes, so the cache lives until they do. Only the
-- default container set is cached: a bank scan is a deliberate one-off and
-- caching it would risk answering about a bank the player has walked away
-- from.
local bagCache = nil

function Inventory.Forget()
    bagCache = nil
end

function Inventory.Scan(containers)
    if not containers and bagCache then
        return bagCache
    end

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
                    local questInfo = QuestInfo(bag, slot)

                    table.insert(items, {
                        itemID   = info.itemID,
                        count    = info.stackCount or 1,
                        link     = info.hyperlink,
                        quality  = info.quality,
                        bag      = bag,
                        slot     = slot,
                        -- `hasNoValue` means the vendor will not buy it. It
                        -- has nothing to do with quest items, and reading it
                        -- as one made `questItem` true for every grey and
                        -- every soulbound token in the bag. The real question
                        -- has its own API, which this same file already asks
                        -- correctly forty lines below.
                        questItem = questInfo
                            and (questInfo.isQuestItem or questInfo.questID)
                            and true or false,

                        -- Kept rather than re-asked. See `QuestInfo` above.
                        startsQuest = questInfo and questInfo.questID or nil,
                        questActive = questInfo and questInfo.isActive or false,
                    })
                end
            end
        end
    end

    if not containers then
        bagCache = items
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

    if not Inventory.IsAvailable() then
        return starters
    end

    -- Read from what the scan already asked, rather than asking again. See
    -- `QuestInfo` above.
    for _, item in ipairs(Inventory.Scan()) do
        if item.startsQuest and not item.questActive then
            item.questID = item.startsQuest

            table.insert(starters, item)
        end
    end

    return starters
end

-- WHAT AN ITEM *IS*, WHICH NEVER CHANGES.
--
-- "Does this item teach a mount" is a property of the item, not of the
-- player, and the client answers it from a static table. The scan asked it --
-- along with the pet, toy and recipe forms of the same question -- once per
-- SLOT, so a forty-slot stack of the same reagent asked four times forty. One
-- bag update was measured at 576 of these calls for at most a few dozen
-- distinct items.
--
-- Keyed on the item, and never cleared: an item that teaches a mount teaches
-- that mount for the life of the game. What CAN change is whether the player
-- has collected it, and that is asked separately below and not memoised.
local itemKinds = {}

local function KindOf(itemID)
    local held = itemKinds[itemID]

    if held then
        return held
    end

    held = {
        mount   = Blizzard.GetMountFromItem(itemID),
        species = Blizzard.GetPetSpeciesFromItem(itemID),
    }

    -- A COLD JOURNAL'S "NO" IS NOT AN ANSWER.
    --
    -- Both calls return nil until their journal is populated, which at login
    -- happens AFTER the first `BAG_UPDATE_DELAYED` scan. Remembering that
    -- made every caged pet and every mount item in the player's bags
    -- invisible to the addon for the whole session, recoverable only by a
    -- reload -- where before this memo existed each scan re-asked and it
    -- corrected itself within seconds.
    --
    -- So only a positive answer is remembered. An item that is genuinely
    -- neither costs two client calls per scan, which is what it cost before.
    if held.mount or held.species then
        itemKinds[itemID] = held
    end

    return held
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
        local kind = KindOf(item.itemID)

        local mountID = kind.mount

        local mount = mountID and Blizzard.GetMountByID(mountID)

        -- `isCollected`, NOT `collected`.
        --
        -- `Blizzard.GetMountByID` returns the field as `isCollected`, and
        -- `Modules/Mounts.lua` reads it correctly. Here it was spelled
        -- `collected`, which is always nil, so `not nil` was always true and
        -- EVERY bag item that teaches a mount was emitted as uncollected --
        -- at completionValue 4 with a travel cost of zero, which is close to
        -- the strongest score shape the addon can produce. A mount you
        -- already learned and kept the item for sat near the top of `/cn next`
        -- telling you to learn it, for ever.
        --
        -- The comment three lines above says this check is what "keeps the
        -- addon from telling somebody to learn what they already have".
        if mount and not mount.isCollected then
            item.kind = CN.objectiveTypes.MOUNT
            item.collectibleID = mountID

            table.insert(found, item)
        else
            local speciesID = kind.species

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
        -- ONE MORE PLACEHOLDER. 0.77.0.
        --
        -- `GetItemInfoInstant` returns `itemID, itemType, itemSubType,
        -- itemEquipLoc, icon, classID, subclassID`, and through `pcall` those
        -- land at positions 2 through 8. This was one short, so the variable
        -- called `classID` was actually receiving the ICON -- a file id in
        -- the six figures -- and `classID == 9` was never true on any client.
        --
        -- So this function has returned an empty list since it was written,
        -- and `/cn bags` has never once reported a carried recipe: the entire
        -- feature the thirty-line header above describes, dead in one
        -- underscore.
        local ok, _, _, _, _, _, classID =
            pcall(C_Item.GetItemInfoInstant, item.itemID)

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
-- PER CHARACTER, WHICH IT WAS NOT.
--
-- This was `CN.Account("bank")` -- one table, account-wide, overwritten
-- wholesale by whichever character last opened a bank. So every alt read the
-- main's bank as its own, `/cn bags` reported items that character cannot
-- reach, and opening the bank on the alt destroyed the main's record. The
-- same defect, in the same shape, that migration 7 removed from
-- `questStatus`.
function Inventory.BankStore()
    local character = CN.character

    -- Nil only before the character table exists, which is before any bank
    -- frame can be open. Returning a throwaway means a scan that lands there
    -- is discarded -- correct, and it must not be mistaken for a real store,
    -- so nothing downstream reports on it.
    if not character then
        return {}
    end

    character.bank = character.bank or {}

    return character.bank
end

-- The Warband bank is genuinely account-wide, so this one genuinely is.
function Inventory.WarbandStore()
    return CN.Account("warbandBank")
end

-- WIPING THE STORE ON EVERY SCAN MADE IT HOLD THE LAST TAB LOOKED AT.
--
-- The client does not describe a bank tab until it has been switched to, so a
-- scan sees the visible tab and reports the rest as empty. Rewriting the
-- whole store from that means the Warband bank ends up holding whichever tab
-- the player clicked last -- and moving one item at the bank rewrites both
-- stores from whatever happens to be described at that moment.
--
-- 0.56.0 fixed that with an IN-MEMORY snapshot per container, which fixed it
-- only inside one session: at the next login the snapshot was empty, so the
-- first `BANKFRAME_OPENED` threw away everything on disk except the tab that
-- happened to be visible -- and stamped `scannedAt = now`, so `/cn bags`
-- reported the truncated record as freshly scanned. You had to click through
-- every tab again after every reload.
--
-- So the per-container shape is what is PERSISTED. `store.containers[bag]` is
-- what was in that container the last time the client described it, with its
-- own timestamp; the flat item counts stay beside it for every reader that
-- wants a total. A container the client is not describing keeps what it had,
-- across a reload, across a week.
local function Fill(store, containers, items, answered)
    store.containers = store.containers or {}
    store.seenAt     = store.seenAt or {}

    local now = time()

    -- Only the containers the client described this time.
    for _, bag in ipairs(containers) do
        if answered[bag] then
            store.containers[bag] = {}
            store.seenAt[bag]     = now
        end
    end

    for _, item in ipairs(items) do
        local bag = store.containers[item.bag]

        if bag then
            bag[item.itemID] = (bag[item.itemID] or 0) + (item.count or 1)
        end
    end

    -- The flat totals, rebuilt from the containers. Item ids and counts only:
    -- the bag and slot of something in a bank is not worth a byte on disk,
    -- because it moves and the player is looking at it.
    for key in pairs(store) do
        if key ~= "containers" and key ~= "seenAt" then
            store[key] = nil
        end
    end

    local seen = 0

    for _, bag in pairs(store.containers) do
        for itemID, count in pairs(bag) do
            store[itemID] = (store[itemID] or 0) + count

            seen = seen + 1
        end
    end

    -- The OLDEST container's timestamp, not this instant.
    --
    -- Stamping `now` claimed the whole record was as fresh as the one tab the
    -- client happened to describe. What `/cn bags` should say is how old the
    -- stalest part of the answer is, which is the honest reading of "seen Nh
    -- ago" over a record assembled from several visits.
    local oldest

    for _, at in pairs(store.seenAt) do
        if not oldest or at < oldest then
            oldest = at
        end
    end

    store.scannedAt = oldest or now

    return seen
end

-- How many kinds of item a bank store holds, ignoring its bookkeeping keys.
-- Counting them was a subtraction of one against a store that now carries
-- three, which is the kind of arithmetic that is wrong the moment anything is
-- added beside it.
function Inventory.Kinds(store)
    local kinds = 0

    for key in pairs(store or {}) do
        if key ~= "containers" and key ~= "seenAt" and key ~= "scannedAt" then
            kinds = kinds + 1
        end
    end

    return kinds
end

-- Which containers the client was willing to describe. A container with no
-- slots is one that has not been opened, not one that is empty, and the
-- difference is the whole reason the snapshot above exists.
local function Answered(containers)
    local answered = {}

    if not Inventory.IsAvailable() then
        return answered
    end

    for _, bag in ipairs(containers) do
        local ok, slots = pcall(C_Container.GetContainerNumSlots, bag)

        if ok and type(slots) == "number" and slots > 0 then
            answered[bag] = true
        end
    end

    return answered
end

-- Returns the character-bank count and the Warband count separately, because
-- the two answer different questions and a caller that adds them up is
-- claiming something the addon cannot support.
function Inventory.ScanBank()
    local mine = Inventory.Scan(Inventory.bankIDs)

    local held = Fill(Inventory.BankStore(), Inventory.bankIDs, mine,
        Answered(Inventory.bankIDs))

    local warband = Inventory.Scan(Inventory.accountBankIDs)

    local heldWarband = Fill(Inventory.WarbandStore(),
        Inventory.accountBankIDs, warband, Answered(Inventory.accountBankIDs))

    return held, heldWarband
end

CN:RegisterEvent("BAG_UPDATE_DELAYED", function()
    Inventory.Forget()
end)

CN:RegisterEvent("BANKFRAME_OPENED", function()
    local mine, warband = Inventory.ScanBank()

    DebugPrint("Bank scanned: " .. mine .. " stacks, "
        .. tostring(warband) .. " in the Warband bank.")
end)

-- THE WARBAND TABS ARE NOT ALL VISIBLE WHEN THE FRAME OPENS.
--
-- The client does not describe a bank tab until it has been switched to, so a
-- single scan at `BANKFRAME_OPENED` sees the tab that happened to be selected
-- and reports the rest as empty -- which is worse than not reading them,
-- because an empty row looks like an answer.
--
-- `BAG_UPDATE_DELAYED` fires when any container the client is describing
-- changes, which includes switching tabs, so re-reading on it WHILE THE FRAME
-- IS OPEN fills the picture in as the player moves around the bank. Only
-- while it is open: asking otherwise returns nothing and would blank a real
-- record with a false one.
--
-- Only events this addon can prove exist. `harness.lua` refuses an invented
-- event name, which is how the two speculative ones in the first draft of
-- this block were caught before they shipped as three handlers that never
-- fired.
CN:RegisterEvent("BAG_UPDATE_DELAYED", function()
    if not Inventory.BankIsOpen() then
        return
    end

    Inventory.ScanBank()
end)

-- Only while the frame the client requires is actually open.
function Inventory.BankIsOpen()
    if BankFrame and BankFrame.IsShown then
        local ok, shown = pcall(BankFrame.IsShown, BankFrame)

        return ok and shown and true or false
    end

    return false
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
                    "a quest starter in your bags" .. CN.DASH .. "right-click it",
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

            -- WHERE IT IS, AND WHAT REACHING IT COSTS. 0.86.0.
            --
            -- This row carried `CN.placelessCost`, which is 0 and means
            -- "there is not a journey" -- true of an item sitting in a bag,
            -- and false of a quest objective out in the world. The sibling
            -- row in `Modules/Quests.lua` charges `CN.unknownLocationCost`
            -- for exactly this case, with a note saying why.
            --
            -- Two things went wrong from it. A zero cost is worth eight to
            -- twenty-four points on a scale where finishing something tops
            -- out around eight, so a quest in a zone left an hour ago
            -- outranked everything in front of the player. And zero also
            -- makes `CN.IsPlaceless` true -- while this provider registers
            -- BEFORE Quests, and the aggregate keeps the first row whole. So
            -- this row won the dedup and replaced the Quests provider's real
            -- coordinates with none: `/cn go`, the arrow, the map pin and
            -- the session plan had nothing to point at.
            local mapID, x, y = Blizzard.GetQuestWaypoint(row.questID)

            local travel, costed

            if mapID and x and y then
                travel, costed = CN.TravelCost(mapID, x, y)
            end

            table.insert(candidates, CN.NewObjective({
                id               = row.questID,
                type             = CN.objectiveTypes.QUEST,
                name             = tostring(row.title or ("Quest " .. row.questID))
                    .. ": " .. row.remaining .. " more",
                state            = CN.objectiveStates.AVAILABLE,
                mapID            = mapID,
                x                = x,
                y                = y,

                -- Worth more the closer it is, which is the entire point.
                completionValue  = 2 + (Inventory.nearlyDoneRemaining - row.remaining),
                travelCost       = travel or CN.unknownLocationCost,
                travelCosted     = costed or nil,
                reasons          = {
                    string.format("%s" .. CN.DASH .. "%d of %d done",
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
    -- THE QUEST EVENTS, because this provider reads the quest log.
    --
    -- `Inventory.NearlyDone` walks `GetQuestLogEntries` and emits a row per
    -- nearly-finished objective -- "Test Quest Alpha: 1 more" -- and the
    -- declaration named only bag events. `InvalidateCandidates` SKIPS a
    -- provider that has an events table and was not named, so handing a quest
    -- in did not touch these rows at all: the quest stayed on the list and in
    -- the route until a bag update or a loading screen happened along.
    --
    -- Reported from play, and the reason the lint below this file exists: a
    -- provider must declare the events of every system it reads, not of the
    -- system it is named after.
    events   = {
        "BAG_UPDATE_DELAYED", "PLAYER_ENTERING_WORLD",
        "QUEST_TURNED_IN", "QUEST_REMOVED", "QUEST_ACCEPTED",
        "QUEST_LOG_UPDATE",

        -- AND WHERE THE PLAYER IS STANDING. 0.86.0. The nearly-done quest
        -- row now costs a real journey, which reads the player's position --
        -- so this provider reads that system too, and the lint below this
        -- file is right to require it to say so.
        "ZONE_CHANGED_NEW_AREA",
    },
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
                CN.PrintLine("  " .. (Blizzard.GetItemName(item.itemID)
                    or ("item " .. item.itemID))
                    .. " |cff8a8f96bag " .. item.bag .. ", slot " .. item.slot .. "|r")
            end
        end

        local uncollected = Inventory.UncollectedItems()

        if #uncollected > 0 then
            Print(#uncollected .. " are collectibles you have not learned:")

            for _, item in ipairs(uncollected) do
                CN.PrintLine("  " .. (Blizzard.GetItemName(item.itemID)
                    or ("item " .. item.itemID))
                    .. " |cff8a8f96" .. tostring(item.kind) .. "|r")
            end
        end

        local recipes = Inventory.Recipes()

        if #recipes > 0 then
            Print(CN.Count(#recipes, "recipe") .. " carried:")

            for _, item in ipairs(recipes) do
                CN.PrintLine("  " .. (Blizzard.GetItemName(item.itemID)
                    or ("item " .. item.itemID)))
            end
        end

        local nearly = Inventory.NearlyDone()

        if #nearly > 0 then
            Print("Nearly finished:")

            for index, row in ipairs(nearly) do
                if index > 8 then
                    -- Translated, like the identical phrase nine lines below.
                    -- Hardcoded English two lines from a CN.L lookup of the
                    -- same words is how a locale file ends up complete and
                    -- the addon still English.
                    CN.PrintLine("  |cff8a8f96"
                        .. string.format(CN.L["%d more"], #nearly - 8) .. "|r")
                    break
                end

                CN.PrintLine(string.format("  |cffffc74f" .. CN.L["%d more"]
                    .. "|r %s |cff8a8f96(%d/%d)|r",
                    row.remaining, tostring(row.text or row.title),
                    row.done, row.required))
            end
        end

        -- TWO BANKS, REPORTED AS TWO, because they answer different
        -- questions. What is in this character's bank is reachable by this
        -- character; what is in the Warband bank is reachable by all of them,
        -- and that difference is the whole reason to mention either.
        -- THROUGH `CN.Ago`. 0.77.0.
        --
        -- This was raw hours, rendered as "seen 336h ago" for a bank read a
        -- fortnight before. `CN.Ago` exists for exactly this, its own header
        -- names "97h 12m" as the wrong shape for a stored reading, and the
        -- Scans tab has used it correctly all along.
        local function Age(store)
            return CN.Ago(store and store.scannedAt) or "never"
        end

        local bank = Inventory.BankStore()

        if bank.scannedAt then
            CN.PrintLine(CN.Muted("Your bank: " .. Inventory.Kinds(bank)
                .. " kinds of item, seen " .. Age(bank) .. " " .. CN.DASH
                .. " the client only describes it while you are standing at "
                .. "one."))
        end

        local warband = Inventory.WarbandStore()

        if warband.scannedAt then
            CN.PrintLine(CN.Muted("Warband bank: "
                .. Inventory.Kinds(warband)
                .. " kinds of item, seen " .. Age(warband) .. " "
                .. CN.DASH .. " reachable from every character."))
        end

        if #starters == 0 and #uncollected == 0 and #recipes == 0
            and #nearly == 0 then

            Print("|cff8a8f96Nothing in there needs doing.|r")
        end

        Print("|cff8a8f96Nothing is used, learned or moved on your behalf.|r")
    end,
}

return Inventory
