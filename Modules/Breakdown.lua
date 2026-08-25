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

-- THROUGH THE SHARED ONE. 0.64.0.
--
-- This file kept a private copy of the pluralizer while `CN.Pluralize` had
-- exactly one caller and twenty-two other places hand-rolled the same
-- expression. Nothing was wrong -- it is the one-fix-one-call-site shape
-- pre-loaded, and the next grammar change would have landed in one of
-- twenty-three places.
local Plural = CN.Pluralize

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

-- TWO LISTS OF "WHAT CHANGES A COLLECTION COUNT", AND THEY DRIFTED. 0.62.0.
--
-- This file kept its own event list and `Scoring.lua` kept another for
-- `CN.collectionGeneration`. The second one gained the profession, title and
-- level events in 0.61.0 and this one did not -- and this file reports a
-- Recipes row and a Titles row. So a player learned forty recipes in their
-- Alchemy window, the Collections tab moved, and `/cn breakdown` and the
-- Remaining tab went on serving the old figure until some unrelated pet or
-- quest event happened along. `CN.MarkScanned` bumped one counter and not the
-- other, so `/cn profscan` followed by `/cn breakdown` reported the pre-scan
-- count.
--
-- There is now ONE list, in Scoring.lua, and this cache reads it. A rule
-- written down twice is a rule that drifts; this project has now found that
-- shape in the invalidator, the window's refresh events, the collection
-- generation and here.
local function CacheKey()
    return Breakdown.generation .. ":" .. tostring(CN.collectionGeneration or 0)
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
    -- AND A FORCED RECOUNT RECOUNTS THE QUESTS TOO. 0.61.0.
    --
    -- The quest figure is maintained incrementally against a snapshot taken
    -- once, and both edges are credited as they happen -- a discovery and a
    -- turn-in. That is correct for ordinary play and is exactly what this
    -- parameter exists to override: the player pressed Refresh, or ran a
    -- scan, and is asking to be told the truth rather than the remembered
    -- answer.
    --
    -- Same rule as the paragraph above, applied to the one figure in this
    -- file that does not live in `reportCache`.
    if force then
        Breakdown.ForgetQuestCounts()
    end

    if not categoryName and not force then
        if reportCache and reportGeneration == CacheKey() then
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
        reportGeneration = CacheKey()
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

-- THIRTY THOUSAND CLIENT CALLS, FOR A NUMBER THAT MOVES BY ONE. 0.61.0.
--
-- This walked every quest the addon has ever discovered -- around 30,000 on
-- an established account -- calling `IsQuestFlaggedCompleted` on each, and it
-- ran on every invalidated Remaining refresh. Measured on the game's own Lua
-- 5.1 at that scale: 13.65 ms, which is most of a frame, for a figure that
-- changes by exactly one when a quest is handed in.
--
-- It is now counted once and then MAINTAINED. A turn-in adds one; a rescan
-- that grows the discovered set recounts. The count is per character, because
-- `IsQuestFlaggedCompleted` answers for the character asking -- the same
-- mistake this category's own comment says it was fixing.
--
-- Held in memory, not on disk: it is derived from something the client
-- re-supplies for free, so persisting it would be the other standing rule
-- broken to fix this one.
local questCounts = {}

function Breakdown.ForgetQuestCounts()
    questCounts = {}
end

function Breakdown.CompletedQuestCount()
    local quests = CN:GetModule("Quests")

    if not quests or not quests.IsCompletedByCharacter then
        return 0
    end

    local key = CN.characterKey or CN.GetCharacterKey()

    local discovered = CN.Account("discoveredQuests")

    local held = questCounts[key]

    -- THE SET GROWING IS NOT A REASON TO RECOUNT ALL OF IT. 0.63.0.
    --
    -- The key was the SIZE of the discovered set, and `RecordDiscovered`
    -- fires from map sweeps, gossip and the quest log -- dozens of new ids on
    -- walking into fresh content. So with the Remaining tab open the sequence
    -- "enter a new zone, hand in a quest" put the whole 30,000-entry walk
    -- back, once per turn-in, for as long as the player was somewhere new.
    -- That is the 13.7 ms this cache was written to remove, returning exactly
    -- where questing puts a player most often.
    --
    -- A newly discovered quest is almost never already completed -- it was
    -- just offered -- and where it is, `NoteDiscovered` below asks the client
    -- about that ONE id, which is a single call rather than thirty thousand.
    -- So the snapshot is now keyed on nothing but its own existence, and both
    -- edges of the count are maintained incrementally: discoveries in, and
    -- turn-ins in.
    --
    -- `Breakdown.ForgetQuestCounts` remains the way to demand a real recount,
    -- and the Remaining tab's Refresh button passes `force` to reach it.
    if held then
        return held.completed
    end

    local completed = 0

    -- The set of ids this figure includes, so a later turn-in cannot credit
    -- one of them twice. Built here rather than lazily: the walk is happening
    -- anyway and the alternative is a second walk later.
    local counted = {}

    for questID in pairs(discovered) do
        if quests.IsCompletedByCharacter(questID) then
            completed = completed + 1

            counted[questID] = true
        end
    end

    questCounts[key] = {
        completed = completed,
        counted   = counted,
    }

    return completed
end

-- Called when a quest is discovered. One client call, not thirty thousand.
--
-- A quest the addon has just seen offered is almost never already completed,
-- but "almost never" is not never -- a repeatable, or a quest first seen on a
-- character who did it years ago. Asking about the one id keeps the snapshot
-- exact without the walk.
function Breakdown.NoteQuestDiscovered(questID)
    local key = CN.characterKey or CN.GetCharacterKey()

    local held = questCounts[key]

    if not held or not questID then
        return
    end

    held.counted = held.counted or {}

    if held.counted[questID] then
        return
    end

    local quests = CN:GetModule("Quests")

    if not quests or not quests.IsCompletedByCharacter then
        return
    end

    if not quests.IsCompletedByCharacter(questID) then
        return
    end

    held.counted[questID] = true
    held.completed        = held.completed + 1
end

-- Called from the turn-in hook. Cheap, exact, and it does not touch the
-- 30,000-entry walk.
--
-- "+1 ON EVERY TURN-IN" IS WRONG, AND WRONG IN THE COMMON CASE.
--
-- The first version of this incremented for any turn-in of a discovered
-- quest. Most turn-ins in a modern evening are REPEATABLE -- a token hand-in,
-- an assault, a holiday daily -- and `IsQuestFlaggedCompleted` stays false for
-- those, so they contribute nothing to the true count while adding one here
-- every single time. Twenty hand-ins is twenty phantom completions, and the
-- Remaining tab could report more quests completed than discovered.
--
-- A daily crossing its reset mid-session is the same shape, once.
--
-- So the client is asked about the ONE quest that just changed -- which is a
-- single call, not a thirty-thousand-entry walk -- and the credit is only
-- taken if the answer moved. `counted` remembers which ids this figure
-- already includes, so a second turn-in of the same quest cannot add a second
-- one.
function Breakdown.NoteQuestCompleted(questID)
    local key = CN.characterKey or CN.GetCharacterKey()

    local held = questCounts[key]

    if not held or not questID then
        return
    end

    -- Only a quest the addon had already discovered was in the denominator
    -- this count walks; one it has not seen will be picked up by the size
    -- change when it is discovered.
    if not CN.Account("discoveredQuests")[questID] then
        return
    end

    held.counted = held.counted or {}

    if held.counted[questID] then
        return
    end

    local quests = CN:GetModule("Quests")

    if not quests or not quests.IsCompletedByCharacter then
        return
    end

    -- The client is the authority on whether this actually completed. A
    -- repeatable quest answers false here and is correctly not credited.
    if not quests.IsCompletedByCharacter(questID) then
        return
    end

    held.counted[questID] = true
    held.completed        = held.completed + 1
end

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
        local completed = Breakdown.CompletedQuestCount()

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
        Print(string.format("|cffffc74f%s|r  %d / %d  (%s)",
            row.name, row.collected, row.total,
            CN.PercentText(percentage / 100, 1)))
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

    -- AND TURN-INS COME IN RUNS. 0.61.0.
    --
    -- A campaign chain, a bonus objective, a world-quest cluster: four to
    -- eight of these arrive within a couple of seconds, and each one made the
    -- next Remaining refresh walk every store in the addon again for a report
    -- that differs by one row. The exact count is maintained incrementally by
    -- `NoteQuestCompleted` above, which runs BEFORE this debounce and is not
    -- subject to it -- so the number stays right while the expensive recount
    -- of everything else waits for the run to finish.
    QUEST_TURNED_IN         = true,
}

Breakdown.burstSeconds = 5

for _, event in ipairs({
    "NEW_PET_ADDED", "NEW_MOUNT_ADDED", "NEW_TOY_ADDED",
    "ACHIEVEMENT_EARNED", "TRANSMOG_COLLECTION_UPDATED",
    "QUEST_TURNED_IN", "UPDATE_FACTION", "CURRENCY_DISPLAY_UPDATE",
    "PLAYER_ENTERING_WORLD",
}) do
    local burst = bursty[event]

    CN:RegisterEvent(event, function(_, questID)
        if event == "QUEST_TURNED_IN" then
            Breakdown.NoteQuestCompleted(questID)
        end

        -- NOT CLEARED ON PLAYER_ENTERING_WORLD, though the first draft was.
        --
        -- That event fires on every instance zone-in and every loading
        -- screen, so clearing there rebuilt the thirty-thousand-entry walk
        -- several times an evening -- which is the exact cost this cache was
        -- written to remove. The clear was there to handle a character
        -- switch, and it was never needed for that: the count is keyed by
        -- character key, so another character simply reads its own entry, and
        -- switching characters in this game ends the session anyway.

        if burst then
            CN.Debounce("Breakdown." .. event, Breakdown.burstSeconds,
                Breakdown.NoteChanged)
            return
        end

        Breakdown.NoteChanged()
    end)
end

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
