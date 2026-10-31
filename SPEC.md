# Ladle — product spec and shared contract

This file is the single source of truth for what Ladle does. The app (`app/`) and the
website (`site/`) are built from it in parallel, so anything both sides depend on —
names, URLs, settings, shortcuts, behavior — is fixed here. Change it here first.

## What Ladle is

A free download manager for the Mac. It splits each file into several connections,
catches downloads from the browser, saves videos you're allowed to save, queues big
files for the night, sorts everything into folders, and updates itself.

- **Free.** No price, trial, license key, account, or checkout anywhere — app or site.
- **Private.** No account, analytics, telemetry, or tracking. See [Privacy](#privacy).
- **Native.** Swift + SwiftUI/AppKit, macOS 14 Sonoma or later, universal (Apple silicon + Intel).

## Repository layout

| Path | What | Owner |
| --- | --- | --- |
| `README.md`, `SPEC.md` | Overview and this spec | lead |
| `site/public/install.sh` | The install script (see [First launch](#first-launch)) | lead |
| `app/` | The macOS app, its browser extensions and native messaging helper | app |
| `site/` | Website and docs (Astro + Starlight) | site |
| `.github/workflows/app-*.yml` | App CI and releases | app |
| `.github/workflows/site-*.yml` | Site CI and deploy | site |

Each side edits only its own paths. The one shared piece is the update feed: the site commits
an empty `site/public/appcast.xml`, and the feed step in `site-deploy.yml` (owned by the app side)
rebuilds it from the published releases before every deploy.

## Identity

| Thing | Value |
| --- | --- |
| Name / tagline | Ladle — "Downloads, poured fast." |
| Bundle ID | `me.alirazakhan.Ladle` |
| Safari extension bundle ID | `me.alirazakhan.Ladle.SafariExtension` |
| Native messaging host (Chrome, Firefox) | `me.alirazakhan.ladle` |
| URL scheme | `ladle://` |
| App data folder | `~/Library/Application Support/Ladle` (download list, resume state, settings) |
| Version | 0.1.1 (build 2) |
| Minimum macOS | 14.0 |
| Distribution | `Ladle.dmg` on GitHub Releases, **ad-hoc signed and not notarized** (no paid Apple Developer account). Users approve the first launch once (see [First launch](#first-launch)). If Developer ID secrets are ever added, the release workflow signs and notarizes instead. Not sandboxed. Not on the Mac App Store. |

## URLs

Both sides hard-code these. Don't change one side without the other.

| What | URL |
| --- | --- |
| Website | `https://ladle.alirazakhan.me/` |
| Download page | `https://ladle.alirazakhan.me/download/` |
| Latest DMG | `https://github.com/ALIRAZA47/ladle-mac/releases/latest/download/Ladle.dmg` |
| Latest Chrome extension (until it's in the Chrome Web Store) | `https://github.com/ALIRAZA47/ladle-mac/releases/latest/download/Ladle-Chrome-Extension.zip` |
| Update feed (Sparkle appcast) | `https://ladle.alirazakhan.me/appcast.xml` (file: `site/public/appcast.xml`) |
| Install script | `https://ladle.alirazakhan.me/install.sh` (file: `site/public/install.sh`) |
| Release notes | `https://ladle.alirazakhan.me/changelog/` — one section per version, anchor `#v1-0-0` style (`v` + version with dots as dashes) |
| Docs | `https://ladle.alirazakhan.me/docs/` |
| Privacy | `https://ladle.alirazakhan.me/privacy/` |
| Support | `https://github.com/ALIRAZA47/ladle-mac/issues` |

### Docs pages the app links to

The site must publish every one of these; the app opens them from Help and Settings.

```
/docs/getting-started/install/                    anchors: #first-launch #install-from-terminal
/docs/getting-started/set-up-your-browser/        anchors: #safari #chrome #firefox
/docs/getting-started/first-download/
/docs/getting-started/menu-bar-dock-and-notifications/
/docs/adding-downloads/paste-drop-or-shortcut/
/docs/adding-downloads/many-links/
/docs/adding-downloads/video-button/
/docs/queues-and-speed/main-queue/
/docs/queues-and-speed/tonight-queue/
/docs/queues-and-speed/connections-and-speed-limits/
/docs/files-and-folders/categories-and-folders/
/docs/files-and-folders/duplicate-file-names/
/docs/files-and-folders/checksums/
/docs/fixing-problems/download-failed/
/docs/fixing-problems/wont-resume/
/docs/fixing-problems/browser-not-handing-off/
/docs/updates/
/docs/reference/keyboard-shortcuts/
/docs/reference/settings/
```

Browser extensions aren't in the Chrome Web Store or Firefox Add-ons yet. In the app,
"Get extension" opens the matching anchor on `set-up-your-browser`; that page holds the
store links once they exist.

## First launch

Release builds are ad-hoc signed, not notarized, so macOS asks once before Ladle first opens:

- **macOS 15 Sequoia and later**: open Ladle; macOS says it can't verify it — click **Done**.
  Open **System Settings › Privacy & Security**, scroll to **Security**, click **Open Anyway**
  next to "Ladle was blocked…". macOS warns once more: click **Open Anyway** there too, then
  confirm with your password or Touch ID.
- **macOS 14 Sonoma**: Control-click **Ladle** in Applications, choose **Open**, then **Open** again.

It's needed once. Updates install without asking again, because they're downloaded by Ladle
and checked against Ladle's own update key.

**Safari** only loads extensions from apps signed by a registered Apple developer, so the Safari
extension can't run in these builds. Settings › Browsers says so and links to the docs. Chrome,
Arc, Edge and Brave can use `Ladle-Chrome-Extension.zip` from the latest release in developer
mode until the Chrome Web Store listing exists; Firefox waits for its Firefox Add-ons listing.

**Install script.** `curl -fsSL https://ladle.alirazakhan.me/install.sh | bash` installs the
latest release without the approval step, because files `curl` downloads aren't quarantined.
It runs on the Bash that ships with macOS, and does the following:

1. Downloads `Ladle.dmg` and skips the app if that version is already installed. If Ladle is open,
   it waits for you to quit it.
2. Copies the app into `/Applications` (`~/Applications` when the account can't write there),
   checks its signature, then opens it.
3. Unpacks `Ladle-Chrome-Extension.zip` into
   `~/Library/Application Support/Ladle/Ladle-Chrome-Extension`, always the same folder, so a
   reload in the browser picks up a new version.
4. Copies that path to the clipboard and opens the browser's extensions page for **Load unpacked**.

Options: `--app-only`, `--extension-only`, `--browser chrome|arc|dia|edge|brave|none`,
`--dir FOLDER`, `--no-open`. When the Chrome Web Store listing exists, set `CHROME_STORE_URL` in
the script, and it opens the store instead. App CI runs the script on macOS against the packaged
app on every run of its packaging dry run.

## Look: Molten

The approved design is the **Molten** look, made modern: frosted-glass panels over a soft
molten glow, rounded corners, pill-shaped controls. Dark first, with a full light theme.

| Token | Dark | Light |
| --- | --- | --- |
| Window background | `#0C0B0A` + soft orange glow top-left, ember glow bottom-right | `#F3EFE9` + same glows, weaker |
| Glass panel | `rgba(30,28,26,0.58)` + blur 28 + 1px `rgba(255,240,220,0.09)` border + top highlight | `rgba(255,255,255,0.6)` |
| Text / secondary / tertiary | `#F6F2EC` / `#B8B0A6` / `#9C9489` | `#1A1714` / `#554E46` / `#675F57` |
| Accent (Molten) | `#FF8A1F` | `#FF8A1F` fills, `#B4500E` text |
| Accent text on fills | `#1E1206` | `#1E1206` |
| Accent text on orange tints | `#FF9A3D` | `#9C440B` (`#B4500E` drops below 4.5:1 there) |
| Pour gradient (progress) | `#FF4F1A` → `#FF8A1F` → `#FFC46B` | same |
| Finished (Steel) | `#C9CDD3` | `#7B8491` |
| Danger | `#FF6B5E` | `#C4321F` |

- Type: SF Pro (UI), SF Pro Rounded (speeds and numbers), Bricolage Grotesque (wordmark,
  website headings), Inter (website body).
- Radii: window 22, panels 20–24, rows 18, buttons and inputs fully rounded (pills).
- Progress: each download's bar is split into one segment per connection; segments glow
  while pouring, dim when paused, turn into one steel bar when finished. The details panel
  shows a **connection ring** — one arc per connection.
- App icon: a molten arrow pouring into a steel ladle on a graphite squircle.

## Features (v1)

The app must behave like this and the docs must describe exactly this.

### Adding downloads

- **Link bar** at the top of the main window: pasting a link shows the file's name, size and
  destination with **Download now** and **More options** (opens the Add sheet with the link
  filled in, to pick a folder or start it tonight). Typing anything else searches the list.
  `⌘K` focuses it.
- **Add sheet** (`⌘N` or the **+** button): one link, or many links, one per line.
  A numbered series like `ep-[01-12].mp3` or `img[1-20].jpg` expands to every number; zero
  padding is kept. Links already downloaded are listed but unchecked ("Already downloaded").
  Choose **Start: Now** or **Tonight, 1:00 AM**.
- **Clipboard**: when Ladle is frontmost or its menu bar menu opens, and the clipboard holds a
  link to a file with a known extension, show "Link on your clipboard" with **Download** and
  **Not now**. Setting: *Watch the clipboard for links* (on). Nothing leaves the Mac.
- **Drag and drop** links onto the window, and `.webloc` files onto the window or the Dock icon.
  Ladle doesn't register for `http`/`https`, so it never shows up as a possible default browser.
- **URL scheme**: `ladle://add?url=<percent-encoded>&referrer=<…>&filename=<…>&cookies=<…>`.
  The extension and the bridge may also pass `size`, `mime`, `sha256` or `md5`, `source`,
  `mode` (`caught`, `direct` or `choose`), `kind`, `audio`, `title`, `quality`, `bandwidth` and `token`.
  A link without Ladle's own `token` may come from any web page, so Ladle ignores its `cookies`,
  `referrer`, `source` and `size`, always asks first (whatever `mode` says), contacts no server
  before the person chooses Download, and shows the file's real address on the panel, titled
  "A web page asked Ladle to download".
- The **clipboard suggestion** shows the file's name and site but not its size: Ladle contacts
  no server until you choose Download.
- The extension's **toolbar button** runs Download All Links with Ladle; its badge counts the
  page's file links.
- **Browser hand-off**: the extension catches downloads of watched file types and Ladle shows
  the catch panel — **Download**, **Later** (adds it to the list without starting it),
  **Let the browser handle it**, and "Always download .<ext> files without asking" (for browser
  catches only; a web page's link never gets that toggle). Setting: *Ask before downloading* (on). Holding **⌥ Option** while clicking a link lets the
  browser download it instead, that once.
- Context menu items: **Download with Ladle**, and **Download All Links with Ladle…**, which
  opens the Add sheet listing the page's file links, checked, to choose from.

### The engine

- Splits each file into *N* pieces (*Connections per download*, default 8, range 1–32) using
  HTTP `Range` requests. Falls back to one connection when the server doesn't return `206`
  for a range probe or the size is unknown.
- **Dynamic splitting**: when a connection finishes early it takes over the second half of the
  largest remaining piece (minimum piece 1 MiB).
- Writes pieces straight into `<name>.ladle-part` in the destination folder (preallocated),
  renamed to the final name when complete. Finder shows its progress.
- **Resume**: piece offsets are saved at least every 2 seconds and on pause/quit/sleep.
  Downloads resume after relaunch, sleep or a network change if the server supports ranges
  and the validator (ETag, else Last-Modified + size) still matches; otherwise Ladle asks
  before starting over.
- **Retries**: failed pieces retry with backoff (1, 2, 4, 8, 16 s with jitter). Setting
  *Retry failed downloads*: Never, 1, 3 (default), 5, 10 times. On `429`/`503` Ladle halves the
  connections it uses for that host and honors `Retry-After` (up to an hour) — "backs off when a
  server asks it to". The host gets its full connections back after 10 quiet minutes.
- **Speed limit**: one global limit across all downloads (*Limit total speed*, off; choices 1, 2,
  5, 10 (default), 25 and 50 MB/s). *Proxy*: **Same as macOS** (default) or **Don't use a proxy**.
- While anything is downloading, Ladle keeps the Mac from going to sleep on its own.
- **Cookies and referrer** from the browser are sent only to the download's own origin (scheme,
  host and port), so never again after a redirect to plain http or to another port. Any other
  host gets the referrer's origin alone ("https://site.example/"), as browsers send it.

### Queues

- **Main queue**: runs *Downloads at the same time* (default 3, range 1–8); the rest wait in line.
- **Pause All** also pauses waiting downloads; **Resume All** also starts ones set aside with Later.
- The list groups downloads as Downloading, Paused, Up next, Needs attention, Completed today
  (collapsible) and Completed earlier.
- **Tonight**: starts at 1:00 AM, stops at 7:00 AM (unfinished items wait for the next night),
  runs every day by default. *When the queue finishes*: **Do nothing** or **Put the Mac to sleep**
  (default).
- *Pause when running on battery* (on) and *Pause on Low Data networks* (on, macOS Low Data Mode)
  apply to the **Tonight queue only**: they hold it and let it carry on by itself once the Mac
  is plugged in or on a regular network. Downloads you start yourself always run.

### Files and folders

- Saved to *Save downloads to* (default `~/Downloads/Ladle`). With *Sort into category folders*
  (on), files go to a subfolder by type:

  | Category | Extensions |
  | --- | --- |
  | Video | mp4 mov mkv webm avi m4v ts |
  | Music | mp3 flac wav m4a aac ogg |
  | Documents | pdf epub doc docx txt pages key xlsx csv |
  | Archives | zip rar 7z tar gz tgz bz2 xz |
  | Apps | dmg pkg iso app |
  | Images | png jpg jpeg heic webp gif svg tiff |
  | Anything else | the base folder |

- *If a file with the same name exists*: **Keep both** (default — adds " 2", " 3"…),
  **Replace**, **Ask**.
- *When a download finishes*: **Just notify me** (default), **Open the file**, **Show in Finder**.
- **Checksums** (*Verify checksums*, on): when a SHA-256 or MD5 is known, Ladle verifies the file
  and marks it **Verified** or warns that it doesn't match. Ways it's known: pasted on the same
  line after the link, separated by a space — the hex digest, optionally prefixed `sha256:` or
  `md5:` (64 hex characters = SHA-256, 32 = MD5); passed by the extension; or published as
  `<file>.sha256` next to the file.

### Video button

- The extension adds a **Download video** pill to `<video>` elements playing a direct media
  file (mp4, webm, mov) or an unencrypted HLS stream. The menu lists qualities from the HLS
  master playlist (resolution, estimated size when known) and **Audio only** when present.
- Never saves protected video: any `EXT-X-KEY` with a method other than `NONE`, or a page using
  Encrypted Media Extensions, shows a disabled pill: "Protected video can't be saved".
  No site-specific extractors.
- The pill reacts only to the person's own pointer and clicks, never to a page's script. A
  stream is looked at with the browser's cookies only when it comes from the page's own origin;
  a stream from another origin is looked at without cookies (and only if the page itself loaded
  it), so a page can learn nothing about the person's accounts elsewhere. If that cookie-less
  look fails, the pill still offers "Download video", and Ladle picks the best quality itself,
  with cookies, once the person clicks.
- HLS with fMP4 segments is joined into `.mp4`; MPEG-TS segments are saved as `.ts`.

### Around the Mac

- **Menu bar** (*Show Ladle in the menu bar*, on): total speed, clipboard suggestion,
  downloading list, up next, *Limit speed* switch, **Open Ladle**.
- **Dock**: overall progress bar on the icon and a badge with the number downloading.
- **Notifications** when downloads finish (*Notify me when downloads finish*, on;
  *Play a sound too*, off) with **Open** and **Show in Finder**.

### Updates

Ladle updates itself with Sparkle 2.

- Sparkle 2 via Swift Package Manager (`https://github.com/sparkle-project/Sparkle`, 2.6 or later).
- Info.plist: `SUFeedURL` = the appcast URL above; `SUPublicEDKey` = the owner's Sparkle public key
  (`KHEwBrneF/Lth44nE+Tr7rTvjAJ1g4513i5UQmPPFoQ=`); `SUEnableAutomaticChecks` = YES;
  `SUAutomaticallyUpdate` = YES; `SUScheduledCheckInterval` = 86400; system profiling off.
- Updates are verified with that EdDSA key, so they work without any Apple signing.
- **Seamless**: updates download in the background. A banner in the main window says
  "Ladle 1.1 is ready" with **Restart to Update** and **Later**; if not restarted, the update
  installs when Ladle quits. If downloads are running, **Restart to Update** warns that they'll
  pause and resume after the restart.
- App menu: **Check for Updates…**. Settings has an **Updates** tab.
- Each appcast item's `sparkle:releaseNotesLink` points to the changelog anchor for that version.

**Release flow.** Before tagging `vX.Y.Z`, the owner writes the release notes in
`site/src/content/changelog/X.Y.Z.md` (front matter: `version`, `title`, optional `date`). The
app's release workflow, on the tag:

1. fails early if that changelog file is missing (tag versions in increasing order: the build
   number is the tag's position among release tags);
2. builds a universal app, ad-hoc signs it (or signs and notarizes it with Developer ID when those
   secrets exist), signs the update with `SPARKLE_ED_PRIVATE_KEY` (the one required secret), and
   publishes a normal (not pre-) GitHub Release with the version-less assets `Ladle.dmg` and
   `Ladle-Chrome-Extension.zip`, so the `releases/latest/download/…` links always work, plus
   `sparkle.json` (`version`, `build`, `edSignature`, `length`, `minimumSystemVersion`) for the feed;
3. starts `.github/workflows/site-deploy.yml` on `main` with `gh workflow run` (that job needs
   `actions: write`). A push made with the default `GITHUB_TOKEN` doesn't start other workflows,
   but a `workflow_dispatch` does, and because the deploy runs on `main`, the `github-pages`
   environment needs no extra rule for tags.

The workflow never commits: `main` requires pull requests, and the workflow's token can't bypass
that. Instead, every site deploy rebuilds `site/public/appcast.xml` from the published releases
(newest first, the last 10, each enclosure pointing at `releases/download/vX.Y.Z/Ladle.dmg`) and
fills in a missing changelog `date` with the release day, in its own checkout only, before it
builds the site. If GitHub can't be reached, the deploy fails rather than publishing an empty feed.
With no releases yet, the feed is an empty channel.

### Settings

| Tab | Settings (defaults) |
| --- | --- |
| General | Open Ladle at login (on) · Show Ladle in the menu bar (on) · Watch the clipboard for links (on) · Appearance: Auto/Light/Dark (Auto) · Notify me when downloads finish (on) · Play a sound too (off) |
| Downloads | Save downloads to (`~/Downloads/Ladle`) · Sort into category folders (on) · If a file with the same name exists (Keep both) · When a download finishes (Just notify me) · Verify checksums (on) |
| Speed | Downloads at the same time (3) · Connections per download (8, "recommended") · Limit total speed (off, 10 MB/s) · Retry failed downloads (3 times) · Proxy (Same as macOS) |
| Browsers | Safari (status, Manage) · Chrome, Arc, Dia, Edge and Brave (Get extension) · Firefox (Get extension) · Everything else (copy a link) · Catch these file types (dmg pkg zip iso mp4 mov mkv mp3 flac pdf, editable) · Ask before downloading (on) |
| Schedule | Tonight queue 1:00 AM to 7:00 AM · Run on (every day) · When the queue finishes (Put the Mac to sleep) · Pause when running on battery (on) · Pause on Low Data networks (on) |
| Updates | Check for updates automatically (on) · Download and install updates automatically (on) · Current version with **Check Now** · Last checked |

### Keyboard shortcuts

| Keys | Action |
| --- | --- |
| `⌘N` | Add downloads |
| `⌘K` | Paste a link or search |
| `Space` | Pause or resume the selected download |
| `⌥⌘P` | Pause or resume all |
| `⌘R` | Retry the selected download |
| `⌘O` | Open the selected file |
| `⇧⌘R` | Show in Finder |
| `⌘⌫` | Remove from list (the file stays) |
| `⌘,` | Settings |

## Privacy

- The app sends nothing about you anywhere. Its only network traffic is the downloads you start
  and Sparkle's daily update check (app and macOS version only).
- Download history stays on the Mac (Application Support). Clipboard contents are read locally
  and never sent.
- The website uses no cookies and no analytics.
