import SwiftUI
import AppKit
import QuickLookThumbnailing

// MARK: - Convert Tab

enum ConvertAudioCodec: String, CaseIterable, Identifiable {
    case aac   = "AAC"
    case ac3   = "AC3"
    case eac3  = "E-AC-3"
    case mp3   = "MP3"
    case flac  = "FLAC"
    case opus  = "Opus"
    case pcm   = "PCM"
    var id: String { rawValue }
    var note: String {
        switch self {
        case .aac:  return "Best compatibility"
        case .ac3:  return "Dolby surround"
        case .eac3: return "Dolby Digital+"
        case .mp3:  return "Universal format"
        case .flac: return "Lossless audio"
        case .opus: return "Web optimized"
        case .pcm:  return "Uncompressed, no re-encode risk"
        }
    }
    var ffmpegCodec: String {
        switch self {
        case .aac:  return "aac"
        case .ac3:  return "ac3"
        case .eac3: return "eac3"
        case .mp3:  return "libmp3lame"
        case .flac: return "flac"
        case .opus: return "libopus"
        case .pcm:  return "pcm_s24le"
        }
    }
    /// Matches this case against the ffprobe-detected source audio codec name,
    /// so we can default-select and silently stream-copy (no re-encode) when
    /// the chosen codec is identical to the source — without a separate "Match" chip.
    var probeNames: [String] {
        switch self {
        case .aac:  return ["AAC"]
        case .ac3:  return ["AC3"]
        case .eac3: return ["EAC3"]
        case .mp3:  return ["MP3"]
        case .flac: return ["FLAC"]
        case .opus: return ["OPUS"]
        case .pcm:  return ["PCM_S16LE", "PCM_S24LE", "PCM_S32LE", "PCM_F32LE"]
        }
    }
    /// True when the given ffprobe-detected raw codec name matches this case —
    /// used to auto-copy without re-encoding when this codec is chosen and it
    /// already equals the source's own codec.
    func matchesSource(_ raw: String?) -> Bool {
        guard let raw else { return false }
        return probeNames.contains(raw)
    }
    /// Typical encode bitrate in kbps — rule-of-thumb figures, used only for the
    /// estimated output size shown above the output-folder picker. Not read by
    /// the actual ffmpeg encode (that stays quality/CRF-driven).
    var typicalBitrateKbps: Int {
        switch self {
        case .aac:  return 192
        case .ac3:  return 384
        case .eac3: return 256
        case .mp3:  return 192
        case .flac: return 900   // lossless — varies by content, this is a reasonable middle figure
        case .opus: return 128
        case .pcm:  return 4608  // 24-bit/48kHz/5.1 uncompressed — largest option, sized for worst case
        }
    }
}

enum ConvertVideoCodec: String, CaseIterable, Identifiable {
    case h264   = "H.264"
    case h265   = "H.265"
    case prores = "ProRes"
    case av1    = "AV1"
    case vp9    = "VP9"
    var id: String { rawValue }
    var note: String {
        switch self {
        case .h264:   return "Best compatibility"
        case .h265:   return "Smaller file size"
        case .prores: return "Apple/Final Cut Pro"
        case .av1:    return "Most efficient"
        case .vp9:    return "Web optimized"
        }
    }
    /// Verified against ffmpeg 8.1.2 on-device: libaom-av1 is NOT built into this
    /// ffmpeg — only libsvtav1 is available, so AV1 encodes must use that, not libaom-av1.
    var ffmpegCodec: String {
        switch self {
        case .h264:   return "libx264"
        case .h265:   return "libx265"
        case .prores: return "prores_ks"
        case .av1:    return "libsvtav1"
        case .vp9:    return "libvpx-vp9"
        }
    }
    /// Matches this case against the ffprobe-detected source video codec name.
    var probeNames: [String] {
        switch self {
        case .h264:   return ["H264", "AVC"]
        case .h265:   return ["HEVC", "H265"]
        case .prores: return ["PRORES"]
        case .av1:    return ["AV1"]
        case .vp9:    return ["VP9"]
        }
    }
    /// True when the given ffprobe-detected raw codec name matches this case —
    /// used to auto-copy without re-encoding when this codec is chosen and it
    /// already equals the source's own codec.
    func matchesSource(_ raw: String?) -> Bool {
        guard let raw else { return false }
        return probeNames.contains(raw)
    }
    /// Typical encode bitrate in Mbps at 1080p — rule-of-thumb figures used only for
    /// the estimated output size shown above the output-folder picker (scaled by actual
    /// resolution below). ProRes is intentionally much higher — it's a near-lossless
    /// intermediate codec, not a delivery codec, so files are dramatically larger.
    var typicalMbpsAt1080p: Double {
        switch self {
        case .h264:   return 8
        case .h265:   return 5
        case .prores: return 220   // ProRes 422 HQ — much larger by design
        case .av1:    return 4
        case .vp9:    return 5
        }
    }
}

enum ConvertMediaMode: String, CaseIterable {
    case videoAndAudio = "both"
    case videoOnly    = "video"
    case audio        = "audio"
    var label: String {
        switch self {
        case .videoAndAudio: return "Video + Audio"
        case .videoOnly:     return "Video Only"
        case .audio:         return "Audio Only"
        }
    }
    var icon: String {
        switch self {
        case .audio:         return "waveform"
        case .videoAndAudio: return "video.badge.waveform"
        case .videoOnly:     return "video"
        }
    }
    var isVideo: Bool { self != .audio }
    var chipTint: Color {
        switch self {
        case .audio:         return DesignTokens.Accent.success
        case .videoAndAudio: return DesignTokens.Accent.primary
        case .videoOnly:     return Color(red: 0.58, green: 0.35, blue: 1.0)
        }
    }
}


enum ConvertOutputFormat: String, CaseIterable, Identifiable {
    case mp4  = "MP4"
    case mov  = "MOV"
    case mkv  = "MKV"
    case wav  = "WAV"
    case mp3  = "MP3"
    case m4a  = "M4A"
    case flac = "FLAC"
    var id: String { rawValue }
    var note: String {
        switch self {
        case .mp4:  return "Universal video"
        case .mov:  return "Apple/Final Cut"
        case .mkv:  return "Best container"
        case .wav:  return "Best for DaVinci Resolve"
        case .mp3:  return "Universal audio"
        case .m4a:  return "Not good for DaVinci Resolve"
        case .flac: return "Lossless audio"
        }
    }
    var isVideo: Bool { [.mp4, .mov, .mkv].contains(self) }
    var fileExtension: String { rawValue.lowercased() }

    /// Alternate file extensions ffprobe/Finder may report for this container
    /// (e.g. an MP4-family file can arrive as .m4v, an MOV as .qt).
    var sourceExtensionAliases: [String] {
        switch self {
        case .mp4:  return ["mp4", "m4v"]
        case .mov:  return ["mov", "qt"]
        case .mkv:  return ["mkv"]
        case .wav:  return ["wav"]
        case .mp3:  return ["mp3"]
        case .m4a:  return ["m4a"]
        case .flac: return ["flac"]
        }
    }
    /// True when the imported file's own extension already matches this container —
    /// used to default a fresh job's output format to its own source container.
    func matchesSource(_ inputExtension: String) -> Bool {
        sourceExtensionAliases.contains(inputExtension.lowercased())
    }

    /// Video codecs this container can actually hold — verified directly against ffmpeg
    /// 8.1.2's muxers on-device (not spec folklore). Each rejection message was confirmed
    /// ("av1 only supported in MP4 and AVIF", "vp9 only supported in MP4", ProRes-in-MP4
    /// fails at the muxer level regardless of audio codec).
    var compatibleVideoCodecs: [ConvertVideoCodec] {
        switch self {
        case .mp4:  return [.h264, .h265, .av1, .vp9]         // ProRes in MP4 fails at muxer level
        case .mov:  return [.h264, .h265, .prores]            // MOV muxer rejects AV1 + VP9
        case .mkv:  return [.h264, .h265, .prores, .av1, .vp9] // Matroska holds anything
        case .wav, .mp3, .m4a, .flac: return []
        }
    }

    /// Audio codecs this container can actually hold — verified directly against ffmpeg 8.1.2's
    /// muxers (not spec folklore). Each combination was test-encoded on-device; see probe results.
    var compatibleAudioCodecs: [ConvertAudioCodec] {
        switch self {
        case .mp4:  return [.aac, .ac3, .eac3, .mp3, .flac, .opus, .pcm] // modern mov/mp4 muxer accepts all seven
        case .mov:  return [.aac, .ac3, .eac3, .mp3, .pcm]  // QuickTime muxer rejects FLAC + Opus ("only supported in MP4"); PCM is native to MOV
        case .mkv:  return [.aac, .ac3, .eac3, .mp3, .flac, .opus, .pcm] // Matroska holds anything
        case .wav:  return [.pcm]                           // self-contained uncompressed format: codec == container
        case .mp3:  return [.mp3]                           // self-contained format: codec == container
        case .m4a:  return [.aac, .ac3]                     // ipod/m4a muxer accepts AAC + AC3, rejects FLAC
        case .flac: return [.flac]                          // self-contained lossless format
        }
    }
}

struct ConvertMediaInfo {
    var videoCodec: String?    // e.g. "h264", "hevc"
    var audioCodec: String?    // e.g. "aac", "mp3"
    var audioChannelLabel: String? // e.g. "1.0", "2.0", "5.1", "7.1"
    var resolution: String?    // e.g. "1920x1080"
    var duration: String?      // e.g. "3:42"
    var fileSize: String?      // e.g. "142 MB"
    var durationSeconds: Double? = nil  // raw seconds, for output size estimation
    var pixelWidth: Int? = nil
    var pixelHeight: Int? = nil
    var fileSizeBytes: Int? = nil  // raw source size, for stream-copy size estimation
    var videoFrameRateLabel: String? = nil  // e.g. "30fps", "29.97fps" -- from r_frame_rate
    var audioBitrateKbps: Int? = nil        // from the audio stream's own bit_rate
}

enum ConvertJobStatus { case queued, converting, done, failed, cancelled }

class ConvertJob: ObservableObject, Identifiable, @unchecked Sendable {
    /// Formats a remaining-seconds countdown as "Ns" or "Nm Ss", matching the
    /// plain style yt-dlp's own ETA strings use on the Download tab.
    static func formatETA(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let m = total / 60
        let s = total % 60
        return "\(m)m \(s)s"
    }

    let id = UUID()
    let inputURL: URL
    @Published var status: ConvertJobStatus = .queued
    @Published var progress: String = "Queued"
    /// Fraction 0.0-1.0 parsed from ffmpeg's stderr "time=" field against the
    /// source duration — drives the same progress-bar visual as Download's
    /// yt-dlp-driven bar. nil while unknown (duration missing, just started).
    @Published var progressFraction: Double? = nil
    /// Right-aligned "NN% · Ns left" readout, kept separate from `progress`
    /// (the friendly speed/bitrate text) so the two can be laid out on
    /// opposite ends of the same line — status on the left, percentage+ETA
    /// on the right, mirroring Download's activityText/etaText split.
    @Published var etaText: String = ""
    @Published var outputURL: URL? = nil
    /// Real on-disk size of the finished output, read once when the job
    /// completes (see runConversion) rather than on every render of its row.
    @Published var outputSizeLabel: String? = nil
    @Published var isSelected: Bool = true
    @Published var thumbnail: NSImage? = nil
    @Published var audioCodec: ConvertAudioCodec = .aac
    @Published var videoCodec: ConvertVideoCodec = .h264
    @Published var outputFormat: ConvertOutputFormat = .mp4
    @Published var mediaMode: ConvertMediaMode = .videoAndAudio
    /// Independent of mediaMode (which decides whether a track is IN the output
    /// at all): these decide whether an included track gets re-encoded or left
    /// exactly as the source. true = transcode with the codec chosen in the
    /// chip row (set automatically when a real codec chip is tapped); false =
    /// stream-copy untouched (the default -- "Same as Source" starts selected
    /// on both tracks, so a freshly-imported file is a pure remux until you
    /// deliberately pick a codec), so e.g. only the audio can be changed on a
    /// clip without ever re-encoding its video, or vice versa.
    @Published var transcodeVideo: Bool = false
    @Published var transcodeAudio: Bool = false
    @Published var mediaInfo: ConvertMediaInfo? = nil {
        didSet { applyDefaultCodecsFromSource() }
    }
    var process: Process? = nil

    func cancel() {
        if let proc = process {
            Self.forceTerminate(proc)
        }
        status = .cancelled
        progress = "Cancelled"
        // ffmpeg writes straight to the destination path as it encodes, so a
        // cancelled run leaves a truncated, unplayable file behind unless we
        // remove it here.
        if let url = outputURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Plain terminate() sends SIGTERM, but ffmpeg's default SIGTERM handling is
    /// a graceful shutdown — it finishes encoding/flushing the current frame and
    /// writes the trailer/moov atom before exiting, which can take a noticeable
    /// amount of time on longer files. That made Cancel look like it did nothing.
    /// Escalate to SIGKILL shortly after if the process hasn't actually exited.
    private static func forceTerminate(_ proc: Process) {
        guard proc.isRunning else { return }
        proc.terminate()
        let pid = proc.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            if pid > 0, kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
        }
    }

    /// Once the source codec is detected, default-select whichever chip matches it
    /// (even if it isn't first in the list) so the initial choice never re-encodes —
    /// but only if that codec is actually valid inside the currently selected output format.
    private func applyDefaultCodecsFromSource() {
        guard let info = mediaInfo else { return }
        if let raw = info.videoCodec,
           let match = ConvertVideoCodec.allCases.first(where: { $0.probeNames.contains(raw) }),
           availableVideoCodecs.contains(match) {
            videoCodec = match
        }
        if let raw = info.audioCodec,
           let match = ConvertAudioCodec.allCases.first(where: { $0.probeNames.contains(raw) }),
           availableAudioCodecs.contains(match) {
            audioCodec = match
        }
        ensureCodecsValidForFormat()
    }

    /// Tapped from the VIDEO CODEC row's "Same as Source" chip. Must reset
    /// `videoCodec` back to the source-matching one, not just clear
    /// `transcodeVideo` -- runConversion's copy-vs-encode decision is driven
    /// entirely by `videoCodecMatchesSource` (see its own comment), which
    /// compares `videoCodec` itself, not this toggle. Without this reset,
    /// picking a real codec chip (e.g. H.265) and then tapping back onto
    /// "Same as Source" left `videoCodec` stuck on H.265 -- the chip showed
    /// as selected, but the conversion silently kept re-encoding to H.265
    /// instead of stream-copying. Confirmed via the actual ffmpeg command
    /// logged for that exact sequence before this fix.
    /// Human-readable size of the file at `url`, or nil (with a log line) if
    /// it can't be read. NSNumber-backed sizes can be UInt64 for large files
    /// on some volumes -- casting straight to Int silently failed and dropped
    /// the size chip -- so this goes through NSNumber's int64Value, which
    /// bridges correctly regardless of the underlying storage width.
    static func fileSizeLabel(at url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            DropLogger.shared.write("Convert size chip: attributesOfItem failed for \(url.path)")
            return nil
        }
        guard let sizeNumber = attrs[.size] as? NSNumber, sizeNumber.int64Value > 0 else {
            DropLogger.shared.write("Convert size chip: unusable .size attr for \(url.path): \(String(describing: attrs[.size]))")
            return nil
        }
        return ByteCountFormatter.string(fromByteCount: sizeNumber.int64Value, countStyle: .file)
    }

    func useSameAsSourceForVideo() {
        transcodeVideo = false
        if let raw = mediaInfo?.videoCodec,
           let match = ConvertVideoCodec.allCases.first(where: { $0.probeNames.contains(raw) }),
           availableVideoCodecs.contains(match) {
            videoCodec = match
        }
    }
    /// Same fix as `useSameAsSourceForVideo`, for the AUDIO CODEC row.
    func useSameAsSourceForAudio() {
        transcodeAudio = false
        if let raw = mediaInfo?.audioCodec,
           let match = ConvertAudioCodec.allCases.first(where: { $0.probeNames.contains(raw) }),
           availableAudioCodecs.contains(match) {
            audioCodec = match
        }
    }

    /// Audio codecs valid inside the currently selected output container.
    var availableAudioCodecs: [ConvertAudioCodec] { outputFormat.compatibleAudioCodecs }
    /// Video codecs valid inside the currently selected output container.
    var availableVideoCodecs: [ConvertVideoCodec] { outputFormat.compatibleVideoCodecs }

    /// Call after changing `outputFormat` (or on init) to guarantee the selected
    /// codecs are still legal for the new container — falls back to the source-matching
    /// codec if still valid, otherwise the first compatible codec.
    func ensureCodecsValidForFormat() {
        if !availableAudioCodecs.contains(audioCodec) {
            if let raw = mediaInfo?.audioCodec,
               let match = availableAudioCodecs.first(where: { $0.probeNames.contains(raw) }) {
                audioCodec = match
            } else {
                audioCodec = availableAudioCodecs.first ?? audioCodec
            }
        }
        if !availableVideoCodecs.contains(videoCodec) {
            if let raw = mediaInfo?.videoCodec,
               let match = availableVideoCodecs.first(where: { $0.probeNames.contains(raw) }) {
                videoCodec = match
            } else {
                videoCodec = availableVideoCodecs.first ?? videoCodec
            }
        }
    }

    var videoCodecMatchesSource: Bool {
        guard let raw = mediaInfo?.videoCodec else { return false }
        return videoCodec.probeNames.contains(raw)
    }
    var audioCodecMatchesSource: Bool {
        guard let raw = mediaInfo?.audioCodec else { return false }
        return audioCodec.probeNames.contains(raw)
    }
    var outputFilename: String {
        let base = inputURL.deletingPathExtension().lastPathComponent
        return "\(base)_converted.\(outputFormat.fileExtension)"
    }

    init(inputURL: URL) {
        self.inputURL = inputURL
        let ext = inputURL.pathExtension.lowercased()
        let isVid = ["mp4","mov","mkv","avi","m4v","ts","mts","m2ts","webm","flv"].contains(ext)
        if isVid {
            mediaMode = .videoAndAudio
            // Default to whichever output container matches the source file's own
            // extension (e.g. importing a .mkv defaults to MKV output) so it reads
            // as a pass-through by default — fall back to MP4 only when the source
            // container isn't one of our own output options (avi, webm, ts, etc.).
            outputFormat = ConvertOutputFormat.allCases.first { $0.isVideo && $0.matchesSource(ext) } ?? .mp4
        } else {
            mediaMode = .audio
            outputFormat = ConvertOutputFormat.allCases.first { !$0.isVideo && $0.matchesSource(ext) } ?? .wav
        }
        generateThumbnail()
        loadMediaInfo()
    }

    private func loadMediaInfo() {
        let url = inputURL
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var info = ConvertMediaInfo()

            // File size
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let bytes = attrs[.size] as? Int64 {
                info.fileSizeBytes = Int(bytes)
                let mb = Double(bytes) / 1_048_576
                if mb >= 1000 {
                    info.fileSize = String(format: "%.1f GB", mb / 1024)
                } else if mb >= 0.1 {
                    info.fileSize = String(format: "%.1f MB", mb)
                } else {
                    info.fileSize = String(format: "%.0f KB", mb * 1024)
                }
            }

            // ffprobe for codec/resolution/duration
            let ffprobe = locateFFprobe()
            if let ffprobe {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: ffprobe)
                p.arguments = ["-v", "quiet", "-print_format", "json",
                               "-show_streams", "-show_format", url.path]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = Pipe()
                try? p.run()
                p.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let streams = json["streams"] as? [[String: Any]] ?? []
                    for s in streams {
                        let ct = s["codec_type"] as? String ?? ""
                        let cn = s["codec_name"] as? String ?? ""
                        if ct == "video" && info.videoCodec == nil {
                            info.videoCodec = cn.uppercased()
                            let w = s["width"] as? Int
                            let h = s["height"] as? Int
                            if let w, let h {
                                info.resolution = "\(w)×\(h)"
                                info.pixelWidth = w
                                info.pixelHeight = h
                            }
                            // r_frame_rate is a "num/den" fraction string (e.g. "30000/1001"
                            // for 29.97fps, "30/1" for a flat 30fps) -- avg_frame_rate can be
                            // "0/0" for some still-image-like streams, so r_frame_rate (the
                            // stream's declared rate) is the more reliable of the two.
                            if let raw = s["r_frame_rate"] as? String {
                                let comps = raw.split(separator: "/")
                                if comps.count == 2, let num = Double(comps[0]), let den = Double(comps[1]), den > 0 {
                                    let fps = num / den
                                    let rounded = (fps * 100).rounded() / 100
                                    let label = rounded == rounded.rounded()
                                        ? String(format: "%.0ffps", rounded)
                                        : String(format: "%.2ffps", rounded)
                                    info.videoFrameRateLabel = label
                                }
                            }
                        }
                        if ct == "audio" && info.audioCodec == nil {
                            info.audioCodec = cn.uppercased()
                            // Some codecs (FLAC, lossless PCM) don't report their own
                            // bit_rate at the stream level -- left nil rather than falling
                            // back to the container's overall bit_rate, which would include
                            // the video track's share too and overstate the audio number.
                            if let raw = s["bit_rate"] as? String, let bps = Int(raw) {
                                info.audioBitrateKbps = bps / 1000
                            }
                            // Derive from raw channel COUNT, not the channel_layout string —
                            // ffprobe reports many layout spellings for the same count ("5.1",
                            // "5.1(side)", "hexagonal", etc.), so count is the unambiguous source
                            // of truth. LFE-bearing counts use the X.1 convention (5 full + 1 LFE
                            // = "5.1", 7 full + 1 LFE = "7.1"); everything else is X.0.
                            if let ch = s["channels"] as? Int {
                                let layout = (s["channel_layout"] as? String) ?? ""
                                let hasLFE = layout.contains(".1") || layout.lowercased().contains("lfe")
                                switch ch {
                                case 1: info.audioChannelLabel = "1.0"
                                case 2: info.audioChannelLabel = "2.0"
                                case 3: info.audioChannelLabel = hasLFE ? "2.1" : "3.0"
                                case 4: info.audioChannelLabel = hasLFE ? "3.1" : "4.0"
                                case 5: info.audioChannelLabel = hasLFE ? "4.1" : "5.0"
                                case 6: info.audioChannelLabel = "5.1"
                                case 8: info.audioChannelLabel = "7.1"
                                default: info.audioChannelLabel = "\(ch)ch"
                                }
                            }
                        }
                    }
                    // The container-level format.duration can come back
                    // missing or "N/A" for some files (e.g. certain MKVs
                    // without a Duration element, or anything ffprobe can't
                    // resolve from headers alone) even though every stream
                    // still reports its own duration just fine -- fall back
                    // to the longest stream-level one so codec/resolution
                    // chips aren't the only thing that ends up populated.
                    let formatDuration = (json["format"] as? [String: Any])
                        .flatMap { $0["duration"] as? String }
                        .flatMap(Double.init)
                    let streamDuration = streams
                        .compactMap { ($0["duration"] as? String).flatMap(Double.init) }
                        .max()
                    if let dur = formatDuration ?? streamDuration, dur > 0 {
                        info.durationSeconds = dur
                        let total = Int(dur)
                        let h = total / 3600
                        let m = (total % 3600) / 60
                        let s = total % 60
                        info.duration = h > 0
                            ? String(format: "%d:%02d:%02d", h, m, s)
                            : String(format: "%d:%02d", m, s)
                    }
                }
            }

            DispatchQueue.main.async { self.mediaInfo = info }
        }
    }

    /// Output formats available for the current media mode
    var availableFormats: [ConvertOutputFormat] {
        switch mediaMode {
        case .audio:                    return [.wav, .mp3, .m4a, .flac]
        case .videoAndAudio, .videoOnly: return [.mp4, .mov, .mkv]
        }
    }

    /// Estimated output file size for the currently selected codec/format combo.
    /// When the selected codec matches the source (the "Original" badge case), Drop
    /// stream-copies that track byte-for-byte instead of re-encoding — so that track's
    /// share of the estimate comes from the real source size, not rule-of-thumb bitrate
    /// math. Only tracks that will actually be re-encoded use the bitrate estimate.
    var estimatedOutputBytes: Int? {
        guard let info = mediaInfo else { return nil }
        // Matches runConversion's actual copy-vs-encode decision: only the
        // real codec match determines this, never the transcode toggle
        // alone (see runConversion's comment) -- otherwise this estimate
        // would report the source's own file size for a track that's
        // actually about to be re-encoded into something much smaller
        // (or larger).
        let videoIsCopy = mediaMode != .audio && videoCodec.matchesSource(info.videoCodec)
        let audioIsCopy = mediaMode != .videoOnly && audioCodec.matchesSource(info.audioCodec)
        // If every relevant track is being stream-copied (the all-default "Original"
        // case), the output is essentially the source file — same container muxing
        // overhead aside — so just report the real source size instead of running it
        // through the bitrate model at all. Checked BEFORE the duration guard below:
        // this path never needs duration at all, and gating it on durationSeconds
        // (which ffprobe can't always determine from a container's header) was
        // silently blanking the output size/duration chip for files whose duration
        // just happens to be unknown, even when they're a plain default remux.
        let allTracksCopied = (mediaMode == .audio || videoIsCopy) && (mediaMode == .videoOnly || audioIsCopy)
        if allTracksCopied, let sourceBytes = info.fileSizeBytes, sourceBytes > 0 {
            return sourceBytes
        }
        guard let duration = info.durationSeconds, duration > 0 else { return nil }
        // Otherwise split the known source size between video/audio using the same
        // rule-of-thumb bitrate ratio, so a copied track's share reflects the source's
        // real weight rather than assuming it's the whole file.
        let sourceVideoKbps = mediaMode != .audio ? ConvertVideoCodec.h264.typicalMbpsAt1080p * 1000 * sourceResolutionRatio(info) : 0
        let sourceAudioKbps = mediaMode != .videoOnly ? Double(ConvertAudioCodec.aac.typicalBitrateKbps) : 0
        let sourceTotalKbps = max(sourceVideoKbps + sourceAudioKbps, 1)
        let sourceBytes = info.fileSizeBytes ?? 0

        var totalKbps: Double = 0
        var copiedBytes: Double = 0

        if mediaMode != .audio {
            if videoIsCopy, sourceBytes > 0 {
                copiedBytes += Double(sourceBytes) * (sourceVideoKbps / sourceTotalKbps)
            } else {
                totalKbps += videoCodec.typicalMbpsAt1080p * 1000 * sourceResolutionRatio(info)
            }
        }
        if mediaMode != .videoOnly {
            if audioIsCopy, sourceBytes > 0 {
                copiedBytes += Double(sourceBytes) * (sourceAudioKbps / sourceTotalKbps)
            } else {
                totalKbps += Double(audioCodec.typicalBitrateKbps)
            }
        }

        let reencodedBytes = totalKbps > 0 ? (totalKbps * 1000 / 8) * duration : 0
        let combined = copiedBytes + reencodedBytes
        guard combined > 0 else { return nil }
        return Int(combined)
    }

    private func sourceResolutionRatio(_ info: ConvertMediaInfo) -> Double {
        let w = info.pixelWidth ?? 1920
        let h = info.pixelHeight ?? 1080
        return max(Double(w * h) / Double(1920 * 1080), 0.1)
    }

    var estimatedOutputSizeLabel: String? {
        guard let bytes = estimatedOutputBytes else { return nil }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1000 {
            return String(format: "~%.1f GB", mb / 1024)
        } else if mb >= 0.1 {
            return String(format: "~%.0f MB", mb)
        } else {
            return String(format: "~%.0f KB", mb * 1024)
        }
    }

    // MARK: Input/output chip rows -- same visual language as Download's
    // LinkPreview.inputChips/outputChips, so a queued Convert card shows an
    // always-visible "what you have" -> "what you'll get" row exactly like
    // Download does, instead of only showing the source side.

    var inputChips: [ChipData] {
        var result: [ChipData] = []
        let dur = mediaInfo?.durationSeconds.flatMap { formatDurationChip(seconds: Int($0)) } ?? mediaInfo?.duration
        if let length = ChipData.lengthAndSize(length: dur, size: mediaInfo?.fileSize) { result.append(length) }
        // Unlike outputChips below, these describe the SOURCE file's own
        // characteristics, so they're gated on whether the source actually
        // has that track (mediaInfo data present) -- never on the selected
        // output mode. Switching to Audio Only doesn't erase the source's
        // own video track from existence, so its input chip should stay.
        // Order: format, codec, framerate, resolution.
        let sourceFormat = isVideoFile ? inputURL.pathExtension.uppercased() : nil
        if let video = ChipData.video([sourceFormat, mediaInfo?.videoCodec, mediaInfo?.videoFrameRateLabel, mediaInfo?.resolution],
                                      icon: isVideoFile ? "video" : "waveform") {
            result.append(video)
        }
        // Order: codec, channels, bitrate.
        if let audio = ChipData.audio([mediaInfo?.audioCodec, mediaInfo?.audioChannelLabel, mediaInfo?.audioBitrateKbps.flatMap { bitrateLabel(kbps: $0) }]) {
            result.append(audio)
        }
        return result
    }

    var outputChips: [ChipData] {
        var result: [ChipData] = []
        let dur = mediaInfo?.durationSeconds.flatMap { formatDurationChip(seconds: Int($0)) } ?? mediaInfo?.duration
        if let length = ChipData.lengthAndSize(length: dur, size: estimatedOutputSizeLabel) { result.append(length) }
        if mediaMode != .audio {
            // Frame rate and resolution are unchanged by conversion (Convert
            // never retimes or resizes), so they carry over from the source.
            result.append(ChipData.video([outputFormat.rawValue.uppercased(), displayVideoCodec, mediaInfo?.videoFrameRateLabel, mediaInfo?.resolution])
                          ?? .videoPlaceholder)
        }
        if mediaMode != .videoOnly {
            // Convert never changes the channel layout except when MP3
            // forces a stereo downmix of a >2-channel source (see
            // displayAudioChannelLabel) -- otherwise this echoes the same
            // audioChannelLabel the input chip shows instead of omitting
            // it, which previously made the output side look like it might
            // downmix when it never does.
            let codecPart = mediaMode == .audio ? outputFormat.rawValue.uppercased() : displayAudioCodec
            result.append(ChipData.audio([codecPart, displayAudioChannelLabel, displayAudioBitrateLabel]) ?? .audioPlaceholder)
        }
        return result
    }

    /// True once QuickLook has genuinely finished trying and came back
    /// empty (not merely "still pending") -- generateRepresentations' own
    /// completion handler only fires once, on success or failure, so this
    /// is a reliable "give up, show the fallback symbol" signal rather than
    /// a guess based on elapsed time.
    @Published var thumbnailFailed: Bool = false

    /// QuickLook can pull real embedded artwork (e.g. ID3 cover art) for
    /// audio-only files too, so this still runs for them -- the view layer
    /// just doesn't wait on it before showing the waveform placeholder,
    /// since a generic result there is far less likely to be useful than a
    /// real video frame is for video.
    private func generateThumbnail() {
        let size = CGSize(width: 80, height: 80)
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let request = QLThumbnailGenerator.Request(
            fileAt: inputURL,
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateRepresentations(for: request) { [weak self] rep, _, _ in
            DispatchQueue.main.async {
                if let image = rep?.nsImage {
                    self?.thumbnail = image
                } else {
                    self?.thumbnailFailed = true
                }
            }
        }
    }

    var isVideoFile: Bool {
        ["mp4","mov","mkv","avi","m4v","ts","mts","m2ts","webm","flv"]
            .contains(inputURL.pathExtension.lowercased())
    }

    /// Pretty-prints a raw ffprobe codec string against a known codec's
    /// probeNames, falling back to the raw string for anything unrecognized.
    private static func prettyCodec<C: RawRepresentable>(_ raw: String, matching cases: [C], probeNames: (C) -> [String]) -> String where C.RawValue == String {
        cases.first(where: { probeNames($0).contains(raw) })?.rawValue ?? raw
    }

    /// "Original: " subtext for the VIDEO layer -- pretty-printed source codec
    /// plus resolution, e.g. "H.264 · 1920x1080".
    var videoSourceLabel: String? {
        guard let raw = mediaInfo?.videoCodec else { return nil }
        let pretty = Self.prettyCodec(raw, matching: ConvertVideoCodec.allCases, probeNames: { $0.probeNames })
        return [pretty, mediaInfo?.resolution].compactMap { $0 }.joined(separator: " · ")
    }
    /// "Original: " subtext for the AUDIO layer -- pretty-printed source codec
    /// plus channel layout, e.g. "AAC · 5.1".
    var audioSourceLabel: String? {
        guard let raw = mediaInfo?.audioCodec else { return nil }
        let pretty = Self.prettyCodec(raw, matching: ConvertAudioCodec.allCases, probeNames: { $0.probeNames })
        return [pretty, mediaInfo?.audioChannelLabel].compactMap { $0 }.joined(separator: " · ")
    }

    /// The codec that will actually end up in the output: the source's own
    /// codec (stream-copied through untouched) when that codec is actually
    /// valid for the chosen container, otherwise the chosen codec while
    /// transcoding -- used anywhere the UI previews what the output will
    /// actually contain. Gated on videoCodecMatchesSource rather than the
    /// transcodeVideo toggle alone: a self-contained/mismatched-codec case
    /// (e.g. ProRes source into MP4) always encodes regardless of whether
    /// "Same as Source" looks selected, so the label must agree with that.
    var displayVideoCodec: String {
        guard videoCodecMatchesSource, let raw = mediaInfo?.videoCodec else { return videoCodec.rawValue }
        return Self.prettyCodec(raw, matching: ConvertVideoCodec.allCases, probeNames: { $0.probeNames })
    }
    /// Same idea as `displayVideoCodec`, for the audio layer.
    var displayAudioCodec: String {
        guard audioCodecMatchesSource, let raw = mediaInfo?.audioCodec else { return audioCodec.rawValue }
        return Self.prettyCodec(raw, matching: ConvertAudioCodec.allCases, probeNames: { $0.probeNames })
    }
    /// Bitrate that will actually end up in the output: the source's own
    /// probed bitrate while stream-copying ("Same as Source"), or the chosen
    /// codec's typical encode bitrate while transcoding. nil (chip simply
    /// omits it) when copying a source whose own bitrate isn't knowable
    /// (e.g. FLAC/PCM don't report one) rather than showing a guess.
    var displayAudioBitrateLabel: String? {
        if !audioCodecMatchesSource { return "\(audioCodec.typicalBitrateKbps)kbps" }
        return mediaInfo?.audioBitrateKbps.map { "\($0)kbps" }
    }

    /// Channel layout that will actually end up in the output -- normally
    /// just the source's own (Convert never touches channel layout), EXCEPT
    /// MP3 forces stereo when actually re-encoding a >2-channel source (see
    /// runConversion's -ac 2), so this is the one place the output chip
    /// must show something other than the source's real channel count.
    var displayAudioChannelLabel: String? {
        let isMultichannel = mediaInfo?.audioChannelLabel.map { $0 == "5.1" || $0 == "7.1" } ?? false
        if !audioCodecMatchesSource && audioCodec == .mp3 && isMultichannel { return "2.0" }
        return mediaInfo?.audioChannelLabel
    }

}

struct ConvertView: View {
    let ffmpegPath: String?
    var toolsReady: Bool = true
    @ObservedObject var history: HistoryStore
    /// Files imported but not yet committed to the Convert Queue -- the
    /// Analyze panel shows exactly one of these at a time (via the dropdown)
    /// so its full settings can be reviewed/changed before queuing.
    @Binding var stagingJobs: [ConvertJob]
    /// Files committed to convert, in the exact order they'll be processed
    /// (drag-reorderable). Lives in the bottom bar's queue drawer as compact
    /// read-only rows -- editing a queued job's settings means pulling it
    /// back into `stagingJobs` first (see editFromQueue).
    @Binding var queue: [ConvertJob]
    /// Which staged job the Analyze panel is currently showing. nil when
    /// stagingJobs is empty. Owned by the parent (not local @State) because
    /// switching tabs unmounts/remounts this view -- local @State would
    /// reset to nil on every trip back, making the panel look like it lost
    /// its staged files even though stagingJobs itself still had them.
    @Binding var selectedStagingID: ConvertJob.ID?
    @ObservedObject var config: Config
    /// Shared app-wide log (same store/panel Download writes to) so ffmpeg
    /// commands, stderr output, and results are visible/exportable from the
    /// existing terminal-icon log panel and included in "Export Log".
    @ObservedObject var manager: DownloadManager

    @State private var isDragging = false
    @State private var isDropZoneHovering = false
    /// Shared content column and vertical density (see WindowLayout) -- the
    /// Analyze panel, drop zone and bottom bar all use the same width as
    /// Download's rows.
    @Environment(\.contentColumnWidth) private var columnWidth
    @Environment(\.isCompactHeight) private var compactHeight
    @Environment(\.isTinyHeight) private var tinyHeight

    /// Convert Queue drawer collapse state -- the item-count subtext stays
    /// visible either way; collapsing only hides the row list beneath it.
    @State private var isQueueExpanded = true

    /// Bumped whenever a job's own @Published state changes in a way this
    /// view needs to react to (isSelected, status) -- `queue`/`stagingJobs`
    /// are arrays of reference-type ConvertJobs behind @Binding, so a change
    /// on one job doesn't by itself invalidate this view's body.
    @State private var selectionVersion = 0

    /// Custom file-switcher popup open state (Analyze panel) -- a plain
    /// Bool, not a native Menu, so the popup can be fully custom-styled.
    @State private var isFileSwitcherOpen = false
    /// Row currently hovered inside fileSwitcherPopup -- drives its hover
    /// highlight, the same interactive-fill-on-hover language every other
    /// button/row in the app uses (DesignTokens.Interactive.fillHover),
    /// rather than the popup rows having no hover feedback at all.
    @State private var hoveredStagingID: ConvertJob.ID? = nil

    /// Captured once the queue's ScrollView appears, so runConversion can
    /// scroll a just-started job into view without needing its own
    /// reactive hook into job.status (mutating a class's @Published
    /// property doesn't by itself invalidate this view -- see
    /// selectionVersion's own comment above for the same issue elsewhere).
    @State private var queueScrollProxy: ScrollViewProxy? = nil

    private var hasStaging: Bool { !stagingJobs.isEmpty }
    private var hasQueue: Bool { !queue.isEmpty }
    private var hasJobs: Bool { hasStaging || hasQueue }

    private var selectedStagingJob: ConvertJob? { stagingJobs.first { $0.id == selectedStagingID } }

    /// "current/total" position of the file currently shown in Analyze
    /// among every staged file (e.g. "2/3") -- nil when there's nothing to
    /// count (0 or 1 staged file), matching the old count-only label's
    /// visibility rule.
    private var stagingProgressLabel: String? {
        guard stagingJobs.count > 1,
              let selectedStagingID,
              let idx = stagingJobs.firstIndex(where: { $0.id == selectedStagingID }) else { return nil }
        return "\(idx + 1)/\(stagingJobs.count)"
    }

    /// Every queue row always shows its own checkbox now (no separate Select
    /// Mode toggle) -- "selected" just means "will be included the next time
    /// Convert is pressed."
    private var selectedQueueJobs: [ConvertJob] { _ = selectionVersion; return queue.filter { $0.isSelected } }
    private var hasSelectedQueued: Bool { selectedQueueJobs.contains { $0.status == .queued } }
    /// Any queued job at all, regardless of checkbox state — used to decide
    /// whether the Convert button shows up in the bar in the first place.
    /// Reads `selectionVersion` purely to force recomputation: `queue` is a
    /// `[ConvertJob]` of reference types behind a `@Binding`, so mutating a
    /// job's own `@Published status` (e.g. Retry/Reconvert) doesn't trigger
    /// this parent view to re-render on its own — without this, the Convert
    /// button stayed hidden after Retry even though the job was re-queued.
    private var hasQueuedJobs: Bool { _ = selectionVersion; return queue.contains { $0.status == .queued } }

    // Sum of estimated output sizes across every checked, still-queued job —
    // shown as a chip next to the always-visible SAVE TO field, mirroring
    // Download's estimated-size chip.
    private var totalEstimatedSizeLabel: String? {
        let bytes = selectedQueueJobs
            .filter { $0.status == .queued }
            .compactMap { $0.estimatedOutputBytes }
            .reduce(0, +)
        guard bytes > 0 else { return nil }
        let d = Double(bytes)
        if d >= 1_073_741_824 { return String(format: "~%.1f GB", d / 1_073_741_824) }
        if d >= 1_048_576     { return String(format: "~%.0f MB", d / 1_048_576) }
        if d >= 1_024         { return String(format: "~%.0f KB", d / 1_024) }
        return "~\(bytes) B"
    }

    private var convertButtonLabel: String {
        let count = selectedQueueJobs.filter { $0.status == .queued }.count
        if count > 1 { return "Convert \(count) Items" }
        if count == 1, let job = selectedQueueJobs.first(where: { $0.status == .queued }) {
            return job.isVideoFile ? "Convert Video" : "Convert Audio"
        }
        return "Convert"
    }
    private var isConverting: Bool { _ = selectionVersion; return queue.contains { $0.status == .converting } }

    private var queueCountLabel: String {
        let n = queue.count
        return n == 0 ? "No items in queue" : "\(n) item\(n == 1 ? "" : "s") in queue"
    }

    // Drop zone — matches urlCard's black-frosted-glass capsule/pill
    // exactly (same fieldHeight, same VisualEffectBlur + black tint +
    // white wash + grain recipe, same Capsule clip + stroke overlay) so
    // Download's paste field and Convert's drop target read as the same
    // design language instead of two different card styles (the old
    // version was a boxy RoundedRectangle using a different token family
    // entirely -- Interactive.fillRest/strokeRest instead of Glass.*).
    // Whole capsule is the button; embedded "Browse" pill mirrors urlCard's
    // embedded Paste & Analyze pill (Spotlight/Arc-style inset action)
    // instead of a second separate control living beside the capsule.
    var dropZoneView: some View {
        let fieldHeight: CGFloat = 52
        let innerPillHeight: CGFloat = fieldHeight - 10

        return HStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: isDragging ? "tray.and.arrow.down.fill" : "folder.badge.plus")
                    .font(.appMono(size: 15, weight: .thin))
                    .foregroundColor(.white.opacity(isDragging ? DesignTokens.Text.secondary : DesignTokens.Text.tertiary))
                Text(isDragging ? "Drop to add…" : "Click or drop files here")
                    .font(.appMono(size: 13))
                    .foregroundColor(.white.opacity(isDragging ? DesignTokens.Text.secondary : 0.18))
                Spacer(minLength: 0)
            }
            .padding(.leading, 14)
            .frame(height: fieldHeight, alignment: .center)
            .frame(maxWidth: .infinity)
            // Tap scoped to just this leading label/icon area, not the
            // whole outer capsule -- the embedded Browse button below is
            // its own Button and already handles taps in its own hit
            // area. A blanket .onTapGesture over the entire bar would sit
            // behind/around that Button and could double-fire
            // openFilePicker() (which blocks on a modal NSOpenPanel) if
            // SwiftUI ever routes the same tap to both recognizers.
            .contentShape(Rectangle())
            .onTapGesture { openFilePicker() }

            // Embedded "Browse" pill -- exact same GlassButton recipe as
            // urlCard's Paste & Analyze button (embedded, glow-stroke-on-
            // hover, frozen scale, fillHeight) so the two input bars share
            // one continuous silhouette instead of Download having an
            // embedded pill while Convert has a detached boxy button.
            GlassButton(
                label: "Browse",
                icon: "folder",
                tint: .white,
                horizontalPadding: 16,
                fillHeight: true,
                fitContent: true,
                embedded: true,
                activeFillOverride: (rest: 0.12, active: 0.12, hover: 0.12, press: 0.12),
                embeddedGlowStroke: true,
                scaleOverride: (hover: 1.0, press: 1.0),
                action: { openFilePicker() }
            )
            .frame(height: innerPillHeight)
            .padding(.trailing, 5)
        }
        .frame(height: fieldHeight)
        .background(
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
        // Rim glow on hover or active drag-over -- same cue as urlCard's
        // hover/focus glow, applied to this bar's outer rim so Download
        // and Convert's header bars feel identically alive.
        .overlay {
            HoverGlowRim(isActive: isDropZoneHovering || isDragging)
        }
        .contentColumn(columnWidth)
        // No blanket .onTapGesture here -- tap-to-browse is scoped to the
        // leading label area above; the embedded Browse button handles
        // its own hit area. Hover/drag feedback still applies to the
        // whole bar.
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isDropZoneHovering = hovering }
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .accessibilityIdentifier("convert_drop_zone")
        .onDrop(of: ["public.file-url"], isTargeted: $isDragging) { providers in
            for p in providers {
                p.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    DispatchQueue.main.async {
                        if let data = item as? Data,
                           let url = URL(dataRepresentation: data, relativeTo: nil) {
                            addFile(url)
                        }
                    }
                }
            }
            return true
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            // Input area — dropZoneView is now a self-contained capsule
            // with its own black-frosted-glass background (matching
            // urlCard), so no outer glassCard wrapper here -- that used to
            // double-card it (glass capsule inside a second glass
            // rounded-rect) which is also what made this drop zone sit
            // differently spaced than Download's paste field. Padding
            // recipe now matches mainPanel's urlCard call exactly: same
            // .padding(.top, 40)/.padding(.bottom, 20)/.padding(.horizontal, 16).
            dropZoneView
                .shadow(color: .black.opacity(DesignTokens.Interactive.glowShadowPeak), radius: 10, y: 4)
                .padding(.top, compactHeight ? 26 : 40)
                .padding(.bottom, compactHeight ? 12 : 20)

            // ── Analyze panel — fixed in place (never scrolls): exactly one
            // staged file at a time, switchable via the dropdown, so every
            // imported file gets its own full settings review before joining
            // the Convert Queue below.
            // zIndex above every later sibling in this VStack (the Spacer and
            // TabBottomBar below) -- the file-switcher popup is an .overlay
            // living inside analyzePanel and can extend past its own frame,
            // and without this it was being painted UNDER TabBottomBar
            // (later siblings in a VStack paint on top by default) any time
            // it overlapped it.
            if tinyHeight {
                // Too short for a pinned bar AND the Analyze panel: both scroll
                // together, so every control stays reachable and legible.
                ScrollView(showsIndicators: true) {
                    VStack(spacing: 12) {
                        analyzePanel
                            .zIndex(99)
                        convertBottomBar
                    }
                }
            } else {
                analyzePanel
                    .zIndex(99)

                Spacer(minLength: 0)

                // With no Analyze card to compete with, the bar (queue drawer,
                // SAVE TO, Convert) takes priority for space -- but only down to
                // its siblings' minimums, so a short window compresses the drawer
                // instead of overflowing. With a staged file the panel and the bar
                // share space as before.
                convertBottomBar
                    .layoutPriority(hasStaging ? 0 : 1)
            }
        }
    }

    @ViewBuilder
    private var convertBottomBar: some View {
            // ── Pinned bottom bar — SAVE TO (always on, single shared
            // destination for every job) plus the Convert Queue drawer.
            TabBottomBar(
                config: config,
                hasItems: hasJobs,
                // Always shown now -- never hidden just because the queue
                // is empty. It reads "No Items in Queue" (greyed,
                // disabled) instead of disappearing, and swaps into "Cancel
                // All" (primaryActionDangerMode) the moment anything's
                // actually converting.
                showPrimaryAction: true,
                toolsReady: toolsReady,
                primaryActionEnabled: hasSelectedQueued,
                primaryActionDisabledLabel: hasQueuedJobs ? "Select Items to Convert" : "No Items in Queue",
                primaryActionDangerMode: isConverting,
                primaryActionInProgress: isConverting,
                primaryActionLabel: convertButtonLabel,
                primaryActionIcon: "arrow.triangle.2.circlepath",
                onClearAll: {},
                onPrimaryAction: {
                    if isConverting {
                        // Stops the whole run, not just the item in flight --
                        // also flips every still-queued job to .cancelled so
                        // advanceQueue (triggered once the in-flight job's
                        // process actually finishes terminating) has nothing
                        // left to pick up and start next.
                        for job in queue where job.status == .converting { job.cancel() }
                        for job in queue where job.status == .queued {
                            job.status = .cancelled
                            job.progress = "Cancelled"
                        }
                        selectionVersion += 1
                    } else {
                        convertSelected()
                    }
                },
                showClearAll: false,
                // The drawer's only content with an empty queue is "No items in
                // queue", which the disabled primary button already says.
                showExtraControls: !queue.isEmpty,
                hasBatchDirectoryControl: true,
                leftControls: { EmptyView() },
                extraControls: { queueDrawer },
                batchDirectoryControl: { batchDirectoryField }
            )
    }

    // MARK: - Analyze panel

    /// Custom popup listing every staged file, styled as a plain greyscale
    /// expansion of the trigger pill (no accent color -- that's reserved for
    /// the trigger itself) rather than a native macOS menu. Rendered via
    /// .overlay on the trigger, so it floats above the rest of the panel
    /// without pushing or resizing anything. Always shows each file's full
    /// name (no truncation), capped at ~65% of the Analyze card's own width
    /// so a very long name wraps instead of growing the popup unbounded.
    private var fileSwitcherPopup: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(stagingJobs.enumerated()), id: \.element.id) { index, staged in
                let isCurrent = staged.id == selectedStagingID
                let isHovered = hoveredStagingID == staged.id
                Button {
                    withAnimation(.spring(response: 0.2)) {
                        selectedStagingID = staged.id
                        isFileSwitcherOpen = false
                    }
                } label: {
                    HStack(spacing: 8) {
                        // Position number instead of a generic doc icon --
                        // matches the same numbering convention the Convert
                        // Queue rows use.
                        Text("\(index + 1)")
                            .font(.appMono(size: 10, weight: .bold))
                            .foregroundColor(.white.opacity(isCurrent ? DesignTokens.Text.primary : DesignTokens.Text.tertiary))
                            .frame(width: 14, alignment: .center)
                        // No lineLimit/truncation here -- the popup should
                        // always show the full filename rather than an
                        // ellipsis, relying on the popup's own maxWidth cap
                        // below (and natural wrapping) to keep it bounded.
                        Text(staged.inputURL.deletingPathExtension().lastPathComponent)
                        Spacer(minLength: 8)
                        if isCurrent {
                            Image(systemName: "checkmark")
                                .font(.appMono(size: 10, weight: .bold))
                        }
                    }
                    .font(.appMono(size: 12, weight: .medium))
                    .foregroundColor(isCurrent ? .white : .white.opacity(DesignTokens.Text.secondary))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Same interactive-fill language as every other
                    // button/row in the app: a plain rest state, a
                    // brighter wash on hover, and the current selection
                    // keeps its own steady highlight regardless of hover.
                    .background(
                        Color.white.opacity(
                            isCurrent
                                ? 0.14
                                : (isHovered ? DesignTokens.Interactive.fillHover * 0.4 : 0)
                        )
                    )
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { hovering in hoveredStagingID = hovering ? staged.id : (hoveredStagingID == staged.id ? nil : hoveredStagingID) }
            }
        }
        .padding(4)
        // Capped at ~65% of the Analyze card's own width (the shared content
        // column is the card's width -- see analyzePanel's own frame) rather
        // than pinned to fileSwitcherTriggerWidth like before -- full
        // filenames need room to grow past the trigger pill's width, but
        // still shouldn't be free to blow out to an arbitrary width for a
        // very long name.
        .frame(maxWidth: columnWidth > 0 ? columnWidth * 0.65 : nil, alignment: .leading)
        .background(
            ZStack {
                VisualEffectBlur(material: DesignTokens.Glass.material, blendingMode: .behindWindow)
                Color.black.opacity(DesignTokens.Glass.blackTint)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.large, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.large, style: .continuous)
            .stroke(Color.white.opacity(DesignTokens.Field.borderRest), lineWidth: 1))
        // Two stacked shadows for real depth (a tight dark contact shadow
        // plus a soft wide one) -- a single subtle shadow read as
        // basically invisible against the app's already-black background.
        .shadow(color: .black.opacity(0.5), radius: 6, y: 3)
        .shadow(color: .black.opacity(0.6), radius: 24, y: 12)
    }

    /// The one staged file currently being configured, plus a dropdown to
    /// switch between every staged file and buttons to commit it (or all of
    /// them) to the Convert Queue. Empty state when nothing's staged.
    @ViewBuilder
    private var analyzePanel: some View {
        if let job = selectedStagingJob {
            VStack(alignment: .leading, spacing: 12) {
                if !compactHeight {
                Label("ANALYZE", systemImage: "slider.horizontal.3")
                    .font(.appMono(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                }
                // zIndex(99) here, not just on the popup's own local ZStack
                // below -- this HStack is the EARLIER of two siblings in
                // analyzePanel's VStack (ConvertPreviewCard, the full
                // settings card, comes right after it), and a VStack paints
                // later children on top of earlier ones by default. The
                // popup is an .overlay attached deep inside this HStack, so
                // without raising the HStack itself, ConvertPreviewCard's
                // own opaque background was painting over the popup even
                // though the popup's local zIndex(20) "won" against its own
                // tap-catcher sibling -- that locality is exactly the bug:
                // zIndex only orders siblings sharing the same parent, and
                // the real occluding view lived one level up.
                HStack(alignment: .center, spacing: 8) {
                    // Pill-chip design (Capsule, accent-tinted fill + border,
                    // matching the app's chip language elsewhere), and the
                    // popup itself is fully custom -- an expanded version of
                    // the same pill acting as an .overlay (so it floats above
                    // everything without shifting any surrounding layout,
                    // and never a native macOS menu).
                    Button {
                        withAnimation(.spring(response: 0.25)) { isFileSwitcherOpen.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text")
                                .font(.appMono(size: 10, weight: .semibold))
                            Text(job.inputURL.deletingPathExtension().lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Image(systemName: isFileSwitcherOpen ? "chevron.up" : "chevron.down")
                                .font(.appMono(size: 9, weight: .bold))
                        }
                        .font(.appMono(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(DesignTokens.Text.secondary))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(isFileSwitcherOpen ? 0.16 : 0.08))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(DesignTokens.Field.borderRest), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .topLeading) {
                        if isFileSwitcherOpen {
                            ZStack(alignment: .topLeading) {
                                // Oversized, effectively-invisible tap catcher
                                // so clicking anywhere else dismisses the
                                // popup -- sits behind it in this same
                                // overlay group, never affecting layout.
                                Color.black.opacity(0.001)
                                    .frame(width: 3000, height: 3000)
                                    .offset(x: -1200, y: -1200)
                                    .onTapGesture {
                                        withAnimation(.spring(response: 0.2)) { isFileSwitcherOpen = false }
                                    }
                                fileSwitcherPopup
                                    .offset(y: 40)
                            }
                            .zIndex(20)
                            // Unfolds out of the trigger pill (top-leading corner)
                            // with blur + scale only -- the popup is a glass
                            // surface, so no opacity (see FocusEffect).
                            .transition(.focus(blur: 10, scale: 0.9, anchor: .topLeading))
                        }
                    }
                    if let stagingProgressLabel {
                        Text(stagingProgressLabel)
                            .font(.appMono(size: 11))
                            .foregroundColor(.white.opacity(DesignTokens.Text.disabled))
                    }
                    Spacer()
                }
                .zIndex(99)
                // The settings card hugs its content when the window is tall
                // enough for all of it, and scrolls inside the panel when it
                // isn't -- this panel used to be "fixed in place (never
                // scrolls)", which forced the whole window to be ~960pt tall
                // on this tab (the window silently grew when you switched
                // here). Add to Queue below stays pinned either way.
                let settingsCard = ConvertPreviewCard(
                    job: job,
                    config: config,
                    onRemove: { removeFromStaging(job) },
                    isQueueRow: false
                )
                ViewThatFits(in: .vertical) {
                    settingsCard
                    ScrollView(.vertical, showsIndicators: true) { settingsCard }
                        .frame(minHeight: compactHeight ? 110 : 130)
                }
                // Add to Queue / Add All to Queue -- moved to the bottom of
                // the Analyze card (below the full settings card) rather
                // than sitting up in the header row beside the file
                // switcher, so committing a file to the queue reads as the
                // final action after reviewing/adjusting its settings, not
                // a header-row control competing with the switcher for space.
                HStack(spacing: 8) {
                    Spacer()
                    if stagingJobs.count > 1 {
                        GlassButton(label: "Add All to Queue", icon: "tray.and.arrow.down", tint: .white, fitContent: true) {
                            addAllToQueue()
                        }
                    }
                    GlassButton(label: "Add to Queue", icon: "arrow.turn.down.right", tint: DesignTokens.Accent.primary, fitContent: true) {
                        addToQueue(job)
                    }
                }
            }
            .padding(16)
            // Outer container dimmed to 0.35 like queueDrawer/batchDirectoryField:
            // the ConvertPreviewCard nested inside is itself a full-strength
            // glassCard, and two stacked full-strength layers read as muddy.
            .glassCard(cornerRadius: DesignTokens.Radius.xlarge, opacity: 0.35)
            .shadow(color: .black.opacity(DesignTokens.Interactive.glowShadowPeak), radius: 10, y: 4)
            .contentColumn(columnWidth)
            // Both branches of this if/else take layout space, so the outgoing
            // one must leave instantly -- see AnyTransition.glassPopInOnly.
            .transition(.glassPopInOnly)
        } else {
            EmptyStateView(
                icon: "arrow.triangle.2.circlepath",
                title: "Drop files to convert",
                subtitle: "Supports any format ffmpeg can read"
            )
            // Hard minimum kept low: it counts toward the window's minimum
            // height, and this state also holds the whole bottom bar.
            .frame(maxWidth: .infinity, minHeight: compactHeight ? 80 : 120)
            .transition(.blurInOnly)
        }
    }

    // MARK: - Convert Queue drawer (lives in the bottom bar, above SAVE TO)

    /// Real row height (including the LazyVStack's own inter-row spacing),
    /// measured live off the first rendered row rather than hardcoded --
    /// used as the drag-swap threshold below, and to derive the drawer's
    /// fixed viewport height. This used to be a hardcoded guess that had to
    /// be manually re-tuned by hand every time the row's own content
    /// changed height (exactly what motivated switching to a real
    /// measurement: the row's leading drag-handle column has grown twice
    /// now as arrows were added to it, and a stale guess here silently
    /// desyncs the drag-swap point from where the row actually is on
    /// screen). Starts at a reasonable fallback before the first row has
    /// ever reported its real size.
    @State private var queueRowStride: CGFloat = 76

    /// Fixed viewport height for the row list -- always this tall while
    /// expanded (about 2.5 rows), regardless of how many items are actually
    /// queued. It does NOT grow with item count (extra items scroll inside
    /// it instead); it only ever shrinks if the window itself is too short
    /// to offer this much room, via ordinary layout compression, not a
    /// content-driven calculation.
    private var queueDrawerHeight: CGFloat { queueRowStride * 2.5 }

    /// Collapsible drawer rendered inside the bottom bar's extraControls
    /// slot, above the SAVE TO row. Card within a card: this whole drawer is
    /// its own nested glass surface. The row list (when expanded) sits on
    /// top with the select toolbar (collapse toggle, count, Clear Queue)
    /// pinned as a bottom bar beneath it, separated by a divider -- so
    /// expanding grows the list upward from that fixed bottom edge rather
    /// than pushing content down from a fixed top.
    private var queueDrawer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isQueueExpanded && hasQueue {
                // Plain ScrollView + LazyVStack (not List) -- same container
                // pattern already proven throughout the rest of the app, and
                // avoids List's native macOS drag visual (a free-floating
                // snapshot of the row) that doesn't match the confined,
                // swap-in-place behavior implemented in QueueRowView below.
                //
                // Fixed .frame(height:) instead of a GeometryReader-derived
                // size -- the previous GeometryReader approach reported
                // whatever leftover space the surrounding VStack happened to
                // have at that moment, which both grew with item count and
                // occasionally mismatched the glassCard's own background
                // height (the "black bar" clipping mid-row). A plain fixed
                // height is deterministic: the card background and the
                // scroll viewport are now sized off the exact same number.
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(Array(queue.enumerated()), id: \.element.id) { index, job in
                                QueueRowView(
                                    job: job, index: index, position: index + 1, queue: $queue, config: config,
                                    onSelectionChange: { selectionVersion += 1 },
                                    onEditRequested: (job.status == .queued || job.status == .failed || job.status == .cancelled)
                                        ? { editFromQueue(job) } : nil
                                )
                                .id(job.id)
                                // Measures the real on-screen stride (row
                                // height + the LazyVStack's own 6pt
                                // spacing) so queueDrawerHeight always
                                // matches reality instead of a hand-tuned
                                // guess. Every row reports this, not just
                                // the first -- harmless (rows are visually
                                // uniform, and onChange only fires on an
                                // actual value change).
                                .background(
                                    GeometryReader { geo in
                                        Color.clear
                                            .onAppear { queueRowStride = geo.size.height + 6 }
                                            .onChange(of: geo.size.height) { _, h in queueRowStride = h + 6 }
                                    }
                                )
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onAppear { queueScrollProxy = proxy }
                }
                // When the Analyze card is showing (hasStaging), it and the
                // queue are competing for the same vertical space, so this
                // is only a CAP (maxHeight) -- ordinary layout can still
                // compress it if the window's genuinely too short. When
                // there's no Analyze card, nothing else needs that room, so
                // this locks to exactly queueDrawerHeight (a real
                // .frame(height:), not just a cap) rather than letting it
                // sit smaller than its stated max just because the current
                // queue is short.
                //
                // Flexible between one row and queueDrawerHeight, NOT a fixed
                // height: SwiftUI treats a fixed frame as a hard minimum and grows
                // the window to fit it (adding the first file used to grow the
                // window ~150pt and it never shrank back). The ScrollView is
                // greedy, so with room to spare it still fills to the max; the bar
                // is given layoutPriority in the queue-only state (see body) so it
                // claims that room ahead of the empty state.
                .frame(minHeight: hasStaging ? nil : queueRowStride, maxHeight: queueDrawerHeight)
                GlassDivider()
            }
            HStack(spacing: 8) {
                if hasQueue {
                    HoverIconButton(
                        icon: isQueueExpanded ? "chevron.down" : "chevron.up",
                        size: 11,
                        help: isQueueExpanded ? "Collapse" : "Expand",
                        expandable: true
                    ) {
                        withAnimation(.spring(response: 0.25)) { isQueueExpanded.toggle() }
                    }
                }
                Text(queueCountLabel)
                    .font(.appMono(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                Spacer()
                if hasQueue {
                    // .fixedSize() locks this to its own natural size --
                    // without it, the Text inside GlassButton has a
                    // minimumScaleFactor that can shrink the label if
                    // anything upstream ever proposes it less width than it
                    // wants, which is what made it visibly shrink when the
                    // row list above pushed this bar's layout around.
                    GlassButton(label: "Clear Queue", icon: "trash", tint: .red, fitContent: true) {
                        withAnimation(.spring(response: 0.3)) {
                            for job in queue where job.status == .converting { job.cancel() }
                            queue.removeAll()
                        }
                    }
                    .fixedSize()
                }
            }
        }
        .padding(12)
        .glassCard(cornerRadius: DesignTokens.Radius.medium, opacity: 0.35)
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        if panel.runModal() == .OK {
            panel.urls.forEach { addFile($0) }
        }
    }

    private func addFile(_ url: URL) {
        let job = ConvertJob(inputURL: url)
        withAnimation(.spring(response: 0.35)) {
            stagingJobs.append(job)
            // Jump the Analyze panel to whatever was just imported -- for a
            // multi-file import this lands on the last one, which still puts
            // every file in the dropdown for review in any order.
            selectedStagingID = job.id
        }
    }

    /// Commits one staged job to the Convert Queue (appended at the end) and
    /// moves the Analyze panel to another remaining staged file, if any.
    private func addToQueue(_ job: ConvertJob) {
        withAnimation(.spring(response: 0.35)) {
            stagingJobs.removeAll { $0.id == job.id }
            queue.append(job)
            selectedStagingID = stagingJobs.last?.id
        }
        selectionVersion += 1
    }

    /// Commits every remaining staged job to the Convert Queue at once, each
    /// with whatever settings it currently has (default or already customized).
    private func addAllToQueue() {
        withAnimation(.spring(response: 0.35)) {
            queue.append(contentsOf: stagingJobs)
            stagingJobs.removeAll()
            selectedStagingID = nil
        }
        selectionVersion += 1
    }

    private func removeFromStaging(_ job: ConvertJob) {
        withAnimation(.spring(response: 0.3)) {
            stagingJobs.removeAll { $0.id == job.id }
            if selectedStagingID == job.id { selectedStagingID = stagingJobs.last?.id }
        }
    }

    /// Pulls a queued (or failed/cancelled) job back out to the Analyze
    /// panel for editing/reconverting. Resets any partial-run state
    /// (progress/output) so it starts clean once it's added back to the
    /// queue -- this is now the only path back to a runnable state for a
    /// failed/cancelled job, since there's no more dedicated Retry/
    /// Reconvert button on the row itself.
    private func editFromQueue(_ job: ConvertJob) {
        withAnimation(.spring(response: 0.3)) {
            queue.removeAll { $0.id == job.id }
            job.status = .queued
            job.progress = "Queued"
            job.progressFraction = nil
            job.etaText = ""
            job.outputURL = nil
            stagingJobs.append(job)
            selectedStagingID = job.id
        }
        selectionVersion += 1
    }

    private func convertSelected() {
        // Kicks off just the first eligible job -- advanceQueue (called
        // again from runConversion's own completion handler) chains
        // through the rest in queue order, one at a time.
        advanceQueue()
    }

    /// Starts the next selected, still-queued job in queue order (top to
    /// bottom), or does nothing if there isn't one. This is the ONLY thing
    /// that calls runConversion, and it's only ever called once to kick off
    /// a run (convertSelected) or again after a job reaches a terminal
    /// state (done/failed/cancelled) -- so exactly one job converts at a
    /// time instead of every selected job's ffmpeg process firing at once.
    /// Concurrent encodes were competing for the same CPU cores, making a
    /// multi-file batch slower overall than converting them one by one, and
    /// made per-item progress/ETA meaningless while several ran at once.
    private func advanceQueue() {
        guard let next = queue.first(where: { $0.isSelected && $0.status == .queued }) else { return }
        runConversion(job: next)
    }

    /// Compact inline SAVE TO control, rendered in TabBottomBar's top row (to
    /// the right of the Auto-Open Folder toggle). Always visible now -- one
    /// shared destination folder for every conversion, batch mode or not,
    /// matching Download's own permanent SAVE TO field. Defaults to Downloads
    /// and remembers the last folder picked (persisted in config.convertOutputDir).
    private var batchDirectoryField: some View {
        VStack(alignment: .leading, spacing: DropGrid.labelSpacing) {
            // Dropped in a short window (see WindowLayout.compactHeightBreakpoint)
            // to give the queue and Analyze panel the room.
            if !compactHeight {
            HStack(spacing: DropGrid.labelSpacing) {
                Image(systemName: "folder")
                    .font(.appMono(size: DropGrid.microLabelSize, weight: .semibold))
                    .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                    .frame(width: 14, alignment: .center)
                Text("SAVE TO")
                    .font(.appMono(size: DropGrid.microLabelSize, weight: .semibold))
                    .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                // Always reserve the chip's slot in Select mode so the row
                // doesn't shift/resize the moment something becomes selected —
                // it just renders blank (no icon/text) until totalEstimatedSizeLabel
                // has a value.
                Spacer()
                HStack(spacing: 4) {
                    if let sizeLabel = totalEstimatedSizeLabel {
                        Image(systemName: "internaldrive")
                            .font(.appMono(size: 9))
                        Text(sizeLabel)
                            .font(.appMono(size: 10, weight: .semibold))
                    }
                }
                .frame(minHeight: 10)
                .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(totalEstimatedSizeLabel == nil ? 0.0 : DesignTokens.Interactive.fillRest))
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous))
            }
            }
            HStack(spacing: DropGrid.rowSpacing) {
                HStack(spacing: DropGrid.rowSpacing) {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.white.opacity(DesignTokens.Text.secondary))
                        .font(.appMono(size: DropGrid.fieldFontSize))
                    Text(config.convertOutputDir)
                        .font(.appMono(size: DropGrid.fieldFontSize))
                        .foregroundColor(.white.opacity(DesignTokens.Text.secondary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: DropGrid.controlHeight)
                .padding(.horizontal, 8)
                .background(Color.white.opacity(DropGrid.fieldFillOpacity))
                .clipShape(RoundedRectangle(cornerRadius: DropGrid.fieldCorner, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DropGrid.fieldCorner, style: .continuous)
                    .stroke(Color.white.opacity(DropGrid.fieldBorderOpacity), lineWidth: DropGrid.fieldBorderWidth))

                GlassButton(label: "Browse", icon: "folder", tint: DesignTokens.Accent.primary, verticalPadding: 4, fillHeight: true) {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.canCreateDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.prompt = "Select"
                    if panel.runModal() == .OK, let url = panel.url {
                        config.convertOutputDir = url.path
                    }
                }
                .frame(width: DropGrid.buttonColumnWidth, height: DropGrid.controlHeight)
                // Always-available Reveal -- replaces the per-row "Reveal in
                // Finder" button a completed job used to have. This one
                // isn't tied to any single job: it just opens the shared
                // SAVE TO destination, usable any time regardless of
                // whether anything's finished converting yet.
                HoverIconButton(icon: "arrow.up.forward.app", size: 13, help: "Open the SAVE TO folder in Finder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: config.convertOutputDir))
                }
                .frame(height: DropGrid.controlHeight)
            }
        }
        .frame(maxWidth: .infinity)
        // Card within a card -- same nested-glass treatment as Download's
        // own SAVE TO section and Convert's Queue drawer above, so this
        // slot reads consistently across both tabs.
        .padding(10)
        .glassCard(cornerRadius: DesignTokens.Radius.medium, opacity: 0.35)
    }

    private func runConversion(job: ConvertJob) {
        guard let ffmpeg = ffmpegPath else {
            // Same stall this class of guard already caused in Download's queue
            // (fixed in d9f9ebe): silently returning here leaves this job stuck
            // in .queued forever AND stops the rest of the batch, since nothing
            // else will ever call advanceQueue() again.
            job.status = .failed
            job.progress = "ffmpeg not found"
            manager.appendLog("Convert: ERROR — \(job.inputURL.lastPathComponent): ffmpeg not found")
            advanceQueue()
            return
        }
        // Destination folder is the single shared SAVE TO field in the bottom
        // bar (same folder for every job, mirrors Download's tab).
        let dir = URL(fileURLWithPath: config.convertOutputDir)
        let output = dir.appendingPathComponent(job.outputFilename)
        job.status = .converting
        selectionVersion += 1
        job.progress = "Starting…"
        job.progressFraction = nil
        job.etaText = "0%"
        job.outputURL = output
        manager.appendLog("Convert: Starting \(job.inputURL.lastPathComponent) → \(output.lastPathComponent)")
        withAnimation(.easeOut(duration: 0.3)) {
            queueScrollProxy?.scrollTo(job.id, anchor: .center)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            job.process = p
            p.executableURL = URL(fileURLWithPath: ffmpeg)
            var args = ["-y", "-i", job.inputURL.path]  // -y: always overwrite, always run a fresh process
            // Audio stream — stream-copy (no re-encode) whenever the chosen codec
            // already matches the source (as before), OR the VIDEO/AUDIO layer's
            // "Same as Source" chip is selected ("leave this side alone"). That
            // chip never forces a copy that isn't actually valid for the source/
            // container combination — it only skips re-encoding when the source
            // already is (or can be treated as) the selected codec.
            if job.mediaMode != .videoOnly {
                let audioMatches = job.audioCodecMatchesSource
                // Stream-copy is only ever valid when the codec ffmpeg would
                // be asked to copy already matches the source -- NOT merely
                // whenever transcodeAudio is false ("Same as Source"
                // selected). A self-contained target format like MP3/WAV/
                // FLAC has exactly one legal codec (audioCodec is forced to
                // it regardless of the toggle), and there is no "Same as
                // Source" option to fall back to when the real source codec
                // isn't already that one -- ffmpeg then rejects "-c:a copy"
                // outright ("Invalid audio stream. Exactly one MP3 audio
                // stream is required.") since raw PCM can't be poured into
                // an MP3 container unencoded. transcodeAudio only decides
                // which chip glows as selected in the UI; it must never be
                // allowed to force an impossible copy.
                let encodeAudio = !audioMatches
                args += ["-c:a", encodeAudio ? job.audioCodec.ffmpegCodec : "copy"]
                // 5.1/7.1 sources need more headroom than stereo to avoid audible
                // compression artifacts — 384k covers 5.1 cleanly, 256k is plenty for stereo/mono.
                let isMultichannel = (job.mediaInfo?.audioChannelLabel).map { $0 == "5.1" || $0 == "7.1" } ?? false
                if encodeAudio && job.audioCodec == .aac { args += ["-b:a", isMultichannel ? "384k" : "256k"] }
                if encodeAudio && job.audioCodec == .mp3 {
                    args += ["-b:a", "320k"]
                    // MP3 (libmp3lame) only supports mono/stereo -- a
                    // >2-channel source (5.1, 7.1) gets silently downmixed
                    // by the encoder's own default behavior if left
                    // unspecified. That's not wrong, but relying on an
                    // implicit encoder default for something this
                    // consequential is fragile across ffmpeg versions/
                    // builds; -ac 2 makes the downmix explicit and
                    // guaranteed. See displayAudioChannelLabel for the
                    // matching UI-side fix (the output chip must say "2.0"
                    // here, not the source's real channel count).
                    if isMultichannel { args += ["-ac", "2"] }
                }
                // Explicitly re-tag the channel layout when re-encoding multichannel audio
                // to AAC. Root cause of "audio imports but is silent / gets split into
                // separate mono tracks in Resolve": many sources (esp. Dolby/E-AC-3 rips)
                // carry a non-standard layout spelling like "5.1(side)" rather than plain
                // "5.1". ffmpeg's AAC encoder happily encodes it, but writes that same
                // non-standard layout tag into the MOV/MP4 container. QuickTime-family
                // decoders (which Resolve's import path is built on) don't recognize
                // "5.1(side)" as a valid MOV channel layout and fall back to exposing
                // each channel as its own untagged mono stream — reproduced and verified
                // on-device: re-reading a "5.1(side)"-tagged AAC/MOV file back through
                // ffmpeg itself required "Guessed Channel Layout", proving the container
                // tag wasn't trustworthy even to ffmpeg's own reader. Forcing the standard
                // "5.1"/"7.1"/"stereo" layout name via -channel_layout normalizes the tag
                // ffmpeg writes into the container, and the same re-read test showed a
                // clean tag with no guessing afterward.
                if encodeAudio && job.audioCodec == .aac {
                    let layoutArg: String? = {
                        switch job.mediaInfo?.audioChannelLabel {
                        case "5.1": return "5.1"
                        case "7.1": return "7.1"
                        case "2.0": return "stereo"
                        case "1.0": return "mono"
                        default: return nil  // unrecognized/uncommon layouts: let ffmpeg pass the source layout through untouched
                        }
                    }()
                    if let layoutArg { args += ["-channel_layout", layoutArg] }
                }
            } else {
                args += ["-an"] // no audio
            }
            // Video stream — same copy-vs-encode rule as audio above: only
            // ever stream-copy when the codec actually matches the source,
            // regardless of the "Same as Source" toggle (see the audio
            // branch's comment above for why -- e.g. a ProRes .mov
            // converted to MP4, which can't hold ProRes at all, needs to
            // encode even with "Same as Source" left selected).
            if job.mediaMode.isVideo {
                let videoMatches = job.videoCodecMatchesSource
                let encodeVideo = !videoMatches
                args += ["-c:v", encodeVideo ? job.videoCodec.ffmpegCodec : "copy"]
                // -preset fast: significantly faster encode with minimal quality loss
                if encodeVideo && (job.videoCodec == .h264 || job.videoCodec == .h265) {
                    args += ["-preset", "fast"]
                }
                // HEVC needs an explicit "hvc1" container tag for QuickTime
                // Player, Preview, Final Cut, and DaVinci Resolve's MOV/MP4
                // import path to recognize it at all -- libx265 (and many
                // non-Apple sources) instead tag it "hev1", the ISO generic
                // tag. A "hev1"-tagged file is valid HEVC (plays fine in
                // VLC/ffplay) but shows as no video / won't open in any of
                // those Apple-ecosystem tools. Confirmed on-device: ffprobe
                // reports "hevc (Rext) (hev1 / 0x31766568)" for a fresh
                // libx265 encode without this. -tag:v is a container-level
                // fourcc rewrite, not a re-encode, so it's applied whenever
                // the OUTPUT is H.265 into MP4/MOV regardless of whether
                // this track is being encoded or stream-copied -- a
                // hev1-tagged HEVC source that's simply being remixed
                // through (e.g. re-encoding only the audio, video left
                // "Same as Source") would otherwise carry the same
                // incompatible tag straight through untouched. Only
                // meaningful for the two Apple-lineage containers -- MKV
                // doesn't have this requirement at all.
                if job.videoCodec == .h265 && (job.outputFormat == .mp4 || job.outputFormat == .mov) {
                    args += ["-tag:v", "hvc1"]
                }
                // libsvtav1 uses its own preset scale (0-13, lower = slower/better) — 8 is a
                // reasonable speed/quality balance, verified to encode successfully on-device.
                if encodeVideo && job.videoCodec == .av1 {
                    args += ["-preset", "8", "-crf", "35"]
                }
                // libvpx-vp9 needs -b:v 0 to actually respect -crf (otherwise it defaults to
                // a bitrate-controlled mode and ignores the quality target).
                if encodeVideo && job.videoCodec == .vp9 {
                    args += ["-crf", "32", "-b:v", "0"]
                }
            } else {
                args += ["-vn"] // no video
            }
            args.append(output.path)
            p.arguments = args

            DispatchQueue.main.async {
                self.manager.appendLog("Convert: ffmpeg \(args.joined(separator: " "))")
            }

            let errPipe = Pipe()
            p.standardOutput = Pipe()
            p.standardError = errPipe

            let totalDuration = job.mediaInfo?.durationSeconds
            errPipe.fileHandleForReading.readabilityHandler = { fh in
                let data = fh.availableData
                guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
                let lines = str.components(separatedBy: "\r")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                guard let last = lines.last else { return }
                // Log every raw ffmpeg line (not just the friendly summary) so the
                // exportable log has full detail for troubleshooting.
                DispatchQueue.main.async { self.manager.appendLog(last) }
                // ffmpeg's progress lines look like:
                // "frame=  120 fps=30 q=-1.0 size=    512kB time=00:00:04.00 bitrate= 1024.0kbits/s speed=1.2x"
                // Parse time= against the known source duration for a 0-1 fraction
                // (mirrors yt-dlp's percent-based progress bar on the Download tab),
                // and build a friendly one-line summary in place of the raw ffmpeg text.
                var fraction: Double? = nil
                var friendly = last
                var eta = ""
                if let timeRange = last.range(of: "time="), let total = totalDuration, total > 0 {
                    let afterTime = last[timeRange.upperBound...]
                    let timeStr = afterTime.prefix(while: { $0 != " " })
                    let comps = timeStr.split(separator: ":").map(String.init)
                    var elapsed: Double? = nil
                    if comps.count == 3, let h = Double(comps[0]), let m = Double(comps[1]), let s = Double(comps[2]) {
                        let e = h * 3600 + m * 60 + s
                        elapsed = e
                        fraction = min(max(e / total, 0), 1)
                    }
                    var parts: [String] = []
                    var speedMultiplier: Double? = nil
                    if let speedRange = last.range(of: "speed=") {
                        let speedStr = last[speedRange.upperBound...].trimmingCharacters(in: .whitespaces).prefix(while: { $0 != " " })
                        if !speedStr.isEmpty && !speedStr.contains("N/A") {
                            parts.append("\(speedStr) speed")
                            speedMultiplier = Double(speedStr.trimmingCharacters(in: CharacterSet(charactersIn: "x")))
                        }
                    }
                    if let bitrateRange = last.range(of: "bitrate=") {
                        let bitrateStr = last[bitrateRange.upperBound...].trimmingCharacters(in: .whitespaces).prefix(while: { $0 != " " })
                        if !bitrateStr.isEmpty && !bitrateStr.contains("N/A") { parts.append("\(bitrateStr)") }
                    }
                    friendly = parts.isEmpty ? "Converting…" : "Converting — " + parts.joined(separator: " · ")

                    // Percentage + ETA readout for the right side of the row.
                    // ffmpeg's speed= is a multiplier on real time (e.g. "1.2x"
                    // means 1.2s of media processed per second of wall time),
                    // so remaining wall-clock seconds = remaining media
                    // seconds / speed. Only show a real countdown once both
                    // the fraction and a sane speed multiplier are known —
                    // otherwise fall back to percentage-only.
                    if let e = elapsed {
                        let pctLabel = "\(Int((min(max(e / total, 0), 1) * 100).rounded()))%"
                        if let mult = speedMultiplier, mult > 0.01 {
                            let remainingSeconds = max(total - e, 0) / mult
                            if remainingSeconds >= 1 {
                                let etaStr = ConvertJob.formatETA(remainingSeconds)
                                eta = "\(pctLabel)  ·  \(etaStr) left"
                            } else {
                                eta = pctLabel
                            }
                        } else {
                            eta = pctLabel
                        }
                    }
                }
                DispatchQueue.main.async {
                    job.progress = friendly
                    if let fraction { job.progressFraction = fraction }
                    if !eta.isEmpty { job.etaText = eta }
                }
            }

            do {
                try p.run(); p.waitUntilExit()
                errPipe.fileHandleForReading.readabilityHandler = nil
                DispatchQueue.main.async {
                    // advanceQueue on the way out of every branch below
                    // (including this early return) so a cancelled job
                    // still lets the rest of the queue keep moving.
                    guard job.status != .cancelled else { self.advanceQueue(); return }
                    let success = p.terminationStatus == 0
                    job.status = success ? .done : .failed
                    self.selectionVersion += 1
                    job.progress = success ? "Done" : "Failed (exit \(p.terminationStatus))"
                    job.etaText = ""
                    self.manager.appendLog(success ? "Convert: ✓ Done: \(output.lastPathComponent)" : "Convert: ERROR — \(job.inputURL.lastPathComponent) failed (exit \(p.terminationStatus))")
                    // Real output size, read from disk now that the file exists.
                    let outputSizeString: String? = success ? ConvertJob.fileSizeLabel(at: output) : nil
                    job.outputSizeLabel = outputSizeString
                    // Codec/quality descriptor for the history chip — video gets codec + resolution,
                    // audio-only gets codec + bitrate. Falls back gracefully if info is unavailable.
                    let qualityDescriptor: String = {
                        if job.mediaMode.isVideo {
                            if let w = job.mediaInfo?.pixelWidth, let h = job.mediaInfo?.pixelHeight, w > 0, h > 0 {
                                return "\(job.displayVideoCodec) · \(h)p"
                            }
                            return job.displayVideoCodec
                        } else {
                            return "\(job.displayAudioCodec) · \(job.audioCodec.typicalBitrateKbps)kbps"
                        }
                    }()
                    // Save to history. `url` stays the ORIGINAL input path for
                    // reference, while `outputFilePath` points at the actual
                    // produced file so subtext/Reveal can target the real result.
                    let e = HistoryEntry(
                        title: output.deletingPathExtension().lastPathComponent,
                        url: job.inputURL.path,
                        format: job.outputFormat.rawValue,  // use output format, not audio codec
                        quality: qualityDescriptor,
                        outputDir: dir.path,
                        fileSize: outputSizeString,
                        failed: !success,
                        errorMessage: success ? nil : "Exit code \(p.terminationStatus)",
                        mediaModeRaw: job.isVideoFile ? "video" : "audio",
                        thumbnailURL: "",
                        entryType: "conversion",
                        outputFilePath: success ? output.path : job.inputURL.path,
                        audioCodecLabel: job.mediaMode != .videoOnly ? job.displayAudioCodec : ""
                    )
                    self.history.add(e)
                    if success {
                        HistoryThumbnailer.generate(for: output) { fileURLString in
                            guard let fileURLString else { return }
                            DispatchQueue.main.async {
                                self.history.updateThumbnail(id: e.id, thumbnailURL: fileURLString)
                            }
                        }
                    }
                    self.advanceQueue()
                }
            } catch {
                // p.run() never succeeded, so the success path's own
                // readabilityHandler = nil (which closes out this GCD dispatch
                // source) never runs -- clear it here too, or the handler
                // closure (and everything it captures) leaks.
                errPipe.fileHandleForReading.readabilityHandler = nil
                DispatchQueue.main.async {
                    guard job.status != .cancelled else { self.advanceQueue(); return }
                    job.status = .failed
                    self.selectionVersion += 1
                    job.progress = error.localizedDescription
                    self.manager.appendLog("Convert: ERROR — \(job.inputURL.lastPathComponent): \(error.localizedDescription)")
                    var e = HistoryEntry(
                        title: job.inputURL.deletingPathExtension().lastPathComponent,
                        url: job.inputURL.path,
                        format: job.audioCodec.rawValue,
                        quality: "",
                        outputDir: dir.path,
                        fileSize: nil,
                        failed: true,
                        errorMessage: error.localizedDescription
                    )
                    e.entryType = "conversion"
                    self.history.add(e)
                    self.advanceQueue()
                }
            }
        }
    }
}

/// One Convert Queue row: position badge + the compact card, with up/down
/// step buttons to reorder it. Drag-to-reorder (three separate attempts --
/// a hand-rolled DragGesture with a measured-stride proposed-index
/// calculation, a drawingGroup() snapshot to fix that approach's render
/// cost, then the standard onDrag/onDrop/DropDelegate pattern used
/// throughout the wider SwiftUI ecosystem) was removed entirely at the
/// user's request after the onDrag version's drag-preview image still
/// visually separated from the card during the drag. Only the up/down
/// step buttons remain -- no drag gesture, no drop delegate, no per-row
/// "is this the one moving" state needed at all anymore.
private struct QueueRowView: View {
    @ObservedObject var job: ConvertJob
    let index: Int
    let position: Int
    @Binding var queue: [ConvertJob]
    let config: Config
    let onSelectionChange: () -> Void
    let onEditRequested: (() -> Void)?

    /// Moves this row one step up or down (a swap with its immediate
    /// neighbor), re-looking-up its real position via job.id rather than
    /// trusting `index` -- index is only "as of the last render," fine for
    /// the disabled check on the buttons below, not for a mutation that
    /// should always act on where the row genuinely is right now.
    private func moveQueueItem(by delta: Int) {
        guard let current = queue.firstIndex(where: { $0.id == job.id }) else { return }
        let target = current + delta
        guard queue.indices.contains(target) else { return }
        withAnimation(.spring(response: 0.3)) {
            queue.swapAt(current, target)
        }
    }

    private var moveControls: AnyView {
        AnyView(
            VStack(spacing: 2) {
                // Real circular HoverIconButtons (not a bare glyph) so
                // they're actually visible at a glance, not just barely
                // legible.
                HoverIconButton(icon: "chevron.up", size: 9, disabled: index == 0, help: "Move up", shape: .circle) {
                    moveQueueItem(by: -1)
                }
                HoverIconButton(icon: "chevron.down", size: 9, disabled: index == queue.count - 1, help: "Move down", shape: .circle) {
                    moveQueueItem(by: 1)
                }
            }
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("\(position)")
                .font(.appMono(size: 11, weight: .bold))
                .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                .frame(width: 18, alignment: .center)
            ConvertPreviewCard(
                job: job,
                config: config,
                onRemove: {
                    if job.status == .converting { job.cancel() }
                    withAnimation(.spring(response: 0.3)) { queue.removeAll { $0.id == job.id } }
                },
                isQueueRow: true,
                onSelectionChange: onSelectionChange,
                onEditRequested: onEditRequested,
                leadingAccessory: moveControls
            )
        }
    }
}

// MARK: - ConvertPreviewCard
//
// Switch between PreviewCard (Analyze) and CompletedCard (queue row, any status).

struct ConvertPreviewCard: View {
    @ObservedObject var job: ConvertJob
    /// Shared SAVE TO destination -- output folder now lives in the bottom
    /// bar (one folder for every job, matching Download's tab) instead of a
    /// per-card field, so this card only needs it for the completed-card's
    /// fallback path construction below.
    let config: Config
    var onRemove: () -> Void
    /// True when this card is rendering as a row in the Convert Queue drawer
    /// (compact summary, checkbox always visible, no editable settings —
    /// editing happens by pulling the job back to the Analyze panel). False
    /// when rendering as the single file being configured in Analyze (full
    /// settings, no checkbox). This is a fixed rendering context per call
    /// site, not a toggleable mode.
    var isQueueRow: Bool = false
    /// Called right after the checkbox toggles `job.isSelected`, so the parent
    /// `ConvertView` (a sibling, not an observer of this specific job) can bump
    /// its own state and re-render the queue drawer's count/enabled state.
    var onSelectionChange: () -> Void = {}
    /// Pulls this job out of the Convert Queue and back into the Analyze
    /// panel for editing. Only ever passed (non-nil) for queue rows whose
    /// status allows it (queued/failed/cancelled) — nil hides the Edit button.
    var onEditRequested: (() -> Void)? = nil
    /// Queue rows' up/down move controls, built by the caller (ConvertView's
    /// queueRow) since the actual move state lives there, not here -- this
    /// view just places whatever's given next to the checkbox.
    var leadingAccessory: AnyView? = nil

    /// Fixed width for the "Same as Source" chip in both the VIDEO CODEC and
    /// AUDIO CODEC rows -- comfortably wider than its own text, and shared by
    /// both rows so the chip renders identically in each regardless of how
    /// many real codec chips sit beside it. The real codec chips are NOT
    /// pinned to this width -- they keep SelectorChip's own default
    /// `.frame(maxWidth: .infinity)`, dynamically sharing whatever space is
    /// left in the row exactly as they did before "Same as Source" got its
    /// own fixed width.
    private static let sameAsSourceChipWidth: CGFloat = 150

    var body: some View {
        if isQueueRow {
            // Every status (including queued-but-not-started) renders as the
            // same compact summary in the drawer -- settings are never edited
            // in place there, only via Edit -> back to Analyze.
            convertCompletedCard
        } else {
            convertSettingsCard
        }
    }

    // MARK: Thumbnail helper

    /// Same skeleton-underlay + fade-in-on-arrival treatment as Download's
    /// own thumbnail (see downloadPreviewCard's thumbView) -- always
    /// returns a real view instead of nil while job.thumbnail is still
    /// nil, so the shell's own generic placeholder glyph never shows;
    /// QuickLook's async generation (see generateThumbnail) is the local
    /// equivalent of Download's AsyncImage load. Audio-only files show the
    /// waveform symbol immediately rather than waiting on QuickLook (a
    /// generic result there is rarely worth the wait); video files show a
    /// loading skeleton until QuickLook genuinely finishes, then either the
    /// real frame or a plain video symbol if it came back empty.
    private var thumbView: AnyView {
        AnyView(
            ZStack {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous)
                    .fill(Color.white.opacity(DesignTokens.Interactive.fillRest))
                if let img = job.thumbnail {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .transition(.blurIn)
                } else if !job.isVideoFile {
                    Image(systemName: "waveform")
                        .font(.appMono(size: 18))
                        .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                } else if job.thumbnailFailed {
                    Image(systemName: "video")
                        .font(.appMono(size: 18))
                        .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                } else {
                    ThumbnailSkeleton().clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous))
                }
            }
            .frame(width: 80, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous))
            .animation(.easeOut(duration: 0.2), value: job.thumbnail == nil)
        )
    }


    /// Composite subtitle: plain-text file path (same visual language as
    /// History's path subtext), then the input->output chip row -- same
    /// visual language as Download's subtitleWithURL, so a queued Convert
    /// card always shows "what you have" -> "what you'll get", matching
    /// Download instead of only showing the source side. Always visible,
    /// even collapsed -- mirrors Download exactly.
    private var subtitleView: AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 6) {
                Text(job.inputURL.path)
                    .font(.appMono(size: 10)).foregroundColor(.white.opacity(DesignTokens.Text.disabled))
                    .lineLimit(1).truncationMode(.middle)
                InputOutputChips(input: job.inputChips, output: job.outputChips)
                    .animation(nil, value: job.mediaMode)
            }
        )
    }

    /// CONVERT AS mode toggle -- same visual language as Download's modeRow
    /// (Video+Audio/Audio Only), just with the extra Video Only case Convert
    /// supports. Lives below the header, outside the thumbnail-centered
    /// group, so switching modes never touches the input side of
    /// subtitleView above.
    private var modeRow: AnyView {
        AnyView(
            OptionRow(spacing: 6) {
                ForEach(ConvertMediaMode.allCases.filter { job.isVideoFile || $0 == .audio }, id: \.rawValue) { mode in
                    CompactModeChip(label: mode.label, icon: mode.icon, isSelected: job.mediaMode == mode, tint: mode.chipTint) {
                        withAnimation(.spring(response: 0.25)) {
                            job.mediaMode = mode
                            if !job.availableFormats.contains(job.outputFormat) {
                                job.outputFormat = job.availableFormats.first ?? job.outputFormat
                            }
                            job.ensureCodecsValidForFormat()
                        }
                    }
                }
            }
        )
    }

    /// OUTPUT FORMAT chip row -- last of the four sections now (see
    /// convertSettingsCard), after the codec choices are settled.
    private var formatRow: AnyView {
        AnyView(
            OptionRow(spacing: 6) {
                ForEach(job.availableFormats) { fmt in
                    SelectorChip(
                        label: fmt.rawValue,
                        isSelected: job.outputFormat == fmt
                    ) {
                        withAnimation(.spring(response: 0.25)) {
                            job.outputFormat = fmt
                            job.ensureCodecsValidForFormat()
                        }
                    }
                }
            }
        )
    }

    /// Below the header, full-width -- divider, then CONVERT AS (conversion
    /// type) on its own, ahead of everything else. This card is only ever
    /// used in the Analyze panel now (one file, always fully shown), so
    /// there's no collapse toggle to share the line with.
    private var belowHeaderRow: AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 9) {
                GlassDivider()
                Label("CONVERT AS", systemImage: "switch.2")
                    .font(.appMono(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                modeRow
            }
        )
    }

    // MARK: Settings card (Analyze panel)

    private var convertSettingsCard: some View {
        PreviewCard(
            isSelected: job.isSelected,
            onToggleSelect: {},
            onRemove: onRemove,
            showCheckbox: false,
            thumbnail: thumbView,
            thumbnailPlaceholder: job.isVideoFile ? "video" : "waveform",
            title: job.inputURL.deletingPathExtension().lastPathComponent,
            subtitle: subtitleView, // path + input->output chip row
            belowHeader: belowHeaderRow // divider + CONVERT AS mode toggle, ahead of everything else
        ) {
            // Four sections, each with its own label, top to bottom:
            // CONVERT AS (above, in belowHeaderRow) -> VIDEO CODEC ->
            // AUDIO CODEC -> OUTPUT FORMAT. OUTPUT FOLDER lives in the
            // bottom bar (shared across every job), not here.
            VStack(alignment: .leading, spacing: 11) {
                // VIDEO CODEC — "Same as Source" is a chip alongside the real
                // codec choices rather than a separate checkbox: selecting it
                // stream-copies the source video untouched; selecting any other
                // chip transcodes with that codec. Lets you change only the
                // audio (or only the video) on a clip without touching the
                // other track.
                if job.mediaMode.isVideo {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Label("VIDEO CODEC", systemImage: "video")
                                .font(.appMono(size: 10, weight: .semibold))
                                .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                            if let source = job.videoSourceLabel {
                                Spacer()
                                Text("Original: \(source)")
                                    .font(.appMono(size: 10))
                                    .foregroundColor(.white.opacity(DesignTokens.Text.disabled))
                            }
                        }
                        OptionRow {
                            let sameAsSourceChip = SelectorChip(label: "Same as Source", isSelected: !job.transcodeVideo) {
                                withAnimation(.spring(response: 0.25)) {
                                    job.useSameAsSourceForVideo()
                                }
                            }
                            // Fixed width only when there's something else in
                            // the row to sit beside -- with no real codec
                            // chips at all, "Same as Source" is the only
                            // control here and goes full width instead of
                            // sitting narrow with dead space next to it.
                            if job.availableVideoCodecs.isEmpty {
                                sameAsSourceChip.frame(maxWidth: .infinity)
                            } else {
                                sameAsSourceChip.frame(width: Self.sameAsSourceChipWidth)
                                ForEach(job.availableVideoCodecs) { codec in
                                    SelectorChip(
                                        label: codec.rawValue,
                                        isSelected: job.transcodeVideo && job.videoCodec == codec
                                    ) {
                                        withAnimation(.spring(response: 0.25)) {
                                            job.videoCodec = codec
                                            job.transcodeVideo = true
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // AUDIO CODEC — same shape as VIDEO CODEC above. Hidden
                // entirely for video-only mode (no audio track in the
                // output at all).
                if job.mediaMode != .videoOnly {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Label("AUDIO CODEC", systemImage: "waveform")
                                .font(.appMono(size: 10, weight: .semibold))
                                .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                            if let source = job.audioSourceLabel {
                                Spacer()
                                Text("Original: \(source)")
                                    .font(.appMono(size: 10))
                                    .foregroundColor(.white.opacity(DesignTokens.Text.disabled))
                            }
                        }
                        OptionRow {
                            let sameAsSourceChip = SelectorChip(label: "Same as Source", isSelected: !job.transcodeAudio) {
                                withAnimation(.spring(response: 0.25)) {
                                    job.useSameAsSourceForAudio()
                                }
                            }
                            // Real codec chips hidden when the output format only has
                            // one possible audio codec (e.g. MP3/FLAC are self-contained
                            // — codec == container, so there's no real choice besides
                            // Same as Source vs. that one codec, and picking the format
                            // above already implies the latter). In that case "Same as
                            // Source" is the only control in the row and goes full width
                            // -- see the matching comment on the VIDEO CODEC row above.
                            if job.availableAudioCodecs.count > 1 {
                                sameAsSourceChip.frame(width: Self.sameAsSourceChipWidth)
                                ForEach(job.availableAudioCodecs) { codec in
                                    SelectorChip(
                                        label: codec.rawValue,
                                        isSelected: job.transcodeAudio && job.audioCodec == codec
                                    ) {
                                        withAnimation(.spring(response: 0.25)) {
                                            job.audioCodec = codec
                                            job.transcodeAudio = true
                                        }
                                    }
                                }
                            } else {
                                sameAsSourceChip.frame(maxWidth: .infinity)
                            }
                        }
                    }
                }

                // OUTPUT FORMAT — last section, after both codec choices are
                // settled.
                VStack(alignment: .leading, spacing: 8) {
                    Label("OUTPUT FORMAT", systemImage: "doc.badge.arrow.up")
                        .font(.appMono(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                    formatRow
                }
            }
        }
    }

    // MARK: Completed card (active / done / failed)

    /// Output layer: destination file path + output info (target format/codec/
    /// resolution/channels/length/size), distinct from subtitleView above
    /// which describes the ORIGINAL input file. Chip order mirrors the input
    /// row exactly (length+size, then video, then audio) so the two rows
    /// read as parallel columns. Shown above the progress bar / action
    /// buttons, mirroring Download's output layer. The status pill now lives
    /// in the actions row (see `statusView` below), not in this row.
    private var outputLayer: AnyView {
        let outPath = job.outputURL?.path ?? {
            let dir = config.convertOutputDir
            let name = job.inputURL.deletingPathExtension().lastPathComponent
            return (dir as NSString).appendingPathComponent("\(name).\(job.outputFormat.fileExtension)")
        }()

        var chips: [ChipData] = []

        // Gray: length + size combined — same field order as the input row.
        // Length is unchanged by conversion (Convert never trims/retimes),
        // so it carries over from the source media info. Size is only shown
        // once the job is done — while converting, the output file is still
        // being written, so its on-disk size is a partial/growing number,
        // not the final file size. It's read from disk once, at completion
        // (see runConversion), not on every render.
        // Unit-suffixed ("45s"/"12m"/"2h") to match Drop/History's chips --
        // falls back to the raw "H:MM:SS" string only if seconds is missing.
        let lengthValue = job.mediaInfo?.durationSeconds.flatMap { formatDurationChip(seconds: Int($0)) }
            ?? job.mediaInfo?.duration
        if let length = ChipData.lengthAndSize(length: lengthValue, size: job.status == .done ? job.outputSizeLabel : nil) {
            chips.append(length)
        }

        // Blue: format, codec, framerate, resolution. Framerate and resolution
        // are unchanged by conversion (Convert never retimes or resizes), so
        // they carry over from the source media info, matching the input row's
        // video chip.
        if job.mediaMode.isVideo,
           let video = ChipData.video([job.outputFormat.rawValue.uppercased(), job.displayVideoCodec, job.mediaInfo?.videoFrameRateLabel, job.mediaInfo?.resolution]) {
            chips.append(video)
        }

        // Green: codec, channels, bitrate. Channels are unchanged by
        // conversion (Convert never remixes), so they carry over from the
        // source media info, matching the input row's audio chip.
        if job.mediaMode != .videoOnly,
           let audio = ChipData.audio([job.displayAudioCodec, job.mediaInfo?.audioChannelLabel, job.displayAudioBitrateLabel]) {
            chips.append(audio)
        }

        return AnyView(
            InputOutputRow(
                inputPath: job.inputURL.path,
                // The source file's own characteristics don't change once
                // conversion starts, so the input side just reuses the same
                // job.inputChips the queued card already shows -- no reason
                // for the same file to render a different blue/green chip
                // depending on which card state you're looking at. (The
                // output side below intentionally stays local: it upgrades
                // from an estimate to the real on-disk size once .done,
                // which job.outputChips -- used by the queued card, which
                // can only ever estimate -- doesn't do.)
                inputChips: job.inputChips,
                outputPath: outPath,
                outputChips: chips
            )
        )
    }

    /// Status icon + pill — lives in the actions row, to the left of the
    /// Reveal/Reconvert/Retry buttons, not in the header subtitle. Nothing
    /// shown for `.queued` -- sitting in the Convert Queue already says that,
    /// so a redundant "Queued" pill on every row was just noise.
    private var statusView: AnyView {
        if job.status == .queued {
            return AnyView(EmptyView())
        }
        return AnyView(
            HStack(spacing: 6) {
                Group {
                    switch job.status {
                    case .done:
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    case .failed:
                        Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                    case .converting:
                        Image(systemName: "arrow.triangle.2.circlepath").foregroundColor(.white.opacity(DesignTokens.Text.secondary))
                    case .queued:
                        EmptyView()
                    case .cancelled:
                        Image(systemName: "slash.circle.fill").foregroundColor(.orange)
                    }
                }.font(.appMono(size: 14))

                StatusPill(label: statusLabel, color: statusColor)
            }
        )
    }

    /// Queue-row-only subtitle: just the output format/codec chips, no input
    /// side and no file paths -- condenses each row down to "what this will
    /// become," since the full input->output comparison (outputLayer) is
    /// still there in Analyze where settings are actually being decided.
    private var queueRowSubtitle: AnyView {
        AnyView(ChipRow(chips: job.outputChips))
    }

    /// Edit control -- pulls this job back to the Analyze panel for
    /// reconfiguring. Rendered by CompletedCard directly beneath the remove
    /// (x) button rather than down in the actions row, so it never sits in
    /// its own divided section. Only offered for statuses where editing
    /// makes sense: not yet started, or didn't finish.
    private var editAccessory: AnyView? {
        guard let onEditRequested, job.status == .queued || job.status == .failed || job.status == .cancelled else { return nil }
        return AnyView(
            HoverIconButton(icon: "slider.horizontal.3", size: 15, help: "Edit", expandable: true) {
                onEditRequested()
            }
        )
    }

    /// Only .converting/.done/.cancelled/.failed put anything in the actions
    /// row below (buttons, progress bar, error text) now that Edit lives up
    /// in the header next to Remove -- a freshly-queued job with none of
    /// those would otherwise show a divider over empty space.
    private var hasCompletedCardStatusContent: Bool { job.status != .queued }

    private var convertCompletedCard: some View {
        CompletedCard(
            isSelected: job.isSelected,
            onToggleSelect: {
                withAnimation(.spring(response: 0.2)) {
                    job.isSelected.toggle()
                }
                onSelectionChange()
            },
            onRemove: onRemove,
            showCheckbox: isQueueRow,
            leadingAccessory: leadingAccessory,
            trailingAccessory: editAccessory,
            thumbnail: thumbView,
            thumbnailPlaceholder: job.isVideoFile ? "video" : "waveform",
            title: job.inputURL.deletingPathExtension().lastPathComponent,
            subtitle: isQueueRow ? queueRowSubtitle : outputLayer,
            hasStatusContent: hasCompletedCardStatusContent,
            compact: isQueueRow
        ) {
            // Actions row — buttons stretch to fill the full card width (each
            // GlassButton defaults to maxWidth: .infinity), so this HStack
            // itself must also claim the full width. A leading Spacer() here
            // previously ate the extra space and left a gap on the left with
            // the buttons hugging the right edge instead of spanning the card.
            // Per-row action buttons (Reveal in Finder, Reconvert, Retry,
            // per-row Cancel) are gone -- Cancel is now global (the bottom
            // bar's primary button becomes "Cancel All" while anything is
            // converting), Reveal in Finder is now a single always-on
            // control pointed at the SAVE TO directory (see
            // batchDirectoryField), and Reconvert/Retry both have the same
            // effect Edit already provides (pull back to Analyze, then Add
            // to Queue again) so a dedicated one-click button was
            // redundant. Every non-queued row still gets `statusView`'s
            // icon+pill (Converting/Done/Failed/Cancelled) so nothing goes
            // fully silent -- that's just an indicator, not a control.
            HStack(spacing: 10) {
                    statusView
                    Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)

            // Progress bar (converting) — same visual + behavior as Download's
            // yt-dlp bar: filled/animated when a fraction is known, indeterminate
            // shimmer otherwise, translating ffmpeg's time= output into 0-1.
            if job.status == .converting {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(DesignTokens.Interactive.fillRest)).frame(height: 4)
                        if let pct = job.progressFraction, pct > 0 {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(LinearGradient(colors: [Color.green.opacity(0.6), Color.green.opacity(1.0)],
                                                     startPoint: .leading, endPoint: .trailing))
                                .frame(width: geo.size.width * CGFloat(pct), height: 4)
                                .shadow(color: Color.green.opacity(0.8), radius: 4)
                                .shadow(color: Color.green.opacity(0.4), radius: 8)
                                .animation(.easeOut(duration: 0.25), value: pct)
                        } else {
                            ShimmerBar(width: geo.size.width, color: .green, glow: true, duration: 1.2)
                        }
                    }
                }
                .frame(height: 4)
                if !job.progress.isEmpty || !job.etaText.isEmpty {
                    HStack(spacing: 6) {
                        if !job.etaText.isEmpty {
                            Text(job.etaText)
                                .font(.appMono(size: 10, design: .monospaced))
                                .foregroundColor(.white.opacity(DesignTokens.Text.disabled))
                                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                                .transition(.blurIn)
                        }
                        if !job.progress.isEmpty {
                            Text(job.progress)
                                .font(.appMono(size: 10, design: .monospaced))
                                .foregroundColor(.white.opacity(DesignTokens.Text.disabled))
                                .lineLimit(1).truncationMode(.tail)
                                .transition(.blurIn)
                        }
                        Spacer(minLength: 4)
                    }
                }
            }

            // Error details (failed) — shows the actual error message. The
            // Cancelled state has no equivalent block: the StatusPill in the
            // output row above already reads "Cancelled", so a second plain-
            // text "Cancelled" here would just duplicate it.
            if job.status == .failed {
                Text(job.progress)
                    .font(.appMono(size: 11))
                    .foregroundColor(.red.opacity(0.75))
                    .lineLimit(2)
            }
        }
    }

    // MARK: Helpers

    private var statusLabel: String {
        switch job.status {
        case .queued:     return "Queued"
        case .converting: return "Converting"
        case .done:       return "Done"
        case .failed:     return "Failed"
        case .cancelled:  return "Cancelled"
        }
    }

    private var statusColor: Color {
        switch job.status {
        case .queued:     return .secondary
        case .converting: return .white
        case .done:       return .green
        case .failed:     return .red
        case .cancelled:  return .orange
        }
    }

}
