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
CN.version     = "0.23.0"
CN.dbVersion   = 4

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
        CN.eventFrame:RegisterEvent(event)
    end
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

function CN.Trim(text)
    if not text then
        return ""
    end

    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end
