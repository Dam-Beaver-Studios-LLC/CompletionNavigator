-- UI/List.lua
-- Completion Navigator :: the scrolling list every tab is built out of.
--
-- SPLIT OUT OF UI.lua IN 0.45.0.
--
-- UI.lua had reached 2,550 lines holding a window, eleven tabs, a minimap
-- button, keybinding entry points and this. The list is the piece with the
-- least to do with the rest: it knows about rows, pooling, filtering and
-- sorting, and nothing about what is in them.
--
-- Only this piece moved. The tabs stayed where they are, because each one
-- reaches into window-local helpers and moving them would be a refactor with
-- real regression risk in a release that already carries a great deal --
-- which is a judgement about timing rather than about the value of doing it.

local ADDON_NAME, CN = ...

local UI = CN.UI

-- Shared with UI.lua, which owns the chrome these rows sit inside.
local WINDOW_WIDTH = UI.WINDOW_WIDTH or 560
local ROW_HEIGHT   = UI.ROW_HEIGHT or 20

local SafeCreateFrame = UI.SafeCreateFrame

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

        -- HANDLERS ARE BOUND ONCE, HERE.
        --
        -- They used to be created inside SetEntries, which meant three fresh
        -- closures per row on every redraw -- three hundred of them for a
        -- hundred-row list, every time the window refreshed, each one
        -- capturing a table it did not need to capture. In this game that is
        -- not an abstract cost: allocation churn is what garbage collection
        -- pauses are made of, and a pause is a stutter.
        --
        -- Bound once and reading `row.entry`, which SetEntries already sets,
        -- a redraw now allocates nothing at all.
        row:SetScript("OnClick", function(clicked)
            local entry = clicked.entry

            if entry and entry.onClick then
                entry.onClick()
            end
        end)

        row:SetScript("OnEnter", function(hovered)
            local entry = hovered.entry

            if not entry or not entry.tooltip or not GameTooltip then
                return
            end

            GameTooltip:SetOwner(hovered, "ANCHOR_RIGHT")
            GameTooltip:SetText(entry.tooltip, nil, nil, nil, nil, true)
            GameTooltip:Show()
        end)

        row:SetScript("OnLeave", function()
            if GameTooltip then
                GameTooltip:Hide()
            end
        end)

        self.rows[index] = row

        return row
    end

    -- A CEILING ON ROWS.
    --
    -- Every row is a frame, and frames cannot be destroyed in this game --
    -- only hidden and reused. A list that renders one entry per row therefore
    -- grows its frame pool to the size of the largest list it has ever been
    -- shown, permanently, for the rest of the session. Nothing capped that.
    --
    -- Two hundred rows is far more than anyone reads before scrolling and
    -- more than any tab currently produces; the point is that the number
    -- exists at all. When it bites, the list says so rather than silently
    -- ending -- a truncated list that looks complete is worse than a long one.
    list.maxRows = 200

    -- A FILTER OVER WHATEVER IS BEING SHOWN.
    --
    -- Not a search across everything the addon knows -- that is what the
    -- commands are for, and a search box that quietly queries a different
    -- data set than the list under it is a lie about what you are looking at.
    -- This narrows the rows already on screen, which is what people reach for
    -- a box for.
    -- STATE IN A LOCAL, NOT ON THE FRAME.
    --
    -- A frame is not a plain table: templates and mixins put a metatable on
    -- it, and reading an unset field can return something other than nil.
    -- The first version of this kept `list.filterText` on the frame and
    -- relied on "unset means nil" -- which held in the game and did not hold
    -- against the test harness's stub, whose __index answers every key. The
    -- test caught it; a player with a different UI library might have found
    -- it instead.
    local filterText = nil

    function list:SetFilter(text)
        -- A stub EditBox, or a template whose GetText returns something
        -- surprising, must not be able to poison the filter with a value that
        -- string.find will throw on later -- three frames away from here,
        -- where the cause is not obvious.
        if type(text) ~= "string" then
            text = ""
        end

        text = CN.Trim(text)

        filterText = (text ~= "") and string.lower(text) or nil

        if self.lastEntries then
            self:SetEntries(self.lastEntries)
        end
    end

    -- SORTING.
    --
    -- Every list in this window has been in whatever order its tab produced,
    -- which is the right default -- the ranking IS the product -- and the
    -- wrong only option. Somebody looking for a specific mount wants
    -- alphabetical; somebody auditing progress wants it grouped.
    --
    -- Three orders, cycled by clicking the header, and "as ranked" is first
    -- so the default never changes for anybody who does not go looking.
    list.sortModes = { "ranked", "name", "reverse" }
    list.sortIndex = 1

    function list:SortMode()
        return self.sortModes[self.sortIndex] or "ranked"
    end

    function list:CycleSort()
        self.sortIndex = (self.sortIndex % #self.sortModes) + 1

        if self.lastEntries then
            self:SetEntries(self.lastEntries)
        end

        return self:SortMode()
    end

    function list:ApplySort(entries)
        local mode = self:SortMode()

        if mode == "ranked" then
            return entries
        end

        local sorted = {}

        for _, entry in ipairs(entries) do
            table.insert(sorted, entry)
        end

        -- A stable-enough comparison on the visible text: the rows are what
        -- the player is reading, so the order they asked for is an order over
        -- what they can see, not over an id they cannot.
        table.sort(sorted, function(a, b)
            local left  = string.lower(tostring(a.text or ""))
            local right = string.lower(tostring(b.text or ""))

            if mode == "reverse" then
                return left > right
            end

            return left < right
        end)

        return sorted
    end

    function list:Matches(entry)
        if not filterText then
            return true
        end

        local haystack = string.lower(tostring(entry.text or ""))

        -- Plain find, not a pattern: somebody typing "mount (2)" is typing a
        -- name, not a regular expression, and a stray bracket must not throw.
        return haystack:find(filterText, 1, true) ~= nil
    end

    -- entries = { { text = , onClick = , tooltip = }, ... }
    function list:SetEntries(entries)
        self.lastEntries = entries

        if filterText then
            local kept = {}

            for _, entry in ipairs(entries) do
                if self:Matches(entry) then
                    table.insert(kept, entry)
                end
            end

            entries = kept
        end

        entries = self:ApplySort(entries)

        local width = scroll:GetWidth() or (WINDOW_WIDTH - 60)

        local shown = math.min(#entries, self.maxRows)

        local truncated = #entries - shown

        if truncated > 0 then
            -- Room for the line that explains the truncation.
            shown = shown - 1
            truncated = truncated + 1
        end

        content:SetSize(width, math.max(1, (shown + (truncated > 0 and 1 or 0)) * ROW_HEIGHT))

        for index = 1, shown do
            local entry = entries[index]

            local row = self:GetRow(index)

            row.label:SetText(entry.text or "")

            -- The only thing a redraw changes. The handlers were bound when
            -- the row was created and read this.
            row.entry = entry

            row:Show()
        end

        local used = shown

        if truncated > 0 then
            used = shown + 1

            local row = self:GetRow(used)

            row.label:SetText("|cff999999... and " .. truncated
                .. " more not shown|r")

            row.entry = nil

            row:Show()
        end

        for index = used + 1, #self.rows do
            self.rows[index]:Hide()
        end

        return used
    end

    return list
end

UI.CreateList = CreateList
