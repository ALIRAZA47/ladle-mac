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

## One-time setup: nobody merges, releases or runs Actions but the owner

The private key signs updates that every copy of Ladle installs without asking, and `main` is what
gets signed, so the repository is set up so that only its owner can merge, create a release tag or
start a workflow. Half of it lives in the repository and is already in place; the other half is
settings, applied once:

1. **Import the rulesets.** In **Settings › Rules › Rulesets**, choose **New ruleset › Import a
   ruleset** and pick each file in [`.github/rulesets/`](../.github/rulesets/):
   - `main.json` — **Protect main**: every change arrives by pull request, needs one approval from a
     code owner (that's you, through [`.github/CODEOWNERS`](../.github/CODEOWNERS), so nobody
     else's approval counts), stale approvals are dismissed on new pushes, review threads must be
     resolved, and the branch can't be force-pushed or deleted. The only bypass is the
     **Repository admin** role, which on a personal repository is you alone, so you can merge your
     own pull requests.
   - `release-tags.json` — **Release tags**: only an admin can create, move or delete a `v*` tag,
     so only you can start a release. (The workflow also refuses a tag whose commit isn't on
     `main`, and a run whose actor isn't the owner.)
   - `other-branches.json` — **Only the owner pushes branches**: nobody else can create, push to
     or delete any branch, so nobody else can start a push-triggered workflow. Other people
     contribute from forks: their pull requests still get checked, after you approve the run (next
     step). Skip this file if you'd rather give trusted collaborators their own branches.

   Each ruleset is a plain JSON file, so a change to one is a reviewed pull request like any other.
2. **Actions settings.** In **Settings › Actions › General**:
   - **Actions permissions**: *Allow owner, and select non-owner, actions and reusable workflows*
     with only *Allow actions created by GitHub* ticked. The workflows use nothing else, and this
     makes it impossible to add a third-party action by accident.
   - **Fork pull request workflows**: *Require approval for all external contributors*. A pull
     request from a fork then runs no workflow until you press **Approve and run**.
   - **Workflow permissions**: *Read repository contents and packages permissions*, and leave
     *Allow GitHub Actions to create and approve pull requests* off.
3. **A protected `release` environment.** The release job runs in the environment named
   `release`; GitHub creates it on the first run. In **Settings › Environments › release**, turn on
   **Required reviewers** and add yourself. From then on, every release waits in the Actions tab
   until you approve it, and only then can the job read the key. Keep `SPARKLE_ED_PRIVATE_KEY` as
   a secret *of that environment* (not of the repository), so no other workflow or job can read
   it. In **Settings › Environments › github-pages**, keep the deployment branch rule at `main`.
4. **Collaborators.** With the rulesets above, nobody needs write access: keep
   **Settings › Collaborators** empty. Write access is what lets someone push a branch or press
   **Run workflow**, and the only thing the in-workflow checks can't stop is a pull request from a
   write collaborator's fork running CI (which carries no secret and a read-only token).

What the workflows enforce on their own, whether or not the settings are applied:

- **App release** stops at once unless the person who pushed the tag or pressed **Run workflow** is
  the repository owner, and unless the tagged commit is on `main`.
- **Site deploy** stops unless it was started by the owner (a merge to `main`, or **Run workflow**)
  or by the release workflow itself, which runs as `github-actions[bot]` and can only deploy `main`.
- **App CI** and **Site CI** run on pushes only for the owner. Pull requests run for anyone, since
  they hold no secret and can't write anything, and fork pull requests wait for your approval.
- Only GitHub's own actions are used (`actions/checkout`, `actions/setup-node`,
  `actions/upload-artifact`, `actions/configure-pages`, `actions/upload-pages-artifact`,
  `actions/deploy-pages`); Xcode is picked with `xcode-select`, and every tool is set up before the
  checkout. Keep it that way: an action is code someone else can change, running next to the key.

If the key is ever exposed, the only remedy is a new key pair: generate one, put the new public key
in `Info.plist`, replace the secret, and release. Copies already installed can't verify the new
releases, so people have to download that version by hand once; say so in its release notes.

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
   1. checks that you started it, that the tagged commit is on `main`, that the release notes
      exist and match the tag, and that the public key is set, and stops there if anything is
      missing; then waits for the `release` environment's reviewer (you) to approve the run, checks
      Sparkle's keys, and stops if the secret isn't the private half of `SUPublicEDKey`;
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

## Later: the hardened runtime for ad-hoc builds

Release builds are ad-hoc signed with the hardened runtime off, because its library validation
refuses frameworks that aren't signed by the same team, and an ad-hoc build has no team, so Sparkle
couldn't load. The packaging script can turn it on anyway: with `LADLE_HARDENED_RUNTIME=1`,
[`scripts/package-app.sh`](scripts/package-app.sh) signs everything with `--options runtime` and
gives each piece that loads Sparkle (the app, LadleBridge, Sparkle's own helpers) the
`com.apple.security.cs.disable-library-validation` entitlement, which keeps the rest of the hardened
runtime (no injected libraries through `DYLD_` variables, no debugger attaching) while letting
Sparkle load. The Safari extension keeps its sandbox entitlements as they are, and
[`scripts/verify-package.sh`](scripts/verify-package.sh) checks the result when the same variable is
set.

It hasn't been tried on a Mac yet, and CI never launches the packaged app, so it stays off until
someone has: package with the variable set, install the DMG, open Ladle, download something, and
check for updates. If all of that works, set `LADLE_HARDENED_RUNTIME: 1` in the `env` of the
release job and the packaging dry run in `.github/workflows/`.

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
