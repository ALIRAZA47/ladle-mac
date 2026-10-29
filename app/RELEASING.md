# Releasing Ladle

Releases are made by [`.github/workflows/app-release.yml`](../.github/workflows/app-release.yml)
when a tag like `v1.2.0` is pushed. They need no paid Apple Developer account: Ladle is signed ad
hoc and isn't notarized, so people approve it once, the first time they open it
([how](https://ladle.alirazakhan.me/docs/getting-started/install/#first-launch)). Updates work all
the same: each one is signed with Sparkle's EdDSA key, and Ladle installs only updates signed with
that key. This page has the one-time setup and the steps for each release. Signing with Developer
ID is optional, for [later](#later-developer-id-and-notarization).

## One-time setup: Sparkle's keys

The setup is one key pair and one secret.

1. Get Sparkle's tools: download a Sparkle 2 release from
   <https://github.com/sparkle-project/Sparkle/releases> and open its `bin/` folder (or, after
   building Ladle once in Xcode, right-click **Sparkle** under Package Dependencies › Show in
   Finder and go to `../artifacts/sparkle/Sparkle/bin/`).
2. Run `./generate_keys`. It keeps the private key in your login keychain and prints the
   public key.
3. Put the public key in `SUPublicEDKey` in [`Ladle/Info.plist`](Ladle/Info.plist) and merge that
   to `main`. (Ladle's key is already there.)
4. Export the private key: `./generate_keys -x sparkle_private_key.txt`. In the repository's
   **Settings › Secrets and variables › Actions**, save the file's contents as the secret
   `SPARKLE_ED_PRIVATE_KEY`, then delete the file.
5. Keep a backup of the private key somewhere safe, and keep using the same keys. A copy of Ladle
   signed ad hoc takes an update only when it's signed with the key that copy already has, so if
   the key is lost or changed, people have to download the next version by hand.

The release workflow checks the keys before it builds anything. It stops while `SUPublicEDKey`
is the placeholder, while the secret is missing, and when the secret isn't the private half of
`SUPublicEDKey`.

## Each release

1. Write the release notes in `site/src/content/changelog/X.Y.Z.md` and merge them to `main`:

   ```markdown
   ---
   version: X.Y.Z
   title: A few words
   ---

   What changed, for people who use Ladle.
   ```

   Leave out `date:`; the website fills in the day the release was published.
2. Start the release, either way:
   - **On GitHub:** **Actions › App release › Run workflow**. Leave the branch on `main`, enter the
     version (`1.2.0`) and click **Run workflow**. The release tags that commit `v1.2.0` when it's
     published, so a run that fails leaves no tag behind.
   - **With git:** tag the commit on `main` and push the tag.

     ```sh
     git tag v1.2.0
     git push origin v1.2.0
     ```

   Versions go up: the build number (`CFBundleVersion`, which Sparkle compares) is the tag's place
   among all release tags, so `v0.1.0` is build 1. A run from the Actions tab refuses a version
   that isn't newer than the last release.

3. Watch **Actions › App release**. It:
   1. checks the tag, that the release notes exist and match it, and Sparkle's keys, and stops
      there if anything is missing;
   2. builds Ladle `X.Y.Z` for Apple silicon and Intel with
      [`scripts/package-app.sh`](scripts/package-app.sh), signs it ad hoc from the inside out
      (Sparkle's helpers, LadleBridge and the Safari extension, then the app), makes `Ladle.dmg`
      with an Applications link, signs the DMG for Sparkle, and packages the Chrome extension;
   3. checks the result with [`scripts/verify-package.sh`](scripts/verify-package.sh), which
      mounts the DMG and checks the signatures, the versions, LadleBridge, the extension's ID and
      the update's signature against the app's `SUPublicEDKey`;
   4. publishes the GitHub Release **Ladle X.Y.Z** with the release notes, a line pointing to the
      first-launch help, and three files:
      - `Ladle.dmg`, which `https://github.com/ALIRAZA47/ladle-mac/releases/latest/download/Ladle.dmg`
        then serves;
      - `Ladle-Chrome-Extension.zip`, the Chrome extension to load unpacked
        ([below](#browser-extensions));
      - `sparkle.json`, the DMG's EdDSA signature and size, which the update feed is made from;
   5. starts **Site deploy** on `main`.

Every run of Site deploy, including the one a release starts, builds the update feed
(`appcast.xml`) from the published releases. The feed lists the newest 10 releases that have
`Ladle.dmg` and `sparkle.json`, leaving out drafts and pre-releases, and links each one's notes at
`https://ladle.alirazakhan.me/changelog/#vX-Y-Z`. The same step dates release notes that have no
`date:`. None of this is committed; it's only in the deployed site.

Copies of Ladle check the feed once a day, download the update in the background and offer
**Restart to Update**; otherwise it installs when Ladle quits.

### If something fails

- **App release**: fix what the error says, then re-run the failed jobs (**Re-run jobs › Re-run
  failed jobs** on the run). Publishing can run again: it replaces the release's files. A secret
  takes effect on the re-run, but a fix in the repository, like the release notes or the public
  key, has to be in the released commit. Merge it, then run **App release** from the Actions tab
  again with the same version (a run by hand creates the tag only when it publishes). If you
  pushed a tag, move it to the fix before the release is published, which starts a new run:

  ```sh
  git fetch origin
  git tag -f vX.Y.Z origin/main
  git push -f origin vX.Y.Z
  ```
- **The feed or the website**: run **Actions › Site deploy › Run workflow** on `main`. It rebuilds
  the feed from the releases, so running it again is always safe. When it can't list the releases
  or download a `sparkle.json`, it fails rather than publish an empty feed.
- **A bad release**: mark it as a pre-release (or delete it) and run Site deploy, so the feed goes
  back to the version before. Copies that already took the bad one keep it until a fixed, higher
  version comes out.

## Browser extensions

The Safari extension ships inside Ladle.app, but Safari only loads extensions from apps signed by
a registered Apple developer, so it needs the
[Developer ID build](#later-developer-id-and-notarization). Until then, Settings › Browsers says so
and links to the docs.

Each release carries `Ladle-Chrome-Extension.zip`: the Chrome extension with its development key,
which gives it the ID Ladle allows. Unzipped, it's a folder for **Load unpacked** (Developer mode)
in Chrome, Arc, Edge and Brave. `node build.mjs --release` in
[`BrowserExtension/`](BrowserExtension/) makes the same zip.

For the stores, package with `npm run build` in [`BrowserExtension/`](BrowserExtension/):

- **Chrome Web Store** (also covers Arc and Brave): upload `dist/ladle-chrome-X.Y.Z-store.zip` from
  `npm run build:store`, which leaves out the development `key`. The store assigns a new ID.
- **Microsoft Edge Add-ons**: upload the same zip; Edge assigns its own ID.
- **Firefox Add-ons (AMO)**: upload `dist/ladle-firefox-X.Y.Z.zip`. The ID stays
  `ladle@alirazakhan.me`, set in `manifests/firefox.json`.

When a store assigns an ID, add it to `chromeExtensionIDs` (or `firefoxExtensionIDs`) in
[`Ladle/Browser/BrowserIntegration.swift`](Ladle/Browser/BrowserIntegration.swift). Ladle writes
those IDs into the native messaging host manifests (`allowed_origins` for Chromium browsers,
`allowed_extensions` for Firefox), and rewrites the manifests at launch, so the next release
lets the store builds talk to LadleBridge. Then update the store links in the docs.

## Later: Developer ID and notarization

With a membership in the Apple Developer Program, releases can be signed with Developer ID and
notarized. Then nobody has to approve the first launch, and the Safari extension works. The
workflow switches on its own once all six secrets below exist (with only some of them, it warns
and signs ad hoc). It then signs with the hardened runtime and a secure timestamp, notarizes and
staples the app and the DMG, and leaves the first-launch line out of the release notes. Keep
Sparkle's keys as they are: copies signed ad hoc take the first Developer ID release as an
ordinary update, checked with the same EdDSA key.

### 1. Developer ID certificate

1. In [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/certificates/list),
   create a **Developer ID Application** certificate (or use the one you have).
2. In Keychain Access, export it with its private key as a `.p12` with a password.
3. `base64 -i DeveloperID.p12 | pbcopy` and save it as the secret `DEVELOPER_ID_CERT_P12_BASE64`.
4. Save the export password as `DEVELOPER_ID_CERT_PASSWORD`, and your 10-character team ID
   (Membership details on developer.apple.com) as `APPLE_TEAM_ID`.

### 2. Notarization key

1. In [App Store Connect › Users and Access › Integrations](https://appstoreconnect.apple.com/access/integrations/api),
   create a Team key with the **Developer** role and download `AuthKey_XXXXXXXXXX.p8`
   (you can download it only once).
2. `base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy` → secret `ASC_API_KEY_P8_BASE64`.
3. The key's ID → `ASC_API_KEY_ID`; the Issuer ID shown above the keys → `ASC_API_ISSUER_ID`.

### 3. The secrets

| Secret | What |
| --- | --- |
| `DEVELOPER_ID_CERT_P12_BASE64` | Developer ID Application certificate and key, `.p12`, base64 |
| `DEVELOPER_ID_CERT_PASSWORD` | The `.p12` password |
| `APPLE_TEAM_ID` | Your team ID |
| `ASC_API_KEY_P8_BASE64` | App Store Connect API key, `.p8`, base64 |
| `ASC_API_KEY_ID` | That key's ID |
| `ASC_API_ISSUER_ID` | Its issuer ID |

If notarization fails, Apple's log is printed in the step. Most often a nested binary isn't
signed with the hardened runtime.
