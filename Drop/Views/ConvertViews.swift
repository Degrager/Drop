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
    /// drives the "Original" badge on the codec chip.
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
    /// drives the "Original" badge on the codec chip.
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

/// One-tap combinations of output format + codecs for common conversion goals.
/// The available presets depend on the current CONVERT AS (media mode) selection,
/// so switching between Video+Audio / Video Only / Audio Only shows a different
/// preset row — each preset only offers combinations that are actually valid for
/// that mode's compatible codecs.
enum ConvertPreset: String, CaseIterable, Identifiable {
    case resolveImportFix = "Resolve Import Fix"
    case smallerFileSize = "Smaller File Size"
    case maxCompatibility = "Max Compatibility"
    case losslessAudio = "Lossless Audio"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .resolveImportFix:  return "speaker.wave.3.fill"
        case .smallerFileSize:   return "arrow.down.circle"
        case .maxCompatibility:  return "checkmark.seal"
        case .losslessAudio:     return "waveform.badge.plus"
        }
    }
    var shortLabel: String {
        switch self {
        case .resolveImportFix:  return "Resolve Import Fix"
        case .smallerFileSize:   return "Smaller File"
        case .maxCompatibility:  return "Max Compatibility"
        case .losslessAudio:     return "Lossless Audio"
        }
    }
    var note: String {
        switch self {
        case .resolveImportFix:  return "WAV audio, AAC video, keeps channels"
        case .smallerFileSize:   return "Best compression"
        case .maxCompatibility:  return "Plays everywhere"
        case .losslessAudio:     return "Uncompressed/lossless"
        }
    }

    /// Which presets make sense for a given media mode. Video+Audio and Video Only
    /// both care about the video-safe options; Audio Only drops anything that talks
    /// about "video re-encode" since there's no video track to protect.
    static func options(for mode: ConvertMediaMode) -> [ConvertPreset] {
        switch mode {
        case .videoAndAudio, .videoOnly:
            return [.resolveImportFix, .smallerFileSize, .maxCompatibility, .losslessAudio]
        case .audio:
            return [.smallerFileSize, .maxCompatibility, .losslessAudio]
        }
    }

    /// Resolves this preset into a concrete (format, videoCodec, audioCodec) choice
    /// for the given job, picking the source-matching codec for "no re-encode" cases
    /// and falling back gracefully when a container doesn't support the ideal codec.
    func resolve(for job: ConvertJob) -> (format: ConvertOutputFormat, video: ConvertVideoCodec?, audio: ConvertAudioCodec) {
        let isAudioOnly = job.mediaMode == .audio
        switch self {
        case .resolveImportFix:
            // One-tap fix for the classic "movie/TV rip MKV won't import into Resolve, or
            // imports with no audio" problem — whatever the source audio codec is (E-AC-3,
            // AC3, DTS, TrueHD, etc.), always re-encode it to AAC, which Resolve reliably
            // decodes. AAC with no -ac flag keeps whatever channel count ffmpeg reads from
            // the source (5.1 stays 5.1, stereo stays stereo) — see the 384k multichannel
            // bump in runConversion(job:). The video stream is always left on its
            // source-matching codec so it stream-copies and never re-encodes.
            //
            // MOV over MKV is a deliberate compatibility choice, not a technical requirement —
            // AAC is equally valid inside MKV (Matroska holds any codec) and ffmpeg has no
            // preference either way. MOV is picked because Resolve's decode/playback engine
            // is built around the QuickTime family (MOV/MP4): even after a successful MKV
            // import, Resolve has shown more scrubbing hitches, dropped frames, and audio-sync
            // drift on MKV timelines than on the same content muxed into MOV. Since the whole
            // point of this preset is guaranteed Resolve reliability (not just codec validity),
            // MOV is the safer target — but ONLY when the source is already an MKV. Resolve
            // already imports MP4 reliably, so an MP4 source is left as MP4 (container AND
            // video codec both untouched) and only its audio is re-encoded to AAC.
            let sourceExt = job.inputURL.pathExtension.lowercased()
            let format: ConvertOutputFormat
            if isAudioOnly {
                // Uncompressed WAV/PCM avoids Resolve's AAC/M4A decode-quality issue entirely
                // (no lossy decode pass), unlike re-encoding to AAC/M4A.
                format = .wav
            } else if ConvertOutputFormat.mp4.matchesSource(sourceExt) {
                format = .mp4
            } else {
                format = .mov
            }
            let videoSourceMatch = job.mediaInfo?.videoCodec.flatMap { raw in format.compatibleVideoCodecs.first { $0.probeNames.contains(raw) } }
            let video: ConvertVideoCodec? = isAudioOnly ? nil : (videoSourceMatch ?? job.videoCodec)
            let audio: ConvertAudioCodec = isAudioOnly ? .pcm : .aac
            return (format, video, audio)
        case .smallerFileSize:
            let format: ConvertOutputFormat = isAudioOnly ? .m4a : .mkv
            let video: ConvertVideoCodec? = isAudioOnly ? nil : .h265
            let audio: ConvertAudioCodec = format.compatibleAudioCodecs.contains(.opus) ? .opus : .aac
            return (format, video, audio)
        case .maxCompatibility:
            let format: ConvertOutputFormat = isAudioOnly ? .m4a : .mp4
            let video: ConvertVideoCodec? = isAudioOnly ? nil : .h264
            return (format, video, .aac)
        case .losslessAudio:
            let format: ConvertOutputFormat = isAudioOnly ? .flac : .mkv
            let videoSourceMatch = job.mediaInfo?.videoCodec.flatMap { raw in format.compatibleVideoCodecs.first { $0.probeNames.contains(raw) } }
            let video: ConvertVideoCodec? = isAudioOnly ? nil : (videoSourceMatch ?? job.videoCodec)
            let audio: ConvertAudioCodec = format.compatibleAudioCodecs.contains(.flac) ? .flac : (format.compatibleAudioCodecs.first ?? .flac)
            return (format, video, audio)
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
    /// drives the "Original" badge on the OUTPUT FORMAT chip.
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
    var directory: String?     // parent folder name
    var durationSeconds: Double? = nil  // raw seconds, for output size estimation
    var pixelWidth: Int? = nil
    var pixelHeight: Int? = nil
    var fileSizeBytes: Int? = nil  // raw source size, for stream-copy size estimation
}

enum ConvertJobStatus { case queued, converting, done, failed, cancelled }

/// A job's Batch Apply choices. Every field is optional and independent —
/// only the fields the user actually touched in Select Mode are set, and only
/// those fields override the job's own base settings. Nothing here is ever
/// written back onto the base fields, so leaving Select Mode or unchecking the
/// job leaves its individual-card settings exactly as they were.
struct BatchOverride: Equatable {
    var mode: ConvertMediaMode? = nil
    var format: ConvertOutputFormat? = nil
    var videoCodec: ConvertVideoCodec? = nil
    var audioCodec: ConvertAudioCodec? = nil
    var preset: ConvertPreset? = nil
}

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
    let addedAt: Date = Date()
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
    @Published var isSelected: Bool = true
    /// Whether this card's settings section is expanded. Transient UI state
    /// only (like isSelected) — always starts expanded, never persisted. Lives
    /// on the job itself (rather than local @State in the card view) so the
    /// "collapse all" toggle in the header can drive every card in lockstep.
    @Published var isExpanded: Bool = true
    @Published var thumbnail: NSImage? = nil
    @Published var audioCodec: ConvertAudioCodec = .aac
    @Published var videoCodec: ConvertVideoCodec = .h264
    @Published var outputFormat: ConvertOutputFormat = .mp4
    @Published var mediaMode: ConvertMediaMode = .videoAndAudio
    /// The preset last applied via applyPreset(_:), if any. Cleared the moment
    /// the user manually changes format/video/audio/mode so the preset chip
    /// only stays highlighted while its exact combination is still in effect.
    @Published var activePreset: ConvertPreset? = nil
    @Published var mediaInfo: ConvertMediaInfo? = nil {
        didSet { applyDefaultCodecsFromSource() }
    }
    /// Batch Apply's choices for this job, kept completely separate from the
    /// individual-card settings above. Selecting this job in Select Mode and
    /// choosing a mode/preset/format/codec there only ever writes here — it
    /// never touches mediaMode/outputFormat/videoCodec/audioCodec/activePreset,
    /// so the individual card keeps showing exactly what it showed before the
    /// job was ever checked. When present, these override the base fields only
    /// for conversion and for the batch panel's own chip highlighting.
    @Published var batchOverride: BatchOverride? = nil
    var outputDir: URL? = nil
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

    /// Applies a preset's resolved format/codec combination in one action, then
    /// re-validates so nothing ends up in an impossible state for the container.
    func applyPreset(_ preset: ConvertPreset) {
        let resolved = preset.resolve(for: self)
        outputFormat = resolved.format
        if let video = resolved.video {
            videoCodec = video
        }
        audioCodec = resolved.audio
        ensureCodecsValidForFormat()
        activePreset = preset
    }

    // MARK: - Batch override / effective settings
    //
    // "Effective" values are what actually gets used for conversion and for
    // the batch panel's own display: the override component if Select Mode set
    // one, otherwise this job's own base setting. The individual card never
    // reads these — it binds directly to the base fields below, so Batch Apply
    // choices can never leak backwards into a card's own settings.

    var effectiveMediaMode: ConvertMediaMode { batchOverride?.mode ?? mediaMode }
    var effectiveOutputFormat: ConvertOutputFormat { batchOverride?.format ?? outputFormat }
    var effectiveVideoCodec: ConvertVideoCodec { batchOverride?.videoCodec ?? videoCodec }
    var effectiveAudioCodec: ConvertAudioCodec { batchOverride?.audioCodec ?? audioCodec }
    var effectiveActivePreset: ConvertPreset? { batchOverride?.preset ?? activePreset }

    var effectiveAvailableFormats: [ConvertOutputFormat] {
        switch effectiveMediaMode {
        case .audio:                    return [.wav, .mp3, .m4a, .flac]
        case .videoAndAudio, .videoOnly: return [.mp4, .mov, .mkv]
        }
    }
    var effectiveAvailableAudioCodecs: [ConvertAudioCodec] { effectiveOutputFormat.compatibleAudioCodecs }
    var effectiveAvailableVideoCodecs: [ConvertVideoCodec] { effectiveOutputFormat.compatibleVideoCodecs }

    var effectiveVideoCodecMatchesSource: Bool {
        guard let raw = mediaInfo?.videoCodec else { return false }
        return effectiveVideoCodec.probeNames.contains(raw)
    }
    var effectiveAudioCodecMatchesSource: Bool {
        guard let raw = mediaInfo?.audioCodec else { return false }
        return effectiveAudioCodec.probeNames.contains(raw)
    }
    var effectiveOutputFilename: String {
        let base = inputURL.deletingPathExtension().lastPathComponent
        return "\(base)_converted.\(effectiveOutputFormat.fileExtension)"
    }

    /// If this job has no Batch Apply choices yet, seeds them with Resolve
    /// Import Fix — the same one-tap-safe default a fresh job's own settings
    /// already amount to — resolved entirely into the override, never touching
    /// the base fields. Call this the moment a job is checked in Select Mode.
    func seedBatchOverrideIfNeeded() {
        guard batchOverride == nil else { return }
        var override = BatchOverride()
        let preset = ConvertPreset.resolveImportFix
        let resolved = preset.resolve(for: self)
        override.mode = mediaMode
        override.format = resolved.format
        if let video = resolved.video {
            override.videoCodec = video
        } else {
            override.videoCodec = videoCodec
        }
        override.audioCodec = resolved.audio
        override.preset = preset
        batchOverride = override
    }

    /// Clears this job's Batch Apply choices, restoring it to showing only its
    /// own base settings for conversion. Call when unchecking a job.
    func clearBatchOverride() {
        batchOverride = nil
    }

    /// Applies a preset into this job's Batch Apply override only — mirrors
    /// `applyPreset(_:)` exactly but never touches the base fields.
    func applyPresetToOverride(_ preset: ConvertPreset) {
        var override = batchOverride ?? BatchOverride()
        let resolved = preset.resolve(for: self)
        override.format = resolved.format
        if let video = resolved.video {
            override.videoCodec = video
        }
        override.audioCodec = resolved.audio
        override.mode = override.mode ?? mediaMode
        override.preset = preset
        batchOverride = override
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

            // Directory
            info.directory = url.deletingLastPathComponent().lastPathComponent

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
                        }
                        if ct == "audio" && info.audioCodec == nil {
                            info.audioCodec = cn.uppercased()
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
                    if let fmt = json["format"] as? [String: Any],
                       let durStr = fmt["duration"] as? String,
                       let dur = Double(durStr) {
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
        guard let info = mediaInfo, let duration = info.durationSeconds, duration > 0 else { return nil }
        // Uses effective* settings so Select mode's Batch Apply overrides (if
        // any) are reflected in the estimate for this run, without touching
        // the job's own base codec/mode fields.
        let videoIsCopy = effectiveMediaMode != .audio && effectiveVideoCodec.matchesSource(info.videoCodec)
        let audioIsCopy = effectiveMediaMode != .videoOnly && effectiveAudioCodec.matchesSource(info.audioCodec)
        // If every relevant track is being stream-copied (the all-default "Original"
        // case), the output is essentially the source file — same container muxing
        // overhead aside — so just report the real source size instead of running it
        // through the bitrate model at all.
        let allTracksCopied = (effectiveMediaMode == .audio || videoIsCopy) && (effectiveMediaMode == .videoOnly || audioIsCopy)
        if allTracksCopied, let sourceBytes = info.fileSizeBytes, sourceBytes > 0 {
            return sourceBytes
        }
        // Otherwise split the known source size between video/audio using the same
        // rule-of-thumb bitrate ratio, so a copied track's share reflects the source's
        // real weight rather than assuming it's the whole file.
        let sourceVideoKbps = effectiveMediaMode != .audio ? ConvertVideoCodec.h264.typicalMbpsAt1080p * 1000 * sourceResolutionRatio(info) : 0
        let sourceAudioKbps = effectiveMediaMode != .videoOnly ? Double(ConvertAudioCodec.aac.typicalBitrateKbps) : 0
        let sourceTotalKbps = max(sourceVideoKbps + sourceAudioKbps, 1)
        let sourceBytes = info.fileSizeBytes ?? 0

        var totalKbps: Double = 0
        var copiedBytes: Double = 0

        if effectiveMediaMode != .audio {
            if videoIsCopy, sourceBytes > 0 {
                copiedBytes += Double(sourceBytes) * (sourceVideoKbps / sourceTotalKbps)
            } else {
                totalKbps += effectiveVideoCodec.typicalMbpsAt1080p * 1000 * sourceResolutionRatio(info)
            }
        }
        if effectiveMediaMode != .videoOnly {
            if audioIsCopy, sourceBytes > 0 {
                copiedBytes += Double(sourceBytes) * (sourceAudioKbps / sourceTotalKbps)
            } else {
                totalKbps += Double(effectiveAudioCodec.typicalBitrateKbps)
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
        if let dur, let size = mediaInfo?.fileSize {
            result.append(ChipData(label: "", value: dur, color: .white, icon: "clock",
                                    icon2: "internaldrive", value2: size))
        } else if let dur {
            result.append(ChipData(label: "", value: dur, color: .white, icon: "clock"))
        } else if let size = mediaInfo?.fileSize {
            result.append(ChipData(label: "", value: size, color: .white, icon: "internaldrive"))
        }
        if effectiveMediaMode != .audio {
            let videoParts = [mediaInfo?.videoCodec, mediaInfo?.resolution].compactMap { $0 }
            if !videoParts.isEmpty {
                result.append(ChipData(label: "", value: videoParts.joined(separator: " · "), color: .blue, icon: isVideoFile ? "video" : "waveform"))
            }
        }
        if effectiveMediaMode != .videoOnly {
            let audioParts = [mediaInfo?.audioCodec, mediaInfo?.audioChannelLabel].compactMap { $0 }
            if !audioParts.isEmpty {
                result.append(ChipData(label: "", value: audioParts.joined(separator: " · "), color: .green, icon: "waveform"))
            }
        }
        return result
    }

    var outputChips: [ChipData] {
        var result: [ChipData] = []
        let dur = mediaInfo?.durationSeconds.flatMap { formatDurationChip(seconds: Int($0)) } ?? mediaInfo?.duration
        if let dur, let sizeLabel = estimatedOutputSizeLabel {
            result.append(ChipData(label: "", value: dur, color: .white, icon: "clock",
                                    icon2: "internaldrive", value2: sizeLabel))
        } else if let dur {
            result.append(ChipData(label: "", value: dur, color: .white, icon: "clock"))
        } else if let sizeLabel = estimatedOutputSizeLabel {
            result.append(ChipData(label: "", value: sizeLabel, color: .white, icon: "internaldrive"))
        }
        if effectiveMediaMode != .audio {
            result.append(ChipData(label: "", value: "\(effectiveOutputFormat.rawValue.uppercased()) · \(effectiveVideoCodec.rawValue)", color: .blue, icon: "video"))
        }
        if effectiveMediaMode != .videoOnly {
            // Convert never changes the channel layout -- the encoder always
            // stream-copies or re-tags the SOURCE channel count (5.1 stays
            // 5.1, stereo stays stereo; see runConversion's -channel_layout
            // handling), so the output chip should echo the same
            // audioChannelLabel the input chip shows instead of omitting
            // it, which previously made the output side look like it might
            // downmix when it never does.
            let codecPart = effectiveMediaMode == .audio ? effectiveOutputFormat.rawValue.uppercased() : effectiveAudioCodec.rawValue
            let audioOutParts = [codecPart, mediaInfo?.audioChannelLabel].compactMap { $0 }
            result.append(ChipData(label: "", value: audioOutParts.joined(separator: " · "), color: .green, icon: "waveform"))
        }
        return result
    }

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
            if let image = rep?.nsImage {
                DispatchQueue.main.async { self?.thumbnail = image }
            }
        }
    }

    var isVideoFile: Bool {
        ["mp4","mov","mkv","avi","m4v","ts","mts","m2ts","webm","flv"]
            .contains(inputURL.pathExtension.lowercased())
    }

}

struct ConvertView: View {
    let ffmpegPath: String?
    var toolsReady: Bool = true
    @ObservedObject var history: HistoryStore
    @Binding var jobs: [ConvertJob]
    @ObservedObject var config: Config
    /// Shared app-wide log (same store/panel Download writes to) so ffmpeg
    /// commands, stderr output, and results are visible/exportable from the
    /// existing terminal-icon log panel and included in "Export Log".
    @ObservedObject var manager: DownloadManager

    @State private var isDragging = false
    @State private var isDropZoneHovering = false
    /// Measured once via GeometryReader on the outer VStack (see body's
    /// .background below) and shared by the list header row, card queue,
    /// and bottom bar so all three are pinned to the exact same pixel
    /// width -- matching Download's mainPanelWidth pattern. Using this one
    /// shared number instead of each row calling containerRelativeFrame
    /// independently is required because the card queue lives inside a
    /// ScrollView, which establishes its own separate container geometry;
    /// containerRelativeFrame resolves against the NEAREST container, so
    /// the list header row (outside the ScrollView) and the card queue
    /// (inside it) were computing 60% against two different base widths
    /// and visibly disagreeing with each other and with the full-width
    /// drop zone above them.
    @State private var mainPanelWidth: CGFloat = 0

    /// Select mode: reveals per-card checkboxes, collapses per-card settings,
    /// and swaps the bottom bar's settings row for one that applies to every
    /// checked card at once. Off by default — normal single-card editing.
    @State private var isBatchMode = false

    /// Bumped on every checkbox toggle to force SwiftUI to recompute
    /// `batchCheckedJobs`/`selectedJobs` and re-render dependent views.
    /// `jobs` is a `@Binding` array of reference-type `ConvertJob`s, so a
    /// `@Published` change on one job's `isSelected` does not by itself
    /// invalidate this view's body — this counter closes that gap.
    @State private var selectionVersion = 0

    private var hasJobs: Bool { !jobs.isEmpty }
    /// Outside Batch Apply mode every queued job counts as "selected" for the
    /// Convert action (checkboxes are hidden, so nothing is excluded). Inside
    /// Batch Apply mode, selection reflects only what's actually checked.
    private var selectedJobs: [ConvertJob] { _ = selectionVersion; return isBatchMode ? jobs.filter { $0.isSelected } : jobs }
    private var hasSelected: Bool { !selectedJobs.isEmpty }
    private var hasSelectedQueued: Bool { selectedJobs.contains { $0.status == .queued } }
    /// Any queued job at all, regardless of checkbox state — used to decide
    /// whether the Convert button shows up in the bar in the first place.
    /// Reads `selectionVersion` purely to force recomputation: `jobs` is a
    /// `[ConvertJob]` of reference types behind a `@Binding`, so mutating a
    /// job's own `@Published status` (e.g. Retry/Reconvert) doesn't trigger
    /// this parent view to re-render on its own — without this, the Convert
    /// button stayed hidden after Retry even though the job was re-queued.
    private var hasQueuedJobs: Bool { _ = selectionVersion; return jobs.contains { $0.status == .queued } }
    private var batchCheckedJobs: [ConvertJob] { _ = selectionVersion; return jobs.filter { $0.isSelected } }
    /// Only the checked jobs that are still queued (batch actions are no-ops
    /// on jobs that are converting/done/failed, so those shouldn't influence
    /// which chips render as available).
    private var batchEligibleJobs: [ConvertJob] { batchCheckedJobs.filter { $0.status == .queued } }

    // Sum of estimated output sizes across all selected, still-queued jobs —
    // shown as a chip next to SAVE TO while Select mode is active, mirroring
    // Download's estimated-size chip. Only meaningful in Select mode since
    // that's when a specific subset of jobs is being converted together.
    private var totalEstimatedSizeLabel: String? {
        guard isBatchMode else { return nil }
        let bytes = selectedJobs
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

    /// True once every checkable card is checked — flips the header button to
    /// "Deselect All". Only counts queued jobs since those are the only ones
    /// that show a checkbox / participate in Select Mode.
    private var allEligibleJobsSelected: Bool {
        _ = selectionVersion
        let eligible = jobs.filter { $0.status == .queued }
        guard !eligible.isEmpty else { return false }
        return eligible.allSatisfy { $0.isSelected }
    }

    /// Select All when nothing (or not everything) is checked; Deselect All
    /// once every eligible card is already checked. Seeds/clears each job's
    /// Batch Apply override to match, exactly like tapping its own checkbox.
    private func toggleSelectAll() {
        let eligible = jobs.filter { $0.status == .queued }
        let shouldSelect = !allEligibleJobsSelected
        for job in eligible {
            job.isSelected = shouldSelect
            if shouldSelect {
                job.seedBatchOverrideIfNeeded()
            } else {
                job.clearBatchOverride()
            }
        }
        selectionVersion += 1
    }

    /// True once every card currently in the list is collapsed — flips the
    /// header button to "Expand All". Empty list counts as not-collapsed.
    /// Reads `selectionVersion` purely to force recomputation — `jobs` is a
    /// plain array of reference-type ConvertJob, so ConvertView's body isn't
    /// otherwise notified when a job's own @Published isExpanded changes.
    private var allCardsCollapsed: Bool {
        _ = selectionVersion
        let queued = jobs.filter { $0.status == .queued }
        return !queued.isEmpty && queued.allSatisfy { !$0.isExpanded }
    }

    /// True when at least one card can actually be collapsed/expanded. Only
    /// queued cards have a collapse toggle at all — converting/done/failed
    /// cards don't, and Select mode force-collapses + locks every card's
    /// toggle, so nothing is expandable while it's active either.
    private var hasExpandableCards: Bool {
        !isBatchMode && jobs.contains { $0.status == .queued }
    }

    /// Collapses every card if any are still expanded; expands every card
    /// once they're all already collapsed.
    private func toggleCollapseAll() {
        let shouldCollapse = !allCardsCollapsed
        jobs.forEach { $0.isExpanded = !shouldCollapse }
        selectionVersion += 1
    }

    /// CONVERT AS modes relevant to the checked selection — mirrors the
    /// per-card filter (video-only modes hidden for audio-only files), but
    /// unioned across every checked job so a mixed selection still shows
    /// every mode that applies to at least one of them.
    private var batchAvailableModes: [ConvertMediaMode] {
        let jobs = batchEligibleJobs
        guard !jobs.isEmpty else { return ConvertMediaMode.allCases }
        let allowVideoModes = jobs.contains { $0.isVideoFile }
        return ConvertMediaMode.allCases.filter { allowVideoModes || $0 == .audio }
    }

    /// PRESETS relevant to the checked selection — union of `ConvertPreset
    /// .options(for:)` across each checked job's current mode.
    private var batchAvailablePresets: [ConvertPreset] {
        let jobs = batchEligibleJobs
        guard !jobs.isEmpty else { return ConvertPreset.allCases }
        var seen: Set<ConvertPreset> = []
        var ordered: [ConvertPreset] = []
        for job in jobs {
            for preset in ConvertPreset.options(for: job.effectiveMediaMode) where !seen.contains(preset) {
                seen.insert(preset)
                ordered.append(preset)
            }
        }
        return ordered
    }

    /// OUTPUT FORMAT choices relevant to the checked selection — union of
    /// `job.effectiveAvailableFormats` (which depends on each job's effective mode).
    private var batchAvailableFormats: [ConvertOutputFormat] {
        let jobs = batchEligibleJobs
        guard !jobs.isEmpty else { return ConvertOutputFormat.allCases }
        var seen: Set<ConvertOutputFormat> = []
        var ordered: [ConvertOutputFormat] = []
        for job in jobs {
            for fmt in job.effectiveAvailableFormats where !seen.contains(fmt) {
                seen.insert(fmt)
                ordered.append(fmt)
            }
        }
        return ordered
    }

    /// Whether any checked job is currently in a video mode (effective) — gates
    /// whether the VIDEO CODEC row renders at all, matching the per-card behavior.
    private var batchHasVideoModeJob: Bool { batchEligibleJobs.contains { $0.effectiveMediaMode.isVideo } }

    /// Whether any checked job would actually show an AUDIO CODEC row —
    /// matches the per-card gate (`effectiveMediaMode != .videoOnly` and more
    /// than one codec choice).
    private var batchHasAudioCodecChoice: Bool {
        batchEligibleJobs.contains { $0.effectiveMediaMode != .videoOnly && $0.effectiveAvailableAudioCodecs.count > 1 }
    }

    /// VIDEO CODEC choices relevant to the checked selection.
    private var batchAvailableVideoCodecs: [ConvertVideoCodec] {
        let jobs = batchEligibleJobs.filter { $0.effectiveMediaMode.isVideo }
        guard !jobs.isEmpty else { return [] }
        var seen: Set<ConvertVideoCodec> = []
        var ordered: [ConvertVideoCodec] = []
        for job in jobs {
            for codec in job.effectiveAvailableVideoCodecs where !seen.contains(codec) {
                seen.insert(codec)
                ordered.append(codec)
            }
        }
        return ordered
    }

    /// AUDIO CODEC choices relevant to the checked selection.
    private var batchAvailableAudioCodecs: [ConvertAudioCodec] {
        let jobs = batchEligibleJobs.filter { $0.effectiveMediaMode != .videoOnly }
        guard !jobs.isEmpty else { return [] }
        var seen: Set<ConvertAudioCodec> = []
        var ordered: [ConvertAudioCodec] = []
        for job in jobs {
            for codec in job.effectiveAvailableAudioCodecs where !seen.contains(codec) {
                seen.insert(codec)
                ordered.append(codec)
            }
        }
        return ordered
    }

    // MARK: Batch chip highlight state
    //
    // Mirrors the per-card chips exactly: a chip lights up when it reflects
    // the checked jobs' ACTUAL current value, not a "last tapped" flag. Since
    // every job defaults to Video + Audio / MP4 / H.264 / AAC with no active
    // preset, that's what shows highlighted on a fresh selection, same as it
    // would look on an individual card.

    /// True only if every checked eligible job currently has this mode set
    /// (a uniform match), so mixed selections don't falsely highlight a chip
    /// that only applies to some of the checked jobs.
    private func batchModeSelected(_ mode: ConvertMediaMode) -> Bool {
        let jobs = batchEligibleJobs
        guard !jobs.isEmpty else { return false }
        return jobs.allSatisfy { $0.effectiveMediaMode == mode }
    }

    private func batchPresetSelected(_ preset: ConvertPreset) -> Bool {
        let jobs = batchEligibleJobs
        guard !jobs.isEmpty else { return false }
        return jobs.allSatisfy { $0.effectiveActivePreset == preset }
    }

    private func batchFormatSelected(_ format: ConvertOutputFormat) -> Bool {
        let jobs = batchEligibleJobs
        guard !jobs.isEmpty else { return false }
        return jobs.allSatisfy { $0.effectiveOutputFormat == format }
    }

    private func batchVideoCodecSelected(_ codec: ConvertVideoCodec) -> Bool {
        let jobs = batchEligibleJobs.filter { $0.effectiveMediaMode.isVideo }
        guard !jobs.isEmpty else { return false }
        return jobs.allSatisfy { $0.effectiveVideoCodec == codec }
    }

    private func batchAudioCodecSelected(_ codec: ConvertAudioCodec) -> Bool {
        let jobs = batchEligibleJobs.filter { $0.effectiveMediaMode != .videoOnly }
        guard !jobs.isEmpty else { return false }
        return jobs.allSatisfy { $0.effectiveAudioCodec == codec }
    }

    private var convertButtonLabel: String {
        let count = selectedJobs.filter { $0.status == .queued }.count
        if count > 1 { return "Convert \(count) Items" }
        if count == 1, let job = selectedJobs.first(where: { $0.status == .queued }) {
            return job.isVideoFile ? "Convert Video" : "Convert Audio"
        }
        return "Convert"
    }
    private var isConverting: Bool { jobs.contains { $0.status == .converting } }

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
        let inputMaxWidth: CGFloat = 864

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
                label: "Browse...",
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
        .frame(maxWidth: inputMaxWidth)
        .frame(maxWidth: .infinity)
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
                .padding(.horizontal, 16)
                .padding(.top, 40)
                .padding(.bottom, 20)

            // ── List header — top-left: Select mode + Select/Deselect All.
            // Top-right: Collapse/Expand All + Clear All. All four buttons
            // share one consistent compact GlassButton style.
            // Floats as its own bubble card, separate from the input area.
            if hasJobs {
                HStack {
                    GlassButton(
                        label: isBatchMode ? "Done" : "Select",
                        icon: isBatchMode ? "xmark.circle" : "checkmark.circle",
                        tint: DesignTokens.Accent.primary,
                        fitContent: true
                    ) {
                        withAnimation(.spring(response: 0.25)) {
                            isBatchMode.toggle()
                            // Always start/end with nothing checked, whether
                            // entering or exiting Select mode, so checkmarks
                            // never carry over stale state from a previous
                            // session. Also clear every job's Batch Apply
                            // override so leaving Select Mode fully resets it.
                            jobs.forEach { $0.isSelected = false; $0.clearBatchOverride() }
                            selectionVersion += 1
                        }
                    }
                    if isBatchMode {
                        GlassButton(
                            label: allEligibleJobsSelected ? "Deselect All" : "Select All",
                            icon: allEligibleJobsSelected ? "circle" : "checkmark.circle",
                            tint: .white,
                            fitContent: true
                        ) {
                            withAnimation(.spring(response: 0.25)) {
                                toggleSelectAll()
                            }
                        }
                    }
                    Spacer()
                    GlassButton(
                        label: allCardsCollapsed ? "Expand All" : "Collapse All",
                        icon: allCardsCollapsed ? "chevron.down" : "chevron.up",
                        tint: .white,
                        fitContent: true,
                        disabled: !hasExpandableCards
                    ) {
                        withAnimation(.spring(response: 0.25)) {
                            toggleCollapseAll()
                        }
                    }
                    GlassButton(
                        label: isBatchMode ? "Clear Selected" : "Clear All",
                        icon: "trash",
                        tint: .red,
                        fitContent: true,
                        disabled: isBatchMode && batchCheckedJobs.isEmpty
                    ) {
                        withAnimation(.spring(response: 0.3)) {
                            if isBatchMode {
                                jobs.removeAll { $0.isSelected }
                            } else {
                                jobs.removeAll()
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .glassCard(cornerRadius: DesignTokens.Radius.xlarge)
                .shadow(color: .black.opacity(DesignTokens.Interactive.glowShadowPeak), radius: 10, y: 4)
                // Pinned to mainPanelWidth (measured once via GeometryReader
                // on the outer VStack below) instead of
                // containerRelativeFrame -- see mainPanelWidth's declaration
                // for why that resolved to a different width than the card
                // queue below it.
                .frame(width: mainPanelWidth > 0 ? mainPanelWidth * 0.60 : nil)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
            }

            // ── Scrollable card area ──────────────────────────────────────
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: true) {
                    // LazyVStack (not VStack) so off-screen cards don't
                    // eagerly render their full view tree while scrolling --
                    // same fix applied to Download's card queue, which
                    // fixed a scroll stutter caused by every card's blur +
                    // (for analyzing cards) TimelineView-driven rim redraw
                    // running regardless of scroll position.
                    LazyVStack(spacing: 10) {
                        ForEach(jobs) { job in
                            ConvertPreviewCard(
                                job: job,
                                onRemove: {
                                    withAnimation(.spring(response: 0.3)) {
                                        jobs.removeAll { $0.id == job.id }
                                    }
                                },
                                isBatchMode: isBatchMode,
                                onSelectionChange: {
                                    selectionVersion += 1
                                }
                            )
                        }
                        Color.clear.frame(height: 4).id("convertBottom")
                    }
                    // Pinned to mainPanelWidth instead of
                    // containerRelativeFrame -- this VStack lives inside a
                    // ScrollView, which is its own containerRelativeFrame
                    // reference frame, separate from the plain VStack the
                    // header row and bottom bar sit in directly. Using the
                    // one shared GeometryReader measurement from mainPanel
                    // fixes this at the root instead of chasing padding deltas.
                    .frame(width: mainPanelWidth > 0 ? mainPanelWidth * 0.60 : nil)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 8)
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
                .onChange(of: jobs.count) {
                    withAnimation(.spring(response: 0.4)) {
                        proxy.scrollTo("convertBottom", anchor: .bottom)
                    }
                }
                .overlay {
                    if jobs.isEmpty {
                        EmptyStateView(
                            icon: "arrow.triangle.2.circlepath",
                            title: "Drop files to convert",
                            subtitle: "Supports any format ffmpeg can read"
                        )
                        .transition(.fadeInOnly)
                    }
                }
                .animation(.easeOut(duration: 0.25), value: jobs.isEmpty)
            }

            // ── Pinned bottom bar ─────────────────────────────────────────
            TabBottomBar(
                config: config,
                hasItems: hasJobs,
                showPrimaryAction: hasQueuedJobs,
                toolsReady: toolsReady,
                primaryActionEnabled: hasSelectedQueued,
                primaryActionDisabledLabel: isBatchMode ? "No Items Selected" : convertButtonLabel,
                primaryActionLabel: convertButtonLabel,
                primaryActionIcon: "arrow.triangle.2.circlepath",
                onClearAll: {},
                onPrimaryAction: { convertSelected() },
                showClearAll: false,
                pinnedWidth: mainPanelWidth * 0.60,
                hasBatchDirectoryControl: isBatchMode,
                leftControls: { EmptyView() },
                extraControls: {
                    if isBatchMode {
                        batchApplyControls
                    } else {
                        EmptyView()  // extraControls: no save-to field (per-card)
                    }
                },
                batchDirectoryControl: {
                    if isBatchMode {
                        batchDirectoryField
                    } else {
                        EmptyView()
                    }
                }
            )
        }
        // Measures this VStack's real resolved width once per layout pass
        // and stores it so the list header row, card queue, and bottom bar
        // all derive their 60% proportional width from the exact same
        // number -- matching Download's mainPanelWidth pattern exactly.
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { mainPanelWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, newWidth in
                        mainPanelWidth = newWidth
                    }
            }
        )
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
        guard !jobs.contains(where: { $0.inputURL == url }) else { return }
        let job = ConvertJob(inputURL: url)
        withAnimation(.spring(response: 0.35)) { jobs.append(job) }
    }

    private func convertSelected() {
        // Convert in order: oldest added first
        let pending = selectedJobs
            .filter { $0.status == .queued }
            .sorted { $0.addedAt < $1.addedAt }
        for job in pending {
            // In Select mode, every converted file goes to the shared batch
            // output folder (config.convertOutputDir) instead of each job's
            // own per-card SAVE TO location — this only affects where THIS
            // run writes its output; it never overwrites job.outputDir, so
            // the individual card's own folder choice is untouched and still
            // shown/used the next time that card is converted outside Select mode.
            runConversion(job: job, batchDestination: isBatchMode ? URL(fileURLWithPath: config.convertOutputDir) : nil)
        }
    }

    // MARK: - Batch Apply

    /// Applies a preset to every checked job at once. Each job resolves the
    /// preset against its own source codec (same logic as the single-card
    /// preset chip), so a batch of mixed-codec MKVs each get the correct
    /// source-aware result rather than one shared guess.
    private func batchApplyPreset(_ preset: ConvertPreset) {
        withAnimation(.spring(response: 0.25)) {
            for job in batchCheckedJobs where job.status == .queued {
                job.applyPresetToOverride(preset)
            }
            selectionVersion += 1
        }
    }

    /// Sets CONVERT AS mode on every checked job's Batch Apply override only,
    /// re-validating override format/codecs afterward. Never touches the base
    /// mediaMode/outputFormat/videoCodec/audioCodec/activePreset fields.
    private func batchApplyMode(_ mode: ConvertMediaMode) {
        withAnimation(.spring(response: 0.25)) {
            for job in batchCheckedJobs where job.status == .queued {
                guard job.isVideoFile || mode == .audio else { continue }
                var override = job.batchOverride ?? BatchOverride()
                override.mode = mode
                override.preset = nil
                let currentFormat = override.format ?? job.outputFormat
                let allowedFormats: [ConvertOutputFormat] = {
                    switch mode {
                    case .audio: return [.wav, .mp3, .m4a, .flac]
                    case .videoAndAudio, .videoOnly: return [.mp4, .mov, .mkv]
                    }
                }()
                if !allowedFormats.contains(currentFormat) {
                    override.format = allowedFormats.first
                }
                job.batchOverride = override
            }
            selectionVersion += 1
        }
    }

    /// Sets OUTPUT FORMAT on every checked job's Batch Apply override that
    /// supports it. Jobs whose effective mode can't use this format (e.g. an
    /// audio-only job offered a video container) are skipped rather than forced.
    private func batchApplyFormat(_ format: ConvertOutputFormat) {
        withAnimation(.spring(response: 0.25)) {
            for job in batchCheckedJobs where job.status == .queued {
                guard job.effectiveAvailableFormats.contains(format) else { continue }
                var override = job.batchOverride ?? BatchOverride()
                override.format = format
                override.preset = nil
                if let vc = override.videoCodec, !format.compatibleVideoCodecs.contains(vc) {
                    override.videoCodec = format.compatibleVideoCodecs.first
                }
                let currentAudio = override.audioCodec ?? job.audioCodec
                if !format.compatibleAudioCodecs.contains(currentAudio) {
                    override.audioCodec = format.compatibleAudioCodecs.first
                }
                job.batchOverride = override
            }
            selectionVersion += 1
        }
    }

    /// Sets VIDEO CODEC on every checked job's Batch Apply override for which
    /// this codec is valid in its effective container. Invalid jobs are skipped.
    private func batchApplyVideoCodec(_ codec: ConvertVideoCodec) {
        withAnimation(.spring(response: 0.25)) {
            for job in batchCheckedJobs where job.status == .queued {
                guard job.effectiveMediaMode.isVideo, job.effectiveAvailableVideoCodecs.contains(codec) else { continue }
                var override = job.batchOverride ?? BatchOverride()
                override.videoCodec = codec
                override.preset = nil
                job.batchOverride = override
            }
            selectionVersion += 1
        }
    }

    /// Sets AUDIO CODEC on every checked job's Batch Apply override for which
    /// this codec is valid in its effective container. Invalid jobs are skipped.
    private func batchApplyAudioCodec(_ codec: ConvertAudioCodec) {
        withAnimation(.spring(response: 0.25)) {
            for job in batchCheckedJobs where job.status == .queued {
                guard job.effectiveMediaMode != .videoOnly, job.effectiveAvailableAudioCodecs.contains(codec) else { continue }
                var override = job.batchOverride ?? BatchOverride()
                override.audioCodec = codec
                override.preset = nil
                job.batchOverride = override
            }
            selectionVersion += 1
        }
    }

    /// Batch Apply's bottom-bar settings row. Unlike the per-card version, chip
    /// selection state isn't meaningful here (checked jobs may already differ
    /// in mode/format/codec), so every chip is a one-tap action rather than a
    /// persistent selection — tapping applies that choice to every checked job.
    private var batchApplyControls: some View {
        let _ = selectionVersion // force recompute when checked jobs' settings change
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .font(.appMono(size: 11))
                    .foregroundColor(.white.opacity(DesignTokens.Text.secondary))
                Text(batchCheckedJobs.isEmpty ? "Check items above to batch apply" : "\(batchCheckedJobs.count) item\(batchCheckedJobs.count == 1 ? "" : "s") checked")
                    .font(.appMono(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
            }

            GlassDivider()

            // CONVERT AS — shown first, same order as the per-card version.
            // Only modes that apply to at least one checked file are offered
            // (e.g. no video-only modes if every checked item is audio-only).
            VStack(alignment: .leading, spacing: 6) {
                Label("CONVERT AS", systemImage: "switch.2")
                    .font(.appMono(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                HStack(spacing: 8) {
                    ForEach(batchAvailableModes, id: \.rawValue) { mode in
                        SelectorChip(label: mode.label, icon: mode.icon, isSelected: batchModeSelected(mode), tint: mode.chipTint) {
                            batchApplyMode(mode)
                        }
                    }
                }
            }

            // PRESETS — filtered by the modes actually present in the checked
            // selection, same as the per-card row filters by that job's mode.
            if !batchAvailablePresets.isEmpty {
                GlassDivider()
                VStack(alignment: .leading, spacing: 6) {
                    Label("PRESETS", systemImage: "wand.and.stars")
                        .font(.appMono(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                    HStack(spacing: 6) {
                        ForEach(batchAvailablePresets) { preset in
                            SelectorChip(label: preset.shortLabel, note: preset.note, isSelected: batchPresetSelected(preset)) {
                                batchApplyPreset(preset)
                            }
                        }
                    }
                }
            }

            GlassDivider()
            VStack(alignment: .leading, spacing: 6) {
                Label("OUTPUT FORMAT", systemImage: "doc.badge.arrow.up")
                    .font(.appMono(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                HStack(spacing: 6) {
                    ForEach(batchAvailableFormats) { fmt in
                        SelectorChip(label: fmt.rawValue, isSelected: batchFormatSelected(fmt)) {
                            batchApplyFormat(fmt)
                        }
                    }
                }
            }

            // VIDEO CODEC — hidden entirely when nothing checked is currently
            // in a video mode, mirroring the per-card `if job.mediaMode.isVideo` gate.
            if batchHasVideoModeJob {
                GlassDivider()
                VStack(alignment: .leading, spacing: 6) {
                    Label("VIDEO CODEC", systemImage: "video")
                        .font(.appMono(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                    HStack(spacing: 6) {
                        ForEach(batchAvailableVideoCodecs) { codec in
                            SelectorChip(label: codec.rawValue, isSelected: batchVideoCodecSelected(codec)) {
                                batchApplyVideoCodec(codec)
                            }
                        }
                    }
                }
            }

            // AUDIO CODEC — hidden when nothing checked would actually offer a
            // codec choice, mirroring the per-card gate (`mediaMode != .videoOnly`
            // and more than one available codec).
            if batchHasAudioCodecChoice {
                GlassDivider()
                VStack(alignment: .leading, spacing: 6) {
                    Label("AUDIO CODEC", systemImage: "waveform")
                        .font(.appMono(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                    HStack(spacing: 6) {
                        ForEach(batchAvailableAudioCodecs) { codec in
                            SelectorChip(label: codec.rawValue, isSelected: batchAudioCodecSelected(codec)) {
                                batchApplyAudioCodec(codec)
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .glassCard(cornerRadius: DesignTokens.Radius.medium)
    }

    /// Compact inline SAVE TO control for Select mode, rendered in TabBottomBar's
    /// top row (to the right of the Auto-Open Folder toggle) instead of inside the
    /// batch apply card below. Shared destination folder for every file converted
    /// while in Select mode; defaults to Downloads and remembers the last folder
    /// picked (persisted in config.convertOutputDir). Independent of each card's
    /// own per-card SAVE TO location, which stays untouched.
    private var batchDirectoryField: some View {
        VStack(alignment: .leading, spacing: DropGrid.labelSpacing) {
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

                GlassButton(label: "Browse...", icon: "folder.badge.plus", tint: DesignTokens.Accent.primary, verticalPadding: 4, fillHeight: true) {
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
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func runConversion(job: ConvertJob, batchDestination: URL? = nil) {
        guard let ffmpeg = ffmpegPath else { return }
        // Uses effective* settings throughout: Select Mode's Batch Apply choices
        // (if any) override the job's own base settings for this conversion run
        // only — the base fields on `job` are never written to, so its individual
        // card keeps showing exactly what it showed before. Same principle for
        // the destination folder: batchDestination (Select mode's shared SAVE TO
        // field) takes priority for this run only, without touching job.outputDir.
        let dir = batchDestination ?? job.outputDir ?? job.inputURL.deletingLastPathComponent()
        let output = dir.appendingPathComponent(job.effectiveOutputFilename)
        job.status = .converting
        job.progress = "Starting…"
        job.progressFraction = nil
        job.etaText = "0%"
        job.outputURL = output
        manager.appendLog("Convert: Starting \(job.inputURL.lastPathComponent) → \(output.lastPathComponent)")

        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            job.process = p
            p.executableURL = URL(fileURLWithPath: ffmpeg)
            var args = ["-y", "-i", job.inputURL.path]  // -y: always overwrite, always run a fresh process
            // Audio stream — stream-copy (no re-encode) when the chosen codec matches the source.
            if job.effectiveMediaMode != .videoOnly {
                let audioMatches = job.effectiveAudioCodecMatchesSource
                args += ["-c:a", audioMatches ? "copy" : job.effectiveAudioCodec.ffmpegCodec]
                // 5.1/7.1 sources need more headroom than stereo to avoid audible
                // compression artifacts — 384k covers 5.1 cleanly, 256k is plenty for stereo/mono.
                let isMultichannel = (job.mediaInfo?.audioChannelLabel).map { $0 == "5.1" || $0 == "7.1" } ?? false
                if !audioMatches && job.effectiveAudioCodec == .aac { args += ["-b:a", isMultichannel ? "384k" : "256k"] }
                if !audioMatches && job.effectiveAudioCodec == .mp3 { args += ["-b:a", "320k"] }
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
                if !audioMatches && job.effectiveAudioCodec == .aac {
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
            // Video stream — stream-copy (no re-encode) when the chosen codec matches the source.
            if job.effectiveMediaMode.isVideo {
                let videoMatches = job.effectiveVideoCodecMatchesSource
                args += ["-c:v", videoMatches ? "copy" : job.effectiveVideoCodec.ffmpegCodec]
                // -preset fast: significantly faster encode with minimal quality loss
                if !videoMatches && (job.effectiveVideoCodec == .h264 || job.effectiveVideoCodec == .h265) {
                    args += ["-preset", "fast"]
                }
                // libsvtav1 uses its own preset scale (0-13, lower = slower/better) — 8 is a
                // reasonable speed/quality balance, verified to encode successfully on-device.
                if !videoMatches && job.effectiveVideoCodec == .av1 {
                    args += ["-preset", "8", "-crf", "35"]
                }
                // libvpx-vp9 needs -b:v 0 to actually respect -crf (otherwise it defaults to
                // a bitrate-controlled mode and ignores the quality target).
                if !videoMatches && job.effectiveVideoCodec == .vp9 {
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
                    guard job.status != .cancelled else { return }
                    let success = p.terminationStatus == 0
                    job.status = success ? .done : .failed
                    job.progress = success ? "Done" : "Failed (exit \(p.terminationStatus))"
                    job.etaText = ""
                    self.manager.appendLog(success ? "Convert: ✓ Done: \(output.lastPathComponent)" : "Convert: ERROR — \(job.inputURL.lastPathComponent) failed (exit \(p.terminationStatus))")
                    // Real output size, read from disk now that the file exists.
                    let outputSizeString: String? = {
                        guard success, let attrs = try? FileManager.default.attributesOfItem(atPath: output.path),
                              let bytes = attrs[.size] as? Int else { return nil }
                        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
                    }()
                    // Codec/quality descriptor for the history chip — video gets codec + resolution,
                    // audio-only gets codec + bitrate. Falls back gracefully if info is unavailable.
                    let qualityDescriptor: String = {
                        if job.effectiveMediaMode.isVideo {
                            if let w = job.mediaInfo?.pixelWidth, let h = job.mediaInfo?.pixelHeight, w > 0, h > 0 {
                                return "\(job.effectiveVideoCodec.rawValue) · \(h)p"
                            }
                            return job.effectiveVideoCodec.rawValue
                        } else {
                            return "\(job.effectiveAudioCodec.rawValue) · \(job.effectiveAudioCodec.typicalBitrateKbps)kbps"
                        }
                    }()
                    // Save to history. `url` stays the ORIGINAL input path for
                    // reference, while `outputFilePath` points at the actual
                    // produced file so subtext/Reveal can target the real result.
                    let e = HistoryEntry(
                        title: output.deletingPathExtension().lastPathComponent,
                        url: job.inputURL.path,
                        format: job.effectiveOutputFormat.rawValue,  // use output format, not audio codec
                        quality: qualityDescriptor,
                        outputDir: dir.path,
                        fileSize: outputSizeString,
                        failed: !success,
                        errorMessage: success ? nil : "Exit code \(p.terminationStatus)",
                        mediaModeRaw: job.isVideoFile ? "video" : "audio",
                        thumbnailURL: "",
                        entryType: "conversion",
                        outputFilePath: success ? output.path : job.inputURL.path,
                        audioCodecLabel: job.effectiveMediaMode != .videoOnly ? job.effectiveAudioCodec.rawValue : ""
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
                }
            } catch {
                DispatchQueue.main.async {
                    guard job.status != .cancelled else { return }
                    job.status = .failed
                    job.progress = error.localizedDescription
                    self.manager.appendLog("Convert: ERROR — \(job.inputURL.lastPathComponent): \(error.localizedDescription)")
                    var e = HistoryEntry(
                        title: job.inputURL.deletingPathExtension().lastPathComponent,
                        url: job.inputURL.path,
                        format: job.audioCodec.rawValue,
                        quality: "",
                        outputDir: job.inputURL.deletingLastPathComponent().path,
                        fileSize: nil,
                        failed: true,
                        errorMessage: error.localizedDescription
                    )
                    e.entryType = "conversion"
                    self.history.add(e)
                }
            }
        }
    }
}


// MARK: - ConvertPreviewCard
//
// Switch between PreviewCard (queued) and CompletedCard (active/done/failed).

struct ConvertPreviewCard: View {
    @ObservedObject var job: ConvertJob
    var onRemove: () -> Void
    /// True while Batch Apply mode is active — hides the checkbox-less normal
    /// state and instead shows the checkbox while collapsing per-card settings,
    /// since all editing happens via the bottom bar's batch controls.
    var isBatchMode: Bool = false
    /// Called right after the checkbox toggles `job.isSelected`, so the parent
    /// `ConvertView` (a sibling, not an observer of this specific job) can bump
    /// its own state and re-render the batch controls' count/enabled state.
    var onSelectionChange: () -> Void = {}

    /// Collapses the settings sections (CONVERT AS → AUDIO CODEC) down to just
    /// the header + output folder + Convert button. Lives on `job.isExpanded`
    /// (not local @State) so the header's "collapse all" toggle can drive every
    /// card in lockstep — still transient UI state, never persisted.
    private var isExpanded: Binding<Bool> {
        Binding(
            get: { job.isExpanded },
            set: { job.isExpanded = $0; onSelectionChange() }
        )
    }

    var body: some View {
        if job.status == .queued {
            convertSettingsCard
        } else {
            convertCompletedCard
        }
    }

    // MARK: Thumbnail helper

    private var thumbView: AnyView? {
        guard let img = job.thumbnail else { return nil }
        return AnyView(Image(nsImage: img).resizable().aspectRatio(contentMode: .fill))
    }

    /// Same visual language as Download's ChipRow/HistoryChip — filled colored pills.
    /// Related values are combined into a single chip (joined with “ · ”) instead of one
    /// chip per field, to keep the row compact. Color grouping: gray/white = general file
    /// info (length/size, directory), blue = video/container info (format/codec/resolution),
    /// green = audio info (codec/channels).
    private var metaRowChips: [ChipData] {
        var chips: [ChipData] = []

        // Gray: length + size combined, each with its own icon (clock / drive).
        // Unit-suffixed ("45s"/"12m"/"2h") to match Drop/History's chips --
        // falls back to the raw "H:MM:SS" string only if seconds is missing.
        let dur = job.mediaInfo?.durationSeconds.flatMap { formatDurationChip(seconds: Int($0)) }
            ?? job.mediaInfo?.duration
        if let dur, let size = job.mediaInfo?.fileSize {
            chips.append(ChipData(label: "", value: dur, color: .white, icon: "clock",
                                   icon2: "internaldrive", value2: size))
        } else if let dur {
            chips.append(ChipData(label: "", value: dur, color: .white, icon: "clock"))
        } else if let size = job.mediaInfo?.fileSize {
            chips.append(ChipData(label: "", value: size, color: .white, icon: "internaldrive"))
        }
        // Directory is now shown as plain subtext above this chip row (see
        // subtitleView below) instead of a chip — no folder chip here anymore.
        // Blue: format + video codec + resolution combined
        let videoParts = [job.inputURL.pathExtension.uppercased(), job.mediaInfo?.videoCodec, job.mediaInfo?.resolution]
            .compactMap { $0 }.joined(separator: " · ")
        if !videoParts.isEmpty {
            chips.append(ChipData(label: "", value: videoParts, color: .blue,
                                   icon: job.isVideoFile ? "video" : "waveform"))
        }
        // Green: audio codec + channels combined
        let audioParts = [job.mediaInfo?.audioCodec, job.mediaInfo?.audioChannelLabel]
            .compactMap { $0 }.joined(separator: " · ")
        if !audioParts.isEmpty {
            chips.append(ChipData(label: "", value: audioParts, color: .green, icon: "waveform"))
        }
        return chips
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
                HStack(alignment: .center, spacing: 10) {
                    ChipRow(chips: job.inputChips)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(DesignTokens.Text.disabled))
                    ChipRow(chips: job.outputChips)
                }
                .animation(nil, value: job.mediaMode)
            }
        )
    }

    /// Always-visible CONVERT AS mode toggle -- same visual language as
    /// Download's modeRow (Video+Audio/Audio Only), just with the extra
    /// Video Only case Convert supports. Lives below the header, outside
    /// the thumbnail-centered group, so switching modes never touches the
    /// input side of subtitleView above.
    private var modeRow: AnyView {
        AnyView(
            HStack(spacing: 6) {
                ForEach(ConvertMediaMode.allCases.filter { job.isVideoFile || $0 == .audio }, id: \.rawValue) { mode in
                    CompactModeChip(label: mode.label, icon: mode.icon, isSelected: job.mediaMode == mode, tint: mode.chipTint) {
                        withAnimation(.spring(response: 0.25)) {
                            job.mediaMode = mode
                            job.activePreset = nil
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

    /// Below the header, full-width -- divider, then the mode toggle sharing
    /// its line with the collapse toggle (trailing edge), matching Download's
    /// belowHeaderRow exactly.
    private func belowHeaderRow(isExpandedBinding: Binding<Bool>) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 9) {
                GlassDivider()
                HStack(spacing: 6) {
                    modeRow
                    Spacer()
                    if !isBatchMode {
                        CollapseToggleButton(isExpanded: isExpandedBinding.wrappedValue) {
                            withAnimation(.spring(response: 0.25)) { isExpandedBinding.wrappedValue.toggle() }
                        }
                    }
                }
            }
        )
    }

    // MARK: Settings card (queued)

    private var convertSettingsCard: some View {
        PreviewCard(
            isSelected: job.isSelected,
            onToggleSelect: {
                withAnimation(.spring(response: 0.2)) {
                    job.isSelected.toggle()
                    // Checking a job in Select Mode seeds its Batch Apply
                    // override with Resolve Import Fix pre-highlighted, without
                    // touching this card's own settings. Unchecking clears it,
                    // so a job that's checked again later starts blank, not
                    // carrying over a choice from its last time being checked.
                    if job.isSelected {
                        job.seedBatchOverrideIfNeeded()
                    } else {
                        job.clearBatchOverride()
                    }
                }
                onSelectionChange()
            },
            onRemove: onRemove,
            showCheckbox: isBatchMode,
            thumbnail: thumbView,
            thumbnailPlaceholder: job.isVideoFile ? "video" : "waveform",
            title: job.inputURL.deletingPathExtension().lastPathComponent,
            subtitle: subtitleView, // path + input->output chip row -- always visible, even collapsed
            belowHeader: isBatchMode ? nil : belowHeaderRow(isExpandedBinding: isExpanded), // divider + CONVERT AS mode toggle + collapse button -- outside the thumbnail-centered group
            isExpanded: isBatchMode ? .constant(false) : isExpanded,
            collapseLocked: isBatchMode,
            // Collapse button now lives inside belowHeaderRow, on the same
            // line as the mode toggle, matching Download exactly. In Batch
            // Select mode there's no belowHeaderRow (mode editing moves to
            // the shared batch controls), so the header keeps its own button.
            collapseButtonInHeader: isBatchMode
        ) {
            // PRESETS — one-tap format/codec combinations, filtered by the mode
            // selected in the always-visible belowHeaderRow (CONVERT AS) so
            // switching modes shows presets that actually apply (e.g.
            // "Compatible Audio, No Video Re-encode" only appears when
            // there's a video track to protect). No leading divider here --
            // PreviewCard's fullCard already inserts one before settings().
            VStack(alignment: .leading, spacing: 6) {
                Label("PRESETS", systemImage: "wand.and.stars")
                    .font(.appMono(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                HStack(spacing: 6) {
                    ForEach(ConvertPreset.options(for: job.mediaMode)) { preset in
                        SelectorChip(
                            label: preset.shortLabel,
                            note: preset.note,
                            isSelected: job.activePreset == preset
                        ) {
                            withAnimation(.spring(response: 0.25)) {
                                job.applyPreset(preset)
                            }
                        }
                    }
                }
            }

            // OUTPUT FORMAT (filtered by mode)
            GlassDivider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("OUTPUT FORMAT", systemImage: "doc.badge.arrow.up")
                        .font(.appMono(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                    Spacer()
                    nativeLegend(positiveLabel: "Original", showReencodeHint: false)
                }
                HStack(spacing: 6) {
                    ForEach(job.availableFormats) { fmt in
                        SelectorChip(
                            label: fmt.rawValue,
                            isSelected: job.outputFormat == fmt,
                            nativeBadge: fmt.matchesSource(job.inputURL.pathExtension) ? true : nil
                        ) {
                            withAnimation(.spring(response: 0.25)) {
                                job.outputFormat = fmt
                                job.activePreset = nil
                                job.ensureCodecsValidForFormat()
                            }
                        }
                    }
                }
            }

            // VIDEO CODEC (video mode only)
            if job.mediaMode.isVideo {
                GlassDivider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("VIDEO CODEC", systemImage: "video")
                            .font(.appMono(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                        Spacer()
                        nativeLegend(positiveLabel: "Original", showReencodeHint: false)
                    }
                    HStack(spacing: 6) {
                        ForEach(job.availableVideoCodecs) { codec in
                            SelectorChip(
                                label: codec.rawValue,
                                isSelected: job.videoCodec == codec,
                                nativeBadge: codec.matchesSource(job.mediaInfo?.videoCodec) ? true : nil
                            ) {
                                withAnimation(.spring(response: 0.25)) {
                                    job.videoCodec = codec
                                    job.activePreset = nil
                                }
                            }
                        }
                    }
                }
            }

            // AUDIO CODEC (hidden for video-only mode, and hidden when the output
            // format only has one possible audio codec — e.g. MP3/FLAC are self-contained,
            // so there's no real choice to present)
            if job.mediaMode != .videoOnly && job.availableAudioCodecs.count > 1 {
                GlassDivider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("AUDIO CODEC", systemImage: "waveform")
                            .font(.appMono(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                        Spacer()
                        nativeLegend(positiveLabel: "Original", showReencodeHint: false)
                    }
                    HStack(spacing: 6) {
                        ForEach(job.availableAudioCodecs) { codec in
                            SelectorChip(
                                label: codec.rawValue,
                                isSelected: job.audioCodec == codec,
                                nativeBadge: codec.matchesSource(job.mediaInfo?.audioCodec) ? true : nil
                            ) {
                                withAnimation(.spring(response: 0.25)) {
                                    job.audioCodec = codec
                                    job.activePreset = nil
                                }
                            }
                        }
                    }
                }
            }

            // OUTPUT FOLDER
            GlassDivider()
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Label("OUTPUT FOLDER", systemImage: "folder")
                        .font(.appMono(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                    if let sizeLabel = job.estimatedOutputSizeLabel {
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: "internaldrive")
                                .font(.appMono(size: 9))
                            Text(sizeLabel)
                                .font(.appMono(size: 10, weight: .semibold))
                        }
                        .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(DesignTokens.Interactive.fillRest))
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous))
                    }
                }
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.white.opacity(DesignTokens.Text.secondary))
                        .font(.appMono(size: 12))
                    Text(job.outputDir?.path ?? job.inputURL.deletingLastPathComponent().path)
                        .font(.appMono(size: 12))
                        .foregroundColor(.white.opacity(DesignTokens.Text.secondary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    GlassButton(label: "Browse...", icon: "folder.badge.plus", tint: DesignTokens.Accent.primary) {
                        pickOutputFolder()
                    }
                    .frame(width: 120)
                }
                .padding(8)
                .background(Color.white.opacity(DesignTokens.Field.fillRest))
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Field.cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DesignTokens.Field.cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(DesignTokens.Field.borderRest), lineWidth: DesignTokens.Field.borderWidth))
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
            let dir = job.outputDir?.path ?? job.inputURL.deletingLastPathComponent().path
            let name = job.inputURL.deletingPathExtension().lastPathComponent
            return (dir as NSString).appendingPathComponent("\(name).\(job.effectiveOutputFormat.fileExtension)")
        }()

        var chips: [ChipData] = []

        // Gray: length + size combined — same field order as the input row.
        // Length is unchanged by conversion (Convert never trims/retimes),
        // so it carries over from the source media info. Size is only read
        // once the job is done — while converting, the output file is still
        // being written and its on-disk size is a partial/growing number,
        // not the final file size, so we withhold it until it's final.
        // Unit-suffixed ("45s"/"12m"/"2h") to match Drop/History's chips --
        // falls back to the raw "H:MM:SS" string only if seconds is missing.
        let lengthValue = job.mediaInfo?.durationSeconds.flatMap { formatDurationChip(seconds: Int($0)) }
            ?? job.mediaInfo?.duration
        let sizeValue: String? = {
            guard job.status == .done else {
                DropLogger.shared.write("Convert size chip: skipped, status=\(job.status)")
                return nil
            }
            guard let out = job.outputURL else {
                DropLogger.shared.write("Convert size chip: outputURL is nil")
                return nil
            }
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: out.path) else {
                DropLogger.shared.write("Convert size chip: attributesOfItem failed for \(out.path)")
                return nil
            }
            // NSNumber-backed sizes can be UInt64 for large files on some
            // volumes — casting straight to Int silently failed and dropped
            // the size chip. Go through NSNumber's int64Value instead, which
            // bridges correctly regardless of the underlying storage width.
            guard let sizeNumber = attrs[.size] as? NSNumber else {
                DropLogger.shared.write("Convert size chip: .size attr not NSNumber, raw=\(String(describing: attrs[.size]))")
                return nil
            }
            let bytes = sizeNumber.int64Value
            guard bytes > 0 else {
                DropLogger.shared.write("Convert size chip: bytes<=0 (\(bytes)) for \(out.path)")
                return nil
            }
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }()
        if let lengthValue, let sizeValue {
            chips.append(ChipData(label: "", value: lengthValue, color: .white, icon: "clock",
                                   icon2: "internaldrive", value2: sizeValue))
        } else if let lengthValue {
            chips.append(ChipData(label: "", value: lengthValue, color: .white, icon: "clock"))
        } else if let sizeValue {
            chips.append(ChipData(label: "", value: sizeValue, color: .white, icon: "internaldrive"))
        }

        // Blue: format + video codec + resolution. Resolution is unchanged
        // by conversion (Convert never resizes), so it carries over from
        // the source media info, matching the input row's video chip.
        if job.effectiveMediaMode.isVideo {
            let parts = [job.effectiveOutputFormat.rawValue.uppercased(), job.effectiveVideoCodec.rawValue, job.mediaInfo?.resolution]
                .compactMap { $0 }
            chips.append(ChipData(label: "", value: parts.joined(separator: " \u{b7} "), color: .blue, icon: "video"))
        }

        // Green: audio codec + channels. Channels are unchanged by
        // conversion (Convert never remixes), so they carry over from the
        // source media info, matching the input row's audio chip.
        if job.effectiveMediaMode != .videoOnly {
            let parts = [job.effectiveAudioCodec.rawValue, job.mediaInfo?.audioChannelLabel].compactMap { $0 }
            chips.append(ChipData(label: "", value: parts.joined(separator: " \u{b7} "), color: .green, icon: "waveform"))
        }

        return AnyView(
            InputOutputRow(
                inputPath: job.inputURL.path,
                inputChips: metaRowChips,
                outputPath: outPath,
                outputChips: chips
            )
        )
    }

    /// Status icon + pill — lives in the actions row, to the left of the
    /// Reveal/Reconvert/Retry buttons, not in the header subtitle.
    private var statusView: AnyView {
        AnyView(
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
                        Image(systemName: "clock").foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                    case .cancelled:
                        Image(systemName: "slash.circle.fill").foregroundColor(.orange)
                    }
                }.font(.appMono(size: 14))

                StatusPill(label: statusLabel, color: statusColor)
            }
        )
    }

    private var convertCompletedCard: some View {
        CompletedCard(
            isSelected: job.isSelected,
            onToggleSelect: {
                withAnimation(.spring(response: 0.2)) {
                    job.isSelected.toggle()
                    if job.isSelected {
                        job.seedBatchOverrideIfNeeded()
                    } else {
                        job.clearBatchOverride()
                    }
                }
                onSelectionChange()
            },
            onRemove: onRemove,
            showCheckbox: isBatchMode,
            thumbnail: thumbView,
            thumbnailPlaceholder: job.isVideoFile ? "video" : "waveform",
            title: job.inputURL.deletingPathExtension().lastPathComponent,
            subtitle: outputLayer
        ) {
            // Actions row — buttons stretch to fill the full card width (each
            // GlassButton defaults to maxWidth: .infinity), so this HStack
            // itself must also claim the full width. A leading Spacer() here
            // previously ate the extra space and left a gap on the left with
            // the buttons hugging the right edge instead of spanning the card.
            HStack(spacing: 10) {
                    statusView
                    if job.status == .done, let out = job.outputURL {
                        GlassButton(label: "Reveal in Finder", icon: "folder.fill", tint: DesignTokens.Accent.primary) {
                            NSWorkspace.shared.activateFileViewerSelecting([out])
                        }
                        GlassButton(label: "Reconvert", icon: "arrow.uturn.backward", tint: DesignTokens.Accent.warning) {
                            withAnimation(.spring(response: 0.25)) {
                                job.status = .queued
                                job.progress = "Queued"
                                job.progressFraction = nil
                                job.etaText = ""
                                job.outputURL = nil
                                job.isExpanded = true // auto-uncollapse so settings are visible again
                            }
                            // Requeuing mutates job.status on a class instance behind the
                            // parent's [ConvertJob] @Binding — that alone doesn't trigger the
                            // parent to recompute hasQueuedJobs/hasSelectedQueued, so the
                            // bottom Convert button would stay hidden. Force it.
                            onSelectionChange()
                        }
                    }
                    if job.status == .failed || job.status == .cancelled {
                        GlassButton(label: "Retry", icon: "arrow.counterclockwise", tint: DesignTokens.Accent.danger) {
                            withAnimation(.spring(response: 0.25)) {
                                job.status = .queued
                                job.progress = "Queued"
                                job.progressFraction = nil
                                job.etaText = ""
                                job.outputURL = nil
                            }
                            // Same reasoning as Reconvert above — force the parent to
                            // re-evaluate so the Convert button reappears after Retry.
                            onSelectionChange()
                        }
                    }
                    if job.status == .converting {
                        GlassButton(label: "Cancel", icon: "stop.fill", tint: .red) {
                            job.cancel()
                        }
                    }
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
                                .transition(.fadeInOnly)
                        }
                        if !job.progress.isEmpty {
                            Text(job.progress)
                                .font(.appMono(size: 10, design: .monospaced))
                                .foregroundColor(.white.opacity(DesignTokens.Text.disabled))
                                .lineLimit(1).truncationMode(.tail)
                                .transition(.fadeInOnly)
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

    private func pickOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Folder"
        if panel.runModal() == .OK {
            job.outputDir = panel.url
        }
    }
}
