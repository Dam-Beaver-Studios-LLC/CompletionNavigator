-- Providers/StaticData.lua
-- Completion Navigator :: access layer for the curated static database.
--
-- Data/*.lua files call CN.Static.Register* to contribute rows. Nothing
-- reads those tables directly; everything goes through the accessors here
-- so the storage shape can change without touching consumers.

local ADDON_NAME, CN = ...

local Static = {}

CN.Static = Static

Static.quests    = {}

-- FOUR REGISTRARS THAT WROTE INTO NOTHING ARE GONE. 0.91.0.
--
-- `Static.recipes`, `Static.vendors`, `Static.rares` and `Static.treasures`
-- were declared here, written by four published registrars, and read by
-- nothing anywhere in the tree -- `Modules/Vendors.lua` and `Modules/Rares.lua`
-- each keep their own account store and never look here. `Static.Count()`
-- returned all five sizes and had no caller at all, while the harness's own
-- note called it "the number /cn dbsize prints", which `/cn dbsize` does not.
--
-- That was harmless while this file was only read by files shipped inside the
-- addon. It stops being harmless the moment an external data addon reads this
-- surface as documentation: a supplier who curated rare and treasure
-- locations would get a successful call, a non-zero count, and no change to
-- anything a player ever sees.
--
-- A published surface either works or is not published. When those four have
-- real readers they come back, with tests.

------------------------------------------------------------
-- THE DATA CONTRACT
------------------------------------------------------------

-- WHAT AN EXTERNAL SUPPLIER IS PROMISED. 0.91.0.
--
-- `Data/*.lua` inside this addon and any companion addon reach this surface
-- the same way, through `_G.CompletionNavigator.Static`. Before 0.91.0 the
-- two registrars below took anything, told the caller nothing, threw on a nil
-- argument where the sibling registrar returned zero, and stamped no origin
-- -- so `/cn provenance` counted every row in the table under the headline
-- "each one checked by hand", including rows that arrived from somewhere
-- else entirely.
--
-- The curated/observed distinction is the whole safety model of this data
-- pipeline; `Data/Community.lua` says so and says there is no getting it back
-- afterwards. A row that cannot say where it came from cannot preserve it.
Static.schemaVersion = 1

-- WHAT THIS REGISTRAR PROMISES, AS A NUMBER A SUPPLIER CAN TEST. 0.92.0.
--
-- `RegisterQuests` existed before 0.91.0 too, and the old one took anything,
-- returned nothing, and stamped no origin. So a companion addon guarding on
-- `type(CN.Static.RegisterQuests) == "function"` passes on an OLD build and
-- then silently gets `nil, nil` back -- with every one of its rows counted by
-- that build's `/cn provenance` under "each one checked by hand", which is
-- this addon making a false provenance claim about somebody else's data.
--
-- `schemaVersion` describes the RECORD SHAPE. This describes the REGISTRAR:
--
--   1 -- validates keys and fields, returns `added, refused`, stamps
--        `origin`, records collisions, invalidates caches on registration,
--        and accepts `UnregisterOrigin`.
--
-- A supplier tests `(CN.Static.apiVersion or 0) >= 1` and refuses to register
-- otherwise, with one line in chat. `CN.version` cannot serve: it is a
-- marketing string, not a contract.
Static.apiVersion = 1

-- Rows that lost a collision, so `/cn selftest` can say two suppliers
-- disagree rather than the later one silently winning.
Static.collisions = {}

-- Moves whenever a curated row is added, so anything holding a shortlist
-- built from this table can tell that it is stale. A companion addon that
-- registers late -- on demand, per expansion, after a settings toggle -- is
-- the case this exists for.
Static.revision = 0

local VALID_FIELDS = {
    name = true, mapID = true, x = true, y = true,
    requires = true, unlocks = true, breadcrumb = true, obsolete = true,
    classes = true, races = true, faction = true, minLevel = true,
    turnInMapID = true, turnInX = true, turnInY = true,
    -- Accepted as synonyms of `minLevel` and `faction`, because
    -- `/cn export` has always emitted them and the eligibility checker has
    -- always read them. See `Static.QuestEligibility`.
    requiresLevel = true, requiresFaction = true,
    -- Written by this file, not by the supplier.
    origin = true,
}

Static.validFields = VALID_FIELDS

-- Registers one curated quest row.
--
-- Returns true on success; false and a reason otherwise. `origin` names the
-- supplier and defaults to "curated", which is what the rows shipped inside
-- this addon are. Anything else is reported as its own provenance by
-- `/cn provenance` rather than being counted as hand-checked.
function Static.RegisterQuest(questID, record, origin)
    -- A NUMBER, NOT A NUMERIC STRING. Every reader indexes this table with a
    -- number from `CN.ToID` or from a client event, so a row filed under
    -- "8237" is stored and never matched -- total silence for a supplier
    -- generating its data file from JSON.
    if type(questID) ~= "number" then
        return false, "a quest id is a number, not "
            .. type(questID) .. ": " .. tostring(questID)
    end

    if type(record) ~= "table" then
        return false, "a quest row is a table, not " .. type(record)
    end

    for field in pairs(record) do
        if not VALID_FIELDS[field] then
            return false, "quest " .. questID
                .. " carries a field this addon does not read: "
                .. tostring(field)
        end
    end

    local existing = Static.quests[questID]

    if existing then
        table.insert(Static.collisions, {
            questID = questID,
            kept    = existing.origin or "curated",
            lost    = origin or "curated",
        })
    end

    record.origin = origin or record.origin or "curated"

    Static.quests[questID] = record

    return true
end

-- Registers a table of curated rows. Returns how many landed and how many
-- were refused, with the refusals recorded to `/cn errors` rather than
-- thrown, so one bad row in a supplier's file does not cost the rest.
--
-- `schemaVersion` is optional and checked when given: a supplier built for a
-- schema this addon does not know is told so once, rather than contributing
-- fields that are silently discarded.
function Static.RegisterQuests(records, origin, schemaVersion)
    if type(records) ~= "table" then
        return 0, 0
    end

    if schemaVersion and schemaVersion ~= Static.schemaVersion then
        local errors = CN.modules and CN:GetModule("Errors")

        if errors and errors.Record then
            errors.Record("quest data built for another schema",
                tostring(origin or "unknown") .. " supplied schema "
                .. tostring(schemaVersion) .. "; this addon reads "
                .. tostring(Static.schemaVersion))
        end
    end

    local added, refused = 0, 0

    -- ONE ENTRY, NOT ONE PER ROW. 0.92.0.
    --
    -- `Errors.capacity` is 20 and the dedupe key is context plus message, so
    -- a supplier with a bad generator and twenty-one refused rows evicted
    -- every other error recorded that session -- including whatever the addon
    -- itself had logged, and including the supplier's own summary. `/cn
    -- errors` then printed twenty near-identical lines with the one real
    -- problem buried underneath.
    --
    -- The first reason is the one worth having; the rest are almost always
    -- the same mistake repeated.
    local firstRefusal

    for questID, record in pairs(records) do
        local ok, why = Static.RegisterQuest(questID, record, origin)

        if ok then
            added = added + 1
        else
            refused = refused + 1

            firstRefusal = firstRefusal or why
        end
    end

    if refused > 0 then
        local errors = CN.modules and CN:GetModule("Errors")

        if errors and errors.Record then
            errors.Record("curated quest rows were refused",
                tostring(origin or "unknown") .. ": "
                .. CN.Count(refused, "row") .. " refused, first: "
                .. tostring(firstRefusal))
        end
    end

    -- AND THE ANSWER CHANGES, so a supplier that registers late is not
    -- ignored until something unrelated moves. The rows shipped inside this
    -- addon register at file-load time and never needed this; a companion
    -- addon registering on demand, per expansion, or after a settings toggle
    -- would otherwise leave the aggregate candidate cache, the ranked list
    -- and the unlock index holding the pre-registration answer for the whole
    -- session.
    --
    -- 0.92.0: this said "`Contribute.Import` calls exactly this, for exactly
    -- this", and `Contribute.Import` has never called it -- it writes its own
    -- store and adds dependencies. The paragraph explaining why the block is
    -- here named a caller that does not exist, which is how the next reader
    -- builds a wrong model. The real caller is a companion data addon
    -- registering after login; `Data/Quests.lua` registers at file-load time
    -- and never needed it.
    if added > 0 then
        Static.revision = Static.revision + 1

        if CN.InvalidateCandidates then
            CN.InvalidateCandidates()
        end

        local harvest = CN.modules and CN:GetModule("Harvest")

        if harvest and harvest.NoteUnlocksChanged then
            harvest.NoteUnlocksChanged()
        end
    end

    return added, refused
end

------------------------------------------------------------
-- ACCESS
------------------------------------------------------------

-- CONTRIBUTED CHAINS.
--
-- Held apart from the curated table so that the difference between "checked"
-- and "widely observed" survives being written to disk, and so /cn why can
-- say which one it is quoting.
Static.community = Static.community or {}

function Static.RegisterCommunity(records)
    if type(records) ~= "table" then
        return 0
    end

    local added = 0

    for questID, record in pairs(records) do
        if type(record) == "table" and type(record.requires) == "table" then
            Static.community[questID] = record

            added = added + 1
        end
    end

    return added
end

function Static.GetCommunity(questID)
    return Static.community[questID]
end

function Static.CommunityCount()
    local count = 0

    for _ in pairs(Static.community) do
        count = count + 1
    end

    return count
end

function Static.GetQuest(questID)
    return Static.quests[questID]
end

-- ELIGIBILITY, from curated data.
--
-- The client only draws quest pins the character qualifies for, so gating is
-- normally handled by simply not seeing it. That is fine while the player is
-- standing there and useless the moment they ask "why can nobody in my
-- Warband do this?" -- which is exactly what /cn why and /cn alts are for.
--
-- Returns eligible, reason. A record with no gating fields is eligible, and
-- says so with a nil reason rather than an empty claim.
function Static.QuestEligibility(questID, character)
    local record = Static.quests[questID]

    if not record then
        return true, nil
    end

    character = character or CN.character or {}

    -- THE REASON AS A TOKEN, AS WELL AS AS A SENTENCE. 0.64.0.
    --
    -- The caller in Quests.lua recovered WHY a quest was blocked by
    -- pattern-matching this English prose -- `find("^race")`,
    -- `find("Alliance")`. Since 0.61.0 the class and race lists in that
    -- sentence are run through the client's LOCALIZED names, so the string is
    -- already half-translated and the parser survives only because the label
    -- prefixes happen to still be English.
    --
    -- The reason is known here, exactly, at the moment the sentence is built.
    -- Throwing it away and reconstructing it from the display text is the
    -- "branch on a localized string" rule broken by a longer road: the first
    -- translation of "race only" would silently reclassify every race-gated
    -- quest as class-gated, and `/cn alts` would name the wrong alt.
    --
    -- Third return: a stable token. The sentence is unchanged.
    -- ONE GATE, TWO SPELLINGS. 0.91.0.
    --
    -- `Data/Quests.lua`'s header documents `faction` and `minLevel`; the
    -- eligibility checker in `Modules/Quests.lua` has always read
    -- `requiresFaction` and `requiresLevel`, and `/cn export` has always
    -- EMITTED those -- so harvested rows and hand-curated rows in the same
    -- file gated through different code. Both names are accepted here and
    -- both are documented; a supplier can use either.
    local faction  = record.faction or record.requiresFaction
    local minLevel = record.minLevel or record.requiresLevel

    if faction and character.faction
        and faction ~= character.faction then

        -- THE FACTION HELPER, NOT THE CLASS ONE. 0.82.0.
        --
        -- `CN.TokenLabel` resolves class and race tokens and knows nothing
        -- about factions, so it fell through to its title-caser and printed
        -- the English token. `CN.FactionLabel` is backed by the client's own
        -- `FACTION_ALLIANCE`/`FACTION_HORDE` globals and was added for the
        -- Warband roster, then extended to `Modules/Mounts.lua` under a note
        -- saying that file "was not converted". This is the third place, and
        -- it was not converted either -- so a German client read "Alliance
        -- only" three lines under a correctly translated class list.
        return false, CN.FactionLabel(faction) .. " only", "FACTION"
    end

    if minLevel and character.level
        and character.level < minLevel then

        return false, "level " .. minLevel .. " required", "LEVEL"
    end

    local function allowed(list, value, label)
        if type(list) ~= "table" or #list == 0 or not value then
            return true
        end

        for _, entry in ipairs(list) do
            if entry == value then
                return true
            end
        end

        -- "class only: WARRIOR, PALADIN" IS A DATABASE ROW, NOT A SENTENCE.
        -- 0.61.0.
        --
        -- These are the client's uppercase tokens, and they went straight
        -- onto the player's screen. The client already holds the localized
        -- names for exactly these tokens; using them costs one table lookup
        -- and turns the line into something a player reads rather than
        -- decodes.
        local words = {}

        for _, entry in ipairs(list) do
            table.insert(words, CN.TokenLabel(entry))
        end

        return false, label .. " only: " .. CN.Series(words)
    end

    local okClass, classReason = allowed(record.classes, character.class, "class")

    if not okClass then
        return false, classReason, "CLASS"
    end

    local okRace, raceReason = allowed(record.races, character.race, "race")

    if not okRace then
        return false, raceReason, "RACE"
    end

    return true, nil, nil
end

-- Where a quest is HANDED IN, which is not where it is picked up and is not
-- what the client's moving "next waypoint" reports once you are part-way
-- through it.
function Static.GetQuestTurnIn(questID)
    local record = Static.quests[questID]

    if not record or not record.turnInMapID then
        return nil
    end

    return record.turnInMapID, record.turnInX, record.turnInY
end

function Static.GetQuestName(questID)
    local record = Static.quests[questID]

    return record and record.name or nil
end

function Static.GetQuestLocation(questID)
    local record = Static.quests[questID]

    if not record then
        return nil, nil, nil
    end

    return record.mapID, record.x, record.y
end

-- REGISTERING TWICE IS NOT A COLLISION WITH SOMEBODY ELSE. 0.92.0.
--
-- `Static.revision` exists so a supplier can register late -- on demand, per
-- expansion, after a settings toggle. A supplier doing that a second time
-- collided with ITSELF: `Static.collisions` filled with rows whose `kept` and
-- `lost` were the same name, and `/cn provenance` reported "N quests claimed
-- by more than one source" about one addon registering twice.
--
-- Dropping an origin's rows first makes the case the revision was built for
-- actually work. Returns how many rows were removed.
function Static.UnregisterOrigin(origin)
    if type(origin) ~= "string" or origin == "" or origin == "curated" then
        return 0
    end

    local removed = 0

    for questID, record in pairs(Static.quests) do
        if record.origin == origin then
            Static.quests[questID] = nil

            removed = removed + 1
        end
    end

    -- Collisions this origin lost or won are no longer about anything.
    local kept = {}

    for _, clash in ipairs(Static.collisions) do
        if clash.kept ~= origin and clash.lost ~= origin then
            table.insert(kept, clash)
        end
    end

    Static.collisions = kept

    if removed > 0 then
        Static.revision = Static.revision + 1

        if CN.InvalidateCandidates then
            CN.InvalidateCandidates()
        end
    end

    return removed
end

-- How many curated rows are held, and how many of them came from this addon
-- rather than from a supplier. 0.91.0: this returned five numbers, four of
-- them counting tables nothing read.
function Static.Count()
    local total, mine = 0, 0

    for _, record in pairs(Static.quests) do
        total = total + 1

        if (record.origin or "curated") == "curated" then
            mine = mine + 1
        end
    end

    return total, mine
end

-- Curated rows grouped by who supplied them, for `/cn provenance`.
function Static.Origins()
    local counts = {}

    for _, record in pairs(Static.quests) do
        local origin = record.origin or "curated"

        counts[origin] = (counts[origin] or 0) + 1
    end

    return counts
end
