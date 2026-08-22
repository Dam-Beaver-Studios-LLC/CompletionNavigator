-- Modules/Hud.lua
-- Completion Navigator :: a small always-on frame, and the settings that make
-- the whole addon legible.
--
-- THE HUD.
--
-- Off by default, like everything in this addon that puts pixels on the
-- screen uninvited. It shows one line -- what to do next -- and nothing else,
-- because a heads-up display that needs reading is not a heads-up display.
--
-- Distinct from Follow's frame, which appears only while a route is being
-- walked and shows the current stop. This is for the player who is not
-- following anything and wants the answer visible while they get on with
-- something else.
--
-- ACCESSIBILITY.
--
-- Two settings that cost almost nothing and matter a great deal to the people
-- who need them:
--
--   * A scale, because the default font is small and not everybody's monitor
--     is two feet away.
--   * A colourblind mode for the navigation arrow. The arrow's whole language
--     is colour -- blue on course, amber drifting, red walking away -- which
--     is exactly the design that fails eight percent of men. In this mode the
--     arrow carries a short text label as well, so the information survives
--     the colour being indistinguishable.
--
-- The rule behind both: no information carried by colour alone.

local ADDON_NAME, CN = ...

local Hud = CN:RegisterModule("Hud")

local Print = CN.Print

------------------------------------------------------------
-- SETTINGS
------------------------------------------------------------

-- Named `Preferences`, not `Settings`.
--
-- `Settings` is also the name of the client's global options API since 10.0,
-- and this file's options-panel registration reads `Settings.RegisterCanvas-
-- LayoutCategory` -- which resolved to this local FUNCTION and threw
-- "attempt to index a function value" on every login on every retail client.
-- The error was caught and printed, and because it aborted the function the
-- pre-10.0 fallback below never ran either: the addon has never appeared in
-- the game's own options list, which is the entire purpose of that block.
--
-- The harness never defined SettingsPanel, so the `and` chain short-circuited
-- before the bad index and the suite saw nothing. Same shape as the invented
-- event name: a stub more forgiving than the client.
local function Preferences()
    return CN.Settings() or {}
end

function Hud.IsEnabled()
    return Preferences().hud == true
end

function Hud.Scale()
    local scale = tonumber(Preferences().uiScale)

    if not scale or scale < 0.7 or scale > 2.0 then
        return 1
    end

    return scale
end

function Hud.IsColourblind()
    return Preferences().colourblind == true
end

------------------------------------------------------------
-- THE FRAME
------------------------------------------------------------

local frame, ticker

local function Build()
    if frame or not CreateFrame then
        return frame
    end

    frame = CreateFrame("Frame", "CompletionNavigatorHud", UIParent)

    frame:SetSize(260, 34)
    frame:SetFrameStrata("BACKGROUND")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetClampedToScreen(true)

    local placement = Preferences().hudPosition or {}

    frame:SetPoint(placement.point or "TOP", UIParent,
        placement.point or "TOP", placement.x or 0, placement.y or -220)

    frame.label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.label:SetPoint("TOPLEFT")
    frame.label:SetPoint("TOPRIGHT")
    frame.label:SetJustifyH("LEFT")

    frame.detail = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.detail:SetPoint("TOPLEFT", frame.label, "BOTTOMLEFT", 0, -2)
    frame.detail:SetPoint("TOPRIGHT", frame.label, "BOTTOMRIGHT", 0, -2)
    frame.detail:SetJustifyH("LEFT")

    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()

        local point, _, _, x, y = self:GetPoint()

        Preferences().hudPosition = { point = point, x = x, y = y }
    end)

    frame:SetScale(Hud.Scale())

    frame:Hide()

    return frame
end

Hud.Build = Build

function Hud.Refresh()
    if not frame or not Hud.IsEnabled() then
        return false
    end

    local results = CN.Recommend(1)

    local objective = results and results[1]

    if not objective then
        frame.label:SetText("|cff999999nothing actionable|r")
        frame.detail:SetText("")

        return true
    end

    frame.label:SetText(tostring(objective.name or objective.id))

    local detail = objective.reasons and objective.reasons[1]

    -- WHILE A ROUTE IS BEING WALKED, SAY HOW FAR THROUGH IT YOU ARE.
    --
    -- The reason line is the right thing to show when nothing else is
    -- happening. It is the wrong thing when the player is nine stops into a
    -- twelve-stop route, which is exactly when a glanceable frame earns its
    -- place on the screen.
    local follow = CN:GetModule("Follow")

    if follow and follow.active and (follow.startedWith or 0) > 0 then
        detail = string.format("stop %d of %d",
            math.min((follow.completed or 0) + 1, follow.startedWith),
            follow.startedWith)
    end

    frame.detail:SetText(detail and ("|cff999999" .. detail .. "|r") or "")

    return true
end

function Hud.SetEnabled(enabled)
    Preferences().hud = enabled and true or nil

    if enabled then
        Build()

        if frame then
            frame:SetScale(Hud.Scale())
            frame:Show()
        end

        -- Slow on purpose. The answer to "what next" changes when the player
        -- does something, not several times a second, and a HUD that
        -- recomputes constantly is a HUD that costs frames for nothing.
        if C_Timer and C_Timer.NewTicker and not ticker then
            ticker = C_Timer.NewTicker(5, function()
                pcall(Hud.Refresh)
            end)
        end

        Hud.Refresh()
    else
        if frame then
            frame:Hide()
        end

        if ticker then
            ticker:Cancel()
            ticker = nil
        end
    end

    return Hud.IsEnabled()
end

CN:OnLogin(function()
    if Hud.IsEnabled() then
        Hud.SetEnabled(true)
    end
end)

------------------------------------------------------------
-- ACCESSIBILITY APPLIED
------------------------------------------------------------

-- Everything the addon draws, at the player's scale.
function Hud.ApplyScale()
    local scale = Hud.Scale()

    for _, name in ipairs({
        "CompletionNavigatorFrame",
        "CompletionNavigatorHud",
        "CompletionNavigatorArrow",
        "CompletionNavigatorFollow",
        "CompletionNavigatorWelcome",
    }) do
        local target = _G and _G[name]

        if target and target.SetScale then
            pcall(target.SetScale, target, scale)
        end
    end

    return scale
end

-- The word for a bearing, for players who cannot rely on the colour. Kept
-- very short: it sits under an arrow, not in a paragraph.
function Hud.BearingWord(relative)
    if not relative then
        return "?"
    end

    local off = math.abs(relative)

    -- THROUGH CN.L, LIKE EVERY OTHER STRING A PLAYER READS.
    --
    -- These four are translated into all ten shipped locales and were
    -- returned as English literals, so the one accessibility feature that
    -- exists for players who cannot use the arrow's colours spoke only
    -- English to nine of them.
    if off < 0.35 then
        return CN.L["ahead"]
    end

    if off < 1.2 then
        return CN.L["veer"]
    end

    if off < 2.4 then
        return CN.L["turn"]
    end

    return CN.L["back"]
end

------------------------------------------------------------
-- THE GAME'S OWN OPTIONS LIST
------------------------------------------------------------

-- The addon has had a settings tab since 0.15.0 and it lives inside a window
-- you have to know how to open. Somebody who installs an addon and goes
-- looking for its options goes to the game's options list, finds nothing, and
-- reasonably concludes it has none.
--
-- Registered defensively: the API was replaced wholesale in 10.0 and the old
-- one still exists on older clients, so both paths are here and neither is
-- assumed.
local registered = false

function Hud.RegisterOptionsPanel()
    if registered or not CreateFrame then
        return registered
    end

    local panel = CreateFrame("Frame")

    panel.name = "Completion Navigator"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Completion Navigator")

    local body = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    body:SetPoint("TOPLEFT", 16, -48)
    body:SetPoint("TOPRIGHT", -16, -48)
    body:SetJustifyH("LEFT")
    body:SetText("Everything this addon can do is in its own window, which "
        .. "has a Settings tab of its own.\n\n"
        .. "/cn ui        open the window\n"
        .. "/cn           what to do next\n"
        .. "/cn scale     size of everything it draws\n"
        .. "/cn colourblind   label the arrow in words\n"
        .. "/cn hud       a small always-on line\n"
        .. "/cn selftest  check the addon against your client")

    local open = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    open:SetSize(160, 24)
    open:SetPoint("TOPLEFT", 16, -190)
    open:SetText("Open the window")
    open:SetScript("OnClick", function()
        if CompletionNavigator_ToggleUI then
            CompletionNavigator_ToggleUI()
        end
    end)

    -- Modern path first.
    if SettingsPanel and Settings and Settings.RegisterCanvasLayoutCategory
        and Settings.RegisterAddOnCategory then

        local ok, category = pcall(Settings.RegisterCanvasLayoutCategory,
            panel, panel.name)

        if ok and category then
            category.ID = panel.name

            pcall(Settings.RegisterAddOnCategory, category)

            registered = true
        end
    end

    -- The pre-10.0 API, still present on Classic clients.
    if not registered and InterfaceOptions_AddCategory then
        local ok = pcall(InterfaceOptions_AddCategory, panel)

        registered = ok and true or false
    end

    return registered
end

CN:OnLogin(function()
    Hud.RegisterOptionsPanel()
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "hud",
    args    = "[on or off]",
    order   = 39,
    help    = "A small always-on line showing what to do next.",
    handler = function(args)
        args = string.lower(CN.Trim(args or ""))

        if args == "on" then
            Hud.SetEnabled(true)
        elseif args == "off" then
            Hud.SetEnabled(false)
        else
            Hud.SetEnabled(not Hud.IsEnabled())
        end

        Print("Heads-up display: " .. CN.YesNo(Hud.IsEnabled()))

        if Hud.IsEnabled() then
            Print("|cff999999Drag it where you want it.|r")
        end
    end,
}

CN:RegisterCommand{
    name    = "scale",
    args    = "<0.7 to 2.0>",
    order   = 40,
    help    = "Size of everything this addon draws.",
    handler = function(args)
        local scale = tonumber(CN.Trim(args or ""))

        if not scale then
            Print("Scale: " .. Hud.Scale())
            Print("|cff999999Usage: /cn scale 1.25|r")
            return
        end

        if scale < 0.7 or scale > 2.0 then
            Print("Scale must be between 0.7 and 2.0.")
            return
        end

        Preferences().uiScale = scale

        Hud.ApplyScale()

        Print("Scale set to " .. scale .. ".")
    end,
}

CN:RegisterCommand{
    name    = "colourblind",
    aliases = { "colorblind" },
    args    = "[on or off]",
    order   = 41,
    help    = "Label the arrow in words as well as colour.",
    handler = function(args)
        args = string.lower(CN.Trim(args or ""))

        if args == "on" then
            Preferences().colourblind = true
        elseif args == "off" then
            Preferences().colourblind = nil
        else
            Preferences().colourblind = (not Hud.IsColourblind()) or nil
        end

        Print("Arrow labelled in words: " .. CN.YesNo(Hud.IsColourblind()))

        local navigation = CN:GetModule("Navigation")

        if navigation and navigation.Refresh then
            navigation.Refresh()
        end
    end,
}

CN:RegisterCommand{
    name    = "keepfilter",
    args    = "[on or off]",
    order   = 44,
    help    = "Whether the window's filter box follows you between tabs.",
    handler = function(args)
        args = string.lower(CN.Trim(args or ""))

        local settings = Preferences()

        if args == "on" then
            settings.keepFilter = true
        elseif args == "off" then
            settings.keepFilter = nil
        else
            settings.keepFilter = (not settings.keepFilter) or nil
        end

        Print("Filter follows you between tabs: "
            .. CN.YesNo(settings.keepFilter))

        if not settings.keepFilter then
            -- Turning it off forgets what it was holding. Leaving the term
            -- behind means turning the setting back on later silently applies
            -- a filter the player typed in another session.
            local ui = CN:GetModule("UI")

            if ui then
                ui.persistedFilter = nil
            end

            Print("|cff999999Off is the safer default: a filter that persists "
                .. "invisibly is how a list looks empty when it is not.|r")
        end
    end,
}

CN:RegisterCommand{
    name    = "cues",
    args    = "[on or off]",
    order   = 42,
    help    = "Sound when you arrive, clear a stop, or finish a route.",
    handler = function(args)
        args = string.lower(CN.Trim(args or ""))

        if args == "on" then
            Preferences().cues = true
        elseif args == "off" then
            Preferences().cues = nil
        else
            Preferences().cues = (not Preferences().cues) or nil
        end

        Print("Completion cues: " .. CN.YesNo(Preferences().cues))
    end,
}

return Hud
