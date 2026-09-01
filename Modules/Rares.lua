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
-- EVERY VIGNETTE THE CLIENT REPORTS, DEAD ONES INCLUDED. 0.78.0.
--
-- `GetActive` used to filter the dead out AND drop the flag from the rows it
-- built, so `VignetteWork` -- which reads `vignette.isDead` to record that a
-- rare was seen already dead -- could never see one. `wasDead` was therefore
-- false for every row, and the branch in `NoteDisappearances` commented as
-- "needs no inference at all" was unreachable.
--
-- `GetActive` now filters THIS list, so the rows it returns are the same
-- tables and do carry the flag; what it removes is the dead ones.
--
-- So every clear fell through to the "it vanished within 150 yards of me"
-- guess, and a rare somebody else killed, or one tagged and finished while
-- the player rode past two hundred yards away, was never marked cleared --
-- and the addon went on recommending it.
--
-- The filter belongs to the two surfaces that want live rares. The learning
-- pass wants what the client actually said.
function Rares.GetAll(mapID)
    local seen = {}

    for _, vignette in ipairs(Blizzard.GetVignettes(mapID)) do
        table.insert(seen, {
            guid       = vignette.guid,
            vignetteID = vignette.vignetteID,
            name       = vignette.name,
            kind       = Blizzard.ClassifyVignette(vignette.atlas),
            mapID      = vignette.mapID,
            x          = vignette.x,
            y          = vignette.y,
            inFogOfWar = vignette.inFogOfWar,
            isDead     = vignette.isDead and true or false,
        })
    end

    return seen
end

function Rares.GetActive(mapID)
    mapID = mapID or select(1, CN.GetPlayerPosition())

    local active = {}

    for _, vignette in ipairs(Rares.GetAll(mapID)) do
        if not vignette.isDead then
            table.insert(active, vignette)
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

-- HOW LONG A GAP MAKES THE NEXT SIGHTING A NEW ONE. See `Rares.Record`.
-- Longer than any fight, shorter than any respawn.
Rares.sightingGap = 10 * 60

function Rares.Record(vignette)
    if not vignette or not vignette.vignetteID then
        return false
    end

    local store    = Store()
    local existing = store[vignette.vignetteID]

    -- `firstSeen` IS NOT STORED. 0.92.0. `Modules/Mounts.lua` states the
    -- rule -- "nothing has ever read a mount record's `firstSeen`" -- and
    -- migration 5 stripped it from four stores. `rares` and `vendors` were in
    -- none of those sweeps and both writers were live. `lastSeen` below IS
    -- read, for the sightings gap, and stays.
    local record = existing or {
        vignetteID = vignette.vignetteID,
        sightings  = 0,
    }

    record.name      = vignette.name or record.name
    record.kind      = vignette.kind or record.kind

    -- A SIGHTING IS AN ENCOUNTER, NOT AN EVENT DISPATCH. 0.66.0.
    --
    -- This counter was incremented once per vignette per dispatch, and
    -- `VIGNETTE_MINIMAP_UPDATED` fires several times a second while anything
    -- is moving in range -- this file's own provider comment says so, which
    -- is why the PROVIDER has a five-second cooldown and this handler had
    -- none. Its one reader is the goal plan, so `/cn goal` told a player who
    -- had met a rare twice that they had seen it 1,847 times, and the number
    -- climbed while they stood there.
    --
    -- An encounter is a sighting after a gap. Ten minutes is longer than any
    -- fight and shorter than any respawn.
    local previous = record.lastSeen or 0

    if time() - previous >= Rares.sightingGap then
        record.sightings = (record.sightings or 0) + 1
    end

    record.lastSeen  = time()

    -- Keep the first coordinates seen; rares roam, and the spawn point is
    -- more useful than wherever it happened to be standing.
    if vignette.mapID and vignette.x and vignette.y then
        if not record.mapID then
            record.mapID = vignette.mapID
            record.x     = math.floor(vignette.x * 10000 + 0.5) / 10000
            record.y     = math.floor(vignette.y * 10000 + 0.5) / 10000
            -- `zone` IS NOT STORED. 0.62.0.
            --
            -- It was written on every sighting and read by nothing: the map
            -- id is already on the row and the client derives the name from
            -- it instantly. Migration 7 deleted this exact field from
            -- `questHarvest` with that exact note, and this copy survived.
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

    -- LEGACY ENTRIES ARE RETIRED, NOT CONVERTED. The comment here used to
    -- claim they were treated as "expires one week after it was written",
    -- and the code has always treated the number as the expiry itself --
    -- so an entry written before 0.53.0, which holds the time the vignette
    -- VANISHED and is therefore always in the past, is dropped on first read.
    --
    -- That is the right outcome and the comment was the thing that was
    -- wrong. Most of those entries are the false positives described above,
    -- the rule they were written under is gone, and a rare offered once more
    -- than it needed to be is a smaller error than one silently never offered
    -- again. Corrected rather than implemented, in 0.67.0: converting them
    -- would mean adding a week to genuine expiries that have already passed,
    -- which resurrects exactly the stale clears this expiry exists to end.
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

        -- THROUGH THE RULE, NOT THE RAW TABLE. 0.66.0.
        --
        -- A cleared entry is a timestamp, and `IsClearedByCharacter` is the
        -- one place that knows an expired one no longer counts -- it prunes
        -- as it reads. Testing the table for truthiness counted entries that
        -- had already expired, so after a weekly reset `/cn raredb` reported
        -- 40 rares cleared while `/cn rares` was correctly offering all 40
        -- again. The addon contradicting itself about its own state.
        if Rares.IsClearedByCharacter(vignetteID) then
            counts.cleared = counts.cleared + 1
        end
    end

    return counts
end

------------------------------------------------------------
-- ELIGIBILITY
------------------------------------------------------------

-- FOR BOTH TYPES THIS FILE EMITS. 0.78.0.
--
-- The provider below produces `RARE` and `TREASURE` rows from one store, and
-- only `RARE` had a checker -- so roughly half of what this module puts on
-- the list resolved to `UNKNOWN` in `CN.Explain`. `/cn why` on a treasure
-- said nothing useful, and the auto-advance staleness test had to fall
-- through to a linear scan of the whole candidate list every time.
--
-- One closure, registered twice, with wording that fits either.
local function Eligibility(vignetteID)
    local states = CN.objectiveStates
    local record = Store()[vignetteID]

    if not record then
        return states.UNKNOWN, "Never seen this one", nil
    end

    if Rares.IsClearedByCharacter(vignetteID) then
        return states.COMPLETED, "Cleared by this character", record.name
    end

    -- AND A ROW THE CLIENT IS NOT REPORTING RIGHT NOW IS NOT AVAILABLE.
    -- 0.79.0.
    --
    -- These two types are the only ones in the addon whose objectives exist
    -- only while the client says so: a rare that despawned, or a treasure
    -- somebody else looted, is gone with no event to say it.
    --
    -- Before 0.78.0 `TREASURE` had no checker at all, so the staleness test
    -- fell through to "is this still a candidate", which caught exactly that.
    -- Registering a checker without a liveness test took the fallback away
    -- and left the waypoint pointed at something that is not there -- which
    -- is the failure `Routing.lua` describes for the seven checker-less types
    -- and was written to end.
    --
    -- `UNKNOWN` is the honest answer: the store remembers this thing, and
    -- whether it is up right now is a question only the client can answer.
    local mapID = select(1, CN.GetPlayerPosition())

    if mapID then
        for _, vignette in ipairs(Rares.GetAll(mapID)) do
            if vignette.vignetteID == vignetteID and not vignette.isDead then
                return states.AVAILABLE, nil, nil
            end
        end

        return states.UNKNOWN, "Not up right now", record.name
    end

    return states.AVAILABLE, nil, nil
end

CN.RegisterEligibilityChecker(CN.objectiveTypes.RARE, Eligibility)
CN.RegisterEligibilityChecker(CN.objectiveTypes.TREASURE, Eligibility)

------------------------------------------------------------
-- CANDIDATES
------------------------------------------------------------

-- Only what is actually up right now becomes a candidate. A rare that is
-- not spawned is not a next action, and the whole point of using vignettes
-- is knowing the difference.
CN.RegisterCandidateProvider("Rares", function()
    local candidates = {}

    -- The point is not read here any more: the "in your current zone" line
    -- compares MAPS now, and the travel cost takes the vignette's own point.
    local playerMap = CN.GetPlayerPosition()

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

            table.insert(reasons, vignette.kind == "TREASURE"
                and "treasure is up right now"
                or "rare is up right now")

            -- THROUGH THE TRAVEL MODEL, LIKE EVERY OTHER LOCATED PROVIDER.
            --
            -- This did raw Pythagoras on normalized map units and multiplied
            -- by ten, which asserts three things that are not true: that a
            -- map unit is the same number of yards north-south as east-west
            -- (the bearing defect of 0.40.0, in a different file), that every
            -- zone is about 2,100 yards across, and that the player is on
            -- foot. Quests, opportunities, vendors, toys and goals all go
            -- through `CN.TravelCost`, which knows the zone's real scale, the
            -- flight network and the player's own measured speed.
            --
            -- Left NIL rather than zero when there are no coordinates: zero
            -- means "you are standing on it", and `CN.IsPlaceless` reads it
            -- that way, so a rare the client would not place was scored as
            -- free AND exempt from the unknown-location cost.
            -- `costed` SAYS WHETHER THE MODEL ANSWERED. 0.70.0.
            --
            -- `CN.TravelCost` never refuses -- on a miss it hands back the
            -- constant the scorer ranks an unknown location with -- and every
            -- caller but one threw the second return away. So nothing
            -- downstream could tell a twenty-minute flight from "I could not
            -- work this out", and `/cn list` printed the second as the first.
            local travel, costed

            if vignette.x and vignette.y then
                travel, costed = CN.TravelCost(vignette.mapID, vignette.x, vignette.y)

                -- THE ZONE, NOT WHETHER THE CLIENT WOULD PLACE YOU. 0.92.0.
                --
                -- The sentence is a claim about map identity; the guard
                -- tested whether the client answered with a position at all.
                -- So a vignette on another map was still labelled "in your
                -- current zone", and a rare genuinely in this zone lost the
                -- line whenever the client withheld coordinates -- indoors,
                -- mid-loading-screen -- which is when a `/cn why` line is
                -- most likely to be read.
                --
                -- `Modules/Opportunities.lua` has this right three files
                -- over: `if worldQuest.mapID == playerMap then`.
                if vignette.mapID and vignette.mapID == playerMap then
                    table.insert(reasons, "in your current zone")
                end
            end

            table.insert(candidates, CN.NewObjective({
                id               = id,
                type             = objectiveType,
                name             = vignette.name,
                mapID            = vignette.mapID,
                x                = vignette.x,
                y                = vignette.y,
                accountWide      = false,
                travelCosted     = costed or nil,
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
-- A COOLDOWN, BECAUSE VIGNETTE EVENTS FIRE CONSTANTLY IN THE OPEN WORLD.
--
-- `VIGNETTE_MINIMAP_UPDATED` fires several times a second while anything is
-- moving in range, and with no cooldown this provider was marked dirty
-- continuously -- and every dirty rebuild used to bump the aggregate
-- generation, which forces a full re-score of everything.
--
-- Five seconds costs nothing in freshness: a rare that appeared two seconds
-- ago is still there, and the alert path that announces one is a separate
-- event handler that is not throttled by this at all.
end, { events = { "VIGNETTE_MINIMAP_UPDATED", "VIGNETTES_UPDATED", "ZONE_CHANGED_NEW_AREA" },
       volatile = true, cooldown = 5 })

------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

-- ONE SWEEP, ONCE A SECOND. 0.66.0.
--
-- This ran on `VIGNETTE_MINIMAP_UPDATED` AND `VIGNETTES_UPDATED` with no
-- debounce at all -- several times a second while anything moves in range --
-- and each run did TWO full `GetVignettes` sweeps of the same map, a distance
-- calculation per row, two position reads, and a SavedVariables write per
-- rare. Flying across a zone with eight vignettes up, that is roughly 34
-- pcall'd client calls and 16 table allocations several times a second.
--
-- The second sweep was reading exactly what the first had already read.
local function VignetteWork()
    local mapID = select(1, CN.GetPlayerPosition())

    -- EVERY VIGNETTE, NOT THE LIVE ONES. 0.78.0. See `Rares.GetAll`: this
    -- reads `isDead` a few lines down, and `GetActive` had already removed
    -- every row that would have carried it.
    local active = Rares.GetAll(mapID)

    local currentGuids = {}

    for _, vignette in ipairs(active) do
        currentGuids[vignette.guid] = true

        -- A CORPSE IS NOT AN ENCOUNTER. 0.79.0.
        --
        -- 0.78.0 switched this walk to the unfiltered list so the dead flag
        -- would survive -- correctly -- and went on recording every row,
        -- dead ones included. `Record` bumps `sightings` after a ten-minute
        -- gap, and that counter is shown in the goal plan, so riding past
        -- the same corpse on three days read as three encounters.
        --
        -- The header on that counter says it exists because `/cn goal` once
        -- told a player who had met a rare twice that they had seen it 1,847
        -- times. The dead flag is needed for the disappearance inference
        -- below, not for the count.
        if not vignette.isDead then
            Rares.Record(vignette)
        end
    end

    Rares.NoteDisappearances(currentGuids)

    -- Rebuild the seen set for the next comparison, carrying the two facts
    -- that let the next comparison tell a kill from a departure: whether the
    -- client had already flagged it dead, and how far away it was.
    local nextSeen = {}

    local playerMap, playerX, playerY = CN.GetPlayerPosition()

    local travel = CN:GetModule("Travel")

    for _, vignette in ipairs(active) do
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

-- Exposed unthrottled so the offline harness and `/cn selftest` can drive it
-- directly; the game only ever reaches it through the debounce below.
Rares.VignetteWork = VignetteWork

local function OnVignetteUpdate()
    CN.Debounce("Rares.vignettes", 1, VignetteWork)
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
            Print("|cff8a8f96Vignettes only appear for content in range; "
                .. "move around the zone.|r")
            return
        end

        Print("Up right now (" .. #active .. "):")

        for index, vignette in ipairs(active) do
            local cleared = vignette.vignetteID
                and Rares.IsClearedByCharacter(vignette.vignetteID)

            CN.PrintLine("  " .. index .. ". " .. tostring(vignette.name)
                .. " |cff8a8f96[" .. tostring(vignette.kind) .. "]|r"
                .. (cleared and " |cff8a8f96(already cleared)|r" or "")
                .. (vignette.x and string.format(" |cff8a8f96%.1f, %.1f|r",
                    vignette.x * 100, vignette.y * 100) or ""))
        end

        Print("|cffffc74f/cn rare <number>|r to set a waypoint.")
        Print("|cff8a8f96\"already cleared\" is inferred from a vignette that "
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
