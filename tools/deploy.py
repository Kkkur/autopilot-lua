"""Copy this folder out to the computers in the world, and check it landed.

CC: Tweaked cannot pull from a folder on the host, so the copies are kept in
step by hand. Doing it by hand four times is how one of them ends up a version
behind, which is a bug that looks like a physics bug.

    python tools/deploy.py           say what differs, change nothing
    python tools/deploy.py --write   copy, then say what differs

What each computer gets:

    0  startup.lua and src/   the flight computer
    1  relay/                 the fuel relay
    2  turbines/              the turbine relay
    3  turbines/              the cruise relay, the same program

Each relay folder carries its own copy of sc/log.lua and sc/link.lua, and each
of those is meant to be the same file in all three places. That is checked here
rather than trusted, because a change to logging or to the passcode envelope is
a change to three files and forgetting one is silent.

What the computers write themselves is never copied back: starcatcher/,
fuelrelay/, turbinerelay/ and the logs and telemetry under them.

Override the save path with STARCATCHER_SAVE.
"""

import filecmp
import os
import shutil
import sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SAVE = os.environ.get(
    "STARCATCHER_SAVE",
    r"C:\Users\WinterOS\AppData\Roaming\PrismLauncher\instances\Skyline SMP"
    r"\minecraft\saves\New World (1)\computercraft\computer",
)

# (computer id, what it is, [(source, destination under that computer)])
PLAN = [
    (0, "flight computer", [("startup.lua", "startup.lua"), ("src", "src")]),
    (1, "fuel relay", [("relay", ".")]),
    (2, "turbine relay", [("turbines", ".")]),
    (3, "cruise relay", [("turbines", ".")]),
]

# The files every role carries a copy of, which have to stay identical. Checked
# before anything is copied, because forgetting one of the copies is silent.
SHARED = [
    ["src/sc/log.lua", "relay/sc/log.lua", "turbines/sc/log.lua"],
    ["src/sc/link.lua", "relay/sc/link.lua", "turbines/sc/link.lua"],
]


# The three copies of log.lua differ on exactly one line and are meant to: each
# writes its own name in the crash banner, so a crash file says which computer
# left it. Comparing the raw bytes reported that as drift on every single run,
# and a warning that is wrong every time is a warning nobody reads the day it is
# right. Everything but the banner is still compared byte for byte.
def body(path):
    with open(path, "rb") as handle:
        lines = handle.read().splitlines()
    return [line for line in lines if b"CRASH ===" not in line]


def sources(src, dst):
    """Every file the pair covers, as (absolute source, relative destination)."""
    full = os.path.join(HERE, src.replace("/", os.sep))
    if os.path.isfile(full):
        yield full, dst.replace("/", os.sep)
        return
    for root, _, names in os.walk(full):
        for name in names:
            if not name.endswith(".lua"):
                continue
            path = os.path.join(root, name)
            rel = os.path.relpath(path, full)
            yield path, os.path.normpath(os.path.join(dst, rel))


def main():
    write = "--write" in sys.argv
    if not os.path.isdir(SAVE):
        print("no save at " + SAVE)
        print("Set STARCATCHER_SAVE to the computercraft/computer folder.")
        return 1

    for copies in SHARED:
        first = body(os.path.join(HERE, copies[0].replace("/", os.sep)))
        for other in copies[1:]:
            path = os.path.join(HERE, other.replace("/", os.sep))
            if body(path) != first:
                print("%s has drifted from %s. They are meant to be the same file."
                      % (other, copies[0]))
                print()

    for cid, what, pairs in PLAN:
        target = os.path.join(SAVE, str(cid))
        exists = os.path.isdir(target)
        print("=" * 60)
        print("computer %d, the %s%s" % (cid, what, "" if exists else "   NOT IN THE WORLD YET"))
        print("=" * 60)

        differs, same, added = [], 0, []
        for source, rel in [item for pair in pairs for item in sources(*pair)]:
            dest = os.path.join(target, rel)
            if not os.path.exists(dest):
                added.append(rel)
            elif filecmp.cmp(source, dest, shallow=False):
                same += 1
                continue
            else:
                differs.append(rel)
            if write:
                parent = os.path.dirname(dest)
                if parent:
                    os.makedirs(parent, exist_ok=True)
                shutil.copy2(source, dest)

        for rel in added:
            print("  new      " + rel)
        for rel in differs:
            print("  changed  " + rel)
        print("  %d file(s) already match" % same)
        if not write and (added or differs):
            print("  nothing was copied. Run with --write.")
        print()

    if write:
        print("Copied. Reboot each computer in the world for it to run the new files.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
