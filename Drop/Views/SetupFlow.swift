import SwiftUI

/// Whether Drop has Full Disk Access. macOS has no prompt for it -- an app can only be listed (switched
/// off) and send the user to Settings -- so the usual test is whether the system's own permission
/// database, which sits behind it, can be opened.
enum FullDiskAccess {
    static var isGranted: Bool {
        let descriptor = Darwin.open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        guard descriptor >= 0 else { return false }
        Darwin.close(descriptor)
        return true
    }
}

/// Drop's setup: get the tools, allow Full Disk Access, optionally sign in to YouTube. It is the only
/// setup there is. It cannot be skipped as a whole: the tools are required, and only the Full Disk
/// Access and sign-in steps (which are optional) have a skip. Shown over whatever tab is up, on a
/// fresh install, whenever the tools turn out to be missing, and from the app menu's "Set Up Drop...".
@MainActor
final class SetupFlow: ObservableObject {
    static let shared = SetupFlow()

    enum Step: Int, CaseIterable { case tools, diskAccess, signIn, done }

    @Published private(set) var isPresented = false
    @Published private(set) var step: Step = .tools
    /// True while showing the Dev tab's preview: the tools step runs on simulated progress and
    /// finishing does not count as having completed the real setup.
    @Published private(set) var isPreview = false
    /// Only the tools step, for an install that finished setup before but has lost its tools (the
    /// network dropped mid-download, or they were deleted). Nothing else needs asking again.
    @Published private(set) var toolsOnly = false
    @Published private(set) var diskAccessGranted = false
    /// 0...1, only advanced while previewing.
    @Published private(set) var previewProgress: Double = 0

    /// Where the YouTube sign-in step stands. The browser is only saved as Drop's cookie source once
    /// its login has actually been found, so a choice that did not work is never remembered.
    enum SignInState: Equatable { case idle, checking, signedIn, notSignedIn, blocked, failed(String) }
    @Published private(set) var signInState: SignInState = .idle
    @Published private(set) var signInBrowser: BrowserSource = .none
    private var signInTask: Task<Void, Never>?

    private static let startedKey = "setupStarted"
    private static let completedKey = "setupCompleted"
    private var previewTimer: Timer?

    enum LaunchDecision: Equatable { case show, showToolsOnly, markCompleted, nothing }

    /// What launch does about setup. A finished setup is not shown again, unless the tools it
    /// installed are gone (then just the tools step comes back). One that was shown but not finished
    /// comes back whole. Otherwise it is a fresh install (the tools are not there yet) and it is shown;
    /// an existing install that already has its tools is not a first run, so it is marked done without
    /// a screen (the app menu still has it).
    nonisolated static func launchDecision(started: Bool, completed: Bool, toolsInstalled: Bool) -> LaunchDecision {
        if completed { return toolsInstalled ? .nothing : .showToolsOnly }
        if started { return .show }
        return toolsInstalled ? .markCompleted : .show
    }

    /// Called at launch, and again if the tools turn out to be missing once the first check settles.
    func presentIfNeeded(toolsInstalled: Bool) {
        guard !isPresented else { return }
        let defaults = UserDefaults.standard
        switch Self.launchDecision(started: defaults.bool(forKey: Self.startedKey),
                                   completed: defaults.bool(forKey: Self.completedKey),
                                   toolsInstalled: toolsInstalled) {
        case .nothing: break
        case .markCompleted: defaults.set(true, forKey: Self.completedKey)
        case .show: present()
        case .showToolsOnly: present(toolsOnly: true)
        }
    }

    func present(toolsOnly: Bool = false) {
        stopPreview()
        isPreview = false
        self.toolsOnly = toolsOnly
        step = .tools
        resetSignIn()
        refreshDiskAccess()
        UserDefaults.standard.set(true, forKey: Self.startedKey)
        withAnimation(.spring(response: 0.4)) { isPresented = true }
    }

    #if DEV_BUILD
    /// The Dev tab's "run it for real": makes this Mac look like it has never run Drop, then shows the
    /// real screen. Setup is forgotten, the tools are deleted and downloaded again, Full Disk Access is
    /// revoked for this app (macOS's own `tccutil`, so Settings shows it switched off), and the YouTube
    /// sign-in is cleared. Every step then reports its true state.
    func startFresh(config: Config, manager: DownloadManager) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.startedKey)
        defaults.removeObject(forKey: Self.completedKey)
        config.browser = .none
        revokeFullDiskAccess(logTo: manager)
        manager.resetToolsForFreshInstall()
        present()
    }

    private func revokeFullDiskAccess(logTo manager: DownloadManager) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "SystemPolicyAllFiles", bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Not waited on (this runs on the main thread): the step re-checks once the reset has landed.
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            Task { @MainActor in
                manager.appendLog("Dev: Full Disk Access reset for \(bundleID) (tccutil exit \(status))")
                SetupFlow.shared.refreshDiskAccess()
            }
        }
        do { try process.run() } catch { manager.appendLog("Dev: could not run tccutil: \(error.localizedDescription)") }
    }
    #endif

    /// The Dev tab's preview button: the real screen, with the tools step on simulated progress.
    func preview() {
        stopPreview()
        isPreview = true
        toolsOnly = false
        step = .tools
        resetSignIn()
        previewProgress = 0
        refreshDiskAccess()
        withAnimation(.spring(response: 0.4)) { isPresented = true }
        // Bounded: stops itself once the simulated downloads reach 100%.
        previewTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.previewProgress = min(1, self.previewProgress + 0.011)
                if self.previewProgress >= 1 { self.stopPreview() }
            }
        }
    }

    func advance() {
        if toolsOnly { return finish() }
        guard let next = Step(rawValue: step.rawValue + 1) else { return finish() }
        withAnimation(.easeInOut(duration: 0.25)) { step = next }
        if next == .diskAccess { refreshDiskAccess() }
    }

    func finish() {
        stopPreview()
        if !isPreview { UserDefaults.standard.set(true, forKey: Self.completedKey) }
        withAnimation(.spring(response: 0.4)) { isPresented = false }
    }

    func refreshDiskAccess() { diskAccessGranted = FullDiskAccess.isGranted }

    // MARK: YouTube sign-in

    private func resetSignIn() {
        signInTask?.cancel()
        signInTask = nil
        signInBrowser = .none
        signInState = .idle
    }

    /// The sign-in step came up. A browser already saved from before (setup run again) is checked right
    /// away, so the step shows where things really stand.
    func signInStepAppeared(config: Config, ytdlpPath: String?) {
        guard signInState == .idle, signInBrowser == .none, config.browser != .none else { return }
        signInBrowser = config.browser
        checkSignIn(config: config, ytdlpPath: ytdlpPath)
    }

    /// "Open Browser": opens YouTube's sign-in page in the browser Drop will read the login from (the
    /// Mac's default one when Drop can read it, otherwise Safari), then looks for the login. It always
    /// opens, so there is always something to see; a login that is already there shows as done.
    func openBrowser(config: Config, ytdlpPath: String?) {
        let browser = BrowserSource.forSignIn()
        signInBrowser = browser
        if !isPreview { browser.openYouTubeSignIn() }
        checkSignIn(config: config, ytdlpPath: ytdlpPath)
    }

    /// "Check Again", and coming back to Drop from the browser.
    func recheckSignIn(config: Config, ytdlpPath: String?) {
        guard signInBrowser != .none, signInState != .checking, signInState != .signedIn else { return }
        checkSignIn(config: config, ytdlpPath: ytdlpPath)
    }

    private func checkSignIn(config: Config, ytdlpPath: String?) {
        signInTask?.cancel()
        let previous = signInState
        signInState = .checking
        let browser = signInBrowser
        // The preview shows the sequence without touching a real browser: not signed in on the first
        // look, signed in on the next.
        if isPreview {
            signInTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard !Task.isCancelled, let self, self.signInBrowser == browser else { return }
                self.signInState = previous == .notSignedIn ? .signedIn : .notSignedIn
            }
            return
        }
        signInTask = Task { [weak self] in
            let result = await YouTubeSignIn.check(browser: browser, ytdlpPath: ytdlpPath)
            guard !Task.isCancelled, let self, self.signInBrowser == browser else { return }
            switch result {
            case .signedIn:
                self.signInState = .signedIn
                config.browser = browser
            case .notSignedIn:
                self.signInState = .notSignedIn
            case .blocked:
                self.signInState = .blocked
            case .failed(let reason):
                self.signInState = .failed(reason)
            }
        }
    }

    /// Leaving the step without a working sign-in leaves no cookie source behind.
    func leaveSignInStep(config: Config) {
        signInTask?.cancel()
        if signInState != .signedIn && !isPreview { config.browser = .none }
    }

    private func stopPreview() {
        previewTimer?.invalidate()
        previewTimer = nil
    }
}

// MARK: - View

struct SetupOverlayView: View {
    @ObservedObject var flow: SetupFlow
    @ObservedObject var manager: DownloadManager
    @ObservedObject var config: Config

    var body: some View {
        ZStack {
            if flow.isPresented {
                // The dim is a flat wash, so a plain opacity fade is right for it; the card itself
                // uses the pop transition (never opacity on a glass card).
                Color.black.opacity(0.45).ignoresSafeArea().transition(.opacity)
                card.transition(.overlayPop)
            }
        }
    }

    // MARK: Card

    private var card: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            titleBlock
            Group {
                switch flow.step {
                case .tools:      toolsBody
                case .diskAccess: diskAccessBody
                case .signIn:     signInBody
                case .done:       doneBody
                }
            }
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
            footer
        }
        .padding(26)
        .frame(width: 520)
        .glassCard(cornerRadius: DesignTokens.Radius.large)
    }

    private var header: some View {
        HStack(spacing: 6) {
            if !flow.toolsOnly {
                ForEach(SetupFlow.Step.allCases, id: \.rawValue) { step in
                    Capsule()
                        .fill(step.rawValue <= flow.step.rawValue ? DesignTokens.Accent.primary : Color.white.opacity(0.14))
                        .frame(width: step == flow.step ? 22 : 12, height: 4)
                }
            }
            if flow.isPreview {
                Text("PREVIEW")
                    .font(.appMono(size: 8.5, weight: .bold))
                    .foregroundColor(DesignTokens.Accent.warning)
                    .padding(.leading, flow.toolsOnly ? 0 : 8)
            }
            Spacer()
            // Setup itself cannot be skipped. Only the preview can be closed early, since it is not
            // the real thing; the optional steps have their own "Skip for Now".
            if flow.isPreview && flow.step != .done {
                Button("Close Preview") { flow.finish() }
                    .buttonStyle(.plain)
                    .font(.appMono(size: 10.5, weight: .medium))
                    .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
            }
        }
    }

    private var titleBlock: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.appMono(size: 18, weight: .semibold))
                .foregroundColor(flow.step == .done ? DesignTokens.Accent.success : DesignTokens.Accent.primaryLight)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.white.opacity(0.06)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.appMono(size: 16, weight: .semibold))
                    .foregroundColor(.white.opacity(DesignTokens.Text.primary))
                Text(subtitle)
                    .font(.appMono(size: 11.5))
                    .foregroundColor(.white.opacity(DesignTokens.Text.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var icon: String {
        switch flow.step {
        case .tools:      return "arrow.down.circle"
        case .diskAccess: return "lock.shield"
        case .signIn:     return "person.crop.circle"
        case .done:       return "checkmark.circle.fill"
        }
    }

    private var title: String {
        switch flow.step {
        case .tools:      return "Get Drop ready"
        case .diskAccess: return "Full Disk Access"
        case .signIn:     return "Sign in to YouTube"
        case .done:       return "You're all set"
        }
    }

    private var subtitle: String {
        switch flow.step {
        case .tools:      return flow.toolsOnly
                            ? "Some of Drop's tools are missing. It downloads them again."
                            : "Drop downloads the tools it works with. This happens once."
        case .diskAccess: return "Optional. It lets Drop read Safari's YouTube sign-in. Skip it if you don't use Safari."
        case .signIn:     return "Optional. Age-restricted videos only play for a signed-in account."
        case .done:       return "Here's what's ready. Everything here can be changed later."
        }
    }

    // MARK: Step 1: tools

    private enum ToolStatus { case done, downloading(Double), failed }

    private func status(installed: Bool, updating: Bool, fraction: Double, previewIndex: Int) -> ToolStatus {
        if flow.isPreview {
            let simulated = min(1, max(0, flow.previewProgress * 1.3 - Double(previewIndex) * 0.15))
            return simulated >= 1 ? .done : .downloading(simulated)
        }
        if installed { return .done }
        return updating ? .downloading(fraction) : .failed
    }

    private var tools: [(name: String, detail: String, status: ToolStatus)] {
        [("yt-dlp", "Downloads videos",
          status(installed: manager.ytdlpPath != nil, updating: manager.updatingYtdlp, fraction: manager.ytdlpDownloadProgress, previewIndex: 0)),
         ("ffmpeg", "Converts and merges",
          status(installed: manager.ffmpegPath != nil, updating: manager.updatingFFmpeg, fraction: manager.ffmpegDownloadProgress, previewIndex: 1)),
         ("deno", "Opens more YouTube videos",
          status(installed: manager.denoPath != nil, updating: manager.updatingDeno, fraction: manager.denoDownloadProgress, previewIndex: 2))]
    }

    /// yt-dlp and ffmpeg are what Drop cannot work without; deno only adds YouTube coverage, so it may
    /// still be arriving when the user moves on.
    private var essentialsReady: Bool {
        guard case .done = tools[0].status, case .done = tools[1].status else { return false }
        return true
    }

    private var anyToolFailed: Bool {
        tools.contains { if case .failed = $0.status { return true } else { return false } }
    }

    private var toolsBody: some View {
        VStack(spacing: 12) {
            ForEach(tools, id: \.name) { tool in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.name)
                            .font(.appMono(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(DesignTokens.Text.primary))
                        Text(tool.detail)
                            .font(.appMono(size: 10))
                            .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                    }
                    .frame(width: 170, alignment: .leading)
                    switch tool.status {
                    case .done:
                        progressBar(1)
                        statusLabel("Ready", color: DesignTokens.Accent.success)
                    case .downloading(let fraction):
                        progressBar(fraction)
                        statusLabel(fraction > 0 ? "\(Int((fraction * 100).rounded()))%" : "Waiting",
                                    color: .white.opacity(DesignTokens.Text.secondary))
                    case .failed:
                        progressBar(0)
                        statusLabel("Failed", color: DesignTokens.Accent.danger)
                    }
                }
            }
            if anyToolFailed {
                Text("Check your internet connection, then try again.")
                    .font(.appMono(size: 10.5))
                    .foregroundColor(DesignTokens.Accent.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func progressBar(_ fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                Capsule()
                    .fill(fraction >= 1 ? DesignTokens.Accent.success : DesignTokens.Accent.primary)
                    .frame(width: geo.size.width * CGFloat(min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 5)
    }

    private func statusLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.appMono(size: 10, weight: .semibold))
            .foregroundColor(color)
            .frame(width: 48, alignment: .trailing)
    }

    // MARK: Step 2: Full Disk Access

    private var diskAccessBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: flow.diskAccessGranted ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundColor(flow.diskAccessGranted ? DesignTokens.Accent.success : .white.opacity(DesignTokens.Text.tertiary))
                    .accessibilityHidden(true)
                Text(flow.diskAccessGranted ? "Allowed" : "Not allowed yet")
                    .font(.appMono(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(DesignTokens.Text.primary))
            }
            if !flow.diskAccessGranted {
                GlassButton(label: "Open Full Disk Access", icon: "lock.open", tint: DesignTokens.Accent.primary, fitContent: true) {
                    NSWorkspace.shared.open(BrowserSource.fullDiskAccessSettingsURL)
                }
                Text("Switch on Drop in the list, then come back here. If it stays off after you switch it on, reopen Drop.")
                    .font(.appMono(size: 10.5))
                    .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Checked again when you come back from Settings, and once a second while this step is up.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in flow.refreshDiskAccess() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in flow.refreshDiskAccess() }
    }

    // MARK: Step 3: sign-in

    private var ytdlpPath: String? { manager.ytdlpPath }

    private var signInBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            signInStatus
            signInActions
        }
        .onAppear { flow.signInStepAppeared(config: config, ytdlpPath: ytdlpPath) }
        // Back from the browser: look again.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            flow.refreshDiskAccess()
            flow.recheckSignIn(config: config, ytdlpPath: ytdlpPath)
        }
    }

    private var signInStatus: some View {
        let name = (flow.signInBrowser == .none ? BrowserSource.forSignIn() : flow.signInBrowser).label
        let line: (icon: String, text: String, color: Color)
        switch flow.signInState {
        case .idle:
            line = ("", "Opens YouTube's sign-in page in \(name). Sign in there and Drop picks the login up from \(name). Drop never sees your password. macOS may ask to allow it.",
                    .white.opacity(DesignTokens.Text.tertiary))
        case .checking:
            line = ("", "Looking for your YouTube sign-in in \(name)…", .white.opacity(DesignTokens.Text.secondary))
        case .signedIn:
            line = ("checkmark.circle.fill", "Signed in to YouTube in \(name).", DesignTokens.Accent.success)
        case .notSignedIn:
            line = ("circle.dashed", "Not signed in yet. Sign in to YouTube in \(name), then come back here.", DesignTokens.Accent.warning)
        case .blocked:
            line = ("exclamationmark.triangle.fill", flow.signInBrowser == .safari
                    ? "macOS is blocking Safari's login. Allow Drop in Full Disk Access, reopen Drop, then check again."
                    : "macOS didn't let Drop read \(name)'s login. Allow it when asked, then check again.",
                    DesignTokens.Accent.warning)
        case .failed(let reason):
            line = ("exclamationmark.triangle.fill", "Couldn't read \(name)'s login\(reason.isEmpty ? "." : ": \(reason)")", DesignTokens.Accent.warning)
        }
        return HStack(alignment: .top, spacing: 8) {
            if flow.signInState == .checking {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
            } else if !line.icon.isEmpty {
                Image(systemName: line.icon).font(.appMono(size: 11, weight: .semibold)).foregroundColor(line.color)
                    .accessibilityHidden(true)
            }
            Text(line.text)
                .font(.appMono(size: 10.5))
                .foregroundColor(flow.signInState == .signedIn ? .white.opacity(DesignTokens.Text.primary) : line.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var signInActions: some View {
        let checking = flow.signInState == .checking
        return HStack(spacing: 8) {
            GlassButton(label: "Open Browser", icon: "safari", tint: DesignTokens.Accent.primary, fitContent: true, disabled: checking) {
                flow.openBrowser(config: config, ytdlpPath: ytdlpPath)
            }
            if flow.signInState == .blocked && flow.signInBrowser == .safari {
                GlassButton(label: "Open Full Disk Access", icon: "lock.open", tint: .white, fitContent: true) {
                    NSWorkspace.shared.open(BrowserSource.fullDiskAccessSettingsURL)
                }
            }
            if flow.signInBrowser != .none && flow.signInState != .signedIn && !checking {
                GlassButton(label: "Check Again", icon: "arrow.clockwise", tint: .white, fitContent: true) {
                    flow.recheckSignIn(config: config, ytdlpPath: ytdlpPath)
                }
            }
        }
    }

    // MARK: Step 4: done

    private var doneBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            summaryRow("Tools", value: essentialsReady ? "Ready" : "Still downloading", good: essentialsReady)
            summaryRow("Full Disk Access", value: flow.diskAccessGranted ? "Allowed" : "Not allowed", good: flow.diskAccessGranted)
            summaryRow("YouTube sign-in", value: flow.signInState == .signedIn ? flow.signInBrowser.label : "Not set up", good: flow.signInState == .signedIn)
        }
    }

    private func summaryRow(_ name: String, value: String, good: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: good ? "checkmark.circle.fill" : "minus.circle")
                .foregroundColor(good ? DesignTokens.Accent.success : .white.opacity(DesignTokens.Text.tertiary))
                .accessibilityHidden(true)
            Text(name)
                .font(.appMono(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(DesignTokens.Text.primary))
            Spacer()
            Text(value)
                .font(.appMono(size: 11.5))
                .foregroundColor(.white.opacity(DesignTokens.Text.secondary))
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Spacer()
            switch flow.step {
            case .tools:
                if anyToolFailed && !flow.isPreview {
                    GlassButton(label: "Try Again", icon: "arrow.clockwise", tint: DesignTokens.Accent.primary, fitContent: true) {
                        manager.ensureLatestTools()
                    }
                }
                GlassButton(label: essentialsReady ? "Continue" : "Setting up…", icon: "arrow.right",
                            tint: DesignTokens.Accent.primary, fitContent: true, disabled: !essentialsReady) {
                    flow.advance()
                }
            case .diskAccess:
                GlassButton(label: flow.diskAccessGranted ? "Continue" : "Skip for Now", icon: "arrow.right",
                            tint: flow.diskAccessGranted ? DesignTokens.Accent.primary : .white, fitContent: true) {
                    flow.advance()
                }
            case .signIn:
                let signedIn = flow.signInState == .signedIn
                GlassButton(label: signedIn ? "Continue" : "Skip for Now", icon: "arrow.right",
                            tint: signedIn ? DesignTokens.Accent.primary : .white, fitContent: true) {
                    flow.leaveSignInStep(config: config)
                    flow.advance()
                }
            case .done:
                GlassButton(label: flow.isPreview ? "Close Preview" : "Start Using Drop", icon: "checkmark",
                            tint: DesignTokens.Accent.success, fitContent: true) {
                    flow.finish()
                }
            }
        }
    }
}
