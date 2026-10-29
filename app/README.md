# Ladle for Mac

The macOS app, its download engine, the browser extensions and the native messaging helper.
What Ladle does, and every name, URL, setting and shortcut it uses, is in [`SPEC.md`](../SPEC.md).

| Folder | What |
| --- | --- |
| [`LadleKit/`](LadleKit/) | The engine as a Swift package (Foundation only, builds and tests on Linux too) |
| [`Ladle/`](Ladle/) | The app: SwiftUI and AppKit, the Molten design |
| [`Shared/`](Shared/) | Constants shared by the app and LadleBridge |
| [`LadleBridge/`](LadleBridge/) | Native messaging host for Chrome, Arc, Edge, Brave and Firefox (`Contents/MacOS/LadleBridge`) |
| [`SafariExtension/`](SafariExtension/) | The Safari Web Extension target: the shared web extension plus a native handler |
| [`BrowserExtension/`](BrowserExtension/) | One MV3 web extension for every browser, its build script and tests |
| [`LadleTests/`](LadleTests/) | Tests for the app target |
| [`scripts/`](scripts/) | Icon rendering, notarization and release-feed scripts |
| [`project.yml`](project.yml) | XcodeGen spec. The `.xcodeproj` is generated, never committed |

## Architecture

**LadleKit** does the work and knows nothing about windows:

- `Engine/FileDownloader` probes the server with `Range: bytes=0-`, splits the file into
  equal pieces (8 connections by default), writes each piece at its offset in a preallocated
  `<name>.ladle-part` file, and when a connection finishes early it takes over half of the
  biggest piece left. Resume state (pieces, ETag or Last-Modified and size) is saved at least
  every 2 seconds; a changed file on the server is never stitched onto old bytes. Servers that
  don't take ranges get one connection.
- `Engine/RetryPolicy`, `HostThrottle` and `TokenBucket`: retries with backoff and jitter
  (1, 2, 4, 8, 16 s), halving a host's connections on 429/503 and honoring `Retry-After`, and
  the global speed limit.
- `Engine/HLSDownloader` and `HLS/`: HLS playlists (master and media, `EXT-X-MAP`, byte ranges,
  `EXT-X-KEY`). fMP4 segments are joined into `.mp4`/`.m4a`, MPEG-TS into `.ts`; encrypted or
  live streams are refused with a clear reason.
- `Queue/DownloadCoordinator` (an actor) owns the list: the Main and Tonight queues, holds
  (sleep, no network, and battery and Low Data for Tonight only), duplicate names, checksums
  (pasted, from the browser, or a `<file>.sha256` next to the file), and persistence as JSON in
  `~/Library/Application Support/Ladle`.
- `Links/`: pasted text and numbered series (`ep-[01-12].mp3`), `ladle://add` links, `.webloc`
  files and clipboard rules. `Presentation/` turns items into every string and state the UI
  shows, so the copy is tested on Linux.
- Networking goes through the `HTTPTransport` protocol. `URLSessionTransport` uses one
  `URLSession` per connection slot so each piece gets its own TCP connection even over HTTP/2,
  and suspends tasks when a reader falls behind.

**The app** (`Ladle/`) is a thin layer on top: `AppModel` publishes the coordinator's snapshots
to SwiftUI. Windows are AppKit windows hosting SwiftUI (`AppDelegate`), so the main window can
have the glass sidebar under the traffic lights. Around the Mac: `MenuBarExtra` (window style),
Dock progress and badge, Finder progress on part files (`NSProgress` publishing), notifications
with Open and Show in Finder, the floating non-activating catch panel, `SMAppService` login item,
IOKit power and sleep, `NWPathMonitor` for Low Data Mode, and Sparkle 2 for updates
(`Updates/UpdateController`: background downloads, an in-window "Ladle X is ready" banner, install
on quit).

**Browser hand-offs** take one of three roads to the same `receive(_:)`:

1. Chrome, Arc, Edge, Brave, Firefox: the extension talks native messaging to `LadleBridge`
   (host `me.alirazakhan.ladle`), which starts Ladle in the background if needed and forwards
   each message over a local `CFMessagePort`. Replies and pushes ("Let the browser handle it",
   new settings) go back the same way.
2. Safari: `SafariWebExtensionHandler` answers the extension's `sendNativeMessage` and opens a
   `ladle://add` link carrying Ladle's token, so Ladle trusts it like the other browsers.
3. Anything else, or an extension that can't reach the helper: a plain `ladle://add` link.
   Ladle always asks before downloading one of these.

The app writes `browser-settings.json` (file types to catch, ask or not, folders, the token) to
its data folder, so the helper and the Safari handler can answer `hello` without starting Ladle.

## Building on a Mac

You need Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
cd app
xcodegen generate
open Ladle.xcodeproj
```

Run the **Ladle** scheme. Out of the box it signs to run locally, with no team needed. Two
things that come with that:

- Safari only loads extensions from signed apps. With a local build, turn on
  **Safari › Settings › Advanced › Show features for web developers**, then
  **Develop › Allow Unsigned Extensions**, and enable Ladle in **Safari › Settings › Extensions**.
- The Debug configuration has the hardened runtime off, because library validation refuses
  ad-hoc signed frameworks such as Sparkle. Release builds turn it on and are signed with
  Developer ID by the release workflow ([`RELEASING.md`](RELEASING.md)).

To sign with your own team, set `DEVELOPMENT_TEAM` and `CODE_SIGN_IDENTITY` ("Apple
Development") on the targets in Xcode, or pass them to `xcodebuild`.

## Tests

```sh
swift test --package-path app/LadleKit                    # the engine (macOS or Linux)

cd app && xcodegen generate && xcodebuild test \
  -project Ladle.xcodeproj -scheme Ladle -destination 'platform=macOS'   # the app target

cd app/BrowserExtension && npm ci
npm test                                                  # extension unit tests (Node)
npx playwright install chromium && npm run test:browser   # the built extension in Chromium

python3 -m unittest discover -s app/scripts -p 'test_*.py'   # release-feed script
```

LadleKit's tests run real segmented downloads against an in-memory server and a local HTTP
server (ranges, redirects, cookies staying with their host, the speed limit), plus the queue,
Tonight window, holds, HLS planning, checksums, link parsing and every UI string.
`.github/workflows/app-ci.yml` runs all of the above on each push that touches `app/`.

## The browser pieces

```sh
cd app/BrowserExtension
npm run build          # dist/chrome, dist/firefox, dist/safari and a .zip of each
npm run build:store    # the Chrome Web Store upload, without the development "key"
```

- **Chrome, Arc, Edge, Brave**: load `dist/chrome` unpacked. The `key` in
  `manifests/chrome.json` fixes the development ID to `pleopllngomokgfeebgjmnkjhebmcmkk`, which
  `Ladle/Browser/BrowserIntegration.swift` allows.
- **Firefox**: load `dist/firefox/manifest.json` from `about:debugging`. Its ID is
  `ladle@alirazakhan.me`.
- **Safari**: nothing to load; the Xcode build copies `src/` and `manifests/safari.json` into
  the Safari extension inside Ladle.app.

Clicking **Get extension** in **Settings › Browsers** writes the native messaging host manifest
(`me.alirazakhan.ladle.json`, pointing at `Ladle.app/Contents/MacOS/LadleBridge`) for every
installed Chromium browser, or for Firefox, then opens the setup page. Ladle rewrites them at
launch if the app has moved.

What the extension does: catches downloads of the watched types (cancels the browser's copy and
hands over the link, file name, page, size and that site's cookies), skips them when **⌥ Option**
is held, adds **Download with Ladle** and **Download All Links with Ladle…** to the context
menu, and puts a **Download video** pill on videos it can save (plain files and HLS, with a
quality menu; DRM-protected videos get "Protected video can't be saved"). Safari has no
downloads API, so there the content script takes clicks on links to watched files instead.

## Known gaps

- **Not compiled yet.** The app, LadleBridge and Safari extension targets were written without
  Xcode and have not been built; LadleKit and the extension are tested. Expect a first round of
  compile fixes on a Mac.
- Ladle can't wake a sleeping Mac. The Tonight queue starts at 1:00 AM only if the Mac is awake;
  while something downloads, Ladle keeps the Mac from idling to sleep.
- Live HLS streams aren't offered. A separate audio track is merged into the video for fMP4
  streams; with MPEG-TS it's saved next to the video as its own "<title> (audio)" file.
- Safari: only clicks on links are caught (not downloads started by scripts or forms), and only
  cookies visible to the page (`document.cookie`, not HttpOnly) are passed along.
- Downloads in private windows aren't caught unless the extension is allowed there. The
  extension only catches downloads while Ladle answers or has answered before, so without Ladle
  the browser downloads as usual.
- The Chrome Web Store, Edge Add-ons and AMO listings don't exist yet; their IDs need adding to
  `BrowserIntegration.swift` when they do ([`RELEASING.md`](RELEASING.md)).
- So links dropped on the Dock icon reach Ladle, it registers for `http` and `https`. That puts
  Ladle in macOS's list of possible default browsers; it never makes itself the default.
- The clipboard suggestion shows the file's name and site but not its size: Ladle doesn't contact
  a server until you choose Download.
- **Put the Mac to sleep** after Tonight uses `IOPMSleepSystem`, which hasn't been tried on a Mac.
- English only.
