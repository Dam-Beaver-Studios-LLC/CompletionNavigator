-- UI.lua
-- Completion Navigator :: minimap button, main window, and tab framework.
--
-- Every command in this addon is reachable by clicking. Typing is the
-- power-user path, not the required path.
--
-- Tabs are registered, not hardcoded, so a module can contribute its own
-- panel without this file knowing it exists:
--
--   CN.UI.RegisterTab{
--       name    = "Pets",
--       order   = 40,
--       build   = function(content) end,   -- once, on first show
--       refresh = function(content) end,   -- every time it becomes visible
--   }
--
-- No external libraries. LibDBIcon and Ace would each drag in an embedded
-- library tree, and the minimap button below is about eighty lines.

local ADDON_NAME, CN = ...

local UI = {}

CN.UI = UI

-- Published for UI/List.lua, which draws the rows inside this chrome and has
-- to know how wide they get and how tall they are.
UI.WINDOW_WIDTH = 560
UI.ROW_HEIGHT   = 20

-- How wide the right-aligned value column is on the rows that use one. Wide
-- enough for the longest thing any tab puts there -- the reputation row's
-- "412 account-wide, 96 this character" -- and zero on the rows that do not,
-- which is most of them.
UI.VALUE_WIDTH  = 210

-- LATE-BOUND ON PURPOSE.
--
-- The tab builders below call UI.CreateList rather than a local, because
-- UI/List.lua loads AFTER this file: a local captured here would be nil
-- forever. The first version of the split left them calling a bare
-- `CreateList`, which resolved to a global that does not exist -- every tab
-- would have failed to build in game. luacheck caught it; the harness did
-- not, because it never builds all eleven tabs.

local Print = CN.Print

local WINDOW_WIDTH  = 560
local WINDOW_HEIGHT = 480

-- THE TAB STRIP AND THE FILTER BOX WERE DRAWN ON TOP OF EACH OTHER.
--
-- The search box sat at TOPRIGHT -30, -26 and occupied the band 26 to 46
-- pixels down. The tab row started at -30 and is 22 tall, so it occupied 30
-- to 52. With the eleven registered tabs, seven fit on the first row and the
-- last two of them -- Zone and Warband -- were drawn underneath the filter
-- box and its label, in the default configuration, on every install.
--
-- The wrap test could not have known: it measured against the window's width
-- and the search box is not a tab.
--
-- Fixed by giving each its own band rather than by making the wrap cleverer.
-- The search row owns the top; the tabs start below it; the window grows by
-- the forty pixels that costs so the lists keep their depth.
local SEARCH_TOP     = -26
local TAB_STRIP_TOP  = -54
local TAB_ROW_HEIGHT = 26
local TAB_MARGIN     = 24

local window, minimapButton

-- A BUTTON'S ANSWER, PUT WHERE THE BUTTON IS.
--
-- Replaces `Print` at every call site inside a button handler. The window
-- gets the line if it is open -- the click happened there, so the answer
-- belongs there -- and chat gets it if it is not, which is how the same
-- handler behaves when a slash command reaches it.
--
-- Never both: the same sentence in two places reads as two things happening.
-- HOW FAR AWAY, IN TIME THE PLAYER RECOGNISES. 0.68.0.
--
-- Two 0.67.0 tooltips printed `CN.TravelCost` as minutes. It is not minutes:
-- a cost point is `Travel.secondsPerCostPoint` seconds -- thirty -- so every
-- one of those lines reported double the addon's own estimate. And
-- `CN.TravelCost` never returns nil: on a miss it returns the pessimism
-- constant the scorer uses to rank an unknown location, so "About 40 minutes
-- away" was printed for a rare thirty yards off whenever the client had not
-- yet answered about the player's position.
--
-- A journey the addon cannot estimate is not described at all. Saying nothing
-- is the honest form of not knowing, and every other travel line in this
-- addon already works that way.
-- HOW MANY ROWS THE MAIN LIST DRAWS. Named once, because a tooltip that
-- counts over a different number than the list shows is making a promise
-- about rows that are not there. 0.68.0.
UI.listLimit = 12

-- THROUGH THE SAME FUNCTION `/cn list` USES, AND THROUGH THE CACHE. 0.72.0.
--
-- This called `Travel.EstimateSeconds` directly. Two consequences, both
-- visible: it skipped `Travel.CostFor`'s cache, so every hover ran a fresh
-- walk of the flight network; and it applied the confidence flag but not the
-- clamp, so a rare forty minutes away printed a confident duration in the
-- tooltip while its row in `/cn list` printed no distance at all.
--
-- `CN.TravelText` is the one place that turns a journey into words.
function UI.DistanceLine(mapID, x, y)
    if not mapID or not x or not y then
        return nil
    end

    local cost, costed = CN.TravelCost(mapID, x, y)

    local text, exact, ceiling = CN.TravelText({
        mapID        = mapID,
        x            = x,
        y            = y,
        travelCost   = cost,
        travelCosted = costed or nil,
    })

    if not text then
        return nil
    end

    if not exact then
        -- THE SAME WORDS `/cn list` USES, plus the reason. Two surfaces
        -- phrasing one fact two ways is how a player ends up thinking they
        -- are two facts.
        return "About " .. (ceiling or text)
            .. " away at least; the addon stops measuring past that."
    end

    return "About " .. text .. " away by the route this addon would take."
end

-- The line under the filter box. Separate from `UI.Answer` on purpose: a
-- search hint and the result of a button press are two different sentences
-- and neither may silently replace the other.
function UI.ShowElsewhere(text)
    if window and window.elsewhere then
        window.elsewhere:SetText(text and CN.Accent(text) or "")

        return true
    end

    return false
end

function UI.Answer(text)
    text = tostring(text)

    if window and window:IsShown() and window.answer then
        window.answer:SetText(CN.Body(text))

        -- The next click's answer replaces this one, and so does a tab
        -- change -- see SelectTab. A stale answer beside a different tab is
        -- worse than no answer.
        return true
    end

    Print(text)

    return false
end


------------------------------------------------------------
-- TEMPLATE SAFETY
------------------------------------------------------------

-- Blizzard renames and retires XML templates between expansions. A missing
-- template makes CreateFrame throw, which would take the entire window with
-- it. Every templated frame in this file goes through here so a retired
-- template degrades to a plain frame instead of no UI at all.
local function SafeCreateFrame(frameType, name, parent, template)
    if template then
        local ok, frame = pcall(CreateFrame, frameType, name, parent, template)

        if ok and frame then
            return frame, true
        end

        CN.DebugPrint("Template '" .. tostring(template)
            .. "' is unavailable; falling back to a plain frame.")
    end

    return CreateFrame(frameType, name, parent), false
end

UI.SafeCreateFrame = SafeCreateFrame

-- Draws a background and a one-pixel border with plain textures. Owes
-- nothing to any template or to the Backdrop system.
local function PaintPanel(frame, r, g, b, a)
    local background = frame:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints()
    background:SetColorTexture(r or 0.05, g or 0.05, b or 0.06, a or 0.94)

    local edges = {
        { "TOPLEFT", "TOPRIGHT", 0, 0, 0, -1 },
        { "BOTTOMLEFT", "BOTTOMRIGHT", 0, 1, 0, 0 },
        { "TOPLEFT", "BOTTOMLEFT", 0, 0, 1, 0 },
        { "TOPRIGHT", "BOTTOMRIGHT", -1, 0, 0, 0 },
    }

    for _, edge in ipairs(edges) do
        local line = frame:CreateTexture(nil, "BORDER")
        line:SetColorTexture(0.35, 0.35, 0.38, 1)
        line:SetPoint(edge[1], edge[3], edge[4])
        line:SetPoint(edge[2], edge[5], edge[6])

        if edge[1] == "TOPLEFT" and edge[2] == "TOPRIGHT" then
            line:SetHeight(1)
        elseif edge[1] == "BOTTOMLEFT" then
            line:SetHeight(1)
        else
            line:SetWidth(1)
        end
    end

    return background
end

UI.PaintPanel = PaintPanel

------------------------------------------------------------
-- TAB REGISTRY
------------------------------------------------------------

UI.tabs = {}

function UI.RegisterTab(definition)
    if type(definition) ~= "table" or not definition.name then
        return
    end

    definition.order = definition.order or 100

    table.insert(UI.tabs, definition)

    table.sort(UI.tabs, function(a, b)
        if a.order == b.order then
            return a.name < b.name
        end

        return a.order < b.order
    end)

    -- A tab registered after the window was built still needs a button.
    if window then
        UI.RebuildTabs()
    end
end

-- WHERE EACH TAB GOES NEXT.
--
-- Named per tab rather than as one global pointer at `/cn help`, because
-- "what else is there" has a different answer on the Collections tab than on
-- the Journey tab, and the useful moment to answer it is while somebody is
-- looking at one of them.
UI.tabFooters = {
    Next        = "/cn why  Â·  /cn order  Â·  /cn plan 30",
    Journey     = "/cn zones  Â·  /cn elsewhere  Â·  /cn loremaster",
    Zone        = "/cn zone  Â·  /cn follow  Â·  /cn unpicked",
    Now         = "/cn clock  Â·  /cn rares  Â·  /cn vault",
    Goals       = "/cn goal <type> <name or id>  Â·  /cn chase  Â·  /cn gogoal",
    Warband     = "/cn alts  Â·  /cn who <type> <name>  Â·  /cn recipes",
    Vault       = "/cn vault  Â·  /cn instances  Â·  /cn clock",
    Collections = "/cn breakdown  Â·  /cn closest  Â·  /cn drops <name>",
    Remaining   = "/cn breakdown  Â·  /cn progress  Â·  /cn whyzero",
    Scans       = "/cn setup  Â·  /cn dbsize  Â·  /cn providers",
    Settings    = "/cn selftest  Â·  /cn errors  Â·  /cn perf",
}

------------------------------------------------------------
-- SCROLLING LIST
------------------------------------------------------------


------------------------------------------------------------
-- BUTTON HELPERS
------------------------------------------------------------

-- FADED IN AND OUT.
--
-- Nothing in the addon faded: the window, the arrow and the two world frames
-- all appeared and vanished between one frame and the next. A hundred and
-- fifty milliseconds is below the threshold at which anybody would call it an
-- animation, and above the one at which a window stops feeling like it was
-- pasted onto the screen. `UIFrameFadeIn` and `UIFrameFadeOut` are stock
-- globals with no library behind them.
local function FadeIn(frame, seconds)
    if not frame then
        return
    end

    if UIFrameFadeIn then
        frame:SetAlpha(0)
        frame:Show()

        pcall(UIFrameFadeIn, frame, seconds or 0.15, 0, 1)

        return
    end

    frame:Show()
end

UI.FadeIn = FadeIn

-- TOOLTIPS ON THE CONTROLS THEMSELVES.
--
-- The minimap button had an excellent one. Not one of the window's
-- twenty-five buttons or six checkboxes had any, so "Re-route", "Next step",
-- "Rescan zones", "Filter types" and the priority cycler all had to be
-- guessed at. This is the difference between a window a new player explores
-- and one they close.
-- IT COMPOSES, RATHER THAN REPLACING.
--
-- A frame that already had an `OnEnter` -- to show a close button, to
-- highlight, to do anything on hover -- silently lost it the moment somebody
-- gave it a tooltip, because `SetScript` replaces. That is a trap that is
-- invisible at the call site and depends on the order two unrelated lines
-- happen to be written in, which is not a property anybody can hold in their
-- head. The heads-up line hit it within an hour of the close button being
-- added.
local function AttachTooltip(frame, tooltip)
    if not frame or not tooltip or not GameTooltip then
        return
    end

    local existingEnter = frame:GetScript("OnEnter")
    local existingLeave = frame:GetScript("OnLeave")

    frame:SetScript("OnEnter", function(hovered, ...)
        if existingEnter then
            existingEnter(hovered, ...)
        end

        GameTooltip:SetOwner(hovered, "ANCHOR_RIGHT")

        -- A FUNCTION IS ALLOWED HERE TOO. 0.61.0.
        --
        -- `UI/List.lua` resolves a function tooltip and carries a comment
        -- explaining why that is the cheaper shape. This one did not, so the
        -- addon had two tooltip paths with different contracts and nothing
        -- checking one against the other -- and a caller that passed a
        -- function got the string "function: 0x..." on screen rather than an
        -- error, which is the kind of defect that ships.
        --
        -- Same theme as the invalidator and the window's refresh events:
        -- two lists, one of which nobody checks against the other.
        local text = tooltip

        if type(text) == "function" then
            local ok, built = pcall(text)

            text = ok and built or nil
        end

        if not text then
            return
        end

        GameTooltip:SetText(text, 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)

    frame:SetScript("OnLeave", function(hovered, ...)
        if existingLeave then
            existingLeave(hovered, ...)
        end

        GameTooltip:Hide()
    end)
end

UI.AttachTooltip = AttachTooltip

local function AddButton(parent, text, width, onClick, tooltip)
    local button, templated = SafeCreateFrame("Button", nil, parent, "UIPanelButtonTemplate")

    button:SetSize(width or 110, 22)

    if not templated then
        -- A plain Button has no artwork and no font string of its own.
        PaintPanel(button, 0.16, 0.16, 0.19, 1)

        local label = CN.Label(button, "ARTWORK", "CAPTION")
        label:SetPoint("CENTER")
        button:SetFontString(label)

        local highlight = button:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetAllPoints()
        highlight:SetColorTexture(1, 1, 1, 0.12)
    elseif button.GetFontString then
        -- The templated path arrives with its own label, so `CN.Label` never
        -- saw it and the text-size setting did not reach it. 0.67.0.
        CN.AdoptLabel(button:GetFontString(), "CAPTION")
    end

    button:SetText(text)
    button:SetScript("OnClick", onClick)

    AttachTooltip(button, tooltip)

    return button
end

local function AddCheckbox(parent, text, getter, setter, tooltip)
    local check = SafeCreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")

    check:SetSize(24, 24)

    check.cnTooltip = tooltip

    if check.Text then
        check.Text:SetText(text)

        CN.AdoptLabel(check.Text, "BODY")
    else
        local label = CN.Label(check, "ARTWORK", "BODY")
        label:SetPoint("LEFT", check, "RIGHT", 2, 0)
        label:SetText(text)
        check.Text = label
    end

    check:SetScript("OnClick", function(self)
        setter(self:GetChecked() and true or false)
    end)

    check.Refresh = function()
        check:SetChecked(getter() and true or false)

        -- THE HIT AREA IS RE-MEASURED, NOT MEASURED ONCE. 0.68.0.
        --
        -- `Fit` was published and called exactly once, at build time. At
        -- Text 150% the label is half again as wide as the invisible button
        -- behind it, so the last third of the words showed no tooltip and did
        -- not toggle the box -- while the same words at 100% did both.
        if check.Fit then
            check.Fit()
        end
    end

    AttachTooltip(check, tooltip)

    -- THE HIT AREA HAS TO COVER THE WORDS.
    --
    -- The box is 24x24 and the label hangs outside it; FontStrings take no
    -- mouse input. So twelve checkboxes carried their only explanation on a
    -- 24-pixel square, and hovering the words -- the natural target, and the
    -- only place the "off by default, the most intrusive thing this addon can
    -- do" note lives -- showed nothing. `AddButton`'s tooltip covers its whole
    -- control, so the two idioms behaved differently in one panel.
    --
    -- A transparent button over box + label, rather than widening the check's
    -- own hit rect: the rect would swallow clicks meant for whatever sits to
    -- the right of it, and this is a hover target that also forwards a click.
    if check.Text and check.Text.GetStringWidth then
        local reach = SafeCreateFrame("Button", nil, parent)

        reach:SetPoint("TOPLEFT", check, "TOPLEFT")
        reach:SetPoint("BOTTOMLEFT", check, "BOTTOMLEFT")

        -- Recomputed on refresh, because a label can be translated.
        local function Fit()
            local measured = check.Text:GetStringWidth()

            if type(measured) ~= "number" then
                measured = 0
            end

            reach:SetWidth(math.max(24, 24 + 2 + measured))
        end

        Fit()

        reach:SetScript("OnClick", function()
            check:Click()
        end)

        AttachTooltip(reach, tooltip)

        -- Behind the box, so the box's own click still reaches it first.
        if reach.SetFrameLevel and check.GetFrameLevel then
            local level = check:GetFrameLevel()

            if type(level) == "number" and level > 0 then
                reach:SetFrameLevel(level - 1)
            end
        end

        check.reach = reach
        check.Fit   = Fit
    end

    return check
end

UI.AddButton   = AddButton
UI.AddCheckbox = AddCheckbox

------------------------------------------------------------
-- WINDOW
------------------------------------------------------------

local function BuildWindow()
    if window then
        return window
    end

    -- Prefer Blizzard's frame so the window matches the rest of the game.
    -- The hand-painted fallback below only runs if that template is ever
    -- retired or renamed, which has happened to other templates before.
    local templated

    window, templated = SafeCreateFrame("Frame", "CompletionNavigatorFrame", UIParent,
        "BasicFrameTemplateWithInset")

    window:SetSize(WINDOW_WIDTH, WINDOW_HEIGHT)
    window:SetPoint("CENTER")
    window:SetMovable(true)
    window:EnableMouse(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", window.StartMoving)
    window:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        UI.SavePosition()
    end)
    window:SetClampedToScreen(true)
    window:SetFrameStrata("DIALOG")
    window:SetToplevel(true)
    window:Hide()

    if templated and window.TitleText then
        -- The version, where somebody looking for it would look. It used to
        -- appear in exactly one place a player might find: the bottom right
        -- of the Settings tab, in grey, at ten points.
        window.TitleText:SetText("Completion Navigator "
            .. CN.Muted("v" .. tostring(CN.version)))
    else
        PaintPanel(window)

        local titleBar = CreateFrame("Frame", nil, window)
        titleBar:SetPoint("TOPLEFT", 1, -1)
        titleBar:SetPoint("TOPRIGHT", -1, -1)
        titleBar:SetHeight(24)

        local titleBackground = titleBar:CreateTexture(nil, "ARTWORK")
        titleBackground:SetAllPoints()
        titleBackground:SetColorTexture(0.13, 0.13, 0.16, 1)

        local title = CN.Label(titleBar, "OVERLAY", "HEAD")
        title:SetPoint("LEFT", 10, 0)
        -- The fallback title, which must say the same thing as the
        -- templated one above -- these were two separate literals and could
        -- silently drift.
        title:SetText("Completion Navigator "
            .. CN.Muted("v" .. tostring(CN.version)))

        local close = CreateFrame("Button", nil, window)
        close:SetSize(22, 22)
        close:SetPoint("TOPRIGHT", -3, -2)

        local closeLabel = CN.Label(close, "OVERLAY", "TITLE")
        closeLabel:SetPoint("CENTER")
        closeLabel:SetText("x")
        close:SetFontString(closeLabel)

        local closeHighlight = close:CreateTexture(nil, "HIGHLIGHT")
        closeHighlight:SetAllPoints()
        closeHighlight:SetColorTexture(0.8, 0.1, 0.1, 0.4)

        close:SetScript("OnClick", function()
            window:Hide()
        end)
    end

    -- Escape should close it, like every other panel in the game.
    if UISpecialFrames then
        table.insert(UISpecialFrames, "CompletionNavigatorFrame")
    end

    window.tabButtons = {}

    -- A FILTER BOX, ONE PER WINDOW.
    --
    -- Sits above the tabs so it plainly applies to whatever tab is showing,
    -- rather than looking like part of one tab's contents. Empty by default
    -- and cleared when the tab changes: a filter that persists invisibly
    -- across tabs is how somebody concludes a list is empty when it is not.
    local search = CreateFrame("EditBox", nil, window, "InputBoxTemplate")

    search:SetSize(160, 20)
    search:SetPoint("TOPRIGHT", -30, SEARCH_TOP)
    search:SetAutoFocus(false)
    search:SetMaxLetters(40)

    local searchLabel = CN.Label(window, "OVERLAY", "LABEL")
    searchLabel:SetPoint("RIGHT", search, "LEFT", -6, 0)
    searchLabel:SetText("filter")

    search:SetScript("OnTextChanged", function(self)
        UI.SetFilter(self:GetText())

        -- AND SAY WHERE ELSE IT IS -- IN ITS OWN LINE. 0.67.0.
        --
        -- 0.66.0 wrote this into `UI.Answer`, which is the line where the
        -- result of clicking a button goes, and passed `or ""` when nothing
        -- matched elsewhere -- so typing a single character after pressing
        -- "Scan everything" wiped "Read 6 collections." off the screen with
        -- nothing, and there was no way to get it back.
        UI.ShowElsewhere(UI.SearchElsewhere(self:GetText()))
    end)

    -- KEEP THE FILTER ACROSS TABS, OR CLEAR IT?
    --
    -- It clears on a tab change, which is the safer default: a filter that
    -- persists invisibly is how somebody concludes a list is empty when it is
    -- not. But a player comparing the same search across tabs -- looking for
    -- one mount in Collections and then in Goals -- wants the opposite, and
    -- was retyping it every time.
    --
    -- So: a setting, defaulting to the safe behaviour, and the box shows what
    -- it is doing rather than leaving the player to work it out.
    search:SetScript("OnEditFocusLost", function(self)
        local settings = CN.Settings()

        if settings and settings.keepFilter then
            -- WRITTEN UNCONDITIONALLY, INCLUDING WHEN IT IS EMPTY.
            --
            -- The guard here used to be `self:GetText() ~= ""`, and nothing
            -- else ever cleared `UI.persistedFilter` -- so clearing the box
            -- did not clear the memory, and the next tab change put the old
            -- term straight back and applied it. The player could not clear a
            -- persisted filter except by typing a different one, which is
            -- precisely the "a filter that persists invisibly is how a list
            -- looks empty when it is not" case this feature's own help text
            -- warns about.
            local text = self:GetText()

            if text == "" then
                UI.persistedFilter = nil
            else
                UI.persistedFilter = text
            end
        end
    end)

    search:SetScript("OnEscapePressed", function(self)
        self:SetText("")
        self:ClearFocus()
    end)

    -- The cross-tab hint's own line, so it cannot overwrite an answer.
    -- BESIDE THE BOX, NOT UNDER IT. 0.68.0.
    --
    -- Anchored below the search box it descended into the tab strip -- the
    -- strip starts six pixels under the box's bottom edge, and the tab
    -- buttons are frames, so they draw over a font string on the window. At
    -- Text 150% it was a line of text behind the first row of tabs.
    --
    -- SMALL and ACCENT, not LABEL and MUTED: this line carries information --
    -- which tabs hold what you are looking for -- and this file's own palette
    -- note reserves the muted, disabled face for text that does not.
    window.elsewhere = CN.Label(window, "OVERLAY", "SMALL")
    window.elsewhere:SetPoint("RIGHT", searchLabel, "LEFT", -8, 0)

    -- BOUNDED ON BOTH EDGES. 0.69.0.
    --
    -- Anchored on one edge a font string grows in the other direction without
    -- limit, and this one can carry four tab names and their counts -- about
    -- 290 pixels at normal size and 435 at Text 150%, in roughly 325 of room.
    -- The overflow is drawn outside the window, over the world.
    window.elsewhere:SetPoint("LEFT", window, "LEFT", CN.SPACE.M, 0)

    if window.elsewhere.SetWordWrap then
        window.elsewhere:SetWordWrap(false)
    end

    window.elsewhere:SetJustifyH("RIGHT")
    window.elsewhere:SetTextColor(CN.Rgb("ACCENT"))
    window.elsewhere:SetText("")

    window.search      = search
    window.searchLabel = searchLabel

    window.body = CreateFrame("Frame", nil, window)
    window.body:SetPoint("TOPLEFT", 10, -58)
    window.body:SetPoint("BOTTOMRIGHT", -10, 34)

    -- A ROUTE FROM THE WINDOW TO THE HUNDRED AND TWENTY COMMANDS.
    --
    -- This said "/cn help for the full command list" and that was the entire
    -- bridge: eleven tabs on one side, a hundred and twenty-five commands on
    -- the other, and one line pointing at a wall of text.
    --
    -- Each tab names the two or three commands that go deeper from THAT tab,
    -- at the moment they are relevant, which surfaces about twenty-five
    -- buried commands for the cost of one fontstring.
    window.footer = CN.Label(window, "ARTWORK", "SMALL")
    window.footer:SetTextColor(CN.Rgb("MUTED"))
    window.footer:SetPoint("BOTTOMLEFT", CN.SPACE.M, CN.SPACE.M)
    window.footer:SetPoint("BOTTOMRIGHT", -CN.SPACE.M, CN.SPACE.M)
    window.footer:SetJustifyH("LEFT")
    window.footer:SetText("/cn help for the full command list")

    -- WHERE A BUTTON'S ANSWER GOES.
    --
    -- Every button in this window answered into the chat frame. A player
    -- clicking "Scan everything" was looking at the window; the sentence
    -- saying what happened appeared behind it, in a scrolling log they may
    -- have moved, resized or filtered. Eleven buttons, and the result of
    -- clicking any of them was somewhere else on the screen.
    --
    -- One line under the tabs, in the window, where the click happened. Chat
    -- still gets it when the window is not open, because the same handlers
    -- run from slash commands.
    window.answer = CN.Label(window, "ARTWORK", "SMALL")
    window.answer:SetPoint("BOTTOMLEFT", window.footer, "TOPLEFT", 0, 4)
    window.answer:SetPoint("BOTTOMRIGHT", window.footer, "TOPRIGHT", 0, 4)
    window.answer:SetJustifyH("LEFT")
    window.answer:SetText("")

    UI.RebuildTabs()

    -- AND SCALE IT, because the window does not exist at login and the login
    -- handler's `ApplyScale` therefore could not reach it. A player who set
    -- the text size got the heads-up line at 1.5 and everything else at 1.0.
    local hud = CN:GetModule("Hud")

    if hud and hud.ApplyScale then
        hud.ApplyScale()
    end

    return window
end

UI.BuildWindow = BuildWindow

function UI.SavePosition()
    if not window or not CN.db then
        return
    end

    local point, _, relativePoint, x, y = window:GetPoint()

    CN.Settings().window = {
        point         = point,
        relativePoint = relativePoint,
        x             = x,
        y             = y,
    }
end

function UI.RestorePosition()
    local saved = CN.Settings() and CN.Settings().window

    if not window or not saved or not saved.point then
        return
    end

    window:ClearAllPoints()
    window:SetPoint(saved.point, UIParent, saved.relativePoint, saved.x, saved.y)
end

------------------------------------------------------------
-- TABS
------------------------------------------------------------

function UI.RebuildTabs()
    if not window then
        return
    end

    for _, button in ipairs(window.tabButtons) do
        button:Hide()
    end

    local previous
    local row, rowWidth = 0, 0

    for index, tab in ipairs(UI.tabs) do
        local button = window.tabButtons[index]

        if not button then
            button = SafeCreateFrame("Button", nil, window, "UIPanelButtonTemplate")
            button:SetHeight(22)
            window.tabButtons[index] = button
        end

        button:SetText(CN.L[tab.name])

        -- THE TAB CAPTIONS TOO. 0.68.0.
        --
        -- 0.67.0 adopted the labels of buttons and checkboxes built by
        -- `AddButton` / `AddCheckbox` and left these -- the eleven captions
        -- the change's own comment names as one of the three things that
        -- stayed at 100% while the rows around them grew.
        --
        -- Adopted BEFORE the width is measured below, so the button is sized
        -- to the text the player will actually see.
        if button.GetFontString then
            CN.AdoptLabel(button:GetFontString(), "CAPTION")
        end

        -- GetTextWidth exists on Button, but guard anyway: a nil or
        -- non-numeric return here would break the whole window.
        local textWidth = button.GetTextWidth and button:GetTextWidth()

        if type(textWidth) ~= "number" then
            textWidth = 60
        end

        local buttonWidth = math.max(64, textWidth + 18)

        button:SetWidth(buttonWidth)
        button:ClearAllPoints()

        -- Wrap to a new row rather than running off the edge. Tabs are a
        -- registry, so the count grows as modules are added and a fixed
        -- single row would eventually overflow silently.
        if previous and (rowWidth + buttonWidth + 4) > (WINDOW_WIDTH - TAB_MARGIN) then
            row      = row + 1
            rowWidth = 0
            previous = nil
        end

        if previous then
            button:SetPoint("LEFT", previous, "RIGHT", 4, 0)
        else
            button:SetPoint("TOPLEFT", CN.SPACE.M,
                TAB_STRIP_TOP - (row * TAB_ROW_HEIGHT))
        end

        rowWidth = rowWidth + buttonWidth + 4

        button:SetScript("OnClick", function()
            UI.SelectTab(index)
        end)

        button:Show()

        previous = button
    end

    -- Push the body down so a second row of tabs does not overlap it.
    if window.body then
        window.body:ClearAllPoints()
        window.body:SetPoint("TOPLEFT", CN.SPACE.S,
            TAB_STRIP_TOP - TAB_ROW_HEIGHT - (row * TAB_ROW_HEIGHT))
        window.body:SetPoint("BOTTOMRIGHT", -CN.SPACE.S, 34)
    end

    -- REBUILDING THE STRIP MUST NOT MOVE THE PLAYER.
    --
    -- `RebuildTabs` runs whenever a tab registers, which can happen after the
    -- window exists. Re-selecting unconditionally therefore yanks the player
    -- off whatever tab they are reading and -- because `SelectTab` clears the
    -- search box unless `keepFilter` is on -- throws away what they were
    -- typing. Harmless while every shipped tab registers before the window is
    -- built; live the moment anything registers one later.
    --
    -- BY NAME, NOT BY INDEX. `UI.selectedTab` is an index into the sort that
    -- was in force when the player clicked, and the sort has just changed --
    -- so reading a name back out of it names a different tab. `SelectTab`
    -- records the name in memory for exactly this.
    if UI.selectedTabName then
        for index, tab in ipairs(UI.tabs) do
            if tab.name == UI.selectedTabName then
                UI.selectedTab = index

                UI.HighlightTab(index)

                return
            end
        end
    end

    UI.SelectTab(UI.RememberedTabIndex() or 1)
end

-- THE INDEX IS NOT A NAME, AND IT WAS BEING SAVED AS IF IT WERE ONE.
--
-- `UI.tabs` is sorted by `order` then by name, and it is rebuilt whenever a
-- tab registers -- which happens at load, and can happen later. So index 7 is
-- "Collections" only until the tab list changes: add a tab, change an order,
-- or ship a release that does either, and the window reopens on whatever tab
-- now happens to sit at 7. There is no error and nothing to notice; the
-- window simply opens on the wrong tab from then on.
--
-- The name is stable and is what the player actually meant. It is written
-- alongside the index and preferred on read, so a database saved by an older
-- version still opens somewhere sensible.
function UI.RememberedTabIndex()
    local settings = CN.Settings()

    if not settings then
        return nil
    end

    local name = settings.selectedTabName

    if type(name) == "string" then
        for index, tab in ipairs(UI.tabs) do
            if tab.name == name then
                return index
            end
        end

        -- A remembered tab that no longer exists is not an error worth a
        -- message; it is a tab that was removed. Fall through to the index.
    end

    local index = settings.selectedTab

    if type(index) == "number" and UI.tabs[index] then
        return index
    end

    return nil
end

-- Which button carries the "you are here" rule. Split out of `SelectTab` so
-- `RebuildTabs` can move the mark to follow a re-sort without re-selecting the
-- panel, which would throw away the player's place and their search box.
function UI.HighlightTab(index)
    if not window or not window.tabButtons then
        return false
    end

    for buttonIndex, button in ipairs(window.tabButtons) do
        if not button.selectMark then
            button.selectMark = button:CreateTexture(nil, "OVERLAY")
            button.selectMark:SetHeight(2)
            button.selectMark:SetPoint("BOTTOMLEFT", 2, 1)
            button.selectMark:SetPoint("BOTTOMRIGHT", -2, 1)
            button.selectMark:SetColorTexture(CN.Rgb("BRAND"))
        end

        button.selectMark:SetShown(buttonIndex == index)

        button:SetEnabled(true)
    end

    return true
end

function UI.SelectTab(index)
    local tab = UI.tabs[index]

    if not tab or not window then
        return
    end

    -- THE OUTGOING TAB'S LIST HAS TO BE CLEARED WHILE IT IS STILL SELECTED.
    --
    -- `UI.SetFilter` resolves its target through `UI.tabs[UI.selectedTab]`,
    -- and `UI.selectedTab` is advanced two lines below -- so from the moment
    -- it moves, NOTHING in the addon can reach the list you just left, and
    -- emptying the box afterwards cleared the widget and not the list behind
    -- it. Leave a filtered tab for one without a list and the box came back
    -- empty and enabled over a list that was still filtered.
    local leaving = UI.tabs[UI.selectedTab or 0]

    local leavingList = leaving and leaving.panel
        and UI.listPanels and UI.listPanels[leaving.panel]

    if leavingList and not (CN.Settings() and CN.Settings().keepFilter) then
        leavingList:SetFilter("")
    end

    UI.selectedTab     = index
    UI.selectedTabName = tab.name

    -- Persisted, so the window reopens where it was left. It always opened on
    -- the first tab, which for a player who lives in Collections meant one
    -- extra click every single time.
    if CN.Settings() then
        CN.Settings().selectedTab     = index
        CN.Settings().selectedTabName = tab.name
    end

    -- An answer belongs to the tab whose button produced it. Carrying "Read
    -- 6 collections." onto the Goals tab is a sentence about nothing on
    -- screen.
    if window.answer then
        window.answer:SetText("")
    end

    -- And so does the cross-tab hint: it names OTHER tabs, and which tabs
    -- those are depends on which one you are standing on.
    UI.ShowElsewhere(nil)

    if window.footer then
        local deeper = UI.tabFooters[tab.name]

        window.footer:SetText(deeper
            or "/cn help for the full command list")
    end

    -- The filter belongs to the tab being left. Clear the box unless the
    -- player has asked for it to follow them, in which case it is put back
    -- AFTER the new panel exists -- see the end of this function.
    --
    -- Setting the text here was the whole of it until 0.47.0, and it did not
    -- work: the box's OnTextChanged calls UI.SetFilter, which reads
    -- `tab.panel`, and on a tab's first visit the panel is not built until
    -- forty lines below. So the term appeared in the box and the list ignored
    -- it -- the exact state `keepFilter` warns about in its own help text,
    -- produced by the feature meant to prevent it.
    --
    -- UI.RestoreFilter was written to do this properly and was never called
    -- from anywhere.
    if window.search and not (CN.Settings() and CN.Settings().keepFilter) then
        window.search:SetText("")
    end

    -- THE SELECTED TAB WAS DRAWN AS A DISABLED BUTTON.
    --
    -- `SetEnabled(false)` on `UIPanelButtonTemplate` greys the text and dims
    -- the art, and in every other piece of interface anywhere, greyed means
    -- unavailable. So the tab the player was looking at was the one that
    -- looked broken and the ten they could go to looked live -- the single
    -- most damaging affordance error in the window, and it shipped for
    -- eleven releases.
    --
    -- Selection is marked instead: a two-pixel rule in the brand blue along
    -- the bottom edge, which is how a tab has said "you are here" since long
    -- before this addon. The button stays enabled, so it still highlights on
    -- hover and clicking it is a harmless refresh.
    UI.HighlightTab(index)

    for _, other in ipairs(UI.tabs) do
        if other.panel then
            other.panel:Hide()
        end
    end

    UI.BuildPanel(tab)

    tab.panel:Show()

    -- Now that the panel exists, the filter has something to apply to.
    UI.RestoreFilter()

    -- AND IF IT HAS NOTHING TO APPLY TO, SAY SO.
    --
    -- The Settings and Scans tabs draw controls, not a list, so `UI.SetFilter`
    -- found no `panel.list` and returned. The box stayed white, focusable and
    -- typeable, and every keystroke did nothing -- which reads as the addon
    -- being broken, not as the control being inapplicable. A control that
    -- cannot act must not look like it can.
    UI.UpdateFilterAvailability(tab)

    UI.Refresh()
end

-- Split out so the tab switch above and the tests can both reach it.
function UI.UpdateFilterAvailability(tab)
    if not window or not window.search then
        return false
    end

    local panel = tab and tab.panel

    -- The registry, not `panel.list` -- see UI/List.lua for why a field read
    -- off a frame cannot answer this honestly.
    local usable = (panel and UI.listPanels and UI.listPanels[panel]) and true
        or false

    -- `Enable`/`Disable`, not `SetEnabled`: SetEnabled is a Button method and
    -- this is an EditBox. It exists on enough widget types to look safe and
    -- would have been a nil call on the one type this actually runs against.
    if usable then
        window.search:Enable()
    else
        window.search:Disable()
    end

    window.search:EnableMouse(usable)

    if not usable then
        -- CLEARED WITHOUT DESTROYING WHAT IS REMEMBERED.
        --
        -- `ClearFocus` on a focused EditBox fires `OnEditFocusLost`, which
        -- with `keepFilter` on writes whatever the box now holds -- nothing
        -- -- over `UI.persistedFilter`. So typing a filter and then clicking
        -- the one tab with no list threw the persisted term away, which is
        -- the opposite of what that setting is for.
        local held = UI.persistedFilter

        window.search:SetText("")
        window.search:ClearFocus()

        UI.persistedFilter = held
    end

    -- Greyed AND relabelled: colour alone is not an explanation, and "filter"
    -- beside a dead box is worse than no label.
    if window.searchLabel then
        window.searchLabel:SetText(usable and "filter" or "no list here")
    end

    if window.search.SetTextColor then
        window.search:SetTextColor(CN.Rgb(usable and "PRIMARY" or "DISABLED"))
    end

    return usable
end

------------------------------------------------------------
-- REFRESH
------------------------------------------------------------

-- Applies the filter box to whichever list the current tab is showing.
-- Re-applied when a tab changes, but only if the player asked for that.
function UI.RestoreFilter()
    local settings = CN.Settings()

    if not settings or not settings.keepFilter or not UI.persistedFilter then
        return false
    end

    if window and window.search then
        window.search:SetText(UI.persistedFilter)
    end

    UI.SetFilter(UI.persistedFilter)

    return true
end

------------------------------------------------------------
-- FINDING SOMETHING WITHOUT KNOWING WHICH TAB IT IS ON
------------------------------------------------------------

-- ELEVEN TABS, AND THE FILTER BOX ONLY EVER SEARCHED ONE. 0.66.0.
--
-- The window knows about quests, mounts, toys, appearances, currencies,
-- titles, factions, rares, vendors, instances and characters -- and to find
-- any of them the player had to already know which tab it lived on. Typing a
-- name on the wrong tab produced "Nothing matched", which is true and
-- useless: the addon had the answer and was declining to say where.
--
-- Every tab that owns a list is asked, from the entries it was last given
-- rather than from what survived its own filter.
function UI.SearchAll(text)
    local results = {}

    if type(text) ~= "string" then
        return results
    end

    text = CN.Trim(text)

    if text == "" then
        return results
    end

    local needle = string.lower(text)

    for index, tab in ipairs(UI.tabs) do
        local list = tab.panel and UI.listPanels and UI.listPanels[tab.panel]

        if list and list.Entries then
            local count, first = 0, nil

            for _, entry in ipairs(list:Entries()) do
                -- Plain find, for the reason the list's own filter gives:
                -- somebody typing "mount (2)" is typing a name, not a
                -- pattern, and a stray bracket must not throw.
                local haystack = string.lower(tostring(entry.text or "")
                    .. " " .. tostring(entry.value or ""))

                if haystack:find(needle, 1, true) then
                    count = count + 1

                    first = first or CN.Strip(tostring(entry.text or ""))
                end
            end

            if count > 0 then
                table.insert(results, {
                    tab   = tab.name,
                    index = index,
                    count = count,
                    first = first,
                })
            end
        end
    end

    table.sort(results, function(a, b)
        if a.count ~= b.count then
            return a.count > b.count
        end

        return a.index < b.index
    end)

    return results
end

-- ONE PLACE THAT TURNS A TAB INTO A PANEL. 0.67.0.
--
-- This was written out inline in `SelectTab`, which is why the cross-tab
-- search could not do it: a panel is created the first time a tab is
-- SELECTED, so ten of the eleven tabs have no panel at all until the player
-- clicks them, and anything that wants to read all eleven had to either
-- duplicate this block or skip them.
function UI.BuildPanel(tab)
    if not tab or tab.panel or not window or not window.body then
        return tab and tab.panel or nil
    end

    tab.panel = CreateFrame("Frame", nil, window.body)
    tab.panel:SetAllPoints()
    tab.panel:Hide()

    if tab.build then
        local ok, err = pcall(tab.build, tab.panel)

        if not ok then
            Print("Error building the " .. tab.name .. " tab: " .. tostring(err))

            local errors = CN:GetModule("Errors")

            if errors then
                errors.Record("building the " .. tab.name .. " tab", err)
            end
        end
    end

    return tab.panel
end

-- BUILT AS WELL AS REFRESHED. 0.67.0.
--
-- The comment here used to say "the window builds every tab's frame up
-- front". It does not -- a panel is created the first time its tab is
-- selected -- so this skipped every tab the player had not clicked this
-- session, and `/cn find` and the "Also on:" line under the filter box were
-- blind to exactly the tabs a player is least likely to have visited.
--
-- This is the only caller that needs all eleven at once, and it is
-- user-initiated.
-- QUIET, NOT SKIPPED. 0.69.0.
--
-- 0.68.0 stopped `/cn find` refreshing the two tabs whose refresh records
-- something -- and a tab that is not refreshed has an empty list, so the
-- search could no longer match anything on them. `/cn find <the objective
-- ranked fourth>` answered "nothing in the window matches", for the tab whose
-- entire purpose is that objective, while its own help says it searches every
-- tab at once.
--
-- The fix for the side effect already existed and was applied one line too
-- far: `CN.Recommend(limit, quiet)`. The Next tab asks quietly when nobody is
-- looking at the window, which is the same condition, and the rows are built
-- either way.
function UI.RefreshAllTabs()
    -- THE WINDOW FIRST. A function that promises every tab has to make sure
    -- there is something for a tab to be a panel of: `BuildPanel` cannot
    -- build anything before the window body exists, and on a fresh login it
    -- does not. 0.67.0.
    UI.BuildWindow()

    local refreshed = 0

    for _, tab in ipairs(UI.tabs) do
        UI.BuildPanel(tab)

        if tab.refresh and tab.panel then
            if pcall(tab.refresh, tab.panel) then
                refreshed = refreshed + 1
            end
        end
    end

    return refreshed
end

-- The one sentence version, for the line under the filter box.
function UI.SearchElsewhere(text)
    local current = UI.selectedTabName

    local parts = {}

    for _, hit in ipairs(UI.SearchAll(text)) do
        if hit.tab ~= current then
            -- NAMED THE WAY THE TAB STRIP NAMES IT. 0.69.0.
            --
            -- `hit.tab` is the internal English key; the strip itself draws
            -- `CN.L[tab.name]`, and all eleven are translated in every
            -- shipped locale. So a German player read "Also on: Collections
            -- (12)" beside a tab labelled Sammlungen -- a pointer to a tab
            -- that does not exist by that name anywhere on their screen.
            --
            -- The token stays the token; only the printing changes.
            table.insert(parts,
                (CN.L[hit.tab] or hit.tab) .. " (" .. hit.count .. ")")
        end

        if #parts >= 4 then
            break
        end
    end

    if #parts == 0 then
        return nil
    end

    return "Also on: " .. table.concat(parts, ", ")
end

function UI.SetFilter(text)
    local tab = UI.tabs[UI.selectedTab or 1]

    local panel = tab and tab.panel

    local list = panel and UI.listPanels and UI.listPanels[panel]

    if list then
        list:SetFilter(text)
    end
end

function UI.Refresh()
    if not window or not window:IsShown() then
        return
    end

    local tab = UI.tabs[UI.selectedTab or 1]

    if tab and tab.refresh and tab.panel then
        local ok, err = pcall(tab.refresh, tab.panel)

        if not ok then
            Print("Error refreshing the " .. tab.name .. " tab: " .. tostring(err))

            local errors = CN:GetModule("Errors")

            if errors then
                errors.Record("refreshing the " .. tab.name .. " tab", err)
            end
        end
    end
end

-- Called from data events. Cheap when the window is closed.

-- THE LAST EVENT OF A BURST IS THE ONE THAT MATTERS, AND IT WAS THE ONE
-- BEING DROPPED.
--
-- This was a leading-edge throttle with no trailing run: inside two seconds
-- of the last redraw, an event was discarded outright. Handing in a quest
-- fires `QUEST_TURNED_IN`, `QUEST_REMOVED` and `QUEST_LOG_UPDATE` within the
-- same second -- so the window redrew on the first, showing a list the
-- providers had not rebuilt yet, and swallowed the rest. The quest stayed on
-- screen until something unrelated happened more than two seconds later.
--
-- `CN.Debounce` answers the first event immediately and collapses the rest
-- into one trailing run, which is the shape this always wanted. It is the
-- same helper the reputation-tick handlers use, for the same reason.
function UI.RequestRefresh()
    if not window or not window:IsShown() then
        return
    end

    CN.Debounce("UI.refresh", UI.refreshSeconds, function()
        -- Re-checked, because the trailing run happens later and the player
        -- may have closed the window in between.
        if window and window:IsShown() then
            UI.Refresh()
        end
    end)
end

-- Two seconds, matching the busiest provider's own cooldown: the trailing run
-- has to land AFTER the rebuild it is meant to display.
UI.refreshSeconds = 2

------------------------------------------------------------
-- SHOW / HIDE
------------------------------------------------------------

function UI.Toggle()
    BuildWindow()

    if window:IsShown() then
        window:Hide()
        return
    end

    UI.RestorePosition()
    FadeIn(window)
    UI.Refresh()

    -- If the frame refuses to show, say so. Silence here is what makes a
    -- missing window look like a command that did nothing.
    if not window:IsShown() then
        Print("The window could not be shown. Run |cffffc74f/cn uistatus|r.")
    end
end

-- The window frame itself, for the tests and for `/cn uistatus`. It is a
-- local because nothing outside this file should be reaching into it, and
-- readable because a window nothing can read is a window nothing can assert
-- about -- which is how the filter box shipped three defects.
-- The Next tab's three action buttons, enabled together or not at all: each
-- of them acts on `CN.currentRecommendation`, so there is exactly one
-- condition and it is the same for all three.
function UI.SetActionsEnabled(panel, enabled)
    local changed = false

    for _, name in ipairs({ "navigate", "skip", "ignore" }) do
        local button = panel and panel[name]

        if button and button.SetEnabled then
            button:SetEnabled(enabled and true or false)

            changed = true
        end
    end

    return changed
end

function UI.Frame()
    return window
end

function UI.Show()
    BuildWindow()
    UI.RestorePosition()

    -- AN ANSWER BELONGS TO THE CLICK THAT PRODUCED IT.
    --
    -- It was cleared on a tab change and nowhere else, and neither `Show` nor
    -- `Toggle` changes tabs -- so "Read 6 collections." was still sitting
    -- under the tab strip when the window was reopened twenty minutes later,
    -- describing something that had not just happened.
    if window and window.answer then
        window.answer:SetText("")
    end

    FadeIn(window)
    UI.Refresh()
end

function UI.Hide()
    if window then
        window:Hide()
    end
end

-- Backwards compatibility with the earlier single-frame version.
CN.ToggleUI  = UI.Toggle
CN.RefreshUI = UI.Refresh

------------------------------------------------------------
-- TAB: NEXT
------------------------------------------------------------

UI.RegisterTab{
    name  = "Next",
    order = 10,

    build = function(panel)
        panel.title = CN.Label(panel, "ARTWORK", "TITLE")
        panel.title:SetPoint("TOPLEFT", CN.SPACE.M, -CN.SPACE.S)
        panel.title:SetPoint("TOPRIGHT", -CN.SPACE.M, -CN.SPACE.S)
        panel.title:SetJustifyH("LEFT")

        panel.type = CN.Label(panel, "ARTWORK", "LABEL")
        panel.type:SetPoint("TOPLEFT", panel.title, "BOTTOMLEFT", 0, -2)

        panel.why = CN.Label(panel, "ARTWORK", "BODY")
        panel.why:SetPoint("TOPLEFT", panel.type, "BOTTOMLEFT", 0, -12)
        panel.why:SetPoint("RIGHT", -CN.SPACE.M, 0)
        panel.why:SetJustifyH("LEFT")
        panel.why:SetJustifyV("TOP")

        panel.navigate = AddButton(panel, "Navigate", 110, function()
            local objective = CN.currentRecommendation

            if not objective then
                return
            end

            CN.NavigateToObjective(objective)
        end,
            "Puts a waypoint and the on-screen arrow on this objective.")
        panel.navigate:SetPoint("BOTTOMLEFT", CN.SPACE.M, CN.SPACE.M)

        panel.skip = AddButton(panel, "Defer 1 hour", 110, function()
            local objective = CN.currentRecommendation

            if not objective then
                return
            end

            CN.SetDeferred(objective.type, objective.id, 3600)
            -- SAY HOW LONG, AND SAY THE WAY BACK. The button says "1 hour"
            -- and the message did not; nothing named the undo.
            UI.Answer("Deferred for an hour: " .. tostring(objective.name)
                .. CN.Aside(CN.Accent("/cn unhide " .. tostring(objective.id))
                    .. " brings it back now"))
            UI.Refresh()
        end,
            "Hides this one for an hour, then it comes back on its own. /cn hidden lists what is deferred.")
        panel.skip:SetPoint("LEFT", panel.navigate, "RIGHT", CN.SPACE.S, 0)

        panel.ignore = AddButton(panel, "Ignore", 110, function()
            local objective = CN.currentRecommendation

            if not objective then
                return
            end

            CN.SetIgnored(objective.type, objective.id, true)
            -- Ignore is permanent and one click, so the message it prints is
            -- the only place the way back can appear.
            UI.Answer("Ignored: " .. tostring(objective.name)
                .. CN.Aside(CN.Accent("/cn unhide " .. tostring(objective.id))
                    .. " restores it"))
            UI.Refresh()
        end,
            "Hides this one permanently. /cn unhide <id> restores it.")
        panel.ignore:SetPoint("LEFT", panel.skip, "RIGHT", CN.SPACE.S, 0)

        -- SET, NOT LEFT UNSET.
        --
        -- `refresh` reads `panel.filtering` before anything writes it. On a
        -- real frame an unset field is nil and the branch is skipped; a frame
        -- is also exactly the kind of object whose `__index` can answer every
        -- key, and this addon has already shipped two defects of that shape
        -- (`lastEntries` and `filterText`, both moved off frames in 0.47.0).
        -- The Next tab is the first thing a new player sees; it should not
        -- depend on a field being absent.
        --
        -- `panel.selected` beside it, for the same reason and a worse
        -- consequence: `panel.selected = nil` REMOVES the key, so `__index`
        -- answers again and `best = panel.selected or best` handed the rest of
        -- the function something that is not an objective. Assigning `false`
        -- stores a key, which nothing can answer over.
        panel.selected  = false
        panel.filtering = false

        -- Type filter. A dropdown would need a menu library; a button that
        -- opens a scrollable checklist in the same list widget the rest of the
        -- window uses costs nothing extra and behaves identically everywhere.
        panel.filter = AddButton(panel, "Filter types", 110, function()
            panel.filtering = (not panel.filtering) and true or false
            UI.Refresh()
        end,
            "Choose which kinds of objective the addon recommends at all.")
        panel.filter:SetPoint("LEFT", panel.ignore, "RIGHT", CN.SPACE.S, 0)

        panel.list = UI.CreateList(panel)
        panel.list.emptyText = "Nothing actionable is known yet. /cn setup reads everything the client will answer for."
        panel.list:ClearAllPoints()
        panel.list:SetPoint("TOPLEFT", panel.why, "BOTTOMLEFT", -4, -14)
        panel.list:SetPoint("BOTTOMRIGHT", -CN.SPACE.S, 38)
    end,

    refresh = function(panel)
        local filters = CN:GetModule("Filters")

        -- Filter mode takes over the list. The recommendation itself stays
        -- visible above it, so you can see what changed as you toggle.
        if panel.filtering and filters then
            local hidden = filters.HiddenTypeCount()

            panel.filter:SetText("Done")

            -- THE THREE ACTION BUTTONS DO NOT APPLY IN THIS MODE.
            --
            -- They stayed enabled and stayed labelled Navigate / Defer 1 hour
            -- / Ignore while the panel had become a type checklist -- and
            -- they still acted on whatever `CN.currentRecommendation` last
            -- held, which is now off screen. Pressing Ignore here hid
            -- something the player could not see, permanently.
            UI.SetActionsEnabled(panel, false)

            panel.title:SetText("Show which types?")
            panel.type:SetText(hidden == 0 and "showing everything"
                or (hidden .. " type" .. CN.Pluralize(hidden, "") .. " hidden"))
            panel.why:SetText("Hidden types still appear in Remaining and "
                .. "Collections.\nThis only filters recommendations.")

            local entries = {}

            table.insert(entries, {
                text = "|cffffc74fShow everything|r",
                onClick = function()
                    filters.EnableAllTypes()
                    UI.Refresh()
                end,
            })

            for _, objectiveType in ipairs(filters.TypeOrder()) do
                local enabled = filters.IsTypeEnabled(objectiveType)

                table.insert(entries, {
                    text = (enabled and "|cff73b873[x]|r " or "|cff5a5f66[ ]|r ")
                        .. (enabled and "" or "|cff8a8f96")
                        .. filters.TypeLabel(objectiveType)
                        .. (enabled and "" or "|r"),

                    -- WITH THE CONSEQUENCE ATTACHED. 0.67.0.
                    --
                    -- "Shown in recommendations" restates the checkbox the
                    -- player is looking at. What they cannot see is how much
                    -- of the list this switch is holding -- which is the only
                    -- thing that makes the decision to flip it a decision.
                    tooltip = function()
                        local lines = { filters.TypeLabel(objectiveType) }

                        local holding = 0

                        -- QUIET, AND OVER THE ROWS THE TAB ACTUALLY DRAWS.
                        -- 0.68.0.
                        --
                        -- This asked for sixty rows on every hover, which
                        -- fired the recommendation hooks -- so mousing down
                        -- the checkbox list recorded ranks 13 to 60 as having
                        -- been shown to the player and started session clocks
                        -- on some of them. It also counted over sixty while
                        -- the list behind the tooltip draws twelve, so the
                        -- sentence promised rows that were not there.
                        -- FROM THE SECOND ROW. 0.69.0.
                        --
                        -- Rank one is the headline ABOVE the list, so the
                        -- list draws eleven of the twelve -- and a type whose
                        -- only representative was the headline claimed "1 row
                        -- in the list" over a list containing none of it.
                        local ranked = CN.Recommend(UI.listLimit, true) or {}

                        for index = 2, #ranked do
                            if ranked[index].type == objectiveType then
                                holding = holding + 1
                            end
                        end

                        if enabled then
                            table.insert(lines, "Shown. "
                                .. CN.Count(holding, "row")
                                .. " in the list right now; hiding it drops "
                                .. "them from the route as well, so you are "
                                .. "not walked past something you said you "
                                .. "did not want.")
                        else
                            table.insert(lines, "Hidden from recommendations "
                                .. "and from the route. Collection totals "
                                .. "still count it.")
                        end

                        return table.concat(lines, "\n")
                    end,

                    onClick = function()
                        filters.ToggleType(objectiveType)
                        UI.Refresh()
                    end,
                })
            end

            panel.list:SetEntries(entries)

            return
        end

        panel.filter:SetText("Filter types")


        -- ASKED QUIETLY WHEN NOBODY IS LOOKING. 0.69.0.
        --
        -- A refresh with the window hidden happens for one reason -- `/cn
        -- find` builds every tab so it has something to search -- and a row
        -- nobody can see was not offered to anybody. See `CN.Recommend`.
        local results = CN.Recommend(UI.listLimit,
            not (window and window:IsShown()))

        -- A CONTROL THAT CANNOT ACT MUST NOT LOOK LIKE IT CAN.
        --
        -- On a fresh install this tab is the first thing a player sees: it
        -- says "Nothing actionable yet" above three live-looking buttons that
        -- silently returned when pressed.
        UI.SetActionsEnabled(panel, #results > 0)

        if #results == 0 then
            panel.title:SetText("Nothing actionable yet")
            panel.type:SetText("")

            -- An empty list because you filtered everything out looks exactly
            -- like an empty list because nothing was found -- and both look
            -- exactly like an engine that threw. The shared explainer says
            -- which, and it says the same thing here as in chat.
            panel.why:SetText(
                table.concat(CN.ExplainEmptyList(), "\n\n"))

            panel.list:SetEntries({})

            CN.currentRecommendation = nil

            return
        end

        local best = results[1]

        -- The headline is the addon's answer unless the player has picked a
        -- different row, in which case it is theirs. A selection that no
        -- longer exists is dropped rather than left aiming at nothing.
        local held = panel.selected

        panel.selected = false

        for _, objective in ipairs(results) do
            if objective == held then
                panel.selected = held
            end
        end

        best = panel.selected or best

        CN.currentRecommendation = best

        panel.title:SetText(tostring(best.name or best.id))
        panel.type:SetText(CN.TypeBadge(best.type))
        panel.why:SetText("Why:\n"
            .. table.concat(CN.ExplainRecommendation(best), "\n"))

        local entries = {}

        for index = 2, #results do
            local objective = results[index]

            table.insert(entries, {
                text = string.format("|cff8a8f96%2d.|r %s |cff8a8f96[%s]|r",
                    index, tostring(objective.name or objective.id),
                    CN.TypeBadge(objective.type)),

                -- SHOW WHICH ROW THE BUTTONS ARE AIMED AT.
                --
                -- Clicking a row re-aimed Navigate, Defer and Ignore at it
                -- and changed nothing on screen -- so the list still numbered
                -- it "7." under a headline that now said something else, and
                -- nothing anywhere said which one was armed. The Goals tab
                -- has done this correctly since 0.50.0, and the list widget
                -- already draws a brand-tinted selection for it.
                selected = (panel.selected == objective),

                -- BUILT ON HOVER, NOT ON EVERY REFRESH.
                --
                -- Composing an explanation now sorts three keyed tables, and
                -- this ran for every row of every refresh whether the mouse
                -- went near it or not.
                tooltip = function()
                    return table.concat(CN.ExplainRecommendation(objective),
                        "\n")
                end,

                onClick = function()
                    panel.selected = objective

                    CN.currentRecommendation = objective

                    UI.Refresh()
                end,
            })
        end

        panel.list:SetEntries(entries)
    end,
}

------------------------------------------------------------
-- TAB: ZONE
------------------------------------------------------------

UI.RegisterTab{
    name  = "Zone",
    order = 20,

    build = function(panel)
        panel.header = CN.Label(panel, "ARTWORK", "HEAD")
        panel.header:SetPoint("TOPLEFT", CN.SPACE.M, -CN.SPACE.S)
        panel.header:SetPoint("TOPRIGHT", -CN.SPACE.M, -CN.SPACE.S)
        panel.header:SetJustifyH("LEFT")

        panel.list = UI.CreateList(panel)
        panel.list.emptyText = "Nothing left here that the addon knows about. Press Re-route, or try another zone."
        panel.list:ClearAllPoints()
        panel.list:SetPoint("TOPLEFT", CN.SPACE.S, -32)
        panel.list:SetPoint("BOTTOMRIGHT", -CN.SPACE.S, 38)

        panel.route = AddButton(panel, "Re-route", 110, function()
            UI.Refresh()
        end,
            "Recomputes the sweep of this zone from where you are standing now.")
        panel.route:SetPoint("BOTTOMLEFT", CN.SPACE.M, CN.SPACE.M)

        panel.clear = AddButton(panel, "Clear waypoints", 130, function()
            -- SAY WHETHER IT WORKED, AND CLEAR WHAT THE TOOLTIP CLAIMS.
            --
            -- The return value was discarded. `Routing.lua` documents that
            -- the boolean exists "so `/cn clearway` can stop announcing a
            -- clearance that did not happen", and it comes back false in
            -- several ordinary cases: nothing was active, the pin belongs to
            -- another addon, the player moved it. `/cn clearway` handles all
            -- of that; this button handled none of it and said nothing either
            -- way. And the tooltip promised map pins, which `MapPins.Clear`
            -- exists to remove and nothing here called.
            local cleared = CN.ClearWaypoints()

            local pins = CN:GetModule("MapPins")

            if pins and pins.Clear then
                pins.Clear()
            end

            UI.Answer(cleared
                and "Waypoints and map pins cleared."
                or "This addon had no waypoint set. A pin you placed yourself "
                    .. "is left alone.")

            UI.Refresh()
        end,
            "Removes the waypoints and map pins this addon set. Other addons' waypoints are left alone.")
        panel.clear:SetPoint("LEFT", panel.route, "RIGHT", CN.SPACE.S, 0)
    end,

    refresh = function(panel)
        local mapID, x, y = CN.GetPlayerPosition()

        if not mapID then
            panel.header:SetText("Current map unknown.")

            -- A DIFFERENT SITUATION NEEDS A DIFFERENT SENTENCE.
            --
            -- The list fell through to "Nothing left here that the addon
            -- knows about. Press Re-route" while the header two lines above
            -- said the map was unknown -- so the tab offered a button that
            -- cannot work as the answer to a problem it had already named.
            -- The client refuses to place the player for a moment after every
            -- loading screen, which is exactly when somebody opens this tab.
            local held = panel.list.emptyText

            panel.list.emptyText = "The client has not said where you are "
                .. "yet. This clears itself a moment after a loading screen."

            panel.list:SetEntries({})

            panel.list.emptyText = held

            return
        end

        local zoneName = CN.Blizzard.GetMapName(mapID) or "This zone"

        local route, skipped = CN.BuildZoneRoute(mapID, x, y)

        local counts, order = CN.SummarizeZone(route, skipped)

        local parts = {}

        for _, key in ipairs(order) do
            -- THE LABEL, NOT THE ENUM. This lowercased the internal type
            -- name, so the Zone tab's header read "3 collectible, 2
            -- exploration, 7 quest" -- the addon's own vocabulary, and the
            -- wrong plural. `CN.TypeLabel` has returned "Collectibles" since
            -- 0.49.0.
            table.insert(parts, counts[key] .. " "
                .. string.lower(CN.TypeLabel(key)))
        end

        if #parts == 0 then
            panel.header:SetText(zoneName .. " " .. CN.DASH
                .. " nothing actionable is known here.")
        else
            panel.header:SetText(zoneName .. " " .. CN.DASH .. " remaining: "
                .. table.concat(parts, ", "))
        end

        local entries = {}

        for index, objective in ipairs(route) do
            table.insert(entries, {
                text = string.format("|cff8a8f96%2d.|r %s |cff8a8f96[%s]|r",
                    index, tostring(objective.name or objective.id),
                    CN.TypeBadge(objective.type)),

                -- BUILT ON HOVER, LIKE THE NEXT TAB'S. 0.61.0.
                --
                -- `ExplainRecommendation` sorts three keyed tables per call,
                -- and the Zone tab composed one for every stop on the route
                -- -- 160 on a busy map -- on every one of its two-second
                -- refreshes, whether the mouse went near a row or not. The
                -- Next tab was given a function for exactly this reason in
                -- 0.57.0 and this one was missed. Measured: 4.02 ms of a
                -- 5.31 ms Zone tab refresh.
                --
                -- `AttachTooltip` already accepts a function.
                tooltip = function()
                    return "Click to set a waypoint.\n"
                        .. table.concat(
                            CN.ExplainRecommendation(objective), "\n")
                end,

                onClick = function()
                    CN.currentRecommendation = objective
                    CN.NavigateToObjective(objective)
                end,
            })
        end

        for _, objective in ipairs(skipped) do
            table.insert(entries, {
                text = "|cff8a8f96     " .. tostring(objective.name or objective.id)
                    .. " (no coordinates)|r",
            })
        end

        panel.list:SetEntries(entries)
    end,
}

------------------------------------------------------------
-- TAB: SCANS
------------------------------------------------------------

-- REBUILT AS PROVENANCE, BECAUSE IT WAS THE WEAKEST TAB IN THE WINDOW.
--
-- It was one FontString holding twenty-odd lines of concatenated text, two
-- buttons, and no list -- so it could not be filtered, could not be sorted,
-- could not be clicked, and its own filter box sat above it doing nothing.
-- Every other tab in the window is a list of rows you can act on; this one
-- was a paragraph.
--
-- What it is FOR is the question no other tab answers: where does each number
-- in this addon come from, and how old is it. So that is what it shows now --
-- one row per source, with its count, its age, and the scan that refreshes
-- it on click. The two buttons it had are two of those rows.
UI.RegisterTab{
    name  = "Scans",
    order = 30,

    build = function(panel)
        panel.header = CN.Label(panel, "ARTWORK", "HEAD")
        panel.header:SetPoint("TOPLEFT", CN.SPACE.M, -CN.SPACE.S)
        panel.header:SetPoint("TOPRIGHT", -CN.SPACE.M, -CN.SPACE.S)
        panel.header:SetJustifyH("LEFT")

        panel.list = UI.CreateList(panel)
        panel.list.emptyText = "No sources are readable on this client."
        panel.list:ClearAllPoints()
        panel.list:SetPoint("TOPLEFT", CN.SPACE.S, -32)
        panel.list:SetPoint("BOTTOMRIGHT", -CN.SPACE.S, 38)

        -- ONE BUTTON, AND IT NAMES WHAT IT WILL DO.
        --
        -- "Scan quests" and "Scan reputations" were two of eleven sources
        -- picked by nothing in particular. Every source is a clickable row
        -- now, so the only button worth keeping is the one that does the
        -- thing a player would otherwise do eleven times.
        panel.stale = AddButton(panel, "Refresh what is stale", 190, function()
            local refreshed = UI.RefreshStaleSources()

            if refreshed == 0 then
                UI.Answer("Nothing is stale. Every source has been read today.")
            else
                UI.Answer("Read " .. refreshed .. " stale "
                    .. CN.Pluralize(refreshed, "source", "sources") .. ".")
            end

            UI.Refresh()
        end, "Re-reads every source that has not been read in a day, or has "
            .. "never been read. Freezes the client while it runs.")

        panel.stale:SetPoint("BOTTOMLEFT", CN.SPACE.M, CN.SPACE.M)

        panel.note = CN.Label(panel, "ARTWORK", "SMALL")
        panel.note:SetPoint("BOTTOMLEFT", CN.SPACE.M, CN.SPACE.M + 26)
        panel.note:SetPoint("RIGHT", -CN.SPACE.M, 0)
        panel.note:SetJustifyH("LEFT")
    end,

    refresh = function(panel)
        local entries = {}

        -- TEN STORE WALKS, EVERY TWO SECONDS. 0.65.0.
        --
        -- This is the identical defect 0.61.0 fixed on the Collections tab --
        -- eight `Summary()` calls, each walking its module's whole store, on
        -- every two-second refresh -- and this sibling tab, which does TEN
        -- plus a map POI scan, was not wrapped. Measured at retail scale it
        -- is the most expensive refresh in the window, and it runs
        -- continuously while questing because `QUEST_LOG_UPDATE` drives it.
        --
        -- Every number in it is already guarded by the same generation.
        -- ONLY THE STORED HALF IS MEMOIZED. 0.66.0.
        --
        -- 0.65.0 wrapped the whole tab in one memo keyed on
        -- `CN.collectionGeneration`, which is bumped by scans and by the
        -- eleven client events that change a COLLECTION. The four rows in the
        -- live section are not collection counts: "Quests in your log",
        -- "Quest givers on this map" -- whose own detail line reads "Changes
        -- as you move" -- and "Quests completed today". Nothing bumps that
        -- generation on `ZONE_CHANGED_NEW_AREA`, `QUEST_ACCEPTED` or
        -- `QUEST_REMOVED`, so those rows froze at whatever they said when the
        -- window was opened and stayed there for the session.
        --
        -- The cost the memo was written for is entirely in the stored half:
        -- ten `Summary()` calls, each walking its module's whole store. The
        -- live half is three client calls.
        -- A NEW ARRAY EVERY REFRESH. THE MEMO HANDS BACK THE CACHE ITSELF.
        --
        -- 0.66.0 split this in two and then appended the live rows onto the
        -- table `CN.Memo` returned -- which is the cached table, not a copy of
        -- it. Standing still, the generation does not move, so the same table
        -- came back every two seconds and grew by five rows each time: after
        -- half a minute the tab listed "Quests in your log" fifteen times, and
        -- `/cn find`, which refreshes every tab, added another copy per use.
        local held = CN.Memo("ui:sources:stored", CN.collectionGeneration,
            function() return UI.Sources("stored") end)

        local sources = {}

        for _, row in ipairs(held) do
            table.insert(sources, row)
        end

        for _, row in ipairs(UI.Sources("live")) do
            table.insert(sources, row)
        end

        local stale = 0

        -- LIVE FIRST, STORED SECOND.
        --
        -- The old tab put "what is true of your world" above "what the
        -- database holds" and said in a comment that the order mattered
        -- because a player reads the top line and stops. That was right, and
        -- it survives the rebuild as two sections.
        local sections = {
            { key = "live",   label = "Read from the client, right now" },
            { key = "stored", label = "Held by the addon, from a scan" },
        }

        for _, section in ipairs(sections) do
            local rows = {}

            for _, source in ipairs(sources) do
                if source.kind == section.key then
                    table.insert(rows, source)
                end
            end

            if #rows > 0 then
                table.insert(entries, {
                    section       = section.key,
                    sectionHeader = true,
                    text          = CN.Accent(section.label),
                })

                for _, source in ipairs(rows) do
                    local age = source.at and CN.Ago(source.at) or nil

                    local isStale = source.command
                        and (not source.at
                            or (time() - source.at) > 86400)

                    if isStale then
                        stale = stale + 1
                    end

                    -- `!` as well as the colour: nothing in this addon is
                    -- carried by hue alone.
                    local mark = isStale and CN.Warn("! ") or "  "

                    table.insert(entries, {
                        section = section.key,

                        text = mark .. source.label
                            .. (source.command
                                and CN.Aside(age or "never read")
                                or CN.Aside("live")),

                        value = CN.Body(source.value or ""),

                        tooltip = source.detail
                            .. (source.command
                                and ("\n\nClick to run /cn " .. source.command
                                    .. ".")
                                or ""),

                        onClick = source.command and function()
                            CN.HandleSlashCommand(source.command)

                            UI.Refresh()
                        end or nil,
                    })
                end
            end
        end

        panel.header:SetText("Where every number in this addon comes from"
            .. (stale > 0
                and CN.Aside(CN.Warn(stale .. " stale"))
                or CN.Aside("all current")))

        panel.list:SetEntries(entries)

        panel.note:SetText(CN.Muted("A source read more than a day ago is "
            .. "marked. Click any row to read it again."))
    end,
}

-- THE SOURCE TABLE, SEPARATE FROM THE TAB THAT DRAWS IT.
--
-- Two callers -- the tab above and the "refresh what is stale" button -- and
-- the tests, which is the third and the reason this is not a local.
-- `which` is "stored", "live", or nil for both. See the note at the caller:
-- the two halves have different lifetimes, so they are cached differently.
function UI.Sources(which)
    local sources = {}

    local steps = {}

    local setup = CN:GetModule("Setup")

    if setup and setup.Steps then
        steps = setup.Steps()
    end

    local function Stored(label, moduleName, command, value, detail)
        if which == "live" then
            return
        end

        table.insert(sources, {
            kind    = "stored",
            label   = label,
            command = command,
            value   = value,
            detail  = detail,
            at      = steps[string.lower(moduleName)],
        })
    end

    local function Live(label, value, detail)
        if which == "stored" then
            return
        end

        table.insert(sources, {
            kind   = "live",
            label  = label,
            value  = value,
            detail = detail,
        })
    end

    ------------------------------------------------------------
    -- LIVE
    ------------------------------------------------------------
    local quests = CN:GetModule("Quests")

    if quests then
        Live("Quests in your log",
            tostring(#CN.Blizzard.GetQuestLogEntries()),
            "Asked of the client every time it is needed. Never stored, "
            .. "because the client always has it.")

        local available = quests.AvailableCount()

        Live("Quest givers on this map", tostring(available),
            "Counted from the map you are standing on. Changes as you move.")
    end

    local progress = CN:GetModule("Progress")

    if progress then
        local summary = progress.Summary()

        if summary.lifetime then
            Live("Quests completed, lifetime", CN.Comma(summary.lifetime),
                "The client's own total. The addon does not maintain it.")
        end

        Live("Quests completed today", tostring(summary.today),
            "Counted by the addon since midnight"
            .. (summary.best > 0
                and (". Your best day was " .. summary.best .. ".")
                or "."))
    end

    Live("Characters seen", tostring(CN.GetCharacterCount()),
        "One row per character that has logged in with the addon loaded.")

    ------------------------------------------------------------
    -- STORED
    ------------------------------------------------------------
    -- `scanquests`, NOT `discoveractive`.
    --
    -- The age on this row is `steps.quests`, and the ONLY writer of that key
    -- in the tree is `Quests.ScanKnown`, which `/cn scanquests` runs.
    -- `/cn discoveractive` reads the log and stamps nothing -- so clicking
    -- this row did real work, printed a real answer, and left the row marked
    -- stale for ever. Worse, "refresh what is stale" then ran it on every
    -- press and could never reach "nothing is stale".
    Stored("Quests known", "quests", "scanquests",
        CN.Comma(CN.CountKeys(CN.Account("discoveredQuests"))) .. " known, "
        .. CN.Comma(CN.CountKeys(CN.Account("questMetadata"))) .. " named",
        "Quests this account has seen offered. Grows as you play; a scan "
        .. "adds the ones on the map you are on now.")

    local reputations = CN:GetModule("Reputations")

    if reputations then
        local counts = reputations.Summary()

        Stored("Reputations", "reputations", "repscan",
            counts.account .. " account, " .. counts.character .. " character",
            counts.renown .. " renown tracks (" .. counts.maxedRenown
            .. " maxed), " .. counts.exalted .. " exalted"
            .. (counts.paragonPending > 0
                and (", " .. CN.Count(counts.paragonPending, "Paragon reward")
                    .. " waiting")
                or ""))
    end

    local collections = {
        { label = "Mounts",       module = "Mounts",       command = "mountscan" },
        { label = "Pets",         module = "Pets",         command = "petscan" },
        { label = "Toys",         module = "Toys",         command = "toyscan" },
        { label = "Titles",       module = "Titles",       command = "titlescan" },
        { label = "Appearances",  module = "Appearances",  command = "appearancescan" },
        { label = "Achievements", module = "Achievements", command = "achievescan" },
        {
            label   = "Currencies",
            module  = "Currencies",
            command = "currencyscan",
            shape   = function(counts)
                return tostring(counts.known or 0) .. " tracked"
                    .. ((counts.capped or 0) > 0
                        and (", " .. counts.capped .. " capped")
                        or "")
            end,
        },
        {
            label   = "Professions",
            module  = "Professions",
            command = "profscan",
            -- An array of per-profession records, not a count table.
            shape   = function(rows)
                local lines, seen = #rows, 0

                for _, record in ipairs(rows) do
                    if record.recipesSeen then
                        seen = seen + 1
                    end
                end

                return CN.Count(lines, "line")
                    .. ", " .. seen .. " with recipes read"
            end,
        },
    }

    for _, entry in ipairs(collections) do
        local module = CN:GetModule(entry.module)

        if module and module.Summary then
            local ok, counts = pcall(module.Summary)

            local value = ""

            if ok and type(counts) == "table" then
                -- NOT EVERY SUMMARY IS "COLLECTED OF KNOWN".
                --
                -- Two of the eight are a different shape, and the generic
                -- read produced an empty right column for both -- on the tab
                -- whose header is "Where every number in this addon comes
                -- from", where a blank reads as zero or as broken.
                -- `Professions.Summary` returns an ARRAY of records, so every
                -- key is nil; `Currencies.Summary` returns known/capped/
                -- weeklyUnfilled and has no "held" at all.
                if entry.shape then
                    value = entry.shape(counts) or ""
                else
                    local held  = counts.collected or counts.completed
                        or counts.onAccount
                    local total = counts.known or counts.total

                    if held and total then
                        value = held .. " / " .. total
                    elseif held then
                        value = tostring(held)
                    end
                end
            end

            Stored(entry.label, entry.module, entry.command, value,
                "Counted against what the addon last read from the client, "
                .. "which is the only denominator it can honestly use.")
        end
    end

    return sources
end

-- Runs every stale source's scan. "Stale" is a day, which is roughly the
-- rate at which any of these can change for a player who is playing.
function UI.RefreshStaleSources()
    local refreshed = 0

    local now = time()

    for _, source in ipairs(UI.Sources()) do
        if source.command
            and (not source.at or (now - source.at) > 86400) then

            if pcall(CN.HandleSlashCommand, source.command) then
                refreshed = refreshed + 1
            end
        end
    end

    return refreshed
end

------------------------------------------------------------
-- TAB: NOW
------------------------------------------------------------

-- Everything with a clock on it, in one place. Nothing added since 0.9 was
-- reachable without typing, which broke the rule this file opens with.
UI.RegisterTab{
    name  = "Now",
    order = 15,

    build = function(panel)
        panel.header = CN.Label(panel, "ARTWORK", "HEAD")
        panel.header:SetPoint("TOPLEFT", CN.SPACE.M, -CN.SPACE.S)
        panel.header:SetPoint("TOPRIGHT", -CN.SPACE.M, -CN.SPACE.S)
        panel.header:SetJustifyH("LEFT")

        panel.list = UI.CreateList(panel)
        panel.list.emptyText = "Nothing is expiring nearby. World quests and rares only appear for the map you are on."
        panel.list:ClearAllPoints()
        panel.list:SetPoint("TOPLEFT", CN.SPACE.S, -32)
        panel.list:SetPoint("BOTTOMRIGHT", -CN.SPACE.S, 38)

        panel.refresh = AddButton(panel, "Refresh", 110, function()
            UI.Refresh()
        end,
            "Reads the timers and lockouts again and redraws this list.")
        panel.refresh:SetPoint("BOTTOMLEFT", CN.SPACE.M, CN.SPACE.M)

        panel.scanCurrency = AddButton(panel, "Rescan currencies", 150, function()
            local module = CN:GetModule("Currencies")

            if module then
                module.Scan()
            end

            UI.Refresh()
        end,
            "Reads your currencies and their caps again.")
        panel.scanCurrency:SetPoint("LEFT", panel.refresh, "RIGHT", CN.SPACE.S, 0)
    end,

    refresh = function(panel)
        local entries = {}

        local opportunities = CN:GetModule("Opportunities")

        -- Hoisted: the weekly-currency rows below sort against the weekly
        -- reset, and they are built outside this block.
        local resets = opportunities and opportunities.GetResets() or {}

        if opportunities then
            local parts = {}

            if resets.daily then
                table.insert(parts, "daily in "
                    .. (opportunities.FormatSpan(resets.daily)
                        or CN.WithConfidence(nil, CN.confidence.UNKNOWN)))
            end

            if resets.weekly then
                table.insert(parts, "weekly in "
                    .. (opportunities.FormatSpan(resets.weekly)
                        or CN.WithConfidence(nil, CN.confidence.UNKNOWN)))
            end

            if #parts > 0 then
                panel.header:SetText("Resets: " .. table.concat(parts, ", "))
            else
                panel.header:SetText("Expiring soon")
            end

            for _, event in ipairs(opportunities.GetActiveEvents()) do
                table.insert(entries, {
                    text  = CN.Accent("EVENT") .. "  " .. tostring(event.title),
                    value = event.endsIn
                        and CN.Muted(opportunities.FormatTimeLeft(event.endsIn))
                        or nil,

                    sortSeconds = event.endsIn or math.huge,
                })
            end

            local worldQuests = opportunities.GetWorldQuests()

            for _, worldQuest in ipairs(worldQuests) do
                table.insert(entries, {
                    text = CN.Brand("WQ") .. "  " .. tostring(worldQuest.name)
                        .. (worldQuest.tagName
                            and CN.Muted(" " .. CN.DOT .. " " .. worldQuest.tagName)
                            or ""),

                    value = CN.Muted(
                        opportunities.FormatTimeLeft(worldQuest.secondsLeft)),

                    sortSeconds = worldQuest.secondsLeft or math.huge,

                    -- WHY IT MATTERS, NOT ONLY WHAT CLICKING DOES. 0.67.0.
                    --
                    -- Backlog item 21. Every tooltip in this window said what
                    -- the row was or what the click would do -- both of which
                    -- the player can see -- and none of them said why the row
                    -- is worth reading. The addon knows: it has the clock, the
                    -- journey and the reward.
                    tooltip = function()
                        local lines = { tostring(worldQuest.name) }

                        -- THE RAW SECONDS, FORMATTED FOR A SENTENCE. 0.68.0.
                        --
                        -- `FormatTimeLeft` is written for the value column
                        -- and returns "42m left", "expired", or a colour-coded
                        -- "unknown time left" -- so this read "Gone in 42m
                        -- left whether you do it or not", and opened a colour
                        -- escape in the middle of a sentence when the client
                        -- would not answer.
                        local session = CN:GetModule("Session")

                        if worldQuest.secondsLeft and worldQuest.secondsLeft > 0
                            and session and session.FormatDuration then

                            table.insert(lines, "Gone in "
                                .. session.FormatDuration(worldQuest.secondsLeft)
                                .. " whether you do it or not.")
                        end

                        if worldQuest.tagName and worldQuest.tagName ~= "" then
                            table.insert(lines, tostring(worldQuest.tagName)
                                .. (worldQuest.isElite and " (elite)" or "")
                                .. ".")
                        elseif worldQuest.isElite then
                            table.insert(lines, "Elite.")
                        end

                        local far = UI.DistanceLine(worldQuest.mapID,
                            worldQuest.x, worldQuest.y)

                        if far then
                            table.insert(lines, far)
                        end

                        table.insert(lines, "Click to set a waypoint.")

                        return table.concat(lines, "\n")
                    end,

                    onClick = function()
                        CN.NavigateToObjective({
                            id    = worldQuest.questID,
                            type  = CN.objectiveTypes.QUEST,
                            name  = worldQuest.name,
                            mapID = worldQuest.mapID,
                            x     = worldQuest.x,
                            y     = worldQuest.y,
                        })
                    end,
                })
            end
        else
            panel.header:SetText("Expiring soon")
        end

        local rares = CN:GetModule("Rares")

        if rares then
            for _, vignette in ipairs(rares.GetActive()) do
                table.insert(entries, {
                    text = CN.Accent(vignette.kind == "TREASURE"
                        and "CHEST" or "RARE") .. "  " .. tostring(vignette.name),

                    value = CN.Good("up now"),

                    -- Up right now, so it sorts above anything on a clock.
                    sortSeconds = 0,

                    tooltip = function()
                        local lines = { tostring(vignette.name) }

                        table.insert(lines, "Up right now. Vignettes only "
                            .. "appear for things in range, so this is a "
                            .. "chance rather than a plan.")

                        local record = CN.Account("rares")[vignette.vignetteID]

                        -- THREE STATES, NOT TWO. 0.68.0.
                        --
                        -- Migration 19 dropped every stored sighting count on
                        -- the stated grounds that a missing number is better
                        -- than a confidently wrong one -- and this turned the
                        -- missing one straight back into a confident claim.
                        -- A player who had farmed a rare weekly for a year
                        -- was told "first time you have met it".
                        if record and (record.sightings or 0) > 1 then
                            table.insert(lines, "You have met it "
                                .. CN.Count(record.sightings, "time") .. ".")
                        elseif record and record.sightings == 1
                            and record.firstSeen
                            and (time() - record.firstSeen)
                                < (rares.sightingGap or 600) then

                            -- AND THE RECORD HAS TO BE NEW, NOT JUST THE
                            -- COUNTER. 0.69.0.
                            --
                            -- Migration 19 cleared every stored count, so the
                            -- NEXT encounter with a rare farmed for a year
                            -- writes 1 and this said "first time" again --
                            -- the same confident wrong claim, one sighting
                            -- later, with a `firstSeen` from months ago
                            -- sitting on the same table.
                            table.insert(lines, "First time you have met it.")
                        end

                        if rares.IsClearedByCharacter(vignette.vignetteID) then
                            table.insert(lines, "This character has already "
                                .. "cleared it since the last weekly reset.")
                        end

                        local far = UI.DistanceLine(vignette.mapID,
                            vignette.x, vignette.y)

                        if far then
                            table.insert(lines, far)
                        end

                        table.insert(lines, "Click to set a waypoint.")

                        return table.concat(lines, "\n")
                    end,

                    onClick = function()
                        CN.NavigateToObjective({
                            id    = vignette.vignetteID,
                            type  = vignette.kind == "TREASURE"
                                and CN.objectiveTypes.TREASURE
                                or CN.objectiveTypes.RARE,
                            name  = vignette.name,
                            mapID = vignette.mapID,
                            x     = vignette.x,
                            y     = vignette.y,
                        })
                    end,
                })
            end
        end

        local currencies = CN:GetModule("Currencies")

        if currencies then
            for _, currency in ipairs(currencies.Capped()) do
                table.insert(entries, {
                    text  = CN.Bad("CAP") .. "  " .. tostring(currency.name),
                    value = CN.Muted(currency.quantity .. " / "
                        .. currency.maximum .. " " .. CN.DASH .. " spend it"),

                    -- At the cap already: every further point is being thrown
                    -- away, so this is as urgent as the list gets.
                    sortSeconds = 0,
                })
            end

            for _, currency in ipairs(currencies.WeeklyUnfilled()) do
                table.insert(entries, {
                    text  = CN.Muted("WEEK") .. "  " .. tostring(currency.name),
                    value = CN.Muted(currency.remaining .. " left this week"),

                    sortSeconds = resets and resets.weekly or math.huge,
                })
            end
        end

        -- THE LIST'S OWN EMPTY STATE, NOT A ROW THAT DEFEATS IT.
        --
        -- Pushing a fallback row means `#entries` is never zero, so
        -- `list.emptyText` was unreachable on this tab -- and the fallback is
        -- an ordinary body row while every other tab's empty state is muted.
        -- Three tabs did this, each with different wording from the empty
        -- text it was shadowing.

        -- SOONEST FIRST, WHICH IS THE ONLY ORDER THIS TAB CAN MEAN.
        --
        -- Entries were appended in module order -- events, then world quests,
        -- then rares, then capped currencies -- so a world quest with eleven
        -- minutes left sat above a rare that is up right now and below an
        -- event that runs for a fortnight. A list called "expiring soon" in
        -- an order unrelated to expiry is a list you have to read all of.
        --
        -- The tags were also hand-padded with trailing spaces to line up, in
        -- a game that ships no monospace font. The time now lives in the
        -- value column, which is anchored and does line up.
        table.sort(entries, function(a, b)
            local left  = a.sortSeconds or math.huge
            local right = b.sortSeconds or math.huge

            if left == right then
                return tostring(a.text) < tostring(b.text)
            end

            return left < right
        end)

        panel.list:SetEntries(entries)
    end,
}

------------------------------------------------------------
-- TAB: WARBAND
------------------------------------------------------------

UI.RegisterTab{
    name  = "Warband",
    order = 22,

    build = function(panel)
        panel.header = CN.Label(panel, "ARTWORK", "HEAD")
        panel.header:SetPoint("TOPLEFT", CN.SPACE.M, -CN.SPACE.S)
        panel.header:SetPoint("TOPRIGHT", -CN.SPACE.M, -CN.SPACE.S)
        panel.header:SetJustifyH("LEFT")

        panel.list = UI.CreateList(panel)
        panel.list.emptyText = "No other characters recorded yet. Log in on one and this fills itself."
        panel.list:ClearAllPoints()
        panel.list:SetPoint("TOPLEFT", CN.SPACE.S, -32)
        panel.list:SetPoint("BOTTOMRIGHT", -CN.SPACE.S, 38)

        panel.note = CN.Label(panel, "ARTWORK", "SMALL")
        panel.note:SetPoint("BOTTOMLEFT", CN.SPACE.M, CN.SPACE.M)
        panel.note:SetPoint("RIGHT", -CN.SPACE.M, 0)
        panel.note:SetJustifyH("LEFT")
    end,

    refresh = function(panel)
        local module = CN:GetModule("Warband")

        if not module then
            panel.header:SetText("This part of the addon did not load. /cn selftest says what is missing.")
            panel.list:SetEntries({})
            return
        end

        -- O(CHARACTERS x RECIPES), EVERY TWO SECONDS. 0.61.0.
        --
        -- `Coverage` walks every recipe, title and profession of every
        -- character to build three sets, and `Roster` counts four tables per
        -- character. On a twelve-character account with full recipe books
        -- that is 2.30 ms per redraw, and this tab redraws every two seconds
        -- while it is open -- for numbers that change when a character learns
        -- something, which is not something a player does while looking at
        -- this tab.
        --
        -- Alts.lua and `/cn warband` call these once per command and are left
        -- alone; the cost was only ever the repeat.
        local rows     = CN.Memo("warband:roster",
            CN.collectionGeneration, module.Roster)
        local coverage = CN.Memo("warband:coverage",
            CN.collectionGeneration, module.Coverage)

        panel.header:SetText(string.format(
            "%d character%s  |cff8a8f96combined: %d professions, %d recipes, %d titles|r",
            #rows, CN.Pluralize(#rows, ""),
            coverage.professions, coverage.recipes, coverage.titles))

        local entries = {}

        for _, row in ipairs(rows) do
            table.insert(entries, {
                -- `selected` is a texture on the row since 0.54.0; it used to
                -- be a green ">" prepended to the label, which shifted every
                -- other row's text by two glyphs.
                selected = row.isCurrent and true or false,

                -- SAID ONCE, NOT TWICE.
                --
                -- Every character carried a tooltip with these four numbers
                -- AND an indented second row repeating them in prose, which
                -- doubled the length of the tab and left the value column --
                -- which exists for exactly this -- empty.
                --
                -- And `(you)` in words, because the selection is a 16% tint
                -- and this addon's own rule is that nothing is carried by
                -- colour alone.
                text = row.key
                    .. (row.isCurrent and CN.Brand("  (you)") or "")
                    .. CN.Aside(tostring(row.level) .. " "
                        .. CN.TokenLabel(row.class or "?")
                        .. (row.faction
                            and (" " .. CN.FactionLabel(row.faction)) or "")),

                -- THE WORDS THIS TAB USES TWICE ALREADY.
                --
                -- The header says "5 professions, 120 recipes, 12 titles" and
                -- the tooltip says "professions 5 / recipes 120 / titles 12";
                -- between them this column invented "5 prof - 120 rec - 12
                -- tit". "tit" appears nowhere else in the addon. The value
                -- column is 210px and was sized for the longer reputation
                -- string, so there is room for the real words.
                value = CN.Muted(row.professions .. " prof " .. CN.DOT .. " "
                    .. row.recipes .. " recipes " .. CN.DOT .. " "
                    .. row.titles .. " titles"),

                tooltip = string.format(
                    "professions %d\nrecipes %d\ntitles %d\nreputations %d",
                    row.professions, row.recipes, row.titles, row.reputations),
            })
        end

        panel.list:SetEntries(entries)

        if #rows == 1 then
            panel.note:SetText("|cffffc74fOnly one character has been seen. "
                .. "Log in on your alts with the addon loaded to make these "
                .. "comparisons useful.|r")
        else
            panel.note:SetText("")
        end
    end,
}

------------------------------------------------------------
-- TAB: VAULT
------------------------------------------------------------

UI.RegisterTab{
    name  = "Vault",
    order = 14,

    build = function(panel)
        panel.header = CN.Label(panel, "ARTWORK", "HEAD")
        panel.header:SetPoint("TOPLEFT", CN.SPACE.M, -CN.SPACE.S)
        panel.header:SetPoint("TOPRIGHT", -CN.SPACE.M, -CN.SPACE.S)
        panel.header:SetJustifyH("LEFT")

        panel.list = UI.CreateList(panel)
        panel.list.emptyText = "The Great Vault has nothing to report on this character yet."
        panel.list:ClearAllPoints()
        panel.list:SetPoint("TOPLEFT", CN.SPACE.S, -32)
        panel.list:SetPoint("BOTTOMRIGHT", -CN.SPACE.S, 38)

        panel.note = CN.Label(panel, "ARTWORK", "SMALL")
        panel.note:SetPoint("BOTTOMLEFT", CN.SPACE.M, CN.SPACE.M)
        panel.note:SetPoint("RIGHT", -CN.SPACE.M, 0)
        panel.note:SetJustifyH("LEFT")
    end,

    refresh = function(panel)
        local vault = CN:GetModule("Vault")

        if not vault or not vault.IsAvailable() then
            panel.header:SetText("The Great Vault is not available on this client.")
            panel.list:SetEntries({})
            panel.note:SetText("")
            return
        end

        local rows = vault.Rows()

        if #rows == 0 then
            panel.header:SetText("No Great Vault progress yet")
            panel.list:SetEntries({})
            panel.note:SetText("|cff8a8f96The client reports vault progress once you "
                .. "have completed at least one qualifying activity this week.|r")
            return
        end

        local summary = vault.Summary()

        panel.header:SetText(summary.unlocked .. " reward"
            .. CN.Pluralize(summary.unlocked, "") .. " unlocked"
            .. (summary.resetsIn and ("  |cff8a8f96resets in "
                .. vault.FormatReset(summary.resetsIn) .. "|r") or ""))

        local entries = {}

        if summary.claimable then
            table.insert(entries, {
                text = "|cff73b873A reward is waiting to be collected.|r",
            })
        end

        for _, row in ipairs(rows) do
            -- The slot and its three thresholds are one block. See UI/List.lua.
            local group = "vault:" .. tostring(row.row)

            table.insert(entries, {
                group = group,

                text = "  " .. vault.DescribeRow(row),

                tooltip = row.label .. "\n"
                    .. (row.capped
                        and "Every threshold met."
                        or ((vault.rowActions[row.row] or "") .. "\n"
                            .. row.remaining .. " more for the next reward.")),
            })

            for _, tier in ipairs(row.tiers) do
                table.insert(entries, {
                    group = group,
                    text = "        |cff8a8f96" .. tier.threshold .. ": "
                        .. (tier.unlocked
                            and ("|cff73b873unlocked" .. (tier.level and tier.level > 0
                                and (" (item level " .. tier.level .. ")") or "") .. "|r")
                            or "locked")
                        .. "|r",
                })
            end
        end

        panel.list:SetEntries(entries)

        if summary.closest then
            panel.note:SetText("|cffffc74fClosest: " .. summary.closest.label
                .. " " .. CN.DASH .. " " .. summary.closest.remaining .. " more, "
                .. (vault.rowActions[summary.closest.row] or "keep going") .. ".|r")
        else
            panel.note:SetText("|cff8a8f96Every row is capped. You choose one item "
                .. "from everything unlocked.|r")
        end
    end,
}

------------------------------------------------------------
-- TAB: GOALS
------------------------------------------------------------

UI.RegisterTab{
    name  = "Goals",
    order = 15,

    build = function(panel)
        -- `false`, not left unset. See the note on the Next tab: a frame can
        -- answer every field it is asked about, and `panel.selected or
        -- list[1]` below is exactly the shape that turns that into a value
        -- the rest of the function treats as a goal.
        panel.selected = false

        panel.header = CN.Label(panel, "ARTWORK", "HEAD")
        panel.header:SetPoint("TOPLEFT", CN.SPACE.M, -CN.SPACE.S)
        panel.header:SetPoint("TOPRIGHT", -CN.SPACE.M, -CN.SPACE.S)
        panel.header:SetJustifyH("LEFT")

        panel.list = UI.CreateList(panel)
        panel.list.emptyText = "Nothing pinned. /cn goal <type> <name or id> pins something so it stays at the top."
        panel.list:ClearAllPoints()
        panel.list:SetPoint("TOPLEFT", CN.SPACE.S, -32)

        -- Deeper than the other tabs' 38, because this one has a note row
        -- under its buttons. The buttons themselves sit on the same baseline
        -- as every other tab's.
        panel.list:SetPoint("BOTTOMRIGHT", -CN.SPACE.S, 64)

        -- "Next step", not "Navigate". They are different destinations and
        -- the difference is the point: the mount is behind a dungeon you
        -- cannot enter, but the attunement quest is forty yards away.
        panel.navigate = AddButton(panel, "Next step", 110, function()
            local chase = CN:GetModule("Chase")

            if not chase or not panel.selected then
                return
            end

            chase.NavigateNext(chase.Chain(panel.selected))
        end,
            "Points the arrow at the next step of this chase.")
        panel.navigate:SetPoint("BOTTOMLEFT", CN.SPACE.M, CN.SPACE.M)

        panel.remove = AddButton(panel, "Remove goal", 110, function()
            local goals = CN:GetModule("Goals")

            if not goals or not panel.selected then
                return
            end

            goals.Remove(panel.selected.type, panel.selected.id)

            panel.selected = false

            UI.Refresh()
        end,
            "Unpins this goal. It goes back to being ranked like anything else.")
        panel.remove:SetPoint("LEFT", panel.navigate, "RIGHT", CN.SPACE.S, 0)

        -- `CN.FONT.SMALL`, not LABEL. This row carries real information --
        -- what a goal does and how to pin one -- and Design.lua reserves the
        -- disabled font for labels because it sits at roughly 2.8:1 contrast
        -- on this background.
        panel.note = CN.Label(panel, "ARTWORK", "SMALL")
        panel.note:SetPoint("BOTTOMLEFT", CN.SPACE.M, CN.SPACE.M + 26)
        panel.note:SetPoint("RIGHT", -CN.SPACE.M, 0)
        panel.note:SetJustifyH("LEFT")
    end,

    refresh = function(panel)
        local goals = CN:GetModule("Goals")

        if not goals then
            panel.header:SetText("This part of the addon did not load. /cn selftest says what is missing.")
            panel.list:SetEntries({})
            return
        end

        local list = goals.List()

        panel.header:SetText(#list .. " goal" .. CN.Pluralize(#list, "")
            .. " |cff8a8f96of " .. goals.limit .. "|r")

        if #list == 0 then
            panel.list:SetEntries({})
            -- THE COLOURS WERE THE WRONG WAY ROUND. The `|r` before the
            -- command cleared the accent, so the PROSE was gold and the
            -- thing to type was plain -- exactly backwards from the one rule
            -- Design.lua states about ACCENT. And the signature disagreed
            -- with the command's own: it takes a name or an id.
            panel.note:SetText(CN.Muted("Nothing pinned. ")
                .. CN.Accent("/cn goal <type> <name or id>")
                .. CN.Muted(" pins something to work toward. A goal becomes "
                    .. "actionable even when nothing else would surface it, "
                    .. "and anything leading to it ranks higher."))
            return
        end

        -- Keep the selection valid across refreshes; a removed goal must not
        -- leave the buttons pointed at nothing.
        if panel.selected then
            local stillThere = false

            for _, goal in ipairs(list) do
                if goal.type == panel.selected.type and goal.id == panel.selected.id then
                    stillThere = true
                    break
                end
            end

            if not stillThere then
                panel.selected = false
            end
        end

        panel.selected = panel.selected or list[1]

        local chase = CN:GetModule("Chase")

        local entries = {}

        -- Step colours by state, asked of Chase, which owns the states.
        --
        -- This table and a second one in Chase.lua declared the same five
        -- states independently -- one in palette hex, one in raw floats, three
        -- of the floats being colours the palette had retired. Two
        -- declarations of one thing is one of them being wrong later.

        for _, goal in ipairs(list) do
            local chain = chase and chase.Chain(goal) or { steps = {} }

            local isSelected = panel.selected
                and panel.selected.type == goal.type
                and panel.selected.id == goal.id

            local fraction = chase and chase.Fraction(chain)

            -- A bar only where the game supplied a denominator. Everywhere
            -- else the line simply does not claim to know.
            local progressText = ""

            if chain.done then
                progressText = CN.Good("done")
            elseif fraction then
                progressText = CN.Brand(CN.PercentText(fraction))
            end

            -- The goal and every row of its chain carry one group key, so
            -- sorting and filtering move them as a unit. See UI/List.lua.
            local group = tostring(goal.type) .. ":" .. tostring(goal.id)

            table.insert(entries, {
                selected = isSelected,
                group    = group,

                text = (chain.done and CN.Muted(tostring(goal.name))
                        or CN.Accent(tostring(goal.name)))
                    .. CN.Aside(CN.TypeBadge(goal.type)),

                value = progressText,

                fraction = fraction,

                tooltip = chase and chase.Summarize(chain) or tostring(goal.name),

                onClick = function()
                    panel.selected = goal
                    UI.Refresh()
                end,
            })

            -- Only the selected goal expands. Every chain open at once is a
            -- wall of text, and the point of the panel is to make one path
            -- readable.
            if isSelected then
                if fraction then
                    -- The bar is a texture on the row now, not a run of
                    -- equals signs whose pixel width changed as it filled.
                    table.insert(entries, {
                        group    = group,
                        text     = "    " .. CN.Muted(CN.Comma(chain.progress.done)
                            .. " / " .. CN.Comma(chain.progress.total)
                            .. " " .. tostring(chain.progress.unit)),
                        fraction = fraction,
                    })
                end

                local shown = 0

                for _, step in ipairs(chain.steps) do
                    if shown >= 15 then
                        table.insert(entries, {
                            group = group,
                            text  = "      |cff8a8f96... and "
                                .. (#chain.steps - shown) .. " more|r",
                        })
                        break
                    end


                    local marker = "  "

                    -- EVERY STATE GETS A GLYPH, NOT JUST TWO OF THEM.
                    --
                    -- Done was "x", next was ">", and BLOCKED -- the one
                    -- state that tells a player to stop reading down the
                    -- chain -- was carried by red text alone. Red against
                    -- this file's TODO grey is a hue difference of exactly
                    -- the kind eight percent of men cannot make, and the
                    -- addon ships a colourblind mode for the arrow that says
                    -- so in its own help text.
                    if step.state == "DONE" then
                        marker = "x "
                    elseif step.state == "NEXT" then
                        marker = "> "
                    elseif step.state == "BLOCKED" then
                        marker = "! "
                    end

                    table.insert(entries, {
                        group = group,
                        text  = "      " .. (chase
                            and chase.StateText(step.state, marker .. step.text)
                            or (marker .. step.text)),
                    })

                    shown = shown + 1
                end

                if chain.character then
                    table.insert(entries, {
                        group = group,
                        text  = "      |cff8a8f96Best character: "
                            .. tostring(chain.character) .. "|r",
                    })
                end
            end
        end

        panel.list:SetEntries(entries)

        local selectedChain = chase and chase.Chain(panel.selected)

        if selectedChain then
            panel.note:SetText("|cff8a8f96" .. chase.Summarize(selectedChain) .. "|r")
        else
            panel.note:SetText("")
        end
    end,
}

------------------------------------------------------------
-- TAB: JOURNEY
------------------------------------------------------------

-- Where a long campaign lives. A player working through every quest in the
-- game is not served by a list of the next five things; they want to know
-- how far they have come and which zone is closest to finished.
UI.RegisterTab{
    name  = "Journey",
    order = 12,

    build = function(panel)
        -- `CN.FONT.HEAD`, like the other seven. This one was a size larger
        -- than every other tab's header for no reason anybody recorded.
        panel.header = CN.Label(panel, "ARTWORK", "HEAD")
        panel.header:SetPoint("TOPLEFT", CN.SPACE.M, -CN.SPACE.S)
        panel.header:SetPoint("TOPRIGHT", -CN.SPACE.M, -CN.SPACE.S)
        panel.header:SetJustifyH("LEFT")

        panel.sub = CN.Label(panel, "ARTWORK", "SMALL")
        panel.sub:SetPoint("TOPLEFT", panel.header, "BOTTOMLEFT", 0, -4)
        panel.sub:SetJustifyH("LEFT")

        panel.list = UI.CreateList(panel)
        panel.list.emptyText = "No zone achievements scanned yet. Press Rescan zones."
        panel.list:ClearAllPoints()
        panel.list:SetPoint("TOPLEFT", CN.SPACE.S, -52)
        panel.list:SetPoint("BOTTOMRIGHT", -CN.SPACE.S, 38)

        panel.follow = AddButton(panel, "Follow the route", 150, function()
            local follow = CN:GetModule("Follow")

            if follow then
                follow.Toggle()
            end

            UI.Refresh()
        end,
            "Walks the route one stop at a time, moving the arrow as you clear each one.")
        panel.follow:SetPoint("BOTTOMLEFT", CN.SPACE.M, CN.SPACE.M)

        -- The three session lengths people actually have. A text field
        -- asking for a number would be more general and less used.
        panel.plan30 = AddButton(panel, "30 min", 70, function()
            CN.HandleSlashCommand("plan 30")
        end,
            "Plans what fits in thirty minutes, from measured travel and learned task times.")
        panel.plan30:SetPoint("BOTTOMRIGHT", -CN.SPACE.M, CN.SPACE.M)

        panel.plan60 = AddButton(panel, "1 hour", 70, function()
            CN.HandleSlashCommand("plan 60")
        end,
            "Plans what fits in an hour, from measured travel and learned task times.")
        panel.plan60:SetPoint("RIGHT", panel.plan30, "LEFT", -CN.SPACE.S, 0)

        panel.rescan = AddButton(panel, "Rescan zones", 130, function()
            local lore = CN:GetModule("Loremaster")

            if lore then
                -- AND IT SAYS WHETHER IT WORKED. 0.73.0.
                --
                -- The button threw both returns away and redrew, so a rescan
                -- the client refused -- routine in the first seconds after a
                -- loading screen -- looked exactly like one that worked: the
                -- same unchanged list, and nothing to tell the player to try
                -- again. `/cn scanlore` was given this message in 0.72.0 and
                -- the button beside it was not.
                local scanned, measured = lore.Scan()

                if measured == 0 then
                    UI.Answer("The game would not answer about zone progress "
                        .. "just now. Try again in a few seconds.")
                else
                    UI.Answer("Read " .. scanned .. " zone achievements.")
                end
            end

            UI.Refresh()
        end,
            "Reads what is left in every zone this addon knows about.")
        panel.rescan:SetPoint("LEFT", panel.follow, "RIGHT", CN.SPACE.S, 0)
    end,

    refresh = function(panel)
        local progress = CN:GetModule("Progress")
        local lore     = CN:GetModule("Loremaster")
        local follow   = CN:GetModule("Follow")

        if progress then
            local summary = progress.Summary()

            panel.header:SetText(summary.lifetime
                and ("|cffffc74f" .. CN.Comma(summary.lifetime)
                    .. "|r quests completed")
                or "Quest progress")

            local parts = { summary.today .. " today" }

            if summary.session > 0 then
                table.insert(parts, summary.session .. " this session")
            end

            if summary.perHour then
                table.insert(parts,
                    string.format("%.0f per hour", summary.perHour))
            end

            if summary.best > 0 then
                table.insert(parts, "best day " .. summary.best)
            end

            panel.sub:SetText("|cff8a8f96" .. table.concat(parts, "   ") .. "|r")
        else
            panel.header:SetText("Quest progress")
            panel.sub:SetText("")
        end

        panel.follow:SetText(follow and follow.active
            and "Stop following" or "Follow the route")

        local entries = {}

        if lore then
            local zone = lore.ForZone()

            if zone then
                -- THE ROW'S OWN BAR AND VALUE COLUMN.
                --
                -- This embedded `CN.ProgressBar` -- a run of "=" and "-"
                -- characters -- inside the label, which is the shape
                -- UI/List.lua documents as replaced: WoW ships no monospace
                -- font, so the two characters are different widths and the
                -- bar got SHORTER as it filled. It also put "12/17" inside
                -- the label while Collections and Remaining put the identical
                -- figure in the value column, and it poisoned the sort, which
                -- strips colour codes but not a run of equals signs.
                local fraction

                if (zone.criteria or 0) > 0 then
                    fraction = zone.done / zone.criteria
                end

                -- AND A FINISHED ZONE IS SAID TO BE FINISHED. 0.72.0.
                --
                -- This row ignored `zone.completed`, so a zone the account
                -- had already earned drew in the unfinished gold with a full
                -- bar and "60 / 60" beside it -- reading, on the tab a player
                -- looks at most, as a piece of work still to do.
                --
                -- Every other surface already carried this rule: the
                -- candidate provider returns early on it, `PrintAchievement`
                -- colours it green, and `Closest` gained `done < criteria`
                -- last release. Fourth copy, first one the player sees.
                local done = zone.completed
                    or (fraction ~= nil and zone.done >= zone.criteria)

                table.insert(entries, {
                    text     = (done and (CN.Good("Here") .. "  ")
                        or "|cffffc74fHere|r  ") .. tostring(zone.name),
                    value    = fraction
                        and (done
                            and CN.Good(zone.done .. " / " .. zone.criteria)
                            or CN.Body(zone.done .. " / " .. zone.criteria))
                        or nil,
                    fraction = fraction,
                })
            end

            -- READ-ONLY WHEN NOBODY IS LOOKING. 0.70.0.
            --
            -- This reaches `Quests.AvailableOnMap`, which files every pin it
            -- walks past into a SavedVariable -- and a refresh with the
            -- window hidden happens for one reason: `/cn find` builds every
            -- tab so the search has rows. A search must not write to disk.
            local split = lore.SplitZoneWork(nil,
                not (window and window:IsShown()))

            if #split.story > 0 or #split.side > 0 then
                table.insert(entries, {
                    text = "      |cff8a8f96" .. #split.story
                        .. " story, " .. #split.side
                        .. " side quests available here|r",
                })
            end

            local closest = lore.Closest(12)

            if #closest > 0 then
                table.insert(entries, { text = " " })

                -- A section rather than a group: these twelve are peers, so
                -- they may be alphabetised -- among themselves, under their
                -- own heading. See UI/List.lua.
                table.insert(entries, {
                    section       = "closest",
                    sectionHeader = true,
                    text          = "|cffffc74fClosest to finished|r",
                })

                for _, entry in ipairs(closest) do
                    table.insert(entries, {
                        section = "closest",

                        text     = "  |cffffc74f" .. tostring(entry.name) .. "|r",
                        value    = CN.Body(entry.done .. " / " .. entry.criteria),
                        fraction = entry.fraction,

                        tooltip  = tostring(entry.category or ""),
                    })
                end
            end
        end

        panel.list:SetEntries(entries)
    end,
}

------------------------------------------------------------
-- TAB: REMAINING
------------------------------------------------------------

UI.RegisterTab{
    name  = "Remaining",
    order = 27,

    build = function(panel)
        panel.header = CN.Label(panel, "ARTWORK", "HEAD")
        panel.header:SetPoint("TOPLEFT", CN.SPACE.M, -CN.SPACE.S)
        panel.header:SetPoint("TOPRIGHT", -CN.SPACE.M, -CN.SPACE.S)
        panel.header:SetJustifyH("LEFT")

        panel.list = UI.CreateList(panel)
        panel.list.emptyText = "Nothing to report yet. Run the scans first."
        panel.list:ClearAllPoints()
        panel.list:SetPoint("TOPLEFT", CN.SPACE.S, -32)
        panel.list:SetPoint("BOTTOMRIGHT", -CN.SPACE.S, 38)

        panel.refresh = AddButton(panel, "Refresh", 110, function()
            -- FORCED. The report is cached behind the events that announce a
            -- collection, and most of what it counts is not a collection --
            -- harvested quests, captured recipes, scanned vendors. So the
            -- button whose tooltip says "counts what is left again" could
            -- not, and a row telling you to run `/cn harvest` went on showing
            -- the old number after you ran it.
            -- AND `force`, WHICH NOTHING EVER PASSED. 0.63.0.
            --
            -- `NoteChanged` busts the report cache; it does not touch the
            -- incrementally-maintained quest count, which is exactly the row
            -- most likely to be stale -- quests completed in a session where
            -- the addon was not loaded, or credited to the Warband. The
            -- `force` parameter was added in 0.61.0 for this button and then
            -- given no caller, so every other row moved when the player
            -- pressed Refresh and the Quests row did not.
            --
            -- A grep for `Report(` returned two call sites and neither passed
            -- it. That is what a half-finished fix looks like.
            local breakdown = CN:GetModule("Breakdown")

            if breakdown then
                breakdown.NoteChanged()
                breakdown.Report(nil, true)
            end

            UI.Refresh()
        end,
            "Counts what is left again and redraws this list.")
        panel.refresh:SetPoint("BOTTOMLEFT", CN.SPACE.M, CN.SPACE.M)
    end,

    refresh = function(panel)
        local module = CN:GetModule("Breakdown")

        if not module then
            panel.header:SetText("This part of the addon did not load. /cn selftest says what is missing.")
            panel.list:SetEntries({})
            return
        end

        panel.header:SetText("What is left, and why")

        local entries = {}

        for _, row in ipairs(module.Report()) do
            local headline

            -- PADDING REMOVED, COLUMN ADDED. `%-14s` in a proportional font
            -- is not a column; the list row has a right-aligned value slot
            -- and a progress bar, which is what this was trying to be.
            local value, fraction

            headline = CN.Accent(row.name)

            if row.total and row.total > 0 then
                fraction = (row.collected or 0) / row.total

                value = CN.Body((row.collected or 0) .. " / " .. row.total)
                    .. "  " .. CN.Muted(CN.PercentText(fraction, 1))
            else
                value = CN.Body((row.collected or 0) .. " collected")
            end

            -- The row and everything indented under it -- why there is no
            -- percentage, the reasons, the action -- are one block. See
            -- UI/List.lua.
            local group = "remaining:" .. tostring(row.name)

            table.insert(entries, {
                group    = group,
                text     = headline,
                value    = value,
                fraction = fraction,
                tooltip  = row.unknownTotal
                    and ("No percentage is shown because " .. row.unknownTotal .. ".")
                    or nil,
            })

            if row.unknownTotal then
                table.insert(entries, {
                    group = group,
                    text  = "      " .. CN.Muted("no percentage: "
                        .. row.unknownTotal),
                })
            end

            for _, reason in ipairs(CN.Reasons(row)) do
                table.insert(entries, { group = group, text = "      " .. reason })
            end

            if row.action then
                -- THE ADDON KNOWS THE NEXT ACTION AND MADE YOU RETYPE IT.
                --
                -- `row.action` is literally "/cn mountscan". It was rendered
                -- as an inert line and the player had to read it, remember
                -- it, and type it into chat -- while it sat there, on screen,
                -- in a list widget that already supports clicking.
                --
                -- Guarded on the prefix: one action is prose ("open each
                -- profession window once"), which correctly stays inert.
                local command = row.action:match("^/cn (.+)$")

                table.insert(entries, {
                    group = group,

                    text = "      " .. CN.Accent((command and "" or "")
                        .. CN.DASH .. " " .. row.action),

                    onClick = command and function()
                        CN.HandleSlashCommand(command)

                        -- The counts this row reports are exactly what the
                        -- scan changes, so recount rather than redraw the
                        -- same numbers.
                        local breakdown = CN:GetModule("Breakdown")

                        if breakdown then
                            breakdown.NoteChanged()
                        end

                        UI.Refresh()
                    end or nil,

                    tooltip = command and ("Runs " .. row.action .. ".") or nil,
                })
            end
        end

        panel.list:SetEntries(entries)
    end,
}

------------------------------------------------------------
-- TAB: COLLECTIONS
------------------------------------------------------------

-- The account dashboard. Every row is "collected / known" -- and the
-- percentage beside it is that ratio and nothing wider.
--
-- The comment here used to say "never a fabricated percentage of some total
-- the addon cannot verify" and the code fifty lines below formatted `%.1f%%`.
-- Both halves were defensible on their own: the denominator IS the addon's
-- own scan snapshot, which is exactly what the row says. What was missing was
-- anything on screen saying WHEN that snapshot was taken, so a figure that
-- silently goes stale the day the game adds collectibles read as current.
-- The header now says so, and each row carries its scan age.
UI.RegisterTab{
    name  = "Collections",
    order = 25,

    build = function(panel)
        panel.header = CN.Label(panel, "ARTWORK", "HEAD")
        panel.header:SetPoint("TOPLEFT", CN.SPACE.M, -CN.SPACE.S)
        panel.header:SetPoint("TOPRIGHT", -CN.SPACE.M, -CN.SPACE.S)
        panel.header:SetJustifyH("LEFT")

        panel.list = UI.CreateList(panel)
        panel.list.emptyText = "Nothing scanned yet. Press Scan everything."
        panel.list:ClearAllPoints()
        panel.list:SetPoint("TOPLEFT", CN.SPACE.S, -32)
        panel.list:SetPoint("BOTTOMRIGHT", -CN.SPACE.S, 38)

        -- A WORKING STATE, BECAUSE THIS FREEZES THE CLIENT.
        --
        -- The button printed "this takes a moment", ran six synchronous
        -- scans, and printed "complete" -- and because chat does not flush
        -- mid-frame, both lines appeared together when the client unfroze.
        -- From the player's side: click, the game stops, the game starts, two
        -- messages arrive at once. Nothing on screen ever said it was working.
        --
        -- `C_Timer.After(0, ...)` lets the frame paint the disabled state
        -- first, which is the whole difference.
        local function RunScans(button, label, work)
            button:SetEnabled(false)
            button:SetText("Working" .. CN.DOT .. CN.DOT .. CN.DOT)

            local function finish()
                -- PROTECTED, OR THE BUTTON WEDGES.
                --
                -- `work()` ran raw, and it is re-enabled AFTER it returns --
                -- so a scan that threw left the button disabled and reading
                -- "Working..." until the player reloaded, with no way to
                -- retry and nothing on screen saying why. The achievement
                -- scan walks `GetCategoryList`/`GetAchievementInfo`, whose
                -- shape has changed across expansions, which is exactly the
                -- kind of call this cannot afford to trust.
                local ok, err = pcall(work)

                button:SetText(label)
                button:SetEnabled(true)

                if not ok then
                    UI.Answer(CN.Bad("That scan failed. ")
                        .. CN.Muted("/cn errors has the detail."))

                    local errors = CN:GetModule("Errors")

                    if errors then
                        errors.Record("the " .. label .. " button", err)
                    end
                end

                UI.Refresh()
            end

            if C_Timer and C_Timer.After then
                C_Timer.After(0, finish)
            else
                finish()
            end
        end

        panel.scanAll = AddButton(panel, "Scan everything", 140, function()
            RunScans(panel.scanAll, "Scan everything", function()
                local scanned = 0

                for _, moduleName in ipairs({ "Pets", "Mounts", "Toys",
                                              "Appearances", "Titles",
                                              "Professions" }) do
                    local module = CN:GetModule(moduleName)

                    if module and module.Scan then
                        if pcall(module.Scan) then
                            scanned = scanned + 1

                            if CN.NoteSetupStep then
                                CN.NoteSetupStep(moduleName)
                            end
                        end
                    end
                end

                UI.Answer("Read " .. scanned .. " collections.")
            end)
        end, "Read your pets, mounts, toys, appearances, titles and "
            .. "professions from the game. Takes a few seconds and freezes "
            .. "the client while it runs.")

        panel.scanAll:SetPoint("BOTTOMLEFT", CN.SPACE.M, CN.SPACE.M)

        panel.achieve = AddButton(panel, "Scan achievements", 150, function()
            RunScans(panel.achieve, "Scan achievements", function()
                local module = CN:GetModule("Achievements")

                if not module then
                    return
                end

                local scanned, completed = module.Scan()

                if CN.NoteSetupStep then
                    CN.NoteSetupStep("Achievements")
                end

                UI.Answer("Read " .. CN.Comma(scanned) .. " achievements, "
                    .. CN.Comma(completed) .. " of them done.")
            end,
                "Reads your achievement criteria again.")
        end, "Read the achievement tree, so the addon can say which ones you "
            .. "are close to finishing.")

        panel.achieve:SetPoint("LEFT", panel.scanAll, "RIGHT", CN.SPACE.S, 0)
    end,

    refresh = function(panel)
        local entries = {}

        -- EIGHT STORE WALKS, EVERY TWO SECONDS, FOR SIXTEEN INTEGERS. 0.61.0.
        --
        -- Each `Summary()` below walks its module's whole store -- three
        -- thousand achievement rows, eighteen hundred pets, and so on -- to
        -- produce a collected count and a total. This tab refreshes every two
        -- seconds for as long as the window is open, and none of those
        -- numbers can move unless the player collects something, which fires
        -- an event the addon already subscribes to. Measured at retail scale:
        -- 4.40 ms per refresh, indefinitely.
        --
        -- `CN.collectionGeneration` is bumped by exactly those events. See
        -- Scoring.lua, where the addon's generation counters live.
        local setup = CN:GetModule("Setup")

        -- WHEN THE DENOMINATOR WAS READ.
        --
        -- Every percentage on this tab is against the addon's own scan
        -- snapshot, which is the honest denominator and also one that goes
        -- stale the day the game adds collectibles. The header said so in
        -- general; no row said it about itself, so "89.4%" from a scan four
        -- months ago looked exactly like one from this morning.
        --
        -- `Setup.Steps()` has had the per-scan timestamps since 0.52.0 and
        -- nothing displayed them.
        local steps = (setup and setup.Steps and setup.Steps()) or {}

        local function Age(key)
            return CN.Ago(steps[string.lower(tostring(key))])
        end

        local function row(label, collected, total, note, key)
            local age = Age(key or label)

            -- "never read" rather than nothing: a row with no age is not a
            -- row that was read at an unknown time.
            local stamp = CN.Muted("  " .. (age or "never read"))

            if total and total > 0 then
                local fraction = collected / total

                table.insert(entries, {
                    text     = label .. stamp,
                    value    = CN.Body(collected .. " / " .. total) .. "  "
                        .. CN.Muted(CN.PercentText(fraction, 1)),
                    fraction = fraction,
                    tooltip  = age
                        and ("Counted against what the addon read " .. age
                            .. ". Rescan to bring it up to date.")
                        or "This has never been scanned on this account.",
                })
            else
                table.insert(entries, {
                    text  = label .. stamp,
                    value = CN.Muted(note or "not scanned"),
                })
            end
        end

        local pets = CN:GetModule("Pets")

        if pets then
            local counts = CN.Memo("summary:Pets",
                CN.collectionGeneration, pets.Summary)
            row("Pets", counts.collected, counts.known)
        end

        local mounts = CN:GetModule("Mounts")

        if mounts then
            local counts = CN.Memo("summary:Mounts",
                CN.collectionGeneration, mounts.Summary)
            row("Mounts", counts.collected, counts.known)
        end

        local toys = CN:GetModule("Toys")

        if toys then
            local counts = CN.Memo("summary:Toys",
                CN.collectionGeneration, toys.Summary)
            row("Toys", counts.collected, counts.known)
        end

        local appearances = CN:GetModule("Appearances")

        if appearances then
            local counts = CN.Memo("summary:Appearances",
                CN.collectionGeneration, appearances.Summary)
            row("Appearances", counts.collected, counts.total)
        end

        local titles = CN:GetModule("Titles")

        if titles then
            local counts = CN.Memo("summary:Titles",
                CN.collectionGeneration, titles.Summary)
            row("Titles", counts.onAccount, counts.known)
        end

        local achievements = CN:GetModule("Achievements")

        if achievements then
            local counts = CN.Memo("summary:Achievements",
                CN.collectionGeneration, achievements.Summary)
            row("Achievements", counts.completed, counts.total)
        end

        local reputations = CN:GetModule("Reputations")

        if reputations then
            local counts = CN.Memo("summary:Reputations",
                CN.collectionGeneration, reputations.Summary)

            table.insert(entries, {
                text  = "Reputations"
                    .. CN.Muted("  " .. (Age("reputations") or "never read")),
                value = CN.Body(counts.account) .. CN.Muted(" account-wide")
                    .. CN.Muted(", ") .. CN.Body(counts.character)
                    .. CN.Muted(" this character"),
            })
        end

        table.insert(entries, { text = " " })

        local quests = CN:GetModule("Quests")

        if quests then
            table.insert(entries, {
                text  = "Quests"
                    .. CN.Muted("  " .. (Age("quests") or "never read")),
                value = CN.Body(CN.CountKeys(CN.Account("discoveredQuests")))
                    .. CN.Muted(" discovered"),
            })
        end

        local professions = CN:GetModule("Professions")

        if professions then
            for _, record in ipairs(CN.Memo("summary:Professions",
                CN.collectionGeneration, professions.Summary)) do
                local note = record.recipesSeen
                    and CN.Muted(record.recipeKnown .. " of "
                        .. record.recipeTotal .. " recipes")
                    or CN.Accent("open its window once")

                table.insert(entries, {
                    text  = (record.name or "?")
                        .. CN.Muted("  "
                            .. (Age("professions") or "never read")),
                    value = CN.Body(tostring(record.rank) .. " / "
                        .. tostring(record.maxRank)) .. "  " .. note,
                })
            end

            local waiting = professions.AwaitingRecipeCapture()

            if #waiting > 0 then
                table.insert(entries, { text = " " })
                table.insert(entries, {
                    text = "|cffffc74fRecipes need the profession window open: "
                        .. table.concat(waiting, ", ") .. "|r",
                    tooltip = "The client only exposes a recipe list while that "
                        .. "profession's window is open. Open each one once and "
                        .. "the addon captures it automatically.",
                })
            end
        end

        panel.header:SetText("Account completion  |cff8a8f96(collected / "
            .. "known at the last scan" .. CN.DASH .. "not of everything in the game)|r")
        panel.list:SetEntries(entries)
    end,
}

------------------------------------------------------------
-- TAB: SETTINGS
------------------------------------------------------------

UI.RegisterTab{
    name  = "Settings",
    order = 40,

    build = function(panel)
        -- TWO COLUMNS, GROUPED BY WHAT THE SETTING IS ABOUT.
        --
        -- Twenty-one settings existed and seven were reachable here. The
        -- thirteen that were not included BOTH accessibility controls -- text
        -- scale and colourblind arrow labelling -- so the players who most
        -- need a larger interface were the least likely to find it, since the
        -- only way in was `/cn scale 1.4` typed into chat.
        --
        -- Grouped by subject, and every group is a heading and a stack, so
        -- the panel reads as a settings page rather than as a column of
        -- checkboxes in registration order.
        local LEFT   = CN.SPACE.M
        local COLUMN = 268

        local function Heading(text, anchor, column)
            local head = CN.Label(panel, "ARTWORK", "HEAD")

            head:SetTextColor(CN.Rgb("ACCENT"))
            head:SetText(text)

            if anchor then
                head:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -CN.SPACE.L)
            else
                head:SetPoint("TOPLEFT", column or LEFT, -CN.SPACE.M)
            end

            return head
        end

        local function Under(frame, anchor, gap)
            frame:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -(gap or CN.SPACE.S))

            return frame
        end

        ------------------------------------------------------------
        -- WHAT THE ADDON IS AIMING AT
        ------------------------------------------------------------
        panel.focusHead = Heading("What you are playing for")

        panel.focusButton = AddButton(panel, "Everything", 170, function()
            local filters = CN:GetModule("Filters")

            if not filters then
                return
            end

            -- Cycles the FOCUS presets, which is the thing the welcome screen
            -- sets and the thing that hides objective types. The window used
            -- to expose the other one -- the weighting profile -- under the
            -- label "Priority mode", so a player who chose Collecting at
            -- first run had thirteen types hidden and found no control here
            -- that said so.
            local names = {}

            for name in pairs(CN.modes) do
                table.insert(names, name)
            end

            table.sort(names)

            local current = select(1, filters.CurrentMode())

            local index = 0

            for position, name in ipairs(names) do
                if name == current then
                    index = position
                    break
                end
            end

            filters.ApplyMode(names[(index % #names) + 1])

            UI.Refresh()
        end, "A focus weights the ranking AND hides the kinds of thing you "
            .. "are not chasing. Click to cycle.")

        Under(panel.focusButton, panel.focusHead, CN.SPACE.XS)

        panel.focusClear = AddButton(panel, "Clear focus", 120, function()
            local filters = CN:GetModule("Filters")

            if filters then
                filters.ClearMode()
            end

            UI.Refresh()
        end, "Puts back the filters and the weighting you had before the "
            .. "focus was set.")

        -- ON ITS OWN ROW, NOT BESIDE THE FOCUS BUTTON.
        --
        -- The left column is 268 wide. "Everything" is 170 starting at 12, so
        -- it ends at 182; "Clear focus" is 120 starting at 190 and ends at
        -- 310 -- forty-two pixels into the right column, on top of the
        -- "Minimap button" checkbox, which is the first control over there
        -- and sits in the same vertical band. Two controls drawn on top of
        -- each other, on the tab whose own header says it was rebuilt so the
        -- window would read as a settings page.
        Under(panel.focusClear, panel.focusButton, CN.SPACE.XS)

        panel.focusNote = CN.Label(panel, "ARTWORK", "SMALL")
        panel.focusNote:SetTextColor(CN.Rgb("MUTED"))
        panel.focusNote:SetWidth(COLUMN - CN.SPACE.M)
        panel.focusNote:SetJustifyH("LEFT")
        Under(panel.focusNote, panel.focusClear, CN.SPACE.XS)

        panel.weightHead = Heading("Ranking weight", panel.focusNote)

        panel.modeButton = AddButton(panel, "balanced", 170, function()
            local settings = CN.Settings()
            local modes    = CN.priorityModes

            local currentIndex = 1

            for index, mode in ipairs(modes) do
                if mode == settings.priorityMode then
                    currentIndex = index
                    break
                end
            end

            settings.priorityMode = modes[(currentIndex % #modes) + 1]

            CN.InvalidateCandidates()

            UI.Refresh()
        end, "How the ranking trades travel time against how much a thing is "
            .. "worth. Does not hide anything. Click to cycle.")

        Under(panel.modeButton, panel.weightHead, CN.SPACE.XS)

        panel.learn = AddCheckbox(panel, "Learn from what I actually do",
            function()
                local preference = CN:GetModule("Preference")

                return preference and preference.IsEnabled()
            end,
            function(value)
                local preference = CN:GetModule("Preference")

                if preference then
                    preference.SetEnabled(value)
                end
            end,
            "Quietly ranks the kinds of thing you act on above the kinds you "
            .. "skip. /cn learned shows what it has noticed and undoes it.")

        Under(panel.learn, panel.modeButton, CN.SPACE.M)

        ------------------------------------------------------------
        -- WHAT IT DRAWS
        ------------------------------------------------------------
        panel.screenHead = Heading("On screen", nil, COLUMN)
        panel.screenHead:ClearAllPoints()
        panel.screenHead:SetPoint("TOPLEFT", COLUMN, -CN.SPACE.M)

        panel.minimap = AddCheckbox(panel, "Minimap button",
            function() return not CN.Settings().minimap.hide end,
            function(value)
                CN.Settings().minimap.hide = not value
                UI.UpdateMinimapButton()
            end,
            "Left-click opens this window, right-click navigates to the next "
            .. "objective, middle-click starts follow mode.")

        Under(panel.minimap, panel.screenHead, CN.SPACE.XS)

        panel.arrow = AddCheckbox(panel, "Navigation arrow",
            function()
                local nav = CN:GetModule("Navigation")
                return nav and nav.IsArrowEnabled()
            end,
            function(value)
                CN.Settings().arrow = value

                local nav = CN:GetModule("Navigation")

                if nav then
                    if value then
                        nav.BuildArrow()
                        nav.Refresh()
                    else
                        nav.Clear()
                    end
                end
            end,
            "Only appears once something is being tracked, so it is never in "
            .. "the way when you are not navigating.")

        Under(panel.arrow, panel.minimap, CN.SPACE.XS)

        panel.pins = AddCheckbox(panel, "Route pins on the world map",
            function()
                local pins = CN:GetModule("MapPins")
                return pins and pins.IsEnabled()
            end,
            function(value)
                local pins = CN:GetModule("MapPins")

                if pins then
                    pins.SetEnabled(value)
                end
            end,
            "Numbered stops for the zone you are looking at, brightest first.")

        Under(panel.pins, panel.arrow, CN.SPACE.XS)

        panel.tooltips = AddCheckbox(panel, "Lines on item and unit tooltips",
            function() return CN.Settings().tooltips ~= false end,
            function(value) CN.Settings().tooltips = value end,
            "Only where there is something to say" .. CN.DASH .. "most items have nothing.")

        Under(panel.tooltips, panel.pins, CN.SPACE.XS)

        panel.hud = AddCheckbox(panel, "Heads-up line",
            function()
                local hud = CN:GetModule("Hud")
                return hud and hud.IsEnabled()
            end,
            function(value)
                local hud = CN:GetModule("Hud")

                if hud then
                    hud.SetEnabled(value)
                end
            end,
            "A small always-on line showing the current stop. Off by default.")

        Under(panel.hud, panel.tooltips, CN.SPACE.XS)

        panel.cues = AddCheckbox(panel, "Sound when I clear a stop",
            function() return CN.Settings().cues and true or false end,
            function(value)
                CN.Settings().cues = value or nil
            end,
            "A quiet tap on arriving and clearing a stop, and a flourish when "
            .. "a route finishes. Off by default.")

        Under(panel.cues, panel.hud, CN.SPACE.XS)

        -- THE TWO MOST INTRUSIVE THINGS THE ADDON CAN DO WERE TYPING-ONLY.
        --
        -- The header on this tab says it was rebuilt because "twenty-one
        -- settings existed and seven were reachable in the window". Moving
        -- the player's waypoint on its own, and making a noise, are exactly
        -- the two a player wants to find and switch off in a settings panel
        -- rather than discover by surprise -- and both were reachable only by
        -- typing a command they would have to already know about.
        panel.autoWaypoint = AddCheckbox(panel,
            "Move the waypoint on as I finish things",
            function() return CN.IsAutoWaypointEnabled() end,
            function(value)
                CN.Settings().autoWaypoint = value and true or false

                if value and CN.StartAutoWaypointTicker then
                    CN.StartAutoWaypointTicker()
                end
            end,
            "Off by default. Taking over the waypoint uninvited is the most "
            .. "intrusive thing this addon can do, and TomTom's arrow is "
            .. "shared with every other addon you run.")

        Under(panel.autoWaypoint, panel.cues, CN.SPACE.XS)

        panel.rares = AddCheckbox(panel, "Announce rares out loud",
            function() return CN.Settings().rareAlerts == true end,
            function(value) CN.Settings().rareAlerts = value and true or false end,
            "Off by default. Unsolicited sound is worse than an uninvited "
            .. "waypoint, and the waypoint is already off.")

        Under(panel.rares, panel.autoWaypoint, CN.SPACE.XS)

        ------------------------------------------------------------
        -- ACCESSIBILITY -- BOTH OF THESE WERE SLASH-ONLY.
        ------------------------------------------------------------
        -- ANCHORED TO THE LAST CONTROL IN THE COLUMN, NOT THE THIRD-LAST.
        --
        -- Two checkboxes were added above and this anchor was left on
        -- `panel.cues`, so the words "Easier to read" were printed across the
        -- "Move the waypoint on as I finish things" checkbox and the 22-tall
        -- "Size 1.00" button was drawn on top of "Announce rares out loud" --
        -- taking the mouse, so that checkbox could not be clicked at all.
        -- The identical defect this file documents as fixed for "Clear focus"
        -- a hundred and eighty lines above, reintroduced by an insertion.
        panel.accessHead = Heading("Easier to read", panel.rares)

        panel.scale = AddButton(panel, "Size 1.0", 120, function()
            local hud = CN:GetModule("Hud")

            if not hud then
                return
            end

            local steps = { 0.9, 1.0, 1.1, 1.25, 1.5 }

            local current = hud.Scale and hud.Scale() or 1

            local index = 1

            for position, value in ipairs(steps) do
                if math.abs(value - current) < 0.001 then
                    index = position
                    break
                end
            end

            hud.SetScale(steps[(index % #steps) + 1])

            UI.Refresh()
        end, "How large everything this addon draws is" .. CN.DASH .. "the window, the "
            .. "arrow, the heads-up line. Click to cycle.")

        Under(panel.scale, panel.accessHead, CN.SPACE.XS)

        panel.colourblind = AddCheckbox(panel, "Label the arrow in words too",
            function()
                local hud = CN:GetModule("Hud")
                return hud and hud.IsColourblind()
            end,
            function(value)
                local hud = CN:GetModule("Hud")

                if hud then
                    hud.SetColourblind(value)
                end
            end,
            "Writes ahead, veer or turn round beside the arrow, and switches "
            .. "its colours to a palette that separates by lightness rather "
            .. "than by hue.")

        Under(panel.colourblind, panel.scale, CN.SPACE.XS)

        -- A SECOND AXIS, BECAUSE THEY ARE DIFFERENT QUESTIONS. 0.66.0.
        --
        -- "Size" scales the whole frame: the window grows with the text. That
        -- is the answer to "this addon is too small on my monitor". It is not
        -- the answer to "I cannot read this", where the player wants the same
        -- window and larger letters -- and until now there was no way to ask.
        panel.textSize = AddButton(panel, "Text 100%", 120, function()
            local steps   = CN.textScales
            local current = CN.TextScale()

            local index = 1

            for position, value in ipairs(steps) do
                if math.abs(value - current) < 0.001 then
                    index = position
                    break
                end
            end

            CN.SetTextScale(steps[(index % #steps) + 1])

            UI.Refresh()
        end, "How large the text in this window is, without changing the size "
            .. "of the window. Click to cycle.")

        Under(panel.textSize, panel.colourblind, CN.SPACE.XS)

        panel.keepFilter = AddCheckbox(panel, "Keep the filter box across tabs",
            function() return CN.Settings().keepFilter and true or false end,
            function(value)
                CN.Settings().keepFilter = value or nil

                if not value then
                    UI.persistedFilter = nil
                end
            end,
            "Off is safer: a filter that persists invisibly is how a list "
            .. "looks empty when it is not.")

        Under(panel.keepFilter, panel.textSize, CN.SPACE.XS)

        ------------------------------------------------------------
        -- THE REST
        ------------------------------------------------------------
        -- "Run first-time setup", NOT "Scan everything now".
        --
        -- Collections has a button called "Scan everything" that reads six
        -- collections, and this one runs eleven scans through `Setup.Run`.
        -- Two buttons, two tabs, near-identical labels, different work.
        panel.setup = AddButton(panel, "Run first-time setup", 180, function()
            local setup = CN:GetModule("Setup")

            if setup then
                setup.Run()
            end
        end, "Reads everything the client will answer for on its own. A few "
            .. "seconds, once.")

        panel.setup:SetPoint("BOTTOMLEFT", CN.SPACE.M, CN.SPACE.M + 26)

        panel.reset = AddButton(panel, "Reset window position", 180, function()
            CN.Settings().window = nil

            if window then
                window:ClearAllPoints()
                window:SetPoint("CENTER")
            end
        end, "Puts the window back in the middle of the screen.")

        panel.reset:SetPoint("BOTTOMLEFT", CN.SPACE.M, CN.SPACE.M)

        panel.debug = AddCheckbox(panel, "Debug output",
            function() return CN.Settings().debug end,
            function(value) CN.Settings().debug = value end,
            "Prints what the addon is doing internally. For bug reports.")

        panel.debug:SetPoint("BOTTOMLEFT", COLUMN, CN.SPACE.M)

        panel.about = CN.Label(panel, "ARTWORK", "SMALL")
        panel.about:SetTextColor(CN.Rgb("MUTED"))
        panel.about:SetPoint("BOTTOMRIGHT", -CN.SPACE.M, CN.SPACE.M)
        panel.about:SetJustifyH("RIGHT")
    end,

    refresh = function(panel)
        local settings = CN.Settings()

        local filters = CN:GetModule("Filters")

        local active

        if filters and filters.CurrentMode then
            active = select(2, filters.CurrentMode())
        end

        panel.focusButton:SetText(active and active.label or "None")

        -- SAYS WHAT THE FOCUS IS DOING TO THE LIST.
        --
        -- A focus hides objective types, and nothing in the window ever said
        -- how many -- so a player who picked "Collecting" at first run had
        -- thirteen kinds of thing silently missing and no way to find out
        -- from here.
        local hidden = filters and filters.HiddenTypeCount
            and filters.HiddenTypeCount() or 0

        if active then
            panel.focusNote:SetText(active.note
                .. (hidden > 0 and ("  " .. CN.DOT .. "  hiding " .. hidden
                    .. " of " .. #filters.TypeOrder() .. " kinds") or ""))
        elseif hidden > 0 then
            panel.focusNote:SetText("No focus set. " .. hidden .. " kind"
                .. CN.Pluralize(hidden, " is", "s are")
                .. " hidden by your own choices.")
        else
            panel.focusNote:SetText("No focus set: everything is in the list.")
        end

        panel.modeButton:SetText(tostring(settings.priorityMode))

        local hud = CN:GetModule("Hud")

        -- `%.2f`, not `%.2g`: two SIGNIFICANT digits render the 1.25 step as
        -- "Size 1.2" and 1.0 as "Size 1", so the button built with the
        -- literal "Size 1.0" changed its own label on the first refresh.
        panel.scale:SetText(string.format("Size %.2f",
            (hud and hud.Scale and hud.Scale()) or 1))

        panel.textSize:SetText(string.format("Text %d%%",
            math.floor(CN.TextScale() * 100 + 0.5)))

        for _, control in ipairs({ panel.learn, panel.minimap, panel.arrow,
                                   panel.pins, panel.tooltips, panel.hud,
                                   panel.cues, panel.autoWaypoint, panel.rares,
                                   panel.colourblind,
                                   panel.keepFilter, panel.debug }) do
            control.Refresh()
        end

        panel.about:SetText("Completion Navigator v" .. CN.version
            .. "  " .. CN.DOT .. "  Dam Beaver Studios, LLC")
    end,
}

------------------------------------------------------------
-- MINIMAP BUTTON
------------------------------------------------------------

local function UpdateMinimapPosition()
    if not minimapButton then
        return
    end

    local angle  = math.rad(CN.Settings().minimap.angle or 225)
    local radius = 80

    minimapButton:SetPoint("CENTER", Minimap, "CENTER",
        math.cos(angle) * radius, math.sin(angle) * radius)
end

local function BuildMinimapButton()
    if minimapButton or not Minimap then
        return minimapButton
    end

    minimapButton = CreateFrame("Button", "CompletionNavigatorMinimapButton", Minimap)

    minimapButton:SetSize(31, 31)
    minimapButton:SetFrameStrata("MEDIUM")
    minimapButton:SetFrameLevel(8)
    -- Middle-click added in 0.45.0. Three buttons, three of the things a
    -- player does most: open it, navigate, and start following.
    minimapButton:RegisterForClicks("LeftButtonUp", "RightButtonUp",
        "MiddleButtonUp")
    minimapButton:RegisterForDrag("LeftButton")
    minimapButton:SetMovable(true)

    local overlay = minimapButton:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT")

    local icon = minimapButton:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", -1, 1)

    -- Prefer the addon's own artwork. SetTexture fails silently on a missing
    -- file and leaves the texture blank, so verify it took and fall back to
    -- a stock icon rather than shipping an invisible button.
    icon:SetTexture(CN.MEDIA_PATH .. "Logo")

    if not icon:GetTexture() then
        icon:SetTexture("Interface\\Icons\\INV_Misc_Map_01")
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    else
        -- The supplied art is a circular badge already; trimming the corners
        -- keeps it round inside the minimap ring.
        icon:SetTexCoord(0.06, 0.94, 0.06, 0.94)
    end

    minimapButton:SetScript("OnClick", function(self, button)
        if button == "MiddleButton" then
            -- Follow mode is the addon's hands-free state and it was three
            -- keystrokes or a scroll through the window away. It is the thing
            -- somebody with the button on their minimap most wants one click
            -- from.
            CN.HandleSlashCommand("follow")

            return
        end

        if button == "RightButton" then
            local results = CN.Recommend(1)

            if #results > 0 then
                CN.currentRecommendation = results[1]

                local objective = results[1]

                Print("Recommended: " .. tostring(objective.name))
                CN.NavigateToObjective(objective)
            else
                Print("Nothing actionable is known yet.")
            end

            return
        end

        UI.Toggle()
    end)

    -- Drag around the minimap edge; the angle is what gets persisted.
    minimapButton:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local px, py = GetCursorPosition()
            local scale  = Minimap:GetEffectiveScale()

            px, py = px / scale, py / scale

            CN.Settings().minimap.angle = math.deg(CN.Atan2(py - my, px - mx))

            UpdateMinimapPosition()
        end)
    end)

    minimapButton:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    minimapButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Completion Navigator")

        -- The recommendation is the whole point of the addon, so put it where
        -- it costs nothing to read. This is cheap now: candidates are cached,
        -- so hovering the button does not rebuild fourteen providers.
        local ok, results = pcall(CN.Recommend, 1)

        if ok and results and results[1] then
            local objective = results[1]

            GameTooltip:AddLine("Next: " .. tostring(objective.name or objective.id),
                CN.Rgb("BRAND"))

            local reasons = CN.ExplainRecommendation(objective)

            for index, reason in ipairs(reasons) do
                if index > 2 then
                    break
                end

                GameTooltip:AddLine(reason, CN.Rgb("MUTED"))
            end
        elseif not ok then
            -- An engine that threw is not an empty list, and telling the
            -- player to run setup again when the real answer is "something
            -- broke" sends them to the wrong place.
            GameTooltip:AddLine("Something went wrong; /cn errors has it.",
                CN.Rgb("BAD"))
        else
            GameTooltip:AddLine("Nothing actionable is known yet.",
                CN.Rgb("MUTED"))

            -- The shared explanation rather than an unconditional "run
            -- setup", which was shown to players who had run it and then
            -- hidden every type with /cn show.
            for index, line in ipairs(CN.ExplainEmptyList()) do
                if index > 2 then
                    break
                end

                GameTooltip:AddLine(line, CN.Rgb("MUTED"))
            end
        end

        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("|cfff2f4f6Left-click|r open the window", 1, 1, 1)
        GameTooltip:AddLine("|cfff2f4f6Right-click|r navigate to the next objective", 1, 1, 1)
        -- Middle-click has started follow mode since 0.44.0 and the tooltip
        -- -- the feature's only discovery surface -- did not mention it.
        GameTooltip:AddLine("|cfff2f4f6Middle-click|r start follow mode", 1, 1, 1)
        GameTooltip:AddLine("|cfff2f4f6Drag|r reposition this button", 1, 1, 1)
        GameTooltip:Show()
    end)

    minimapButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    UpdateMinimapPosition()

    return minimapButton
end

function UI.UpdateMinimapButton()
    BuildMinimapButton()

    if not minimapButton then
        return
    end

    if CN.Settings().minimap.hide then
        minimapButton:Hide()
    else
        minimapButton:Show()
        UpdateMinimapPosition()
    end
end

------------------------------------------------------------
-- KEYBINDING ENTRY POINTS
------------------------------------------------------------

function CompletionNavigator_ToggleUI()
    UI.Toggle()
end

function CompletionNavigator_NextObjective()
    local handler = SlashCmdList and SlashCmdList.COMPLETIONNAVIGATOR

    if handler then
        handler("next")
    end
end

function CompletionNavigator_Navigate()
    local handler = SlashCmdList and SlashCmdList.COMPLETIONNAVIGATOR

    if handler then
        handler("go")
    end
end

-- One helper rather than three copies of the same four lines. The slash
-- handler is the single entry point every command already goes through, so a
-- binding is a keystroke that types for you.
local function RunCommand(text)
    local handler = SlashCmdList and SlashCmdList.COMPLETIONNAVIGATOR

    if handler then
        handler(text)
    end
end

function CompletionNavigator_ToggleFollow()
    RunCommand("follow")
end

function CompletionNavigator_Plan()
    -- No argument: /cn plan now defaults to however long this character
    -- usually plays, which is exactly the right behaviour for a key you press
    -- without thinking about it.
    RunCommand("plan")
end

function CompletionNavigator_ToggleHud()
    RunCommand("hud")
end

BINDING_HEADER_COMPLETIONNAVIGATOR       = "Completion Navigator"
BINDING_NAME_COMPLETIONNAVIGATOR_TOGGLE  = "Toggle window"
BINDING_NAME_COMPLETIONNAVIGATOR_NEXT    = "Recommend next objective"
BINDING_NAME_COMPLETIONNAVIGATOR_GO      = "Navigate to recommendation"
BINDING_NAME_COMPLETIONNAVIGATOR_FOLLOW  = "Start or stop follow mode"
BINDING_NAME_COMPLETIONNAVIGATOR_PLAN    = "Plan a session"
BINDING_NAME_COMPLETIONNAVIGATOR_HUD     = "Toggle the heads-up line"

------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------

CN:OnLogin(function()
    UI.UpdateMinimapButton()

    -- Say once where the interface actually is. A minimap button nobody
    -- notices is the same as no interface at all.
    local settings = CN.Settings()

    if not settings.seenWelcome then
        settings.seenWelcome = true

        Print("Click the |cffffc74fmap icon on your minimap|r to open the window, "
            .. "or type |cffffc74f/cn ui|r.")
        Print("Right-click that icon to navigate straight to the next objective.")
    end
end)

-- KEEP AN OPEN WINDOW CURRENT, FROM WHAT THE PROVIDERS ACTUALLY DECLARE.
--
-- This was a second hand-written list of six events -- the same "two lists,
-- one of which nobody checked against the other" that Scoring.lua records as
-- fixed for the invalidator, left standing here. The providers were being
-- invalidated correctly and the window simply did not redraw.
--
-- Missing from the six: every collection event, achievements, criteria,
-- currencies, bags, vignettes, lockouts and the vault. In a city, where none
-- of the six fire, that meant using a mount from your bags left "collect this
-- mount" on screen; looting a toy did the same; and DYING did not show the
-- corpse run, which is the one objective the addon weights above everything
-- else.
--
-- Asked of the registry instead, at login, when every provider has
-- registered. There is no ticker: the refresh is debounced, so a burst costs
-- one redraw.
local function SubscribeToRefreshEvents()
    local wanted = {}

    for _, event in ipairs(CN.baseInvalidationEvents or {}) do
        wanted[event] = true
    end

    for _, provider in pairs(CN.candidateProviders or {}) do
        for event in pairs(provider.events or {}) do
            wanted[event] = true
        end
    end

    -- Two the providers cannot declare, because no provider is about them:
    -- being dead changes the whole ranking through an adjuster, and the
    -- reputation renown event is what the Warband tab reads.
    wanted.PLAYER_DEAD  = true
    wanted.PLAYER_ALIVE = true
    wanted.PLAYER_UNGHOST = true
    wanted.MAJOR_FACTION_RENOWN_LEVEL_CHANGED = true

    local names = {}

    for event in pairs(wanted) do
        table.insert(names, event)
    end

    -- Sorted, so the registration order is the same on every login.
    table.sort(names)

    for _, event in ipairs(names) do
        CN:RegisterEvent(event, function()
            UI.RequestRefresh()
        end)
    end

    UI.refreshEventCount = #names

    return #names
end

UI.SubscribeToRefreshEvents = SubscribeToRefreshEvents

CN:OnLogin(function()
    SubscribeToRefreshEvents()
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------

CN:RegisterCommand{
    name    = "ui",
    -- "show" REMOVED. Filters registers `/cn show` and loads later in the
    -- .toc, so this alias was already dead -- and `/cn show` being the filter
    -- command is what the documentation says. A dead alias that reads as a
    -- live one is a collision waiting for a load-order change.
    aliases = { "window" },
    order   = 5,
    help    = "Open the main window.",
    handler = function()
        UI.Toggle()
    end,
}

CN:RegisterCommand{
    name    = "find",
    args    = "<text>",
    order   = 6,
    help    = "Find something without knowing which tab it is on.",
    handler = function(args)
        args = CN.Trim(args or "")

        if args == "" then
            Print("Usage: /cn find <text>")
            Print("|cff8a8f96Searches every tab of the window at once.|r")
            return
        end

        -- THE TABS HAVE TO HAVE BEEN BUILT TO HAVE ANYTHING IN THEM.
        --
        -- A player typing this has usually not opened the window, and a tab
        -- that has never been refreshed holds no entries -- so the search
        -- would have answered "nothing" for things the addon plainly knows.
        -- `RefreshAllTabs` builds the window itself. This used to call
        -- `UI.Frame()`, which is a pure accessor -- `return window` -- so on
        -- a fresh login it built nothing and the command answered "nothing
        -- matches" for things the addon plainly had. 0.67.0.
        UI.RefreshAllTabs()

        local hits = UI.SearchAll(args)

        if #hits == 0 then
            Print("Nothing in the window matches: " .. args)
            Print("|cff8a8f96Collections and goals are searched from what has "
                .. "been scanned; /cn scan fills them.|r")
            return
        end

        Print("Matches for |cffffc74f" .. args .. "|r:")

        for _, hit in ipairs(hits) do
            CN.PrintLine("  " .. (CN.L[hit.tab] or hit.tab) .. " |cff8a8f96("
                .. CN.Count(hit.count, "match", "matches") .. ")|r"
                .. (hit.first and (" " .. CN.DASH .. " " .. hit.first) or ""))
        end

        Print("|cff8a8f96/cn ui to open the window; the filter box now says "
            .. "which other tabs match too.|r")
    end,
}

CN:RegisterCommand{
    name    = "uistatus",
    order   = 7,
    help    = "Diagnose the window and minimap button.",
    handler = function()
        -- `UI.Frame()`, not the global. The global is published by the client
        -- when the frame is NAMED, and this addon creates it through
        -- `SafeCreateFrame`, which falls back to an unnamed frame if the
        -- template is missing -- exactly the case a diagnostic exists for.
        -- So the one command whose job is "tell me whether the window got
        -- built" reported "not created" for a window that was created and
        -- working.
        local frame = UI.Frame()

        -- ONE ANSWER, ONE IDENTITY.
        --
        -- Twelve `Print` calls, several of them hand-indented with two
        -- spaces, so this produced "Completion Navigator:   named: true" --
        -- and Core.lua cites this exact command by name as the reason
        -- `CN.PrintLine` exists.
        local lines = {}

        table.insert(lines, "Window object: "
            .. (frame and CN.Good("created") or CN.Bad("not created")))

        if frame then
            table.insert(lines, "  named: " .. CN.YesNo(CompletionNavigatorFrame ~= nil))
            table.insert(lines, "  shown: " .. CN.YesNo(frame:IsShown()))
            table.insert(lines, "  size: " .. math.floor(frame:GetWidth() or 0)
                .. " x " .. math.floor(frame:GetHeight() or 0) .. " px")
            table.insert(lines, "  strata: " .. tostring(frame:GetFrameStrata()))

            local point, _, _, x, y = frame:GetPoint()

            table.insert(lines, "  anchored: " .. tostring(point)
                .. " at " .. math.floor(x or 0) .. ", " .. math.floor(y or 0))
        end

        table.insert(lines, "Minimap button: "
            .. (CompletionNavigatorMinimapButton
                and CN.Good("created") or CN.Bad("not created")))

        if CompletionNavigatorMinimapButton then
            table.insert(lines, "  shown: "
                .. CN.YesNo(CompletionNavigatorMinimapButton:IsShown()))
            table.insert(lines, "  hidden by setting: "
                .. CN.YesNo(CN.Settings().minimap.hide))
            table.insert(lines, "  angle: "
                .. string.format("%.2f rad", CN.Settings().minimap.angle or 0))
        end

        table.insert(lines, "Registered tabs: " .. #UI.tabs)
        table.insert(lines, "Minimap frame exists: " .. CN.YesNo(Minimap ~= nil))

        if frame and not frame:IsShown() then
            table.insert(lines, CN.Accent("Forcing the window open and centering it."))

            CN.Settings().window = nil

            frame:ClearAllPoints()
            frame:SetPoint("CENTER")
            frame:Show()
        end

        CN.PrintBlock("UI diagnostics:", lines)
    end,
}

CN:RegisterCommand{
    name    = "minimap",
    order   = 6,
    help    = "Toggle the minimap button.",
    handler = function()
        local settings = CN.Settings()

        settings.minimap.hide = not settings.minimap.hide

        UI.UpdateMinimapButton()

        Print("Minimap button " .. (settings.minimap.hide and "hidden." or "shown."))
    end,
}
