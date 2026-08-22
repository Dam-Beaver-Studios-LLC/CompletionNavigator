-- Modules/Sets.lua
-- Completion Navigator :: appearance SETS, the guild, and what you could
-- queue for.
--
-- Three readers, one file, for the same reason Waiting holds four: each is a
-- thin wrapper over a client API the addon had never opened, and none of them
-- carries enough behaviour to justify a module of its own.
--
-- SETS.
--
-- The addon has tracked individual appearances since 0.13.0 and has never
-- known that the game groups them. That matters because collecting is
-- overwhelmingly done by SET -- nobody wants "one more shoulder", they want
-- the tier set finished -- and "3 of 5 pieces" is a genuine denominator the
-- client supplies, which this addon is otherwise very short of.
--
-- GUILD.
--
-- Guild achievements and guild reputation are a whole progression track that
-- was structurally invisible. Modest scope deliberately: what the guild is,
-- and whether the character is close to anything in it.
--
-- QUEUES.
--
-- "You could run this right now" is a different and more useful sentence than
-- "this dungeon exists". The client knows what the character is eligible for;
-- the addon never asked.

local ADDON_NAME, CN = ...

local Sets = CN:RegisterModule("Sets")

local Print = CN.Print

------------------------------------------------------------
-- APPEARANCE SETS
------------------------------------------------------------

function Sets.IsAvailable()
    return C_TransmogSets ~= nil and C_TransmogSets.GetAllSets ~= nil
end

-- Every set the client will describe, with how much of it is collected.
--
-- Bounded: there are several thousand sets across the game's history and each
-- one costs a call to enumerate its pieces. The cap is a real limit on what
-- this answers, so it is stated rather than hidden -- the command says how
-- many were examined.
Sets.scanCap = 400

-- CACHED, BECAUSE THIS IS THE MOST EXPENSIVE THING IN THE ADDON WITHOUT IT.
--
-- Measured at realistic scale -- three thousand sets, which is roughly what
-- the game holds -- the uncached scan cost 4.4 milliseconds per candidate
-- rebuild: more than every other provider in the addon added together, and
-- nearly half of a 16ms frame.
--
-- It was invisible in the first measurement because the fixture had three
-- sets in it. That is the same trap as the map that was always square and the
-- flying speed that was always rejected: a fixture small enough to read is a
-- fixture too small to measure.
--
-- Collections change rarely and announce themselves, so the cache is held
-- until the client says a transmog was collected.
local cache = nil

function Sets.Forget()
    cache = nil
end

function Sets.All(limit)
    limit = limit or Sets.scanCap

    if cache and cache.limit == limit then
        return cache.rows, cache.readable, cache.examined
    end

    local rows = {}

    if not Sets.IsAvailable() then
        return rows, false
    end

    local ok, all = pcall(C_TransmogSets.GetAllSets)

    if not ok or type(all) ~= "table" then
        return rows, false
    end

    local examined = 0

    for _, set in ipairs(all) do
        if examined >= limit then
            break
        end

        if set.setID and set.collected ~= nil then
            examined = examined + 1

            local total, collected = 0, 0

            if C_TransmogSets.GetSetPrimaryAppearances then
                local gotPieces, pieces =
                    pcall(C_TransmogSets.GetSetPrimaryAppearances, set.setID)

                if gotPieces and type(pieces) == "table" then
                    for _, piece in ipairs(pieces) do
                        total = total + 1

                        if piece.collected then
                            collected = collected + 1
                        end
                    end
                end
            end

            table.insert(rows, {
                setID     = set.setID,
                name      = set.name,
                label     = set.label,
                collected = collected,
                total     = total,
                complete  = set.collected and true or false,
            })
        end
    end

    cache = {
        rows     = rows,
        readable = true,
        examined = examined,
        limit    = limit,
    }

    return rows, true, examined
end

-- The sets closest to finished, which is the only ordering anybody wants.
-- A set with nothing collected is not "nearly done"; it is a decision.
function Sets.NearlyComplete(maxMissing)
    maxMissing = maxMissing or 2

    local rows = {}

    for _, set in ipairs((Sets.All())) do
        local missing = set.total - set.collected

        if set.total > 0 and missing > 0 and missing <= maxMissing then
            set.missing = missing

            table.insert(rows, set)
        end
    end

    table.sort(rows, function(a, b)
        if a.missing ~= b.missing then
            return a.missing < b.missing
        end

        return (a.setID or 0) < (b.setID or 0)
    end)

    return rows
end

------------------------------------------------------------
-- THE GUILD
------------------------------------------------------------

function Sets.Guild()
    if not IsInGuild then
        return nil
    end

    local ok, inGuild = pcall(IsInGuild)

    if not ok or not inGuild then
        return nil
    end

    local name, rank, rankIndex

    if GetGuildInfo then
        local gotInfo, guildName, guildRank, guildRankIndex =
            pcall(GetGuildInfo, "player")

        if gotInfo then
            name, rank, rankIndex = guildName, guildRank, guildRankIndex
        end
    end

    return {
        name      = name,
        rank      = rank,
        rankIndex = rankIndex,
    }
end

------------------------------------------------------------
-- WHAT YOU COULD QUEUE FOR
------------------------------------------------------------

-- Deliberately read-only, and deliberately not a queueing button. An addon
-- that puts you in a group finder queue is an addon that will one day do it
-- while you are in a raid.
function Sets.Queues()
    local rows = {}

    if not C_LFGList or not C_LFGList.GetAvailableActivities then
        return rows, false
    end

    local ok, activities = pcall(C_LFGList.GetAvailableActivities)

    if not ok or type(activities) ~= "table" then
        return rows, false
    end

    for _, activityID in ipairs(activities) do
        local gotInfo, info = pcall(C_LFGList.GetActivityInfoTable, activityID)

        if gotInfo and type(info) == "table" and info.fullName then
            table.insert(rows, {
                activityID = activityID,
                name       = info.fullName,
                maxPlayers = info.maxNumPlayers,
            })
        end
    end

    return rows, true
end

------------------------------------------------------------
-- CANDIDATES
------------------------------------------------------------

CN:RegisterEvent("TRANSMOG_COLLECTION_UPDATED", function()
    Sets.Forget()
end)

CN.RegisterCandidateProvider("Sets", function()
    local candidates = {}

    for _, set in ipairs(Sets.NearlyComplete()) do
        if not CN.IsIgnored(CN.objectiveTypes.APPEARANCE, set.setID)
            and not CN.IsDeferred(CN.objectiveTypes.APPEARANCE, set.setID) then

            table.insert(candidates, CN.NewObjective({
                id               = set.setID,
                type             = CN.objectiveTypes.APPEARANCE,
                name             = tostring(set.name or ("Set " .. set.setID))
                    .. ": " .. set.missing .. " piece(s) left",

                -- A REAL denominator, which this addon is normally short of.
                completionValue  = 3 + (3 - math.min(3, set.missing)),
                travelCost       = CN.unknownLocationCost,
                reasons          = {
                    set.collected .. " of " .. set.total .. " pieces collected",
                },
            }))
        end
    end

    return candidates
end, {
    events   = { "TRANSMOG_COLLECTION_UPDATED" },
    cooldown = 60,
})

------------------------------------------------------------
-- COMMAND
------------------------------------------------------------

CN:RegisterCommand{
    name    = "sets",
    aliases = { "guild", "queues" },
    order   = 31,
    help    = "Appearance sets nearly finished, your guild, and what you "
        .. "could queue for.",
    handler = function()
        local rows, readable, examined = Sets.All()

        if not readable then
            Print("|cff8a8f96This client does not expose appearance sets.|r")
        else
            local nearly = Sets.NearlyComplete()

            Print(#rows .. " sets read"
                .. (examined and examined >= Sets.scanCap
                    and (" |cff8a8f96(capped at " .. Sets.scanCap
                        .. "; there are more)|r") or "") .. ".")

            if #nearly == 0 then
                Print("|cff8a8f96None of them is within two pieces.|r")
            else
                Print("Nearly finished:")

                for index, set in ipairs(nearly) do
                    if index > 10 then
                        Print("  |cff8a8f96... and " .. (#nearly - 10) .. " more|r")
                        break
                    end

                    Print(string.format("  |cffffc74f%d left|r %s |cff8a8f96(%d/%d)|r",
                        set.missing, tostring(set.name or set.setID),
                        set.collected, set.total))
                end
            end
        end

        local guild = Sets.Guild()

        if guild then
            Print("Guild: |cffffc74f" .. tostring(guild.name or "?") .. "|r"
                .. (guild.rank and (" |cff8a8f96" .. guild.rank .. "|r") or ""))
        end

        local queues, queueReadable = Sets.Queues()

        if queueReadable and #queues > 0 then
            Print(#queues .. " activities you are eligible to queue for.")
            Print("|cff8a8f96The addon reads that list. It does not queue you "
                .. "for anything.|r")
        end
    end,
}

return Sets
