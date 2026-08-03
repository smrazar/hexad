# hexad — status

**Version:** 0.6.2 · **Phase:** 6 — the backlog is built; the screen check is now most of the work
**Last updated:** 2026-08-01
**Published:** github.com/smrazar/hexad · smrazar.github.io/hexad · released as a **pre-release**

> **This is an early build, and this file is the reason to believe that.** v0.6.2 is tagged and
> downloadable, but the release is marked pre-release on purpose: the list below separates what has
> been *watched working on screen* from what merely exists in the binary, and the second list is
> still long.

The "not verified" list is the valuable half of this file. A claim moves up only when something was
actually observed, and the note says what was observed, not what was intended.

---

## How this app is worked on

Learned the hard way over several rounds. Breaking any of these has cost a whole round before.

1. **Fresh install every build.** `./Scripts/install.sh --fresh` — wipes the preferences domain and
   plist, ByHost copies, cfprefsd's cache, Application Support, logs, caches, saved state and both
   TCC grants, then re-registers with Launch Services and restarts the Dock so the icon cache
   cannot serve a stale icon. Say so explicitly when handing a build over.
2. **Read `~/Library/Logs/hexad.log` yourself.** It traces list rebuilds, session opens, keystrokes,
   commits, actions and swipe open/step/lift. Do not ask for it to be pasted. It has already
   confirmed reported bugs before a line of code was touched.
3. **Verify UI by looking at it.** `--self-check` passes happily while the app looks wrong; the
   whole of B5–B10 is what happens when a green build is mistaken for a good one.
4. **Check the data before tuning the view.** B22 cost two rounds of SwiftUI aspect-ratio changes on
   an image that was already letterboxed when it arrived.
5. **Measure the claims.** B27 was found by running `--self-check --bench` for the first time, and
   it had been false for months while every manual check passed.
6. **Big batches, not drip-feed.** Iterate finely near the finish line, not now.
7. **Keep the notes current.** CHANGELOG, BUGS, TODO, STATUS — and bump `VERSION` in
   `Scripts/build.sh`.

---

## Verified this round — by measurement, not by looking

- **`--self-check` passes** in the shipping binary, including the five new checks: window sort,
  window identity, the action modifier, the shortcut-conflict table, and highlight-agrees-with-scorer.
- **`--self-check --bench` passes** every budget after the B27 fix. On a four-window desk:
  cached snapshot 0.000ms (budget 16), full AX walk 14.2ms median / 46.8ms worst (budget 33),
  tap decision 0.001ms (budget 1), fuzzy rank 0.004ms (budget 1).
- **B27 is real and is fixed.** Before the fix the same bench reported the AX walk at 22.3ms median
  and 50.4ms worst *on the hot path*, against a 16ms budget.
- **B28 was diagnosed, not guessed.** `--dump-windows --why` printed the answer in one run:
  Finder returned only its desktop (`AXScrollArea`), and the dedup rule was merging windows that
  shared a title. The previous session had guessed at this and been wrong.
- **The grid's fit is checked by arithmetic** across three viewports — including a 1100×620
  laptop — at 1, 4, 9, 20, 40, 80, 150, 250 and **400** windows, with no tolerance. Either the
  layout fits or it sets `overflows`. The previous version of this check tested one viewport with
  a whole row of slack and passed while the grid overflowed: that was B29.
- **Pinning and window-set capture are checked**: a pin outranks every sort, re-pinning moves
  rather than duplicates, a stale pin invents nothing, and a captured set is reversed so replaying
  it leaves the right window in front.
- **The self-check caught a bad test of its own, twice** — the second time was the third instance
  of the same mistake, which is why `SelfCheck.fixture` now exists. The new full-screen subtitle check failed on
  first run because its fixture passed `element: nil`, which makes any item an app-only row — the
  assertion was testing the wrong branch. Fixed by giving the fixture a real `AXUIElement`.

## Verified this round — by looking at it

Screenshotted and read, not reasoned about. The demo flags exist so this does not depend on
catching the app in the right state.

- **The grid does not scroll.** At 24 windows: seven columns, four rows, every card on screen and
  no scroll bar. This is the bug reported twice, and it is fixed.
- **Grid cards are centred and uniform.** Two bugs the arithmetic could not have caught: a low
  window count left cards hugging the left edge (`LazyVGrid` was reserving seven columns for two
  cards), and cards sized themselves from their preview's aspect ratio while the solver assumed one
  height, so a row came out ragged. Both fixed and re-checked.
- **Square wraps rather than shrinks.** Three rows of nine, with the hint row still visible.
- **Settings shows five panes**, with the permission buttons inline and the amber accent on the
  controls — no system blue.
- **All five onboarding steps.** Steps 3 and 4 had never been looked at before this round; reading
  them found B30. `--demo-onboarding=N` now opens any step directly.
- **The welcome window centres on a first run.** Checked against a genuinely wiped preferences
  domain, which is what exposed B31.

## Verified in earlier rounds — by looking

- Square matches the mockup's proportions, with the bottom hint gone.
- Search works in Square; typing filters from the first keystroke.
- Window previews fill the tile and crop by height. Fill/Fit both confirmed.
- The trackpad gesture works: three fingers, either way, opens · scrubs · lifts to commit.
- The window list is right: windows first, then running apps with none, and hexad's own Settings
  window appears while its overlays never do.
- The app icon is the amber glyph, full-bleed, with no macOS plate showing as a border.

## Known broken

- **B32 — hiding the menu bar icon locks the app away.** Reported by a user on the first install
  from the published repository. There is no Dock icon, a relaunch of an onboarded install opens
  no window, and the "Shortcut for Settings" mitigation is opt-in and defaults to nothing. The
  in-app copy tells the user a relaunch will reopen Settings; it does not. Recovery today is
  `./Scripts/install.sh --fresh`, which wipes preferences. Fix proposed in `BUGS.md`, not applied.

## Not verified — **the whole 0.5.0 round is in here**

Nothing below has been seen on screen. The build is installed and running.

- **The Settings panes past their first screen.** The five panes were seen, but only the top of
  each — nothing has scrolled to the bottom of Switcher or Shortcuts to check for clipping.
- **Everything added to the switcher itself**: the count header, the not-listening banner, the three
  empty states, matched-letter highlighting, close/minimise/hide/quit, middle-click, scroll-to-move,
  peek-while-choosing, letter-jump, remembered query, opens-on.
- **Per-window recency.** The identity heuristic is checked by `--self-check`, but whether two
  windows of one app actually come back in the used order has not been watched.
- **Skip these apps, sort, and only-this-display.** Built, never exercised.
- **Grid's search field, section counts and multi-window indicator.**
- **Conflict warnings** on a recorded binding.
- **The background AX walk.** The walk now runs off the main thread with coalescing. Compiles and
  benches, but nothing has watched whether the list stays correct under a burst of app launches.
- **Full-screen windows**: the badge, the subtitle note, and the activate-then-raise order. The
  detection is `AXFullScreen`, which not every app publishes — a false negative costs a badge.
- **Drag a card between displays in Grid.** Needs two displays to exercise at all.
- **The B28 fix.** Still the first thing to check, and it got *harder* to check this round rather
  than easier — see the open question below. Open several Vivaldi windows on the same page and
  several Finder windows, then run `--dump-windows --why`.
- **The grid above 24 windows.** Twenty-four fits with no scroll bar; the tiers below that —
  smaller cards, cards with no title, rows of text — have only ever been exercised by arithmetic.
- **Square wrapping to two and three rows**, and whether the cycle still reads left-to-right then
  down when it does.
- **The new defaults on a genuinely fresh profile** — the install wipes preferences, so what you
  see now *is* the shipped default set.
- **Everything in 0.6.0.** Pins, reopen, hover buttons, app filter, window sets, apps on their own
  row, per-app switcher, the menu bar count, the full-size preview, and all eight R items. None of
  it has been on screen.
- **The grid at high density in particular** — the card → small card → titleless card → rows
  progression is the fix for the bug you reported, and it is the thing most worth looking at.
- Everything on a second display, and anything above ~30 windows.
- Whether ⌘Tab switching survives every edge case — two Spaces, a minimized window, a hung app.

**`Scripts/make-identity.sh` has now been run**, and the signature is stable
(`hexad Local Signing`, `D3505136…`). `install.sh` no longer resets the permission grants unless
the build is ad-hoc signed, so rebuilds keep Accessibility and Screen Recording.

---

## Open question — AX reported zero windows for apps that plainly had them

At the end of this round, with Vivaldi, Outlook, WhatsApp and Finder all open and visible,
`--dump-windows --why` showed `raw 0` for each: hexad listed them as app-only rows with no windows.
This looks exactly like B28's symptom, but it is **not hexad misreading the answer** —

```
osascript -e 'tell application "System Events" to tell process "Vivaldi" to get count of windows'
→ 0
```

System Events is Apple's own Accessibility client, and it returned zero for the same apps in the
same moment. Whatever the cause, it is upstream of hexad. The screen was not locked (checked). The
likely candidates are a Space or full-screen state that empties `kAXWindowsAttribute` for
non-frontmost apps, or an AX server that needed restarting.

**What to do about it:** next time the window list looks short, run the `osascript` line above
first. If System Events also says zero, the problem is not hexad and a logout will probably clear
it. If System Events says three and hexad says zero, *that* is a real bug and `--why` will name the
rule that dropped them.

---

## Where things stand

| | |
|---|---|
| Modes | Square, List, Grid — one at a time, chosen in onboarding or Settings |
| Bindings | ⌘Tab ships alone; the rest is the user's to add (max 3), with conflict warnings |
| Backward | ⇧ with the binding, or ⌘\` |
| Trackpad | Three fingers to open and scrub · two-finger scroll to move |
| Displays | Grid groups by display; drag a card to another to move the window |
| Full screen | Detected, badged, and raised by activating first |
| Search | On by default, in all three modes. Off turns letters into app-jumps |
| Actions | Close · minimise · hide · quit, in every mode. Middle-click closes |
| Order | Recent (per-window within an app), A–Z, or by app |
| Square rows | One, wrapping to two or three rather than shrinking past readable |
| Grid | Sized to fit the screen — never a scroll bar until no layout could fit |
| Previews | On by default; onboarding step 4 shows the switch and asks for Screen Recording there |
| Permissions | Accessibility required; Screen Recording optional |
| Licence | MIT via clean-room. AltTab is GPL-3 — never open its source |
| Accent | OKLCH hue 70 (amber), `#e39f39` |

## Key locations

- Repo: github.com/smrazar/hexad · Site: smrazar.github.io/hexad
- Log: `~/Library/Logs/hexad.log`
- Artwork: `Assets/icon.svg` (app icon) and `Assets/hexad-glyph.svg` (menu bar) — **two separate
  files**. They used to be one, so a change to either moved both.
- Build: `./Scripts/build.sh` · Install: `./Scripts/install.sh --fresh`
- Bench: `/Applications/hexad.app/Contents/MacOS/hexad --self-check --bench`
- Why is a window missing: `/Applications/hexad.app/Contents/MacOS/hexad --dump-windows --why`
- Read the welcome tour without reinstalling: `./.build/debug/hexad --demo-onboarding=N` (N is 0–4)
- The other demo flags: `--demo-settings`, `--demo-palette`, `--demo-grid`, `--demo-overlay`
- Signing identity, once: `./Scripts/make-identity.sh`
- Prefs domain: `com.smrazar.hexad`
