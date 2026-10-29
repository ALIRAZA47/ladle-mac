# Ladle

A free download manager for the Mac. Downloads, poured fast.

Ladle splits every file into several connections, catches downloads straight from your
browser, saves videos you're allowed to save, queues big files for the night, sorts
everything into folders, and updates itself.

- Website: https://ladle.alirazakhan.me
- Docs: https://ladle.alirazakhan.me/docs/
- Download: https://github.com/ALIRAZA47/ladle-mac/releases/latest/download/Ladle.dmg
- Issues and support: https://github.com/ALIRAZA47/ladle-mac/issues

## What's in this repository

| Folder | What | Read more |
| --- | --- | --- |
| [`app/`](app/) | The macOS app (Swift, SwiftUI), its browser extensions and the native messaging helper | [`app/README.md`](app/README.md) |
| [`site/`](site/) | The website and docs (Astro + Starlight), including the update feed `appcast.xml` | [`site/README.md`](site/README.md) |
| [`SPEC.md`](SPEC.md) | What Ladle does, and the names, URLs and settings the app and site share | |

## Requirements

- To use Ladle: macOS 14 Sonoma or later, Apple silicon or Intel.
- To build the app: Xcode 16 or later on macOS, plus [XcodeGen](https://github.com/yonaskolb/XcodeGen).
- To build the site: Node.js 20 or later.
