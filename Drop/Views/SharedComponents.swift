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

    /// Hard window minimum, one for each sidebar state. Both numbers are the
    /// WHOLE window frame (title bar included) -- what Accessibility Inspector
    /// reports and NSWindow.minSize takes -- not the content area. The sidebar
    /// no longer auto-collapses as the window narrows (see DropAppDelegate and
    /// ContentView.isCompactSidebar -- removed per the user's own call: the
    /// live-resize-triggered animation was a real, repeated source of resize
    /// lag no matter how it was tuned). Instead the floor itself changes with
    /// the sidebar's own state: toggling it open grows the window to at least
    /// minimumSizeExpanded if it's currently narrower (see
    /// DropAppDelegate.sidebarCollapsedDidChange); toggling it closed only
    /// ever lowers the floor, so the window never needs to move.
    static let minimumSizeCollapsed = NSSize(width: 800, height: 800)
    static let minimumSizeExpanded = NSSize(width: 1000, height: 800)
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
    static let maxColumnWidth: CGFloat = 850
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
    var metrics = CardFacadeMetrics()
}

/// What a card's facade needs to know about the real card it stands in for, measured from
/// the real card while it is laid out normally and remembered by SizeMemory: the facade then
/// draws a title bar as long as the title and a capsule the size of the metadata's, from
/// these numbers alone -- nothing real is laid out while the window or sidebar moves.
struct CardFacadeMetrics: Equatable {
    /// Intrinsic width of the title text.
    var titleWidth: CGFloat = 0
    /// The IN / OUT (or error) capsule.
    var metaSize: CGSize = .zero
    var expanded = false
    var analyzing = false
    /// Buttons on the header's trailing edge (the last one is the card's main control).
    var buttonCount = 0
    /// The progress column between the text and the buttons (a download under way).
    var hasStatus = false
    /// The outcome label there instead (a download that has finished).
    var hasStatusLabel = false
    /// The link line under the header, shown while a card is expanded.
    var hasLink = false
    /// A row in the Convert queue: no card of its own (it sits inside the queue's), compact.
    var flat = false
    /// A flat row's move controls (the up / down pair before its thumbnail).
    var hasLeadingControls = false
    /// Every visible "field" in the settings content -- a caption, a SegmentedCapsule pill, a
    /// DropdownField/DropdownBitrateField box -- measured ONCE from the real layout (see
    /// `reportsFacadeFieldShape`) and replayed by CardFacade as plain grey shapes at these
    /// exact positions/sizes while frozen. Two hand-authored, counted versions of this came
    /// before it (`settingsFieldCounts`/`topStripSegmentCounts`) and both needed a new call
    /// site update for every new card layout, plus still guessed at individual widths --
    /// reported live as still not matching ("the width of the fields in the facade dont
    /// match the width and the layout of the fields in the actual card"). This one is
    /// fully generic: any card automatically gets a correctly-shaped facade for whatever
    /// fields its real settings content actually has, with no per-layout code here at all.
    /// Keyed by each field's own stable id (SegmentOption.id, DropdownField.id, ...) rather
    /// than a plain array, so a field that disappears (a row hidden for the current format)
    /// removes only its own entry (`onDisappear`) instead of leaving a stale phantom shape
    /// or needing some other reset-and-rebuild dance between independent reporters.
    /// Coordinates are relative to the card's own top-left (the `"cardFacadeFields"` named
    /// coordinate space established in FrozenDuringResize), which is also where CardFacade
    /// itself is placed, so a measured rect and the shape drawn from it always land in the
    /// same spot.
    var fieldShapes: [String: FieldShape] = [:]

    /// What kind of element a reported shape stands in for -- every entry used to be drawn
    /// identically regardless of what it really was, so a row caption, a DropdownField box,
    /// and a SegmentedCapsule pill all came out as the same small-cornered grey rectangle.
    /// Reported live: "pills show up as individual boxes" (the real pill is a true Capsule,
    /// with no border of its own -- its group shares ONE capsule background, see
    /// SegmentedCapsule.oneLine) and text captions weren't drawn at all.
    enum Kind {
        /// A FieldCaption label ("RESOLUTION", "DOWNLOAD AS", ...) -- a thin bar, not a box.
        case text
        /// A DropdownField/DropdownBitrateField's own box -- the standard rounded rect.
        case field
        /// One segment of a SegmentedCapsule -- a true pill/capsule shape.
        case pill
        /// An invisible layout-only placeholder (e.g. a `Color.clear` standing in a field's
        /// unused half of a row) -- draws nothing, but still claims its share of a row's
        /// growth the way its real, blank `.frame(maxWidth: .infinity)` sibling would.
        /// Without this, a row split between one real flexible field and one blank flexible
        /// placeholder reported the real field alone as that row's only stretching item, so
        /// it silently absorbed the placeholder's share too and grew twice as wide as it
        /// should -- reported live as "the right side of the facades doesn't scale properly."
        case spacer
    }

    struct FieldShape: Equatable {
        var rect: CGRect
        var kind: Kind = .field
        /// For `.pill` only: the SegmentedCapsule row this segment belongs to (its
        /// `groupID`). Every segment sharing one `group` is drawn as ONE capsule spanning
        /// all of them, not as separate pills side by side -- the real row shares ONE
        /// continuous capsule background (SegmentedCapsule.oneLine's own
        /// `.background(..., in: Capsule())`); an unselected segment has no fill or
        /// border of its own at all. Reported live: "the pill selectors are made up of
        /// individual pills next to each other instead of one big pill."
        var group: String? = nil
        /// For `.pill` only: the real SegmentedCapsule's own `fill` value -- `true` means
        /// its segments share the row's full available width (the row genuinely stretches
        /// with the card, e.g. Download's OUTPUT FORMAT); `false` means segments hug their
        /// own labels regardless of available room (e.g. DOWNLOAD AS, CONVERT AS -- never
        /// wider than their content, no matter how wide the card gets). `.field` entries
        /// always stretch (DropdownField/DropdownBitrateField fill their own slot
        /// internally, unconditionally); `.text` entries never do (a caption is always its
        /// own natural size). Reported live: "facade blocks should be an exact match in
        /// design and placement to the actual elements" -- treating every entry as equally
        /// flexible was wrong the moment a row mixed a fixed and a flexible sibling.
        var pillFills: Bool = true
    }
    /// True once the card itself (not just a piece of it) has reported.
    var reported = false
}

/// The card's own state (expanded, analyzing, which buttons it has), published by PreviewCard
/// as a preference. The MEASURED parts (title width, capsule size) do not travel this way:
/// preferences emitted from inside a GeometryReader never reached the freeze wrapper, so
/// they are written straight into the card's SizeMemory (see `reportsToFacade`).
struct CardFacadeMetricsKey: PreferenceKey {
    static var defaultValue = CardFacadeMetrics()
    static func reduce(value: inout CardFacadeMetrics, nextValue: () -> CardFacadeMetrics) {
        let next = nextValue()
        if next.reported { value = next }
    }
}

private struct CardFacadeMemoryKey: EnvironmentKey { static let defaultValue: SizeMemory? = nil }

extension EnvironmentValues {
    /// The SizeMemory of the card this view belongs to, provided by FrozenDuringResize.
    var cardFacadeMemory: SizeMemory? {
        get { self[CardFacadeMemoryKey.self] }
        set { self[CardFacadeMemoryKey.self] = newValue }
    }
}

private struct FacadeReporter: ViewModifier {
    @Environment(\.cardFacadeMemory) private var memory
    let apply: (inout CardFacadeMetrics, CGSize) -> Void

    func body(content: Content) -> some View {
        content.background(GeometryReader { geo in
            Color.clear
                .onAppear { report(geo.size) }
                .onChange(of: geo.size) { _, size in report(size) }
        })
    }

    private func report(_ size: CGSize) {
        // A frozen card is given no room, so what it measures then is not its size.
        guard let memory, !LiveResizeState.shared.freezesCards, size.width > 1 else { return }
        apply(&memory.metrics, size)
    }
}

extension View {
    /// Reports this view's size into its card's SizeMemory as one part of the facade metrics
    /// (a plain write into a class: nothing re-renders because of it).
    func reportsToFacade(_ apply: @escaping (inout CardFacadeMetrics, CGSize) -> Void) -> some View {
        modifier(FacadeReporter(apply: apply))
    }

    /// This view is the card's metadata capsule.
    func reportsFacadeMeta() -> some View {
        reportsToFacade { metrics, size in metrics.metaSize = size }
    }
}

/// The named coordinate space `reportsFacadeFieldShape` measures every field against --
/// established once, in FrozenDuringResize, around the same content CardFacade replaces,
/// so a measured rect and the shape CardFacade draws from it always share one origin
/// regardless of where the whole card is currently positioned on screen.
let cardFacadeFieldsSpace = "cardFacadeFields"

private struct FacadeFieldShapeReporter: ViewModifier {
    @Environment(\.cardFacadeMemory) private var memory
    let id: String
    let kind: CardFacadeMetrics.Kind
    let group: String?
    let pillFills: Bool

    func body(content: Content) -> some View {
        content.background(GeometryReader { geo in
            Color.clear
                .onAppear { report(geo.frame(in: .named(cardFacadeFieldsSpace))) }
                .onChange(of: geo.frame(in: .named(cardFacadeFieldsSpace))) { _, rect in report(rect) }
                .onDisappear { memory?.metrics.fieldShapes[id] = nil }
        })
    }

    private func report(_ rect: CGRect) {
        // A frozen card is given no room, so what it measures then is not its real shape.
        guard let memory, !LiveResizeState.shared.freezesCards, rect.width > 1 else { return }
        memory.metrics.fieldShapes[id] = .init(rect: rect, kind: kind, group: group, pillFills: pillFills)
    }
}

extension View {
    /// Marks this view as one visible piece of the settings content -- a FieldCaption label,
    /// a SegmentedCapsule pill, a DropdownField/DropdownBitrateField box -- whose measured
    /// frame CardFacade's resize placeholder should redraw as a plain grey shape while frozen
    /// (`kind` decides which real shape it's drawn as -- see CardFacadeMetrics.Kind) -- see
    /// CardFacadeMetrics.fieldShapes's own doc comment for why this replaces two earlier,
    /// hand-counted versions. `id` must be stable and unique among this card's OTHER fields
    /// (an option's own `.id`, a field's own `id:` string) -- it's the dictionary key this
    /// field's shape is stored/removed under, independent of every other field's own
    /// lifecycle. `group` only matters for `.pill`: every segment sharing one `group` draws
    /// as one shared capsule (see CardFacadeMetrics.FieldShape.group). A no-op everywhere
    /// this isn't inside a facade-tracked card (cardFacadeMemory is nil): every other use of
    /// these shared components (Convert's queue reorder controls, chips elsewhere in the
    /// app, ...) pays nothing for this.
    func reportsFacadeFieldShape(id: String, kind: CardFacadeMetrics.Kind = .field, group: String? = nil, pillFills: Bool = true) -> some View {
        modifier(FacadeFieldShapeReporter(id: id, kind: kind, group: group, pillFills: pillFills))
    }
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

/// The placeholder drawn in a card's place while the window or sidebar moves: the card's
/// outline, its thumbnail box, a title bar as long as the title, a capsule the size of the
/// metadata's, the header buttons, and -- for an expanded card -- placeholder settings rows.
/// Plain shapes only (no material, no animation, nothing measured), drawn from the sizes
/// SizeMemory remembered.
///
/// Built so that as little as possible changes on each frame of a drag: the left-anchored
/// pieces (thumbnail, title bar, capsule, link line) have FIXED sizes -- a card's title and
/// metadata do not change length as the window narrows, and a card narrower than they are
/// simply clips them -- so SwiftUI never has to touch them again. Only what tracks the card's
/// width moves: the outline, the header buttons on its right edge, and the settings rows.
struct CardFacade: View {
    var metrics: CardFacadeMetrics
    @Environment(\.contentColumnWidth) private var columnWidth

    /// Same rule as PreviewCard: in a narrow column the capsule moves below the thumbnail row.
    private var narrow: Bool { columnWidth > 0 && columnWidth < WindowLayout.narrowColumnBreakpoint }
    private var titleWidth: CGFloat { metrics.titleWidth > 0 ? metrics.titleWidth : 200 }
    private var metaSize: CGSize { metrics.metaSize.width > 0 ? metrics.metaSize : CGSize(width: 320, height: 26) }
    private var capsuleBesideTitle: Bool { !narrow }

    /// Height of the thumbnail / title row, which the header buttons centre on.
    private var headerHeight: CGFloat {
        max(CardMetrics.thumbHeight, 12 + (capsuleBesideTitle ? 4 + metaSize.height : 0))
    }

    private func button(_ side: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous)
            .fill(Color.white.opacity(0.06))
            .frame(width: side, height: side)
    }

    private var capsule: some View {
        RoundedRectangle(cornerRadius: 17, style: .continuous)
            .fill(Color.white.opacity(0.05))
            .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.75))
            .frame(width: metaSize.width, height: metaSize.height)
    }

    private var thumbnailBox: some View {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous)
            .fill(Color.white.opacity(0.06))
            .frame(width: CardMetrics.thumbWidth, height: CardMetrics.thumbHeight)
    }

    private func titleBar(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.white.opacity(0.09))
            .frame(width: titleWidth, height: height)
    }

    /// Everything on the left: fixed sizes, never re-laid-out while the card resizes.
    private var leading: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                thumbnailBox
                VStack(alignment: .leading, spacing: 4) {
                    titleBar(height: 12)
                    if capsuleBesideTitle { capsule }
                }
            }
            if narrow { capsule }
            if metrics.hasLink {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 300, height: 9)
            }
        }
        .fixedSize()
    }

    /// The progress column of a downloading card: a status line over a slim bar.
    private var statusColumn: some View {
        VStack(alignment: .trailing, spacing: 5) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.white.opacity(0.07))
                .frame(width: 70, height: 8)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .frame(width: CardMetrics.statusWidth, height: 4)
        }
        .frame(width: CardMetrics.statusWidth, alignment: .trailing)
    }

    /// The outcome label of a finished download, in the room the Reveal button leaves it.
    private var statusLabel: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.white.opacity(0.07))
            .frame(width: 52, height: 8)
            .frame(width: CardMetrics.statusWidth - (metrics.buttonCount >= 3 ? CardMetrics.buttonSlot : 0), alignment: .trailing)
    }

    /// The only piece that stretches with the card while frozen: one plain rounded shape per
    /// real field the card has actually reported (see CardFacadeMetrics.fieldShapes), each
    /// drawn at its own measured position and size, plus a divider 12pt above the topmost
    /// one -- matching the 12pt gap the real settings content itself uses above its first
    /// row. No per-layout code at all: whatever fields a card's real settings content has,
    /// this draws that many placeholders, at their real widths, in their real places. Two
    /// earlier, hand-authored/hand-counted versions of this both needed a call-site update
    /// for every new card layout and still guessed at individual field widths -- reported
    /// live as still not matching ("the width of the fields in the facade dont match the
    /// width and the layout of the fields in the actual card").
    /// One item the row-distribution algorithm below treats as a single unit: either a
    /// non-pill field shape, or a whole pill GROUP already merged into one capsule rect
    /// (see `settingsRows`). `stretches` says whether HStack would actually give this
    /// item more room as its row's own available width grows -- `.field` always does
    /// (DropdownField/DropdownBitrateField fill their own slot internally); `.text`
    /// never does (a caption is its own natural size); `.pill` depends on the real
    /// SegmentedCapsule's own `fill` value (CardFacadeMetrics.FieldShape.pillFills).
    private struct FacadeItem {
        var rect: CGRect
        var kind: CardFacadeMetrics.Kind
        var stretches: Bool
    }

    /// Every visible piece of the settings content, positioned to an EXACT match of where
    /// the real layout would put it at the card's CURRENT (possibly resized) width --
    /// not an approximation. A single blanket scale/stretch treated every field as
    /// equally flexible, which is wrong the moment a row mixes a fixed sibling (DOWNLOAD
    /// AS, CONVERT AS -- SegmentedCapsule's own `fill: false`) with a flexible one
    /// (OUTPUT FORMAT, RESOLUTION) side by side: only the flexible one should actually
    /// grow or shrink. Reported live, in order: "the width of the fields in the facade
    /// dont match... the actual card", "pills show up as individual boxes... arent
    /// matching placement", "the facades dont resize with the window", "the facades dont
    /// line up with the actual fields", and finally "facade blocks should be an exact
    /// match in design and placement to the actual elements" -- this replaces every
    /// earlier approximation (a blanket scaleEffect, a plain offset) with the real thing:
    /// items are clustered into rows by Y-overlap (two items in the same visual row, by
    /// construction, share overlapping Y-ranges), each row's own available-width DELTA is
    /// split only among that row's stretching items, and every other item keeps its exact
    /// original width, shifting only by however much its stretching neighbors ahead of it
    /// (in reading order) have already grown -- precisely how HStack itself distributes
    /// space among fixed and flexible siblings.
    private var settingsRows: some View {
        GeometryReader { geo in
            if let bounds = metrics.fieldShapes.values.reduce(into: CGRect?.none, { result, shape in result = result?.union(shape.rect) ?? shape.rect }) {
                // `bounds` is measured inside the card's own horizontal padding on both
                // sides (bounds.minX IS that left inset), but `geo` is the card's full,
                // unpadded width -- comparing them directly overcounts both insets as
                // growth every time (reported live as the facade overshooting the card's
                // real right edge, most visibly on a row that already spans the full
                // width). Subtracting the same inset from both sides of `geo` first makes
                // the two widths comparable.
                let availableWidth = geo.size.width - 2 * bounds.minX
                let delta = bounds.width > 1 ? availableWidth - bounds.width : 0
                // Every .pill segment sharing one `group` merges into ONE capsule spanning
                // all of them -- the real row shares one continuous capsule background
                // (SegmentedCapsule.oneLine), not separate pills side by side.
                let pillGroups: [String: (rect: CGRect, fills: Bool)] = metrics.fieldShapes.values
                    .filter { $0.kind == .pill }
                    .reduce(into: [:]) { result, shape in
                        let key = shape.group ?? ""
                        result[key] = (result[key]?.rect.union(shape.rect) ?? shape.rect, shape.pillFills)
                    }
                let items: [FacadeItem] = metrics.fieldShapes.values
                    .filter { $0.kind != .pill }
                    .map { .init(rect: $0.rect, kind: $0.kind, stretches: $0.kind == .field || $0.kind == .spacer) }
                    + pillGroups.values.map { value in
                        // Outset to match the real row's own 3pt padding between its
                        // segments and the shared outer capsule.
                        .init(rect: value.rect.insetBy(dx: -3, dy: -3), kind: .pill, stretches: value.fills)
                    }
                // Cluster into visual rows by Y-overlap, then within each row distribute
                // that row's own share of `delta` only among its stretching items, in X
                // order, so a fixed item shifts by however much stretching neighbors
                // BEFORE it already grew, but never changes its own width.
                let rows: [[FacadeItem]] = items
                    .sorted { $0.rect.minY < $1.rect.minY }
                    .reduce(into: []) { rows, item in
                        if let last = rows.indices.last, rows[last].contains(where: { $0.rect.minY < item.rect.maxY && item.rect.minY < $0.rect.maxY }) {
                            rows[last].append(item)
                        } else {
                            rows.append([item])
                        }
                    }
                // Each entry also keeps its own pre-shift local X (rect.minX - bounds.minX)
                // so a `.text` caption -- placed in its OWN row, directly above the field it
                // labels rather than beside it -- can be re-anchored to that field below.
                let placedRaw: [(rect: CGRect, kind: CardFacadeMetrics.Kind, originalLocalX: CGFloat)] = rows.flatMap { row in
                    let sortedRow = row.sorted { $0.rect.minX < $1.rect.minX }
                    let flexCount = sortedRow.filter(\.stretches).count
                    let growth = flexCount > 0 ? delta / CGFloat(flexCount) : 0
                    var shift: CGFloat = 0
                    return sortedRow.map { item in
                        let originalLocalX = item.rect.minX - bounds.minX
                        let newRect = CGRect(x: originalLocalX + shift, y: item.rect.minY - bounds.minY,
                                              width: max(0, item.rect.width + (item.stretches ? growth : 0)), height: item.rect.height)
                        if item.stretches { shift += growth }
                        return (newRect, item.kind, originalLocalX)
                    }
                }
                // A DropdownField/DropdownBitrateField's caption and its own box are both
                // `.leading`-aligned siblings in ONE VStack (same for a pill group's caption),
                // so they start at (almost) the same original X -- but a row like Convert's
                // VIDEO (CODEC + RESOLUTION + BITRATE side by side) puts every field's caption
                // in ONE row-cluster above ALL of them, with no stretching item of its own
                // (captions never stretch), so that row's shift stayed 0 for every caption in
                // it regardless of how far its own field had already shifted below -- reported
                // live as "the label facades... dont move when resizing." Fix: re-anchor every
                // `.text` item to whichever non-text item started at (nearly) the same original
                // local X, inheriting that item's shift (never its growth -- a caption's own
                // width never changes).
                let nonTextPlaced = placedRaw.filter { $0.kind != .text }
                let placed: [(rect: CGRect, kind: CardFacadeMetrics.Kind)] = placedRaw.map { entry in
                    guard entry.kind == .text,
                          let partner = nonTextPlaced.min(by: { abs($0.originalLocalX - entry.originalLocalX) < abs($1.originalLocalX - entry.originalLocalX) }),
                          abs(partner.originalLocalX - entry.originalLocalX) < 1.5
                    else { return (entry.rect, entry.kind) }
                    let inheritedShift = partner.rect.minX - partner.originalLocalX
                    return (CGRect(x: entry.originalLocalX + inheritedShift, y: entry.rect.minY, width: entry.rect.width, height: entry.rect.height), entry.kind)
                }
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Color.white.opacity(0.07))
                        .frame(width: geo.size.width, height: 0.5)
                        .position(x: geo.size.width / 2, y: -12)
                    ForEach(Array(placed.enumerated()), id: \.offset) { _, entry in
                        facadeShape(kind: entry.kind, rect: entry.rect)
                    }
                }
                .offset(x: bounds.minX, y: bounds.minY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// One placeholder, shaped to match what it's standing in for and drawn at its own
    /// already-final rect (see `settingsRows`'s row-distribution algorithm above).
    @ViewBuilder
    private func facadeShape(kind: CardFacadeMetrics.Kind, rect: CGRect) -> some View {
        switch kind {
        case .pill:
            Capsule()
                .fill(Color.white.opacity(0.05))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        case .field:
            RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        case .text:
            // A thin bar, not a box -- text reads as a line, not a filled block. Vertically
            // centered in the caption's own measured height rather than filling it.
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.white.opacity(0.07))
                .frame(width: rect.width, height: 6)
                .position(x: rect.midX, y: rect.midY)
        case .spacer:
            EmptyView()
        }
    }

    // MARK: A Convert queue row

    /// The row's up / down pair: two small round buttons, one above the other.
    private var moveControls: some View {
        VStack(spacing: 2) {
            Circle().fill(Color.white.opacity(0.06)).frame(width: 21, height: 21)
            Circle().fill(Color.white.opacity(0.06)).frame(width: 21, height: 21)
        }
    }

    /// Height of a queue row's header, which its status and buttons centre on.
    private var flatHeaderHeight: CGFloat {
        max(CardMetrics.thumbHeight, metrics.hasLeadingControls ? 44 : 0,
            capsuleBesideTitle ? 11 + 4 + metaSize.height : 0)
    }

    /// A queue row has no card of its own (it sits in the queue's), so only the pieces are drawn,
    /// at the compact row's own spacing: fixed ones on the left, the status and buttons anchored
    /// to the right edge. The same rule as the card's: nothing here is measured or re-laid-out
    /// while the window moves.
    private var flatBody: some View {
        Color.clear
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 8) {
                        if metrics.hasLeadingControls { moveControls }
                        thumbnailBox
                        VStack(alignment: .leading, spacing: 4) {
                            titleBar(height: 11)
                            if capsuleBesideTitle { capsule }
                        }
                    }
                    if narrow { capsule }
                }
                .fixedSize()
                .padding(4)
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 8) {
                    if metrics.hasStatus {
                        statusColumn
                    } else if metrics.hasStatusLabel {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.white.opacity(0.07))
                            .frame(width: 52, height: 8)
                    }
                    HStack(spacing: 6) {
                        ForEach(0..<max(metrics.buttonCount, 1), id: \.self) { _ in button(28) }
                    }
                }
                .frame(height: flatHeaderHeight)
                .padding(4)
            }
            .allowsHitTesting(false)
    }

    var body: some View {
        if metrics.flat {
            flatBody
        } else {
            cardBody
        }
    }

    private var cardBody: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.large, style: .continuous)
        return shape
            .fill(Color(white: 0.075))
            .overlay(shape.stroke(Color.white.opacity(0.10), lineWidth: 0.75))
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 9) {
                    leading
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
            }
            .overlay(alignment: .topLeading) {
                // Unpadded: fieldShapes' coordinates are already relative to the card's own
                // top-left (the same "cardFacadeFields" space `content` measures against, see
                // FrozenDuringResize), so this must share that exact origin, not the (12, 10)
                // padded one `leading`'s overlay above uses.
                if metrics.expanded, !metrics.analyzing {
                    settingsRows.clipped()
                }
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 12) {
                    if metrics.hasStatus { statusColumn } else if metrics.hasStatusLabel { statusLabel }
                    HStack(spacing: 12) {
                        // Every header button is the same 28pt capsule.
                        ForEach(0..<max(metrics.buttonCount, 1), id: \.self) { _ in
                            button(28)
                        }
                    }
                }
                .frame(height: headerHeight)
                .padding(.top, 10)
                .padding(.trailing, 12)
            }
            .allowsHitTesting(false)
    }
}

/// Puts the facade where the content column WOULD be for the sidebar's current position,
/// while the sidebar collapses or expands. The real cards are laid out for where the
/// sidebar is HEADING (`pinned`, which jumps in one step), so a facade that simply filled
/// that column would snap by the sidebar's width the moment it starts to move. `live` is
/// the sidebar's animated inset, interpolated by SwiftUI, so the column for `live` is a
/// frame that glides from the old layout to the new one.
///
/// Worked out from the column's own rule (`WindowLayout.columnWidth`, centered in what is
/// left of `area` after the sidebar), NOT by sliding the left edge along with the sidebar:
/// that is only right while the column fills the space. Once it is capped (850pt) and
/// centered, the column keeps its width and only its position shifts, and a facade that
/// followed the sidebar's edge grew wider than any real card.
private struct FacadeFollowsSidebar: ViewModifier, Animatable {
    var live: CGFloat
    var pinned: CGFloat
    /// The page container's width with the sidebar collapsed; 0 until measured.
    var area: CGFloat
    /// False for a facade inside something that already follows the sidebar itself (the bottom
    /// bar's queue): shifting it as well would move it twice.
    var enabled: Bool = true
    var animatableData: CGFloat {
        get { live }
        set { live = newValue }
    }

    /// Left edge and width of the content column when the sidebar's inset is `inset`.
    private func column(at inset: CGFloat) -> (left: CGFloat, width: CGFloat) {
        let offered = max(area - inset, 0)
        let width = min(WindowLayout.columnWidth(mainWidth: offered), offered)
        return (inset + (offered - width) / 2, width)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if !enabled {
            content
        } else if area > 0 {
            let now = column(at: live)
            let laidOut = column(at: pinned)
            content
                .padding(.leading, now.left - laidOut.left)
                .padding(.trailing, (laidOut.left + laidOut.width) - (now.left + now.width))
        } else {
            content.padding(.leading, live - pinned)
        }
    }
}

/// Swaps a card for its facade while the window edge is dragged or the sidebar collapses /
/// expands, and fades the facade back out afterwards (the real card is already laid out
/// underneath by then). The real card is hidden at opacity 0 with animation OFF -- never a
/// partial opacity on glass, which greys it -- so only the facade's own opacity fades.
struct FrozenDuringResize: ViewModifier {
    /// Whether the facade glides with the sidebar's edge while it moves (cards pinned in the page).
    /// Rows inside the bottom bar are already carried along by the bar, so they say no.
    var followsSidebar = true

    /// A Convert queue row: no card of its own, and carried along by the bottom bar it sits in.
    /// Its shape is seeded rather than waited for, because a row first laid out DURING a drag
    /// (one that scrolls into view, a job added) never reports it, and would otherwise be drawn
    /// as a full card.
    init(queueRow: Bool = false) {
        followsSidebar = !queueRow
        if queueRow {
            let seeded = SizeMemory()
            seeded.metrics.flat = true
            seeded.metrics.hasLeadingControls = true
            seeded.metrics.hasStatusLabel = true
            seeded.metrics.buttonCount = 2
            _memory = State(initialValue: seeded)
        }
    }

    @ObservedObject private var live = LiveResizeState.shared
    @State private var memory = SizeMemory()
    @Environment(\.sidebarLiveInset) private var sidebarLive
    @Environment(\.cardContentInset) private var sidebarPinned

    func body(content: Content) -> some View {
        let frozen = live.freezesCards
        FreezeLayout(frozen: frozen, memory: memory) {
            content
                .environment(\.cardFacadeMemory, memory)
                // Same origin FreezeLayout places both children at (bounds.origin), so a
                // field's measured rect here lines up with the shape CardFacade draws from
                // it -- see reportsFacadeFieldShape.
                .coordinateSpace(name: cardFacadeFieldsSpace)
                .opacity(frozen ? 0 : 1)
                .animation(nil, value: frozen)
                .allowsHitTesting(!frozen)
            CardFacade(metrics: memory.metrics)
                .modifier(FacadeFollowsSidebar(live: sidebarLive, pinned: sidebarPinned, area: LiveResizeState.shared.pageAreaWidth,
                                               enabled: followsSidebar))
                .opacity(frozen ? 1 : 0)
        }
        // The card's own state (expanded, analyzing, buttons). Only while it is really laid
        // out, like the measurements: a frozen card is given no room.
        .onPreferenceChange(CardFacadeMetricsKey.self) { state in
            guard !frozen, state.reported else { return }
            memory.metrics.expanded = state.expanded
            memory.metrics.analyzing = state.analyzing
            memory.metrics.buttonCount = state.buttonCount
            memory.metrics.hasStatus = state.hasStatus
            memory.metrics.hasStatusLabel = state.hasStatusLabel
            memory.metrics.hasLink = state.hasLink
            memory.metrics.flat = state.flat
            memory.metrics.hasLeadingControls = state.hasLeadingControls
            memory.metrics.reported = true
        }
        // The start is always a cut (nil while freezing): during a drag the window is already
        // moving under the pointer, and a toggle must not dip through an empty frame while a
        // facade fades in over a card that has just vanished. The release is what animates:
        // the facade fades out and the height settles.
        .animation(frozen ? nil : .easeOut(duration: 0.2), value: frozen)
    }
}

extension View {
    func frozenDuringResize(queueRow: Bool = false) -> some View {
        modifier(FrozenDuringResize(queueRow: queueRow))
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
            HoverIconButton(icon: "doc.on.doc", size: 12, help: "Copy log", expandable: true, action: copyLog)
            HoverIconButton(icon: "square.and.arrow.up", size: 12, help: "Export log", expandable: true, action: exportLog)
            HoverIconButton(icon: "folder", size: 12, help: "Reveal in Finder", expandable: true, action: { DropLogger.shared.revealInFinder() })
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

    /// A size: "~111.2 MB" while it is an estimate, "111.4 MB" once it is exact. When the chip
    /// reserves the mark's room, the "~" is its own Text whose slot stays once it is invisible, so
    /// the capsule does not change width when the real size replaces the estimate.
    @ViewBuilder
    private func sizeText(_ raw: String) -> some View {
        if chip.reservesEstimateMark {
            let estimated = raw.hasPrefix("~")
            HStack(spacing: 0) {
                Text("~").opacity(estimated ? 1 : 0)
                Text(estimated ? String(raw.dropFirst()) : raw)
            }
            .font(.appMono(size: 10.5, weight: .medium))
            .foregroundColor(primary)
        } else {
            Text(raw)
                .font(.appMono(size: 10.5, weight: .medium))
                .foregroundColor(primary)
        }
    }

    var body: some View {
        // .firstTextBaseline, not the default .center -- an SF Symbol's own glyph bounds don't
        // always land in the exact vertical center of an adjacent Text's bounding box, and
        // centering the two by frame instead of by baseline read as the icon sitting a little
        // high or low against the label (same fix as DropdownField's value+subtext row).
        HStack(alignment: .firstTextBaseline, spacing: 5) {
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
            if chip.icon == "internaldrive", chip.icon2 == nil {
                // A size with no length before it.
                sizeText(chip.value)
            } else {
                text(chip.value, dimTail: chip.metaColumn == .audio)
                    .font(.appMono(size: 10.5, weight: .medium))
                    .foregroundColor(primary)
            }
            if let icon2 = chip.icon2, let value2 = chip.value2 {
                Image(systemName: icon2)
                    .font(.appMono(size: 10, weight: .bold))
                    .foregroundColor(chip.metaIconColor)
                    .padding(.leading, 3)
                sizeText(value2)
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

    var body: some View {
        if input.isEmpty && output.isEmpty {
            EmptyView()
        } else {
            MetaLinesContent(input: input, output: output)
                .metaCapsuleChrome()
                .reportsFacadeMeta()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Rows of cells in aligned columns (the IN / OUT lines): every row has `columns` cells, a column
/// is as wide as its widest cell, cells are leading-aligned and centred in their row.
///
/// Replaces `Grid` here. Inside a ViewThatFits, `Grid` measured every cell several times for each
/// size its parents asked about, and that was most of what a click in the Convert card cost (about
/// 130 ms of layout per click: taking the block out cut a burst of clicks by two thirds). The
/// cells' ideal sizes do not depend on the proposal, so they are measured ONCE per change of
/// content (the cache) and every later question is arithmetic.
struct AlignedRows: Layout {
    var columns: Int
    var columnSpacing: CGFloat = 9
    var rowSpacing: CGFloat = 3

    struct Measured {
        var sizes: [CGSize] = []
        var columnWidths: [CGFloat] = []
        var rowHeights: [CGFloat] = []
    }

    private func measure(_ subviews: Subviews) -> Measured {
        var measured = Measured()
        guard columns > 0 else { return measured }
        measured.sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        measured.columnWidths = Array(repeating: 0, count: columns)
        measured.rowHeights = Array(repeating: 0, count: (subviews.count + columns - 1) / columns)
        for (index, size) in measured.sizes.enumerated() {
            measured.columnWidths[index % columns] = max(measured.columnWidths[index % columns], size.width)
            measured.rowHeights[index / columns] = max(measured.rowHeights[index / columns], size.height)
        }
        return measured
    }

    func makeCache(subviews: Subviews) -> Measured { measure(subviews) }
    func updateCache(_ cache: inout Measured, subviews: Subviews) { cache = measure(subviews) }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Measured) -> CGSize {
        CGSize(width: cache.columnWidths.reduce(0, +) + columnSpacing * CGFloat(max(columns - 1, 0)),
               height: cache.rowHeights.reduce(0, +) + rowSpacing * CGFloat(max(cache.rowHeights.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Measured) {
        guard columns > 0 else { return }
        var y = bounds.minY
        for row in cache.rowHeights.indices {
            var x = bounds.minX
            for column in 0..<columns {
                let index = row * columns + column
                if index < subviews.count {
                    subviews[index].place(at: CGPoint(x: x, y: y + cache.rowHeights[row] / 2), anchor: .leading,
                                          proposal: ProposedViewSize(cache.sizes[index]))
                }
                x += cache.columnWidths[column] + columnSpacing
            }
            y += cache.rowHeights[row] + rowSpacing
        }
    }
}

/// The IN / OUT grid itself, with no capsule around it (see PersistentCapsule).
struct MetaLinesContent: View {
    let input: [ChipData]
    let output: [ChipData]

    private func tag(_ text: String, out: Bool) -> some View {
        Text(text)
            .font(.appMono(size: 8.5, weight: .bold))
            .tracking(0.8)
            .foregroundColor(out ? DesignTokens.Accent.primaryLight : .white.opacity(0.34))
            .frame(minWidth: 22, alignment: .leading)
    }

    private func wrapped(_ chips: [ChipData], _ label: String, out: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            tag(label, out: out)
            DividedCells(chips: chips)
        }
    }

    /// A cell, or nothing of its width when the row has none in that column.
    ///
    /// `.id(chip.value)` forces a fresh MetaCell whenever the text changes --
    /// AlignedRows is a custom Layout, and when a codec-only edit (e.g. H.265
    /// back to "Same as Source") produces the same-width monospace string in
    /// the same cell position, SwiftUI's Layout-driven placement can skip
    /// repainting that subview's Text even though its `chip` input already
    /// changed (confirmed live: the value flowing in was correct, only the
    /// pixels were stale, and any unrelated structural re-layout "healed" it).
    /// Keying identity to the value sidesteps that by remounting instead of
    /// updating in place.
    @ViewBuilder
    private func slot(_ chip: ChipData?) -> some View {
        if let chip {
            MetaCell(chip: chip).id(chip.value)
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }

    /// A divider, or an empty column of the same width where the row has nothing to divide.
    @ViewBuilder
    private func divider(_ show: Bool) -> some View {
        if show {
            MetaDivider()
        } else {
            Color.clear.frame(width: 0.75, height: 10)
        }
    }

    /// One row of the aligned grid. Each divider is a column of its own, so the dividers line up
    /// from the IN row down to the OUT row. A divider's presence is decided by whether that
    /// column exists ANYWHERE across both rows (`hasVideoColumn`/`hasAudioColumn`), not by
    /// whether THIS row happens to have a cell on both sides of it: switching the OUT row to
    /// Video Only or Audio Only leaves it with just one of video/audio, but the IN row (the
    /// source) still has both -- checking only this row's own cells hid the OUT row's divider
    /// at that column while the IN row directly above it kept showing one, an inconsistent,
    /// seemingly missing divider (reported live). Every row that has anything before a column
    /// that exists anywhere gets that divider, even where its own cell on the far side is empty.
    private func gridRow(_ chips: [ChipData], _ label: String, out: Bool, withTime: Bool, hasVideoColumn: Bool, hasAudioColumn: Bool) -> some View {
        let time = withTime ? chips.first(where: { $0.metaColumn == .time }) : nil
        let video = chips.first(where: { $0.metaColumn == .video })
        let audio = chips.first(where: { $0.metaColumn == .audio })
        return Group {
            tag(label, out: out)
            if withTime {
                slot(time)
                if hasVideoColumn { divider(hasVideoColumn && time != nil) }
            }
            if hasVideoColumn { slot(video) }
            divider(hasAudioColumn && (video != nil || time != nil))
            slot(audio)
        }
    }

    /// The aligned grid. `withTime` false leaves out the length / size column, so
    /// a narrower place (a Convert queue row) still gets the same two lines of
    /// video and audio before anything has to wrap.
    private func grid(withTime: Bool) -> some View {
        // No video column when neither row has video (an audio-only file): an empty column would
        // still cost its spacing, and push the divider away from the audio it belongs to.
        let hasVideoColumn = (input + output).contains { $0.metaColumn == .video }
        // Same idea for the audio column/divider -- see gridRow's own doc comment.
        let hasAudioColumn = (input + output).contains { $0.metaColumn == .audio }
        // The row: tag, [time, its divider if there is video], [video], the divider before audio, audio.
        let columns = 1 + (withTime ? (hasVideoColumn ? 2 : 1) : 0) + (hasVideoColumn ? 1 : 0) + 2
        return AlignedRows(columns: columns, columnSpacing: 9, rowSpacing: 3) {
            if !input.isEmpty { gridRow(input, "IN", out: false, withTime: withTime, hasVideoColumn: hasVideoColumn, hasAudioColumn: hasAudioColumn) }
            if !output.isEmpty { gridRow(output, "OUT", out: true, withTime: withTime, hasVideoColumn: hasVideoColumn, hasAudioColumn: hasAudioColumn) }
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            grid(withTime: true)
            grid(withTime: false)
            VStack(alignment: .leading, spacing: 3) {
                if !input.isEmpty { wrapped(input, "IN", out: false) }
                if !output.isEmpty { wrapped(output, "OUT", out: true) }
            }
        }
    }
}

extension View {
    /// The rounded capsule every card's metadata sits in.
    func metaCapsuleChrome() -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 17, style: .continuous).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(Color.white.opacity(DesignTokens.Field.borderRest), lineWidth: 0.75))
    }
}

/// An icon and a reason, wrapped to two lines at most (the note a card's capsule can hold).
struct NoteContent: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: icon)
                .font(.appMono(size: 9, weight: .semibold))
                .foregroundColor(DesignTokens.Accent.warning)
            Text(text)
                .font(.appMono(size: 10))
                .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What a card's metadata capsule holds.
enum CardCapsule: Equatable {
    /// The link is still being analyzed.
    case analyzing
    /// What will be / is being produced, on one line, with dividers between the kinds of
    /// metadata (length and size | video | audio). Download's card shows only this: the
    /// input side is Convert's business.
    case output([ChipData])
    /// A reason instead of metadata.
    case note(icon: String, text: String)

    /// Which kind of contents this is. Moving between kinds animates; a change WITHIN a kind
    /// (the output line following the Video / Audio toggle) does not, as before.
    enum Kind: Equatable { case analyzing, output, note }
    var kind: Kind {
        switch self {
        case .analyzing: return .analyzing
        case .output:    return .output
        case .note:      return .note
        }
    }
}

/// Measures a hidden view's own natural (unconstrained) width -- the same purpose
/// PreviewCard.swift's own WidthPreferenceKey serves for the title bar, duplicated here
/// (private to each file) because that one isn't visible outside PreviewCard.swift.
private struct CapsuleWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

/// The metadata capsule of a card that keeps its state changes in place: ONE capsule that
/// stays mounted while its contents change (analyzing -> output/note), so it grows or shrinks
/// to fit what is inside it instead of one capsule being swapped for another.
///
/// Rebuilt from scratch (2026-09-27) as one explicit state machine, after three incremental
/// patches each fixed one reported symptom and exposed another. All three traced back to the
/// SAME root cause: leaning on SwiftUI's *implicit* animation system (`.animation(value:)`,
/// default `.transition`s, a frame constraint animated to/from `nil`) to coordinate a timeline
/// that involves things implicit animation cannot see or control -- a Core Animation pulse
/// running on a raw NSView layer (invisible to SwiftUI's transition system), a state variable
/// that changes later on its own timer (not covered by an `.animation(value:)` scoped to a
/// different value), and `nil` itself (which SwiftUI cannot interpolate at all, so a
/// constraint that relaxes to `nil` always SNAPS instead of animating). Every step below is
/// driven by exactly one explicit `withAnimation` at the moment it happens, or is left
/// unanimated on purpose -- nothing is left for an ambient modifier to interpret.
struct PersistentCapsule: View {
    let content: CardCapsule
    /// How long to hold after analyzing ends before the incoming content appears -- lets the
    /// title above finish first. 0 = show immediately (e.g. toggling Video/Audio on an
    /// already-analyzed card, which never goes through `.analyzing` here at all).
    var revealDelay: Double = 0

    /// The capsule's own timeline. `analyzing` and `shown` are steady states; `growing` exists
    /// only for the ~0.3s it takes the capsule to expand from the analyzing pill's width to
    /// room enough for real content, with that content still invisible.
    private enum Phase: Equatable { case analyzing, growing, shown }

    @State private var phase: Phase
    /// What kind we last actually showed -- tracked separately from `phase` because the same
    /// "already shown" phase covers two different cases that must NOT animate the same way:
    /// a same-kind content swap (Video/Audio toggle -- no animation, matches the previous
    /// design's own rule) versus a kind change that didn't come from analyzing (output <-> note
    /// directly -- a plain cross-fade).
    @State private var lastKind: CardCapsule.Kind
    /// The last real chips/note shown, kept around independently of `content` so the capsule
    /// NEVER structurally unmounts `MetaLineContent`/`NoteContent` on its own -- only their
    /// opacity/blur change with `phase`. (Analyzing's row is separate and always mounted too;
    /// see `body`.) This is what lets every transition be a plain property animation instead
    /// of a transition-based mount/unmount, which is what caused the Core Animation pulse and
    /// the reveal-delay bugs in the first place.
    @State private var lastChips: [ChipData]?
    @State private var lastNote: (icon: String, text: String)?
    /// The incoming content's own natural (single-line) width, kept current by a hidden probe
    /// in `body` -- see `CapsuleWidthPreferenceKey`. This, not a guessed constant, is what
    /// `.growing`/`.shown` animate the capsule's width TO: a fixed placeholder (560, an earlier
    /// version of this fix) was wider than most real content, so the capsule visibly overshot
    /// past the metadata's own length once it filled in -- reported live: "the capsule expands
    /// beyond the length of the metadata after it fills in, and it actually gets taller for a
    /// split second." Measuring the real target means .growing and .shown can share ONE width
    /// (no separate "now relax to nil" step needed at all, which is what caused the late jump).
    @State private var measuredWidth: CGFloat?
    /// True for the brief window between new content landing (`lastChips`/`lastNote`
    /// changing) and the hidden probe's re-measurement actually arriving -- see the fixedSize
    /// comment above for why a same-kind swap needs this. Cleared on a fixed timer rather than
    /// waiting on the next `onPreferenceChange` firing: that closure only fires when the
    /// measured value actually differs from before, so a swap that happens to land on the
    /// exact same width would otherwise never clear this.
    @State private var contentPendingMeasurement = false
    private static let measurementSettleDuration: Double = 0.15

    private static let pillWidth: CGFloat = 150
    private static let growDuration: Double = 0.3
    private static let revealDuration: Double = 0.25
    /// Same-kind swaps and non-analyzing kind changes don't go through the grow dance, but
    /// still deserve a quick cross-fade rather than an instant pop.
    private static let swapDuration: Double = 0.2

    init(content: CardCapsule, revealDelay: Double = 0) {
        self.content = content
        self.revealDelay = revealDelay
        _phase = State(initialValue: content.kind == .analyzing ? .analyzing : .shown)
        _lastKind = State(initialValue: content.kind)
        switch content {
        case .analyzing: _lastChips = State(initialValue: nil); _lastNote = State(initialValue: nil)
        case .output(let chips): _lastChips = State(initialValue: chips); _lastNote = State(initialValue: nil)
        case .note(let icon, let text): _lastChips = State(initialValue: nil); _lastNote = State(initialValue: (icon, text))
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // The same icon-and-text row as a metadata cell (MetaCell), so the capsule is
            // exactly as tall while it waits as it is once the metadata is in it -- kept
            // structurally identical (same glyphs, same font) purely to hold that height/
            // width footprint; it is permanently invisible now that "Analyzing" itself is
            // shown in the header's progress-indicator slot instead (see analyzeProgressColumn
            // in Drop.swift), matching the Downloading/Done states, which never put their own
            // status in this capsule either. Always mounted (never conditionally switched) so
            // its disappearance is a plain opacity fade, not a transition -- see the type's own
            // doc comment for why that matters.
            HStack(spacing: 5) {
                Image(systemName: "hourglass")
                    .font(.appMono(size: 10, weight: .bold))
                Text("Analyzing\u{2026}")
                    .font(.appMono(size: 10.5, weight: .medium))
            }
            .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
            .lineLimit(1)
            .fixedSize()
            .opacity(0)

            if let chips = lastChips {
                MetaLineContent(chips: chips)
                    // Not .shown yet: force this to lay out at its own IDEAL (single-line)
                    // width regardless of whatever width the frame below is CURRENTLY
                    // proposing -- which can briefly still be the old, smaller one, since
                    // `targetWidth` depends on `measuredWidth`, and that only updates a
                    // render or two after `lastChips` does (see the hidden probe below).
                    // Without this, MetaLineContent's own DividedCells (built to WRAP onto
                    // more lines when it doesn't fit a narrow width) took that stale,
                    // too-narrow proposal at face value and wrapped to two lines for that
                    // one render -- invisible (opacity 0) but still taller, so the CAPSULE
                    // itself briefly grew taller too. Reported live: "the capsule goes from
                    // small width normal height, to tall height for a split second, back to
                    // normal height but correct width." Only .shown lets this wrap normally
                    // again, so a genuinely narrow window still wraps as before.
                    //
                    // `contentPendingMeasurement` covers the SAME class of bug for a same-
                    // kind swap while already .shown (switching audio format -- e.g. MP3 to
                    // FLAC -- with the card already expanded): `phase` never leaves .shown for
                    // that swap, so this fixedSize guard alone missed it, and the capsule
                    // visibly grew taller for a split second there too (reported live).
                    .fixedSize(horizontal: phase != .shown || contentPendingMeasurement, vertical: false)
                    .opacity(phase == .shown ? 1 : 0)
                    .blur(radius: phase == .shown ? 0 : 5)
            } else if let note = lastNote {
                NoteContent(icon: note.icon, text: note.text)
                    .fixedSize(horizontal: phase != .shown || contentPendingMeasurement, vertical: false)
                    .opacity(phase == .shown ? 1 : 0)
                    .blur(radius: phase == .shown ? 0 : 5)
            }

            // Hidden probe: measures the CURRENT content's own natural single-line width,
            // independent of whatever width the frame below currently imposes -- the same
            // technique PreviewCard.swift's title bar already uses for the same reason. Kept
            // continuously up to date (not just measured once at the start of a grow) so a
            // same-kind content swap (Video/Audio toggle) also has a correct target ready.
            Group {
                if let chips = lastChips { MetaLineContent(chips: chips) }
                else if let note = lastNote { NoteContent(icon: note.icon, text: note.text) }
            }
            .fixedSize(horizontal: true, vertical: false)
            .hidden()
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: CapsuleWidthPreferenceKey.self, value: geo.size.width)
                }
            )
        }
        // pillWidth while analyzing; the MEASURED content width for both .growing and .shown
        // (one target, shared -- no separate "now relax to nil" step, which is what caused the
        // capsule to visibly jump again right as the metadata finished fading in).
        .frame(width: phase == .analyzing ? Self.pillWidth : targetWidth, alignment: .leading)
        .clipped()
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // A plain, constant fill -- no pulse. A pulsing overlay (PulsingSkeletonView, an
        // NSViewRepresentable whose CALayer independently animates its own backgroundColor)
        // used to stand in here while analyzing; removed entirely per the user's own call:
        // "the pulse glow corner radius doesn't match the capsule, let's remove the pulsing
        // glow entirely for the cards, all we need is the light rim which works great." Two
        // real problems went away with it, not just the one asked for: the compounded opacity
        // of the pulse layered OVER this same fill read as "a light grey [capsule] because of
        // two overlapping capsules," and mixing an AppKit-hosted layer with a native SwiftUI
        // shape at the same bounds risked the sub-pixel corner mismatch that prompted this
        // request in the first place. The border below (the "rim") is unrelated and unchanged.
        .background(RoundedRectangle(cornerRadius: 17, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(Color.white.opacity(DesignTokens.Field.borderRest), lineWidth: 0.75))
        .reportsFacadeMeta()
        .frame(maxWidth: .infinity, alignment: .leading)
        .onPreferenceChange(CapsuleWidthPreferenceKey.self) { newValue in
            if measuredWidth == nil, phase == .shown {
                // The very first measurement this view instance has ever taken, with
                // content that was ALREADY resolved before this render (phase never
                // passed through .growing to get here) -- this happens when the whole
                // Download/Convert tab is torn down and rebuilt after switching to
                // another tab and back, which resets every @State here including this
                // one even though the card itself finished analyzing long ago.
                // Animating this first width made the capsule visibly grow from the
                // analyzing pill's own width every single time you returned to the
                // tab, even though nothing was actually still analyzing (reported
                // live). A genuinely new card's first measurement still animates:
                // phase is .growing (not .shown yet) at that exact moment -- see
                // growThenReveal.
                measuredWidth = newValue
            } else {
                // A brief animation here too: this can legitimately fire a frame after `advance`
                // already started an unrelated transition (the probe re-measures asynchronously),
                // so if the target nudges afterward, it eases into place instead of snapping.
                withAnimation(.easeOut(duration: 0.15)) {
                    measuredWidth = newValue
                }
            }
        }
        .onChange(of: content) { _, newContent in advance(to: newContent) }
    }

    private var targetWidth: CGFloat {
        max(measuredWidth ?? Self.pillWidth, Self.pillWidth)
    }

    /// The whole timeline lives here, as explicit `withAnimation` calls (or explicit NON-
    /// animation, e.g. leaving `.analyzing` itself unanimated so the pulse's removal has
    /// nothing ambient to inherit) -- see the type's doc comment for why.
    private func advance(to newContent: CardCapsule) {
        let previousKind = lastKind
        lastKind = newContent.kind

        switch newContent {
        case .analyzing:
            lastChips = nil
            lastNote = nil
            phase = .analyzing

        case .output(let chips):
            if previousKind == .analyzing {
                lastChips = chips
                growThenReveal()
            } else if previousKind == .output {
                // Same kind (the Video/Audio toggle's own output line changing, or a format/
                // bitrate change with the card already expanded): swap in place, unanimated --
                // matches the design this replaces, which deliberately never animated a change
                // WITHIN a kind. Still needs markPendingMeasurement: `phase` stays .shown
                // through this whole swap, so nothing else guards against the stale-width
                // wrap-then-unwrap flash (see the fixedSize comment in body).
                lastChips = chips
                markPendingMeasurement()
            } else {
                // note -> output without a trip through analyzing: a plain cross-fade.
                withAnimation(.easeInOut(duration: Self.swapDuration)) {
                    lastChips = chips
                    lastNote = nil
                }
            }

        case .note(let icon, let text):
            if previousKind == .analyzing {
                lastNote = (icon, text)
                growThenReveal()
            } else if previousKind == .note {
                lastNote = (icon, text)
                markPendingMeasurement()
            } else {
                withAnimation(.easeInOut(duration: Self.swapDuration)) {
                    lastNote = (icon, text)
                    lastChips = nil
                }
            }
        }
    }

    /// Flags that new content just landed and the hidden probe hasn't measured it yet, then
    /// clears itself after a fixed delay -- not left to `onPreferenceChange` alone, which only
    /// fires when the newly measured width actually differs from before (a swap that happens to
    /// land on the same width would otherwise never clear it).
    private func markPendingMeasurement() {
        contentPendingMeasurement = true
        Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.measurementSettleDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            contentPendingMeasurement = false
        }
    }

    /// Analyzing -> real content: grow the capsule first (visibly, from the analyzing pill's
    /// own width), then reveal the content once it's had room to land in -- never both at
    /// once, which is what read as an empty capsule (growing too early) or as two capsules
    /// (the old pulse lingering while a new width snapped in) in the versions before this one.
    private func growThenReveal() {
        withAnimation(.easeOut(duration: Self.growDuration)) {
            phase = .growing
        }
        let holdBeforeReveal = max(revealDelay, Self.growDuration)
        Task {
            try? await Task.sleep(nanoseconds: UInt64(holdBeforeReveal * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: Self.revealDuration)) {
                phase = .shown
            }
        }
    }
}

/// A single line of metadata (History rows, Convert queue rows): the same
/// symbols and text as MetaLines, separated by thin dividers.
struct MetaLine: View {
    let chips: [ChipData]
    /// Draws the line inside the same capsule MetaLines uses (Convert queue rows).
    var inCapsule: Bool = false

    var body: some View {
        if chips.isEmpty {
            EmptyView()
        } else if inCapsule {
            // The capsule hugs its content.
            MetaLineContent(chips: chips)
                .metaCapsuleChrome()
                .reportsFacadeMeta()
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            MetaLineContent(chips: chips)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The thin vertical rule between two kinds of metadata.
struct MetaDivider: View {
    var body: some View {
        Rectangle().fill(Color.white.opacity(0.2)).frame(width: 0.75, height: 10)
    }
}

/// Lays out cells on lines, wrapping at cell boundaries when a line is full. Each cell arrives
/// with its own leading divider (see DividedCells); a cell that starts a line is shifted left by
/// the divider's width, so its divider lands outside the layout's bounds and is clipped away.
/// The result: "A | B" on a line, and no divider at the start or end of any line.
///
/// One layout instead of nested ViewThatFits alternatives (all built, all measured): the
/// nesting made every click in the Convert card cost ~60 ms more than it had.
struct DividedFlow: Layout {
    var spacing: CGFloat = 9
    var lineSpacing: CGFloat = 3
    /// A divider and the gap after it: what a cell's leading divider takes.
    var dividerAdvance: CGFloat = 9.75

    private func lines(_ sizes: [CGSize], width: CGFloat) -> [[Int]] {
        var lines: [[Int]] = [[]]
        var used: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            // A line's first cell hides its divider, so it is that much narrower.
            let needed = lines[lines.count - 1].isEmpty ? size.width - dividerAdvance : used + spacing + size.width
            if !lines[lines.count - 1].isEmpty, needed > width {
                lines.append([index])
                used = size.width - dividerAdvance
            } else {
                lines[lines.count - 1].append(index)
                used = needed
            }
        }
        return lines
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let laid = lines(sizes, width: proposal.width ?? .infinity)
        var width: CGFloat = 0, height: CGFloat = 0
        for line in laid {
            let lineWidth = line.enumerated().reduce(CGFloat(0)) { total, item in
                total + sizes[item.element].width + (item.offset == 0 ? -dividerAdvance : spacing)
            }
            width = max(width, lineWidth)
            height += (line.map { sizes[$0].height }.max() ?? 0) + lineSpacing
        }
        return CGSize(width: width, height: max(height - lineSpacing, 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var y = bounds.minY
        for line in lines(sizes, width: bounds.width) {
            let lineHeight = line.map { sizes[$0].height }.max() ?? 0
            var x = bounds.minX - dividerAdvance
            for index in line {
                subviews[index].place(at: CGPoint(x: x, y: y + lineHeight / 2), anchor: .leading,
                                      proposal: ProposedViewSize(sizes[index]))
                x += sizes[index].width + spacing
            }
            y += lineHeight + lineSpacing
        }
    }
}

/// Metadata cells with a divider between neighbours on the same line: all on one line when they
/// fit, else wrapped at the cells (length | video over audio) so a divider is never left at the
/// start or end of a line, which a plain wrapping flow cannot promise (see DividedFlow).
struct DividedCells: View {
    let chips: [ChipData]

    var body: some View {
        DividedFlow {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                HStack(spacing: 9) {
                    MetaDivider()
                    MetaCell(chip: chip)
                }
            }
        }
        .clipped()
    }
}

/// One line of metadata chips with dividers between the kinds, breaking onto more lines only
/// when it has to (no capsule around it; see MetaLine, PersistentCapsule).
struct MetaLineContent: View {
    let chips: [ChipData]

    var body: some View {
        DividedCells(chips: chips)
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
    /// A second, smaller line under the label: the source's own value beside "Same as Source",
    /// or (RESOLUTION) a friendly name like "4K Ultra HD" beside every option, not just the
    /// source's. When any option in a row has one, every segment of that row takes the taller
    /// height, so the row stays aligned.
    var subtext: String? = nil
    /// True for the one option that leaves a track untouched ("Same as Source") -- DropdownField
    /// reads this, not subtext, to decide whether the field counts as "changed" (accent-tinted).
    /// Kept separate from subtext because RESOLUTION now puts a subtext on every option (not
    /// just "Same as Source"), which would otherwise have made every resolution read as
    /// unchanged the moment it had explanatory text of its own.
    var isSourceDefault: Bool = false
    let action: () -> Void
}

/// "Choose one" as a single capsule holding every option, the selected one
/// lit. When the options don't fit on one line they wrap as separate capsules.
struct SegmentedCapsule: View {
    let options: [SegmentOption]
    /// true: the segments share the capsule's full width. false: they hug
    /// their labels (mode toggles with two or three short options).
    var fill: Bool = true
    /// This row's own name ("DOWNLOAD AS", "OUTPUT FORMAT", ...), prefixed onto each
    /// option's own id to key its facade field-shape report (see reportsFacadeFieldShape) --
    /// a card can have more than one SegmentedCapsule, and their options' ids are free to
    /// collide (both rows might have an option literally called "same").
    var groupID: String = ""

    /// Every segment is as tall as the tallest kind in the row (one with a subtext).
    private var rowHeight: CGFloat { options.contains { $0.subtext != nil } ? 36 : 26 }

    @Environment(\.contentColumnWidth) private var columnWidth

    /// A generous estimate of the row's one-line width (11.5pt mono is ~6.9pt a character, plus
    /// each segment's padding). Only used to decide whether the wrapped alternative is worth
    /// BUILDING at all: a ViewThatFits builds and measures both, and with a card full of rows
    /// that doubled what every click cost.
    private var clearlyFitsOnOneLine: Bool {
        guard columnWidth > 0 else { return false }
        let estimate = options.reduce(CGFloat(6)) { total, option in
            let characters = max(option.label.count, (option.subtext?.count ?? 0) * 9 / 11)
            return total + CGFloat(characters) * 7.2 + 30
        }
        // The page column less the card's padding, the label column and a wide margin.
        return estimate < columnWidth - 260
    }

    private var oneLine: some View {
        HStack(spacing: 2) {
            ForEach(options) {
                SegmentButton(option: $0, fill: fill, standalone: false, height: rowHeight)
                    .reportsFacadeFieldShape(id: "\(groupID)_\($0.id)", kind: .pill, group: groupID, pillFills: fill)
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.04), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(DesignTokens.Field.borderRest), lineWidth: 0.75))
    }

    var body: some View {
        Group {
            if clearlyFitsOnOneLine {
                oneLine
            } else {
                ViewThatFits(in: .horizontal) {
                    oneLine
                    FlowLayout(spacing: 6) {
                        ForEach(options) {
                            SegmentButton(option: $0, fill: false, standalone: true, height: rowHeight)
                                .reportsFacadeFieldShape(id: "\(groupID)_\($0.id)", kind: .pill, group: groupID, pillFills: fill)
                        }
                    }
                }
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
    var height: CGFloat = 26
    @State private var hovering = false

    private static let restingStroke: Double = 0.8
    private static let restingGlow: Double = 0.4

    var body: some View {
        let T = DesignTokens.Interactive.self
        let selected = option.isSelected
        Button(action: option.action) {
            VStack(spacing: 1) {
                // .firstTextBaseline -- see MetaCell's identical fix.
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if let icon = option.icon {
                        Image(systemName: icon)
                            .font(.appMono(size: 11, weight: .semibold))
                    }
                    if let native = option.nativeBadge {
                        // Confirmed live (not just by theory): an Image(systemName:) under
                        // .firstTextBaseline, with no explicit baseline guide of its own,
                        // falls back to VerticalAlignment.center -- so its CENTER lands on
                        // the text's BASELINE, not on the text's cap-height middle. That
                        // reads as the dot sitting low (center at the letter's bottom).
                        // Shifting up by half the label's cap-height puts the dot's center
                        // where a reader expects it: level with the middle of a capital
                        // letter. (11.5pt semibold -- cap height ~8pt, half ~4pt.)
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .foregroundColor(native ? DesignTokens.Accent.success : DesignTokens.Accent.warning)
                            .offset(y: -2)
                    }
                    Text(option.label)
                        .font(.appMono(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                        // A segment is never narrower than its label: the row wraps
                        // (see SegmentedCapsule) before a label would be cut.
                        .fixedSize(horizontal: true, vertical: false)
                }
                .foregroundColor(selected ? option.tint : .white.opacity(hovering ? DesignTokens.Text.primary : DesignTokens.Text.tertiary))
                if let subtext = option.subtext {
                    Text(subtext)
                        .font(.appMono(size: 9))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundColor(selected ? option.tint.opacity(0.7)
                                         : .white.opacity(hovering ? DesignTokens.Text.tertiary : DesignTokens.Text.disabled))
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: fill ? .infinity : nil)
            .frame(height: height)
            .background(
                Capsule().fill(
                    selected ? option.tint.opacity(0.14)
                        : Color.white.opacity(hovering ? T.fillHover * 0.4 : (standalone ? T.fillRest : 0))
                )
            )
            .overlay(
                Capsule().stroke(
                    selected ? option.tint.opacity(Self.restingStroke)
                        : (standalone ? Color.white.opacity(hovering ? T.strokeHover : T.strokeRest) : Color.clear),
                    lineWidth: selected ? 1.0 : 0.5
                )
            )
            // A plain, constant glow -- no pulse, even under the pointer. Card
            // settings pills don't breathe anymore (see reportsFacadeFieldShape's
            // sibling change this same session, and the metadata capsule's own
            // earlier precedent: "remove the pulsing glow entirely for the cards,
            // all we need is the light rim which works great").
            .shadow(color: selected ? option.tint.opacity(Self.restingGlow) : .clear,
                    radius: selected ? 6 : 0)
        }
        .buttonStyle(.plain)
        .onHover { h in hovering = h }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.spring(response: 0.2), value: selected)
        .help(option.help)
    }
}

// MARK: Stepped slider

/// One notch of a SteppedSlider.
struct SliderStep: Identifiable {
    let id: String
    let label: String
    /// Small text under the label (the source's own value, beside "Auto").
    var subtext: String? = nil
}

/// A slider that moves in increments: one notch per step, labelled, the thumb snapping to the
/// nearest as you drag anywhere along it (or tap a notch or its label). Plain shapes and a
/// single GeometryReader: no material, no repeating animation.
struct SteppedSlider: View {
    let steps: [SliderStep]
    let selected: Int
    var tint: Color = DesignTokens.Accent.primary
    let onSelect: (Int) -> Void

    private let thumb: CGFloat = 16
    private let track: CGFloat = 4
    private let labelHeight: CGFloat = 26

    private func label(_ step: SliderStep, chosen: Bool) -> some View {
        VStack(spacing: 1) {
            Text(step.label)
                .font(.appMono(size: 10.5, weight: chosen ? .semibold : .medium))
                .foregroundColor(chosen ? tint : .white.opacity(DesignTokens.Text.tertiary))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let subtext = step.subtext {
                Text(subtext)
                    .font(.appMono(size: 9))
                    .foregroundColor(.white.opacity(DesignTokens.Text.disabled))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            let count = max(steps.count, 1)
            let column = geo.size.width / CGFloat(count)
            let chosen = min(max(selected, 0), count - 1)
            VStack(alignment: .leading, spacing: 5) {
                ZStack(alignment: .leading) {
                    // The track runs from the first notch to the last; the part the thumb has
                    // covered is lit.
                    Capsule().fill(Color.white.opacity(0.09))
                        .frame(width: max(column * CGFloat(count - 1), 0), height: track)
                        .offset(x: column / 2)
                    Capsule().fill(tint.opacity(0.55))
                        .frame(width: column * CGFloat(chosen), height: track)
                        .offset(x: column / 2)
                    ForEach(0..<count, id: \.self) { index in
                        Circle()
                            .fill(index <= chosen ? tint : Color.white.opacity(0.28))
                            .frame(width: 6, height: 6)
                            .offset(x: column * (CGFloat(index) + 0.5) - 3)
                    }
                    Circle()
                        .fill(tint)
                        .frame(width: thumb, height: thumb)
                        .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 0.75))
                        .shadow(color: tint.opacity(0.5), radius: 4)
                        .offset(x: column * (CGFloat(chosen) + 0.5) - thumb / 2)
                }
                .frame(height: thumb)
                HStack(spacing: 0) {
                    ForEach(steps.indices, id: \.self) { index in
                        label(steps[index], chosen: index == chosen).frame(width: column)
                    }
                }
                .frame(height: labelHeight, alignment: .top)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    let index = min(max(Int(value.location.x / column), 0), count - 1)
                    if index != chosen { onSelect(index) }
                }
            )
        }
        .frame(height: thumb + 5 + labelHeight)
        .animation(.spring(response: 0.22, dampingFraction: 0.85), value: selected)
    }
}

// MARK: Dropdown field

/// A small icon-and-caps caption above a field or a track's row of fields
/// ("CODEC", "VIDEO") -- a compact form of the same icon+label language used
/// throughout the app's settings rows.
struct FieldCaption: View {
    let icon: String?
    let text: String
    var body: some View {
        // .firstTextBaseline -- see MetaCell's identical fix.
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.appMono(size: 10, weight: .semibold))
                    .frame(width: 14, alignment: .center)
            }
            Text(text)
                .font(.appMono(size: icon == nil ? 9 : 10, weight: .semibold))
                .tracking(icon == nil ? 0.3 : 0)
                .lineLimit(1)
        }
        // A field's own caption (no icon: CODEC, RESOLUTION, BITRATE) sits a
        // notch dimmer than a row caption (with icon: CONVERT AS, VIDEO) --
        // the row caption is naming what the whole line is about, the field
        // caption is a quieter label on a control that already speaks for
        // itself once it has a value.
        .foregroundColor(.white.opacity(icon == nil ? DesignTokens.Text.tertiary : DesignTokens.Text.secondary))
    }
}

/// One row inside a DropdownField's open menu: its own hover state, since a
/// ForEach can't hold an array of @State for its children.
private struct DropdownMenuRow: View {
    let option: SegmentOption
    /// True for the first/last row in the list -- their OUTER corners (top for the
    /// first row, bottom for the last) round to match the menu's own outer radius
    /// instead of the plain inner-row radius, so the hover highlight doesn't poke a
    /// square corner out past the menu's rounded edge (reported live). The other two
    /// corners of an edge row, and all four of a middle row, keep the normal radius.
    let isFirst: Bool
    let isLast: Bool
    let action: () -> Void
    @State private var hovering = false

    /// DropdownMenuChrome clips the whole menu to DesignTokens.Radius.large (20),
    /// and this row sits inset by the menu content's own 4pt padding -- subtracting
    /// that padding from the outer radius keeps the row's corner CONCENTRIC with the
    /// menu's, the same relationship Apple's own nested rounded-rect chrome uses.
    private var outerRadius: CGFloat { DesignTokens.Radius.large - 4 }
    private var innerRadius: CGFloat { 8 }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(option.label)
                Spacer(minLength: 10)
                if let subtext = option.subtext {
                    Text(subtext)
                        .font(.appMono(size: 10))
                        .foregroundColor(.white.opacity(DesignTokens.Text.disabled))
                } else if option.isSelected {
                    Image(systemName: "checkmark")
                        .font(.appMono(size: 10, weight: .bold))
                }
            }
            .font(.appMono(size: 12, weight: .medium))
            .foregroundColor(option.isSelected ? DesignTokens.Accent.primaryLight : .white.opacity(DesignTokens.Text.secondary))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(hovering ? DesignTokens.Interactive.fillHover * 0.4 : 0))
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: isFirst ? outerRadius : innerRadius,
                    bottomLeadingRadius: isLast ? outerRadius : innerRadius,
                    bottomTrailingRadius: isLast ? outerRadius : innerRadius,
                    topTrailingRadius: isFirst ? outerRadius : innerRadius,
                    style: .continuous
                )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(option.help)
    }
}

/// The glass surface every DropdownField/DropdownBitrateField menu opens
/// into -- same recipe as ConvertView's fileSwitcherPopup (blur + black tint,
/// a hairline rim, two stacked shadows for real depth against the black card
/// behind it).
private struct DropdownMenuChrome<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .modifier(PopoverGlassChrome())
    }
}

/// Shared background chrome for a floating popover panel -- dropdown menus
/// (DropdownMenuChrome above) and the file switcher popup (ConvertViews.swift)
/// both use this. Backdrop blur + black tint, clipped to a rounded rect, a
/// hairline rim, two stacked shadows for real depth against the black card
/// behind it.
///
/// Used to start as a plain solid color and swap to this live VisualEffectBlur
/// ~0.5s after mounting, to survive a fast scale/position-changing pop-in
/// transition that both popovers had at the time (VisualEffectBlur's
/// .behindWindow blending re-samples whatever's behind the window at its
/// CURRENT position, live, which that transition's geometry changes could
/// outrun and bleed neighboring content into). That pop-in was removed
/// entirely in favor of a plain instant appearance (4a0a8d9) -- with no more
/// fast geometry change to survive, the solid-to-blur swap was pure leftover
/// baggage, and became its own visible glitch on its own: reported live, "the
/// menu goes from black to translucent after a second." Removed; this just
/// uses the live material from the first frame now.
struct PopoverGlassChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    VisualEffectBlur(material: DesignTokens.Glass.material, blendingMode: .behindWindow)
                    Color.black.opacity(DesignTokens.Glass.blackTint)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.large, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.large, style: .continuous)
                .stroke(Color.white.opacity(DesignTokens.Field.borderRest), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 6, y: 3)
            .shadow(color: .black.opacity(0.6), radius: 24, y: 12)
    }
}

/// A field's open popover, published up through `.anchorPreference` to
/// DropdownPopoverHost instead of drawn where the field itself sits.
///
/// Every analyze-card field lives inside PreviewCard's body, and PreviewCard
/// ends in `.liveGlassCard(...)`, which clipShapes its ENTIRE content to the
/// card's rounded rect -- popover included, no matter how high its zIndex,
/// because clipping and z-ordering are different things: clipping bounds
/// what a subtree can draw at all, z-ordering only decides who's on top
/// within whatever isn't clipped. Confirmed live: a field near the bottom of
/// the card (AUDIO's row) opened a popover that was cut off after its first
/// row, right at the card's own bottom edge. Publishing the anchor instead
/// lets ONE host, rendered as a sibling to PreviewCard (outside its clip;
/// see ConvertPreviewCard.body), draw the actual popover content.
private struct DropdownPopoverPreferenceKey: PreferenceKey {
    /// `width`/`height` are the menu's own fixed (width) or estimated (height) size --
    /// carried alongside the anchor so the host can keep the menu on screen (and pick
    /// which side of the field to open on) without waiting on a second layout pass to
    /// measure it. `height` is an estimate, not exact -- close enough to decide whether
    /// the menu would run past the bottom of the window, not a pixel-perfect fit.
    struct Entry { let anchor: Anchor<CGRect>; let width: CGFloat; let height: CGFloat; let content: () -> AnyView }
    static var defaultValue: [String: Entry] = [:]
    static func reduce(value: inout [String: Entry], nextValue: () -> [String: Entry]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Sits as a sibling to the analyze card's own content (not inside it -- see
/// DropdownPopoverPreferenceKey), and draws whichever field's popover is
/// currently open at that field's real on-screen position. One host per
/// card; every DropdownField/DropdownBitrateField on it shares its `openID`
/// binding, so opening one field's popover closes any other's automatically.
extension View {
    /// Draws whichever DropdownField/DropdownBitrateField on this view has
    /// named itself via `openID` -- as `.overlay(...)` added to THIS view
    /// from outside, not a sibling with its own GeometryReader.
    ///
    /// A preference set by a DropdownField only reaches an `.overlayPreferenceValue`
    /// called on one of ITS OWN ANCESTORS -- preferences climb a single branch of
    /// the tree, they don't cross to a sibling branch. A first version of this put
    /// the reader in a sibling view next to convertSettingsCard (both inside one
    /// ZStack); nothing a field published ever reached it, so no popover ever drew
    /// (confirmed live: every dropdown field opened and closed by its state alone,
    /// with no menu appearing at all, not even the earlier clipped-off one).
    /// Calling this directly on `convertSettingsCard` makes it the ancestor whose
    /// `.overlay` this becomes, and -- because `.liveGlassCard()`'s clipShape was
    /// already applied INSIDE PreviewCard's own body, one layer further in -- the
    /// overlay this adds sits outside that clip, exactly the way a `.overlay` added
    /// after a `.clipShape` in any modifier chain always does.
    func dropdownPopoverOverlay(openID: Binding<String?>) -> some View {
        overlayPreferenceValue(DropdownPopoverPreferenceKey.self) { entries in
            GeometryReader { proxy in
                if let id = openID.wrappedValue, let entry = entries[id] {
                    let rect = proxy[entry.anchor]
                    // Anchored at the field's left edge, but pulled back so the menu's
                    // own width never runs past the card's right edge (or off its left,
                    // for a very narrow card) -- a field near the right side of a row
                    // (BITRATE is usually last) used to open a menu that continued
                    // straight past the window.
                    let x = min(max(rect.minX, 0), max(proxy.size.width - entry.width, 0))
                    // Opens below the field normally, but flips above it when there
                    // isn't room left in the window -- reported live with two cards
                    // both expanded: the second card's own field sits low enough that
                    // opening downward ran the menu straight under the bottom bar.
                    // proxy is scoped to just this card, so window-relative position
                    // needs its own global frame; windowHeight falls back to the
                    // card's own height (never flipping) if no window is found, which
                    // only means the old below-only behavior for that edge case.
                    let cardGlobalTop = proxy.frame(in: .global).minY
                    let cardGlobalLeft = proxy.frame(in: .global).minX
                    let windowHeight = NSApplication.shared.windows.first(where: { !($0 is NSPanel) })?.frame.height ?? (cardGlobalTop + proxy.size.height)
                    // Reserves room for the bottom bar/window chrome below the content
                    // area -- approximate on purpose (see the Entry.height doc comment).
                    // 90 undershot Download's real bar height (~130pt with the folder-
                    // path row + Download button, measured live) by enough that a
                    // second queued card's dropdown still opened downward straight
                    // under it instead of flipping up.
                    let bottomMargin: CGFloat = 145
                    let opensUpward = cardGlobalTop + rect.maxY + 6 + entry.height > windowHeight - bottomMargin
                    let y = opensUpward ? rect.minY - 6 - entry.height : rect.maxY + 6
                    ZStack(alignment: .topLeading) {
                        // Was an invisible, card-sized SwiftUI tap-catcher (a view that
                        // CLAIMS hit-testing over the whole card so it can see an
                        // "outside" tap) -- that meant the tap which dismissed the menu
                        // was also CONSUMED, never reaching whatever real control was
                        // underneath it, so acting on anything else while a menu was
                        // open took two clicks: one to dismiss, a second to actually
                        // act (reported live). An AppKit local event monitor instead
                        // OBSERVES every left-click in the window without claiming
                        // SwiftUI's own hit-testing at all, so the same click both
                        // dismisses this menu and still reaches its real target.
                        OutsideClickMonitor(
                            // Unioned with the triggering field's OWN rect (`rect`, not
                            // just the popover's), or clicking the trigger again to close
                            // it -- the normal way to dismiss any of these -- raced its own
                            // toggle action: this monitor saw that click as "outside" and
                            // closed the menu first, so the field's own `isOpen ? nil : id`
                            // then read it as already-closed and reopened it (reported
                            // live: "works if i click and hold, but then re-opens after
                            // release"). Excluding the trigger's own area means a click on
                            // it is never treated as an outside dismiss at all -- its own
                            // existing toggle handles open/close by itself, undisturbed.
                            excluding: CGRect(x: cardGlobalLeft + x, y: cardGlobalTop + y, width: entry.width, height: entry.height)
                                .union(CGRect(x: cardGlobalLeft + rect.minX, y: cardGlobalTop + rect.minY, width: rect.width, height: rect.height)),
                            windowHeight: windowHeight
                        ) {
                            withAnimation(.spring(response: 0.2)) { openID.wrappedValue = nil }
                        }
                        .frame(width: 0, height: 0)
                        entry.content()
                            .offset(x: x, y: y)
                            // `.id()` outermost (wrapping offset too) so a field switch is a
                            // real identity change -- the exiting copy keeps its OWN frozen
                            // offset instead of a shared ancestor dragging it toward the new
                            // field's position (see git history on this line for the fuller
                            // account of that earlier bug).
                            //
                            // Plain `.identity` on BOTH sides, not a scale+blur pop (tried a
                            // `.focus(blur:scale:anchor:)` insertion first, matching the glass-pop
                            // style used elsewhere in the app). ANY non-zero scale here visibly
                            // travels diagonally on a field switch, regardless of the anchor point
                            // chosen -- tried anchoring to the trigger's own position, then to the
                            // menu's own horizontal center, and neither changed the diagonal
                            // motion at all (confirmed live, watched slowed to 3s both times).
                            // Isolated the actual cause by setting scale/blur to a no-op (matching
                            // their own "identity" values) while leaving everything else the same
                            // -- the diagonal motion disappeared completely, proving it was never
                            // about the anchor's position at all, but about scaleEffect itself
                            // (combined with this content, on a field switch specifically -- a
                            // clean open from closed never showed it) being applied here at all.
                            // Reported live as preferred anyway: "this fixed it, i like this
                            // better" -- a plain instant appearance, no pop.
                            .transition(.identity)
                            .id(id)
                    }
                }
            }
        }
    }
}

/// Watches every left-click in the window and calls `action` when it lands outside
/// `excluding`, WITHOUT consuming the event -- unlike a SwiftUI view that claims hit-testing
/// over a region to catch an "outside" tap, this lets the very same click that dismisses a
/// popover also continue on to whatever real control is actually underneath it. Purely an
/// event observer, never part of the view hierarchy's own hit-testing (see `hitTest` below).
/// `excluding` and `windowHeight` are both in SwiftUI's top-left-origin, Y-down coordinate
/// space (matching dropdownPopoverOverlay's own window-relative math) -- converted here to
/// AppKit's bottom-left-origin, Y-up `NSEvent.locationInWindow`.
struct OutsideClickMonitor: NSViewRepresentable {
    let excluding: CGRect
    let windowHeight: CGFloat
    let action: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.excluding = excluding
        view.windowHeight = windowHeight
        view.action = action
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.excluding = excluding
        nsView.windowHeight = windowHeight
        nsView.action = action
    }

    final class MonitorView: NSView {
        var excluding: CGRect = .zero
        var windowHeight: CGFloat = 0
        var action: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            // A local monitor always gets first look at an event, before AppKit's
            // own normal dispatch -- true for every event type, so watching
            // mouseUp instead of mouseDown (an earlier version of this) didn't
            // change the ordering, only which half of the click it raced.
            // Calling `action` synchronously here started tearing down this
            // popover's view hierarchy WHILE the target control's own
            // mouseDown->mouseUp click-tracking was still using it, cancelling
            // the target's own click before it could complete (reported live
            // both ways: needed two clicks, and separately, a second click
            // doing nothing after switching to mouseUp). Returning the event
            // unchanged lets normal dispatch -- including the target's own
            // click -- run first and finish completely in this same turn;
            // deferring `action` to the NEXT run loop turn (main.async) makes
            // sure this popover only starts disappearing after that.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let point = CGPoint(x: event.locationInWindow.x, y: self.windowHeight - event.locationInWindow.y)
                if !self.excluding.contains(point) {
                    DispatchQueue.main.async { [weak self] in self?.action?() }
                }
                return event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// One labelled field that shows either the source's own value (dim, with a
/// trailing "source" mark) or the chosen override (accent-tinted), and opens
/// a short menu of the same options a SegmentedCapsule would show -- for a
/// track row where several controls have to sit on one line that never wraps
/// (see VIDEO CODEC / RESOLUTION in ConvertView's analyze card). The caller
/// still owns every option's `isSelected`/`action`, exactly as with
/// SegmentedCapsule; this is only a more compact way to present the same
/// list, not a different data model.
///
/// `id` and `openID` are the field's half of DropdownPopoverHost: every field
/// on one card shares the same `openID` binding, so it names itself when
/// tapped and only draws its own menu content when it's the one named.
struct DropdownField: View {
    let id: String
    let caption: String
    let options: [SegmentOption]
    @Binding var openID: String?
    /// True when this field doesn't apply at all right now (e.g. RE-ENCODE for
    /// a container that can hold the source codec natively, no choice to make)
    /// -- shown greyed out and unclickable instead of removing the field, so
    /// the row's layout stays put rather than RESOLUTION jumping to fill the
    /// gap every time the output format changes.
    var disabled: Bool = false

    private var isOpen: Bool { openID == id }
    private var selected: SegmentOption? { options.first(where: \.isSelected) }
    /// "Same as Source" is the one option marked isSourceDefault -- everything else (including a
    /// resolution option, which now carries its own explanatory subtext too) counts as changed.
    /// Never true while disabled -- there's no real selection to call "changed."
    private var isChanged: Bool { !disabled && selected != nil && !(selected?.isSourceDefault ?? false) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldCaption(icon: nil, text: caption).reportsFacadeFieldShape(id: "\(id)_caption", kind: .text)
            Button {
                // One uniform animated toggle for open, close, AND switching directly
                // to a different field -- two earlier, more surgical attempts at the
                // switch case specifically (an unanimated plain assignment, then a
                // Transaction with disablesAnimations) both still reportedly ghosted
                // on a real mouse click. Root cause turned out to live in
                // dropdownPopoverOverlay's own `.transition()` being SYMMETRIC (see
                // its own doc comment) -- an interrupted removal animation gets stuck
                // mid-blur regardless of how carefully the state CHANGE itself is
                // wrapped. Now that removal there is `.identity` (instant, nothing to
                // interrupt), this call no longer needs special-casing the switch.
                guard !disabled else { return }
                withAnimation(.spring(response: 0.25)) { openID = isOpen ? nil : id }
            } label: {
                // .firstTextBaseline, not the default .center: the label (12pt) and
                // subtext (9pt) are different sizes, and centering by bounding box
                // instead of by baseline reads as the subtext floating above the
                // text line instead of sitting on it (reported live).
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(selected?.label ?? "—")
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    if let subtext = selected?.subtext {
                        Text(subtext)
                            .font(.appMono(size: 9))
                            .foregroundColor(.white.opacity(DesignTokens.Text.disabled))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.appMono(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(disabled ? DesignTokens.Text.disabled : DesignTokens.Text.tertiary))
                }
                .font(.appMono(size: 12, weight: .medium))
                .foregroundColor(disabled ? .white.opacity(DesignTokens.Text.disabled) : (isChanged ? DesignTokens.Accent.primaryLight : .white.opacity(DesignTokens.Text.primary)))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous)
                        .fill(isChanged ? DesignTokens.Accent.primary.opacity(0.14) : Color.white.opacity(DesignTokens.Field.fillRest))
                        .opacity(disabled ? 0.5 : 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous)
                        .stroke(isChanged ? DesignTokens.Accent.primary.opacity(0.6) : Color.white.opacity(DesignTokens.Field.borderRest),
                                lineWidth: DesignTokens.Field.borderWidth)
                        .opacity(disabled ? 0.5 : 1)
                )
            }
            .buttonStyle(.plain)
            .reportsFacadeFieldShape(id: id, kind: .field)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .anchorPreference(key: DropdownPopoverPreferenceKey.self, value: .bounds) { anchor in
            guard isOpen else { return [:] }
            return [id: .init(anchor: anchor, width: Self.menuWidth, height: menuHeight, content: { AnyView(menu) })]
        }
    }

    /// Fixed, not a minimum: the host needs to know the menu's real width up
    /// front to keep it on screen (see dropdownPopoverOverlay), and every
    /// option list here is short codec/format names plus at most one row of
    /// subtext -- comfortably narrower than this even for "Same as Source"
    /// beside a resolution like "1920x1080".
    private static let menuWidth: CGFloat = 230
    /// Estimated, not measured -- one DropdownMenuRow is ~30pt (12pt text, 7pt vertical
    /// padding each side, 1pt row spacing), plus the menu's own 4pt padding on each side.
    private var menuHeight: CGFloat { CGFloat(options.count) * 30 + 8 }

    private var menu: some View {
        DropdownMenuChrome {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                    DropdownMenuRow(option: option, isFirst: index == 0, isLast: index == options.count - 1) {
                        option.action()
                        withAnimation(.spring(response: 0.2)) { openID = nil }
                    }
                }
            }
            .padding(4)
        }
        .frame(width: Self.menuWidth)
    }
}

/// Same shell as DropdownField, but its menu is a SteppedSlider instead of a
/// list -- for VIDEO BITRATE / AUDIO BITRATE, where "a handful of discrete
/// options" is better shown as a slider than a scrolling list of numbers.
/// Stays open across a drag (unlike DropdownField, which closes the instant
/// something is picked): a slider is something you settle into, not a single
/// tap.
struct DropdownBitrateField: View {
    let id: String
    let caption: String
    let steps: [SliderStep]
    let selected: Int
    let isChanged: Bool
    @Binding var openID: String?
    let onSelect: (Int) -> Void

    private var isOpen: Bool { openID == id }
    private var chosen: SliderStep { steps[min(max(selected, 0), steps.count - 1)] }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldCaption(icon: nil, text: caption).reportsFacadeFieldShape(id: "\(id)_caption", kind: .text)
            Button {
                // One uniform animated toggle -- see DropdownField's identical button
                // for why the switch case no longer needs special-casing.
                withAnimation(.spring(response: 0.25)) { openID = isOpen ? nil : id }
            } label: {
                // .firstTextBaseline -- see DropdownField's identical fix.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(chosen.label)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    if let subtext = chosen.subtext {
                        Text(subtext)
                            .font(.appMono(size: 9))
                            .foregroundColor(.white.opacity(DesignTokens.Text.disabled))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.appMono(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                }
                .font(.appMono(size: 12, weight: .medium))
                .foregroundColor(isChanged ? DesignTokens.Accent.primaryLight : .white.opacity(DesignTokens.Text.primary))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous)
                        .fill(isChanged ? DesignTokens.Accent.primary.opacity(0.14) : Color.white.opacity(DesignTokens.Field.fillRest))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous)
                        .stroke(isChanged ? DesignTokens.Accent.primary.opacity(0.6) : Color.white.opacity(DesignTokens.Field.borderRest),
                                lineWidth: DesignTokens.Field.borderWidth)
                )
            }
            .buttonStyle(.plain)
            .reportsFacadeFieldShape(id: id, kind: .field)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .anchorPreference(key: DropdownPopoverPreferenceKey.self, value: .bounds) { anchor in
            guard isOpen else { return [:] }
            return [id: .init(anchor: anchor, width: Self.menuWidth, height: Self.menuHeight, content: { AnyView(menu) })]
        }
    }

    /// Estimated, not measured -- fixed content (one slider + one line of caption text)
    /// regardless of how many steps it has, unlike DropdownField's per-row list.
    private static let menuHeight: CGFloat = 120

    // SteppedSlider divides this width into one column per step (up to 6 for
    // audio: Auto + 5 real bitrates) and centers each label under its own
    // dot. 330 was carried over from an early guess; at up to 6 columns that
    // gives each label only ~50px, and the LAST one (e.g. "12 Mbps"/"320
    // kbps") sits with its label frame ending exactly at the content edge --
    // reported live as looking cramped/uneven against "Auto"'s wide space.
    // The slider was originally sized for a full-width row (600pt+), where
    // this never showed. 380 gives 6 columns ~60px each, enough room for a
    // two-line "320\nkbps" label to breathe on both sides.
    private static let menuWidth: CGFloat = 380

    private var menu: some View {
        DropdownMenuChrome {
            VStack(alignment: .leading, spacing: 10) {
                SteppedSlider(steps: steps, selected: selected, onSelect: onSelect)
                Text("Auto keeps the source's own quality target.")
                    .font(.appMono(size: 9.5))
                    .foregroundColor(.white.opacity(DesignTokens.Text.disabled))
            }
            .padding(14)
        }
        .frame(width: Self.menuWidth)
    }
}

/// A track's row of fields ("VIDEO" / "AUDIO" beside CODEC, RESOLUTION,
/// BITRATE) -- a plain HStack, so it never wraps: SwiftUI's HStack doesn't
/// reflow to a second line the way a CSS flex row can, it just negotiates
/// each field's width, which is exactly the point (see the analyze-card
/// redesign: every field keeps to one row at every real window width).
struct FieldsTrackRow<Content: View>: View {
    let icon: String
    let label: String
    /// Stable id for this row's own icon+label caption's facade shape -- distinct from
    /// whatever field(s) `content()` reports on its own, and unique among this card's other
    /// captions (see reportsFacadeFieldShape).
    let captionID: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            FieldCaption(icon: icon, text: label)
                .frame(width: 60, alignment: .leading)
                .padding(.bottom, 7)
                .reportsFacadeFieldShape(id: captionID, kind: .text)
            content()
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
            // boxSize makes the visible glass chrome exactly DropGrid.controlHeight,
            // matching the folder capsule beside it -- the outer .frame below only
            // reserves that much LAYOUT space, it doesn't touch the glass box HoverIconButton
            // draws internally, which is why the box needs its own explicit override
            // (reported live: "same height as the directory bar"). `size` stays 13 so the
            // glyph and hover caption keep their original size instead of scaling up too.
            HoverIconButton(icon: "folder", size: 13, boxSize: DropGrid.controlHeight, help: "Choose folder", expandable: true) {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.canCreateDirectories = true
                panel.allowsMultipleSelection = false
                panel.prompt = "Select"
                panel.directoryURL = URL(fileURLWithPath: path)
                // .begin (async), not .runModal() (blocking) -- a modal session entered
                // synchronously from inside a SwiftUI button/gesture callback crashed here
                // (EXC_BREAKPOINT in ViewBridge's NSRendezvousWindowRemoteViewDelegate, surfaced
                // using the panel's own "New Folder" control while browsing). The panel's
                // completion handler keeps it alive for the duration, same as every other use.
                panel.begin { response in
                    if response == .OK, let url = panel.url { onChoose(url.path) }
                }
            }
            HoverIconButton(icon: "arrow.up.forward.app", size: 13, boxSize: DropGrid.controlHeight, help: "Reveal in Finder", expandable: true) {
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
