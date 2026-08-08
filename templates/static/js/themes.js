'use strict';
/**
 * Levititas v3.3 — Theme System
 * static/js/themes.js
 *
 * Built-in themes: dark | light | midnight | cyberpunk | frost | leviathan
 * User-created themes: stored in localStorage
 * Dynamic accent color switching
 * Full persistence across sessions
 */

const ThemeSystem = (() => {

  const STORAGE_KEY  = 'lv33-theme';
  const CUSTOM_KEY   = 'lv33-custom-themes';
  const ACCENT_KEY   = 'lv33-accent';
  const EFFECT_KEY   = 'lv33-effect';
  const BG_KEY       = 'lv33-bg';
  const ANIM_KEY     = 'lv33-anim';

  // ── Built-in themes ──────────────────────────────────────────
  const BUILTIN = {
    dark: {
      id: 'dark', name: 'Dark', icon: '🌑',
      preview: ['#0a0910','#100f1c','#7c5cfc','#ede9f8'],
    },
    light: {
      id: 'light', name: 'Light', icon: '☀️',
      preview: ['#f0eefb','#ffffff','#7c5cfc','#1a1730'],
    },
    midnight: {
      id: 'midnight', name: 'Midnight', icon: '🌊',
      preview: ['#000510','#000d1a','#0ea5e9','#ddeeff'],
    },
    cyberpunk: {
      id: 'cyberpunk', name: 'Cyberpunk', icon: '⚡',
      preview: ['#05000a','#0a0010','#ff00cc','#ffe0ff'],
    },
    frost: {
      id: 'frost', name: 'Frost', icon: '❄️',
      preview: ['#e8f4f8','#ffffff','#2563eb','#1a3050'],
    },
    leviathan: {
      id: 'leviathan', name: 'Leviathan', icon: '🐉',
      preview: ['#020408','#050c14','#00e096','#c0ffe0'],
    },
  };

  // ── Accent presets ────────────────────────────────────────────
  const ACCENTS = [
    { name: 'Purple',   value: '#7c5cfc', accent2: '#a78bfa', accent3: '#06b6d4' },
    { name: 'Blue',     value: '#2563eb', accent2: '#60a5fa', accent3: '#0ea5e9' },
    { name: 'Cyan',     value: '#06b6d4', accent2: '#38bdf8', accent3: '#7c3aed' },
    { name: 'Green',    value: '#22c55e', accent2: '#4ade80', accent3: '#06b6d4' },
    { name: 'Teal',     value: '#00e096', accent2: '#00ffaa', accent3: '#0066ff' },
    { name: 'Pink',     value: '#ec4899', accent2: '#f472b6', accent3: '#8b5cf6' },
    { name: 'Orange',   value: '#f59e0b', accent2: '#fbbf24', accent3: '#ef4444' },
    { name: 'Red',      value: '#ef4444', accent2: '#f87171', accent3: '#f59e0b' },
    { name: 'Magenta',  value: '#ff00cc', accent2: '#ff44ff', accent3: '#00ffcc' },
    { name: 'Indigo',   value: '#6366f1', accent2: '#818cf8', accent3: '#06b6d4' },
    { name: 'Rose',     value: '#f43f5e', accent2: '#fb7185', accent3: '#8b5cf6' },
    { name: 'Lime',     value: '#84cc16', accent2: '#a3e635', accent3: '#06b6d4' },
  ];

  // ── State ─────────────────────────────────────────────────────
  let state = {
    current:      localStorage.getItem(STORAGE_KEY)   || 'dark',
    accent:       localStorage.getItem(ACCENT_KEY)    || null,
    effect:       localStorage.getItem(EFFECT_KEY)    || 'none',
    bgUrl:        localStorage.getItem(BG_KEY)        || '',
    animLevel:    localStorage.getItem(ANIM_KEY)      || 'full',
    customThemes: JSON.parse(localStorage.getItem(CUSTOM_KEY) || '{}'),
  };

  // ── Apply theme ───────────────────────────────────────────────
  function applyTheme(id) {
    const theme = BUILTIN[id] || state.customThemes[id];
    if (!theme) return;
    state.current = id;
    localStorage.setItem(STORAGE_KEY, id);
    document.documentElement.setAttribute('data-theme', id);

    // If custom theme has CSS vars, inject them
    if (theme.vars) {
      const el = document.getElementById('custom-theme-style') ||
                 (() => {
                   const s = document.createElement('style');
                   s.id = 'custom-theme-style';
                   document.head.appendChild(s);
                   return s;
                 })();
      const vars = Object.entries(theme.vars)
        .map(([k,v]) => `  ${k}: ${v};`).join('\n');
      el.textContent = `[data-theme="${id}"] {\n${vars}\n}`;
    }

    updateThemeGrid();
  }

  // ── Apply accent ──────────────────────────────────────────────
  function applyAccent(accentObj) {
    const root = document.documentElement;
    if (typeof accentObj === 'string') {
      // Custom hex color
      root.style.setProperty('--accent', accentObj);
      state.accent = accentObj;
    } else {
      root.style.setProperty('--accent',   accentObj.value);
      root.style.setProperty('--accent-2', accentObj.accent2);
      root.style.setProperty('--accent-3', accentObj.accent3);
      root.style.setProperty('--accent-glow', hexToRgba(accentObj.value, 0.3));
      root.style.setProperty('--accent-soft', hexToRgba(accentObj.value, 0.1));
      root.style.setProperty('--accent-mid',  hexToRgba(accentObj.value, 0.2));
      state.accent = accentObj.value;
    }
    localStorage.setItem(ACCENT_KEY, state.accent);
    updateAccentGrid();
  }

  function hexToRgba(hex, alpha) {
    const r = parseInt(hex.slice(1,3),16);
    const g = parseInt(hex.slice(3,5),16);
    const b = parseInt(hex.slice(5,7),16);
    return `rgba(${r},${g},${b},${alpha})`;
  }

  // ── Apply background ──────────────────────────────────────────
  function applyBackground(url, blurPx = 0, dimOpacity = 0) {
    const el = document.getElementById('bg-image');
    if (!el) return;
    state.bgUrl = url;
    localStorage.setItem(BG_KEY, url);
    if (url) {
      el.style.backgroundImage = `url(${JSON.stringify(url)})`;
      el.style.filter = blurPx > 0 ? `blur(${blurPx}px)` : '';
      el.style.opacity = String(1 - dimOpacity);
    } else {
      el.style.backgroundImage = '';
      el.style.opacity = '0';
    }
  }

  // ── Apply animation level ─────────────────────────────────────
  function applyAnimLevel(level) {
    // level: 'full' | 'reduced' | 'none'
    state.animLevel = level;
    localStorage.setItem(ANIM_KEY, level);
    const root = document.documentElement;
    if (level === 'none') {
      root.style.setProperty('--transition',    '0s');
      root.style.setProperty('--transition-lg', '0s');
      root.style.setProperty('--spring',        '0s');
    } else if (level === 'reduced') {
      root.style.setProperty('--transition',    '0.08s');
      root.style.setProperty('--transition-lg', '0.15s');
      root.style.setProperty('--spring',        '0.2s');
    } else {
      root.style.removeProperty('--transition');
      root.style.removeProperty('--transition-lg');
      root.style.removeProperty('--spring');
    }
  }

  // ── Create user theme ─────────────────────────────────────────
  function createUserTheme(id, name, icon, vars) {
    const theme = { id, name, icon, preview: ['#000','#111','#fff','#eee'], vars };
    state.customThemes[id] = theme;
    localStorage.setItem(CUSTOM_KEY, JSON.stringify(state.customThemes));
    updateThemeGrid();
    return theme;
  }

  function deleteUserTheme(id) {
    if (BUILTIN[id]) return; // can't delete built-ins
    delete state.customThemes[id];
    localStorage.setItem(CUSTOM_KEY, JSON.stringify(state.customThemes));
    if (state.current === id) applyTheme('dark');
    updateThemeGrid();
  }

  // ── UI: render theme grid ─────────────────────────────────────
  function updateThemeGrid() {
    const grid = document.getElementById('themeGrid');
    if (!grid) return;
    const all = { ...BUILTIN, ...state.customThemes };
    grid.innerHTML = Object.values(all).map(t => `
      <div class="theme-card ${t.id === state.current ? 'active' : ''}"
           data-theme-id="${t.id}"
           title="${t.name}">
        <canvas class="theme-preview" width="80" height="60"
                data-colors="${JSON.stringify(t.preview)}"></canvas>
        <span class="theme-name">${t.icon || ''} ${t.name}</span>
      </div>
    `).join('');

    // Draw preview swatches
    grid.querySelectorAll('.theme-preview').forEach(c => {
      const colors = JSON.parse(c.dataset.colors || '[]');
      const ctx = c.getContext('2d');
      const W = c.width, H = c.height;
      colors.forEach((col, i) => {
        ctx.fillStyle = col;
        ctx.fillRect(i * W/colors.length, 0, W/colors.length, H);
      });
      // Overlay name
      ctx.fillStyle = 'rgba(0,0,0,0.35)';
      ctx.fillRect(0, H-20, W, 20);
    });

    // Click handlers
    grid.querySelectorAll('.theme-card').forEach(card => {
      card.addEventListener('click', () => applyTheme(card.dataset.themeId));
    });
  }

  // ── UI: render accent grid ────────────────────────────────────
  function updateAccentGrid() {
    const grid = document.getElementById('accentGrid');
    if (!grid) return;
    grid.innerHTML = ACCENTS.map(a => `
      <div class="accent-swatch ${state.accent === a.value ? 'active' : ''}"
           style="background:${a.value}"
           data-accent='${JSON.stringify(a)}'
           title="${a.name}"></div>
    `).join('');
    grid.querySelectorAll('.accent-swatch').forEach(sw => {
      sw.addEventListener('click', () => applyAccent(JSON.parse(sw.dataset.accent)));
    });
  }

  // ── UI: render effect grid ────────────────────────────────────
  function updateEffectGrid() {
    const grid = document.getElementById('effectGrid');
    if (!grid) return;
    const effects = [
      { id:'none',      icon:'✕',  name:'None'      },
      { id:'snow',      icon:'❄️', name:'Snow'      },
      { id:'rain',      icon:'🌧️', name:'Rain'     },
      { id:'particles', icon:'✦',  name:'Particles' },
      { id:'stars',     icon:'★',  name:'Stars'     },
      { id:'matrix',    icon:'⌨', name:'Matrix'    },
      { id:'dots',      icon:'●',  name:'Dots'      },
    ];
    grid.innerHTML = effects.map(e => `
      <div class="effect-card ${state.effect === e.id ? 'active' : ''}"
           data-effect="${e.id}">
        <div class="effect-icon">${e.icon}</div>
        <div class="effect-name">${e.name}</div>
      </div>
    `).join('');
    grid.querySelectorAll('.effect-card').forEach(card => {
      card.addEventListener('click', () => {
        const id = card.dataset.effect;
        state.effect = id;
        localStorage.setItem(EFFECT_KEY, id);
        if (typeof Effects !== 'undefined') Effects.start(id === 'none' ? null : id);
        updateEffectGrid();
      });
    });
  }

  // ── Init ─────────────────────────────────────────────────────
  function init() {
    applyTheme(state.current);
    if (state.accent) {
      const preset = ACCENTS.find(a => a.value === state.accent);
      if (preset) applyAccent(preset);
    }
    if (state.bgUrl) applyBackground(state.bgUrl);
    applyAnimLevel(state.animLevel);

    // Start effect after Effects module inits
    if (state.effect && state.effect !== 'none') {
      setTimeout(() => {
        if (typeof Effects !== 'undefined') Effects.start(state.effect);
      }, 100);
    }

    updateThemeGrid();
    updateAccentGrid();
    updateEffectGrid();
  }

  // ── Public API ────────────────────────────────────────────────
  return {
    init,
    applyTheme,
    applyAccent,
    applyBackground,
    applyAnimLevel,
    createUserTheme,
    deleteUserTheme,
    updateThemeGrid,
    updateAccentGrid,
    updateEffectGrid,
    getState: () => ({ ...state }),
    BUILTIN,
    ACCENTS,
  };

})();
