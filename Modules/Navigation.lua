-- Modules/Navigation.lua
-- Completion Navigator :: native waypoints and the on-screen arrow.
--
-- Until now the addon decided WHERE to go and handed the job of pointing at it
-- to TomTom. That made TomTom effectively required: without it you got a
-- static map pin and no arrow, which is not navigation.
--
-- This file removes that dependency. It is not an attempt to reimplement
-- TomTom -- it is the minimum that makes the addon complete on its own:
--
--   * a waypoint store of our own
--   * an arrow that points at the current target and colours by whether you
--     are facing it
--   * real distance in yards, not map percentage
--   * arrival detection, which is what makes auto-advance work properly
--
-- TomTom stays supported. Someone who already runs it and likes its arrow can
-- keep using it -- /cn nav tomtom -- and everything else still works.
--
------------------------------------------------------------------------------
-- THE MATH, and an admission about it.
--
--   Map coordinates run x east, y SOUTH. North is therefore -y.
--   bearing clockwise from north = atan2(dx, -dy)
--   relative bearing             = bearing - (facing * facingSign)
--   rotation to apply            = -(relative bearing)
--
-- The one thing that cannot be derived from first principles is which way
-- GetPlayerFacing() counts. 0 is north on every build; whether the value grows
-- as you turn left or as you turn right is a client convention.
--
-- 0.19.0 assumed counter-clockwise and shipped a bearing that pointed people
-- away from their target. The harness "verified" it against seven cases -- and
-- every one of those cases computed its expected answer from the same
-- assumption, so the tests agreed with the bug. A test that encodes the
-- premise it is meant to check proves nothing.
--
-- So the sign is not asserted here. It defaults to the convention every
-- established navigation addon uses, and then CORRECTS ITSELF from evidence:
-- if you are lined up with the arrow, moving, and the distance is growing,
-- the sign is wrong, and the addon flips it and says so. The game is the only
-- thing that can settle this, so the game settles it.
------------------------------------------------------------------------------

local ADDON_NAME, CN = ...

local Navigation = CN:RegisterModule("Navigation")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

------------------------------------------------------------
-- STATE
------------------------------------------------------------

-- The single active target. One arrow, one destination: a list of waypoints is
-- TomTom's job, and duplicating it would be duplicating the wrong half.
local target = nil

local arrow, ticker

Navigation.arrivalYards = 12

function Navigation.GetTarget()
    return target
end

------------------------------------------------------------
-- GEOMETRY
------------------------------------------------------------

-- Radians clockwise from straight ahead. nil when the bearing cannot be
-- computed, which is different from zero and must not be shown as zero.
-- +1 means GetPlayerFacing() grows clockwise; -1 means counter-clockwise.
-- Persisted once determined, so the correction happens at most once ever.
function Navigation.FacingSign()
    local settings = CN.Settings()

    if settings and settings.facingSign then
        return settings.facingSign
    end

    return 1
end

function Navigation.SetFacingSign(sign)
    local settings = CN.Settings()

    if settings then
        settings.facingSign = (sign < 0) and -1 or 1
    end
end

function Navigation.RelativeBearing(playerX, playerY, targetX, targetY, facing, sign)
    if not (playerX and playerY and targetX and targetY and facing) then
        return nil
    end

    local dx = targetX - playerX
    local dy = targetY - playerY

    if dx == 0 and dy == 0 then
        return 0
    end

    -- -dy because map y grows southward.
    local bearing = math.atan(dx, -dy)

    local relative = bearing - (facing * (sign or Navigation.FacingSign()))

    -- Normalize to (-pi, pi] so "how far off am I" is a small number.
    while relative > math.pi do
        relative = relative - (2 * math.pi)
    end

    while relative <= -math.pi do
        relative = relative + (2 * math.pi)
    end

    return relative
end

-- Distance in yards, using the client's world positions. Map coordinates are
-- normalized per map, so a 0.1 difference is a different real distance in
-- every zone; converting is the only way to get a number worth printing.
--
-- Returns nil when the client cannot convert, rather than a made-up figure.
function Navigation.DistanceYards(mapID, playerX, playerY, targetX, targetY)
    if not (mapID and playerX and playerY and targetX and targetY) then
        return nil
    end

    if not C_Map or not C_Map.GetWorldPosFromMapPos then
        return nil
    end

    -- GetWorldPosFromMapPos takes a Vector2D, NOT a UiMapPoint.
    --
    -- These are two different types and 0.19.0 passed the wrong one, so the
    -- call returned nothing and the arrow reported "distance unknown" for
    -- every target. UiMapPoint carries a nested `position`; Vector2D carries
    -- x and y directly. SetUserWaypoint wants the former, this wants the
    -- latter, and they are easy to confuse because both describe a point.
    if not CreateVector2D then
        return nil
    end

    local function worldPosition(x, y)
        local ok, continentID, position =
            pcall(C_Map.GetWorldPosFromMapPos, mapID, CreateVector2D(x, y))

        if not ok or not position then
            return nil, nil
        end

        -- Vector2D exposes GetXY(); some builds also expose x and y directly.
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
            return nil, nil
        end

        return continentID, { x = wx, y = wy }
    end

    local fromContinent, fromPos = worldPosition(playerX, playerY)

    if not fromPos then
        return nil
    end

    local toContinent, toPos = worldPosition(targetX, targetY)

    if not toPos then
        return nil
    end

    -- Different continents means the straight-line number would be nonsense.
    if fromContinent and toContinent and fromContinent ~= toContinent then
        return nil
    end

    local dx = toPos.x - fromPos.x
    local dy = toPos.y - fromPos.y

    return math.sqrt((dx * dx) + (dy * dy))
end

function Navigation.FormatDistance(yards)
    if not yards then
        return "distance unknown"
    end

    if yards >= 1000 then
        return string.format("%.1f km", yards * 0.0009144)
    end

    return string.format("%d yd", math.floor(yards + 0.5))
end

------------------------------------------------------------
-- THE ARROW
------------------------------------------------------------

local function Settings()
    return CN.Settings() or {}
end

function Navigation.IsArrowEnabled()
    local settings = Settings()

    return settings.arrow ~= false
end

local function BuildArrow()
    if arrow or not CreateFrame then
        return arrow
    end

    arrow = CreateFrame("Frame", "CompletionNavigatorArrow", UIParent)

    arrow:SetSize(56, 56)
    arrow:SetFrameStrata("MEDIUM")
    arrow:SetMovable(true)
    arrow:EnableMouse(true)
    arrow:RegisterForDrag("LeftButton")
    arrow:SetClampedToScreen(true)

    local settings = Settings()

    settings.arrowPosition = settings.arrowPosition or {}

    arrow:SetPoint(
        settings.arrowPosition.point or "CENTER",
        UIParent,
        settings.arrowPosition.point or "CENTER",
        settings.arrowPosition.x or 0,
        settings.arrowPosition.y or 160)

    arrow.texture = arrow:CreateTexture(nil, "ARTWORK")
    arrow.texture:SetAllPoints()
    arrow.texture:SetTexture(CN.MEDIA_PATH .. "Arrow")

    -- SetTexture fails silently on a missing file, so verify rather than
    -- shipping an invisible arrow.
    if not arrow.texture:GetTexture() then
        arrow.texture:SetTexture("Interface\\Minimap\\MinimapArrow")
    end

    arrow.label = arrow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    arrow.label:SetPoint("TOP", arrow, "BOTTOM", 0, -2)
    arrow.label:SetJustifyH("CENTER")

    arrow.distance = arrow:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    arrow.distance:SetPoint("TOP", arrow.label, "BOTTOM", 0, -2)
    arrow.distance:SetJustifyH("CENTER")

    arrow:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)

    arrow:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()

        local point, _, _, x, y = self:GetPoint()

        local saved = Settings()

        saved.arrowPosition = { point = point, x = x, y = y }
    end)

    arrow:Hide()

    return arrow
end

Navigation.BuildArrow = BuildArrow

-- The arrow's palette.
--
-- ON_COURSE is the blue of the waypoint marker in the addon's own logo,
-- sampled from it rather than guessed: #5DD2FB. Because you are pointed at
-- your target most of the time, this is the colour the arrow actually wears,
-- which is what makes it read as part of the addon rather than as generic
-- navigation furniture.
--
-- The texture is greyscale for exactly this reason: tinting is a multiply, so
-- a pre-coloured blue arrow could never turn amber, and the bearing feedback
-- would be lost to make one screenshot prettier.
Navigation.colors = {
    ON_COURSE = { 0.365, 0.824, 0.984 },   -- #5DD2FB, the logo's marker blue
    DRIFTING  = { 1.000, 0.780, 0.310 },   -- the logo's gold, for "turn a bit"
    AWAY      = { 0.960, 0.420, 0.380 },   -- you are walking the wrong way
    UNKNOWN   = { 0.600, 0.640, 0.680 },   -- no bearing available
}

-- Blue when you are walking toward it, gold when you are drifting, red when
-- you are walking away. The single most useful thing an arrow does, and it
-- costs one comparison.
function Navigation.BearingColor(relative)
    local palette = Navigation.colors

    if not relative then
        return palette.UNKNOWN[1], palette.UNKNOWN[2], palette.UNKNOWN[3]
    end

    local off = math.abs(relative)

    if off < 0.35 then
        return palette.ON_COURSE[1], palette.ON_COURSE[2], palette.ON_COURSE[3]
    end

    if off < 1.2 then
        return palette.DRIFTING[1], palette.DRIFTING[2], palette.DRIFTING[3]
    end

    return palette.AWAY[1], palette.AWAY[2], palette.AWAY[3]
end

-- Recomputes the arrow. Split out so the harness can drive it without a frame.
function Navigation.Compute()
    if not target then
        return nil
    end

    local mapID, playerX, playerY = CN.GetPlayerPosition()

    if not mapID or not playerX or not playerY then
        return { state = "NO_POSITION" }
    end

    if mapID ~= target.mapID then
        return {
            state = "WRONG_MAP",
            zone  = target.zone or Blizzard.GetMapName(target.mapID),
        }
    end

    local facing = GetPlayerFacing and GetPlayerFacing() or nil

    local relative = Navigation.RelativeBearing(playerX, playerY,
        target.x, target.y, facing)

    local yards = Navigation.DistanceYards(mapID, playerX, playerY,
        target.x, target.y)

    local within = yards and yards <= Navigation.arrivalYards

    -- ARRIVAL DOES NOT LATCH.
    --
    -- REPORTED FROM LIVE PLAY, TWICE: "I walked past it and the arrow did not
    -- turn around." `target.arrived` was set once and never cleared, so a
    -- player who walked through the destination and kept going was, as far as
    -- this code was concerned, still arrived -- forever.
    --
    -- Walking back out of the arrival radius is the player un-arriving. Say
    -- so, so that tracking resumes and the arrow turns round.
    if target.arrived and yards and yards > (Navigation.arrivalYards * 2) then
        target.arrived = false

        DebugPrint("Left the destination; tracking it again.")
    end

    return {
        state    = within and "ARRIVED" or "TRACKING",
        relative = relative,
        yards    = yards,
        facing   = facing,
        within   = within,
    }
end

------------------------------------------------------------
-- SELF-CORRECTION
------------------------------------------------------------

-- Evidence that the facing convention is backwards.
--
-- If you are lined up with the arrow and moving, the distance must shrink. If
-- it grows instead, the arrow is pointing at the reciprocal. That is not a
-- guess -- it is the definition of the arrow being wrong, observed directly.
--
-- Several consecutive samples are required so that walking backwards, a
-- flight path, or a teleport cannot trigger it.
local calibration = {
    lastDistance = nil,
    growing      = 0,
    corrected    = false,
}

Navigation.calibrationSamples = 4

function Navigation.ResetCalibration()
    calibration.lastDistance = nil
    calibration.growing      = 0
end

function Navigation.NoteObservation(relative, yards)
    -- Only meaningful while genuinely lined up: if you are not following the
    -- arrow, the distance says nothing about whether the arrow is right.
    if not relative or not yards or math.abs(relative) > 0.3 then
        Navigation.ResetCalibration()
        return false
    end

    local previous = calibration.lastDistance

    calibration.lastDistance = yards

    if not previous then
        return false
    end

    local delta = yards - previous

    -- Ignore standing still and ignore jumps far too large to be walking,
    -- which are loading screens rather than movement.
    if math.abs(delta) < 0.5 or math.abs(delta) > 200 then
        return false
    end

    if delta > 0 then
        calibration.growing = calibration.growing + 1
    else
        calibration.growing = 0
    end

    if calibration.growing < Navigation.calibrationSamples then
        return false
    end

    calibration.growing = 0

    if calibration.corrected then
        -- Already flipped once this session and still wrong: flipping back and
        -- forth forever would be worse than leaving it alone.
        return false
    end

    calibration.corrected = true

    Navigation.SetFacingSign(-Navigation.FacingSign())

    Print("The arrow was pointing the wrong way. Corrected, and remembered.")
    DebugPrint("Facing sign is now " .. Navigation.FacingSign() .. ".")

    return true
end

-- Wipe what the arrow is showing.
--
-- Hiding a frame does not clear it. The rotation, the colour and the distance
-- stay exactly as they were, so an arrow hidden while pointing north-east at
-- "10 yd" is still pointing north-east at "10 yd" the moment anything shows
-- it again -- a stale claim about a destination that is no longer being
-- tracked. Costs nothing to reset; costs the player's trust not to.
local function Blank()
    if not arrow then
        return
    end

    if arrow.texture then
        arrow.texture:SetRotation(0)
        arrow.texture:SetVertexColor(Navigation.BearingColor(nil))
    end

    if arrow.distance then
        arrow.distance:SetText("")
    end

    if arrow.label then
        arrow.label:SetText("")
    end
end

Navigation.Blank = Blank

local function Refresh()
    if not arrow then
        return
    end

    if not target or not Navigation.IsArrowEnabled() then
        Blank()
        arrow:Hide()
        return
    end

    local state = Navigation.Compute()

    if not state then
        arrow:Hide()
        return
    end

    arrow:Show()

    arrow.label:SetText(target.title or "Destination")

    if state.state == "WRONG_MAP" then
        arrow.texture:SetRotation(0)
        arrow.texture:SetVertexColor(Navigation.BearingColor(nil))
        arrow.distance:SetText("|cff999999" .. (state.zone or "another zone") .. "|r")
        return
    end

    if state.state == "NO_POSITION" then
        arrow.texture:SetVertexColor(Navigation.BearingColor(nil))
        arrow.distance:SetText("|cff999999no position|r")
        return
    end

    if state.relative then
        -- SetRotation turns counter-clockwise; the relative bearing is
        -- clockwise, hence the negation.
        arrow.texture:SetRotation(-state.relative)
    end

    arrow.texture:SetVertexColor(Navigation.BearingColor(state.relative))

    arrow.distance:SetText(Navigation.FormatDistance(state.yards))

    -- Watch whether following the arrow actually works.
    Navigation.NoteObservation(state.relative, state.yards)

    if state.state == "ARRIVED" then
        Navigation.Arrive()
    end
end

Navigation.Refresh = Refresh

function Navigation.Arrive()
    if not target or target.arrived then
        return
    end

    target.arrived = true

    local reached = tostring(target.title or "destination")

    Print("Arrived: " .. reached)

    -- Arrival is exactly the moment auto-advance was designed for; before
    -- this, it could only re-point on a timer or an event.
    if CN.IsAutoWaypointEnabled and CN.IsAutoWaypointEnabled() then
        CN.AutoAdvance("arrival", true)

        -- SAY SO WHEN THE ARROW NOW MEANS SOMETHING ELSE.
        --
        -- Auto-advance re-points at the next thing, and the arrow looks
        -- absolutely identical doing it: same shape, same blue, still ahead
        -- of you. A player who walks through a destination and sees the arrow
        -- still pointing forward reasonably concludes it failed to turn
        -- round, when in fact it is now pointing at something else. That was
        -- reported as a bug twice, and it was a communication failure rather
        -- than a maths one.
        local now = target and tostring(target.title or "destination")

        if now and now ~= reached then
            Print("Now heading to: |cffffff00" .. now .. "|r")
        end
    else
        Navigation.Clear()
    end
end

------------------------------------------------------------
-- TICKER
------------------------------------------------------------

-- Ten times a second. A rotating arrow needs to feel continuous; recomputing
-- world positions every frame does not.
Navigation.tickSeconds = 0.1

function Navigation.StartTicker()
    if ticker or not C_Timer or not C_Timer.NewTicker then
        return
    end

    ticker = C_Timer.NewTicker(Navigation.tickSeconds, function()
        local ok, err = pcall(Refresh)

        if not ok then
            DebugPrint("Arrow refresh failed: " .. tostring(err))
        end
    end)
end

function Navigation.StopTicker()
    if ticker then
        ticker:Cancel()
        ticker = nil
    end
end

------------------------------------------------------------
-- WAYPOINT PROVIDER
------------------------------------------------------------

local provider = {}

function provider.IsAvailable()
    -- Native navigation needs nothing but the map API, which is why it is the
    -- default: it is the only provider that cannot be missing.
    return C_Map ~= nil and C_Map.GetBestMapForUnit ~= nil
end

function provider.SetWaypoint(mapID, x, y, title)
    target = {
        mapID = mapID,
        x     = x,
        y     = y,
        title = title,
        zone  = Blizzard.GetMapName(mapID),
        setAt = time(),
    }

    Navigation.ResetCalibration()

    BuildArrow()
    Navigation.StartTicker()
    Refresh()

    -- Also drop a map pin, so the destination is visible on the world map and
    -- not only in front of the player.
    if C_Map.SetUserWaypoint and UiMapPoint and UiMapPoint.CreateFromCoordinates then
        local ok = pcall(function()
            C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(mapID, x, y))
        end)

        if ok and C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
            pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
        end
    end

    return true
end

function provider.ClearAll()
    Navigation.Clear()
end

function Navigation.Clear()
    target = nil

    if arrow then
        Blank()
        arrow:Hide()
    end

    Navigation.StopTicker()

    if C_Map and C_Map.ClearUserWaypoint then
        pcall(C_Map.ClearUserWaypoint)
    end
end

-- Priority 5: ahead of TomTom's 10. The addon is self-contained now, and a
-- player who prefers TomTom's arrow can say so with /cn nav tomtom.
CN.RegisterWaypointProvider("Native", provider, 5)

Navigation.provider = provider

------------------------------------------------------------
-- PROVIDER PREFERENCE
------------------------------------------------------------

-- Overrides the priority order. Stored rather than inferred, because
-- "whichever addon happens to be loaded" is not a preference.
function Navigation.SetPreference(name)
    local settings = Settings()

    if name == "auto" or name == nil then
        settings.navigation = nil
        return true, "automatic"
    end

    local key = string.lower(name)

    local known = {
        native  = "Native",
        tomtom  = "TomTom",
        blizzard = "Blizzard",
    }

    if not known[key] then
        return false, nil
    end

    settings.navigation = known[key]

    return true, known[key]
end

function Navigation.Preference()
    return Settings().navigation
end

-- Consulted by Routing before the priority order.
function CN.GetPreferredWaypointProvider()
    local preferred = Navigation.Preference()

    if not preferred then
        return nil
    end

    local candidate = CN.waypointProviders[preferred]

    if candidate and candidate.IsAvailable and candidate.IsAvailable() then
        return candidate, preferred
    end

    return nil
end

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "arrow",
    args    = "[on or off]",
    order   = 40,
    help    = "Toggle the on-screen navigation arrow.",
    handler = function(args)
        local settings = Settings()

        args = string.lower(CN.Trim(args or ""))

        if args == "on" then
            settings.arrow = true
        elseif args == "off" then
            settings.arrow = false
        elseif args ~= "" then
            Print("Usage: /cn arrow [on or off]")
            return
        else
            settings.arrow = (settings.arrow == false)
        end

        Print("Navigation arrow: " .. CN.YesNo(Navigation.IsArrowEnabled()))

        if Navigation.IsArrowEnabled() then
            BuildArrow()
            Refresh()
        elseif arrow then
            arrow:Hide()
        end

        if not target then
            Print("|cff999999Nothing is being tracked. |cffffff00/cn go|r "
                .. "points it at something.|r")
        end
    end,
}

CN:RegisterCommand{
    name    = "calibrate",
    aliases = { "flip" },
    order   = 43,
    help    = "Flip the navigation arrow if it points the wrong way.",
    handler = function()
        Navigation.SetFacingSign(-Navigation.FacingSign())
        Navigation.ResetCalibration()

        Print("Arrow direction flipped and remembered.")
        Print("|cff999999Whether GetPlayerFacing counts clockwise or "
            .. "counter-clockwise is a client convention, so the addon "
            .. "normally works this out on its own by watching whether "
            .. "following the arrow shortens the distance.|r")

        Navigation.Refresh()
    end,
}

CN:RegisterCommand{
    name    = "nav",
    args    = "[auto, native, tomtom or blizzard]",
    order   = 41,
    help    = "Choose which navigation provider to use.",
    handler = function(args)
        args = CN.Trim(args or "")

        if args ~= "" then
            local ok, resolved = Navigation.SetPreference(args)

            if not ok then
                Print("Not a navigation provider: " .. args)
                Print("|cff999999Choose auto, native, tomtom or blizzard.|r")
                return
            end

            Print("Navigation provider: |cffffff00" .. tostring(resolved) .. "|r")
        end

        local preference = Navigation.Preference()

        Print("Preference: " .. (preference or "automatic"))

        local active, name = CN.GetWaypointProvider()

        Print("Currently using: " .. (active and name or "none available"))

        Print("Available:")

        for _, entry in ipairs(CN.waypointOrder) do
            local candidate = CN.waypointProviders[entry.name]

            local available = candidate and candidate.IsAvailable
                and candidate.IsAvailable()

            Print("  " .. entry.name .. " " .. CN.YesNo(available)
                .. " |cff999999priority " .. entry.priority .. "|r")
        end
    end,
}

CN:RegisterCommand{
    name    = "where am i",
    aliases = { "here" },
    order   = 42,
    help    = "Report your position and what is being tracked.",
    handler = function()
        local mapID, x, y = CN.GetPlayerPosition()

        if not mapID then
            Print("Your position is not available right now.")
            return
        end

        Print("You are in " .. tostring(Blizzard.GetMapName(mapID))
            .. (x and y and string.format(" at %.1f, %.1f", x * 100, y * 100) or ""))

        if not target then
            Print("Nothing is being tracked.")
            return
        end

        local state = Navigation.Compute()

        Print("Tracking: |cffffff00" .. tostring(target.title) .. "|r in "
            .. tostring(target.zone))

        if state and state.state == "WRONG_MAP" then
            Print("  |cff999999It is in another zone.|r")
        elseif state then
            Print("  " .. Navigation.FormatDistance(state.yards)
                .. (state.relative and string.format(" |cff999999%d degrees off|r",
                    math.floor(math.abs(math.deg(state.relative)) + 0.5)) or ""))
        end
    end,
}

------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------

CN:OnLogin(function()
    if Navigation.IsArrowEnabled() then
        BuildArrow()
    end
end)

-- Zone changes can move you onto the target's map, or off it.
CN:RegisterEvent("ZONE_CHANGED_NEW_AREA", function()
    if target then
        Refresh()
    end
end)

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
