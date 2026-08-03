<p align="center">
  <img src="docs/icon.png" alt="" width="128" height="128">
</p>

<h1 align="center">hexad</h1>

<p align="center">
  A window switcher for macOS in three shapes — a held-modifier row, a searchable list,<br>
  or every window at once. You pick one, and the other two stay out of the way.
</p>

<p align="center">
  <a href="https://smrazar.github.io/hexad/">Website</a> ·
  <a href="docs/FEATURES.md">Features</a> ·
  <a href="docs/STATUS.md">Status</a> ·
  <a href="docs/CHANGELOG.md">Changelog</a> ·
  <a href="docs/BUGS.md">Bugs</a>
</p>

---

> ### This is an early build
>
> **v0.6.2, and not yet verified end to end.** Everything below exists in the binary. Whether each
> piece has been *watched working* is tracked separately and honestly in
> [`docs/STATUS.md`](docs/STATUS.md) — that file exists precisely because "built" and "seen
> working" are not the same claim, and this project keeps them apart on purpose.
>
> There is no release and no binary download. Build it from source if you want to try it.

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
- **A three-finger trackpad swipe**, left or right — one switch, not a direction. A single swipe
  opens, scrubs the selection while the fingers stay down, and commits when they lift.
- **Two-finger scroll**, once it is open, to move the selection.
- **The menu bar item**, which names the current mode and opens it.

Two rules are enforced rather than documented: a **bare letter cannot be bound** (it would swallow
that letter in every app, forever — function keys are the exception), and the **last binding
cannot be removed**, because clearing it locks you out of an app whose only interface is the thing
you just unbound.

A binding fires with Shift held too — Shift means **cycle backwards**, not a different chord.

## Install

```sh
git clone https://github.com/smrazar/hexad.git
cd hexad
./Scripts/install.sh
```

Swift Package Manager, no Xcode project. macOS 14+. Ad-hoc signed.

hexad needs **Accessibility** permission to see and raise other applications' windows — that is the
whole job, and there is no way to do it without. It reads window titles, owners and positions. It
records nothing and sends nothing anywhere.

## Development

```sh
./Scripts/build.sh            # assembles hexad.app from the SwiftPM build
./Scripts/install.sh          # build, install to /Applications, reset permissions
python3 Tools/make-site.py    # regenerate the website
```

The app icon is `Assets/icon.svg`. The **menu-bar glyph is a separate file**,
`Assets/hexad-glyph.svg` — the two used to share one source, so changing either moved both.

## Licence

MIT.
