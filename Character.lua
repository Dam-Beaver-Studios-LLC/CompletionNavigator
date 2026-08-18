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

function CN.GetCharacterKey()
    local name  = UnitName("player") or "Unknown"
    local realm = GetRealmName() or "UnknownRealm"

    return realm .. "-" .. name
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
    character.sex     = UnitSex("player")
    character.lastSeen = time()

    if UnitFactionGroup then
        character.faction = UnitFactionGroup("player")
    end

    if GetSpecialization and GetSpecializationInfo then
        local index = GetSpecialization()

        if index then
            local specID, specName = GetSpecializationInfo(index)

            character.specID   = specID
            character.specName = specName
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

            CN.character.specID   = specID
            CN.character.specName = specName

            DebugPrint("Specialization updated to " .. tostring(specName))
        end
    end
end)
