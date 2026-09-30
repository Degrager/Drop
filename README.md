<p align="center">
  <img src=".github/readme/logo.png" alt="Drop" height="80">
</p>

<p align="center">
  <a href="#requirements"><img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-0A0A0A?style=flat-square&logo=apple&logoColor=white"></a>
  <a href="#requirements"><img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-arm64-0A0A0A?style=flat-square"></a>
  <a href="#how-it-works"><img alt="Swift" src="https://img.shields.io/badge/Swift-SwiftUI-0A0A0A?style=flat-square&logo=swift&logoColor=white"></a>
</p>

<p align="center">Drop is a fast, native macOS app for downloading and converting online video and audio. Paste a link, pick a quality, and Drop handles the rest — powered by <a href="https://github.com/yt-dlp/yt-dlp">yt-dlp</a> and <a href="https://ffmpeg.org/">ffmpeg</a>, wrapped in a clean SwiftUI interface with a dark liquid-glass design.</p>

<p align="center">
  <img src=".github/readme/hero.png" alt="Drop's Download tab in its empty state, ready for a link to be copied" width="760">
</p>

## How it works

### Download

Paste a YouTube, SoundCloud, or Vimeo link — Drop reads it straight from your clipboard. Pick a format, resolution, and audio quality, then download. Multiple links queue up and download independently, each with its own settings.

<p align="center">
  <img src=".github/readme/download.png" alt="Drop's Download tab showing two queued YouTube videos, one expanded with format and resolution options" width="760">
</p>

### Convert

Drop a local video or audio file to re-encode it or just change containers. Codec, resolution, and bitrate default to "Same as Source" — Drop only touches what you actually change, copying streams instead of re-encoding them wherever it can.

<p align="center">
  <img src=".github/readme/convert.png" alt="Convert tab showing codec, resolution, and bitrate controls for a local file" width="760">
</p>

### Quick access from the menu bar

Copy a link anywhere and click Drop's menu bar icon — it shows what's on your clipboard and lets you analyze it without switching apps or losing focus on what you're doing.

<p align="center">
  <img src=".github/readme/menubar.png" alt="Drop's menu bar quick-access panel showing a clipboard link ready to analyze" width="360">
</p>

### History

Every download is logged with its original link, so redownloading or retrying a failed one is one click — no need to find and re-paste the URL.

<p align="center">
  <img src=".github/readme/history.png" alt="History tab listing past downloads with redownload and reveal actions" width="760">
</p>

## Features

- **Paste-and-go downloading** — paste any supported link (YouTube, Soundcloud, and Vimeo via yt-dlp), choose your quality and format, and download.
- **Menu bar quick access** — paste a link from anywhere and Drop picks it up without stealing focus from what you're doing.
- **Download history** — every past download is tracked with one-click redownload/retry that reuses the original analyzed link, no need to re-paste.
- **In-app updates** — Drop can detect latest GitHub Releases and can update itself, it also keeps yt-dlp and ffmpeg updated, all integrated directly into the app.

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
