import SwiftUI
import AppKit
import UserNotifications
import UniformTypeIdentifiers
import QuickLookThumbnailing
import CryptoKit
import Sparkle

/// Reusable icon-only button with animated glow on hover
/// Cancel control shown in place of a download's progress spinner on hover.
/// Rebuilt on GlassInteractive so the X gets the same black-frosted circle,
/// glow ring, and press feedback as every other icon control in the app --
/// previously this had its own flat red wash with no material and no press
/// state at all.
struct SkeletonCancelButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        // The finished card's remove button, in its place and at its size: the same red
        // capsule, with the spinner where the X will be until the pointer is over it.
        GlassInteractive(shape: .roundedRect(DesignTokens.Radius.small), tint: .red, action: action) {
            ZStack {
                ProgressView()
                    .controlSize(.small)
                    .opacity(hovering ? 0 : 1)
                Image(systemName: "xmark.circle.fill")
                    .font(.appMono(size: 16))
                    .opacity(hovering ? 1 : 0)
            }
            .frame(width: 16, height: 16)
            .padding(6)
        }
        .onHover { h in
            withAnimation(.easeOut(duration: 0.15)) { hovering = h }
        }
        .help("Cancel")
        .accessibilityLabel("Cancel")
    }
}

/// Shared centered empty-state used by all four tabs (Download, Convert,
/// History, Log) -- icon + headline + optional subtitle, always true-
/// centered in the full available height and always using the same
/// DesignTokens.Text opacities. Before this, each tab hand-rolled its own
/// copy with drifted icon sizes/weights, raw opacity literals instead of
/// tokens (Convert's was nearly invisible), and two different centering
/// strategies (full-height frame vs. a fixed vertical padding), so the
/// four empty states landed at different positions and brightness levels
/// instead of reading as one consistent pattern.
struct EmptyStateView: View {
    let icon: String
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.appMono(size: 30, weight: .thin))
                .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                .accessibilityHidden(true)
            Text(title)
                .font(.appMono(size: 14, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(DesignTokens.Text.secondary))
            if let subtitle {
                Text(subtitle)
                    .font(.appMono(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

/// Small icon-only control (toolbar toggles, tab icons, per-row actions).
/// Rebuilt on GlassInteractive -- shape is a rounded-rect at the shared
/// `small` radius token so it matches chips/rows elsewhere, and every hover/
/// press/glow number now comes from DesignTokens instead of one-off values.
struct HoverIconButton: View {
    let icon: String
    var size: CGFloat = 13
    /// The button's own visible box -- defaults to `size + 12`, the original
    /// fixed relationship every existing call site still expects. Pass this
    /// explicitly to make the box match a taller neighbor (e.g. a folder
    /// capsule) WITHOUT scaling the glyph and hover caption up too, which
    /// bumping `size` alone would do (reported live: "the symbol inside
    /// should be the same height as it was... the hover labels should be
    /// the same size they were before").
    var boxSize: CGFloat? = nil
    var color: Color = .white
    var activeColor: Color? = nil
    var isActive: Bool = false
    var disabled: Bool = false
    var help: String = ""
    /// When true, hovering reveals `help` as a caption next to the icon
    /// (expanding per `captionExpandsFrom`, icon stays anchored) instead of
    /// relying on the tooltip alone -- one flag per call site, reusing
    /// `help`'s text rather than needing a second string typed out again.
    /// false (default) is icon-only, unchanged from before this existed.
    var expandable: Bool = false
    /// Defaults to the original rounded-rect chrome every existing call
    /// site already expects -- pass .circle for a fully round button
    /// instead, e.g. the queue row's up/down move controls.
    var shape: GlassInteractiveShape = .roundedRect(DesignTokens.Radius.small)
    /// The caption expands leftward by default (every existing expandable
    /// button sits near a row's trailing/right edge, so growing left is
    /// the only direction with room). Pass .leading for a button that
    /// sits near a LEFT edge instead (e.g. the sidebar's own collapse
    /// toggle, at the window's far-left) so the caption grows rightward
    /// and never runs off the window edge.
    var captionExpandsFrom: HorizontalEdge = .trailing
    let action: () -> Void

    @State private var isHovering = false
    /// Measured once from the button's own (fixed) rendered size -- used
    /// only to position the caption's offset below, never to size
    /// anything that .onHover is attached to.
    @State private var buttonWidth: CGFloat = 0

    var body: some View {
        let resolvedColor = isActive ? (activeColor ?? color) : color
        // Clears the hover caption the instant the button is actually pressed, not
        // just on hover-exit -- reported live: collapsing a card's settings (this
        // exact button) leaves "Hide Options"/"Show Options" ghosted on screen,
        // because the button ITSELF moves when the row above it shrinks/grows, and
        // nothing tells AppKit's hover tracking that happened without a fresh
        // mouse-moved event, so isHovering just stays true at the button's now-
        // stale old position. The same risk applies to any other expandable button
        // whose own click can shift layout (e.g. the sidebar's own toggle).
        GlassInteractive(shape: shape, tint: resolvedColor, isActive: isActive, disabled: disabled, action: {
            isHovering = false
            action()
        }) {
            Image(systemName: icon)
                .font(.appMono(size: size))
                // A button that changes what it is (collapse -> cancel -> redownload) swaps its
                // symbol in place instead of being replaced.
                .contentTransition(.symbolEffect(.replace))
                // A fixed square frame, not just .padding(6) around whatever the glyph's own
                // natural bounding box happens to be -- different SF Symbols render at
                // different aspect ratios at the same point size (a wide "chevron.down" vs a
                // symmetric "xmark.circle.fill"), so padding alone gave each icon a DIFFERENT
                // overall button footprint. On a non-square footprint, the shared corner
                // radius reads as much rounder on the short axis than the long one -- reported
                // live as the collapse chevron looking fully circular next to the perfectly
                // square remove button, though both use the identical .roundedRect shape and
                // radius. Every icon now centers in the same size box regardless of its own
                // proportions.
                .frame(width: boxSize ?? size + 12, height: boxSize ?? size + 12)
        }
        // Only the hover caption needs the width, and only `expandable` buttons
        // have one -- every other button skipped a GeometryReader + @State
        // that was re-laid-out on every window resize for nothing.
        .background {
            if expandable {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { buttonWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, w in buttonWidth = w }
                }
            }
        }
        // The caption renders as a non-interactive .overlay positioned by
        // a raw offset, NOT laid out inline inside the button's own
        // HStack. Growing something inline would grow the button's actual
        // frame -- which is exactly what .onHover below is keyed off of --
        // so hovering near the button's original edge would grow it just
        // enough to move that edge out from under the cursor, un-hovering
        // it, shrinking it back, re-hovering it, forever flickering right
        // at the boundary. Overlaying the caption (and disabling its own
        // hit-testing) means the button's interactive bounds never change
        // size at all; only paint extends past them.
        .overlay(alignment: captionExpandsFrom == .trailing ? .trailing : .leading) {
            if expandable, isHovering, !help.isEmpty {
                Text(help)
                    .font(.appMono(size: max(9, size * 0.8), weight: .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundColor(resolvedColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.7))
                    .clipShape(Capsule())
                    .offset(x: captionExpandsFrom == .trailing ? -(buttonWidth + 6) : (buttonWidth + 6))
                    .allowsHitTesting(false)
                    // Insertion-only, like glassPopInOnly/blurInOnly (see AnyTransition's own
                    // "if/else branches" comment): a SYMMETRIC transition here left the caption
                    // visibly stuck mid-fade -- reported live as still ghosting after the
                    // isHovering=false-on-click fix, which addressed a real but secondary risk
                    // (the button's own hover state going stale), not this one. The actual
                    // mechanism: an animated REMOVAL can get interrupted before it finishes
                    // (isHovering flips again, or this card's OWN click also kicks off the
                    // settings-collapse animation competing for the same frames), leaving a
                    // half-blurred, half-scaled frame on screen indefinitely. Removal is now
                    // instant; the fade-in still gets the pleasant animation.
                    .transition(.asymmetric(
                        insertion: .focus(blur: 5, scale: 0.9, opacity: 0.3, anchor: captionExpandsFrom == .trailing ? .trailing : .leading)
                            .animation(.spring(response: 0.25, dampingFraction: 0.85)),
                        removal: .identity
                    ))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: isHovering)
        .onHover { hovering in
            guard expandable, !disabled else { return }
            isHovering = hovering
        }
        .help(help)
        .accessibilityLabelIfPresent(help)
    }
}

/// Unified update button for a single dependency (yt-dlp, ffmpeg). Used as a
/// full row inside the Tools dropdown. Static, non-interactive -- shows the
/// installed version number (or an updating spinner). Updates are now
/// triggered by a single "Check for Updates" button below all the rows,
/// not per-tool.
struct VersionChip: View {
    let version: String
    let isUpdating: Bool
    let isCheckingUpdates: Bool
    let updateAvailable: Bool
    // Interchangeable characteristic: the chip doubles as its own refresh
    // button now (both tools force-update on launch, so there's no
    // separate "Update" button state to react to anymore). Hovering swaps
    // the version text for a refresh glyph; clicking re-fetches the
    // latest nightly for just this tool. nil action falls back to the old
    // static, non-interactive display.
    var refreshAction: (() -> Void)? = nil
    var refreshHelp: String = ""

    @State private var hovering = false

    private var accentColor: Color {
        updateAvailable ? .orange : .white
    }

    // yt-dlp nightly tags look like "2026.08.17.073947" (date + HHMMSS
    // build time) -- the time suffix is just build-run noise, not
    // meaningful to a user glancing at the row, so only the YYYY.MM.DD
    // date is shown. ffmpeg's plain "7.1"-style versions pass through
    // unchanged since they don't match this pattern.
    static func simplify(_ raw: String) -> String {
        let parts = raw.split(separator: ".")
        if parts.count == 4, parts[0].count == 4 {
            return parts[0...2].joined(separator: ".")
        }
        return raw
    }

    private var chipContent: some View {
        Group {
            if isUpdating || isCheckingUpdates {
                ProgressView().scaleEffect(0.5).frame(width: 10, height: 10)
            } else if hovering, refreshAction != nil {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.appMono(size: 10))
            } else {
                HStack(spacing: 4) {
                    Text(version.isEmpty ? "—" : Self.simplify(version))
                        .font(.appMono(size: 9.5, design: .monospaced))
                        .minimumScaleFactor(0.75)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    if updateAvailable {
                        Circle().fill(Color.orange).frame(width: 5, height: 5)
                    }
                }
            }
        }
        // Wide enough for the longest version strings we display -- now
        // just the simplified "2026.08.17" date (build-time suffix
        // dropped in simplify()) -- without clipping; grows from content
        // rather than clamping to a fixed width.
        .frame(minWidth: 58, minHeight: 22)
        .padding(.horizontal, 6)
        .frame(height: 22)
        .foregroundColor(accentColor.opacity(updateAvailable ? DesignTokens.Text.primary : DesignTokens.Text.secondary))
        .background(accentColor.opacity(hovering && refreshAction != nil ? 0.16 : 0.1))
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous)
                .stroke(accentColor.opacity(updateAvailable ? 0.45 : 0.14), lineWidth: 0.5)
        )
    }

    var body: some View {
        Group {
            if let refreshAction {
                Button(action: refreshAction) { chipContent }
                    .buttonStyle(.plain)
                    .disabled(isUpdating || isCheckingUpdates)
                    .onHover { hovering = $0 }
                    .help(refreshHelp)
            } else {
                chipContent
                    .help(updateAvailable ? "Update Available" : "Up to Date")
            }
        }
    }
}

/// Single dependency row inside the Tools dropdown (Homebrew, yt-dlp, ffmpeg).
/// Each installed tool shows a static VersionChip; updates are triggered by
/// the single CheckForUpdatesButton below all rows, not per-row.
struct ToolStatusRow: View {
    let name: String
    let installed: Bool
    let installing: Bool
    let installAction: () -> Void
    var versionChip: AnyView? = nil
    var updateAvailable: Bool = false
    var isUpdating: Bool = false
    var updateAction: (() -> Void)? = nil

    private var iconName: String {
        if !installed { return "exclamationmark.circle.fill" }
        if updateAvailable { return "exclamationmark.triangle.fill" }
        return "checkmark.circle.fill"
    }
    private var iconColor: Color {
        if !installed { return .orange.opacity(0.85) }
        if updateAvailable { return .yellow.opacity(0.9) }
        return .green.opacity(0.85)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.appMono(size: 11))
                .foregroundColor(iconColor)
            Text(name)
                .font(.appMono(size: 11.5, weight: .medium))
                .foregroundColor(.white.opacity(DesignTokens.Text.secondary))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 12)
            if installed, updateAvailable, let updateAction {
                GlassButton(
                    label: "Update",
                    icon: "arrow.triangle.2.circlepath",
                    tint: .yellow,
                    fitContent: true,
                    isLoading: isUpdating,
                    disabled: isUpdating
                ) {
                    updateAction()
                }
                .help("Update \(name)")
            } else if let versionChip, installed {
                // Both tools now force-update to their latest nightly build
                // on every launch, so updateAvailable is always false here.
                // The chip itself (constructed with a refreshAction by the
                // caller) doubles as the manual re-fetch control -- hover
                // swaps the version text for a refresh glyph.
                versionChip
            } else if !installed {
                GlassButton(
                    label: "Install",
                    icon: "arrow.down.circle",
                    tint: .orange,
                    fitContent: true,
                    isLoading: installing,
                    disabled: installing
                ) {
                    installAction()
                }
                .help("Install \(name)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Always-visible tools section in the sidebar showing yt-dlp/ffmpeg
/// versions and update state. Both tools are bundled inside the app, so
/// there's no install flow -- this is purely a version/update surface.
/// No toggle, no popover -- the rows are simply part of the rail at all
/// times, pinned to the bottom via the Spacer() above this in `sidebar`.
struct ToolsStatusPill: View {
    @ObservedObject var manager: DownloadManager
    /// First domino index this block's own rows should use -- see
    /// AnyTransition.dominoPop. Defaults to 0 (no stagger) so a future
    /// standalone/popover usage isn't accidentally delayed; the sidebar's
    /// own call site passes 7 to continue the sequence after the nav pills.
    var baseIndex: Int = 0
    /// Mirrors ContentView.sidebarRowsHidden -- see ToolsDropdownContent's
    /// own rowsHidden for why this has to reach all the way down to each
    /// individual row instead of gating this whole view from the outside.
    var rowsHidden: Bool = false

    var body: some View {
        ToolsDropdownContent(manager: manager, dropDriver: manager.dropUpdater.userDriver, baseIndex: baseIndex, rowsHidden: rowsHidden)
    }
}

/// The logo and "Drop" in the sidebar's header; the name types itself out when
/// the sidebar opens (see TypedText).
struct SidebarBrandLabel: View {
    var body: some View {
        HStack(spacing: 7) {
            DropMark(height: 16)
                .foregroundColor(DesignTokens.Accent.primary)
            TypedText("Drop")
                .font(.appMono(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(DesignTokens.Text.primary))
        }
    }
}

/// One tool in the sidebar's update block, built like a tab button: a pill with
/// an icon that never moves (it sits where the tab icons do), the name typed out
/// beside it when the sidebar opens, and the version as a badge at the trailing
/// edge, styled like the tab counters. Collapsed, it is just the icon -- with a
/// small orange dot in the corner when that tool has an update, exactly as the
/// tab counters shrink to a dot -- and the version moves to the tooltip. There
/// is no per-row check mark: one badge on the Check for Updates button says
/// whether everything is current.
struct SidebarToolRow: View {
    let name: String
    let icon: String
    let updateAvailable: Bool
    /// Raw version string.
    let version: String
    @Environment(\.isCompactSidebar) private var compact

    private var shownVersion: String { version.isEmpty ? "—" : VersionChip.simplify(version) }
    private var badgeColor: Color { updateAvailable ? .orange : .white }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.appMono(size: 11))
                .frame(width: WindowLayout.railIconSlot)
                .accessibilityHidden(true)
            if !compact {
                TypedText(name)
                    .font(.appMono(size: 11, weight: .medium))
                    .lineLimit(1)
                    .transition(.labelFade)
                Spacer(minLength: 0)
                Text(shownVersion)
                    .font(.appMono(size: 9, weight: .semibold))
                    .lineLimit(1)
                    .foregroundColor(updateAvailable ? .orange : .white.opacity(DesignTokens.Text.secondary))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(badgeColor.opacity(updateAvailable ? 0.14 : 0.08))
                    .clipShape(Capsule())
                    .transition(.blurInLeading)
            }
        }
        // One fixed content height, so the pill is exactly as tall collapsed (the
        // bare icon) as open (typed name and version badge, which are taller than
        // the icon) -- it never shrinks when the sidebar collapses.
        .frame(height: 17)
        .foregroundColor(.white.opacity(DesignTokens.Text.secondary))
        // The icon sits exactly where the tab icons do.
        .padding(.leading, WindowLayout.railIconInset)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .background(Capsule().fill(Color.white.opacity(0.04)))
        // A little quieter than the tabs' rim (they are buttons; these are readouts).
        .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 0.75))
        // Collapsed, the badge is gone with the label: a dot says a tool needs an update.
        .overlay(alignment: .topTrailing) {
            if compact, updateAvailable {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(Color.black, lineWidth: 2))
                    .padding(.top, 2).padding(.trailing, 8)
                    .transition(.blurIn)
                    .allowsHitTesting(false)
            }
        }
        .help(version.isEmpty ? name : "\(name) \(version)\(updateAvailable ? " — Update Available" : "")")
        .accessibilityElement(children: .combine)
    }
}

/// The sidebar's update block: a status row per bundled tool (yt-dlp, ffmpeg,
/// Drop itself) and the single button that checks all of them. Built once for
/// every sidebar width -- see SidebarToolRow -- and pinned to the bottom of the
/// rail by the Spacer() above it in `sidebar`.
struct ToolsDropdownContent: View {
    @ObservedObject var manager: DownloadManager
    // manager.dropUpdater.userDriver is a *nested* ObservableObject --
    // SwiftUI does not propagate its @Published changes through `manager`'s
    // own objectWillChange automatically, so a view that only observes
    // `manager` can silently miss (or only pick up, inconsistently, whenever
    // something else happens to trigger a re-render) every stage/
    // justConfirmedUpToDate change from the driver. Observing it directly
    // here is what makes those changes reliably reactive.
    @ObservedObject var dropDriver: DropCustomUserDriver
    /// First domino index this block's own rows should use -- see
    /// AnyTransition.dominoPop and ToolsStatusPill.
    var baseIndex: Int = 0
    /// Mirrors ContentView.sidebarRowsHidden. Each row below carries its OWN
    /// `.dominoVisibility(hidden: rowsHidden, index:)` and stays mounted the
    /// whole time (shrunk to a point + blurred while hidden) rather than
    /// being removed with `.transition`: this block is pinned to the bottom
    /// of the sidebar, so mounting/unmounting rows changes its height and
    /// slides its top edge, dragging every row with it instead of each one
    /// popping in place (see DominoVisibility).
    var rowsHidden: Bool = false
    @Environment(\.isTinyHeight) private var tiny

    var body: some View {
        if tiny {
            // No room for the version readouts in a very short window; the
            // update button is the one control worth keeping.
            checkForUpdatesButton
                .dominoVisibility(hidden: rowsHidden, index: baseIndex)
        } else {
            // Each row is a static status readout -- no per-tool click target.
            // Checking/updating happens in exactly one place, the single
            // button below, so there's no ambiguity about whether clicking a
            // specific row's chip silently kicked off its own separate check.
            // Chips show no per-row spinner: yt-dlp's download, ffmpeg's
            // download, the local re-verify pass and Sparkle's own network
            // check are independent async operations that were never going
            // to start/stop in sync, so separately-flickering spinners just
            // read as broken. The button's single "Checking…" state covers
            // the whole operation; each chip updates in place when its own
            // piece finishes.
            // Each tool is a tab-style pill and its own domino step. The pills and
            // the button sit straight on the sidebar, 6pt apart like the tabs
            // above, at the same edge inset -- no card around them.
            VStack(alignment: .leading, spacing: 6) {
                toolRow("yt-dlp", icon: "arrow.down.to.line", updateAvailable: manager.updateAvailable,
                        version: manager.ytdlpVersion)
                    .dominoVisibility(hidden: rowsHidden, index: baseIndex)
                toolRow("ffmpeg", icon: "film", updateAvailable: manager.ffmpegUpdateAvailable,
                        version: manager.ffmpegVersion)
                    .dominoVisibility(hidden: rowsHidden, index: baseIndex + 1)
                toolRow("Drop", icon: "drop.fill", updateAvailable: dropDriver.hasActionableUpdate,
                        version: manager.currentAppVersion)
                    .dominoVisibility(hidden: rowsHidden, index: baseIndex + 2)
                checkForUpdatesButton
                    .dominoVisibility(hidden: rowsHidden, index: baseIndex + 3)
            }
            .padding(.top, 4)
        }
    }

    private func toolRow(_ name: String, icon: String, updateAvailable: Bool, version: String) -> some View {
        SidebarToolRow(
            name: name,
            icon: icon,
            updateAvailable: updateAvailable,
            version: version
        )
    }

    private var checkForUpdatesButton: some View {
        CheckForUpdatesButton(
            isChecking: manager.checkingUpdates || dropDriver.isActivelyChecking,
            hasUpdate: manager.updateAvailable || manager.ffmpegUpdateAvailable || dropDriver.hasActionableUpdate,
            isUpToDate: manager.justCheckedUpToDate && dropDriver.justConfirmedUpToDate,
            // Everything current: the tools are installed and none of the three
            // (yt-dlp, ffmpeg, Drop) has an update waiting.
            allUpToDate: manager.toolsReady && !manager.updateAvailable && !manager.ffmpegUpdateAvailable && !dropDriver.hasActionableUpdate,
            disabledUntilSetup: !manager.toolsReady,
            action: {
                // The one place all three checks actually run now --
                // yt-dlp/ffmpeg's nightly fetch plus Drop's own Sparkle
                // check, previously reachable individually per-row.
                manager.ensureLatestTools()
                manager.dropUpdater.checkForUpdates()
            }
        )
    }
}

/// Single button below the tool rows that triggers a version/update check
/// for both bundled tools at once. One view at every sidebar width: a capsule
/// that fills the row, its icon fixed on the rail (where the tab icons are), its
/// label typed out beside it as the sidebar widens, and ONE status badge at the
/// trailing edge (a check when everything is up to date, an exclamation mark when
/// something needs attention) -- placed and styled like the count badges on the
/// tab buttons, and shrinking to a corner dot in the collapsed rail the same way.
struct CheckForUpdatesButton: View {
    let isChecking: Bool
    let hasUpdate: Bool
    // True once the most recently completed check cycle confirmed
    // everything current -- cleared the instant a new check starts, so it
    // can never linger from a stale previous result.
    var isUpToDate: Bool = false
    /// yt-dlp, ffmpeg and Drop are all installed and none has an update.
    var allUpToDate: Bool = false
    var disabledUntilSetup: Bool = false
    let action: () -> Void
    @Environment(\.isCompactSidebar) private var compact
    /// What the label and tint actually show. `isUpToDate` stays true until the next check
    /// starts, so on its own "Up to Date" would sit there indefinitely; this follows it for
    /// a few seconds and then lets the button rest back on "Check for Updates" (the green
    /// check badge, driven by `allUpToDate`, keeps saying everything is current).
    @State private var upToDateShown = false
    private static let upToDateHold: UInt64 = 4_000_000_000

    /// The badge: nothing while a check runs.
    private var statusBadge: (icon: String, color: Color)? {
        if isChecking { return nil }
        if disabledUntilSetup || hasUpdate { return ("exclamationmark", .orange) }
        if allUpToDate { return ("checkmark", DesignTokens.Accent.success) }
        return nil
    }

    private var accentColor: Color {
        if hasUpdate { return .orange }
        if upToDateShown { return DesignTokens.Accent.success }
        return .white
    }
    private var tint: Color {
        disabledUntilSetup ? Color.white.opacity(DesignTokens.Text.secondary) : accentColor
    }
    // Also disabled while "Up to Date" is showing: clicking through it used to
    // flash the label back to "Check for Updates" for a frame before jumping
    // to "Checking…" (reported live), since a fresh check clears upToDateShown
    // asynchronously, one step behind isChecking turning true. Simplest fix is
    // to not allow that click at all -- wait for the timed hold in
    // upToDateShown's own `.task` to clear it, then allow clicking again.
    private var isDisabled: Bool { isChecking || disabledUntilSetup || upToDateShown }
    private var labelText: String {
        isChecking ? "Checking…" : (disabledUntilSetup ? "Tools Missing" : (hasUpdate ? "Update Available" : (upToDateShown ? "Up to Date" : "Check for Updates")))
    }
    var body: some View {
        // Sits straight on the sidebar now (no card behind it), so its rim is a
        // little stronger than the default, like the tab buttons'.
        GlassInteractive(shape: .capsule, tint: tint, isActive: false, disabled: isDisabled,
                         scaleOverride: (hover: 1.0, press: DesignTokens.Interactive.scalePress),
                         restStrokeOverride: 0.24, action: action) {
            HStack(spacing: 6) {
                Group {
                    if isChecking {
                        // frame BEFORE scaleEffect so the layout box is set first
                        // and the shrunk spinner can't bleed past it.
                        ProgressView().frame(width: 10, height: 10).scaleEffect(0.55)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.appMono(size: 11))
                    }
                }
                .frame(width: WindowLayout.railIconSlot)
                if !compact {
                    TypedText(labelText)
                        .font(.appMono(size: 11, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .transition(.labelFade)
                    Spacer(minLength: 0)
                    if let badge = statusBadge {
                        Image(systemName: badge.icon)
                            .font(.appMono(size: 9, weight: .bold))
                            .foregroundColor(badge.color)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(badge.color.opacity(0.14))
                            .clipShape(Capsule())
                            .transition(.blurInLeading)
                    }
                }
            }
            // Same fixed content height as the tool pills above and the tab
            // buttons: the badge is taller than the icon, and the button must not
            // shrink when it goes away.
            .frame(height: 17)
            .padding(.leading, WindowLayout.railIconInset)
            .padding(.trailing, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
        // Shows "Up to Date" for a few seconds after a check confirms it, then rests
        // back on "Check for Updates". Restarts (and cancels the wait) whenever a new
        // check flips `isUpToDate`.
        .task(id: isUpToDate) {
            upToDateShown = isUpToDate
            guard isUpToDate else { return }
            try? await Task.sleep(nanoseconds: Self.upToDateHold)
            if !Task.isCancelled { upToDateShown = false }
        }
        // Collapsed, the badge is gone with the label -- a small dot in the
        // corner says the same thing, exactly as on the tab buttons.
        .overlay(alignment: .topTrailing) {
            if compact, let badge = statusBadge {
                Circle()
                    .fill(badge.color)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(Color.black, lineWidth: 2))
                    .padding(.top, 4).padding(.trailing, 10)
                    .transition(.blurIn)
                    .allowsHitTesting(false)
            }
        }
        .help(compact ? labelText : (disabledUntilSetup ? HelpText.toolsMissing : ""))
        .accessibilityLabel(labelText)
    }
}

/// Thin separator with glass look
struct GlassDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(height: 0.5)
    }
}

/// Same hairline as GlassDivider, turned 90 degrees -- stretches to fill whatever height its
/// container offers (a card header row, say), rather than GlassDivider's own full-width/fixed-
/// height shape.
struct VerticalGlassDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 0.5)
            .frame(maxHeight: .infinity)
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = DesignTokens.Radius.large, opacity: Double = 0.55, isActive: Bool = false, rimAnchoredToBottom: Bool = false) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius, opacity: opacity, rimAnchoredToBottom: rimAnchoredToBottom, isActive: isActive))
    }
}
