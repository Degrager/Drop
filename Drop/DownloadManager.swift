import SwiftUI
import AppKit
import UserNotifications
import UniformTypeIdentifiers
import QuickLookThumbnailing
import CryptoKit
import Sparkle

// MARK: - Download Manager

/// A string that two threads share: the thread reading yt-dlp's output appends to it, and the
/// code that runs once the process has exited reads it.
final class SyncText: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ s: String) { lock.lock(); text += s; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return text }
}

class DownloadManager: ObservableObject {
    // Downloads run strictly one at a time. Previously 3 ran concurrently,
    // which meant multiple yt-dlp processes competing for the same network/
    // CPU and no clear indication of what was actually in progress vs still
    // waiting -- sequential downloading with an explicit "waiting to
    // download" state (see .pending rendering) is clearer and avoids that
    // contention. Single source of truth for both add() and
    // startNextPending() so they can never drift out of sync with each other.
    static let maxConcurrentDownloads = 1
    /// Every extension Drop can actually produce -- shared by scanForFile's
    /// on-disk lookup and uniqueBaseName's collision check so the two can
    /// never drift out of sync (a new output format previously had to be
    /// added to both lists by hand).
    static let mediaExtensions: Set<String> = ["mp3", "m4a", "wav", "flac", "mp4", "mkv", "webm", "mov", "ogg"]
    let history = HistoryStore()
    @Published var downloads: [Download] = []
    @Published var globalLogs: [String] = []
    @Published var toolsReady: Bool = false
    @Published var checkingDeps    = true
    @Published var checkingUpdates: Bool = false
    @Published var updatingYtdlp: Bool = false
    @Published var updatingFFmpeg: Bool = false
    /// Real download fractionCompleted (0...1), fed from the download
    /// task's own `.progress` via KVO below -- lets the first-launch setup
    /// card show actual progress instead of a generic spinner.
    @Published var ytdlpDownloadProgress: Double = 0
    @Published var ffmpegDownloadProgress: Double = 0
    private var ytdlpProgressObservation: NSKeyValueObservation?
    private var ffmpegProgressObservation: NSKeyValueObservation?
    @Published var updateAvailable: Bool = false
    @Published var ffmpegUpdateAvailable: Bool = false
    @Published var ytdlpVersion: String = UserDefaults.standard.string(forKey: "cachedYtdlpVersion") ?? ""
    @Published var ffmpegVersion: String = UserDefaults.standard.string(forKey: "cachedFfmpegVersion") ?? ""
    // Drop's own self-update, via Sparkle -- EdDSA-signed appcast at
    // SUFeedURL in Info.plist, verified against SUPublicEDKey before
    // anything is installed. See DropUpdater below.
    let dropUpdater = DropUpdater()
    // Set once ensureLatestTools's check cycle finishes, cleared the
    // moment a new one starts -- drives the shared Check for Updates
    // button's "Up to Date" state alongside dropUpdater's own equivalent
    // flag for the Sparkle-based check.
    @Published var justCheckedUpToDate = false
    private let gatekeeperAlertKey = "gatekeeperAlertShown"

    /// Writable location for self-updated binaries. The app bundle itself is
    /// read-only once code-signed, so "updating" yt-dlp/ffmpeg means
    /// downloading a fresh binary here and preferring it over the bundled
    /// copy -- never touching Bundle.main.
    private var supportDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Drop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Directory containing the app's own executable -- Contents/MacOS/.
    /// The Xcode "Embed Binaries" copy phase (dstSubfolderSpec = 6) places
    /// yt-dlp/ffmpeg here, NOT in Contents/Resources/, so Bundle.main's
    /// path(forResource:) (which only searches Resources) can never find
    /// them -- that was the bug making toolsReady come back false. Resolve
    /// via Bundle.main.executableURL's parent directory instead.
    private var bundledBinariesDir: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent()
    }

    /// yt-dlp resolution order: user-updated "onedir" build in Application
    /// Support, then the copy bundled inside the app at build time. No
    /// Homebrew, no PATH search -- Drop ships everything it needs.
    ///
    /// IMPORTANT: the updated copy is the PyInstaller "onedir" build
    /// (yt-dlp_macos.zip), not the old single-file "onefile" binary. The
    /// onefile binary re-unpacks its entire bundled Python runtime + all
    /// 1744 extractors into a temp dir on EVERY invocation, which measured
    /// at a fixed ~8.5s tax per call on this machine regardless of caching,
    /// URL, or flags -- confirmed via `time yt-dlp --version` alone taking
    /// 8.5-8.7s repeatedly. This is a widely-reported yt-dlp/PyInstaller
    /// issue (see yt-dlp/yt-dlp#10826, #14239, #10425), not something
    /// fixable via flags. The onedir build extracts once and its binary
    /// then launches in ~0.24s on repeat calls (measured, 35x faster) --
    /// so it lives in its own folder (yt-dlp_bin/) alongside the required
    /// _internal/ support directory the executable depends on at runtime.
    var ytdlpPath: String? {
        let updatedOnedir = supportDir.appendingPathComponent("yt-dlp_bin/yt-dlp_macos").path
        if FileManager.default.fileExists(atPath: updatedOnedir) { return updatedOnedir }
        // Back-compat: an old onefile copy from before this change may still
        // be sitting in Application Support on upgrade -- prefer the onedir
        // build above when present, but don't strand users mid-download.
        let updatedOnefile = supportDir.appendingPathComponent("yt-dlp").path
        if FileManager.default.fileExists(atPath: updatedOnefile) { return updatedOnefile }
        if let bundled = bundledBinariesDir?.appendingPathComponent("yt-dlp").path,
           FileManager.default.fileExists(atPath: bundled) { return bundled }
        return nil
    }

    var ffmpegPath: String? {
        let updated = supportDir.appendingPathComponent("ffmpeg").path
        if FileManager.default.fileExists(atPath: updated) { return updated }
        if let bundled = bundledBinariesDir?.appendingPathComponent("ffmpeg").path,
           FileManager.default.fileExists(atPath: bundled) { return bundled }
        return nil
    }

    // MARK: - Analyze info-json cache
    //
    // Analyze already pays yt-dlp's full extraction cost (webpage fetch +
    // player API + m3u8 resolution -- measured at ~9-10s on YouTube).
    // Pressing Download right after used to pay that exact same cost again
    // from scratch, since the download-time yt-dlp invocation only ever
    // received the bare URL. yt-dlp's own --load-info-json flag lets a
    // download start directly from a previously-extracted info dict instead
    // of re-resolving the URL: --write-info-json at analyze time persists
    // that dict to disk (cheap -- it's serializing data yt-dlp already has
    // in memory for the --print calls, not a second network round trip),
    // and --load-info-json at download time feeds it back in. yt-dlp
    // internally falls back to a full re-extraction automatically
    // (ReExtractInfo) if a cached format URL has since expired, so a stale
    // or missing cache is never a hard failure -- just a lost speedup.
    private var analyzeCacheDir: URL {
        let dir = supportDir.appendingPathComponent("analyze-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // Cache is only trusted for this long -- belt-and-suspenders on top of
    // yt-dlp's own expired-URL fallback, so a week-old cache file left over
    // from a previous run never even gets attempted.
    private static let analyzeCacheTTL: TimeInterval = 30 * 60  // 30 minutes

    /// Deterministic cache basename for a given source URL -- same URL
    /// always maps to the same path, so re-analyzing overwrites cleanly.
    /// Uses SHA256 rather than Swift's built-in Hasher, which is seeded
    /// randomly per process launch and would silently miss its own cache
    /// after every relaunch. Returns the EXTENSION-LESS base path: yt-dlp's
    /// --write-info-json always appends ".info.json" itself to whatever
    /// -o template it's given (confirmed against yt-dlp's own dir_type
    /// filename logic, which forces the "infojson" output type's extension
    /// to info.json regardless of the template passed in) -- passing an
    /// already-suffixed ".info.json" template here would produce a
    /// double-suffixed "<hash>.info.json.info.json" file on disk instead.
    private func analyzeCacheBasePath(for url: String) -> URL {
        let digest = SHA256.hash(data: Data(url.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return analyzeCacheDir.appendingPathComponent(hash)
    }

    private func analyzeCacheInfoJSONPath(for url: String) -> URL {
        // String-concatenated rather than appendingPathExtension("info.json") --
        // appendingPathExtension treats its argument as a single extension and
        // its behavior with an embedded dot is not something to rely on
        // un-verified; simple concatenation is unambiguous and matches
        // exactly what yt-dlp itself appends ("<template>.info.json").
        URL(fileURLWithPath: analyzeCacheBasePath(for: url).path + ".info.json")
    }

    /// The -o template to pass to yt-dlp's --write-info-json at analyze
    /// time. yt-dlp appends ".info.json" itself -- see note above.
    func cachedInfoJSONWritePath(for url: String) -> String {
        analyzeCacheBasePath(for: url).path
    }

    /// Returns the cached info-json path for this URL if it exists and is
    /// still within the trust window, else nil. Callers should treat nil as
    /// "no cache, use the normal URL-based path" -- never a hard error.
    func cachedInfoJSONPath(for url: String) -> String? {
        let path = analyzeCacheInfoJSONPath(for: url)
        let fm = FileManager.default
        guard fm.fileExists(atPath: path.path),
              let attrs = try? fm.attributesOfItem(atPath: path.path),
              let modified = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < Self.analyzeCacheTTL
        else { return nil }
        return path.path
    }

    /// Deletes this URL's cached analyze info-json, if any -- used when a download's
    /// retry-on-403 path needs the NEXT startDownload call to skip --load-info-json
    /// entirely and resolve a genuinely fresh stream URL, rather than silently
    /// reusing the exact cached data whose URL just got rejected.
    func invalidateAnalyzeCache(for url: String) {
        try? FileManager.default.removeItem(at: analyzeCacheInfoJSONPath(for: url))
    }

    /// Best-effort prune of stale cache files -- called once on launch so
    /// the directory doesn't grow unbounded across many sessions. Not
    /// load-bearing for correctness (the TTL check above already refuses to
    /// use stale files); this just reclaims disk space.
    func pruneAnalyzeCache() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: analyzeCacheDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)  // prune anything older than a day
        for file in files {
            if let attrs = try? fm.attributesOfItem(atPath: file.path),
               let modified = attrs[.modificationDate] as? Date,
               modified < cutoff {
                try? fm.removeItem(at: file)
            }
        }
    }

    /// Returns a unique file path in outputDir — appends (2), (3), … if needed.
    init() {
        // The only indication of what's actually running was yt-dlp/ffmpeg's own paths/update
        // status (reported live: "no indication of the Drop version in the log like there is for
        // yt-dlp and ffmpeg") -- useful on its own (a source build reads as "dev", distinguishing
        // it at a glance from a real stamped release -- see isReleaseVersion's own doc comment),
        // and essential context for reading the rest of a log someone else sends in.
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        appendLog("Drop \(currentAppVersion) (build \(build))")
        checkDeps()
        requestNotificationPermission()
        // Both tools track nightly builds, so every launch makes sure the
        // latest nightly is installed (a cheap redirect check first, a full
        // download only when a newer build exists) before the tools are
        // considered ready to use.
        ensureLatestTools()
        showGatekeeperAlertIfNeeded()
        // Reclaim disk space from any analyze-cache info-json files left
        // over from previous sessions -- the 30-minute TTL already stops
        // them from being used once stale, this just deletes them.
        pruneAnalyzeCache()
    }

    /// Runs at every launch: installs the latest nightly yt-dlp and ffmpeg
    /// builds, skipping each download when the build already on disk is the
    /// current one (see resolveVersionedAssetURL). Runs both in parallel,
    /// then re-runs checkDeps() (see its own comment for why that's
    /// necessary, not just silentUpdateCheck()) once both finish.
    func ensureLatestTools() {
        // Set here, not left to silentUpdateCheck's own line below: that one
        // only runs after updateYtdlp/updateFFmpeg have ALREADY finished
        // their own network round-trip (inside group.notify), so the button
        // sat on "Check for Updates" doing nothing for that whole stretch
        // and only flipped to "Checking…" right at the tail end -- reported
        // live as the button not switching to Checking instantly on click.
        checkingUpdates = true
        justCheckedUpToDate = false
        appendLog("Updating yt-dlp and ffmpeg to latest nightly builds…")
        let group = DispatchGroup()
        group.enter(); updateYtdlp(onlyIfNewer: true) { group.leave() }
        group.enter(); updateFFmpeg(onlyIfNewer: true) { group.leave() }
        group.notify(queue: .main) {
            // Re-evaluate readiness now that both downloads have actually
            // landed on disk. On a genuinely first launch (nothing in
            // Application Support yet, and nothing is ever truly bundled
            // into the app itself despite the comment below -- see
            // bundledBinariesDir), the ONE checkDeps() call in init() runs
            // long before these downloads finish, so without this second
            // call toolsReady stayed permanently false for the rest of
            // that session even after the tools successfully arrived --
            // the UI stayed locked on "Setup Needed" until the user quit
            // and relaunched. This makes the app un-stick itself instead.
            self.checkDeps()
            self.silentUpdateCheck { self.justCheckedUpToDate = true }
        }
    }

    /// Dev-tab only: forces the first-launch "setting up tools" card into view
    /// with simulated (not real) progress, so it can be eyeballed without
    /// wiping Application Support and actually re-downloading both tools.
    /// Auto-resolves back to the real ready state after a few seconds --
    /// mirrors DropCustomUserDriver's own previewX() pattern for the update
    /// overlay (see DevReleaseView's testingCard).
    func previewToolsSetup() {
        checkingDeps = false
        toolsReady = false
        updatingYtdlp = true
        updatingFFmpeg = true
        ytdlpDownloadProgress = 0
        ffmpegDownloadProgress = 0
        var tick = 0
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            tick += 1
            // Different rates so the two bars visibly diverge, like two
            // independent real downloads would.
            self.ytdlpDownloadProgress = min(1, Double(tick) * 0.045)
            self.ffmpegDownloadProgress = min(1, Double(tick) * 0.03)
            if self.ffmpegDownloadProgress >= 1 {
                timer.invalidate()
                self.updatingYtdlp = false
                self.updatingFFmpeg = false
                self.toolsReady = true
            }
        }
    }

    /// No install flow, no polling loop needed since nothing external has
    /// to appear -- this just confirms whether ytdlpPath/ffmpegPath
    /// currently resolve to something on disk (either a fresh download in
    /// Application Support, or -- in principle, though nothing in this
    /// project's build actually populates it -- a copy bundled inside the
    /// app itself) and logs the outcome. Called once immediately at
    /// launch (before the automatic downloads below have had time to
    /// finish -- a "not ready yet" result here is completely normal on a
    /// first launch, not a real error) and again once ensureLatestTools's
    /// downloads actually complete.
    func checkDeps() {
        checkingDeps = true
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            let ytdlp  = self.ytdlpPath  != nil
            let ffmpeg = self.ffmpegPath != nil
            DispatchQueue.main.async {
                // Reported live: "Tools ready" logged twice back to back on an ordinary launch.
                // This runs once immediately at launch and again once ensureLatestTools's
                // downloads finish (see that function's own comment for why the second call
                // exists) -- on a first launch those two calls genuinely differ (not ready, then
                // ready), but on every later launch the tools are already on disk for BOTH calls,
                // so the second one was re-announcing exactly what the first already said. Only
                // the not-ready -> ready transition is worth logging a second time.
                let wasAlreadyReady = self.toolsReady
                self.toolsReady    = ytdlp && ffmpeg
                self.checkingDeps  = false
                if !self.toolsReady {
                    self.appendLog("Tools not ready yet (yt-dlp=\(ytdlp), ffmpeg=\(ffmpeg)) — waiting on the automatic download. If this doesn't clear after the download finishes, check your internet connection.")
                } else if !wasAlreadyReady {
                    self.appendLog("Tools ready — yt-dlp: \(self.ytdlpPath ?? "?"), ffmpeg: \(self.ffmpegPath ?? "?")")
                }
            }
        }
    }

    func performFix(for download: Download, config: Config, showFolderPicker: @escaping () -> Void) {
        switch download.fixAction {
        case .setCookieNone:
            // Mutate config to remove cookies then retry
            appendLog("Auto-fix: setting Cookie Source to None and retrying...")
            config.browser = .none
            retry(download: download, config: config)


        case .openFolderPicker:
            showFolderPicker()

        case .openPrivacySecurity:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)

        case .openURL(let urlString):
            if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }

        case .none:
            break
        }
    }

    func showGatekeeperAlertIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: gatekeeperAlertKey) else { return }
        UserDefaults.standard.set(true, forKey: gatekeeperAlertKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.showAlert(
                title: "First Launch Note",
                message: "Drop is not notarized by Apple, so macOS may have warned you before opening it. If you see \"cannot be opened\" errors, go to System Settings → Privacy & Security and click \"Open Anyway\". All downloads happen locally on your Mac."
            )
        }
    }

    func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func sendNotification(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    func playCompletionSound() {
        NSSound(named: "Glass")?.play()
    }

    /// Reads the currently-active yt-dlp/ffmpeg version (bundled or
    /// user-updated, whichever ytdlpPath/ffmpegPath resolve to) purely for
    /// display in the Tools dropdown. Both tools are brought to their latest
    /// nightly build on every launch (see ensureLatestTools), so there's no
    /// separate "is an update available" check anymore -- by the time this
    /// runs, whatever's on disk already IS the latest nightly.
    /// updateAvailable/ffmpegUpdateAvailable stay false.
    func silentUpdateCheck(completion: (() -> Void)? = nil) {
        DispatchQueue.main.async { self.checkingUpdates = true }
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 0.2) {
            func runBin(_ path: String, _ args: [String]) -> String {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
                try? p.run(); p.waitUntilExit()
                return (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let ytVersion: String
            if let path = self.ytdlpPath {
                ytVersion = runBin(path, ["--version"])
            } else { ytVersion = "" }
            let ffRaw: String
            if let path = self.ffmpegPath {
                ffRaw = runBin(path, ["-version"])
            } else { ffRaw = "" }
            let ffVersion = ffRaw.components(separatedBy: "\n").first
                .flatMap { line -> String? in
                    // Stable releases report a plain "ffmpeg version 7.1.1 ...".
                    // The martin-riedl.de nightly build server's own version
                    // string format has changed at least once already --
                    // it used to be "N-125892-g406c5a37aa-https://www.martin-
                    // riedl.de" (a build number + git hash + URL) and is now
                    // "8.0.git-https://www.martin-riedl.de" (a plain-looking
                    // version immediately followed by a URL with no
                    // separator this parser could rely on). Rather than
                    // hardcode to whichever exact shape it happens to use
                    // today, extract just the leading version-looking prefix
                    // and drop everything appended after it -- this keeps
                    // working if the suffix changes shape again, since it
                    // never depends on what that suffix actually contains.
                    let parts = line.components(separatedBy: " ")
                    guard let idx = parts.firstIndex(of: "version"), parts.count > idx + 1 else { return nil }
                    let raw = parts[idx + 1]
                    // Legacy nightly scheme: "N-<build>-<hash>-<url>".
                    if raw.hasPrefix("N-") {
                        let segments = raw.components(separatedBy: "-")
                        if segments.count >= 2 { return "N-\(segments[1])" }
                    }
                    // Everything else: the leading dotted-number run, e.g.
                    // "8.0" out of "8.0.git-https://…", or "7.1.1" out of a
                    // plain stable release string -- whatever's appended
                    // directly after it (a git suffix, a hash, a URL) is
                    // dropped unconditionally rather than pattern-matched.
                    if let match = raw.range(of: #"^\d+(\.\d+)*"#, options: .regularExpression) {
                        return String(raw[match])
                    }
                    return raw
                } ?? ""

            DispatchQueue.main.async {
                self.ytdlpVersion = ytVersion
                self.updateAvailable = false
                self.ffmpegVersion = ffVersion
                self.ffmpegUpdateAvailable = false
                self.checkingUpdates = false
                if !ytVersion.isEmpty { UserDefaults.standard.set(ytVersion, forKey: "cachedYtdlpVersion") }
                if !ffVersion.isEmpty { UserDefaults.standard.set(ffVersion, forKey: "cachedFfmpegVersion") }
                completion?()
            }
        }
    }

    private static let ytdlpAssetKey = "installedYtdlpAssetURL"
    private static let ffmpegAssetKey = "installedFfmpegAssetURL"

    /// Both nightly endpoints are "latest" redirects whose FIRST hop points at
    /// a versioned URL (a tag for yt-dlp, a build number for ffmpeg). A GET
    /// that refuses to follow the redirect reads that URL from a tiny
    /// response, which is enough to tell whether the build already installed
    /// is the current one without re-downloading tens of megabytes every
    /// launch. (GET, not HEAD: ffmpeg.martin-riedl.de answers HEAD with an
    /// intermittent 404, but has never failed a GET.) One retry covers a
    /// transient blip. Calls back with nil if the endpoint still can't be
    /// resolved (offline, etc.), in which case callers just fall through to a
    /// normal download attempt.
    private func resolveVersionedAssetURL(_ latestURL: URL, attemptsLeft: Int = 2, completion: @escaping (URL?) -> Void) {
        final class NoRedirect: NSObject, URLSessionTaskDelegate {
            func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
                completionHandler(nil)
            }
        }
        var request = URLRequest(url: latestURL)
        request.timeoutInterval = 15
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        session.dataTask(with: request) { _, response, _ in
            session.finishTasksAndInvalidate()
            guard let http = response as? HTTPURLResponse, (300..<400).contains(http.statusCode),
                  let location = http.value(forHTTPHeaderField: "Location"),
                  let resolved = URL(string: location, relativeTo: latestURL)?.absoluteURL else {
                if attemptsLeft > 1 {
                    self.resolveVersionedAssetURL(latestURL, attemptsLeft: attemptsLeft - 1, completion: completion)
                } else {
                    completion(nil)
                }
                return
            }
            completion(resolved)
        }.resume()
    }

    /// Downloads the latest yt-dlp NIGHTLY build (yt-dlp-nightly-builds repo,
    /// not the stable yt-dlp repo) into Application Support, replacing
    /// whatever ytdlpPath currently resolves to. The bundled copy inside the
    /// app itself is never touched. `completion` fires on the main queue
    /// once the attempt finishes (success or failure) so launch-time forced
    /// updates can wait for both tools before flipping toolsReady.
    ///
    /// Fetches the "onedir" zip build (yt-dlp_macos.zip), NOT the old
    /// single-file binary -- see the comment on ytdlpPath above for why.
    /// The zip's top level contains the yt-dlp_macos executable plus an
    /// _internal/ folder of runtime dependencies that MUST stay alongside
    /// it; both are extracted into a dedicated yt-dlp_bin/ directory rather
    /// than flattened into supportDir directly, so this can't collide with
    /// or partially overwrite anything else Drop stores there.
    func updateYtdlp(onlyIfNewer: Bool = false, completion: (() -> Void)? = nil) {
        guard !updatingYtdlp else { completion?(); return }
        updatingYtdlp = true
        let latestURL = URL(string: "https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/latest/download/yt-dlp_macos.zip")!
        let installedBinary = supportDir.appendingPathComponent("yt-dlp_bin/yt-dlp_macos")
        resolveVersionedAssetURL(latestURL) { assetURL in
            DispatchQueue.main.async {
                if onlyIfNewer, let assetURL, FileManager.default.fileExists(atPath: installedBinary.path),
                   UserDefaults.standard.string(forKey: Self.ytdlpAssetKey) == assetURL.absoluteString {
                    self.updatingYtdlp = false
                    self.appendLog("✓ yt-dlp is already on the latest nightly.")
                    completion?()
                    return
                }
                self.downloadYtdlp(from: assetURL ?? latestURL, completion: completion)
            }
        }
    }

    private func downloadYtdlp(from releaseURL: URL, completion: (() -> Void)?) {
        appendLog("Fetching latest yt-dlp nightly build…")
        ytdlpDownloadProgress = 0
        let finalDir = supportDir.appendingPathComponent("yt-dlp_bin")
        let tempZip = supportDir.appendingPathComponent("yt-dlp_macos.zip.download")
        let task = URLSession.shared.downloadTask(with: releaseURL) { location, response, error in
            guard let location = location, error == nil else {
                DispatchQueue.main.async {
                    self.updatingYtdlp = false
                    self.appendLog("ERROR: yt-dlp nightly update failed — \(error?.localizedDescription ?? "unknown error")")
                    completion?()
                }
                return
            }
            do {
                try? FileManager.default.removeItem(at: tempZip)
                try FileManager.default.moveItem(at: location, to: tempZip)
                let unzipDir = self.supportDir.appendingPathComponent("yt-dlp_bin_unzip")
                try? FileManager.default.removeItem(at: unzipDir)
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                proc.arguments = ["-o", tempZip.path, "-d", unzipDir.path]
                try proc.run(); proc.waitUntilExit()
                guard proc.terminationStatus == 0 else {
                    throw NSError(domain: "Drop", code: 2, userInfo: [NSLocalizedDescriptionKey: "unzip exited with status \(proc.terminationStatus)"])
                }
                let extractedBinary = unzipDir.appendingPathComponent("yt-dlp_macos")
                guard FileManager.default.fileExists(atPath: extractedBinary.path) else {
                    throw NSError(domain: "Drop", code: 1, userInfo: [NSLocalizedDescriptionKey: "yt-dlp_macos binary not found in downloaded archive"])
                }
                try? FileManager.default.removeItem(at: finalDir)
                try FileManager.default.moveItem(at: unzipDir, to: finalDir)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: finalDir.appendingPathComponent("yt-dlp_macos").path)
                // Downloaded via URLSession, so the whole extracted tree carries
                // com.apple.quarantine -- Gatekeeper's first-launch scan on a
                // freshly-quarantined binary is itself a multi-second one-time
                // cost (measured ~8.5s), separate from and in addition to the
                // onefile-vs-onedir unpack cost this whole change targets.
                // Clearing it here means only THIS update pays that cost once,
                // not every subsequent yt-dlp invocation for the rest of the
                // session.
                let xattrProc = Process()
                xattrProc.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
                xattrProc.arguments = ["-cr", finalDir.path]
                try? xattrProc.run(); xattrProc.waitUntilExit()
                try? FileManager.default.removeItem(at: tempZip)
                DispatchQueue.main.async {
                    self.updatingYtdlp = false
                    UserDefaults.standard.set(releaseURL.absoluteString, forKey: Self.ytdlpAssetKey)
                    self.appendLog("✓ yt-dlp updated to latest nightly.")
                    completion?()
                }
            } catch {
                DispatchQueue.main.async {
                    self.updatingYtdlp = false
                    self.appendLog("ERROR: yt-dlp nightly update failed — \(error.localizedDescription)")
                    completion?()
                }
            }
        }
        ytdlpProgressObservation = task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            DispatchQueue.main.async { self?.ytdlpDownloadProgress = progress.fractionCompleted }
        }
        task.resume()
    }

    /// Current running version, read straight from the bundle -- this is
    /// what CFBundleShortVersionString/MARKETING_VERSION resolves to at
    /// build time, so it always reflects the actual installed build.
    var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// A real release number ("1.2", "1.2.1") as opposed to the "dev" every build
    /// from source carries (the project's default MARKETING_VERSION). Only the
    /// release pipeline stamps a number, so the running build is a dev build
    /// unless this says otherwise. Dev builds also default CURRENT_PROJECT_VERSION
    /// high (999999), so Sparkle never sees a published release as newer than them.
    static func isReleaseVersion(_ version: String) -> Bool {
        version.range(of: #"^\d+(\.\d+)+$"#, options: .regularExpression) != nil
    }

    var isDevBuild: Bool { !Self.isReleaseVersion(currentAppVersion) }

    /// Thin wrapper around Sparkle's standard updater. Sparkle itself owns
    /// checking (per SUEnableAutomaticChecks/SUScheduledCheckInterval in
    /// Info.plist), signature verification (against SUPublicEDKey), and the
    /// update-available/install UI (its own native alert) -- this class only
    /// mirrors "is it checking / did it find something" into @Published
    /// state so the existing Tools-row VersionChip can reflect it, matching
    /// the yt-dlp/ffmpeg rows' look even though Sparkle drives the actual
    /// update flow once the user confirms in its dialog.
    // Custom driver replaces Sparkle's own AppKit alert windows with an
    // in-app overlay matching Drop's design (DropUpdateOverlay.swift).
    // `DropUpdater` itself no longer conforms to SPUUpdaterDelegate: that
    // protocol's callbacks (didFindValidUpdate, updaterDidNotFindUpdate,
    // didAbortWithError) are notified independently of the driver by
    // Sparkle's internals, and were observed NOT firing in reliable lockstep
    // with it -- specifically, checkingForUpdates could get stuck true for
    // seconds after the driver had already moved on, once a user-interaction
    // wait (dismissing the error card) was involved. `userDriver.stage` is
    // the one thing Sparkle actually keeps in sync with what's on screen, so
    // every published flag the UI reads (isActivelyChecking,
    // hasActionableUpdate, justConfirmedUpToDate) now lives directly on it
    // instead of being split across two independently-notified objects.
    final class DropUpdater: NSObject, ObservableObject {
        // DropCustomUserDriver is @MainActor (required -- Sparkle's
        // SPUUserDriver protocol itself is annotated NS_SWIFT_UI_ACTOR), but
        // DropUpdater/DownloadManager aren't statically MainActor-isolated
        // even though they're only ever actually constructed on the main
        // thread in practice (as a SwiftUI @StateObject). assumeIsolated
        // bridges that gap without cascading @MainActor up through
        // DownloadManager, which is used from background threads elsewhere.
        let userDriver = MainActor.assumeIsolated { DropCustomUserDriver() }
        private var updater: SPUUpdater!

        // Started immediately (not lazy/deferred) so Sparkle's own scheduled
        // background checking (per SUScheduledCheckInterval) begins right
        // away, not only once the Tools menu is opened.
        override init() {
            super.init()
            updater = SPUUpdater(hostBundle: Bundle.main, applicationBundle: Bundle.main, userDriver: userDriver, delegate: nil)
            try? updater.start()
            checkWhatsNewIfJustUpdated()
        }

        func checkForUpdates() {
            updater.checkForUpdates()
        }

        /// Sparkle has no "what's new" screen of its own -- it only ever asks
        /// "install this?" *before* an update happens. This detects the
        /// other half: the first launch after a real update landed, so Drop
        /// can show what changed once per version. Tracks the *set* of
        /// versions already shown (not just the single last-seen version)
        /// so a version that bounces -- a manual dev reinstall, a rollback --
        /// can never re-trigger an announcement it already showed once.
        /// Only added to that set once the network fetch actually succeeds
        /// and the overlay is queued to appear, never merely attempted, so a
        /// failed fetch doesn't silently and permanently suppress it either.
        private func checkWhatsNewIfJustUpdated() {
            let shownKey = "whatsNewShownVersions"
            let legacyKey = "lastSeenAppVersion"
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            // A dev build has no published release notes to announce (and no
            // v<current> tag to fetch them from).
            guard DownloadManager.isReleaseVersion(current) else { return }
            var shown = Set(UserDefaults.standard.stringArray(forKey: shownKey) ?? [])

            // One-time migration from the old single-version tracker: a
            // fresh install (no legacy record) or a version already handled
            // under the old scheme both mean "nothing new to show" -- mark
            // current as seen without showing anything. A genuine version
            // change under the old scheme falls through to the normal
            // fetch-and-show path below.
            if shown.isEmpty {
                let legacy = UserDefaults.standard.string(forKey: legacyKey)
                if legacy == nil || legacy == current {
                    shown.insert(current)
                }
                UserDefaults.standard.removeObject(forKey: legacyKey)
                UserDefaults.standard.set(Array(shown), forKey: shownKey)
            }

            guard !shown.contains(current),
                  let url = URL(string: "https://api.github.com/repos/Degrager/Drop/releases/tags/v\(current)") else { return }

            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let notes = json["body"] as? String else { return }
                DispatchQueue.main.async {
                    shown.insert(current)
                    UserDefaults.standard.set(Array(shown), forKey: shownKey)
                    self?.userDriver.showWhatsNew(versionString: current, notesHTML: notes)
                }
            }.resume()
        }
    }


    /// Downloads the latest ffmpeg NIGHTLY ("snapshot") arm64 macOS build
    /// from ffmpeg.martin-riedl.de's stable redirect endpoint into
    /// Application Support. That build tracks ffmpeg master and updates
    /// daily -- unlike the old osxexperts.net static release build, there IS
    /// a real nightly channel here. Zip contains the ffmpeg binary at its
    /// root (no nested folder), same completion-callback shape as
    /// updateYtdlp above.
    func updateFFmpeg(onlyIfNewer: Bool = false, completion: (() -> Void)? = nil) {
        guard !updatingFFmpeg else { completion?(); return }
        updatingFFmpeg = true
        let latestURL = URL(string: "https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/snapshot/ffmpeg.zip")!
        let installedBinary = supportDir.appendingPathComponent("ffmpeg")
        resolveVersionedAssetURL(latestURL) { assetURL in
            DispatchQueue.main.async {
                if onlyIfNewer, let assetURL, FileManager.default.fileExists(atPath: installedBinary.path),
                   UserDefaults.standard.string(forKey: Self.ffmpegAssetKey) == assetURL.absoluteString {
                    self.updatingFFmpeg = false
                    self.appendLog("✓ ffmpeg is already on the latest nightly.")
                    completion?()
                    return
                }
                self.downloadFFmpeg(from: assetURL ?? latestURL, completion: completion)
            }
        }
    }

    private func downloadFFmpeg(from releaseURL: URL, completion: (() -> Void)?) {
        appendLog("Fetching latest ffmpeg nightly build…")
        ffmpegDownloadProgress = 0
        let destURL = supportDir.appendingPathComponent("ffmpeg")
        let tempZip = supportDir.appendingPathComponent("ffmpeg.zip")
        let task = URLSession.shared.downloadTask(with: releaseURL) { location, response, error in
            guard let location = location, error == nil else {
                DispatchQueue.main.async {
                    self.updatingFFmpeg = false
                    self.appendLog("ERROR: ffmpeg nightly update failed — \(error?.localizedDescription ?? "unknown error")")
                    completion?()
                }
                return
            }
            do {
                try? FileManager.default.removeItem(at: tempZip)
                try FileManager.default.moveItem(at: location, to: tempZip)
                let unzipDir = self.supportDir.appendingPathComponent("ffmpeg_unzip")
                try? FileManager.default.removeItem(at: unzipDir)
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                proc.arguments = ["-o", tempZip.path, "-d", unzipDir.path]
                try proc.run(); proc.waitUntilExit()
                // The zip may nest the binary in a subfolder; find it.
                let enumerator = FileManager.default.enumerator(at: unzipDir, includingPropertiesForKeys: nil)
                var foundPath: URL?
                while let item = enumerator?.nextObject() as? URL {
                    if item.lastPathComponent == "ffmpeg" { foundPath = item; break }
                }
                guard let found = foundPath else {
                    throw NSError(domain: "Drop", code: 1, userInfo: [NSLocalizedDescriptionKey: "ffmpeg binary not found in downloaded archive"])
                }
                try? FileManager.default.removeItem(at: destURL)
                try FileManager.default.moveItem(at: found, to: destURL)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destURL.path)
                try? FileManager.default.removeItem(at: tempZip)
                try? FileManager.default.removeItem(at: unzipDir)
                DispatchQueue.main.async {
                    self.updatingFFmpeg = false
                    UserDefaults.standard.set(releaseURL.absoluteString, forKey: Self.ffmpegAssetKey)
                    self.appendLog("✓ ffmpeg updated to latest nightly.")
                    completion?()
                }
            } catch {
                DispatchQueue.main.async {
                    self.updatingFFmpeg = false
                    self.appendLog("ERROR: ffmpeg nightly update failed — \(error.localizedDescription)")
                    completion?()
                }
            }
        }
        ffmpegProgressObservation = task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            DispatchQueue.main.async { self?.ffmpegDownloadProgress = progress.fractionCompleted }
        }
        task.resume()
    }

    @discardableResult
    func add(urls: [String], config: Config, thumbnailURL: String = "", isPlaylist: Bool = false, snapshot: DownloadSnapshot? = nil) -> UUID? {
        var lastID: UUID? = nil
        for url in urls {
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // Skip if the exact same URL+format+mode is already active/queued —
            // prevents duplicate concurrent downloads racing on the same output file.
            let alreadyQueued = downloads.contains { existing in
                existing.url == trimmed &&
                existing.mediaMode == config.mediaMode &&
                existing.format == config.format &&
                existing.videoFormat == config.videoFormat &&
                (existing.status == .pending || existing.status == .downloading)
            }
            if alreadyQueued {
                appendLog("Skipped duplicate: \(trimmed) is already queued in this format.")
                continue
            }
            var dl = Download(url: trimmed, title: trimmed, status: .pending,
                              outputDir: config.outputDir, format: config.format,
                              mediaMode: config.mediaMode, videoFormat: config.videoFormat,
                              videoQuality: config.videoQuality)
            dl.thumbnailURL = thumbnailURL
            dl.browser = config.browser
            dl.reencodeCodec = config.reencodeCodec
            dl.audioQuality = config.quality
            dl.isPlaylist = isPlaylist
            if let snap = snapshot {
                dl.title        = snap.title.isEmpty ? trimmed : snap.title
                dl.thumbnailURL = snap.thumbnailURL.isEmpty ? thumbnailURL : snap.thumbnailURL
                dl.snapshot     = snap
            }
            let newID = dl.id
            downloads.append(dl)  // append so order is top→bottom
            lastID = newID
            // Downloads run one at a time (see maxConcurrent in
            // startNextPending) so yt-dlp isn't fighting itself for network/
            // CPU across multiple simultaneous processes, and so progress
            // for each item is easy to follow top-to-bottom instead of
            // several bars moving at once. Only start immediately if
            // nothing else is currently downloading -- otherwise this new
            // item just sits as .pending and startNextPending picks it up
            // the moment the active one finishes.
            let activeCount = downloads.filter { $0.id != newID && $0.status == .downloading }.count
            if activeCount < DownloadManager.maxConcurrentDownloads, let idx = downloads.firstIndex(where: { $0.id == newID }) {
                startDownload(index: idx, config: config)
            }
        }
        return lastID
    }

    func retry(download: Download, config: Config) {
        if let idx = downloads.firstIndex(where: { $0.id == download.id }) {
            downloads[idx].status = .pending
            downloads[idx].errorMessage = nil
            downloads[idx].fixHint = nil
            downloads[idx].fixAction = .none
            downloads[idx].logs = []
            startDownload(index: idx, config: config)
        }
    }

    func cancel(download: Download) {
        if let idx = downloads.firstIndex(where: { $0.id == download.id }) {
            if let proc = downloads[idx].process {
                Self.terminateProcessTree(proc)
            }
            downloads[idx].status = .cancelled
            appendLog("Cancelled: \(downloads[idx].title)")
            Self.deletePartialFiles(baseName: downloads[idx].resolvedBaseName, in: downloads[idx].outputDir, log: { self.appendLog($0) })
        }
    }

    /// Quitting stops every download in flight, and -- like Cancel -- removes the .part/.ytdl files
    /// they had written. Drop doesn't keep in-progress downloads across launches, so nothing would
    /// ever resume from those files; they would just sit in the output folder.
    func cancelAllForQuit() {
        let running = downloads.filter { $0.status == .downloading }
        guard !running.isEmpty else { return }
        for download in running {
            guard let proc = download.process else { continue }
            Self.terminateProcessTree(proc)
            kill(proc.processIdentifier, SIGKILL)
        }
        // Let the processes finish dying so they can't write another byte after the cleanup.
        usleep(150_000)
        for download in running {
            appendLog("Stopped on quit: \(download.title)")
            Self.deletePartialFiles(baseName: download.resolvedBaseName, in: download.outputDir, log: { self.appendLog($0) })
        }
    }

    /// Cancel kills yt-dlp/ffmpeg but doesn't remove whatever they'd already
    /// written — a .part/.ytdl temp file, or (once past the merge step) a
    /// truncated final file. Both use the same resolved base name, so scan
    /// outputDir for anything starting with it and delete the lot.
    private static func deletePartialFiles(baseName: String?, in outputDir: String, log: (String) -> Void) {
        guard let baseName, !baseName.isEmpty else { return }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: outputDir) else { return }
        for item in items where item.hasPrefix(baseName) {
            let fullPath = "\(outputDir)/\(item)"
            if (try? fm.removeItem(atPath: fullPath)) != nil {
                log("Deleted partial file: \(item)")
            }
        }
    }

    /// Terminating yt-dlp's own PID isn't enough — yt-dlp shells out to ffmpeg for
    /// merging (--merge-output-format) and metadata embedding (--embed-metadata),
    /// and a SIGTERM to the parent Python process doesn't reliably propagate to
    /// those ffmpeg children. Left alone, ffmpeg keeps writing the output file to
    /// completion even after yt-dlp itself has exited, so Cancel looked like it
    /// did nothing. Kill any live ffmpeg child processes by PID first (found via
    /// `pgrep -P`), then terminate yt-dlp itself.
    static func terminateProcessTree(_ proc: Process) {
        let pid = proc.processIdentifier
        if pid > 0 {
            let pgrep = Process()
            pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            pgrep.arguments = ["-P", "\(pid)"]
            let pipe = Pipe()
            pgrep.standardOutput = pipe
            pgrep.standardError = Pipe()
            if (try? pgrep.run()) != nil {
                pgrep.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let out = String(data: data, encoding: .utf8) {
                    for line in out.split(separator: "\n") {
                        if let childPid = Int32(line.trimmingCharacters(in: .whitespaces)) {
                            kill(childPid, SIGKILL)
                        }
                    }
                }
            }
        }
        proc.terminate()
    }

    // Safely mutates a download by its stable id. The array can be resized
    // (Clear All, individual remove, cancel-and-remove) while a background
    // download's async closures are still in flight holding a now-stale
    // integer index — looking up by id and no-oping if the row is gone
    // avoids the out-of-range crash that a raw downloads[idx] access risks.
    private func withDownload(_ id: UUID, _ mutate: (inout Download) -> Void) {
        guard let i = downloads.firstIndex(where: { $0.id == id }) else { return }
        mutate(&downloads[i])
    }

    private func readDownload<T>(_ id: UUID, _ read: (Download) -> T) -> T? {
        guard let i = downloads.firstIndex(where: { $0.id == id }) else { return nil }
        return read(downloads[i])
    }

    /// Actual height (in pixels) of the video stream in a finished download,
    /// read straight off the file with the bundled ffmpeg binary -- NOT the
    /// height the user requested. yt-dlp's format selector can silently
    /// fall back to a lower resolution than requested when the source has
    /// no stream at the requested height (or a merge picks a smaller of
    /// two close candidates), and until now the history/log label always
    /// echoed back the REQUESTED VideoQuality.label regardless of what
    /// actually landed on disk -- e.g. showing "4K" for a file that's
    /// really 1080p. `ffmpeg -i <file>` with no output prints full stream
    /// info to stderr (exit code is nonzero because there's no output
    /// target, which is expected and ignored here) -- parsed for the
    /// first "WxH" resolution pair on a Video: line. No bundled ffprobe
    /// exists in Drop, so this reuses the ffmpeg binary already required
    /// for every conversion instead of shipping a second tool.
    private func actualVideoHeight(atPath path: String, ffmpegPath: String) -> Int? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpegPath)
        p.arguments = ["-hide_banner", "-i", path]
        let errPipe = Pipe()
        p.standardOutput = Pipe()
        p.standardError = errPipe
        do { try p.run() } catch { return nil }
        let data = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: "\n") where line.contains("Video:") {
            // Matches the first bare "WWWxHHH" token, e.g. "1920x1080" —
            // ffmpeg's Video: line always includes this even when SAR/DAR
            // annotations like "[SAR 1:1 DAR 16:9]" follow right after.
            if let range = line.range(of: #"\d{2,5}x\d{2,5}"#, options: .regularExpression) {
                let pair = line[range]
                if let hStr = pair.split(separator: "x").last, let h = Int(hStr) {
                    return h
                }
            }
        }
        return nil
    }

    /// Same probe as actualVideoHeight, reading the codec name instead of the resolution off
    /// ffmpeg's own "Video: <codec> (...)" banner line (e.g. "vp9", "av1", "h264").
    private func actualVideoCodec(atPath path: String, ffmpegPath: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpegPath)
        p.arguments = ["-hide_banner", "-i", path]
        let errPipe = Pipe()
        p.standardOutput = Pipe()
        p.standardError = errPipe
        do { try p.run() } catch { return nil }
        let data = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: "\n") where line.contains("Video:") {
            if let range = line.range(of: #"Video:\s*(\w+)"#, options: .regularExpression) {
                return line[range].replacingOccurrences(of: "Video:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Parses ffmpeg's own "Duration: HH:MM:SS.ms" banner line, the same probe pattern as
    /// actualVideoHeight/actualVideoCodec. Used by reencodeIfNeeded to size a bitrate
    /// target off the source file instead of guessing a flat number.
    private func probeDurationSeconds(atPath path: String, ffmpegPath: String) -> Double? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpegPath)
        p.arguments = ["-hide_banner", "-i", path]
        let errPipe = Pipe()
        p.standardOutput = Pipe()
        p.standardError = errPipe
        do { try p.run() } catch { return nil }
        let data = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8),
              let range = text.range(of: #"Duration:\s*(\d{2}):(\d{2}):(\d{2}\.\d+)"#, options: .regularExpression) else { return nil }
        let parts = text[range].replacingOccurrences(of: "Duration:", with: "")
            .trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }

    /// yt-dlp's MP4 format selector excludes VP9/AV1 (see VideoQuality.formatSelector(for:)'s own
    /// doc comment) -- but its last fallback clause has no codec restriction at all, so when a
    /// source genuinely has no H.264 stream at the requested height, it still hands back
    /// whatever IS there. The resulting MP4 is completely valid (plays fine in VLC/ffplay), but
    /// Preview and QuickTime Player can't decode AV1 or VP9 at all, on any Mac -- so a card
    /// marked Done could hand back a file the user's own Mac won't open. Reported live: a 1080p
    /// A24 teaser whose only YouTube source was VP9 came through unplayable in Preview, sitting
    /// right next to sibling trailers that had a real H.264 stream and played fine. Re-encodes
    /// the video track to `targetCodec` (audio is stream-copied, untouched) whenever this
    /// happens, so "Done" always means "will actually open" for an MP4 -- and, since both
    /// options are fully native to .mov, doubles as the step that turns an AV1/VP9 source's .mp4
    /// intermediate (see sourceNeedsTranscodeForMov at the download-args site) into a genuine
    /// .mov: `finalExtension` is normally the same as the input's own extension (a true in-place
    /// re-encode), but passing a different one produces the result under that extension instead,
    /// deleting the intermediate. Returns the resulting file's path if a re-encode happened
    /// (which may differ from `path` when finalExtension changed it), nil if none was
    /// needed/possible (the caller re-measures file size either way, from whichever path is current).
    private func reencodeIfNeeded(atPath path: String, ffmpegPath: String, finalExtension: String, targetCodec: ReencodeCodec, downloadID: UUID) -> String? {
        guard let sourceCodec = actualVideoCodec(atPath: path, ffmpegPath: ffmpegPath),
              sourceCodec == "av1" || sourceCodec == "vp9" else { return nil }
        // .off genuinely means "don't touch it" when the file is already sitting in its real
        // final container (MP4 output: a valid, if non-H.264, .mp4 -- see this function's own
        // top-level doc comment on why that's fine to just leave). But a MOV request whose
        // source needed the .mp4 intermediate (mov's muxer flatly can't hold AV1/VP9 at all --
        // see sourceNeedsTranscodeForMov at the download-args site) still has to produce a real
        // .mov somehow, and that container CANNOT hold the untouched source codec either -- so
        // .off can't be honored there. The picker already hides .off for MOV to avoid offering
        // a choice it can't keep, but fall back to H.264 here too in case a card's stored value
        // is stale from before a format switch, rather than silently handing back a .mp4 file
        // under a .mov name.
        guard targetCodec != .off || finalExtension != (path as NSString).pathExtension else { return nil }
        let effectiveCodec = targetCodec == .off ? .h264 : targetCodec
        if targetCodec == .off {
            appendLog("⚠ Off isn't possible for a MOV source -- .mov can't hold \(sourceCodec.uppercased()) at all, re-encoding to \(effectiveCodec.label) instead.")
        }
        appendLog("⚠ Source had no \(effectiveCodec.label) stream at this resolution (got \(sourceCodec.uppercased())) — re-encoding for Preview/QuickTime compatibility…")
        let finalPath = (path as NSString).deletingPathExtension + ".\(finalExtension)"
        let tempPath = (path as NSString).deletingPathExtension + ".reencode.\(finalExtension)"

        // Apple Silicon's dedicated encode hardware (guaranteed present since Drop ships
        // arm64-only) has no CRF/quality-value option for either codec -- -b:v is the only
        // true bitrate lever. Matching the source's own overall bitrate (file size / duration,
        // which also covers the audio track being copied through -- a deliberate slight
        // overshoot on the video target rather than an underestimate) was the original
        // starting point, VMAF-verified against libx264's default CRF on a real 4K source at
        // 94.96 vs 95.77 for H.264 -- a gap that read as imperceptible in that one comparison,
        // but not what the user experienced in practice (reported live: a re-encode "doesn't
        // maintain the same quality as if i didn't re-encode"). See the -realtime/-profile/
        // bitrate-margin comment just below for what actually changed in response.
        // Probed once, up front, and reused for both the bitrate target above and the live
        // progress fraction below (previously probed a second time purely for the bitrate calc).
        let durationSeconds = probeDurationSeconds(atPath: path, ffmpegPath: ffmpegPath)
        // effectiveCodec is never .off here (see the guard above), so this always has a real
        // encoder name -- the fallback is defensive only, never actually hit.
        //
        // -realtime 0: VideoToolbox's own quality-over-speed lever, found after the user
        // reported live that a re-encode "doesn't maintain the same quality as if i didn't
        // re-encode" and asked for quality over speed (or a balance of both). ffmpeg's
        // h264_videotoolbox/hevc_videotoolbox default to VideoToolbox's REAL-TIME encode
        // mode (built for live capture, where staying ahead of the clock matters more than
        // squeezing the most quality out of each frame) -- telling it `-realtime 0` lifts
        // that constraint, so it spends more time per frame on better motion estimation/rate
        // control at the SAME bitrate. This is the single flag the earlier VMAF comparison
        // (94.96 vs libx264's 95.77, see this function's own history) was missing; it should
        // close most of that gap for free, no larger file required. -profile:v high (H.264
        // only -- HEVC's default "main" profile is the right one to leave alone, since a
        // higher HEVC profile changes bit depth/compatibility, not just efficiency) squeezes
        // a bit more compression efficiency out of the same bit budget too.
        var videoArgs = ["-c:v", effectiveCodec.videotoolboxEncoder ?? "h264_videotoolbox", "-realtime", "0"]
        if effectiveCodec == .h264 {
            videoArgs += ["-profile:v", "high"]
        }
        let sizeBytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? nil
        if let sizeBytes, sizeBytes > 0, let durationSeconds, durationSeconds > 0 {
            let sourceKbps = Int((Double(sizeBytes) * 8 / 1000) / durationSeconds)
            // On top of -realtime/-profile above (same bits, better quality), a real "spend
            // more to get more" margin: 30% over the source's own bitrate, matching the
            // user's explicit "quality over speed" preference rather than just matching the
            // source 1:1 (which assumes VideoToolbox is exactly as efficient per-bit as
            // whatever encoder produced the source -- rarely true for a hardware encoder).
            let targetKbps = Int(Double(sourceKbps) * 1.3)
            videoArgs += ["-b:v", "\(targetKbps)k"]
        }

        // The card's progress bar/activity text were driven entirely by yt-dlp's own stdout
        // (see outputThread in startDownload) and never touched again once that process exited --
        // so a re-encode here, which can run tens of seconds on a large 4K source, left the UI
        // frozen on whatever the download left behind with zero feedback (reported live). -progress
        // pipe:1 makes ffmpeg emit a stable, machine-readable `out_time_us=N` line per frame on its
        // own stdout (kept separate from stderr, which still carries human error text on failure
        // below) -- read live the same way outputThread reads yt-dlp's, and converted to a 0-1
        // fraction against the duration already probed above.
        DispatchQueue.main.async {
            self.withDownload(downloadID) {
                $0.activityText = "Re-encoding\u{2026}"
                $0.etaText = ""
                $0.progress = (durationSeconds != nil) ? 0.0 : nil
            }
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpegPath)
        p.arguments = ["-y", "-i", path] + videoArgs + ["-c:a", "copy", "-progress", "pipe:1", "-nostats", "-loglevel", "error", tempPath]
        let progressPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = progressPipe
        p.standardError = errPipe

        let progressThread = Thread {
            let handle = progressPipe.fileHandleForReading
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                guard let text = String(data: buffer, encoding: .utf8) else { continue }
                var lines = text.components(separatedBy: "\n")
                if let last = lines.last, !last.isEmpty {
                    buffer = last.data(using: .utf8) ?? Data()
                    lines.removeLast()
                } else {
                    buffer = Data()
                }
                for line in lines {
                    guard line.hasPrefix("out_time_us="),
                          let total = durationSeconds, total > 0,
                          let microseconds = Double(line.dropFirst("out_time_us=".count)) else { continue }
                    let fraction = min(max((microseconds / 1_000_000) / total, 0), 1)
                    DispatchQueue.main.async { self.withDownload(downloadID) { $0.progress = fraction } }
                }
            }
        }
        progressThread.start()

        do { try p.run() } catch {
            appendLog("❌ Re-encode failed to start: \(error.localizedDescription) — keeping the original \(sourceCodec.uppercased()) file.")
            return nil
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: tempPath) else {
            appendLog("❌ Re-encode to \(effectiveCodec.label) failed — keeping the original \(sourceCodec.uppercased()) file.")
            try? FileManager.default.removeItem(atPath: tempPath)
            return nil
        }
        do {
            try FileManager.default.removeItem(atPath: path)
            try FileManager.default.moveItem(atPath: tempPath, toPath: finalPath)
        } catch {
            appendLog("❌ Couldn't replace the original file after re-encoding: \(error.localizedDescription)")
            try? FileManager.default.removeItem(atPath: tempPath)
            return nil
        }
        appendLog("✓ Re-encoded to \(effectiveCodec.label).")
        return finalPath
    }

    private func startDownload(index idx: Int, config: Config) {
        // Wall-clock start, used below to show "[Ns elapsed]" alongside the
        // progress bar.
        let t0 = Date()
        // yt-dlp's raw per-line percentage is a whole-file estimate that
        // gets recomputed at every HLS/DASH fragment boundary as
        // (bytes-so-far + newly-known-fragment-size) / (fragment-index+1) *
        // total-fragments -- each time a fresh fragment's real size becomes
        // known it revises that whole-file estimate, which visibly knocks
        // the percentage backward a few points (observed in real logs, e.g.
        // 4.8% -> 2.4% -> 0.1% right as fragment 0 handed off to fragment 1).
        // Never letting the displayed fraction go backward within a single
        // download attempt smooths this out without hiding real progress --
        // scoped to this one startDownload call via closure capture, so it
        // naturally resets for the next queued download.
        var lastDisplayedFraction: Double = 0.0

        guard downloads.indices.contains(idx) else { return }
        let downloadID = downloads[idx].id
        guard let ytdlp = ytdlpPath else {
            withDownload(downloadID) {
                $0.status = .error
                $0.errorMessage = "yt-dlp not found"
            }
            return
        }
        let url          = downloads[idx].url
        let outputDir    = downloads[idx].outputDir
        let format       = downloads[idx].format
        let mediaMode    = downloads[idx].mediaMode
        let videoFormat  = downloads[idx].videoFormat
        let videoQuality = downloads[idx].videoQuality
        // Per-item, not config.quality: items started later via startNextPending
        // get a fresh Config() whose quality is just the last persisted value,
        // which used to make every queued item after the first download at
        // whatever quality the most recently added item happened to use.
        let audioQuality = downloads[idx].audioQuality
        let sourceABR    = downloads[idx].snapshot.sourceABR
        let sourceVideoCodec = downloads[idx].snapshot.sourceVideoCodec
        let reencodeCodec = downloads[idx].reencodeCodec
        let isPlaylist   = downloads[idx].isPlaylist
        // Real analyzed title when available (set from the Analyze
        // snapshot in add()); falls back to being literally equal to the
        // URL only on the "paste URLs, skip analyze" path, which is the
        // one case where we still need to ask yt-dlp itself for the title
        // below since there's nothing meaningful to sanitize client-side.
        let knownTitle   = downloads[idx].title
        appendLog("Starting: \(url)")

        // Flip to .downloading with a "Preparing…" activity label on the main
        // thread IMMEDIATELY -- before the folder check, before anything else
        // does any work at all. Previously the folder-exists/writable check
        // below (fm.fileExists/isWritableFile, plus a blocking chmod subprocess
        // in the permission-repair branch) ran synchronously on the calling
        // thread while the card still showed its old .pending "Waiting to
        // download…" state, so pressing Download looked like nothing happened
        // for however long that check took. Now the card visibly changes the
        // instant the button is pressed, and the folder check + filename
        // resolution both move onto the background queue below so the main
        // thread is never blocked by disk I/O or a chmod subprocess.
        DispatchQueue.main.async {
            self.withDownload(downloadID) {
                $0.status = .downloading
                $0.progress = 0
                $0.activityText = "Preparing\u{2026}"
                $0.etaText = ""
                $0.lastKnownETA = nil
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            // Check output directory exists and is writable before launching
            // yt-dlp. Runs on the background queue (not the caller's thread)
            // so it never blocks the main/UI thread -- the chmod fallback in
            // particular spawns and waits on a subprocess, which would have
            // stalled the UI if left on the main thread.
            let fm = FileManager.default
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: outputDir, isDirectory: &isDir) || !isDir.boolValue {
                DispatchQueue.main.async {
                    self.withDownload(downloadID) {
                        $0.status = .error
                        $0.errorMessage = "Output folder does not exist: \(outputDir)"
                        $0.fixHint = "Choose a different folder using the Browse button."
                        $0.fixAction = .openFolderPicker
                    }
                    self.appendLog("ERROR: Output folder does not exist: \(outputDir)")
                }
                return
            }
            if !fm.isWritableFile(atPath: outputDir) {
                // Try to fix permissions automatically with chmod before giving up
                self.appendLog("⚠ Folder not writable, attempting chmod u+w...")
                let chmod = Process()
                chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
                chmod.arguments = ["u+w", outputDir]
                try? chmod.run(); chmod.waitUntilExit()

                if !fm.isWritableFile(atPath: outputDir) {
                    // chmod failed — surface a clear error
                    DispatchQueue.main.async {
                        self.withDownload(downloadID) {
                            $0.status = .error
                            $0.errorMessage = "No write permission for: \(outputDir)"
                            $0.fixHint = "Choose a folder you have permission to write to, such as ~/Music or ~/Downloads."
                            $0.fixAction = .none
                        }
                        self.appendLog("ERROR: Could not get write access to: \(outputDir)")
                        self.showAlert(title: "Permission Denied", message: "Drop can\'t save files to that folder even after trying to fix permissions. Choose a different folder using the Browse button.")
                    }
                    return
                }
                self.appendLog("✓ Fixed folder permissions, continuing download.")
            }
            DispatchQueue.main.async {
                self.withDownload(downloadID) {
                    // Leave progress at 0 (not 0.02) so the progress bar
                    // stays on its shimmer/pulse branch (see the `pct > 0`
                    // check in the card view) instead of switching to a
                    // static sliver-filled bar. yt-dlp's own subprocess
                    // startup + URL extraction takes several real seconds
                    // before its first "%" line ever appears on stdout --
                    // a static 2% bar during that whole gap reads as
                    // "frozen", not "starting". The shimmer communicates
                    // activity for as long as this gap lasts.
                    $0.progress = 0
                    $0.activityText = "Starting download\u{2026}"  // shown right away, before yt-dlp's first output line
                    $0.etaText = ""  // no fake "0%" -- shimmer bar alone communicates activity until a real % arrives
                }
            }

            let proc = Process()
            // Use yt-dlp directly — no shell, no quoting issues with paths/URLs
            proc.executableURL = URL(fileURLWithPath: ytdlp)

            var ytArgs: [String] = []

            // If Analyze already extracted this exact URL recently, feed its
            // cached info dict straight in via --load-info-json instead of
            // making yt-dlp re-resolve the URL from scratch -- this is the
            // same webpage-fetch + player-API + m3u8 round trip Analyze just
            // paid (~9-10s measured on YouTube), so skipping it here makes a
            // just-analyzed link start downloading almost immediately.
            // yt-dlp transparently falls back to a full re-extraction using
            // the original URL if a cached format's signed URL has since
            // expired (ReExtractInfo), so a stale cache is never a hard
            // failure. Playlists are excluded: the cached info dict only
            // ever covers the single first item (Analyze uses
            // --playlist-items 1), which would silently truncate a real
            // playlist download to one file.
            if !isPlaylist, let cachedInfoJSON = self.cachedInfoJSONPath(for: url) {
                ytArgs += ["--load-info-json", cachedInfoJSON]
            }

            ytArgs += config.browser.cookieArgs

            switch mediaMode {
            case .audioOnly:
                if format == .flac {
                    // FLAC: inject format selector for sample rate control, then extract+encode
                    ytArgs += ["-f", audioQuality.flacFormatSelector]
                    ytArgs += format.ytdlpArgs  // -x --audio-format flac
                    // No --audio-quality needed: FLAC is lossless, quality = source selection only
                } else if format == .m4a {
                    // M4A passthrough: no -x, no re-encode, --audio-quality has no effect
                    ytArgs += format.ytdlpArgs  // -f bestaudio[ext=m4a]/bestaudio/best
                } else {
                    // MP3 / WAV: -x re-encodes via ffmpeg, --audio-quality controls bitrate.
                    // Auto means "match the source's own real bitrate exactly" -- pass that
                    // number directly as a CBR target instead of ytdlpAudioQuality's generic
                    // fallback, which would otherwise silently re-round it to a fixed preset.
                    ytArgs += format.ytdlpArgs  // -f bestaudio/best -x --audio-format mp3/wav
                    let quality = (audioQuality == .auto && sourceABR > 0) ? "\(sourceABR)K" : audioQuality.ytdlpAudioQuality
                    ytArgs += ["--audio-quality", quality]
                }
            case .videoAndAudio:
                // Best video + best audio merged. bestaudio always picks highest bitrate available.
                // --audio-quality only affects -x re-encodes; since we're not re-encoding audio here,
                // it has no effect — omit it to avoid confusion.
                ytArgs += ["-f", videoQuality.formatSelector(for: videoFormat)]
                // ffmpeg's mov muxer can't remux AV1/VP9 (mp4's can) -- merge into .mp4
                // in that case instead of the .mov this download will ultimately be, so
                // the merge itself doesn't silently fail/fall back. reencodeIfNeeded
                // below produces the real .mov as its final output once it transcodes to
                // the selected codec, which .mov natively supports either way.
                let sourceNeedsTranscodeForMov = videoFormat == .mov && (sourceVideoCodec == "AV1" || sourceVideoCodec == "VP9")
                ytArgs += sourceNeedsTranscodeForMov ? ["--merge-output-format", "mp4"] : videoFormat.ytdlpArgs  // --merge-output-format
            }

            // YouTube only: as of mid-2026 YouTube requires a per-video PO
            // (Proof of Origin) token for googlevideo.com playback URLs on
            // most clients. Pinning to specific player clients (android_vr,
            // mweb, etc.) either gets 403'd outright or falls back to
            // low-quality muxed formats -- confirmed directly by testing.
            // --impersonate chrome (TLS/HTTP fingerprint spoofing via
            // curl_cffi, baked into the bundled yt-dlp binary) is applied to
            // every yt-dlp call instead -- it doesn't solve the PO-token gate
            // on android_vr-only streams, but it helps avoid other bot-
            // detection related blocks. No client override otherwise; yt-dlp
            // uses its own default client selection.
            // See: https://github.com/yt-dlp/yt-dlp/wiki/Po-Token-Guide
            ytArgs += ["--impersonate", "chrome"]

            // Resolve the exact filename yt-dlp would use (sanitized title), then
            // de-dupe it ourselves. This restores "Title (2).ext" numbering for
            // repeat downloads instead of --no-overwrites silently skipping or a
            // bare template silently clobbering.
            //
            // Fast path: when Analyze already ran (the normal case -- links go
            // through the preview/analyze flow before Download is ever pressed),
            // we already have the real title in-hand. Sanitize it ourselves with
            // ytdlpSanitizedFilename (an exact port of yt-dlp's own algorithm) and
            // skip spawning yt-dlp a second time just to ask it for a filename it
            // would compute from a title we already have -- this was a measured
            // ~1.5-1.7s of pure process-launch overhead on every single download.
            //
            // Slow path fallback: if Download was triggered from the raw "paste
            // URLs, skip analyze" flow, knownTitle is literally just the URL --
            // there is no title to sanitize client-side, so fall back to asking
            // yt-dlp directly, exactly as before.
            var resolvedName = config.filenameTemplate
            if !isPlaylist && config.filenameTemplate == "%(title)s" {
                if !knownTitle.isEmpty && knownTitle != url {
                    resolvedName = self.uniqueBaseName(ytdlpSanitizedFilename(knownTitle), in: outputDir)
                } else {
                    let nameProc = Process()
                    nameProc.executableURL = URL(fileURLWithPath: ytdlp)
                    var nameArgs = ["--no-warnings", "--no-download", "--print", "filename",
                                     "-o", "%(title)s", "--no-playlist", "--impersonate", "chrome"]
                    nameArgs.append(url)
                    nameProc.arguments = nameArgs
                    let namePipe = Pipe()
                    nameProc.standardOutput = namePipe
                    nameProc.standardError = Pipe()
                    do {
                        try nameProc.run()
                        nameProc.waitUntilExit()
                        let data = namePipe.fileHandleForReading.readDataToEndOfFile()
                        if let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !out.isEmpty {
                            resolvedName = self.uniqueBaseName(out, in: outputDir)
                        }
                    } catch {
                        self.appendLog("ERROR: filename resolution failed to launch — \(error.localizedDescription)")
                    }
                }
            }
            DispatchQueue.main.async { self.withDownload(downloadID) { $0.resolvedBaseName = resolvedName } }

            ytArgs += [
                isPlaylist ? "--yes-playlist" : "--no-playlist",
                "--embed-metadata",
                // Always pick the highest bitrate available for both video and audio streams
                "--no-format-sort-force",
                "--format-sort", "res,abr,vbr,asr,codec:av1:vp9.2:vp9:h265:h264",
                // Retry transient errors (403s, connection resets, rate-limit blips)
                // inside yt-dlp itself instead of surfacing them as an immediate
                // failure. YouTube's CDN edges frequently 403 a signed URL for a
                // moment (expiring/rotating tokens, per-edge throttling) and a
                // same-process retry a couple seconds later just works -- this is
                // exactly what manually clicking retry was doing by hand.
                "--retries", "5",
                "--fragment-retries", "5",
                "--extractor-retries", "3",
                "--retry-sleep", "2",
                "--file-access-retries", "3",
                // Write directly to outputDir — no /tmp staging, no file scanner needed
                "-o", "\(outputDir)/\(resolvedName).%(ext)s",
                url
            ]
            proc.arguments = ytArgs
            // Inject Homebrew PATH so ffmpeg etc. are found
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(env["PATH"] ?? "")"
            proc.environment = env

            // Use a single pipe for both stdout+stderr so we never deadlock
            // (reading two pipes on one thread causes deadlock if either buffer fills)
            let outputPipe = Pipe()
            proc.standardOutput = outputPipe
            proc.standardError  = outputPipe
            DispatchQueue.main.async { self.withDownload(downloadID) { $0.process = proc } }

            let stderrOutput  = SyncText()
            // Signalled when the reader thread below has read to the end of yt-dlp's output.
            let readerDone = DispatchSemaphore(value: 0)

            // Read all output on a dedicated thread — never blocks the launch thread
            let outputThread = Thread {
                defer { readerDone.signal() }
                let handle = outputPipe.fileHandleForReading
                var buffer = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    guard let text = String(data: buffer, encoding: .utf8) else { continue }
                    // yt-dlp uses \r for progress lines and \n for regular lines — handle both
                    // Normalize \r to \n so we split on a single separator
                    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
                                         .replacingOccurrences(of: "\r",    with: "\n")
                    var lines = normalized.components(separatedBy: "\n")
                    // Keep the last (possibly incomplete) chunk in buffer
                    if let last = lines.last, !last.isEmpty {
                        buffer = last.data(using: .utf8) ?? Data()
                        lines.removeLast()
                    } else {
                        buffer = Data()
                    }
                    for line in lines {
                        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !t.isEmpty else { continue }
                        stderrOutput.append(t + "\n")
                        // Logged line for this iteration -- normally just `t`
                        // verbatim, but percentage lines get rewritten below
                        // into a Homebrew-style Unicode bar + elapsed time
                        // instead of yt-dlp's raw "[download] NN.N% of ..."
                        // text, so the log reads like a real terminal
                        // installer rather than a wall of repeated percents.
                        var renderedLine = t
                        // Parse progress: "[download]  47.3% of ..."
                        if t.hasPrefix("[download]"), t.contains("%") {
                            let parts = t.components(separatedBy: "%")
                            if let first = parts.first {
                                let token = first.components(separatedBy: CharacterSet.whitespaces).last ?? ""
                                if let pct = Double(token), pct >= 0 {
                                    let rawClamped = min(max(pct / 100.0, 0.02), 1.0)
                                    // yt-dlp's per-line percentage during a
                                    // fragmented (HLS/DASH) download is a
                                    // whole-file *estimate* that gets revised
                                    // every fragment boundary -- early on
                                    // this estimate is wildly unstable and
                                    // can even briefly read 100% (e.g. the
                                    // very first line, when only ~1KiB of
                                    // an unknown-size stream has been seen).
                                    // While fragments are in play (a "(frag
                                    // N/M)" suffix is present and M > 1),
                                    // prefer fragment-index-based progress
                                    // instead -- coarser, but monotonic and
                                    // never spuriously pins at 100% early.
                                    // The true finish line has no "(frag"
                                    // suffix at all, so it always passes
                                    // through untouched.
                                    var effective = rawClamped
                                    if let fragRange = t.range(of: "(frag ") {
                                        let fragText = t[fragRange.upperBound...]
                                        let fragNums = fragText
                                            .components(separatedBy: "/")
                                        if fragNums.count >= 2,
                                           let idx = Int(fragNums[0].trimmingCharacters(in: .whitespaces)),
                                           let total = Int(fragNums[1].components(separatedBy: ")").first?.trimmingCharacters(in: .whitespaces) ?? ""),
                                           total > 1 {
                                            // idx is the fragment currently in
                                            // flight (0-based), so idx/total
                                            // is a safe floor -- never above
                                            // true progress, and only rises.
                                            let fragFloor = min(max(Double(idx) / Double(total), 0.02), 0.99)
                                            effective = fragFloor
                                        }
                                    }
                                    // Never let the displayed value move
                                    // backward within one download attempt.
                                    let clamped = max(effective, lastDisplayedFraction)
                                    lastDisplayedFraction = clamped
                                    // Carry the rest of the line (speed/ETA, after the
                                    // first "%") alongside the bar so that info isn't lost --
                                    // "of 8.23MiB at 1.20MiB/s ETA 00:04" stays visible.
                                    let tail = parts.dropFirst().joined(separator: "%")
                                        .trimmingCharacters(in: .whitespaces)
                                    let elapsed = Int(Date().timeIntervalSince(t0))
                                    let bar = DownloadManager.unicodeProgressBar(fraction: clamped)
                                    renderedLine = tail.isEmpty
                                        ? "\(bar)  [\(elapsed)s elapsed]"
                                        : "\(bar)  \(tail)  [\(elapsed)s elapsed]"
                                    DispatchQueue.main.async {
                                        self.withDownload(downloadID) { $0.progress = clamped }
                                        // Parse: "[download]  47.3% of  8.23MiB at  1.20MiB/s ETA 00:04"
                                        // (yt-dlp's "of X" is only the stream it is on -- the video, then
                                        // the audio -- so it is not used as the file's size: the card
                                        // keeps the analyzed estimate until the real file replaces it.)
                                        let afterPct = parts.dropFirst().joined(separator: "%")
                                        // Speed + ETA activity text
                                        if afterPct.contains(" at ") {
                                            let atParts = afterPct.components(separatedBy: " at ")
                                            if atParts.count > 1 {
                                                let speedEta = atParts[1].trimmingCharacters(in: .whitespaces)
                                                let etaParts = speedEta.components(separatedBy: " ETA ")
                                                let speed = etaParts[0].trimmingCharacters(in: .whitespaces)
                                                // A fragmented stream (HLS/DASH) appends its own
                                                // "(frag 11/50)" counter straight onto the ETA
                                                // with no further delimiter -- yt-dlp's own
                                                // diagnostic text, not part of the countdown. Left
                                                // in, it made etaText long enough to truncate in
                                                // the status card (reported live: "02:55 (frag
                                                // 11…"), so it's stripped before the ETA is ever
                                                // used for the ticking countdown or for display.
                                                let rawEta = etaParts.count > 1 ? etaParts[1].trimmingCharacters(in: .whitespaces) : ""
                                                let eta = (rawEta.components(separatedBy: " (").first ?? rawEta)
                                                    .trimmingCharacters(in: .whitespaces)
                                                // Only show ETA when it's a real, meaningful countdown.
                                                // On fast connections small files finish in under a
                                                // second, so yt-dlp reports "00:00" or "Unknown" almost
                                                // the entire time — showing that looked like a frozen
                                                // countdown. Fall back to speed-only in those cases.
                                                let etaSeconds = eta.components(separatedBy: ":")
                                                    .compactMap { Int($0) }
                                                    .reduce(0) { $0 * 60 + $1 }
                                                let hasRealETA = !eta.isEmpty && eta != "Unknown" && etaSeconds >= 2
                                                let speedIsKnown = !speed.isEmpty && speed != "Unknown B/s"
                                                let text: String
                                                if speedIsKnown {
                                                    text = speed
                                                } else {
                                                    text = "Downloading\u{2026}"
                                                }
                                                self.withDownload(downloadID) {
                                                    $0.activityText = text
                                                    // yt-dlp's ETA jitters between a real countdown and
                                                    // "Unknown"/near-zero on almost every other tick, which
                                                    // made the ETA flash in and out. Once a real ETA has
                                                    // been shown, keep displaying it (percentage still
                                                    // updates live) instead of collapsing back to
                                                    // percent-only on a single stale/"Unknown" tick.
                                                    // The percentage itself is its own element now (see
                                                    // progressIndicator), not folded into this text.
                                                    if hasRealETA {
                                                        $0.etaText = "\(eta) left"
                                                    } else if let prevETA = $0.lastKnownETA {
                                                        $0.etaText = "\(prevETA) left"
                                                    } else {
                                                        $0.etaText = ""
                                                    }
                                                    if hasRealETA { $0.lastKnownETA = eta }
                                                }
                                            } else {
                                                self.withDownload(downloadID) { $0.etaText = "" }
                                            }
                                        } else {
                                            self.withDownload(downloadID) { $0.etaText = "" }
                                        }
                                    }
                                }
                            }
                        }
                        // Map yt-dlp status messages to friendly activity text
                        let activity: String?
                        if t.contains("Extracting URL") || t.contains("Downloading webpage") {
                            activity = "Fetching info…"
                        } else if t.contains("Downloading android") || t.contains("Downloading initial") || t.contains("Downloading player") {
                            activity = "Loading player…"
                        } else if t.contains("Solving JS") || t.contains("deno") {
                            activity = "Solving challenges…"
                        } else if t.contains("m3u8") || t.contains("Downloading m3u8") {
                            activity = "Reading stream…"
                        } else if t.contains("Downloading") && t.contains("format") {
                            activity = "Selecting format…"
                        } else if t.contains("Downloading video thumbnail") {
                            activity = "Fetching thumbnail…"
                        } else if t.hasPrefix("[download]") && !t.contains("%") && t.contains("Destination") {
                            activity = "Starting download…"
                        } else if t.contains("Merging formats") || t.contains("ffmpeg") {
                            activity = "Merging streams…"
                        } else if t.contains("Fixing") || t.contains("Post-process") || t.contains("Adding metadata") {
                            activity = "Processing…"
                        } else if t.contains("Converting") || t.contains("Extracting audio") || t.hasPrefix("[ExtractAudio]") || t.hasPrefix("[ffmpeg]") {
                            activity = "Converting…"
                            DispatchQueue.main.async { self.withDownload(downloadID) { $0.progress = 1.0 } }
                        } else if t.hasPrefix("[EmbedThumbnail]") {
                            activity = "Embedding thumbnail…"
                        } else if t.hasPrefix("[Metadata]") || t.contains("embed-metadata") {
                            activity = "Embedding metadata…"
                        } else {
                            activity = nil
                        }
                        if let a = activity {
                            DispatchQueue.main.async {
                                self.withDownload(downloadID) { $0.activityText = a }
                            }
                        }
                        // NOTE: title is already set from the LinkPreview when the
                        // download row was created (see startDownload's $0.title at
                        // creation) — we intentionally do NOT overwrite it from stdout
                        // here. The main process has no --print line (filename is
                        // resolved separately via nameProc before this runs), so the
                        // first unbracketed stdout line can be arbitrary yt-dlp output
                        // like "Deleting original file ... (pass -k to keep)", which
                        // would clobber the real title if captured.
                        let isProgressLine = t.hasPrefix("[download]") && t.contains("%")
                        DispatchQueue.main.async {
                            self.withDownload(downloadID) { $0.logs.append(renderedLine) }
                            self.appendLog(renderedLine, progressSourceID: isProgressLine ? "download-\(downloadID)" : nil)
                        }
                    }
                }
                // Flush remaining buffer
                if !buffer.isEmpty, let last = String(data: buffer, encoding: .utf8) {
                    let t = last.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty {
                        stderrOutput.append(t)
                        DispatchQueue.main.async {
                            self.withDownload(downloadID) { $0.logs.append(t) }
                            self.appendLog(t)
                        }
                    }
                }
            }
            outputThread.start()

            do {
                try proc.run()
                proc.waitUntilExit()
                // The reader thread may still be draining what yt-dlp wrote last, including the
                // final ERROR line the failure message and the 403 retry look for. Wait for it to
                // reach the end of the stream before anything below reads `stderrOutput` --
                // `Thread.cancel()` alone only sets a flag the read loop never checks. Bounded,
                // because a child process (ffmpeg) can hold the pipe open after yt-dlp exits.
                _ = readerDone.wait(timeout: .now() + 3)
                outputThread.cancel()

                // File was written directly to outputDir by yt-dlp.
                // Find it by scanning outputDir for the newest media file matching the title.
                let fm = FileManager.default
                var confirmedPath: String? = nil
                var fileSize: String? = nil

                let mediaExts = Self.mediaExtensions
                let expectedExt: String = {
                    switch mediaMode {
                    case .audioOnly:             return format.rawValue
                    case .videoAndAudio: return videoFormat.rawValue
                    }
                }()
                // We control the exact literal output name (resolvedName) when it came
                // from our own filename resolution, so prefer an exact match on that;
                // otherwise (playlist / custom template) fall back to fuzzy title matching.
                let resolvedNameFolded = resolvedName
                    .folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: nil)
                let usesExactName = !isPlaylist && config.filenameTemplate == "%(title)s"
                let titleFolded = (self.readDownload(downloadID) { $0.title } ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: nil)

                // Scan for the output file. Retry a couple of times with a short delay —
                // metadata embedding / concurrent duplicate downloads can briefly delay
                // the final file becoming visible in the directory listing.
                func scanForFile() -> (path: String, mod: Date)? {
                    guard let items = try? fm.contentsOfDirectory(atPath: outputDir) else { return nil }
                    var best: (path: String, mod: Date)? = nil
                    for item in items {
                        let ext = (item as NSString).pathExtension.lowercased()
                        guard mediaExts.contains(ext) else { continue }
                        let fullPath = "\(outputDir)/\(item)"
                        guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                              let mod = attrs[.modificationDate] as? Date else { continue }
                        let base = (item as NSString).deletingPathExtension
                            .folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: nil)
                        if usesExactName {
                            guard base == resolvedNameFolded else { continue }
                        } else {
                            guard !titleFolded.isEmpty && base.contains(titleFolded) else { continue }
                        }
                        // Prefer expected extension; among ties pick newest
                        if let b = best {
                            let curIsExpected = ext == expectedExt
                            let bestIsExpected = (b.path as NSString).pathExtension.lowercased() == expectedExt
                            if curIsExpected && !bestIsExpected { best = (fullPath, mod) }
                            else if curIsExpected == bestIsExpected && mod > b.mod { best = (fullPath, mod) }
                        } else {
                            best = (fullPath, mod)
                        }
                    }
                    return best
                }

                var best = scanForFile()
                var retries = 0
                while best == nil && retries < 3 {
                    Thread.sleep(forTimeInterval: 0.3)
                    best = scanForFile()
                    retries += 1
                }
                if let b = best {
                    confirmedPath = b.path
                    self.appendLog("✓ Saved to: \(b.path)")
                } else {
                    self.appendLog("❌ File not found in \(outputDir) after download.")
                }

                // MP4/MOV only -- MKV/WebM hold AV1/VP9 natively, no compatibility issue to fix.
                // For MOV this is also what turns the .mp4 intermediate (see
                // sourceNeedsTranscodeForMov at the download-args site) into the real .mov the
                // user actually asked for -- confirmedPath/the "Saved to" log are corrected to
                // match since the extension itself changes, not just the file's bytes. Before the
                // fileSize measurement below, so a re-encode's real output size is what gets
                // recorded, not the pre-swap original's.
                if mediaMode == .videoAndAudio, (videoFormat == .mp4 || videoFormat == .mov),
                   let path = confirmedPath, let ffmpeg = self.ffmpegPath,
                   let reencodedPath = self.reencodeIfNeeded(atPath: path, ffmpegPath: ffmpeg, finalExtension: videoFormat.rawValue, targetCodec: reencodeCodec, downloadID: downloadID) {
                    confirmedPath = reencodedPath
                    if reencodedPath != path {
                        self.appendLog("✓ Saved to: \(reencodedPath)")
                    }
                }

                if let path = confirmedPath,
                   let attrs = try? fm.attributesOfItem(atPath: path),
                   let bytes = attrs[.size] as? Int64 {
                    fileSize = formatByteSize(Int(bytes))
                }

                // Verify the REAL resulting resolution against what was requested --
                // yt-dlp's format selector can silently settle for a lower height
                // than asked for when the source has no stream at the requested
                // height, and the history/log label used to just echo back the
                // request (videoQuality.label) with no check against the actual
                // file. Only probes for video downloads with a confirmed path;
                // still runs off the main thread here, before the completion
                // handler hops back to it.
                var actualHeight: Int? = nil
                if mediaMode == .videoAndAudio, let path = confirmedPath, let ffmpeg = self.ffmpegPath {
                    actualHeight = self.actualVideoHeight(atPath: path, ffmpegPath: ffmpeg)
                    if let h = actualHeight, h < videoQuality.maxHeight {
                        self.appendLog("⚠ Requested \(videoQuality.label) but source only delivered \(h)p -- history will reflect the actual resolution.")
                    }
                }

                DispatchQueue.main.async {
                    let curStatus = self.readDownload(downloadID) { $0.status }
                    guard curStatus != nil else {
                        // Row is gone (removed/cleared while downloading) — nothing to update.
                        self.startNextPending(after: idx)
                        return
                    }
                    guard curStatus != .cancelled else {
                        self.startNextPending(after: idx)
                        return
                    }
                    if proc.terminationStatus == 0 && confirmedPath != nil {
                        var resolvedTitle = ""
                        var thumb = ""
                        var snap: DownloadSnapshot? = nil
                        self.withDownload(downloadID) {
                            $0.status = .done
                            $0.activityText = ""
                            $0.etaText = ""
                            $0.lastKnownETA = nil
                            $0.fileSize = fileSize
                            $0.outputFilePath = confirmedPath
                            resolvedTitle = $0.title
                            thumb = $0.thumbnailURL
                            snap = $0.snapshot
                        }
                        let title = resolvedTitle
                        self.appendLog("✓ Done: \(title)\(fileSize.map { " (\($0))" } ?? "")")
                        self.sendNotification(title: "Download Complete", body: title)
                        self.playCompletionSound()
                        if config.autoOpenFolder {
                            DispatchQueue.main.async {
                                NSWorkspace.shared.open(URL(fileURLWithPath: outputDir))
                            }
                        }
                        let modeStr = mediaMode == .audioOnly ? format.rawValue.uppercased() :
                                      "\(videoFormat.rawValue.uppercased()) + audio"
                        // Use the ACTUAL probed height when it's lower than what was
                        // requested (source didn't have the requested resolution) --
                        // otherwise keep the clean requested-tier label (e.g. "4K")
                        // instead of a raw pixel number for the common case where the
                        // request was honored exactly.
                        let qualStr = mediaMode == .audioOnly ? audioQuality.rawValue :
                                      (actualHeight.map { $0 < videoQuality.maxHeight ? "\($0)p (requested \(videoQuality.label))" : videoQuality.label } ?? videoQuality.label)
                        let entry = HistoryEntry(
                            title: title, url: url,
                            format: modeStr, quality: qualStr,
                            outputDir: outputDir, fileSize: fileSize,
                            mediaModeRaw: mediaMode.rawValue,
                            thumbnailURL: thumb,
                            // Without this, HistoryEntry.outputFilePath defaulted to "",
                            // so History's Reveal button always fell back to outputDir
                            // (the containing folder) instead of selecting the actual
                            // file, unlike the Download card and Convert's history entries.
                            outputFilePath: confirmedPath ?? "",
                            snapshot: snap
                        )
                        self.history.add(entry)
                        self.startNextPending(after: idx)
                    } else {
                        var failTitle = ""
                        self.withDownload(downloadID) {
                            $0.status = .error
                            failTitle = $0.title
                        }
                        // Save failed download to history so user can see what went wrong
                        let failErrLine = stderrOutput.value.components(separatedBy: "\n")
                            .first(where: { $0.contains("ERROR") }) ?? String(stderrOutput.value.suffix(200))
                        let failEntry = HistoryEntry(
                            title: failTitle.isEmpty ? url : failTitle,
                            url: url, format: "", quality: "",
                            outputDir: outputDir, fileSize: nil,
                            failed: true,
                            errorMessage: failErrLine.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        self.history.add(failEntry)
                        let stderr      = stderrOutput.value.lowercased()
                        // A 403 here almost always means the signed CDN URL yt-dlp
                        // resolved expired or got edge-throttled between extraction
                        // and the actual media fetch -- not that the video is truly
                        // blocked. Re-running yt-dlp from scratch re-derives a fresh
                        // signed URL and typically succeeds, which is exactly what
                        // manually mashing retry was doing by hand. Auto-retry a
                        // few times before ever surfacing this as a failure.
                        let isHTTP403  = stderr.contains("403") && (stderr.contains("forbidden") || stderr.contains("http error 403"))
                        let retryCount = self.readDownload(downloadID) { $0.autoRetryCount } ?? 0
                        if isHTTP403 && retryCount < 4 {
                            // "From scratch" above only actually happens if the retried
                            // startDownload call skips the cached analyze info-json --
                            // otherwise --load-info-json feeds back the EXACT same
                            // resolved stream URL that just got rejected, and yt-dlp
                            // doesn't always detect that as expired and re-extract on
                            // its own (confirmed live: a SoundCloud HLS stream hit the
                            // identical 403 on all 4 attempts, "URLs are ignored due to
                            // --load-info-json" logged every time, no re-extraction ever
                            // attempted). Deleting the cache here forces every retry to
                            // resolve a genuinely new URL from the real page instead of
                            // repeating the same doomed request.
                            self.invalidateAnalyzeCache(for: url)
                            self.withDownload(downloadID) {
                                $0.autoRetryCount += 1
                                $0.status = .downloading
                                $0.activityText = "Retrying after a temporary block\u{2026} (\(retryCount + 1)/4)"
                            }
                            self.appendLog("⚠ Got HTTP 403 — retrying automatically (attempt \(retryCount + 1)/4)\u{2026}")
                            let backoff = Double(retryCount + 1) * 1.5
                            DispatchQueue.main.asyncAfter(deadline: .now() + backoff) {
                                guard let freshIdx = self.downloads.firstIndex(where: { $0.id == downloadID }) else { return }
                                self.startDownload(index: freshIdx, config: config)
                            }
                            return
                        }
                        let isDRM       = stderr.contains("drm")
                        let isCookie    = stderr.contains("operation not permitted") && stderr.contains("cookies")
                        let isPrivate   = stderr.contains("private video") || stderr.contains("sign in")
                        let isUnavail   = stderr.contains("video unavailable") || stderr.contains("no video formats")
                        let fileMissing = proc.terminationStatus == 0 && confirmedPath == nil
                        let errLine: String
                        if fileMissing {
                            errLine = "yt-dlp exited OK but no output file found in \(outputDir). Open the log for details."
                        } else {
                            errLine = stderrOutput.value.components(separatedBy: "\n")
                                .first(where: { $0.contains("ERROR") }) ?? String(stderrOutput.value.suffix(300))
                        }
                        self.withDownload(downloadID) { $0.errorMessage = errLine.isEmpty ? "Unknown error" : errLine }
                        if isCookie {
                            self.withDownload(downloadID) {
                                $0.fixHint = "Safari's cookie DB is locked by macOS."
                                $0.fixAction = .setCookieNone
                            }
                        } else if isDRM {
                            let isYouTubeURL = self.readDownload(downloadID) { $0.url.contains("youtube.com") || $0.url.contains("youtu.be") } ?? false
                            if isYouTubeURL {
                                self.withDownload(downloadID) {
                                    $0.fixHint = "This video is DRM protected and cannot be downloaded."
                                    $0.fixAction = .none
                                }
                            } else {
                                let query = (self.readDownload(downloadID) { $0.title } ?? "")
                                    .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                                self.withDownload(downloadID) {
                                    $0.fixHint = "Track is DRM protected. Try finding it on YouTube instead."
                                    $0.fixAction = .openURL("https://www.youtube.com/results?search_query=\(query)")
                                }
                            }
                        } else if isPrivate {
                            self.withDownload(downloadID) {
                                $0.fixHint = "Video is private. You may need to be signed in via a browser."
                                // .openPrivacySecurity opens macOS System Settings > Privacy &
                                // Security, which has nothing to do with being signed into
                                // YouTube in a browser -- looked like a copy/paste mismatch from
                                // the isCookie branch above. No automated fix exists for this one.
                                $0.fixAction = .none
                            }
                        } else if isUnavail {
                            self.withDownload(downloadID) {
                                $0.fixHint = "Video unavailable or region-locked. Try a different URL."
                                $0.fixAction = .none
                            }
                        } else if fileMissing {
                            self.withDownload(downloadID) {
                                $0.fixHint = "File not written — check the log for details."
                                $0.fixAction = .none
                            }
                        }
                        self.appendLog("ERROR: \(errLine)")
                        if isDRM { self.showAlert(title: "DRM Protected", message: "This track is DRM protected. Try YouTube instead.") }
                        else if !isCookie { self.showAlert(title: "Download Failed", message: errLine.isEmpty ? "Unknown error. Check the log." : errLine) }
                        self.startNextPending(after: idx)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    let curStatus = self.readDownload(downloadID) { $0.status }
                    // Unlike every other terminal path here, this one used to
                    // return without calling startNextPending for the "row
                    // gone" / "cancelled" cases -- if p.run() itself threw
                    // (e.g. yt-dlp missing) at the same moment the row got
                    // cancelled or removed, the queue would silently stall
                    // with pending items never picked up.
                    guard curStatus != nil && curStatus != .cancelled else {
                        self.startNextPending(after: idx)
                        return
                    }
                    self.withDownload(downloadID) {
                        $0.status = .error
                        $0.errorMessage = error.localizedDescription
                    }
                    self.appendLog("ERROR: \(error.localizedDescription)")
                    self.startNextPending(after: idx)
                }
            }
        }
    }

    /// Given a base filename (no extension) and a directory, returns a name guaranteed
    /// not to collide with any existing file of any media extension in that directory —
    /// appending " (2)", " (3)", etc. as needed. Mirrors the old uniqueDestPath behavior.
    private func uniqueBaseName(_ base: String, in dir: String) -> String {
        let fm = FileManager.default
        let mediaExts = Self.mediaExtensions
        func exists(_ name: String) -> Bool {
            mediaExts.contains { fm.fileExists(atPath: "\(dir)/\(name).\($0)") }
        }
        guard exists(base) else { return base }
        var n = 2
        while exists("\(base) (\(n))") { n += 1 }
        return "\(base) (\(n))"
    }

    private func startNextPending(after idx: Int) {
        let activeCount = downloads.filter { $0.status == .downloading }.count
        guard activeCount < Self.maxConcurrentDownloads else { return }
        guard let next = downloads.firstIndex(where: { $0.status == .pending }) else { return }
        // Config() reads filenameTemplate + autoOpenFolder from UserDefaults.
        // All other fields (format, quality, outputDir, etc.) are read directly
        // from downloads[next] inside startDownload.
        startDownload(index: next, config: Config())
    }

    // .medium time style only carries whole-second resolution, so a burst of
    // yt-dlp progress lines (many per second) all print the same identical
    // [HH:MM:SS AM] timestamp -- impossible to see real gaps between them.
    // This formatter adds millisecond precision instead.
    private static let logTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm:ss.SSS a"
        return f
    }()

    /// Which source's progress line currently occupies the LAST slot in globalLogs -- nil means
    /// that slot is a one-off event, not a progress tick, so the next line (whatever it is)
    /// always appends fresh rather than overwriting it.
    private var lastLogProgressSourceID: String? = nil

    /// yt-dlp's download percent and ffmpeg's frame=N both tick many times a second, and used to
    /// each append their own line -- a single download could bury the rest of the log under
    /// thousands of near-identical percent lines. Pass `progressSourceID` (a stable per-job key,
    /// e.g. the download/job's UUID) for a repeating progress tick: consecutive calls with the
    /// SAME id overwrite the log's last line in place, Homebrew/npm-style, instead of appending --
    /// a different id (a second download/conversion running at once) still appends its own fresh
    /// line rather than stomping on the first one's. Leave it nil (the default) for anything that
    /// should remain its own permanent line -- errors, start/finish events, one-off output.
    /// DropLogger's on-disk file is unaffected either way: every call is written there in full,
    /// so the exportable log keeps complete fidelity for troubleshooting even when the in-app
    /// list coalesces.
    func appendLog(_ line: String, progressSourceID: String? = nil) {
        let ts = DownloadManager.logTimestampFormatter.string(from: Date())
        let entry = "[\(ts)] \(line)"
        if let progressSourceID, progressSourceID == lastLogProgressSourceID, !globalLogs.isEmpty {
            globalLogs[globalLogs.count - 1] = entry
        } else {
            globalLogs.append(entry)
            if globalLogs.count > 500 { globalLogs.removeFirst() }
        }
        lastLogProgressSourceID = progressSourceID
        DropLogger.shared.write(entry)
    }

    /// Renders a Homebrew-style Unicode progress bar, e.g. the solid-block
    /// look brew/most CLI installers use: "█████████░░░░░░░░░░░ 47%".
    /// Fixed width so the bar doesn't jitter the log line length as the
    /// percentage changes.
    static func unicodeProgressBar(fraction: Double, width: Int = 24) -> String {
        let clamped = min(max(fraction, 0.0), 1.0)
        let filledCount = Int((clamped * Double(width)).rounded())
        let filled = String(repeating: "█", count: filledCount)
        let empty  = String(repeating: "░", count: width - filledCount)
        let pct = Int((clamped * 100).rounded())
        return "\(filled)\(empty) \(String(format: "%3d", pct))%"
    }

    func showAlert(title: String, message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title; alert.informativeText = message
            alert.alertStyle = .warning; alert.addButton(withTitle: "OK"); alert.runModal()
        }
    }

    func clear() { downloads.removeAll(); globalLogs.removeAll() }
}
