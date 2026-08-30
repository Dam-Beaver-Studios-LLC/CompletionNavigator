-- Modules/Waiting.lua
-- Completion Navigator :: things with a clock on them that the addon could
-- not see.
--
-- Four systems, one file, because each is thirty lines and none of them
-- deserves a module. What they share is the only thing that matters to the
-- ranking: a deadline, and something lost when it passes.
--
--   MAIL          -- expires and is destroyed. Thirty days, and the client
--                    tells you how many are left.
--   KEYSTONE      -- the one in your bag is gone at the weekly reset.
--   KNOWLEDGE     -- profession knowledge is weekly, capped, and permanently
--                    missable: the week you skip does not come back.
--   HEIRLOOMS     -- no deadline, but a collection with its own journal that
--                    nothing in this addon had ever read.
--
-- ON MAIL, SPECIFICALLY.
--
-- This reads the mailbox the client has already told the addon about. It does
-- not open mail, take attachments, or send anything. An addon that empties
-- your mailbox unprompted is one bad edge case away from destroying something
-- irreplaceable, and the standing rule here is that the addon prompts and
-- never acts.

local ADDON_NAME, CN = ...

local Waiting = CN:RegisterModule("Waiting")

local Print      = CN.Print
local Blizzard   = CN.Blizzard

------------------------------------------------------------
-- MAIL
------------------------------------------------------------

-- Below this, it is worth interrupting whatever the player is doing. Three
-- days: enough warning to be actionable, short enough that it is not shouting
-- about mail that arrived this morning.
Waiting.mailWarningDays = 3

function Waiting.Mail()
    local items = {}

    if not GetInboxNumItems or not GetInboxHeaderInfo then
        return items, false
    end

    local ok, count = pcall(GetInboxNumItems)

    if not ok or not count or count == 0 then
        return items, true
    end

    for index = 1, count do
        local gotInfo, _, _, sender, subject, money, _, daysLeft, itemCount =
            pcall(GetInboxHeaderInfo, index)

        if gotInfo and daysLeft then
            table.insert(items, {
                sender    = sender,
                subject   = subject,
                money     = money or 0,
                items     = itemCount or 0,
                daysLeft  = daysLeft,
                expiring  = daysLeft <= Waiting.mailWarningDays,
            })
        end
    end

    table.sort(items, function(a, b)
        return (a.daysLeft or 0) < (b.daysLeft or 0)
    end)

    return items, true
end

function Waiting.ExpiringMail()
    local expiring = {}

    for _, mail in ipairs((Waiting.Mail())) do
        if mail.expiring and (mail.items > 0 or mail.money > 0) then
            table.insert(expiring, mail)
        end
    end

    return expiring
end

------------------------------------------------------------
-- KEYSTONE
------------------------------------------------------------

function Waiting.Keystone()
    if not C_MythicPlus then
        return nil
    end

    local level, mapID

    if C_MythicPlus.GetOwnedKeystoneLevel then
        local ok, owned = pcall(C_MythicPlus.GetOwnedKeystoneLevel)

        if ok then
            level = owned
        end
    end

    if not level or level == 0 then
        return nil
    end

    if C_MythicPlus.GetOwnedKeystoneChallengeMapID then
        local ok, owned = pcall(C_MythicPlus.GetOwnedKeystoneChallengeMapID)

        if ok then
            mapID = owned
        end
    end

    local name

    if mapID and C_ChallengeMode and C_ChallengeMode.GetMapUIInfo then
        local ok, mapName = pcall(C_ChallengeMode.GetMapUIInfo, mapID)

        if ok then
            name = mapName
        end
    end

    return {
        level = level,
        mapID = mapID,
        name  = name,
        -- A keystone is replaced at the reset whether or not it is used, so
        -- the reset IS its expiry.
        expiresIn = Blizzard.GetSecondsUntilWeeklyReset(),
    }
end

------------------------------------------------------------
-- PROFESSION KNOWLEDGE
------------------------------------------------------------

-- Weekly knowledge is the most permanently missable thing in modern
-- professions: the cap resets, and a week not collected is gone. The client
-- exposes it as a currency, which is why this reads currencies rather than
-- the profession API -- fewer moving parts, and it works for every expansion
-- that has used the pattern.
--
-- THE ENGLISH WORD WAS THE GATE, AND IT SHOULD NEVER HAVE BEEN. FIXED 0.61.0.
--
-- `knowledgePattern = "[Kk]nowledge"` was matched against the currency's
-- LOCALIZED name. On a German client the currency is "Wissen", on French
-- "Connaissance", on Spanish "Conocimiento" -- so this section, and every
-- candidate it produces, returned exactly zero rows on every non-English
-- client in the world. That is roughly half the player base being silently
-- denied the feature this file's own header calls "the most permanently
-- missable thing in modern professions".
--
-- It is also the second locale bug of this shape the project has found, and
-- the lesson is the same: a localized string is a thing to DISPLAY, never a
-- thing to BRANCH ON.
--
-- What replaces it is a fact the client vouches for in every locale: the
-- currency has a weekly cap and there is room left under it. That is already
-- what the loop below tests, and it was the honest gate all along. A weekly
-- cap on a currency is the game saying "this is gone on Tuesday", which is
-- precisely the question `/cn clock` asks.
--
-- AND THE DEMOTED PATTERN IS GONE TOO. 0.63.0.
--
-- 0.61.0 kept it as an ordering hint, which is the same bug with a smaller
-- blast radius: an English player saw knowledge sorted first and a German
-- player did not. A hint that works in one language is not a hint. See the
-- note at the ordering below for what replaced it.

-- Locale-free reinforcement: the profession knowledge currencies the addon
-- knows by id. An id is the same in every locale. This is a HINT for
-- ordering, not a gate -- a currency missing from this list is still
-- reported, because the weekly cap is what makes it missable and a hard-coded
-- list of ids goes stale on every content patch.
Waiting.knowledgeCurrencies = {
    -- The War Within profession knowledge.
    [2915] = true, [2916] = true, [2917] = true, [2918] = true,
    [2919] = true, [2920] = true, [2921] = true, [2922] = true,
    [2923] = true, [2924] = true, [2925] = true,
}

function Waiting.Knowledge()
    local rows = {}

    local currencies = CN:GetModule("Currencies")

    -- `CharacterStore`, not `Store`. There has never been a Currencies.Store,
    -- so this guard was false on every client and the whole KNOWLEDGE section
    -- of `/cn clock` -- plus its candidates -- has never once produced a row,
    -- in a file whose header calls weekly profession knowledge "the most
    -- permanently missable thing in modern professions".
    --
    -- Nothing caught it because an empty knowledge list and a knowledge list
    -- that cannot be built look identical from outside, and the suite only
    -- asserted that `/cn clock` did not error.
    if not currencies or not currencies.CharacterStore then
        return rows
    end

    for currencyID, record in pairs(currencies.CharacterStore() or {}) do
        -- THE SAME STALENESS RULE THE CURRENCY MODULE APPLIES. 0.64.0.
        --
        -- `Currencies.IsCurrent` exists so a row the client has stopped
        -- listing -- a currency retired at a patch, or any row still carrying
        -- migration 13's "unconfirmed" serial -- is not reported as though it
        -- were live. `Capped` and `WeeklyUnfilled` both apply it; this
        -- re-implemented the filter without it.
        --
        -- So `/cn clock` said "still 1,500 to earn this week" about a
        -- currency `/cn currencies` had correctly dropped, on the same login.
        if currencies.IsCurrent(record)
            and record.maxWeeklyQuantity and record.maxWeeklyQuantity > 0
            and (record.weeklyRemaining or 0) > 0 then

            local info = Blizzard.GetCurrency(currencyID)
            local name = info and info.name

            -- No name is not a reason to drop a capped currency: the row is
            -- still true, and the id can carry it.
            -- THE HINT IS STILL A GATE, JUST A SMALLER ONE. 0.63.0.
            --
            -- 0.61.0 demoted the English word from deciding WHETHER a row
            -- appears to deciding where it SORTS -- which is better and still
            -- wrong for the same reason. A German player whose knowledge
            -- currency is not in the hard-coded id list (any new expansion's
            -- will not be) sees "Wissen" sorted among the ordinary weeklies
            -- while an English player sees it first.
            --
            -- The id list is locale-free and stays. The English match is gone
            -- rather than demoted again: a hint that works in one language is
            -- not a hint, it is a bug with a smaller blast radius. What
            -- replaces it for currencies the list does not know is the fact
            -- the client vouches for -- a weekly cap that is nearly full is
            -- more urgent than one barely touched -- which is true in every
            -- language and is what a player is actually deciding on.
            local knowledge = Waiting.knowledgeCurrencies[currencyID] == true

            table.insert(rows, {
                currencyID = currencyID,
                name       = name or ("Currency " .. tostring(currencyID)),
                knowledge  = knowledge,
                remaining  = record.weeklyRemaining,
                cap        = record.maxWeeklyQuantity,
            })
        end
    end

    -- Knowledge first where it is identifiable, then by id so the order is
    -- stable across sessions and locales.
    table.sort(rows, function(a, b)
        if a.knowledge ~= b.knowledge then
            return a.knowledge
        end

        -- Then by how much of the week's cap is still unclaimed, which is a
        -- fact in every locale. See the note above.
        local left  = (a.cap or 0) > 0 and (a.remaining / a.cap) or 0
        local right = (b.cap or 0) > 0 and (b.remaining / b.cap) or 0

        if left ~= right then
            return left > right
        end

        return a.currencyID < b.currencyID
    end)

    return rows
end

------------------------------------------------------------
-- HEIRLOOMS
------------------------------------------------------------

function Waiting.Heirlooms()
    if not C_Heirloom or not C_Heirloom.GetNumHeirlooms then
        return nil
    end

    local ok, total = pcall(C_Heirloom.GetNumHeirlooms)

    if not ok or not total then
        return nil
    end

    local collected = 0

    for index = 1, total do
        local gotID, itemID = pcall(C_Heirloom.GetHeirloomItemIDFromIndex, index)

        if gotID and itemID then
            local gotOwned, owned = pcall(C_Heirloom.PlayerHasHeirloom, itemID)

            if gotOwned and owned then
                collected = collected + 1
            end
        end
    end

    return { total = total, collected = collected }
end

------------------------------------------------------------
-- CANDIDATES
------------------------------------------------------------

CN.RegisterCandidateProvider("Waiting", function()
    local candidates = {}

    -- MAIL. Ranked by what is actually at stake: mail with something in it,
    -- about to be destroyed.
    local expiring = Waiting.ExpiringMail()

    -- AND HIDING OR DEFERRING IT WORKS. 0.82.0.
    --
    -- The two loops below this one both guard on `IsIgnored` and
    -- `IsDeferred`, and this singleton row did not -- the exact defect
    -- `Modules/Orders.lua` and `Modules/Vault.lua` each record for their own
    -- singleton rows, in the two passes that missed this one.
    --
    -- Hiding is enforced INSIDE providers; there is no aggregate filter above
    -- them. So the row scored highest in the file, sat at the top of
    -- `/cn next`, printed "Ignored: 3 mail expiring" when the player hid it,
    -- wrote the entry, and came straight back on the next rebuild -- listed
    -- in `/cn hidden` and first in the list at the same time.
    if #expiring > 0
        and not CN.IsIgnored(CN.objectiveTypes.CURRENCY, "mail")
        and not CN.IsDeferred(CN.objectiveTypes.CURRENCY, "mail") then

        local soonest = expiring[1]

        table.insert(candidates, CN.NewObjective({
            id               = "mail",
            type             = CN.objectiveTypes.CURRENCY,
            name             = #expiring .. " mail expiring",
            completionValue  = 6,
            limitedTimeBonus = 3,
            travelCost       = 3,
            expiresIn        = math.max(0, (soonest.daysLeft or 0) * 86400),
            reasons          = {
                string.format("%s with attachments, the first in %.1f days",
                    CN.Count(#expiring, "message"), soonest.daysLeft or 0),
                "expired mail is destroyed, not returned",
            },
        }))
    end

    -- KEYSTONE. Not gearing: a thing in your bag that is replaced on Tuesday
    -- whether you use it or not.
    local keystone = Waiting.Keystone()

    if keystone and not CN.IsIgnored(CN.objectiveTypes.INSTANCE, "keystone")
        and not CN.IsDeferred(CN.objectiveTypes.INSTANCE, "keystone") then

        table.insert(candidates, CN.NewObjective({
            id               = "keystone",
            type             = CN.objectiveTypes.INSTANCE,
            name             = "Keystone: " .. (keystone.name or "unknown")
                .. " +" .. keystone.level,
            completionValue  = 4,
            limitedTimeBonus = 2,
            travelCost       = 3,
            expiresIn        = keystone.expiresIn,
            reasons          = {
                "your keystone is replaced at the weekly reset whether you "
                    .. "use it or not",
            },
        }))
    end

    -- KNOWLEDGE. The most permanently missable thing in the game that the
    -- addon can see.
    for _, row in ipairs(Waiting.Knowledge()) do
        if not CN.IsIgnored(CN.objectiveTypes.PROFESSION, row.currencyID)
            and not CN.IsDeferred(CN.objectiveTypes.PROFESSION, row.currencyID) then

            table.insert(candidates, CN.NewObjective({
                id               = row.currencyID,
                type             = CN.objectiveTypes.PROFESSION,
                name             = row.name .. ": " .. row.remaining .. " left this week",
                completionValue  = 5,
                limitedTimeBonus = 2,
                travelCost       = CN.placelessCost,
                expiresIn        = Blizzard.GetSecondsUntilWeeklyReset(),
                reasons          = {
                    row.remaining .. " of " .. row.cap .. " still collectable this week",
                    "a week not collected does not come back",
                },
            }))
        end
    end

    return candidates
end, {
    events   = { "MAIL_INBOX_UPDATE", "BAG_UPDATE_DELAYED", "CURRENCY_DISPLAY_UPDATE" },
    volatile = true,
    cooldown = 30,
})

------------------------------------------------------------
-- COMMAND
------------------------------------------------------------

CN:RegisterCommand{
    name    = "clock",
    aliases = { "expiring" },
    order   = 29,
    help    = "Everything on a weekly or daily timer: vault, caps, lockouts.",
    handler = function()
        local said = false

        local mail, readable = Waiting.Mail()

        if not readable then
            Print("|cff8a8f96Mail cannot be read in this client.|r")
        elseif #mail == 0 then
            Print("|cff8a8f96No mail, or the mailbox has not been opened this "
                .. "session" .. CN.DASH .. "the client only hands the addon the inbox once "
                .. "you have looked at it.|r")
        else
            local rows = {}

            for _, entry in ipairs(mail) do
                table.insert(rows, {
                    text  = tostring(entry.subject or "(no subject)"),
                    value = string.format("%.1f days", entry.daysLeft or 0),
                    state = entry.expiring and "BAD" or "MUTED",
                    note  = "from " .. tostring(entry.sender or "?"),
                })
            end

            CN.PrintRows(CN.Count(#mail, "message") .. " in your mailbox:",
                rows, { limit = 5, more = "open your mailbox for the rest" })

            said = true
        end

        local keystone = Waiting.Keystone()

        if keystone then
            Print("Keystone: " .. (keystone.name or "unknown")
                .. " |cffffc74f+" .. keystone.level .. "|r")

            said = true
        end

        local knowledge = Waiting.Knowledge()

        if #knowledge > 0 then
            local rows = {}

            for _, row in ipairs(knowledge) do
                table.insert(rows, {
                    text  = row.name,
                    value = row.remaining .. " of " .. row.cap,
                    state = "ACCENT",
                    note  = "still collectable this week",
                })
            end

            CN.PrintRows(nil, rows)

            said = true
        end

        local heirlooms = Waiting.Heirlooms()

        if heirlooms then
            Print("Heirlooms: " .. heirlooms.collected .. " of " .. heirlooms.total)

            said = true
        end

        if not said then
            Print(CN.L["Nothing is on a clock right now."])
        end
    end,
}

return Waiting
