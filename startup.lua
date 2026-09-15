-- startup.lua -- this computer is the autopilot.
--
-- Copied to the root of the flight computer, next to the src folder, so the
-- program is up after a reboot or a chunk reload without anyone typing it.
--
-- A restart always comes up idle with the propellers stopped: starcatcher never
-- takes a target back up on its own, and that is on purpose. A flight computer
-- that resumed a leg by itself after a crash would fly a ship at a waypoint
-- nobody was watching.

local PROGRAM = "src/starcatcher"

if not fs.exists(PROGRAM .. ".lua") then
    printError("startup: " .. PROGRAM .. ".lua is missing")
    printError("copy the src folder to the root of this computer and reboot.")
    return
end

-- shell.run swallows the error and returns false rather than raising, so this
-- reads the return value instead of using pcall. A clean exit is `exit` typed
-- on purpose, or Ctrl+T, and neither should start it up again.
while true do
    if shell.run(PROGRAM) then return end
    printError("starcatcher stopped. Restarting in 5s, Ctrl+T for the shell.")
    sleep(5)
end
