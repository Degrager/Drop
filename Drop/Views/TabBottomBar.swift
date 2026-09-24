import SwiftUI
import AppKit

// MARK: - TabBottomBar
//
// Shared bottom bar used by both the Download and Convert tabs.
//
// Shared chrome (always rendered when hasItems == true):
//   • Top row: leftControls (COOKIES FROM) + Clear All button
//   • Extra controls row: SAVE TO field + AUTO-OPEN FOLDER toggle
//   • Primary action button (Download / Convert)
//   • Top separator + material background
//
// Tab-specific content injected via @ViewBuilder slots:
//   • leftControls  — Download: COOKIES FROM picker. Convert: empty.
//   • extraControls — Download: SAVE TO field (Auto-Open toggle renders alongside it automatically). Convert: empty.
//
// NOTE: the input area (URL paste field / drop zone) no longer lives here —
// it now renders above the toolbar, at the top of each tab's main panel.
//
// Usage (download):
//   TabBottomBar(config: config, hasItems: !linkPreviews.isEmpty,
//                primaryActionLabel: "Download as MP3", primaryActionIcon: "arrow.down.circle",
//                onClearAll: { ... }, onPrimaryAction: { download() }) {
//       cookiesPicker   // leftControls
//   } extraControls: {
//       saveToField     // extraControls
//   }
//
// Usage (convert):
//   TabBottomBar(config: config, hasItems: hasJobs,
//                primaryActionLabel: "Convert Audio", primaryActionIcon: "arrow.triangle.2.circlepath",
//                showPrimaryAction: hasSelectedQueued,
//                onClearAll: { jobs.removeAll() }, onPrimaryAction: { convertSelected() }) {
//       EmptyView()
//   } extraControls: {
//       EmptyView()
//   }

struct TabBottomBar<LeftControls: View, ExtraControls: View, BatchDirectoryControl: View>: View {

    // Shared state
    @ObservedObject var config: Config

    // Visibility
    var hasItems: Bool
    var showPrimaryAction: Bool = true

    // Gate — when false, primary action is disabled/greyed and shows a setup hint
    var toolsReady: Bool = true

    /// When false, the primary action button stays visible but is disabled
    /// and shows `primaryActionDisabledLabel` instead of `primaryActionLabel`.
    /// Used by Convert's Select mode so the button doesn't disappear while
    /// nothing is checked — it just greys out instead.
    var primaryActionEnabled: Bool = true
    var primaryActionDisabledLabel: String? = nil
    /// Icon shown while disabled-but-visible for a reason OTHER than
    /// !toolsReady (which always forces "lock.fill" regardless of this).
    /// Defaults to primaryActionIcon so callers that don't need a distinct
    /// disabled icon see no change in behavior.
    var primaryActionDisabledIcon: String? = nil
    /// When true, the primary action button swaps entirely into a "stop
    /// everything in progress" control -- red instead of the normal accent
    /// gradient, always enabled, label/icon overridden below. Used by
    /// Convert while any job is actively converting: there's no more
    /// per-row Cancel button (removed in favor of this single one), so
    /// this is the only way to stop a run in progress.
    var primaryActionDangerMode: Bool = false
    /// Same Tron-style traveling light beam used on the Analyze card's rim
    /// (see GlassCard.isActive/RimBeam) -- true while the work this button
    /// represents (a conversion, a download) is actively running, not
    /// merely available. Independent of primaryActionDangerMode: Convert's
    /// danger mode and "in progress" happen to coincide (isConverting
    /// drives both), but Download has no danger/cancel-all mode at all and
    /// still needs its own "actively downloading" signal.
    var primaryActionInProgress: Bool = false

    // Primary action button
    var primaryActionLabel: String
    var primaryActionIcon: String
    var onClearAll: () -> Void
    var onPrimaryAction: () -> Void
    /// Label for the trash button. Defaults to "Clear All"; Convert tab swaps
    /// this to "Clear Selected" while Batch Apply mode is active.
    var clearAllLabel: String = "Clear All"
    /// When false, hides this bar's own Clear All button entirely. Convert
    /// tab moved Clear All (and its Select mode button) up into its own
    /// header row above the card list, so it hides both here to avoid a
    /// duplicate control.
    var showClearAll: Bool = true
    /// The bar's width and vertical density come from the shared window
    /// layout (see WindowLayout), so it always matches the rows above it.
    @Environment(\.contentColumnWidth) private var columnWidth
    @Environment(\.isCompactHeight) private var compactHeight
    /// False lets a tab skip the extra-controls slot (and its divider) when it
    /// has nothing worth showing -- Convert's queue drawer, when the queue is
    /// empty. The `is EmptyView` check below can't detect that on its own.
    var showExtraControls: Bool = true
    /// Whether `batchDirectoryControl` is actually rendering visible content
    /// right now (vs. an EmptyView placeholder). Passed explicitly by the
    /// caller because `@ViewBuilder`'s `if/else` produces a
    /// `_ConditionalContent` wrapper type, not a literal `EmptyView` — so a
    /// runtime `is EmptyView` check on the built view never actually matches
    /// and can't be used to detect this.
    var hasBatchDirectoryControl: Bool = false

    // Hover state for the primary action button -- this button is
    // deliberately the one solid (non-glass) control in the app, so it
    // can't just reuse GlassButton/GlassInteractive's built-in hover
    // handling. Previously had zero .onHover wiring at all, so hovering
    // it produced no feedback whatsoever.
    @State private var primaryActionHovering = false

    // Slots
    @ViewBuilder var leftControls: () -> LeftControls
    @ViewBuilder var extraControls: () -> ExtraControls
    /// Inline control rendered in the top row, immediately to the right of the
    /// Auto-Open Folder toggle (and before the Spacer/Clear All button). Used by
    /// Select mode's batch SAVE TO directory field on both Download and Convert —
    /// keeps it out of the extraControls row below so it sits at-a-glance next to
    /// the other per-run settings instead of inside its own card.
    @ViewBuilder var batchDirectoryControl: () -> BatchDirectoryControl

    private var narrow: Bool { columnWidth > 0 && columnWidth < WindowLayout.barStackBreakpoint }

    /// Auto-open Folder as one compact chip: lit blue when on, plain when off.
    /// (It used to be an icon, "AUTO-OPEN", "On"/"Off" and a switch -- about
    /// 200pt for one setting.) The tooltip says what it does.
    private var autoOpenToggle: some View {
        GlassInteractive(
            shape: .capsule,
            tint: config.autoOpenFolder ? DesignTokens.Accent.primary : .white,
            isActive: config.autoOpenFolder,
            action: { config.autoOpenFolder.toggle() }
        ) {
            HStack(spacing: 5) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.appMono(size: 11, weight: .semibold))
                Text("Auto-open")
                    .font(.appMono(size: 10.5, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .frame(height: DropGrid.controlHeight)
        }
        .fixedSize()
        .help(config.autoOpenFolder
              ? "Auto-open is on: the save folder opens when a run finishes"
              : "Auto-open is off: click to open the save folder when a run finishes")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Settings area — only when there are items. Floats as its own
            // card, inset and rounded like every other section (media card,
            // list header, paste bar) instead of docking flush to the
            // window's edges with no margin -- previously this was the one
            // section that broke the app's card-based language.
            if hasItems {
                VStack(spacing: compactHeight ? 8 : 10) {

                    // The grey inner card: everything that isn't the primary
                    // action. Convert's queue sits at the top (its slot is
                    // `extraControls`), a divider line separates it from the
                    // destination row below -- so it reads as "queue, then
                    // destination" top to bottom. Download never populates the
                    // queue slot, so its card is just the destination row.
                    VStack(alignment: .leading, spacing: compactHeight ? 8 : 10) {
                        let extra = extraControls()
                        if showExtraControls && !(extra is EmptyView) {
                            extra
                            GlassDivider()
                        }

                        // In a narrow column the toggle and the folder field can't share
                        // one row without the field collapsing, so they stack.
                        if narrow {
                            VStack(alignment: .leading, spacing: 8) {
                                leftControls()
                                    .frame(height: DropGrid.controlHeight)
                                batchDirectoryControl()
                                autoOpenToggle
                                if showClearAll {
                                    GlassButton(label: clearAllLabel, icon: "trash", tint: .red, fillHeight: true, action: onClearAll)
                                        .frame(height: DropGrid.controlHeight)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            // The destination (folder, Browse, Reveal), a divider,
                            // then the Auto-Open Folder toggle. All controls in the
                            // row share DropGrid.controlHeight so nothing sits a
                            // pixel off from its neighbor.
                            HStack(alignment: .center, spacing: DropGrid.rowSpacing + 4) {
                                leftControls()
                                    .frame(height: DropGrid.controlHeight)

                                batchDirectoryControl()
                                    .layoutPriority(1)

                                Rectangle()
                                    .fill(Color.white.opacity(0.14))
                                    .frame(width: 0.75, height: DropGrid.controlHeight - 8)

                                autoOpenToggle

                                if showClearAll {
                                    Spacer(minLength: 0)
                                    GlassButton(label: clearAllLabel, icon: "trash", tint: .red, fillHeight: true, action: onClearAll)
                                        .frame(width: DropGrid.buttonColumnWidth, height: DropGrid.controlHeight)
                                }
                            }
                        }
                    }
                    .padding(8)
                    .innerCard()

                    // Primary action button.
                    // Deliberately the ONE control in the entire app that isn't glass --
                    // a solid accent-blue gradient instead of the translucent Interactive
                    // fills everything else uses. This is the strongest form of functional
                    // differentiation available: the single most important commit action
                    // per tab (Download / Convert) must outrank every chip, toggle, and
                    // chrome button around it at a glance. Radius/spacing still pull from
                    // DesignTokens so it stays proportionally consistent with the rest of
                    // the UI even while its material language differs on purpose.
                    if showPrimaryAction {
                        // Danger mode is always enabled (you can always
                        // cancel) and ignores toolsReady/primaryActionEnabled
                        // entirely -- it's a different control, not a
                        // disabled/enabled variant of the normal one.
                        let enabled = primaryActionDangerMode || (toolsReady && primaryActionEnabled)
                        // Hover only registers real feedback while actually
                        // enabled -- a disabled button greying out further
                        // on hover would read as broken/inconsistent rather
                        // than helpful, so the glow/scale bump is reserved
                        // for the clickable state only.
                        let hovering = enabled && primaryActionHovering
                        let accentColor = primaryActionDangerMode ? DesignTokens.Accent.danger : DesignTokens.Accent.primary
                        Button(action: onPrimaryAction) {
                            HStack(spacing: 8) {
                                Image(systemName: primaryActionDangerMode ? "stop.fill" : (!toolsReady ? "lock.fill" : (enabled ? primaryActionIcon : (primaryActionDisabledIcon ?? primaryActionIcon))))
                                    .font(.appMono(size: 15, weight: .semibold))
                                // Keyed on the string so a label change (mode switch,
                                // Download -> Cancel All) blurs one label out and the next
                                // in, in place, rather than SwiftUI cross-fading two
                                // overlapping strings.
                                let label = primaryActionDangerMode ? "Cancel All" : (!toolsReady ? "Setup Needed" : (enabled ? primaryActionLabel : (primaryActionDisabledLabel ?? primaryActionLabel)))
                                ZStack {
                                    Text(label)
                                        .font(.appMono(size: 15, weight: .semibold))
                                        .id(label)
                                        .transition(.blurIn)
                                }
                                .animation(.easeOut(duration: 0.2), value: label)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, compactHeight ? 8 : 11)
                            .background(
                                RoundedRectangle(cornerRadius: DesignTokens.Radius.medium, style: .continuous)
                                    .fill(enabled ?
                                        LinearGradient(
                                            // Brightens slightly on hover -- same two-stop
                                            // gradient, just nudged toward a lighter blue
                                            // (or red, in danger mode) rather than swapping
                                            // in a translucent glass wash (this button
                                            // intentionally stays solid).
                                            colors: primaryActionDangerMode
                                                ? (hovering
                                                    ? [Color(red: 1.0, green: 0.42, blue: 0.38), Color(red: 0.85, green: 0.18, blue: 0.16)]
                                                    : [DesignTokens.Accent.danger, Color(red: 0.70, green: 0.12, blue: 0.12)])
                                                : (hovering
                                                    ? [Color(red: 0.30, green: 0.58, blue: 1.0), Color(red: 0.16, green: 0.46, blue: 0.98)]
                                                    : [DesignTokens.Accent.primary, Color(red: 0.10, green: 0.38, blue: 0.90)]),
                                            startPoint: .topLeading, endPoint: .bottomTrailing
                                        ) :
                                        LinearGradient(
                                            colors: [Color.white.opacity(DesignTokens.Interactive.fillRest), Color.white.opacity(DesignTokens.Interactive.fillRest)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing
                                        )
                                    )
                                    .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium, style: .continuous)
                                        .stroke(enabled ? Color.white.opacity(hovering ? 0.85 : DesignTokens.Interactive.strokeHover) : Color.white.opacity(DesignTokens.Interactive.strokeDisabled), lineWidth: 0.75))
                                    .shadow(color: enabled ? accentColor.opacity(hovering ? 0.6 : 0.4) : .clear, radius: hovering ? 16 : 12, y: 4)
                            )
                            .foregroundColor(enabled ? .white.opacity(DesignTokens.Text.primary) : .white.opacity(DesignTokens.Text.disabled))
                        }
                        .buttonStyle(.plain)
                        .disabled(!enabled)
                        .help(!toolsReady ? "Install yt-dlp and ffmpeg from the Tools menu first" : "")
                        .onHover { h in
                            withAnimation(.easeOut(duration: 0.18)) {
                                primaryActionHovering = h
                            }
                        }
                        .animation(.easeOut(duration: 0.18), value: hovering)
                        .overlay {
                            if primaryActionInProgress {
                                RimBeam(cornerRadius: DesignTokens.Radius.medium)
                            }
                        }
                    }

                }
                .padding(.horizontal, 12)
                .padding(.vertical, compactHeight ? 8 : 12)
                .glassCard(cornerRadius: DesignTokens.Radius.xlarge)
                .shadow(color: .black.opacity(DesignTokens.Interactive.glowShadowPeak), radius: 10, y: 4)
                .contentColumn()
                .padding(.bottom, compactHeight ? 8 : 14)
                .transition(.glassBar(anchor: .bottom))
            }
        }
    }
}
