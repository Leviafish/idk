'use strict';
/* Levititas v3.3 — Main App (fixed all click handlers) */

const LAYERS = [
  { key:'mangleNames',    icon:'🔀', name:'Name Mangling',     desc:'Rename identifiers',      tier:'base', w:8  },
  { key:'encryptStrings', icon:'🔐', name:'String Encryption', desc:'Rolling-XOR cipher',      tier:'base', w:12 },
  { key:'encodeNumbers',  icon:'🔢', name:'Number Encoding',   desc:'Lambda chain',            tier:'base', w:8  },
  { key:'injectJunk',     icon:'🧬', name:'Dead Code',         desc:'Mutation injection',      tier:'base', w:7  },
  { key:'antiDebug',      icon:'🛡', name:'Anti-Debug',        desc:'Multi-layer hooks',       tier:'base', w:8  },
  { key:'stripComments',  icon:'💬', name:'Strip Comments',    desc:'Remove all comments',     tier:'base', w:2  },
  { key:'controlFlow',    icon:'🌀', name:'Control Flow',      desc:'State machine dispatch',  tier:'cfg',  w:15 },
  { key:'polymorphic',    icon:'🎲', name:'Polymorphic',       desc:'Unique per run',          tier:'p2',   w:10 },
  { key:'wrapEnv',        icon:'📦', name:'Env Wrapping',      desc:'Nested sandboxes',        tier:'p2',   w:10 },
  { key:'vmMode',         icon:'⚙', name:'Custom VM',         desc:'Bytecode interpreter',    tier:'vm',   w:15 },
  { key:'antiTamper',     icon:'🔒', name:'Anti-Tamper',       desc:'CRC integrity check',     tier:'vm',   w:5  },
];

const ST = {
  layers:       Object.fromEntries(LAYERS.map(l=>[l.key,true])),
  protectNames: [],
  target:       localStorage.getItem('lv-target')   || 'lua54',
  determin:     localStorage.getItem('lv-determin') === '1',
  seed:         localStorage.getItem('lv-seed')     || '',
  view:         'obfuscator',
  sidebar:      localStorage.getItem('lv-sidebar')  !== '0',
  statusOpen:   localStorage.getItem('lv-status')   !== '0',
  history:      JSON.parse(localStorage.getItem('lv-history') || '[]'),
  batchFiles:   [],
};

const $  = id => document.getElementById(id);
const $$ = s  => document.querySelectorAll(s);

/* ── INIT ── */
document.addEventListener('DOMContentLoaded', () => {
  buildLayerList();
  initNav();
  initObfuscator();
  initBatch();
  initHistory();
  initStatus();
  initKeyboard();
  initSettings();

  applySidebar(ST.sidebar);
  applyView(ST.view);

  if (typeof ThemeSystem !== 'undefined') ThemeSystem.init();
  if (typeof Effects    !== 'undefined') Effects.init();

  checkEngine();
  setInterval(checkEngine, 30000);
  setInterval(pingServer, 10000);
});

/* ── LAYER LIST ── */
function buildLayerList() {
  const list = $('layerList');
  if (!list) return;
  list.innerHTML = LAYERS.map(l => `
    <div class="layer-item">
      <div class="layer-left">
        <span class="layer-emoji">${l.icon}</span>
        <div>
          <div class="layer-name">${l.name}${l.tier!=='base'?`<span class="layer-badge ${l.tier}">${l.tier.toUpperCase()}</span>`:''}</div>
          <div class="layer-desc">${l.desc}</div>
        </div>
      </div>
      <div class="toggle on" id="toggle_${l.key}" data-key="${l.key}" data-tier="${l.tier}"></div>
    </div>
  `).join('');

  list.querySelectorAll('.toggle').forEach(t => {
    t.addEventListener('click', e => {
      e.stopPropagation();
      const key = t.dataset.key;
      ST.layers[key] = !ST.layers[key];
      t.classList.toggle('on', ST.layers[key]);
      updateStrength();
    });
  });

  const inp = $('protectInput');
  if (inp) {
    inp.addEventListener('keydown', e => {
      if (e.key !== 'Enter' && e.key !== ',') return;
      e.preventDefault();
      inp.value.split(',').map(s=>s.trim()).filter(Boolean).forEach(n => {
        if (!ST.protectNames.includes(n)) ST.protectNames.push(n);
      });
      inp.value = '';
      renderTags();
    });
  }

  $('collapseBtn')?.addEventListener('click', () => applySidebar(false));
  $('expandBtn')  ?.addEventListener('click', () => applySidebar(true));
  $('mobileMenuBtn')?.addEventListener('click', () => {
    $('sidebar').classList.add('mobile-open');
    $('sidebarBackdrop').style.display = 'block';
  });
  $('sidebarBackdrop')?.addEventListener('click', closeMobile);

  updateStrength();
}

function renderTags() {
  const c = $('protectTags');
  if (!c) return;
  c.innerHTML = ST.protectNames.map((n,i) => `
    <span class="protect-tag">${esc(n)}<button data-i="${i}">✕</button></span>
  `).join('');
  c.querySelectorAll('button').forEach(b => {
    b.addEventListener('click', () => { ST.protectNames.splice(+b.dataset.i,1); renderTags(); });
  });
}

function applySidebar(open) {
  ST.sidebar = open;
  localStorage.setItem('lv-sidebar', open?'1':'0');
  $('sidebar').classList.toggle('collapsed', !open);
}

function closeMobile() {
  $('sidebar').classList.remove('mobile-open');
  const bd = $('sidebarBackdrop');
  if (bd) bd.style.display = 'none';
}

/* ── STRENGTH ── */
function updateStrength() {
  const total = LAYERS.reduce((a,l) => a + (ST.layers[l.key] ? l.w : 0), 0);
  const fill  = $('strengthFill');
  const pct   = $('strengthPct');
  const grade = $('strengthGrade');
  if (!fill) return;
  fill.style.width = total + '%';

  let color, label;
  if      (total>=90){ color='var(--success)';  label='ELITE';  }
  else if (total>=75){ color='var(--accent-2)'; label='STRONG'; }
  else if (total>=55){ color='var(--warning)';  label='MEDIUM'; }
  else if (total>=30){ color='var(--warning)';  label='WEAK';   }
  else               { color='var(--error)';    label='BARE';   }

  fill.style.background = color;
  if (pct)   { pct.textContent = total+'%'; pct.style.color = color; }
  if (grade) {
    grade.textContent     = label;
    grade.style.background = color+'22';
    grade.style.color      = color;
  }
}

/* ── NAV ── */
function initNav() {
  $$('.nav-item').forEach(el => {
    el.addEventListener('click', () => applyView(el.dataset.view));
  });
  $('themeBtn')?.addEventListener('click', () => {
    const themes = ['dark','light','midnight','cyberpunk','frost','leviathan'];
    const cur = document.documentElement.getAttribute('data-theme') || 'dark';
    const next = themes[(themes.indexOf(cur)+1) % themes.length];
    if (typeof ThemeSystem !== 'undefined') ThemeSystem.applyTheme(next);
    else document.documentElement.setAttribute('data-theme', next);
  });
}

function applyView(view) {
  ST.view = view;
  $$('.nav-item').forEach(el => el.classList.toggle('active', el.dataset.view===view));
  $$('.view').forEach(el => el.classList.toggle('active', el.dataset.view===view));
  const titles = {obfuscator:'Obfuscator',batch:'Batch Mode',history:'History',settings:'Settings'};
  const t = $('topbarTitle'); if (t) t.textContent = titles[view]||view;
  if (view==='history') renderHistory();
  closeMobile();
}

/* ── OBFUSCATOR ── */
function initObfuscator() {
  const inEd  = $('inputEditor');
  const inLn  = $('inLines');
  const outEd = $('outputEditor');
  const outLn = $('outLines');
  if (!inEd) return;

  /* Line numbers sync */
  function syncLines(ed, ln) {
    const n = ed.value.split('\n').length;
    if (ln.dataset.c == n) return;
    ln.dataset.c = n;
    ln.textContent = Array.from({length:n},(_,i)=>i+1).join('\n')+'\n';
  }
  inEd.addEventListener('input',  () => syncLines(inEd, inLn));
  inEd.addEventListener('scroll', () => { inLn.scrollTop = inEd.scrollTop; });
  outEd.addEventListener('scroll',() => { outLn.scrollTop = outEd.scrollTop; });

  /* Tab key */
  inEd.addEventListener('keydown', e => {
    if (e.key !== 'Tab') return;
    e.preventDefault();
    const s = inEd.selectionStart, v = inEd.value;
    inEd.value = v.slice(0,s)+'    '+v.slice(inEd.selectionEnd);
    inEd.selectionStart = inEd.selectionEnd = s+4;
    syncLines(inEd, inLn);
  });

  /* Drag-drop on input pane */
  const inPane = $('inputPane');
  inPane?.addEventListener('dragover', e => { e.preventDefault(); inPane.classList.add('drag-over'); });
  inPane?.addEventListener('dragleave',() => inPane.classList.remove('drag-over'));
  inPane?.addEventListener('drop', e => {
    e.preventDefault(); inPane.classList.remove('drag-over');
    const f = e.dataTransfer.files[0];
    if (f) readLuaFile(f);
  });

  /* Upload */
  $('uploadBtn')?.addEventListener('click', () => $('fileInput').click());
  $('fileInput')?.addEventListener('change', () => {
    const f = $('fileInput').files[0];
    if (f) readLuaFile(f);
    $('fileInput').value = '';
  });

  /* Example */
  $('exampleBtn')?.addEventListener('click', () => {
    inEd.value = `-- Example: Secret token validator
local SECRET = "sk-prod-abc123xyz789"
local API    = "https://api.service.com/v2"

local function hmac(msg, key)
  local result = ""
  for i = 1, #msg do
    local b = string.byte(msg, i) ~ string.byte(key, ((i-1)%#key)+1)
    result = result .. string.char(b)
  end
  return result
end

local function validate(token)
  return hmac(token, SECRET) == hmac("valid_user_token", SECRET)
end

local data = { level=99, coins=50000, premium=true }

if validate("valid_user_token") then
  print("[OK] Access granted")
  for k, v in pairs(data) do
    print("  "..k.." = "..tostring(v))
  end
else
  print("[DENIED]")
end`;
    syncLines(inEd, inLn);
    showToast('Example loaded', 'success');
  });

  /* Clear */
  $('clearBtn')?.addEventListener('click', () => {
    inEd.value  = '';
    outEd.value = '';
    $('statsRow').style.display = 'none';
    syncLines(inEd, inLn);
    syncLines(outEd, outLn);
  });

  /* Copy */
  $('copyBtn')?.addEventListener('click', () => {
    if (!outEd.value) { showToast('Nothing to copy','error'); return; }
    navigator.clipboard.writeText(outEd.value)
      .then(()=>showToast('Copied!','success'))
      .catch(()=>{ outEd.select(); document.execCommand('copy'); showToast('Copied!','success'); });
  });

  /* Download */
  $('downloadBtn')?.addEventListener('click', () => {
    if (!outEd.value) { showToast('Nothing to download','error'); return; }
    dlText(outEd.value, 'obfuscated.lua');
    showToast('Downloaded!','success');
  });

  /* Run */
  $('runBtn')?.addEventListener('click', runObfuscate);

  /* Target */
  const tgt = $('targetSelect');
  if (tgt) {
    tgt.value = ST.target;
    tgt.addEventListener('change', e => {
      ST.target = e.target.value;
      localStorage.setItem('lv-target', ST.target);
    });
  }

  /* Deterministic toggle */
  const detTgl = $('deterministicToggle');
  if (detTgl) {
    detTgl.classList.toggle('on', ST.determin);
    detTgl.addEventListener('click', () => {
      ST.determin = !ST.determin;
      localStorage.setItem('lv-determin', ST.determin?'1':'0');
      detTgl.classList.toggle('on', ST.determin);
      const si = $('seedInput');
      if (si) si.disabled = !ST.determin;
    });
  }

  /* Seed input */
  const si = $('seedInput');
  if (si) {
    si.value    = ST.seed;
    si.disabled = !ST.determin;
    si.addEventListener('input', e => {
      ST.seed = e.target.value;
      localStorage.setItem('lv-seed', ST.seed);
    });
  }

  /* Seed refresh */
  $('seedRefreshBtn')?.addEventListener('click', () => {
    const s = String(Math.floor(Math.random()*0xFFFFFFFF));
    ST.seed = s;
    localStorage.setItem('lv-seed', s);
    const inp = $('seedInput');
    if (inp) inp.value = s;
  });

  /* Dismiss error */
  $('dismissErrorBtn')?.addEventListener('click', () => {
    $('errorCover').style.display = 'none';
  });
}

function readLuaFile(f) {
  if (!f.name.endsWith('.lua')) { showToast('Only .lua files','error'); return; }
  const r = new FileReader();
  r.onload = ev => {
    const ed = $('inputEditor'), ln = $('inLines');
    ed.value = ev.target.result;
    const n = ed.value.split('\n').length;
    ln.textContent = Array.from({length:n},(_,i)=>i+1).join('\n')+'\n';
    ln.dataset.c = n;
    showToast('Loaded: '+f.name,'success');
  };
  r.readAsText(f);
}

const MSGS = [
  'Parsing AST…','Checking compatibility…','Mangling names…',
  'Encrypting strings…','Encoding numbers…','Flattening control flow…',
  'Building VM bytecode…','Shuffling opcodes…','Injecting dead code…',
  'Wrapping environment…','Applying polymorphic transforms…','Finalizing…',
];

async function runObfuscate() {
  const inEd  = $('inputEditor');
  const outEd = $('outputEditor');
  const outLn = $('outLines');
  const src   = inEd?.value?.trim();
  if (!src) { showToast('Paste some Lua code first','error'); return; }

  const runBtn = $('runBtn');
  if (runBtn) { runBtn.classList.add('loading'); runBtn.disabled = true; }
  $('loadingCover').style.display = 'flex';
  $('errorCover').style.display   = 'none';
  $('statsRow').style.display     = 'none';
  if (outEd) outEd.value = '';

  let mi = 0;
  const msgEl = $('loadingMsg');
  if (msgEl) msgEl.textContent = MSGS[0];
  const msgTimer = setInterval(() => {
    mi = (mi+1) % MSGS.length;
    if (msgEl) msgEl.textContent = MSGS[mi];
  }, 650);

  try {
    const opts = { ...ST.layers, protectNames: ST.protectNames, target: ST.target };
    if (ST.determin && ST.seed) opts.seed = parseInt(ST.seed)||0;

    const res  = await fetch('/api/obfuscate', {
      method:'POST',
      headers:{'Content-Type':'application/json'},
      body: JSON.stringify({ source: src, options: opts }),
    });
    const data = await res.json();
    clearInterval(msgTimer);
    $('loadingCover').style.display = 'none';

    if (!data.ok) {
      $('errorCover').style.display = 'flex';
      $('errorMsg').textContent = (data.error||'Obfuscation failed.').slice(0,200);
      showToast('Error: '+(data.error||'failed').slice(0,60),'error');
      return;
    }

    if (outEd) {
      outEd.value = data.result||'';
      const n = outEd.value.split('\n').length;
      outLn.textContent = Array.from({length:n},(_,i)=>i+1).join('\n')+'\n';
      outLn.dataset.c = n;
    }

    const s = data.stats||{};
    $('statsRow').style.display = 'flex';
    $('statOrig').textContent  = fmtBytes(s.originalBytes);
    $('statObf').textContent   = fmtBytes(s.obfuscatedBytes);
    $('statRatio').textContent = (s.ratio||0)+'×';
    $('statLines').textContent = (s.originalLines||0)+'→'+(s.obfuscatedLines||0);
    $('statTime').textContent  = (data.elapsed||0)+'s';

    showToast('Obfuscated ✓','success');
    saveHistory(src, data.result||'', s, data.elapsed||0);

  } catch(err) {
    clearInterval(msgTimer);
    $('loadingCover').style.display = 'none';
    $('errorCover').style.display   = 'flex';
    $('errorMsg').textContent = 'Network error: '+err.message;
    showToast('Network error','error');
  } finally {
    if (runBtn) { runBtn.classList.remove('loading'); runBtn.disabled = false; }
  }
}

/* ── BATCH ── */
function initBatch() {
  const drop  = $('batchDrop');
  const input = $('batchFileInput');

  $('batchBrowseBtn')?.addEventListener('click', e => { e.stopPropagation(); input?.click(); });
  input?.addEventListener('change', () => { addFiles(input.files); input.value=''; });

  drop?.addEventListener('click', () => input?.click());
  drop?.addEventListener('dragover', e => { e.preventDefault(); drop.classList.add('drag-over'); });
  drop?.addEventListener('dragleave',() => drop.classList.remove('drag-over'));
  drop?.addEventListener('drop', e => { e.preventDefault(); drop.classList.remove('drag-over'); addFiles(e.dataTransfer.files); });

  $('runBatchBtn')?.addEventListener('click', runBatch);
  $('clearBatchBtn')?.addEventListener('click', () => { ST.batchFiles=[]; renderBatch(); });
  $('downloadAllBtn')?.addEventListener('click', downloadAll);
}

function addFiles(files) {
  for (const f of files) {
    if (!f.name.endsWith('.lua')) { showToast('Skipped: '+f.name,'error'); continue; }
    ST.batchFiles.push({file:f,name:f.name,size:f.size,status:'pending',result:null});
  }
  renderBatch();
}

function renderBatch() {
  const list = $('batchList');
  const acts = $('batchActions');
  if (!list) return;
  if (!ST.batchFiles.length) { list.style.display='none'; if(acts) acts.style.display='none'; return; }
  list.style.display = 'block';
  if (acts) acts.style.display = 'flex';
  list.innerHTML = ST.batchFiles.map((f,i)=>`
    <div class="batch-row">
      <span class="batch-name">${esc(f.name)}</span>
      <span class="batch-size">${fmtBytes(f.size)}</span>
      <span class="batch-status ${f.status}">${{pending:'Pending',running:'Running…',done:'✓ Done',error:'✗ Error'}[f.status]}</span>
      ${f.status==='done'?`<button class="tb-btn batch-dl" data-i="${i}" style="font-size:10.5px;padding:3px 8px;">↓ DL</button>`:''}
      <button class="tb-btn batch-rm" data-i="${i}" style="font-size:10.5px;padding:3px 8px;margin-left:4px;">✕</button>
    </div>
  `).join('');
  list.querySelectorAll('.batch-rm').forEach(b => b.addEventListener('click', () => { ST.batchFiles.splice(+b.dataset.i,1); renderBatch(); }));
  list.querySelectorAll('.batch-dl').forEach(b => b.addEventListener('click', () => { const f=ST.batchFiles[+b.dataset.i]; if(f.result) dlText(f.result, f.name.replace('.lua','_obf.lua')); }));
}

async function runBatch() {
  const rb = $('runBatchBtn');
  if (rb) rb.disabled = true;
  let done=0;
  for (const f of ST.batchFiles) {
    if (f.status==='done') continue;
    f.status='running'; renderBatch();
    try {
      const text = await f.file.text();
      const res  = await fetch('/api/obfuscate',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({source:text,options:{...ST.layers,protectNames:ST.protectNames,target:ST.target}})});
      const d    = await res.json();
      f.status = d.ok?'done':'error';
      if (d.ok) { f.result=d.result; done++; }
    } catch { f.status='error'; }
    renderBatch();
  }
  if (rb) rb.disabled = false;
  showToast(`Done — ${done} file(s) obfuscated`,'success');
  const da = $('downloadAllBtn');
  if (done>0 && da) da.style.display='inline-flex';
}

async function downloadAll() {
  const done = ST.batchFiles.filter(f=>f.status==='done'&&f.result);
  for (const f of done) { await new Promise(r=>setTimeout(r,160)); dlText(f.result, f.name.replace('.lua','_obf.lua')); }
  showToast(`Downloading ${done.length} file(s)…`,'success');
}

/* ── HISTORY ── */
function initHistory() {
  $('clearHistoryBtn')?.addEventListener('click', () => {
    ST.history=[]; localStorage.removeItem('lv-history'); renderHistory();
    showToast('History cleared');
  });
}

function saveHistory(src, result, stats, elapsed) {
  ST.history.unshift({id:Date.now(),ts:new Date().toLocaleString(),preview:src.slice(0,100),result,stats,elapsed,layers:{...ST.layers}});
  if (ST.history.length>20) ST.history.pop();
  localStorage.setItem('lv-history', JSON.stringify(ST.history));
}

function renderHistory() {
  const c = $('historyEntries');
  if (!c) return;
  if (!ST.history.length) { c.innerHTML='<p style="color:var(--text-3);font-size:13px;">No history yet.</p>'; return; }
  c.innerHTML = ST.history.map((e,i)=>`
    <div class="hist-entry" data-i="${i}">
      <div class="hist-top">
        <span class="hist-name">Session #${ST.history.length-i}</span>
        <span class="hist-time">${e.ts}</span>
      </div>
      <div class="hist-meta">
        <span>${fmtBytes(e.stats?.originalBytes||0)} → ${fmtBytes(e.stats?.obfuscatedBytes||0)}</span>
        <span>${e.elapsed}s</span>
      </div>
      <div>
        ${e.layers?.vmMode?'<span class="htag vm">VM</span>':''}
        ${e.layers?.controlFlow?'<span class="htag cfg">CFG</span>':''}
        ${e.layers?.polymorphic?'<span class="htag base">POLY</span>':''}
      </div>
      <div class="hist-preview">${esc(e.preview)}</div>
    </div>
  `).join('');
  c.querySelectorAll('.hist-entry').forEach(el => {
    el.addEventListener('click', () => {
      const en = ST.history[+el.dataset.i];
      const ed = $('outputEditor'), ln = $('outLines');
      if (ed && en.result) {
        ed.value = en.result;
        const n = ed.value.split('\n').length;
        ln.textContent = Array.from({length:n},(_,i2)=>i2+1).join('\n')+'\n';
        ln.dataset.c = n;
      }
      applyView('obfuscator');
      showToast('Restored from history','success');
    });
  });
}

/* ── STATUS ── */
function initStatus() {
  const fab   = $('statusFab');
  const panel = $('statusPanel');
  if (fab && panel) {
    fab.addEventListener('click', () => {
      ST.statusOpen = !ST.statusOpen;
      localStorage.setItem('lv-status', ST.statusOpen?'1':'0');
      panel.classList.toggle('hidden', !ST.statusOpen);
    });
    panel.classList.toggle('hidden', !ST.statusOpen);
  }
}

async function checkEngine() {
  try {
    const t0  = performance.now();
    const res = await fetch('/api/status');
    const d   = await res.json();
    const rtt = Math.round(performance.now()-t0);

    const dot   = $('engDot');
    const label = $('engLabel');
    if (dot && label) {
      dot.className   = 'eng-dot '+(d.lua?'on':'warn');
      label.textContent = d.lua ? '✓ Lua 5.4 engine' : '⚠ No Lua engine';
    }

    const se = $('statusEngine');
    if (se) { se.textContent=d.engine||'—'; se.className='status-val '+(d.lua?'online':'warn'); }
    const sp = $('statusPing');
    if (sp) { sp.textContent=rtt+'ms'; sp.className='status-val '+(rtt<100?'online':rtt<400?'warn':'offline'); }
    const sv = $('statusVersion');
    if (sv) sv.textContent = d.version||'3.3.0';
    const ss = $('statusService');
    if (ss) { ss.innerHTML='<span class="status-dot online"></span>Online'; ss.className='status-val online'; }
  } catch {
    const dot = $('engDot');
    if (dot) dot.className='eng-dot';
    const se = $('statusService');
    if (se) { se.innerHTML='<span class="status-dot offline"></span>Offline'; se.className='status-val offline'; }
  }
}

async function pingServer() {
  try {
    const t0 = performance.now();
    await fetch('/api/status');
    const rtt = Math.round(performance.now()-t0);
    const sp = $('statusPing');
    if (sp) { sp.textContent=rtt+'ms'; sp.className='status-val '+(rtt<100?'online':rtt<400?'warn':'offline'); }
  } catch {}
}

/* ── SETTINGS ── */
function initSettings() {
  $('animSelect')?.addEventListener('change', e => {
    if (typeof ThemeSystem !== 'undefined') ThemeSystem.applyAnimLevel(e.target.value);
  });
  $('bgBlurSlider')?.addEventListener('input', updateBg);
  $('bgDimSlider') ?.addEventListener('input', updateBg);
  $('bgUrlInput')  ?.addEventListener('change', updateBg);
  $('bgUploadBtn') ?.addEventListener('click', () => $('bgFileInput')?.click());
  $('bgFileInput') ?.addEventListener('change', e => {
    const f = e.target.files[0]; if (!f) return;
    const r = new FileReader();
    r.onload = ev => {
      const inp = $('bgUrlInput'); if (inp) inp.value='(uploaded)';
      const img = document.getElementById('bg-image');
      if (img) { img.style.backgroundImage=`url(${ev.target.result})`; img.style.opacity='1'; }
    };
    r.readAsDataURL(f);
  });
  $('bgClearBtn')?.addEventListener('click', () => {
    const img = document.getElementById('bg-image');
    if (img) { img.style.backgroundImage=''; img.style.opacity='0'; }
    const inp = $('bgUrlInput'); if (inp) inp.value='';
  });
}

function updateBg() {
  const url   = $('bgUrlInput')?.value?.trim()||'';
  const blur  = +($('bgBlurSlider')?.value||0);
  const dim   = +($('bgDimSlider')?.value||0)/100;
  const img   = document.getElementById('bg-image');
  if (!img) return;
  if (url && !url.startsWith('(')) {
    img.style.backgroundImage = `url(${JSON.stringify(url)})`;
    img.style.opacity = String(1-dim);
    img.style.filter  = blur>0?`blur(${blur}px)`:'';
  }
}

/* ── KEYBOARD ── */
function initKeyboard() {
  document.addEventListener('keydown', e => {
    const ctrl = e.ctrlKey||e.metaKey;
    if (ctrl && e.key==='Enter')         { e.preventDefault(); runObfuscate(); }
    if (ctrl && e.key==='b')             { e.preventDefault(); applySidebar(!ST.sidebar); }
    if (ctrl && e.key==='j')             { e.preventDefault(); $('themeBtn')?.click(); }
    if (ctrl && e.shiftKey && e.key==='C'){ e.preventDefault(); $('copyBtn')?.click(); }
    if (e.key==='Escape') { $('errorCover').style.display='none'; }
  });
}

/* ── UTILS ── */
function fmtBytes(n) {
  if (!n) return '0B';
  if (n<1024) return n+'B';
  if (n<1048576) return (n/1024).toFixed(1)+'KB';
  return (n/1048576).toFixed(2)+'MB';
}
function esc(s) {
  return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}
function dlText(text, name) {
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([text],{type:'text/plain'}));
  a.download = name; a.click();
  setTimeout(()=>URL.revokeObjectURL(a.href),1000);
}
let _toastT;
function showToast(msg, type='') {
  clearTimeout(_toastT);
  const el = $('toast'); if (!el) return;
  el.textContent = msg;
  el.className = 'toast show'+(type?' '+type:'');
  _toastT = setTimeout(()=>el.classList.remove('show'), 3000);
}
