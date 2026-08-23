-- Modules/Breakdown.lua
-- Completion Navigator :: "why isn't this 100%?"
--
-- Every other module answers what it tracks. None of them answer the
-- question a completionist actually asks, which is why a category is not
-- finished and what specifically is in the way.
--
-- Two rules shape this module.
--
-- 1. A percentage is only shown where the denominator is trustworthy. The
--    client knows exactly how many mounts exist; nobody knows how many
--    quests exist. Where the denominator is unknown, counts are shown and
--    the reason is stated, rather than inventing a number that looks
--    authoritative and is not.
--
-- 2. Every line says what to do next, not just what is missing. "4 vendor
--    recipes" is trivia; "4 recipes, open the profession window to see
--    which" is an instruction.

local ADDON_NAME, CN = ...

local Breakdown = CN:RegisterModule("Breakdown")

local Print = CN.Print

-- "1 are locked" reads as a bug even when the number is right.
local function Are(count)
    return count == 1 and "is" or "are"
end

local function Plural(count, singular, plural)
    return count == 1 and singular or (plural or (singular .. "s"))
end

------------------------------------------------------------
-- REGISTRY
------------------------------------------------------------

-- Each category reports: collected, total (or nil when unknowable),
-- remaining lines, and the next action.
Breakdown.categories = {}

function Breakdown.Register(definition)
    if type(definition) ~= "table" or not definition.name then
        return
    end

    definition.order = definition.order or 100

    table.insert(Breakdown.categories, definition)

    table.sort(Breakdown.categories, function(a, b)
        if a.order == b.order then
            return a.name < b.name
        end

        return a.order < b.order
    end)
end

------------------------------------------------------------
-- REPORT
------------------------------------------------------------

local function Percentage(collected, total)
    if not total or total <= 0 then
        return nil
    end

    return collected / total * 100
end

-- CACHED, because the Remaining tab asks for it every two seconds and
-- nothing in it changes except when a collection does.
--
-- Measured: 0.63 ms per call, of which 0.24 ms walks three thousand
-- achievement rows and 0.16 ms walks eighteen hundred pets -- to produce
-- numbers that are identical until the player collects something, and every
-- collection already fires an event this addon subscribes to.
Breakdown.generation = 0

local reportCache, reportGeneration

function Breakdown.NoteChanged()
    Breakdown.generation = Breakdown.generation + 1
end

-- `force` IS NOT A LUXURY.
--
-- The cache is keyed on a generation bumped by nine collection events, and
-- most of what this report counts is not a collection: harvested quests,
-- captured recipes, scanned vendors. So the Remaining tab's own Refresh
-- button -- whose tooltip says "counts what is left again" -- could not
-- recount, and a row that says "run /cn harvest" went on showing the old
-- number after the player ran it.
--
-- Anything that ASKED for a recount gets one.
function Breakdown.Report(categoryName, force)
    if not categoryName and not force then
        if reportCache and reportGeneration == Breakdown.generation then
            return reportCache
        end
    end

    local rows = {}

    for _, category in ipairs(Breakdown.categories) do
        if not categoryName
            or string.lower(category.name) == string.lower(categoryName) then

            local ok, result = pcall(category.report)

            if ok and type(result) == "table" then
                result.name  = category.name
                result.order = category.order

                table.insert(rows, result)
            elseif not ok then
                -- A category that throws was dropped with no trace, so if
                -- every one of them threw the report said "Nothing to report
                -- yet. Run the scans first." -- which sends the player to do
                -- work that will not help.
                local errors = CN:GetModule("Errors")

                if errors and errors.Record then
                    pcall(errors.Record, "breakdown:" .. tostring(category.name),
                        tostring(result))
                end
            end
        end
    end

    if not categoryName then
        reportCache      = rows
        reportGeneration = Breakdown.generation
    end

    return rows
end

------------------------------------------------------------
-- BUILT-IN CATEGORIES
------------------------------------------------------------

Breakdown.Register{
    name  = "Mounts",
    order = 10,
    report = function()
        local module = CN:GetModule("Mounts")

        if not module then return nil end

        local counts = module.Summary()

        local reasons = {}

        if counts.wrongFaction > 0 then
            table.insert(reasons, counts.wrongFaction .. " " .. Are(counts.wrongFaction)
                .. " locked to the opposite faction")
        end

        return {
            collected = counts.collected,
            total     = counts.known,
            remaining = counts.missing,
            reasons   = reasons,
            action    = counts.known == 0 and "/cn mountscan" or nil,
        }
    end,
}

Breakdown.Register{
    name  = "Pets",
    order = 11,
    report = function()
        local module = CN:GetModule("Pets")

        if not module then return nil end

        local counts = module.Summary()

        local reasons = {}

        if counts.unobtainable > 0 then
            table.insert(reasons, counts.unobtainable .. " " .. Are(counts.unobtainable)
                .. " no longer obtainable and can never be collected")
        end

        if counts.wildMissing > 0 then
            table.insert(reasons, counts.wildMissing .. " " .. Are(counts.wildMissing) .. " "
                .. Plural(counts.wildMissing, "a wild pet", "wild pets")
                .. " you can catch in the world")
        end

        return {
            collected = counts.collected,
            total     = counts.known,
            remaining = counts.missing,
            reasons   = reasons,
            action    = counts.known == 0 and "/cn petscan" or nil,
        }
    end,
}

Breakdown.Register{
    name  = "Toys",
    order = 12,
    report = function()
        local module = CN:GetModule("Toys")

        if not module then return nil end

        local counts = module.Summary()

        return {
            collected = counts.collected,
            total     = counts.known,
            remaining = counts.missing,
            action    = counts.known == 0 and "/cn toyscan" or nil,
        }
    end,
}

Breakdown.Register{
    name  = "Appearances",
    order = 13,
    report = function()
        local module = CN:GetModule("Appearances")

        if not module then return nil end

        local counts = module.Summary()
        local rows   = module.Remaining()

        local reasons = {}

        for index = 1, math.min(3, #rows) do
            table.insert(reasons, rows[index].name .. ": "
                .. rows[index].remaining .. " left")
        end

        return {
            collected = counts.collected,
            total     = counts.total,
            remaining = counts.total - counts.collected,
            reasons   = reasons,
            action    = counts.categories == 0 and "/cn appearancescan" or nil,
        }
    end,
}

Breakdown.Register{
    name  = "Achievements",
    order = 14,
    report = function()
        local module = CN:GetModule("Achievements")

        if not module then return nil end

        local counts = module.Summary()

        local reasons = {}

        if counts.nearlyDone > 0 then
            table.insert(reasons, counts.nearlyDone .. " " .. Are(counts.nearlyDone)
                .. " within two criteria of finishing")
        end

        return {
            collected = counts.completed,
            total     = counts.total,
            remaining = counts.total - counts.completed,
            reasons   = reasons,
            -- SCAN STATE IS NOT THE LIVE TOTAL.
            --
            -- `counts.total` comes from the client, so it is never zero and
            -- this branch could never fire: a player who has never scanned
            -- saw a healthy "1200 / 3400 (35.3%)" with no in-progress rows and
            -- no prompt to scan. The scan is what fills `inProgress`, so that
            -- is what says whether it has run.
            action    = counts.inProgress == 0 and "/cn achievescan"
                or (counts.nearlyDone > 0 and "/cn closest" or nil),
        }
    end,
}

Breakdown.Register{
    name  = "Titles",
    order = 15,
    report = function()
        local module = CN:GetModule("Titles")

        if not module then return nil end

        local counts = module.Summary()

        local reasons = {}

        if counts.onAccount > counts.onThisOne then
            local elsewhere = counts.onAccount - counts.onThisOne

            table.insert(reasons, elsewhere .. " " .. Are(elsewhere)
                .. " held by another character, not this one")
        end

        return {
            collected = counts.onAccount,
            total     = counts.known,
            remaining = counts.known - counts.onAccount,
            reasons   = reasons,
            action    = counts.known == 0 and "/cn titlescan" or nil,
        }
    end,
}

Breakdown.Register{
    name  = "Reputations",
    order = 16,
    report = function()
        local module = CN:GetModule("Reputations")

        if not module then return nil end

        local counts = module.Summary()

        local reasons = {}

        if counts.paragonPending > 0 then
            table.insert(reasons, counts.paragonPending .. " " .. Plural(counts.paragonPending, "has", "have")
                .. " a Paragon reward waiting to be collected")
        end

        if counts.character > 0 then
            table.insert(reasons, counts.character .. " " .. Are(counts.character)
                .. " character-specific, so an alt may be further ahead")
        end

        -- Total factions in the game is not knowable from the client.
        return {
            collected = counts.exalted + counts.maxedRenown,
            total     = nil,
            remaining = nil,
            unknownTotal = "the client does not expose how many factions exist",
            reasons   = reasons,
            action    = (counts.account + counts.character) == 0
                and "/cn repscan"
                or (counts.paragonPending > 0 and "/cn paragon" or nil),
        }
    end,
}

Breakdown.Register{
    name  = "Recipes",
    order = 17,
    report = function()
        local module = CN:GetModule("Professions")

        if not module then return nil end

        local waiting = module.AwaitingRecipeCapture()

        local reasons = {}

        if #waiting > 0 then
            table.insert(reasons, "recipe lists not captured for: "
                .. table.concat(waiting, ", "))
        end

        local known = 0

        for _, record in ipairs(module.Summary()) do
            known = known + (record.recipeKnown or 0)
        end

        return {
            collected    = known,
            total        = nil,
            unknownTotal = "recipes are only countable while a profession window is open",
            reasons      = reasons,
            action       = #waiting > 0 and "open each profession window once" or nil,
        }
    end,
}

Breakdown.Register{
    name  = "Quests",
    order = 18,
    report = function()
        local discovered = CN.CountKeys(CN.Account("discoveredQuests"))

        -- ASKED OF THE CLIENT, FOR THIS CHARACTER.
        --
        -- This counted an account-wide `questStatus` store whose
        -- `characterCompleted` flag belonged to whichever character last
        -- scanned, so a fresh alt was shown the main's progress. The client
        -- answers per character, for free, and `discoveredQuests` is the set
        -- worth asking about.
        local quests = CN:GetModule("Quests")

        local completed = 0

        if quests and quests.IsCompletedByCharacter then
            for questID in pairs(CN.Account("discoveredQuests")) do
                if quests.IsCompletedByCharacter(questID) then
                    completed = completed + 1
                end
            end
        end

        return {
            collected    = completed,
            total        = nil,
            unknownTotal = "no API reports how many quests exist; "
                .. "only quests this addon has seen can be counted",
            reasons      = {
                discovered .. " quests discovered so far",
                CN.CountKeys(CN.Account("questHarvest")) .. " harvested with location data",
            },
            action = "/cn harvest",
        }
    end,
}

Breakdown.Register{
    name  = "Currencies",
    order = 19,
    report = function()
        local module = CN:GetModule("Currencies")

        if not module then return nil end

        local counts = module.Summary()

        local reasons = {}

        if counts.capped > 0 then
            table.insert(reasons, counts.capped .. " " .. Are(counts.capped)
                .. " at cap; further earning is wasted")
        end

        if counts.weeklyUnfilled > 0 then
            table.insert(reasons, counts.weeklyUnfilled .. " still " .. Plural(counts.weeklyUnfilled, "has", "have")
                .. " weekly earning available")
        end

        return {
            collected    = counts.known - counts.capped,
            total        = nil,
            unknownTotal = "currencies are a state to manage, not a set to complete",
            reasons      = reasons,
            action       = counts.capped > 0 and "/cn currencies" or nil,
        }
    end,
}

------------------------------------------------------------
-- COMMAND
------------------------------------------------------------

local function PrintRow(row)
    local percentage = Percentage(row.collected, row.total)

    if percentage then
        Print(string.format("|cffffc74f%s|r  %d / %d  (%.1f%%)",
            row.name, row.collected, row.total, percentage))
    else
        Print(string.format("|cffffc74f%s|r  %d collected",
            row.name, row.collected or 0))

        if row.unknownTotal then
            Print("    |cff8a8f96no percentage: " .. row.unknownTotal .. "|r")
        end
    end

    for _, reason in ipairs(CN.Reasons(row)) do
        CN.PrintLine("    " .. reason)
    end

    if row.action then
        Print("    |cffffc74f-> " .. row.action .. "|r")
    end
end

CN:RegisterCommand{
    name    = "breakdown",
    aliases = { "remaining" },
    args    = "[category]",
    order   = 19,
    help    = "Explain what is left in each category, and why.",
    handler = function(args)
        local requested = args ~= "" and args or nil

        local rows = Breakdown.Report(requested)

        if #rows == 0 then
            if requested then
                Print("No category matches: " .. requested)

                local names = {}

                for _, category in ipairs(Breakdown.categories) do
                    table.insert(names, category.name)
                end

                Print("Try: " .. table.concat(names, ", "))
            else
                Print("Nothing to report yet. Run the scans first.")
            end

            return
        end

        Print("What is left, and why:")

        for _, row in ipairs(rows) do
            PrintRow(row)
        end

        if not requested then
            Print("|cff8a8f96/cn breakdown <category> for one at a time.|r")
        end
    end,
}

-- EVERY EVENT THAT CAN CHANGE A COUNT IN HERE.
--
-- The report walks three thousand achievement rows and eighteen hundred pets
-- to produce numbers that are identical until the player collects something
-- -- and every collection already announces itself. The Remaining tab asked
-- for it every two seconds.
--
-- TWO OF THEM ARE TICKERS, NOT ANNOUNCEMENTS. `UPDATE_FACTION` fires on
-- nearly every reputation tick and `CURRENCY_DISPLAY_UPDATE` on every coin
-- picked up, so while a player was earning anything the Remaining tab's
-- two-second refresh found the 0.63 ms report cache stale on every single
-- tick -- which is the cache doing nothing at all, in the one place it was
-- written for. The other seven fire when something is genuinely collected
-- and stay immediate.
local bursty = {
    UPDATE_FACTION          = true,
    CURRENCY_DISPLAY_UPDATE = true,
}

Breakdown.burstSeconds = 5

for _, event in ipairs({
    "NEW_PET_ADDED", "NEW_MOUNT_ADDED", "NEW_TOY_ADDED",
    "ACHIEVEMENT_EARNED", "TRANSMOG_COLLECTION_UPDATED",
    "QUEST_TURNED_IN", "UPDATE_FACTION", "CURRENCY_DISPLAY_UPDATE",
    "PLAYER_ENTERING_WORLD",
}) do
    local burst = bursty[event]

    CN:RegisterEvent(event, function()
        if burst then
            CN.Debounce("Breakdown." .. event, Breakdown.burstSeconds,
                Breakdown.NoteChanged)
            return
        end

        Breakdown.NoteChanged()
    end)
end

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
