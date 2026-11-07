<p align="center">
  <img src="Downloader/AppIcon1024.png" width="120" alt="Downloader app icon">
</p>

<h1 align="center">Downloader</h1>

<p align="center">A download manager for <b>iPhone</b> | parallel segmented downloads that keep going in the background, a persistent queue, live speed and time remaining, and pause and resume that pick up right where they stopped.</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-iOS%2017%2B-0A5E75" alt="Platform: iOS 17+">
  <a href="https://github.com/c12n/downloader/releases/latest"><img src="https://img.shields.io/github/v/release/c12n/downloader?label=Latest%20release&color=0AA2C0" alt="Latest release"></a>
  <a href="https://github.com/c12n/downloader/releases"><img src="https://img.shields.io/github/downloads/c12n/downloader/total?label=Downloads&color=0AA2C0" alt="Downloads"></a>
  <img src="https://img.shields.io/github/license/c12n/downloader?color=0AA2C0" alt="License: MIT">
</p>

<p align="center">
  📥 <a href="https://github.com/c12n/downloader/releases/latest"><b>Download v1.3.0</b></a> · 🐛 <a href="https://github.com/c12n/downloader/issues"><b>Report an issue</b></a>
</p>

`v1.3.0` · Background downloads, magnet and torrent support through debrid services, grab-all-links in the browser, a share extension, and automatic repair for failed downloads.

> [!NOTE]
> **Independent.** Downloader is an open-source app in the spirit of AB Download Manager. It is not affiliated with or endorsed by AB Download Manager or Apple Inc.

---

## 🌟 Features

| **Segmented downloads**<br>When a server supports byte ranges, a file is split into parts and pulled down over parallel connections | 1 to 16, you choose (default 4). No range support? It falls back to a single stream automatically.<br> | **A queue that persists**<br>Add one link or many at once. The queue, progress and resume data are saved on the device, so closing the app loses nothing.<br> |
| :--- | :--- |
| **Pause and resume**<br>Pause anything, resume it later | even after a relaunch, a segmented download continues from the parts it already has instead of starting over.<br> | **Live speed and ETA**<br>Every running download shows its current speed and time remaining, updated as it goes.<br> |
| **Files where you can see them**<br>Finished downloads land in the app's `Documents/Downloads` folder, visible in the Files app, ready to open or share.<br> | **Your pace**<br>Settings for connection count, how many downloads run at once, and a keep-awake switch for long pulls.<br> |
| **Built-in browser**<br>A WebKit browser with an ad and tracker blocker and no pop-ups, ever. Tap a download link and the app offers to grab it | confirm, and the download is added and starts right away.<br> | **Debrid speed**<br>Add your TorBox, Premiumize or Real-Debrid key in Settings and test it in the app. Links from hosts a verified service supports are fetched through that service instead of directly, then downloaded with the same segmented engine.<br> |
| **Background downloads**<br>Downloads run on a background engine now: close the app, lock the phone, they keep going | and a notification arrives when each file finishes. Progress survives relaunches, and anything left stranded comes back as paused, ready to resume.<br> | **Magnets and torrents**<br>Paste a magnet link or share a .torrent file and your verified debrid service fetches the torrent on its own servers; every file in it lands in the queue as a normal download.<br> |
| **Grab every link**<br>The browser menu lists every downloadable link on the page you are on; pick the ones you want and add them all in one tap. Bookmarks keep your regular sites one tap away.<br> | **Share and self-repair**<br>Send links to Downloader from Safari's share sheet. A failed download retries itself once, and an expired debrid link re-resolves on its own. Queue filters, a details screen for every download, clipboard pre-fill, and a Wi-Fi-only switch round it out.<br> |

---

## 🚀 Installation

### iOS

**Sideload**

1. Download `Downloader.ipa` from the [latest release](https://github.com/c12n/downloader/releases/latest).
2. Install it with Feather, AltStore, SideStore, Sideloadly, or your preferred sideloading tool.
3. Updates are new IPAs from the same releases page; installing one over the old keeps your queue and files.

> [!TIP]
> The IPA is unsigned, so your sideloading tool signs it with your own certificate as part of the install.

---

## 📖 How to Use

1. **Add links:** paste one URL, or several at once (magnets included), and add them to the queue. You can also share any link to Downloader from Safari, or use the **Browser** tab: open a page, tap a download link, and confirm; or open the browser menu and grab every download link on the page at once.
2. **Let it run:** downloads start in order and keep going in the background; watch speed and time remaining on each row, and pause or resume any of them. Rows fetched through a debrid service say so ("via TorBox").
3. **Get your files:** finished downloads are in the Files app under the Downloader folder, in `Downloads`.

---

## 🗺️ Roadmap

- **Per-download connection counts** | override the global setting on a single file.
- **Archive extraction** | open and extract ZIP files without leaving the app.
- **Scheduled downloads** | let a queue wait for a set time before it starts.

---

## ⚠️ Known Issues

- If the app is force-quit while downloads are running, iOS stops them. Reopen Downloader and they are waiting as paused, keeping every byte they already downloaded.
- Magnet and .torrent links need a debrid key that has been added and tested in Settings; there is no direct way to download a torrent.
- Servers that do not support byte ranges are downloaded in a single stream, so they will not get the segmented speed-up.

---

## ❓ FAQ

**Is it free?**
Yes | free, no ads, no in-app purchases.

**What links does it work with?**
Any direct link to a file. If the server supports byte ranges you get segmented speed; if not, the same link downloads in a single stream.

**What is a debrid service?**
TorBox, Premiumize and Real-Debrid are paid services that fetch files from file hosters onto their own fast servers. If you have an account, add your API key under Settings → Debrid services and tap Test. Once it shows Verified, links from hosts that service supports are fetched through it automatically; everything else downloads directly as before. Multi-file links add every file to the queue.

**Do downloads keep going if I close the app?**
Yes. Downloads run in the background and a notification arrives when each file finishes. The one exception is force-quitting the app, which stops them; reopen Downloader and resume.

**How do magnet links work?**
A magnet needs a debrid service to fetch it. Add a TorBox, Premiumize or Real-Debrid key in Settings and tap Test; once verified, pasted magnets, magnets tapped in the browser, and shared .torrent files are fetched by that service and their files are queued like normal downloads.

**Does it collect my data?**
No accounts, no analytics, no tracking, no ads. See the Privacy section below.

---

## 🔒 Privacy

Downloader collects nothing. There are no accounts, no analytics, no tracking and no ads. The network traffic is the downloads you start, the pages you open in the built-in browser, and, if you add debrid keys, requests to those services with your key. Debrid keys are stored in the iOS Keychain. Your queue, settings, bookmarks and files stay on your device.

---

## 🏗️ Built With

- **SwiftUI** for the interface
- **Background URLSession** for the download engine, with a custom segmented (range) downloader on top
- **WebKit** for the built-in browser, with a bundled content-rule ad blocker
- **Swift** throughout | no third-party dependencies

---

## 🛠️ Build It Yourself

### iOS

1. Open `Downloader.xcodeproj` in Xcode.
2. Pick the `Downloader` target and build for an arm64 iOS device (iOS 17+).
3. For a sideload IPA, build with signing off and package the `.app` into a `Payload` folder, or let your sideloading tool handle it.

<details>
<summary><b>Project layout</b></summary>

- `Downloader/` | the app target: `ContentView` (queue interface), `DownloadManager` (queue, persistence, scheduling, notifications, share-sheet hand-off), `SegmentedDownloader` (the background download engine: parallel range download tasks, pause resume data, relaunch recovery), `BrowserView` (WebKit browser, ad blocking, download capture, grab-all-links, bookmarks), `Debrid` (TorBox, Premiumize and Real-Debrid clients, Keychain keys, host routing, magnets and torrents), `Models`, `SettingsView`, `adblock-rules.json`, and the app icons
- `ShareExtension/` | the share extension: queues shared links into the app through the shared App Group container
- `Downloader.xcodeproj` | the Xcode project
- Releases are built from this source and attached to the [GitHub releases](https://github.com/c12n/downloader/releases)

</details>

---

## Disclaimer

This is an unofficial open-source project and is not affiliated with, authorized, or endorsed by AB Download Manager or Apple Inc. Provided "as is", without warranty of any kind. Only download files you have the right to download.

- This app is **free**. If a third party charged you for it, you may have been misled.
- No user data is collected, stored, or distributed by this repository.

## 📄 License

MIT | Copyright (c) 2026 c12n Apps. See [LICENSE](LICENSE).

> [!TIP]
> **Star the repo** to get notified about new releases directly from GitHub.
