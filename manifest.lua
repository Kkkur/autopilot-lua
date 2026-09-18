-- manifest.lua -- which files each computer needs, and where they go.
--
-- Read by install.lua before it downloads anything, so adding a file later is
-- an edit here rather than a new installer shipped to four computers. Each
-- computer downloads only what its own role uses: the fuel relay has no
-- business carrying the flight maths.
--
-- A path on the left is a path in the repo. A path on the right is where it
-- lands on the computer, and those are not the same shape: the relays live at
-- the root of their computer while the flight computer keeps its modules under
-- src/, which is what starcatcher.lua looks for them in.
--
-- The version is recorded by the installer so a computer can say when it is
-- behind. Bump it whenever the set of files changes or the program does.
--
-- Each role also names where its copy of `sc/link.lua` landed. The installer
-- pairs the ship through the module it has just installed rather than carrying
-- a second copy of the `link.cfg` format, and the path is not the same on a
-- relay as on the flight computer, so it is recorded here rather than guessed.

return {
    version = "0.13.0",
    note = "stage 11: the rose is walked on the front, not on the hull",

    roles = {
        -- The flight computer. Carries CC: Sable and a modem, owns the maths
        -- and owns nothing that spins.
        command = {
            title = "flight computer",
            data = "starcatcher",
            link = "src/sc/link.lua",
            files = {
                { "startup.lua", "startup.lua" },
                { "src/starcatcher.lua", "src/starcatcher.lua" },
                { "src/sc/util.lua", "src/sc/util.lua" },
                { "src/sc/config.lua", "src/sc/config.lua" },
                { "src/sc/log.lua", "src/sc/log.lua" },
                { "src/sc/link.lua", "src/sc/link.lua" },
                { "src/sc/telemetry.lua", "src/sc/telemetry.lua" },
                { "src/sc/ship.lua", "src/sc/ship.lua" },
                { "src/sc/flight.lua", "src/sc/flight.lua" },
                { "src/sc/turbine.lua", "src/sc/turbine.lua" },
                { "src/sc/cal.lua", "src/sc/cal.lua" },
                { "src/sc/control.lua", "src/sc/control.lua" },
                { "src/sc/nav.lua", "src/sc/nav.lua" },
                { "src/sc/fuel.lua", "src/sc/fuel.lua" },
                { "src/sc/preflight.lua", "src/sc/preflight.lua" },
                { "src/sc/popup.lua", "src/sc/popup.lua" },
                { "src/sc/ui.lua", "src/sc/ui.lua" },
                { "src/sc/cmd.lua", "src/sc/cmd.lua" },
                { "src/sc/tests.lua", "src/sc/tests.lua" },
            },
        },

        fuel = {
            title = "fuel relay",
            data = "fuelrelay",
            link = "sc/link.lua",
            files = {
                { "relay/startup.lua", "startup.lua" },
                { "relay/fuel_relay.lua", "fuel_relay.lua" },
                { "relay/test.lua", "test.lua" },
                { "relay/sc/log.lua", "sc/log.lua" },
                { "relay/sc/link.lua", "sc/link.lua" },
            },
        },

        -- Two computers, one program. Which one a relay turns out to be is
        -- decided by what it finds on its own network when it boots, not by
        -- which of these two names was picked here, so the file lists are
        -- identical on purpose. The names exist so the installer can say out
        -- loud which one it thinks this is.
        turbine = {
            title = "turbine relay",
            data = "turbinerelay",
            link = "sc/link.lua",
            files = {
                { "turbines/startup.lua", "startup.lua" },
                { "turbines/turbine_relay.lua", "turbine_relay.lua" },
                { "turbines/sc/log.lua", "sc/log.lua" },
                { "turbines/sc/link.lua", "sc/link.lua" },
            },
        },

        cruise = {
            title = "cruise relay",
            data = "turbinerelay",
            link = "sc/link.lua",
            files = {
                { "turbines/startup.lua", "startup.lua" },
                { "turbines/turbine_relay.lua", "turbine_relay.lua" },
                { "turbines/sc/log.lua", "sc/log.lua" },
                { "turbines/sc/link.lua", "sc/link.lua" },
            },
        },
    },
}
