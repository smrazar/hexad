import AppKit

/// Measures the two numbers PLAN.md §11 promises and nothing else measured.
///
/// The plan budgets **16ms to open** the switcher and **1ms inside the tap callback**, and both
/// have been claims rather than measurements since Phase 2. The list has grown a second tier and
/// an extra AX pass per app since those numbers were written, so they are exactly the kind of
/// promise that quietly stops being true.
///
/// Run with `hexad --self-check --bench`. It is separate from the checks that gate the build,
/// because a timing check on a machine under load fails for reasons that have nothing to do with
/// the code — this reports, and says plainly when a budget was missed.
enum Bench {

    /// PLAN.md §11 budgets.
    private enum Budget {
        static let open: Double = 16
        static let tap: Double = 1
        /// The AX walk is not on the hot path — it runs on app activation and on a timer, never
        /// on the keypress. It still gets a ceiling because it happens on the main thread every
        /// time you switch apps, and two frames is where that starts being felt as the *system*
        /// hitching rather than hexad being slow.
        static let background: Double = 33
    }

    private static let iterations = 50

    struct Result {
        let name: String
        let median: Double
        let worst: Double
        let budget: Double

        var isWithin: Bool { median <= budget }

        var line: String {
            String(format: "%@ %-22@ median %6.3fms  worst %6.3fms  budget %5.1fms",
                   isWithin ? "PASS" : "OVER",
                   name as NSString, median, worst, budget)
        }
    }

    /// Returns the results and whether every budget held.
    @discardableResult
    static func run() -> (results: [Result], isWithin: Bool) {
        guard Permissions.isAccessibilityGranted else {
            print("bench: Accessibility is not granted — the window list is empty by definition,")
            print("bench: so every number here would be a measurement of nothing.")
            return ([], false)
        }

        let store = WindowStore()
        store.rebuild()
        let items = store.snapshot()
        print("bench: \(items.count) window(s), \(iterations) iterations each\n")

        var results: [Result] = []

        // The cached read — what the hotkey actually pays, and the number PLAN.md §11's 16ms
        // budget is really about. `snapshot` must never enumerate: it used to rebuild inline
        // when the cache was stale, which is how a 22ms AX walk ended up on the keypress the
        // cache exists to protect. If this number ever leaves the noise floor, that regressed.
        results.append(measure("snapshot (cached)", budget: Budget.open) {
            _ = store.snapshot()
        })

        // The full walk. Off the hot path by construction, but it runs on every app activation
        // and on the refresh timer, so a machine with forty windows pays it constantly.
        results.append(measure("rebuild (full AX walk)", budget: Budget.background) {
            store.rebuild()
        })

        // The tap's own decision, which is the 1ms budget. A synthesised key event is enough:
        // the callback is pure arithmetic over flags and a key code, and that is the part that
        // must not grow.
        let session = SwitcherSession(store: store, overlay: StripOverlay())
        if let event = CGEvent(keyboardEventSource: nil,
                               virtualKey: CGKeyCode(Shortcut.Key.tab),
                               keyDown: true) {
            event.flags = .maskControl  // deliberately not a binding — measures the reject path
            results.append(measure("tap decision (no match)", budget: Budget.tap) {
                _ = session.handle(.keyDown, event)
            })
        }

        // Ranking the whole list, which is what every keystroke of a search costs.
        results.append(measure("fuzzy rank whole list", budget: Budget.tap) {
            _ = FuzzyMatch.rank(items, query: "se") { "\($0.appName) \($0.displayTitle)" }
        })

        for result in results { print(result.line) }
        let isWithin = results.allSatisfy(\.isWithin)
        print("\nbench: \(isWithin ? "every budget held" : "a budget was missed")")
        return (results, isWithin)
    }

    /// Median rather than mean: one scheduling hiccup in fifty runs should not become the number
    /// the whole budget is judged on. The worst case is printed beside it rather than hidden.
    private static func measure(_ name: String,
                                budget: Double,
                                _ body: () -> Void) -> Result {
        // One untimed run so the first measurement does not include a cold cache.
        body()

        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            samples.append(Double(elapsed) / 1_000_000)
        }
        samples.sort()
        return Result(name: name,
                      median: samples[samples.count / 2],
                      worst: samples[samples.count - 1],
                      budget: budget)
    }
}
