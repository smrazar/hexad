# hexad — bugs

By root cause, not by symptom. Each entry: what was seen, what was actually wrong, what fixed it, and
**why the checks did not catch it** — that last line is the one that changes how the next check is
written.

Platform behaviours that only look like bugs are at the bottom.

Phase 0. The app does not exist yet, so everything here is about the spike and the machine it runs on.
That is not a reason to leave it unwritten: every one of these would have produced a wrong measurement
and a wrong design decision.

---

## B1 — ⌘Tab dead on the build machine, with no app responsible

**Symptom.** ⌘Tab did nothing. AltTab had been uninstalled to clear the field for testing, so nothing
should have been holding the shortcut.

**Actual cause.** Two independent causes stacked, which is why the first fix appeared not to work.

*Cause 1 — an orphaned symbolic hotkey.* AltTab disables the system switcher through
`CGSSetSymbolicHotKeyEnabled(71, false)`. That flag is WindowServer session state. Uninstalling the app
does not release it: the flag survived removal of the bundle and the process, leaving the machine with
no ⌘Tab and nothing on disk to explain it.

*Cause 2 — a deliberate setting in an unrelated app.* `com.sindresorhus.Supercharge-setapp` had
`disableAppSwitcher = 1`. Supercharge (via Setapp) was running the whole time and was never a suspect,
because the search was for *switcher* apps and Supercharge is a general utility.

**Fix.** Cause 1: `CGSSetSymbolicHotKeyEnabled(71, true)`, exposed as `spike-cmdtab --read-only
--restore`, verified back to `true`. Cause 2: the user's own setting, in Supercharge's own UI — not
something to reverse behind the app's back while it is running and will rewrite its preferences on
quit.

**Resolved 2026-07-27.** ⌘Tab confirmed working by the user after both causes were addressed:
symbolic hotkey 71 restored to `true`, and `disableAppSwitcher` turned off in Supercharge's own UI.
Baseline verified clean before the gate measurement — flag `true`, Supercharge `0`, no blocking app
running.

**Why the checks missed it.** The conflict check enumerated *running applications* against a list of
known switchers. Neither cause is a running switcher: one was a flag left by an app that no longer
existed, and the other was a preference key inside an app nobody would think to look at. **Checking
"who is running" cannot find "what was left behind" or "what an unrelated app decided".** The check now
reads the flag itself first, and treats the running-app list only as an explanation for what it reads.

**What it changes in the design.** `PLAN.md` §4 assumed `atexit` and signal handlers were enough to
protect the user's ⌘Tab. **An uninstall is a path no exit handler covers.** hexad must therefore repair
the flag *at launch*: if ⌘Tab is disabled and hexad did not disable it, put it back before doing
anything else. That is now a Phase 3 requirement rather than a nicety.

---

## B2 — the automated spike reported INCONCLUSIVE with no cause visible

**Symptom.** `spike-auto` synthesised ⌘Tab and watched `CGWindowListCopyWindowInfo` for the system
switcher's window. The control phase — deliberately run with no event tap installed, where the switcher
*must* appear — saw nothing.

**Actual cause.** WindowServer symbolic hotkeys do not respond to synthesised events.
`CGEvent.post(tap: .cghidEventTap)` delivers the keystroke to applications and to session taps, but the
switcher never fires. Confirmed by elimination: no tap installed, no competing app running, permissive
window filter, still nothing.

**Fix.** None available. The automation was abandoned and the manual spike kept.

**Why the checks missed it.** They did not — this is the control phase doing precisely its job. Had
the experiment been written as test-only, "no switcher appeared with the tap installed" would have read
as a clean pass and shipped a wrong conclusion into the design. **The control phase was worth more than
the result it was supposed to validate.**

**What it changes in the design.** The ⌘Tab path **cannot be regression-tested automatically, ever.**
It stays a documented manual check for the life of the app. `PLAN.md` §11's automated budgets cover
what remains measurable: the state machine, the window list, the overlay.

---

## B3 — the spike measured a different app and reported it as hexad's result

**Symptom.** The first `spike-auto` run showed a new window during ⌘Tab: `LaunchOS [layer 1000]
1728×1117`. The system switcher was recorded as absent.

**Actual cause.** LaunchOS 2.2.0 was running and intercepting ⌘Tab, drawing its own full-screen
overlay. The switcher was genuinely absent — because another app had already consumed the keystroke.

**Fix.** A conflict guard that refuses to run when a known ⌘Tab replacement is live, printing the exact
quit command. Split into two tiers after an over-correction: apps that *own* ⌘Tab block the run
(AltTab, rcmd, DockDoor, Contexts, Witch, LaunchOS); keyboard and gesture utilities that merely sit in
the event path are named and allowed (Superkey, Karabiner, BetterTouchTool, Hammerspoon, Multitouch,
Loop, Swish, 1Piece, LinearMouse).

**Why the checks missed it.** The guard existed and was correct, but its list was built from apps
*discussed in this project*. LaunchOS was installed on the machine and never mentioned, so it was
absent from a list that looked complete. **A hardcoded list of known conflicts is only as good as the
imagination that wrote it** — which is why the run now also prints every new window it saw, so an
unknown interloper is visible in the output rather than silently changing the answer.

---

## B4 — the spike accused itself of a leak that had not happened

**Symptom.** With AltTab installed and running normally, `--read-only` reported: *"NOT enabled. If you
did not disable it yourself, a previous run leaked it."* Nothing had leaked.

**Actual cause.** The check treated `enabled == false` as evidence of a leak. A running switcher holds
that flag disabled for its entire lifetime; false is its normal resting state whenever one is
installed.

**Fix.** Correlate before accusing. The message now names the app holding the flag when one is running,
and only suggests a leak when the flag is off with no known switcher alive.

**Why the checks missed it.** No check was wrong — the *message* was. It stated a conclusion where it
had only an observation. **A diagnostic that guesses at cause is worse than one that reports state**,
because it sends the reader somewhere specific and wrong.

---

## B5 — the window list found one window out of four

**Symptom.** `--dump-windows` reported a single window — a Vivaldi tab — on a machine with Finder,
Terminal and Vivaldi all open and visible.

**Actual cause.** The enumeration filtered on **subrole**, keeping only `AXStandardWindowSubrole`.
That is not what macOS reports. On macOS 26.5.2, Finder's file browser and Terminal's window both
come back with subrole **`AXDialog`**, and only Vivaldi's window claimed `AXStandardWindow`. An
allow-list built on the name of the thing therefore discarded three real windows out of four.

**Fix.** Filter on **role** — `kAXWindowRole` — and deny-list the two subroles that genuinely are not
switch targets (`AXSheet`, `AXSystemDialog`). Role also solves a second problem the subrole check had
been hiding: the Finder **desktop** arrives in the same array as an `AXScrollArea`, and would have
been listed as a window the moment the filter was loosened the obvious way.

**Why the checks did not catch it.** `--self-check` covers colour, geometry and key codes — things
computable without a machine state. Nothing compared the list against the windows actually on screen,
because that comparison needs a human or a fixture. The check that *would* have caught it is the one
Phase 2 defines as its exit criterion, and running it is exactly what surfaced this.

**Lesson.** For an API that describes someone else's UI, **prefer a deny-list to an allow-list**. Being
wrong with a deny-list shows up as one extra row; being wrong with an allow-list shows up as an empty
app, and looks like the permission is missing rather than the filter being wrong.

---

## B6 — Accessibility reads as granted in System Settings and denied in the app

**Symptom.** hexad.app appeared in System Settings ▸ Privacy & Security ▸ Accessibility with its toggle
**on**, while the app itself reported `Not listening — Accessibility not granted` and the event tap
refused to start.

**Actual cause.** hexad is **ad-hoc signed** — there is no code-signing identity on this machine
(`security find-identity -v -p codesigning` finds none). An ad-hoc signature is derived from the
binary, so it changes on every build. TCC records the grant against that signature, so a rebuilt
hexad is a *different app* to macOS that happens to have the same name and path. The old row stays
in the list, still switched on, describing a binary that no longer exists.

**Fix.** `Scripts/install.sh` runs `tccutil reset Accessibility com.smrazar.hexad` after installing, so
the stale record is cleared and the app asks again cleanly. The app also opens its own Settings window
on launch when it finds it cannot listen, rather than sitting in the menu bar looking healthy.

**Why the checks did not catch it.** The build verifies the binary; nothing verified the *installed*
app could do its job. `~/Library/Logs/hexad.log` now gets one line per launch stating whether the tap
started, which is what turned a silent failure into a one-line answer.

**Open.** The real fix is a stable self-signed identity, which keeps the grant across rebuilds. Until
then Accessibility must be re-granted after every install — acceptable while testing, not acceptable
for anyone else.

---

---

# Phase 2–5 — reported from the built app

Everything below was found by **using hexad**, not by reading it. That is the pattern worth
noticing: the checks in `--self-check` were all passing while every one of these was true. They
verify that tokens are correct; they cannot see a control that never asks for a token, or a rule
in `design-language.md` that was read and then half-applied.

---

## B7 — the Settings window frosted end to end

**Symptom.** The whole Settings window was translucent — the wallpaper showed through the sidebar
*and* through the pane of text beside it.

**Actual cause.** `AppWindow` makes one `NSVisualEffectView` the window's content view. That much
is right, and §3 requires it. The other half of the same rule was never implemented: **"chrome
frosts; content does not."** Only the sidebar and panels are meant to let the backdrop through;
any pane holding dense text stays opaque, because text has to stay readable over any wallpaper.

**Fix.** The window keeps its single effect view — a second one is forbidden outright by §13 — and
the content column paints an opaque `bg` fill over it. **A pane opts out of frost by painting, not
by getting its own blur.**

**Why the checks missed it.** `--self-check` verifies that colour tokens resolve, that OKLCH maths
is right and that radii stay ordered. Not one of those can see *where a surface was applied*.
**A token check proves the paint is the right colour, never that it was put in the right place.**

---

## B8 — the frost switch did nothing

**Symptom.** Toggling "Frosted overlay" in Settings changed nothing anywhere, in either direction.

**Actual cause.** Two independent halves, which is why it looked completely dead rather than
partly working.

*Cause 1.* `AppWindow` read no frost preference at all. It built an always-active effect view and
never asked again, so the window it was sitting in could not respond to its own switch.

*Cause 2.* `StripOverlay` did read the preference, but only inside `show()`. The setting therefore
appeared to do nothing until the next time the overlay opened — and since the user was looking at
the Settings window when they flipped it, that is indistinguishable from broken.

**Fix.** One `applySurface` in `OverlayChrome`, called by every surface, plus a Combine
subscription on `$isFrosted` in `AppWindow` so the window restyles live. §11: *a setting that needs
a restart is a setting that will be assumed broken* — and one that needs you to reopen another
window is the same bug wearing a smaller number.

**Why the checks missed it.** Nothing exercised a preference *change*. The value was stored and
read correctly, and a test of that would have passed. **The defect was in who gets told, which no
check of the value itself can reach.**

---

## B9 — blue accents in an amber app

**Symptom.** The Appearance pane's toggle was system blue, and its System/Light/Dark picker had a
solid blue selected segment. hexad's accent is amber, and §13 forbids a second hue outright.

**Actual cause.** `.toggleStyle(.switch)` and `.pickerStyle(.segmented)` are AppKit controls, and
they paint themselves in the **system** accent — the one set in System Settings, blue by default.
They never consult the app's palette, so no amount of correct tokens changes them. The onboarding
screen had the same fault by a different route: its buttons carried no style at all, so they were
stock push buttons and the default one was blue.

**Fix.** `HexToggleStyle` and `HexSegmented` in `Components.swift`, built to §10's spec — 38×22
track with an 18pt knob that squashes to 22 while held; a segmented track whose active tab is a
raised `surface` chip with a hairline that slides, **never an accent fill**. Every button in
onboarding now carries `.hexadPrimary`, `.hexadSecondary` or `.hexadGhost`.

**Why the checks missed it.** `checkAccentResolves` asserts the accent is not black and
`checkOklchMath` asserts it is warm. Both passed, and both were irrelevant: **the offending pixels
never asked the palette what colour they should be.** A check can only inspect what the app
computes, not what AppKit draws on its behalf. This is the argument for `Components.swift` existing
at all, stated in its own header and then not followed on two rows.

---

## B10 — three switchers, all listening at once

**Symptom.** Strip, palette and grid were each bound to their own shortcut and all live
simultaneously.

**Actual cause.** Not a coding error — a design error, carried from `PLAN.md` §3.4, which
described three modes and never said which one hexad *is*. Three ways into the same list, all
armed, means the user decides which switcher they are using every time they switch.

**Fix.** `SwitcherMode` as a preference. One mode answers the bindings; the other two are not
listening. Chosen during onboarding and changeable in Settings ▸ General.

**Related, found while removing it.** `Shortcut.grid` was labelled `⌥⇧Tab` but its modifier was
only `.maskAlternate` — the same key code and modifier as `Shortcut.optionTab`. It worked only
because the grid branch was tested first and separately required Shift. **A label that disagrees
with the value beside it is a bug waiting for someone to reorder two `if`s.** Gone with the rest
of the fixed-shortcut scheme.

**Why the checks missed it.** `checkShortcutModifiers` compared each shortcut against the modifier
it was declared with. It never compared the shortcuts **to each other**, so a duplicate pair was
invisible. The replacement check asserts exactly one mode is held-to-cycle.

---

## B11 — the overlay faded in and cut out

**Symptom.** Opening was a plain fade with no scale; closing had no animation at all.

**Actual cause.** `StripOverlay.show` animated `alphaValue` only, and `hide()` called
`orderOut(nil)` directly. A comment in the file argued for this on the grounds that "a switcher
that lingers after the key is released feels slower". That reasoning is right about *duration* and
wrong about *presence*: §8 says a hard cut sitting beside an animated transition reads as a bug.

**Fix.** `OverlayChrome.present` / `dismiss`: a fade **and** a scale, together — 0.92 → 1.015 → 1
over 140ms in, 1 → 0.96 over 100ms out. Out is deliberately quicker, because motion after the
decision is only latency. The scale runs on a view inside the window rather than on the window,
since an `NSWindow` cannot scale and animating its frame relayouts the SwiftUI tree every frame —
the tiles would visibly reflow instead of the surface growing as one object.

**Why the checks missed it.** Motion had no constants to check; the durations were inline literals
at two call sites with different values. `Theme.Motion.Pop` now holds them and `checkPopMotion`
asserts the signs — that it starts small, overshoots past 1, shrinks on the way out, and leaves
faster than it arrives. **Naming a value is what makes it checkable.**

---

## B12 — the shortcut was whatever hexad decided

**Symptom.** Settings said "Shortcuts are fixed in this build."

**Actual cause.** Deferred on purpose, and the deferral outlived its justification: a switcher
whose trigger cannot be changed is unusable for anyone whose ⌘Tab is already spoken for.

**Fix.** `KeyBinding` — a codable chord recorded from a real keystroke — with up to three bound at
once, a `ShortcutRecorder` control, and an optional three-finger trackpad swipe. Key **codes**, not
characters, so a binding recorded on one keyboard layout survives a change of layout.

**What it changes in the design.** Two rules fell out of building it, both now enforced in code:
a bare letter cannot be bound (it would swallow that letter in every app, forever — function keys
are the documented exception), and the **last** binding cannot be removed, because someone who
clears it has locked themselves out of an app whose only interface is the thing they just unbound.

---

## B13 — hexad took ⌘Tab back from an app that was still using it

**Symptom.** Found while preparing a clean install, before it could be reported. ⌘Tab was off and
LaunchOS was running and holding it. A fresh hexad — with its preferences wiped, so with no record
of having disabled anything — would restore ⌘Tab at launch and take the shortcut away from the
switcher the user had chosen to run.

**Actual cause.** `repairIfOrphaned()` treats `.offButNotOurs` as one situation. It is two, and
they need opposite handling: a flag **left behind** by an app that no longer exists, which is B1
and must be repaired, and a flag a **running** app is deliberately holding, which must be left
alone. The repair only ever asked "did *we* turn this off?", never "is anyone still here?".

**Fix.** Check for a running ⌘Tab owner before restoring, reusing the Phase 0 spike's two-tier
split — apps that *own* the shortcut block the repair; keyboard and gesture utilities that merely
sit in the event path do not. The status row now names the app, so "Off — LaunchOS is using it"
replaces a state that read as hexad being broken.

**Why the checks missed it.** No check covers this, and none easily can: the condition depends on
which apps happen to be running. What makes it worth recording is that **the conclusion was
already written down.** B1 says of Supercharge: *"not something to reverse behind the app's back
while it is running and will rewrite its preferences on quit."* That reasoning was applied to the
app the user configures and not to the flag hexad repairs, in the same file, by the same argument.
**A lesson recorded in prose is not a lesson enforced.** The general fix is fewer places that can
write this flag, not a longer list of apps to check.

---

## B14 — a wrong diagnosis, and the phantom windows it shipped

**Kept in full because the mistake is the useful part.** This entry originally claimed AX could not
see other Spaces. That was wrong, it was written confidently, and it shipped a worse bug than the
one it set out to fix.

**The original report.** "I have many apps running but it only shows Terminal."

**What was concluded, and why it was wrong.** A probe showed Finder with three "Searching …"
windows in `CGWindowListCopyWindowInfo` and one in `kAXWindows`, so the conclusion was drawn that
`kAXWindows` only reports the active Space. A window-server supplement was built on that, and the
verification — *nine windows instead of one* — was taken as proof it worked.

**It was not proof of anything.** The count went up; nothing checked that the extra windows were
real. The user then reported the truth: one Terminal window open, no Finder windows at all, and the
switcher was showing three Finder entries.

**The actual cause.** `CGWindowListCopyWindowInfo` with `.optionAll` includes **closed windows the
window server still caches.** Finder keeps its search windows, Terminal keeps its Profiles window.
They report `kCGWindowIsOnscreen` absent, full alpha, ordinary size, layer 0 — indistinguishable
from a real window by every field examined. AX reported zero Finder windows and **AX was right.**

The original symptom had no bug in it: the user diagnosed it themselves before the probe did — two
of the four running apps had no windows open, so a switcher showing one window was correct.

**Fix.** The supplement is deleted. AX is the source of truth. What survives from that work is the
part that was independently real: Finder reports the **same window twice** (once
`AXSystemFloatingWindow`, once `AXStandardWindow`), so windows are deduplicated on title and frame;
and `AXUIElementSetMessagingTimeout` now bounds every per-app walk, which `PLAN.md` §4 asked for and
nothing had implemented.

**Why the checks missed it.** They could not have caught it, and that is the point:

- **The verification measured the wrong property.** "Nine windows instead of one" confirms the code
  ran. It says nothing about whether nine is correct. **A number that moves in the direction you
  hoped is not evidence** — the check has to compare against ground truth, and the only source of
  ground truth here was the person looking at their own screen.
- **The probe was read as confirming a theory rather than as data.** Finder having more CG windows
  than AX windows is equally consistent with "AX misses Spaces" and with "CG includes dead
  windows". The second reading was never tested, and one glance at `kCGWindowIsOnscreen` — already
  printed in the probe output — would have settled it.

**Whether AX can see other Spaces is now genuinely unknown** and is recorded as open in
`STATUS.md` rather than answered by assumption a second time.

---

## B15 — the selection wash ran past the card's rounded corner

**Symptom.** In Settings, the amber on a selected row spilled past the curve of the card.

**Actual cause.** `SettingsSection` drew a rounded background *behind* its rows and rows painted
their own full-bleed selection fill on top. A background is not a clip.

**Fix.** `.clipShape` on the row container.

**Why the checks missed it.** `checkRadiiOrdering` asserts the radius *scale* is ordered. It cannot
see that a correct radius was drawn in a place that does not clip.

---

## B16 — Settings cramped itself into a column of single words

**Symptom.** Resizing Settings narrower wrapped every description one word per line and turned the
status pill into a vertical stack of letters.

**Actual cause.** `contentMinSize` was 420×320 — a number chosen to be permissive, which guaranteed
the layout would break, since the sidebar alone takes 168 of it. Inside the row, the label column
and the trailing control had equal layout priority, so SwiftUI compressed the *control*.

**Fix.** A minimum derived from the window's own design size rather than an arbitrary floor, plus
`layoutPriority` on the text and a fixed horizontal size on the trailing control.

**Why the checks missed it.** Nothing resizes a window in a check. This is the "needs a human to
look at it" category `STATUS.md` keeps a list for.

---

## B17 — the menu bar contradicted itself two lines apart

**Symptom.** The menu showed "Shortcut: ⌘Tab" directly above "System ⌘Tab: On — macOS handles ⌘Tab",
while hexad was in fact being used with ⌘Tab.

**Actual cause.** The menu mixed two sources. The shortcut row read `SystemSwitcher.cachedState`
(what the event tap uses, refreshed on a 5s timer) and the status row read `state` (a live
WindowServer call). Between refreshes they disagree, and the menu printed both.

**Fix.** One `refreshCachedState()` when the menu opens, before anything is drawn from it.

**Why the checks missed it.** `checkSwitcherStateCache` compares live against cached — and passes,
because it refreshes immediately before comparing. **It tested the refresh, not the staleness the
refresh exists to bound.** A cache check that refreshes first can never observe a stale cache.

---

## B18 — Quit read as a label, not a button

**Symptom.** "Quit hexad" in About looked like text.

**Actual cause.** `.hexadGhost`, which §10 reserves for destructive or dismissive actions and which
is text-only by design. Quit in a settings window is a deliberate action and needs a real control.

**Fix.** `.hexadSecondary` — hairline border, hover fill.

---

## B19 — the three-finger swipe could never have fired

**Symptom.** "The trackpad gesture is not working, and the gesture check is not working either."

**Actual cause.** `NSEvent.swipe` is not delivered for this gesture on this machine, and the
`ponytail:` note in the original file named exactly this ceiling without anyone checking whether it
had already been hit. Read from the system rather than guessed:

- `TrackpadThreeFingerVertSwipeGesture = 2` — the vertical three-finger swipe is assigned to
  Mission Control.
- `TrackpadThreeFingerHorizSwipeGesture = 0` — the horizontal one is off entirely.

macOS synthesises no swipe event in either case, so **no public API could have observed it.** The
gesture-check pill was equally dead, for the same reason, which at least meant it was telling the
truth: it never saw a swipe because there was never a swipe to see.

**Fix.** Read the trackpad directly through MultitouchSupport, resolved with `dlopen`/`dlsym` — the
same route and the same reasoning already used for the ⌘Tab flag, including degrading to
"unavailable" rather than failing to launch. Exactly three contacts, a threshold in normalised
trackpad units, a cross-axis limit so a diagonal is not a direction, and a cooldown because one
swipe crosses the threshold on many frames.

**Why the checks missed it.** Nothing can check this without a finger on the glass. What is worth
keeping is that **the limitation was written down before the feature was built and then not
tested against the machine it was going to ship on.** A `ponytail:` note naming a ceiling is a
prediction; it needed one `defaults read` to become an observation, and that is a cheaper step than
building the feature twice.

---

## B20 — an SVG that parsed cleanly into a blank icon

**Symptom.** The menu-bar glyph converter reported "wrote MenuGlyph.pdf from 7 paths" and produced
a valid PDF with an 11-byte content stream: a correct, empty page.

**Actual cause.** The attribute reader searched for `d="[^"]*"`, which matches the `d="TL"` sitting
inside `id="TL"`. Every path parsed the string `TL` — no commands, no coordinates — into an empty
`CGPath`. Seven of them.

**Fix.** Require a leading space before the attribute name.

**Why the checks missed it.** The script's own output was a count of paths *found*, not of geometry
*produced*, so it reported success. **Every stage succeeded and the result was blank** — the parse
found seven elements, the draw drew seven empty paths, the PDF wrote one valid page. This is the
same shape as B14: a number that goes up is not evidence the number means anything. The only thing
that caught it was rendering the image and looking at it.

---

## Platform behaviours, not bugs

**`kCGWindowName` is `nil` without Screen Recording.** `CGWindowListCopyWindowInfo` returns owner,
bounds, layer and window number freely, but not titles. This is why rcmd asks for Screen Recording
merely to read window titles, and why hexad reads titles through the Accessibility API instead —
one permission in v1 rather than two. See `PLAN.md` §2.

**The symbolic-hotkey flag is not in `com.apple.symbolichotkeys`.** IDs 71 and 72 are absent from that
domain even while disabled, so the state lives in WindowServer, not in preferences. It therefore
probably does not survive a reboot — reasoned, not yet verified, and tracked as an open item in
`STATUS.md`.

**`CGSIsSymbolicHotKeyEnabled` is fast until it is not.** Measured over 200 calls on macOS 26.5.2:
p50 **37µs**, p99 **362µs**, worst case **21ms**. The worst case is twenty-one times the entire 1ms
event-tap budget, and an overrunning tap is disabled by the system with no error reported anywhere.
So the switcher state is polled every 5s into `SystemSwitcher.cachedState` and the tap reads only the
cache. This was measured *because* the call sat on the hot path, not after it caused a failure —
`PLAN.md` §11 exists to make that ordering the normal one.

**`AppleSymbolicHotKeys` on this machine has 57 of 63 entries disabled.** A heavily customised keyboard
configuration. Neither 71 nor 72 is among them, which is what ruled the plist out as the cause of B1
and pointed at session state instead.

---

## B21 — search could never work in Square

**Cause.** The typing fallback guarded on `!flags.contains(.maskCommand)`. ⌘ is held for the entire
duration of a ⌘Tab session, so every letter looked like a ⌘-shortcut and was dropped.

**Fix.** Subtract the *binding's own* modifiers before deciding whether a key is a shortcut. Only a
modifier added on top of the binding disqualifies a keystroke.

**Lesson.** A guard written for a mode that is not held cannot be reused unchanged in one that is.

## B22 — window previews arrived letterboxed

**Cause.** `ThumbnailProvider.shoot` set `SCStreamConfiguration.width/height` to the *tile* size —
square, in Square mode — with `scalesToFit = true`. ScreenCaptureKit rendered a landscape window
letterboxed into a square buffer, so the bars were part of the bitmap before any view saw it.

**Fix.** Shape the capture buffer like the window and bound only its longest edge. Cropping to a
tile shape is the view's decision and now happens there.

**Lesson.** Two rounds were spent changing `.aspectRatio(contentMode:)` in SwiftUI. The image was
already wrong; no view-side setting could have fixed it. Check what the data looks like before
tuning what draws it.

## B23 — the trackpad gesture never fired (two stacked causes)

**Cause 1.** `MTDeviceCreateList` returns a CFArray of raw device handles. `as? [DeviceRef]` fails
— Swift bridging wants elements it can retain — so the guard returned before a single device was
started.

**Cause 2.** Touch position was read at byte 16 of `MTTouch`, which is `identifier`/`state`. The
normalised vector begins at byte 32. Two ints were reinterpreted as floats, giving coordinates in
the millions.

**Fix.** `CFArrayGetValueAtIndex` for the list; offset 32 for the position; frames whose positions
fall outside 0…1 are dropped and flagged rather than trusted.

**Lesson.** Both failures were silent and identical in symptom to "macOS claimed the gesture". A
struct read by byte offset needs a validity check, not just a comment.

## B24 — "Stay open" left the switcher with no way out

**Cause.** A held session ends when the modifier is released. A sticky one has no such end and
nothing watched for a click, so the panel ignored every click while covering the screen.

**Fix.** A global mouse-down monitor while a sticky session is up.

## B25 — Settings reported the wrong ⌘Tab state

**Cause.** Two bugs. The pill knew only `hexadOwnsCommandTab` and "everything else", so
`offButNotOurs` — the state a `--fresh` install produces, because the wipe takes hexad's record
while WindowServer keeps the flag — displayed as "macOS has ⌘Tab". And the pane read
`SystemSwitcher.state` as a function call in a view body, which gives SwiftUI nothing to
invalidate on.

**Fix.** All four states named, published through `SettingsModel`, with Claim/Give back actions.

## B26 — grid cards were invisible, then enormous

**Cause.** The card fill was `Color.white.opacity(0.08)`, which over a wallpaper backdrop is
nothing — cards read as icons and text floating loose. After frosting them, `GridItem(.flexible())`
with no maximum divided the whole screen between the columns, so four windows became cards ~470pt
across.

**Fix.** `.ultraThinMaterial` over a dark scrim; columns bounded to 170–260pt.

## B27 — the cache rebuilt itself on the keypress it existed to protect

**Found by** `--self-check --bench`, on its first ever run. Not by using the app.

**Cause.** `WindowStore.snapshot()` rebuilt inline whenever the cache was older than two seconds:

```swift
if Date().timeIntervalSince(lastRebuild) > stalenessInterval { rebuild() }
return cache
```

That backstop was written for changes that fire no workspace notification — a window closed inside
an app that stays frontmost. What it actually did was put the full Accessibility walk onto the
hotkey path, which is the one thing `PLAN.md` §11 and the whole cache exist to prevent. And it did
it on *most* opens, because two seconds without an app activation is the normal state of a machine
sitting still: the longer you leave the switcher alone, the more certain it is to be slow when you
finally press the key.

Measured on a four-window desk — the cheapest case there is:

| | median | worst | budget |
|---|---|---|---|
| `snapshot` (cached) | 0.000ms | 0.034ms | 16ms |
| `rebuild` (full AX walk) | 22.270ms | 50.409ms | 16ms |

**Fix.** `snapshot()` returns the cache and nothing else. Freshness moved to a repeating timer on
the main run loop in `.common` mode, at the same two-second interval, so the walk still happens and
never happens on a keypress.

**Lesson.** The performance budget in the plan was three months old and had never been measured
once. It was violated by the code written to honour it, and every manual check passed the whole
time — the app *felt* fine, because the slow path only fires when you have not used it recently,
which is exactly when nobody is watching for lag. A budget nothing measures is a comment.

## B28 — two windows of one app were merged into one, and slow windows were dropped

**Reported as** "I have a lot of Vivaldi windows and Finder windows but it only shows 2 Vivaldi
windows". Three separate causes, all of which delete real windows from the list, and none of which
leaves any trace.

**Cause 1 — deduplication keyed on title and frame.** The rule existed for a real problem: Finder
hands the *same* window back twice, once as `AXSystemFloatingWindow` and once as `AXStandardWindow`,
same title and same frame. But the key was:

```swift
let key = "\(item.title)|\(x),\(y)|\(w)×\(h)"
```

A browser reports its window title as the **active tab's title**. Two Vivaldi windows showing the
same page therefore had the same title — and two maximised windows have the same frame — so the
rule declared them one window and dropped the rest. Worse for minimized windows, which report no
frame at all: every untitled minimized window of an app collapsed into a single entry.

**Cause 2 — a failed AX read was treated as a wrong answer.** `axCopy` returns `nil` both when an
app says "this is a scroll area" and when it says *nothing at all* because the query timed out.
The role check could not tell those apart:

```swift
let role: String? = axCopy(element, kAXRoleAttribute)
guard role == kAXWindowRole else { return nil }   // ← a timeout looks like a rejection
```

**Cause 3 — a 0.25s messaging timeout.** Chosen when the walk ran on the main thread, where a slow
app would have frozen the UI. Each window costs several AX round trips, so an app with many
windows — exactly the case being reported — is the one most likely to exceed it, and by cause 2
that loss was silent.

**Fix.** Deduplicate on the `AXUIElement` itself, which is exact: two different windows are never
the same element and a window handed back twice always is. The title-and-frame rule survives only
where it was needed, against a window whose subrole is `AXSystemFloatingWindow`. The role check
inspects the `AXError` and **keeps** a window it could not read — being in the app's own window
list is evidence enough. The timeout is 1.0s, affordable now the walk is off the main thread.

**Also added:** `hexad --dump-windows --why`, which prints every app, whether AX answered, how many
elements came back, how many were kept, and the rule that dropped each of the rest. This bug was
diagnosed with it in one run after the previous session had guessed at it.

**Lesson.** Every one of the three is a *silent* deletion, and the switcher looks identical
whether it found four windows or forty — that is what let three of them stack up unnoticed. A rule
that removes something should be able to say what it removed and why.

## B29 — the grid promised a fit and scrolled anyway

**Reported as** "I said try not to have a scroll bar, but even now when there are many windows I
have to scroll to see the last windows."

**Cause.** The first fitting solver (B28's sibling, added in 0.5.1) gave up in two ways, both of
which looked like reasonable limits and both of which quietly meant "and then it scrolls":

1. **A hard content-width cap of 1180pt.** On a 1728pt display that discarded a third of the width
   the grid could have used for columns. Fewer columns means more rows, and more rows is exactly
   what overflows.
2. **A card floor of 132pt with nothing below it.** When cards at the floor still did not fit, the
   solver fell through to a compact list — but only if the *list* fitted. Between those two lay a
   band of window counts where neither did, and the answer was a scroll view.

The self-check that was supposed to catch this tested a single viewport up to 150 windows, and its
fit assertion allowed a whole extra row of slack (`height <= viewport.height + rowHeight`). It
passed while the real layout overflowed.

**Fix.** The width cap became a *preference*: used while the windows fit inside it as proper cards,
abandoned for the full screen the moment they do not. The shape now degrades through four tiers
instead of two — full cards, smaller cards, cards with no title, then rows of text — and within
each tier the size is solved by walking down in 2pt steps rather than picked from a list. The
check now runs three viewports (including a 1100×620 laptop) up to **400 windows**, asserts the
exact height with no slack, and requires `overflows` to be set if a fit was not found.

**Lesson.** A limit chosen for aesthetics — "cards should not be wider than 260pt", "content
should not be wider than 1180pt" — becomes a correctness bug the moment something else depends on
fitting. The check had the right shape and the wrong numbers: one viewport, a generous tolerance,
and a ceiling well below what a real desk reaches. A test that only exercises the comfortable case
certifies the comfortable case.

---

## B30 — the tour promised one permission on the step before it asked for a second

**Found by** opening every onboarding step with `--demo-onboarding=N` and reading them.

**Cause.** The Accessibility step said "It is the only permission hexad asks for", and its note
doubled down: "which is why it can ask for one permission and mean it". Both were true when
written — previews were off by default and the tour was three steps. Previews then became a
fourth step that asks for Screen Recording, and shipped **on** by default. Nobody re-read step 2
after step 4 was added, because reaching step 4 meant three real clicks in a window that only
appears once per install.

The previews step had drifted the same way from the other end: "it stays off unless you turn it
on", above a switch that was already on.

**Fix.** Step 2 now says Accessibility is "the one permission hexad cannot work without" and
points forward: "The next step offers a second one, for pictures." Step 4 says Screen Recording is
"the only reason hexad will ever ask for it" and leads with "Turn it off" rather than "Say no".

**Lesson.** Copy that describes a default is a claim about code, and it goes stale silently — no
compiler, no test, and in this case no way to even *look* at it without wiping the preferences
domain. `--demo-onboarding=N` exists now so the tour can be read on demand.

---

## B31 — the welcome window opened in the bottom-left corner on a first run

**Found by** running `install.sh --fresh` and looking at where the tour landed.

**Cause.** `AppWindow.show()` centred only a window macOS had no remembered frame for, and tested
that with `window.frame.origin == .zero`. But naming a window for frame autosaving is itself what
moves it: AppKit lifts a window created at the origin up to clear the Dock, so by the time the
check ran the frame was `(0, 42)`, not zero. Every brand-new window therefore read as one the user
had already placed, and was left where AppKit dropped it — the bottom-left corner.

Only the welcome window showed it. Settings had been opened and moved during development, so it
always had a real saved frame and always looked correct.

**Fix.** Ask `UserDefaults` for the `NSWindow Frame <name>` key *before* naming the window, and
centre on the answer to that rather than on the origin.

**Lesson.** "Has the user positioned this?" cannot be inferred from the position — the framework
writes to the same field for its own reasons. Ask the store that actually records the user's
answer. Verifying this needed a wiped preferences domain, which is the one state a machine that
has been building the app for a week never has.

---

## B32 — hiding the menu bar icon locked the app away with no way back in

**Found by** a user, on the first install from the published repository: they turned on "Hide the
menu bar icon", and could no longer reach Settings at all. The app kept running and kept switching
windows; there was simply no route back to its own preferences. Recovering it took
`./Scripts/install.sh --fresh` — a preferences wipe.

**Cause.** Four decisions that are each defensible alone, and together remove every door:

1. `LSUIElement` is `true`, so there is no Dock icon to click.
2. The menu bar icon is the only other affordance, and the switch removes it.
3. `applicationDidFinishLaunching` opens a window **only** when onboarding has not been done, or
   when the app cannot listen. A relaunch of a healthy, onboarded install therefore shows nothing.
4. There is no `applicationShouldHandleReopen`, so `open -a hexad` on a running instance does
   nothing visible either.

The mitigation that exists — the "Shortcut for Settings" row, which appears in the same group the
moment the icon is hidden — is **opt-in and defaults to `nil`**. Anyone who flips the switch
without also recording a shortcut is locked out. The row was added for exactly this failure and
still lets the user walk past it.

**What made it worse: the copy is wrong.** Both strings tell the user a relaunch will save them.

- `menuBarDescription`: *"The icon is hidden. Bind a shortcut below, or Settings needs a relaunch."*
- the row's own description: *"Nothing is bound. Without the menu bar icon, only a relaunch
  reopens this window."*

Neither is true. Per cause 3, relaunching an onboarded install opens no window. The user follows
the instruction, sees nothing happen, and now believes the app is broken rather than misconfigured.

**Fix — not yet applied.** The switch must not be able to remove the last way in. In order of
preference:

1. **Require a binding before the icon can be hidden.** The same rule already exists for key
   bindings — "the last binding cannot be removed, because clearing it locks you out of an app
   whose only interface is the thing you just unbound." This is that rule, missed in a second
   place. Hiding the icon *is* unbinding the last interface.
2. **Make a relaunch honest.** Show Settings on launch when the icon is hidden and no settings
   binding is recorded — the state where there is provably no other entry point.
3. **Add `applicationShouldHandleReopen`** so `open -a hexad` shows Settings, giving a documented
   Terminal recovery that is not a preferences wipe.
4. **Fix the two strings** regardless of which of the above lands, since they currently describe
   behaviour the app does not have.

**Why the checks did not catch it.** `--self-check` verifies things it can assert about state, and
this is a claim about *reachability* — whether a running app can still be driven by a user. Nothing
tests that, and a machine that has been building the app all week always has a menu bar icon, a
bound shortcut, or a debug flag to fall back on. The same blind spot as B31: the broken state is the
one a developer's machine never reaches.

**Lesson.** Any switch that removes an affordance has to be checked against *every other* route to
the same place, not just its own. And a recovery instruction in the UI is a claim about behaviour —
it needs the same verification as the behaviour itself. Two strings here confidently described a
relaunch path that had never worked.
