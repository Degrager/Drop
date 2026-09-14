# Drop

Drop is a fast, native macOS app for downloading and converting online video and audio. Paste a link, pick a quality, and Drop handles the rest — powered by [yt-dlp](https://github.com/yt-dlp/yt-dlp) and [ffmpeg](https://ffmpeg.org/) under the hood, wrapped in a clean SwiftUI interface with a black frosted-glass design.

## Features

- **Paste-and-go downloading** — paste any supported link (YouTube and hundreds of other sites via yt-dlp) and Drop analyzes it automatically.
- **Quality and format selection** — choose resolution up to 4K, pick between MP4 and MKV output, and select audio-only extraction when you just want the sound.
- **Smart format compatibility** — Drop's MP4 pipeline automatically avoids VP9/AV1-in-MP4 combinations that fail to play back in QuickTime, falling back to MKV when a source needs a codec MP4 can't reliably carry.
- **Menu bar quick access** — paste a link from anywhere and Drop picks it up without stealing focus from what you're doing.
- **Download history** — every past download is tracked with one-click redownload/retry that reuses the original analyzed link, no need to re-paste.
- **Bundled, self-updating tools** — yt-dlp and ffmpeg are bundled and kept up to date automatically, so you always get the latest site support and codec fixes without manual maintenance.
- **In-app updates** — Drop checks GitHub Releases for new versions and can update itself in place from the same panel that manages the yt-dlp/ffmpeg tooling.

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon or Intel Mac

## Installation

Download the latest `Drop.dmg` from the [Releases page](https://github.com/Degrager/Drop/releases/latest), open it, and drag Drop into your Applications folder.

Since Drop is distributed outside the Mac App Store, macOS Gatekeeper will flag it as being from an unidentified developer on first launch. Right-click (or Control-click) the app and choose **Open** to bypass this the first time.

## Building from source

1. Clone this repository.
2. Open `Drop.xcodeproj` in Xcode 16 or later.
3. Build and run the `Drop` scheme (Release configuration recommended for normal use).

## Updates

Drop can update itself. Click Check For Updates in the sidebar and it will automatically install the latest version directly from this repository's [Releases](https://github.com/Degrager/Drop/releases) — no need to redownload manually.

## License

All rights reserved. Source is provided for transparency and self-building; redistribution of modified builds is not permitted.
