// MC Download Manager — content script
// 1) In Safari (no downloads API) intercepts clicks on file links.
// 2) Reports <video>/<audio>/<source> URLs on the page to the background script.
// 3) Shows a "Download this video" button over videos.
(() => {
  'use strict';
  const api = typeof browser !== 'undefined' ? browser : chrome;
  const DL_EXT = /\.(zip|rar|7z|tar|gz|tgz|bz2|xz|dmg|pkg|iso|exe|msi|apk|deb|rpm|pdf|epub|mobi|doc|docx|xls|xlsx|ppt|pptx|mp4|mkv|avi|mov|webm|mp3|flac|wav|m4a|aac|ogg|jar|bin|img|csv|psd|ai|ttf|otf|woff2?)(\?|#|$)/i;

  let state = { online: false, clickIntercept: false, settings: { intercept: true } };

  function refresh() {
    try {
      api.runtime.sendMessage({ type: 'status' }, (r) => {
        if (api.runtime.lastError || !r) return;
        state = r;
      });
    } catch {}
  }
  refresh();
  setInterval(refresh, 30000);

  document.addEventListener('click', (e) => {
    if (!state.clickIntercept || !state.online || !state.settings?.intercept) return;
    if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.altKey || e.shiftKey) return;
    const a = e.target && e.target.closest ? e.target.closest('a[href]') : null;
    if (!a) return;
    const href = a.href;
    if (!/^https?:/i.test(href)) return;
    const list = state.captureExtensions || [];
    const m = href.split(/[?#]/)[0].match(/\.([a-z0-9]{1,8})$/i);
    const ext = m ? m[1].toLowerCase() : '';
    if (list.length ? !(ext && list.includes(ext)) : !(a.hasAttribute('download') || DL_EXT.test(href))) return;
    e.preventDefault();
    e.stopPropagation();
    api.runtime.sendMessage({ type: 'download', url: href, filename: a.getAttribute('download') || '', referer: location.href, kind: 'file' });
  }, true);

  const reported = new Set();
  function scanMedia() {
    const items = [];
    document.querySelectorAll('video, audio, source').forEach((el) => {
      const src = el.currentSrc || el.src || el.getAttribute('src');
      if (!src || !/^https?:/i.test(src) || reported.has(src)) return;
      reported.add(src);
      items.push({ url: src, type: el.getAttribute('type') || '', name: document.title ? document.title.slice(0, 80) : '' });
    });
    if (items.length) {
      try { api.runtime.sendMessage({ type: 'pageMedia', items }); } catch {}
    }
  }
  scanMedia();
  document.addEventListener('play', scanMedia, true);
  document.addEventListener('loadedmetadata', scanMedia, true);
  let n = 0;
  const iv = setInterval(() => { scanMedia(); if (++n > 20) clearInterval(iv); }, 3000);

  // 3) IDM-style "Download this video" button over playing / hovered videos.
  const t = (k) => { try { return api.i18n.getMessage(k) || k; } catch { return k; } };
  const MIN_W = 200, MIN_H = 112;
  const dismissed = new WeakSet();
  let host = null, root = null, btn = null, current = null, hideTimer = null, rafPending = false;
  let pointer = { x: -1, y: -1 }, overButton = false;

  const overlayEnabled = () => state.online && state.settings?.overlay !== false;

  // Background loops (muted, looping, no controls) are decoration, not content.
  function eligible(v) {
    if (!v.isConnected || dismissed.has(v)) return false;
    if (v.muted && v.loop && !v.controls) return false;
    if (!(v.currentSrc || v.src || v.readyState > 0 || v.querySelector('source'))) return false;
    const r = v.getBoundingClientRect();
    return r.width >= MIN_W && r.height >= MIN_H;
  }

  function ensureHost() {
    if (host) return;
    host = document.createElement('mcdm-video-button');
    host.style.cssText = 'all:initial;position:fixed;top:0;left:0;width:0;height:0;z-index:2147483647;';
    root = host.attachShadow({ mode: 'closed' });
    // Built with DOM APIs and a constructed stylesheet: pages with Trusted Types or a strict style-src CSP
    // (YouTube, GitHub…) reject innerHTML and inline <style>.
    const css = `
      .wrap { position: fixed; display: none; align-items: center; gap: 2px; font: 600 13px/1 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
              background: rgba(20, 20, 22, .82); color: #fff; border: 1px solid rgba(255, 255, 255, .18); border-radius: 9px;
              box-shadow: 0 4px 16px rgba(0, 0, 0, .35); -webkit-backdrop-filter: blur(8px); backdrop-filter: blur(8px); padding: 3px; }
      .wrap.show { display: flex; }
      button { all: unset; cursor: pointer; border-radius: 6px; padding: 7px 10px; color: inherit; white-space: nowrap; }
      button:hover, button:focus-visible { background: rgba(255, 255, 255, .14); }
      button:focus-visible { outline: 2px solid #5b8cff; outline-offset: 1px; }
      .dl { display: flex; align-items: center; gap: 7px; }
      svg { width: 15px; height: 15px; flex: none; color: #6ea1ff; }
      .x { padding: 7px 8px; opacity: .7; }
      .x:hover { opacity: 1; }
    `;
    try {
      const sheet = new CSSStyleSheet();
      sheet.replaceSync(css);
      root.adoptedStyleSheets = [sheet];
    } catch {
      root.appendChild(Object.assign(document.createElement('style'), { textContent: css }));
    }
    const el = (tag, cls) => Object.assign(document.createElement(tag), { className: cls });
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('viewBox', '0 0 16 16');
    svg.setAttribute('aria-hidden', 'true');
    const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    for (const [k, v] of Object.entries({ d: 'M8 1.5v8.5m0 0L4.5 6.5M8 10l3.5-3.5M2.5 14h11', stroke: 'currentColor', 'stroke-width': '2',
      fill: 'none', 'stroke-linecap': 'round', 'stroke-linejoin': 'round' })) path.setAttribute(k, v);
    svg.appendChild(path);
    const dl = Object.assign(el('button', 'dl'), { type: 'button' });
    dl.append(svg, el('span', 'label'));
    const x = Object.assign(el('button', 'x'), { type: 'button', textContent: '✕' });
    const wrap = root.appendChild(el('div', 'wrap'));
    wrap.append(dl, x);
    btn = dl.querySelector('.label');
    btn.textContent = t('overlayDownload');
    x.title = t('overlayHide');
    x.setAttribute('aria-label', t('overlayHide'));
    wrap.addEventListener('mouseenter', () => { overButton = true; clearTimeout(hideTimer); });
    wrap.addEventListener('mouseleave', () => { overButton = false; scheduleHide(1200); });
    for (const b of [dl, x]) {
      for (const type of ['mousedown', 'mouseup', 'pointerdown', 'pointerup']) b.addEventListener(type, (e) => e.stopPropagation());
    }
    dl.addEventListener('click', (e) => { e.preventDefault(); e.stopPropagation(); if (current) download(current); });
    x.addEventListener('click', (e) => {
      e.preventDefault(); e.stopPropagation();
      if (current) dismissed.add(current);
      hide();
    });
    attachHost();
  }

  // In fullscreen only the fullscreen element's subtree is rendered, so the button has to live inside it.
  function attachHost() {
    if (!host) return;
    const fs = document.fullscreenElement || document.webkitFullscreenElement;
    const parent = fs && fs.tagName !== 'VIDEO' ? fs : document.documentElement;
    if (host.parentNode !== parent) parent.appendChild(host);
  }

  function place(v) {
    // Anchored to the video's top-right corner so label changes ("Sending…") grow leftwards.
    const r = v.getBoundingClientRect();
    const wrap = root.querySelector('.wrap');
    wrap.classList.add('show');
    wrap.style.right = Math.max(4, document.documentElement.clientWidth - r.right + 10) + 'px';
    wrap.style.top = Math.max(4, Math.min(r.top + 10, innerHeight - 40)) + 'px';
  }

  function show(v) {
    if (!overlayEnabled() || !eligible(v)) return;
    ensureHost();
    attachHost();
    if (current !== v) { current = v; btn.textContent = t('overlayDownload'); }
    clearTimeout(hideTimer);
    place(v);
  }

  function hide() {
    clearTimeout(hideTimer);
    current = null;
    root?.querySelector('.wrap').classList.remove('show');
  }

  function scheduleHide(ms) {
    clearTimeout(hideTimer);
    hideTimer = setTimeout(() => { if (!overButton) hide(); }, ms);
  }

  function videoAt(x, y) {
    for (const v of document.querySelectorAll('video')) {
      const r = v.getBoundingClientRect();
      if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom && eligible(v)) return v;
    }
    return null;
  }

  function onPointer() {
    rafPending = false;
    if (!overlayEnabled()) { if (current) hide(); return; }
    const v = videoAt(pointer.x, pointer.y);
    if (v) show(v);
    else if (current && !overButton) scheduleHide(1200);
  }

  document.addEventListener('mousemove', (e) => {
    pointer = { x: e.clientX, y: e.clientY };
    if (!rafPending) { rafPending = true; requestAnimationFrame(onPointer); }
  }, { capture: true, passive: true });

  // Briefly announce the button when playback starts, like IDM does.
  document.addEventListener('play', (e) => {
    const v = e.target;
    if (!(v instanceof HTMLVideoElement)) return;
    setTimeout(() => { show(v); if (current === v && !overButton) scheduleHide(4000); }, 300);
  }, true);

  const reposition = () => { if (current) { if (current.isConnected) place(current); else hide(); } };
  addEventListener('scroll', reposition, { capture: true, passive: true });
  addEventListener('resize', reposition, { passive: true });
  for (const type of ['fullscreenchange', 'webkitfullscreenchange']) {
    document.addEventListener(type, () => { attachHost(); setTimeout(reposition, 100); });
  }

  try {
    api.storage.onChanged.addListener((changes, area) => {
      if (area === 'local' && changes.settings) {
        state.settings = { ...(state.settings || {}), ...(changes.settings.newValue || {}) };
        if (!overlayEnabled()) hide();
      }
    });
  } catch {}

  function titleName(ext) {
    const base = (document.title || location.hostname).replace(/[\\/:*?"<>|]+/g, ' ').trim().slice(0, 120) || 'video';
    return ext ? `${base}.${ext}` : base;
  }

  // Direct media files go to the multi-connection downloader; streams (blob:/MSE, HLS, DASH)
  // go to yt-dlp with the URL of the frame that hosts the player (embeds included).
  function download(v) {
    const src = v.currentSrc || v.src || '';
    const direct = /^https?:/i.test(src) && !/\.(m3u8|mpd)(\?|#|$)/i.test(src);
    let msg;
    if (direct) {
      const m = src.split(/[?#]/)[0].match(/\.(mp4|m4v|webm|mkv|mov|ogv|ogg)$/i);
      msg = { type: 'download', url: src, filename: titleName(m ? m[1].toLowerCase() : 'mp4'), referer: location.href, kind: 'file' };
    } else {
      msg = { type: 'download', url: location.href, referer: location.href, kind: 'video' };
    }
    btn.textContent = t('overlaySending');
    try {
      api.runtime.sendMessage(msg, (r) => {
        const ok = !api.runtime.lastError && r && r.ok;
        btn.textContent = ok ? t('overlaySent') : t('overlayFailed');
        setTimeout(() => { if (btn) btn.textContent = t('overlayDownload'); }, 2500);
      });
    } catch {
      btn.textContent = t('overlayFailed');
    }
  }
})();
