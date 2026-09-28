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

/// Sizes shared by every card header so a card doesn't change shape as it moves
/// between states (analyzing, queued, downloading, done).
enum CardMetrics {
    static let thumbWidth: CGFloat = 56
    static let thumbHeight: CGFloat = 38
    /// Height of the IN / OUT metadata capsule (two rows). The analyzing placeholder is drawn
    /// at the same height, so a card keeps its size as it resolves.
    static let metaCapsuleHeight: CGFloat = 41
    /// Room between a download card's text and its buttons for the progress column, and, once
    /// the download has finished, for the outcome label plus the Reveal button that joins the
    /// buttons then: the total is the same either way, so the title never has to give way.
    static let statusWidth: CGFloat = 128
    /// One header button (28pt) and the 12pt gap that follows it.
    static let buttonSlot: CGFloat = 40
}

/// A control in a card's header, in the button slot beside the remove button. The same
/// HoverIconButton stays in its slot as a card changes state (collapse -> cancel -> redownload) and
/// just takes on the next control's icon and colour, so the swap happens in place.
struct CardControl {
    var icon: String
    var color: Color = .white
    var help: String = ""
    var action: () -> Void
}

// MARK: - Shared card chrome
//
// Both PreviewCard and CompletedCard share the same header row:
// checkbox · thumbnail · title + subtitle · buttons.
//
//  PreviewCard   — Download's card for a link's WHOLE life (analyzing, ready with its
//                  settings, downloading, finished, failed): one card whose contents change
//                  with the state (see the `capsule`, `inlineStatus`, `primaryControl` and
//                  `showsSettings` inputs), never replaced by another view. Also Convert's
//                  analyze card.
//
//  CompletedCard — Convert's queue rows (and their inline status), which Download's
//                  downloading / finished states now look like.

// MARK: - PreviewCard

/// Universal card. Download's card in every state, and Convert's analyze card. The `settings` slot receives tab-specific
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
    /// The link or file path, shown dim on the same line as the title.
    var secondaryTitle: String = ""
    var subtitle: AnyView?          // the IN / OUT metadata lines
    /// A control for the header's trailing edge, beside the collapse and remove
    /// buttons (Convert's list of staged files).
    var headerAccessory: AnyView? = nil
    /// Buttons along the bottom of the card, below the settings (Convert's
    /// Add to Queue).
    var footer: AnyView? = nil

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

    /// The metadata capsule, when the card manages one itself: ONE capsule that stays mounted
    /// and changes its contents as the card moves through its states (analyzing, ready,
    /// downloading, finished; see PersistentCapsule). Cards that pass nil keep using `subtitle`.
    var capsule: CardCapsule? = nil
    /// True once `title` is the real title, not the pasted link standing in for it while the
    /// link is analyzed. Until then the title bar waits at a default length; when it is true the
    /// bar first takes the title's length and only then gives way to the title.
    var titleKnown: Bool = true
    /// A status column between the text and the buttons on the header's trailing side (a
    /// download's progress while it runs).
    var inlineStatus: AnyView? = nil
    /// A download's outcome (Done, Failed, Cancelled), to the left of the buttons once the
    /// progress column has gone. Not part of the progress column: it is its own label, so
    /// nothing that was in the column moves.
    var statusLabel: AnyView? = nil
    /// Takes the collapse button's slot (a download's redownload / retry, once it has ended).
    var primaryControl: CardControl? = nil
    /// A control to the left of the primary one (Reveal in Finder, once a download is done).
    var secondaryControl: CardControl? = nil
    /// When set, the red Remove button becomes an orange Cancel running this (a download that
    /// is still in flight) -- same one-button swap as CompletedCard.removeOrCancelButton, so a
    /// running job never shows two buttons (Cancel and Remove) at once for the same action.
    var onCancel: (() -> Void)? = nil
    /// False hides everything below the header (belowHeader, settings, footer): a download
    /// under way or finished.
    var showsSettings: Bool = true

    // Settings content
    @ViewBuilder var settings: () -> Settings

    // Mirrors AnalyzingCard's own reveal gate -- a brief minimum "redacted"
    // hold before the real thumbnail/title are allowed to show, even if
    // they're already known instantly (e.g. redownloading from History).
    @State private var revealTimerElapsed = false
    /// The title bar is on screen from the moment the card waits for its title until the title
    /// has faded in. Set once the card is seen analyzing; cleared after the reveal.
    @State private var titleWasPending = false
    /// 0: the bar at its default length. 1: the bar has taken the title's length. 2: the title
    /// itself is showing.
    @State private var titlePhase = 0
    /// The card has been analyzing and has only just stopped: the metadata that arrives then
    /// waits for the capsule to finish growing (and the title to appear) before it shows.
    @State private var sawAnalyzing = false
    // Measured width of the real title Text once it has actual content --
    // the skeleton bar sizes itself to this instead of a fixed guess, so it
    // reads as a placeholder for THIS title rather than a generic bar.
    // Falls back to a reasonable default (below) until a title arrives.
    @State private var measuredTitleWidth: CGFloat = 0
    /// The title `measuredTitleWidth` was measured for, so the bar never sizes itself to a
    /// width measured for some other text (the pasted link that stood in for the title).
    @State private var measuredTitle = ""

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
            .task(id: TitleProgress(known: titleKnown, analyzing: isAnalyzing)) { await advanceTitle() }
            .task(id: isAnalyzing) {
                if isAnalyzing {
                    sawAnalyzing = true
                } else if sawAnalyzing {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if !Task.isCancelled { sawAnalyzing = false }
                }
            }
    }

    private struct TitleProgress: Hashable {
        var known: Bool
        var analyzing: Bool
    }

    /// The title's reveal, in order: the bar takes the title's length, then (after the card has
    /// been up long enough not to flash) the title fades in over it. Runs again whenever the
    /// title becomes known or the analysis ends.
    @MainActor
    private func advanceTitle() async {
        if isAnalyzing { titleWasPending = true }
        guard titleWasPending, titlePhase < 2 else { return }
        // Still waiting for the real title: the bar just stays at its default length.
        guard titleKnown || !isAnalyzing else { return }
        // The bar takes the title's length, so wait until that length has been measured (a
        // frame or two) rather than growing toward a stale one.
        var waited = 0
        while titleKnown, measuredTitle != title, waited < 15, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 20_000_000)
            waited += 1
        }
        guard !Task.isCancelled else { return }
        if titlePhase < 1 {
            withAnimation(.easeInOut(duration: 0.3)) { titlePhase = 1 }
        }
        try? await Task.sleep(nanoseconds: 350_000_000)
        while !revealTimerElapsed && isAnalyzing && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.3)) { titlePhase = 2 }
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !Task.isCancelled else { return }
        titleWasPending = false
    }

    // MARK: Full card

    private var fullCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            cardHeader
                // Above the settings below it, so the header's own popups (the
                // Convert file switcher) aren't painted over.
                .zIndex(1)
            if !isAnalyzing {
                if let belowHeader {
                    belowHeader.transition(.blurInTop)
                }
                if showsSettings {
                    if expanded {
                        GlassDivider().transition(.blurInTop)
                        settings().transition(.blurInTop)
                    }
                    if let footer { footer }
                }
            }
        }
        // De-emphasise unselected cards in batch-select mode by dimming the
        // CONTENT only. Opacity on the card itself would dilute the glass tint
        // and turn the surface into a flat grey slab (see FocusEffect).
        .opacity((showCheckbox && !isSelected) ? 0.6 : 1.0)
        .padding(.horizontal, 12).padding(.vertical, 10)
        // Match the 60%-of-window proportional width every other row in
        // the queue (list header, bottom bar) explicitly stretches to --
        // without this the card just hugs its own content and reads
        // narrower than everything else stacked above/below it.
        .frame(maxWidth: .infinity, alignment: .leading)
        // What the resize facade needs to know about this card's shape.
        .preference(key: CardFacadeMetricsKey.self, value: CardFacadeMetrics(
            expanded: expanded && showsSettings,
            analyzing: isAnalyzing,
            buttonCount: buttonCount,
            hasStatus: inlineStatus != nil,
            hasStatusLabel: statusLabel != nil,
            hasLink: expanded && showsSettings && !isAnalyzing && !secondaryTitle.isEmpty,
            reported: true
        ))
        // The analyzing card has exactly the finished card's shape (radius, padding, header
        // height); the Tron-beam rim is what marks it as working, and goes when it resolves.
        // Same view, same identity -- this just animates the chrome rather
        // than swapping to a different card.
        .liveGlassCard(cornerRadius: DesignTokens.Radius.large, isActive: isAnalyzing)
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .animation(.easeOut(duration: 0.15), value: showCheckbox)
        // Every state change (analyzing -> ready -> downloading -> finished) animates in place:
        // the same card, its contents adjusting.
        .animation(.easeInOut(duration: 0.35), value: StateKey(
            analyzing: isAnalyzing, settings: showsSettings, status: inlineStatus != nil, label: statusLabel != nil, buttons: buttonCount
        ))
        .transition(.glassPopInOnly)
    }

    private struct StateKey: Equatable {
        var analyzing: Bool
        var settings: Bool
        var status: Bool
        var label: Bool
        var buttons: Int
    }

    /// The room the status slot takes: what the progress column needs, less the Reveal button
    /// that shares the trailing side once a download is done.
    private var statusSlotWidth: CGFloat {
        CardMetrics.statusWidth - (secondaryControl != nil ? CardMetrics.buttonSlot : 0)
    }

    /// Buttons on the header's trailing edge, for the resize facade.
    private var buttonCount: Int {
        if isAnalyzing { return 1 }
        return (secondaryControl != nil ? 1 : 0) + (primaryTrailingControl != nil ? 1 : 0) + 1
    }

    // MARK: Shared header

    /// The thumbnail comes out of its blur once the card has been up long enough not to flash.
    private var canRevealThumb: Bool { !isAnalyzing || revealTimerElapsed }
    /// The title bar is showing until the title has faded in.
    private var showsTitleBar: Bool { isAnalyzing || titleWasPending }
    private var titleRevealed: Bool { !showsTitleBar || titlePhase >= 2 }

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
            if narrow { capsuleSlot }
            // The link / file path lives on its own line, and only while the
            // card is expanded -- collapsed cards stay a single compact row.
            if expanded, !isAnalyzing, !secondaryTitle.isEmpty {
                Text(secondaryTitle)
                    .font(.appMono(size: 10))
                    .foregroundColor(.white.opacity(DesignTokens.Text.disabled))
                    // A URL's most identifying part (domain + path) comes first; tracking
                    // params/session tokens pile up at the end, so tail truncation drops the
                    // least useful part instead of the middle -- Download is the only caller
                    // that ever sets this to a real link (Convert's own secondaryTitle below,
                    // a local file path, keeps .middle: there the FILENAME at the end matters).
                    .lineLimit(1).truncationMode(.tail)
                    .transition(.blurInTop)
            }
        }
    }

    /// The metadata capsule: the card's own persistent one, or (Convert) the caller's subtitle.
    @ViewBuilder
    private var capsuleSlot: some View {
        if let capsule {
            PersistentCapsule(content: capsule, revealDelay: sawAnalyzing && !isAnalyzing ? Self.metadataRevealDelay : 0)
        } else if let subtitle {
            subtitle.transition(.blurIn)
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
        // the reveal state. Keeping one shared header means SwiftUI is
        // always updating the same view identity in place (this is the
        // fix for cards visually "popping in" as a replacement once analyze
        // finishes, instead of smoothly settling) rather than unmounting an
        // AnalyzingCard and mounting a fresh PreviewCard.
        HStack(alignment: .center, spacing: 12) {
            if showCheckbox {
                // Checkbox slot is simply absent while analyzing (nothing to
                // select yet) -- matches AnalyzingCard, which never showed one.
                if !isAnalyzing {
                    HoverIconButton(
                        icon: isSelected ? "checkmark.circle.fill" : "circle",
                        size: 18, isActive: isSelected, help: isSelected ? "Deselect" : "Select", expandable: true
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
                ThumbnailSkeleton(isPulsing: !canRevealThumb)
                    .opacity(canRevealThumb ? 0 : 1)
                if let thumb = thumbnail {
                    // Sharpens out of a blur as the skeleton pulses away
                    // underneath, like a progressive image load.
                    thumb
                        .scaledToFill()
                        .clipped()
                        .blur(radius: canRevealThumb ? 0 : 10)
                        .scaleEffect(canRevealThumb ? 1 : 1.08)
                        .opacity(canRevealThumb ? 1 : 0)
                } else if !isAnalyzing {
                    Image(systemName: thumbnailPlaceholder)
                        .font(.system(size: 16, weight: .thin))
                        .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                }
            }
            .frame(width: CardMetrics.thumbWidth, height: CardMetrics.thumbHeight)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous))
            .animation(.easeInOut(duration: 0.5), value: canRevealThumb)

            // The title is ONE always-mounted Text, with a redacted bar over it until it can be
            // shown. While the link is analyzed the bar waits at a default length; the moment the
            // real title is known (an early oEmbed answer or the final result) the bar takes its
            // length, and only then does the title fade in over it -- so what is revealed is
            // already the size of the bar, and a card whose title was known from the start (a
            // redownload) has no bar at all. The capsule below is one persistent capsule too (see
            // PersistentCapsule): its contents change, it does not get replaced.
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                ZStack(alignment: .leading) {
                    if showsTitleBar {
                        // A Core Animation pulse (a SwiftUI repeatForever here kept the whole
                        // window redrawing at idle), still once the title is showing.
                        PulsingSkeleton(cornerRadius: 4, isPulsing: !titleRevealed)
                            .frame(width: titlePhase >= 1 ? min(max(measuredTitleWidth, 60), Self.titleMaxWidth) : Self.defaultTitleBarWidth, height: 14)
                            .opacity(titleRevealed ? 0 : 1)
                    }
                    Text(title.isEmpty ? "Fetching title metadata" : title)
                        .font(.appMono(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(
                            !titleRevealed ? 0 :
                            (isAnalyzing ? DesignTokens.Text.secondary :
                                ((showCheckbox && !isSelected) ? DesignTokens.Text.disabled : DesignTokens.Text.primary))
                        ))
                        .lineLimit(1)
                        // Cut where it runs out of room, never in the middle.
                        .truncationMode(.tail)
                        // The same cap in every state, so the title never has to shorten itself
                        // when the progress column appears next to it.
                        .frame(maxWidth: Self.titleMaxWidth, alignment: .leading)
                        .blur(radius: titleRevealed ? 0 : 6)
                        // Measures this Text's own intrinsic single-line width (ignoring the
                        // lineLimit/truncation above, which would clip the reported width to
                        // whatever space happens to be available), so the bar can take exactly
                        // the length the title will have.
                        .background(
                            Text(title.isEmpty ? "Fetching title metadata" : title)
                                .font(.appMono(size: 13, weight: .semibold))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .hidden()
                                // The facade draws its title bar this long (a default one while
                                // the title is still the pasted link).
                                .reportsToFacade { metrics, size in
                                    metrics.titleWidth = titleKnown ? min(size.width, Self.titleMaxWidth) : Self.defaultTitleBarWidth
                                }
                                .background(
                                    GeometryReader { geo in
                                        Color.clear.preference(key: WidthPreferenceKey.self, value: geo.size.width)
                                    }
                                )
                        )
                        .onPreferenceChange(WidthPreferenceKey.self) { width in
                            // Only the real title counts: until then the text is the pasted link.
                            guard titleKnown, !title.isEmpty else { return }
                            measuredTitleWidth = width
                            measuredTitle = title
                        }
                }
                .animation(.easeInOut(duration: 0.3), value: titleRevealed)
                .animation(.easeInOut(duration: 0.3), value: titlePhase)
                .layoutPriority(1)
                }

                if !narrow { capsuleSlot }
            }

            Spacer()

            if inlineStatus != nil || statusLabel != nil {
                // A download's progress column, then (in its place) its outcome label. The room
                // they share is worked out from the buttons that come after it -- the Reveal button
                // that joins them when a download finishes takes 40pt of it -- so the whole
                // trailing side is the same width in every download state and the title never
                // gets more or less room. That width is a spacer that never animates; the two
                // views swap inside it (as an overlay, so the outgoing one takes no room while it
                // fades) and stay right-aligned against the buttons.
                Color.clear
                    .frame(width: statusSlotWidth, height: 1)
                    .animation(nil, value: statusSlotWidth)
                    .overlay(alignment: .trailing) {
                        ZStack(alignment: .trailing) {
                            if let inlineStatus { inlineStatus.transition(.blurIn) }
                            if let statusLabel { statusLabel.transition(.blurIn) }
                        }
                    }
            }

            trailingArea
        }
    }

    /// Where the title bar waits until the real title is known: short, so it visibly grows to the
    /// title's length.
    private static var defaultTitleBarWidth: CGFloat { 120 }
    /// The most a title is allowed to take, in every state.
    private static var titleMaxWidth: CGFloat { 420 }
    /// How long the metadata of a card that was analyzing waits before it shows: the capsule
    /// grows for 0.3s and the title's text starts to appear just after that.
    private static var metadataRevealDelay: Double { 0.55 }

    /// The control that takes the collapse button's slot: the caller's (a download's cancel /
    /// redownload / retry), else the collapse chevron itself.
    private var primaryTrailingControl: CardControl? {
        if let primaryControl { return primaryControl }
        guard !isAnalyzing, collapseButtonInHeader, let isExpanded, !collapseLocked else { return nil }
        return CardControl(icon: isExpanded.wrappedValue ? "chevron.up" : "chevron.down",
                           help: isExpanded.wrappedValue ? "Hide options" : "Show options") {
            withAnimation(.easeOut(duration: 0.22)) { isExpanded.wrappedValue.toggle() }
        }
    }

    private func controlButton(_ control: CardControl) -> some View {
        HoverIconButton(icon: control.icon, size: 16, color: control.color, help: control.help, expandable: true) { control.action() }
    }

    /// The header's buttons, each in its own place: [secondary] [primary] [remove], remove
    /// always last. Every one is the same 28pt capsule, and the primary one stays put while its
    /// icon changes (collapse -> cancel -> redownload).
    @ViewBuilder
    private var trailingArea: some View {
        HStack(spacing: 12) {
            if let headerAccessory { headerAccessory }
            if let secondaryControl {
                controlButton(secondaryControl).transition(.blurIn)
            }
            if let primary = primaryTrailingControl {
                controlButton(primary).transition(.blurIn)
            }
            if isAnalyzing {
                // Spinner -> X on hover, in the remove button's own slot.
                SkeletonCancelButton(action: onCancelAnalyze).transition(.blurIn)
            } else {
                // Remove, or Cancel while the card's work is in flight -- one button either
                // way, its icon swapping in place (see CompletedCard.removeOrCancelButton).
                let cancelling = onCancel != nil
                HoverIconButton(icon: cancelling ? "stop.circle.fill" : "xmark.circle.fill", size: 16,
                               color: cancelling ? .orange : .red, help: cancelling ? "Cancel" : "Remove",
                               expandable: primaryTrailingControl == nil && secondaryControl == nil) {
                    if let onCancel { onCancel() } else { onRemove() }
                }
                .transition(.blurIn)
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
            // Keep the label readable while the fill grows/shrinks (chipFill):
            // easing black<->grey in step with the fill left the text black on
            // black for a few frames. Selecting holds the grey until the fill has
            // mostly covered it; deselecting snaps to grey at once.
            .animation(isSelected ? .easeInOut(duration: 0.12).delay(0.1) : nil, value: isSelected)
            .fixedSize()
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(
                ZStack {
                    // Tinted base is always present; only the solid accent fill
                    // comes and goes (swapping via if/else made SwiftUI cross-
                    // fade a VisualEffectBlur layer, which flashed the chip flat
                    // grey mid-change -- see FocusEffect). NOT its own
                    // VisualEffectBlur: this chip always sits on its parent
                    // card's already-blurred glassCard background, so a second,
                    // independent live backdrop blur per chip only multiplied
                    // the compositor's per-resize-frame work for a visual
                    // difference this opaque a tint (0.93) made negligible.
                    Color.black.opacity(DesignTokens.Glass.blackTint)
                    Color.white.opacity(hovering ? DesignTokens.Interactive.fillHover : DesignTokens.Interactive.fillRest)
                    if isSelected {
                        // Solid tint fill (not a translucent wash) -- a
                        // capsule shape alone next to rounded-rect format
                        // chips wasn't enough distinction once selected;
                        // this makes the active mode unmistakable at a
                        // glance instead of reading as just another chip.
                        tint.transition(.chipFill())
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
        .animation(.easeOut(duration: 0.15), value: isSelected)
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
                    .font(.appMono(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .help(isExpanded ? "Hide options" : "Show formatting options")
    }
}

// MARK: - StatusBesideButtons

/// A row's trailing side: an optional status slot (a job's progress column while it runs, its
/// outcome label after) followed by the buttons.
///
/// The whole side is `statusWidth + gap + the PERSISTENT buttons` wide in every state, however
/// many others join them (Edit comes and goes with a queue row's status): the slot takes
/// whatever they leave. So the text beside it never gets more or less room as the job moves on
/// and its title never shifts. Mark the buttons that are always there `persistentButton()`
/// (none marked: the last one counts). The slot is worked out from the buttons' own widths,
/// which depend on their symbols, rather than from a number that only fits some of them. The
/// status is one child (mark it `statusSlot()`), placed right-aligned against the buttons, so a
/// view that is still fading out inside it takes no room.
struct StatusBesideButtons: Layout {
    var statusWidth: CGFloat
    var gap: CGFloat
    var buttonSpacing: CGFloat

    struct IsStatus: LayoutValueKey { static let defaultValue = false }
    struct IsPersistent: LayoutValueKey { static let defaultValue = false }

    private func split(_ subviews: Subviews) -> (status: LayoutSubview?, buttons: [LayoutSubview]) {
        (subviews.first { $0[IsStatus.self] }, subviews.filter { !$0[IsStatus.self] })
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (status, buttons) = split(subviews)
        let sizes = buttons.map { $0.sizeThatFits(.unspecified) }
        let buttonsWidth = sizes.map(\.width).reduce(0, +) + buttonSpacing * CGFloat(max(sizes.count - 1, 0))
        let height = max(sizes.map(\.height).max() ?? 0, status?.sizeThatFits(.unspecified).height ?? 0)
        guard status != nil, !sizes.isEmpty else { return CGSize(width: buttonsWidth, height: height) }
        var kept = buttons.indices.filter { buttons[$0][IsPersistent.self] }.map { sizes[$0].width }
        if kept.isEmpty, let last = sizes.last { kept = [last.width] }
        let keptWidth = kept.reduce(0, +) + buttonSpacing * CGFloat(kept.count - 1)
        return CGSize(width: max(statusWidth + gap + keptWidth, gap + buttonsWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (status, buttons) = split(subviews)
        var x = bounds.maxX
        for button in buttons.reversed() {
            let size = button.sizeThatFits(.unspecified)
            x -= size.width
            button.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(size))
            x -= buttonSpacing
        }
        if let status {
            let size = status.sizeThatFits(.unspecified)
            let right = buttons.isEmpty ? bounds.maxX : x + buttonSpacing - gap
            status.place(at: CGPoint(x: right, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(size))
        }
    }
}

extension View {
    /// Marks the status child of a `StatusBesideButtons`.
    func statusSlot() -> some View {
        layoutValue(key: StatusBesideButtons.IsStatus.self, value: true)
    }

    /// Marks a button of a `StatusBesideButtons` that is there in every state.
    func persistentButton() -> some View {
        layoutValue(key: StatusBesideButtons.IsPersistent.self, value: true)
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
    /// When set, the red Remove button becomes an orange Cancel running this
    /// (a Convert queue row whose job is converting).
    var onCancel: (() -> Void)? = nil
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
    /// A control that is there in every state, beside the remove button (Convert's Reveal in
    /// Finder). Unlike `trailingAccessory` it does not come and go, so it is part of the width
    /// the row keeps constant.
    var revealAccessory: AnyView? = nil
    var thumbnail: AnyView?
    var thumbnailPlaceholder: String = "doc"
    var title: String
    /// The link or file path, shown dim on the title's line.
    var secondaryTitle: String = ""
    var subtitle: AnyView?
    /// Status shown in the header itself, between the text and the buttons (the
    /// Convert queue's "Converting 64%" with its progress bar), instead of in a
    /// section below a divider.
    var inlineStatus: AnyView? = nil
    /// How the row's work ended or where it stands (Done, Failed, Queued...), beside the buttons in
    /// the progress column's place. Its own label, not the column changing shape.
    var statusLabel: AnyView? = nil
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
    /// A plain row with no glass card of its own, for lists that already sit
    /// inside a grey card (the Convert queue) -- rows are told apart by a
    /// hairline the list draws between them.
    var flat: Bool = false

    // Status content
    @ViewBuilder var status: () -> Status

    /// Buttons on the header's trailing edge, for the resize facade.
    private var buttonCount: Int {
        (trailingAccessory != nil ? 1 : 0) + (revealAccessory != nil ? 1 : 0) + 1
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            cardHeader
            if hasStatusContent {
                GlassDivider()
                status()
            }
        }
        // Content-only dim -- see PreviewCard.fullCard.
        .opacity((showCheckbox && !isSelected) ? 0.6 : 1.0)
        .padding(flat ? 4 : (compact ? 8 : 12))
        // Same proportional-width fix as PreviewCard.fullCard above.
        .frame(maxWidth: .infinity, alignment: .leading)
        // What the resize facade needs to know about a queue row (see FrozenDuringResize).
        .preference(key: CardFacadeMetricsKey.self, value: CardFacadeMetrics(
            buttonCount: buttonCount,
            hasStatus: inlineStatus != nil,
            hasStatusLabel: statusLabel != nil,
            flat: flat,
            hasLeadingControls: leadingAccessory != nil,
            reported: true
        ))
    }

    var body: some View {
        if flat {
            rowContent
                .animation(.easeOut(duration: 0.15), value: isSelected)
                .animation(.easeOut(duration: 0.15), value: showCheckbox)
                .transition(.blurIn)
        } else {
            rowContent
                .liveGlassCard(cornerRadius: DesignTokens.Radius.large)
                .animation(.easeOut(duration: 0.15), value: isSelected)
                .animation(.easeOut(duration: 0.15), value: showCheckbox)
                .transition(.glassPop)
        }
    }

    @Environment(\.contentColumnWidth) private var columnWidth
    /// See PreviewCard.narrow.
    private var narrow: Bool { columnWidth > 0 && columnWidth < WindowLayout.narrowColumnBreakpoint }

    @ViewBuilder
    private var cardHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardHeaderRow
            if narrow {
                if !secondaryTitle.isEmpty {
                    Text(secondaryTitle)
                        .font(.appMono(size: 10))
                        .foregroundColor(.white.opacity(DesignTokens.Text.disabled))
                        .lineLimit(1).truncationMode(.middle)
                }
                if let sub = subtitle { sub }
            }
        }
    }

    /// Remove, or Cancel while the row's work is in flight. One button either way, so the icon
    /// swaps in place (see HoverIconButton) instead of one button replacing another.
    private var removeOrCancelButton: some View {
        let cancelling = onCancel != nil
        return HoverIconButton(icon: cancelling ? "stop.circle.fill" : "xmark.circle.fill", size: 16,
                               color: cancelling ? .orange : .red, help: cancelling ? "Cancel" : "Remove", expandable: true) {
            if let onCancel { onCancel() } else { onRemove() }
        }
    }

    @ViewBuilder
    private var cardHeaderRow: some View {
        HStack(spacing: compact ? 8 : 12) {
            if showCheckbox {
                HoverIconButton(
                    icon: isSelected ? "checkmark.circle.fill" : "circle",
                    size: compact ? 16 : 18, isActive: isSelected, help: isSelected ? "Deselect" : "Select", expandable: true
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
                        .font(.system(size: 16, weight: .thin))
                        .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                }
            }
            .frame(width: CardMetrics.thumbWidth, height: CardMetrics.thumbHeight)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(title)
                        .font(.appMono(size: compact ? 12 : 13, weight: .semibold))
                        .foregroundColor(.white.opacity((showCheckbox && !isSelected) ? DesignTokens.Text.disabled : DesignTokens.Text.primary))
                        .lineLimit(1)
                        // Cut where it runs out of room, never in the middle.
                        .truncationMode(.tail)
                        .layoutPriority(1)
                        // What is shown of it is the length the facade's title bar takes.
                        .reportsToFacade { metrics, size in metrics.titleWidth = size.width }
                    if !secondaryTitle.isEmpty, !narrow {
                        Text(secondaryTitle)
                            .font(.appMono(size: 10))
                            .foregroundColor(.white.opacity(DesignTokens.Text.disabled))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if let sub = subtitle, !narrow { sub }
            }

            Spacer()

            // Destructive action -- same red treatment as PreviewCard's
            // remove control, so "this deletes the item" reads identically
            // everywhere in the app. trailingAccessory (e.g. Edit) stacks
            // directly beneath it rather than living in its own row/section.
            let removeButton = removeOrCancelButton
            if flat {
                // Beside each other, so the row stays one line tall. The status (progress
                // column, then the outcome label) and the buttons are one group of a constant
                // width (see StatusBesideButtons): Edit comes and goes with the status, and the
                // title must not.
                StatusBesideButtons(statusWidth: CardMetrics.statusWidth, gap: compact ? 8 : 12, buttonSpacing: 6) {
                    if inlineStatus != nil || statusLabel != nil {
                        ZStack(alignment: .trailing) {
                            if let inlineStatus { inlineStatus.transition(.blurIn) }
                            if let statusLabel { statusLabel.transition(.blurIn) }
                        }
                        .statusSlot()
                    }
                    if let trailingAccessory { trailingAccessory }
                    if let revealAccessory { revealAccessory.persistentButton() }
                    removeButton.persistentButton()
                }
            } else {
                if let inlineStatus { inlineStatus }
                VStack(spacing: 6) {
                    removeButton
                    if let trailingAccessory { trailingAccessory }
                }
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
                .font(.appMono(size: 10)).foregroundColor(.white.opacity(DesignTokens.Text.disabled))
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
