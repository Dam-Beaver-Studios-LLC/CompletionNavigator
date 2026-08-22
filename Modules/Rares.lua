-- Modules/Rares.lua
-- Completion Navigator :: rares and treasures.
--
-- Most rare-tracking addons ship a static database of where rares spawn.
-- That answers "where is it", which is only half the question, and it goes
-- stale every patch.
--
-- This module leads with the client's vignette data instead, because a
-- vignette is the one live signal that a rare is *up right now*. Something
-- that exists this minute and may be dead in five is exactly the kind of
-- objective the opportunity scoring was built for.
--
-- Everything seen is also recorded permanently, so the addon accumulates its
-- own spawn database from play -- same approach as quest harvesting, and it
-- never goes stale because it comes from the live game.

local ADDON_NAME, CN = ...

local Rares = CN:RegisterModule("Rares")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

------------------------------------------------------------
-- STORAGE
------------------------------------------------------------

-- Everything ever seen, keyed by vignetteID. Account-wide: where a rare
-- spawns is a fact about the world.
local function Store()
    return CN.Account("rares")
end

-- Which vignettes this character has already dealt with. Rares are usually
-- once-per-character, so this is character state, not account state.
local function CharacterKills(character)
    character = character or CN.character

    if not character then
        return nil
    end

    character.raresKilled = character.raresKilled or {}

    return character.raresKilled
end

Rares.Store          = Store
Rares.CharacterKills = CharacterKills

------------------------------------------------------------
-- LIVE STATE
------------------------------------------------------------

-- Vignettes currently visible, classified and located.
function Rares.GetActive(mapID)
    mapID = mapID or select(1, CN.GetPlayerPosition())

    local active = {}

    for _, vignette in ipairs(Blizzard.GetVignettes(mapID)) do
        local kind = Blizzard.ClassifyVignette(vignette.atlas)

        if not vignette.isDead then
            table.insert(active, {
                guid       = vignette.guid,
                vignetteID = vignette.vignetteID,
                name       = vignette.name,
                kind       = kind,
                mapID      = vignette.mapID,
                x          = vignette.x,
                y          = vignette.y,
                inFogOfWar = vignette.inFogOfWar,
            })
        end
    end

    table.sort(active, function(a, b)
        if a.kind ~= b.kind then
            return a.kind < b.kind
        end

        return (a.name or "") < (b.name or "")
    end)

    return active
end

------------------------------------------------------------
-- RECORDING
------------------------------------------------------------

function Rares.Record(vignette)
    if not vignette or not vignette.vignetteID then
        return false
    end

    local store    = Store()
    local existing = store[vignette.vignetteID]

    local record = existing or {
        vignetteID = vignette.vignetteID,
        firstSeen  = time(),
        sightings  = 0,
    }

    record.name      = vignette.name or record.name
    record.kind      = vignette.kind or record.kind
    record.lastSeen  = time()
    record.sightings = (record.sightings or 0) + 1

    -- Keep the first coordinates seen; rares roam, and the spawn point is
    -- more useful than wherever it happened to be standing.
    if vignette.mapID and vignette.x and vignette.y then
        if not record.mapID then
            record.mapID = vignette.mapID
            record.x     = math.floor(vignette.x * 10000 + 0.5) / 10000
            record.y     = math.floor(vignette.y * 10000 + 0.5) / 10000
            record.zone  = Blizzard.GetMapName(vignette.mapID)
        end
    end

    store[vignette.vignetteID] = record

    return existing == nil
end

------------------------------------------------------------
-- KILL TRACKING
------------------------------------------------------------

-- A vignette that was present and is now gone, while the player was nearby,
-- is very likely dealt with. This is inference, so it is recorded as
-- "cleared by this character" rather than presented as fact.
local lastSeenGuids = {}

-- HOW CLOSE YOU HAVE TO HAVE BEEN FOR "IT VANISHED" TO MEAN "IT DIED".
--
-- `GetVignettes` returns what is IN RANGE, and a vignette leaves that list
-- for two completely different reasons: somebody killed it, or you rode away
-- from it. The old code could not tell them apart and assumed the first, so
-- riding past a rare marked it cleared -- permanently, with no expiry and no
-- command to undo it. The addon then refused to ever offer that rare to that
-- character again, which is the worst possible failure for a module whose job
-- is to say a rare is up.
--
-- A vignette that goes out of range does so at the edge of the range. One
-- that dies does so wherever it was standing, which for a player who killed
-- it is close. This is still inference, but it is inference that distinguishes
-- the two cases instead of collapsing them.
Rares.clearedWithinYards = 150

-- AND THE INFERENCE EXPIRES.
--
-- Some rares are once per character and some are daily or weekly, and the
-- client does not say which. Remembering forever is right for the first group
-- and permanently wrong for the second; remembering until the weekly reset is
-- approximately right for both, and self-corrects either way.
Rares.rememberSeconds = 7 * 24 * 60 * 60

local function ClearedUntil()
    local seconds = Blizzard.GetSecondsUntilWeeklyReset
        and Blizzard.GetSecondsUntilWeeklyReset()

    if type(seconds) == "number" and seconds > 0 then
        return time() + seconds
    end

    return time() + Rares.rememberSeconds
end

-- Recorded when the client itself says the vignette is dead, which needs no
-- inference at all, and when one vanishes from close range.
function Rares.NoteCleared(vignetteID, name)
    local kills = CharacterKills()

    if not kills or not vignetteID then
        return false
    end

    kills[vignetteID] = ClearedUntil()

    DebugPrint("Marking cleared: " .. tostring(name or vignetteID))

    return true
end

-- The sighting set, so a test can put the module in the state a real
-- VIGNETTE_MINIMAP_UPDATED would have left it in and then drive the real
-- comparison. Writing to `lastSeenGuids` from outside is the alternative, and
-- a test that reaches around the module proves nothing about the module.
function Rares.SetLastSeen(seen)
    lastSeenGuids = seen or {}
end

function Rares.NoteDisappearances(currentGuids)
    local kills = CharacterKills()

    if not kills then
        return
    end

    for guid, entry in pairs(lastSeenGuids) do
        if not currentGuids[guid] and entry.vignetteID then
            if entry.wasDead then
                Rares.NoteCleared(entry.vignetteID, entry.name)
            elseif entry.yards and entry.yards <= Rares.clearedWithinYards then
                Rares.NoteCleared(entry.vignetteID, entry.name)
            else
                DebugPrint("Vignette out of range, not marking cleared: "
                    .. tostring(entry.name))
            end
        end
    end
end

function Rares.IsClearedByCharacter(vignetteID)
    local kills = CharacterKills()

    if not kills then
        return false
    end

    local entry = kills[vignetteID]

    if entry == nil then
        return false
    end

    -- MIGRATED IN PLACE. Entries written before 0.53.0 hold the time the
    -- vignette vanished rather than the time the memory expires, and most of
    -- them are the false positives described above. Treating a bare timestamp
    -- as "expires one week after it was written" retires them without a
    -- migration step and without discarding a genuine recent kill.
    local expires = type(entry) == "number" and entry or 0

    if expires < time() then
        kills[vignetteID] = nil

        return false
    end

    return true
end

-- The player's own escape hatch, because inference that cannot be corrected
-- is just a wrong answer with a longer life.
function Rares.ForgetCleared()
    local kills = CharacterKills()

    if not kills then
        return 0
    end

    local count = CN.CountKeys(kills)

    for key in pairs(kills) do
        kills[key] = nil
    end

    return count
end

------------------------------------------------------------
-- SUMMARY
------------------------------------------------------------

function Rares.Summary()
    local counts = {
        known     = 0,
        rares     = 0,
        treasures = 0,
        located   = 0,
        cleared   = 0,
    }

    local kills = CharacterKills() or {}

    for vignetteID, record in pairs(Store()) do
        counts.known = counts.known + 1

        if record.kind == "TREASURE" then
            counts.treasures = counts.treasures + 1
        else
            counts.rares = counts.rares + 1
        end

        if record.x and record.y then
            counts.located = counts.located + 1
        end

        if kills[vignetteID] then
            counts.cleared = counts.cleared + 1
        end
    end

    return counts
end

------------------------------------------------------------
-- ELIGIBILITY
------------------------------------------------------------

CN.RegisterEligibilityChecker(CN.objectiveTypes.RARE, function(vignetteID)
    local states = CN.objectiveStates
    local record = Store()[vignetteID]

    if not record then
        return states.UNKNOWN, "Never seen this rare", nil
    end

    if Rares.IsClearedByCharacter(vignetteID) then
        return states.COMPLETED, "Cleared by this character", record.name
    end

    return states.AVAILABLE, nil, nil
end)

------------------------------------------------------------
-- CANDIDATES
------------------------------------------------------------

-- Only what is actually up right now becomes a candidate. A rare that is
-- not spawned is not a next action, and the whole point of using vignettes
-- is knowing the difference.
CN.RegisterCandidateProvider("Rares", function()
    local candidates = {}

    local playerMap, playerX, playerY = CN.GetPlayerPosition()

    for _, vignette in ipairs(Rares.GetActive(playerMap)) do
        local objectiveType = vignette.kind == "TREASURE"
            and CN.objectiveTypes.TREASURE
            or CN.objectiveTypes.RARE

        local id = vignette.vignetteID

        if id
            and not Rares.IsClearedByCharacter(id)
            and not CN.IsIgnored(objectiveType, id)
            and not CN.IsDeferred(objectiveType, id) then

            local reasons = {}
            local travel  = 0

            table.insert(reasons, vignette.kind == "TREASURE"
                and "treasure is up right now"
                or "rare is up right now")

            if vignette.x and vignette.y and playerX and playerY then
                local dx = vignette.x - playerX
                local dy = vignette.y - playerY

                travel = math.sqrt((dx * dx) + (dy * dy)) * 10

                table.insert(reasons, "in your current zone")
            end

            table.insert(candidates, CN.NewObjective({
                id               = id,
                type             = objectiveType,
                name             = vignette.name,
                mapID            = vignette.mapID,
                x                = vignette.x,
                y                = vignette.y,
                accountWide      = false,
                state            = CN.objectiveStates.AVAILABLE,
                completionValue  = 2,

                -- Up now, gone when someone else kills it. That is exactly
                -- what the limited-time term is for.
                limitedTimeBonus = 1.5,

                travelCost       = travel,
                reasons          = reasons,
            }))
        end
    end

    return candidates
end, { events = { "VIGNETTE_MINIMAP_UPDATED", "VIGNETTES_UPDATED", "ZONE_CHANGED_NEW_AREA" }, volatile = true })

------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

local function OnVignetteUpdate()
    local mapID = select(1, CN.GetPlayerPosition())

    local currentGuids = {}

    for _, vignette in ipairs(Rares.GetActive(mapID)) do
        currentGuids[vignette.guid] = true

        Rares.Record(vignette)
    end

    Rares.NoteDisappearances(currentGuids)

    -- Rebuild the seen set for the next comparison, carrying the two facts
    -- that let the next comparison tell a kill from a departure: whether the
    -- client had already flagged it dead, and how far away it was.
    local nextSeen = {}

    local playerMap, playerX, playerY = CN.GetPlayerPosition()

    local travel = CN:GetModule("Travel")

    for _, vignette in ipairs(Blizzard.GetVignettes(mapID)) do
        local yards

        if travel and travel.YardsBetween and playerMap and playerX
            and vignette.mapID and vignette.x then

            yards = travel.YardsBetween(playerMap, playerX, playerY,
                vignette.mapID, vignette.x, vignette.y)
        end

        nextSeen[vignette.guid] = {
            vignetteID = vignette.vignetteID,
            name       = vignette.name,
            wasDead    = vignette.isDead and true or false,
            yards      = yards,
        }
    end

    lastSeenGuids = nextSeen
end

CN:RegisterEvent("VIGNETTE_MINIMAP_UPDATED", OnVignetteUpdate)
CN:RegisterEvent("VIGNETTES_UPDATED", OnVignetteUpdate)

CN:RegisterEvent("ZONE_CHANGED_NEW_AREA", function()
    -- Vignettes from the previous zone are meaningless now.
    lastSeenGuids = {}
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "rares",
    order   = 74,
    help    = "Show rares and treasures up right now.",
    handler = function()
        local active = Rares.GetActive()

        if #active == 0 then
            Print("Nothing is up nearby.")
            Print("|cff999999Vignettes only appear for content in range; "
                .. "move around the zone.|r")
            return
        end

        Print("Up right now (" .. #active .. "):")

        for index, vignette in ipairs(active) do
            local cleared = vignette.vignetteID
                and Rares.IsClearedByCharacter(vignette.vignetteID)

            Print("  " .. index .. ". " .. tostring(vignette.name)
                .. " |cff999999[" .. tostring(vignette.kind) .. "]|r"
                .. (cleared and " |cff999999(already cleared)|r" or "")
                .. (vignette.x and string.format(" |cff999999%.1f, %.1f|r",
                    vignette.x * 100, vignette.y * 100) or ""))
        end

        Print("|cffffff00/cn rare <number>|r to set a waypoint.")
        Print("|cff999999\"already cleared\" is inferred from a vignette that "
            .. "vanished while you were next to it, and it expires at the "
            .. "weekly reset. /cn rareforget clears it now.|r")
    end,
}

CN:RegisterCommand{
    name    = "rareforget",
    order   = 77,
    help    = "Forget which rares this character is assumed to have cleared.",
    handler = function()
        local count = Rares.ForgetCleared()

        if count == 0 then
            Print("Nothing was being treated as cleared on this character.")
            return
        end

        Print(count .. " cleared for this character, forgotten. They will be "
            .. "offered again.")

        CN.InvalidateCandidates()
    end,
}

CN:RegisterCommand{
    name    = "rare",
    args    = "<number>",
    order   = 75,
    help    = "Navigate to something that is up right now.",
    handler = function(args)
        local index = CN.ToID(args)

        if not index then
            Print("Usage: /cn rare <number from /cn rares>")
            return
        end

        local active = Rares.GetActive()
        local vignette = active[index]

        if not vignette then
            Print("There is no number " .. index .. " in the current list.")
            return
        end

        CN.NavigateToObjective({
            id    = vignette.vignetteID,
            type  = vignette.kind == "TREASURE"
                and CN.objectiveTypes.TREASURE
                or CN.objectiveTypes.RARE,
            name  = vignette.name,
            mapID = vignette.mapID,
            x     = vignette.x,
            y     = vignette.y,
        })
    end,
}

CN:RegisterCommand{
    name    = "raredb",
    order   = 76,
    help    = "Summarize every rare and treasure recorded from play.",
    handler = function()
        local counts = Rares.Summary()

        if counts.known == 0 then
            Print("Nothing recorded yet. Rares and treasures are captured "
                .. "automatically as you encounter them.")
            return
        end

        Print("Recorded: " .. counts.known
            .. " (" .. counts.rares .. " rares, " .. counts.treasures .. " treasures)")
        Print("With coordinates: " .. counts.located)
        Print("Cleared by this character: " .. counts.cleared)
    end,
}

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
