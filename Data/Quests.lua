-- Data/Quests.lua
-- Completion Navigator :: curated static quest data.
--
-- Blizzard does not reliably return metadata for historical quests, so
-- anything the client cannot answer lives here. Keys are quest IDs.
--
-- Fields:
--   name       (string)  quest title
--   mapID      (number)  UiMapID the quest is picked up or completed in
--   x, y       (number)  0-1 normalized map coordinates
--   expansion  (string)  short expansion tag
--   requires   (table)   array of prerequisite quest IDs
--   unlocks    (table)   array of quest IDs this one opens
--   breadcrumb (boolean) skippable and permanently missable
--   obsolete   (boolean) no longer obtainable
--
-- Added in 0.43.0, all optional, all for saying WHY something is not
-- available rather than leaving the player to work it out:
--
--   classes    (table)   class file names that can take it, e.g. { "DRUID" }
--   races      (table)   race file names, e.g. { "NIGHTELF" }
--   faction    (string)  "Alliance" or "Horde"
--   minLevel   (number)  character level required
--   turnInMapID(number)  where it is handed IN, when that differs from where
--   turnInX,               it is picked up -- the client's own waypoint moves
--   turnInY                as you progress, so it cannot answer this
--
-- Add rows with:  .\cn.ps1 data quest <id> -Name "<title>"

local ADDON_NAME, CN = ...

CN.Static.RegisterQuests({

    [8237] = {
        name      = "Vanquish the Invaders!",
        expansion = "Classic",
    },

    -- CN:DATA:QUESTS -- new rows are inserted above this marker.
})
