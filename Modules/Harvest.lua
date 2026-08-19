-- Modules/Harvest.lua
-- Completion Navigator :: build the static database from your own play.
--
-- The curated database is the addon's bottleneck: prerequisite forensics,
-- zone percentages and unlock scoring all need quest records that nobody has
-- typed in yet. External providers help only if the player has those addons
-- installed.
--
-- This module needs nothing. Every quest you pick up gets its name, zone,
-- coordinates and level recorded permanently, account-wide. Playing the game
-- fills the database.
--
-- /cn export then emits it as a Data\Quests.lua block, so what you harvest
-- can be committed and shipped to everyone.

local ADDON_NAME, CN = ...

local Harvest = CN:RegisterModule("Harvest")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

local function Store()
    return CN.Account("questHarvest")
end

Harvest.Store = Store

------------------------------------------------------------
-- CAPTURE
------------------------------------------------------------

-- Records everything currently knowable about a quest. Safe to call
-- repeatedly: fields are only filled in, never blanked, because the client
-- answers for a quest in the log and goes quiet once it is turned in.
function Harvest.Capture(questID, reason)
    questID = CN.ToID(questID)

    if not questID then
        return false
    end

    local store  = Store()
    local record = store[questID] or { questID = questID, firstSeen = time() }

    local changed = false

    local function set(field, value)
        if value ~= nil and record[field] == nil then
            record[field] = value
            changed = true
        end
    end

    local quests = CN:GetModule("Quests")

    if quests then
        set("name", quests.GetName(questID, false))
    end

    local mapID, x, y = Blizzard.GetQuestWaypoint(questID)

    set("mapID", mapID)

    if x and y then
        set("x", math.floor(x * 10000 + 0.5) / 10000)
        set("y", math.floor(y * 10000 + 0.5) / 10000)
    end

    if mapID then
        set("zone", Blizzard.GetMapName(mapID))
    end

    -- The level the character was when the quest became available is a
    -- usable lower bound on the quest's own level requirement.
    if record.observedLevel == nil then
        record.observedLevel = UnitLevel("player")
        changed = true
    end

    if CN.character and record.faction == nil then
        record.faction = CN.character.faction
        changed = true
    end

    -- Anything an installed provider knows, captured once so it survives
    -- that addon being uninstalled later.
    if not record.requires then
        local external = CN.QueryQuestDataProviders(questID)

        if external then
            set("name", external.name)
            set("mapID", external.mapID)
            set("x", external.x)
            set("y", external.y)
            set("requiresLevel", external.requiresLevel)

            if external.requires then
                record.requires  = external.requires
                record.requiredBy = external.providers
                changed = true
            end
        end
    end

    record.lastSeen = time()
    record.reason   = record.reason or reason

    store[questID] = record

    if changed then
        DebugPrint("Harvested quest " .. questID
            .. (record.name and (" (" .. record.name .. ")") or ""))
    end

    return changed
end

------------------------------------------------------------
-- INFERRED PREREQUISITES
------------------------------------------------------------

-- When a quest is accepted, every quest completed immediately beforehand is a
-- *candidate* prerequisite. One observation is a correlation and nothing more.
--
-- What turns correlation into something usable is REPETITION ACROSS
-- CHARACTERS. If quest B follows quest A on one character, that is the order
-- you happened to play. If it follows on three characters, that is the game
-- telling you A gates B -- because independent playthroughs do not agree by
-- accident, and an alt cannot inherit the coincidence.
--
-- So observations accumulate per prerequisite, counted by distinct character,
-- and only cross into the dependency graph once enough characters agree. Even
-- then they are labelled as observed, never as fact, and curated data always
-- wins over them.
local recentTurnIns = {}

-- How many DISTINCT characters must show the same ordering. Two is a
-- coincidence you could plausibly hit; three is a pattern.
Harvest.confidenceThreshold = 3

-- Forgets recent turn-ins.
--
-- Called on login: a quest accepted in this session must not be correlated
-- with one turned in before the last logout. The 300-second window mostly
-- covers that already, but "mostly" is how a false prerequisite gets recorded
-- and then repeated on other characters until it looks confident.
function Harvest.ResetRecent()
    recentTurnIns = {}
end

function Harvest.NoteTurnIn(questID)
    table.insert(recentTurnIns, 1, { questID = questID, at = time() })

    for index = #recentTurnIns, 6, -1 do
        table.remove(recentTurnIns, index)
    end
end

-- observed[prereqID] = { seen = n, characters = { [key] = true } }
local function Observations(record)
    record.observed = record.observed or {}

    return record.observed
end

Harvest.Observations = Observations

function Harvest.NoteAccepted(questID)
    local record = Store()[questID]

    if not record then
        return
    end

    local observed = Observations(record)

    local characterKey = CN.characterKey or "unknown"

    for _, entry in ipairs(recentTurnIns) do
        -- Only within a short window; anything older is coincidence.
        if time() - entry.at <= 300 and entry.questID ~= questID then
            local candidate = observed[entry.questID]

            if not candidate then
                candidate = { seen = 0, characters = {} }
                observed[entry.questID] = candidate
            end

            candidate.seen = candidate.seen + 1

            -- Counted by character, not by sighting: doing the same chain
            -- twice on one character is still one character's opinion.
            candidate.characters[characterKey] = true
        end
    end
end

-- How many distinct characters have shown this ordering.
function Harvest.Confidence(record, prerequisiteID)
    local observed = record and record.observed

    local candidate = observed and observed[prerequisiteID]

    if not candidate then
        return 0
    end

    return CN.CountKeys(candidate.characters or {})
end

-- Prerequisites confident enough to act on, for one quest.
function Harvest.ConfidentPrerequisites(questID)
    local record = Store()[questID]

    if not record or not record.observed then
        return {}
    end

    local confident = {}

    for prerequisiteID in pairs(record.observed) do
        if Harvest.Confidence(record, prerequisiteID) >= Harvest.confidenceThreshold then
            table.insert(confident, prerequisiteID)
        end
    end

    table.sort(confident)

    return confident
end

-- Everything currently confident, across every harvested quest.
function Harvest.AllConfident()
    local edges = {}

    for questID, record in pairs(Store()) do
        local confident = Harvest.ConfidentPrerequisites(questID)

        if #confident > 0 then
            edges[questID] = confident
        end
    end

    return edges
end

-- Feeds confident observations into the dependency graph.
--
-- They go in under `observedRequires`, NOT `requires`. The eligibility checker
-- reads both but reports them differently, so "you have not done X" and "on
-- three of your characters X came first" never read as the same claim.
function Harvest.PublishConfident()
    local published = 0

    for questID, prerequisites in pairs(Harvest.AllConfident()) do
        CN.AddDependency(CN.ObjectiveKey(CN.objectiveTypes.QUEST, questID), {
            observedRequires = prerequisites,
        })

        published = published + 1
    end

    if published > 0 then
        DebugPrint("Published " .. published .. " observed prerequisite set(s).")
    end

    return published
end

CN:OnLogin(function()
    Harvest.ResetRecent()
    Harvest.PublishConfident()
end)

------------------------------------------------------------
-- SUMMARY
------------------------------------------------------------

function Harvest.Summary()
    local counts = {
        total       = 0,
        named       = 0,
        located     = 0,
        withRequires = 0,
        withGuesses = 0,
    }

    for _, record in pairs(Store()) do
        counts.total = counts.total + 1

        if record.name then counts.named = counts.named + 1 end
        if record.x and record.y then counts.located = counts.located + 1 end
        if record.requires then counts.withRequires = counts.withRequires + 1 end
        if record.maybeRequires then counts.withGuesses = counts.withGuesses + 1 end
    end

    return counts
end

------------------------------------------------------------
-- EXPORT
------------------------------------------------------------

-- Emits harvested rows in the exact shape Data\Quests.lua expects, so the
-- output can be pasted straight in and committed.
function Harvest.BuildExport(onlyLocated)
    local rows = {}

    for questID, record in pairs(Store()) do
        if not onlyLocated or (record.x and record.y) then
            table.insert(rows, record)
        end
    end

    table.sort(rows, function(a, b) return a.questID < b.questID end)

    local lines = {}

    for _, record in ipairs(rows) do
        table.insert(lines, "    [" .. record.questID .. "] = {")

        if record.name then
            table.insert(lines, '        name      = "'
                .. record.name:gsub('"', '\\"') .. '",')
        end

        if record.zone then
            table.insert(lines, '        -- ' .. record.zone)
        end

        if record.mapID then
            table.insert(lines, "        mapID     = " .. record.mapID .. ",")
        end

        if record.x and record.y then
            table.insert(lines, "        x         = " .. record.x .. ",")
            table.insert(lines, "        y         = " .. record.y .. ",")
        end

        if record.requiresLevel then
            table.insert(lines, "        requiresLevel = " .. record.requiresLevel .. ",")
        end

        if record.requires and #record.requires > 0 then
            table.insert(lines, "        requires  = { "
                .. table.concat(record.requires, ", ") .. " },")
        end

        -- Confident observations become real rows; everything below the
        -- threshold stays a comment for a human to confirm. The distinction
        -- survives into the exported file, so curation never has to guess
        -- which lines were inferred.
        local confident = Harvest.ConfidentPrerequisites(record.questID)

        if #confident > 0 then
            table.insert(lines, "        -- observed on "
                .. Harvest.confidenceThreshold .. "+ characters")
            table.insert(lines, "        requires  = { "
                .. table.concat(confident, ", ") .. " },")
        end

        local unconfirmed = {}

        for prerequisiteID in pairs(record.observed or {}) do
            local seen = Harvest.Confidence(record, prerequisiteID)

            if seen < Harvest.confidenceThreshold then
                table.insert(unconfirmed, prerequisiteID .. " (" .. seen .. ")")
            end
        end

        table.sort(unconfirmed)

        if #unconfirmed > 0 then
            table.insert(lines, "        -- unconfirmed, character count in "
                .. "brackets: " .. table.concat(unconfirmed, ", "))
        end

        table.insert(lines, "    },")
    end

    return table.concat(lines, "\n"), #rows
end

------------------------------------------------------------
-- EXPORT WINDOW
------------------------------------------------------------

local exportFrame

local function ShowExport(text, count)
    if not exportFrame then
        exportFrame = CN.UI.SafeCreateFrame("Frame", "CompletionNavigatorExportFrame",
            UIParent, "BasicFrameTemplateWithInset")

        exportFrame:SetSize(600, 420)
        exportFrame:SetPoint("CENTER")
        exportFrame:SetMovable(true)
        exportFrame:EnableMouse(true)
        exportFrame:RegisterForDrag("LeftButton")
        exportFrame:SetScript("OnDragStart", exportFrame.StartMoving)
        exportFrame:SetScript("OnDragStop", exportFrame.StopMovingOrSizing)
        exportFrame:SetFrameStrata("DIALOG")

        if exportFrame.TitleText then
            exportFrame.TitleText:SetText("Completion Navigator - Export")
        end

        local scroll = CN.UI.SafeCreateFrame("ScrollFrame", nil, exportFrame,
            "UIPanelScrollFrameTemplate")

        scroll:SetPoint("TOPLEFT", 12, -32)
        scroll:SetPoint("BOTTOMRIGHT", -32, 40)

        local edit = CreateFrame("EditBox", nil, scroll)

        edit:SetMultiLine(true)
        edit:SetFontObject("GameFontHighlightSmall")
        edit:SetWidth(540)
        edit:SetAutoFocus(false)
        edit:SetScript("OnEscapePressed", function() exportFrame:Hide() end)

        scroll:SetScrollChild(edit)

        exportFrame.edit = edit

        local hint = exportFrame:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
        hint:SetPoint("BOTTOMLEFT", 14, 14)
        hint:SetText("Ctrl+A then Ctrl+C, and paste into Data\\Quests.lua")

        table.insert(UISpecialFrames, "CompletionNavigatorExportFrame")
    end

    exportFrame.edit:SetText(text)
    exportFrame.edit:HighlightText()
    exportFrame.edit:SetFocus()
    exportFrame:Show()

    Print("Exported " .. count .. " harvested quests.")
end

------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

CN:RegisterEvent("QUEST_ACCEPTED", function(event, questID)
    Harvest.Capture(questID, "accepted")
    Harvest.NoteAccepted(questID)
end)

CN:RegisterEvent("QUEST_TURNED_IN", function(event, questID)
    -- Capture before noting: the client still answers for it right now, and
    -- stops shortly afterwards.
    Harvest.Capture(questID, "turnedin")
    Harvest.NoteTurnIn(questID)
end)

-- Quests already in the log when the addon loads would otherwise be missed.
CN:OnLogin(function()
    for _, info in ipairs(Blizzard.GetQuestLogEntries()) do
        Harvest.Capture(info.questID, "login")
    end
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "harvest",
    order   = 80,
    help    = "Show what has been harvested from play.",
    handler = function()
        local counts = Harvest.Summary()

        if counts.total == 0 then
            Print("Nothing harvested yet. Pick up and turn in quests with the addon loaded.")
            return
        end

        Print("Harvested quests: " .. counts.total)
        Print("  with names: " .. counts.named)
        Print("  with coordinates: " .. counts.located)
        Print("  with confirmed prerequisites: " .. counts.withRequires)
        Print("  with unconfirmed prerequisite guesses: " .. counts.withGuesses)
        Print("Use |cffffff00/cn export|r to emit them as Data\\Quests.lua rows.")
    end,
}

CN:RegisterCommand{
    name    = "harvestnow",
    order   = 81,
    help    = "Harvest every quest currently in the log.",
    handler = function()
        local captured = 0

        for _, info in ipairs(Blizzard.GetQuestLogEntries()) do
            if Harvest.Capture(info.questID, "manual") then
                captured = captured + 1
            end
        end

        Print("Harvested " .. captured .. " quests from the current log.")
    end,
}

CN:RegisterCommand{
    name    = "export",
    args    = "[all]",
    order   = 82,
    help    = "Emit harvested quests as Data\\Quests.lua rows.",
    handler = function(args)
        local onlyLocated = string.lower(args or "") ~= "all"

        local text, count = Harvest.BuildExport(onlyLocated)

        if count == 0 then
            Print("Nothing to export yet."
                .. (onlyLocated and " Try |cffffff00/cn export all|r to include "
                    .. "quests with no coordinates." or ""))
            return
        end

        ShowExport(text, count)
    end,
}

CN:RegisterCommand{
    name    = "providers",
    order   = 83,
    help    = "Show which external data addons were detected.",
    handler = function()
        Print("Quest data providers:")

        for _, entry in ipairs(CN.questDataOrder) do
            local provider = CN.questDataProviders[entry.name]

            local ok, isAvailable = pcall(provider.IsAvailable)

            local status = (ok and isAvailable)
                and "|cff00ff00available|r"
                or "|cff999999unavailable|r"

            local detail = ""

            if provider.Describe then
                local described, text = pcall(provider.Describe)

                if described and text then
                    detail = " |cff999999(" .. text .. ")|r"
                end
            end

            Print("  " .. entry.name .. ": " .. status .. detail)
        end

        Print("Waypoint providers:")

        for _, entry in ipairs(CN.waypointOrder) do
            local provider = CN.waypointProviders[entry.name]

            local ok, isAvailable = pcall(provider.IsAvailable)

            Print("  " .. entry.name .. ": "
                .. ((ok and isAvailable) and "|cff00ff00available|r" or "|cff999999unavailable|r"))
        end
    end,
}

CN:RegisterCommand{
    name    = "lookup",
    args    = "<questID>",
    order   = 84,
    help    = "Ask every external provider about a quest.",
    handler = function(args)
        local questID = CN.ToID(args)

        if not questID then
            Print("Usage: /cn lookup <questID>")
            return
        end

        local data = CN.QueryQuestDataProviders(questID)

        if not data then
            Print("No external provider knows quest " .. questID .. ".")
            Print("Run |cffffff00/cn providers|r to see what is installed.")
            return
        end

        Print("Quest " .. questID .. " |cff999999via "
            .. table.concat(data.providers or {}, ", ") .. "|r")

        if data.name then Print("  name: " .. data.name) end

        if data.mapID then
            Print("  map: " .. data.mapID
                .. (data.x and string.format(" at %.1f, %.1f", data.x * 100, data.y * 100) or ""))
        end

        if data.requiresLevel then Print("  level: " .. data.requiresLevel) end

        if data.requires then
            Print("  requires: " .. table.concat(data.requires, ", "))
        end
    end,
}

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
