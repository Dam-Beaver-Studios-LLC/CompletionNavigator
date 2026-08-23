-- Modules/Quests.lua
-- Completion Navigator :: quest subsystem.
--
-- Roadmap position: automatic discovery, event-driven refresh, persistent
-- metadata and status, source-ranked metadata writes.

local ADDON_NAME, CN = ...

local Quests = CN:RegisterModule("Quests")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

CN.pendingQuestLoads = CN.pendingQuestLoads or {}

------------------------------------------------------------
-- COMPLETION STATE
------------------------------------------------------------

function Quests.IsCompletedByCharacter(questID)
    return Blizzard.IsQuestCompletedByCharacter(questID)
end

function Quests.IsCompletedOnAccount(questID)
    return Blizzard.IsQuestCompletedOnAccount(questID)
end

-- Kept for backwards compatibility with the single-file prototype.
CN.IsQuestCompletedByCharacter = Quests.IsCompletedByCharacter
CN.IsQuestCompletedOnAccount   = Quests.IsCompletedOnAccount

------------------------------------------------------------
-- METADATA
------------------------------------------------------------

-- Writes a name only when the incoming source is at least as
-- authoritative as the stored one. Manual entries never clobber Blizzard.
function Quests.SetMetadata(questID, name, source)
    if not questID or not name or name == "" then
        return false
    end

    local metadata = CN.Account("questMetadata")
    local existing = metadata[questID]

    source = source or "manual"

    if existing and existing.name and not CN.IsBetterSource(source, existing.source) then
        DebugPrint("Kept existing " .. tostring(existing.source)
            .. " name for quest " .. questID .. "; rejected " .. source .. ".")
        return false
    end

    metadata[questID] = {
        questID  = questID,
        name     = name,
        lastSeen = time(),
        source   = source,
    }

    return true
end

function Quests.GetMetadata(questID)
    return CN.Account("questMetadata")[questID]
end

-- Resolution order: cache -> live client -> static data -> async request.
function Quests.GetName(questID, requestIfMissing)
    if not questID then
        return nil
    end

    local cached = Quests.GetMetadata(questID)

    if cached and cached.name then
        return cached.name
    end

    local title = Blizzard.GetQuestTitle(questID, false)

    if title then
        Quests.SetMetadata(questID, title, "blizzard")
        return title
    end

    local static = CN.Static.GetQuestName(questID)

    if static then
        Quests.SetMetadata(questID, static, "static")
        return static
    end

    if requestIfMissing then
        Blizzard.GetQuestTitle(questID, true)
    end

    return nil
end

CN.GetQuestName = Quests.GetName

------------------------------------------------------------
-- DISCOVERY
------------------------------------------------------------

function Quests.RecordDiscovered(questID, source)
    questID = CN.ToID(questID)

    if not questID then
        return false
    end

    local discovered = CN.Account("discoveredQuests")
    local existing   = discovered[questID]

    discovered[questID] = {
        firstSeen = existing and existing.firstSeen or time(),
        lastSeen  = time(),
        source    = source or (existing and existing.source) or "manual",
    }

    if not existing then
        DebugPrint("Discovered quest " .. questID .. " (" .. tostring(source or "manual") .. ").")
    end

    return existing == nil
end

CN.RecordDiscoveredQuest = Quests.RecordDiscovered

-- Quests you could walk up to and accept right now, on one map.
--
-- These are the exclamation marks. Until 0.23.0 the addon could not see them
-- at all: it read the quest LOG, which by definition contains only quests you
-- have already taken. "What should I do next?" cannot be answered honestly
-- while the answer "pick up that quest twenty yards away" is invisible.
------------------------------------------------------------
-- LIFECYCLE PHASE
------------------------------------------------------------

-- A quest is not one place. It is three, in order:
--
--   PICKUP  -- the exclamation mark, where you accept it
--   ACTIVE  -- wherever its objectives actually are
--   TURNIN  -- the question mark, where you hand it back
--
-- Treating a quest as a single point is why an addon sends you back and forth:
-- it cannot tell that two quests share a giver, or that four you are carrying
-- all hand in at the same NPC. Naming the phase is what makes batching
-- possible at all.
CN.questPhases = {
    PICKUP = "PICKUP",
    ACTIVE = "ACTIVE",
    TURNIN = "TURNIN",
}

CN.questPhaseVerbs = {
    PICKUP = "pick up",
    ACTIVE = "work on",
    TURNIN = "turn in",
}

function Quests.Phase(questID)
    if not questID then
        return nil
    end

    if Blizzard.IsQuestReadyForTurnIn(questID) then
        return CN.questPhases.TURNIN
    end

    if Blizzard.IsQuestInLog(questID) then
        return CN.questPhases.ACTIVE
    end

    if Quests.IsCompletedByCharacter(questID) then
        return nil
    end

    return CN.questPhases.PICKUP
end

function Quests.PhaseVerb(phase)
    return CN.questPhaseVerbs[phase] or "do"
end

-- Quests offered near you that you have not taken.
--
-- REPORTED FROM LIVE PLAY: "I'm literally standing in front of one to pick
-- up" while this returned zero. Three separate reasons that can happen, and
-- the old version was vulnerable to all three:
--
--   1. WRONG MAP. GetBestMapForUnit answers with the most specific map you
--      are standing on -- a city, a cave, a building interior. Quest starts
--      belonging to the surrounding zone are registered against the PARENT
--      map, so asking only about your own map misses them. This is the most
--      likely cause and the cheapest to fix: ask the neighbourhood.
--   2. THE MAP SIMPLY DOES NOT SAY. A giver whose pin the client has not
--      loaded is invisible to every map query. The only thing that cannot be
--      wrong is the conversation itself, so talking to an NPC now records
--      what they offered.
--
-- Sources are unioned and each result says where it came from, because when
-- this is wrong again the first question will be "which source found it".
function Quests.AvailableOnMap(mapID)
    mapID = mapID or select(1, CN.GetPlayerPosition())

    if not mapID then
        return {}
    end

    local found, seen = {}, {}

    local function consider(poi, source)
        if not poi or not poi.questID or seen[poi.questID] then
            return
        end

        if Blizzard.IsQuestInLog(poi.questID) then
            return
        end

        if Quests.IsCompletedByCharacter(poi.questID) then
            return
        end

        seen[poi.questID] = true

        poi.source = source

        table.insert(found, poi)
    end

    -- 1. Every map in the neighbourhood, not just the one under your feet.
    for _, relatedID in ipairs(Blizzard.RelatedMapIDs(mapID)) do
        for _, poi in ipairs(Blizzard.GetQuestPOIsOnMap(relatedID)) do
            if poi.isQuestStart and not poi.inProgress then
                consider(poi, "map")

                Quests.RememberOffer(poi)
            end
        end
    end

    -- 2. Anything an NPC has actually offered us, remembered from the
    --    conversation. Only kept while it is still plausibly nearby.
    for questID, record in pairs(Quests.RecentOffers()) do
        consider({
            questID = questID,
            mapID   = record.mapID,
            x       = record.x,
            y       = record.y,
        }, "offered")
    end

    table.sort(found, function(a, b) return a.questID < b.questID end)

    return found
end

-- QUESTS THREE ZONES AWAY.
--
-- The client's POI list only answers for a map, and only for the map the
-- player is looking at -- so "what is waiting for me in Azj-Kahet?" was
-- structurally unanswerable and the addon said so in its own scope-limits
-- note. It still cannot enumerate a zone it has never seen; what it can do
-- is remember what it HAS seen.
--
-- Every quest start observed on any map is recorded, so a zone the player
-- walked through last week can still be reported on. Bounded, and pruned
-- when a quest is completed or picked up, because a remembered pin for a
-- quest already in the log is worse than no pin.
Quests.rememberedCap = 600

local function Remembered()
    return CN.Account("questPins")
end

Quests.Remembered = Remembered

function Quests.RememberOffer(poi)
    if not poi or not poi.questID or not poi.mapID then
        return false
    end

    local store = Remembered()

    -- Only what the client cannot re-derive instantly: no names, no
    -- timestamps beyond the one that makes pruning possible.
    store[poi.questID] = {
        mapID = poi.mapID,
        x     = poi.x and math.floor(poi.x * 1000 + 0.5) / 1000 or nil,
        y     = poi.y and math.floor(poi.y * 1000 + 0.5) / 1000 or nil,
    }

    if CN.CountKeys(store) > Quests.rememberedCap then
        Quests.PruneRemembered()
    end

    return true
end

-- Drops anything no longer worth remembering: completed, in the log, or --
-- if still over the cap after that -- the lowest quest IDs, which are the
-- oldest content and the least likely to be what the player is working on.
function Quests.PruneRemembered()
    local store = Remembered()

    local dropped = 0

    -- ACCOUNT COMPLETION, NOT THIS CHARACTER'S.
    --
    -- `Remembered()` is an account-wide store of WHERE a quest is, and where
    -- a quest is does not depend on who is asking. Pruning it on
    -- `IsCompletedByCharacter` meant one character finishing a zone deleted
    -- the remembered locations for every other character who still had it to
    -- do -- the same wrong-scope defect as the quest-status store, in the
    -- other direction.
    for questID in pairs(store) do
        if Quests.IsCompletedOnAccount(questID)
            or Blizzard.IsQuestInLog(questID) then

            store[questID] = nil
            dropped = dropped + 1
        end
    end

    local remaining = CN.CountKeys(store)

    if remaining > Quests.rememberedCap then
        local ids = {}

        for questID in pairs(store) do
            table.insert(ids, questID)
        end

        table.sort(ids)

        for index = 1, remaining - Quests.rememberedCap do
            store[ids[index]] = nil
            dropped = dropped + 1
        end
    end

    return dropped
end

-- What is waiting in a zone the player is not standing in.
function Quests.RememberedInZone(mapID)
    local waiting = {}

    if not mapID then
        return waiting
    end

    for questID, record in pairs(Remembered()) do
        if record.mapID == mapID
            and not Quests.IsCompletedByCharacter(questID)
            and not Blizzard.IsQuestInLog(questID) then

            table.insert(waiting, {
                questID = questID,
                mapID   = record.mapID,
                x       = record.x,
                y       = record.y,
            })
        end
    end

    table.sort(waiting, function(a, b) return a.questID < b.questID end)

    return waiting
end

-- Every zone with something remembered in it, most first.
function Quests.RememberedZones()
    local byZone = {}

    for questID, record in pairs(Remembered()) do
        if not Quests.IsCompletedByCharacter(questID)
            and not Blizzard.IsQuestInLog(questID) then

            byZone[record.mapID] = (byZone[record.mapID] or 0) + 1
        end
    end

    local zones = {}

    for zoneID, count in pairs(byZone) do
        table.insert(zones, {
            mapID = zoneID,
            name  = Blizzard.GetMapName(zoneID),
            count = count,
        })
    end

    table.sort(zones, function(a, b)
        if a.count ~= b.count then
            return a.count > b.count
        end

        return (a.mapID or 0) < (b.mapID or 0)
    end)

    return zones
end

CN:RegisterEvent("QUEST_TURNED_IN", function()
    Quests.PruneRemembered()
end)

CN:RegisterCommand{
    -- RENAMED. "Waiting" reads as "waiting on a timer", which is what
    -- `/cn now` and `/cn clock` do -- three commands about deadlines, and
    -- this one is not about deadlines at all.
    name    = "unpicked",
    aliases = { "waiting" },
    args    = "[zone name]",
    order   = 23,
    help    = "Quests you have walked past and never picked up, by zone.",
    handler = function(args)
        args = CN.Trim(args or "")

        local zones = Quests.RememberedZones()

        if #zones == 0 then
            Print("Nothing remembered yet.")
            Print("|cff8a8f96The addon records quest starts as it sees them. "
                .. "Walk through a zone once and it can tell you what you "
                .. "left behind in it.|r")
            return
        end

        if args ~= "" then
            for _, zone in ipairs(zones) do
                if zone.name and string.lower(zone.name):find(string.lower(args), 1, true) then
                    Print(zone.name .. ": " .. zone.count .. " left behind")

                    for index, entry in ipairs(Quests.RememberedInZone(zone.mapID)) do
                        if index > 20 then
                            Print("  |cff8a8f96... and more|r")
                            break
                        end

                        Print("  " .. (Quests.GetName(entry.questID)
                            or ("quest " .. entry.questID)))
                    end

                    return
                end
            end

            Print("Nothing remembered in a zone matching \"" .. args .. "\".")
            return
        end

        Print("Quests you have seen and not taken:")

        for index, zone in ipairs(zones) do
            if index > 12 then
                Print("  |cff8a8f96... and " .. (#zones - 12) .. " more zones|r")
                break
            end

            Print(string.format("  %-28s %d",
                tostring(zone.name or zone.mapID), zone.count))
        end

        Print("|cff8a8f96This is what the addon has actually seen, not every "
            .. "quest in the game -- the client only lists pins for the map "
            .. "you are looking at.|r")
    end,
}

-- HOW FAR IS "HERE".
--
-- Searching the parent map and its siblings is what fixed a player being told
-- zero while standing in front of a quest giver. It also means the answer now
-- spans a whole zone, so calling it "here" overstates it -- the addon would
-- be pointing at something a four-minute ride away and using a word that
-- means arm's reach.
--
-- Split by distance where coordinates exist, and say the honest word for
-- each. Anything without coordinates is reported as "in this zone", because
-- that is the strongest claim the data supports.
CN.nearbyYards = 300

function Quests.SplitAvailableByDistance(available, mapID)
    local near, zone = {}, {}

    local playerMap, playerX, playerY = CN.GetPlayerPosition()

    local nav = CN:GetModule("Navigation")

    for _, poi in ipairs(available or {}) do
        local yards

        if nav and nav.DistanceYards and playerX and playerY
            and poi.x and poi.y and (poi.mapID or mapID) == playerMap then

            yards = nav.DistanceYards(playerMap, playerX, playerY, poi.x, poi.y)
        end

        poi.yards = yards

        if yards and yards <= CN.nearbyYards then
            table.insert(near, poi)
        else
            table.insert(zone, poi)
        end
    end

    return near, zone
end

-- World quests and bonus objectives, deliberately counted SEPARATELY.
--
-- They are available in the dictionary sense, and they are not what a player
-- means by "quests I can pick up here" -- there is no exclamation mark and
-- nobody to talk to. Folding them into that number makes it stop matching
-- what is on the screen, which is the entire complaint this code exists to
-- answer.
function Quests.TasksOnMap(mapID)
    mapID = mapID or select(1, CN.GetPlayerPosition())

    if not mapID then
        return {}
    end

    local tasks = {}

    for _, task in ipairs(Blizzard.GetTaskQuestsOnMap(mapID)) do
        if not Quests.IsCompletedByCharacter(task.questID) then
            table.insert(tasks, task)
        end
    end

    return tasks
end

------------------------------------------------------------
-- WHAT AN NPC ACTUALLY OFFERED
------------------------------------------------------------

-- A conversation cannot be wrong about what it is offering. Map data can.
local recentOffers = {}

Quests.offerMemorySeconds = 900

function Quests.RecentOffers()
    local now = time()

    for questID, record in pairs(recentOffers) do
        if now - (record.at or 0) > Quests.offerMemorySeconds then
            recentOffers[questID] = nil
        end
    end

    return recentOffers
end

function Quests.NoteOffered(questID, title)
    if not questID or Quests.IsCompletedByCharacter(questID) then
        return false
    end

    if Blizzard.IsQuestInLog(questID) then
        return false
    end

    local mapID, x, y = CN.GetPlayerPosition()

    recentOffers[questID] = {
        at    = time(),
        mapID = mapID,
        x     = x,
        y     = y,
    }

    if title and title ~= "" then
        Quests.SetMetadata(questID, title, "offered")
    end

    if mapID and x and y then
        Quests.SetLocation(questID, mapID, x, y, "offered")
    end

    Quests.RecordDiscovered(questID, "offered")

    DebugPrint("Noted quest " .. questID .. " offered by an NPC here.")

    return true
end

function Quests.ForgetOffer(questID)
    if questID then
        recentOffers[questID] = nil
    end
end

-- Talking to someone is the single most reliable moment to learn that a
-- quest exists here, so take it every time.
CN:RegisterEvent("GOSSIP_SHOW", function()
    for _, offer in ipairs(Blizzard.GetGossipAvailableQuests()) do
        Quests.NoteOffered(offer.questID, offer.title)
    end
end)

CN:RegisterEvent("QUEST_DETAIL", function()
    Quests.NoteOffered(Blizzard.GetActiveQuestOffer(), GetTitleText and GetTitleText())
end)

CN:RegisterEvent("QUEST_ACCEPTED", function(_, questID)
    Quests.ForgetOffer(questID)
end)

------------------------------------------------------------
-- DIAGNOSIS
------------------------------------------------------------

-- When a player says "it says zero and I am standing in front of one", the
-- useful reply is not a guess. It is a listing of every map that was asked,
-- what each one answered, and why each answer was rejected.
function Quests.AvailableDiagnostic(mapID)
    mapID = mapID or select(1, CN.GetPlayerPosition())

    local report = {
        mapID  = mapID,
        maps   = {},
        counts = { start = 0, inLog = 0, completed = 0, notStart = 0, task = 0, offered = 0 },
    }

    if not mapID then
        return report
    end

    for _, relatedID in ipairs(Blizzard.RelatedMapIDs(mapID)) do
        local pois = Blizzard.GetQuestPOIsOnMap(relatedID)

        local row = {
            mapID = relatedID,
            name  = Blizzard.GetMapName(relatedID),
            pois  = #pois,
            starts = 0,
            usable = 0,
        }

        for _, poi in ipairs(pois) do
            if poi.isQuestStart and not poi.inProgress then
                row.starts = row.starts + 1

                if Blizzard.IsQuestInLog(poi.questID) then
                    report.counts.inLog = report.counts.inLog + 1
                elseif Quests.IsCompletedByCharacter(poi.questID) then
                    report.counts.completed = report.counts.completed + 1
                else
                    row.usable = row.usable + 1
                    report.counts.start = report.counts.start + 1
                end
            else
                report.counts.notStart = report.counts.notStart + 1
            end
        end

        table.insert(report.maps, row)
    end

    report.counts.task    = #Blizzard.GetTaskQuestsOnMap(mapID)
    report.counts.offered = CN.CountKeys(Quests.RecentOffers())

    return report
end

-- How many quests are on offer here that you have not taken.
--
-- This is the number a player means by "new", and it took a fourteen-year-old
-- to say so plainly. The addon used to report how many quests it had written
-- into its own database for the first time -- a scanner statistic, correct and
-- useless, which drops to zero forever once a zone has been walked. He read
-- "0 new" in a zone with exclamation marks visible on his screen and
-- concluded, reasonably, that the addon was broken.
--
-- A number shown to a player has to be about the player's world. If it is
-- about the addon's bookkeeping it belongs in debug output.
function Quests.AvailableCount(mapID)
    return #Quests.AvailableOnMap(mapID)
end

------------------------------------------------------------
-- SAYING SO WHEN IT IS WORTH SAYING
------------------------------------------------------------

-- THE ADDON KNEW AND SAID NOTHING.
--
-- Walking into a zone with seven unpicked quests in it is the single most
-- common moment at which "what should I do next?" has an obvious answer, and
-- the addon computed that number on arrival and kept it to itself until
-- somebody thought to type `/cn zone`.
--
-- This is a prompt, not an action: it names a number and a command. It does
-- not accept a quest, move a waypoint, or open anything.
--
-- Bounded three ways, because a line that appears too often is a line people
-- turn off: once per zone per session, only when there are enough of them to
-- be worth a detour, and never while the player is busy.
Quests.arrivalMinimum = 3

-- ONCE PER SESSION WAS TOO ONCE.
--
-- The latch was a permanent per-session flag, so a player who logs in at nine
-- and plays until two is told about a zone the first time they enter it and
-- never again -- including after clearing it, flying to another continent,
-- and coming back four hours later to the quests they left behind. That is
-- the moment the prompt is most useful and the one moment it could not fire.
--
-- A timestamp instead of a boolean, and a long window. Long enough that
-- crossing a zone border twice while running a loop cannot re-prompt; short
-- enough that a genuine return counts as a return.
local announcedZones = {}

Quests.arrivalMemorySeconds = 7200

-- Called when the PLAYER asks the addon to rediscover what is out there --
-- `/cn discoveractive`, or the Quests tab's rescan button. The latch is a
-- record of what they have already been told, and somebody deliberately
-- asking to be told again is the one thing that clearly overrides it.
--
-- DELIBERATELY NOT CALLED FROM `DiscoverActive` ITSELF. That runs off
-- `QUEST_LOG_UPDATE` on a ten-second throttle, so wiping the latch there
-- would have replaced a seven-thousand-second window with a ten-second one --
-- and stepping into a cave and back out would re-prompt. A worse bug than the
-- one it was meant to fix, dressed as a fix.
function Quests.ForgetArrivals()
    announcedZones = {}
end

function Quests.AnnounceArrival(mapID)
    mapID = mapID or CN.GetPlayerPosition()

    if not mapID then
        return false
    end

    local announcedAt = announcedZones[mapID]

    local now = (time and time()) or 0

    if announcedAt and (now - announcedAt) < Quests.arrivalMemorySeconds then
        return false
    end

    -- In a fight is not a moment for a suggestion, and neither is a flight
    -- path: `ZONE_CHANGED_NEW_AREA` fires for every zone a taxi crosses, so a
    -- cross-continent flight was prompting about zones being flown OVER --
    -- and latching out the zone actually being flown to.
    if InCombatLockdown and InCombatLockdown() then
        return false
    end

    if UnitOnTaxi and UnitOnTaxi("player") then
        return false
    end

    local available = Quests.AvailableOnMap(mapID)

    -- THE LATCH IS SET ONLY IF SOMETHING WAS SAID.
    --
    -- It used to be set before the threshold test, and this runs on a
    -- three-second timer whose own comment concedes the quest pins may not
    -- have arrived. So a slow load meant the count was short, the zone was
    -- marked announced for the session, and the prompt never fired for it --
    -- silently, and for the zones a player most wants it in.
    if #available < Quests.arrivalMinimum then
        return false
    end

    announcedZones[mapID] = now

    local zone = Blizzard.GetMapName(mapID) or "This zone"

    CN.PrintBlock(zone .. ": " .. CN.Brand(#available)
        .. " quest" .. (#available == 1 and "" or "s")
        .. " here you have not picked up",
        {
            CN.Accent("/cn zone")
                .. CN.Muted(" routes them, nearest first."),
        })

    return true
end

CN:RegisterEvent("ZONE_CHANGED_NEW_AREA", function()
    -- Delayed: the map is not reliable in the frame the event fires, and the
    -- quest pins arrive after it.
    --
    -- The map is captured NOW rather than read at fire time. Read three
    -- seconds later it resolves against wherever the player happens to be,
    -- which on a taxi is a different zone entirely.
    if not C_Timer or not C_Timer.After then
        return
    end

    local arrivedAt = CN.GetPlayerPosition()

    if not arrivedAt then
        return
    end

    C_Timer.After(3, function()
        -- Still there? A player who zoned again inside three seconds is not
        -- being told about the zone they left.
        if CN.GetPlayerPosition() ~= arrivedAt then
            return
        end

        pcall(Quests.AnnounceArrival, arrivedAt)
    end)
end)

function Quests.DiscoverActive()
    local entries = Blizzard.GetQuestLogEntries()

    if #entries == 0 and not C_QuestLog then
        Print("Quest Log API is unavailable.")
        return 0, 0
    end


    local seen = 0
    local new  = 0

    for _, info in ipairs(entries) do
        if Quests.RecordDiscovered(info.questID, "questlog") then
            new = new + 1
        end

        if info.title and info.title ~= "" then
            Quests.SetMetadata(info.questID, info.title, "questlog")
        end

        seen = seen + 1
    end

    -- Quests offered in this zone but not yet accepted.
    --
    -- Without these, "new" settled at zero permanently after the first scan:
    -- the only thing being discovered was your own quest log, which stops
    -- changing the moment you have scanned it once.
    for _, poi in ipairs(Quests.AvailableOnMap()) do
        if Quests.RecordDiscovered(poi.questID, "available") then
            new = new + 1
        end

        local title = Blizzard.GetQuestTitle(poi.questID, true)

        if title and title ~= "" then
            Quests.SetMetadata(poi.questID, title, "available")
        end

        if poi.x and poi.y then
            Quests.SetLocation(poi.questID, poi.mapID, poi.x, poi.y, "available")
        end

        seen = seen + 1
    end

    return seen, new
end

------------------------------------------------------------
-- STATUS
------------------------------------------------------------

-- ASKED, NOT REMEMBERED.
--
-- This used to write the answer into an account-wide `questStatus` table.
-- Both fields come from a free synchronous client call, so there was nothing
-- to gain by storing them -- and `IsQuestFlaggedCompleted` answers for the
-- character asking, so storing it account-wide meant a main's four thousand
-- completions were read back as every alt's. `/cn breakdown` on a fresh alt
-- reported the main's progress, and scanning on the alt destroyed the main's
-- record.
--
-- Migration 7 drops the store. The name is kept because callers want the pair
-- of answers, and asking through one function keeps the two questions
-- together.
function Quests.RecordStatus(questID)
    return Quests.IsCompletedByCharacter(questID),
        Quests.IsCompletedOnAccount(questID)
end

function Quests.ScanKnown()
    local scanned, byCharacter, onAccount = 0, 0, 0

    for questID in pairs(CN.Account("discoveredQuests")) do
        local characterCompleted, accountCompleted = Quests.RecordStatus(questID)

        scanned = scanned + 1

        if characterCompleted then
            byCharacter = byCharacter + 1
        end

        if accountCompleted then
            onAccount = onAccount + 1
        end
    end

    -- The only setup step that does not go through `CN.MarkScanned`, because
    -- it scans nothing collectible -- but the setup record still has to know
    -- it ran, or the login reminder asks for it forever.
    if CN.NoteSetupStep then
        CN.NoteSetupStep("quests")
    end

    return scanned, byCharacter, onAccount
end

------------------------------------------------------------
-- ELIGIBILITY
------------------------------------------------------------

-- Curated static data first, then whatever external addons know, then
-- anything harvested from this account's own play. Static wins because it is
-- the only source this addon controls and ships.
function Quests.GetRecord(questID)
    local static = CN.Static.GetQuest(questID)

    if static and (static.requires or static.obsolete or static.requiresLevel) then
        return static, "static"
    end

    local external = CN.QueryQuestDataProviders(questID)

    if external and (external.requires or external.requiresLevel) then
        return external, table.concat(external.providers or { "external" }, "+")
    end

    local harvested = CN.Account("questHarvest")[questID]

    if harvested and harvested.requires then
        return harvested, "harvested"
    end

    return static, static and "static" or nil
end

CN.RegisterEligibilityChecker(CN.objectiveTypes.QUEST, function(questID)
    local states = CN.objectiveStates

    if Quests.IsCompletedByCharacter(questID) then
        return states.COMPLETED, "Already completed by this character", nil
    end

    local static = Quests.GetRecord(questID)

    if static then
        if static.obsolete then
            return states.UNOBTAINABLE, CN.blockReasons.OBSOLETE, nil
        end

        if static.requires then
            for _, prerequisiteID in ipairs(static.requires) do
                if not Quests.IsCompletedByCharacter(prerequisiteID) then
                    return states.LOCKED,
                           CN.blockReasons.PREREQUISITE_QUEST,
                           Quests.GetName(prerequisiteID) or ("quest " .. prerequisiteID)
                end
            end
        end



        if static.requiresLevel and UnitLevel("player") < static.requiresLevel then
            return states.LOCKED, CN.blockReasons.LEVEL_TOO_LOW, tostring(static.requiresLevel)
        end

        if static.requiresFaction and CN.character
            and CN.character.faction ~= static.requiresFaction then
            return states.INELIGIBLE, CN.blockReasons.WRONG_FACTION, static.requiresFaction
        end
    end

    -- CURATED GATING (0.43.0).
    --
    -- Class, race, faction and level, from the static database. The client
    -- handles this implicitly by not drawing a pin you do not qualify for,
    -- which works while you are standing there and answers nothing when you
    -- ask "could any of my characters do this?" -- which is precisely what
    -- /cn alts is for.
    local eligible, gateReason = CN.Static.QuestEligibility(questID)

    if not eligible then
        local reason = CN.blockReasons.WRONG_CLASS

        if gateReason:find("^race") then
            reason = CN.blockReasons.WRONG_RACE
        elseif gateReason:find("^level") then
            reason = CN.blockReasons.LEVEL_TOO_LOW
        elseif gateReason:find("Alliance") or gateReason:find("Horde") then
            reason = CN.blockReasons.WRONG_FACTION
        end

        return states.INELIGIBLE, reason, gateReason
    end

    -- Prerequisites nobody curated, inferred from repeated observation
    -- across characters.
    --
    -- Reported as LIKELY_PREREQUISITE, never as PREREQUISITE_QUEST. The
    -- addon has watched an ordering hold on several characters; that is
    -- strong evidence and it is still not the same claim as knowing. It
    -- must not be possible to mistake one for the other in the output.
    local dependency = CN.GetDependency(
        CN.ObjectiveKey(CN.objectiveTypes.QUEST, questID))

    if dependency and dependency.observedRequires then
        local harvest = CN:GetModule("Harvest")

        for _, prerequisiteID in ipairs(dependency.observedRequires) do
            if not Quests.IsCompletedByCharacter(prerequisiteID) then
                local name = Quests.GetName(prerequisiteID)
                    or ("quest " .. prerequisiteID)

                -- WHERE THE EDGE CAME FROM DECIDES WHAT THE LINE CAN CLAIM.
                --
                -- An imported chain was never observed by this player, so
                -- the harvest store has nothing for it and the character
                -- count came back zero -- "seen first on 0 characters",
                -- printed as evidence. Say which kind of edge it is.
                if dependency.origin == "contributed" then
                    return states.LOCKED,
                           CN.blockReasons.LIKELY_PREREQUISITE,
                           name .. " (from an imported chain, not from your "
                               .. "own play)"
                end

                local characters = harvest
                    and harvest.Confidence(harvest.Store()[questID], prerequisiteID)
                    or 0

                return states.LOCKED,
                       CN.blockReasons.LIKELY_PREREQUISITE,
                       name .. " (seen first on " .. characters
                           .. " characters)"
            end
        end
    end

    return states.AVAILABLE, nil, nil
end)

------------------------------------------------------------
-- LOCATION
------------------------------------------------------------

-- Coordinates the player supplied by hand, for quests the client will not
-- answer for. Persisted account-wide: a location is a fact about the world,
-- not about one character.
local function Overrides()
    return CN.Account("questLocations")
end

Quests.Overrides = Overrides

-- `source` says where the coordinates came from: nil or "manual" for a
-- player typing them, "offered" for a quest giver's gossip, "available" for a
-- map pin. Two callers have always passed it and this function has always
-- ignored it -- the parameter was not even declared -- so `/cn where`
-- attributed machine-learned coordinates to the player, and the block comment
-- above describing this store as "coordinates the player supplied by hand"
-- was false in both directions.
function Quests.SetLocation(questID, mapID, x, y, source)
    if not questID or not mapID or not x or not y then
        return false
    end

    -- Accept either 0-1 or 0-100; the map API wants 0-1.
    if x > 1 then x = x / 100 end
    if y > 1 then y = y / 100 end

    if x <= 0 or x >= 1 or y <= 0 or y >= 1 then
        return false
    end

    Overrides()[questID] = {
        mapID  = mapID,
        x      = x,
        y      = y,
        setAt  = time(),
        source = source,
    }

    return true
end

-- Live client data first, then the player's own override, then curated
-- static data. Live wins because it tracks the quest's *current* step.
function Quests.GetLocation(questID)
    local mapID, x, y = Blizzard.GetQuestWaypoint(questID)

    -- A CURATED TURN-IN BEATS THE CLIENT'S MOVING WAYPOINT.
    --
    -- `Static.GetQuestTurnIn` has existed since the three-phase quest model
    -- was designed -- "a quest is a pick up, a do, and a turn in" -- with a
    -- documented schema, and was called by nothing at all: the harness's dead
    -- code check listed it by name. So the third phase, the one the design
    -- rests on, has always used the client's waypoint, which points at
    -- whatever the quest currently wants rather than at the person who takes
    -- it back.
    --
    -- Only when the quest is actually ready to hand in. Before that the
    -- client's waypoint is the better answer, because it moves with the work.
    if CN.Static and CN.Static.GetQuestTurnIn
        and Blizzard.IsQuestReadyForTurnIn
        and Blizzard.IsQuestReadyForTurnIn(questID) then

        local turnMap, turnX, turnY = CN.Static.GetQuestTurnIn(questID)

        if turnMap and turnX and turnY then
            return turnMap, turnX, turnY, "turn-in"
        end
    end

    if mapID and x and y then
        return mapID, x, y, "blizzard"
    end

    local override = Overrides()[questID]

    if override and override.mapID and override.x and override.y then
        return override.mapID, override.x, override.y, override.source or "manual"
    end

    local staticMap, staticX, staticY = CN.Static.GetQuestLocation(questID)

    if staticMap and staticX and staticY then
        return staticMap, staticX, staticY, "static"
    end

    return mapID or staticMap, nil, nil, nil
end

------------------------------------------------------------
-- CANDIDATES
------------------------------------------------------------

CN.RegisterCandidateProvider("Quests", function()
    local candidates = {}

    -- The coordinates are no longer needed here: travel cost is asked for
    -- by map and point, and CN.TravelCost reads the player's position itself
    -- so that every provider costs a journey the same way.
    local playerMap = CN.GetPlayerPosition()

    local seen = {}

    local function add(questID, name, isActive, availablePOI)
        if not questID or seen[questID] then
            return
        end

        if CN.IsIgnored(CN.objectiveTypes.QUEST, questID)
            or CN.IsDeferred(CN.objectiveTypes.QUEST, questID) then
            return
        end

        seen[questID] = true

        local mapID, x, y, source = Quests.GetLocation(questID)

        local reasons = {}
        local value   = 1
        local travel  = 0

        -- An available quest carries its own pin, which is more current than
        -- anything recorded earlier.
        if availablePOI then
            mapID  = availablePOI.mapID or mapID
            x      = availablePOI.x or x
            y      = availablePOI.y or y
            source = "available"

            -- Weighted above an accepted quest you have not started: going to
            -- get a quest is cheap, it is right here, and it unlocks
            -- everything that quest leads to.
            value = value + 2

            table.insert(reasons, "available to pick up in this zone")

            if availablePOI.isDaily then
                table.insert(reasons, "daily")
            end
        end

        -- A DEADLINE THE ADDON ALREADY KNEW AND WAS NOT ATTACHING.
        --
        -- 0.28.0 added an urgency curve that weights anything carrying
        -- `expiresIn`, and then only world quests and the Vault set it. A
        -- daily disappears at the daily reset and a weekly at the weekly one;
        -- both are knowable to the minute, and neither was being said. The
        -- headline feature of that release was close to inert.
        local expiry

        if availablePOI and availablePOI.isDaily then
            expiry = Blizzard.GetSecondsUntilDailyReset()
        elseif isActive and Blizzard.IsQuestInLog(questID) then
            local timeLeft = Blizzard.GetQuestTimeLeft(questID)

            if timeLeft and timeLeft > 0 then
                expiry = timeLeft
            end
        end

        if isActive then
            if Blizzard.IsQuestReadyForTurnIn(questID) then
                value = value + 3
                table.insert(reasons, "ready to turn in")
            else
                local done, total = Blizzard.GetQuestObjectiveProgress(questID)

                if total > 0 and done > 0 then
                    value = value + 1
                    table.insert(reasons, done .. " of " .. total .. " objectives already done")
                end
            end
        end

        local static = CN.Static.GetQuest(questID)

        if static and static.unlocks and #static.unlocks > 0 then
            value = value + #static.unlocks
            table.insert(reasons, "unlocks " .. #static.unlocks .. " further quest(s)")
        end

        if mapID and playerMap then
            if mapID == playerMap then
                table.insert(reasons, "in your current zone")
            end

            -- COSTED AS THE JOURNEY YOU WOULD ACTUALLY MAKE.
            --
            -- Before 0.42.0 this was a straight line within the zone and a
            -- flat 25 for anywhere else -- so the zone over the ridge and the
            -- far side of the continent cost exactly the same, and a zone
            -- with a flight master in it cost the same as one without.
            local measured, fromTravel = CN.TravelCost(mapID, x, y)

            travel = measured or travel

            if fromTravel and mapID ~= playerMap then
                table.insert(reasons, "another zone, costed by how long the "
                    .. "journey actually takes")
            end
        elseif not mapID then
            -- Unknown location: usable as a suggestion, useless for routing.
            travel = 5
        end

        table.insert(candidates, CN.NewObjective({
            id                = questID,
            type              = CN.objectiveTypes.QUEST,
            name              = name or Quests.GetName(questID) or ("Quest " .. questID),
            mapID             = mapID,
            x                 = x,
            y                 = y,
            source            = source,
            phase             = Quests.Phase(questID),
            state             = CN.objectiveStates.AVAILABLE,
            completionValue   = value,
            travelCost        = travel,
            expiresIn         = expiry,
            reasons           = reasons,
        }))
    end

    for _, info in ipairs(Blizzard.GetQuestLogEntries()) do
        add(info.questID, info.title, true)
    end

    -- Quests standing in this zone waiting to be picked up.
    --
    -- This is the fix for the most basic possible complaint: the addon showed
    -- only quests you had already accepted, so it could never tell you to go
    -- and get one. Picking up a quest twenty yards away is often the single
    -- best next action available, and it was invisible.
    for _, poi in ipairs(Quests.AvailableOnMap(playerMap)) do
        local name = Quests.GetName(poi.questID)
            or Blizzard.GetQuestTitle(poi.questID, true)
            or ("Quest " .. poi.questID)

        add(poi.questID, name, false, poi)
    end

    -- Curated quests that are not in the log and not yet completed.
    for questID, record in pairs(CN.Static.quests) do
        if not record.obsolete and not Quests.IsCompletedByCharacter(questID) then
            local state = CN.Explain(CN.objectiveTypes.QUEST, questID)

            if state == CN.objectiveStates.AVAILABLE then
                add(questID, record.name, false)
            end
        end
    end

    return candidates
end, { events = { "QUEST_ACCEPTED", "QUEST_TURNED_IN", "QUEST_REMOVED", "QUEST_LOG_UPDATE", "ZONE_CHANGED_NEW_AREA" }, cooldown = 2 })

------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

CN:RegisterEvent("QUEST_DATA_LOAD_RESULT", function(event, questID, success)
    if not CN.pendingQuestLoads[questID] then
        return
    end

    CN.pendingQuestLoads[questID] = nil

    if not success then
        DebugPrint("Quest " .. tostring(questID) .. " metadata was unavailable from Blizzard.")
        return
    end

    local title = Blizzard.GetQuestTitle(questID, false)

    if title then
        Quests.SetMetadata(questID, title, "blizzard")
        Print("Quest " .. questID .. " - " .. title)
    else
        DebugPrint("Quest " .. questID .. " loaded, but no title was returned.")
    end
end)

CN:RegisterEvent("QUEST_ACCEPTED", function(event, questID)
    if not questID then
        return
    end

    Quests.RecordDiscovered(questID, "questlog")

    local title = Blizzard.GetQuestTitle(questID, true)

    if title then
        Quests.SetMetadata(questID, title, "questlog")
    end

    Quests.RecordStatus(questID)

    DebugPrint("Quest accepted: " .. questID)
end)

CN:RegisterEvent("QUEST_TURNED_IN", function(event, questID)
    if not questID then
        return
    end

    Quests.RecordDiscovered(questID, "questlog")
    Quests.RecordStatus(questID)

    DebugPrint("Quest turned in: " .. questID)
end)

CN:RegisterEvent("QUEST_REMOVED", function(event, questID)
    if not questID then
        return
    end

    Quests.RecordStatus(questID)

    DebugPrint("Quest removed from log: " .. questID)
end)

-- QUEST_LOG_UPDATE fires constantly; throttle a full rescan.
local lastLogScan = 0

CN:RegisterEvent("QUEST_LOG_UPDATE", function()
    local now = time()

    if now - lastLogScan < 10 then
        return
    end

    lastLogScan = now

    local seen, new = Quests.DiscoverActive()

    if new > 0 then
        DebugPrint("Quest Log scan discovered " .. new .. " new quests (" .. seen .. " active).")
    end
end)

CN:OnLogin(function()
    local seen, new = Quests.DiscoverActive()

    DebugPrint("Login quest scan: " .. seen .. " active, "
        .. new .. " newly recorded.")
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "quest",
    aliases = { "q" },
    args    = "<questID>",
    order   = 20,
    help    = "Check whether a quest is completed.",
    handler = function(args)
        local questID = CN.ToID(args)

        if not questID then
            Print("Usage: /cn quest <questID>")
            return
        end

        Quests.RecordDiscovered(questID, "manual")

        local characterCompleted, accountCompleted = Quests.RecordStatus(questID)

        local name = Quests.GetName(questID, true)

        if name then
            Print("Quest " .. questID .. " - " .. name .. ":")
        else
            Print("Quest " .. questID .. ":")
        end

        Print("Character completion: " .. CN.YesNo(characterCompleted))

        if Blizzard.HasAccountQuestAPI() then
            Print("Account/Warband completion: " .. CN.YesNo(accountCompleted))
        else
            Print("Account/Warband completion: |cffffc74fAPI unavailable|r")
        end

        local state, reason, detail = CN.Explain(CN.objectiveTypes.QUEST, questID)

        Print("State: " .. state .. (reason and (" - " .. reason) or "")
            .. (detail and (" (" .. detail .. ")") or ""))
    end,
}

CN:RegisterCommand{
    name    = "cache",
    args    = "<questID>",
    order   = 21,
    help    = "Show cached quest metadata.",
    handler = function(args)
        local questID = CN.ToID(args)

        if not questID then
            Print("Usage: /cn cache <questID>")
            return
        end

        local cached = Quests.GetMetadata(questID)

        if cached and cached.name then
            Print("Cached quest " .. questID .. ": " .. cached.name
                .. " |cff8a8f96[" .. tostring(cached.source) .. "]|r")
        else
            Print("No cached metadata for quest " .. questID .. ".")
        end
    end,
}

CN:RegisterCommand{
    name    = "setquest",
    args    = "<questID> <name>",
    order   = 22,
    help    = "Manually save quest metadata.",
    handler = function(args)
        local questIDText, name = args:match("^(%d+)%s+(.+)$")

        local questID = CN.ToID(questIDText)

        if not questID or not name or name == "" then
            Print("Usage: /cn setquest <questID> <name>")
            return
        end

        if Quests.SetMetadata(questID, name, "manual") then
            Print("Saved quest " .. questID .. ": " .. name)
        else
            Print("Kept the existing, more authoritative name for quest " .. questID .. ".")
        end
    end,
}

CN:RegisterCommand{
    name    = "queststatus",
    args    = "<questID>",
    order   = 23,
    help    = "Show this character's completion state for a quest.",
    handler = function(args)
        local questID = CN.ToID(args)

        if not questID then
            Print("Usage: /cn queststatus <questID>")
            return
        end

        local characterCompleted, accountCompleted = Quests.RecordStatus(questID)

        Print("Quest " .. questID .. ", as the client answers right now:")
        Print("Character completion: " .. CN.YesNo(characterCompleted))
        Print("Account/Warband completion: " .. CN.YesNo(accountCompleted))
    end,
}

CN:RegisterCommand{
    name    = "scanquests",
    order   = 24,
    help    = "Scan known quest IDs for completion.",
    handler = function()
        local scanned, byCharacter, onAccount = Quests.ScanKnown()

        Print("Scanned " .. scanned .. " known quests.")
        Print("Character completed: " .. byCharacter)
        Print("Account/Warband completed: " .. onAccount)
    end,
}

CN:RegisterCommand{
    name    = "discovered",
    order   = 25,
    help    = "Show the number of discovered quests.",
    handler = function()
        Print("Discovered quests: " .. CN.CountKeys(CN.Account("discoveredQuests")))
        Print("Cached quest names: " .. CN.CountKeys(CN.Account("questMetadata")))
    end,
}

CN:RegisterCommand{
    name    = "available",
    aliases = { "pickup", "offered" },
    -- NO ARGUMENTS. This read "[zone name is not needed; uses the zone you
    -- are in]" -- a note, rendered by the help printer as an argument spec,
    -- so `/cn help` showed `/cn available [zone name is not needed; uses the
    -- zone you are in]`. The note belongs in the help text.
    order   = 13,
    help    = "List the quests offered in the zone you are in that you have "
        .. "not accepted.",
    handler = function()
        local mapID = select(1, CN.GetPlayerPosition())

        local available = Quests.AvailableOnMap(mapID)

        if #available == 0 then
            Print("Nothing here is offering you a quest you have not taken.")
            Print("|cff8a8f96That counts quest starts the map is showing. A "
                .. "giver you have not walked past yet is not on the map, so "
                .. "it is not counted.|r")
            return
        end

        local near, zone = Quests.SplitAvailableByDistance(available, mapID)

        if #near > 0 then
            Print(#near .. " quest" .. (#near == 1 and "" or "s")
                .. " available right here:")
        else
            Print(#available .. " quest" .. (#available == 1 and "" or "s")
                .. " available in this zone, none within "
                .. CN.nearbyYards .. " yards:")
        end

        for _, poi in ipairs(#near > 0 and near or zone) do
            local title = Quests.GetName(poi.questID)
                or Blizzard.GetQuestTitle(poi.questID, true)
                or ("Quest " .. poi.questID)

            local where = ""

            if poi.x and poi.y then
                where = string.format(" |cff8a8f96(%.1f, %.1f)|r",
                    poi.x * 100, poi.y * 100)
            end

            Print("  |cffffc74f" .. title .. "|r" .. where)
        end

        if #near > 0 and #zone > 0 then
            Print("|cff8a8f96Plus " .. #zone
                .. " further out in this zone.|r")
        end

        local tasks = Quests.TasksOnMap(mapID)

        if #tasks > 0 then
            Print("|cff8a8f96Also " .. #tasks .. " world quest"
                .. (#tasks == 1 and "" or "s")
                .. " or bonus objective in this zone -- no giver to talk "
                .. "to.|r")
        end

        Print("|cff8a8f96These are in your recommendations and in |r/cn zone"
            .. "|cff8a8f96 too.|r")
    end,
}

CN:RegisterCommand{
    name    = "whyzero",
    aliases = { "diagquests" },
    order   = 29,
    help    = "Explain why the available-quest count is what it is.",
    handler = function()
        local report = Quests.AvailableDiagnostic()

        if not report.mapID then
            Print("The client will not say which map you are on.")
            return
        end

        Print("Available-quest diagnosis for map " .. report.mapID
            .. " (" .. tostring(Blizzard.GetMapName(report.mapID) or "?") .. "):")

        for _, row in ipairs(report.maps) do
            Print(string.format("  %-28s %3d pins, %2d starts, %2d usable",
                tostring(row.name or row.mapID),
                row.pois, row.starts, row.usable))
        end

        Print("Rejected: " .. report.counts.inLog .. " already in your log, "
            .. report.counts.completed .. " already completed, "
            .. report.counts.notStart .. " not quest starts.")

        Print("Other sources: " .. report.counts.task .. " bonus/world, "
            .. report.counts.offered .. " remembered from conversations.")

        if report.counts.start == 0 and report.counts.offered == 0 then
            Print("|cffffc74fIf you can see an exclamation mark from here, the "
                .. "client has not published that pin to any of the maps "
                .. "above. Talk to the NPC once and it will be remembered.|r")
        end
    end,
}

CN:RegisterCommand{
    name    = "discoveractive",
    order   = 26,
    help    = "Discover quests currently in the Quest Log.",
    handler = function()
        -- Somebody asking to be told what is out there overrides the record
        -- of having already told them.
        Quests.ForgetArrivals()

        local seen, recorded = Quests.DiscoverActive()

        local available = Quests.AvailableCount()

        Print("Quests: " .. seen .. " in your log, "
            .. "|cffffc74f" .. available .. "|r available to pick up nearby.")

        DebugPrint(recorded .. " newly recorded in the database.")
    end,
}

CN:RegisterCommand{
    name    = "where",
    args    = "<questID>",
    order   = 28,
    help    = "Show what location is known for a quest.",
    handler = function(args)
        local questID = CN.ToID(args)

        if not questID then
            Print("Usage: /cn where <questID>")
            return
        end

        local mapID, x, y, source = Quests.GetLocation(questID)

        Print("Quest " .. questID .. " - "
            .. (Quests.GetName(questID, true) or "unknown name"))

        if mapID and x and y then
            Print(string.format("Location: map %d at %.1f, %.1f |cff8a8f96[%s]|r",
                mapID, x * 100, y * 100, tostring(source)))
        elseif mapID then
            Print("Map " .. mapID .. " |cffffc74f(no coordinates)|r")
        else
            Print("|cffe2564cNo location is known.|r")
        end

        Print("In your quest log: " .. CN.YesNo(Blizzard.IsQuestInLog(questID)))
    end,
}

CN:RegisterCommand{
    name    = "setloc",
    args    = "<questID> <mapID> <x> <y>",
    order   = 29,
    help    = "Record coordinates for a quest by hand.",
    handler = function(args)
        local questID, mapID, x, y =
            args:match("^(%d+)%s+(%d+)%s+([%d%.]+)%s+([%d%.]+)$")

        questID = CN.ToID(questID)
        mapID   = CN.ToID(mapID)
        x       = tonumber(x)
        y       = tonumber(y)

        if not questID or not mapID or not x or not y then
            Print("Usage: /cn setloc <questID> <mapID> <x> <y>")
            Print("Coordinates may be 0-1 or 0-100. Find the map ID with "
                .. "|cffffc74f/cn where|r or /dump C_Map.GetBestMapForUnit(\"player\")")
            return
        end

        if Quests.SetLocation(questID, mapID, x, y) then
            Print("Saved location for quest " .. questID .. ".")
        else
            Print("Those coordinates are out of range.")
        end
    end,
}

CN:RegisterCommand{
    name    = "why",
    args    = "[questID]",
    order   = 27,
    help    = "Why the current recommendation, or why a quest is not offered.",
    handler = function(args)
        local questID = CN.ToID(args)

        if not questID then
            -- BARE `/cn why` ANSWERS THE OBVIOUS READING OF THE WORD.
            --
            -- It used to print a usage line. "Why" reads as "why did you
            -- recommend that", and the addon computes exactly that -- it
            -- prints it inline under `/cn next` and had no way to ask for it
            -- again afterwards. Meanwhile the command called `why` answered a
            -- different question entirely.
            --
            -- Both now, split on whether there is an id.
            local objective = CN.currentRecommendation

            if not objective then
                local results = CN.Recommend(1)

                objective = results and results[1]
            end

            if not objective then
                CN.PrintBlock("Nothing is being recommended, so there is "
                    .. "nothing to explain.", CN.ExplainEmptyList())

                return
            end

            CN.PrintBlock(
                "Why " .. CN.Primary(tostring(objective.name or objective.id))
                    .. CN.Aside(CN.TypeBadge(objective.type)),
                CN.ExplainRecommendation(objective))

            CN.PrintLine(CN.Accent("/cn why <questID>")
                .. CN.Muted(" answers why a quest is not offered to you."))

            return
        end

        local state, reason, detail = CN.Explain(CN.objectiveTypes.QUEST, questID)

        Print("Quest " .. questID .. " - " .. (Quests.GetName(questID, true) or "unknown name"))
        Print("State: " .. state)

        if reason then
            Print("Reason: " .. reason .. (detail and (" (" .. detail .. ")") or ""))
        end

        local record, source = Quests.GetRecord(questID)

        if record and source then
            Print("Data source: |cff8a8f96" .. source .. "|r")
        else
            -- `/cn setloc` records COORDINATES and nothing else, so it
            -- cannot add the prerequisite data this line is about. Naming it
            -- here sent the player to a command that could not solve the
            -- stated problem.
            Print("|cff8a8f96No prerequisite data for this quest. "
                .. "Install AllTheThings or BtWQuests, or let the addon "
                .. "learn the ordering by playing -- |cffffc74f/cn harvest|r"
                .. "|cff8a8f96 shows what it has seen so far.|r")
        end
    end,
}

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
