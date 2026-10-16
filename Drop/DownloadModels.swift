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


// MARK: - yt-dlp output lines

/// What one line of yt-dlp's output means for a download's row: the progress fraction, the speed
/// and ETA, the friendly status, and the line as it should appear in the log. Worked out by
/// `parse` from the line alone (plus the fraction shown so far), so it can run on the thread that
/// reads the output and be tested without a download.
struct YtDlpOutputUpdate: Sendable, Equatable {
    enum Eta: Sendable, Equatable {
        /// A percentage line with no speed section: no ETA to show.
        case clear
        /// `text` is the speed (or "Downloading…" when it is unknown); `eta` is the countdown
        /// with any fragment counter stripped; `hasRealETA` is false for "Unknown" and
        /// near-zero values.
        case speed(text: String, eta: String, hasRealETA: Bool)
    }

    var renderedLine: String
    var isProgressLine: Bool
    var progress: Double? = nil
    var eta: Eta? = nil
    var activityText: String? = nil
    /// Post-processing lines (converting, extracting audio) mean the download itself is complete.
    var pinsProgressComplete: Bool = false

    /// `lastFraction` is the fraction shown so far for this download attempt: the new one never
    /// goes below it, and it is updated when this line carries a percentage.
    static func parse(line t: String, lastFraction: inout Double, elapsedSeconds: Int) -> YtDlpOutputUpdate {
        // Percentage lines are rewritten into a Homebrew-style Unicode bar plus elapsed time
        // instead of yt-dlp's raw "[download] NN.N% of ..." text, so the log reads like a real
        // terminal installer rather than a wall of repeated percents.
        var update = YtDlpOutputUpdate(
            renderedLine: t,
            isProgressLine: t.hasPrefix("[download]") && t.contains("%"))

        // Parse progress: "[download]  47.3% of ..."
        if update.isProgressLine {
            let parts = t.components(separatedBy: "%")
            if let first = parts.first {
                let token = first.components(separatedBy: CharacterSet.whitespaces).last ?? ""
                if let pct = Double(token), pct >= 0 {
                    let rawClamped = min(max(pct / 100.0, 0.02), 1.0)
                    // yt-dlp's per-line percentage during a fragmented (HLS/DASH) download is a
                    // whole-file *estimate* that gets revised every fragment boundary -- early on
                    // it is wildly unstable and can even briefly read 100% (e.g. the very first
                    // line, when only ~1KiB of an unknown-size stream has been seen). While
                    // fragments are in play (a "(frag N/M)" suffix is present and M > 1), prefer
                    // fragment-index-based progress instead -- coarser, but monotonic and never
                    // spuriously pins at 100% early. The true finish line has no "(frag" suffix at
                    // all, so it always passes through untouched.
                    var effective = rawClamped
                    if let fragRange = t.range(of: "(frag ") {
                        let fragNums = t[fragRange.upperBound...].components(separatedBy: "/")
                        if fragNums.count >= 2,
                           let idx = Int(fragNums[0].trimmingCharacters(in: .whitespaces)),
                           let total = Int(fragNums[1].components(separatedBy: ")").first?.trimmingCharacters(in: .whitespaces) ?? ""),
                           total > 1 {
                            // idx is the fragment currently in flight (0-based), so idx/total is a
                            // safe floor -- never above true progress, and only rises.
                            effective = min(max(Double(idx) / Double(total), 0.02), 0.99)
                        }
                    }
                    // Never let the displayed value move backward within one download attempt.
                    let clamped = max(effective, lastFraction)
                    lastFraction = clamped
                    // Carry the rest of the line (speed/ETA, after the first "%") alongside the
                    // bar so that info isn't lost -- "of 8.23MiB at 1.20MiB/s ETA 00:04" stays
                    // visible.
                    let tail = parts.dropFirst().joined(separator: "%")
                        .trimmingCharacters(in: .whitespaces)
                    let bar = DownloadManager.unicodeProgressBar(fraction: clamped)
                    update.renderedLine = tail.isEmpty
                        ? "\(bar)  [\(elapsedSeconds)s elapsed]"
                        : "\(bar)  \(tail)  [\(elapsedSeconds)s elapsed]"
                    update.progress = clamped
                    update.eta = speedAndEta(afterPercent: parts.dropFirst().joined(separator: "%"))
                }
            }
        }

        // Map yt-dlp status messages to friendly activity text
        if t.contains("Extracting URL") || t.contains("Downloading webpage") {
            update.activityText = "Fetching info…"
        } else if t.contains("Downloading android") || t.contains("Downloading initial") || t.contains("Downloading player") {
            update.activityText = "Loading player…"
        } else if t.contains("Solving JS") || t.contains("deno") {
            update.activityText = "Solving challenges…"
        } else if t.contains("m3u8") || t.contains("Downloading m3u8") {
            update.activityText = "Reading stream…"
        } else if t.contains("Downloading") && t.contains("format") {
            update.activityText = "Selecting format…"
        } else if t.contains("Downloading video thumbnail") {
            update.activityText = "Fetching thumbnail…"
        } else if t.hasPrefix("[download]") && !t.contains("%") && t.contains("Destination") {
            update.activityText = "Starting download…"
        } else if t.contains("Merging formats") || t.contains("ffmpeg") {
            update.activityText = "Merging streams…"
        } else if t.contains("Fixing") || t.contains("Post-process") || t.contains("Adding metadata") {
            update.activityText = "Processing…"
        } else if t.contains("Converting") || t.contains("Extracting audio") || t.hasPrefix("[ExtractAudio]") || t.hasPrefix("[ffmpeg]") {
            update.activityText = "Converting…"
            update.pinsProgressComplete = true
        } else if t.hasPrefix("[EmbedThumbnail]") {
            update.activityText = "Embedding thumbnail…"
        } else if t.hasPrefix("[Metadata]") || t.contains("embed-metadata") {
            update.activityText = "Embedding metadata…"
        }
        // NOTE: the title is deliberately never taken from the output. The main process has no
        // --print line (the filename is resolved separately before it runs), so the first
        // unbracketed line can be arbitrary yt-dlp output like "Deleting original file ... (pass
        // -k to keep)", which would clobber the real title if captured.
        return update
    }

    /// Parses what follows the first "%" of a progress line:
    /// " of  8.23MiB at  1.20MiB/s ETA 00:04" (yt-dlp's "of X" is only the stream it is on -- the
    /// video, then the audio -- so it is not used as the file's size).
    private static func speedAndEta(afterPercent afterPct: String) -> Eta {
        guard afterPct.contains(" at ") else { return .clear }
        let atParts = afterPct.components(separatedBy: " at ")
        guard atParts.count > 1 else { return .clear }
        let speedEta = atParts[1].trimmingCharacters(in: .whitespaces)
        let etaParts = speedEta.components(separatedBy: " ETA ")
        let speed = etaParts[0].trimmingCharacters(in: .whitespaces)
        // A fragmented stream (HLS/DASH) appends its own "(frag 11/50)" counter straight onto the
        // ETA with no further delimiter -- yt-dlp's own diagnostic text, not part of the
        // countdown. Left in, it made etaText long enough to truncate in the status card
        // (reported live: "02:55 (frag 11…"), so it's stripped before the ETA is used.
        let rawEta = etaParts.count > 1 ? etaParts[1].trimmingCharacters(in: .whitespaces) : ""
        let eta = (rawEta.components(separatedBy: " (").first ?? rawEta)
            .trimmingCharacters(in: .whitespaces)
        // Only a real, meaningful countdown counts. On fast connections small files finish in
        // under a second, so yt-dlp reports "00:00" or "Unknown" almost the entire time --
        // showing that looked like a frozen countdown, so those fall back to speed-only.
        let etaSeconds = eta.components(separatedBy: ":")
            .compactMap { Int($0) }
            .reduce(0) { $0 * 60 + $1 }
        let hasRealETA = !eta.isEmpty && eta != "Unknown" && etaSeconds >= 2
        let speedIsKnown = !speed.isEmpty && speed != "Unknown B/s"
        return .speed(text: speedIsKnown ? speed : "Downloading\u{2026}", eta: eta, hasRealETA: hasRealETA)
    }
}
