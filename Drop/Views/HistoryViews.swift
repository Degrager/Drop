import SwiftUI
import AppKit
import QuickLookThumbnailing

// MARK: - History View

struct HistoryView: View {
    @ObservedObject var history: HistoryStore
    @Binding var activeTab: AppTab
    @Binding var urlText: String
    @Binding var hasInvalidURLs: Bool
    @Binding var linkPreviews: [ContentView.LinkPreview]
    @ObservedObject var config: Config
    let onAnalyze: ([String], [UUID]) -> Void
    let onReconvert: (URL) -> Void
    @Environment(\.isCompactHeight) private var compactHeight
    @State private var searchText = ""
    @State private var isSearchHovering = false
    @FocusState private var searchFieldFocused: Bool

    var filtered: [HistoryEntry] {
        guard !searchText.isEmpty else { return history.entries }
        return history.entries.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.url.localizedCaseInsensitiveContains(searchText)
        }
    }

    // Group entries by relative date label
    var grouped: [(label: String, entries: [HistoryEntry])] {
        let cal = Calendar.current
        let now = Date()
        var buckets: [(String, [HistoryEntry])] = []
        var seen: [String: Int] = [:]
        for entry in filtered {
            let label: String
            if cal.isDateInToday(entry.date) { label = "Today" }
            else if cal.isDateInYesterday(entry.date) { label = "Yesterday" }
            else {
                let days = cal.dateComponents([.day], from: entry.date, to: now).day ?? Int.max
                if days < 7 { label = "This Week" }
                else if days < 30 { label = "This Month" }
                else { label = "Older" }
            }
            if let idx = seen[label] {
                buckets[idx].1.append(entry)
            } else {
                seen[label] = buckets.count
                buckets.append((label, [entry]))
            }
        }
        return buckets.map { (label: $0.0, entries: $0.1) }
    }

    // Same black-frosted-glass capsule recipe as urlCard/dropZoneView --
    // search field flush left, "Clear all" as an embedded pill on the
    // right, instead of the previous bare HStack sitting directly on the
    // page background with no card treatment at all.
    private var searchHeader: some View {
        let fieldHeight: CGFloat = 52
        let innerPillHeight: CGFloat = fieldHeight - 10

        return HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.white.opacity(DesignTokens.Text.tertiary)).font(.appMono(size: 12))
                // Placeholder rendered as its own Text layer at the same
                // dim 0.18 opacity urlCard/dropZoneView use for "Paste a
                // link…"/"Click or drop files here…" -- native TextField
                // placeholder text on macOS doesn't reliably pick up
                // .foregroundColor, which is why this previously rendered
                // brighter/whiter than every other tab's placeholder text.
                ZStack(alignment: .leading) {
                    if searchText.isEmpty {
                        Text("Search history…")
                            .font(.appMono(size: 13))
                            .foregroundColor(.white.opacity(0.18))
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.appMono(size: 13))
                        .foregroundColor(.white.opacity(DesignTokens.Text.secondary))
                        .focused($searchFieldFocused)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 14)
            .frame(height: fieldHeight, alignment: .center)
            .frame(maxWidth: .infinity)

            if !history.entries.isEmpty {
                GlassButton(
                    label: "Clear all",
                    icon: "trash",
                    tint: .white,
                    horizontalPadding: 14,
                    fillHeight: true,
                    fitContent: true,
                    embedded: true,
                    activeFillOverride: (rest: 0.12, active: 0.12, hover: 0.12, press: 0.12),
                    embeddedGlowStroke: true,
                    scaleOverride: (hover: 1.0, press: 1.0),
                    action: { history.clear() }
                )
                .frame(height: innerPillHeight)
                .padding(.trailing, 5)
            } else {
                // Keeps the capsule's trailing edge visually balanced
                // (matching the field's own leading inset) when there's
                // no Clear-all pill to embed.
                Spacer().frame(width: 14)
            }
        }
        .frame(height: fieldHeight)
        .background(
            ZStack {
                VisualEffectBlur(material: DesignTokens.Glass.material, blendingMode: .behindWindow)
                Color.black.opacity(DesignTokens.Glass.blackTint)
                Color.white.opacity(0.55 * DesignTokens.Glass.whiteWash)
                DitherNoise(opacity: 0.04)
            }
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(DropGrid.fieldBorderOpacity), lineWidth: DropGrid.fieldBorderWidth)
            )
        )
        // Rim glow on hover or focus (cursor in the field) -- same cue as
        // urlCard's and Convert's header bars.
        .overlay {
            HoverGlowRim(isActive: isSearchHovering || searchFieldFocused)
        }
        .onHover { isSearchHovering = $0 }
        // Fills the tab's content column exactly (the whole History panel is
        // pinned to it -- see ContentView), so this capsule is the same
        // width as Download's paste bar and Convert's drop zone.
        .frame(maxWidth: .infinity)
        .shadow(color: .black.opacity(DesignTokens.Interactive.glowShadowPeak), radius: 10, y: 4)
    }

    var body: some View {
        VStack(spacing: 12) {
            searchHeader
                .padding(.top, compactHeight ? 26 : 40)
                .padding(.bottom, compactHeight ? 12 : 20)

            if filtered.isEmpty {
                EmptyStateView(
                    icon: "clock",
                    title: history.entries.isEmpty ? "No downloads yet" : "No results"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 8, pinnedViews: [.sectionHeaders]) {
                        ForEach(grouped, id: \.label) { group in
                            Section {
                                ForEach(group.entries) { entry in
                                    HistoryRow(entry: entry, config: config, onRemove: {
                                        withAnimation(.easeOut(duration: 0.2)) { history.remove(id: entry.id) }
                                    }) {
                                        if entry.entryType == "conversion" {
                                            // Reconvert: re-import the ORIGINAL input file (stored
                                            // in entry.url for conversions) exactly like a fresh
                                            // drop/import — no stored snapshot reused.
                                            onReconvert(URL(fileURLWithPath: entry.url))
                                        } else {
                                            // Redownload: treat exactly like a fresh paste — a live
                                            // analyze against the URL always re-runs from scratch, so
                                            // no stale snapshot data (duration, resolutions, quality
                                            // options) is ever reused for the actual download. The one
                                            // exception is cosmetic: since we already know this link's
                                            // title/thumbnail from the previous analyze, show them on
                                            // the placeholder immediately instead of the bare URL while
                                            // the fresh analyze runs — purely a faster-feeling display,
                                            // replaced the instant the new analyze result comes back.
                                            let placeholder = ContentView.LinkPreview(
                                                url: entry.url, title: entry.title, thumbnailURL: entry.thumbnailURL,
                                                hasVideo: false, duration: "",
                                                mediaMode: .audioOnly, isPending: true
                                            )
                                            linkPreviews.append(placeholder)
                                            hasInvalidURLs = false
                                            activeTab = .download
                                            // Pass the placeholder's own id through so the analyze
                                            // result lands on THIS card -- analyzeURL() generates its
                                            // own fresh UUIDs when no ids override is given, which
                                            // never matched this placeholder's id and left it stuck
                                            // on "Analyzing…" forever (the result was silently
                                            // dropped, matching the deliberate no-else-append design
                                            // for cancelled/cleared cards).
                                            onAnalyze([entry.url], [placeholder.id])
                                        }
                                    }
                                }
                            } header: {
                                Text(group.label)
                                    .font(.appMono(size: 10, weight: .semibold))
                                    .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 20)
                                    .padding(.top, 8)
                                    .padding(.bottom, 2)
                            }
                        }
                    }
                    .padding(.vertical, 16)
                }
            }
        }
    }
}

// MARK: - History Row

struct HistoryRow: View {
    let entry: HistoryEntry
    @ObservedObject var config: Config
    let onRemove: () -> Void
    let onRedownload: () -> Void
    @State private var hovering = false

    var formattedDate: String {
        let cal = Calendar.current
        if cal.isDateInToday(entry.date) {
            return "Today " + DateFormatter.localizedString(from: entry.date, dateStyle: .none, timeStyle: .short)
        } else if cal.isDateInYesterday(entry.date) {
            return "Yesterday"
        } else {
            return DateFormatter.localizedString(from: entry.date, dateStyle: .short, timeStyle: .none)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Thumbnail + title/date row
            HStack(alignment: .top, spacing: 10) {
                // Thumbnail (only when URL available)
                if !entry.thumbnailURL.isEmpty, let thumbURL = URL(string: entry.thumbnailURL) {
                    AsyncImage(url: thumbURL) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().aspectRatio(contentMode: .fill)
                                .frame(width: 56, height: 36)
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        case .failure, .empty:
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.white.opacity(DesignTokens.Interactive.fillRest))
                                .frame(width: 56, height: 36)
                        @unknown default:
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.white.opacity(DesignTokens.Interactive.fillRest))
                                .frame(width: 56, height: 36)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: entry.failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundColor(entry.failed ? .red.opacity(0.6) : .green.opacity(0.55))
                            .font(.appMono(size: 12))
                        Text(entry.title)
                            .font(.appMono(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(DesignTokens.Text.primary))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(formattedDate)
                            .font(.appMono(size: 10)).foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                        Button(action: onRemove) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                                .frame(width: 16, height: 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Remove from History")
                        .accessibilityLabel("Remove from History")
                        // Faint at rest (so it's discoverable without hovering,
                        // and reachable by accessibility/keyboard), full on hover.
                        .opacity(hovering ? 1 : 0.3)
                    }
                    // For conversions, `url` is the ORIGINAL input file — show
                    // the actual produced file's path instead when available.
                    Text(entry.entryType == "conversion" && !entry.outputFilePath.isEmpty ? entry.outputFilePath : entry.url)
                        .font(.appMono(size: 10)).foregroundColor(.white.opacity(DesignTokens.Text.disabled))
                        .lineLimit(1).truncationMode(.middle)
                }
            }

            // Error message for failed entries
            if entry.failed, let err = entry.errorMessage, !err.isEmpty {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.appMono(size: 10)).foregroundColor(.red.opacity(0.7))
                    Text(err)
                        .font(.appMono(size: 10))
                        .foregroundColor(.red.opacity(0.65))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.red.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous)
                    .stroke(Color.red.opacity(0.15), lineWidth: 0.5))
            }

            // Metadata chips row — dynamic, color-grouped chips reflecting final output data
            HStack(spacing: 6) {
                ChipRow(chips: entry.chips)

                Spacer()

                if !entry.failed {
                    // Reveal button — selects the actual finished file (not just
                    // the containing folder) so it matches the Download/Convert
                    // card behavior. Falls back to the output directory itself
                    // if no specific file path was recorded (older entries).
                    GlassButton(label: "Reveal", icon: "folder.fill", tint: .white, fitContent: true) {
                        let target = !entry.outputFilePath.isEmpty ? entry.outputFilePath : entry.outputDir
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)])
                    }
                }

                // Retry / Reconvert / Redownload button — same GlassButton style
                // used on the Download/Convert tab cards. Conversion entries say
                // "Reconvert" instead of "Redownload" to match their action.
                GlassButton(
                    label: entry.failed ? "Retry" : (entry.entryType == "conversion" ? "Reconvert" : "Redownload"),
                    icon: entry.failed ? "arrow.counterclockwise" : "arrow.uturn.down",
                    tint: entry.failed ? .red : DesignTokens.Accent.warning,
                    fitContent: true,
                    action: onRedownload
                )
            }
        }
        .padding(12)
        // Same black-frosted glass material every other card in the app
        // uses (was previously flat white-on-black with no blur -- a gap
        // versus the rest of the design language). Mirrors GlassCard's
        // exact layer order: blur base, black tint, white wash, hover lift.
        .background(
            ZStack {
                VisualEffectBlur(material: DesignTokens.Glass.material, blendingMode: .behindWindow)
                Color.black.opacity(DesignTokens.Glass.blackTint)
                Color.white.opacity(hovering ? DesignTokens.Interactive.fillHover : DesignTokens.Glass.whiteWash)
                DitherNoise(opacity: 0.04)
            }
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium, style: .continuous))
        )
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.medium, style: .continuous)
            .stroke(Color.white.opacity(hovering ? DesignTokens.Interactive.strokeHover : DesignTokens.Interactive.strokeRest), lineWidth: 0.5))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu {
            Button("Remove from History", role: .destructive, action: onRemove)
        }
    }
}

struct HistoryChip: View {
    let label: String
    let value: String
    let color: Color
    var icon: String? = nil
    /// Optional second icon rendered right before `value2` — lets a single chip
    /// combine two related fields (e.g. length + size) while still showing a
    /// distinct icon for each segment.
    var icon2: String? = nil
    var value2: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.appMono(size: 9, weight: .bold))
                    .foregroundColor(color.opacity(0.7))
            }
            if !label.isEmpty {
                Text(label)
                    .font(.appMono(size: 9, weight: .bold))
                    .foregroundColor(color.opacity(0.6))
                    .lineLimit(1)
            }
            Text(value)
                .font(.appMono(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                .lineLimit(1)
            if let icon2, let value2 {
                Text("·")
                    .font(.appMono(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                Image(systemName: icon2)
                    .font(.appMono(size: 9, weight: .bold))
                    .foregroundColor(color.opacity(0.7))
                Text(value2)
                    .font(.appMono(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                    .lineLimit(1)
            }
        }
        // Natural width when there's room; text truncates (rather than the
        // chip overflowing its row) when the container is narrower.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous)
            .stroke(color.opacity(0.2), lineWidth: 0.5))
    }
}

// MARK: - History Thumbnailer
//
// Conversion entries have no remote thumbnail URL (unlike downloads, which
// use the source site's thumbnail), so we generate one locally from the
// finished output file via QuickLook and cache it to disk as a small PNG.
// The resulting file:// URL slots into the same `thumbnailURL` field/AsyncImage
// path History already uses for download thumbnails.
enum HistoryThumbnailer {
    private static var cacheDir: URL? = {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("DropHistoryThumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Deletes a cached thumbnail given the `file://` URL string stored on a
    /// HistoryEntry. Anything outside the cache directory (a download's remote
    /// https thumbnail, or an empty string) is ignored.
    static func deleteCachedThumbnail(_ urlString: String) {
        guard let cacheDir, urlString.hasPrefix("file://"), let url = URL(string: urlString),
              url.standardizedFileURL.deletingLastPathComponent() == cacheDir.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes every cached thumbnail no history entry references anymore.
    static func pruneCache(keeping referencedURLStrings: Set<String>) {
        guard let cacheDir,
              let files = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) else { return }
        let keep = Set(referencedURLStrings.compactMap { URL(string: $0)?.standardizedFileURL.path })
        for file in files where !keep.contains(file.standardizedFileURL.path) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Generates a thumbnail for `fileURL` and calls back with a `file://`
    /// URL string on success, or nil on failure. Callback fires on a
    /// background queue — caller is responsible for dispatching to main.
    static func generate(for fileURL: URL, completion: @escaping (String?) -> Void) {
        guard let cacheDir else { completion(nil); return }
        let outPath = cacheDir.appendingPathComponent(UUID().uuidString + ".png")
        let size = CGSize(width: 112, height: 72)
        let scale: CGFloat = 2.0
        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateRepresentations(for: request) { rep, _, _ in
            guard let image = rep?.nsImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                completion(nil)
                return
            }
            do {
                try png.write(to: outPath)
                completion(outPath.absoluteString)
            } catch {
                completion(nil)
            }
        }
    }
}




