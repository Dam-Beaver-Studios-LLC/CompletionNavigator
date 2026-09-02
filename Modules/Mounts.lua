-- Modules/Mounts.lua
-- Completion Navigator :: mount collection.
--
-- Mounts are account-wide, but a mount can be faction-locked or hidden on
-- the current character. Both matter for "which character should get this",
-- so both are recorded rather than filtered away at scan time.

local ADDON_NAME, CN = ...

local Mounts = CN:RegisterModule("Mounts")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

------------------------------------------------------------
-- STORAGE
------------------------------------------------------------

local function Store()
    return CN.Account("mounts")
end

Mounts.Store = Store

------------------------------------------------------------
-- SCAN
------------------------------------------------------------

function Mounts.Scan()
    if not C_MountJournal then
        return 0, 0, 0
    end

    local store = Store()

    local seen, collected, missing = 0, 0, 0

    for _, mountID in ipairs(Blizzard.GetMountIDs()) do
        local mount = Blizzard.GetMountByID(mountID)

        if mount then
            store[mountID] = {
                mountID           = mountID,

                -- `name` IS NOT STORED. 0.63.0.
                --
                -- Around nine hundred localized names the journal returns
                -- instantly, in the language the player is reading. Stored,
                -- they froze: a player who changed client language could not
                -- find their own mounts with `/cn mount <name>` and the row
                -- printed the old locale's name. 0.62.0 dropped `source` from
                -- these same rows on the same rule and left the name.
                --
                -- `Mounts.NameOf` below is the one reader, matching
                -- `Pets.NameOf` and `Achievements.NameOf`.
                -- `spellID` IS NOT STORED. 0.98.0.
                --
                -- Nothing in the tree has ever read a mount record's
                -- `spellID`: a grep finds this write and nothing else. Nine
                -- hundred integers plus their hash slots, serialised at every
                -- logout and parsed again at every login, for a value
                -- `GetMountInfoByID` hands back instantly.
                --
                -- The three comments immediately below explain what this scan
                -- deliberately does not store, and were written with this
                -- line directly above them. Migrations 4, 5, 14, 15, 16, 31
                -- and 32 swept this store for names and for timestamps; none
                -- of them asked about the ids.
                sourceType        = mount.sourceType,

                -- `source` IS NOT STORED ANY MORE. 0.62.0.
                --
                -- It is the journal's multi-line LOCALIZED source prose, for
                -- around nine hundred rows -- by far the largest thing this
                -- addon still wrote to disk that the client hands back
                -- instantly from `GetMountInfoExtraByID`. Migrations 4, 5 and
                -- 14 stripped item names, achievement names and points, pet
                -- names and harvest zones on exactly this rule.
                --
                -- Nothing needs it stored now that ranking reads the numeric
                -- `sourceType`: the two places that DISPLAY it read it live,
                -- through `Mounts.SourceText` below.
                isFactionSpecific = mount.isFactionSpecific,
                faction           = mount.faction,
                collected         = mount.isCollected,

                -- NO TIMESTAMPS. 0.82.0.
                --
                -- Nothing has ever read a mount record's `firstSeen` or
                -- `lastSeen`. Migration 5 stripped exactly these two fields
                -- from `pets` and `toys` for exactly this reason, and
                -- migration 31 caught `appearances` under a header naming
                -- itself "THE STORE MIGRATION 5 MISSED". `mounts` is the
                -- largest of the four and was missed by both -- two fresh
                -- integers on roughly nine hundred rows, written at every
                -- login and serialized at every logout.
            }

            seen = seen + 1

            if mount.isCollected then
                collected = collected + 1
            else
                missing = missing + 1
            end
        end
    end

    -- ZERO IS THE CLIENT DECLINING, NOT AN EMPTY collection. 0.95.0.
    --
    -- `CN.MarkScanned` routes to `CN.NoteSetupStep`, so stamping it removes
    -- mounts from `Setup.NeverScanned` for ever: the new player is never told to
    -- run `/cn mountscan`, and the Scans tab reads "just now" over a read that returned
    -- nothing. Same shape as toys next door; see the note there.

    if seen == 0 then
        return 0, 0, 0
    end

    CN.MarkScanned("mounts")

    return seen, collected, missing
end

------------------------------------------------------------
-- CANDIDATES
------------------------------------------------------------

-- Only mounts with a KNOWN SOURCE become recommendations.
--
-- Retail has roughly 900 mounts and most players are missing hundreds. An
-- objective that says "collect this mount" and nothing else is not a next
-- action, it is a list -- and /cn breakdown and the Collections tab already
-- read the store directly for that. What makes a mount actionable is the
-- journal's source text: "Vendor: X", "Quest: Y", "Drop: Z".
-- WHERE A MOUNT COMES FROM, AS A NUMBER. 0.62.0.
--
-- `C_MountJournal.GetMountInfoByID` returns a numeric `sourceType` alongside
-- the localized source sentence, and the addon has been storing it, unused,
-- since it started reading mounts. These are the client's own values; an enum
-- is the same number in every language, which the sentence is not.
--
-- Unknown values rank as "we do not know", not as "worthless" -- a source the
-- client adds in a future patch must not be silently buried.
Mounts.sourceTypes = {
    [0]  = "UNKNOWN",
    [1]  = "DROP",
    [2]  = "QUEST",
    [3]  = "VENDOR",
    [4]  = "PROFESSION",
    [5]  = "PET_STORE",
    [6]  = "ACHIEVEMENT",
    [7]  = "WORLD_EVENT",
    [8]  = "PROMOTION",
    [9]  = "TCG",
    [10] = "BLACK_MARKET",
    [11] = "TRADING_POST",
    [12] = "DISCOVERY",
}

-- Something you can walk up to and buy or complete beats something with a
-- drop chance, which beats everything else.
Mounts.sourceValues = {
    VENDOR      = 3,
    QUEST       = 3,
    ACHIEVEMENT = 3,
    PROFESSION  = 3,
    WORLD_EVENT = 3,
    DROP        = 2,
    DISCOVERY   = 2,
}

function Mounts.SourceValue(record)
    local kind = record and Mounts.sourceTypes[record.sourceType]

    if kind then
        return Mounts.sourceValues[kind] or 1
    end

    -- THE PRE-0.62.0 FALLBACK COULD NEVER RUN. 0.82.0.
    --
    -- This matched English words in `record.source` and was justified by
    -- "databases from before 0.62.0 carry the sentence and no type... the old
    -- English match is better than nothing FOR THOSE ROWS". Migration 15 sets
    -- `record.source = nil` on every row of `db.account.mounts`, and
    -- migrations run on ADDON_LOADED -- strictly before any scan or rebuild.
    -- So the branch was unreachable on every client, always, and the promise
    -- it made to upgrading players could not be kept by construction.
    --
    -- It was also a localized string being BRANCHED on, which this project
    -- forbids outright.
    return 1
end

-- A mount's name, from the client.
--
-- The `record` argument is kept for the call sites that pass one; the stored
-- fallback it used to consult was deleted from every row by migration 16, so
-- reading it was reading nil. 0.82.0.
function Mounts.NameOf(mountID)
    local live = CN.Blizzard.GetMountByID and CN.Blizzard.GetMountByID(mountID)

    if live and live.name and live.name ~= "" then
        return live.name
    end

    return "Mount " .. tostring(mountID)
end

-- The journal's source sentence, live. See the note in `Scan`.
--
-- No stored fallback: migration 15 removed `source` from every row, so the
-- one this used to read was always nil. 0.82.0.
function Mounts.SourceText(mountID)
    local live = CN.Blizzard.GetMountByID and CN.Blizzard.GetMountByID(mountID)

    if live and live.source and live.source ~= "" then
        return live.source
    end

    return nil
end

CN.RegisterCandidateProvider("Mounts", function()
    local playerFaction = UnitFactionGroup and UnitFactionGroup("player") or nil

    local candidates, considered, dropped = CN.CollectBounded(Store(), nil,
        function(mountID, record)
            if record.collected then
                return nil
            end

            -- A mount locked to the other faction cannot be earned on this
            -- account's characters of this faction; saying "go get it" is
            -- worse than silence.
            if record.isFactionSpecific and record.faction and playerFaction then
                local wanted = (record.faction == 0) and "Horde" or "Alliance"

                if wanted ~= playerFaction then
                    return nil
                end
            end

            -- SOMETHING KNOWN ABOUT WHERE IT COMES FROM, IN ANY FORM.
            --
            -- This required the localized `source` sentence to be non-empty,
            -- which is the same locale trap as the ranking below: a client
            -- that returns a source TYPE and an empty prose line -- which
            -- happens -- had every one of its mounts dropped from the list.
            if (record.sourceType == nil or record.sourceType == 0)
                and not Mounts.SourceText(mountID) then

                return nil
            end

            if CN.IsIgnored(CN.objectiveTypes.MOUNT, mountID)
                or CN.IsDeferred(CN.objectiveTypes.MOUNT, mountID) then
                return nil
            end

            -- THE NUMBER, NOT THE SENTENCE. FIXED IN 0.62.0.
            --
            -- This ranked mounts by searching the journal's `sourceText` for
            -- the English words "vendor", "quest" and "drop". That string is
            -- LOCALIZED -- "HÃ¤ndler:", "QuÃªte :", "BotÃ­n:" -- so on every
            -- non-English client every uncollected mount fell through to 1,
            -- and a vendor mount two zones away ranked identically to a
            -- one-per-cent raid drop. `/cn next` stopped preferring the
            -- actionable one for roughly half the player base.
            --
            -- The client hands over a numeric `sourceType` from the same call
            -- and the addon has been STORING it, unused, since it started
            -- reading mounts. An enum is the same number in every locale.
            return Mounts.SourceValue(record)
        end,
        function(mountID, record, value)
            return CN.NewObjective({
                id              = mountID,
                type            = CN.objectiveTypes.MOUNT,
                name            = Mounts.NameOf(mountID, record),
                accountWide     = true,
                completionValue = value,
                reasons         = { Mounts.SourceText(mountID, record)
                    or "the journal does not say where this comes from" },
            })
        end)

    CN.providerTruncation["Mounts"] = { considered = considered, dropped = dropped }

    return candidates
end, { events = { "NEW_MOUNT_ADDED" } })

------------------------------------------------------------
-- ELIGIBILITY
------------------------------------------------------------

-- faction is 0 for Horde and 1 for Alliance in the mount journal.
--
-- THIS TABLE IS A TOKEN MAP AND IS USED AS ONE. It is compared against
-- `character.faction`, which is stored in the same English tokens, and that
-- comparison is correct. What is NOT correct is printing the token: 0.64.0
-- gave the Warband roster `CN.FactionLabel`, backed by the client's own
-- `FACTION_ALLIANCE` / `FACTION_HORDE` globals, and this file -- the other
-- place a faction reaches the player -- was not converted. A German player
-- read "Faction: Alliance" beside "Sammelbar: nein". 0.66.0.
local FACTION_NAMES = { [0] = "Horde", [1] = "Alliance" }

-- Published, so the tooltip does not build a second copy of the mapping.
-- Returns the client's own word for the faction, not the token.
function Mounts.FactionOf(record)
    local token = record and record.faction and FACTION_NAMES[record.faction]

    return token and CN.FactionLabel(token) or nil
end

function Mounts.IsUsableByCharacter(record, character)
    if not record.isFactionSpecific then
        return true
    end

    character = character or CN.character

    if not character or not character.faction then
        return true
    end

    return FACTION_NAMES[record.faction] == character.faction
end

CN.RegisterEligibilityChecker(CN.objectiveTypes.MOUNT, function(mountID)
    local states = CN.objectiveStates
    local record = Store()[mountID]

    if not record then
        return states.UNKNOWN, "No mount data; run /cn mountscan", nil
    end

    if record.collected then
        return states.COMPLETED, "Already collected", Mounts.NameOf(mountID, record)
    end

    if not Mounts.IsUsableByCharacter(record) then
        local token = FACTION_NAMES[record.faction]

        return states.REQUIRES_OTHER_CHARACTER,
               CN.blockReasons.WRONG_FACTION,
               token and CN.FactionLabel(token) or "the other faction"
    end

    return states.AVAILABLE, nil, nil
end)

------------------------------------------------------------
-- SUMMARY
------------------------------------------------------------

function Mounts.Summary()
    local counts = {
        known        = 0,
        collected    = 0,
        missing      = 0,
        wrongFaction = 0,
    }

    for _, record in pairs(Store()) do
        counts.known = counts.known + 1

        if record.collected then
            counts.collected = counts.collected + 1
        else
            counts.missing = counts.missing + 1

            if not Mounts.IsUsableByCharacter(record) then
                counts.wrongFaction = counts.wrongFaction + 1
            end
        end
    end

    return counts
end

------------------------------------------------------------
-- LOOKUP
------------------------------------------------------------

function Mounts.Resolve(text)
    local mountID = CN.ToID(text)

    if mountID and Store()[mountID] then
        return mountID
    end

    if not text or text == "" then
        return nil
    end

    local needle  = string.lower(text)
    local matches = {}

    for id, record in pairs(Store()) do
        local heldName = Mounts.NameOf(id, record)

        if heldName and string.find(string.lower(heldName), needle, 1, true) then
            table.insert(matches, { id = id, name = heldName })
        end
    end

    if #matches == 0 then
        return nil
    end

    table.sort(matches, function(a, b) return #a.name < #b.name end)

    return matches[1].id, matches
end

------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

CN:RegisterEvent("NEW_MOUNT_ADDED", function()
    Mounts.Scan()
    DebugPrint("Mount added; journal rescanned.")
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "mountscan",
    order   = 53,
    help    = "Scan the mount journal.",
    handler = function()
        local seen, collected, missing = Mounts.Scan()

        Print("Scanned " .. seen .. " mounts.")
        Print("Collected: " .. collected .. " " .. CN.DOT
            .. " Missing: " .. missing)
    end,
}

CN:RegisterCommand{
    name    = "mounts",
    order   = 54,
    help    = "Summarize mount collection.",
    handler = function()
        local counts = Mounts.Summary()

        if counts.known == 0 then
            Print("No mount data yet. Run /cn mountscan.")
            return
        end

        Print("Mounts known to the journal: " .. counts.known)
        Print("Collected: " .. counts.collected .. " " .. CN.DOT
            .. " Missing: " .. counts.missing)

        if counts.wrongFaction > 0 then
            Print("Missing and locked to the other faction: " .. counts.wrongFaction)
        end
    end,
}

CN:RegisterCommand{
    name    = "mount",
    args    = "<mountID or name>",
    order   = 55,
    help    = "Show one mount's collection state.",
    handler = function(args)
        if args == "" then
            Print("Usage: /cn mount <mountID or name>")
            return
        end

        local mountID = Mounts.Resolve(args)

        if not mountID then
            Print("No known mount matches: " .. args)
            return
        end

        local record = Store()[mountID]

        Print(Mounts.NameOf(mountID, record)
            .. " |cff8a8f96(" .. mountID .. ")|r")
        Print("Collected: " .. CN.YesNo(record.collected))

        local sourceText = Mounts.SourceText(mountID, record)

        if sourceText and sourceText ~= "" then
            Print("Source: " .. CN.Strip(sourceText))
        end

        if record.isFactionSpecific then
            local token = FACTION_NAMES[record.faction]

            Print("Faction: " .. (token and CN.FactionLabel(token) or "unknown")
                .. (Mounts.IsUsableByCharacter(record) and "" or " |cffe2564c(not this character)|r"))
        end
    end,
}

-- AND ONCE AT LOGIN. 0.62.0.
--
-- This store relied entirely on `NEW_MOUNT_ADDED`, which covers
-- collections made while this session is running and nothing collected in a
-- session where the addon was not loaded. The store is persisted account-wide,
-- so a player who turns addons off for a raid night, collects three, and turns
-- them back on is recommended things they already own until they happen to run
-- the scan by hand.
--
-- `Appearances.lua` made exactly this argument in 0.58.0 and the same argument
-- applies verbatim here; three stores were left behind.
--
-- Guarded and quiet: this is a journal walk, and a client that refuses it must
-- not take the login sequence with it.
CN:OnLogin(function()
    CN.Guard("Mounts.Scan", Mounts.Scan)
end)
