import SwiftUI
import AppKit
import UserNotifications
import UniformTypeIdentifiers
import QuickLookThumbnailing
import CryptoKit
import Sparkle

// MARK: - Liquid Glass Helpers

/// NSVisualEffectView wrapper — the real frosted glass blur
// MARK: - Design Tokens
//
// Single source of truth for the black liquid-glass design language.
// Reference points: Flighty (dense, precise information hierarchy, sparing
// vivid accent color used only for status/action, tight type scale) and
// Apple's Liquid Glass / Siri material (refractive, luminous, glowing edge
// light that responds to interaction rather than sitting flat). Every glass
// surface pulls its corner radius, glow strength, and text contrast from
// here so the whole app reads as one consistent, alive material.
// MARK: - App Font

/// Drop's app-wide typeface: SF Mono (via `Font.system(design: .monospaced)`),
/// giving the app a monospace identity while staying visually lighter than
/// Menlo. Menlo was tried first and rejected as too thick -- Menlo only
/// ships 4 static faces (Regular/Bold/Italic/BoldItalic) with no true
/// light/thin weight, and SwiftUI's `.weight()` modifier doesn't synthesize
/// missing weights on a `Font.custom` face, so everything rendered at one
/// uniformly heavy weight. SF Mono is Apple's real variable-weight
/// monospace family (Light/Regular/Medium/Semibold/Bold all exist as true
/// faces) and is only reliably reachable through `Font.system(design:
/// .monospaced)` -- NOT `Font.custom("SF Mono", ...)`, which Apple does
/// not expose a stable PostScript name for. This gives every existing
/// `weight:` argument at each of the 133 call sites real effect again.
/// One knob for the app's text size. Every monospaced font in the app goes
/// through Font.appMono, so scaling it here scales the whole interface.
enum Typography {
    static let scale: CGFloat = 0.95
}

extension Font {
    static func appMono(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: size * Typography.scale, weight: weight, design: .monospaced)
    }
}

/// One effect drives every transition in the app: scale + blur, with
/// opacity available but used sparingly. Never put opacity on a glass
/// surface (`glassCard`): fading a `VisualEffectBlur`-backed view dilutes its
/// 0.93 black tint while the raw material underneath stays lit, so the card
/// turns into a flat grey slab mid-transition. Blur and scale don't have that
/// problem -- they leave the tint alone -- so glass surfaces transition with
/// those two only, and opacity is reserved for loose content (chips, text)
/// sitting on top of a surface.
struct FocusEffect: ViewModifier {
    var blur: CGFloat
    var scale: CGFloat
    var opacity: Double = 1
    var anchor: UnitPoint = .center

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale, anchor: anchor)
            // A spring can overshoot past the identity value; a negative
            // blur radius is meaningless, so clamp.
            .blur(radius: max(0, blur))
            .opacity(opacity)
    }
}

extension Animation {
    /// Domino curves, shared by `AnyTransition.dominoPop` (rows that mount/
    /// unmount) and `DominoVisibility` (rows that stay mounted). Only the
    /// reveal is staggered by `index`; every row leaves together, at once.
    static func dominoEnter(index: Int) -> Animation {
        .spring(response: 0.15, dampingFraction: 0.62).delay(Double(index) * AnyTransition.dominoStagger)
    }

    static var dominoExit: Animation {
        .easeIn(duration: AnyTransition.dominoExitDuration)
    }
}

/// Domino visibility for a row that must NOT leave layout while hidden: it
/// shrinks to a point and blurs in place instead of being removed. Used by
/// the sidebar's bottom-pinned tools block -- a mounted/unmounted row changes
/// that block's height, and because the block is pinned to the bottom the
/// change moves its top edge; under the ambient sequence animation that edge
/// (and every row riding on it) visibly slides instead of each row popping
/// where it sits. Top-anchored content (the nav tabs) doesn't show this,
/// which is why they can use plain `.transition(.dominoPop)`.
struct DominoVisibility: ViewModifier {
    var hidden: Bool
    var index: Int

    func body(content: Content) -> some View {
        content
            .modifier(FocusEffect(blur: hidden ? AnyTransition.dominoBlur : 0, scale: hidden ? 0.001 : 1))
            .animation(hidden ? Animation.dominoExit : Animation.dominoEnter(index: index), value: hidden)
            .allowsHitTesting(!hidden)
            .accessibilityHidden(hidden)
    }
}

extension View {
    func dominoVisibility(hidden: Bool, index: Int) -> some View {
        modifier(DominoVisibility(hidden: hidden, index: index))
    }
}

extension AnyTransition {
    /// WARNING before using this bare, symmetric, on a conditionally-mounted view (an
    /// `if`/`if let` branch, or a view keyed with `.id()` to one of several possible
    /// values): a SYMMETRIC transition's removal half can get INTERRUPTED before it
    /// finishes by any other animation competing for the same frames (another branch
    /// opening, a sibling layout change, the user re-triggering the same toggle
    /// quickly) -- Core Animation leaves that half-blurred/half-scaled frame stuck on
    /// screen until something else clears it, which reads as a persistent duplicate
    /// "ghost," not a transient flicker. Hit three times in this codebase before the
    /// pattern was recognized (HoverIconButton's hover caption, 64d698e; Convert's
    /// queue rows on Clear Queue, 88c66b0; the dropdown field popover, 3db4f08) --
    /// every time reported as "ghosting is still happening" even after a first,
    /// more surgical fix that tried to suppress the TRIGGERING state change's
    /// animation instead of the view's own removal. If the view can plausibly be
    /// re-triggered (opened/closed/switched) faster than its own transition's
    /// duration, wrap it `.asymmetric(insertion: focus(...).animation(...), removal:
    /// .identity)` instead -- see glassPopInOnly/blurInOnly/pageSwap below for the
    /// established convention. Safe to use bare where removal genuinely can't be
    /// interrupted (a one-shot card leaving a list with nothing else competing for
    /// its slot) -- glassPop/glassBar/chipFill/dominoPop/blurIn below do this
    /// deliberately, for the motion, not by oversight.
    static func focus(blur: CGFloat, scale: CGFloat, opacity: Double = 1, anchor: UnitPoint = .center) -> AnyTransition {
        .modifier(
            active: FocusEffect(blur: blur, scale: scale, opacity: opacity, anchor: anchor),
            identity: FocusEffect(blur: 0, scale: 1, opacity: 1, anchor: anchor)
        )
    }

    // GPU budget. Every glass surface is a live backdrop blur, and moving,
    // scaling or fading one makes the compositor recompute that blur EVERY
    // FRAME it animates. Measured on the WindowServer: a no-op transition costs
    // the same as no transition; a 12px-blur, ~1s-spring page swap cost 9x a
    // hard cut; blur 4 over 0.22s with the outgoing page removed instantly cost
    // half that. So: short fixed-duration ease curves (a spring's long tail keeps
    // the GPU busy long after it stops being visible), small blur radii, and
    // outgoing views leave instantly unless they're small.

    /// Glass surfaces -- Download's analyze/preview cards. Rises out of a soft
    /// blur while settling from 95% scale, anchored on the top edge. No opacity
    /// (see FocusEffect). Removal is a quick shrink so cards still leave with
    /// motion.
    static let glassPop = AnyTransition.asymmetric(
        insertion: focus(blur: 6, scale: 0.95, anchor: .top)
            .animation(.easeOut(duration: 0.26)),
        removal: focus(blur: 4, scale: 0.97, anchor: .top)
            .animation(.easeIn(duration: 0.14))
    )

    /// Insertion-only variants, for `if/else` branches that BOTH take layout
    /// space in the same stack. An animated removal keeps the outgoing branch
    /// in the layout until it finishes, so for that moment the container holds
    /// both branches; that inflates its minimum height and the window
    /// auto-grows to fit (and never shrinks back). Outgoing branches therefore
    /// leave instantly and only the incoming one animates. Also used for
    /// status swaps inside one card (a card going from analyzed to
    /// downloading), where animating both glass surfaces at once was the most
    /// expensive thing the app did.
    static let glassPopInOnly = AnyTransition.asymmetric(
        insertion: focus(blur: 6, scale: 0.95, anchor: .top)
            .animation(.easeOut(duration: 0.26)),
        removal: .identity
    )
    static let blurInOnly = AnyTransition.asymmetric(
        insertion: focus(blur: 5, scale: 0.97, opacity: 0.4)
            .animation(.easeOut(duration: 0.2)),
        removal: .identity
    )

    /// Wide glass strips and rows (Download toolbar, bottom bar, History
    /// rows). A gentler cousin of `glassPop` -- a 90% scale on something 600pt
    /// wide swings its edges by 30pt, which reads as a lurch, so this only
    /// shrinks to 97% while blurring. Anchor picks the edge it grows from.
    static func glassBar(anchor: UnitPoint) -> AnyTransition {
        .asymmetric(
            insertion: focus(blur: 5, scale: 0.97, anchor: anchor)
                .animation(.easeOut(duration: 0.24)),
            removal: focus(blur: 4, scale: 0.98, anchor: anchor)
                .animation(.easeIn(duration: 0.14))
        )
    }

    /// The selected-state fill of a chip. The chip's glass base stays put and
    /// the accent fill grows out of its centre (blurred, scale only) on select
    /// and shrinks back on deselect. The old code swapped two whole fills with
    /// the default opacity cross-fade, which faded a VisualEffectBlur-backed
    /// layer and flashed the chip flat grey mid-change (see FocusEffect).
    static func chipFill(scale: CGFloat = 0.4) -> AnyTransition {
        .asymmetric(
            insertion: focus(blur: 4, scale: scale)
                .animation(.easeOut(duration: 0.2)),
            removal: focus(blur: 4, scale: scale)
                .animation(.easeIn(duration: 0.12))
        )
    }

    /// Gap between one sidebar row's reveal step and the next. Only the
    /// reveal is staggered (every row leaves together -- see
    /// dominoExitDuration). 40ms is the tightest that still reads as a march
    /// rather than one wave: over 11 rows that's 10 gaps = 0.4s, plus the
    /// last row's settle (ContentView.sidebarEnterTotal), for a whole toggle
    /// of about 0.8s. Single source of truth -- ContentView reads this too,
    /// so the sequencing stays in lockstep.
    static let dominoStagger: Double = 0.04

    /// How long all rows take to shrink/blur out together when the sidebar is
    /// toggled. ContentView reads this to know when they're gone.
    static let dominoExitDuration: Double = 0.14

    /// Blur radius rows carry while hidden -- large enough that the focus
    /// pull is clearly visible on the way out and in.
    static let dominoBlur: CGFloat = 12

    /// Sidebar collapse/expand: every row vanishes AT ONCE (blur + shrink
    /// toward nothing, no opacity -- these rows are GlassInteractive pills
    /// with their own VisualEffectBlur, and fading opacity on a glass surface
    /// dilutes its tint and flashes it grey, see FocusEffect/glassPop), then
    /// pops back in one by one, growing from near-zero scale with a springy
    /// overshoot and staggered top-to-bottom by `index` -- the TOP row
    /// starts first, each following row a beat later (the stagger is when
    /// each row's own pop BEGINS, not where it scales from -- every row
    /// still grows from its own center).
    static func dominoPop(index: Int) -> AnyTransition {
        .asymmetric(
            insertion: focus(blur: dominoBlur, scale: 0.05)
                .animation(Animation.dominoEnter(index: index)),
            removal: focus(blur: dominoBlur, scale: 0.05)
                .animation(Animation.dominoExit)
        )
    }

    /// Loose content on a surface: thumbnails, progress text, empty states,
    /// sub-rows. A short focus pull with only a light opacity assist so
    /// bright elements (blue chips, green ETA) don't read as glowing blobs
    /// at full blur.
    static let blurIn = AnyTransition.asymmetric(
        insertion: focus(blur: 5, scale: 0.97, opacity: 0.4)
            .animation(.easeOut(duration: 0.2)),
        removal: focus(blur: 4, scale: 0.98, opacity: 0.4)
            .animation(.easeIn(duration: 0.12))
    )

    /// `blurIn` that holds back for `delay` seconds and stays fully hidden until then (a capsule's
    /// text waiting for the capsule to finish growing, then for the title above it to appear).
    static func blurInAfter(_ delay: Double) -> AnyTransition {
        .asymmetric(
            insertion: focus(blur: 5, scale: 0.97, opacity: 0)
                .animation(.easeOut(duration: 0.25).delay(delay)),
            removal: focus(blur: 4, scale: 0.98, opacity: 0.4)
                .animation(.easeIn(duration: 0.12))
        )
    }

    /// Same as `blurIn`, anchored on the top edge -- for sections that unfold
    /// downward inside a card (Options, the format chips) so the content
    /// grows out of the header instead of scaling from its own centre while
    /// the card height is still animating open.
    static let blurInTop = AnyTransition.asymmetric(
        insertion: focus(blur: 5, scale: 0.97, opacity: 0.3, anchor: .top)
            .animation(.easeOut(duration: 0.22)),
        removal: focus(blur: 4, scale: 0.98, opacity: 0.3, anchor: .top)
            .animation(.easeIn(duration: 0.12))
    )

    /// Same as `blurIn`, but for text that appears beside an icon (sidebar
    /// labels): a blur and a light fade only, with NO scale -- the pill around
    /// it is what grows and shrinks (clipping the label as it goes), and a
    /// scaling label made rows look like they were resizing vertically.
    static let blurInLeading = AnyTransition.asymmetric(
        insertion: focus(blur: 4, scale: 1, opacity: 0.3, anchor: .leading)
            .animation(.easeOut(duration: 0.2).delay(0.06)),
        removal: focus(blur: 4, scale: 1, opacity: 0.3, anchor: .leading)
            .animation(.easeIn(duration: 0.1))
    )

    /// A sidebar label (tab names, tool names, "Drop"): fades in on the ambient
    /// animation, and leaves with a quick fade of its OWN. The collapse flips the
    /// labels in the very same transaction as the card's width, so every row's
    /// frame follows one curve; this keeps the text from lingering (and being
    /// clipped by the shrinking pill) for the whole width animation.
    static let labelFade = AnyTransition.asymmetric(
        insertion: .opacity,
        removal: AnyTransition.opacity.animation(.easeOut(duration: 0.15))
    )

    /// Tab-to-tab page change and the Video<->Audio section swap. The outgoing
    /// page is removed instantly (animating two full pages of glass at once was
    /// the single most expensive thing here, and a measured contributor to the
    /// app feeling sluggish/freezing when several cards updated at once) and
    /// the incoming one focuses in over a short, fixed-duration ease-out --
    /// deliberately not a spring: a spring's tail keeps the GPU compositing
    /// long after the motion is visually done.
    static let pageSwap = AnyTransition.asymmetric(
        insertion: focus(blur: 4, scale: 0.99, opacity: 0.6, anchor: .top)
            .animation(.easeOut(duration: 0.2)),
        removal: .identity
    )

    /// Centered overlay content (update sheet stages, popups): pops from
    /// slightly small out of a blur, leaves the same way in reverse.
    static let overlayPop = AnyTransition.asymmetric(
        insertion: focus(blur: 6, scale: 0.95)
            .animation(.easeOut(duration: 0.24)),
        removal: focus(blur: 4, scale: 0.97)
            .animation(.easeIn(duration: 0.14))
    )
}

enum DesignTokens {
    // Corner radii -- one scale used everywhere instead of ad-hoc numbers.
    // Widened the steps between tiers (was 8/12/16/20) so radius alone
    // signals hierarchy at a glance: small controls read tight and precise,
    // top-level containers read soft and roomy -- the jump between tiers
    // needs to be visible, not just technically different.
    enum Radius {
        static let small: CGFloat = 9      // chips, small icon buttons, badges
        static let medium: CGFloat = 14    // rows, inline controls
        static let large: CGFloat = 20     // cards, panels
        static let xlarge: CGFloat = 26    // top-level containers, menus
    }

    // Glass material -- shared black-frosted base + tint strengths.
    // Pushed noticeably darker/blacker than before so the material reads as
    // true black frosted glass at rest, not dark grey -- the tint depth is
    // what visually separates "alive glass" from a flat translucent panel.
    enum Glass {
        static let material: NSVisualEffectView.Material = .underWindowBackground
        // Lowered from 0.93 -- reported live as reading too black/flat,
        // both before the Liquid Glass detour and again after reverting
        // back to this system. Liquid Glass itself had to be abandoned (a
        // mini-LED display's local dimming crushed it to black at any
        // tint tried), but the underlying "too dark" complaint about THIS
        // system stands on its own and doesn't depend on that material --
        // lower opacity here reduces how much of the screen reads as
        // near-black regardless of which material is doing the blurring.
        static let blackTint: Double = 0.72
        static let blackTintDisabled: Double = 0.31
        static let whiteWash: Double = 0.02      // faint white wash to avoid flat black
    }

    // Interactive state opacities -- fill/stroke/glow at rest, hover, press.
    // Rest states pulled down further (quieter chrome at idle) while
    // hover/press/glow states pushed up (more pronounced feedback), so the
    // gap between "sitting there" and "being touched" is much wider --
    // this is the "alive" feeling: controls should visibly react, not just
    // acknowledge a hover.
    enum Interactive {
        static let fillRest: Double = 0.05
        static let fillActive: Double = 0.22
        static let fillHover: Double = 0.30
        static let fillPress: Double = 0.38

        static let strokeRest: Double = 0.16
        static let strokeHover: Double = 0.65
        static let strokeGlow: Double = 1.0
        static let strokePress: Double = 0.8
        static let strokeDisabled: Double = 0.06

        static let glowShadowHover: Double = 0.5
        static let glowShadowPeak: Double = 0.95
        static let glowRadiusHover: CGFloat = 14
        static let glowRadiusPress: CGFloat = 8

        static let scaleHover: CGFloat = 1.045
        static let scalePress: CGFloat = 0.95
    }

    // Text contrast -- meets a practical accessibility floor (foreground
    // opacity of ~0.6+ against the near-black glass reads comfortably;
    // primary text stays full white). Kept as named levels, not raw numbers,
    // so a future contrast pass only needs to change these once.
    enum Text {
        static let primary: Double = 1.0        // headlines, primary labels, active state
        static let secondary: Double = 0.78     // body copy, secondary labels
        static let tertiary: Double = 0.62      // captions, metadata, timestamps
        static let disabled: Double = 0.35      // disabled controls
    }

    // Spacing -- common padding values reused across pills/rows/cards.
    enum Spacing {
        static let tight: CGFloat = 4
        static let compact: CGFloat = 8
        static let comfortable: CGFloat = 12
        static let generous: CGFloat = 16
    }

    // Text-entry / display fields (path fields, dropdowns' resting chrome) --
    // functionally passive containers, not tappable controls, so they read
    // deliberately quieter than GlassInteractive's button/chip states at
    // rest. Kept as its own category (rather than reusing Interactive)
    // because "this holds a value" and "this is a button" are different
    // affordances and should never accidentally converge to the same look.
    enum Field {
        static let fillRest: Double = 0.05
        static let borderRest: Double = 0.12
        static let borderWidth: CGFloat = 0.75
        static let cornerRadius: CGFloat = Radius.medium
    }

    // Brand accent -- replaces the old flat system-blue literal
    // (0.18, 0.51, 1.0) that was scattered across every file as a raw value.
    // That blue read as generic macOS UI blue, not a considered brand color.
    // `primary` is deepened and given a violet lean so it feels closer to
    // Flighty's engineered "Ocean Blue" against black, and pairs naturally
    // with `glow`, a warmer secondary hue used only for the Siri-style
    // multi-tone shimmer on the most prominent active/selected states --
    // never for everyday chrome, so it stays special when it appears.
    enum Accent {
        static let primary   = Color(red: 0.22, green: 0.47, blue: 1.0)
        static let primaryLight = Color(red: 0.45, green: 0.65, blue: 1.0)
        static let glow       = Color(red: 0.62, green: 0.38, blue: 1.0)
        static let success   = Color(red: 0.20, green: 0.85, blue: 0.55)
        static let warning   = Color(red: 0.98, green: 0.62, blue: 0.16)
        static let danger    = Color(red: 1.0, green: 0.32, blue: 0.32)
    }
}

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var state: NSVisualEffectView.State = .active
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material     = material
        v.blendingMode = blendingMode
        v.state        = state
        // A freshly-inserted NSVisualEffectView needs a display pass before
        // its vibrancy/material fully settles -- AppKit briefly shows an
        // uninitialized, unclipped light/gray render on the very first
        // frame. When SwiftUI cross-fades a card in via `.transition
        // (.opacity)`, that fade is driven by the layer's own opacity
        // animation, which starts running before this first display pass
        // completes -- so new cards visibly flash gray-then-black instead
        // of cross-fading straight to the intended black-frosted look.
        // Disabling implicit layer animations on this view removes the
        // extra animated opacity pass AppKit would otherwise add on top of
        // SwiftUI's own transition, so the material renders in its final
        // state on the very first frame it's visible.
        v.wantsLayer = true
        v.layer?.actions = ["opacity": NSNull(), "hidden": NSNull(), "bounds": NSNull(), "position": NSNull()]
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material     = material
        nsView.blendingMode = blendingMode
        nsView.state        = state
    }
}

/// Frosted glass card modifier
// MARK: - Shared Glass Interactive Base
//
// One base every clickable control in the app should converge on, so hover/
// press/glow behavior stays identical everywhere -- icon buttons, pill
// buttons, chips, the clear-X, etc. Existing bespoke button structs
// (GlassButton, HoverIconButton, SkeletonCancelButton, SelectorChip, ...)
// are migrated onto this one at a time; the old ones stay in place until
// each migration is verified working, per zanderriley's request to test
// before replacing.
//
// GlassInteractiveShape lets call sites pick the outline that fits their
// context (round icon button vs. pill-shaped label button vs. rounded-rect
// chip) while sharing identical glow/hover/press physics underneath.
enum GlassInteractiveShape {
    case capsule
    case circle
    case roundedRect(CGFloat)
}

/// A capsule whose corners use .continuous (squircle-style smooth curvature) instead of plain
/// Capsule()'s .circular corners. Capsule's two semicircular ends meet the straight sides at a
/// genuine curvature DISCONTINUITY -- flat (zero curvature) snapping straight to the arc's full
/// curvature right at the tangent point, with nothing in between -- and a stroke traced around
/// that join visibly thins out exactly there (reported live: "where the flat edges meet the
/// corner radius... gets thinner than the top or the actual curve"), the same reason Apple's own
/// continuous/squircle corners exist for rounded rects. SwiftUI's RoundedRectangle already
/// supports .continuous, just not at a radius that tracks the view's own eventual height (a
/// capsule's radius is always exactly half of it) -- this computes that radius from the actual
/// rect handed to path(in:) and delegates to RoundedRectangle for the real continuous-corner math
/// rather than reimplementing it.
///
/// At EXACTLY radius = height/2 (a true capsule, no straight run at all on the short axis) each
/// semicircular end is really two 90° continuous corner curves glued together at the leftmost/
/// rightmost point -- each one blends from near-zero curvature (matching a straight edge) up to
/// its own peak partway through its own sweep, so the seam where they meet is where BOTH curves
/// are at their lowest local curvature, not the constant curvature a true semicircle would have
/// there. A stroke traced over that seam reads as very slightly thinner right at the midpoint
/// (reported live, after the fix above: "right in the middle of... where the corner radius meets
/// to make a half circle"). Backing the radius off by a hair gives each corner curve a real
/// (if visually imperceptible, well under half a point) straight segment to blend from on either
/// side instead of a zero-length seam, without reintroducing the original, far more visible
/// straight-to-curve discontinuity this shape exists to fix.
private let continuousCapsuleRadiusSlack: CGFloat = 0.4

struct ContinuousCapsule: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2 - continuousCapsuleRadiusSlack
        return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect)
    }
}

/// Shared glass hover/press/glow wrapper. Wrap any tappable content in this
/// to get the same liquid-glass interactive feel as every other control in
/// the app -- translucent base, brightening tint on hover, animated glow
/// ring, and a slight press-scale. `isActive` keeps a control visibly lit
/// even when not hovered (e.g. a selected chip); `disabled` dims it and
/// blocks interaction entirely.
struct GlassInteractive<Content: View>: View {
    var shape: GlassInteractiveShape = .capsule
    var tint: Color = .white
    var isActive: Bool = false
    var disabled: Bool = false
    // Interchangeable characteristic, not a one-off: the shared
    // fillActive/fillHover/fillPress opacity tokens were tuned for
    // chip-scale elements (TabChip, format/resolution pills). At a much
    // larger element (e.g. a full-width sidebar row) those same opacity
    // values spread a saturated tint across enough area to read as a
    // solid color block instead of a quiet wash. Rather than fork a
    // separate component, callers at a different visual scale can pass a
    // lighter opacity triple here; nil (the default) preserves the exact
    // existing behavior for every current caller.
    var activeFillOverride: (rest: Double, active: Double, hover: Double, press: Double)? = nil
    // Interchangeable characteristic: when true, this instance renders as
    // an inset control living INSIDE another glass surface (e.g. the
    // Paste & Analyze pill inside the urlCard field) rather than its own
    // independent glass surface. Skips the VisualEffectBlur/black-tint/
    // grain background and the rim stroke -- those would otherwise stack
    // on top of the parent surface's own blur+tint+stroke and read as a
    // visible second pill/seam. Keeps the tint wash + glow + press-scale
    // so it still feels interactive.
    var embedded: Bool = false
    // Interchangeable characteristic: normally embedded instances skip
    // BOTH the rim stroke and the hover scale-grow, relying purely on the
    // fill wash for hover feedback. Some embedded buttons (e.g. the large
    // Paste & Analyze pill) want the opposite: no scale-grow, no extra
    // fill wash, but a real glow outline on hover so the center keeps
    // reading as plain black glass. Setting this true re-enables just the
    // stroke+glow overlay while keeping the base blur/tint suppressed (no
    // doubled surface). Default false preserves existing embedded behavior.
    var embeddedGlowStroke: Bool = false
    // Interchangeable characteristic: overrides the shared hover/press
    // scale-grow amount. nil (default) preserves T.scaleHover/T.scalePress
    // for every existing caller. Pass (1.0, 1.0) to disable growth/shrink
    // entirely for a specific instance.
    var scaleOverride: (hover: CGFloat, press: CGFloat)? = nil
    // Interchangeable characteristic: overrides the shared rest-state rim
    // stroke opacity (T.strokeRest, 0.16). That default was tuned for
    // chip-scale elements sitting on a lighter/varied background; larger
    // full-width rows resting directly on their own black-frosted glass
    // parent (e.g. sidebar tabs on the sidebar's glassCard) need a
    // stronger line to read as a distinct control at all. nil preserves
    // existing behavior for every current caller.
    var restStrokeOverride: Double? = nil
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var hovering = false
    @State private var pressing = false

    var body: some View {
        let T = DesignTokens.Interactive.self
        let fRest = activeFillOverride?.rest ?? T.fillRest
        let fActive = activeFillOverride?.active ?? T.fillActive
        let fHover = activeFillOverride?.hover ?? T.fillHover
        let fPress = activeFillOverride?.press ?? T.fillPress
        let baseOpacity: Double = isActive ? fActive : 0.0
        let fillOpacity: Double = disabled ? baseOpacity : (pressing ? fPress : (hovering ? fHover : (baseOpacity == 0.0 ? fRest : baseOpacity)))
        let strokeOpacity: Double = disabled ? T.strokeDisabled : (pressing ? T.strokePress : (hovering ? T.strokeHover : (restStrokeOverride ?? T.strokeRest)))
        // While the pointer is over it (and it is not being pressed) the rim and glow breathe:
        // a Core Animation ring, not a SwiftUI repeatForever (see PulsingRing).
        let pulsing = hovering && !pressing && !disabled && (!embedded || embeddedGlowStroke)
        let glowRadius: CGFloat = (!disabled && hovering) ? (pressing ? T.glowRadiusPress : T.glowRadiusHover) : 0
        let scaleHoverAmt = scaleOverride?.hover ?? T.scaleHover
        let scalePressAmt = scaleOverride?.press ?? T.scalePress

        return Button(action: action) {
            content()
                .foregroundColor(tint.opacity(disabled ? DesignTokens.Text.disabled : (hovering ? DesignTokens.Text.primary : DesignTokens.Text.secondary)))
                .background(
                    ZStack {
                        if !embedded {
                            // Black-frosted-glass base, matching GlassCard/GlassButton.
                            // Skipped when embedded -- the parent surface
                            // (e.g. urlCard's outer capsule) already paints
                            // this; stacking it again doubles the tint and
                            // reads as a visible second pill.
                            VisualEffectBlur(material: DesignTokens.Glass.material, blendingMode: .behindWindow)
                            Color.black.opacity(disabled ? DesignTokens.Glass.blackTintDisabled : DesignTokens.Glass.blackTint)
                            DitherNoise(opacity: 0.035)
                        }
                        // Keyed on isActive so selecting/deselecting swaps the fill
                        // layer (chipFill) instead of lerping tint AND alpha together,
                        // which passed through a washed-out blue-grey. Hover/press only
                        // change alpha on the same layer, so they still animate in place.
                        tint.opacity(fillOpacity)
                            .id(isActive)
                            .transition(.chipFill(scale: 0.9))
                    }
                    .clipShape(clipShape)
                )
                .overlay(
                    Group {
                        // Embedded instances normally skip the rim stroke too --
                        // one outline (the parent capsule's) reads as one pill;
                        // a second inner stroke is exactly the seam we're
                        // trying to eliminate. embeddedGlowStroke opts back in
                        // for buttons that want a real glow ring on hover
                        // instead of relying on the fill wash alone.
                        if !embedded || embeddedGlowStroke {
                            clipShape
                                .stroke(tint.opacity(pulsing ? 0 : strokeOpacity), lineWidth: (disabled || !hovering) ? 0.75 : 1.1)
                        }
                    }
                    .shadow(color: tint.opacity(pulsing ? 0 : (glowRadius > 0 ? T.glowShadowHover : 0)), radius: glowRadius)
                    .overlay {
                        if pulsing {
                            PulsingRing(shape: shape, color: tint, lineWidth: 1.1, stroke: T.strokeHover...T.strokeGlow,
                                        glow: T.glowShadowHover...T.glowShadowPeak, glowRadius: T.glowRadiusHover, duration: 0.7)
                        }
                    }
                )
                .clipShape(clipShape)
                .scaleEffect(pressing ? scalePressAmt : (hovering ? scaleHoverAmt : 1.0))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !disabled { pressing = true } }
                .onEnded { _ in pressing = false }
        )
        .onHover { h in
            guard !disabled else { return }
            hovering = h
        }
        .animation(.easeOut(duration: 0.12), value: pressing)
        .animation(.easeOut(duration: 0.15), value: hovering)
        // Selection-state changes (isActive flipping, e.g. switching sidebar
        // tabs) drive both `tint` and the fill-opacity baseline together.
        // Without an explicit animation scoped to `isActive`, SwiftUI falls
        // back to an implicit default animation for that transaction --
        // out of sync with the hover/press curves above -- which let the
        // white "rest" tint's opacity ramp up and settle as flat neutral
        // gray for several frames before the color itself finished
        // interpolating to the accent blue. Scoping a single fast animation
        // to `isActive` makes color and opacity cross-fade together instead.
        .animation(.easeOut(duration: 0.12), value: isActive)
        .animation(.easeOut(duration: 0.12), value: tint)
    }

    private var clipShape: AnyShape {
        switch shape {
        case .capsule:
            return AnyShape(ContinuousCapsule())
        case .circle:
            return AnyShape(Circle())
        case .roundedRect(let r):
            return AnyShape(RoundedRectangle(cornerRadius: r, style: .continuous))
        }
    }
}

/// Very low-opacity procedural noise, tiled across the view it's applied
/// to. Breaks up 8-bit banding on large, near-black gradients (the app
/// background, glass card fills) where subtle color ramps would otherwise
/// show visible steps between shades. The noise tile is generated once
/// and repeated -- see the static `tile` below for why.
struct DitherNoise: View {
    var opacity: Double = 0.02

    // Fixed-size noise tile, generated ONCE per process (not per card, not
    // per frame). The old implementation ran a Canvas closure that redrew
    // every ~2.5pt cell from scratch on every geometry change -- with
    // several cards on screen each doing tens of thousands of individual
    // fill() calls, live-resizing the window recomputed all of them on
    // every frame, which is what caused the resize/scale lag. A small
    // static tile repeated via Image(_:).resizable(resizingMode: .tile)
    // costs nothing on resize since the pixel data itself never changes --
    // only the tile's on-screen repeat count does, which is nearly free.
    private static let tileSize = 64
    private static let tile: CGImage = {
        let size = tileSize
        var rng = SystemRandomNumberGenerator()
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for i in 0..<(size * size) {
            let v = Double.random(in: 0...1, using: &rng)
            let shade: UInt8 = v > 0.5 ? 255 : 0
            let a: UInt8 = UInt8((v > 0.5 ? v - 0.5 : (0.5 - v)) * 255 * 2)
            let o = i * 4
            pixels[o] = shade; pixels[o + 1] = shade; pixels[o + 2] = shade; pixels[o + 3] = a
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: &pixels, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }()

    var body: some View {
        Image(decorative: Self.tile, scale: 2, orientation: .up)
            .resizable(resizingMode: .tile)
            .opacity(opacity)
            .blendMode(.overlay)
            .allowsHitTesting(false)
    }
}

/// A card's rim: a 0.75pt ring with a diagonal gradient (white 0.30 at the
/// top-leading corner down to 0.05 at the bottom-trailing one). A CAGradientLayer
/// masked by a border-only layer, so the GPU composites it and a resize is just a
/// frame change -- no CPU shading. The mask layer uses the continuous corner
/// curve so it follows the card's SwiftUI `.continuous` rounded rectangle.
struct GlassRim: NSViewRepresentable {
    var cornerRadius: CGFloat
    /// For a card that grows and shrinks upward from a fixed bottom edge (the bottom
    /// bar): shade the rim by distance from the bottom edge, measured against the
    /// card's smallest height, instead of as a fraction of its current height. The
    /// gradient is stretched to the card's size, so on a card whose height changes a
    /// point on its edge would otherwise change colour every time it resizes.
    var anchoredToBottom: Bool = false

    func makeNSView(context: Context) -> GlassRimView {
        let v = GlassRimView(cornerRadius: cornerRadius)
        v.anchoredToBottom = anchoredToBottom
        return v
    }
    func updateNSView(_ view: GlassRimView, context: Context) {
        view.cornerRadius = cornerRadius
        view.anchoredToBottom = anchoredToBottom
    }
}

final class GlassRimView: NSView {
    private let gradient = CAGradientLayer()
    private let ring = CALayer()

    var cornerRadius: CGFloat {
        didSet { if cornerRadius != oldValue { needsLayout = true } }
    }
    var anchoredToBottom = false {
        didSet { if anchoredToBottom != oldValue { needsLayout = true } }
    }
    /// The smallest height this rim has been laid out at -- the bar's collapsed height.
    private var referenceHeight: CGFloat = 0

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        gradient.colors = [NSColor.white.withAlphaComponent(0.30).cgColor,
                           NSColor.white.withAlphaComponent(0.05).cgColor]
        // A layer's unit space has y pointing up here, so (0, 1) is top-leading.
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        ring.borderColor = NSColor.black.cgColor
        ring.borderWidth = 0.75
        ring.cornerCurve = .continuous
        gradient.mask = ring
        layer?.addSublayer(gradient)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        // No implicit animation: the rim must track the card's edge exactly
        // while it resizes.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        ring.frame = bounds
        ring.cornerRadius = cornerRadius
        updateGradientPoints()
        CATransaction.commit()
    }

    /// Default: corner to corner in the layer's unit space. Anchored: the same
    /// gradient, but its vertical part is measured in points from the bottom edge
    /// against `referenceHeight`, so it matches the default at that height and stays
    /// put at any other. With rho = height / referenceHeight, a linear gradient
    /// t = x/2 + (1 - rho*y)/2 over the unit square (y up) has axis from (0, 1/rho)
    /// to (2, 1/rho - 2 rho) / (1 + rho^2), i.e. exactly the default at rho = 1.
    private func updateGradientPoints() {
        guard anchoredToBottom, bounds.height > 0 else {
            gradient.startPoint = CGPoint(x: 0, y: 1)
            gradient.endPoint = CGPoint(x: 1, y: 0)
            return
        }
        referenceHeight = referenceHeight == 0 ? bounds.height : min(referenceHeight, bounds.height)
        let rho = bounds.height / referenceHeight
        let c = 1 + rho * rho
        let start = CGPoint(x: 0, y: 1 / rho)
        gradient.startPoint = start
        gradient.endPoint = CGPoint(x: start.x + 2 / c, y: start.y - 2 * rho / c)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        gradient.contentsScale = scale
        ring.contentsScale = scale
    }

    // Purely decorative: never takes a click or a hover.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The window's own background: the concept's soft radial glow, lightest near the
/// top-left and falling off to near-black at the far corner. A Core Animation
/// gradient layer (like GlassRim), so it is composited on the GPU and simply
/// resizes with the window instead of being re-shaded on the CPU every frame.
/// Sits on top of its own VisualEffectBlur (see ContentView.body) with semi-
/// transparent colors instead of the old fully-opaque ones, so the same real
/// blur-of-whatever's-behind-the-window that cards and the sidebar already
/// show carries through to the base background too, instead of stopping at
/// a flat painted gradient.
struct WindowBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowBackdropView { WindowBackdropView() }
    func updateNSView(_ nsView: WindowBackdropView, context: Context) {}
}

final class WindowBackdropView: NSView {
    private let gradient = CAGradientLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        gradient.type = .radial
        // CSS: radial-gradient(120% 90% at 18% 0%, #1b1b1b 0%, #101010 60%, #0c0c0c 100%).
        // Unit space here has y pointing up, so the glow's centre (18% across, the
        // top edge) is (0.18, 1); the end point sets the ellipse's radii, 120% of
        // the width across and 90% of the height down.
        gradient.startPoint = CGPoint(x: 0.18, y: 1)
        gradient.endPoint = CGPoint(x: 0.18 + 1.2, y: 1 - 0.9)
        gradient.colors = [
            NSColor(srgbRed: 0x1b / 255, green: 0x1b / 255, blue: 0x1b / 255, alpha: 0.75).cgColor,
            NSColor(srgbRed: 0x10 / 255, green: 0x10 / 255, blue: 0x10 / 255, alpha: 0.75).cgColor,
            NSColor(srgbRed: 0x0c / 255, green: 0x0c / 255, blue: 0x0c / 255, alpha: 0.75).cgColor,
        ]
        gradient.locations = [0, 0.6, 1]
        layer?.addSublayer(gradient)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        gradient.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Zero-mean dither for the window background: each pixel of a small tile is
/// white or black at 0-2/255 alpha, so it nudges the gradient's 8-bit steps by
/// a level either way without shifting its average brightness (DitherNoise's
/// overlay-blended tile lifts what it sits on by several levels, which would
/// have washed the backdrop out past the concept's colours).
struct WindowDither: View {
    private static let tile: CGImage = {
        let size = 64
        var rng = SystemRandomNumberGenerator()
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for i in 0..<(size * size) {
            let alpha = UInt8.random(in: 0...2, using: &rng)
            let white = Bool.random(using: &rng)
            let o = i * 4
            // Premultiplied: a white pixel's colour equals its alpha.
            let v: UInt8 = white ? alpha : 0
            pixels[o] = v; pixels[o + 1] = v; pixels[o + 2] = v; pixels[o + 3] = alpha
        }
        let ctx = CGContext(
            data: &pixels, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }()

    var body: some View {
        Image(decorative: Self.tile, scale: 2, orientation: .up)
            .resizable(resizingMode: .tile)
            .allowsHitTesting(false)
    }
}

/// The frosted fill of a card (blur, black tint, wash, grain), clipped to its
/// rounded shape -- shared by GlassCard and LiveGlassCard.
struct GlassFill: View {
    var cornerRadius: CGFloat
    var opacity: Double

    var body: some View {
        ZStack {
            // .underWindowBackground reads dark/neutral by default,
            // unlike .hudWindow which leans light -- the right base
            // for a true black-frosted-glass look.
            VisualEffectBlur(material: DesignTokens.Glass.material, blendingMode: .behindWindow)
            // Heavy black tint on top so the material reads as black
            // smoked glass, not grey.
            Color.black.opacity(DesignTokens.Glass.blackTint)
            Color.white.opacity(opacity * DesignTokens.Glass.whiteWash)
            // Fine grain across the frosted-glass fill -- breaks up
            // 8-bit banding on the near-black surface and gives the
            // card a textured, physical "frosted" quality instead of
            // a flat tinted panel.
            DitherNoise(opacity: 0.04)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// A card whose OUTLINE (glass, rim, glow) can stick out to the left of its
/// contents. While the sidebar moves, the outline follows the sidebar's edge frame
/// by frame -- cheap, only a shape changes -- while the contents are laid out once,
/// for where the sidebar will be, and never reflow mid-animation: opening, the
/// contents shrink at once and the outline narrows to meet them; collapsing, the
/// outline widens first and the contents take the new width at the end.
struct LiveGlassCard: ViewModifier {
    var cornerRadius: CGFloat = DesignTokens.Radius.large
    var opacity: Double = 0.55
    var isActive: Bool = false
    @Environment(\.sidebarLiveInset) private var live
    @Environment(\.cardContentInset) private var pinned

    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .modifier(LiveOutline(live: live, pinned: pinned, cornerRadius: cornerRadius, opacity: opacity, isActive: isActive))
    }
}

/// The animated half of LiveGlassCard: `live` is interpolated by SwiftUI, so the
/// outline's overhang (`pinned - live`, never negative) shrinks or grows smoothly.
private struct LiveOutline: ViewModifier, Animatable {
    var live: CGFloat
    var pinned: CGFloat
    var cornerRadius: CGFloat
    var opacity: Double
    var isActive: Bool
    var animatableData: CGFloat {
        get { live }
        set { live = newValue }
    }

    func body(content: Content) -> some View {
        let overhang = max(pinned - live, 0)
        content
            .background(alignment: .topLeading) {
                GeometryReader { geo in
                    GlassFill(cornerRadius: cornerRadius, opacity: opacity)
                        // Same specular rim as every card, drawn by Core Animation.
                        .overlay(GlassRim(cornerRadius: cornerRadius).allowsHitTesting(false))
                        .frame(width: geo.size.width + overhang, height: geo.size.height)
                        .offset(x: -overhang)
                }
            }
            .overlay(alignment: .topLeading) {
                if isActive {
                    GeometryReader { geo in
                        RimBeam(cornerRadius: cornerRadius)
                            .frame(width: geo.size.width + overhang, height: geo.size.height)
                            .offset(x: -overhang)
                    }
                    .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    func liveGlassCard(cornerRadius: CGFloat = DesignTokens.Radius.large, opacity: Double = 0.55, isActive: Bool = false) -> some View {
        modifier(LiveGlassCard(cornerRadius: cornerRadius, opacity: opacity, isActive: isActive))
    }
}

struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = DesignTokens.Radius.large
    var opacity: Double = 0.55
    /// See GlassRim.anchoredToBottom.
    var rimAnchoredToBottom: Bool = false
    // When true, a Tron-style light beam travels around the card's rim --
    // reserved for active/in-progress states (e.g. a link being analyzed),
    // not a resting decoration. Cards are calm and still until something is
    // actually happening.
    var isActive: Bool = false

    func body(content: Content) -> some View {
        content
            .background(GlassFill(cornerRadius: cornerRadius, opacity: opacity))
            .overlay(
                // Static, quiet rim running the full perimeter: bright at the
                // top-leading corner, dimmest at the bottom-trailing one -- a
                // diagonal specular catch rather than a flat uniform ring. This
                // is the resting state for every card, active or not.
                //
                // Drawn by Core Animation (see GlassRim), not by SwiftUI: a
                // SwiftUI gradient stroke is shaded by CoreGraphics on the CPU
                // over the card's whole bounds every time the card's size
                // changes (window drag, sidebar collapse, cards appearing) --
                // about a fifth of the main thread's time during a drag with
                // several cards on screen. A gradient layer is composited on the
                // GPU and just resizes.
                GlassRim(cornerRadius: cornerRadius, anchoredToBottom: rimAnchoredToBottom)
                    .allowsHitTesting(false)
            )
            .overlay {
                if isActive {
                    RimBeam(cornerRadius: cornerRadius)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Thumbnail-loading placeholder -- a plain, quiet fill while a thumbnail
/// hasn't resolved yet. Used to breathe between two opacities (a Core
/// Animation layer, see the old PulsingSkeleton); removed per the user's
/// call to drop every pulse from the card system -- the same reasoning
/// already applied once to the metadata capsule ("remove the pulsing glow
/// entirely for the cards, all we need is the light rim which works great").
struct ThumbnailSkeleton: View {
    var body: some View {
        SkeletonFill(cornerRadius: 0)
    }
}

/// The same plain skeleton fill ThumbnailSkeleton uses, at a caller-chosen
/// corner radius (PreviewCard's title-bar placeholder).
struct SkeletonFill: View {
    var cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.white.opacity(DesignTokens.Interactive.fillRest * 0.6))
    }
}

/// Waiting-for-paste cue shown around the field only while it's focused
/// and still empty -- a slim, controlled bar of light along the rim
/// rather than a diffuse halo. Restrained pulsate range, no interior
/// fill, and hit-testing disabled so it never blocks clicks/typing into
/// the field underneath. Turns off the instant text lands or focus
/// moves elsewhere.
///
/// A Core Animation layer, not a SwiftUI `repeatForever`: the pulse runs in the render
/// server, so the cue costs the app nothing per frame. Driven from SwiftUI it kept the
/// whole window re-laying-out and re-rendering at the display rate, ~25% of a core, for as
/// long as the empty field had focus (which is most of the time Drop is open).
struct WaitingPulseGlow: NSViewRepresentable {
    func makeNSView(context: Context) -> WaitingPulseGlowView { WaitingPulseGlowView() }
    func updateNSView(_ nsView: WaitingPulseGlowView, context: Context) {}
}

final class WaitingPulseGlowView: NSView {
    private let ring = CAShapeLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        ring.fillColor = nil
        ring.lineWidth = 1.5
        ring.strokeColor = NSColor.white.withAlphaComponent(0.3).cgColor
        ring.shadowColor = NSColor.white.cgColor
        ring.shadowOffset = .zero
        ring.shadowOpacity = 0.2
        // SwiftUI's shadow radius is twice a layer's, so 3 -> 6 there is 1.5 -> 3 here.
        ring.shadowRadius = 1.5
        layer?.addSublayer(ring)

        func pulse(_ keyPath: String, from: Any, to: Any) {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = from
            animation.toValue = to
            animation.duration = 1.3
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ring.add(animation, forKey: keyPath)
        }
        pulse("strokeColor", from: NSColor.white.withAlphaComponent(0.3).cgColor, to: NSColor.white.withAlphaComponent(0.55).cgColor)
        pulse("shadowOpacity", from: Float(0.2), to: Float(0.45))
        pulse("shadowRadius", from: CGFloat(1.5), to: CGFloat(3))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        // No implicit animation: the ring must follow the field's edge exactly.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        // A capsule traced on the view's own edge, like `Capsule().stroke`.
        let radius = min(bounds.width, bounds.height) / 2
        ring.path = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        ring.contentsScale = window?.backingScaleFactor ?? 2
    }

    // Purely decorative: never takes a click or a hover.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A ring around a control whose stroke and glow breathe between two strengths for as long
/// as it is on screen: the pulse that runs while the pointer is over a glass control
/// (GlassInteractive), a selector chip (SelectorChip) or a segment (SegmentButton). Add it
/// only while that is true.
///
/// A Core Animation layer, not a SwiftUI `repeatForever`: driven from SwiftUI, one hovered
/// control kept the whole window laying out and re-rendering at the display rate -- measured
/// at ~26% of a core for as long as the pointer sat on a selected segment, against 0.1% on
/// an unselected one, which is what made the Convert card feel laggy. The render server runs
/// this one for free.
struct PulsingRing: NSViewRepresentable {
    var shape: GlassInteractiveShape
    var color: Color
    var lineWidth: CGFloat
    /// The stroke's opacity at the two ends of the pulse.
    var stroke: ClosedRange<Double>
    /// The glow's opacity at the two ends of the pulse.
    var glow: ClosedRange<Double>
    /// The glow's radius in SwiftUI's units (a layer's is half of that).
    var glowRadius: CGFloat
    /// One way across, in seconds (it reverses).
    var duration: Double = 0.7

    func makeNSView(context: Context) -> PulsingRingView { PulsingRingView() }
    func updateNSView(_ view: PulsingRingView, context: Context) {
        view.update(shape: shape, color: NSColor(color), lineWidth: lineWidth, stroke: stroke,
                    glow: glow, glowRadius: glowRadius / 2, duration: duration)
    }
}

final class PulsingRingView: NSView {
    private let ring = CAShapeLayer()
    private var shape: GlassInteractiveShape = .capsule
    /// What the animations were built from, so an unchanged update leaves them running.
    private var built = ""

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        ring.fillColor = nil
        ring.shadowOffset = .zero
        layer?.addSublayer(ring)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(shape: GlassInteractiveShape, color: NSColor, lineWidth: CGFloat, stroke: ClosedRange<Double>,
                glow: ClosedRange<Double>, glowRadius: CGFloat, duration: Double) {
        self.shape = shape
        needsLayout = true
        let key = "\(color)|\(lineWidth)|\(stroke)|\(glow)|\(glowRadius)|\(duration)"
        guard key != built else { return }
        built = key
        ring.lineWidth = lineWidth
        ring.shadowColor = color.cgColor
        ring.shadowRadius = glowRadius
        ring.strokeColor = color.withAlphaComponent(stroke.lowerBound).cgColor
        ring.shadowOpacity = Float(glow.lowerBound)
        ring.removeAllAnimations()
        func pulse(_ keyPath: String, from: Any, to: Any) {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = from
            animation.toValue = to
            animation.duration = duration
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ring.add(animation, forKey: keyPath)
        }
        pulse("strokeColor", from: color.withAlphaComponent(stroke.lowerBound).cgColor, to: color.withAlphaComponent(stroke.upperBound).cgColor)
        pulse("shadowOpacity", from: Float(glow.lowerBound), to: Float(glow.upperBound))
    }

    override func layout() {
        super.layout()
        // No implicit animation: the ring must follow the control's edge exactly.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Also set here, not just in viewDidChangeBackingProperties below -- that only fires on
        // an actual SCALE CHANGE (e.g. dragging the window to a different display), never on a
        // view's first attachment to its (already-Retina) window, so contentsScale was silently
        // left at its 1.0 default for the ring's entire life on a single-display Mac. Core
        // Animation rasterizes a CAShapeLayer's shadow (the hover glow) at contentsScale, then
        // the compositor upscales that bitmap to fit the real pixel grid -- at 1.0 on a 2x
        // display that's exactly what showed as visible blockiness around the stroke, worst on
        // the curved corners where under-sampling is most visible (reported live). layout()
        // itself always runs before the first paint, so this reliably catches the case
        // viewDidChangeBackingProperties never fires for.
        ring.contentsScale = window?.backingScaleFactor ?? 2
        ring.frame = bounds
        switch shape {
        case .capsule:
            // .continuous corners (via ContinuousCapsule, see its own doc comment), not
            // CGPath's plain circular-corner roundedRect -- that's a genuine curvature
            // discontinuity right where the straight side meets the arc, which traced a glow
            // that visibly thinned out exactly there (reported live). Routed through SwiftUI's
            // own continuous-corner math (.cgPath) rather than reimplemented by hand, so the
            // glow traces the identical path GlassInteractive's stroke does -- same reasoning
            // as GlassInteractive's own clipShape using ContinuousCapsule now.
            ring.path = ContinuousCapsule().path(in: bounds).cgPath
        case .circle:
            ring.path = CGPath(ellipseIn: bounds, transform: nil)
        case .roundedRect(let radius):
            // Same reasoning as .capsule above -- GlassInteractive's own stroke for this shape
            // is already .continuous (see its clipShape), so the glow should trace the same path.
            let r = min(radius, min(bounds.width, bounds.height) / 2)
            ring.path = RoundedRectangle(cornerRadius: r, style: .continuous).path(in: bounds).cgPath
        }
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        ring.contentsScale = window?.backingScaleFactor ?? 2
    }

    // Purely decorative: never takes a click or a hover.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Rim glow for the big capsule header bars (urlCard, Convert's dropZoneView,
/// History's searchHeader) -- brightens the outer stroke and adds a soft
/// white shadow whenever the bar is hovered OR actively focused/selected
/// (e.g. the paste field has a cursor in it), then eases back to resting
/// the instant neither is true. A plain brighten/fade rather than
/// WaitingPulseGlow's repeating pulse -- these are large full-bleed
/// surfaces the user interacts with directly, not a passive "waiting for
/// input" cue, so a steady lit-up state reads as direct feedback instead
/// of competing decoration.
struct HoverGlowRim: View {
    let isActive: Bool

    var body: some View {
        Capsule()
            .stroke(Color.white.opacity(isActive ? 0.6 : 0), lineWidth: 1.5)
            .shadow(color: Color.white.opacity(isActive ? 0.35 : 0), radius: isActive ? 8 : 0)
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.2), value: isActive)
    }
}

/// A bright dot of light that travels continuously around a card's rim,
/// like a car on a racetrack -- used only while that card represents
/// something actively in progress (e.g. a link being analyzed). Stops the
/// instant the work finishes; never a resting/decorative state.
///
/// Earlier versions of this effect used `.trim(from:to:)` directly on a
/// `RoundedRectangle` path and drove the trim window forward over time.
/// That still visibly sped up and slowed down and momentarily vanished at
/// the seam, because `.trim` divides a rounded-rect's path into fixed
/// *parametric* segments (one span per straight edge, one per corner arc)
/// that do not correspond 1:1 with true on-screen distance once the
/// card's width and height differ a lot -- a wide, short card has two long
/// horizontal edges and two short corner arcs, but the path's own internal
/// parameterization does not necessarily give the long edges a
/// proportionally larger share of the 0...1 trim range. The result: the
/// dot visibly eased through some stretches and rushed through others
/// even though the trim fraction itself advanced at a perfectly constant
/// rate -- the geometry was lying about distance, not the timing code.
///
/// This version sidesteps `.trim` entirely. It builds the rim as an
/// explicit ordered list of points (straight-edge endpoints plus densely
/// sampled quarter-circle arc points), measures the true cumulative
/// distance between consecutive points, and walks a short trailing window
/// of those points forward at a constant real-world speed (perimeter
/// distance per second, derived from the measured total perimeter and
/// cyclesPerSecond). Because every step is a measured distance rather
/// than a path parameter fraction, the trail moves at one constant visual
/// speed around every straight edge and every corner, with no easing and
/// no seam. Per-segment colors are computed individually (via Canvas)
/// rather than with a screen-space LinearGradient, since a fixed
/// leading-to-trailing gradient would only look correct while the trail
/// happens to be horizontal -- it needs to fade correctly whether the
/// trail is running along a vertical edge or curling through a corner.
struct RimBeam: View {
    var cornerRadius: CGFloat
    /// Length of the bright trail as a fraction of the full perimeter.
    var headLength: CGFloat = 0.16
    /// Full loops per second around the perimeter.
    var cyclesPerSecond: Double = 1.0 / 1.8

    /// One sample point along the rim, with its true cumulative distance
    /// (in points) from the start of the path.
    private struct RimPoint {
        var position: CGPoint
        var distance: CGFloat
    }

    /// Walks the rounded rect's rim clockwise starting just right of the
    /// top-left corner, sampling straight edges as single endpoints and
    /// corners as dense arcs, and returns points annotated with true
    /// cumulative distance. Arc samples are spaced ~2pt apart so the path
    /// reads as perfectly smooth at any card size used in this app.
    private static func rimPoints(size: CGSize, cornerRadius: CGFloat) -> [RimPoint] {
        let r = min(cornerRadius, min(size.width, size.height) / 2)
        let w = size.width
        let h = size.height
        var points: [CGPoint] = []

        func arc(center: CGPoint, startAngle: CGFloat, endAngle: CGFloat) {
            let arcLength = r * abs(endAngle - startAngle)
            let steps = max(2, Int((arcLength / 2).rounded(.up)))
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let angle = startAngle + (endAngle - startAngle) * t
                points.append(CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle)))
            }
        }

        // Walk clockwise in SwiftUI's y-down space: top edge -> top-right
        // corner -> right edge -> bottom-right corner -> bottom edge ->
        // bottom-left corner -> left edge -> top-left corner -> back to
        // the first point.
        points.append(CGPoint(x: r, y: 0))
        points.append(CGPoint(x: w - r, y: 0))
        arc(center: CGPoint(x: w - r, y: r), startAngle: -.pi / 2, endAngle: 0)
        points.append(CGPoint(x: w, y: h - r))
        arc(center: CGPoint(x: w - r, y: h - r), startAngle: 0, endAngle: .pi / 2)
        points.append(CGPoint(x: r, y: h))
        arc(center: CGPoint(x: r, y: h - r), startAngle: .pi / 2, endAngle: .pi)
        points.append(CGPoint(x: 0, y: r))
        arc(center: CGPoint(x: r, y: r), startAngle: .pi, endAngle: 3 * .pi / 2)
        // Implicitly closes back to the very first point (r, 0).

        var result: [RimPoint] = []
        result.reserveCapacity(points.count)
        var cumulative: CGFloat = 0
        var previous = points[0]
        for p in points {
            cumulative += hypot(p.x - previous.x, p.y - previous.y)
            result.append(RimPoint(position: p, distance: cumulative))
            previous = p
        }
        return result
    }

    @State private var start: Date = Date()
    /// The beam holds still while the window is being dragged (see
    /// LiveResizeState) and resumes from the current time when it ends.
    @ObservedObject private var liveResize = LiveResizeState.shared

    var body: some View {
        GeometryReader { geo in
            let rim = Self.rimPoints(size: geo.size, cornerRadius: cornerRadius)
            let perimeter = max(rim.last?.distance ?? 1, 1)
            TimelineView(.animation(paused: liveResize.isActive)) { timeline in
                let elapsed = timeline.date.timeIntervalSince(start)
                let phase = CGFloat((elapsed * cyclesPerSecond).truncatingRemainder(dividingBy: 1.0))
                trail(rim: rim, perimeter: perimeter, headPhase: phase)
            }
        }
        .allowsHitTesting(false)
        .onAppear { start = Date() }
    }

    /// Returns the interpolated rim position at a given cumulative
    /// distance, wrapping around the perimeter. Linear interpolation
    /// between the two bracketing sampled points keeps the trail smooth
    /// even between discrete sample steps.
    private func position(at distance: CGFloat, rim: [RimPoint], perimeter: CGFloat) -> CGPoint {
        let wrapped = distance.truncatingRemainder(dividingBy: perimeter)
        let target = wrapped < 0 ? wrapped + perimeter : wrapped
        var lo = 0
        var hi = rim.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if rim[mid].distance < target { lo = mid + 1 } else { hi = mid }
        }
        let idx = max(1, lo)
        let a = rim[idx - 1]
        let b = rim[idx]
        let span = max(b.distance - a.distance, 0.0001)
        let t = (target - a.distance) / span
        return CGPoint(x: a.position.x + (b.position.x - a.position.x) * t,
                        y: a.position.y + (b.position.y - a.position.y) * t)
    }

    @ViewBuilder
    private func trail(rim: [RimPoint], perimeter: CGFloat, headPhase: CGFloat) -> some View {
        // Sample the bright trail as a short run of points ending at the
        // current head position, spaced evenly by true distance rather
        // than by path-parameter fraction -- this is what guarantees
        // constant visual speed through corners and straight edges alike.
        let headDistance = headPhase * perimeter
        let trailLength = headLength * perimeter
        let sampleCount = 28
        let trailPoints: [CGPoint] = (0...sampleCount).map { i in
            let back = trailLength * (1 - CGFloat(i) / CGFloat(sampleCount))
            return position(at: headDistance - back, rim: rim, perimeter: perimeter)
        }

        Canvas { context, _ in
            guard trailPoints.count > 1 else { return }
            for i in 1..<trailPoints.count {
                // Fade from fully transparent at the tail (i == 1) to
                // fully bright at the head (i == last), interpolating
                // between the two accent tones near the very tip.
                let t = Double(i) / Double(trailPoints.count - 1)
                let color: Color = t > 0.75
                    ? DesignTokens.Accent.primaryLight.opacity(min(1, (t - 0.75) / 0.25 * 0.4 + 0.6))
                    : DesignTokens.Accent.primary.opacity(t * t)
                var segment = Path()
                segment.move(to: trailPoints[i - 1])
                segment.addLine(to: trailPoints[i])
                context.stroke(segment, with: .color(color), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
        }
        // One shadow pass instead of two -- the second, tighter-radius shadow
        // added a second full blur pass for a bloom that's barely visible over
        // the first at this stroke width.
        .shadow(color: DesignTokens.Accent.primary.opacity(0.55), radius: 5)
    }
}
