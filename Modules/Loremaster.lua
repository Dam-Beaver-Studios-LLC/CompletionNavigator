-- Modules/Loremaster.lua
-- Completion Navigator :: finishing zones, continents and expansions.
--
-- FROM A PLAYER'S OWN STATED PLAN:
--
--   "Once I finish the story this weekend, I'm gonna do all the side quests
--    on the continent I'm currently on. Then I'll move from one continent to
--    another. After that, I'm gonna switch timelines and work backwards to
--    the previous expansion... Basically, I'm gonna try to complete every
--    main quest and side quest in the entire game."
--
-- That is a two-year project measured in zones and continents, and the addon
-- had nothing to say about it. It could tell him what to do in the next
-- hundred yards and nothing about where he was in the campaign.
--
-- THE DENOMINATOR PROBLEM, AND WHY THIS WORKS ANYWAY.
--
-- The client will not tell you how many quests exist in a zone. Counting
-- "quests I know about" would produce a denominator that grows as you play,
-- so your percentage would go DOWN as you did more -- which is worse than no
-- percentage at all, and this addon has a standing rule against inventing
-- one.
--
-- But the game already ships the exact tracker this player needs: the quest
-- achievements. "Loremaster of Khaz Algar", the per-zone story achievements,
-- the exploration-style quest counts. Those have criteria the client
-- enumerates and vouches for. So the progress here is real, and it is real
-- because we did not compute it -- we read it.

local ADDON_NAME, CN = ...

local Loremaster = CN:RegisterModule("Loremaster")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint

local Blizzard = CN.Blizzard

-- Blizzard's "Quests" achievement category. A stable constant for many
-- years, and everything below degrades to "nothing found" rather than to an
-- error if it ever moves.
Loremaster.questCategoryID = 96

-- Published rather than literals, so the retry is a knob the suite can turn.
Loremaster.coldRetrySeconds    = 10
Loremaster.maximumColdAttempts = 3
Loremaster.coldAttempts        = 0

------------------------------------------------------------
-- THE CATEGORY TREE
------------------------------------------------------------

-- Every category descending from Quests: one per expansion, and below those,
-- per continent. Walked rather than hardcoded, so a new expansion needs no
-- code.
function Loremaster.QuestCategories()
    local categories = {}

    if not GetCategoryList or not GetCategoryInfo then
        return categories
    end

    local ok, list = pcall(GetCategoryList)

    if not ok or type(list) ~= "table" then
        return categories
    end

    -- Parentage is only one level per lookup, so resolve to a root by
    -- walking upward. Cheap: the tree is three deep at most.
    local function rootOf(categoryID)
        local guard = 0
        local current = categoryID

        while current and guard < 8 do
            local name, parent = GetCategoryInfo(current)

            if not name then
                return nil
            end

            if current == Loremaster.questCategoryID then
                return current
            end

            if not parent or parent <= 0 then
                return nil
            end

            current = parent
            guard   = guard + 1
        end

        return nil
    end

    for _, categoryID in ipairs(list) do
        if rootOf(categoryID) == Loremaster.questCategoryID then
            local name, parent = GetCategoryInfo(categoryID)

            table.insert(categories, {
                categoryID = categoryID,
                name       = name,
                parentID   = parent,
            })
        end
    end

    return categories
end

------------------------------------------------------------
-- SCANNING
------------------------------------------------------------

local function Records()
    return CN.Account("loremaster")
end

Loremaster.Records = Records

-- The achievement's name, and its category's, from the client. See the note
-- in `Scan`. The stored fallbacks keep an older database readable until its
-- first rescan.
function Loremaster.NameOf(achievementID, record)
    local live = Blizzard.GetAchievementName
        and Blizzard.GetAchievementName(achievementID)

    if live and live ~= "" then
        return live
    end

    return (record and record.name)
        or ("Achievement " .. tostring(achievementID))
end

function Loremaster.CategoryOf(record)
    if type(record) ~= "table" then
        return "Other"
    end

    if record.categoryID and Blizzard.GetCategoryName then
        local live = Blizzard.GetCategoryName(record.categoryID)

        if live and live ~= "" then
            return live
        end
    end

    return record.category or "Other"
end

-- THE STORE HAD NO CHARACTER DIMENSION, AND SAID IT DID. FIXED IN 0.61.0.
--
-- `Loremaster.Scan`'s own comment says the store exists "so the Warband view
-- can show what other characters have finished". It could not: every row was
-- written into the ACCOUNT store under the achievement id alone, so whichever
-- character logged in last overwrote every other character's progress.
--
-- Two players on two characters saw the second one's numbers attributed to
-- both, and the Warband column that this was built for showed the same figure
-- in every row. Nothing caught it because the fixture has one character, and
-- one character cannot overwrite anybody.
--
-- The split follows what the game actually scopes:
--
--   name, category, criteria  -- properties of the achievement. Account.
--   completed                 -- achievements are earned account-wide. Account.
--   done                      -- criteria progress on quest achievements is
--                                CHARACTER-specific. Per character.
--
-- `progress` is a table keyed by character key. `record.done` is kept as the
-- current character's value so nothing downstream had to change shape, and so
-- a database written by an older version still reads correctly until the
-- migration runs.
function Loremaster.DoneFor(record, characterKey)
    if type(record) ~= "table" then
        return 0
    end

    characterKey = characterKey or CN.characterKey or CN.GetCharacterKey()

    if record.progress and record.progress[characterKey] ~= nil then
        return record.progress[characterKey]
    end

    -- No per-character figure: either this character has never scanned, or
    -- the row predates the split. Only the CURRENT character may fall back to
    -- the flat field, because that field holds whoever scanned last -- which
    -- is exactly the bug, and attributing it to a named other character would
    -- keep telling the lie in a new place.
    if characterKey == (CN.characterKey or CN.GetCharacterKey()) then
        return record.done or 0
    end

    return nil
end

-- Reads every quest achievement and stores what the client says about it.
-- Stored rather than recomputed because walking the achievement tree is not
-- something to do on every frame, and because it lets the Warband view show
-- what other characters have finished.
function Loremaster.Scan(fromRetry)
    local store = Records()

    -- COUNTED ONLY WHEN THE RETRY ITSELF IS COLD. 0.75.0.
    --
    -- 0.74.0 incremented on every cold scan and reset only on one that
    -- measured something, so three cold scans anywhere in a session -- `/cn
    -- setup` at login plus two presses of "Rescan zones", which is exactly
    -- what the addon's own messages tell the player to do -- left the counter
    -- spent, and every later cold scan scheduled nothing. The retry died
    -- silently at the moment the player started trying harder.
    --
    -- A scan the player asked for is a fresh start; only the retry chain
    -- counts against itself.
    if not fromRetry then
        Loremaster.coldAttempts = 0
    end

    local scanned = 0

    -- How many rows the client actually answered about. See the marker at
    -- the bottom: a scan that measured nothing must not record itself.
    local measured = 0

    for _, category in ipairs(Loremaster.QuestCategories()) do
        local total = select(1, Blizzard.GetCategoryCounts(category.categoryID))

        for index = 1, (total or 0) do
            local achievement = Blizzard.GetAchievementInCategory(
                category.categoryID, index)

            if achievement and achievement.achievementID then
                local id = achievement.achievementID

                local done, criteria = Blizzard.GetAchievementProgress(id)

                local held = store[id] or {}

                -- NEITHER NAME IS STORED. 0.64.0.
                --
                -- Both are LOCALIZED strings the client answers instantly,
                -- and both were being branched on: `ByCategory` groups on the
                -- stored category and `ForZone` substring-matches the stored
                -- achievement name against a LIVE zone name. So a player who
                -- switched client language read English achievement names
                -- under English headings, and `ForZone` matched nothing at
                -- all -- the "This zone" block and the already-here bonus in
                -- `/cn zones` simply disappeared until a rescan.
                --
                -- Sixth store to lose a name it did not need to keep;
                -- migrations 4, 5, 14, 15 and 16 were the others.
                held.categoryID = category.categoryID
                held.completed = achievement.completed and true or false

                -- THE FLAT FIELD IS NO LONGER WRITTEN. 0.66.0. See the same
                -- change in `Exploration.NoteProgress`.
                --
                -- It was kept so pre-migration databases still read, and
                -- `DoneFor` still reads it for that reason -- but writing it
                -- here meant the fallback returned whoever scanned last
                -- rather than something old, so an alt with no entry of its
                -- own was handed the main's criteria count as its own.
                -- NOT OVER GOOD DATA WITH NOTHING. 0.70.0.
                --
                -- `GetAchievementProgress` answers `0, 0` when the criteria
                -- API is unavailable, and this wrote that straight in --
                -- `Closest` filters on `criteria > 0`, so one scan at a cold
                -- moment emptied the whole Journey tab and `/cn zones`, and
                -- stamped the Scans tab "just now" on the way.
                --
                -- The guard `Exploration` has carried since 0.61.0, that
                -- `Achievements` was given in 0.68.0, and that this file's
                -- OWN new sibling forty lines down has -- in the third
                -- writer, thirty lines from the comment naming the other two.
                if criteria and criteria > 0 then
                    held.criteria = criteria

                    held.progress = held.progress or {}
                    held.progress[CN.characterKey or CN.GetCharacterKey()] = done

                    measured = measured + 1
                end

                store[id] = held

                scanned = scanned + 1
            end
        end
    end

    -- AND ONLY WHEN IT MEASURED SOMETHING. 0.71.0.
    --
    -- The marker was written unconditionally, so a scan that ran at a moment
    -- the criteria API would not answer -- which is routine at `PLAYER_LOGIN`
    -- and is the reason the guard above exists -- recorded nothing, stamped
    -- itself as done, and put "just now" on the Scans tab. The login rescan
    -- then never fired again for that character, and `/cn zones` reported
    -- "not started" for every zone it had fully quested, permanently.
    --
    -- The 0.69.0 condition it replaced was accidentally repairing this on the
    -- next login; 0.70.0 removed the repair along with its cost.
    -- INVALIDATED BEFORE THE EARLY RETURN, NOT AFTER IT. 0.73.0.
    --
    -- `Scan` writes `store[id]` for every row it reaches whether or not the
    -- criteria API answered, so the set of records can change on a scan that
    -- measured nothing -- and the invalidation sat below the early return, so
    -- the one scan most likely to have run against a cold client was the one
    -- scan that left a stale index behind.
    Loremaster.ForgetZoneIndex()

    if measured == 0 then
        DebugPrint("Loremaster scan measured nothing; not recording it.")

        -- AND IT TRIES AGAIN. 0.74.0.
        --
        -- 0.73.0 correctly stopped such a scan from recording itself and then
        -- left the player with nothing: the store is no longer EMPTY, because
        -- the walk wrote a row for everything it reached, so the "no data
        -- yet, running a scan" branch never fires again -- and `Closest`
        -- filters on `criteria > 0`, so the Journey tab shows a bare "Here"
        -- row and no zone list, silently, until the next login.
        --
        -- The condition is known to be transient; this file says so in four
        -- separate comments. A retry is the obvious affordance and costs one
        -- timer. Bounded, so a client that will never answer is not asked
        -- forever.
        Loremaster.coldAttempts = (Loremaster.coldAttempts or 0) + 1

        if Loremaster.coldAttempts <= Loremaster.maximumColdAttempts
            and C_Timer and C_Timer.After then

            C_Timer.After(Loremaster.coldRetrySeconds, function()
                CN.Guard("Loremaster.Scan", function()
                    local retried, got = Loremaster.Scan(true)

                    -- AND THE PLAYER IS TOLD IT WORKED. 0.75.0.
                    --
                    -- `/cn setup` and the Rescan button both say "try again
                    -- in a moment" while a retry is already scheduled, and
                    -- 0.74.0's retry succeeded in silence -- leaving the
                    -- player looking at a stale empty list with nothing to
                    -- say the addon had recovered.
                    if (got or 0) > 0 then
                        Print("Zone progress read: " .. retried
                            .. " quest achievements. The game is answering "
                            .. "now.")

                        if CN.UI and CN.UI.RequestRefresh then
                            CN.UI.RequestRefresh()
                        end
                    end
                end)
            end)
        end

        -- AND IT SAYS SO OUT LOUD. 0.72.0.
        --
        -- 0.71.0 stopped the marker and went on returning `scanned`, which
        -- counts every row the walk REACHED -- so `/cn scanlore` at a cold
        -- moment printed "Quest achievements scanned: 412" over a store that
        -- had recorded nothing, and the Journey tab stayed empty. A count is
        -- not a result.
        return scanned, 0
    end

    -- WHO HAS SCANNED, RECORDED RATHER THAN INFERRED. 0.70.0.
    --
    -- The login rescan asked "does every row carry this character's
    -- progress?" -- and `Scan` writes progress only for achievements the
    -- category walk returns, so any row it cannot reach this session (a
    -- category the client has not populated yet at login, an achievement
    -- retired in a patch) keeps that entry nil for ever. The condition was
    -- then true on every login of every character, and each firing is the
    -- full tree walk this file says is "why it was never put on an event".
    --
    -- A marker says what actually happened.
    CN.Account("loremasterScans")[CN.characterKey or CN.GetCharacterKey()] =
        time()

    CN.MarkScanned("loremaster")

    Loremaster.coldAttempts = 0

    -- AND A BINDING TO AN ACHIEVEMENT THAT NO LONGER EXISTS IS DROPPED.
    -- 0.75.0.
    --
    -- A game patch can retire a quest achievement. The binding for it would
    -- otherwise sit on disk for the life of the account, excluding nothing
    -- and describing nothing -- dead state that the next reader has to
    -- discover is dead. Only after a scan that measured something, so a cold
    -- client never deletes anything.
    local bindings = Loremaster.Bindings()

    for achievementID in pairs(bindings) do
        if not store[achievementID] then
            bindings[achievementID] = nil
        end
    end

    DebugPrint("Loremaster scan: " .. scanned .. " quest achievements.")

    return scanned, measured
end

------------------------------------------------------------
-- GROUPING
------------------------------------------------------------

-- Quest achievements grouped by the category they live in -- which is to say,
-- by expansion and continent, because that is how Blizzard files them and
-- how the player thinks about them.
function Loremaster.ByCategory(includeCompleted)
    local groups, order = {}, {}

    for id, record in pairs(Records()) do
        if includeCompleted or not record.completed then
            local key = Loremaster.CategoryOf(record)

            if not groups[key] then
                groups[key] = {}
                table.insert(order, key)
            end

            table.insert(groups[key], {
                id        = id,
                name      = Loremaster.NameOf(id, record),
                completed = record.completed,
                done      = Loremaster.DoneFor(record) or 0,
                criteria  = record.criteria or 0,
            })
        end
    end

    table.sort(order)

    for _, key in pairs(order) do
        table.sort(groups[key], function(a, b)
            local left  = (a.criteria or 0) > 0 and (a.done / a.criteria) or -1
            local right = (b.criteria or 0) > 0 and (b.done / b.criteria) or -1

            if left ~= right then
                return left > right
            end

            return tostring(a.name) < tostring(b.name)
        end)
    end

    return groups, order
end

-- The ones worth finishing next: started, not finished, closest first.
-- An untouched zone is not "nearly done", so it sorts below one you have
-- already put an evening into.
-- The zones nearest to finished.
--
-- TWO BUGS LIVED HERE.
--
-- The first: this sorted candidates carefully by completion fraction and then
-- handed the list to CN.CapCandidates, which re-sorts by `completionValue` --
-- a field these rows do not have. Every row therefore compared equal and the
-- tie-break took over, silently reordering the whole list alphabetically by
-- achievement ID whenever there were more rows than the limit. The careful
-- ordering above it was thrown away exactly when it mattered.
--
-- The second was worse for anyone actually working through content: rows with
-- `done == 0` were excluded, so a zone you had never set foot in could never
-- be recommended. For a player sweeping a continent, the untouched zones are
-- precisely the ones they need to be pointed at.
--
-- Untouched zones are now included and ranked separately, because "you are
-- 90% through this one" and "you have not started this one" are different
-- suggestions and blending them by fraction would bury every fresh zone under
-- every half-finished one forever.
-- NAMES ARE RESOLVED FOR THE ROWS THAT SURVIVE, NOT FOR THE STORE. 0.72.0.
--
-- Both `Loremaster.NameOf` and `Loremaster.CategoryOf` are `pcall` plus a
-- client call, and this resolved both for EVERY unfinished record before
-- sorting and throwing all but `limit` away. Several hundred rows on a mature
-- account, twice each, on a function the Journey tab calls from every
-- `UI.Refresh` -- which data events drive as often as every two seconds.
--
-- Sorting on the numbers, truncating, and naming what is left makes that
-- O(limit) client calls instead of O(store). The tie-breaks that used the
-- name now use the id, which is stable, free, and just as deterministic.
--
-- AND THE UNTOUCHED HALF IS NO LONGER TRUNCATED AWAY.
--
-- The two lists were concatenated and cut from the end, so an account with
-- `limit` or more partly-done zones lost every untouched one -- and
-- `NextZones` asks for 50, which is an ordinary number of started zones for
-- the completionist this file was written for. The header below says a zone
-- you have never set foot in must be recommendable; it was not, for exactly
-- the players it was written for. Each half now keeps its own share.
function Loremaster.Closest(limit, freshShare)
    local started, untouched = {}, {}

    for id, record in pairs(Records()) do
        local done = Loremaster.DoneFor(record) or 0

        -- NOTHING LEFT IS NOT "CLOSEST TO FINISHING". 0.71.0.
        --
        -- The candidate provider has always carried this rule -- `if
        -- remaining <= 0 ... return` -- and the two DISPLAY paths did not, so
        -- a row whose criteria are all done but whose earned flag is stale
        -- sorted to the top of `/cn zones` with the reason "100% done --
        -- finishing is cheaper than starting", and to the top of the Journey
        -- tab's "closest to finished" printed as 60/60 in the unfinished
        -- colour. The addon telling the player, first, to go and finish a
        -- zone with nothing in it.
        --
        -- The same rule written twice, and the third copy is in `Exploration`
        -- with the same omission.
        if not record.completed and (record.criteria or 0) > 0
            and done < record.criteria then

            local row = {
                id       = id,
                record   = record,
                done     = done,
                criteria = record.criteria,
                fraction = done / record.criteria,
            }

            if row.done > 0 then
                table.insert(started, row)
            else
                table.insert(untouched, row)
            end
        end
    end

    local function byProgress(a, b)
        if a.fraction ~= b.fraction then
            return a.fraction > b.fraction
        end

        return (a.criteria - a.done) < (b.criteria - b.done)
    end

    table.sort(started, byProgress)

    -- Smallest first among the untouched: a fresh zone with twenty quests is
    -- a better next step than one with ninety.
    table.sort(untouched, function(a, b)
        if a.criteria ~= b.criteria then
            return a.criteria < b.criteria
        end

        return a.id < b.id
    end)

    -- Truncate. Deliberately NOT CN.CapCandidates: that re-sorts, and the
    -- ordering above is the entire product of this function.
    limit = limit or 10

    -- RESERVED ONLY WHEN THE CALLER ASKS FOR IT. 0.73.0.
    --
    -- 0.72.0 applied the reserve to every caller, and two of the three are
    -- headed "Closest to finished" -- the Journey tab and `/cn loremaster`.
    -- So a player with plenty of half-done zones read three rows of `0 / 120`
    -- with an empty bar under that heading, while three genuinely nearly-done
    -- zones were pushed off the list to make room for them.
    --
    -- `NextZones` is the caller the reserve was written for: it is the one
    -- that scores untouched zones on their own terms and labels them "not
    -- started, N to do". It asks for the reserve explicitly now.
    local fresh = math.min(#untouched, freshShare or 0)

    local room = math.max(0, limit - fresh)

    local ordered = {}

    for index = 1, math.min(#started, room) do
        table.insert(ordered, started[index])
    end

    -- AND THE FILL RESPECTS THE SHARE TOO. 0.74.0.
    --
    -- 0.73.0 made the RESERVE opt-in and left the FILL unbounded, so any
    -- account with fewer started zones than the limit -- a new player, an
    -- alt, anyone mid-expansion -- still read rows of `0 / 120` with an empty
    -- bar under a heading that says "Closest to finished". Less common than
    -- before, and the same wrong thing.
    --
    -- Both callers already receive `#started` and `#untouched` and can say
    -- "Not started" over their own section; see the Journey tab.
    for index = 1, math.min(#untouched, fresh, limit - #ordered) do
        table.insert(ordered, untouched[index])
    end

    -- The client calls, at last, and only for what is being shown.
    for _, row in ipairs(ordered) do
        row.name     = Loremaster.NameOf(row.id, row.record)
        row.category = Loremaster.CategoryOf(row.record)
        row.record   = nil
    end

    return ordered, #started, #untouched
end

-- WHICH RECORD THIS ZONE IS, LEARNED BY MAP ID. Rewritten in 0.71.0.
--
-- Three releases have claimed to fix a reported symptom -- "the completion of
-- a quest does not appear to remove it from the journey" -- and none of them
-- worked. 0.69.0 listened for the wrong event. 0.70.0 fixed the event and
-- introduced this lookup, which was inert in two separate ways:
--
--   1. It keyed on `GetMapName(GetBestMapForUnit(...))`, which answers with
--      the CITY when the player is standing in one -- and this file's own
--      neighbour says so in as many words. No achievement contains
--      "Dornogal", so the whole path did nothing for any turn-in made in a
--      capital, which is where campaign turn-ins happen.
--
--   2. It refused whenever two achievements contained the zone name, on the
--      grounds that duplicate ZONE names are ambiguous -- and every modern
--      zone ships a story achievement AND a "Sojourner of <Zone>" companion,
--      so it refused everywhere. `ForZone` picked one happily for display, so
--      the tab showed a count that nothing ever moved.
--
-- `Exploration.ForCurrentZone` has solved this since 0.62.0 and this is that
-- solution, not a third invention: the zone name must appear as a whole word
-- run anchored at the END of the achievement name.
--
-- WHAT 0.71.0 THEN GOT WRONG ABOUT REMEMBERING THE ANSWER, fixed in 0.72.0.
--
-- It matched on `GetZoneText()` -- correctly -- and then cached the answer
-- under `CN.GetPlayerPosition()`, which is `GetBestMapForUnit`: the CITY map
-- indoors. That is the same wrong value defect (1) above is about, moved from
-- the match to the memory of it, and it is the fourth time this one map call
-- has been used for a question it does not answer.
--
-- Three things followed. The cache never converged, because walking out of a
-- building missed and re-stamped a different id, so the walk it exists to
-- avoid ran on every threshold. The stamp was PERSISTED, so it wrote a
-- SavedVariable on every zone transition. And because "unfinished first" can
-- change its mind when the story achievement completes, one zone could end up
-- with two records holding two map ids -- the completed one indoors and the
-- companion outdoors -- so the tab showed a different achievement depending
-- on which side of a doorway the player stood. Exactly the hash-order
-- symptom 0.71.0 set out to remove, reintroduced by the fix for it.
--
-- The key is now the zone name, which is what the match was actually made on,
-- and the cache is SESSION-LOCAL. A name is a display string and this file
-- never branches on it -- it is a cache key, and the walk that fills it is
-- the same walk that would run without it. Nothing about a localized string
-- is worth writing to disk, and a session is exactly as long as the answer
-- stays true.
local zoneIndex = {}

-- Which rows the client has ever named in this session. `false` means it has
-- refused every time so far -- a row retired in a game patch, most likely --
-- and `true` means it answered at least once, which is permanent.
local everNamed = {}

-- Only a change to WHICH RECORDS EXIST invalidates this -- a scan. Earning
-- an achievement does not, because the winner is chosen fresh on every
-- lookup; see the note inside `ZoneRecord`.
function Loremaster.ForgetZoneIndex()
    zoneIndex = {}
    everNamed = {}
end

-- NO LOADING-SCREEN WIPE. 0.74.0. See the acceptance test in `ZoneRecord`:
-- refusing to remember an indecisive walk is cheaper and more direct than
-- remembering it and then throwing the whole index away on an event.

-- WHICH OF TWO LEGITIMATE ZONE MATCHES IS THE ZONE'S OWN. 0.71.0.
--
-- Every modern zone has more than one achievement whose name ends in the zone
-- name: the story one and its "Sojourner of <Zone>" companion, at least. Both
-- are legitimate matches, so SOMETHING has to choose, and what it must not
-- choose by is whichever `pairs` reached first -- that shows a different zone
-- achievement on different logins with nothing having changed, and it is the
-- reason this is a named function with its own test rather than four lines
-- inside a loop where only the hash order could observe it.
--
-- The order, in full:
--   1. an unfinished one beats a finished one -- the tab is about what is
--      left, and a completed zone achievement has nothing left to say;
--   2. then the SHORTER name, which is the one about the zone rather than
--      about the zone plus a side collection;
--   3. then the lower ID, so that two achievements with names of equal length
--      still resolve the same way every time.
--
-- Every step is total and deterministic; there is no path that returns "I
-- cannot tell", because refusing is what made 0.70.0 do nothing everywhere.
-- WHICH ACHIEVEMENT A ZONE IS, LEARNED FROM EVIDENCE. 0.74.0.
--
-- WHY THE 0.73.0 ANSWER WAS INERT.
--
-- 0.73.0 broke the tie between two zones sharing a name by comparing the
-- achievement's category name with the name of the continent the player is
-- standing on. The premise was that the quest category tree is
-- Quests > continent. It is not. On retail the children of category 96 are
-- EXPANSIONS -- "Warlords of Draenor", "Burning Crusade", "Legion" -- and
-- only Classic has a continent level beneath it. So for every collision the
-- release was written for:
--
--   Draenor's Nagrand   continent "Draenor"      category "Warlords of Draenor"
--   Outland's Nagrand    continent "Outland"      category "Burning Crusade"
--   Legion Dalaran       continent "Broken Isles" category "Legion"
--
-- neither side matched, both answers were false, and the branch never fired.
-- A release whose headline was "zone identity, for the fourth and last time"
-- shipped a comparison that could not fire in any case it was written for --
-- and, where it COULD fire, fired wrongly: the only categories that ever
-- match a continent name are Classic's two, and the test sat ABOVE the
-- unfinished-beats-finished rule, so a Cataclysm-revamped zone lost to
-- anything filed under "Kalimdor".
--
-- It was also two localized strings being compared to decide a branch, which
-- is the one thing this project has a standing rule against, in the one place
-- the rule warns about.
--
-- WHAT REPLACES IT.
--
-- There is no client call that says which zone a quest achievement belongs
-- to. There is, however, evidence: when the player's criteria progress on
-- exactly one candidate MOVES while they are standing in a given zone, that
-- candidate is that zone's achievement. Nothing else can produce that.
--
-- So the binding is learned rather than derived, filed under the zone's own
-- map id -- which cannot be duplicated -- and it is the only thing in this
-- store that IS persisted, because it is the one fact here the client cannot
-- hand back. Until the evidence arrives the ordering below is unchanged:
-- deterministic, stable across logins, and occasionally wrong about which of
-- two Nagrands you meant. That is honest, and it stops being wrong the first
-- time the player turns a quest in there.
-- WHICH ZONE AN ACHIEVEMENT BELONGS TO, LEARNED FROM EVIDENCE. 0.75.0.
--
-- INVERTED FROM 0.74.0, WHICH HAD THE RELATION THE WRONG WAY ROUND.
--
-- 0.74.0 stored zone -> achievement and let a binding PROMOTE that
-- achievement above every other rule. Two things went wrong with that, and
-- both of them fired in ordinary play rather than in the rare case the
-- mechanism was written for:
--
--   1. The learning path ran in EVERY zone, because its guard was "more than
--      one candidate" -- and this file says two paragraphs further up that
--      every modern zone has at least two: its story achievement and its
--      "Sojourner of <Zone>" companion. Those are not rivals; they are both
--      this zone's. So the first quest of either kind, turned in alone, bound
--      the zone to whichever it happened to be. Once a bound Sojourner was
--      earned, the "Here" row showed it green at 24/24 for ever while the
--      zone's Loremaster achievement sat at 30 of 60, unmentioned, and the
--      provider stopped offering the zone at all.
--
--   2. It was absolute. A binding outranked unfinished-beats-finished, which
--      is the rule that makes the tab about what is LEFT.
--
-- The relation that is actually true is the other one: an achievement belongs
-- to a zone. Stored that way it EXCLUDES rather than promotes -- a candidate
-- known to belong to a different zone map is not a candidate here -- and
-- everything else is left to the ordering that was already correct.
--
-- That makes the two cases behave differently, which is the point:
--
--   Two Nagrands: Outland's achievement is learned to belong to Outland's
--   map, so standing in Draenor's it is excluded and Draenor's is all that
--   is left. This is the case the mechanism exists for.
--
--   Story and Sojourner: both belong to the SAME map, so neither is ever
--   excluded and the shortest-name rule decides, exactly as before. The
--   mechanism cannot do harm here, by construction, rather than by a guard
--   somebody has to remember.
--
-- Self-healing, too: a binding is re-learned from newer evidence, so a wrong
-- one corrects itself the next time a quest is handed in. `/cn zones forget`
-- clears them all for a player who wants to start over.
local function Bindings()
    return CN.Account("achievementZones")
end

Loremaster.Bindings = Bindings

function Loremaster.ForgetBindings()
    local store = Bindings()

    local cleared = 0

    for key in pairs(store) do
        store[key] = nil
        cleared = cleared + 1
    end

    return cleared
end

-- The zone map this achievement has been shown to belong to, or nil.
function Loremaster.ZoneOfAchievement(achievementID)
    if not achievementID then
        return nil
    end

    return Bindings()[achievementID]
end

-- LEARNED ONLY FROM A READING THAT ACTUALLY CHANGED, against a baseline that
-- was actually recorded. Re-learned from newer evidence rather than held.
function Loremaster.Bind(achievementID, zoneMapID)
    if not achievementID or not zoneMapID then
        return false
    end

    if Bindings()[achievementID] == zoneMapID then
        return false
    end

    Bindings()[achievementID] = zoneMapID

    return true
end

function Loremaster.BetterZoneMatch(record, name, id, best, bestName, bestID)
    -- A HELD CANDIDATE WITH NO NAME IS NOT A HELD CANDIDATE. 0.72.0.
    --
    -- This is called from one place with three variables that are always set
    -- together, so the `not best` test was enough -- but it is a published
    -- function with its own test, which is an invitation to call it from a
    -- second place, and `#bestName` on a nil throws rather than degrading.
    if not best or not bestName or not bestID then
        return true
    end

    -- NO BINDING RULE HERE ANY MORE. 0.75.0.
    --
    -- 0.74.0 put one at the top, absolute, and it promoted the wrong
    -- achievement in every ordinary zone -- see the header on `Bindings`. A
    -- candidate known to belong somewhere else is now removed from the list
    -- BEFORE this function sees it, which is a filter rather than a
    -- preference, and leaves this ordering as it was when it was correct.
    local heldDone = best.completed and true or false
    local mineDone = record.completed and true or false

    if heldDone ~= mineDone then
        return not mineDone
    end

    if #name ~= #bestName then
        return #name < #bestName
    end

    return id < bestID
end

-- `zone` is the name to match on and `key` is what the answer is filed
-- under. Both default to the zone the player is standing in. A caller asking
-- about SOMEWHERE ELSE must supply both, because the player's own zone id is
-- not an identity for a zone they are not in -- which is how the first draft
-- of this filed Eversong Woods' answer under Isle of Dorn.
local function ZoneRecord(zone, key)
    if not zone then
        zone = GetZoneText and GetZoneText()

        key = key or (Blizzard.ZoneMapID
            and Blizzard.ZoneMapID(CN.GetPlayerPosition()))
    end

    if not zone or zone == "" then
        return nil
    end

    key = key or zone

    local store = Records()

    -- WHAT IS CACHED IS THE MATCH, NOT THE WINNER.
    --
    -- The two halves of this answer age differently. WHICH achievements are
    -- named after this zone depends only on their names, which do not change
    -- while the client is running -- and finding them is the whole expense:
    -- a walk of the store with a `pcall` and a client call per row. WHICH of
    -- those is the zone's own depends on `completed`, which changes the
    -- instant the player earns one.
    --
    -- Caching the winner, as the first draft of this did, made the second
    -- fact as stale as the first: earning the story achievement left the tab
    -- showing it at 60/60 while its companion sat open and unmentioned, until
    -- the next login. Caching only the candidate list keeps the expensive
    -- half and re-decides the cheap half every time -- a loop over two or
    -- three entries with no client calls in it.
    -- FILED UNDER THE ZONE'S OWN MAP ID WHERE THERE IS ONE. 0.73.0.
    --
    -- The name is what the match is MADE on and stays so. It is the wrong
    -- thing to file the result under: two zones called Nagrand would share
    -- one entry, and a player walking from one to the other would be handed
    -- the other one's candidate list. `Blizzard.ZoneMapID` walks up to the
    -- first ancestor the client itself calls a zone, so it answers with the
    -- ZONE even when the player is standing in a building inside it -- which
    -- is the distinction the last three releases kept getting wrong.
    local needle = string.lower(zone)

    -- A COMPOSITE KEY, NOT AN EXCLUSIVE ONE. 0.75.0.
    --
    -- 0.74.0 filed the match list under the map id and rejected it on read
    -- when the stored needle differed. In a dungeon or raid whose map parents
    -- into its outdoor zone -- most modern ones -- `ZoneMapID` answers with
    -- the ZONE and `GetZoneText` with the instance, so those two always
    -- differ: every lookup inside missed AND overwrote the outdoor zone's
    -- good entry with the instance's empty one, and walking back out missed
    -- and re-stamped. The index never converged, in the places
    -- `CRITERIA_UPDATE` fires hardest -- which is the exact failure the
    -- caching scheme before it was replaced for.
    --
    -- Putting the needle IN the key keeps both properties instead of trading
    -- one for the other: two Nagrands still get separate entries because
    -- their map ids differ, and a dungeon and the zone around it each hold
    -- their own.
    -- THE KEY AND THE VALUE COME FROM DIFFERENT CLIENT CALLS. 0.74.0.
    --
    -- `key` comes from the map and `matches` is derived entirely from the
    -- NAME, and the two can disagree: during a loading screen the map is nil
    -- and the key falls back to the name, so one zone acquires two entries;
    -- and `ForZone(mapID)` resolves the name of a micro map while keying on
    -- the ZONE above it, which files an empty match list under the enclosing
    -- zone -- making that zone's achievement vanish from the tab until the
    -- entry is dropped.
    --
    -- Storing the needle beside the list makes the pairing an invariant that
    -- is checked rather than an assumption that holds until it does not.
    local slot = tostring(key) .. "|" .. needle

    local held = zoneIndex[slot]

    local matches = held and held.zone == needle and held.matches or nil

    if not matches then

        local function Names(candidate)
            if not candidate then
                return false
            end

            candidate = string.lower(candidate)

            if candidate == needle then
                return true
            end

            -- Ends with the zone name, preceded by a space: "Loremaster of
            -- Nagrand" matches "Nagrand", and an achievement about Shadowmoon
            -- Valley does not match "Shadowmoon".
            return string.sub(candidate, -(#needle + 1)) == (" " .. needle)
        end

        matches = {}

        -- HOW MANY ROWS THE CLIENT ACTUALLY NAMED. See the guard below.
        local named, rows, retired = 0, 0, 0

        local refused = {}

        for id, record in pairs(store) do
            rows = rows + 1

            local live = Blizzard.GetAchievementName
                and Blizzard.GetAchievementName(id)

            if live and live ~= "" then
                named = named + 1

                -- A row that has answered once in this session is never one
                -- of the retired ones below, permanently.
                everNamed[id] = true
            else
                table.insert(refused, id)

                if everNamed[id] == false then
                    retired = retired + 1
                end
            end

            -- THE ANSWER ALREADY IN HAND, NOT A SECOND CALL FOR IT. 0.74.0.
            --
            -- 0.73.0 added the counter above and then called
            -- `Loremaster.NameOf`, which asks the client for the very same
            -- name again -- a second `pcall(GetAchievementInfo)` per row, on
            -- the walk this file calls "the whole expense". It doubled the
            -- cost of the thing it was written to make safe.
            local heldName = (live and live ~= "" and live)
                or Loremaster.NameOf(id, record)

            if Names(heldName) then
                table.insert(matches, { id = id, name = heldName })
            end
        end

        -- A WALK THE CLIENT REFUSED IS NOT AN ANSWER, AND MUST NOT BE KEPT.
        -- 0.73.0.
        --
        -- Achievement names are not stored -- since 0.64.0 they are asked for
        -- every time -- so when the client will not answer, which is routine
        -- for a window after a loading screen and is what every other guard
        -- in this file exists for, every row resolves to "Achievement 12345"
        -- and nothing matches. 0.72.0 then cached that empty result
        -- deliberately, for the session.
        --
        -- The Loremaster provider declares `ZONE_CHANGED_NEW_AREA`, so its
        -- first rebuild after a loading screen runs this walk at exactly that
        -- cold moment. One badly-timed zone change and the Journey tab's
        -- "Here" row, the "This zone" block, the provider's rows and the
        -- turn-in refresh were all silently gone until the next login.
        -- REMEMBERED ONLY WHEN THE CLIENT ANSWERED FOR EVERY ROW. 0.74.0.
        --
        -- 0.73.0 tested `named == 0`, which misses the case that actually
        -- happens. The client warming up answers for SOME rows and not
        -- others, so the walk finds a few names, misses the zone's own, and
        -- caches a wrong answer that an `== 0` guard waves straight through.
        --
        -- 0.73.0 covered that by wiping the whole index on
        -- `PLAYER_ENTERING_WORLD` -- every loading screen, portal, hearth and
        -- boat -- each one paying for a full store walk in the first seconds
        -- after the screen clears, which is precisely when the client is
        -- least able to answer. An event that undoes a bad decision after the
        -- fact, at the moment the bad decision is most likely.
        --
        -- The exact test is not a ratio, which would be a number picked out
        -- of the air. It is: did the client answer for everything it was
        -- asked about? If so this walk is as good as any later one and is
        -- worth keeping. If not, the answer is still RETURNED -- a partial
        -- list is more likely right than nothing, and refusing would blank
        -- the tab -- but it is not committed to memory, so the next lookup
        -- asks again rather than inheriting a guess.
        -- A ROW THE CLIENT WILL NEVER NAME IS NOT THE CLIENT BEING COLD.
        -- 0.75.0.
        --
        -- `Loremaster.Scan` only ever writes rows; it never deleted one. So
        -- an achievement retired in a game patch keeps its row for the life
        -- of the account and `GetAchievementName` returns nil for it FOREVER
        -- -- which made `named == rows` permanently false and the index
        -- permanently empty. Every lookup then paid the full walk this cache
        -- exists to avoid: on every provider rebuild, every two-second tab
        -- refresh, and inside the criteria debounce.
        --
        -- 0.73.0's `named == 0` was too loose; 0.74.0's `named == rows` was
        -- too tight in the one direction that never heals. The rows that have
        -- never answered in this session are excluded from the denominator,
        -- and one live answer removes a row from that set permanently.
        -- A WALK THAT NAMED NOTHING IS THE CLIENT BEING COLD, NOT A STORE
        -- FULL OF RETIRED ACHIEVEMENTS -- so it marks nothing and settles
        -- nothing. That floor is 0.73.0's rule and it is still needed.
        if named > 0 then
            for _, id in ipairs(refused) do
                if everNamed[id] == nil then
                    -- FIRST REFUSAL: NOTED, BUT NOT YET FORGIVEN.
                    --
                    -- It is recorded as provisionally retired and
                    -- deliberately NOT counted in `retired` on this walk, so
                    -- the walk that DISCOVERS a refusal is never decisive.
                    -- If the zone's own achievement is the row that refused,
                    -- caching here would cache its absence.
                    --
                    -- The next walk counts it and can settle. One extra walk
                    -- per retired row per session, once, in exchange for
                    -- never remembering a list a refusal might have holed.
                    -- One live answer at any later point promotes it out of
                    -- this set for good.
                    everNamed[id] = false
                end
            end
        end

        local decisive = named > 0 and named == rows - retired

        if not decisive then
            DebugPrint("Loremaster zone walk: the client named " .. named
                .. " of " .. rows .. "; answering but not remembering it.")
        end

        -- Sorted so the list itself does not carry hash order into anything
        -- that reads it, and remembered even when EMPTY: a dungeon, a raid
        -- and a capital have no achievement named after them, and those are
        -- the places `CRITERIA_UPDATE` fires hardest, so caching only the
        -- hits would leave the full walk running on the events that can
        -- least afford it.
        table.sort(matches, function(a, b) return a.id < b.id end)

        if decisive then
            zoneIndex[slot] = { zone = needle, matches = matches }
        end
    end

    -- A CANDIDATE KNOWN TO BELONG SOMEWHERE ELSE IS NOT A CANDIDATE HERE.
    -- 0.75.0.
    --
    -- The only thing a binding does. Nothing is promoted, so a binding
    -- learned in an unambiguous zone -- where both candidates belong to this
    -- same map -- excludes neither and changes nothing.
    local here = type(key) == "number" and key or nil

    local best, bestID, bestName

    for _, match in ipairs(matches) do
        local record = store[match.id]

        local belongsTo = here and Loremaster.ZoneOfAchievement(match.id)

        if record and (not belongsTo or belongsTo == here)
            and Loremaster.BetterZoneMatch(record, match.name, match.id,
                                           best, bestName, bestID) then

            best, bestID, bestName = record, match.id, match.name
        end
    end

    return best, bestID, matches, key
end

Loremaster.ZoneRecord = ZoneRecord

-- ONE LOOKUP, USED BY THE DISPLAY AND BY THE WRITE. 0.71.0.
--
-- `ForZone` had its own copy of the name match, and 0.70.0 added a second,
-- stricter one for the write path -- so the tab picked a record and the
-- refresh picked nothing, and the number on screen was one nothing could
-- move. Two copies of one rule, drifted before the release that added the
-- second one had shipped.
--
-- The `mapID` argument survives for callers that ask about a zone they are
-- not standing in; the current-zone case, which is every caller today, goes
-- through the learned index.
function Loremaster.ForZone(mapID)
    local record, id

    -- ONE MATCH, ONE ORDERING, ONE PLACE. 0.72.0.
    --
    -- This branch used to carry its own copy of both: a PLAIN SUBSTRING test
    -- where the current-zone path anchors at the end, and an inlined
    -- duplicate of `BetterZoneMatch`. So a caller asking about "Shadowmoon"
    -- got Shadowmoon Valley, and the two orderings were already free to
    -- drift -- in a release whose notes say "one lookup now".
    --
    -- It was also unreachable: every caller in the addon passes nothing.
    -- Untested code that gives a different answer from its neighbour, sitting
    -- where the next caller will find it.
    if mapID and mapID ~= CN.GetPlayerPosition() then
        -- RESOLVED FIRST, SO A MAP WITH NO NAME IS AN ANSWER OF NONE. 0.73.0.
        --
        -- `ZoneRecord` defaults a nil argument to `GetZoneText()`, so passing
        -- the result of a failed `GetMapName` straight in handed a caller
        -- asking about zone X the record for the zone the player is standing
        -- in, with nothing saying so.
        local named = Blizzard.GetMapName(mapID)

        if not named or named == "" then
            return nil
        end

        record, id = ZoneRecord(named,
            (Blizzard.ZoneMapID and Blizzard.ZoneMapID(mapID)) or mapID)
    else
        record, id = ZoneRecord()
    end

    if not record or not id then
        return nil
    end

    return {
        id        = id,
        name      = Loremaster.NameOf(id, record),
        completed = record.completed,
        done      = Loremaster.DoneFor(record) or 0,
        criteria  = record.criteria or 0,
    }
end

------------------------------------------------------------
-- WHICH ZONE NEXT
------------------------------------------------------------

-- The addon could answer "what next" and "where in this zone", and had
-- nothing at all to say about "which zone".
--
-- That is the question somebody working through a continent asks every time
-- they finish one, and answering it badly is worse than not answering: the
-- wrong zone is twenty minutes of flying and a level range that wastes the
-- quests. So it is built from things the client will actually vouch for --
-- how much of each zone's quest achievement is done, how big what remains
-- is, and whether the zone feeds something you said you were chasing -- and
-- it says which of those reasons applied.

-- A zone you are most of the way through beats a fresh one, because
-- finishing is cheaper than starting and leaves fewer loose ends behind.
Loremaster.nearlyDoneFraction = 0.6

function Loremaster.NextZones(limit)
    -- The one caller that wants room held for zones not yet begun; see the
    -- note on `Closest`. A quarter of the list, which is the share a player
    -- sweeping a continent needs and the two "closest to finished" surfaces
    -- must not have.
    local rows = Loremaster.Closest(50, 12)

    local chased = {}

    -- Anything pinned as a goal makes the zone that serves it worth more.
    local goals = CN:GetModule("Goals")

    if goals then
        for _, goal in ipairs(goals.List()) do
            if goal.type == CN.objectiveTypes.ACHIEVEMENT then
                chased[goal.id] = true
            end
        end
    end

    local currentZone = Loremaster.ForZone()

    -- THE ZONE YOU ARE STANDING IN IS ALWAYS A CANDIDATE. 0.72.0.
    --
    -- "You are already here" is worth two points and costs nothing to act on,
    -- and it could only be awarded to a zone that had already survived the
    -- truncation above -- so on the account with the most zones in progress,
    -- which is the one that most needs the advice, the cheapest suggestion
    -- available was the one most likely to be cut before it could be made.
    local carrying = false

    for _, row in ipairs(rows) do
        if currentZone and row.id == currentZone.id then
            carrying = true
            break
        end
    end

    if currentZone and not carrying and (currentZone.criteria or 0) > 0
        and not currentZone.completed
        and currentZone.done < currentZone.criteria then

        table.insert(rows, {
            id       = currentZone.id,
            name     = currentZone.name,
            category = Loremaster.CategoryOf(Records()[currentZone.id]),
            done     = currentZone.done,
            criteria = currentZone.criteria,
            fraction = currentZone.done / currentZone.criteria,
        })
    end

    local scored = {}

    for _, row in ipairs(rows) do
        local reasons = {}

        local value = 0

        if row.fraction >= Loremaster.nearlyDoneFraction then
            value = value + 3
            table.insert(reasons, string.format(
                "%s done" .. CN.DASH .. "finishing is cheaper than starting",
                CN.PercentText(row.fraction)))
        elseif row.done > 0 then
            value = value + 1
            table.insert(reasons, string.format("%d of %d done",
                row.done, row.criteria))
        else
            table.insert(reasons, string.format(
                "not started, %d to do", row.criteria))
        end

        if chased[row.id] then
            value = value + 4
            table.insert(reasons, "you are chasing this")
        end

        -- The zone you are standing in costs nothing to reach.
        if currentZone and currentZone.id == row.id then
            value = value + 2
            table.insert(reasons, "you are already here")
        end

        -- A small remainder is a session; a large one is a project.
        local remaining = row.criteria - row.done

        if remaining <= 5 then
            value = value + 1
            table.insert(reasons, remaining .. " left")
        end

        table.insert(scored, {
            id        = row.id,
            name      = row.name,
            done      = row.done,
            criteria  = row.criteria,
            fraction  = row.fraction,
            remaining = remaining,
            value     = value,
            here      = currentZone and currentZone.id == row.id or false,
            reasons   = reasons,
        })
    end

    table.sort(scored, function(a, b)
        if a.value ~= b.value then
            return a.value > b.value
        end

        if a.fraction ~= b.fraction then
            return a.fraction > b.fraction
        end

        return tostring(a.name) < tostring(b.name)
    end)

    limit = limit or 5

    while #scored > limit do
        table.remove(scored)
    end

    return scored
end

CN:RegisterCommand{
    name    = "zones",
    aliases = { "nextzone", "wherenext" },
    args    = "[forget]",
    order   = 15,
    help    = "Which zone to work on next, and why.",
    handler = function(args)
        -- A WAY OUT OF A WRONG BINDING. 0.75.0.
        --
        -- 0.74.0 published `ForgetBindings` with a comment saying it was
        -- there "so `/cn reset` can clear what was learned" -- and there is
        -- no `/cn reset` in this addon and nothing called it. A persisted
        -- store that can be wrong, with no way for the player to clear it,
        -- is the shape this project has written five migrations to undo.
        --
        -- Bindings also re-learn themselves from newer evidence, so this is
        -- a shortcut rather than the only repair; but a player who can see
        -- the wrong answer should not have to wait for the right quest.
        if string.lower(CN.Trim(args or "")) == "forget" then
            local cleared = Loremaster.ForgetBindings()

            Loremaster.ForgetZoneIndex()

            Print("Forgot " .. cleared .. CN.Pluralize(cleared,
                " learned zone.", " learned zones."))
            Print("|cff8a8f96They are learned again as you quest.|r")
            return
        end

        local rows = Loremaster.NextZones(6)

        if #rows == 0 then
            Print("No unfinished zone achievements are recorded yet.")
            -- `/cn loremaster scan` is not a command. `loremaster` treats
            -- any argument that is not `all` or `zone` as a NAME FILTER, so
            -- that line sent the player to "Nothing matched."
            Print("|cff8a8f96Run |cffffc74f/cn scanlore|r"
                .. "|cff8a8f96 to read them from the game.|r")
            return
        end

        Print("Zones worth doing next:")

        for index, row in ipairs(rows) do
            CN.PrintLine(string.format("  %d. %s%s|r  |cff8a8f96%d/%d|r",
                index,
                row.here and "|cff5dd2fb" or "|cffffc74f",
                tostring(row.name),
                row.done, row.criteria))

            CN.PrintLine("     " .. CN.Muted(table.concat(CN.Reasons(row), "; ")))
        end

        Print("|cff8a8f96Ordered by what is cheapest to finish, not by size. "
            .. "Zones you have not started are included" .. CN.DASH .. "an earlier version "
            .. "left them out entirely.|r")
    end,
}

------------------------------------------------------------
-- THE STORY, AS DISTINCT FROM EVERYTHING ELSE
------------------------------------------------------------

-- "Finish the story, then do the side quests" is how players actually talk,
-- and the client knows which quests are campaign quests. Splitting the zone's
-- work along that line costs one API call per quest and matches the plan the
-- player already has in their head.
-- `quiet` is passed straight through to `Quests.AvailableOnMap`: this is a
-- read, and the Journey tab's refresh runs with the window closed whenever
-- somebody types `/cn find`. 0.70.0.
function Loremaster.SplitZoneWork(mapID, quiet)
    local quests = CN:GetModule("Quests")

    if not quests then
        return { story = {}, side = {} }
    end

    local split = { story = {}, side = {} }

    for _, poi in ipairs(quests.AvailableOnMap(mapID, quiet)) do
        if Blizzard.IsQuestCampaign(poi.questID) then
            table.insert(split.story, poi)
        else
            table.insert(split.side, poi)
        end
    end

    return split
end

------------------------------------------------------------
-- CANDIDATES
------------------------------------------------------------

-- A zone achievement you are most of the way through is a genuine next
-- action: three quests from Loremaster is worth knowing about while you are
-- standing in the zone, and worthless as a line in a list of four hundred.
CN.RegisterCandidateProvider("Loremaster", function()
    local candidates = {}

    local zone = Loremaster.ForZone()

    if not zone or zone.completed or (zone.criteria or 0) == 0 then
        return candidates
    end

    local remaining = zone.criteria - zone.done

    if remaining <= 0 or remaining > 10 then
        return candidates
    end

    -- THE ONE PROVIDER THAT DID NOT HONOUR THE IGNORE LIST.
    --
    -- Twenty-one of the twenty-two check these at build time; nothing
    -- downstream filters an ignored objective, so a provider that skips the
    -- check makes Ignore a silent no-op for its rows.
    --
    -- Worse here than elsewhere: this emits a real achievement id in the same
    -- namespace the Achievements provider uses, so hiding a zone achievement
    -- removed it from Achievements, this re-emitted it, and the aggregate
    -- kept it. The player hid something and it stayed.
    if CN.IsIgnored(CN.objectiveTypes.ACHIEVEMENT, zone.id)
        or CN.IsDeferred(CN.objectiveTypes.ACHIEVEMENT, zone.id) then

        return candidates
    end

    local mapID = select(1, CN.GetPlayerPosition())

    table.insert(candidates, CN.NewObjective({
        id              = zone.id,
        type            = CN.objectiveTypes.ACHIEVEMENT,
        name            = zone.name,
        mapID           = mapID,
        accountWide     = false,
        completionValue = 4,
        reasons         = {
            remaining .. " of " .. zone.criteria .. " left in this zone",
        },
    }))

    return candidates
end, { events = { "ZONE_CHANGED_NEW_AREA", "CRITERIA_UPDATE" }, cooldown = 5 })

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

local function PrintAchievement(entry, indent)
    local bar = ""

    if (entry.criteria or 0) > 0 then
        local fraction = entry.done / entry.criteria

        bar = " |cff5dd2fb" .. CN.ProgressBar(fraction, 12) .. "|r "
            .. entry.done .. "/" .. entry.criteria
    end

    Print((indent or "  ")
        .. (entry.completed and "|cff73b873" or "|cffffc74f")
        .. tostring(entry.name) .. "|r" .. bar)
end

CN:RegisterCommand{
    name    = "loremaster",
    -- "zones" REMOVED. It was registered as its own command 120 lines up --
    -- "Which zone to work on next, and why" -- and this alias, loading later,
    -- overwrote it. So `/cn zones` printed the quest-completion-by-zone
    -- report while `/cn help` and the store page both described the zone
    -- ranking, and the real command was reachable only as `/cn nextzone`.
    aliases = { "lore" },
    args    = "[all, zone, or a name to filter]",
    order   = 12,
    help    = "Quest completion by zone, continent and expansion.",
    handler = function(args)
        args = CN.Trim(args or "")

        if CN.CountKeys(Records()) == 0 then
            Print("No quest achievements scanned yet. Running a scan now.")
            Loremaster.Scan()
        end

        if string.lower(args) == "zone" or args == "" then
            local zone = Loremaster.ForZone()

            if zone then
                Print("This zone:")
                PrintAchievement(zone)
            end

            local split = Loremaster.SplitZoneWork()

            if #split.story > 0 or #split.side > 0 then
                Print("Available here: |cffffc74f" .. #split.story
                    .. "|r story, |cffffc74f" .. #split.side .. "|r side.")
            end

            if args ~= "" then
                return
            end

            local closest = Loremaster.Closest(8)

            if #closest > 0 then
                Print("Closest to finished:")

                for _, entry in ipairs(closest) do
                    PrintAchievement(entry)
                end
            end

            -- AND ZONES NOT YET BEGUN, SAID TO BE THAT. 0.74.0.
            --
            -- They used to fill whatever room the list above left, printed
            -- under "Closest to finished" reading `0 / 120` -- which is the
            -- one thing they are not. Shown, and labelled.
            local unstarted = {}

            for _, entry in ipairs(Loremaster.Closest(4, 4)) do
                if (entry.done or 0) == 0 then
                    table.insert(unstarted, entry)
                end
            end

            if #unstarted > 0 then
                Print("Not started:")

                for _, entry in ipairs(unstarted) do
                    PrintAchievement(entry)
                end
            end

            if #closest == 0 and #unstarted == 0 then
                Print("Nothing left to finish, and nothing new to begin.")
            end

            Print("|cff8a8f96/cn loremaster all|r lists everything by expansion.")

            return
        end

        local includeCompleted = string.lower(args) == "all"

        local filter = (not includeCompleted) and string.lower(args) or nil

        local groups, order = Loremaster.ByCategory(includeCompleted)

        local shown = 0

        for _, key in ipairs(order) do
            if not filter or string.find(string.lower(key), filter, 1, true) then
                CN.PrintLine("|cffffc74f" .. key .. "|r")

                for _, entry in ipairs(groups[key]) do
                    PrintAchievement(entry, "    ")
                    shown = shown + 1
                end
            end
        end

        if shown == 0 then
            Print("Nothing matched. Try |cffffc74f/cn loremaster all|r.")
        end
    end,
}

CN:RegisterCommand{
    name    = "scanlore",
    order   = 27,
    help    = "Rescan quest achievements by zone and expansion.",
    handler = function()
        local scanned, measured = Loremaster.Scan()

        if measured == 0 then
            Print("The game would not answer about criteria just now"
                .. CN.DASH .. "nothing was recorded.")
            Print("|cff8a8f96Try again in a few seconds; this is usual for "
                .. "the first moments after a loading screen.|r")
            return
        end

        Print("Quest achievements scanned: " .. scanned
            .. "   Measured: " .. measured)
    end,
}

-- SCANNED WHEN THE STORE IS EMPTY, OR WHEN IT IS INCOMPLETE. 0.68.0.
--
-- "Empty" was the only trigger, and after the first character it is never
-- empty again -- so a store that lost a field, or one written by a version
-- that did not record something this one reads, stayed wrong for the life of
-- the account unless the player found `/cn scanlore`. Migration 20 produced
-- exactly that state and the addon had no way back out of it.
--
-- A row with no `completed` flag is the shape of that damage, and it is also
-- the shape of a row written before the flag existed. Both want the same
-- thing.
-- THE ZONE YOU ARE IN, WHEN YOU HAND SOMETHING IN. 0.69.0.
--
-- The store was written by `Loremaster.Scan` and by nothing else, and `Scan`
-- ran at login, on `/cn scanlore`, and from the Journey tab's "Rescan zones"
-- button. So turning in a quest moved nothing: the Journey tab went on
-- reading the count it had at login, and the zone the player had just
-- advanced still said what it said an hour ago.
--
-- That is a reported symptom -- "the completion of a quest does not appear to
-- remove it from the journey" -- and it is not the recommendation list, which
-- has always been invalidated on `QUEST_TURNED_IN`. It is this store, which
-- nothing invalidated at all.
--
-- ONE ACHIEVEMENT, NOT THE TREE. A full scan walks every quest achievement in
-- the game and is why it was never put on an event. The zone the player is
-- standing in is the only row a turn-in can move, and refreshing it is two
-- client calls -- the same shape `Exploration.RefreshCurrentZone` has used
-- since 0.61.0, in the sibling store this fix never reached.
--


-- CRITERIA PROGRESS ONLY. THE EARNED FLAG IS NOT DERIVED FROM IT. 0.70.0.
--
-- 0.69.0 wrote `record.completed = (done >= criteria)`, and those two
-- quantities are scoped differently: criteria progress is what THIS character
-- has done, and the earned flag belongs to the ACCOUNT. So an alt at 3 of 12
-- standing in a zone the main had finished cleared the account's flag on the
-- way past, and `/cn zones` began recommending a zone already earned -- the
-- exact symptom two migrations were written to repair, reintroduced by the
-- code repairing it.
--
-- The client answers the account question directly, so it is asked directly.
-- WHICH ZONE A CANDIDATE BELONGS TO, FROM EVIDENCE. 0.74.0, corrected in
-- 0.75.0.
--
-- Run before the write below, because the write is what destroys the
-- evidence: once this character's progress has been brought up to date,
-- "which one moved" can no longer be asked.
--
-- WHAT 0.74.0 CALLED EVIDENCE AND WAS NOT.
--
-- It compared the live figure with `DoneFor`, which answers 0 for any row
-- this character has never scanned -- and `Scan` is skipped at login once
-- this character has a scan marker, so most rows on most characters have no
-- reading at all. `CRITERIA_UPDATE` is global: it fires for a pet battle, a
-- raid criterion, anything. So a character holding 12 of 64 on Outland's
-- Nagrand, standing in DRAENOR'S Nagrand, saw "12 ~= 0" on the Outland row
-- for any criteria update anywhere and bound the wrong zone, permanently.
--
-- "Different from a number nobody recorded" is not movement. A candidate is
-- only a mover now when this character HAS a recorded reading for it and the
-- live figure is HIGHER -- progress going backwards is not evidence either.
--
-- One mover is evidence. Two is not evidence about either of them, so
-- nothing is learned and the ordering keeps answering until a moment comes
-- along where exactly one moves.
local function LearnZoneBinding(matches, key)
    if type(key) ~= "number" or not matches or #matches < 2 then
        return false
    end

    local store = Records()

    local characterKey = CN.characterKey or CN.GetCharacterKey()

    local moved, movers = nil, 0

    for _, match in ipairs(matches) do
        local record = store[match.id]

        -- A READING THIS CHARACTER ACTUALLY MADE, not a zero standing in for
        -- one it never made.
        local before = record and record.progress
            and record.progress[characterKey]

        if before ~= nil then
            local done, criteria = Blizzard.GetAchievementProgress(match.id)

            if criteria and criteria > 0 and done and done > before then
                moved  = match.id
                movers = movers + 1
            end
        end
    end

    if movers ~= 1 then
        return false
    end

    if Loremaster.Bind(moved, key) then
        DebugPrint("Learned that achievement " .. moved
            .. " belongs to zone map " .. key .. ".")

        return true
    end

    return false
end

Loremaster.LearnZoneBinding = LearnZoneBinding

function Loremaster.RefreshCurrentZone()
    -- ONE WALK, NOT TWO. 0.75.0.
    --
    -- 0.74.0 called `ZoneRecord()` once purely to populate two module-level
    -- variables, learned from those, and called it again for the answer --
    -- two full store walks with a client call per row, inside the
    -- `CRITERIA_UPDATE` debounce body, every two seconds while questing.
    -- `ZoneRecord` returns its candidate list now, so there is nothing to go
    -- and fetch.
    local record, id, matches, zoneMap = ZoneRecord()

    local learned = LearnZoneBinding(matches, zoneMap)

    if not record or not id then
        return learned
    end

    local done, criteria = Blizzard.GetAchievementProgress(id)

    -- NOT OVER GOOD DATA WITH NOTHING. A refusal from the criteria API
    -- answers `0, 0`, and writing that in loses the row -- the guard
    -- `Exploration` carries, and the one `Achievements` was given in 0.68.0
    -- after it did exactly this.
    if not criteria or criteria <= 0 then
        return learned
    end

    local key = CN.characterKey or CN.GetCharacterKey()

    -- NORMALIZED, SO "NEVER SEEN" IS NOT "CHANGED". 0.73.0.
    --
    -- This read the raw table entry, which is nil for any row this character
    -- has not scanned -- so `before ~= done` was true even when `done` was 0
    -- and nothing had moved, costing one spurious
    -- `CN.InvalidateProvider("Loremaster")` per zone per character.
    -- `DoneFor` is the function that owns "what has this character done",
    -- and it answers 0 rather than nil.
    local before = Loremaster.DoneFor(record) or 0

    record.criteria = criteria

    record.progress = record.progress or {}
    record.progress[key] = done

    -- ASKED, NOT INFERRED. And left alone when the client will not answer,
    -- rather than guessed at from the numbers above.
    local earned = Blizzard.IsAchievementEarned and Blizzard.IsAchievementEarned(id)

    if earned ~= nil then
        record.completed = earned
    end

    return learned or before ~= done
end

-- `CRITERIA_UPDATE`, NOT `QUEST_TURNED_IN`. 0.70.0.
--
-- 0.69.0 wired this to the turn-in, which fires BEFORE the client has moved
-- the criteria -- and `CN.Debounce` is leading-edge, so the single-turn-in
-- case ran once, immediately, and read the number it already had. The fix for
-- a reported symptom did nothing for the ordinary form of it.
--
-- `CRITERIA_UPDATE` is the event that fires when the criteria actually move,
-- and it is what the sibling this was modelled on has always used. Reading
-- one file and copying half of it is how this project keeps producing the
-- same defect.
--
-- AND IT TELLS THE RANKING. A store change that dispatches nothing leaves the
-- provider's cached row saying "8 of 12 left" until a zone change -- which is
-- the other half `Exploration` does and this did not.
CN:RegisterEvent("CRITERIA_UPDATE", function()
    CN.Debounce("Loremaster.zone", 2, function()
        local ok, moved = pcall(Loremaster.RefreshCurrentZone)

        if ok and moved then
            CN.InvalidateProvider("Loremaster")
        end
    end)
end)

CN:OnLogin(function()
    local records = Records()

    if CN.CountKeys(records) == 0 then
        Loremaster.Scan()

        return
    end

    -- AND ON THIS CHARACTER'S OWN DIMENSION. 0.69.0.
    --
    -- `completed` is account-wide, so once ANY character has repaired it no
    -- other character ever triggers a rescan again -- and `progress` is
    -- per-character, which is precisely what an alt is missing. So the first
    -- character to log in after an upgrade fixed the store for itself and
    -- locked every other character out of the repair: `/cn zones` reported
    -- "not started, 120 to do" for zones an alt had fully quested.
    --
    -- ASKED OF A MARKER, NOT OF THE ROWS. 0.70.0. The first version walked
    -- the store looking for a row missing this character's progress -- and
    -- `Scan` only writes progress for rows the category walk returns, so a
    -- row it cannot reach keeps that entry nil for ever and the condition was
    -- true on every login, of every character, for the life of the account.
    -- A full tree walk per login, to discover that a retired achievement is
    -- still retired.
    local key = CN.characterKey or CN.GetCharacterKey()

    if not CN.Account("loremasterScans")[key] then
        Loremaster.Scan()

        return
    end

    -- The account-wide half stays a row check: it repairs a store that lost
    -- the flag, which is a thing that happened once, to everybody.
    for _, record in pairs(records) do
        if type(record) == "table" and record.completed == nil then
            Loremaster.Scan()

            return
        end
    end
end)

return Loremaster
