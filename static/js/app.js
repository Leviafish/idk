'use strict';
/**
 * Leviathan Obfuscator v3.3 — Main Application
 * static/js/app.js
 */

// ── Layer definitions ──────────────────────────────────────────────────────
const LAYERS = [
  { id:'nameObf',    name:'Name Obfuscation', emoji:'🔤', desc:'Renames locals/functions',  flag:'--name-obf',   default:true  },
  { id:'strEnc',     name:'String Encoding',  emoji:'🔒', desc:'Encrypts string literals',  flag:'--str-enc',    default:true  },
  { id:'constFold',  name:'Const Folding',    emoji:'🧮', desc:'Computes constants early',  flag:'--const-fold', default:true  },
  { id:'deadCode',   name:'Dead Code',        emoji:'💀', desc:'Injects junk branches',     flag:'--dead-code',  default:true  },
  { id:'controlFlow',name:'Control Flow',     emoji:'🔀', desc:'Flattens flow graph',       flag:'--cfg',        default:false, badge:'CFG'  },
  { id:'vmWrap',     name:'VM Wrap',          emoji:'⚙️', desc:'Compiles to custom VM',     flag:'--vm',         default:false, badge:'VM'   },
  { id:'p2',         name:'Phase-2 Crypto',   emoji:'🔐', desc:'Multi-layer encryption',    flag:'--p2',         default:false, badge:'P2'   },
];

const PRESETS = {
  quick:    { nameObf:true,  strEnc:true,  constFold:false, deadCode:false, controlFlow:false, vmWrap:false, p2:false },
  standard: { nameObf:true,  strEnc:true,  constFold:true,  deadCode:true,  controlFlow:false, vmWrap:false, p2:false },
  heavy:    { nameObf:true,  strEnc:true,  constFold:true,  deadCode:true,  controlFlow:true,  vmWrap:false, p2:false },
  maximum:  { nameObf:true,  strEnc:true,  constFold:true,  deadCode:true,  controlFlow:true,  vmWrap:true,  p2:true  },
};

// ── State ──────────────────────────────────────────────────────────────────
const State = {
  layers:        Object.fromEntries(LAYERS.map(l=>[l.id, l.default])),
  target:        'lua54',
  deterministic: false,
  seed:          null,
  preset:        'standard',
  protectedNames:[],
  history:       [],
};

// ── DOM refs ───────────────────────────────────────────────────────────────
const $ = id => document.getElementById(id);
const $$ = sel => document.querySelectorAll(sel);

// ── Toast ──────────────────────────────────────────────────────────────────
let _toastTimer;
function toast(msg, type='', dur=2400) {
  const el = $('toast');
  el.textContent = msg;
  el.className = `toast ${type} show`;
  clearTimeout(_toastTimer);
  _toastTimer = setTimeout(() => el.classList.remove('show'), dur);
}

// ── View navigation ────────────────────────────────────────────────────────
const VIEW_TITLES = { dashboard:'Dashboard', obfuscator:'Obfuscator', settings:'Settings', themes:'Themes' };

function switchView(id) {
  $$('.view').forEach(v => v.classList.remove('active'));
  $$('.nav-item').forEach(n => n.classList.remove('active'));
  const view = document.querySelector(`.view[data-view="${id}"]`);
  if (view) view.classList.add('active');
  const nav = document.querySelector(`.nav-item[data-view="${id}"]`);
  if (nav) nav.classList.add('active');
  $('topbarTitle').textContent = VIEW_TITLES[id] || id;
  $('layersSection').style.display = id === 'obfuscator' ? '' : 'none';
}

// ── Sidebar ────────────────────────────────────────────────────────────────
let _sidebarCollapsed = false;

function setSidebarCollapsed(val) {
  _sidebarCollapsed = val;
  const sb = $('sidebar');
  sb.classList.toggle('collapsed', val);
  $('expandBtn').classList.toggle('visible', val);
  try { localStorage.setItem('lv-sidebar-collapsed', val ? '1' : '0'); } catch(e){}
}

// ── Layer list ─────────────────────────────────────────────────────────────
function renderLayers() {
  const list = $('layerList');
  if (!list) return;
  list.innerHTML = LAYERS.map(l => {
    const on = State.layers[l.id];
    return `<div class="layer-item" data-layer="${l.id}">
      <div class="layer-left">
        <span class="layer-emoji">${l.emoji}</span>
        <div>
          <div class="layer-name">${l.name}${l.badge ? `<span class="layer-badge ${l.badge.toLowerCase()}">${l.badge}</span>` : ''}</div>
          <div class="layer-desc">${l.desc}</div>
        </div>
      </div>
      <div class="toggle ${on?'on':''}" data-toggle-layer="${l.id}"></div>
    </div>`;
  }).join('');
  list.querySelectorAll('[data-toggle-layer]').forEach(el => {
    el.addEventListener('click', e => {
      e.stopPropagation();
      const id = el.dataset.toggleLayer;
      State.layers[id] = !State.layers[id];
      renderLayers();
      updateStrength();
    });
  });
  list.querySelectorAll('.layer-item').forEach(el => {
    el.addEventListener('click', () => {
      const tog = el.querySelector('[data-toggle-layer]');
      if (tog) tog.click();
    });
  });
}

// ── Strength meter ─────────────────────────────────────────────────────────
const STRENGTH_WEIGHTS = { nameObf:15, strEnc:15, constFold:10, deadCode:10, controlFlow:20, vmWrap:20, p2:10 };
const STRENGTH_GRADES  = [
  [90,'ELITE','var(--success)'],
  [70,'STRONG','var(--info)'],
  [45,'FAIR','var(--warning)'],
  [0, 'WEAK','var(--error)'],
];

function updateStrength() {
  const pct = Object.entries(STRENGTH_WEIGHTS).reduce((s,[id,w]) => s + (State.layers[id] ? w : 0), 0);
  const fill = $('strengthFill');
  const pctEl = $('strengthPct');
  const grade = $('strengthGrade');
  if (!fill) return;
  fill.style.width = pct + '%';
  pctEl.textContent = pct + '%';
  const [,lbl,col] = STRENGTH_GRADES.find(([min])=>pct>=min) || STRENGTH_GRADES.at(-1);
  grade.textContent = lbl;
  fill.style.background = col;
  grade.style.background = col.replace(')',',0.15)').replace('var','rgba').replace('--success','34,211,160').replace('--info','96,165,250').replace('--warning','245,158,11').replace('--error','239,68,68');
  grade.style.color = col;
}

// ── Preset selector ────────────────────────────────────────────────────────
function applyPreset(name) {
  State.preset = name;
  const p = PRESETS[name];
  if (!p) return;
  Object.assign(State.layers, p);
  $$('.type-option').forEach(el => el.classList.toggle('active', el.dataset.preset === name));
  renderLayers();
  updateStrength();
}

// ── Protected names ────────────────────────────────────────────────────────
function renderProtectTags() {
  const container = $('protectTags');
  if (!container) return;
  container.innerHTML = State.protectedNames.map(n =>
    `<div class="protect-tag">${n}<button data-rm-name="${n}">×</button></div>`
  ).join('');
  container.querySelectorAll('[data-rm-name]').forEach(btn =>
    btn.addEventListener('click', () => {
      State.protectedNames = State.protectedNames.filter(x => x !== btn.dataset.rmName);
      renderProtectTags();
    })
  );
}

// ── Line numbers ───────────────────────────────────────────────────────────
function syncLineNums(textarea, numsEl) {
  if (!textarea || !numsEl) return;
  const count = (textarea.value.match(/\n/g) || []).length + 1;
  const cur   = parseInt(numsEl.dataset.count || '0');
  if (cur !== count) {
    numsEl.dataset.count = count;
    numsEl.textContent = Array.from({length:count},(_,i)=>i+1).join('\n');
  }
  numsEl.scrollTop = textarea.scrollTop;
}

// ── Build API options from state ───────────────────────────────────────────
function buildOptions() {
  const flags = LAYERS.filter(l => State.layers[l.id]).map(l => l.flag);
  return {
    target:          State.target,
    flags,
    protectNames:    State.protectedNames,
    ...(State.deterministic && State.seed !== null ? { seed: parseInt(State.seed) } : {}),
  };
}

// ── Obfuscate ──────────────────────────────────────────────────────────────
let _running = false;

async function runObfuscate() {
  if (_running) return;
  const src = $('inputEditor').value.trim();
  if (!src) { toast('No source code.', 'error'); return; }

  _running = true;
  const cover  = $('loadingCover');
  const errCov = $('errorCover');
  const outEd  = $('outputEditor');
  const runBtn = $('runBtn');

  cover.style.display  = 'flex';
  errCov.style.display = 'none';
  runBtn.disabled = true;
  $('statsRow').style.display = 'none';

  const msgs = ['Parsing source…','Compiling AST…','Applying layers…','Generating VM…','Almost done…'];
  let mi = 0;
  const msgEl = $('loadingMsg');
  const msgTimer = setInterval(() => { msgEl.textContent = msgs[Math.min(mi++, msgs.length-1)]; }, 600);

  try {
    const res  = await fetch('/api/obfuscate', {
      method:'POST',
      headers:{'Content-Type':'application/json'},
      body: JSON.stringify({ source: src, options: buildOptions() }),
    });
    const data = await res.json();

    cover.style.display = 'none';

    if (data.success || data.ok) {
      const result = data.result || '';
      outEd.value = result;
      syncLineNums(outEd, $('outLines'));

      // Stats
      const st = data.stats || {};
      const fmt = n => n > 1024 ? (n/1024).toFixed(1)+'KB' : n+'B';
      $('statOrig').textContent  = fmt(st.originalBytes   || src.length);
      $('statObf').textContent   = fmt(st.obfuscatedBytes || result.length);
      $('statRatio').textContent = (st.ratio || 0) + 'x';
      $('statLines').textContent = (st.obfuscatedLines || result.split('\n').length) + ' lines';
      $('statTime').textContent  = (data.elapsed || 0) + 's';
      $('statsRow').style.display = 'flex';

      $('outputMeta').textContent = `seed: ${data.seed ?? '—'} · ${data.target || State.target}`;

      // History
      State.history.unshift({ time: Date.now(), size: fmt(st.originalBytes||src.length), target: data.target||State.target, elapsed: data.elapsed||0 });
      if (State.history.length > 8) State.history.pop();
      renderHistory();

      toast('Obfuscated successfully', 'success');
    } else {
      showError(data.error || 'Unknown error.', data.details || '');
    }
  } catch(e) {
    cover.style.display = 'none';
    showError('Network error: ' + e.message, '');
  } finally {
    clearInterval(msgTimer);
    runBtn.disabled = false;
    _running = false;
  }
}

function showError(msg, detail) {
  $('errorMsg').textContent = msg;
  const detEl = $('errorDetail');
  if (detail && detail.trim()) {
    detEl.textContent = detail;
    detEl.style.display = 'block';
  } else {
    detEl.style.display = 'none';
  }
  $('errorCover').style.display = 'flex';
}

// ── Dashboard status ───────────────────────────────────────────────────────
let _statusInterval;

async function fetchStatus() {
  const t0 = performance.now();
  try {
    const res  = await fetch('/api/status');
    const ping = Math.round(performance.now() - t0);
    const data = await res.json();

    const ok = data.ready || data.lua;

    setDash('obf',    ok ? 'Online' : 'Degraded', ok ? 'online' : 'warn');
    setDash('engine', data.lua_version || (ok ? 'Lua 5.4' : 'Missing'), ok ? 'online' : 'offline');
    setDash('api',    'Online', 'online');
    setDash('ping',   ping + ' ms', ping < 120 ? 'online' : ping < 350 ? 'warn' : 'offline');
    setDash('region', data.region || 'global', 'online');
    setDash('version', 'v' + (data.version || '3.3.0'), 'online');
    setDash('health', ok ? 'Healthy' : 'Degraded', ok ? 'online' : 'warn');
    setDash('uptime', fmtUptime(data.uptime || 0), 'online');

    // Engine footer
    const dot = $('engDot');
    $('engLabel').textContent = ok ? (data.lua_version||'Lua 5.4') : 'Unavailable';
    dot.className = 'eng-dot ' + (ok ? 'online' : 'offline');
  } catch(e) {
    setDash('obf',    'Offline', 'offline');
    setDash('api',    'Offline', 'offline');
    setDash('engine', 'Error',   'offline');
    $('engDot').className = 'eng-dot offline';
    $('engLabel').textContent = 'Offline';
  }
}

function setDash(key, val, badge) {
  const el = $('ds-'+key), b = $('ds-'+key+'-badge');
  if (el) el.textContent = val;
  if (b) { b.textContent = badge; b.className = 'status-badge ' + (badge||''); }
}

function fmtUptime(secs) {
  if (secs < 60)   return secs + 's';
  if (secs < 3600) return Math.floor(secs/60) + 'm ' + (secs%60) + 's';
  return Math.floor(secs/3600) + 'h ' + Math.floor((secs%3600)/60) + 'm';
}

function renderHistory() {
  const el = $('dashHistory');
  if (!el) return;
  if (!State.history.length) {
    el.innerHTML = '<div class="dash-history-empty">No builds yet. Run the obfuscator to see history.</div>';
    return;
  }
  el.innerHTML = State.history.map(h => {
    const ago = fmtAgo(Date.now() - h.time);
    return `<div class="dash-history-item">
      <span class="dh-badge">✓ done</span>
      <span>${h.size} → ${h.target}</span>
      <span style="color:var(--text-3)">${h.elapsed}s</span>
      <span style="color:var(--text-3);margin-left:auto">${ago}</span>
    </div>`;
  }).join('');
}

function fmtAgo(ms) {
  const s = Math.floor(ms/1000);
  if (s < 60)   return s + 's ago';
  if (s < 3600) return Math.floor(s/60) + 'm ago';
  return Math.floor(s/3600) + 'h ago';
}

// ── File helpers ───────────────────────────────────────────────────────────
function downloadFile(name, content) {
  const a = Object.assign(document.createElement('a'), {
    href: URL.createObjectURL(new Blob([content], {type:'text/plain'})),
    download: name,
  });
  document.body.appendChild(a); a.click();
  setTimeout(() => { document.body.removeChild(a); URL.revokeObjectURL(a.href); }, 100);
}

// ── Theme cycling ──────────────────────────────────────────────────────────
const THEME_CYCLE = ['dark','midnight','cyberpunk','frost','leviathan','light'];
let _themeIdx = 0;
function cycleTheme() {
  _themeIdx = (_themeIdx + 1) % THEME_CYCLE.length;
  ThemeSystem.applyTheme(THEME_CYCLE[_themeIdx]);
  toast('Theme: ' + THEME_CYCLE[_themeIdx]);
}

// ── Init ───────────────────────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', () => {
  // Background & effects
  Effects.init();
  ThemeSystem.init();

  // Sidebar collapse restore
  const savedCollapse = localStorage.getItem('lv-sidebar-collapsed');
  if (savedCollapse === '1') setSidebarCollapsed(true);

  // Nav
  $$('.nav-item').forEach(el =>
    el.addEventListener('click', () => switchView(el.dataset.view))
  );

  $('collapseBtn').addEventListener('click', () => setSidebarCollapsed(true));
  $('expandBtn').addEventListener('click',   () => setSidebarCollapsed(false));

  const backdrop = $('sidebarBackdrop');
  backdrop.addEventListener('click', () => {
    $('sidebar').classList.remove('mobile-open');
  });
  $('mobileMenuBtn')?.addEventListener('click', () => {
    $('sidebar').classList.toggle('mobile-open');
  });

  // Layer render
  renderLayers();
  updateStrength();
  renderHistory();

  // Type selector
  $$('.type-option').forEach(el =>
    el.addEventListener('click', () => applyPreset(el.dataset.preset))
  );
  applyPreset('standard');

  // Target select
  $('targetSelect').addEventListener('change', e => { State.target = e.target.value; });

  // Deterministic toggle
  const detTog = $('deterministicToggle');
  detTog.addEventListener('click', () => {
    State.deterministic = !State.deterministic;
    detTog.classList.toggle('on', State.deterministic);
    const si = $('seedInput');
    si.disabled = !State.deterministic;
    if (State.deterministic && !si.value) {
      si.value = Math.floor(Math.random() * 0xFFFFFF).toString();
      State.seed = si.value;
    }
  });
  $('seedInput').addEventListener('input', e => { State.seed = e.target.value; });
  $('seedRefreshBtn').addEventListener('click', () => {
    const v = Math.floor(Math.random() * 0xFFFFFF).toString();
    $('seedInput').value = v; State.seed = v;
  });

  // Protected names
  const pi = $('protectInput');
  pi.addEventListener('keydown', e => {
    if (e.key === 'Enter' || e.key === ',') {
      e.preventDefault();
      const val = pi.value.trim().replace(/,/g,'');
      if (val && !State.protectedNames.includes(val)) {
        State.protectedNames.push(val);
        renderProtectTags();
      }
      pi.value = '';
    }
  });

  // Editors — line numbers + meta
  const inEd  = $('inputEditor');
  const outEd = $('outputEditor');

  inEd.addEventListener('input', () => {
    syncLineNums(inEd, $('inLines'));
    const lines = inEd.value.split('\n').length;
    const bytes = new Blob([inEd.value]).size;
    const fmt   = n => n > 1024 ? (n/1024).toFixed(1)+'KB' : n+'B';
    $('inputMeta').textContent = `${lines} lines · ${fmt(bytes)}`;
  });
  inEd.addEventListener('scroll', () => syncLineNums(inEd, $('inLines')));
  outEd.addEventListener('scroll', () => syncLineNums(outEd, $('outLines')));
  syncLineNums(inEd, $('inLines'));

  // Drag & drop on input pane
  const inPane = $('inputPane');
  inPane.addEventListener('dragover', e => { e.preventDefault(); inPane.style.borderColor = 'var(--accent)'; });
  inPane.addEventListener('dragleave',  () => { inPane.style.borderColor = ''; });
  inPane.addEventListener('drop', e => {
    e.preventDefault(); inPane.style.borderColor = '';
    const file = e.dataTransfer.files[0];
    if (file) { const r = new FileReader(); r.onload = e => { inEd.value = e.target.result; inEd.dispatchEvent(new Event('input')); }; r.readAsText(file); }
  });

  // File upload
  $('uploadBtn').addEventListener('click', () => $('fileInput').click());
  $('fileInput').addEventListener('change', e => {
    const file = e.target.files[0];
    if (!file) return;
    const r = new FileReader();
    r.onload = ev => { inEd.value = ev.target.result; inEd.dispatchEvent(new Event('input')); };
    r.readAsText(file);
    e.target.value = '';
  });

  // Toolbar actions
  $('exampleBtn').addEventListener('click', () => {
    inEd.value = `-- Example: secret vault
local KEY = "super_secret_key_2025"
local function decrypt(data, key)
    local result = {}
    for i = 1, #data do
        local byte = string.byte(data, i)
        local kbyte = string.byte(key, ((i-1) % #key) + 1)
        result[#result+1] = string.char(byte ~ kbyte)
    end
    return table.concat(result)
end
local function getCredentials()
    return { user = "admin", pass = decrypt("\\x1a\\x0f\\x05", KEY) }
end
print(getCredentials().user)`;
    inEd.dispatchEvent(new Event('input'));
  });

  $('clearBtn').addEventListener('click', () => {
    inEd.value = ''; outEd.value = '';
    $('statsRow').style.display = 'none';
    $('errorCover').style.display = 'none';
    syncLineNums(inEd, $('inLines'));
    syncLineNums(outEd, $('outLines'));
    $('inputMeta').textContent = '';
    $('outputMeta').textContent = '';
  });

  $('runBtn').addEventListener('click', runObfuscate);

  $('copyBtn').addEventListener('click', () => {
    const out = outEd.value;
    if (!out) { toast('Nothing to copy.', 'error'); return; }
    navigator.clipboard.writeText(out).then(() => toast('Copied!', 'success'), () => {
      outEd.select(); document.execCommand('copy'); toast('Copied!', 'success');
    });
  });

  $('downloadBtn').addEventListener('click', () => {
    const out = outEd.value;
    if (!out) { toast('Nothing to download.', 'error'); return; }
    downloadFile('obfuscated.lua', out);
    toast('Downloaded', 'success');
  });

  $('dismissErrorBtn').addEventListener('click', () => { $('errorCover').style.display = 'none'; });

  // Theme button
  $('themeBtn').addEventListener('click', cycleTheme);

  // Settings: animation
  $('animSelect').addEventListener('change', e => ThemeSystem.applyAnimLevel(e.target.value));

  // Settings: background
  $('bgUrlInput').addEventListener('change', e => {
    const blur = parseInt($('bgBlurSlider').value);
    const dim  = parseInt($('bgDimSlider').value) / 100;
    ThemeSystem.applyBackground(e.target.value, blur, dim);
  });
  $('bgBlurSlider').addEventListener('input', e => {
    $('bgBlurVal').textContent = e.target.value + 'px';
    const url = $('bgUrlInput').value;
    const dim = parseInt($('bgDimSlider').value) / 100;
    if (url) ThemeSystem.applyBackground(url, parseInt(e.target.value), dim);
  });
  $('bgDimSlider').addEventListener('input', e => {
    $('bgDimVal').textContent = e.target.value + '%';
    const url  = $('bgUrlInput').value;
    const blur = parseInt($('bgBlurSlider').value);
    if (url) ThemeSystem.applyBackground(url, blur, parseInt(e.target.value)/100);
  });
  $('bgUploadBtn').addEventListener('click', () => $('bgFileInput').click());
  $('bgFileInput').addEventListener('change', e => {
    const file = e.target.files[0]; if (!file) return;
    const r = new FileReader();
    r.onload = ev => {
      $('bgUrlInput').value = ev.target.result;
      const blur = parseInt($('bgBlurSlider').value);
      const dim  = parseInt($('bgDimSlider').value) / 100;
      ThemeSystem.applyBackground(ev.target.result, blur, dim);
    };
    r.readAsDataURL(file);
    e.target.value = '';
  });
  $('bgClearBtn').addEventListener('click', () => {
    $('bgUrlInput').value = '';
    ThemeSystem.applyBackground('');
  });

  // Keyboard shortcuts
  document.addEventListener('keydown', e => {
    if ((e.ctrlKey || e.metaKey)) {
      if (e.key === 'Enter')    { e.preventDefault(); runObfuscate(); }
      if (e.key === 'b')        { e.preventDefault(); setSidebarCollapsed(!_sidebarCollapsed); }
      if (e.key === 'j')        { e.preventDefault(); cycleTheme(); }
      if (e.key === 'C' && e.shiftKey) { e.preventDefault(); $('copyBtn').click(); }
    }
  });

  // Init theme cycle index
  const cur = ThemeSystem.getState().current;
  _themeIdx = THEME_CYCLE.indexOf(cur);
  if (_themeIdx < 0) _themeIdx = 0;

  // Status dashboard
  fetchStatus();
  _statusInterval = setInterval(fetchStatus, 15000);
  renderHistory();

  // Switch to default view
  switchView('obfuscator');
});
