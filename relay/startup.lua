-- startup.lua -- this computer is the fuel relay, and nothing else.
--
-- It runs on boot, on a chunk reload, and after a crash, because the autopilot
-- next door expects fuel numbers to be on the air without anyone walking over
-- here to type a command.
--
-- Ctrl+T once stops the relay and leaves you in the five second window below;
-- Ctrl+T again during that window drops you to the shell.

local PROGRAM = "fuel_relay"

if not fs.exists(PROGRAM .. ".lua") then
    printError("startup: " .. PROGRAM .. ".lua is missing")
    printError("the relay is not running. Copy it back and reboot.")
    return
end

-- A relay that has stopped relaying is worse than one that never started, so a
-- crash restarts it. shell.run swallows the error and returns false rather than
-- raising, which is why this reads the return value instead of using pcall.
--
-- The delay is there so a fault that fails instantly cannot spin the computer,
-- and so there is always somewhere for Ctrl+T to land.
while true do
    local ok = shell.run(PROGRAM)
    if ok then
        -- A clean exit means the relay was quit on purpose, or found no tanks
        -- and said so on screen. Leave the message up rather than wiping it.
        return
    end
    printError("fuel relay stopped. Restarting in 5s, Ctrl+T for the shell.")
    sleep(5)
end
