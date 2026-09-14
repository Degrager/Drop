import SwiftUI
import AppKit
import QuickLookThumbnailing

// MARK: - Universal Media Item Card
//
// One card struct for both the Download and Convert tabs.
// The enum MediaItem carries the tab-specific data; the card
// derives status, badges, detail section, and actions from it.
// Zero design divergence — same code path, same components.

// MARK: - Item model

enum MediaItem {
    case download(Download, DownloadManager, Config, Binding<String>)
    case convert(ConvertJob, ffmpegPath: String?, onRemove: () -> Void)
}

// MARK: - Card

struct MediaItemCard: View {
    let item: MediaItem

    // Convert-tab local state (ignored for download items)
    @State private var audioCodec: ConvertAudioCodec = .aac
    @State private var videoCodec: ConvertVideoCodec = .h264
    @State private var outputDir: String = ""
    @State private var showDirPicker = false

    // MARK: Derived — status

    private var statusIconName: String {
        switch item {
        case .download(let dl, _, _, _):
            switch dl.status {
            case .done:       return "checkmark.circle.fill"
            case .error:      return "xmark.circle.fill"
            case .cancelled:  return "slash.circle.fill"
            case .downloading: return "arrow.down.circle"
            case .pending:    return "clock"
            }
        case .convert(let job, _, _):
            switch job.status {
            case .queued:     return "clock"
            case .converting: return "arrow.triangle.2.circlepath"
            case .done:       return "checkmark.circle.fill"
            case .failed:     return "xmark.circle.fill"
            case .cancelled:  return "slash.circle.fill"
            }
        }
    }

    private var statusColor: Color {
        switch item {
        case .download(let dl, _, _, _):
            switch dl.status {
            case .done:        return .green
            case .error:       return .red
            case .cancelled:   return .orange
            case .downloading: return .white.opacity(DesignTokens.Text.secondary)
            case .pending:     return .white.opacity(DesignTokens.Text.tertiary)
            }
        case .convert(let job, _, _):
            switch job.status {
            case .queued:     return .white.opacity(DesignTokens.Text.tertiary)
            case .converting: return .blue
            case .done:       return .green
            case .failed:     return .red
            case .cancelled:  return .orange
            }
        }
    }

    // MARK: Derived — display content

    private var title: String {
        switch item {
        case .download(let dl, _, _, _): return dl.title
        case .convert(let job, _, _):    return job.inputURL.lastPathComponent
        }
    }

    private var subtitle: String {
        switch item {
        case .download(let dl, _, _, _): return dl.url
        case .convert(let job, _, _):    return job.progress
        }
    }

    private var badges: [MediaCardBadge] {
        switch item {
        case .download(let dl, _, _, _):
            var b: [MediaCardBadge] = [
                MediaCardBadge(label: dl.status.label, color: statusColor, background: statusColor.opacity(0.12)),
                MediaCardBadge(label: dl.format.label, color: .white.opacity(DesignTokens.Text.tertiary))
            ]
            if let size = dl.fileSize { b.append(MediaCardBadge(label: size, color: .white.opacity(DesignTokens.Text.disabled))) }
            return b
        case .convert(let job, _, _):
            let label: String = {
                switch job.status {
                case .queued:     return "Queued"
                case .converting: return "Converting"
                case .done:       return "Done"
                case .failed:     return "Failed"
                case .cancelled:  return "Cancelled"
                }
            }()
            return [
                MediaCardBadge(label: label, color: statusColor, background: statusColor.opacity(0.12)),
                MediaCardBadge(label: job.isVideoFile ? "Video" : "Audio", color: .white.opacity(DesignTokens.Text.tertiary))
            ]
        }
    }

    private var progressFraction: CGFloat? {
        switch item {
        case .download(let dl, _, _, _):
            guard dl.status == .downloading, let p = dl.progress else { return nil }
            return CGFloat(p)
        case .convert(let job, _, _):
            return job.status == .converting ? 0.6 : nil
        }
    }

    private var progressColor: Color {
        switch item {
        case .download: return .white
        case .convert:  return .blue
        }
    }

    private var showCheckbox: Bool {
        switch item {
        case .download: return false
        case .convert:  return true
        }
    }

    private var isChecked: Bool {
        switch item {
        case .download: return false
        case .convert(let job, _, _): return job.isSelected
        }
    }

    private var checkboxDisabled: Bool {
        switch item {
        case .download: return true
        case .convert(let job, _, _): return job.status != .queued
        }
    }

    private var thumbnail: NSImage? {
        switch item {
        case .download: return nil
        case .convert(let job, _, _): return job.thumbnail
        }
    }

    private var thumbnailPlaceholderIcon: String {
        switch item {
        case .download: return "doc"
        case .convert(let job, _, _): return job.isVideoFile ? "film" : "music.note"
        }
    }

    private var logLines: [String] {
        switch item {
        case .download(let dl, _, _, _): return dl.logs
        case .convert: return []
        }
    }

    // MARK: Derived — actions

    private var actions: [MediaCardAction] {
        switch item {
        case .download(let dl, let manager, let config, _):
            var acts: [MediaCardAction] = []
            if dl.status == .done {
                acts.append(.glass("Reveal in Finder", icon: "folder.fill") {
                    // Select the actual finished file, not just its containing folder.
                    // Falls back to the output directory if no specific file path was recorded.
                    if let filePath = dl.outputFilePath {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: filePath)])
                    } else {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dl.outputDir)])
                    }
                })
            }
            if dl.status == .error || dl.status == .cancelled {
                acts.append(.glass("Retry", icon: "arrow.counterclockwise") {
                    manager.retry(download: dl, config: config)
                })
            }
            if dl.status == .downloading {
                acts.append(.icon("stop.fill", color: .red.opacity(0.7)) {
                    manager.cancel(download: dl)
                })
            }
            return acts

        case .convert(let job, _, let onRemove):
            var acts: [MediaCardAction] = []
            if job.status == .done, let out = job.outputURL {
                acts.append(.glass("Reveal in Finder", icon: "folder.fill") {
                    NSWorkspace.shared.selectFile(
                        out.path,
                        inFileViewerRootedAtPath: out.deletingLastPathComponent().path
                    )
                })
            }
            if job.status == .failed || job.status == .cancelled {
                acts.append(.glass("Retry", icon: "arrow.counterclockwise") {
                    job.status = .queued; job.progress = "Queued"; job.isSelected = true
                })
            }
            if job.status == .queued || job.status == .failed || job.status == .cancelled {
                acts.append(.icon("xmark", color: .white.opacity(DesignTokens.Text.tertiary), action: onRemove))
            }
            if job.status == .converting {
                acts.append(.icon("stop.fill", color: .red.opacity(0.7)) {
                    job.cancel()
                })
            }
            return acts
        }
    }

    // MARK: Derived — detail section

    private var detailView: AnyView {
        switch item {
        case .download(let dl, let manager, let config, let urlText):
            return AnyView(DownloadItemDetail(
                download: dl, manager: manager, config: config, urlText: urlText))
        case .convert(let job, _, _):
            return AnyView(ConvertItemDetail(
                job: job,
                audioCodec: $audioCodec,
                videoCodec: $videoCodec,
                outputDir: $outputDir,
                showDirPicker: $showDirPicker
            ))
        }
    }

    // MARK: Checkbox toggle

    private func handleCheckboxToggle() {
        if case .convert(let job, _, _) = item, job.status == .queued {
            job.isSelected.toggle()
        }
    }

    // MARK: Body

    var body: some View {
        let icon   = statusIconName
        let color  = statusColor
        let bdgs   = badges
        let prog   = progressFraction
        let pcol   = progressColor
        let detail = detailView
        let acts   = actions
        let logs   = logLines
        let thumb  = thumbnail
        let thumbIcon = thumbnailPlaceholderIcon
        let chk    = isChecked
        let chkDis = checkboxDisabled
        let showChk = showCheckbox

        return MediaCard(
            showCheckbox:      showChk,
            isChecked:         chk,
            checkboxDisabled:  chkDis,
            onCheckboxToggle:  showChk ? handleCheckboxToggle : nil,
            thumbnail:         thumb,
            thumbnailPlaceholderIcon: thumbIcon,
            statusIconName:    icon,
            statusColor:       color,
            title:             title,
            badges:            bdgs,
            subtitle:          subtitle,
            progressFraction:  prog,
            progressColor:     pcol,
            detail:            detail,
            actions:           acts,
            logLines:          logs
        )
        .onAppear {
            if case .convert(let job, _, _) = item {
                audioCodec = job.audioCodec
                videoCodec = job.videoCodec
            }
        }
    }
}

// MARK: - Download detail section

private struct DownloadItemDetail: View {
    let download: Download
    let manager:  DownloadManager
    let config:   Config
    let urlText:  Binding<String>

    var body: some View {
        if download.status == .done {
            HStack(spacing: 12) {
                SmallActionButton(label: download.outputDir, icon: "folder.fill", tint: .green) {
                    // Select the actual finished file, not just its containing folder.
                    if let filePath = download.outputFilePath {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: filePath)])
                    } else {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: download.outputDir)])
                    }
                }
                SmallActionButton(label: "Re-paste", icon: "arrow.uturn.left") {
                    urlText.wrappedValue = download.url
                }
            }
        }
        if download.status == .error {
            if let err = download.errorMessage {
                Text(err).font(.system(size: 11)).foregroundColor(.red.opacity(0.75)).lineLimit(2)
            }
            if let hint = download.fixHint {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 10)).foregroundColor(.yellow.opacity(0.8))
                    Text(hint).font(.system(size: 11)).foregroundColor(.orange.opacity(0.85))
                }
            }
            if download.fixAction != .none {
                SmallActionButton(
                    label: fixLabel(download.fixAction),
                    icon: fixIcon(download.fixAction),
                    tint: .orange,
                    filled: true
                ) {
                    manager.performFix(for: download, config: config) {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false; panel.canChooseDirectories = true
                        panel.canCreateDirectories = true
                        panel.allowsMultipleSelection = false; panel.prompt = "Select Folder"
                        if panel.runModal() == .OK, let url = panel.url {
                            config.outputDir = url.path
                        }
                    }
                }
            }
        }
    }

    private func fixLabel(_ action: FixAction) -> String {
        switch action {
        case .setCookieNone:      return "Set Cookie Source to None"
        case .openFolderPicker:   return "Choose Folder"
        case .openPrivacySecurity: return "Open Privacy & Security"
        case .openURL:            return "Search on YouTube"
        case .none:               return ""
        }
    }
    private func fixIcon(_ action: FixAction) -> String {
        switch action {
        case .setCookieNone:      return "cookie"
        case .openFolderPicker:   return "folder.badge.plus"
        case .openPrivacySecurity: return "shield.fill"
        case .openURL:            return "magnifyingglass"
        case .none:               return ""
        }
    }
}

// MARK: - Convert detail section
//
// Mirrors the download card's section-label + GlassDivider + SelectorChip
// layout exactly. Same components, different options.

private struct ConvertItemDetail: View {
    @ObservedObject var job: ConvertJob
    @Binding var audioCodec:  ConvertAudioCodec
    @Binding var videoCodec:  ConvertVideoCodec
    @Binding var outputDir:   String
    @Binding var showDirPicker: Bool

    var body: some View {
        if job.status == .queued {
            VStack(alignment: .leading, spacing: 0) {

                GlassDivider()

                // ── AUDIO CODEC ──────────────────────────────────────────
                VStack(alignment: .leading, spacing: 8) {
                    Label("AUDIO CODEC", systemImage: "waveform")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                    HStack(spacing: 6) {
                        ForEach(job.availableAudioCodecs) { codec in
                            SelectorChip(
                                label: codec.rawValue,
                                isSelected: audioCodec == codec
                            ) {
                                audioCodec = codec; job.audioCodec = codec
                            }
                        }
                    }
                }
                .padding(.vertical, 10)

                // ── VIDEO CODEC (video files only) ───────────────────────
                if job.isVideoFile {
                    GlassDivider()
                    VStack(alignment: .leading, spacing: 8) {
                        Label("VIDEO CODEC", systemImage: "video")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                        HStack(spacing: 6) {
                            ForEach(job.availableVideoCodecs) { codec in
                                SelectorChip(
                                    label: codec.rawValue,
                                    isSelected: videoCodec == codec
                                ) {
                                    videoCodec = codec; job.videoCodec = codec
                                }
                            }
                        }
                    }
                    .padding(.vertical, 10)
                }

                // ── OUTPUT FOLDER ────────────────────────────────────────
                GlassDivider()
                VStack(alignment: .leading, spacing: 8) {
                    Label("OUTPUT FOLDER", systemImage: "folder")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                    // Passive value-display container (matches ConvertViews' output-folder
                    // box) with a tap target layered on top -- it reads as a field you can
                    // click to change, not a standalone action button.
                    Button { showDirPicker = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(DesignTokens.Text.disabled))
                            Text(outputDir.isEmpty ? "Same folder as source" : outputDir)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(DesignTokens.Text.tertiary))
                                .lineLimit(1).truncationMode(.middle)
                            if !outputDir.isEmpty {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(DesignTokens.Text.disabled * 0.7))
                                    .onTapGesture { outputDir = ""; job.outputDir = nil }
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Color.white.opacity(DesignTokens.Field.fillRest))
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Field.cornerRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignTokens.Field.cornerRadius, style: .continuous)
                                .stroke(Color.white.opacity(DesignTokens.Field.borderRest), lineWidth: DesignTokens.Field.borderWidth)
                        )
                    }
                    .buttonStyle(.plain)
                    .fileImporter(
                        isPresented: $showDirPicker,
                        allowedContentTypes: [.folder]
                    ) { result in
                        if case .success(let url) = result {
                            outputDir = url.path; job.outputDir = url
                        }
                    }
                }
                .padding(.vertical, 10)
            }
        }

        if job.status == .done, let out = job.outputURL {
            SmallActionButton(label: out.path, icon: "folder.fill", tint: .green) {
                NSWorkspace.shared.selectFile(
                    out.path,
                    inFileViewerRootedAtPath: out.deletingLastPathComponent().path
                )
            }
        }

        if job.status == .failed {
            Text(job.progress)
                .font(.system(size: 11))
                .foregroundColor(.red.opacity(0.75))
                .lineLimit(2)
        }

        if job.status == .cancelled {
            Text("Cancelled")
                .font(.system(size: 11))
                .foregroundColor(.orange.opacity(0.75))
                .lineLimit(2)
        }
    }
}
