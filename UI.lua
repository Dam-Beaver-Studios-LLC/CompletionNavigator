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
                row:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
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
    local check, templated = SafeCreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")

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

        button:SetWidth(math.max(70, textWidth + 20))
        button:ClearAllPoints()

        if previous then
            button:SetPoint("LEFT", previous, "RIGHT", 4, 0)
        else
            button:SetPoint("TOPLEFT", 12, -30)
        end

        button:SetScript("OnClick", function()
            UI.SelectTab(index)
        end)

        button:Show()

        previous = button
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

        panel.list = CreateList(panel)
        panel.list:ClearAllPoints()
        panel.list:SetPoint("TOPLEFT", panel.why, "BOTTOMLEFT", -4, -14)
        panel.list:SetPoint("BOTTOMRIGHT", -8, 38)
    end,

    refresh = function(panel)
        local results = CN.Recommend(12)

        if #results == 0 then
            panel.title:SetText("Nothing actionable yet")
            panel.type:SetText("")
            panel.why:SetText("Run a scan from the Scans tab, or pick up a quest.")
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
                local seen, new = module.DiscoverActive()
                local scanned   = module.ScanKnown()

                Print("Quest scan: " .. seen .. " active, " .. new .. " new, "
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

        table.insert(lines, "|cffffd100Quests|r")
        table.insert(lines, "Discovered: " .. CN.CountKeys(CN.Account("discoveredQuests")))
        table.insert(lines, "Names cached: " .. CN.CountKeys(CN.Account("questMetadata")))
        table.insert(lines, "Statuses stored: " .. CN.CountKeys(CN.Account("questStatus")))
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

        panel.minimap = AddCheckbox(panel, "Show minimap button",
            function() return not CN.Settings().minimap.hide end,
            function(value)
                CN.Settings().minimap.hide = not value
                UI.UpdateMinimapButton()
            end)
        panel.minimap:SetPoint("TOPLEFT", panel.debug, "BOTTOMLEFT", 0, -6)

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
        panel.minimap.Refresh()

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
    icon:SetTexture("Interface\\Icons\\INV_Misc_Map_01")
    icon:SetPoint("CENTER", -1, 1)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

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
