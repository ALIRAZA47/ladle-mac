// Browser extension store listings.
//
// Neither extension is listed yet. Until the Chrome Web Store link is set, the browser setup guide
// shows how to load Ladle-Chrome-Extension.zip from the latest release in developer mode. Once
// it's set, the store button and steps take over, with a note for anyone switching from the
// developer-mode copy. Until the Firefox link is set, the guide says the add-on is on its way.
// The home page, the download page and the docs home follow both links.
//
// Leave a value as '' until that listing exists, so the site never shows a broken link. When the
// Chrome Web Store link is set, set CHROME_STORE_URL in public/install.sh too, so the install
// script sends people to the store instead of setting up the developer-mode copy.

export const storeLinks = {
	/** Chrome Web Store listing. Arc, Edge and Brave install the same extension from it. */
	chrome: '',
	/** Firefox Add-ons (addons.mozilla.org) listing. */
	firefox: '',
};

export const hasChromeExtension = storeLinks.chrome.trim() !== '';
export const hasFirefoxExtension = storeLinks.firefox.trim() !== '';

/**
 * The browsers that can run Ladle's extension today, for sentences like "Add it to …".
 * Chrome, Arc, Edge and Brave can, from the store or in developer mode. Safari can't: it only
 * loads extensions from apps signed by a registered Apple developer.
 */
export const extensionBrowsers = hasFirefoxExtension
	? 'Chrome, Arc, Edge, Brave or Firefox'
	: 'Chrome, Arc, Edge or Brave';
