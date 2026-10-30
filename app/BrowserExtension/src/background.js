/*
 * Ladle extension: background.
 * Chrome, Arc, Edge, Brave: service worker. Firefox: event page. Safari: service worker.
 * Catches downloads of watched types, adds "Download with Ladle" menus, finds videos per tab,
 * and talks to Ladle through native messaging (Safari: through the app extension).
 */
if (typeof importScripts === 'function' && typeof LadleCommon === 'undefined') {
  importScripts('lib/ladle-common.js', 'lib/hls.js');
}

(function () {
  'use strict';

  const api = globalThis.browser || globalThis.chrome;
  const C = globalThis.LadleCommon;
  const H = globalThis.LadleHLS;
  const hasDownloads = !!(api.downloads && api.downloads.onCreated);
  const hasWebRequest = !!(api.webRequest && api.webRequest.onHeadersReceived);
  const isFirefox = typeof navigator !== 'undefined' && /Firefox\//.test(navigator.userAgent);
  // Safari web extensions have no downloads API; its content script catches link clicks instead.
  const isSafari = !hasDownloads;
  const BROWSER = C.browserName(typeof navigator !== 'undefined' ? navigator.userAgent : '', { brave: typeof navigator !== 'undefined' && !!navigator.brave });
  const VERSION = api.runtime.getManifest().version;
  const MENU_LINK = 'ladle-download-link';
  const MENU_ALL = 'ladle-download-all';
  const PORT_IDLE_MS = 5 * 60 * 1000;

  let settings = null;
  const altClicks = {};
  const bypass = {};
  const tabMedia = new Map();
  const pendingNames = new Map();
  const inspections = new Map();

  // MARK: settings

  async function loadSettings() {
    if (settings) return settings;
    try {
      const stored = await api.storage.local.get(['settings']);
      if (stored && stored.settings) settings = stored.settings;
    } catch (e) {
      /* storage unavailable */
    }
    return settings;
  }

  function saveSettings(next) {
    if (!next) return;
    settings = next;
    try {
      const saved = api.storage.local.set({ settings: next, ladleSeen: true });
      if (saved && typeof saved.catch === 'function') saved.catch(() => {});
    } catch (e) {
      /* storage unavailable */
    }
  }

  async function ladleSeen() {
    try {
      const stored = await api.storage.local.get(['ladleSeen']);
      return !!(stored && stored.ladleSeen);
    } catch (e) {
      return false;
    }
  }

  // MARK: native messaging

  let port = null;
  let nextId = 1;
  let idleTimer = null;
  const waiting = new Map();

  function touchPort() {
    if (idleTimer) clearTimeout(idleTimer);
    idleTimer = setTimeout(() => {
      if (port && waiting.size === 0) {
        port.disconnect();
        port = null;
      }
    }, PORT_IDLE_MS);
  }

  function connect() {
    if (port) return port;
    try {
      port = api.runtime.connectNative(C.HOST_NAME);
    } catch (e) {
      port = null;
      return null;
    }
    port.onMessage.addListener(onNativeMessage);
    port.onDisconnect.addListener(() => {
      const reason = (api.runtime.lastError && api.runtime.lastError.message) || 'Ladle isn’t reachable';
      port = null;
      for (const entry of waiting.values()) entry.reject(new Error(reason));
      waiting.clear();
    });
    return port;
  }

  function request(message, timeoutMs) {
    if (isSafari) {
      // The containing app's extension handler answers; the name is ignored by Safari.
      return Promise.resolve(api.runtime.sendNativeMessage('application.id', message)).then((reply) => {
        if (!reply || reply.ok === false) throw new Error((reply && reply.error) || 'Ladle didn’t answer');
        if (reply.settings) saveSettings(reply.settings);
        return reply;
      });
    }
    return new Promise((resolve, reject) => {
      const p = connect();
      if (!p) {
        reject(new Error('Native messaging isn’t set up'));
        return;
      }
      const id = nextId++;
      const timer = setTimeout(() => {
        waiting.delete(id);
        reject(new Error('Ladle didn’t answer'));
      }, timeoutMs || 20000);
      waiting.set(id, {
        resolve(value) {
          clearTimeout(timer);
          resolve(value);
        },
        reject(error) {
          clearTimeout(timer);
          reject(error);
        },
      });
      touchPort();
      try {
        p.postMessage(Object.assign({ id }, message));
      } catch (e) {
        waiting.delete(id);
        clearTimeout(timer);
        reject(e);
      }
    });
  }

  function onNativeMessage(message) {
    if (!message) return;
    touchPort();
    if (message.replyTo !== undefined && message.replyTo !== null && waiting.has(message.replyTo)) {
      const entry = waiting.get(message.replyTo);
      waiting.delete(message.replyTo);
      if (message.settings) saveSettings(message.settings);
      if (message.ok) entry.resolve(message);
      else entry.reject(Object.assign(new Error(message.error || 'Ladle said no'), { code: message.error }));
      return;
    }
    if (message.type === 'settings' && message.settings) saveSettings(message.settings);
    if (message.type === 'browserDownload' && message.url) browserDownload(message.url, message.filename);
  }

  async function hello() {
    try {
      const reply = await request({ type: 'hello', browser: BROWSER, version: VERSION }, 5000);
      if (reply && reply.settings) saveSettings(reply.settings);
      return true;
    } catch (e) {
      return false;
    }
  }

  async function ensureSettings() {
    if (await loadSettings()) return settings;
    await hello();
    return settings;
  }

  /** Opens `ladle://add?…`; the browser asks once before handing it to Ladle. */
  async function openLadleURL(url) {
    try {
      const tabs = await api.tabs.query({ active: true, currentWindow: true });
      if (tabs && tabs[0] && tabs[0].id !== undefined) {
        await api.tabs.update(tabs[0].id, { url });
      } else {
        await api.tabs.create({ url, active: false });
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  /** Sends a request to Ladle; falls back to the ladle:// link where there is no native messaging. */
  async function handOff(message, options) {
    const opts = options || {};
    message.browser = message.browser || BROWSER;
    if (!message.userAgent && typeof navigator !== 'undefined') message.userAgent = navigator.userAgent;
    try {
      await request(message);
      return { ok: true };
    } catch (error) {
      if (error && error.code === 'letBrowser') return { ok: false, letBrowser: true };
      if (isSafari || opts.noFallback) return { ok: false };
      const opened = await openLadleURL(C.ladleURL(message));
      return { ok: opened, viaLink: true };
    }
  }

  // MARK: cookies

  async function cookiesFor(url, storeId) {
    if (!api.cookies || !api.cookies.getAll || !C.isWebLink(url)) return '';
    try {
      const query = { url };
      if (storeId) query.storeId = storeId;
      return C.cookieHeader(await api.cookies.getAll(query), url);
    } catch (e) {
      return '';
    }
  }

  // MARK: catching downloads (Chrome, Arc, Edge, Brave, Firefox)

  /** "Let the browser handle it": the browser downloads it itself, uncaught, this once. */
  async function browserDownload(url, filename) {
    if (!hasDownloads) return;
    bypass[url] = Date.now() + 60000;
    const options = { url, saveAs: false };
    if (filename) options.filename = filename;
    try {
      await api.downloads.download(options);
    } catch (e) {
      try {
        await api.downloads.download({ url });
      } catch (e2) {
        /* nothing more to do */
      }
    }
  }

  function prune() {
    const now = Date.now();
    for (const key of Object.keys(altClicks)) if (now - altClicks[key] > 10000) delete altClicks[key];
    for (const key of Object.keys(bypass)) if (bypass[key] < now) delete bypass[key];
  }

  async function considerDownload(item) {
    prune();
    await ensureSettings();
    const verdict = C.shouldCatch(item, {
      settings: settings || C.DEFAULT_SETTINGS,
      altClicks,
      bypass,
      selfId: api.runtime.id,
    });
    if (!verdict.catch) {
      // Chrome often learns the real name (Content-Disposition) a moment later.
      if (verdict.reason === 'not-watched' && !item.filename && !isFirefox) {
        pendingNames.set(item.id, item);
        setTimeout(() => pendingNames.delete(item.id), 15000);
      }
      if (verdict.reason === 'option-click') {
        for (const link of [item.url, item.finalUrl]) delete altClicks[link];
      }
      return;
    }
    // Only take it if Ladle can be reached, or was set up before (then the ladle:// link works).
    const reachable = (await hello()) || (await ladleSeen());
    if (!reachable) return;
    try {
      await api.downloads.cancel(item.id);
    } catch (e) {
      return;
    }
    quiet(api.downloads.erase({ id: item.id }));
    const cookies = await cookiesFor(item.url, item.cookieStoreId);
    const message = C.downloadMessage({
      url: item.url,
      filename: C.baseName(item.filename),
      referrer: item.referrer,
      cookies,
      size: item.totalBytes > 0 ? item.totalBytes : item.fileSize,
      mime: item.mime,
      mode: 'caught',
    });
    const result = await handOff(message);
    if (!result.ok) browserDownload(item.url, C.baseName(item.filename));
  }

  if (hasDownloads) {
    api.downloads.onCreated.addListener((item) => {
      considerDownload(item);
    });
    if (api.downloads.onChanged) {
      api.downloads.onChanged.addListener((delta) => {
        if (!delta || !delta.filename || !pendingNames.has(delta.id)) return;
        const item = pendingNames.get(delta.id);
        pendingNames.delete(delta.id);
        item.filename = delta.filename.current;
        considerDownload(item);
      });
    }
  }

  // MARK: context menus and the toolbar button

  function quiet(result) {
    if (result && typeof result.catch === 'function') result.catch(() => {});
  }

  function createMenus() {
    const menus = api.contextMenus || api.menus;
    if (!menus) return;
    const ignore = () => void api.runtime.lastError;
    const create = () => {
      menus.create({ id: MENU_LINK, title: 'Download with Ladle', contexts: ['link', 'video', 'audio', 'image'] }, ignore);
      menus.create({ id: MENU_ALL, title: 'Download All Links with Ladle…', contexts: ['page', 'link', 'selection'] }, ignore);
    };
    try {
      const cleared = menus.removeAll();
      if (cleared && typeof cleared.then === 'function') cleared.then(create, create);
      else create();
    } catch (e) {
      create();
    }
  }

  async function collectLinks(tab, selectionOnly) {
    if (!tab || tab.id === undefined) return [];
    try {
      const reply = await api.tabs.sendMessage(tab.id, { type: 'collectLinks', selectionOnly: !!selectionOnly });
      return (reply && reply.links) || [];
    } catch (e) {
      return [];
    }
  }

  async function sendLinks(tab, links) {
    if (!links.length) return;
    const cookies = links.length === 1 ? await cookiesFor(links[0]) : '';
    await handOff({ type: 'links', links, referrer: tab && tab.url, cookies });
  }

  const menuApi = api.contextMenus || api.menus;
  if (menuApi && menuApi.onClicked) {
    menuApi.onClicked.addListener(async (info, tab) => {
      if (info.menuItemId === MENU_LINK) {
        const url = info.linkUrl || info.srcUrl;
        if (!C.isWebLink(url)) return;
        const message = C.downloadMessage({
          url,
          referrer: info.pageUrl || (tab && tab.url),
          cookies: await cookiesFor(url),
          mode: 'direct',
        });
        await handOff(message);
      } else if (info.menuItemId === MENU_ALL) {
        const links = await collectLinks(tab, !!info.selectionText);
        await sendLinks(tab, links);
      }
    });
  }

  if (api.action && api.action.onClicked) {
    api.action.onClicked.addListener(async (tab) => {
      const links = await collectLinks(tab, false);
      await sendLinks(tab, links);
    });
  }

  function setBadge(tabId, count) {
    if (!api.action || tabId === undefined) return;
    const text = count > 0 ? String(count > 99 ? '99+' : count) : '';
    quiet(api.action.setBadgeText({ tabId, text }));
    if (api.action.setBadgeBackgroundColor) quiet(api.action.setBadgeBackgroundColor({ tabId, color: '#FF8A1F' }));
    const title = count > 0 ? 'Ladle: ' + count + (count === 1 ? ' download' : ' downloads') + ' found on this page' : 'Ladle';
    quiet(api.action.setTitle({ tabId, title }));
  }

  // MARK: videos

  function rememberMedia(tabId, entry) {
    const list = tabMedia.get(tabId) || [];
    if (!list.some((e) => e.url === entry.url)) list.push(entry);
    while (list.length > 30) list.shift();
    tabMedia.set(tabId, list);
  }

  if (hasWebRequest) {
    try {
      api.webRequest.onHeadersReceived.addListener(
        (details) => {
          if (details.tabId === undefined || details.tabId < 0) return;
          const header = (details.responseHeaders || []).find((h) => h.name && h.name.toLowerCase() === 'content-type');
          const type = header ? String(header.value || '').toLowerCase() : '';
          const ext = C.extensionOf(details.url);
          let kind = null;
          if (ext === 'm3u8' || type.indexOf('mpegurl') !== -1) kind = 'hls';
          else if (details.type === 'media' && (['mp4', 'webm', 'mov', 'm4v'].indexOf(ext) !== -1 || /^video\/(mp4|webm|quicktime)/.test(type))) kind = 'file';
          if (kind) rememberMedia(details.tabId, { url: details.url, kind, time: Date.now() });
        },
        { urls: ['<all_urls>'], types: ['media', 'xmlhttprequest', 'other'] },
        ['responseHeaders']
      );
    } catch (e) {
      /* webRequest not allowed here */
    }
  }

  if (api.tabs && api.tabs.onRemoved) {
    api.tabs.onRemoved.addListener((tabId) => tabMedia.delete(tabId));
  }
  if (api.tabs && api.tabs.onUpdated) {
    api.tabs.onUpdated.addListener((tabId, change) => {
      if (change && change.status === 'loading' && change.url) tabMedia.delete(tabId);
    });
  }

  const FILE_TYPES = ['mp4', 'webm', 'mov', 'm4v'];

  async function fetchText(url, credentials) {
    const response = await fetch(url, { credentials: credentials || 'omit', cache: 'no-store' });
    if (!response.ok) throw new Error('HTTP ' + response.status);
    return response.text();
  }

  function originOf(url) {
    try {
      return new URL(url).origin;
    } catch (e) {
      return null;
    }
  }

  /** The origin of the frame a message came from; null when it has none (sandboxed, data:). */
  function frameOriginOf(sender) {
    const origin = sender ? sender.origin || (sender.url ? originOf(sender.url) : null) : null;
    return origin && origin !== 'null' ? origin : null;
  }

  function sameOrigin(url, frameOrigin) {
    return !!frameOrigin && originOf(url) === frameOrigin;
  }

  /**
   * Which cookies a look at `url` may carry, asked from a frame of `frameOrigin`. The page's own
   * origin gets them: a same-origin fetch with cookies is what the page could do itself. Any other
   * origin gets none: a cookie-less fetch tells the page nothing about the user, so what the button
   * shows (which the page can read) never says where they're logged in.
   */
  function credentialsFor(url, frameOrigin) {
    return sameOrigin(url, frameOrigin) ? 'include' : 'omit';
  }

  /** Whether the tab itself loaded `url` (webRequest saw it), so the page's own <video> already uses it. */
  function tabLoaded(tabId, url) {
    const plain = String(url).split('#')[0]; // requests carry no fragment; a src may (#t=10)
    return (tabMedia.get(tabId) || []).some((e) => e.url === plain);
  }

  /** A playlist we couldn't read without the page's cookies: offered as is, for Ladle to sort out. */
  function unreadStream(url) {
    return { options: [{ label: 'Original', format: 'HLS', size: null, url, audio: null, bandwidth: null, kind: 'hls' }], duration: 0 };
  }

  /** What the video button can offer for a playlist, asked from a frame of `frameOrigin`. */
  async function inspectPlaylist(url, frameOrigin) {
    // Cached per asking origin: a result read with the page's cookies is never shown to another page.
    const key = (frameOrigin || '') + ' ' + url;
    const cached = inspections.get(key);
    if (cached && Date.now() - cached.time < 5 * 60 * 1000) return cached.result;
    const credentials = credentialsFor(url, frameOrigin);
    let result;
    try {
      const parsed = H.parse(await fetchText(url, credentials), url);
      if (parsed.type === 'master') {
        if (parsed.protected) {
          result = { protected: true };
        } else {
          const probe = H.probeVariant(parsed);
          const media = probe && C.isWebLink(probe.uri) ? H.parse(await fetchText(probe.uri, credentialsFor(probe.uri, frameOrigin)), probe.uri) : null;
          if (media && media.protected) result = { protected: true };
          else if (media && !media.complete) result = { live: true };
          else result = { options: H.menuOptions(parsed, media), duration: media ? media.duration : 0 };
        }
      } else if (parsed.protected) {
        result = { protected: true };
      } else if (!parsed.complete) {
        result = { live: true };
      } else {
        const box = H.container(parsed) === 'ts' ? 'TS' : 'MP4';
        result = {
          options: [{ label: 'Original', format: box, size: null, url, audio: null, bandwidth: null, kind: 'hls' }],
          duration: parsed.duration,
        };
      }
    } catch (e) {
      // Another origin's playlist that won't open without cookies (a CDN with signed cookies, say) is
      // still the page's own stream: offer it as is. Ladle fetches it with the user's cookies once
      // they've clicked, and picks the best quality itself when none is named.
      result = credentials === 'omit' ? unreadStream(url) : { unavailable: true };
    }
    inspections.set(key, { time: Date.now(), result });
    return result;
  }

  /** What the video button can offer for a <video> whose source is `src`, in a frame of `frameOrigin` in tab `tabId`. */
  async function inspectVideo(src, tabId, frameOrigin) {
    const ext = C.extensionOf(src);
    if (C.isWebLink(src) && (ext === 'm3u8' || FILE_TYPES.indexOf(ext) !== -1)) {
      // The page's own files, always. Another origin's only once the page's <video> has loaded it,
      // and then without cookies (see credentialsFor): a page can't point the button at a private
      // link somewhere else to learn whether the user can open it.
      if (!sameOrigin(src, frameOrigin) && !tabLoaded(tabId, src)) return { unavailable: true };
      if (ext === 'm3u8') return inspectPlaylist(src, frameOrigin);
      return {
        options: [{ label: 'Original', format: ext === 'mov' ? 'MOV' : ext.toUpperCase(), size: null, url: src, audio: null, bandwidth: null, kind: 'file' }],
      };
    }
    // Media Source players: use what the tab loaded.
    const seen = (tabMedia.get(tabId) || []).slice().reverse();
    const hls = seen.filter((e) => e.kind === 'hls');
    for (const entry of hls) {
      const result = await inspectPlaylist(entry.url, frameOrigin);
      if (!result.unavailable) return result;
    }
    const file = seen.find((e) => e.kind === 'file');
    if (file) return inspectVideo(file.url, tabId, frameOrigin);
    return { unavailable: true };
  }

  async function saveVideo(option, title, pageUrl) {
    if (!option || !C.isWebLink(option.url)) return { ok: false };
    const message = {
      type: 'video',
      url: option.url,
      kind: option.kind === 'file' ? 'file' : 'hls',
      title: title || '',
      quality: option.label === 'Original' ? '' : option.label,
      referrer: pageUrl,
      cookies: await cookiesFor(option.url),
    };
    if (option.audio) message.audio = option.audio;
    if (option.bandwidth) message.bandwidth = option.bandwidth;
    return handOff(message);
  }

  // MARK: messages from content scripts

  api.runtime.onMessage.addListener((message, sender, sendResponse) => {
    const tabId = sender && sender.tab ? sender.tab.id : undefined;
    const reply = (promise) => {
      Promise.resolve(promise).then(sendResponse, () => sendResponse({ ok: false }));
      return true;
    };
    switch (message && message.type) {
      case 'getConfig':
        return reply(
          ensureSettings().then((s) => {
            const current = s || C.DEFAULT_SETTINGS;
            return {
              interceptClicks: isSafari,
              catchTypes: current.catchTypes || C.DEFAULT_SETTINGS.catchTypes,
              videoFolder: current.videoFolder || C.DEFAULT_SETTINGS.videoFolder,
            };
          })
        );
      case 'altClick':
        if (message.url) altClicks[message.url] = Date.now();
        return false;
      case 'pageCount':
        setBadge(tabId, message.count || 0);
        return false;
      case 'inspectVideo':
        return reply(inspectVideo(message.src, tabId, frameOriginOf(sender)));
      case 'saveVideo':
        return reply(saveVideo(message.option, message.title, sender && sender.tab ? sender.tab.url : message.pageUrl));
      case 'catchLink':
        // Safari: a click on a link to a watched file.
        return reply(
          handOff(
            C.downloadMessage({
              url: message.url,
              filename: message.filename,
              referrer: message.referrer,
              cookies: message.cookies,
              mode: 'caught',
            })
          )
        );
      default:
        return false;
    }
  });

  createMenus();
  loadSettings().then((s) => {
    if (!s) hello();
  });
})();
