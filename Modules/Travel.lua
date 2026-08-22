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

-- THE DISTANCE BETWEEN TWO FLIGHT POINTS DOES NOT CHANGE.
--
-- The pair search below tries every origin against every arrival, which is
-- the right search -- nearest-to-you and nearest-to-target are frequently not
-- the best route together. What was wrong was recomputing the flight leg of
-- every pair on every journey estimate.
--
-- It was invisible for the same reason the appearance-set scan was: the
-- fixture had three flight points in it. A levelled character has sixty on a
-- continent, and sixty squared is three and a half thousand distance
-- computations for one objective's travel cost. Measured with a realistic
-- fixture, a single estimate cost 1.5 ms and a cold rebuild 11.4.
--
-- Two nodes do not move relative to each other, so this is computed once per
-- continent and thrown away with the node list.
local spanCache = {}

function Travel.ForgetNodes()
    nodeCache = {}
    spanCache = {}
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

-- The flight leg of every pair, computed once. Indexed by position in the
-- node list rather than by node id, because the list is what the search
-- walks and an integer index costs nothing to look up.
local function Spans(continent, nodes)
    if spanCache[continent] then
        return spanCache[continent]
    end

    local spans = {}

    for i = 1, #nodes do
        spans[i] = {}

        for j = 1, #nodes do
            if i ~= j then
                spans[i][j] =
                    Travel.YardsBetweenPoints(nodes[i].point, nodes[j].point)
            end
        end
    end

    spanCache[continent] = spans

    return spans
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

local function RouteKey(fromID, toID)
    if not fromID or not toID then
        return nil
    end

    -- Undirected: a flight path that carries you one way is evidence the two
    -- points are on the same network, which is what the costing needs.
    if fromID > toID then
        fromID, toID = toID, fromID
    end

    return fromID .. ":" .. toID
end

Travel.RouteKey = RouteKey

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

        local spans = Spans(continent, nodes)

        local originSeconds, arrivalSeconds = {}, {}

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

        for i = 1, #nodes do
            local walkOut = originSeconds[i]

            -- Nothing beyond this point can be free, and nothing can be
            -- discounted further than a known route discounts it, so an
            -- origin whose best conceivable total already loses cannot win.
            if walkOut and cheapestArrival
                and (bestPossibleDiscount
                    * (walkOut + Travel.flightOverheadSeconds + cheapestArrival))
                    < bestRanking then

                local origin = nodes[i]
                local row    = spans[i]

                for j = 1, #nodes do
                    local flightYards = row and row[j]
                    local walkIn      = arrivalSeconds[j]

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
for _, event in ipairs({ "TAXIMAP_OPENED", "PLAYER_ENTERING_WORLD" }) do
    CN:RegisterEvent(event, function()
        Travel.ForgetNodes()

        CN.InvalidateCandidates()
    end)
end

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
