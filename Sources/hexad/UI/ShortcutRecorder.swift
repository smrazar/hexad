import AppKit
import SwiftUI

/// Click it, press a chord, it is bound.
///
/// Recording uses a local key monitor rather than the responder chain: the chords worth binding
/// are exactly the ones AppKit would otherwise route somewhere else — ⌘Tab to the menu bar, ⌥Space
/// to the input source switcher — and a monitor sees them before that happens.
struct ShortcutRecorder: View {

    var binding: KeyBinding?
    var onRecord: (KeyBinding) -> Void
    var onClear: (() -> Void)?

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var isHovering = false
    /// Set when a keystroke was rejected, so the control can say why instead of ignoring the
    /// user. A recorder that silently does nothing reads as broken, not as "not allowed".
    @State private var rejection: String?

    var body: some View {
        HStack(spacing: Theme.Space.s8) {
            if let rejection, isRecording {
                Text(rejection)
                    .font(Font(Theme.Font.caption))
                    .foregroundStyle(Color(nsColor: Palette.NS.textSecondary))
            }

            Button { toggleRecording() } label: {
                Text(label)
                    .font(Font(Theme.Font.monoSmall))
                    .foregroundStyle(Color(nsColor: isRecording
                                           ? Palette.NS.accent
                                           : Palette.NS.textPrimary))
                    .frame(minWidth: 62)
                    .padding(.horizontal, Theme.Space.s8)
                    .padding(.vertical, Theme.Space.s4 + 1)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .fill(Color(nsColor: isRecording
                                        ? Palette.NS.accentSoft
                                        : Palette.NS.surfaceSecondary))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .strokeBorder(Color(nsColor: isRecording
                                                ? Palette.NS.accent
                                                : Palette.NS.border))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isRecording ? "Press the keys to bind, or Esc to cancel" : "Click to rebind")

            // Hover reveals, it does not add — §11. The slot is always 16pt wide, so nothing
            // shifts when the clear button appears.
            Group {
                if let onClear, binding != nil, isHovering, !isRecording {
                    Button(action: onClear) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(nsColor: Palette.NS.textTertiary))
                    }
                    .buttonStyle(.plain)
                    .help("Remove this shortcut")
                    .accessibilityLabel("Remove this shortcut")
                } else {
                    Color.clear
                }
            }
            .frame(width: 16, height: 16)
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: Theme.Motion.fast), value: isHovering)
        .onDisappear(perform: stopRecording)
    }

    private var label: String {
        if isRecording { return "Press keys…" }
        return binding?.label ?? "Not set"
    }

    // MARK: - Recording

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        stopRecording()
        isRecording = true
        rejection = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Esc means "leave it as it was", which is the only way out that does not bind
            // something. Binding Esc itself would take the cancel key away from every dialog.
            if Int64(event.keyCode) == Shortcut.Key.escape {
                stopRecording()
                return nil
            }
            if let recorded = KeyBinding(event: event) {
                onRecord(recorded)
                stopRecording()
            } else {
                rejection = "Add a modifier"
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}
