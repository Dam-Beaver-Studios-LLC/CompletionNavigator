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
    Goals       = "/cn goal <type> <name>  Â·  /cn chase  Â·  /cn gogoal",
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
local function AttachTooltip(frame, tooltip)
    if not frame or not tooltip or not GameTooltip then
        return
    end

    frame:SetScript("OnEnter", function(hovered)
        GameTooltip:SetOwner(hovered, "ANCHOR_RIGHT")
        GameTooltip:SetText(tooltip, 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)

    frame:SetScript("OnLeave", function()
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

        local label = button:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        label:SetPoint("CENTER")
        button:SetFontString(label)

        local highlight = button:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetAllPoints()
        highlight:SetColorTexture(1, 1, 1, 0.12)
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
    else
        local label = check:CreateFontString(nil, "ARTWORK", "GameFontHighlightLeft")
        label:SetPoint("LEFT", check, "RIGHT", 2, 0)
        label:SetText(text)
        check.Text = label
    end

    check:SetScript("OnClick", function(self)
        setter(self:GetChecked() and true or false)
    end)

    check.Refresh = function()
        check:SetChecked(getter() and true or false)
    end

    AttachTooltip(check, tooltip)

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

        local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("LEFT", 10, 0)
        -- The fallback title, which must say the same thing as the
        -- templated one above -- these were two separate literals and could
        -- silently drift.
        title:SetText("Completion Navigator "
            .. CN.Muted("v" .. tostring(CN.version)))

        local close = CreateFrame("Button", nil, window)
        close:SetSize(22, 22)
        close:SetPoint("TOPRIGHT", -3, -2)

        local closeLabel = close:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
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

    local searchLabel = window:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    searchLabel:SetPoint("RIGHT", search, "LEFT", -6, 0)
    searchLabel:SetText("filter")

    search:SetScript("OnTextChanged", function(self)
        UI.SetFilter(self:GetText())
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

    window.search = search

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
    window.footer = window:CreateFontString(nil, "ARTWORK", CN.FONT.SMALL)
    window.footer:SetTextColor(CN.Rgb("MUTED"))
    window.footer:SetPoint("BOTTOMLEFT", 14, 14)
    window.footer:SetPoint("BOTTOMRIGHT", -14, 14)
    window.footer:SetJustifyH("LEFT")
    window.footer:SetText("/cn help for the full command list")

    UI.RebuildTabs()

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

    UI.SelectTab(UI.selectedTab
        or (CN.Settings() and CN.Settings().selectedTab)
        or 1)
end

function UI.SelectTab(index)
    local tab = UI.tabs[index]

    if not tab or not window then
        return
    end

    UI.selectedTab = index

    -- Persisted, so the window reopens where it was left. It always opened on
    -- the first tab, which for a player who lives in Collections meant one
    -- extra click every single time.
    if CN.Settings() then
        CN.Settings().selectedTab = index
    end

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

    for _, other in ipairs(UI.tabs) do
        if other.panel then
            other.panel:Hide()
        end
    end

    if not tab.panel then
        tab.panel = CreateFrame("Frame", nil, window.body)
        tab.panel:SetAllPoints()

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
    end

    tab.panel:Show()

    -- Now that the panel exists, the filter has something to apply to.
    UI.RestoreFilter()

    UI.Refresh()
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

function UI.SetFilter(text)
    local tab = UI.tabs[UI.selectedTab or 1]

    local panel = tab and tab.panel

    if panel and panel.list and panel.list.SetFilter then
        panel.list:SetFilter(text)
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
local lastRefresh = 0

function UI.RequestRefresh()
    if not window or not window:IsShown() then
        return
    end

    local now = time()

    if now - lastRefresh < 2 then
        return
    end

    lastRefresh = now

    UI.Refresh()
end

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

function UI.Show()
    BuildWindow()
    UI.RestorePosition()
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
        panel.title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
        panel.title:SetPoint("TOPLEFT", 8, -8)
        panel.title:SetPoint("TOPRIGHT", -8, -8)
        panel.title:SetJustifyH("LEFT")

        panel.type = panel:CreateFontString(nil, "ARTWORK", "GameFontDisable")
        panel.type:SetPoint("TOPLEFT", panel.title, "BOTTOMLEFT", 0, -2)

        panel.why = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightLeft")
        panel.why:SetPoint("TOPLEFT", panel.type, "BOTTOMLEFT", 0, -12)
        panel.why:SetPoint("RIGHT", -8, 0)
        panel.why:SetJustifyH("LEFT")
        panel.why:SetJustifyV("TOP")

        panel.navigate = AddButton(panel, "Navigate", 110, function()
            local objective = CN.currentRecommendation

            if not objective then
                return
            end

            CN.NavigateToObjective(objective)
        end)
        panel.navigate:SetPoint("BOTTOMLEFT", 8, 8)

        panel.skip = AddButton(panel, "Defer 1 hour", 110, function()
            local objective = CN.currentRecommendation

            if not objective then
                return
            end

            CN.SetDeferred(objective.type, objective.id, 3600)
            Print("Deferred: " .. tostring(objective.name))
            UI.Refresh()
        end)
        panel.skip:SetPoint("LEFT", panel.navigate, "RIGHT", 6, 0)

        panel.ignore = AddButton(panel, "Ignore", 110, function()
            local objective = CN.currentRecommendation

            if not objective then
                return
            end

            CN.SetIgnored(objective.type, objective.id, true)
            Print("Ignored: " .. tostring(objective.name))
            UI.Refresh()
        end)
        panel.ignore:SetPoint("LEFT", panel.skip, "RIGHT", 6, 0)

        -- Type filter. A dropdown would need a menu library; a button that
        -- opens a scrollable checklist in the same list widget the rest of the
        -- window uses costs nothing extra and behaves identically everywhere.
        panel.filter = AddButton(panel, "Filter types", 110, function()
            panel.filtering = not panel.filtering
            UI.Refresh()
        end)
        panel.filter:SetPoint("LEFT", panel.ignore, "RIGHT", 6, 0)

        panel.list = UI.CreateList(panel)
        panel.list:ClearAllPoints()
        panel.list:SetPoint("TOPLEFT", panel.why, "BOTTOMLEFT", -4, -14)
        panel.list:SetPoint("BOTTOMRIGHT", -8, 38)
    end,

    refresh = function(panel)
        local filters = CN:GetModule("Filters")

        -- Filter mode takes over the list. The recommendation itself stays
        -- visible above it, so you can see what changed as you toggle.
        if panel.filtering and filters then
            local hidden = filters.HiddenTypeCount()

            panel.filter:SetText("Done")

            panel.title:SetText("Show which types?")
            panel.type:SetText(hidden == 0 and "showing everything"
                or (hidden .. " type" .. (hidden == 1 and "" or "s") .. " hidden"))
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

                    tooltip = filters.TypeLabel(objectiveType)
                        .. (enabled and "\nShown in recommendations."
                            or "\nHidden from recommendations."),

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

        local results = CN.Recommend(12)

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

        CN.currentRecommendation = best

        panel.title:SetText(tostring(best.name or best.id))
        panel.type:SetText(CN.TypeBadge(best.type))
        panel.why:SetText("Why:\n" .. table.concat(CN.ExplainRecommendation(best), "\n"))

        local entries = {}

        for index = 2, #results do
            local objective = results[index]

            table.insert(entries, {
                text = string.format("|cff8a8f96%2d.|r %s |cff8a8f96[%s]|r",
                    index, tostring(objective.name or objective.id),
                    CN.TypeBadge(objective.type)),

                tooltip = table.concat(CN.ExplainRecommendation(objective), "\n"),

                onClick = function()
                    CN.currentRecommendation = objective

                    panel.title:SetText(tostring(objective.name or objective.id))
                    panel.type:SetText(CN.TypeBadge(objective.type))
                    panel.why:SetText("Why:\n"
                        .. table.concat(CN.ExplainRecommendation(objective), "\n"))
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
        panel.header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        panel.header:SetPoint("TOPLEFT", 8, -8)
        panel.header:SetPoint("TOPRIGHT", -8, -8)
        panel.header:SetJustifyH("LEFT")

        panel.list = UI.CreateList(panel)
        panel.list:ClearAllPoints()
        panel.list:SetPoint("TOPLEFT", 4, -32)
        panel.list:SetPoint("BOTTOMRIGHT", -8, 38)

        panel.route = AddButton(panel, "Re-route", 110, function()
            UI.Refresh()
        end)
        panel.route:SetPoint("BOTTOMLEFT", 8, 8)

        panel.clear = AddButton(panel, "Clear waypoints", 130, function()
            CN.ClearWaypoints()
        end)
        panel.clear:SetPoint("LEFT", panel.route, "RIGHT", 6, 0)
    end,

    refresh = function(panel)
        local mapID, x, y = CN.GetPlayerPosition()

        if not mapID then
            panel.header:SetText("Current map unknown.")
            panel.list:SetEntries({})
            return
        end

        local zoneName = CN.Blizzard.GetMapName(mapID) or "This zone"

        local route, skipped = CN.BuildZoneRoute(mapID, x, y)

        local counts, order = CN.SummarizeZone(route, skipped)

        local parts = {}

        for _, key in ipairs(order) do
            table.insert(parts, counts[key] .. " " .. string.lower(key))
        end

        if #parts == 0 then
            panel.header:SetText(zoneName .. " - nothing actionable is known here.")
        else
            panel.header:SetText(zoneName .. " - remaining: " .. table.concat(parts, ", "))
        end

        local entries = {}

        for index, objective in ipairs(route) do
            table.insert(entries, {
                text = string.format("|cff8a8f96%2d.|r %s |cff8a8f96[%s]|r",
                    index, tostring(objective.name or objective.id),
                    CN.TypeBadge(objective.type)),

                tooltip = "Click to set a waypoint.\n"
                    .. table.concat(CN.ExplainRecommendation(objective), "\n"),

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

UI.RegisterTab{
    name  = "Scans",
    order = 30,

    build = function(panel)
        panel.status = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightLeft")
        panel.status:SetPoint("TOPLEFT", 8, -8)
        panel.status:SetPoint("RIGHT", -8, 0)
        panel.status:SetJustifyH("LEFT")
        panel.status:SetJustifyV("TOP")

        local quests = AddButton(panel, "Scan quests", 130, function()
            local module = CN:GetModule("Quests")

            if module then
                local seen, recorded = module.DiscoverActive()
                local scanned        = module.ScanKnown()

                Print("Quests: " .. seen .. " in your log, "
                    .. "|cffffc74f" .. module.AvailableCount() .. "|r "
                    .. "available to pick up nearby.")

                CN.DebugPrint(recorded .. " newly recorded, "
                    .. scanned .. " checked.")
            end

            UI.Refresh()
        end)
        quests:SetPoint("BOTTOMLEFT", 8, 8)

        local reps = AddButton(panel, "Scan reputations", 150, function()
            local module = CN:GetModule("Reputations")

            if module then
                local total = module.Scan()

                Print("Reputation scan: " .. total .. " factions.")
            end

            UI.Refresh()
        end)
        reps:SetPoint("LEFT", quests, "RIGHT", 6, 0)
    end,

    refresh = function(panel)
        local lines = {}

        -- What is true of the player's world first; what is true of the
        -- addon's database second, and marked as such. The order matters:
        -- a player reads the top line and stops.
        local questModule = CN:GetModule("Quests")

        table.insert(lines, "|cffffc74fQuests|r")

        -- The number he actually wanted back, first.
        local progressModule = CN:GetModule("Progress")

        if progressModule then
            local summary = progressModule.Summary()

            if summary.lifetime then
                table.insert(lines, "Completed: |cffffc74f"
                    .. CN.Comma(summary.lifetime) .. "|r")
            end

            local todayLine = "Today: |cffffc74f" .. summary.today .. "|r"

            if summary.best > 0 then
                todayLine = todayLine .. "   |cff8a8f96best "
                    .. summary.best .. "|r"
            end

            table.insert(lines, todayLine)
        end

        if questModule then
            local available = questModule.AvailableCount()

            table.insert(lines, "Available to pick up nearby: "
                .. (available > 0 and "|cffffc74f" or "|cff8a8f96")
                .. available .. "|r")
            table.insert(lines, "In your log: " .. #CN.Blizzard.GetQuestLogEntries())
        end

        table.insert(lines, "|cff8a8f96Database: "
            .. CN.CountKeys(CN.Account("discoveredQuests")) .. " known, "
            .. CN.CountKeys(CN.Account("questMetadata")) .. " named|r")
        table.insert(lines, " ")

        local reputations = CN:GetModule("Reputations")

        if reputations then
            local counts = reputations.Summary()

            table.insert(lines, "|cffffc74fReputations|r")
            table.insert(lines, "Account-wide: " .. counts.account)
            table.insert(lines, "Character-specific: " .. counts.character)
            table.insert(lines, "Renown: " .. counts.renown
                .. " (" .. counts.maxedRenown .. " maxed)")
            table.insert(lines, "Exalted: " .. counts.exalted)

            if counts.paragonPending > 0 then
                table.insert(lines, "|cff73b873Paragon rewards waiting: "
                    .. counts.paragonPending .. "|r")
            end

            table.insert(lines, " ")
        end

        table.insert(lines, "|cffffc74fWarband|r")
        table.insert(lines, "Known characters: " .. CN.GetCharacterCount())

        panel.status:SetText(table.concat(lines, "\n"))
    end,
}

------------------------------------------------------------
-- TAB: NOW
------------------------------------------------------------

-- Everything with a clock on it, in one place. Nothing added since 0.9 was
-- reachable without typing, which broke the rule this file opens with.
UI.RegisterTab{
    name  = "Now",
    order = 15,

    build = function(panel)
        panel.header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        panel.header:SetPoint("TOPLEFT", 8, -8)
        panel.header:SetPoint("TOPRIGHT", -8, -8)
        panel.header:SetJustifyH("LEFT")

        panel.list = UI.CreateList(panel)
        panel.list:ClearAllPoints()
        panel.list:SetPoint("TOPLEFT", 4, -32)
        panel.list:SetPoint("BOTTOMRIGHT", -8, 38)

        panel.refresh = AddButton(panel, "Refresh", 110, function()
            UI.Refresh()
        end)
        panel.refresh:SetPoint("BOTTOMLEFT", 8, 8)

        panel.scanCurrency = AddButton(panel, "Rescan currencies", 150, function()
            local module = CN:GetModule("Currencies")

            if module then
                module.Scan()
            end

            UI.Refresh()
        end)
        panel.scanCurrency:SetPoint("LEFT", panel.refresh, "RIGHT", 6, 0)
    end,

    refresh = function(panel)
        local entries = {}

        local opportunities = CN:GetModule("Opportunities")

        if opportunities then
            local resets = opportunities.GetResets()

            local parts = {}

            if resets.daily then
                table.insert(parts, "daily in " .. opportunities.FormatTimeLeft(resets.daily))
            end

            if resets.weekly then
                table.insert(parts, "weekly in " .. opportunities.FormatTimeLeft(resets.weekly))
            end

            if #parts > 0 then
                panel.header:SetText("Resets: " .. table.concat(parts, ", "))
            else
                panel.header:SetText("Expiring soon")
            end

            for _, event in ipairs(opportunities.GetActiveEvents()) do
                table.insert(entries, {
                    text = "|cffffc74fEVENT|r  " .. tostring(event.title),
                })
            end

            local worldQuests = opportunities.GetWorldQuests()

            for _, worldQuest in ipairs(worldQuests) do
                table.insert(entries, {
                    text = string.format("|cff5dd2fbWQ|r     %s  |cff8a8f96%s%s|r",
                        tostring(worldQuest.name),
                        opportunities.FormatTimeLeft(worldQuest.secondsLeft),
                        worldQuest.tagName and (", " .. worldQuest.tagName) or ""),

                    tooltip = "Click to set a waypoint.",

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
                    text = string.format("|cffffc74f%s|r  %s",
                        vignette.kind == "TREASURE" and "CHEST " or "RARE  ",
                        tostring(vignette.name)),

                    tooltip = "Up right now. Click to set a waypoint.",

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
                    text = "|cffe2564cCAP|r    " .. tostring(currency.name)
                        .. " |cff8a8f96" .. currency.quantity
                        .. " / " .. currency.maximum .. " -- spend it|r",
                })
            end

            for _, currency in ipairs(currencies.WeeklyUnfilled()) do
                table.insert(entries, {
                    text = "|cff8a8f96WEEK|r   " .. tostring(currency.name)
                        .. " |cff8a8f96" .. currency.remaining .. " left this week|r",
                })
            end
        end

        if #entries == 0 then
            table.insert(entries, { text = "Nothing is expiring nearby." })
            table.insert(entries, {
                text = "|cff8a8f96World quests and rares only appear for your current map.|r",
            })
        end

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
        panel.header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        panel.header:SetPoint("TOPLEFT", 8, -8)
        panel.header:SetPoint("TOPRIGHT", -8, -8)
        panel.header:SetJustifyH("LEFT")

        panel.list = UI.CreateList(panel)
        panel.list:ClearAllPoints()
        panel.list:SetPoint("TOPLEFT", 4, -32)
        panel.list:SetPoint("BOTTOMRIGHT", -8, 38)

        panel.note = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
        panel.note:SetPoint("BOTTOMLEFT", 12, 12)
        panel.note:SetPoint("RIGHT", -12, 0)
        panel.note:SetJustifyH("LEFT")
    end,

    refresh = function(panel)
        local module = CN:GetModule("Warband")

        if not module then
            panel.header:SetText("Warband module not loaded.")
            panel.list:SetEntries({})
            return
        end

        local rows     = module.Roster()
        local coverage = module.Coverage()

        panel.header:SetText(string.format(
            "%d character%s  |cff8a8f96combined: %d professions, %d recipes, %d titles|r",
            #rows, #rows == 1 and "" or "s",
            coverage.professions, coverage.recipes, coverage.titles))

        local entries = {}

        for _, row in ipairs(rows) do
            table.insert(entries, {
                -- `selected` is a texture on the row since 0.54.0; it used to
                -- be a green ">" prepended to the label, which shifted every
                -- other row's text by two glyphs.
                selected = row.isCurrent and true or false,

                text = row.key
                    .. CN.Aside(tostring(row.level) .. " "
                        .. tostring(row.class or "?")
                        .. (row.faction and (" " .. row.faction) or "")),

                tooltip = string.format(
                    "professions %d\nrecipes %d\ntitles %d\nreputations %d",
                    row.professions, row.recipes, row.titles, row.reputations),
            })

            table.insert(entries, {
                text = "      |cff8a8f96professions " .. row.professions
                    .. ", recipes " .. row.recipes
                    .. ", titles " .. row.titles
                    .. ", reputations " .. row.reputations .. "|r",
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
        panel.header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        panel.header:SetPoint("TOPLEFT", 8, -8)
        panel.header:SetPoint("TOPRIGHT", -8, -8)
        panel.header:SetJustifyH("LEFT")

        panel.list = UI.CreateList(panel)
        panel.list:ClearAllPoints()
        panel.list:SetPoint("TOPLEFT", 4, -32)
        panel.list:SetPoint("BOTTOMRIGHT", -8, 38)

        panel.note = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
        panel.note:SetPoint("BOTTOMLEFT", 12, 12)
        panel.note:SetPoint("RIGHT", -12, 0)
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
            .. (summary.unlocked == 1 and "" or "s") .. " unlocked"
            .. (summary.resetsIn and ("  |cff8a8f96resets in "
                .. vault.FormatReset(summary.resetsIn) .. "|r") or ""))

        local entries = {}

        if summary.claimable then
            table.insert(entries, {
                text = "|cff73b873A reward is waiting to be collected.|r",
            })
        end

        for _, row in ipairs(rows) do
            table.insert(entries, {
                text = "  " .. vault.DescribeRow(row),

                tooltip = row.label .. "\n"
                    .. (row.capped
                        and "Every threshold met."
                        or ((vault.rowActions[row.row] or "") .. "\n"
                            .. row.remaining .. " more for the next reward.")),
            })

            for _, tier in ipairs(row.tiers) do
                table.insert(entries, {
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
                .. " -- " .. summary.closest.remaining .. " more, "
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
        panel.header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        panel.header:SetPoint("TOPLEFT", 8, -8)
        panel.header:SetPoint("TOPRIGHT", -8, -8)
        panel.header:SetJustifyH("LEFT")

        panel.list = UI.CreateList(panel)
        panel.list:ClearAllPoints()
        panel.list:SetPoint("TOPLEFT", 4, -32)
        panel.list:SetPoint("BOTTOMRIGHT", -8, 64)

        -- "Next step", not "Navigate". They are different destinations and
        -- the difference is the point: the mount is behind a dungeon you
        -- cannot enter, but the attunement quest is forty yards away.
        panel.navigate = AddButton(panel, "Next step", 110, function()
            local chase = CN:GetModule("Chase")

            if not chase or not panel.selected then
                return
            end

            chase.NavigateNext(chase.Chain(panel.selected))
        end)
        panel.navigate:SetPoint("BOTTOMLEFT", 8, 34)

        panel.remove = AddButton(panel, "Remove goal", 110, function()
            local goals = CN:GetModule("Goals")

            if not goals or not panel.selected then
                return
            end

            goals.Remove(panel.selected.type, panel.selected.id)

            panel.selected = nil

            UI.Refresh()
        end)
        panel.remove:SetPoint("LEFT", panel.navigate, "RIGHT", 6, 0)

        panel.note = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
        panel.note:SetPoint("BOTTOMLEFT", 12, 12)
        panel.note:SetPoint("RIGHT", -12, 0)
        panel.note:SetJustifyH("LEFT")
    end,

    refresh = function(panel)
        local goals = CN:GetModule("Goals")

        if not goals then
            panel.header:SetText("Goals module not loaded.")
            panel.list:SetEntries({})
            return
        end

        local list = goals.List()

        panel.header:SetText(#list .. " goal" .. (#list == 1 and "" or "s")
            .. " |cff8a8f96of " .. goals.limit .. "|r")

        if #list == 0 then
            panel.list:SetEntries({})
            panel.note:SetText("|cffffc74fNothing pinned. Use |r/cn goal <type> <id>|cffffc74f "
                .. "to pin something to work toward. A goal becomes actionable even "
                .. "when nothing else would surface it, and anything leading to it "
                .. "ranks higher.|r")
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
                panel.selected = nil
            end
        end

        panel.selected = panel.selected or list[1]

        local chase = CN:GetModule("Chase")

        local entries = {}

        -- Step colours by state. The player should be able to find the one
        -- actionable line without reading any of the others.
        local stateColor = {
            DONE    = "|cff73b873",
            NEXT    = "|cff5dd2fb",
            BLOCKED = "|cffe2564c",
            TODO    = "|cffc8ccd2",
            NOTE    = "|cff8a8f96",
        }

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
                progressText = CN.Brand(string.format("%d%%",
                    math.floor(fraction * 100 + 0.5)))
            end

            table.insert(entries, {
                selected = isSelected,

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
                            text = "      |cff8a8f96... and "
                                .. (#chain.steps - shown) .. " more|r",
                        })
                        break
                    end

                    local colour = stateColor[step.state] or "|cffc8ccd2"

                    local marker = "  "

                    if step.state == "DONE" then
                        marker = "x "
                    elseif step.state == "NEXT" then
                        marker = "> "
                    end

                    table.insert(entries, {
                        text = "      " .. colour .. marker .. step.text .. "|r",
                    })

                    shown = shown + 1
                end

                if chain.character then
                    table.insert(entries, {
                        text = "      |cff8a8f96Best character: "
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
        panel.header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
        panel.header:SetPoint("TOPLEFT", 8, -8)
        panel.header:SetPoint("TOPRIGHT", -8, -8)
        panel.header:SetJustifyH("LEFT")

        panel.sub = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        panel.sub:SetPoint("TOPLEFT", panel.header, "BOTTOMLEFT", 0, -4)
        panel.sub:SetJustifyH("LEFT")

        panel.list = UI.CreateList(panel)
        panel.list:ClearAllPoints()
        panel.list:SetPoint("TOPLEFT", 4, -52)
        panel.list:SetPoint("BOTTOMRIGHT", -8, 40)

        panel.follow = AddButton(panel, "Follow the route", 150, function()
            local follow = CN:GetModule("Follow")

            if follow then
                follow.Toggle()
            end

            UI.Refresh()
        end)
        panel.follow:SetPoint("BOTTOMLEFT", 8, 10)

        -- The three session lengths people actually have. A text field
        -- asking for a number would be more general and less used.
        panel.plan30 = AddButton(panel, "30 min", 70, function()
            CN.HandleSlashCommand("plan 30")
        end)
        panel.plan30:SetPoint("BOTTOMRIGHT", -8, 10)

        panel.plan60 = AddButton(panel, "1 hour", 70, function()
            CN.HandleSlashCommand("plan 60")
        end)
        panel.plan60:SetPoint("RIGHT", panel.plan30, "LEFT", -4, 0)

        panel.rescan = AddButton(panel, "Rescan zones", 130, function()
            local lore = CN:GetModule("Loremaster")

            if lore then
                lore.Scan()
            end

            UI.Refresh()
        end)
        panel.rescan:SetPoint("LEFT", panel.follow, "RIGHT", 6, 0)
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
                local bar = ""

                if (zone.criteria or 0) > 0 then
                    bar = " |cff5dd2fb"
                        .. CN.ProgressBar(zone.done / zone.criteria, 16)
                        .. "|r " .. zone.done .. "/" .. zone.criteria
                end

                table.insert(entries, {
                    text = "|cffffc74fHere|r  " .. tostring(zone.name) .. bar,
                })
            end

            local split = lore.SplitZoneWork()

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
                table.insert(entries, { text = "|cffffc74fClosest to finished|r" })

                for _, entry in ipairs(closest) do
                    table.insert(entries, {
                        text = "  |cffffc74f" .. tostring(entry.name) .. "|r"
                            .. " |cff5dd2fb"
                            .. CN.ProgressBar(entry.fraction, 14) .. "|r "
                            .. entry.done .. "/" .. entry.criteria,

                        tooltip = tostring(entry.category or ""),
                    })
                end
            end
        end

        if #entries == 0 then
            table.insert(entries, {
                text = "|cff8a8f96No zone achievements scanned yet. "
                    .. "Press Rescan zones.|r",
            })
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
        panel.header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        panel.header:SetPoint("TOPLEFT", 8, -8)
        panel.header:SetPoint("TOPRIGHT", -8, -8)
        panel.header:SetJustifyH("LEFT")

        panel.list = UI.CreateList(panel)
        panel.list:ClearAllPoints()
        panel.list:SetPoint("TOPLEFT", 4, -32)
        panel.list:SetPoint("BOTTOMRIGHT", -8, 38)

        panel.refresh = AddButton(panel, "Refresh", 110, function()
            UI.Refresh()
        end)
        panel.refresh:SetPoint("BOTTOMLEFT", 8, 8)
    end,

    refresh = function(panel)
        local module = CN:GetModule("Breakdown")

        if not module then
            panel.header:SetText("Breakdown module not loaded.")
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
                    .. "  " .. CN.Muted(string.format("%.1f%%", fraction * 100))
            else
                value = CN.Body((row.collected or 0) .. " collected")
            end

            table.insert(entries, {
                text     = headline,
                value    = value,
                fraction = fraction,
                tooltip  = row.unknownTotal
                    and ("No percentage is shown because " .. row.unknownTotal .. ".")
                    or nil,
            })

            if row.unknownTotal then
                table.insert(entries, {
                    text = "      " .. CN.Muted("no percentage: "
                        .. row.unknownTotal),
                })
            end

            for _, reason in ipairs(row.reasons or {}) do
                table.insert(entries, { text = "      " .. reason })
            end

            if row.action then
                table.insert(entries, {
                    text = "      |cffffc74f-> " .. row.action .. "|r",
                })
            end
        end

        if #entries == 0 then
            table.insert(entries, { text = "Nothing to report yet. Run the scans first." })
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
        panel.header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        panel.header:SetPoint("TOPLEFT", 8, -8)
        panel.header:SetPoint("TOPRIGHT", -8, -8)
        panel.header:SetJustifyH("LEFT")

        panel.list = UI.CreateList(panel)
        panel.list:ClearAllPoints()
        panel.list:SetPoint("TOPLEFT", 4, -32)
        panel.list:SetPoint("BOTTOMRIGHT", -8, 38)

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
                work()

                button:SetText(label)
                button:SetEnabled(true)

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

                Print("Read " .. scanned .. " collections.")
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

                Print("Read " .. CN.Comma(scanned) .. " achievements, "
                    .. CN.Comma(completed) .. " of them done.")
            end)
        end, "Read the achievement tree, so the addon can say which ones you "
            .. "are close to finishing.")

        panel.achieve:SetPoint("LEFT", panel.scanAll, "RIGHT", CN.SPACE.S, 0)
    end,

    refresh = function(panel)
        local entries = {}

        local function row(label, collected, total, note)
            if total and total > 0 then
                local fraction = collected / total

                table.insert(entries, {
                    text     = label,
                    value    = CN.Body(collected .. " / " .. total) .. "  "
                        .. CN.Muted(string.format("%.1f%%", fraction * 100)),
                    fraction = fraction,
                })
            else
                table.insert(entries, {
                    text  = label,
                    value = CN.Muted(note or "not scanned"),
                })
            end
        end

        local pets = CN:GetModule("Pets")

        if pets then
            local counts = pets.Summary()
            row("Pets", counts.collected, counts.known)
        end

        local mounts = CN:GetModule("Mounts")

        if mounts then
            local counts = mounts.Summary()
            row("Mounts", counts.collected, counts.known)
        end

        local toys = CN:GetModule("Toys")

        if toys then
            local counts = toys.Summary()
            row("Toys", counts.collected, counts.known)
        end

        local appearances = CN:GetModule("Appearances")

        if appearances then
            local counts = appearances.Summary()
            row("Appearances", counts.collected, counts.total)
        end

        local titles = CN:GetModule("Titles")

        if titles then
            local counts = titles.Summary()
            row("Titles", counts.onAccount, counts.known)
        end

        local achievements = CN:GetModule("Achievements")

        if achievements then
            local counts = achievements.Summary()
            row("Achievements", counts.completed, counts.total)
        end

        local reputations = CN:GetModule("Reputations")

        if reputations then
            local counts = reputations.Summary()

            table.insert(entries, {
                text  = "Reputations",
                value = CN.Body(counts.account) .. CN.Muted(" account-wide")
                    .. CN.Muted(", ") .. CN.Body(counts.character)
                    .. CN.Muted(" this character"),
            })
        end

        table.insert(entries, { text = " " })

        local quests = CN:GetModule("Quests")

        if quests then
            table.insert(entries, {
                text  = "Quests",
                value = CN.Body(CN.CountKeys(CN.Account("discoveredQuests")))
                    .. CN.Muted(" discovered"),
            })
        end

        local professions = CN:GetModule("Professions")

        if professions then
            for _, record in ipairs(professions.Summary()) do
                local note = record.recipesSeen
                    and CN.Muted(record.recipeKnown .. " of "
                        .. record.recipeTotal .. " recipes")
                    or CN.Accent("open its window once")

                table.insert(entries, {
                    text  = record.name or "?",
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
            .. "known at the last scan -- not of everything in the game)|r")
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
            local head = panel:CreateFontString(nil, "ARTWORK", CN.FONT.HEAD)

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

        panel.focusClear:SetPoint("LEFT", panel.focusButton, "RIGHT", CN.SPACE.S, 0)

        panel.focusNote = panel:CreateFontString(nil, "ARTWORK", CN.FONT.SMALL)
        panel.focusNote:SetTextColor(CN.Rgb("MUTED"))
        panel.focusNote:SetWidth(COLUMN - CN.SPACE.M)
        panel.focusNote:SetJustifyH("LEFT")
        Under(panel.focusNote, panel.focusButton, CN.SPACE.XS)

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

            CN.InvalidateCandidates("mode")

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
            "Only where there is something to say -- most items have nothing.")

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

        ------------------------------------------------------------
        -- ACCESSIBILITY -- BOTH OF THESE WERE SLASH-ONLY.
        ------------------------------------------------------------
        panel.accessHead = Heading("Easier to read", panel.cues)

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
        end, "How large everything this addon draws is -- the window, the "
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

        Under(panel.keepFilter, panel.colourblind, CN.SPACE.XS)

        ------------------------------------------------------------
        -- THE REST
        ------------------------------------------------------------
        panel.setup = AddButton(panel, "Scan everything now", 180, function()
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

        panel.about = panel:CreateFontString(nil, "ARTWORK", CN.FONT.SMALL)
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
                .. (hidden == 1 and " is" or "s are")
                .. " hidden by your own choices.")
        else
            panel.focusNote:SetText("No focus set: everything is in the list.")
        end

        panel.modeButton:SetText(tostring(settings.priorityMode))

        local hud = CN:GetModule("Hud")

        panel.scale:SetText(string.format("Size %.2g",
            (hud and hud.Scale and hud.Scale()) or 1))

        for _, control in ipairs({ panel.learn, panel.minimap, panel.arrow,
                                   panel.pins, panel.tooltips, panel.hud,
                                   panel.cues, panel.colourblind,
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
                0.2, 1.0, 0.6)

            local reasons = CN.ExplainRecommendation(objective)

            for index, reason in ipairs(reasons) do
                if index > 2 then
                    break
                end

                GameTooltip:AddLine(reason, 0.6, 0.6, 0.6)
            end
        elseif not ok then
            -- An engine that threw is not an empty list, and telling the
            -- player to run setup again when the real answer is "something
            -- broke" sends them to the wrong place.
            GameTooltip:AddLine("Something went wrong; /cn errors has it.",
                0.96, 0.42, 0.38)
        else
            GameTooltip:AddLine("Nothing actionable is known yet.", 0.6, 0.6, 0.6)

            -- The shared explanation rather than an unconditional "run
            -- setup", which was shown to players who had run it and then
            -- hidden every type with /cn show.
            for index, line in ipairs(CN.ExplainEmptyList()) do
                if index > 2 then
                    break
                end

                GameTooltip:AddLine(line, 0.6, 0.6, 0.6)
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

-- Keep an open window current without polling.
for _, event in ipairs({
    "QUEST_TURNED_IN",
    "QUEST_ACCEPTED",
    "QUEST_REMOVED",
    "UPDATE_FACTION",
    "ZONE_CHANGED_NEW_AREA",
    "MAJOR_FACTION_RENOWN_LEVEL_CHANGED",
}) do
    CN:RegisterEvent(event, function()
        UI.RequestRefresh()
    end)
end

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
    name    = "uistatus",
    order   = 7,
    help    = "Diagnose the window and minimap button.",
    handler = function()
        Print("UI diagnostics:")
        Print("Window object: " .. (CompletionNavigatorFrame and "created" or "|cffe2564cnot created|r"))

        if CompletionNavigatorFrame then
            Print("  shown: " .. tostring(CompletionNavigatorFrame:IsShown()))
            Print("  size: " .. math.floor(CompletionNavigatorFrame:GetWidth() or 0)
                .. " x " .. math.floor(CompletionNavigatorFrame:GetHeight() or 0))
            Print("  strata: " .. tostring(CompletionNavigatorFrame:GetFrameStrata()))

            local point, _, _, x, y = CompletionNavigatorFrame:GetPoint()

            Print("  anchored: " .. tostring(point)
                .. " at " .. math.floor(x or 0) .. ", " .. math.floor(y or 0))
        end

        Print("Minimap button: "
            .. (CompletionNavigatorMinimapButton and "created" or "|cffe2564cnot created|r"))

        if CompletionNavigatorMinimapButton then
            Print("  shown: " .. tostring(CompletionNavigatorMinimapButton:IsShown()))
            Print("  hidden by setting: " .. tostring(CN.Settings().minimap.hide))
            Print("  angle: " .. tostring(CN.Settings().minimap.angle))
        end

        Print("Registered tabs: " .. #UI.tabs)
        Print("Minimap frame exists: " .. tostring(Minimap ~= nil))

        if CompletionNavigatorFrame and not CompletionNavigatorFrame:IsShown() then
            Print("Forcing the window open and centering it.")

            CN.Settings().window = nil

            CompletionNavigatorFrame:ClearAllPoints()
            CompletionNavigatorFrame:SetPoint("CENTER")
            CompletionNavigatorFrame:Show()
        end
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
