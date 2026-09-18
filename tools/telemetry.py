"""Read the ship's telemetry off the live computers, from the desktop.

A CC: Tweaked computer's filesystem is a folder on this machine, so everything
the flight computer and the relays write about a flight is already here. This
just finds it and prints it, because the alternative is remembering a path four
levels deep every time.

    python tools/telemetry.py              what the ship is doing right now
    python tools/telemetry.py events       the events file, newest last
    python tools/telemetry.py events gate  only the gate lines
    python tools/telemetry.py flight       the last rows of the flight csv
    python tools/telemetry.py flight 200   the last two hundred of them
    python tools/telemetry.py cols t,phase,dist,err,common,differential
    python tools/telemetry.py logs         the tail of every computer's log
    python tools/telemetry.py clear        throw away what is there and start clean

The save path is the one CLAUDE.md records. Override it with STARCATCHER_SAVE.
"""

import csv
import os
import sys

SAVE = os.environ.get(
    "STARCATCHER_SAVE",
    r"C:\Users\WinterOS\AppData\Roaming\PrismLauncher\instances\Skyline SMP"
    r"\minecraft\saves\New World (1)\computercraft\computer",
)

# Which computer holds what. The flight computer is the only one with a flight
# csv, because it is the only one that knows where the ship is.
COMPUTERS = {
    0: ("flight computer", "starcatcher"),
    1: ("fuel relay", "fuelrelay"),
    2: ("turbine relay", "turbinerelay"),
    3: ("cruise relay", "turbinerelay"),
}


def folder(cid):
    name, data = COMPUTERS[cid]
    return os.path.join(SAVE, str(cid), data, "telemetry")


def newest_flight():
    d = folder(0)
    if not os.path.isdir(d):
        return None
    files = [f for f in os.listdir(d) if f.startswith("flight_") and f.endswith(".csv")]
    if not files:
        return None
    files.sort(key=lambda f: int(f[len("flight_"):-len(".csv")]))
    return os.path.join(d, files[-1])


def read(path):
    if not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()


def cmd_now():
    for cid in sorted(COMPUTERS):
        name, _ = COMPUTERS[cid]
        text = read(os.path.join(folder(cid), "snapshot.txt"))
        print("=" * 60)
        print("computer %d, the %s" % (cid, name))
        print("=" * 60)
        if text is None:
            print("  nothing written. The computer has not run this build yet.")
        else:
            print(text.rstrip())
        print()


def cmd_events(needle=None):
    path = os.path.join(folder(0), "events.csv")
    text = read(path)
    if text is None:
        print("no events file at " + path)
        return
    for line in text.splitlines():
        if needle is None or needle in line:
            print(line)


def cmd_flight(count="40", columns=None):
    path = newest_flight()
    if path is None:
        print("no flight csv under " + folder(0))
        return
    print("-- " + path)
    with open(path, newline="", encoding="utf-8", errors="replace") as handle:
        rows = list(csv.DictReader(handle))
    if not rows:
        print("header only, no samples yet")
        return
    keep = columns or list(rows[0].keys())
    width = {k: max(len(k), 7) for k in keep}
    print("  ".join(k.rjust(width[k]) for k in keep))
    for row in rows[-int(count):]:
        print("  ".join((row.get(k) or "").rjust(width[k]) for k in keep))
    print("\n%d samples in the file" % len(rows))


def cmd_logs(count=30):
    for cid in sorted(COMPUTERS):
        name, data = COMPUTERS[cid]
        d = os.path.join(SAVE, str(cid), data, "logs")
        print("=" * 60)
        print("computer %d, the %s" % (cid, name))
        print("=" * 60)
        if not os.path.isdir(d):
            print("  no logs folder")
            print()
            continue
        files = [f for f in os.listdir(d) if f.startswith("log_")]
        if not files:
            print("  no logs")
            print()
            continue
        files.sort(key=lambda f: os.path.getmtime(os.path.join(d, f)))
        text = read(os.path.join(d, files[-1])) or ""
        print("-- " + files[-1])
        for line in text.splitlines()[-count:]:
            print(line)
        print()


def cmd_clear():
    removed = 0
    for cid in sorted(COMPUTERS):
        d = folder(cid)
        if not os.path.isdir(d):
            continue
        for name in os.listdir(d):
            os.remove(os.path.join(d, name))
            removed += 1
    print("removed %d telemetry file(s). The next boot starts a clean set." % removed)


def main():
    args = sys.argv[1:]
    if not args or args[0] == "now":
        cmd_now()
    elif args[0] == "events":
        cmd_events(args[1] if len(args) > 1 else None)
    elif args[0] == "flight":
        cmd_flight(args[1] if len(args) > 1 else "40")
    elif args[0] == "cols":
        cmd_flight("40", args[1].split(","))
    elif args[0] == "logs":
        cmd_logs()
    elif args[0] == "clear":
        cmd_clear()
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
