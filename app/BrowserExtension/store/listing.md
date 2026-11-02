# Chrome Web Store listing

What to paste into the Chrome Web Store developer dashboard for Ladle's extension. The same text
works for Microsoft Edge Add-ons. Keep this file in step with the manifest and the privacy page
(`site/src/pages/privacy.astro`): the store compares the listing with what the extension does.

## Package

`npm run build:store` → `dist/ladle-chrome-X.Y.Z-store.zip`. It is the Chrome build without the
development `key`, so the store assigns the extension its own ID. Each upload needs a higher
version than the one before; bump the version in `package.json` and the manifests first.

## Store listing tab

| Field | Value |
| --- | --- |
| Name | Ladle (from the manifest) |
| Summary | From the manifest's `description`, 132 characters at most: *Hands downloads to Ladle, the free download manager for Mac, and adds a Download video button to videos you’re allowed to save.* |
| Category | Tools |
| Language | English |
| Homepage URL | https://ladle.alirazakhan.me/ |
| Support URL | https://github.com/ALIRAZA47/ladle-mac/issues |
| Store icon | `store/store-icon-128.png` (the app icon at 96×96 with 16 px of transparent padding, as the store asks; the package's `icons/icon-128.png` is full-bleed) |
| Screenshots | `store/screenshot-1-video-button.png`, `store/screenshot-2-quality-menu.png`, `store/screenshot-3-protected-video.png` (1280×800); add real Mac screenshots of the catch panel and the main window when available |
| Small promo tile | `store/promo-tile-440x280.png` |
| Mature content | Off |

### Detailed description

```
Ladle is a free download manager for the Mac. This extension connects your browser to it.

What it does

• Catches downloads. Click a link to a file type you’ve chosen (dmg, zip, mp4, pdf and more) and the download goes to Ladle, which pours it in through several connections at once, resumes it after an interruption, and sorts it into folders. Hold ⌥ Option while clicking to let the browser keep a download.

• Download with Ladle. Right-click any link to send it to Ladle, or choose Download All Links with Ladle… to pick from every file link on the page.

• Download video. A small button appears on videos you’re allowed to save, with a choice of quality. Protected (DRM) video is never offered.

Requires Ladle for macOS 14 Sonoma or later, free at https://ladle.alirazakhan.me — no account, no license key.

Ladle and this extension are free software under the GNU GPL v3: the source code is at https://github.com/ALIRAZA47/ladle-mac, and anyone may use, change and share them, as long as what they share stays free too.

Privacy

The extension sends nothing to any server of ours and has no analytics. When it hands a download to Ladle, it passes the file’s link, the page you were on, the file’s name and the cookies that site needs directly to the Ladle app on your Mac, so Ladle can download exactly what your browser would have. It keeps no history. Full details: https://ladle.alirazakhan.me/privacy/

Works in Chrome, Arc, Dia, Edge and Brave.
```

## Privacy tab

**Single purpose description**

```
Hands downloads from this browser to the Ladle download manager app on the user’s Mac, and offers to save videos the user is allowed to save.
```

**Permission justifications**

| Permission | Justification |
| --- | --- |
| `downloads` | To notice a download the browser is about to start, cancel it when it’s a file type the user chose to send to Ladle, and let the browser keep it when Ladle can’t take it or the user holds ⌥ Option. |
| `contextMenus` | The “Download with Ladle” and “Download All Links with Ladle…” menu items. |
| `cookies` | To pass the cookies a site set along with a download to the Ladle app, so Ladle can download the file with the same access the browser has (for example, a file behind a login). They go only to the Ladle app on the user’s Mac, which sends them only to the site they belong to. |
| `nativeMessaging` | To talk to Ladle’s helper (LadleBridge) on the user’s Mac. This is the only way downloads reach Ladle; nothing is sent over the network by the extension. |
| `storage` | To remember the settings Ladle shares with the extension (which file types to catch, whether to ask first) between browser sessions. |
| `webRequest` | To see which video streams (HLS playlists and media files) the current tab loaded, so the Download video button can offer them. Observation only; no request is blocked or modified. |
| `activeTab` | The toolbar button collects the current page’s file links when the user clicks it. |
| Host permission `<all_urls>` | Downloads and videos can come from any site: the content script shows the Download video button on any page’s videos, catches download links the user clicks on any page, and the video button looks at the stream the page is playing. |

**Remote code:** No, I am not using remote code. (Everything runs from the package.)

**Data usage.** Tick what the extension handles, then the three certifications. Nothing is sent to
us; the data goes from the browser to the Ladle app on the same Mac.

| Category | Tick? | Why |
| --- | --- | --- |
| Authentication information | Yes | A site’s cookies travel with a download to the Ladle app on the user’s Mac. |
| Website content | Yes | Links, video stream addresses and the page title of the video. |
| Web history | No | Only the address of the page a download came from is passed along with that one download; no list of visited pages is kept or sent. |
| Personally identifiable information, health, financial, personal communications, location, user activity | No | Not handled. |

Certifications: I do not sell or transfer user data to third parties outside of the approved use
cases · I do not use or transfer user data for purposes unrelated to the item’s single purpose ·
I do not use or transfer user data to determine creditworthiness or for lending purposes.

**Privacy policy URL:** https://ladle.alirazakhan.me/privacy/

## Distribution tab

Visibility **Public**, all regions, free.

## After the first upload

1. The dashboard shows the item’s **ID** (32 letters) as soon as the package is uploaded, before
   review. Add it to `chromeExtensionIDs` in `app/Ladle/Browser/BrowserIntegration.swift`: Ladle
   writes it into the native messaging host manifests, so the store copy can reach LadleBridge.
   Store installs can’t talk to Ladle until that release is out, so ship it before the listing
   goes public.
2. When the listing is live, put its URL in `storeLinks.chrome` (`site/src/config/stores.mjs`)
   and in `CHROME_STORE_URL` (`site/public/install.sh`). The site then shows the store button
   and the install script opens the store instead of setting up the developer-mode copy.
3. Microsoft Edge Add-ons takes the same zip (free registration at partner.microsoft.com). Edge
   assigns its own ID; add it the same way.

## Review notes

Native messaging, cookies and `<all_urls>` get a closer look. The justifications above describe
exactly what the code does; keep them true when the extension changes.
