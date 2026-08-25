-- Core.lua
-- Completion Navigator :: namespace, logging, and registries.
--
-- Load order: FIRST. Nothing may be added above this file.
--
-- This file intentionally contains no gameplay logic. It exists so that
-- every other file can register itself declaratively:
--
--   CN:RegisterCommand{ ... }
--   CN:RegisterEvent("EVENT_NAME", handler)
--   CN:RegisterModule("Quests")
--
-- That makes the codebase append-only for tooling purposes: adding a
-- command or an event never requires editing a dispatcher.

local ADDON_NAME, CN = ...

_G.CompletionNavigator = CN

CN.name        = ADDON_NAME
CN.version     = "0.64.0"
CN.dbVersion   = 18

-- Where the addon's own textures live. Referenced by the .toc IconTexture
-- line and the minimap button.
CN.MEDIA_PATH  = "Interface\\AddOns\\CompletionNavigator\\Media\\"

------------------------------------------------------------
-- REGISTRIES
------------------------------------------------------------

CN.modules     = {}   -- [name]  = module table
CN.commands    = {}   -- [name]  = command definition
CN.commandList = {}   -- ordered list of command definitions (for /cn help)
CN.eventTable  = {}   -- [event] = { handler, handler, ... }
CN.initHooks   = {}   -- functions run on ADDON_LOADED, after the DB exists
CN.loginHooks  = {}   -- functions run on PLAYER_LOGIN
CN.logoutHooks = {}   -- functions run on PLAYER_LOGOUT

------------------------------------------------------------
-- OUTPUT
------------------------------------------------------------

-- THE ADDON'S NAME ONCE PER ANSWER, NOT ONCE PER LINE.
--
-- Every line went out with "Completion Navigator: " in front of it, and this
-- addon answers in blocks: `/cn next` is four to six lines, `/cn help` is
-- twenty, `/cn uistatus` is twelve. Twenty-two characters of chrome per line
-- turned every answer into a wall of the addon's own name, in a chat frame
-- the player is also using for the game.
--
-- The headline carries the name. Continuations are indented under it, which
-- is what a block of related lines has looked like in every medium for four
-- hundred years, and costs three characters instead of twenty-two.
local PREFIX       = "|cff5dd2fbCompletion Navigator|r: "
local CONTINUATION = "   "
local DEBUG_PREFIX = "|cff8a8f96Completion Navigator Debug|r: "

function CN.Print(message)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. tostring(message))
end

-- A continuation of the line above: same answer, no repeated identity.
function CN.PrintLine(message)
    DEFAULT_CHAT_FRAME:AddMessage(CONTINUATION .. tostring(message))
end

-- The common shape: one headline and its detail. Saves every caller from
-- deciding which of the two to use, and makes the block structure visible in
-- the source as well as on screen.
function CN.PrintBlock(headline, lines)
    CN.Print(headline)

    for _, line in ipairs(lines or {}) do
        CN.PrintLine(line)
    end
end

function CN.DebugPrint(message)
    if CN.db and CN.db.settings and CN.db.settings.debug then
        DEFAULT_CHAT_FRAME:AddMessage(DEBUG_PREFIX .. tostring(message))
    end
end

-- IS ANYBODY LISTENING? 0.63.0.
--
-- `DebugPrint` checks the setting AFTER the caller has already built the
-- string, because Lua evaluates arguments at the call site. The hot one is
-- `CN.InvalidateCandidates`, which runs once per subscribed event -- and the
-- subscribed set includes `QUEST_LOG_UPDATE`, `CRITERIA_UPDATE` and
-- `UPDATE_FACTION`, all firehoses while questing. Four concatenations and
-- three intermediate strings, tens of times a second, for output nobody can
-- see.
--
-- Callers on a hot path ask first and build second.
function CN.Debugging()
    return (CN.db and CN.db.settings and CN.db.settings.debug) and true or false
end

local Print      = CN.Print
local DebugPrint = CN.DebugPrint

-- Colorized yes/no used throughout the completion output.
function CN.YesNo(value)
    -- Sentence case, not shouting. "YES" beside sentence-case labels was the
    -- loudest thing in the addon's output and it was answering the smallest
    -- questions.
    if value then
        return CN.Good("yes")
    end

    return CN.Bad("no")
end

------------------------------------------------------------
-- MODULE REGISTRY
------------------------------------------------------------

-- Returns a table that a module file can hang its functions on.
-- Calling it twice with the same name returns the same table, so module
-- files can be split later without breaking references.
function CN:RegisterModule(name)
    if CN.modules[name] then
        return CN.modules[name]
    end

    local module = {
        name   = name,
        Print  = CN.Print,
        Debug  = CN.DebugPrint,
    }

    CN.modules[name] = module

    return module
end

function CN:GetModule(name)
    return CN.modules[name]
end

------------------------------------------------------------
-- COMMAND REGISTRY
------------------------------------------------------------

-- definition = {
--     name    = "quest",              -- required, lowercase
--     aliases = { "q" },              -- optional
--     args    = "<questID>",          -- optional, shown in /cn help
--     help    = "Check a quest.",     -- optional, shown in /cn help
--     order   = 50,                   -- optional sort weight for help
--     handler = function(args) end,   -- required
-- }
function CN:RegisterCommand(definition)
    if type(definition) ~= "table" then
        return
    end

    if not definition.name or type(definition.handler) ~= "function" then
        Print("Internal error: malformed command registration.")
        return
    end

    definition.name  = string.lower(definition.name)
    definition.order = definition.order or 100

    -- A NAME CLAIMED TWICE IS A COMMAND THAT DOES SOMETHING ELSE.
    --
    -- Registration used to overwrite silently, so whichever file loaded last
    -- won and `/cn help` went on describing the loser. `/cn zones` was
    -- registered by Loremaster as a command and, further down the same file,
    -- as an ALIAS of `/cn loremaster` -- so it printed the quest-completion
    -- report while the help text, and the store page, described the zone
    -- ranking. `/cn show` was claimed by both the window and the filters.
    --
    -- Recorded rather than refused: refusing would change which command wins
    -- at load time, and the answer to a collision is to fix it, not to
    -- reshuffle it. `/cn selftest` names them.
    CN.commandCollisions = CN.commandCollisions or {}

    local function Claim(name, kind)
        local held = CN.commands[name]

        if held and held ~= definition then
            table.insert(CN.commandCollisions, {
                name  = name,
                kind  = kind,
                from  = held.name,
                to    = definition.name,
            })
        end

        CN.commands[name] = definition
    end

    Claim(definition.name, "name")

    if definition.aliases then
        for _, alias in ipairs(definition.aliases) do
            Claim(string.lower(alias), "alias")
        end
    end

    table.insert(CN.commandList, definition)
end

------------------------------------------------------------
-- EVENT REGISTRY
------------------------------------------------------------

-- Multiple files may register the same event. Every handler is called
-- with (event, ...) in registration order.
function CN:RegisterEvent(event, handler)
    if type(event) ~= "string" or type(handler) ~= "function" then
        return
    end

    if not CN.eventTable[event] then
        CN.eventTable[event] = {}
    end

    table.insert(CN.eventTable[event], handler)

    -- Events.lua may not have created the frame yet; if it has, register
    -- with the client immediately.
    if CN.eventFrame then
        CN.RegisterWithClient(event)
    end
end

-- ONE BAD EVENT NAME MUST NOT BE A LUA ERROR ON EVERY LOGIN.
--
-- The client throws on an unknown event rather than ignoring it, and this
-- addon registers around forty of them across thirty files. A single typo --
-- or an invented name that reads plausibly, which is what happened with
-- `NEW_TAXI_NODE` -- produced an error box at load for every player.
--
-- Refusing to register is the correct outcome; erroring is not. The name is
-- kept so `/cn errors` can name it, because an event silently doing nothing
-- is its own kind of invisible.
CN.rejectedEvents = CN.rejectedEvents or {}

function CN.RegisterWithClient(event)
    if not CN.eventFrame or not CN.eventFrame.RegisterEvent then
        return false
    end

    local ok, err = pcall(CN.eventFrame.RegisterEvent, CN.eventFrame, event)

    if not ok then
        CN.rejectedEvents[event] = tostring(err)

        local errors = CN.modules and CN.modules.Errors

        if errors and errors.Record then
            pcall(errors.Record, "RegisterEvent",
                "the client does not have an event called " .. tostring(event))
        end

        return false
    end

    return true
end

------------------------------------------------------------
-- LIFECYCLE HOOKS
------------------------------------------------------------

function CN:OnInitialize(handler)
    table.insert(CN.initHooks, handler)
end

function CN:OnLogin(handler)
    table.insert(CN.loginHooks, handler)
end

function CN:OnLogout(handler)
    table.insert(CN.logoutHooks, handler)
end

function CN.RunHooks(list, ...)
    for _, handler in ipairs(list) do
        local ok, err = pcall(handler, ...)

        if not ok then
            CN.PrintLine("Error: " .. tostring(err))
        end
    end
end

------------------------------------------------------------
-- SHARED UTILITIES
------------------------------------------------------------

-- Recursively fills missing keys in destination from source.
function CN.CopyDefaults(source, destination)
    if type(destination) ~= "table" then
        destination = {}
    end

    for key, value in pairs(source) do
        if type(value) == "table" then
            destination[key] = CN.CopyDefaults(value, destination[key])
        elseif destination[key] == nil then
            destination[key] = value
        end
    end

    return destination
end

-- Normalizes user input into a positive integer ID, or nil.
function CN.ToID(text)
    local id = tonumber(text)

    if not id then
        return nil
    end

    id = math.floor(id)

    if id <= 0 then
        return nil
    end

    return id
end

function CN.CountKeys(tbl)
    local count = 0

    if type(tbl) ~= "table" then
        return 0
    end

    for _ in pairs(tbl) do
        count = count + 1
    end

    return count
end

-- 1234567 -> "1,234,567".
--
-- Reputation numbers are the one place this addon prints figures large
-- enough to be misread, and "42000 to go" reads as a different order of
-- magnitude than "42,000 to go" at a glance.
-- ONE GRAMMAR FOR "MEASURED" VERSUS "ESTIMATED".
--
-- The addon prints a lot of numbers and, until 0.43.0, said how much it
-- trusted each one in a slightly different way every time: "(estimated)"
-- here, "time unknown" there, a grey parenthetical somewhere else. A reader
-- cannot learn three conventions, so in practice they learn none and treat
-- every number as equally solid -- which is the opposite of what all that
-- careful hedging was for.
--
-- Three states, one shape, used everywhere:
--
--   measured  -- from this player's own data, printed plain
--   estimated -- a real calculation on a seeded input, marked
--   unknown   -- not knowable, and the number is not printed at all
CN.confidence = {
    MEASURED  = "measured",
    ESTIMATED = "estimated",
    UNKNOWN   = "unknown",
}

-- Wraps a value in the convention. Returns the text to print.
function CN.WithConfidence(text, level)
    -- Translated. This is the convention every number in the addon is
    -- wrapped in, so leaving it in English left the single most repeated
    -- qualifier a non-English player sees untranslated -- while the word sat
    -- translated in all ten locale files.
    --
    -- CN.L is not available while Core.lua is loading, so the lookup happens
    -- here at call time rather than at file scope.
    if level == CN.confidence.UNKNOWN or text == nil then
        return "|cff8a8f96" .. CN.L["unknown"] .. "|r"
    end

    if level == CN.confidence.ESTIMATED then
        return text .. " |cff8a8f96(" .. CN.L["estimated"] .. ")|r"
    end

    return text
end

-- Convenience for the common case: a boolean "was this measured".
function CN.ConfidenceFor(measured)
    return measured and CN.confidence.MEASURED or CN.confidence.ESTIMATED
end

-- LANGUAGE COMPATIBILITY.
--
-- Everything in this block exists because the game and the test suite run
-- different languages. WoW is Lua 5.1; the suite is 5.4. Anything that
-- behaves differently between them is a defect waiting for a player to find,
-- and 0.43.1 shipped after exactly that happened -- see CN.Atan2 below.
--
-- The rule these enforce is simple: if a construct means two things, the
-- addon uses neither directly. It uses one of these.

-- unpack moved to table.unpack in 5.2. The game still has the global.
CN.Unpack = rawget(table, "unpack") or unpack

-- MODULO ON NEGATIVE NUMBERS.
--
-- `math.fmod` truncates toward zero and `%` floors, so they disagree in sign
-- for negative operands -- and bearings are negative half the time. 5.1 and
-- 5.4 also differ in whether math.fmod accepts floats cleanly.
--
-- This is the floored version, which is what every angle in this addon wants:
-- the result carries the sign of the divisor, so wrapping an angle into a
-- range never produces the wrong half of the circle.
function CN.Mod(value, divisor)
    if not value or not divisor or divisor == 0 then
        return 0
    end

    return value - (math.floor(value / divisor) * divisor)
end

-- THE SINGLE MOST IMPORTANT FUNCTION IN THIS FILE.
--
-- World of Warcraft runs Lua 5.1. The offline test suite runs Lua 5.4. In 5.3
-- and later, `math.atan(y, x)` is the two-argument arctangent; in 5.1 it is
-- the one-argument one and the SECOND ARGUMENT IS SILENTLY IGNORED.
--
--     Lua 5.4:  math.atan(1, 0) == 1.5707963  (90 degrees -- correct)
--     Lua 5.1:  math.atan(1, 0) == 0.7853981  (45 degrees -- atan(1))
--
-- No error. No warning. A number that looks entirely reasonable.
--
-- Every bearing this addon computed IN GAME from 0.19.0 to 0.43.0 was
-- therefore atan(dx), with the north-south component of the direction thrown
-- away -- which is why the arrow never pointed behind the player, and why
-- "it does not turn around when I walk past the destination" was reported
-- three times and "fixed" three times against a test suite where the code was
-- genuinely correct.
--
-- This is the eighth instance in this project of the same class of defect:
-- the test environment modelling the world more simply, or differently, than
-- the world. It is the worst one, because the difference was not in a stub I
-- wrote -- it was in the language itself.
--
-- Use CN.Atan2 for every bearing. Never math.atan with two arguments.
--
-- Assigned rather than wrapped: a wrapper would contain the two-argument call
-- itself, and the suite's rule against that expression is worth more than the
-- one function call it costs. Where math.atan2 exists -- the game, and every
-- Lua before 5.4 -- it is used. Where it does not, math.atan IS the
-- two-argument form, so passing both through is correct.
CN.Atan2 = math.atan2 or math.atan

-- THE SELF-TEST REGISTRY LIVES HERE, NOT IN THE MODULE THAT USES IT.
--
-- It was in Modules/SelfTest.lua, which meant any module registering a check
-- had to load after it -- an invisible constraint that held in the .toc I
-- maintain by hand and broke the moment the toolkit scaffolded the tree in a
-- different order. The failure was a runtime error on load, in a module that
-- has nothing to do with self-tests.
--
-- A registry belongs where everything can see it. The checks stay where they
-- make sense.
CN.selfTests = CN.selfTests or {}

function CN.RegisterSelfTest(definition)
    if type(definition) ~= "table" or type(definition.run) ~= "function" then
        return false
    end

    definition.order = definition.order or (#CN.selfTests + 1)

    table.insert(CN.selfTests, definition)

    return true
end

-- AN EVENT THAT FIRES MANY TIMES A SECOND, ANSWERED ONCE.
--
-- `UPDATE_FACTION` fires on nearly every reputation tick -- this addon says
-- so in three separate files -- and two handlers used it to bump a
-- generation counter. `CN.decoratorGeneration` is the ONE thing that defeats
-- the unchanged-provider shortcut, so bumping it on every tick meant that
-- while a player was questing, i.e. gaining reputation continuously, the
-- shortcut was permanently off and every provider re-decorated on every pass:
-- the measured 0.007 ms to 0.221 ms regression the shortcut exists to remove,
-- back in full, plus a five-decorator sweep over every candidate.
--
-- LEADING EDGE PLUS A TRAILING RUN, not a plain throttle. The first tick is
-- answered immediately, because the common case is one event and a plain
-- throttle would delay it; a burst collapses to one more run at the end,
-- because the LAST tick of a burst is the one that crossed a rank.
--
-- Returns whether the work ran now, so a caller that needs to know can tell.
local debounced = {}

function CN.Debounce(key, seconds, work)
    if type(key) ~= "string" or type(work) ~= "function" then
        return false
    end

    local now   = (GetTime and GetTime()) or (time and time()) or 0
    local state = debounced[key]

    if state and (now - state.ranAt) < seconds then
        -- Inside the window. One trailing run is enough however many events
        -- arrive, so a pending timer is never replaced by a second one.
        if not state.pending and C_Timer and C_Timer.After then
            state.pending = true

            -- The timer's closure holds THIS state table, and
            -- `CN.ForgetDebounces` replaces the whole registry -- so without
            -- this check a forgotten timer would fire against an orphan while
            -- a fresh state, seeing `pending = false`, scheduled a second
            -- one: the work would run twice inside one window, which is the
            -- single thing this function exists to prevent.
            C_Timer.After(seconds - (now - state.ranAt), function()
                if debounced[key] ~= state then
                    return
                end

                state.pending = false
                state.ranAt   = (GetTime and GetTime()) or (time and time()) or 0

                -- `CN.Guard` if Errors.lua has loaded, which it has by the
                -- time any event fires; pcall otherwise, because a callback
                -- that throws inside a timer is invisible.
                if CN.Guard then
                    CN.Guard("Debounce:" .. key, work)
                else
                    pcall(work)
                end
            end)
        end

        return false
    end

    debounced[key] = { ranAt = now, pending = false }

    work()

    return true
end

-- For the tests, and for a reload: a stale timestamp would swallow the first
-- event of a new session.
function CN.ForgetDebounces()
    debounced = {}
end

-- HOW OLD A STORED NUMBER IS, IN WORDS A PLAYER USES.
--
-- `Session.FormatDuration` is the right shape for "this will take 40m" and
-- the wrong one for "this was read four days ago", which it renders as
-- "97h 12m". Anything the addon keeps between sessions is measured in days,
-- so this stops at days and rounds toward the coarser unit: the point of the
-- line is "is this stale", not "how stale to the minute".
--
-- Returns nil rather than a word when there is no stamp, so a caller can tell
-- "never" from "just now" -- they are different answers and the second is a
-- lie about the first.
function CN.Ago(stamp, now)
    stamp = tonumber(stamp)

    if not stamp or stamp <= 0 then
        return nil
    end

    now = tonumber(now) or (time and time()) or 0

    local seconds = now - stamp

    -- A clock that moved backwards -- a timezone change, a client restart
    -- across one -- must not print a negative age.
    if seconds < 60 then
        return "just now"
    end

    if seconds < 3600 then
        return math.floor(seconds / 60) .. "m ago"
    end

    if seconds < 86400 then
        return math.floor(seconds / 3600) .. "h ago"
    end

    local days = math.floor(seconds / 86400)

    return days .. (days == 1 and " day ago" or " days ago")
end

function CN.Comma(number)
    number = tonumber(number)

    if not number then
        return "0"
    end

    local negative = number < 0

    local text = tostring(math.floor(math.abs(number) + 0.5))

    local formatted = text

    while true do
        local replaced

        formatted, replaced = string.gsub(formatted, "^(%d+)(%d%d%d)", "%1,%2")

        if replaced == 0 then
            break
        end
    end

    return (negative and "-" or "") .. formatted
end

-- A text progress bar, for chat.
--
-- Deliberately only ever called with a fraction the client vouched for.
-- There is no overload that takes "roughly" -- a bar is the most confident
-- shape information can take, and the addon does not spend that confidence
-- on a guess.
function CN.ProgressBar(fraction, width)
    width = width or 20

    if type(fraction) ~= "number" then
        return string.rep("-", width)
    end

    if fraction < 0 then fraction = 0 end
    if fraction > 1 then fraction = 1 end

    local filled = math.floor(fraction * width + 0.5)

    -- A FULL BAR IS A CLAIM, AND ROUNDING MUST NOT MAKE IT. 0.61.0.
    --
    -- At width 20 anything from 0.975 up rounded to twenty filled cells, so
    -- an achievement 39 of 40 done drew the same bar as one that was finished
    -- -- in a list whose whole job is telling you what is still outstanding.
    -- Same at the bottom: 0.024 drew an empty bar for real progress.
    if filled >= width and fraction < 1 then
        filled = width - 1
    end

    if filled <= 0 and fraction > 0 then
        filled = 1
    end

    return string.rep("=", filled) .. string.rep("-", width - filled)
end

-- A COMPLETION PERCENTAGE THAT DOES NOT LIE AT EITHER END.
--
-- Four places rendered their own, and every one of them rounded: 999 of
-- 1,000 printed "100%" next to a row that was still on the outstanding list,
-- and 1 of 400 printed "0%" for work already done. Both are the addon
-- contradicting itself on the same line, and both are exactly the cases a
-- completionist notices, because the last percent is the part they are here
-- for.
--
-- Round normally in the middle; clamp away from 100 and 0 at the ends.
-- `decimals` defaults to 0.
function CN.PercentText(fraction, decimals)
    if type(fraction) ~= "number" then
        return "--%"
    end

    decimals = decimals or 0

    if fraction < 0 then fraction = 0 end
    if fraction > 1 then fraction = 1 end

    local scale   = 10 ^ decimals
    local percent = math.floor(fraction * 100 * scale + 0.5) / scale

    if percent >= 100 and fraction < 1 then
        percent = 100 - (1 / scale)
    end

    if percent <= 0 and fraction > 0 then
        percent = 1 / scale
    end

    return string.format("%." .. decimals .. "f%%", percent)
end

-- "1 piece(s) left" IS WHAT AN UNFINISHED SENTENCE LOOKS LIKE.
--
-- Twenty-odd lines across the addon wrote "(s)" rather than deciding, and the
-- ones a player reads most are the worst of them -- "3 piece(s) left" is on
-- the row that is supposed to persuade them the set is nearly done. The
-- debug-only ones can stay lazy; the ones a player sees cannot.
--
-- `CN.Count(3, "piece")` -> "3 pieces"
-- `CN.Count(1, "piece")` -> "1 piece"
-- `CN.Count(2, "entry", "entries")` for the irregulars.
function CN.Count(number, singular, plural)
    number = tonumber(number) or 0

    local word = singular

    if number ~= 1 then
        word = plural or (singular .. "s")
    end

    return CN.Comma(number) .. " " .. word
end

-- The word alone, where the caller has already written the number (a
-- coloured count, usually).
-- `CN.Pluralize(3, "")` is "s" and `CN.Pluralize(1, "")` is "" -- which is
-- what twenty-two call sites were writing by hand as
-- `(n == 1 and "" or "s")`, each of them a place the next grammar change
-- would have had to find. 0.64.0.
function CN.Pluralize(number, singular, plural)
    if (tonumber(number) or 0) == 1 then
        return singular
    end

    return plural or (singular .. "s")
end

-- THE CLIENT'S TOKENS ARE FOR CODE. THE CLIENT'S NAMES ARE FOR PLAYERS.
--
-- `UnitClass` and `UnitRace` return a localized name AND an uppercase token,
-- and the token is what everything in this addon stores, because a token is
-- stable and a name is not. That is correct -- and it means anything that
-- prints one is printing "class only: WARRIOR, PALADIN" at somebody.
--
-- The client keeps the mapping back. `LOCALIZED_CLASS_NAMES_MALE` covers the
-- classes; races come back from `C_CreatureInfo`. Where neither answers, the
-- token is title-cased rather than shouted, which is wrong in a small way
-- instead of a loud one.
-- Built once, from the client, in whatever locale it is running in.
--
-- `C_CreatureInfo.GetRaceInfo` hands back `clientFileString` (the token this
-- addon stores) alongside `raceName` (what a player calls it), so the map is
-- read out of the game rather than hard-coded -- a hard-coded race table goes
-- stale on the next allied race, and the token is the part that must not.
--
-- The scan is bounded and the gaps in the id space are ordinary; it runs at
-- most once per session and only when something actually needs to print a
-- race.
CN.raceScanCeiling = 100

local raceNames

function CN.RaceNamesByToken()
    if raceNames then
        return raceNames
    end

    raceNames = {}

    if not C_CreatureInfo or not C_CreatureInfo.GetRaceInfo then
        return raceNames
    end

    for id = 1, CN.raceScanCeiling do
        local ok, info = pcall(C_CreatureInfo.GetRaceInfo, id)

        if ok and type(info) == "table"
            and info.clientFileString and info.raceName then

            raceNames[string.upper(info.clientFileString)] = info.raceName
        end
    end

    return raceNames
end

-- For the harness, and for anything that changes locale mid-session.
function CN.ForgetRaceNames()
    raceNames = nil
end

-- Alliance and Horde, in the player's language.
--
-- `UnitFactionGroup` returns an English token like every other one, and it
-- was printed raw beside a class run through `CN.TokenLabel` -- one localized
-- word and one untranslated token in the same seven characters. The client
-- keeps both names in globals it has always had. 0.64.0.
CN.factionGlobals = {
    Alliance = "FACTION_ALLIANCE",
    Horde    = "FACTION_HORDE",
    Neutral  = "FACTION_STANDING_LABEL4",
}

function CN.FactionLabel(token)
    if type(token) ~= "string" or token == "" then
        return ""
    end

    local global = CN.factionGlobals[token]

    if global and _G[global] and _G[global] ~= "" then
        return _G[global]
    end

    return token
end

function CN.TokenLabel(token)
    if type(token) ~= "string" or token == "" then
        return tostring(token)
    end

    -- Class tokens are uppercase and race tokens are not ("NightElf"), so
    -- both maps are keyed uppercase and both lookups normalize. Getting this
    -- wrong is silent: the fall-through below produces something that reads
    -- almost right, which is the worst kind of wrong to debug.
    local upper = string.upper(token)

    local classes = _G.LOCALIZED_CLASS_NAMES_MALE

    if type(classes) == "table" and classes[upper] then
        return classes[upper]
    end

    local races = CN.RaceNamesByToken()

    if races[upper] then
        return races[upper]
    end

    -- Title case from a SHOUTED_TOKEN, underscores to spaces.
    local words = {}

    for word in string.gmatch(token, "[^_]+") do
        table.insert(words,
            string.upper(string.sub(word, 1, 1))
                .. string.lower(string.sub(word, 2)))
    end

    if #words == 0 then
        return token
    end

    return table.concat(words, " ")
end

-- "a, b and c" -- the shape a person writes, from the shape code holds.
-- Every caller that used `table.concat(list, ", ")` on something a player
-- reads was producing a list and calling it a sentence.
function CN.Series(list, conjunction)
    if type(list) ~= "table" or #list == 0 then
        return ""
    end

    if #list == 1 then
        return tostring(list[1])
    end

    conjunction = conjunction or "and"

    if #list == 2 then
        return tostring(list[1]) .. " " .. conjunction .. " " .. tostring(list[2])
    end

    local head = {}

    for index = 1, #list - 1 do
        table.insert(head, tostring(list[index]))
    end

    return table.concat(head, ", ") .. " " .. conjunction .. " "
        .. tostring(list[#list])
end

-- A RESULT HELD AGAINST A GENERATION.
--
-- The addon has three of these written by hand already -- the shortlist
-- cache, the report cache, the route cache -- and every one of them is the
-- same six lines: hold the answer, hold the generation it was built at,
-- rebuild when they differ.
--
-- The tabs are the reason this one exists. The Collections and Scans tabs
-- call `Summary()` on eight collection modules on every two-second refresh,
-- and each of those walks its whole store to produce two integers that cannot
-- have changed unless the player collected something -- which fires an event
-- the addon already subscribes to. Measured at retail scale: 3.28 ms and
-- 4.40 ms per refresh, every two seconds, for the life of the window.
--
-- `build` is called only when the generation has moved. A generation of nil
-- means "do not cache this", which is how a caller opts out without a branch.
local memos = {}

function CN.Memo(key, generation, build)
    if generation == nil then
        return build()
    end

    local held = memos[key]

    if held and held.generation == generation then
        return held.value
    end

    local value = build()

    memos[key] = { generation = generation, value = value }

    return value
end

function CN.ForgetMemos(key)
    if key then
        memos[key] = nil
    else
        memos = {}
    end
end

-- Bumped by anything that can change what a collection Summary answers.
-- Maintained in Scoring.lua, next to the other generation counters, so there
-- is one place to look for all of them.
CN.collectionGeneration = 0

function CN.Trim(text)
    if not text then
        return ""
    end

    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end
