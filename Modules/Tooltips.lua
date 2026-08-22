-- Modules/Tooltips.lua
-- Completion Navigator :: what the addon knows, shown where you are looking.
--
-- Everything in this addon already knows whether you own a toy, which of your
-- characters knows a recipe, and which vendor sells an item. Until now you had
-- to go and ask. A tooltip is where that question actually gets asked -- while
-- hovering the thing in a vendor list, a loot window or the auction house.
--
-- The line-building functions are deliberately separate from the hooks: the
-- lines are pure data, so they can be tested offline, and the hooks are a thin
-- adapter over whichever tooltip API the client is running.

local ADDON_NAME, CN = ...

local Tooltips = CN:RegisterModule("Tooltips")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

-- THE SAME PALETTE AS EVERYTHING ELSE, IN THE SHAPE A TOOLTIP WANTS.
--
-- These were four hand-written triples, of which exactly one matched the hex
-- codes the rest of the addon used for the same four meanings. A player
-- hovering an item saw a slightly different green from the one in the window
-- for "collected", and nothing in the code said which was right.
local GREEN  = CN.RGB.GOOD
local RED    = CN.RGB.BAD
local YELLOW = CN.RGB.WARN
local GREY   = CN.RGB.MUTED

local HEADER = "Completion Navigator"

local function Enabled()
    local settings = CN.Settings()

    return settings and settings.tooltips ~= false
end

Tooltips.Enabled = Enabled

------------------------------------------------------------
-- LINE BUILDERS
------------------------------------------------------------

local function Add(lines, text, color)
    table.insert(lines, { text = text, color = color or GREY })
end

local function CollectedLine(lines, label, collected)
    if collected then
        Add(lines, label .. ": collected", GREEN)
    else
        Add(lines, label .. ": not collected", RED)
    end
end

-- Toys are keyed by item ID in both the toy box and our own store, so this is
-- the one collection lookup that needs no translation.
local function ToyLines(lines, itemID)
    local record = CN.Account("toys")[itemID]

    if record then
        CollectedLine(lines, "Toy", record.collected)
        return true
    end

    -- No scan yet, but the client can still answer for this one item.
    if PlayerHasToy and C_ToyBox and C_ToyBox.GetToyInfo then
        local _, name = C_ToyBox.GetToyInfo(itemID)

        if name then
            CollectedLine(lines, "Toy", PlayerHasToy(itemID))
            return true
        end
    end

    return false
end

local function MountLines(lines, itemID)
    local mountID = Blizzard.GetMountFromItem(itemID)

    if not mountID then
        return false
    end

    local record = CN.Account("mounts")[mountID]

    if record then
        CollectedLine(lines, "Mount", record.collected)

        if record.isFactionSpecific and record.faction then
            Add(lines, "Faction-locked", YELLOW)
        end

        return true
    end

    local mount = Blizzard.GetMountByID(mountID)

    if mount then
        CollectedLine(lines, "Mount", mount.isCollected)
        return true
    end

    return false
end

local function PetLines(lines, itemID)
    local speciesID = Blizzard.GetPetSpeciesFromItem(itemID)

    if not speciesID then
        return false
    end

    local record = CN.Account("pets")[speciesID]

    local count, limit

    if record then
        count, limit = record.count, record.limit
    else
        count, limit = Blizzard.GetPetCollectedCount(speciesID)
    end

    count = count or 0

    -- NO FABRICATED DENOMINATOR.
    --
    -- `limit or 3` invented the cap when neither the store nor the client
    -- supplied it, and then printed "collected 2 of 3" as though the 3 had
    -- been read from somewhere. Three is the right number today; it is still
    -- a made-up total in a module that refuses them everywhere else.
    if count > 0 and limit and limit > 0 then
        Add(lines, "Battle pet: collected " .. count .. " of " .. limit, GREEN)
    elseif count > 0 then
        Add(lines, "Battle pet: collected " .. count, GREEN)
    else
        Add(lines, "Battle pet: not collected", RED)
    end

    return true
end

local function AppearanceLines(lines, itemID)
    local has = Blizzard.HasTransmogByItem(itemID)

    if has == nil then
        return false
    end

    if has then
        Add(lines, "Appearance: already known", GREEN)
    else
        Add(lines, "Appearance: not yet known", RED)
    end

    return true
end

-- Recipes are the messy case. The trade skill API keys recipes by recipe ID
-- while a vendor sells an item ID, and the two are not the same number. The
-- ID lookup is tried first because it is exact; the name match is the fallback
-- that actually fires most of the time, and it is reported as a match on name
-- rather than dressed up as certainty.
local function RecipeLines(lines, itemID, itemName)
    local professions = CN:GetModule("Professions")

    if not professions then
        return false
    end

    local mine = professions.CharacterRecipes() or {}

    -- ONE INDEXED LOOKUP, NOT A SCAN.
    --
    -- This used to walk every recipe name the addon knew -- lowercasing each
    -- one and searching it -- on every single item tooltip. At retail scale
    -- that is twenty-five hundred iterations and five thousand string
    -- allocations to answer a question about one item, measured at 0.54ms:
    -- three per cent of a frame, per mouseover, and a bag sweep fires dozens
    -- a second.
    local recipeID, matchedOnName =
        professions.RecipeForItem(itemID, itemName)

    if not recipeID then
        return false
    end

    if mine[recipeID] then
        Add(lines, "Recipe: known by this character", GREEN)
    else
        Add(lines, "Recipe: not known by this character", RED)

        local holders = professions.WhoKnows(recipeID) or {}

        if #holders > 0 then
            Add(lines, "Known by: " .. table.concat(holders, ", "), YELLOW)
        end
    end

    if matchedOnName then
        Add(lines, "matched by name", GREY)
    end

    return true
end

local function VendorLines(lines, itemID)
    local vendors = CN:GetModule("Vendors")

    if not vendors then
        return false
    end

    local sellers = vendors.WhoSells(itemID)

    if #sellers == 0 then
        return false
    end

    for index, seller in ipairs(sellers) do
        if index > 3 then
            Add(lines, "and " .. (#sellers - 3) .. " more recorded seller"
                .. ((#sellers - 3) == 1 and "" or "s"), GREY)
            break
        end

        local text = "Sold by " .. tostring(seller.name or seller.npcID)

        if seller.zone then
            text = text .. " in " .. seller.zone
        end

        if seller.x and seller.y then
            text = text .. string.format(" (%.1f, %.1f)", seller.x * 100, seller.y * 100)
        end

        Add(lines, text, YELLOW)
    end

    return true
end

-- The whole item block, as data. Returns an array of { text, color }.
function Tooltips.ItemLines(itemID, itemName)
    local lines = {}

    if not itemID or not CN.db then
        return lines
    end

    itemName = itemName or Blizzard.GetItemName(itemID)

    local collectible = false

    collectible = ToyLines(lines, itemID)         or collectible
    collectible = MountLines(lines, itemID)       or collectible
    collectible = PetLines(lines, itemID)         or collectible
    collectible = RecipeLines(lines, itemID, itemName) or collectible

    -- Appearance state is noise on something that is not gear, so it is only
    -- consulted when nothing else claimed the item.
    if not collectible then
        AppearanceLines(lines, itemID)
    end

    VendorLines(lines, itemID)

    -- WHY IT MATTERS, not only that it is tracked (0.43.0).
    --
    -- Every line above answers "do I have this?". None of them answered the
    -- question a player actually hovers an item to ask, which is "should I
    -- care?" -- and the addon knows, because it has already ranked the thing
    -- and written down its reasons.
    --
    -- One line, the top reason only. A tooltip that grows a paragraph is a
    -- tooltip people turn off.
    if collectible then
        local goals = CN:GetModule("Goals")

        local mountID = Blizzard.GetMountFromItem(itemID)
        local speciesID = Blizzard.GetPetSpeciesFromItem(itemID)

        local goalType = mountID and CN.objectiveTypes.MOUNT
            or (speciesID and CN.objectiveTypes.PET)

        local goalID = mountID or speciesID

        if goals and goalType and goalID and goals.IsGoal
            and goals.IsGoal(goalType, goalID) then

            Add(lines, "You are chasing this.", { 0.365, 0.824, 0.984 })
        else
            local candidate = CN.FindCandidate and goalType
                and CN.FindCandidate(goalType, goalID)

            local reason = candidate and candidate.reasons
                and candidate.reasons[1]

            if reason then
                Add(lines, reason, { 0.6, 0.6, 0.6 })
            end

            -- ONE MORE LINE, WHERE IT SAYS SOMETHING THE FIRST DID NOT.
            --
            -- 0.43.0 added the top reason, which answers "should I care?".
            -- The second question a player asks of a collectible is "where
            -- does it come from?", and the addon has known that since 0.41.0
            -- without ever putting it where the mouse already is.
            local instances = CN:GetModule("Instances")

            if instances and itemName then
                local ok, source = pcall(instances.DescribeSource, itemName)

                if ok and source then
                    Add(lines, "Drops from " .. source, { 0.6, 0.6, 0.6 })
                end
            end
        end
    end

    return lines
end

-- Unit tooltips answer a narrower question: have I shopped here, and is this
-- creature one the addon is tracking as a rare.
function Tooltips.UnitLines(npcID)
    local lines = {}

    if not npcID or not CN.db then
        return lines
    end

    local vendors = CN:GetModule("Vendors")

    if vendors then
        local record = vendors.Store()[npcID]

        if record then
            Add(lines, "Recorded vendor: " .. (record.itemCount or 0) .. " items", YELLOW)

            if not record.mapID then
                Add(lines, "no coordinates recorded yet", GREY)
            end
        end
    end

    -- The rare database is keyed by vignette ID, not creature ID, so there is
    -- deliberately nothing to say here about rares. Adding a guess would be
    -- worse than the silence.

    return lines
end

------------------------------------------------------------
-- RENDERING
------------------------------------------------------------

function Tooltips.Render(tooltip, lines)
    if not tooltip or not tooltip.AddLine or #lines == 0 then
        return 0
    end

    tooltip:AddLine(" ")
    tooltip:AddLine(HEADER, 0.2, 1.0, 0.6)

    for _, line in ipairs(lines) do
        tooltip:AddLine(line.text, line.color[1], line.color[2], line.color[3])
    end

    if tooltip.Show then
        tooltip:Show()
    end

    return #lines
end

------------------------------------------------------------
-- HOOKS
------------------------------------------------------------

-- Which tooltip API resolved, reported by /cn tooltips so a silent hook is
-- diagnosable rather than mysterious.
Tooltips.backend = "none"

local function OnItemTooltip(tooltip, itemID, itemName)
    if not Enabled() then
        return
    end

    local ok, err = pcall(function()
        Tooltips.Render(tooltip, Tooltips.ItemLines(itemID, itemName))
    end)

    if not ok then
        DebugPrint("Item tooltip failed: " .. tostring(err))
    end
end

local function OnUnitTooltip(tooltip, unit)
    if not Enabled() then
        return
    end

    local ok, err = pcall(function()
        local npcID = Blizzard.GetUnitNPCID(unit or "mouseover")

        Tooltips.Render(tooltip, Tooltips.UnitLines(npcID))
    end)

    if not ok then
        DebugPrint("Unit tooltip failed: " .. tostring(err))
    end
end

Tooltips.OnItemTooltip = OnItemTooltip
Tooltips.OnUnitTooltip = OnUnitTooltip

function Tooltips.Install()
    if Tooltips.installed then
        return Tooltips.backend
    end

    -- Modern retail: every tooltip is data-driven and post-processed. Post
    -- calls run after the tooltip is rebuilt, so lines are added once per
    -- render rather than accumulating.
    if TooltipDataProcessor
        and TooltipDataProcessor.AddTooltipPostCall
        and Enum and Enum.TooltipDataType then

        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item,
            function(tooltip, data)
                local itemID, itemName

                if data then
                    itemID = data.id
                end

                if TooltipUtil and TooltipUtil.GetDisplayedItem then
                    local name, _, id = TooltipUtil.GetDisplayedItem(tooltip)

                    itemName = name
                    itemID   = itemID or id
                end

                OnItemTooltip(tooltip, itemID, itemName)
            end)

        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit,
            function(tooltip, data)
                local unit

                if TooltipUtil and TooltipUtil.GetDisplayedUnit then
                    unit = select(2, TooltipUtil.GetDisplayedUnit(tooltip))
                end

                OnUnitTooltip(tooltip, unit)
            end)

        Tooltips.installed = true
        Tooltips.backend   = "TooltipDataProcessor"

        return Tooltips.backend
    end

    -- Older clients. Kept because the addon is expected to load on more than
    -- one flavour, and a missing hook here is silent otherwise.
    if GameTooltip and GameTooltip.HookScript then
        GameTooltip:HookScript("OnTooltipSetItem", function(self)
            local name, link = self:GetItem()

            local itemID = link and tonumber(link:match("item:(%d+)"))

            OnItemTooltip(self, itemID, name)
        end)

        GameTooltip:HookScript("OnTooltipSetUnit", function(self)
            local _, unit = self:GetUnit()

            OnUnitTooltip(self, unit)
        end)

        Tooltips.installed = true
        Tooltips.backend   = "OnTooltipSet"

        return Tooltips.backend
    end

    Tooltips.backend = "none"

    return Tooltips.backend
end

CN:OnLogin(function()
    Tooltips.Install()

    DebugPrint("Tooltip backend: " .. tostring(Tooltips.backend))
end)

------------------------------------------------------------
-- COMMAND
------------------------------------------------------------

CN:RegisterCommand{
    name    = "tooltips",
    args    = "[on or off]",
    order   = 82,
    help    = "Toggle addon lines on item and unit tooltips.",
    handler = function(args)
        local settings = CN.Settings()

        args = string.lower(CN.Trim(args))

        if args == "on" then
            settings.tooltips = true
        elseif args == "off" then
            settings.tooltips = false
        elseif args ~= "" then
            Print("Usage: /cn tooltips [on or off]")
            return
        else
            -- Default is on, so nil counts as enabled.
            settings.tooltips = (settings.tooltips == false)
        end

        Print("Tooltip lines: " .. CN.YesNo(settings.tooltips ~= false))
        Print("|cff8a8f96Backend: " .. tostring(Tooltips.backend) .. "|r")

        if Tooltips.backend == "none" then
            Print("|cff8a8f96No tooltip API resolved, so nothing will be added.|r")
        end
    end,
}

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
