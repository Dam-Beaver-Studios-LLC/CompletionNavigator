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
-- ONE SOURCE FOR WHAT A FOCUS IS CALLED AND WHAT IT DOES.
--
-- These carried their own `label` and `note`, and all four had drifted from
-- `CN.modes` -- which is what the Settings tab, `/cn mode` and `/cn status`
-- all read. Three of the four were merely different words for the same thing.
-- The fourth was wrong: the first-run screen described Levelling as "Quests
-- first, collections quiet", and `leveling.show` is `{ QUEST, EXPLORATION }`,
-- which HIDES seventeen of the nineteen types. "Quiet" and "gone" are not the
-- same promise, and this is the screen where the promise is made.
--
-- Names and descriptions come from `CN.modes` now. A mode renamed there is
-- renamed here, and cannot say two things at once.
Welcome.choices = {
    { mode = "leveling" },
    { mode = "collecting" },
    { mode = "reputation" },
    { mode = "everything" },
}

-- What the button says, and what the line under it says.
function Welcome.Describe(mode)
    local definition = CN.modes and CN.modes[mode]

    if not definition then
        return tostring(mode), nil
    end

    return definition.label or tostring(mode), definition.note
end

function Welcome.Choose(mode)
    Welcome.MarkSeen()

    -- "A BIT OF EVERYTHING" SET NOTHING, AND SAID IT HAD.
    --
    -- This short-circuited before `ApplyMode`, so the click handler printed
    -- "Focus set to everything" while `/cn mode` reported no focus and `/cn
    -- mode off` answered "No focus was set, so nothing changed." Worse: with
    -- a focus already active -- from an earlier `/cn mode collecting`, say --
    -- picking "a bit of everything" left thirteen types hidden and told the
    -- player the focus was now everything.
    --
    -- `CN.modes.everything` exists and does exactly the right thing.
    if not mode then
        mode = "everything"
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

    frame:SetSize(432, 300)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)

    -- ESCAPE CLOSES IT, LIKE EVERY OTHER PANEL IN THE GAME.
    --
    -- Three frames this addon creates were on this list and one was not: the
    -- welcome screen -- the only frame most players ever see, shown once, on
    -- first login, over a character they have just logged into. Escape did
    -- nothing, and the close button is a small X in a corner of a dialog that
    -- appears without being asked for.
    if UISpecialFrames then
        table.insert(UISpecialFrames, "CompletionNavigatorWelcome")
    end

    if frame.SetBackdrop then
        frame:SetBackdrop({
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 8, right = 8, top = 8, bottom = 8 },
        })
    end

    local title = CN.Label(frame, "OVERLAY", "TITLE")
    title:SetPoint("TOP", 0, -18)
    title:SetText("Completion Navigator")

    local body = CN.Label(frame, "OVERLAY", "BODY")
    body:SetPoint("TOPLEFT", 24, -48)
    body:SetPoint("TOPRIGHT", -24, -48)
    body:SetJustifyH("LEFT")
    body:SetText("What are you playing for at the moment? This only sets a "
        .. "starting focus " .. CN.DASH .. " everything is still tracked, and "
        .. CN.Accent("/cn mode off") .. " puts it back.")

    -- THE ONE THING THAT ACTUALLY MATTERS, AS A BUTTON.
    --
    -- This screen arrives at the single moment a new player is engaged and
    -- looking at the addon's own interface, and it offered four flavour
    -- presets and no way to do the required step. `/cn setup` was mentioned
    -- in CHAT, after the click. Somebody who pressed "Not now" was told
    -- "Right. /cn whenever you want it." and never heard about it again that
    -- session.
    --
    -- Offered, not run, which is the standing rule -- but offered where the
    -- player is, rather than in a line that scrolls away under login chatter.
    local scan = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")

    scan:SetSize(384, 26)
    scan:SetPoint("TOPLEFT", 24, -96)
    scan:SetText("Read my collections now (a few seconds)")
    -- The client built this label, so `CN.Label` never saw it and the
    -- text-size setting did not reach it. 0.69.0.
    CN.AdoptLabel(scan:GetFontString(), "CAPTION")

    scan:SetScript("OnClick", function()
        local setup = CN:GetModule("Setup")

        if setup then
            scan:SetEnabled(false)
            scan:SetText("Reading" .. CN.DOT .. CN.DOT .. CN.DOT)

            setup.Run(function()
                -- A STATUS MESSAGE IS NOT A BUTTON.
                --
                -- This left a permanently disabled, greyed 384-pixel control
                -- reading "Read. /cn asks what is next." -- a sentence shaped
                -- like something you press.
                if scan and scan.Hide then
                    scan:Hide()
                end

                if frame and frame.scanNote then
                    frame.scanNote:SetText(CN.Good("Read.") .. " "
                        .. CN.Muted("Close this and try ")
                        .. CN.Accent("/cn") .. CN.Muted("."))
                end

                -- The scan is the thing this screen was open for. Once it has
                -- run there is nothing left to do here.
                if frame and frame.Hide then
                    frame:Hide()
                end
            end)
        end
    end)

    frame.scan = scan

    -- Where the scan reports, so the button does not have to become a label.
    frame.scanNote = CN.Label(frame, "OVERLAY", "SMALL")
    frame.scanNote:SetPoint("TOPLEFT", scan, "BOTTOMLEFT", 0, -2)
    frame.scanNote:SetPoint("RIGHT", scan, "RIGHT")
    frame.scanNote:SetJustifyH("LEFT")
    frame.scanNote:SetText("")

    local previous

    for index, choice in ipairs(Welcome.choices) do
        local button = CreateFrame("Button", nil, frame,
            "UIPanelButtonTemplate")

        local label = Welcome.Describe(choice.mode)

        button:SetSize(180, 24)
        button:SetText(label)
        -- The client built this label, so `CN.Label` never saw it and the
        -- text-size setting did not reach it. 0.69.0.
        CN.AdoptLabel(button:GetFontString(), "CAPTION")

        if index == 1 then
            button:SetPoint("TOPLEFT", 24, -140)
        elseif index == 2 then
            button:SetPoint("TOPLEFT", previous, "TOPRIGHT", 12, 0)
        elseif index == 3 then
            button:SetPoint("TOPLEFT", 24, -172)
        else
            button:SetPoint("TOPLEFT", previous, "TOPRIGHT", 12, 0)
        end

        button:SetScript("OnClick", function()
            local _, mode = Welcome.Choose(choice.mode)

            local lines = {
                CN.Accent("/cn") .. CN.Muted(" asks what is next. ")
                    .. CN.Accent("/cn ui") .. CN.Muted(" opens the window."),
            }

            local setup = CN:GetModule("Setup")

            if setup and setup.HasRun and not setup.HasRun() then
                table.insert(lines, CN.Muted("It has not read your "
                    .. "collections yet. ") .. CN.Accent("/cn setup")
                    .. CN.Muted(" does that once."))
            end

            -- THE LABEL THE PLAYER CLICKED, NOT THE TABLE KEY.
            --
            -- This printed `mode`, which is the internal key -- so clicking
            -- the button marked "Reputation" answered "Focus: reputation",
            -- and clicking "Levelling" answered "Focus: leveling", in
            -- American spelling, in an addon that writes colour and
            -- levelling everywhere else. `/cn mode` has always done this
            -- correctly.
            local chosenLabel, chosenNote = Welcome.Describe(mode)

            if chosenNote then
                table.insert(lines, 1, CN.Muted(chosenNote))
            end

            CN.PrintBlock("Focus: " .. CN.Accent(chosenLabel)
                .. CN.Aside(CN.Accent("/cn mode off") .. " undoes it"), lines)

            -- ANSWERING THE QUESTION MUST NOT DESTROY THE CALL TO ACTION.
            --
            -- This screen's primary action is the scan button at the top, and
            -- every focus button closed the frame -- so a player who answered
            -- the question it asked lost the button that does the one setup
            -- step the addon needs, and the only recovery was a chat line
            -- that scrolls away under login chatter.
            --
            -- The choice is marked instead, and the frame stays open until
            -- the scan runs, "Not now" is pressed, or Escape is.
            for _, other in ipairs(frame.choiceButtons or {}) do
                other:SetText(Welcome.Describe(other.cnMode))
            end

            button:SetText(CN.Good("|cff73b873>|r ") .. label)
        end)

        button.cnMode = choice.mode

        frame.choiceButtons = frame.choiceButtons or {}

        table.insert(frame.choiceButtons, button)

        previous = button
    end

    local note = CN.Label(frame, "OVERLAY", "LABEL")
    note:SetPoint("BOTTOMLEFT", 24, 46)
    note:SetPoint("BOTTOMRIGHT", -24, 46)
    note:SetJustifyH("LEFT")
    -- SAY WHAT IS ACTUALLY TRUE OF ALL THREE VERBS.
    --
    -- "Nothing is scanned, sent or changed until you ask" is exactly right
    -- about scanning and sending, and a player will read it as covering the
    -- third: preference learning is on by default and does quietly reweight
    -- the ranking from what they go and do. Nothing leaves the machine, so
    -- this is not a privacy defect -- it is a promise that needs one more
    -- clause to stay true.
    note:SetText("Nothing is scanned or sent until you ask. It does notice "
        .. "which kinds of thing you go and do" .. CN.DASH .. "/cn learned shows what, and "
        .. "undoes it. This appears once.")

    local dismiss = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    dismiss:SetSize(120, 22)
    dismiss:SetPoint("BOTTOM", 0, 16)
    dismiss:SetText("Not now")
    -- The client built this label, so `CN.Label` never saw it and the
    -- text-size setting did not reach it. 0.69.0.
    CN.AdoptLabel(dismiss:GetFontString(), "CAPTION")
    dismiss:SetScript("OnClick", function()
        Welcome.MarkSeen()

        Print("Right. |cffffc74f/cn|r whenever you want it.")

        frame:Hide()
    end)

    frame:Hide()

    -- THE SAVED SCALE REACHES THIS FRAME TOO. 0.90.0. See the note in
    -- `Modules/Navigation.lua`: three of the addon's five named frames are
    -- built lazily, so the login handler's `ApplyScale` could not reach any
    -- of them. This is the frame a first-time player sees.
    local hudModule = CN:GetModule("Hud")

    if hudModule and hudModule.ApplyScale then
        hudModule.ApplyScale()
    end

    return frame
end

function Welcome.Show()
    local built = Welcome.Build()

    if built then
        built:Show()

        -- SHOWN COUNTS AS SEEN.
        --
        -- This marked the window seen only on the button handlers, so a
        -- player who read it and closed it -- or ignored it -- got it again
        -- on every login, against this file's own promise that "it does not
        -- run again. Ever." Answering the question is a choice; being asked
        -- twice is not.
        Welcome.MarkSeen()

        return true
    end

    -- No frame available -- a headless test, or a client that refuses to
    -- create one. Say the same thing in chat rather than silently doing
    -- nothing.
    Print("Installed. |cffffc74f/cn mode leveling|r, "
        .. "|cffffc74fcollecting|r, |cffffc74freputation|r or just "
        .. "|cffffc74f/cn|r to begin.")

    Welcome.MarkSeen()

    return false
end

CN:OnLogin(function()
    if Welcome.HasSeen() then
        return
    end

    -- After the login chatter, and after the setup reminder has had its turn.
    -- Two things talking at once on a first login is worse than either alone.
    --
    -- FOURTEEN SECONDS, NOT EIGHT. The setup reminder is also scheduled at
    -- eight, and because this module loads first its timer fired FIRST -- the
    -- exact opposite of what the sentence above promised, and the player got
    -- the modal with two lines of setup reminder appearing underneath it.
    -- A comment describing an ordering that the code leaves to load order is
    -- not an ordering.
    if C_Timer and C_Timer.After then
        C_Timer.After(14, function()
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
