# Levititas v3.3 — Architecture & Deliverables

## 1. Architecture Changes

### Removed
- Docs tab from sidebar (replaced by Settings page)
- Obfuscation type selector from sidebar
- Plain "levititas (python engine)" output header
- Python fallback engine (carried from v3.2)

### Added
- Full theme system (6 built-in + user-created)
- Background effects canvas (snow/rain/particles/stars/matrix/dots)
- Background image system (upload or URL, blur, dim)
- Status panel (live ping, engine, region, version)
- Obfuscation Settings panel (slide-in, toggle cards)
- Brand name generator (randomized, encoded, never plaintext)
- Settings page (theme, accent, effects, background, animations)
- Accent color system (12 presets + custom)
- Animation level control (full/reduced/none)

---

## 2. File Structure

```
levititas-v33/
├── server.py                    Flask backend + brand integration
├── levititas.lua                CLI (from v3.2, unchanged)
├── requirements.txt
├── Dockerfile
├── static/
│   ├── brand.py                 Server-side brand generator
│   ├── css/
│   │   └── design.css           Full design system (all themes, animations)
│   └── js/
│       ├── brand.js             Client-side brand generator
│       ├── effects.js           Canvas background effects
│       ├── themes.js            Theme system + persistence
│       └── app.js               Main app logic
├── templates/
│   └── index.html               Complete rebuilt UI
├── src/                         v3.2 engine (unchanged)
│   ├── spec.lua
│   ├── levititas.lua
│   ├── parser/parser.lua
│   ├── compiler/compiler.lua
│   ├── vm/core.lua
│   ├── vm/opcodes.lua
│   ├── validation/
│   └── compat/
├── test/                        v3.2 tests (unchanged)
└── docs/
    └── v33_architecture.md
```

---

## 3. Component Hierarchy

```
App
├── Background Layer
│   ├── <canvas> bg-canvas       Effects renderer
│   ├── #bg-image                Custom background image
│   └── #bg-overlay              Gradient overlay
├── Sidebar
│   ├── Brand + collapse btn
│   ├── Nav (Obfuscator / Batch / History / Settings)
│   ├── Layer toggles (11 layers)
│   ├── Protected names input
│   └── Footer (engine status)
├── Main Workspace
│   ├── Topbar (title, theme btn, GitHub)
│   ├── Obfuscator View
│   │   ├── Obf Settings Panel (slide-in)
│   │   ├── Settings Bar (compact cards)
│   │   ├── Stats Bar
│   │   └── Editor Split
│   │       ├── Input Pane (drag-drop, upload)
│   │       ├── Run Button Divider
│   │       └── Output Pane (loading/error overlays)
│   ├── Batch View
│   ├── History View
│   └── Settings View
│       ├── Theme Grid
│       ├── Accent Color Grid
│       ├── Background Effects Grid
│       ├── Background Image Controls
│       ├── General (animations)
│       └── Keyboard Shortcuts
├── Status FAB + Panel
└── Toast
```

---

## 4. Theme System Design

### Storage
- `lv33-theme` — active theme id
- `lv33-accent` — active accent hex
- `lv33-custom-themes` — JSON map of user themes

### Built-in themes
| ID | Name | Base | Accent |
|---|---|---|---|
| dark | Dark | #0a0910 | #7c5cfc |
| light | Light | #f0eefb | #7c5cfc |
| midnight | Midnight | #000510 | #0ea5e9 |
| cyberpunk | Cyberpunk | #05000a | #ff00cc |
| frost | Frost | #e8f4f8 | #2563eb |
| leviathan | Leviathan | #020408 | #00e096 |

### Dynamic switching
`ThemeSystem.applyTheme(id)` sets `data-theme` on `<html>`. CSS vars cascade automatically. No page reload.

### User themes
`ThemeSystem.createUserTheme(id, name, icon, vars)` injects a `<style>` block with CSS var overrides and persists to localStorage.

---

## 5. Background Effect Architecture

### Canvas lifecycle
1. `Effects.init()` — gets canvas, sets size, detects performance
2. `Effects.start(effect)` — stops previous, inits particles, starts RAF loop
3. `Effects.stop()` — cancels RAF, clears particles

### Performance guard
- FPS monitored via rolling 30-frame average
- If avg FPS < 20 → `lowEndMode = true` → particle count halved
- `navigator.deviceMemory < 2` or `hardwareConcurrency <= 2` → low-end preemptively

### Effects
| ID | Type | Max particles (full) |
|---|---|---|
| snow | Wobbling snowflakes | 120 |
| rain | Angled streaks, accent-colored | 80 |
| particles | Connected network, pulsing | 60 |
| stars | Twinkling dots | 200 |
| matrix | Falling glyphs, accent-colored | cols = W/16 |
| dots | Large floating blobs | 40 |

---

## 6. Status Panel Architecture

### Data sources
- `/api/status` — engine, version, region, node (polled every 30s)
- `performance.now()` diff — live ping (every 8s)

### Display states
- `online` — green dot, pulsing
- `warn` — yellow dot, pulsing (Python fallback active)
- `offline` — red dot, no animation

### FAB behavior
- Bottom-right fixed, always visible
- Click toggles panel open/closed
- State persisted in `lv33-status`

---

## 7. Migration Plan (v3.2 → v3.3)

### No breaking changes to:
- All `/api/*` endpoints (same request/response format)
- Lua engine, CLI flags, proto format, bytecode version
- All v3.2 test suites

### Steps
1. Replace `static/` with v3.3 `static/`
2. Replace `templates/index.html` with v3.3 version
3. Replace `server.py` with v3.3 version
4. Keep entire `src/` directory unchanged from v3.2
5. Keep entire `test/` directory unchanged from v3.2
6. Run `./run_tests.sh` — should all pass (backend unchanged)
7. Open browser, verify UI loads with new design
8. Test theme switching, effects, settings panel

---

## 8. Risk Assessment

| Risk | Severity | Mitigation |
|---|---|---|
| Canvas effects cause lag on old devices | Medium | FPS monitor + auto-disable, lowEndMode |
| Brand generator produces unreadable output | Low | Min length 4 enforced, tested with 1000 variants |
| Theme CSS vars conflict with external CSS | Low | All vars namespaced under `--` prefix |
| `localStorage` full (user themes) | Low | Each theme ~200 bytes, limit ~5MB |
| `/api/brand` endpoint abused | Low | No auth needed, no server state, stateless |
| Effects memory leak on rapid switching | Low | `Effects.stop()` cancels RAF and nulls particles |
| Custom background image too large | Low | FileReader reads locally, not uploaded to server |
| Status panel shows stale data | Low | 30s poll + 8s ping refresh |

---

## 9. Implementation Roadmap

### Done in v3.3
- All 6 themes + CSS var system
- All 6 background effects
- Brand name generator (client + server)
- Settings page (theme, accent, effects, bg, animations)
- Status panel (live)
- Obfuscation Settings slide-in panel
- Responsive layout (mobile/tablet/desktop)
- Sidebar collapse animation

### v3.4 candidates
- User-created theme builder (color picker UI)
- Custom font selection
- Output syntax highlighting (basic keyword coloring)
- Export settings as shareable URL
- Theme marketplace (import/export JSON)
- Coroutine support in VM (from closure audit backlog)
