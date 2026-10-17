// MC Download Manager — content script
// 1) In Safari (no downloads API) intercepts clicks on file links.
// 2) Reports <video>/<audio>/<source> URLs on the page to the background script.
(() => {
  'use strict';
  const api = typeof browser !== 'undefined' ? browser : chrome;
  const DL_EXT = /\.(zip|rar|7z|tar|gz|tgz|bz2|xz|dmg|pkg|iso|exe|msi|apk|deb|rpm|pdf|epub|mobi|doc|docx|xls|xlsx|ppt|pptx|mp4|mkv|avi|mov|webm|mp3|flac|wav|m4a|aac|ogg|jar|bin|img|csv|psd|ai|ttf|otf|woff2?)(\?|#|$)/i;

  let state = { online: false, clickIntercept: false, settings: { intercept: true } };

  // Firefox's browser.runtime.sendMessage only returns a promise (a callback argument is rejected).
  const IS_FIREFOX = typeof browser !== 'undefined' && String(browser.runtime.getURL('')).startsWith('moz-extension:');

  function refresh() {
    const apply = (r) => { if (r) state = r; };
    try {
      if (IS_FIREFOX) {
        browser.runtime.sendMessage({ type: 'status' }).then(apply, () => {});
      } else {
        api.runtime.sendMessage({ type: 'status' }, (r) => { if (!api.runtime.lastError) apply(r); });
      }
    } catch {}
  }
  refresh();
  setInterval(refresh, 30000);

  function send(msg) {
    return new Promise((resolve) => {
      try {
        if (IS_FIREFOX) browser.runtime.sendMessage(msg).then(resolve, () => resolve(null));
        else api.runtime.sendMessage(msg, (r) => resolve(api.runtime.lastError ? null : r));
      } catch { resolve(null); }
    });
  }

  let passThrough = null;   // link re-clicked after the app could not take the download
  document.addEventListener('click', (e) => {
    if (!state.clickIntercept || !state.settings?.intercept) return;
    // While the app is closed the background script can start it (native messaging) before handing over.
    if (!state.online && !(state.canLaunch && state.settings?.autoLaunch)) return;
    if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.altKey || e.shiftKey) return;
    const a = e.target && e.target.closest ? e.target.closest('a[href]') : null;
    if (!a) return;
    if (a === passThrough) { passThrough = null; return; }
    const href = a.href;
    if (!/^https?:/i.test(href)) return;
    const list = state.captureExtensions || [];
    const m = href.split(/[?#]/)[0].match(/\.([a-z0-9]{1,8})$/i);
    const ext = m ? m[1].toLowerCase() : '';
    if (list.length ? !(ext && list.includes(ext)) : !(a.hasAttribute('download') || DL_EXT.test(href))) return;
    e.preventDefault();
    e.stopPropagation();
    send({ type: 'download', url: href, filename: a.getAttribute('download') || '', referer: location.href, kind: 'file' }).then((r) => {
      if (r && r.ok) { if (!state.online) refresh(); return; }
      // The app is unavailable: let the browser handle the click after all.
      passThrough = a;
      a.click();
    });
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
})();
