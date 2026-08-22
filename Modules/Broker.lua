-- Modules/Broker.lua
-- Completion Navigator :: LibDataBroker feed, and rare-spawn alerts.
--
-- Two small things that share a theme: telling you something without you
-- having to ask.
--
-- The broker is the addon's answer to "what next?" displayed permanently in
-- whatever bar you already run -- Titan Panel, ElvUI, ChocolateBar. This is
-- the only place the addon touches an external library, and it does so the
-- same way it touches TomTom and AllTheThings: probed, wrapped, optional. If
-- LibDataBroker is not installed nothing happens and nothing is said, because
-- an addon complaining about a library you never asked for is noise.
--
-- Alerts are OFF by default. Unsolicited sound is worse than a waypoint you
-- did not ask for, and this addon has already decided how it feels about that.

local ADDON_NAME, CN = ...

local Broker = CN:RegisterModule("Broker")

local Print      = CN.Print
local DebugPrint = CN.DebugPrint

------------------------------------------------------------
-- LIBDATABROKER
------------------------------------------------------------

Broker.available = false

local dataObject

-- `results` may be supplied by a caller that already has them. The
-- recommendation hook does, and re-asking from inside it is re-entering the
-- function that fired the hook -- which recursed until pcall stopped it and
-- cost seventy times the budget for one refresh. A performance budget caught
-- it before it shipped.
local function CurrentText(results)
    if not results then
        local ok, fetched = pcall(CN.Recommend, 1)

        results = ok and fetched or nil
    end

    if not results or not results[1] then
        return "Completion Navigator", CN.L["nothing actionable"]
    end

    local objective = results[1]

    return tostring(objective.name or objective.id), tostring(objective.type)
end

Broker.CurrentText = CurrentText

function Broker.Refresh(results)
    if not dataObject then
        return
    end

    local name, kind = CurrentText(results)

    dataObject.text  = name
    dataObject.value = name
    dataObject.label = kind
end

function Broker.Install()
    if Broker.available or not LibStub then
        return Broker.available
    end

    -- LibStub's silent form: it returns nil rather than throwing when the
    -- library is absent, which is exactly what optional means.
    local ok, ldb = pcall(LibStub, "LibDataBroker-1.1", true)

    if not ok or not ldb then
        return false
    end

    local created, object = pcall(ldb.NewDataObject, ldb, "CompletionNavigator", {
        type  = "data source",
        text  = "Completion Navigator",
        icon  = CN.MEDIA_PATH .. "Logo",

        OnClick = function(_, button)
            if button == "RightButton" then
                local results = CN.Recommend(1)

                if results and results[1] then
                    CN.NavigateToObjective(results[1])
                end

                return
            end

            if CN.UI and CN.UI.Toggle then
                CN.UI.Toggle()
            end
        end,

        OnTooltipShow = function(tooltip)
            if not tooltip or not tooltip.AddLine then
                return
            end

            tooltip:AddLine("Completion Navigator")

            local results = CN.Recommend(3)

            if not results or #results == 0 then
                tooltip:AddLine("Nothing actionable yet.", 0.6, 0.6, 0.6)
                tooltip:AddLine("Run /cn setup once.", 0.6, 0.6, 0.6)
                return
            end

            for index, objective in ipairs(results) do
                tooltip:AddLine(
                    (index == 1 and "Next: " or "     ")
                        .. tostring(objective.name or objective.id),
                    index == 1 and 0.365 or 0.7,
                    index == 1 and 0.824 or 0.7,
                    index == 1 and 0.984 or 0.7)
            end

            tooltip:AddLine(" ")
            tooltip:AddLine("Left-click to open, right-click to navigate.", 1, 1, 1)
        end,
    })

    if not created or not object then
        return false
    end

    dataObject      = object
    Broker.available = true

    Broker.Refresh()

    DebugPrint("LibDataBroker feed registered.")

    return true
end

------------------------------------------------------------
-- RARE ALERTS
------------------------------------------------------------

-- Which vignettes have already been announced this session. A rare drifting
-- in and out of vignette range must not announce itself repeatedly.
local announced = {}

function Broker.AlertsEnabled()
    local settings = CN.Settings()

    -- Off by default, deliberately. See the file header.
    return settings and settings.rareAlerts == true
end

function Broker.ResetAnnounced()
    announced = {}
end

-- Returns the vignettes worth announcing: up right now, not already announced,
-- not already cleared by this character, and not something you have ignored.
function Broker.PendingAlerts()
    local rares = CN:GetModule("Rares")

    if not rares then
        return {}
    end

    local pending = {}

    for _, vignette in ipairs(rares.GetActive()) do
        local id = vignette.vignetteID

        if id
            and not announced[id]
            and vignette.kind == "RARE"
            and not rares.IsClearedByCharacter(id)
            and not CN.IsIgnored(CN.objectiveTypes.RARE, id) then

            table.insert(pending, vignette)
        end
    end

    return pending
end

function Broker.Announce(vignette)
    announced[vignette.vignetteID] = time()

    Print("|cff5DD2FBRare up:|r " .. tostring(vignette.name or "unknown")
        .. (vignette.x and vignette.y
            and string.format(" |cff999999%.1f, %.1f|r",
                vignette.x * 100, vignette.y * 100)
            or ""))

    if PlaySound then
        -- A quiet, non-alarming stock sound. Raid warnings are for raids.
        pcall(PlaySound, 8959, "Master")
    end

    return true
end

function Broker.CheckAlerts()
    if not Broker.AlertsEnabled() then
        return 0
    end

    local sent = 0

    for _, vignette in ipairs(Broker.PendingAlerts()) do
        Broker.Announce(vignette)

        sent = sent + 1
    end

    return sent
end

------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

for _, event in ipairs({ "VIGNETTE_MINIMAP_UPDATED", "VIGNETTES_UPDATED" }) do
    CN:RegisterEvent(event, function()
        local ok, err = pcall(Broker.CheckAlerts)

        if not ok then
            DebugPrint("Rare alert check failed: " .. tostring(err))
        end
    end)
end

-- A new zone is a new set of rares; nothing carries over.
CN:RegisterEvent("ZONE_CHANGED_NEW_AREA", function()
    Broker.ResetAnnounced()
end)

CN:OnLogin(function()
    Broker.Install()
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "alerts",
    args    = "[on or off]",
    order   = 44,
    help    = "Announce rares that appear near you.",
    handler = function(args)
        local settings = CN.Settings()

        args = string.lower(CN.Trim(args or ""))

        if args == "on" then
            settings.rareAlerts = true
        elseif args == "off" then
            settings.rareAlerts = false
        elseif args ~= "" then
            Print("Usage: /cn alerts [on or off]")
            return
        else
            settings.rareAlerts = not Broker.AlertsEnabled()
        end

        Print("Rare alerts: " .. CN.YesNo(Broker.AlertsEnabled()))

        if Broker.AlertsEnabled() then
            Print("|cff999999Announced once each, only for rares you have not "
                .. "already cleared, and reset when you change zone.|r")
        end
    end,
}

CN:RegisterCommand{
    name    = "broker",
    order   = 45,
    help    = "Show LibDataBroker status.",
    handler = function()
        if Broker.available then
            local name = CurrentText()

            Print("LibDataBroker feed: " .. CN.YesNo(true))
            Print("Currently showing: |cffffff00" .. tostring(name) .. "|r")
            Print("|cff999999Add it from your display addon: Titan Panel, "
                .. "ElvUI datatexts, ChocolateBar.|r")
            return
        end

        Print("LibDataBroker feed: " .. CN.YesNo(false))
        Print("|cff999999LibDataBroker is not installed, which is fine -- it is "
            .. "optional. Display addons like Titan Panel and ElvUI ship it, "
            .. "and the feed appears automatically when one of them is present.|r")
    end,
}

------------------------------------------------------------
-- KEEPING IT CURRENT
------------------------------------------------------------

-- REFRESHED WHEN THE ANSWER CHANGES, WHICH IT NEVER WAS.
--
-- `Broker.Refresh` had exactly one caller: `Install`, from a login hook that
-- runs before the collection scans in their own login hooks have populated
-- anything. So the feed was built from an empty database, almost always
-- settled on "nothing actionable", and then never changed again for the whole
-- session -- in a module whose header calls it "the addon's answer to 'what
-- next?' displayed permanently".
--
-- A recommendation hook is the right place: it fires exactly when the list is
-- recomputed, which is the only time this text can be stale.
if CN.RegisterRecommendationHook then
    CN.RegisterRecommendationHook("Broker", function(results)
        if Broker.available then
            pcall(Broker.Refresh, results)
        end
    end)
end

-- And once shortly after login, because a player who opens no window and
-- asks for nothing should still see a real answer rather than the placeholder
-- the feed was created with.
CN:OnLogin(function()
    if C_Timer and C_Timer.After then
        C_Timer.After(10, function()
            if Broker.available then
                pcall(Broker.Refresh)
            end
        end)
    end
end)

-- CN:APPEND -- cn.ps1 inserts generated commands and event handlers above this line.
