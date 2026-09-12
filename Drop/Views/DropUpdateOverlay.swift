import SwiftUI
import Sparkle

/// Replaces Sparkle's native AppKit alert windows entirely with an in-app
/// overlay matching Drop's own black-glass design. Every method here is
/// called directly by Sparkle's internal state machine, which for methods
/// taking a `reply`/`acknowledgement`/completion block WAITS on that call --
/// skipping one, even on an error/edge path, leaves the updater hung
/// indefinitely rather than merely showing a blank screen. Every path below
/// is written to always eventually call whatever handler it was given.
@MainActor
final class DropCustomUserDriver: NSObject, SPUUserDriver, ObservableObject {
    enum Stage {
        case idle
        // Tracked but deliberately invisible -- the shared Check for
        // Updates button already shows "Checking…" in the sidebar, and a
        // second, separate popup for the same brief moment was one too many
        // places announcing the same thing.
        case checking
        // Carries just the display data actually used (version string,
        // notes HTML) rather than a real SUAppcastItem -- Sparkle only ever
        // vends one of those from inside a genuine update check, which
        // would make a Dev-tab preview button impossible to build without
        // fabricating a fake Sparkle-internal object.
        case updateFound(versionString: String, notesHTML: String?, reply: (SPUUserUpdateChoice) -> Void)
        case downloading(progress: Double?)   // nil while content length is still unknown
        case extracting(progress: Double)
        case readyToInstall(reply: (SPUUserUpdateChoice) -> Void)
        case installing
        // Carries its own acknowledgement rather than calling it eagerly --
        // Sparkle tears the whole update session down shortly after
        // receiving it (that's what "acknowledge the error was shown"
        // triggers), which was wiping this overlay after about a second
        // when it was called the moment the card first appeared. Deferring
        // it to dismissError() means Sparkle doesn't clean up until the
        // user has actually seen and dismissed it.
        case error(message: String, acknowledgement: () -> Void)
        // .notFound deliberately has no visible overlay -- the shared Check
        // for Updates button already turns green with "Up to Date" for this
        // exact case (DropUpdater.justConfirmedUpToDate), so a second,
        // redundant confirmation here would just be noise.
    }

    @Published var stage: Stage = .idle

    /// The shared Check for Updates button derives its "checking" state from
    /// this, not from DropUpdater's separate SPUUpdaterDelegate callback --
    /// that callback and this driver are notified independently by Sparkle,
    /// and don't fire in lockstep once the driver is waiting on the user to
    /// dismiss something (observed: the button kept saying "Checking…" for
    /// several seconds after the error card had already been dismissed).
    /// `stage` is always authoritative for what's actually on screen right
    /// now, so deriving from it directly can't drift out of sync with it.
    var isActivelyChecking: Bool {
        if case .checking = stage { return true }
        return false
    }

    /// True while the overlay has something actionable on screen for an
    /// update (found/downloading/extracting/ready/installing) -- the Drop
    /// row's equivalent of yt-dlp/ffmpeg's "update available" orange state.
    var hasActionableUpdate: Bool {
        switch stage {
        case .updateFound, .downloading, .extracting, .readyToInstall, .installing: return true
        default: return false
        }
    }

    /// Set directly by this driver the moment Sparkle reports no update
    /// found -- not by a separate SPUUpdaterDelegate callback, which
    /// (observed firsthand) does not reliably fire in step with this driver
    /// once a user-interaction wait (like the error card) is involved.
    /// This is the single object Sparkle actually hands every real-time
    /// state to, so deriving everything from it can't drift out of sync
    /// with what's on screen the way splitting state across two
    /// independently-notified Sparkle extension points did.
    @Published var justConfirmedUpToDate = false

    private var cancelCheckBlock: (() -> Void)?
    private var cancelDownloadBlock: (() -> Void)?
    private var expectedContentLength: UInt64 = 0
    private var receivedContentLength: UInt64 = 0

    // MARK: Permission
    //
    // SUEnableAutomaticChecks is already set explicitly in Info.plist, so
    // Sparkle should never actually ask -- but must still reply immediately
    // if it somehow does, or the updater hangs waiting forever.
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        cancelCheckBlock = cancellation
        justConfirmedUpToDate = false
        withAnimation { stage = .checking }
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // Inline notes (CDATA in the appcast) are available immediately via
        // itemDescription; a releaseNotesURL-linked file instead arrives
        // later through showUpdateReleaseNotes(with:), if present at all.
        justConfirmedUpToDate = false
        withAnimation { stage = .updateFound(versionString: appcastItem.displayVersionString, notesHTML: appcastItem.itemDescription, reply: reply) }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        guard case .updateFound(let versionString, _, let reply) = stage else { return }
        let html = String(data: downloadData.data, encoding: .utf8)
        stage = .updateFound(versionString: versionString, notesHTML: html, reply: reply)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        // Non-fatal: whatever inline description was already shown (or none)
        // stays as-is -- the Install/Later choice doesn't depend on this.
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        justConfirmedUpToDate = true
        withAnimation { stage = .idle }
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        withAnimation { stage = .error(message: error.localizedDescription, acknowledgement: acknowledgement) }
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        cancelDownloadBlock = cancellation
        expectedContentLength = 0
        receivedContentLength = 0
        withAnimation { stage = .downloading(progress: nil) }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        self.expectedContentLength = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedContentLength += length
        guard expectedContentLength > 0 else { return }
        stage = .downloading(progress: Double(receivedContentLength) / Double(expectedContentLength))
    }

    func showDownloadDidStartExtractingUpdate() {
        withAnimation { stage = .extracting(progress: 0) }
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        stage = .extracting(progress: progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        withAnimation { stage = .readyToInstall(reply: reply) }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        withAnimation { stage = .installing }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        cancelCheckBlock = nil
        cancelDownloadBlock = nil
        withAnimation { stage = .idle }
    }

    // MARK: Actions the overlay UI calls back into

    func cancelCheck() { cancelCheckBlock?() }
    func cancelDownload() { cancelDownloadBlock?() }

    /// Dev-tab-only: shows the real update-found overlay with sample data,
    /// with no actual Sparkle update behind it -- Install/Skip/Later all
    /// just dismiss, since there's nothing real to act on. Exists purely so
    /// the overlay's design can be checked without needing a real published
    /// version newer than the one currently running.
    func previewUpdateFound() {
        withAnimation {
            stage = .updateFound(
                versionString: "9.9.9",
                notesHTML: "<p>This is a preview of the update overlay -- sample release notes, not a real update.</p><p>- Example bullet one<br>- Example bullet two</p>",
                reply: { [weak self] _ in withAnimation { self?.stage = .idle } }
            )
        }
    }
    func dismissError() {
        if case .error(_, let acknowledgement) = stage { acknowledgement() }
        stage = .idle
    }
}

/// The actual overlay UI, attached once at the ContentView root so it can
/// appear regardless of which tab is active -- an update can be found at
/// any time, not only while the Dev tab happens to be open.
struct DropUpdateOverlayView: View {
    @ObservedObject var driver: DropCustomUserDriver

    var body: some View {
        Group {
            switch driver.stage {
            case .idle:
                EmptyView()
            case .checking:
                // No overlay -- the shared Check for Updates button already
                // shows this in the sidebar.
                EmptyView()
            case .updateFound(let versionString, let notesHTML, let reply):
                updateFoundCard(versionString: versionString, notesHTML: notesHTML, reply: reply)
            case .downloading(let progress):
                card {
                    Text("Downloading update…").font(.appMono(size: 13, weight: .medium)).foregroundColor(.white.opacity(DesignTokens.Text.primary))
                    if let progress {
                        ProgressView(value: progress).frame(width: 240).tint(DesignTokens.Accent.primary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            case .extracting(let progress):
                card {
                    Text("Extracting…").font(.appMono(size: 13, weight: .medium)).foregroundColor(.white.opacity(DesignTokens.Text.primary))
                    ProgressView(value: progress).frame(width: 240).tint(DesignTokens.Accent.primary)
                }
            case .readyToInstall(let reply):
                card {
                    Image(systemName: "checkmark.circle.fill").font(.appMono(size: 22)).foregroundColor(DesignTokens.Accent.success)
                    Text("Ready to install").font(.appMono(size: 14, weight: .semibold)).foregroundColor(.white.opacity(DesignTokens.Text.primary))
                    Text("Drop will quit and relaunch on the new version.").font(.appMono(size: 11)).foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                    HStack(spacing: 10) {
                        GlassButton(label: "Later", icon: "clock", tint: .white, fitContent: true) { reply(.dismiss) }
                        GlassButton(label: "Install & Relaunch", icon: "arrow.triangle.2.circlepath", tint: DesignTokens.Accent.primary, fitContent: true) { reply(.install) }
                    }
                }
            case .installing:
                card {
                    ProgressView().controlSize(.small)
                    Text("Installing update…").font(.appMono(size: 13)).foregroundColor(.white.opacity(DesignTokens.Text.secondary))
                }
            case .error(let message, _):
                card {
                    Image(systemName: "exclamationmark.triangle.fill").font(.appMono(size: 20)).foregroundColor(DesignTokens.Accent.danger)
                    Text("Update Check Failed").font(.appMono(size: 14, weight: .semibold)).foregroundColor(.white.opacity(DesignTokens.Text.primary))
                    Text(message).font(.appMono(size: 11)).foregroundColor(.white.opacity(DesignTokens.Text.secondary)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    GlassButton(label: "Dismiss", icon: "xmark", tint: .white, fitContent: true) { driver.dismissError() }
                }
            }
        }
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 12) { content() }
                .padding(24)
                .frame(maxWidth: 360)
                .glassCard(cornerRadius: DesignTokens.Radius.large)
        }
        .transition(.opacity)
    }

    private func updateFoundCard(versionString: String, notesHTML: String?, reply: @escaping (SPUUserUpdateChoice) -> Void) -> some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill").foregroundColor(DesignTokens.Accent.primary).font(.appMono(size: 16))
                    Text("Drop \(versionString) is available")
                        .font(.appMono(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(DesignTokens.Text.primary))
                }

                if let notesHTML, let attributed = try? AttributedString(
                    markdown: Self.stripHTML(notesHTML),
                    options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                ) {
                    ScrollView {
                        Text(attributed)
                            .font(.appMono(size: 11.5))
                            .foregroundColor(.white.opacity(DesignTokens.Text.secondary))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                } else {
                    Text("No release notes provided.")
                        .font(.appMono(size: 11.5))
                        .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                }

                HStack(spacing: 10) {
                    Spacer()
                    GlassButton(label: "Skip", icon: "forward", tint: .white, fitContent: true) { reply(.skip) }
                    GlassButton(label: "Later", icon: "clock", tint: .white, fitContent: true) { reply(.dismiss) }
                    GlassButton(label: "Install", icon: "arrow.down.circle", tint: DesignTokens.Accent.primary, fitContent: true) { reply(.install) }
                }
            }
            .padding(24)
            .frame(maxWidth: 440)
            .glassCard(cornerRadius: DesignTokens.Radius.large)
        }
        .transition(.opacity)
    }

    /// Release notes from generate_appcast are simple HTML (a paragraph of
    /// plain text and line breaks, per DevReleasePipeline's own notes.html)
    /// -- stripping tags is enough to get clean, readable text without
    /// pulling in a full HTML renderer for what's normally a short changelog.
    private static func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<br/>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
