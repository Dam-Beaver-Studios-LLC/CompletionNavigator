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
local function NameStore()
    return CN.Account("currencyNames")
end

local function CharacterStore(character)
    character = character or CN.character

    if not character then
        return nil
    end

    character.currencies = character.currencies or {}

    return character.currencies
end

Currencies.NameStore      = NameStore
Currencies.CharacterStore = CharacterStore

------------------------------------------------------------
-- SCAN
------------------------------------------------------------

function Currencies.Scan()
    local names = NameStore()
    local mine  = CharacterStore()

    if not mine then
        return 0, 0, 0
    end

    local seen, atCap, weeklyRemaining = 0, 0, 0

    for _, currency in ipairs(Blizzard.GetCurrencyList()) do
        if currency.currencyID then
            names[currency.currencyID] = currency.name

            local capped = currency.maxQuantity > 0
                and currency.quantity >= currency.maxQuantity

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
                accountWide       = currency.accountWide or nil,
                weeklyRemaining   = weeklyLeft,
                lastSeen          = time(),
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
        if record.capped then
            table.insert(capped, {
                currencyID = currencyID,
                name       = NameStore()[currencyID],
                quantity   = record.quantity,
                maximum    = record.maxQuantity,

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
        if record.weeklyRemaining and record.weeklyRemaining > 0 then
            table.insert(rows, {
                currencyID = currencyID,
                name       = NameStore()[currencyID],
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
    local store = CharacterStore(character) or {}

    return {
        known           = CN.CountKeys(store),
        capped          = #Currencies.Capped(character),
        weeklyUnfilled  = #Currencies.WeeklyUnfilled(character),
    }
end

function Currencies.Resolve(text)
    local currencyID = CN.ToID(text)

    if currencyID and NameStore()[currencyID] then
        return currencyID
    end

    if not text or text == "" then
        return nil
    end

    local needle  = string.lower(text)
    local matches = {}

    for id, name in pairs(NameStore()) do
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
                limitedTimeBonus = 1,
                travelCost       = 0,

                -- A capped currency is not "expiring", but every hour spent
                -- at cap is earning thrown away, and the weekly reset is when
                -- that waste is realised. Treating the reset as its deadline
                -- makes the urgency curve say the true thing: this matters
                -- more on Monday night than on Wednesday morning.
                expiresIn        = CN.Blizzard.GetSecondsUntilWeeklyReset(),

                reasons          = {
                    "at cap: " .. tostring(currency.quantity)
                        .. " / " .. tostring(currency.maximum),
                    "further earning is wasted until you spend it",
                },
            }))
        end
    end

    return candidates
end, { events = { "CURRENCY_DISPLAY_UPDATE" }, volatile = true })

------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

local lastScan = 0

CN:RegisterEvent("CURRENCY_DISPLAY_UPDATE", function()
    local now = time()

    if now - lastScan < 10 then
        return
    end

    lastScan = now

    Currencies.Scan()
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

            for _, currency in ipairs(capped) do
                CN.PrintLine("  " .. tostring(currency.name)
                    .. " |cff8a8f96" .. currency.quantity
                    .. " / " .. currency.maximum .. "|r")
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
        local seen, atCap, weekly = Currencies.Scan()

        Print("Scanned " .. seen .. " currencies.")
        Print("At cap: " .. atCap .. "   With weekly earning left: " .. weekly)
    end,
}

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
