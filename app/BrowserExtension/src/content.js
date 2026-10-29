/*
 * Ladle extension: content script.
 * - Records ⌥ Option-clicks so the browser keeps those downloads.
 * - Safari only: hands clicks on links to watched files to Ladle (Safari has no downloads API).
 * - Collects links for "Download All Links with Ladle…" and counts them for the toolbar badge.
 * - Adds the "Download video" pill and its quality menu to videos you're allowed to save.
 */
(function () {
  'use strict';
  if (window.__ladleContent) return;
  window.__ladleContent = true;

  const api = globalThis.browser || globalThis.chrome;
  const C = globalThis.LadleCommon;
  const isTop = window === window.top;
  let config = { interceptClicks: false, catchTypes: C.DEFAULT_SETTINGS.catchTypes, videoFolder: C.DEFAULT_SETTINGS.videoFolder };

  function send(message) {
    try {
      return Promise.resolve(api.runtime.sendMessage(message)).catch(() => null);
    } catch (e) {
      return Promise.resolve(null);
    }
  }

  send({ type: 'getConfig' }).then((reply) => {
    if (reply) config = Object.assign({}, config, reply);
  });

  // MARK: ⌥ Option-click and Safari's link clicks

  document.addEventListener(
    'mousedown',
    (event) => {
      if (!event.altKey) return;
      const link = event.target && event.target.closest ? event.target.closest('a[href]') : null;
      if (link && C.isWebLink(link.href)) send({ type: 'altClick', url: link.href });
    },
    true
  );

  function sameHost(url) {
    try {
      return new URL(url).host === location.host;
    } catch (e) {
      return false;
    }
  }

  document.addEventListener(
    'click',
    (event) => {
      if (!config.interceptClicks) return;
      const link = event.target && event.target.closest ? event.target.closest('a[href]') : null;
      if (!link || link.dataset.ladleSkip === '1') return;
      const click = {
        button: event.button,
        altKey: event.altKey,
        metaKey: event.metaKey,
        ctrlKey: event.ctrlKey,
        shiftKey: event.shiftKey,
        defaultPrevented: event.defaultPrevented,
      };
      if (!C.shouldInterceptClick(click, { href: link.href, download: link.getAttribute('download') }, config, location.href)) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      send({
        type: 'catchLink',
        url: link.href,
        filename: link.getAttribute('download') || '',
        referrer: location.href,
        cookies: sameHost(link.href) ? document.cookie : '',
      }).then((reply) => {
        if (reply && reply.ok) return;
        // Ladle couldn't take it: let the browser have the click after all.
        link.dataset.ladleSkip = '1';
        link.click();
        setTimeout(() => delete link.dataset.ladleSkip, 1000);
      });
    },
    true
  );

  // MARK: links

  function allLinks(selectionOnly) {
    const selection = selectionOnly ? window.getSelection() : null;
    const hrefs = [];
    for (const a of document.querySelectorAll('a[href]')) {
      if (selection && selection.rangeCount > 0 && !selection.containsNode(a, true)) continue;
      hrefs.push(a.href);
    }
    if (!selectionOnly) {
      for (const media of document.querySelectorAll('video[src], audio[src], video source[src], audio source[src]')) {
        hrefs.push(media.src);
      }
    }
    // The page's file links: the Add sheet lists them, checked, to choose from.
    return C.fileLinks(hrefs);
  }

  api.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (!message || message.type !== 'collectLinks' || !isTop) return false;
    sendResponse({ links: allLinks(!!message.selectionOnly) });
    return false;
  });

  let countTimer = null;
  function reportCount() {
    if (!isTop) return;
    clearTimeout(countTimer);
    countTimer = setTimeout(() => {
      const files = C.fileLinks(Array.from(document.querySelectorAll('a[href]'), (a) => a.href));
      const videos = Array.from(document.querySelectorAll('video')).filter((v) => C.isWebLink(v.currentSrc || v.src)).length;
      send({ type: 'pageCount', count: files.length + videos });
    }, 800);
  }

  // MARK: the video button

  const ICON_LADLE = '<path d="M3 12.5h13a6.5 6.5 0 0 1-13 0z"></path><path d="M16 12.5l5-7"></path><path d="M9.5 2.5v6M7 6.5l2.5 2.5L12 6.5"></path>';
  const ICON_LOCK = '<rect x="5" y="11" width="14" height="10" rx="2"></rect><path d="M8 11V7a4 4 0 0 1 8 0v4"></path>';
  const ICON_DOWN = '<path d="m6 9 6 6 6-6"></path>';
  const ICON_UP = '<path d="m6 15 6-6 6 6"></path>';
  const ICON_CHECK = '<path d="M20 6 9 17l-5-5"></path>';
  const ICON_FOLDER = '<path d="M3 7.5A1.5 1.5 0 0 1 4.5 6H9l2 2h8.5A1.5 1.5 0 0 1 21 9.5v8a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 17.5z"></path>';

  const STYLE = `
    :host { all: initial; }
    * { box-sizing: border-box; }
    .layer { position: fixed; z-index: 2147483646; pointer-events: none; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Inter", system-ui, sans-serif; -webkit-font-smoothing: antialiased; color: #F6F2EC; }
    .ic { fill: none; stroke: currentColor; stroke-width: 1.8; stroke-linecap: round; stroke-linejoin: round; flex: none; display: block; }
    .pill { position: absolute; top: 14px; right: 14px; pointer-events: auto; display: flex; align-items: center; gap: 8px; height: 36px; padding: 0 12px 0 11px; border-radius: 999px; border: 1px solid rgba(255, 240, 220, 0.16); background: rgba(22, 21, 19, 0.82); box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.08), 0 8px 24px rgba(0, 0, 0, 0.45); backdrop-filter: blur(20px) saturate(150%); -webkit-backdrop-filter: blur(20px) saturate(150%); color: #F6F2EC; font-family: inherit; font-size: 13px; font-weight: 600; line-height: 1; cursor: default; white-space: nowrap; opacity: 0; transform: translateY(-4px); transition: opacity 0.18s, transform 0.18s; }
    .pill.shown { opacity: 1; transform: none; }
    .pill:focus-visible { outline: 2px solid #F6F2EC; outline-offset: 2px; }
    .pill.open { box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.08), 0 0 0 2px rgba(255, 138, 31, 0.55), 0 8px 24px rgba(0, 0, 0, 0.45); }
    .pill .brand { color: #FF9A3D; }
    .pill .dot { color: #9A9389; font-weight: 400; }
    .pill .quality { color: #CFC9C0; font-weight: 500; font-variant-numeric: tabular-nums; }
    .pill .chev { color: #9C9489; }
    .pill.locked { height: 34px; padding: 0 13px 0 11px; font-weight: 500; font-size: 12.5px; color: #B8B0A6; }
    .menu { position: absolute; top: 60px; right: 14px; width: 304px; pointer-events: auto; display: flex; flex-direction: column; gap: 6px; padding: 10px; border-radius: 22px; border: 1px solid rgba(255, 240, 220, 0.16); background: rgba(30, 28, 26, 0.92); box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.08), 0 24px 60px rgba(0, 0, 0, 0.55); backdrop-filter: blur(28px) saturate(150%); -webkit-backdrop-filter: blur(28px) saturate(150%); }
    .head { display: flex; flex-direction: column; gap: 2px; padding: 4px 8px 6px; }
    .title { font-size: 13.5px; font-weight: 700; }
    .sub { font-size: 12px; color: #B8B0A6; font-variant-numeric: tabular-nums; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .options { display: flex; flex-direction: column; gap: 2px; }
    .opt { display: grid; grid-template-columns: 18px minmax(0, 1fr) auto; gap: 10px; align-items: center; height: 44px; padding: 0 10px; border: 0; border-radius: 14px; background: transparent; color: #F6F2EC; text-align: left; font-family: inherit; cursor: default; }
    .opt:hover { background: rgba(255, 244, 230, 0.06); }
    .opt[aria-checked="true"] { box-shadow: inset 0 0 0 1px rgba(255, 138, 31, 0.45), inset 0 0 0 999px rgba(255, 138, 31, 0.1); }
    .opt:focus-visible { outline: 2px solid #F6F2EC; outline-offset: 1px; }
    .radio { width: 18px; height: 18px; display: grid; place-items: center; border-radius: 999px; border: 1.5px solid rgba(255, 240, 220, 0.25); color: #1E1206; }
    .opt[aria-checked="true"] .radio { border-color: #FF8A1F; background: #FF8A1F; }
    .radio svg { opacity: 0; stroke-width: 3.4; }
    .opt[aria-checked="true"] .radio svg { opacity: 1; }
    .label { display: flex; flex-direction: column; gap: 1px; min-width: 0; }
    .label b { font-size: 13px; font-weight: 600; }
    .label span { font-size: 11.5px; color: #9C9489; }
    .size { font-size: 12px; color: #B8B0A6; font-variant-numeric: tabular-nums; }
    .rule { height: 1px; margin: 4px 8px; background: rgba(255, 240, 220, 0.1); }
    .folder { display: flex; align-items: center; gap: 8px; padding: 4px 8px; font-size: 12px; color: #B8B0A6; }
    .folder .ic { color: #FF9A3D; }
    .go { height: 40px; margin-top: 4px; border: 0; border-radius: 999px; background: #FF8A1F; color: #1E1206; font-family: inherit; font-size: 13px; font-weight: 600; box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.35), 0 6px 18px rgba(255, 138, 31, 0.3); cursor: default; }
    .go:hover { filter: brightness(1.07); }
    .go:focus-visible { outline: 2px solid #F6F2EC; outline-offset: 2px; }
    @media (prefers-reduced-motion: reduce) { .pill { transition: none; } }
  `;

  function icon(paths, size, extra) {
    return '<svg class="ic' + (extra ? ' ' + extra : '') + '" viewBox="0 0 24 24" width="' + size + '" height="' + size + '" aria-hidden="true">' + paths + '</svg>';
  }

  function escapeHTML(text) {
    return String(text).replace(/[&<>"']/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]));
  }

  function pageTitle() {
    const og = document.querySelector('meta[property="og:title"]');
    const title = (og && og.content) || document.title || '';
    return title.trim().slice(0, 150);
  }

  /** One video on the page and its button. */
  class VideoButton {
    constructor(video) {
      this.video = video;
      this.state = 'idle';
      this.result = null;
      this.selected = 0;
      this.protected = false;
      this.open = false;
      this.hideTimer = null;
      this.flash = null;
      this.host = document.createElement('ladle-video-button');
      this.root = this.host.attachShadow({ mode: 'open' });
      this.root.innerHTML = '<style>' + STYLE + '</style><div class="layer"></div>';
      this.layer = this.root.querySelector('.layer');
      this.onEncrypted = () => {
        this.protected = true;
        this.render();
      };
      this.onSourceChange = () => {
        this.state = 'idle';
        this.result = null;
        this.render();
      };
      video.addEventListener('encrypted', this.onEncrypted);
      video.addEventListener('loadstart', this.onSourceChange);
      this.layer.addEventListener('keydown', (event) => {
        if (event.key === 'Escape' && this.open) {
          this.open = false;
          this.render();
          const pill = this.layer.querySelector('.pill');
          if (pill) pill.focus();
        }
      });
    }

    get source() {
      return this.video.currentSrc || this.video.src || '';
    }

    isProtected() {
      return this.protected || !!this.video.mediaKeys;
    }

    attach() {
      if (!this.host.isConnected) (document.body || document.documentElement).appendChild(this.host);
    }

    detach() {
      this.video.removeEventListener('encrypted', this.onEncrypted);
      this.video.removeEventListener('loadstart', this.onSourceChange);
      this.host.remove();
    }

    place() {
      const rect = this.video.getBoundingClientRect();
      Object.assign(this.layer.style, { left: rect.left + 'px', top: rect.top + 'px', width: rect.width + 'px', height: rect.height + 'px' });
      return rect;
    }

    show() {
      clearTimeout(this.hideTimer);
      this.attach();
      this.visible = true;
      this.inspect();
      this.render();
      track();
    }

    scheduleHide() {
      clearTimeout(this.hideTimer);
      this.hideTimer = setTimeout(() => {
        if (this.open || (this.root.activeElement && this.layer.contains(this.root.activeElement))) return;
        this.visible = false;
        this.render();
      }, 1500);
    }

    inspect() {
      if (this.isProtected() || this.state !== 'idle') return;
      this.state = 'loading';
      send({ type: 'inspectVideo', src: this.source }).then((result) => {
        this.result = result || { unavailable: true };
        this.state = 'ready';
        if (this.result.protected) this.protected = true;
        const options = this.result.options || [];
        const preferred = options.findIndex((o) => /^(\d+)p/.test(o.label) && parseInt(o.label, 10) <= 1080);
        this.selected = preferred >= 0 ? preferred : 0;
        this.render();
      });
    }

    get options() {
      return (this.result && this.result.options) || [];
    }

    canSave() {
      return !this.isProtected() && this.options.length > 0;
    }

    render() {
      const shown = this.visible || this.open;
      if (this.isProtected()) {
        this.layer.innerHTML =
          '<span class="pill locked' + (shown ? ' shown' : '') + '" role="note" aria-disabled="true">' +
          icon(ICON_LOCK, 14) + 'Protected video can’t be saved</span>';
        return;
      }
      if (!this.canSave()) {
        this.layer.innerHTML = '';
        return;
      }
      const option = this.options[this.selected] || this.options[0];
      const quality = option.label === 'Original' ? '' : option.label;
      let label = 'Download video';
      if (this.flash) label = this.flash;
      const pill =
        '<button type="button" class="pill' + (shown ? ' shown' : '') + (this.open ? ' open' : '') + '" aria-haspopup="true" aria-expanded="' + this.open + '">' +
        icon(this.flash === 'Sent to Ladle' ? ICON_CHECK : ICON_LADLE, 16, 'brand') +
        '<span>' + escapeHTML(label) + '</span>' +
        (quality && !this.flash && !this.open ? '<span class="dot" aria-hidden="true">·</span><span class="quality">' + escapeHTML(quality) + '</span>' : '') +
        icon(this.open ? ICON_UP : ICON_DOWN, 13, 'chev') +
        '</button>';
      let menu = '';
      if (this.open) {
        const duration = isFinite(this.video.duration) && this.video.duration > 0 ? this.video.duration : (this.result && this.result.duration) || 0;
        const title = pageTitle();
        const sub = [title, duration ? C.formatDuration(duration) : ''].filter(Boolean).join(' · ');
        menu =
          '<section class="menu" aria-label="Save this video">' +
          '<div class="head"><span class="title">Save this video</span>' + (sub ? '<span class="sub">' + escapeHTML(sub) + '</span>' : '') + '</div>' +
          '<div class="options" role="radiogroup" aria-label="Quality">' +
          this.options
            .map(
              (o, i) =>
                '<button type="button" class="opt" role="radio" data-index="' + i + '" aria-checked="' + (i === this.selected) + '">' +
                '<span class="radio" aria-hidden="true">' + icon(ICON_CHECK, 10) + '</span>' +
                '<span class="label"><b>' + escapeHTML(o.label) + '</b><span>' + escapeHTML(o.format || '') + '</span></span>' +
                '<span class="size">' + (o.size ? escapeHTML(C.formatSize(o.size)) : '') + '</span></button>'
            )
            .join('') +
          '</div><div class="rule"></div>' +
          '<div class="folder">' + icon(ICON_FOLDER, 14) + '<span>' + escapeHTML(config.videoFolder) + '</span></div>' +
          '<button type="button" class="go">Download ' + escapeHTML(option.label === 'Original' ? 'video' : option.label) + '</button>' +
          '</section>';
      }
      this.layer.innerHTML = pill + menu;
      this.layer.querySelector('.pill').addEventListener('click', () => {
        this.open = !this.open;
        this.render();
      });
      for (const button of this.layer.querySelectorAll('.opt')) {
        button.addEventListener('click', () => {
          this.selected = Number(button.dataset.index);
          this.render();
          const again = this.layer.querySelector('.opt[data-index="' + this.selected + '"]');
          if (again) again.focus();
        });
      }
      const go = this.layer.querySelector('.go');
      if (go) go.addEventListener('click', () => this.save());
    }

    save() {
      const option = this.options[this.selected];
      if (!option) return;
      this.open = false;
      this.flash = 'Sending…';
      this.render();
      send({ type: 'saveVideo', option, title: pageTitle(), pageUrl: location.href }).then((reply) => {
        this.flash = reply && reply.ok ? 'Sent to Ladle' : 'Couldn’t reach Ladle';
        this.render();
        setTimeout(() => {
          this.flash = null;
          this.render();
        }, 2500);
      });
    }
  }

  const buttons = new Map();
  let tracking = false;

  function track() {
    if (tracking) return;
    tracking = true;
    const step = () => {
      let any = false;
      for (const button of buttons.values()) {
        if (!button.video.isConnected) {
          button.detach();
          buttons.delete(button.video);
          continue;
        }
        if (button.visible || button.open || button.flash) {
          any = true;
          button.place();
        }
      }
      if (any) requestAnimationFrame(step);
      else tracking = false;
    };
    requestAnimationFrame(step);
  }

  function consider(video) {
    if (buttons.has(video)) return buttons.get(video);
    const button = new VideoButton(video);
    buttons.set(video, button);
    return button;
  }

  function scanVideos() {
    for (const video of document.querySelectorAll('video')) consider(video);
  }

  function inside(rect, x, y) {
    return x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom;
  }

  document.addEventListener(
    'mousemove',
    (event) => {
      for (const button of buttons.values()) {
        const rect = button.video.getBoundingClientRect();
        if (rect.width < 160 || rect.height < 90) continue;
        if (inside(rect, event.clientX, event.clientY)) {
          button.show();
        } else if (button.visible) {
          button.scheduleHide();
        }
      }
    },
    { passive: true, capture: true }
  );

  document.addEventListener(
    'pointerdown',
    (event) => {
      for (const button of buttons.values()) {
        if (button.open && !event.composedPath().includes(button.host)) {
          button.open = false;
          button.render();
        }
      }
    },
    true
  );

  const observer = new MutationObserver(() => {
    scanVideos();
    reportCount();
  });

  function start() {
    scanVideos();
    reportCount();
    observer.observe(document.documentElement, { childList: true, subtree: true });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, { once: true });
  else start();
})();
