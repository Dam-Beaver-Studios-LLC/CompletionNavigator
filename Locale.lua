-- Locale.lua
-- Completion Navigator :: translated strings, and what happens when there is
-- no translation.
--
-- WHY IT IS BUILT THIS WAY.
--
-- The key IS the English string. `CN.L["Destination"]` in a client with no
-- German table returns "Destination", which is exactly right: a missing
-- translation shows English, never a blank label and never a raw identifier
-- like "NAV_DEST_LABEL". Every addon that has invented its own key namespace
-- has eventually shipped a screen reading "MISSING_KEY_47" to somebody.
--
-- That choice has one real cost, and it is worth stating rather than
-- discovering: changing the English wording of a string silently orphans
-- every translation of it. The lint in `cn.ps1 check` catches the reverse
-- case -- a locale file translating a key that no longer exists -- and the
-- untranslated-string report below catches this one, at runtime, on the
-- machine where it actually matters.
--
-- WHAT IS AND IS NOT TRANSLATED.
--
-- The framework covers everything. The bundled translations do not: they
-- cover the strings the player sees most, and the rest falls back to English
-- until somebody who speaks the language sends better. `/cn locale` says
-- exactly how far along that is rather than implying the addon is translated
-- when it is a quarter translated. Machine-translating the remainder to make
-- the number look better would produce a German player's first impression of
-- this addon being written by someone who does not speak German.

local ADDON_NAME, CN = ...

------------------------------------------------------------
-- THE TABLE
------------------------------------------------------------

CN.locales = CN.locales or {}

-- Recorded rather than counted: a key that was actually asked for and had no
-- translation is a real gap in this player's experience, which is a very
-- different list from every key in the addon.
CN.localeMisses = CN.localeMisses or {}

local active = {}

CN.L = setmetatable({}, {
    __index = function(_, key)
        if type(key) ~= "string" then
            return key
        end

        local translated = active[key]

        if translated then
            return translated
        end

        CN.localeMisses[key] = true

        return key
    end,

    -- Assigning into L would look like it worked and change nothing on the
    -- next reload. Refuse loudly instead.
    __newindex = function(_, key)
        error("CN.L is read-only; register strings with CN.RegisterLocale (" ..
            tostring(key) .. ")", 2)
    end,
})

function CN.ClientLocale()
    if GetLocale then
        local ok, value = pcall(GetLocale)

        if ok and value then
            return value
        end
    end

    return "enUS"
end

-- Locale files call this at load. Only the one matching the client is kept,
-- so a player running an English client pays nothing for the other eight
-- tables being in the package -- they are never merged into memory.
function CN.RegisterLocale(code, strings)
    if type(code) ~= "string" or type(strings) ~= "table" then
        return false
    end

    CN.locales[code] = true

    if code ~= CN.ClientLocale() then
        return false
    end

    local added = 0

    for key, value in pairs(strings) do
        if type(key) == "string" and type(value) == "string" and value ~= "" then
            active[key] = value
            added = added + 1
        end
    end

    return true, added
end

function CN.LocaleStats()
    local translated = 0

    for _ in pairs(active) do
        translated = translated + 1
    end

    local missing, sample = 0, {}

    for key in pairs(CN.localeMisses) do
        missing = missing + 1

        if #sample < 12 then
            table.insert(sample, key)
        end
    end

    table.sort(sample)

    return {
        locale     = CN.ClientLocale(),
        translated = translated,
        missing    = missing,
        sample     = sample,
        available  = CN.locales,
    }
end

------------------------------------------------------------
-- COMMAND
------------------------------------------------------------

CN:RegisterCommand{
    name    = "locale",
    args    = "[missing or export]",
    order   = 33,
    help    = "Which language the addon is using, and how much is translated.",
    handler = function(args)
        local Print = CN.Print

        local stats = CN.LocaleStats()

        args = string.lower(CN.Trim(args or ""))

        Print("Client language: |cffffff00" .. stats.locale .. "|r")

        if stats.locale == "enUS" or stats.locale == "enGB" then
            -- English is the source language, not an untranslated one. Saying
            -- "no translation available" to an English player would describe
            -- a problem that does not exist.
            Print("|cff999999The addon is written in English, so there is "
                .. "nothing to translate here.|r")
        elseif stats.translated == 0 then
            Print("|cff999999No translation table for this language yet. "
                .. "Everything shows in English, which is the intended "
                .. "fallback rather than a fault -- and "
                .. "|cffffff00/cn locale missing|r is the list a translator "
                .. "would start from.|r")
        else
            Print(stats.translated .. " strings translated.")
        end

        if args == "missing" then
            if stats.missing == 0 then
                Print("Nothing has fallen back to English yet this session.")
                return
            end

            Print(stats.missing .. " strings fell back to English this "
                .. "session:")

            for _, key in ipairs(stats.sample) do
                Print("  |cff999999" .. key .. "|r")
            end

            if stats.missing > #stats.sample then
                Print("  |cff999999... and "
                    .. (stats.missing - #stats.sample) .. " more.|r")
            end

            return
        end

        if stats.missing > 0 then
            Print("|cff999999" .. stats.missing .. " strings fell back to "
                .. "English this session. |cffffff00/cn locale missing|r "
                .. "lists them -- that list is exactly what a translator "
                .. "needs.|r")
        end

        if args == "export" then
            -- A PASTE-READY FILE, NOT A LIST TO RETYPE.
            --
            -- `/cn locale missing` names what fell back to English, which is
            -- the right diagnostic and the wrong deliverable: a translator
            -- then has to build the Lua themselves, and the barrier to
            -- helping should not include learning this addon's file format.
            local keys = {}

            for _, key in ipairs(CN.localeKeys or {}) do
                table.insert(keys, key)
            end

            table.sort(keys)

            Print("Paste this into Locales/" .. stats.locale .. ".lua and "
                .. "fill in the right-hand side:")

            for _, key in ipairs(keys) do
                Print('    ["' .. key .. '"] = "",')
            end

            Print("|cff999999" .. #keys .. " keys. Leave anything you are not "
                .. "sure of blank -- an empty string is ignored, and English "
                .. "is a better answer than a guess.|r")

            -- AND WHERE TO SEND IT.
            --
            -- The tool half of the translator workflow has existed since
            -- 0.39.0; the return path was never written down anywhere. A
            -- translator finished the work and then had to guess what to do
            -- with it, which is the point at which most people stop.
            Print("|cff999999When you are done, open an issue on the project's "
                .. "GitHub with the block pasted in, titled \"Translation: "
                .. stats.locale .. "\". TRANSLATING.md in the repository has "
                .. "the details.|r")

            return
        end

        local languages = {}

        for code in pairs(stats.available) do
            table.insert(languages, code)
        end

        table.sort(languages)

        Print("|cff999999Bundled: " .. table.concat(languages, ", ") .. ".|r")
    end,
}

return CN.L
