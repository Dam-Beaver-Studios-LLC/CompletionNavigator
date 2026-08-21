-- Benchmark: loads the addon through the harness stubs, then inflates the
-- collection stores to retail scale and times the recommendation path.
--
-- Run:  lua5.4 bench.lua build/CompletionNavigator

local ROOT = arg[1] or "build/CompletionNavigator"

-- Read BEFORE `arg` is rewritten for the harness below, which replaces the
-- whole table and would otherwise take the flag with it. The budget block at
-- the end of this file therefore saw no arguments and silently did nothing --
-- a check that cannot fail because it never runs.
local ENFORCE_BUDGETS = false

for _, argument in ipairs(arg) do
    if argument == "--budget" then
        ENFORCE_BUDGETS = true
    end
end

-- Silence the harness's own output while it loads and self-tests.
local realPrint = print
_G.print = function() end

CN_BENCH = true
arg = { ROOT }
dofile("harness.lua")

_G.print = realPrint

local CN = _G.CompletionNavigator
local db = _G.CompletionNavigatorDB

------------------------------------------------------------
-- RETAIL-SCALE DATA
------------------------------------------------------------

-- Approximate live retail counts.
local N_PETS         = 1800
local N_MOUNTS       = 900
local N_TOYS         = 600
local N_ACHIEVEMENTS = 3000
local N_FACTIONS     = 500
local N_RECIPES      = 2500
local N_VENDOR_ITEMS = 400

local pets = CN.Account('pets')
for i = 1, N_PETS do
    -- No name: the client's journal has it. Keeping the fixture in step with
    -- what the addon actually writes is the whole point of measuring.
    pets[10000 + i] = {
        speciesID = 10000 + i,
        collected = (i % 3 == 0),
        obtainable = true,
        isWild = (i % 5 == 0),
        count = 0, limit = 3,
    }
end

local achievements = CN.Account('achievements')
for i = 1, N_ACHIEVEMENTS do
    local criteria = 1 + (i % 12)
    achievements[20000 + i] = {
        achievementID = 20000 + i,
        criteria = criteria,
        done = math.max(0, criteria - (i % 4)),
        points = 10,
    }
end

local reputations = CN.Account('reputations')
for i = 1, N_FACTIONS do
    reputations[30000 + i] = {
        factionID = 30000 + i,
        name = "Faction " .. i,
        standing = 4,
        accountWide = (i % 2 == 0),
    }
end

local recipeNames = CN.Account('recipeNames')
for i = 1, N_RECIPES do
    recipeNames[40000 + i] = "Recipe " .. i
end

local vendorStore = CN.Account('vendors')
for v = 1, 20 do
    local items = {}
    for i = 1, N_VENDOR_ITEMS do
        -- A NUMBER, matching what the addon actually writes: the price, not
        -- a table holding it. Keeping the fixture in step with the real shape
        -- is the whole point of measuring.
        items[40000 + ((v * 100 + i) % N_RECIPES)] = 1
    end
    vendorStore[60000 + v] = {
        npcID = 60000 + v, name = "Vendor " .. v, items = items,
        itemCount = N_VENDOR_ITEMS, mapID = 94, x = 0.5, y = 0.5, zone = "Bench Zone",
    }
end

------------------------------------------------------------
-- TIMING
------------------------------------------------------------

-- MEASUREMENTS, KEPT.
--
-- The benchmark printed numbers and threw them away, so a regression was only
-- caught by somebody reading the output and remembering what it used to say.
-- Nobody remembers. Recording them means CI can fail on one.
CN_BENCH_RESULTS = {}

local function bench(label, iterations, fn)
    -- Warm up, so the first-call cost of building any lazy index is not
    -- charged to the measurement.
    fn()

    local started = os.clock()
    for _ = 1, iterations do fn() end
    local elapsed = (os.clock() - started) * 1000

    local perCall = elapsed / iterations

    print(string.format("  %-38s %8.3f ms/call  (%d iterations)",
        label, perCall, iterations))

    CN_BENCH_RESULTS[label] = perCall

    return perCall
end

print("\nData scale:")
local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
print("  pets         = " .. count(CN.Account('pets')))
print("  achievements = " .. count(CN.Account('achievements')))
print("  reputations  = " .. count(CN.Account('reputations')))
print("  recipes      = " .. count(CN.Account('recipeNames')))
print("  vendors      = " .. count(CN.Account('vendors')))

print("\nCold rebuild (cache forced, what an invalidating event costs):")
bench("CollectCandidates(force)", 20, function()
    CN.CollectCandidates(true)
end)

print("\nWarm path (what a tooltip hover or UI refresh costs):")
bench("CollectCandidates()", 2000, function()
    CN.CollectCandidates()
end)
bench("Recommend(1)", 200, function()
    CN.Recommend(1)
end)
bench("Recommend(25)", 200, function()
    CN.Recommend(25)
end)

print("\nCandidates produced: " .. #CN.CollectCandidates(true))

print("\nPer-provider, slowest first:")
local rows = {}
for name, timing in pairs(CN.providerTimings) do
    table.insert(rows, { name = name, avg = timing.total / timing.calls })
end
table.sort(rows, function(a, b) return a.avg > b.avg end)
for _, row in ipairs(rows) do
    print(string.format("  %-16s %8.3f ms", row.name, row.avg))
end

print("\nSingle-event invalidation (what actually happens while playing):")

local function fireEvent(event)
    for _, handler in ipairs(CN.eventTable[event] or {}) do
        handler(event)
    end
end

for _, event in ipairs({
    "QUEST_LOG_UPDATE",
    "NEW_PET_ADDED",
    "CRITERIA_UPDATE",
    "UPDATE_FACTION",
    "NEW_MOUNT_ADDED",
}) do
    CN.CollectCandidates()
    bench(event, 20, function()
        fireEvent(event)
        CN.Recommend(1)
    end)
end

print("\nFilter cost (ignored/deferred lists are empty here, the common case):")
bench("IsIgnored + IsDeferred x 10000", 20, function()
    for i = 1, 10000 do
        CN.IsIgnored("PET", i)
        CN.IsDeferred("PET", i)
    end
end)

------------------------------------------------------------
-- UI REFRESH
------------------------------------------------------------
--
-- The path that runs while the window is open, which had never been measured.

print("\nUI refresh (what an open window costs):")

do
    local goals = CN:GetModule("Goals")
    local chase = CN:GetModule("Chase")

    if goals and chase then
        goals.Clear()

        for index = 1, 8 do
            goals.Add(CN.objectiveTypes.ACHIEVEMENT, 10 + (index % 4))
        end

        bench("Chase.All() with 8 goals", 50, function()
            chase.All()
        end)

        goals.Clear()
    end

    local alts = CN:GetModule("Alts")

    if alts then
        bench("Alts.Verdict()", 50, function()
            alts.Verdict()
        end)
    end

    local progress = CN:GetModule("Progress")

    if progress then
        bench("Progress.Summary() (12k completed quests)", 50, function()
            progress.Summary()
        end)

        -- QUEST_LOG_UPDATE fires many times a second during normal play. If
        -- it invalidates the cache, the cache does nothing and this number
        -- goes straight back to the uncached one.
        bench("Summary under a chatty QUEST_LOG_UPDATE", 50, function()
            for _, handler in ipairs(CN.eventTable["QUEST_LOG_UPDATE"] or {}) do
                handler("QUEST_LOG_UPDATE")
            end

            progress.Summary()
        end)
    end
end

------------------------------------------------------------
-- SAVEDVARIABLES SIZE
------------------------------------------------------------
--
-- The client rewrites this entire file on every logout. Nobody had ever
-- measured how big this addon makes it.

print("\nSavedVariables (rewritten in full on every logout):")

local function measure(value, seen)
    seen = seen or {}

    if type(value) == "table" then
        if seen[value] then return 0 end
        seen[value] = true

        local bytes = 8

        for k, v in pairs(value) do
            bytes = bytes + measure(k, seen) + measure(v, seen) + 4
        end

        return bytes
    end

    if type(value) == "string" then return #value + 2 end
    if type(value) == "number" then return 8 end

    return 4
end

local total = measure(CompletionNavigatorDB)

local sections = {}

for section, contents in pairs(CompletionNavigatorDB.account or {}) do
    local bytes = measure(contents)

    if bytes > 200 then
        table.insert(sections, {
            name  = section,
            bytes = bytes,
            count = CN.CountKeys(contents),
        })
    end
end

table.sort(sections, function(a, b) return a.bytes > b.bytes end)

print(string.format("  TOTAL %s", string.format("%.1f KB", total / 1024)))

for _, row in ipairs(sections) do
    print(string.format("  %-22s %8.1f KB  (%d rows)",
        row.name, row.bytes / 1024, row.count))
end

------------------------------------------------------------
-- TOOLTIPS
------------------------------------------------------------
--
-- The hottest path in the addon: every mouseover in the game, in bags, in the
-- auction house, on a vendor's entire inventory. Never measured until now.

print("\nTooltip cost (runs on every mouseover):")

do
    local tooltips = CN:GetModule("Tooltips")

    if tooltips then
        -- An ordinary item: not a toy, not a mount, not a recipe. The common
        -- case, and the one that falls through every check.
        bench("ItemLines on an ordinary item", 200, function()
            tooltips.ItemLines(123456, "Some Ordinary Item")
        end)

        bench("ItemLines with no name supplied", 200, function()
            tooltips.ItemLines(123457)
        end)
    end
end

------------------------------------------------------------
-- BUDGETS
------------------------------------------------------------

-- WHY THESE ARE ASSERTIONS AND NOT A REPORT.
--
-- Two performance regressions have shipped in this project's history, and
-- both were visible in this file's output at the time. Printing a number that
-- somebody has to compare against a number they remember is not a check; it
-- is a document nobody reads.
--
-- The figures are ceilings with real headroom -- roughly three times the
-- measured cost -- because a budget that fails on noise gets disabled within
-- a fortnight, and a disabled budget catches nothing at all.
--
-- Run with: lua5.4 bench.lua <tree> --budget
local BUDGETS = {
    ["CollectCandidates(force)"]  = 20.0,
    ["CollectCandidates()"]       = 0.05,
    ["Recommend(1)"]              = 0.10,
    ["Recommend(25)"]             = 0.40,
    ["ItemLines on an ordinary item"] = 0.05,
}

if ENFORCE_BUDGETS then
    print("\nBudgets:")

    local failed = 0

    for label, ceiling in pairs(BUDGETS) do
        local measured = CN_BENCH_RESULTS[label]

        if not measured then
            print(string.format("  MISSING  %-38s (never measured)", label))

            failed = failed + 1
        elseif measured > ceiling then
            print(string.format("  OVER     %-38s %.3f ms > %.3f ms",
                label, measured, ceiling))

            failed = failed + 1
        else
            print(string.format("  ok       %-38s %.3f ms of %.3f ms",
                label, measured, ceiling))
        end
    end

    if failed > 0 then
        print("\n" .. failed .. " budget(s) exceeded.")

        os.exit(1)
    end

    print("\nEvery measured path is inside its budget.")
end
