-- Design.lua
-- Completion Navigator :: the addon's one palette, one grid, one type scale.
--
-- WHY THIS FILE EXISTS.
--
-- Before 0.54.0 there was no palette. There were three, plus five hundred and
-- forty-three inline hex codes across the tree: five near-identical greys
-- doing one job, three reds, two greens, two golds, and the brand blue
-- written in two different casings. `Modules/Tooltips.lua` kept a fourth set
-- as RGB triples, only one of which matched anything else.
--
-- Every one of those choices was defensible where it was made. Together they
-- read as four people's work, which is the one thing a single-author addon
-- should never look like.
--
-- THE RULE.
--
-- Nothing outside this file defines a colour. Call sites should use the
-- wrappers below.
--
-- WHAT IS ACTUALLY ENFORCED, precisely, because a rule stated more strongly
-- than it is checked is a rule nobody trusts twice: the harness reads every
-- `.lua` named in the `.toc`, collects every `|cffRRGGBB` literal in it, and
-- fails if any one of them is a code that is not in `CN.C`. It does NOT fail
-- on the literal itself -- roughly five hundred of them remain in the tree,
-- all spelling out a palette colour by hand. Writing one more of those is
-- untidy. Writing a NEW colour is the thing that cost sixteen colours last
-- time, and that is the thing the check catches.
--
-- A second check requires every pair of roles to differ by more than 0.05 in
-- RGB distance, so a palette cannot quietly become five greys again either.
--
-- WHAT THE COLOURS MEAN.
--
-- Eight roles, and no more -- plus DISABLED, which is a control state rather
-- than a voice. If something does not fit one of them, the answer is almost
-- always that it should read as body text.
--
--   BRAND    the addon's own voice, and the value the player asked for
--   ACCENT   a thing to type, and a section heading
--   PRIMARY  names and headings on a dark panel
--   BODY     ordinary text
--   MUTED    hints, units, parentheticals, "why not"
--   GOOD     done, collected, unlocked
--   WARN     needs attention -- a cap about to be hit, something waiting
--   BAD      blocked, failed, not collected

local ADDON_NAME, CN = ...

------------------------------------------------------------
-- THE PALETTE
------------------------------------------------------------

CN.C = {
    -- Sampled from the addon's own logo, and the reason everything else is
    -- cool-toned: a warm grey beside this blue reads as dirty.
    BRAND   = "5dd2fb",

    -- Replaces both `ffff00` (139 uses, pure yellow -- aggressive on a dark
    -- chat background) and `ffd100` (24 uses). One gold.
    ACCENT  = "ffc74f",

    PRIMARY = "f2f4f6",
    BODY    = "c8ccd2",

    -- Replaces `999999` (290 uses), `808080`, `cccccc` and `666666`. Pulled
    -- very slightly toward the brand blue so a hint stops reading as
    -- "disabled" next to it.
    MUTED   = "8a8f96",

    -- Replaces `73b873` and `00ff00`. Pure green is a colour from 1998 and
    -- the muted one was already in use for "done" in two modules.
    GOOD    = "73b873",

    -- DEEPER THAN ACCENT, DELIBERATELY.
    --
    -- These two were the same gold, which meant "here is a command you can
    -- type" and "this is about to be wasted" looked identical -- and the
    -- second is the only thing in the addon that is genuinely time-critical.
    -- A palette that does not carry a distinction is not carrying it.
    WARN    = "f0932b",

    -- Replaces `ff4444` and `f56b61`. Dark enough to read on the light
    -- parchment of a tooltip as well as on a dark panel.
    BAD     = "e2564c",

    -- Not a role: the grey a disabled control draws itself in.
    DISABLED = "5a5f66",
}

------------------------------------------------------------
-- WRAPPERS
------------------------------------------------------------

-- One per role, so a call site never types a hex code. Nil-safe, because half
-- of what gets wrapped is a number or a value that may not exist.
local function Wrap(role)
    return function(text)
        return "|cff" .. CN.C[role] .. tostring(text) .. "|r"
    end
end

CN.Brand    = Wrap("BRAND")
CN.Accent   = Wrap("ACCENT")
CN.Primary  = Wrap("PRIMARY")
CN.Body     = Wrap("BODY")
CN.Muted    = Wrap("MUTED")
CN.Good     = Wrap("GOOD")
CN.Warn     = Wrap("WARN")
CN.Bad      = Wrap("BAD")

-- Good or bad from a boolean, which is most of what the addon prints about
-- state. Saves the ternary at ninety call sites.
function CN.State(condition, text)
    if condition then
        return CN.Good(text)
    end

    return CN.Bad(text)
end

------------------------------------------------------------
-- THE SAME COLOURS AS NUMBERS
------------------------------------------------------------

-- `AddLine`, `SetTextColor` and `SetVertexColor` all want three floats.
-- Tooltips.lua kept its own set of triples that had drifted from the hex
-- codes everything else used; now there is one source and two shapes of it.
--
-- Computed on first use and held, because these are read on every tooltip.
local rgb = {}

CN.RGB = setmetatable({}, {
    __index = function(_, role)
        local held = rgb[role]

        if held then
            return held
        end

        local hex = CN.C[role]

        if not hex then
            return { 1, 1, 1 }
        end

        held = {
            tonumber(hex:sub(1, 2), 16) / 255,
            tonumber(hex:sub(3, 4), 16) / 255,
            tonumber(hex:sub(5, 6), 16) / 255,
        }

        rgb[role] = held

        return held
    end,
})

-- The three floats directly, for the very common
-- `SetTextColor(CN.Rgb("MUTED"))` shape.
function CN.Rgb(role)
    local triple = CN.RGB[role]

    return triple[1], triple[2], triple[3]
end

------------------------------------------------------------
-- SPACING
------------------------------------------------------------

-- A four-pixel grid, and only these values. Sampled before this file existed,
-- the window used 2, 4, 6, 8, 12, 14, 16, 26, 30, 32, 34, 38, 52, 58, 64,
-- 104, 136 and 190 -- which is not a grid, it is a series of individually
-- reasonable decisions.
CN.SPACE = {
    XS = 4,
    S  = 8,
    M  = 12,
    L  = 16,
    XL = 24,
}

------------------------------------------------------------
-- TYPE
------------------------------------------------------------

-- Font objects by ROLE rather than by name, so a panel asks for a heading
-- instead of remembering which of GameFontNormal and GameFontNormalLarge the
-- tab next door happened to pick. Nine of the eleven tabs disagreed.
--
-- MUTED is for labels only. It was carrying real information in five places,
-- at roughly 2.8:1 contrast on the panel's own background -- below the
-- accessibility floor for any text size, and about six physical pixels tall
-- at 0.64 UI scale on a large monitor. Anything that carries information uses
-- SMALL and takes its colour from CN.C.MUTED instead.
CN.FONT = {
    TITLE = "GameFontNormalLarge",
    HEAD  = "GameFontNormal",
    BODY  = "GameFontHighlightLeft",
    SMALL = "GameFontHighlightSmall",
    LABEL = "GameFontDisableSmall",
}

------------------------------------------------------------
-- TEXT THAT IS DRAWN OVER THE WORLD
------------------------------------------------------------

-- NOTHING THE ADDON DRAWS OVER THE 3D WORLD HAD AN OUTLINE.
--
-- The arrow's distance readout, the heads-up line, the follow frame and the
-- numbers on the map pins were all bare `GameFont*` strings with the standard
-- one-pixel drop shadow. That is enough over a dark UI panel. It is not
-- enough over Northrend snow, Uldum sand, Bastion's white marble, or a spell
-- effect -- and the distance readout is the number a player reads while
-- running, which is exactly when the background is moving and unpredictable.
--
-- An outline is one call and it is the difference between "readable at a
-- glance" and "readable if the ground happens to be dark".
function CN.Outline(fontString, size, role)
    if not fontString or not fontString.SetFont then
        return false
    end

    local face = fontString.GetFont and fontString:GetFont()

    if not face and GameFontNormal and GameFontNormal.GetFont then
        face = GameFontNormal:GetFont()
    end

    if not face then
        return false
    end

    local applied = pcall(fontString.SetFont, fontString, face, size or 12,
        "OUTLINE")

    if not applied then
        return false
    end

    -- The outline replaces the shadow; keeping both smears the glyph.
    if fontString.SetShadowOffset then
        pcall(fontString.SetShadowOffset, fontString, 0, 0)
    end

    if role and fontString.SetTextColor then
        fontString:SetTextColor(CN.Rgb(role))
    end

    return true
end

------------------------------------------------------------
-- PUNCTUATION
------------------------------------------------------------

-- ONE DASH, USED ONE WAY.
--
-- Sixty-five player-facing strings used `--` as a stand-in for an em dash and
-- others used a plain hyphen for the same job, sometimes in adjacent lines of
-- the same panel. WoW's fonts render U+2014 correctly in every shipped
-- locale, so there was never a technical reason for the substitute.
--
-- `CN.DASH` separates a clause from its aside. `CN.DOT` separates two facts of
-- equal weight -- "Nagrand Â· 12 stops Â· 34m". Small things, and they are most
-- of what separates a hobby addon's chat output from a product's.
CN.DASH = "\226\128\148"
CN.DOT  = "\194\183"

-- Wraps an aside in the dash and the muted colour in one call, which is the
-- single commonest shape in the addon's output.
function CN.Aside(text)
    return " " .. CN.Muted(CN.DASH .. " " .. tostring(text))
end

return CN.C
