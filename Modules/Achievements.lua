-- Modules/Achievements.lua
-- Completion Navigator :: achievements and their criteria.
--
-- Achievements are account-wide in retail, so completion lives in account
-- storage. Only incomplete achievements are stored in detail: keeping a row
-- for all ~3000 completed ones would triple the SavedVariables file to say
-- something the client can answer instantly.
--
-- The useful signal here is *near-completion*: an achievement sitting at
-- 9 of 10 criteria is worth far more attention than one at 0 of 10, and
-- nothing else in the addon surfaces that.

local ADDON_NAME, CN = ...

local Achievements = CN:RegisterModule("Achievements")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

-- An achievement's name, from the client, falling back to whatever an older
-- database still carries.
--
-- Names and point values used to be stored for every tracked achievement --
-- 394 KB at retail scale, in a file the game rewrites on every logout, and
-- every byte of it re-derivable from `GetAchievementInfo` in microseconds.
local function NameOf(achievementID, record)
    local live = CN.Blizzard.GetAchievementName(achievementID)

    if live then
        return live
    end

    return (record and record.name) or ("Achievement " .. tostring(achievementID))
end

local function Store()
    return CN.Account("achievements")
end

Achievements.Store  = Store
Achievements.NameOf = NameOf

-- CRITERIA PROGRESS IS THE CHARACTER'S; THE EARNED FLAG IS THE ACCOUNT'S.
-- 0.74.0.
--
-- The third and last store with this defect. `Loremaster` was split in
-- 0.61.0 and `Exploration` in 0.64.0, each with a paragraph explaining that a
-- criterion counted by questing or killing is counted per character while the
-- achievement itself is earned account-wide. This file was written the same
-- way and never revisited, so `record.done` held whichever character scanned
-- last.
--
-- What that does to a player: `IsNearlyDone` drives the shortlist, which
-- drives `/cn next`. An alt at 2 of 40 inherited the main's 38 of 40, was
-- told it was two criteria from finishing something it had barely started,
-- and was sent across the world to do it.
--
-- Same shape as the two siblings: `progress` keyed by character, with the
-- flat field kept as the current character's value so an older database still
-- reads correctly and nothing downstream had to change.
function Achievements.DoneFor(record, characterKey)
    if type(record) ~= "table" then
        return 0
    end

    characterKey = characterKey or CN.characterKey or CN.GetCharacterKey()

    if record.progress and record.progress[characterKey] ~= nil then
        return record.progress[characterKey]
    end

    -- Only the CURRENT character may fall back to the flat field: it holds
    -- whoever scanned last, which is the defect, and attributing it to a
    -- named other character would tell the same lie somewhere new.
    if characterKey == (CN.characterKey or CN.GetCharacterKey()) then
        return record.done or 0
    end

    return nil
end

-- THE ONE WRITER, so the scan and the criteria sweep cannot record progress
-- differently, and so both file it under the character it belongs to.
function Achievements.NoteProgress(record, done)
    if type(record) ~= "table" or done == nil then
        return
    end

    local key = CN.characterKey or CN.GetCharacterKey()

    record.progress = record.progress or {}
    record.progress[key] = done

    -- `record.done` IS NOT WRITTEN. 0.75.0.
    --
    -- 0.74.0 introduced this function to split the store per character and
    -- then wrote the flat field anyway, which is the field `DoneFor` falls
    -- back to for a character that has no reading of its own -- so the split
    -- existed and changed nothing. `Loremaster` stopped writing it in 0.66.0
    -- and `Exploration` carries a paragraph on why.
end

-- Bumped whenever the store is rewritten, so the candidate provider knows
-- when its shortlist is stale. See CN.Shortlist.
Achievements.revision = 0

-- Within two criteria of finished. Everything else is a project rather than
-- a next action, and there are three thousand of them.
Achievements.nearlyDoneThreshold = 2

local function IsNearlyDone(record)
    local criteria = record and record.criteria or 0

    if criteria <= 0 then
        return false
    end

    local remaining = criteria - (Achievements.DoneFor(record) or 0)

    return remaining > 0 and remaining <= Achievements.nearlyDoneThreshold
end

Achievements.IsNearlyDone = IsNearlyDone

-- The shortlist: only the rows a provider could possibly use.
function Achievements.Shortlist()
    return CN.Shortlist("Achievements", Achievements.revision, function()
        local list = {}

        for achievementID, record in pairs(Store()) do
            if IsNearlyDone(record) then
                table.insert(list, { id = achievementID, record = record })
            end
        end

        -- Deterministic order, so the cut is stable between rebuilds.
        table.sort(list, function(a, b) return a.id < b.id end)

        return list
    end)
end

------------------------------------------------------------
-- SCAN
------------------------------------------------------------

-- Walking every category is a few thousand calls. That is fine on demand,
-- but it must never run on a frequent event.
function Achievements.Scan()
    if not GetCategoryList then
        return 0, 0, 0
    end

    local store = Store()

    -- NOT WIPED ANY MORE. 0.75.0.
    --
    -- `Wipe` emptied the ACCOUNT store and refilled it from the character
    -- running the scan, so every other character's criteria readings were
    -- destroyed on every `/cn achievescan` -- which is the whole thing the
    -- per-character split added in 0.74.0 exists to keep. The split was
    -- inert: the scan never called its writer, and the writer wrote the flat
    -- field the split was meant to retire.
    --
    -- Rows the client no longer returns are dropped explicitly below instead,
    -- which is what the wipe was actually for.
    local seen = {}

    -- How many rows the criteria API actually answered about. See the guard
    -- below: a scan that answered for nothing must not prune, stamp, or
    -- record itself.
    local answered = 0

    -- Which categories the client actually populated this time.
    local answeringCategories = {}

    Achievements.revision = Achievements.revision + 1

    local scanned, completed, nearlyDone = 0, 0, 0

    for _, categoryID in ipairs(Blizzard.GetAchievementCategories()) do
        local total = Blizzard.GetCategoryCounts(categoryID)

        -- `achievementTotals` IS NOT WRITTEN ANY MORE. 0.64.0.
        --
        -- A per-category snapshot of numbers `GetAchievementTotals` answers
        -- in one call, persisted, re-parsed at every login, rewritten at
        -- every logout -- and read by nothing at all. `Achievements.Summary`
        -- takes its totals live; the only other reference in the tree is the
        -- field-stripper in a migration.
        --
        -- The same class migrations 4, 5, 14, 15 and 16 exist to remove.

        for index = 1, total do
            local achievement = Blizzard.GetAchievementInCategory(categoryID, index)

            if achievement then
                scanned = scanned + 1

                -- REACHED, NOT STORED. 0.76.0.
                --
                -- 0.75.0 marked a row seen only inside the branch that
                -- stored it -- and that branch is gated on THIS character's
                -- progress. So on an alt, every achievement the main had
                -- progress on and the alt did not was neither stored nor
                -- marked, and the prune below deleted the row, taking the
                -- main's readings with it.
                --
                -- `/cn achievescan` on a fresh alt therefore destroyed the
                -- main's criteria data for nearly every achievement: exactly
                -- the loss 0.75.0 removed the store wipe to prevent, brought
                -- straight back as a character-relative prune.
                --
                -- The prune's job is to drop what the GAME no longer returns.
                -- That is what this records.
                seen[achievement.achievementID] = true

                -- AND WHICH CATEGORY ANSWERED. See the prune below: the walk
                -- is per category and 0.76.0 gated the prune on a whole-store
                -- counter, so one expansion answering licensed the deletion
                -- of every row in the ones that did not.
                answeringCategories[categoryID] = true

                if achievement.completed then
                    completed = completed + 1
                else
                    local done, criteria =
                        Blizzard.GetAchievementProgress(achievement.achievementID)

                    -- Store only what is unfinished, and only if there is
                    -- real progress or it is small enough to be actionable.
                    if criteria == 0 or done > 0 then
                        -- THROUGH THE ONE WRITER, AND ON TOP OF WHAT IS
                        -- ALREADY THERE. 0.75.0.
                        --
                        -- This built a fresh table literal, so it never
                        -- created a `progress` entry at all -- the split
                        -- added in 0.74.0 had no writer -- and it discarded
                        -- every other character's reading in the same
                        -- statement.
                        local held = store[achievement.achievementID] or {}

                        held.achievementID = achievement.achievementID
                        held.categoryID    = categoryID

                        -- NOT OVER GOOD DATA WITH NOTHING. 0.76.0.
                        --
                        -- `GetAchievementProgress` answers `0, 0` when the
                        -- criteria API is unavailable, which is routine for a
                        -- window after logging in -- and `/cn setup`, by this
                        -- addon's own note, is most often run exactly then.
                        -- This wrote the refusal straight in: a stored 40
                        -- became 0, `IsNearlyDone` went false, and the row
                        -- left the shortlist.
                        --
                        -- The guard `Exploration` has carried since 0.61.0,
                        -- `Loremaster` since 0.71.0, and that this file's own
                        -- criteria sweep four hundred lines down already had.
                        -- Third writer, no guard.
                        if criteria > 0 then
                            held.criteria = criteria

                            Achievements.NoteProgress(held, done)

                            answered = answered + 1
                        elseif held.criteria == nil then
                            -- Genuinely a criteria-less achievement, and new
                            -- to the store. A stored `criteria > 0` is never
                            -- overwritten with a refusal.
                            held.criteria = 0

                            Achievements.NoteProgress(held, done)
                        end

                        store[achievement.achievementID] = held

                        -- THROUGH THE ONE RULE. 0.62.0.
                        --
                        -- This and `Summary` each hardcoded
                        -- `done >= criteria - 2`, neither guarded
                        -- `remaining > 0`, and `IsNearlyDone` -- the rule the
                        -- provider actually uses -- reads a published
                        -- threshold field. Three copies, one of them
                        -- authoritative: changing the threshold silently
                        -- desynchronised what `/cn achievescan` and
                        -- `/cn achievements` report from the shortlist the
                        -- addon works off, and both counted finished
                        -- achievements as nearly finished.
                        if IsNearlyDone(held) then
                            nearlyDone = nearlyDone + 1
                        end
                    end
                end
            end
        end
    end

    -- AND A SCAN THE CLIENT WOULD NOT ANSWER FOR CHANGES NOTHING. 0.76.0.
    --
    -- Pruning, stamping and recording all follow from having read something.
    -- A cold scan that read nothing would otherwise delete every row it could
    -- not confirm, mark itself done, and silence the reminder that would have
    -- sent the player back.
    if answered == 0 then
        DebugPrint("Achievement scan answered for nothing; not recording it.")

        return scanned, completed, nearlyDone, 0
    end

    -- ROWS THE CLIENT NO LONGER RETURNS, dropped explicitly. This is what the
    -- wipe at the top used to accomplish, without taking every other
    -- character's readings with it.
    -- PER CATEGORY, NOT PER SCAN. Corrected in 0.77.0; see the sibling in
    -- `Modules/Loremaster.lua` for the whole argument. A row whose category
    -- did not answer is not a row the game has stopped returning -- it is a
    -- row nobody asked about -- and a row with no stored category has nothing
    -- to check against.
    for achievementID, record in pairs(store) do
        local categoryID = type(record) == "table" and record.categoryID

        if not seen[achievementID] and categoryID
            and answeringCategories[categoryID] then

            store[achievementID] = nil
        end
    end

    -- AND THE SCAN IS RECORDED PER CHARACTER. 0.75.0.
    --
    -- `CN.MarkScanned` is account-wide, and `Setup.HasRun` reads account-wide
    -- stamps -- so an alt that had never scanned was never prompted to, and
    -- silently read whatever the main's scan had left. `Loremaster` records
    -- who scanned, for exactly this reason; this is that.
    CN.Account("achievementScans")[CN.characterKey or CN.GetCharacterKey()] =
        time()

    CN.MarkScanned("achievements")

    return scanned, completed, nearlyDone, answered
end

-- Whether THIS character has ever read its own criteria progress.
function Achievements.HasScanned(characterKey)
    characterKey = characterKey or CN.characterKey or CN.GetCharacterKey()

    return CN.Account("achievementScans")[characterKey] ~= nil
end

------------------------------------------------------------
-- SUMMARY
------------------------------------------------------------

function Achievements.Summary()
    local total, completed = Blizzard.GetAchievementTotals()

    local counts = {
        total       = total,
        completed   = completed,
        inProgress  = 0,
        nearlyDone  = 0,
    }

    -- `pointsLeft` REMOVED. `record.points` has been nil since 0.36.0 --
    -- migration 5 stripped it as something the client re-supplies -- so this
    -- summed to zero on every client, permanently. Two other readers of the
    -- same field were fixed at the time and this one was missed. Nothing
    -- displayed it, so it was dead state rather than a wrong number on
    -- screen; it is gone rather than revived, because a points total the
    -- addon would have to rebuild from the client is a question the
    -- Achievements panel already answers.
    for _, record in pairs(Store()) do
        counts.inProgress = counts.inProgress + 1

        -- The same one rule. See the note in `Scan`.
        if IsNearlyDone(record) then
            counts.nearlyDone = counts.nearlyDone + 1
        end
    end

    return counts
end

-- Incomplete achievements sorted by how close they are to finishing.
function Achievements.Closest(limit)
    local rows = {}

    -- THE NAME WENT ON THE RECORD, AND THE RECORD IS ON DISK. FIXED 0.61.0.
    --
    -- `record` here is the live SavedVariables row -- `Store()` hands back
    -- the saved table itself, not a copy -- so writing `resolvedName` onto it
    -- persisted a client-supplied achievement name into the player's
    -- database, permanently, for every achievement this function ever
    -- touched. 0.36.0 deliberately STOPPED storing achievement names for
    -- exactly this reason, and this line quietly put them back one `/cn
    -- closest` at a time.
    --
    -- Both callers resolve the name themselves anyway. The only thing that
    -- ever read `resolvedName` was the comparator two lines below, so the
    -- names live in a local for the length of the sort and are then gone.
    --
    -- The addon's standing rule, restated: persist only what the client
    -- cannot re-supply. A name it hands over instantly is the clearest case
    -- there is.
    local names = {}

    -- AND THE REMAINDER, HOISTED OUT OF THE COMPARATOR. 0.75.0.
    --
    -- 0.74.0 routed "every reader of `record.done`" through `DoneFor` and
    -- missed this one, so the list was ORDERED by whichever character scanned
    -- last while each row DISPLAYED this character's own figure -- `/cn
    -- closest` printing "3 / 40" above "38 / 40" under the heading "closest
    -- to completion". Computed once per row here rather than O(n log n) times
    -- inside the sort.
    local left = {}

    for achievementID, record in pairs(Store()) do
        local done = Achievements.DoneFor(record) or 0

        if record.criteria and record.criteria > 0 and done > 0 then
            names[record] = NameOf(achievementID, record) or ""
            left[record]  = record.criteria - done

            table.insert(rows, record)
        end
    end

    table.sort(rows, function(a, b)
        local aLeft = left[a] or 0
        local bLeft = left[b] or 0

        if aLeft == bLeft then
            return (names[a] or "") < (names[b] or "")
        end

        return aLeft < bLeft
    end)

    local results = {}

    for index = 1, math.min(limit or 10, #rows) do
        table.insert(results, rows[index])
    end

    return results
end

function Achievements.Resolve(text)
    local achievementID = CN.ToID(text)

    if achievementID then
        return achievementID
    end

    if not text or text == "" then
        return nil
    end

    local needle  = string.lower(text)
    local matches = {}

    for id, record in pairs(Store()) do
        local name = NameOf(id, record)

        if name and string.find(string.lower(name), needle, 1, true) then
            table.insert(matches, { id = id, name = name })
        end
    end

    if #matches == 0 then
        return nil
    end

    table.sort(matches, function(a, b) return #a.name < #b.name end)

    return matches[1].id
end

------------------------------------------------------------
-- ELIGIBILITY
------------------------------------------------------------

CN.RegisterEligibilityChecker(CN.objectiveTypes.ACHIEVEMENT, function(achievementID)
    local states = CN.objectiveStates
    local record = Store()[achievementID]

    if not record then
        -- Absent from the incomplete store means either completed or never
        -- scanned. Ask the client rather than guessing.
        local info = GetAchievementInfo and select(4, GetAchievementInfo(achievementID))

        if info then
            return states.COMPLETED, "Already earned", nil
        end

        return states.UNKNOWN, "No achievement data; run /cn achievescan", nil
    end

    return states.AVAILABLE, nil, nil
end)

------------------------------------------------------------
-- CANDIDATES
------------------------------------------------------------

-- Only near-complete achievements become candidates. A zero-progress
-- achievement is a project, not a next action, and flooding the
-- recommendation list with thousands of them would bury everything else.
-- The criteria line always; the points line only when the client will say.
local function PointReasons(achievementID, remaining, criteria)
    local reasons = {
        remaining .. " of " .. criteria .. " criteria left",
    }

    local points = Blizzard.GetAchievementPoints
        and Blizzard.GetAchievementPoints(achievementID)

    if type(points) == "number" and points > 0 then
        table.insert(reasons, points .. " achievement points")
    end

    return reasons
end

CN.RegisterCandidateProvider("Achievements", function()
    -- Iterates the shortlist, not the store. At retail scale that is a dozen
    -- rows instead of three thousand, and the three thousand were being
    -- rejected identically on every single rebuild.
    local shortlist = {}

    for _, entry in ipairs(Achievements.Shortlist()) do
        shortlist[entry.id] = entry.record
    end

    local candidates, considered, dropped = CN.CollectBounded(shortlist, nil,
        function(achievementID, record)
            local criteria = record.criteria or 0

            if criteria <= 0 then
                return nil
            end

            local remaining = criteria - (Achievements.DoneFor(record) or 0)

            -- A zero-progress achievement is a project, not a next action.
            if remaining <= 0 or remaining > Achievements.nearlyDoneThreshold then
                return nil
            end

            if CN.IsIgnored(CN.objectiveTypes.ACHIEVEMENT, achievementID)
                or CN.IsDeferred(CN.objectiveTypes.ACHIEVEMENT, achievementID) then
                return nil
            end

            return 3 - remaining
        end,
        function(achievementID, record, value)
            local remaining = (record.criteria or 0)
                - (Achievements.DoneFor(record) or 0)

            return CN.NewObjective({
                id              = achievementID,
                type            = CN.objectiveTypes.ACHIEVEMENT,
                name            = NameOf(achievementID, record),
                accountWide     = true,
                completionValue = value,
                -- POINTS ARE READ LIVE, OR NOT MENTIONED.
                --
                -- `record.points` has been nil since 0.36.0 stopped storing
                -- it -- this file says so in a comment a hundred lines below,
                -- where two other readers were fixed. This one was missed,
                -- and `or 0` turned an absent number into a confident false
                -- statement: every near-complete achievement in the addon has
                -- been reporting "0 achievement points".
                --
                -- Silence beats a wrong number. That is the same rule this
                -- addon applies to every denominator it cannot vouch for.
                reasons         = PointReasons(achievementID, remaining,
                    record.criteria),
            })
        end)

    CN.providerTruncation["Achievements"] = { considered = considered, dropped = dropped }

    return candidates
end, { events = { "ACHIEVEMENT_EARNED", "CRITERIA_UPDATE" }, cooldown = 5 })

------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

CN:RegisterEvent("ACHIEVEMENT_EARNED", function(event, achievementID)
    if achievementID then
        Store()[achievementID] = nil

        -- THE SHORTLIST HOLDS THE ROW THE STORE JUST RELEASED.
        --
        -- `CN.Shortlist` returns its held list whenever the revision matches,
        -- and the revision moved only on a full scan or when a criteria tick
        -- crossed the nearly-done boundary. Deleting the store row without
        -- moving it left the shortlist holding a strong reference to an
        -- orphaned record -- so ACHIEVEMENT_EARNED invalidated the provider,
        -- the provider rebuilt, asked for the shortlist, got the cached one
        -- back, and emitted the achievement the player had just earned as a
        -- candidate again. It stayed at the top of `/cn next` until something
        -- unrelated moved the revision.
        Achievements.revision = Achievements.revision + 1

        DebugPrint("Achievement earned: " .. tostring(achievementID))
    end
end)

-- Criteria updates fire constantly during play. Refresh the tracked rows
-- rather than rescanning thousands of achievements, and throttle even that.

-- Published rather than a literal, so the throttle is a knob the suite can
-- turn. A guard nothing can reach is a guard nothing tests.
Achievements.criteriaSweepSeconds = 5

-- THROUGH `CN.Debounce`, LIKE BOTH ITS SIBLINGS. 0.72.0.
--
-- This was a hand-rolled leading-edge throttle with NO TRAILING RUN -- the
-- exact shape `UI.RequestRefresh` documents as wrong and replaced, and the
-- shape the two other `CRITERIA_UPDATE` handlers in this addon
-- (`Exploration`, `Loremaster`) already avoid.
--
-- A single discovery fires several criteria updates in a row. The first was
-- answered against pre-move state and the rest were DROPPED -- including the
-- one that actually crossed the `IsNearlyDone` boundary -- so an achievement
-- reaching 38 of 40 stayed off the shortlist until an unrelated criteria
-- update happened along more than five seconds later. `CN.Debounce` gives the
-- leading answer AND one trailing run, which is what makes the last update in
-- a burst the one that counts.
CN:RegisterEvent("CRITERIA_UPDATE", function()
    CN.Debounce("Achievements.criteria",
        Achievements.criteriaSweepSeconds, function()

        -- AND THE RANKING IS TOLD. 0.73.0.
        --
        -- The trailing run is the one that matters -- it is the whole reason
        -- 0.72.0 moved this onto `CN.Debounce` -- and it bumped
        -- `Achievements.revision`, which busts the SHORTLIST cache and
        -- nothing else. The provider is marked dirty by its own
        -- `CRITERIA_UPDATE` subscription, which fires DURING the burst, five
        -- seconds before this runs. So a row crossing the "nearly done"
        -- boundary still did not reach `/cn next` until an unrelated criteria
        -- update happened along -- the exact case 0.72.0's note claims to
        -- have fixed.
        --
        -- `Exploration` and `Loremaster` both invalidate from inside their
        -- debounced bodies. This was the missed sibling, one release after
        -- the throttle was copied from them.
        local crossed = false

        -- THE SHORTLIST, NOT THE WHOLE STORE. 0.62.0.
        --
        -- This walked every incomplete tracked achievement and called
        -- `GetAchievementProgress` on each -- and that function makes one client
        -- call PER CRITERION. At retail scale it is several hundred rows of five
        -- to forty criteria: a few thousand client calls, every five seconds, for
        -- as long as CRITERIA_UPDATE keeps firing, which is continuously while
        -- questing or raiding. Measured on the game's own Lua 5.1: 21.4 ms per
        -- sweep, more than a frame, twelve times a minute.
        --
        -- Only rows near the boundary can change what the addon SHOWS: the
        -- provider reads the shortlist, and a row at 3 of 40 moving to 4 of 40
        -- changes nothing anybody sees until it is within the threshold. So the
        -- sweep covers the shortlist plus anything the player has pinned as a
        -- goal, which is a dozen rows rather than several hundred.
        --
        -- The rest are picked up by the next full scan, exactly as before -- this
        -- store has always been a snapshot refreshed on demand.
        local store = Store()

        local watched = {}

        for _, entry in ipairs(Achievements.Shortlist()) do
            watched[entry.id] = true
        end

        local goals = CN:GetModule("Goals")

        if goals and goals.List then
            for _, goal in ipairs(goals.List() or {}) do
                if goal and goal.type == CN.objectiveTypes.ACHIEVEMENT and goal.id then
                    watched[goal.id] = true
                end
            end
        end

        for achievementID, record in pairs(store) do
            if watched[achievementID]
                and record.criteria and record.criteria > 0 then

                -- BOTH RETURNS, BECAUSE A REFUSAL LOOKS LIKE ZERO. 0.67.0.
                --
                -- `GetAchievementProgress` answers `0, 0` when the criteria API
                -- is unavailable -- early in a loading screen, or before the
                -- achievement UI has loaded -- and this discarded the second
                -- return, so a refusal was written into the store as real
                -- progress. One `CRITERIA_UPDATE` at the wrong moment rewrote
                -- every watched row to zero, `IsNearlyDone` went false, and an
                -- achievement at 38 of 40 dropped out of `/cn next` until a full
                -- `/cn achievescan`, which nothing runs on its own.
                --
                -- `Exploration.RefreshCurrentZone` guards this exact case, under
                -- the header "NOT OVER GOOD DATA WITH NOTHING". The guard was
                -- never carried to the sibling.
                local done, criteria = Blizzard.GetAchievementProgress(achievementID)

                if criteria and criteria > 0
                    and done ~= (Achievements.DoneFor(record) or 0) then

                    local wasNear = IsNearlyDone(record)

                    Achievements.NoteProgress(record, done)

                    -- Only a change that crosses the shortlist boundary can
                    -- change what the provider would produce. Bumping the
                    -- revision on every criteria tick would rebuild the
                    -- shortlist constantly and give back the saving.
                    if wasNear ~= IsNearlyDone(record) then
                        Achievements.revision = Achievements.revision + 1
                        crossed = true
                    end
                end
            end
        end

        if crossed then
            CN.InvalidateProvider("Achievements")
        end
    end)
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "achievescan",
    order   = 64,
    help    = "Scan every achievement category.",
    handler = function()
        Print("Scanning achievements; this takes a moment.")

        local scanned, completed, nearlyDone = Achievements.Scan()

        Print("Scanned " .. scanned .. " achievements.")
        Print("Completed: " .. completed)
        Print("Within two criteria of finishing: " .. nearlyDone)
    end,
}

CN:RegisterCommand{
    name    = "achievements",
    aliases = { "achieve" },
    order   = 65,
    help    = "Summarize achievement progress.",
    handler = function()
        local counts = Achievements.Summary()

        if counts.total == 0 and counts.inProgress == 0 then
            Print("No achievement data yet. Run /cn achievescan.")
            return
        end

        Print("Achievements: " .. counts.completed .. " / " .. counts.total
            .. " (" .. CN.PercentText(
                counts.total > 0 and (counts.completed / counts.total) or 0, 1)
            .. ")")

        Print("Tracked in progress: " .. counts.inProgress)
        Print("Within two criteria of finishing: " .. counts.nearlyDone)

        local closest = Achievements.Closest(5)

        local rows = {}

        for _, record in ipairs(closest) do
            table.insert(rows, {
                text  = NameOf(record.achievementID or 0, record),
                value = (Achievements.DoneFor(record) or 0)
                    .. " / " .. record.criteria,
            })
        end

        CN.PrintRows(nil, rows, { limit = 5 })
    end,
}

CN:RegisterCommand{
    name    = "closest",
    args    = "[count]",
    order   = 66,
    help    = "List the achievements closest to completion.",
    handler = function(args)
        local limit   = CN.ToID(args) or 10
        local closest = Achievements.Closest(limit)

        if #closest == 0 then
            Print("No achievements in progress. Run /cn achievescan.")
            return
        end

        local rows = {}

        for _, record in ipairs(closest) do
            -- `points` HAS BEEN NIL SINCE 0.36.0.
            --
            -- That release stopped storing it, correctly -- the client
            -- returns it instantly and a copy on disk was dead weight. Two
            -- other places were updated to read it live or to tolerate its
            -- absence with `or 0`; this one was missed, so the command threw
            -- for anybody whose database had been migrated. It was invisible
            -- because the error is caught by the command dispatcher, printed
            -- once, and looks like a client hiccup.
            --
            -- Read live, and say nothing about points when the client will
            -- not say either.
            local points = record.points
                or Blizzard.GetAchievementPoints(record.achievementID)

            table.insert(rows, {
                text  = NameOf(record.achievementID or 0, record),
                value = (Achievements.DoneFor(record) or 0)
                    .. " / " .. record.criteria,
                note  = points and CN.Count(points, "point") or nil,
            })
        end

        CN.PrintRows(nil, rows, { limit = limit })
    end,
}
