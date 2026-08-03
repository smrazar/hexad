import SwiftUI

/// An uppercase `caption` heading with an optional icon, above a card of rows: `surface`, `card`
/// radius, hairline border, rows separated by a 1pt divider inset by the row padding.
/// `design-language.md` §10.
struct SettingsSection<Content: View>: View {

    let title: String
    var systemImage: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s12) {
            HStack(spacing: Theme.Space.s8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .medium))
                }
                Text(title.uppercased())
                    .font(Font(Theme.Font.caption))
                    .tracking(0.6)
            }
            .foregroundStyle(Color(nsColor: Palette.NS.textTertiary))

            VStack(spacing: 0) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Color(nsColor: Palette.NS.surface))
            )
            // Rows paint their own selection wash edge to edge, which squares off the card's
            // rounded corners — the amber ran past the curve on the first and last row. The card
            // has to clip its contents, not merely sit behind them.
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Color(nsColor: Palette.NS.border))
            )
        }
    }
}

/// Optional 20pt icon · label + one line of grey description · trailing control.
///
/// The description is not optional in spirit — §10 — so it is a required parameter here. A setting
/// that cannot be explained in one line needs rethinking, and making the argument mandatory is the
/// cheapest way to keep having that thought.
struct SettingsRow<Trailing: View>: View {

    let title: String
    let description: String
    var systemImage: String?
    var showsDivider: Bool = true
    @ViewBuilder let trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: Theme.Space.s12) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color(nsColor: Palette.NS.textSecondary))
                        .frame(width: Theme.Control.rowIcon)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Font(Theme.Font.body))
                        .foregroundStyle(Color(nsColor: Palette.NS.textPrimary))
                    Text(description)
                        .font(Font(Theme.Font.caption))
                        .foregroundStyle(Color(nsColor: Palette.NS.textSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The label column yields first. Without this the trailing control was compressed
                // instead, and a status pill squeezed to 20pt wraps into a vertical column of
                // letters — the control has an intrinsic width and text has somewhere to go.
                .layoutPriority(1)

                Spacer(minLength: Theme.Space.s12)
                trailing
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.vertical, Theme.Space.rowVertical)
            .padding(.horizontal, Theme.Space.rowHorizontal)

            if showsDivider {
                Rectangle()
                    .fill(Color(nsColor: Palette.NS.border))
                    .frame(height: 1)
                    .padding(.leading, Theme.Space.rowHorizontal)
            }
        }
    }
}
