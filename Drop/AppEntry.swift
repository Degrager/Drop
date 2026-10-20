import SwiftUI
import AppKit
import UserNotifications
import UniformTypeIdentifiers
import QuickLookThumbnailing
import CryptoKit
import Sparkle

// MARK: - App Entry

extension Notification.Name {
    static let menuBarDownload = Notification.Name("dropMenuBarDownload")
    /// Fired once, from DropAppDelegate.windowDidEndLiveResize, when the user
    /// releases a window-edge drag. See ContentView's settledWindowSize /
    /// columnClass / settledWindowSize for why this exists.
    static let dropLiveResizeEnded = Notification.Name("dropLiveResizeEnded")
}

/// True while the user is dragging a window edge (from
/// windowWillStartLiveResize to windowDidEndLiveResize). Flips twice per drag,
/// so a view observing it costs nothing per resize tick. Used to pause
/// continuously-running animations (a TimelineView driving a Canvas at the
/// display's refresh rate keeps SwiftUI re-laying-out on macOS), which would
/// otherwise stack on top of the per-frame relayout the drag itself causes.
final class LiveResizeState: ObservableObject {
    static let shared = LiveResizeState()
    @Published private(set) var isActive = false
    /// True while the sidebar collapses or expands -- from the toggle until the page has
    /// taken its final width. Not a window resize, but the same problem: every frame of
    /// it would lay the cards out again.
    @Published private(set) var sidebarMoving = false

    /// The cards give way to their facade (see FrozenDuringResize) while the window edge is
    /// dragged or the sidebar is moving.
    var freezesCards: Bool { isActive || sidebarMoving }

    /// The page container's width (ContentView's `mainAreaWidth`: measured as if the sidebar
    /// were collapsed), kept here for the facade to place itself with. A plain property, NOT
    /// published: it changes on every tick of a window drag, and nothing may re-run just
    /// because of it (see the note above `mainAreaWidth`).
    var pageAreaWidth: CGFloat = 0

    func set(_ active: Bool) {
        if active != isActive { isActive = active }
    }

    func setSidebarMoving(_ moving: Bool) {
        if moving != sidebarMoving { sidebarMoving = moving }
    }
}

extension Notification.Name {
    /// Posted by ContentView's onChange(of: sidebarCollapsedByUser) -- see
    /// DropAppDelegate.sidebarCollapsedDidChange.
    static let dropSidebarCollapsedChanged = Notification.Name("DropSidebarCollapsedChanged")
}

// MARK: - App Delegate (enforces the screen-relative minimum window size)

@MainActor
class DropAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var shared: DropAppDelegate!
    /// The status item, its panel and its right-click menu (MenuBarPanel.swift).
    private let menuBar = MenuBarController()
    /// Keeps titlebarSeparatorStyle pinned to .none -- see configureWindow's
    /// comment on why a one-time assignment doesn't hold.
    private var titlebarSeparatorObservation: NSKeyValueObservation?

    override init() {
        super.init()
        DropAppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Drop has exactly one window and never will have more than one --
        // native window tabbing has nothing to do here, so its menu items
        // ("Show Tab Bar", "Show All Tabs") are just clutter in the View
        // menu. This is the standard AppKit-wide switch to remove them.
        NSWindow.allowsAutomaticWindowTabbing = false
        // Disables AppKit's spelling/completion/substitution machinery
        // globally rather than per-field -- every SwiftUI TextField on
        // macOS is actually edited through one shared "field editor"
        // NSTextView per window, obtainable only via AppKit, so this
        // listens for ANY field beginning editing anywhere in the app.
        // Not what was causing the launch-time popup near the paste field
        // (that turned out to be the system Password AutoFill suggestion
        // window -- see the .textContentType(.URL) fix on that TextField)
        // but still worth keeping: a URL-paste field has no legitimate use
        // for any of this.
        NotificationCenter.default.addObserver(
            forName: NSText.didBeginEditingNotification, object: nil, queue: .main
        ) { note in
            guard let editor = note.object as? NSTextView else { return }
            editor.isAutomaticTextCompletionEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isContinuousSpellCheckingEnabled = false
            editor.isGrammarCheckingEnabled = false
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticDataDetectionEnabled = false
            editor.isAutomaticLinkDetectionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
        }

        // Created here, not in init -- AppKit is fully initialized by now.
        menuBar.install()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let window = NSApplication.shared.windows.first(where: { !($0 is NSPanel) }) {
                self.configureWindow(window)
            }
        }
        // The block above only ever runs once, on whatever window exists 0.1s after
        // THIS launch. Closing the window (not quitting -- Drop stays alive via the
        // menu bar) and reopening it from the Dock hands WindowGroup a BRAND NEW
        // NSWindow that block never sees, so it kept none of the setup below --
        // no delegate, so windowWillResize never fired, so minSize's own floor (which
        // SwiftUI can silently rewrite smaller from its own content minimum, per
        // applyMinimumSize's comment) had nothing enforcing it -- reported live as
        // "closed the window and reopened it and it overrode the strict minimum
        // window size." didBecomeKeyNotification fires for every window as it's
        // first shown, launch's included, so `delegate !== self` (never yet
        // configured) is what actually gates a fresh run here -- not "just
        // reopened," since it must stay a no-op for the ordinary case of simply
        // clicking back into the same, already-configured window.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let window = note.object as? NSWindow,
                  !(window is NSPanel), window.delegate !== self else { return }
            // Delivered on the main queue (queue: .main), so this really is on the main actor.
            MainActor.assumeIsolated { self.configureWindow(window) }
        }
        NotificationCenter.default.addObserver(
            forName: .dropSidebarCollapsedChanged, object: nil, queue: .main
        ) { [weak self] note in
            guard let collapsed = note.userInfo?["collapsed"] as? Bool else { return }
            MainActor.assumeIsolated { self?.sidebarCollapsedDidChange(collapsed: collapsed) }
        }
    }

    private func configureWindow(_ window: NSWindow) {
        window.delegate = self
        applyMinimumSize(to: window)
        applyLaunchSize(to: window)
        window.collectionBehavior = [.managed, .fullScreenPrimary]
        // Standard AppKit window -- no NonFullscreenWindow subclass
        // override anymore, so both double-click-title-bar-to-zoom
        // and the green button's native Spaces-fullscreen mode work
        // exactly like any normal Mac app window.
        // The window backing itself must be non-opaque with a
        // clear background color for NSVisualEffectView's
        // .behindWindow blending to have anything real to
        // refract -- .behindWindow blur samples what's actually
        // behind the window (desktop, other apps), but AppKit only
        // composites that through if the window's own backing
        // isn't opaque. Without this the material still renders as
        // a flat blurred color because it's compositing against
        // the window's opaque backing instead of true content
        // behind it -- this is what produced the washed-out white
        // splotches instead of real glass refraction.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        // Without this the title bar stays an opaque solid strip
        // even though the rest of the window is now transparent --
        // it's a separate chrome layer AppKit draws regardless of
        // window.backgroundColor. isMovableByWindowBackground keeps
        // drag-to-move working since the transparent title bar area
        // no longer paints a draggable bar the user can visually
        // grab.
        window.titlebarAppearsTransparent = true
        // Left at AppKit's default (.automatic) this draws a hairline under
        // the title bar whenever the content below has scrolled -- on by
        // the time any tab's list isn't pinned to the very top, gone once
        // it is, which read as the divider randomly appearing/disappearing.
        // Every page already carries its own glass top bar as part of its
        // content, so this native one is pure redundant chrome.
        //
        // Setting it once here isn't enough: AppKit re-derives this property
        // live off the content's own scroll position (the same mechanism
        // .automatic uses), so it silently flips back to .line the next time
        // a ScrollView underneath scrolls -- confirmed live, reported back as
        // "that divider line is back" after a one-time `= .none` here. KVO
        // on the property itself snaps it back to .none every time AppKit
        // tries to reassert it, instead of fighting that per scroll event.
        window.titlebarSeparatorStyle = .none
        titlebarSeparatorObservation = window.observe(\.titlebarSeparatorStyle, options: [.new]) { window, change in
            if change.newValue != .none { window.titlebarSeparatorStyle = .none }
        }
        window.isMovableByWindowBackground = true
        // Disables macOS's window-state-restoration snapshot --
        // SwiftUI's WindowGroup opts into this by default, which
        // caches a bitmap of the window's content on quit and shows
        // it immediately on the next launch (before the app has
        // actually finished initializing), swapping in real content
        // once ready. Not related to the launch-time paste-field
        // popup (that was the system Password AutoFill suggestion
        // window -- see .textContentType(.URL) on the URL
        // TextField) but still worth keeping off since Drop has no
        // meaningful state worth restoring between launches.
        window.isRestorable = false
    }

    /// Every launch opens at WindowLayout.defaultSize, centered on the screen
    /// it appears on (the middle of the area left after the menu bar and Dock),
    /// whatever size or place the last session ended at. constrainFrameRect
    /// pulls it back on-screen if the screen is smaller than the window.
    private func applyLaunchSize(to window: NSWindow) {
        let size = WindowLayout.defaultSize
        let screen = window.screen ?? NSScreen.main
        var frame = NSRect(origin: window.frame.origin, size: size)
        if let visible = screen?.visibleFrame {
            frame.origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        }
        window.setFrame(window.constrainFrameRect(frame, to: screen), display: true)
    }

    /// The sidebar no longer auto-collapses as the window narrows -- its own
    /// state (a free user choice) instead decides which floor applies.
    private var currentMinimumSize: NSSize {
        UserDefaults.standard.bool(forKey: "sidebarCollapsed") ? WindowLayout.minimumSizeCollapsed : WindowLayout.minimumSizeExpanded
    }

    private var minSizeObservations: [NSKeyValueObservation] = []

    /// The floor is `currentMinimumSize`, and nothing may raise it. (SwiftUI can also
    /// rewrite the minimum DOWN to its content's, so windowWillResize below enforces the
    /// same floor from the other side.) SwiftUI overwrites the
    /// window's minimum with its own content minimum, and for a moment that is far above
    /// ours: with Convert showing, the file dialog opening (Browse) made it 293 x 1005. A
    /// dialog that was then cancelled never triggered another layout, so the window stayed
    /// pinned at a 1005pt minimum and could not be dragged back down to 800. So any
    /// minimum above the app's own is pulled straight back down. The window itself is
    /// never grown: only its minimum changes.
    private func applyMinimumSize(to window: NSWindow) {
        window.minSize = currentMinimumSize
        guard minSizeObservations.isEmpty else { return }
        let capMinimum: (NSWindow) -> Void = { [weak self] window in
            guard let self else { return }
            let floor = self.currentMinimumSize
            guard window.minSize.width > floor.width || window.minSize.height > floor.height else { return }
            window.minSize = NSSize(width: min(window.minSize.width, floor.width),
                                    height: min(window.minSize.height, floor.height))
        }
        minSizeObservations = [
            window.observe(\.minSize, options: [.new]) { window, _ in capMinimum(window) },
            window.observe(\.contentMinSize, options: [.new]) { window, _ in capMinimum(window) },
        ]
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let minimum = currentMinimumSize
        return NSSize(width: max(frameSize.width, minimum.width), height: max(frameSize.height, minimum.height))
    }

    /// Posted by ContentView when the user toggles the sidebar (see .dropSidebarCollapsedChanged).
    /// Collapsing only ever lowers the floor, so the window never needs to move; expanding can
    /// raise it above the window's current width, so this grows the window to fit if needed --
    /// the strict-minimum guarantee has to hold immediately, not just for the NEXT drag.
    /// Instant, not `animate: true` -- AppKit's own animationResizeTime scales with how far the
    /// frame moves, which for this jump (up to 200pt) stretched close to a full second, reported
    /// live as "a second delay after clicking before anything happens" (the sidebar's OWN
    /// animation starts immediately, but the window visually lagged behind it so badly the two
    /// read as one long stall). The sidebar's own SwiftUI animation still gives the motion.
    func sidebarCollapsedDidChange(collapsed: Bool) {
        guard let window = NSApplication.shared.windows.first(where: { !($0 is NSPanel) }) else { return }
        applyMinimumSize(to: window)
        guard !collapsed, window.frame.width < WindowLayout.minimumSizeExpanded.width else { return }
        var frame = window.frame
        frame.size.width = WindowLayout.minimumSizeExpanded.width
        window.setFrame(window.constrainFrameRect(frame, to: window.screen), display: true)
    }

    // Fires once when the user releases a window-edge drag (not on every
    // in-between resize tick, unlike windowWillResize above). ContentView uses
    // this to defer recomputing its layout breakpoints (compact sidebar/height,
    // content column width, chip wrapping) until the drag actually ends,
    // instead of re-deciding all of them on every one of the dozens of frames
    // a drag produces -- see settledWindowSize. Standard
    // AppKit-recommended pattern for expensive live-resize content (Apple's
    // "Cocoa Live Window Resizing" guide): let the raw frame track the mouse,
    // defer real relayout to resize's end.
    func windowDidEndLiveResize(_ notification: Notification) {
        LiveResizeState.shared.set(false)
        NotificationCenter.default.post(name: .dropLiveResizeEnded, object: nil)
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        LiveResizeState.shared.set(true)
    }

}

/// The two sidebar collapse/expand animations, switchable from the View menu >
/// Sidebar Animation. Resize is the default.
enum SidebarAnimationStyle: String {
    /// Rows blur out together, the card resizes, rows pop back in one by one.
    case pop
    /// The card resizes and its tabs and icons resize with it; nothing leaves.
    case resize

    static let storageKey = "sidebarAnimationStyle"
}

struct DropApp: App {
    @NSApplicationDelegateAdaptor(DropAppDelegate.self) var appDelegate
    @AppStorage(SidebarAnimationStyle.storageKey) private var sidebarAnimationStyle = SidebarAnimationStyle.resize.rawValue
    // Same UserDefaults key ContentView's own sidebarCollapsedByUser reads/writes --
    // an @AppStorage binding at this scope stays in sync with it automatically,
    // there's no need to reach into ContentView's own state to toggle it from here.
    @AppStorage("sidebarCollapsed") private var sidebarCollapsedByUser = false

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Toggle Sidebar") { sidebarCollapsedByUser.toggle() }
                Divider()
                Picker("Sidebar Animation", selection: $sidebarAnimationStyle) {
                    Text("Resize").tag(SidebarAnimationStyle.resize.rawValue)
                    Text("Pop In").tag(SidebarAnimationStyle.pop.rawValue)
                }
            }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        // The delegate then pins the exact frame at every launch
        // (applyLaunchSize); this just keeps the window from first appearing
        // at some other size or place before that runs.
        .defaultSize(width: WindowLayout.defaultSize.width, height: WindowLayout.defaultSize.height)
        .defaultPosition(.center)
    }
}

/// A copied/dropped line turned into an actual URL Drop can act on. A link
/// copied without its scheme (common: many browser address bars hide
/// "https://") otherwise silently failed validation everywhere that reads
/// from the clipboard -- reported live as "having the link copied without
/// the https:// doesn't work." `line` must already be trimmed and non-empty.
func normalizedDropURLLine(_ line: String) -> String {
    if let url = URL(string: line), url.scheme != nil { return line }
    return "https://\(line)"
}

/// Shared URL-list validator used by both the Download tab's Paste & Analyze
/// button and the menu bar's Paste & Analyze button, so "every line must be
/// a valid http/https URL" is defined in exactly one place.
func dropAllLinesAreURLs(_ text: String) -> Bool {
    let lines = text.components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .map(normalizedDropURLLine)
    guard !lines.isEmpty else { return false }
    return lines.allSatisfy { line in
        guard let url = URL(string: line),
              let scheme = url.scheme,
              (scheme == "http" || scheme == "https"),
              let host = url.host, dropHostLooksReal(host) else { return false }
        return true
    }
}

/// Whether a URL's host could be a real address. Foundation's URL parsing is lenient: any text at
/// all becomes a "host" once `https://` is put in front of it (Japanese words turn into a
/// punycode name like `xn--q6jaa…`, a lone word like `foo` is a host), so "has a host" alone let
/// ordinary text pass as a link. A real one has dots with a real top-level domain (`example.com`,
/// `日本語.jp`, `xn--…`), or is `localhost` or an IP address.
func dropHostLooksReal(_ host: String) -> Bool {
    if host == "localhost" || host.contains(":") { return true }   // `:` -> an IPv6 literal
    let name = host.hasSuffix(".") ? String(host.dropLast()) : host
    let labels = name.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return false }
    if labels.count == 4, labels.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) { return true }   // IPv4
    guard let tld = labels.last else { return false }
    return tld.hasPrefix("xn--") || (tld.count >= 2 && tld.allSatisfy(\.isLetter))
}

// MARK: - App Tab

enum AppTab { case download, history, convert, log, devRelease }

// MARK: - Analyze Result

enum AnalyzeResult {
    case videoAndAudio, audioOnly, unknown
}

// MARK: - On-Disk Log File

/// Persists every appendLog() line to a real file on disk so logs survive app
/// restarts and can be attached/uploaded when reporting an issue. Lives
/// alongside (not instead of) the in-memory globalLogs/log panel.
final class DropLogger {
    static let shared = DropLogger()
    let fileURL: URL
    private let handle: FileHandle?
    private let maxBytes: UInt64 = 5 * 1024 * 1024 // 5MB cap, then rotate

    private init() {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Drop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("drop.log")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = FileHandle(forWritingAtPath: fileURL.path)
        handle?.seekToEndOfFile()
    }

    func write(_ line: String) {
        guard let handle else { return }
        if let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? UInt64,
           size > maxBytes {
            // Rotate: keep the previous file as .1, start fresh.
            let rotated = fileURL.deletingPathExtension().appendingPathExtension("1.log")
            try? FileManager.default.removeItem(at: rotated)
            try? FileManager.default.moveItem(at: fileURL, to: rotated)
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            handle.seek(toFileOffset: 0)
        }
        if let data = (line + "\n").data(using: .utf8) {
            handle.write(data)
        }
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}
