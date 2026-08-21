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
CN.version     = "0.47.0"
CN.dbVersion   = 7

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

local PREFIX       = "|cff33ff99Completion Navigator|r: "
local DEBUG_PREFIX = "|cff999999Completion Navigator Debug|r: "

function CN.Print(message)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. tostring(message))
end

function CN.DebugPrint(message)
    if CN.db and CN.db.settings and CN.db.settings.debug then
        DEFAULT_CHAT_FRAME:AddMessage(DEBUG_PREFIX .. tostring(message))
    end
end

local Print      = CN.Print
local DebugPrint = CN.DebugPrint

-- Colorized yes/no used throughout the completion output.
function CN.YesNo(value)
    if value then
        return "|cff00ff00YES|r"
    end

    return "|cffff4444NO|r"
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

    CN.commands[definition.name] = definition

    if definition.aliases then
        for _, alias in ipairs(definition.aliases) do
            CN.commands[string.lower(alias)] = definition
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
            Print("Error: " .. tostring(err))
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
    if level == CN.confidence.UNKNOWN or text == nil then
        return "|cff999999unknown|r"
    end

    if level == CN.confidence.ESTIMATED then
        return text .. " |cff999999(estimated)|r"
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

    return string.rep("=", filled) .. string.rep("-", width - filled)
end

function CN.Trim(text)
    if not text then
        return ""
    end

    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end
