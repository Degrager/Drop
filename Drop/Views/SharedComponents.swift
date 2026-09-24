import SwiftUI
import AppKit
import QuickLookThumbnailing

// MARK: - Window Layout

/// The window's size rules in one place. Every tab used to compute its own
/// content width (60% of "something", where the something differed between
/// Download, Convert and History/Log/Dev), and the window minimum was
/// declared in four places with three different numbers.
enum WindowLayout {
    // MARK: Window size

    /// Hard window minimum. Both numbers are the WHOLE window frame (title bar
    /// included) -- what Accessibility Inspector reports and NSWindow.minSize
    /// takes -- not the content area.
    static let minimumSize = NSSize(width: 800, height: 800)
    /// Every launch opens at this frame size (see DropAppDelegate).
    static let defaultSize = NSSize(width: 1050, height: 800)

    // MARK: Sidebar

    static let sidebarWidth: CGFloat = 240
    static let compactSidebarWidth: CGFloat = 72
    /// 0 = fully collapsed, 1 = fully expanded, for an in-flight sidebar width.
    static func sidebarExpansion(_ width: CGFloat) -> CGFloat {
        min(max((width - compactSidebarWidth) / (sidebarWidth - compactSidebarWidth), 0), 1)
    }
    /// The sidebar's margin from the window (leading 12 + trailing 8).
    static let sidebarMargins: CGFloat = 20
    /// Window width below which the sidebar collapses to icons.
    static let compactSidebarBreakpoint: CGFloat = 1000

    // MARK: Height breakpoints (against the content area: window minus title bar)

    /// Below this the bottom bar drops its secondary chrome and the top padding
    /// tightens. The 720pt first-launch window (692pt of content) keeps the full bar.
    static let compactHeightBreakpoint: CGFloat = 680
    /// Below this there's no room for pinned chrome AND a card list, so the
    /// bottom bar (and list header) scroll with the cards instead of staying
    /// pinned, and the sidebar sheds its logo and tool readouts.
    static let tinyHeightBreakpoint: CGFloat = 500

    // MARK: Content column

    /// The narrowest a card (and the paste bar, list header and bottom bar,
    /// which share its width) is ever allowed to get.
    static let minColumnWidth: CGFloat = 380
    static let maxColumnWidth: CGFloat = 1100
    /// Side padding never drops below this, however small the window gets.
    static let minSidePadding: CGFloat = 8
    /// At or above this main-area width the column is the roomy 60%; at or
    /// below tightMainWidth it fills the area minus minSidePadding; in between
    /// the share grows steadily -- so the side padding shrinks as the window
    /// does, rather than staying a fixed multiple of a shrinking window.
    static let comfortableMainWidth: CGFloat = 1500
    static let tightMainWidth: CGFloat = 480
    /// Below this, side-by-side input -> output chip rows no longer fit
    /// without truncating, so they stack instead.
    static let stackedChipsBreakpoint: CGFloat = 700
    /// Below this, card headers and History rows move their chips onto a
    /// full-width line, and option chips drop their sub-notes.
    static let narrowColumnBreakpoint: CGFloat = 540
    /// Below this the bottom bar's toggle and folder field can't share a row
    /// without the folder path being cut off, so they stack.
    static let barStackBreakpoint: CGFloat = 610

    /// Width of the content column for a given main-area width. 0 means "not
    /// measured yet".
    static func columnWidth(mainWidth: CGFloat) -> CGFloat {
        guard mainWidth > 0 else { return 0 }
        let fillShare = 1 - 2 * minSidePadding / mainWidth
        let t = min(max((comfortableMainWidth - mainWidth) / (comfortableMainWidth - tightMainWidth), 0), 1)
        let share = 0.60 + (fillShare - 0.60) * t
        let widest = max(mainWidth - 2 * minSidePadding, 0)
        return min(max(mainWidth * share, minColumnWidth), widest, maxColumnWidth)
    }
}

private struct ContentColumnWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
private struct CompactSidebarKey: EnvironmentKey { static let defaultValue = false }
private struct SidebarWidthKey: EnvironmentKey { static let defaultValue: CGFloat = WindowLayout.sidebarWidth }
private struct CompactHeightKey: EnvironmentKey { static let defaultValue = false }
private struct TinyHeightKey: EnvironmentKey { static let defaultValue = false }

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
    /// The sidebar card's CURRENT width, animated between compactSidebarWidth
    /// and sidebarWidth. Everything inside that should shrink/grow with the
    /// card (tab pills, paddings) derives from this, not from the discrete
    /// isCompactSidebar flag -- the flag flips instantly, so anything sized
    /// from it snaps to its final size while the card is still mid-animation.
    var sidebarWidth: CGFloat {
        get { self[SidebarWidthKey.self] }
        set { self[SidebarWidthKey.self] = newValue }
    }
    var isCompactHeight: Bool {
        get { self[CompactHeightKey.self] }
        set { self[CompactHeightKey.self] = newValue }
    }
    var isTinyHeight: Bool {
        get { self[TinyHeightKey.self] }
        set { self[TinyHeightKey.self] = newValue }
    }
}

/// Keeps its one child mounted (so its state survives) but only lays it out
/// while `isActive`. Inactive, it reports zero size and gives the child a fixed
/// zero proposal, which SwiftUI memoizes -- so a hidden-but-mounted view costs
/// nothing on each window-resize tick.
struct ActiveOnlyLayout: Layout {
    var isActive: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard isActive, let child = subviews.first else { return .zero }
        return child.sizeThatFits(proposal)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        child.place(at: bounds.origin, anchor: .topLeading,
                    proposal: isActive ? ProposedViewSize(width: bounds.width, height: bounds.height) : .zero)
    }
}

/// Gives its one child exactly `width` when there's room, but never REPORTS
/// `width` as a minimum: it reports whatever it's proposed, capped at `width`.
/// A plain `.frame(width:)` reports `width` as a hard minimum, and since the
/// column width is derived from the last settled window width, the window's
/// own minimum size was propped up by the size it had a moment ago -- a drag
/// (or programmatic resize) toward the real minimum stalled well above it and
/// only crept down a step at a time.
///
/// SwiftUI asks a layout for its size several times per pass with the same
/// proposal, and each answer walks the whole child subtree, so the child's
/// answers are cached per proposal for the length of one pass (SwiftUI drops
/// the cache whenever the layout's inputs change).
private struct ContentColumnLayout: Layout {
    var width: CGFloat

    struct Cache {
        var fitted: [Proposal: CGSize] = [:]
    }

    struct Proposal: Hashable {
        var width: CGFloat?
        var height: CGFloat?
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    private func childSize(_ proposal: ProposedViewSize, _ child: LayoutSubview, _ cache: inout Cache) -> CGSize {
        let key = Proposal(width: proposal.width, height: proposal.height)
        if let hit = cache.fitted[key] { return hit }
        let size = child.sizeThatFits(proposal)
        cache.fitted[key] = size
        return size
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let w = min(width, proposal.width ?? width)
        let size = childSize(ProposedViewSize(width: w, height: proposal.height), child, &cache)
        return CGSize(width: w, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard let child = subviews.first else { return }
        let w = min(width, bounds.width)
        child.place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top,
                    proposal: ProposedViewSize(width: w, height: bounds.height))
    }
}

extension View {
    /// Fixes a view to the shared content column, centered in its container.
    /// The column already leaves the side padding, so callers add none of
    /// their own. Until the width is measured it falls back to the minimum
    /// side padding.
    @ViewBuilder
    func contentColumn(_ width: CGFloat) -> some View {
        if width > 0 {
            ContentColumnLayout(width: width) { self }.frame(maxWidth: .infinity)
        } else {
            self.padding(.horizontal, WindowLayout.minSidePadding)
        }
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
    @Environment(\.isTinyHeight) private var tiny

    private static let accent = DesignTokens.Accent.primary
    // Neutral rim/fill tint for unselected tabs -- GlassInteractive tints
    // both its stroke and fill off a single `tint` color, so leaving this
    // at the accent for every row (selected or not) made every tab read
    // as blue once the rest-state rim opacity was raised for visibility.
    // Only the selected tab should carry the accent color; unselected
    // tabs get a plain white/grey rim instead.
    private static let neutral = Color.white
    private static let iconSlot: CGFloat = 18
    /// Leading inset that centers the icon slot in the COLLAPSED pill
    /// (compactSidebarWidth - the 24pt of side room the pill leaves).
    private static let iconInset: CGFloat = (WindowLayout.compactSidebarWidth - 24 - iconSlot) / 2

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
                // The icon sits in a fixed slot at a fixed inset, so it stays
                // exactly where it is whether the pill is wide (icon + label)
                // or collapsed to an icon -- there it happens to be centered
                // (see iconInset), and the label just appears to its right.
                Image(systemName: icon)
                    .font(.appMono(size: 14))
                    .frame(width: Self.iconSlot)
                if !compact {
                    Text(label)
                        .font(.appMono(size: 13, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                        .transition(.blurInLeading)
                    // Pushes the count to the pill's trailing edge; the label
                    // and icon stay leading-aligned.
                    Spacer(minLength: 0)
                    if let badge = badge {
                        // Same accent-tinted glass badge language as TabChip and
                        // every other badge/chip in the app.
                        Text(badge)
                            .font(.appMono(size: 9, weight: .semibold))
                            .foregroundColor(isSelected ? Self.accent : .white.opacity(DesignTokens.Text.secondary))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Self.accent.opacity(isSelected ? 0.18 : 0.12))
                            .clipShape(Capsule())
                            .transition(.blurInLeading)
                    }
                }
            }
            .padding(.leading, Self.iconInset)
            .padding(.trailing, 14)
            .foregroundColor(isSelected ? Self.accent : .white.opacity(DesignTokens.Text.secondary))
            // Fills whatever width the card gives it (the card's own frame, less
            // the row's side padding, is 24pt narrower) rather than reading the
            // width itself: a per-pill `.frame(width:)` from an environment
            // value gave each pill its own animated attribute, and different
            // tabs picked up different animation curves mid-collapse, so some
            // shrank well before others. Sized by layout from ONE animated
            // frame, every pill is in lock-step by construction.
            // Leading-aligned; clipped so a label that's still on its way out can't
            // spill past a pill that's already narrower than it.
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .padding(.vertical, tiny ? 6 : 11)
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

