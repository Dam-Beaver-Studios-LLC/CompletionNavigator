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
    "Stop cleared",
    "Stop %d of %d cleared",
    "Route complete.",
    "estimated",
    "unknown",
    "ready",
    "solo",
    "dead",
    "grouped",
    "instanced",

    -- Added in 0.45.0: the words on the newest surfaces, chosen the same way
    -- as the last batch -- where a player's eye lands, not where the strings
    -- happen to be easy to extract.
    --
    -- "ready" and "another zone" were listed a second time here in 0.45.0.
    -- A duplicate in the canonical list is not harmless: this file is the one
    -- authoritative answer to "which strings does the addon use", the lint
    -- counts it, and 48 entries describing 46 strings makes every coverage
    -- number it reports wrong. Removed in 0.48.1, and the lint now refuses a
    -- list that repeats itself.
    "cleared",
    "left",
    "expiring",
    "in your bags",
    "uncollected",
    "quest starter",
    "%d more",
    "%d of %d",
    "flying yourself",
    "on a flight path",
    "on foot",
    "measured",
    "Nothing to do right now.",
    "Nothing is on a clock right now.",
}

CN.RegisterLocale("enUS", {})
