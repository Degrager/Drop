import SwiftUI
import AppKit
import UserNotifications
import UniformTypeIdentifiers
import QuickLookThumbnailing
import CryptoKit
import Sparkle

// MARK: - Layout Grid
//
// Single source of truth for the bottom toolbar's control rows and field boxes,
// so every row shares the same height, corner radius, and border treatment.
// Applies to: Save To field, URL paste field, Clear All button, Auto-Open row,
// and any future single-line control in the Download/Convert bottom bars.
// Layout-only geometry (heights, widths, spacing, font sizes) for the
// Convert/Download control rows. Visual/chrome values (fill, border,
// corner radius) are NOT redefined here anymore -- they read straight
// through to DesignTokens.Field so field chrome can never drift from the
// rest of the app's design language again.
enum DropGrid {
    static let controlHeight: CGFloat = 32         // fixed height for every single-line control row
    static let fieldCorner: CGFloat = DesignTokens.Field.cornerRadius
    static let fieldBorderOpacity: Double = DesignTokens.Field.borderRest
    static let fieldBorderWidth: CGFloat = DesignTokens.Field.borderWidth
    static let fieldFillOpacity: Double = DesignTokens.Field.fillRest
    static let rowSpacing: CGFloat = 8             // gap between a field box and its adjacent button column
    static let sectionSpacing: CGFloat = 16        // gap between major row groups (leftControls / toggle / Clear All)
    static let labelSpacing: CGFloat = 6           // gap between a micro-label and its control
    static let buttonColumnWidth: CGFloat = 120    // fixed width for Browse / Clear All / Paste & Analyze columns
    static let browseWidth: CGFloat = 96           // Browse next to a folder capsule
    static let topBarButtonWidth: CGFloat = 132    // the embedded main button in the Download and Convert input bars (Analyze Link / Browse): one width for both
    static let microLabelSize: CGFloat = 10
    static let fieldFontSize: CGFloat = 12
}

// MARK: - Config

class Config: ObservableObject {
    private let outputDirKey        = "outputDir"
    private let qualityKey          = "quality"
    private let browserKey          = "browser"
    private let reencodeCodecKey    = "reencodeCodec"
    private let filenameTemplateKey = "filenameTemplate"
    private let autoOpenFolderKey   = "autoOpenFolder"
    private let convertOutputDirKey = "convertOutputDir"
    /// False only for detached(...) copies, whose property writes must never
    /// reach UserDefaults.
    private var persists = true

    @Published var outputDir: String {
        didSet { if persists { UserDefaults.standard.set(outputDir, forKey: outputDirKey) } }
    }
    @Published var format: AudioFormat {
        didSet { /* intentionally not persisted — format chip always resets to first-in-list on launch */ }
    }
    @Published var quality: AudioQuality {
        didSet { if persists { UserDefaults.standard.set(quality.rawValue, forKey: qualityKey) } }
    }
    @Published var browser: BrowserSource {
        didSet { if persists { UserDefaults.standard.set(browser.rawValue, forKey: browserKey) } }
    }
    @Published var reencodeCodec: ReencodeCodec {
        didSet { if persists { UserDefaults.standard.set(reencodeCodec.rawValue, forKey: reencodeCodecKey) } }
    }
    @Published var mediaMode: MediaMode {
        didSet { /* intentionally not persisted — resets to first-in-list (Video + Audio) on launch */ }
    }
    @Published var videoFormat: VideoFormat {
        didSet { /* intentionally not persisted — format chip always resets to first-in-list on launch */ }
    }
    @Published var videoQuality: VideoQuality {
        didSet { /* intentionally not persisted — resets to highest-available on launch/per source */ }
    }
    @Published var filenameTemplate: String {
        didSet { if persists { UserDefaults.standard.set(filenameTemplate, forKey: filenameTemplateKey) } }
    }
    @Published var autoOpenFolder: Bool {
        didSet { if persists { UserDefaults.standard.set(autoOpenFolder, forKey: autoOpenFolderKey) } }
    }
    /// Convert tab's batch output directory. Unlike Download's outputDir, this
    /// IS persisted across launches — remembers the last folder picked so
    /// repeat batch conversions don't need re-selecting it every time. Falls
    /// back to Downloads on first run (no saved value yet).
    @Published var convertOutputDir: String {
        didSet { if persists { UserDefaults.standard.set(convertOutputDir, forKey: convertOutputDirKey) } }
    }

    init() {
        // Defaults to Downloads on first run; once the user picks a different folder via
        // Browse, that choice is persisted and reused as the default on future launches.
        let defaultOutputDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? "\(NSHomeDirectory())/Downloads"
        outputDir        = UserDefaults.standard.string(forKey: outputDirKey) ?? defaultOutputDir
        // Format chips always default to the first (native) option in their list on every
        // launch — never restored from a previous session's selection.
        format           = AudioFormat.allCases.first!
        quality          = AudioQuality(rawValue:  UserDefaults.standard.string(forKey: qualityKey) ?? "") ?? .q320
        // REVERTED (2026-10-04): this used to call BrowserSource.autoDetected() on a true first
        // run, to get an authenticated format list (notably 4K+) without any setup. Reported
        // live from real users: it triggered a macOS Keychain prompt for the detected browser's
        // "Safe Storage" key (yt-dlp's --cookies-from-browser has to decrypt Chrome/Edge/Brave's
        // cookie DB to read it) the first time ANYONE clicked Download -- a bewildering, unasked-
        // for permission prompt from a button that has nothing to do with another app's
        // credentials, not a Dev-tooling issue. Defaulting to .none here is the fix: cookies are
        // opt-in only now, via whatever explicit control reaches this setting (none currently
        // does -- autoDetected() is kept on BrowserSource for if/when one is added deliberately).
        browser = BrowserSource(rawValue: UserDefaults.standard.string(forKey: browserKey) ?? "") ?? .none
        // Defaults to Off (not H.264) the first time this has ever run -- the user's explicit
        // choice ("if never been selected before it should default to off"). Any later card's
        // selection overwrites this (see downloadReencodeCodecOptions), so this only matters on
        // a true first use.
        reencodeCodec    = ReencodeCodec(rawValue: UserDefaults.standard.string(forKey: reencodeCodecKey) ?? "") ?? .off
        mediaMode        = MediaMode.allCases.first!
        videoFormat      = VideoFormat.allCases.first!
        // Resolution always defaults to the highest tier (first in list); actual per-video ceiling
        // is re-applied via VideoQuality.highest(for:) once a source's real max height is known.
        videoQuality     = VideoQuality.allCases.first!
        filenameTemplate = UserDefaults.standard.string(forKey: filenameTemplateKey) ?? "%(title)s"
        autoOpenFolder   = UserDefaults.standard.bool(forKey: autoOpenFolderKey)
        let defaultDownloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? "\(NSHomeDirectory())/Downloads"
        convertOutputDir = UserDefaults.standard.string(forKey: convertOutputDirKey) ?? defaultDownloads
    }

    /// A throwaway copy carrying one queued item's own options, for handing to
    /// DownloadManager.add. Batch downloads used to write each item's options
    /// straight into the shared Config instead -- which persisted the last
    /// item's audio quality as the user's default and published a change (and
    /// a re-render of everything observing Config) once per batch item.
    func detached(mediaMode: MediaMode, videoQuality: VideoQuality, videoFormat: VideoFormat,
                  format: AudioFormat, quality: AudioQuality, reencodeCodec: ReencodeCodec) -> Config {
        let copy = Config()
        copy.persists = false
        copy.mediaMode = mediaMode
        copy.videoQuality = videoQuality
        copy.videoFormat = videoFormat
        copy.format = format
        copy.quality = quality
        copy.reencodeCodec = reencodeCodec
        return copy
    }
}
