-- Modules/SelfTest.lua
-- Completion Navigator :: assertions that run where reality is.
--
-- WHY THIS EXISTS.
--
-- Seven times in this project's history, the offline test harness has modelled
-- the world more simply than the world, and hidden a real defect by doing it:
--
--   * a map point modelled as a flat table when the client wants a vector
--   * a quest list that contained no quest starts
--   * an achievement criterion with no counter
--   * a completed-quest list that cost nothing to read
--   * a player who could not move
--   * an arrow whose direction nothing could read
--   * a map that would place the player anywhere it was asked about
--
-- Every one was found by somebody playing the game. None was found by the
-- suite. And no amount of improving the harness fixes that, because the
-- harness is the thing that is wrong: you cannot write a stub for the part of
-- reality you did not know you were simplifying.
--
-- So these assertions do not run against a stub. They run against the live
-- client, on the player's own character, and report what they actually got.
-- When something is wrong, the answer is one command rather than a
-- conversation.
--
-- RULES FOR A CHECK IN HERE.
--
--   * It must be read-only. A diagnostic that changes the game is a liability.
--   * It must be fast. This runs on demand, but nobody waits.
--   * It must report the VALUE it saw, not just pass or fail. "Failed" starts
--     a conversation; "expected a number, got nil" ends one.
--   * A client that cannot answer is a SKIP, not a failure. Being in a raid
--     with the map API restricted is not a bug in this addon.

local ADDON_NAME, CN = ...

local SelfTest = CN:RegisterModule("SelfTest")

local Print = CN.Print

local Blizzard = CN.Blizzard

------------------------------------------------------------
-- REGISTRY
------------------------------------------------------------

SelfTest.results = { PASS = "PASS", FAIL = "FAIL", SKIP = "SKIP" }

-- The registry itself is in Core.lua, so that a module registering a check
-- does not have to load after this file:
--
--     CN.RegisterSelfTest{ name = ..., area = ..., run = function() end }
--
-- definition.run returns status, detail.

function SelfTest.Run()
    local rows = { passed = 0, failed = 0, skipped = 0, checks = {} }

    local ordered = {}

    for _, definition in ipairs(CN.selfTests) do
        table.insert(ordered, definition)
    end

    table.sort(ordered, function(a, b)
        if (a.area or "") ~= (b.area or "") then
            return (a.area or "") < (b.area or "")
        end

        return (a.order or 0) < (b.order or 0)
    end)

    for _, definition in ipairs(ordered) do
        -- A check that throws is a failed check, not a broken command. The
        -- whole point is to survive a client that surprises us.
        local ok, status, detail = pcall(definition.run)

        if not ok then
            -- `status` is the error message here, so read it BEFORE
            -- overwriting it. Getting that order wrong produced a check that
            -- reported "the check itself errored: FAIL", which is the least
            -- useful sentence this module could possibly print.
            detail = "the check itself errored: " .. tostring(status)
            status = SelfTest.results.FAIL
        end

        status = status or SelfTest.results.SKIP

        if status == SelfTest.results.PASS then
            rows.passed = rows.passed + 1
        elseif status == SelfTest.results.FAIL then
            rows.failed = rows.failed + 1
        else
            rows.skipped = rows.skipped + 1
        end

        table.insert(rows.checks, {
            name   = definition.name,
            area   = definition.area or "general",
            status = status,
            detail = detail,
        })
    end

    return rows
end

------------------------------------------------------------
-- THE CHECKS
------------------------------------------------------------

local PASS = SelfTest.results.PASS
local FAIL = SelfTest.results.FAIL
local SKIP = SelfTest.results.SKIP

-- 1. Can the client say where we are at all? Everything else depends on it.
-- WHAT THE GAME PATCHED OUT FROM UNDER US.
--
-- Added in 0.47.0. Every expansion renames or removes client functions, and
-- this addon names nearly two hundred of them. Each call site guards on the
-- name existing -- which is right, and which is also why a removed function
-- produces silence rather than an error: the guard goes false and the feature
-- is dead with nothing to say so.
--
-- Data/ApiSurface.lua is generated from the source at build time, so this
-- cannot fall out of step with what the addon actually calls. Reported here
-- because the player is the one holding a client the author has not seen.
CN.RegisterSelfTest{
    area  = "client",
    order = 0,
    name  = "every client function this addon calls still exists",
    run   = function()
        if type(CN.apiSurface) ~= "table" or #CN.apiSurface == 0 then
            return SKIP, "this build carries no generated API list"
        end

        local missing = {}

        for _, path in ipairs(CN.apiSurface) do
            local namespace, method = string.match(path, "^([^.]+)%.(.+)$")

            local value

            if namespace then
                local container = _G and _G[namespace]

                value = type(container) == "table" and container[method] or nil
            else
                value = _G and _G[path]
            end

            if value == nil then
                table.insert(missing, path)
            end
        end

        if #missing == 0 then
            return PASS, #CN.apiSurface .. " client functions, all present"
        end

        -- Named, and bounded: a patch that removes a whole namespace would
        -- otherwise print forty lines into the chat frame.
        local named = {}

        for index = 1, math.min(6, #missing) do
            table.insert(named, missing[index])
        end

        return FAIL, #missing .. " of " .. #CN.apiSurface
            .. " are gone from this client: " .. table.concat(named, ", ")
            .. (#missing > 6 and (" and " .. (#missing - 6) .. " more") or "")
    end,
}

CN.RegisterSelfTest{
    area = "position",
    name = "the client reports your position",
    run  = function()
        local mapID, x, y = CN.GetPlayerPosition()

        if not mapID then
            return SKIP, "no map -- are you in an instance or a loading screen?"
        end

        if not x or not y then
            return FAIL, "map " .. mapID .. " but no coordinates"
        end

        return PASS, string.format("map %d at %.1f, %.1f", mapID, x * 100, y * 100)
    end,
}

-- 2. THE 0.19.0 BUG. GetWorldPosFromMapPos wants a Vector2D, not a UiMapPoint.
--    Passing the wrong one returns nothing and every distance reads "unknown".
--    The stub modelled both as the same shape, so the suite agreed with it.
CN.RegisterSelfTest{
    area = "position",
    name = "map coordinates convert to world positions",
    run  = function()
        local mapID, x, y = CN.GetPlayerPosition()

        if not mapID or not x then
            return SKIP, "no position to convert"
        end

        local nav = CN:GetModule("Navigation")

        if not nav then
            return SKIP, "navigation module not loaded"
        end

        -- Distance from where we are to slightly north of it. Any real
        -- number proves the conversion works.
        local yards = nav.DistanceYards(mapID, x, y, x, math.max(0, y - 0.01))

        if not yards then
            return FAIL, "the client would not convert -- every distance in "
                .. "the addon will read 'unknown'"
        end

        return PASS, string.format("%.0f yards per 1%% of this map", yards)
    end,
}

-- 3. THE 0.34.0 BUG. Standing in a building changes which map you are "on",
--    and the arrow gave up when that map differed from the destination's.
CN.RegisterSelfTest{
    area = "position",
    name = "your position is expressible on the surrounding zone",
    run  = function()
        local mapID = CN.GetPlayerPosition()

        if not mapID then
            return SKIP, "no map"
        end

        local info = Blizzard.GetMapInfo(mapID)

        local parentID = info and info.parentMapID

        if not parentID or parentID == 0 then
            return SKIP, "this map has no parent -- you are not indoors"
        end

        local nav = CN:GetModule("Navigation")

        local translated = nav and nav.PlayerPositionOnMap(parentID)

        if not translated then
            return SKIP, "the parent map cannot place you, which is normal "
                .. "for a continent"
        end

        return PASS, string.format("also %.1f, %.1f on map %d",
            translated.x * 100, translated.y * 100, parentID)
    end,
}

-- 4. THE BEARING MATHS, against cases whose answers are known independently
--    of the code being checked.
--
--    NOT written the obvious way. The obvious way is to project a point in
--    front of the player using the addon's own facing convention and then ask
--    the addon which way that point is -- which is a tautology: it derives the
--    expected answer from the thing under test, so it passes whether the
--    convention is right or wrong. That is precisely the failure this module
--    exists to stop, and it was in this file before it shipped.
--
--    Instead: fix the facing at zero, put a target somewhere whose bearing is
--    known from the definition of the map (north is up, east is right), and
--    require the stated answer.
CN.RegisterSelfTest{
    area = "navigation",
    name = "the bearing maths gives known answers",
    run  = function()
        local nav = CN:GetModule("Navigation")

        if not nav then
            return SKIP, "navigation module not loaded"
        end

        local cases = {
            { name = "north",  x = 0.5, y = 0.4, expected =   0 },
            { name = "east",   x = 0.6, y = 0.5, expected =  90 },
            { name = "south",  x = 0.5, y = 0.6, expected = 180 },
            { name = "west",   x = 0.4, y = 0.5, expected = -90 },
        }

        for _, case in ipairs(cases) do
            -- No mapID: unscaled, so the four cardinals stay cardinal.
            local relative = nav.RelativeBearing(0.5, 0.5, case.x, case.y, 0, 1)

            if not relative then
                return FAIL, "no bearing could be computed at all"
            end

            local degrees = math.deg(relative)

            -- Signed difference, wrapped, so that east reading as west is a
            -- failure rather than the same distance from zero.
            local off = math.abs(math.deg(
                nav.NormalizeAngle(math.rad(degrees - case.expected))))

            if off > 1 then
                return FAIL, string.format(
                    "a target due %s read as %.0f degrees, not %d",
                    case.name, degrees, case.expected)
            end
        end

        return PASS, "north, east, south and west all read correctly"
    end,
}

-- 5. WHICH WAY THE CLIENT COUNTS FACING, from the player's own movement.
--
--    This is the one that would have ended two bug reports. It cannot be
--    answered by arithmetic, because it is a fact about the client, so it is
--    answered by evidence: when you walk, the direction you moved is the
--    direction you were facing, and only one of the two conventions agrees
--    with that.
--
--    No evidence yet is a SKIP with an instruction, not a pass. An
--    unverified assumption reported as PASS is worse than no check.
CN.RegisterSelfTest{
    area = "navigation",
    name = "your facing is being read the right way round",
    run  = function()
        local nav = CN:GetModule("Navigation")

        if not nav then
            return SKIP, "navigation module not loaded"
        end

        local state = nav.MotionState()

        if state.samples == 0 then
            return SKIP, "no movement seen yet -- point the arrow at "
                .. "something with /cn go, walk forward a few seconds, and "
                .. "run this again"
        end

        if state.verdict == "corrected" then
            return PASS, "was backwards; corrected from your movement and "
                .. "remembered (sign " .. tostring(state.sign) .. ")"
        end

        return PASS, string.format(
            "confirmed against %d movement samples (sign %s)",
            state.samples, tostring(state.sign))
    end,
}

-- 6. MAP ASPECT RATIO. Angles taken from raw map coordinates are distorted by
--    however far from square the zone is, which was wrong in every zone in
--    the game until 0.40.0.
CN.RegisterSelfTest{
    area = "navigation",
    name = "angles are corrected for the shape of the zone",
    run  = function()
        local nav = CN:GetModule("Navigation")

        local mapID = CN.GetPlayerPosition()

        if not nav or not mapID then
            return SKIP, "no map"
        end

        local scaleX, scaleY = nav.MapScale(mapID)

        if scaleX == 1 and scaleY == 1 then
            return SKIP, "the client would not size this map"
        end

        local ratio = scaleX / scaleY

        return PASS, string.format(
            "%.0f x %.0f yards, ratio %.2f -- angles adjusted by it",
            scaleX, scaleY, ratio)
    end,
}

-- 7. THE 0.23.0 BUG. Every quest source read the quest log, so quests
--    offered in front of the player were structurally invisible.
CN.RegisterSelfTest{
    area = "quests",
    name = "the map reports quests you have NOT accepted",
    run  = function()
        local mapID = CN.GetPlayerPosition()

        if not mapID then
            return SKIP, "no map"
        end

        local pois = Blizzard.GetQuestPOIsOnMap(mapID)

        if #pois == 0 then
            return SKIP, "no quest pins on this map at all"
        end

        local starts = 0

        for _, poi in ipairs(pois) do
            if poi.isQuestStart then
                starts = starts + 1
            end
        end

        return PASS, string.format("%d pins, %d of them quest starts",
            #pois, starts)
    end,
}

-- 8. THE 0.32.0 BUG. This returns a table of every quest ever completed, not
--    a count, and reading it on every refresh was expensive.
CN.RegisterSelfTest{
    area = "quests",
    name = "your completed-quest history is readable",
    run  = function()
        local progress = CN:GetModule("Progress")

        if not progress then
            return SKIP, "progress module not loaded"
        end

        local total = progress.LifetimeCompleted()

        if not total then
            return SKIP, "the client will not report a lifetime total"
        end

        return PASS, CN.Comma(total) .. " quests completed on this character"
    end,
}

-- 9. THE 0.26.0 BUG. A criterion can carry its own counter, and a stub that
--    returned only three values hid that.
CN.RegisterSelfTest{
    area = "achievements",
    name = "achievement criteria report their counters",
    run  = function()
        local achievements = CN:GetModule("Achievements")

        if not achievements then
            return SKIP, "achievements module not loaded"
        end

        local sampled, counted = 0, 0

        for achievementID in pairs(achievements.Store()) do
            local criteria = Blizzard.GetAchievementCriteriaList(achievementID, 6)

            for _, criterion in ipairs(criteria) do
                sampled = sampled + 1

                if criterion.required and criterion.required > 1 then
                    counted = counted + 1
                end
            end

            if sampled >= 30 then
                break
            end
        end

        if sampled == 0 then
            return SKIP, "nothing scanned yet -- run /cn setup"
        end

        return PASS, string.format("%d criteria read, %d carry a counter",
            sampled, counted)
    end,
}

-- 10. Names the addon deliberately stopped storing must come back live. If
--    they do not, everything in the interface reads "Pet 12345".
CN.RegisterSelfTest{
    area = "names",
    name = "names resolve from the client rather than from disk",
    run  = function()
        local checked, resolved = 0, 0

        local pets = CN:GetModule("Pets")

        if pets then
            for speciesID in pairs(pets.Store()) do
                checked = checked + 1

                if Blizzard.GetPetName(speciesID) then
                    resolved = resolved + 1
                end

                if checked >= 10 then
                    break
                end
            end
        end

        if checked == 0 then
            return SKIP, "no pets scanned yet"
        end

        if resolved == 0 then
            return FAIL, "the pet journal named none of "
                .. checked .. " -- the interface will show numbers"
        end

        return PASS, resolved .. " of " .. checked .. " named by the client"
    end,
}

-- 11. The database is at the version this build expects. A migration that
--    silently failed leaves a shape nothing else understands.
CN.RegisterSelfTest{
    area = "database",
    name = "the database is at the expected version",
    run  = function()
        if not CN.db then
            return FAIL, "no database loaded at all"
        end

        local version = CN.db.version

        if version ~= CN.dbVersion then
            return FAIL, "database is version " .. tostring(version)
                .. ", this build expects " .. tostring(CN.dbVersion)
        end

        return PASS, "version " .. tostring(version)
    end,
}

-- 12. Size, because it is rewritten on every logout and nobody notices it
--     growing until logging out becomes slow.
CN.RegisterSelfTest{
    area = "database",
    name = "saved data is a reasonable size",
    run  = function()
        if not CN.MeasureDatabase or not CN.db then
            return SKIP, "cannot measure"
        end

        local bytes = CN.MeasureDatabase(CN.db)

        local kb = bytes / 1024

        if kb > 4096 then
            return FAIL, string.format(
                "%.0f KB -- unusually large; run /cn dbsize to see where", kb)
        end

        return PASS, string.format("%.0f KB", kb)
    end,
}

-- 13. The recommendation engine produces something. An addon whose entire
--     purpose is answering a question should be asked it.
CN.RegisterSelfTest{
    area = "engine",
    name = "the engine can answer 'what next'",
    run  = function()
        local results = CN.Recommend(1)

        if not results or #results == 0 then
            return SKIP, "nothing actionable right now -- try /cn setup, or "
                .. "check /cn show in case everything is filtered out"
        end

        local first = results[1]

        return PASS, tostring(first.name or first.id)
            .. " (" .. tostring(first.type) .. ")"
    end,
}

-- 14. LOCKOUTS. The client reports these directly, and a lockout the addon
--     cannot read is a deadline it cannot rank.
CN.RegisterSelfTest{
    area = "instances",
    name = "your dungeon and raid lockouts are readable",
    run  = function()
        local instances = CN:GetModule("Instances")

        if not instances then
            return SKIP, "instances module not loaded"
        end

        local lockouts = instances.Lockouts()

        if #lockouts == 0 then
            return SKIP, "you are not saved to anything right now"
        end

        local summary = instances.Summary()

        return PASS, string.format("%d saved, %d unfinished, %d bosses left",
            summary.total, summary.unfinished, summary.bosses)
    end,
}

-- 15. THE ADVENTURE GUIDE, which is how a drop gets a boss's name attached to
--     it. Open, it must refuse -- reading it moves what the player is looking
--     at, and that refusal is the behaviour worth checking.
CN.RegisterSelfTest{
    area = "instances",
    name = "the Adventure Guide can be read without disturbing you",
    run  = function()
        if not Blizzard.HasEncounterJournal() then
            return SKIP, "this client has no Adventure Guide"
        end

        if Blizzard.IsEncounterJournalOpen() then
            return SKIP, "the Adventure Guide is open, so nothing was read -- "
                .. "which is the intended behaviour, not a fault"
        end

        local encounters = Blizzard.GetInstanceEncounters(1273)

        if #encounters == 0 then
            return SKIP, "the journal returned no bosses for the sample "
                .. "instance; loot lookups may be unavailable"
        end

        return PASS, #encounters .. " bosses read, and the journal's own "
            .. "selection restored"
    end,
}

------------------------------------------------------------
-- COMMAND
------------------------------------------------------------

CN:RegisterCommand{
    name    = "selftest",
    aliases = { "diagnose", "check" },
    order   = 32,
    help    = "Check the addon against the live game and report what it finds.",
    handler = function()
        local rows = SelfTest.Run()

        Print("Self-test: " .. #rows.checks .. " checks against the live client.")

        local area

        for _, check in ipairs(rows.checks) do
            if check.area ~= area then
                area = check.area

                Print("|cffffc74f" .. area .. "|r")
            end

            local colour = "|cff73b873"

            if check.status == FAIL then
                colour = "|cffe2564c"
            elseif check.status == SKIP then
                colour = "|cff8a8f96"
            end

            Print(string.format("  %s%-4s|r %s", colour, check.status, check.name))

            if check.detail then
                Print("        |cff8a8f96" .. check.detail .. "|r")
            end
        end

        Print(string.format("%d passed, %d failed, %d skipped.",
            rows.passed, rows.failed, rows.skipped))

        if rows.failed > 0 then
            Print("|cffffc74fA failure above is a real defect. Copy this "
                .. "output into a bug report -- it says more than any "
                .. "description could.|r")
        end
    end,
}

return SelfTest
