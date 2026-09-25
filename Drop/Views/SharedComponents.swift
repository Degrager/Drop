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
    /// The row content sits 12pt in from the card edge (8 of stack padding + 4
    /// of row padding) everywhere in the rail, so rows and pills share edges.
    static let railContentInset: CGFloat = 12
    /// Width of the box every rail icon (tab, tool status, update button) sits
    /// in, and how far in from the row's leading edge that box starts. Chosen
    /// so the icon is centered in the COLLAPSED rail: because the same values
    /// are used open and closed, the icon never moves as the sidebar resizes --
    /// the text beside it is what appears and disappears.
    static let railIconSlot: CGFloat = 18
    static let railIconInset: CGFloat = (compactSidebarWidth - 2 * railContentInset - railIconSlot) / 2
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
    /// The widest the column grows: past this, extra window width becomes margin.
    static let maxColumnWidth: CGFloat = 1000
    /// The margin between the column and each edge of the main area (the space
    /// between the sidebar and the window's right edge). The column fills the
    /// area minus this, at every window width, so the cards run nearly edge to
    /// edge instead of sitting in a narrow centered strip.
    static let sidePadding: CGFloat = 12
    /// Below this, side-by-side input -> output chip rows no longer fit
    /// without truncating, so they stack instead.
    static let stackedChipsBreakpoint: CGFloat = 700
    /// Below this, card headers and History rows move their chips onto a
    /// full-width line, and option chips drop their sub-notes.
    static let narrowColumnBreakpoint: CGFloat = 540
    /// Below this the bottom bar's toggle and folder field can't share a row
    /// without the folder path being cut off, so they stack.
    static let barStackBreakpoint: CGFloat = 610

    /// Below this the bottom bar's "AUTO-OPEN FOLDER" label shortens to "AUTO-OPEN".
    static let barLabelBreakpoint: CGFloat = 720

    /// Every width that any view compares the content column against. Keep in
    /// step with those comparisons: columnClass(mainWidth:) is only exact for
    /// thresholds listed here.
    static let columnBreakpoints: [CGFloat] = [
        narrowColumnBreakpoint, barStackBreakpoint, barLabelBreakpoint, stackedChipsBreakpoint
    ]

    /// The column width reduced to which side of each breakpoint it falls on:
    /// the largest breakpoint at or below it (or one under the smallest).
    /// `class < T` gives the same answer as `columnWidth < T` for every T in
    /// columnBreakpoints, but the value only changes when a breakpoint is
    /// crossed -- so publishing it to the environment costs nothing on the
    /// dozens of resize ticks in between, while the column's ACTUAL width
    /// (ContentColumnLayout) follows the window live. 0 means "not measured".
    static func columnClass(mainWidth: CGFloat) -> CGFloat {
        let width = columnWidth(mainWidth: mainWidth)
        guard width > 0 else { return 0 }
        return columnBreakpoints.filter { $0 <= width }.max() ?? ((columnBreakpoints.min() ?? 1) - 1)
    }

    /// Width of the content column for a given main-area width: the whole area
    /// minus a small gutter each side, up to maxColumnWidth. 0 means "not
    /// measured yet".
    static func columnWidth(mainWidth: CGFloat) -> CGFloat {
        guard mainWidth > 0 else { return 0 }
        let widest = max(mainWidth - 2 * sidePadding, 0)
        return min(max(widest, minColumnWidth), widest, maxColumnWidth)
    }
}

private struct ContentColumnWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
private struct CompactSidebarKey: EnvironmentKey { static let defaultValue = false }
private struct SidebarLiveInsetKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
private struct CardContentInsetKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
private struct CompactHeightKey: EnvironmentKey { static let defaultValue = false }
private struct TinyHeightKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// The content column's width reduced to which side of each breakpoint it
    /// is on (see WindowLayout.columnClass) -- for `columnWidth < breakpoint`
    /// decisions only, NOT its real width, which ContentColumnLayout works
    /// out live from the space it is offered. 0 until ContentView has
    /// measured the main area.
    var contentColumnWidth: CGFloat {
        get { self[ContentColumnWidthKey.self] }
        set { self[ContentColumnWidthKey.self] = newValue }
    }
    var isCompactSidebar: Bool {
        get { self[CompactSidebarKey.self] }
        set { self[CompactSidebarKey.self] = newValue }
    }
    /// How much wider the sidebar is than the collapsed rail (0...168), as of
    /// where its width is HEADING: SwiftUI animates whatever consumes it (see
    /// `followsSidebar()` and LiveGlassCard), so it tracks the sidebar's edge
    /// frame by frame.
    var sidebarLiveInset: CGFloat {
        get { self[SidebarLiveInsetKey.self] }
        set { self[SidebarLiveInsetKey.self] = newValue }
    }
    /// The same, for what the page's CONTENT is laid out for. It changes in one
    /// step (opening: at once; collapsing: when the sidebar has finished
    /// shrinking) and is never animated -- see `pinnedToSidebar()`.
    var cardContentInset: CGFloat {
        get { self[CardContentInsetKey.self] }
        set { self[CardContentInsetKey.self] = newValue }
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

/// Lays its one child out as the shared content column: as wide as
/// WindowLayout.columnWidth says for the space it is OFFERED -- the area
/// between the sidebar and the window's right edge -- and never wider than
/// that space, so a card can't slide under the sidebar.
///
/// Working the width out here, from the live proposal, is what makes cards,
/// the paste bar and the bottom bar follow a window drag frame by frame with no
/// state in between: nothing has to be measured, stored and re-published, so
/// there's no stale value to catch up (or ease) to once the mouse is released.
/// It also reports the offered width as its minimum, not some remembered size,
/// so a plain `.frame(width:)`'s stale minimum can't stall a drag toward the
/// window's real minimum size.
///
/// SwiftUI asks a layout for its size several times per pass with the same
/// proposal, and each answer walks the whole child subtree, so the child's
/// answers are cached per proposal for the length of one pass (SwiftUI drops
/// the cache whenever the layout's inputs change).
private struct ContentColumnLayout: Layout {
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

    /// nil means an "ideal size" query (nothing to be a share of): the narrowest
    /// column. 0 is the window's minimum-size query: no width at all.
    private func columnWidth(offered: CGFloat?) -> CGFloat {
        guard let offered else { return WindowLayout.minColumnWidth }
        guard offered > 0 else { return 0 }
        return min(WindowLayout.columnWidth(mainWidth: offered), offered)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let w = columnWidth(offered: proposal.width)
        let size = childSize(ProposedViewSize(width: w, height: proposal.height), child, &cache)
        return CGSize(width: w, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard let child = subviews.first else { return }
        // bounds.width is the width sizeThatFits reported, i.e. already the column.
        child.place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top,
                    proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// The page sits in a frame as wide as the window allows with the sidebar
/// collapsed (ContentView.body); each piece says how it follows the sidebar.
/// The cheap bars (paste bar, toolbar, bottom bar, page headers) FOLLOW its edge
/// frame by frame with this, so they never snap. Heavy content (the cards) is
/// PINNED instead (`pinnedToSidebar()`): laid out once, in one step.
struct FollowsSidebar: ViewModifier {
    @Environment(\.sidebarLiveInset) private var live
    func body(content: Content) -> some View { content.padding(.leading, live) }
}

/// Lays heavy content out for where the sidebar will be, in one step (never
/// animated), however far the sidebar has got. See LiveGlassCard for how a card's
/// outline still follows the sidebar's edge while its contents wait.
struct PinnedToSidebar: ViewModifier {
    @Environment(\.cardContentInset) private var inset
    func body(content: Content) -> some View {
        content.padding(.leading, inset).animation(nil, value: inset)
    }
}

extension View {
    func followsSidebar() -> some View { modifier(FollowsSidebar()) }
    func pinnedToSidebar() -> some View { modifier(PinnedToSidebar()) }

    /// Lays a view out as the shared content column, centered in its
    /// container. The column already leaves the side padding, so callers add
    /// none of their own.
    func contentColumn() -> some View {
        ContentColumnLayout { self }.frame(maxWidth: .infinity)
    }
}

// MARK: - Resize facade

/// A card's last real size, remembered so a facade can stand in for it (same height,
/// so the list doesn't jump) while the window edge is being dragged.
final class SizeMemory {
    var width: CGFloat = 0
    var height: CGFloat = 0
}

/// Two children: [0] a real card, [1] its facade. Normally it is exactly the real card
/// (the facade sits at zero opacity above it). While `frozen` -- a window-edge drag --
/// it reports the facade's size instead and places the real card at its LAST size, a
/// constant proposal, so SwiftUI reuses the cached layout and the card costs nothing per
/// frame; only the facade (a few plain shapes) follows the window. Measured on the
/// Download page with 12 cards: ~57 fps -> ~118 fps during a drag. The real card stays
/// mounted throughout, so releasing the drag is one layout pass, not a rebuild.
struct FreezeLayout: Layout {
    var frozen: Bool
    let memory: SizeMemory
    private static let fallbackHeight: CGFloat = 96

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        if frozen {
            return CGSize(width: proposal.width ?? memory.width,
                          height: memory.height > 0 ? memory.height : Self.fallbackHeight)
        }
        let size = subviews[0].sizeThatFits(proposal)
        if let w = proposal.width, w > 1 {
            memory.width = w
            memory.height = size.height
        }
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let live = ProposedViewSize(width: bounds.width, height: bounds.height)
        if frozen {
            // Zero size, like ActiveOnlyLayout: a constant proposal SwiftUI can reuse the
            // cached layout for, and no real-sized glass views for AppKit to keep moving
            // (and re-blurring) under the facade on every frame of the drag.
            subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: .zero)
        } else {
            subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: live)
        }
        subviews[1].place(at: bounds.origin, anchor: .topLeading, proposal: live)
    }
}

/// The placeholder drawn in a card's place during a window drag: the card's outline plus
/// a thumbnail box, a title bar and a metadata bar. Plain shapes only (no material, no
/// animation), so it is cheap to lay out and draw at any width.
struct CardFacade: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.large, style: .continuous)
        shape
            .fill(Color(white: 0.075))
            .overlay(shape.stroke(Color.white.opacity(0.10), lineWidth: 0.75))
            .overlay(alignment: .topLeading) {
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .frame(width: CardMetrics.thumbWidth, height: CardMetrics.thumbHeight)
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(0.09))
                            .frame(maxWidth: 200)
                            .frame(height: 11)
                        Capsule()
                            .fill(Color.white.opacity(0.05))
                            .frame(maxWidth: 320)
                            .frame(height: 28)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
            }
            .allowsHitTesting(false)
    }
}

/// Swaps a card for its facade while the window edge is dragged, and fades the facade
/// back out on release (the real card is already laid out underneath by then). The real
/// card is hidden at opacity 0 with animation OFF -- never a partial opacity on glass,
/// which greys it -- so only the facade's own opacity fades.
struct FrozenDuringResize: ViewModifier {
    @ObservedObject private var live = LiveResizeState.shared
    @State private var memory = SizeMemory()

    func body(content: Content) -> some View {
        FreezeLayout(frozen: live.isActive, memory: memory) {
            content
                .opacity(live.isActive ? 0 : 1)
                .animation(nil, value: live.isActive)
                .allowsHitTesting(!live.isActive)
            CardFacade()
                .opacity(live.isActive ? 1 : 0)
        }
        // The drag start stays a cut (the window is already moving under the pointer);
        // the release is what animates: facade fades out, height settles.
        .animation(.easeOut(duration: 0.2), value: live.isActive)
    }
}

extension View {
    func frozenDuringResize() -> some View { modifier(FrozenDuringResize()) }
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
                .padding(.top, compactHeight ? 22 : 30)
                .padding(.bottom, compactHeight ? 10 : 14)
                .contentColumn()
                .followsSidebar()

            if logs.isEmpty {
                EmptyStateView(icon: "terminal", title: "No log output yet")
                    .followsSidebar()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(logs.enumerated()), id: \.offset) { i, line in
                                LogRow(line: line, color: logColor(line), tinted: i % 2 == 0)
                                    .id(i)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 14)
                    }
                    .onChange(of: logs.count) {
                        if autoScroll, let last = logs.indices.last {
                            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                }
                .contentColumn()
                .pinnedToSidebar()
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

/// One log line, split into a quiet timestamp column, a status symbol and the
/// message. Long messages wrap onto further lines.
private struct LogRow: View {
    let line: String
    let color: Color
    let tinted: Bool

    private var parts: (time: String, message: String) {
        // Lines are "[4:06:37.774 AM] message".
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return ("", line) }
        let time = String(line[line.index(after: line.startIndex)..<close])
        let message = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        return (time, message)
    }

    private var isError: Bool { line.contains("ERROR") }
    private var isWarning: Bool { line.contains("WARNING") }
    private var isSuccess: Bool { line.contains("✓") }

    private var symbol: String {
        if isError { return "xmark" }
        if isWarning { return "exclamationmark.triangle.fill" }
        if isSuccess { return "checkmark" }
        return "terminal"
    }

    /// The ✓ already says it in the symbol column.
    private var message: String {
        var text = parts.message
        if isSuccess, let range = text.range(of: "✓") {
            text.removeSubrange(range)
            text = text.trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(parts.time)
                .font(.appMono(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(DesignTokens.Text.disabled))
                .lineLimit(1)
                .frame(width: 112, alignment: .leading)
            Image(systemName: symbol)
                .font(.appMono(size: 9.5, weight: .bold))
                .foregroundColor(isError || isWarning || isSuccess ? color : .white.opacity(DesignTokens.Text.disabled))
                .frame(width: 14)
            Text(message)
                .font(.appMono(size: 11, design: .monospaced))
                .foregroundColor(color)
                .textSelection(.enabled)
                // Every line wraps in full -- long paths and error output are
                // exactly what people come to the log to read.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.white.opacity(tinted ? 0.025 : 0))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help(line)
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
/// A label that types itself out, one character at a time, when it appears --
/// instead of fading or blurring in. The full text's width is reserved from the
/// first frame, so nothing beside it moves while it types. It only types once the
/// app has been up a couple of seconds (`settled`), so labels already there at
/// launch just appear; once done it shows the current text, so a later text
/// change (the update button's "Checking…") is just a swap. The whole label
/// takes about `duration` however long it is.
struct TypedText: View {
    private static let firstUse = Date()
    /// False during launch, true after: only a reveal after that types.
    static var settled: Bool { Date().timeIntervalSince(firstUse) > 2 }

    let text: String
    var animates: Bool = true
    var delay: Double = 0.02
    var duration: Double = 0.22
    @State private var shown: Int

    init(_ text: String, animates: Bool = TypedText.settled, delay: Double = 0.02, duration: Double = 0.22) {
        self.text = text
        self.animates = animates
        self.delay = delay
        self.duration = duration
        _shown = State(initialValue: animates ? 0 : .max)
    }

    var body: some View {
        Text(text)
            .hidden()
            .overlay(alignment: .leading) {
                Text(shown >= text.count ? text : String(text.prefix(shown)))
                    .lineLimit(1)
            }
            .task {
                guard animates, shown == 0 else { return }
                let count = text.count
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                let step = min(0.04, duration / Double(max(count, 1)))
                for i in 1...max(count, 1) {
                    if Task.isCancelled { return }
                    shown = i
                    if i < count { try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000)) }
                }
                shown = .max
            }
    }
}

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
    private static let iconSlot = WindowLayout.railIconSlot
    private static let iconInset = WindowLayout.railIconInset

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
                    TypedText(label)
                        .font(.appMono(size: 13, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                        .transition(.labelFade)
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
            // One fixed content height, so a pill is exactly as tall collapsed
            // (icon only) as open (label + count badge, which is a point taller
            // than the label alone) -- the rows never grow or shrink
            // vertically while the sidebar changes width.
            .frame(height: 17)
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
        // Collapsed, the count is gone with the label -- a small dot on the icon
        // says there's something in it (the count is in the tooltip).
        .overlay(alignment: .topTrailing) {
            if compact, badge != nil {
                Circle()
                    .fill(DesignTokens.Accent.primaryLight)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(Color.black, lineWidth: 2))
                    .padding(.top, 4).padding(.trailing, 10)
                    .transition(.blurIn)
                    .allowsHitTesting(false)
            }
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


// MARK: - Card design kit
//
// The shared pieces the redesigned cards, bottom bars and history rows are
// built from, so Download, Convert and History can't drift apart:
//  - MetaLines / MetaLine: compact metadata with colored symbols
//  - SegmentedCapsule / FormRow: labelled "choose one" rows
//  - FieldCapsule: a path/text field in a capsule
//  - innerCard(): the grey card nested inside a glass card

extension ChipData {
    enum MetaColumn { case time, video, audio, other }

    /// Which column of the aligned IN / OUT grid this chip belongs in.
    var metaColumn: MetaColumn {
        switch icon {
        case "clock", "internaldrive": return .time
        case "waveform": return .audio
        case "video", "video.badge.waveform": return .video
        default: return .other
        }
    }

    /// The symbol's color: blue video, green audio, warm for conversions,
    /// red for failures, quiet white for length/size.
    var metaIconColor: Color {
        if color == .blue { return DesignTokens.Accent.primaryLight }
        if color == .green { return DesignTokens.Accent.success }
        if color == .orange { return DesignTokens.Accent.warning }
        if color == .red { return DesignTokens.Accent.danger }
        return .white.opacity(0.5)
    }
}

/// One metadata item as text with its symbol: no capsule of its own.
struct MetaCell: View {
    let chip: ChipData

    private var primary: Color { .white.opacity(0.88) }
    private var dim: Color { .white.opacity(DesignTokens.Text.tertiary) }

    /// "AAC · 2.0 · 128kbps" reads as "AAC" bright and "2.0 128kbps" quiet;
    /// video and length keep everything bright.
    private func text(_ raw: String, dimTail: Bool) -> Text {
        let tokens = raw.components(separatedBy: " · ")
        guard dimTail, tokens.count > 1 else { return Text(tokens.joined(separator: " ")) }
        return Text(tokens[0] + " ") + Text(tokens.dropFirst().joined(separator: " ")).foregroundColor(dim)
    }

    var body: some View {
        HStack(spacing: 5) {
            if let icon = chip.icon {
                Image(systemName: icon)
                    .font(.appMono(size: 10, weight: .bold))
                    .foregroundColor(chip.metaIconColor)
            }
            if !chip.label.isEmpty {
                Text(chip.label)
                    .font(.appMono(size: 10, weight: .bold))
                    .foregroundColor(chip.metaIconColor)
            }
            text(chip.value, dimTail: chip.metaColumn == .audio)
                .font(.appMono(size: 10.5, weight: .medium))
                .foregroundColor(primary)
            if let icon2 = chip.icon2, let value2 = chip.value2 {
                Image(systemName: icon2)
                    .font(.appMono(size: 10, weight: .bold))
                    .foregroundColor(chip.metaIconColor)
                    .padding(.leading, 3)
                Text(value2)
                    .font(.appMono(size: 10.5, weight: .medium))
                    .foregroundColor(primary)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// "IN" and "OUT" lines for a card header: what you have, then what you'll
/// get, in fixed columns (time and size, video, audio) so the eye can read
/// straight down from source to result. Falls back to wrapping lines when the
/// column is too narrow for the grid. Both lines sit inside ONE rounded capsule.
struct MetaLines: View {
    let input: [ChipData]
    let output: [ChipData]

    private func tag(_ text: String, out: Bool) -> some View {
        Text(text)
            .font(.appMono(size: 8.5, weight: .bold))
            .tracking(0.8)
            .foregroundColor(out ? DesignTokens.Accent.primaryLight : .white.opacity(0.34))
            .frame(minWidth: 22, alignment: .leading)
    }

    @ViewBuilder
    private func cell(_ chips: [ChipData], _ column: ChipData.MetaColumn) -> some View {
        if let chip = chips.first(where: { $0.metaColumn == column }) {
            MetaCell(chip: chip)
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }

    private func wrapped(_ chips: [ChipData], _ label: String, out: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            tag(label, out: out)
            FlowLayout(spacing: 4) {
                ForEach(chips, id: \.self) { MetaCell(chip: $0) }
            }
        }
    }

    /// The aligned grid. `withTime` false leaves out the length / size column, so
    /// a narrower place (a Convert queue row) still gets the same two lines of
    /// video and audio before anything has to wrap.
    private func grid(withTime: Bool) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
            if !input.isEmpty {
                GridRow {
                    tag("IN", out: false)
                    if withTime { cell(input, .time) }
                    cell(input, .video)
                    cell(input, .audio)
                }
            }
            if !output.isEmpty {
                GridRow {
                    tag("OUT", out: true)
                    if withTime { cell(output, .time) }
                    cell(output, .video)
                    cell(output, .audio)
                }
            }
        }
    }

    var body: some View {
        if input.isEmpty && output.isEmpty {
            EmptyView()
        } else {
            // The padding is inside the fit test, so the grid is only picked when
            // it fits with its capsule around it; the capsule hugs its content.
            ViewThatFits(in: .horizontal) {
                grid(withTime: true)
                grid(withTime: false)
                VStack(alignment: .leading, spacing: 3) {
                    if !input.isEmpty { wrapped(input, "IN", out: false) }
                    if !output.isEmpty { wrapped(output, "OUT", out: true) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 17, style: .continuous).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(Color.white.opacity(DesignTokens.Field.borderRest), lineWidth: 0.75))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A single line of metadata (History rows, Convert queue rows): the same
/// symbols and text as MetaLines, separated by thin dividers.
struct MetaLine: View {
    let chips: [ChipData]
    /// Draws the line inside the same capsule MetaLines uses (Convert queue rows).
    var inCapsule: Bool = false

    private var separator: some View {
        Rectangle().fill(Color.white.opacity(0.2)).frame(width: 0.75, height: 10)
    }

    private var oneLine: some View {
        HStack(spacing: 9) {
            ForEach(Array(chips.enumerated()), id: \.offset) { index, chip in
                if index > 0 { separator }
                MetaCell(chip: chip)
            }
        }
    }

    private var wrapped: some View {
        FlowLayout(spacing: 8) {
            ForEach(chips, id: \.self) { MetaCell(chip: $0) }
        }
    }

    var body: some View {
        if chips.isEmpty {
            EmptyView()
        } else if inCapsule {
            // The padding is inside the fit test, so the line is only picked when it
            // fits with its capsule around it; the capsule hugs its content.
            ViewThatFits(in: .horizontal) {
                oneLine.padding(.horizontal, 12).padding(.vertical, 6)
                wrapped.padding(.horizontal, 12).padding(.vertical, 6)
            }
            .background(RoundedRectangle(cornerRadius: 17, style: .continuous).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(Color.white.opacity(DesignTokens.Field.borderRest), lineWidth: 0.75))
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ViewThatFits(in: .horizontal) {
                oneLine
                wrapped
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: Segmented capsule

struct SegmentOption: Identifiable {
    let id: String
    let label: String
    var icon: String? = nil
    /// nil = no badge. true = "Native" (green dot), false = "Re-encodes" (amber dot).
    var nativeBadge: Bool? = nil
    var help: String = ""
    var isSelected: Bool
    var tint: Color = DesignTokens.Accent.primary
    let action: () -> Void
}

/// "Choose one" as a single capsule holding every option, the selected one
/// lit. When the options don't fit on one line they wrap as separate capsules.
struct SegmentedCapsule: View {
    let options: [SegmentOption]
    /// true: the segments share the capsule's full width. false: they hug
    /// their labels (mode toggles with two or three short options).
    var fill: Bool = true

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 2) {
                ForEach(options) { SegmentButton(option: $0, fill: fill, standalone: false) }
            }
            .padding(3)
            .background(Color.white.opacity(0.04), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(DesignTokens.Field.borderRest), lineWidth: 0.75))
            FlowLayout(spacing: 6) {
                ForEach(options) { SegmentButton(option: $0, fill: false, standalone: true) }
            }
        }
        .frame(maxWidth: fill ? .infinity : nil, alignment: .leading)
    }
}

private struct SegmentButton: View {
    let option: SegmentOption
    let fill: Bool
    /// True when wrapped onto its own line: draws its own capsule border.
    let standalone: Bool
    @State private var hovering = false
    @State private var glowPhase = false

    private static let restingStroke: Double = 0.8
    private static let restingGlow: Double = 0.4

    var body: some View {
        let T = DesignTokens.Interactive.self
        let selected = option.isSelected
        Button(action: option.action) {
            HStack(spacing: 5) {
                if let icon = option.icon {
                    Image(systemName: icon)
                        .font(.appMono(size: 11, weight: .semibold))
                }
                if let native = option.nativeBadge {
                    Circle()
                        .fill(native ? DesignTokens.Accent.success : DesignTokens.Accent.warning)
                        .frame(width: 5, height: 5)
                }
                Text(option.label)
                    .font(.appMono(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                    // A segment is never narrower than its label: the row wraps
                    // (see SegmentedCapsule) before a label would be cut.
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundColor(selected ? option.tint : .white.opacity(hovering ? DesignTokens.Text.primary : DesignTokens.Text.tertiary))
            .padding(.horizontal, 12)
            .frame(maxWidth: fill ? .infinity : nil)
            .frame(height: 26)
            .background(
                Capsule().fill(
                    selected ? option.tint.opacity(0.14)
                        : Color.white.opacity(hovering ? T.fillHover * 0.4 : (standalone ? T.fillRest : 0))
                )
            )
            .overlay(
                Capsule().stroke(
                    selected ? option.tint.opacity(glowPhase ? T.strokeGlow : Self.restingStroke)
                        : (standalone ? Color.white.opacity(hovering ? T.strokeHover : T.strokeRest) : Color.clear),
                    lineWidth: selected ? 1.0 : 0.5
                )
            )
            // The selected glow is steady; it pulses only under the pointer
            // (a repeatForever animation on something sitting on screen keeps
            // the whole window redrawing every frame -- see SelectorChip).
            .shadow(color: selected ? option.tint.opacity(glowPhase ? T.glowShadowHover : Self.restingGlow) : .clear,
                    radius: selected ? 6 : 0)
        }
        .buttonStyle(.plain)
        .onHover { h in
            hovering = h
            if h && selected {
                withAnimation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true)) { glowPhase = true }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { glowPhase = false }
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.spring(response: 0.2), value: selected)
        .help(option.help)
    }
}

// MARK: Form row

/// A settings row: the label (and a small hint) on the left, one control on the
/// right. In a narrow column the label sits above the control instead.
struct FormRow<Content: View>: View {
    let icon: String
    let label: String
    /// Small text under the label ("Original: ProRes").
    var hint: String? = nil
    /// Shows the Native / Re-encodes legend under the label instead.
    var showsNativeLegend: Bool = false
    @ViewBuilder let content: () -> Content
    @Environment(\.contentColumnWidth) private var columnWidth
    private var stacked: Bool { columnWidth > 0 && columnWidth < WindowLayout.narrowColumnBreakpoint }

    private var labelBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.appMono(size: 10, weight: .semibold))
                    .frame(width: 14, alignment: .center)
                Text(label)
                    .font(.appMono(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundColor(.white.opacity(DesignTokens.Text.secondary))
            if showsNativeLegend {
                nativeLegend()
                    .padding(.leading, 20)
            } else if let hint, !hint.isEmpty {
                Text(hint)
                    .font(.appMono(size: 9))
                    .foregroundColor(.white.opacity(DesignTokens.Text.disabled))
                    .lineLimit(1)
                    .padding(.leading, 20)
            }
        }
    }

    var body: some View {
        if stacked {
            VStack(alignment: .leading, spacing: 6) {
                labelBlock
                content()
            }
        } else {
            // The label column is only as wide as the longest label ("OUTPUT FORMAT",
            // icon included) plus a little air -- it used to be 150pt, which left a
            // ~70pt hole between the label and its selector.
            HStack(alignment: .center, spacing: 10) {
                labelBlock
                    .frame(width: 112, alignment: .leading)
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: Field capsule + inner card

/// A folder path or text field drawn as a capsule.
struct FieldCapsule<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: DropGrid.rowSpacing) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: DropGrid.controlHeight)
            .padding(.horizontal, 14)
            .background(Color.white.opacity(DropGrid.fieldFillOpacity))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(DropGrid.fieldBorderOpacity), lineWidth: DropGrid.fieldBorderWidth))
    }
}

/// Browse and Reveal, side by side next to a folder capsule: the same icon
/// buttons as everywhere else, each with a hover caption saying what it does.
struct FolderActionButtons: View {
    let path: String
    let onChoose: (String) -> Void

    var body: some View {
        HStack(spacing: DropGrid.rowSpacing) {
            HoverIconButton(icon: "folder", size: 13, help: "Choose folder", expandable: true) {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.canCreateDirectories = true
                panel.allowsMultipleSelection = false
                panel.prompt = "Select"
                panel.directoryURL = URL(fileURLWithPath: path)
                if panel.runModal() == .OK, let url = panel.url { onChoose(url.path) }
            }
            HoverIconButton(icon: "arrow.up.forward.app", size: 13, help: "Reveal in Finder", expandable: true) {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        }
        .frame(height: DropGrid.controlHeight)
    }
}

/// The estimated total size, at the trailing end of a folder capsule (it also
/// rides along in the capsule's tooltip).
struct FolderSizeLabel: View {
    let label: String?

    var body: some View {
        if let label {
            HStack(spacing: 4) {
                Image(systemName: "internaldrive")
                    .font(.appMono(size: 9))
                Text(label)
                    .font(.appMono(size: 10, weight: .semibold))
            }
            .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
            .fixedSize()
        }
    }
}

extension View {
    /// The grey card nested inside a glass card (the bottom bar's controls, the
    /// sidebar's update block): the same recipe the bottom bar's SAVE TO
    /// section has always used, so utility zones read as separate from the
    /// black content cards around them.
    func innerCard(cornerRadius: CGFloat = DesignTokens.Radius.medium) -> some View {
        glassCard(cornerRadius: cornerRadius, opacity: 0.35)
    }
}
