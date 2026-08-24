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

-- The map's name, derived rather than remembered.
function Harvest.Zone(record)
    if type(record) ~= "table" or not record.mapID then
        return nil
    end

    return Blizzard.GetMapName(record.mapID)
end

-- A CEILING, BECAUSE THIS IS THE LARGEST THING THE ADDON SAVES.
--
-- Every quest accepted, turned in, or seen at login gets a permanent record,
-- and there was no cap and no prune. Migration 6 gave `questPins` a ceiling
-- of 600 for exactly this reason and did not touch this store, whose rows are
-- larger.
Harvest.cap = 2000

-- HYSTERESIS, WHICH IS NOT OPTIONAL AT THE CEILING.
--
-- "Count before allocating" fixed the case below the cap and did nothing at
-- it: once the store holds `cap + 1` rows, EVERY capture builds a 2001-row
-- array and sorts it to drop exactly one row -- and `Capture` runs in a loop
-- over the whole quest log at login. Measured: 82 ms of blocked frames for
-- forty captures, against 1.6 ms below the cap. It also threw away the unlock
-- inversion forty times in the process.
--
-- Let it overshoot by a tenth, then prune back to the cap. One sort per two
-- hundred captures instead of one per capture, for two hundred rows of slack
-- on a store that holds two thousand. `Session.offerMemoryCap` has had this
-- since 0.28.0 for the same reason.
Harvest.pruneSlack = 200

-- AND THE EVICTION ORDER WAS BACKWARDS FOR THE PLAYER MOST LIKELY TO HIT IT.
--
-- It dropped the lowest quest ids, on the reasoning that a low id is old
-- content nobody is working on. That reasoning describes a max-level
-- character doing current content. It describes the exact opposite of a
-- levelling alt, whose entire quest log is low ids -- so the store threw away
-- the records for the zones that character is standing in, kept the main's
-- endgame chains, and did it again on the next capture.
--
-- Least-recently-seen instead. `lastSeen` is stamped on every capture, so it
-- means "the addon has not touched this quest in a while" regardless of which
-- expansion it belongs to -- which is the actual question. A record with no
-- `lastSeen` is from before it was recorded and goes first.
--
-- Ties break on the quest id so the result is deterministic; two records
-- written in the same second must not evict in table order, which is not an
-- order.
function Harvest.Prune()
    local store = Store()

    -- COUNT FIRST, ALLOCATE SECOND.
    --
    -- `Prune` runs at the end of every `Capture`, and `Capture` runs in a loop
    -- over the whole quest log at login. Building the sort array before
    -- checking the cap meant two thousand table allocations per captured
    -- quest, thrown away immediately in the overwhelmingly common case where
    -- there is nothing to prune. `Session.Prune` and `Preference.Prune` both
    -- check a cheap counter first, for exactly this reason.
    local held = 0

    for _ in pairs(store) do
        held = held + 1
    end

    if held <= (Harvest.cap + Harvest.pruneSlack) then
        return 0
    end

    local rows = {}

    for questID, record in pairs(store) do
        table.insert(rows, {
            id   = questID,
            seen = (type(record) == "table" and record.lastSeen) or 0,
        })
    end

    table.sort(rows, function(a, b)
        if a.seen == b.seen then
            return a.id < b.id
        end

        return a.seen < b.seen
    end)

    local dropped = #rows - Harvest.cap

    for index = 1, dropped do
        store[rows[index].id] = nil
    end

    -- THROUGH `NoteUnlocksChanged`, NOT BY TOUCHING THE COUNTER.
    --
    -- That function's own header explains why bumping `unlockGeneration`
    -- alone is not enough: the Unlocks decorator only consults it if
    -- `Decorate` runs at all, and the unchanged-provider shortcut skips
    -- that. So after a prune dropped rows, quests kept an `unlockValue` --
    -- weight 1.5, the second-heaviest term -- and a `/cn why` sentence
    -- reading "4 quests you have seen come after this one", derived from
    -- records that no longer existed.
    Harvest.NoteUnlocksChanged()

    DebugPrint("Pruned " .. dropped .. " least-recently-seen harvested "
        .. "quest(s) over the ceiling.")

    return dropped
end

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

    -- ZONE IS NOT STORED. It is `GetMapName(record.mapID)`, which the client
    -- answers for free and forever -- the same duplication migrations 4 and 5
    -- removed from items, achievements and pets. The coordinates genuinely
    -- are not re-suppliable after a turn-in and stay; the name of the map
    -- they are on always is.
    --
    -- Read back through Harvest.Zone below, so nothing that wants it has to
    -- know where it comes from.

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

                Harvest.NoteUnlocksChanged()

                -- `requiresFrom`: which addons answered. It was written as
                -- `requiredBy`, a name meaning the opposite -- the quests
                -- this one unlocks -- and read by nothing, so the misnomer
                -- had no effect beyond misleading the next reader.
                record.requiresFrom = external.providers
                changed = true
            end
        end
    end

    record.lastSeen = time()
    record.reason   = record.reason or reason

    store[questID] = record

    Harvest.Prune()

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
    local published, recorded = 0, 0

    local store = Store()

    for questID, prerequisites in pairs(Harvest.AllConfident()) do
        CN.AddDependency(CN.ObjectiveKey(CN.objectiveTypes.QUEST, questID), {
            observedRequires = prerequisites,
        })

        published = published + 1

        -- AND WRITE IT FLAT, so the toolkit can fold it into Data\Quests.lua
        -- without having to understand the nested evidence table.
        --
        -- Until 0.42.0 the confident sets existed only in memory and in the
        -- dependency graph, which meant the shipped static data could never
        -- learn anything from real play -- the whole point of harvesting.
        --
        -- UNDER ITS OWN NAME, NOT `requires`.
        --
        -- Writing it as `requires` was the first attempt and it was wrong: the
        -- eligibility checker reads that field as curated fact, so /cn why
        -- stopped saying "on three of your characters X came first" and
        -- started saying "X is required" -- inference masquerading as
        -- authority, through a door I had just built for it. The existing
        -- test for that distinction caught it.
        local record = store[questID]

        if record and not record.observedRequires and #prerequisites > 0 then
            record.observedRequires = prerequisites

            -- The unlock index is an inversion of exactly this field.
            Harvest.NoteUnlocksChanged()

            recorded = recorded + 1
        end
    end

    if recorded > 0 then
        DebugPrint("Recorded " .. recorded
            .. " observed prerequisite set(s) for export.")
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
        -- `record.observed`, not `record.maybeRequires`. The old field was
        -- deleted by database migration 3 and nothing has written it since,
        -- so this counter reported zero guesses on every database in
        -- existence -- including every database that was full of them. The
        -- reader outlived the field by four schema versions because nothing
        -- ever asserted on the number it produced.
        if record.observed and next(record.observed) then
            counts.withGuesses = counts.withGuesses + 1
        end
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

        local zone = Harvest.Zone(record)

        if zone then
            table.insert(lines, '       " .. CN.DASH .. "' .. zone)
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
        --
        -- `observedRequires`, NOT `requires`. Two things were wrong with
        -- writing it as `requires`. It emitted the key a second time in the
        -- same table constructor, so a quest that had both a provider answer
        -- and three-character agreement lost the provider's list entirely --
        -- Lua keeps the last assignment. And it is exactly the door
        -- PublishConfident closes thirty lines above, in a comment calling it
        -- "inference masquerading as authority": the runtime path was fixed
        -- and the export path -- the one that actually ships inference to
        -- other players -- still wrote it under the curated name.
        local confident = Harvest.ConfidentPrerequisites(record.questID)

        if #confident > 0 then
            table.insert(lines, "       " .. CN.DASH .. "observed on "
                .. Harvest.confidenceThreshold .. "+ characters")
            table.insert(lines, "        observedRequires = { "
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
            table.insert(lines, "       " .. CN.DASH .. "unconfirmed, character count in "
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
        edit:SetFontObject(CN.FONT.SMALL)
        edit:SetWidth(540)
        edit:SetAutoFocus(false)
        edit:SetScript("OnEscapePressed", function() exportFrame:Hide() end)

        scroll:SetScrollChild(edit)

        exportFrame.edit = edit

        local hint = exportFrame:CreateFontString(nil, "ARTWORK", CN.FONT.LABEL)
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
        Print("Use |cffffc74f/cn export|r to emit them as Data\\Quests.lua rows.")
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
                .. (onlyLocated and " Try |cffffc74f/cn export all|r to include "
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
                and "|cff73b873available|r"
                or "|cff8a8f96unavailable|r"

            local detail = ""

            if provider.Describe then
                local described, text = pcall(provider.Describe)

                if described and text then
                    detail = " |cff8a8f96(" .. text .. ")|r"
                end
            end

            CN.PrintLine("  " .. entry.name .. ": " .. status .. detail)
        end

        Print("Waypoint providers:")

        for _, entry in ipairs(CN.waypointOrder) do
            local provider = CN.waypointProviders[entry.name]

            local ok, isAvailable = pcall(provider.IsAvailable)

            CN.PrintLine("  " .. entry.name .. ": "
                .. ((ok and isAvailable) and "|cff73b873available|r" or "|cff8a8f96unavailable|r"))
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
            Print("Run |cffffc74f/cn providers|r to see what is installed.")
            return
        end

        Print("Quest " .. questID .. " |cff8a8f96via "
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

------------------------------------------------------------
-- WHAT A QUEST UNLOCKS
------------------------------------------------------------

-- A SCORING TERM WITH ONE PRODUCER OUT OF TWENTY-TWO.
--
-- `unlockValue` carries a weight of 1.5 -- the second-heaviest term in the
-- scorer, above urgency and well above travel. Exactly one provider ever set
-- it: `Modules/Inventory.lua`, which writes a flat 1 for an item that teaches
-- something. Every quest, reputation, renown, profession and dungeon in the
-- addon contributed zero to "what it unlocks", for ever -- so the term did
-- not rank anything, it just sat in the explanation printing 0.00 and made
-- the arithmetic look thorough.
--
-- The addon already collects the evidence. `observedRequires` records, per
-- quest, which quests were seen completed before it across the player's own
-- characters. Invert that and you have, for a given quest, how many other
-- quests have been observed to sit behind it. That is what "unlocks" means,
-- measured, from this account's own play.
--
-- NO INVENTION. A quest nothing has been observed behind scores zero, exactly
-- as it does today. This raises a quest only on evidence the player generated
-- themselves, and `/cn why` names the count.

-- Rebuilt when the harvest changes rather than on every scoring pass: the
-- inversion is a full walk of a store that can hold two thousand rows, and
-- the ranking scores two hundred candidates.
Harvest.unlockGeneration = Harvest.unlockGeneration or 0

local unlockIndex, unlockIndexGeneration

-- Above this many, one more unlocked quest tells the ranking nothing it did
-- not already know, and a hub quest with forty followers must not out-score
-- everything else in the zone on its own.
Harvest.unlockCap = 6

-- AND SAY SO LOUDLY ENOUGH THAT SOMETHING ACTUALLY REDECORATES.
--
-- Bumping the counter was the whole of this, and the decorator only consults
-- the counter if `Decorate` runs at all -- which the unchanged-provider
-- shortcut skips, which is the normal case. So the count the release claims
-- to have unfrozen stayed frozen: the guard was correct and unreachable.
--
-- `CN.decoratorGeneration` is exactly the hook. The reuse condition requires
-- `entry.decorated == CN.decoratorGeneration`, so bumping it makes every
-- provider re-decorate on its next rebuild, and invalidating the candidates
-- makes that rebuild happen.
function Harvest.NoteUnlocksChanged()
    Harvest.unlockGeneration = Harvest.unlockGeneration + 1

    CN.NoteDecoratorsChanged()
end

function Harvest.UnlockIndex()
    if unlockIndex and unlockIndexGeneration == Harvest.unlockGeneration then
        return unlockIndex
    end

    local index = {}

    for _, record in pairs(Store()) do
        if type(record) == "table" then
            -- Both sources, and deduplicated per record: a prerequisite named
            -- by the external provider AND observed in play is one unlock,
            -- not two.
            local counted = {}

            -- NOT `ipairs({ record.requires, record.observedRequires })`.
            --
            -- A record with no `requires` makes that a table whose first
            -- element is nil, and `ipairs` stops at the hole -- so the
            -- observed list, which is the one this addon actually harvests,
            -- would be skipped for every record that has no external data.
            -- Which is nearly all of them.
            local function Count(list)
                for _, prerequisiteID in ipairs(list or {}) do
                    if not counted[prerequisiteID] then
                        counted[prerequisiteID] = true

                        index[prerequisiteID] = (index[prerequisiteID] or 0) + 1
                    end
                end
            end

            Count(record.requires)
            Count(record.observedRequires)
        end
    end

    unlockIndex           = index
    unlockIndexGeneration = Harvest.unlockGeneration

    return index
end

-- How many quests this account has observed sitting behind a given quest.
function Harvest.UnlockCount(questID)
    questID = CN.ToID(questID)

    if not questID then
        return 0
    end

    return Harvest.UnlockIndex()[questID] or 0
end

CN.RegisterCandidateDecorator("Unlocks", function(objective)
    if not objective or objective.type ~= CN.objectiveTypes.QUEST then
        return
    end

    -- A provider that has its own opinion keeps it. This fills a gap; it does
    -- not overrule anybody.
    if objective.unlockValue ~= nil and objective.unlockGeneration == nil then
        return
    end

    -- MEASURED AGAINST THE GENERATION, NOT AGAINST NIL.
    --
    -- A plain "already set, leave it" froze the first answer for the session:
    -- since 0.55.0 a provider's tables are REUSED across rebuilds, so the
    -- objective carrying a count of two still carried two after ten more
    -- quests were harvested behind it -- on a weight-1.5 term, with `/cn why`
    -- stating a number the addon knew was wrong.
    if objective.unlockGeneration == Harvest.unlockGeneration then
        return
    end

    objective.unlockGeneration = Harvest.unlockGeneration
    objective.unlockValue      = nil

    local count = Harvest.UnlockCount(objective.id)

    if count <= 0 then
        CN.ClearDecoratorReason(objective, "unlocks")

        return
    end

    -- Scaled to the same 0..1 range every other term uses, so the weight in
    -- `CN.scoreWeights` means what it says.
    objective.unlockValue = math.min(1, count / Harvest.unlockCap)

    -- Through the keyed mechanism, so the sentence is REPLACED when the count
    -- changes and WITHDRAWN when it goes to zero -- rather than appended to
    -- once per rebuild, which is what an unkeyed insert does now that tables
    -- are reused.
    CN.AddDecoratorReason(objective, "unlocks", count == 1
        and "one quest you have seen comes after this one"
        or (count .. " quests you have seen come after this one"))
end)

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
