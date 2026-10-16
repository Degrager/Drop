import SwiftUI
import AppKit
import UserNotifications
import UniformTypeIdentifiers
import QuickLookThumbnailing
import CryptoKit
import Sparkle

/// ffprobe isn't bundled with Drop -- it's a companion tool from whichever
/// Homebrew ffmpeg install the user has, if any (Drop bundles ffmpeg itself,
/// but not ffprobe). Checks both common install locations (Apple Silicon
/// and Intel Homebrew prefixes). Shared by History's legacy-entry migration
/// and Convert's media-info probing so the two search paths can't drift.
func locateFFprobe() -> String? {
    ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"].first { FileManager.default.fileExists(atPath: $0) }
}

// MARK: - Content View

struct ContentView: View {
    @StateObject private var manager  = DownloadManager()
    // Observed directly (not just reached via manager.dropUpdater.userDriver
    // inline) so this view's own body -- specifically the Escape-to-clear-
    // URL-field button below -- actually re-renders when the driver's
    // @Published stage changes. A nested ObservableObject's @Published
    // changes don't propagate through manager's own objectWillChange (the
    // same gap already fixed once for ToolsDropdownContent), so without
    // this the .disabled(...) binding on that button would only update
    // whenever something else happened to redraw ContentView.
    @ObservedObject private var dropDriver: DropCustomUserDriver
    @StateObject private var config   = Config()
    @State private var urlText        = ""
    @State private var isDragging     = false

    @State private var activeTab: AppTab = .download
    // What's on the clipboard right now, shown in the field in place of typing/
    // pasting into it (see urlCard) -- same describe(_:) the menu bar panel already
    // uses for its own clipboard well, so "no link copied" / "N links" read
    // identically in both places. Refreshed on appear and whenever Drop becomes the
    // active app (the moment a link copied elsewhere would first be visible here).
    @State private var clipboardPreview: MenuBarClipboard = .empty
    /// True for a few seconds right after a NEW link appears on the clipboard --
    /// WaitingPulseGlow's own trigger, see refreshClipboardPreview. Deliberately
    /// bounded: the old focus-based trigger this replaced could only ever run for
    /// as long as a cursor sat in an empty field (a user attention span), but a
    /// link can sit on the clipboard for hours -- an indefinite Core Animation
    /// layer for that whole stretch is exactly the "repeatForever" pattern this
    /// codebase already treats as a real cost (see idle-animation-cost), and one
    /// running continuously turned out to compete with the sidebar's OWN
    /// animation for compositor time during a collapse/expand, reported live as
    /// "resizing/sidebar animations feel laggy."
    @State private var clipboardPulseActive = false
    @State private var clipboardPulseGeneration = 0
    @State private var isAnalyzing       = false
    @State private var hasInvalidURLs    = false
    // True right after a Paste & Analyze attempt whose URL(s) are already
    // present in linkPreviews -- surfaced as an inline "Already Analyzed"
    // state on the pill instead of silently queuing a second duplicate
    // card. Reset (like analyzeResult) whenever the field's text changes,
    // so it only reflects the most recent paste attempt.
    @State private var duplicateURLDetected = false
    // Keyed by the pending placeholder card's own unique id, NOT the url string.
    // Pasting/analyzing the same link multiple times at once creates multiple
    // pending cards that all share one url -- keying by url made every one of
    // those instances collide on the same dictionary slot, so a later duplicate
    // would silently steal over an earlier one's process reference, cancelling
    // one card would look up and kill/clear ALL cards sharing that url, and
    // finished results would land on whichever same-url pending card happened
    // to still be first in the array rather than the one that actually started
    // that particular process.
    @State private var analyzeProcesses: [UUID: Process] = [:]  // placeholder id -> running analyze process
    // Cards cancelled while still queued behind the analyze concurrency gate
    // (see maxConcurrentAnalyze in analyzeURL) -- at that point there's no
    // Process yet to terminate, so analyzeProcesses alone can't represent
    // "cancel this one." Checked the instant a queued slot opens up for this
    // id so a cancelled-while-waiting card never spawns yt-dlp at all.
    @State private var cancelledAnalyzeIDs: Set<UUID> = []
    // Measured once here and shared with every tab (see WindowLayout and the
    // .environment(...) values injected at the end of body). Previously each
    // tab measured -- or worse, guessed via containerRelativeFrame, which
    // resolves against whatever container happens to be nearest -- its own
    // "60% of something", so Download, Convert and History/Log/Dev never
    // agreed on a width.
    // Raw, continuously-updated geometry -- cheap to store, but every
    // breakpoint BELOW deliberately reads the "settled" snapshot instead (see
    // those two @State vars) so a live window-edge drag doesn't re-decide
    // "should the bottom bar stack / is the sidebar forced compact" on every
    // single one of the dozens of frames a drag produces. Kept around because
    // the settled snapshot needs a live value to catch up to once the drag ends.
    // NOTHING in `body` may read windowSize or mainAreaWidth: they're written on
    // every resize tick, so a read there re-runs ContentView.body -- and every
    // sidebar tab, glass control and the bottom bar under it -- on every tick
    // of a drag (measured: hundreds of re-runs per drag, about a third of the
    // main thread's time). Views that need a decision from the live width read
    // a Bool that only changes when the width crosses a threshold
    // (isNarrowWindow).
    @State private var windowSize: CGSize = .zero
    @State private var mainAreaWidth: CGFloat = 0
    // What the height breakpoints below read. Equal to windowSize except while
    // NSApp.keyWindow?.inLiveResize is true, during which it is pinned to its
    // pre-drag value and only catches up once (via the .dropLiveResizeEnded
    // notification, posted from DropAppDelegate.windowDidEndLiveResize) when
    // the drag ends -- height breakpoints recomputed on every resize tick were
    // measurably one of the most expensive things the app did.
    @State private var settledWindowSize: CGSize = .zero
    /// The content column's width reduced to which side of each breakpoint it
    /// is on (WindowLayout.columnClass) -- the only column-width value views
    /// read. It follows the space between the sidebar and the window's right
    /// edge live, but only CHANGES at a breakpoint, so publishing it costs
    /// nothing on the resize ticks in between. The column's real width is
    /// worked out live inside ContentColumnLayout, so cards track the window
    /// frame by frame; only decisions like "stack these chips" wait for this.
    @State private var columnClass: CGFloat = 0
    /// The user's own collapse choice (the toggle in the sidebar header).
    @AppStorage("sidebarCollapsed") private var sidebarCollapsedByUser = false
    /// Which toggle animation to play -- switched from the View menu (see
    /// DropApp.commands) so the two can be compared side by side.
    @AppStorage(SidebarAnimationStyle.storageKey) private var sidebarAnimationStyleRaw = SidebarAnimationStyle.resize.rawValue
    private var sidebarAnimationStyle: SidebarAnimationStyle { SidebarAnimationStyle(rawValue: sidebarAnimationStyleRaw) ?? .resize }
    // The sidebar card's own width. A deliberate toggle tween it (rows blur
    // out, the card visibly shrinks/grows, rows pop back in one by one -- see
    // onChange(of: isCompactSidebar) below); a window-driven change snaps it.
    // The page beside it is inset by this value's FINAL number the instant it
    // changes (see body), so only the card animates. Seeded from the
    // persisted preference so a collapsed launch doesn't animate on first
    // appearance.
    @State private var sidebarWidth: CGFloat =
        UserDefaults.standard.bool(forKey: "sidebarCollapsed") ? WindowLayout.compactSidebarWidth : WindowLayout.sidebarWidth
    /// The sidebar width the PAGE is currently laid out for. It follows
    /// `sidebarWidth`, but not at the same moment: opening, the page moves at
    /// once; collapsing, it waits until the sidebar has finished shrinking.
    @State private var pageInset: CGFloat =
        UserDefaults.standard.bool(forKey: "sidebarCollapsed") ? WindowLayout.compactSidebarWidth : WindowLayout.sidebarWidth
    /// True for the whole toggle sequence (width tween AND the reveal after
    /// it). While it is, the live-resize rule that switches animations off
    /// stands aside, so the sidebar can animate during a window drag.
    @State private var sidebarSequencePlaying = false
    // What every ROW actually renders as (icon+label vs icon-only) -- this,
    // not isCompactSidebar directly, is what's published to the
    // \.isCompactSidebar environment SidebarTabItem/ToolsDropdownContent/
    // CheckForUpdatesButton read. It only changes once every row has left
    // (mid-tween), so nothing visibly reflows into the new mode early.
    // Without this split, those views saw the NEW mode the instant the
    // toggle was tapped -- their own hard-cut content swap (e.g.
    // SidebarTabItem's `if !compact { Text(label) }`) fired immediately,
    // instead of staying full-content until the rows were gone.
    @State private var sidebarDisplayCompact: Bool =
        UserDefaults.standard.bool(forKey: "sidebarCollapsed")
    /// True while the sidebar's rows (header, tab pills, tools block) are
    /// hidden mid-collapse/expand -- see onChange(of: isCompactSidebar) and
    /// AnyTransition.dominoPop.
    @State private var sidebarRowsHidden = false
    /// Bumped on every collapse/expand toggle so a stale, still-in-flight
    /// asyncAfter from a superseded toggle (the user tapped twice quickly)
    /// can recognize it's no longer current and no-op instead of clobbering
    /// a newer sequence's width/visibility.
    @State private var sidebarToggleGeneration = 0
    // toggle(1) + label(1) + 5 tab pills + 4 tool rows (yt-dlp/ffmpeg/Drop/
    // Check for Updates, see ToolsStatusPill's baseIndex: 7) = indices 0-10,
    // 11 total. Kept at the worst-case count even when Dev is absent -- an
    // unused index just means the reveal's ambient duration is a touch more
    // generous than strictly needed, never too short.
    private static let sidebarRowCount = 11
    /// Pop-in style: how long the card takes to shrink/grow. The rows blur out
    /// together over the first dominoExitDuration of it; the reveal starts
    /// once it lands.
    private static let sidebarWidthDuration: Double = 0.22
    /// Resize style: how long the card takes to shrink/grow, with its tabs and
    /// icons resizing along with it instead of leaving and popping back.
    /// Was 0.3 -- a window-drag crossing the 1000pt breakpoint force-collapses/
    /// expands the sidebar WHILE every drag frame is also re-laying-out the
    /// page, and animating that alongside a live AppKit resize stalls frames
    /// (measured: ~6 per crossing at 0.3s). Halving the duration roughly halves
    /// the stall count (measured: ~3 per crossing at 0.15s) -- reported live as
    /// still stuttering at the old duration even with the page/card side of a
    /// resize now smooth (see the card-facade and pulse-animation fixes this
    /// same session). A manual sidebar-toggle click is unaffected either way,
    /// it was never the part that stuttered.
    private static let sidebarResizeDuration: Double = 0.15
    // How long the reveal's last row takes to read as fully settled: its own
    // delay plus a little slack for its spring's overshoot to visibly damp
    // out (a spring doesn't stop dead at `response`, it keeps interpolating
    // past it). Must stay ≥ dominoPop's insertion animation (response +
    // delay) or the last rows get cut off before their pop plays -- see the
    // ambient-wrapper comment below.
    private static var sidebarEnterTotal: Double { AnyTransition.dominoStagger * Double(sidebarRowCount - 1) + 0.2 }
    /// A free user choice, not window-width-driven: the sidebar used to also
    /// auto-collapse below a breakpoint, animating every time a drag crossed
    /// it -- a real, repeatedly-reported source of resize lag no matter how
    /// that animation was tuned (shorter duration, snap-during-drag-only).
    /// Removed per the user's own call: the window instead enforces a strict,
    /// sidebar-state-dependent minimum width (see WindowLayout.minimumSize
    /// Collapsed/Expanded, DropAppDelegate.sidebarCollapsedDidChange) so the
    /// two states never fight over the same window.
    private var isCompactSidebar: Bool { sidebarCollapsedByUser }
    private var isCompactHeight: Bool { settledWindowSize.height > 0 && settledWindowSize.height < WindowLayout.compactHeightBreakpoint }
    private var isTinyHeight: Bool { settledWindowSize.height > 0 && settledWindowSize.height < WindowLayout.tinyHeightBreakpoint }
    @State private var convertStagingJobs: [ConvertJob] = []
    @State private var convertQueue: [ConvertJob] = []
    /// Lives here (not as local @State in ConvertView) because activeTab
    /// switches unmount/remount ConvertView -- local @State would reset to
    /// nil on every trip back to the tab, making the Analyze panel look
    /// like it "lost" its staged files even though stagingJobs itself
    /// (also lifted here for the same reason) still had them.
    @State private var convertSelectedStagingID: ConvertJob.ID? = nil

    /// Select mode — mirrors Convert's Batch Apply toggle. Off by default;
    /// checkboxes on link cards only show while this is true. Outside Select
    /// mode every queued item counts as included (checkbox hidden = implicitly
    /// selected), same convention as Convert.
    @State private var isBatchMode = false

    /// Includes pending (still-analyzing) cards -- shows the Select/Clear
    /// toolbar as soon as a link starts analyzing, instead of waiting for
    /// the first one to finish.
    private var hasAnyLinkItems: Bool { !linkPreviews.isEmpty }
    /// Outside Select mode every queued item is treated as selected (checkboxes
    /// are hidden, so nothing is excluded). Inside Select mode, only what's
    /// actually checked counts. Either way, a card that already failed to
    /// analyze (shown on screen as its own error banner) is never a real
    /// download target -- excluding it here fixes it everywhere this is used:
    /// the "Download N Items" count/button label, whether the primary action
    /// shows at all, the total-size estimate, and (most importantly) download()
    /// itself, which used to happily queue a doomed-to-fail download for a
    /// link the user already saw fail to analyze.
    private var selectedPreviews: [LinkPreview] {
        let base = isBatchMode ? linkPreviews.filter { $0.isSelected } : linkPreviews
        return base.filter { $0.analyzeError == nil }
    }
    private var allEligibleLinksSelected: Bool {
        let eligible = linkPreviews.filter { !$0.isPending && $0.downloadID == nil && $0.analyzeError == nil }
        guard !eligible.isEmpty else { return false }
        return eligible.allSatisfy { $0.isSelected }
    }
    private func toggleSelectAllLinks() {
        let shouldSelect = !allEligibleLinksSelected
        for i in linkPreviews.indices where !linkPreviews[i].isPending && linkPreviews[i].downloadID == nil && linkPreviews[i].analyzeError == nil {
            linkPreviews[i].isSelected = shouldSelect
        }
    }

    /// Cards that can actually be collapsed/expanded -- queued, not pending
    /// (downloading/done/failed cards don't have a collapse toggle at all).
    /// Shared by allLinksCollapsed/hasExpandableLinks so the two can't drift
    /// out of sync on what counts as "collapsible."
    private var collapsibleLinks: [LinkPreview] {
        linkPreviews.filter { !$0.isPending && $0.downloadID == nil && $0.analyzeError == nil }
    }

    /// True once every collapsible card is collapsed — flips the header
    /// button to "Expand All". Empty list counts as not-collapsed.
    private var allLinksCollapsed: Bool {
        let queued = collapsibleLinks
        return !queued.isEmpty && queued.allSatisfy { !$0.isExpanded }
    }

    /// True when at least one card can actually be collapsed/expanded. Select
    /// mode force-collapses + locks every card's toggle.
    private var hasExpandableLinks: Bool {
        !isBatchMode && !collapsibleLinks.isEmpty
    }

    /// While anything is still analyzing, collapse/expand has nothing
    /// consistent to act on yet (pending cards don't have a collapse
    /// state), so the button is hidden entirely rather than just disabled
    /// -- it reappears once every card in the queue has resolved.
    private var anyLinksStillAnalyzing: Bool {
        linkPreviews.contains { $0.isPending }
    }

    /// Collapses every card if any are still expanded; expands every card
    /// once they're all already collapsed.
    private func toggleCollapseAllLinks() {
        let shouldCollapse = !allLinksCollapsed
        for i in linkPreviews.indices where !linkPreviews[i].isPending && linkPreviews[i].downloadID == nil && linkPreviews[i].analyzeError == nil {
            linkPreviews[i].isExpanded = !shouldCollapse
        }
    }

    var readyToDownload: Bool { manager.toolsReady }

    init() {
        let manager = DownloadManager()
        _manager = StateObject(wrappedValue: manager)
        _dropDriver = ObservedObject(wrappedValue: manager.dropUpdater.userDriver)
    }

    var body: some View {
        ZStack {
            // Real blur-of-whatever's-behind-the-window, same material cards
            // and the sidebar use -- WindowBackdrop's gradient now paints
            // semi-transparent colors on top of this instead of a fully
            // opaque fill, so the base background gets the same genuine
            // translucency every other glass surface in the app already has.
            VisualEffectBlur(material: DesignTokens.Glass.material, blendingMode: .behindWindow)
                .ignoresSafeArea()
            // Window-wide base: the concept's soft radial glow (see
            // WindowBackdrop) -- a touch lighter than the flat black frosting it
            // replaces. The tiny dither tile breaks up 8-bit banding across
            // such a dark, slow ramp; the cards above still carry their own
            // black-frosted glass.
            WindowBackdrop()
                .ignoresSafeArea()
            WindowDither()
                .ignoresSafeArea()

            // Main layout — sidebar on the left, active tab's content on the
            // right. Sidebar is now a floating GlassCard with its own
            // margin (leading/vertical padding applied inside `sidebar`
            // itself), so no extra gap is needed here.
            //
            // The page is NOT pushed by the sidebar (an HStack made every card
            // re-lay-out on every frame of the width tween: about 40ms a frame,
            // ~20fps on a 120Hz screen). It is inset by the sidebar's FINAL
            // width, set instantly (see the `.animation(nil...)` below), so it is
            // laid out once per toggle; only the sidebar card itself animates,
            // sliding over the page or away from it.
            VStack(spacing: 0) {
                // Active tab content -- structurally unrelated pages, so
                // they swap instantly: no fade, blur or scale between them
                // (see the transaction override on the Group below).
                ZStack(alignment: .top) {
                Group {
                    if activeTab == .download {
                        mainPanel
                            .transition(.identity)
                    } else if activeTab == .history {
                        // Real content is historyOverlay below, kept permanently
                        // mounted instead of created fresh here -- see its comment
                        // for why.
                        Color.clear
                    } else if activeTab == .convert {
                        // Real content is convertOverlay below, kept permanently
                        // mounted instead of created fresh here -- see its comment
                        // for why.
                        Color.clear
                    } else if activeTab == .devRelease {
                        // Real content is devReleaseOverlay below, kept
                        // permanently mounted instead of created fresh
                        // here -- see its comment for why.
                        Color.clear
                    } else {
                        // Log is now a full page like Download/History/Convert
                        // instead of a floating side panel -- same bare-VStack-
                        // against-the-window-glass structure and 60%-width
                        // convention as History, not a card floating on a page.
                        LogView(logs: manager.globalLogs)
                            .transition(.identity)
                    }
                }
                // A tab click runs inside withAnimation (the sidebar's
                // highlight uses it), and an animated transaction would
                // cross-fade the outgoing and incoming pages -- and let the
                // cards' own removal transitions play as a ghost of the old
                // page; `.transition(.identity)` on each page root is what
                // takes the whole page out in one piece. Scoped to
                // `activeTab` so ONLY the page swap is made instant; card
                // spawns, thumbnail loads and the rest of the subtree keep
                // their own animations.
                .transaction(value: activeTab) { $0.animation = nil }

                // History, like Dev below, is kept permanently mounted instead of
                // created fresh on every switch (the if/else-if pattern above).
                // Mounting it fresh tore the whole row list down and rebuilt it
                // from scratch each time, which meant every visible row replayed
                // its own .glassBar insertion transition -- a LIVE BACKDROP BLUR
                // recomputed every frame for 0.24s (see the GPU-cost comment on
                // AnyTransition above) -- on EVERY switch to this tab, not just
                // when a row was actually newly added. With a non-trivial history
                // list, several rows' blurs animating in at once is real
                // compositor work, and read as "a bit of a delay" switching here
                // specifically (Download/Convert are usually near-empty, so they
                // had nothing comparable to replay). Keeping it mounted means
                // each row's insertion transition plays once, when the row is
                // actually added to history, never again just from tab-switching.
                ActiveOnlyLayout(isActive: activeTab == .history) {
                    HistoryView(history: manager.history, activeTab: $activeTab, urlText: $urlText, hasInvalidURLs: $hasInvalidURLs, linkPreviews: $linkPreviews, config: config, onAnalyze: { urls, ids in analyzeURL(urls: urls, ids: ids) }, onReconvert: { fileURL in
                        // Treat Reconvert exactly like freshly dropping/importing the original
                        // input file into the Convert tab — no stored snapshot reused, the file
                        // is re-probed from scratch just like a first-time add.
                        // Selecting the job matters: ConvertView's Analyze panel only
                        // renders the SELECTED staged file, so appending without
                        // selecting left Reconvert landing on an empty Convert tab.
                        if let existing = convertStagingJobs.first(where: { $0.inputURL == fileURL }) {
                            convertSelectedStagingID = existing.id
                            activeTab = .convert
                            return
                        }
                        guard !convertQueue.contains(where: { $0.inputURL == fileURL }) else {
                            activeTab = .convert
                            return
                        }
                        let job = ConvertJob(inputURL: fileURL)
                        withAnimation(.spring(response: 0.35)) {
                            convertStagingJobs.append(job)
                            convertSelectedStagingID = job.id
                        }
                        activeTab = .convert
                    })
                    .transaction(value: activeTab) { $0.animation = nil }
                }
                    .opacity(activeTab == .history ? 1 : 0)
                    .allowsHitTesting(activeTab == .history)
                    .transaction(value: activeTab) { $0.animation = nil }

                // Same reasoning as History above: Convert used to be mounted fresh on
                // every switch (the if/else-if pattern), which tore its queue drawer down
                // and rebuilt it from scratch each time -- every visible item replayed its
                // own insertion transition, and TabBottomBar's own .glassBar(anchor: .bottom)
                // mount transition played too, reading as a visible "pop in" (reported live)
                // that Download's equivalent bar doesn't show. ActiveOnlyLayout keeps it
                // permanently mounted instead, so both only ever animate when something
                // actually changes, never just from switching tabs back to them.
                ActiveOnlyLayout(isActive: activeTab == .convert) {
                    ConvertView(ffmpegPath: manager.ffmpegPath, toolsReady: readyToDownload, history: manager.history, stagingJobs: $convertStagingJobs, queue: $convertQueue, selectedStagingID: $convertSelectedStagingID, config: config, manager: manager)
                        .transaction(value: activeTab) { $0.animation = nil }
                }
                    .opacity(activeTab == .convert ? 1 : 0)
                    .allowsHitTesting(activeTab == .convert)
                    .transaction(value: activeTab) { $0.animation = nil }

                // Dev tab, unlike the others above, keeps essentially
                // all of its own state locally (pipeline, typed-in
                // version/changelog, fetched releases/audit trail) --
                // nothing hoisted up to ContentView the way History's
                // and Convert's real data lives in `manager`. Mounting
                // it fresh on every tab switch (the pattern above) tore
                // all of that down and rebuilt it from scratch each
                // time, which read as "the Dev page resets when I leave
                // it." Keeping it permanently in the tree and only
                // toggling opacity/hit-testing preserves its state for
                // as long as the app runs, matching every other tab's
                // actual persistence even though the mechanism here is
                // different. It switches instantly like the other pages.
                #if DEV_BUILD
                if DevKeychain.isDevMachine {
                    // ActiveOnlyLayout keeps it mounted (state survives) but
                    // lays it out only while it's the active tab -- hidden,
                    // it used to be re-laid-out on every window-resize tick
                    // for nothing. The transaction override stops the layout
                    // change at activation from animating the page's size.
                    ActiveOnlyLayout(isActive: activeTab == .devRelease) {
                        DevReleaseView(dropDriver: dropDriver, manager: manager, isActive: activeTab == .devRelease)
                            .contentColumn()
                            .pinnedToSidebar()
                            .transaction(value: activeTab) { $0.animation = nil }
                    }
                        .opacity(activeTab == .devRelease ? 1 : 0)
                        .allowsHitTesting(activeTab == .devRelease)
                        .transaction(value: activeTab) { $0.animation = nil }
                }
                #endif
                }

            }
            .frame(maxWidth: .infinity)
            // The main column's own width (everything right of the
            // sidebar). Every tab's content column is derived from the space
            // it offers (ContentColumnLayout); this only feeds the breakpoint
            // class views compare against.
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear {
                            mainAreaWidth = geo.size.width
                            LiveResizeState.shared.pageAreaWidth = geo.size.width
                            columnClass = WindowLayout.columnClass(mainWidth: geo.size.width - (pageInset - WindowLayout.compactSidebarWidth))
                        }
                        .onChange(of: geo.size.width) { _, newWidth in
                            mainAreaWidth = newWidth
                            LiveResizeState.shared.pageAreaWidth = newWidth
                            // The page's real width: this frame minus the room
                            // the (pinned) sidebar takes.
                            let cls = WindowLayout.columnClass(mainWidth: newWidth - (pageInset - WindowLayout.compactSidebarWidth))
                            if cls != columnClass {
                                if sidebarSequencePlaying {
                                    // The page jumps to its final width when a
                                    // toggle starts, so its breakpoints flip
                                    // then too -- instantly, not as a 0.3s
                                    // animated restack of every card.
                                    var t = Transaction()
                                    t.disablesAnimations = true
                                    withTransaction(t) { columnClass = cls }
                                } else {
                                    columnClass = cls
                                }
                            }
                        }
                }
            )
            // The page's frame is as wide as the window allows with the sidebar
            // COLLAPSED (its footprint is the rail's width plus the 12pt leading
            // and 8pt trailing margins `sidebar` adds around it); every piece
            // then insets itself for the sidebar -- following its edge live
            // (`followsSidebar()`) or pinned (`pinnedToSidebar()`).
            .padding(.leading, WindowLayout.compactSidebarWidth + 20)
            // Fills the window, and centered as it was when a row beside the
            // sidebar: the overlay below takes its size from this.
            .frame(maxHeight: .infinity)
            // An OVERLAY, not a sibling: an overlay never affects its base's
            // layout, so the sidebar's changing size can't make the container
            // re-ask the whole page (every card) for its size on every frame.
            // Draws above the page, so the card and its shadow cover it.
            .overlay(alignment: .topLeading) { sidebar }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        windowSize = geo.size
                        settledWindowSize = geo.size
                    }
                    .onChange(of: geo.size) { _, newSize in
                        windowSize = newSize
                        if NSApp.keyWindow?.inLiveResize != true { settledWindowSize = newSize }
                    }
            }
        )
        .environment(\.contentColumnWidth, columnClass)
        .environment(\.isCompactSidebar, sidebarDisplayCompact)
        .environment(\.sidebarLiveInset, sidebarWidth - WindowLayout.compactSidebarWidth)
        .environment(\.cardContentInset, pageInset - WindowLayout.compactSidebarWidth)
        .onChange(of: isCompactSidebar) { _, compact in
            let target = compact ? WindowLayout.compactSidebarWidth : WindowLayout.sidebarWidth
            // Toggle sequence, per request: every row blurs/shrinks out AT
            // ONCE while the card visibly shrinks/grows; once the width lands
            // the new row set pops IN one by one, top-to-bottom. See
            // AnyTransition.dominoPop. The page beside the card is laid out
            // once at its final width (see body), so its breakpoints flip
            // once, at the start, rather than on every intermediate width.
            sidebarToggleGeneration += 1
            let generation = sidebarToggleGeneration
            // sidebarSequencePlaying exempts this from the live-resize rule below
            // that switches animations off, in case the user drags the window
            // (an unrelated resize) while this sequence is still playing.
            sidebarSequencePlaying = true
            // The cards stand down for the toggle: a facade takes their place while the
            // sidebar moves, and they are laid out once, at their final width, when it
            // has landed (see FrozenDuringResize).
            LiveResizeState.shared.setSidebarMoving(true)
            let landed = (sidebarAnimationStyle == .resize ? Self.sidebarResizeDuration : Self.sidebarWidthDuration) + 0.06
            DispatchQueue.main.asyncAfter(deadline: .now() + landed) {
                if sidebarToggleGeneration == generation { LiveResizeState.shared.setSidebarMoving(false) }
            }
            // The page's CONTENT (its cards) takes its new size in ONE step,
            // never live: opening, at the start; collapsing, once the sidebar has
            // finished shrinking. Everything else follows the sidebar's edge
            // frame by frame on its own (see `followsSidebar()` and
            // LiveGlassCard, which read `sidebarWidth`). The page's breakpoint
            // class is worked out at the same moment as the content's new size,
            // from the width the content is about to have, so the heavy
            // re-layout is a single update.
            let chromeDuration = sidebarAnimationStyle == .resize ? Self.sidebarResizeDuration : Self.sidebarWidthDuration
            let newContentWidth = { mainAreaWidth - (target - WindowLayout.compactSidebarWidth) }
            // Every collapse is now a deliberate user toggle (see isCompactSidebar's
            // own comment), so it always waits for the sidebar.
            if compact {
                // Collapsing: the content keeps its old size until the animation is over.
                DispatchQueue.main.asyncAfter(deadline: .now() + chromeDuration) {
                    guard sidebarToggleGeneration == generation else { return }
                    var commit = Transaction()
                    commit.disablesAnimations = true
                    withTransaction(commit) {
                        pageInset = target
                        if mainAreaWidth > 0 { columnClass = WindowLayout.columnClass(mainWidth: newContentWidth()) }
                    }
                }
            } else {
                // Opening (or a window-forced collapse): the content takes its
                // new size at once.
                var jump = Transaction()
                jump.disablesAnimations = true
                withTransaction(jump) {
                    pageInset = target
                    if mainAreaWidth > 0 { columnClass = WindowLayout.columnClass(mainWidth: newContentWidth()) }
                }
            }
            if sidebarAnimationStyle == .resize {
                // Resize style: nothing leaves. The card's width tweens and
                // the tabs, icons and labels resize with it (SidebarTabItem
                // reads the animated width). The content that has to switch
                // layout -- labels, the tools block -- switches through its
                // own transitions: right away when collapsing, partway
                // through when expanding, so a label never shows up inside
                // a pill that's still too narrow for it.
                if compact {
                    // Collapsing: labels leave right away, in this same update AND
                    // this same transaction as the width. They used to flip in a
                    // second withAnimation of their own (0.2s against the width's
                    // 0.3s), and the two curves each moved part of every row's
                    // frame, so all the icons drifted about a point to the left
                    // mid-collapse and back -- a wiggle. One transaction = one
                    // curve for every row.
                    withAnimation(.easeInOut(duration: Self.sidebarResizeDuration)) {
                        sidebarWidth = target
                        sidebarDisplayCompact = compact
                    }
                } else {
                    withAnimation(.easeInOut(duration: Self.sidebarResizeDuration)) { sidebarWidth = target }
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.sidebarResizeDuration * 0.25) {
                        guard sidebarToggleGeneration == generation else { return }
                        withAnimation(.easeInOut(duration: 0.2)) { sidebarDisplayCompact = compact }
                    }
                }
                // After the last label/tools transition (a flip at most
                // 0.45 * duration in, plus its 0.2s) has finished.
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.sidebarResizeDuration + 0.25) {
                    if sidebarToggleGeneration == generation { sidebarSequencePlaying = false }
                }
                return
            }
            // Pop style. Both start together. The row exit's ambient
            // duration only needs to cover the (unstaggered) exit itself.
            withAnimation(.linear(duration: AnyTransition.dominoExitDuration)) { sidebarRowsHidden = true }
            withAnimation(.easeInOut(duration: Self.sidebarWidthDuration)) { sidebarWidth = target }
            // A second toggle landing mid-sequence supersedes both callbacks
            // below (the newer onChange owns sidebarWidth/sidebarRowsHidden),
            // hence the generation check in each.
            DispatchQueue.main.asyncAfter(deadline: .now() + AnyTransition.dominoExitDuration) {
                guard sidebarToggleGeneration == generation else { return }
                // Every row is gone by now, so it's safe for them to learn
                // the new mode -- see sidebarDisplayCompact's declaration.
                sidebarDisplayCompact = compact
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.sidebarWidthDuration) {
                guard sidebarToggleGeneration == generation else { return }
                // The width has landed: start the reveal.
                // The ambient wrapper's OWN duration must span the full
                // staggered reveal, not just one row's animation -- each
                // row's transition bakes its own delay+curve (see
                // AnyTransition.dominoPop) which overrides this ambient one
                // for HOW it animates, but SwiftUI still uses the ambient
                // transaction's duration to decide WHEN an insertion is
                // "done". A short ambient duration cut every row past the
                // first couple off mid-delay, before their own animation ever
                // started.
                withAnimation(.linear(duration: Self.sidebarEnterTotal)) { sidebarRowsHidden = false }
                // The reveal is the last thing to play; once it has, animations
                // go back to being switched off for the rest of a live drag.
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.sidebarEnterTotal) {
                    if sidebarToggleGeneration == generation { sidebarSequencePlaying = false }
                }
            }
        }
        // Tells DropAppDelegate to re-apply the window's minimum size for the new
        // state, growing the window if expanding pushed it above the current width
        // (see sidebarCollapsedDidChange) -- AppKit-level, so it lives outside SwiftUI.
        .onChange(of: sidebarCollapsedByUser) { _, collapsed in
            NotificationCenter.default.post(name: .dropSidebarCollapsedChanged, object: nil, userInfo: ["collapsed": collapsed])
        }
        .environment(\.isCompactHeight, isCompactHeight)
        .environment(\.isTinyHeight, isTinyHeight)
        // While the user drags the window edge, layout should track their hand
        // exactly. Every breakpoint the drag crosses (compact sidebar, compact
        // height, a section appearing or disappearing) used to start its own
        // animation mid-drag, stacking GPU work on top of the per-frame relayout
        // and making resizing feel sluggish. Scoped to live resize only, so
        // every other animation in the app is unaffected -- and the sidebar's
        // own collapse/expand sequence is exempt (sidebarSequencePlaying), so
        // it plays live as the drag crosses its threshold.
        .transaction { t in
            if NSApp.keyWindow?.inLiveResize == true, !sidebarSequencePlaying {
                t.animation = nil
                t.disablesAnimations = true
            }
        }
        // Window-level drop target — drag a URL anywhere onto Drop
        .onDrop(of: ["public.url", "public.plain-text"], isTargeted: nil) { providers in
            handleDrop(providers: providers)
            return true
        }
        .preferredColorScheme(.dark)
        // Quitting stops whatever is running and removes the partial files it had written, the same
        // as Cancel does (see DownloadManager.cancelAllForQuit).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            manager.cancelAllForQuit()
            for job in convertQueue where job.status == .converting { job.cancel() }
        }
        .onAppear {
            // Mirrors the Download tab's own Paste & Analyze button exactly:
            // validate every line is a URL, insert pending placeholder cards
            // immediately for visual feedback, then kick off analysis — so
            // pasting from the menu bar behaves identically to pasting on
            // the Download page itself.
            // A live-resize drag just ended -- catch the settled breakpoint
            // snapshot up to wherever the raw geometry actually landed. See
            // settledWindowSize's declaration.
            NotificationCenter.default.addObserver(forName: .dropLiveResizeEnded, object: nil, queue: .main) { _ in
                settledWindowSize = windowSize
                // Minus the room the (pinned) sidebar takes -- mainAreaWidth is
                // measured as if the sidebar were collapsed.
                columnClass = WindowLayout.columnClass(mainWidth: mainAreaWidth - (pageInset - WindowLayout.compactSidebarWidth))
            }
            // The menu bar's Check for Updates (panel button and right-click menu):
            // exactly what the sidebar's button does, gated the same way (it is
            // disabled until the tools are installed).
            NotificationCenter.default.addObserver(forName: .menuBarCheckForUpdates, object: nil, queue: .main) { _ in
                guard manager.toolsReady else { return }
                manager.ensureLatestTools()
                manager.dropUpdater.checkForUpdates()
            }
            NotificationCenter.default.addObserver(forName: .menuBarDownload, object: nil, queue: .main) { note in
                guard let raw = note.userInfo?["url"] as? String else { return }
                let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !candidate.isEmpty, allLinesAreURLs(candidate) else { return }
                activeTab = .download
                // Deliberately NOT activating/foregrounding the app here --
                // the menu bar panel's whole point is a quick background
                // paste-and-queue without interrupting whatever the user is
                // doing (its button just turns to "Queued" -- you stay where
                // you are unless you tap "Open Drop" yourself).
                let pendingURLs = candidate.components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                // Capture each placeholder's own id (not just its url) so
                // duplicate-url pastes stay independent through analyze --
                // see analyzeProcesses' declaration for why.
                var pendingIDs: [UUID] = []
                withAnimation(.spring(response: 0.35)) {
                    for u in pendingURLs {
                        let placeholder = LinkPreview(
                            url: u, title: u, thumbnailURL: "",
                            hasVideo: false, duration: "",
                            mediaMode: .audioOnly, isPending: true
                        )
                        pendingIDs.append(placeholder.id)
                        linkPreviews.append(placeholder)
                    }
                }
                urlText = ""
                analyzeURL(urls: pendingURLs, ids: pendingIDs)
            }
        }
        // Cmd+Shift+V: paste clipboard and download immediately
        .background(
            Button("") {
                if let s = NSPasteboard.general.string(forType: .string) {
                    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    urlText = trimmed
                    download()
                }
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .hidden()
        )
        // Escape: clear URL field -- removed from the view hierarchy
        // entirely (not merely .disabled) while the update overlay has a
        // card on screen. .disabled(_:) does NOT make a keyboard shortcut
        // inert the way it sounds like it should -- confirmed on-device
        // (via the Dev tab's overlay previews, using Escape specifically):
        // a disabled button can still consume an ambiguous shortcut before
        // an enabled one gets a chance, so with just .disabled() here,
        // this button and the overlay's own Escape-to-dismiss
        // (DropUpdateOverlayView.escapeCatcher) competed for the same
        // keypress and this one silently won every time, leaving every
        // overlay preview un-Escape-dismissable. An `if` inside the
        // ViewBuilder background block actually excludes this button from
        // the hierarchy while a card is up, so there's only ever one
        // Escape-bound button to route to.
        .background {
            if !dropDriver.isPresentingCard {
                Button("") { urlText = "" }
                    .keyboardShortcut(.escape, modifiers: [])
                    .hidden()
            }
        }
        // Drop's own update UI -- attached at the root so it can appear
        // over any tab, not just while Dev happens to be open, since an
        // update can be found at any time.
        .overlay(DropUpdateOverlayView(driver: dropDriver))

    }

    // MARK: - Sidebar

    /// Vertical nav rail. Layout borrows the Perplexity Mac app's plain-row
    /// convention (no divider/border, quiet spacing-based separation,
    /// small icons inline with text) but the rail itself is now an actual
    /// floating GlassCard -- same recipe (blur + black tint + grain + rim
    /// stroke) and corner radius as every other card in the app, with a
    /// margin from the window edges so it visually floats rather than
    /// sitting as a flush edge-to-edge panel. Same three destinations and
    /// the same Tools pill / log toggle controls as the old horizontal tab
    /// bar, just re-flowed top-to-bottom.
    /// Header: the collapse/expand toggle lives in a slot exactly as wide as
    /// the collapsed rail, at the card's leading edge, so it sits in the same
    /// spot whether the sidebar is open or closed. Open, the logo and "Drop"
    /// sit beside it; closed there's nothing else on the row, so it never
    /// crowds the narrow rail. Always the real toggle now -- expanding grows
    /// the window to fit if it's currently too narrow (see
    /// DropAppDelegate.sidebarCollapsedDidChange), so there's no "too narrow
    /// to expand" state to fall back to the bare logo for anymore.
    private var sidebarToggleSlot: some View {
        HoverIconButton(
            icon: "sidebar.left", size: 16,
            // Short caption -- the sidebar's expanded state also shows the
            // "Drop" wordmark immediately to this button's right, so a
            // longer "Collapse sidebar"/"Expand sidebar" caption (which
            // pops out rightward, see captionExpandsFrom below) ran
            // straight into that text.
            help: isCompactSidebar ? "Expand" : "Collapse",
            // Collapsed, this caption has nowhere to pop out TO -- the rail
            // is exactly as wide as the button's own slot -- so it got
            // clipped by the sidebar's own glassCard (reported live). The
            // plain system tooltip from `.help` above still works there
            // (AppKit draws it outside SwiftUI's clip entirely), so the
            // custom caption only takes over once expanded, where there's
            // real room for it.
            expandable: !isCompactSidebar,
            captionExpandsFrom: .leading
        ) {
            sidebarCollapsedByUser.toggle()
        }
        .accessibilityLabel(isCompactSidebar ? "Expand Sidebar" : "Collapse Sidebar")
        .frame(width: WindowLayout.compactSidebarWidth)
        // The caption pops out rightward past this slot's own bounds, right
        // where the "Drop" wordmark sits once expanded -- reported live as
        // rendering BEHIND that label instead of in front of it, since
        // sidebarLabel is declared right after this in the header HStack
        // and plain sibling paint order draws later declarations on top.
        .zIndex(1)
    }

    private var sidebarLabel: some View { SidebarBrandLabel() }

    var sidebar: some View {
        VStack(spacing: 0) {
            // Header is two independent reveal steps: the toggle slot is
            // index 0 (leftmost, so it leads), the label (icon + "Drop", open
            // only) is index 1 -- each in its OWN `if !sidebarRowsHidden`
            // so SwiftUI tracks them as separate insertions/removals (see
            // the note on the nav items below for why shared conditionals
            // don't stagger). The label follows sidebarDisplayCompact, which
            // only changes while every row is hidden.
            HStack(spacing: 0) {
                if !sidebarRowsHidden {
                    sidebarToggleSlot
                        .transition(.dominoPop(index: 0))
                }
                if !sidebarRowsHidden, !sidebarDisplayCompact {
                    sidebarLabel
                        .padding(.leading, -8)
                        .transition(sidebarAnimationStyle == .resize ? AnyTransition.labelFade : AnyTransition.dominoPop(index: 1))
                }
                Spacer(minLength: 0)
            }
            .frame(height: 27)
            .padding(.top, isTinyHeight ? 8 : 16)
            .padding(.bottom, isTinyHeight ? 6 : 18)

            // Nav items — larger touch targets (bumped padding/font inside
            // SidebarTabItem itself) with real breathing room between rows,
            // instead of the previous near-zero 2pt gap. Each row is its own
            // domino step (index 2-6), and critically each gets its OWN
            // independent `if !sidebarRowsHidden { ... }` rather than sharing
            // one `if` around the whole VStack -- when several sibling views
            // shared a single conditional, SwiftUI treated that whole block
            // as ONE unit entering/leaving, and did not reliably apply each
            // child's own individually-delayed `.transition()` to its own
            // removal/insertion. An unconditionally-present VStack containing
            // several independently-gated children is the pattern SwiftUI's
            // transition system unambiguously honors per-view (same pattern
            // the header above and ToolsStatusPill below also use).
            VStack(spacing: 6) {
                if !sidebarRowsHidden {
                SidebarTabItem(label: "Download", icon: "arrow.down.circle", isSelected: activeTab == .download,
                        badge: linkPreviews.isEmpty ? nil : "\(linkPreviews.count)") {
                    withAnimation(.spring(response: 0.25)) { activeTab = .download }
                }
                .accessibilityIdentifier("tab_download")
                .transition(.dominoPop(index: 2))
                }
                if !sidebarRowsHidden {
                SidebarTabItem(label: "Convert", icon: "arrow.triangle.2.circlepath", isSelected: activeTab == .convert,
                        badge: convertQueue.isEmpty ? nil : "\(convertQueue.count)") {
                    withAnimation(.spring(response: 0.25)) { activeTab = .convert }
                }
                .accessibilityIdentifier("tab_convert")
                .transition(.dominoPop(index: 3))
                }
                if !sidebarRowsHidden {
                SidebarTabItem(label: "History", icon: "clock",
                        isSelected: activeTab == .history,
                        badge: manager.history.entries.isEmpty ? nil : "\(manager.history.entries.count)") {
                    withAnimation(.spring(response: 0.25)) { activeTab = .history }
                }
                .accessibilityIdentifier("tab_history")
                .transition(.dominoPop(index: 4))
                }
                if !sidebarRowsHidden {
                SidebarTabItem(label: "Log", icon: "terminal", isSelected: activeTab == .log) {
                    withAnimation(.spring(response: 0.25)) { activeTab = .log }
                }
                .accessibilityIdentifier("tab_log")
                .transition(.dominoPop(index: 5))
                }
                // Present only on a machine holding the Sparkle signing key
                // and GitHub token -- see DevKeychain.isDevMachine. On any
                // other machine this row, and everything behind it, simply
                // doesn't exist; that absence is the entire access control.
                // Guarded by DEV_BUILD (see Config/Base.xcconfig) on top of
                // that check: the public repo doesn't even compile
                // DevKeychain/DevReleaseView in at all, so this couldn't
                // reference them regardless.
                #if DEV_BUILD
                if !sidebarRowsHidden, DevKeychain.isDevMachine {
                    SidebarTabItem(label: "Dev", icon: "wrench.and.screwdriver", isSelected: activeTab == .devRelease) {
                        withAnimation(.spring(response: 0.25)) { activeTab = .devRelease }
                    }
                    .accessibilityIdentifier("tab_dev")
                    .transition(.dominoPop(index: 6))
                }
                // DEBUG only (never in the Release build that ships to users,
                // where the Dev tab's absence is the access control): a Debug
                // build that can't reach the keychain items -- the prompt was
                // denied, or a new build's signature was never approved --
                // otherwise just silently has no Dev tab for the whole session.
                #if DEBUG
                if !sidebarRowsHidden, !DevKeychain.isDevMachine {
                    SidebarTabItem(label: "Dev (locked)", icon: "lock", isSelected: false) {}
                        .opacity(0.4)
                        .help("Keychain access to the Sparkle signing key / GitHub token was denied or is missing. Relaunch and choose Always Allow.")
                        .accessibilityIdentifier("tab_dev_locked")
                        .transition(.dominoPop(index: 6))
                }
                #endif
                #endif
            }
            .padding(.horizontal, 8)

            Spacer()

            // Tools section -- integrated directly into the rail as an
            // always-visible block (no popover, no toggle), pinned to
            // the bottom via the Spacer() above. Continues the domino from
            // index 7 -- its OWN rows (yt-dlp/ffmpeg/Drop/Check for Updates)
            // are each a separate step (see baseIndex), rather than this whole
            // block popping as one piece. The block is ONE set of views at
            // every sidebar width (its icons sit on the rail exactly where
            // the tab icons do; the text appears beside them as the card
            // widens), so opening the sidebar widens it in place. It's
            // inset by the same railContentInset as the nav pills so the two
            // line up. Passed through as rowsHidden rather than gated with an
            // outer `if !sidebarRowsHidden` here -- gating the WHOLE pill from
            // outside would remove all of its rows in one shot, and even
            // per-row removal changes this bottom-pinned block's height,
            // sliding it; ToolsStatusPill instead keeps every row mounted and
            // shrinks/blurs each one in place (see DominoVisibility).
            ToolsStatusPill(manager: manager, baseIndex: 7, rowsHidden: sidebarRowsHidden)
                .padding(.horizontal, WindowLayout.railContentInset)
                .padding(.bottom, isTinyHeight ? 8 : 16)
        }
        // maxHeight: .infinity guards against the card collapsing to the lone
        // Spacer's zero intrinsic height during the brief window where every
        // row is hidden mid-domino (header/nav/tools all conditionally gone)
        // -- keeps the card's HEIGHT stable throughout, so only its width
        // ever visibly changes.
        .frame(width: sidebarWidth)
        .frame(maxHeight: .infinity)
        // Real floating card -- identical material/radius/rim-stroke
        // recipe as every other GlassCard in the app (VisualEffectBlur +
        // black tint + grain + gradient rim stroke), not a bespoke
        // one-off background.
        .glassCard(cornerRadius: DesignTokens.Radius.large)
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 12)
    }

    // MARK: - Main Panel

    var mainPanel: some View {
        VStack(spacing: 12) {
            // Input area — the paste field and Paste & Analyze button
            // share one seamless pill bar (built inside urlCard itself), so
            // no outer card wrapper is needed here.
            urlCard
                .shadow(color: .black.opacity(DesignTokens.Interactive.glowShadowPeak), radius: 10, y: 4)
                // Clearly more breathing room above the drop zone (top of
                // window) and below it (before the toolbar/list header
                // row). Previous +14/+8 bump read as barely-there at this
                // window scale, so these are large, deliberate increases --
                // the extra bottom padding stacks with the VStack's own
                // 12pt spacing so this gap grows without also widening the
                // toolbar-to-scroll-area gap beneath it. Tighter in a short
                // window, where the card list needs every point.
                .padding(.top, isCompactHeight ? 22 : 30)
                .padding(.bottom, isCompactHeight ? 10 : 14)
                .followsSidebar()

            if isTinyHeight {
                // Too short for pinned chrome AND a card list: everything under
                // the paste bar scrolls together, so the list header, the cards
                // and the bottom bar are all still reachable and fully legible.
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: true) {
                        VStack(spacing: 12) {
                            mainPanelToolbar.pinnedToSidebar()
                            mainPanelCardsContent
                            if linkPreviews.isEmpty {
                                EmptyStateView(
                                    icon: "arrow.down.to.line",
                                    title: "Copy a link to get started",
                                    subtitle: "Supports YouTube, SoundCloud, TikTok and more"
                                )
                                .padding(.vertical, 16)
                                .followsSidebar()
                                // Own transition, matching the non-tiny-height branch's
                                // equivalent empty state (see its own .overlay +
                                // .transition(.blurIn)) -- otherwise this falls back to
                                // SwiftUI's default opacity fade.
                                .transition(.blurIn)
                            }
                            mainPanelBottomBar.pinnedToSidebar()
                        }
                    }
                    .onChange(of: linkPreviews.count) {
                        withAnimation(.spring(response: 0.4)) {
                            proxy.scrollTo("scrollBottom", anchor: .bottom)
                        }
                    }
                }
            } else {
                // Only the gap between the Select / Collapse / Clear row and the
                // first card is tighter (6pt, not the VStack's 12); the space
                // above the row is unchanged.
                VStack(spacing: 6) {
                    mainPanelToolbar
                        .followsSidebar()
                    mainPanelCardsScroll
                }
                mainPanelBottomBar
                    .followsSidebar()
            }
        }
    }

    // MARK: Main panel pieces (composed pinned or all-scrolling -- see mainPanel)

    @ViewBuilder
    private var mainPanelToolbar: some View {
            // ── List header — link count, then Select/Done + Select All/
            // Deselect All, with Collapse/Clear All on the right. The buttons
            // are capsules sitting directly on the page, not inside a glass
            // bar of their own.
            if hasAnyLinkItems {
                HStack(spacing: 8) {
                    Text(linkPreviews.count == 1 ? "1 link" : "\(linkPreviews.count) links")
                        .font(.appMono(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                        .padding(.trailing, 4)
                    GlassButton(
                        label: isBatchMode ? "Done" : "Select",
                        icon: isBatchMode ? "xmark.circle" : "checkmark.circle",
                        tint: DesignTokens.Accent.primary,
                        fitContent: true
                    ) {
                        withAnimation(.spring(response: 0.25)) {
                            isBatchMode.toggle()
                            // Select mode always starts unchecked so checkmarks
                            // never carry over stale state. Exiting Select mode
                            // resets every item back to fully included, since
                            // outside Select mode checkboxes are hidden and
                            // nothing should be silently excluded.
                            for i in linkPreviews.indices { linkPreviews[i].isSelected = !isBatchMode }
                        }
                    }
                    if isBatchMode {
                        GlassButton(
                            label: allEligibleLinksSelected ? "Deselect All" : "Select All",
                            icon: allEligibleLinksSelected ? "circle" : "checkmark.circle",
                            tint: .white,
                                fitContent: true
                        ) {
                            withAnimation(.spring(response: 0.25)) {
                                toggleSelectAllLinks()
                            }
                        }
                    }
                    Spacer()
                    // Hidden (not just disabled) while any card is still
                    // analyzing -- pending cards have no collapse state yet,
                    // so the button has nothing meaningful to do until the
                    // whole queue has resolved.
                    if !anyLinksStillAnalyzing {
                        GlassButton(
                            label: allLinksCollapsed ? "Expand All" : "Collapse All",
                            icon: allLinksCollapsed ? "chevron.down" : "chevron.up",
                            tint: .white,
                                fitContent: true,
                            disabled: !hasExpandableLinks
                        ) {
                            withAnimation(.easeOut(duration: 0.22)) {
                                toggleCollapseAllLinks()
                            }
                        }
                    }
                    GlassButton(
                        label: isBatchMode ? "Clear Selected" : "Clear All",
                        icon: "trash",
                        tint: .red,
                        fitContent: true,
                        disabled: isBatchMode && !linkPreviews.contains { $0.isSelected }
                    ) {
                        withAnimation(.spring(response: 0.3)) {
                            // Only terminate processes belonging to the cards
                            // actually being cleared -- this used to terminate
                            // every in-flight analyze process unconditionally,
                            // so "Clear Selected" in batch mode (or clearing one
                            // duplicate among several) also silently killed
                            // every OTHER still-analyzing card's process even
                            // though only some cards were meant to be cleared.
                            let idsBeingCleared: Set<UUID> = isBatchMode
                                ? Set(linkPreviews.filter { $0.isSelected }.map { $0.id })
                                : Set(linkPreviews.map { $0.id })
                            for id in idsBeingCleared {
                                if let proc = analyzeProcesses[id] {
                                    DownloadManager.terminateProcessTree(proc)
                                    analyzeProcesses.removeValue(forKey: id)
                                    manager.appendLog("Analyze cancelled: \(id)")
                                }
                            }
                            if isBatchMode {
                                // Also mark any still-pending, still-queued
                                // (behind the analyze concurrency gate) cards
                                // being cleared as cancelled -- they have no
                                // Process yet to terminate above, but without
                                // this they'd still silently analyze and
                                // reappear even though the user just cleared them.
                                for p in linkPreviews where p.isSelected && p.isPending {
                                    cancelledAnalyzeIDs.insert(p.id)
                                }
                                for p in linkPreviews where p.isSelected {
                                    if let did = p.downloadID, let dl = manager.downloads.first(where: { $0.id == did }) {
                                        // Cancel before removing -- deleting the Download
                                        // object out from under an active process orphaned
                                        // it headless with no reference left to ever kill it.
                                        if dl.status == .downloading { manager.cancel(download: dl) }
                                        manager.downloads.removeAll { $0.id == did }
                                    }
                                }
                                linkPreviews.removeAll { $0.isSelected }
                            } else {
                                for p in linkPreviews where p.isPending {
                                    cancelledAnalyzeIDs.insert(p.id)
                                }
                                for p in linkPreviews {
                                    if let did = p.downloadID, let dl = manager.downloads.first(where: { $0.id == did }) {
                                        if dl.status == .downloading { manager.cancel(download: dl) }
                                        manager.downloads.removeAll { $0.id == did }
                                    }
                                }
                                linkPreviews.removeAll()
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
                // Same shared content column as the paste bar, the card queue
                // below and the bottom bar (see WindowLayout.columnWidth), so
                // every row in this tab is pixel-identical in width.
                .contentColumn()
                .transition(.glassBar(anchor: .top))
            }

    }

    @ViewBuilder
    private var mainPanelCardsContent: some View {
                    LazyVStack(spacing: 10) {
                        // yt-dlp/ffmpeg are downloaded on launch (see ytdlpPath/
                        // ffmpegPath) -- never actually bundled inside the app
                        // despite what some older comments elsewhere claim -- so a
                        // brand new install always hits this for however long that
                        // one-time download takes. Used to show an alarming
                        // "Bundled tools missing, please reinstall" error here
                        // unconditionally instead, which was simply wrong for this
                        // completely normal state and gave no progress feedback at
                        // all (a new user's first impression was a false
                        // "something's broken" message, not real setup progress).
                        if !manager.checkingDeps && !manager.toolsReady {
                            if manager.updatingYtdlp || manager.updatingFFmpeg {
                                toolsSetupCard
                            } else {
                                toolsSetupFailedCard
                            }
                        }

                        previewCard

                        Color.clear.frame(height: 4).id("scrollBottom")
                    }
                    // Same content column as the paste bar, list header and
                    // bottom bar, so every card in the queue lines up with them.
                    // One measured number (see WindowLayout) rather than a
                    // containerRelativeFrame, which resolves against the
                    // NEAREST container -- and this VStack sits inside a
                    // ScrollView, which has its own.
                    .contentColumn()
                    // Laid out once for where the sidebar will be; each card's
                    // outline follows the sidebar's edge live (LiveGlassCard).
                    .pinnedToSidebar()
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                    // ONE reader for the whole queue, not one per card: a modifier
                    // applied to a ForEach (as this used to be, inside downloadCard)
                    // is distributed to EACH row individually rather than wrapping
                    // them as a group, so every card painted its own popover as part
                    // of its own layout slot -- and a later card, painted after an
                    // earlier one in this LazyVStack, still covered that earlier
                    // card's popover wherever the two overlapped (a .zIndex on the
                    // row itself didn't help either: it only reorders siblings of a
                    // ZStack, not of a VStack/LazyVStack, confirmed live -- the first
                    // card's own popover still clipped under the second card's
                    // opaque background). This LazyVStack is a genuine single view by
                    // the time its own modifier chain reaches this point, so one
                    // overlay here paints once, above every row, unconditionally.
                    .dropdownPopoverOverlay(openID: $openDropdownID)
    }

    /// Shown while yt-dlp/ffmpeg's one-time setup download is actually in
    /// flight -- real per-tool progress (see ytdlpDownloadProgress/
    /// ffmpegDownloadProgress), not a generic spinner, so a first launch
    /// doesn't read as broken for however long the download takes. Each row
    /// flips to "Done" independently the moment ITS OWN tool finishes --
    /// the two run in parallel with no ordering guarantee.
    private var toolsSetupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle")
                    .foregroundColor(.white.opacity(DesignTokens.Text.secondary))
                    .font(.appMono(size: 16))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Setting up yt-dlp and ffmpeg…")
                        .font(.appMono(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(DesignTokens.Text.primary))
                    Text("One-time download — this only happens once.")
                        .font(.appMono(size: 11))
                        .foregroundColor(.white.opacity(DesignTokens.Text.secondary))
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 8) {
                toolSetupProgressRow(name: "yt-dlp", fraction: manager.ytdlpDownloadProgress, done: !manager.updatingYtdlp)
                toolSetupProgressRow(name: "ffmpeg", fraction: manager.ffmpegDownloadProgress, done: !manager.updatingFFmpeg)
            }
        }
        .padding(14)
        .glassCard(cornerRadius: DesignTokens.Radius.medium)
    }

    private func toolSetupProgressRow(name: String, fraction: Double, done: Bool) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.appMono(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(DesignTokens.Text.secondary))
                .frame(width: 48, alignment: .leading)
            fractionProgressBar(done ? 1 : fraction)
            Text(done ? "Done" : (fraction > 0 ? "\(Int((fraction * 100).rounded()))%" : ""))
                .font(.appMono(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(DesignTokens.Text.secondary))
                .frame(width: 32, alignment: .trailing)
        }
    }

    /// The setup download genuinely finished (or was already current) and
    /// the tools are STILL not resolvable -- a real failure, not just
    /// "still downloading." Can recur on any later launch too, not only
    /// the first one, if e.g. the network drops mid-download.
    private var toolsSetupFailedCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.appMono(size: 16))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn't set up yt-dlp/ffmpeg")
                    .font(.appMono(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(DesignTokens.Text.primary))
                Text("Check your internet connection, then try again.")
                    .font(.appMono(size: 11))
                    .foregroundColor(.white.opacity(DesignTokens.Text.secondary))
            }
            Spacer()
            GlassButton(label: "Retry", icon: "arrow.clockwise", tint: DesignTokens.Accent.primary, fitContent: true) {
                manager.ensureLatestTools()
            }
        }
        .padding(14)
        .glassCard(cornerRadius: DesignTokens.Radius.medium)
    }

    @ViewBuilder
    private var mainPanelCardsScroll: some View {
            // ── Scrollable cards area ────────────────────────────────
            // LazyVStack instead of VStack: a plain VStack forces every
            // card's full view tree (blur material, animated rim glow,
            // async thumbnail) to build and render simultaneously
            // regardless of scroll position, which is what caused the
            // scroll lag/stutter as the queue grew. LazyVStack only
            // renders rows near the visible viewport -- same visuals,
            // no eager off-screen rendering cost. ScrollViewReader's
            // .scrollTo still works identically with LazyVStack.
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: true) {
                    mainPanelCardsContent
                }
                // Fade scrolled cards out near the top edge instead of a hard
                // clip against the frosted header above.
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.035),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .onChange(of: linkPreviews.count) {
                    withAnimation(.spring(response: 0.4)) {
                        proxy.scrollTo("scrollBottom", anchor: .bottom)
                    }
                }
                // Empty state — overlaid and truly centered in the scroll area.
                // It is a light view, so it FOLLOWS the sidebar's edge frame by
                // frame (always centered in what's visible) instead of waiting
                // for the sidebar like the cards do.
                .overlay {
                    if linkPreviews.isEmpty {
                        EmptyStateView(
                            icon: "arrow.down.to.line",
                            title: "Copy a link to get started",
                            subtitle: "Supports YouTube, SoundCloud, TikTok and more"
                        )
                        .followsSidebar()
                        .transition(.blurIn)
                    }
                }
                .animation(.easeOut(duration: 0.25), value: linkPreviews.isEmpty)
            }

    }

    @ViewBuilder
    private var mainPanelBottomBar: some View {
            // Whether there's actually something the Download button could
            // start right now -- previously this was also what gated whether
            // the button showed up AT ALL (showPrimaryAction below). Now the
            // button always shows (matching Convert's queue button), so this
            // becomes an enablement check instead, same as Convert's
            // hasSelectedQueued.
            let eligibleToDownload = selectedPreviews.contains { $0.downloadID == nil }
            // ── Pinned bottom bar ─────────────────────────────────────
            TabBottomBar(
                    config: config,
                    // Always shown now, even with nothing queued (matches
                    // Convert's Convert button) -- it reads "No Links to
                    // Download" (greyed, disabled) instead of disappearing.
                    showPrimaryAction: true,
                    toolsReady: readyToDownload,
                    // Blocks Download until every link currently in the
                    // queue has finished analyzing (isPending == false),
                    // not just the selected ones -- a still-analyzing card
                    // doesn't have real format/title data yet, and starting
                    // a run while one is mid-flight raced ahead of it
                    // instead of waiting the way the button visually implies
                    // it should. Checked against the WHOLE queue rather than
                    // just selectedPreviews since an in-flight card could be
                    // selected the moment it resolves -- the queue as a
                    // whole needs to settle first.
                    primaryActionEnabled: eligibleToDownload && !linkPreviews.contains(where: { $0.isPending }),
                    primaryActionDisabledLabel: linkPreviews.contains(where: { $0.isPending })
                        ? "Analyzing…"
                        : (linkPreviews.isEmpty ? "No Links to Download" : "Nothing to Download"),
                    primaryActionDisabledIcon: linkPreviews.contains(where: { $0.isPending }) ? "hourglass" : nil,
                    primaryActionInProgress: manager.downloads.contains { $0.status == .downloading },
                    primaryActionLabel: downloadButton_label,
                    primaryActionIcon: "arrow.down.circle",
                    onClearAll: {},
                    onPrimaryAction: { download() },
                    showClearAll: false,
                    hasBatchDirectoryControl: true
                ) {
                    // leftControls: none — cookie source is now resolved automatically on failure
                    EmptyView()
                } extraControls: {
                    EmptyView()  // extraControls: unused now that SAVE TO lives in batchDirectoryControl
            } batchDirectoryControl: {
                // The destination, on the same row as the Auto-Open Folder toggle:
                // the folder as a capsule (editable path, with the estimated total
                // size at its trailing end), then Browse and Reveal as icon buttons.
                // No SAVE TO label -- the folder itself says what it is.
                HStack(spacing: DropGrid.rowSpacing) {
                    FieldCapsule {
                        Image(systemName: "folder")
                            .font(.appMono(size: DropGrid.fieldFontSize - 1))
                            .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                            .accessibilityHidden(true)
                        TextField("", text: $config.outputDir)
                            .textFieldStyle(.plain)
                            .font(.appMono(size: DropGrid.fieldFontSize))
                            .foregroundColor(.white.opacity(DesignTokens.Text.secondary))
                        FolderSizeLabel(label: totalEstimatedSizeLabel)
                    }
                    .help("Save to This Folder" + (totalEstimatedSizeLabel.map { " · Est. \($0)" } ?? ""))

                    FolderActionButtons(path: config.outputDir) { config.outputDir = $0 }
                }
                .frame(maxWidth: .infinity)
            }
    }

    // MARK: - URL Card

    // Same reasoning as pasteAnalyzeButton's own extraction just below: a small property of
    // its own instead of being written inline inside urlCard's already-large view-builder tree.
    // Overlaid on the trailing edge of urlCard's field ZStack (see that call site) -- in the
    // same spot/style the old typed-field's clear button used to occupy, back when this bar
    // accepted typing (see 16f354a). Dimmer than the accent-filled Analyze pill so it doesn't
    // compete with it, matching the leading link glyph's own secondary weight.
    private var clipboardRefreshButton: some View {
        HoverIconButton(icon: "arrow.clockwise", size: 11, boxSize: 24, color: .white.opacity(DesignTokens.Text.secondary), help: "Refresh Clipboard", shape: .circle) {
            refreshClipboardPreview()
        }
        .padding(.trailing, 6)
    }

    // Extracted out of urlCard's body -- inlining this GlassButton call
    // (with its tuple literal, closure, and multiple chained modifiers)
    // directly inside urlCard's giant view-builder tree made the whole
    // expression too complex for the type-checker to solve in reasonable
    // time (build failure at the unrelated Text("Paste a link…") line).
    // Giving it its own @ViewBuilder function isolates it as a separate
    // expression the compiler can type-check independently.
    @ViewBuilder
    private func pasteAnalyzeButton(label: String, icon: String, tint: Color, isRetry: Bool, innerPillHeight: CGFloat) -> some View {
        // Hover/press fill kept flat at the same level as rest -- per
        // user request this pill should NOT wash in extra color or grow
        // on hover, it should just gain a glow outline while the center
        // keeps reading as plain black glass.
        let fillOverride: (rest: Double, active: Double, hover: Double, press: Double) = (rest: 0.12, active: 0.12, hover: 0.12, press: 0.12)
        GlassButton(
            label: label,
            icon: icon,
            tint: tint,
            // Extra horizontal breathing room around the icon/label since
            // this pill nearly fills the outer bar's height and needs more
            // inset than the default 10pt to avoid feeling cramped.
            horizontalPadding: 16,
            // fillHeight: true -- makes the button's content (and
            // therefore its capsule background) actually stretch to
            // match the .frame(height: innerPillHeight) applied below,
            // instead of hugging the label/icon's natural size and
            // floating centered with visible gaps top/bottom.
            fillHeight: true,
            fitContent: false,
            isLoading: false,
            embedded: true,
            activeFillOverride: fillOverride,
            // Re-enable the glow-ring stroke even though embedded (see
            // GlassInteractive), and freeze scale at 1.0 so the pill
            // doesn't grow/shrink on hover/press -- only the outline glows.
            embeddedGlowStroke: true,
            scaleOverride: (hover: 1.0, press: 1.0)
        ) {
            if !isRetry {
                if let s = NSPasteboard.general.string(forType: .string) {
                    // Normalized per line (adds a missing https:// -- see
                    // normalizedDropURLLine) before anything downstream reads it, so a
                    // link copied without its scheme still analyzes correctly.
                    let candidate = s.components(separatedBy: "\n")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .map(normalizedDropURLLine)
                        .joined(separator: "\n")
                    // Check the clipboard candidate against the queue
                    // BEFORE committing it into urlText -- committing first
                    // and only bailing out afterward (previous approach)
                    // left the duplicate link sitting in the field with no
                    // further watcher to clean it up, so cancelling/
                    // clearing that same card later left urlText stale and
                    // it could resurface as a confusing "Invalid" state on
                    // the next unrelated interaction. Detecting first means
                    // urlText is simply never touched for a pure duplicate
                    // paste -- only the pill flashes "Already Analyzed"
                    // for a moment, nothing lingers in the field to go stale.
                    let candidateURLs = candidate.components(separatedBy: "\n")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    let existingURLs = Set(linkPreviews.map { $0.url })
                    let isPureDuplicate = !candidateURLs.isEmpty
                        && allLinesAreURLs(candidate)
                        && candidateURLs.allSatisfy { existingURLs.contains($0) }
                    if isPureDuplicate {
                        duplicateURLDetected = true
                        // Auto-clears so the pill returns to its normal
                        // "Paste & Analyze" label/icon/tint after a beat --
                        // this is a momentary confirmation, not a
                        // persistent error state like Invalid.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                            duplicateURLDetected = false
                        }
                        return
                    }
                    urlText = candidate
                    analyzeResult = nil
                    duplicateURLDetected = false
                    hasInvalidURLs = !allLinesAreURLs(urlText)
                }
                if !urlText.trimmingCharacters(in: .whitespaces).isEmpty && allLinesAreURLs(urlText) {
                    // Insert pending placeholder cards immediately
                    let pendingURLs = urlText.components(separatedBy: "\n")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    // Capture each placeholder's own id (not just its url) so
                    // duplicate-url pastes stay independent through analyze --
                    // see analyzeProcesses' declaration for why.
                    var pendingIDs: [UUID] = []
                    withAnimation(.spring(response: 0.35)) {
                        for u in pendingURLs {
                            let placeholder = LinkPreview(
                                url: u, title: u, thumbnailURL: "",
                                hasVideo: false, duration: "",
                                mediaMode: .audioOnly, isPending: true
                            )
                            pendingIDs.append(placeholder.id)
                            linkPreviews.append(placeholder)
                        }
                    }
                    urlText = ""  // clear field once cards are queued
                    analyzeURL(urls: pendingURLs, ids: pendingIDs)
                }
            }
        }
        .frame(width: DropGrid.topBarButtonWidth, height: innerPillHeight)
        .padding(.trailing, 5)
        // Deliberately NOT gated on isAnalyzing (see comment at call site)
        // -- only a genuine retry/invalid state or a missing yt-dlp/ffmpeg
        // setup should ever block this button.
        .disabled(isRetry || !readyToDownload)
        .opacity((isRetry || !readyToDownload) ? 0.5 : 1.0)
        .help(readyToDownload ? "" : HelpText.toolsMissing)
    }

    /// Re-reads the clipboard into `clipboardPreview` -- called on appear and
    /// whenever Drop becomes active, the two moments a link copied elsewhere first
    /// becomes visible to this window (mirrors MenuBarModel.refreshClipboard, called
    /// there when its panel opens instead). A genuinely NEW link (the content
    /// actually changed, not just re-read the same one) starts a short, bounded
    /// pulse -- see clipboardPulseActive's own comment for why this can't just be
    /// "pulse for as long as .links holds."
    private func refreshClipboardPreview() {
        let raw = NSPasteboard.general.string(forType: .string) ?? ""
        let next = raw.isEmpty ? .empty : MenuBarModel.describe(raw)
        if next != clipboardPreview, case .links = next {
            clipboardPulseGeneration += 1
            let generation = clipboardPulseGeneration
            clipboardPulseActive = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if clipboardPulseGeneration == generation { clipboardPulseActive = false }
            }
        }
        clipboardPreview = next
    }

    /// urlCard's field has nothing of its own to type or paste into, in ANY state --
    /// it's never editable. `isLink` picks the bright/dim text color the same way
    /// MenuBarQuickView's well does. Reported live: showing the clipboard's own raw
    /// (non-link) text here, right after opening the app or a new window, could
    /// read as blank/wrong before anything had actually been analyzed -- "it should
    /// only ever say Copy a link to see it here" whenever there's nothing to act on,
    /// empty clipboard or not-a-link alike; only a real link ever gets its own
    /// preview text.
    private var clipboardFieldContent: (text: String, isLink: Bool) {
        switch clipboardPreview {
        case .empty:
            return ("Clipboard's Empty", false)
        case .notLinks:
            return ("Copy a link to see it here", false)
        case .links(let count, let title, let detail):
            // A single link reads as one continuous URL (host immediately followed
            // by its path, no gap) -- reported live as a stray double space here
            // ("youtube.com    /watch?..." instead of "youtube.com/watch?...").
            // Several links keep a separating space; there's no single URL to read
            // as continuous there ("3 links  youtube.com, vimeo.com").
            guard !detail.isEmpty else { return (title, true) }
            return (count == 1 ? "\(title)\(detail)" : "\(title)  \(detail)", true)
        }
    }

    var urlCard: some View {
        // Taller bar so the field reads more substantial, and the Analyze
        // control is now an accent-filled pill INSET inside this same
        // capsule (Spotlight/Arc-style embedded action) rather than a
        // second independent GlassButton sitting beside it -- the old
        // layout had two adjacent capsules (field + button, each with
        // their own glass fill/stroke) which read as a visible seam/
        // "pill next to a pill" instead of one continuous field.
        let fieldHeight: CGFloat = 52
        // 2pt margin top/bottom -- the pill should nearly fill the bar's
        // full height, not float as a shorter capsule centered inside a
        // taller frame. Pairs with fillHeight: true below, which is what
        // actually makes the capsule's own background stretch to this
        // height instead of just hugging its label/icon content size.
        let innerPillHeight: CGFloat = fieldHeight - 10

        // spacing: 0 -- the field and the embedded pill must sit flush
        // against each other with zero gap so this reads as one
        // continuous bar. The pill's own fill/edge provides the visual
        // separation; whitespace here would reintroduce the seam.
        return HStack(spacing: 0) {
            // Leading icon, same convention as Convert's dropZoneView (folder.badge.plus) and
            // History's search bar (magnifyingglass) -- this was the one top bar missing it.
            Image(systemName: "link")
                .font(.appMono(size: 13, weight: .thin))
                .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                .padding(.leading, 14)
                .accessibilityHidden(true)

            ZStack(alignment: .leading) {
                // No longer a TextField: this bar has nothing of its own to type or
                // paste into (see clipboardFieldContent) -- it just shows whatever's
                // already on the clipboard, exactly like the menu bar panel's own
                // well, or a link just dropped onto it. Left-aligned to match the
                // convention every other URL/paste field in the app uses.
                let content = clipboardFieldContent
                // No clear button in any state now -- nothing here is ever editable
                // (a drop still lands in urlText as a fallback the Analyze button
                // reads if the clipboard itself can't be read, but the field never
                // shows or clears it directly), so a constant trailing inset is
                // enough; there's no longer a control to leave room for.
                Text(content.text)
                    .font(.appMono(size: 13))
                    .foregroundColor(.white.opacity(content.isLink ? 1 : 0.18))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .allowsHitTesting(false)
                    .frame(height: fieldHeight, alignment: .center)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
                    // Leaves room for clipboardRefreshButton (below), overlaid on this same
                    // ZStack's trailing edge, so long clipboard text truncates before running
                    // underneath it -- same reasoning the old typed-field clear button used this
                    // inset for.
                    .padding(.trailing, 40)
                    .onDrop(of: ["public.url", "public.plain-text"], isTargeted: $isDragging) { providers in
                        self.handleDrop(providers: providers)
                        return true
                    }
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) { clipboardRefreshButton }

            // Paste & Analyze / Retry -- inset accent pill living INSIDE
            // the outer field capsule (not a second independent capsule).
            let _isEmpty  = urlText.trimmingCharacters(in: .whitespaces).isEmpty
            let _isFailed = analyzeResult == .unknown
            let _isRetry  = _isFailed && !_isEmpty
            // Duplicate is NOT folded into isRetry -- isRetry also disables
            // the button and blocks the tap handler's own
            // paste-from-clipboard step (see pasteAnalyzeButton's `if
            // !isRetry`), and a duplicate hit should still let the user
            // paste something else right away rather than locking the
            // control the way a genuinely invalid clipboard value does.
            // Not gated on !_isEmpty -- urlText is deliberately left
            // untouched (usually empty) when a pure duplicate is detected,
            // so this flag has to stand on its own rather than depending
            // on the field actually holding text.
            let _isDuplicate = duplicateURLDetected && !_isRetry
            // Whatever's on the clipboard right now isn't a link -- only matters
            // when nothing else (a drop, a retry, a duplicate hit) already has an
            // opinion, since a dropped link should still analyze regardless of
            // clipboard state.
            let _clipboardHasLink: Bool = { if case .links = clipboardPreview { return true }; return false }()
            let _isClipboardInvalid = _isEmpty && !_isRetry && !_isDuplicate && !_clipboardHasLink
            // No longer gated on isAnalyzing -- the button stays fully
            // interactive while a previous paste's analyze is still in
            // flight, so pasting/submitting the next link never has to
            // wait on the last one to finish. isAnalyzing still exists for
            // the underlying pipeline's own per-batch bookkeeping, it's
            // just no longer surfaced on this control.
            let _pasteLabel: String = !readyToDownload ? "Setup Needed" : (_isRetry ? "Invalid" : (_isDuplicate ? "Already Analyzed" : (_isClipboardInvalid ? "Invalid Link" : "Analyze Link")))
            // Clipboard-invalid gets the SAME neutral icon/tint as Setup Needed, not
            // the red/triangle a genuine failed-analyze retry uses -- reported live as
            // "too dark": red at the button's own 50% disabled opacity read as a dark,
            // muddy maroon against the black glass, and an empty/non-link clipboard is
            // really the same "nothing to do yet" category as Setup Needed, not an
            // actual error, so it shouldn't reach for the same danger color at all.
            let _pasteIcon: String  = !readyToDownload ? "lock.fill" : ((_isRetry || _isClipboardInvalid) ? "exclamationmark.triangle" : (_isDuplicate ? "checkmark.circle" : "magnifyingglass"))
            let _pasteTint: Color   = (!readyToDownload || _isClipboardInvalid) ? Color.white.opacity(DesignTokens.Text.secondary) : (_isRetry ? DesignTokens.Accent.danger : (_isDuplicate ? Color.orange.opacity(0.8) : Color.white))
            pasteAnalyzeButton(
                label: _pasteLabel,
                icon: _pasteIcon,
                tint: _pasteTint,
                isRetry: _isRetry || _isClipboardInvalid,
                innerPillHeight: innerPillHeight
            )
        }
        .frame(height: fieldHeight)
        .background(
            // Same black-frosted-glass material as every card and the
            // sidebar (VisualEffectBlur + black tint + white wash + grain),
            // just clipped to a Capsule instead of GlassCard's
            // RoundedRectangle -- the field used to be a flat
            // Color.white.opacity(0.05) fill, a visibly different/lighter
            // material than the rest of the app's glass surfaces.
            ZStack {
                VisualEffectBlur(material: DesignTokens.Glass.material, blendingMode: .behindWindow)
                Color.black.opacity(isDragging ? DesignTokens.Glass.blackTintDisabled : DesignTokens.Glass.blackTint)
                Color.white.opacity(0.55 * DesignTokens.Glass.whiteWash)
                DitherNoise(opacity: 0.04)
            }
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(isDragging ? Color.white.opacity(DesignTokens.Text.secondary) : Color.white.opacity(DropGrid.fieldBorderOpacity), lineWidth: isDragging ? 1.5 : DropGrid.fieldBorderWidth)
            )
        )
        // Waiting-for-a-click cue lives on the OUTER bar capsule (field +
        // embedded button together) so the pulse ring traces the entire
        // pill's true perimeter instead of stopping short at the inner
        // text ZStack's bounds. Used to gate on the field being focused
        // (the "now paste" moment) -- there's no more focus to have now
        // that the field only ever displays, never accepts typing, so this
        // pulses instead for a few seconds right after a NEW link appears on
        // the clipboard (clipboardPulseActive) -- NOT for as long as one sits
        // there, which could be indefinitely and cost real compositor time the
        // whole time (see clipboardPulseActive's own comment).
        .overlay {
            if urlText.isEmpty, clipboardPulseActive {
                WaitingPulseGlow()
            }
        }
        // Same content column as everything beneath it (it used to be a
        // separate fixed 864pt cap, which left it narrower than the cards on
        // big windows and wider than them on small ones).
        .contentColumn()
        .onAppear { refreshClipboardPreview() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshClipboardPreview()
        }
        .onChange(of: urlText) {
            analyzeResult = nil
            duplicateURLDetected = false
            hasInvalidURLs = !allLinesAreURLs(urlText)
        }
    }

    // MARK: - Preview Card

    var previewCard: some View {
        ForEach($linkPreviews) { $preview in
            linkPreviewCard(preview: $preview)
                // While the window edge is dragged each card is replaced by a cheap
                // facade (see FreezeLayout) -- laying out the real cards on every frame
                // of a drag is what made resizing choppy.
                .frozenDuringResize()
                // Insert/remove only -- same-identity property updates
                // (analyze completing, instant-preview title/thumbnail
                // landing) never hit this transition since the id is
                // preserved across those updates. Scale-pop-in on spawn,
                // brought back by explicit request for these download/
                // analyze cards specifically. Removal is still instant.
                .transition(.glassPop)
        }
    }

    /// ONE card for a link's whole life -- analyzing, ready, downloading, finished, failed. The
    /// state only changes what is INSIDE it (see downloadCard); the card itself is never
    /// replaced by a different view.
    func linkPreviewCard(preview: Binding<LinkPreview>) -> some View {
        downloadCard(preview: preview)
    }

    // Shared by downloadPreviewCard and downloadCompletedCard, which used to
    // each carry an identical copy of this exact 80x52 thumbnail+skeleton
    // ZStack.
    private func thumbnailView(urlString: String) -> AnyView {
        AnyView(
            AsyncImage(url: URL(string: urlString)) { phase in
                ZStack {
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous)
                        .fill(Color.clear)
                        .overlay(ThumbnailSkeleton().clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous)))
                    if case .success(let img) = phase {
                        img.resizable()
                            .aspectRatio(contentMode: .fill)
                            .transition(.blurIn)
                    }
                }
                .frame(width: CardMetrics.thumbWidth, height: CardMetrics.thumbHeight)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous))
            }
            .animation(.easeOut(duration: 0.2), value: urlString)
        )
    }

    // MARK: Download — the card (one card for every state)

    /// The card for a link, whatever state it is in. Analyzing, ready (with its settings),
    /// downloading, finished and failed are all this one PreviewCard: what changes is what is
    /// inside it -- the metadata capsule's contents, the title bar, the status column, the
    /// buttons, the settings -- so a state change adjusts the card instead of swapping it for
    /// another. (A download's progress sits on the right, like a Convert queue row.)
    func downloadCard(preview: Binding<LinkPreview>) -> some View {
        let p = preview.wrappedValue
        let dl: Download? = p.downloadID.flatMap { id in manager.downloads.first(where: { $0.id == id }) }
        let failedAnalyze = p.analyzeError != nil
        let analyzing = p.isPending && dl == nil && !failedAnalyze
        let failureIcon = p.analyzeErrorIsForbidden ? "lock.slash" : "exclamationmark.triangle"

        // What the capsule holds in this state.
        let capsule: CardCapsule = {
            if let err = p.analyzeError { return .note(icon: failureIcon, text: err) }
            if let dl {
                if dl.status == .error, let message = dl.errorMessage, !message.isEmpty {
                    return .note(icon: "exclamationmark.triangle", text: message)
                }
                return .output(dl.outputChips)
            }
            if analyzing { return .analyzing }
            // Only what will be produced: the input side is Convert's business.
            // Same resolution effectiveReencodeCodec uses (see its own doc comment), so the
            // capsule's VIDEO chip matches what the RE-ENCODE dropdown actually shows as
            // selected -- including the MOV-can't-honor-.off fallback to H.264.
            return .output(p.outputChips(effectiveReencodeCodec: effectiveReencodeCodec(choice: p.reencodeCodec, default: config.reencodeCodec, videoFormat: p.videoFormat)))
        }()
        // The pasted link stands in for the title until a real one arrives.
        let titleKnown = !analyzing || (!p.title.isEmpty && p.title != p.url)
        let primaryControl: CardControl? = dl.flatMap { downloadControls($0, preview: p) }
            ?? (failedAnalyze ? CardControl(icon: "arrow.clockwise", color: DesignTokens.Accent.danger, help: "Retry") {
                retryAnalysis(of: p)
            } : nil)
        let cardLocked = isBatchMode || failedAnalyze || dl != nil
        // Only while a job is actually in flight -- once it's set, the card's remove button
        // becomes Cancel instead (see PreviewCard.onCancel), so onRemove below is never called
        // for a running download and doesn't need to cancel it first.
        let cancelDownload: (() -> Void)? = {
            guard let dl, dl.status == .pending || dl.status == .downloading else { return nil }
            return { manager.cancel(download: dl) }
        }()

        return PreviewCard(
            isSelected: p.isSelected,
            onToggleSelect: {
                withAnimation(.spring(response: 0.2)) { preview.isSelected.wrappedValue.toggle() }
            },
            onRemove: {
                withAnimation(.spring(response: 0.3)) { linkPreviews.removeAll { $0.id == p.id } }
            },
            showCheckbox: isBatchMode && !failedAnalyze,
            thumbnail: failedAnalyze ? nil : thumbnailView(urlString: p.thumbnailURL),
            thumbnailPlaceholder: failedAnalyze ? failureIcon : "doc",
            title: p.title,
            // The link and the path are only shown while the settings are (expanded).
            secondaryTitle: dl == nil ? p.url : "",
            belowHeader: dl.flatMap { downloadErrorDetails($0) } ?? (failedAnalyze ? analyzeErrorDetails() : nil),
            isExpanded: cardLocked ? .constant(false) : Binding(
                get: { preview.wrappedValue.isExpanded },
                set: { preview.isExpanded.wrappedValue = $0 }
            ),
            collapseLocked: cardLocked,
            isAnalyzing: analyzing,
            onCancelAnalyze: {
                // Matched by this card's own id, not its url -- pasting the
                // same link multiple times at once creates several pending
                // cards sharing one url string, and url-based lookup here
                // used to terminate/clear every one of them instead of just
                // the specific card the user clicked X on.
                // Kill yt-dlp's own child processes (any fallback/merge step)
                // before terminate() -- a plain terminate() only SIGTERMs the
                // yt-dlp process itself, which doesn't always stop promptly if
                // it's blocked mid-network-call, letting analyze finish in the
                // background after the card is already gone from the list.
                if let proc = analyzeProcesses[p.id] { DownloadManager.terminateProcessTree(proc) }
                analyzeProcesses.removeValue(forKey: p.id)
                // Marks this id as cancelled in case it's still waiting on
                // the concurrency gate (no Process exists yet to terminate
                // above) -- checked the moment its turn comes up so it bails
                // out before ever spawning yt-dlp.
                cancelledAnalyzeIDs.insert(p.id)
                withAnimation(.spring(response: 0.35)) {
                    linkPreviews.removeAll { $0.id == p.id }
                }
            },
            capsule: capsule,
            titleKnown: titleKnown,
            queuedStatus: (!analyzing && !failedAnalyze && (dl == nil || dl?.status == .pending)) ? queuedProgressColumn() : nil,
            inlineStatus: analyzing ? analyzeProgressColumn() : dl.flatMap { downloadProgressColumn($0) },
            statusLabel: dl.flatMap { downloadOutcomeLabel($0) },
            primaryControl: primaryControl,
            onCancel: cancelDownload,
            showsSettings: dl == nil && !failedAnalyze
        ) {
            // Same field layout as Convert's own analyze card (the 2026-09-26
            // redesign, see [[convert-analyze-lag]]): DOWNLOAD AS and FORMAT
            // share a top strip as full segmented capsules -- they decide
            // what's being produced at all -- and the many-option picker
            // (RESOLUTION for video, BITRATE for audio) becomes one compact
            // dropdown field in its own VIDEO/AUDIO track row below, instead
            // of a full row of chips.
            //
            // The Video-vs-Audio rows are structurally different content, so a
            // mode change swaps them via `.pageSwap` (outgoing blurs away
            // first, incoming focuses in a beat later -- that stagger is what
            // stops the two sets reading as overlapped). The ZStack keeps both
            // overlaid during the swap instead of stacking their heights, so
            // the card doesn't bounce. Picks within a mode aren't gated on
            // mediaMode and keep their own feedback.
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        FieldCaption(icon: "switch.2", text: "DOWNLOAD AS")
                            .frame(height: 15, alignment: .leading)
                            .reportsFacadeFieldShape(id: "download.downloadAs.caption.\(p.id)", kind: .text)
                        SegmentedCapsule(options: downloadModeOptions(preview: preview), fill: false, groupID: "downloadAs")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            FieldCaption(icon: p.mediaMode == .audioOnly ? "waveform" : "video", text: "OUTPUT FORMAT")
                                .reportsFacadeFieldShape(id: "download.outputFormat.caption.\(p.id)", kind: .text)
                            // Explains MOV's own amber dot (see sourceNeedsReencode) -- only
                            // shown when an AV1/VP9 source could actually trigger it, same as
                            // the dot itself, so an ordinary H.264/HEVC source (plain remux,
                            // no real re-encode either way) doesn't carry an irrelevant key.
                            if p.mediaMode != .audioOnly && sourceNeedsReencode(for: .mov, preview: p) {
                                Spacer(minLength: 10)
                                nativeLegend(positiveLabel: "Re-encode", tint: DesignTokens.Accent.warning)
                            }
                        }
                        .frame(height: 15, alignment: .leading)
                        SegmentedCapsule(options: p.mediaMode == .audioOnly
                            ? downloadAudioFormatOptions(preview: preview)
                            : downloadVideoFormatOptions(preview: preview), groupID: "outputFormat")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                ZStack(alignment: .top) {
                    Group {
                        if p.mediaMode != .audioOnly {
                            FieldsTrackRow(icon: "video", label: "VIDEO", captionID: "download.video.caption.\(p.id)") {
                                HStack(alignment: .bottom, spacing: 12) {
                                    // Suffixed with the card's own id: openDropdownID is one
                                    // value shared by every download card (see its declaration),
                                    // so two cards' otherwise-identical field ids would each
                                    // register as "open" together the instant either one opened,
                                    // since both would match the same shared string.
                                    DropdownField(id: "download.video.resolution.\(p.id)", caption: "RESOLUTION",
                                                  options: downloadVideoQualityOptions(preview: preview),
                                                  openID: $openDropdownID)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    // reencodeIfNeeded only ever runs for an AV1/VP9 source going
                                    // to MP4/MOV (see its own doc comment) -- for every other
                                    // format/source combination this choice has no effect at all,
                                    // since the container can already hold the source codec
                                    // natively. Always mounted (not swapped for a spacer) so the
                                    // field reads as "doesn't apply right now" rather than
                                    // vanishing -- greyed out and unclickable, same convention as
                                    // a disabled GlassButton -- and RESOLUTION's width never jumps
                                    // when the output format changes.
                                    DropdownField(id: "download.video.reencodeCodec.\(p.id)", caption: "RE-ENCODE",
                                                  options: needsReencodeChoice(preview: p) ? downloadReencodeCodecOptions(preview: preview) : [],
                                                  openID: $openDropdownID,
                                                  disabled: !needsReencodeChoice(preview: p))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        } else if p.audioFormat != .m4a {
                            // M4A has no selectable quality/bitrate -- it's a fixed passthrough
                            // format, so there's no real choice to present, and the row is
                            // hidden entirely (mirrors Convert's handling of a lossless codec
                            // hiding its own bitrate field).
                            FieldsTrackRow(icon: "waveform", label: "AUDIO", captionID: "download.audio.caption.\(p.id)") {
                                DropdownField(id: "download.audio.bitrate.\(p.id)", caption: "BITRATE",
                                              options: downloadAudioQualityOptions(preview: preview),
                                              openID: $openDropdownID)
                            }
                        }
                    }
                    .id(p.mediaMode)
                    .transition(.pageSwap)
                }
                // Scoped to BOTH: mediaMode swaps which row can appear at all (VIDEO vs
                // AUDIO), but the AUDIO row can also appear/disappear on its own within
                // audioOnly mode alone -- switching TO m4a (no bitrate to offer) or away
                // from it. That second case doesn't touch mediaMode, so scoping this to
                // mediaMode alone left it with no active animation at all: the row's
                // .transition(.pageSwap) exists but has nothing animating to apply it to,
                // so the card's height snapped shut instantly instead of easing shut
                // (reported live). A plain String, not a tuple: .animation(_:value:)
                // needs one Equatable value, and a raw tuple of two Equatable enums isn't
                // itself Equatable.
                .animation(.easeOut(duration: 0.2), value: "\(p.mediaMode.rawValue)|\(p.audioFormat.rawValue)")
            }
        }
    }

    // MARK: Download — segmented option builders
    //
    // Pulled out of downloadPreviewCard's view tree: building these inline made
    // the whole expression too complex for the type-checker.

    private func downloadModeOptions(preview: Binding<LinkPreview>) -> [SegmentOption] {
        let p = preview.wrappedValue
        var options: [SegmentOption] = []
        if p.hasVideo {
            options.append(SegmentOption(
                id: "videoAndAudio", label: "Video + Audio", icon: "video.badge.waveform",
                isSelected: p.mediaMode == .videoAndAudio, tint: DesignTokens.Accent.primary
            ) {
                withAnimation(.spring(response: 0.25)) { preview.mediaMode.wrappedValue = .videoAndAudio }
            })
        }
        options.append(SegmentOption(
            id: "audioOnly", label: "Audio Only", icon: "waveform",
            isSelected: p.mediaMode == .audioOnly, tint: DesignTokens.Accent.success
        ) {
            withAnimation(.spring(response: 0.25)) { preview.mediaMode.wrappedValue = .audioOnly }
        })
        return options
    }

    /// MOV's own warning dot (nativeBadge: false -> SegmentButton's amber branch):
    /// an AV1/VP9 source forces a REAL re-encode to land in a .mov -- same codec
    /// gate as needsReencodeChoice/reencodeIfNeeded, just evaluated per-format here
    /// instead of against whatever's currently selected, so the dot shows on MOV's
    /// own pill regardless of which format is picked right now.
    private func sourceNeedsReencode(for format: VideoFormat, preview p: LinkPreview) -> Bool {
        format == .mov && (p.sourceVideoCodec == "AV1" || p.sourceVideoCodec == "VP9")
    }

    private func downloadVideoFormatOptions(preview: Binding<LinkPreview>) -> [SegmentOption] {
        let p = preview.wrappedValue
        return VideoFormat.allCases.map { f in
            SegmentOption(
                id: f.rawValue, label: f.label,
                nativeBadge: sourceNeedsReencode(for: f, preview: p) ? false : nil,
                help: f.note,
                isSelected: p.videoFormat == f, tint: DesignTokens.Accent.primary
            ) {
                preview.videoFormat.wrappedValue = f
            }
        }
    }

    private func downloadVideoQualityOptions(preview: Binding<LinkPreview>) -> [SegmentOption] {
        let p = preview.wrappedValue
        // Tiers above what the source actually has are hidden (unknown height
        // keeps the old up-to-1080p default). A sub-480p source still shows
        // the 480p floor tier -- the output line reports the real resolution.
        let h = p.sourceMaxHeight
        // The highest tier the source actually supports -- what you'd get without
        // touching this field at all, same logic the filter below already uses for
        // its own upper bound. Marked isSourceDefault so the field reads as neutral
        // there and only tints (DropdownField's isChanged) once a LOWER tier is
        // chosen -- previously no option here was ever marked isSourceDefault, so
        // every possible selection counted as "changed" and the field was always
        // blue regardless of quality (reported live: "why are the fields blue").
        let defaultTier: VideoQuality = h == 0 ? .q1080 : .highest(for: h)
        return VideoQuality.allCases.filter { q in
            h == 0 ? q.maxHeight <= 1080 : q.maxHeight <= defaultTier.maxHeight
        }.map { q in
            SegmentOption(
                id: "\(q)", label: effectiveVideoResolutionLabel(q, sourceMaxHeight: p.sourceMaxHeight),
                isSelected: p.videoQuality == q, tint: DesignTokens.Accent.primary,
                subtext: resolutionMarketingName(forMaxHeight: q.maxHeight),
                isSourceDefault: q == defaultTier
            ) {
                preview.videoQuality.wrappedValue = q
            }
        }
    }

    /// True only when this card's own reencodeCodec choice can actually affect anything --
    /// reencodeIfNeeded (DownloadManager) only ever runs for an AV1/VP9 source going to MP4/MOV
    /// output (every other combination either doesn't need a re-encode at all, like a native MKV/
    /// WebM download, or already has a native H.264 stream). Gates whether the RE-ENCODE field
    /// shows at all, next to RESOLUTION -- see its own call site's doc comment.
    private func needsReencodeChoice(preview p: LinkPreview) -> Bool {
        (p.sourceVideoCodec == "AV1" || p.sourceVideoCodec == "VP9") && (p.videoFormat == .mp4 || p.videoFormat == .mov)
    }

    /// Resolves a card's reencode choice (its own override, or the remembered default) to what
    /// will ACTUALLY be used for the given output format -- `.off` can't be honored for `.mov`
    /// (reencodeIfNeeded falls back to H.264 there regardless; see its own doc comment), so
    /// anywhere a card needs to DISPLAY its effective choice has to mirror that same fallback,
    /// not just the real re-encode call itself. Without this, switching a card's own output
    /// format to MOV left `.off` as the resolved value, which `downloadReencodeCodecOptions`
    /// then couldn't match against any of its own options (it hides `.off` for MOV) -- the field
    /// showed a bare "—" instead of the H.264 that will actually run (reported live). Being a
    /// pure function of the CURRENT format rather than something written back into
    /// `preview.reencodeCodec`/`config.reencodeCodec` also means switching back to MP4 (where
    /// `.off` is valid again) naturally resolves back to `.off` on its own, with nothing to
    /// reset explicitly -- also reported live as the wanted behavior.
    private func effectiveReencodeCodec(choice: ReencodeCodec?, default fallback: ReencodeCodec, videoFormat: VideoFormat) -> ReencodeCodec {
        let resolved = choice ?? fallback
        return (resolved == .off && videoFormat == .mov) ? .h264 : resolved
    }

    private func downloadReencodeCodecOptions(preview: Binding<LinkPreview>) -> [SegmentOption] {
        let p = preview.wrappedValue
        // .off is hidden for MOV: it can't actually be honored there (see
        // effectiveReencodeCodec's own doc comment), so it shouldn't be offered as if it were.
        let effective = effectiveReencodeCodec(choice: p.reencodeCodec, default: config.reencodeCodec, videoFormat: p.videoFormat)
        return ReencodeCodec.allCases.filter { $0 != .off || p.videoFormat != .mov }.map { c in
            SegmentOption(
                id: c.rawValue, label: c.label, help: c.note,
                isSelected: effective == c, tint: DesignTokens.Accent.primary,
                // .off is the untouched/do-nothing choice, same role "Same as Source" plays
                // on every other field -- without this the field was always blue regardless
                // of selection, same bug as RESOLUTION's (see downloadVideoQualityOptions'
                // own comment; reported live together as "why are the fields blue").
                isSourceDefault: c == .off
            ) {
                preview.reencodeCodec.wrappedValue = c
                // Remembered as the default for the NEXT card that needs this choice.
                config.reencodeCodec = c
            }
        }
    }

    private func downloadAudioFormatOptions(preview: Binding<LinkPreview>) -> [SegmentOption] {
        let p = preview.wrappedValue
        return AudioFormat.allCases.map { f in
            SegmentOption(
                id: f.rawValue, label: f.label, help: f.note,
                isSelected: p.audioFormat == f, tint: DesignTokens.Accent.success
            ) {
                preview.qualityByFormat.wrappedValue[p.audioFormat.rawValue] = p.audioQuality
                preview.audioFormat.wrappedValue = f
                let saved = preview.qualityByFormat.wrappedValue[f.rawValue] ?? .q320
                preview.audioQuality.wrappedValue = saved
            }
        }
    }

    private func downloadAudioQualityOptions(preview: Binding<LinkPreview>) -> [SegmentOption] {
        let p = preview.wrappedValue
        // Auto only makes sense for the kbps ladder (MP3/WAV re-encodes) when the source's real
        // bitrate is actually known -- FLAC uses its own sample-rate ladder instead (a bitrate
        // number doesn't mean anything for a lossless target), and with no detected sourceABR
        // there's nothing for Auto to represent, so the plain fixed presets are shown as before.
        let showsAuto = p.audioFormat != .flac && p.sourceABR > 0
        return AudioQuality.allCases.compactMap { q -> SegmentOption? in
            if q == .auto {
                guard showsAuto else { return nil }
                return SegmentOption(
                    id: "auto", label: "\(p.sourceABR)kbps",
                    isSelected: p.audioQuality == .auto, tint: DesignTokens.Accent.success,
                    isSourceDefault: true
                ) {
                    preview.audioQuality.wrappedValue = .auto
                }
            }
            let kbps: Int = {
                switch q {
                case .auto: return 0  // unreachable -- handled above
                case .q320: return 320
                case .q256: return 256
                case .q128: return 128
                }
            }()
            let asrHz: Int = {
                switch q {
                case .auto: return 0  // unreachable -- handled above
                case .q320: return 0
                case .q256: return 96000
                case .q128: return 44100
                }
            }()
            // Above the source's own bitrate/sample rate, a preset would just be padding a
            // lossy source up to a bigger number with no real detail gained -- Auto (above)
            // already covers "give me everything the source has," so these stay hidden.
            let hideKbps = p.audioFormat != .flac && p.sourceABR > 0 && kbps > p.sourceABR
            let effectiveASR: Int = {
                if p.sourceASR > 0 { return p.sourceASR }
                if p.sourceABR > 0 { return p.sourceABR >= 320 ? 96000 : 48000 }
                return 48000
            }()
            let hideFLAC = p.audioFormat == .flac && asrHz > 0 && asrHz > effectiveASR
            if hideKbps || hideFLAC { return nil }
            return SegmentOption(
                id: "\(q)", label: p.audioFormat == .flac ? q.flacLabel : q.label,
                isSelected: p.audioQuality == q, tint: DesignTokens.Accent.success
            ) {
                preview.audioQuality.wrappedValue = q
            }
        }
    }

    // MARK: Download — what the one card shows once a download exists

    /// Shared shape for the header's progress-indicator slot, used by every state a card moves
    /// through (Analyzing, Queued, Downloading, Done, Failed, Cancelled). Built from three parts:
    /// a status (an icon + label -- every state has exactly one), a progress bar, and a
    /// percentage beside that bar -- only Downloading turns the last two on, since it's the only
    /// state with real progress to report. One shared builder instead of each state hand-rolling
    /// its own layout, so they can never quietly drift apart (reported live: the progress
    /// indicator should be "made up of 3 elements, the status, progress bar, and percentage").
    /// The percentage sits beside the BAR, not beside the label -- putting all three on the
    /// label's own row left it competing with icon + percentage for the same narrow
    /// CardMetrics.statusCardContentWidth, truncating status text that used to fit (reported live: "i dont
    /// like that status text is getting cut off and it has to be shortened"). The status row is
    /// left-aligned within the box (reported live: "the label text should be left aligned") --
    /// trailing alignment made the icon itself jump left/right as the label's own length changed
    /// from state to state; anchoring to the left instead keeps the icon in one fixed spot and
    /// only the label's trailing edge moves.
    private func progressIndicator(icon: String, label: String, color: Color, iconColor: Color? = nil,
                                    percentage: String? = nil, bar: AnyView? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: icon).foregroundColor(iconColor ?? color).accessibilityHidden(true)
                Text(label).foregroundColor(color).lineLimit(1)
            }
            .font(.appMono(size: 10, weight: .semibold))
            if let bar {
                HStack(spacing: 6) {
                    bar
                    if let percentage {
                        Text(percentage)
                            .font(.appMono(size: 10, weight: .semibold))
                            .foregroundColor(color)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
        }
    }

    /// The header's progress-indicator slot while a card is still being analyzed -- status only
    /// (see progressIndicator), same position as every other state so Analyzing reads as the
    /// first step of one continuous progression (Analyzing -> Queued -> Downloading -> Done)
    /// instead of a message that lived somewhere else entirely (the IN/OUT metadata capsule,
    /// which now stays blank until real metadata exists -- see PersistentCapsule).
    private func analyzeProgressColumn() -> AnyView {
        AnyView(
            progressIndicator(icon: "hourglass", label: "Analyzing", color: .white,
                               iconColor: .white.opacity(DesignTokens.Text.secondary))
        )
    }

    /// The progress column on the right of a downloading card: status, a percentage beside it,
    /// and a slim bar below -- the only state that turns on all three parts (see
    /// progressIndicator), since it's the only one with real progress to report. Only while the
    /// download is actually in flight; a still-`.pending` download shows queuedProgressColumn
    /// instead (see its own doc comment), and what a download ends as is its own label
    /// (downloadOutcomeLabel), not this column changing shape. The status label is whatever's
    /// actually happening (speed, or a real ETA once known, or "Downloading" before either is) --
    /// the percentage is always its own element, never folded into that text.
    private func downloadProgressColumn(_ dl: Download) -> AnyView? {
        guard dl.status == .downloading else { return nil }
        let label = dl.etaText.isEmpty ? (dl.activityText.isEmpty ? "Downloading" : dl.activityText) : dl.etaText
        // Same threshold as downloadProgressBar's own switch from shimmer to a real fill --
        // progress starts at a bare 0 the instant a download begins (not nil), so matching on
        // non-nil alone showed a premature, meaningless "0%" before any real data arrived.
        let percentage = dl.progress.flatMap { $0 > 0 ? "\(Int(($0 * 100).rounded()))%" : nil }
        return AnyView(
            progressIndicator(icon: "arrow.down.circle", label: label, color: .white,
                               iconColor: .white.opacity(DesignTokens.Text.secondary),
                               percentage: percentage,
                               bar: AnyView(downloadProgressBar(dl).frame(maxWidth: .infinity)))
        )
    }

    /// A download not yet transferring -- status only (see progressIndicator), same reasoning as
    /// every non-Downloading state: there's nothing yet to measure progress against. Sits to the
    /// LEFT, right after the title, instead of sharing downloadProgressColumn's spot beside the
    /// buttons, and moves into that box the instant a real download starts (reported live: "move
    /// it over to the left and have it say queued, and then move it back when it starts
    /// downloading"). Shown for BOTH "analyzed and ready, nothing submitted yet" and "submitted
    /// but waiting behind another download" (downloads run one at a time, see
    /// DownloadManager.maxConcurrentDownloads) -- from the user's own perspective these read as
    /// the same thing (reported live: "ready and queued should be the same state... the queued
    /// indicator should be during the ready state").
    private func queuedProgressColumn() -> AnyView {
        AnyView(progressIndicator(icon: "clock", label: "Queued", color: .white.opacity(DesignTokens.Text.tertiary)))
    }

    /// How a download ended (Done, Failed, Cancelled) -- status only (see progressIndicator), a
    /// plain label to the left of the buttons.
    private func downloadOutcomeLabel(_ dl: Download) -> AnyView? {
        let icon: String, label: String, color: Color
        switch dl.status {
        case .done:      (icon, label, color) = ("checkmark.circle.fill", "Done", .green)
        case .error:     (icon, label, color) = ("xmark.circle.fill", "Failed", .red)
        case .cancelled: (icon, label, color) = ("slash.circle.fill", "Cancelled", .orange)
        case .pending, .downloading: return nil
        }
        return AnyView(progressIndicator(icon: icon, label: label, color: color))
    }

    /// Filled and animated once a percentage is known, a shimmer before that (only while it is
    /// actually transferring -- a still-`.pending` download has no bar at all, see
    /// queuedProgressColumn).
    private func downloadProgressBar(_ dl: Download) -> some View {
        fractionProgressBar(dl.progress ?? 0)
    }

    /// Shared by any slim green progress bar keyed to a plain 0...1 fraction
    /// (a download card's own percentage, or the tools-setup card below) --
    /// shimmers in place of a fill until there's real progress to show.
    private func fractionProgressBar(_ fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(DesignTokens.Interactive.fillRest)).frame(height: 4)
                if fraction > 0 {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(colors: [Color.green.opacity(0.6), Color.green.opacity(1.0)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * CGFloat(fraction), height: 4)
                        .shadow(color: Color.green.opacity(0.6), radius: 4)
                        .animation(.easeOut(duration: 0.25), value: fraction)
                } else {
                    ShimmerBar(width: geo.size.width, color: .green, glow: true, duration: 1.2)
                }
            }
        }
        .frame(height: 4)
    }

    /// A download's controls, in the slots of the header's button row: the PRIMARY one takes the
    /// collapse button's place once the job has ended (Redownload / Retry), and Reveal in
    /// Finder appears to its left once the file is there. While a job is still in flight,
    /// neither slot is used -- Cancel lives in the card's own remove/cancel button instead (see
    /// downloadCard's onCancel).
    /// Redownload/Retry only -- Reveal in Finder used to be the card's own secondary button too,
    /// but that's redundant with the bottom bar's own Reveal (which opens the destination folder
    /// already), so it's gone from here; the bottom bar is the one place it lives now.
    private func downloadControls(_ dl: Download, preview p: LinkPreview) -> CardControl? {
        switch dl.status {
        case .pending, .downloading:
            return nil
        case .done, .cancelled:
            return CardControl(icon: "arrow.uturn.down", color: DesignTokens.Accent.warning, help: "Redownload") {
                restorePreviewCard(from: dl, replacing: p.id)
            }
        case .error:
            return CardControl(icon: "arrow.uturn.down", color: DesignTokens.Accent.danger, help: "Retry") {
                restorePreviewCard(from: dl, replacing: p.id)
            }
        }
    }

    /// Puts a failed card back to Analyzing and runs the same analysis again, in place (same id,
    /// so the card updates instead of being replaced).
    private func retryAnalysis(of p: LinkPreview) {
        guard let idx = linkPreviews.firstIndex(where: { $0.id == p.id }) else { return }
        withAnimation(.spring(response: 0.35)) {
            linkPreviews[idx].analyzeError = nil
            linkPreviews[idx].analyzeErrorIsForbidden = false
            linkPreviews[idx].title = p.url
            linkPreviews[idx].isPending = true
        }
        analyzeURL(urls: [p.url], ids: [p.id])
    }

    /// A failed analysis's way to the real reason: the capsule only has the short summary, the
    /// log has yt-dlp's own error line.
    private func analyzeErrorDetails() -> AnyView {
        AnyView(
            Button(action: {
                withAnimation(.spring(response: 0.25)) { activeTab = .log }
            }) {
                HStack(spacing: 5) {
                    Image(systemName: "terminal").font(.appMono(size: 10, weight: .semibold))
                    Text("Show in Log").font(.appMono(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.orange.opacity(0.4), lineWidth: 0.75)))
                .foregroundColor(.orange)
            }
            .buttonStyle(.plain)
            .help("Show in Log")
            .frame(maxWidth: .infinity, alignment: .leading)
        )
    }

    /// A failed download's hint and its fix button, below the header (the reason itself is in
    /// the capsule).
    private func downloadErrorDetails(_ dl: Download) -> AnyView? {
        guard dl.status == .error, dl.fixHint != nil || dl.fixAction != .none else { return nil }
        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                if let hint = dl.fixHint {
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "lightbulb.fill").font(.appMono(size: 10)).foregroundColor(.yellow.opacity(0.8))
                        Text(hint).font(.appMono(size: 11)).foregroundColor(.orange.opacity(0.85))
                    }
                }
                if dl.fixAction != .none {
                    Button(action: {
                        manager.performFix(for: dl, config: config) {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false; panel.canChooseDirectories = true
                            panel.canCreateDirectories = true
                            panel.allowsMultipleSelection = false; panel.prompt = "Select Folder"
                            // .begin (async), not .runModal() (blocking) -- see
                            // FolderActionButtons' identical fix for why.
                            panel.begin { response in
                                if response == .OK, let url = panel.url {
                                    config.outputDir = url.path
                                }
                            }
                        }
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: fixActionIcon(dl.fixAction)).font(.appMono(size: 10, weight: .semibold))
                            Text(fixActionLabel(dl.fixAction)).font(.appMono(size: 11, weight: .semibold))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.18))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.orange.opacity(0.4), lineWidth: 0.75)))
                        .foregroundColor(.orange)
                    }.buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        )
    }

    func fixActionLabel(_ action: FixAction) -> String {
        switch action {
        case .setCookieNone:       return "Set Cookie Source to None"
        case .openFolderPicker:    return "Choose Folder"
        case .openPrivacySecurity: return "Open Privacy & Security"
        case .openURL:             return "Search on YouTube"
        case .none:                return ""
        }
    }
    func fixActionIcon(_ action: FixAction) -> String {
        switch action {
        case .setCookieNone:       return "cookie"
        case .openFolderPicker:    return "folder.badge.plus"
        case .openPrivacySecurity: return "shield.fill"
        case .openURL:             return "magnifyingglass"
        case .none:                return ""
        }
    }
    func allLinesAreURLs(_ text: String) -> Bool {
        dropAllLinesAreURLs(text)
    }

    struct LinkPreview: Identifiable {
        // var, not let: the analyze-complete path below reassigns this to
        // the pending placeholder's original id so SwiftUI keeps treating
        // it as the *same* card (a smooth cross-fade) instead of tearing
        // down the old view and mounting a brand new one (which read as a
        // hard "replace" flash -- light grey glass materializing then
        // deepening to the real black tint -- because a fresh view has to
        // build up its VisualEffectBlur/tint layers from scratch).
        var id = UUID()
        let url: String
        // Mutable: patched in-place by the instant-preview fetch while the
        // card is still `isPending`, then overwritten again once the real
        // yt-dlp analyze result lands.
        var title: String
        var thumbnailURL: String
        let hasVideo: Bool
        let duration: String
        var durationSeconds: Int = 0      // for size estimation
        var fileSizeBytes: Int? = nil     // filesize_approx from yt-dlp (best available format)
        var sourceMaxHeight: Int = 0      // tier height of the source (0 = unknown); widened for ultrawide, see analyze
        var sourceWidthPx: Int = 0        // real pixel size of the best video format (0 = unknown)
        var sourceHeightPx: Int = 0
        var sourceASR: Int = 0              // audio sample rate in Hz (0 = unknown)
        var sourceABR: Int = 0              // audio bitrate in kbps (0 = unknown)
        var sourceContainer: String? = nil   // e.g. "WEBM", "MP4", "M4A": the container the source stream is hosted in
        var sourceVideoCodec: String? = nil  // e.g. "AV1", "H264" (nil = unknown/audio-only)
        var sourceAudioCodec: String? = nil  // e.g. "OPUS", "AAC"
        var sourceChannelLabel: String? = nil // e.g. "2.0", "5.1"
        // Per-link download options
        var mediaMode: MediaMode
        var videoQuality: VideoQuality = VideoQuality.allCases.first!  // set to highest(for: sourceMaxHeight) after analyze
        var videoFormat: VideoFormat   = VideoFormat.allCases.first!
        // nil until the user explicitly picks a value on THIS card -- falls back to
        // config.reencodeCodec (the last value picked on any card, persisted; "Off" if the user
        // has never picked one at all) everywhere this is read, rather than defaulting every
        // fresh card back to a fixed value and losing the user's last choice. Only has any effect
        // when sourceVideoCodec needs reencodeIfNeeded to run at all (AV1/VP9 source + MP4/MOV
        // output) -- see the field's own selector, shown only in that case.
        var reencodeCodec: ReencodeCodec? = nil
        var audioFormat: AudioFormat   = AudioFormat.allCases.first!   // M4A — native, no re-encode
        var audioQuality: AudioQuality = .q320  // quality for current format
        // Per-format quality memory
        var qualityByFormat: [String: AudioQuality] = [
            "mp3": .q320, "m4a": .q320, "wav": .q320, "flac": .q320
        ]
        // Queue selection
        var isSelected: Bool = true
        // Settings-section collapse state — mirrors Convert's job.isExpanded.
        // Transient UI state, never persisted. Defaults collapsed: the
        // mode chip (Video+Audio / Audio Only) and the resulting output
        // format chips are always visible in the header regardless of
        // this flag -- expanding only reveals the deeper per-format/
        // quality picker rows (VIDEO FORMAT/RESOLUTION or AUDIO FORMAT/
        // QUALITY), the "advanced" layer on top of the "simple" default.
        var isExpanded: Bool = false
        // Tracks the active Download.id once dispatched
        var downloadID: UUID? = nil
        // True when re-queued from history (bypasses duplicate check)
        var fromHistory: Bool = false
        var isPending: Bool = false   // true while analyze is in-flight
        // Set when analyze itself fails (not the later download step). A
        // persistent 403 here means the SOURCE is blocking access outright
        // (bot detection, geo/auth-gated, etc.) -- unlike a download-time
        // 403, which is usually just a stale signed CDN URL and gets
        // auto-retried. There's nothing to retry at analyze time since
        // yt-dlp couldn't even read the page, so this is surfaced directly
        // instead of silently dropping the card.
        var analyzeError: String? = nil
        var analyzeErrorIsForbidden: Bool = false  // true specifically for HTTP 403 at analyze time
        var isPlaylist: Bool = false      // true if URL is a playlist
        var playlistCount: Int = 0        // number of items in playlist
        // Exact combined (video+audio) byte sizes per resolution cap — populated during analyze
        var fileSizeByQuality: [Int: Int] = [:]  // [heightCap: bytes]

        // Input row — describes the SOURCE itself, never the currently
        // selected download mode/format. Blue video chip shows whenever
        // the source actually has a video track (hasVideo), independent
        // of mediaMode -- switching to Audio Only must never make this
        // row look like the source lost its video track, it only changes
        // what's being extracted from it. Mirrors Download.inputChips'
        // same source-of-truth split.
        var inputChips: [ChipData] {
            var result: [ChipData] = []
            let playlistSize = isPlaylist ? "\(playlistCount) tracks" : nil
            let size = playlistSize ?? sourceSizeLabel(hasVideo: hasVideo, sourceMaxHeight: sourceMaxHeight,
                                                        fileSizeByQuality: fileSizeByQuality, fileSizeBytes: fileSizeBytes)
            if let length = ChipData.lengthAndSize(length: lengthChipValue(seconds: durationSeconds, raw: duration), size: size) {
                result.append(length)
            }
            // Blue: source video info (codec + resolution) — gated on hasVideo
            // (the source's actual capability), NOT mediaMode (the user's
            // current output choice).
            if hasVideo {
                result.append(.video([sourceContainer, sourceVideoCodec, fullResolutionLabel(width: sourceWidthPx, height: sourceHeightPx, tierHeight: sourceMaxHeight)]) ?? .videoPlaceholder)
            }
            // Green: source audio info (codec + channels + bitrate); an audio-only source carries
            // its container here, since it has no video chip to.
            if let audio = ChipData.audio([hasVideo ? nil : sourceContainer, sourceAudioCodec, sourceChannelLabel, bitrateLabel(kbps: sourceABR)]) {
                result.append(audio)
            } else if !hasVideo {
                result.append(.audioPlaceholder)
            }
            return result
        }

        // Output row — reflects the CURRENTLY SELECTED mediaMode/format/
        // quality, i.e. what will actually be produced. This is the only
        // row that changes when the Video+Audio / Audio Only chip is
        // toggled -- mirrors Download.outputChips exactly so the pre-
        // download card and the active/completed card read identically.
        // `effectiveReencodeCodec` is this card's own choice (reencodeCodec,
        // when set) or the remembered default (config.reencodeCodec) --
        // LinkPreview itself has no visibility into Config, so the caller
        // resolves it the same way downloadReencodeCodecOptions does and
        // passes it in (nil is fine when it doesn't matter, e.g. audioOnly).
        func outputChips(effectiveReencodeCodec: ReencodeCodec?) -> [ChipData] {
            var result: [ChipData] = []
            if let length = ChipData.lengthAndSize(length: lengthChipValue(seconds: durationSeconds, raw: duration), size: estimatedSizeString(), reservesEstimateMark: true) {
                result.append(length)
            }
            switch mediaMode {
            case .audioOnly:
                // M4A is native passthrough (no re-encode -- see audioFormat's own doc
                // comment), so its real bitrate is the source's own rather than one of the
                // quality presets. Auto means the same thing for a re-encoded format --
                // "match the source exactly" -- so it shows that real number too. FLAC
                // repurposes the same enum cases for a sample-rate tier instead of a
                // bitrate (see AudioQuality.flacLabel) -- mirrors Download.outputChips.
                let bitrate: String?
                if audioFormat == .flac {
                    bitrate = audioQuality.flacLabel
                } else if audioFormat == .m4a || audioQuality == .auto {
                    bitrate = bitrateLabel(kbps: sourceABR)
                } else {
                    bitrate = audioQuality.label
                }
                result.append(.audio([audioFormat.rawValue.uppercased(), sourceChannelLabel, bitrate]) ?? .audioPlaceholder)
            case .videoAndAudio:
                // Audio is always stream-copied, so it still reuses the source's own info. Video
                // usually is too -- EXCEPT the one case reencodeIfNeeded actually runs (an AV1/
                // VP9 source going to MP4/MOV, and the resolved choice isn't .off), where the
                // real output codec is that choice, not the source's. This chip used to always
                // show the source codec regardless of the re-encode selector (reported live).
                let needsReencode = (sourceVideoCodec == "AV1" || sourceVideoCodec == "VP9")
                    && (videoFormat == .mp4 || videoFormat == .mov) && effectiveReencodeCodec != .off
                let displayedVideoCodec = needsReencode ? effectiveReencodeCodec?.label : sourceVideoCodec
                result.append(.video([videoFormat.rawValue.uppercased(), displayedVideoCodec,
                                      outputResolutionLabel(videoQuality, width: sourceWidthPx, height: sourceHeightPx, tierHeight: sourceMaxHeight)
                                        ?? effectiveVideoResolutionLabel(videoQuality, sourceMaxHeight: sourceMaxHeight)]) ?? .videoPlaceholder)
                result.append(.audio([sourceAudioCodec, sourceChannelLabel, bitrateLabel(kbps: sourceABR)]) ?? .audioPlaceholder)
            }
            return result
        }

        // Estimated size string based on current options
        // Formatted, "~"-prefixed version of estimatedBytes(), for the
        // per-card size label.
        func estimatedSizeString() -> String? {
            guard let bytes = estimatedBytes() else { return nil }
            return "~" + formatByteSize(bytes)
        }

        // Raw byte version, used both by estimatedSizeString() above and to
        // sum totals across multiple queued previews for the SAVE TO
        // section's total-size chip.
        func estimatedBytes() -> Int? {
            guard downloadID == nil else { return nil }
            let secs = durationSeconds
            if mediaMode == .audioOnly && secs > 0 {
                // Auto has no fixed kbps of its own -- use the real detected source bitrate
                // it represents instead of the generic (and usually wrong) fallback.
                let kbps = audioQuality == .auto && sourceABR > 0 ? sourceABR : audioQuality.kbps
                return (kbps * 1000 / 8) * secs
            } else if mediaMode == .videoAndAudio {
                let cap = videoQuality.maxHeight
                if let exact = fileSizeByQuality[cap], exact > 0 {
                    return exact
                }
                if let b = fileSizeBytes, b > 0 {
                    let scale: Double
                    let is4KSource = sourceMaxHeight >= 2160
                    switch videoQuality {
                    case .q4k:   scale = 1.0
                    case .q1440: scale = is4KSource ? 0.50 : 1.0
                    case .q1080: scale = is4KSource ? 0.25 : 0.85
                    case .q720:  scale = is4KSource ? 0.15 : 0.55
                    case .q480:  scale = is4KSource ? 0.08 : 0.30
                    }
                    let adj = Int(Double(b) * scale)
                    let audioBytes = secs > 0 ? (192000 / 8) * secs : 0
                    return adj + audioBytes
                }
            }
            return nil
        }
    }

    @State private var analyzeResult: AnalyzeResult? = nil
    @State private var linkPreviews: [LinkPreview] = []
    // Which settings dropdown field (RESOLUTION / BITRATE) has its popover open, if any --
    // ONE value shared by every download card on the page (not per-card), so opening a
    // dropdown on one card closes whatever was open on another. Lives here rather than on
    // LinkPreview itself specifically so every downloadCard() call -- one per row, but all
    // methods on this same ContentView -- reads and writes the identical piece of state.
    @State private var openDropdownID: String? = nil

    // Sum of estimated sizes across all selected, not-yet-downloaded previews —
    // shown as a chip next to SAVE TO, mirroring Convert's estimated-size chip.
    var totalEstimatedSizeLabel: String? {
        let bytes = selectedPreviews
            .filter { $0.downloadID == nil }
            .compactMap { $0.estimatedBytes() }
            .reduce(0, +)
        guard bytes > 0 else { return nil }
        return "~" + formatByteSize(bytes)
    }

    // Instant preview for pending cards, mirroring how TBD makes a pasted
    // link feel immediate: yt-dlp is a PyInstaller binary that unpacks all
    // of Python on every launch, so even the fastest analyze call takes a
    // visible second or more. YouTube's public oEmbed endpoint is a tiny
    // JSON response that answers in a few hundred milliseconds, and the
    // thumbnail doesn't need a network call at all -- it's deterministic
    // from the video ID. This runs in parallel with the real yt-dlp
    // analyze already in flight and only ever patches a card that's still
    // `isPending` and doesn't have a title yet, so it can never clobber a
    // faster-arriving real result and never fights the eventual PreviewCard.
    /// Called from the analyze background thread right after a Process starts.
    /// Returns false (after killing it) if the card was cancelled while the
    /// process was still launching.
    private func registerAnalyzeProcess(_ proc: Process, cardID: UUID) -> Bool {
        var cancelled = false
        DispatchQueue.main.sync {
            if self.cancelledAnalyzeIDs.contains(cardID) { cancelled = true }
            else { self.analyzeProcesses[cardID] = proc }
        }
        if cancelled {
            DownloadManager.terminateProcessTree(proc)
            proc.waitUntilExit()
        }
        return !cancelled
    }

    /// Caps how long a single yt-dlp analyze attempt can leave a card sitting on "Analyzing"
    /// with nothing else happening. Neither analyze Process below had any timeout at all --
    /// `waitUntilExit()` just blocks forever -- so a stalled network request (one that never
    /// cleanly fails, just never answers) left the card wedged indefinitely with no error and
    /// nothing in the Log tab. Reported by another user via two exported logs: one card stuck
    /// on "Analyzing 1 URL(s)..." as the very last line, no further log entry ever, no way to
    /// tell it apart from the app having silently died. 45s is generous for yt-dlp's own
    /// PyInstaller startup plus a real network fetch, short enough that a genuinely stuck card
    /// recovers inside one visible wait instead of needing a force-quit.
    private static let analyzeTimeoutSeconds: Double = 45

    /// Starts a watchdog that kills `proc` if it's still running after `analyzeTimeoutSeconds`.
    /// Cancel the returned work item the moment `proc.waitUntilExit()` returns on its own, then
    /// call `didTimeOut()` to tell a genuine timeout apart from every other way an analyze
    /// attempt can end empty-handed (a clean yt-dlp failure, a 403, cancellation) -- those all
    /// reach the same "waitUntilExit returned" point, so only this flag says *why*.
    private func startAnalyzeTimeoutWatchdog(for proc: Process) -> (workItem: DispatchWorkItem, didTimeOut: () -> Bool) {
        let flagLock = NSLock()
        var timedOut = false
        let workItem = DispatchWorkItem {
            if proc.isRunning {
                flagLock.lock(); timedOut = true; flagLock.unlock()
                DownloadManager.terminateProcessTree(proc)
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.analyzeTimeoutSeconds, execute: workItem)
        return (workItem, { flagLock.lock(); defer { flagLock.unlock() }; return timedOut })
    }

    private func fetchInstantPreview(for url: String, cardID: UUID) {
        guard let videoID = Self.youTubeVideoID(from: url) else { return }
        let thumbnailURL = "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg"
        // Show the deterministic thumbnail immediately -- no network wait needed.
        // Matched by the placeholder's own id, not url, so duplicate-url
        // pastes each patch their own card instead of all racing to patch
        // whichever same-url card happens to be first in the array.
        DispatchQueue.main.async {
            if let idx = self.linkPreviews.firstIndex(where: { $0.id == cardID }) {
                self.linkPreviews[idx].thumbnailURL = thumbnailURL
            }
        }
        guard let oembedURL = URL(string: "https://www.youtube.com/oembed?url=\(url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url)&format=json") else { return }
        URLSession.shared.dataTask(with: oembedURL) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = json["title"] as? String, !title.isEmpty else { return }
            DispatchQueue.main.async {
                if let idx = self.linkPreviews.firstIndex(where: { $0.id == cardID }) {
                    self.linkPreviews[idx].title = title
                }
            }
        }.resume()
    }

    // Accepts youtube.com/watch?v=, youtu.be/, youtube.com/shorts/, and
    // youtube.com/embed/ forms -- the same variety of link shapes users
    // actually paste.
    private static func youTubeVideoID(from url: String) -> String? {
        guard let comps = URLComponents(string: url),
              let host = comps.host?.lowercased(),
              host.contains("youtube.com") || host.contains("youtu.be") else { return nil }
        if host.contains("youtu.be") {
            let id = comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return id.isEmpty ? nil : id
        }
        if let v = comps.queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty {
            return v
        }
        for prefix in ["/shorts/", "/embed/", "/live/"] {
            if comps.path.hasPrefix(prefix) {
                let id = String(comps.path.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return id.isEmpty ? nil : id
            }
        }
        return nil
    }

    // `ids` lets each entry point associate the freshly-created pending
    // placeholder's own unique UUID with its url, so duplicate-url pastes
    // stay independent all the way through analyze/cancel/complete instead
    // of colliding on the shared url string. Optional and defaults to
    // freshly-generated UUIDs for any caller that hasn't been updated to
    // pass real placeholder ids (keeps this source-compatible), though
    // every current call site now passes the real ids.
    func analyzeURL(urls urlsOverride: [String]? = nil, ids idsOverride: [UUID]? = nil) {
        let urls: [String]
        if let override = urlsOverride {
            urls = override
        } else {
            urls = urlText.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        guard !urls.isEmpty, let ytdlp = manager.ytdlpPath else {
            manager.appendLog("Analyze: yt-dlp not found")
            return
        }
        // ids MUST line up 1:1 with urls by index -- if a caller passes a
        // mismatched count, fall back to fresh UUIDs rather than risk
        // silently pairing the wrong id with the wrong url.
        let ids: [UUID] = (idsOverride?.count == urls.count) ? idsOverride! : urls.map { _ in UUID() }
        isAnalyzing = true
        analyzeResult = nil
        manager.appendLog("Analyzing \(urls.count) URL(s)...")

        let group = DispatchGroup()
        // Use a lock-protected array to collect results in order
        var results: [(Int, LinkPreview?)] = []
        let lock = NSLock()

        // Cap how many yt-dlp analyze processes run at once. Previously every
        // pasted URL fired its own yt-dlp process onto DispatchQueue.global()
        // simultaneously with no limit -- fine for 1-2 links, but pasting a
        // large batch (e.g. 8x the same link) meant 8 concurrent yt-dlp/network
        // calls competing for the same CPU cores and, for duplicate URLs, the
        // same remote endpoint -- which both slowed the batch down overall and
        // made them tend to finish in one simultaneous cluster rather than a
        // steady trickle. A small counting gate lets at most `maxConcurrentAnalyze`
        // run their actual process-spawning work at a time; the rest wait on
        // this same global queue and pick up as slots free -- no change to the
        // per-URL completion/UI logic below, which already applies each result
        // the instant it lands.
        let maxConcurrentAnalyze = 3
        let analyzeGateSemaphore = DispatchSemaphore(value: maxConcurrentAnalyze)

        for (i, url) in urls.enumerated() {
            let cardID = ids[i]
            // Fires independently of the yt-dlp call below and doesn't
            // participate in `group`/`results` at all -- it only ever
            // patches the still-pending card's title/thumbnail so the UI
            // stops looking frozen on a bare URL while yt-dlp spins up.
            // The real analyze result below always wins once it lands.
            // Runs immediately for every card regardless of the concurrency
            // gate below -- it's a cheap oEmbed fetch, not a yt-dlp process,
            // so there's no reason to queue it.
            fetchInstantPreview(for: url, cardID: cardID)
            group.enter()
            DispatchQueue.global().async {
                // Block this queued work item (not the main thread) until a
                // concurrency slot is free -- same pattern as the errSem/
                // errSem2 semaphores just below, which already block a
                // background-queue thread safely within this same function.
                analyzeGateSemaphore.wait()
                defer { analyzeGateSemaphore.signal() }
                // If this card was cancelled while it was still waiting for a
                // concurrency slot, there's no yt-dlp process to spawn at all --
                // just clean up and bail before doing any work. Checked on the
                // main queue since cancelledAnalyzeIDs is @State.
                var wasCancelledWhileQueued = false
                DispatchQueue.main.sync {
                    if self.cancelledAnalyzeIDs.remove(cardID) != nil { wasCancelledWhileQueued = true }
                }
                if wasCancelledWhileQueued { group.leave(); return }
                // Single yt-dlp call: detect playlist + extract metadata in one pass.
                // %(playlist_count)s is NA for single videos, an integer for playlists.
                // --yes-playlist so yt-dlp doesn't refuse to print playlist_count.
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: ytdlp)
                // Cache the full extracted info dict alongside the existing --print
                // calls so a same-session Download can skip yt-dlp's full webpage +
                // player-API + m3u8 resolution the second time (~9-10s measured on
                // YouTube) via --load-info-json. This adds zero extra network cost --
                // --write-info-json just serializes the info dict yt-dlp already has
                // in memory for the --print output above. Written unconditionally
                // here (including for playlist probes); the playlist case writes
                // just the first item's info, so the download-time cache lookup
                // below is gated on !isPlaylist to avoid ever feeding a single-item
                // info dict into a full-playlist download.
                let infoJSONCachePath = self.manager.cachedInfoJSONWritePath(for: url)
                var analyzeArgs = [
                    "--no-warnings", "--no-download",
                    // --print (used below) implies --simulate, and yt-dlp's
                    // --write-info-json write is gated on `not simulate` --
                    // so without --no-simulate here, --write-info-json was
                    // silently a no-op the entire time (confirmed: the
                    // analyze-cache directory stayed empty across repeated
                    // analyzes of the same URL). --no-simulate overrides
                    // that implied simulate so the file actually gets
                    // written to disk; --no-download (above) is what
                    // actually prevents the real media from being fetched,
                    // so this does not turn analyze into a real download.
                    "--no-simulate",
                    "--yes-playlist",
                    "--format", "bestvideo*",  // ensures %(height)s reflects true max resolution
                    // Line 1: playlist_count (NA for single video)
                    "--print", "%(playlist_count)s",
                    // Line 2: metadata
                    "--print", "%(title)s|||%(vcodec)s|||%(width)s|||%(thumbnail)s|||%(duration_string)s|||%(duration)s|||%(filesize_approx)s|||%(height)s|||%(asr)s|||%(abr)s|||%(acodec)s|||%(audio_channels)s|||%(ext)s",
                    // Line 3: formats JSON for per-resolution file size
                    "--print", "%(formats.:.{height,filesize,filesize_approx,tbr,vbr,abr,acodec,vcodec,audio_channels,format_note,protocol})j",
                    "--playlist-items", "1",  // only process first item — gets count + metadata fast
                    "--impersonate", "chrome",
                    "--write-info-json",
                    "-o", infoJSONCachePath
                ]
                // Authenticated requests see a materially larger format list than
                // anonymous ones -- YouTube in particular omits its true 4K+
                // streams from the anonymous list for many videos, which without
                // this was capping sourceMaxHeight (and therefore the quality
                // picker itself) at 1080p even when a signed-in browser session
                // could see higher. The download call already applied this same
                // cookie source (see ytArgs below); analyze never did, so the two
                // steps were silently looking at two different format lists.
                analyzeArgs += self.config.browser.cookieArgs
                // Reuse a fresh cached info-json (written by a prior analyze of
                // this exact URL within the TTL window) instead of re-resolving
                // from the network -- this is what makes re-pasting an already-
                // analyzed link (or re-analyzing from History) return near-
                // instantly instead of repeating the full ~6-10s yt-dlp
                // extraction. --load-info-json fully replaces the URL argument
                // (yt-dlp ignores/warns on a URL when this flag is present), and
                // every --print template above reads from the same info dict
                // either way, so the existing parsing logic below needs no
                // changes to handle this path.
                let reusedCachePath = self.manager.cachedInfoJSONPath(for: url)
                if let cachePath = reusedCachePath {
                    analyzeArgs.append("--load-info-json")
                    analyzeArgs.append(cachePath)
                } else {
                    analyzeArgs.append(url)
                }
                proc.arguments = analyzeArgs
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(env["PATH"] ?? "")"
                proc.environment = env
                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError  = errPipe
                try? proc.run()
                // Registered synchronously (not via main.async) so a Cancel that
                // lands between run() and registration can't slip through:
                // onCancelAnalyze finds no process to kill in that window, only
                // records the id, and the old async registration then re-added
                // the entry afterward -- letting this yt-dlp run to completion
                // for a card that was already gone.
                if !registerAnalyzeProcess(proc, cardID: cardID) { group.leave(); return }
                let watchdog1 = startAnalyzeTimeoutWatchdog(for: proc)
                // Read stderr concurrently to prevent pipe buffer deadlock.
                // Captured (not discarded) so a persistent-block signal like
                // HTTP 403 at analyze time can be detected and surfaced --
                // previously this text was read and thrown away, so analyze
                // failures were invisible.
                var errData1 = Data()
                let errSem = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    errData1 = errPipe.fileHandleForReading.readDataToEndOfFile()
                    errSem.signal()
                }
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                watchdog1.workItem.cancel()
                var analyzeTimedOut = watchdog1.didTimeOut()
                errSem.wait()
                // Check if this URL was cancelled while we were waiting
                var wasCancelled = false
                DispatchQueue.main.sync { wasCancelled = self.analyzeProcesses[cardID] == nil }
                if wasCancelled { group.leave(); return }
                var output = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                var lastStderr = String(data: errData1, encoding: .utf8) ?? ""

                // Fallback: if bestvideo* failed (audio-only source), retry with bestaudio.
                // Skipped once the primary attempt already timed out -- retrying the same
                // network call that just stalled for analyzeTimeoutSeconds would most likely
                // just stall again, doubling the wait before the card can show any result.
                if !analyzeTimedOut && (proc.terminationStatus != 0 || output.isEmpty) {
                    let proc2 = Process()
                    proc2.executableURL = URL(fileURLWithPath: ytdlp)
                    var fallbackArgs = [
                        "--no-warnings", "--no-download",
                        // Same --no-simulate fix as the primary analyze call
                        // above -- otherwise this fallback's --write-info-json
                        // is silently a no-op too.
                        "--no-simulate",
                        "--yes-playlist", "--playlist-items", "1",
                        "--format", "bestaudio",
                        "--print", "%(playlist_count)s",
                        "--print", "%(title)s|||none|||0|||%(thumbnail)s|||%(duration_string)s|||%(duration)s|||%(filesize_approx)s|||0|||%(asr)s|||%(abr)s|||%(acodec)s|||%(audio_channels)s|||%(ext)s",
                        "--impersonate", "chrome",
                        "--write-info-json",
                        "-o", infoJSONCachePath
                    ]
                    fallbackArgs.append(url)
                    proc2.arguments = fallbackArgs
                    proc2.environment = env
                    let outPipe2 = Pipe(); let errPipe2 = Pipe()
                    proc2.standardOutput = outPipe2
                    proc2.standardError  = errPipe2
                    try? proc2.run()
                    if !registerAnalyzeProcess(proc2, cardID: cardID) { group.leave(); return }
                    let watchdog2 = startAnalyzeTimeoutWatchdog(for: proc2)
                    var errData2 = Data()
                    let errSem2 = DispatchSemaphore(value: 0)
                    DispatchQueue.global().async {
                        errData2 = errPipe2.fileHandleForReading.readDataToEndOfFile()
                        errSem2.signal()
                    }
                    let outData2 = outPipe2.fileHandleForReading.readDataToEndOfFile()
                    proc2.waitUntilExit()
                    watchdog2.workItem.cancel()
                    if watchdog2.didTimeOut() { analyzeTimedOut = true }
                    errSem2.wait()
                    var wasCancelled2 = false
                    DispatchQueue.main.sync { wasCancelled2 = self.analyzeProcesses[cardID] == nil }
                    if wasCancelled2 { group.leave(); return }
                    output = String(data: outData2, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    // Fallback's stderr replaces the primary attempt's --
                    // it's the more recent, more relevant failure reason
                    // once both attempts have actually run.
                    if let s2 = String(data: errData2, encoding: .utf8), !s2.isEmpty { lastStderr = s2 }
                }

                // A 403 here means yt-dlp couldn't even read the page/metadata
                // for this URL, on either attempt -- this is a hard block at
                // the source (bot detection, geo-lock, auth wall, etc.), not
                // a signed-CDN-URL race like the download-time 403 case.
                // There's nothing to retry: yt-dlp using --impersonate chrome
                // already tried its best browser-impersonation attempt and
                // still got 403'd, so surfacing it immediately (rather than
                // silently dropping the card) is the right call here.
                let stderrLower = lastStderr.lowercased()
                let analyzeIsForbidden = output.isEmpty && stderrLower.contains("403") &&
                    (stderrLower.contains("forbidden") || stderrLower.contains("http error 403"))

                var preview: LinkPreview? = nil
                if !output.isEmpty {
                    // Output: line 1 = playlist_count (or NA), line 2 = metadata, line 3+ = formats JSON
                    let outputLines = output.components(separatedBy: "\n")
                    let playlistLine = outputLines.first ?? ""
                    let playlistCount = Int(playlistLine.trimmingCharacters(in: .whitespaces)) ?? 0

                    // If it's a playlist, create a playlist card without full metadata parse
                    if playlistCount > 1 {
                        var lp = LinkPreview(
                            url: url, title: "Playlist (\(playlistCount) items)",
                            thumbnailURL: "", hasVideo: true, duration: "",
                            mediaMode: .videoAndAudio
                        )
                        lp.isPlaylist = true
                        lp.playlistCount = playlistCount
                        lp.isSelected = true
                        lock.lock(); results.append((i, lp)); lock.unlock()
                        DispatchQueue.main.async { self.analyzeProcesses.removeValue(forKey: cardID) }
                        group.leave()
                        return
                    }

                    let metaLine    = outputLines.count > 1 ? outputLines[1] : (outputLines.first ?? output)
                    let formatsJSON = outputLines.count > 2 ? outputLines[2...].joined(separator: "\n") : ""
                    let parts = metaLine.components(separatedBy: "|||")
                    let title        = parts.count > 0 ? parts[0].trimmingCharacters(in: .whitespacesAndNewlines) : "Unknown"
                    let vcodec       = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : "none"
                    let width        = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespacesAndNewlines) : "0"
                    let thumbnail    = parts.count > 3 ? parts[3].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    let duration     = parts.count > 4 ? parts[4].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    // %(duration)s is a whole-number string for YouTube ("19") but a
                    // fractional one for SoundCloud ("213.886") -- Int(_:) on a string
                    // containing a decimal point returns nil, so this silently fell back
                    // to 0 for every SoundCloud link, which made estimatedBytes() (guarded
                    // on `secs > 0`) return nil and hide the size estimate entirely for
                    // audio-only SoundCloud sources. Parsing as Double first (then
                    // truncating) handles both shapes.
                    let durationSecs = parts.count > 5 ? Int(Double(parts[5].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) : 0
                    let fileSizeRaw  = parts.count > 6 ? parts[6].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    let heightRaw    = parts.count > 7 ? parts[7].trimmingCharacters(in: .whitespacesAndNewlines) : "0"
                    let asrRaw       = parts.count > 8 ? parts[8].trimmingCharacters(in: .whitespacesAndNewlines) : "0"
                    let abrRaw       = parts.count > 9 ? parts[9].trimmingCharacters(in: .whitespacesAndNewlines) : "0"
                    let acodecRaw    = parts.count > 10 ? parts[10].trimmingCharacters(in: .whitespacesAndNewlines) : "none"
                    let channelsRaw  = parts.count > 11 ? parts[11].trimmingCharacters(in: .whitespacesAndNewlines) : "0"
                    // The container the source stream is hosted in (WEBM, MP4, M4A...): what the
                    // input side of the metadata shows, like the output side shows its format.
                    let extRaw       = parts.count > 12 ? parts[12].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    let fileSizeB    = Int(fileSizeRaw)  // yt-dlp returns bytes as int string, "NA" if unknown
                    let rawHeight    = Int(heightRaw) ?? 0
                    let sourceW      = Int(width) ?? 0
                    // Tier thresholds (2160/1440/1080/720/480) assume standard 16:9 framing.
                    // Wider-than-16:9 sources (e.g. ultrawide, cinematic crops) hit their true
                    // resolution tier at a shorter pixel height, so a strict height check
                    // under-classifies them (e.g. a real 4K-wide master reads as 1440p by height
                    // alone). Normalize by deriving an equivalent 16:9 height from width when the
                    // source is wider than 16:9, and use whichever is larger.
                    let heightFromWidth = sourceW > 0 ? (sourceW * 9 / 16) : 0
                    let sourceH      = max(rawHeight, heightFromWidth)
                    let sourceASR    = Int(asrRaw) ?? 0
                    let sourceABR    = Int(Double(abrRaw) ?? 0)

                    // Normalize a raw yt-dlp/ffmpeg codec string (which often includes profile/
                    // level suffixes like "av01.0.12M.08" or "avc1.640028") down to a short,
                    // human-readable family name matching Convert's ffprobe-derived labels.
                    func normalizeCodecFamily(_ raw: String) -> String? {
                        guard raw != "none", raw != "NA", !raw.isEmpty else { return nil }
                        let lower = raw.lowercased()
                        if lower.hasPrefix("av01") || lower.hasPrefix("av1") { return "AV1" }
                        if lower.hasPrefix("vp09") || lower.hasPrefix("vp9") { return "VP9" }
                        if lower.hasPrefix("vp08") || lower.hasPrefix("vp8") { return "VP8" }
                        if lower.hasPrefix("avc1") || lower.hasPrefix("h264") { return "H264" }
                        if lower.hasPrefix("hev1") || lower.hasPrefix("hvc1") || lower.hasPrefix("h265") { return "H265" }
                        if lower.hasPrefix("mp4a") { return "AAC" }
                        if lower.hasPrefix("opus") { return "OPUS" }
                        if lower.hasPrefix("mp3") { return "MP3" }
                        if lower.hasPrefix("vorbis") { return "VORBIS" }
                        if lower.hasPrefix("ac-3") || lower.hasPrefix("ac3") { return "AC3" }
                        if lower.hasPrefix("flac") { return "FLAC" }
                        // Fallback: strip anything after the first "." and uppercase
                        let base = raw.split(separator: ".").first.map(String.init) ?? raw
                        return base.uppercased()
                    }
                    let normVideoCodec = normalizeCodecFamily(vcodec)
                    // yt-dlp's audio_channels is a bare integer count (no LFE layout string
                    // like ffprobe's channel_layout), so map the common counts directly —
                    // 6ch and 8ch sources are virtually always 5.1 / 7.1 surround in practice.
                    func channelLabel(_ ch: Int) -> String? {
                        switch ch {
                        case 1: return "1.0"
                        case 2: return "2.0"
                        case 6: return "5.1"
                        case 8: return "7.1"
                        case 0: return nil
                        default: return "\(ch)ch"
                        }
                    }
                    // The top-level %(acodec)s / %(audio_channels)s reflect whatever format
                    // was actually SELECTED (bestvideo* → video-only stream → audio fields are
                    // always "none"/"NA"). Real audio codec/channel info only lives on the
                    // best audio-only stream inside the formats JSON, extracted further below.
                    var normAudioCodec = normalizeCodecFamily(acodecRaw)
                    var normChannelLabel = channelLabel(Int(channelsRaw) ?? 0)

                    let hasVideo     = vcodec != "none" && vcodec != "NA" && vcodec != "" && (Int(width) ?? 0) > 0
                    var lp = LinkPreview(
                        url: url, title: title, thumbnailURL: thumbnail,
                        hasVideo: hasVideo, duration: duration,
                        durationSeconds: durationSecs,
                        fileSizeBytes: (fileSizeB ?? 0) > 0 ? fileSizeB : nil,
                        mediaMode: hasVideo ? .videoAndAudio : .audioOnly
                    )
                    lp.sourceMaxHeight = sourceH
                    lp.sourceWidthPx = sourceW
                    lp.sourceHeightPx = rawHeight
                    lp.sourceASR = sourceASR
                    lp.sourceABR = sourceABR
                    lp.sourceVideoCodec = hasVideo ? normVideoCodec : nil
                    lp.sourceContainer = ["", "NA", "none"].contains(extRaw) ? nil : extRaw.uppercased()
                    // sourceAudioCodec / sourceChannelLabel assigned after formats JSON parsing
                    // below, since the real values come from the best audio-only stream there.
                    // Set per-format quality based on source capabilities
                    // kbps formats: match the source's real bitrate exactly (Auto) whenever it's
                    // known, rather than rounding down to the nearest of the three fixed presets
                    // -- a 160kbps source used to silently default to "128kbps" with no way to
                    // see or select the real number.
                    let kbpsQuality: AudioQuality = sourceABR > 0 ? .auto : .q320
                    // FLAC: always Lossless (q320) — takes best available source
                    lp.audioQuality = kbpsQuality
                    lp.qualityByFormat = [
                        "mp3":  kbpsQuality,
                        "wav":  kbpsQuality,
                        "flac": .q320,      // always Lossless
                        "m4a":  .q320
                    ]
                    if hasVideo && sourceH > 0 {
                        lp.videoQuality = VideoQuality.highest(for: sourceH)
                    }
                    // Parse formats JSON to compute exact per-resolution file sizes
                    if !formatsJSON.isEmpty,
                       let jsonData = formatsJSON.data(using: .utf8),
                       let allFormats = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] {
                        // Best audio stream size
                        let audioStreams = allFormats.filter {
                            let vc = $0["vcodec"] as? String ?? ""
                            let ac = $0["acodec"] as? String ?? ""
                            return (vc == "none" || vc.isEmpty) && !ac.isEmpty && ac != "none"
                        }
                        let bestAudio = audioStreams.max {
                            let a = ($0["tbr"] as? Double ?? $0["abr"] as? Double ?? 0)
                            let b = ($1["tbr"] as? Double ?? $1["abr"] as? Double ?? 0)
                            return a < b
                        }
                        let audioBytes = bestAudio.map {
                            estimatedStreamBytes($0, among: allFormats, durationSeconds: durationSecs)
                        } ?? 0
                        // Real audio codec/channel info lives on the best audio-only stream
                        // (the top-level %(acodec)s reflects the video-only selected format).
                        if let bestAudio {
                            let rawAc = bestAudio["acodec"] as? String ?? ""
                            if let cleaned = normalizeCodecFamily(rawAc) { normAudioCodec = cleaned }
                            let ch = bestAudio["audio_channels"] as? Int ?? Int("\(bestAudio["audio_channels"] ?? "")") ?? 0
                            if let label = channelLabel(ch) { normChannelLabel = label }
                        }
                        // Per resolution cap: best video stream + best audio stream
                        for cap in [2160, 1440, 1080, 720, 480] {
                            let videoStreams = allFormats.filter {
                                let h   = $0["height"] as? Int ?? 0
                                let vc  = $0["vcodec"] as? String ?? ""
                                return h > 0 && h <= cap && !vc.isEmpty && vc != "none"
                            }
                            if let bestVid = videoStreams.max(by: {
                                let scoreA = (($0["height"] as? Int ?? 0) * 100000) + Int($0["tbr"] as? Double ?? $0["vbr"] as? Double ?? 0)
                                let scoreB = (($1["height"] as? Int ?? 0) * 100000) + Int($1["tbr"] as? Double ?? $1["vbr"] as? Double ?? 0)
                                return scoreA < scoreB
                            }) {
                                let vidBytes = estimatedStreamBytes(bestVid, among: allFormats, durationSeconds: durationSecs)
                                if vidBytes > 0 || audioBytes > 0 {
                                    lp.fileSizeByQuality[cap] = vidBytes + audioBytes
                                }
                            }
                        }
                    }
                    lp.sourceAudioCodec = normAudioCodec
                    lp.sourceChannelLabel = normChannelLabel
                    // Pre-fetch thumbnail into URL cache so AsyncImage renders instantly
                    if let thumbURL = URL(string: lp.thumbnailURL) {
                        _ = try? Data(contentsOf: thumbURL)
                    }
                    preview = lp
                } else if analyzeIsForbidden {
                    // Surface the block immediately instead of letting the
                    // card silently disappear -- there's no title/thumbnail
                    // to show since yt-dlp never got a readable response,
                    // but the user needs to know THIS specific link is
                    // blocked at the source rather than just vanishing with
                    // no explanation.
                    var lp = LinkPreview(
                        url: url, title: url, thumbnailURL: "",
                        hasVideo: false, duration: "",
                        mediaMode: .audioOnly
                    )
                    lp.analyzeError = "Blocked by source (HTTP 403) — this link can't be read, even with browser impersonation."
                    lp.analyzeErrorIsForbidden = true
                    preview = lp
                    manager.appendLog("Analyze failed (blocked, HTTP 403): \(url)")
                } else if analyzeTimedOut {
                    // The watchdog killed a hung yt-dlp process -- distinct from every other
                    // empty-output case below so the card (and the Log tab) say what actually
                    // happened instead of implying the source itself is unsupported.
                    var lp = LinkPreview(
                        url: url, title: url, thumbnailURL: "",
                        hasVideo: false, duration: "",
                        mediaMode: .audioOnly
                    )
                    lp.analyzeError = "Couldn't read this link — the request timed out."
                    preview = lp
                    manager.appendLog("Analyze timed out after \(Int(Self.analyzeTimeoutSeconds))s: \(url)")
                } else {
                    // Empty output and not a detected 403 -- most commonly
                    // an unsupported/incompatible source (a syntactically
                    // valid http(s) URL that isn't a host yt-dlp knows how
                    // to read). dropAllLinesAreURLs only checks URL syntax,
                    // not whether the host is actually supported, so this
                    // is the first point anything can catch that case.
                    // Previously this branch just deleted the placeholder
                    // card with no explanation -- the card would vanish
                    // and the paste field (already cleared when the card
                    // was queued) had nothing left to show either, so the
                    // failure was invisible. Surfacing it the same way as
                    // the 403 case gives the user a persistent, specific
                    // reason instead of a link that just silently disappears.
                    var lp = LinkPreview(
                        url: url, title: url, thumbnailURL: "",
                        hasVideo: false, duration: "",
                        mediaMode: .audioOnly
                    )
                    lp.analyzeError = "Couldn't read this link — the source may not be supported."
                    preview = lp
                    // Previously nothing about this failure ever reached the Log tab --
                    // stderr was read (to detect 403s) but otherwise thrown away, so a report
                    // like "random links fail to analyze" arrived with an exported log that
                    // just stopped after "Analyzing N URL(s)...", no clue why. The last
                    // non-empty stderr line is usually yt-dlp's own ERROR summary.
                    let stderrSummary = lastStderr
                        .split(separator: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .last { !$0.isEmpty } ?? "no stderr output"
                    manager.appendLog("Analyze failed for \(url): \(stderrSummary)")
                }
                lock.lock()
                results.append((i, preview))
                lock.unlock()
                // Push this URL's result to the UI the instant IT finishes,
                // rather than waiting for every pasted URL in the batch to
                // finish (the old group.notify-only path). Each yt-dlp
                // metadata-only call already resolves independently and
                // often in under a second, so cards should flip from
                // "Analyzing…" to their real title/thumbnail one at a time
                // instead of all sitting at "Analyzing…" until the slowest
                // link in the batch finally completes.
                DispatchQueue.main.async {
                    self.analyzeProcesses.removeValue(forKey: cardID)
                    if var realCard = preview {
                        // Slower, gentler settle than the old 0.4s spring --
                        // the user wants the analyze-to-preview handoff to
                        // read as a smooth blend, not a snap.
                        withAnimation(.easeInOut(duration: 0.55)) {
                            // Matched by the placeholder's own id (cardID),
                            // not url+isPending -- when the same link is
                            // pasted multiple times at once, every one of
                            // those pending cards shares the same url, so
                            // url-based matching always resolved to
                            // whichever same-url card was first in the
                            // array, collapsing all the duplicates onto
                            // one card as results landed. The id is unique
                            // per pasted instance even when the url repeats.
                            if let idx = self.linkPreviews.firstIndex(where: { $0.id == cardID }) {
                                // Keep the pending placeholder's identity so
                                // SwiftUI updates the existing card view in
                                // place instead of removing it and mounting
                                // a new one -- a same-identity update
                                // cross-fades cleanly, while a swapped
                                // identity forces the new view's glass
                                // background to build up from scratch
                                // (the light-grey-then-dark flash).
                                realCard.id = cardID
                                self.linkPreviews[idx] = realCard
                            }
                            // NOTE: deliberately no `else { append }` here anymore.
                            // If cardID isn't found, the user already cleared/
                            // cancelled this specific card while yt-dlp was still
                            // running in the background (Process.terminate() sends
                            // SIGTERM, which yt-dlp doesn't always honor instantly
                            // if it's mid-network-call -- so the process can still
                            // run to completion and land here well after the card
                            // was removed). Re-appending unconditionally used to
                            // silently resurrect a card the user had just cleared.
                            // Dropping the result here is correct: the user's
                            // clear action is the source of truth, not a late
                            // straggling process result.
                        }
                        // No `else` branch anymore -- preview is never nil now.
                        // Every path above (success, 403-forbidden, generic
                        // empty-output failure) constructs a LinkPreview, so
                        // there's no longer a case where this card should be
                        // deleted outright rather than updated in place with
                        // an error message. The old else-branch silently
                        // removed the placeholder for any non-403 failure,
                        // which is exactly what made an incompatible-source
                        // link vanish with zero explanation.
                    }
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            self.isAnalyzing = false
            for id in ids {
                self.analyzeProcesses.removeValue(forKey: id)
                // Any id from THIS batch left in cancelledAnalyzeIDs at this
                // point was never consumed by the queued-cancel check above
                // (e.g. cancelled after its process already started, which
                // is handled separately via analyzeProcesses) -- clear it so
                // the set doesn't grow unbounded across repeated batches.
                self.cancelledAnalyzeIDs.remove(id)
            }
            // Per-URL updates above already applied every card as it
            // finished. This just cleans up anything that's somehow still
            // pending once THIS batch is done (shouldn't normally happen,
            // but guards against a card getting stuck forever if a result
            // was missed). Scoped to THIS batch's own `ids` set only --
            // an unscoped `removeAll { $0.isPending }` here used to sweep
            // every still-pending card in the entire list, including ones
            // queued by a separate, still-in-flight analyzeURL() call.
            // Each paste-and-analyze tap spawns its OWN DispatchGroup, so
            // pasting link A, then link B, then link C in quick succession
            // (each still analyzing when the next is pasted) produced
            // three concurrent, independent group.notify callbacks all
            // closing over the same shared linkPreviews array -- whichever
            // batch's network call finished first would wipe out the
            // other two batches' still-legitimately-analyzing placeholder
            // cards the instant its own notify fired, well before their
            // own yt-dlp processes had a chance to complete. Restricting
            // the sweep to this batch's own ids fixes that without
            // touching the per-URL apply-on-completion logic above, which
            // was already correctly scoped by cardID.
            let batchIDs = Set(ids)
            withAnimation(.spring(response: 0.35)) {
                self.linkPreviews.removeAll { $0.isPending && batchIDs.contains($0.id) }
            }
            // Reconstruct the successful (non-error) results for the
            // batch-level summary badge below -- per-URL updates above
            // already applied each card to the UI as it finished, but the
            // "was this batch video, audio, or mixed" badge still needs a
            // full-batch view once everything's done.
            let sorted = results.sorted { $0.0 < $1.0 }.compactMap { $0.1 }.filter { $0.analyzeError == nil }
            let hasAny  = !sorted.isEmpty
            let hasVid  = sorted.contains { $0.hasVideo }
            let allVid  = sorted.allSatisfy { $0.hasVideo }
            // NOTE: no longer touches self.urlText here. Every current call
            // site passes an explicit `urls:`/`ids:` override and already
            // clears urlText itself the moment its own placeholders are
            // queued (see the paste/analyze tap handler above and
            // HistoryView's onAnalyze), so by the time THIS closure runs,
            // urlText may already hold a completely different link the
            // user pasted for a newer, still-in-flight batch. Clearing it
            // here unconditionally used to blank out that newer paste out
            // from under the user while an older batch's slower network
            // call finally caught up.
            if !hasAny {
                self.analyzeResult = .unknown
            } else {
                if allVid {
                    self.analyzeResult = .videoAndAudio
                } else if !hasVid {
                    self.analyzeResult = .audioOnly
                } else {
                    self.analyzeResult = .videoAndAudio  // mixed — show generic badge
                }
            }
        }
    }

    var downloadButton_label: String {
        let checkedCount = selectedPreviews.count
        if checkedCount > 1  { return "Download \(checkedCount) Items" }
        if checkedCount == 1, let p = selectedPreviews.first {
            switch p.mediaMode {
            case .audioOnly:     return "Download as \(p.audioFormat.label)"
            case .videoAndAudio: return "Download \(p.videoFormat.label) + Audio"
            }
        }
        let lineCount = urlText.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        if lineCount > 1 { return "Download \(lineCount) Items" }
        switch config.mediaMode {
        case .audioOnly:     return "Download as \(config.format.label)"
        case .videoAndAudio: return "Download \(config.videoFormat.label) + Audio"
        }
    }

    func download() {
        // If we have analyzed previews, download only the checked ones.
        // Outside Select mode every queued preview counts as selected
        // (checkboxes are hidden, so nothing is excluded) — same convention
        // as Convert's selectedJobs.
        if !linkPreviews.isEmpty {
            let selected = selectedPreviews
            guard !selected.isEmpty else { return }
            let selectedIDs = Set(selected.map { $0.id })
            for i in linkPreviews.indices where selectedIDs.contains(linkPreviews[i].id) && linkPreviews[i].downloadID == nil {
                let preview = linkPreviews[i]
                let itemConfig = config.detached(mediaMode: preview.mediaMode, videoQuality: preview.videoQuality,
                                                 videoFormat: preview.videoFormat, format: preview.audioFormat,
                                                 quality: preview.audioQuality,
                                                 // Falls back to the remembered default when this
                                                 // card's own dropdown was never touched -- see
                                                 // LinkPreview.reencodeCodec's own doc comment.
                                                 reencodeCodec: preview.reencodeCodec ?? config.reencodeCodec)
                // add() returns the UUID of the newly created Download
                let snap = DownloadSnapshot(
                    title:            preview.title,
                    thumbnailURL:     preview.thumbnailURL,
                    hasVideo:         preview.hasVideo,
                    duration:         preview.duration,
                    durationSeconds:  preview.durationSeconds,
                    fileSizeBytes:    preview.fileSizeBytes,
                    sourceMaxHeight:  preview.sourceMaxHeight,
                    sourceWidthPx:    preview.sourceWidthPx,
                    sourceHeightPx:   preview.sourceHeightPx,
                    sourceASR:        preview.sourceASR,
                    sourceABR:        preview.sourceABR,
                    sourceContainer:  preview.sourceContainer,
                    sourceVideoCodec: preview.sourceVideoCodec,
                    sourceAudioCodec: preview.sourceAudioCodec,
                    sourceChannelLabel: preview.sourceChannelLabel,
                    qualityByFormat:  preview.qualityByFormat,
                    fileSizeByQuality: preview.fileSizeByQuality,
                    estimatedBytes:   preview.estimatedBytes()
                )
                if let newID = manager.add(urls: [preview.url], config: itemConfig, thumbnailURL: preview.thumbnailURL, isPlaylist: preview.isPlaylist, snapshot: snap) {
                    linkPreviews[i].downloadID = newID
                }
            }
            return
        }
        // Fallback: plain URL list (no analyze)
        let urls = urlText.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !urls.isEmpty else { return }
        manager.add(urls: urls, config: config)
    }

    /// Restore a full PreviewCard from a Download's stored analyze snapshot.
    /// Called by Retry / Redownload / cancelled retry — avoids re-analyzing
    /// and preserves title, thumbnail, resolution options, and quality settings.
    func restorePreviewCard(from dl: Download, replacing oldID: UUID) {
        let snap = dl.snapshot
        var lp = LinkPreview(
            url: dl.url,
            title: snap.title.isEmpty ? dl.title : snap.title,
            thumbnailURL: snap.thumbnailURL.isEmpty ? dl.thumbnailURL : snap.thumbnailURL,
            hasVideo: snap.hasVideo,
            duration: snap.duration,
            durationSeconds: snap.durationSeconds,
            fileSizeBytes: snap.fileSizeBytes,
            mediaMode: dl.mediaMode
        )
        lp.sourceMaxHeight   = snap.sourceMaxHeight
        lp.sourceWidthPx     = snap.sourceWidthPx
        lp.sourceHeightPx    = snap.sourceHeightPx
        lp.sourceASR         = snap.sourceASR
        lp.sourceABR         = snap.sourceABR
        lp.sourceContainer   = snap.sourceContainer
        lp.sourceVideoCodec  = snap.sourceVideoCodec
        lp.sourceAudioCodec  = snap.sourceAudioCodec
        lp.sourceChannelLabel = snap.sourceChannelLabel
        lp.videoQuality      = snap.sourceMaxHeight > 0 ? VideoQuality.highest(for: snap.sourceMaxHeight) : dl.videoQuality
        lp.videoFormat       = dl.videoFormat
        lp.audioFormat       = dl.format
        lp.audioQuality      = dl.audioQuality
        lp.reencodeCodec     = dl.reencodeCodec
        lp.qualityByFormat   = snap.qualityByFormat
        lp.fileSizeByQuality = snap.fileSizeByQuality
        lp.isSelected        = true
        withAnimation(.spring(response: 0.25)) {
            manager.downloads.removeAll { $0.id == dl.id }
            if let idx = linkPreviews.firstIndex(where: { $0.id == oldID }) {
                // The same card (same id) goes back to its ready state, rather than being replaced.
                lp.id = oldID
                linkPreviews[idx] = lp
            } else {
                linkPreviews.append(lp)
            }
        }
    }

    func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            // Try public.url first (dragging from browser address bar)
            if provider.hasItemConformingToTypeIdentifier("public.url") {
                provider.loadItem(forTypeIdentifier: "public.url", options: nil) { item, _ in
                    let str: String?
                    if let url = item as? URL { str = url.absoluteString }
                    else if let data = item as? Data { str = String(data: data, encoding: .utf8) }
                    else { str = nil }
                    if let s = str?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                        DispatchQueue.main.async {
                            self.urlText += (self.urlText.isEmpty ? "" : "\n") + s
                        }
                    }
                }
            } else {
                provider.loadItem(forTypeIdentifier: "public.plain-text", options: nil) { item, _ in
                    if let data = item as? Data, let s = String(data: data, encoding: .utf8) {
                        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        DispatchQueue.main.async {
                            self.urlText += (self.urlText.isEmpty ? "" : "\n") + trimmed
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Shimmer Bar

struct ShimmerBar: View {
    let width: CGFloat
    var color: Color = .white
    var glow: Bool = false
    var duration: Double = 1.4
    @State private var offset: CGFloat = -1.0

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: color.opacity(0.08), location: 0),
                        .init(color: color.opacity(0.08), location: max(0, offset - 0.25)),
                        .init(color: color.opacity(glow ? 0.9 : 0.55), location: offset),
                        .init(color: color.opacity(0.08), location: min(1, offset + 0.25)),
                        .init(color: color.opacity(0.08), location: 1),
                    ]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 4)
            .shadow(color: glow ? color.opacity(0.6) : .clear, radius: glow ? 6 : 0, x: 0, y: 0)
            .onAppear {
                withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                    offset = 2.0
                }
            }
    }
}

// MARK: - Bouncing Dots

/// Three small dots that bounce in sequence -- used in place of a progress
/// bar for the brief pre-download gap (process launching, URL still being
/// resolved) where there's no real percentage yet but the UI still needs to
/// read as "actively working", not frozen. Clearer at a glance than a subtle
/// gradient sweep on a 4pt bar.
struct BouncingDots: View {
    var color: Color = .green
    var size: CGFloat = 4
    @State private var animate = false

    var body: some View {
        HStack(spacing: size * 0.9) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(color)
                    .frame(width: size, height: size)
                    .opacity(animate ? 1.0 : 0.35)
                    .scaleEffect(animate ? 1.0 : 0.6)
                    .animation(
                        .easeInOut(duration: 0.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.18),
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
    }
}

// MARK: - Download Info Chip Row
// Shared between the in-progress and finished download card states, and
// styled identically to the History tab's chips (same HistoryChip view).
struct ChipRow: View {
    let chips: [ChipData]
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(chips, id: \.self) { chip in
                HistoryChip(label: chip.label, value: chip.value, color: chip.color, icon: chip.icon,
                            icon2: chip.icon2, value2: chip.value2)
            }
        }
    }
}

/// A row of "choose one" chips. Equal-width and filling the row when they
/// fit; when they don't (a narrow window), they wrap onto more lines at their
/// natural widths instead of every label truncating to "H.2…".
struct OptionRow<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: spacing) { content() }
            FlowLayout(spacing: spacing) { content() }
        }
    }
}

/// Wraps children onto new lines when the row runs out of horizontal space —
/// each chip keeps its own fixed size (no internal text wrapping), only the
/// row itself wraps. Used by ChipRow so Download/Convert info chips never
/// get squeezed into vertical text columns.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            // Clamped to the row: a chip wider than the whole row (a long
            // "MP4 · H264 · 24fps · 1920×1080" in a narrow column) is
            // truncated by its own text rather than overflowing the row and
            // overlapping whatever sits beside it.
            let ideal = subview.sizeThatFits(.unspecified)
            let size = CGSize(width: min(ideal.width, maxWidth), height: ideal.height)
            if rowWidth > 0 && rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                totalWidth = max(totalWidth, rowWidth)
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        totalWidth = max(totalWidth, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            let size = CGSize(width: min(ideal.width, maxWidth), height: ideal.height)
            if x > bounds.minX && x + size.width > bounds.minX + maxWidth {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: size.width, height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Small legend explaining a dot shown on format/codec chips. `positiveLabel` reads
/// "Native" for Download's format rows (true remux-native containers) and "Original"
/// for Convert's codec rows (matches source) -- both green (`tint`'s default). Download's
/// OUTPUT FORMAT row also uses this for the opposite case: an orange "Re-encode" legend
/// next to MOV's own warning dot (see downloadVideoFormatOptions), when the source codec
/// actually forces one.
func nativeLegend(positiveLabel: String = "Native", tint: Color = DesignTokens.Accent.success) -> some View {
    // Same dot as SegmentButton's nativeBadge, same fix -- see its comment. An
    // Image(systemName:) under .firstTextBaseline has no real baseline guide of its
    // own, so it falls back to VerticalAlignment.center: the dot's CENTER lands on
    // the text's BASELINE (confirmed live), not on the label's cap-height middle.
    // Shifting up by half the label's cap-height corrects it. (8.5pt -- cap height
    // ~6pt, half ~3pt.)
    HStack(alignment: .firstTextBaseline, spacing: 4) {
        Image(systemName: "circle.fill")
            .font(.system(size: 6))
            .foregroundColor(tint)
            .offset(y: -1.5)
        Text(positiveLabel).font(.appMono(size: 8.5)).foregroundColor(.white.opacity(DesignTokens.Text.disabled))
            .lineLimit(1).fixedSize()
    }
}

// MARK: - Glass Button

/// Pill-shaped label+icon button. Thin wrapper around GlassInteractive so it
/// shares the exact same glass material, hover/press/glow physics, and
/// contrast tokens as every other interactable in the app -- only the
/// icon+label content and a few layout knobs (fitContent, fillHeight,
/// verticalPadding) are specific to this call-site shape.
struct GlassButton: View {
    let label: String
    let icon: String
    var tint: Color = .white
    var verticalPadding: CGFloat = 6
    // Only overridden for call sites (like the embedded Paste & Analyze
    // pill) that need more breathing room around the icon/label than the
    // default gives -- every existing caller keeps the original 10pt.
    var horizontalPadding: CGFloat = 10
    var fillHeight: Bool = false
    var fitContent: Bool = false   // when true, button hugs its label/icon instead of stretching to fill its container
    var isLoading: Bool = false
    var disabled: Bool = false     // when true, dims the button and blocks interaction/hover glow
    // Passthrough to GlassInteractive -- true when this button is an inset
    // control living inside another glass surface (e.g. Paste & Analyze
    // inside urlCard's own capsule) so it doesn't paint a second
    // independent blur/tint/stroke on top of the parent's.
    var embedded: Bool = false
    // Passthrough to GlassInteractive -- lets an embedded pill show a
    // resting accent wash (isActive-style fill even when not hovered),
    // since embedded mode has no independent border to signal "this is
    // a button" on its own.
    var activeFillOverride: (rest: Double, active: Double, hover: Double, press: Double)? = nil
    // Passthrough to GlassInteractive -- see its declaration for details.
    var embeddedGlowStroke: Bool = false
    var scaleOverride: (hover: CGFloat, press: CGFloat)? = nil
    // Same Tron-style traveling light beam used on the Analyze card's rim
    // (see GlassCard.isActive/RimBeam) -- reserved for a button that
    // represents real work actively in progress (checking for updates,
    // converting, downloading), not a resting decoration. cornerRadius is
    // passed a large constant below since this button's shape is a
    // capsule, not a fixed-radius rounded rect -- RimBeam's own rim math
    // already clamps radius to min(width, height)/2, so any sufficiently
    // large value traces a true capsule regardless of this button's size.
    var showRimBeam: Bool = false
    let action: () -> Void

    var body: some View {
        GlassInteractive(shape: .capsule, tint: tint, isActive: embedded, disabled: disabled, activeFillOverride: activeFillOverride, embedded: embedded, embeddedGlowStroke: embeddedGlowStroke, scaleOverride: scaleOverride, action: action) {
            HStack(spacing: isLoading ? 6 : 4) {
                if isLoading {
                    // frame BEFORE scaleEffect so the 10x10 layout box is
                    // established first, then the spinner's rendered
                    // content shrinks to fit inside it -- the old
                    // scaleEffect-then-frame order left the shrunk
                    // spinner's visual bleeding past its own layout box
                    // and hugging/overlapping the label text, since
                    // scaleEffect only resizes the render, not the layout
                    // frame it's clipped into.
                    ProgressView().frame(width: 10, height: 10).scaleEffect(0.55)
                } else {
                    Image(systemName: icon).font(.appMono(size: 10))
                }
                Text(label)
                    .font(.appMono(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: fitContent ? nil : .infinity)
            .padding(.horizontal, horizontalPadding).padding(.vertical, verticalPadding)
            .frame(maxHeight: fillHeight ? .infinity : nil)
        }
        .overlay {
            if showRimBeam {
                RimBeam(cornerRadius: 999)
            }
        }
    }
}




/// Tooltip and accessibility wording that more than one place shows.
enum HelpText {
    /// yt-dlp / ffmpeg ship inside the app, so a missing one means a broken install.
    static let toolsMissing = "Bundled yt-dlp or ffmpeg Is Missing — Reinstall Drop"
}

extension View {
    /// Gives a control an accessibility label only when there is one to give: an empty label would
    /// replace the one SwiftUI derives with nothing at all.
    @ViewBuilder
    func accessibilityLabelIfPresent(_ label: String) -> some View {
        if label.isEmpty { self } else { self.accessibilityLabel(label) }
    }
}
