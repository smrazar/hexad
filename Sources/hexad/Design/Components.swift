import SwiftUI

/// The shared controls, built once.
///
/// `design-language.md` §10 opens with "a bespoke variant is how consistency dies", and that is the
/// only reason this file exists: every button, pill and keycap in hexad comes from here, so the app
/// keeps one vocabulary rather than growing five subtly different rows.

// MARK: - Buttons

/// Accent fill, `onAccent` label, height 30, 14pt horizontal padding. One per surface.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBackdrop(configuration: configuration) { isHovering, isPressed in
            configuration.label
                .font(Font(Theme.Font.bodyEmph))
                .foregroundStyle(Color(nsColor: Palette.NS.onAccent))
                .padding(.horizontal, Theme.Space.s12 + 2)
                .frame(height: Theme.Control.height)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(Color(nsColor: isHovering ? Palette.NS.accentHover : Palette.NS.accent))
                )
                // The glow, not a size change: the main action reads as the one to press
                // without moving the layout around it.
                .shadow(color: Color(nsColor: Palette.NS.accent).opacity(isHovering ? 0.35 : 0),
                        radius: 8, y: 1)
                .opacity(isPressed ? 0.85 : 1)
        }
    }
}

/// Transparent with a hairline border. Hover fills `surfaceHover` and strengthens the border.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBackdrop(configuration: configuration) { isHovering, isPressed in
            configuration.label
                .font(Font(Theme.Font.bodyEmph))
                .foregroundStyle(Color(nsColor: Palette.NS.textPrimary))
                .padding(.horizontal, Theme.Space.s12 + 2)
                .frame(height: Theme.Control.height)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(Color(nsColor: isHovering ? Palette.NS.surfaceHover : .clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .strokeBorder(Color(nsColor: isHovering
                                            ? Palette.NS.borderStrong
                                            : Palette.NS.border))
                )
                .opacity(isPressed ? 0.85 : 1)
        }
    }
}

/// Text only, `textSecondary`. For destructive or quit actions.
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBackdrop(configuration: configuration) { isHovering, isPressed in
            configuration.label
                .font(Font(Theme.Font.body))
                .foregroundStyle(Color(nsColor: isHovering
                                       ? Palette.NS.textPrimary
                                       : Palette.NS.textSecondary))
                .padding(.horizontal, Theme.Space.s8)
                .frame(height: Theme.Control.height)
                .opacity(isPressed ? 0.85 : 1)
        }
    }
}

/// `ButtonStyle` has no hover state of its own, and `.onHover` cannot be applied to a
/// `Configuration`. One wrapper holds the state so each style does not reinvent it.
private struct HoverBackdrop<Content: View>: View {
    let configuration: ButtonStyleConfiguration
    @ViewBuilder let content: (Bool, Bool) -> Content

    @State private var isHovering = false

    var body: some View {
        content(isHovering, configuration.isPressed)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: Theme.Motion.fast), value: isHovering)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var hexadPrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var hexadSecondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

extension ButtonStyle where Self == GhostButtonStyle {
    static var hexadGhost: GhostButtonStyle { GhostButtonStyle() }
}

// MARK: - Toggle

/// 38×22 track, 18pt knob, accent when on and `borderStrong` when off. The knob squashes to
/// 22pt while held — §10's one flourish, because a toggle is the control people touch most.
///
/// This exists because `.toggleStyle(.switch)` paints itself in the **system** accent, which is
/// blue on a default Mac. hexad is monochrome plus amber; a blue switch is a second hue, and §13
/// forbids that outright. The same goes for `.pickerStyle(.segmented)` below.
struct HexToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HexSwitch(configuration: configuration)
    }
}

extension ToggleStyle where Self == HexToggleStyle {
    static var hexad: HexToggleStyle { HexToggleStyle() }
}

private struct HexSwitch: View {

    let configuration: ToggleStyleConfiguration

    @State private var isPressed = false

    private enum Metric {
        static let trackWidth: CGFloat = 38
        static let trackHeight: CGFloat = 22
        static let knob: CGFloat = 18
        static let knobHeld: CGFloat = 22
        static let inset: CGFloat = 2
    }

    var body: some View {
        let isOn = configuration.isOn

        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule(style: .continuous)
                .fill(Color(nsColor: isOn ? Palette.NS.accent : Palette.NS.surfaceSecondary))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color(nsColor: isOn ? .clear : Palette.NS.borderStrong))
                )

            Capsule(style: .continuous)
                .fill(Color(nsColor: Palette.NS.knob))
                .frame(width: isPressed ? Metric.knobHeld : Metric.knob, height: Metric.knob)
                .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                .padding(.horizontal, Metric.inset)
        }
        .frame(width: Metric.trackWidth, height: Metric.trackHeight)
        .animation(.easeOut(duration: Theme.Motion.fast), value: isOn)
        .animation(.easeOut(duration: Theme.Motion.fast), value: isPressed)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { value in
                    isPressed = false
                    // Only commit if the pointer is still on the control. Pressing and sliding
                    // off is how someone changes their mind, and it should mean nothing.
                    let bounds = CGRect(x: 0, y: 0,
                                        width: Metric.trackWidth, height: Metric.trackHeight)
                    if bounds.insetBy(dx: -6, dy: -6).contains(value.location) {
                        configuration.isOn.toggle()
                    }
                }
        )
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "on" : "off")
    }
}

// MARK: - Segmented tabs

struct SegmentedOption<Value: Hashable>: Identifiable {
    let value: Value
    let label: String
    var id: Value { value }
}

/// Track `surfaceSecondary`; the active tab is a raised `surface` chip with a hairline that
/// **slides** between positions. Never an accent fill — §10 reserves the accent for actions,
/// not for saying where you are.
/// Lives outside the generic: a nested type inside one cannot hold static stored properties.
private enum SegmentMetric {
    static let height: CGFloat = 26
    static let inset: CGFloat = 2
}

struct HexSegmented<Value: Hashable>: View {

    let options: [SegmentedOption<Value>]
    @Binding var selection: Value
    var segmentWidth: CGFloat = 64

    private typealias Metric = SegmentMetric

    private var selectedIndex: Int {
        options.firstIndex { $0.value == selection } ?? 0
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Color(nsColor: Palette.NS.surfaceSecondary))

            RoundedRectangle(cornerRadius: Theme.Radius.control - 1, style: .continuous)
                .fill(Color(nsColor: Palette.NS.surface))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.control - 1, style: .continuous)
                        .strokeBorder(Color(nsColor: Palette.NS.border))
                )
                .frame(width: segmentWidth - Metric.inset * 2,
                       height: Metric.height - Metric.inset * 2)
                .offset(x: CGFloat(selectedIndex) * segmentWidth + Metric.inset)

            HStack(spacing: 0) {
                ForEach(options) { option in
                    let isSelected = option.value == selection
                    Text(option.label)
                        .font(Font(isSelected ? Theme.Font.bodyEmph : Theme.Font.body))
                        .foregroundStyle(Color(nsColor: isSelected
                                               ? Palette.NS.textPrimary
                                               : Palette.NS.textSecondary))
                        .frame(width: segmentWidth, height: Metric.height)
                        .contentShape(Rectangle())
                        .onTapGesture { selection = option.value }
                        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }
        }
        .frame(width: segmentWidth * CGFloat(options.count), height: Metric.height)
        .animation(.easeOut(duration: Theme.Motion.swap), value: selection)
    }
}

// MARK: - Read-only state

/// Read-only state: a capsule, `accentSoft` when good and `surfaceSecondary` otherwise, always
/// with a glyph. The glyph is not decoration — §12 forbids colour as the only carrier of meaning,
/// and a pill that says "granted" in a tint nobody can distinguish says nothing.
struct StatusPill: View {
    let text: String
    var isGood: Bool = true

    var body: some View {
        HStack(spacing: Theme.Space.s4 + 2) {
            Image(systemName: isGood ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(nsColor: isGood
                                       ? Palette.NS.accent
                                       : Palette.NS.textSecondary))
            Text(text)
                .font(Font(Theme.Font.bodyEmph))
                .foregroundStyle(Color(nsColor: Palette.NS.textPrimary))
        }
        .padding(.horizontal, Theme.Space.s12)
        .padding(.vertical, Theme.Space.s4 + 2)
        .background(
            Capsule(style: .continuous)
                .fill(Color(nsColor: isGood
                            ? Palette.NS.accentSoft
                            : Palette.NS.surfaceSecondary))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

/// A shortcut in `monoSmall` on `surfaceSecondary` with a hairline border.
struct KeycapChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Font(Theme.Font.monoSmall))
            .foregroundStyle(Color(nsColor: Palette.NS.textPrimary))
            .padding(.horizontal, Theme.Space.s8)
            .padding(.vertical, Theme.Space.s4)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Color(nsColor: Palette.NS.surfaceSecondary))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(Color(nsColor: Palette.NS.border))
            )
            .accessibilityLabel("Shortcut \(text)")
    }
}
