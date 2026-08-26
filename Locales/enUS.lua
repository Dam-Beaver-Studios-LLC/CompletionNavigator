-- Locales/enUS.lua
-- The canonical key list.
--
-- English needs no translation table -- the keys are English. This file exists
-- so that there is one authoritative list of every key the addon uses, which
-- `cn.ps1 check` lints every locale file against. A translator working from a
-- key that no longer exists is translating something no player will ever see.
--
-- Add a key here in the same commit that introduces it, or the lint fails.

local ADDON_NAME, CN = ...

CN.localeKeys = {
    -- Window tabs
    "Next",
    "Zone",
    "Scans",
    "Now",
    "Warband",
    "Vault",
    "Goals",
    "Journey",
    "Remaining",
    "Collections",
    "Settings",

    -- The arrow
    "Destination",
    "distance unknown",
    "no position",
    "another zone",
    "Arrived: %s",
    "Now heading to: %s",

    -- Added in 0.43.0. Chosen by where a player's eye actually lands: the
    -- arrow, the heads-up line, and the words the route says as it advances.
    "ahead",
    "veer",
    "turn",
    "back",
    "nothing actionable",

    -- Added in 0.65.0. This sentence was doing two jobs -- three places
    -- branched on it as a token while three others printed it -- so it is a
    -- token now and this is the sentence.
    "account-wide",
    "Stop cleared",
    "Stop %d of %d cleared",
    "Route complete.",
    "estimated",
    "unknown",
    "solo",
    "dead",
    "grouped",
    "instanced",

    -- Added in 0.45.0 as "the words on the newest surfaces" -- and thirteen
    -- of them were never looked up by anything. They were translated into
    -- ten languages, passed every lint, and appeared on no screen.
    --
    -- Removed in 0.52.0 rather than kept: a canonical list is the addon's
    -- claim about what has been translated, and a key nothing displays makes
    -- that claim false in the direction that matters -- it says the work is
    -- done. The build now fails on a key with no call site, so the list
    -- cannot drift this way again.
    --
    -- "ready" and "another zone" were listed a second time here in 0.45.0.
    -- A duplicate in the canonical list is not harmless: this file is the one
    -- authoritative answer to "which strings does the addon use", the lint
    -- counts it, and 48 entries describing 46 strings makes every coverage
    -- number it reports wrong. Removed in 0.48.1, and the lint now refuses a
    -- list that repeats itself.
    "%d more",
    "Nothing is on a clock right now.",
}

-- REACHED THROUGH A VARIABLE, NOT A LITERAL.
--
-- The build fails on a canonical key that nothing looks up, which is how
-- thirteen keys translated into ten languages were found to appear on no
-- screen at all. Two lookups are legitimately dynamic, and this is where
-- they are declared -- with the site named, so the claim can be checked by a
-- reader as well as by the build.
CN.localeDynamic = {
    -- UI.lua: `button:SetText(CN.L[tab.name])`
    ["Next"] = "UI tab", ["Zone"] = "UI tab", ["Scans"] = "UI tab",
    ["Now"] = "UI tab", ["Warband"] = "UI tab", ["Vault"] = "UI tab",
    ["Goals"] = "UI tab", ["Journey"] = "UI tab", ["Remaining"] = "UI tab",
    ["Collections"] = "UI tab", ["Settings"] = "UI tab",

    -- Modules/Group.lua: `CN.L[situation]` in `/cn situation`. The values are
    -- identifiers four call sites compare against, so only the display is
    -- translated. "solo" is also looked up literally in the same function.
    ["dead"] = "situation", ["grouped"] = "situation",
    ["instanced"] = "situation",
}

CN.RegisterLocale("enUS", {})
