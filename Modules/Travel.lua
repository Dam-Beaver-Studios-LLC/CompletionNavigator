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
        -- Portals and boats exist and are not modelled. Saying nothing is
        -- correct; inventing a duration is not.
        return nil, false, { mode = "elsewhere" }
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

    local nodes = Travel.KnownNodes(toMapID) or {}

    if #nodes >= 2 then
        local origin, originYards  = Travel.NearestNode(from, nodes)
        local arrival, arrivalYards = Travel.NearestNode(to, nodes)

        if origin and arrival and origin.id ~= arrival.id then
            local flightYards = Travel.YardsBetweenPoints(origin.point, arrival.point)

            local flightSpeed, flightMeasured = Travel.FlightSpeed()

            if flightYards then
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

                    -- A flight estimate is only as good as the flight speed
                    -- behind it.
                    confident = confident and flightMeasured
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

function Travel.Describe(detail, seconds, confident)
    if not seconds then
        return "travel time unknown"
    end

    local session = CN:GetModule("Session")

    local text = session and session.FormatDuration
        and session.FormatDuration(seconds)
        or (math.floor(seconds / 60) .. " min")

    if detail and detail.mode == "fly" and detail.node then
        text = text .. " |cff999999via " .. tostring(detail.node)
        if detail.arrival then
            text = text .. " to " .. tostring(detail.arrival)
        end
        text = text .. "|r"
    end

    if not confident then
        text = text .. " |cff999999(estimated)|r"
    end

    return text
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
        elseif detail and detail.mode == "elsewhere" then
            Print("|cff999999That is on another continent, and this addon does "
                .. "not model portals -- so it will not guess.|r")
        end
    end,
}

return Travel
