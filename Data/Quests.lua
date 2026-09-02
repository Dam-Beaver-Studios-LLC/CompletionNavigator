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
--   requires   (table)   array of prerequisite quest IDs
--   unlocks    (table)   array of quest IDs this one opens
--   breadcrumb (boolean) skippable and permanently missable; a breadcrumb
--                        whose `unlocks` target is started or finished is
--                        reported as permanently gone rather than available
--   obsolete   (boolean) no longer obtainable
--
-- `expansion` WAS DOCUMENTED HERE AND READ NOWHERE, and is gone. 0.91.0.
-- Every field in this list now reaches something; a field a curator fills in
-- that the addon discards is worse than one that was never offered, because
-- the curator paid for it.
--
-- Added in 0.43.0, all optional, all for saying WHY something is not
-- available rather than leaving the player to work it out:
--
--   classes    (table)   class file names that can take it, e.g. { "DRUID" }
--   races      (table)   race file names, e.g. { "NIGHTELF" }
--   faction    (string)  "Alliance" or "Horde"
--   minLevel   (number)  character level required
--
-- `requiresFaction` and `requiresLevel` are accepted as synonyms of the two
-- above, because `/cn export` has always emitted them. 0.91.0 made the two
-- vocabularies gate identically; before that a row written to THIS header's
-- schema was not treated as authoritative and could lose to an external
-- addon's answer.
--   turnInMapID(number)  where it is handed IN, when that differs from where
--   turnInX,               it is picked up -- the client's own waypoint moves
--   turnInY                as you progress, so it cannot answer this
--
-- Add rows with:  .\cn.ps1 data quest <id> -Name "<title>"

local ADDON_NAME, CN = ...

CN.Static.RegisterQuests({

    [8237] = {
        name      = "Vanquish the Invaders!",
    },

    -- CN:DATA:QUESTS -- new rows are inserted above this marker.
})
