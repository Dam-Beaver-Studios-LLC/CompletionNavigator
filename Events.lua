-- Events.lua
-- Completion Navigator :: single event frame and dispatcher.
--
-- No other file should call CreateFrame for event handling. Register with
-- CN:RegisterEvent("EVENT", handler) instead; handlers receive
-- (event, ...) and multiple handlers per event are supported.

local ADDON_NAME, CN = ...

local Print      = CN.Print
local DebugPrint = CN.DebugPrint

------------------------------------------------------------
-- FRAME
------------------------------------------------------------

local eventFrame = CreateFrame("Frame", "CompletionNavigatorEventFrame")

CN.eventFrame = eventFrame

------------------------------------------------------------
-- CORE LIFECYCLE EVENTS
------------------------------------------------------------

local CORE_EVENTS = {
    "ADDON_LOADED",
    "PLAYER_LOGIN",
    "PLAYER_LOGOUT",
}

for _, event in ipairs(CORE_EVENTS) do
    eventFrame:RegisterEvent(event)
end

-- Anything registered before this file loaded still needs to be told to
-- the client.
--
-- Through the guarded path, for the same reason Core registers through it:
-- most of the addon loads BEFORE this file, so this loop is where a bad event
-- name from any earlier module actually reaches the client. Registering
-- directly here meant the guard in Core protected only the handful of
-- registrations that happen after Events.lua.
for event in pairs(CN.eventTable) do
    CN.RegisterWithClient(event)
end

------------------------------------------------------------
-- DISPATCH
------------------------------------------------------------

local function Dispatch(event, ...)
    local handlers = CN.eventTable[event]

    if not handlers then
        return
    end

    for _, handler in ipairs(handlers) do
        local ok, err = pcall(handler, event, ...)

        if not ok then
            Print("Error in " .. event .. " handler: " .. tostring(err))

            -- And keep it, so a bug report can carry the text rather than a
            -- description of the text.
            local errors = CN:GetModule("Errors")

            if errors then
                errors.Record(event .. " handler", err)
            end
        end
    end
end

CN.Dispatch = Dispatch

------------------------------------------------------------
-- HANDLER
------------------------------------------------------------

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...

        if loadedAddon ~= ADDON_NAME then
            return
        end

        CN.InitializeDatabase()
        CN.RunHooks(CN.initHooks)

        DebugPrint("Initialization hooks complete.")

        return
    end

    if event == "PLAYER_LOGIN" then
        -- Banner first: login hooks print their own findings, and those
        -- read as noise before the addon has said it loaded.
        -- The banner names the two commands worth knowing on day one, not
        -- the status dump. It used to point at bare `/cn`, which printed the
        -- addon's internal module list.
        Print("v" .. CN.version .. " loaded. " .. CN.Accent("/cn")
            .. CN.Muted(" for what to do next, ") .. CN.Accent("/cn help")
            .. CN.Muted(" for everything else."))

        CN.RunHooks(CN.loginHooks)

        Dispatch(event, ...)

        return
    end

    if event == "PLAYER_LOGOUT" then
        CN.RunHooks(CN.logoutHooks)

        Dispatch(event, ...)

        return
    end

    Dispatch(event, ...)
end)
