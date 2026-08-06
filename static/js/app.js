'use strict';
/**
 * Levititas v3.3 — Main Application
 * static/js/app.js
 *
 * All UI logic: sidebar, views, obfuscator, batch, history,
 * settings, status panel, keyboard shortcuts.
 * Depends on: themes.js, effects.js, brand.js
 */

/* ── Layer config ─────────────────────────────────────────────── */
const LAYERS = [
  { key:'mangleNames',    icon:'🔀', name:'Name Mangling',     desc:'Rename identifiers',     tier:'base', weight:8  },
  { key:'encryptStrings', icon:'🔐', name:'String Encryption', desc:'Rolling-XOR cipher',     tier:'base', weight:12 },
  { key:'encodeNumbers',  icon:'🔢', name:'Number Virtualiz.', desc:'Lambda chain encoding',  tier:'base', weight:8  },
  { key:'injectJunk',     icon:'🧬', name:'Dead Code',         desc:'Mutation injection',     tier:'base', weight:7  },
  { key:'antiDebug',      icon:'🛡️', name:'Anti-Debug',        desc:'Multi-layer hooks',      tier:'base', weight:8  },
  { key:'stripComments',  icon:'💬', name:'Strip Comments',    desc:'Remove all comments',    tier:'base', weight:2  },
  { key:'controlFlow',    icon:'🌀', name:'Control Flow',      desc:'State machine dispatch', tier:'cfg',  weight:15 },
  { key:'polymorphic',    icon:'🎲', name:'Polymorphic',       desc:'Unique output per run',  tier:'p2',   weight:10 },
  { key:'wrapEnv',        icon:'📦', name:'Env Wrapping',      desc:'Nested load() sandboxes',tier:'p2',   weight:10 },
  { key:'vmMode',         icon:'⚙️', name:'Custom VM',         desc:'Bytecode interpreter',   tier:'vm',   weight:15 },
  { key:'antiTamper',     icon:'🔒', name:'Anti-Tamper',       desc:'Continuous CRC check',   tier:'vm',   weight:5  },
];

const LAYER_WEIGHTS = Object.fromEntries(LAYERS.map(l => [l.key, l.weight]));

/* ── App state ────────────────────────────────────────────────── */
const state = {
  layers: Object.fromEntries(LAYERS.map(l => [l.key, true])),
  protectNames: [],
  target:    localStorage.getItem('lv33-target')    || 'lua54',
  determin:  localStorage.getItem('lv33-determin')  === '1',
  seed:      localStorage.getItem('lv33-seed')      || '',
  view:      'obfuscator',
  sidebar:   localStorage.getItem('lv33-sidebar')   !== '0',
  history:   JSON.parse(localStorage.getItem('lv33-history')  || '[]'),
  batchFiles:[],
  statusOpen:localStorage.getItem('lv33-status')    !== '0',
  settingsPanelOpen: false,
  ping:      null,
  engineStatus: 'loading',
};

/* ── DOM helpers ─────────────────────────────────────────────── */
const $  = id => document.getElementById(id);
const $$ = s  => document.querySelectorAll(s);
const $q = s  => document.querySelector(s);

/* ═══════════════════════════════════════════════════════════════
   INIT
   ═══════════════════════════════════════════════════════════════ */
document.addEventListener('DOMContentLoaded', () => {
  Effects.init();
  ThemeSystem.init();
  buildSidebar();
  buildSettingsPage();
  initTopbar();
  initObfuscator();
  initBatch();
  initHistory();
  initStatusPanel();
  initKeyboard();
  applySidebar(state.sidebar);
  switchView(state.view);
  checkEngineStatus();
  setInterval(checkEngineStatus, 30000);
  setInterval(updatePing, 8000);
});

/* ═══════════════════════════════════════════════════════════════
   SIDEBAR
   ═══════════════════════════════════════════════════════════════ */

function buildSidebar() {
  // Layer list
  const list = $('layerList');
  if (!list) return;
  list.innerHTML = LAYERS.map(l => `
    <div class="layer-item" data-key="${l.key}">
      <div class="layer-left">
        <span class="layer-emoji">${l.icon}</span>
        <div>
          <div class="layer-name">
            ${l.name}
            ${l.tier !== 'base' ? `<span class="layer-badge ${l.tier}">${l.tier.toUpperCase()}</span>` : ''}
          </div>
          <div class="layer-desc">${l.desc}</div>
        </div>
      </div>
      <div class="toggle ${state.layers[l.key] ? 'on' : ''}"
           data-key="${l.key}" data-tier="${l.tier}"></div>
    </div>
  `).join('');

  list.querySelectorAll('.toggle').forEach(sw => {
    sw.addEventListener('click', e => {
      const key = sw.dataset.key;
      state.layers[key] = !state.layers[key];
      sw.classList.toggle('on', state.layers[key]);
      updateStrength();
      syncSettingsPanel();
      e.stopPropagation();
    });
  });

  // Protect names
  const inp = $('protectInput');
  if (inp) {
    inp.addEventListener('keydown', e => {
      if ((e.key === 'Enter' || e.key === ',') && inp.value.trim()) {
        e.preventDefault();
        inp.value.split(',').map(s=>s.trim()).filter(Boolean).forEach(n => {
          if (!state.protectNames.includes(n)) state.protectNames.push(n);
        });
        inp.value = '';
        renderProtectTags();
      }
    });
  }

  // Collapse btn
  $('collapseBtn')?.addEventListener('click', () => applySidebar(false));
  $('expandBtn')  ?.addEventListener('click', () => applySidebar(true));
  $('mobileSidebarBtn')?.addEventListener('click', () => {
    $('sidebar').classList.add('mobile-open');
    $('sidebarBackdrop').style.display = 'block';
  });
  $('sidebarBackdrop')?.addEventListener('click', closeMobileSidebar);

  updateStrength();
}

function applySidebar(open) {
  state.sidebar = open;
  localStorage.setItem('lv33-sidebar', open ? '1' : '0');
  $('sidebar').classList.toggle('collapsed', !open);
}

function closeMobileSidebar() {
  $('sidebar').classList.remove('mobile-open');
  const bd = $('sidebarBackdrop');
  if (bd) bd.style.display = 'none';
}

function renderProtectTags() {
  const c = $('protectTags');
  if (!c) return;
  c.innerHTML = state.protectNames.map((n, i) => `
    <span class="protect-tag">${n}<button data-i="${i}">✕</button></span>
  `).join('');
  c.querySelectorAll('button').forEach(btn => {
    btn.addEventListener('click', () => {
      state.protectNames.splice(+btn.dataset.i, 1);
      renderProtectTags();
    });
  });
}

/* ═══════════════════════════════════════════════════════════════
   STRENGTH METER
   ═══════════════════════════════════════════════════════════════ */

function updateStrength() {
  let score = 0;
  for (const [key, w] of Object.entries(LAYER_WEIGHTS)) {
    if (state.layers[key]) score += w;
  }
  const fill  = $('strengthFill');
  const pct   = $('strengthPct');
  const grade = $('strengthGrade');
  if (!fill) return;
  fill.style.width = score + '%';
  pct.textContent  = score + '%';
  let color, label;
  if      (score >= 90) { color='var(--success)';  label='ELITE';  }
  else if (score >= 75) { color='var(--accent-2)'; label='STRONG'; }
  else if (score >= 55) { color='var(--warning)';  label='MEDIUM'; }
  else if (score >= 30) { color='var(--warning)';  label='WEAK';   }
  else                  { color='var(--error)';    label='BARE';   }
  fill.style.background  = color;
  pct.style.color        = color;
  if (grade) {
    grade.textContent     = label;
    grade.style.background= color + '22';
    grade.style.color     = color;
  }
}

/* ═══════════════════════════════════════════════════════════════
   NAVIGATION
   ═══════════════════════════════════════════════════════════════ */

function switchView(view) {
  state.view = view;
  $$('.nav-item').forEach(el => el.classList.toggle('active', el.dataset.view === view));
  $$('.view').forEach(el => el.classList.toggle('active', el.dataset.view === view));
  const titles = { obfuscator:'Obfuscator', batch:'Batch Mode', history:'History', settings:'Settings' };
  const title = $('topbarTitle');
  if (title) title.textContent = titles[view] || view;
  if (view === 'history') renderHistory();
  closeMobileSidebar();
}

function initTopbar() {
  $$('.nav-item').forEach(el => {
    el.addEventListener('click', () => switchView(el.dataset.view));
  });
  $('themeToggleBtn')?.addEventListener('click', () => {
    const themes = Object.keys(ThemeSystem.BUILTIN);
    const cur = ThemeSystem.getState().current;
    const idx = themes.indexOf(cur);
    ThemeSystem.applyTheme(themes[(idx + 1) % themes.length]);
  });
}

/* ═══════════════════════════════════════════════════════════════
   OBFUSCATION SETTINGS PANEL
   ═══════════════════════════════════════════════════════════════ */

function initSettingsPanel() {
  const panel = $('obfSettingsPanel');
  const btn   = $('settingsPanelBtn');
  if (!panel || !btn) return;

  btn.addEventListener('click', () => {
    state.settingsPanelOpen = !state.settingsPanelOpen;
    panel.classList.toggle('open', state.settingsPanelOpen);
    btn.classList.toggle('active', state.settingsPanelOpen);
  });

  // Close on outside click
  document.addEventListener('click', e => {
    if (state.settingsPanelOpen &&
        !panel.contains(e.target) &&
        !btn.contains(e.target)) {
      state.settingsPanelOpen = false;
      panel.classList.remove('open');
      btn.classList.remove('active');
    }
  });

  syncSettingsPanel();
}

function syncSettingsPanel() {
  // Sync toggle cards in settings panel with state
  $$('[data-obf-key]').forEach(card => {
    const key = card.dataset.obfKey;
    if (key in state.layers) {
      card.classList.toggle('on', state.layers[key]);
      const toggle = card.querySelector('.toggle');
      if (toggle) toggle.classList.toggle('on', state.layers[key]);
    }
  });

  // Sync target
  const tgt = $('targetSelect');
  if (tgt) tgt.value = state.target;

  // Sync deterministic
  const det = $('deterministicToggle');
  if (det) det.classList.toggle('on', state.determin);

  // Sync seed input
  const si = $('seedInput');
  if (si) {
    si.value    = state.seed;
    si.disabled = !state.determin;
  }
}

/* ═══════════════════════════════════════════════════════════════
   OBFUSCATOR
   ═══════════════════════════════════════════════════════════════ */

function initObfuscator() {
  const inEd  = $('inputEditor');
  const inLn  = $('inLines');
  const outEd = $('outputEditor');
  const outLn = $('outLines');

  if (!inEd) return;

  // Line numbers
  const updateLines = (ed, ln) => {
    const n = ed.value.split('\n').length;
    if (parseInt(ln.dataset.c||0) === n) return;
    ln.dataset.c = n;
    let s = '';
    for (let i=1;i<=n;i++) s+=i+'\n';
    ln.textContent = s;
  };
  inEd.addEventListener('input',  () => updateLines(inEd, inLn));
  inEd.addEventListener('scroll', () => { inLn.scrollTop = inEd.scrollTop; });
  outEd.addEventListener('scroll',() => { outLn.scrollTop = outEd.scrollTop; });
  inEd.addEventListener('keydown', e => {
    if (e.key === 'Tab') {
      e.preventDefault();
      const s = inEd.selectionStart, v = inEd.value;
      inEd.value = v.slice(0,s)+'    '+v.slice(inEd.selectionEnd);
      inEd.selectionStart = inEd.selectionEnd = s + 4;
      updateLines(inEd, inLn);
    }
  });
  updateLines(inEd, inLn);

  // Drag-drop
  const inputPane = $('inputPane');
  inputPane?.addEventListener('dragover',  e => { e.preventDefault(); inputPane.classList.add('drag-over'); });
  inputPane?.addEventListener('dragleave', () => inputPane.classList.remove('drag-over'));
  inputPane?.addEventListener('drop', e => {
    e.preventDefault();
    inputPane.classList.remove('drag-over');
    const f = e.dataTransfer.files[0];
    if (!f) return;
    readFile(f);
  });

  // Upload btn
  $('uploadBtn')?.addEventListener('click', () => $('fileInput').click());
  $('fileInput')?.addEventListener('change', () => {
    const f = $('fileInput').files[0];
    if (f) readFile(f);
    $('fileInput').value = '';
  });

  function readFile(f) {
    if (!f.name.endsWith('.lua')) { showToast('Only .lua files accepted', 'error'); return; }
    const rd = new FileReader();
    rd.onload = ev => {
      inEd.value = ev.target.result;
      updateLines(inEd, inLn);
      showToast(`Loaded: ${f.name}`, 'success');
    };
    rd.readAsText(f);
  }

  // Clear / example
  $('clearBtn')?.addEventListener('click', () => {
    inEd.value = ''; outEd.value = '';
    $('statsBar').style.display = 'none';
    updateLines(inEd, inLn); updateLines(outEd, outLn);
  });

  $('exampleBtn')?.addEventListener('click', () => {
    inEd.value = `-- Levititas v3.3 Example
local VERSION = "3.3.0"
local SECRET_KEY = "super_secret_token_abc123"
local API_URL = "https://api.example.com/v2"

local function hashStr(input, salt)
    local result = ""
    for i = 1, #input do
        local byte = string.byte(input, i)
        local keyByte = string.byte(salt, ((i-1) % #salt) + 1)
        result = result .. string.char(byte ~ keyByte)
    end
    return result
end

local function validate(user, pass)
    local hash = hashStr(pass, SECRET_KEY)
    local db = {
        admin = hashStr("admin_pass_2024", SECRET_KEY),
        guest = hashStr("guest_pass_2024", SECRET_KEY),
    }
    return db[user] == hash
end

local data = {
    level   = 99,
    coins   = 50000,
    premium = true,
    token   = SECRET_KEY,
}

if validate("admin", "admin_pass_2024") then
    print("[AUTH] Welcome! Level:", data.level)
    for k, v in pairs(data) do
        print("  " .. k .. " =", tostring(v))
    end
end`;
    updateLines(inEd, inLn);
    showToast('Example loaded!', 'success');
  });

  // Copy / Download output
  $('copyBtn')?.addEventListener('click', () => {
    if (!outEd.value) { showToast('Nothing to copy', 'error'); return; }
    navigator.clipboard.writeText(outEd.value)
      .then(() => showToast('Copied!', 'success'))
      .catch(() => { outEd.select(); document.execCommand('copy'); showToast('Copied!', 'success'); });
  });

  $('downloadBtn')?.addEventListener('click', () => {
    if (!outEd.value) { showToast('Nothing to download', 'error'); return; }
    dlText(outEd.value, 'obfuscated.lua');
    showToast('Downloaded!', 'success');
  });

  // Run button
  $('runBtn')?.addEventListener('click', runObfuscate);

  // Settings panel
  initSettingsPanel();

  // Target select
  $('targetSelect')?.addEventListener('change', e => {
    state.target = e.target.value;
    localStorage.setItem('lv33-target', state.target);
    updateSettingsCards();
  });

  // Deterministic toggle
  $('deterministicToggle')?.addEventListener('click', () => {
    state.determin = !state.determin;
    localStorage.setItem('lv33-determin', state.determin ? '1' : '0');
    const si = $('seedInput');
    if (si) si.disabled = !state.determin;
    syncSettingsPanel();
  });

  $('seedInput')?.addEventListener('input', e => {
    state.seed = e.target.value;
    localStorage.setItem('lv33-seed', state.seed);
  });

  $('seedRefreshBtn')?.addEventListener('click', () => {
    const s = Math.floor(Math.random() * 0xFFFFFFFF);
    state.seed = String(s);
    const si = $('seedInput');
    if (si) si.value = state.seed;
    localStorage.setItem('lv33-seed', state.seed);
  });

  updateSettingsCards();
}

function updateSettingsCards() {
  // Update the compact settings bar cards
  const tgtCard = $('targetCard');
  if (tgtCard) {
    tgtCard.querySelector('.settings-card-value').textContent = state.target;
  }
  const detCard = $('deterministicCard');
  if (detCard) {
    detCard.classList.toggle('active', state.determin);
    detCard.querySelector('.settings-card-value').textContent = state.determin ? 'ON' : 'OFF';
  }
}

/* ── LOADING MESSAGES ────────────────────────────────────────── */
const LOADING_MSGS = [
  'Parsing AST…', 'Flattening control flow…', 'Encrypting strings…',
  'Virtualizing numbers…', 'Building VM bytecode…', 'Shuffling opcodes…',
  'Injecting dead code…', 'Wrapping environments…', 'Applying polymorphic transforms…',
  'Encoding constants…', 'Generating header…', 'Finalizing…',
];

async function runObfuscate() {
  const inEd  = $('inputEditor');
  const outEd = $('outputEditor');
  const src   = inEd.value.trim();
  if (!src) { showToast('Paste some Lua code first', 'error'); return; }

  $('runBtn').classList.add('loading');
  $('paneOverlay').style.display = 'flex';
  $('paneOverlayError').style.display = 'none';
  $('statsBar').style.display = 'none';
  outEd.value = '';

  // Cycle loading messages
  let msgIdx = 0;
  const msgEl = $('loadingMsg');
  if (msgEl) msgEl.textContent = LOADING_MSGS[0];
  const msgTimer = setInterval(() => {
    msgIdx = (msgIdx + 1) % LOADING_MSGS.length;
    if (msgEl) msgEl.textContent = LOADING_MSGS[msgIdx];
  }, 700);

  try {
    const opts = {
      ...state.layers,
      protectNames: state.protectNames,
      target: state.target,
    };
    if (state.determin && state.seed) opts.seed = parseInt(state.seed);

    const res  = await fetch('/api/obfuscate', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ source: src, options: opts }),
    });
    const data = await res.json();
    clearInterval(msgTimer);

    if (!data.ok) {
      $('paneOverlay').style.display   = 'none';
      $('paneOverlayError').style.display = 'flex';
      $('paneOverlayErrorMsg').textContent = data.error || 'Obfuscation failed.';
      showToast(data.error || 'Failed', 'error');
      return;
    }

    outEd.value = data.result;
    // Sync line numbers
    const outLn = $('outLines');
    const n = outEd.value.split('\n').length;
    let s=''; for(let i=1;i<=n;i++) s+=i+'\n';
    if (outLn) { outLn.textContent = s; outLn.dataset.c = n; }

    // Stats
    const st = data.stats || {};
    $('statsBar').style.display = 'flex';
    $('statOrig').textContent   = fmtBytes(st.originalBytes);
    $('statObf').textContent    = fmtBytes(st.obfuscatedBytes);
    $('statRatio').textContent  = (st.ratio||0)+'×';
    $('statLines').textContent  = (st.originalLines||0)+'→'+(st.obfuscatedLines||0);
    $('statTime').textContent   = (data.elapsed||0)+'s';
    const noteEl = $('statNote');
    if (noteEl) noteEl.textContent = data.note || '';

    showToast('Obfuscated! ✓', 'success');
    saveHistory(src, data.result, st, data.elapsed);

  } catch(err) {
    clearInterval(msgTimer);
    $('paneOverlay').style.display   = 'none';
    $('paneOverlayError').style.display = 'flex';
    $('paneOverlayErrorMsg').textContent = 'Network error: ' + err.message;
    showToast('Network error', 'error');
  } finally {
    $('runBtn').classList.remove('loading');
    $('paneOverlay').style.display = 'none';
  }
}

/* ═══════════════════════════════════════════════════════════════
   BATCH MODE
   ═══════════════════════════════════════════════════════════════ */

function initBatch() {
  const drop  = $('batchDrop');
  const input = $('batchFileInput');

  $('batchBrowseBtn')?.addEventListener('click', () => input?.click());
  input?.addEventListener('change', () => { addBatchFiles(input.files); input.value=''; });

  drop?.addEventListener('dragover',  e => { e.preventDefault(); drop.classList.add('drag-over'); });
  drop?.addEventListener('dragleave', () => drop.classList.remove('drag-over'));
  drop?.addEventListener('drop', e => {
    e.preventDefault(); drop.classList.remove('drag-over');
    addBatchFiles(e.dataTransfer.files);
  });
  drop?.addEventListener('click', () => input?.click());

  $('runBatchBtn')?.addEventListener('click', runBatch);
  $('clearBatchBtn')?.addEventListener('click', () => {
    state.batchFiles = [];
    renderBatchList();
    const dlBtn = $('downloadAllBtn');
    if (dlBtn) dlBtn.style.display = 'none';
  });
  $('downloadAllBtn')?.addEventListener('click', downloadAll);
}

function addBatchFiles(files) {
  for (const f of files) {
    if (!f.name.endsWith('.lua')) { showToast('Skipping: '+f.name,'error'); continue; }
    state.batchFiles.push({ file:f, name:f.name, size:f.size, status:'pending', result:null });
  }
  renderBatchList();
}

function renderBatchList() {
  const list    = $('batchList');
  const actions = $('batchActions');
  if (!list) return;
  if (!state.batchFiles.length) {
    list.style.display = 'none';
    if (actions) actions.style.display = 'none';
    return;
  }
  list.style.display = 'block';
  if (actions) actions.style.display = 'flex';
  list.innerHTML = state.batchFiles.map((f,i) => `
    <div class="batch-file-row">
      <svg viewBox="0 0 24 24" width="14" height="14" style="color:var(--text-3);flex-shrink:0">
        <path d="M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8z" stroke="currentColor" stroke-width="2" fill="none"/>
      </svg>
      <span class="batch-file-name">${esc(f.name)}</span>
      <span class="batch-file-size">${fmtBytes(f.size)}</span>
      <span class="batch-file-status ${f.status}">${
        {pending:'Pending',running:'⏳ Running',done:'✓ Done',error:'✗ Error'}[f.status]
      }</span>
      ${f.status==='done'?`<button class="pane-btn batch-dl" data-i="${i}">⬇ DL</button>`:''}
      <button class="pane-btn batch-rm" data-i="${i}" style="margin-left:auto;">✕</button>
    </div>
  `).join('');
  list.querySelectorAll('.batch-rm').forEach(b => b.onclick = () => {
    state.batchFiles.splice(+b.dataset.i,1); renderBatchList();
  });
  list.querySelectorAll('.batch-dl').forEach(b => b.onclick = () => {
    const f = state.batchFiles[+b.dataset.i];
    if (f.result) dlText(f.result, f.name.replace('.lua','_obf.lua'));
  });
}

async function runBatch() {
  const pending = state.batchFiles.filter(f => f.status==='pending'||f.status==='error');
  if (!pending.length) { showToast('No pending files','error'); return; }
  $('runBatchBtn').disabled = true;
  let done = 0;
  for (const f of state.batchFiles) {
    if (f.status==='done') continue;
    f.status='running'; renderBatchList();
    try {
      const text = await f.file.text();
      const res  = await fetch('/api/obfuscate',{
        method:'POST', headers:{'Content-Type':'application/json'},
        body:JSON.stringify({source:text, options:{...state.layers, protectNames:state.protectNames, target:state.target}}),
      });
      const d = await res.json();
      f.status = d.ok ? 'done' : 'error';
      if (d.ok) { f.result=d.result; done++; }
    } catch { f.status='error'; }
    renderBatchList();
  }
  $('runBatchBtn').disabled = false;
  showToast(`Done! ${done} file(s) obfuscated.`, 'success');
  if (done > 0) { const b=$('downloadAllBtn'); if(b) b.style.display='inline-flex'; }
}

async function downloadAll() {
  const done = state.batchFiles.filter(f=>f.status==='done'&&f.result);
  if (!done.length) { showToast('No completed files','error'); return; }
  for (const f of done) {
    await new Promise(r=>setTimeout(r,180));
    dlText(f.result, f.name.replace('.lua','_obf.lua'));
  }
  showToast(`Downloading ${done.length} file(s)…`,'success');
}

/* ═══════════════════════════════════════════════════════════════
   HISTORY
   ═══════════════════════════════════════════════════════════════ */

function initHistory() {
  $('clearHistoryBtn')?.addEventListener('click', () => {
    state.history=[];
    localStorage.removeItem('lv33-history');
    renderHistory();
    showToast('History cleared');
  });
}

function saveHistory(src, result, stats, elapsed) {
  state.history.unshift({
    id:Date.now(), ts:new Date().toLocaleString(),
    preview:src.slice(0,120), result, stats, elapsed,
    layers:{...state.layers},
  });
  if (state.history.length>20) state.history.pop();
  localStorage.setItem('lv33-history', JSON.stringify(state.history));
}

function renderHistory() {
  const c = $('historyEntries');
  if (!c) return;
  if (!state.history.length) {
    c.innerHTML='<p style="color:var(--text-3);font-size:13px;">No history yet. Obfuscate something first!</p>';
    return;
  }
  c.innerHTML = state.history.map((e,i) => `
    <div class="history-entry" data-i="${i}">
      <div class="history-entry-top">
        <span class="history-entry-name">Session #${state.history.length-i}</span>
        <span class="history-entry-time">${e.ts}</span>
      </div>
      <div class="history-entry-meta">
        <span>${fmtBytes(e.stats?.originalBytes||0)} → ${fmtBytes(e.stats?.obfuscatedBytes||0)}</span>
        <span>${e.stats?.originalLines||0} → ${e.stats?.obfuscatedLines||0} lines</span>
        <span>${e.elapsed||0}s</span>
      </div>
      <div>
        ${e.layers?.vmMode?'<span class="htag vm">VM</span>':''}
        ${e.layers?.controlFlow?'<span class="htag cfg">CFG</span>':''}
        ${e.layers?.polymorphic?'<span class="htag base">POLY</span>':''}
        ${e.layers?.wrapEnv?'<span class="htag base">ENV</span>':''}
      </div>
      <div style="margin-top:5px;font-family:var(--font-mono);font-size:11px;color:var(--text-3);overflow:hidden;white-space:nowrap;text-overflow:ellipsis;">${esc(e.preview)}</div>
    </div>
  `).join('');
  c.querySelectorAll('.history-entry').forEach(el => {
    el.addEventListener('click', () => {
      const en = state.history[+el.dataset.i];
      const ed = $('inputEditor');
      if (ed) { ed.value=en.result; }
      switchView('obfuscator');
      showToast('Restored from history','success');
    });
  });
}

/* ═══════════════════════════════════════════════════════════════
   SETTINGS PAGE
   ═══════════════════════════════════════════════════════════════ */

function buildSettingsPage() {
  // Anim level select
  $('animSelect')?.addEventListener('change', e => {
    ThemeSystem.applyAnimLevel(e.target.value);
  });

  // Blur slider
  $('bgBlurSlider')?.addEventListener('input', e => {
    const url = ThemeSystem.getState().bgUrl;
    ThemeSystem.applyBackground(url, +e.target.value, +($('bgDimSlider')?.value||0)/100);
  });

  $('bgDimSlider')?.addEventListener('input', e => {
    const url = ThemeSystem.getState().bgUrl;
    ThemeSystem.applyBackground(url, +($('bgBlurSlider')?.value||0), +e.target.value/100);
  });

  // BG URL
  $('bgUrlInput')?.addEventListener('change', e => {
    const url = e.target.value.trim();
    ThemeSystem.applyBackground(url, +($('bgBlurSlider')?.value||0), +($('bgDimSlider')?.value||0)/100);
  });

  // BG upload
  $('bgUploadBtn')?.addEventListener('click', () => $('bgFileInput')?.click());
  $('bgFileInput')?.addEventListener('change', e => {
    const f = e.target.files[0];
    if (!f) return;
    const reader = new FileReader();
    reader.onload = ev => {
      ThemeSystem.applyBackground(ev.target.result, 0, 0);
      const inp = $('bgUrlInput');
      if (inp) inp.value = '(uploaded image)';
    };
    reader.readAsDataURL(f);
  });

  $('bgClearBtn')?.addEventListener('click', () => {
    ThemeSystem.applyBackground('', 0, 0);
    const inp = $('bgUrlInput');
    if (inp) inp.value = '';
  });
}

/* ═══════════════════════════════════════════════════════════════
   STATUS PANEL
   ═══════════════════════════════════════════════════════════════ */

function initStatusPanel() {
  $('statusFab')?.addEventListener('click', () => {
    state.statusOpen = !state.statusOpen;
    localStorage.setItem('lv33-status', state.statusOpen ? '1' : '0');
    updateStatusPanel();
  });
  updateStatusPanel();
  updatePing();
}

function updateStatusPanel() {
  const panel = $('statusPanel');
  if (!panel) return;
  panel.classList.toggle('hidden', !state.statusOpen);
}

async function checkEngineStatus() {
  try {
    const t0  = performance.now();
    const res = await fetch('/api/status');
    const d   = await res.json();
    const rtt = Math.round(performance.now() - t0);
    state.ping = rtt;
    state.engineStatus = d.lua ? 'online' : 'fallback';

    $('statusEngine')?.setAttribute('class', `status-val ${d.lua ? 'online' : 'warn'}`);
    if ($('statusEngine')) $('statusEngine').textContent = d.engine || (d.lua ? 'Lua 5.4' : 'Python');

    $('statusPing')?.setAttribute('class', `status-val ${rtt < 100 ? 'online' : rtt < 400 ? 'warn' : 'offline'}`);
    if ($('statusPing')) $('statusPing').textContent = rtt + 'ms';

    $('statusTool')?.setAttribute('class', 'status-val online');
    if ($('statusTool')) $('statusTool').textContent = 'Online';

    if ($('statusVersion')) $('statusVersion').textContent = d.version || '3.3.0';

    // Update sidebar engine status
    const dot   = $('engineDot');
    const label = $('engineLabel');
    if (dot && label) {
      dot.className   = `engine-dot ${d.lua ? 'online' : 'loading'}`;
      label.textContent = d.lua ? '✓ Lua engine (full VM)' : '⚠ Python engine (fallback)';
    }
  } catch {
    state.engineStatus = 'offline';
    $('statusTool')?.setAttribute('class', 'status-val offline');
    if ($('statusTool')) $('statusTool').textContent = 'Offline';
  }
}

async function updatePing() {
  try {
    const t0 = performance.now();
    await fetch('/api/status');
    const rtt = Math.round(performance.now() - t0);
    state.ping = rtt;
    if ($('statusPing')) {
      $('statusPing').textContent = rtt + 'ms';
      $('statusPing').className = `status-val ${rtt<100?'online':rtt<400?'warn':'offline'}`;
    }
  } catch { /* ignore */ }
}

/* ═══════════════════════════════════════════════════════════════
   KEYBOARD SHORTCUTS
   ═══════════════════════════════════════════════════════════════ */

function initKeyboard() {
  document.addEventListener('keydown', e => {
    const ctrl = e.ctrlKey || e.metaKey;
    if (ctrl && e.key === 'Enter')       { e.preventDefault(); runObfuscate(); }
    if (ctrl && e.key === 'b')           { e.preventDefault(); applySidebar(!state.sidebar); }
    if (ctrl && e.key === 'j')           { e.preventDefault(); ThemeSystem.applyTheme(
      state.view === 'dark' ? 'light' : 'dark'); }
    if (ctrl && e.shiftKey && e.key==='C') { e.preventDefault(); $('copyBtn')?.click(); }
    if (e.key === 'Escape') {
      if (state.settingsPanelOpen) {
        state.settingsPanelOpen = false;
        $('obfSettingsPanel')?.classList.remove('open');
        $('settingsPanelBtn')?.classList.remove('active');
      }
    }
  });
}

/* ═══════════════════════════════════════════════════════════════
   UTILITIES
   ═══════════════════════════════════════════════════════════════ */

function fmtBytes(n) {
  if (!n) return '0B';
  if (n<1024) return n+'B';
  if (n<1048576) return (n/1024).toFixed(1)+'KB';
  return (n/1048576).toFixed(2)+'MB';
}

function esc(s) {
  return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

function dlText(text, name) {
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([text],{type:'text/plain'}));
  a.download = name;
  a.click();
  setTimeout(()=>URL.revokeObjectURL(a.href),1000);
}

let _toastTimer;
function showToast(msg, type='') {
  clearTimeout(_toastTimer);
  const el = $('toast');
  if (!el) return;
  el.textContent = msg;
  el.className = `toast show ${type}`;
  _toastTimer = setTimeout(()=>el.classList.remove('show'), 3200);
}
