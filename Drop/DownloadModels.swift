import SwiftUI
import AppKit
import UserNotifications
import UniformTypeIdentifiers
import QuickLookThumbnailing
import CryptoKit
import Sparkle

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
    var sourceWidthPx: Int = 0
    var sourceHeightPx: Int = 0
    var sourceASR: Int = 0
    var sourceABR: Int = 0
    var sourceContainer: String? = nil
    var sourceVideoCodec: String? = nil
    var sourceAudioCodec: String? = nil
    var sourceChannelLabel: String? = nil
    var qualityByFormat: [String: AudioQuality] = ["mp3": .q320, "m4a": .q320, "wav": .q320, "flac": .q320]
    var fileSizeByQuality: [Int: Int] = [:]
    /// The size the analyzed card estimated for what was chosen, so the download's card keeps
    /// showing that same figure until the real file replaces it.
    var estimatedBytes: Int? = nil
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
    var reencodeCodec: ReencodeCodec = .off  // always overwritten from config.reencodeCodec in add()
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
        let sourceSize = sourceSizeLabel(hasVideo: snapshot.hasVideo, sourceMaxHeight: snapshot.sourceMaxHeight,
                                         fileSizeByQuality: snapshot.fileSizeByQuality, fileSizeBytes: snapshot.fileSizeBytes)
        if let length = ChipData.lengthAndSize(length: lengthChipValue(seconds: snapshot.durationSeconds, raw: snapshot.duration), size: sourceSize) {
            result.append(length)
        }
        if mediaMode == .videoAndAudio {
            result.append(.video([snapshot.sourceContainer, snapshot.sourceVideoCodec, fullResolutionLabel(width: snapshot.sourceWidthPx, height: snapshot.sourceHeightPx, tierHeight: snapshot.sourceMaxHeight)]) ?? .videoPlaceholder)
        }
        // An audio-only source has no video chip to carry its container, so the audio chip does.
        if let audio = ChipData.audio([snapshot.hasVideo ? nil : snapshot.sourceContainer, snapshot.sourceAudioCodec, snapshot.sourceChannelLabel, bitrateLabel(kbps: snapshot.sourceABR)]) {
            result.append(audio)
        } else if mediaMode == .audioOnly {
            result.append(.audioPlaceholder)
        }
        return result
    }

    /// Output row — length (unchanged, same as input) + final size, then the
    /// target format/quality. Until the file exists the size is the same "~" estimate the
    /// analyzed card showed (a snapshot of it, so it does not shift when the download starts);
    /// once it is done, the real size read from disk replaces it.
    var outputChips: [ChipData] {
        var result: [ChipData] = []
        let sizeValue: String? = {
            if let sz = fileSize { return sz }
            if let estimate = snapshot.estimatedBytes { return "~" + formatByteSize(estimate) }
            switch mediaMode {
            case .audioOnly:
                if let sz = snapshot.fileSizeBytes { return "~" + formatByteSize(sz) }
            case .videoAndAudio:
                let heightKey = videoQuality.maxHeight
                if let sz = snapshot.fileSizeByQuality[heightKey] ?? snapshot.fileSizeByQuality.first?.value {
                    return "~" + formatByteSize(sz)
                }
            }
            return nil
        }()
        if let length = ChipData.lengthAndSize(length: lengthChipValue(seconds: snapshot.durationSeconds, raw: snapshot.duration), size: sizeValue, reservesEstimateMark: true) {
            result.append(length)
        }
        switch mediaMode {
        case .audioOnly:
            // M4A is native passthrough (no re-encode), so its real bitrate is the source's
            // own rather than one of the quality presets. Auto is the same idea for a
            // re-encoded format: it means "match the source exactly," so it shows that real
            // number too instead of the generic "Auto" label. FLAC repurposes the same enum
            // cases for a sample-rate tier instead of a bitrate (see AudioQuality.flacLabel) --
            // falling through to audioQuality.label here showed a literal "256kbps"/"128kbps"
            // that didn't match the BITRATE dropdown's own "96kHz"/"48kHz" for that exact same
            // selection (reported live).
            let bitrate: String?
            if format == .flac {
                bitrate = audioQuality.flacLabel
            } else if format == .m4a || audioQuality == .auto {
                bitrate = bitrateLabel(kbps: snapshot.sourceABR)
            } else {
                bitrate = audioQuality.label
            }
            result.append(.audio([format.rawValue.uppercased(), snapshot.sourceChannelLabel, bitrate]) ?? .audioPlaceholder)
        case .videoAndAudio:
            // Video is usually stream-copied when merging, so the output codec matches the
            // source's own selected stream -- EXCEPT the one case reencodeIfNeeded actually runs
            // (an AV1/VP9 source going to MP4/MOV, reencodeCodec != .off), where the real output
            // codec is reencodeCodec's choice, not the source's. This chip used to always show
            // the source codec regardless, which went stale the moment the re-encode selector
            // could change what's actually produced (reported live). The audio track is always
            // stream-copied either way, so it still reuses the detected source audio info.
            let needsReencode = (snapshot.sourceVideoCodec == "AV1" || snapshot.sourceVideoCodec == "VP9")
                && (videoFormat == .mp4 || videoFormat == .mov) && reencodeCodec != .off
            let displayedVideoCodec = needsReencode ? reencodeCodec.label : snapshot.sourceVideoCodec
            result.append(.video([videoFormat.rawValue.uppercased(), displayedVideoCodec,
                                  outputResolutionLabel(videoQuality, width: snapshot.sourceWidthPx, height: snapshot.sourceHeightPx, tierHeight: snapshot.sourceMaxHeight)
                                    ?? effectiveVideoResolutionLabel(videoQuality, sourceMaxHeight: snapshot.sourceMaxHeight)]) ?? .videoPlaceholder)
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
    /// The size (`value2`) starts with "~" while it is an estimate. With this on, that mark has
    /// a slot of its own that stays (invisible) once the size is exact, so the capsule keeps
    /// its width when the real size replaces the estimate.
    var reservesEstimateMark = false
}

extension ChipData {
    /// The white "length (+ size)" chip every chip row leads with. Nil when
    /// neither is known. Shared by Download, LinkPreview and Convert so the
    /// three tabs' rows can't drift apart.
    static func lengthAndSize(length: String?, size: String?, reservesEstimateMark: Bool = false) -> ChipData? {
        if let length, let size {
            return ChipData(label: "", value: length, color: .white, icon: "clock", icon2: "internaldrive", value2: size,
                            reservesEstimateMark: reservesEstimateMark)
        } else if let length {
            return ChipData(label: "", value: length, color: .white, icon: "clock")
        } else if let size {
            return ChipData(label: "", value: size, color: .white, icon: "internaldrive", reservesEstimateMark: reservesEstimateMark)
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

/// The size of the SOURCE for the input side of a card's metadata: the exact combined
/// (video + audio) size at the source's top tier when yt-dlp reported one, else the best
/// stream's approximate size, else "n/a" -- so the size cell is never just blank.
func sourceSizeLabel(hasVideo: Bool, sourceMaxHeight: Int, fileSizeByQuality: [Int: Int], fileSizeBytes: Int?) -> String {
    if hasVideo, sourceMaxHeight > 0,
       let exact = fileSizeByQuality[VideoQuality.highest(for: sourceMaxHeight).maxHeight], exact > 0 {
        return "~" + formatByteSize(exact)
    }
    if let approx = fileSizeBytes, approx > 0 { return "~" + formatByteSize(approx) }
    return "n/a"
}

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
