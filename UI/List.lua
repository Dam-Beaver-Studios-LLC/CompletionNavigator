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

-- WHICH PANELS HAVE A LIST, RECORDED RATHER THAN GUESSED.
--
-- The window's filter box applies to one list, and the check for "does this
-- tab have one" was `panel.list and panel.list.SetFilter`. That reads a field
-- off a frame, and a frame is exactly the kind of object that answers yes to
-- any field it is asked about -- in the offline harness it did, so a check
-- that was correct in game could not be tested at all.
--
-- A registry keyed on the panel is the same answer, asked of something that
-- can only say yes when it is true.
UI.listPanels = UI.listPanels or {}

-- Creates a reusable row list. Rows are pooled; SetRows swaps the data.
local function CreateList(parent)
    local list = CreateFrame("Frame", nil, parent)

    if parent then
        UI.listPanels[parent] = list
    end

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
        row.value = CN.Label(row, "ARTWORK", "SMALL")
        row.value:SetPoint("RIGHT", -6, 0)
        row.value:SetJustifyH("RIGHT")

        -- THE CLICKABLE MARKER, in its own gutter to the right of the value
        -- column so it never collides with either. See the header where it is
        -- shown, in the fill loop below.
        row.chevron = CN.Label(row, "ARTWORK", "SMALL")
        row.chevron:SetPoint("RIGHT", 0, 0)
        row.chevron:SetWidth(8)
        row.chevron:SetJustifyH("RIGHT")
        row.chevron:SetText(CN.Muted(">"))
        row.chevron:Hide()

        row.value:ClearAllPoints()
        row.value:SetPoint("RIGHT", row.chevron, "LEFT", -2, 0)

        row.label = CN.Label(row, "ARTWORK", "BODY")
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
            -- A FUNCTION IS ALLOWED, AND IS THE CHEAPER SHAPE.
            --
            -- A tooltip that is expensive to build -- composing and sorting
            -- an objective's four reason tables, say -- was being built for
            -- every row of every refresh whether the mouse went near it or
            -- not. Passing the work instead of the answer means it happens
            -- once, when somebody actually hovers.
            local text = entry.tooltip

            if type(text) == "function" then
                local ok, built = pcall(text)

                text = ok and built or nil
            end

            if not text then
                return
            end

            GameTooltip:SetText(text, nil, nil, nil, nil, true)
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

    -- WHAT THE THREE MODES ARE CALLED IN FRONT OF A PLAYER.
    --
    -- The caption printed the internal key, so it read "sort: reverse" --
    -- reverse of what? -- while the tooltip two lines away said "As ranked,
    -- by name, or reversed", which is a third vocabulary for three states.
    local sortLabels = {
        ranked  = "as ranked",
        name    = "A to Z",
        reverse = "Z to A",
    }

    function list.SortLabel(mode)
        return sortLabels[mode] or tostring(mode)
    end

    function list:SortMode()
        return self.sortModes[self.sortIndex] or "ranked"
    end

    function list:CycleSort()
        self.sortIndex = (self.sortIndex % #self.sortModes) + 1

        if lastEntries then
            self:SetEntries(lastEntries)
        end

        if list.sortCaption then
            list.sortCaption:SetText(CN.Muted("sort: "
                .. list.SortLabel(self:SortMode())))
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

    list.sortCaption = CN.Label(sortButton, "ARTWORK", "SMALL")
    list.sortCaption:SetPoint("RIGHT")
    list.sortCaption:SetJustifyH("RIGHT")
    list.sortCaption:SetText(CN.Muted("sort: as ranked"))

    sortButton:SetScript("OnClick", function()
        list:CycleSort()
    end)

    if CN.UI and CN.UI.AttachTooltip then
        CN.UI.AttachTooltip(sortButton,
            "Sort: as ranked, A to Z, or Z to A. \"As ranked\" is the order "
            .. "the addon thinks you should do things in, which is the point "
            .. "of the addon.")
    end

    list.sortButton = sortButton

    -- ROWS THAT BELONG TO EACH OTHER MOVE TOGETHER.
    --
    -- Five tabs draw a heading and then the rows under it -- a goal and its
    -- chain, a character and their Warband totals, a vault slot and its three
    -- options. Sorting treated all of them as peers, so "A to Z" interleaved
    -- every chain step of every goal into one alphabetical column with the
    -- headings scattered through it, and filtering for a step's text showed
    -- the step with no indication of which goal it belonged to.
    --
    -- A tab marks the parent and its children with the same `group` value.
    -- Consecutive rows sharing one become a block: the block sorts on its
    -- first row's text and its children keep the order the tab produced,
    -- because that order is the sequence you do them in and alphabetising a
    -- sequence destroys the only information it carries.
    local function Blocks(entries)
        local blocks = {}

        local index, count = 1, #entries

        while index <= count do
            local entry = entries[index]

            local group = entry.group

            if group == nil then
                table.insert(blocks, { entry })

                index = index + 1
            else
                local block = { entry }

                index = index + 1

                while index <= count and entries[index].group == group do
                    table.insert(block, entries[index])

                    index = index + 1
                end

                table.insert(blocks, block)
            end
        end

        return blocks
    end

    -- THE SORT KEY IS THE WORDS, NOT THE MARKUP AROUND THEM.
    --
    -- `entry.text` is the RENDERED string: `|cff8a8f96Aardvark|r`, a route
    -- number, a `!` for stale, a leading `x ` for done. Sorting on it sorted
    -- on all of that first, because `|` and the hex digits after it are
    -- ordinary characters. Measured on three tabs:
    --
    --   * Zone: every row begins with its route index, so "A to Z" re-sorted
    --     by route number -- clicking the header did visibly nothing.
    --   * Goals: finished goals are muted (`8a...`) and the rest accented
    --     (`ff...`), so every finished goal sorted above every unfinished one
    --     whatever they were called.
    --   * Scans: stale rows carry a coloured `!`, so A to Z grouped by
    --     staleness and alphabetised within each group.
    --
    -- The same key feeds the filter, so typing `cff` matched every row in the
    -- addon.
    --
    -- Strips colour openers, the `|r` that closes them, inline textures, and
    -- then any leading punctuation and digits the row uses as a marker.
    -- ONE DEFINITION, IN CORE. 0.77.0. It was a local here and the
    -- cross-tab search could not reach it, so the two searched different
    -- strings; see the header on `CN.SortKey`.
    local SortKey = CN.SortKey

    list.SortKey = SortKey

    local function Flatten(blocks)
        local out = {}

        for _, block in ipairs(blocks) do
            for _, entry in ipairs(block) do
                table.insert(out, entry)
            end
        end

        return out
    end

    -- AND A SECOND KIND OF BELONGING, WHICH IS NOT THE SAME KIND.
    --
    -- A goal's chain is atomic: its steps are a sequence and reordering them
    -- is meaningless. A section is not -- the Journey tab draws "Closest to
    -- finished" and then twelve achievements, and those twelve are peers that
    -- a player may well want alphabetised. Freezing them because they sit
    -- under a heading would take the sort away exactly where it is useful.
    --
    -- So `section` sorts WITHIN itself: sections keep the order the tab
    -- produced, a row marked `sectionHeader` stays at the top of its own, and
    -- everything else moves only among its own section's rows.
    local function Runs(blocks)
        local runs, current = {}, nil

        for _, block in ipairs(blocks) do
            local section = block[1].section

            if not current or current.section ~= section then
                current = { section = section }

                table.insert(runs, current)
            end

            table.insert(current, block)
        end

        return runs
    end

    function list:ApplySort(entries)
        local mode = self:SortMode()

        if mode == "ranked" then
            return entries
        end

        local blocks = Blocks(entries)

        -- `table.sort` is not stable, and two blocks whose first rows read the
        -- same would otherwise swap places on every refresh -- a list that
        -- twitches once a second. The original index breaks the tie.
        for position, block in ipairs(blocks) do
            block.order  = position
            block.key    = SortKey(block[1].text)
            block.pinned = block[1].sectionHeader and true or false
        end

        local out = {}

        for _, run in ipairs(Runs(blocks)) do
            table.sort(run, function(a, b)
                -- A heading is not a row to be alphabetised against the rows
                -- it introduces. It is the thing that says what they are.
                if a.pinned ~= b.pinned then
                    return a.pinned
                end

                if a.key == b.key then
                    return a.order < b.order
                end

                if mode == "reverse" then
                    return a.key > b.key
                end

                return a.key < b.key
            end)

            for _, block in ipairs(run) do
                table.insert(out, block)
            end
        end

        return Flatten(out)
    end

    function list:Matches(entry)
        if not filterText then
            return true
        end

        -- The same stripped text the sort uses: a filter that searches the
        -- colour codes is a filter where `cff` matches everything.
        --
        -- AND THE VALUE COLUMN. 0.77.0. The cross-tab count searched it and
        -- this did not, so "Also on: Collections (12)" led to a tab that said
        -- "Nothing here matches". One predicate now.
        local haystack = CN.SearchKey(entry.text, entry.value)

        -- Plain find, not a pattern: somebody typing "mount (2)" is typing a
        -- name, not a regular expression, and a stray bracket must not throw.
        return haystack:find(filterText, 1, true) ~= nil
    end

    -- A block survives the filter if ANY row in it matches, and it survives
    -- whole. Matching a chain step and showing it without its goal is an
    -- answer to a question nobody asked.
    -- HOW MANY ROWS THIS TAB WOULD SHOW FOR A NEEDLE. 0.79.0.
    --
    -- The cross-tab search counted MATCHING ENTRIES while this tab keeps
    -- WHOLE BLOCKS -- a block survives if any row in it matches, and it
    -- survives entire. So "Also on: Goals (2)" led to a tab showing eight
    -- rows, on every grouped tab.
    --
    -- 0.77.0 and 0.78.0 removed the TEXT mismatch between the two
    -- predicates and left the COUNTING mismatch, which is the visible half.
    -- One predicate and one denominator, so the two cannot drift again.
    function list:CountMatching(needle)
        if not needle or needle == "" then
            return 0
        end

        local held = filterText

        filterText = string.lower(needle)

        local kept = self:Filter(self:Entries())

        filterText = held

        return #kept
    end

    function list:Filter(entries)
        if not filterText then
            return entries
        end

        local kept = {}

        for _, block in ipairs(Blocks(entries)) do
            local hit = false

            for _, entry in ipairs(block) do
                if self:Matches(entry) then
                    hit = true
                    break
                end
            end

            if hit then
                for _, entry in ipairs(block) do
                    table.insert(kept, entry)
                end
            end
        end

        return kept
    end

    -- What this list was last given, BEFORE the filter and the sort. The
    -- window's cross-tab search reads it: a search that can only see what
    -- survived the current filter is a search of the answer rather than of
    -- the question.
    function list:Entries()
        return lastEntries or {}
    end

    -- A DIFFERENT SITUATION NEEDS A DIFFERENT SENTENCE. 0.84.0.
    --
    -- Drawing an empty list falls through to `emptyText`, which is the tab's
    -- NORMAL empty message -- "Nothing pinned. /cn goal pins something", "Log
    -- in on another character and this fills itself". Four tabs printed one
    -- of those directly underneath a header saying the module had not loaded,
    -- so a player whose addon was broken was told, in the same twenty pixels,
    -- both that it was broken and that the remedy was to pin a goal or run a
    -- scan -- neither of which can work.
    --
    -- The Zone tab solved this by swapping `emptyText` around the call. Four
    -- copies of that swap is a rule written five times, so it lives here.
    function list:SetEmpty(text)
        local held = self.emptyText

        self.emptyText = text

        self:SetEntries({})

        self.emptyText = held
    end

    -- entries = { { text = , onClick = , tooltip = }, ... }
    function list:SetEntries(entries)
        lastEntries = entries

        entries = self:Filter(entries)
        entries = self:ApplySort(entries)

        local width = scroll:GetWidth() or (WINDOW_WIDTH - 60)

        -- AN EMPTY LIST DREW LITERALLY NOTHING.
        --
        -- `SetEntries({})` hid every row and returned, so a tab with nothing
        -- to show was a one-line header above three hundred and eighty pixels
        -- of void -- which reads as broken rather than as empty. Every tab
        -- inherits this; each sets `list.emptyText` to the step that would
        -- fill it.
        if #entries == 0 then
            local row = self:GetRow(1)

            content:SetSize(width, ROW_HEIGHT)

            -- "NOTHING MATCHED" IS NOT "YOU HAVE NEVER SCANNED".
            --
            -- The filter runs first, so a search that matched nothing fell
            -- into this branch and printed the tab's own empty text. On
            -- Collections that reads "Nothing scanned yet. Press Scan my
            -- collections." -- so a player who typed a name with a typo was
            -- told to run a scan that freezes the client for several seconds,
            -- and the list was still empty afterwards.
            local message = self.emptyText or "Nothing to show here."

            if filterText and #(lastEntries or {}) > 0 then
                message = "Nothing here matches \"" .. filterText .. "\"."
            end

            row.label:SetText(CN.Muted(message))
            row.value:SetText("")
            row.value:SetWidth(0.001)
            row.selected:SetShown(false)
            row.chevron:Hide()

            -- AND THE PROGRESS BAR, which the filled path hides and this one
            -- did not -- so a search that matched nothing on a tab with bars
            -- drew the message with the previous row's bar still under it.
            if row.bar then
                row.bar:Hide()
            end

            row.entry = nil

            row:EnableMouse(false)
            row:Show()

            for index = 2, #self.rows do
                self.rows[index]:Hide()
            end

            return
        end

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

            -- AND NOT BY COLOUR ALONE.
            --
            -- Whether a row navigates you across a continent or does nothing
            -- at all was carried by two steps of brightness -- f2f4f6 against
            -- c8ccd2 -- which is this addon's first rule broken in the widget
            -- every tab is built out of. It was also defeated wherever a tab
            -- wraps its whole label in an inline colour code, which several
            -- do, so those rows were indistinguishable at any brightness.
            --
            -- A chevron in the value column's own gutter: present when the
            -- row acts, absent when it does not, and unaffected by whatever
            -- the label is wearing.
            row.chevron:SetShown(actionable)

            -- The hover highlight is reserved for rows that do something too:
            -- a highlight under an inert row says "this is clickable".
            row.highlight:SetAlpha(actionable and 1 or 0)

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
            row.chevron:Hide()

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
