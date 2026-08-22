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

    -- THE WHOLE BODY IS GUARDED, NOT JUST THE STEP.
    --
    -- `RunStep` was pcall'd and nothing else was -- and steps two onward run
    -- inside `C_Timer.After` callbacks, outside the slash command's own
    -- pcall. So a throw in the bookkeeping, in `Setup.Report`, or in
    -- `Setup.Outstanding` stopped the chain dead AND left `Setup.running`
    -- true, which makes `/cn setup` answer "Setup is already running." for
    -- the rest of the session with no way back short of a reload.
    local function step()
        local ran, err = pcall(function()
            index = index + 1

            local entry = Setup.steps[index]

            if not entry then
                Setup.running = false

                -- COMPLETION IS RECORDED ONLY IF SOMETHING COMPLETED.
                --
                -- This was stamped unconditionally, so a run in which every
                -- scan failed was remembered as a successful setup: the login
                -- reminder stopped, `Setup.HasRun()` went true forever, and
                -- `/cn setup check` answered "Everything the addon can read
                -- on its own is scanned."
                local failed = 0

                for _, row in ipairs(results) do
                    if not row.ok then
                        failed = failed + 1
                    end
                end

                if failed < #results then
                    CN.Account("setup").completedAt = time()
                end

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
        end)

        if not ran then
            Setup.running = false

            local errors = CN:GetModule("Errors")

            if errors and errors.Record then
                pcall(errors.Record, "Setup.Run", tostring(err))
            end

            Print("Setup stopped after " .. index .. " of "
                .. #Setup.steps .. " scans: " .. tostring(err))
            Print("|cff999999/cn setup runs it again from the start.|r")
        end
    end

    Print("Running setup: " .. #Setup.steps .. " scans.")

    step()

    return true
end

function Setup.Report(results)
    local scanned, absent, broke = 0, 0, 0

    for _, result in ipairs(results) do
        if result.ok then
            scanned = scanned + 1

            Print("  " .. result.label .. ": "
                .. (type(result.value) == "number" and result.value or "done"))
        elseif result.error == "module not loaded" then
            -- "UNAVAILABLE" AND "IT THREW" ARE DIFFERENT STATEMENTS.
            --
            -- Every failure was reported with the word "unavailable", so a
            -- module that raised a Lua error was presented to the player as a
            -- subsystem this client does not have -- nothing to look into,
            -- nothing to report.
            absent = absent + 1

            Print("  " .. result.label
                .. ": |cff999999not available on this client|r")
        else
            broke = broke + 1

            Print("  " .. result.label .. ": |cffff4444failed: "
                .. tostring(result.error) .. "|r")
        end
    end

    Print("Setup complete: " .. scanned .. " scanned"
        .. (absent > 0 and (", " .. absent .. " unavailable") or "")
        .. (broke > 0 and (", " .. broke .. " failed") or "") .. ".")

    if broke > 0 then
        Print("|cff999999A failure is a defect, not a missing feature. "
            .. "|cffffff00/cn errors|r has the detail.|r")
    end

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
--
-- BUT: the prompt used to fire once, ever. It was recorded as "prompted" the
-- first time and never spoken again, so a player who missed that single line
-- in a busy login -- which is most of them -- had an addon that quietly knew
-- nothing about their collections for the rest of its installed life, and no
-- way to find out why it seemed thin.
--
-- A required first step is worth saying every login until it has been done.
-- Once done, it is never mentioned again. That is the difference between a
-- reminder and nagging: a reminder stops when the thing is finished.
Setup.remindSeconds = 8

function Setup.RemindIfNeeded()
    if Setup.HasRun() then
        return false
    end

    Print("Completion Navigator has not scanned your collections yet.")
    Print("Type |cffffff00/cn setup|r once and it will know what you have.")

    local account = CN.Account("setup")

    account.prompts = (account.prompts or 0) + 1

    return true
end

------------------------------------------------------------
-- WHEN THE ADDON CANNOT SEE SOMETHING
------------------------------------------------------------

-- Two subsystems are readable only while their window is open, so the addon
-- can be fully set up and still blind to a profession the player levelled
-- last week. It knew that and only said so immediately after a manual scan,
-- which is the one moment the player is least likely to need telling.
--
-- Said again periodically, and never more than this often, because the fix
-- is "open a window some time" rather than anything urgent.
Setup.outstandingIntervalDays = 7

function Setup.RemindOutstanding()
    if not Setup.HasRun() then
        return false
    end

    local lines = Setup.Outstanding()

    if #lines == 0 then
        return false
    end

    local account = CN.Account("setup")

    local last = account.outstandingRemindedAt or 0

    if (time() - last) < (Setup.outstandingIntervalDays * 86400) then
        return false
    end

    account.outstandingRemindedAt = time()

    Print("Completion Navigator cannot see everything yet:")

    for _, line in ipairs(lines) do
        Print("  |cffffff00" .. line .. "|r")
    end

    return true
end

CN:OnLogin(function()
    local function speak()
        if Setup.RemindIfNeeded() then
            return
        end

        Setup.RemindOutstanding()
    end

    -- Delayed, so it lands after the login chatter rather than inside it.
    if C_Timer and C_Timer.After then
        C_Timer.After(Setup.remindSeconds, speak)
    else
        speak()
    end
end)

------------------------------------------------------------
-- COMMAND
------------------------------------------------------------

CN:RegisterCommand{
    name    = "setup",
    aliases = { "scanall" },
    args    = "[check]",
    order   = 5,
    help    = "Scan every subsystem once. Run this first.",
    handler = function(args)
        if string.lower(CN.Trim(args or "")) == "check" then
            -- Report without scanning. "What can you not see?" is a
            -- different question from "go and look again", and answering the
            -- first by doing the second is why people stop asking.
            if not Setup.HasRun() then
                Print("Not scanned yet. Type |cffffff00/cn setup|r.")
                return
            end

            local lines = Setup.Outstanding()

            if #lines == 0 then
                Print("Everything the addon can read on its own is scanned.")
                return
            end

            Print("Still outside what the addon can read on its own:")

            for _, line in ipairs(lines) do
                Print("  |cffffff00" .. line .. "|r")
            end

            return
        end

        Setup.Run()
    end,
}

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
