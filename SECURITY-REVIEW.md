# Ladle security review

Date: 2026-11-01. Scope: everything in this repository at commit `2e1a89a`: the macOS app and
LadleKit engine, LadleBridge, the Safari extension, the browser extension, the install script,
the release and deploy workflows, the release scripts, and the website. Static review of the
source; nothing was run on a Mac. Severity is relative to Ladle's own threat model (a non-sandboxed,
ad-hoc-signed app that takes links from any web page and cookies from the browser).

## Status of the fixes

Every finding below has a fix on this branch. What each one changed, and what still needs a Mac:

| # | Fix | Needs checking on a Mac |
| --- | --- | --- |
| 1 | `app-release.yml`: the tagged commit must be on `main`; the `release` job runs in a `release` environment (add required reviewers in Settings › Environments and keep the key as its secret); the third-party Xcode action is gone (`xcode-select` picks the newest stable Xcode); tools are set up before the checkout; `RELEASING.md` documents the environment, a `v*` tag ruleset and key rotation | Create the environment's reviewers and the tag ruleset in the repository settings |
| 2 | `Limits.swift` bounds every size, offset, duration and segment count a playlist or server sends; `M3U8` refuses byte ranges that could overflow and treats absurd durations as unknown; `HLSJoin.estimatedSize` never converts an out-of-range Double; a download found running at three launches in a row is marked failed (`DownloadFailure.interrupted`) instead of started again | Swift tests cover it; `swift test --package-path app/LadleKit` runs on Linux in CI |
| 3 | Cookies are dropped from a download as soon as it finishes, scrubbed from finished items in older lists at load, and `JSONFileStore` writes 0600 files in a 0700 folder | No |
| 4 | `cookieHeader` in the extension drops `SameSite=Strict` cookies when the download's site differs from the page's (schemeful, registrable-domain match); every caller passes the page; unit tests added; Chromium tests pass | No |
| 5 | `install.sh` downloads the release's `sparkle.json`, checks the DMG's size and verifies its Ed25519 signature against the pinned `SUPublicEDKey` with a Perl implementation of RFC 8032 (Perl ships with macOS; no other dependency); App CI's dry run installs with a throwaway key and checks that a tampered DMG is refused | CI's packaging dry run exercises it on macOS |
| 6 | The CFMessagePort is replaced by a Unix socket (`bridge.sock`, 0600, in Ladle's data folder). The app verifies each connecting process against LadleBridge's designated requirement (`SecCodeCheckValidity`), and LadleBridge verifies the listener is the Ladle it belongs to before sending anything; an unverified peer's hand-offs are treated like a web page's | Yes: the browser hand-off path can only be tried in a real browser with a built app |
| 7 | `PartFile` and the HLS segment writer open with `O_NOFOLLOW` and refuse anything but a regular file; `nameIsTaken` uses `lstat`, so a dangling symlink counts as taken | No |
| 8 | `Content-Length` and `Content-Range` outside `0 … 1 PiB` are treated as unknown or invalid; `slotFractions` clamps the total; sizes from hand-offs are bounded | No |
| 9 | The extension's `ladle://` fallback carries no cookies; Safari's handler writes the request into `~/Library/Application Support/Ladle/Inbox/<uuid>.json` (its sandbox's one writable place in Ladle's data) and opens `ladle://inbox?id=…` with Ladle itself by path, so neither cookies nor a secret pass through the scheme; the trust token is gone | Yes, with a Developer ID build, since Safari won't load the extension otherwise |
| 10 | `receive` drops the checksum of an untrusted hand-off along with its cookies, referrer, source and size | No |
| 11 | `FileNaming.sanitize` removes zero-width and bidirectional formatting characters | No |
| 12 | `LADLE_HARDENED_RUNTIME=1` packages an ad-hoc build with the hardened runtime and the library-validation exception; off by default until tried on a Mac (`RELEASING.md`). The rest stays as documented: `NSAllowsArbitraryLoads` is needed for plain-http downloads, and sandboxing a download manager is out of scope | Yes: package with the variable, install, download, check for updates |

The Swift changes were written without a Mac and have not been compiled here; `app-ci.yml` builds
and tests them on macOS and Linux on push. Everything that could be run here was run: the extension's
unit and Chromium tests, the release scripts' Python tests, `bash -n` on every shell script, and the
Perl verifier against `sparkle_ed.py`'s signatures (valid, tampered, wrong key and short signature).

The earlier pre-launch fixes (commit `b48f4e8`, `fe4c072`) hold up: untrusted `ladle://` links lose
their cookies, referrer, source and size and always ask; cookies and referrer stay on the download's
origin across redirects; file names can't escape their folder; the video button needs trusted
events. The findings below are what is left.

## Summary

| # | Severity | Area | Finding |
| --- | --- | --- | --- |
| 1 | High | Release pipeline | A pushed `v*` tag releases any commit, bypassing `main`'s review requirement, and the release job runs an unpinned third-party action before it handles the Sparkle private key |
| 2 | Medium | HLS engine | A playlist can crash Ladle with integer overflow traps, and the crash repeats at every launch until the download list is deleted |
| 3 | Medium | Data at rest | Browser cookies (HttpOnly included) are saved in plain text in `downloads.json` and kept forever |
| 4 | Medium | Browser extension | Caught downloads are refetched with every cookie for the file's host, more than the browser itself would have sent (SameSite is not honored) |
| 5 | Medium | Install script | `install.sh` installs an unauthenticated binary and removes quarantine; the Sparkle signature it could check is ignored |
| 6 | Low | Local IPC | Any local process can impersonate the browser helper, squat Ladle's message port, or read the trust token |
| 7 | Low | File engine | Part files are opened without `O_NOFOLLOW`; a planted dangling symlink redirects download bytes elsewhere |
| 8 | Low | File engine | Server-sized values flow into arithmetic that traps on overflow (`slotFractions`, `overallProgress`) |
| 9 | Low | Hand-offs | Cookies and the trust token travel inside `ladle://` URLs, which any app can register to receive |
| 10 | Low | Hand-offs | A web page's own checksum earns the file a "Verified" badge |
| 11 | Low | File names | Unicode bidi controls survive sanitization, so a `.dmg` can display as a `.pdf` |
| 12 | Info | Platform | Ad-hoc signing, no hardened runtime, no sandbox, `NSAllowsArbitraryLoads` |

## Findings

### 1. Release pipeline: tag pushes bypass review, and the signing runner trusts a mutable action (High)

`.github/workflows/app-release.yml` runs on any `v*` tag push. The `check` job validates the
version string and the release notes, but never checks that the tagged commit is on `main`. Branch
protection on `main` requires pull requests (SPEC.md), yet anyone who can push a tag can have CI
build an arbitrary commit, sign it with `SPARKLE_ED_PRIVATE_KEY`, publish it as the latest release,
and every installed copy of Ladle installs it silently within a day (`SUAutomaticallyUpdate`). The
Sparkle key is the single root of trust for code execution on every user's Mac, so this is the
most valuable target in the repository.

Two things make it worse:

- The `release` job runs `maxim-lobanov/setup-xcode@v1` (a mutable tag of a third-party action)
  after checkout and before `package-app.sh`. A compromised release of that action can edit the
  checked-out scripts and read the key file the next step writes. `brew install xcodegen` runs
  unpinned on the same runner.
- The secret is a plain repository secret, so every run of this workflow can read it; there is no
  GitHub environment with required reviewers in front of it.

Fix:

- In `check`, after the full-history checkout, fail unless the commit is on `main`:
  `git merge-base --is-ancestor "$GITHUB_SHA" origin/main`. Also add a tag ruleset on GitHub so
  only release managers can create `v*` tags.
- Pin third-party actions to full commit SHAs (and let Dependabot bump them). Consider moving
  Sparkle signing into a job that uses only first-party actions, or at least run `setup-xcode`
  before checkout so it can't edit the scripts.
- Put the `release` job behind a GitHub environment (`release`) with required reviewers and store
  `SPARKLE_ED_PRIVATE_KEY` as an environment secret.

### 2. HLS playlists can crash Ladle, and the crash repeats on every launch (Medium)

Swift traps on integer overflow and on converting an out-of-range `Double` to `Int64`. Three
places in the HLS path feed server-supplied numbers into such arithmetic:

- `app/LadleKit/Sources/LadleKit/HLS/HLSJoin.swift:33` — `Int64(Double(bandwidth) * duration / 8)`.
  A media playlist line `#EXTINF:1e300,` (or `#EXTINF:inf,`; Swift's `Double(String)` accepts
  both) under a master playlist with any positive `BANDWIDTH` makes `totalDuration` enormous and
  the conversion traps. Reached from `HLSDownloader.mediaPlaylist(at:)` before any segment is fetched.
- `app/LadleKit/Sources/LadleKit/HLS/M3U8.swift:235` — `lastRangeEnd[uri] = offset + spec.length`
  traps on `#EXT-X-BYTERANGE:9223372036854775807@10`.
- `app/LadleKit/Sources/LadleKit/HLS/M3U8.swift:13` — `HLSByteRange.lastByte` (`offset + length - 1`)
  traps the same way for an `EXT-X-MAP` byte range, when the request for it is built.

The playlist comes from the video button (no prompt) or a `ladle://add?kind=hls&url=…` link (one
prompt). The item is already in `downloads.json` as queued when the crash happens, so the next
launch schedules it again and crashes again, and Ladle is a login item by default. Recovery means
deleting the file by hand.

Fix: parse durations with a finite, bounded check (`duration.isFinite && duration < 1e7`), use
`addingReportingOverflow`/`multipliedReportingOverflow` or Double math for byte ranges and reject
ranges whose end overflows, and cap `BANDWIDTH` and segment counts. In `DownloadCoordinator.start`,
consider marking an item that was `.downloading` at the previous crash as failed after N
consecutive launches so a bad download can't loop the app.

### 3. Cookies are stored in plain text, indefinitely (Medium)

The extension sends every cookie for the file's host (`chrome.cookies.getAll`, which includes
HttpOnly and SameSite=Strict cookies). `DownloadCoordinator.add` copies them into
`DownloadItem.cookies` (`app/LadleKit/Sources/LadleKit/Queue/DownloadCoordinator.swift:279`), and
`JSONFileStore` writes the list to `~/Library/Application Support/Ladle/downloads.json` with default
permissions. `complete()` never clears the field, and completed items stay in the list ("Completed
earlier"), so the file accumulates live session cookies for every site a download was caught from.
The browser keeps the same cookies encrypted with a Keychain-held key that prompts other apps; Ladle
makes them readable to any same-user process, backup, or sync agent with no prompt. The same file
also holds `referrer` and `userAgent`.

Fix: drop `cookies` (and `referrer`) from the item as soon as the download completes or is removed,
and never persist them for completed items. While a download is in flight, keep cookies in memory or
in the Keychain rather than the JSON file. Set 0600 on the files Ladle writes (`FileManager`
attributes or `open` with mode) as a cheap extra.

### 4. The extension gives Ladle more cookies than the browser would have used (Medium)

`cookiesFor(url)` in `app/BrowserExtension/src/background.js:208` returns every cookie for the URL,
and the caught download (`considerDownload`) or context-menu download is then refetched by Ladle with
that full `Cookie` header. The browser's own request would have applied SameSite: a cross-site
navigation to `https://app.example/export.pdf` sends only `SameSite=None` and `Lax` cookies, never
`Strict` ones. With "Always download .pdf files without asking" enabled, or once the user clicks
Download on the catch panel, an attacker page can make Ladle issue an authenticated GET to a
cross-site URL with cookies the browser would have withheld. The response goes to the user's disk,
not the attacker, so this is a CSRF-style side-effect risk rather than a data leak, but it does
weaken a protection sites rely on.

Fix: `chrome.cookies.getAll` returns `sameSite` for each cookie. When the download's site differs
from the referrer's site, keep only cookies with `sameSite === 'no_restriction'` (and `lax` for
top-level navigations, which is what a browser download is). Apply the same in `cookieHeader` in
`ladle-common.js`, with a unit test.

### 5. `install.sh` installs an unauthenticated binary without Gatekeeper (Medium)

`site/public/install.sh` downloads `Ladle.dmg` from the latest GitHub release, runs
`codesign --verify`, strips `com.apple.quarantine`, and opens the app. For an ad-hoc signature,
`codesign --verify` only proves the bundle matches a signature anyone can produce, so the only
authentication is TLS to `github.com`. A compromised release asset, GitHub account, or (for the
script itself) the Pages site or its DNS would install code on every machine that runs the one-liner,
with no Gatekeeper prompt. This is the documented trade-off of shipping without Developer ID, but the
script has a stronger check available: every release publishes `sparkle.json` with an Ed25519
signature over the DMG, and the public key is already fixed in `Info.plist`.

Fix: embed `SUPublicEDKey` in the script and verify `sparkle.json`'s `edSignature` over the DMG
before copying it (the same check `verify-package.sh` does with `sparkle_ed.py`). macOS ships
`python3` only with the developer tools, so either vendor a small verifier in the script or ship a
signed `install` helper; at minimum, pin the expected SHA-256 of each release in the script and keep
the script under version control review. Also say in the docs that the one-liner bypasses the
first-launch check on purpose.

### 6. Any local process can act as the browser helper (Low)

`BridgeServer` (`app/Ladle/Browser/BridgeServer.swift:32`) registers the CFMessagePort
`me.alirazakhan.Ladle.bridge` in the user's bootstrap namespace. CFMessagePort gives no sender
identity, so Ladle treats every message as if it came from LadleBridge: a same-user process can
start downloads with `mode: direct` (no catch panel) with its own URL, cookies, file name and user
agent, read the settings snapshot, and name a `replyPort` of its choosing to receive Ladle's
`browserDownload` pushes. A process that registers the name before Ladle starts receives every
browser hand-off, cookies included, because `LadleBridge.appIsListening()` only checks that the
port exists. The trust token in `browser-settings.json` is readable by the same processes.

A same-user attacker on macOS is mostly outside any app's control, but two consequences are specific
to Ladle: cookies become harvestable without the browser's Keychain prompt (see 3), and a process
without Downloads/Desktop/Documents TCC access can have Ladle write attacker-chosen bytes into those
folders (and open them, with "Open the file" set).

Fix: switch the app side to `NSXPCListener`/`xpc_connection` with an anonymous listener whose
endpoint LadleBridge gets from the app, or keep CFMessagePort but have Ladle verify the helper's
code identity through `SecCodeCopyGuestWithAttributes` on the PID the helper includes and a
requirement on the embedded `LadleBridge` cdhash. Treat bridge messages like untrusted links unless
that check passes.

### 7. Part files follow symlinks (Low)

`PartFile.init` (`app/LadleKit/Sources/LadleKit/Files/PartFile.swift:22`) opens
`<name>.ladle-part` with `O_RDWR | O_CREAT [| O_TRUNC]` and no `O_NOFOLLOW`, and
`Destination.nameIsTaken` uses `fileExists`, which returns false for a dangling symlink. A dangling
symlink `report.pdf.ladle-part -> ~/.ssh/authorized_keys` planted in the download folder is treated
as a free name, `open` follows it, and the download's bytes land in the link's target. The HLS
segment writer (`createFile` + `FileHandle`) behaves the same. Planting the link needs write access
to the download folder, which is the user's own unless they point Ladle at a shared, synced or
network folder, so this is a hardening item rather than a direct exploit.

Fix: add `O_NOFOLLOW` (and `O_EXCL` on a fresh start) to `open`, check with `lstat` rather than
`fileExists`, and refuse to continue if the part file is not a regular file owned by the user.

### 8. Server-supplied sizes reach trapping arithmetic (Low)

`PieceTable.slotFractions` (`app/LadleKit/Sources/LadleKit/Engine/PieceTable.swift:226`) computes
`total * k` for `k` up to the slot count, and `AppModel.overallProgress` sums `totalBytes` across
running downloads with `+`. Both trap when a server advertises a size above about 2^60 bytes.
Today the preallocation step usually fails with `ENOSPC` first and no piece table exists, so the
crash is hard to reach, but the guard is accidental. Also, a negative `Content-Length` or
`Content-Range` total is accepted into `totalBytes` and displayed.

Fix: reject totals outside `0 ... 1 << 50` (1 PiB) at `HTTPResponseHead.contentLength` and
`ContentRange.parse`, and do the UI math in `Double`.

### 9. Cookies and the trust token travel in `ladle://` URLs (Low)

`SafariWebExtensionHandler` and the extension's native-messaging fallback build
`ladle://add?…&cookies=…&token=…` and open it through LaunchServices or the browser's external
protocol handler. Any app that registers the `ladle` scheme can be chosen by LaunchServices to
receive these links, and URLs opened this way can end up in system logs. The Safari path is dormant
in current builds (unsigned), but the Chrome fallback is live whenever native messaging isn't set up.

Fix: don't put cookies in the fallback URL (let Ladle fetch without them and say so), and for Safari
prefer passing the hand-off through the shared `browser-settings` folder or an app-group file that
Ladle watches, with only an opaque id in the URL.

### 10. A page's own checksum earns a "Verified" badge (Low)

`LadleURL.parse` accepts `sha256`/`md5` from untrusted links with `source: .browser`, and the
coordinator verifies the file against it, so a malicious page can ship a payload plus its own hash
and the notification says "checksum verified". The badge reads as a safety signal but proves nothing
about the file.

Fix: drop the checksum from untrusted hand-offs in `AppModel.receive` (next to cookies and
referrer), or record a distinct `source: .webPage` and show "matches the checksum the page gave"
instead of "Verified".

### 11. Bidi control characters survive file-name sanitization (Low)

`FileNaming.sanitize` strips `CharacterSet.controlCharacters` (Cc) but not format characters (Cf)
such as U+202E RIGHT-TO-LEFT OVERRIDE. A name like `report\u{202E}fdp.dmg` renders as
`reportgmd.pdf` in the catch panel, the list and Finder while its real extension is `dmg`.
Quarantine still applies when the file is opened, so this is a social-engineering aid only.

Fix: also remove U+200B–U+200F, U+202A–U+202E and U+2066–U+2069 in `sanitize`, and show the
extension badge from the sanitized name (it already does).

### 12. Platform posture (Informational)

- Releases are ad-hoc signed with the hardened runtime off (`package-app.sh`), so there is no
  library validation: any same-user process can inject into Ladle with `DYLD_INSERT_LIBRARIES` and
  inherit its TCC grants. The Safari extension is sandboxed; the app and LadleBridge are not.
- `NSAllowsArbitraryLoads` is on for plain-http downloads. Certificate validation is unaffected,
  but there is no per-connection minimum TLS version. Fine for a download manager; keep Sparkle's
  feed and the website on HTTPS, which they are.
- The HLS merge runs AVFoundation on untrusted media inside the app process. Apple's parsers are
  hardened, but if sandboxing ever becomes possible, the merge is the first thing to move out.
- `SUAutomaticallyUpdate` means the Sparkle private key is a silent-code-execution key for every
  user. Keep the backup offline and rotate it if finding 1 is ever exercised.
- No analytics, no third-party scripts and no cookies on the website were found; the search and
  feedback components render results with `textContent`. The `set:html` uses take page front matter
  only. `npm audit` reports no known vulnerabilities in either lockfile.

## What was checked and looks right

- `ladle://` links without the token: cookies, referrer, source and size dropped; always asks;
  no server contact before Download; the panel shows the real address.
- Redirects: cookies and `Referer` only on the download's own scheme, host and port; `Referer`
  shrinks to the origin elsewhere; at most 10 redirects; only `http`/`https` leave the transport.
- File placement: names can't contain `/`, `:` or `\`, can't start with a dot, can't collapse to
  `..`; `isDirectlyInside` and `isReplaceableFile` prevent replacing folders or anything outside
  the target folder; replaced files go to the Trash.
- `LSFileQuarantineEnabled` is set, so downloaded apps, packages, scripts and `.terminal` files
  get the Gatekeeper prompt when opened, including with "Open the file" on.
- Content-Range and ETag are checked on every piece; a changed file is never stitched onto old
  bytes; playlists and sidecars are size-capped.
- The video button only acts on trusted events and user activation, and inspects other origins'
  streams without cookies.
- The Chrome extension's native host manifest is restricted to one extension id; the token never
  goes to Chrome-family browsers; the Sparkle package is pinned to an exact version; the release
  checkout has no persisted credentials; the private key is written with `umask 077` and removed.
- Workflows use `pull_request`, not `pull_request_target`, with `contents: read` by default.
