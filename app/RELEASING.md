# Releasing Ladle

Releases are made by [`.github/workflows/app-release.yml`](../.github/workflows/app-release.yml)
when a tag like `v1.2.0` is pushed. It builds a universal app, signs it with Developer ID,
notarizes it, publishes `Ladle.dmg` to the GitHub Release, adds the update to Sparkle's feed and
deploys the website. This page has the one-time setup and the steps for each release.

## One-time setup

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

### 3. Sparkle signing keys

Every update is signed with an EdDSA key, and Ladle only installs updates signed with it.

1. Get Sparkle's tools: download a Sparkle 2 release from
   <https://github.com/sparkle-project/Sparkle/releases> and open its `bin/` folder (or, after
   building Ladle once in Xcode, right-click **Sparkle** under Package Dependencies › Show in
   Finder and go to `../artifacts/sparkle/Sparkle/bin/`).
2. Run `./generate_keys`. It keeps the private key in your login keychain and prints the
   public key.
3. Put the public key in [`Ladle/Info.plist`](Ladle/Info.plist), replacing
   `REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY` in `SUPublicEDKey`, and commit it. The release workflow
   refuses to run while the placeholder is there.
4. Export the private key: `./generate_keys -x sparkle_private_key.txt`. Save the file's
   contents as the secret `SPARKLE_ED_PRIVATE_KEY`, then delete the file. Keep a backup of the
   key somewhere safe: if it's lost, existing copies of Ladle can't take updates any more.

### 4. GitHub settings

- **Secrets** (Settings › Secrets and variables › Actions), all required:

  | Secret | What |
  | --- | --- |
  | `DEVELOPER_ID_CERT_P12_BASE64` | Developer ID Application certificate and key, `.p12`, base64 |
  | `DEVELOPER_ID_CERT_PASSWORD` | The `.p12` password |
  | `APPLE_TEAM_ID` | Your team ID |
  | `ASC_API_KEY_P8_BASE64` | App Store Connect API key, `.p8`, base64 |
  | `ASC_API_KEY_ID` | That key's ID |
  | `ASC_API_ISSUER_ID` | Its issuer ID |
  | `SPARKLE_ED_PRIVATE_KEY` | Sparkle's private EdDSA key |

- **Pushing to main.** After publishing, the workflow commits the dated release notes and the
  new `site/public/appcast.xml` to `main` with `GITHUB_TOKEN`. If `main` is protected, let
  GitHub Actions push to it (a bypass for the `github-actions` app, or no required reviews for
  that path).
- **Pages from a tag.** The website deploy runs inside the tag's workflow run. In
  Settings › Environments › `github-pages`, add a deployment tag rule `v*` next to `main`, or the
  deploy is refused.

## Each release

1. Write the release notes in `site/src/content/changelog/X.Y.Z.md` and merge them to `main`:

   ```markdown
   ---
   version: X.Y.Z
   title: A few words
   ---

   What changed, for people who use Ladle.
   ```

   Leave out `date:`; the workflow sets it to the release day.
2. Tag the commit on `main` and push the tag. Tag versions in increasing order: the build
   number (`CFBundleVersion`, which Sparkle compares) is the tag's place among all release tags,
   so `v0.1.0` is build 1.

   ```sh
   git tag v1.2.0
   git push origin v1.2.0
   ```

3. Watch **Actions › App release**. It:
   1. checks the tag, that the release notes exist and match, the Sparkle key and the secrets,
      and stops there if anything is missing;
   2. builds Ladle for Apple silicon and Intel with version `X.Y.Z`, exports it with Developer
      ID, notarizes and staples it, makes `Ladle.dmg`, signs, notarizes and staples that, and
      signs it for Sparkle;
   3. publishes the GitHub Release `vX.Y.Z` with `Ladle.dmg` and the release notes, so
      `https://github.com/ALIRAZA47/ladle-mac/releases/latest/download/Ladle.dmg` serves it;
   4. sets `date:` in the release notes and adds the update to `site/public/appcast.xml` (newest
      first, the last 10 releases, each with `sparkle:releaseNotesLink` pointing at
      `https://ladle.alirazakhan.me/changelog/#vX-Y-Z`), and commits both to `main`;
   5. deploys the website through `site-deploy.yml`, so the feed and the changelog go live.

Copies of Ladle check the feed once a day, download the update in the background and offer
**Restart to Update**; otherwise it installs when Ladle quits.

### If something fails

- **Before "release"**: fix what the error says (missing notes, placeholder key, a secret) and
  push the tag again: `git tag -f vX.Y.Z && git push -f origin vX.Y.Z`.
- **Notarization**: the log from Apple is printed in the step. Most often a nested binary isn't
  signed with the hardened runtime.
- **After the GitHub Release**: re-run the failed jobs. Publishing uploads the DMG again, and the
  feed update replaces this version's entry instead of adding a second one.

## Browser extensions

Safari's extension ships inside Ladle.app; nothing to publish. The others are packaged with
`npm run build` in [`BrowserExtension/`](BrowserExtension/):

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
