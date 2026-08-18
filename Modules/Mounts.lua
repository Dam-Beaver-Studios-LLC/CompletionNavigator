-- Modules/Mounts.lua
-- Completion Navigator :: mount collection.
--
-- Mounts are account-wide, but a mount can be faction-locked or hidden on
-- the current character. Both matter for "which character should get this",
-- so both are recorded rather than filtered away at scan time.

local ADDON_NAME, CN = ...

local Mounts = CN:RegisterModule("Mounts")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

------------------------------------------------------------
-- STORAGE
------------------------------------------------------------

local function Store()
    return CN.Account("mounts")
end

Mounts.Store = Store

------------------------------------------------------------
-- SCAN
------------------------------------------------------------

function Mounts.Scan()
    if not C_MountJournal then
        return 0, 0, 0
    end

    local store = Store()

    local seen, collected, missing = 0, 0, 0

    for _, mountID in ipairs(Blizzard.GetMountIDs()) do
        local mount = Blizzard.GetMountByID(mountID)

        if mount then
            local existing = store[mountID]

            store[mountID] = {
                mountID           = mountID,
                name              = mount.name,
                spellID           = mount.spellID,
                sourceType        = mount.sourceType,
                source            = mount.source,
                isFactionSpecific = mount.isFactionSpecific,
                faction           = mount.faction,
                collected         = mount.isCollected,
                firstSeen         = existing and existing.firstSeen or time(),
                lastSeen          = time(),
            }

            seen = seen + 1

            if mount.isCollected then
                collected = collected + 1
            else
                missing = missing + 1
            end
        end
    end

    CN.Account("collectionScans").mounts = time()

    return seen, collected, missing
end

------------------------------------------------------------
-- ELIGIBILITY
------------------------------------------------------------

-- faction is 0 for Horde and 1 for Alliance in the mount journal.
local FACTION_NAMES = { [0] = "Horde", [1] = "Alliance" }

function Mounts.IsUsableByCharacter(record, character)
    if not record.isFactionSpecific then
        return true
    end

    character = character or CN.character

    if not character or not character.faction then
        return true
    end

    return FACTION_NAMES[record.faction] == character.faction
end

CN.RegisterEligibilityChecker(CN.objectiveTypes.MOUNT, function(mountID)
    local states = CN.objectiveStates
    local record = Store()[mountID]

    if not record then
        return states.UNKNOWN, "No mount data; run /cn mountscan", nil
    end

    if record.collected then
        return states.COMPLETED, "Already collected", record.name
    end

    if not Mounts.IsUsableByCharacter(record) then
        return states.REQUIRES_OTHER_CHARACTER,
               CN.blockReasons.WRONG_FACTION,
               FACTION_NAMES[record.faction] or "the other faction"
    end

    return states.AVAILABLE, nil, nil
end)

------------------------------------------------------------
-- SUMMARY
------------------------------------------------------------

function Mounts.Summary()
    local counts = {
        known        = 0,
        collected    = 0,
        missing      = 0,
        wrongFaction = 0,
    }

    for _, record in pairs(Store()) do
        counts.known = counts.known + 1

        if record.collected then
            counts.collected = counts.collected + 1
        else
            counts.missing = counts.missing + 1

            if not Mounts.IsUsableByCharacter(record) then
                counts.wrongFaction = counts.wrongFaction + 1
            end
        end
    end

    return counts
end

------------------------------------------------------------
-- LOOKUP
------------------------------------------------------------

function Mounts.Resolve(text)
    local mountID = CN.ToID(text)

    if mountID and Store()[mountID] then
        return mountID
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

    return matches[1].id, matches
end

------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

CN:RegisterEvent("NEW_MOUNT_ADDED", function()
    Mounts.Scan()
    DebugPrint("Mount added; journal rescanned.")
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "mountscan",
    order   = 53,
    help    = "Scan the mount journal.",
    handler = function()
        local seen, collected, missing = Mounts.Scan()

        Print("Scanned " .. seen .. " mounts.")
        Print("Collected: " .. collected .. "   Missing: " .. missing)
    end,
}

CN:RegisterCommand{
    name    = "mounts",
    order   = 54,
    help    = "Summarize mount collection.",
    handler = function()
        local counts = Mounts.Summary()

        if counts.known == 0 then
            Print("No mount data yet. Run /cn mountscan.")
            return
        end

        Print("Mounts known to the journal: " .. counts.known)
        Print("Collected: " .. counts.collected .. "   Missing: " .. counts.missing)

        if counts.wrongFaction > 0 then
            Print("Missing and locked to the other faction: " .. counts.wrongFaction)
        end
    end,
}

CN:RegisterCommand{
    name    = "mount",
    args    = "<mountID or name>",
    order   = 55,
    help    = "Show one mount's collection state.",
    handler = function(args)
        if args == "" then
            Print("Usage: /cn mount <mountID or name>")
            return
        end

        local mountID = Mounts.Resolve(args)

        if not mountID then
            Print("No known mount matches: " .. args)
            return
        end

        local record = Store()[mountID]

        Print(record.name .. " |cff999999(" .. mountID .. ")|r")
        Print("Collected: " .. CN.YesNo(record.collected))

        if record.source and record.source ~= "" then
            Print("Source: " .. record.source:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
        end

        if record.isFactionSpecific then
            Print("Faction: " .. (FACTION_NAMES[record.faction] or "unknown")
                .. (Mounts.IsUsableByCharacter(record) and "" or " |cffff4444(not this character)|r"))
        end
    end,
}
