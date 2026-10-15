import SwiftUI
import AppKit
import UserNotifications
import UniformTypeIdentifiers
import QuickLookThumbnailing
import CryptoKit
import Sparkle

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
        case .mp3:  return "Universal Compatibility"
        case .m4a:  return "Not Good for DaVinci Resolve"
        case .wav:  return "Best for DaVinci Resolve"
        case .flac: return "Lossless, Large Files"
        }
    }
    /// True if this format is a direct stream copy from the source (no ffmpeg decode/encode pass).
    /// Only M4A passthrough avoids -x entirely — MP3/WAV/FLAC all re-encode via ffmpeg.
    var isNative: Bool { self == .m4a }
}

enum AudioQuality: String, CaseIterable, Identifiable {
    // auto: matches the source's own real bitrate exactly, whatever that is -- added
    // because the fixed presets below have no slot for a common real-world bitrate like
    // SoundCloud's 160kbps AAC, which used to silently round down to 128kbps and hide the
    // 32kbps of real headroom between them (reported live, confirmed against yt-dlp's own
    // --list-formats). Mirrors Convert's own "Auto" bitrate step (see DropdownBitrateField).
    case auto = "auto", q320 = "320K", q256 = "5", q128 = "9"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto"  // real call sites replace this with the detected kbps
        case .q320: return "320kbps"
        case .q256: return "256kbps"
        case .q128: return "128kbps"
        }
    }
    var flacLabel: String {
        switch self {
        // Unreachable in practice -- FLAC's own ladder never offers .auto (sample rate,
        // not bitrate, is the meaningful axis there; see downloadAudioQualityOptions).
        case .auto: return "Lossless"
        case .q320: return "Lossless"
        case .q256: return "96kHz"  // hi-res
        case .q128: return "48kHz"   // standard (YouTube/SoundCloud native)
        }
    }
    // Format selector override for FLAC (sample rate filter)
    var flacFormatSelector: String {
        switch self {
        case .auto: return "bestaudio"  // unreachable -- see flacLabel
        case .q320: return "bestaudio"
        case .q256: return "bestaudio[asr>=96000]/bestaudio"
        case .q128: return "bestaudio[asr>=48000]/bestaudio"
        }
    }
    /// kbps for file size estimation. .auto has no fixed number of its own -- callers with
    /// a known sourceABR should use that directly instead of this fallback.
    var kbps: Int {
        switch self { case .auto: return 128; case .q320: return 320; case .q256: return 256; case .q128: return 128 }
    }
    /// yt-dlp --audio-quality argument.
    /// MP3 VBR scale: 0 = best (~245kbps), 5 = ~130kbps, 9 = worst.
    /// For CBR: pass "320K", "256K", "128K" — ffmpeg interprets these as fixed bitrates.
    /// Only has effect when -x / --extract-audio is used (i.e. mp3, wav, flac — NOT m4a passthrough).
    /// .auto's real value is computed at the call site (startDownload) from the source's
    /// actual detected bitrate -- this fallback only applies if that's somehow unknown.
    var ytdlpAudioQuality: String {
        // CBR bitrates passed directly to ffmpeg — "0" is VBR ~245kbps, not 320
        switch self { case .auto: return "128K"; case .q320: return "320K"; case .q256: return "256K"; case .q128: return "128K" }
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
    // MOV was once hidden for AV1/VP9 sources: ffmpeg's mov muxer can't remux those
    // codecs (unlike mp4's, which can), so --merge-output-format mov silently produced
    // a .mp4 anyway while still showing "MOV" — a misleading option, hidden via
    // isAvailable(forSourceVideoCodec:) rather than offered and lying about the
    // container. Now offered unconditionally: the download step merges an incompatible
    // source into .mp4 instead (the container mov can't take, mp4 already proven to
    // handle for any codec — see VideoQuality.formatSelector(for:)), and
    // reencodeIfNeeded transcodes that to a genuine H.264/HEVC .mov afterward — both are
    // fully native to .mov, so that step is a real remux, not a workaround. (Convert
    // tab's MOV is unaffected — that path always re-encodes and is a separate enum.)
    case mp4, mov, mkv, webm
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
    var note: String {
        switch self {
        case .mp4:  return "Universal Compatibility, QuickTime-Ready"
        case .mov:  return "QuickTime, Final Cut Pro Native"
        case .mkv:  return "Best Quality Container"
        case .webm: return "Web Optimized"
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
        case .mov:  return ["--merge-output-format", "mov"]
        case .mkv:  return ["--merge-output-format", "mkv"]
        case .webm: return ["--merge-output-format", "webm"]
        }
    }
}

/// Which hardware encoder reencodeIfNeeded (DownloadManager) targets when a source has no
/// stream compatible with the requested output container (see that function's own doc
/// comment). H.264 and HEVC are both Apple Silicon's dedicated videotoolbox encode blocks, not
/// software -- HEVC is NOT faster to encode than H.264 on the same hardware (its coding tools
/// are inherently more complex even accelerated), its advantage is a meaningfully smaller file
/// at the same visual quality. H.264 stays the default: it is also readable by older/non-Apple
/// software HEVC sometimes isn't. .off skips the step entirely, keeping the source's original
/// AV1/VP9 stream even though that means the file may not open in Preview/QuickTime -- for a
/// user who already knows that and would rather keep the untouched original (e.g. it's headed
/// to an app that decodes AV1/VP9 fine, or they just don't want ANY re-encode loss).
enum ReencodeCodec: String, CaseIterable, Identifiable {
    case off, h264, hevc
    var id: String { rawValue }
    var label: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        case .off:  return "Off"
        }
    }
    var note: String {
        switch self {
        case .h264: return "Fastest, Plays Everywhere"
        case .hevc: return "Smaller File, Same Quality"
        case .off:  return "Keep Original — May Not Open in Preview/QuickTime"
        }
    }
    var videotoolboxEncoder: String? {
        switch self {
        case .h264: return "h264_videotoolbox"
        case .hevc: return "hevc_videotoolbox"
        case .off:  return nil
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

/// The common marketing name for one of the fixed resolution-ladder tiers (2160/1440/1080/720/
/// 480 -- VideoQuality.maxHeight's own values, and Convert's identical ladder) -- shared by
/// Download's RESOLUTION picker and Convert's, so the same height always reads the same way in
/// both places. "4K"/"2K" only where that nickname is unambiguous; 1080 and below use their
/// well-known name alone.
func resolutionMarketingName(forMaxHeight height: Int) -> String? {
    switch height {
    case 2160: return "4K Ultra HD"
    case 1440: return "2K Quad HD"
    case 1080: return "Full HD"
    case 720:  return "HD"
    case 480:  return "SD"
    default:   return nil
    }
}

/// Same marketing names as `resolutionMarketingName(forMaxHeight:)`, but bucketed by a >=
/// threshold rather than an exact match -- for a SOURCE's own, real (often non-ladder-exact)
/// height, not one of the fixed ladder tiers a picker actually offers. Matches
/// `sourceResolutionLabel`'s/`VideoQuality.highest(for:)`'s own >=2160 convention. Used for
/// "Same as Source" subtext (Convert's RESOLUTION field): a 3840x2160 source should read "4K
/// Ultra HD", not the raw "3840x2160" dimension string (reported live).
func sourceResolutionMarketingName(_ height: Int) -> String? {
    guard height > 0 else { return nil }
    switch height {
    case 2160...:    return "4K Ultra HD"
    case 1440..<2160: return "2K Quad HD"
    case 1080..<1440: return "Full HD"
    case 720..<1080:  return "HD"
    case 480..<720:   return "SD"
    default:          return nil
    }
}

/// Even pixel count, the way real encodes are sized (1920x1080, 854x480, ...).
private func evenPixels(_ value: Double) -> Int { max(2, Int((value / 2).rounded()) * 2) }

/// The source's FULL resolution ("3840×2160"), like Convert's chips show it -- never
/// the "4K" / "1080p" shorthand. Uses the real pixel size when it is known; entries
/// analyzed before that was kept only have the tier height, so those assume 16:9.
func fullResolutionLabel(width: Int, height: Int, tierHeight: Int) -> String? {
    if width > 0, height > 0 { return "\(width)×\(height)" }
    guard tierHeight > 0 else { return nil }
    return "\(evenPixels(Double(tierHeight) * 16 / 9))×\(tierHeight)"
}

/// The full resolution that will land in the file for the chosen quality: the source
/// scaled down to the quality's height cap (never up), sized to even pixel counts.
/// nil when the source's size is unknown (callers fall back to the tier label).
func outputResolutionLabel(_ quality: VideoQuality, width: Int, height: Int, tierHeight: Int) -> String? {
    let w: Int, h: Int
    if width > 0, height > 0 { (w, h) = (width, height) }
    else if tierHeight > 0 { (w, h) = (evenPixels(Double(tierHeight) * 16 / 9), tierHeight) }
    else { return nil }
    guard tierHeight > quality.maxHeight else { return "\(w)×\(h)" }
    let scale = Double(quality.maxHeight) / Double(tierHeight)
    return "\(evenPixels(Double(w) * scale))×\(evenPixels(Double(h) * scale))"
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

/// Shared size formatter for every estimate -- previously duplicated between LinkPreview's
/// own formatBytes and ContentView's totalEstimatedSizeLabel with a visible
/// inconsistency (one used "%.1f MB", the other "%.0f MB"), so the same byte
/// count could read as two different sizes depending on which chip showed it.
///
/// Decimal units (1 MB = 1,000,000 bytes), as Finder writes them: it used to divide by 1024 while
/// still saying "MB", so even a perfect estimate read about 5% under the size that replaced it
/// (106.2 MB, then 111.4 MB).
///
/// The SHAPE is fixed -- always one decimal for MB, two for GB -- because an estimate and the
/// real size that replaces it are both written here and must be the same length: the system's
/// own formatter drops a decimal that is nearly whole ("8 MB" for 8.03 MB, against "~7.9 MB"),
/// which made a capsule shrink (and re-wrap) the moment a job finished.
func formatByteSize(_ bytes: Int) -> String {
    let b = Double(max(bytes, 0))
    if b < 1_000 { return "\(Int(b)) B" }
    if b < 999_500 { return String(format: "%.0f KB", b / 1_000) }
    if b < 999_950_000 { return String(format: "%.1f MB", b / 1_000_000) }
    return String(format: "%.2f GB", b / 1_000_000_000)
}

/// Best guess at one stream's size in bytes, from yt-dlp's format list.
///
/// yt-dlp reports a size for direct (DASH) streams but never for manifest (HLS) ones, and on
/// YouTube the HLS ones are what its format sort prefers, because their bitrate reads higher.
/// With no size, the estimate for a 111 MB download collapsed to its audio track alone
/// (2.6 MB). So, in order:
///  1. the size yt-dlp reports;
///  2. the size of the direct stream with the same height and codec family: an HLS variant is
///     normally the very same encode (measured: 77,187,219 bytes against 77,151,406). Not for
///     a "Premium" stream, whose encode is a genuinely bigger one;
///  3. bitrate x duration, halved for a manifest stream: its bitrate is a peak (measured HLS
///     streams came in at 0.25-0.65 of it, a Premium one at 0.50).
func estimatedStreamBytes(_ stream: [String: Any], among formats: [[String: Any]], durationSeconds: Int) -> Int {
    func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
    func reported(_ format: [String: Any]) -> Int {
        let exact = number(format["filesize"])
        return Int(exact > 0 ? exact : number(format["filesize_approx"]))
    }
    /// avc1.640028 / vp09.00.40.08 / vp9 / av01.0.08M.08, told apart by family.
    func family(_ format: [String: Any]) -> String {
        let codec = (format["vcodec"] as? String ?? "").lowercased()
        if codec.hasPrefix("avc") { return "avc" }
        if codec.hasPrefix("vp09") || codec.hasPrefix("vp9") { return "vp9" }
        if codec.hasPrefix("av01") { return "av1" }
        if codec.hasPrefix("hev") || codec.hasPrefix("hvc") { return "hevc" }
        return codec
    }

    let known = reported(stream)
    if known > 0 { return known }

    let height = Int(number(stream["height"]))
    let isPremium = (stream["format_note"] as? String ?? "").localizedCaseInsensitiveContains("premium")
    if height > 0, !isPremium {
        let twin = formats
            .filter { reported($0) > 0 && Int(number($0["height"])) == height && family($0) == family(stream) }
            .max { number($0["tbr"]) < number($1["tbr"]) }
        if let twin { return reported(twin) }
    }

    let tbr = number(stream["tbr"])
    let kbps = tbr > 0 ? tbr : max(number(stream["vbr"]), number(stream["abr"]))
    guard kbps > 0, durationSeconds > 0 else { return 0 }
    let transport = (stream["protocol"] as? String ?? "").lowercased()
    let isManifest = transport.contains("m3u8") || transport.contains("dash")
    return Int(kbps * 125 * Double(durationSeconds) * (isManifest ? 0.5 : 1))
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
    /// Format selector for video+audio merged download — sorted by bitrate descending. Falls
    /// back to `best[height<=H]` (and a final unconditional `best`) for sources that have no
    /// separate video-only/audio-only pair to merge at all -- TikTok, Instagram, and Facebook
    /// clips are typically ONE pre-muxed stream, so `bestaudio` alone matches nothing and the
    /// `+` combinator has nothing to combine, which without this fallback yt-dlp reported as
    /// "Requested format is not available" (confirmed via a real TikTok download log) rather
    /// than just picking the single muxed format that was there the whole time.
    var formatSelector: String {
        switch self {
        case .q4k:   return "bestvideo[height<=2160]+bestaudio/best[height<=2160]/best"
        case .q1440: return "bestvideo[height<=1440]+bestaudio/best[height<=1440]/best"
        case .q1080: return "bestvideo[height<=1080]+bestaudio/best[height<=1080]/best"
        case .q720:  return "bestvideo[height<=720]+bestaudio/best[height<=720]/best"
        case .q480:  return "bestvideo[height<=480]+bestaudio/best[height<=480]/best"
        }
    }
    /// Format selector for MP4 output. Previously excluded vcodec=vp9/av01 outright to stay
    /// within QuickTime/AVFoundation's native H.264 support -- but YouTube simply has no H.264
    /// stream above 1080p (its 2160p+ streams are VP9/AV1 only), so excluding them was
    /// functionally identical to a hard avc1 requirement at any quality above 1080p: yt-dlp's `/`
    /// fallback only advances on a *zero-match* selector, not a "better stream exists" one, so it
    /// silently settled for the best remaining H.264 stream (1080p) and reported success rather
    /// than falling through to the real 4K/8K stream (confirmed via a real download log: itag 299,
    /// YouTube's 1080p60 avc1 stream, selected for a 4K request). No codec constraint is needed
    /// here anymore -- reencodeIfNeeded already transcodes a VP9/AV1 MP4 download to a
    /// QuickTime-native codec afterward (hardware-accelerated, VMAF-verified near-parity with the
    /// source for H.264 -- see ReencodeCodec), so the
    /// selector can just fetch the real best stream and let that existing step handle
    /// MP4/QuickTime compatibility. MKV and WebM hold VP9/AV1/Opus natively and never reach this
    /// branch at all (see the `guard` below).
    func formatSelector(for container: VideoFormat) -> String {
        guard container == .mp4 else { return formatSelector }
        let h = maxHeight
        // Prefer the best native M4A/AAC audio (highest bitrate available, Resolve-safe, no
        // re-encode needed for MP4). Only fall back to unrestricted bestaudio if the source has
        // no AAC track at all — rare, but keeps the download from failing outright. Final
        // best[height<=H]/best tail for a source with no separate video-only/audio-only pair to
        // merge at all -- see formatSelector's own doc comment above (same root cause, same fix,
        // just with the MP4-preferred-audio clause still tried first).
        return "bestvideo[height<=\(h)]+bestaudio[ext=m4a]/bestvideo[height<=\(h)]+bestaudio/best[height<=\(h)]/best"
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

    private var bundleIdentifier: String? {
        switch self {
        case .none:   return nil
        case .safari: return "com.apple.Safari"
        case .chrome: return "com.google.Chrome"
        case .firefox: return "org.mozilla.firefox"
        case .brave:  return "com.brave.Browser"
        case .edge:   return "com.microsoft.edgemac"
        }
    }

    /// True if this browser is actually installed on the Mac (checked via
    /// LaunchServices, not just a hardcoded assumption) -- a cookie source
    /// yt-dlp can't find a jar for is worse than no cookie source at all,
    /// since it turns a quiet quality cap into a hard download failure.
    var isInstalled: Bool {
        guard let id = bundleIdentifier else { return false }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
    }

    /// Picks a cookie source automatically so authenticated-only formats
    /// (notably YouTube's 4K+ streams, which its anonymous format list
    /// omits entirely for many videos -- see sourceMaxHeight detection in
    /// analyzeURL) are available without the user ever opening a settings
    /// screen. Safari is tried last on purpose: its cookie DB requires
    /// Full Disk Access and is frequently reported locked by macOS (see
    /// the existing .setCookieNone fix path above, which exists
    /// specifically for that failure) -- Chromium-family browsers store
    /// cookies in a far more reliably-readable format. Falls through to
    /// .none (anonymous) only if nothing supported is installed.
    static func autoDetected() -> BrowserSource {
        for candidate: BrowserSource in [.chrome, .edge, .brave, .firefox, .safari] where candidate.isInstalled {
            return candidate
        }
        return .none
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
