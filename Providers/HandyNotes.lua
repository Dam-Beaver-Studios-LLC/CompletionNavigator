-- Providers/HandyNotes.lua
-- Completion Navigator :: HandyNotes interoperability.
--
-- HandyNotes and its plugins hold coordinates for treasures, rares, vendors
-- and collectibles that no Blizzard API reports. Where vignettes only tell
-- you about something in range, HandyNotes knows where things are before you
-- get near them.
--
-- Same caution as the other external providers: this reads another addon's
-- internals, which are not a published contract. Every access is probed and
-- wrapped, so a HandyNotes update can make this go quiet but cannot break
-- Completion Navigator. /cn providers reports what resolved.

local ADDON_NAME, CN = ...

local Print = CN.Print

local HandyNotes = {}

CN.HandyNotes = HandyNotes

local function Root()
    local candidate = _G.HandyNotes

    if type(candidate) == "table" then
        return candidate
    end

    return nil
end

function HandyNotes.IsAvailable()
    return Root() ~= nil
end

------------------------------------------------------------
-- PLUGINS
------------------------------------------------------------

-- HandyNotes itself holds almost no data. The plugins do, and they register
-- with the parent under names like "HandyNotes_Treasures".
function HandyNotes.GetPlugins()
    local root = Root()

    if not root then
        return {}
    end

    local names = {}

    -- Ace-style addon with a plugin registry.
    local iterate = root.IteratePlugins

    if type(iterate) == "function" then
        -- THE WHOLE TRIPLET, NOT JUST THE FIRST RETURN.
        --
        -- `IteratePlugins` is a `pairs`-style stateful iterator: it returns
        -- `next`, the table, and the control value. Capturing only the first
        -- and writing `for name in iterator` calls `next(nil, nil)`, which
        -- throws "bad argument #1 to 'next' (table expected, got nil)" -- so
        -- this integration could not work for any player who actually has
        -- HandyNotes installed.
        --
        -- The stub in the test suite was a single self-contained closure,
        -- which is the one shape that makes the broken form work. Stub more
        -- forgiving than the client, again.
        local ok, step, state, control = pcall(iterate, root)

        if ok and type(step) == "function" then
            local safe = 0

            for name in step, state, control do
                table.insert(names, name)

                safe = safe + 1

                if safe > 200 then
                    break
                end
            end
        end
    end

    if #names == 0 and type(root.plugins) == "table" then
        for name in pairs(root.plugins) do
            table.insert(names, name)
        end
    end

    table.sort(names)

    return names
end

------------------------------------------------------------
-- NODE LOOKUP
------------------------------------------------------------

-- Asks every registered plugin what it knows about a map. Plugin node
-- iterators are HandyNotes' documented extension point, so this is the most
-- stable surface available -- but it is still another addon's internals.
function HandyNotes.GetNodesOnMap(uiMapID)
    local root = Root()

    if not root or not uiMapID then
        return {}
    end

    local nodes = {}

    local iterate = root.IteratePlugins

    if type(iterate) ~= "function" then
        return nodes
    end

    local ok, step, state, control = pcall(iterate, root)

    if not ok or type(step) ~= "function" then
        return nodes
    end

    local pluginCount = 0

    for name, handler in step, state, control do
        pluginCount = pluginCount + 1

        if pluginCount > 50 then
            break
        end

        if type(handler) == "table" and type(handler.GetNodes2) == "function" then
            -- Same triplet, same reason: a plugin's node iterator is also
            -- a `pairs`-style return. This one was inside a pcall, so it
            -- failed to a debug line instead of an error -- silently, which
            -- is how a whole feature can be broken and look empty.
            local gotNodes, nodeStep, nodeState, nodeControl =
                pcall(handler.GetNodes2, handler, uiMapID, false)

            if gotNodes and type(nodeStep) == "function" then
                local safe = 0

                -- HandyNotes coords pack x and y into one integer.
                local success = pcall(function()
                    for coord, node in nodeStep, nodeState, nodeControl do
                        safe = safe + 1

                        if safe > 500 then
                            break
                        end

                        if type(coord) == "number" then
                            local x = math.floor(coord / 10000) / 10000
                            local y = (coord % 10000) / 10000

                            table.insert(nodes, {
                                plugin = name,
                                x      = x,
                                y      = y,
                                mapID  = uiMapID,
                                label  = type(node) == "table" and node.label or nil,
                            })
                        end
                    end
                end)

                if not success then
                    CN.DebugPrint("HandyNotes plugin " .. tostring(name)
                        .. " node iteration failed.")
                end
            end
        end
    end

    return nodes
end

------------------------------------------------------------
-- DIAGNOSTICS
------------------------------------------------------------

function HandyNotes.Describe()
    local root = Root()

    if not root then
        return "not installed"
    end

    local plugins = HandyNotes.GetPlugins()

    if #plugins == 0 then
        return "loaded, no plugins registered"
    end

    local noun = (#plugins == 1) and " plugin" or " plugins"

    if #plugins <= 3 then
        return #plugins .. noun .. ": " .. table.concat(plugins, ", ")
    end

    return #plugins .. noun
end

------------------------------------------------------------
-- REGISTRATION
------------------------------------------------------------

-- Registered as a quest data provider so it appears in /cn providers, even
-- though it answers about locations rather than quests. It never claims to
-- know a quest, so it can never contribute wrong prerequisite data.
CN.RegisterQuestDataProvider("HandyNotes", {
    IsAvailable  = HandyNotes.IsAvailable,
    GetQuestData = function() return nil end,
    Describe     = HandyNotes.Describe,
    priority     = 90,
})

------------------------------------------------------------
-- COMMAND
------------------------------------------------------------

-- `GetNodesOnMap` is seventy lines and the stated reason this file exists,
-- and until 0.53.0 nothing called it: no provider, no command, no test. It
-- was written, documented, shipped, and never run -- and because it sat
-- behind a broken iterator it could not have worked if it had been.
--
-- Read-only and on request. HandyNotes nodes are another addon's data about
-- the same world, so they are shown rather than folded into the ranking:
-- this addon does not know how that plugin decides what to draw, and
-- inheriting somebody else's opinion silently is not the same as having one.
CN:RegisterCommand{
    name    = "handynotes",
    aliases = { "hn" },
    order   = 78,
    help    = "What HandyNotes plugins are drawing on this map.",
    handler = function()
        if not HandyNotes.IsAvailable() then
            Print("HandyNotes is not installed, or has not loaded.")
            return
        end

        Print("HandyNotes: " .. HandyNotes.Describe())

        local mapID = CN.GetPlayerPosition()

        if not mapID then
            Print("|cff8a8f96The client will not say which map you are on.|r")
            return
        end

        local nodes = HandyNotes.GetNodesOnMap(mapID)

        if #nodes == 0 then
            Print("|cff8a8f96No plugin is drawing anything on this map.|r")
            return
        end

        Print(#nodes .. " node(s) on this map:")

        for index, node in ipairs(nodes) do
            if index > 20 then
                Print("  |cff8a8f96and " .. (#nodes - 20) .. " more|r")
                break
            end

            Print(string.format("  %d. %s |cff8a8f96%s at %.1f, %.1f|r",
                index, tostring(node.label or "unnamed"),
                tostring(node.plugin), (node.x or 0) * 100, (node.y or 0) * 100))
        end

        Print("|cff8a8f96Shown, not scored: this is another addon's view of "
            .. "the same world.|r")
    end,
}
