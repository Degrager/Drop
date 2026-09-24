import SwiftUI
import AppKit
import UserNotifications
import UniformTypeIdentifiers
import QuickLookThumbnailing
import CryptoKit
import Sparkle

/// ffprobe isn't bundled with Drop -- it's a companion tool from whichever
/// Homebrew ffmpeg install the user has, if any (Drop bundles ffmpeg itself,
/// but not ffprobe). Checks both common install locations (Apple Silicon
/// and Intel Homebrew prefixes). Shared by History's legacy-entry migration
/// and Convert's media-info probing so the two search paths can't drift.
func locateFFprobe() -> String? {
    ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"].first { FileManager.default.fileExists(atPath: $0) }
}

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
    static let microLabelSize: CGFloat = 10
    static let fieldFontSize: CGFloat = 12
}

// MARK: - Config

class Config: ObservableObject {
    private let outputDirKey        = "outputDir"
    private let qualityKey          = "quality"
    private let browserKey          = "browser"
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
        browser          = BrowserSource(rawValue: UserDefaults.standard.string(forKey: browserKey) ?? "") ?? .none
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
                  format: AudioFormat, quality: AudioQuality) -> Config {
        let copy = Config()
        copy.persists = false
        copy.mediaMode = mediaMode
        copy.videoQuality = videoQuality
        copy.videoFormat = videoFormat
        copy.format = format
        copy.quality = quality
        return copy
    }
}
enum AudioFormat: String, CaseIterable, Identifiable {
    // WAV first — uncompressed PCM, decodes identically everywhere, best for DaVinci Resolve; other formats follow.
    case wav, m4a, mp3, flac
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
    // Base args — quality args are appended separately in the download path
    var ytdlpArgs: [String] {
        switch self {
        // -x = extract audio. --audio-format tells ffmpeg the output codec.
        // bestaudio (no /best fallback) — avoids pulling a muxed stream just to strip video
        case .mp3:  return ["-f", "bestaudio", "-x", "--audio-format", "mp3"]
        // m4a: passthrough — select native m4a stream, no re-encode, no -x
        case .m4a:  return ["-f", "bestaudio[ext=m4a]/bestaudio"]
        // wav: uncompressed
        case .wav:  return ["-f", "bestaudio", "-x", "--audio-format", "wav"]
        // flac: lossless — -f is injected separately with flacFormatSelector for sample rate control
        case .flac: return ["-x", "--audio-format", "flac"]
        }
    }
    var note: String {
        switch self {
        case .mp3:  return "Universal compatibility"
        case .m4a:  return "Not good for DaVinci Resolve"
        case .wav:  return "Best for DaVinci Resolve"
        case .flac: return "Lossless, large files"
        }
    }
    /// True if this format is a direct stream copy from the source (no ffmpeg decode/encode pass).
    /// Only M4A passthrough avoids -x entirely — MP3/WAV/FLAC all re-encode via ffmpeg.
    var isNative: Bool { self == .m4a }
}

enum AudioQuality: String, CaseIterable, Identifiable {
    case q320 = "320K", q256 = "5", q128 = "9"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .q320: return "320kbps"
        case .q256: return "256kbps"
        case .q128: return "128kbps"
        }
    }
    var flacLabel: String {
        switch self {
        case .q320: return "Lossless"
        case .q256: return "96kHz"  // hi-res
        case .q128: return "48kHz"   // standard (YouTube/SoundCloud native)
        }
    }
    // Format selector override for FLAC (sample rate filter)
    var flacFormatSelector: String {
        switch self {
        case .q320: return "bestaudio"
        case .q256: return "bestaudio[asr>=96000]/bestaudio"
        case .q128: return "bestaudio[asr>=48000]/bestaudio"
        }
    }
    /// kbps for file size estimation
    var kbps: Int {
        switch self { case .q320: return 320; case .q256: return 256; case .q128: return 128 }
    }
    /// yt-dlp --audio-quality argument.
    /// MP3 VBR scale: 0 = best (~245kbps), 5 = ~130kbps, 9 = worst.
    /// For CBR: pass "320K", "256K", "128K" — ffmpeg interprets these as fixed bitrates.
    /// Only has effect when -x / --extract-audio is used (i.e. mp3, wav, flac — NOT m4a passthrough).
    var ytdlpAudioQuality: String {
        // CBR bitrates passed directly to ffmpeg — "0" is VBR ~245kbps, not 320
        switch self { case .q320: return "320K"; case .q256: return "256K"; case .q128: return "128K" }
    }
}


enum MediaMode: String, CaseIterable, Identifiable {
    // Order = display order: Video + Audio, Audio (also the default-first selection).
    case videoAndAudio = "both", audioOnly = "audio"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .audioOnly:     return "Audio Only"
        case .videoAndAudio: return "Video + Audio"
        }
    }
    var icon: String {
        switch self {
        case .audioOnly:     return "waveform"
        case .videoAndAudio: return "video.badge.waveform"
        }
    }
}

enum VideoFormat: String, CaseIterable, Identifiable {
    // MOV removed: yt-dlp/ffmpeg can't merge AV1/VP9 into a real .mov container, so it silently
    // saved as .mp4 anyway while showing "MOV" — a misleading option. QuickTime plays MP4 natively,
    // so MP4 already covers that use case. (Convert tab's MOV is unaffected — that path re-encodes
    // to a genuine .mov file and is a separate enum.)
    case mp4, mkv, webm
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
    var note: String {
        switch self {
        case .mp4:  return "Universal compatibility, QuickTime-ready"
        case .mkv:  return "Best quality container"
        case .webm: return "Web optimized"
        }
    }
    /// All containers here are stream remuxes, not re-encodes — video/audio codecs are untouched.
    var isNative: Bool { true }
    var ytdlpArgs: [String] {
        switch self {
        // --merge-output-format: container used when merging video+audio streams.
        // --remux-video: lossless remux after merge. No re-encoding.
        // MKV is the universal fallback — supports AV1, VP9, H.264, opus, AAC.
        // WebM: merge directly; yt-dlp/ffmpeg handle AV1+opus in WebM fine.
        // --merge-output-format sets the container at merge time — --remux-video is redundant
        case .mp4:  return ["--merge-output-format", "mp4"]
        case .mkv:  return ["--merge-output-format", "mkv"]
        case .webm: return ["--merge-output-format", "webm"]
        }
    }
}

/// Shared source-resolution chip label -- mirrors VideoQuality.label's "4K" convention
/// for the input side, so a 2160p+ source reads "4K" instead of the raw pixel count.
/// Anything below the 4K threshold keeps the plain "Np" form (matches the >=2160
/// bucketing already used by VideoQuality.highest(for:) and the is4KSource checks).
func sourceResolutionLabel(_ height: Int) -> String? {
    guard height > 0 else { return nil }
    return height >= 2160 ? "4K" : "\(height)p"
}

/// The resolution that will actually land in the downloaded file for a given
/// quality selection, clamped to the source's real max height. yt-dlp's
/// format selector (`bestvideo[height<=N]`) can never manufacture pixels the
/// source doesn't have, so whenever the source is shorter than the selected
/// tier -- either because VideoQuality has no tier below 480p (a sub-480p
/// source floors out at .q480) or because the user manually picked a tier
/// above the source (the quality chips deliberately go up to at least 1080p
/// regardless of source height) -- the output preview should show what will
/// really be delivered, not the requested tier's label.
func effectiveVideoResolutionLabel(_ quality: VideoQuality, sourceMaxHeight: Int) -> String {
    if sourceMaxHeight > 0 && sourceMaxHeight < quality.maxHeight {
        return sourceResolutionLabel(sourceMaxHeight) ?? quality.label
    }
    return quality.label
}

/// Shared GB/MB/KB/B formatter -- previously duplicated between LinkPreview's
/// own formatBytes and ContentView's totalEstimatedSizeLabel with a visible
/// inconsistency (one used "%.1f MB", the other "%.0f MB"), so the same byte
/// count could read as two different sizes depending on which chip showed it.
func formatByteSize(_ bytes: Int) -> String {
    let d = Double(bytes)
    if d >= 1_073_741_824 { return String(format: "%.1f GB", d / 1_073_741_824) }
    if d >= 1_048_576     { return String(format: "%.1f MB", d / 1_048_576) }
    if d >= 1_024         { return String(format: "%.0f KB", d / 1_024) }
    return "\(bytes) B"
}

enum VideoQuality: String, CaseIterable, Identifiable {
    case q4k = "2160", q1440 = "1440", q1080 = "1080", q720 = "720", q480 = "480"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .q4k:   return "4K"
        case .q1440: return "1440p"
        case .q1080: return "1080p"
        case .q720:  return "720p"
        case .q480:  return "480p"
        }
    }
    var maxHeight: Int {
        switch self {
        case .q4k:   return 2160
        case .q1440: return 1440
        case .q1080: return 1080
        case .q720:  return 720
        case .q480:  return 480
        }
    }
    /// Format selector for video+audio merged download — sorted by bitrate descending
    var formatSelector: String {
        switch self {
        case .q4k:   return "bestvideo[height<=2160]+bestaudio"
        case .q1440: return "bestvideo[height<=1440]+bestaudio"
        case .q1080: return "bestvideo[height<=1080]+bestaudio"
        case .q720:  return "bestvideo[height<=720]+bestaudio"
        case .q480:  return "bestvideo[height<=480]+bestaudio"
        }
    }
    /// Format selector constrained to a target container's natively-compatible codecs, with
    /// automatic fallback to the best available stream if no compatible codec exists at this
    /// quality. MP4 reliably supports only H.264/AVC video across QuickTime/AVFoundation — both
    /// VP9-in-MP4 and AV1-in-MP4 are excluded (AV1 decode only exists on M3+ chips, and even
    /// there QuickTime has been reported to refuse AV1 MP4s). Crucially, this only excludes vcodec, it
    /// does NOT hard-require avc1 — at higher resolutions (e.g. 4K) many sources have no avc1
    /// stream at all, and a hard avc1 filter would silently cap the download at a lower resolution
    /// (the avc1-restricted alternative still 'succeeds' at 1080p instead of failing over to 4K).
    /// MKV and WebM support VP9/AV1/Opus natively, so no constraint is needed there.
    func formatSelector(for container: VideoFormat) -> String {
        guard container == .mp4 else { return formatSelector }
        let h = maxHeight
        // Prefer the best native M4A/AAC audio (highest bitrate available, Resolve-safe, no
        // re-encode needed for MP4). Only fall back to unrestricted bestaudio if the source has
        // no AAC track at all — rare, but keeps the download from failing outright.
        return "bestvideo[height<=\(h)][vcodec!*=vp9][vcodec!*=av01]+bestaudio[ext=m4a]/bestvideo[height<=\(h)][vcodec!*=vp9][vcodec!*=av01]+bestaudio/bestvideo[height<=\(h)]+bestaudio"
    }
    /// Highest quality that fits within sourceMaxHeight (no upscaling)
    static func highest(for sourceH: Int) -> VideoQuality {
        if sourceH >= 2160 { return .q4k }
        if sourceH >= 1440 { return .q1440 }
        if sourceH >= 1080 { return .q1080 }
        if sourceH >= 720  { return .q720 }
        return .q480
    }
}

enum BrowserSource: String, CaseIterable, Identifiable {
    case none, safari, chrome, firefox, brave, edge
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "None"
        default: return rawValue.capitalized
        }
    }
    var cookieArgs: [String] {
        guard self != .none else { return [] }
        return ["--cookies-from-browser", rawValue]
    }
}

// MARK: - Filename Sanitizer

/// Faithful Swift port of yt-dlp's own `sanitize_filename(s, restricted=False,
/// is_id=NO_DEFAULT)` (yt_dlp/utils/_utils.py, default — non-restricted —
/// mode, which is what Drop's download command uses since it never passes
/// --restrict-filenames). This lets Drop predict the exact on-disk filename
/// yt-dlp would choose for a title WITHOUT spawning a `--print filename`
/// probe process first, cutting real, measured startup latency (~1.5-1.7s)
/// off every download. Ported character-for-character from yt-dlp source
/// (https://github.com/yt-dlp/yt-dlp/blob/master/yt_dlp/utils/_utils.py) on
/// 2026-08-20 so results match yt-dlp's own --print filename output exactly,
/// including the fullwidth Unicode substitutions (e.g. ":" -> "\uFF1A").
/// If yt-dlp ever changes this algorithm upstream, this will silently drift
/// out of sync -- there is no way around that without calling yt-dlp itself,
/// which is exactly the cost this function exists to avoid.
func ytdlpSanitizedFilename(_ input: String) -> String {
    if input.isEmpty { return "" }

    // Step 1: collapse digit:digit:digit timestamps (e.g. "12:34") by
    // replacing their colons with a plain underscore before the main pass,
    // exactly as yt-dlp's regex `[0-9]+(?::[0-9]+)+` does.
    var s = input
    if let re = try? NSRegularExpression(pattern: "[0-9]+(?::[0-9]+)+") {
        let ns = s as NSString
        var result = ""
        var last = 0
        let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            result += ns.substring(with: m.range).replacingOccurrences(of: ":", with: "_")
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        s = result
    }

    // Step 2: per-character replacement, using "\0" as a marker prefix for
    // substitute chars (mirrors yt-dlp's own use of "\0" as a sentinel it
    // strips at the very end) so repeated-substitute collapsing and
    // leading/trailing trims can find them the same way yt-dlp's regexes do.
    var chars: [String] = []
    for scalar in s.unicodeScalars {
        let char = String(scalar)
        if char == "\n" {
            chars.append("\u{0} ")
        } else if "\"*:<>?|/\\".unicodeScalars.contains(scalar) {
            // restricted=False, is_id unset -> full-width unicode counterparts
            if scalar == "/" {
                chars.append("\u{29F8}")
            } else if scalar == "\\" {
                chars.append("\u{29F9}")
            } else if let fullwidth = Unicode.Scalar(scalar.value + 0xFEE0) {
                chars.append(String(fullwidth))
            } else {
                chars.append(char)
            }
        } else {
            chars.append(char)
        }
    }
    var result = chars.joined()

    // Step 3: remove repeated substitute chars -- yt-dlp's `(\0.)(?:(?=\1)..)+`
    // collapses e.g. multiple consecutive "\0 " markers down to one.
    if let re = try? NSRegularExpression(pattern: "(\u{0}.)(?:(?=\\1)..)+") {
        let ns = result as NSString
        result = re.stringByReplacingMatches(in: result, range: NSRange(location: 0, length: ns.length), withTemplate: "$1")
    }

    // Step 4: strip substitute-char runs (mixed with plain space/underscore/
    // hyphen) from the very start and end of the string.
    let stripPattern = "(?:\u{0}.|[ _-])*"
    if let re = try? NSRegularExpression(pattern: "^\u{0}.\(stripPattern)|\(stripPattern)\u{0}.$") {
        let ns = result as NSString
        result = re.stringByReplacingMatches(in: result, range: NSRange(location: 0, length: ns.length), withTemplate: "")
    }

    // Step 5: drop the sentinel marker bytes entirely (their job -- marking
    // substitute chars for the collapse/strip passes above -- is done), and
    // fall back to "_" for a fully-empty result exactly like yt-dlp does.
    result = result.replacingOccurrences(of: "\u{0}", with: "")
    if result.isEmpty { result = "_" }

    // Step 6: collapse doubled underscores, trim stray leading/trailing
    // underscores, fix a leading hyphen, and strip leading dots -- matches
    // yt-dlp's final non-is_id cleanup block.
    while result.contains("__") {
        result = result.replacingOccurrences(of: "__", with: "_")
    }
    result = result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    if result.hasPrefix("-") {
        result = "_" + result.dropFirst()
    }
    while result.hasPrefix(".") {
        result.removeFirst()
    }
    if result.isEmpty { result = "_" }
    return result
}

/// Formats a duration for the card chip as a single value + unit suffix
/// ("45s", "12m", "2h") instead of yt-dlp's raw colon-separated
/// duration_string ("0:45", "12:07", "2:03:41") -- the suffix makes the
/// unit legible at a glance without parsing colons. Picks the largest
/// whole unit that fits: under a minute shows seconds, under an hour
/// shows minutes (rounded to the nearest minute, minimum 1m once past
/// 0s), an hour or more shows hours (one decimal place if it isn't a
/// clean whole number, so "1.5h" reads correctly instead of rounding
/// away a meaningful chunk of a long video/podcast).
func formatDurationChip(seconds: Int) -> String? {
    guard seconds > 0 else { return nil }
    if seconds < 60 {
        return "\(seconds)s"
    } else if seconds < 3600 {
        let mins = max(1, Int((Double(seconds) / 60.0).rounded()))
        return "\(mins)m"
    } else {
        let hours = Double(seconds) / 3600.0
        let rounded = (hours * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return "\(Int(rounded))h"
        } else {
            return String(format: "%.1fh", rounded)
        }
    }
}

// MARK: - History

struct HistoryEntry: Codable, Identifiable {
    let id: UUID
    let title: String
    let url: String
    let format: String
    var quality: String
    var outputDir: String
    var fileSize: String?
    let date: Date
    var failed: Bool = false
    var errorMessage: String? = nil
    var mediaModeRaw: String = "audio"  // "audio", "video", "both" — the mode LAST used, not the source's capability
    // Whether the SOURCE actually has a video track, independent of mediaModeRaw above.
    // Redownload must offer the video+audio toggle whenever this is true, even if the
    // original download was audio-only — otherwise re-queueing an audio-only history
    // entry permanently loses the video option for that link.
    var hasVideo: Bool = false
    var thumbnailURL: String = ""       // persisted thumbnail for re-queue
    var entryType: String = "download" // "download" or "conversion"
    // Full path to the actual finished file (download's saved file, or a
    // conversion's output file). Distinct from `url`, which for conversions
    // holds the ORIGINAL input file's path, not the produced one. Used for
    // the subtext line and for the Reveal button so both point at the real
    // finished file rather than the source or a bare folder.
    var outputFilePath: String = ""
    // Final audio codec label (e.g. "aac", "opus") for conversion entries —
    // populated even when the conversion also has a video track, since
    // `quality` in that case only carries video codec/resolution.
    var audioCodecLabel: String = ""
    // Full analyze snapshot — stored so Redownload from history restores a complete card
    var snapshotDuration: String = ""
    var snapshotDurationSeconds: Int = 0
    var snapshotFileSizeBytes: Int? = nil
    var snapshotSourceMaxHeight: Int = 0
    var snapshotSourceASR: Int = 0
    var snapshotSourceABR: Int = 0
    var snapshotQualityByFormat: [String: String] = [:]  // AudioQuality rawValues
    var snapshotFileSizeByQuality: [String: Int] = [:]   // heightCap as String keys (Codable)

    /// Tolerant decoding: every key is optional on disk. Synthesized Codable
    /// requires every non-optional key to be present, so adding any new field
    /// to this struct made the WHOLE saved history fail to decode -- and the
    /// next save then overwrote it with an empty list. Missing keys now fall
    /// back to the same defaults the properties declare.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                        = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title                     = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        url                       = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        format                    = try c.decodeIfPresent(String.self, forKey: .format) ?? ""
        quality                   = try c.decodeIfPresent(String.self, forKey: .quality) ?? ""
        outputDir                 = try c.decodeIfPresent(String.self, forKey: .outputDir) ?? ""
        fileSize                  = try c.decodeIfPresent(String.self, forKey: .fileSize)
        date                      = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        failed                    = try c.decodeIfPresent(Bool.self, forKey: .failed) ?? false
        errorMessage              = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        mediaModeRaw              = try c.decodeIfPresent(String.self, forKey: .mediaModeRaw) ?? "audio"
        hasVideo                  = try c.decodeIfPresent(Bool.self, forKey: .hasVideo) ?? false
        thumbnailURL              = try c.decodeIfPresent(String.self, forKey: .thumbnailURL) ?? ""
        entryType                 = try c.decodeIfPresent(String.self, forKey: .entryType) ?? "download"
        outputFilePath            = try c.decodeIfPresent(String.self, forKey: .outputFilePath) ?? ""
        audioCodecLabel           = try c.decodeIfPresent(String.self, forKey: .audioCodecLabel) ?? ""
        snapshotDuration          = try c.decodeIfPresent(String.self, forKey: .snapshotDuration) ?? ""
        snapshotDurationSeconds   = try c.decodeIfPresent(Int.self, forKey: .snapshotDurationSeconds) ?? 0
        snapshotFileSizeBytes     = try c.decodeIfPresent(Int.self, forKey: .snapshotFileSizeBytes)
        snapshotSourceMaxHeight   = try c.decodeIfPresent(Int.self, forKey: .snapshotSourceMaxHeight) ?? 0
        snapshotSourceASR         = try c.decodeIfPresent(Int.self, forKey: .snapshotSourceASR) ?? 0
        snapshotSourceABR         = try c.decodeIfPresent(Int.self, forKey: .snapshotSourceABR) ?? 0
        snapshotQualityByFormat   = try c.decodeIfPresent([String: String].self, forKey: .snapshotQualityByFormat) ?? [:]
        snapshotFileSizeByQuality = try c.decodeIfPresent([String: Int].self, forKey: .snapshotFileSizeByQuality) ?? [:]
    }

    init(title: String, url: String, format: String, quality: String,
         outputDir: String, fileSize: String?,
         failed: Bool = false, errorMessage: String? = nil,
         mediaModeRaw: String = "audio",
         thumbnailURL: String = "",
         entryType: String = "download",
         outputFilePath: String = "",
         audioCodecLabel: String = "",
         snapshot: DownloadSnapshot? = nil) {
        self.id           = UUID()
        self.title        = title
        self.url          = url
        self.format       = format
        self.quality      = quality
        self.outputDir    = outputDir
        self.fileSize     = fileSize
        self.date         = Date()
        self.failed       = failed
        self.errorMessage = errorMessage
        self.mediaModeRaw = mediaModeRaw
        // Source capability, not the mode picked — falls back to mediaModeRaw's implication
        // only when there's no snapshot at all (e.g. failed entries with no analyze data).
        self.hasVideo     = snapshot?.hasVideo ?? (mediaModeRaw != "audio")
        self.thumbnailURL = thumbnailURL
        self.entryType       = entryType
        self.outputFilePath  = outputFilePath
        self.audioCodecLabel = audioCodecLabel
        if let snap = snapshot {
            self.snapshotDuration        = snap.duration
            self.snapshotDurationSeconds = snap.durationSeconds
            self.snapshotFileSizeBytes   = snap.fileSizeBytes
            self.snapshotSourceMaxHeight = snap.sourceMaxHeight
            self.snapshotSourceASR       = snap.sourceASR
            self.snapshotSourceABR       = snap.sourceABR
            self.snapshotQualityByFormat = snap.qualityByFormat.mapValues { $0.rawValue }
            self.snapshotFileSizeByQuality = Dictionary(uniqueKeysWithValues:
                snap.fileSizeByQuality.map { (String($0.key), $0.value) })
        }
    }

    /// Audio-quality raw codes ("0"/"5"/"9") to their kbps label — same mapping
    /// used for the live download quality chip, applied here to final output data.
    private var resolvedQualityLabel: String {
        switch quality {
        case "320K": return "320kbps"
        case "5": return "256 kbps"
        case "9": return "128 kbps"
        default:  return quality.isEmpty ? "Best" : quality
        }
    }

    /// Dynamic, color-grouped chips for the History row — mirrors the combined
    /// chip scheme used by Download/Convert cards, but reflects the FINAL output
    /// that was actually produced (not source/pre-download estimates). White/gray =
    /// general file info (size, folder), blue = video output, green = audio output.
    var chips: [ChipData] {
        var result: [ChipData] = []
        // Type chip — download vs conversion
        result.append(ChipData(
            label: "", value: entryType == "conversion" ? "CONVERT" : "DOWNLOAD",
            color: entryType == "conversion" ? .orange : .blue,
            icon: entryType == "conversion" ? "arrow.triangle.2.circlepath" : "arrow.down.circle"
        ))
        if failed {
            result.append(ChipData(label: "", value: "FAILED", color: .red, icon: "xmark.circle"))
            return result
        }
        // Output format + quality — blue for video output, green for audio-only output,
        // matching the mediaMode-driven color rule used on the live download card.
        let isVideo = mediaModeRaw == "video" || mediaModeRaw == "both"
        if isVideo {
            if let video = ChipData.video([format.uppercased(), quality]) { result.append(video) }
            // Video conversions/downloads still carry an audio track — show its
            // codec in its own chip since `quality` above only covers video.
            if let audio = ChipData.audio([audioCodecLabel]) { result.append(audio) }
        } else {
            let showQuality = format.lowercased() != "m4a"
            if let audio = ChipData.audio([format.uppercased(), showQuality ? resolvedQualityLabel : nil]) { result.append(audio) }
        }
        // Final size — white/gray, general file info. (No folder chip: the
        // full path is already shown as plain subtext above this row.)
        if let size = ChipData.lengthAndSize(length: nil, size: fileSize) { result.append(size) }
        return result
    }
}

class HistoryStore: ObservableObject {
    @Published var entries: [HistoryEntry] = []
    private let key = "dropHistory"
    private var saveWorkItem: DispatchWorkItem?

    init() { load() }

    func add(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > 200 {
            entries.suffix(from: 200).forEach { HistoryThumbnailer.deleteCachedThumbnail($0.thumbnailURL) }
            entries = Array(entries.prefix(200))
        }
        scheduleSave()
    }

    func remove(id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        HistoryThumbnailer.deleteCachedThumbnail(entries[idx].thumbnailURL)
        entries.remove(at: idx)
        scheduleSave()
    }

    func clear() {
        entries.forEach { HistoryThumbnailer.deleteCachedThumbnail($0.thumbnailURL) }
        entries.removeAll()
        scheduleSave()
    }

    /// Patches a single entry's thumbnailURL after the fact (used once a
    /// conversion's async QuickLook thumbnail finishes generating, since the
    /// entry is already saved to history by that point) and persists it.
    func updateThumbnail(id: UUID, thumbnailURL: String) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].thumbnailURL = thumbnailURL
        scheduleSave()
    }

    /// Debounced background save — coalesces rapid adds into a single write.
    private func scheduleSave() {
        saveWorkItem?.cancel()
        let snapshot = entries
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if let data = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(data, forKey: self.key)
            }
        }
        saveWorkItem = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    /// Decodes an array one element at a time so a single unreadable entry is
    /// skipped instead of failing the whole list.
    private struct Lossy: Decodable {
        let entry: HistoryEntry?
        init(from decoder: Decoder) throws { entry = try? HistoryEntry(from: decoder) }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        guard let lossy = try? JSONDecoder().decode([Lossy].self, from: data) else {
            // Not even a list. Keep the raw bytes around before the next save
            // overwrites them, rather than silently discarding a whole history.
            UserDefaults.standard.set(data, forKey: key + ".unreadable")
            DropLogger.shared.write("History: saved data was unreadable; kept a copy under \(key).unreadable")
            return
        }
        let saved = lossy.compactMap(\.entry)
        if saved.count != lossy.count {
            UserDefaults.standard.set(data, forKey: key + ".unreadable")
            DropLogger.shared.write("History: \(lossy.count - saved.count) unreadable entries skipped; raw copy kept under \(key).unreadable")
        }
        entries = saved
        // Thumbnails written before entries were cleaned up on eviction/clear
        // are orphaned in the cache forever -- sweep them once per launch.
        let referenced = Set(saved.map(\.thumbnailURL))
        DispatchQueue.global(qos: .background).async { HistoryThumbnailer.pruneCache(keeping: referenced) }
        // Runs ffprobe/disk I/O per legacy entry — kept off the main thread so it
        // never delays app launch, even with a large history list.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.migrateLegacyConversionEntries()
        }
    }

    /// One-time repair for conversion history entries saved before this fix: the
    /// old code passed the full OUTPUT FILE path as `outputDir` (so the folder chip
    /// showed a filename) and never captured `fileSize`/`quality`. This probes the
    /// real file on disk (if it still exists) to recover the true folder, size, and
    /// codec/quality info, running once per affected entry then re-saving.
    private func migrateLegacyConversionEntries() {
        // Snapshot on whatever thread this was called from (background utility
        // queue from load()) — all file I/O and ffprobe calls happen here, off main.
        var snapshot = entries
        var changed = false
        let ffprobe = locateFFprobe()

        for i in snapshot.indices {
            guard snapshot[i].entryType == "conversion", !snapshot[i].failed else { continue }
            let storedPath = snapshot[i].outputDir
            let storedURL = URL(fileURLWithPath: storedPath)
            let looksLikeFile = !storedURL.pathExtension.isEmpty

            // Resolve the real output file path: legacy entries stored the file
            // path itself in outputDir; newer ones already store the directory.
            let candidateFile = looksLikeFile ? storedURL : nil
            guard let fileURL = candidateFile, FileManager.default.fileExists(atPath: fileURL.path) else {
                // Can't find the file on disk (moved/deleted) — at least fix the
                // folder chip so it stops showing a filename where a folder belongs.
                if looksLikeFile {
                    snapshot[i].outputDir = storedURL.deletingLastPathComponent().path
                    changed = true
                }
                continue
            }

            // Fix folder to the real parent directory.
            snapshot[i].outputDir = fileURL.deletingLastPathComponent().path

            // Real file size from disk.
            if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let bytes = attrs[.size] as? Int {
                snapshot[i].fileSize = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            }

            // Probe codec/resolution/bitrate with ffprobe to rebuild the quality descriptor.
            if let ffprobe, snapshot[i].quality.isEmpty {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: ffprobe)
                p.arguments = ["-v", "quiet", "-print_format", "json", "-show_streams", fileURL.path]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = Pipe()
                try? p.run()
                p.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let streams = json["streams"] as? [[String: Any]] {
                    var videoCodec: String? = nil
                    var height: Int? = nil
                    var audioCodec: String? = nil
                    var audioBitrateKbps: Int? = nil
                    for s in streams {
                        let ct = s["codec_type"] as? String ?? ""
                        let cn = s["codec_name"] as? String ?? ""
                        if ct == "video" && videoCodec == nil {
                            videoCodec = cn.uppercased()
                            height = s["height"] as? Int
                        }
                        if ct == "audio" && audioCodec == nil {
                            audioCodec = cn.uppercased()
                            if let brStr = s["bit_rate"] as? String, let br = Int(brStr) {
                                audioBitrateKbps = br / 1000
                            }
                        }
                    }
                    if snapshot[i].mediaModeRaw == "video", let vc = videoCodec {
                        snapshot[i].quality = height != nil ? "\(vc) · \(height!)p" : vc
                    } else if let ac = audioCodec {
                        snapshot[i].quality = audioBitrateKbps != nil ? "\(ac) · \(audioBitrateKbps!)kbps" : ac
                    }
                }
            }
            changed = true
        }

        guard changed else { return }
        let finalSnapshot = snapshot
        DispatchQueue.main.async { [weak self] in
            self?.entries = finalSnapshot
            self?.scheduleSave()
        }
    }
}

// MARK: - Models

/// Frozen analyze results carried from LinkPreview → Download so Retry/Redownload
/// can restore a full card without re-analyzing.
struct DownloadSnapshot {
    var title: String = ""
    var thumbnailURL: String = ""
    var hasVideo: Bool = true
    var duration: String = ""
    var durationSeconds: Int = 0
    var fileSizeBytes: Int? = nil
    var sourceMaxHeight: Int = 0
    var sourceASR: Int = 0
    var sourceABR: Int = 0
    var sourceVideoCodec: String? = nil
    var sourceAudioCodec: String? = nil
    var sourceChannelLabel: String? = nil
    var qualityByFormat: [String: AudioQuality] = ["mp3": .q320, "m4a": .q320, "wav": .q320, "flac": .q320]
    var fileSizeByQuality: [Int: Int] = [:]
}

struct Download: Identifiable {
    let id = UUID()
    let url: String
    var title: String
    var status: DownloadStatus
    var errorMessage: String?
    var fixHint: String?
    var fixAction: FixAction = .none
    let outputDir: String
    let format: AudioFormat
    let mediaMode: MediaMode
    let videoFormat: VideoFormat
    let videoQuality: VideoQuality
    var logs: [String] = []
    var fileSize: String?
    /// Full path to the confirmed output file on disk, set once the download
    /// finishes and yt-dlp's actual output file is located (see scanForFile
    /// in startDownload). Used to show the exact filename in the output
    /// layer and to reveal the file itself (not just its parent folder).
    var outputFilePath: String? = nil
    var process: Process?
    var progress: Double? = nil  // 0.0–1.0 parsed from yt-dlp
    var activityText: String = ""
    /// Right-aligned "NN% · Ns left" readout shown on the same line as
    /// activityText, kept separate so the two can be laid out independently
    /// (status on the left, percentage+ETA on the right).
    var etaText: String = ""
    /// Last real ETA string parsed from yt-dlp (e.g. "00:04"), kept around so
    /// a single stale/"Unknown" tick doesn't collapse the display back to
    /// percent-only — see etaText usage above.
    var lastKnownETA: String? = nil
    /// Base filename (no extension) yt-dlp is writing to, captured as soon as
    /// it's resolved so Cancel can find and delete the partial .part/.ytdl
    /// files (and any partially-merged output) left behind in outputDir.
    var resolvedBaseName: String? = nil
    var thumbnailURL: String = ""  // carried from LinkPreview for history
    var browser: BrowserSource = .none
    var audioQuality: AudioQuality = .q320
    var isPlaylist: Bool = false
    // Full analyze snapshot — populated immediately when dispatched, used by Retry/Redownload
    var snapshot: DownloadSnapshot = DownloadSnapshot()
    /// Counts automatic re-launches triggered after a transient 403 from
    /// yt-dlp (expired/edge-throttled signed URL) so the app can retry a
    /// fresh process on the user's behalf instead of requiring a manual
    /// click, while still capping it so a truly dead/blocked URL doesn't
    /// loop forever. Reset is not needed -- each Download is one-shot.
    var autoRetryCount: Int = 0

    // Input/output chip rows — mirrors Convert's paired-row layout exactly so
    // the two tabs read the same way: length+size first (gray/white), then
    // video info (blue), then audio info (green). Input describes the
    // original link/file; output describes what's being produced/was
    // produced. Length is unchanged by downloading, so both rows show the
    // same duration, matching Convert's input/output length parity.

    /// Input row — the original link's detected length + video/audio, distinct
    /// from the output format/quality/size chips. Falls back to a generic chip
    /// (matching LinkPreview.inputChips' pre-download behavior) when codec
    /// detection didn't resolve anything, so the row never silently disappears.
    var inputChips: [ChipData] {
        var result: [ChipData] = []
        if let length = ChipData.lengthAndSize(length: lengthChipValue(seconds: snapshot.durationSeconds, raw: snapshot.duration), size: nil) {
            result.append(length)
        }
        if mediaMode == .videoAndAudio {
            result.append(.video([snapshot.sourceVideoCodec, sourceResolutionLabel(snapshot.sourceMaxHeight)]) ?? .videoPlaceholder)
        }
        if let audio = ChipData.audio([snapshot.sourceAudioCodec, snapshot.sourceChannelLabel, bitrateLabel(kbps: snapshot.sourceABR)]) {
            result.append(audio)
        } else if mediaMode == .audioOnly {
            result.append(.audioPlaceholder)
        }
        return result
    }

    /// Output row — length (unchanged, same as input) + final size, then the
    /// target format/quality. Size prefers the real post-download file size
    /// (exact, read from disk once done) over the pre-download snapshot
    /// estimate, which can be inaccurate since it's probed before the actual
    /// format/quality is finalized. While actively downloading, size shows
    /// yt-dlp's own reported estimate (set once, not a live disk re-read).
    var outputChips: [ChipData] {
        var result: [ChipData] = []
        let sizeValue: String? = {
            if let sz = fileSize { return sz }
            switch mediaMode {
            case .audioOnly:
                if let sz = snapshot.fileSizeBytes {
                    return ByteCountFormatter.string(fromByteCount: Int64(sz), countStyle: .file)
                }
            case .videoAndAudio:
                let heightKey = videoQuality.maxHeight
                if let sz = snapshot.fileSizeByQuality[heightKey] ?? snapshot.fileSizeByQuality.first?.value {
                    return ByteCountFormatter.string(fromByteCount: Int64(sz), countStyle: .file)
                }
            }
            return nil
        }()
        if let length = ChipData.lengthAndSize(length: lengthChipValue(seconds: snapshot.durationSeconds, raw: snapshot.duration), size: sizeValue) {
            result.append(length)
        }
        switch mediaMode {
        case .audioOnly:
            // M4A is native passthrough (no re-encode), so its real bitrate
            // is the source's own rather than one of the quality presets,
            // which only apply when actually re-encoding to MP3/WAV/FLAC.
            let bitrate = format == .m4a ? bitrateLabel(kbps: snapshot.sourceABR) : audioQuality.label
            result.append(.audio([format.rawValue.uppercased(), snapshot.sourceChannelLabel, bitrate]) ?? .audioPlaceholder)
        case .videoAndAudio:
            // Video is never re-encoded when merging video+audio, so the
            // output codec matches the source's own selected stream. The
            // audio track is stream-copied too, so it reuses the detected
            // source audio info.
            result.append(.video([videoFormat.rawValue.uppercased(), snapshot.sourceVideoCodec,
                                  effectiveVideoResolutionLabel(videoQuality, sourceMaxHeight: snapshot.sourceMaxHeight)]) ?? .videoPlaceholder)
            result.append(.audio([snapshot.sourceAudioCodec, snapshot.sourceChannelLabel, bitrateLabel(kbps: snapshot.sourceABR)]) ?? .audioPlaceholder)
        }
        return result
    }
}

struct ChipData: Hashable {
    let label: String
    let value: String
    let color: Color
    var icon: String? = nil
    var icon2: String? = nil
    var value2: String? = nil
}

extension ChipData {
    /// The white "length (+ size)" chip every chip row leads with. Nil when
    /// neither is known. Shared by Download, LinkPreview and Convert so the
    /// three tabs' rows can't drift apart.
    static func lengthAndSize(length: String?, size: String?) -> ChipData? {
        if let length, let size {
            return ChipData(label: "", value: length, color: .white, icon: "clock", icon2: "internaldrive", value2: size)
        } else if let length {
            return ChipData(label: "", value: length, color: .white, icon: "clock")
        } else if let size {
            return ChipData(label: "", value: size, color: .white, icon: "internaldrive")
        }
        return nil
    }

    /// Blue video chip from whichever parts are known; nil if none are.
    static func video(_ parts: [String?], icon: String = "video") -> ChipData? {
        let value = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return value.isEmpty ? nil : ChipData(label: "", value: value, color: .blue, icon: icon)
    }

    /// Green audio chip from whichever parts are known; nil if none are.
    static func audio(_ parts: [String?]) -> ChipData? {
        let value = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return value.isEmpty ? nil : ChipData(label: "", value: value, color: .green, icon: "waveform")
    }

    static let videoPlaceholder = ChipData(label: "", value: "VIDEO + AUDIO", color: .blue, icon: "video.badge.waveform")
    static let audioPlaceholder = ChipData(label: "", value: "AUDIO", color: .green, icon: "waveform")
}

/// "45s"/"12m"/"2h" from seconds, falling back to yt-dlp's raw duration
/// string only if seconds never resolved (e.g. "NA") but a string is present.
func lengthChipValue(seconds: Int, raw: String) -> String? {
    formatDurationChip(seconds: seconds) ?? ((!raw.isEmpty && raw != "NA") ? raw : nil)
}

func bitrateLabel(kbps: Int) -> String? { kbps > 0 ? "\(kbps)kbps" : nil }

enum DownloadStatus {
    case pending, downloading, done, error, cancelled
    var label: String {
        switch self {
        case .pending:     return "Pending"
        case .downloading: return "Downloading"
        case .done:        return "Done"
        case .error:       return "Error"
        case .cancelled:   return "Cancelled"
        }
    }
    var color: Color {
        switch self {
        case .pending:     return .secondary
        case .downloading: return .white
        case .done:        return .green
        case .error:       return .red
        case .cancelled:   return .orange
        }
    }
}

// MARK: - Fix Actions

enum FixAction: Equatable {
    case setCookieNone          // Safari cookie locked — set browser to None
    case openFolderPicker       // Wrong/missing output folder
    case openPrivacySecurity    // macOS permission issue
    case openURL(String)        // Open a URL (e.g. YouTube search)
    case none
}

// MARK: - Download Manager

class DownloadManager: ObservableObject, @unchecked Sendable {
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
    private var depPollTimer: Timer?
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
                self.toolsReady    = ytdlp && ffmpeg
                self.checkingDeps  = false
                if !self.toolsReady {
                    self.appendLog("Tools not ready yet (yt-dlp=\(ytdlp), ffmpeg=\(ffmpeg)) — waiting on the automatic download. If this doesn't clear after the download finishes, check your internet connection.")
                } else {
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
        task.resume()
    }

    /// Current running version, read straight from the bundle -- this is
    /// what CFBundleShortVersionString/MARKETING_VERSION resolves to at
    /// build time, so it always reflects the actual installed build.
    var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

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
            Self.deletePartialFiles(baseName: downloads[idx].resolvedBaseName, in: downloads[idx].outputDir, log: appendLog)
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
                    // MP3 / WAV: -x re-encodes via ffmpeg, --audio-quality controls bitrate
                    ytArgs += format.ytdlpArgs  // -f bestaudio/best -x --audio-format mp3/wav
                    ytArgs += ["--audio-quality", audioQuality.ytdlpAudioQuality]
                }
            case .videoAndAudio:
                // Best video + best audio merged. bestaudio always picks highest bitrate available.
                // --audio-quality only affects -x re-encodes; since we're not re-encoding audio here,
                // it has no effect — omit it to avoid confusion.
                ytArgs += ["-f", videoQuality.formatSelector(for: videoFormat)]
                ytArgs += videoFormat.ytdlpArgs  // --merge-output-format
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

            var stderrOutput  = ""

            // Read all output on a dedicated thread — never blocks the launch thread
            let outputThread = Thread {
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
                        stderrOutput += t + "\n"
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
                                    let pctLabel = "\(Int((clamped * 100).rounded()))%"
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
                                        let afterPct = parts.dropFirst().joined(separator: "%")
                                        // Extract total size estimate from "of X"
                                        let fileSizeIsNil = self.readDownload(downloadID) { $0.fileSize == nil } ?? false
                                        if fileSizeIsNil,
                                           afterPct.contains(" of ") {
                                            let ofParts = afterPct.components(separatedBy: " of ")
                                            if ofParts.count > 1 {
                                                // "  8.23MiB at ..." — grab first token
                                                let sizeToken = ofParts[1]
                                                    .trimmingCharacters(in: .whitespaces)
                                                    .components(separatedBy: " ").first ?? ""
                                                // Only set if it looks like a size (ends with B)
                                                if sizeToken.hasSuffix("B") && !sizeToken.hasPrefix("~") {
                                                    self.withDownload(downloadID) { $0.fileSize = "~\(sizeToken)" }
                                                }
                                            }
                                        }
                                        // Speed + ETA activity text
                                        if afterPct.contains(" at ") {
                                            let atParts = afterPct.components(separatedBy: " at ")
                                            if atParts.count > 1 {
                                                let speedEta = atParts[1].trimmingCharacters(in: .whitespaces)
                                                let etaParts = speedEta.components(separatedBy: " ETA ")
                                                let speed = etaParts[0].trimmingCharacters(in: .whitespaces)
                                                let eta   = etaParts.count > 1 ? etaParts[1].trimmingCharacters(in: .whitespaces) : ""
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
                                                    if hasRealETA {
                                                        $0.etaText = "\(pctLabel)  \u{B7}  \(eta) left"
                                                    } else if let prevETA = $0.lastKnownETA {
                                                        $0.etaText = "\(pctLabel)  \u{B7}  \(prevETA) left"
                                                    } else {
                                                        $0.etaText = pctLabel
                                                    }
                                                    if hasRealETA { $0.lastKnownETA = eta }
                                                }
                                            } else {
                                                self.withDownload(downloadID) { $0.etaText = pctLabel }
                                            }
                                        } else {
                                            self.withDownload(downloadID) { $0.etaText = pctLabel }
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
                        DispatchQueue.main.async {
                            self.withDownload(downloadID) { $0.logs.append(renderedLine) }
                            self.appendLog(renderedLine)
                        }
                    }
                }
                // Flush remaining buffer
                if !buffer.isEmpty, let last = String(data: buffer, encoding: .utf8) {
                    let t = last.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty {
                        stderrOutput += t
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

                if let path = confirmedPath,
                   let attrs = try? fm.attributesOfItem(atPath: path),
                   let bytes = attrs[.size] as? Int64 {
                    fileSize = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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
                        let failErrLine = stderrOutput.components(separatedBy: "\n")
                            .first(where: { $0.contains("ERROR") }) ?? String(stderrOutput.suffix(200))
                        let failEntry = HistoryEntry(
                            title: failTitle.isEmpty ? url : failTitle,
                            url: url, format: "", quality: "",
                            outputDir: outputDir, fileSize: nil,
                            failed: true,
                            errorMessage: failErrLine.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        self.history.add(failEntry)
                        let stderr      = stderrOutput.lowercased()
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
                            errLine = stderrOutput.components(separatedBy: "\n")
                                .first(where: { $0.contains("ERROR") }) ?? String(stderrOutput.suffix(300))
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

    func appendLog(_ line: String) {
        let ts = DownloadManager.logTimestampFormatter.string(from: Date())
        let entry = "[\(ts)] \(line)"
        globalLogs.append(entry)
        if globalLogs.count > 500 { globalLogs.removeFirst() }
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
extension Font {
    static func appMono(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
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

    /// Same as `blurIn`, but growing from the leading edge -- for text that
    /// appears beside an icon (sidebar labels) so it unfolds out of the icon
    /// instead of scaling from its own centre.
    static let blurInLeading = AnyTransition.asymmetric(
        insertion: focus(blur: 4, scale: 0.85, opacity: 0.3, anchor: .leading)
            .animation(.easeOut(duration: 0.2).delay(0.06)),
        removal: focus(blur: 4, scale: 0.85, opacity: 0.3, anchor: .leading)
            .animation(.easeIn(duration: 0.1))
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
        // Resting black-frosted tint. Raised again from 0.82 -- against the
        // window-wide base tint of 0.74, an 0.08 gap read as barely any
        // separation at all, so cards blended into the background instead
        // of standing out as a distinct layer. 0.93 gives real contrast
        // while the VisualEffectBlur underneath still keeps it from ever
        // looking like a flat, opaque black rectangle.
        static let blackTint: Double = 0.93
        static let blackTintDisabled: Double = 0.4
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
    @State private var glowPhase = false

    var body: some View {
        let T = DesignTokens.Interactive.self
        let fRest = activeFillOverride?.rest ?? T.fillRest
        let fActive = activeFillOverride?.active ?? T.fillActive
        let fHover = activeFillOverride?.hover ?? T.fillHover
        let fPress = activeFillOverride?.press ?? T.fillPress
        let baseOpacity: Double = isActive ? fActive : 0.0
        let fillOpacity: Double = disabled ? baseOpacity : (pressing ? fPress : (hovering ? fHover : (baseOpacity == 0.0 ? fRest : baseOpacity)))
        let strokeOpacity: Double = disabled ? T.strokeDisabled : (pressing ? T.strokePress : (hovering ? (glowPhase ? T.strokeGlow : T.strokeHover) : (restStrokeOverride ?? T.strokeRest)))
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
                                .stroke(tint.opacity(strokeOpacity), lineWidth: (disabled || !hovering) ? 0.75 : 1.1)
                        }
                    }
                    .shadow(color: tint.opacity(glowRadius > 0 ? (glowPhase ? T.glowShadowPeak : T.glowShadowHover) : 0), radius: glowRadius)
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
            if h {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { glowPhase = true }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { glowPhase = false }
            }
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
            return AnyShape(Capsule())
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

struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = DesignTokens.Radius.large
    var opacity: Double = 0.55
    // When true, a Tron-style light beam travels around the card's rim --
    // reserved for active/in-progress states (e.g. a link being analyzed),
    // not a resting decoration. Cards are calm and still until something is
    // actually happening.
    var isActive: Bool = false

    func body(content: Content) -> some View {
        content
            .background(
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
            )
            .overlay(
                // Static, quiet rim running the full perimeter: bright at the
                // top-leading corner, dimmest at the bottom-trailing one, and
                // half-way (0.175) at the other two corners, so it reads as a
                // diagonal specular catch rather than a flat uniform ring.
                // This is the resting state for every card, active or not.
                //
                // A diagonal LinearGradient, not an AngularGradient (which had
                // the same corner values): CoreGraphics rasterizes a conic
                // gradient pixel-by-pixel on the CPU (atan2 per pixel)
                // whenever the card's size changes -- the sidebar collapse
                // tween, cards appearing -- while a linear one is cheap.
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.3), Color.white.opacity(0.05)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ), lineWidth: 0.75
                    )
            )
            .overlay {
                if isActive {
                    RimBeam(cornerRadius: cornerRadius)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Thumbnail-loading placeholder -- a slow, quiet breathing fill instead
/// of a flat static color. A flat `Color.white.opacity(x)` box against the
/// black-frosted card reads as a jarring gray flash the instant it appears
/// (no motion cue that it's *loading* vs. just broken/empty); this softly
/// pulses between two low opacities so the same brief moment reads as
/// "working on it" rather than a gray glitch.
struct ThumbnailSkeleton: View {
    @State private var pulse = false

    var body: some View {
        Color.white.opacity(pulse ? DesignTokens.Interactive.fillRest * 1.6 : DesignTokens.Interactive.fillRest * 0.6)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

/// Waiting-for-paste cue shown around the field only while it's focused
/// and still empty -- a slim, controlled bar of light along the rim
/// rather than a diffuse halo. Restrained pulsate range, no interior
/// fill, and hit-testing disabled so it never blocks clicks/typing into
/// the field underneath. Turns off the instant text lands or focus
/// moves elsewhere.
struct WaitingPulseGlow: View {
    @State private var pulse = false

    var body: some View {
        Capsule()
            .stroke(Color.white.opacity(pulse ? 0.55 : 0.3), lineWidth: 1.5)
            .shadow(color: Color.white.opacity(pulse ? 0.45 : 0.2), radius: pulse ? 6 : 3)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
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
        ZStack {
            // Spinner — fades out on hover
            ProgressView()
                .scaleEffect(0.7)
                .frame(width: 24, height: 24)
                .opacity(hovering ? 0 : 1)

            // X button — fades in on hover
            GlassInteractive(shape: .circle, tint: .red, action: action) {
                Image(systemName: "xmark")
                    .font(.appMono(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .opacity(hovering ? 1 : 0)
        }
        .frame(width: 24, height: 24)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.15)) { hovering = h }
        }
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
    var color: Color = .white
    var activeColor: Color? = nil
    var isActive: Bool = false
    var disabled: Bool = false
    var help: String = ""
    /// When true, hovering reveals `help` as a caption next to the icon
    /// (expanding leftward, icon stays anchored) instead of relying on the
    /// tooltip alone -- one flag per call site, reusing `help`'s text
    /// rather than needing a second string typed out again. false
    /// (default) is icon-only, unchanged from before this existed.
    var expandable: Bool = false
    /// Defaults to the original rounded-rect chrome every existing call
    /// site already expects -- pass .circle for a fully round button
    /// instead, e.g. the queue row's up/down move controls.
    var shape: GlassInteractiveShape = .roundedRect(DesignTokens.Radius.small)
    let action: () -> Void

    @State private var isHovering = false
    /// Measured once from the button's own (fixed) rendered size -- used
    /// only to position the caption's offset below, never to size
    /// anything that .onHover is attached to.
    @State private var buttonWidth: CGFloat = 0

    var body: some View {
        let resolvedColor = isActive ? (activeColor ?? color) : color
        GlassInteractive(shape: shape, tint: resolvedColor, isActive: isActive, disabled: disabled, action: action) {
            Image(systemName: icon)
                .font(.appMono(size: size))
                .padding(6)
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
        .overlay(alignment: .trailing) {
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
                    .offset(x: -(buttonWidth + 6))
                    .allowsHitTesting(false)
                    .transition(.focus(blur: 5, scale: 0.9, opacity: 0.3, anchor: .trailing))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: isHovering)
        .onHover { hovering in
            guard expandable, !disabled else { return }
            isHovering = hovering
        }
        .help(help)
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
    private static func simplify(_ raw: String) -> String {
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
                    .help(updateAvailable ? "Update available" : "Up to date")
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

/// One row of the sidebar's update block -- the SAME view whether the rail is
/// collapsed or open. The status glyph sits on the rail exactly where the tab
/// icons do (WindowLayout.railIconInset), and the tool's name and version chip
/// are revealed beside it as the sidebar widens, the way a tab's label is.
/// Nothing is swapped for a separate collapsed version, so widening the sidebar
/// never cross-fades one layout into another; the row just gets wider.
struct SidebarToolRow: View {
    let name: String
    let installed: Bool
    let updateAvailable: Bool
    /// Raw version string, for the collapsed tooltip.
    let version: String
    let versionChip: AnyView
    @Environment(\.isCompactSidebar) private var compact

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
                .font(.appMono(size: 12))
                .foregroundColor(iconColor)
                .frame(width: WindowLayout.railIconSlot)
            if !compact {
                Text(name)
                    .font(.appMono(size: 11.5, weight: .medium))
                    .foregroundColor(.white.opacity(DesignTokens.Text.secondary))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .transition(.blurInLeading)
                Spacer(minLength: 8)
                versionChip
                    .transition(.blurInLeading)
            }
        }
        .padding(.leading, WindowLayout.railIconInset)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        // The open row is as tall as its version chip (22pt) plus padding; the
        // collapsed row has no chip. Holding the collapsed row to the same
        // height means the block doesn't move up and down as the sidebar
        // opens and closes.
        .frame(maxWidth: .infinity, minHeight: 22 + 16, alignment: .leading)
        .clipped()
        .help(compact ? (version.isEmpty ? name : "\(name) \(version)") : "")
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
            // Each row is paired with its own trailing divider so the divider
            // shrinks with the row it belongs to, and is its own domino step.
            VStack(alignment: .leading, spacing: 2) {
                toolRow("yt-dlp", installed: manager.toolsReady, updateAvailable: manager.updateAvailable,
                        version: manager.ytdlpVersion)
                    .dominoVisibility(hidden: rowsHidden, index: baseIndex)
                toolRow("ffmpeg", installed: manager.toolsReady, updateAvailable: manager.ffmpegUpdateAvailable,
                        version: manager.ffmpegVersion)
                    .dominoVisibility(hidden: rowsHidden, index: baseIndex + 1)
                toolRow("Drop", installed: true, updateAvailable: dropDriver.hasActionableUpdate,
                        version: manager.currentAppVersion)
                    .dominoVisibility(hidden: rowsHidden, index: baseIndex + 2)
                checkForUpdatesButton
                    .padding(.top, 4)
                    .dominoVisibility(hidden: rowsHidden, index: baseIndex + 3)
            }
            .padding(.top, 4)
        }
    }

    private func toolRow(_ name: String, installed: Bool, updateAvailable: Bool, version: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SidebarToolRow(
                name: name,
                installed: installed,
                updateAvailable: updateAvailable,
                version: version,
                versionChip: AnyView(
                    VersionChip(
                        version: version,
                        isUpdating: false,
                        isCheckingUpdates: false,
                        updateAvailable: updateAvailable
                    )
                )
            )
            GlassDivider()
        }
    }

    private var checkForUpdatesButton: some View {
        CheckForUpdatesButton(
            isChecking: manager.checkingUpdates || dropDriver.isActivelyChecking,
            hasUpdate: manager.updateAvailable || manager.ffmpegUpdateAvailable || dropDriver.hasActionableUpdate,
            isUpToDate: manager.justCheckedUpToDate && dropDriver.justConfirmedUpToDate,
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
/// that fills the row, its icon fixed on the rail (where the tab icons are) and
/// its label revealed beside it as the sidebar widens.
struct CheckForUpdatesButton: View {
    let isChecking: Bool
    let hasUpdate: Bool
    // True once the most recently completed check cycle confirmed
    // everything current -- cleared the instant a new check starts, so it
    // can never linger from a stale previous result.
    var isUpToDate: Bool = false
    var disabledUntilSetup: Bool = false
    let action: () -> Void
    @Environment(\.isCompactSidebar) private var compact

    private var accentColor: Color {
        if hasUpdate { return .orange }
        if isUpToDate { return DesignTokens.Accent.success }
        return .white
    }
    private var tint: Color {
        disabledUntilSetup ? Color.white.opacity(DesignTokens.Text.secondary) : accentColor
    }
    private var isDisabled: Bool { isChecking || disabledUntilSetup }
    private var labelText: String {
        isChecking ? "Checking…" : (disabledUntilSetup ? "Tools Missing" : (hasUpdate ? "Update Available" : (isUpToDate ? "Up to Date" : "Check for Updates")))
    }
    private var iconName: String {
        disabledUntilSetup ? "exclamationmark.triangle.fill" : (isUpToDate && !hasUpdate ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
    }

    var body: some View {
        GlassInteractive(shape: .capsule, tint: tint, isActive: false, disabled: isDisabled, action: action) {
            HStack(spacing: 6) {
                Group {
                    if isChecking {
                        // frame BEFORE scaleEffect so the layout box is set first
                        // and the shrunk spinner can't bleed past it.
                        ProgressView().frame(width: 10, height: 10).scaleEffect(0.55)
                    } else {
                        Image(systemName: iconName).font(.appMono(size: 11))
                    }
                }
                .frame(width: WindowLayout.railIconSlot)
                if !compact {
                    Text(labelText)
                        .font(.appMono(size: 11, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .transition(.blurInLeading)
                    Spacer(minLength: 0)
                }
            }
            .padding(.leading, WindowLayout.railIconInset)
            .padding(.trailing, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
        // Same Tron-style light beam as the cards' rims while real work is in
        // progress; RimBeam clamps its radius to min(width, height)/2, so a
        // large constant traces a true capsule at any width.
        .overlay {
            if isChecking { RimBeam(cornerRadius: 999) }
        }
        .help(compact ? labelText : (disabledUntilSetup ? "Bundled yt-dlp/ffmpeg missing — reinstall Drop" : ""))
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

extension View {
    func glassCard(cornerRadius: CGFloat = DesignTokens.Radius.large, opacity: Double = 0.55, isActive: Bool = false) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius, opacity: opacity, isActive: isActive))
    }
}

// MARK: - App Entry

extension Notification.Name {
    static let menuBarDownload = Notification.Name("dropMenuBarDownload")
    /// Fired once, from DropAppDelegate.windowDidEndLiveResize, when the user
    /// releases a window-edge drag. See ContentView's settledWindowSize /
    /// columnClass / settledWindowSize for why this exists.
    static let dropLiveResizeEnded = Notification.Name("dropLiveResizeEnded")
}

/// True while the user is dragging a window edge (from
/// windowWillStartLiveResize to windowDidEndLiveResize). Flips twice per drag,
/// so a view observing it costs nothing per resize tick. Used to pause
/// continuously-running animations (a TimelineView driving a Canvas at the
/// display's refresh rate keeps SwiftUI re-laying-out on macOS), which would
/// otherwise stack on top of the per-frame relayout the drag itself causes.
final class LiveResizeState: ObservableObject {
    static let shared = LiveResizeState()
    @Published private(set) var isActive = false

    func set(_ active: Bool) {
        if active != isActive { isActive = active }
    }
}

// MARK: - App Delegate (enforces the screen-relative minimum window size)

class DropAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var shared: DropAppDelegate!
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    override init() {
        super.init()
        DropAppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Disables AppKit's spelling/completion/substitution machinery
        // globally rather than per-field -- every SwiftUI TextField on
        // macOS is actually edited through one shared "field editor"
        // NSTextView per window, obtainable only via AppKit, so this
        // listens for ANY field beginning editing anywhere in the app.
        // Not what was causing the launch-time popup near the paste field
        // (that turned out to be the system Password AutoFill suggestion
        // window -- see the .textContentType(.URL) fix on that TextField)
        // but still worth keeping: a URL-paste field has no legitimate use
        // for any of this.
        NotificationCenter.default.addObserver(
            forName: NSText.didBeginEditingNotification, object: nil, queue: .main
        ) { note in
            guard let editor = note.object as? NSTextView else { return }
            editor.isAutomaticTextCompletionEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isContinuousSpellCheckingEnabled = false
            editor.isGrammarCheckingEnabled = false
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticDataDetectionEnabled = false
            editor.isAutomaticLinkDetectionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
        }

        // Create status item here — guaranteed AppKit is fully initialized
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: "Drop")
            button.image?.isTemplate = true
            button.action = #selector(handleStatusItemClick)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        let pop = NSPopover()
        pop.contentSize = NSSize(width: 260, height: 160)
        pop.behavior = .transient
        // Force dark vibrancy for the popover's own native bezel/arrow
        // chrome (defaults to light otherwise) so it reads as dark at the
        // edges where SwiftUI content doesn't fully cover it; the black
        // frosted-glass tint/grain on top comes from MenuBarQuickView's own
        // .glassCard() background.
        pop.appearance = NSAppearance(named: .vibrantDark)
        pop.contentViewController = NSHostingController(rootView: MenuBarQuickView())
        popover = pop
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let window = NSApplication.shared.windows.first(where: { !($0 is NSPanel) }) {
                window.delegate = self
                self.applyMinimumSize(to: window)
                self.applyLaunchSize(to: window)
                window.collectionBehavior = [.managed, .fullScreenPrimary]
                // Standard AppKit window -- no NonFullscreenWindow subclass
                // override anymore, so both double-click-title-bar-to-zoom
                // and the green button's native Spaces-fullscreen mode work
                // exactly like any normal Mac app window.
                // The window backing itself must be non-opaque with a
                // clear background color for NSVisualEffectView's
                // .behindWindow blending to have anything real to
                // refract -- .behindWindow blur samples what's actually
                // behind the window (desktop, other apps), but AppKit only
                // composites that through if the window's own backing
                // isn't opaque. Without this the material still renders as
                // a flat blurred color because it's compositing against
                // the window's opaque backing instead of true content
                // behind it -- this is what produced the washed-out white
                // splotches instead of real glass refraction.
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = true
                // Without this the title bar stays an opaque solid strip
                // even though the rest of the window is now transparent --
                // it's a separate chrome layer AppKit draws regardless of
                // window.backgroundColor. isMovableByWindowBackground keeps
                // drag-to-move working since the transparent title bar area
                // no longer paints a draggable bar the user can visually
                // grab.
                window.titlebarAppearsTransparent = true
                window.isMovableByWindowBackground = true
                // Disables macOS's window-state-restoration snapshot --
                // SwiftUI's WindowGroup opts into this by default, which
                // caches a bitmap of the window's content on quit and shows
                // it immediately on the next launch (before the app has
                // actually finished initializing), swapping in real content
                // once ready. Not related to the launch-time paste-field
                // popup (that was the system Password AutoFill suggestion
                // window -- see .textContentType(.URL) on the URL
                // TextField) but still worth keeping off since Drop has no
                // meaningful state worth restoring between launches.
                window.isRestorable = false
            }
        }
    }

    @objc private func handleStatusItemClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showStatusMenu()
        } else {
            togglePopover()
        }
    }

    private func showStatusMenu() {
        let menu = NSMenu()
        let updateItem = menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(.separator())
        let quitItem = menu.addItem(withTitle: "Quit Drop", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func checkForUpdates() {
        // Bring window to front
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { !($0 is NSPanel) })?.makeKeyAndOrderFront(nil)
        // Trigger update check via notification
        NotificationCenter.default.post(name: NSNotification.Name("DropCheckForUpdates"), object: nil)
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if let pop = popover {
            if pop.isShown {
                pop.performClose(nil)
            } else {
                pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                pop.contentViewController?.view.window?.makeKey()
            }
        }
    }

    /// Every launch opens at WindowLayout.defaultSize, centered on the screen
    /// it appears on (the middle of the area left after the menu bar and Dock),
    /// whatever size or place the last session ended at. constrainFrameRect
    /// pulls it back on-screen if the screen is smaller than the window.
    private func applyLaunchSize(to window: NSWindow) {
        let size = WindowLayout.defaultSize
        let screen = window.screen ?? NSScreen.main
        var frame = NSRect(origin: window.frame.origin, size: size)
        if let visible = screen?.visibleFrame {
            frame.origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        }
        window.setFrame(window.constrainFrameRect(frame, to: screen), display: true)
    }

    /// minSize only constrains drags (and SwiftUI can rewrite it from its own
    /// content minimum), so windowWillResize below enforces the same floor.
    private func applyMinimumSize(to window: NSWindow) {
        window.minSize = WindowLayout.minimumSize
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let minimum = WindowLayout.minimumSize
        return NSSize(width: max(frameSize.width, minimum.width), height: max(frameSize.height, minimum.height))
    }

    // Fires once when the user releases a window-edge drag (not on every
    // in-between resize tick, unlike windowWillResize above). ContentView uses
    // this to defer recomputing its layout breakpoints (compact sidebar/height,
    // content column width, chip wrapping) until the drag actually ends,
    // instead of re-deciding all of them on every one of the dozens of frames
    // a drag produces -- see settledWindowSize. Standard
    // AppKit-recommended pattern for expensive live-resize content (Apple's
    // "Cocoa Live Window Resizing" guide): let the raw frame track the mouse,
    // defer real relayout to resize's end.
    func windowDidEndLiveResize(_ notification: Notification) {
        LiveResizeState.shared.set(false)
        NotificationCenter.default.post(name: .dropLiveResizeEnded, object: nil)
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        LiveResizeState.shared.set(true)
    }

}

/// The two sidebar collapse/expand animations, switchable from the View menu >
/// Sidebar Animation. Resize is the default.
enum SidebarAnimationStyle: String {
    /// Rows blur out together, the card resizes, rows pop back in one by one.
    case pop
    /// The card resizes and its tabs and icons resize with it; nothing leaves.
    case resize

    static let storageKey = "sidebarAnimationStyle"
}

struct DropApp: App {
    @NSApplicationDelegateAdaptor(DropAppDelegate.self) var appDelegate
    @AppStorage(SidebarAnimationStyle.storageKey) private var sidebarAnimationStyle = SidebarAnimationStyle.resize.rawValue

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(after: .sidebar) {
                Picker("Sidebar Animation", selection: $sidebarAnimationStyle) {
                    Text("Pop In").tag(SidebarAnimationStyle.pop.rawValue)
                    Text("Resize").tag(SidebarAnimationStyle.resize.rawValue)
                }
            }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        // The delegate then pins the exact frame at every launch
        // (applyLaunchSize); this just keeps the window from first appearing
        // at some other size or place before that runs.
        .defaultSize(width: WindowLayout.defaultSize.width, height: WindowLayout.defaultSize.height)
        .defaultPosition(.center)
    }
}

/// Shared URL-list validator used by both the Download tab's Paste & Analyze
/// button and the menu bar's Paste & Analyze button, so "every line must be
/// a valid http/https URL" is defined in exactly one place.
func dropAllLinesAreURLs(_ text: String) -> Bool {
    let lines = text.components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    guard !lines.isEmpty else { return false }
    return lines.allSatisfy { line in
        guard let url = URL(string: line),
              let scheme = url.scheme,
              (scheme == "http" || scheme == "https"),
              url.host != nil else { return false }
        return true
    }
}

struct MenuBarQuickView: View {
    @State private var submitted = false
    @State private var invalidClipboard = false

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.appMono(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(DesignTokens.Text.secondary))
                Text("Drop")
                    .font(.appMono(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(DesignTokens.Text.primary))
            }

            if submitted {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text("Queued — open Drop to track progress")
                        .font(.appMono(size: 11))
                        .foregroundColor(.white.opacity(DesignTokens.Text.secondary))
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        submitted = false
                    }
                }
            } else {
                // Same label/icon/tint states as the Download tab's own
                // Paste & Analyze button ("Invalid" in red when the
                // clipboard doesn't contain a valid URL list).
                GlassButton(
                    label: invalidClipboard ? "Invalid" : "Paste & Analyze",
                    icon: invalidClipboard ? "exclamationmark.triangle" : "doc.on.clipboard",
                    tint: invalidClipboard ? .red : .white
                ) {
                    pasteAndQueue()
                }
                .onAppear { invalidClipboard = false }
            }

            GlassButton(label: "Open Drop", icon: "arrow.up.forward.app", tint: .white, fitContent: true) {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: { !($0 is NSPanel) })?.makeKeyAndOrderFront(nil)
            }
        }
        .padding(14)
        .frame(width: 260)
        // Same black-frosted-glass recipe as every other surface in the
        // app (VisualEffectBlur + black tint + grain + gradient rim
        // stroke), layered on top of the popover's own dark-vibrancy
        // bezel (set to .vibrantDark where the NSPopover is created) so
        // this reads as Drop's own material, not a stock system popover.
        .glassCard(cornerRadius: DesignTokens.Radius.medium)
        .preferredColorScheme(.dark)
    }

    /// Validates the clipboard exactly like the Download tab's Paste &
    /// Analyze button does, then hands off to ContentView's notification
    /// handler to run the identical placeholder-card + analyze flow.
    private func pasteAndQueue() {
        guard let raw = NSPasteboard.general.string(forType: .string) else {
            flashInvalid()
            return
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, dropAllLinesAreURLs(trimmed) else {
            flashInvalid()
            return
        }
        NotificationCenter.default.post(name: .menuBarDownload, object: nil, userInfo: ["url": trimmed])
        submitted = true
    }

    private func flashInvalid() {
        invalidClipboard = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            invalidClipboard = false
        }
    }
}

// MARK: - App Tab

enum AppTab { case download, history, convert, log, devRelease }

// MARK: - Analyze Result

enum AnalyzeResult {
    case videoAndAudio, audioOnly, unknown
}

// MARK: - On-Disk Log File

/// Persists every appendLog() line to a real file on disk so logs survive app
/// restarts and can be attached/uploaded when reporting an issue. Lives
/// alongside (not instead of) the in-memory globalLogs/log panel.
final class DropLogger {
    static let shared = DropLogger()
    let fileURL: URL
    private let handle: FileHandle?
    private let maxBytes: UInt64 = 5 * 1024 * 1024 // 5MB cap, then rotate

    private init() {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Drop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("drop.log")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = FileHandle(forWritingAtPath: fileURL.path)
        handle?.seekToEndOfFile()
    }

    func write(_ line: String) {
        guard let handle else { return }
        if let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? UInt64,
           size > maxBytes {
            // Rotate: keep the previous file as .1, start fresh.
            let rotated = fileURL.deletingPathExtension().appendingPathExtension("1.log")
            try? FileManager.default.removeItem(at: rotated)
            try? FileManager.default.moveItem(at: fileURL, to: rotated)
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            handle.seek(toFileOffset: 0)
        }
        if let data = (line + "\n").data(using: .utf8) {
            handle.write(data)
        }
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}

// MARK: - Content View

struct ContentView: View {
    @StateObject private var manager  = DownloadManager()
    // Observed directly (not just reached via manager.dropUpdater.userDriver
    // inline) so this view's own body -- specifically the Escape-to-clear-
    // URL-field button below -- actually re-renders when the driver's
    // @Published stage changes. A nested ObservableObject's @Published
    // changes don't propagate through manager's own objectWillChange (the
    // same gap already fixed once for ToolsDropdownContent), so without
    // this the .disabled(...) binding on that button would only update
    // whenever something else happened to redraw ContentView.
    @ObservedObject private var dropDriver: DropCustomUserDriver
    @StateObject private var config   = Config()
    @State private var urlText        = ""
    @State private var isDragging     = false

    @State private var activeTab: AppTab = .download
    @FocusState private var urlFieldFocused: Bool
    @State private var isUrlCardHovering = false
    @State private var isAnalyzing       = false
    @State private var hasInvalidURLs    = false
    // True right after a Paste & Analyze attempt whose URL(s) are already
    // present in linkPreviews -- surfaced as an inline "Already Analyzed"
    // state on the pill instead of silently queuing a second duplicate
    // card. Reset (like analyzeResult) whenever the field's text changes,
    // so it only reflects the most recent paste attempt.
    @State private var duplicateURLDetected = false
    // Keyed by the pending placeholder card's own unique id, NOT the url string.
    // Pasting/analyzing the same link multiple times at once creates multiple
    // pending cards that all share one url -- keying by url made every one of
    // those instances collide on the same dictionary slot, so a later duplicate
    // would silently steal over an earlier one's process reference, cancelling
    // one card would look up and kill/clear ALL cards sharing that url, and
    // finished results would land on whichever same-url pending card happened
    // to still be first in the array rather than the one that actually started
    // that particular process.
    @State private var analyzeProcesses: [UUID: Process] = [:]  // placeholder id -> running analyze process
    // Cards cancelled while still queued behind the analyze concurrency gate
    // (see maxConcurrentAnalyze in analyzeURL) -- at that point there's no
    // Process yet to terminate, so analyzeProcesses alone can't represent
    // "cancel this one." Checked the instant a queued slot opens up for this
    // id so a cancelled-while-waiting card never spawns yt-dlp at all.
    @State private var cancelledAnalyzeIDs: Set<UUID> = []
    // Measured once here and shared with every tab (see WindowLayout and the
    // .environment(...) values injected at the end of body). Previously each
    // tab measured -- or worse, guessed via containerRelativeFrame, which
    // resolves against whatever container happens to be nearest -- its own
    // "60% of something", so Download, Convert and History/Log/Dev never
    // agreed on a width.
    // Raw, continuously-updated geometry -- cheap to store, but every
    // breakpoint BELOW deliberately reads the "settled" snapshot instead (see
    // those two @State vars) so a live window-edge drag doesn't re-decide
    // "should the bottom bar stack / is the sidebar forced compact" on every
    // single one of the dozens of frames a drag produces. Kept around because
    // the settled snapshot needs a live value to catch up to once the drag ends.
    // NOTHING in `body` may read windowSize or mainAreaWidth: they're written on
    // every resize tick, so a read there re-runs ContentView.body -- and every
    // sidebar tab, glass control and the bottom bar under it -- on every tick
    // of a drag (measured: hundreds of re-runs per drag, about a third of the
    // main thread's time). Views that need a decision from the live width read
    // a Bool that only changes when the width crosses a threshold
    // (isNarrowWindow).
    @State private var windowSize: CGSize = .zero
    @State private var mainAreaWidth: CGFloat = 0
    /// Live window width is below WindowLayout.compactSidebarBreakpoint. Only
    /// flips at the threshold, so reading it in `body` costs nothing per tick.
    @State private var isNarrowWindow = false
    // What the height breakpoints below read. Equal to windowSize except while
    // NSApp.keyWindow?.inLiveResize is true, during which it is pinned to its
    // pre-drag value and only catches up once (via the .dropLiveResizeEnded
    // notification, posted from DropAppDelegate.windowDidEndLiveResize) when
    // the drag ends -- height breakpoints recomputed on every resize tick were
    // measurably one of the most expensive things the app did.
    @State private var settledWindowSize: CGSize = .zero
    /// The content column's width reduced to which side of each breakpoint it
    /// is on (WindowLayout.columnClass) -- the only column-width value views
    /// read. It follows the space between the sidebar and the window's right
    /// edge live, but only CHANGES at a breakpoint, so publishing it costs
    /// nothing on the resize ticks in between. The column's real width is
    /// worked out live inside ContentColumnLayout, so cards track the window
    /// frame by frame; only decisions like "stack these chips" wait for this.
    @State private var columnClass: CGFloat = 0
    /// The user's own collapse choice (the toggle in the sidebar header).
    @AppStorage("sidebarCollapsed") private var sidebarCollapsedByUser = false
    /// Which toggle animation to play -- switched from the View menu (see
    /// DropApp.commands) so the two can be compared side by side.
    @AppStorage(SidebarAnimationStyle.storageKey) private var sidebarAnimationStyleRaw = SidebarAnimationStyle.resize.rawValue
    private var sidebarAnimationStyle: SidebarAnimationStyle { SidebarAnimationStyle(rawValue: sidebarAnimationStyleRaw) ?? .resize }
    // The sidebar card's own width. A deliberate toggle tween it (rows blur
    // out, the card visibly shrinks/grows, rows pop back in one by one -- see
    // onChange(of: isCompactSidebar) below); a window-driven change snaps it.
    // While it tweens, columnClass is held (sidebarWidthAnimating) so the
    // main content doesn't restack between side-by-side and stacked on every
    // intermediate width. Seeded from the persisted preference so a
    // collapsed launch doesn't animate on first appearance.
    @State private var sidebarWidth: CGFloat =
        UserDefaults.standard.bool(forKey: "sidebarCollapsed") ? WindowLayout.compactSidebarWidth : WindowLayout.sidebarWidth
    /// True from the moment a toggle starts the card's width tween until it
    /// lands; pins columnClass so breakpoints don't flip mid-tween.
    @State private var sidebarWidthAnimating = false
    /// True for the whole toggle sequence (width tween AND the reveal after
    /// it). While it is, the live-resize rule that switches animations off
    /// stands aside, so the sidebar can animate during a window drag.
    @State private var sidebarSequencePlaying = false
    // What every ROW actually renders as (icon+label vs icon-only) -- this,
    // not isCompactSidebar directly, is what's published to the
    // \.isCompactSidebar environment SidebarTabItem/ToolsDropdownContent/
    // CheckForUpdatesButton read. It only changes once every row has left
    // (mid-tween), so nothing visibly reflows into the new mode early.
    // Without this split, those views saw the NEW mode the instant the
    // toggle was tapped -- their own hard-cut content swap (e.g.
    // SidebarTabItem's `if !compact { Text(label) }`) fired immediately,
    // instead of staying full-content until the rows were gone.
    @State private var sidebarDisplayCompact: Bool =
        UserDefaults.standard.bool(forKey: "sidebarCollapsed")
    /// True while the sidebar's rows (header, tab pills, tools block) are
    /// hidden mid-collapse/expand -- see onChange(of: isCompactSidebar) and
    /// AnyTransition.dominoPop.
    @State private var sidebarRowsHidden = false
    /// Bumped on every collapse/expand toggle so a stale, still-in-flight
    /// asyncAfter from a superseded toggle (the user tapped twice quickly)
    /// can recognize it's no longer current and no-op instead of clobbering
    /// a newer sequence's width/visibility.
    @State private var sidebarToggleGeneration = 0
    // toggle(1) + label(1) + 5 tab pills + 4 tool rows (yt-dlp/ffmpeg/Drop/
    // Check for Updates, see ToolsStatusPill's baseIndex: 7) = indices 0-10,
    // 11 total. Kept at the worst-case count even when Dev is absent -- an
    // unused index just means the reveal's ambient duration is a touch more
    // generous than strictly needed, never too short.
    private static let sidebarRowCount = 11
    /// Pop-in style: how long the card takes to shrink/grow. The rows blur out
    /// together over the first dominoExitDuration of it; the reveal starts
    /// once it lands.
    private static let sidebarWidthDuration: Double = 0.22
    /// Resize style: how long the card takes to shrink/grow, with its tabs and
    /// icons resizing along with it instead of leaving and popping back.
    private static let sidebarResizeDuration: Double = 0.3
    // How long the reveal's last row takes to read as fully settled: its own
    // delay plus a little slack for its spring's overshoot to visibly damp
    // out (a spring doesn't stop dead at `response`, it keeps interpolating
    // past it). Must stay ≥ dominoPop's insertion animation (response +
    // delay) or the last rows get cut off before their pop plays -- see the
    // ambient-wrapper comment below.
    private static var sidebarEnterTotal: Double { AnyTransition.dominoStagger * Double(sidebarRowCount - 1) + 0.2 }
    /// Below this window width the sidebar is ALWAYS icons-only, to free the
    /// room -- the toggle is disabled there rather than letting the sidebar
    /// swallow a third of a narrow window.
    /// Follows the LIVE window width (via isNarrowWindow), not the settled
    /// snapshot the other breakpoints use, so the sidebar collapses/expands the
    /// moment a drag crosses the threshold rather than when the mouse is
    /// released.
    private var sidebarForcedCollapsed: Bool { isNarrowWindow }
    private var isCompactSidebar: Bool { sidebarForcedCollapsed || sidebarCollapsedByUser }
    private var isCompactHeight: Bool { settledWindowSize.height > 0 && settledWindowSize.height < WindowLayout.compactHeightBreakpoint }
    private var isTinyHeight: Bool { settledWindowSize.height > 0 && settledWindowSize.height < WindowLayout.tinyHeightBreakpoint }
    @State private var convertStagingJobs: [ConvertJob] = []
    @State private var convertQueue: [ConvertJob] = []
    /// Lives here (not as local @State in ConvertView) because activeTab
    /// switches unmount/remount ConvertView -- local @State would reset to
    /// nil on every trip back to the tab, making the Analyze panel look
    /// like it "lost" its staged files even though stagingJobs itself
    /// (also lifted here for the same reason) still had them.
    @State private var convertSelectedStagingID: ConvertJob.ID? = nil

    /// Select mode — mirrors Convert's Batch Apply toggle. Off by default;
    /// checkboxes on link cards only show while this is true. Outside Select
    /// mode every queued item counts as included (checkbox hidden = implicitly
    /// selected), same convention as Convert.
    @State private var isBatchMode = false

    /// Includes pending (still-analyzing) cards -- shows the Select/Clear
    /// toolbar as soon as a link starts analyzing, instead of waiting for
    /// the first one to finish.
    private var hasAnyLinkItems: Bool { !linkPreviews.isEmpty }
    /// Outside Select mode every queued item is treated as selected (checkboxes
    /// are hidden, so nothing is excluded). Inside Select mode, only what's
    /// actually checked counts. Either way, a card that already failed to
    /// analyze (shown on screen as its own error banner) is never a real
    /// download target -- excluding it here fixes it everywhere this is used:
    /// the "Download N Items" count/button label, whether the primary action
    /// shows at all, the total-size estimate, and (most importantly) download()
    /// itself, which used to happily queue a doomed-to-fail download for a
    /// link the user already saw fail to analyze.
    private var selectedPreviews: [LinkPreview] {
        let base = isBatchMode ? linkPreviews.filter { $0.isSelected } : linkPreviews
        return base.filter { $0.analyzeError == nil }
    }
    private var allEligibleLinksSelected: Bool {
        let eligible = linkPreviews.filter { !$0.isPending && $0.downloadID == nil && $0.analyzeError == nil }
        guard !eligible.isEmpty else { return false }
        return eligible.allSatisfy { $0.isSelected }
    }
    private func toggleSelectAllLinks() {
        let shouldSelect = !allEligibleLinksSelected
        for i in linkPreviews.indices where !linkPreviews[i].isPending && linkPreviews[i].downloadID == nil && linkPreviews[i].analyzeError == nil {
            linkPreviews[i].isSelected = shouldSelect
        }
    }

    /// Cards that can actually be collapsed/expanded -- queued, not pending
    /// (downloading/done/failed cards don't have a collapse toggle at all).
    /// Shared by allLinksCollapsed/hasExpandableLinks so the two can't drift
    /// out of sync on what counts as "collapsible."
    private var collapsibleLinks: [LinkPreview] {
        linkPreviews.filter { !$0.isPending && $0.downloadID == nil && $0.analyzeError == nil }
    }

    /// True once every collapsible card is collapsed — flips the header
    /// button to "Expand All". Empty list counts as not-collapsed.
    private var allLinksCollapsed: Bool {
        let queued = collapsibleLinks
        return !queued.isEmpty && queued.allSatisfy { !$0.isExpanded }
    }

    /// True when at least one card can actually be collapsed/expanded. Select
    /// mode force-collapses + locks every card's toggle.
    private var hasExpandableLinks: Bool {
        !isBatchMode && !collapsibleLinks.isEmpty
    }

    /// While anything is still analyzing, collapse/expand has nothing
    /// consistent to act on yet (pending cards don't have a collapse
    /// state), so the button is hidden entirely rather than just disabled
    /// -- it reappears once every card in the queue has resolved.
    private var anyLinksStillAnalyzing: Bool {
        linkPreviews.contains { $0.isPending }
    }

    /// Collapses every card if any are still expanded; expands every card
    /// once they're all already collapsed.
    private func toggleCollapseAllLinks() {
        let shouldCollapse = !allLinksCollapsed
        for i in linkPreviews.indices where !linkPreviews[i].isPending && linkPreviews[i].downloadID == nil && linkPreviews[i].analyzeError == nil {
            linkPreviews[i].isExpanded = !shouldCollapse
        }
    }

    var readyToDownload: Bool { manager.toolsReady }

    init() {
        let manager = DownloadManager()
        _manager = StateObject(wrappedValue: manager)
        _dropDriver = ObservedObject(wrappedValue: manager.dropUpdater.userDriver)
    }

    var body: some View {
        ZStack {
            // Window-wide black-frosted glass base. The window itself is
            // non-opaque (see DropAppDelegate) so this NSVisualEffectView
            // genuinely refracts real desktop/window content behind Drop
            // via .behindWindow blending. NSVisualEffectView has no
            // exposed blur-radius knob (its diffusion amount is fixed by
            // material), so an extra SwiftUI .blur() pass is layered on
            // top of the material to push the refracted content softer/
            // more diffused -- real content is still genuinely showing
            // through, just less sharply resolved, which reads as heavier
            // frosting. Black tint raised (0.55 -> 0.74, close to the
            // per-card 0.72) for a darker base per zanderriley's request,
            // while cards stay a hair above that so they still read as a
            // slightly deeper layer floating on top.
            VisualEffectBlur(material: DesignTokens.Glass.material, blendingMode: .behindWindow)
                .blur(radius: 18)
                .ignoresSafeArea()
            Color.black.opacity(0.74)
                .ignoresSafeArea()

            // Main layout — sidebar on the left, active tab's content on the
            // right. Sidebar is now a floating GlassCard with its own
            // margin (leading/vertical padding applied inside `sidebar`
            // itself), so no extra gap is needed here.
            HStack(spacing: 0) {
                // Above everything in the main column, so the sidebar's card
                // (and its shadow) always draws over content beside it.
                sidebar
                    .zIndex(99)

                VStack(spacing: 0) {
                    // Active tab content -- structurally unrelated pages, so
                    // they swap with `.pageSwap`: the outgoing page blurs
                    // away quickly while the incoming one focuses in a beat
                    // later. The stagger matters -- the old cross-fade laid
                    // both pages' headers over each other, which is why this
                    // used to be a hard cut. Blur (not opacity) also keeps
                    // the glass cards from greying out mid-switch.
                    ZStack(alignment: .top) {
                    Group {
                        if activeTab == .download {
                            mainPanel
                                .transition(.pageSwap)
                        } else if activeTab == .history {
                            HistoryView(history: manager.history, activeTab: $activeTab, urlText: $urlText, hasInvalidURLs: $hasInvalidURLs, linkPreviews: $linkPreviews, config: config, onAnalyze: { urls, ids in analyzeURL(urls: urls, ids: ids) }, onReconvert: { fileURL in
                                // Treat Reconvert exactly like freshly dropping/importing the original
                                // input file into the Convert tab — no stored snapshot reused, the file
                                // is re-probed from scratch just like a first-time add.
                                // Selecting the job matters: ConvertView's Analyze panel only
                                // renders the SELECTED staged file, so appending without
                                // selecting left Reconvert landing on an empty Convert tab.
                                if let existing = convertStagingJobs.first(where: { $0.inputURL == fileURL }) {
                                    convertSelectedStagingID = existing.id
                                    activeTab = .convert
                                    return
                                }
                                guard !convertQueue.contains(where: { $0.inputURL == fileURL }) else {
                                    activeTab = .convert
                                    return
                                }
                                let job = ConvertJob(inputURL: fileURL)
                                withAnimation(.spring(response: 0.35)) {
                                    convertStagingJobs.append(job)
                                    convertSelectedStagingID = job.id
                                }
                                activeTab = .convert
                            })
                            // History is one continuous panel rather than a stack of
                            // floating cards, so the equivalent of "cap the cards at
                            // the content column" here is capping the whole panel -- the
                            // same shared column width and centering as every other tab.
                            .contentColumn()
                            .transition(.pageSwap)
                        } else if activeTab == .convert {
                            ConvertView(ffmpegPath: manager.ffmpegPath, toolsReady: readyToDownload, history: manager.history, stagingJobs: $convertStagingJobs, queue: $convertQueue, selectedStagingID: $convertSelectedStagingID, config: config, manager: manager)
                                .transition(.pageSwap)
                        } else if activeTab == .devRelease {
                            // Real content is devReleaseOverlay below, kept
                            // permanently mounted instead of created fresh
                            // here -- see its comment for why.
                            Color.clear
                        } else {
                            // Log is now a full page like Download/History/Convert
                            // instead of a floating side panel -- same bare-VStack-
                            // against-the-window-glass structure and 60%-width
                            // convention as History, not a card floating on a page.
                            LogView(logs: manager.globalLogs)
                                .contentColumn()
                                .transition(.pageSwap)
                        }
                    }
                    // Scoped to `activeTab` so only the page swap picks up this
                    // spring; other state changes inside the subtree (card
                    // spawns, thumbnail loads) keep their own animations.
                    .animation(.easeOut(duration: 0.2), value: activeTab)

                    // Dev tab, unlike the others above, keeps essentially
                    // all of its own state locally (pipeline, typed-in
                    // version/changelog, fetched releases/audit trail) --
                    // nothing hoisted up to ContentView the way History's
                    // and Convert's real data lives in `manager`. Mounting
                    // it fresh on every tab switch (the pattern above) tore
                    // all of that down and rebuilt it from scratch each
                    // time, which read as "the Dev page resets when I leave
                    // it." Keeping it permanently in the tree and only
                    // toggling opacity/hit-testing preserves its state for
                    // as long as the app runs, matching every other tab's
                    // actual persistence even though the mechanism here is
                    // different. It gets the same focus effect as `.pageSwap`
                    // so it moves like the other pages.
                    #if DEV_BUILD
                    if DevKeychain.isDevMachine {
                        // ActiveOnlyLayout keeps it mounted (state survives) but
                        // lays it out only while it's the active tab -- hidden,
                        // it used to be re-laid-out on every window-resize tick
                        // for nothing. The transaction override stops the layout
                        // change at activation from animating the page's size.
                        ActiveOnlyLayout(isActive: activeTab == .devRelease) {
                            DevReleaseView(dropDriver: dropDriver, isActive: activeTab == .devRelease)
                                .contentColumn()
                                .transaction(value: activeTab) { $0.animation = nil }
                        }
                            .modifier(FocusEffect(
                                blur: activeTab == .devRelease ? 0 : 4,
                                scale: activeTab == .devRelease ? 1 : 0.985,
                                opacity: activeTab == .devRelease ? 1 : 0,
                                anchor: .top
                            ))
                            .allowsHitTesting(activeTab == .devRelease)
                            .animation(.easeOut(duration: 0.2), value: activeTab)
                    }
                    #endif
                    }

                }
                .frame(maxWidth: .infinity)
                // The main column's own width (everything right of the
                // sidebar). Every tab's content column is derived from the space
                // it offers (ContentColumnLayout); this only feeds the breakpoint
                // class views compare against.
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear {
                                mainAreaWidth = geo.size.width
                                columnClass = WindowLayout.columnClass(mainWidth: geo.size.width)
                            }
                            .onChange(of: geo.size.width) { _, newWidth in
                                mainAreaWidth = newWidth
                                // Held while the sidebar's own width tween is dragging
                                // this through intermediate values
                                // (sidebarWidthAnimating); caught up when it lands.
                                if !sidebarWidthAnimating {
                                    let cls = WindowLayout.columnClass(mainWidth: newWidth)
                                    if cls != columnClass { columnClass = cls }
                                }
                            }
                    }
                )
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        windowSize = geo.size
                        settledWindowSize = geo.size
                        isNarrowWindow = geo.size.width > 0 && geo.size.width < WindowLayout.compactSidebarBreakpoint
                    }
                    .onChange(of: geo.size) { _, newSize in
                        windowSize = newSize
                        let narrow = newSize.width > 0 && newSize.width < WindowLayout.compactSidebarBreakpoint
                        if narrow != isNarrowWindow { isNarrowWindow = narrow }
                        if NSApp.keyWindow?.inLiveResize != true { settledWindowSize = newSize }
                    }
            }
        )
        .environment(\.contentColumnWidth, columnClass)
        .environment(\.isCompactSidebar, sidebarDisplayCompact)
        .environment(\.sidebarWidth, sidebarWidth)
        .onChange(of: isCompactSidebar) { _, compact in
            // Toggle sequence, per request: every row blurs/shrinks out AT
            // ONCE while the card visibly shrinks/grows; once the width lands
            // the new row set pops IN one by one, top-to-bottom. See
            // AnyTransition.dominoPop. While the width tweens, the main
            // content's breakpoints are held (sidebarWidthAnimating) and
            // catch up once, when it lands -- otherwise the bottom bar and
            // chip rows would flip between side-by-side and stacked on
            // every intermediate width.
            let target = compact ? WindowLayout.compactSidebarWidth : WindowLayout.sidebarWidth
            sidebarToggleGeneration += 1
            let generation = sidebarToggleGeneration
            // The toggle button and the window's width crossing
            // sidebarForcedCollapsed's threshold -- including mid-drag, live
            // -- get the same animated sequence. sidebarSequencePlaying
            // exempts it from the live-resize rule below that switches
            // animations off.
            sidebarWidthAnimating = true
            sidebarSequencePlaying = true
            if sidebarAnimationStyle == .resize {
                // Resize style: nothing leaves. The card's width tweens and
                // the tabs, icons and labels resize with it (SidebarTabItem
                // reads the animated width). The content that has to switch
                // layout -- labels, the tools block -- switches through its
                // own transitions: right away when collapsing, partway
                // through when expanding, so a label never shows up inside
                // a pill that's still too narrow for it.
                withAnimation(.easeInOut(duration: Self.sidebarResizeDuration)) { sidebarWidth = target }
                let flipDelay = compact ? 0 : Self.sidebarResizeDuration * 0.45
                DispatchQueue.main.asyncAfter(deadline: .now() + flipDelay) {
                    guard sidebarToggleGeneration == generation else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { sidebarDisplayCompact = compact }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.sidebarResizeDuration) {
                    guard sidebarToggleGeneration == generation else { return }
                    sidebarWidthAnimating = false
                    withAnimation(.easeOut(duration: 0.2)) { columnClass = WindowLayout.columnClass(mainWidth: mainAreaWidth) }
                }
                // After the last label/tools transition (a flip at most
                // 0.45 * duration in, plus its 0.2s) has finished.
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.sidebarResizeDuration + 0.25) {
                    if sidebarToggleGeneration == generation { sidebarSequencePlaying = false }
                }
                return
            }
            // Pop style. Both start together. The row exit's ambient
            // duration only needs to cover the (unstaggered) exit itself.
            withAnimation(.linear(duration: AnyTransition.dominoExitDuration)) { sidebarRowsHidden = true }
            withAnimation(.easeInOut(duration: Self.sidebarWidthDuration)) { sidebarWidth = target }
            // A second toggle landing mid-sequence supersedes both callbacks
            // below (the newer onChange owns sidebarWidth/sidebarRowsHidden),
            // hence the generation check in each.
            DispatchQueue.main.asyncAfter(deadline: .now() + AnyTransition.dominoExitDuration) {
                guard sidebarToggleGeneration == generation else { return }
                // Every row is gone by now, so it's safe for them to learn
                // the new mode -- see sidebarDisplayCompact's declaration.
                sidebarDisplayCompact = compact
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.sidebarWidthDuration) {
                guard sidebarToggleGeneration == generation else { return }
                // The width has landed: let the main content's breakpoints
                // catch up (once, gently), then start the reveal.
                sidebarWidthAnimating = false
                withAnimation(.easeOut(duration: 0.2)) { columnClass = WindowLayout.columnClass(mainWidth: mainAreaWidth) }
                // The ambient wrapper's OWN duration must span the full
                // staggered reveal, not just one row's animation -- each
                // row's transition bakes its own delay+curve (see
                // AnyTransition.dominoPop) which overrides this ambient one
                // for HOW it animates, but SwiftUI still uses the ambient
                // transaction's duration to decide WHEN an insertion is
                // "done". A short ambient duration cut every row past the
                // first couple off mid-delay, before their own animation ever
                // started.
                withAnimation(.linear(duration: Self.sidebarEnterTotal)) { sidebarRowsHidden = false }
                // The reveal is the last thing to play; once it has, animations
                // go back to being switched off for the rest of a live drag.
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.sidebarEnterTotal) {
                    if sidebarToggleGeneration == generation { sidebarSequencePlaying = false }
                }
            }
        }
        .environment(\.isCompactHeight, isCompactHeight)
        .environment(\.isTinyHeight, isTinyHeight)
        // While the user drags the window edge, layout should track their hand
        // exactly. Every breakpoint the drag crosses (compact sidebar, compact
        // height, a section appearing or disappearing) used to start its own
        // animation mid-drag, stacking GPU work on top of the per-frame relayout
        // and making resizing feel sluggish. Scoped to live resize only, so
        // every other animation in the app is unaffected -- and the sidebar's
        // own collapse/expand sequence is exempt (sidebarSequencePlaying), so
        // it plays live as the drag crosses its threshold.
        .transaction { t in
            if NSApp.keyWindow?.inLiveResize == true, !sidebarSequencePlaying {
                t.animation = nil
                t.disablesAnimations = true
            }
        }
        // Window-level drop target — drag a URL anywhere onto Drop
        .onDrop(of: ["public.url", "public.plain-text"], isTargeted: nil) { providers in
            handleDrop(providers: providers)
            return true
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // Mirrors the Download tab's own Paste & Analyze button exactly:
            // validate every line is a URL, insert pending placeholder cards
            // immediately for visual feedback, then kick off analysis — so
            // pasting from the menu bar behaves identically to pasting on
            // the Download page itself.
            // A live-resize drag just ended -- catch the settled breakpoint
            // snapshot up to wherever the raw geometry actually landed. See
            // settledWindowSize's declaration.
            NotificationCenter.default.addObserver(forName: .dropLiveResizeEnded, object: nil, queue: .main) { _ in
                settledWindowSize = windowSize
                columnClass = WindowLayout.columnClass(mainWidth: mainAreaWidth)
            }
            NotificationCenter.default.addObserver(forName: .menuBarDownload, object: nil, queue: .main) { note in
                guard let raw = note.userInfo?["url"] as? String else { return }
                let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !candidate.isEmpty, allLinesAreURLs(candidate) else { return }
                activeTab = .download
                // Deliberately NOT activating/foregrounding the app here --
                // the menu bar popover's whole point is a quick background
                // paste-and-queue without interrupting whatever the user is
                // doing (matches the popover's own "Queued — open Drop to
                // track progress" messaging, which implies you stay where
                // you are unless you tap "Open Drop" yourself).
                let pendingURLs = candidate.components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                // Capture each placeholder's own id (not just its url) so
                // duplicate-url pastes stay independent through analyze --
                // see analyzeProcesses' declaration for why.
                var pendingIDs: [UUID] = []
                withAnimation(.spring(response: 0.35)) {
                    for u in pendingURLs {
                        let placeholder = LinkPreview(
                            url: u, title: u, thumbnailURL: "",
                            hasVideo: false, duration: "",
                            mediaMode: .audioOnly, isPending: true
                        )
                        pendingIDs.append(placeholder.id)
                        linkPreviews.append(placeholder)
                    }
                }
                urlText = ""
                analyzeURL(urls: pendingURLs, ids: pendingIDs)
            }
        }
        // Cmd+Shift+V: paste clipboard and download immediately
        .background(
            Button("") {
                if let s = NSPasteboard.general.string(forType: .string) {
                    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    urlText = trimmed
                    download()
                }
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .hidden()
        )
        // Escape: clear URL field -- removed from the view hierarchy
        // entirely (not merely .disabled) while the update overlay has a
        // card on screen. .disabled(_:) does NOT make a keyboard shortcut
        // inert the way it sounds like it should -- confirmed on-device
        // (via the Dev tab's overlay previews, using Escape specifically):
        // a disabled button can still consume an ambiguous shortcut before
        // an enabled one gets a chance, so with just .disabled() here,
        // this button and the overlay's own Escape-to-dismiss
        // (DropUpdateOverlayView.escapeCatcher) competed for the same
        // keypress and this one silently won every time, leaving every
        // overlay preview un-Escape-dismissable. An `if` inside the
        // ViewBuilder background block actually excludes this button from
        // the hierarchy while a card is up, so there's only ever one
        // Escape-bound button to route to.
        .background {
            if !dropDriver.isPresentingCard {
                Button("") { urlText = "" }
                    .keyboardShortcut(.escape, modifiers: [])
                    .hidden()
            }
        }
        // Drop's own update UI -- attached at the root so it can appear
        // over any tab, not just while Dev happens to be open, since an
        // update can be found at any time.
        .overlay(DropUpdateOverlayView(driver: dropDriver))

    }

    // MARK: - Sidebar

    /// Vertical nav rail. Layout borrows the Perplexity Mac app's plain-row
    /// convention (no divider/border, quiet spacing-based separation,
    /// small icons inline with text) but the rail itself is now an actual
    /// floating GlassCard -- same recipe (blur + black tint + grain + rim
    /// stroke) and corner radius as every other card in the app, with a
    /// margin from the window edges so it visually floats rather than
    /// sitting as a flush edge-to-edge panel. Same three destinations and
    /// the same Tools pill / log toggle controls as the old horizontal tab
    /// bar, just re-flowed top-to-bottom.
    /// Header: the collapse/expand toggle lives in a slot exactly as wide as
    /// the collapsed rail, at the card's leading edge, so it sits in the same
    /// spot whether the sidebar is open or closed. Open, the logo and "Drop"
    /// sit beside it; closed there's nothing else on the row, so it never
    /// crowds the narrow rail. While the window is too narrow to expand at all
    /// the toggle has no job, so the logo takes its slot instead.
    private var sidebarToggleSlot: some View {
        ZStack {
            if sidebarForcedCollapsed {
                sidebarLogo
            } else {
                HoverIconButton(
                    icon: "sidebar.left", size: 13,
                    help: isCompactSidebar ? "Expand sidebar" : "Collapse sidebar"
                ) {
                    sidebarCollapsedByUser.toggle()
                }
                .accessibilityLabel(isCompactSidebar ? "Expand sidebar" : "Collapse sidebar")
            }
        }
        .frame(width: WindowLayout.compactSidebarWidth)
    }

    private var sidebarLogo: some View {
        Image(systemName: "arrow.down.circle.fill")
            .font(.appMono(size: 14, weight: .semibold))
            .foregroundColor(DesignTokens.Accent.primary)
    }

    private var sidebarLabel: some View {
        HStack(spacing: 7) {
            sidebarLogo
            Text("Drop")
                .font(.appMono(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(DesignTokens.Text.primary))
        }
    }

    var sidebar: some View {
        VStack(spacing: 0) {
            // Header is two independent reveal steps: the toggle slot is
            // index 0 (leftmost, so it leads), the label (icon + "Drop", open
            // only) is index 1 -- each in its OWN `if !sidebarRowsHidden`
            // so SwiftUI tracks them as separate insertions/removals (see
            // the note on the nav items below for why shared conditionals
            // don't stagger). The label follows sidebarDisplayCompact, which
            // only changes while every row is hidden.
            HStack(spacing: 0) {
                if !sidebarRowsHidden {
                    sidebarToggleSlot
                        .transition(.dominoPop(index: 0))
                }
                if !sidebarRowsHidden, !sidebarDisplayCompact {
                    sidebarLabel
                        .padding(.leading, -8)
                        .transition(sidebarAnimationStyle == .resize ? AnyTransition.blurInLeading : AnyTransition.dominoPop(index: 1))
                }
                Spacer(minLength: 0)
            }
            .frame(height: 27)
            .padding(.top, isTinyHeight ? 8 : 16)
            .padding(.bottom, isTinyHeight ? 6 : 18)

            // Nav items — larger touch targets (bumped padding/font inside
            // SidebarTabItem itself) with real breathing room between rows,
            // instead of the previous near-zero 2pt gap. Each row is its own
            // domino step (index 2-6), and critically each gets its OWN
            // independent `if !sidebarRowsHidden { ... }` rather than sharing
            // one `if` around the whole VStack -- when several sibling views
            // shared a single conditional, SwiftUI treated that whole block
            // as ONE unit entering/leaving, and did not reliably apply each
            // child's own individually-delayed `.transition()` to its own
            // removal/insertion. An unconditionally-present VStack containing
            // several independently-gated children is the pattern SwiftUI's
            // transition system unambiguously honors per-view (same pattern
            // the header above and ToolsStatusPill below also use).
            VStack(spacing: 6) {
                if !sidebarRowsHidden {
                SidebarTabItem(label: "Download", icon: "arrow.down.circle", isSelected: activeTab == .download,
                        badge: linkPreviews.isEmpty ? nil : "\(linkPreviews.count)") {
                    withAnimation(.spring(response: 0.25)) { activeTab = .download }
                }
                .accessibilityIdentifier("tab_download")
                .transition(.dominoPop(index: 2))
                }
                if !sidebarRowsHidden {
                SidebarTabItem(label: "Convert", icon: "arrow.triangle.2.circlepath", isSelected: activeTab == .convert,
                        badge: convertQueue.isEmpty ? nil : "\(convertQueue.count)") {
                    withAnimation(.spring(response: 0.25)) { activeTab = .convert }
                }
                .accessibilityIdentifier("tab_convert")
                .transition(.dominoPop(index: 3))
                }
                if !sidebarRowsHidden {
                SidebarTabItem(label: "History", icon: "clock",
                        isSelected: activeTab == .history,
                        badge: manager.history.entries.isEmpty ? nil : "\(manager.history.entries.count)") {
                    withAnimation(.spring(response: 0.25)) { activeTab = .history }
                }
                .accessibilityIdentifier("tab_history")
                .transition(.dominoPop(index: 4))
                }
                if !sidebarRowsHidden {
                SidebarTabItem(label: "Log", icon: "terminal", isSelected: activeTab == .log) {
                    withAnimation(.spring(response: 0.25)) { activeTab = .log }
                }
                .accessibilityIdentifier("tab_log")
                .transition(.dominoPop(index: 5))
                }
                // Present only on a machine holding the Sparkle signing key
                // and GitHub token -- see DevKeychain.isDevMachine. On any
                // other machine this row, and everything behind it, simply
                // doesn't exist; that absence is the entire access control.
                // Guarded by DEV_BUILD (see Config/Base.xcconfig) on top of
                // that check: the public repo doesn't even compile
                // DevKeychain/DevReleaseView in at all, so this couldn't
                // reference them regardless.
                #if DEV_BUILD
                if !sidebarRowsHidden, DevKeychain.isDevMachine {
                    SidebarTabItem(label: "Dev", icon: "wrench.and.screwdriver", isSelected: activeTab == .devRelease) {
                        withAnimation(.spring(response: 0.25)) { activeTab = .devRelease }
                    }
                    .accessibilityIdentifier("tab_dev")
                    .transition(.dominoPop(index: 6))
                }
                // DEBUG only (never in the Release build that ships to users,
                // where the Dev tab's absence is the access control): a Debug
                // build that can't reach the keychain items -- the prompt was
                // denied, or a new build's signature was never approved --
                // otherwise just silently has no Dev tab for the whole session.
                #if DEBUG
                if !sidebarRowsHidden, !DevKeychain.isDevMachine {
                    SidebarTabItem(label: "Dev (locked)", icon: "lock", isSelected: false) {}
                        .opacity(0.4)
                        .help("Keychain access to the Sparkle signing key / GitHub token was denied or is missing. Relaunch and choose Always Allow.")
                        .accessibilityIdentifier("tab_dev_locked")
                        .transition(.dominoPop(index: 6))
                }
                #endif
                #endif
            }
            .padding(.horizontal, 8)

            Spacer()

            // Tools section -- integrated directly into the rail as an
            // always-visible block (no popover, no toggle), pinned to
            // the bottom via the Spacer() above. Continues the domino from
            // index 7 -- its OWN rows (yt-dlp/ffmpeg/Drop/Check for Updates)
            // are each a separate step (see baseIndex), rather than this whole
            // block popping as one piece. The block is ONE set of views at
            // every sidebar width (its icons sit on the rail exactly where
            // the tab icons do; the text appears beside them as the card
            // widens), so opening the sidebar widens it in place. It's
            // inset by the same railContentInset as the nav pills so the two
            // line up. Passed through as rowsHidden rather than gated with an
            // outer `if !sidebarRowsHidden` here -- gating the WHOLE pill from
            // outside would remove all of its rows in one shot, and even
            // per-row removal changes this bottom-pinned block's height,
            // sliding it; ToolsStatusPill instead keeps every row mounted and
            // shrinks/blurs each one in place (see DominoVisibility).
            ToolsStatusPill(manager: manager, baseIndex: 7, rowsHidden: sidebarRowsHidden)
                .padding(.horizontal, WindowLayout.railContentInset)
                .padding(.bottom, isTinyHeight ? 8 : 16)
        }
        // maxHeight: .infinity guards against the card collapsing to the lone
        // Spacer's zero intrinsic height during the brief window where every
        // row is hidden mid-domino (header/nav/tools all conditionally gone)
        // -- keeps the card's HEIGHT stable throughout, so only its width
        // ever visibly changes.
        .frame(width: sidebarWidth)
        .frame(maxHeight: .infinity)
        // Real floating card -- identical material/radius/rim-stroke
        // recipe as every other GlassCard in the app (VisualEffectBlur +
        // black tint + grain + gradient rim stroke), not a bespoke
        // one-off background.
        .glassCard(cornerRadius: DesignTokens.Radius.large)
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 12)
    }

    // MARK: - Main Panel

    var mainPanel: some View {
        VStack(spacing: 12) {
            // Input area — the paste field and Paste & Analyze button
            // share one seamless pill bar (built inside urlCard itself), so
            // no outer card wrapper is needed here.
            urlCard
                .shadow(color: .black.opacity(DesignTokens.Interactive.glowShadowPeak), radius: 10, y: 4)
                // Clearly more breathing room above the drop zone (top of
                // window) and below it (before the toolbar/list header
                // row). Previous +14/+8 bump read as barely-there at this
                // window scale, so these are large, deliberate increases --
                // the extra bottom padding stacks with the VStack's own
                // 12pt spacing so this gap grows without also widening the
                // toolbar-to-scroll-area gap beneath it. Tighter in a short
                // window, where the card list needs every point.
                .padding(.top, isCompactHeight ? 26 : 40)
                .padding(.bottom, isCompactHeight ? 12 : 20)

            if isTinyHeight {
                // Too short for pinned chrome AND a card list: everything under
                // the paste bar scrolls together, so the list header, the cards
                // and the bottom bar are all still reachable and fully legible.
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: true) {
                        VStack(spacing: 12) {
                            mainPanelToolbar
                            mainPanelCardsContent
                            if linkPreviews.isEmpty {
                                EmptyStateView(
                                    icon: "arrow.down.to.line",
                                    title: "Paste a link to get started",
                                    subtitle: "Supports YouTube, SoundCloud, Vimeo and more"
                                )
                                .padding(.vertical, 16)
                            }
                            mainPanelBottomBar
                        }
                    }
                    .onChange(of: linkPreviews.count) {
                        withAnimation(.spring(response: 0.4)) {
                            proxy.scrollTo("scrollBottom", anchor: .bottom)
                        }
                    }
                }
            } else {
                mainPanelToolbar
                mainPanelCardsScroll
                mainPanelBottomBar
            }
        }
    }

    // MARK: Main panel pieces (composed pinned or all-scrolling -- see mainPanel)

    @ViewBuilder
    private var mainPanelToolbar: some View {
            // ── List header — Select/Done + Select All/Deselect All on the
            // left, Clear All on the right. Mirrors Convert's header exactly.
            // Floats as its own bubble card, separate from the input area.
            if hasAnyLinkItems {
                HStack {
                    GlassButton(
                        label: isBatchMode ? "Done" : "Select",
                        icon: isBatchMode ? "xmark.circle" : "checkmark.circle",
                        tint: DesignTokens.Accent.primary,
                        fitContent: true
                    ) {
                        withAnimation(.spring(response: 0.25)) {
                            isBatchMode.toggle()
                            // Select mode always starts unchecked so checkmarks
                            // never carry over stale state. Exiting Select mode
                            // resets every item back to fully included, since
                            // outside Select mode checkboxes are hidden and
                            // nothing should be silently excluded.
                            for i in linkPreviews.indices { linkPreviews[i].isSelected = !isBatchMode }
                        }
                    }
                    if isBatchMode {
                        GlassButton(
                            label: allEligibleLinksSelected ? "Deselect All" : "Select All",
                            icon: allEligibleLinksSelected ? "circle" : "checkmark.circle",
                            tint: .white,
                            fitContent: true
                        ) {
                            withAnimation(.spring(response: 0.25)) {
                                toggleSelectAllLinks()
                            }
                        }
                    }
                    Spacer()
                    // Hidden (not just disabled) while any card is still
                    // analyzing -- pending cards have no collapse state yet,
                    // so the button has nothing meaningful to do until the
                    // whole queue has resolved.
                    if !anyLinksStillAnalyzing {
                        GlassButton(
                            label: allLinksCollapsed ? "Expand All" : "Collapse All",
                            icon: allLinksCollapsed ? "chevron.down" : "chevron.up",
                            tint: .white,
                            fitContent: true,
                            disabled: !hasExpandableLinks
                        ) {
                            withAnimation(.easeOut(duration: 0.22)) {
                                toggleCollapseAllLinks()
                            }
                        }
                    }
                    GlassButton(
                        label: isBatchMode ? "Clear Selected" : "Clear All",
                        icon: "trash",
                        tint: .red,
                        fitContent: true,
                        disabled: isBatchMode && !linkPreviews.contains { $0.isSelected }
                    ) {
                        withAnimation(.spring(response: 0.3)) {
                            // Only terminate processes belonging to the cards
                            // actually being cleared -- this used to terminate
                            // every in-flight analyze process unconditionally,
                            // so "Clear Selected" in batch mode (or clearing one
                            // duplicate among several) also silently killed
                            // every OTHER still-analyzing card's process even
                            // though only some cards were meant to be cleared.
                            let idsBeingCleared: Set<UUID> = isBatchMode
                                ? Set(linkPreviews.filter { $0.isSelected }.map { $0.id })
                                : Set(linkPreviews.map { $0.id })
                            for id in idsBeingCleared {
                                if let proc = analyzeProcesses[id] {
                                    DownloadManager.terminateProcessTree(proc)
                                    analyzeProcesses.removeValue(forKey: id)
                                    manager.appendLog("Analyze cancelled: \(id)")
                                }
                            }
                            if isBatchMode {
                                // Also mark any still-pending, still-queued
                                // (behind the analyze concurrency gate) cards
                                // being cleared as cancelled -- they have no
                                // Process yet to terminate above, but without
                                // this they'd still silently analyze and
                                // reappear even though the user just cleared them.
                                for p in linkPreviews where p.isSelected && p.isPending {
                                    cancelledAnalyzeIDs.insert(p.id)
                                }
                                for p in linkPreviews where p.isSelected {
                                    if let did = p.downloadID, let dl = manager.downloads.first(where: { $0.id == did }) {
                                        // Cancel before removing -- deleting the Download
                                        // object out from under an active process orphaned
                                        // it headless with no reference left to ever kill it.
                                        if dl.status == .downloading { manager.cancel(download: dl) }
                                        manager.downloads.removeAll { $0.id == did }
                                    }
                                }
                                linkPreviews.removeAll { $0.isSelected }
                            } else {
                                for p in linkPreviews where p.isPending {
                                    cancelledAnalyzeIDs.insert(p.id)
                                }
                                for p in linkPreviews {
                                    if let did = p.downloadID, let dl = manager.downloads.first(where: { $0.id == did }) {
                                        if dl.status == .downloading { manager.cancel(download: dl) }
                                        manager.downloads.removeAll { $0.id == did }
                                    }
                                }
                                linkPreviews.removeAll()
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .glassCard(cornerRadius: DesignTokens.Radius.xlarge)
                .shadow(color: .black.opacity(DesignTokens.Interactive.glowShadowPeak), radius: 10, y: 4)
                // Same shared content column as the paste bar, the card queue
                // below and the bottom bar (see WindowLayout.columnWidth), so
                // every row in this tab is pixel-identical in width.
                .contentColumn()
                .transition(.glassBar(anchor: .top))
            }

    }

    @ViewBuilder
    private var mainPanelCardsContent: some View {
                    LazyVStack(spacing: 12) {
                        // Bundled tools missing banner — should only ever appear if the
                        // app bundle itself is corrupt/incomplete, since yt-dlp and
                        // ffmpeg ship inside Drop.app rather than being installed.
                        if !manager.checkingDeps && !manager.toolsReady {
                            HStack(spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                    .font(.appMono(size: 16))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Bundled tools missing")
                                        .font(.appMono(size: 13, weight: .semibold))
                                        .foregroundColor(.white.opacity(DesignTokens.Text.primary))
                                    Text("yt-dlp/ffmpeg weren't found inside the app bundle. Please reinstall Drop.")
                                        .font(.appMono(size: 11))
                                        .foregroundColor(.white.opacity(DesignTokens.Text.secondary))
                                }
                                Spacer()
                            }
                            .padding(14)
                            .glassCard(cornerRadius: DesignTokens.Radius.medium)
                        }

                        previewCard

                        Color.clear.frame(height: 4).id("scrollBottom")
                    }
                    // Same content column as the paste bar, list header and
                    // bottom bar, so every card in the queue lines up with them.
                    // One measured number (see WindowLayout) rather than a
                    // containerRelativeFrame, which resolves against the
                    // NEAREST container -- and this VStack sits inside a
                    // ScrollView, which has its own.
                    .contentColumn()
                    .padding(.top, 20)
                    .padding(.bottom, 8)
    }

    @ViewBuilder
    private var mainPanelCardsScroll: some View {
            // ── Scrollable cards area ────────────────────────────────
            // LazyVStack instead of VStack: a plain VStack forces every
            // card's full view tree (blur material, animated rim glow,
            // async thumbnail) to build and render simultaneously
            // regardless of scroll position, which is what caused the
            // scroll lag/stutter as the queue grew. LazyVStack only
            // renders rows near the visible viewport -- same visuals,
            // no eager off-screen rendering cost. ScrollViewReader's
            // .scrollTo still works identically with LazyVStack.
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: true) {
                    mainPanelCardsContent
                }
                // Fade scrolled cards out near the top edge instead of a hard
                // clip against the frosted header above.
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.035),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .onChange(of: linkPreviews.count) {
                    withAnimation(.spring(response: 0.4)) {
                        proxy.scrollTo("scrollBottom", anchor: .bottom)
                    }
                }
                // Empty state — overlaid and truly centered in the scroll area
                .overlay {
                    if linkPreviews.isEmpty {
                        EmptyStateView(
                            icon: "arrow.down.to.line",
                            title: "Paste a link to get started",
                            subtitle: "Supports YouTube, SoundCloud, Vimeo and more"
                        )
                        .transition(.blurIn)
                    }
                }
                .animation(.easeOut(duration: 0.25), value: linkPreviews.isEmpty)
            }

    }

    @ViewBuilder
    private var mainPanelBottomBar: some View {
            // ── Pinned bottom bar ─────────────────────────────────────
            TabBottomBar(
                    config: config,
                    hasItems: linkPreviews.contains(where: { !$0.isPending }),
                    showPrimaryAction: selectedPreviews.contains { $0.downloadID == nil },
                    toolsReady: readyToDownload,
                    // Blocks Download until every link currently in the
                    // queue has finished analyzing (isPending == false),
                    // not just the selected ones -- a still-analyzing card
                    // doesn't have real format/title data yet, and starting
                    // a run while one is mid-flight raced ahead of it
                    // instead of waiting the way the button visually implies
                    // it should. Checked against the WHOLE queue rather than
                    // just selectedPreviews since an in-flight card could be
                    // selected the moment it resolves -- the queue as a
                    // whole needs to settle first.
                    primaryActionEnabled: !linkPreviews.contains(where: { $0.isPending }),
                    primaryActionDisabledLabel: linkPreviews.contains(where: { $0.isPending }) ? "Analyzing…" : nil,
                    primaryActionDisabledIcon: linkPreviews.contains(where: { $0.isPending }) ? "hourglass" : nil,
                    primaryActionInProgress: manager.downloads.contains { $0.status == .downloading },
                    primaryActionLabel: downloadButton_label,
                    primaryActionIcon: "arrow.down.circle",
                    onClearAll: {},
                    onPrimaryAction: { download() },
                    showClearAll: false,
                    hasBatchDirectoryControl: true
                ) {
                    // leftControls: none — cookie source is now resolved automatically on failure
                    EmptyView()
                } extraControls: {
                    EmptyView()  // extraControls: unused now that SAVE TO lives in batchDirectoryControl
            } batchDirectoryControl: {
                // SAVE TO — now rendered in the same top row as the Auto-Open
                // Folder toggle, always visible (matching Convert's Select-mode
                // layout, but permanent here since Download has only one
                // destination). Fills the remaining bar width.
                VStack(alignment: .leading, spacing: DropGrid.labelSpacing) {
                    // In a short window the label row (and the total-size chip
                    // on it) is dropped to give the card list the room -- the
                    // folder field below says the same thing, and the total
                    // moves into its tooltip.
                    if !isCompactHeight {
                    HStack(spacing: DropGrid.labelSpacing) {
                        Image(systemName: "folder")
                            .font(.appMono(size: DropGrid.microLabelSize, weight: .semibold))
                            .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                            .frame(width: 14, alignment: .center)
                        Text("SAVE TO")
                            .font(.appMono(size: DropGrid.microLabelSize, weight: .semibold))
                            .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                        if let sizeLabel = totalEstimatedSizeLabel {
                            Spacer()
                            HStack(spacing: 4) {
                                Image(systemName: "internaldrive")
                                    .font(.appMono(size: 9))
                                Text(sizeLabel)
                                    .font(.appMono(size: 10, weight: .semibold))
                            }
                            .foregroundColor(.white.opacity(DesignTokens.Text.secondary))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(DesignTokens.Interactive.fillRest))
                            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous))
                        }
                    }
                    }
                    HStack(spacing: DropGrid.rowSpacing) {
                        HStack(spacing: DropGrid.rowSpacing) {
                            Image(systemName: "folder.fill")
                                .foregroundColor(.white.opacity(DesignTokens.Text.secondary))
                                .font(.appMono(size: DropGrid.fieldFontSize))
                            TextField("", text: $config.outputDir)
                                .textFieldStyle(.plain)
                                .font(.appMono(size: DropGrid.fieldFontSize))
                                .foregroundColor(.white.opacity(DesignTokens.Text.secondary))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: DropGrid.controlHeight)
                        .padding(.horizontal, 8)
                        .background(Color.white.opacity(DropGrid.fieldFillOpacity))
                        .clipShape(RoundedRectangle(cornerRadius: DropGrid.fieldCorner, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: DropGrid.fieldCorner, style: .continuous)
                            .stroke(Color.white.opacity(DropGrid.fieldBorderOpacity), lineWidth: DropGrid.fieldBorderWidth))
                        .help(isCompactHeight ? "Save to this folder" + (totalEstimatedSizeLabel.map { " · est. \($0)" } ?? "") : "")

                        GlassButton(label: "Browse", icon: "folder", tint: DesignTokens.Accent.primary, verticalPadding: 4, fillHeight: true) {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            panel.canCreateDirectories = true
                            panel.allowsMultipleSelection = false
                            panel.prompt = "Select"
                            if panel.runModal() == .OK, let url = panel.url {
                                config.outputDir = url.path
                            }
                        }
                        .frame(width: DropGrid.buttonColumnWidth, height: DropGrid.controlHeight)
                        // Always-available Reveal -- same control Convert's
                        // SAVE TO field has, opening the shared output
                        // directory in Finder any time, not tied to any
                        // single download.
                        HoverIconButton(icon: "arrow.up.forward.app", size: 13, help: "Open the SAVE TO folder in Finder") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: config.outputDir))
                        }
                        .frame(height: DropGrid.controlHeight)
                    }
                }
                .frame(maxWidth: .infinity)
                // Card within a card -- same nested-glass treatment as
                // Convert's Queue drawer, so both tabs' bottom-bar sections
                // read as one shared system even though what's inside differs.
                .padding(10)
                .glassCard(cornerRadius: DesignTokens.Radius.medium, opacity: 0.35)
            }
    }

    // MARK: - URL Card

    // Extracted out of urlCard's body -- inlining this GlassButton call
    // (with its tuple literal, closure, and multiple chained modifiers)
    // directly inside urlCard's giant view-builder tree made the whole
    // expression too complex for the type-checker to solve in reasonable
    // time (build failure at the unrelated Text("Paste a link…") line).
    // Giving it its own @ViewBuilder function isolates it as a separate
    // expression the compiler can type-check independently.
    @ViewBuilder
    private func pasteAnalyzeButton(label: String, icon: String, tint: Color, isRetry: Bool, innerPillHeight: CGFloat) -> some View {
        // Hover/press fill kept flat at the same level as rest -- per
        // user request this pill should NOT wash in extra color or grow
        // on hover, it should just gain a glow outline while the center
        // keeps reading as plain black glass.
        let fillOverride: (rest: Double, active: Double, hover: Double, press: Double) = (rest: 0.12, active: 0.12, hover: 0.12, press: 0.12)
        GlassButton(
            label: label,
            icon: icon,
            tint: tint,
            // Extra horizontal breathing room around the icon/label since
            // this pill nearly fills the outer bar's height and needs more
            // inset than the default 10pt to avoid feeling cramped.
            horizontalPadding: 16,
            // fillHeight: true -- makes the button's content (and
            // therefore its capsule background) actually stretch to
            // match the .frame(height: innerPillHeight) applied below,
            // instead of hugging the label/icon's natural size and
            // floating centered with visible gaps top/bottom.
            fillHeight: true,
            fitContent: true,
            isLoading: false,
            embedded: true,
            activeFillOverride: fillOverride,
            // Re-enable the glow-ring stroke even though embedded (see
            // GlassInteractive), and freeze scale at 1.0 so the pill
            // doesn't grow/shrink on hover/press -- only the outline glows.
            embeddedGlowStroke: true,
            scaleOverride: (hover: 1.0, press: 1.0)
        ) {
            if !isRetry {
                if let s = NSPasteboard.general.string(forType: .string) {
                    let candidate = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Check the clipboard candidate against the queue
                    // BEFORE committing it into urlText -- committing first
                    // and only bailing out afterward (previous approach)
                    // left the duplicate link sitting in the field with no
                    // further watcher to clean it up, so cancelling/
                    // clearing that same card later left urlText stale and
                    // it could resurface as a confusing "Invalid" state on
                    // the next unrelated interaction. Detecting first means
                    // urlText is simply never touched for a pure duplicate
                    // paste -- only the pill flashes "Already Analyzed"
                    // for a moment, nothing lingers in the field to go stale.
                    let candidateURLs = candidate.components(separatedBy: "\n")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    let existingURLs = Set(linkPreviews.map { $0.url })
                    let isPureDuplicate = !candidateURLs.isEmpty
                        && allLinesAreURLs(candidate)
                        && candidateURLs.allSatisfy { existingURLs.contains($0) }
                    if isPureDuplicate {
                        duplicateURLDetected = true
                        // Auto-clears so the pill returns to its normal
                        // "Paste & Analyze" label/icon/tint after a beat --
                        // this is a momentary confirmation, not a
                        // persistent error state like Invalid.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                            duplicateURLDetected = false
                        }
                        return
                    }
                    urlText = candidate
                    analyzeResult = nil
                    duplicateURLDetected = false
                    hasInvalidURLs = !allLinesAreURLs(urlText)
                }
                if !urlText.trimmingCharacters(in: .whitespaces).isEmpty && allLinesAreURLs(urlText) {
                    // Insert pending placeholder cards immediately
                    let pendingURLs = urlText.components(separatedBy: "\n")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    // Capture each placeholder's own id (not just its url) so
                    // duplicate-url pastes stay independent through analyze --
                    // see analyzeProcesses' declaration for why.
                    var pendingIDs: [UUID] = []
                    withAnimation(.spring(response: 0.35)) {
                        for u in pendingURLs {
                            let placeholder = LinkPreview(
                                url: u, title: u, thumbnailURL: "",
                                hasVideo: false, duration: "",
                                mediaMode: .audioOnly, isPending: true
                            )
                            pendingIDs.append(placeholder.id)
                            linkPreviews.append(placeholder)
                        }
                    }
                    urlText = ""  // clear field once cards are queued
                    analyzeURL(urls: pendingURLs, ids: pendingIDs)
                }
            }
        }
        .frame(height: innerPillHeight)
        .padding(.trailing, 5)
        // Deliberately NOT gated on isAnalyzing (see comment at call site)
        // -- only a genuine retry/invalid state or a missing yt-dlp/ffmpeg
        // setup should ever block this button.
        .disabled(isRetry || !readyToDownload)
        .opacity((isRetry || !readyToDownload) ? 0.5 : 1.0)
        .help(readyToDownload ? "" : "Install yt-dlp and ffmpeg from the Tools menu first")
    }

    var urlCard: some View {
        // Taller bar so the field reads more substantial, and the Analyze
        // control is now an accent-filled pill INSET inside this same
        // capsule (Spotlight/Arc-style embedded action) rather than a
        // second independent GlassButton sitting beside it -- the old
        // layout had two adjacent capsules (field + button, each with
        // their own glass fill/stroke) which read as a visible seam/
        // "pill next to a pill" instead of one continuous field.
        let fieldHeight: CGFloat = 52
        // 2pt margin top/bottom -- the pill should nearly fill the bar's
        // full height, not float as a shorter capsule centered inside a
        // taller frame. Pairs with fillHeight: true below, which is what
        // actually makes the capsule's own background stretch to this
        // height instead of just hugging its label/icon content size.
        let innerPillHeight: CGFloat = fieldHeight - 10

        // spacing: 0 -- the field and the embedded pill must sit flush
        // against each other with zero gap so this reads as one
        // continuous bar. The pill's own fill/edge provides the visual
        // separation; whitespace here would reintroduce the seam.
        return HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                // Left-aligned instead of centered -- centering put the
                // typing cursor directly on top of the "Paste a link…"
                // placeholder when the field was empty and focused, and
                // made the text baseline harder to line up cleanly with
                // the clear button's vertical center. Leading alignment is
                // also the standard convention for URL/paste fields.
                if urlText.isEmpty {
                    Text("Paste a link…")
                        .font(.appMono(size: 13))
                        .foregroundColor(.white.opacity(0.18))
                        .allowsHitTesting(false)
                        .frame(height: fieldHeight, alignment: .center)
                        .padding(.leading, 14)
                }
                TextField("", text: $urlText)
                    .textFieldStyle(.plain)
                    .font(.appMono(size: 13))
                    .multilineTextAlignment(.leading)
                    .foregroundColor(.white)
                    .tint(.white)
                    // A URL-paste field has no legitimate use for spell-
                    // check/autocorrect/predictive-text.
                    .autocorrectionDisabled()
                    // The actual fix for a real, confirmed bug (root-caused
                    // via a runtime diagnostic that logged every NSWindow
                    // AppKit created/showed during launch): this field
                    // becoming first responder made macOS briefly show its
                    // system Password AutoFill suggestion window -- an
                    // empty, undecorated, cross-process (NSRemoteView)
                    // popover anchored right under the field -- because
                    // nothing told AppKit this ISN'T a username/password
                    // field. It appeared for a single frame (~30ms) then
                    // self-dismissed once AutoFill found no matching saved
                    // credentials. Two earlier theories (a system text-
                    // completion candidate popover; a window-restoration
                    // snapshot) were tried and shipped before this was
                    // root-caused -- both harmless to also keep, but
                    // neither was the actual cause. Explicitly hinting
                    // .URL content type stops AppKit from ever attempting
                    // the AutoFill suggestion for this field at all.
                    .textContentType(.URL)
                    .focused($urlFieldFocused)
                    .frame(height: fieldHeight, alignment: .center)
                    .padding(.leading, 14)
                    // Leave room on the trailing edge for the clear button so
                    // typed/pasted text never sits underneath it.
                    .padding(.trailing, urlText.isEmpty ? 14 : 36)
                    .onDrop(of: ["public.url", "public.plain-text"], isTargeted: $isDragging) { providers in
                        self.handleDrop(providers: providers)
                        return true
                    }

                if !urlText.isEmpty {
                    // Migrated onto the shared GlassInteractive base so the
                    // clear button gets real hover/press glow feedback
                    // instead of sitting there inert. Explicit .center
                    // frame alignment keeps it vertically lined up with
                    // the text field's own center regardless of font
                    // metrics/line-height quirks.
                    HStack {
                        Spacer()
                        GlassInteractive(shape: .circle, tint: .red, action: {
                            urlText = ""
                            analyzeResult = nil
                            duplicateURLDetected = false
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.appMono(size: 15))
                                .padding(4)
                        }
                        .padding(.trailing, 8)
                    }
                    .frame(height: fieldHeight, alignment: .center)
                }
            }
            .frame(maxWidth: .infinity)

            // Paste & Analyze / Retry -- inset accent pill living INSIDE
            // the outer field capsule (not a second independent capsule).
            let _isEmpty  = urlText.trimmingCharacters(in: .whitespaces).isEmpty
            let _isFailed = analyzeResult == .unknown
            let _isRetry  = _isFailed && !_isEmpty
            // Duplicate is NOT folded into isRetry -- isRetry also disables
            // the button and blocks the tap handler's own
            // paste-from-clipboard step (see pasteAnalyzeButton's `if
            // !isRetry`), and a duplicate hit should still let the user
            // paste something else right away rather than locking the
            // control the way a genuinely invalid clipboard value does.
            // Not gated on !_isEmpty -- urlText is deliberately left
            // untouched (usually empty) when a pure duplicate is detected,
            // so this flag has to stand on its own rather than depending
            // on the field actually holding text.
            let _isDuplicate = duplicateURLDetected && !_isRetry
            // No longer gated on isAnalyzing -- the button stays fully
            // interactive while a previous paste's analyze is still in
            // flight, so pasting/submitting the next link never has to
            // wait on the last one to finish. isAnalyzing still exists for
            // the underlying pipeline's own per-batch bookkeeping, it's
            // just no longer surfaced on this control.
            let _pasteLabel: String = !readyToDownload ? "Setup Needed" : (_isRetry ? "Invalid" : (_isDuplicate ? "Already Analyzed" : "Paste & Analyze"))
            let _pasteIcon: String  = !readyToDownload ? "lock.fill" : (_isRetry ? "exclamationmark.triangle" : (_isDuplicate ? "checkmark.circle" : "doc.on.clipboard"))
            // Back to black/white per request -- keep red only for the
            // actual invalid/retry error state. Duplicate uses the same
            // amber/orange the app already reserves for "needs attention
            // but not an error" (see AnalyzeResult.unknown's orange vs.
            // the red danger tint used for genuine invalid input).
            let _pasteTint: Color   = !readyToDownload ? Color.white.opacity(DesignTokens.Text.secondary) : (_isRetry ? DesignTokens.Accent.danger : (_isDuplicate ? Color.orange.opacity(0.8) : Color.white))
            pasteAnalyzeButton(
                label: _pasteLabel,
                icon: _pasteIcon,
                tint: _pasteTint,
                isRetry: _isRetry,
                innerPillHeight: innerPillHeight
            )
        }
        .frame(height: fieldHeight)
        .background(
            // Same black-frosted-glass material as every card and the
            // sidebar (VisualEffectBlur + black tint + white wash + grain),
            // just clipped to a Capsule instead of GlassCard's
            // RoundedRectangle -- the field used to be a flat
            // Color.white.opacity(0.05) fill, a visibly different/lighter
            // material than the rest of the app's glass surfaces.
            ZStack {
                VisualEffectBlur(material: DesignTokens.Glass.material, blendingMode: .behindWindow)
                Color.black.opacity(isDragging ? DesignTokens.Glass.blackTintDisabled : DesignTokens.Glass.blackTint)
                Color.white.opacity(0.55 * DesignTokens.Glass.whiteWash)
                DitherNoise(opacity: 0.04)
            }
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(isDragging ? Color.white.opacity(DesignTokens.Text.secondary) : Color.white.opacity(DropGrid.fieldBorderOpacity), lineWidth: isDragging ? 1.5 : DropGrid.fieldBorderWidth)
            )
        )
        // Waiting-for-paste cue lives on the OUTER bar capsule (field +
        // embedded button together) so the pulse ring traces the entire
        // pill's true perimeter instead of stopping short at the inner
        // text-field ZStack's bounds -- that mismatch used to read as a
        // second nested capsule outline ending right before the button.
        .overlay {
            if urlFieldFocused && urlText.isEmpty {
                WaitingPulseGlow()
            }
        }
        // Rim glow on hover or focus (cursor in the field) -- same cue as
        // every other interactive control's hover state, just applied to
        // this bar's own outer rim instead of a button's.
        .overlay {
            HoverGlowRim(isActive: isUrlCardHovering || urlFieldFocused)
        }
        .onHover { isUrlCardHovering = $0 }
        // Same content column as everything beneath it (it used to be a
        // separate fixed 864pt cap, which left it narrower than the cards on
        // big windows and wider than them on small ones).
        .contentColumn()
        .onChange(of: urlText) {
            analyzeResult = nil
            duplicateURLDetected = false
            hasInvalidURLs = !allLinesAreURLs(urlText)
        }
    }

    // MARK: - Preview Card

    var previewCard: some View {
        ForEach($linkPreviews) { $preview in
            linkPreviewCard(preview: $preview)
                // Insert/remove only -- same-identity property updates
                // (analyze completing, instant-preview title/thumbnail
                // landing) never hit this transition since the id is
                // preserved across those updates. Scale-pop-in on spawn,
                // brought back by explicit request for these download/
                // analyze cards specifically. Removal is still instant.
                .transition(.glassPop)
        }
    }

    @ViewBuilder
    func linkPreviewCard(preview: Binding<LinkPreview>) -> some View {
        let p = preview.wrappedValue

        if p.downloadID != nil {
            // ── CompletedCard: download is active / done / failed ─────────
            downloadCompletedCard(preview: preview)
        } else {
            // ── PreviewCard: item waiting, show settings ───────────────────
            downloadPreviewCard(preview: preview)
        }
    }

    // Shared by downloadPreviewCard and downloadCompletedCard, which used to
    // each carry an identical copy of this exact 80x52 thumbnail+skeleton
    // ZStack.
    private func thumbnailView(urlString: String) -> AnyView {
        AnyView(
            AsyncImage(url: URL(string: urlString)) { phase in
                ZStack {
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous)
                        .fill(Color.clear)
                        .overlay(ThumbnailSkeleton().clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous)))
                    if case .success(let img) = phase {
                        img.resizable()
                            .aspectRatio(contentMode: .fill)
                            .transition(.blurIn)
                    }
                }
                .frame(width: 80, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous))
            }
            .animation(.easeOut(duration: 0.2), value: urlString)
        )
    }

    // MARK: Download — settings card (queued state)

    @ViewBuilder
    func downloadPreviewCard(preview: Binding<LinkPreview>) -> some View {
        let p = preview.wrappedValue

        let thumbView = thumbnailView(urlString: p.thumbnailURL)

        // Simple mode -- always visible whether the card is collapsed or
        // expanded: URL, then input->output chip pairing (same visual
        // language as the in-progress/completed card's InputOutputRow, so
        // a card reads identically before and after the download starts),
        // then the Video+Audio / Audio Only mode toggle. Only the deeper
        // per-format/quality picker rows are gated behind expand (see
        // settings() below) -- switching mediaMode here never touches the
        // input side, it only changes what outputChips reports.
        let modeRow = AnyView(
            HStack(spacing: 6) {
                if p.hasVideo {
                    CompactModeChip(label: "Video + Audio", icon: "video.badge.waveform", isSelected: p.mediaMode == .videoAndAudio,
                             tint: DesignTokens.Accent.primary) {
                        withAnimation(.spring(response: 0.25)) { preview.mediaMode.wrappedValue = .videoAndAudio }
                    }
                }
                CompactModeChip(label: "Audio Only", icon: "waveform", isSelected: p.mediaMode == .audioOnly,
                         tint: DesignTokens.Accent.success) {
                    withAnimation(.spring(response: 0.25)) { preview.mediaMode.wrappedValue = .audioOnly }
                }
            }
        )
        // Only URL + input->output chips here now -- this is exactly the
        // group the thumbnail centers against (see PreviewCard.cardHeader).
        // modeRow moved to belowHeader below, outside this group, so the
        // toggle's own height never pulls the thumbnail's centering down
        // with it, and the thumbnail stays vertically centered against
        // "everything but the format/mode controls" as requested.
        let subtitleWithURL = AnyView(
            VStack(alignment: .leading, spacing: 6) {
                Text(p.url)
                    .font(.appMono(size: 10)).foregroundColor(.white.opacity(DesignTokens.Text.disabled))
                    .lineLimit(1).truncationMode(.middle)
                // Side by side (arrow centered against the chips' real height,
                // including when they wrap) in a wide column; stacked in a
                // narrow one -- see InputOutputChips.
                InputOutputChips(input: p.inputChips, output: p.outputChips)
                    .animation(nil, value: p.mediaMode)
            }
        )
        // Below the header, full-width -- a thin divider first so the mode
        // toggle reads as a clearly separate control/section from the
        // input->output chip row above it, not a continuation of it. The
        // collapse toggle now shares this same line (trailing edge) instead
        // of sitting up in the header row -- it's grouped with the mode
        // toggle here since collapseButtonInHeader is false for this call.
        let collapseIsExpandedBinding = isBatchMode ? .constant(false) : Binding(
            get: { preview.wrappedValue.isExpanded },
            set: { preview.isExpanded.wrappedValue = $0 }
        )
        let belowHeaderRow = AnyView(
            VStack(alignment: .leading, spacing: 9) {
                GlassDivider()
                HStack(spacing: 6) {
                    modeRow
                    Spacer()
                    if !isBatchMode {
                        CollapseToggleButton(isExpanded: collapseIsExpandedBinding.wrappedValue) {
                            withAnimation(.easeOut(duration: 0.22)) { collapseIsExpandedBinding.wrappedValue.toggle() }
                        }
                    }
                }
            }
        )

        // State 1: Analyzing → State 2: PreviewCard (analyzed, waiting)
        // Error state: analyze itself failed -- either a detected HTTP 403
        // at analyze time, or a generic "no usable output" failure (most
        // often an incompatible/unsupported source) -- shown instead of
        // silently dropping the card, reusing the same row layout/height as
        // AnalyzingCard/PreviewCard so the queue doesn't jump around as
        // cards resolve.
        if let err = p.analyzeError {
            HStack(spacing: 10) {
                Image(systemName: p.analyzeErrorIsForbidden ? "lock.slash" : "exclamationmark.triangle")
                    .font(.system(size: 18))
                    .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                    .frame(width: 80, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.url)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(DesignTokens.Text.secondary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(err)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                        .lineLimit(2)
                }
                Spacer()
                HoverIconButton(icon: "xmark", help: "Remove", expandable: true) {
                    withAnimation(.spring(response: 0.3)) { linkPreviews.removeAll { $0.id == p.id } }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: DesignTokens.Radius.medium)
            .transition(.glassPopInOnly)
        } else {
        PreviewCard(
            isSelected: p.isSelected,
            onToggleSelect: {
                withAnimation(.spring(response: 0.2)) { preview.isSelected.wrappedValue.toggle() }
            },
            onRemove: {
                withAnimation(.spring(response: 0.3)) { linkPreviews.removeAll { $0.id == p.id } }
            },
            showCheckbox: isBatchMode,
            thumbnail: thumbView,
            title: p.title,
            subtitle: subtitleWithURL, // URL + input→output chip row -- always visible, even collapsed
            belowHeader: belowHeaderRow, // divider + mode toggle + collapse button -- outside the thumbnail-centered group
            isExpanded: isBatchMode ? .constant(false) : Binding(
                get: { preview.wrappedValue.isExpanded },
                set: { preview.isExpanded.wrappedValue = $0 }
            ),
            collapseLocked: isBatchMode,
            // Collapse button now lives inside belowHeaderRow, on the same
            // line as the mode toggle, instead of up in the header row.
            collapseButtonInHeader: false,
            // While still analyzing, this same PreviewCard instance renders
            // the skeleton/spinner header instead of real content -- no more
            // separate AnalyzingCard view swapped in via if/else, so the
            // card updates in place (expands/fills in) once analyze
            // completes instead of being removed and replaced.
            isAnalyzing: p.isPending,
            onCancelAnalyze: {
                // Matched by this card's own id, not its url -- pasting the
                // same link multiple times at once creates several pending
                // cards sharing one url string, and url-based lookup here
                // used to terminate/clear every one of them instead of just
                // the specific card the user clicked X on.
                // Kill yt-dlp's own child processes (any fallback/merge step)
                // before terminate() -- a plain terminate() only SIGTERMs the
                // yt-dlp process itself, which doesn't always stop promptly if
                // it's blocked mid-network-call, letting analyze finish in the
                // background after the card is already gone from the list.
                if let proc = analyzeProcesses[p.id] { DownloadManager.terminateProcessTree(proc) }
                analyzeProcesses.removeValue(forKey: p.id)
                // Marks this id as cancelled in case it's still waiting on
                // the concurrency gate (no Process exists yet to terminate
                // above) -- checked the moment its turn comes up so it bails
                // out before ever spawning yt-dlp.
                cancelledAnalyzeIDs.insert(p.id)
                withAnimation(.spring(response: 0.35)) {
                    linkPreviews.removeAll { $0.id == p.id }
                }
            }
        ) {
            // Advanced mode -- format + quality pickers, only reachable
            // once expanded. DOWNLOAD AS (the Video+Audio/Audio Only
            // toggle) lives in the always-visible header now (modeRow
            // above), not here -- this closure only renders the deeper
            // per-format/quality choices.
            //
            // Condensed into a single labeled section per media mode
            // (previously two separate sections each with their own
            // header/divider; the format row and quality row now share
            // one header since they're really one decision -- "what exact
            // file do I get").
            //
            // The Video-vs-Audio sections are structurally different content,
            // so a mode change swaps the whole body via `.pageSwap` (outgoing
            // blurs away first, incoming focuses in a beat later -- that
            // stagger is what stops the two chip sets reading as overlapped,
            // the reason this used to be a hard cut). The ZStack keeps both
            // bodies overlaid during the swap instead of stacking their
            // heights, so the card doesn't bounce. Individual chip picks
            // within a mode aren't gated on mediaMode and keep their own
            // spring feedback.
            ZStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 11) {
            if p.hasVideo && p.mediaMode != .audioOnly {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("VIDEO", systemImage: "video")
                            .font(.appMono(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                        Spacer()
                        nativeLegend()
                    }
                    OptionRow {
                        ForEach(VideoFormat.allCases) { f in
                            SelectorChip(label: f.label, note: f.note, isSelected: p.videoFormat == f,
                                       tint: DesignTokens.Accent.primary, nativeBadge: f.isNative) {
                                preview.videoFormat.wrappedValue = f
                            }
                        }
                    }
                    OptionRow {
                        // Tiers above what the source actually has are hidden
                        // (unknown height keeps the old up-to-1080p default).
                        // A sub-480p source still shows the 480p floor tier --
                        // the output chip reports the real resolution.
                        ForEach(VideoQuality.allCases.filter { q in
                            let h = p.sourceMaxHeight
                            return h == 0 ? q.maxHeight <= 1080 : q.maxHeight <= VideoQuality.highest(for: h).maxHeight
                        }) { q in
                            SelectorChip(label: effectiveVideoResolutionLabel(q, sourceMaxHeight: p.sourceMaxHeight), isSelected: p.videoQuality == q) {
                                preview.videoQuality.wrappedValue = q
                            }
                        }
                    }
                }
            }

            if p.mediaMode == .audioOnly {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("AUDIO", systemImage: "waveform")
                            .font(.appMono(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                        Spacer()
                        nativeLegend()
                    }
                    OptionRow {
                        ForEach(AudioFormat.allCases) { f in
                            SelectorChip(label: f.label, note: f.note, isSelected: p.audioFormat == f,
                                       tint: DesignTokens.Accent.success, nativeBadge: f.isNative) {
                                preview.qualityByFormat.wrappedValue[p.audioFormat.rawValue] = p.audioQuality
                                preview.audioFormat.wrappedValue = f
                                let saved = preview.qualityByFormat.wrappedValue[f.rawValue] ?? .q320
                                preview.audioQuality.wrappedValue = saved
                            }
                        }
                    }
                    // M4A has no selectable quality/bitrate — it's a fixed
                    // passthrough format, so there's no real choice to present
                    // (mirrors Convert's handling of MP3/FLAC hiding the audio
                    // codec row).
                    if p.audioFormat != .m4a {
                        OptionRow {
                            ForEach(AudioQuality.allCases) { q in
                                let chipLabel = p.audioFormat == .flac ? q.flacLabel : q.label
                                let kbps: Int = { switch q {
                                    case .q320: return 320
                                    case .q256: return 256
                                    case .q128: return 128
                                }}()
                                let asrHz: Int = { switch q {
                                    case .q320: return 0
                                    case .q256: return 96000
                                    case .q128: return 44100
                                }}()
                                let hideKbps = p.audioFormat != .flac && p.sourceABR > 0 && kbps > p.sourceABR
                                let effectiveASR: Int = {
                                    if p.sourceASR > 0 { return p.sourceASR }
                                    if p.sourceABR > 0 { return p.sourceABR >= 320 ? 96000 : 48000 }
                                    return 48000
                                }()
                                let hideFLAC = p.audioFormat == .flac && asrHz > 0 && asrHz > effectiveASR
                                if !hideKbps && !hideFLAC {
                                    SelectorChip(label: chipLabel, isSelected: p.audioQuality == q) {
                                        preview.audioQuality.wrappedValue = q
                                    }
                                }
                            }
                        }
                    }
                }
            }
            } // close wrapper VStack (spacing: 11)
            .id(p.mediaMode)
            .transition(.pageSwap)
            }
            .animation(.easeOut(duration: 0.2), value: p.mediaMode)
        }
        .transition(.glassPopInOnly)
        } // end else (not pending)
    }

    // MARK: Download — completed card (active/done/failed state)

    @ViewBuilder
    func downloadCompletedCard(preview: Binding<LinkPreview>) -> some View {
        let p = preview.wrappedValue
        if let did = p.downloadID,
           let dl = manager.downloads.first(where: { $0.id == did }) {

        let thumbView = thumbnailView(urlString: p.thumbnailURL)

        // ORIGINAL link/file info chips (length + Source codec/resolution) —
        // unchanged, reads the source file. Matches Convert's input-row chip
        // treatment exactly.
        let originalInfoChips: [ChipData] = dl.inputChips

        // Output info: destination path (directory + final filename once
        // known) + output info chips (length/size/format-quality).
        let outputInfoChips: [ChipData] = dl.outputChips
        let outputPath: String = dl.outputFilePath ?? dl.outputDir

        // Status icon + pill — lives in the actions row now, to the left of
        // the Cancel/Reveal/Redownload/Retry buttons, not in the header.
        let statusView = AnyView(
            HStack(spacing: 6) {
                Group {
                    switch dl.status {
                    case .done:      Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    case .error:     Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                    case .cancelled: Image(systemName: "slash.circle.fill").foregroundColor(.orange)
                    case .downloading, .pending:
                        Image(systemName: "arrow.down.circle").foregroundColor(.white.opacity(DesignTokens.Text.secondary))
                    }
                }.font(.appMono(size: 14))

                StatusBadge(status: dl.status)
            }
        )

        // Combined subtitle: input info (URL + chips) on the left, a big
        // centered arrow, then output info (destination path + chips) on
        // the right — both halves live in the SAME header row now, at the
        // same visual level, instead of output info being its own row
        // below the divider.
        let subtitleWithURL = AnyView(
            InputOutputRow(
                inputPath: p.url,
                inputChips: originalInfoChips,
                outputPath: outputPath,
                outputChips: outputInfoChips
            )
        )

        CompletedCard(
            isSelected: p.isSelected,
            onToggleSelect: {
                withAnimation(.spring(response: 0.2)) { preview.isSelected.wrappedValue.toggle() }
            },
            onRemove: {
                // Cancel first if this download is still in flight -- removing
                // the card alone left yt-dlp/ffmpeg running headless with
                // nothing on screen to show for it, and no partial-file
                // cleanup (see manager.cancel(download:)) ever ran.
                if dl.status == .downloading {
                    manager.cancel(download: dl)
                }
                withAnimation(.spring(response: 0.3)) { linkPreviews.removeAll { $0.id == p.id } }
            },
            showCheckbox: isBatchMode,
            thumbnail: thumbView,
            title: p.title,
            subtitle: subtitleWithURL
        ) {

            // Actions row — buttons stretch to fill the full card width (each
            // GlassButton defaults to maxWidth: .infinity), so this HStack
            // itself must also claim the full width. A leading Spacer() here
            // previously ate the extra space and left a gap on the left with
            // the buttons hugging the right edge instead of spanning the card.
            HStack(spacing: 10) {
                    statusView
                    if dl.status == .downloading {
                        // No hover growth -- this pill sits right at the card's
                        // trailing edge, and the default hover scale-up clipped
                        // its right side against the card boundary.
                        GlassButton(label: "Cancel", icon: "stop.fill", tint: .red, scaleOverride: (hover: 1.0, press: DesignTokens.Interactive.scalePress)) {
                            manager.cancel(download: dl)
                        }
                    }
                    // No hover growth on any of these -- same trailing-edge
                    // pill row as Cancel above, same clipping issue against
                    // the card boundary if the default hover scale-up is
                    // left on.
                    if dl.status == .cancelled {
                        restoreActionButton(label: "Redownload", tint: DesignTokens.Accent.warning, dl: dl, replacingID: p.id)
                    }
                    if dl.status == .error {
                        restoreActionButton(label: "Retry", tint: DesignTokens.Accent.danger, dl: dl, replacingID: p.id)
                    }
                    if dl.status == .done {
                        GlassButton(label: "Reveal in Finder", icon: "folder.fill", tint: DesignTokens.Accent.primary, scaleOverride: (hover: 1.0, press: DesignTokens.Interactive.scalePress)) {
                            if let filePath = dl.outputFilePath {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: filePath)])
                            } else {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dl.outputDir)])
                            }
                        }
                        restoreActionButton(label: "Redownload", tint: DesignTokens.Accent.warning, dl: dl, replacingID: p.id)
                    }
            }
            .frame(maxWidth: .infinity)

            // Progress bar (downloading only)
            if dl.status == .pending {
                HStack(spacing: 5) {
                    Image(systemName: "clock").font(.appMono(size: 10))
                    Text("Waiting to download\u{2026}").font(.appMono(size: 11))
                }
                .foregroundColor(.white.opacity(DesignTokens.Text.disabled))
                // Dim, slow shimmer -- visually distinct from the brighter/
                // faster one used for "downloading, no % yet" below, so
                // waiting reads as a calmer pre-download state rather than
                // looking like it's already actively transferring.
                GeometryReader { geo in
                    ShimmerBar(width: geo.size.width, color: .white, glow: false, duration: 1.8)
                }
                .frame(height: 4)
            } else if dl.status == .downloading {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(DesignTokens.Interactive.fillRest)).frame(height: 4)
                        if let pct = dl.progress, pct > 0 {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(LinearGradient(colors: [Color.green.opacity(0.6), Color.green.opacity(1.0)],
                                                     startPoint: .leading, endPoint: .trailing))
                                .frame(width: geo.size.width * CGFloat(pct), height: 4)
                                .shadow(color: Color.green.opacity(0.8), radius: 4)
                                .shadow(color: Color.green.opacity(0.4), radius: 8)
                                .animation(.easeOut(duration: 0.25), value: pct)
                        }
                        // Pre-download gap (process launching / URL still
                        // resolving): the bar itself just stays at its dim
                        // resting fill -- the bouncing dots below, in the
                        // same spot the real percentage label will occupy,
                        // carry the "actively working" signal instead.
                    }
                }
                .frame(height: 4)
                if !dl.activityText.isEmpty || !dl.etaText.isEmpty {
                    let hasRealProgress = (dl.progress ?? 0) > 0
                    HStack(spacing: 6) {
                        if let pct = dl.progress, pct == 0 {
                            BouncingDots()
                        }
                        if !dl.etaText.isEmpty {
                            // Once there's a real percentage, style it to match
                            // the bouncing dots / progress fill -- green with
                            // a soft glow -- instead of the dim disabled tint.
                            Text(dl.etaText)
                                .font(.appMono(size: 10, design: .monospaced))
                                .foregroundColor(hasRealProgress ? Color.green.opacity(0.95) : .white.opacity(DesignTokens.Text.disabled))
                                .shadow(color: hasRealProgress ? Color.green.opacity(0.6) : .clear, radius: 4)
                                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                                .transition(.blurIn)
                        }
                        if !dl.activityText.isEmpty {
                            Text(dl.activityText)
                                .font(.appMono(size: 10, design: .monospaced))
                                .foregroundColor(.white.opacity(DesignTokens.Text.disabled))
                                .lineLimit(1).truncationMode(.tail)
                                .transition(.blurIn)
                        }
                        Spacer(minLength: 4)
                    }
                }
            }

            // Error details
            if dl.status == .error {
                if let err = dl.errorMessage {
                    Text(err).font(.appMono(size: 11)).foregroundColor(.red.opacity(0.75)).lineLimit(2)
                }
                if let hint = dl.fixHint {
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "lightbulb.fill").font(.appMono(size: 10)).foregroundColor(.yellow.opacity(0.8))
                        Text(hint).font(.appMono(size: 11)).foregroundColor(.orange.opacity(0.85))
                    }
                }
                if dl.fixAction != .none {
                    Button(action: {
                        manager.performFix(for: dl, config: config) {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false; panel.canChooseDirectories = true
                            panel.canCreateDirectories = true
                            panel.allowsMultipleSelection = false; panel.prompt = "Select Folder"
                            if panel.runModal() == .OK, let url = panel.url {
                                config.outputDir = url.path
                            }
                        }
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: fixActionIcon(dl.fixAction)).font(.appMono(size: 10, weight: .semibold))
                            Text(fixActionLabel(dl.fixAction)).font(.appMono(size: 11, weight: .semibold))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.18))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.orange.opacity(0.4), lineWidth: 0.75)))
                        .foregroundColor(.orange)
                    }.buttonStyle(.plain)
                }
            }
        }
        } // end if let did
    }

    func fixActionLabel(_ action: FixAction) -> String {
        switch action {
        case .setCookieNone:       return "Set Cookie Source to None"
        case .openFolderPicker:    return "Choose Folder"
        case .openPrivacySecurity: return "Open Privacy & Security"
        case .openURL:             return "Search on YouTube"
        case .none:                return ""
        }
    }
    func fixActionIcon(_ action: FixAction) -> String {
        switch action {
        case .setCookieNone:       return "cookie"
        case .openFolderPicker:    return "folder.badge.plus"
        case .openPrivacySecurity: return "shield.fill"
        case .openURL:             return "magnifyingglass"
        case .none:                return ""
        }
    }
    func allLinesAreURLs(_ text: String) -> Bool {
        dropAllLinesAreURLs(text)
    }

    struct LinkPreview: Identifiable {
        // var, not let: the analyze-complete path below reassigns this to
        // the pending placeholder's original id so SwiftUI keeps treating
        // it as the *same* card (a smooth cross-fade) instead of tearing
        // down the old view and mounting a brand new one (which read as a
        // hard "replace" flash -- light grey glass materializing then
        // deepening to the real black tint -- because a fresh view has to
        // build up its VisualEffectBlur/tint layers from scratch).
        var id = UUID()
        let url: String
        // Mutable: patched in-place by the instant-preview fetch while the
        // card is still `isPending`, then overwritten again once the real
        // yt-dlp analyze result lands.
        var title: String
        var thumbnailURL: String
        let hasVideo: Bool
        let duration: String
        var durationSeconds: Int = 0      // for size estimation
        var fileSizeBytes: Int? = nil     // filesize_approx from yt-dlp (best available format)
        var sourceMaxHeight: Int = 0      // actual max resolution of the source (0 = unknown)
        var sourceASR: Int = 0              // audio sample rate in Hz (0 = unknown)
        var sourceABR: Int = 0              // audio bitrate in kbps (0 = unknown)
        var sourceVideoCodec: String? = nil  // e.g. "AV1", "H264" (nil = unknown/audio-only)
        var sourceAudioCodec: String? = nil  // e.g. "OPUS", "AAC"
        var sourceChannelLabel: String? = nil // e.g. "2.0", "5.1"
        // Per-link download options
        var mediaMode: MediaMode
        var videoQuality: VideoQuality = VideoQuality.allCases.first!  // set to highest(for: sourceMaxHeight) after analyze
        var videoFormat: VideoFormat   = VideoFormat.allCases.first!
        var audioFormat: AudioFormat   = AudioFormat.allCases.first!   // M4A — native, no re-encode
        var audioQuality: AudioQuality = .q320  // quality for current format
        // Per-format quality memory
        var qualityByFormat: [String: AudioQuality] = [
            "mp3": .q320, "m4a": .q320, "wav": .q320, "flac": .q320
        ]
        // Queue selection
        var isSelected: Bool = true
        // Settings-section collapse state — mirrors Convert's job.isExpanded.
        // Transient UI state, never persisted. Defaults collapsed: the
        // mode chip (Video+Audio / Audio Only) and the resulting output
        // format chips are always visible in the header regardless of
        // this flag -- expanding only reveals the deeper per-format/
        // quality picker rows (VIDEO FORMAT/RESOLUTION or AUDIO FORMAT/
        // QUALITY), the "advanced" layer on top of the "simple" default.
        var isExpanded: Bool = false
        // Tracks the active Download.id once dispatched
        var downloadID: UUID? = nil
        // True when re-queued from history (bypasses duplicate check)
        var fromHistory: Bool = false
        var isPending: Bool = false   // true while analyze is in-flight
        // Set when analyze itself fails (not the later download step). A
        // persistent 403 here means the SOURCE is blocking access outright
        // (bot detection, geo/auth-gated, etc.) -- unlike a download-time
        // 403, which is usually just a stale signed CDN URL and gets
        // auto-retried. There's nothing to retry at analyze time since
        // yt-dlp couldn't even read the page, so this is surfaced directly
        // instead of silently dropping the card.
        var analyzeError: String? = nil
        var analyzeErrorIsForbidden: Bool = false  // true specifically for HTTP 403 at analyze time
        var isPlaylist: Bool = false      // true if URL is a playlist
        var playlistCount: Int = 0        // number of items in playlist
        // Exact combined (video+audio) byte sizes per resolution cap — populated during analyze
        var fileSizeByQuality: [Int: Int] = [:]  // [heightCap: bytes]

        // Input row — describes the SOURCE itself, never the currently
        // selected download mode/format. Blue video chip shows whenever
        // the source actually has a video track (hasVideo), independent
        // of mediaMode -- switching to Audio Only must never make this
        // row look like the source lost its video track, it only changes
        // what's being extracted from it. Mirrors Download.inputChips'
        // same source-of-truth split.
        var inputChips: [ChipData] {
            var result: [ChipData] = []
            let playlistSize = isPlaylist ? "\(playlistCount) tracks" : nil
            if let length = ChipData.lengthAndSize(length: lengthChipValue(seconds: durationSeconds, raw: duration), size: playlistSize) {
                result.append(length)
            }
            // Blue: source video info (codec + resolution) — gated on hasVideo
            // (the source's actual capability), NOT mediaMode (the user's
            // current output choice).
            if hasVideo {
                result.append(.video([sourceVideoCodec, sourceResolutionLabel(sourceMaxHeight)]) ?? .videoPlaceholder)
            }
            // Green: source audio info (codec + channels + bitrate)
            if let audio = ChipData.audio([sourceAudioCodec, sourceChannelLabel, bitrateLabel(kbps: sourceABR)]) {
                result.append(audio)
            } else if !hasVideo {
                result.append(.audioPlaceholder)
            }
            return result
        }

        // Output row — reflects the CURRENTLY SELECTED mediaMode/format/
        // quality, i.e. what will actually be produced. This is the only
        // row that changes when the Video+Audio / Audio Only chip is
        // toggled -- mirrors Download.outputChips exactly so the pre-
        // download card and the active/completed card read identically.
        var outputChips: [ChipData] {
            var result: [ChipData] = []
            if let length = ChipData.lengthAndSize(length: lengthChipValue(seconds: durationSeconds, raw: duration), size: estimatedSizeString()) {
                result.append(length)
            }
            switch mediaMode {
            case .audioOnly:
                // M4A is native passthrough (no re-encode -- see audioFormat's
                // own doc comment), so its real bitrate is the source's own
                // rather than one of the quality presets, which only apply
                // when actually re-encoding to MP3/WAV/FLAC.
                let bitrate = audioFormat == .m4a ? bitrateLabel(kbps: sourceABR) : audioQuality.label
                result.append(.audio([audioFormat.rawValue.uppercased(), sourceChannelLabel, bitrate]) ?? .audioPlaceholder)
            case .videoAndAudio:
                // Video and audio are both stream-copied when merging, so the
                // output codec/channels/bitrate match the source's own.
                result.append(.video([videoFormat.rawValue.uppercased(), sourceVideoCodec,
                                      effectiveVideoResolutionLabel(videoQuality, sourceMaxHeight: sourceMaxHeight)]) ?? .videoPlaceholder)
                result.append(.audio([sourceAudioCodec, sourceChannelLabel, bitrateLabel(kbps: sourceABR)]) ?? .audioPlaceholder)
            }
            return result
        }

        // Estimated size string based on current options
        // Formatted, "~"-prefixed version of estimatedBytes(), for the
        // per-card size label.
        func estimatedSizeString() -> String? {
            guard let bytes = estimatedBytes() else { return nil }
            return "~" + formatByteSize(bytes)
        }

        // Raw byte version, used both by estimatedSizeString() above and to
        // sum totals across multiple queued previews for the SAVE TO
        // section's total-size chip.
        func estimatedBytes() -> Int? {
            guard downloadID == nil else { return nil }
            let secs = durationSeconds
            if mediaMode == .audioOnly && secs > 0 {
                return (audioQuality.kbps * 1000 / 8) * secs
            } else if mediaMode == .videoAndAudio {
                let cap = videoQuality.maxHeight
                if let exact = fileSizeByQuality[cap], exact > 0 {
                    return exact
                }
                if let b = fileSizeBytes, b > 0 {
                    let scale: Double
                    let is4KSource = sourceMaxHeight >= 2160
                    switch videoQuality {
                    case .q4k:   scale = 1.0
                    case .q1440: scale = is4KSource ? 0.50 : 1.0
                    case .q1080: scale = is4KSource ? 0.25 : 0.85
                    case .q720:  scale = is4KSource ? 0.15 : 0.55
                    case .q480:  scale = is4KSource ? 0.08 : 0.30
                    }
                    let adj = Int(Double(b) * scale)
                    let audioBytes = secs > 0 ? (192000 / 8) * secs : 0
                    return adj + audioBytes
                }
            }
            return nil
        }
    }

    @State private var analyzeResult: AnalyzeResult? = nil
    @State private var linkPreviews: [LinkPreview] = []

    // Sum of estimated sizes across all selected, not-yet-downloaded previews —
    // shown as a chip next to SAVE TO, mirroring Convert's estimated-size chip.
    var totalEstimatedSizeLabel: String? {
        let bytes = selectedPreviews
            .filter { $0.downloadID == nil }
            .compactMap { $0.estimatedBytes() }
            .reduce(0, +)
        guard bytes > 0 else { return nil }
        return "~" + formatByteSize(bytes)
    }

    // Instant preview for pending cards, mirroring how TBD makes a pasted
    // link feel immediate: yt-dlp is a PyInstaller binary that unpacks all
    // of Python on every launch, so even the fastest analyze call takes a
    // visible second or more. YouTube's public oEmbed endpoint is a tiny
    // JSON response that answers in a few hundred milliseconds, and the
    // thumbnail doesn't need a network call at all -- it's deterministic
    // from the video ID. This runs in parallel with the real yt-dlp
    // analyze already in flight and only ever patches a card that's still
    // `isPending` and doesn't have a title yet, so it can never clobber a
    // faster-arriving real result and never fights the eventual PreviewCard.
    /// Called from the analyze background thread right after a Process starts.
    /// Returns false (after killing it) if the card was cancelled while the
    /// process was still launching.
    private func registerAnalyzeProcess(_ proc: Process, cardID: UUID) -> Bool {
        var cancelled = false
        DispatchQueue.main.sync {
            if self.cancelledAnalyzeIDs.contains(cardID) { cancelled = true }
            else { self.analyzeProcesses[cardID] = proc }
        }
        if cancelled {
            DownloadManager.terminateProcessTree(proc)
            proc.waitUntilExit()
        }
        return !cancelled
    }

    private func fetchInstantPreview(for url: String, cardID: UUID) {
        guard let videoID = Self.youTubeVideoID(from: url) else { return }
        let thumbnailURL = "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg"
        // Show the deterministic thumbnail immediately -- no network wait needed.
        // Matched by the placeholder's own id, not url, so duplicate-url
        // pastes each patch their own card instead of all racing to patch
        // whichever same-url card happens to be first in the array.
        DispatchQueue.main.async {
            if let idx = self.linkPreviews.firstIndex(where: { $0.id == cardID }) {
                self.linkPreviews[idx].thumbnailURL = thumbnailURL
            }
        }
        guard let oembedURL = URL(string: "https://www.youtube.com/oembed?url=\(url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url)&format=json") else { return }
        URLSession.shared.dataTask(with: oembedURL) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = json["title"] as? String, !title.isEmpty else { return }
            DispatchQueue.main.async {
                if let idx = self.linkPreviews.firstIndex(where: { $0.id == cardID }) {
                    self.linkPreviews[idx].title = title
                }
            }
        }.resume()
    }

    // Accepts youtube.com/watch?v=, youtu.be/, youtube.com/shorts/, and
    // youtube.com/embed/ forms -- the same variety of link shapes users
    // actually paste.
    private static func youTubeVideoID(from url: String) -> String? {
        guard let comps = URLComponents(string: url),
              let host = comps.host?.lowercased(),
              host.contains("youtube.com") || host.contains("youtu.be") else { return nil }
        if host.contains("youtu.be") {
            let id = comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return id.isEmpty ? nil : id
        }
        if let v = comps.queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty {
            return v
        }
        for prefix in ["/shorts/", "/embed/", "/live/"] {
            if comps.path.hasPrefix(prefix) {
                let id = String(comps.path.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return id.isEmpty ? nil : id
            }
        }
        return nil
    }

    // `ids` lets each entry point associate the freshly-created pending
    // placeholder's own unique UUID with its url, so duplicate-url pastes
    // stay independent all the way through analyze/cancel/complete instead
    // of colliding on the shared url string. Optional and defaults to
    // freshly-generated UUIDs for any caller that hasn't been updated to
    // pass real placeholder ids (keeps this source-compatible), though
    // every current call site now passes the real ids.
    func analyzeURL(urls urlsOverride: [String]? = nil, ids idsOverride: [UUID]? = nil) {
        let urls: [String]
        if let override = urlsOverride {
            urls = override
        } else {
            urls = urlText.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        guard !urls.isEmpty, let ytdlp = manager.ytdlpPath else {
            manager.appendLog("Analyze: yt-dlp not found")
            return
        }
        // ids MUST line up 1:1 with urls by index -- if a caller passes a
        // mismatched count, fall back to fresh UUIDs rather than risk
        // silently pairing the wrong id with the wrong url.
        let ids: [UUID] = (idsOverride?.count == urls.count) ? idsOverride! : urls.map { _ in UUID() }
        isAnalyzing = true
        analyzeResult = nil
        manager.appendLog("Analyzing \(urls.count) URL(s)...")

        let group = DispatchGroup()
        // Use a lock-protected array to collect results in order
        var results: [(Int, LinkPreview?)] = []
        let lock = NSLock()

        // Cap how many yt-dlp analyze processes run at once. Previously every
        // pasted URL fired its own yt-dlp process onto DispatchQueue.global()
        // simultaneously with no limit -- fine for 1-2 links, but pasting a
        // large batch (e.g. 8x the same link) meant 8 concurrent yt-dlp/network
        // calls competing for the same CPU cores and, for duplicate URLs, the
        // same remote endpoint -- which both slowed the batch down overall and
        // made them tend to finish in one simultaneous cluster rather than a
        // steady trickle. A small counting gate lets at most `maxConcurrentAnalyze`
        // run their actual process-spawning work at a time; the rest wait on
        // this same global queue and pick up as slots free -- no change to the
        // per-URL completion/UI logic below, which already applies each result
        // the instant it lands.
        let maxConcurrentAnalyze = 3
        let analyzeGateSemaphore = DispatchSemaphore(value: maxConcurrentAnalyze)

        for (i, url) in urls.enumerated() {
            let cardID = ids[i]
            // Fires independently of the yt-dlp call below and doesn't
            // participate in `group`/`results` at all -- it only ever
            // patches the still-pending card's title/thumbnail so the UI
            // stops looking frozen on a bare URL while yt-dlp spins up.
            // The real analyze result below always wins once it lands.
            // Runs immediately for every card regardless of the concurrency
            // gate below -- it's a cheap oEmbed fetch, not a yt-dlp process,
            // so there's no reason to queue it.
            fetchInstantPreview(for: url, cardID: cardID)
            group.enter()
            DispatchQueue.global().async {
                // Block this queued work item (not the main thread) until a
                // concurrency slot is free -- same pattern as the errSem/
                // errSem2 semaphores just below, which already block a
                // background-queue thread safely within this same function.
                analyzeGateSemaphore.wait()
                defer { analyzeGateSemaphore.signal() }
                // If this card was cancelled while it was still waiting for a
                // concurrency slot, there's no yt-dlp process to spawn at all --
                // just clean up and bail before doing any work. Checked on the
                // main queue since cancelledAnalyzeIDs is @State.
                var wasCancelledWhileQueued = false
                DispatchQueue.main.sync {
                    if self.cancelledAnalyzeIDs.remove(cardID) != nil { wasCancelledWhileQueued = true }
                }
                if wasCancelledWhileQueued { group.leave(); return }
                // Single yt-dlp call: detect playlist + extract metadata in one pass.
                // %(playlist_count)s is NA for single videos, an integer for playlists.
                // --yes-playlist so yt-dlp doesn't refuse to print playlist_count.
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: ytdlp)
                // Cache the full extracted info dict alongside the existing --print
                // calls so a same-session Download can skip yt-dlp's full webpage +
                // player-API + m3u8 resolution the second time (~9-10s measured on
                // YouTube) via --load-info-json. This adds zero extra network cost --
                // --write-info-json just serializes the info dict yt-dlp already has
                // in memory for the --print output above. Written unconditionally
                // here (including for playlist probes); the playlist case writes
                // just the first item's info, so the download-time cache lookup
                // below is gated on !isPlaylist to avoid ever feeding a single-item
                // info dict into a full-playlist download.
                let infoJSONCachePath = self.manager.cachedInfoJSONWritePath(for: url)
                var analyzeArgs = [
                    "--no-warnings", "--no-download",
                    // --print (used below) implies --simulate, and yt-dlp's
                    // --write-info-json write is gated on `not simulate` --
                    // so without --no-simulate here, --write-info-json was
                    // silently a no-op the entire time (confirmed: the
                    // analyze-cache directory stayed empty across repeated
                    // analyzes of the same URL). --no-simulate overrides
                    // that implied simulate so the file actually gets
                    // written to disk; --no-download (above) is what
                    // actually prevents the real media from being fetched,
                    // so this does not turn analyze into a real download.
                    "--no-simulate",
                    "--yes-playlist",
                    "--format", "bestvideo*",  // ensures %(height)s reflects true max resolution
                    // Line 1: playlist_count (NA for single video)
                    "--print", "%(playlist_count)s",
                    // Line 2: metadata
                    "--print", "%(title)s|||%(vcodec)s|||%(width)s|||%(thumbnail)s|||%(duration_string)s|||%(duration)s|||%(filesize_approx)s|||%(height)s|||%(asr)s|||%(abr)s|||%(acodec)s|||%(audio_channels)s",
                    // Line 3: formats JSON for per-resolution file size
                    "--print", "%(formats.:.{height,filesize,filesize_approx,tbr,vbr,abr,acodec,vcodec,audio_channels})j",
                    "--playlist-items", "1",  // only process first item — gets count + metadata fast
                    "--impersonate", "chrome",
                    "--write-info-json",
                    "-o", infoJSONCachePath
                ]
                // Reuse a fresh cached info-json (written by a prior analyze of
                // this exact URL within the TTL window) instead of re-resolving
                // from the network -- this is what makes re-pasting an already-
                // analyzed link (or re-analyzing from History) return near-
                // instantly instead of repeating the full ~6-10s yt-dlp
                // extraction. --load-info-json fully replaces the URL argument
                // (yt-dlp ignores/warns on a URL when this flag is present), and
                // every --print template above reads from the same info dict
                // either way, so the existing parsing logic below needs no
                // changes to handle this path.
                let reusedCachePath = self.manager.cachedInfoJSONPath(for: url)
                if let cachePath = reusedCachePath {
                    analyzeArgs.append("--load-info-json")
                    analyzeArgs.append(cachePath)
                } else {
                    analyzeArgs.append(url)
                }
                proc.arguments = analyzeArgs
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(env["PATH"] ?? "")"
                proc.environment = env
                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError  = errPipe
                try? proc.run()
                // Registered synchronously (not via main.async) so a Cancel that
                // lands between run() and registration can't slip through:
                // onCancelAnalyze finds no process to kill in that window, only
                // records the id, and the old async registration then re-added
                // the entry afterward -- letting this yt-dlp run to completion
                // for a card that was already gone.
                if !registerAnalyzeProcess(proc, cardID: cardID) { group.leave(); return }
                // Read stderr concurrently to prevent pipe buffer deadlock.
                // Captured (not discarded) so a persistent-block signal like
                // HTTP 403 at analyze time can be detected and surfaced --
                // previously this text was read and thrown away, so analyze
                // failures were invisible.
                var errData1 = Data()
                let errSem = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    errData1 = errPipe.fileHandleForReading.readDataToEndOfFile()
                    errSem.signal()
                }
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                errSem.wait()
                // Check if this URL was cancelled while we were waiting
                var wasCancelled = false
                DispatchQueue.main.sync { wasCancelled = self.analyzeProcesses[cardID] == nil }
                if wasCancelled { group.leave(); return }
                var output = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                var lastStderr = String(data: errData1, encoding: .utf8) ?? ""

                // Fallback: if bestvideo* failed (audio-only source), retry with bestaudio
                if proc.terminationStatus != 0 || output.isEmpty {
                    let proc2 = Process()
                    proc2.executableURL = URL(fileURLWithPath: ytdlp)
                    var fallbackArgs = [
                        "--no-warnings", "--no-download",
                        // Same --no-simulate fix as the primary analyze call
                        // above -- otherwise this fallback's --write-info-json
                        // is silently a no-op too.
                        "--no-simulate",
                        "--yes-playlist", "--playlist-items", "1",
                        "--format", "bestaudio",
                        "--print", "%(playlist_count)s",
                        "--print", "%(title)s|||none|||0|||%(thumbnail)s|||%(duration_string)s|||%(duration)s|||%(filesize_approx)s|||0|||%(asr)s|||%(abr)s|||%(acodec)s|||%(audio_channels)s",
                        "--impersonate", "chrome",
                        "--write-info-json",
                        "-o", infoJSONCachePath
                    ]
                    fallbackArgs.append(url)
                    proc2.arguments = fallbackArgs
                    proc2.environment = env
                    let outPipe2 = Pipe(); let errPipe2 = Pipe()
                    proc2.standardOutput = outPipe2
                    proc2.standardError  = errPipe2
                    try? proc2.run()
                    if !registerAnalyzeProcess(proc2, cardID: cardID) { group.leave(); return }
                    var errData2 = Data()
                    let errSem2 = DispatchSemaphore(value: 0)
                    DispatchQueue.global().async {
                        errData2 = errPipe2.fileHandleForReading.readDataToEndOfFile()
                        errSem2.signal()
                    }
                    let outData2 = outPipe2.fileHandleForReading.readDataToEndOfFile()
                    proc2.waitUntilExit()
                    errSem2.wait()
                    var wasCancelled2 = false
                    DispatchQueue.main.sync { wasCancelled2 = self.analyzeProcesses[cardID] == nil }
                    if wasCancelled2 { group.leave(); return }
                    output = String(data: outData2, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    // Fallback's stderr replaces the primary attempt's --
                    // it's the more recent, more relevant failure reason
                    // once both attempts have actually run.
                    if let s2 = String(data: errData2, encoding: .utf8), !s2.isEmpty { lastStderr = s2 }
                }

                // A 403 here means yt-dlp couldn't even read the page/metadata
                // for this URL, on either attempt -- this is a hard block at
                // the source (bot detection, geo-lock, auth wall, etc.), not
                // a signed-CDN-URL race like the download-time 403 case.
                // There's nothing to retry: yt-dlp using --impersonate chrome
                // already tried its best browser-impersonation attempt and
                // still got 403'd, so surfacing it immediately (rather than
                // silently dropping the card) is the right call here.
                let stderrLower = lastStderr.lowercased()
                let analyzeIsForbidden = output.isEmpty && stderrLower.contains("403") &&
                    (stderrLower.contains("forbidden") || stderrLower.contains("http error 403"))

                var preview: LinkPreview? = nil
                if !output.isEmpty {
                    // Output: line 1 = playlist_count (or NA), line 2 = metadata, line 3+ = formats JSON
                    let outputLines = output.components(separatedBy: "\n")
                    let playlistLine = outputLines.first ?? ""
                    let playlistCount = Int(playlistLine.trimmingCharacters(in: .whitespaces)) ?? 0

                    // If it's a playlist, create a playlist card without full metadata parse
                    if playlistCount > 1 {
                        var lp = LinkPreview(
                            url: url, title: "Playlist (\(playlistCount) items)",
                            thumbnailURL: "", hasVideo: true, duration: "",
                            mediaMode: .videoAndAudio
                        )
                        lp.isPlaylist = true
                        lp.playlistCount = playlistCount
                        lp.isSelected = true
                        lock.lock(); results.append((i, lp)); lock.unlock()
                        DispatchQueue.main.async { self.analyzeProcesses.removeValue(forKey: cardID) }
                        group.leave()
                        return
                    }

                    let metaLine    = outputLines.count > 1 ? outputLines[1] : (outputLines.first ?? output)
                    let formatsJSON = outputLines.count > 2 ? outputLines[2...].joined(separator: "\n") : ""
                    let parts = metaLine.components(separatedBy: "|||")
                    let title        = parts.count > 0 ? parts[0].trimmingCharacters(in: .whitespacesAndNewlines) : "Unknown"
                    let vcodec       = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : "none"
                    let width        = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespacesAndNewlines) : "0"
                    let thumbnail    = parts.count > 3 ? parts[3].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    let duration     = parts.count > 4 ? parts[4].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    let durationSecs = parts.count > 5 ? (Int(parts[5].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) : 0
                    let fileSizeRaw  = parts.count > 6 ? parts[6].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    let heightRaw    = parts.count > 7 ? parts[7].trimmingCharacters(in: .whitespacesAndNewlines) : "0"
                    let asrRaw       = parts.count > 8 ? parts[8].trimmingCharacters(in: .whitespacesAndNewlines) : "0"
                    let abrRaw       = parts.count > 9 ? parts[9].trimmingCharacters(in: .whitespacesAndNewlines) : "0"
                    let acodecRaw    = parts.count > 10 ? parts[10].trimmingCharacters(in: .whitespacesAndNewlines) : "none"
                    let channelsRaw  = parts.count > 11 ? parts[11].trimmingCharacters(in: .whitespacesAndNewlines) : "0"
                    let fileSizeB    = Int(fileSizeRaw)  // yt-dlp returns bytes as int string, "NA" if unknown
                    let rawHeight    = Int(heightRaw) ?? 0
                    let sourceW      = Int(width) ?? 0
                    // Tier thresholds (2160/1440/1080/720/480) assume standard 16:9 framing.
                    // Wider-than-16:9 sources (e.g. ultrawide, cinematic crops) hit their true
                    // resolution tier at a shorter pixel height, so a strict height check
                    // under-classifies them (e.g. a real 4K-wide master reads as 1440p by height
                    // alone). Normalize by deriving an equivalent 16:9 height from width when the
                    // source is wider than 16:9, and use whichever is larger.
                    let heightFromWidth = sourceW > 0 ? (sourceW * 9 / 16) : 0
                    let sourceH      = max(rawHeight, heightFromWidth)
                    let sourceASR    = Int(asrRaw) ?? 0
                    let sourceABR    = Int(Double(abrRaw) ?? 0)

                    // Normalize a raw yt-dlp/ffmpeg codec string (which often includes profile/
                    // level suffixes like "av01.0.12M.08" or "avc1.640028") down to a short,
                    // human-readable family name matching Convert's ffprobe-derived labels.
                    func normalizeCodecFamily(_ raw: String) -> String? {
                        guard raw != "none", raw != "NA", !raw.isEmpty else { return nil }
                        let lower = raw.lowercased()
                        if lower.hasPrefix("av01") || lower.hasPrefix("av1") { return "AV1" }
                        if lower.hasPrefix("vp09") || lower.hasPrefix("vp9") { return "VP9" }
                        if lower.hasPrefix("vp08") || lower.hasPrefix("vp8") { return "VP8" }
                        if lower.hasPrefix("avc1") || lower.hasPrefix("h264") { return "H264" }
                        if lower.hasPrefix("hev1") || lower.hasPrefix("hvc1") || lower.hasPrefix("h265") { return "H265" }
                        if lower.hasPrefix("mp4a") { return "AAC" }
                        if lower.hasPrefix("opus") { return "OPUS" }
                        if lower.hasPrefix("mp3") { return "MP3" }
                        if lower.hasPrefix("vorbis") { return "VORBIS" }
                        if lower.hasPrefix("ac-3") || lower.hasPrefix("ac3") { return "AC3" }
                        if lower.hasPrefix("flac") { return "FLAC" }
                        // Fallback: strip anything after the first "." and uppercase
                        let base = raw.split(separator: ".").first.map(String.init) ?? raw
                        return base.uppercased()
                    }
                    let normVideoCodec = normalizeCodecFamily(vcodec)
                    // yt-dlp's audio_channels is a bare integer count (no LFE layout string
                    // like ffprobe's channel_layout), so map the common counts directly —
                    // 6ch and 8ch sources are virtually always 5.1 / 7.1 surround in practice.
                    func channelLabel(_ ch: Int) -> String? {
                        switch ch {
                        case 1: return "1.0"
                        case 2: return "2.0"
                        case 6: return "5.1"
                        case 8: return "7.1"
                        case 0: return nil
                        default: return "\(ch)ch"
                        }
                    }
                    // The top-level %(acodec)s / %(audio_channels)s reflect whatever format
                    // was actually SELECTED (bestvideo* → video-only stream → audio fields are
                    // always "none"/"NA"). Real audio codec/channel info only lives on the
                    // best audio-only stream inside the formats JSON, extracted further below.
                    var normAudioCodec = normalizeCodecFamily(acodecRaw)
                    var normChannelLabel = channelLabel(Int(channelsRaw) ?? 0)

                    let hasVideo     = vcodec != "none" && vcodec != "NA" && vcodec != "" && (Int(width) ?? 0) > 0
                    var lp = LinkPreview(
                        url: url, title: title, thumbnailURL: thumbnail,
                        hasVideo: hasVideo, duration: duration,
                        durationSeconds: durationSecs,
                        fileSizeBytes: (fileSizeB ?? 0) > 0 ? fileSizeB : nil,
                        mediaMode: hasVideo ? .videoAndAudio : .audioOnly
                    )
                    lp.sourceMaxHeight = sourceH
                    lp.sourceASR = sourceASR
                    lp.sourceABR = sourceABR
                    lp.sourceVideoCodec = hasVideo ? normVideoCodec : nil
                    // sourceAudioCodec / sourceChannelLabel assigned after formats JSON parsing
                    // below, since the real values come from the best audio-only stream there.
                    // Set per-format quality based on source capabilities
                    // kbps formats: cap at sourceABR
                    let kbpsQuality: AudioQuality = {
                        guard sourceABR > 0 else { return .q320 }
                        if sourceABR >= 320 { return .q320 }
                        if sourceABR >= 256 { return .q256 }
                        return .q128
                    }()
                    // FLAC: always Lossless (q320) — takes best available source
                    lp.audioQuality = kbpsQuality
                    lp.qualityByFormat = [
                        "mp3":  kbpsQuality,
                        "wav":  kbpsQuality,
                        "flac": .q320,      // always Lossless
                        "m4a":  .q320
                    ]
                    if hasVideo && sourceH > 0 {
                        lp.videoQuality = VideoQuality.highest(for: sourceH)
                    }
                    // Parse formats JSON to compute exact per-resolution file sizes
                    if !formatsJSON.isEmpty,
                       let jsonData = formatsJSON.data(using: .utf8),
                       let allFormats = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] {
                        // Best audio stream size
                        let audioStreams = allFormats.filter {
                            let vc = $0["vcodec"] as? String ?? ""
                            let ac = $0["acodec"] as? String ?? ""
                            return (vc == "none" || vc.isEmpty) && !ac.isEmpty && ac != "none"
                        }
                        let bestAudio = audioStreams.max {
                            let a = ($0["tbr"] as? Double ?? $0["abr"] as? Double ?? 0)
                            let b = ($1["tbr"] as? Double ?? $1["abr"] as? Double ?? 0)
                            return a < b
                        }
                        let audioBytes = bestAudio.map {
                            Int($0["filesize"] as? Double ?? $0["filesize_approx"] as? Double ?? 0)
                        } ?? 0
                        // Real audio codec/channel info lives on the best audio-only stream
                        // (the top-level %(acodec)s reflects the video-only selected format).
                        if let bestAudio {
                            let rawAc = bestAudio["acodec"] as? String ?? ""
                            if let cleaned = normalizeCodecFamily(rawAc) { normAudioCodec = cleaned }
                            let ch = bestAudio["audio_channels"] as? Int ?? Int("\(bestAudio["audio_channels"] ?? "")") ?? 0
                            if let label = channelLabel(ch) { normChannelLabel = label }
                        }
                        // Per resolution cap: best video stream + best audio stream
                        for cap in [2160, 1440, 1080, 720, 480] {
                            let videoStreams = allFormats.filter {
                                let h   = $0["height"] as? Int ?? 0
                                let vc  = $0["vcodec"] as? String ?? ""
                                return h > 0 && h <= cap && !vc.isEmpty && vc != "none"
                            }
                            if let bestVid = videoStreams.max(by: {
                                let scoreA = (($0["height"] as? Int ?? 0) * 100000) + Int($0["tbr"] as? Double ?? $0["vbr"] as? Double ?? 0)
                                let scoreB = (($1["height"] as? Int ?? 0) * 100000) + Int($1["tbr"] as? Double ?? $1["vbr"] as? Double ?? 0)
                                return scoreA < scoreB
                            }) {
                                let vidBytes = Int(bestVid["filesize"] as? Double ?? bestVid["filesize_approx"] as? Double ?? 0)
                                if vidBytes > 0 || audioBytes > 0 {
                                    lp.fileSizeByQuality[cap] = vidBytes + audioBytes
                                }
                            }
                        }
                    }
                    lp.sourceAudioCodec = normAudioCodec
                    lp.sourceChannelLabel = normChannelLabel
                    // Pre-fetch thumbnail into URL cache so AsyncImage renders instantly
                    if let thumbURL = URL(string: lp.thumbnailURL) {
                        _ = try? Data(contentsOf: thumbURL)
                    }
                    preview = lp
                } else if analyzeIsForbidden {
                    // Surface the block immediately instead of letting the
                    // card silently disappear -- there's no title/thumbnail
                    // to show since yt-dlp never got a readable response,
                    // but the user needs to know THIS specific link is
                    // blocked at the source rather than just vanishing with
                    // no explanation.
                    var lp = LinkPreview(
                        url: url, title: url, thumbnailURL: "",
                        hasVideo: false, duration: "",
                        mediaMode: .audioOnly
                    )
                    lp.analyzeError = "Blocked by source (HTTP 403) — this link can't be read, even with browser impersonation."
                    lp.analyzeErrorIsForbidden = true
                    preview = lp
                } else {
                    // Empty output and not a detected 403 -- most commonly
                    // an unsupported/incompatible source (a syntactically
                    // valid http(s) URL that isn't a host yt-dlp knows how
                    // to read). dropAllLinesAreURLs only checks URL syntax,
                    // not whether the host is actually supported, so this
                    // is the first point anything can catch that case.
                    // Previously this branch just deleted the placeholder
                    // card with no explanation -- the card would vanish
                    // and the paste field (already cleared when the card
                    // was queued) had nothing left to show either, so the
                    // failure was invisible. Surfacing it the same way as
                    // the 403 case gives the user a persistent, specific
                    // reason instead of a link that just silently disappears.
                    var lp = LinkPreview(
                        url: url, title: url, thumbnailURL: "",
                        hasVideo: false, duration: "",
                        mediaMode: .audioOnly
                    )
                    lp.analyzeError = "Couldn't read this link — the source may not be supported."
                    preview = lp
                }
                lock.lock()
                results.append((i, preview))
                lock.unlock()
                // Push this URL's result to the UI the instant IT finishes,
                // rather than waiting for every pasted URL in the batch to
                // finish (the old group.notify-only path). Each yt-dlp
                // metadata-only call already resolves independently and
                // often in under a second, so cards should flip from
                // "Analyzing…" to their real title/thumbnail one at a time
                // instead of all sitting at "Analyzing…" until the slowest
                // link in the batch finally completes.
                DispatchQueue.main.async {
                    self.analyzeProcesses.removeValue(forKey: cardID)
                    if var realCard = preview {
                        // Slower, gentler settle than the old 0.4s spring --
                        // the user wants the analyze-to-preview handoff to
                        // read as a smooth blend, not a snap.
                        withAnimation(.easeInOut(duration: 0.55)) {
                            // Matched by the placeholder's own id (cardID),
                            // not url+isPending -- when the same link is
                            // pasted multiple times at once, every one of
                            // those pending cards shares the same url, so
                            // url-based matching always resolved to
                            // whichever same-url card was first in the
                            // array, collapsing all the duplicates onto
                            // one card as results landed. The id is unique
                            // per pasted instance even when the url repeats.
                            if let idx = self.linkPreviews.firstIndex(where: { $0.id == cardID }) {
                                // Keep the pending placeholder's identity so
                                // SwiftUI updates the existing card view in
                                // place instead of removing it and mounting
                                // a new one -- a same-identity update
                                // cross-fades cleanly, while a swapped
                                // identity forces the new view's glass
                                // background to build up from scratch
                                // (the light-grey-then-dark flash).
                                realCard.id = cardID
                                self.linkPreviews[idx] = realCard
                            }
                            // NOTE: deliberately no `else { append }` here anymore.
                            // If cardID isn't found, the user already cleared/
                            // cancelled this specific card while yt-dlp was still
                            // running in the background (Process.terminate() sends
                            // SIGTERM, which yt-dlp doesn't always honor instantly
                            // if it's mid-network-call -- so the process can still
                            // run to completion and land here well after the card
                            // was removed). Re-appending unconditionally used to
                            // silently resurrect a card the user had just cleared.
                            // Dropping the result here is correct: the user's
                            // clear action is the source of truth, not a late
                            // straggling process result.
                        }
                        // No `else` branch anymore -- preview is never nil now.
                        // Every path above (success, 403-forbidden, generic
                        // empty-output failure) constructs a LinkPreview, so
                        // there's no longer a case where this card should be
                        // deleted outright rather than updated in place with
                        // an error message. The old else-branch silently
                        // removed the placeholder for any non-403 failure,
                        // which is exactly what made an incompatible-source
                        // link vanish with zero explanation.
                    }
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            self.isAnalyzing = false
            for id in ids {
                self.analyzeProcesses.removeValue(forKey: id)
                // Any id from THIS batch left in cancelledAnalyzeIDs at this
                // point was never consumed by the queued-cancel check above
                // (e.g. cancelled after its process already started, which
                // is handled separately via analyzeProcesses) -- clear it so
                // the set doesn't grow unbounded across repeated batches.
                self.cancelledAnalyzeIDs.remove(id)
            }
            // Per-URL updates above already applied every card as it
            // finished. This just cleans up anything that's somehow still
            // pending once THIS batch is done (shouldn't normally happen,
            // but guards against a card getting stuck forever if a result
            // was missed). Scoped to THIS batch's own `ids` set only --
            // an unscoped `removeAll { $0.isPending }` here used to sweep
            // every still-pending card in the entire list, including ones
            // queued by a separate, still-in-flight analyzeURL() call.
            // Each paste-and-analyze tap spawns its OWN DispatchGroup, so
            // pasting link A, then link B, then link C in quick succession
            // (each still analyzing when the next is pasted) produced
            // three concurrent, independent group.notify callbacks all
            // closing over the same shared linkPreviews array -- whichever
            // batch's network call finished first would wipe out the
            // other two batches' still-legitimately-analyzing placeholder
            // cards the instant its own notify fired, well before their
            // own yt-dlp processes had a chance to complete. Restricting
            // the sweep to this batch's own ids fixes that without
            // touching the per-URL apply-on-completion logic above, which
            // was already correctly scoped by cardID.
            let batchIDs = Set(ids)
            withAnimation(.spring(response: 0.35)) {
                self.linkPreviews.removeAll { $0.isPending && batchIDs.contains($0.id) }
            }
            // Reconstruct the successful (non-error) results for the
            // batch-level summary badge below -- per-URL updates above
            // already applied each card to the UI as it finished, but the
            // "was this batch video, audio, or mixed" badge still needs a
            // full-batch view once everything's done.
            let sorted = results.sorted { $0.0 < $1.0 }.compactMap { $0.1 }.filter { $0.analyzeError == nil }
            let hasAny  = !sorted.isEmpty
            let hasVid  = sorted.contains { $0.hasVideo }
            let allVid  = sorted.allSatisfy { $0.hasVideo }
            // NOTE: no longer touches self.urlText here. Every current call
            // site passes an explicit `urls:`/`ids:` override and already
            // clears urlText itself the moment its own placeholders are
            // queued (see the paste/analyze tap handler above and
            // HistoryView's onAnalyze), so by the time THIS closure runs,
            // urlText may already hold a completely different link the
            // user pasted for a newer, still-in-flight batch. Clearing it
            // here unconditionally used to blank out that newer paste out
            // from under the user while an older batch's slower network
            // call finally caught up.
            if !hasAny {
                self.analyzeResult = .unknown
            } else {
                if allVid {
                    self.analyzeResult = .videoAndAudio
                } else if !hasVid {
                    self.analyzeResult = .audioOnly
                } else {
                    self.analyzeResult = .videoAndAudio  // mixed — show generic badge
                }
            }
        }
    }

    var downloadButton_label: String {
        let checkedCount = selectedPreviews.count
        if checkedCount > 1  { return "Download \(checkedCount) Items" }
        if checkedCount == 1, let p = selectedPreviews.first {
            switch p.mediaMode {
            case .audioOnly:     return "Download as \(p.audioFormat.label)"
            case .videoAndAudio: return "Download \(p.videoFormat.label) + Audio"
            }
        }
        let lineCount = urlText.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        if lineCount > 1 { return "Download \(lineCount) Items" }
        switch config.mediaMode {
        case .audioOnly:     return "Download as \(config.format.label)"
        case .videoAndAudio: return "Download \(config.videoFormat.label) + Audio"
        }
    }

    func download() {
        // If we have analyzed previews, download only the checked ones.
        // Outside Select mode every queued preview counts as selected
        // (checkboxes are hidden, so nothing is excluded) — same convention
        // as Convert's selectedJobs.
        if !linkPreviews.isEmpty {
            let selected = selectedPreviews
            guard !selected.isEmpty else { return }
            let selectedIDs = Set(selected.map { $0.id })
            for i in linkPreviews.indices where selectedIDs.contains(linkPreviews[i].id) && linkPreviews[i].downloadID == nil {
                let preview = linkPreviews[i]
                let itemConfig = config.detached(mediaMode: preview.mediaMode, videoQuality: preview.videoQuality,
                                                 videoFormat: preview.videoFormat, format: preview.audioFormat,
                                                 quality: preview.audioQuality)
                // add() returns the UUID of the newly created Download
                let snap = DownloadSnapshot(
                    title:            preview.title,
                    thumbnailURL:     preview.thumbnailURL,
                    hasVideo:         preview.hasVideo,
                    duration:         preview.duration,
                    durationSeconds:  preview.durationSeconds,
                    fileSizeBytes:    preview.fileSizeBytes,
                    sourceMaxHeight:  preview.sourceMaxHeight,
                    sourceASR:        preview.sourceASR,
                    sourceABR:        preview.sourceABR,
                    sourceVideoCodec: preview.sourceVideoCodec,
                    sourceAudioCodec: preview.sourceAudioCodec,
                    sourceChannelLabel: preview.sourceChannelLabel,
                    qualityByFormat:  preview.qualityByFormat,
                    fileSizeByQuality: preview.fileSizeByQuality
                )
                if let newID = manager.add(urls: [preview.url], config: itemConfig, thumbnailURL: preview.thumbnailURL, isPlaylist: preview.isPlaylist, snapshot: snap) {
                    linkPreviews[i].downloadID = newID
                }
            }
            return
        }
        // Fallback: plain URL list (no analyze)
        let urls = urlText.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !urls.isEmpty else { return }
        manager.add(urls: urls, config: config)
    }

    /// Shared shape for Cancelled's "Redownload", Error's "Retry", and Done's
    /// "Redownload" -- same icon/action/no-hover-growth treatment, only the
    /// label and tint differ per status.
    @ViewBuilder
    private func restoreActionButton(label: String, tint: Color, dl: Download, replacingID: UUID) -> some View {
        GlassButton(label: label, icon: "arrow.uturn.down", tint: tint, scaleOverride: (hover: 1.0, press: DesignTokens.Interactive.scalePress)) {
            restorePreviewCard(from: dl, replacing: replacingID)
        }
    }

    /// Restore a full PreviewCard from a Download's stored analyze snapshot.
    /// Called by Retry / Redownload / cancelled retry — avoids re-analyzing
    /// and preserves title, thumbnail, resolution options, and quality settings.
    func restorePreviewCard(from dl: Download, replacing oldID: UUID) {
        let snap = dl.snapshot
        var lp = LinkPreview(
            url: dl.url,
            title: snap.title.isEmpty ? dl.title : snap.title,
            thumbnailURL: snap.thumbnailURL.isEmpty ? dl.thumbnailURL : snap.thumbnailURL,
            hasVideo: snap.hasVideo,
            duration: snap.duration,
            durationSeconds: snap.durationSeconds,
            fileSizeBytes: snap.fileSizeBytes,
            mediaMode: dl.mediaMode
        )
        lp.sourceMaxHeight   = snap.sourceMaxHeight
        lp.sourceASR         = snap.sourceASR
        lp.sourceABR         = snap.sourceABR
        lp.sourceVideoCodec  = snap.sourceVideoCodec
        lp.sourceAudioCodec  = snap.sourceAudioCodec
        lp.sourceChannelLabel = snap.sourceChannelLabel
        lp.videoQuality      = snap.sourceMaxHeight > 0 ? VideoQuality.highest(for: snap.sourceMaxHeight) : dl.videoQuality
        lp.videoFormat       = dl.videoFormat
        lp.audioFormat       = dl.format
        lp.audioQuality      = dl.audioQuality
        lp.qualityByFormat   = snap.qualityByFormat
        lp.fileSizeByQuality = snap.fileSizeByQuality
        lp.isSelected        = true
        withAnimation(.spring(response: 0.25)) {
            manager.downloads.removeAll { $0.id == dl.id }
            if let idx = linkPreviews.firstIndex(where: { $0.id == oldID }) {
                linkPreviews[idx] = lp
            } else {
                linkPreviews.append(lp)
            }
        }
    }

    func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            // Try public.url first (dragging from browser address bar)
            if provider.hasItemConformingToTypeIdentifier("public.url") {
                provider.loadItem(forTypeIdentifier: "public.url", options: nil) { item, _ in
                    let str: String?
                    if let url = item as? URL { str = url.absoluteString }
                    else if let data = item as? Data { str = String(data: data, encoding: .utf8) }
                    else { str = nil }
                    if let s = str?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                        DispatchQueue.main.async {
                            self.urlText += (self.urlText.isEmpty ? "" : "\n") + s
                        }
                    }
                }
            } else {
                provider.loadItem(forTypeIdentifier: "public.plain-text", options: nil) { item, _ in
                    if let data = item as? Data, let s = String(data: data, encoding: .utf8) {
                        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        DispatchQueue.main.async {
                            self.urlText += (self.urlText.isEmpty ? "" : "\n") + trimmed
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Shimmer Bar

struct ShimmerBar: View {
    let width: CGFloat
    var color: Color = .white
    var glow: Bool = false
    var duration: Double = 1.4
    @State private var offset: CGFloat = -1.0

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: color.opacity(0.08), location: 0),
                        .init(color: color.opacity(0.08), location: max(0, offset - 0.25)),
                        .init(color: color.opacity(glow ? 0.9 : 0.55), location: offset),
                        .init(color: color.opacity(0.08), location: min(1, offset + 0.25)),
                        .init(color: color.opacity(0.08), location: 1),
                    ]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 4)
            .shadow(color: glow ? color.opacity(0.6) : .clear, radius: glow ? 6 : 0, x: 0, y: 0)
            .onAppear {
                withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                    offset = 2.0
                }
            }
    }
}

// MARK: - Bouncing Dots

/// Three small dots that bounce in sequence -- used in place of a progress
/// bar for the brief pre-download gap (process launching, URL still being
/// resolved) where there's no real percentage yet but the UI still needs to
/// read as "actively working", not frozen. Clearer at a glance than a subtle
/// gradient sweep on a 4pt bar.
struct BouncingDots: View {
    var color: Color = .green
    var size: CGFloat = 4
    @State private var animate = false

    var body: some View {
        HStack(spacing: size * 0.9) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(color)
                    .frame(width: size, height: size)
                    .opacity(animate ? 1.0 : 0.35)
                    .scaleEffect(animate ? 1.0 : 0.6)
                    .animation(
                        .easeInOut(duration: 0.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.18),
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
    }
}

// MARK: - Download Info Chip Row
// Shared between the in-progress and finished download card states, and
// styled identically to the History tab's chips (same HistoryChip view).
struct ChipRow: View {
    let chips: [ChipData]
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(chips, id: \.self) { chip in
                HistoryChip(label: chip.label, value: chip.value, color: chip.color, icon: chip.icon,
                            icon2: chip.icon2, value2: chip.value2)
            }
        }
    }
}

/// A row of "choose one" chips. Equal-width and filling the row when they
/// fit; when they don't (a narrow window), they wrap onto more lines at their
/// natural widths instead of every label truncating to "H.2…".
struct OptionRow<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: spacing) { content() }
            FlowLayout(spacing: spacing) { content() }
        }
    }
}

/// Wraps children onto new lines when the row runs out of horizontal space —
/// each chip keeps its own fixed size (no internal text wrapping), only the
/// row itself wraps. Used by ChipRow so Download/Convert info chips never
/// get squeezed into vertical text columns.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            // Clamped to the row: a chip wider than the whole row (a long
            // "MP4 · H264 · 24fps · 1920×1080" in a narrow column) is
            // truncated by its own text rather than overflowing the row and
            // overlapping whatever sits beside it.
            let ideal = subview.sizeThatFits(.unspecified)
            let size = CGSize(width: min(ideal.width, maxWidth), height: ideal.height)
            if rowWidth > 0 && rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                totalWidth = max(totalWidth, rowWidth)
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        totalWidth = max(totalWidth, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            let size = CGSize(width: min(ideal.width, maxWidth), height: ideal.height)
            if x > bounds.minX && x + size.width > bounds.minX + maxWidth {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: size.width, height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Selector Chip
// Unified chip for mode/format/quality selection. Two layouts:
// - icon set: horizontal icon+label (formerly ModeChip)
// - icon nil: vertical label+note, stacked (formerly FormatChip / QualityChip)
// No scaleEffect — these render in tightly-packed HStacks where scale caused
// hover growth to overlap neighboring chips. Selection/hover feedback comes
// from glow + border + background only.

/// Small legend explaining the green (positive/native/original) vs amber (re-encode) dot
/// shown on format/codec chips. `positiveLabel` reads "Native" for Download's format rows
/// (true remux-native containers) and "Original" for Convert's codec rows (matches source).
func nativeLegend(positiveLabel: String = "Native", showReencodeHint: Bool = true) -> some View {
    HStack(spacing: 10) {
        HStack(spacing: 4) {
            Circle().fill(DesignTokens.Accent.success).frame(width: 5, height: 5)
            Text(positiveLabel).font(.appMono(size: 8.5)).foregroundColor(.white.opacity(DesignTokens.Text.disabled))
        }
        if showReencodeHint {
            HStack(spacing: 4) {
                Circle().fill(DesignTokens.Accent.warning).frame(width: 5, height: 5)
                Text("Re-encodes").font(.appMono(size: 8.5)).foregroundColor(.white.opacity(DesignTokens.Text.disabled))
            }
        }
    }
}

struct SelectorChip: View {
    let label: String
    var icon: String? = nil
    var note: String = ""
    let isSelected: Bool
    var tint: Color = DesignTokens.Accent.primary
    /// nil = no badge shown. true = "Native" (green dot), false = "Re-encode" (amber dot).
    var nativeBadge: Bool? = nil
    let action: () -> Void
    @State private var hovering = false
    @State private var glowPhase = false
    @Environment(\.contentColumnWidth) private var columnWidth
    /// The sub-note ("Universal compatibility, QuickTime-ready") is dropped in
    /// a narrow column, where it forced every chip onto its own line; it stays
    /// available as the tooltip.
    private var showNote: Bool { !note.isEmpty && !(columnWidth > 0 && columnWidth < WindowLayout.narrowColumnBreakpoint) }

    var body: some View {
        Button(action: action) {
            // One layout for every chip regardless of whether it carries an
            // icon or a note -- previously icon-chips (Video + Audio, Audio
            // Only) used a tight HStack while plain chips (MP4, 4K, etc.)
            // used a width-filling VStack, so sibling rows of the same
            // "choose one" pattern rendered at visibly different scales.
            // Every chip now fills its row slot the same way.
            VStack(spacing: 2) {
                HStack(spacing: 5) {
                    if let icon = icon {
                        Image(systemName: icon)
                            .font(.appMono(size: 11, weight: .semibold))
                    }
                    if let native = nativeBadge {
                        Circle()
                            .fill(native ? DesignTokens.Accent.success : DesignTokens.Accent.warning)
                            .frame(width: 5, height: 5)
                    }
                    Text(label)
                        .font(.appMono(size: 12, weight: .semibold))
                }
                .foregroundColor(isSelected ? tint : .white.opacity(hovering ? DesignTokens.Text.primary : DesignTokens.Text.tertiary))
                if showNote {
                    Text(note)
                        .font(.appMono(size: 9))
                        .foregroundColor(isSelected ? tint.opacity(0.75) : .white.opacity(hovering ? DesignTokens.Text.tertiary : DesignTokens.Text.disabled))
                        .lineLimit(1)
                }
            }
            // Horizontal padding lives inside the chip so that when a row wraps
            // (see OptionRow) the chips hug their labels with room to spare;
            // in an equal-width row the extra padding is invisible.
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .padding(.vertical, showNote ? 8 : 6)
            .background(
                ZStack {
                    // Tinted base -- NOT its own VisualEffectBlur. Every chip
                    // here sits directly on a parent glassCard (the card's
                    // settings section), which already provides a live
                    // backdrop blur; stacking a second, independent
                    // NSVisualEffectView per chip (several per card: format +
                    // quality + mode) multiplied the number of live blur
                    // layers the compositor had to recompute on every resize
                    // frame for a visual difference this opaque a tint (0.93)
                    // made negligible. The parent's blur shows through this
                    // tint exactly as before.
                    Color.black.opacity(DesignTokens.Glass.blackTint)
                    // One selected-state treatment everywhere: a soft tint
                    // wash, not a solid fill and not a plain outline-only
                    // look -- previously icon-chips used a flat opacity fill
                    // while plain chips used a gradient wash, two different
                    // "selected" languages for the same chip concept.
                    //
                    // The two states are separate layers with explicit
                    // transitions: the rest wash swaps instantly and the tint
                    // gradient grows/shrinks (chipFill). Left implicit, SwiftUI
                    // cross-faded them, passing through a washed-out grey.
                    if isSelected {
                        LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.12)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                            .transition(.chipFill())
                    } else {
                        Color.white.opacity(hovering ? DesignTokens.Interactive.fillHover : DesignTokens.Interactive.fillRest)
                            .transition(.identity)
                    }
                    DitherNoise(opacity: 0.035)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous)
                    .stroke(
                        isSelected
                            ? tint.opacity(glowPhase ? DesignTokens.Interactive.strokeGlow : 0.6)
                            : Color.white.opacity(hovering ? (glowPhase ? DesignTokens.Interactive.strokeHover + 0.05 : DesignTokens.Interactive.strokeHover) : DesignTokens.Interactive.strokeRest),
                        lineWidth: (isSelected || hovering) ? 1.0 : 0.5
                    )
                    // Selected chips carry a resting ambient glow, not just an
                    // on-hover one -- Flighty/Siri-style liquid glass always
                    // reads as lit from within, even when idle. Previously this
                    // was .clear at rest, so a selected MP4/4K chip looked
                    // identical whether the pointer was near it or not.
                    .shadow(color: isSelected ? tint.opacity(glowPhase ? DesignTokens.Interactive.glowShadowHover : 0.32) : .clear, radius: isSelected ? 6 : 0)
            )
        }
        .buttonStyle(.plain)
        .onHover { h in
            hovering = h
            if h {
                withAnimation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true)) { glowPhase = true }
            } else if !isSelected {
                withAnimation(.easeOut(duration: 0.2)) { glowPhase = false }
            }
        }
        .onAppear { if isSelected { startRestingGlow() } }
        .onChange(of: isSelected) { selected in
            if selected {
                startRestingGlow()
            } else if !hovering {
                withAnimation(.easeOut(duration: 0.2)) { glowPhase = false }
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.spring(response: 0.2), value: isSelected)
        .help(!note.isEmpty && !showNote ? note : "")
    }

    /// Slow ambient pulse for the selected state, independent of hover --
    /// keeps a chosen chip reading as "lit" the whole time it's selected,
    /// not just when the pointer happens to be over it.
    private func startRestingGlow() {
        withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
            glowPhase = true
        }
    }
}

// MARK: - Glass Button

/// Pill-shaped label+icon button. Thin wrapper around GlassInteractive so it
/// shares the exact same glass material, hover/press/glow physics, and
/// contrast tokens as every other interactable in the app -- only the
/// icon+label content and a few layout knobs (fitContent, fillHeight,
/// verticalPadding) are specific to this call-site shape.
struct GlassButton: View {
    let label: String
    let icon: String
    var tint: Color = .white
    var verticalPadding: CGFloat = 6
    // Only overridden for call sites (like the embedded Paste & Analyze
    // pill) that need more breathing room around the icon/label than the
    // default gives -- every existing caller keeps the original 10pt.
    var horizontalPadding: CGFloat = 10
    var fillHeight: Bool = false
    var fitContent: Bool = false   // when true, button hugs its label/icon instead of stretching to fill its container
    var isLoading: Bool = false
    var disabled: Bool = false     // when true, dims the button and blocks interaction/hover glow
    // Passthrough to GlassInteractive -- true when this button is an inset
    // control living inside another glass surface (e.g. Paste & Analyze
    // inside urlCard's own capsule) so it doesn't paint a second
    // independent blur/tint/stroke on top of the parent's.
    var embedded: Bool = false
    // Passthrough to GlassInteractive -- lets an embedded pill show a
    // resting accent wash (isActive-style fill even when not hovered),
    // since embedded mode has no independent border to signal "this is
    // a button" on its own.
    var activeFillOverride: (rest: Double, active: Double, hover: Double, press: Double)? = nil
    // Passthrough to GlassInteractive -- see its declaration for details.
    var embeddedGlowStroke: Bool = false
    var scaleOverride: (hover: CGFloat, press: CGFloat)? = nil
    // Same Tron-style traveling light beam used on the Analyze card's rim
    // (see GlassCard.isActive/RimBeam) -- reserved for a button that
    // represents real work actively in progress (checking for updates,
    // converting, downloading), not a resting decoration. cornerRadius is
    // passed a large constant below since this button's shape is a
    // capsule, not a fixed-radius rounded rect -- RimBeam's own rim math
    // already clamps radius to min(width, height)/2, so any sufficiently
    // large value traces a true capsule regardless of this button's size.
    var showRimBeam: Bool = false
    let action: () -> Void

    var body: some View {
        GlassInteractive(shape: .capsule, tint: tint, isActive: embedded, disabled: disabled, activeFillOverride: activeFillOverride, embedded: embedded, embeddedGlowStroke: embeddedGlowStroke, scaleOverride: scaleOverride, action: action) {
            HStack(spacing: isLoading ? 6 : 4) {
                if isLoading {
                    // frame BEFORE scaleEffect so the 10x10 layout box is
                    // established first, then the spinner's rendered
                    // content shrinks to fit inside it -- the old
                    // scaleEffect-then-frame order left the shrunk
                    // spinner's visual bleeding past its own layout box
                    // and hugging/overlapping the label text, since
                    // scaleEffect only resizes the render, not the layout
                    // frame it's clipped into.
                    ProgressView().frame(width: 10, height: 10).scaleEffect(0.55)
                } else {
                    Image(systemName: icon).font(.appMono(size: 10))
                }
                Text(label)
                    .font(.appMono(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: fitContent ? nil : .infinity)
            .padding(.horizontal, horizontalPadding).padding(.vertical, verticalPadding)
            .frame(maxHeight: fillHeight ? .infinity : nil)
        }
        .overlay {
            if showRimBeam {
                RimBeam(cornerRadius: 999)
            }
        }
    }
}


