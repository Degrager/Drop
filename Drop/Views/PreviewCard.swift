import SwiftUI
import AppKit

// Reports a view's own rendered width up through the view tree -- used to
// size the title skeleton bar to match the real, resolved title Text's
// width instead of a hardcoded guess.
private struct WidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

// MARK: - Shared card chrome
//
// Both PreviewCard and CompletedCard share the same header row:
// checkbox · thumbnail · title + subtitle · remove button.
// The only difference is the body below the header.
//
//  PreviewCard   — item is queued / waiting. Shows settings rows
//                  (format pickers, codec chips, etc.) via @ViewBuilder.
//
//  CompletedCard — item is active, done, or failed. Shows status +
//                  action buttons via @ViewBuilder.

// MARK: - PreviewCard

/// Universal settings card. Used before a download starts or while
/// a convert job is queued. The `settings` slot receives tab-specific
/// sections (DOWNLOAD AS / RESOLUTION / AUDIO CODEC / VIDEO CODEC …).
struct PreviewCard<Settings: View>: View {

    // Chrome
    var isSelected: Bool
    var onToggleSelect: () -> Void
    var onRemove: () -> Void
    /// Hides the selection checkbox entirely when false. Defaults to true so
    /// existing call sites (Download tab) keep the always-visible checkbox.
    /// Convert tab passes false outside Batch Apply mode.
    var showCheckbox: Bool = true
    var thumbnail: AnyView?
    var thumbnailPlaceholder: String = "doc"
    var title: String
    var subtitle: AnyView?          // duration, size, video/audio badge…

    /// Extra always-visible row rendered below the header but OUTSIDE
    /// cardHeader's own HStack -- e.g. Download's Video+Audio/Audio Only
    /// mode toggle. Kept separate from `subtitle` so its height never
    /// factors into the thumbnail's vertical centering against the
    /// title/subtitle group; it always renders full-width beneath both.
    var belowHeader: AnyView? = nil

    /// Optional collapse control for the settings section below the header.
    /// When nil, the card always shows settings expanded (unchanged default
    /// behavior for call sites that don't opt in, e.g. Download today).
    var isExpanded: Binding<Bool>? = nil

    /// When true, the collapse/show toggle button is hidden entirely instead
    /// of being rendered as a no-op. Convert tab sets this while Select mode
    /// is active, since settings are force-collapsed and shouldn't offer a
    /// button that looks tappable but does nothing.
    var collapseLocked: Bool = false

    /// When false, cardHeader does NOT render its own CollapseToggleButton --
    /// the call site is placing it elsewhere instead (Download puts it on
    /// the same line as its Video+Audio/Audio Only mode toggle, inside
    /// belowHeader). Convert has no mode-toggle row to share a line with,
    /// so it keeps the default `true` and the button stays in the header.
    var collapseButtonInHeader: Bool = true

    /// When true, this card is still being analyzed (yt-dlp/oEmbed hasn't
    /// resolved yet) -- cardHeader shows the skeleton thumbnail/redacted
    /// title bar/"Analyzing…"/spinner-cancel treatment instead of the real
    /// thumbnail, title, checkbox, and remove button, and belowHeader/
    /// settings stay hidden below. Everything else about this PreviewCard
    /// instance (its identity in a ForEach, its glassCard chrome) stays
    /// exactly the same as it flips to false once analyze completes --
    /// this is what used to be a completely separate AnalyzingCard view
    /// swapped in/out via if/else, which meant SwiftUI unmounted the whole
    /// analyzing view and mounted a brand new PreviewCard the instant a
    /// result landed (jarring, especially with several cards resolving
    /// close together -- they all appeared to "pop in" at once rather than
    /// smoothly settling one at a time). Folding both states into one
    /// PreviewCard means the header's content just updates in place.
    var isAnalyzing: Bool = false
    /// Cancel action while isAnalyzing is true (terminates the yt-dlp
    /// process / clears the queued slot for this specific card). Ignored
    /// when isAnalyzing is false -- onRemove is used instead.
    var onCancelAnalyze: () -> Void = {}

    // Settings content
    @ViewBuilder var settings: () -> Settings

    // Mirrors AnalyzingCard's own reveal gate -- a brief minimum "redacted"
    // hold before the real thumbnail/title are allowed to show, even if
    // they're already known instantly (e.g. redownloading from History).
    @State private var revealTimerElapsed = false
    // Drives the slow pulse on the title's redacted skeleton bar while
    // analyzing -- mirrors the old standalone TitleSkeletonBar's own pulse.
    @State private var titleSkeletonPulse = false
    // Measured width of the real title Text once it has actual content --
    // the skeleton bar sizes itself to this instead of a fixed guess, so it
    // reads as a placeholder for THIS title rather than a generic bar.
    // Falls back to a reasonable default (below) until a title arrives.
    @State private var measuredTitleWidth: CGFloat = 0

    private var expanded: Bool { isExpanded?.wrappedValue ?? true }

    var body: some View {
        fullCard
            .onAppear {
                if isAnalyzing {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                        revealTimerElapsed = true
                    }
                }
            }
    }

    // MARK: Full card

    private var fullCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            cardHeader
            if !isAnalyzing {
                if let belowHeader {
                    belowHeader.transition(.blurInTop)
                }
                if expanded {
                    GlassDivider().transition(.blurInTop)
                    settings().transition(.blurInTop)
                }
            }
        }
        // De-emphasise unselected cards in batch-select mode by dimming the
        // CONTENT only. Opacity on the card itself would dilute the glass tint
        // and turn the surface into a flat grey slab (see FocusEffect).
        .opacity((showCheckbox && !isSelected) ? 0.6 : 1.0)
        .padding(16)
        // Match the 60%-of-window proportional width every other row in
        // the queue (list header, bottom bar) explicitly stretches to --
        // without this the card just hugs its own content and reads
        // narrower than everything else stacked above/below it.
        .frame(maxWidth: .infinity, alignment: .leading)
        // While analyzing: smaller corner radius + the Tron-beam active rim
        // (matches the old AnalyzingCard's own glassCard call exactly).
        // Once resolved: back to the normal large radius, no active rim.
        // Same view, same identity -- this just animates the chrome rather
        // than swapping to a different card.
        .glassCard(cornerRadius: isAnalyzing ? DesignTokens.Radius.medium : DesignTokens.Radius.large, isActive: isAnalyzing)
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .animation(.easeOut(duration: 0.15), value: showCheckbox)
        .animation(.easeInOut(duration: 0.35), value: isAnalyzing)
        .transition(.glassPop)
    }

    // MARK: Shared header

    private var canRevealAnalyzed: Bool {
        !isAnalyzing || (title.isEmpty == false && revealTimerElapsed)
    }

    @Environment(\.contentColumnWidth) private var columnWidth
    /// In a narrow column the thumbnail + title row keeps its place, but the
    /// URL and input -> output chips (which need real width) move BELOW it at
    /// the card's full width instead of being squeezed into the space beside
    /// the thumbnail, where they wrapped and truncated.
    private var narrow: Bool { columnWidth > 0 && columnWidth < WindowLayout.narrowColumnBreakpoint }

    @ViewBuilder
    private var cardHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardHeaderRow
            if narrow, !isAnalyzing, let sub = subtitle {
                sub.transition(.blurIn)
            }
        }
    }

    @ViewBuilder
    private var cardHeaderRow: some View {
        // Center-aligned against just the title + subtitle group (URL +
        // input->output chips) -- the mode toggle now lives in its own
        // belowHeader slot outside this HStack entirely, so it never
        // factors into this centering and the thumbnail stays visually
        // centered against "everything but the format/mode controls".
        //
        // Same HStack shell for both the analyzing and analyzed states --
        // only the content INSIDE each slot changes based on isAnalyzing/
        // canRevealAnalyzed. Keeping one shared header means SwiftUI is
        // always updating the same view identity in place (this is the
        // fix for cards visually "popping in" as a replacement once analyze
        // finishes, instead of smoothly settling) rather than unmounting an
        // AnalyzingCard and mounting a fresh PreviewCard.
        HStack(alignment: .center, spacing: 10) {
            if showCheckbox {
                // Checkbox slot is simply absent while analyzing (nothing to
                // select yet) -- matches AnalyzingCard, which never showed one.
                if !isAnalyzing {
                    HoverIconButton(
                        icon: isSelected ? "checkmark.circle.fill" : "circle",
                        size: 18, isActive: isSelected
                    ) { onToggleSelect() }
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous)
                    .fill(Color.white.opacity(DesignTokens.Interactive.fillRest))
                // Skeleton and real thumbnail are BOTH always mounted (never
                // branch-swapped) so the thumbnail that was already showing
                // during analyze never remounts/re-renders once analyze
                // finishes -- only the skeleton's opacity animates out from
                // underneath an image that was already there.
                ThumbnailSkeleton()
                    .opacity(canRevealAnalyzed ? 0 : 1)
                if let thumb = thumbnail {
                    // Sharpens out of a blur as the skeleton pulses away
                    // underneath, like a progressive image load.
                    thumb
                        .scaledToFill()
                        .clipped()
                        .blur(radius: canRevealAnalyzed ? 0 : 10)
                        .scaleEffect(canRevealAnalyzed ? 1 : 1.08)
                        .opacity(canRevealAnalyzed ? 1 : 0)
                } else if !isAnalyzing {
                    Image(systemName: thumbnailPlaceholder)
                        .font(.system(size: 20, weight: .thin))
                        .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                }
            }
            .frame(width: 80, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous))
            .animation(.easeInOut(duration: 0.5), value: canRevealAnalyzed)

            // Title is a single, always-mounted Text -- never branch-swapped
            // between a skeleton bar and a real Text, so the same text that
            // was already visible while analyzing never remounts once
            // analyze finishes. It just animates its own font/weight/color
            // from the analyzing look to the resolved look, and the
            // "Analyzing\u{2026}" caption fades out while the real subtitle (URL +
            // chips) fades in underneath it -- the title visually "moves up"
            // into the subtitle's old spot because that line's content
            // cross-fades in place rather than the whole block swapping.
            VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .leading) {
                    // Redacted placeholder bar with the same slow pulse the
                    // old standalone TitleSkeletonBar had, just inlined here
                    // so it can share one Text underneath instead of a
                    // second, separately-mounted Text.
                    if isAnalyzing {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(titleSkeletonPulse ? DesignTokens.Interactive.fillRest * 1.6 : DesignTokens.Interactive.fillRest * 0.6))
                            // Width now matches the real, resolved title's
                            // own measured width (see measuredTitleWidth
                            // below) instead of a fixed guess -- falls back
                            // to a reasonable default only until a title
                            // has actually arrived and been measured once.
                            // Clamped so a very long title doesn't blow the
                            // skeleton out past a sane single-line width.
                            .frame(width: min(max(measuredTitleWidth, 120), 260), height: 14)
                            .opacity(canRevealAnalyzed ? 0 : 1)
                            .animation(.easeInOut(duration: 0.25), value: measuredTitleWidth)
                            .onAppear {
                                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                                    titleSkeletonPulse = true
                                }
                            }
                    }
                    Text(title.isEmpty ? "Fetching title metadata" : title)
                        .font(.system(size: isAnalyzing ? 12 : 13, weight: isAnalyzing ? .medium : .semibold))
                        .foregroundColor(.white.opacity(
                            !canRevealAnalyzed ? 0 :
                            (isAnalyzing ? DesignTokens.Text.secondary :
                                ((showCheckbox && !isSelected) ? DesignTokens.Text.disabled : DesignTokens.Text.primary))
                        ))
                        .lineLimit(isAnalyzing ? 1 : 2)
                        .truncationMode(.middle)
                        .blur(radius: canRevealAnalyzed ? 0 : 6)
                        // Measures this Text's own intrinsic single-line
                        // width (ignoring the lineLimit/truncation applied
                        // above, which would otherwise clip the reported
                        // width to whatever space happens to be available)
                        // so the skeleton bar above can match the width
                        // the resolved title will actually render at.
                        .background(
                            Text(title.isEmpty ? "Fetching title metadata" : title)
                                .font(.system(size: isAnalyzing ? 12 : 13, weight: isAnalyzing ? .medium : .semibold))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .hidden()
                                .background(
                                    GeometryReader { geo in
                                        Color.clear.preference(key: WidthPreferenceKey.self, value: geo.size.width)
                                    }
                                )
                        )
                        .onPreferenceChange(WidthPreferenceKey.self) { width in
                            guard !title.isEmpty else { return }
                            measuredTitleWidth = width
                        }
                }
                .animation(.easeInOut(duration: 0.3), value: canRevealAnalyzed)
                .animation(.easeInOut(duration: 0.35), value: isAnalyzing)

                if isAnalyzing {
                    Text("Analyzing\u{2026}")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                        .transition(.blurIn)
                } else if let sub = subtitle, !narrow {
                    sub
                        .transition(.blurIn)
                }
            }
            .animation(.easeInOut(duration: 0.35), value: isAnalyzing)

            Spacer()

            if isAnalyzing {
                // Spinner → X on hover, exactly like AnalyzingCard.
                SkeletonCancelButton(action: onCancelAnalyze)
            } else {
                if collapseButtonInHeader, let isExpanded, !collapseLocked {
                    CollapseToggleButton(isExpanded: isExpanded.wrappedValue) {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { isExpanded.wrappedValue.toggle() }
                    }
                }

                // Destructive action -- red tint so its intent is unambiguous at
                // a glance, matching SkeletonCancelButton's cancel treatment,
                // instead of blending in with neutral chrome controls.
                // Only expandable when CollapseToggleButton isn't also
                // showing right beside it -- that one already has its own
                // permanent text label, and this one's hover caption would
                // render right on top of it otherwise.
                HoverIconButton(icon: "xmark.circle.fill", size: 16, color: .red, help: "Remove", expandable: !(collapseButtonInHeader && isExpanded != nil && !collapseLocked)) {
                    onRemove()
                }
            }
        }
    }
}

// MARK: - CompactModeChip

/// Small, content-hugging pill for inline mode toggles that live in a
/// header/subtitle row (e.g. Download's always-visible Video+Audio / Audio
/// Only switch). Deliberately NOT styled like SelectorChip (used for
/// format/quality/resolution picker rows) -- a capsule shape instead of a
/// rounded rect, and a solid tint fill when selected instead of a subtle
/// wash, so the mode switch reads as its own distinct control rather than
/// blending into the format chip row sitting right next to it.
struct CompactModeChip: View {
    let label: String
    let icon: String
    let isSelected: Bool
    var tint: Color = DesignTokens.Accent.primary
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.appMono(size: 9, weight: .bold))
                Text(label)
                    .font(.appMono(size: 10, weight: .semibold))
            }
            .foregroundColor(isSelected ? .black : .white.opacity(hovering ? DesignTokens.Text.secondary : DesignTokens.Text.tertiary))
            .fixedSize()
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(
                ZStack {
                    if isSelected {
                        // Solid tint fill (not a translucent wash) -- a
                        // capsule shape alone next to rounded-rect format
                        // chips wasn't enough distinction once selected;
                        // this makes the active mode unmistakable at a
                        // glance instead of reading as just another chip.
                        tint
                    } else {
                        VisualEffectBlur(material: DesignTokens.Glass.material, blendingMode: .behindWindow)
                        Color.black.opacity(DesignTokens.Glass.blackTint)
                        Color.white.opacity(hovering ? DesignTokens.Interactive.fillHover : DesignTokens.Interactive.fillRest)
                    }
                }
            )
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(isSelected ? Color.clear : Color.white.opacity(hovering ? DesignTokens.Interactive.strokeHover : DesignTokens.Interactive.strokeRest),
                            lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - CollapseToggleButton

/// Labeled show/hide control for PreviewCard's settings section — pairs an
/// icon with a short text label so the collapse action is legible at a
/// glance instead of relying on an icon-only chevron.
/// Low-stakes chrome toggle (hide/show settings) -- deliberately kept on
/// the neutral white tint rather than the blue accent used by primary/
/// selected controls, so its visual weight stays subordinate to actions
/// that actually matter (Download/Convert, destructive remove).
struct CollapseToggleButton: View {
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        GlassInteractive(shape: .roundedRect(DesignTokens.Radius.small), action: action) {
            HStack(spacing: 4) {
                Image(systemName: isExpanded ? "chevron.up" : "slider.horizontal.3")
                    .font(.system(size: 9, weight: .semibold))
                // "Options" reads clearer than "Expand" for what this reveals
                // (media mode / quality / format settings), and "Hide" is a
                // shorter, plainer counterpart than "Collapse" once open.
                Text(isExpanded ? "Hide" : "Options")
                    .font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .help(isExpanded ? "Hide options" : "Show formatting options")
    }
}

// MARK: - CompletedCard

/// Universal status card. Used while a job is active (downloading /
/// converting) or after it finishes (done / failed). The `status` slot
/// receives a progress bar, action buttons, error messages, etc.
struct CompletedCard<Status: View>: View {

    // Chrome
    var isSelected: Bool
    var onToggleSelect: () -> Void
    var onRemove: () -> Void
    /// Hides the selection checkbox entirely when false. Defaults to true so
    /// existing call sites (Download tab) keep the always-visible checkbox.
    var showCheckbox: Bool = true
    /// Optional small control rendered immediately after the checkbox --
    /// e.g. Convert's queue-row drag handle. nil (the default) renders
    /// nothing extra, unchanged from before this existed.
    var leadingAccessory: AnyView? = nil
    /// Optional small control stacked directly beneath the remove (x) button
    /// in the header's trailing corner -- e.g. Convert's per-row Edit icon.
    /// nil (the default) renders nothing extra.
    var trailingAccessory: AnyView? = nil
    var thumbnail: AnyView?
    var thumbnailPlaceholder: String = "doc"
    var title: String
    var subtitle: AnyView?
    /// False hides the divider + status() section entirely -- for rows
    /// where that section would otherwise render as an empty divider with
    /// nothing beneath it (e.g. a freshly-queued Convert job with no
    /// buttons or progress to show yet). Defaults to true, unchanged from
    /// before this existed.
    var hasStatusContent: Bool = true
    /// Tighter padding/thumbnail/spacing for rows that need to stay dense
    /// (Convert's queue rows, where several sit in a fixed-height
    /// scrollable drawer) -- false (default) keeps Download's cards at
    /// their original size.
    var compact: Bool = false

    // Status content
    @ViewBuilder var status: () -> Status

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            cardHeader
            if hasStatusContent {
                GlassDivider()
                status()
            }
        }
        // Content-only dim -- see PreviewCard.fullCard.
        .opacity((showCheckbox && !isSelected) ? 0.6 : 1.0)
        .padding(compact ? 10 : 16)
        // Same proportional-width fix as PreviewCard.fullCard above.
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: DesignTokens.Radius.large)
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .animation(.easeOut(duration: 0.15), value: showCheckbox)
        .transition(.glassPop)
    }

    @Environment(\.contentColumnWidth) private var columnWidth
    /// See PreviewCard.narrow.
    private var narrow: Bool { columnWidth > 0 && columnWidth < WindowLayout.narrowColumnBreakpoint }

    @ViewBuilder
    private var cardHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardHeaderRow
            if narrow, let sub = subtitle { sub }
        }
    }

    @ViewBuilder
    private var cardHeaderRow: some View {
        HStack(spacing: compact ? 8 : 10) {
            if showCheckbox {
                HoverIconButton(
                    icon: isSelected ? "checkmark.circle.fill" : "circle",
                    size: compact ? 16 : 18, isActive: isSelected
                ) { onToggleSelect() }
            }
            if let leadingAccessory { leadingAccessory }

            ZStack {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous)
                    .fill(Color.white.opacity(DesignTokens.Interactive.fillRest))
                if let thumb = thumbnail {
                    thumb
                        .scaledToFill()
                        .clipped()
                } else {
                    Image(systemName: thumbnailPlaceholder)
                        .font(.system(size: compact ? 16 : 20, weight: .thin))
                        .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                }
            }
            .frame(width: compact ? 56 : 80, height: compact ? 38 : 52)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: compact ? 12 : 13, weight: .semibold))
                    .foregroundColor(.white.opacity((showCheckbox && !isSelected) ? DesignTokens.Text.disabled : DesignTokens.Text.primary))
                    .lineLimit(2)
                if let sub = subtitle, !narrow { sub }
            }

            Spacer()

            // Destructive action -- same red treatment as PreviewCard's
            // remove control, so "this deletes the item" reads identically
            // everywhere in the app. trailingAccessory (e.g. Edit) stacks
            // directly beneath it rather than living in its own row/section.
            VStack(spacing: 6) {
                HoverIconButton(icon: "xmark.circle.fill", size: 16, color: .red, help: "Remove", expandable: true) {
                    onRemove()
                }
                if let trailingAccessory { trailingAccessory }
            }
        }
    }
}

// MARK: - InputOutputRow

/// Combined input -> output summary shown in the header's subtitle slot for
/// in-progress/completed cards (Download's CompletedCard and Convert's
/// convertCompletedCard). Puts the original source info on the left and the
/// destination info on the right of the SAME row, with a big arrow perfectly
/// centered between them so it's immediately clear the item on the right is
/// what the item on the left is being turned into. Both sides use the exact
/// same path-then-chips layout so they line up visually. The status
/// indicator is intentionally NOT shown here — it now lives in the actions
/// row instead. Replaces the old layout where output info sat in its own
/// separate row below the header/divider.
struct InputOutputRow: View {
    let inputPath: String
    let inputChips: [ChipData]
    let outputPath: String
    let outputChips: [ChipData]

    // Custom alignment ID keyed to each side's chip row specifically --
    // centering the whole HStack (the old .center approach) centers the
    // arrow against path-text + chips combined, which biases it upward
    // since the path line adds height above the chips on both sides. Using
    // an explicit guide anchored to the chip rows' own vertical center
    // keeps the arrow level with the chips even when one side wraps onto a
    // second line and the other doesn't.
    private struct ChipRowCenter: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context.height / 2 }
    }
    private var chipRowCenter: VerticalAlignment { VerticalAlignment(ChipRowCenter.self) }

    @Environment(\.contentColumnWidth) private var columnWidth
    /// Side by side needs room for two chip rows plus the arrow; below the
    /// breakpoint they stack (input on top, output beneath) instead of
    /// squeezing each other into truncated or overlapping chips.
    private var stacked: Bool { columnWidth > 0 && columnWidth < WindowLayout.stackedChipsBreakpoint }

    private func column(path: String, chips: [ChipData], alignChips: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(path)
                .font(.system(size: 10)).foregroundColor(.white.opacity(DesignTokens.Text.disabled))
                .lineLimit(1).truncationMode(.middle)
            if !chips.isEmpty {
                if alignChips {
                    ChipRow(chips: chips)
                        .alignmentGuide(chipRowCenter) { $0.height / 2 }
                } else {
                    ChipRow(chips: chips)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        if stacked {
            VStack(alignment: .leading, spacing: 8) {
                column(path: inputPath, chips: inputChips, alignChips: false)
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                        .padding(.top, 2)
                    column(path: outputPath, chips: outputChips, alignChips: false)
                }
            }
        } else {
            HStack(alignment: chipRowCenter, spacing: 14) {
                // Input (source) column
                column(path: inputPath, chips: inputChips, alignChips: true)

                // Big arrow — input flows into output, level with both chip
                // rows regardless of how many lines either one wraps to.
                Image(systemName: "arrow.right")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                    .alignmentGuide(chipRowCenter) { $0.height / 2 }

                // Output (destination) column — same layout as input so the two
                // sides align at the same level.
                column(path: outputPath, chips: outputChips, alignChips: true)
            }
        }
    }
}

/// The "what you have -> what you'll get" chip pair under a card's title
/// (Download's queued cards and Convert's Analyze/queue cards). Side by side
/// when the content column is wide enough; stacked below
/// WindowLayout.stackedChipsBreakpoint, where the side-by-side layout used to
/// overlap (Convert) or wrap to three rows per side (Download).
struct InputOutputChips: View {
    let input: [ChipData]
    let output: [ChipData]
    @Environment(\.contentColumnWidth) private var columnWidth

    var body: some View {
        if columnWidth > 0 && columnWidth < WindowLayout.stackedChipsBreakpoint {
            VStack(alignment: .leading, spacing: 6) {
                ChipRow(chips: input)
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(DesignTokens.Text.disabled))
                        .padding(.top, 6)
                    ChipRow(chips: output)
                }
            }
        } else {
            HStack(alignment: .center, spacing: 10) {
                ChipRow(chips: input)
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(DesignTokens.Text.disabled))
                ChipRow(chips: output)
            }
        }
    }
}

// NOTE: AnalyzingCard (former State 1 of 3) has been folded directly into
// PreviewCard above via the isAnalyzing flag -- see cardHeader. This keeps
// one consistent view identity across the analyzing → analyzed transition
// instead of unmounting/remounting a separate view type, which is what
// caused pending cards to visually "pop in" as replacements rather than
// smoothly updating in place once analyze completed.
