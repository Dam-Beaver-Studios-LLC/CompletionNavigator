-- Modules/Session.lua
-- Completion Navigator :: "I have forty minutes. What should I do?"
--
-- The single most common shape a play session actually has, and the addon
-- had nothing to say about it. It could rank everything and route between
-- stops, and it could not answer the one question a person with a job and a
-- bedtime asks before logging in.
--
-- WHY THIS IS HARD TO DO HONESTLY.
--
-- A plan that fits in forty minutes requires knowing how long things take,
-- and the client does not say. The tempting move is to make numbers up --
-- "quests take four minutes" -- and present them in a font that looks like
-- measurement. This addon has a standing rule against exactly that.
--
-- So the estimate is built from two halves, and only one of them is guessed:
--
--   TRAVEL is computed. The router already knows the real yard distance
--   between stops, and this module measures how fast you actually move by
--   watching your position. That is arithmetic on observations.
--
--   TASK TIME is learned. Every completion is timed against when the
--   objective was first offered as the current stop, and the median per type
--   is kept. Until a type has been seen enough times, it has NO estimate and
--   the plan says so rather than inventing one.
--
-- A plan therefore starts out honest and vague -- "these stops, distance
-- known, duration not yet" -- and sharpens as it watches you play. That is
-- slower to become useful than a table of invented constants, and it is the
-- only version that is ever true.

local ADDON_NAME, CN = ...

local Session = CN:RegisterModule("Session")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint

------------------------------------------------------------
-- MEASURED TRAVEL SPEED
------------------------------------------------------------

-- Yards per second. Seeded with a walking-speed figure that is immediately
-- replaced by measurement; it exists so the first plan is not divided by nil.
Session.defaultSpeed = 7

Session.minSamples = 5

-- THE CLOCK.
--
-- `time()` returns whole seconds. Sampling a ten-second interval with a
-- one-second ruler is up to ten per cent of error baked into every estimate
-- the planner produces, and it silently discarded every task that finished
-- within the same second it was offered -- which, in the offline suite, was
-- all of them. `GetTime()` is the client's fractional monotonic clock and is
-- the right instrument for measuring a duration.
--
-- Kept behind a function so the offline harness can drive it.
function Session.Now()
    if GetTime then
        return GetTime()
    end

    return os.clock()
end

-- Speed is kept in three buckets, not one.
--
-- A single median across mounted and unmounted travel is a number that is
-- wrong in both states: too slow to plan a mounted route, too fast to plan a
-- walk around a town.
--
-- 0.43.0 added the third, and it was the same mistake one level down: flying
-- yourself was landing in `mounted` beside a ground mount, so the median was
-- dragged upward by however much the player skyrides and every ground
-- estimate inherited it. Three medians are three honest answers.
local speed = {
    lastMapID  = nil,
    lastX      = nil,
    lastY      = nil,
    lastAt     = nil,
    lastMounted = nil,
    lastFlying = nil,
    samples    = { mounted = {}, onFoot = {}, flying = {} },
}

-- SAMPLES SURVIVE A RELOAD.
--
-- They did not. Speed was measured into a table that lived and died with the
-- session, so every `/reload` -- which a player does several times an hour --
-- threw away the measurements and put the planner back on a guessed constant.
-- The addon was permanently five samples from being useful and never got
-- there.
--
-- Stored per character, because a druid in travel form and a warrior on foot
-- are different measurements and averaging them helps nobody.
local function Persisted()
    local character = CN.character

    if not character then
        return nil
    end

    character.speedSamples = character.speedSamples or {}

    character.speedSamples.mounted = character.speedSamples.mounted or {}
    character.speedSamples.onFoot  = character.speedSamples.onFoot or {}
    character.speedSamples.flying  = character.speedSamples.flying or {}

    return character.speedSamples
end

Session.Persisted = Persisted

-- THE SANITY BAND, PER BUCKET.
--
-- It was a single range -- above half a yard a second, below sixty -- written
-- when there were two buckets and both were ground travel. Sixty is a
-- perfectly good ceiling for running and riding, and it is BELOW the speed a
-- player actually flies at.
--
-- So when 0.43.0 added the flying bucket, every genuine flying sample was
-- silently discarded as implausible, the bucket never filled, and the flying
-- estimate stayed permanently seeded. The feature would have looked like it
-- was working and never learned anything. Caught by a test that assumed a
-- realistic flying speed.
Session.speedBands = {
    onFoot  = { 0.5, 60 },
    mounted = { 0.5, 60 },

    -- Skyriding sustains well past sixty and bursts higher. The upper bound
    -- is the same one Travel uses for a taxi: fast enough to be a loading
    -- screen rather than a mount.
    flying  = { 0.5, 200 },
}

function Session.IsPlausibleSpeed(value, bucket)
    local band = Session.speedBands[bucket or "onFoot"]
        or Session.speedBands.onFoot

    return value > band[1] and value < band[2]
end

function Session.LoadSamples()
    local stored = Persisted()

    if not stored then
        return 0
    end

    local loaded = 0

    for _, bucket in ipairs({ "mounted", "onFoot", "flying" }) do
        speed.samples[bucket] = {}

        for _, value in ipairs(stored[bucket] or {}) do
            if type(value) == "number" and Session.IsPlausibleSpeed(value, bucket) then
                table.insert(speed.samples[bucket], value)
                loaded = loaded + 1
            end
        end
    end

    -- Write the cleaned set back.
    --
    -- SavedVariables are a file on disk that other things can touch and that
    -- survives every future version of this addon. Filtering junk on read and
    -- leaving it in place means filtering the same junk on every login
    -- forever; cleaning it means the corruption is dealt with once.
    Session.SaveSamples()

    return loaded
end

function Session.SaveSamples()
    local stored = Persisted()

    if not stored then
        return false
    end

    -- ALL THREE BUCKETS, INCLUDING THE ONE THAT WAS MISSING.
    --
    -- `flying` was left out of this list while Persisted() creates it and
    -- LoadSamples reads it, so measured flight speed survived until logout
    -- and then vanished. Travel.HasFlying needs five flying samples before it
    -- will consider a self-flown route at all, so after any reload the addon
    -- silently went back to costing every journey on the ground -- the
    -- feature 0.43.0 was built around, off, permanently, for everyone.
    --
    -- The suite tested disk-to-memory for all three and memory-to-disk for
    -- two. A round trip is not tested by testing each half against a
    -- different fixture.
    for _, bucket in ipairs({ "mounted", "onFoot", "flying" }) do
        stored[bucket] = {}

        for _, value in ipairs(speed.samples[bucket]) do
            table.insert(stored[bucket], value)
        end
    end

    return true
end

Session.speedSampleCap = 40

local function Mounted()
    if IsMounted and IsMounted() then
        return true
    end

    if UnitOnTaxi and UnitOnTaxi("player") then
        return true
    end

    return false
end

Session.IsMounted = Mounted

-- Flying yourself, which is not the same as being on a flight path and not
-- the same as a ground mount. On a taxi the client also reports the player as
-- flying, and that movement belongs to Travel's flight-speed measurement
-- rather than to this one -- so it is excluded here.
local function Flying()
    if UnitOnTaxi and UnitOnTaxi("player") then
        return false
    end

    return (IsFlying and IsFlying()) and true or false
end

Session.IsFlying = Flying

-- Which bucket the player's current movement belongs in.
function Session.Bucket()
    if Flying() then
        return "flying"
    end

    if Mounted() then
        return "mounted"
    end

    return "onFoot"
end

-- Called on a slow clock. Measures the distance covered since the last look.
--
-- Deliberately discards anything implausible: a teleport, a flight path, a
-- hearthstone or a zone change would otherwise register as a very fast
-- player and make every estimate useless.
function Session.Observe()
    local mapID, x, y = CN.GetPlayerPosition()

    local now     = Session.Now()
    local mounted = Mounted()
    local flying  = Flying()

    if not mapID or not x or not y then
        return nil
    end

    local previousMap, previousX, previousY, previousAt, previousMounted =
        speed.lastMapID, speed.lastX, speed.lastY, speed.lastAt, speed.lastMounted

    -- Read BEFORE it is overwritten. The first version of the flying check
    -- compared the new value against itself, which is always equal, so taking
    -- off mid-interval produced a sample that was half ground speed and half
    -- flight speed and was filed under whichever the player ended in.
    local previousFlying = speed.lastFlying

    speed.lastMapID, speed.lastX, speed.lastY = mapID, x, y
    speed.lastAt, speed.lastMounted = now, mounted
    speed.lastFlying = flying

    if previousMap ~= mapID or not previousAt then
        return nil
    end

    -- Mounting halfway through an interval makes the sample a blend of both
    -- speeds and belongs to neither bucket. The same is true of taking off.
    if previousMounted ~= mounted or previousFlying ~= flying then
        return nil
    end

    local elapsed = now - previousAt

    if elapsed <= 0 or elapsed > 30 then
        return nil
    end

    local nav = CN:GetModule("Navigation")

    if not nav or not nav.DistanceYards then
        return nil
    end

    local yards = nav.DistanceYards(mapID, previousX, previousY, x, y)

    if not yards or yards <= 0 then
        return nil
    end

    local observed = yards / elapsed

    -- A player on foot does about 7 yards a second; mounted, roughly 14 to
    -- 20; flying, a great deal more. The ceiling is per bucket for exactly
    -- that reason -- see Session.speedBands.
    local bucketName = flying and "flying"
        or (mounted and "mounted" or "onFoot")

    if not Session.IsPlausibleSpeed(observed, bucketName) then
        return nil
    end

    local bucket = speed.samples[bucketName]

    table.insert(bucket, observed)

    while #bucket > Session.speedSampleCap do
        table.remove(bucket, 1)
    end

    -- Written straight through. A measurement kept only in memory is a
    -- measurement thrown away at the next reload, which is what this used
    -- to do.
    Session.SaveSamples()

    return observed, mounted
end

-- The median, not the mean: standing still for a minute should not halve the
-- estimate, and one flight path should not double it.
local function Median(values)
    if #values == 0 then
        return nil
    end

    local sorted = {}

    for index = 1, #values do
        sorted[index] = values[index]
    end

    table.sort(sorted)

    local middle = math.floor(#sorted / 2) + 1

    if #sorted % 2 == 1 then
        return sorted[middle]
    end

    return (sorted[middle - 1] + sorted[middle]) / 2
end

Session.Median = Median

-- The speed to plan with.
--
-- Defaults to however the player is travelling right now, because that is
-- the best available guess at how they will travel next. Falls back to the
-- other bucket rather than to a constant: measured-but-wrong-state beats
-- unmeasured.
function Session.Speed(mounted)
    local bucket

    if mounted == nil then
        bucket = Session.Bucket()
    elseif mounted == true then
        bucket = "mounted"
    elseif mounted == false then
        bucket = "onFoot"
    else
        -- A caller that names a bucket outright: Travel asks for "flying"
        -- when it is costing a journey the player would fly themselves,
        -- which has nothing to do with how they happen to be moving now.
        bucket = mounted
    end

    local preferred = speed.samples[bucket] or {}

    if #preferred >= Session.minSamples then
        return Median(preferred), true
    end

    -- Fall back through the other buckets rather than to a constant:
    -- measured-but-wrong-state beats unmeasured. Ordered nearest-first, so a
    -- missing flying median falls to mounted before it falls to walking.
    local fallbacks = {
        flying  = { "mounted", "onFoot" },
        mounted = { "flying", "onFoot" },
        onFoot  = { "mounted", "flying" },
    }

    for _, name in ipairs(fallbacks[bucket] or {}) do
        local other = speed.samples[name] or {}

        if #other >= Session.minSamples then
            return Median(other), false
        end
    end

    return Session.defaultSpeed, false
end

function Session.SpeedSampleCount(mounted)
    if mounted == nil then
        return #speed.samples.mounted + #speed.samples.onFoot
            + #speed.samples.flying
    end

    if mounted == true then
        return #speed.samples.mounted
    end

    if mounted == false then
        return #speed.samples.onFoot
    end

    return #(speed.samples[mounted] or {})
end

-- The in-memory samples themselves. Exposed so that a round trip through
-- disk can be tested as a round trip -- testing each half against a fixture
-- the other half never produced is how a bucket that was loaded but never
-- saved stayed broken for four releases.
function Session.Samples()
    return speed.samples
end

function Session.SpeedBuckets()
    return {
        mounted = Median(speed.samples.mounted),
        onFoot  = Median(speed.samples.onFoot),
        flying  = Median(speed.samples.flying),
    }
end

------------------------------------------------------------
-- LEARNED TASK DURATION
------------------------------------------------------------

local function Durations()
    return CN.Account("taskDurations")
end

Session.Durations = Durations

Session.minDurationSamples = 4
Session.durationSampleCap  = 25

-- The shortest a thing can be said to have taken once its journey is removed.
--
-- A floor rather than a discard, and a very small one. Discarding every
-- sample where the journey estimate exceeded the whole elapsed span would
-- throw away precisely the fast objectives -- biasing the learned time
-- upward, which is the error this subtraction exists to remove. A floored
-- sample says "the work itself was negligible next to getting there", which
-- for a quest handed in on arrival is exactly true.
Session.minimumWorkSeconds = 0.05

-- When each objective was first put in front of the player. A completion
-- timed from here is "how long it took once it was the thing to do", which is
-- the number a plan needs.
-- BOUNDED, because it was not.
--
-- Every objective the addon decorated used to get an entry here and only a
-- completion removed one. Cross a dozen zones and it accumulates a timestamp
-- for everything that ever scrolled past -- a slow leak I shipped in 0.28.0.
--
-- Two bounds now: entries expire, and the table is capped. Neither costs
-- accuracy, because an entry older than the expiry window would have been
-- rejected as implausible at completion time anyway.
local offeredAt = {}
local offeredCount = 0

Session.offerMemoryCap     = 400
Session.offerMemorySeconds = 1800

-- HYSTERESIS, and why it is not optional.
--
-- Pruning the moment the table reaches its cap means every subsequent insert
-- triggers a full sweep of four hundred entries. Recommend(25) does twenty
-- five inserts, so a single call became ten thousand iterations -- measured
-- at 1.5ms, up from 0.02ms. A fix for a memory leak that costs seventy times
-- the CPU is not a fix.
--
-- So: let it overshoot by a quarter, then prune back to the cap. Sweeps
-- happen once per hundred inserts instead of once per insert, and the table
-- is still bounded, which was the entire point.
Session.offerMemorySlack = 0.25

local function Prune(force)
    local trigger = Session.offerMemoryCap
        * (1 + Session.offerMemorySlack)

    if not force and offeredCount <= trigger then
        return 0
    end

    local now = Session.Now()

    local removed = 0

    for key, record in pairs(offeredAt) do
        if now - record.at > Session.offerMemorySeconds then
            offeredAt[key] = nil
            removed = removed + 1
        end
    end

    offeredCount = offeredCount - removed

    -- Still over cap after expiring? Drop the oldest until it fits. A
    -- timestamp we cannot afford to keep is worth less than a bounded table.
    if offeredCount > Session.offerMemoryCap then
        local ordered = {}

        for key, record in pairs(offeredAt) do
            table.insert(ordered, { key = key, at = record.at })
        end

        table.sort(ordered, function(a, b) return a.at < b.at end)

        local excess = offeredCount - Session.offerMemoryCap

        for index = 1, excess do
            offeredAt[ordered[index].key] = nil
            removed = removed + 1
        end

        offeredCount = offeredCount - excess
    end

    return removed
end

Session.Prune = Prune

function Session.OfferedCount()
    return offeredCount
end

function Session.NoteOffered(objective)
    if type(objective) ~= "table" or not objective.type or not objective.id then
        return
    end

    local key = tostring(objective.type) .. ":" .. tostring(objective.id)

    if offeredAt[key] then
        return
    end

    -- WHAT THE JOURNEY WAS EXPECTED TO COST, RECORDED WITH THE CLOCK.
    --
    -- The elapsed span between "this was recommended" and "this was finished"
    -- contains the walk to it. The planner then ADDS a separately computed
    -- travel leg to a sum of those spans, so the journey was counted twice --
    -- and once per objective at a stop, which is worst exactly where the
    -- router is trying to reward batching. Four quests six minutes away came
    -- out at thirty-six minutes against a true twelve, reported confident.
    --
    -- Subtracting the addon's own estimate makes the stored number a WORK
    -- time, which is what every consumer already assumes it is. Using the
    -- addon's own model rather than a measurement keeps the two consistent
    -- even where the model is imperfect: the same quantity is removed here
    -- and added back there.
    local travelSeconds = 0

    if objective.travelCost and CN.secondsPerCostPoint then
        travelSeconds = objective.travelCost * CN.secondsPerCostPoint
    end

    offeredAt[key] = { at = Session.Now(), travel = travelSeconds }
    offeredCount   = offeredCount + 1

    Prune()
end

function Session.NoteCompleted(objectiveType, id)
    if not objectiveType or not id then
        return nil
    end

    local key = tostring(objectiveType) .. ":" .. tostring(id)

    local started = offeredAt[key]

    if offeredAt[key] then
        offeredAt[key] = nil
        offeredCount   = offeredCount - 1
    end

    if not started then
        return nil
    end

    local elapsed = Session.Now() - started.at

    -- The journey out, which the caller will add back separately.
    elapsed = elapsed - (started.travel or 0)

    -- A floor rather than a discard: something finished faster than the model
    -- said the journey would take is a fast objective, not a corrupt sample.
    if elapsed < Session.minimumWorkSeconds then
        elapsed = Session.minimumWorkSeconds
    end

    -- Anything over twenty minutes was not "doing the thing", it was living
    -- your life with the thing still on the list.
    --
    -- The lower bound is now a fraction of a second rather than a whole one.
    -- With a one-second clock, anything finished in the same second it was
    -- offered read as zero elapsed and was thrown away -- which quietly
    -- discarded exactly the fast turn-ins a quest grinder produces most of.
    if elapsed <= 0.05 or elapsed > 1200 then
        return nil
    end

    local store = Durations()

    store[objectiveType] = store[objectiveType] or {}

    table.insert(store[objectiveType], elapsed)

    while #store[objectiveType] > Session.durationSampleCap do
        table.remove(store[objectiveType], 1)
    end

    DebugPrint(objectiveType .. " took " .. elapsed .. "s ("
        .. #store[objectiveType] .. " samples).")

    return elapsed
end

-- Seconds this type usually takes, or NIL when the addon has not watched it
-- often enough to have an opinion. Nil is a real answer here and every
-- caller must handle it rather than substituting a guess.
function Session.TypicalSeconds(objectiveType)
    local samples = Durations()[objectiveType]

    if not samples or #samples < Session.minDurationSamples then
        return nil
    end

    return Median(samples)
end

function Session.HasEnoughData()
    for _, samples in pairs(Durations()) do
        if #samples >= Session.minDurationSamples then
            return true
        end
    end

    return false
end

------------------------------------------------------------
-- THE PLAN
------------------------------------------------------------

-- Estimates a stop: travel to it, plus the work at it.
--
-- Returns seconds and a confidence flag. `false` means part of this was not
-- measured, and callers must say so out loud.
function Session.EstimateHub(hub, fromX, fromY)
    local confident = true

    local travelSeconds = 0

    -- ASK TRAVEL, WHICH KNOWS ABOUT FLIGHT PATHS.
    --
    -- This used to be a straight line at running speed between two points on
    -- the same map, and gave up entirely when the maps differed -- so a stop
    -- one zone away was either uncosted or costed as though you would run
    -- there in a straight line through the mountains.
    local travel = CN:GetModule("Travel")

    local playerMap = CN.GetPlayerPosition()

    if travel and hub.mapID and hub.x and hub.y and fromX and fromY and playerMap then
        local seconds, sure = travel.EstimateSeconds(
            playerMap, fromX, fromY, hub.mapID, hub.x, hub.y)

        if seconds then
            travelSeconds = seconds

            if not sure then
                confident = false
            end
        else
            confident = false
        end
    else
        confident = false
    end

    local workSeconds = 0

    for _, objective in ipairs(hub.objectives or {}) do
        local typical = Session.TypicalSeconds(objective.type)

        if typical then
            workSeconds = workSeconds + typical
        else
            confident = false
        end
    end

    return travelSeconds + workSeconds, confident, travelSeconds, workSeconds
end

-- Builds a route and takes stops from the front of it until the budget is
-- spent.
--
-- Takes from the FRONT rather than choosing the best-fitting subset. The
-- route is already ordered to minimise walking; cherry-picking stops out of
-- it produces a plan that fits the clock and makes you cross the zone twice.
-- HOW LONG YOU ACTUALLY PLAY.
--
-- `/cn plan` has always needed a number, and its example has always been
-- thirty minutes -- a figure chosen because it sounds reasonable, not because
-- anybody plays in thirty-minute units. The addon watches how long sessions
-- run anyway; asking it is cheaper than asking the player.
--
-- Stored per character, capped, and used only as the DEFAULT: an explicit
-- number always wins, because "I have twenty minutes" is a fact about tonight
-- that no amount of history overrides.
Session.lengthSampleCap = 20
Session.minLengthSamples = 3

local sessionStartedAt = nil

local function Lengths()
    local character = CN.character

    if not character then
        return nil
    end

    character.sessionLengths = character.sessionLengths or {}

    return character.sessionLengths
end

Session.Lengths = Lengths

function Session.BeginSession()
    sessionStartedAt = Session.Now()
end

-- Called at logout and on a reload. A reload is not the end of a session, but
-- there is no way to tell one from the other at the moment it happens -- so
-- very short sessions are discarded rather than counted, which handles the
-- reload case without needing to detect it.
Session.minCountableMinutes = 8

function Session.EndSession()
    local lengths = Lengths()

    if not lengths or not sessionStartedAt then
        return false
    end

    local minutes = (Session.Now() - sessionStartedAt) / 60

    sessionStartedAt = nil

    if minutes < Session.minCountableMinutes or minutes > 720 then
        return false
    end

    table.insert(lengths, math.floor(minutes + 0.5))

    while #lengths > Session.lengthSampleCap do
        table.remove(lengths, 1)
    end

    return true
end

-- Returns minutes and whether it was measured.
function Session.TypicalSessionMinutes()
    local lengths = Lengths()

    if not lengths or #lengths < Session.minLengthSamples then
        return 30, false
    end

    return math.floor(Median(lengths) + 0.5), true
end

CN:OnLogin(function()
    Session.BeginSession()
end)

CN:RegisterEvent("PLAYER_LOGOUT", function()
    Session.EndSession()
end)

function Session.Plan(minutes)
    local requested = tonumber(minutes)

    -- THE RANKING KNOWS WHERE YOU ARE; THE PLANNER DID NOT.
    --
    -- 0.43.0 taught the ranking about being dead and being in an instance,
    -- and the session planner carried on laying out a walking route through
    -- the open world regardless -- which is a plan the player cannot start.
    local group = CN:GetModule("Group")

    local situation = group and group.Situation()

    if situation == "dead" or situation == "instanced" then
        return {
            minutes   = (requested or Session.TypicalSessionMinutes()),
            stops     = {},
            seconds   = 0,
            confident = true,
            skipped   = 0,
            blocked   = situation,
            notice    = group and group.Notice(),
        }
    end

    -- No number given: use however long this character usually plays, rather
    -- than a round thirty that was only ever a placeholder.
    local budget = (requested or Session.TypicalSessionMinutes()) * 60

    local mapID, x, y = CN.GetPlayerPosition()

    local plan = {
        minutes   = budget / 60,
        stops     = {},
        seconds   = 0,
        confident = true,
        skipped   = 0,
    }

    if not mapID then
        return plan
    end

    local _, _, hubs = CN.BuildZoneRoute(mapID, x or 0.5, y or 0.5)

    if type(hubs) ~= "table" then
        return plan
    end

    local currentX, currentY = x or 0.5, y or 0.5

    for _, hub in ipairs(hubs) do
        local seconds, confident, travel, work =
            Session.EstimateHub(hub, currentX, currentY)

        -- STOP AT THE FIRST STOP THAT DOES NOT FIT.
        --
        -- This used to `continue` past an overrunning hub and keep testing
        -- later ones, which is exactly the cherry-picking the comment above
        -- this function forbids -- and it forbids it for a good reason: the
        -- route is ordered to minimise walking, so skipping the middle of it
        -- and taking the far end makes you cross the zone twice to save a
        -- number on a screen.
        --
        -- It was also arithmetically wrong even on its own terms: the skipped
        -- hub's position was not advanced past, so every later hub's travel
        -- leg was costed from wherever the last ACCEPTED stop was, which is
        -- not where the player would be.
        -- THE FIRST STOP IS NOT EXEMPT FROM THE CLOCK.
        --
        -- `#plan.stops > 0` meant stop one was admitted whatever it cost, so
        -- `/cn plan 5` against a forty-five minute hub printed "1 stop, about
        -- 45m of the 5m you have" with nothing flagging that the budget had
        -- been blown ninefold. Taking it is still often the right call --
        -- there may be nothing smaller -- but the player has to be told, not
        -- shown a plan that silently is not a plan.
        if plan.seconds + seconds > budget and #plan.stops > 0 then
            plan.skipped = plan.skipped + 1

            break
        else
            table.insert(plan.stops, {
                hub       = hub,
                seconds   = seconds,
                travel    = travel,
                work      = work,
                summary   = CN.DescribeHub and CN.DescribeHub(hub) or nil,
                confident = confident,
            })

            plan.seconds = plan.seconds + seconds

            if not confident then
                plan.confident = false
            end

            currentX, currentY = hub.x or currentX, hub.y or currentY
        end
    end

    -- `skipped` counts the stop that did not fit plus everything behind it,
    -- because that is what the player is not doing tonight. Counting only the
    -- one that overran would report "1 skipped" for a route with nine stops
    -- left in it.
    if plan.skipped > 0 then
        plan.skipped = #hubs - #plan.stops
    end

    -- Said out loud when the only thing available does not fit.
    plan.overran = plan.seconds > budget

    return plan
end

-- SHORT IS NOT FREE.
--
-- Rounded to whole minutes, a twenty-five second stop rendered as "0m" in
-- `/cn plan` and `/cn travel`, which reads as costing nothing rather than as
-- costing very little. Under a minute is reported in seconds.
function Session.FormatDuration(seconds)
    if not seconds or seconds <= 0 then
        return "0m"
    end

    if seconds < 60 then
        return math.max(1, math.floor(seconds + 0.5)) .. "s"
    end

    local minutes = math.floor(seconds / 60 + 0.5)

    if minutes < 60 then
        return minutes .. "m"
    end

    return string.format("%dh %dm", math.floor(minutes / 60), minutes % 60)
end

------------------------------------------------------------
-- WIRING
------------------------------------------------------------

-- The clock starts when something is RECOMMENDED, not when it is collected.
--
-- 0.28.0 hung this on a candidate decorator, which meant a timestamp was
-- taken for every objective the addon knew about on every rebuild -- two
-- hundred at retail scale, the overwhelming majority of which the player
-- never saw and no plan ever used. Wrong on cost and wrong on meaning: an
-- objective sitting at rank 180 has not been "offered" to anybody.
--
-- Recommend() is the moment something is actually put in front of a player.
function Session.NoteRecommended(list)
    for index = 1, math.min(#list, Session.timedRecommendations) do
        Session.NoteOffered(list[index])
    end

    return list
end

Session.timedRecommendations = 25

if CN.RegisterRecommendationHook then
    CN.RegisterRecommendationHook("SessionTiming", Session.NoteRecommended)
end

CN:RegisterEvent("QUEST_TURNED_IN", function(_, questID)
    Session.NoteCompleted(CN.objectiveTypes.QUEST, questID)
end)

CN:RegisterEvent("NEW_PET_ADDED", function()
    -- The client does not say which pet, so nothing can be timed here
    -- honestly. Left deliberately unhandled rather than attributing the
    -- elapsed time to a guess.
end)

local ticker

CN:OnLogin(function()
    Session.LoadSamples()

    Session.Observe()

    if C_Timer and C_Timer.NewTicker and not ticker then
        -- GUARDED. A C_Timer callback that throws goes to the client's own
        -- error handler, and a REPEATING ticker means a repeating error box:
        -- one bad observation and the player gets a popup every ten seconds
        -- for the rest of the session. Navigation's ticker has been guarded
        -- since 0.34.0; the four others were not.
        ticker = C_Timer.NewTicker(10, function()
            CN.Guard("Session.Observe", Session.Observe)
        end)
    end
end)

------------------------------------------------------------
-- COMMAND
------------------------------------------------------------

CN:RegisterCommand{
    name    = "plan",
    aliases = { "time", "budget" },
    args    = "<minutes>",
    order   = 13,
    help    = "What fits in the time you actually have.",
    handler = function(args)
        local minutes = tonumber(CN.Trim(args or ""))

        if not minutes or minutes <= 0 then
            -- No number is no longer a usage error. The addon has watched how
            -- long this character plays; asking it beats asking the player,
            -- and a player who wanted a specific number can still say one.
            local typical, measured = Session.TypicalSessionMinutes()

            minutes = typical

            Print("Planning " .. minutes .. " minutes -- "
                .. (measured
                    and ("|cff999999your usual session on this character|r")
                    or ("|cff999999a default; play a few sessions and this "
                        .. "becomes your own figure|r")))
        end

        local plan = Session.Plan(minutes)

        if plan.blocked then
            -- Not "nothing to plan around": there is plenty, and the player
            -- cannot start any of it from where they are. Saying the first
            -- when the second is true is how an addon earns a reputation for
            -- not paying attention.
            Print(plan.notice or "Not while you are in the middle of that.")
            Print("|cff999999The plan is waiting; ask again when you are back "
                .. "in the world.|r")
            return
        end

        if #plan.stops == 0 then
            Print("Nothing here to plan around.")
            return
        end

        -- THE SUM OF NUMBERS TOO UNCERTAIN TO SHOW IS NOT A CERTAIN NUMBER.
        --
        -- Each individual stop below refuses to print a duration it is not
        -- confident in, and this headline printed their total as a plain
        -- figure regardless. One convention, both lines.
        Print(string.format("%d stop%s, about %s of the %dm you have:",
            #plan.stops,
            #plan.stops == 1 and "" or "s",
            CN.WithConfidence(Session.FormatDuration(plan.seconds),
                CN.ConfidenceFor(plan.confident)),
            plan.minutes))

        for index, stop in ipairs(plan.stops) do
            Print(string.format("  %d. |cffffff00%s|r |cff999999%s|r",
                index,
                tostring(stop.summary or "stop"),
                stop.confident and Session.FormatDuration(stop.seconds)
                    or (CN.WithConfidence(nil, CN.confidence.UNKNOWN) .. " time")))
        end

        if plan.skipped > 0 then
            Print("|cff999999" .. plan.skipped
                .. " further stop(s) did not fit.|r")
        end

        if plan.overran then
            Print("|cffffff00The nearest stop is longer than the time you "
                .. "have.|r |cff999999Nothing smaller was available, so it "
                .. "is shown anyway -- but it will not fit.|r")
        end

        if not plan.confident then
            -- THE COUNT MUST BE THE COUNT BEHIND THE RATE.
            --
            -- `Speed()` answers from one bucket; `SpeedSampleCount()` with no
            -- argument summed all three. So the line justifying confidence in
            -- a 62 yd/s flying median cited forty-six samples, forty of which
            -- were on-foot readings at seven that had no part in it --
            -- overstating the evidence sevenfold in the one place whose whole
            -- job is to say how much evidence there is.
            local bucket = Session.Bucket()

            local rate, measured = Session.Speed(bucket)

            Print("|cffffff00Some of this is not measured yet.|r "
                .. "|cff999999Travel speed: "
                .. (measured and string.format("%.0f yd/s from %d %s samples",
                        rate, Session.SpeedSampleCount(bucket), bucket)
                    or "still learning")
                .. ". Task times are learned from your own play, so the "
                .. "estimate sharpens as you go rather than starting from "
                .. "numbers nobody measured.|r")
        end
    end,
}

------------------------------------------------------------
-- HOW LONG A THING TAKES, AS A SCORING TERM
------------------------------------------------------------

-- THE LEVER `/cn mode fastest` HAS ALWAYS ADVERTISED AND NEVER HAD.
--
-- `estimatedTime` is a declared scoring weight, summed on every objective,
-- printed by `/cn order`, and overridden by the `fastest` profile to -1.5 --
-- and nothing in the addon has ever set the field. So the mode's second lever
-- did nothing: `/cn mode fastest` was a travel-cost change wearing the name
-- of something broader.
--
-- The data to fill it has been collected since 0.41.0. This is the wiring.
--
-- SCALED, NOT RAW. A raw duration in seconds would swamp every other term --
-- a twenty-minute dungeon would arrive at 1200 against a completion value of
-- 5. The term is the duration in units of the typical objective, so 1 means
-- "about as long as things usually take", 3 means "three times as long", and
-- an objective the addon has never timed contributes nothing rather than a
-- guess. The addon does not invent a duration it has not watched.
Session.timeScaleSeconds = 300

function Session.TimeCost(objectiveType)
    local typical = Session.TypicalSeconds(objectiveType)

    if not typical or typical <= 0 then
        return nil
    end

    return typical / Session.timeScaleSeconds
end

-- A DECORATOR RECEIVES ONE OBJECTIVE, NOT A LIST.
--
-- This took `candidates` and iterated it, which yields nothing when handed a
-- single objective table -- so the field was never set on anything and
-- `/cn mode fastest` kept the inert second lever that 0.48.0 recorded as
-- fixed. Two mistakes in one edit: this, and the block landing INSIDE
-- Session.Speed because the anchor `return Session` also matched
-- `return Session.defaultSpeed`. Everything here was therefore defined only
-- as a side effect of calling Speed(), and re-registered on every call that
-- fell through all three buckets -- fifty-seven registrations of the same
-- decorator in one session.
--
-- The harness asserted that TimeCost exists and then hand-built objectives
-- with estimatedTime already set, testing the scorer against a fixture the
-- producer never made. That is precisely the trap this file's own comment
-- about the flying speed bucket warns about.
CN.RegisterCandidateDecorator("Session", function(objective)
    if type(objective) == "table" and objective.type then
        objective.estimatedTime = Session.TimeCost(objective.type)
    end
end)


return Session
