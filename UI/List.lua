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

        -- Alternating rows, very faintly. Below the threshold at which
        -- anybody would call it striping, and above the threshold at which
        -- the eye stops losing its place along a wide row.
        row.stripe = row:CreateTexture(nil, "BACKGROUND")
        row.stripe:SetAllPoints()
        row.stripe:SetColorTexture(1, 1, 1, 0.025)
        row.stripe:SetShown(index % 2 == 0)

        -- SELECTION IS A TEXTURE NOW, NOT A CHARACTER.
        --
        -- Three tabs marked the selected row by prepending a green ">" to
        -- the label string, which shifts every other row's text by the width
        -- of two glyphs and reads as punctuation rather than as state.
        row.selected = row:CreateTexture(nil, "ARTWORK")
        row.selected:SetAllPoints()
        row.selected:SetColorTexture(CN.Rgb("BRAND"))
        row.selected:SetAlpha(0.16)
        row.selected:Hide()

        row.highlight = row:CreateTexture(nil, "HIGHLIGHT")
        row.highlight:SetAllPoints()
        row.highlight:SetColorTexture(1, 1, 1, 0.10)

        -- A RIGHT-ALIGNED VALUE COLUMN.
        --
        -- Three tabs built their columns with `%-16s` and `%6d` padding. WoW
        -- ships no monospace font and Friz Quadrata is proportional, so
        -- "Pets", "Appearances" and "Achievements" padded to sixteen
        -- characters are three different widths and the numbers beside them
        -- were visibly ragged -- on the tabs that most want to read as a
        -- dashboard.
        --
        -- Two anchored fontstrings do what padding cannot.
        row.value = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        row.value:SetPoint("RIGHT", -6, 0)
        row.value:SetJustifyH("RIGHT")

        row.label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightLeft")
        row.label:SetPoint("LEFT", 4, 0)
        row.label:SetPoint("RIGHT", row.value, "LEFT", -8, 0)
        row.label:SetJustifyH("LEFT")

        -- A REAL BAR, RATHER THAN ONE MADE OF EQUALS SIGNS.
        --
        -- `CN.ProgressBar` builds its bar from "=" and "-" characters, which
        -- is the right call in chat where there is no alternative. In the
        -- window it meant a twenty-four cell bar whose PIXEL WIDTH changed as
        -- it filled, because the two characters are different widths -- a
        -- progress bar that gets shorter as you make progress.
        row.bar = row:CreateTexture(nil, "ARTWORK")
        row.bar:SetHeight(2)
        row.bar:SetPoint("BOTTOMLEFT", 4, 1)
        row.bar:SetColorTexture(CN.Rgb("BRAND"))
        row.bar:SetAlpha(0.85)
        row.bar:Hide()

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

    -- THE SAME TRAP, TWO FIELDS ALONG.
    --
    -- `lastEntries` was kept on the frame while `filterText` was moved off it
    -- for exactly the reason above, which is the shape of a fix applied to
    -- the instance that was noticed rather than to the class. Reading an
    -- unset field on a frame is not guaranteed to give nil -- a mixin's
    -- __index can answer every key -- and here that turns `if
    -- self.lastEntries then` into an infinite ipairs over a table that
    -- answers every index.
    --
    -- Found in 0.47.0 when a new test made the first call to SetFilter
    -- happen before anything had set entries. It hung the suite outright.
    local lastEntries = nil

    -- Readable, because a filter nobody can read is a filter nobody can test,
    -- and the one defect this widget has shipped was a filter that was set
    -- and never applied.
    function list:GetFilter()
        return filterText
    end

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

        if lastEntries then
            self:SetEntries(lastEntries)
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

        if lastEntries then
            self:SetEntries(lastEntries)
        end

        if list.sortCaption then
            list.sortCaption:SetText(CN.Muted("sort: " .. self:SortMode()))
        end

        return self:SortMode()
    end

    -- AND THE BUTTON THAT CYCLES IT.
    --
    -- The comment above says "cycled by clicking the header" and nothing in
    -- the addon called `CycleSort` -- a complete, tested, three-mode sort
    -- that no player could reach. Twelve lines to ship a feature that was
    -- already written.
    local sortButton = CreateFrame("Button", nil, parent)

    -- INSIDE THE LIST, NOT IN THE BAND ABOVE IT.
    --
    -- Anchored above the list, it sat in the eighteen pixels most panels
    -- already use for their header -- and on the Next tab, over the last line
    -- of the "why this recommendation" text. There is no free band above a
    -- list; there is a free corner inside one, because the first row starts
    -- below the scroll frame's own inset.
    sortButton:SetSize(96, 14)
    sortButton:SetPoint("TOPRIGHT", list, "TOPRIGHT", -28, 3)
    -- Above the rows, so the caption is not painted over by a stripe.
    if list.GetFrameLevel and sortButton.SetFrameLevel then
        local level = list:GetFrameLevel()

        if type(level) == "number" then
            sortButton:SetFrameLevel(level + 4)
        end
    end

    list.sortCaption = sortButton:CreateFontString(nil, "ARTWORK",
        "GameFontHighlightSmall")
    list.sortCaption:SetPoint("RIGHT")
    list.sortCaption:SetJustifyH("RIGHT")
    list.sortCaption:SetText(CN.Muted("sort: ranked"))

    sortButton:SetScript("OnClick", function()
        list:CycleSort()
    end)

    if CN.UI and CN.UI.AttachTooltip then
        CN.UI.AttachTooltip(sortButton,
            "As ranked, by name, or reversed. \"As ranked\" is the order the "
            .. "addon thinks you should do things in, which is the point of "
            .. "the addon.")
    end

    list.sortButton = sortButton

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
        lastEntries = entries

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
            row.value:SetText(entry.value or "")

            -- THE COLUMN TAKES NO ROOM WHEN THERE IS NOTHING IN IT.
            --
            -- 0.54.0 gave it a fixed width, and the label's right edge is
            -- anchored to it -- so every row on every tab that sets no value
            -- lost a hundred and seventy-eight pixels of label to an empty
            -- fontstring. Of forty-three entry sites in the window, nine set
            -- a value; the other thirty-four were paying for a column that
            -- was not there.
            --
            -- Wide enough for the widest thing any tab puts in it, which is
            -- the reputation row's "412 account-wide, 96 this character".
            row.value:SetWidth(entry.value and CN.UI.VALUE_WIDTH or 0.001)

            row.selected:SetShown(entry.selected and true or false)

            -- Only rows that do something respond to the mouse, so a hover
            -- highlight means "this is clickable" rather than "the cursor is
            -- here". Inert rows take the body colour; actionable ones the
            -- brighter primary.
            local actionable = entry.onClick ~= nil

            row:EnableMouse(actionable or entry.tooltip ~= nil)

            if actionable then
                row.label:SetTextColor(CN.Rgb("PRIMARY"))
            else
                row.label:SetTextColor(CN.Rgb("BODY"))
            end

            if entry.fraction then
                local fraction = math.max(0, math.min(1, entry.fraction))

                row.bar:SetWidth(math.max(1, (width - 12) * fraction))
                row.bar:Show()
            else
                row.bar:Hide()
            end

            -- The only thing a redraw changes. The handlers were bound when
            -- the row was created and read this.
            row.entry = entry

            row:Show()
        end

        local used = shown

        if truncated > 0 then
            used = shown + 1

            local row = self:GetRow(used)

            row.label:SetText(CN.Muted("and " .. truncated .. " more not shown"))
            row.value:SetText("")
            row.selected:Hide()
            row.bar:Hide()

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
