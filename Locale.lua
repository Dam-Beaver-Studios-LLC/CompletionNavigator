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

-- DELIBERATELY NOT MEMOISED INTO THE TABLE ITSELF.
--
-- Every lookup here is a metamethod call rather than a hash hit, and 0.54.0's
-- performance pass considered `rawset`-ing the resolved value into the outer
-- table so the metamethod would run once per string per session.
--
-- It does not go in, because `__index` only fires for a key the table does
-- not have -- and neither does `__newindex`. Populating the table would
-- therefore silently disable the read-only guard below for exactly the keys
-- the addon uses most, and that guard exists because assigning into `CN.L`
-- looks like it worked and is gone on the next reload.
--
-- Measured, the whole saving was under a hundredth of a millisecond across
-- the busiest path in the addon. A real protection is worth more than that.
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

            -- A key that fell back to English before its table arrived is not
            -- missing any more.
            CN.localeMisses[key] = nil
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

    -- How many strings are in scope at all, so the report can say what it
    -- is a report ABOUT rather than leaving the reader to assume it covers
    -- everything the addon prints.
    local total = 0

    for _ in pairs(CN.localeKeys or {}) do
        total = total + 1
    end

    return {
        locale     = CN.ClientLocale(),
        translated = translated,
        missing    = missing,
        sample     = sample,
        total      = total,
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

        Print("Client language: |cffffc74f" .. stats.locale .. "|r")

        -- ENGLISH, ASKED ONCE. 0.80.0. The branch below already knew this and
        -- the fallback tally two screens down did not, so an English player
        -- was told there was nothing to translate and then, four lines later,
        -- that N strings had "fallen back to English" and that the list "is
        -- exactly what a translator needs". Both from the same command.
        --
        -- Every English lookup is a recorded miss BY CONSTRUCTION:
        -- `Locales/enUS.lua` registers an empty table, so `CN.L[key]` never
        -- finds a translation and stamps `localeMisses` on the way past. The
        -- number was real; it just did not mean what the sentence said.
        local english = (stats.locale == "enUS" or stats.locale == "enGB")

        if english then
            -- English is the source language, not an untranslated one. Saying
            -- "no translation available" to an English player would describe
            -- a problem that does not exist.
            Print("|cff8a8f96The addon is written in English, so there is "
                .. "nothing to translate here.|r")
        elseif stats.translated == 0 then
            Print("|cff8a8f96No translation table for this language yet. "
                .. "Everything shows in English, which is the intended "
                .. "fallback rather than a fault" .. CN.DASH .. "and "
                .. "|cffffc74f/cn locale missing|r is the list a translator "
                .. "would start from.|r")
        else
            Print(stats.translated .. " strings translated.")
        end

        -- WHAT IS IN SCOPE, SAID PLAINLY.
        --
        -- `CN.localeKeys` is 33 strings and internally consistent: every key
        -- has a call site, nothing is orphaned, and `/cn locale missing`
        -- names exactly what fell back. What it does NOT cover is the several
        -- hundred chat lines that never go through CN.L at all -- so a
        -- translator who completed every key here would still be looking at a
        -- largely English addon, and nothing on this screen said so.
        --
        -- Stated rather than fixed: routing every line through CN.L is a
        -- release of its own, and a promise the addon cannot keep is worse
        -- than a limit it admits to.
        Print("|cff8a8f96Scope: the " .. (stats.total or 0) .. " recurring "
            .. "strings this addon routes through its locale table" .. CN.DASH .. "the "
            .. "confidence and status words, the tab names, the counters. "
            .. "Most one-off chat lines are still English and are not in "
            .. "this count.|r")

        if args == "missing" then
            -- AND THE LIST ITSELF. 0.80.0. On an English client every key is
            -- a "miss", so this printed the addon's entire locale table as
            -- though it were untranslated work waiting for somebody.
            if english then
                Print("|cff8a8f96Every string here is already in the client's "
                    .. "language. |cffffc74f/cn locale export|r produces the "
                    .. "starting file for another one.|r")
                return
            end

            if stats.missing == 0 then
                Print("Nothing has fallen back to English yet this session.")
                return
            end

            Print(stats.missing .. " strings fell back to English this "
                .. "session:")

            for _, key in ipairs(stats.sample) do
                CN.PrintLine("  |cff8a8f96" .. key .. "|r")
            end

            if stats.missing > #stats.sample then
                Print("  |cff8a8f96... and "
                    .. (stats.missing - #stats.sample) .. " more.|r")
            end

            return
        end

        if stats.missing > 0 and not english then
            Print("|cff8a8f96" .. stats.missing .. " strings fell back to "
                .. "English this session. |cffffc74f/cn locale missing|r "
                .. "lists them" .. CN.DASH .. "that list is exactly what a translator "
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
                CN.PrintLine('    ["' .. key .. '"] = "",')
            end

            Print("|cff8a8f96" .. #keys .. " keys. Leave anything you are not "
                .. "sure of blank" .. CN.DASH .. "an empty string is ignored, and English "
                .. "is a better answer than a guess.|r")

            -- AND WHERE TO SEND IT.
            --
            -- The tool half of the translator workflow has existed since
            -- 0.39.0; the return path was never written down anywhere. A
            -- translator finished the work and then had to guess what to do
            -- with it, which is the point at which most people stop.
            Print("|cff8a8f96When you are done, open an issue on the project's "
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

        Print("|cff8a8f96Bundled: " .. table.concat(languages, ", ") .. ".|r")
    end,
}

return CN.L
