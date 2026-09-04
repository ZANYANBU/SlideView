import * as pdfjsLib from '/vendor/pdf.min.mjs';
pdfjsLib.GlobalWorkerOptions.workerSrc = '/vendor/pdf.worker.min.mjs';

const $  = s => document.querySelector(s);
const $$ = s => [...document.querySelectorAll(s)];
const clamp = (v, a, b) => v < a ? a : v > b ? b : v;
const native = window.webkit?.messageHandlers?.app;
const send = (cmd, extra = {}) => { try { native?.postMessage({ cmd, ...extra }); } catch {} };

const store = {
  get(k, d) { try { const v = localStorage.getItem(k); return v === null ? d : JSON.parse(v); } catch { return d; } },
  set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch {} }
};

const S = {
  lib: null, subject: 'all', filter: '',
  doc: null, pdf: null, page: 1, total: 0,
  theme: store.get('sv:theme', 'smart'),
  zoom: 1, fitMode: 'fit',
  strip: store.get('sv:strip', false),
  stars: new Set(),
  text: null, textDone: 0,
  token: 0, baseW: 0, aspect: 16 / 9,
  fs: false
};

/* ════════════════════════════════════════════════════════════════
   Appearance engine
   ──────────────────────────────────────────────────────────────
   `smart`  invert text + vector art, leave photographs alone
   `invert` invert the whole page
   `dim`    keep colours, lower the light output
   `light`  untouched
   Inversion = per-channel invert followed by a 180° hue rotation,
   so a red heading stays red instead of turning cyan. The result is
   then compressed into [LO,HI] so paper-white lands on a soft near
   black and body text on a soft near white — easier on the eyes for
   a long revision session than pure #000/#fff.
   ════════════════════════════════════════════════════════════════ */
const LO = 16, HI = 233;
const IMG_DIM = 0.92;      // gentle knock-down on preserved photos
const DIM_K   = 0.55;

let lutTheme = null, LUT = null;
function grayLUT(theme) {
  if (lutTheme === theme) return LUT;
  const t = new Uint8ClampedArray(256);
  for (let v = 0; v < 256; v++) {
    if (theme === 'dim') t[v] = v * DIM_K;
    else t[v] = LO + (255 - v) * (HI - LO) / 255;
  }
  LUT = t; lutTheme = theme;
  return t;
}

function transformPixels(img, mask, theme) {
  if (theme === 'light') return;
  const d = img.data, n = d.length, lut = grayLUT(theme);
  const dim = theme === 'dim';

  for (let i = 0, p = 0; i < n; i += 4, p++) {
    if (mask && mask[p]) {                       // preserved photograph
      if (!dim) { d[i] *= IMG_DIM; d[i + 1] *= IMG_DIM; d[i + 2] *= IMG_DIM; }
      else      { d[i] *= DIM_K;   d[i + 1] *= DIM_K;   d[i + 2] *= DIM_K;   }
      continue;
    }
    const r = d[i], g = d[i + 1], b = d[i + 2];
    if (r === g && g === b) {                    // grey — the common case, table lookup
      const v = lut[r]; d[i] = v; d[i + 1] = v; d[i + 2] = v;
      continue;
    }
    if (dim) { d[i] = r * DIM_K; d[i + 1] = g * DIM_K; d[i + 2] = b * DIM_K; continue; }

    const R = 255 - r, G = 255 - g, B = 255 - b; // invert …
    let nr = -0.574 * R + 1.430 * G + 0.144 * B; // … then rotate hue 180°
    let ng =  0.426 * R + 0.430 * G + 0.144 * B;
    let nb =  0.426 * R + 1.430 * G - 0.856 * B;
    const k = (HI - LO) / 255;
    d[i]     = LO + clamp(nr, 0, 255) * k;
    d[i + 1] = LO + clamp(ng, 0, 255) * k;
    d[i + 2] = LO + clamp(nb, 0, 255) * k;
  }
}

/* Walk the page's operator list, tracking the CTM, to find where raster
   images land on the canvas. Those regions are exempt from inversion. */
const OPS = pdfjsLib.OPS;
function mul(m, n) {
  return [
    m[0] * n[0] + m[2] * n[1], m[1] * n[0] + m[3] * n[1],
    m[0] * n[2] + m[2] * n[3], m[1] * n[2] + m[3] * n[3],
    m[0] * n[4] + m[2] * n[5] + m[4], m[1] * n[4] + m[3] * n[5] + m[5]
  ];
}
async function imageRects(page, viewport) {
  let ops;
  try { ops = await page.getOperatorList(); } catch { return []; }
  const rects = [];
  const stack = [];
  let ctm = viewport.transform.slice();

  for (let i = 0; i < ops.fnArray.length; i++) {
    const fn = ops.fnArray[i], a = ops.argsArray[i];
    switch (fn) {
      case OPS.save: stack.push(ctm.slice()); break;
      case OPS.restore: ctm = stack.pop() || ctm; break;
      case OPS.transform: ctm = mul(ctm, a); break;
      case OPS.paintFormXObjectBegin: stack.push(ctm.slice()); if (a?.[0]) ctm = mul(ctm, a[0]); break;
      case OPS.paintFormXObjectEnd: ctm = stack.pop() || ctm; break;
      case OPS.paintImageXObject:
      case OPS.paintImageXObjectRepeat:
      case OPS.paintInlineImageXObject:
      case OPS.paintJpegXObject: {
        const xs = [], ys = [];
        for (const [ux, uy] of [[0, 0], [1, 0], [0, 1], [1, 1]]) {
          xs.push(ctm[0] * ux + ctm[2] * uy + ctm[4]);
          ys.push(ctm[1] * ux + ctm[3] * uy + ctm[5]);
        }
        rects.push([Math.min(...xs), Math.min(...ys), Math.max(...xs), Math.max(...ys)]);
        break;
      }
      // paintImageMaskXObject is a stencil filled with the current colour —
      // that is really text/vector art, so it stays invertible.
    }
  }
  return rects;
}

/* Average luminance of a region. Samples a fixed GRID rather than a fixed
   pixel stride, so a thumbnail and a full-size render of the same slide
   always reach the same verdict. */
const LUMA_GRID = 48;
function regionLuma(data, W, x0, y0, x1, y1) {
  const w = x1 - x0, h = y1 - y0;
  if (w <= 0 || h <= 0) return 0;
  const cols = Math.min(LUMA_GRID, w), rows = Math.min(LUMA_GRID, h);
  let sum = 0, n = 0;
  for (let j = 0; j < rows; j++) {
    const y = y0 + Math.floor((j + 0.5) * h / rows);
    for (let i = 0; i < cols; i++) {
      const x = x0 + Math.floor((i + 0.5) * w / cols);
      const idx = (y * W + x) * 4;
      sum += 0.2126 * data[idx] + 0.7152 * data[idx + 1] + 0.0722 * data[idx + 2];
      n++;
    }
  }
  return n ? sum / n : 0;
}

function buildMask(img, rects, W, H) {
  if (!rects.length) return null;
  const area = W * H;
  const mask = new Uint8Array(W * H);
  let any = false;

  for (const r of rects) {
    const x0 = clamp(Math.floor(r[0]) + 1, 0, W), x1 = clamp(Math.ceil(r[2]) - 1, 0, W);
    const y0 = clamp(Math.floor(r[1]) + 1, 0, H), y1 = clamp(Math.ceil(r[3]) - 1, 0, H);
    if (x1 - x0 < 6 || y1 - y0 < 6) continue;

    // A near-white image that covers most of the slide is a background
    // plate, not a photo — inverting it is the whole point of dark mode.
    if ((x1 - x0) * (y1 - y0) > area * 0.45 &&
        regionLuma(img.data, W, x0, y0, x1, y1) > 150) continue;

    any = true;
    for (let y = y0; y < y1; y++) {
      mask.fill(1, y * W + x0, y * W + x1);
    }
  }
  return any ? mask : null;
}

/* ════════════════════════  page rendering  ════════════════════════ */
const cacheMain = new Map(), cacheThumb = new Map();
function cachePut(cache, key, bmp, limit) {
  cache.set(key, bmp);
  while (cache.size > limit) {
    const k = cache.keys().next().value;
    try { cache.get(k).close?.(); } catch {}
    cache.delete(k);
  }
}
function dropCaches() {
  for (const c of [cacheMain, cacheThumb]) {
    for (const b of c.values()) { try { b.close?.(); } catch {} }
    c.clear();
  }
}

const inflight = new Map();
/* pdf.js does not support two concurrent render()/getOperatorList() calls on
   the same page proxy, and page.cleanup() from one will pull data out from
   under the other. The main view and the filmstrip both want page N, so every
   job for a page is chained behind the previous one. */
const pageLock = new Map();
function withPage(key, fn) {
  const prev = pageLock.get(key) || Promise.resolve();
  const next = prev.catch(() => {}).then(fn);
  pageLock.set(key, next.catch(() => {}));
  return next;
}

function renderPage(n, width, thumb = false) {
  const key = `${S.doc ? S.doc.id : '-'}|${n}|${Math.round(width)}|${S.theme}`;
  const cache = thumb ? cacheThumb : cacheMain;
  const hit = cache.get(key);
  if (hit) return Promise.resolve(hit);
  if (inflight.has(key)) return inflight.get(key);

  const job = withPage(`${S.doc ? S.doc.id : '-'}|${n}`, async () => {
    const page = await S.pdf.getPage(n);
    const base = page.getViewport({ scale: 1 });
    const scale = width / base.width;
    const vp = page.getViewport({ scale });
    const W = Math.max(1, Math.round(vp.width)), H = Math.max(1, Math.round(vp.height));

    const cv = document.createElement('canvas');
    cv.width = W; cv.height = H;
    const ctx = cv.getContext('2d', { willReadFrequently: true, alpha: false });
    ctx.fillStyle = '#fff';
    ctx.fillRect(0, 0, W, H);
    await page.render({ canvasContext: ctx, viewport: vp, background: '#ffffff' }).promise;

    if (S.theme !== 'light') {
      const rects = S.theme === 'smart' ? await imageRects(page, vp) : [];
      const img = ctx.getImageData(0, 0, W, H);
      const mask = S.theme === 'smart' ? buildMask(img, rects, W, H) : null;
      transformPixels(img, mask, S.theme);
      ctx.putImageData(img, 0, 0);
    }
    const bmp = await createImageBitmap(cv);
    cachePut(cache, key, bmp, thumb ? 80 : 12);
    return bmp;
  }).finally(() => inflight.delete(key));

  inflight.set(key, job);
  return job;
}

/* ════════════════════════════  library  ════════════════════════════ */
const fmtSize = b => b > 1048576 ? (b / 1048576).toFixed(1) + ' MB' : Math.round(b / 1024) + ' KB';
const allDocs = () => (S.lib?.subjects || []).flatMap(s => s.docs);
const findDoc = id => allDocs().find(d => d.id === id);

let pollTimer = null;
async function loadLibrary() {
  const r = await fetch('/api/library');
  S.lib = await r.json();
  renderRoots();
  renderSidebar();
  renderGrid();

  const pending = allDocs().filter(d => d.state !== 'ready' && d.state !== 'error');
  pending.slice(0, 24).forEach(d => fetch('/api/convert?id=' + d.id));
  clearTimeout(pollTimer);
  if (pending.length) pollTimer = setTimeout(loadLibrary, 1400);
}

function renderRoots() {
  const folder = '<svg viewBox="0 0 16 16" width="13" height="13"><path fill="currentColor" d="M1.5 4.2c0-.94.76-1.7 1.7-1.7h2.4c.45 0 .88.18 1.2.5l.9.9h5.1c.94 0 1.7.76 1.7 1.7v6c0 .94-.76 1.7-1.7 1.7H3.2c-.94 0-1.7-.76-1.7-1.7z"/></svg>';
  $('#rootList').innerHTML = (S.lib.roots || []).map(r =>
    `<div class="src" data-path="${esc(r.path)}" title="${esc(r.path)}">
       ${folder}<span class="src-name">${esc(r.name)}</span>
       <button class="src-x" title="Remove from library">✕</button>
     </div>`).join('');
}

function renderSidebar() {
  const nav = $('#subjectNav');
  const subs = S.lib.subjects;
  const total = allDocs().length;
  const item = (key, label, count) =>
    `<button class="item ${S.subject === key ? 'on' : ''}" data-sub="${key}">
       <span class="dot"></span><span class="nm">${esc(label)}</span><span class="count">${count}</span>
     </button>`;
  nav.innerHTML = item('all', 'All material', total) + '<div class="nav-gap"></div>' +
    subs.map(s => item(s.name, s.name, s.docs.length)).join('');
}

function esc(s) { return String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c])); }

function renderGrid() {
  const grid = $('#grid');
  const q = S.filter.trim().toLowerCase();
  const subs = S.lib.subjects
    .filter(s => S.subject === 'all' || s.name === S.subject)
    .map(s => ({ ...s, docs: s.docs.filter(d => !q || d.name.toLowerCase().includes(q)) }))
    .filter(s => s.docs.length);

  const shown = subs.flatMap(s => s.docs).length;
  $('#libTitle').textContent = S.subject === 'all' ? 'All material' : S.subject;
  const nRoots = (S.lib.roots || []).length;
  const where = nRoots > 1 ? `${nRoots} folders` : S.lib.root.replace(/^\/Users\/[^/]+/, '~');
  $('#libSub').textContent = shown ? `${shown} deck${shown === 1 ? '' : 's'} · ${where}` : 'Nothing matches';
  $('#libEmpty').hidden = !!allDocs().length;
  grid.hidden = !allDocs().length;

  grid.innerHTML = subs.map(s => {
    const head = (S.subject === 'all' && S.lib.subjects.length > 1)
      ? `<div class="sec-head">${esc(s.name)}<span class="n">${s.docs.length}</span></div>` : '';
    return head + s.docs.map(card).join('');
  }).join('');
}

function card(d) {
  const pos = store.get(`sv:pos:${d.id}`, 0);
  const stars = store.get(`sv:stars:${d.id}`, []).length;
  const pct = d.pages && pos ? Math.round(pos / d.pages * 100) : 0;
  const art = d.state === 'ready'
    ? `<img src="/api/thumb?id=${d.id}" loading="lazy" alt="">`
    : `<div class="ph">${d.state === 'error'
        ? '⚠︎<br>Could not convert' : '<div class="spinner"></div>Converting…'}</div>`;
  return `<button class="card" data-id="${d.id}">
    <div class="card-art">
      ${art}
      <span class="badge">${d.ext}</span>
      ${stars ? `<span class="badge star">★ ${stars}</span>` : ''}
      ${d.notes ? `<span class="card-note">✎ ${d.notes}</span>` : ''}
      ${pct ? `<div class="card-bar"><i style="width:${pct}%"></i></div>` : ''}
    </div>
    <div class="card-name">${esc(d.name)}</div>
    <div class="card-meta">${d.pages ? d.pages + ' slides · ' : ''}${fmtSize(d.size)}${pct ? ` · ${pct}%` : ''}</div>
  </button>`;
}

/* ════════════════════════════  viewer  ════════════════════════════ */
function showScreen(which) {
  $('#library').hidden = which !== 'library';
  $('#viewer').hidden = which !== 'viewer';
  $('#graph').hidden = which !== 'graph';
  document.body.dataset.screen = which;
  renderTabs();
}

/* ── tabs ───────────────────────────────────────────────────────────
   S mirrors the *active* tab. Switching stashes S back into the old tab
   and adopts the new one, so the rest of the viewer code stays unaware
   that more than one deck is open. Render caches are keyed by document,
   so switching back to a tab is instant. */
const TABS = [];
let cur = null;
const TAB_FIELDS = ['doc', 'pdf', 'page', 'total', 'aspect', 'zoom', 'fitMode',
                    'stars', 'text', 'textDone', 'notes'];

function stash() { if (cur) for (const k of TAB_FIELDS) cur[k] = S[k]; }
function adopt(t) { cur = t; for (const k of TAB_FIELDS) S[k] = t[k]; }

function newTab(d) {
  return { docId: d.id, doc: d, pdf: null, page: 1, total: 0, aspect: 16 / 9,
           zoom: 1, fitMode: 'fit', stars: new Set(), text: null, textDone: 0,
           notes: {}, loading: false };
}

/* In full screen (and zen) the tab strip is folded into the toolbar row —
   a strip of its own would cost ~42px of slide for no gain. */
function relocateTabs() {
  const bar = $('#tabbar');
  const inline = document.body.classList.contains('fs') || document.body.classList.contains('zen');
  const host = inline ? $('.vbar-left') : document.body;
  if (bar.parentElement === host) return;
  if (inline) host.appendChild(bar);
  else document.body.insertBefore(bar, $('#screens'));
  syncDragZone();
}

let zenTimer = null;
function setZen(on) {
  document.body.classList.toggle('zen', on);
  document.body.classList.remove('peek');
  $('#zenBtn').classList.toggle('on', on);
  relocateTabs();
  if (on) {
    const h = document.createElement('div');
    h.className = 'zen-hint';
    h.textContent = 'Press H or Esc to bring the controls back · move the pointer to the top edge to peek';
    document.body.appendChild(h);
    clearTimeout(zenTimer);
    zenTimer = setTimeout(() => h.remove(), 2600);
  } else {
    $('.zen-hint')?.remove();
  }
  if (S.pdf) show(S.page, false);
}

addEventListener('mousemove', e => {
  if (!document.body.classList.contains('zen')) return;
  const near = e.clientY < 6;
  const away = e.clientY > 110;
  if (near) document.body.classList.add('peek');
  else if (away) document.body.classList.remove('peek');
});

/* Tell the shell where the tab strip stops being interactive, so it can put a
   real AppKit drag region there (the web view otherwise eats titlebar drags). */
function syncDragZone() {
  if (!native) return;
  if (document.body.classList.contains('fs') || document.body.classList.contains('zen')) {
    return send('dragZone', { x: 1e6, h: 0 });
  }
  const bar = $('#tabbar').getBoundingClientRect();
  const end = $('#newTabBtn').getBoundingClientRect().right;
  send('dragZone', { x: Math.round(end + 6), h: Math.round(bar.height) });
}

function renderTabs() {
  const onLib = document.body.dataset.screen === 'library';
  $('#newTabBtn').classList.toggle('on', onLib);
  $('#tabs').innerHTML = TABS.map((t, i) => {
    const n = Object.keys(t.notes || {}).length;
    return `<button class="tab ${t === cur && !onLib ? 'on' : ''}" data-i="${i}" title="${esc(t.doc.name)}">
      ${n ? '<span class="tab-dot"></span>' : ''}
      <span class="tab-name">${esc(t.doc.name)}</span>
      <span class="tab-x" title="Close tab (⌘W)">✕</span>
    </button>`;
  }).join('');
  requestAnimationFrame(syncDragZone);
}

async function openDoc(id, opts = {}) {
  const open = TABS.find(t => t.docId === id);
  if (open) return switchTab(open);
  const d = findDoc(id);
  if (!d) return;

  const t = newTab(d);
  if (opts.background && cur) {
    TABS.push(t); renderTabs();
    loadTabDoc(t).then(renderTabs);
    toast(`${d.name} opened in a tab`);
    return;
  }
  await flushNote();
  stash();
  TABS.push(t);
  adopt(t);
  showScreen('viewer');
  renderTabs();
  await activate(t);
}

async function switchTab(t) {
  if (t === cur) { showScreen('viewer'); return; }
  await flushNote();
  stash();
  adopt(t);
  showScreen('viewer');
  renderTabs();
  await activate(t);
}

function cycleTab(dir) {
  if (TABS.length < 2) return;
  const i = TABS.indexOf(cur);
  switchTab(TABS[(i + dir + TABS.length) % TABS.length]);
}

async function closeTab(t) {
  const i = TABS.indexOf(t);
  if (i < 0) return;
  if (t === cur) await flushNote();
  TABS.splice(i, 1);
  try { t.pdf?.destroy(); } catch {}
  if (t !== cur) return renderTabs();

  cur = null;
  if (TABS.length) {
    const next = TABS[Math.min(i, TABS.length - 1)];
    adopt(next);
    renderTabs();
    showScreen('viewer');
    await activate(next);
  } else {
    S.doc = null; S.pdf = null; S.total = 0;
    renderTabs();
    toLibrary();
  }
}

/* Fill a tab with its PDF. Safe to run for a background tab. */
async function loadTabDoc(t) {
  if (t.loading || t.pdf) return !!t.pdf;
  t.loading = true;
  try {
    if (t.doc.state !== 'ready') {
      if (cur === t) setLoading(true, 'Converting with LibreOffice…',
                                'First open only — the PDF is cached afterwards.');
      fetch('/api/convert?id=' + t.docId);
      if (!await waitReady(t.docId, t)) return false;
      t.doc.state = 'ready';
    }
    const pdf = await pdfjsLib.getDocument({
      url: '/api/pdf?id=' + t.docId, disableRange: true, disableStream: true }).promise;
    t.pdf = pdf;
    t.total = pdf.numPages;
    const p1 = await pdf.getPage(1);
    const vp = p1.getViewport({ scale: 1 });
    t.aspect = vp.width / vp.height;
    t.stars = new Set(store.get(`sv:stars:${t.docId}`, []));
    t.page = clamp(store.get(`sv:pos:${t.docId}`, 1), 1, t.total);
    try { t.notes = await (await fetch('/api/notes?id=' + t.docId)).json(); } catch { t.notes = {}; }
    if (cur === t) adopt(t);
    return true;
  } catch (e) {
    if (cur === t) setLoading(true, 'Could not open this document', String(e?.message || e));
    return false;
  } finally {
    t.loading = false;
  }
}

async function activate(t) {
  closePanels();
  $('#docTitle').textContent = t.doc.name;
  $('#docSub').textContent = t.doc.subject;
  $('.vbar').dataset.title = t.doc.name;
  send('title', { text: t.doc.name });
  $('#filmstrip').hidden = !S.strip;
  $('#stripBtn').classList.toggle('on', S.strip);
  $('#notes').hidden = !store.get('sv:notes', false);
  $('#notesBtn').classList.toggle('on', !$('#notes').hidden);

  if (!t.pdf) {
    setLoading(true, 'Opening…');
    if (!await loadTabDoc(t)) return;
    if (cur !== t) return;
    adopt(t);
  }
  $('#pageTotal').textContent = S.total;
  setLoading(false);
  await show(S.page, false);
  buildStrip();
  showNote();
  if (!t.text) indexText();
}

async function waitReady(id, tab) {
  for (;;) {
    await new Promise(r => setTimeout(r, 600));
    if (tab && !TABS.includes(tab)) return false;          // tab was closed
    const st = await (await fetch('/api/state?id=' + id)).json();
    if (st.state === 'ready') { const d = findDoc(id); if (d) d.state = 'ready'; return true; }
    if (st.state === 'error') {
      if (!tab || cur === tab) {
        setLoading(true, 'Conversion failed', st.message || '');
        $('#loading .spinner').style.display = 'none';
      }
      return false;
    }
  }
}

let loadTimer = null;
function setLoading(on, text, sub) {
  clearTimeout(loadTimer);
  const el = $('#loading');
  if (!on) { el.hidden = true; return; }
  $('#loadingText').textContent = text || 'Rendering…';
  $('#loadingSub').textContent = sub || '';
  $('#loading .spinner').style.display = '';
  el.hidden = false;
}

function stageBox() {
  const st = $('#stage');
  return { w: Math.max(120, st.clientWidth - 32), h: Math.max(120, st.clientHeight - 32) };
}
function targetWidth() {
  const { w, h } = stageBox();
  const base = S.fitMode === 'width' ? w : Math.min(w, h * S.aspect);
  return Math.max(240, base * S.zoom);
}

async function show(n, animate = true) {
  if (!S.pdf) return;
  const target = clamp(n, 1, S.total);
  if (target !== S.page) flushNote();     // never lose what was just typed
  S.page = target;
  const tok = ++S.token;
  const cssW = targetWidth();
  const dpr = Math.min(window.devicePixelRatio || 1, 2);
  const devW = Math.min(Math.round(cssW * dpr), 3600);

  updateChrome();
  loadTimer = setTimeout(() => { if (tok === S.token) setLoading(true, 'Rendering slide ' + S.page + '…'); }, 220);

  let bmp;
  try { bmp = await renderPage(S.page, devW); }
  catch (e) { if (tok === S.token) setLoading(true, 'Could not render slide', String(e?.message || e)); return; }
  if (tok !== S.token) return;
  clearTimeout(loadTimer);
  setLoading(false);

  const cv = $('#slide');
  cv.width = bmp.width; cv.height = bmp.height;
  cv.style.width = cssW + 'px';
  cv.getContext('2d', { alpha: false }).drawImage(bmp, 0, 0);

  const wrap = $('#slideWrap');
  $('#stage').classList.toggle('zoomed', S.zoom > 1.02);
  if (animate) { wrap.classList.remove('turn'); void wrap.offsetWidth; wrap.classList.add('turn'); }

  if (S.doc) store.set(`sv:pos:${S.doc.id}`, S.page);
  idle(() => prefetch(devW));
}

function idle(fn) {
  (window.requestIdleCallback || (f => setTimeout(f, 60)))(fn, { timeout: 800 });
}
function prefetch(devW) {
  for (const n of [S.page + 1, S.page + 2, S.page - 1]) {
    if (n >= 1 && n <= S.total) renderPage(n, devW).catch(() => {});
  }
}

function updateChrome() {
  $('#pageInput').value = S.page;
  $('#prevBtn').disabled = S.page <= 1;
  $('#nextBtn').disabled = S.page >= S.total;
  const starred = S.stars.has(S.page);
  $('#starBtn').classList.toggle('starred', starred);
  $('#slideBadge').hidden = !starred;
  $('#slideBadge').textContent = '★';
  $('#scrubFill').style.width = (S.total > 1 ? (S.page - 1) / (S.total - 1) * 100 : 0) + '%';
  const at = p => (S.total > 1 ? (p - 1) / (S.total - 1) * 100 : 0);
  $('#scrubMarks').innerHTML =
    [...S.stars].map(p => `<i style="left:${at(p)}%"></i>`).join('') +
    Object.keys(S.notes || {}).map(p => `<i class="note" style="left:${at(+p)}%"></i>`).join('');
  $('#footLeft').textContent = `${S.doc?.subject || ''} — ${S.doc?.name || ''}`;
  $('#footRight').textContent = `${S.page} of ${S.total}` + (S.stars.size ? `  ·  ★ ${S.stars.size}` : '')
    + (S.zoom > 1.02 ? `  ·  ${Math.round(S.zoom * 100)}%` : '');
  $$('#filmstrip .fs-item').forEach(el =>
    el.classList.toggle('on', +el.dataset.n === S.page));
  const on = $(`#filmstrip .fs-item[data-n="${S.page}"]`);
  if (on && S.strip) on.scrollIntoView({ block: 'nearest' });
  if (!$('#notes').hidden) showNote();
}

/* ─────────────  filmstrip  ───────────── */
let stripObs = null;
function buildStrip() {
  const strip = $('#filmstrip');
  stripObs?.disconnect();
  strip.innerHTML = '';
  if (!S.pdf) return;
  const frag = document.createDocumentFragment();
  for (let n = 1; n <= S.total; n++) {
    const b = document.createElement('button');
    b.className = 'fs-item'; b.dataset.n = n;
    b.innerHTML = `<div class="fs-ph"></div><span class="fs-num">${n}</span>` +
      (S.stars.has(n) ? '<span class="fs-star">★</span>' : '') +
      (S.notes && S.notes[n] ? '<span class="fs-note"></span>' : '');
    frag.appendChild(b);
  }
  strip.appendChild(frag);
  stripObs = new IntersectionObserver(es => {
    for (const e of es) if (e.isIntersecting) { stripObs.unobserve(e.target); paintThumb(e.target); }
  }, { root: strip, rootMargin: '320px' });
  $$('#filmstrip .fs-item').forEach(el => stripObs.observe(el));
  updateChrome();
}
async function paintThumb(el) {
  const n = +el.dataset.n;
  try {
    const bmp = await renderPage(n, 272, true);
    const cv = document.createElement('canvas');
    cv.width = bmp.width; cv.height = bmp.height;
    cv.getContext('2d', { alpha: false }).drawImage(bmp, 0, 0);
    el.querySelector('.fs-ph')?.replaceWith(cv);
  } catch {}
}

/* ─────────────  text search  ───────────── */
async function indexText() {
  const doc = S.doc, pdf = S.pdf;
  S.text = new Array(S.total).fill('');
  for (let n = 1; n <= S.total; n++) {
    if (S.doc !== doc || S.pdf !== pdf) return;
    try {
      S.text[n - 1] = await withPage(`${doc.id}|${n}`, async () => {
        const p = await pdf.getPage(n);
        const tc = await p.getTextContent();
        return tc.items.map(i => i.str).join(' ').replace(/\s+/g, ' ').trim();
      });
    } catch {}
    S.textDone = n;
    if (n % 12 === 0) {
      await new Promise(r => setTimeout(r, 0));
      if (!$('#searchPanel').hidden) runSearch();
    }
  }
  if (!$('#searchPanel').hidden) runSearch();
}

function runSearch() {
  const q = $('#searchInput').value.trim();
  const list = $('#searchResults');
  if (!S.text) { list.innerHTML = '<div class="panel-empty">Indexing…</div>'; return; }
  if (q.length < 2) {
    $('#searchCount').textContent = S.textDone < S.total ? `${S.textDone}/${S.total}` : '';
    list.innerHTML = '<div class="panel-empty">Type at least two characters</div>';
    return;
  }
  const needle = q.toLowerCase();
  const out = [];
  for (let i = 0; i < S.text.length; i++) {
    const t = S.text[i]; if (!t) continue;
    const at = t.toLowerCase().indexOf(needle);
    if (at < 0) continue;
    const from = Math.max(0, at - 42);
    const snip = (from ? '…' : '') + t.slice(from, at) +
      '<mark>' + esc(t.substr(at, q.length)) + '</mark>' + esc(t.slice(at + q.length, at + q.length + 90)) + '…';
    out.push(`<button class="res" data-n="${i + 1}"><div class="p">Slide ${i + 1}</div><div class="t">${snip}</div></button>`);
    if (out.length > 120) break;
  }
  $('#searchCount').textContent = out.length + (S.textDone < S.total ? ` · ${S.textDone}/${S.total}` : '');
  list.innerHTML = out.length ? out.join('') : '<div class="panel-empty">No matches</div>';
}

/* ─────────────  stars  ───────────── */
function toggleStar() {
  if (!S.doc) return;
  S.stars.has(S.page) ? S.stars.delete(S.page) : S.stars.add(S.page);
  store.set(`sv:stars:${S.doc.id}`, [...S.stars].sort((a, b) => a - b));
  const el = $(`#filmstrip .fs-item[data-n="${S.page}"]`);
  if (el) {
    el.querySelector('.fs-star')?.remove();
    if (S.stars.has(S.page)) el.insertAdjacentHTML('beforeend', '<span class="fs-star">★</span>');
  }
  toast(S.stars.has(S.page) ? `★ Slide ${S.page} starred` : `Slide ${S.page} unstarred`);
  updateChrome();
  if (!$('#starPanel').hidden) renderStars();
}
function jumpStar(dir) {
  const arr = [...S.stars].sort((a, b) => a - b);
  if (!arr.length) return toast('No starred slides yet — press S');
  const next = dir > 0 ? arr.find(p => p > S.page) ?? arr[0]
                       : [...arr].reverse().find(p => p < S.page) ?? arr[arr.length - 1];
  show(next);
}
function renderStars() {
  const arr = [...S.stars].sort((a, b) => a - b);
  $('#starCount').textContent = arr.length;
  $('#starList').innerHTML = arr.length
    ? arr.map(n => `<button class="res" data-n="${n}"><div class="p">Slide ${n}</div>
        <div class="t">${esc((S.text?.[n - 1] || '').slice(0, 110) || 'No text on this slide')}</div></button>`).join('')
    : '<div class="panel-empty">Press <b>S</b> on a slide worth coming back to</div>';
}

/* ── per-slide notes ────────────────────────────────────────────────
   Saved on the server (JSON per deck) rather than in localStorage, so a
   cleared cache cannot take your revision notes with it. Writes are
   debounced, and always flushed before the page or tab changes. */
let notePending = null, noteTimer = null;

function noteCountText() {
  const n = Object.keys(S.notes || {}).length;
  return n ? `${n} note${n === 1 ? '' : 's'} in this deck` : '';
}

function showNote() {
  const el = $('#noteText');
  if (document.activeElement === el && notePending) return;   // mid-edit
  el.value = (S.notes || {})[S.page] || '';
  $('#notesPage').textContent = S.total ? `Slide ${S.page} of ${S.total}` : '';
  $('#noteCount').textContent = noteCountText();
}

function queueNote(docId, page, text) {
  notePending = { docId, page, text };
  clearTimeout(noteTimer);
  noteTimer = setTimeout(flushNote, 400);
}

async function flushNote() {
  clearTimeout(noteTimer);
  const p = notePending;
  notePending = null;
  if (!p) return;
  try {
    await fetch(`/api/notes?id=${p.docId}&page=${p.page}`, { method: 'POST', body: p.text });
    $('#noteStatus').textContent = 'Saved';
    setTimeout(() => {
      if ($('#noteStatus').textContent === 'Saved') $('#noteStatus').textContent = '';
    }, 1400);
  } catch {
    $('#noteStatus').textContent = 'Could not save';
  }
  renderTabs();
}

function noteEdited() {
  if (!S.doc) return;
  const v = $('#noteText').value;
  if (!S.notes) S.notes = {};
  if (v.trim()) S.notes[S.page] = v; else delete S.notes[S.page];
  if (cur) cur.notes = S.notes;
  $('#noteStatus').textContent = 'Saving…';
  $('#noteCount').textContent = noteCountText();
  queueNote(S.doc.id, S.page, v);

  const it = $(`#filmstrip .fs-item[data-n="${S.page}"]`);
  if (it) {
    it.querySelector('.fs-note')?.remove();
    if (S.notes[S.page]) it.insertAdjacentHTML('beforeend', '<span class="fs-note"></span>');
  }
}

function toggleNotes(force) {
  const el = $('#notes');
  const on = force === undefined ? el.hidden : force;
  el.hidden = !on;
  $('#notesBtn').classList.toggle('on', on);
  store.set('sv:notes', on);
  if (on) { showNote(); setTimeout(() => $('#noteText').focus(), 30); }
  if (S.pdf) show(S.page, false);
}

function jumpNote(dir) {
  const arr = Object.keys(S.notes || {}).map(Number).sort((a, b) => a - b);
  if (!arr.length) return toast('No notes in this deck yet');
  const next = dir > 0 ? arr.find(p => p > S.page) ?? arr[0]
                       : [...arr].reverse().find(p => p < S.page) ?? arr[arr.length - 1];
  show(next);
}

function exportNotes() {
  const arr = Object.keys(S.notes || {}).map(Number).sort((a, b) => a - b);
  if (!arr.length) return toast('No notes in this deck yet');
  const md = `# ${S.doc.name} — notes\n\n` +
    arr.map(p => `## Slide ${p}\n\n${S.notes[p]}\n`).join('\n');
  send('copyText', { text: md });
  toast(`Copied ${arr.length} note${arr.length === 1 ? '' : 's'} as Markdown`);
}

let toastTimer = null;
function toast(msg) {
  const t = $('#toast');
  t.textContent = msg; t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.hidden = true; }, 1500);
}
function closePanels() { $('#searchPanel').hidden = true; $('#starPanel').hidden = true; }

/* ════════════════════════════  events  ════════════════════════════ */
function setTheme(t) {
  S.theme = t; store.set('sv:theme', t);
  $$('#themeSeg button').forEach(b => b.classList.toggle('on', b.dataset.theme === t));
  if (S.pdf) { show(S.page, false); repaintStrip(); }
}
function repaintStrip() {
  $$('#filmstrip .fs-item').forEach(el => {
    const cv = el.querySelector('canvas');
    if (cv) { const ph = document.createElement('div'); ph.className = 'fs-ph'; cv.replaceWith(ph); }
    stripObs?.unobserve(el); stripObs?.observe(el);
  });
}
function setZoom(z) {
  S.zoom = clamp(z, 0.5, 5);
  if (S.zoom <= 1.02) { S.zoom = 1; $('#stage').scrollTo(0, 0); }
  show(S.page, false);
}

$('#grid').addEventListener('click', e => {
  const c = e.target.closest('.card');
  if (c) openDoc(c.dataset.id, { background: e.metaKey || e.ctrlKey });
});
$('#grid').addEventListener('auxclick', e => {
  const c = e.target.closest('.card');
  if (c && e.button === 1) { e.preventDefault(); openDoc(c.dataset.id, { background: true }); }
});
$('#subjectNav').addEventListener('click', e => {
  const it = e.target.closest('.item'); if (!it) return;
  S.subject = it.dataset.sub; renderSidebar(); renderGrid();
});
$('#libFilter').addEventListener('input', e => { S.filter = e.target.value; renderGrid(); });
$('#addRootBtn').onclick = () => send('chooseRoot');
$('#emptyChoose').onclick = () => send('chooseRoot');
$('#rootList').addEventListener('click', e => {
  const row = e.target.closest('.src'); if (!row) return;
  if (e.target.closest('.src-x')) send('removeRoot', { path: row.dataset.path });
});

$('#backBtn').onclick = () => toLibrary();
$('#prevBtn').onclick = () => show(S.page - 1);
$('#nextBtn').onclick = () => show(S.page + 1);
$('#fsBtn').onclick = () => send('toggleFullScreen');
$('#zenBtn').onclick = () => setZen(!document.body.classList.contains('zen'));
$('#starBtn').onclick = toggleStar;
$('#stripBtn').onclick = () => {
  S.strip = !S.strip; store.set('sv:strip', S.strip);
  $('#filmstrip').hidden = !S.strip;
  $('#stripBtn').classList.toggle('on', S.strip);
  show(S.page, false);
};
$('#themeSeg').addEventListener('click', e => {
  const b = e.target.closest('button'); if (b) setTheme(b.dataset.theme);
});

$('#tabs').addEventListener('click', e => {
  const tab = e.target.closest('.tab'); if (!tab) return;
  const t = TABS[+tab.dataset.i]; if (!t) return;
  if (e.target.closest('.tab-x')) closeTab(t); else switchTab(t);
});
$('#tabs').addEventListener('auxclick', e => {
  const tab = e.target.closest('.tab');
  if (tab && e.button === 1) { e.preventDefault(); const t = TABS[+tab.dataset.i]; if (t) closeTab(t); }
});
$('#newTabBtn').onclick = () => toLibrary();

$('#notesBtn').onclick = () => toggleNotes();
$('#notesClose').onclick = () => toggleNotes(false);
$('#noteText').addEventListener('input', noteEdited);
$('#noteText').addEventListener('blur', flushNote);
$('#notesPrev').onclick = () => jumpNote(-1);
$('#notesNext').onclick = () => jumpNote(1);
$('#notesExport').onclick = exportNotes;

$('#searchBtn').onclick = () => openSearch();
$('#searchClose').onclick = () => { $('#searchPanel').hidden = true; };
$('#searchInput').addEventListener('input', runSearch);
$('#searchResults').addEventListener('click', e => {
  const r = e.target.closest('.res'); if (r) show(+r.dataset.n);
});
$('#starClose').onclick = () => { $('#starPanel').hidden = true; };
$('#starList').addEventListener('click', e => {
  const r = e.target.closest('.res'); if (r) show(+r.dataset.n);
});
$('#helpClose').onclick = () => { $('#help').hidden = true; };
function openSearch() {
  closePanels();
  $('#searchPanel').hidden = false;
  $('#searchInput').focus(); $('#searchInput').select();
  runSearch();
}
function openStars() { closePanels(); $('#starPanel').hidden = false; renderStars(); }

$('#filmstrip').addEventListener('click', e => {
  const it = e.target.closest('.fs-item'); if (it) show(+it.dataset.n);
});

const pageInput = $('#pageInput');
pageInput.addEventListener('focus', () => pageInput.select());
pageInput.addEventListener('keydown', e => {
  e.stopPropagation();
  if (e.key === 'Enter') { show(parseInt(pageInput.value, 10) || S.page); pageInput.blur(); }
  if (e.key === 'Escape') { pageInput.value = S.page; pageInput.blur(); }
});
pageInput.addEventListener('blur', () => { pageInput.value = S.page; });

/* scrubber */
const scrub = $('#scrub');
let scrubbing = false;
const scrubTo = e => {
  const r = scrub.getBoundingClientRect();
  show(Math.round(clamp((e.clientX - r.left) / r.width, 0, 1) * (S.total - 1)) + 1, false);
};
scrub.addEventListener('pointerdown', e => { scrubbing = true; scrub.setPointerCapture(e.pointerId); scrubTo(e); });
scrub.addEventListener('pointermove', e => { if (scrubbing) scrubTo(e); });
scrub.addEventListener('pointerup', () => { scrubbing = false; });

/* wheel / trackpad: swipe between slides, ⌘-scroll to zoom */
let wheelLock = 0;
$('#stage').addEventListener('wheel', e => {
  if (e.metaKey || e.ctrlKey) { e.preventDefault(); setZoom(S.zoom * (e.deltaY < 0 ? 1.12 : 0.89)); return; }
  if (S.zoom > 1.02) return;                 // zoomed in — let it scroll
  e.preventDefault();
  const now = Date.now();
  if (now < wheelLock) return;
  const d = Math.abs(e.deltaY) > Math.abs(e.deltaX) ? e.deltaY : e.deltaX;
  if (Math.abs(d) < 18) return;
  wheelLock = now + 190;
  show(S.page + (d > 0 ? 1 : -1));
}, { passive: false });

function toLibrary() {
  S.token++;
  showScreen('library');
  send('title', { text: 'SlideView' });
  closePanels();
  renderGrid();
}

/* keyboard */
let goBuf = '', goTimer = null;
addEventListener('keydown', e => {
  const tag = e.target.tagName;
  const typing = tag === 'INPUT' || tag === 'TEXTAREA';

  if (e.key === 'Escape') {
    if (!$('#help').hidden) return void ($('#help').hidden = true);
    if (document.body.classList.contains('zen')) return setZen(false);
    if (!$('#searchPanel').hidden || !$('#starPanel').hidden) return closePanels();
    if (typing) return e.target.blur();
    if (document.body.dataset.screen === 'viewer') return toLibrary();
    if (document.body.dataset.screen === 'graph') return toLibrary();
    if (cur) { showScreen('viewer'); renderTabs(); }
    return;
  }
  if ((e.metaKey || e.ctrlKey) && e.key === 'f') {
    e.preventDefault();
    if (document.body.dataset.screen === 'viewer') openSearch(); else $('#libFilter').focus();
    return;
  }
  if ((e.metaKey || e.ctrlKey) && e.key === 'r') { e.preventDefault(); loadLibrary(); toast('Rescanned'); return; }

  // Tab commands work even while the notes box has focus.
  if (e.metaKey && !e.altKey) {
    if (e.key === 't') { e.preventDefault(); toLibrary(); return; }
    if (e.key === 'w') { e.preventDefault(); if (cur) closeTab(cur); return; }
    if (e.key >= '1' && e.key <= '9') {
      const t = TABS[+e.key - 1];
      if (t) { e.preventDefault(); switchTab(t); }
      return;
    }
  }
  if (e.ctrlKey && e.key === 'Tab') { e.preventDefault(); cycleTab(e.shiftKey ? -1 : 1); return; }
  if (typing) return;

  if (document.body.dataset.screen === 'library') {
    if (e.key === 'Enter') { const f = $('#grid .card'); if (f) openDoc(f.dataset.id); }
    if (e.key === '?') $('#help').hidden = false;
    if (e.key === 'm' || e.key === 'M') openMap();
    return;
  }
  if (e.metaKey || e.ctrlKey || e.altKey) return;

  const k = e.key;
  if (k >= '0' && k <= '9') {
    goBuf += k; clearTimeout(goTimer);
    toast('Go to slide ' + goBuf);
    goTimer = setTimeout(() => { show(parseInt(goBuf, 10)); goBuf = ''; }, 750);
    e.preventDefault(); return;
  }
  switch (k) {
    case 'ArrowRight': case 'ArrowDown': case 'PageDown': case 'n': case 'j':
      e.preventDefault(); show(S.page + 1); break;
    case 'ArrowLeft': case 'ArrowUp': case 'PageUp': case 'p': case 'k':
      e.preventDefault(); show(S.page - 1); break;
    case ' ':
      e.preventDefault(); show(S.page + (e.shiftKey ? -1 : 1)); break;
    case 'Home': e.preventDefault(); show(1); break;
    case 'End':  e.preventDefault(); show(S.total); break;
    case 'd': case 'D': {
      const order = ['smart', 'invert', 'dim', 'light'];
      const t = order[(order.indexOf(S.theme) + 1) % order.length];
      setTheme(t); toast('Appearance: ' + t); break;
    }
    case 'f': case 'F': send('toggleFullScreen'); break;
    case 'h': case 'H': setZen(!document.body.classList.contains('zen')); break;
    case 't': case 'T': $('#stripBtn').click(); break;
    case 'n': case 'N': toggleNotes(); break;
    case 's': e.shiftKey ? openStars() : toggleStar(); break;
    case 'S': openStars(); break;
    case '[': jumpStar(-1); break;
    case ']': jumpStar(1); break;
    case '+': case '=': setZoom(S.zoom * 1.25); break;
    case '-': case '_': setZoom(S.zoom / 1.25); break;
    case '0': S.fitMode = 'fit'; setZoom(1); break;
    case 'w': case 'W': S.fitMode = S.fitMode === 'width' ? 'fit' : 'width'; setZoom(1);
      toast(S.fitMode === 'width' ? 'Fit width' : 'Fit slide'); break;
    case '/': e.preventDefault(); openSearch(); break;
    case '?': $('#help').hidden = false; break;
  }
});

/* resize */
let rsTimer = null;
new ResizeObserver(() => {
  clearTimeout(rsTimer);
  syncDragZone();
  rsTimer = setTimeout(() => { if (S.pdf && !$('#viewer').hidden) show(S.page, false); }, 130);
}).observe($('#stage'));
addEventListener('resize', syncDragZone);

/* right-click -> native menu (Copy, Google Lens, Gemini, open in Chrome…) */
function slideMenu(e, id, page) {
  if (!native) return;                     // plain browser: keep the default menu
  e.preventDefault();
  send('contextMenu', { id, page, x: e.clientX, y: e.clientY });
}
$('#stage').addEventListener('contextmenu', e => { if (S.doc) slideMenu(e, S.doc.id, S.page); });
$('#filmstrip').addEventListener('contextmenu', e => {
  const it = e.target.closest('.fs-item');
  if (it && S.doc) slideMenu(e, S.doc.id, +it.dataset.n);
});
$('#grid').addEventListener('contextmenu', e => {
  const c = e.target.closest('.card');
  if (c) slideMenu(e, c.dataset.id, 1);
});

/* Commands the native menu bar dispatches into the page. */
const COMMANDS = {
  next:      () => show(S.page + 1),
  prev:      () => show(S.page - 1),
  first:     () => show(1),
  last:      () => show(S.total),
  goto:      () => { $('#pageInput').focus(); $('#pageInput').select(); },
  zen:       () => setZen(!document.body.classList.contains('zen')),
  strip:     () => $('#stripBtn').click(),
  notes:     () => toggleNotes(),
  search:    () => { if (document.body.dataset.screen === 'viewer') openSearch(); else $('#libFilter').focus(); },
  star:      () => toggleStar(),
  starList:  () => openStars(),
  nextStar:  () => jumpStar(1),
  prevStar:  () => jumpStar(-1),
  zoomIn:    () => setZoom(S.zoom * 1.25),
  zoomOut:   () => setZoom(S.zoom / 1.25),
  fit:       () => { S.fitMode = 'fit'; setZoom(1); },
  fitWidth:  () => { S.fitMode = 'width'; setZoom(1); },
  newTab:    () => toLibrary(),
  closeTab:  () => { if (cur) closeTab(cur); },
  nextTab:   () => cycleTab(1),
  prevTab:   () => cycleTab(-1),
  library:   () => toLibrary(),
  exportNotes: () => exportNotes(),
  reveal:    () => { if (S.doc) send('reveal', { id: S.doc.id }); },
  rescan:    () => { loadLibrary(); toast('Rescanned'); },
  help:      () => { $('#help').hidden = false; }
};

/* native bridge */
window.sv = {
  cmd(name) {
    if (name.startsWith('theme:')) return setTheme(name.slice(6));
    const fn = COMMANDS[name];
    if (fn) fn();
  },
  /* Files opened from Finder, dropped on the window, or picked with ⌘O. */
  async openPaths(ids) {
    await loadLibrary();
    for (let i = 0; i < ids.length; i++) {
      await openDoc(ids[i], { background: i > 0 });
    }
  },
  fullScreen(on) {
    S.fs = on;
    document.body.classList.toggle('fs', on);
    if (!on && document.body.classList.contains('zen')) setZen(false);
    relocateTabs();
    if (S.pdf) show(S.page, false);
  },
  rootChanged() { S.subject = 'all'; loadLibrary(); },
  newTab() { toLibrary(); },
  closeTab() { if (cur) closeTab(cur); },
  toast(msg) { toast(msg); }
};

setTheme(S.theme);
relocateTabs();
syncDragZone();
loadLibrary().then(() => send('ready'));

/* ═══════════════════════════  MAP  ═══════════════════════════
   A force-directed map of the library: which documents are linked by
   something you wrote, and which cover the same ground. Written from
   scratch — Obsidian is closed source and Logseq is AGPL-3.0, so neither
   could contribute code here.
   ═══════════════════════════════════════════════════════════════════ */
const G = {
  nodes: [], edges: [], mode: 'all',
  tx: 0, ty: 0, scale: 1, alpha: 0, raf: 0,
  hover: null, drag: null, panning: false, px: 0, py: 0, loaded: false
};

function subjectColour(name) {
  let h = 0;
  for (let i = 0; i < name.length; i++) h = (h * 31 + name.charCodeAt(i)) >>> 0;
  return `hsl(${h % 360} 62% 58%)`;
}

async function openMap(rebuild = false) {
  showScreen('graph');
  const load = $('#graphLoading');
  if (!G.loaded || rebuild) {
    load.hidden = false;
    for (;;) {
      const r = await fetch('/api/graph' + (rebuild ? '?rebuild=1' : ''));
      const d = await r.json();
      if (d.ready) { ingest(d); break; }
      $('#graphProgress').textContent =
        d.total ? `${d.progress} of ${d.total} documents` : 'starting…';
      rebuild = false;
      await new Promise(res => setTimeout(res, 700));
    }
    load.hidden = true;
  }
  sizeCanvas();
  fit(260);            // settle first so the opening view frames everything
  G.alpha = 0.35;
  tick();
}

function ingest(d) {
  const cx = 0, cy = 0;
  G.nodes = d.nodes.map((n, i) => {
    const a = (i / d.nodes.length) * Math.PI * 2;
    const r = 180 + (i % 7) * 26;
    return { ...n, x: cx + Math.cos(a) * r, y: cy + Math.sin(a) * r, vx: 0, vy: 0,
             rad: Math.max(6, Math.min(20, 5 + Math.sqrt(n.pages || 1) * 1.7)),
             col: subjectColour(n.subject || '') };
  });
  const byId = Object.fromEntries(G.nodes.map(n => [n.id, n]));
  G.edges = d.edges.map(e => ({ ...e, s: byId[e.a], t: byId[e.b] }))
                   .filter(e => e.s && e.t);
  G.loaded = true;

  const subjects = [...new Set(G.nodes.map(n => n.subject))].sort();
  $('#graphLegend').innerHTML = subjects.map(sub =>
    `<span><i style="background:${subjectColour(sub)}"></i>${esc(sub)}</span>`).join('');
  const links = G.edges.filter(e => e.kind === 'link').length;
  $('#graphSub').textContent =
    `${G.nodes.length} documents · ${G.edges.length - links} shared-topic links · ${links} written links`;
}

function activeEdges() {
  return G.mode === 'link' ? G.edges.filter(e => e.kind === 'link') : G.edges;
}

function step() {
  const nodes = G.nodes, edges = activeEdges();
  const k = 0.0016;
  for (let i = 0; i < nodes.length; i++) {
    const a = nodes[i];
    for (let j = i + 1; j < nodes.length; j++) {
      const b = nodes[j];
      let dx = b.x - a.x, dy = b.y - a.y;
      let d2 = dx * dx + dy * dy;
      if (d2 < 1) { d2 = 1; dx = Math.random() - 0.5; dy = Math.random() - 0.5; }
      const f = 5200 / d2;                       // repulsion
      const d = Math.sqrt(d2);
      const fx = (dx / d) * f, fy = (dy / d) * f;
      a.vx -= fx; a.vy -= fy; b.vx += fx; b.vy += fy;
    }
    a.vx -= a.x * k;                              // gentle pull to centre
    a.vy -= a.y * k;
  }
  for (const e of edges) {
    const dx = e.t.x - e.s.x, dy = e.t.y - e.s.y;
    const d = Math.max(1, Math.hypot(dx, dy));
    const rest = e.kind === 'link' ? 90 : 150;
    const f = (d - rest) * 0.0032 * (e.kind === 'link' ? 1.6 : e.w);
    const fx = (dx / d) * f, fy = (dy / d) * f;
    e.s.vx += fx; e.s.vy += fy; e.t.vx -= fx; e.t.vy -= fy;
  }
  for (const n of nodes) {
    if (n === G.drag) { n.vx = n.vy = 0; continue; }
    n.vx *= 0.86; n.vy *= 0.86;
    n.x += n.vx * G.alpha; n.y += n.vy * G.alpha;
  }
  G.alpha = Math.max(0, G.alpha - 0.004);
}

function sizeCanvas() {
  const cv = $('#graphCanvas');
  const dpr = Math.min(window.devicePixelRatio || 1, 2);
  const r = cv.getBoundingClientRect();
  cv.width = Math.max(1, Math.round(r.width * dpr));
  cv.height = Math.max(1, Math.round(r.height * dpr));
  G.dpr = dpr; G.w = r.width; G.h = r.height;
}

/// Settle the layout headlessly, then frame the whole map in the viewport.
function fit(settle = 0) {
  if (!G.nodes.length) return;
  const keep = G.alpha;
  G.alpha = 1;
  for (let i = 0; i < settle; i++) step();
  G.alpha = keep;

  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const n of G.nodes) {
    x0 = Math.min(x0, n.x - n.rad); x1 = Math.max(x1, n.x + n.rad);
    y0 = Math.min(y0, n.y - n.rad); y1 = Math.max(y1, n.y + n.rad);
  }
  const pad = 70, lw = Math.max(1, x1 - x0), lh = Math.max(1, y1 - y0);
  G.scale = clamp(Math.min((G.w - pad * 2) / lw, (G.h - pad * 2 - 40) / lh), 0.25, 1.6);
  G.tx = -((x0 + x1) / 2) * G.scale;
  G.ty = -((y0 + y1) / 2) * G.scale;
}

function draw() {
  const cv = $('#graphCanvas');
  const ctx = cv.getContext('2d');
  ctx.setTransform(G.dpr, 0, 0, G.dpr, 0, 0);
  ctx.clearRect(0, 0, G.w, G.h);
  ctx.save();
  ctx.translate(G.w / 2 + G.tx, G.h / 2 + G.ty);
  ctx.scale(G.scale, G.scale);

  const hov = G.hover;
  const near = hov ? new Set(activeEdges().flatMap(e =>
    e.s === hov ? [e.t.id] : e.t === hov ? [e.s.id] : [])) : null;

  for (const e of activeEdges()) {
    const lit = hov && (e.s === hov || e.t === hov);
    ctx.strokeStyle = e.kind === 'link'
      ? `rgba(10,132,255,${lit ? .95 : .5})`
      : `rgba(255,255,255,${lit ? .5 : 0.06 + e.w * 0.16})`;
    ctx.lineWidth = (e.kind === 'link' ? 1.6 : 0.8 + e.w * 1.6) / G.scale;
    ctx.beginPath();
    ctx.moveTo(e.s.x, e.s.y);
    ctx.lineTo(e.t.x, e.t.y);
    ctx.stroke();
  }

  for (const n of G.nodes) {
    const dim = hov && n !== hov && !near.has(n.id);
    ctx.globalAlpha = dim ? 0.25 : 1;
    ctx.beginPath();
    ctx.arc(n.x, n.y, n.rad, 0, Math.PI * 2);
    ctx.fillStyle = n.col;
    ctx.fill();
    if (n.notes) {
      ctx.lineWidth = 2 / G.scale;
      ctx.strokeStyle = '#ffd426';
      ctx.stroke();
    }
    if (n === hov || G.scale > 0.85 || n.rad > 13) {
      ctx.globalAlpha = dim ? 0.25 : 1;
      ctx.fillStyle = '#f2f2f5';
      ctx.font = `${n === hov ? 600 : 400} ${11 / G.scale}px -apple-system, sans-serif`;
      ctx.textAlign = 'center';
      ctx.fillText(n.name.length > 26 ? n.name.slice(0, 25) + '…' : n.name,
                   n.x, n.y + n.rad + 12 / G.scale);
    }
  }
  ctx.globalAlpha = 1;
  ctx.restore();
}

function tick() {
  cancelAnimationFrame(G.raf);
  const run = () => {
    if (G.alpha > 0.002 || G.drag) step();
    draw();
    G.raf = requestAnimationFrame(run);
  };
  G.raf = requestAnimationFrame(run);
}

function toGraph(ev) {
  const r = $('#graphCanvas').getBoundingClientRect();
  return {
    x: (ev.clientX - r.left - G.w / 2 - G.tx) / G.scale,
    y: (ev.clientY - r.top - G.h / 2 - G.ty) / G.scale
  };
}
function nodeAt(p) {
  for (let i = G.nodes.length - 1; i >= 0; i--) {
    const n = G.nodes[i];
    if (Math.hypot(n.x - p.x, n.y - p.y) <= n.rad + 5) return n;
  }
  return null;
}

const gcv = $('#graphCanvas');
gcv.addEventListener('mousemove', e => {
  const p = toGraph(e);
  if (G.drag) { G.drag.x = p.x; G.drag.y = p.y; G.alpha = Math.max(G.alpha, 0.28); return; }
  if (G.panning) {
    G.tx += e.clientX - G.px; G.ty += e.clientY - G.py;
    G.px = e.clientX; G.py = e.clientY;
    return;
  }
  const n = nodeAt(p);
  G.hover = n;
  const tip = $('#graphTip');
  if (n) {
    tip.hidden = false;
    tip.innerHTML = `<b>${esc(n.name)}</b><div class="meta">${esc(n.subject)} · ${n.ext.toUpperCase()}`
      + `${n.pages ? ' · ' + n.pages + ' pages' : ''}${n.notes ? ' · ✎ ' + n.notes : ''}</div>`
      + (n.terms?.length ? `<div class="terms">${n.terms.map(esc).join(' · ')}</div>` : '');
    const r = gcv.getBoundingClientRect();
    tip.style.left = Math.min(e.clientX - r.left + 14, r.width - 260) + 'px';
    tip.style.top = Math.min(e.clientY - r.top + 14, r.height - 90) + 'px';
  } else tip.hidden = true;
});
gcv.addEventListener('mousedown', e => {
  const n = nodeAt(toGraph(e));
  if (n) { G.drag = n; }
  else { G.panning = true; G.px = e.clientX; G.py = e.clientY; gcv.classList.add('dragging'); }
});
addEventListener('mouseup', () => {
  G.drag = null; G.panning = false; gcv.classList.remove('dragging');
});
gcv.addEventListener('dblclick', () => { fit(60); });
gcv.addEventListener('click', e => {
  const n = nodeAt(toGraph(e));
  if (n) openDoc(n.id);
});
gcv.addEventListener('wheel', e => {
  e.preventDefault();
  const before = toGraph(e);
  G.scale = clamp(G.scale * (e.deltaY < 0 ? 1.1 : 0.9), 0.25, 3);
  const after = toGraph(e);
  G.tx += (after.x - before.x) * G.scale;
  G.ty += (after.y - before.y) * G.scale;
}, { passive: false });

$('#mapBtn').onclick = () => openMap();
$('#graphBack').onclick = () => toLibrary();
$('#graphRebuild').onclick = () => { G.loaded = false; openMap(true); };
$('#graphMode').addEventListener('click', e => {
  const b = e.target.closest('button'); if (!b) return;
  G.mode = b.dataset.mode;
  $$('#graphMode button').forEach(x => x.classList.toggle('on', x === b));
  G.alpha = 0.7;
});
new ResizeObserver(() => { if (!$('#graph').hidden) sizeCanvas(); }).observe($('#graph'));
COMMANDS.map = () => openMap();
COMMANDS.fitMap = () => fit(60);
