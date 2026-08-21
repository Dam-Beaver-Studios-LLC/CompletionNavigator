-- Data/Community.lua
-- Completion Navigator :: quest chains contributed by players.
--
-- SEPARATE FROM Data/Quests.lua, DELIBERATELY.
--
-- Quests.lua is curated: somebody checked each row. This file is not. Rows
-- here arrived as `/cn contribute` exports, were reviewed for shape rather
-- than for truth, and are believed because several independent installs
-- watched the same ordering hold.
--
-- Keeping the two apart is what lets /cn why say which kind of claim it is
-- making. Merging them would be a one-line convenience that permanently
-- destroyed the distinction between "this is known" and "this has been
-- observed a lot", and there is no getting it back afterwards.
--
-- Rows are registered as OBSERVED prerequisites, so nothing in here can ever
-- present itself as curated fact.

local ADDON_NAME, CN = ...

CN.Static.RegisterCommunity({

    -- [questID] = { requires = { questID, ... }, sources = 3 },
    --
    -- `sources` is how many independent contributions agreed. Two is thin,
    -- five is solid; below two a row does not belong in this file.

    -- CN:DATA:COMMUNITY -- new rows are inserted above this marker.
})
