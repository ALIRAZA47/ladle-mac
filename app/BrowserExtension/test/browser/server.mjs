// A small local web server for the browser tests.
import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';

const fixture = (name) => readFileSync(new URL(`../fixtures/${name}`, import.meta.url));

const PAGES = {
  '/video.html': `<!doctype html><html><head><title>Designing for Speed</title>
    <meta property="og:title" content="Designing for Speed"></head>
    <body style="margin:0;padding:40px;background:#FAFAF8;font-family:sans-serif">
    <h1>Designing for Speed</h1>
    <video id="v" src="/media/clip.mp4" width="680" height="383" style="display:block;background:#1D1B19;border-radius:12px" muted preload="metadata"></video>
    </body></html>`,
  '/hls.html': `<!doctype html><html><head><title>Designing for Speed</title></head>
    <body style="margin:0;padding:40px;background:#FAFAF8">
    <video id="v" width="680" height="383" style="display:block;background:#1D1B19" muted></video>
    <script>document.getElementById('v').src = 'blob:http://localhost/stream';</script>
    </body></html>`,
  '/links.html': `<!doctype html><html><head><title>Downloads</title></head><body>
    <a id="dmg" href="/files/HandBrake-1.8.2.dmg">HandBrake</a>
    <a id="zip" href="/files/archive.zip">Archive</a>
    <a id="zip2" href="/files/archive.zip#again">Archive again</a>
    <a id="page" href="/other.html">Another page</a>
    <a id="mail" href="mailto:a@b.c">Mail</a>
    <p id="part">Selected: <a id="pdf" href="/files/report.pdf">Report</a></p>
    </body></html>`,
  '/other.html': '<!doctype html><title>Other</title><p>Other page</p>',
  '/hls-native.html': `<!doctype html><html><head><title>Designing for Speed</title></head>
    <body style="margin:0;padding:40px">
    <video id="v" src="/media/local-master.m3u8" width="680" height="383" style="display:block;background:#1D1B19" muted preload="metadata"></video>
    </body></html>`,
  // The stream lives on this same server under its other name (localhost ↔ 127.0.0.1): another origin.
  // "?gated" points at a copy that needs the session cookie, which a cross-site <video> load won't send.
  '/hls-cross.html': `<!doctype html><html><head><title>Designing for Speed</title></head>
    <body style="margin:0;padding:40px">
    <video id="v" width="680" height="383" style="display:block;background:#1D1B19" muted preload="metadata"></video>
    <script>
      const other = location.hostname === 'localhost' ? '127.0.0.1' : 'localhost';
      const path = location.search === '?gated' ? '/gated/media/local-master.m3u8' : '/media/local-master.m3u8';
      document.getElementById('v').src = 'http://' + other + ':' + location.port + path;
    </script>
    </body></html>`,
};

export async function startServer() {
  const log = [];
  const server = createServer((req, res) => {
    const url = new URL(req.url, 'http://localhost');
    log.push({ path: url.pathname, headers: req.headers });
    if (PAGES[url.pathname]) {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Set-Cookie': 'session=abc123; Path=/' });
      res.end(PAGES[url.pathname]);
      return;
    }
    if (url.pathname.startsWith('/files/')) {
      const name = url.pathname.slice(7);
      const body = Buffer.alloc(256 * 1024, 7);
      res.writeHead(200, {
        'Content-Type': name.endsWith('.zip') ? 'application/zip' : 'application/octet-stream',
        'Content-Disposition': `attachment; filename="${name}"`,
        'Content-Length': body.length,
      });
      // Trickle the body so the browser's download is still running when the extension acts.
      let sent = 0;
      const timer = setInterval(() => {
        if (sent >= body.length || res.destroyed) {
          clearInterval(timer);
          res.end();
          return;
        }
        res.write(body.subarray(sent, sent + 8192));
        sent += 8192;
      }, 20);
      return;
    }
    if (url.pathname === '/media/clip.mp4') {
      res.writeHead(200, { 'Content-Type': 'video/mp4', 'Content-Length': 16 });
      res.end(Buffer.alloc(16));
      return;
    }
    if (url.pathname.endsWith('.m3u8')) {
      // /gated/… answers only with the session cookie, like a CDN with signed cookies.
      if (url.pathname.startsWith('/gated/') && !/(^|;\s*)session=abc123(;|$)/.test(req.headers.cookie || '')) {
        res.writeHead(403);
        res.end();
        return;
      }
      res.writeHead(200, { 'Content-Type': 'application/vnd.apple.mpegurl' });
      const name = url.pathname.split('/').pop();
      res.end(fixture(name === 'index.m3u8' ? 'fmp4.m3u8' : name));
      return;
    }
    res.writeHead(404);
    res.end();
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  return { server, log, origin: `http://localhost:${port}`, close: () => new Promise((r) => server.close(r)) };
}
