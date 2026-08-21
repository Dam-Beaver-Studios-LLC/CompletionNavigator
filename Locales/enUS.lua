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
}

CN.RegisterLocale("enUS", {})
