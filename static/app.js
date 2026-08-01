'use strict';

/* ─── State ──────────────────────────────────────────────── */
const state = {
  layers: {
    mangleNames:    true,
    encryptStrings: true,
    encodeNumbers:  true,
    injectJunk:     true,
    antiDebug:      true,
    stripComments:  true,
    controlFlow:    true,
    polymorphic:    true,
    wrapEnv:        true,
    vmMode:         true,
  },
  protectNames: [],
  theme:   localStorage.getItem('lv2-theme')   || 'dark',
  sidebar: localStorage.getItem('lv2-sidebar') !== '1',
  view:    'obfuscator',
  history: JSON.parse(localStorage.getItem('lv2-history') || '[]'),
  batchFiles: [],
};

// Layer weights for strength meter (total = 100)
const LAYER_WEIGHTS = {
  mangleNames:    8,
  encryptStrings: 12,
  encodeNumbers:  8,
  injectJunk:     7,
  antiDebug:      8,
  stripComments:  2,
  controlFlow:    15,
  polymorphic:    10,
  wrapEnv:        10,
  vmMode:         20,
};

/* ─── DOM ─────────────────────────────────────────────────── */
const $ = id => document.getElementById(id);
const $$ = s => document.querySelectorAll(s);

/* ─── Theme ───────────────────────────────────────────────── */
const applyTheme = t => {
  state.theme = t;
  document.documentElement.setAttribute('data-theme', t);
  localStorage.setItem('lv2-theme', t);
};
applyTheme(state.theme);
$('themeBtn').addEventListener('click', () =>
  applyTheme(state.theme === 'dark' ? 'light' : 'dark'));

/* ─── Sidebar ─────────────────────────────────────────────── */
const setSidebar = open => {
  state.sidebar = open;
  $('sidebar').classList.toggle('collapsed', !open);
  localStorage.setItem('lv2-sidebar', open ? '0' : '1');
};
$('collapseBtn').addEventListener('click', () => setSidebar(false));
$('expandBtn').addEventListener('click',   () => setSidebar(true));
setSidebar(state.sidebar);

// Mobile
const openMobile  = () => { $('sidebar').classList.add('mobile-open');    $('sidebarBackdrop').style.display='block'; };
const closeMobile = () => { $('sidebar').classList.remove('mobile-open'); $('sidebarBackdrop').style.display='none';  };
$('mobileSidebarBtn').addEventListener('click', openMobile);
$('sidebarBackdrop').addEventListener('click',  closeMobile);

/* ─── Navigation ──────────────────────────────────────────── */
const switchView = view => {
  state.view = view;
  $$('.nav-item').forEach(el => el.classList.toggle('active', el.dataset.view === view));
  $$('.view-overlay').forEach(el => el.classList.toggle('active', el.dataset.view === view));
  $('viewTitle').textContent = {obfuscator:'Obfuscator',batch:'Batch Mode',history:'History',docs:'Docs'}[view] || view;
  if (view === 'history') renderHistory();
  closeMobile();
};
$$('.nav-item').forEach(el => el.addEventListener('click', () => switchView(el.dataset.view)));

/* ─── Strength Meter ──────────────────────────────────────── */
const updateStrength = () => {
  let score = 0;
  for (const [key, w] of Object.entries(LAYER_WEIGHTS)) {
    if (state.layers[key]) score += w;
  }
  const fill  = $('strengthFill');
  const pct   = $('strengthPct');
  const grade = $('strengthGrade');
  fill.style.width = score + '%';
  pct.textContent  = score + '%';
  let color, label;
  if      (score >= 90) { color='var(--success)';  label='ELITE'; }
  else if (score >= 75) { color='var(--accent-2)'; label='STRONG'; }
  else if (score >= 55) { color='var(--cfg-color)';label='MEDIUM'; }
  else if (score >= 30) { color='var(--warning)';  label='WEAK'; }
  else                  { color='var(--error)';    label='BARE'; }
  fill.style.background   = color;
  pct.style.color         = color;
  grade.textContent       = label;
  grade.style.background  = color + '22';
  grade.style.color       = color;
};
updateStrength();

/* ─── Toggle switches ─────────────────────────────────────── */
$$('.toggle-switch').forEach(sw => {
  sw.addEventListener('click', e => {
    const key = sw.dataset.key;
    if (!key) return;
    state.layers[key] = !state.layers[key];
    sw.classList.toggle('on', state.layers[key]);
    updateStrength();
    e.stopPropagation();
  });
});

/* ─── Protected names ─────────────────────────────────────── */
const renderTags = () => {
  const c = $('protectTags'); c.innerHTML = '';
  state.protectNames.forEach((n, i) => {
    const tag = document.createElement('span');
    tag.className = 'protect-tag';
    tag.innerHTML = `${n}<button data-i="${i}">✕</button>`;
    tag.querySelector('button').onclick = () => { state.protectNames.splice(i,1); renderTags(); };
    c.appendChild(tag);
  });
};
$('protectInput').addEventListener('keydown', e => {
  if (e.key === 'Enter' || e.key === ',') {
    e.preventDefault();
    $('protectInput').value.split(',').map(s=>s.trim()).filter(Boolean).forEach(n => {
      if (!state.protectNames.includes(n)) state.protectNames.push(n);
    });
    $('protectInput').value = '';
    renderTags();
  }
});

/* ─── Line numbers ────────────────────────────────────────── */
const updateLines = (editor, nums) => {
  const n = editor.value.split('\n').length;
  if (parseInt(nums.dataset.count||0) === n) return;
  nums.dataset.count = n;
  let s = ''; for (let i=1;i<=n;i++) s+=i+'\n';
  nums.textContent = s;
};
const syncScroll = (editor, nums) => { nums.scrollTop = editor.scrollTop; };

const inEd  = $('inputEditor'),  inLn  = $('inLines');
const outEd = $('outputEditor'), outLn = $('outLines');

inEd.addEventListener('input',  () => updateLines(inEd, inLn));
inEd.addEventListener('scroll', () => syncScroll(inEd, inLn));
outEd.addEventListener('scroll',() => syncScroll(outEd, outLn));
inEd.addEventListener('keydown', e => {
  if (e.key === 'Tab') {
    e.preventDefault();
    const s = inEd.selectionStart, v = inEd.value;
    inEd.value = v.slice(0,s)+'    '+v.slice(inEd.selectionEnd);
    inEd.selectionStart = inEd.selectionEnd = s+4;
    updateLines(inEd, inLn);
  }
});
updateLines(inEd, inLn);

/* ─── Toast ───────────────────────────────────────────────── */
let _toastTimer;
const toast = (msg, type='') => {
  clearTimeout(_toastTimer);
  const el = $('toast');
  el.textContent = msg;
  el.className = 'toast show ' + type;
  _toastTimer = setTimeout(() => el.classList.remove('show'), 3000);
};

/* ─── File upload ─────────────────────────────────────────── */
$('uploadBtn').addEventListener('click', () => $('fileInput').click());
$('fileInput').addEventListener('change', () => {
  const f = $('fileInput').files[0]; if(!f) return;
  const r = new FileReader();
  r.onload = () => { inEd.value=r.result; updateLines(inEd,inLn); toast('Loaded: '+f.name,'success'); $('fileInput').value=''; };
  r.readAsText(f);
});

// Drag-drop
$('inputPane').addEventListener('dragover', e => { e.preventDefault(); $('inputPane').style.outline='2px solid var(--accent)'; });
$('inputPane').addEventListener('dragleave',() => $('inputPane').style.outline='');
$('inputPane').addEventListener('drop', e => {
  e.preventDefault(); $('inputPane').style.outline='';
  const f = e.dataTransfer.files[0];
  if (!f || !f.name.endsWith('.lua')) { toast('Only .lua files','error'); return; }
  new FileReader().onload = ev => { inEd.value=ev.target.result; updateLines(inEd,inLn); toast('Loaded: '+f.name,'success'); };
  new FileReader().readAsText(f);
  // fix: use single reader
  const rd = new FileReader();
  rd.onload = ev => { inEd.value=ev.target.result; updateLines(inEd,inLn); toast('Loaded: '+f.name,'success'); };
  rd.readAsText(f);
});

/* ─── Clear / Example ─────────────────────────────────────── */
$('clearBtn').addEventListener('click', () => {
  inEd.value=''; outEd.value='';
  $('statsBar').style.display='none';
  updateLines(inEd,inLn); updateLines(outEd,outLn);
});

$('exampleBtn').addEventListener('click', () => {
  inEd.value = `-- Levititas v2 Example
local VERSION = "2.0.0"
local SECRET_KEY = "my_super_secret_token_abc123"
local API_ENDPOINT = "https://api.example.com/data"

local function hashString(input, salt)
    local result = ""
    for i = 1, #input do
        local byte = string.byte(input, i)
        local keyByte = string.byte(salt, ((i-1) % #salt) + 1)
        result = result .. string.char(byte ~ keyByte)
    end
    return result
end

local function validateUser(username, password)
    local hash = hashString(password, SECRET_KEY)
    local users = {
        admin = hashString("admin_pass_123", SECRET_KEY),
        guest = hashString("guest_pass_456", SECRET_KEY),
    }
    return users[username] == hash
end

local playerData = {
    level = 99,
    coins = 50000,
    premium = true,
    token = SECRET_KEY,
}

if validateUser("admin", "admin_pass_123") then
    print("[AUTH] Welcome, admin! Level:", playerData.level)
    for k, v in pairs(playerData) do
        print("  " .. k .. " =", tostring(v))
    end
else
    print("[AUTH] Access denied.")
end`;
  updateLines(inEd, inLn);
  toast('Example loaded!', 'success');
});

/* ─── Copy / Download ─────────────────────────────────────── */
$('copyBtn').addEventListener('click', () => {
  if (!outEd.value) { toast('Nothing to copy','error'); return; }
  navigator.clipboard.writeText(outEd.value)
    .then(()=>toast('Copied!','success'))
    .catch(()=>{ outEd.select(); document.execCommand('copy'); toast('Copied!','success'); });
});
$('downloadBtn').addEventListener('click', () => {
  if (!outEd.value) { toast('Nothing to download','error'); return; }
  dlText(outEd.value, 'obfuscated.lua');
  toast('Downloaded!', 'success');
});

/* ─── Engine status check ─────────────────────────────────── */
(async () => {
  try {
    const r = await fetch('/api/status');
    const d = await r.json();
    const dot   = $('engineDot');
    const label = $('engineLabel');
    if (d.lua) {
      dot.className   = 'engine-dot full';
      label.textContent = '✓ Lua engine (full VM)';
    } else {
      dot.className   = 'engine-dot fallback';
      label.textContent = 'Python engine (fallback)';
    }
  } catch { /* server not running in preview */ }
})();

/* ─── OBFUSCATE ───────────────────────────────────────────── */
const loadingMsgs = [
  'Flattening control flow…',
  'Encrypting strings…',
  'Virtualizing numbers…',
  'Building custom VM…',
  'Injecting dead code…',
  'Wrapping environments…',
  'Applying polymorphic transforms…',
  'Finalizing…',
];
let _msgIdx = 0, _msgTimer;

async function runObfuscate() {
  const src = inEd.value.trim();
  if (!src) { toast('Paste some Lua code first','error'); return; }

  $('obfBtn').classList.add('loading');
  $('obfLoading').style.display = 'flex';
  $('obfError').style.display   = 'none';
  outEd.value = '';
  $('statsBar').style.display = 'none';

  // Cycle loading messages
  _msgIdx = 0;
  $('loadingMsg').textContent = loadingMsgs[0];
  _msgTimer = setInterval(() => {
    _msgIdx = (_msgIdx + 1) % loadingMsgs.length;
    $('loadingMsg').textContent = loadingMsgs[_msgIdx];
  }, 600);

  try {
    const res  = await fetch('/api/obfuscate', {
      method: 'POST',
      headers: {'Content-Type':'application/json'},
      body: JSON.stringify({ source: src, options: { ...state.layers, protectNames: state.protectNames } }),
    });
    const data = await res.json();

    clearInterval(_msgTimer);
    if (!data.ok) {
      $('obfError').style.display = 'flex';
      $('obfErrorMsg').textContent = data.error || 'Obfuscation failed.';
      toast(data.error || 'Failed', 'error');
      return;
    }

    outEd.value = data.result;
    updateLines(outEd, outLn);

    const s = data.stats || {};
    $('statsBar').style.display = 'flex';
    $('statOrig').textContent  = fmt(s.originalBytes);
    $('statObf').textContent   = fmt(s.obfuscatedBytes);
    $('statRatio').textContent = (s.ratio||0) + '×';
    $('statLines').textContent = (s.originalLines||0) + '→' + (s.obfuscatedLines||0);
    $('statTime').textContent  = (data.elapsed||0) + 's';
    $('statNote').textContent  = data.note || '';

    toast('Obfuscated! ' + (state.layers.vmMode ? '⚙️VM' : '') + (state.layers.controlFlow ? ' 🌀CFG' : ''), 'success');
    saveHistory(src, data.result, s, data.elapsed);
  } catch(err) {
    clearInterval(_msgTimer);
    $('obfError').style.display = 'flex';
    $('obfErrorMsg').textContent = 'Network error: ' + err.message;
    toast('Network error','error');
  } finally {
    $('obfBtn').classList.remove('loading');
    $('obfLoading').style.display = 'none';
  }
}

$('obfBtn').addEventListener('click', runObfuscate);

/* ─── Keyboard shortcuts ──────────────────────────────────── */
document.addEventListener('keydown', e => {
  if ((e.ctrlKey||e.metaKey) && e.key==='Enter')      { e.preventDefault(); runObfuscate(); }
  if ((e.ctrlKey||e.metaKey) && e.key==='b')          { e.preventDefault(); setSidebar(!state.sidebar); }
  if ((e.ctrlKey||e.metaKey) && e.key==='j')          { e.preventDefault(); applyTheme(state.theme==='dark'?'light':'dark'); }
  if ((e.ctrlKey||e.metaKey) && e.shiftKey && e.key==='C') { e.preventDefault(); $('copyBtn').click(); }
});

/* ─── History ─────────────────────────────────────────────── */
const saveHistory = (src, result, stats, elapsed) => {
  state.history.unshift({
    id: Date.now(), ts: new Date().toLocaleString(),
    preview: src.slice(0,120), result, stats, elapsed,
    layers: {...state.layers},
  });
  if (state.history.length > 20) state.history.pop();
  localStorage.setItem('lv2-history', JSON.stringify(state.history));
};

const renderHistory = () => {
  const c = $('historyEntries');
  if (!state.history.length) {
    c.innerHTML = '<p style="color:var(--text-tertiary);font-size:13px;">No history yet.</p>'; return;
  }
  c.innerHTML = state.history.map((e,i) => `
    <div class="history-entry" data-i="${i}">
      <div class="history-entry-top">
        <span class="history-entry-name">Session #${state.history.length-i}</span>
        <span class="history-entry-time">${e.ts}</span>
      </div>
      <div class="history-entry-meta">
        <span>${fmt(e.stats?.originalBytes||0)} → ${fmt(e.stats?.obfuscatedBytes||0)}</span>
        <span>${e.stats?.originalLines||0} → ${e.stats?.obfuscatedLines||0} lines</span>
        <span>${e.elapsed||0}s</span>
      </div>
      <div style="margin-top:5px;">
        ${e.layers?.vmMode      ?'<span class="htag vm">VM</span>':''}
        ${e.layers?.controlFlow ?'<span class="htag cfg">CFG</span>':''}
        ${e.layers?.polymorphic ?'<span class="htag base">POLY</span>':''}
        ${e.layers?.wrapEnv     ?'<span class="htag base">ENV</span>':''}
      </div>
      <div style="margin-top:5px;font-family:var(--font-mono);font-size:11px;color:var(--text-tertiary);overflow:hidden;white-space:nowrap;text-overflow:ellipsis;">${esc(e.preview)}</div>
    </div>`).join('');
  c.querySelectorAll('.history-entry').forEach(el => {
    el.addEventListener('click', () => {
      const en = state.history[+el.dataset.i];
      inEd.value = en.result; updateLines(inEd,inLn);
      outEd.value=''; switchView('obfuscator');
      toast('Restored from history','success');
    });
  });
};
$('clearHistoryBtn').addEventListener('click', () => {
  state.history=[]; localStorage.removeItem('lv2-history'); renderHistory();
  toast('History cleared');
});

/* ─── Batch Mode ──────────────────────────────────────────── */
const batchDrop = $('batchDrop');

const addBatchFiles = files => {
  for (const f of files) {
    if (!f.name.endsWith('.lua')) { toast('Skipping: '+f.name,'error'); continue; }
    state.batchFiles.push({file:f, name:f.name, size:f.size, status:'pending', result:null});
  }
  renderBatch();
};

const renderBatch = () => {
  const list    = $('batchList');
  const actions = $('batchActions');
  if (!state.batchFiles.length) { list.style.display='none'; actions.style.display='none'; return; }
  list.style.display='block'; actions.style.display='flex';
  list.innerHTML = state.batchFiles.map((f,i)=>`
    <div class="batch-file-row">
      <span class="batch-file-name">${esc(f.name)}</span>
      <span class="batch-file-size">${fmt(f.size)}</span>
      <span class="batch-file-status ${f.status}">${
        {pending:'Pending',running:'⏳ Running',done:'✓ Done',error:'✗ Error'}[f.status]
      }</span>
      ${f.status==='done'?`<span class="batch-dl" data-i="${i}">Download</span>`:''}
      <button class="pane-btn batch-rm" data-i="${i}" style="margin-left:auto;padding:3px 8px;">✕</button>
    </div>`).join('');
  list.querySelectorAll('.batch-rm').forEach(b=>b.onclick=()=>{ state.batchFiles.splice(+b.dataset.i,1); renderBatch(); });
  list.querySelectorAll('.batch-dl').forEach(b=>b.onclick=()=>{
    const f=state.batchFiles[+b.dataset.i]; if(f.result) dlText(f.result,f.name.replace('.lua','_obf.lua'));
  });
};

$('batchBrowseBtn').addEventListener('click',()=>$('batchFileInput').click());
$('batchFileInput').addEventListener('change',()=>{ addBatchFiles($('batchFileInput').files); $('batchFileInput').value=''; });
batchDrop.addEventListener('dragover',e=>{e.preventDefault();batchDrop.classList.add('drag-over');});
batchDrop.addEventListener('dragleave',()=>batchDrop.classList.remove('drag-over'));
batchDrop.addEventListener('drop',e=>{e.preventDefault();batchDrop.classList.remove('drag-over');addBatchFiles(e.dataTransfer.files);});
$('clearBatchBtn').addEventListener('click',()=>{ state.batchFiles=[]; $('downloadAllBtn').style.display='none'; renderBatch(); });

$('runBatchBtn').addEventListener('click', async () => {
  const pending = state.batchFiles.filter(f=>f.status==='pending'||f.status==='error');
  if (!pending.length) { toast('No pending files','error'); return; }
  $('runBatchBtn').disabled = true;
  let done = 0;
  for (const f of state.batchFiles) {
    if (f.status==='done') continue;
    f.status='running'; renderBatch();
    try {
      const text = await f.file.text();
      const res  = await fetch('/api/obfuscate',{
        method:'POST', headers:{'Content-Type':'application/json'},
        body:JSON.stringify({source:text, options:{...state.layers, protectNames:state.protectNames}}),
      });
      const d = await res.json();
      f.status = d.ok ? 'done' : 'error';
      if (d.ok) { f.result=d.result; done++; }
    } catch { f.status='error'; }
    renderBatch();
  }
  $('runBatchBtn').disabled=false;
  toast(`Done! ${done} file(s) obfuscated.`, 'success');
  if (done>0) $('downloadAllBtn').style.display='inline-flex';
});

$('downloadAllBtn').addEventListener('click', async ()=>{
  const done = state.batchFiles.filter(f=>f.status==='done'&&f.result);
  if (!done.length) { toast('No completed files','error'); return; }
  for (const f of done) {
    await new Promise(r=>setTimeout(r,180));
    dlText(f.result, f.name.replace('.lua','_obf.lua'));
  }
  toast(`Downloading ${done.length} file(s)…`,'success');
});

/* ─── Utilities ───────────────────────────────────────────── */
const fmt = n => {
  if (!n) return '0B';
  if (n<1024) return n+'B';
  if (n<1048576) return (n/1024).toFixed(1)+'KB';
  return (n/1048576).toFixed(2)+'MB';
};
const esc = s => s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
const dlText = (text, name) => {
  const a = Object.assign(document.createElement('a'),{
    href: URL.createObjectURL(new Blob([text],{type:'text/plain'})),
    download: name,
  });
  a.click(); setTimeout(()=>URL.revokeObjectURL(a.href),1000);
};

/* ─── Init ────────────────────────────────────────────────── */
updateLines(inEd, inLn);
updateLines(outEd, outLn);
