/*
 * Ladle extension: HLS playlist parsing for the video button's quality menu.
 * Mirrors LadleKit's M3U8 parser in the app.
 */
(function (root) {
  'use strict';

  function attributes(text) {
    const out = {};
    let key = '';
    let value = '';
    let readingKey = true;
    let inQuotes = false;
    const commit = () => {
      const k = key.trim().toUpperCase();
      if (k) out[k] = value.trim();
      key = '';
      value = '';
      readingKey = true;
    };
    for (const ch of String(text)) {
      if (readingKey) {
        if (ch === '=') readingKey = false;
        else if (ch === ',') commit();
        else key += ch;
      } else if (ch === '"') {
        inQuotes = !inQuotes;
      } else if (ch === ',' && !inQuotes) {
        commit();
      } else {
        value += ch;
      }
    }
    commit();
    return out;
  }

  function resolve(ref, base) {
    try {
      return new URL(String(ref).trim(), base).href;
    } catch (e) {
      return null;
    }
  }

  function isAudioOnlyVariant(v) {
    if (v.width || v.height) return false;
    if (!v.codecs) return false;
    const list = v.codecs.toLowerCase().split(',').map((c) => c.trim());
    const video = ['avc', 'hvc', 'hev', 'dvh', 'dva', 'vp0', 'vp9', 'av01', 'mp4v'];
    return list.length > 0 && !list.some((c) => video.some((p) => c.indexOf(p) === 0));
  }

  function qualityLabel(v) {
    if (isAudioOnlyVariant(v)) return 'Audio only';
    if (v.height) return v.height >= 2160 ? v.height + 'p · 4K' : v.height + 'p';
    return ((v.averageBandwidth || v.bandwidth) / 1e6).toFixed(1) + ' Mbps';
  }

  /** Returns {type:'master', variants, renditions, protected} or {type:'media', segments, map, complete, protected, duration, targetDuration}. */
  function parse(text, baseURL) {
    const lines = String(text || '').replace(/\r\n?/g, '\n').split('\n').map((l) => l.trim());
    const first = lines.find((l) => l.length > 0);
    if (!first || first.indexOf('#EXTM3U') !== 0) throw new Error('Not an HLS playlist');
    if (lines.some((l) => l.indexOf('#EXT-X-STREAM-INF') === 0)) return parseMaster(lines, baseURL);
    return parseMedia(lines, baseURL);
  }

  function parseMaster(lines, baseURL) {
    const variants = [];
    const renditions = [];
    let isProtected = false;
    let pending = null;
    for (const line of lines) {
      if (!line) continue;
      if (line.indexOf('#EXT-X-STREAM-INF:') === 0) {
        pending = attributes(line.slice('#EXT-X-STREAM-INF:'.length));
      } else if (line.indexOf('#EXT-X-MEDIA:') === 0) {
        const a = attributes(line.slice('#EXT-X-MEDIA:'.length));
        renditions.push({
          type: (a.TYPE || '').toUpperCase(),
          groupId: a['GROUP-ID'] || '',
          name: a.NAME || '',
          language: a.LANGUAGE || null,
          isDefault: (a.DEFAULT || '').toUpperCase() === 'YES',
          uri: a.URI ? resolve(a.URI, baseURL) : null,
        });
      } else if (line.indexOf('#EXT-X-SESSION-KEY:') === 0 || line.indexOf('#EXT-X-KEY:') === 0) {
        const a = attributes(line.slice(line.indexOf(':') + 1));
        if ((a.METHOD || 'NONE').toUpperCase() !== 'NONE') isProtected = true;
      } else if (line.charAt(0) === '#') {
        continue;
      } else if (pending) {
        const a = pending;
        pending = null;
        const uri = resolve(line, baseURL);
        if (!uri) continue;
        let width = null;
        let height = null;
        if (a.RESOLUTION) {
          const parts = a.RESOLUTION.toLowerCase().split('x');
          if (parts.length === 2) {
            width = parseInt(parts[0], 10) || null;
            height = parseInt(parts[1], 10) || null;
          }
        }
        variants.push({
          uri,
          bandwidth: parseInt(a.BANDWIDTH, 10) || 0,
          averageBandwidth: a['AVERAGE-BANDWIDTH'] ? parseInt(a['AVERAGE-BANDWIDTH'], 10) : null,
          width,
          height,
          codecs: a.CODECS || null,
          audioGroup: a.AUDIO || null,
        });
      }
    }
    return { type: 'master', variants, renditions, protected: isProtected };
  }

  function parseMedia(lines, baseURL) {
    const segments = [];
    let map = null;
    let complete = false;
    let isProtected = false;
    let targetDuration = null;
    let pendingDuration = null;
    for (const line of lines) {
      if (!line) continue;
      if (line.indexOf('#EXTINF:') === 0) {
        pendingDuration = parseFloat(line.slice(8).split(',')[0]) || 0;
      } else if (line.indexOf('#EXT-X-TARGETDURATION:') === 0) {
        targetDuration = parseFloat(line.slice(22));
      } else if (line.indexOf('#EXT-X-ENDLIST') === 0) {
        complete = true;
      } else if (line.indexOf('#EXT-X-PLAYLIST-TYPE:') === 0) {
        if (line.slice(21).toUpperCase() === 'VOD') complete = true;
      } else if (line.indexOf('#EXT-X-KEY:') === 0) {
        const a = attributes(line.slice(11));
        if ((a.METHOD || 'NONE').toUpperCase() !== 'NONE') isProtected = true;
      } else if (line.indexOf('#EXT-X-MAP:') === 0) {
        const a = attributes(line.slice(11));
        if (!map && a.URI) map = { uri: resolve(a.URI, baseURL) };
      } else if (line.charAt(0) === '#') {
        continue;
      } else {
        const uri = resolve(line, baseURL);
        if (uri) segments.push({ uri, duration: pendingDuration || 0 });
        pendingDuration = null;
      }
    }
    const duration = segments.reduce((sum, s) => sum + s.duration, 0);
    return { type: 'media', segments, map, complete, protected: isProtected, duration, targetDuration };
  }

  /** "fmp4", "ts" or "aac", like HLSJoin.container in the app. */
  function container(media) {
    if (media.map) return 'fmp4';
    const first = media.segments[0];
    const ext = first ? (first.uri.split(/[?#]/)[0].split('.').pop() || '').toLowerCase() : '';
    if (['m4s', 'mp4', 'm4v', 'm4a', 'cmfv', 'cmfa'].indexOf(ext) !== -1) return 'fmp4';
    if (['aac', 'ac3', 'ec3', 'mp3'].indexOf(ext) !== -1) return 'aac';
    return 'ts';
  }

  function codecName(codecs) {
    const c = String(codecs || '').toLowerCase();
    if (/hvc1|hev1|dvh1|dvhe/.test(c)) return 'HEVC';
    if (/av01/.test(c)) return 'AV1';
    if (/vp09|vp9/.test(c)) return 'VP9';
    if (/avc1|avc3/.test(c)) return 'H.264';
    return '';
  }

  function sortedVariants(master) {
    return master.variants.slice().sort((a, b) => {
      const aa = isAudioOnlyVariant(a);
      const ba = isAudioOnlyVariant(b);
      if (aa !== ba) return aa ? 1 : -1;
      if ((a.height || 0) !== (b.height || 0)) return (b.height || 0) - (a.height || 0);
      return (b.averageBandwidth || b.bandwidth) - (a.averageBandwidth || a.bandwidth);
    });
  }

  function audioRendition(master, variant) {
    if (!variant.audioGroup) return null;
    const list = master.renditions.filter((r) => r.type === 'AUDIO' && r.groupId === variant.audioGroup && r.uri);
    return list.find((r) => r.isDefault) || list[0] || null;
  }

  /**
   * Quality menu entries, best first, with "Audio only" last when the stream has it.
   * `media` (optional) is one parsed variant playlist, for the length and container.
   */
  function menuOptions(master, media) {
    const duration = media ? media.duration : 0;
    const kind = media ? container(media) : 'fmp4';
    const box = kind === 'ts' ? 'TS' : 'MP4';
    const options = [];
    const seen = new Set();
    for (const v of sortedVariants(master)) {
      const audioOnly = isAudioOnlyVariant(v);
      if (audioOnly) continue;
      const label = qualityLabel(v);
      if (seen.has(label)) continue;
      seen.add(label);
      const codec = codecName(v.codecs);
      const rendition = audioRendition(master, v);
      const bandwidth = v.averageBandwidth || v.bandwidth;
      options.push({
        label,
        format: codec ? box + ' · ' + codec : box,
        size: duration > 0 && bandwidth > 0 ? Math.round((bandwidth * duration) / 8) : null,
        url: v.uri,
        audio: rendition ? rendition.uri : null,
        bandwidth,
        kind: 'hls',
      });
    }
    const audioVariant = sortedVariants(master).find(isAudioOnlyVariant);
    const audioRenditions = master.renditions.filter((r) => r.type === 'AUDIO' && r.uri);
    const audioURL = audioVariant ? audioVariant.uri : (audioRenditions.find((r) => r.isDefault) || audioRenditions[0] || {}).uri;
    if (audioURL) {
      const bandwidth = audioVariant ? audioVariant.averageBandwidth || audioVariant.bandwidth : 128000;
      options.push({
        label: 'Audio only',
        format: kind === 'ts' ? 'TS · AAC' : 'M4A · AAC',
        size: duration > 0 ? Math.round((bandwidth * duration) / 8) : null,
        url: audioURL,
        audio: null,
        bandwidth,
        kind: 'hls',
      });
    }
    return options;
  }

  /** The variant to inspect for length and container: the best video one. */
  function probeVariant(master) {
    return sortedVariants(master).find((v) => !isAudioOnlyVariant(v)) || master.variants[0] || null;
  }

  const api = { attributes, parse, container, menuOptions, sortedVariants, probeVariant, qualityLabel, isAudioOnlyVariant, audioRendition, codecName };
  root.LadleHLS = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
