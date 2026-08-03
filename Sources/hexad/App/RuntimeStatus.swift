import SwiftUI

/// Whether hexad is actually listening, and on what.
///
/// This exists because "the app is running" and "the app works" are different things, and the
/// gap between them is invisible: without Accessibility the event tap cannot be created, so
/// hexad sits in the menu bar looking perfectly healthy and doing nothing at all. Every surface
/// that can show state — the menu, Settings — reads this, so there is no screen where the app
/// is broken and silent about it.
final class RuntimeStatus: ObservableObject {

    static let shared = RuntimeStatus()

    @Published var isListening = false

    /// Derived, never stored. Turning the macOS switcher off moves hexad from ⌥Tab to ⌘Tab
    /// without the tap restarting, so a cached label goes stale the moment it matters and the
    /// menu confidently names the wrong key.
    var shortcutLabel: String { Shortcut.active.label }

    private init() {}

    /// Appends the current state to `~/Library/Logs/hexad.log`.
    ///
    /// A menu-bar app has nowhere to print. `NSLog` goes to the unified log, where finding it
    /// means knowing the right predicate — so the one question worth answering after an install
    /// ("is it actually listening?") gets a file anyone can `tail`.
    func writeToLog(_ note: String) {
        append("\(note) — \(summary)")
    }

    /// A running trace of what the app actually did, for reading back after a session with it.
    ///
    /// Separate from `writeToLog` because that one appends the whole status summary to every line,
    /// which is right for a lifecycle event and noise for a stream of gestures. Kept deliberately
    /// cheap: one formatted line, appended, no buffering to lose on a crash.
    func trace(_ event: String) {
        guard Self.isTracing else { return }
        append("· \(event)")
    }

    /// Tracing is on by default while hexad is pre-release — the app is being used specifically to
    /// find out what it gets wrong, and a bug that leaves no trace has to be reproduced by hand.
    /// `defaults write com.smrazar.hexad hexad.trace -bool NO` turns it off.
    private static let isTracing: Bool = {
        UserDefaults.standard.object(forKey: "hexad.trace") as? Bool ?? true
    }()

    /// **R8.** Keep the log from growing without bound.
    ///
    /// Tracing is on by default while hexad is pre-release, and the store rebuilds every two
    /// seconds — so the file gains a line a second on a busy machine and nothing was ever removing
    /// them. Trimmed once at launch rather than on every write: stat-ing a file before appending a
    /// line costs more than the line.
    ///
    /// The tail is kept, not the head. The interesting part of a log is always what happened most
    /// recently, and truncating to zero throws away the session that is being diagnosed.
    func trimLogIfNeeded() {
        let url = logURL
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int,
              size > Self.maxLogBytes else { return }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        // Seek to the last chunk rather than reading the whole file — the point is to avoid
        // holding several megabytes in memory to throw most of it away.
        try? handle.seek(toOffset: UInt64(max(0, size - Self.keptLogBytes)))
        guard let data = try? handle.readToEnd(), var text = String(data: data, encoding: .utf8)
        else { return }

        // The seek almost certainly landed mid-line; drop the partial one so the file starts on a
        // real entry rather than on half a timestamp.
        if let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        let header = "— trimmed \(size / 1024)KB at launch, oldest entries dropped —\n"
        try? (header + text).data(using: .utf8)?.write(to: url)
    }

    /// Trim once the file passes this, keeping the most recent `keptLogBytes`.
    private static let maxLogBytes = 2 * 1024 * 1024
    private static let keptLogBytes = 512 * 1024

    private var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/hexad.log")
    }

    private func append(_ body: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(body)\n"
        let url = logURL
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// One line, plain words, safe to put straight into a menu.
    var summary: String {
        guard isListening else {
            return Permissions.isAccessibilityGranted
                ? "Not listening — the keyboard tap could not start"
                : "Not listening — Accessibility not granted"
        }
        return "Listening on \(shortcutLabel)"
    }
}
