// Browser extension store listings.
//
// The Chrome-family and Firefox extensions aren't listed yet. Paste each listing URL between the
// quotes once it's live and rebuild: the browser setup guide swaps its "coming soon" note for the
// store button and install steps, and the home page and FAQ start naming those browsers.
//
// Leave a value as '' until that listing exists, so the site never shows a broken link.

export const storeLinks = {
	/** Chrome Web Store listing. Arc, Edge and Brave install the same extension from it. */
	chrome: '',
	/** Firefox Add-ons (addons.mozilla.org) listing. */
	firefox: '',
};

export const hasChromeExtension = storeLinks.chrome.trim() !== '';
export const hasFirefoxExtension = storeLinks.firefox.trim() !== '';
