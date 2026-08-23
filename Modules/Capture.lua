-- Modules/Capture.lua
-- Completion Navigator :: recording what the client actually returns.
--
-- THE PROBLEM THIS EXISTS TO END.
--
-- Nine defects in this addon's history came from the same place: the offline
-- test harness modelled the world more simply than the world is, the tests
-- agreed with the model, and the bug shipped. A map point modelled as a flat
-- table when the client wants a vector. A quest list containing no quest
-- starts. An achievement criterion with no counter. Every map modelled as a
-- perfect square, for eight releases, which hid an angle error in every zone
-- in the game.
--
-- `/cn selftest` catches these in play, which is a great deal better than a
-- player catching them, but it is still after the fact. It cannot stop the
-- NEXT optimistic stub from being written, because the author of a stub does
-- not know which part of reality he is simplifying -- that is what makes it a
-- simplification rather than a decision.
--
-- The only thing that ends it is testing against real data. So: record what
-- the client actually returned, on a real character, and let the offline
-- suite check its own stubs against that recording. A stub that is missing a
-- field reality had becomes a test failure instead of a future bug report.
--
-- WHAT IS RECORDED.
--
-- Shapes and small samples, never the player's collections wholesale. The
-- suite needs to know that GetSavedInstanceInfo returns thirteen values in a
-- particular order and that map spans are not square; it does not need
-- eighteen hundred pets.
--
-- WHAT IS NOT RECORDED.
--
-- Character names, realm, guild, anything that identifies the player, and
-- nothing at all unless the command is run deliberately. The file is written
-- into your own SavedVariables and goes nowhere on its own -- this addon has
-- no network access of any kind and never will.

local ADDON_NAME, CN = ...

local Capture = CN:RegisterModule("Capture")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

------------------------------------------------------------
-- REGISTRY
------------------------------------------------------------

CN.captures = CN.captures or {}

-- definition = {
--     name = "GetSavedInstanceInfo",
--     run  = function() return <plain data>, note end,
-- }
-- THE NAME IS THE KEY THE RESULT IS FILED UNDER, AND IT WAS NOT CHECKED.
--
-- `Capture.Run` writes `records[definition.name]`. A definition registered
-- without a name made that `records[nil] = value`, which throws -- inside the
-- capture run, taking every later capture with it. A definition registered
-- with a name another one already uses silently overwrote it, so a capture
-- ran, cost its time, and produced nothing anybody could find.
function CN.RegisterCapture(definition)
    if type(definition) ~= "table" or type(definition.run) ~= "function" then
        return false, "a capture needs a run function"
    end

    if type(definition.name) ~= "string" or definition.name == "" then
        return false, "a capture needs a name" .. CN.DASH .. "it is the key its result is "
            .. "filed under"
    end

    for _, existing in ipairs(CN.captures) do
        if existing.name == definition.name then
            return false, "a capture named " .. definition.name
                .. " is already registered"
        end
    end

    table.insert(CN.captures, definition)

    return true
end

------------------------------------------------------------
-- SHAPE, NOT CONTENT
------------------------------------------------------------

-- Reduces a value to what a test needs to know about it: its type, and for a
-- table, the shape of its keys. Numbers survive because a range matters --
-- a map span of 4,000 by 2,700 is the whole point of one of these captures --
-- but a list of three thousand achievement IDs collapses to "3000 numbers".
--
-- Bounded by depth and by width, because this is written to disk and read
-- back on every login until it is cleared.
function Capture.Shape(value, depth, width)
    depth = depth or 3
    width = width or 12

    local kind = type(value)

    if kind ~= "table" then
        if kind == "string" and #value > 64 then
            return { type = "string", length = #value }
        end

        return { type = kind, value = (kind == "function" and "function" or value) }
    end

    if depth <= 0 then
        return { type = "table", truncated = true }
    end

    local shape = { type = "table", fields = {}, count = 0, array = 0 }

    -- Methods matter as much as fields: the 0.19.0 bug was a Vector2D whose
    -- GetXY the stub did not have.
    for key, entry in pairs(value) do
        shape.count = shape.count + 1

        if type(key) == "number" then
            shape.array = shape.array + 1
        elseif type(key) == "string" and shape.count <= width then
            shape.fields[key] = Capture.Shape(entry, depth - 1, width)
        end
    end

    if getmetatable(value) then
        shape.metatable = true
    end

    return shape
end

------------------------------------------------------------
-- WHAT GETS CAPTURED
------------------------------------------------------------

CN.RegisterCapture{
    name = "position",
    run  = function()
        local mapID, x, y = CN.GetPlayerPosition()

        if not mapID then
            return nil, "no map"
        end

        return { mapID = mapID, x = x, y = y }
    end,
}

-- THE ONE THAT WOULD HAVE CAUGHT 0.40.0's ANGLE BUG EIGHT RELEASES EARLIER.
CN.RegisterCapture{
    name = "mapSpanYards",
    run  = function()
        local mapID = CN.GetPlayerPosition()

        local nav = CN:GetModule("Navigation")

        if not mapID or not nav then
            return nil, "no map"
        end

        local scaleX, scaleY = nav.MapScale(mapID)

        return {
            mapID  = mapID,
            xYards = scaleX,
            yYards = scaleY,
            square = math.abs(scaleX - scaleY) < 1,
        }
    end,
}

CN.RegisterCapture{
    name = "worldPosition",
    run  = function()
        local mapID, x, y = CN.GetPlayerPosition()

        if not mapID or not C_Map or not C_Map.GetWorldPosFromMapPos then
            return nil, "no map"
        end

        local ok, continentID, position =
            pcall(C_Map.GetWorldPosFromMapPos, mapID, CreateVector2D(x, y))

        if not ok or not position then
            return nil, "the client would not convert"
        end

        return {
            continentID = continentID,
            shape       = Capture.Shape(position),
            hasGetXY    = position.GetXY ~= nil,
        }
    end,
}

CN.RegisterCapture{
    name = "mapInfo",
    run  = function()
        local mapID = CN.GetPlayerPosition()

        if not mapID then
            return nil, "no map"
        end

        return Capture.Shape(Blizzard.GetMapInfo(mapID))
    end,
}

CN.RegisterCapture{
    name = "questPOI",
    run  = function()
        local mapID = CN.GetPlayerPosition()

        if not mapID then
            return nil, "no map"
        end

        local pois = Blizzard.GetQuestPOIsOnMap(mapID)

        if #pois == 0 then
            return nil, "no quest pins here"
        end

        local starts = 0

        for _, poi in ipairs(pois) do
            if poi.isQuestStart then
                starts = starts + 1
            end
        end

        return {
            count       = #pois,
            questStarts = starts,
            shape       = Capture.Shape(pois[1]),
        }
    end,
}

CN.RegisterCapture{
    name = "achievementCriteria",
    run  = function()
        local achievements = CN:GetModule("Achievements")

        if not achievements then
            return nil, "achievements module not loaded"
        end

        for achievementID in pairs(achievements.Store()) do
            local criteria = Blizzard.GetAchievementCriteriaList(achievementID, 4)

            if criteria and criteria[1] then
                return {
                    shape    = Capture.Shape(criteria[1]),
                    counted  = criteria[1].required ~= nil,
                }
            end
        end

        return nil, "nothing scanned yet"
    end,
}

CN.RegisterCapture{
    name = "savedInstances",
    run  = function()
        local saved = Blizzard.GetSavedInstances()

        if #saved == 0 then
            return nil, "not saved to anything"
        end

        return { count = #saved, shape = Capture.Shape(saved[1]) }
    end,
}

CN.RegisterCapture{
    name = "encounterJournal",
    run  = function()
        if not Blizzard.HasEncounterJournal() then
            return nil, "no Adventure Guide in this client"
        end

        if Blizzard.IsEncounterJournalOpen() then
            return nil, "the Adventure Guide is open"
        end

        return { available = true }
    end,
}

CN.RegisterCapture{
    name = "completedQuests",
    run  = function()
        local progress = CN:GetModule("Progress")

        local total = progress and progress.LifetimeCompleted()

        if not total then
            return nil, "the client will not report a lifetime total"
        end

        -- The COUNT is the interesting number: a stub that returns eight
        -- entries where the client returns twelve thousand is a stub that
        -- makes an expensive call look free.
        return { count = total }
    end,
}

CN.RegisterCapture{
    name = "weeklyReset",
    run  = function()
        local seconds = Blizzard.GetSecondsUntilWeeklyReset()

        if not seconds then
            return nil, "the client will not say"
        end

        return { seconds = seconds }
    end,
}

-- WHICH OF THE EVENTS THIS ADDON REGISTERS ARE REAL.
--
-- Added in 0.46.0, after `NEW_TAXI_NODE` -- a name that does not exist and
-- never has -- threw a Lua error at every login. The test suite could not see
-- it because the stub frame accepted any string, and the fix for that is a
-- list of real event names maintained by hand in the harness. A list
-- maintained by hand is precisely the kind of thing this project keeps being
-- caught by, so it needs checking against a client rather than against
-- memory.
--
-- This asks the live client to register every event the addon uses, on a
-- throwaway frame with no handler attached, and records the ones it refused.
-- The harness fails on any refusal.
CN.RegisterCapture{
    name = "events",
    run  = function()
        if not CreateFrame then
            return nil, "no frame factory"
        end

        local ok, probe = pcall(CreateFrame, "Frame")

        if not ok or not probe then
            return nil, "the client would not make a frame"
        end

        local refused, accepted = {}, 0

        for event in pairs(CN.eventTable or {}) do
            local registered = pcall(probe.RegisterEvent, probe, event)

            if registered then
                accepted = accepted + 1

                pcall(probe.UnregisterEvent, probe, event)
            else
                table.insert(refused, event)
            end
        end

        table.sort(refused)

        return { accepted = accepted, refused = refused }
    end,
}

-- WHICH OF THE CLIENT FUNCTIONS THIS ADDON CALLS STILL EXIST.
--
-- The sibling of the `events` capture, and the more insidious half. An
-- unknown EVENT name throws, so it announces itself. An unknown FUNCTION name
-- announces nothing: every call site in this addon is guarded with
-- `if C_Thing and C_Thing.Method`, which is correct, and which makes a
-- misspelled or renamed name indistinguishable from a client that does not
-- support the feature. The guard is false, the branch never runs, and the
-- feature is quietly dead for as long as nobody notices.
--
-- Data/ApiSurface.lua is generated from the source at build time -- a
-- hand-written list of what the code calls is a second copy of the code, and
-- would drift within a release.
CN.RegisterCapture{
    name = "apiSurface",
    run  = function()
        if type(CN.apiSurface) ~= "table" or #CN.apiSurface == 0 then
            return nil, "no generated surface in this build"
        end

        local missing, present = {}, 0

        for _, path in ipairs(CN.apiSurface) do
            local namespace, method = string.match(path, "^([^.]+)%.(.+)$")

            local value

            if namespace then
                local container = _G and _G[namespace]

                value = type(container) == "table" and container[method] or nil
            else
                value = _G and _G[path]
            end

            if value ~= nil then
                present = present + 1
            else
                table.insert(missing, path)
            end
        end

        return { examined = #CN.apiSurface, present = present, missing = missing }
    end,
}

------------------------------------------------------------
-- RUNNING IT
------------------------------------------------------------

function Capture.Run()
    local records = {}

    local captured, skipped = 0, 0

    for _, definition in ipairs(CN.captures) do
        local ok, value, note = pcall(definition.run)

        if not ok then
            records[definition.name] = { skipped = "errored: " .. tostring(value) }
            skipped = skipped + 1
        elseif value == nil then
            records[definition.name] = { skipped = note or "nothing to record" }
            skipped = skipped + 1
        else
            records[definition.name] = value
            captured = captured + 1
        end
    end

    records.build   = CN.version
    records.locale  = CN.ClientLocale and CN.ClientLocale() or nil
    records.recorded = time()

    -- WHICH CLIENT THIS IS EVIDENCE ABOUT.
    --
    -- Added in 0.46.0, because a recording with no interface number cannot be
    -- checked for staleness, and stale evidence is worse than none: it makes
    -- the audit report success about a game that has since been patched. The
    -- .toc's Interface line is the addon's claim about which client it
    -- supports; this is the client that was actually running.
    if GetBuildInfo then
        local ok, _, _, _, interface = pcall(GetBuildInfo)

        if ok then
            records.interface = tonumber(interface)
        end
    end

    -- Written under the account table so it survives to the next logout and
    -- lands in SavedVariables, which is the only way it can reach the
    -- repository. Explicitly NOT merged into anything the addon reads: this
    -- is evidence, not data.
    local account = CN.Account()

    account.capture = records

    return records, captured, skipped
end

function Capture.Clear()
    local account = CN.Account()

    local had = account.capture ~= nil

    account.capture = nil

    return had
end

------------------------------------------------------------
-- COMMAND
------------------------------------------------------------

CN:RegisterCommand{
    name    = "capture",
    args    = "[clear]",
    order   = 35,
    help    = "Record what your client returns, so the tests can check "
        .. "themselves against reality.",
    handler = function(args)
        args = string.lower(CN.Trim(args or ""))

        if args == "clear" then
            Print(Capture.Clear()
                and "Capture cleared. It will be gone from your saved data "
                    .. "at the next logout."
                or "There was nothing recorded.")
            return
        end

        local records, captured, skipped = Capture.Run()

        Print("Recorded " .. captured .. " of " .. (captured + skipped)
            .. " observations.")

        for name, value in pairs(records) do
            if type(value) == "table" and value.skipped then
                Print("  |cff8a8f96" .. name .. "" .. CN.DASH .. "" .. value.skipped .. "|r")
            end
        end

        Print("|cff8a8f96Nothing identifying you is recorded, and nothing "
            .. "leaves your machine" .. CN.DASH .. "this addon has no network access. "
            .. "It is written to your SavedVariables at logout.|r")
        Print("To send it: log out, then find "
            .. "|cffffc74fWTF\\Account\\<account>\\SavedVariables\\"
            .. "CompletionNavigatorDB.lua|r.")
        Print("|cffffc74f/cn capture clear|r removes it again.")
    end,
}

return Capture
