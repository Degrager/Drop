import XCTest
@testable import Drop

/// Tests for Drop's pure logic: the functions that turn input into text, sizes and command
/// lines, and have no UI or process behind them. Past regressions (fractional durations, bitrate
/// rounding, size estimates) were all in code like this.
final class FormattingTests: XCTestCase {
    func testDurationChip() {
        XCTAssertNil(formatDurationChip(seconds: 0))
        XCTAssertEqual(formatDurationChip(seconds: 45), "45s")
        XCTAssertEqual(formatDurationChip(seconds: 90), "2m")        // 1.5 min rounds up
        XCTAssertEqual(formatDurationChip(seconds: 3600), "1h")
        XCTAssertEqual(formatDurationChip(seconds: 5400), "1.5h")
    }

    func testByteSizeUsesDecimalUnits() {
        XCTAssertEqual(formatByteSize(0), "0 B")
        XCTAssertEqual(formatByteSize(999), "999 B")
        XCTAssertEqual(formatByteSize(637_031), "637 KB")
        XCTAssertEqual(formatByteSize(13_500_000), "13.5 MB")
        XCTAssertEqual(formatByteSize(1_390_000_000), "1.39 GB")
        XCTAssertEqual(formatByteSize(-5), "0 B")
    }

    func testResolutionMarketingNames() {
        XCTAssertEqual(resolutionMarketingName(forMaxHeight: 2160), "4K Ultra HD")
        XCTAssertEqual(resolutionMarketingName(forMaxHeight: 1080), "Full HD")
        XCTAssertEqual(resolutionMarketingName(forMaxHeight: 720), "HD")
        XCTAssertNil(resolutionMarketingName(forMaxHeight: 999))
    }

    func testHighestQualityTierForASourceHeight() {
        XCTAssertEqual(VideoQuality.highest(for: 2160), .q4k)
        XCTAssertEqual(VideoQuality.highest(for: 1200), .q1080)
        XCTAssertEqual(VideoQuality.highest(for: 719), .q480)
    }

    func testBitrateLabel() {
        XCTAssertEqual(bitrateLabel(kbps: 160), "160kbps")
        XCTAssertNil(bitrateLabel(kbps: 0))
    }
}

final class FilenameSanitizerTests: XCTestCase {
    func testRestrictedCharactersBecomeFullWidthLookalikes() {
        XCTAssertEqual(ytdlpSanitizedFilename("a/b"), "a\u{29F8}b")
        XCTAssertEqual(ytdlpSanitizedFilename("What: Now?"), "What\u{FF1A} Now\u{FF1F}")
    }

    func testTimestampColonsBecomeUnderscores() {
        XCTAssertEqual(ytdlpSanitizedFilename("Live 12:34"), "Live 12_34")
    }

    func testEmptyStaysEmptyAndLeadingDotsAndHyphensAreFixed() {
        XCTAssertEqual(ytdlpSanitizedFilename(""), "")
        XCTAssertEqual(ytdlpSanitizedFilename(".hidden"), "hidden")
        XCTAssertEqual(ytdlpSanitizedFilename("-x"), "_x")
    }
}

final class URLValidationTests: XCTestCase {
    func testSchemeIsAddedWhenMissing() {
        XCTAssertEqual(normalizedDropURLLine("example.com/x"), "https://example.com/x")
        XCTAssertEqual(normalizedDropURLLine("http://a.b"), "http://a.b")
    }

    func testOnlyRealWebLinksPass() {
        XCTAssertTrue(dropAllLinesAreURLs("https://www.youtube.com/watch?v=aqz-KE-bpKQ"))
        XCTAssertTrue(dropAllLinesAreURLs("https://a.com/x\nhttps://b.com/y"))
        XCTAssertFalse(dropAllLinesAreURLs(""))
        XCTAssertFalse(dropAllLinesAreURLs("hello this is not a link"))
        XCTAssertFalse(dropAllLinesAreURLs("ftp://files.example.com/a"))
        XCTAssertFalse(dropAllLinesAreURLs("https://a.com/x\nnot a link"))
    }

    /// Foundation turns any text into a host once `https://` is added, so ordinary words (a
    /// Japanese sentence turns into a punycode name, a lone word is a host) used to pass.
    func testOrdinaryTextIsNotALinkEvenWithoutSpaces() {
        XCTAssertFalse(dropAllLinesAreURLs("さん、し、じゅうご、ご、じゅうに、じゅう、さんじゅう、"))
        XCTAssertFalse(dropAllLinesAreURLs("foo"))
        XCTAssertFalse(dropAllLinesAreURLs("hello"))
        XCTAssertFalse(dropAllLinesAreURLs("https://notahost"))
        XCTAssertFalse(dropAllLinesAreURLs("version 1.5"))
        XCTAssertFalse(dropAllLinesAreURLs("https://a.com/x\nさん、し"))
    }

    func testRealHostsStillPass() {
        XCTAssertTrue(dropAllLinesAreURLs("youtube.com/watch?v=abc"))
        XCTAssertTrue(dropAllLinesAreURLs("https://日本語.jp/ページ"))
        XCTAssertTrue(dropAllLinesAreURLs("https://example.co.uk/a"))
        XCTAssertTrue(dropAllLinesAreURLs("http://localhost:8000/a"))
        XCTAssertTrue(dropAllLinesAreURLs("http://192.168.1.5:8000/a"))
        XCTAssertTrue(dropAllLinesAreURLs("https://[::1]/x"))
        XCTAssertTrue(dropAllLinesAreURLs("https://example.com./x"))
        XCTAssertFalse(dropAllLinesAreURLs("https://999.1.1.1.1/x"))
    }
}

final class StreamSizeEstimateTests: XCTestCase {
    func testReportedSizeWins() {
        let stream: [String: Any] = ["filesize": 5_000_000, "tbr": 9_999]
        XCTAssertEqual(estimatedStreamBytes(stream, among: [stream], durationSeconds: 100), 5_000_000)
    }

    func testApproximateSizeIsUsedWhenExactIsMissing() {
        let stream: [String: Any] = ["filesize_approx": 4_000_000]
        XCTAssertEqual(estimatedStreamBytes(stream, among: [stream], durationSeconds: 100), 4_000_000)
    }

    func testManifestStreamBorrowsTheSizeOfItsDirectTwin() {
        let hls: [String: Any] = ["height": 1080, "vcodec": "avc1.640028", "protocol": "m3u8_native", "tbr": 3000]
        let direct: [String: Any] = ["height": 1080, "vcodec": "avc1.4d401f", "filesize": 77_151_406, "tbr": 2900]
        XCTAssertEqual(estimatedStreamBytes(hls, among: [hls, direct], durationSeconds: 120), 77_151_406)
    }

    func testPremiumStreamDoesNotBorrowFromAnOrdinaryTwin() {
        let premium: [String: Any] = ["height": 1080, "vcodec": "avc1.640028", "format_note": "Premium", "tbr": 2000, "protocol": "https"]
        let ordinary: [String: Any] = ["height": 1080, "vcodec": "avc1.4d401f", "filesize": 5_000_000]
        // 2000 kbps x 125 bytes per kbps-second x 100 s
        XCTAssertEqual(estimatedStreamBytes(premium, among: [premium, ordinary], durationSeconds: 100), 25_000_000)
    }

    func testBitrateTimesDurationHalvedForAManifest() {
        let direct: [String: Any] = ["tbr": 1000, "protocol": "https"]
        let manifest: [String: Any] = ["tbr": 1000, "protocol": "m3u8_native"]
        XCTAssertEqual(estimatedStreamBytes(direct, among: [direct], durationSeconds: 100), 12_500_000)
        XCTAssertEqual(estimatedStreamBytes(manifest, among: [manifest], durationSeconds: 100), 6_250_000)
    }

    func testNoSizeAndNoBitrateGivesZero() {
        let stream: [String: Any] = ["height": 720]
        XCTAssertEqual(estimatedStreamBytes(stream, among: [stream], durationSeconds: 100), 0)
    }
}

final class SyncTextTests: XCTestCase {
    func testAppendsFromManyThreadsAreAllKept() {
        let text = SyncText()
        let group = DispatchGroup()
        for _ in 0..<8 {
            DispatchQueue.global().async(group: group) {
                for _ in 0..<500 { text.append("x\n") }
            }
        }
        group.wait()
        XCTAssertEqual(text.value.count, 8 * 500 * 2)
    }
}

final class HistoryEntryTests: XCTestCase {
    private func entry(_ json: String) throws -> HistoryEntry {
        try JSONDecoder().decode(HistoryEntry.self, from: Data(json.utf8))
    }

    /// Adding a field to HistoryEntry must never make saved history unreadable.
    func testEmptyJSONDecodesToDefaults() throws {
        let e = try entry("{}")
        XCTAssertEqual(e.title, "")
        XCTAssertEqual(e.entryType, "download")
        XCTAssertFalse(e.failed)
        XCTAssertEqual(e.outputFilePath, "")
    }

    func testFinishedFileURL() throws {
        XCTAssertEqual(try entry(#"{"outputFilePath": "/tmp/a.mp4"}"#).finishedFileURL?.path, "/tmp/a.mp4")
        XCTAssertNil(try entry(#"{"outputFilePath": "/tmp/a.mp4", "failed": true}"#).finishedFileURL)
        XCTAssertNil(try entry("{}").finishedFileURL)
    }
}

final class ConvertCommandTests: XCTestCase {
    private let input = "/tmp/in.mp4", output = "/tmp/out.mp4"

    /// A job whose source is H.264 + AAC at 1080p, the common case. ffprobe's codec names are
    /// uppercased by the app ("H264", "AAC"), and the copy-or-encode rule matches on those.
    private func job() -> ConvertJob {
        let job = ConvertJob(inputURL: URL(fileURLWithPath: input))
        job.mediaInfo = ConvertMediaInfo(
            videoCodec: "H264", audioCodec: "AAC", audioChannelLabel: "2.0",
            resolution: "1920x1080", duration: "1:00", fileSize: "10 MB",
            durationSeconds: 60, pixelWidth: 1920, pixelHeight: 1080)
        return job
    }

    func testUntouchedSourceIsAPureStreamCopy() {
        XCTAssertEqual(job().ffmpegArgs(outputPath: output),
                       ["-y", "-i", input, "-c:a", "copy", "-c:v", "copy", output])
    }

    func testChoosingASmallerResolutionReEncodesTheVideoOnly() {
        let j = job()
        j.chosenResolution = 720
        let args = j.ffmpegArgs(outputPath: output)
        XCTAssertTrue(args.contains("libx264"))
        XCTAssertTrue(args.contains("scale=w='if(gt(iw,ih),-2,720)':h='if(gt(iw,ih),720,-2)':flags=lanczos"))
        XCTAssertEqual(args[args.firstIndex(of: "-c:a")! + 1], "copy")
    }

    func testVideoOnlyDropsAudio() {
        let j = job()
        j.mediaMode = .videoOnly
        let args = j.ffmpegArgs(outputPath: output)
        XCTAssertTrue(args.contains("-an"))
        XCTAssertFalse(args.contains("-c:a"))
    }

    func testAudioOnlyDropsVideo() {
        let j = job()
        j.mediaMode = .audio
        let args = j.ffmpegArgs(outputPath: output)
        XCTAssertTrue(args.contains("-vn"))
        XCTAssertFalse(args.contains("-c:v"))
    }

    func testH265InMP4IsTaggedForQuickTime() {
        let j = job()
        j.videoCodec = .h265
        let args = j.ffmpegArgs(outputPath: output)
        XCTAssertTrue(args.contains("libx265"))
        XCTAssertEqual(args[args.firstIndex(of: "-tag:v")! + 1], "hvc1")
    }

    func testOutputPathIsAlwaysLast() {
        XCTAssertEqual(job().ffmpegArgs(outputPath: output).last, output)
    }
}

/// Convert must never write over a file that is already there: ffmpeg runs with -y, and Cancel deletes
/// the run's own output, so a shared path meant a finished conversion could vanish.
final class ConvertOutputNamingTests: XCTestCase {
    private let dir = URL(fileURLWithPath: "/out")

    private func name(_ filename: String, taken: Set<String>) -> String {
        ConvertJob.uniqueOutputURL(filename: filename, in: dir) { taken.contains($0.path) }.lastPathComponent
    }

    func testFreeNameIsUsedAsIs() {
        XCTAssertEqual(name("Clip_converted.mp4", taken: []), "Clip_converted.mp4")
    }

    func testTakenNameGetsNumberedBeforeTheExtension() {
        XCTAssertEqual(name("Clip_converted.mp4", taken: ["/out/Clip_converted.mp4"]), "Clip_converted (2).mp4")
    }

    func testNumberingSkipsNamesAlreadyTaken() {
        let taken: Set<String> = ["/out/Clip_converted.mp4", "/out/Clip_converted (2).mp4", "/out/Clip_converted (3).mp4"]
        XCTAssertEqual(name("Clip_converted.mp4", taken: taken), "Clip_converted (4).mp4")
    }

    func testOnlyTheSameFolderCounts() {
        let taken: Set<String> = ["/elsewhere/Clip_converted.mp4"]
        XCTAssertEqual(name("Clip_converted.mp4", taken: taken), "Clip_converted.mp4")
    }

    func testDotsInTheNameAndNoExtension() {
        XCTAssertEqual(name("my.clip_converted.mp4", taken: ["/out/my.clip_converted.mp4"]), "my.clip_converted (2).mp4")
        XCTAssertEqual(name("notes", taken: ["/out/notes"]), "notes (2)")
    }

    /// Two different files with the same name (from different folders) get the same output name;
    /// the second one to run must land beside the first, not over it.
    func testSameNameFromTwoSourceFoldersDoesNotCollide() {
        let a = ConvertJob(inputURL: URL(fileURLWithPath: "/one/Clip.mov")).outputFilename
        let b = ConvertJob(inputURL: URL(fileURLWithPath: "/two/Clip.mov")).outputFilename
        XCTAssertEqual(a, b)
        let first = ConvertJob.uniqueOutputURL(filename: a, in: dir) { _ in false }
        let second = ConvertJob.uniqueOutputURL(filename: b, in: dir) { $0 == first }
        XCTAssertNotEqual(first, second)
    }

    /// The scenario that lost a file: convert, convert the same source again, cancel the second run.
    func testCancellingASecondRunLeavesTheFirstFinishedFileAlone() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("drop-naming-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let source = URL(fileURLWithPath: "/somewhere/Clip.mov")
        let firstOutput = ConvertJob.uniqueOutputURL(filename: ConvertJob(inputURL: source).outputFilename, in: tmp)
        try Data("finished first conversion".utf8).write(to: firstOutput)

        let second = ConvertJob(inputURL: source)
        second.outputURL = ConvertJob.uniqueOutputURL(filename: second.outputFilename, in: tmp)
        XCTAssertNotEqual(second.outputURL, firstOutput)
        try Data("half-written".utf8).write(to: second.outputURL!)

        second.cancel()

        XCTAssertTrue(FileManager.default.fileExists(atPath: firstOutput.path), "the first finished file must survive")
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.outputURL!.path), "the cancelled run's own file is removed")
    }
}

// MARK: - yt-dlp output lines

final class YtDlpOutputUpdateTests: XCTestCase {
    private func parse(_ line: String, last: Double = 0, elapsed: Int = 5) -> (YtDlpOutputUpdate, Double) {
        var fraction = last
        let update = YtDlpOutputUpdate.parse(line: line, lastFraction: &fraction, elapsedSeconds: elapsed)
        return (update, fraction)
    }

    func testPercentLineGivesProgressSpeedAndEta() {
        let (u, fraction) = parse("[download]  47.3% of  8.23MiB at  1.20MiB/s ETA 00:04")
        XCTAssertEqual(u.progress ?? -1, 0.473, accuracy: 0.0001)
        XCTAssertEqual(fraction, u.progress)
        XCTAssertTrue(u.isProgressLine)
        XCTAssertEqual(u.eta, .speed(text: "1.20MiB/s", eta: "00:04", hasRealETA: true))
        XCTAssertTrue(u.renderedLine.contains("[5s elapsed]"))
        XCTAssertTrue(u.renderedLine.contains("of  8.23MiB at  1.20MiB/s ETA 00:04"))
    }

    func testProgressNeverMovesBackward() {
        let (u, fraction) = parse("[download]  10.0% of  8.23MiB at  1.20MiB/s ETA 00:40", last: 0.6)
        XCTAssertEqual(u.progress, 0.6)
        XCTAssertEqual(fraction, 0.6)
    }

    func testFragmentIndexReplacesAnUnstablePercentage() {
        // The very first fragment line of an unknown-size stream can read 100%.
        let (u, _) = parse("[download] 100.0% of ~   1.00KiB at  1.00KiB/s ETA Unknown (frag 3/50)")
        XCTAssertEqual(u.progress ?? -1, 3.0 / 50.0, accuracy: 0.0001)
    }

    func testFragmentCounterIsStrippedFromTheEta() {
        let (u, _) = parse("[download]  20.0% of ~  50.00MiB at  2.00MiB/s ETA 02:55 (frag 11/50)")
        XCTAssertEqual(u.eta, .speed(text: "2.00MiB/s", eta: "02:55", hasRealETA: true))
    }

    func testUnknownOrNearZeroEtaIsNotReal() {
        XCTAssertEqual(parse("[download]  50.0% of  1.00MiB at  5.00MiB/s ETA Unknown").0.eta,
                       .speed(text: "5.00MiB/s", eta: "Unknown", hasRealETA: false))
        XCTAssertEqual(parse("[download]  50.0% of  1.00MiB at  5.00MiB/s ETA 00:01").0.eta,
                       .speed(text: "5.00MiB/s", eta: "00:01", hasRealETA: false))
    }

    func testUnknownSpeedFallsBackToDownloading() {
        let u = parse("[download]  50.0% of  1.00MiB at  Unknown B/s ETA Unknown").0
        XCTAssertEqual(u.eta, .speed(text: "Downloading\u{2026}", eta: "Unknown", hasRealETA: false))
    }

    func testPercentLineWithoutSpeedClearsTheEta() {
        let (u, _) = parse("[download] 100% of 8.23MiB in 00:00:07")
        XCTAssertEqual(u.eta, .clear)
        XCTAssertEqual(u.progress, 1.0)
    }

    func testActivityTextFromStatusLines() {
        XCTAssertEqual(parse("[youtube] Extracting URL: https://youtu.be/x").0.activityText, "Fetching info…")
        XCTAssertEqual(parse("[Merger] Merging formats into \"a.mp4\"").0.activityText, "Merging streams…")
        XCTAssertEqual(parse("[EmbedThumbnail] ffmpeg: Adding thumbnail").0.activityText, "Merging streams…")
        XCTAssertEqual(parse("[Metadata] Adding metadata to \"a.mp4\"").0.activityText, "Processing…")
        XCTAssertNil(parse("something unrelated").0.activityText)
    }

    func testPostProcessingLinePinsProgressComplete() {
        let u = parse("[ExtractAudio] Destination: a.m4a").0
        XCTAssertEqual(u.activityText, "Converting…")
        XCTAssertTrue(u.pinsProgressComplete)
        XCTAssertFalse(parse("[youtube] Extracting URL: https://youtu.be/x").0.pinsProgressComplete)
    }

    func testPlainLinesPassThroughUnchanged() {
        let u = parse("ERROR: Unsupported URL").0
        XCTAssertEqual(u.renderedLine, "ERROR: Unsupported URL")
        XCTAssertFalse(u.isProgressLine)
        XCTAssertNil(u.progress)
        XCTAssertNil(u.eta)
    }
}
