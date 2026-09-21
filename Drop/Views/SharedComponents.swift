import SwiftUI
import AppKit
import QuickLookThumbnailing

// MARK: - Window Layout

/// The window's size rules in one place. Every tab used to compute its own
/// content width (60% of "something", where the something differed between
/// Download, Convert and History/Log/Dev), and the window minimum was
/// declared in four places with three different numbers.
enum WindowLayout {
    /// Enforced by AppKit (window.minSize) and applied to restored/first-launch
    /// frames too. 640 is tall enough for the bottom bar plus a usable card
    /// viewport on every tab; 896 leaves the compact sidebar a comfortable
    /// main area (see minColumnWidth).
    static let minimumSize = NSSize(width: 896, height: 640)
    static let firstLaunchSize = NSSize(width: 1000, height: 720)

    static let sidebarWidth: CGFloat = 240
    static let compactSidebarWidth: CGFloat = 72
    /// The sidebar's margin from the window (leading 12 + trailing 8).
    static let sidebarMargins: CGFloat = 20
    /// Window width below which the sidebar collapses to icons.
    static let compactSidebarBreakpoint: CGFloat = 1000
    /// Window height below which the bottom bar drops its secondary chrome.
    /// Measured against the content area (window height minus the title bar),
    /// so the 720pt first-launch window (692pt of content) keeps the full bar.
    static let compactHeightBreakpoint: CGFloat = 680

    /// The centered content column every tab lays out against.
    static let minColumnWidth: CGFloat = 600
    static let maxColumnWidth: CGFloat = 1100
    static let columnPadding: CGFloat = 16
    /// Below this, side-by-side input -> output chip rows no longer fit
    /// without truncating, so they stack instead.
    static let stackedChipsBreakpoint: CGFloat = 700

    /// Width of the content column for a given main-area width: 60% of it,
    /// but never narrower than minColumnWidth (unless the area itself is), and
    /// never wider than maxColumnWidth. 0 means "not measured yet".
    static func columnWidth(mainWidth: CGFloat) -> CGFloat {
        guard mainWidth > 0 else { return 0 }
        let available = max(mainWidth - 2 * columnPadding, 0)
        return min(max(mainWidth * 0.60, minColumnWidth), available, maxColumnWidth)
    }
}

private struct ContentColumnWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
private struct CompactSidebarKey: EnvironmentKey { static let defaultValue = false }
private struct CompactHeightKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Width of the centered content column (see WindowLayout.columnWidth);
    /// 0 until ContentView has measured the main area.
    var contentColumnWidth: CGFloat {
        get { self[ContentColumnWidthKey.self] }
        set { self[ContentColumnWidthKey.self] = newValue }
    }
    var isCompactSidebar: Bool {
        get { self[CompactSidebarKey.self] }
        set { self[CompactSidebarKey.self] = newValue }
    }
    var isCompactHeight: Bool {
        get { self[CompactHeightKey.self] }
        set { self[CompactHeightKey.self] = newValue }
    }
}

extension View {
    /// Fixes a view to the shared content column (falls back to unconstrained
    /// until the width is measured), centered in its container.
    func contentColumn(_ width: CGFloat) -> some View {
        self.frame(width: width > 0 ? width : nil)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Status Badge

struct StatusBadge: View {
    let status: DownloadStatus
    var body: some View {
        StatusPill(label: status.label, color: status.color)
    }
}

/// Generic status pill — the shared visual used by both Download's and
/// Convert's in-progress/done/failed status row, so the two tabs' labels
/// always render identically instead of drifting (one plain Text, one
/// pill) out of sync with each other.
struct StatusPill: View {
    let label: String
    let color: Color
    var body: some View {
        Text(label)
            .font(.appMono(size: 10, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous).stroke(color.opacity(0.3), lineWidth: 0.5))
    }
}

// MARK: - Log View

struct LogView: View {
    let logs: [String]
    @Environment(\.isCompactHeight) private var compactHeight
    @State private var autoScroll = true

    private func exportLog() {
        let panel = NSSavePanel()
        panel.title = "Export Log"
        panel.nameFieldStringValue = "drop-log.txt"
        panel.allowedContentTypes = [.plainText]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? logs.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logs.joined(separator: "\n"), forType: .string)
    }

    // Same black-frosted-glass capsule recipe as urlCard/dropZoneView/
    // History's searchHeader -- icon+label flush left, all secondary
    // controls (auto-scroll toggle, copy, export, reveal-in-finder) as
    // plain icon chips inline on the capsule's own translucent surface,
    // matching every other icon-only control in the app instead of the
    // previous one-off embedded pill treatment.
    private var logHeader: some View {
        let fieldHeight: CGFloat = 52

        return HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundColor(.white.opacity(DesignTokens.Text.tertiary)).font(.appMono(size: 12))
            Text("Log")
                .font(.appMono(size: 13))
                .foregroundColor(.white.opacity(DesignTokens.Text.secondary))
            Spacer(minLength: 12)
            Toggle("Auto-scroll", isOn: $autoScroll)
                .toggleStyle(.checkbox)
                .font(.appMono(size: 11))
                .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
            HoverIconButton(icon: "doc.on.doc", size: 12, help: "Copy log", action: copyLog)
            HoverIconButton(icon: "square.and.arrow.up", size: 12, help: "Export log", action: exportLog)
            HoverIconButton(icon: "folder", size: 12, help: "Reveal in Finder", action: { DropLogger.shared.revealInFinder() })
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: fieldHeight, alignment: .center)
        .background(
            ZStack {
                VisualEffectBlur(material: DesignTokens.Glass.material, blendingMode: .behindWindow)
                Color.black.opacity(DesignTokens.Glass.blackTint)
                Color.white.opacity(0.55 * DesignTokens.Glass.whiteWash)
                DitherNoise(opacity: 0.04)
            }
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(DropGrid.fieldBorderOpacity), lineWidth: DropGrid.fieldBorderWidth)
            )
        )
        // Fills the tab's content column exactly (the whole Log panel is
        // pinned to it -- see ContentView), matching every other tab's
        // header bar.
        .frame(maxWidth: .infinity)
        .shadow(color: .black.opacity(DesignTokens.Interactive.glowShadowPeak), radius: 10, y: 4)
    }

    var body: some View {
        VStack(spacing: 12) {
            logHeader
                .padding(.top, compactHeight ? 26 : 40)
                .padding(.bottom, compactHeight ? 12 : 20)

            if logs.isEmpty {
                EmptyStateView(icon: "terminal", title: "No log output yet")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(logs.enumerated()), id: \.offset) { i, line in
                                Text(line)
                                    .font(.appMono(size: 11, design: .monospaced))
                                    .foregroundColor(logColor(line))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(i)
                            }
                        }
                        .padding(.horizontal, 20).padding(.vertical, 16)
                    }
                    .onChange(of: logs.count) {
                        if autoScroll, let last = logs.indices.last {
                            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                }
            }
        }
    }

    func logColor(_ line: String) -> Color {
        if line.contains("ERROR") { return .red.opacity(0.85) }
        if line.contains("WARNING") { return .orange.opacity(0.85) }
        if line.contains("✓") { return .green.opacity(0.85) }
        return .white.opacity(DesignTokens.Text.tertiary)
    }
}

// MARK: - Sidebar Tab Item

/// Vertical nav-rail row for the sidebar (Download / Convert / History). Icon-only when the sidebar is compact.
///
/// Built directly on the shared GlassInteractive base (same primitive as
/// every other clickable control in the app) using a roundedRect shape,
/// so this genuinely is a "glass button" -- real hover/press glow, rim
/// stroke, black-frosted-glass fill, grain -- not a bespoke one-off. The
/// only thing customized for this element's size is activeFillOverride:
/// the shared fillActive/fillHover/fillPress tokens were tuned for
/// chip-scale elements, and reusing them unmodified at full sidebar-row
/// width previously spread a saturated tint across enough area to read
/// as a solid color block. A lighter override keeps the same glass
/// language legible at this larger scale.
struct SidebarTabItem: View {
    let label: String
    let icon: String
    let isSelected: Bool
    var badge: String? = nil
    let action: () -> Void
    @Environment(\.isCompactSidebar) private var compact

    private static let accent = DesignTokens.Accent.primary
    // Neutral rim/fill tint for unselected tabs -- GlassInteractive tints
    // both its stroke and fill off a single `tint` color, so leaving this
    // at the accent for every row (selected or not) made every tab read
    // as blue once the rest-state rim opacity was raised for visibility.
    // Only the selected tab should carry the accent color; unselected
    // tabs get a plain white/grey rim instead.
    private static let neutral = Color.white

    var body: some View {
        GlassInteractive(
            // Pill shape instead of rounded-rect, per request. Also
            // stronger rest-state stroke (0.34 vs the shared 0.16 T.strokeRest
            // default) and a slightly higher rest fill floor -- against the
            // sidebar's own black-frosted glassCard() background, the old
            // 0.75pt/0.16-opacity hairline read as almost no border at all
            // since both surfaces sit at nearly the same near-black shade.
            shape: .capsule,
            tint: isSelected ? Self.accent : Self.neutral,
            isActive: isSelected,
            activeFillOverride: (rest: 0.05, active: 0.14, hover: 0.09, press: 0.17),
            restStrokeOverride: 0.34,
            action: action
        ) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.appMono(size: compact ? 15 : 13))
                if !compact {
                Text(label)
                    .font(.appMono(size: 13, weight: isSelected ? .semibold : .medium))
                }
                if let badge = badge, !compact {
                    // Same accent-tinted glass badge language as TabChip and
                    // every other badge/chip in the app.
                    Text(badge)
                        .font(.appMono(size: 9, weight: .semibold))
                        .foregroundColor(isSelected ? Self.accent : .white.opacity(DesignTokens.Text.secondary))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Self.accent.opacity(isSelected ? 0.18 : 0.12))
                        .clipShape(Capsule())
                }
            }
            // Centered, fixed consistent width instead of stretching full
            // sidebar width -- all tabs now the same size regardless of
            // label length. Sidebar is 240pt wide, so 216 = 90% of that.
            .foregroundColor(isSelected ? Self.accent : .white.opacity(DesignTokens.Text.secondary))
            .frame(width: compact ? WindowLayout.compactSidebarWidth - 24 : 216, alignment: .center)
            .padding(.vertical, 11)
            // Scoped to isSelected specifically -- without this, the label/
            // icon color change riding along with GlassInteractive's own
            // tint/isActive swap picked up SwiftUI's implicit default
            // animation instead, landing on flat gray for several frames
            // before settling to the accent blue.
            .animation(.easeOut(duration: 0.12), value: isSelected)
        }
        // Small horizontal room around the pill so its hover/press scale-
        // grow still has a little breathing space before the sidebar's
        // own edge -- kept tight since the pill itself is now 90% wide.
        .padding(.horizontal, 4)
        // Icon-only mode has no visible label, so the name (and count) move
        // into the tooltip and the accessibility label.
        .help(compact ? (badge.map { "\(label) (\($0))" } ?? label) : "")
        .accessibilityLabel(label)
    }
}

