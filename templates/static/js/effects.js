/**
 * Levititas v3.3 — Background Effects System
 * static/js/effects.js
 *
 * Effects: snow | rain | particles | stars | matrix | dots
 * - Toggleable per effect
 * - Performance-aware (FPS monitor, auto-disable on low-end)
 * - requestAnimationFrame-based, no blocking
 * - Cleans up properly when switched
 */

'use strict';

const Effects = (() => {

  // ── State ────────────────────────────────────────────────────
  let canvas, ctx, W, H;
  let currentEffect = null;
  let animFrame = null;
  let particles  = [];
  let lastTime   = 0;
  let fpsHistory = [];
  let lowEndMode = false;

  // ── Init ─────────────────────────────────────────────────────
  function init() {
    canvas = document.getElementById('bg-canvas');
    if (!canvas) return;
    ctx = canvas.getContext('2d');
    resize();
    window.addEventListener('resize', resize, { passive: true });
    detectPerformance();
  }

  function resize() {
    if (!canvas) return;
    W = canvas.width  = window.innerWidth;
    H = canvas.height = window.innerHeight;
    // Re-init particles on resize
    if (currentEffect) start(currentEffect);
  }

  // ── Performance detection ─────────────────────────────────────
  function detectPerformance() {
    // Check device memory (Chrome only)
    const mem = navigator.deviceMemory;
    if (mem && mem < 2) { lowEndMode = true; return; }
    // Check hardware concurrency
    const cores = navigator.hardwareConcurrency || 4;
    if (cores <= 2) { lowEndMode = true; return; }
    // Run a quick FPS probe
    let frames = 0;
    const t0 = performance.now();
    function probe() {
      frames++;
      if (performance.now() - t0 < 500) {
        requestAnimationFrame(probe);
      } else {
        const fps = frames / 0.5;
        if (fps < 30) lowEndMode = true;
      }
    }
    requestAnimationFrame(probe);
  }

  function getMaxParticles(base) {
    return lowEndMode ? Math.floor(base * 0.3) : base;
  }

  // ── Effect management ─────────────────────────────────────────
  function start(effect) {
    stop();
    currentEffect = effect;
    if (!effect || effect === 'none') {
      clear();
      return;
    }
    const init = EFFECTS[effect];
    if (!init) return;
    particles = init();
    loop();
  }

  function stop() {
    if (animFrame) { cancelAnimationFrame(animFrame); animFrame = null; }
    particles = [];
    currentEffect = null;
  }

  function clear() {
    if (!ctx) return;
    ctx.clearRect(0, 0, W, H);
  }

  function loop(ts = 0) {
    const dt = Math.min(ts - lastTime, 50); // cap at 50ms to handle tab switching
    lastTime = ts;

    // FPS tracking
    if (dt > 0) {
      const fps = 1000 / dt;
      fpsHistory.push(fps);
      if (fpsHistory.length > 30) fpsHistory.shift();
      const avgFps = fpsHistory.reduce((a,b)=>a+b,0) / fpsHistory.length;
      if (avgFps < 20 && fpsHistory.length >= 20) {
        lowEndMode = true;
        // Reduce particles
        particles = particles.slice(0, Math.floor(particles.length * 0.5));
        fpsHistory = [];
      }
    }

    ctx.clearRect(0, 0, W, H);
    const updater = UPDATERS[currentEffect];
    if (updater) updater(particles, dt);
    animFrame = requestAnimationFrame(loop);
  }

  // ── Color helpers ─────────────────────────────────────────────
  function getAccent() {
    return getComputedStyle(document.documentElement)
      .getPropertyValue('--accent').trim() || '#7c5cfc';
  }

  function hexToRgb(hex) {
    const r = parseInt(hex.slice(1,3),16);
    const g = parseInt(hex.slice(3,5),16);
    const b = parseInt(hex.slice(5,7),16);
    return `${r},${g},${b}`;
  }

  // ── EFFECT: SNOW ──────────────────────────────────────────────
  EFFECTS_INIT_snow = () => {
    const count = getMaxParticles(120);
    return Array.from({length: count}, () => ({
      x:    Math.random() * W,
      y:    Math.random() * H,
      r:    Math.random() * 3 + 1,
      vx:   (Math.random() - 0.5) * 0.4,
      vy:   Math.random() * 0.8 + 0.3,
      alpha:Math.random() * 0.6 + 0.2,
      wobble: Math.random() * Math.PI * 2,
      wobbleSpeed: Math.random() * 0.02 + 0.01,
    }));
  };

  EFFECTS_UPDATE_snow = (p, dt) => {
    ctx.fillStyle = 'rgba(255,255,255,';
    for (const s of p) {
      s.wobble += s.wobbleSpeed;
      s.x += s.vx + Math.sin(s.wobble) * 0.3;
      s.y += s.vy;
      if (s.y > H + 5) { s.y = -5; s.x = Math.random() * W; }
      if (s.x > W + 5) s.x = -5;
      if (s.x < -5)    s.x = W + 5;
      ctx.beginPath();
      ctx.arc(s.x, s.y, s.r, 0, Math.PI * 2);
      ctx.fillStyle = `rgba(255,255,255,${s.alpha})`;
      ctx.fill();
    }
  };

  // ── EFFECT: RAIN ──────────────────────────────────────────────
  EFFECTS_INIT_rain = () => {
    const count = getMaxParticles(80);
    return Array.from({length: count}, () => ({
      x:    Math.random() * W,
      y:    Math.random() * H,
      len:  Math.random() * 20 + 10,
      vx:  -1.5,
      vy:   Math.random() * 8 + 8,
      alpha:Math.random() * 0.4 + 0.1,
    }));
  };

  EFFECTS_UPDATE_rain = (p, dt) => {
    const accent = getAccent();
    const rgb = hexToRgb(accent);
    for (const r of p) {
      r.x += r.vx;
      r.y += r.vy;
      if (r.y > H) { r.y = -r.len; r.x = Math.random() * W; }
      ctx.beginPath();
      ctx.moveTo(r.x, r.y);
      ctx.lineTo(r.x + r.vx * r.len / r.vy, r.y + r.len);
      ctx.strokeStyle = `rgba(${rgb},${r.alpha})`;
      ctx.lineWidth = 1;
      ctx.stroke();
    }
  };

  // ── EFFECT: PARTICLES ─────────────────────────────────────────
  EFFECTS_INIT_particles = () => {
    const count = getMaxParticles(60);
    return Array.from({length: count}, () => ({
      x:    Math.random() * W,
      y:    Math.random() * H,
      r:    Math.random() * 4 + 1,
      vx:   (Math.random() - 0.5) * 0.6,
      vy:   (Math.random() - 0.5) * 0.6,
      alpha:Math.random() * 0.5 + 0.15,
      pulse: Math.random() * Math.PI * 2,
      pulseSpeed: Math.random() * 0.02 + 0.008,
    }));
  };

  EFFECTS_UPDATE_particles = (p, dt) => {
    const accent = getAccent();
    const rgb = hexToRgb(accent);
    // Draw connections
    for (let i = 0; i < p.length; i++) {
      for (let j = i + 1; j < p.length; j++) {
        const dx = p[i].x - p[j].x;
        const dy = p[i].y - p[j].y;
        const dist = Math.sqrt(dx*dx + dy*dy);
        if (dist < 120) {
          ctx.beginPath();
          ctx.moveTo(p[i].x, p[i].y);
          ctx.lineTo(p[j].x, p[j].y);
          ctx.strokeStyle = `rgba(${rgb},${(1 - dist/120) * 0.15})`;
          ctx.lineWidth = 1;
          ctx.stroke();
        }
      }
    }
    // Draw particles
    for (const pt of p) {
      pt.x += pt.vx;
      pt.y += pt.vy;
      pt.pulse += pt.pulseSpeed;
      if (pt.x < 0 || pt.x > W) pt.vx *= -1;
      if (pt.y < 0 || pt.y > H) pt.vy *= -1;
      const r = pt.r + Math.sin(pt.pulse) * 0.5;
      ctx.beginPath();
      ctx.arc(pt.x, pt.y, r, 0, Math.PI * 2);
      ctx.fillStyle = `rgba(${rgb},${pt.alpha})`;
      ctx.fill();
    }
  };

  // ── EFFECT: STARS ─────────────────────────────────────────────
  EFFECTS_INIT_stars = () => {
    const count = getMaxParticles(200);
    return Array.from({length: count}, () => ({
      x:    Math.random() * W,
      y:    Math.random() * H,
      r:    Math.random() * 1.5 + 0.2,
      alpha:Math.random(),
      phase:Math.random() * Math.PI * 2,
      speed:Math.random() * 0.008 + 0.003,
    }));
  };

  EFFECTS_UPDATE_stars = (p, dt) => {
    for (const s of p) {
      s.phase += s.speed;
      const a = (Math.sin(s.phase) * 0.5 + 0.5) * 0.8 + 0.1;
      ctx.beginPath();
      ctx.arc(s.x, s.y, s.r, 0, Math.PI * 2);
      ctx.fillStyle = `rgba(255,255,255,${a})`;
      ctx.fill();
    }
  };

  // ── EFFECT: MATRIX ────────────────────────────────────────────
  EFFECTS_INIT_matrix = () => {
    const cols = Math.floor(W / 16);
    return Array.from({length: getMaxParticles(cols)}, (_, i) => ({
      x:   i * 16,
      y:   Math.random() * H,
      speed: Math.random() * 3 + 1,
      chars: '01アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホ'.split(''),
      char:  '0',
      alpha: Math.random() * 0.5 + 0.2,
      timer: 0,
      interval: Math.random() * 80 + 40,
    }));
  };

  EFFECTS_UPDATE_matrix = (p, dt) => {
    const accent = getAccent();
    const rgb = hexToRgb(accent);
    ctx.font = '13px "JetBrains Mono", monospace';
    for (const col of p) {
      col.y += col.speed;
      col.timer += dt;
      if (col.timer > col.interval) {
        col.char  = col.chars[Math.floor(Math.random() * col.chars.length)];
        col.timer = 0;
      }
      if (col.y > H) {
        col.y = -20;
        col.alpha = Math.random() * 0.4 + 0.1;
      }
      ctx.fillStyle = `rgba(${rgb},${col.alpha})`;
      ctx.fillText(col.char, col.x, col.y);
      // Brighter leading char
      ctx.fillStyle = `rgba(${rgb},0.9)`;
      ctx.fillText(col.char, col.x, col.y);
    }
  };

  // ── EFFECT: FLOATING DOTS ─────────────────────────────────────
  EFFECTS_INIT_dots = () => {
    const count = getMaxParticles(40);
    return Array.from({length: count}, () => ({
      x:    Math.random() * W,
      y:    Math.random() * H,
      r:    Math.random() * 8 + 3,
      vx:   (Math.random() - 0.5) * 0.3,
      vy:   (Math.random() - 0.5) * 0.3,
      alpha:Math.random() * 0.15 + 0.03,
      phase:Math.random() * Math.PI * 2,
    }));
  };

  EFFECTS_UPDATE_dots = (p, dt) => {
    const accent = getAccent();
    const rgb = hexToRgb(accent);
    for (const d of p) {
      d.phase += 0.005;
      d.x += d.vx + Math.sin(d.phase) * 0.2;
      d.y += d.vy + Math.cos(d.phase * 0.7) * 0.2;
      if (d.x < -20) d.x = W + 20;
      if (d.x > W+20) d.x = -20;
      if (d.y < -20) d.y = H + 20;
      if (d.y > H+20) d.y = -20;
      ctx.beginPath();
      ctx.arc(d.x, d.y, d.r, 0, Math.PI * 2);
      ctx.fillStyle = `rgba(${rgb},${d.alpha})`;
      ctx.fill();
    }
  };

  // ── Effect registry ───────────────────────────────────────────
  const EFFECTS = {
    snow:      () => EFFECTS_INIT_snow(),
    rain:      () => EFFECTS_INIT_rain(),
    particles: () => EFFECTS_INIT_particles(),
    stars:     () => EFFECTS_INIT_stars(),
    matrix:    () => EFFECTS_INIT_matrix(),
    dots:      () => EFFECTS_INIT_dots(),
  };

  const UPDATERS = {
    snow:      EFFECTS_UPDATE_snow,
    rain:      EFFECTS_UPDATE_rain,
    particles: EFFECTS_UPDATE_particles,
    stars:     EFFECTS_UPDATE_stars,
    matrix:    EFFECTS_UPDATE_matrix,
    dots:      EFFECTS_UPDATE_dots,
  };

  // ── Public API ────────────────────────────────────────────────
  return {
    init,
    start,
    stop,
    current: () => currentEffect,
    isLowEnd: () => lowEndMode,
  };

})();

// Declare init fns in outer scope so EFFECTS registry can ref them
let EFFECTS_INIT_snow, EFFECTS_INIT_rain, EFFECTS_INIT_particles;
let EFFECTS_INIT_stars, EFFECTS_INIT_matrix, EFFECTS_INIT_dots;
let EFFECTS_UPDATE_snow, EFFECTS_UPDATE_rain, EFFECTS_UPDATE_particles;
let EFFECTS_UPDATE_stars, EFFECTS_UPDATE_matrix, EFFECTS_UPDATE_dots;
