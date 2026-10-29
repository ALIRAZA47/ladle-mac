/*
 * Ladle extension: shared logic for the background, the content script and tests.
 * Plain script (no modules) so it loads the same way in Chrome, Firefox and Safari.
 */
(function (root) {
  'use strict';

  const HOST_NAME = 'me.alirazakhan.ladle';

  const DEFAULT_SETTINGS = Object.freeze({
    catchTypes: ['dmg', 'pkg', 'zip', 'iso', 'mp4', 'mov', 'mkv', 'mp3', 'flac', 'pdf'],
    askBeforeDownloading: true,
    alwaysTypes: [],
    saveFolder: 'Downloads › Ladle',
    videoFolder: 'Downloads › Ladle › Video',
    appVersion: '',
  });

  /** Every extension Ladle sorts into a category (SPEC "Files and folders"). */
  const KNOWN_TYPES = [
    'mp4', 'mov', 'mkv', 'webm', 'avi', 'm4v', 'ts',
    'mp3', 'flac', 'wav', 'm4a', 'aac', 'ogg',
    'pdf', 'epub', 'doc', 'docx', 'txt', 'pages', 'key', 'xlsx', 'csv',
    'zip', 'rar', '7z', 'tar', 'gz', 'tgz', 'bz2', 'xz',
    'dmg', 'pkg', 'iso', 'app',
    'png', 'jpg', 'jpeg', 'heic', 'webp', 'gif', 'svg', 'tiff',
  ];

  const MIME_TYPES = {
    'application/x-apple-diskimage': 'dmg',
    'application/zip': 'zip',
    'application/x-zip-compressed': 'zip',
    'application/x-iso9660-image': 'iso',
    'application/pdf': 'pdf',
    'video/mp4': 'mp4',
    'video/quicktime': 'mov',
    'video/x-matroska': 'mkv',
    'video/webm': 'webm',
    'audio/mpeg': 'mp3',
    'audio/flac': 'flac',
    'audio/x-flac': 'flac',
    'application/x-7z-compressed': '7z',
    'application/vnd.rar': 'rar',
    'application/gzip': 'gz',
    'application/x-gzip': 'gz',
    'application/x-xz': 'xz',
    'application/x-bzip2': 'bz2',
    'application/x-tar': 'tar',
  };

  /** Lowercase extension of a file name or of a link's path, '' when there is none. */
  function extensionOf(nameOrUrl) {
    if (!nameOrUrl) return '';
    let path = String(nameOrUrl);
    if (/^[a-z][a-z0-9+.-]*:\/\//i.test(path)) {
      try {
        path = new URL(path).pathname;
      } catch (e) {
        return '';
      }
    }
    path = path.split(/[?#]/)[0];
    const base = path.split(/[\\/]/).pop() || '';
    let decoded = base;
    try { decoded = decodeURIComponent(base); } catch (e) { /* keep raw */ }
    const dot = decoded.lastIndexOf('.');
    if (dot <= 0 || dot === decoded.length - 1) return '';
    const ext = decoded.slice(dot + 1).toLowerCase();
    return /^[a-z0-9]{1,10}$/.test(ext) ? ext : '';
  }

  function mimeToExtension(mime) {
    if (!mime) return '';
    return MIME_TYPES[String(mime).split(';')[0].trim().toLowerCase()] || '';
  }

  function baseName(path) {
    if (!path) return '';
    return String(path).split(/[\\/]/).pop() || '';
  }

  function isWebLink(url) {
    return /^https?:\/\//i.test(String(url || ''));
  }

  /** The watched extension of a browser download, or '' when Ladle doesn't catch it. */
  function watchedExtension(item, settings) {
    const types = (settings && settings.catchTypes) || DEFAULT_SETTINGS.catchTypes;
    const candidates = [
      extensionOf(baseName(item.filename)),
      extensionOf(item.finalUrl),
      extensionOf(item.url),
      mimeToExtension(item.mime),
    ];
    for (const ext of candidates) {
      if (ext && types.indexOf(ext) !== -1) return ext;
    }
    return '';
  }

  /**
   * Whether to take a download away from the browser.
   * `altClicks` maps link → time of an ⌥ Option-click; `bypass` maps link → expiry.
   */
  function shouldCatch(item, options) {
    const opts = options || {};
    const now = opts.now || Date.now();
    if (!item || !isWebLink(item.url)) return { catch: false, reason: 'not-web' };
    if (item.incognito) return { catch: false, reason: 'private' };
    if (item.byExtensionId && item.byExtensionId === opts.selfId) return { catch: false, reason: 'self' };
    if (item.state && item.state !== 'in_progress') return { catch: false, reason: 'finished' };
    const links = [item.url, item.finalUrl].filter(Boolean);
    const bypass = opts.bypass || {};
    for (const link of links) {
      if (bypass[link] && bypass[link] > now) return { catch: false, reason: 'bypass' };
    }
    const altClicks = opts.altClicks || {};
    for (const link of links) {
      if (altClicks[link] && now - altClicks[link] < 10000) return { catch: false, reason: 'option-click' };
    }
    const ext = watchedExtension(item, opts.settings);
    if (!ext) return { catch: false, reason: 'not-watched' };
    return { catch: true, ext };
  }

  /** Cookie header for a request, from `cookies.getAll` results. */
  function cookieHeader(cookies) {
    return (cookies || [])
      .filter((c) => c && c.name)
      .map((c) => c.name + '=' + c.value)
      .join('; ');
  }

  function browserName(userAgent, hints) {
    const ua = String(userAgent || '');
    if (hints && hints.brave) return 'Brave';
    if (/Edg\//.test(ua)) return 'Edge';
    if (/Firefox\//.test(ua)) return 'Firefox';
    if (/Chrome\//.test(ua)) return 'Chrome';
    if (/Safari\//.test(ua)) return 'Safari';
    return 'your browser';
  }

  /** The `download` message for a caught browser download or a context-menu link. */
  function downloadMessage(fields) {
    const msg = { type: 'download', url: fields.url, mode: fields.mode || 'caught' };
    const optional = ['filename', 'referrer', 'cookies', 'mime', 'browser', 'userAgent', 'sha256', 'md5'];
    for (const key of optional) {
      if (fields[key]) msg[key] = fields[key];
    }
    if (fields.size && fields.size > 0) msg.size = fields.size;
    return msg;
  }

  /** Same parameters as `LadleURL` in the app: the fallback when native messaging isn't set up. */
  function ladleURL(msg) {
    const params = [];
    const add = (name, value) => {
      if (value !== undefined && value !== null && value !== '') params.push(name + '=' + encodeURIComponent(String(value)));
    };
    const urls = msg.type === 'links' ? msg.links || [] : [msg.url];
    urls.forEach((u) => add('url', u));
    add('referrer', msg.referrer);
    add('filename', msg.filename);
    add('cookies', msg.cookies);
    add('size', msg.size);
    add('mime', msg.mime);
    add('sha256', msg.sha256);
    add('md5', msg.md5);
    add('source', msg.browser);
    if (msg.type === 'links') {
      // "Download All Links with Ladle…" opens the Add sheet, even for one link.
      add('mode', 'choose');
    } else if (msg.type === 'video') {
      add('mode', 'direct');
      if (msg.kind && msg.kind !== 'file') add('kind', msg.kind);
      add('audio', msg.audio);
      add('title', msg.title);
      add('quality', msg.quality);
      add('bandwidth', msg.bandwidth);
    } else if (msg.mode && msg.mode !== 'caught') {
      add('mode', msg.mode);
    }
    return 'ladle://add?' + params.join('&');
  }

  /**
   * Safari has no downloads API, so the content script takes clicks on links to watched files.
   * `click` is {button, altKey, metaKey, ctrlKey, shiftKey, defaultPrevented}; `link` is {href, download, target}.
   */
  function shouldInterceptClick(click, link, settings, pageUrl) {
    if (!click || !link) return false;
    if (click.defaultPrevented) return false;
    if (click.button !== 0) return false;
    if (click.altKey || click.metaKey || click.ctrlKey || click.shiftKey) return false;
    if (!isWebLink(link.href)) return false;
    if (pageUrl) {
      try {
        const target = new URL(link.href);
        const page = new URL(pageUrl);
        if (target.hash && target.origin === page.origin && target.pathname === page.pathname && target.search === page.search) return false;
      } catch (e) {
        return false;
      }
    }
    const types = (settings && settings.catchTypes) || DEFAULT_SETTINGS.catchTypes;
    const ext = extensionOf(link.download) || extensionOf(link.href);
    return !!ext && types.indexOf(ext) !== -1;
  }

  /** "5.79 GB", "312 MB", "18.2 MB": the same rules as the app. */
  function formatSize(bytes) {
    const b = Math.max(0, Number(bytes) || 0);
    if (b >= 999.5e6) {
      const v = b / 1e9;
      return (v >= 100 ? v.toFixed(0) : v.toFixed(2)) + ' GB';
    }
    if (b >= 999.5e3) {
      const v = b / 1e6;
      return (v >= 99.95 ? v.toFixed(0) : v.toFixed(1)) + ' MB';
    }
    return Math.round(b / 1e3) + ' KB';
  }

  /** "42:18" or "1:02:03". */
  function formatDuration(seconds) {
    const s = Math.max(0, Math.round(Number(seconds) || 0));
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    const sec = s % 60;
    const pad = (n) => String(n).padStart(2, '0');
    return h > 0 ? h + ':' + pad(m) + ':' + pad(sec) : m + ':' + pad(sec);
  }

  /** Links on a page worth offering: web links, unique, in order. */
  function uniqueLinks(hrefs) {
    const seen = new Set();
    const out = [];
    for (const href of hrefs) {
      if (!isWebLink(href)) continue;
      const clean = String(href).split('#')[0];
      if (seen.has(clean)) continue;
      seen.add(clean);
      out.push(clean);
    }
    return out;
  }

  /** Links to files Ladle knows how to sort. */
  function fileLinks(hrefs) {
    return uniqueLinks(hrefs).filter((href) => KNOWN_TYPES.indexOf(extensionOf(href)) !== -1);
  }

  const api = {
    HOST_NAME,
    DEFAULT_SETTINGS,
    KNOWN_TYPES,
    extensionOf,
    mimeToExtension,
    baseName,
    isWebLink,
    watchedExtension,
    shouldCatch,
    cookieHeader,
    browserName,
    downloadMessage,
    ladleURL,
    shouldInterceptClick,
    formatSize,
    formatDuration,
    uniqueLinks,
    fileLinks,
  };

  root.LadleCommon = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
