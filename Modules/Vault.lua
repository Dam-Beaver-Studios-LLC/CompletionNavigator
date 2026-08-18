-- Modules/Vault.lua
-- Completion Navigator :: the Great Vault.
--
-- The weekly reward chest. Three rows -- raid, dungeons, world -- each with
-- three thresholds, and you choose ONE item from everything unlocked.
--
-- This module matters more than its size suggests, because the Great Vault is
-- the only system in the game that hands the addon all three things it
-- normally has to guess at:
--
--   * a hard deadline      -- the weekly reset, which the client reports
--   * a known denominator  -- the thresholds are fixed
--   * a known reward       -- the client reports the item level
--
-- Everywhere else this addon reports counts rather than percentages, because
-- a percentage needs a denominator the client will not supply. Here it will.
-- "3 of 4 dungeons" is a fact, and "one more Heroic before Tuesday unlocks a
-- second reward" is a genuine next action rather than an estimate.
--
-- The nearly-there row is the whole point. A row sitting one activity short of
-- a threshold is the highest-value, most time-boxed objective the addon can
-- offer; a row already at its cap is worth nothing this week.

local ADDON_NAME, CN = ...

local Vault = CN:RegisterModule("Vault")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint
local Blizzard   = CN.Blizzard

------------------------------------------------------------
-- ROWS
------------------------------------------------------------

Vault.rowLabels = {
    RAID    = "Raid",
    DUNGEON = "Dungeons",
    WORLD   = "World",
    PVP     = "PvP",
    UNKNOWN = "Other",
}

-- What the player would actually go and do to advance each row. Naming the
-- action is the difference between a progress bar and a recommendation.
Vault.rowActions = {
    RAID    = "defeat another raid boss",
    DUNGEON = "run another Heroic or higher dungeon",
    WORLD   = "complete another Delve, weekly quest or zone event",
    PVP     = "complete another rated PvP match",
    UNKNOWN = "complete another qualifying activity",
}

local ROW_ORDER = { "RAID", "DUNGEON", "WORLD", "PVP", "UNKNOWN" }

------------------------------------------------------------
-- READING THE VAULT
------------------------------------------------------------

-- Collapses the flat activity list into one entry per row:
--
--   { row, label, progress, unlocked, tiers, next, remaining, capped }
--
-- `next` is the next unmet threshold; `remaining` is how many activities
-- away it is. Both nil when the row is capped.
function Vault.Rows()
    local activities = Blizzard.GetWeeklyRewardActivities()

    if #activities == 0 then
        return {}
    end

    local byRow = {}

    for _, activity in ipairs(activities) do
        local row = byRow[activity.row]

        if not row then
            row = {
                row      = activity.row,
                label    = Vault.rowLabels[activity.row] or activity.row,
                progress = 0,
                unlocked = 0,
                tiers    = {},
            }

            byRow[activity.row] = row
        end

        -- Every tier of a row reports the same progress figure; taking the
        -- maximum is defensive rather than necessary.
        row.progress = math.max(row.progress, activity.progress or 0)

        table.insert(row.tiers, {
            threshold = activity.threshold,
            progress  = activity.progress,
            level     = activity.level,
            unlocked  = activity.unlocked,
        })

        if activity.unlocked then
            row.unlocked = row.unlocked + 1
        end
    end

    local rows = {}

    for _, name in ipairs(ROW_ORDER) do
        local row = byRow[name]

        if row then
            table.sort(row.tiers, function(a, b)
                return (a.threshold or 0) < (b.threshold or 0)
            end)

            for _, tier in ipairs(row.tiers) do
                if not tier.unlocked and not row.next then
                    row.next      = tier.threshold
                    row.remaining = math.max(0, (tier.threshold or 0) - row.progress)
                end
            end

            row.capped = row.next == nil

            table.insert(rows, row)
        end
    end

    return rows
end

function Vault.IsAvailable()
    return Blizzard.HasWeeklyRewards()
end

-- Total reward choices unlocked across every row.
function Vault.Summary()
    local rows = Vault.Rows()

    local summary = {
        rows     = #rows,
        unlocked = 0,
        closest  = nil,
        resetsIn = Blizzard.GetSecondsUntilWeeklyReset(),
        claimable = Blizzard.HasAvailableWeeklyRewards(),
    }

    for _, row in ipairs(rows) do
        summary.unlocked = summary.unlocked + row.unlocked

        if not row.capped and row.remaining then
            if not summary.closest or row.remaining < summary.closest.remaining then
                summary.closest = row
            end
        end
    end

    return summary
end

------------------------------------------------------------
-- FORMATTING
------------------------------------------------------------

local function FormatReset(seconds)
    if not seconds then
        return nil
    end

    local days  = math.floor(seconds / 86400)
    local hours = math.floor((seconds % 86400) / 3600)

    if days > 0 then
        return days .. "d " .. hours .. "h"
    end

    if hours > 0 then
        return hours .. "h"
    end

    return math.max(1, math.floor(seconds / 60)) .. "m"
end

Vault.FormatReset = FormatReset

function Vault.DescribeRow(row)
    local text = row.label .. ": " .. row.progress

    if row.capped then
        return text .. " |cff00ff00all " .. row.unlocked .. " unlocked|r"
    end

    return text .. " of " .. row.next
        .. " |cff999999(" .. row.unlocked .. " unlocked, "
        .. row.remaining .. " more for the next)|r"
end

------------------------------------------------------------
-- CANDIDATES
------------------------------------------------------------

-- Urgency rises as the reset approaches AND as the row nears its threshold.
-- One activity away with a day left is the single most actionable thing the
-- addon can surface; three away with six days left is barely worth a mention.
local function Urgency(remaining, resetsIn)
    local value = 0

    if remaining then
        if remaining <= 1 then
            value = value + 3
        elseif remaining <= 2 then
            value = value + 2
        else
            value = value + 1
        end
    end

    if resetsIn then
        local days = resetsIn / 86400

        if days <= 1 then
            value = value + 3
        elseif days <= 2 then
            value = value + 2
        elseif days <= 4 then
            value = value + 1
        end
    end

    return value
end

Vault.Urgency = Urgency

-- How many activities away a row can be and still be worth recommending.
-- Beyond this it is a plan for the week, not a next action.
Vault.maxRemaining = 4

CN.RegisterCandidateProvider("Vault", function()
    local candidates = {}

    if not Vault.IsAvailable() then
        return candidates
    end

    local resetsIn = Blizzard.GetSecondsUntilWeeklyReset()

    -- An unclaimed vault from last week outranks everything: it is free, it
    -- takes thirty seconds, and it expires.
    if Blizzard.HasAvailableWeeklyRewards() then
        table.insert(candidates, CN.NewObjective({
            id               = 0,
            type             = CN.objectiveTypes.CURRENCY,
            name             = "Collect your Great Vault reward",
            accountWide      = false,
            completionValue  = 8,
            limitedTimeBonus = 3,
            travelCost       = 2,
            reasons          = {
                "a reward is waiting to be claimed",
                "it is replaced when the vault next fills",
            },
        }))
    end

    for _, row in ipairs(Vault.Rows()) do
        if not row.capped
            and row.remaining
            and row.remaining <= Vault.maxRemaining
            and not CN.IsIgnored(CN.objectiveTypes.CURRENCY, row.row)
            and not CN.IsDeferred(CN.objectiveTypes.CURRENCY, row.row) then

            local reasons = {
                row.remaining .. " more to unlock a "
                    .. (row.unlocked > 0 and "further" or "first")
                    .. " Great Vault reward",
                Vault.rowActions[row.row] or "complete another activity",
            }

            if resetsIn then
                table.insert(reasons, "resets in " .. FormatReset(resetsIn))
            end

            table.insert(candidates, CN.NewObjective({
                id               = row.row,
                type             = CN.objectiveTypes.CURRENCY,
                name             = "Great Vault: " .. row.label,
                accountWide      = false,
                completionValue  = 4,
                limitedTimeBonus = Urgency(row.remaining, resetsIn),
                -- Instanced content has no map coordinate, but it is not
                -- "location unknown" either: the group finder is one click.
                travelCost       = 3,
                expiresIn        = resetsIn,
                reasons          = reasons,
            }))
        end
    end

    return candidates
end, { events = { "WEEKLY_REWARDS_UPDATE", "CHALLENGE_MODE_COMPLETED",
                  "ENCOUNTER_END", "QUEST_TURNED_IN" }, volatile = true })

------------------------------------------------------------
-- COMMAND
------------------------------------------------------------

CN:RegisterCommand{
    name    = "vault",
    aliases = { "greatvault" },
    order   = 16,
    help    = "Great Vault progress and what unlocks the next reward.",
    handler = function()
        if not Vault.IsAvailable() then
            Print("The Great Vault is not available on this client.")
            return
        end

        local rows = Vault.Rows()

        if #rows == 0 then
            Print("No Great Vault progress recorded yet.")
            Print("|cff999999The client reports vault progress once you have "
                .. "completed at least one qualifying activity this week.|r")
            return
        end

        local summary = Vault.Summary()

        Print("Great Vault: " .. summary.unlocked .. " reward"
            .. (summary.unlocked == 1 and "" or "s") .. " unlocked"
            .. (summary.resetsIn
                and (" |cff999999resets in " .. FormatReset(summary.resetsIn) .. "|r")
                or ""))

        if summary.claimable then
            Print("|cff00ff00A reward is waiting to be collected.|r")
        end

        for _, row in ipairs(rows) do
            Print("  " .. Vault.DescribeRow(row))
        end

        if summary.closest then
            Print("|cffffff00Closest:|r " .. summary.closest.label
                .. " -- " .. summary.closest.remaining .. " more, "
                .. (Vault.rowActions[summary.closest.row] or "keep going") .. ".")
        else
            Print("|cff00ff00Every row is capped. Nothing more to earn this week.|r")
        end

        Print("|cff999999You choose one item from everything unlocked.|r")
    end,
}

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
