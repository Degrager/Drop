import SwiftUI
import AppKit

// MARK: - Menu bar
//
// Drop's menu bar presence: a status item whose click opens a small glass
// panel (paste a link straight into Drop without leaving what you are doing),
// and whose right-click opens a short menu. The panel is Drop's own surface
// -- the same black frosted glass, rim and focus-in as every card in the
// window -- rather than a stock NSPopover, whose arrow and bezel never matched.

extension Notification.Name {
    /// Posted by the menu bar's "Check for Updates" (panel button and right-click
    /// menu). ContentView answers it by running the very same check as the
    /// sidebar's button. The raw name is kept from when the menu item posted it
    /// with nothing listening.
    static let menuBarCheckForUpdates = Notification.Name("DropCheckForUpdates")
}

// MARK: Model

/// What "Paste & Analyze" would do with the clipboard right now, so the panel can
/// show it before the click instead of reporting "Invalid" after it.
enum MenuBarClipboard: Equatable {
    case empty
    case notLinks
    /// One or more links, every line a valid http(s) URL. `title` is the host (or
    /// "3 links"); `detail` the path (or the hosts involved).
    case links(count: Int, title: String, detail: String)
}

final class MenuBarModel: ObservableObject {
    @Published private(set) var clipboard: MenuBarClipboard = .empty
    /// Right after a successful paste, until it reverts on its own.
    @Published private(set) var queued = false
    /// A paste the clipboard no longer supported when the button was pressed
    /// (it changed after the panel opened): the well flashes red.
    @Published private(set) var refused = false

    var canPaste: Bool {
        if case .links = clipboard { return true }
        return false
    }

    /// Reads the clipboard. Called when the panel opens (the user just clicked the
    /// status item, so this is user-initiated) and after a refused paste.
    func refreshClipboard() {
        guard let raw = NSPasteboard.general.string(forType: .string) else {
            clipboard = .empty
            return
        }
        clipboard = Self.describe(raw)
    }

    static func describe(_ raw: String) -> MenuBarClipboard {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .empty }
        // Prose or code on the clipboard can be enormous; a list of links never is.
        guard text.utf8.count <= 20_000, dropAllLinesAreURLs(text) else { return .notLinks }
        let urls = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { URL(string: $0) }
        guard let first = urls.first else { return .notLinks }
        func host(_ url: URL) -> String {
            let h = url.host ?? ""
            return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
        }
        if urls.count == 1 {
            var detail = pathAndQuery(first)
            if detail.isEmpty { detail = "Link" }
            return .links(count: 1, title: host(first), detail: detail)
        }
        var hosts: [String] = []
        for u in urls where !hosts.contains(host(u)) { hosts.append(host(u)) }
        return .links(count: urls.count, title: "\(urls.count) links", detail: hosts.joined(separator: ", "))
    }

    private static func pathAndQuery(_ url: URL) -> String {
        var s = url.path == "/" ? "" : url.path
        if let q = url.query { s += "?" + q }
        return s
    }

    /// Same validation and hand-off as the Download tab's own Paste & Analyze:
    /// ContentView's `.menuBarDownload` handler runs the identical
    /// placeholder-card + analyze flow.
    func paste() {
        guard !queued else { return }
        guard let raw = NSPasteboard.general.string(forType: .string) else {
            refuse()
            return
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, dropAllLinesAreURLs(trimmed) else {
            refuse()
            return
        }
        NotificationCenter.default.post(name: .menuBarDownload, object: nil, userInfo: ["url": trimmed])
        withAnimation(.easeOut(duration: 0.15)) { queued = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            withAnimation(.easeOut(duration: 0.15)) { self?.queued = false }
        }
    }

    private func refuse() {
        refreshClipboard()
        withAnimation(.easeOut(duration: 0.15)) { refused = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            withAnimation(.easeOut(duration: 0.2)) { self?.refused = false }
        }
    }
}

// MARK: View

struct MenuBarQuickView: View {
    @ObservedObject var model: MenuBarModel
    var onOpen: () -> Void
    var onCheckForUpdates: () -> Void
    var onQuit: () -> Void

    /// Transparent margin around the card: room for its shadow, which the window's edge
    /// must not clip.
    static let margin: CGFloat = 24
    static let cardWidth: CGFloat = 292

    var body: some View {
        VStack(spacing: 12) {
            header
            well
            VStack(spacing: 8) {
                pasteButton
                openButton
            }
        }
        .padding(14)
        .frame(width: Self.cardWidth)
        .glassCard(cornerRadius: DesignTokens.Radius.large)
        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        .padding(Self.margin)
        .preferredColorScheme(.dark)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.appMono(size: 15, weight: .semibold))
                .foregroundColor(.white.opacity(DesignTokens.Text.secondary))
            Text("Drop")
                .font(.appMono(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(DesignTokens.Text.primary))
            Spacer(minLength: 0)
            // Captions open to the left, over the empty part of this row.
            HoverIconButton(icon: "arrow.triangle.2.circlepath", size: 11, help: "Check for Updates", expandable: true, action: onCheckForUpdates)
            HoverIconButton(icon: "power", size: 11, help: "Quit Drop", expandable: true, action: onQuit)
        }
    }

    // MARK: Clipboard well

    private var wellContent: (icon: String, title: String, detail: String, isLink: Bool) {
        switch model.clipboard {
        case .empty:
            return ("doc.on.clipboard", "Clipboard is empty", "Copy a link, then paste it here", false)
        case .notLinks:
            return ("doc.on.clipboard", "No link on the clipboard", "Copy a link, then paste it here", false)
        case .links(_, let title, let detail):
            return ("link", title, detail, true)
        }
    }

    private var well: some View {
        let content = wellContent
        let tint: Color = model.refused ? DesignTokens.Accent.danger : .white
        return HStack(spacing: 10) {
            Image(systemName: model.refused ? "exclamationmark.triangle" : content.icon)
                .font(.appMono(size: 12, weight: .medium))
                .foregroundColor(model.refused ? DesignTokens.Accent.danger : .white.opacity(content.isLink ? DesignTokens.Text.primary : DesignTokens.Text.tertiary))
                .frame(width: 28, height: 28)
                .background(Circle().fill(tint.opacity(model.refused ? 0.14 : 0.06)))
            VStack(alignment: .leading, spacing: 2) {
                Text(model.refused ? "Nothing to paste" : content.title)
                    .font(.appMono(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(content.isLink || model.refused ? DesignTokens.Text.primary : DesignTokens.Text.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(model.refused ? "Copy a link, then try again" : content.detail)
                    .font(.appMono(size: 10.5))
                    .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Field.cornerRadius, style: .continuous)
                .fill(Color.white.opacity(DesignTokens.Field.fillRest))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Field.cornerRadius, style: .continuous)
                .stroke(model.refused ? DesignTokens.Accent.danger.opacity(0.7) : Color.white.opacity(DesignTokens.Field.borderRest),
                        lineWidth: DesignTokens.Field.borderWidth)
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: Buttons

    private var pasteButton: some View {
        // The primary action: a resting wash the plain buttons don't have. With
        // nothing to paste it keeps its dark glass and just dims (GlassButton's own
        // `disabled` lightens the glass to a grey slab), and after a paste it turns
        // into a green "Queued" for a couple of seconds.
        let inactive = !model.canPaste && !model.queued
        return GlassButton(
            label: model.queued ? "Queued" : "Paste & Analyze",
            icon: model.queued ? "checkmark" : "doc.on.clipboard",
            tint: model.queued ? DesignTokens.Accent.success : (inactive ? .white.opacity(0.4) : .white),
            verticalPadding: 9,
            fillHeight: true,
            activeFillOverride: inactive ? nil : (rest: 0.10, active: 0.10, hover: 0.18, press: 0.24)
        ) {
            model.paste()
        }
        // A fixed height: the icon swaps between states (a checkmark is shorter than
        // the clipboard glyph), which would otherwise resize the whole panel.
        .frame(height: 34)
        // Not `.disabled`: a disabled plain-style button fades its whole label,
        // glass included, to a grey slab (see FocusEffect).
        .allowsHitTesting(!inactive)
        .accessibilityHint(inactive ? "Copy a link first" : "")
    }

    private var openButton: some View {
        GlassButton(label: "Open Drop", icon: "arrow.up.forward.app", tint: .white, verticalPadding: 7, fillHeight: true, action: onOpen)
            .frame(height: 30)
    }
}

// MARK: - Panel

/// Borderless, non-activating: clicking it (or its buttons) never brings Drop's
/// main window forward -- the whole point is a paste that leaves you where you were.
/// Still able to become key, so hover and clicks behave like a normal window's.
private final class MenuBarPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

private final class MenuBarHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Controller

final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var panel: MenuBarPanel?
    private let model = MenuBarModel()
    /// When the panel last went away. Pressing the status item while the panel is
    /// open first makes the panel resign key (hiding it) and only then delivers
    /// the click, which would reopen it -- so a click right after a hide is the
    /// click that closed it, not a request to open.
    private var lastHide = Date.distantPast

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: "Drop")
        button.image?.isTemplate = true
        button.action = #selector(statusItemClicked)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    // MARK: Status item

    @objc private func statusItemClicked() {
        // No mouse event means an accessibility press (VoiceOver, Switch Control):
        // treat it as the primary click.
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showMenu()
        } else {
            togglePanel()
        }
    }

    private func showMenu() {
        hidePanel()
        let menu = NSMenu()
        menu.addItem(menuItem("Open Drop", symbol: "arrow.up.forward.app", action: #selector(openDrop)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Check for Updates…", symbol: "arrow.triangle.2.circlepath", action: #selector(checkForUpdates)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit Drop", symbol: "power", action: #selector(quitApp), key: "q"))
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    private func menuItem(_ title: String, symbol: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    // MARK: Actions (shared by the panel and the menu)

    @objc private func openDrop() {
        hidePanel()
        NSApp.activate(ignoringOtherApps: true)
        if let window = mainWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func checkForUpdates() {
        hidePanel()
        // The update card is drawn inside the main window, so bring it forward
        // first, then run the same check as the sidebar's button.
        openDrop()
        NotificationCenter.default.post(name: .menuBarCheckForUpdates, object: nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private var mainWindow: NSWindow? {
        NSApp.windows.first(where: { !($0 is NSPanel) })
    }

    // MARK: Panel

    private func togglePanel() {
        if let panel, panel.isVisible {
            hidePanel()
        } else if Date().timeIntervalSince(lastHide) > 0.25 {
            showPanel()
        }
    }

    private func makePanel() -> MenuBarPanel {
        let root = MenuBarQuickView(
            model: model,
            onOpen: { [weak self] in self?.openDrop() },
            onCheckForUpdates: { [weak self] in self?.checkForUpdates() },
            onQuit: { [weak self] in self?.quitApp() }
        )
        let hosting = MenuBarHostingView(rootView: root)
        let panel = MenuBarPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The card draws its own shadow.
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // Appears and goes away with the system's own window animation (a quick fade),
        // not a custom one: the scale-and-blur exit this used to play read as clunky.
        panel.animationBehavior = .utilityWindow
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.onCancel = { [weak self] in self?.hidePanel() }
        // Clicking anywhere else -- another window, another app, the desktop --
        // takes key away, and that closes the panel.
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelResignedKey), name: NSWindow.didResignKeyNotification, object: panel
        )
        return panel
    }

    private func showPanel() {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel

        model.refreshClipboard()

        // Under the status item, centred on it, kept on its screen.
        let size = (panel.contentView as? NSHostingView<MenuBarQuickView>)?.fittingSize ?? panel.frame.size
        let anchor = anchorRect(for: buttonWindow)
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let margin = MenuBarQuickView.margin
        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX - margin + 8), visible.maxX - size.width + margin - 8)
        // The card (not the transparent margin) sits 6pt under the menu bar.
        let cardTop = min(anchor.minY, visible.maxY) - 6
        panel.setFrame(NSRect(x: x, y: cardTop + margin - size.height, width: size.width, height: size.height), display: true)

        panel.orderFrontRegardless()
        panel.makeKey()
        button.highlight(true)
    }

    /// Where the status item is on screen. Its window's frame is normally exact, but
    /// it has been seen stale (nowhere near the menu bar) when the app had no
    /// visible window; a frame that isn't in the menu bar band of a screen is not
    /// trusted, and the panel goes where the user just clicked instead.
    private func anchorRect(for buttonWindow: NSWindow) -> NSRect {
        let frame = buttonWindow.frame
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }),
           frame.maxY >= screen.frame.maxY - 60 {
            return frame
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let top = screen?.frame.maxY ?? mouse.y
        return NSRect(x: mouse.x - 12, y: top - 24, width: 24, height: 24)
    }

    private func hidePanel() {
        guard let panel, panel.isVisible else { return }
        lastHide = Date()
        statusItem?.button?.highlight(false)
        panel.orderOut(nil)
    }

    @objc private func panelResignedKey(_ note: Notification) {
        hidePanel()
    }
}
