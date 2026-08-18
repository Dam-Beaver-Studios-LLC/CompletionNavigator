-- Modules/Setup.lua
-- Completion Navigator :: the first five minutes.
--
-- Every recommendation this addon makes is only as good as what it has
-- scanned, and until now a new install had to discover eleven separate scan
-- commands to get there. Worse, it looked broken in the meantime: an empty
-- database and a confident "nothing actionable is known yet" read as a bug
-- rather than as a first run.
--
-- /cn setup runs every scan in order, one per frame, and then reports what
-- the client genuinely could not answer -- recipes and vendors, which are
-- readable only while their windows are open, and so can never be batched.

local ADDON_NAME, CN = ...

local Setup = CN:RegisterModule("Setup")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint

------------------------------------------------------------
-- STEPS
------------------------------------------------------------

-- Ordered so the cheap scans report first and the journal scans -- which
-- open and filter collection UIs -- come last.
Setup.steps = {
    { key = "reputations", label = "Reputations", module = "Reputations", fn = "Scan" },
    { key = "currencies",  label = "Currencies",  module = "Currencies",  fn = "Scan" },
    { key = "titles",      label = "Titles",      module = "Titles",      fn = "Scan" },
    { key = "professions", label = "Professions", module = "Professions", fn = "Scan" },
    { key = "exploration", label = "Exploration", module = "Exploration", fn = "Scan" },
    { key = "quests",      label = "Quests",      module = "Quests",      fn = "ScanKnown" },
    { key = "achievements",label = "Achievements",module = "Achievements",fn = "Scan" },
    { key = "toys",        label = "Toys",        module = "Toys",        fn = "Scan" },
    { key = "mounts",      label = "Mounts",      module = "Mounts",      fn = "Scan" },
    { key = "pets",        label = "Battle pets", module = "Pets",        fn = "Scan" },
    { key = "appearances", label = "Appearances", module = "Appearances", fn = "Scan" },
}

function Setup.RunStep(step)
    local module = CN:GetModule(step.module)

    if not module or type(module[step.fn]) ~= "function" then
        return false, "module not loaded"
    end

    local ok, first = pcall(module[step.fn])

    if not ok then
        return false, tostring(first)
    end

    return true, first
end

------------------------------------------------------------
-- RUN
------------------------------------------------------------

Setup.running = false

-- Spreading the steps across frames matters: several of these walk the entire
-- pet journal or achievement tree, and doing all eleven inside one frame is a
-- visible stutter on a login that is already busy.
function Setup.Run(onComplete)
    if Setup.running then
        Print("Setup is already running.")
        return false
    end

    Setup.running = true

    local results = {}
    local index   = 0

    local function step()
        index = index + 1

        local entry = Setup.steps[index]

        if not entry then
            Setup.running = false

            CN.Account("setup").completedAt = time()

            Setup.Report(results)

            if onComplete then
                pcall(onComplete, results)
            end

            return
        end

        local ok, value = Setup.RunStep(entry)

        table.insert(results, {
            label = entry.label,
            ok    = ok,
            value = ok and value or nil,
            error = (not ok) and value or nil,
        })

        if C_Timer and C_Timer.After then
            C_Timer.After(0, step)
        else
            step()
        end
    end

    Print("Running setup: " .. #Setup.steps .. " scans.")

    step()

    return true
end

function Setup.Report(results)
    local scanned, failed = 0, 0

    for _, result in ipairs(results) do
        if result.ok then
            scanned = scanned + 1

            Print("  " .. result.label .. ": "
                .. (type(result.value) == "number" and result.value or "done"))
        else
            failed = failed + 1

            Print("  " .. result.label .. ": |cffff4444" .. tostring(result.error) .. "|r")
        end
    end

    Print("Setup complete: " .. scanned .. " scanned"
        .. (failed > 0 and (", " .. failed .. " unavailable") or "") .. ".")

    for _, line in ipairs(Setup.Outstanding()) do
        Print("|cffffff00" .. line .. "|r")
    end

    Print("Now try |cffffff00/cn next|r.")
end

------------------------------------------------------------
-- WHAT SETUP CANNOT DO
------------------------------------------------------------

-- Two subsystems are readable only while their window is open. Saying so is
-- the difference between "this addon does not track recipes" and "open your
-- profession window once".
function Setup.Outstanding()
    local lines = {}

    local professions = CN:GetModule("Professions")

    if professions and professions.AwaitingRecipeCapture then
        local awaiting = professions.AwaitingRecipeCapture()

        if awaiting and #awaiting > 0 then
            local names = {}

            for _, entry in ipairs(awaiting) do
                table.insert(names, tostring(entry))
            end

            table.insert(lines, "Open each profession window once to record recipes: "
                .. table.concat(names, ", "))
        end
    end

    local vendors = CN:GetModule("Vendors")

    if vendors then
        local counts = vendors.Summary()

        if counts.vendors == 0 then
            table.insert(lines,
                "No vendors recorded yet; they are captured as you open merchant windows.")
        end
    end

    return lines
end

function Setup.HasRun()
    local record = CN.Account("setup")

    return (record and record.completedAt) and true or false
end

------------------------------------------------------------
-- FIRST-RUN PROMPT
------------------------------------------------------------

-- Prompt, never act. Running eleven scans uninvited on someone's login is the
-- same discourtesy as seizing their waypoint.
CN:OnLogin(function()
    if Setup.HasRun() then
        return
    end

    local account = CN.Account("setup")

    if account.prompted then
        return
    end

    account.prompted = time()

    if C_Timer and C_Timer.After then
        C_Timer.After(8, function()
            if not Setup.HasRun() then
                Print("First run: type |cffffff00/cn setup|r to scan everything once.")
            end
        end)
    else
        Print("First run: type |cffffff00/cn setup|r to scan everything once.")
    end
end)

------------------------------------------------------------
-- COMMAND
------------------------------------------------------------

CN:RegisterCommand{
    name    = "setup",
    aliases = { "scanall" },
    order   = 5,
    help    = "Scan every subsystem once. Run this first.",
    handler = function()
        Setup.Run()
    end,
}

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
