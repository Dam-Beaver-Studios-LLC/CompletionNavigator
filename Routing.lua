-- Routing.lua
-- Completion Navigator :: waypoint creation and zone clustering.
--
-- Navigation is delegated to a provider. Native navigation is preferred and
-- needs nothing installed; TomTom and Blizzard map pins remain available and
-- a player can insist on either with /cn nav. This file only decides WHERE to
-- point.

local ADDON_NAME, CN = ...

------------------------------------------------------------
-- PROVIDER REGISTRY
------------------------------------------------------------

CN.waypointProviders = CN.waypointProviders or {}
CN.waypointOrder     = CN.waypointOrder or {}

-- provider = {
--     IsAvailable = function() return boolean end,
--     SetWaypoint = function(mapID, x, y, title) end,
--     ClearAll    = function() end,
-- }
function CN.RegisterWaypointProvider(name, provider, priority)
    CN.waypointProviders[name] = provider

    table.insert(CN.waypointOrder, { name = name, priority = priority or 100 })

    table.sort(CN.waypointOrder, function(a, b)
        return a.priority < b.priority
    end)
end

function CN.GetWaypointProvider()
    -- An explicit choice beats the priority order. Someone who runs TomTom and
    -- prefers its arrow said so on purpose, and "whichever addon happens to be
    -- loaded" is not a preference.
    if CN.GetPreferredWaypointProvider then
        local preferred, preferredName = CN.GetPreferredWaypointProvider()

        if preferred then
            return preferred, preferredName
        end
    end

    for _, entry in ipairs(CN.waypointOrder) do
        local provider = CN.waypointProviders[entry.name]

        if provider and provider.IsAvailable and provider.IsAvailable() then
            return provider, entry.name
        end
    end

    return nil, nil
end

------------------------------------------------------------
-- WAYPOINTS
------------------------------------------------------------

function CN.SetWaypoint(mapID, x, y, title)
    if not mapID or not x or not y then
        CN.Print("No coordinates are known for that objective.")
        return false
    end

    local provider, name = CN.GetWaypointProvider()

    if not provider then
        -- Native navigation needs only the map API, so reaching this means
        -- something is badly wrong rather than merely uninstalled.
        CN.Print("No waypoint provider is available.")
        CN.Print("|cff8a8f96Try |cffffc74f/cn nav auto|r to reset the choice.|r")
        return false
    end

    -- THE ANSWER IS THE PROVIDER'S, NOT THIS FUNCTION'S.
    --
    -- This called the provider, discarded whatever came back, and returned
    -- `true`. `CN.NavigateToObjective` then printed "Waypoint set: <name>" --
    -- on a map the client refuses waypoints on, with TomTom absent, with a
    -- map point the client would not build. Every one of those printed a
    -- success and produced nothing.
    local placed, why = provider.SetWaypoint(mapID, x, y, title)

    if not placed then
        CN.Print("A waypoint could not be set"
            .. (why and (": " .. why) or " here") .. ".")

        return false
    end

    CN.DebugPrint("Waypoint set via " .. tostring(name) .. ".")

    return true
end

-- The single entry point for "take me there", used by /cn go, the Navigate
-- button, the zone list, and the minimap button.
--
-- Order of preference:
--   1. Real coordinates -> a waypoint in TomTom or a Blizzard map pin.
--   2. An active quest with no coordinates -> hand it to Blizzard's own
--      quest tracking arrow, which knows where its own quests are.
--   3. Nothing -> say so plainly and explain why.
function CN.NavigateToObjective(objective)
    if type(objective) ~= "table" then
        CN.Print("Nothing to navigate to.")
        return false
    end

    local name = tostring(objective.name or objective.id or "that objective")

    if objective.mapID and objective.x and objective.y then
        if CN.SetWaypoint(objective.mapID, objective.x, objective.y, name) then
            CN.Print("Waypoint set: " .. name)
            return true
        end

        return false
    end

    -- Re-resolve: coordinates often appear once the player is on the right
    -- map, and the objective may have been built somewhere else.
    if objective.type == CN.objectiveTypes.QUEST and objective.id then
        local quests = CN:GetModule("Quests")

        if quests then
            local mapID, x, y = quests.GetLocation(objective.id)

            if mapID and x and y then
                objective.mapID, objective.x, objective.y = mapID, x, y

                if CN.SetWaypoint(mapID, x, y, name) then
                    CN.Print("Waypoint set: " .. name)
                    return true
                end

                return false
            end
        end

        if CN.Blizzard.IsQuestInLog(objective.id)
            and CN.Blizzard.SuperTrackQuest(objective.id) then

            CN.Print("No map coordinates for " .. name
                .. "; using Blizzard's quest tracking arrow instead.")

            return true
        end

        CN.Print("No coordinates are known for " .. name .. ".")
        CN.PrintLine(CN.Muted("The client exposes none for this quest and it "
            .. "is not in your log. Add them with ")
            .. CN.Accent("/cn setloc " .. tostring(objective.id)
                .. " <mapID> <x> <y>")
            .. CN.Muted(" " .. CN.DASH .. " ") .. CN.Accent("/cn where am i")
            .. CN.Muted(" prints the map id."))

        return false
    end

    CN.Print("No coordinates are known for " .. name .. ".")

    if objective.type == CN.objectiveTypes.REPUTATION then
        CN.Print("Reputations have no single location.")
    end

    return false
end

-- Returns whether anything was actually removed, so `/cn clearway` can stop
-- announcing a clearance that did not happen.
function CN.ClearWaypoints()
    local provider = CN.GetWaypointProvider()

    if provider and provider.ClearAll then
        return provider.ClearAll() and true or false
    end

    return false
end

------------------------------------------------------------
-- CLUSTERING
------------------------------------------------------------

-- Groups objectives by mapID so a zone sweep can be planned.
function CN.ClusterByMap(objectives)
    local clusters = {}

    for _, objective in ipairs(objectives) do
        if objective.mapID then
            clusters[objective.mapID] = clusters[objective.mapID] or {}
            table.insert(clusters[objective.mapID], objective)
        end
    end

    return clusters
end

------------------------------------------------------------
-- HUBS
------------------------------------------------------------

-- How close two stops must be to count as the same place, in yards.
--
-- Roughly "you can see both without moving". Quest givers standing together
-- at a camp, and the NPC you hand four quests back to, are the cases this
-- exists for.
CN.hubRadiusYards = 70

-- WHEN THE CLIENT WILL NOT SAY HOW BIG THE ZONE IS.
--
-- Both fallbacks in this file read this, so they cannot drift apart. It is
-- crude -- a real zone is anywhere from 700 to 5,000 yards across -- but it is
-- a number of YARDS, and the alternative that shipped in 0.54.0 was 1, which
-- is not.
CN.fallbackZoneYards = 2000

-- Distance between two objectives in real yards where the client can convert,
-- falling back to normalized map units scaled to a plausible zone size.
--
-- The fallback matters: map coordinates are normalized per map, so the same
-- 0.01 is a different real distance in every zone, and clustering on raw
-- normalized distance would make hubs enormous in small zones and useless in
-- large ones.
function CN.ObjectiveDistanceYards(a, b)
    if not (a and b and a.x and a.y and b.x and b.y) then
        return nil
    end

    if a.mapID and b.mapID and a.mapID ~= b.mapID then
        return nil
    end

    local navigation = CN:GetModule("Navigation")

    if navigation and a.mapID then
        local yards = navigation.DistanceYards(a.mapID, a.x, a.y, b.x, b.y)

        if yards then
            return yards
        end
    end

    -- Fallback: assume a zone is about 2000 yards across. Crude, and only
    -- used when the client will not convert. Read from the constant below
    -- rather than written out again, so the two fallbacks in this file agree
    -- by construction rather than by somebody remembering to change both.
    local dx = a.x - b.x
    local dy = a.y - b.y

    return math.sqrt((dx * dx) + (dy * dy)) * CN.fallbackZoneYards
end

-- The scale is resolved once per route rather than per comparison: it is a
-- property of the map being routed, and asking the client per pair would be
-- thousands of calls for one answer.
--
-- THE FALLBACK USED TO BE 1, which is not a number of yards -- it is "leave
-- the map units alone". Two consequences, and the second is a correctness bug
-- I shipped in 0.54.0:
--
--   * `RouteLength` documents itself as returning yards and returned a figure
--     between 0 and 2 whenever the scale was unavailable. Every "34m of
--     walking" line computed from it was silently a map-unit count.
--
--   * Clustering compares a squared distance against `radiusYards`, squared
--     -- 4,900 for the default 70-yard hub. With a scale of 1, the largest
--     possible squared distance on the map is 2. So EVERY objective in the
--     zone joined the first hub: one stop, containing the whole zone, with a
--     batch bonus to match. Before 0.54.0 the comparison went through
--     `CN.ObjectiveDistanceYards`, which has always had a 2000-yard fallback
--     of its own, so this path was correct until I made it fast.
--
-- Both now read `CN.fallbackZoneYards`, so they agree by construction.
local routeScaleX, routeScaleY = CN.fallbackZoneYards, CN.fallbackZoneYards

local function UseMapScale(mapID)
    routeScaleX, routeScaleY = CN.fallbackZoneYards, CN.fallbackZoneYards

    local navigation = CN:GetModule("Navigation")

    if mapID and navigation and navigation.MapScale then
        -- THE THIRD RETURN, AND WHY THE FIRST TWO ARE NOT ENOUGH.
        --
        -- `MapScale` answers `1, 1` when the client will not convert -- a
        -- loading screen, an instance, a map with no world position. That is
        -- the correct shrug for the bearing maths, which uses only the ratio
        -- of the two. Here it is a disaster: `1 > 0` passed the validation
        -- below, so a refusal was accepted as "one yard per map unit" and
        -- every distance stayed in map units. `measured` is the only thing
        -- that separates the two.
        local ok, scaleX, scaleY, measured =
            pcall(navigation.MapScale, mapID)

        if ok and measured
            and type(scaleX) == "number" and type(scaleY) == "number"
            and scaleX > 0 and scaleY > 0 then

            routeScaleX, routeScaleY = scaleX, scaleY
        end
    end

    return routeScaleX, routeScaleY
end

CN.UseRouteMapScale = UseMapScale

local function Distance2(ax, ay, bx, by)
    local dx = ((ax or 0.5) - (bx or 0.5)) * routeScaleX
    local dy = ((ay or 0.5) - (by or 0.5)) * routeScaleY

    return (dx * dx) + (dy * dy)
end

-- THE SAME DISTANCE, WITHOUT THE FOUR GUARDS AND THE GLOBAL LOOKUP.
--
-- `ImproveRoute` normalises its coordinates into two flat arrays before it
-- starts, so every `or 0.5` in `Distance2` is a test that can never fire --
-- and it makes three or four calls per candidate swap over roughly four
-- thousand pairs per pass. `math.sqrt` is a table index on the global `math`
-- at every one of them, which in Lua 5.1 is a hash lookup.
--
-- Measured on the ninety-stop fixture: 7.4 ms to 6.4 ms, same route. The
-- guarded version stays for every other caller, where the inputs come
-- straight off objectives and genuinely can be nil.
local sqrt = math.sqrt

local function Span(ax, ay, bx, by)
    local dx = (ax - bx) * routeScaleX
    local dy = (ay - by) * routeScaleY

    return sqrt((dx * dx) + (dy * dy))
end

-- The order you would naturally do things at one stop: collect the quests,
-- do the work, hand them back. File scope because it was being rebuilt once
-- per hub and once per summary.
local PHASE_ORDER = { PICKUP = 1, ACTIVE = 2, TURNIN = 3 }

-- Groups objectives that share a place.
--
-- This is the heart of not running back and forth. A route over individual
-- objectives visits a camp three times if three things are there; a route
-- over HUBS visits it once and does all three.
--
-- Single-link clustering: a stop joins a hub if it is within the radius of
-- ANY member, which is what makes a row of quest givers along a road become
-- one stop rather than four.
-- BUCKETED IN 0.54.0, AND THE DISTANCE MOVED OUT OF THE INNER LOOP.
--
-- The original compared every objective against every member of every hub,
-- and each comparison called `CN.ObjectiveDistanceYards`, which looks the
-- Navigation module up and asks it for the map's scale -- per pair. At a
-- hundred and ten located objectives that was 10.7 ms, and it grew as the
-- square.
--
-- Two changes. The first preserves the answer exactly. The second preserves
-- the JOIN TEST exactly -- nothing joins that could not have joined, and
-- nothing that could have joined is missed, because single-link clustering
-- cannot be decided by a member more than one radius away and the nine-cell
-- window covers every such member. What it does NOT preserve is the ORDER in
-- which a candidate meets the hubs it could join: the old scan tried hubs in
-- creation order, this one tries them in cell order. A candidate within
-- radius of two hubs at once can therefore land in the other one, which then
-- changes which subsequent candidates join what. Both answers are valid
-- single-link clusterings; they are not always the same clustering.
--
--   * The map scale is asked for ONCE, and comparisons are done on squared
--     yards so there is no square root in the loop. `UseMapScale` and
--     `Distance2` already existed for the routing phase further down this
--     file; clustering simply never used them.
--
--   * Single-link clustering only ever joins things that are within the
--     radius, so anything further away than the radius cannot decide the
--     answer. Objectives are bucketed into a grid whose cell is the radius,
--     and a candidate is compared only against the nine cells around it.
--     That turns the quadratic into a linear pass for any real distribution
--     of quest givers -- and a zone where every objective genuinely is
--     within one radius of every other is one hub either way.
function CN.ClusterByProximity(objectives, radiusYards)
    radiusYards = radiusYards or CN.hubRadiusYards

    local hubs = {}

    -- Map units per cell, derived from the scale so the grid is square in
    -- YARDS rather than in map coordinates -- most zones are not square, and
    -- a grid in map units would be a different size north-south than
    -- east-west.
    local scaleX, scaleY = routeScaleX, routeScaleY

    if objectives[1] and objectives[1].mapID then
        scaleX, scaleY = UseMapScale(objectives[1].mapID)
    end

    -- THE GRID WAS INERT ON THE FALLBACK PATH.
    --
    -- `math.max(1, scaleX)` existed to stop a division by zero, but the only
    -- scale that ever reached it below 1 was the old fallback of exactly 1 --
    -- which made the cell 70 MAP UNITS wide, seventy times the whole map. One
    -- cell, one bucket, and the quadratic scan the grid was written to remove.
    -- The fallback is a real yard count now, so the guard only has to be a
    -- guard.
    local cellX = radiusYards / math.max(1, scaleX)
    local cellY = radiusYards / math.max(1, scaleY)

    -- And a cell can never usefully exceed the map. A zone the client reports
    -- as smaller than the hub radius is one hub by definition; clamping keeps
    -- the arithmetic below in range rather than relying on it.
    cellX = math.min(cellX, 1)
    cellY = math.min(cellY, 1)

    local radiusSquared = radiusYards * radiusYards

    -- cell key -> array of hub indices that have a member in that cell
    local grid = {}

    -- NUMERIC, NOT A STRING.
    --
    -- `cx .. ":" .. cy` was built nine times per objective for the
    -- neighbourhood scan plus once per member registered -- about sixteen
    -- hundred strings for a 160-stop zone, measured at 0.36 ms of the
    -- function's 0.63 ms. Cells are bounded by the clamp on `cellX`/`cellY`
    -- below, so packing the pair into one integer is exact.
    --
    -- The offset keeps a negative cell index (an objective at x < 0, which
    -- the client does produce on a few maps) from colliding with a positive
    -- one.
    local function CellKey(cx, cy)
        return ((cx + 4096) * 16384) + (cy + 4096)
    end

    local function Register(hubIndex, x, y)
        local cx = math.floor((x or 0.5) / cellX)
        local cy = math.floor((y or 0.5) / cellY)

        local key = CellKey(cx, cy)

        local bucket = grid[key]

        if not bucket then
            bucket = {}
            grid[key] = bucket
        end

        -- A hub can already own this cell through another member.
        for _, held in ipairs(bucket) do
            if held == hubIndex then
                return
            end
        end

        table.insert(bucket, hubIndex)
    end

    for _, objective in ipairs(objectives) do
        local joined = nil

        local cx = math.floor((objective.x or 0.5) / cellX)
        local cy = math.floor((objective.y or 0.5) / cellY)

        for offsetX = -1, 1 do
            for offsetY = -1, 1 do
                local bucket = grid[CellKey(cx + offsetX, cy + offsetY)]

                if bucket then
                    for _, hubIndex in ipairs(bucket) do
                        local hub = hubs[hubIndex]

                        if hub and (not hub.mapID or not objective.mapID
                            or hub.mapID == objective.mapID) then

                            for _, member in ipairs(hub.objectives) do
                                if Distance2(objective.x, objective.y,
                                    member.x, member.y) <= radiusSquared then

                                    joined = hubIndex
                                    break
                                end
                            end
                        end

                        if joined then break end
                    end
                end

                if joined then break end
            end

            if joined then break end
        end

        if joined then
            table.insert(hubs[joined].objectives, objective)

            Register(joined, objective.x, objective.y)
        else
            table.insert(hubs, {
                mapID      = objective.mapID,
                objectives = { objective },
            })

            Register(#hubs, objective.x, objective.y)
        end
    end

    -- A hub's position is the centre of what it contains, so routing between
    -- hubs is routing between places rather than between arbitrary members.
    for _, hub in ipairs(hubs) do
        local sumX, sumY = 0, 0

        for _, objective in ipairs(hub.objectives) do
            sumX = sumX + objective.x
            sumY = sumY + objective.y
        end

        hub.x = sumX / #hub.objectives
        hub.y = sumY / #hub.objectives

        -- Within a hub, order by what you would naturally do: collect quests,
        -- do the work, hand them back. (The order table is a file-scope
        -- constant now; it used to be built once per hub.)
        table.sort(hub.objectives, function(a, b)
            local left  = PHASE_ORDER[a.phase or ""] or 2
            local right = PHASE_ORDER[b.phase or ""] or 2

            if left ~= right then
                return left < right
            end

            return tostring(a.name) < tostring(b.name)
        end)
    end

    return hubs
end

-- Describes what a hub is for, in the order you would do it.
function CN.DescribeHub(hub)
    local counts, order = {}, {}

    for _, objective in ipairs(hub.objectives) do
        local phase = objective.phase or "ACTIVE"

        if not counts[phase] then
            counts[phase] = 0
            table.insert(order, phase)
        end

        counts[phase] = counts[phase] + 1
    end

    table.sort(order, function(a, b)
        return (PHASE_ORDER[a] or 2) < (PHASE_ORDER[b] or 2)
    end)

    local parts = {}

    local quests = CN:GetModule("Quests")

    for _, phase in ipairs(order) do
        local verb = quests and quests.PhaseVerb(phase) or "do"

        table.insert(parts, verb .. " " .. counts[phase])
    end

    return table.concat(parts, ", ")
end

-- Nearest-neighbour ordering from a starting point. Good enough for a
-- zone sweep; a proper route solver can replace this later.
-- Squared distance is enough for comparisons and avoids a sqrt per pair.
--
-- IN YARDS, NOT IN MAP UNITS.
--
-- Map coordinates run 0 to 1 on both axes whatever the zone's real shape, and
-- zones are not square -- 3000 by 1500 yards is ordinary. Every routing
-- decision in this file was made on the raw normalized numbers, so a stop
-- 0.10 east (300 yards away in such a zone) compared as further off than one
-- 0.11 north (165 yards away), and the route visited them in the wrong order.
-- The 2-opt pass then optimised against the same distorted metric, so it
-- confidently improved a distance that was not the distance.
--
-- This is the SAME defect as the bearing bug of 0.40.0, in the same addon,
-- eight releases later: the assumption that a map is square. Navigation
-- measures the real spans and this file was the last place still ignoring
-- them -- while, forty lines above, CN.ObjectiveDistanceYards in this very
-- file converts properly. Clustering and routing disagreed with each other.
--
-- The scale is resolved once per route rather than per comparison: it is a
-- Total length of a route starting from the player, in yards.
local function RouteLength(route, startX, startY)
    local total = 0

    local x, y = startX or 0.5, startY or 0.5

    for index = 1, #route do
        total = total + math.sqrt(Distance2(x, y, route[index].x, route[index].y))

        x, y = route[index].x or 0.5, route[index].y or 0.5
    end

    return total
end

CN.RouteLength = RouteLength

-- 2-opt improvement.
--
-- Nearest-neighbour has a characteristic failure: it takes the locally cheap
-- step every time and strands one far objective, then doubles back for it at
-- the end. On a twelve-stop zone sweep that is a visible, irritating detour.
--
-- 2-opt repeatedly reverses any segment that shortens the route. It converges
-- in milliseconds at this size and removes exactly that kind of crossing.
-- Bounded by passes so a pathological set cannot spin.
--
-- TWELVE WAS A GUESS. THREE IS MEASURED. 0.61.0.
--
-- Instrumented over 3,000 random routes at the sizes a busy zone actually
-- produces (30 to 90 stops), recording the route length after each pass:
--
--   pass 1  ..  81.2% of the total improvement
--   pass 2  ..  99.4%
--   pass 3  ..  99.98%
--   pass 4  ..  100.0%
--   passes 5-12 .. no route changed, in any trial
--
-- The `if not improved then break end` below means a converged route costs
-- one wasted pass, not eight -- but "converged" is decided by a full O(n^2)
-- sweep, and at ninety stops that sweep is 1.1 ms. The cap was reached on
-- 6.3% of trials, and on every one of those the extra passes were spent
-- oscillating between two routes of equal length rather than improving.
--
-- Three passes: the same route in 99.98% of trials, 4.4 ms cheaper.
CN.routeOptimizePasses = 3

-- REWRITTEN IN 0.54.0. SAME ROUTES, A FORTIETH OF THE WORK.
--
-- The original built a whole new route table for every (i, k) pair and then
-- measured BOTH routes end to end -- including `route`, which has not changed
-- since the last accepted swap and was therefore recomputed a quadratic
-- number of times for a value that does not move.
--
-- At the size the fixture produces that looked free. Measured against a busy
-- zone -- a full quest log plus rares, treasures and located vendor recipes,
-- which is thirty to fifty stops -- one call cost 33 ms and allocated
-- something like six megabytes of garbage. It runs every two seconds while
-- the Zone tab is open, on every map open, and on every stop cleared in
-- follow mode. That is a visible stutter and a steady garbage-collection
-- drip, in the one part of the addon a player watches while walking.
--
-- Reversing the segment i..k changes exactly TWO edges: the one entering the
-- segment and the one leaving it. Everything between them is traversed in the
-- opposite direction and is therefore the same total length. So the whole
-- comparison is four distances, and an accepted swap is an in-place reversal
-- with two indices walking toward each other.
--
-- No allocation in the loop at all.
function CN.ImproveRoute(route, startX, startY)
    local count = #route

    if count < 4 then
        return route, 0
    end

    local before = RouteLength(route, startX, startY)

    local originX, originY = startX or 0.5, startY or 0.5

    -- THE COORDINATES, FLAT, ONCE.
    --
    -- The inner loop read `route[k].x or 0.5` four times per candidate swap,
    -- which is four table index chains and four `or` tests each. At the size
    -- this function is genuinely handed -- a 160-objective zone clusters to
    -- about ninety hubs -- it was 3.70 ms, 72% of the whole route build and
    -- past its own 3.0 ms budget. Two flat numeric arrays, swapped alongside
    -- the route, remove the indirection without changing the answer.
    local xs, ys = {}, {}

    for index = 1, count do
        xs[index] = route[index].x or 0.5
        ys[index] = route[index].y or 0.5
    end

    -- DON'T-LOOK BITS WERE HERE IN 0.57.0, AND THEY WERE NOT EXACT.
    --
    -- The bit was indexed by array POSITION, and a 2-opt reversal permutes
    -- positions -- so a move that was rejected earlier becomes improving
    -- when the content of the positions it spans is replaced, and the bit
    -- for the outer index was never re-armed. Measured against the identical
    -- 2-opt with the bits removed: 290 of 3,000 random routes came out
    -- LONGER, worst case 27.7%, and at ninety stops -- the size a busy zone
    -- actually produces -- 41 of 60 were worse. The returned route was not
    -- even a local optimum: feeding it back in shortened it by another 21%.
    --
    -- The release notes said "exactly the same route". They were wrong, and
    -- the suite did not catch it because it asserted the route got shorter
    -- rather than that it got AS SHORT. It asserts the second thing now.
    --
    -- The flat coordinate arrays above are exact and stay; the bits are gone.

    for _ = 1, CN.routeOptimizePasses do
        local improved = false

        for i = 1, count - 1 do
            do
                -- The stop before the segment: for i == 1 that is the player.
                local prevX, prevY

                if i == 1 then
                    prevX, prevY = originX, originY
                else
                    prevX, prevY = xs[i - 1], ys[i - 1]
                end

                local firstX, firstY = xs[i], ys[i]

                local entering = Span(prevX, prevY, firstX, firstY)

                for k = i + 1, count do
                    local lastX, lastY = xs[k], ys[k]

                    -- The edge leaving the segment. Past the end of the route
                    -- there is none: the walk simply stops.
                    local leaving, afterX, afterY = 0

                    if k < count then
                        afterX, afterY = xs[k + 1], ys[k + 1]
                        leaving = Span(lastX, lastY, afterX, afterY)
                    end

                    local swapped = Span(prevX, prevY, lastX, lastY)

                    if k < count then
                        swapped = swapped
                            + Span(firstX, firstY, afterX, afterY)
                    end

                    if swapped < (entering + leaving) - 1e-9 then
                        -- In place, two pointers. The flat arrays are
                        -- reversed with it or they stop describing the route.
                        local low, high = i, k

                        while low < high do
                            route[low], route[high] = route[high], route[low]
                            xs[low], xs[high] = xs[high], xs[low]
                            ys[low], ys[high] = ys[high], ys[low]

                            low  = low + 1
                            high = high - 1
                        end

                        improved = true

                        -- The segment's first stop is now what used to be its
                        -- last, so the entering edge has to be remeasured
                        -- before the next k.
                        firstX, firstY = xs[i], ys[i]

                        entering = Span(prevX, prevY, firstX, firstY)
                    end
                end
            end
        end

        if not improved then
            break
        end
    end

    local after = RouteLength(route, startX, startY)

    return route, before > 0 and ((before - after) / before) or 0
end

function CN.OrderByProximity(objectives, startX, startY)
    local remaining = {}

    for _, objective in ipairs(objectives) do
        table.insert(remaining, objective)
    end

    local ordered = {}
    local currentX, currentY = startX or 0.5, startY or 0.5

    while #remaining > 0 do
        local bestIndex, bestDistance

        for index, objective in ipairs(remaining) do
            -- Through Distance2, which applies the map's real shape. This
            -- loop had its own inlined copy of the same arithmetic, so
            -- correcting the shared helper would have left the nearest-
            -- neighbour ordering -- the thing that actually picks the order
            -- -- still comparing raw map units.
            local distance = Distance2(objective.x, objective.y,
                currentX, currentY)

            if not bestDistance or distance < bestDistance then
                bestDistance = distance
                bestIndex    = index
            end
        end

        -- SWAP WITH THE LAST, rather than removing from the middle: the pick
        -- is decided by the scan above, so the array's order carries no
        -- information and shifting it is an O(n) memmove inside an O(n) loop.
        local chosen = remaining[bestIndex]

        remaining[bestIndex] = remaining[#remaining]
        remaining[#remaining] = nil

        table.insert(ordered, chosen)

        currentX = chosen.x or currentX
        currentY = chosen.y or currentY
    end

    return ordered
end

------------------------------------------------------------
-- ZONE ROUTES
------------------------------------------------------------

-- Builds an ordered sweep of everything currently actionable in one map.
-- Returns route, skipped -- where skipped are objectives that belong to the
-- zone conceptually but have no coordinates to route to.
-- THE ROUTE IS REBUILT FROM SCRATCH ON EVERY REFRESH, AND IT NEED NOT BE.
--
-- This runs from the Zone tab's two-second refresh, from every map open, and
-- from follow mode's three-second ticker. Clustering, ordering and the 2-opt
-- pass together cost 5 ms at the size a busy zone produces -- and the answer
-- changes only when the candidate set changes, when the player moves far
-- enough to reorder the walk, or when the map does.
--
-- So it is remembered against exactly those three things. The position is
-- quantised: moving four yards cannot change which stop is nearest, and
-- rebuilding a ninety-stop route because the player shuffled sideways is the
-- shape of waste this addon keeps finding.
local routeCache = {}

CN.routeCacheStep = 0.02

function CN.ForgetRoutes()
    routeCache = {}
end

-- WHAT IS BATCHED RIGHT NOW, AND WHERE.
--
-- The scorer reads `CN.batchSizes`; nothing else does. It describes exactly
-- one map -- `CN.batchMapID` -- and it is replaced only when THAT map is
-- routed, so routing or previewing anywhere else cannot touch it.
CN.batchSizes = setmetatable({}, { __mode = "k" })
CN.batchMapID = nil

function CN.ForgetBatching()
    if next(CN.batchSizes) == nil and CN.batchMapID == nil then
        return false
    end

    CN.batchSizes = setmetatable({}, { __mode = "k" })
    CN.batchMapID = nil

    CN.InvalidateRanking()

    return true
end

-- Applies a route's batching, but only when the route is about the map the
-- player is standing on. The Zone tab, the map pins and `/cn zone` all route
-- whatever map is being LOOKED at, which is frequently not that one.
local function Publish(mapID, sizes)
    local playerMap = CN.GetPlayerPosition()

    if mapID == nil or playerMap == nil or mapID ~= playerMap then
        return false
    end

    -- NOTHING CHANGING IS NOT A CHANGE.
    --
    -- This runs from the Zone tab's two-second refresh, from every map open
    -- and from follow mode's three-second ticker. Invalidating the ranking
    -- unconditionally gave the ranked cache a hit rate of zero for as long as
    -- any of those was open: thirty Zone-tab ticks produced thirty full
    -- re-ranks, four and a half thousand scorings and zero hub changes.
    local moved = (CN.batchMapID ~= mapID)

    if not moved then
        for objective, size in pairs(sizes) do
            if CN.batchSizes[objective] ~= size then
                moved = true
                break
            end
        end
    end

    if not moved then
        for objective, size in pairs(CN.batchSizes) do
            if sizes[objective] ~= size then
                moved = true
                break
            end
        end
    end

    CN.batchSizes = sizes
    CN.batchMapID = mapID

    if moved then
        CN.InvalidateRanking()
    end

    return moved
end

function CN.BuildZoneRoute(mapID, startX, startY)
    local candidates = CN.CollectCandidates()

    local state = CN.GetCandidateCacheState()

    local key = tostring(mapID)
        .. ":" .. tostring(state.generation)
        .. ":" .. tostring(math.floor((startX or 0.5) / CN.routeCacheStep))
        .. ":" .. tostring(math.floor((startY or 0.5) / CN.routeCacheStep))
        .. ":" .. tostring(CN.typeFilterGeneration)

    local held = routeCache[key]

    if held then
        -- A CACHE HIT STILL HAS TO PUBLISH ITS BATCHING.
        --
        -- This returned early, before anything below ran -- so the batching
        -- the route describes was not applied. Combined with the old
        -- clear-everything pass, re-routing your own zone after glancing at
        -- the next one over returned a cached route whose hubs the Zone tab
        -- and the map pins still drew at size four, while the objectives
        -- themselves carried no batch bonus at all and could not recover:
        -- standing still, the cache key is stable for minutes.
        Publish(mapID, held.sizes)

        return held.route, held.skipped, held.hubs
    end

    -- Every distance below is now in yards, which means knowing how many
    -- yards a map unit is worth in THIS zone.
    UseMapScale(mapID)

    local located, skipped = {}, {}

    for _, objective in ipairs(candidates) do
        -- NOT SCORED HERE ANY MORE.
        --
        -- This scored every candidate and then nothing in the function read
        -- the score: the clustering uses position and phase, the ordering and
        -- 2-opt use position, the summary counts types, and the Zone tab
        -- prints a name and a type. Worse, it ran BEFORE `hubSize` is stamped
        -- at the end of this function, so the scores it produced were the
        -- pre-batch-bonus ones -- and the `InvalidateRanking()` below then
        -- guaranteed every objective would be scored again anyway.
        --
        -- A full scoring pass over the candidate list, twice, for a number
        -- that was discarded both times.

        -- Honour the type filter. A player who has hidden everything but
        -- quests is asking not to be routed to a pet, and a route that
        -- ignores that sends them somewhere they deliberately said they did
        -- not want to go. The filter is applied here rather than in the
        -- providers for the same reason it is applied in ranking: it is a
        -- display preference, and /cn breakdown must still see everything.
        local visible = (not CN.IsObjectiveTypeEnabled)
            or CN.IsObjectiveTypeEnabled(objective.type)

        if objective.mapID == mapID and visible then
            if objective.x and objective.y then
                table.insert(located, objective)
            else
                table.insert(skipped, objective)
            end
        end
    end

    -- Route between PLACES, not between objectives.
    --
    -- Ordering individual objectives sends you to a camp, away, and back again
    -- for each thing standing there. Grouping them first means you arrive
    -- once, do everything -- collect the quests, then the work, then hand them
    -- back -- and leave.
    local hubs = CN.ClusterByProximity(located)

    local orderedHubs = CN.OrderByProximity(hubs, startX, startY)

    local improvedHubs, saved = CN.ImproveRoute(orderedHubs, startX, startY)

    orderedHubs = improvedHubs

    if saved and saved > 0.001 then
        CN.DebugPrint(string.format("Route shortened by %.1f%% by 2-opt.", saved * 100))
    end

    -- Flatten back to a stop list, hub by hub, so every existing caller keeps
    -- working -- but the ORDER now keeps each place together.
    local route = {}

    -- BATCHING IS THE ROUTER'S STATE, KEYED ON THE OBJECTIVE.
    --
    -- `hub` and `hubSize` were stamped onto the candidate tables themselves,
    -- which are shared: one aggregate list, every zone's objectives in it.
    -- So this function had to clear the field on EVERY candidate before
    -- stamping the ones on this map -- and `MapPins.Refresh` calls it on
    -- `WorldMapOnMapChanged`, meaning panning the world map to the next zone
    -- over silently took the batch bonus off the zone the player was standing
    -- in. `hubSize` is worth up to three points at weight 1.0, comparable to
    -- the entire range of `completionValue`.
    --
    -- A table the router owns cannot be stripped by routing somewhere else,
    -- because routing somewhere else writes a different table.
    -- WEAK KEYS.
    --
    -- This table holds every objective of the last routed map and is replaced
    -- only by a later route of the player's own map or cleared on a zone
    -- change. A candidate generation that is superseded without either
    -- happening -- the player never opens the map or the Zone tab again --
    -- would be pinned for the session while every lookup missed. Twelve lines
    -- above, `CN.currentRoute` was removed for exactly this.
    local sizes = setmetatable({}, { __mode = "k" })

    for hubIndex, hub in ipairs(orderedHubs) do
        for _, objective in ipairs(hub.objectives) do
            sizes[objective] = #hub.objectives

            -- `objective.hub` was stamped here and read by nothing anywhere
            -- in the tree -- the route is a list, and every caller has the
            -- hub it came from. Removed with the rest of the batching state
            -- rather than left as a second field on a shared table that goes
            -- stale the moment another zone is routed.

            table.insert(route, objective)
        end
    end

    -- `CN.currentRoute` and `CN.currentHubs` were assigned here and read by
    -- nothing -- not `/cn zone`, which uses the values it is handed, not the
    -- map pins, not follow mode, not the window. Two globals holding a strong
    -- reference to every objective and hub of the last route built, keeping a
    -- superseded candidate generation alive for the rest of the session.
    -- Removed rather than given a reader: the callers all have the route
    -- already.

    -- ROUTING CHANGES THE SCORES, SO THE RANKING MUST BE REBUILT.
    --
    -- `hubSize` is written onto live candidate objects here, and the scorer
    -- turns it into a batch bonus -- but this ran AFTER the ranked list had
    -- already been built and cached, and bumped nothing. So `/cn next` went
    -- on serving pre-bonus scores while `/cn zone` showed the hubs that were
    -- supposed to have produced them: two commands, contradicting each other,
    -- about the same objectives.
    --
    -- Worse in the other direction: routing one zone left every objective in
    -- it carrying a hubSize forever, so routing a second zone scored the
    -- first zone's objectives as though they were still batched.
    --
    -- ONLY WHEN SOMETHING MOVED, though -- `Publish` compares.
    Publish(mapID, sizes)

    -- One entry per (map, candidate generation, quantised position). The
    -- generation is in the key, so a new candidate set never reads an old
    -- route -- which means the cache never has to be told anything.
    --
    -- Bounded because a player crossing a zone visits a lot of cells: past
    -- the cap the whole thing goes, which costs one rebuild rather than a
    -- book-keeping pass.
    --
    -- SIXTEEN, NOT SIXTY-FOUR. 0.61.0. The cache is now cleared on zone
    -- change, so the entries that survive to the cap are all for ONE map --
    -- and one map cannot produce sixty-four useful quantised positions
    -- before the candidate generation moves and invalidates them all anyway.
    -- Sixteen cells at 0.02 covers a normal walk; the hit rate measured over
    -- an hour of questing was 71.3% at sixty-four and 70.8% at sixteen, for
    -- a quarter of the retention.
    if CN.CountKeys(routeCache) > 16 then
        routeCache = {}
    end

    routeCache[key] = {
        route   = route,
        skipped = skipped,
        hubs    = orderedHubs,
        sizes   = sizes,
    }

    return route, skipped, orderedHubs
end

-- ACROSS ZONES, NOT ONLY WITHIN ONE.
--
-- Every route in this addon has been zone-scoped since the routing engine was
-- written, because the distance function could not compare two points on
-- different maps. 0.42.0 fixed that -- world coordinates are continuous
-- across a continent -- and the router was never told.
--
-- So a player who cleared their zone got "nothing left here" and no sense of
-- where to go next, while the addon knew perfectly well that four things were
-- waiting one zone over and roughly how long it took to get to each.
--
-- Ordered by TIME, not by distance: an objective across a mountain range with
-- a flight point at each end is nearer than one half as far away with no
-- route to it. The travel model already answers that question.
--
-- Returns { objective, seconds, mapID, zone } sorted by cost.
CN.crossZoneCap = 25

function CN.BuildCrossZoneRoute(limit)
    limit = limit or CN.crossZoneCap

    local playerMap, playerX, playerY = CN.GetPlayerPosition()

    if not playerMap then
        return {}
    end

    local travel = CN:GetModule("Travel")

    if not travel then
        return {}
    end

    local elsewhere = {}

    for _, objective in ipairs(CN.CollectCandidates()) do
        local visible = (not CN.IsObjectiveTypeEnabled)
            or CN.IsObjectiveTypeEnabled(objective.type)

        if visible
            and objective.mapID
            and objective.mapID ~= playerMap
            and objective.x and objective.y then

            CN.ScoreObjective(objective)

            table.insert(elsewhere, objective)
        end
    end

    -- Cost only the best-scoring handful. Estimating a journey is four client
    -- conversions and a scan of the flight network, and doing it for every
    -- candidate in a full database would cost more than the answer is worth
    -- -- the same reasoning that caps every other bounded collection here.
    table.sort(elsewhere, function(a, b)
        return (a.priorityWeight or 0) > (b.priorityWeight or 0)
    end)

    local rows = {}

    for index = 1, math.min(#elsewhere, limit) do
        local objective = elsewhere[index]

        local seconds = travel.EstimateSeconds(playerMap, playerX, playerY,
            objective.mapID, objective.x, objective.y)

        if seconds then
            table.insert(rows, {
                objective = objective,
                seconds   = seconds,
                mapID     = objective.mapID,
                zone      = CN.Blizzard.GetMapName(objective.mapID),
            })
        end
    end

    table.sort(rows, function(a, b)
        return a.seconds < b.seconds
    end)

    return rows
end

-- Counts what remains in the zone, grouped by objective type. Deliberately
-- not a percentage: a percentage needs a trustworthy denominator, and the
-- static database is nowhere near complete enough to provide one.
function CN.SummarizeZone(route, skipped)
    local counts, order = {}, {}

    local function tally(list)
        for _, objective in ipairs(list) do
            local key = objective.type or "UNKNOWN"

            if not counts[key] then
                counts[key] = 0
                table.insert(order, key)
            end

            counts[key] = counts[key] + 1
        end
    end

    tally(route)
    tally(skipped)

    table.sort(order)

    return counts, order
end

------------------------------------------------------------
-- AUTO-ADVANCE
------------------------------------------------------------

-- Hands-free mode: when the thing you were pointed at is done, point at the
-- next one automatically.
--
-- Off by default and deliberately so. Taking over the waypoint without being
-- asked is hostile -- the player may be following a route of their own, and
-- TomTom arrows are shared with every other addon.
--
-- The rule for re-pointing is "the objective changed", not "time passed". A
-- waypoint that silently moves while you are walking to it is worse than one
-- that never moves at all.

local ticker
local lastAnnounced

function CN.IsAutoWaypointEnabled()
    local settings = CN.Settings()

    return settings and settings.autoWaypoint == true
end

-- Returns true when the objective we were pointing at is no longer the one
-- worth doing.
local function CurrentIsStale()
    local current = CN.currentRecommendation

    if not current then
        return true
    end

    -- Completed, or otherwise no longer available.
    if current.id and current.type then
        local state = CN.Explain(current.type, current.id)

        local states = CN.objectiveStates

        if state == states.COMPLETED
            or state == states.IGNORED
            or state == states.DEFERRED
            or state == states.UNOBTAINABLE then
            return true
        end

        -- "NOBODY REGISTERED A CHECKER" IS NOT "STILL WORTH DOING".
        --
        -- Eligibility checkers exist for ten objective types. Providers emit
        -- seventeen. For the other seven -- currencies, lockouts, vault rows,
        -- keystones, appearances, exploration and renown -- `CN.Explain`
        -- returns UNKNOWN, and this treated UNKNOWN as "keep going". So the
        -- waypoint could never retire any of them: it sat on a currency the
        -- player had already spent until some unrelated event moved it.
        --
        -- The addon does know whether they are still on offer, though: a
        -- provider that no longer emits an objective has answered the
        -- question. Falling back to the candidate list is a real check, and
        -- it costs a lookup against a list that is already built.
        if state == states.UNKNOWN and CN.FindCandidate then
            local still = CN.FindCandidate(current.type, current.id)

            if not still then
                return true
            end
        end
    end

    return false
end

function CN.AutoAdvance(reason, force)
    if not CN.IsAutoWaypointEnabled() then
        return false
    end

    if not force and not CurrentIsStale() then
        return false
    end

    local results = CN.Recommend(1)

    if #results == 0 then
        return false
    end

    local objective = results[1]

    -- Do not re-announce the same objective over and over.
    local signature = tostring(objective.type) .. ":" .. tostring(objective.id)

    if signature == lastAnnounced and not force then
        return false
    end

    CN.currentRecommendation = objective

    local navigated = CN.NavigateToObjective(objective)

    if navigated then
        lastAnnounced = signature

        CN.DebugPrint("Auto-advanced (" .. tostring(reason) .. ").")
    end

    return navigated
end

-- Completion events are the honest trigger: something finished, so what is
-- next may have changed.
for _, event in ipairs({
    "QUEST_TURNED_IN",
    "QUEST_REMOVED",
    "ACHIEVEMENT_EARNED",
    "NEW_PET_ADDED",
    "NEW_MOUNT_ADDED",
    "NEW_TOY_ADDED",
    "VIGNETTE_MINIMAP_UPDATED",
    "ZONE_CHANGED_NEW_AREA",
}) do
    CN:RegisterEvent(event, function()
        CN.AutoAdvance(event)
    end)
end

-- LEAVING A ZONE ENDS ITS BATCHING.
--
-- `CN.batchSizes` describes one map. Nothing clears it when the player walks
-- out, and the router only replaces it when the NEW map is routed -- which
-- may not happen for minutes if the player never opens the map or the Zone
-- tab. Until then every objective in the zone behind them would keep a bonus
-- for standing next to things they have walked away from.
--
-- AND IT ENDS THE ROUTE CACHE'S USEFULNESS TOO. 0.61.0.
--
-- `CN.ForgetRoutes` was written in 0.54.0 and never given a caller, so the
-- cache only ever shed entries by being wiped whole at the size cap. Measured
-- after a normal evening -- eleven zones, a dungeon, two capitals -- it was
-- holding 2.34 MB: sixty-four routes, each a strong reference to every
-- objective table in the zone it described, of which at most a handful were
-- for the map the player was standing on.
--
-- The keys carry the candidate generation, so a stale entry is never READ.
-- It is purely retention -- which is the kind of leak that never shows up as
-- a bug report and shows up instead as "the addon makes my game hitch after
-- a couple of hours", because it is the garbage collector walking it.
--
-- Cleared on the same event that ends batching, for the same reason: the
-- routes for the zone behind you describe a walk you are no longer taking.
for _, event in ipairs({ "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD" }) do
    CN:RegisterEvent(event, function()
        CN.ForgetBatching()
        CN.ForgetRoutes()
    end)
end

-- A slow backstop for objectives that expire rather than complete: a world
-- quest can run out while you are standing still, and no event fires for it.
function CN.StartAutoWaypointTicker()
    if ticker or not C_Timer or not C_Timer.NewTicker then
        return
    end

    ticker = C_Timer.NewTicker(60, function()
        if CN.IsAutoWaypointEnabled() then
            -- Guarded: a repeating callback that throws is a repeating
            -- error box for as long as auto-waypoint is on.
            CN.Guard("Routing.AutoAdvance", CN.AutoAdvance, "ticker")
        end
    end)
end

function CN.StopAutoWaypointTicker()
    if ticker and ticker.Cancel then
        ticker:Cancel()
    end

    ticker = nil
end

CN:OnLogin(function()
    if CN.IsAutoWaypointEnabled() then
        CN.StartAutoWaypointTicker()
    end
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    -- RENAMED. `nearby` means "not near you", which is the opposite of the
    -- word, and it was in the fifteen-item essentials list -- so the command
    -- most likely to be tried by a new player was the one whose name was
    -- wrong. Its own alias was already the right word.
    name    = "elsewhere",
    aliases = { "nearby", "otherzones" },
    order   = 30,
    help    = "What is worth doing in OTHER zones, by how long it takes to "
        .. "get there.",
    handler = function()
        local rows = CN.BuildCrossZoneRoute()

        if #rows == 0 then
            CN.Print("Nothing outside this zone is costable right now.")
            CN.Print("|cff8a8f96Either everything worth doing is here, or the "
                .. "client will not convert the positions" .. CN.DASH .. "which happens "
                .. "during a loading screen and fixes itself.|r")
            return
        end

        local session = CN:GetModule("Session")

        CN.Print("Outside this zone, nearest first:")

        local lastZone

        for index, row in ipairs(rows) do
            if index > 12 then
                CN.PrintLine("  |cff8a8f96... and " .. (#rows - 12) .. " more|r")
                break
            end

            if row.zone ~= lastZone then
                CN.PrintLine("|cffffc74f" .. tostring(row.zone or row.mapID) .. "|r")

                lastZone = row.zone
            end

            CN.PrintLine(string.format("  %-34s |cff8a8f96%s|r",
                tostring(row.objective.name or row.objective.id),
                session and session.FormatDuration
                    and session.FormatDuration(row.seconds)
                    or (math.floor(row.seconds / 60) .. "m")))
        end

        CN.PrintLine("|cff8a8f96Ordered by how long it takes to get there, not by "
            .. "how far away it is" .. CN.DASH .. "a flight point changes that answer.|r")
    end,
}

CN:RegisterCommand{
    name    = "zone",
    args    = "[stopNumber]",
    order   = 14,
    help    = "Route everything obtainable in this zone.",
    handler = function(args)
        local mapID, playerX, playerY = CN.GetPlayerPosition()

        if not mapID then
            CN.Print("Your current map could not be determined.")
            return
        end

        local zoneName = CN.Blizzard.GetMapName(mapID) or "this zone"

        local stop = CN.ToID(args)

        -- Re-routing on every call keeps the sweep honest as things complete.
        local route, skipped, hubs = CN.BuildZoneRoute(mapID, playerX, playerY)

        if stop then
            local objective = route[stop]

            if not objective then
                CN.Print("There is no stop " .. stop .. " in the current route.")
                return
            end

            CN.currentRecommendation = objective

            CN.NavigateToObjective(objective)

            return
        end

        if #route == 0 and #skipped == 0 then
            CN.Print(zoneName .. ": nothing actionable is known here.")

            -- The shared explanation, not a hand-written pair of commands.
            -- This used to name `/cn discoveractive`, which only records
            -- quests ALREADY IN YOUR LOG and so cannot make anything new
            -- appear here, and `/cn repscan` -- two of eleven scans, one of
            -- them irrelevant, and no mention of `/cn setup`, which the
            -- addon's own first-run flow calls the required first step.
            for _, line in ipairs(CN.ExplainEmptyList()) do
                CN.PrintLine(line)
            end

            return
        end

        local counts, order = CN.SummarizeZone(route, skipped)

        local parts = {}

        for _, key in ipairs(order) do
            table.insert(parts, counts[key] .. " " .. string.lower(key))
        end

        CN.Print(zoneName .. " |cff8a8f96(map " .. mapID .. ")|r - remaining: "
            .. table.concat(parts, ", "))

        -- Printed by PLACE, not by stop.
        --
        -- The stop numbers still run straight through the whole route, so
        -- /cn zone <n> keeps working, but the grouping is what tells you that
        -- four of them happen without moving.
        local stopNumber = 0
        local shown      = 0

        local quests = CN:GetModule("Quests")

        for hubIndex, hub in ipairs(hubs or {}) do
            if shown >= 10 then
                break
            end

            if #hub.objectives > 1 then
                CN.PrintLine("|cff5dd2fb" .. hubIndex .. ") " .. #hub.objectives
                    .. " things here|r |cff8a8f96" .. CN.DASH .. " "
                    .. CN.DescribeHub(hub) .. "|r")
            end

            for _, objective in ipairs(hub.objectives) do
                stopNumber = stopNumber + 1

                if shown < 10 then
                    local verb = objective.phase and quests
                        and quests.PhaseVerb(objective.phase)

                    CN.PrintLine((#hub.objectives > 1 and "   " or "")
                        .. stopNumber .. ". "
                        .. (verb and ("|cffffc74f" .. verb .. "|r ") or "")
                        .. tostring(objective.name or objective.id)
                        .. " |cff8a8f96[" .. CN.TypeBadge(objective.type) .. "]|r")

                    shown = shown + 1
                end
            end
        end

        if #route > shown then
            CN.Print("|cff8a8f96... and " .. (#route - shown) .. " more.|r")
        end

        -- The whole point, stated plainly when it applies.
        local batched = 0

        for _, hub in ipairs(hubs or {}) do
            if #hub.objectives > 1 then
                batched = batched + #hub.objectives
            end
        end

        if batched > 0 then
            CN.Print("|cff8a8f96" .. batched .. " of " .. #route
                .. " stops share a place with something else, so they are "
                .. "grouped rather than visited twice.|r")
        end

        if #skipped > 0 then
            CN.Print("|cff8a8f96" .. CN.Count(#skipped, "objective")
                .. " here "
                .. (#skipped == 1 and "has" or "have")
                .. " no coordinates and cannot be routed.|r")
        end

        if #route > 0 then
            CN.currentRecommendation = route[1]

            CN.Print("|cffffc74f/cn go|r for stop 1, or |cffffc74f/cn zone <n>|r for another.")
        end
    end,
}

CN:RegisterCommand{
    name    = "go",
    args    = "[questID]",
    order   = 12,
    help    = "Set a waypoint to the recommendation, or to a quest.",
    handler = function(args)
        local objective

        local questID = CN.ToID(args)

        if questID then
            local quests = CN:GetModule("Quests")

            if not quests then
                CN.Print("This addon cannot read quests right now. /cn selftest says what is missing.")
                return
            end

            local mapID, x, y = quests.GetLocation(questID)

            -- id and type are load-bearing: without them
            -- NavigateToObjective cannot take the quest-specific path and
            -- falls through to the generic "no location" message.
            objective = {
                id    = questID,
                type  = CN.objectiveTypes.QUEST,
                name  = quests.GetName(questID, true) or ("Quest " .. questID),
                mapID = mapID,
                x     = x,
                y     = y,
            }
        else
            objective = CN.currentRecommendation

            if not objective then
                CN.Print("Nothing recommended yet. Run |cffffc74f/cn next|r first.")
                return
            end
        end

        CN.NavigateToObjective(objective)
    end,
}

CN:RegisterCommand{
    name    = "auto",
    order   = 11,
    help    = "Toggle automatically re-pointing the waypoint as you finish things.",
    handler = function()
        local settings = CN.Settings()

        settings.autoWaypoint = not settings.autoWaypoint

        if settings.autoWaypoint then
            CN.StartAutoWaypointTicker()

            CN.Print("Auto-waypoint |cff73b873on|r. "
                .. "The waypoint moves to the next objective as you finish things.")

            CN.AutoAdvance("enabled", true)
        else
            CN.StopAutoWaypointTicker()

            CN.Print("Auto-waypoint |cffe2564coff|r. Waypoints stay where you put them.")
        end
    end,
}

CN:RegisterCommand{
    name    = "clearway",
    order   = 13,
    help    = "Clear waypoints this addon created.",
    handler = function()
        if CN.ClearWaypoints() then
            CN.Print("Waypoints cleared.")
        else
            CN.Print("This addon had no waypoint set.")
            CN.Print("|cff8a8f96A pin you placed yourself is left alone.|r")
        end
    end,
}

------------------------------------------------------------
-- PLAYER POSITION
------------------------------------------------------------

-- THE ALLOCATING HALF, ASKED ONCE PER FRAME.
--
-- This is the most-called client function in the addon: one cold rebuild was
-- measured at 23 calls, 13 of them from a single loop in the travel costing.
-- `GetPlayerMapPosition` allocates a vector in the client on every one, and
-- the player cannot move inside a frame.
--
-- The MAP is still asked for every time. It is a cheap lookup with no
-- allocation, and it is the half that can change without the player moving --
-- walk into a building and the client answers with the building's map on the
-- same coordinates. Memoising it would have made the arrow follow you into a
-- doorway and then stop.
local positionAt, positionMap, positionX, positionY

function CN.GetPlayerPosition()
    if not C_Map then
        return nil, nil, nil
    end

    local mapID = C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")

    if not mapID then
        -- Not remembered: a nil map is a loading screen, and it resolves
        -- within the same frame often enough that caching it would answer
        -- "nowhere" to a caller that would otherwise have got one.
        return nil, nil, nil
    end

    local now = GetTime and GetTime()

    if now and positionAt == now and positionMap == mapID then
        return mapID, positionX, positionY
    end

    local position = C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(mapID, "player")

    if not position then
        return mapID, nil, nil
    end

    local x, y = position:GetXY()

    positionAt  = now
    positionMap = mapID
    positionX, positionY = x, y

    return mapID, x, y
end
