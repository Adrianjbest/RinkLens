// BUILD 697 STATE CONTRACT: authoritative mutations pass through the declared domain owner/reducer; local values are drafts, projections, snapshots or caches only.
#if canImport(SwiftUI)
import SwiftUI

// MARK: - STYLE1 Shared Broadcast Menu Style

/// Shared operator-menu styling. STYLE1 routes colours, fonts and corner
/// radii through RinkLensDesignSystem so Sponsors, Media, Settings, Stream and
/// other menus do not drift into different visual styles.
struct BroadcastMenuBackgroundView: View {
    @ObservedObject private var appearance = RinkLensAppearanceSettings.shared

    var body: some View {
        RinkLensDesignSystem.screenBackground
            .ignoresSafeArea()
            .overlay(RinkLensDesignSystem.accentGlow.ignoresSafeArea())
    }
}

struct BroadcastMenuHeaderLabel: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(RinkLensDesignSystem.font(.cardTitle))
                .foregroundStyle(RinkLensDesignSystem.accent)
                .frame(width: 22, alignment: .center)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(RinkLensDesignSystem.font(.cardTitle))
                    .foregroundStyle(RinkLensDesignSystem.primaryText)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(RinkLensDesignSystem.font(.caption))
                        .foregroundStyle(RinkLensDesignSystem.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BroadcastMenuSectionTitle: View {
    let title: String
    let systemImage: String?

    init(_ title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(RinkLensDesignSystem.font(.caption))
                    .foregroundStyle(RinkLensDesignSystem.accent)
            }
            Text(title)
                .font(RinkLensDesignSystem.font(.bodyStrong))
                .foregroundStyle(RinkLensDesignSystem.primaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BroadcastMenuCardModifier: ViewModifier {
    var cornerRadius: CGFloat = RinkLensDesignSystem.cardCornerRadius
    var opacity: Double = 0.52

    func body(content: Content) -> some View {
        content
            .font(RinkLensDesignSystem.font(.body))
            .foregroundStyle(RinkLensDesignSystem.primaryText)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(RinkLensDesignSystem.cardBackground.opacity(opacity + 0.25))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(RinkLensDesignSystem.border, lineWidth: 1)
            )
    }
}

extension View {
    func broadcastMenuCard(cornerRadius: CGFloat = RinkLensDesignSystem.cardCornerRadius, opacity: Double = 0.52) -> some View {
        modifier(BroadcastMenuCardModifier(cornerRadius: cornerRadius, opacity: opacity))
    }

    func broadcastMenuText() -> some View {
        foregroundStyle(RinkLensDesignSystem.primaryText)
            .tint(RinkLensDesignSystem.accent)
            .font(RinkLensDesignSystem.font(.body))
            .preferredColorScheme(.dark)
    }
}

struct BroadcastMenuTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<_Label>) -> some View {
        configuration
            .font(RinkLensDesignSystem.font(.bodyStrong))
            .foregroundStyle(RinkLensDesignSystem.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RinkLensDesignSystem.controlBackground, in: RoundedRectangle(cornerRadius: RinkLensDesignSystem.controlCornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: RinkLensDesignSystem.controlCornerRadius, style: .continuous).stroke(RinkLensDesignSystem.border, lineWidth: 1))
    }
}
#endif
