# hexad — what it does

What exists in the binary. Whether it has been *seen working* is `STATUS.md`'s job, and the two
disagree on purpose: this file says what was built, that one says what was watched.

---

## One switcher, chosen

hexad is **one** of three things at a time, never all three. The mode is picked during onboarding
and changed in Settings ▸ General; the bindings open the chosen mode and the other two are not
listening.

| Mode | What it is | How it behaves |
|---|---|---|
| **Square** | A row of square tiles, most recently used first | Held gesture: press, cycle, release to switch |
| **List** | A vertical list with a preview of the selection beside it | Takes focus, type a few letters, ⏎ to switch |
| **Grid** | Every window at once, grouped by display | Somewhere you land: arrows and clicks |

Square is the only mode that cycles while a modifier is held. List and Grid own the keyboard
because they have a text field, and holding a modifier down to type a query would be absurd.

## Ways in

- **Up to three key bindings**, each recorded from a real keystroke and stored as a virtual key
  code — so a chord recorded on one keyboard layout still works on another.
- **A three-finger trackpad swipe**, left or right — one switch, not a direction. A single
  swipe opens, scrubs the selection while the fingers stay down, and commits when they lift.
- **Two-finger scroll**, once it is open, to move the selection.
- **The menu bar item**, which names the current mode and opens it.

Two rules are enforced rather than documented: a **bare letter cannot be bound** (it would swallow
that letter in every app, forever — function keys are the exception), and the **last binding
cannot be removed**, because clearing it locks you out of an app whose only interface is the thing
you just unbound.

A binding fires with Shift held too — Shift means **cycle backwards**, not a different chord. Any
other extra modifier is a different chord and belongs to whoever else wants it.

## ⌘Tab, taken visibly

hexad wants ⌘Tab, and macOS owns it until its own switcher is turned off. That happens as an
explicit onboarding step with a real "Not now", is shown as a status pill in Settings, is restored
on quit, and is **repaired at launch** if the flag is off and hexad did not turn it off — the
uninstall case from `BUGS.md` B1, which no exit handler can cover.

Declining is a real answer: hexad falls back to ⌥Tab and says so.

## Window previews

Off by default. On, each tile shows the window itself with the app icon as a badge, and the tile
turns landscape (260×164) instead of square (180×180) — one constant drives both, so turning
previews on does not reflow anything else.

This is the **only** part of hexad that needs Screen Recording, and it is asked for at the moment
the switch is turned on, never before. That is what keeps "hexad asks for one permission" true
rather than a claim undermined on first launch — rcmd asks for Screen Recording merely to read
window titles; hexad reads them through Accessibility, which it needs anyway.

Captures never happen on the hot path. The overlay opens with app icons and previews swap in as
they land, because a capture costs tens of milliseconds per window against a 16ms budget to appear.

## Appearance

- **Frosted or not** — one switch, no amount to choose, applied live to every surface.
- **Chrome frosts, content does not.** The Settings sidebar lets the desktop through; the pane of
  text beside it paints opaque, because text has to stay readable over any wallpaper.
- **System / Light / Dark**, pinned through `NSApp.appearance` so a light pane never sits beside a
  dark one.
- **Amber**, OKLCH hue 70 — clear of markpad's 259 and stow's 205. One accent, no second hue.
- **Motion is a pop**: a little fade and a little scale together, 140ms in and 100ms out. Out is
  quicker on purpose, because motion after the decision is only latency.

## Honesty features

These exist because the failures they answer are invisible otherwise:

- The **menu bar's first row** says whether hexad is actually listening. A missing permission
  otherwise looks exactly like a working app.
- The **gesture check pill** shows the last swipe hexad received, so "nothing happens" can be told
  apart from "macOS never delivered the gesture".
- Each **binding row says what it will actually do** — ⌘Tab reads as inactive while macOS still
  owns it, rather than looking bound and doing nothing.
- **`--self-check` runs in the shipping binary** and fails the build. `assert` compiles out of
  release, so a pass there would mean nothing.

## What the list contains

Order is most-recently-used **by app**, and within an app by when each window was last used.
Per-window recency needs a stable window identity, which AX will not give without the private call
clean-room MIT rules out — so identity is inferred from the process, the title, and the window's
size rounded to 20pt. A moved or slightly resized window keeps its place; two same-size untitled
windows of one app share one, which costs their relative order and nothing else.

The order can be changed to A–Z or grouped by app, apps can be excluded by bundle identifier, and
on a multi-display machine the list can be limited to the display the pointer is on. Limiting to
the current **Space** is not offered, because doing it correctly needs a private call.

## What can be done to a window without leaving

Close, minimise, hide and quit, in every mode, leaving the switcher open — closing four windows
should be four keystrokes, not four sessions. Middle-click closes a tile, as it does everywhere
tabs exist.

List and Grid use the plain ⌘ chords, because they own the keyboard. **Square cannot**: it holds a
modifier for the whole session, so ⌘W there is indistinguishable from typing a "w" into the search
box. It uses a modifier the binding does not already hold — ⌥W under ⌘Tab, ⌘W under ⌥Tab — which is
the only rule that works for every chord a user might record.

## Honest about what it cannot see

The overlay says how many windows it found — "12 windows", or "3 of 12" while a query is narrowing
it — because a list quietly missing something looks exactly like a complete one. When it has
nothing to show it says which nothing: no match, no windows, or Accessibility missing. Those are
three different problems with three different fixes, and one blank panel for all three is how a
permission problem gets mistaken for a broken app.

If hexad is not listening at all, the overlay says so in its own header rather than only in
Settings, which is not the window anybody is looking at when the app has stopped working.

## Measured, not asserted

`hexad --self-check --bench` measures PLAN.md §11's two budgets — 16ms to open, 1ms inside the tap
callback — in the binary that ships. It found B27 on its first run: the window cache was rebuilding
itself inline on the hotkey path, which is the one thing the cache exists to prevent.

## Fitting the screen

**Square wraps.** A single row shrinking to fit is right up to a point and hopeless past it — below
a readable tile width the row simply runs off both edges of the display. So Square takes the fewest
rows that keep tiles readable, up to three. Past three rows a "row of windows" is not a row any
more, and the honest answer is Grid rather than a fourth row of ever smaller tiles. Tiles fill
left-to-right then down, so the cycle order reads the way text does.

**Grid never scrolls.** The promise of the mode is seeing every window at once, and a scroll bar
breaks it twice: what is below the fold is invisible, and reaching it costs more than the ⌘Tab it
replaced. So the layout solves for a size instead — cards shrink while they stay readable, then
become compact rows, then columns of compact rows. Only if even that overflows does anything
scroll, and by then no layout could have shown them all. The old "more than 30 windows" rule was a
guess that could not know how much screen there is; the shape is now a consequence of the
arithmetic, and `--self-check` verifies the fit at 1, 4, 9, 20, 40, 80 and 150 windows.

## Saying why, when something is missing

`hexad --dump-windows --why` prints every running app, whether Accessibility answered, how many
window elements came back, how many survived, and the rule that dropped each of the rest.

It exists because "the switcher is missing my windows" has half a dozen causes that look identical
from outside — the app was filtered out, AX refused, the query timed out, or the role and subrole
rules rejected everything — and B28 turned out to be three of them stacked. Every one deleted real
windows silently. A rule that removes something should be able to say what it removed and why.

## Defaults that have been lived with

The shipped defaults were read back from a real running install rather than chosen in advance,
which is the same rule stow follows: a default nobody has run is a default nobody has tested. That
is why the backdrop is off (covering the windows you are choosing between removes the context that
makes a preview recognisable), why titles and the count are off, and why the switcher opens on the
window you are already in rather than the previous one — the opposite of the platform convention,
and offered as a setting for exactly that reason.

## Pins, sets, and what was closed

**Pinned windows.** ⌘1…⌘9 jump by position, and position moves with most-recently-used order — so
the muscle memory those keys exist to serve could never form. A pinned window always leads the
list at its own slot, with the number on its badge, and a pin outranks every sort. `⌥P` toggles it
(`⌘P` under a ⌥ binding — see the note on action modifiers).

The honest limit: identity is pid + title + rounded size, because AX gives no window id without
the private call clean-room MIT rules out. **A pin does not survive quitting the app it points
at.** It survives moving, resizing, sorting and reordering, which is what it is for.

**Window sets.** Name the current windows; raise them together later, in the order that leaves the
right one in front. It does not launch, move or lay out anything — it raises what is already open,
and says so in an alert when only some of them are still there. A set that quietly returned three
of five windows would teach you not to trust it without telling you why.

**Reopen.** The store rebuilds constantly, so it already knows which windows vanished between two
passes. What "reopen" can do is bounded by the platform and the UI says so: macOS offers no way to
resurrect a specific window from outside its app, so hexad sends that app the *reopen* event — the
same one a Dock icon click sends. For an app that restores its last session that is usually the
window you wanted; for one that does not, it is a fresh window of the right app.

## Filtering to one app

↓ narrows the list to the selected window's app; ← or Esc widens it again. This is different from
typing the app's name, which only *ranks* its windows first — six Vivaldi windows among forty
others still means cycling past all forty. The header says which app is being shown, because a
switcher displaying four windows on a machine with forty otherwise looks broken.

## A different switcher in some apps

One switcher is the design. This is the exception someone opts into: Grid on the desktop and
Square inside a full-screen editor is a real preference, because the mode that suits "show me
everything" is not the one that suits "flick back to the last thing". Read at the moment the
switcher opens, from the frontmost app.

## What is not built, and will not be

**Anything per-Space.** Showing which Space a window is on, filtering to the current Space, and
dragging a window to another Space all need `CGSCopySpacesForWindows`, which is private. hexad is
MIT via clean-room and uses no private APIs, so these are absent rather than half-done. Raising a
window on another Space works — macOS switches to it — there is simply no label saying it will.

Full-screen windows *are* handled, because `AXFullScreen` is public: they carry a badge, say so in
their subtitle, and are raised by activating the app first, since `AXRaise` cannot move the
desktop between Spaces on its own.
