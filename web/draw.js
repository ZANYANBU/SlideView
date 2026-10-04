/* The drawing editor: the real Excalidraw (MIT), vendored under
   /vendor/excalidraw, wrapped in just enough glue to make a drawing behave like
   every other SlideView document — an ordinary .excalidraw file on disk that
   saves itself and has a thumbnail in the library.

   Runs in an iframe so Excalidraw's React tree and stylesheet stay out of the
   rest of the app, and so none of it is loaded until a drawing is opened. */
import * as X from '/vendor/excalidraw/excalidraw.js';

const { React, createRoot, Excalidraw, WelcomeScreen,
        serializeAsJSON, serializeLibraryAsJSON, restoreLibraryItems,
        exportToBlob, getSceneVersion } = X;
const h = React.createElement;

const q = new URLSearchParams(location.search);
const ID = q.get('id');
const NAME = q.get('name') || 'drawing';
const RENDER = q.get('render') === '1';          // headless: export a PNG and stop
const root = document.getElementById('root');

function message(title, detail) {
  root.innerHTML = '';
  const box = document.createElement('div');
  box.className = 'sv-msg';
  const b = document.createElement('b'); b.textContent = title; box.appendChild(b);
  if (detail) { const c = document.createElement('code'); c.textContent = detail; box.appendChild(c); }
  root.appendChild(box);
}

/* ── loading ────────────────────────────────────────────────────────
   A file that will not parse must never be replaced by an empty scene, so a
   failed load returns null and the editor is not mounted at all. A genuinely
   empty file (a note that was just created) is a valid blank canvas. */
async function loadScene() {
  const r = await fetch('/api/text?id=' + ID);
  if (!r.ok) throw new Error('The file could not be read.');
  const text = await r.text();
  if (!text.trim()) return { elements: [], appState: {}, files: {} };
  const data = JSON.parse(text);
  if (!data || typeof data !== 'object' || (data.type && data.type !== 'excalidraw')) {
    throw new Error('This is not an Excalidraw scene.');
  }
  return {
    elements: Array.isArray(data.elements) ? data.elements : [],
    appState: data.appState || {},
    files: data.files || {}
  };
}

async function loadLibrary() {
  try {
    const d = await (await fetch('/api/drawlib')).json();
    return restoreLibraryItems(d.libraryItems || d.library || [], 'unpublished');
  } catch { return []; }
}

/* ── the picture of the scene used for thumbnails and the slide view ──
   Always exported light, on the scene's own background: SlideView's smart
   invert darkens it the same way it does any other document. */
async function snapshot(elements, appState, files) {
  const live = elements.filter(e => !e.isDeleted);
  if (!live.length) {
    const cv = document.createElement('canvas');
    cv.width = 1600; cv.height = 900;
    const ctx = cv.getContext('2d');
    const bg = appState.viewBackgroundColor;
    ctx.fillStyle = bg && bg !== 'transparent' ? bg : '#ffffff';
    ctx.fillRect(0, 0, cv.width, cv.height);
    const blob = await new Promise(res => cv.toBlob(res, 'image/png'));
    return { blob, scale: 2 };
  }
  let scale = 2;
  const blob = await exportToBlob({
    elements: live,
    files,
    appState: {
      ...appState,
      exportBackground: true,
      exportWithDarkMode: false,
      exportEmbedScene: false,
      viewBackgroundColor: appState.viewBackgroundColor || '#ffffff'
    },
    mimeType: 'image/png',
    exportPadding: 32,
    getDimensions: (w, hh) => {
      scale = Math.max(0.25, Math.min(2, 4200 / Math.max(w, hh)));
      return { width: Math.round(w * scale), height: Math.round(hh * scale), scale };
    }
  });
  return { blob, scale };
}

/* ── headless render (thumbnails for drawings never opened here) ──── */
if (RENDER) {
  const post = body => window.webkit?.messageHandlers?.drawing?.postMessage(body);
  try {
    const scene = await loadScene();
    const { blob, scale } = await snapshot(scene.elements, scene.appState, scene.files);
    const b64 = await new Promise((res, rej) => {
      const fr = new FileReader();
      fr.onload = () => res(String(fr.result).split(',')[1]);
      fr.onerror = rej;
      fr.readAsDataURL(blob);
    });
    post({ png: b64, scale });
  } catch (e) {
    post({ error: String(e && e.message || e) });
  }
} else {
  await mountEditor();
}

/* ── the editor ─────────────────────────────────────────────────────── */
async function mountEditor() {
  let scene, libraryItems;
  try {
    [scene, libraryItems] = await Promise.all([loadScene(), loadLibrary()]);
  } catch (e) {
    message('This drawing could not be opened',
            String(e && e.message || e) + '\nNothing was changed on disk.');
    window.svDraw = { flush: async () => {}, zoom() {}, fit() {} };
    return;
  }

  const status = t => { try { parent.svDrawStatus && parent.svDrawStatus(t); } catch {} };
  let api = null;
  let armed = false;                 // ignore the change events fired while loading
  let lastVersion = -1, lastMeta = '';
  let dirty = false, previewDirty = false;
  let saveTimer = null, previewTimer = null;
  let chain = Promise.resolve();
  let theme = localStorage.getItem('sv:drawTheme') || 'dark';

  const metaOf = (appState, files) =>
    [appState.viewBackgroundColor, appState.gridModeEnabled, appState.gridSize,
     Object.keys(files || {}).length].join('|');

  function onChange(elements, appState, files) {
    if (appState.theme && appState.theme !== theme) {
      theme = appState.theme;
      localStorage.setItem('sv:drawTheme', theme);
    }
    if (!armed) return;
    const v = getSceneVersion(elements), m = metaOf(appState, files);
    if (v === lastVersion && m === lastMeta) return;
    lastVersion = v; lastMeta = m;
    dirty = true; previewDirty = true;
    status('Saving…');
    clearTimeout(saveTimer);
    saveTimer = setTimeout(save, 800);
  }

  function save() {
    clearTimeout(saveTimer);
    if (!api || !dirty) return chain;
    dirty = false;
    const body = serializeAsJSON(api.getSceneElements(), api.getAppState(), api.getFiles(), 'local');
    chain = chain.then(async () => {
      const r = await fetch('/api/text?id=' + ID, { method: 'POST', body });
      if (!r.ok) throw new Error('rejected');
      status('Saved');
      clearTimeout(previewTimer);
      previewTimer = setTimeout(preview, 2500);
    }).catch(() => { dirty = true; status('Not saved'); });
    return chain;
  }

  function preview() {
    clearTimeout(previewTimer);
    if (!api || !previewDirty) return chain;
    previewDirty = false;
    chain = chain.then(async () => {
      const { blob, scale } = await snapshot(api.getSceneElements(), api.getAppState(), api.getFiles());
      await fetch(`/api/preview?id=${ID}&scale=${scale}`, { method: 'POST', body: blob });
    }).catch(() => { previewDirty = true; });
    return chain;
  }

  // What the rest of the app calls into.
  window.svDraw = {
    async flush() { await save(); await preview(); await chain; },
    zoom(f) {
      if (!api) return;
      const z = api.getAppState().zoom.value;
      api.updateScene({ appState: { zoom: { value: Math.max(0.1, Math.min(30, z * f)) } } });
    },
    fit() { if (api) api.scrollToContent(api.getSceneElements(), { fitToContent: true, animate: true }); }
  };

  addEventListener('beforeunload', () => {
    if (!dirty || !api) return;
    const body = serializeAsJSON(api.getSceneElements(), api.getAppState(), api.getFiles(), 'local');
    navigator.sendBeacon('/api/text?id=' + ID, body);
  });

  const App = () => h(Excalidraw, {
    excalidrawAPI: a => {
      api = a;
      // Arm autosave only once the loaded scene has settled, so merely opening
      // a drawing never rewrites the file.
      setTimeout(() => {
        lastVersion = getSceneVersion(a.getSceneElementsIncludingDeleted());
        lastMeta = metaOf(a.getAppState(), a.getFiles());
        armed = true;
      }, 700);
    },
    initialData: {
      elements: scene.elements,
      appState: { ...scene.appState, theme },
      files: scene.files,
      libraryItems,
      scrollToContent: true
    },
    onChange,
    onLibraryChange: items => {
      fetch('/api/drawlib', { method: 'POST', body: serializeLibraryAsJSON(items) }).catch(() => {});
    },
    name: NAME,
    langCode: 'en',
    autoFocus: true,
    handleKeyboardGlobally: true,
    validateEmbeddable: true,
    UIOptions: {
      canvasActions: {
        loadScene: true,
        saveToActiveFile: false,          // the file saves itself
        export: { saveFileToDisk: true },
        saveAsImage: true,
        toggleTheme: true,
        clearCanvas: true,
        changeViewBackgroundColor: true
      }
    }
  }, h(WelcomeScreen, null));

  root.innerHTML = '';
  createRoot(root).render(h(App));
  window.focus();
}
