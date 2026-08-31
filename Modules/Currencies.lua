-- Modules/Currencies.lua
-- Completion Navigator :: currencies, caps, and wasted earning potential.
--
-- A currency total on its own is not a decision. What matters is whether you
-- are at a cap, because a capped currency is earning potential you are
-- throwing away, and a weekly cap you have not filled resets in a few days
-- whether you use it or not.
--
-- Both of those are time-sensitive, which is why this module contributes to
-- the opportunity side of the scoring rather than sitting in a list.

local ADDON_NAME, CN = ...

local Currencies = CN:RegisterModule("Currencies")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

-- Currency quantities are character state; which currencies exist is not.
-- A currency's name, from the client. Seventh store to get one of these; see
-- `Achievements.NameOf` for the first. 0.65.0.
--
-- NO FALLBACK TO A STORE. `CN.Account(key)` CREATES the table it is asked
-- for, so any reader left pointing at `currencyNames` resurrects the store
-- migration 18 deleted -- an empty one, on every login, forever. The client
-- answers this instantly and in the player's own language; there is nothing
-- for a fallback to add.
function Currencies.NameOf(currencyID)
    local info = CN.Blizzard.GetCurrency and CN.Blizzard.GetCurrency(currencyID)

    if info and info.name and info.name ~= "" then
        return info.name
    end

    return "Currency " .. tostring(currencyID)
end

local function CharacterStore(character)
    character = character or CN.character

    if not character then
        return nil
    end

    character.currencies = character.currencies or {}

    return character.currencies
end

Currencies.CharacterStore = CharacterStore

------------------------------------------------------------
-- SCAN
------------------------------------------------------------

-- A CURRENCY THE CLIENT HAS STOPPED LISTING IS NOT A CURRENCY YOU CAN SPEND.
--
-- `GetCurrencyList` is the currency UI tree, and things leave it: a season
-- ends, an expansion's currency is retired, one migrates to the Warband. The
-- store was write-only-grow -- one row per currency ever seen, never removed
-- -- and `Capped` walked all of it with no freshness check.
--
-- So a currency capped last season kept producing "at cap, further earning is
-- wasted until you spend it", every five seconds because this provider is
-- volatile, with a fresh weekly urgency bonus every reset, for the life of
-- the character. The player could not satisfy it and could not make it go
-- away except with `/cn ignore`.
--
-- A serial per sweep is the whole fix: a row the last scan did not see is not
-- reported on. `lastSeen` was already being written and was read by nothing
-- anywhere in the tree, which is why this went unnoticed.
-- PERSISTED, or a reload would leave every row looking stale until the login
-- scan ran -- a window in which `/cn currencies` would report nothing at all.
local function Serials()
    local account = CN.Account()

    account.currencyScans = account.currencyScans or {}

    return account.currencyScans
end

-- The counter for a NAMED character, not always the logged-in one.
--
-- `Capped`, `WeeklyUnfilled` and `Summary` all accept an explicit character,
-- and comparing an alt's rows against the current character's counter filters
-- every one of them out -- so an alt would have reported zero capped
-- currencies and zero unfilled weeklies. No caller passes one today, which is
-- the only reason this was latent rather than live.
-- REALM FIRST, LIKE EVERY OTHER CHARACTER KEY IN THE ADDON. 0.62.0.
--
-- `CN.GetCharacterKey` is `realm .. "-" .. name`, and this built
-- `name .. "-" .. realm` -- so the key matched nothing, `CurrentSerial` came
-- back 0, and the paragraph above describes precisely the symptom that
-- produces. The comment was written about the bug being fixed; the code kept
-- it. Latent only because nothing passes a character yet, which is the reason
-- to correct it now rather than when the first caller trips over it.
--
-- Built through the one function that owns the format, so the two cannot
-- drift again.
local function KeyFor(character)
    if character and character.name and character.realm then
        return CN.CharacterKeyFor(character.realm, character.name)
    end

    return CN.characterKey or "?"
end

local function CurrentSerial(character)
    return Serials()[KeyFor(character)] or 0
end

local function NextSerial()
    local key = CN.characterKey or "?"

    Serials()[key] = CurrentSerial() + 1

    return Serials()[key]
end

Currencies.CurrentSerial = CurrentSerial

-- A row is current if the last sweep saw it.
--
-- NO EXEMPTION FOR ROWS WRITTEN BEFORE SERIALS EXISTED. The first version of
-- this treated an unstamped row as current "until the next scan rewrites
-- them" -- and the premise is wrong in exactly the case the feature is for:
-- a currency the client no longer lists is precisely the row the next scan
-- will NOT rewrite. So the fix worked on a fresh install and did nothing at
-- all for anybody upgrading, which is everybody.
--
-- Migration 13 stamps every existing row with serial 0 instead, and the
-- login scan then stamps the live ones with 1. Nothing is lost: the login
-- scan runs before anything reads this.
local function IsCurrent(record, character)
    if type(record) ~= "table" then
        return false
    end

    return record.serial == CurrentSerial(character)
end

Currencies.IsCurrent = IsCurrent

-- When the last sweep ran. Declared here, ABOVE its first use: a local
-- declared below the line that assigns it is not the same variable -- the
-- assignment creates a global and the throttle silently stops working.
local lastScan = 0

-- Every scan stamps the throttle, whichever path asked for it. Before this,
-- the login scan and the manual one both left the timestamp alone, so the
-- next coin picked up ran a second full sweep. 0.65.0.
function Currencies.Scan()
    local mine = CharacterStore()

    if not mine then
        lastScan = time()

        return 0, 0, 0
    end

    local list = Blizzard.GetCurrencyList()

    -- A REFUSAL IS NOT AN EMPTY CURRENCY LIST. 0.88.0.
    --
    -- THE SERIAL *IS* THE PRUNE: `IsCurrent` compares a row's serial against
    -- the current one, and `Capped`, `WeeklyUnfilled` and `CurrentCount` all
    -- gate on it. Bumping it with nothing to stamp therefore retires every
    -- stored currency at once -- while the rows sit intact on disk.
    --
    -- `Blizzard.GetCurrencyList` answers with an empty table on four ordinary
    -- refusal paths, one of which is a size of zero -- which is what the
    -- client returns while currency data is still streaming at login, which
    -- is exactly when `CN:OnLogin` runs this.
    --
    -- `Achievements` has carried this guard since 0.76.0, `Exploration` since
    -- 0.61.0 and `Loremaster` since 0.71.0, and the note on the first of them
    -- says why: "a cold scan that read nothing would otherwise delete every
    -- row it could not confirm". Fourth writer of the same idea, no guard.
    --
    -- The throttle is not stamped either, so the next coin picked up retries
    -- rather than waiting out a minute on an answer that was never given.
    if #list == 0 then
        DebugPrint("Currency sweep answered for nothing; not recording it.")

        return 0, 0, 0
    end

    lastScan = time()

    local serial = NextSerial()

    local seen, atCap, weeklyRemaining = 0, 0, 0

    for _, currency in ipairs(list) do
        if currency.currencyID then
            -- `currencyNames` IS NOT WRITTEN ANY MORE. 0.65.0.
            --
            -- 0.64.0 gave every reader a live client path and left the writer
            -- alone, so the store kept filling with names frozen at whatever
            -- language last scanned -- and `Currencies.Resolve`, which
            -- searches only the store, could not find a player's own
            -- currencies by name after a language change.
            --
            -- Seventh store to lose a name it did not need to keep.

            -- THE CAP APPLIES TO WHAT THE CLIENT SAYS IT APPLIES TO. 0.62.0.
            --
            -- `useTotalEarnedForMaxQty` is read from the client in
            -- BlizzardWorld.lua and was then neither stored nor consulted, so
            -- every currency was tested as `quantity >= maxQuantity`. For the
            -- currencies whose cap is on LIFETIME or SEASONAL earnings, a
            -- player who has hit the cap and then spent the balance was told
            -- they were not capped -- so `/cn currencies` and the currency
            -- provider stayed silent about earning that is now being thrown
            -- away, which is the one thing this row exists to warn about.
            -- The reason string read "at cap: 1200 / 2500", which is its own
            -- contradiction.
            local against = currency.useTotalEarnedForMaxQty
                and (currency.totalEarned or 0)
                or currency.quantity

            local capped = currency.maxQuantity > 0
                and against >= currency.maxQuantity

            local weeklyLeft = 0

            if currency.maxWeeklyQuantity > 0 then
                weeklyLeft = math.max(0,
                    currency.maxWeeklyQuantity - currency.earnedThisWeek)
            end

            mine[currency.currencyID] = {
                currencyID        = currency.currencyID,
                quantity          = currency.quantity,
                maxQuantity       = currency.maxQuantity,
                totalEarned       = currency.totalEarned,
                earnedThisWeek    = currency.earnedThisWeek,
                maxWeeklyQuantity = currency.maxWeeklyQuantity,
                capped            = capped,

                -- Which quantity the cap is measured against, so every
                -- reader agrees with the flag above rather than recomputing
                -- it from the wrong field.
                cappedAgainst     = against,
                usesTotalEarned   = currency.useTotalEarnedForMaxQty or nil,
                accountWide       = currency.accountWide or nil,
                weeklyRemaining   = weeklyLeft,
                -- `lastSeen` IS NOT STORED. 0.91.0.
            --
            -- The note at the top of this file already says it: "`lastSeen`
            -- was already being written and was read by nothing anywhere in
            -- the tree". The serial replaced it and the write survived.
            -- Migration 5 stripped this field from four stores, 31 from
            -- appearances, 32 from mounts and reputations, 33 from
            -- exploration; `currencies` was in none of the four sweeps and
            -- its writer was live, so this was one integer per currency per
            -- character rewritten at every logout, forever.

                -- Which sweep last saw it. See the header above `Scan`.
                serial            = serial,
            }

            seen = seen + 1

            if capped then
                atCap = atCap + 1
            end

            if weeklyLeft > 0 then
                weeklyRemaining = weeklyRemaining + 1
            end
        end
    end

    CN.MarkScanned("currencies")

    return seen, atCap, weeklyRemaining
end

------------------------------------------------------------
-- QUERIES
------------------------------------------------------------

function Currencies.Capped(character)
    local capped = {}

    for currencyID, record in pairs(CharacterStore(character) or {}) do
        if record.capped and IsCurrent(record, character) then
            table.insert(capped, {
                currencyID = currencyID,
                name       = Currencies.NameOf(currencyID),
                -- THE NUMBERS THE CAP WAS MEASURED AGAINST. 0.63.0.
                --
                -- 0.62.0 fixed the DETECTION -- a currency whose cap applies
                -- to lifetime earnings is tested against `totalEarned` -- and
                -- then this function went on exporting `quantity` and
                -- `maxQuantity` for display. So the fix produced a row that
                -- was correctly flagged and then printed its own
                -- contradiction: "At cap - spend these: Foo 100 / 2500".
                --
                -- `cappedAgainst` was stored by that release and read by
                -- nothing, which is what a half-finished fix looks like in a
                -- grep. It is the display value now, and `held` carries the
                -- balance separately for anything that wants to say how much
                -- there is to spend.
                quantity   = record.cappedAgainst or record.quantity,
                maximum    = record.maxQuantity,
                held       = record.quantity,
                earned     = record.totalEarned,

                -- So a reader can say WHY the two differ rather than leaving
                -- the player to work it out.
                usesTotalEarned = record.usesTotalEarned or nil,

                -- CARRIED THROUGH, WHICH IT WAS NOT.
                --
                -- The candidate provider reads `accountWide` off these rows
                -- under a long comment explaining that ignoring the flag was
                -- "the exact mistake the Warband work exists to prevent" --
                -- and this function, the only thing that builds those rows,
                -- never copied it. The flag was read from the client
                -- correctly, stored correctly, and dropped here. So a
                -- Warband currency capped on your main was still recommended
                -- on every alt, which is precisely the behaviour 0.43.0
                -- claimed to have fixed.
                accountWide = record.accountWide and true or false,
            })
        end
    end

    table.sort(capped, function(a, b) return (a.name or "") < (b.name or "") end)

    return capped
end

function Currencies.WeeklyUnfilled(character)
    local rows = {}

    for currencyID, record in pairs(CharacterStore(character) or {}) do
        if record.weeklyRemaining and record.weeklyRemaining > 0
            and IsCurrent(record, character) then
            table.insert(rows, {
                currencyID = currencyID,
                name       = Currencies.NameOf(currencyID),
                remaining  = record.weeklyRemaining,
                earned     = record.earnedThisWeek,
                maximum    = record.maxWeeklyQuantity,
            })
        end
    end

    table.sort(rows, function(a, b) return (a.remaining or 0) > (b.remaining or 0) end)

    return rows
end

function Currencies.Summary(character)
    return {
        -- COUNTED OVER THE SAME POPULATION AS THE OTHER TWO. 0.64.0.
        --
        -- `known` counted every row in the store while `capped` and
        -- `weeklyUnfilled` counted only rows the client still lists -- so
        -- `/cn breakdown` printed `known - capped`, a subtraction across two
        -- different populations, and could report more capped currencies than
        -- known ones.
        known           = Currencies.CurrentCount(character),
        capped          = #Currencies.Capped(character),
        weeklyUnfilled  = #Currencies.WeeklyUnfilled(character),
    }
end

-- How many rows the client still lists. See the note in `Summary`.
function Currencies.CurrentCount(character)
    local count = 0

    for _, record in pairs(CharacterStore(character) or {}) do
        if IsCurrent(record, character) then
            count = count + 1
        end
    end

    return count
end

function Currencies.Resolve(text)
    local currencyID = CN.ToID(text)

    if currencyID and CharacterStore() and CharacterStore()[currencyID] then
        return currencyID
    end

    if not text or text == "" then
        return nil
    end

    local needle  = string.lower(text)
    local matches = {}

    -- SEARCHED OVER WHAT THIS CHARACTER HAS, NAMED LIVE. 0.65.0.
    --
    -- This searched the stored name table, which no longer fills -- and even
    -- before that it was frozen at the last scan's language, so a player who
    -- changed client language could not find their own currencies by name.
    for id in pairs(CharacterStore() or {}) do
        local name = Currencies.NameOf(id)

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
-- CANDIDATES
------------------------------------------------------------

-- A capped currency is not a place to travel to, so these carry no
-- coordinates. They surface as high-priority advisories: stop earning this
-- and go spend it.
CN.RegisterCandidateProvider("Currencies", function()
    local candidates = {}

    for _, currency in ipairs(Currencies.Capped()) do
        if not CN.IsIgnored(CN.objectiveTypes.CURRENCY, currency.currencyID)
            and not CN.IsDeferred(CN.objectiveTypes.CURRENCY, currency.currencyID) then

            -- ACCOUNT-WIDE CURRENCIES ARE ACCOUNT-WIDE (0.43.0).
            --
            -- The client flags these and the addon ignored the flag, so a
            -- Warband currency capped on one character was recommended again
            -- on every other one -- the exact mistake the Warband work exists
            -- to prevent, in the one store that had not been told about it.
            local shared = currency.accountWide

            table.insert(candidates, CN.NewObjective({
                id               = currency.currencyID,
                type             = CN.objectiveTypes.CURRENCY,
                name             = "Spend " .. tostring(currency.name)
                    .. (shared and " (Warband)" or ""),
                accountWide      = shared and true or false,
                completionValue  = 2,

                -- ONE DEADLINE, ONE CURVE. 0.89.0. `expiresIn` below is the
                -- weekly reset and the note beside it says why -- so this
                -- charged the same reset a second time, through a shape
                -- `/cn urgency` does not plot. Fifth row in the addon to do
                -- it; a sweep in the harness now covers every provider.
                limitedTimeBonus = 0,
                travelCost       = 0,

                -- A capped currency is not "expiring", but every hour spent
                -- at cap is earning thrown away, and the weekly reset is when
                -- that waste is realised. Treating the reset as its deadline
                -- makes the urgency curve say the true thing: this matters
                -- more on Monday night than on Wednesday morning.
                expiresIn        = CN.Blizzard.GetSecondsUntilWeeklyReset(),

                reasons          = {
                    "at cap: " .. tostring(currency.quantity)
                        .. " / " .. tostring(currency.maximum)
                        .. (currency.usesTotalEarned and " earned" or ""),
                    "further earning is wasted until you spend it",
                },
            }))
        end
    end

    return candidates
-- A COOLDOWN, BECAUSE THIS EVENT FIRES ON EVERY COIN PICKED UP. 0.78.0.
--
-- This file's own note six lines down says exactly that, which is why the
-- SCAN is throttled to sixty seconds -- and the provider had no cooldown at
-- all, so it was marked dirty and rebuilt on every firing, each rebuild
-- walking the whole character store through `Capped()` and making a live
-- client call per capped row.
--
-- Thirty seconds costs nothing in freshness: capped-ness cannot change
-- faster than the sixty-second scan that computes it. `Modules/Rares.lua`
-- sets 5 for the same reason and `Modules/Orders.lua` sets 30.
end, { events = { "CURRENCY_DISPLAY_UPDATE" }, volatile = true, cooldown = 30 })

------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

-- SIXTY SECONDS, NOT TEN, AND NOT WHILE THE PLAYER IS LOOKING. 0.64.0.
--
-- `CURRENCY_DISPLAY_UPDATE` fires on every coin picked up, so a ten-second
-- guard meant this ran continuously through an evening -- and it is not a
-- cheap read. Each sweep makes three passes over the whole currency list,
-- recovers an id per row by building and matching a hyperlink, rewrites about
-- a hundred and fifty tables into SavedVariables, and bumps the collection
-- generation.
--
-- It also EXPANDS AND RE-COLLAPSES the player's currency headers to see rows
-- the client hides, which is the one place in this addon that changes
-- something the player can see. It puts them back -- but a player with the
-- Currency tab open watched their collapsed groups pop open and shut every
-- ten seconds, which is the addon acting rather than prompting.
--
-- So: a minute rather than ten seconds, and never while the frame whose state
-- it disturbs is on screen. A currency total that is at most a minute stale
-- costs nothing; the sweep costs a visible flicker.
Currencies.rescanSeconds = 60

-- `IsVisible`, NOT `IsShown`, AND ONLY THE CURRENCY PANEL. 0.67.0.
--
-- `IsShown` reports a region's own flag, not whether the player can see it:
-- a child of a hidden parent still answers true. `TokenFrame` is a panel
-- INSIDE `CharacterFrame`, so pressing C, clicking Currency and pressing Esc
-- left its flag set forever -- and from that moment this returned true on
-- every path, `SweepIfDue` refused on every path, and the store froze at
-- login for the rest of the session. A currency capped that evening was
-- never reported, which is the one thing this module exists to warn about.
--
-- The `or _G.CharacterFrame` fallback made it worse rather than safer: with
-- `Blizzard_TokenUI` not yet loaded it answered about the character sheet,
-- which is a different window that this sweep does not disturb.
local function CurrencyFrameOpen()
    local frame = _G.TokenFrame

    if not frame or not frame.IsVisible then
        return false
    end

    return frame:IsVisible() and true or false
end

Currencies.IsFrameOpen = CurrencyFrameOpen

-- THE ONE PLACE THAT DECIDES WHETHER A SWEEP RUNS NOW. 0.66.0.
--
-- The throttle, the open-frame deferral and the scan were spread across an
-- event handler, so the only way to reach the deferral was to dispatch a
-- currency event -- which is why the promise below ("as soon as the player
-- closes the window") was made by a comment and kept by nothing.
function Currencies.SweepIfDue()
    if time() - lastScan < Currencies.rescanSeconds then
        return false
    end

    -- Deferred rather than skipped: `lastScan` is not advanced, so the sweep
    -- happens at the next opportunity instead of a minute after this one.
    if CurrencyFrameOpen() then
        return false
    end

    Currencies.Scan()

    return true
end

-- THE LOGIN SCAN ALREADY IS THE PROMPT SWEEP. 0.66.0.
--
-- There was a `PLAYER_ENTERING_WORLD` handler here that cleared the throttle,
-- justified as "a player who reloads mid-session should not then wait a
-- minute". It could never serve that case: `PLAYER_LOGIN` runs the login
-- hooks -- including this module's `Scan()` -- and it fires BEFORE
-- `PLAYER_ENTERING_WORLD`, on a reload as on a fresh login. So the order was
-- always: sweep, stamp the throttle, throw the stamp away. The next coin
-- picked up in the first minute ran the whole three-pass sweep again, which
-- is the same double sweep 0.65.0 fixed on the manual path, arriving by the
-- other door.
--
-- What DOES need collecting is the deferral: see the frame hook below.

CN:RegisterEvent("CURRENCY_DISPLAY_UPDATE", function()
    Currencies.SweepIfDue()
end)

-- AND THE DEFERRAL IS ACTUALLY COLLECTED. 0.66.0.
--
-- The deferral above says the sweep "happens as soon as the player closes the
-- window". Nothing made that true: the only thing that reached it was the
-- next `CURRENCY_DISPLAY_UPDATE`, which arrives when the player next gains a
-- currency -- so a player who opened the Currency tab, read it, closed it and
-- went to a raid carried a store that could be an hour stale, and `/cn
-- currencies` answered from it.
--
-- No client event announces that frame closing, so the frame itself is asked.
-- Hooked once, at login, guarded, and silent if the frame does not exist --
-- the same shape every other optional client surface in this addon gets.
-- HOOKED WHEN THE FRAME EXISTS, WHICH IS NOT AT LOGIN. 0.67.0.
--
-- `Blizzard_TokenUI` is loaded on demand, so at `PLAYER_LOGIN` there is no
-- `TokenFrame` -- and the first version of this fell back to
-- `CharacterFrame`, hooked THAT, and set the "done" flag, so the frame it was
-- written for never got a hook at all and closing the character sheet swept
-- currencies instead.
--
-- Retried on `ADDON_LOADED`, which is how the client announces exactly this.
local hookedCurrencyFrame = false

function Currencies.HookFrame()
    if hookedCurrencyFrame then
        return true
    end

    local frame = _G.TokenFrame

    if not frame or not frame.HookScript then
        return false
    end

    local ok = pcall(frame.HookScript, frame, "OnHide", function()
        pcall(Currencies.SweepIfDue)
    end)

    hookedCurrencyFrame = ok and true or false

    return hookedCurrencyFrame
end

CN:RegisterEvent("ADDON_LOADED", function()
    Currencies.HookFrame()
end)

CN:OnLogin(function()
    Currencies.HookFrame()
end)

CN:OnLogin(function()
    Currencies.Scan()
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "currencies",
    aliases = { "currency" },
    order   = 77,
    help    = "Show currency caps and unfilled weekly earning.",
    handler = function()
        local counts = Currencies.Summary()

        if counts.known == 0 then
            Print("No currency data yet. Run /cn currencyscan.")
            return
        end

        Print("Currencies tracked: " .. counts.known)

        local capped = Currencies.Capped()

        if #capped > 0 then
            Print("|cffe2564cAt cap (" .. #capped .. ") - spend these:|r")

            -- CAPPED, AND SAYING SO -- like the list below it. 0.79.0.
            --
            -- 0.78.0 added "and N more" to the weekly list and left this one
            -- unbounded, so a player deep into an expansion had twenty-plus
            -- rows dumped into chat. The two halves of one command were
            -- inconsistent in opposite directions.
            for index, currency in ipairs(capped) do
                if index > 8 then
                    break
                end

                CN.PrintLine("  " .. tostring(currency.name)
                    .. " |cff8a8f96" .. currency.quantity
                    .. " / " .. currency.maximum
                    -- A cap on lifetime earning and a balance are different
                    -- numbers, and a player who has spent theirs will
                    -- otherwise read this as a bug.
                    .. (currency.usesTotalEarned
                        and (" earned, " .. tostring(currency.held)
                            .. " held")
                        or "")
                    .. "|r")
            end

            if #capped > 8 then
                CN.PrintLine(CN.Muted("  ... and " .. (#capped - 8)
                    .. " more"))
            end
        end

        local weekly = Currencies.WeeklyUnfilled()

        if #weekly > 0 then
            Print("Weekly earning still available (" .. #weekly .. "):")

            for index = 1, math.min(#weekly, 8) do
                local currency = weekly[index]

                CN.PrintLine("  " .. tostring(currency.name)
                    .. " |cff8a8f96" .. currency.earned .. " / " .. currency.maximum
                    .. ", " .. currency.remaining .. " left this week|r")
            end

            -- A CAP NOBODY CAN SEE READS AS "THAT WAS EVERYTHING". 0.78.0.
            --
            -- The headline announced the real count and the list stopped at
            -- eight with nothing said, so a player with fourteen was told
            -- fourteen and shown eight. Three other commands print "and N
            -- more" for the same shape and `Design.lua`'s own header names
            -- this inconsistency.
            if #weekly > 8 then
                CN.PrintLine(CN.Muted("  ... and " .. (#weekly - 8)
                    .. " more"))
            end
        end

        if #capped == 0 and #weekly == 0 then
            Print("Nothing capped, nothing left to earn this week.")
        end
    end,
}

CN:RegisterCommand{
    name    = "currencyscan",
    order   = 78,
    help    = "Rescan currencies for this character.",
    handler = function()
        -- A SCAN THE PLAYER ASKED FOR RE-ARMS THE TIMER -- AFTERWARDS.
        --
        -- 0.64.0 wrote this and put it in the wrong place: resetting the
        -- timestamp BEFORE scanning sets it to zero, which makes the throttle
        -- test false for the next sixty seconds and guarantees the very
        -- double sweep the comment says it prevents. Pick up one coin a
        -- second after a manual scan and the whole three-pass read ran again,
        -- headers and all.
        --
        -- The timestamp belongs to the scan, so `Scan` stamps it itself now
        -- and every path -- manual, automatic, login -- is throttled the same
        -- way. 0.65.0.
        local seen, atCap, weekly = Currencies.Scan()

        Print("Scanned " .. seen .. " currencies.")
        Print("At cap: " .. atCap .. "   With weekly earning left: " .. weekly)
    end,
}

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
