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

local HandyNotes = {}

CN.HandyNotes = HandyNotes

local probeNotes = {}

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
        local ok, iterator = pcall(iterate, root)

        if ok and type(iterator) == "function" then
            local safe = 0

            for name in iterator do
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

    local ok, iterator = pcall(iterate, root)

    if not ok or type(iterator) ~= "function" then
        return nodes
    end

    local pluginCount = 0

    for name, handler in iterator do
        pluginCount = pluginCount + 1

        if pluginCount > 50 then
            break
        end

        if type(handler) == "table" and type(handler.GetNodes2) == "function" then
            local gotNodes, nodeIterator = pcall(handler.GetNodes2, handler, uiMapID, false)

            if gotNodes and type(nodeIterator) == "function" then
                local safe = 0

                -- HandyNotes coords pack x and y into one integer.
                local success = pcall(function()
                    for coord, node in nodeIterator do
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
