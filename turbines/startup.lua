-- startup.lua -- this computer is the turbine relay, and nothing else.
--
-- It runs on boot, on a chunk reload, and after a crash, because turbines that
-- nobody is driving are worse than turbines that are stopped, and the flight
-- computer has no way to notice this one is gone beyond the readings going
-- quiet.
--
-- Ctrl+T once stops the turbines and leaves you in the five second window
-- below; Ctrl+T again during that window drops you to the shell.

local PROGRAM = "turbine_relay"

if not fs.exists(PROGRAM .. ".lua") then
    printError("startup: " .. PROGRAM .. ".lua is missing")
    printError("the turbines are not being driven. Copy it back and reboot.")
    return
end

-- shell.run swallows the error and returns false rather than raising, which is
-- why this reads the return value instead of using pcall. The relay stops its
-- own turbines on the way out of a crash, so the restart always begins at zero.
while true do
    local ok = shell.run(PROGRAM)
    if ok then
        -- A clean exit means it was quit on purpose, or found no controllers and
        -- said so on screen. Leave the message up rather than wiping it.
        return
    end
    printError("turbine relay stopped. Restarting in 5s, Ctrl+T for the shell.")
    sleep(5)
end
