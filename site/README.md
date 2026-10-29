# Ladle website and docs

The site at **https://ladle.alirazakhan.me**: the landing page, download page, changelog,
privacy policy and the docs under `/docs/`. It's a static [Astro](https://astro.build) site, and
the docs use [Starlight](https://starlight.astro.build), themed to the same Molten design.

Product facts, URLs, settings and shortcuts come from [`../SPEC.md`](../SPEC.md). The app opens
several docs pages directly, so their paths and anchors must not change; `npm run check` fails if
any of them goes missing.

## Run it locally

You need Node.js 22.23.4 or later. The CI uses Node 24 (see [`.nvmrc`](.nvmrc)).

```sh
cd site
npm ci
npm run dev        # http://localhost:4321
```

Search (the docs header and the docs home) only works in a production build:

```sh
npm run build      # writes dist/ and the Pagefind search index
npm run preview    # serves dist/ at http://localhost:4321
npm run check      # broken links, missing #anchors, pages SPEC.md requires
```

| Command | What it does |
| --- | --- |
| `npm run dev` | Dev server with hot reload. |
| `npm run build` | Static build into `dist/`, plus the search index and sitemap. |
| `npm run preview` | Serves the build. |
| `npm run check` | Crawls `dist/` for broken internal links and anchors, checks every URL and docs page in `SPEC.md`, the changelog anchor for the spec's version, and that `appcast.xml` is a Sparkle feed. |
| `npm run images` | Regenerates `favicon.ico`, `apple-touch-icon.png` and `og.png` in `public/`. See [Images](#images). |

## Where things are

| Path | What |
| --- | --- |
| `src/pages/` | Landing page, `/download/`, `/changelog/`, `/privacy/` and the 404 page. |
| `src/content/docs/docs/` | Every docs page, as MDX. The folder path is the URL. |
| `src/content/changelog/` | One Markdown file per release, such as `0.1.0.md`. |
| `src/config/site.mjs` | URLs from the spec: downloads, releases, source, support, appcast. |
| `src/config/docs-nav.mjs` | Docs sidebar order, the docs home topic cards and breadcrumbs. |
| `src/config/stores.mjs` | Browser extension store links. See below. |
| `src/styles/tokens.css` | Molten colors, fonts and shadows for both themes. |
| `src/styles/starlight.css` | Maps Starlight onto the tokens and restyles its components. |
| `src/components/docs/` | Starlight overrides: header, page title, footer, docs home hero and search. |
| `public/appcast.xml` | The Sparkle update feed. The app's release workflow rewrites it. |

## Browser extensions and their store links

Neither extension is in a store yet, and releases are ad-hoc signed, not notarized (see
[First launch](../SPEC.md#first-launch) in the spec). So for now:

- **Chrome, Arc, Edge and Brave:** [Set up your browser](https://ladle.alirazakhan.me/docs/getting-started/set-up-your-browser/#chrome)
  shows how to load `Ladle-Chrome-Extension.zip` from the latest release in developer mode.
- **Firefox:** the guide says the add-on is on its way to Firefox Add-ons.
- **Safari:** the extension can't run, because Safari only loads extensions from apps signed by a
  registered Apple developer. The docs say so wherever Safari comes up.

When a store listing goes live, paste its URL into [`src/config/stores.mjs`](src/config/stores.mjs):

```js
export const storeLinks = {
	chrome: 'https://chromewebstore.google.com/detail/…',
	firefox: 'https://addons.mozilla.org/firefox/addon/…',
};
```

Push to `main` and the site redeploys. For each filled-in link:

- [Set up your browser](https://ladle.alirazakhan.me/docs/getting-started/set-up-your-browser/)
  swaps the developer-mode steps (Chrome) or the "on its way" note (Firefox) for the store button
  and install steps, in the `#chrome` and `#firefox` tabs the app opens. The Chrome tab keeps a
  short note for anyone moving over from the developer-mode copy;
- the troubleshooting page shows that browser's store checklist;
- the home page, the download page and the docs home name every browser with an extension.

## Write or change a docs page

1. Add an `.mdx` file under `src/content/docs/docs/<section>/`. Its path becomes its URL.
2. Give it a `title` and a one-sentence `description`. The description is shown under the title
   and used for search engines.
3. Add its slug to [`src/config/docs-nav.mjs`](src/config/docs-nav.mjs) so it appears in the
   sidebar, previous/next links and the docs home.

Useful components: `Steps`, `Aside` and `Tabs`/`TabItem` from `@astrojs/starlight/components`
(use `syncKey="browser"` with the labels `Safari`, `Chrome, Arc, Edge and Brave` and `Firefox`),
plus `TabAnchor`, `IfStore`, `UnlessStore` and `StoreButton` from `~/components/content/`.
Places where a screenshot would help are marked with `{/* Screenshot: … */}` comments.

Astro 7 applies JSX whitespace rules in `.astro` files: a line break between text and an inline
tag is removed. Write `{' '}` where a space has to survive, as in `version from{' '}` followed by
`<strong>` on the next line.

## Releases, the changelog and the update feed

Releases follow the release flow in [`SPEC.md`](../SPEC.md#updates):

1. Before tagging `vX.Y.Z`, write the release notes in `src/content/changelog/X.Y.Z.md` with
   `version` and `title` in the front matter. The changelog page turns the version into its
   anchor, such as `#v1-2-0`, which each update feed item links to.
2. Push the tag. The app's release workflow fails early if that file is missing, publishes
   `Ladle.dmg`, fills in the entry's `date`, rewrites `public/appcast.xml`, commits both to
   `main`, and then calls `site-deploy.yml`. It has to call it: a push made with the default
   `GITHUB_TOKEN` doesn't start other workflows. Called that way, the deploy builds the latest
   `main`:

   ```yaml
   deploy-site:
     needs: publish            # the job that commits appcast.xml
     permissions: { contents: read, pages: write, id-token: write }
     uses: ./.github/workflows/site-deploy.yml
   ```

The download page shows the newest version in `appcast.xml`, or the newest changelog entry
before the first release. To redeploy by hand, run **Site deploy** from the repository's
**Actions** tab.

## Deploy

[`site-deploy.yml`](../.github/workflows/site-deploy.yml) builds the site and publishes it to
GitHub Pages whenever a push to `main` changes `site/`. It can also be run by hand or called by
another workflow. [`site-ci.yml`](../.github/workflows/site-ci.yml) builds and runs
`npm run check` on every other branch and on pull requests.

### One-time setup

1. **Turn on Pages.** In the repository, open **Settings › Pages**. Under **Build and
   deployment**, set **Source** to **GitHub Actions**.
2. **Add the DNS record.** Where `alirazakhan.me`'s DNS is hosted, add:

   | Type | Name | Value |
   | --- | --- | --- |
   | CNAME | `ladle` | `aliraza47.github.io` |

3. **Set the custom domain.** Back in **Settings › Pages**, enter `ladle.alirazakhan.me` under
   **Custom domain** and click **Save**. Sites deployed by Actions take the domain from this
   setting; `public/CNAME` just records it in the repository.
4. **Deploy.** Merge to `main`, or run **Site deploy** from the **Actions** tab.
5. **Turn on HTTPS.** Once GitHub has issued the certificate (it can take a while after the DNS
   check passes), select **Enforce HTTPS** in **Settings › Pages**.

Optional but recommended: verify `alirazakhan.me` in your GitHub account's **Settings › Pages**
so nobody else can point a Pages site at its subdomains.

## Images

`npm run images` rebuilds the icons and the social preview from the artwork:

- `src/assets/ladle-icon.svg` (full detail) → `public/apple-touch-icon.png`
- `public/favicon.svg` (heavier strokes for small sizes) → `public/favicon.ico`
- `scripts/og.html` → `public/og.png`, 1200×630. This one renders in Chromium through
  [Playwright](https://playwright.dev); the script skips it with a note if Playwright isn't
  installed.

Commit the files it writes.

## Privacy

The site promises no cookies and no analytics, so keep it that way: no tracking scripts, no
embeds and no third-party fonts or CDNs. Fonts are bundled from npm. The only things stored in
the visitor's browser are the light/dark choice and the selected browser tab, in `localStorage`.
