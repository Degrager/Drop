import SwiftUI
import AppKit
import QuickLookThumbnailing

// MARK: - Shared Media Card

/// Data-driven card used by both Download and Convert tabs.
/// Both wrappers (DownloadRow, ConvertJobCard) map their model onto this.
struct MediaCardBadge: Identifiable {
    let id = UUID()
    let label: String
    let color: Color
    var background: Color = .white.opacity(DesignTokens.Interactive.fillRest)
}

struct MediaCardAction {
    let isGlass: Bool      // true = GlassButton, false = IconButton
    let label: String      // GlassButton label (unused for icon)
    let icon: String
    let color: Color       // IconButton tint (unused for glass)
    let action: () -> Void

    static func glass(_ label: String, icon: String, action: @escaping () -> Void) -> MediaCardAction {
        MediaCardAction(isGlass: true, label: label, icon: icon, color: .white, action: action)
    }
    static func icon(_ icon: String, color: Color, action: @escaping () -> Void) -> MediaCardAction {
        MediaCardAction(isGlass: false, label: "", icon: icon, color: color, action: action)
    }
}

// MARK: - Small Action Button

/// Shared small icon+label action button used for inline row-level actions
/// (Reveal in Finder, Retry/Redownload, Re-paste, fix-action hints, etc).
/// Consolidates what were previously separate inline Button blocks in
/// HistoryViews and MediaItemCard into one reusable, consistently-styled shape.
struct SmallActionButton: View {
    let label: String
    let icon: String
    var tint: Color = .white
    // `filled` = true means "this needs your attention" (fix-action, failed
    // retry) -- it should visually stand out from routine actions at rest,
    // not just on hover. Maps onto GlassInteractive's `isActive`, which is
    // exactly this always-lit-vs-lights-on-hover distinction everywhere
    // else in the app (TabChip's selected state, ToolsStatusPill's warning
    // state), so "needs attention" reads consistently across the whole UI.
    var filled: Bool = false
    let action: () -> Void

    var body: some View {
        GlassInteractive(shape: .roundedRect(DesignTokens.Radius.small), tint: tint, isActive: filled, action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: filled ? .semibold : .regular))
                Text(label).font(.system(size: 10, weight: filled ? .semibold : .medium)).lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
        }
    }
}

// Non-generic AnyView-based card to avoid Swift type-checker complexity limits.
struct MediaCard: View {
    // Left leading
    var showCheckbox: Bool = false
    var isChecked: Bool = false
    var checkboxDisabled: Bool = false
    var onCheckboxToggle: (() -> Void)? = nil
    var thumbnail: NSImage? = nil
    var thumbnailPlaceholderIcon: String = "doc"
    // Status icon
    var statusIconName: String
    var statusColor: Color
    // Content
    var title: String
    var badges: [MediaCardBadge] = []
    var subtitle: String
    var progressFraction: CGFloat? = nil
    var progressColor: Color = .white
    // Detail slot — extra views below subtitle (nil = no detail)
    var detail: AnyView? = nil
    // Right action buttons
    var actions: [MediaCardAction] = []
    // Expandable log section
    var logLines: [String] = []

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {

                // Optional checkbox
                if showCheckbox {
                    HoverIconButton(
                        icon: isChecked ? "checkmark.circle.fill" : "circle",
                        size: 16, isActive: isChecked, disabled: checkboxDisabled
                    ) { onCheckboxToggle?() }
                    .padding(.top, 3)
                }

                // Optional thumbnail
                if showCheckbox { // only convert tab uses thumbnail
                    ZStack {
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous)
                            .fill(Color.white.opacity(DesignTokens.Interactive.fillRest))
                        if let thumb = thumbnail {
                            Image(nsImage: thumb)
                                .resizable().scaledToFill().clipped()
                        } else {
                            Image(systemName: thumbnailPlaceholderIcon)
                                .font(.system(size: 16, weight: .thin))
                                .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                        }
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous))
                }

                // Status icon
                Image(systemName: statusIconName)
                    .font(.system(size: 14))
                    .foregroundColor(statusColor)
                    .padding(.top, 3)

                VStack(alignment: .leading, spacing: 5) {
                    // Title + badges
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(DesignTokens.Text.primary))
                            .lineLimit(1).truncationMode(.middle)
                        ForEach(badges) { badge in
                            Text(badge.label)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(badge.color)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(badge.background)
                                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous).stroke(badge.color.opacity(0.25), lineWidth: 0.5))
                        }
                    }

                    // Progress bar
                    if let pct = progressFraction {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.white.opacity(DesignTokens.Interactive.fillRest)).frame(height: 3)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(progressColor.opacity(0.55))
                                    .frame(width: geo.size.width * pct, height: 3)
                                    .animation(.linear(duration: 0.3), value: pct)
                            }
                        }
                        .frame(height: 3)
                    }

                    // Subtitle
                    Text(subtitle)
                        .font(.system(size: 11)).foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                        .lineLimit(1).truncationMode(.middle)

                    // Detail slot
                    if let d = detail { d }
                }

                Spacer()

                // Action buttons
                HStack(spacing: 6) {
                    ForEach(Array(actions.enumerated()), id: \.offset) { _, a in
                        if a.isGlass {
                            GlassButton(label: a.label, icon: a.icon, action: a.action)
                        } else {
                            IconButton(icon: a.icon, color: a.color, action: a.action)
                        }
                    }
                    if !logLines.isEmpty {
                        IconButton(icon: expanded ? "chevron.up" : "chevron.down", color: .white.opacity(DesignTokens.Text.tertiary)) {
                            withAnimation(.spring(response: 0.25)) { expanded.toggle() }
                        }
                    }
                }
            }
            .padding(14)

            // Log expansion
            if expanded && !logLines.isEmpty {
                GlassDivider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(logLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(line.contains("ERROR") ? .red.opacity(0.8) : .white.opacity(DesignTokens.Text.tertiary))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(10)
                }
                .frame(maxHeight: 120)
                .background(Color.black.opacity(0.25))
            }
        }
        .glassCard(cornerRadius: DesignTokens.Radius.medium, opacity: 0.35)
    }
}
