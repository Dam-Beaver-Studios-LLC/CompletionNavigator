-- Modules/Travel.lua
-- Completion Navigator :: how long it actually takes to get there.
--
-- WHAT WAS WRONG.
--
-- Every travel figure in this addon was a straight line. Within a zone that is
-- very nearly right -- you run in roughly the direction you are going. Between
-- zones it is not even approximately right, and the addon papered over that
-- with a flat penalty: anything outside your current zone cost the same
-- whether it was over the next ridge or on the far side of the continent.
--
-- That flat number is why `/cn plan 30` could put something in your half hour
-- that is a flight and a ride away, and why `/cn zones` ranked a zone with a
-- flight master in it the same as one without.
--
-- WHAT THIS DOES.
--
-- Costs a journey the way you would actually make it: run to the nearest
-- flight point you know, fly, run from the arrival point to the target -- and
-- compares that against simply running the whole way, taking whichever is
-- quicker. Flight points you have not discovered do not exist as far as this
-- is concerned, because they do not exist for you either.
--
-- WHAT IT REFUSES TO DO.
--
-- Guess. Flight speed is MEASURED, from your own flights, exactly the way
-- running speed already is -- the client will not tell us and the number
-- differs between expansions. Until it has been measured, estimates are
-- returned with confidence false and every caller says so out loud rather
-- than printing a number that looks like a fact.
--
-- Two continents with no flight between them return nil, not a large number.
-- "I do not know" is an answer; a fabricated four hours is not.

local ADDON_NAME, CN = ...

local Travel = CN:RegisterModule("Travel")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

------------------------------------------------------------
-- POINTS IN THE WORLD
------------------------------------------------------------

-- Map coordinates are normalized per map, so two points on different maps
-- cannot be compared at all in map space. World coordinates can: they are
-- yards, they are continuous across a continent, and the client will convert
-- into them. This is what makes a cross-zone distance possible where the old
-- code simply gave up and charged a flat penalty.
-- MEMOISED, and safely so: a map coordinate's world position is a property of
-- the world, not of the player, so it cannot go stale. The conversion is a
-- client call with a table allocation on either side of it, and costing a
-- journey needs four of them -- which the quest provider then does once per
-- candidate.
--
-- Bounded rather than unbounded: a long session touches a lot of points, and a
-- cache with no ceiling is a memory leak with good intentions.
local worldPoints = {}
local worldPointCount = 0

Travel.worldPointCap = 2048

function Travel.ForgetWorldPoints()
    worldPoints = {}
    worldPointCount = 0
end

function Travel.WorldPoint(mapID, x, y)
    if not (mapID and x and y) then
        return nil
    end

    -- Rounded to about a yard on any map. Finer than that is precision the
    -- callers do not use and cache entries nothing will ever hit again.
    local key = mapID .. ":" .. math.floor(x * 10000) .. ":" .. math.floor(y * 10000)

    local cached = worldPoints[key]

    if cached ~= nil then
        if cached == false then
            return nil
        end

        return cached
    end

    if not C_Map or not C_Map.GetWorldPosFromMapPos or not CreateVector2D then
        return nil
    end

    local ok, continentID, position =
        pcall(C_Map.GetWorldPosFromMapPos, mapID, CreateVector2D(x, y))

    if not ok or not position then
        -- NOT cached as a miss: during a loading screen the client refuses
        -- every conversion, and remembering that would poison the cache for
        -- the rest of the session.
        return nil
    end

    local wx, wy

    if position.GetXY then
        local gotXY, gx, gy = pcall(position.GetXY, position)

        if gotXY then
            wx, wy = gx, gy
        end
    end

    wx = wx or position.x
    wy = wy or position.y

    if not wx or not wy then
        return nil
    end

    local point = { continent = continentID, x = wx, y = wy }

    if worldPointCount >= Travel.worldPointCap then
        Travel.ForgetWorldPoints()
    end

    worldPoints[key] = point
    worldPointCount  = worldPointCount + 1

    return point
end

-- Yards between two world points, or nil when they are not on the same
-- continent -- in which case the straight-line number would be meaningless
-- rather than merely imprecise.
function Travel.YardsBetweenPoints(from, to)
    if not from or not to then
        return nil
    end

    if from.continent and to.continent and from.continent ~= to.continent then
        return nil
    end

    local dx = to.x - from.x
    local dy = to.y - from.y

    return math.sqrt((dx * dx) + (dy * dy))
end

-- The headline: distance between two points that may be on different maps.
function Travel.YardsBetween(fromMapID, fromX, fromY, toMapID, toX, toY)
    return Travel.YardsBetweenPoints(
        Travel.WorldPoint(fromMapID, fromX, fromY),
        Travel.WorldPoint(toMapID, toX, toY))
end

------------------------------------------------------------
-- FLIGHT POINTS
------------------------------------------------------------

-- The continent a map belongs to. Taxi nodes are listed per continent, and a
-- zone map will not answer for them.
function Travel.ContinentFor(mapID)
    local guard = 0

    while mapID and guard < 12 do
        local info = Blizzard.GetMapInfo(mapID)

        if not info then
            return nil
        end

        -- Enum.UIMapType.Continent == 2.
        if info.mapType == 2 then
            return mapID
        end

        mapID = info.parentMapID

        guard = guard + 1
    end

    return nil
end

-- Cached per continent. The set of flight points you know changes only when
-- you discover one, which is rare and which the client announces.
local nodeCache = {}

function Travel.ForgetNodes()
    nodeCache = {}
end

-- Only nodes you can actually use. An undiscovered flight master is not a
-- shortcut, and costing a journey through one would produce a plan you cannot
-- follow -- which is worse than a pessimistic plan you can.
local function IsUsable(node)
    if not node then
        return false
    end

    if not Enum or not Enum.FlightPathState then
        -- Unknown enum: trust the client's list rather than dropping
        -- everything, and let the distance maths decide.
        return true
    end

    return node.state == Enum.FlightPathState.Current
        or node.state == Enum.FlightPathState.Reachable
end

function Travel.KnownNodes(mapID)
    local continent = Travel.ContinentFor(mapID)

    if not continent then
        return {}, nil
    end

    if nodeCache[continent] then
        return nodeCache[continent], continent
    end

    if not C_TaxiMap or not C_TaxiMap.GetAllTaxiNodes then
        return {}, continent
    end

    local ok, nodes = pcall(C_TaxiMap.GetAllTaxiNodes, continent)

    if not ok or type(nodes) ~= "table" then
        return {}, continent
    end

    local usable = {}

    for _, node in ipairs(nodes) do
        if IsUsable(node) and node.position then
            local nx, ny

            if node.position.GetXY then
                local gotXY, gx, gy = pcall(node.position.GetXY, node.position)

                if gotXY then
                    nx, ny = gx, gy
                end
            end

            nx = nx or node.position.x
            ny = ny or node.position.y

            local point = nx and Travel.WorldPoint(continent, nx, ny)

            if point then
                table.insert(usable, {
                    name  = node.name,
                    id    = node.nodeID,
                    point = point,
                })
            end
        end
    end

    nodeCache[continent] = usable

    return usable, continent
end

-- Nearest known flight point to a world point, and how far it is.
function Travel.NearestNode(point, nodes)
    if not point then
        return nil, nil
    end

    local best, bestYards

    for _, node in ipairs(nodes or {}) do
        local yards = Travel.YardsBetweenPoints(point, node.point)

        if yards and (not bestYards or yards < bestYards) then
            best, bestYards = node, yards
        end
    end

    return best, bestYards
end

------------------------------------------------------------
-- HOW FAST YOU FLY
------------------------------------------------------------

-- MEASURED, not assumed. Flight-path speed differs by expansion and by
-- whether the route is a modern one, the client does not expose it, and
-- Session already discards taxi movement when learning running speed -- so
-- nothing in the addon knew this number at all.
--
-- Seeded with a figure that is in the right area so the feature does
-- something on day one, and flagged as unmeasured until the player has
-- actually flown, exactly as running speed is.
Travel.seededFlightSpeed = 25

-- The part of a flight that is not flying: talking to the flight master,
-- taking off, and landing. A constant rather than a measurement because it is
-- dominated by a fixed animation, and because the alternative -- timing the
-- gossip window -- would be measuring the player's reading speed.
Travel.flightOverheadSeconds = 20

-- Casting a teleport and loading the destination. A constant for the same
-- reason as the others: it is an animation and a loading screen, not
-- something worth instrumenting.
Travel.castSeconds = 15

Travel.speedSampleCap = 20

local function Samples()
    local account = CN.Account("flight")

    account.samples = account.samples or {}

    return account.samples
end

local flight = {
    point = nil,
    at    = nil,
    yards = 0,
    seconds = 0,
}

local function Median(values)
    if not values or #values == 0 then
        return nil
    end

    local sorted = {}

    for _, value in ipairs(values) do
        table.insert(sorted, value)
    end

    table.sort(sorted)

    local middle = math.floor(#sorted / 2)

    if #sorted % 2 == 1 then
        return sorted[middle + 1]
    end

    return (sorted[middle] + sorted[middle + 1]) / 2
end

-- Returns yards per second and whether it was measured.
function Travel.FlightSpeed()
    local measured = Median(Samples())

    if measured and measured > 0 then
        return measured, true
    end

    return Travel.seededFlightSpeed, false
end

function Travel.FlightSampleCount()
    return #Samples()
end

-- Called on a timer while the player is on a taxi. Accumulates distance and
-- time for the whole flight and records ONE sample when it ends, rather than
-- one per tick: a flight is a single observation of a constant speed, and
-- treating each tick as independent would let a long flight drown out every
-- other measurement.
function Travel.ObserveFlight()
    local onTaxi = UnitOnTaxi and UnitOnTaxi("player")

    local now = (GetTime and GetTime()) or 0

    if not onTaxi then
        if flight.at and flight.seconds > 10 and flight.yards > 100 then
            local speed = flight.yards / flight.seconds

            -- Sanity bounds. A loading screen or a zone change mid-flight can
            -- produce a figure no aircraft in this game achieves, and one bad
            -- sample in a median of twenty is survivable but pointless.
            if speed > 5 and speed < 200 then
                local samples = Samples()

                table.insert(samples, speed)

                while #samples > Travel.speedSampleCap do
                    table.remove(samples, 1)
                end

                DebugPrint(string.format(
                    "Flight speed sampled: %.1f yards/second over %.0f yards.",
                    speed, flight.yards))
            end
        end

        flight.point, flight.at = nil, nil
        flight.yards, flight.seconds = 0, 0

        return false
    end

    local mapID, x, y = CN.GetPlayerPosition()

    local point = mapID and Travel.WorldPoint(mapID, x, y)

    if point and flight.point and flight.at then
        local yards = Travel.YardsBetweenPoints(flight.point, point)

        local elapsed = now - flight.at

        -- Crossing a continent boundary mid-flight yields nil, which is not a
        -- reason to throw the flight away -- just this interval.
        if yards and elapsed > 0 and elapsed < 10 then
            flight.yards   = flight.yards + yards
            flight.seconds = flight.seconds + elapsed
        end
    end

    flight.point, flight.at = point, now

    return true
end

------------------------------------------------------------
-- FLYING YOURSELF
------------------------------------------------------------

-- Seconds spent mounting up and gaining height before any distance is
-- covered. A constant, like the flight master's overhead, and for the same
-- reason: it is an animation, not a measurement.
Travel.takeoffSeconds = 6

-- Whether the player can fly to the destination.
--
-- Two separate questions, and both have to be yes: does this character fly at
-- all, and does the game allow it where they are going. `IsFlyableArea`
-- answers for where the player IS, which is the honest approximation
-- available -- the client will not answer for a zone the player is not in, so
-- a cross-zone claim is checked at the near end and re-checked when they get
-- there.
-- Which zones the player has actually been able to fly in.
--
-- `IsFlyableArea` answers for where the player IS STANDING, and there is no
-- API that answers for anywhere else -- so a cross-zone claim was being made
-- from the near end and could be wrong at the far end. Remembering the answer
-- per zone, as it is observed, turns that guess into evidence: a zone the
-- player has flown in is flyable, and one they have been in and could not fly
-- in is not.
local function FlightMemory()
    return CN.Account("flyableZones")
end

Travel.FlightMemory = FlightMemory

function Travel.NoteFlyable(mapID)
    if not mapID or not IsFlyableArea then
        return nil
    end

    local ok, flyable = pcall(IsFlyableArea)

    if not ok then
        return nil
    end

    FlightMemory()[mapID] = flyable and true or false

    return flyable
end

function Travel.CanFly(mapID)
    if not Travel.HasFlying() then
        return false
    end

    -- What is REMEMBERED about the destination beats what is true where the
    -- player happens to be standing.
    local remembered = mapID and FlightMemory()[mapID]

    if remembered == false then
        return false
    end

    if remembered ~= true and IsFlyableArea and not IsFlyableArea() then
        -- Nothing remembered, and flight is disabled here. The conservative
        -- answer is the one the player can definitely follow.
        return false
    end

    -- Same continent only; crossing one is handled above.
    local continent = Travel.ContinentFor(mapID)

    return continent ~= nil
end

-- Has this character ever actually flown? Measured, not assumed: the client
-- exposes no reliable "can you fly here" for an arbitrary map, and skyriding
-- availability changes with expansion, level and campaign progress. A
-- character with flying samples has flown; one without has not, and the
-- addon does not offer them a route they may not be able to take.
function Travel.HasFlying()
    local session = CN:GetModule("Session")

    if not session or not session.SpeedSampleCount then
        return false
    end

    return session.SpeedSampleCount("flying") >= (session.minSamples or 3)
end

-- Yards per second flying yourself, from the player's own measurements.
function Travel.SelfFlightSpeed()
    local session = CN:GetModule("Session")

    if not session or not session.Speed then
        return Travel.seededFlightSpeed, false
    end

    return session.Speed("flying")
end

------------------------------------------------------------
-- HEARTHSTONES, PORTALS AND TELEPORTS
------------------------------------------------------------

-- WHAT THIS IS AND IS NOT.
--
-- It is a list of ways off this continent that the player DEMONSTRABLY has:
-- an item in their bags, or a spell they know. Each one is reported with the
-- cooldown the client gives, so "your hearthstone is ready" and "your
-- hearthstone is on a 40 minute cooldown" are different answers.
--
-- It is NOT a routing model. The addon does not know where a hearthstone is
-- bound in map terms -- `GetBindLocation` returns a name, and names do not
-- convert to map ids -- so no duration is claimed and none is folded into any
-- score. Naming the option is useful; costing it would be fiction.
-- WHERE A TELEPORT ACTUALLY GOES.
--
-- The client will not convert a hearthstone's bind location into a map, and
-- it will not tell you where a mage portal leads either. Both are knowable
-- facts about the game rather than about the player, so they are curated
-- here -- which is the same argument that put quest locations in Data.
--
-- `mapID` is the ZONE the teleport lands in. Where it is nil, the option is
-- still listed and simply cannot be costed; naming a shortcut you have is
-- useful even when the addon cannot price it.
Travel.teleports = {
    { kind = "item",  id = 6948,   label = "Hearthstone" },
    { kind = "item",  id = 110560, label = "Garrison Hearthstone" },
    { kind = "item",  id = 140192, label = "Dalaran Hearthstone" },
    { kind = "item",  id = 141605, label = "Flight Master's Whistle" },
    { kind = "spell", id = 556,    label = "Astral Recall" },
    { kind = "spell", id = 3565,   label = "Teleport: Darnassus",     mapID = 89 },
    { kind = "spell", id = 3562,   label = "Teleport: Ironforge",     mapID = 87 },
    { kind = "spell", id = 3561,   label = "Teleport: Stormwind",     mapID = 84 },
    { kind = "spell", id = 3567,   label = "Teleport: Orgrimmar",     mapID = 85 },
    { kind = "spell", id = 3563,   label = "Teleport: Undercity",     mapID = 90 },
    { kind = "spell", id = 3566,   label = "Teleport: Thunder Bluff", mapID = 88 },
    { kind = "spell", id = 18960,  label = "Teleport: Moonglade" },
    { kind = "spell", id = 50977,  label = "Death Gate" },
    { kind = "spell", id = 126892, label = "Zen Pilgrimage" },
}

local function ItemCooldown(itemID)
    local count = 0

    if C_Item and C_Item.GetItemCount then
        count = C_Item.GetItemCount(itemID) or 0
    elseif GetItemCount then
        count = GetItemCount(itemID) or 0
    end

    if count <= 0 then
        return nil
    end

    local start, duration

    if C_Item and C_Item.GetItemCooldown then
        start, duration = C_Item.GetItemCooldown(itemID)
    elseif GetItemCooldown then
        start, duration = GetItemCooldown(itemID)
    end

    if not start or not duration or duration == 0 then
        return 0
    end

    local remaining = (start + duration) - ((GetTime and GetTime()) or 0)

    return math.max(0, remaining)
end

local function SpellCooldown(spellID)
    local known = false

    if IsSpellKnown then
        local ok, result = pcall(IsSpellKnown, spellID)

        known = ok and result
    end

    if not known and IsPlayerSpell then
        local ok, result = pcall(IsPlayerSpell, spellID)

        known = ok and result
    end

    if not known then
        return nil
    end

    local start, duration

    if C_Spell and C_Spell.GetSpellCooldown then
        local info = C_Spell.GetSpellCooldown(spellID)

        if type(info) == "table" then
            start, duration = info.startTime, info.duration
        end
    elseif GetSpellCooldown then
        start, duration = GetSpellCooldown(spellID)
    end

    if not start or not duration or duration == 0 then
        return 0
    end

    local remaining = (start + duration) - ((GetTime and GetTime()) or 0)

    return math.max(0, remaining)
end

-- Every teleport this character has, with seconds of cooldown remaining.
-- Ready ones first, because that is the order they are useful in.
function Travel.ReadyTeleports()
    local available = {}

    for _, entry in ipairs(Travel.teleports) do
        local remaining

        if entry.kind == "item" then
            remaining = ItemCooldown(entry.id)
        else
            remaining = SpellCooldown(entry.id)
        end

        if remaining then
            table.insert(available, {
                label     = entry.label,
                kind      = entry.kind,
                id        = entry.id,
                mapID     = entry.mapID,
                remaining = remaining,
                ready     = remaining <= 0,
                -- Where a hearthstone actually goes. A name, because that is
                -- all the client offers; deliberately not turned into a map.
                bound     = (entry.id == 6948 and GetBindLocation)
                    and GetBindLocation() or nil,
            })
        end
    end

    table.sort(available, function(a, b)
        if a.ready ~= b.ready then
            return a.ready
        end

        return a.remaining < b.remaining
    end)

    return available
end

------------------------------------------------------------
-- THE ESTIMATE
------------------------------------------------------------

-- Returns seconds, confident, detail.
--
-- detail = { mode = "run"|"fly", yards, runToNode, flightYards, runFromNode,
--            node, arrival }
function Travel.EstimateSeconds(fromMapID, fromX, fromY, toMapID, toX, toY)
    local from = Travel.WorldPoint(fromMapID, fromX, fromY)
    local to   = Travel.WorldPoint(toMapID, toX, toY)

    if not from or not to then
        return nil, false, nil
    end

    if from.continent and to.continent and from.continent ~= to.continent then
        -- ANOTHER CONTINENT.
        --
        -- Still no duration: portal networks and boat schedules are not
        -- modelled and a fabricated number would be worse than an admission.
        -- But "I cannot cost this" and "there is no way to do it" are
        -- different statements, and until 0.43.0 the addon made the first and
        -- the player heard the second. So: say what is actually available.
        local teleports = Travel.ReadyTeleports()

        -- COSTED THROUGH A TELEPORT, WHERE ONE LANDS SOMEWHERE USEFUL.
        --
        -- Until 0.44.0 a cross-continent journey returned nothing at all,
        -- which is honest and unhelpful: the real answer is usually "hearth,
        -- then fly for ten seconds". Where a teleport has a known destination
        -- ON THE TARGET'S CONTINENT, the journey becomes castable: the
        -- teleport, plus the ordinary journey from where it drops you.
        --
        -- A teleport on cooldown is still offered, with the wait added --
        -- because "twenty minutes, then four" is a real answer and often the
        -- right one.
        local best

        for _, teleport in ipairs(teleports) do
            local landing = teleport.mapID and Travel.WorldPoint(teleport.mapID, 0.5, 0.5)

            if landing and landing.continent == to.continent then
                local onward, _, onwardDetail = Travel.EstimateSeconds(
                    teleport.mapID, 0.5, 0.5, toMapID, toX, toY)

                if onward then
                    local seconds = onward + Travel.castSeconds
                        + (teleport.ready and 0 or teleport.remaining)

                    if not best or seconds < best.seconds then
                        best = {
                            seconds   = seconds,
                            mode      = "teleport",
                            via       = teleport.label,
                            waited    = teleport.ready and 0 or teleport.remaining,
                            onward    = onward,
                            onwardMode = onwardDetail and onwardDetail.mode,
                        }
                    end
                end
            end
        end

        if best then
            -- Never confident: the onward leg is measured from the middle of
            -- the landing zone, because the addon does not know precisely
            -- where a teleport puts you down.
            best.teleports = teleports

            return best.seconds, false, best
        end

        return nil, false, {
            mode      = "elsewhere",
            teleports = teleports,
        }
    end

    local session = CN:GetModule("Session")

    local runSpeed, runMeasured = 7, false

    if session and session.Speed then
        runSpeed, runMeasured = session.Speed()
    end

    runSpeed = math.max(0.5, runSpeed)

    local direct = Travel.YardsBetweenPoints(from, to)

    if not direct then
        return nil, false, nil
    end

    local best = {
        seconds = direct / runSpeed,
        mode    = "run",
        yards   = direct,
    }

    local confident = runMeasured

    -- SELF-FLYING (0.43.0).
    --
    -- In current content, flying yourself point to point usually beats both
    -- running and the flight network: no walk to a flight master, no
    -- overhead, and a straight line. Leaving it out meant the addon sent
    -- people to a flight master for journeys they would simply fly.
    --
    -- Only offered where the player can actually fly: a zone with flying
    -- disabled, or a character who has never flown, gets the ground answer.
    if Travel.CanFly(toMapID) then
        local flySpeed, flyMeasured = Travel.SelfFlightSpeed()

        local seconds = (direct / flySpeed) + Travel.takeoffSeconds

        if seconds < best.seconds then
            best = {
                seconds = seconds,
                mode    = "self",
                yards   = direct,
            }

            confident = flyMeasured
        end
    end

    local nodes = Travel.KnownNodes(toMapID) or {}

    if #nodes >= 2 then
        -- THE BEST PAIR, NOT THE NEAREST AT EACH END.
        --
        -- Nearest-to-you and nearest-to-target are two independently sensible
        -- choices that together are often not the best route: a flight point
        -- slightly further from you can sit much closer to where you are
        -- going. The node count per continent is small enough to simply try
        -- every pairing.
        local flightSpeed, flightMeasured = Travel.FlightSpeed()

        for _, origin in ipairs(nodes) do
            local originYards = Travel.YardsBetweenPoints(from, origin.point)

            if originYards then
                for _, arrival in ipairs(nodes) do
                    if arrival.id ~= origin.id then
                        local arrivalYards = Travel.YardsBetweenPoints(to, arrival.point)

                        local flightYards =
                            Travel.YardsBetweenPoints(origin.point, arrival.point)

                        if arrivalYards and flightYards then
                            local seconds = (originYards / runSpeed)
                                + Travel.flightOverheadSeconds
                                + (flightYards / flightSpeed)
                                + (arrivalYards / runSpeed)

                            if seconds < best.seconds then
                                best = {
                                    seconds     = seconds,
                                    mode        = "fly",
                                    yards       = direct,
                                    runToNode   = originYards,
                                    flightYards = flightYards,
                                    runFromNode = arrivalYards,
                                    node        = origin.name,
                                    arrival     = arrival.name,
                                }

                                -- A flight estimate is only as good as the
                                -- flight speed behind it.
                                confident = runMeasured and flightMeasured
                            end
                        end
                    end
                end
            end
        end
    end

    return best.seconds, confident, best
end

-- The same answer on the scale the scorer uses, where roughly ten is "across
-- a zone". Kept as a separate function so the scoring scale and the human
-- number never drift apart: one is derived from the other.
Travel.secondsPerCostPoint = 30
Travel.maximumCost         = 40

function Travel.CostFor(mapID, x, y)
    local playerMap, playerX, playerY = CN.GetPlayerPosition()

    if not playerMap or not mapID or not x or not y then
        return nil
    end

    local seconds = Travel.EstimateSeconds(playerMap, playerX, playerY, mapID, x, y)

    if not seconds then
        return nil
    end

    return math.min(Travel.maximumCost, seconds / Travel.secondsPerCostPoint)
end

-- Published so providers do not each have to decide what to do when the
-- estimate is unavailable. Falls back to what the addon did before this
-- module existed, which is a flat penalty for another zone.
CN.fallbackZoneCost = 25

function CN.TravelCost(mapID, x, y)
    local travel = CN:GetModule("Travel")

    local cost = travel and travel.CostFor(mapID, x, y)

    if cost then
        return cost, true
    end

    local playerMap = CN.GetPlayerPosition()

    if mapID and playerMap and mapID == playerMap then
        return CN.unknownLocationCost, false
    end

    if not mapID then
        return CN.unknownLocationCost, false
    end

    return CN.fallbackZoneCost, false
end

------------------------------------------------------------
-- FORMATTING
------------------------------------------------------------

-- Short "how long until it is usable" text. Minutes and seconds, because a
-- cooldown the player is waiting on is measured in the units they are
-- counting in.
function Travel.FormatReset(seconds)
    if not seconds or seconds <= 0 then
        return "ready"
    end

    if seconds < 60 then
        return math.floor(seconds) .. "s"
    end

    if seconds < 3600 then
        return math.floor(seconds / 60) .. "m"
    end

    return string.format("%.1fh", seconds / 3600)
end

function Travel.Describe(detail, seconds, confident)
    if not seconds then
        return CN.WithConfidence(nil, CN.confidence.UNKNOWN) .. " travel time"
    end

    local session = CN:GetModule("Session")

    local text = session and session.FormatDuration
        and session.FormatDuration(seconds)
        or (math.floor(seconds / 60) .. " min")

    if detail and detail.mode == "self" then
        text = text .. " |cff999999flying yourself|r"
    end

    if detail and detail.mode == "teleport" then
        text = text .. " |cff999999via " .. tostring(detail.via)

        if (detail.waited or 0) > 0 then
            text = text .. ", after a " .. Travel.FormatReset(detail.waited)
                .. " cooldown"
        end

        text = text .. "|r"
    end

    if detail and detail.mode == "fly" and detail.node then
        text = text .. " |cff999999via " .. tostring(detail.node)
        if detail.arrival then
            text = text .. " to " .. tostring(detail.arrival)
        end
        text = text .. "|r"
    end

    -- One convention, defined in Core, used by everything that prints a
    -- number it is not certain of.
    return CN.WithConfidence(text, CN.ConfidenceFor(confident))
end

------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

-- Discovering a flight point changes every cross-zone answer this module
-- gives, so the cache goes when it happens.
for _, event in ipairs({ "TAXIMAP_OPENED", "NEW_TAXI_NODE", "PLAYER_ENTERING_WORLD" }) do
    CN:RegisterEvent(event, function()
        Travel.ForgetNodes()

        CN.InvalidateCandidates()
    end)
end

-- Sampling the flight only while there is a flight to sample.
local ticker

Travel.tickSeconds = 1

CN:RegisterEvent("PLAYER_CONTROL_LOST", function()
    if ticker or not C_Timer or not C_Timer.NewTicker then
        return
    end

    ticker = C_Timer.NewTicker(Travel.tickSeconds, function()
        local flying = Travel.ObserveFlight()

        if not flying and ticker then
            ticker:Cancel()
            ticker = nil
        end
    end)
end)

------------------------------------------------------------
-- COMMAND
------------------------------------------------------------

CN:RegisterCommand{
    name    = "travel",
    order   = 26,
    help    = "How long it takes to reach the top recommendation, and how.",
    handler = function()
        local nodes, continent = Travel.KnownNodes(CN.GetPlayerPosition())

        local speed, measured = Travel.FlightSpeed()

        Print(string.format("Flight points known on this continent: %d", #nodes))
        Print(string.format("Flight speed: %.1f yards/second %s",
            speed, measured
                and ("|cff999999from " .. Travel.FlightSampleCount()
                    .. " of your own flights|r")
                or "|cff999999estimated -- take a flight path and it will be measured|r"))

        if not continent then
            Print("|cff999999The client will not say which continent this is.|r")
        end

        local results = CN.Recommend(1)

        local target = results and results[1]

        if not target or not target.mapID or not target.x then
            Print("|cff999999Nothing with a location is being recommended, so "
                .. "there is nothing to cost.|r")
            return
        end

        local playerMap, playerX, playerY = CN.GetPlayerPosition()

        local seconds, confident, detail = Travel.EstimateSeconds(
            playerMap, playerX, playerY, target.mapID, target.x, target.y)

        Print("To " .. tostring(target.name) .. ": "
            .. Travel.Describe(detail, seconds, confident))

        if detail and detail.mode == "fly" then
            local session = CN:GetModule("Session")

            local runSpeed = session and session.Speed() or 7

            Print(string.format(
                "  |cff999999%.0f yd to %s, %.0f yd in the air, %.0f yd at the "
                .. "far end -- against %.0f yd on foot|r",
                detail.runToNode, tostring(detail.node), detail.flightYards,
                detail.runFromNode, detail.yards))

            Print(string.format("  |cff999999running the whole way: %s|r",
                session and session.FormatDuration
                    and session.FormatDuration(detail.yards / math.max(0.5, runSpeed))
                    or "unknown"))
        elseif detail and detail.mode == "self" then
            local flySpeed, flyMeasured = Travel.SelfFlightSpeed()

            Print(string.format(
                "  |cff999999%.0f yd direct at %.0f yd/s%s|r",
                detail.yards, flySpeed,
                flyMeasured and "" or " |cff999999(estimated)|r"))
        elseif detail and detail.mode == "elsewhere" then
            Print("|cff999999That is on another continent. Portals and boats "
                .. "are not modelled, so no time is claimed -- but here is "
                .. "what you have:|r")

            local teleports = detail.teleports or {}

            if #teleports == 0 then
                Print("  |cff999999no hearthstone or teleport available|r")
            end

            for index, teleport in ipairs(teleports) do
                if index > 5 then
                    break
                end

                local line = "  " .. teleport.label

                if teleport.bound then
                    line = line .. " |cff999999to " .. teleport.bound .. "|r"
                end

                if teleport.ready then
                    line = line .. " |cff73b873ready|r"
                else
                    line = line .. " |cfff56b61"
                        .. Travel.FormatReset(teleport.remaining) .. "|r"
                end

                Print(line)
            end
        end
    end,
}

return Travel
