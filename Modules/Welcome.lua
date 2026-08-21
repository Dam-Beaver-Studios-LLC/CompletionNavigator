-- Modules/Welcome.lua
-- Completion Navigator :: the first sixty seconds.
--
-- An addon is judged before it is understood. This one opened with a slash
-- command and a list of things the player had not asked about, which is a
-- perfectly honest way to present a tool and a poor way to introduce one.
--
-- WHAT THIS IS.
--
-- One question, asked once: what are you playing for right now? The answer
-- sets the focus mode, which the addon already supports and which almost
-- nobody discovers, because `/cn mode collecting` is a sentence you have to
-- already know to type.
--
-- WHAT IT IS NOT.
--
--   * It is not a wizard. One screen, four buttons, and a way out.
--   * It does not run again. Ever. An addon that re-introduces itself is an
--     addon that has not noticed you already met.
--   * It does not block anything. Close it and every command still works
--     exactly as before -- nothing here is a gate.
--   * It changes only the focus, which `/cn mode off` reverses completely.
--     A first-run screen that quietly reconfigures things is a first-run
--     screen people learn to distrust.

local ADDON_NAME, CN = ...

local Welcome = CN:RegisterModule("Welcome")

local Print = CN.Print

------------------------------------------------------------
-- STATE
------------------------------------------------------------

local function Account()
    return CN.Account()
end

function Welcome.HasSeen()
    local account = Account()

    return account and account.welcomed and true or false
end

function Welcome.MarkSeen()
    local account = Account()

    if account then
        account.welcomed = true
    end
end

------------------------------------------------------------
-- THE CHOICES
------------------------------------------------------------

-- Four, because five is a menu and three leaves out collecting or levelling,
-- which are the two most common answers. Each maps onto a focus that already
-- exists rather than inventing new behaviour for the occasion.
Welcome.choices = {
    {
        mode  = "leveling",
        label = "Levelling",
        note  = "Quests first, collections quiet.",
    },
    {
        mode  = "collecting",
        label = "Collecting",
        note  = "Mounts, pets, toys and appearances.",
    },
    {
        mode  = "reputation",
        label = "Reputation & renown",
        note  = "Factions, paragon and renown tracks.",
    },
    {
        mode  = "everything",
        label = "A bit of everything",
        note  = "Balanced. The default.",
    },
}

function Welcome.Choose(mode)
    Welcome.MarkSeen()

    if not mode or mode == "everything" then
        return true, "everything"
    end

    local filters = CN:GetModule("Filters")

    if filters and filters.ApplyMode then
        filters.ApplyMode(mode)
    end

    CN.InvalidateCandidates()

    return true, mode
end

------------------------------------------------------------
-- THE FRAME
------------------------------------------------------------

local frame

function Welcome.Build()
    if frame or not CreateFrame then
        return frame
    end

    frame = CreateFrame("Frame", "CompletionNavigatorWelcome", UIParent,
        BackdropTemplateMixin and "BackdropTemplate" or nil)

    frame:SetSize(420, 260)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)

    if frame.SetBackdrop then
        frame:SetBackdrop({
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 8, right = 8, top = 8, bottom = 8 },
        })
    end

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -18)
    title:SetText("Completion Navigator")

    local body = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    body:SetPoint("TOPLEFT", 24, -48)
    body:SetPoint("TOPRIGHT", -24, -48)
    body:SetJustifyH("LEFT")
    body:SetText("What are you playing for at the moment? This only sets a "
        .. "starting focus -- everything is still tracked, and |cffffff00/cn "
        .. "mode off|r puts it back.")

    local previous

    for index, choice in ipairs(Welcome.choices) do
        local button = CreateFrame("Button", nil, frame,
            "UIPanelButtonTemplate")

        button:SetSize(180, 24)
        button:SetText(choice.label)

        if index == 1 then
            button:SetPoint("TOPLEFT", 24, -104)
        elseif index == 2 then
            button:SetPoint("TOPLEFT", previous, "TOPRIGHT", 12, 0)
        elseif index == 3 then
            button:SetPoint("TOPLEFT", 24, -136)
        else
            button:SetPoint("TOPLEFT", previous, "TOPRIGHT", 12, 0)
        end

        button:SetScript("OnClick", function()
            local _, mode = Welcome.Choose(choice.mode)

            Print("Focus set to |cffffff00" .. mode .. "|r. "
                .. "|cff999999/cn mode off|r undoes it.")
            Print("Ask it anything with |cffffff00/cn|r, or open the window "
                .. "with |cffffff00/cn ui|r.")

            frame:Hide()
        end)

        previous = button
    end

    local note = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note:SetPoint("BOTTOMLEFT", 24, 46)
    note:SetPoint("BOTTOMRIGHT", -24, 46)
    note:SetJustifyH("LEFT")
    note:SetText("Nothing is scanned, sent or changed until you ask. "
        .. "This appears once.")

    local dismiss = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    dismiss:SetSize(120, 22)
    dismiss:SetPoint("BOTTOM", 0, 16)
    dismiss:SetText("Not now")
    dismiss:SetScript("OnClick", function()
        Welcome.MarkSeen()

        Print("Right. |cffffff00/cn|r whenever you want it.")

        frame:Hide()
    end)

    frame:Hide()

    return frame
end

function Welcome.Show()
    local built = Welcome.Build()

    if built then
        built:Show()

        return true
    end

    -- No frame available -- a headless test, or a client that refuses to
    -- create one. Say the same thing in chat rather than silently doing
    -- nothing.
    Print("Completion Navigator is installed. |cffffff00/cn mode leveling|r, "
        .. "|cffffff00collecting|r, |cffffff00reputation|r or just "
        .. "|cffffff00/cn|r to begin.")

    Welcome.MarkSeen()

    return false
end

CN:OnLogin(function()
    if Welcome.HasSeen() then
        return
    end

    -- After the login chatter, and after the setup reminder has had its turn.
    -- Two things talking at once on a first login is worse than either alone.
    if C_Timer and C_Timer.After then
        C_Timer.After(8, function()
            if not Welcome.HasSeen() then
                Welcome.Show()
            end
        end)
    end
end)

CN:RegisterCommand{
    name    = "welcome",
    order   = 38,
    help    = "Show the first-run question again.",
    handler = function()
        Welcome.Show()
    end,
}

return Welcome
