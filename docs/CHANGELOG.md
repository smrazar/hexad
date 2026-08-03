# hexad — changelog

Newest first. Every entry says what changed and, where it matters, *why* — a line that only says
what changed is a line nobody can act on later.

Versioning follows stow's rule: `+0.1` for a normal round, `+1.0` for a major one.

---

## 0.6.2 — the tour, read end to end for the first time

**The onboarding tour is now readable on demand**
- `--demo-onboarding=N` opens any step directly. The tour is otherwise reachable only once per
  install, which is why the two copy bugs below survived it growing from three steps to five —
  reading step 4 meant three real clicks in a window that had already been dismissed for good.
- All five steps were opened and read on screen this round. Steps 3 and 4 had never been looked at.

**Fixed**
- **B30 — the tour promised one permission on the step before it asked for a second.** Step 2
  claimed Accessibility was "the only permission hexad asks for"; step 4 then asks for Screen
  Recording, and ships with previews on. Step 4 in turn said previews "stay off unless you turn it
  on", above a switch that was already on. Both now describe what the app actually does.
- **B31 — the welcome window opened in the bottom-left corner on a first run.** `AppWindow`
  decided whether to centre by testing `frame.origin == .zero`, but naming a window for frame
  autosaving lifts it clear of the Dock first, so a brand-new window read as one the user had
  already placed. It now asks `UserDefaults` whether a saved frame exists before naming the
  window. Only the welcome window showed this — Settings had been moved during development and so
  always had a real saved frame.

---

## 0.6.1 — the defaults, read from a lived-in install, and a signing identity that holds

**Defaults, second reading**
- Read back from a running install after a fresh profile had been used for a while, and adopted
  wholesale. **This pass reversed most of the previous one** — the count, the titles and the
  remembered query all came back on once the features around them worked, which is the argument
  for reading the machine rather than reasoning about it.
- Now on: the backdrop over the wallpaper, window titles, the count, the remembered query,
  **stay open**, **peek while choosing**, preview freshness, the menu bar count, and **window
  previews**.
- Still off: scroll-to-move. The swipe already scrubs while the fingers are down, and a switcher
  that moves under an idle two-finger rest is startling.
- **Three bindings ship — ⌘Tab, ⌥Tab, ⌃Tab.** For a while only ⌘Tab did, on the reasoning that
  answering a chord nobody chose is presumptuous. That argument missed something: ⌘Tab does not
  work until the macOS switcher has been turned off, so shipping it alone means an app that does
  nothing at all for anyone who declines that step or has not reached it yet.

**Previews on by default — this reverses PLAN.md §2**
- The rule was that an app asking for the screen on first launch, to do something the user never
  requested, is an app that gets denied. Two things changed: onboarding now *asks*, with a live
  switch and a "do it later"; and previews are what the switcher is *for* — with them off hexad is
  a nicer row of app icons, with them on it answers "which of these four documents", which is the
  case ⌘Tab cannot handle.
- **The README claim has to change with it:** hexad needs *one* permission to work and asks for a
  second, once, for previews. Saying "one permission" while shipping this default would be
  marketing rather than description.

**Signing — three real failures, all now documented in the scripts**
- `make-identity.sh` failed three times before it worked, each for a different reason, and each
  error named the wrong thing:
  1. **`MAC verification failed ... (wrong password?)`** — not a password. Homebrew's OpenSSL 3
     writes PKCS#12 with AES-256/PBKDF2/SHA-256, which Apple's importer cannot verify. Fixed by
     pinning 3DES with a SHA-1 MAC.
  2. **`SecTrustSettingsSetTrustSettings: ... parameters ... not valid`** — `-r trustAsRoot` is for
     treating a *non*-self-signed certificate as a root. `openssl req -x509` is self-signed, so it
     needs `trustRoot`.
  3. **`hexad Local Signing: ambiguous`** — trusting the certificate copies it into the System
     keychain while its key stays in the login keychain, so the name matches twice. `build.sh` now
     signs by SHA-1 hash, which is unambiguous however many keychains hold a copy.
- The script is now idempotent: a half-finished identity is removed before a retry, and a failed
  import is fatal rather than carrying on to ask for an admin password it cannot use.
- **`install.sh` no longer resets the TCC grants when the app is properly signed.** It read the
  signature off the bundle and only clears permissions for an ad-hoc one — the unconditional reset
  would have destroyed the exact thing the stable identity exists to preserve, on every install.

---

## 0.6.0 — the feature round: pins, window sets, reopen, and a grid that actually fits

**The grid, properly this time — B29**
- 0.5.1 said the grid would never scroll and it still did. Two limits were the cause: a hard
  1180pt content cap that threw away a third of a wide display, and a 132pt card floor with
  nothing below it but a compact list that also had to fit.
- The width cap is now a *preference* — used while the windows fit inside it as proper cards,
  abandoned for the full screen the moment they do not. The shape degrades through four tiers
  rather than two: full cards → smaller cards → **cards with no title** → rows of text. Within
  each tier the size is solved by walking down in 2pt steps.
- The self-check that missed this tested one viewport, allowed a whole extra row of slack, and
  stopped at 150 windows. It now runs three viewports up to **400 windows** with no slack.

**New features**
- **N1 · Pin a window to a slot.** ⌘1…⌘9 jump by *position*, and position moves with recency — so
  the muscle memory those keys exist for could never form. A pinned window always leads the list
  at its own slot, with the number on a badge. `⌥P` toggles (or `⌘P` under a ⌥ binding).
- **N2 · Reopen a closed window.** The store already knew what vanished between two rebuilds; that
  was being thrown away. Menu bar ▸ Reopen. **Stated honestly:** macOS offers no way to resurrect
  a specific window from outside its app, so this sends the app the *reopen* event — the same one
  a Dock click sends. For an app that restores its session that is usually the window you wanted.
- **N3 · Buttons on hover.** A close and a minimise button on the tile under the pointer. ⌘W and
  ⌘M existed and nobody discovers them.
- **N4 · Filter to one app in place.** ↓ narrows to the selected window's app, ← or Esc widens
  again. Different from typing its name, which only ranks — six Vivaldi windows among forty others
  still means cycling past all forty.
- **N5 · Window sets.** Name the current windows, raise them together later. Menu bar ▸ Window
  sets. A partial restore says so in an alert rather than quietly returning three of five.
- **N6 · Apps on their own row** in Square, instead of trailing the windows in one flat sequence
  where an app icon looks like a window whose preview failed. Only when it does not cost a row.
- **N7 · Per-app switcher.** Grid on the desktop, Square inside an editor. Settings ▸ Switcher.
- **N9 · The window count in the menu bar.** How much is open, and proof hexad is still counting.
- **N10 · Full-size preview on space.** Finder's gesture, for the decision a tile is too small to
  support. Space again closes it.
- **N8 · Drag a tile to another Space — not built.** It needs `CGSCopySpacesForWindows`, which is
  private, and hexad stays clean-room MIT. Listed here so the omission is deliberate and visible
  rather than forgotten. Full-screen windows *are* handled — `AXFullScreen` is public.

**Second-wave quality of life**
- **R1 · Come back where I was.** Reopening within a few seconds returns to the window you were
  looking at, matched by identity rather than index — the list reorders between sessions.
- **R2 · Mark the wrap.** The panel flashes when the cycle passes the end. Wrapping was silent, so
  a long hold read as the list having stuck.
- **R3 · "Nothing on this display".** The display filter falls back to showing everything when it
  matches nothing, and that fallback was silent — the setting said one thing and the panel showed
  another. It now says so.
- **R4 · The hint, for the first three launches only.** The footer hint was removed as chrome, and
  a hint on every invocation is exactly that. One that stops is teaching.
- **R5 · Keep previews current.** Re-capture the selected window while you look at it. Off by
  default: it costs a capture per pause.
- **R6 · Reduce Transparency is honoured**, the way Reduce Motion already was. An accessibility
  setting outranks the frost preference.
- **R7 · Escape twice quits.** The only keyboard route out of a wedged overlay. Deliberately
  awkward to reach by accident: two presses inside 0.6s, on an already-empty switcher.
- **R8 · The log is trimmed at launch.** Tracing is on by default and the store rebuilds every two
  seconds, so the file grew without bound. Trimmed past 2MB, keeping the most recent 512KB — the
  tail, because the interesting part of a log is always what just happened.

**Also**
- A shared `SelfCheck.fixture` helper. Three separate checks had built test windows with
  `element: nil`, which makes them *app-only rows* — so each was silently asserting against the
  wrong branch. Caught the third time by a failing check; the helper is so there is no fourth.

---

## 0.5.1 — the missing windows, a grid that never scrolls, and your own settings as the defaults

**Missing windows — B28, three stacked causes**
- **Deduplication merged real windows.** The rule keyed on title + frame, and a browser reports its
  window title as the *active tab's* title — so two Vivaldi windows on the same page looked like
  one window and the rest were dropped. Two maximised windows share a frame; minimized windows
  report no frame at all, so every untitled minimized window of an app collapsed into one entry.
  Identity now comes from the `AXUIElement` itself, which is exact.
- **A failed AX read was treated as "not a window".** `axCopy` returns nil both for "this is a
  scroll area" and for "the query timed out", and the role check could not tell them apart. It now
  inspects the error and **keeps** a window it could not read — being in the app's own window list
  is evidence enough.
- **The AX messaging timeout went from 0.25s to 1.0s.** A quarter-second was chosen when the walk
  ran on the main thread; it is too tight for an app with many windows, which is precisely the case
  that was failing.
- **New: `hexad --dump-windows --why`** — prints every app, whether AX answered, how many elements
  came back, how many survived, and which rule dropped each of the rest. This bug was found with it
  in a single run.

**Grid never scrolls**
- The scroll view is gone. "Every window at once" and a scroll bar are contradictory: what is below
  the fold is invisible, and reaching it costs more than the ⌘Tab it replaced.
- `GridLayout` solves for the largest layout that *fits* the viewport — shrinking cards while they
  stay readable, then switching to compact rows, then to several columns of rows. Only if even that
  overflows does anything scroll, and by then no layout could have shown them all.
- The compact switch was a fixed "more than 30 windows" guess, which could not know how much screen
  there is. It is now a consequence of the arithmetic.
- A self-check verifies the promise at 1, 4, 9, 20, 40, 80 and 150 windows: either it fits, or it
  admits it cannot. Silent overflow is the failure being guarded against.

**Square wraps to two or three rows**
- A single row shrinking to a 110pt floor meant that past a certain count the row simply ran off
  both edges of the screen. Square now wraps to at most three rows, taking the fewest rows that
  keep tiles readable. Past three, the honest answer is Grid rather than a fourth row of ever
  smaller tiles.
- Tiles fill left-to-right then down, so the cycle order still reads the way text does.

**Defaults taken from a real running install**
- Read back from the machine on 2026-07-28 and adopted wholesale, the same rule stow follows: a
  default nobody has lived with is a default nobody has tested. Several reverse what 0.5.0 shipped.
- Now off: the backdrop (covering the windows you are choosing between removes the context that
  makes a preview recognisable), window titles, the count, the remembered query, scroll-to-move.
- Now on: the three-finger swipe — it shipped off only because it could not be trusted to fire, and
  it fires now — and **opens on the current window** rather than the previous one.

---

## 0.5.0 — the quality-of-life round, and a budget that was never measured

**Settings, reorganised**
- Six panes became five. *General* held two switches and is gone; startup and the menu bar icon
  now sit in *Setup*, with the rest of "how the app itself runs".
- **Each pane is self-sufficient.** The complaint was jumping between panes to change one thing,
  and the cause was panes that overlapped: window previews lived in *Switcher* while the Screen
  Recording they need lived in *Setup*, and the tile's appearance was split across two panes.
  Previews moved to *Appearance* beside the frost switch, and the permission is granted **in the
  row that needs it** rather than by being sent somewhere else.
- The ⌘Tab binding row used to read "Turn it off above" — and the control was not above, it was in
  another pane. It now carries its own **Turn ⌘Tab over** button.
- Hiding the menu bar icon reveals a shortcut recorder for Settings in the same row group, because
  that switch used to disable the only route back to itself.

**Onboarding**
- Three steps became five. **Window previews and Screen Recording are now asked for**, with a live
  switch on the step and *off* as the default — leaving them out never removed the decision, it
  only moved it somewhere the user had to find.
- A closing summary says what hexad actually ended up with: the chord, the switcher, the
  permission, previews. Every step can be declined, which made it possible to finish setup with
  nothing granted and no idea.

**The list**
- **Per-window recency.** Two windows of one app come back in the order they were used, not in AX
  order. Identity is heuristic — pid, title, size rounded to 20pt — because AX gives no window id
  without the private call clean-room MIT rules out.
- **Sort:** recent, A–Z, or by app.
- **Skip these apps:** a deny-list, chosen inline from the running apps.
- **Only this display**, on a multi-display machine. Filtering to the current *Space* stays
  deferred — that needs a private call.

**In the switcher**
- The count in the overlay: "12 windows", or "3 of 12" while filtering.
- A **not listening** banner in the overlay itself, not only in Settings.
- Empty states that say which nothing: no match, no windows, or Accessibility missing.
- **Matched letters are highlighted** while filtering, in all three modes. The ranking is fuzzy and
  showed no reason for its order, which reads as arbitrary.
- **Close, minimise, hide and quit** from every mode. Square uses a modifier the binding does not
  hold — ⌥W under ⌘Tab — because ⌘ is already down for the whole session there.
- **Middle-click closes a tile**, in all three modes.
- **Scroll to move** the selection. The swipe already opened the switcher; scrolling did nothing.
- **Peek while choosing** (off by default): pause on a window and it comes forward; cancel and the
  one you were in comes back.
- **Search in Grid**, which was the one mode without it.
- **A letter jumps to an app** when search is off — the alternative to filtering, not a second
  meaning for the same key.
- The query is remembered for five seconds, so reopening after a mistype does not start blank.
- **Opens on** is now a choice: the previous window (the macOS habit) or the one you are in.

**Grid**
- Sections gained a right-aligned window count and a hairline rule.
- Cards gained an app-icon badge over the preview and a **multi-window indicator** — a card that
  reads "Safari" when there are four Safari windows is a card that lies.

**Shortcuts**
- **Conflict warnings.** Binding ⌘Q says so before you lose Quit in every app. Nothing is blocked:
  the machine belongs to the user.
- A bindable **Open Settings** chord.

**Measured, not claimed**
- `--self-check --bench` measures PLAN.md §11's two budgets. It had never been run, and it failed
  on its first attempt — see **B27**. `snapshot()` rebuilt the whole window list inline whenever
  the cache was two seconds old, putting a 22ms median / 50ms worst Accessibility walk directly on
  the ⌘Tab keypress the cache exists to keep it off. Freshness moved to a background timer;
  the cached read is now 0.000ms and every budget holds.

**Off the main thread, and the Spaces that were never handled**
- **The Accessibility walk now runs on a background queue.** It is not on the hotkey path — that
  reads the cache — but it fires on every app activation, and 47ms on the main thread while
  switching apps is hexad making the *system* hitch. AppKit is touched only before the hop out
  (app list, names, icons) and after the hop back (filter, sort, publish); the AX calls run on a
  serial queue, and overlapping requests coalesce rather than racing to publish.
- **Full-screen windows are recognised** — via `AXFullScreen`, a documented attribute, not the
  private Spaces call hexad stays clear of. They get a badge and a "full screen" note in the
  subtitle, and they are **raised differently**: activating the app first, because `AXRaise`
  cannot move the desktop to another Space, so raising first succeeded against a window nobody
  could see.
- **Drag a card between displays in Grid.** Drop it on another display's section and the window
  moves there, centred. Full-screen windows are not draggable — they own a Space, and setting
  their position does nothing while looking like it should have.

**Signing**
- `./Scripts/make-identity.sh` creates a stable self-signed identity, once. Ad-hoc signing changes
  the app's identity on every build, so TCC drops Accessibility and Screen Recording each time
  while their switches stay on and the APIs return false — the root cause behind both permission
  bugs. `build.sh` uses the identity when it exists and says so when it does not. It is not run
  automatically: it writes to the login keychain.

**Bug log**
- `BUGS.md` had two entries numbered B12 through B17. The second block is now B21–B26.

---

## 0.4.0 — the switcher behaves like a switcher

**Square**
- Rebuilt to the mockup's proportions: container inset ≈7.5% of a tile, gap ≈10%. The bottom hint
  is gone — onboarding shown on every invocation is chrome.
- A **search tile** leads the row and shows the query as it is typed. It is deliberately not a slot
  in the cycle: typing filters from the first keystroke, so a position you had to land on first
  bought nothing and could strand the selection somewhere with nothing to switch to.
- Window previews fill the tile, cropping by height. Title is a bar on the tile's bottom edge, with
  a toggle to turn it off. App icon badge scales with the tile.
- "No match" is now a tile rather than a line of text above the row, so the panel keeps its shape.

**Fixes with named causes**
- **Search could never work in Square.** The typing guard tested the raw modifier flags, and ⌘ is
  held for the whole of a ⌘Tab session — so every letter looked like a ⌘-shortcut and was dropped.
  It now subtracts the binding's own modifiers first.
- **Previews were letterboxed.** The capture asked ScreenCaptureKit for a *square* buffer with
  `scalesToFit`, so a landscape window arrived with bars baked in. No view-side aspect setting could
  have fixed it. The buffer is now shaped like the window.
- **The trackpad never fired.** Two stacked bugs: `MTDeviceCreateList` returns a CFArray of raw
  handles and was being bridged with `as? [DeviceRef]`, which yields nil — so no device was ever
  opened; and the touch position was read at byte 16 of `MTTouch` rather than 32, reinterpreting
  two ints as floats.
- **"Stay open" left no way out.** A sticky session now dismisses on a click anywhere outside.
- **Settings reported the wrong ⌘Tab state.** The pill knew two of four states, so "off, but not by
  hexad" — exactly what a fresh install produces — displayed as "macOS has ⌘Tab".

**Trackpad**
- One switch, no direction. Swipe left or right with three fingers to open, keep swiping to move
  the selection, lift to switch. Reversing mid-swipe walks back.

**Grid**
- **Card size is capped.** `GridItem(.flexible())` carries no maximum, so the grid divided the
  whole screen between its columns and four windows on a wide display became cards ~470pt across.
  Columns are now 170–260pt, per PLAN.md §10.
- Cards are frosted. An 8% white wash was invisible over a wallpaper backdrop, so cards read as
  icons and text floating loose on the desktop.
- Cards render window previews with an app-icon badge, at a fixed 16:10 so the row keeps its rhythm
  before the captures land.

**Settings**
- Reorganised into Setup · Switcher · Shortcuts · Appearance · General · About. The switcher's own
  style, behaviour and preview controls had been split across General and Appearance, and the ⌘Tab
  takeover appeared in two panes where one was always stale.
- **Setup** is new and first: both permissions, the ⌘Tab takeover, listening state, and a button to
  replay the welcome tour.

**Under it**
- A runtime trace at `~/Library/Logs/hexad.log`: list rebuilds, session opens, keystrokes, commits,
  swipe open/step/lift. On by default pre-release; `defaults write com.smrazar.hexad hexad.trace
  -bool NO` turns it off.
- `install.sh --fresh` removes every trace — prefs domain and plist, ByHost copies, cfprefsd cache,
  Application Support, logs, caches, saved state, both TCC grants — then re-registers with Launch
  Services and restarts the Dock so the icon cache cannot serve a stale icon.
- Shipped defaults are now the configuration actually in use, not a guess made before the app had
  been lived with.

## 0.3.0 — the window list

- **Windowless apps are listed**, after every real window, and choosing one opens a new window via
  the Launch Services reopen event rather than merely activating an app with nothing on screen.
- **hexad's own Settings window appears.** Menu-bar apps are `.accessory` and the whole activation
  policy had been excluded; accessory apps now count when they own a standard window, which also
  keeps hexad's own borderless overlays out of the list they draw.
- **A second ⌘Tab cycles** in List and Grid instead of toggling the switcher shut.
- Only ⌘Tab ships as a binding; the rest is the user's to build.

## 0.2.0 — identity

- Icon and menu-bar glyph both drawn from one file, `Assets/hexad-glyph.svg`. The icon is that mark
  in amber on a dark tile, full-bleed: macOS 26 composites a legacy `.icns` onto its own light plate
  and masks it, so artwork with a margin shows that plate as a grey border.

## 0.1.0 — the shell

- SwiftPM package, hand-assembled bundle, ad-hoc signing, `--self-check` that fails the build.
- ⌘Tab takeover as a visible, consented, reversible action, with launch-time repair of an orphaned
  flag.
