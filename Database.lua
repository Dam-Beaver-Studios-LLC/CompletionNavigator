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
                        or { seen = 1, characters = { ["migrated"] = true } }
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
                CN.PrintLine(string.format("  %-20s %6.0f KB  |cff8a8f96%d rows|r",
                    row.name, row.bytes / 1024, row.count))

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
