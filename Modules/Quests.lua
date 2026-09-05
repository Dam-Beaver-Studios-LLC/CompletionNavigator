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

-- QUESTS THE SERVER HAS ALREADY SAID NO ABOUT. 1.7.0.
--
-- 1.6.0 stopped the addon asking for a quest title while a request was in
-- flight, and the handler below clears the pending flag on EVERY answer --
-- including `success = false`, and including a success that carries no title.
-- Both are ordinary answers from the client, and both put the id straight
-- back into the "not asked" state, so the next rebuild asked again, two
-- seconds later, for ever.
--
-- The latch 1.6.0 added therefore closed only the case where no answer ever
-- arrives, which is the one the test fixture happened to model. The two the
-- client actually produces were untouched, and the suite's own request budget
-- passed because the stub answered nothing rather than answering "no".
--
-- A separate table rather than a third value in `pendingQuestLoads`, because
-- that table is tested for truthiness in three places and a `false` in it
-- reads as "not pending" at every one of them.
CN.refusedQuestLoads = CN.refusedQuestLoads or {}

-- AND THE WAY OUT THE 1.6.0 COMMENT PROMISED AND DID NOT BUILD.
--
-- That release's note reads "cleared on a loading screen rather than never,
-- because a refusal can be transient... a latch with no way out turns a
-- momentary refusal into a permanent one." Nothing cleared it. The comment
-- described behaviour that did not exist, which is worse than the missing
-- behaviour: the next reader checks the note instead of the code.
--
-- Both tables go, because both are statements about what the server has said
-- during THIS segment, and a loading screen is where that stops being true.
CN:RegisterEvent("PLAYER_ENTERING_WORLD", function()
    CN.pendingQuestLoads = {}
    CN.refusedQuestLoads = {}
end)

-- SEE `Modules/Instances.lua`. Unlike the other two this one is a count
-- rather than a noun, which is why the registry takes a label that may be
-- produced rather than only a fixed string.
CN.RegisterServerRequest{
    label = function()
        local outstanding = 0

        for _ in pairs(CN.pendingQuestLoads or {}) do
            outstanding = outstanding + 1
        end

        return CN.Count(outstanding, "quest title")
    end,

    -- Asking IS the pending entry: nothing goes into that table without a
    -- request having gone out beside it.
    asked    = function() return next(CN.pendingQuestLoads or {}) ~= nil end,
    answered = function() return next(CN.pendingQuestLoads or {}) == nil end,
}

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
-- A ROW IS A STRING UNLESS IT HAS SOMETHING ELSE TO SAY. 0.61.0.
--
-- `questMetadata` is the largest store in the addon: 708 KB of a 2.0 MB
-- SavedVariables file, and the game rewrites that file in full on every
-- logout. Every row was a two-field TABLE -- `{ name = ..., source = ... }`
-- -- and on an established account 30,000 of them said `source = "blizzard"`,
-- which is the default and carries no information.
--
-- The name itself does have to be kept. `GetTitleForQuestID` answers only for
-- quests the CLIENT has cached, and returns nil with an async request for
-- everything else -- so without this store the addon shows "Quest 84213" for
-- anything the player has not looked at this session. That is a real thing
-- the client will not re-supply on demand, and the standing rule permits it.
--
-- What the rule does NOT permit is the wrapper. So a row is now the name
-- itself, and only a name the PLAYER typed -- which must survive being
-- offered a Blizzard one -- keeps a table to say so. That is a handful of
-- rows against thirty thousand.
--
-- Both readers below accept either shape, and migration 15 collapses the
-- existing ones on first login.
-- A BARE STRING IS THE CLIENT'S NAME, AND ONLY THE CLIENT'S. 0.63.0.
--
-- 0.61.0 collapsed the row to a bare string for everything except a name the
-- player typed, and taught this to report a bare string as source
-- "blizzard". That threw away provenance for two other sources -- a title
-- read from a gossip window ("offered") and one read from a map pin
-- ("available") -- and did something worse than lose a label: because
-- "blizzard" is rank 1, the TOP of `CN.sourceRank`, a guess captured from a
-- map pin outranked the authoritative quest-log title that arrived later, and
-- `IsBetterSource` refused to correct it. `/cn cache 12345` then reported the
-- guess as having come from the client.
--
-- The saving was never in dropping the source; it was in dropping the
-- WRAPPER for the overwhelmingly common case. So the common case keeps the
-- bare string and every other source keeps its table -- a handful of rows
-- against thirty thousand, which is the same arithmetic that justified the
-- change in the first place.
--
-- "offered" and "available" are ranked now, too. They were absent from the
-- ladder entirely, which made them rank 99: worse than anything, including
-- each other.
local function NameFrom(record)
    if type(record) == "string" then
        return record, "blizzard"
    end

    if type(record) == "table" then
        return record.name, record.source
    end

    return nil, nil
end

Quests.NameFrom = NameFrom

-- Writes a name only when the incoming source is at least as
-- authoritative as the stored one. Manual entries never clobber Blizzard.
function Quests.SetMetadata(questID, name, source)
    if not questID or not name or name == "" then
        return false
    end

    local metadata = CN.Account("questMetadata")

    local heldName, heldSource = NameFrom(metadata[questID])

    source = source or "manual"

    if heldName and not CN.IsBetterSource(source, heldSource) then
        DebugPrint("Kept existing " .. tostring(heldSource)
            .. " name for quest " .. questID .. "; rejected " .. source .. ".")
        return false
    end

    -- `questID` duplicated the key this is filed under and `lastSeen` had no
    -- reader. The same fields migration 5 stripped from achievements, pets
    -- and toys.
    -- The bare string means "the client's own title for this quest", which
    -- is the overwhelmingly common case and the one worth optimising -- and
    -- the two sources that mean it are the top two ranks, so collapsing them
    -- together loses no decision. Every other source keeps its label, which
    -- is the part 0.61.0 threw away.
    if source == "blizzard" or source == "questlog" then
        metadata[questID] = name
    else
        metadata[questID] = { name = name, source = source }
    end

    return true
end

-- Kept in the table shape callers already expect, built on read rather than
-- stored. Two fields on a handful of lookups is not worth 708 KB on disk.
function Quests.GetMetadata(questID)
    local name, source = NameFrom(CN.Account("questMetadata")[questID])

    if not name then
        return nil
    end

    return { name = name, source = source }
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

    -- ONE FACT, WHICH IS ALL ANYTHING EVER READ.
    --
    -- This stored `{ firstSeen, lastSeen, source }`, and every reader in the
    -- tree -- the completion scan, the breakdown, the window, the two
    -- commands -- counts or iterates keys. Three fields per row, rewritten in
    -- full on every logout, for information nothing has ever asked for. See
    -- migration 12.
    discovered[questID] = true

    -- The Remaining tab's quest figure counts completed quests among the
    -- DISCOVERED set, so a new discovery is one of the two edges it has to be
    -- told about. One client call about one id; see the note there.
    local breakdown = CN:GetModule("Breakdown")

    if breakdown and breakdown.NoteQuestDiscovered then
        breakdown.NoteQuestDiscovered(questID)
    end

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
-- `quiet` MEANS "READ, DO NOT RECORD". 0.70.0.
--
-- This writes: every quest-start pin it walks past is filed into the
-- remembered store, which is a SavedVariable, and each new one moves the
-- shortlist revision. That is right when the player is playing, and wrong
-- when something is merely reading -- `/cn find` refreshes every tab so the
-- search has rows to look at, and the Journey tab's refresh reaches here, so
-- typing a search with the window shut wrote pins to disk and forced a
-- shortlist rebuild.
--
-- The same distinction `CN.Recommend(limit, quiet)` draws one file over, for
-- the same reason and from the same command.
function Quests.AvailableOnMap(mapID, quiet)
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

                if not quiet then
                    Quests.RememberOffer(poi)
                end
            end
        end
    end

    -- 2. Anything an NPC has actually offered us, remembered from the
    --    conversation. Only kept while it is still plausibly nearby.
    --
    -- ON THE MAP IT WAS SEEN ON. 0.89.0.
    --
    -- This function takes a map and the source above honours it; this one did
    -- not, so anything a gossip window offered in the last fifteen minutes
    -- was reported as being on whatever map was asked about. The provider
    -- then wrote "available to pick up in this zone" on a row whose travel
    -- cost was computed against the PREVIOUS zone -- the sentence and the
    -- number on one row contradicting each other -- `/cn available` counted
    -- it, and walking into an empty zone within fifteen minutes of a
    -- conversation fired "3 quests here you have not picked up".
    local nearby = {}

    for _, relatedID in ipairs(Blizzard.RelatedMapIDs(mapID)) do
        nearby[relatedID] = true
    end

    for questID, record in pairs(Quests.RecentOffers()) do
        if record.mapID and nearby[record.mapID] then
            consider({
                questID = questID,
                mapID   = record.mapID,
                x       = record.x,
                y       = record.y,
            }, "offered")
        end
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

-- A COUNTER, NOT A COUNT. 0.67.0.
--
-- The off-map shortlist keyed its revision on `CN.CountKeys(Remembered())`,
-- which is a walk of up to six hundred rows -- the exact walk 0.65.0 took OFF
-- this path -- performed on every call, from a provider on the
-- `QUEST_LOG_UPDATE` firehose. Worse, walking into new content adds ids
-- continuously, so the count moved constantly and the shortlist rebuilt every
-- two seconds: a full store walk plus one travel estimate per remembered map,
-- and a travel estimate is four client conversions and a scan of the flight
-- network.
--
-- One integer, bumped by the only two things that change what is in the
-- store.
Quests.pinRevision = 0

-- Moves when this character's completed set changes, so a shortlist built by
-- filtering on "not completed" can tell it is stale. Added in 0.91.0 with the
-- curated shortlist; completion itself is read live from the client, so
-- there was nothing to key on before.
Quests.completionRevision = 0

Quests.Remembered = Remembered

function Quests.RememberOffer(poi)
    if not poi or not poi.questID or not poi.mapID then
        return false
    end

    local store = Remembered()

    -- Only what the client cannot re-derive instantly: no names, no
    -- timestamps beyond the one that makes pruning possible.
    local isNew = store[poi.questID] == nil

    if isNew then
        Quests.pinRevision = Quests.pinRevision + 1
    end

    store[poi.questID] = {
        mapID = poi.mapID,
        x     = poi.x and math.floor(poi.x * 1000 + 0.5) / 1000 or nil,
        y     = poi.y and math.floor(poi.y * 1000 + 0.5) / 1000 or nil,
    }

    -- THE CEILING IS TESTED WHEN THE SET GREW, NOT ON EVERY SIGHTING.
    --
    -- `CN.CountKeys` walks the whole six-hundred-entry store, and this runs
    -- once per quest-start pin on every related map -- about thirty pins
    -- across four maps in a quest hub, so eighteen thousand table iterations
    -- for one boolean, from a provider on the `QUEST_LOG_UPDATE` firehose.
    --
    -- A store that did not gain a key cannot have crossed its ceiling, and
    -- the caller above already knows whether this id was new. 0.65.0.
    if isNew and CN.CountKeys(store) > Quests.rememberedCap then
        Quests.PruneRemembered()
    end

    return true
end

------------------------------------------------------------
-- QUESTS BEYOND THE MAP YOU ARE STANDING ON
------------------------------------------------------------

-- THE STORE WAS ALREADY BEING FILLED. NOTHING OFFERED FROM IT. 0.66.0.
--
-- `questPins` has recorded where every quest-start pin the player has ever
-- ridden past lives, and pruned itself, since it was added -- and it was read
-- only to answer "where is this quest" for a quest something ELSE had already
-- proposed. So the addon's answer to "what next?" was, for available quests,
-- bounded by the borders of the zone the player happened to be standing in:
-- it could see a quest twenty yards away and not one in the next zone, and it
-- would recommend a rare across the continent instead.
--
-- This is the largest coverage gap in the backlog and the data for it was
-- already on disk.
--
-- BOUNDED BY ZONE, NOT BY QUEST. Travel cost is a property of where a zone
-- is, and the pins in one zone share it -- so the cost is asked once per
-- MAP, of which a player has a few dozen, rather than once per pin, of which
-- they have up to six hundred. The nearest few zones contribute; the rest do
-- not, because a list that offers everything is not a recommendation.
Quests.offMapZones = 3
Quests.offMapCap   = 20

-- Which remembered maps are worth reaching, cheapest first. One representative
-- point per map is enough to price it: zones are not large compared to the
-- distance between them.
function Quests.NearbyRememberedMaps(playerMap)
    local byMap = {}

    -- THE NEIGHBOURHOOD, NOT THE EXACT MAP. 0.67.0.
    --
    -- Pins are recorded against every RELATED map -- `AvailableOnMap` walks
    -- `RelatedMapIDs`, which adds the parent zone and all its children -- and
    -- `GetBestMapForUnit` answers with the city's own map when the player is
    -- standing in one. So a quest giver twenty yards away in Dornogal, whose
    -- pin was filed against Isle of Dorn, came back through the OFF-map
    -- branch: priced as a journey, penalised a point, and captioned
    -- "available to pick up in Isle of Dorn" while the player stood in it.
    local here = {}

    if playerMap then
        here[playerMap] = true

        for _, related in ipairs(Blizzard.RelatedMapIDs(playerMap) or {}) do
            here[related] = true
        end
    end

    local function Skip(mapID)
        return here[mapID] == true
    end

    for questID, record in pairs(Remembered()) do
        local mapID = record.mapID

        -- BY CHARACTER, NOT BY ACCOUNT. 0.67.0.
        --
        -- `PruneRemembered` uses the account check deliberately -- WHERE a
        -- quest is does not depend on who is asking -- and this borrowed it,
        -- which is the opposite question. So a player whose main had cleared
        -- a continent rolled an alt and was offered nothing at all from it:
        -- `/cn unpicked` correctly listed twenty-two quests in a zone and
        -- `/cn next` never mentioned one of them. The in-zone sibling,
        -- `AvailableOnMap`, has always used the character check.
        if mapID and not Skip(mapID)
            and not Quests.IsCompletedByCharacter(questID)
            and not Blizzard.IsQuestInLog(questID) then

            byMap[mapID] = byMap[mapID] or {}

            table.insert(byMap[mapID], {
                questID = questID,
                mapID   = mapID,
                x       = record.x,
                y       = record.y,
            })
        end
    end

    local maps = {}

    for mapID, pins in pairs(byMap) do
        table.sort(pins, function(a, b) return a.questID < b.questID end)

        -- A PIN THAT HAS COORDINATES, NOT MERELY THE LOWEST ID. 0.68.0.
        --
        -- `RememberOffer` stores `x` and `y` only when the client gave them,
        -- and it does not always. Pricing a zone from a pin with no position
        -- makes `Travel.CostFor` refuse, `CN.TravelCost` fall through to its
        -- pessimism constant, and the zone sort last -- so up to twenty
        -- available quests one flight point away silently never appeared,
        -- while a farther zone whose lowest-id pin happened to have
        -- coordinates did.
        local sample

        for _, pin in ipairs(pins) do
            if pin.x and pin.y then
                sample = pin
                break
            end
        end

        -- No pin in the whole zone has a position. The zone is still worth
        -- offering -- the quests are real -- but nothing here can price the
        -- journey, so it is not pretended: it sorts last on the same constant
        -- the scorer uses for an unknown location, which is what that
        -- constant is for.
        -- AN EXPLICIT BRANCH, BECAUSE `CN.TravelCost` NEVER REFUSES. 0.69.0.
        --
        -- Written as an `and ... or` it reads as protection against a nil
        -- cost -- which cannot happen, and which this file says cannot happen
        -- a thousand lines down. A guard that cannot fire is one nobody can
        -- reason about, and it would silently swallow the day `CN.TravelCost`
        -- learns to refuse.
        local cost

        if sample then
            cost = CN.TravelCost(mapID, sample.x, sample.y)
        else
            cost = CN.unknownLocationCost
        end

        table.insert(maps, {
            mapID = mapID,
            cost  = cost,
            pins  = pins,
        })
    end

    -- ORDERED, AND ORDERED TOTALLY. Ties are broken on the map id so two
    -- clients with the same data produce the same list -- the same reason
    -- the candidate providers are ordered by registration.
    table.sort(maps, function(a, b)
        if a.cost ~= b.cost then
            return a.cost < b.cost
        end

        return a.mapID < b.mapID
    end)

    return maps
end

-- The offers themselves, capped. Shortlisted because the walk above is over
-- the whole remembered store and the provider it feeds runs every two
-- seconds; the revision changes when the store or the player's map does,
-- which is exactly when the answer can differ.
function Quests.OffMapOffers()
    local playerMap = CN.GetPlayerPosition()

    if not playerMap then
        return {}
    end

    -- AND WHERE THE PLAYER IS, COARSELY. 0.67.0.
    --
    -- The revision carried the map and not the position, so the "three
    -- cheapest zones" ordering was taken once on entering a zone and never
    -- re-costed: fly to the far side of it, or learn a flight point, and the
    -- addon went on pricing the journey from where you landed. A tenth of a
    -- map is coarse enough that walking does not thrash it and fine enough
    -- that crossing a zone re-asks.
    local _, playerX, playerY = CN.GetPlayerPosition()

    local revision = tostring(playerMap)
        .. ":" .. tostring(Quests.pinRevision)
        .. ":" .. tostring(math.floor((playerX or 0) * 10))
        .. ":" .. tostring(math.floor((playerY or 0) * 10))

    local list = CN.Shortlist("quests:offmap", revision, function()
        local offers = {}

        for index, map in ipairs(Quests.NearbyRememberedMaps(playerMap)) do
            if index > Quests.offMapZones then
                break
            end

            for _, pin in ipairs(map.pins) do
                if #offers >= Quests.offMapCap then
                    break
                end

                table.insert(offers, pin)
            end
        end

        return offers
    end)

    return list
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
    -- AND NOT ON THIS CHARACTER'S QUEST LOG. 0.74.0.
    --
    -- The paragraph above states the rule -- where a quest is does not depend
    -- on who is asking -- and the next clause used to break it:
    -- `IsQuestInLog` answers for the character currently logged in, and this
    -- deletes from the ACCOUNT store.
    --
    -- Under 0.72.0 the sweep ran only when the store crossed its six-hundred
    -- row cap, so the damage was rare. 0.73.0 wired it to every login, which
    -- made it routine: log in on a main holding twenty-five quests and
    -- twenty-five pickup locations vanish for the whole account, so an alt
    -- that still needs them is no longer offered them and the location is
    -- unrecoverable until somebody rides past the giver again. Abandoning a
    -- quest lost its pin the same way.
    --
    -- Account completion is the correct test and stays. "In MY log" is a
    -- per-character question and already belongs to the per-character read
    -- filters, which have it -- and to `QUEST_ACCEPTED`, which drops the pin
    -- for the character that picked it up without speaking for the others.
    for questID in pairs(store) do
        if Quests.IsCompletedOnAccount(questID) then
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

    if dropped > 0 then
        Quests.pinRevision = Quests.pinRevision + 1
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

-- THE EVENT HANDS YOU THE ID. USE IT. 0.72.0.
--
-- This ran the full sweep on every turn-in: a walk of the remembered store,
-- capped at 600 rows, with `IsQuestCompletedOnAccount` and `IsQuestInLog` --
-- two client calls -- on each, plus a `CN.CountKeys` pass. Twelve hundred
-- client calls to remove one entry, at the end of every quest, and four times
-- over in the bursts at the end of a chain.
--
-- The one quest that just changed is the argument. The full sweep runs where
-- a sweep belongs: once at login, from `RememberOffer` when the store crosses
-- its cap, and here when the client does not say which quest it was.
--
-- 0.72.0's version of this note claimed a login hook that did not exist. It
-- does now.
CN:RegisterEvent("QUEST_TURNED_IN", function(_, questID)
    if not questID then
        -- No id: the client did not say which. Fall back to the sweep rather
        -- than leaving a stale pin on the map.
        Quests.PruneRemembered()
        return
    end

    -- AND ONLY WHEN THE ACCOUNT IS DONE WITH IT. 0.74.0.
    --
    -- 0.72.0 replaced the full sweep here with a single-id removal, which was
    -- right about the cost and wrong about the scope in the same way
    -- `PruneRemembered` was: one character handing a quest in does not mean
    -- the account is finished with it, and this store is where the addon
    -- remembers, for every character, WHERE that quest is picked up. A main
    -- clearing a zone erased the map for every alt behind it.
    --
    -- Asking the account question about the one id that changed keeps the
    -- whole saving -- one client call instead of twelve hundred -- and gets
    -- the scope right, which is what the store is for.
    if not Quests.IsCompletedOnAccount(questID) then
        return
    end

    local store = Remembered()

    if store[questID] then
        store[questID] = nil
        Quests.pinRevision = Quests.pinRevision + 1
    end
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
                    CN.PrintLine(zone.name .. ": " .. zone.count .. " left behind")

                    for index, entry in ipairs(Quests.RememberedInZone(zone.mapID)) do
                        if index > 20 then
                            CN.PrintLine("  |cff8a8f96... and more|r")
                            break
                        end

                        CN.PrintLine("  " .. (Quests.GetName(entry.questID)
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
                CN.PrintLine("  |cff8a8f96... and " .. (#zones - 12) .. " more zones|r")
                break
            end

            -- NO COLUMN PADDING. 0.77.0. See the note in `Routing.lua`.
            CN.PrintLine("  " .. CN.Body(tostring(zone.name or zone.mapID))
                .. CN.Aside(tostring(zone.count)))
        end

        Print("|cff8a8f96This is what the addon has actually seen, not every "
            .. "quest in the game" .. CN.DASH .. "the client only lists pins for the map "
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

-- AND THE PIN IS DELIBERATELY NOT DROPPED HERE. Reverted in 0.74.0.
--
-- 0.73.0 added a pin removal to this handler on the grounds that a quest in
-- the log is no longer waiting to be picked up. True of THIS character, and
-- `Remembered()` is an account-wide store of WHERE a quest is -- so a main
-- accepting a quest deleted the location an alt still needed, and nothing
-- could recover it short of somebody riding past the giver again.
--
-- That is the identical wrong-scope defect this file's own `PruneRemembered`
-- header describes and warns about, written one release after the warning was
-- read. "In my log" is a per-character question, and the per-character read
-- filters already ask it at every read.
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
-- THE QUIET FLAG GOES THROUGH. 0.84.0.
--
-- This could not forward it, so every caller wanting a count also filed
-- every quest pin it walked past into a SavedVariable. `Quests.AvailableOnMap`
-- takes `quiet` for exactly that reason and the Journey tab passes it; the
-- Scans tab called this instead and had no way to.
function Quests.AvailableCount(mapID, quiet)
    return #Quests.AvailableOnMap(mapID, quiet)
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
        .. " quest" .. CN.Pluralize(#available, "")
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

-- THE THROTTLE THE SWEEP STAMPS ITSELF. 0.94.0.
--
-- This lived in the `QUEST_LOG_UPDATE` handler, so only that path advanced
-- it. The login hook and `/cn discoveractive` both ran the entire sweep --
-- the quest log, then every related map's POIs, a `RememberOffer` write and
-- an async title request per pin -- and left the stamp reading "never", and
-- `QUEST_LOG_UPDATE` fires within the same second in both situations. So the
-- most expensive scan in the addon ran twice at every login.
--
-- `Modules/Currencies.lua` records fixing exactly this in 0.65.0 ("the login
-- scan and the manual one both left the timestamp alone, so the next coin
-- picked up ran a second full sweep") and `Modules/Rares.lua` states the rule
-- again. The fix landed in one file and nowhere else, which is this project's
-- most-repeated defect.
Quests.logScanSeconds = 10

local lastLogScan = 0

function Quests.LogScanIsDue()
    return (time() - lastLogScan) >= Quests.logScanSeconds
end

function Quests.DiscoverActive()
    local entries = Blizzard.GetQuestLogEntries()

    if #entries == 0 and not C_QuestLog then
        Print("Quest Log API is unavailable.")
        return 0, 0
    end

    -- Stamped by the function that does the work, whoever called it.
    lastLogScan = time()


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
    --
    -- WALKED ONCE AND COUNTED FROM THE SAME WALK. 0.94.0.
    --
    -- `/cn discoveractive` called this function and then `AvailableCount`,
    -- which walks every related map's POIs all over again -- with the
    -- `RememberOffer` writes and the async title request per pin -- to
    -- produce a number this loop already knows. One command, two full
    -- sweeps, in one frame.
    local available = Quests.AvailableOnMap()

    for _, poi in ipairs(available) do
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

    return seen, new, #available
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
-- THE ONE PLACE THE COMPLETED SET IS RE-READ, so the one place the revision
-- moves. 0.91.0.
--
-- Seven call sites reach this, and putting the bump at the three that happen
-- to fire on a turn-in is the shape this project has recorded fixing eight
-- times: a rule applied at one call site and not its siblings.
local completed = {}

function Quests.RecordStatus(questID)
    local byCharacter = Quests.IsCompletedByCharacter(questID)
    local onAccount   = Quests.IsCompletedOnAccount(questID)

    -- Only on a CHANGE. An idempotent write that moves a revision destroys
    -- the cache the revision exists to preserve, at the worst moment --
    -- `Quests.ScanKnown` walks every discovered quest through here.
    if completed[questID] ~= byCharacter then
        completed[questID] = byCharacter

        Quests.completionRevision = (Quests.completionRevision or 0) + 1
    end

    return byCharacter, onAccount
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

    -- AND THE COUNTER THE SCANS TAB MEMOISES ITS ROWS AGAINST. 0.84.0.
    --
    -- `CN.MarkScanned` bumps it for every other setup step, and this is the
    -- one step that deliberately does not go through it -- so the row the
    -- Scans tab draws for this scan stayed marked stale, with its old age,
    -- however many times the player clicked it. The Collections tab reads
    -- the same timestamp uncached and immediately said "just now", so two
    -- tabs of one window reported different ages for the same fact.
    if CN.NoteCollectionChanged then
        CN.NoteCollectionChanged()
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

    -- IN EITHER VOCABULARY. 0.91.0.
    --
    -- `Data/Quests.lua`'s header documents `minLevel` and `faction`; this
    -- tested `requiresLevel`, which is what `/cn export` emits. So a row
    -- written to the addon's OWN documented schema, gated on `minLevel`, was
    -- not treated as authoritative and could lose to an external addon's
    -- answer -- directly contradicting the sentence three lines above, which
    -- says static wins because it is the source this addon controls.
    if static and (static.requires or static.obsolete
        or static.requiresLevel or static.minLevel
        or static.faction or static.requiresFaction
        or static.breadcrumb) then

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



        -- A BREADCRUMB YOU HAVE WALKED PAST IS GONE. 0.91.0.
        --
        -- `Data/Quests.lua` has documented `breadcrumb` -- "skippable and
        -- permanently missable" -- since 0.43.0, and `CN.blockReasons` has
        -- carried `BREADCRUMB_SKIPPED` just as long. Neither had a producer:
        -- the field had zero references in the whole tree, so a curator
        -- following the addon's own schema wrote something that reached
        -- nothing.
        --
        -- A breadcrumb is a quest that only points at another quest, and the
        -- game removes it once you have started the thing it points at. So a
        -- breadcrumb whose target is already begun or finished is not
        -- available and never will be, and telling a completionist to go and
        -- find it is the worst kind of wrong answer this addon can give: it
        -- sends them somewhere for something that is not there.
        --
        -- Only when the target is KNOWN. A breadcrumb with no `unlocks` is
        -- left alone rather than guessed at.
        if static.breadcrumb and type(static.unlocks) == "table" then
            for _, targetID in ipairs(static.unlocks) do
                if Quests.IsCompletedByCharacter(targetID)
                    or Blizzard.IsQuestInLog(targetID) then

                    return states.UNOBTAINABLE,
                           CN.blockReasons.BREADCRUMB_SKIPPED,
                           Quests.GetName(targetID)
                               or ("quest " .. tostring(targetID))
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
    -- THE TOKEN, NOT THE SENTENCE. 0.64.0.
    --
    -- This recovered the block reason by pattern-matching the English display
    -- prose the eligibility check builds -- and since 0.61.0 that prose is
    -- partly localized, so the parser was one translation away from telling
    -- `/cn alts` that a race-gated quest was class-gated. The reason is
    -- returned as a stable token now; see the note there.
    local eligible, gateReason, gate = CN.Static.QuestEligibility(questID)

    if not eligible then
        local byGate = {
            CLASS   = CN.blockReasons.WRONG_CLASS,
            RACE    = CN.blockReasons.WRONG_RACE,
            LEVEL   = CN.blockReasons.LEVEL_TOO_LOW,
            FACTION = CN.blockReasons.WRONG_FACTION,
        }

        return states.INELIGIBLE,
            byGate[gate] or CN.blockReasons.WRONG_CLASS,
            gateReason
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
    -- THE CHEAP QUESTION FIRST. 1.1.0.
    --
    -- This asked the client whether the quest was ready to hand in BEFORE
    -- asking whether there was a curated turn-in to use -- a C call per
    -- quest, on a function the zone router calls once per stop, for the
    -- three curated rows in existence. `Static.GetQuestTurnIn` is a table
    -- lookup and answers nil for everything else, so it decides the branch
    -- for a two-hundred-stop route without leaving Lua.
    local turnMap, turnX, turnY

    if CN.Static and CN.Static.GetQuestTurnIn then
        turnMap, turnX, turnY = CN.Static.GetQuestTurnIn(questID)
    end

    if turnMap and turnX and turnY
        and Blizzard.IsQuestReadyForTurnIn
        and Blizzard.IsQuestReadyForTurnIn(questID) then

        return turnMap, turnX, turnY, "turn-in"
    end

    if mapID and x and y then
        return mapID, x, y, "blizzard"
    end

    local override = Overrides()[questID]

    if override and override.mapID and override.x and override.y then
        return override.mapID, override.x, override.y, override.source or "manual"
    end

    -- THIS ACCOUNT'S OWN OBSERVATION, WHEN NOTHING ABOVE ANSWERED. 1.0.0.
    --
    -- The curated branch at the top of this function is the right answer and
    -- there are two curated rows in existence, so for every other quest the
    -- three-phase model still rests on the client -- which is fine until the
    -- client refuses, which it does for a quest whose giver is on a map it is
    -- not currently describing. `Harvest` began recording where a quest was
    -- handed in in 1.0.0, so this account usually has the answer for anything
    -- it has done before on another character.
    --
    -- Below the override deliberately: an override is the player saying where
    -- something is, and nothing the addon watched outranks that. Above the
    -- curated PICK-UP location, because a quest that is ready to hand in is
    -- not asking where it was taken from.
    -- Same ordering rule as the curated branch above: the store lookup is
    -- Lua and answers nil for a quest this account has never handed in, so
    -- the client is asked only when there is an answer to use.
    local harvest = CN:GetModule("Harvest")

    if harvest and harvest.TurnInFor then
        local seenMap, seenX, seenY = harvest.TurnInFor(questID)

        if seenMap and seenX and seenY
            and Blizzard.IsQuestReadyForTurnIn
            and Blizzard.IsQuestReadyForTurnIn(questID) then

            return seenMap, seenX, seenY, "harvested turn-in"
        end
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

        -- NIL, NOT ZERO.
        --
        -- Zero means "you are standing on it", and `CN.IsPlaceless` reads a
        -- travelCost of zero exactly that way. `playerMap` is nil for a
        -- second or two after every loading screen -- `Travel.CostFor` says
        -- so in its own comment -- and neither branch below ran in that case,
        -- so every located quest in the log was scored as though the player
        -- were standing on top of it. It healed on the next rebuild, but
        -- arriving in a zone is precisely when somebody types `/cn next`.
        local travel, costed

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

            if availablePOI.offMap then
                -- Named, not "in this zone", because it is not. The zone is
                -- what makes it worth saying: "somewhere else" is not an
                -- instruction and the route needs a destination.
                local zone = CN.Blizzard.GetMapName(availablePOI.mapID)

                table.insert(reasons, "available to pick up in "
                    .. (zone or ("map " .. tostring(availablePOI.mapID))))

                -- One point, not three: going to get a quest in the next zone
                -- is still worth doing, and still not as good as one you can
                -- see from here.
                value = value - 1
            else
                table.insert(reasons, "available to pick up in this zone")
            end

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
            table.insert(reasons, "unlocks " .. #static.unlocks
                .. (#static.unlocks == 1 and " further quest"
                    or " further quests"))
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
            -- `CN.TravelCost` never answers nil, so the old `or travel`
            -- could only ever read the nil this starts as -- which luacheck
            -- correctly called reading an uninitialised variable.
            local measured, fromTravel = CN.TravelCost(mapID, x, y)

            travel = measured
            costed = fromTravel or nil

            if fromTravel and mapID ~= playerMap then
                table.insert(reasons, "another zone, costed by how long the "
                    .. "journey actually takes")
            end
        elseif not mapID then
            -- "I DO NOT KNOW WHERE THIS IS" IS ONE PRICE, SET IN ONE PLACE.
            --
            -- This hard-coded 5 while `CN.unknownLocationCost` is 8 -- raised
            -- from 3 in 0.57.0 with a long note explaining that anything
            -- below the cost of crossing a zone lets "no idea where this is"
            -- outrank "I can see it from here". The highest-volume provider
            -- in the addon was bypassing that decision, so a quest with NO
            -- location was cheaper than one in your own zone whose
            -- coordinates had not resolved yet.
            travel = CN.unknownLocationCost
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
            travelCosted      = costed,
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

    -- AND THE ZONES NEXT DOOR. 0.66.0. See `Quests.OffMapOffers`.
    --
    -- Weighted BELOW a quest available in this zone -- it is a real journey
    -- and the travel cost already says so -- but above nothing, which is what
    -- it was worth before.
    for _, pin in ipairs(Quests.OffMapOffers()) do
        -- FILTERED AGAIN HERE, AND ON PURPOSE. The shortlist's revision moves
        -- when the store grows or the player changes map, and neither of
        -- those happens when a quest is accepted or turned in -- so without
        -- this the addon would go on recommending the player go and pick up
        -- a quest they are already carrying. Twenty checks; the shortlist
        -- exists to keep the six-hundred-row walk off this path, not these.
        if not seen[pin.questID]
            and not Quests.IsCompletedByCharacter(pin.questID)
            and not Blizzard.IsQuestInLog(pin.questID) then
            local name = Quests.GetName(pin.questID)
                or Blizzard.GetQuestTitle(pin.questID, true)
                or ("Quest " .. pin.questID)

            add(pin.questID, name, false, {
                questID  = pin.questID,
                mapID    = pin.mapID,
                x        = pin.x,
                y        = pin.y,
                offMap   = true,
            })
        end
    end

    -- Curated quests that are not in the log and not yet completed.
    --
    -- A SHORTLIST, NOT A SWEEP OF THE WHOLE DATABASE. 0.91.0.
    --
    -- This walked every curated row and called `CN.Explain` on each, and
    -- `Explain` reaches `Quests.GetRecord`, which for a row without gating
    -- fields falls through to `CN.QueryQuestDataProviders` -- a pcall of
    -- `IsAvailable` AND `GetQuestData` on every registered external addon.
    -- This provider declares `QUEST_LOG_UPDATE` at a two-second cooldown.
    --
    -- With the one row this addon has shipped so far that cost nothing. With
    -- a few thousand curated rows and AllTheThings or BtWQuests installed it
    -- is a full eligibility sweep plus thousands of cross-addon lookups every
    -- two seconds while questing -- which is exactly the shape a companion
    -- data addon is about to create.
    --
    -- The completed set is the cheap filter and it is what actually moves, so
    -- the shortlist is keyed on it. `CN.Shortlist` is the same mechanism five
    -- other providers already use.
    local pending = CN.Shortlist("Quests.Curated",
        tostring(Quests.completionRevision or 0) .. ":"
            .. tostring(CN.Static.revision or 0),
        function()
            local rows = {}

            for questID, record in pairs(CN.Static.quests) do
                if not record.obsolete
                    and not Quests.IsCompletedByCharacter(questID) then

                    table.insert(rows, { questID = questID,
                                         name = record.name })
                end
            end

            return rows
        end)

    for _, row in ipairs(pending) do
        local state = CN.Explain(CN.objectiveTypes.QUEST, row.questID)

        if state == CN.objectiveStates.AVAILABLE then
            add(row.questID, row.name, false)
        end
    end

    -- AND THE PROVIDER HONOURS ITS OWN CAP, like Pets, Mounts, Toys,
    -- Achievements and Vendors. `CN.providerCandidateCap` is self-applied by
    -- convention and `RunProvider` does not enforce it, so a provider that
    -- does not call this can push an unbounded list into the score-and-sort.
    return CN.CapCandidates and CN.CapCandidates(candidates) or candidates
end, {
    events = {
        "QUEST_ACCEPTED", "QUEST_TURNED_IN", "QUEST_REMOVED",
        "QUEST_LOG_UPDATE", "ZONE_CHANGED_NEW_AREA",

        -- AND THE TITLE THIS PROVIDER ASKED THE SERVER FOR. 1.2.0.
        --
        -- Two of the three loops above render `"Quest " .. questID` when the
        -- client has no title cached, and call
        -- `Blizzard.GetQuestTitle(id, true)` to ask for one -- so this
        -- provider is the thing that starts the request and was not told
        -- when it was answered. Crossing into a zone whose pins are not
        -- cached produced a ranked list of quest numbers that stayed numbers
        -- until something else invalidated.
        "QUEST_DATA_LOAD_RESULT",
    },
    cooldown = 2,
})

------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

CN:RegisterEvent("QUEST_DATA_LOAD_RESULT", function(event, questID, success)
    if not CN.pendingQuestLoads[questID] then
        return
    end

    CN.pendingQuestLoads[questID] = nil

    -- AN ANSWER OF "NO" IS AN ANSWER. 1.7.0.
    --
    -- Clearing the pending flag and recording nothing else put this id back
    -- into the state that starts a request, so the provider asked again on
    -- its next rebuild -- every two seconds, for as long as the player stood
    -- in a zone with a pin the server would not describe.
    if not success then
        CN.refusedQuestLoads[questID] = true

        DebugPrint("Quest " .. tostring(questID) .. " metadata was unavailable from Blizzard.")
        return
    end

    local title = Blizzard.GetQuestTitle(questID, false)

    -- AND A SUCCESS WITH NOTHING IN IT IS ALSO AN ANSWER. The client reports
    -- the load as having worked and still has no title for the quest, which
    -- this treated as "keep asking" for the same reason.
    if not title then
        CN.refusedQuestLoads[questID] = true

        DebugPrint("Quest " .. questID .. " loaded, but no title was returned.")
        return
    end

    Quests.SetMetadata(questID, title, "blizzard")

    -- NOBODY ASKED FOR THIS SENTENCE. 1.2.0.
    --
    -- This printed a chat line per quest, and every path that reaches it is a
    -- background one. `CN.pendingQuestLoads` is written in exactly one place
    -- -- `Blizzard.GetQuestTitle(questID, true)` -- and its callers are the
    -- candidate provider walking this map's quest pins, the same provider
    -- walking up to twenty offers in three neighbouring zones, the map-pin
    -- sweep and `Chase`. Not one of them is a player asking about a quest.
    -- There is no `/cn lookup <id>` path into this: that command asks
    -- external providers and never requests a title.
    --
    -- So crossing into a zone whose pins the client has not cached printed
    -- a line for each of them -- forty at the cap -- announcing titles for
    -- rows the player had not looked at yet. `Modules/Harvest.lua` states the
    -- rule this broke: "nothing spams the chat frame at login".
    DebugPrint("Quest " .. questID .. " resolved: " .. title)

    -- AND THE ROW THAT WAS SHOWING A NUMBER IS REBUILT. 1.2.0.
    --
    -- The provider that asked for this title renders `"Quest " .. questID`
    -- while waiting, and nothing told it the answer had come: the name landed
    -- in the metadata store and the ranked list went on saying "Quest 84732"
    -- until a quest event happened along. Exactly the defect 1.1.0 fixed for
    -- the client's ITEM cache, on its sibling system -- one that had an event
    -- registered, a handler and a store, and no line joining them to the
    -- screen.
    --
    -- THE INVALIDATION IS NOT WRITTEN HERE. The provider below declares
    -- `QUEST_DATA_LOAD_RESULT`, so `CN.SubscribeToInvalidationEvents` wires
    -- it, and `CN.burstInvalidationEvents` gathers it -- because this arrives
    -- once per quest, in bursts of up to forty as a zone's pins resolve. A
    -- second invalidation written by hand here would be the same work twice
    -- and a second place to keep right.
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

-- QUEST_LOG_UPDATE fires constantly; throttle a full rescan. The stamp is
-- inside `DiscoverActive` -- see the note there.
CN:RegisterEvent("QUEST_LOG_UPDATE", function()
    if not Quests.LogScanIsDue() then
        return
    end

    local seen, new = Quests.DiscoverActive()

    if new > 0 then
        DebugPrint("Quest Log scan discovered " .. new .. " new quests (" .. seen .. " active).")
    end
end)

CN:OnLogin(function()
    local seen, new = Quests.DiscoverActive()

    DebugPrint("Login quest scan: " .. seen .. " active, "
        .. new .. " newly recorded.")

    -- THE LOGIN SWEEP 0.72.0's COMMENT PROMISED AND DID NOT WRITE. 0.73.0.
    --
    -- 0.72.0 replaced the full `PruneRemembered` on every turn-in with a
    -- single-id removal, which was right -- twelve hundred client calls to
    -- forget one pin -- and justified it by saying "the login hook covers
    -- anything completed elsewhere". There was no login hook. `OnLogin` here
    -- called only `DiscoverActive`.
    --
    -- What was actually lost is the eviction of rows dead for a reason other
    -- than a turn-in: a quest ACCEPTED into the log, and a quest completed by
    -- another character on the account. Those sat until the store happened to
    -- cross its cap of six hundred, and every read filtered them at two
    -- client calls a row -- so the cost the change removed from the turn-in
    -- reappeared on the read path, which runs far more often.
    --
    -- Once, at login, is where a sweep of a persisted store belongs.
    local dropped = Quests.PruneRemembered()

    if dropped > 0 then
        DebugPrint("Pruned " .. dropped .. " remembered quest location(s).")
    end
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

        Print("State: " .. CN.StateLabel(state)
            .. (reason and (" " .. CN.DASH .. " " .. reason) or "")
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
            Print(#near .. " quest" .. CN.Pluralize(#near, "")
                .. " available right here:")
        else
            Print(#available .. " quest" .. CN.Pluralize(#available, "")
                .. " available in this zone, none within "
                .. CN.nearbyYards .. "yd:")
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

            CN.PrintLine("  |cffffc74f" .. title .. "|r" .. where)
        end

        if #near > 0 and #zone > 0 then
            Print("|cff8a8f96Plus " .. #zone
                .. " further out in this zone.|r")
        end

        local tasks = Quests.TasksOnMap(mapID)

        if #tasks > 0 then
            Print("|cff8a8f96Also " .. #tasks .. " world quest"
                .. CN.Pluralize(#tasks, "")
                .. " or bonus objective in this zone" .. CN.DASH .. "no giver to talk "
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
            -- NO COLUMN PADDING. 0.77.0. See the note in `Routing.lua`.
            CN.PrintLine("  " .. CN.Body(tostring(row.name or row.mapID))
                .. CN.Aside(row.pois .. " pins, " .. row.starts
                    .. " starts, " .. row.usable .. " usable"))
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

        local seen, recorded, available = Quests.DiscoverActive()

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
            -- `/cn where` WANTS A QUEST ID AND ANSWERS ABOUT THAT QUEST'S
            -- MAP, so it could never answer "what map am I on" -- and the
            -- fallback was a raw Lua dump. `/cn where am i` prints the id now.
            CN.PrintLine(CN.Muted("Coordinates may be 0-1 or 0-100. ")
                .. CN.Accent("/cn where am i")
                .. CN.Muted(" prints the map id you are standing on."))
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
        Print("State: " .. CN.StateLabel(state))

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
                .. "learn the ordering by playing" .. CN.DASH .. "|cffffc74f/cn harvest|r"
                .. "|cff8a8f96 shows what it has seen so far.|r")
        end
    end,
}

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
