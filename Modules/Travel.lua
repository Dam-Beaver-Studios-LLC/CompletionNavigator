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

-- CLAMPED BEFORE PACKING.
--
-- The packing is exact for coordinates in [0, 1), which is where the client's
-- own APIs stay -- but a third-party data provider is not the client, and at
-- exactly 1.0 the coordinate term is a full 1,000,000 and collides with the
-- next map's origin. A negative coordinate floors downward and collides with
-- the previous map's far corner.
--
-- FILE SCOPE, because it was declared inside `CostFor` ABOVE the cache
-- lookup -- so every call allocated a closure, including the overwhelming
-- majority that were about to return a cached answer.
local function Packed(value)
    local scaled = math.floor((value or 0) * 1000)

    if scaled < 0 then
        return 0
    end

    if scaled > 999 then
        return 999
    end

    return scaled
end

-- Scratch buffers for the journey search below, reused across calls. See the
-- comment at their first use.
local scratchOrigin, scratchArrival, scratchOrder = {}, {}, {}

local scratchSort

local function OrderByOrigin(a, b)
    if scratchSort[a] == scratchSort[b] then
        return a < b
    end

    return scratchSort[a] < scratchSort[b]
end

-- The flight network, and the shortest way through it. See THE NETWORK below.
local neighbourCache = {}
local pathCache      = {}

function Travel.ForgetNodes()
    nodeCache      = {}
    neighbourCache = {}
    pathCache      = {}

    -- Every costed journey was costed through this network, so it goes too.
    if Travel.ForgetCosts then
        Travel.ForgetCosts()
    end
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

    -- AN EMPTY LIST IS NOT AN ANSWER, SO IT IS NOT REMEMBERED.
    --
    -- `C_TaxiMap.GetAllTaxiNodes` answers usefully only while the client has
    -- the taxi map's data to hand, and every node here needs
    -- `Travel.WorldPoint`, which refuses during a loading screen. The one
    -- event that clears this cache -- PLAYER_ENTERING_WORLD -- is a loading
    -- screen, so the very next query was the one most likely to get nothing.
    --
    -- Caching that nothing meant every flight-based estimate on the continent
    -- degraded to "run there" for the rest of the session. `Travel.WorldPoint`
    -- and `Navigation.MapScale` both already refuse to remember a miss, with
    -- comments saying why; this derived list did it anyway.
    if #usable > 0 then
        nodeCache[continent] = usable
    end

    return usable, continent
end

------------------------------------------------------------
-- THE NETWORK
------------------------------------------------------------

-- A FLIGHT IS NOT A STRAIGHT LINE, AND SOME JOURNEYS NEED TWO HOPS.
--
-- Until now the flight leg of a route was the straight-line distance between
-- the two flight points, which is the one distance a taxi never travels. The
-- network is a graph: the bird hops from master to master, and a pair at
-- opposite ends of a continent is reached by going through the ones in
-- between. Measuring the hypotenuse understated every long flight -- always
-- in the same direction, so the addon systematically recommended distant
-- objectives over near ones.
--
-- It also let the addon cost a pairing that does not connect at all. An
-- island node with no route to the mainland was quoted as a short flight
-- because the two points happen to be close together on the map.
--
-- The client does not publish the edge list -- `GetAllTaxiNodes` gives
-- positions and reachability, not who connects to whom -- so the edges are
-- inferred: a flight master connects to the ones near it, plus its nearest
-- few regardless of distance so that a sparse region is not cut off from the
-- rest of the continent. That is a model, and it is marked as one: a
-- multi-hop estimate is never reported as confident.
--
-- What it is not is a guess in the direction of optimism. Every path length
-- this produces is at least the straight line it replaces, so the estimate
-- moved from "certainly too short" to "approximately right".
Travel.hopYards = 4000

-- Plus the nearest few whatever the distance, so that a lone outpost still
-- joins the graph rather than becoming unreachable and silently dropping out
-- of every route.
Travel.minimumNeighbours = 4

-- No real continent has a flight chain anywhere near this long. It exists so
-- that a malformed graph cannot spin a loop.
Travel.maximumHops = 32

local function Neighbours(continent, nodes)
    if neighbourCache[continent] then
        return neighbourCache[continent]
    end

    -- BUILT WITHOUT SORTING EVERYTHING FIRST.
    --
    -- The original built, for every node, a table of ALL n-1 edges -- one
    -- freshly allocated row each -- sorted the whole thing, and then threw
    -- away everything past the threshold. On a sixty-node continent that is
    -- three and a half thousand allocations and sixty sorts to keep a few
    -- hundred edges, and it ran again after every loading screen. Measured at
    -- 4.9 ms, which was most of the cold graph cost.
    --
    -- What is actually needed is two things: every edge within `hopYards`,
    -- and the nearest `minimumNeighbours` whatever the distance. The first is
    -- one pass with no sort at all. The second is a fixed four-slot insertion,
    -- which is a sort of four elements rather than of fifty-nine.
    --
    -- `Spans` is gone with it: since the flight leg became a path rather than
    -- a straight line it was read exactly once per continent, here, and then
    -- retained for the session -- sixty tables and three and a half thousand
    -- numbers kept for nothing.
    local count = #nodes
    local out   = {}

    -- The shortest edge leaving each node, which is the cheapest any flight
    -- from it can possibly be. Used to tighten the search's pruning bound.
    local minOutgoing = {}

    local keep = Travel.minimumNeighbours

    for i = 1, count do
        local list = {}
        local held = {}

        -- The `keep` nearest, as a small insertion-sorted array.
        local nearIndex, nearYards = {}, {}
        local nearCount = 0

        local shortest

        for j = 1, count do
            if i ~= j then
                local yards = Travel.YardsBetweenPoints(
                    nodes[i].point, nodes[j].point)

                if yards then
                    if not shortest or yards < shortest then
                        shortest = yards
                    end

                    if yards <= Travel.hopYards then
                        held[j] = true

                        table.insert(list, { index = j, yards = yards })
                    else
                        -- Not close enough to connect on distance, so it is a
                        -- candidate for the nearest-few rule instead.
                        local slot = nearCount + 1

                        while slot > 1 and nearYards[slot - 1] > yards do
                            nearYards[slot] = nearYards[slot - 1]
                            nearIndex[slot] = nearIndex[slot - 1]
                            slot = slot - 1
                        end

                        if slot <= keep then
                            nearYards[slot] = yards
                            nearIndex[slot] = j

                            if nearCount < keep then
                                nearCount = nearCount + 1
                            end
                        end
                    end
                end
            end
        end

        -- Top up to `keep` edges from the nearest-few list, in order, without
        -- duplicating anything the distance rule already took.
        local taken = #list

        for slot = 1, nearCount do
            if taken >= keep then
                break
            end

            local j = nearIndex[slot]

            if j and not held[j] then
                held[j] = true
                taken   = taken + 1

                table.insert(list, { index = j, yards = nearYards[slot] })
            end
        end

        minOutgoing[i] = shortest
        out[i]         = list
        out[i].held    = held
    end

    -- AND THE GRAPH IS UNDIRECTED, BECAUSE FLIGHT PATHS ARE.
    --
    -- Built one node at a time, `minimumNeighbours` is a rule about who each
    -- node reaches OUT to, and that is not the same as who reaches it. A lone
    -- outpost picks its four nearest and every one of them is close enough to
    -- fill its own four from the crowd nearby -- so the outpost had a way out
    -- and no way in, and Dijkstra from anywhere on the mainland simply never
    -- reached it. It vanished from every route, silently, which is the exact
    -- failure `minimumNeighbours` was written to prevent.
    -- A membership set rather than a linear scan of the target's list: the
    -- scan made this O(V*E), which on a dense graph is cubic in nodes.
    for i = 1, count do
        for _, edge in ipairs(out[i]) do
            local back = out[edge.index]

            if not back.held[i] then
                back.held[i] = true

                table.insert(back, { index = i, yards = edge.yards })
            end
        end
    end

    out.minOutgoing = minOutgoing

    neighbourCache[continent] = out

    return out
end

-- Dijkstra from one flight point to every other, cached per origin.
--
-- Per origin rather than all-pairs: the search below prunes most origins
-- before it ever asks, and paying for a full Floyd-Warshall on sixty nodes at
-- the first estimate of a session would be a visible hitch for answers that
-- are mostly never needed. What is computed is kept, and thrown away with the
-- node list it was derived from.
local function ShortestFrom(continent, nodes, source)
    local cache = pathCache[continent]

    if not cache then
        cache = {}
        pathCache[continent] = cache
    end

    if cache[source] then
        return cache[source]
    end

    local neighbours = Neighbours(continent, nodes)
    local count      = #nodes
    local dist, prev, settled = {}, {}, {}

    dist[source] = 0

    for _ = 1, count do
        local pick, pickDist

        for index = 1, count do
            if not settled[index] and dist[index]
                and (not pickDist or dist[index] < pickDist) then

                pick, pickDist = index, dist[index]
            end
        end

        if not pick then
            -- Everything reachable has been settled. What is left is a
            -- separate component, and stays unreachable -- which is the
            -- honest answer for it.
            break
        end

        settled[pick] = true

        for _, edge in ipairs(neighbours[pick] or {}) do
            local through = pickDist + edge.yards

            if not dist[edge.index] or through < dist[edge.index] then
                dist[edge.index] = through
                prev[edge.index] = pick
            end
        end
    end

    local result = { dist = dist, prev = prev }

    cache[source] = result

    return result
end

-- The hops themselves, so `/cn travel` can print the chain rather than a
-- single number the player cannot check.
function Travel.LegsBetween(nodes, path, source, target)
    if not path or not path.dist or not path.dist[target] then
        return nil
    end

    local chain, at, guard = {}, target, 0

    while at and guard <= Travel.maximumHops do
        table.insert(chain, 1, at)

        if at == source then
            break
        end

        at    = path.prev[at]
        guard = guard + 1
    end

    if chain[1] ~= source then
        return nil
    end

    local legs = {}

    for step = 1, #chain - 1 do
        local a, b = chain[step], chain[step + 1]

        table.insert(legs, {
            from  = nodes[a] and nodes[a].name,
            to    = nodes[b] and nodes[b].name,
            yards = (path.dist[b] or 0) - (path.dist[a] or 0),
        })
    end

    return legs
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
-- WHICH FLIGHTS ACTUALLY CONNECT
------------------------------------------------------------

-- THE ASSUMPTION THIS REPLACES.
--
-- The costing has assumed since 0.42.0 that any flight point on a continent
-- can reach any other. Mostly true, and wrong often enough to matter: routes
-- go through hubs, some connect only one way, and a few zones are served by a
-- single node that reaches almost nothing.
--
-- There is no API that answers "does A connect to B". There is, however, the
-- player, who takes flights -- and a flight taken is proof that its two ends
-- connect. So: watch, remember, and prefer a pair that is known to work over
-- one that is merely plausible.
--
-- Nothing is ever ruled OUT by this. A pair never observed is not a pair that
-- does not connect; it is a pair nobody has flown yet, and treating those as
-- impossible would make the model worse than the assumption it replaces.
local function Routes()
    return CN.Account("flightRoutes")
end

Travel.Routes = Routes

-- NUMERIC, NOT A STRING.
--
-- `IsKnownRoute` is asked once per surviving pair inside the search, which on
-- a real continent is a thousand times per estimate -- so this built a
-- thousand strings, each of them two coercions and a concatenation, to look
-- up a table with a few dozen rows in it.
--
-- Node ids are integers well under the multiplier, so packing them into one
-- number is exact and costs nothing. The stored keys change shape, so
-- migration 8 rewrites them; `Travel.UnpackRouteKey` reads one back.
Travel.routeKeyStride = 1000000

local function RouteKey(fromID, toID)
    if not fromID or not toID then
        return nil
    end

    -- Undirected: a flight path that carries you one way is evidence the two
    -- points are on the same network, which is what the costing needs.
    if fromID > toID then
        fromID, toID = toID, fromID
    end

    return (fromID * Travel.routeKeyStride) + toID
end

Travel.RouteKey = RouteKey

-- The two node ids back out of a packed key, for anything that has to read
-- the store rather than write it -- `/cn dbsize`, a future export, and the
-- migration's own verification. Returns nil for anything that is not one of
-- our keys rather than inventing a pair out of arithmetic.
function Travel.UnpackRouteKey(key)
    if type(key) ~= "number" or key < 0 or key ~= math.floor(key) then
        return nil
    end

    local stride = Travel.routeKeyStride

    local fromID = math.floor(key / stride)
    local toID   = key - (fromID * stride)

    if fromID <= 0 or toID <= 0 then
        return nil
    end

    return fromID, toID
end

function Travel.NoteRoute(fromID, toID)
    local key = RouteKey(fromID, toID)

    if not key then
        return false
    end

    local routes = Routes()

    routes[key] = (routes[key] or 0) + 1

    return true
end

function Travel.IsKnownRoute(fromID, toID)
    local key = RouteKey(fromID, toID)

    return key ~= nil and (Routes()[key] or 0) > 0
end

-- How much a known pair is preferred. A multiplier on the estimate rather
-- than a hard filter, because an unobserved pair is unproven, not impossible
-- -- and a small preference is enough to break a tie between two routes of
-- similar length.
Travel.knownRouteBonus = 0.9

-- The flight the player is currently on, so its endpoints can be recorded
-- when it ends. Which node they left from is known at the moment they board:
-- it is the nearest one to where they were standing.
local boarding = nil

function Travel.NoteBoarding()
    local mapID, x, y = CN.GetPlayerPosition()

    local point = mapID and Travel.WorldPoint(mapID, x, y)

    local node = point and Travel.NearestNode(point, Travel.KnownNodes(mapID))

    boarding = node and node.id or nil

    return boarding
end

function Travel.NoteLanding()
    if not boarding then
        return false
    end

    local mapID, x, y = CN.GetPlayerPosition()

    local point = mapID and Travel.WorldPoint(mapID, x, y)

    local node = point and Travel.NearestNode(point, Travel.KnownNodes(mapID))

    local landed = node and node.id

    local recorded = false

    if landed and landed ~= boarding then
        recorded = Travel.NoteRoute(boarding, landed)

        DebugPrint("Flight recorded: " .. boarding .. " to " .. landed .. ".")
    end

    boarding = nil

    return recorded
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
-- WHERE EACH ONE PUTS YOU DOWN.
--
-- A cross-continent journey can only be costed through a teleport whose
-- destination is known, and eight of these fourteen carried no destination at
-- all -- including the hearthstone, which is the one every player has. So a
-- non-mage asking about another continent got a list of what they own and no
-- duration whatsoever, which is the state this whole branch was built to
-- replace.
--
-- Three of them genuinely cannot be pinned, and are marked rather than given
-- a plausible-looking false landing:
--
--   * The hearthstone and Astral Recall go wherever the player set them. The
--     client reports that as a zone NAME, and this addon has no name-to-map
--     index -- building one means walking the whole map tree, which is a
--     client call per zone for a fact that is worth less than its cost. They
--     are still listed as available; they are not costed.
--   * The Flight Master's Whistle lands at the nearest flight point in the
--     zone you are already standing in. It is not a cross-continent option at
--     all.
--
-- The other eleven are fixed locations and are simply written down. Five of
-- them had no destination for no better reason than that nobody had filled
-- it in, which is why a non-mage got no cross-continent number at all.
Travel.teleports = {
    { kind = "item",  id = 6948,   label = "Hearthstone", bindPoint = true },

    { kind = "item",  id = 110560, label = "Garrison Hearthstone",
      -- Two garrisons, one per faction, and the client will not say which
      -- without reading the player's own garrison data. Draenor is the
      -- continent either way, which is what a cross-continent estimate needs.
      mapID = 590 },

    { kind = "item",  id = 140192, label = "Dalaran Hearthstone", mapID = 627 },

    -- Not a destination: it lands you at the nearest flight point in the zone
    -- you are already in.
    { kind = "item",  id = 141605, label = "Flight Master's Whistle",
      local_ = true },

    { kind = "spell", id = 556,    label = "Astral Recall", bindPoint = true },
    { kind = "spell", id = 3565,   label = "Teleport: Darnassus",     mapID = 89 },
    { kind = "spell", id = 3562,   label = "Teleport: Ironforge",     mapID = 87 },
    { kind = "spell", id = 3561,   label = "Teleport: Stormwind",     mapID = 84 },
    { kind = "spell", id = 3567,   label = "Teleport: Orgrimmar",     mapID = 85 },
    { kind = "spell", id = 3563,   label = "Teleport: Undercity",     mapID = 90 },
    { kind = "spell", id = 3566,   label = "Teleport: Thunder Bluff", mapID = 88 },
    { kind = "spell", id = 18960,  label = "Teleport: Moonglade",     mapID = 80 },
    { kind = "spell", id = 50977,  label = "Death Gate",              mapID = 118 },
    { kind = "spell", id = 126892, label = "Zen Pilgrimage",          mapID = 809 },
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

    -- THE SPEED OF RUNNING, NOT THE SPEED YOU HAPPEN TO BE MOVING.
    --
    -- `Speed()` with no argument answers for the bucket the player is in
    -- RIGHT NOW -- so asking it while airborne returned the skyriding median
    -- and used it to divide the "run the whole way" option and both walking
    -- legs of every flight-path route. A twenty-one thousand yard journey was
    -- quoted at six minutes, labelled `run`, and marked confident. The true
    -- figure on foot is fifty.
    --
    -- It also made the self-flown option unreachable while flying: dividing
    -- the same distance by the same number and then adding six seconds of
    -- takeoff can never win, so the mode this addon built a whole travel
    -- model around never appeared in the situation it was written for.
    --
    -- The ground speed is asked for by name. Which bucket the player is
    -- standing in is not a fact about how long it takes to walk somewhere.
    local runSpeed, runMeasured = 7, false

    if session and session.Speed then
        runSpeed, runMeasured = session.Speed(false)
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

    -- What the comparison uses, which is the duration for everything except a
    -- flight pair the player has flown before -- see the tie-break below.
    local bestRanking = best.seconds

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

        if seconds < bestRanking then
            bestRanking = seconds

            best = {
                seconds = seconds,
                mode    = "self",
                yards   = direct,
            }

            confident = flyMeasured
        end
    end

    local nodes, continent = Travel.KnownNodes(toMapID)

    nodes = nodes or {}

    if #nodes >= 2 then
        -- THE BEST PAIR, NOT THE NEAREST AT EACH END.
        --
        -- Nearest-to-you and nearest-to-target are two independently sensible
        -- choices that together are often not the best route: a flight point
        -- slightly further from you can sit much closer to where you are
        -- going. The node count per continent is small enough to simply try
        -- every pairing, and that is still true -- what was not true was
        -- doing three distance computations inside each pairing.
        --
        -- REWRITTEN IN 0.46.0 with the same answers and a twentieth of the
        -- work. The two ends are each measured once per node instead of once
        -- per pair, the flight leg comes from a table computed once per
        -- continent, and the inner loop is arithmetic on numbers already in
        -- hand.
        local flightSpeed, flightMeasured = Travel.FlightSpeed()

        -- SCRATCH, NOT FRESH.
        --
        -- Three arrays of one entry per flight node -- fifty-nine on a real
        -- continent -- allocated on every call, and this is called once per
        -- located candidate per rebuild and on every costing cache miss.
        -- Measured at 8.3 KB per call. The cross-continent branch returns
        -- well above here, so the recursive teleport call cannot re-enter
        -- this block and reusing the buffers is safe.
        local originSeconds, arrivalSeconds = scratchOrigin, scratchArrival

        for index = #originSeconds, 1, -1 do
            originSeconds[index] = nil
        end

        for index = #arrivalSeconds, 1, -1 do
            arrivalSeconds[index] = nil
        end

        -- The cheapest either end can possibly be. Used to abandon an origin
        -- whose walk alone already costs more than the best route found so
        -- far.
        local cheapestArrival

        -- AND THE MOST THE REST OF THE SUM CAN BE DISCOUNTED.
        --
        -- 0.46.0 wrote this bound and called it exact "because every remaining
        -- term of the sum is positive". Every term is -- but the sum is then
        -- MULTIPLIED by knownRouteBonus when the pair is a route the player
        -- has actually flown, and a discount is not a term. A bound that
        -- ignores it prunes origins whose true cost is up to a tenth below
        -- what the bound predicted, and the addon silently reports the
        -- second-best route.
        --
        -- The test that was supposed to catch this brute-forced the answer
        -- honestly and still missed it: no routes had been noted at that point
        -- in the run, so the discount branch was never live while the
        -- comparison ran. It would have bitten only players who had flown
        -- somewhere -- which is all of them, and none of the fixtures.
        local bestPossibleDiscount = math.min(1, Travel.knownRouteBonus or 1)

        for index, node in ipairs(nodes) do
            local originYards = Travel.YardsBetweenPoints(from, node.point)
            local arrivalYards = Travel.YardsBetweenPoints(to, node.point)

            originSeconds[index]  = originYards and (originYards / runSpeed)
            arrivalSeconds[index] = arrivalYards and (arrivalYards / runSpeed)

            if arrivalSeconds[index]
                and (not cheapestArrival or arrivalSeconds[index] < cheapestArrival) then

                cheapestArrival = arrivalSeconds[index]
            end
        end

        -- ORIGINS IN THE ORDER THAT MAKES THE BOUND BITE.
        --
        -- The loop used to walk the node list in whatever order the client
        -- returned it, so `bestRanking` might not improve until late and the
        -- bound could not reject anything before it did. Walked nearest-first,
        -- the best route is usually found in the first few origins and every
        -- one after it fails the bound -- and because the bound rises
        -- monotonically with `walkOut`, the first failure means every
        -- remaining origin fails too. A filter becomes an early exit.
        local order = scratchOrder

        for index = #order, 1, -1 do
            order[index] = nil
        end

        for index = 1, #nodes do
            if originSeconds[index] then
                order[#order + 1] = index
            end
        end

        -- The comparator reads the scratch array through an upvalue rather
        -- than being rebuilt as a closure on every call.
        scratchSort = originSeconds

        table.sort(order, OrderByOrigin)

        -- The cheapest any flight out of a given node can be. Built with the
        -- graph, and it tightens the bound in exactly the place the bound was
        -- weakest: since 0.53.0 the flight leg is a path rather than a
        -- straight line, so assuming the flight is free -- which is what the
        -- bound did -- became a much larger lie.
        local minOutgoing = Neighbours(continent, nodes).minOutgoing or {}

        for _, i in ipairs(order) do
            local walkOut = originSeconds[i]

            -- Nothing beyond this point can be free, no flight out of here is
            -- shorter than the shortest edge leaving it, and nothing can be
            -- discounted further than a known route discounts it -- so an
            -- origin whose best conceivable total already loses cannot win.
            local floor = walkOut + Travel.flightOverheadSeconds
                + ((minOutgoing[i] or 0) / flightSpeed)
                + (cheapestArrival or 0)

            if not cheapestArrival
                or (bestPossibleDiscount * floor) >= bestRanking then

                -- Sorted by `walkOut`, so every remaining origin has a floor
                -- at least this high.
                break
            end

            do
                local origin = nodes[i]

                -- THE WAY THE BIRD ACTUALLY GOES.
                --
                -- `spans` is still what the graph is built from, but the
                -- flight leg is now the shortest path through that graph
                -- rather than the straight line across it. A pair with no
                -- path between them has no entry and is not offered.
                local path = ShortestFrom(continent, nodes, i)

                for j = 1, #nodes do
                    local flightYards = (i ~= j) and path.dist[j] or nil
                    local walkIn      = arrivalSeconds[j]

                    -- The same argument, one level down: an arrival whose two
                    -- walks alone already lose cannot be rescued by a flight,
                    -- which is never negative. There was no bound on the
                    -- inner loop at all.
                    if walkIn
                        and (bestPossibleDiscount
                            * (walkOut + Travel.flightOverheadSeconds + walkIn))
                            >= bestRanking then

                        flightYards = nil
                    end

                    if flightYards and walkIn then
                        local seconds = walkOut
                            + Travel.flightOverheadSeconds
                            + (flightYards / flightSpeed)
                            + walkIn

                        -- A pair the player has actually flown beats an
                        -- equivalent pair nobody has: same distance, one
                        -- of them proven to connect.
                        --
                        -- A TIE-BREAK, NOT A DISCOUNT. This used to multiply
                        -- `seconds` itself, so the duration reported to the
                        -- player was ten percent below the model's own
                        -- arithmetic -- `/cn travel` printed legs that summed
                        -- to fifty seconds more than its own headline -- and
                        -- that shortened number flowed into scoring and into
                        -- `/cn plan`'s budget. Every player has flown
                        -- somewhere, so this was the common case, not an
                        -- edge one.
                        --
                        -- The preference belongs in the comparison. The
                        -- seconds are the seconds.
                        local ranking = seconds

                        if Travel.IsKnownRoute(origin.id, nodes[j].id) then
                            ranking = ranking * Travel.knownRouteBonus
                        end

                        if ranking < bestRanking then
                            bestRanking = ranking

                            best = {
                                seconds     = seconds,
                                mode        = "fly",
                                yards       = direct,
                                runToNode   = walkOut * runSpeed,
                                flightYards = flightYards,
                                runFromNode = walkIn * runSpeed,
                                node        = origin.name,
                                arrival     = nodes[j].name,

                                -- The ids as well as the names, added in
                                -- 0.46.0: a name is what a player reads, and
                                -- an id is what anything downstream needs to
                                -- ask a further question about the route.
                                nodeID      = origin.id,
                                arrivalID   = nodes[j].id,

                                -- The chain itself. One entry means the
                                -- ordinary direct hop; more means the route
                                -- goes through flight masters in between,
                                -- and the player is told which.
                                legs        = Travel.LegsBetween(
                                                  nodes, path, i, j),
                            }

                            best.hops = best.legs and #best.legs or 1

                            -- A flight estimate is only as good as the
                            -- flight speed behind it -- and a multi-hop
                            -- route rests on an inferred edge list as well,
                            -- which is a model and not a measurement.
                            confident = runMeasured and flightMeasured
                                and best.hops <= 1
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

-- Published, because Session has to remove from a measured duration exactly
-- what the planner will add back to it. One constant, one conversion.
CN.secondsPerCostPoint = Travel.secondsPerCostPoint
Travel.maximumCost         = 40

-- MEMOISED, BECAUSE EVERY LOCATED CANDIDATE PAYS THIS.
--
-- One estimate costs about two tenths of a millisecond against a real flight
-- network, and a rebuild asks for one per located objective -- a full quest
-- log plus rares, treasures and located vendor recipes is forty to eighty of
-- them. That is most of the rebuild, and it was recomputed from scratch every
-- time even though a rebuild answers the same question about the same
-- destinations from the same place.
--
-- Keyed on the destination rounded to about a yard, and on where the player
-- is standing rounded rather more coarsely -- the answer does not change
-- meaningfully for a few paces, and re-keying on every step would defeat the
-- cache in exactly the situation it is for.
--
-- Numeric key, not a string: `Travel.WorldPoint`'s string key is built two
-- concatenations and two coercions at a time, and this runs far more often.
Travel.costCacheCap = 512

-- How far the player has to move before the cached costs stop being about
-- where they are. Twenty yards is under two seconds of running and well
-- inside the noise of a model whose smallest unit is thirty seconds.
Travel.costCacheYards = 20

local costCache, costCacheCount = {}, 0
local costCacheMap, costCacheX, costCacheY

function Travel.ForgetCosts()
    costCache, costCacheCount = {}, 0
    costCacheMap, costCacheX, costCacheY = nil, nil, nil
end

function Travel.CostCacheSize()
    return costCacheCount
end

function Travel.CostFor(mapID, x, y)
    local playerMap, playerX, playerY = CN.GetPlayerPosition()

    if not playerMap or not mapID or not x or not y then
        return nil
    end

    -- THE PLAYER'S OWN POSITION HAS TO BE KNOWN, TOO.
    --
    -- The guard checked the DESTINATION's coordinates and not the player's,
    -- and `CN.GetPlayerPosition` routinely answers `mapID, nil, nil` for a
    -- moment after a loading screen. So the cache was stamped with a nil
    -- origin, every estimate failed, and the failures were remembered.
    if not playerX or not playerY then
        return nil
    end

    -- Has the player moved far enough for the answers to be about somewhere
    -- else? A different map always counts; on the same map, compare in yards.
    local moved = costCacheMap ~= playerMap

    if not moved and not costCacheX then
        -- No origin was recorded, so nothing in the cache is about anywhere
        -- in particular. Fail open: a cache whose premise is unknown is a
        -- cache that has to be rebuilt.
        moved = true
    elseif not moved then
        local yards = Travel.YardsBetween(playerMap, costCacheX, costCacheY,
            playerMap, playerX, playerY)

        moved = (yards == nil) or (yards > Travel.costCacheYards)
    end

    if moved then
        costCache, costCacheCount = {}, 0
        costCacheMap = playerMap
        costCacheX, costCacheY = playerX, playerY
    end

    local key = (mapID * 1000000) + (Packed(x) * 1000) + Packed(y)

    local held = costCache[key]

    if held ~= nil then
        if held == false then
            return nil
        end

        return held
    end

    local seconds = Travel.EstimateSeconds(playerMap, playerX, playerY, mapID, x, y)

    if costCacheCount >= Travel.costCacheCap then
        costCache, costCacheCount = {}, 0
    end

    if not seconds then
        -- NOT REMEMBERED.
        --
        -- 0.54.0 cached the refusal, reasoning that re-deriving the same nil
        -- is the most expensive way to learn nothing. That was wrong for the
        -- same reason `Travel.WorldPoint` fourteen hundred lines above
        -- refuses to cache ITS miss, in a comment that says so plainly: a
        -- failure here is almost never a property of the destination, it is a
        -- property of the moment. The client refuses every coordinate
        -- conversion for a window after a loading screen, and remembering
        -- that made the whole ranking travel-blind for the rest of the
        -- session -- at exactly the moment a player is most likely to be
        -- looking at it.
        --
        -- Re-deriving a nil costs one failed estimate. Remembering it cost
        -- the feature.
        return nil
    end

    local cost = math.min(Travel.maximumCost,
        seconds / Travel.secondsPerCostPoint)

    costCache[key]  = cost
    costCacheCount  = costCacheCount + 1

    return cost
end

-- Published so providers do not each have to decide what to do when the
-- estimate is unavailable.
--
-- IT MUST NOT BE CHEAPER THAN A JOURNEY WE CAN ACTUALLY COST.
--
-- This was 25 while a costed journey saturates at `maximumCost = 40`, so
-- "I cannot work out how to get there" scored fifteen points BELOW the far
-- side of the zone the player is standing in -- and fifteen is nearly twice
-- the entire range of what finishing something is worth. Another continent,
-- unreachable and unmodelled, outranked a quest two minutes away.
--
-- An uncostable journey is the one we know least about; it has to be the
-- pessimistic answer, not the optimistic one.
CN.fallbackZoneCost = 40

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
        or (math.floor(seconds / 60) .. "m")

    if detail and detail.mode == "self" then
        text = text .. " |cff8a8f96flying yourself|r"
    end

    if detail and detail.mode == "teleport" then
        text = text .. " |cff8a8f96via " .. tostring(detail.via)

        if (detail.waited or 0) > 0 then
            text = text .. ", after a " .. Travel.FormatReset(detail.waited)
                .. " cooldown"
        end

        text = text .. "|r"
    end

    if detail and detail.mode == "fly" and detail.node then
        text = text .. " |cff8a8f96via " .. tostring(detail.node)
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
--
-- `NEW_TAXI_NODE` was in this list and is not an event. The client refuses to
-- register an unknown name -- it throws -- so every login since this line was
-- written produced a Lua error, and the two events either side of it were
-- registered anyway only because they come before and after in the loop. It
-- was invented, plausibly, and nothing ever checked.
--
-- There is no discovery event. TAXIMAP_OPENED is the honest substitute: you
-- discover a flight point by talking to the flight master, which opens the
-- map.
-- ONLY TAXIMAP_OPENED THROWS THE NETWORK AWAY.
--
-- `PLAYER_ENTERING_WORLD` was in this list, and it fires on every zone
-- transition through a loading screen, every instance, every portal, every
-- hearth and every reload -- so the first rebuild after any of those paid for
-- the whole flight graph again. Measured at about ten milliseconds, on top of
-- a provider rebuild, at precisely the moment the client is busiest.
--
-- And it bought nothing: flight points cannot appear during a loading screen.
-- The only thing that adds one is talking to a flight master, which opens the
-- taxi map. `Travel.KnownNodes` already refuses to remember an empty list, so
-- the "client was not ready yet" case that the event was covering is handled
-- where it belongs.
CN:RegisterEvent("TAXIMAP_OPENED", function()
    Travel.ForgetNodes()

    CN.InvalidateCandidates()
end)

-- A loading screen still moves the player, though, so the costed journeys
-- are about somewhere else now. Those are cheap to rebuild and the network
-- they were derived from is not.
CN:RegisterEvent("PLAYER_ENTERING_WORLD", function()
    Travel.ForgetCosts()

    CN.InvalidateCandidates()
end)

-- WHERE THE FLYABILITY MEMORY IS ACTUALLY WRITTEN.
--
-- `Travel.NoteFlyable` was written in 0.43.0 with a block comment explaining
-- that remembering the answer per zone "turns that guess into evidence", and
-- then nothing ever called it. The store stayed empty for four releases, so
-- `Travel.CanFly` always fell through to `IsFlyableArea()` -- which answers
-- for where the player is STANDING -- and that is precisely the guess the
-- comment claims was replaced. Every self-flown route estimate to another
-- zone rested on it.
--
-- The test suite could not see it because the harness wrote the store
-- directly, bypassing the producer: populated in test, permanently empty in
-- game.
--
-- Observed on arrival, which is the only moment the client will answer
-- honestly about a zone.
local function NoteWhereWeAre()
    local mapID = CN.GetPlayerPosition()

    if mapID then
        pcall(Travel.NoteFlyable, mapID)
    end
end

for _, event in ipairs({ "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD" }) do
    CN:RegisterEvent(event, NoteWhereWeAre)
end

-- And whenever the player is demonstrably flying, which is evidence that
-- outranks anything the client says about the area: you cannot be flying
-- somewhere flight is disabled.
CN:RegisterEvent("PLAYER_CONTROL_GAINED", function()
    if IsFlying and select(1, pcall(IsFlying)) then
        local flying = select(2, pcall(IsFlying))

        if flying then
            local mapID = CN.GetPlayerPosition()

            if mapID then
                FlightMemory()[mapID] = true
            end
        end
    end
end)

-- Sampling the flight only while there is a flight to sample.
local ticker

Travel.tickSeconds = 1

CN:RegisterEvent("PLAYER_CONTROL_LOST", function()
    -- Losing control is the moment a flight starts. Record where from.
    pcall(Travel.NoteBoarding)

    if ticker or not C_Timer or not C_Timer.NewTicker then
        return
    end

    ticker = C_Timer.NewTicker(Travel.tickSeconds, function()
        local flying = Travel.ObserveFlight()

        if not flying and ticker then
            -- The flight has ended: record which two points it joined.
            pcall(Travel.NoteLanding)

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
                and ("|cff8a8f96from " .. Travel.FlightSampleCount()
                    .. " of your own flights|r")
                or (CN.WithConfidence("", CN.confidence.ESTIMATED)
                    .. " |cff8a8f96-- take a flight path and it will be "
                    .. "measured|r")))

        if not continent then
            Print("|cff8a8f96The client will not say which continent this is.|r")
        end

        local results = CN.Recommend(1)

        local target = results and results[1]

        if not target or not target.mapID or not target.x then
            Print("|cff8a8f96Nothing with a location is being recommended, so "
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
                "  |cff8a8f96%.0f yd to %s, %.0f yd in the air, %.0f yd at the "
                .. "far end -- against %.0f yd on foot|r",
                detail.runToNode, tostring(detail.node), detail.flightYards,
                detail.runFromNode, detail.yards))

            -- THE CHAIN, NOT JUST ITS ENDS.
            --
            -- A two-hop route printed as a single "in the air" figure looks
            -- like a straight line the player can check against the map and
            -- find wrong. Printed as its legs it is checkable, which is the
            -- point of the whole breakdown.
            local legs = detail.legs or {}

            if #legs > 1 then
                Print(string.format("  |cff8a8f96%d legs:|r", #legs))

                for index, leg in ipairs(legs) do
                    Print(string.format("    |cff8a8f96%d. %s to %s, %.0f yd|r",
                        index, tostring(leg.from), tostring(leg.to),
                        leg.yards or 0))
                end
            end

            Print(string.format("  |cff8a8f96running the whole way: %s|r",
                session and session.FormatDuration
                    and session.FormatDuration(detail.yards / math.max(0.5, runSpeed))
                    or "unknown"))
        elseif detail and detail.mode == "self" then
            local flySpeed, flyMeasured = Travel.SelfFlightSpeed()

            Print(string.format(
                "  |cff8a8f96%.0f yd direct at %.0f yd/s%s|r",
                detail.yards, flySpeed,
                flyMeasured and ""
                    or (" " .. CN.WithConfidence("",
                        CN.confidence.ESTIMATED))))
        elseif detail and detail.mode == "elsewhere" then
            Print("|cff8a8f96That is on another continent. Portals and boats "
                .. "are not modelled, so no time is claimed -- but here is "
                .. "what you have:|r")

            local teleports = detail.teleports or {}

            if #teleports == 0 then
                Print("  |cff8a8f96no hearthstone or teleport available|r")
            end

            for index, teleport in ipairs(teleports) do
                if index > 5 then
                    break
                end

                local line = "  " .. teleport.label

                if teleport.bound then
                    line = line .. " |cff8a8f96to " .. teleport.bound .. "|r"
                end

                if teleport.ready then
                    line = line .. " |cff73b873ready|r"
                else
                    line = line .. " |cffe2564c"
                        .. Travel.FormatReset(teleport.remaining) .. "|r"
                end

                Print(line)
            end
        end
    end,
}

return Travel
