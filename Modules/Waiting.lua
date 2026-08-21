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
Waiting.knowledgePattern = "[Kk]nowledge"

function Waiting.Knowledge()
    local rows = {}

    local currencies = CN:GetModule("Currencies")

    if not currencies or not currencies.Store then
        return rows
    end

    for currencyID, record in pairs(currencies.Store()) do
        if record.maxWeeklyQuantity and record.maxWeeklyQuantity > 0
            and (record.weeklyRemaining or 0) > 0 then

            local name = Blizzard.GetCurrency(currencyID)

            name = name and name.name

            if name and name:find(Waiting.knowledgePattern) then
                table.insert(rows, {
                    currencyID = currencyID,
                    name       = name,
                    remaining  = record.weeklyRemaining,
                    cap        = record.maxWeeklyQuantity,
                })
            end
        end
    end

    table.sort(rows, function(a, b) return a.currencyID < b.currencyID end)

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

    if #expiring > 0 then
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
                string.format("%d message(s) with attachments, the first in "
                    .. "%.1f days", #expiring, soonest.daysLeft or 0),
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
                travelCost       = CN.unknownLocationCost,
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
    help    = "Everything with a deadline that is not a quest.",
    handler = function()
        local said = false

        local mail, readable = Waiting.Mail()

        if not readable then
            Print("|cff999999Mail cannot be read in this client.|r")
        elseif #mail == 0 then
            Print("|cff999999No mail, or the mailbox has not been opened this "
                .. "session -- the client only hands the addon the inbox once "
                .. "you have looked at it.|r")
        else
            Print(#mail .. " message(s) in your mailbox:")

            for index, entry in ipairs(mail) do
                if index > 5 then
                    Print("  |cff999999... and " .. (#mail - 5) .. " more|r")
                    break
                end

                local colour = entry.expiring and "|cfff56b61" or "|cff999999"

                Print(string.format("  %s%.1f days|r %s |cff999999from %s|r",
                    colour, entry.daysLeft or 0,
                    tostring(entry.subject or "(no subject)"),
                    tostring(entry.sender or "?")))
            end

            said = true
        end

        local keystone = Waiting.Keystone()

        if keystone then
            Print("Keystone: " .. (keystone.name or "unknown")
                .. " |cffffff00+" .. keystone.level .. "|r")

            said = true
        end

        local knowledge = Waiting.Knowledge()

        for _, row in ipairs(knowledge) do
            Print(row.name .. ": |cffffff00" .. row.remaining
                .. "|r of " .. row.cap .. " still collectable this week")

            said = true
        end

        local heirlooms = Waiting.Heirlooms()

        if heirlooms then
            Print("Heirlooms: " .. heirlooms.collected .. " of " .. heirlooms.total)

            said = true
        end

        if not said then
            Print("Nothing is on a clock right now.")
        end
    end,
}

return Waiting
