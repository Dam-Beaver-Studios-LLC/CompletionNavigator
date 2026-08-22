-- Providers/BlizzardCollections.lua
-- Completion Navigator :: pets, mounts, toys, appearances and titles.
--
-- SPLIT OUT OF Providers/Blizzard.lua IN 0.45.0.
--
-- That file had grown to 2,250 lines and held every call this addon makes
-- into the client. The original argument for one file was sound -- a patch
-- that renames an API is a one-file fix rather than a hunt -- and it stopped
-- being true somewhere around the point where finding the function you wanted
-- required a search rather than a scroll.
--
-- The three files divide by what the client is being asked ABOUT, which is
-- also how patches break things: a collections patch breaks collection APIs.
-- `CN.Blizzard` is still one table; only the source is divided.

local ADDON_NAME, CN = ...

local Blizzard = CN.Blizzard

-- BATTLE PETS
------------------------------------------------------------

-- The pet journal reports only what the player's current filters allow, so
-- any complete scan must widen the filters and then put them back.
--
-- IT PUT BACK THE SEARCH BOX AND NOTHING ELSE.
--
-- The comment above has said "and then put them back" since this was
-- written, and the code restored one of the four things it changed. A player
-- with their journal filtered to, say, uncollected wild pets ran `/cn setup`
-- once and had it silently reset to show everything -- permanently, with no
-- undo, and with no message saying so. That is the addon reaching into the
-- player's interface and changing a setting they chose, which is the one
-- thing this project's standing rule forbids outright: it prompts, it does
-- not act.
--
-- Restoring the checkbox states needs to read them first, and the client
-- will only answer for the two collected filters -- there is no getter for
-- source or type checks. So those are widened only if the scan would
-- otherwise see nothing, and are restored to "all checked", which is the
-- journal's own default and the state the overwhelming majority of players
-- are in. Stated here rather than hidden, because it is the one place this
-- file cannot be exact.
function Blizzard.WithAllPetsShown(scan)
    if not C_PetJournal then
        return
    end

    local search = C_PetJournal.GetSearchFilter and C_PetJournal.GetSearchFilter() or ""

    local collected, uncollected

    if C_PetJournal.IsFilterChecked and LE_PET_JOURNAL_FILTER_COLLECTED then
        local gotCollected, wasCollected =
            pcall(C_PetJournal.IsFilterChecked, LE_PET_JOURNAL_FILTER_COLLECTED)

        local gotUncollected, wasUncollected =
            pcall(C_PetJournal.IsFilterChecked, LE_PET_JOURNAL_FILTER_NOT_COLLECTED)

        -- EXPLICIT IFS. `got and was or nil` cannot express false: when the
        -- filter is off, `false or nil` is nil, the restore is skipped, and
        -- the filter the player turned off stays on. That is the whole bug
        -- this block exists to fix, reintroduced by the idiom -- and it is
        -- the second time this exact and/or trap has shipped in this addon.
        if gotCollected then
            collected = wasCollected and true or false
        end

        if gotUncollected then
            uncollected = wasUncollected and true or false
        end
    end

    if C_PetJournal.SetSearchFilter then
        C_PetJournal.SetSearchFilter("")
    end

    if C_PetJournal.SetFilterChecked and LE_PET_JOURNAL_FILTER_COLLECTED then
        C_PetJournal.SetFilterChecked(LE_PET_JOURNAL_FILTER_COLLECTED, true)
        C_PetJournal.SetFilterChecked(LE_PET_JOURNAL_FILTER_NOT_COLLECTED, true)
    end

    -- THE COMMENT ABOVE SAID "ONLY IF THE SCAN WOULD OTHERWISE SEE NOTHING".
    -- THE CODE DID IT UNCONDITIONALLY, EVERY TIME.
    --
    -- Source and type checks have no getter, so widening them cannot be
    -- undone -- which makes an unconditional widen a permanent change to a
    -- setting the player chose. And the pet scan runs on a thirty-second
    -- throttle off PET_JOURNAL_LIST_UPDATE, so a player with the Pet Journal
    -- open and filtered to, say, Drop-source Beasts had those filters wiped
    -- twice a minute while they were using it. By an addon whose standing
    -- rule is that it prompts and does not act.
    --
    -- The honest version, at last. The journal's own count answers the
    -- question before anything is changed: with the collected filters already
    -- widened above, a count of zero can only mean the source or type checks
    -- are hiding everything. Only then is the widening justified -- and the
    -- player is told, because it is not recoverable.
    if select(1, Blizzard.GetNumPets()) == 0 then
        local widened = false

        if C_PetJournal.SetAllPetSourcesChecked then
            C_PetJournal.SetAllPetSourcesChecked(true)
            widened = true
        end

        if C_PetJournal.SetAllPetTypesChecked then
            C_PetJournal.SetAllPetTypesChecked(true)
            widened = true
        end

        if widened then
            CN.Print("Your Pet Journal's source and type filters were hiding "
                .. "every pet, so they were set to show everything. The "
                .. "client does not let an addon read those checkboxes, so "
                .. "they cannot be put back -- set them again in the journal "
                .. "if you had them narrowed.")
        end
    end

    local ok, err = pcall(scan)

    -- Put back everything that was read, whether the scan threw or not.
    if C_PetJournal.SetSearchFilter then
        C_PetJournal.SetSearchFilter(search or "")
    end

    if C_PetJournal.SetFilterChecked and LE_PET_JOURNAL_FILTER_COLLECTED then
        if collected ~= nil then
            pcall(C_PetJournal.SetFilterChecked,
                LE_PET_JOURNAL_FILTER_COLLECTED, collected)
        end

        if uncollected ~= nil then
            pcall(C_PetJournal.SetFilterChecked,
                LE_PET_JOURNAL_FILTER_NOT_COLLECTED, uncollected)
        end
    end

    if not ok then
        error(err, 0)
    end
end

function Blizzard.GetNumPets()
    if C_PetJournal and C_PetJournal.GetNumPets then
        return C_PetJournal.GetNumPets()
    end

    return 0, 0
end

function Blizzard.GetPetByIndex(index)
    if not C_PetJournal or not C_PetJournal.GetPetInfoByIndex then
        return nil
    end

    local petID, speciesID, owned, customName, level, favorite, isRevoked,
          speciesName, icon, petType, companionID, tooltip, description,
          isWild, canBattle, isTradeable, isUnique, obtainable =
          C_PetJournal.GetPetInfoByIndex(index)

    if not speciesID then
        return nil
    end

    return {
        petID       = petID,
        speciesID   = speciesID,
        owned       = owned and true or false,
        level       = level,
        favorite    = favorite and true or false,
        name        = speciesName,
        icon        = icon,
        petType     = petType,
        isWild      = isWild and true or false,
        canBattle   = canBattle and true or false,
        obtainable  = obtainable ~= false,
        description = description,
    }
end

-- A pet's name, from the client's own journal.
--
-- Exists so the addon can stop keeping its own copy of eighteen hundred pet
-- names on disk. The journal answers instantly and is always current, which a
-- saved copy is not.
function Blizzard.GetPetName(speciesID)
    if not speciesID or not C_PetJournal or not C_PetJournal.GetPetInfoBySpeciesID then
        return nil
    end

    local ok, name = pcall(C_PetJournal.GetPetInfoBySpeciesID, speciesID)

    if ok and name and name ~= "" then
        return name
    end

    return nil
end

function Blizzard.GetPetCollectedCount(speciesID)
    if C_PetJournal and C_PetJournal.GetNumCollectedInfo then
        return C_PetJournal.GetNumCollectedInfo(speciesID)
    end

    return 0, 0
end

------------------------------------------------------------
-- MOUNTS
------------------------------------------------------------

function Blizzard.GetMountIDs()
    if C_MountJournal and C_MountJournal.GetMountIDs then
        return C_MountJournal.GetMountIDs()
    end

    return {}
end

function Blizzard.GetMountByID(mountID)
    if not C_MountJournal or not C_MountJournal.GetMountInfoByID then
        return nil
    end

    local name, spellID, icon, isActive, isUsable, sourceType, isFavorite,
          isFactionSpecific, faction, shouldHideOnChar, isCollected =
          C_MountJournal.GetMountInfoByID(mountID)

    if not name then
        return nil
    end

    local source, description

    if C_MountJournal.GetMountInfoExtraByID then
        local _, extraDescription, extraSource = C_MountJournal.GetMountInfoExtraByID(mountID)

        description = extraDescription
        source      = extraSource
    end

    return {
        mountID           = mountID,
        name              = name,
        spellID           = spellID,
        icon              = icon,
        sourceType        = sourceType,
        isFactionSpecific = isFactionSpecific and true or false,
        faction           = faction,
        hiddenOnCharacter = shouldHideOnChar and true or false,
        isCollected       = isCollected and true or false,
        source            = source,
        description       = description,
    }
end

------------------------------------------------------------
-- TOYS
------------------------------------------------------------

-- Same filter problem as the pet journal, and until 0.49.0 the same failure
-- to put anything back -- this one restored nothing at all, not even the
-- search string it cleared.
function Blizzard.WithAllToysShown(scan)
    if not C_ToyBox then
        return
    end

    local collected, uncollected

    -- Explicit, for the reason spelled out in WithAllPetsShown above.
    if C_ToyBox.GetCollectedShown then
        local got, was = pcall(C_ToyBox.GetCollectedShown)

        if got then
            collected = was and true or false
        end
    end

    if C_ToyBox.GetUncollectedShown then
        local got, was = pcall(C_ToyBox.GetUncollectedShown)

        if got then
            uncollected = was and true or false
        end
    end

    if C_ToyBox.SetFilterString then
        C_ToyBox.SetFilterString("")
    end

    if C_ToyBox.SetCollectedShown then
        C_ToyBox.SetCollectedShown(true)
    end

    if C_ToyBox.SetUncollectedShown then
        C_ToyBox.SetUncollectedShown(true)
    end

    -- SAME RULE AS THE PET JOURNAL, AND FOR THE SAME REASON.
    --
    -- `SetAllSourceTypeFilters` has no getter either, so widening it is
    -- permanent. It was done unconditionally and never restored. With the
    -- collected and uncollected filters already widened above, a filtered
    -- count of zero can only be the source-type checks, and that is the one
    -- case where changing them beats returning an empty collection.
    if Blizzard.GetNumToys() == 0 and C_ToyBox.SetAllSourceTypeFilters then
        C_ToyBox.SetAllSourceTypeFilters(true)

        CN.Print("Your Toy Box's source filters were hiding every toy, so "
            .. "they were set to show everything. The client does not let an "
            .. "addon read them, so they cannot be put back.")
    end

    local ok, err = pcall(scan)

    -- NOT A RESTORE, AND NO LONGER PRETENDING TO BE ONE.
    --
    -- There is no `GetFilterString`, so the search box's contents were never
    -- captured and this line cleared it a second time. It stays -- an addon
    -- that leaves a search string behind would hide the player's own toys --
    -- but it is described accurately: the box is left empty, not restored.
    if C_ToyBox.SetFilterString then
        C_ToyBox.SetFilterString("")
    end

    if collected ~= nil and C_ToyBox.SetCollectedShown then
        pcall(C_ToyBox.SetCollectedShown, collected)
    end

    if uncollected ~= nil and C_ToyBox.SetUncollectedShown then
        pcall(C_ToyBox.SetUncollectedShown, uncollected)
    end

    if not ok then
        error(err, 0)
    end
end

function Blizzard.GetNumToys()
    if C_ToyBox and C_ToyBox.GetNumFilteredToys then
        return C_ToyBox.GetNumFilteredToys()
    end

    if C_ToyBox and C_ToyBox.GetNumToys then
        return C_ToyBox.GetNumToys()
    end

    return 0
end

function Blizzard.GetToyByIndex(index)
    if not C_ToyBox or not C_ToyBox.GetToyFromIndex then
        return nil
    end

    local itemID = C_ToyBox.GetToyFromIndex(index)

    if not itemID or itemID == 0 then
        return nil
    end

    local _, name, icon = C_ToyBox.GetToyInfo(itemID)

    return {
        itemID    = itemID,
        name      = name,
        icon      = icon,
        collected = PlayerHasToy and PlayerHasToy(itemID) and true or false,
    }
end

------------------------------------------------------------
-- APPEARANCES (TRANSMOG)
------------------------------------------------------------

-- Appearance counts are reported per category. Individual appearance
-- enumeration is enormous; the per-category totals are what a completion
-- dashboard actually needs.
function Blizzard.GetAppearanceCategories()
    local categories = {}

    if not C_TransmogCollection then
        return categories
    end

    local names = C_TransmogCollection.GetCategoryInfo
        and Enum and Enum.TransmogCollectionType

    if not names then
        return categories
    end

    for _, categoryID in pairs(Enum.TransmogCollectionType) do
        if type(categoryID) == "number" then
            local name = C_TransmogCollection.GetCategoryInfo(categoryID)

            if name then
                local collected = C_TransmogCollection.GetCategoryCollectedCount
                    and C_TransmogCollection.GetCategoryCollectedCount(categoryID) or 0

                local total = C_TransmogCollection.GetCategoryTotal
                    and C_TransmogCollection.GetCategoryTotal(categoryID) or 0

                if total and total > 0 then
                    table.insert(categories, {
                        categoryID = categoryID,
                        name       = name,
                        collected  = collected,
                        total      = total,
                    })
                end
            end
        end
    end

    table.sort(categories, function(a, b) return a.name < b.name end)

    return categories
end

------------------------------------------------------------
-- TITLES
------------------------------------------------------------

function Blizzard.GetTitles()
    local titles = {}

    if not GetNumTitles then
        return titles
    end

    for index = 1, GetNumTitles() do
        local name = GetTitleName and GetTitleName(index)

        if name and name ~= "" then
            table.insert(titles, {
                titleID = index,
                name    = (name:gsub("^%s+", ""):gsub("%s+$", "")),
                known   = IsTitleKnown and IsTitleKnown(index) and true or false,
            })
        end
    end

    return titles
end

------------------------------------------------------------
-- ACHIEVEMENTS
------------------------------------------------------------

function Blizzard.GetAchievementCategories()
    if GetCategoryList then
        return GetCategoryList()
    end

    return {}
end

function Blizzard.GetCategoryCounts(categoryID)
    if not GetCategoryNumAchievements then
        return 0, 0
    end

    local total, completed = GetCategoryNumAchievements(categoryID, true)

    return total or 0, completed or 0
end

function Blizzard.GetAchievementInCategory(categoryID, index)
    if not GetAchievementInfo then
        return nil
    end

    local id, name, points, completed, _, _, _, description, flags, icon =
        GetAchievementInfo(categoryID, index)

    if not id then
        return nil
    end

    return {
        achievementID = id,
        name          = name,
        points        = points or 0,
        completed     = completed and true or false,
        description   = description,
        icon          = icon,
        flags         = flags,
    }
end

-- Points for one achievement, live from the client.
--
-- The addon stopped storing points in 0.36.0 because the client answers
-- instantly and a copy on disk was dead weight. That was right, and it left
-- one caller reading a field that no longer exists -- so this is the
-- replacement it should have had at the time.
function Blizzard.GetAchievementPoints(achievementID)
    if not GetAchievementInfo or not achievementID then
        return nil
    end

    local ok, _, _, points = pcall(GetAchievementInfo, achievementID)

    if not ok then
        return nil
    end

    return points
end

-- Returns completedCriteria, totalCriteria for one achievement.
-- The achievement's name, straight from the client.
--
-- Needed because a player can pin an achievement the addon has never scanned,
-- and answering them with "Achievement 12345" is the addon admitting it did
-- not look.
function Blizzard.GetAchievementName(achievementID)
    if not GetAchievementInfo or not achievementID then
        return nil
    end

    local ok, _, name = pcall(GetAchievementInfo, achievementID)

    if ok and name and name ~= "" then
        return name
    end

    return nil
end

function Blizzard.GetAchievementProgress(achievementID)
    if not GetAchievementNumCriteria or not GetAchievementCriteriaInfo then
        return 0, 0
    end

    local total = GetAchievementNumCriteria(achievementID) or 0
    local done  = 0

    -- A SINGLE COUNTING CRITERION IS NOT A SINGLE STEP.
    --
    -- "Complete 100 quests in Hallowfall" is reported by the client as ONE
    -- criterion carrying a quantity and a requirement. Counting rows gave
    -- 0 of 1 -- so a hundred-quest zone grind was filed as "not started, 1
    -- to do", sorted to the front of `/cn zones` as the smallest job
    -- available, awarded the "a small remainder is a session" bonus, and
    -- emitted as a recommendation reading "1 of 1 left in this zone".
    --
    -- The quantity is right there on the same call this function already
    -- makes; it was being discarded. When a single criterion carries a real
    -- requirement, that requirement IS the denominator.
    if total == 1 then
        local _, _, criteriaCompleted, quantity, required =
            GetAchievementCriteriaInfo(achievementID, 1)

        if type(required) == "number" and required > 1 then
            return math.min(quantity or 0, required), required
        end

        return criteriaCompleted and 1 or 0, 1
    end

    for index = 1, total do
        local _, _, criteriaCompleted = GetAchievementCriteriaInfo(achievementID, index)

        if criteriaCompleted then
            done = done + 1
        end
    end

    return done, total
end

function Blizzard.GetAchievementTotals()
    if GetNumCompletedAchievements then
        local total, completed = GetNumCompletedAchievements(true)
        return total or 0, completed or 0
    end

    return 0, 0
end

------------------------------------------------------------
