import SwiftUI
import AppKit
import QuickLookThumbnailing

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

// MARK: - Icon Button

/// Same shape/role as HoverIconButton in Drop.swift (icon-only control),
/// kept as a distinct type only because call sites live in the download row
/// context and pass a fixed 26x26 frame. Rebuilt on GlassInteractive so it
/// finally gets the shared black-frosted material and glow instead of a
/// flat white wash with no blur.
struct IconButton: View {
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        GlassInteractive(shape: .roundedRect(DesignTokens.Radius.small), tint: color, action: action) {
            Image(systemName: icon)
                .font(.appMono(size: 11))
                .frame(width: 26, height: 26)
        }
    }
}

// MARK: - Log View

struct LogView: View {
    let logs: [String]
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
        // Capped at the same 864pt width as urlCard/dropZoneView (Download/
        // Convert's reference bar) and centered, instead of stretching to
        // fill the page -- otherwise this capsule reads as a different,
        // wider size than every other tab's header bar.
        .frame(maxWidth: 864)
        .frame(maxWidth: .infinity)
        .shadow(color: .black.opacity(DesignTokens.Interactive.glowShadowPeak), radius: 10, y: 4)
    }

    var body: some View {
        VStack(spacing: 12) {
            logHeader
                .padding(.horizontal, 16)
                .padding(.top, 40)
                .padding(.bottom, 20)

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

// MARK: - Tab Chip

/// Top-level tab selector (Download / Convert / History). Rebuilt on
/// GlassInteractive -- same capsule shape, glow, and accent blue as every
/// other selected/active control in the app, instead of its own bespoke
/// hover+glow state machine.
struct TabChip: View {
    let label: String
    let icon: String
    let isSelected: Bool
    var badge: String? = nil
    let action: () -> Void

    private static let accent = DesignTokens.Accent.primary

    var body: some View {
        GlassInteractive(shape: .capsule, tint: Self.accent, isActive: isSelected, action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.appMono(size: 11))
                Text(label).font(.appMono(size: 12, weight: .medium))
                if let badge = badge {
                    // Accent-tinted glass, matching every other badge/chip in
                    // the app (AV1, AAC, native/re-encode dots) -- previously
                    // this used a plain white fill which, at this small a
                    // size, read as a solid white circle instead of the same
                    // translucent glass language everything else uses.
                    Text(badge)
                        .font(.appMono(size: 9, weight: .semibold))
                        .foregroundColor(isSelected ? Self.accent : .white.opacity(DesignTokens.Text.secondary))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Self.accent.opacity(isSelected ? 0.22 : 0.14))
                        .clipShape(Capsule())
                }
            }
            // Fixed height keeps Download/Convert/History the same size
            // regardless of History's badge — without this, the badge's extra
            // vertical padding made that one chip visibly taller than its
            // siblings. 16 matches the natural height of the badge-less
            // content. Width is left natural (not fixed) per design intent.
            .frame(height: 16)
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }
}

// MARK: - Sidebar Tab Item

/// Vertical nav-rail row for the sidebar (Download / Convert / History).
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
                    .font(.appMono(size: 13))
                Text(label)
                    .font(.appMono(size: 13, weight: isSelected ? .semibold : .medium))
                if let badge = badge {
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
            .frame(width: 216, alignment: .center)
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
    }
}

