-- Modules/MapPins.lua
-- Completion Navigator :: the plan, drawn on the world map.
--
-- Everything else in this addon answers "what next?" one line at a time. That
-- is the right answer to the question, but it hides the thing that actually
-- makes the routing worth having: the SHAPE of the work. The router already
-- groups objectives into hubs, orders the hubs to minimise walking, and
-- improves that order with a 2-opt pass -- and until now a player saw none of
-- it. They saw a list and an arrow, and had no way to know that stops three
-- through six were all the same camp, or that the route doubles back for a
-- reason.
--
-- So: one numbered pin per HUB, in route order, on the map you are looking at.
-- The number is the order. The tooltip is what you do when you arrive, in the
-- order you would do it. Clicking navigates there.
--
-- One pin per hub, not per objective. Twelve overlapping pins on one camp
-- communicate less than a single pin reading "3 -- pick up 2, do 4, hand in
-- 1", and a map that becomes unreadable when you have a lot to do is a map
-- that fails exactly when it matters most.
--
-- Deliberately NOT a MapCanvasDataProvider. The data-provider API is the
-- blessed route, and it is also a moving target that has broken addons across
-- several expansions. A pooled frame parented to the canvas is boring, has no
-- version surface to speak of, and degrades to "no pins" rather than to a Lua
-- error inside Blizzard's map code.

local ADDON_NAME, CN = ...

local MapPins = CN:RegisterModule("MapPins")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint

local function Settings()
    return CN.Settings() or {}
end

------------------------------------------------------------
-- ENABLEMENT
------------------------------------------------------------

-- On by default. Pins are additive and read-only -- like tooltip lines, and
-- unlike the waypoint, they take nothing over and interrupt nothing. They
-- also appear only on a map you have deliberately opened.
function MapPins.IsEnabled()
    return Settings().mapPins ~= false
end

function MapPins.SetEnabled(value)
    Settings().mapPins = value and true or false

    if value then
        MapPins.Refresh(true)
    else
        MapPins.Clear()
    end

    return MapPins.IsEnabled()
end

------------------------------------------------------------
-- GEOMETRY
------------------------------------------------------------

-- Normalised map coordinates to a canvas offset.
--
-- The canvas is anchored from its TOPLEFT and y grows DOWNWARD, while map
-- coordinates also grow downward -- so the offset is +x and -y. Getting the
-- sign wrong mirrors every pin vertically, which looks plausible on a
-- symmetrical map and is completely wrong on every other one.
--
-- Pure, and tested as such: this is the one piece of the file that can be
-- wrong in a way no amount of looking at the screen would reveal, because a
-- mirrored pin is still a pin in a believable place.
function MapPins.CanvasOffset(x, y, width, height)
    if not x or not y or not width or not height then
        return nil
    end

    return x * width, -(y * height)
end

MapPins.pinSize      = 26
MapPins.maxPins      = 40
MapPins.crowdedScale = 0.8

-- How big a pin should be. A hub holding six things is worth more of the
-- player's attention than one holding a single stray pet, and size is the
-- cheapest way to say so without adding another colour to read.
function MapPins.PinSize(hubSize, pinCount)
    local size = MapPins.pinSize

    if (hubSize or 1) > 1 then
        size = size + math.min(10, (hubSize - 1) * 2)
    end

    -- A busy zone gets smaller pins rather than fewer of them. Dropping stops
    -- silently would misrepresent the route; shrinking them does not.
    if (pinCount or 0) > 12 then
        size = size * MapPins.crowdedScale
    end

    return math.floor(size + 0.5)
end

------------------------------------------------------------
-- LAYOUT
------------------------------------------------------------

-- Turns ordered hubs into pin descriptors. Pure: no frames, no client, no
-- side effects. Everything that decides what a pin SAYS happens here, so it
-- can be asserted offline.
function MapPins.Layout(hubs)
    local pins = {}

    if type(hubs) ~= "table" then
        return pins
    end

    local total = 0

    for _, hub in ipairs(hubs) do
        if hub.x and hub.y then
            total = total + 1
        end
    end

    for index, hub in ipairs(hubs) do
        if #pins >= MapPins.maxPins then
            break
        end

        -- A hub with no coordinates cannot be drawn. It is not dropped from
        -- the route -- the list still reports it -- it simply has nowhere to
        -- go on a map.
        if hub.x and hub.y then
            local objectives = hub.objectives or {}

            table.insert(pins, {
                order      = index,
                mapID      = hub.mapID,
                x          = hub.x,
                y          = hub.y,
                size       = MapPins.PinSize(#objectives, total),
                hubSize    = #objectives,
                summary    = CN.DescribeHub and CN.DescribeHub(hub) or nil,
                objectives = objectives,
            })
        end
    end

    -- HOW MANY DID NOT FIT. 0.84.0.
    --
    -- The loop above stops at `maxPins` and this function threw the shortfall
    -- away, while thirty lines up the note above `PinSize` states the
    -- opposite rule for the same overflow: "A busy zone gets smaller pins
    -- rather than fewer of them. Dropping stops silently would misrepresent
    -- the route; shrinking them does not." Past forty stops it does drop
    -- them, and said nothing.
    --
    -- `total` is already counted for the sizing; reporting it costs nothing
    -- and lets the caller apply the house rule -- a truncated list that looks
    -- complete is worse than a long one.
    return pins, math.max(0, total - #pins)
end

-- The tooltip body for one pin: what you do when you get there, in the order
-- you would do it. The hub's objectives are already sorted pick up -> do ->
-- hand in by the router, so this only has to not re-sort them.
function MapPins.DescribeLines(pin)
    local lines = {}

    if not pin then
        return lines
    end

    local quests = CN:GetModule("Quests")

    local shown = 0

    for _, objective in ipairs(pin.objectives or {}) do
        if shown >= 8 then
            table.insert(lines, string.format(
                "and %d more", #pin.objectives - shown))
            break
        end

        local verb = "do"

        if objective.phase and quests and quests.PhaseVerb then
            verb = quests.PhaseVerb(objective.phase)
        end

        table.insert(lines, string.format("%s: %s",
            verb, tostring(objective.name or objective.id)))

        shown = shown + 1
    end

    return lines
end

------------------------------------------------------------
-- THE CANVAS
------------------------------------------------------------

-- Resolves the world map's canvas, or nil. Every layer here is optional
-- because every layer is Blizzard's: if any of it moves, pins stop appearing
-- and nothing else in the addon notices.
function MapPins.Canvas()
    local map = _G and _G.WorldMapFrame

    if not map or not map.ScrollContainer then
        return nil
    end

    return map.ScrollContainer.Child
end

-- Which map the player is LOOKING AT, which is not necessarily where they
-- are standing.
function MapPins.DisplayedMapID()
    local map = _G and _G.WorldMapFrame

    if not map or not map.GetMapID then
        return nil
    end

    local ok, mapID = pcall(map.GetMapID, map)

    if ok then
        return mapID
    end

    return nil
end

function MapPins.IsMapShown()
    local map = _G and _G.WorldMapFrame

    if not map or not map.IsShown then
        return false
    end

    local ok, shown = pcall(map.IsShown, map)

    return ok and shown == true
end

------------------------------------------------------------
-- THE ROUTE FOR A DISPLAYED MAP
------------------------------------------------------------

-- Where a route across THIS map should start.
--
-- If you are looking at the zone you are standing in, the route starts at
-- your feet -- that is the whole point of routing. If you are looking at
-- somewhere else, your position is meaningless there: using it would order
-- the stops by their distance from a point on another continent, producing a
-- route that is not merely suboptimal but arbitrary. Start from the middle
-- instead, which orders the stops by their relationship to each other.
function MapPins.RouteStart(displayedMapID)
    local playerMap, x, y = nil, nil, nil

    if CN.GetPlayerPosition then
        local ok, a, b, c = pcall(CN.GetPlayerPosition)

        if ok then
            playerMap, x, y = a, b, c
        end
    end

    if displayedMapID and playerMap == displayedMapID and x and y then
        return x, y, true
    end

    return 0.5, 0.5, false
end

local cache = { mapID = nil, generation = nil, hubs = nil }

function MapPins.InvalidateCache()
    cache.mapID      = nil
    cache.generation = nil
    cache.hubs       = nil
end

-- EVERYTHING THE ROUTE DEPENDS ON, NOT JUST THE CANDIDATES.
--
-- `BuildZoneRoute` applies the objective-type filter when it picks the stops,
-- so the hub set is a function of that filter as well as of the candidate
-- list. `SetTypeEnabled` deliberately does not rebuild providers -- it bumps
-- `CN.typeFilterGeneration` instead -- so the candidate generation did not
-- move and this cache did not notice.
--
-- The result was two views of one route disagreeing on screen: `/cn zone`
-- honoured `/cn show only quests` and the map, reopened a second later, still
-- drew the pet and appearance stops the player had just hidden.
local function RouteGeneration()
    local generation = 0

    if CN.GetCandidateCacheState then
        local ok, state = pcall(CN.GetCandidateCacheState)

        if ok and state then
            generation = state.generation or 0
        end
    end

    -- The ranking generation is deliberately NOT part of this key:
    -- `BuildZoneRoute` bumps it itself, so including it would mean the cache
    -- never matched and the route was rebuilt on every map pan -- which is
    -- the cost this cache exists to avoid.
    return generation .. ":" .. tostring(CN.typeFilterGeneration or 0)
end

-- Building a zone route means collecting and scoring every candidate, so it
-- must not happen on every map pan. It happens when the map you are looking
-- at changes, or when the underlying candidates do.
function MapPins.HubsForMap(mapID, force)
    if not mapID or not CN.BuildZoneRoute then
        return nil
    end

    local startX, startY = MapPins.RouteStart(mapID)

    -- AND WHERE THE ROUTE STARTS IS PART OF THE ROUTE. 0.90.0.
    --
    -- The key was the candidate generation and the type filter, and neither
    -- moves when the player walks -- nor does anything else invalidate on
    -- movement, since the only invalidators are the zone change and the quest
    -- log. So: open the map at one end of a zone, run to the other end, open
    -- it again, and the numbered stops are still ordered from where you were
    -- standing the first time, for the rest of the session. Route ORDER is
    -- the entire content of this feature; the header above calls it "the
    -- SHAPE of the work".
    --
    -- `CN.BuildZoneRoute` already keys its own cache on the start point, so
    -- the fresher answer existed and this layer declined to ask for it, and
    -- `Travel.CostFor` solves the same problem with `costCacheYards`.
    --
    -- Coarsened to `CN.routeCacheStep`, the same grid the router uses, so a
    -- map pan and a few yards of walking still hit the cache: this is the
    -- work that must not happen on every frame the map is open.
    local generation = RouteGeneration()
        .. ":" .. tostring(math.floor((startX or 0.5) / CN.routeCacheStep))
        .. ":" .. tostring(math.floor((startY or 0.5) / CN.routeCacheStep))

    if not force
        and cache.mapID == mapID
        and cache.generation == generation
        and cache.hubs then

        return cache.hubs
    end

    local ok, _, _, hubs = pcall(CN.BuildZoneRoute, mapID, startX, startY)

    if not ok then
        return nil
    end

    cache.mapID      = mapID
    cache.generation = generation
    cache.hubs       = hubs

    return hubs
end

------------------------------------------------------------
-- THE PINS THEMSELVES
------------------------------------------------------------

local pool = {}

-- A SEQUENCE, NOT ONE BRIGHT PIN AND A CROWD OF GREY ONES.
--
-- Stop one wore the brand blue and every other stop wore the same flat grey,
-- so a twelve-stop route read as one pin and eleven identical ones -- and the
-- numbers, which are the smallest and least legible thing on the map, were
-- the only way to tell them apart.
--
-- The route is ordered, and the pins should say so. Same hue throughout,
-- stepped down in value: bright at the front, fading back. That is what the
-- whole 2-opt pass exists to produce and it is now visible without reading a
-- single digit.
MapPins.trailFade = 0.06
MapPins.trailFloor = 0.55

local function PinColor(order)
    local brand = CN.RGB.BRAND

    if (order or 1) <= 1 then
        return brand[1], brand[2], brand[3]
    end

    local step = math.min(MapPins.trailFloor,
        0.10 + ((order - 1) * MapPins.trailFade))

    local keep = 1 - step

    return brand[1] * keep, brand[2] * keep, brand[3] * keep
end

local function ShowPinTooltip(frame)
    if not GameTooltip or not frame.pin then
        return
    end

    GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")

    GameTooltip:AddLine(string.format("Stop %d", frame.pin.order), 1, 1, 1)

    if frame.pin.summary then
        GameTooltip:AddLine(frame.pin.summary, CN.Rgb("BRAND"))
    end

    for _, line in ipairs(MapPins.DescribeLines(frame.pin)) do
        GameTooltip:AddLine(line, CN.Rgb("BODY"))
    end

    GameTooltip:AddLine("Click to navigate here", CN.Rgb("MUTED"))

    GameTooltip:Show()
end

local function HidePinTooltip()
    if GameTooltip then
        GameTooltip:Hide()
    end
end

-- Clicking navigates to the first objective at the stop THAT HAS
-- COORDINATES, and falls back to the stop itself.
--
-- THE COMMENT HERE DESCRIBED THE OPPOSITE ORDER. 0.96.0. It said clicking
-- navigates to the stop "not to whichever objective happens to be listed
-- first there", which is not what the loop below does and never was. The
-- behaviour is right -- routing to the objective carries the objective
-- through `NavigateToObjective`, so the arrow knows what it is pointing at
-- -- and the comment would have sent the next reader to "fix" working code.
--
-- The reasoning it got right, and which the fallback exists for: an
-- objective's own coordinates may be missing -- plenty of collectibles are
-- known to be in a zone and nowhere more precise -- while the stop's are the
-- centre of everything at it and always exist, because that is how the stop
-- was formed. Answering a click with "no coordinates are known" is, from the
-- player's side, the addon refusing to go to a place it just drew a pin on.
-- So: the objective where one can be routed to, the stop otherwise, and
-- never a refusal.
local function ClickPin(frame)
    local pin = frame.pin

    if not pin then
        return
    end

    for _, objective in ipairs(pin.objectives or {}) do
        if objective.x and objective.y and CN.NavigateToObjective then
            CN.NavigateToObjective(objective)
            return
        end
    end

    if pin.x and pin.y and pin.mapID and CN.SetWaypointAndSay then
        local first = (pin.objectives or {})[1]

        local label = first and tostring(first.name or first.id)
            or ("Stop " .. tostring(pin.order))

        -- SAY SOMETHING. 0.79.0. This clicked a pin on the world map and
        -- printed nothing, so a refusal and a success looked identical.
        CN.SetWaypointAndSay(pin.mapID, pin.x, pin.y, label,
            "Waypoint set: " .. label)
    end
end

local function AcquirePin(index, canvas)
    if pool[index] then
        return pool[index]
    end

    if not CreateFrame or not canvas then
        return nil
    end

    local frame = CreateFrame("Button", "CompletionNavigatorMapPin" .. index, canvas)

    frame:SetSize(MapPins.pinSize, MapPins.pinSize)

    frame.texture = frame:CreateTexture(nil, "OVERLAY")
    frame.texture:SetAllPoints()
    frame.texture:SetTexture(CN.MEDIA_PATH .. "Arrow")

    if not frame.texture:GetTexture() then
        frame.texture:SetTexture("Interface\\Minimap\\MinimapArrow")
    end

    frame.label = CN.Label(frame, "OVERLAY", "CAPTION")
    frame.label:SetPoint("CENTER")

    -- Over map art, which is the same problem as over the world: a stop
    -- number in ten-point gold with a one-pixel shadow disappears against
    -- half the maps in the game.
    CN.Outline(frame.label, 12, "PRIMARY")

    frame:SetScript("OnEnter", ShowPinTooltip)
    frame:SetScript("OnLeave", HidePinTooltip)
    frame:SetScript("OnClick", ClickPin)

    pool[index] = frame

    return frame
end

MapPins.AcquirePin = AcquirePin

function MapPins.Clear()
    for _, frame in ipairs(pool) do
        frame:Hide()
    end
end

-- Positions the pins. Separated from Refresh so the arithmetic can be driven
-- offline against a stubbed canvas.
function MapPins.Place(pins, canvas)
    if not canvas then
        return 0
    end

    local width  = canvas:GetWidth()
    local height = canvas:GetHeight()

    if not width or not height or width <= 0 or height <= 0 then
        return 0
    end

    local placed = 0

    for index, pin in ipairs(pins) do
        local frame = AcquirePin(index, canvas)

        if frame then
            local offsetX, offsetY = MapPins.CanvasOffset(pin.x, pin.y, width, height)

            if offsetX then
                frame.pin = pin

                frame:SetSize(pin.size, pin.size)
                frame:ClearAllPoints()
                frame:SetPoint("CENTER", canvas, "TOPLEFT", offsetX, offsetY)

                frame.label:SetText(tostring(pin.order))
                frame.texture:SetVertexColor(PinColor(pin.order))

                frame:Show()

                placed = placed + 1
            end
        end
    end

    -- Surplus frames from a busier map are hidden, never destroyed. Pin
    -- frames are cheap to keep and expensive to churn.
    for index = #pins + 1, #pool do
        pool[index]:Hide()
        pool[index].pin = nil
    end

    return placed
end

function MapPins.Refresh(force)
    if not MapPins.IsEnabled() then
        MapPins.Clear()
        return 0
    end

    if not MapPins.IsMapShown() then
        return 0
    end

    local canvas = MapPins.Canvas()

    if not canvas then
        return 0
    end

    local mapID = MapPins.DisplayedMapID()

    if not mapID then
        MapPins.Clear()
        return 0
    end

    local hubs = MapPins.HubsForMap(mapID, force)

    if not hubs then
        MapPins.Clear()
        return 0
    end

    -- AND CARRY THE SHORTFALL OUT. 0.85.0. `Layout` reports how many stops
    -- did not fit; this function discarded it, so the one caller that prints
    -- a number still printed the capped one as the total.
    local pins, dropped = MapPins.Layout(hubs)

    local placed = MapPins.Place(pins, canvas)

    DebugPrint(string.format("Map pins: %d stop(s) on map %s.",
        placed, tostring(mapID)))

    return placed, dropped or 0
end

------------------------------------------------------------
-- HOOKS
------------------------------------------------------------

local hooked = false

-- Hooked, not overwritten. The world map is shared with every other addon
-- the player runs, and replacing a script on it would break them.
function MapPins.Install()
    if hooked then
        return true
    end

    local map = _G and _G.WorldMapFrame

    if not map or not map.HookScript then
        return false
    end

    -- GUARDED, because these are hooks on a frame the player opens
    -- constantly and shares with every other addon they run. An unguarded
    -- throw here is an error box every time the world map opens.
    map:HookScript("OnShow", function()
        CN.Guard("MapPins.Refresh", MapPins.Refresh)
    end)

    map:HookScript("OnHide", function()
        CN.Guard("MapPins.Clear", MapPins.Clear)
    end)

    -- Panning to a different zone is a map change, not a redraw, so the
    -- route must be rebuilt for the map now on screen.
    if map.RegisterCallback and map.OnMapChanged then
        pcall(map.RegisterCallback, map, "WorldMapOnMapChanged", function()
            CN.Guard("MapPins.Refresh", MapPins.Refresh)
        end)
    end

    hooked = true

    return true
end

CN:RegisterEvent("PLAYER_ENTERING_WORLD", function()
    MapPins.Install()
end)

CN:RegisterEvent("ZONE_CHANGED_NEW_AREA", function()
    MapPins.InvalidateCache()
    MapPins.Refresh()
end)

CN:RegisterEvent("QUEST_LOG_UPDATE", function()
    MapPins.InvalidateCache()
end)

------------------------------------------------------------
-- COMMAND
------------------------------------------------------------

CN:RegisterCommand{
    name    = "pins",
    aliases = { "map" },
    args    = "[on, off, or refresh]",
    order   = 18,
    help    = "Show the route as numbered pins on the world map.",
    handler = function(args)
        args = string.lower(CN.Trim(args or ""))

        if args == "on" then
            MapPins.SetEnabled(true)
            Print("Map pins are on.")
            return
        end

        if args == "off" then
            MapPins.SetEnabled(false)
            Print("Map pins are off.")
            return
        end

        if args == "refresh" then
            MapPins.InvalidateCache()

            -- THE OTHER BRANCH OF THIS HANDLER. 0.85.0. 0.84.0 fixed the
            -- listing twenty-five lines below to say how many stops it did
            -- not draw, and left the branch above it reporting the capped
            -- count as a fact -- "Redrew 40 stops." for a route of
            -- sixty-three. The sibling nobody swept, in the same function as
            -- the fix.
            local placed, dropped = MapPins.Refresh(true)

            Print("Redrew " .. CN.Count(placed, "stop") .. "."
                .. ((dropped or 0) > 0
                    and CN.Aside(dropped .. " more not drawn; the map caps at "
                        .. MapPins.maxPins) or ""))
            return
        end

        if not MapPins.IsEnabled() then
            Print("Map pins are off. Turn them on with /cn pins on")
            return
        end

        local mapID = MapPins.DisplayedMapID()

        if not mapID then
            Print("Map pins are on. Open the world map to see the route.")
            return
        end

        local hubs = MapPins.HubsForMap(mapID)
        local pins, dropped = MapPins.Layout(hubs or {})

        if #pins == 0 then
            Print("Nothing to route on this map.")
            return
        end

        -- AND SAY WHEN IT STOPPED. 0.84.0. This printed the TRUNCATED count
        -- as the total, so in a busy zone a player read "40 stops on this
        -- map:" as a statement of fact about the whole route.
        Print(CN.Count(#pins, "stop") .. " on this map"
            .. ((dropped or 0) > 0
                and CN.Aside(dropped .. " more not drawn; the map caps at "
                    .. MapPins.maxPins) or "") .. ":")

        for _, pin in ipairs(pins) do
            CN.PrintLine(string.format("  %d. %s (%d)",
                pin.order,
                tostring(pin.summary or "do " .. pin.hubSize),
                pin.hubSize))
        end
    end,
}

return MapPins
