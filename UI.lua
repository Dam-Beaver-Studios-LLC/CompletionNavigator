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

local Print = CN.Print

local WINDOW_WIDTH  = 560
local WINDOW_HEIGHT = 440
local ROW_HEIGHT    = 20

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

------------------------------------------------------------
-- SCROLLING LIST
------------------------------------------------------------

-- Creates a reusable row list. Rows are pooled; SetRows swaps the data.
local function CreateList(parent)
    local list = CreateFrame("Frame", nil, parent)

    list:SetPoint("TOPLEFT", 8, -8)
    list:SetPoint("BOTTOMRIGHT", -8, 8)

    local scroll = SafeCreateFrame("ScrollFrame", nil, list, "UIPanelScrollFrameTemplate")

    scroll:SetPoint("TOPLEFT")
    scroll:SetPoint("BOTTOMRIGHT", -26, 0)

    local content = CreateFrame("Frame", nil, scroll)

    content:SetSize(1, 1)
    scroll:SetScrollChild(content)

    list.rows = {}

    function list:GetRow(index)
        if self.rows[index] then
            return self.rows[index]
        end

        local row = CreateFrame("Button", nil, content)

        row:SetHeight(ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 0, -((index - 1) * ROW_HEIGHT))
        row:SetPoint("TOPRIGHT", 0, -((index - 1) * ROW_HEIGHT))

        row.highlight = row:CreateTexture(nil, "HIGHLIGHT")
        row.highlight:SetAllPoints()
        row.highlight:SetColorTexture(1, 1, 1, 0.10)

        row.label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightLeft")
        row.label:SetPoint("LEFT", 4, 0)
        row.label:SetPoint("RIGHT", -4, 0)
        row.label:SetJustifyH("LEFT")

        self.rows[index] = row

        return row
    end

    -- entries = { { text = , onClick = , tooltip = }, ... }
    function list:SetEntries(entries)
        local width = scroll:GetWidth() or (WINDOW_WIDTH - 60)

        content:SetSize(width, math.max(1, #entries * ROW_HEIGHT))

        for index, entry in ipairs(entries) do
            local row = self:GetRow(index)

            row.label:SetText(entry.text or "")
            row.entry = entry

            row:SetScript("OnClick", function()
                if entry.onClick then
                    entry.onClick()
                end
            end)

            if entry.tooltip then
                row:SetScript("OnEnter", function(hovered)
                    GameTooltip:SetOwner(hovered, "ANCHOR_RIGHT")
                    GameTooltip:SetText(entry.tooltip, nil, nil, nil, nil, true)
                    GameTooltip:Show()
                end)

                row:SetScript("OnLeave", function()
                    GameTooltip:Hide()
                end)
            else
                row:SetScript("OnEnter", nil)
                row:SetScript("OnLeave", nil)
            end

            row:Show()
        end

        for index = #entries + 1, #self.rows do
            self.rows[index]:Hide()
        end
    end

    return list
end

UI.CreateList = CreateList

------------------------------------------------------------
-- BUTTON HELPERS
------------------------------------------------------------

local function AddButton(parent, text, width, onClick)
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

    return button
end

local function AddCheckbox(parent, text, getter, setter)
    local check = SafeCreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")

    check:SetSize(24, 24)

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
        window.TitleText:SetText("Completion Navigator")
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
        title:SetText("Completion Navigator")

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

    window.body = CreateFrame("Frame", nil, window)
    window.body:SetPoint("TOPLEFT", 10, -58)
    window.body:SetPoint("BOTTOMRIGHT", -10, 34)

    window.footer = window:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    window.footer:SetPoint("BOTTOMLEFT", 14, 14)
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

        button:SetText(tab.name)

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
        if previous and (rowWidth + buttonWidth + 4) > (WINDOW_WIDTH - 24) then
            row      = row + 1
            rowWidth = 0
            previous = nil
        end

        if previous then
            button:SetPoint("LEFT", previous, "RIGHT", 4, 0)
        else
            button:SetPoint("TOPLEFT", 12, -30 - (row * 26))
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
        window.body:SetPoint("TOPLEFT", 10, -58 - (row * 26))
        window.body:SetPoint("BOTTOMRIGHT", -10, 34)
    end

    UI.SelectTab(UI.selectedTab or 1)
end

function UI.SelectTab(index)
    local tab = UI.tabs[index]

    if not tab or not window then
        return
    end

    UI.selectedTab = index

    for buttonIndex, button in ipairs(window.tabButtons) do
        if buttonIndex == index then
            button:SetEnabled(false)
        else
            button:SetEnabled(true)
        end
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
            end
        end
    end

    tab.panel:Show()

    UI.Refresh()
end

------------------------------------------------------------
-- REFRESH
------------------------------------------------------------

function UI.Refresh()
    if not window or not window:IsShown() then
        return
    end

    local tab = UI.tabs[UI.selectedTab or 1]

    if tab and tab.refresh and tab.panel then
        local ok, err = pcall(tab.refresh, tab.panel)

        if not ok then
            Print("Error refreshing the " .. tab.name .. " tab: " .. tostring(err))
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
    window:Show()
    UI.Refresh()

    -- If the frame refuses to show, say so. Silence here is what makes a
    -- missing window look like a command that did nothing.
    if not window:IsShown() then
        Print("The window could not be shown. Run |cffffff00/cn uistatus|r.")
    end
end

function UI.Show()
    BuildWindow()
    UI.RestorePosition()
    window:Show()
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

        panel.list = CreateList(panel)
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
                text = "|cffffff00Show everything|r",
                onClick = function()
                    filters.EnableAllTypes()
                    UI.Refresh()
                end,
            })

            for _, objectiveType in ipairs(filters.TypeOrder()) do
                local enabled = filters.IsTypeEnabled(objectiveType)

                table.insert(entries, {
                    text = (enabled and "|cff00ff00[x]|r " or "|cff666666[ ]|r ")
                        .. (enabled and "" or "|cff808080")
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
            local hidden = filters and filters.HiddenTypeCount() or 0

            panel.title:SetText("Nothing actionable yet")
            panel.type:SetText("")

            -- An empty list because you filtered everything out looks exactly
            -- like an empty list because nothing was found. Say which.
            if hidden > 0 then
                panel.why:SetText(hidden .. " type"
                    .. (hidden == 1 and " is" or "s are") .. " hidden by your filter.\n"
                    .. "Click Filter types to change it.")
            else
                panel.why:SetText("Run a scan from the Scans tab, or pick up a quest.")
            end

            panel.list:SetEntries({})

            CN.currentRecommendation = nil

            return
        end

        local best = results[1]

        CN.currentRecommendation = best

        panel.title:SetText(tostring(best.name or best.id))
        panel.type:SetText(tostring(best.type))
        panel.why:SetText("Why:\n" .. table.concat(CN.ExplainRecommendation(best), "\n"))

        local entries = {}

        for index = 2, #results do
            local objective = results[index]

            table.insert(entries, {
                text = string.format("|cff999999%2d.|r %s |cff808080[%s]|r",
                    index, tostring(objective.name or objective.id),
                    tostring(objective.type)),

                tooltip = table.concat(CN.ExplainRecommendation(objective), "\n"),

                onClick = function()
                    CN.currentRecommendation = objective

                    panel.title:SetText(tostring(objective.name or objective.id))
                    panel.type:SetText(tostring(objective.type))
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

        panel.list = CreateList(panel)
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
                text = string.format("|cff999999%2d.|r %s |cff808080[%s]|r",
                    index, tostring(objective.name or objective.id),
                    tostring(objective.type)),

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
                text = "|cff808080     " .. tostring(objective.name or objective.id)
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
                    .. "|cffffff00" .. module.AvailableCount() .. "|r "
                    .. "available to pick up here.")

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

        table.insert(lines, "|cffffd100Quests|r")

        -- The number he actually wanted back, first.
        local progressModule = CN:GetModule("Progress")

        if progressModule then
            local summary = progressModule.Summary()

            if summary.lifetime then
                table.insert(lines, "Completed: |cffffd100"
                    .. CN.Comma(summary.lifetime) .. "|r")
            end

            local todayLine = "Today: |cffffff00" .. summary.today .. "|r"

            if summary.best > 0 then
                todayLine = todayLine .. "   |cff999999best "
                    .. summary.best .. "|r"
            end

            table.insert(lines, todayLine)
        end

        if questModule then
            local available = questModule.AvailableCount()

            table.insert(lines, "Available to pick up here: "
                .. (available > 0 and "|cffffff00" or "|cff999999")
                .. available .. "|r")
            table.insert(lines, "In your log: " .. #CN.Blizzard.GetQuestLogEntries())
        end

        table.insert(lines, "|cff999999Database: "
            .. CN.CountKeys(CN.Account("discoveredQuests")) .. " known, "
            .. CN.CountKeys(CN.Account("questMetadata")) .. " named, "
            .. CN.CountKeys(CN.Account("questStatus")) .. " tracked|r")
        table.insert(lines, " ")

        local reputations = CN:GetModule("Reputations")

        if reputations then
            local counts = reputations.Summary()

            table.insert(lines, "|cffffd100Reputations|r")
            table.insert(lines, "Account-wide: " .. counts.account)
            table.insert(lines, "Character-specific: " .. counts.character)
            table.insert(lines, "Renown: " .. counts.renown
                .. " (" .. counts.maxedRenown .. " maxed)")
            table.insert(lines, "Exalted: " .. counts.exalted)

            if counts.paragonPending > 0 then
                table.insert(lines, "|cff00ff00Paragon rewards waiting: "
                    .. counts.paragonPending .. "|r")
            end

            table.insert(lines, " ")
        end

        table.insert(lines, "|cffffd100Warband|r")
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

        panel.list = CreateList(panel)
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
                    text = "|cffffd100EVENT|r  " .. tostring(event.title),
                })
            end

            local worldQuests = opportunities.GetWorldQuests()

            for _, worldQuest in ipairs(worldQuests) do
                table.insert(entries, {
                    text = string.format("|cff33ff99WQ|r     %s  |cff999999%s%s|r",
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
                    text = string.format("|cffff8040%s|r  %s",
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
                    text = "|cffff4444CAP|r    " .. tostring(currency.name)
                        .. " |cff999999" .. currency.quantity
                        .. " / " .. currency.maximum .. " -- spend it|r",
                })
            end

            for _, currency in ipairs(currencies.WeeklyUnfilled()) do
                table.insert(entries, {
                    text = "|cff999999WEEK|r   " .. tostring(currency.name)
                        .. " |cff999999" .. currency.remaining .. " left this week|r",
                })
            end
        end

        if #entries == 0 then
            table.insert(entries, { text = "Nothing is expiring nearby." })
            table.insert(entries, {
                text = "|cff999999World quests and rares only appear for your current map.|r",
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

        panel.list = CreateList(panel)
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
            "%d character%s  |cff999999combined: %d professions, %d recipes, %d titles|r",
            #rows, #rows == 1 and "" or "s",
            coverage.professions, coverage.recipes, coverage.titles))

        local entries = {}

        for _, row in ipairs(rows) do
            local marker = row.isCurrent and "|cff00ff00>|r " or "  "

            table.insert(entries, {
                text = marker .. row.key
                    .. string.format("  |cff999999%s %s%s|r",
                        tostring(row.level), tostring(row.class or "?"),
                        row.faction and (" " .. row.faction) or ""),

                tooltip = string.format(
                    "professions %d\nrecipes %d\ntitles %d\nreputations %d",
                    row.professions, row.recipes, row.titles, row.reputations),
            })

            table.insert(entries, {
                text = "      |cff999999professions " .. row.professions
                    .. ", recipes " .. row.recipes
                    .. ", titles " .. row.titles
                    .. ", reputations " .. row.reputations .. "|r",
            })
        end

        panel.list:SetEntries(entries)

        if #rows == 1 then
            panel.note:SetText("|cffffff00Only one character has been seen. "
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

        panel.list = CreateList(panel)
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
            panel.note:SetText("|cff999999The client reports vault progress once you "
                .. "have completed at least one qualifying activity this week.|r")
            return
        end

        local summary = vault.Summary()

        panel.header:SetText(summary.unlocked .. " reward"
            .. (summary.unlocked == 1 and "" or "s") .. " unlocked"
            .. (summary.resetsIn and ("  |cff999999resets in "
                .. vault.FormatReset(summary.resetsIn) .. "|r") or ""))

        local entries = {}

        if summary.claimable then
            table.insert(entries, {
                text = "|cff00ff00A reward is waiting to be collected.|r",
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
                    text = "        |cff999999" .. tier.threshold .. ": "
                        .. (tier.unlocked
                            and ("|cff00ff00unlocked" .. (tier.level and tier.level > 0
                                and (" (item level " .. tier.level .. ")") or "") .. "|r")
                            or "locked")
                        .. "|r",
                })
            end
        end

        panel.list:SetEntries(entries)

        if summary.closest then
            panel.note:SetText("|cffffff00Closest: " .. summary.closest.label
                .. " -- " .. summary.closest.remaining .. " more, "
                .. (vault.rowActions[summary.closest.row] or "keep going") .. ".|r")
        else
            panel.note:SetText("|cff999999Every row is capped. You choose one item "
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

        panel.list = CreateList(panel)
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
            .. " |cff999999of " .. goals.limit .. "|r")

        if #list == 0 then
            panel.list:SetEntries({})
            panel.note:SetText("|cffffff00Nothing pinned. Use |r/cn goal <type> <id>|cffffff00 "
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
            BLOCKED = "|cfff56b61",
            TODO    = "|cffcccccc",
            NOTE    = "|cff999999",
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
                progressText = " |cff73b873done|r"
            elseif fraction then
                progressText = string.format(" |cff5dd2fb%d%%|r",
                    math.floor(fraction * 100 + 0.5))
            end

            table.insert(entries, {
                text = (isSelected and "|cff00ff00>|r " or "  ")
                    .. (chain.done and "|cff999999" or "|cffffff00")
                    .. tostring(goal.name) .. "|r"
                    .. " |cff999999(" .. tostring(goal.type) .. ")|r"
                    .. progressText,

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
                    table.insert(entries, {
                        text = "      |cff5dd2fb" .. CN.ProgressBar(fraction, 24)
                            .. "|r |cff999999" .. CN.Comma(chain.progress.done)
                            .. " / " .. CN.Comma(chain.progress.total)
                            .. " " .. tostring(chain.progress.unit) .. "|r",
                    })
                end

                local shown = 0

                for _, step in ipairs(chain.steps) do
                    if shown >= 15 then
                        table.insert(entries, {
                            text = "      |cff999999... and "
                                .. (#chain.steps - shown) .. " more|r",
                        })
                        break
                    end

                    local colour = stateColor[step.state] or "|cffcccccc"

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
                        text = "      |cff999999Best character: "
                            .. tostring(chain.character) .. "|r",
                    })
                end
            end
        end

        panel.list:SetEntries(entries)

        local selectedChain = chase and chase.Chain(panel.selected)

        if selectedChain then
            panel.note:SetText("|cff999999" .. chase.Summarize(selectedChain) .. "|r")
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

        panel.list = CreateList(panel)
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
                and ("|cffffd100" .. CN.Comma(summary.lifetime)
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

            panel.sub:SetText("|cff999999" .. table.concat(parts, "   ") .. "|r")
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
                    text = "|cffffd100Here|r  " .. tostring(zone.name) .. bar,
                })
            end

            local split = lore.SplitZoneWork()

            if #split.story > 0 or #split.side > 0 then
                table.insert(entries, {
                    text = "      |cff999999" .. #split.story
                        .. " story, " .. #split.side
                        .. " side quests available here|r",
                })
            end

            local closest = lore.Closest(12)

            if #closest > 0 then
                table.insert(entries, { text = " " })
                table.insert(entries, { text = "|cffffd100Closest to finished|r" })

                for _, entry in ipairs(closest) do
                    table.insert(entries, {
                        text = "  |cffffff00" .. tostring(entry.name) .. "|r"
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
                text = "|cff999999No zone achievements scanned yet. "
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

        panel.list = CreateList(panel)
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

            if row.total and row.total > 0 then
                headline = string.format("|cffffd100%-14s|r %6d / %-6d  |cff999999%.1f%%|r",
                    row.name, row.collected or 0, row.total,
                    (row.collected or 0) / row.total * 100)
            else
                headline = string.format("|cffffd100%-14s|r %6d collected",
                    row.name, row.collected or 0)
            end

            table.insert(entries, {
                text    = headline,
                tooltip = row.unknownTotal
                    and ("No percentage is shown because " .. row.unknownTotal .. ".")
                    or nil,
            })

            if row.unknownTotal then
                table.insert(entries, {
                    text = "      |cff808080no percentage: " .. row.unknownTotal .. "|r",
                })
            end

            for _, reason in ipairs(row.reasons or {}) do
                table.insert(entries, { text = "      " .. reason })
            end

            if row.action then
                table.insert(entries, {
                    text = "      |cffffff00-> " .. row.action .. "|r",
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

-- The account dashboard. Every row is "collected / known", never a
-- fabricated percentage of some total the addon cannot verify.
UI.RegisterTab{
    name  = "Collections",
    order = 25,

    build = function(panel)
        panel.header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        panel.header:SetPoint("TOPLEFT", 8, -8)
        panel.header:SetPoint("TOPRIGHT", -8, -8)
        panel.header:SetJustifyH("LEFT")

        panel.list = CreateList(panel)
        panel.list:ClearAllPoints()
        panel.list:SetPoint("TOPLEFT", 4, -32)
        panel.list:SetPoint("BOTTOMRIGHT", -8, 38)

        panel.scanAll = AddButton(panel, "Scan everything", 140, function()
            Print("Scanning all collections; this takes a moment.")

            for _, moduleName in ipairs({ "Pets", "Mounts", "Toys", "Appearances",
                                          "Titles", "Professions" }) do
                local module = CN:GetModule(moduleName)

                if module and module.Scan then
                    pcall(module.Scan)
                end
            end

            Print("Collection scan complete.")
            UI.Refresh()
        end)
        panel.scanAll:SetPoint("BOTTOMLEFT", 8, 8)

        panel.achieve = AddButton(panel, "Scan achievements", 150, function()
            local module = CN:GetModule("Achievements")

            if module then
                Print("Scanning achievements; this takes a moment.")

                local scanned, completed = module.Scan()

                Print("Scanned " .. scanned .. ", completed " .. completed .. ".")
            end

            UI.Refresh()
        end)
        panel.achieve:SetPoint("LEFT", panel.scanAll, "RIGHT", 6, 0)
    end,

    refresh = function(panel)
        local entries = {}

        local function row(label, collected, total, note)
            local text

            if total and total > 0 then
                text = string.format("%-16s %6d / %-6d  |cff999999%.1f%%|r",
                    label, collected, total, collected / total * 100)
            else
                text = string.format("%-16s %6s        |cff999999%s|r",
                    label, "-", note or "not scanned")
            end

            table.insert(entries, { text = text })
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
                text = string.format("%-16s %6d account-wide, %d character-specific",
                    "Reputations", counts.account, counts.character),
            })
        end

        table.insert(entries, { text = " " })

        local quests = CN:GetModule("Quests")

        if quests then
            table.insert(entries, {
                text = string.format("%-16s %6d discovered",
                    "Quests", CN.CountKeys(CN.Account("discoveredQuests"))),
            })
        end

        local professions = CN:GetModule("Professions")

        if professions then
            for _, record in ipairs(professions.Summary()) do
                local note = record.recipesSeen
                    and (record.recipeKnown .. " of " .. record.recipeTotal .. " recipes")
                    or "|cffffff00open its window once|r"

                table.insert(entries, {
                    text = string.format("%-16s %6s / %-6s  |cff999999%s|r",
                        record.name or "?", tostring(record.rank),
                        tostring(record.maxRank), note),
                })
            end

            local waiting = professions.AwaitingRecipeCapture()

            if #waiting > 0 then
                table.insert(entries, { text = " " })
                table.insert(entries, {
                    text = "|cffffff00Recipes need the profession window open: "
                        .. table.concat(waiting, ", ") .. "|r",
                    tooltip = "The client only exposes a recipe list while that "
                        .. "profession's window is open. Open each one once and "
                        .. "the addon captures it automatically.",
                })
            end
        end

        panel.header:SetText("Account completion  |cff999999(collected / known)|r")
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
        panel.modeLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        panel.modeLabel:SetPoint("TOPLEFT", 8, -12)

        -- A cycling button instead of a dropdown: dropdown templates have
        -- been renamed twice in recent expansions, this has not.
        panel.modeButton = AddButton(panel, "balanced", 160, function()
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

            UI.Refresh()
        end)
        panel.modeButton:SetPoint("TOPLEFT", panel.modeLabel, "BOTTOMLEFT", 0, -6)

        panel.modeHelp = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
        panel.modeHelp:SetPoint("LEFT", panel.modeButton, "RIGHT", 8, 0)
        panel.modeHelp:SetText("Click to cycle")

        panel.debug = AddCheckbox(panel, "Debug output",
            function() return CN.Settings().debug end,
            function(value) CN.Settings().debug = value end)
        panel.debug:SetPoint("TOPLEFT", panel.modeButton, "BOTTOMLEFT", 0, -16)

        panel.auto = AddCheckbox(panel, "Auto-advance waypoint as I finish things",
            function() return CN.IsAutoWaypointEnabled() end,
            function(value)
                CN.Settings().autoWaypoint = value

                if value then
                    CN.StartAutoWaypointTicker()
                    CN.AutoAdvance("settings", true)
                else
                    CN.StopAutoWaypointTicker()
                end
            end)
        panel.auto:SetPoint("TOPLEFT", panel.debug, "BOTTOMLEFT", 0, -6)

        panel.minimap = AddCheckbox(panel, "Show minimap button",
            function() return not CN.Settings().minimap.hide end,
            function(value)
                CN.Settings().minimap.hide = not value
                UI.UpdateMinimapButton()
            end)
        panel.minimap:SetPoint("TOPLEFT", panel.auto, "BOTTOMLEFT", 0, -6)

        panel.tooltips = AddCheckbox(panel, "Add lines to item and unit tooltips",
            function() return CN.Settings().tooltips ~= false end,
            function(value) CN.Settings().tooltips = value end)
        panel.tooltips:SetPoint("TOPLEFT", panel.minimap, "BOTTOMLEFT", 0, -6)

        panel.arrow = AddCheckbox(panel, "Show the navigation arrow",
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
            end)
        panel.arrow:SetPoint("TOPLEFT", panel.tooltips, "BOTTOMLEFT", 0, -6)

        panel.pins = AddCheckbox(panel, "Show route pins on the world map",
            function()
                local pins = CN:GetModule("MapPins")
                return pins and pins.IsEnabled()
            end,
            function(value)
                local pins = CN:GetModule("MapPins")

                if pins then
                    pins.SetEnabled(value)
                end
            end)
        panel.pins:SetPoint("TOPLEFT", panel.arrow, "BOTTOMLEFT", 0, -6)

        panel.setup = AddButton(panel, "Scan everything now", 180, function()
            local setup = CN:GetModule("Setup")

            if setup then
                setup.Run()
            end
        end)
        panel.setup:SetPoint("TOPLEFT", panel.pins, "BOTTOMLEFT", 0, -12)

        panel.reset = AddButton(panel, "Reset window position", 180, function()
            CN.Settings().window = nil

            if window then
                window:ClearAllPoints()
                window:SetPoint("CENTER")
            end
        end)
        panel.reset:SetPoint("BOTTOMLEFT", 8, 8)

        panel.about = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
        panel.about:SetPoint("BOTTOMRIGHT", -8, 14)
    end,

    refresh = function(panel)
        local settings = CN.Settings()

        panel.modeLabel:SetText("Priority mode")
        panel.modeButton:SetText(tostring(settings.priorityMode))

        panel.debug.Refresh()
        panel.auto.Refresh()
        panel.minimap.Refresh()
        panel.tooltips.Refresh()
        panel.arrow.Refresh()
        panel.pins.Refresh()

        panel.about:SetText("Completion Navigator v" .. CN.version)
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
    minimapButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
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

            CN.Settings().minimap.angle = math.deg(math.atan(py - my, px - mx))

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
        else
            GameTooltip:AddLine("Nothing actionable is known yet.", 0.6, 0.6, 0.6)
            GameTooltip:AddLine("Run /cn setup once.", 0.6, 0.6, 0.6)
        end

        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("|cffffffffLeft-click|r open the window", 1, 1, 1)
        GameTooltip:AddLine("|cffffffffRight-click|r navigate to the next objective", 1, 1, 1)
        GameTooltip:AddLine("|cffffffffDrag|r reposition this button", 1, 1, 1)
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

BINDING_HEADER_COMPLETIONNAVIGATOR       = "Completion Navigator"
BINDING_NAME_COMPLETIONNAVIGATOR_TOGGLE  = "Toggle window"
BINDING_NAME_COMPLETIONNAVIGATOR_NEXT    = "Recommend next objective"
BINDING_NAME_COMPLETIONNAVIGATOR_GO      = "Navigate to recommendation"

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

        Print("Click the |cffffff00map icon on your minimap|r to open the window, "
            .. "or type |cffffff00/cn ui|r.")
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
    aliases = { "show", "window" },
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
        Print("Window object: " .. (CompletionNavigatorFrame and "created" or "|cffff4444not created|r"))

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
            .. (CompletionNavigatorMinimapButton and "created" or "|cffff4444not created|r"))

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
