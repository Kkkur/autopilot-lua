# Drawing a screen that matches the rest

Everything the pilot sees on the flight computer comes out of
`src/sc/ui.lua`. It is one file on purpose: a screen split across five files
drifts into five styles. This is how to add to it without the new thing looking
like it arrived from somewhere else.

The relay computers draw their own small screens in their own programs
(`relay/fuel_relay.lua` has one at the bottom). Those follow the same ideas in
miniature and none of the machinery below is available to them.

## The frame

One window, created over the terminal, drawn with `setVisible(false)` and
flipped at the end. Nothing ever flickers, and nothing may look at a half
drawn frame.

There are exactly two entry points and they are not interchangeable.

| Call | Who calls it | What it does |
| --- | --- | --- |
| `ui.draw` | the screen loop | reads the slow instruments, then paints |
| `ui.repaint` | input handling | paints from the reads it already had |

A keystroke calls `ui.repaint`, which is why typing lands on screen at the
speed it was typed. Peripheral numbers a quarter of a second old are the same
numbers, and waiting for fresh ones is what makes a keyboard feel dead.

**The single hardest rule in the file: `paint` contains no yields.** `sublevel`
and `aero` calls are `mainThread` and yield a server tick each. A yield between
the clear and the flip hands the screen to another loop mid frame. So every
instrument that costs a tick is read in `readInstruments`, before painting
starts, and the result is passed down as `reads`. If your new panel needs a
number from a peripheral, add it there, not in the drawing code.

The expensive and slow moving reads (the altimeter, the ship's mass) are on
their own clock inside `readInstruments`, refreshed every `uiExtrasTick`
seconds. This is what lets the screen redraw ten times a second without the
screen being the thing that slows the ship down.

## Colors

Never name a color. Call `C("name")` and pick from the vocabulary:

| Name | For |
| --- | --- |
| `bg` | the background |
| `panel` | rules and inert chrome |
| `accent` | something the eye should find |
| `hi` | ordinary text |
| `dim` | text that is true but secondary |
| `good`, `warn`, `bad` | a state, never a decoration |
| `bar`, `barBg` | a filled bar and its trough |
| `tabOn`, `tabOff` | the tab bar |
| `ink` | text drawn on a colored background |

`C` picks between a full palette and a monochrome one, so the screen works on
an advanced computer and on a plain one, and the pilot can force the plain one
with the `colorful` setting. Writing `colours.red` directly breaks both.

A color is a claim. `good`, `warn` and `bad` mean the thing being drawn is
good, warning or bad, and thresholds come from config rather than from a fixed
third and two thirds: `fuelColour` and `stressColour` read the captain's own
limits. A number colored red that is fine is worse than a number with no color
at all.

## The primitives

```lua
at(x, y, text, fg, bg)      -- write at a point
line(y, text, fg, bg)       -- write a whole row, padded to the width
rule(y, label)              -- "-- LABEL ------------" divider
bar(x, y, width, frac, fg, bg)          -- a filled bar
biBar(x, y, width, value, maxValue, fg) -- signed, zero in the middle
comma(n)                    -- 142,000 rather than 142000
wrapText(text, width)       -- a list of lines
```

Two warnings that have each cost a screen.

**`line` truncates at the width and says nothing about it.** Prose goes through
`wrapText`, always. A stage that explains in one sentence how much clear air it
wants, with the half naming the distance cut off, has told the pilot nothing.

**Bars are drawn as colored background, not as `#` or `=`.** They read as a
solid block on every font, which characters never quite do.

## Pane, and why a tab is a list before it is a screen

A tab body is built as a list of rows and placed afterwards, rather than
written down the screen as it is composed.

```lua
local p = pane()
p:rule("LINK")
p:text(" relay #1   0.4s ago   812 msgs", C("good"))
p:gap()
p:rule("TOTAL")
p:row(function(y)
    at(1, y, " 412,000 / 1,008,000 mB", C("good"), C("bg"))
    at(W - 10, y, "     41%", C("good"), C("bg"))
end)
p:gap(99)
p:rule("ADVICE")
p:place()
```

- `p:text` is a whole row of text.
- `p:row(fn)` gets the row number only once it is known, and is what you want
  for anything with more than one thing on the line.
- `p:rule(label)` is a section heading.
- `p:gap(weight)` asks for air between two groups. `weight` is the most rows
  that boundary may take.
- `p:left()` says how many rows are still free, which is how a list knows to
  stop before it pushes the footer off the bottom.
- `p:place()` spends the leftover rows on the gaps, round robin, and draws.

Nothing is ever dropped to make a gap. A tab with something to say on every
line loses no room, and a tab with less to say comes out spaced instead of
huddled at the top with a dead block underneath.

`gap(99)` is the idiom for pinning what follows to the foot of the screen.

A list that could be long asks `p:left()` before each item and holds back the
rows the footer needs:

```lua
for _, tank in ipairs(status.tanks) do
    if p:left() <= 4 then break end
    p:row(function(y) ... end)
end
```

## The shape of a panel

Look at `drawFuel` and copy its order. It is the house layout.

1. **The link line first**, when the panel's numbers come from a relay. Every
   number under it is worth exactly what the link is worth.
2. **The headline**, the one number somebody looks up for, with a bar under it.
3. **The detail**, one row per thing.
4. **The advice**, sentences, at the foot.

Within a row: a leading space before text, the label on the left, the value on
the right at a fixed offset from `W`, the bar last. Values are right aligned
through `string.format` widths so digits line up as they change.

Section headings are short and uppercase because they are furniture, not
sentences. Everything else is a sentence, in plain words, lowercase unless it
is a proper name or a state worth shouting. `SILENT` is shouted. `relay #1` is
not.

## Advice is a list, not a paragraph

Anything that reasons about numbers belongs in a pure function outside
`ui.lua`, returning `{ kind, text }` items, worst first. `fuel.advice` is the
model. The screen only arranges them:

```lua
for _, item in ipairs(items) do
    for index, part in ipairs(wrapText(item.text, W - 3)) do
        if p:left() <= 0 then break end
        p:text((index == 1 and " " or "   ") .. part, kindColour(item.kind))
    end
end
```

Continuation lines are indented further than the first, so a wrapped sentence
does not read as two findings.

The advice from every relay goes in one panel. A captain does not care which
computer noticed the problem.

## Failures say what failed

Every fault gets its own sentence in the words of the thing that failed. Two
different faults get two different strings, and neither is swallowed into a
generic message. The four link states are the example worth copying:

```
no modem on this computer
listening on top, nothing heard yet
relay #1 SILENT for 12s
relay #1   0.4s ago   812 msgs
```

Each one names a different fix. "cargo relay error" names none.

## Adding a tab

Add the name to `ui.TABS` and nothing else changes shape: `ui.TAB` is built
from that list, and the tab bar, the click map and the function keys all lay
themselves out from it.

```lua
ui.TABS = { "FLIGHT", "MANUAL", "PROPS", "NAV", "CAL", "TUNE", "FUEL", "LOG" }
```

Then write `drawCargo(snap, reads)` and add the branch in `paint`. Anything
that sets `ui.tab` uses the name, `ui.TAB.CARGO`, never a number: they were
bare numbers in five files once and inserting MANUAL in the middle moved every
one of them silently.

The tab bar tiles the full width in equal cells, so every column belongs to
some tab and a click can never land in a gap. `drawTabs` and `handleClick` both
lay it out through `tabLabels`, because two layouts that disagree by a column
is a pilot pressing FUEL and getting TUNE. Adding a ninth tab narrows every
cell, and on a 51 column computer the clock in the corner gives up its space
first. Run `node sim.js --tabs` and `node sim.js --clicks` afterward and look
at what came out.

## Keys, clicks and commands

Everything the pilot can do has both a key and a command. Keys are for flying,
commands are for saying exactly what you mean, and the command line at the
bottom is live on every tab: `goto dock` works while the CAL tab is up.

Key handling is in `ui.handleKey`, characters in `ui.handleChar`, clicks in
`ui.handleClick`. Two things to respect there:

- A letter key only does something when `ui.input` is empty. On the MANUAL tab
  the letters fly the ship, and `inventory` has to still be a command there
  rather than six throttle nudges.
- F1 to F8 pick a tab outright. Do not take a function key for anything else.

New commands go in `src/sc/cmd.lua` and get added to `cmd.names()`, which is
what tab completion offers.

## Popups

A modal is a pure descriptor built in `src/sc/popup.lua` and drawn by
`ui.lua`. Nothing in `popup.lua` touches a screen, which is why every
sentence in a modal is checkable under `starcatcher --test`.

```lua
{
    severity = "alarm",           -- alarm, warn, info
    title = "HOLD OVERLOADED",
    lines = { { text = "...", kind = "bad" } },
    cost  = { { text = "...", kind = "dim" } },
    choices = {
        { key = "e", label = "ease off", action = "ease" },
        { key = "c", label = "carry on", action = "carry" },
    },
}
```

`lines` is what happened. `cost` is what it means for the ship, which is the
half a pilot needs to choose and the half that usually gets left out. Raise it
with `ui.raise(descriptor, onChoice)` and act on the action in the callback.

**A popup never parks the control loop.** A wizard does, on purpose, because it
has its hands on the propellers. A modal that stopped the balloon being
commanded would drop the ship out of the sky while the pilot read it.

## Screen sizes

The code reads `W, H` once and everything is placed relative to them. An
advanced monitor is wider than a pocket computer by a lot, so:

- Never assume 51 columns. Use `W - n` for right aligned things.
- Never assume the rows. Use `pane()` and let `place` spend what is spare.
- Prose wraps at `W - 3` and not at a number you counted.

`node sim.js --tabs` photographs every tab and is the fastest way to see what
you actually drew.

## Before you say it works

From `tools/`:

    node syntax.js        parses everything
    node sim.js --test    the self test, which covers popup text and advice
    node sim.js           boots, flies a leg, prints the screen it drew
    node sim.js --tabs    photographs every tab
    node sim.js --clicks  clicks every tab cell and checks the right tab came up

The simulator stubs CC: Tweaked, CC: Sable, Create: Avionics, rednet and the
relays, so a mistake in the screen is caught on the desktop rather than on a
ship in the air. Look at the photographs. A tab that passes every test and
reads badly is still a tab that reads badly.
