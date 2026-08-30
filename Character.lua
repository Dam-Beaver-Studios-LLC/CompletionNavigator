-- Character.lua
-- Completion Navigator :: per-character profiles.
--
-- Warband-aware logic depends on knowing what every character can do, not
-- just the one currently logged in. Every field written here is persisted
-- so an offline character can still be evaluated as a candidate for an
-- objective.

local ADDON_NAME, CN = ...

local DebugPrint = CN.DebugPrint

------------------------------------------------------------
-- IDENTITY
------------------------------------------------------------

-- ONE PLACE THAT KNOWS THE FORMAT. 0.62.0.
--
-- The key was assembled by hand in more than one file, and the second copy
-- had realm and name the wrong way round -- a key that matches nothing, in a
-- function whose own comment described the symptom as already fixed. The
-- format is a rule, and a rule written down twice is a rule that drifts.
function CN.CharacterKeyFor(realm, name)
    return tostring(realm or "UnknownRealm") .. "-" .. tostring(name or "Unknown")
end

function CN.GetCharacterKey()
    return CN.CharacterKeyFor(GetRealmName(), UnitName("player"))
end

------------------------------------------------------------
-- PROFILE
------------------------------------------------------------

function CN.InitializeCharacter()
    local key = CN.GetCharacterKey()

    CN.db.characters[key] = CN.db.characters[key] or {}

    local character = CN.db.characters[key]

    character.name    = UnitName("player")
    character.realm   = GetRealmName()
    character.class   = select(2, UnitClass("player"))
    character.race    = select(2, UnitRace("player"))
    character.level   = UnitLevel("player")
    character.lastSeen = time()

    if UnitFactionGroup then
        character.faction = UnitFactionGroup("player")
    end

    if GetSpecialization and GetSpecializationInfo then
        local index = GetSpecialization()

        if index then
            -- THE ID, NOT THE WORD. 0.82.0.
            --
            -- `character.sex` had no reader anywhere and is gone. `specName`
            -- had one -- `Warband.Roster()` -- which nothing then consumed,
            -- and it is a LOCALIZED STRING persisted per character: the exact
            -- freeze migrations 4, 5, 14, 15, 16 and 18 were each written to
            -- end, waiting to show a German main's "Vergeltung" beside an
            -- alt's "Retribution" on the day something read it.
            --
            -- The id is stable, is one number, and the client will translate
            -- it on demand -- so the roster shows the spec now, in the
            -- reader's own language, which is what the field was for.
            character.specID = (GetSpecializationInfo(index))
        end
    end

    CN.characterKey = key
    CN.character    = character

    DebugPrint("Character initialized: " .. tostring(key))
end

------------------------------------------------------------
-- REFRESH
------------------------------------------------------------

function CN.TouchCharacter()
    if not CN.character then
        return
    end

    CN.character.level    = UnitLevel("player")
    CN.character.lastSeen = time()
end

------------------------------------------------------------
-- WARBAND HELPERS
------------------------------------------------------------

-- Iterates every known character profile: for key, character in CN.Characters()
function CN.Characters()
    if not CN.db or not CN.db.characters then
        return function() return nil end
    end

    return pairs(CN.db.characters)
end

function CN.GetCharacterCount()
    return CN.CountKeys(CN.db and CN.db.characters)
end

------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------

CN:OnLogin(function()
    CN.InitializeCharacter()
end)

CN:OnLogout(function()
    CN.TouchCharacter()
end)

CN:RegisterEvent("PLAYER_LEVEL_UP", function(event, newLevel)
    if CN.character then
        CN.character.level    = newLevel
        CN.character.lastSeen = time()
    end

    DebugPrint("Character level updated to " .. tostring(newLevel))
end)

CN:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED", function(event, unit)
    if unit ~= "player" then
        return
    end

    if CN.character and GetSpecialization and GetSpecializationInfo then
        local index = GetSpecialization()

        if index then
            local specID, specName = GetSpecializationInfo(index)

            CN.character.specID = specID

            DebugPrint("Specialization updated to " .. tostring(specName))
        end
    end
end)
