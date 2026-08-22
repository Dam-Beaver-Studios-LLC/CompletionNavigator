-- .luacheckrc
-- Completion Navigator :: static analysis configuration.
--
-- luacheck knows nothing about the WoW client, so every API call reads as an
-- undefined global and the real signal drowns in 500 lines of noise. Declaring
-- the client surface here means a warning is worth reading: an undeclared
-- global is now either a typo or a genuine leak.
--
-- Run:  luacheck .

std = "lua51"

max_line_length = false

-- Every file is loaded by the client as
--   local ADDON_NAME, CN = ...
self = false

read_globals = {
    -- Namespaced client API.
    "C_Calendar", "C_CurrencyInfo", "C_DateAndTime",
    "C_CampaignInfo", "C_GossipInfo", "C_Item", "C_MajorFactions", "C_Map",
    "C_MerchantFrame",
    "C_MountJournal", "C_PetJournal", "C_QuestLog", "C_Reputation",
    "C_SuperTrack", "C_TaskQuest", "C_Timer", "C_ToyBox", "C_TradeSkillUI",
    "C_TransmogCollection", "C_VignetteInfo", "C_WeeklyRewards",

    -- Flat client API.
    "CreateFrame", "GetAchievementCriteriaInfo", "GetAchievementInfo",
    "IsMounted", "UnitOnTaxi",
    "GetAchievementNumCriteria", "GetCategoryList", "GetCategoryNumAchievements",
    "GetCursorPosition", "GetItemInfo", "GetMerchantItemInfo",
    "GetMerchantItemLink", "GetMerchantNumItems", "GetNumCompletedAchievements",
    "GetNumTitles", "GetProfessionInfo", "GetProfessions", "GetQuestResetTime",
    "GetRealmName", "GetSpecialization", "GetSpecializationInfo", "GetTitleName",
    "GetZoneText", "IsTitleKnown", "PlayerHasToy", "UnitClass", "UnitExists",
    "UnitFactionGroup", "UnitGUID", "UnitLevel", "UnitName", "UnitRace",
    "UnitSex", "PlaySound", "GetTime",
    "GetPlayerFacing", "InCombatLockdown", "IsInInstance",
    "GetLocale",

    -- Saved instances and the Adventure Guide (Encounter Journal). The EJ
    -- functions are globals rather than a namespaced table, which is why
    -- there are so many of them.
    "GetNumSavedInstances", "GetSavedInstanceInfo", "C_TaxiMap",

    -- Memory reporting, sound and flash, group and death state, self-flying,
    -- crafting orders and the settings panel. All optional, all guarded at
    -- the call site, all real APIs the client provides.
    "UpdateAddOnMemoryUsage", "GetAddOnMemoryUsage",
    "SOUNDKIT", "PlaySound", "UIFrameFlash",
    "UnitIsDeadOrGhost", "UnitIsGhost", "GetNumGroupMembers", "C_DeathInfo",
    "IsInRaid", "IsInInstance", "IsFlying", "IsFlyableArea",
    "C_CraftingOrders", "C_DelvesUI", "C_Spell",

    -- Bags, mail, keystones, heirlooms and challenge modes: five systems the
    -- addon began reading in 0.44.0.
    "C_Container", "GetInboxNumItems", "GetInboxHeaderInfo",
    "C_MythicPlus", "C_ChallengeMode", "C_Heirloom",
    "C_ToyBox", "PlayerHasToy",
    "C_TransmogSets", "C_LFGList", "IsInGuild", "GetGuildInfo", "GetBuildInfo",
    "IsSpellKnown", "IsPlayerSpell", "GetSpellCooldown", "GetItemCooldown",
    "GetItemCount", "GetBindLocation", "EJ_GetDifficulty", "GetDifficultyInfo",
    "SettingsPanel", "Settings", "InterfaceOptions_AddCategory",
    "BackdropTemplateMixin",
    "EncounterJournal", "EJ_SelectInstance", "EJ_GetCurrentInstance",
    "EJ_GetInstanceInfo", "EJ_GetEncounterInfoByIndex", "EJ_GetEncounterInfo",
    "EJ_SetSearch", "EJ_ClearSearch", "EJ_GetNumSearchResults",
    "EJ_GetSearchResult",
    "GetQuestID", "GetTitleText", "GetCategoryInfo",

    -- Globals the client defines that are not functions.
    "Enum", "GameTooltip", "GameFontNormal", "Minimap", "UIParent",
    "UIFrameFadeIn", "UIFrameFadeOut",
    "UISpecialFrames",
    "UiMapPoint", "CreateVector2D", "DEFAULT_CHAT_FRAME", "TooltipDataProcessor",
    "TooltipUtil", "LE_PET_JOURNAL_FILTER_COLLECTED",
    "LE_PET_JOURNAL_FILTER_NOT_COLLECTED",

    -- Lua functions the client exposes globally.
    "date", "time", "strsplit", "debugprofilestop", "wipe",

    -- Optional third-party addons. Probed, never required. The three addon
    -- tables themselves are reached through _G and so are not listed: an
    -- entry here for a name the source never mentions weakens the guarantee
    -- in this file's own header, that an undeclared global is a typo or a
    -- leak. Eleven such entries were pruned in 0.47.0.
    "LibStub",
}

globals = {
    -- SavedVariables, declared in the .toc.
    "CompletionNavigatorDB",

    -- Named frames the client publishes as globals.
    "CompletionNavigatorFrame", "CompletionNavigatorMinimapButton",

    -- Binding labels, read by the client's key binding UI.
    "BINDING_HEADER_COMPLETIONNAVIGATOR",
    "BINDING_NAME_COMPLETIONNAVIGATOR_TOGGLE",
    "BINDING_NAME_COMPLETIONNAVIGATOR_FOLLOW",
    "BINDING_NAME_COMPLETIONNAVIGATOR_PLAN",
    "BINDING_NAME_COMPLETIONNAVIGATOR_HUD",
    "BINDING_NAME_COMPLETIONNAVIGATOR_NEXT",
    "BINDING_NAME_COMPLETIONNAVIGATOR_GO",

    -- Binding handlers, called by name from Bindings.xml.
    "CompletionNavigator_ToggleUI",
    "CompletionNavigator_ToggleFollow",
    "CompletionNavigator_Plan",
    "CompletionNavigator_ToggleHud",
    "CompletionNavigator_NextObjective",
    "CompletionNavigator_Navigate",

    -- Exploration category constant, set by Data files.
    "CN_EXPLORATION_CATEGORY",

    -- Slash command registration. The client reads SLASH_<NAME><n> globals and
    -- dispatches through SlashCmdList; there is no other way to register one.
    "SLASH_COMPLETIONNAVIGATOR1",
    "SLASH_COMPLETIONNAVIGATOR2",
    "SlashCmdList",
}

-- Every file opens with `local ADDON_NAME, CN = ...`. Most only need CN, and
-- dropping the name would make the idiom inconsistent across 38 files for no
-- gain. Suppressed by name rather than by disabling the whole unused-variable
-- check, which does catch real things.
-- Event handlers receive (event, ...) and most do not need the event name.
-- Silencing unused arguments wholesale is right for an event-driven addon;
-- unused *variables* are still reported, and those do catch real things.
unused_args = false

ignore = {
    -- Every file opens with `local ADDON_NAME, CN = ...`. Most only need CN,
    -- and dropping the name would make the idiom inconsistent across 39 files
    -- for no gain.
    "211/ADDON_NAME",

    -- Same idiom: the logging locals are bound at the top of every module so
    -- that adding a Print call later needs no edit to the header.
    "211/DebugPrint",
    "211/Print",
}

-- The provider files exist to absorb the client's positional return lists.
-- Naming every slot is what makes the call sites readable; most are unused by
-- design, and replacing them with select() would make the files worse.
--
-- All three, since the split in 0.45.0 -- the exception belonged to the ROLE,
-- not to the filename, and naming only the original file would have meant the
-- warnings reappeared the moment the role moved.
for _, provider in ipairs({
    "Providers/Blizzard.lua",
    "Providers/BlizzardCollections.lua",
    "Providers/BlizzardWorld.lua",
}) do
    files[provider] = { ignore = { "211" } }
end

-- Test tooling. The harness exists to define the globals the addon reads, so
-- "setting an undefined global" is its entire job; linting it under the addon's
-- rules would report several hundred deliberate ones.
files["harness.lua"] = { ignore = { "1" }, unused = false }
files["bench.lua"]   = { ignore = { "1" }, unused = false }

-- CI builds the Lua toolchain into the workspace, so the repository root now
-- contains thousands of third-party .lua files belonging to LuaRocks and its
-- dependencies. They are not ours and must not be analysed.
exclude_files = {
    "_backups/",

    -- Recordings of a live client, read only by the harness. Evidence, not
    -- source: a malformed one is a broken recording to re-capture, not a
    -- syntax error in the addon -- and it failed the build as though it were.
    --
    -- The FOURTH place that decides what counts as addon source. The other
    -- three -- the toolkit's file scanner, the CI search, and .pkgmeta --
    -- were taught about fixtures/ and this was missed, so the build moved
    -- from failing at the .toc step to failing at Lint.
    "fixtures/",
    ".lua/**",
    ".lua-build/**",
    ".luarocks/**",
    ".install/**",
}
