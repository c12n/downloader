# Downloader | iOS download manager

Copyright (c) 2026 c12n Apps

A native SwiftUI download manager for iOS 17+, in the spirit of AB Download
Manager: a persistent queue with parallel segmented (range) downloads,
pause/resume that survives relaunch, live speed and ETA, and configurable
connection counts.

## Features

- Add one URL or many at once; the queue runs them in order
- Parallel segmented downloads when the server supports byte ranges
  (1 to 16 connections, default 4, for files of 1 MB and up), with a
  single-stream fallback when it does not
- Pause and resume, persisted across relaunch exactly where it stopped
- Live speed and ETA per download
- Finished files land in `Documents/Downloads`, visible in the Files app
- Settings for connection count, simultaneous downloads, and keep-awake
- No third-party dependencies

## Install

Grab `Downloader.ipa` from the
[latest release](https://github.com/c12n/downloader/releases/latest) and
sideload it with Feather, AltStore, or SideStore.

- Bundle: `com.c12n.downloadmanager` | Version 1.0.0 (1) | iOS 17+ | arm64

## Notes

- Downloads run on a foreground URLSession: iOS may suspend the app after
  it has been in the background for a while. Paused and partial progress
  is persisted and resumes where it stopped.
- Segment part files and resume state live in Application Support.

## Building

Open `Downloader.xcodeproj` in Xcode, pick the `Downloader` target, and
build for an arm64 iOS device. No packages to fetch.
