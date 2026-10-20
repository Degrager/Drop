import SwiftUI
import AppKit
import UserNotifications
import UniformTypeIdentifiers
import QuickLookThumbnailing
import CryptoKit
import Sparkle

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

    /// Audio-quality raw codes ("0"/"5"/"9"/"auto") to their kbps label — same mapping
    /// used for the live download quality chip, applied here to final output data.
    private var resolvedQualityLabel: String {
        switch quality {
        case "320K": return "320kbps"
        case "5": return "256 kbps"
        case "9": return "128 kbps"
        // Auto means "matched the source's own real bitrate" -- show that real number
        // (captured in the analyze snapshot) rather than the literal word "auto".
        case "auto": return snapshotSourceABR > 0 ? "\(snapshotSourceABR)kbps" : "Auto"
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

@MainActor
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
        // The copy is taken here, on the main thread; the background work only ever sees the copy.
        let legacyEntries = entries
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let repaired = Self.repairedLegacyConversionEntries(legacyEntries) else { return }
            DispatchQueue.main.async { [weak self] in self?.applyRepairedEntries(repaired) }
        }
    }

    /// Puts repaired entries back by id, so an entry added while the repair ran is not lost.
    private func applyRepairedEntries(_ repaired: [HistoryEntry]) {
        let byID = Dictionary(repaired.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for i in entries.indices { if let fixed = byID[entries[i].id] { entries[i] = fixed } }
        scheduleSave()
    }

    /// One-time repair for conversion history entries saved before this fix: the
    /// old code passed the full OUTPUT FILE path as `outputDir` (so the folder chip
    /// showed a filename) and never captured `fileSize`/`quality`. This probes the
    /// real file on disk (if it still exists) to recover the true folder, size, and
    /// codec/quality info, running once per affected entry then re-saving.
    nonisolated private static func repairedLegacyConversionEntries(_ entries: [HistoryEntry]) -> [HistoryEntry]? {
        // All file I/O and ffprobe calls happen here, off the main thread, on a copy.
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
                snapshot[i].fileSize = formatByteSize(Int(bytes))
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

        return changed ? snapshot : nil
    }
}
