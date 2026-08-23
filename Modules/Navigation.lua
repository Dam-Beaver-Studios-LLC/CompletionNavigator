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
--
-- 0.40.0 added a second, better source of that evidence, because the first
-- one only fires when the player happens to be lined up with a target and
-- walking. When you move at all, the direction you moved IS the direction you
-- were facing, and only one of the two conventions agrees with that. See
-- NoteMotion below. Strafing and walking backwards agree with neither, so
-- they are discarded rather than voted on.
--
-- 0.40.0 also fixed an error that was present in every zone: angles were
-- taken from raw map coordinates, which normalize to 0-1 regardless of the
-- shape of the ground, so every bearing was stretched by the zone's aspect
-- ratio. See MapScale.
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

-- MAP COORDINATES ARE NOT SQUARE, AND ANGLES MEASURED IN THEM ARE WRONG.
--
-- Every map normalizes to 0-1 in both axes regardless of the shape of the
-- ground it covers. A zone 3,000 yards wide and 2,000 yards tall therefore
-- stretches its vertical axis by half again, and an angle computed from raw
-- map deltas is distorted by exactly that ratio: a target genuinely 45
-- degrees off reads as 56 degrees in that zone, and worse in a long one.
--
-- The arrow was doing that in every zone in the game. It is not enough to be
-- noticed as "the arrow is broken" -- it is enough to be noticed as "the
-- arrow is sloppy", and both complaints about the arrow so far have come with
-- "it doesn't point quite right" attached.
--
-- The client will tell us the real width and height in yards, so ask once per
-- map and scale the deltas into yards before taking the angle.
local mapScales = {}

-- Returns yards-per-map-unit on each axis, and a THIRD value saying whether
-- that is a measurement or a shrug.
--
-- THE SENTINEL WAS INDISTINGUISHABLE FROM AN ANSWER.
--
-- `1, 1` means "no distortion", which is the right shrug for the bearing
-- maths -- that only ever uses the RATIO of the two, and a ratio of one is
-- exactly "assume the map is square". But routing asks this for an ABSOLUTE
-- number of yards, and `1` is not a number of yards; it leaves distances in
-- map units, where the whole map is one unit across. `UseMapScale` in
-- Routing.lua validated the answer with `scaleX > 0`, which `1` satisfies, so
-- its 2000-yard fallback could never fire on the one path it was written for:
-- a real map the client would not convert during a loading screen.
--
-- Callers that want a ratio keep ignoring the third value. Callers that want
-- yards must check it.
function Navigation.MapScale(mapID)
    if not mapID then
        return 1, 1, false
    end

    local cached = mapScales[mapID]

    if cached then
        return cached[1], cached[2], true
    end

    -- A tenth of the map, measured across the middle, where a map is least
    -- likely to be doing something strange at its edges.
    local span = 0.1

    local xYards = Navigation.DistanceYards(mapID, 0.45, 0.5, 0.45 + span, 0.5)
    local yYards = Navigation.DistanceYards(mapID, 0.5, 0.45, 0.5, 0.45 + span)

    if not xYards or not yYards or xYards <= 0 or yYards <= 0 then
        -- Do NOT cache a failure. A map the client would not convert during a
        -- loading screen will convert a second later, and caching 1,1 would
        -- keep the distortion for the rest of the session.
        return 1, 1, false
    end

    xYards = xYards / span
    yYards = yYards / span

    mapScales[mapID] = { xYards, yYards }

    return xYards, yYards, true
end

function Navigation.ForgetMapScales()
    mapScales = {}
end

function Navigation.RelativeBearing(playerX, playerY, targetX, targetY, facing, sign, mapID)
    if not (playerX and playerY and targetX and targetY and facing) then
        return nil
    end

    local scaleX, scaleY = Navigation.MapScale(mapID)

    local dx = (targetX - playerX) * scaleX
    local dy = (targetY - playerY) * scaleY

    if dx == 0 and dy == 0 then
        return 0
    end

    -- -dy because map y grows southward.
    local bearing = CN.Atan2(dx, -dy)

    local relative = bearing - (facing * (sign or Navigation.FacingSign()))

    -- Normalize to (-pi, pi] so "how far off am I" is a small number.
    --
    -- THROUGH THE SHIM, WHICH IS WHAT THE SHIM IS FOR.
    --
    -- Core.lua defines `CN.Mod` as the floored modulo -- "if a construct
    -- means two things, the addon uses neither directly; it uses one of
    -- these" -- and then the one place in the addon that wraps an angle did
    -- it with two unbounded `while` loops instead. So the rule was enforced
    -- nowhere and the shim had no call sites at all, which is how a
    -- compatibility guard quietly stops being one.
    --
    -- The loops were also unbounded: a non-finite bearing spins the client.
    -- This is O(1) and it cannot.
    local full = 2 * math.pi

    relative = CN.Mod(relative + math.pi, full) - math.pi

    -- CN.Mod's range is [0, full), so the line above lands in [-pi, pi).
    -- The addon's convention is (-pi, pi] -- exactly antipodal must read as
    -- "behind you", not "behind you, negative".
    if relative == -math.pi then
        relative = math.pi
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
        return CN.L["distance unknown"]
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

    -- OUTLINED, BECAUSE THIS IS DRAWN OVER THE GAME WORLD.
    --
    -- Both of these were bare font objects with the standard one-pixel drop
    -- shadow, which is enough over a dark UI panel and is not enough over
    -- Northrend snow, Uldum sand, Bastion's marble or a spell effect. The
    -- distance is the number a player reads WHILE RUNNING, which is exactly
    -- when the background is moving and unpredictable.
    CN.Outline(arrow.label, 12, "BODY")
    CN.Outline(arrow.distance, 17, "PRIMARY")

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
-- Derived from the addon's palette rather than restating its numbers. The
-- three that mean something -- on course, turn a bit, wrong way -- are the
-- brand blue, the accent gold and the bad red, which is what they always
-- were; writing them out again is how the two drifted apart in the first
-- place.
Navigation.colors = {
    ON_COURSE = CN.RGB.BRAND,
    DRIFTING  = CN.RGB.ACCENT,
    AWAY      = CN.RGB.BAD,

    -- Not a palette role: this is the absence of a bearing, and it must not
    -- read as any of the three states.
    UNKNOWN   = { 0.600, 0.640, 0.680 },
}

-- THE PALETTE ITSELF, NOT ONLY A LABEL BESIDE IT.
--
-- Colourblind mode has until now added a word next to the arrow, which
-- satisfies "no information carried by colour alone" and leaves the colours
-- themselves as bad as they were. Gold against red is the single worst pair
-- for the commonest form of colour blindness -- and it is the pair carrying
-- "drifting" against "walking away", which is the distinction the arrow
-- exists to make.
--
-- Blue and orange instead, which separate under every common form, with
-- white for on-course so the three differ in lightness as well as in hue.
-- Somebody who cannot tell the hues apart can still tell these apart.
-- Chosen so that the three differ by at least 0.27 in relative luminance --
-- checked by the suite, not by eye. Lightness is what survives when hue does
-- not.
Navigation.colorblindColors = {
    ON_COURSE = { 0.980, 0.980, 0.980 },   -- near-white, luminance 0.98
    DRIFTING  = { 0.400, 0.760, 1.000 },   -- light blue,  luminance 0.70
    AWAY      = { 0.780, 0.340, 0.020 },   -- dark orange, luminance 0.41
    UNKNOWN   = { 0.520, 0.540, 0.560 },
}

function Navigation.Palette()
    local hud = CN:GetModule("Hud")

    if hud and hud.IsColourblind and hud.IsColourblind() then
        return Navigation.colorblindColors
    end

    return Navigation.colors
end

-- Blue when you are walking toward it, gold when you are drifting, red when
-- you are walking away. The single most useful thing an arrow does, and it
-- costs one comparison.
function Navigation.BearingColor(relative)
    local palette = Navigation.Palette()

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
-- The player's position expressed on a specific map, or nil.
--
-- Works for any map that can describe where the player is standing -- a zone
-- while you are inside one of its buildings, for instance -- and returns nil
-- when it genuinely cannot, which is the honest answer for another continent.
function Navigation.PlayerPositionOnMap(mapID)
    if not mapID or not C_Map or not C_Map.GetPlayerMapPosition then
        return nil
    end

    local ok, position = pcall(C_Map.GetPlayerMapPosition, mapID, "player")

    if not ok or not position then
        return nil
    end

    local x, y

    if position.GetXY then
        local gotXY, gx, gy = pcall(position.GetXY, position)

        if gotXY then
            x, y = gx, gy
        end
    end

    x = x or position.x
    y = y or position.y

    if not x or not y then
        return nil
    end

    -- The client answers (0, 0) for a map that cannot place you, which is a
    -- real coordinate on every map and therefore indistinguishable from a
    -- corner. Treated as "cannot say", because a corner is a far less likely
    -- place to be standing than nowhere.
    if x == 0 and y == 0 then
        return nil
    end

    return { x = x, y = y }
end

function Navigation.Compute()
    if not target then
        return nil
    end

    local mapID, playerX, playerY = CN.GetPlayerPosition()

    if not mapID or not playerX or not playerY then
        return { state = "NO_POSITION" }
    end

    -- THE MAP UNDER YOUR FEET IS NOT THE MAP THE TARGET IS ON.
    --
    -- `GetBestMapForUnit` answers with the most SPECIFIC map containing you:
    -- step into a building, a cave, an inn or a city district and it changes,
    -- even though you have moved thirty yards. The arrow compared that to the
    -- target's map, found them different, and gave up -- announcing "another
    -- zone" while standing next to the destination.
    --
    -- This is the same defect that made available quests invisible in a city
    -- in 0.27.0, in a different file. The fix is the same shape: ask the
    -- client for the player's position expressed on the map that matters,
    -- rather than assuming the two maps are the same one.
    local onTargetMap = false

    if mapID ~= target.mapID then
        local translated = Navigation.PlayerPositionOnMap(target.mapID)

        if translated then
            mapID   = target.mapID
            playerX = translated.x
            playerY = translated.y

            onTargetMap = true
        else
            -- Genuinely somewhere the target's map cannot describe --
            -- another continent, or an instance.
            return {
                state = "WRONG_MAP",
                zone  = target.zone or Blizzard.GetMapName(target.mapID),
            }
        end
    end

    local facing = GetPlayerFacing and GetPlayerFacing() or nil

    local relative = Navigation.RelativeBearing(playerX, playerY,
        target.x, target.y, facing, nil, mapID)

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
        mapID    = mapID,
        playerX  = playerX,
        playerY  = playerY,
        translated = onTargetMap,
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

-- WHICH WAY DOES GetPlayerFacing COUNT?
--
-- Everything the arrow does rests on one unverified assumption: that the
-- number the client gives for "facing" grows in the same rotational direction
-- as the bearing computed from map coordinates. If it does not, the arrow is
-- not backwards -- it is MIRRORED, wrong by twice your facing, which looks
-- right when you face north and badly wrong when you face east. That is a
-- much better description of what was reported twice than "backwards" was.
--
-- The old evidence for it was indirect: follow the arrow, and if the distance
-- grows, the arrow is wrong. That only fires when the player happens to be
-- lined up and walking, and cannot fire at all when nothing is targeted.
--
-- This is direct evidence instead, and it needs no target and no cooperation:
-- when you MOVE, the direction you moved is the direction you were facing.
-- Compute the bearing of your own movement, compare it against your facing
-- under both conventions, and only one of them can agree. Strafing and
-- walking backwards agree with neither, so they are discarded rather than
-- voted on -- which is what makes this safe to run continuously.
local motion = {
    mapID   = nil,
    x       = nil,
    y       = nil,
    agree   = 0,
    against = 0,
    samples = 0,
    verdict = nil,
}

-- Consecutive agreeing samples before the sign is changed. At ten samples a
-- second this is a fraction of a second of walking, but every one of them has
-- to agree, and one strafe resets the count.
Navigation.motionSamples   = 6

-- Below this the player is standing still; above it, a loading screen, a
-- flight path or a teleport.
Navigation.motionMinYards  = 1.5
Navigation.motionMaxYards  = 60

-- How close a hypothesis has to be to count as agreeing, and how far the
-- other one has to be to count as excluded.
Navigation.motionAgree     = math.rad(25)
Navigation.motionExclude   = math.rad(60)

local function Normalize(angle)
    while angle > math.pi do
        angle = angle - (2 * math.pi)
    end

    while angle <= -math.pi do
        angle = angle + (2 * math.pi)
    end

    return angle
end

Navigation.NormalizeAngle = Normalize

function Navigation.ResetMotion()
    motion.mapID   = nil
    motion.x       = nil
    motion.y       = nil
    motion.agree   = 0
    motion.against = 0
end

function Navigation.MotionState()
    return {
        samples = motion.samples,
        agree   = motion.agree,
        against = motion.against,
        verdict = motion.verdict,
        sign    = Navigation.FacingSign(),
    }
end

-- Returns the sign the evidence supports, or nil when this sample said
-- nothing. Separated from the sampling so it can be tested as arithmetic.
function Navigation.SignFromMotion(moved, facing)
    if not moved or not facing then
        return nil
    end

    local withPlus  = math.abs(Normalize(moved - facing))
    local withMinus = math.abs(Normalize(moved + facing))

    if withPlus <= Navigation.motionAgree and withMinus >= Navigation.motionExclude then
        return 1
    end

    if withMinus <= Navigation.motionAgree and withPlus >= Navigation.motionExclude then
        return -1
    end

    -- Facing north or south makes both conventions agree, so the sample
    -- cannot distinguish them and must not be counted as evidence for the one
    -- we happen to be using.
    return nil
end

function Navigation.NoteMotion()
    if not GetPlayerFacing then
        return nil
    end

    if UnitOnTaxi and UnitOnTaxi("player") then
        Navigation.ResetMotion()
        return nil
    end

    local mapID, x, y = CN.GetPlayerPosition()

    if not mapID or not x or not y then
        Navigation.ResetMotion()
        return nil
    end

    local previousMap, previousX, previousY = motion.mapID, motion.x, motion.y

    motion.mapID, motion.x, motion.y = mapID, x, y

    if previousMap ~= mapID or not previousX then
        return nil
    end

    local scaleX, scaleY = Navigation.MapScale(mapID)

    local dx = (x - previousX) * scaleX
    local dy = (y - previousY) * scaleY

    local yards = math.sqrt((dx * dx) + (dy * dy))

    if yards < Navigation.motionMinYards then
        -- Standing still is not evidence against anything; leave the tally.
        return nil
    end

    if yards > Navigation.motionMaxYards then
        Navigation.ResetMotion()
        return nil
    end

    local facing = GetPlayerFacing()

    if not facing then
        return nil
    end

    local moved = CN.Atan2(dx, -dy)

    local supported = Navigation.SignFromMotion(moved, facing)

    if not supported then
        return nil
    end

    motion.samples = motion.samples + 1

    if supported == Navigation.FacingSign() then
        motion.agree   = motion.agree + 1
        motion.against = 0

        -- "corrected" is sticky. Once the sign has been changed this session,
        -- every subsequent sample agrees with it by construction, and
        -- overwriting the verdict with "confirmed" would erase the only
        -- record that anything was ever wrong -- which is the single most
        -- useful line in a bug report about the arrow.
        if motion.verdict ~= "corrected" then
            motion.verdict = "confirmed"
        end

        return nil
    end

    motion.against = motion.against + 1
    motion.agree   = 0

    if motion.against < Navigation.motionSamples then
        return nil
    end

    motion.against = 0
    motion.verdict = "corrected"

    Navigation.SetFacingSign(supported)
    Navigation.ResetCalibration()

    Print("The arrow was reading your facing backwards. Corrected, and "
        .. "remembered.")
    DebugPrint("Facing sign is now " .. Navigation.FacingSign()
        .. ", from " .. motion.samples .. " movement samples.")

    return supported
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
    Navigation.ResetSmoothing()
    Navigation.ResetDistanceSmoothing()

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

-- SMOOTHING.
--
-- The arrow recomputes ten times a second and snapped straight to each new
-- bearing, so a player turning on the spot saw it step rather than sweep. The
-- underlying number is right either way -- this is only about whether it
-- reads as an instrument or as a slideshow.
--
-- Snaps rather than sweeps when the change is large: an arrow that eases
-- through 170 degrees is pointing at nothing at all for a quarter of a second,
-- which is worse than a jump. Passing a destination and turning around is
-- exactly that case, and it is the one complaint this addon has actually
-- received about the arrow.
Navigation.smoothingFactor  = 0.35
Navigation.smoothingSnapRad = math.rad(90)

local smoothed = nil

function Navigation.ResetSmoothing()
    smoothed = nil
end

function Navigation.Smooth(bearing)
    if not bearing then
        return bearing
    end

    if not smoothed then
        smoothed = bearing

        return smoothed
    end

    local delta = Normalize(bearing - smoothed)

    if math.abs(delta) >= Navigation.smoothingSnapRad then
        smoothed = bearing

        return smoothed
    end

    smoothed = Normalize(smoothed + (delta * Navigation.smoothingFactor))

    return smoothed
end

-- Distance, eased. Snaps on a large jump for the same reason the rotation
-- does: a teleport, a flight path or a loading screen is a real change and
-- easing through it would show a number that was never true.
Navigation.distanceSmoothing = 0.5
Navigation.distanceSnapYards = 80

local smoothedDistance = nil

function Navigation.ResetDistanceSmoothing()
    smoothedDistance = nil
end

function Navigation.SmoothDistance(yards)
    if not yards then
        smoothedDistance = nil

        return nil
    end

    if not smoothedDistance
        or math.abs(yards - smoothedDistance) >= Navigation.distanceSnapYards then

        smoothedDistance = yards

        return smoothedDistance
    end

    smoothedDistance = smoothedDistance
        + ((yards - smoothedDistance) * Navigation.distanceSmoothing)

    return smoothedDistance
end

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

    arrow.label:SetText(target.title or CN.L["Destination"])

    if state.state == "WRONG_MAP" then
        arrow.texture:SetRotation(0)
        arrow.texture:SetVertexColor(Navigation.BearingColor(nil))
        arrow.distance:SetText("|cff8a8f96" .. (state.zone or CN.L["another zone"]) .. "|r")
        return
    end

    if state.state == "NO_POSITION" then
        arrow.texture:SetVertexColor(Navigation.BearingColor(nil))
        arrow.distance:SetText("|cff8a8f96" .. CN.L["no position"] .. "|r")
        return
    end

    if state.relative then
        -- SetRotation turns counter-clockwise; the relative bearing is
        -- clockwise, hence the negation.
        arrow.texture:SetRotation(-Navigation.Smooth(state.relative))
    end

    arrow.texture:SetVertexColor(Navigation.BearingColor(state.relative))

    -- The distance figure jumped the way the rotation used to, because it is
    -- recomputed from a position the client rounds. Same treatment, and a
    -- much lower factor: distance should look steady, not sluggish.
    local distanceText = Navigation.FormatDistance(
        Navigation.SmoothDistance(state.yards))

    -- NO INFORMATION CARRIED BY COLOUR ALONE.
    --
    -- The arrow's whole language is colour -- blue on course, amber drifting,
    -- red walking away -- which is precisely the design that fails a
    -- colourblind player. In that mode the same fact is written next to the
    -- distance, where it survives the colours being indistinguishable.
    local hud = CN:GetModule("Hud")

    if hud and hud.IsColourblind() then
        distanceText = distanceText .. " |cfff2f4f6"
            .. hud.BearingWord(state.relative) .. "|r"
    end

    arrow.distance:SetText(distanceText)

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

    Print(string.format(CN.L["Arrived: %s"], reached))

    -- The other moment `/cn cues` was written for and never wired to.
    local follow = CN:GetModule("Follow")

    if follow and follow.Cue then
        pcall(follow.Cue, "arrival")
    end

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
            Print(string.format(CN.L["Now heading to: %s"],
                "|cffffc74f" .. now .. "|r"))
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
        -- Before drawing, and regardless of what is being tracked: the
        -- player's own movement is the only direct evidence of which way the
        -- client counts facing, and it is free to read.
        pcall(Navigation.NoteMotion)

        local ok, err = pcall(Refresh)

        if not ok then
            DebugPrint("Arrow refresh failed: " .. tostring(err))

            local errors = CN:GetModule("Errors")

            if errors then
                errors.Record("arrow refresh", err)
            end
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
-- DIAGNOSIS
------------------------------------------------------------

-- Everything the arrow is thinking, in one command.
--
-- Written because a player reported the arrow misbehaving twice, and both
-- times the only evidence available was a description in prose. I guessed
-- from it twice and was wrong twice. Prose is a bad instrument; this is a
-- better one.
--
-- Reports what is being tracked, where the client says you are, which way it
-- says you are facing, every intermediate value in the bearing, what was
-- actually applied to the texture, and which of the several things that can
-- silently change the destination is switched on.
function Navigation.Diagnose()
    local report = {}

    local function add(label, value)
        table.insert(report, { label = label, value = tostring(value) })
    end

    if not target then
        add("target", "none -- nothing is being tracked")

        return report
    end

    add("target", tostring(target.title or "untitled"))
    add("target map", string.format("%s (%s)",
        tostring(target.mapID), tostring(target.zone or "?")))
    add("target coords", string.format("%.1f, %.1f",
        (target.x or 0) * 100, (target.y or 0) * 100))
    add("marked arrived", target.arrived and "yes" or "no")

    local bestMap, px, py = CN.GetPlayerPosition()

    add("your map", tostring(bestMap))
    add("your coords", px and string.format("%.1f, %.1f", px * 100, py * 100)
        or "the client will not say")

    local state = Navigation.Compute() or {}

    add("state", tostring(state.state))

    if state.translated then
        add("translation", "your position was expressed on the target's map")
    end

    add("facing (raw)", state.facing
        and string.format("%.1f deg", math.deg(state.facing)) or "nil")
    local motionState = Navigation.MotionState()

    add("facing sign", tostring(Navigation.FacingSign())
        .. " (flips if the arrow ever pointed backwards)")
    add("facing evidence", motionState.samples == 0
        and "none yet -- walk a few yards with the arrow up"
        or string.format("%d movement samples, %s",
            motionState.samples, tostring(motionState.verdict)))

    local scaleX, scaleY = Navigation.MapScale(state.mapID or bestMap)

    add("map scale", string.format("%.0f x %.0f yards across", scaleX, scaleY))

    add("relative bearing", state.relative
        and string.format("%.1f deg", math.deg(state.relative))
        or "nil -- no bearing could be computed")

    if state.relative then
        add("rotation applied", string.format("%.1f deg", math.deg(-state.relative)))

        local off = math.abs(state.relative)

        add("colour", off < 0.35 and "BLUE (on course)"
            or off < 1.2 and "GOLD (drifting)"
            or "RED (walking away)")
    end

    add("distance", Navigation.FormatDistance(state.yards))
    add("arrival radius", Navigation.arrivalYards .. " yd")

    add("provider", tostring(select(2, CN.GetWaypointProvider())))

    -- The two settings that can change what the arrow means without the
    -- player doing anything.
    add("auto-advance", (CN.IsAutoWaypointEnabled and CN.IsAutoWaypointEnabled())
        and "ON -- arriving re-points the arrow at the next thing"
        or "off")

    local follow = CN:GetModule("Follow")

    add("follow mode", (follow and follow.active) and "ON" or "off")

    return report
end

CN:RegisterCommand{
    name    = "navdiag",
    aliases = { "arrowdiag" },
    order   = 30,
    help    = "Show exactly what the navigation arrow is doing and why.",
    handler = function()
        local report = Navigation.Diagnose()

        Print("Arrow diagnosis:")

        for _, row in ipairs(report) do
            Print(string.format("  |cff8a8f96%-18s|r %s", row.label, row.value))
        end

        -- THE ONE THING THAT MAKES EVERY OTHER LINE HERE UNTRUSTWORTHY.
        --
        -- A migration that threw leaves the saved data in neither the old
        -- shape nor the new one, and everything below reads that data. It
        -- used to be a single line at login and nothing else; this is where
        -- the player was told to look, so this is where it has to appear.
        local failure = (CN.db and CN.db.migrationFailure) or CN.migrationFailure

        if type(failure) == "table" then
            Print(CN.Bad("Your saved data did not finish upgrading."))
            Print("  " .. CN.Muted("step " .. tostring(failure.version)
                .. ": " .. tostring(failure.error)))
            Print("  " .. CN.Muted("Everything above is read from that data. "
                .. "Copy this line into a bug report."))
        end

        if not target then
            Print("|cff8a8f96Set one with |cffffc74f/cn go|r"
                .. "|cff8a8f96 and run this again.|r")
        end
    end,
}

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
    -- THE MAP MAY REFUSE, AND THE ARROW IS NOT THE WHOLE ANSWER.
    --
    -- The native provider draws its own arrow, which works anywhere -- but it
    -- also drops the client's user waypoint, and the client will not place one
    -- on a dungeon, raid, cosmic or continent map. `CanSetUserWaypointOnMap`
    -- says which, and was called nowhere in this addon.
    --
    -- The arrow is still worth having on those maps, so this does not refuse
    -- outright; it simply does not claim a map pin it could not place.
    local allowed = true

    if C_Map and C_Map.CanSetUserWaypointOnMap then
        local asked, answer = pcall(C_Map.CanSetUserWaypointOnMap, mapID)

        if asked and not answer then
            allowed = false
        end
    end

    target = {
        mapID = mapID,
        x     = x,
        y     = y,
        title = title,
        zone  = Blizzard.GetMapName(mapID),
        setAt = time(),
    }

    Navigation.ResetCalibration()
    Navigation.ResetMotion()

    -- SMOOTHING BELONGS TO A DESTINATION, NOT TO THE ARROW.
    --
    -- `Blank` -- the only thing that resets the smoothed bearing and distance
    -- -- ran from `Navigation.Clear` and only when an arrow already existed.
    -- Changing target without clearing first, which is what `/cn go`, the
    -- route's auto-advance and a map-pin click all do, left the previous
    -- destination's smoothed values in place. The snap thresholds hid the
    -- large jumps, so what remained was the confusing case: a new target
    -- within 89 degrees and 79 yards was eased into over several ticks,
    -- showing a bearing and a distance belonging to neither destination.
    Navigation.ResetSmoothing()
    Navigation.ResetDistanceSmoothing()

    BuildArrow()
    Navigation.StartTicker()
    Refresh()

    -- Also drop a map pin, so the destination is visible on the world map and
    -- not only in front of the player.
    if allowed and C_Map.SetUserWaypoint and UiMapPoint
        and UiMapPoint.CreateFromCoordinates then

        local ok = pcall(function()
            C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(mapID, x, y))
        end)

        if ok then
            -- Remembered so Clear can tell this addon's pin from one the
            -- player placed by hand.
            Navigation.ownsUserWaypoint = true

            if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
                pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
            end
        end
    end

    if not allowed then
        return true, "the arrow is set; the game does not allow a map pin here"
    end

    return true
end

function provider.ClearAll()
    return Navigation.Clear()
end

function Navigation.Clear()
    local had = target ~= nil or Navigation.ownsUserWaypoint

    target = nil

    if arrow then
        arrow:Hide()
    end

    -- Unconditionally, not only when an arrow was built: the smoothed values
    -- are state about a destination and the destination is gone either way.
    Blank()

    Navigation.StopTicker()

    -- ONLY OUR OWN PIN. `ClearUserWaypoint` removes THE user waypoint, and
    -- there is one. Stopping follow mode used to delete a pin the player had
    -- placed by hand.
    if Navigation.ownsUserWaypoint and C_Map and C_Map.ClearUserWaypoint then
        pcall(C_Map.ClearUserWaypoint)
    end

    Navigation.ownsUserWaypoint = nil

    return had and true or false
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

    -- Lowercased first: `auto` was the one value that stayed case-sensitive,
    -- so `/cn nav Auto` was refused against a help line that offers `auto`.
    if name == nil or string.lower(name) == "auto" then
        settings.navigation = nil
        return true, "automatic"
    end

    -- THE REGISTRY WAS OPEN AND THIS LIST WAS NOT.
    --
    -- `CN.RegisterWaypointProvider` is a published extension point: another
    -- addon, or a later module of this one, can register a fourth provider
    -- and `CN.GetPreferredWaypointProvider` will honour it. But the only way
    -- to EXPRESS a preference is this command, and it matched against three
    -- names hardcoded here -- so a registered fourth provider could be used
    -- automatically and could never be chosen deliberately. A registry with a
    -- closed selector is three special cases wearing a registry's name.
    --
    -- Matched against what is actually registered now, case-insensitively,
    -- and the registered name is what gets stored so the lookup on the other
    -- side is exact.
    local key = string.lower(name)

    local resolved

    for registered in pairs(CN.waypointProviders or {}) do
        if string.lower(registered) == key then
            resolved = registered
            break
        end
    end

    if not resolved then
        return false, nil
    end

    settings.navigation = resolved

    return true, resolved
end

-- The names `/cn nav <name>` will accept, for the command's own help and its
-- error message. Sorted, so the list does not reorder itself between logins.
function Navigation.PreferenceNames()
    local names = {}

    for registered in pairs(CN.waypointProviders or {}) do
        table.insert(names, registered)
    end

    table.sort(names)

    return names
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
            Print("|cff8a8f96Nothing is being tracked. |cffffc74f/cn go|r "
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
        Print("|cff8a8f96Whether GetPlayerFacing counts clockwise or "
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

                -- Named from the registry rather than from a sentence, so a
                -- provider registered by another addon is offered here the
                -- moment it exists.
                Print("|cff8a8f96Choose auto, or one of: "
                    .. table.concat(Navigation.PreferenceNames(), ", ")
                    .. ".|r")

                return
            end

            Print("Navigation provider: |cffffc74f" .. tostring(resolved) .. "|r")
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
                .. " |cff8a8f96priority " .. entry.priority .. "|r")
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

        Print("Tracking: |cffffc74f" .. tostring(target.title) .. "|r in "
            .. tostring(target.zone))

        if state and state.state == "WRONG_MAP" then
            Print("  |cff8a8f96It is in another zone.|r")
        elseif state then
            Print("  " .. Navigation.FormatDistance(state.yards)
                .. (state.relative and string.format(" |cff8a8f96%d degrees off|r",
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
