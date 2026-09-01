-- Database.lua
-- Completion Navigator :: SavedVariables schema, defaults, and migration.
--
-- Anything that must survive /reload or logout lives in
-- CompletionNavigatorDB. Add new persistent tables to DEFAULTS below and
-- bump CN.dbVersion in Core.lua when the shape changes in a way that
-- requires a migration step.

local ADDON_NAME, CN = ...

local Print      = CN.Print
local DebugPrint = CN.DebugPrint

------------------------------------------------------------
-- DEFAULT DATABASE
------------------------------------------------------------

CN.defaults = {
    -- Kept in step with CN.dbVersion so a fresh install never looks like
    -- an old database that needs migrating.
    version = CN.dbVersion,

    settings = {
        -- `enabled` REMOVED. It sat here reading like a master on/off switch
        -- and nothing anywhere read it, so setting it false did nothing at
        -- all. A setting that is present and inert is worse than one that is
        -- absent: it invites somebody to rely on it.
        debug        = false,
        priorityMode = "balanced",

        -- Off by default: taking over the waypoint uninvited is hostile,
        -- and TomTom arrows are shared with every other addon.
        autoWaypoint = false,

        -- Addon lines on item and unit tooltips. On by default: these are
        -- additive and read-only, unlike the waypoint.
        tooltips     = true,

        -- The on-screen navigation arrow. On by default, but it only appears
        -- once something is actually being tracked, so it is never in the way
        -- of a player who has not asked for navigation.
        arrow        = true,

        -- Numbered route pins on the world map. On by default: like tooltip
        -- lines they are additive and read-only, they appear only on a map
        -- the player deliberately opened, and they are the only place the
        -- routing engine's work is visible.
        mapPins      = true,

        -- Follow mode. OFF by default and firmly so: it takes over the
        -- waypoint and puts a frame on screen, which is the most intrusive
        -- thing this addon can do. It is started deliberately or not at all.
        follow       = false,

        -- Announcing rares out loud is the noisiest thing this addon could
        -- do, so it is opt-in. Unsolicited sound is worse than an uninvited
        -- waypoint, and the waypoint is already off by default.
        rareAlerts   = false,

        -- Minimap button placement is an angle in degrees around the
        -- minimap edge, so it survives UI scale and minimap size changes.
        minimap = {
            hide  = false,
            angle = 225,
        },
    },

    account = {
        ignoredObjectives  = {},
        deferredObjectives = {},

        questMetadata      = {},
        discoveredQuests   = {},
        loremaster         = {},
        taskDurations      = {},
    },

    characters = {},
}

------------------------------------------------------------
-- MIGRATIONS
------------------------------------------------------------

-- Each entry migrates FROM the given version TO version + 1.
-- Never destroy user completion history here.
CN.migrations = {
    -- 1 -> 2. The collection modules introduced account tables that older
    -- databases do not have, and the minimap settings moved under a nested
    -- table. CopyDefaults fills both in, so this migration exists to prove
    -- the ladder runs and to normalize anything defaults cannot fix.
    [1] = function(db)
        db.account = db.account or {}

        -- Tables added after the schema was first written. Creating them
        -- here means no module has to guard against their absence.
        for _, key in ipairs({
            "pets", "mounts", "toys", "appearances", "titleNames",
            "achievements", "achievementTotals", "recipeNames",
            "reputations", "factionNames", "questHarvest", "questLocations",
            "collectionScans",
        }) do
            db.account[key] = db.account[key] or {}
        end

        db.settings = db.settings or {}

        -- Very early builds stored the minimap flag flat. Move it, and do
        -- not lose the player's choice in the process.
        if type(db.settings.minimap) ~= "table" then
            local wasHidden = db.settings.minimap == true or db.settings.hideMinimap == true

            db.settings.minimap = {
                hide  = wasHidden and true or false,
                angle = db.settings.minimapAngle or 225,
            }
        end

        db.settings.hideMinimap  = nil
        db.settings.minimapAngle = nil
    end,

    -- 2 -> 3. Per-character setting overrides.
    --
    -- Nothing to convert: every existing setting stays exactly where it is,
    -- account-wide, and characters start with no overrides at all. This entry
    -- exists so the ladder is explicit about the shape change rather than
    -- relying on absence, and so the assertion below documents the intent.
    [2] = function(db)
        db.characters = db.characters or {}

        for _, character in pairs(db.characters) do
            if type(character) == "table" then
                character.settings = character.settings or {}
            end
        end
    end,

    -- 3 -> 4. Observed prerequisites gained a confidence count.
    --
    -- The old shape was a flat array of candidate quest IDs, overwritten on
    -- every sighting, so it carried no idea of how often or on how many
    -- characters an ordering had held. The new shape counts by character.
    --
    -- Existing observations are preserved and credited to one unknown
    -- character each. That is deliberately BELOW the promotion threshold:
    -- data gathered before the addon knew how to count characters must not
    -- be promoted to a prerequisite on the strength of a count it never
    -- actually made.
    [3] = function(db)
        db.account = db.account or {}

        local harvest = db.account.questHarvest

        if type(harvest) ~= "table" then
            return
        end

        for _, record in pairs(harvest) do
            if type(record) == "table" and type(record.maybeRequires) == "table" then
                record.observed = record.observed or {}

                for _, prerequisiteID in ipairs(record.maybeRequires) do
                    record.observed[prerequisiteID] = record.observed[prerequisiteID]
                        -- `seen` NOT SEEDED. 0.90.0: migration 34 removes
                        -- the field, and a migration that runs before it must
                        -- not put it back on a database old enough to need
                        -- both.
                        or { characters = { ["migrated"] = true } }
                end

                record.maybeRequires = nil
            end
        end
    end,

    -- 4 -> 5: stop carrying a copy of the client's item cache.
    --
    -- Vendor rows stored every item's NAME as well as its ID. The client
    -- knows every item name already, so this was a duplicate of its cache
    -- written to disk, rewritten on every logout and re-parsed on every
    -- login -- and at retail scale it was the single largest thing this addon
    -- saved.
    --
    -- Dropped in place rather than waiting for a rescan, so the saving
    -- arrives on the next login rather than the next time the player happens
    -- to reopen every merchant they have ever visited.
    [4] = function(db)
        db.account = db.account or {}

        local vendors = db.account.vendors

        if type(vendors) ~= "table" then
            return
        end

        local dropped = 0

        for _, record in pairs(vendors) do
            if type(record) == "table" and type(record.items) == "table" then
                for _, item in pairs(record.items) do
                    if type(item) == "table" and item.name then
                        item.name = nil
                        dropped = dropped + 1
                    end
                end
            end
        end

        if dropped > 0 then
            CN.DebugPrint("Dropped " .. dropped
                .. " cached item names the client already knows.")
        end
    end,

    -- 5 -> 6: the same argument, applied to the two remaining stores.
    --
    -- Achievements kept a name and a point value for every tracked row;
    -- pets kept a name for all eighteen hundred. Both come back from the
    -- client instantly, and both were being written to disk on every logout
    -- and parsed again on every login.
    --
    -- Stripped in place so the space is reclaimed on the next login rather
    -- than on the next full rescan.
    [5] = function(db)
        db.account = db.account or {}

        local dropped = 0

        local function strip(store, fields)
            if type(store) ~= "table" then
                return
            end

            for _, record in pairs(store) do
                if type(record) == "table" then
                    for _, field in ipairs(fields) do
                        if record[field] ~= nil then
                            record[field] = nil
                            dropped = dropped + 1
                        end
                    end
                end
            end
        end

        strip(db.account.achievements, { "name", "points", "lastSeen" })
        strip(db.account.pets, { "name", "firstSeen", "lastSeen" })
        strip(db.account.toys, { "firstSeen", "lastSeen" })
        strip(db.account.achievementTotals, { "lastSeen" })

        if dropped > 0 then
            CN.DebugPrint("Dropped " .. dropped
                .. " stored values the client already knows.")
        end
    end,

    -- 6 -> 7. Five stores arrived between 0.40.0 and 0.43.0 and none needed a
    -- migration, so the version never moved -- which meant the ladder could
    -- not be used to enforce anything about them either.
    --
    -- The remembered quest pins are the one that matters: they are written on
    -- every scan of a map, capped by a constant in the module, and the cap
    -- was enforced only at the moment of writing. A database that grew past
    -- it under an older build, or through a version where the constant was
    -- larger, stayed large forever. Trim on the way in instead of trusting
    -- that it never happened.
    -- 8 -> 9. Three stores change shape, all of them for speed and all of
    -- them measured.
    --
    -- `ignoredObjectives` and `deferredObjectives` were keyed on a "TYPE:id"
    -- string, and the two functions that read them are called twice per
    -- candidate -- four thousand times each per rebuild at retail scale. So
    -- the moment a player used Ignore once, every rebuild built eight
    -- thousand strings to look up a table with one row in it: +2.2 ms per
    -- rebuild, a 53% increase, for exactly the people the feature is for.
    -- Nested by type, the lookup is two hash indexes and no string at all.
    --
    -- `flightRoutes` was keyed the same way and read once per surviving pair
    -- inside the travel search -- about a thousand times per journey estimate
    -- on a real continent. Node ids are integers, so the pair packs into one
    -- number exactly.
    [8] = function(db)
        db.account = db.account or {}

        for _, name in ipairs({ "ignoredObjectives", "deferredObjectives" }) do
            local store = db.account[name]

            if type(store) == "table" then
                local nested, moved, dropped = {}, 0, 0

                for key, entry in pairs(store) do
                    -- Already nested (a type name maps to a table of ids)
                    -- is left alone, so re-running is harmless.
                    local objectiveType, id =
                        string.match(tostring(key), "^(.-):(.+)$")

                    if objectiveType and id then
                        nested[objectiveType] = nested[objectiveType] or {}
                        nested[objectiveType][tonumber(id) or id] = entry
                        moved = moved + 1
                    elseif type(entry) == "table" then
                        -- Already nested: a type name mapping to a table of
                        -- ids. Carried across as it is.
                        nested[key] = entry
                    else
                        -- AND THE THIRD CASE, WHICH USED TO BE FOLDED INTO
                        -- THE SECOND AND PRODUCED A STORE NOTHING COULD READ.
                        --
                        -- A key with no colon whose value is not a table is
                        -- neither an old flat row nor a new nested one. The
                        -- old branch copied it straight across, so the
                        -- migrated store came out as a mix of `[type] =
                        -- table` and `[junk] = true` -- and `Ignored()`
                        -- indexes `store[type][id]`, which throws on the
                        -- second shape the moment anything of that name is
                        -- filtered.
                        --
                        -- There is nothing to recover here: the value carries
                        -- no id. Dropped, and counted.
                        dropped = dropped + 1
                    end
                end

                db.account[name] = nested

                if moved > 0 then
                    CN.DebugPrint("Renested " .. moved .. " row(s) in "
                        .. name .. ".")
                end

                if dropped > 0 then
                    CN.DebugPrint("Dropped " .. dropped
                        .. " unreadable row(s) from " .. name .. ".")
                end
            end
        end

        local routes = db.account.flightRoutes

        if type(routes) == "table" then
            local packed, moved = {}, 0

            local stride = 1000000

            for key, count in pairs(routes) do
                local from, to = string.match(tostring(key), "^(%d+):(%d+)$")

                if from and to then
                    packed[(tonumber(from) * stride) + tonumber(to)] = count
                    moved = moved + 1
                else
                    packed[key] = count
                end
            end

            db.account.flightRoutes = packed

            if moved > 0 then
                CN.DebugPrint("Repacked " .. moved .. " flight route key(s).")
            end
        end
    end,

    -- 9 -> 10. Preference rows for types the addon can never credit.
    --
    -- Every type a provider emits was counted as "shown"; only the five the
    -- client announces a completion for could ever be counted as "acted". The
    -- other thirteen accumulated sightings against a numerator that was nailed
    -- to zero, crossed the observation threshold, and settled permanently on
    -- the 0.80 floor -- while `/cn learned` reported "you rarely act on
    -- these", which the addon had no way to know.
    --
    -- 0.55.0 stops counting them. These rows are the residue: they cannot be
    -- corrected, because the sightings they hold were never paired with
    -- anything, and leaving them would keep them on screen. Dropped.
    --
    -- Quests, achievements, pets, mounts, toys and the two quest refinements
    -- are kept -- those were being measured properly.
    [9] = function(db)
        -- NOT `db.characters = {}`.
        --
        -- Replacing a corrupt value silently DESTROYS every character profile
        -- and then reports success, so `/cn navdiag` gives a clean bill of
        -- health over a database that just lost the lot. Nothing here is
        -- worth that. A missing table is created; a table that is something
        -- else is a fault, and this release already has machinery for
        -- recording a fault safely -- the `pcall` in `Migrate` catches this,
        -- files it, and stops the ladder.
        if db.characters == nil then
            db.characters = {}
        end

        if type(db.characters) ~= "table" then
            error("db.characters is a " .. type(db.characters)
                .. ", not a table" .. CN.DASH .. "refusing to replace it")
        end

        local keep = {
            QUEST = true, ACHIEVEMENT = true, PET = true, MOUNT = true,
            TOY = true, QUEST_CAMPAIGN = true, QUEST_SIDE = true,
        }

        local dropped = 0

        for _, character in pairs(db.characters) do
            local store = type(character) == "table" and character.preference

            if type(store) == "table" then
                for objectiveType in pairs(store) do
                    if not keep[objectiveType] then
                        store[objectiveType] = nil
                        dropped = dropped + 1
                    end
                end
            end
        end

        if dropped > 0 then
            CN.DebugPrint("Dropped " .. dropped
                .. " preference row(s) the addon could never have credited.")
        end
    end,

    -- 10 -> 11. The bank was a per-character fact in an account-wide table.
    --
    -- `db.account.bank` was written wholesale by whichever character last
    -- opened a bank and read by every character as its own -- so `/cn bags`
    -- on an alt reported items it cannot reach, and opening the bank on that
    -- alt destroyed the main's record. Exactly the defect migration 7 removed
    -- from `questStatus`, in exactly the same shape.
    --
    -- Dropped rather than migrated: there is no field anywhere saying whose
    -- bank it was, so it cannot be attributed, and the next time the player
    -- stands at a bank it is replaced by a correct one. Guessing an owner
    -- would be inventing a fact.
    [10] = function(db)
        db.account = db.account or {}

        if type(db.account.bank) == "table" then
            local held = CN.CountKeys(db.account.bank)

            db.account.bank = nil

            CN.DebugPrint("Dropped an account-wide bank record holding "
                .. tostring(held) .. " row(s); it belonged to one character "
                .. "and was read by all of them.")
        end
    end,

    -- 11 -> 12. The bank stores gained a per-container shape.
    --
    -- The flat store said WHAT was in a bank and not WHICH CONTAINER it was
    -- in, and the container is what makes "this tab has not been described"
    -- separable from "this tab is empty". There is nothing in the old rows
    -- that can be attributed, so they are dropped rather than guessed at --
    -- and the next time the player stands at a bank they are replaced by a
    -- record that keeps its own attribution.
    [11] = function(db)
        db.account    = db.account or {}
        db.characters = db.characters or {}

        local dropped = 0

        local function Flatten(store)
            if type(store) ~= "table" or store.containers ~= nil then
                return
            end

            for key in pairs(store) do
                store[key] = nil
            end

            dropped = dropped + 1
        end

        Flatten(db.account.warbandBank)

        for _, character in pairs(db.characters) do
            if type(character) == "table" then
                Flatten(character.bank)
            end
        end

        if dropped > 0 then
            CN.DebugPrint("Reset " .. dropped .. " bank record(s) that could "
                .. "not say which container each item was in.")
        end
    end,

    -- 12 -> 13. Three fields per discovered quest, all of them write-only.
    --
    -- `discoveredQuests[id]` held `{ firstSeen, lastSeen, source }` and every
    -- reader in the tree -- the completion scan, the breakdown, the window,
    -- `/cn queststatus` -- counts or iterates KEYS. On a mature account that
    -- is tens of thousands of three-field tables rewritten in full on every
    -- logout for information nothing has ever asked for.
    --
    -- Deliberately NOT capped, unlike the two stores beside it. `questPins`
    -- and `questHarvest` have ceilings because a stale pin and a stale
    -- ordering are worth less than a fresh one, so dropping the oldest loses
    -- nothing. A discovery is not like that: the set is what "this account
    -- has seen this quest offered" MEANS, the client will not re-supply it,
    -- and a ceiling would quietly make `/cn queststatus` and the harvest
    -- ordering answer a smaller question than the one asked. As booleans the
    -- store is a fraction of its former size, and `/cn dbsize` reports it.
    --
    -- `questMetadata` loses the same way: `questID` duplicated the key it is
    -- filed under, and `lastSeen` had no reader. `source` is kept -- it
    -- decides which of two names wins.
    [12] = function(db)
        db.account = db.account or {}

        local discovered = db.account.discoveredQuests

        if type(discovered) == "table" then
            local collapsed = 0

            for questID, record in pairs(discovered) do
                if type(record) == "table" then
                    discovered[questID] = true
                    collapsed = collapsed + 1
                end
            end

            if collapsed > 0 then
                CN.DebugPrint("Collapsed " .. collapsed .. " discovered quest "
                    .. "record(s) to the one fact anything reads.")
            end
        end

        local metadata = db.account.questMetadata

        if type(metadata) == "table" then
            local trimmed = 0

            for _, record in pairs(metadata) do
                if type(record) == "table"
                    and (record.questID ~= nil or record.lastSeen ~= nil) then

                    record.questID  = nil
                    record.lastSeen = nil

                    trimmed = trimmed + 1
                end
            end

            if trimmed > 0 then
                CN.DebugPrint("Dropped two write-only fields from "
                    .. trimmed .. " quest name record(s).")
            end
        end
    end,

    -- 13 -> 14. Stamp every currency row with a serial older than any sweep.
    --
    -- `Currencies` now reports only rows the LAST sweep saw, so a currency
    -- the client has stopped listing -- a retired season, an expansion
    -- currency, one migrated to the Warband -- stops being recommended.
    --
    -- Rows written before this release carry no serial, and treating those as
    -- current was the whole feature undone: a row the next scan will not
    -- rewrite is exactly the row that will never gain one. Serial 0 is older
    -- than the first sweep's 1, so an existing row is stale until a scan
    -- confirms it -- and the login scan runs before anything reads this.
    [13] = function(db)
        db.characters = db.characters or {}

        local stamped = 0

        for _, character in pairs(db.characters) do
            if type(character) == "table"
                and type(character.currencies) == "table" then

                for _, record in pairs(character.currencies) do
                    if type(record) == "table" and record.serial == nil then
                        record.serial = 0

                        stamped = stamped + 1
                    end
                end
            end
        end

        if stamped > 0 then
            CN.DebugPrint("Marked " .. stamped .. " currency row(s) as "
                .. "unconfirmed until the next scan.")
        end
    end,

    -- 7 -> 8. `questStatus` was a per-character fact kept in an account-wide
    -- table, which is two defects at once.
    --
    -- Wrong scope: `IsQuestFlaggedCompleted` answers for the character asking,
    -- so a main that ran `/cn scanquests` wrote its own four thousand
    -- completions into a store every alt then read as its own. `/cn breakdown`
    -- on a fresh alt reported the main's progress. Scanning on the alt
    -- overwrote the lot and destroyed the main's record.
    --
    -- And it should not have been persisted at all: both fields come from a
    -- free synchronous client call, which is the definition of something the
    -- addon does not need to remember. The standing rule is to persist only
    -- what the client cannot re-supply.
    --
    -- So the store is asked for live now, and the old one is dropped rather
    -- than migrated -- there is nothing in it that is worth keeping and much
    -- of it belongs to a different character.
    [7] = function(db)
        db.account = db.account or {}

        if type(db.account.questStatus) == "table" then
            local count = 0

            for key in pairs(db.account.questStatus) do
                db.account.questStatus[key] = nil
                count = count + 1
            end

            CN.DebugPrint("Dropped " .. count .. " stored quest statuses; "
                .. "the client answers this for free, and per character.")
        end

        db.account.questStatus = nil

        -- And the inert `enabled` flag, for the same reason: it was never
        -- read, so nothing can be relying on its value.
        if type(db.settings) == "table" then
            db.settings.enabled = nil
        end

        -- The harvest store's `zone` is `GetMapName(record.mapID)`, which the
        -- client answers for free -- the same duplication migrations 4 and 5
        -- removed elsewhere. And the store itself had no ceiling, unlike
        -- `questPins`, which migration 6 capped for exactly this reason and
        -- whose rows are smaller.
        local harvest = db.account.questHarvest

        if type(harvest) == "table" then
            local dropped, ids = 0, {}

            for questID, record in pairs(harvest) do
                if type(record) == "table" and record.zone ~= nil then
                    record.zone = nil
                    dropped = dropped + 1
                end

                table.insert(ids, questID)
            end

            local ceiling = 2000

            if #ids > ceiling then
                table.sort(ids)

                for index = 1, #ids - ceiling do
                    harvest[ids[index]] = nil
                end

                CN.DebugPrint("Trimmed " .. (#ids - ceiling)
                    .. " harvested quests over the ceiling.")
            end

            if dropped > 0 then
                CN.DebugPrint("Dropped " .. dropped
                    .. " stored zone names the client derives from the map.")
            end
        end
    end,

    [6] = function(db)
        db.account = db.account or {}

        local pins = db.account.questPins

        if type(pins) ~= "table" then
            return
        end

        local ceiling = 600

        local ids = {}

        for questID in pairs(pins) do
            table.insert(ids, questID)
        end

        if #ids <= ceiling then
            return
        end

        table.sort(ids)

        -- Lowest ids first: the oldest content, and the least likely to be
        -- what anybody is working on now.
        for index = 1, #ids - ceiling do
            pins[ids[index]] = nil
        end

        CN.DebugPrint("Trimmed " .. (#ids - ceiling)
            .. " remembered quest pins over the ceiling.")
    end,

    -- 14 -> 15. TWO THINGS THAT WERE WRITTEN TO DISK AND SHOULD NOT HAVE
    -- BEEN, AND ONE THAT WAS WRITTEN WITHOUT SAYING WHOSE IT WAS.
    --
    -- 1. `achievements[id].resolvedName`. `Achievements.Closest` wrote a
    --    client-supplied achievement name onto the live SavedVariables row so
    --    a sort comparator could read it, permanently, for every achievement
    --    the command ever touched. 0.36.0 deliberately stopped storing
    --    achievement names; this put them back one `/cn closest` at a time.
    --    The comparator holds them in a local now.
    --
    -- 2. `loremaster[id].done`. Criteria progress on a quest achievement is
    --    CHARACTER-specific and was stored account-wide under the achievement
    --    id alone, so the last character to scan overwrote every other
    --    character's figure -- in a store whose own comment says it exists so
    --    the Warband view can show what other characters have finished.
    --
    --    The flat field is kept and is now the current character's value; the
    --    per-character map is what the Warband view reads. This migration
    --    cannot know WHICH character wrote the existing number, so it does not
    --    guess: the flat value is left where it is, unattributed, and the
    --    first scan on each character fills in that character's entry. A
    --    wrong attribution would be worse than an absent one, because it
    --    would look authoritative.
    [14] = function(db)
        db.account = db.account or {}

        local names = 0

        for _, record in pairs(db.account.achievements or {}) do
            if type(record) == "table" and record.resolvedName ~= nil then
                record.resolvedName = nil

                names = names + 1
            end
        end

        if names > 0 then
            CN.DebugPrint("Dropped " .. names .. " achievement name(s) the "
                .. "client re-supplies for free.")
        end

        local split = 0

        for _, record in pairs(db.account.loremaster or {}) do
            if type(record) == "table" and record.progress == nil then
                record.progress = {}

                split = split + 1
            end
        end

        if split > 0 then
            CN.DebugPrint("Gave " .. split .. " loremaster row(s) a character "
                .. "dimension; each character's first scan fills in its own.")
        end

        -- AND THE LARGEST STORE IN THE ADDON LOSES ITS WRAPPER.
        --
        -- `questMetadata` was 708 KB of a 2.0 MB file, and the game rewrites
        -- that file in full on every logout. Every row was a two-field table
        -- and 30,000 of them said `source = "blizzard"` -- the default, which
        -- carries no information at all.
        --
        -- A row is the name itself now. Only a name the PLAYER typed keeps a
        -- table, because that one has something to say: it must not be
        -- clobbered the next time the client offers its own.
        local collapsed = 0

        for questID, record in pairs(db.account.questMetadata or {}) do
            if type(record) == "table" then
                if record.source == "manual" then
                    -- Left as a table, but without the fields nothing reads.
                    record.questID  = nil
                    record.lastSeen = nil
                elseif record.name then
                    db.account.questMetadata[questID] = record.name

                    collapsed = collapsed + 1
                else
                    db.account.questMetadata[questID] = nil
                end
            end
        end

        if collapsed > 0 then
            CN.DebugPrint("Collapsed " .. collapsed .. " quest name row(s) to "
                .. "the name itself.")
        end

        -- AND THE SETS THE PLAYER HAD ALREADY HIDDEN MOVE WITH THEIR IDS.
        --
        -- Transmog set objectives are filed under `"set:" .. setID` from
        -- 0.61.0, because a bare set id collided with an appearance CATEGORY
        -- id in the same namespace. Without this, a set the player hid before
        -- upgrading reappears -- and its old entry goes on hiding an
        -- unrelated appearance slot, which is precisely the collateral damage
        -- the fix was written to stop, now stranded where nobody can connect
        -- the two.
        --
        -- WHICH NUMERIC ENTRIES WERE SETS. Appearance category ids come from
        -- `Enum.TransmogCollectionType`, a small enumeration -- head,
        -- shoulder, chest and so on, under thirty of them. Set ids run to the
        -- thousands. So an entry above the ceiling was certainly a set and is
        -- moved; one at or below it is genuinely ambiguous, and this migration
        -- does not guess: a wrong re-key would hide something the player
        -- never hid, which is worse than leaving a small id where it is.
        --
        -- This runs at ADDON_LOADED, before the transmog APIs are reliable,
        -- so the ceiling is a constant rather than a client call.
        local CATEGORY_CEILING = 60

        local rekeyed = 0

        for _, store in ipairs({
            db.account.ignoredObjectives,
            db.account.deferredObjectives,
        }) do
            local appearances = type(store) == "table" and store.APPEARANCE

            if type(appearances) == "table" then
                local moves = {}

                for id, entry in pairs(appearances) do
                    if type(id) == "number" and id > CATEGORY_CEILING then
                        moves[id] = entry
                    end
                end

                for id, entry in pairs(moves) do
                    appearances[id] = nil
                    appearances["set:" .. id] = entry

                    rekeyed = rekeyed + 1
                end
            end
        end

        if rekeyed > 0 then
            CN.DebugPrint("Moved " .. rekeyed .. " hidden or deferred "
                .. "appearance set(s) onto their own key.")
        end
    end,

    -- 15 -> 16. TWO MORE FIELDS THE CLIENT HANDS BACK FOR FREE.
    --
    -- `mounts[id].source` is the journal's multi-line LOCALIZED source prose,
    -- around nine hundred rows of it -- the largest thing still written to
    -- disk that `GetMountInfoExtraByID` returns instantly. It was also the
    -- thing mount ranking used to branch on, which is why it was kept; 0.62.0
    -- ranks on the numeric `sourceType` instead, and the two places that
    -- DISPLAY the sentence read it live.
    --
    -- `rares[id].zone` was written on every sighting and read by nothing. The
    -- map id is already on the row. Migration 7 deleted the identical field
    -- from `questHarvest` and this copy survived it.
    --
    -- Same standing rule both times: persist only what the client cannot
    -- re-supply.
    [15] = function(db)
        db.account = db.account or {}

        local prose = 0

        for _, record in pairs(db.account.mounts or {}) do
            if type(record) == "table" and record.source ~= nil then
                record.source = nil

                prose = prose + 1
            end
        end

        local zones = 0

        for _, record in pairs(db.account.rares or {}) do
            if type(record) == "table" and record.zone ~= nil then
                record.zone = nil

                zones = zones + 1
            end
        end

        if prose > 0 or zones > 0 then
            CN.DebugPrint("Dropped source prose from " .. prose
                .. " mount row(s) and a derived zone name from " .. zones
                .. " rare row(s).")
        end
    end,

    -- 16 -> 17. THE LAST OF THE NAMES THE CLIENT HANDS BACK FOR FREE.
    --
    -- Around nine hundred mount names, a thousand toy names, and a zone name
    -- on every captured vendor. All three are LOCALIZED, all three are
    -- answered instantly by the client, and all three froze at whatever
    -- language last scanned -- so a player who switched client language could
    -- not find their own mounts by name and read old-locale zone names in
    -- every vendor tooltip.
    --
    -- This is the fifth application of one rule: persist only what the client
    -- cannot re-supply. Migrations 4, 5, 14 and 15 were the others.
    [16] = function(db)
        db.account = db.account or {}

        local names, zones = 0, 0

        for _, store in ipairs({ db.account.mounts, db.account.toys }) do
            for _, record in pairs(store or {}) do
                if type(record) == "table" and record.name ~= nil then
                    record.name = nil

                    names = names + 1
                end
            end
        end

        for _, record in pairs(db.account.vendors or {}) do
            -- Only where the map id can derive it again. A row with a zone
            -- and no map id has nothing to fall back on, and losing it would
            -- be losing information rather than losing a duplicate.
            if type(record) == "table" and record.zone ~= nil
                and record.mapID then

                record.zone = nil

                zones = zones + 1
            end
        end

        if names > 0 or zones > 0 then
            CN.DebugPrint("Dropped " .. names .. " collectible name(s) and "
                .. zones .. " vendor zone name(s) the client re-supplies.")
        end
    end,

    -- 17 -> 18. THE EXPLORATION STORE GETS A CHARACTER DIMENSION, AND TWO
    -- MORE STORES LOSE NAMES THE CLIENT ANSWERS FOR FREE.
    --
    -- 1. `exploration[id].done` and `.completed` are how much of a zone THIS
    --    character has explored, and they were written into an account store
    --    keyed by the achievement id alone -- the same defect migration 14
    --    fixed for `loremaster`, in the identically-shaped sibling store the
    --    fix never reached. It is worse here: the refresh is wired to
    --    `ZONE_CHANGED_NEW_AREA`, so an alt flying through a zone overwrote
    --    the main's progress on the way past, with no scan involved.
    --
    --    The flat fields stay and are the current character's; the map is
    --    what the Warband view reads. As with migration 14, this cannot know
    --    WHICH character wrote the existing number, so it does not guess.
    --
    -- 2. `exploration[id].name` and `loremaster[id].name` / `.category` are
    --    localized strings the client returns instantly -- and both were
    --    being BRANCHED on: the zone lookups substring-match a stored name
    --    against a live one, so a player who changed client language lost
    --    both features entirely until a rescan.
    --
    -- 3. `achievementTotals` is a per-category snapshot of numbers one client
    --    call answers, written on every scan and read by nothing at all.
    [17] = function(db)
        db.account = db.account or {}

        local split, names = 0, 0

        for _, record in pairs(db.account.exploration or {}) do
            if type(record) == "table" then
                if record.progress == nil then
                    record.progress = {}

                    split = split + 1
                end

                if record.name ~= nil then
                    record.name = nil

                    names = names + 1
                end
            end
        end

        for _, record in pairs(db.account.loremaster or {}) do
            if type(record) == "table"
                and (record.name ~= nil or record.category ~= nil) then

                record.name     = nil
                record.category = nil

                names = names + 1
            end
        end

        local totals = CN.CountKeys(db.account.achievementTotals)

        db.account.achievementTotals = nil

        if split > 0 or names > 0 or totals > 0 then
            CN.DebugPrint("Gave " .. split .. " exploration row(s) a character "
                .. "dimension, dropped " .. names .. " stored name(s), and "
                .. "removed " .. totals .. " write-only achievement total(s).")
        end
    end,

    -- 18 -> 19. THE LAST TWO NAME STORES, AND A STANDING THAT WAS ENGLISH.
    --
    -- `titleNames` and `currencyNames` are localized strings the client
    -- returns instantly. 0.64.0 gave their READERS a live path and left the
    -- two writers alone, so both stores went on filling with names frozen at
    -- whatever language last scanned -- and `Titles.Resolve` and
    -- `Currencies.Resolve` searched only those stores, so a player who
    -- changed client language could not find their own titles or currencies
    -- by name.
    --
    -- `reputations[id].standing` is localized for every faction EXCEPT a
    -- major one, where it was the hardcoded English "Renown 12" -- and
    -- persisted, so an alt's row was frozen at that character's language too.
    -- Dropped rather than rewritten: the next scan rebuilds it in the
    -- player's own language, and a wrong language now is better replaced than
    -- translated by guesswork.
    --
    -- Eighth and ninth applications of one rule: persist only what the client
    -- cannot re-supply.
    [18] = function(db)
        db.account = db.account or {}

        local titles     = CN.CountKeys(db.account.titleNames)
        local currencies = CN.CountKeys(db.account.currencyNames)

        db.account.titleNames   = nil
        db.account.currencyNames = nil

        local standings = 0

        for _, record in pairs(db.account.reputations or {}) do
            if type(record) == "table" and record.kind == "RENOWN"
                and record.standing ~= nil then

                record.standing = nil

                standings = standings + 1
            end
        end

        for _, character in pairs(db.characters or {}) do
            if type(character) == "table" then
                for _, record in pairs(character.reputations or {}) do
                    if type(record) == "table" and record.kind == "RENOWN"
                        and record.standing ~= nil then

                        record.standing = nil

                        standings = standings + 1
                    end
                end
            end
        end

        if titles > 0 or currencies > 0 or standings > 0 then
            CN.DebugPrint("Dropped " .. (titles + currencies)
                .. " stored name(s) and " .. standings
                .. " English renown standing(s) the client re-supplies.")
        end
    end,

    -- 19 -> 20. A COUNT OF EVENT DISPATCHES, PRESENTED AS A COUNT OF
    -- ENCOUNTERS.
    --
    -- `rares[id].sightings` was incremented once per vignette per dispatch of
    -- `VIGNETTE_MINIMAP_UPDATED`, which fires several times a second while
    -- anything is moving in range. So the number `/cn goal` printed as "Seen
    -- 1,847 times here" was a measure of how long the player had stood near a
    -- rare, in tenths of a second, and it grew while they read it.
    --
    -- 0.66.0 counts an encounter instead: a sighting after a gap. The stored
    -- values cannot be converted into that -- there is no ratio, because it
    -- depends entirely on how long the player lingered each time -- so they
    -- are dropped rather than scaled. The count rebuilds from the next
    -- sighting, and a number that is missing is better than one that is
    -- confidently wrong.
    [19] = function(db)
        db.account = db.account or {}

        local dropped = 0

        for _, record in pairs(db.account.rares or {}) do
            if type(record) == "table" and record.sightings ~= nil then
                record.sightings = nil

                dropped = dropped + 1
            end
        end

        if dropped > 0 then
            CN.DebugPrint("Dropped " .. dropped .. " inflated rare sighting "
                .. "count(s); they are counted per encounter now.")
        end
    end,
    -- 20 -> 21. THE FLAT FIELDS THE 0.66.0 CHANGE LEFT BEHIND.
    --
    -- 0.66.0 stopped WRITING `record.done` / `record.completed` on exploration
    -- and Loremaster rows, because any character rewrote them merely by flying
    -- through a zone and `DoneFor` fell back to them -- so an alt was handed
    -- the main's progress as its own. The read-side fallback was kept, on the
    -- stated grounds that databases written before the per-character split
    -- still need it and that the field would "decay out of the store as
    -- characters rescan".
    --
    -- It does not decay. Nothing rewrites it any more, so an upgraded account
    -- carries the last value the main wrote, for ever -- and Loremaster in
    -- particular scans only when its store is empty and is not in the setup
    -- run, so a fresh alt reads "Loremaster of Khaz Algar 90 / 120" with three
    -- done and never stops.
    --
    -- Deleted, once, here. That is what makes the fallback mean what its
    -- comment says: a pre-split database, and nothing else.
    [20] = function(db)
        db.account = db.account or {}

        local cleared = 0

        -- `done` FROM BOTH; `completed` FROM EXPLORATION ONLY. Corrected in
        -- 0.68.0, and repaired by migration 21 for anyone who ran the first
        -- version of this. Loremaster's `completed` is ACCOUNT-wide by
        -- design -- an achievement is earned once for the whole account, as
        -- that file says in as many words -- and it is still written by every
        -- scan. Deleting it here removed a live field that nothing rewrites,
        -- because the Loremaster login scan only runs when the store is
        -- EMPTY.
        for _, record in pairs(db.account.exploration or {}) do
            if type(record) == "table"
                and (record.done ~= nil or record.completed ~= nil) then

                record.done      = nil
                record.completed = nil

                cleared = cleared + 1
            end
        end

        for _, record in pairs(db.account.loremaster or {}) do
            if type(record) == "table" and record.done ~= nil then
                record.done = nil

                cleared = cleared + 1
            end
        end

        if cleared > 0 then
            CN.DebugPrint("Cleared " .. cleared .. " shared progress figure(s)"
                .. " that belonged to whichever character wrote last.")
        end
    end,

    -- 21 -> 22. REPAIRING WHAT MIGRATION 20 TOOK.
    --
    -- The first version of migration 20 deleted `completed` from every
    -- Loremaster record as well as from every exploration one. Exploration
    -- was right; Loremaster was not -- that flag is account-wide, is still
    -- written by every scan, and nothing rewrites it in between because the
    -- login scan only fires when the store is EMPTY.
    --
    -- The visible result was the addon recommending finished zones: `/cn
    -- zones` put "Loremaster of Khaz Algar 120/120" at the top of "worth
    -- doing next" with the reason "100% done -- finishing is cheaper than
    -- starting", and the Journey tab listed every completed achievement as
    -- closest to finished.
    --
    -- The whole store is re-derivable from the client -- name, category,
    -- criteria count, completion and this character's progress all come from
    -- the achievement API -- so it is emptied rather than patched, and the
    -- login scan that fires on an empty store rebuilds it correctly. Nothing
    -- is lost that the client cannot hand back.
    [21] = function()
        -- DELIBERATELY EMPTY, AND KEPT SO THE LADDER STAYS CONTINUOUS.
        --
        -- This used to empty `account.loremaster` outright, to force the
        -- login scan to rebuild what the first version of migration 20 had
        -- taken. Its own comment claimed "nothing is lost that the client
        -- cannot hand back" and that was wrong: `record.progress` is keyed by
        -- character, and the client can only ever report the character
        -- currently logged in. Emptying the store destroyed every ALT's
        -- criteria progress to repair one account-wide flag.
        --
        -- The repair belongs where it can actually be made: the login scan
        -- rewrites `completed` for every row and this character's progress
        -- for its own, and 0.69.0 triggers it on either being absent. Each
        -- character repairs itself the first time it plays, and nobody's work
        -- is thrown away to do it.
    end,

    -- A STAMP THAT SHOULD NEVER HAVE BEEN WRITTEN DOWN. 0.72.0.
    --
    -- 0.71.0 cached "which achievement is this zone" onto the record itself,
    -- as `record.mapID`, taken from `GetBestMapForUnit` -- which answers with
    -- the CITY map indoors. So the value is wrong wherever it differs from
    -- the zone it was matched by, it was rewritten on every threshold
    -- crossed, and one zone could end up with two records each claiming a
    -- different map.
    --
    -- The lookup is remembered in memory now, for the session, under the zone
    -- name it was actually matched on. Nothing about it belongs on disk.
    -- Removed here rather than left inert, because a field left behind is a
    -- field the next reader will believe.
    [22] = function(db)
        local account = db.account

        if not account or type(account.loremaster) ~= "table" then
            return
        end

        for _, record in pairs(account.loremaster) do
            if type(record) == "table" then
                record.mapID = nil
            end
        end
    end,

    -- AND THE LOCALIZED STANDING MIGRATION 18 ONLY HALF-REMOVED. 0.72.0.
    --
    -- 18 stripped `standing` from RENOWN rows because it had been persisted
    -- as hardcoded English. It did not stop the SCANNER writing it, so the
    -- next `/cn repscan` put it straight back -- for every kind of faction,
    -- not just RENOWN -- and `StandingText` preferred the stored copy to its
    -- own derivation. A migration undone by the ordinary use of the addon.
    --
    -- 0.72.0 stopped writing it. This removes what the last three years of
    -- scans left behind, on account rows and on every character's, so that
    -- the derivation is the only thing anything can read. The exception is
    -- `friendshipStanding`, which is written under its own name precisely
    -- because the client will not re-supply it for an alt.
    [23] = function(db)
        -- HOW MANY RANKS THIS MIGRATION CARRIED ACROSS. Read by 25, which
        -- otherwise accuses 0.72.0 of a loss that never happened on this
        -- database; see the note there.
        local carried = 0

        local function Strip(store)
            if type(store) ~= "table" then
                return
            end

            for _, record in pairs(store) do
                if type(record) == "table" then
                    -- CARRIED, NOT DELETED, FOR THE ONE KIND THAT NEEDS IT.
                    -- Corrected in 0.73.0, before this shipped a second time.
                    --
                    -- 0.72.0 wrote a paragraph saying a friendship's rank is
                    -- the one standing the client will not re-supply for an
                    -- alt, moved it to `friendshipStanding`, and then had
                    -- this loop delete every existing copy of it. No row
                    -- written before 0.72.0 carries the new field, so every
                    -- alt's friendship rank would have been destroyed on
                    -- upgrade -- and shown as a standard 1-8 label, or as
                    -- nothing, in `/cn rep`, `/cn who rep`, `/cn alts` and
                    -- the Warband tab.
                    --
                    -- The store cannot be rebuilt by logging in: that is the
                    -- entire reason the field is kept.
                    if record.kind == "FRIENDSHIP"
                        and record.friendshipStanding == nil
                        and type(record.standing) == "string"
                        and record.standing ~= "" then

                        record.friendshipStanding = record.standing

                        carried = carried + 1
                    end

                    record.standing = nil
                end
            end
        end

        Strip(db.account and db.account.reputations)

        for _, character in pairs(db.characters or {}) do
            if type(character) == "table" then
                Strip(character.reputations)
            end
        end

        -- Even at zero: what matters to 25 is that this database took the
        -- CORRECTED path, not how much it found on the way.
        db.friendshipRanksCarried = true

        if carried > 0 then
            DebugPrint("Carried " .. carried .. " friendship rank(s).")
        end
    end,

    -- THE EXPLORATION MAP STAMP, WRITTEN FROM THE WRONG CLIENT CALL. 0.74.0.
    --
    -- `Exploration.ForCurrentZone` has stamped `record.mapID` from
    -- `GetBestMapForUnit` since 0.62.0 -- the building or cave map indoors --
    -- and learned it from an unordered walk that could bind the wrong one of
    -- two same-named zones. Migration 22 removed the identical field from the
    -- loremaster store and left this one, because at the time only Loremaster
    -- had been looked at.
    --
    -- Every stamp written before this release is therefore either the wrong
    -- map or an unjustified guess, and both are re-learnable in a second by
    -- standing in the zone. Cleared rather than migrated: there is nothing
    -- here worth keeping and a wrong one is read as fact.
    [24] = function(db)
        local account = db.account

        if not account or type(account.exploration) ~= "table" then
            return
        end

        for _, record in pairs(account.exploration) do
            if type(record) == "table" then
                record.mapID = nil
            end
        end
    end,

    -- WHAT 0.72.0 DESTROYED, SAID OUT LOUD RATHER THAN LEFT SILENT. 0.74.0.
    --
    -- 0.72.0's migration 23 deleted `record.standing` from every reputation
    -- row, including FRIENDSHIP rows, whose rank is free text the client
    -- supplies for the logged-in character ONLY. 0.73.0 corrected the
    -- migration to carry it -- but anyone who had already upgraded through
    -- 0.72.0 was past it, and the addon said nothing.
    --
    -- Nothing can bring that back; each character restores its own the next
    -- time it logs in. What the addon owes the player is to say so, once,
    -- rather than let them find a blank column and wonder. Prompt, never act.
    [25] = function(db)
        -- A DATABASE THAT TOOK THE CORRECTED PATH LOST NOTHING. 0.76.0.
        --
        -- Migration 23 was fixed in 0.73.0 to carry a friendship's rank
        -- across instead of deleting it. An account upgrading from below 23
        -- therefore runs the corrected version and loses nothing -- and then
        -- fell straight into this, which counted every row without a
        -- `friendshipStanding` (including ones that never had a standing
        -- string at all) and reported them as destroyed by 0.72.0.
        --
        -- A wrong number in the one message whose stated purpose is honesty
        -- about data loss, which is the same class of error this migration
        -- was already corrected for once.
        if db.friendshipRanksCarried then
            return
        end

        local lost = 0

        -- NOT THIS CHARACTER. Corrected in 0.75.0.
        --
        -- Migrations run at `ADDON_LOADED`, before this character's
        -- reputation scan restores its OWN friendship ranks -- so every one
        -- of its rows satisfied the test and was counted. The notice then
        -- told the player that N ranks "on other characters" were lost, with
        -- an N that included rows about to be restored seconds later on the
        -- character reading the message. A wrong number in the one message
        -- whose entire purpose is honesty about data loss.
        local mine = CN.GetCharacterKey and CN.GetCharacterKey()

        for key, character in pairs(db.characters or {}) do
            if key ~= mine and type(character) == "table"
                and type(character.reputations) == "table" then

                for _, record in pairs(character.reputations) do
                    if type(record) == "table"
                        and record.kind == "FRIENDSHIP"
                        and record.friendshipStanding == nil then

                        lost = lost + 1
                    end
                end
            end
        end

        if lost > 0 then
            db.account = db.account or {}
            db.account.notices = db.account.notices or {}

            table.insert(db.account.notices, {
                at   = time(),
                text = lost .. CN.Pluralize(lost, " friendship rank",
                        " friendship ranks")
                    .. " on other characters "
                    .. CN.Pluralize(lost, "was", "were")
                    .. " lost by a defect in version 0.72.0. Each character "
                    .. "restores its own the next time it logs in.",
            })
        end
    end,

    -- THE FLAT CRITERIA FIELD IN THE ACHIEVEMENT STORE. 0.75.0.
    --
    -- `record.done` held whichever character scanned last. 0.74.0 added a
    -- per-character `progress` table and then never wrote it -- the scan
    -- built a fresh table literal and the writer kept setting the flat field
    -- -- so the split existed on paper only. Both halves are fixed, and this
    -- removes the field so that `DoneFor`'s fallback cannot go on handing one
    -- character's figure to another.
    --
    -- Nothing is lost that a scan does not hand straight back, and an alt
    -- reading "0 of 40" until it scans is right where reading the main's
    -- "38 of 40" was wrong.
    [26] = function(db)
        local account = db.account

        if not account or type(account.achievements) ~= "table" then
            return
        end

        local blanked = 0

        for _, record in pairs(account.achievements) do
            if type(record) == "table" and record.done ~= nil then
                record.done = nil
                blanked = blanked + 1
            end
        end

        -- AND IT SAYS SO, BECAUSE NOTHING ELSE WOULD. 0.76.0.
        --
        -- 0.74.0's scan never wrote the per-character table, and the criteria
        -- sweep touches only a dozen rows -- so for an upgrading account the
        -- flat field was the ONLY figure nearly every row had, and clearing
        -- it empties the shortlist, `/cn next`'s achievement rows and every
        -- goal plan at once.
        --
        -- Nothing recovers on its own: the achievement scan has no login hook
        -- and no event. The reminder is repaired separately, by asking each
        -- character whether IT has scanned rather than reading an
        -- account-wide stamp -- but a player whose recommendations changed
        -- underneath them is owed the sentence.
        if blanked > 0 then
            db.account = db.account or {}
            db.account.notices = db.account.notices or {}

            table.insert(db.account.notices, {
                at   = time(),
                text = "Achievement criteria progress is now recorded per "
                    .. "character. Run /cn achievescan on each character "
                    .. "once; until then its achievement recommendations "
                    .. "will be missing.",
            })
        end
    end,

    -- DELIBERATELY EMPTY, AND KEPT SO THE LADDER STAYS CONTINUOUS.
    --
    -- 0.76.0 changes no stored shape of its own: every fix in it is to code
    -- that reads or writes what is already there. The version is bumped so
    -- that a database upgrading from 0.75.0 still runs migration 26's notice
    -- path if it has not, and the ladder rule -- one migration per step, no
    -- gaps -- is the reason this is a function rather than a hole. Migration
    -- 21 is the precedent.
    [27] = function()
    end,

    -- 0.77.0's VERSION OF THIS LOOKED IN A TABLE THAT DOES NOT EXIST.
    --
    -- It cleared from `db.account.settings` and `character.preferences`.
    -- Settings live at `db.settings` -- `AccountSettings()` returns that, the
    -- account defaults have no `settings` key, and nothing in the tree ever
    -- asks `CN.Account("settings")`. So the migration ran, found nothing,
    -- stamped itself done, and the headline fix of that release reached
    -- nobody: every legacy `{point, x, y}` survived, and
    -- `CN.RestoreFramePosition` falls back to `placement.point` for the
    -- missing relative point -- which is exactly the broken anchor it was
    -- written to stop using.
    --
    -- Version 29 has shipped, so this one cannot be re-run. Kept as an empty
    -- function so the ladder stays continuous; the real reset is [29] below.
    [28] = function()
    end,

    -- THE FRAME POSITIONS THREE FRAMES SAVED WITHOUT A RELATIVE POINT.
    --
    -- The heads-up line, the follow list and the arrow all stored
    -- `{ point, x, y }` and restored with the anchor standing in for the
    -- relative point. Where the two differ the offsets were re-applied
    -- against a different corner of the screen, so the frame came back a
    -- screen away from where it was left and was then pinned to an edge --
    -- which is the reported "it drags and does not stay".
    --
    -- A stored position with no `relativePoint` is one of those, and there is
    -- no way to tell whether it was ever wrong. Cleared, so each frame starts
    -- from its default and is placed once more, rather than restored to
    -- somewhere the player never put it.
    --
    -- IN `db.settings`, which is where they actually are. See [28].
    [29] = function(db)
        local function Reset(store, key)
            if type(store) ~= "table" then
                return
            end

            local held = store[key]

            if type(held) == "table" and held.point
                and not held.relativePoint then

                store[key] = nil
            end
        end

        for _, key in ipairs({ "hudPosition", "arrowPosition",
                               "followPosition" }) do
            Reset(db.settings, key)

            for _, character in pairs(db.characters or {}) do
                if type(character) == "table" then
                    Reset(character.settings, key)
                end
            end
        end

        -- AND THE EMPTY TABLE THE ARROW WROTE ON EVERY FIRST BUILD. 0.78.0.
        --
        -- `settings.arrowPosition = settings.arrowPosition or {}` put a
        -- permanent empty table in saved data for a player who never moved
        -- the arrow, which nothing read and which would defeat any later
        -- reset keyed on the entry being present.
        if type(db.settings) == "table"
            and type(db.settings.arrowPosition) == "table"
            and db.settings.arrowPosition.point == nil then

            db.settings.arrowPosition = nil
        end

        -- A LIFETIME TOTAL THE CLIENT ALREADY KEEPS. 0.78.0.
        --
        -- `Progress` incremented `total` on every turn-in and read it back
        -- nowhere: `Progress.Summary` takes its lifetime figure from the
        -- client, which that file's own header calls "the real lifetime
        -- total". Sixth store to lose a field it did not need to keep.
        if type(db.account) == "table"
            and type(db.account.progress) == "table" then

            db.account.progress.total = nil
        end
    end,

    -- A CHOICE THE PLAYER MADE, CARRIED THROUGH A RENAME. 0.79.0.
    --
    -- The Great Vault claim row's id was `0` until 0.78.0, when it became
    -- "vault" -- because `CN.ToID` rejects `0`, so `/cn unhide` could never
    -- name it back. The rename orphaned whatever the player had already
    -- hidden or deferred under the old key: the row came back, and a phantom
    -- entry stayed in `/cn hidden` that nothing could remove.
    --
    -- Moved rather than dropped. A player who hid something once should not
    -- have to hide it again because the addon changed its mind about how to
    -- name it internally.
    [30] = function(db)
        local currency = CN.objectiveTypes and CN.objectiveTypes.CURRENCY
            or "CURRENCY"

        for _, storeName in ipairs({ "ignoredObjectives",
                                     "deferredObjectives" }) do
            local store = db.account and db.account[storeName]

            local byType = type(store) == "table" and store[currency]

            if type(byType) == "table" and byType[0] ~= nil then
                if byType["vault"] == nil then
                    byType["vault"] = byType[0]
                end

                byType[0] = nil
            end
        end
    end,

    -- THE STORE MIGRATION 5 MISSED.
    --
    -- Migration 5 stripped `lastSeen` from four account stores because the
    -- field was written on every scan and read by nothing -- the whole point
    -- of that migration. `appearances` has the same dead field, written by
    -- the same kind of scan, and was not in the list. Its writer is fixed in
    -- 0.80.0; this clears what nineteen releases of logins wrote to disk.
    [31] = function(db)
        local store = db.account and db.account.appearances

        if type(store) ~= "table" then
            return
        end

        local dropped = 0

        for _, record in pairs(store) do
            if type(record) == "table" and record.lastSeen ~= nil then
                record.lastSeen = nil
                dropped = dropped + 1
            end
        end

        if dropped > 0 then
            CN.DebugPrint("Dropped " .. dropped
                .. " appearance timestamps nothing reads.")
        end
    end,

    -- THE TWO STORES MIGRATIONS 5 AND 31 BOTH MISSED.
    --
    -- Migration 5 stripped `firstSeen`/`lastSeen` from four account stores
    -- because they were written on every scan and read by nothing. Migration
    -- 31 caught `appearances`. `mounts` -- roughly nine hundred rows, the
    -- largest of the lot -- and `reputations` were missed by both, and their
    -- writers were still putting the fields back on every login until 0.82.0.
    --
    -- Written as a table of store to fields, so a fifth store found later is
    -- one line rather than another migration.
    [32] = function(db)
        local dead = {
            mounts      = { "firstSeen", "lastSeen" },
            reputations = { "lastSeen" },
        }

        local dropped = 0

        local function strip(store, fields)
            if type(store) ~= "table" then
                return
            end

            for _, record in pairs(store) do
                if type(record) == "table" then
                    for _, field in ipairs(fields) do
                        if record[field] ~= nil then
                            record[field] = nil
                            dropped = dropped + 1
                        end
                    end
                end
            end
        end

        for storeName, fields in pairs(dead) do
            strip(db.account and db.account[storeName], fields)
        end

        -- AND THE CHARACTER HALF OF THE REPUTATION STORE. 0.83.0.
        --
        -- `Reputations.Scan` writes the record into the ACCOUNT store only
        -- when the faction is account-wide, and into `character.reputations`
        -- otherwise -- which is most factions, so the character copy holds
        -- the larger half of the rows.
        --
        -- Every store the four earlier cleanups touched was account-only, so
        -- "walk `db.account[name]`" was the whole job and this one inherited
        -- the shape without inheriting the question. The test could not see
        -- it either: its fixture had no characters in it.
        for _, character in pairs(db.characters or {}) do
            if type(character) == "table" then
                strip(character.reputations, dead.reputations)
            end
        end

        if dropped > 0 then
            CN.DebugPrint("Dropped " .. dropped
                .. " stored values nothing reads.")
        end
    end,

    -- AND THE SIXTH STORE. 0.89.0.
    --
    -- Migration 5 stripped `lastSeen` from four stores, 31 from appearances,
    -- 32 from mounts and reputations. `exploration` was in none of the three
    -- sweeps and its writer went on putting the field back on every scan and
    -- every `/cn explorescan`. Nothing in the addon has ever read it.
    --
    -- Migration 32's note said a fifth store found later would be one line;
    -- it is one line, in a new migration, because 32 has shipped.
    [33] = function(db)
        local store = db.account and db.account.exploration

        if type(store) ~= "table" then
            return
        end

        local dropped = 0

        for _, record in pairs(store) do
            if type(record) == "table" and record.lastSeen ~= nil then
                record.lastSeen = nil

                dropped = dropped + 1
            end
        end

        if dropped > 0 then
            CN.DebugPrint("Dropped " .. dropped
                .. " exploration timestamps nothing reads.")
        end
    end,

    -- AND THE HARVEST SIGHTING COUNTER. 0.90.0.
    --
    -- One integer per (quest, prerequisite) pair, on a store capped at 2000
    -- rows, incremented on every quest accepted inside the five-minute window
    -- and read by nothing. `Harvest.Confidence` -- the only thing that could
    -- want it -- counts distinct CHARACTERS instead, deliberately. Migration
    -- 3 seeded the field; this removes it.
    [34] = function(db)
        local store = db.account and db.account.questHarvest

        if type(store) ~= "table" then
            return
        end

        local dropped = 0

        for _, record in pairs(store) do
            if type(record) == "table" and type(record.observed) == "table" then
                for _, candidate in pairs(record.observed) do
                    if type(candidate) == "table"
                        and candidate.seen ~= nil then

                        candidate.seen = nil

                        dropped = dropped + 1
                    end
                end
            end
        end

        if dropped > 0 then
            CN.DebugPrint("Dropped " .. dropped
                .. " harvest sighting counters nothing reads.")
        end
    end,

    -- SIX MORE FIELDS NOTHING READS. 0.91.0.
    --
    -- `currencies.lastSeen` is the seventh store to carry this field with no
    -- reader; `Modules/Currencies.lua`'s own header said so and the write
    -- survived four separate sweeps. `progress.previousDayKey` and
    -- `progress.bestDay` sat beside `progress.total`, which migration 29
    -- removed. The three harvest fields are on a store capped at two thousand
    -- rows: an integer, a string and an array each.
    [35] = function(db)
        local dropped = 0

        local function strip(store, fields)
            if type(store) ~= "table" then
                return
            end

            for _, record in pairs(store) do
                if type(record) == "table" then
                    for _, field in ipairs(fields) do
                        if record[field] ~= nil then
                            record[field] = nil

                            dropped = dropped + 1
                        end
                    end
                end
            end
        end

        strip(db.account and db.account.currencies, { "lastSeen" })

        strip(db.account and db.account.questHarvest,
            { "observedLevel", "requiresFrom", "reason" })

        -- AND THE CHARACTER HALVES. The currency store's larger half lives on
        -- the character, and `progress` is character-only -- which is the
        -- exact shape migration 32 records missing the first time.
        for _, character in pairs(db.characters or {}) do
            if type(character) == "table" then
                strip(character.currencies, { "lastSeen" })

                if type(character.progress) == "table" then
                    for _, field in ipairs({ "previousDayKey", "bestDay" }) do
                        if character.progress[field] ~= nil then
                            character.progress[field] = nil

                            dropped = dropped + 1
                        end
                    end
                end
            end
        end

        if dropped > 0 then
            CN.DebugPrint("Dropped " .. dropped
                .. " stored values nothing reads.")
        end
    end,

    -- TWO MORE STORES, AND ONE VALUE THAT CANNOT BE READ BACK. 0.92.0.
    --
    -- `vendors.firstSeen` and `rares.firstSeen` are the sixth and seventh
    -- stores to carry a timestamp nothing reads; `Modules/Mounts.lua` states
    -- the rule and migration 5 stripped four of them.
    --
    -- The deferral is a different problem. `/cn defer forever` stored
    -- `until_ = time() + math.huge`, which is `inf`. The client serialises
    -- that as the bare word `inf`, which parses on the next login as an
    -- UNDEFINED GLOBAL and comes back as nil -- so the value written was not
    -- the value read, silently. It behaved correctly by accident, because a
    -- missing `until_` means "never expires", and that is what it is written
    -- as now. Any row already on disk carrying a non-finite number is
    -- normalised here rather than left to be read as whatever a global named
    -- `inf` happens to hold.
    [36] = function(db)
        local dropped = 0

        local function strip(store, fields)
            if type(store) ~= "table" then
                return
            end

            for _, record in pairs(store) do
                if type(record) == "table" then
                    for _, field in ipairs(fields) do
                        if record[field] ~= nil then
                            record[field] = nil

                            dropped = dropped + 1
                        end
                    end
                end
            end
        end

        strip(db.account and db.account.vendors, { "firstSeen" })
        strip(db.account and db.account.rares,   { "firstSeen" })

        local normalised = 0

        local deferred = db.account and db.account.deferredObjectives

        for _, byType in pairs(deferred or {}) do
            if type(byType) == "table" then
                for _, entry in pairs(byType) do
                    if type(entry) == "table" then
                        local until_ = entry.until_

                        -- A non-finite number, or the nil an `inf` round-trip
                        -- produced. `x ~= x` catches nan; the comparison
                        -- catches inf without naming `math.huge` twice.
                        if type(until_) == "number"
                            and (until_ ~= until_
                                or until_ >= math.huge) then

                            entry.until_ = nil

                            normalised = normalised + 1
                        end
                    end
                end
            end
        end

        if dropped > 0 or normalised > 0 then
            CN.DebugPrint("Dropped " .. dropped .. " stored values nothing "
                .. "reads and normalised " .. normalised
                .. " deferrals that could not be read back.")
        end
    end,
}

-- Published so the harness can drive it against a hand-built database. A
-- migration path that is only reachable through a real login is a migration
-- path nothing tests until it has already run on somebody's saved data.
local function Migrate(db)
    local from = db.version or 1

    while from < CN.dbVersion do
        local migration = CN.migrations[from]

        if migration then
            local ok, err = pcall(migration, db)

            if not ok then
                -- A HALF-APPLIED MIGRATION IS NOT A THING TO BE QUIET ABOUT.
                --
                -- This printed once, at login, into a chat frame that is
                -- usually mid-scroll, and then the addon carried on reading a
                -- database that is now in neither the old shape nor the new
                -- one. Every subsequent login retries the same migration
                -- against data it has already partly rewritten.
                --
                -- Record it, so `/cn navdiag` and the self-test can see it and
                -- say so rather than reporting a clean bill of health over a
                -- database that is not.
                db.migrationFailure = {
                    version = from,
                    error   = tostring(err),
                }

                CN.migrationFailure = db.migrationFailure

                CN.PrintLine("Database migration " .. from .. " failed: " .. tostring(err))

                -- NOT "your data is unchanged". A migration that threw
                -- part-way through has already rewritten some of it, which is
                -- the whole reason this is worth telling anybody about.
                CN.PrintLine("This step may have half-finished. Nothing further will "
                    .. "be upgraded until it succeeds. Run "
                    .. "|cffffc74f/cn navdiag|r for the details.")

                return
            end

            -- Cleared only by the migration that failed actually succeeding.
            --
            -- NOT WHEN SOMETHING WAS SET ASIDE, though. Migration 9 refuses a
            -- corrupt `characters` value; the rescue below moves it to
            -- `rescuedCharacters` and leaves `characters` nil -- so on the
            -- NEXT login the same migration sees nil, takes the "create it"
            -- branch, succeeds, and cleared the record right here. One login
            -- after the refusal, `/cn navdiag` reported a clean bill of
            -- health over an empty character list, and the rescued data sat
            -- in SavedVariables forever with nothing that mentioned it.
            --
            -- The failure is what the player is told about; the rescue is the
            -- thing that has not been dealt with. They are separate facts and
            -- only the first of them is over.
            if db.migrationFailure and db.migrationFailure.version == from then
                db.migrationFailure = nil
                CN.migrationFailure = nil
            end

            DebugPrint("Migrated database from version " .. from .. ".")
        end

        from = from + 1
        db.version = from
    end
end

CN.RunMigrations = Migrate

------------------------------------------------------------
-- INITIALIZATION
------------------------------------------------------------

-- WHAT A MIGRATION REFUSED TO DESTROY, `CopyDefaults` WOULD.
--
-- Migration 9 raises rather than replacing a corrupt `characters` value,
-- which stops the ladder and files the fault -- and then `CopyDefaults`
-- replaces any stored value whose type no longer matches its default, which
-- is exactly that value. So the refusal was announced and then quietly
-- undone, the evidence was overwritten, and the next login found a clean `{}`
-- and cleared the failure record. The whole point of refusing is that the
-- data is still there afterwards.
--
-- Moved aside under its own key, which `CopyDefaults` has no default for and
-- therefore leaves alone. `/cn rescued` is the only thing that removes it.
function CN.RescueUnreadable(raw)
    if type(raw) ~= "table" then
        return false
    end

    if not raw.migrationFailure then
        return false
    end

    if raw.characters == nil or type(raw.characters) == "table" then
        return false
    end

    raw.rescuedCharacters = raw.characters
    raw.characters        = nil

    return true
end

function CN.InitializeDatabase()
    local raw = CompletionNavigatorDB

    -- A brand new install has nothing to migrate; stamping it at the current
    -- version stops migration 1 running against an empty table.
    local isFresh = type(raw) ~= "table" or next(raw) == nil

    raw = type(raw) == "table" and raw or {}

    if isFresh then
        raw.version = CN.dbVersion
    else
        -- Migrations MUST run on the raw saved data, before defaults are
        -- merged in.
        --
        -- CopyDefaults replaces any stored value whose type no longer matches
        -- the default -- a legacy boolean where the default is now a table
        -- gets discarded outright. Running defaults first would therefore
        -- destroy exactly the values a migration exists to read, and it would
        -- do so silently.
        Migrate(raw)

        CN.RescueUnreadable(raw)
    end

    CompletionNavigatorDB = CN.CopyDefaults(CN.defaults, raw)

    CN.db = CompletionNavigatorDB

    -- The ignore and defer stores are held as file-locals in Objectives.lua
    -- so the hottest pair of functions in the addon does not do a table
    -- lookup and two `or {}` assignments per call. The table identity changes
    -- here, so the references have to be renewed here.
    if CN.RefreshFilterStores then
        CN.RefreshFilterStores()
    end

    DebugPrint("Database initialized (schema version " .. tostring(CN.db.version) .. ").")
end

------------------------------------------------------------
-- ACCESSORS
------------------------------------------------------------

-- Safe accessor for account tables. Creates the table if it is missing so
-- new subsystems can be added without a migration.
function CN.Account(key)
    if not CN.db then
        return nil
    end

    CN.db.account = CN.db.account or {}

    if key then
        CN.db.account[key] = CN.db.account[key] or {}
        return CN.db.account[key]
    end

    return CN.db.account
end

-- Which candidate providers read which store. Rescanning your mounts must not
-- rebuild the achievement candidates; measured, that mistake cost 18ms of a
-- 16ms frame every time a mount was learned.
--
-- A store with no entry here feeds no candidate provider at all.
--
-- That sentence used to name mounts, toys and appearances as examples, and
-- it stopped being true when each of them became a candidate provider. So
-- `/cn setup` scanned them, rewrote their stores, printed "Setup complete",
-- and left the providers holding a cache built before the scan -- the
-- collections a new player had just scanned for were invisible to `/cn next`
-- until a zone change, a level-up, or the next login.
--
-- The suite asserted the bug was correct: "a mount scan must not rebuild
-- candidate providers".
CN.scanProviders = {
    pets         = { "Pets" },
    achievements = { "Achievements" },
    reputations  = { "Reputations" },
    currencies   = { "Currencies" },
    exploration  = { "Exploration" },
    loremaster   = { "Loremaster" },
    vendors      = { "Vendors" },
    mounts       = { "Mounts" },
    toys         = { "Toys" },
    appearances  = { "Appearances" },
    professions  = { "Professions" },

    -- Recipe names are the left-hand side of the vendor recipe join.
    recipes      = { "Vendors" },
}

-- A scan rewrites a store wholesale, and no client event fires to say so.
-- Recording the scan is the one thing every scan already does, which makes it
-- the right place to tell the candidate caches they are stale.
function CN.MarkScanned(key)
    CN.Account("collectionScans")[key] = time()

    -- A SCAN IS THE LOUDEST THING THAT CHANGES A COLLECTION COUNT. 0.61.0.
    --
    -- `CN.collectionGeneration` guards the memoized `Summary()` calls on the
    -- Collections, Scans and Warband tabs. It was bumped by the eleven CLIENT
    -- events that announce a collection changing -- and not by the addon's
    -- own scans, which are what actually POPULATE the stores those summaries
    -- read.
    --
    -- THROUGH `CN.NoteCollectionChanged`, WHICH ALREADY EXISTS. 0.84.0.
    --
    -- `Scoring.lua` declares that function and calls itself "the one writer",
    -- and this file bumped the same counter inline -- two writers of one
    -- number, which is how they drift. Resolved at call time, and Scoring
    -- loads after this file, so the one writer is the one that runs.
    --
    -- The comment below says "every scan in the addon routes through here...
    -- no scan can be added later that forgets to do it". One already had:
    -- `Quests.ScanKnown` deliberately does NOT call `MarkScanned` -- it
    -- scans nothing collectible -- so the Scans tab, which memoises its rows
    -- against this counter, could never clear the stale mark on the "Quests
    -- known" row. Clicking it froze the client, did real work, and changed
    -- nothing on screen; the Collections tab beside it said "just now" for
    -- the same fact. That scan calls the one writer directly now.
    -- The result was the addon contradicting itself on its own onboarding
    -- screen: a player presses "Scan everything", the stores fill, the "last
    -- read" stamp beside each row updates to "just now" -- because that reads
    -- `Setup.Steps` directly and is not memoized -- and the count beside it
    -- still says "not scanned", until a zone change happens along.
    --
    -- Every scan in the addon routes through here, which is exactly why this
    -- is the right place: one line, and no scan can be added later that
    -- forgets to do it.
    CN.NoteCollectionChanged()

    -- Every scan in the addon already routes through here, so this is where
    -- the setup record learns that a step is done -- rather than only the
    -- eleven-step run knowing, which is what made the login reminder tell
    -- players nothing had been scanned while four subsystems were answering.
    if CN.NoteSetupStep then
        CN.NoteSetupStep(key)
    end

    -- Scoring.lua loads after this file, so these may not exist yet at load
    -- time. They always do by the time a scan can run.
    if not CN.InvalidateProvider then
        return
    end

    local providers = CN.scanProviders[key]

    if not providers then
        return
    end

    -- URGENT, so the provider's cooldown does not hold the scan back.
    --
    -- A scan is something the player asked for, and half the point of the
    -- `urgent` flag is that an explicit request bypasses a throttle written
    -- for background churn. Without it `/cn appearancescan` could leave the
    -- new candidates invisible for ten seconds and the reputation, profession
    -- and toy scans for five -- the same "scanned it and left the cache
    -- holding the old answer" shape this function was written to fix.
    for _, name in ipairs(providers) do
        CN.InvalidateProvider(name, true)
    end

    -- The shortlists are built from the same stores the scan just rewrote,
    -- and they are held behind a revision number that a scan does not move.
    if CN.ClearShortlist then
        CN.ClearShortlist()
    end
end

------------------------------------------------------------
-- SETTINGS AND PROFILES
------------------------------------------------------------

-- Settings are account-wide by default. Any single setting can be overridden
-- per character, because some of them are genuinely character-shaped: a max
-- level main and a levelling alt want different priority modes, and the
-- character you happen to be on should decide that, not the last one you
-- changed it on.
--
-- Overrides are stored SPARSELY -- only what a character has explicitly
-- overridden. That means a new default added in a later release reaches every
-- character, instead of being frozen at whatever the value was when the
-- override was created.
-- HOW BIG IS THIS?
--
-- The client rewrites the entire saved-variables file on every logout and
-- parses it again on every login. Nobody had ever measured what this addon
-- contributes to that, and the answer was over a megabyte at retail scale --
-- a third of which was a copy of the client's own item cache.
--
-- Measured rather than guessed, and reportable, so it cannot quietly grow
-- back.
function CN.MeasureDatabase(value, seen)
    seen = seen or {}

    if type(value) == "table" then
        if seen[value] then
            return 0
        end

        seen[value] = true

        local bytes = 8

        for key, entry in pairs(value) do
            bytes = bytes + CN.MeasureDatabase(key, seen)
                + CN.MeasureDatabase(entry, seen) + 4
        end

        return bytes
    end

    if type(value) == "string" then
        return #value + 2
    end

    if type(value) == "number" then
        return 8
    end

    return 4
end

function CN.DatabaseSizes()
    local rows = {}

    -- THREE BOOKKEEPING KEYS ARE NOT THREE ITEMS.
    --
    -- An inventory store holds one key per item id PLUS `containers`,
    -- `seenAt` and `scannedAt`, which are how the snapshot knows what it
    -- covers and when it was taken. `CN.CountKeys` counted all of them, so a
    -- Warband bank holding nothing at all was reported as three rows -- and
    -- one holding four items as seven, which is the worse error, because it
    -- is wrong by an amount that looks plausible.
    --
    -- `Inventory.Kinds` is the function that already knows the difference,
    -- and this is the second caller it should always have had.
    local inventory = CN:GetModule("Inventory")

    local storeSections = { warbandBank = true, bank = true }

    local function section(label, contents)
        if type(contents) ~= "table" then
            return
        end

        local count

        if storeSections[label] and inventory and inventory.Kinds then
            count = inventory.Kinds(contents)
        else
            count = CN.CountKeys(contents)
        end

        table.insert(rows, {
            name  = label,
            bytes = CN.MeasureDatabase(contents),
            count = count,
        })
    end

    for name, contents in pairs((CN.db and CN.db.account) or {}) do
        section(name, contents)
    end

    section("characters", CN.db and CN.db.characters)

    table.sort(rows, function(a, b) return a.bytes > b.bytes end)

    return rows, CN.MeasureDatabase(CN.db)
end

-- WHAT WAS SET ASIDE, AND WHAT TO DO WITH IT.
--
-- A migration that refuses to destroy data it cannot read leaves that data
-- somewhere, and until 0.57.0 the somewhere was a key nothing in the addon
-- mentioned -- so the refusal was announced once and the data sat in
-- SavedVariables for ever. A rescue with no way to look at it or clear it is
-- a leak with good manners.
CN:RegisterCommand{
    name    = "rescued",
    order   = 93,
    args    = "[discard]",
    help    = "Saved data the addon set aside rather than destroy.",
    handler = function(args)
        args = string.lower(CN.Trim(args or ""))

        local held = CN.db and CN.db.rescuedCharacters

        if held == nil then
            Print("Nothing has been set aside.")
            CN.PrintLine(CN.Muted("This is where saved data the addon could "
                .. "not read would be kept, rather than replaced."))
            return
        end

        if args == "discard" then
            -- `CN.rescuedData` was set here and read nowhere in the tree.
            -- A flag nothing reads is not a flag, it is a note to a reader
            -- that a decision was carried when it was not.
            CN.db.rescuedCharacters = nil

            Print("Discarded. " .. CN.Muted("The addon will stop mentioning "
                .. "it."))
            return
        end

        Print("Your character records were set aside as unreadable.")

        CN.PrintLine("held as: " .. CN.Muted(type(held)))

        if type(held) == "string" then
            CN.PrintLine(CN.Muted(string.sub(held, 1, 120)))
        elseif type(held) == "table" then
            CN.PrintLine(CN.Muted(CN.CountKeys(held) .. " row(s)"))
        end

        CN.PrintLine(CN.Muted("Nothing was destroyed, and nothing else is "
            .. "using it. If it means nothing to you, "
            .. "") .. CN.Accent("/cn rescued discard")
            .. CN.Muted(" removes it."))
    end,
}

CN:RegisterCommand{
    name    = "dbsize",
    aliases = { "storage" },
    order   = 31,
    help    = "How much this addon writes to disk, and where it goes.",
    handler = function()
        local rows, total = CN.DatabaseSizes()

        Print(string.format("Saved data: |cffffc74f%.0f KB|r", total / 1024))
        Print("|cff8a8f96Rewritten in full every time you log out.|r")

        -- DISK IS NOT MEMORY, AND ONLY ONE OF THEM WAS BEING MEASURED.
        --
        -- This command has always reported what the addon writes. What it
        -- costs while running -- the indexes, the caches, the frame pool --
        -- was assumed rather than measured, which is precisely the habit the
        -- rest of this project spends its time correcting.
        if UpdateAddOnMemoryUsage and GetAddOnMemoryUsage then
            local ok = pcall(UpdateAddOnMemoryUsage)

            if ok then
                local gotMemory, kilobytes =
                    pcall(GetAddOnMemoryUsage, "CompletionNavigator")

                if gotMemory and kilobytes then
                    Print(string.format("In memory: |cffffc74f%.0f KB|r",
                        kilobytes))
                    Print("|cff8a8f96Indexes, caches and frames. Freed when "
                        .. "you log out; not written anywhere.|r")
                end
            end
        end

        local shown = 0

        for _, row in ipairs(rows) do
            if row.bytes > 4096 and shown < 12 then
                -- NO COLUMN PADDING. 0.77.0. See `Routing.lua`.
                CN.PrintLine("  " .. CN.Body(row.name) .. "  "
                    .. string.format("%.0f KB", row.bytes / 1024)
                    .. CN.Aside(row.count .. " rows"))

                shown = shown + 1
            end
        end

        if shown == 0 then
            Print("|cff8a8f96Nothing large enough to itemise.|r")
        end
    end,
}

CN.characterOverridable = {
    priorityMode = true,
    autoWaypoint = true,
    arrow        = true,
    tooltips     = true,
    mapPins      = true,
    follow       = true,
}

local function AccountSettings()
    if not CN.db then
        return nil
    end

    CN.db.settings = CN.db.settings or {}

    return CN.db.settings
end

CN.AccountSettings = AccountSettings

local function Overrides(character)
    character = character or CN.character

    if not character then
        return nil
    end

    character.settings = character.settings or {}

    return character.settings
end

CN.SettingOverrides = Overrides

function CN.IsOverridden(key)
    local overrides = Overrides()

    return overrides ~= nil and overrides[key] ~= nil
end

-- Sets a per-character override, or clears it when value is nil.
function CN.SetOverride(key, value)
    if not CN.characterOverridable[key] then
        return false, "That setting is account-wide only."
    end

    local overrides = Overrides()

    if not overrides then
        return false, "No character is loaded yet."
    end

    overrides[key] = value

    return true
end

function CN.ClearOverride(key)
    local overrides = Overrides()

    if overrides then
        overrides[key] = nil
    end

    return true
end

-- The settings table every caller sees.
--
-- A proxy rather than a copy: reads fall through to the account table unless
-- this character has overridden the key, and writes go to whichever level the
-- key already lives at. Copying would have meant every existing call site
-- needing to know which level it was talking to.
local settingsProxy

local function BuildProxy()
    return setmetatable({}, {
        __index = function(_, key)
            local overrides = Overrides()

            if overrides and overrides[key] ~= nil then
                return overrides[key]
            end

            local account = AccountSettings()

            return account and account[key]
        end,

        __newindex = function(_, key, value)
            local overrides = Overrides()

            -- Writing to a key this character has overridden updates the
            -- override. Everything else is account-wide, which is the
            -- behaviour every release before this one had.
            if overrides and overrides[key] ~= nil then
                overrides[key] = value
                return
            end

            local account = AccountSettings()

            if account then
                account[key] = value
            end
        end,

        -- __pairs IS NOT HONOURED BY THE GAME.
        --
        -- It arrived in Lua 5.2. World of Warcraft runs 5.1, so `pairs()` on
        -- this proxy iterates the empty backing table and yields NOTHING --
        -- silently, in game, while the offline suite on 5.4 walked a
        -- correctly merged view and agreed the code was fine.
        --
        -- Kept, because it is right where it is honoured and costs nothing
        -- where it is not. But nothing may DEPEND on it: use CN.AllSettings()
        -- below, which works everywhere.
        __pairs = function()
            return next, CN.AllSettings(), nil
        end,
    })
end

-- The merged settings as a plain table: account values with this character's
-- overrides on top.
--
-- A real function rather than a metamethod, because the game's Lua does not
-- support the metamethod and a facility that works in testing and not in
-- production is worse than no facility at all.
function CN.AllSettings()
    local merged = {}

    for key, value in pairs(AccountSettings() or {}) do
        merged[key] = value
    end

    for key, value in pairs(Overrides() or {}) do
        merged[key] = value
    end

    return merged
end

function CN.Settings()
    if not CN.db then
        return nil
    end

    AccountSettings()

    settingsProxy = settingsProxy or BuildProxy()

    return settingsProxy
end
