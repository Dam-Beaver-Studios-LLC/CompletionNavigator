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

-- Sixteen for the button plus two of margin. See where the label is anchored.
-- `Hud.closeWidth` REMOVED. 0.78.0: it restated the width the control itself
-- sizes from, in another file. `CN.CLOSE_WIDTH` is the one number.

local function Build()
    if frame or not CreateFrame then
        return frame
    end

    frame = CreateFrame("Frame", "CompletionNavigatorHud", UIParent)

    frame:SetSize(260, 34)

    -- MEDIUM, LIKE EVERY OTHER FRAME THIS ADDON PUTS OVER THE WORLD.
    --
    -- This was BACKGROUND, the lowest strata above the world itself -- and it
    -- is the only frame in the addon that was: the arrow and the follow
    -- frame, which sit over the world in exactly the same way, are both
    -- MEDIUM. At BACKGROUND anything else on screen takes the mouse first,
    -- so the line could not be dragged and its two click actions did nothing,
    -- while its own tooltip promised all three.
    --
    -- Reported from play: "the heads up box should be able to be dragged
    -- around to a different location".
    frame:SetFrameStrata("MEDIUM")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetClampedToScreen(true)

    CN.RestoreFramePosition(frame, Preferences().hudPosition,
        { point = "TOP", relativePoint = "TOP", x = 0, y = -220 })

    -- A PANEL, AND THE ADDON'S OWN MARK ON IT.
    --
    -- The heads-up line and the follow frame were both bare frames with text
    -- hung on them -- no background, no edge, no padding -- while the main
    -- window used a Blizzard template and the welcome screen used parchment.
    -- Three idioms in one addon, and two of them read as text that had come
    -- loose from something.
    --
    -- `UI.PaintPanel` already draws a flat fill and a one-pixel border owing
    -- nothing to any template, which is why it survives Blizzard retiring
    -- one. Low alpha, because this sits over the world and a black box is
    -- worse than no box.
    if CN.UI and CN.UI.PaintPanel then
        CN.UI.PaintPanel(frame, 0.04, 0.05, 0.07, 0.55)
    end

    -- Two pixels of brand blue down the left edge. The cheapest mark in the
    -- addon: it appears here, on the follow frame and under the selected tab,
    -- and it is what makes the three read as one product.
    local rule = frame:CreateTexture(nil, "ARTWORK")
    rule:SetPoint("TOPLEFT")
    rule:SetPoint("BOTTOMLEFT")
    rule:SetWidth(2)
    rule:SetColorTexture(CN.Rgb("BRAND"))
    rule:SetAlpha(0.9)

    local inset = CN.SPACE.S

-- The width the close control reserves along the top-right edge. Declared
-- before the label, which has to keep clear of it.

    -- ROOM FOR THE CLOSE BUTTON.
    --
    -- The X is 16 wide at the top-right corner, and alpha 0 does not disable
    -- mouse input -- so the last stretch of a long objective name sat under a
    -- button that turns the line off rather than navigating to it. The label
    -- stops short of it instead.
    frame.label = CN.Label(frame, "OVERLAY", "HEAD")
    frame.label:SetPoint("TOPLEFT", inset, -inset)
    frame.label:SetPoint("TOPRIGHT", -(inset + CN.CLOSE_WIDTH), -inset)
    frame.label:SetJustifyH("LEFT")

    frame.detail = CN.Label(frame, "OVERLAY", "SMALL")
    frame.detail:SetPoint("TOPLEFT", frame.label, "BOTTOMLEFT", 0, -CN.SPACE.XS)
    frame.detail:SetPoint("TOPRIGHT", frame.label, "BOTTOMRIGHT", 0, -CN.SPACE.XS)
    frame.detail:SetJustifyH("LEFT")

    CN.Outline(frame.label, 13, "PRIMARY")
    CN.Outline(frame.detail, 11, "MUTED")

    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()

        Preferences().hudPosition = CN.SaveFramePosition(self)
            or Preferences().hudPosition
    end)

    -- IT NAMES THE NEXT THING AND COULD NOT BE CLICKED.
    --
    -- The frame was mouse-enabled for dragging and showed the current
    -- recommendation -- so the player read "Kill Ten Rats" on their own
    -- screen and then typed `/cn go`. The two actions the Next tab offers for
    -- the same objective are a left and a right click away, and neither
    -- fights the drag: `OnMouseUp` fires on a click, not on a drag.
    frame:RegisterForDrag("LeftButton")

    frame:SetScript("OnMouseUp", function(clicked, button)
        -- THE ONE IT IS SHOWING, NOT THE ONE SOMETHING ELSE SELECTED.
        --
        -- This read `CN.currentRecommendation`, which only the Next tab,
        -- `/cn next`, the minimap right-click and auto-advance ever write.
        -- A player who turned the heads-up line on and never opened the
        -- window had it nil for the whole session: the line named an
        -- objective, its tooltip promised two clicks, and both did nothing
        -- with no message. And when they diverged -- row 7 selected on the
        -- Next tab -- the line showed #1 and clicking it navigated to 7.
        local objective = clicked.objective or CN.currentRecommendation

        if not objective then
            return
        end

        if button == "RightButton" then
            CN.SetDeferred(objective.type, objective.id, 3600)

            CN.Print("Deferred for an hour: "
                .. tostring(objective.name or objective.id)
                .. CN.Aside(CN.Accent("/cn unhide " .. tostring(objective.id))
                    .. " brings it back now"))

            CN.InvalidateCandidates()

            Hud.Refresh()

            return
        end

        CN.NavigateToObjective(objective)
    end)

    -- A WAY OUT, ON THE THING ITSELF.
    --
    -- Turning this off meant knowing that `/cn hud` exists, or finding the
    -- checkbox on the Settings tab of a window you have to open first. A
    -- frame that appears over the world and cannot be dismissed from itself
    -- is a frame people uninstall the addon to be rid of.
    --
    -- Reported from play: it "should also be able to be closed or turned off
    -- by clicking an x or other appropriate icon or button in or on the heads
    -- up box itself".
    -- THROUGH THE ONE HELPER. 0.77.0.
    --
    -- This was the first of these and it was the only one: the follow list
    -- and the arrow are also drawn over the world, also mouse-enabled, also
    -- draggable, and offered no way out at all. Hoisted into
    -- `CN.AttachCloseControl` so all three read from one definition rather
    -- than two of them going without.
    CN.AttachCloseControl(frame,
        function()
            -- TURNED OFF, NOT HIDDEN.
            --
            -- Hiding it would bring it back on the next refresh, and a
            -- control that undoes itself is worse than no control. This is
            -- the same setting the Settings checkbox and `/cn hud` write, so
            -- all three agree afterwards.
            Hud.SetEnabled(false)

            CN.Print("Heads-up line off. " .. CN.Aside(CN.Accent("/cn hud")
                .. " brings it back"))
        end,
        "Click to navigate to this. Right-click to put it off for an hour. "
        .. "Drag to move this line. The x turns it off.",
        "Turn the heads-up line off. /cn hud brings it back.")

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
        frame.objective = nil

        -- THROUGH THE LOCALE TABLE, LIKE THE OTHER CALL SITE. 0.64.0.
        --
        -- `Modules/Broker.lua` prints `CN.L["nothing actionable"]` for the
        -- same state. The key is canonical and translated in all ten shipped
        -- locale files, and the build lint only requires that a key be used
        -- ONCE -- so a second, hardcoded copy of the same sentence passed
        -- every check. A German player read "nichts zu tun" in the broker
        -- feed and "nothing actionable" an inch away on the heads-up line.
        frame.label:SetText(CN.Muted(CN.L["nothing actionable"]))
        frame.detail:SetText("")

        return true
    end

    -- What the line is showing IS what clicking it acts on. See OnMouseUp.
    frame.objective = objective

    frame.label:SetText(tostring(objective.name or objective.id))

    local detail = CN.FirstReason(objective)

    -- WHILE A ROUTE IS BEING WALKED, SAY HOW FAR THROUGH IT YOU ARE.
    --
    -- The reason line is the right thing to show when nothing else is
    -- happening. It is the wrong thing when the player is nine stops into a
    -- twelve-stop route, which is exactly when a glanceable frame earns its
    -- place on the screen.
    local follow = CN:GetModule("Follow")

    if follow and follow.active and (follow.startedWith or 0) > 0 then
        -- ONE PHRASING PER QUANTITY.
        --
        -- This said "stop 4 of 12" -- counted over hubs in the route -- while
        -- the follow frame two inches away said "Stop: 3 of 5 left", counted
        -- over objectives at the current hub. Two frames on screen at once,
        -- describing the same activity in near-identical words with unrelated
        -- numbers. The follow frame now says "3 left here"; this one keeps
        -- the route-level count, which is the one a glanceable line wants.
        -- TRANSLATED. 0.78.0: this sat two lines under a `CN.L` lookup and
        -- was assembled from an English literal, which is the same defect as
        -- the route-complete line one frame away.
        detail = string.format(CN.L["stop %d of %d"],
            math.min((follow.completed or 0) + 1, follow.startedWith),
            follow.startedWith)
    end

    frame.detail:SetText(detail and ("|cff8a8f96" .. detail .. "|r") or "")

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

    -- THE TEXT SIZE SILENTLY REVERTED ON EVERY RELOAD.
    --
    -- `ApplyScale` is what scales the window, the arrow, the follow frame and
    -- the welcome frame, and it was called from exactly one place: the
    -- command that sets the number. So a player who set Size 1.50 saw it
    -- apply, reloaded, and got everything except the heads-up line back at
    -- 1.0 -- with the button still reading "Size 1.50".
    --
    -- This is the accessibility control the settings rebuild existed for,
    -- because "the players who most need a larger interface are the least
    -- likely to find /cn scale 1.4 in a hundred-line help listing".
    Hud.ApplyScale()
end)

------------------------------------------------------------
-- ACCESSIBILITY APPLIED
------------------------------------------------------------

-- Everything the addon draws, at the player's scale.
-- SETTERS, so the window can offer these two.
--
-- Both accessibility controls were reachable only by typing a slash command,
-- which is the sharpest form of the problem: the players who most need a
-- larger interface or a hue-independent arrow are the least likely to find
-- `/cn scale 1.4`.
function Hud.SetScale(scale)
    scale = tonumber(scale)

    if not scale or scale < 0.7 or scale > 2.0 then
        return false
    end

    Preferences().uiScale = scale

    Hud.ApplyScale()

    return true
end

function Hud.SetColourblind(enabled)
    Preferences().colourblind = enabled or nil

    local navigation = CN:GetModule("Navigation")

    if navigation and navigation.Refresh then
        navigation.Refresh()
    end

    return Hud.IsColourblind()
end

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
            -- A FRAME TALLER THAN THE SCREEN CANNOT BE CLAMPED ONTO IT.
            -- 0.85.0.
            --
            -- The window sets `SetClampedToScreen(true)`, which pins one edge
            -- and lets the opposite one overhang -- it cannot help with a
            -- frame that is simply bigger than the screen. UIParent is 768
            -- units tall, and 0.84.0 grew the window from 480 to 560: at the
            -- Size button's top step, 560 x 1.5 is 840. Forty-eight pixels of
            -- window off one end, applied at BUILD time rather than only when
            -- the button is pressed.
            --
            -- Which end depends on how the clamp resolves, and both are bad:
            -- the footer and the answer line, or the title bar, the close
            -- button and the filter box -- in which case the window can no
            -- longer be dragged or closed with the mouse. And the placement
            -- persists, because the position is saved.
            --
            -- 480 x 1.5 was 720 and fitted, which is why this has never come
            -- up before. The size the player asked for is honoured as far as
            -- the screen allows and no further.
            local applied = scale

            local room = (UIParent and UIParent.GetHeight
                and UIParent:GetHeight()) or 768

            local height = (target.GetHeight and target:GetHeight()) or 0

            if height > 0 and room > 0 and (height * applied) > room then
                applied = room / height
            end

            pcall(target.SetScale, target, applied)
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

    local title = CN.Label(panel, "ARTWORK", "TITLE")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Completion Navigator")

    -- WHAT THIS PANEL SAYS IS WHAT A NEW PLAYER NEEDS FIRST.
    --
    -- It used to list six commands, three of which are display preferences,
    -- and point at bare `/cn`, which printed the addon's internal module
    -- list. It did not mention `/cn setup` -- the one step the addon's own
    -- first-run flow calls required -- so somebody who installed the addon
    -- and went straight to Options learned about text size and never learned
    -- that anything needed reading.
    --
    -- Three sentences and two buttons. The settings themselves live one click
    -- away, in the window, where there is room to group them.
    local body = CN.Label(panel, "ARTWORK", "BODY")
    body:SetPoint("TOPLEFT", 16, -48)
    body:SetPoint("TOPRIGHT", -16, -48)
    body:SetJustifyH("LEFT")
    body:SetText("Answers \"what should I do next?\" " .. CN.DASH .. " ranks what is worth "
        .. "doing now, costs the journey the way you would really make it, "
        .. "and shows its working when you ask why.\n\n"
        .. "1.  Scan once, so it knows what you have.\n"
        .. "2.  Type /cn to ask what is next.\n"
        .. "3.  Open the window for everything else. Its Settings tab has "
        .. "text size, the colourblind arrow labels, sound, and what the "
        .. "addon draws on screen.")

    local scan = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    scan:SetSize(190, 24)
    scan:SetPoint("TOPLEFT", 16, -190)
    scan:SetText("Scan my collections")
    -- The client built this label, so `CN.Label` never saw it and the
    -- text-size setting did not reach it. 0.69.0.
    CN.AdoptLabel(scan:GetFontString(), "CAPTION")
    scan:SetScript("OnClick", function()
        local setup = CN:GetModule("Setup")

        if setup then
            setup.Run()
        end
    end)

    local open = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    open:SetSize(160, 24)
    open:SetPoint("LEFT", scan, "RIGHT", 8, 0)
    open:SetText("Open the window")
    -- The client built this label, so `CN.Label` never saw it and the
    -- text-size setting did not reach it. 0.69.0.
    CN.AdoptLabel(open:GetFontString(), "CAPTION")
    open:SetScript("OnClick", function()
        if CompletionNavigator_ToggleUI then
            CompletionNavigator_ToggleUI()
        end
    end)

    local version = CN.Label(panel, "ARTWORK", "LABEL")
    version:SetPoint("TOPLEFT", scan, "BOTTOMLEFT", 0, -12)
    version:SetText("v" .. tostring(CN.version)
        .. "  " .. CN.DOT .. "  Dam Beaver Studios, LLC")

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

        Print("Heads-up line: " .. CN.YesNo(Hud.IsEnabled()))

        if Hud.IsEnabled() then
            Print("|cff8a8f96Drag it where you want it.|r")
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
            Print(string.format("Size: %.2f", Hud.Scale()))
            Print("|cff8a8f96Usage: /cn scale 1.25|r")
            return
        end

        if scale < 0.7 or scale > 2.0 then
            Print("Scale must be between 0.7 and 2.0.")
            return
        end

        Hud.SetScale(scale)

        Print("Scale set to " .. scale .. ".")
    end,
}

CN:RegisterCommand{
    name    = "textsize",
    aliases = { "text" },

    -- WHAT THE SETTER ACTUALLY ACCEPTS. 0.88.0. Three constants described
    -- one ceiling and disagreed: this said 150, the rejection message below
    -- says 200, and `CN.SetTextScale` accepts up to 200. So `/cn help` told
    -- the players who most need larger text that 150 was the limit -- on the
    -- accessibility control the surrounding notes say was rebuilt precisely
    -- because those players are least likely to go hunting for a command.
    args    = "<100 to 200>",
    order   = 40.5,
    help    = "Size of the text in the window, without resizing it.",
    handler = function(args)
        local typed = CN.Trim(args or "")

        if typed == "" then
            Print(string.format("Text size: %d%%",
                math.floor(CN.TextScale() * 100 + 0.5)))
            Print("|cff8a8f96Usage: /cn textsize 130. `/cn scale` resizes the "
                .. "whole window instead.|r")
            return
        end

        local asked = tonumber(typed)

        if not asked then
            Print("Usage: /cn textsize 130")
            return
        end

        -- A PERCENTAGE OR A MULTIPLIER, WHICHEVER THEY TYPED. Both readings
        -- are obvious and only one of them can be meant: nobody wants their
        -- text at 130 times its size, and nobody wants it at 1.3 percent.
        if asked > 3 then
            asked = asked / 100
        end

        if not CN.SetTextScale(asked) then
            Print("Text size must be between 100% and 200%.")
            return
        end

        Print(string.format("Text size: %d%%",
            math.floor(CN.TextScale() * 100 + 0.5)))

        Print("|cff8a8f96Applied to text already on screen. `/cn scale` "
            .. "resizes the whole window instead.|r")
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
            Hud.SetColourblind(true)
        elseif args == "off" then
            Hud.SetColourblind(false)
        else
            Hud.SetColourblind(not Hud.IsColourblind())
        end

        Print("Arrow labelled in words: " .. CN.YesNo(Hud.IsColourblind()))
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
            -- `CN.UI`, NOT `CN:GetModule("UI")`.
            --
            -- UI.lua publishes itself as `CN.UI` (UI.lua:24) and never calls
            -- `RegisterModule`, so the lookup returned nil, the branch never
            -- ran, and this command printed "a filter that persists invisibly
            -- is how a list looks empty when it is not" while leaving exactly
            -- that filter in memory. The checkbox path did it correctly, so
            -- the setting worked from the window and not from the command.
            if CN.UI then
                CN.UI.persistedFilter = nil
            end

            Print("|cff8a8f96Off is the safer default: a filter that persists "
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

        Print("Sound when you clear a stop: " .. CN.YesNo(Preferences().cues))
    end,
}

return Hud
