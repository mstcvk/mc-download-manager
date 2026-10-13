'use strict';
const api = typeof browser !== 'undefined' ? browser : chrome;
const $ = (id) => document.getElementById(id);
const t = (k, subs) => { try { return api.i18n.getMessage(k, subs) || k; } catch { return k; } };

document.querySelectorAll('[data-i18n]').forEach((el) => { el.textContent = t(el.dataset.i18n); });
document.documentElement.lang = (() => { try { return api.i18n.getUILanguage(); } catch { return 'en'; } })();

// Firefox's browser.runtime.sendMessage only returns a promise (a callback argument is rejected).
const IS_FIREFOX = typeof browser !== 'undefined' && String(browser.runtime.getURL('')).startsWith('moz-extension:');

function send(msg) {
  return new Promise((resolve) => {
    try {
      if (IS_FIREFOX) browser.runtime.sendMessage(msg).then(resolve, () => resolve(null));
      else api.runtime.sendMessage(msg, (r) => resolve(api.runtime.lastError ? null : r));
    } catch { resolve(null); }
  });
}
function fmtSize(n) {
  if (!n) return '';
  const u = ['B', 'KB', 'MB', 'GB'];
  let i = 0; while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return n.toFixed(i ? 1 : 0) + ' ' + u[i];
}

let tab = null;

async function currentTab() {
  const tabs = await api.tabs.query({ active: true, currentWindow: true });
  return tabs && tabs[0];
}

async function refresh() {
  const st = await send({ type: 'status' });
  const online = !!(st && st.online);
  $('dot').classList.toggle('on', online);
  $('statusText').textContent = online
    ? t('popupConnected', [String(st.app.version)]) + (st.app.active ? ` · ${t('popupActive', [String(st.app.active)])}` : '')
    : t('popupOffline');
  $('offline').classList.toggle('hidden', online);
  $('launch').classList.toggle('hidden', !(st && st.canLaunch));
  if (st && st.settings) {
    $('intercept').checked = !!st.settings.intercept;
    $('sniff').checked = !!st.settings.sniff;
    $('autoLaunch').checked = st.settings.autoLaunch !== false;
    $('port').value = st.settings.port;
    $('minSize').value = st.settings.minSizeMB || 0;
  }
}

async function loadMedia() {
  tab = await currentTab();
  const list = (tab && (await send({ type: 'getMedia', tabId: tab.id }))) || [];
  const ul = $('media');
  ul.innerHTML = '';
  $('count').textContent = list.length ? `(${list.length})` : '';
  $('noMedia').classList.toggle('hidden', list.length > 0);
  for (const m of list) {
    const li = document.createElement('li');
    const info = document.createElement('div'); info.className = 'info';
    const name = document.createElement('div'); name.className = 'name'; name.textContent = m.name || m.url; name.title = m.url;
    const meta = document.createElement('div'); meta.className = 'meta';
    const kind = m.kind === 'hls' ? t('kindHls') : m.kind === 'dash' ? t('kindDash') : (m.type || t('kindMedia'));
    meta.textContent = [kind, fmtSize(m.size)].filter(Boolean).join(' · ');
    info.append(name, meta);
    const btn = document.createElement('button'); btn.className = 'small'; btn.textContent = t('popupDownload');
    btn.onclick = async () => {
      btn.disabled = true; btn.textContent = '…';
      const k = m.kind === 'hls' || m.kind === 'dash' ? 'video' : 'file';
      const r = await send({ type: 'download', url: m.url, filename: k === 'file' ? m.name : '', referer: tab.url, kind: k });
      btn.textContent = r && r.ok ? t('popupSent') : t('popupError');
    };
    li.append(info, btn);
    ul.appendChild(li);
  }
}

// ---------- Downloads (progress list) ----------
const seenActive = new Set();   // ids that were active while this popup was open → keep showing their final state
const STATE_LABEL = { queued: 'stateQueued', paused: 'statePaused', probing: 'stateProbing', completed: 'stateCompleted', failed: 'stateFailed', cancelled: 'stateCancelled' };
let dlTimer = null;

async function loadDownloads() {
  const all = (await send({ type: 'downloads' })) || [];
  const shown = all.filter((d) => {
    if (d.state === 'downloading' || d.state === 'probing') { seenActive.add(d.id); return true; }
    if (d.state === 'queued' || d.state === 'paused') return true;
    return seenActive.has(d.id);
  });
  const ul = $('dl');
  $('noDl').classList.toggle('hidden', shown.length > 0);
  // Rebuild only when the set of rows changes; otherwise update in place to keep buttons clickable.
  const ids = shown.map((d) => d.id).join('|');
  if (ul.dataset.ids !== ids) { ul.innerHTML = ''; ul.dataset.ids = ids; for (const d of shown) ul.appendChild(buildRow(d)); }
  for (const d of shown) updateRow(d);
}

function buildRow(d) {
  const li = document.createElement('li'); li.dataset.id = d.id;
  const info = document.createElement('div'); info.className = 'info';
  const name = document.createElement('div'); name.className = 'name';
  const bar = document.createElement('div'); bar.className = 'bar'; bar.appendChild(Object.assign(document.createElement('div'), { className: 'fill' }));
  const meta = document.createElement('div'); meta.className = 'meta';
  info.append(name, bar, meta);
  const actions = document.createElement('div'); actions.className = 'actions';
  const toggle = document.createElement('button'); toggle.className = 'icon toggle';
  toggle.onclick = () => send({ type: 'action', id: d.id, action: toggle.dataset.action }).then(loadDownloads);
  const cancel = document.createElement('button'); cancel.className = 'icon cancel'; cancel.textContent = '✕'; cancel.title = t('popupCancel');
  cancel.onclick = () => send({ type: 'action', id: d.id, action: cancel.dataset.action || 'cancel' }).then(loadDownloads);
  actions.append(toggle, cancel);
  li.append(info, actions);
  return li;
}

function updateRow(d) {
  const li = $('dl').querySelector(`li[data-id="${d.id}"]`); if (!li) return;
  li.querySelector('.name').textContent = d.name; li.querySelector('.name').title = d.name;
  const active = d.state === 'downloading' || d.state === 'probing';
  const pct = d.total > 0 ? Math.min(100, Math.round((100 * d.received) / d.total)) : (d.state === 'completed' ? 100 : 0);
  const bar = li.querySelector('.bar');
  bar.className = 'bar' + (active && d.total <= 0 ? ' indeterminate' : '') + (d.state === 'completed' ? ' done' : '') + (d.state === 'failed' ? ' failed' : '');
  bar.querySelector('.fill').style.width = (active && d.total <= 0) ? '' : pct + '%';
  const parts = [];
  if (d.state === 'downloading') {
    if (d.total > 0) parts.push(pct + '%', fmtSize(d.received) + ' / ' + fmtSize(d.total));
    if (d.speed > 0) parts.push(fmtSize(d.speed) + '/s');
    if (d.stage) parts.push(d.stage);
  } else {
    parts.push(d.stage && active ? d.stage : t(STATE_LABEL[d.state] || d.state));
    if (d.state === 'failed' && d.error) parts.push(d.error);
  }
  li.querySelector('.meta').textContent = parts.join(' · ');
  const toggle = li.querySelector('.toggle'), cancel = li.querySelector('.cancel');
  const terminal = d.state === 'completed' || d.state === 'failed' || d.state === 'cancelled';
  toggle.classList.toggle('hidden', terminal);
  if (active) { toggle.textContent = '❚❚'; toggle.title = t('popupPause'); toggle.dataset.action = 'pause'; }
  else { toggle.textContent = '▶'; toggle.title = t('popupResume'); toggle.dataset.action = 'resume'; }
  cancel.dataset.action = terminal ? 'remove' : 'cancel';
  cancel.title = terminal ? t('popupRemove') : t('popupCancel');
}

$('pageVideo').onclick = async () => {
  tab = tab || (await currentTab());
  if (!tab?.url) return;
  $('pageVideo').textContent = t('popupSending');
  const r = await send({ type: 'download', url: tab.url, referer: tab.url, kind: 'video' });
  $('pageVideo').textContent = r && r.ok ? t('popupStarted') : t('popupFailed');
  loadDownloads();
  setTimeout(() => ($('pageVideo').textContent = t('popupPageVideo')), 2500);
};
$('pageLink').onclick = async () => {
  tab = tab || (await currentTab());
  if (!tab?.url) return;
  await send({ type: 'download', url: tab.url, referer: tab.url, kind: 'file' });
  window.close();
};
$('launch').onclick = async () => {
  await send({ type: 'launchApp' });
  setTimeout(refresh, 1500);
};
$('intercept').onchange = (e) => send({ type: 'setSettings', settings: { intercept: e.target.checked } });
$('sniff').onchange = (e) => send({ type: 'setSettings', settings: { sniff: e.target.checked } });
$('autoLaunch').onchange = (e) => send({ type: 'setSettings', settings: { autoLaunch: e.target.checked } });
$('port').onchange = (e) => send({ type: 'setSettings', settings: { port: parseInt(e.target.value, 10) || 48213 } }).then(refresh);
$('minSize').onchange = (e) => send({ type: 'setSettings', settings: { minSizeMB: parseInt(e.target.value, 10) || 0 } });

refresh();
loadMedia();
loadDownloads();
dlTimer = setInterval(loadDownloads, 1000);
