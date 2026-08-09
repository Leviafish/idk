'use strict';
/**
 * Leviathan Obfuscator v3.3 — Background Effects System
 * static/js/effects.js
 *
 * FIX: All outer `let` declarations moved BEFORE the IIFE that assigns them.
 *      This eliminates the Temporal Dead Zone (TDZ) ReferenceError:
 *      "Cannot access 'EFFECTS_INIT_snow' before initialization"
 *
 * Each effect init/update is wrapped in try/catch — one broken effect
 * never crashes the page or other effects.
 */

// ── Outer-scope bindings: MUST be declared before the IIFE ──────────────────
let EFFECTS_INIT_snow,      EFFECTS_INIT_rain,      EFFECTS_INIT_particles;
let EFFECTS_INIT_stars,     EFFECTS_INIT_matrix,    EFFECTS_INIT_dots;
let EFFECTS_UPDATE_snow,    EFFECTS_UPDATE_rain,    EFFECTS_UPDATE_particles;
let EFFECTS_UPDATE_stars,   EFFECTS_UPDATE_matrix,  EFFECTS_UPDATE_dots;

const Effects = (() => {

  let canvas, ctx, W, H;
  let currentEffect = null;
  let animFrame     = null;
  let particles     = [];
  let lastTime      = 0;
  let fpsHistory    = [];
  let lowEndMode    = false;

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
    if (currentEffect) start(currentEffect);
  }

  function detectPerformance() {
    const mem = navigator.deviceMemory;
    if (mem && mem < 2) { lowEndMode = true; return; }
    if ((navigator.hardwareConcurrency || 4) <= 2) { lowEndMode = true; return; }
    let frames = 0;
    const t0 = performance.now();
    function probe() {
      frames++;
      if (performance.now() - t0 < 500) requestAnimationFrame(probe);
      else if (frames / 0.5 < 30)       lowEndMode = true;
    }
    requestAnimationFrame(probe);
  }

  function getMax(n) { return lowEndMode ? Math.floor(n * 0.3) : n; }

  function start(effect) {
    stop();
    currentEffect = effect;
    if (!effect || effect === 'none') { clear(); return; }
    const initFn = EFFECTS[effect];
    if (!initFn) return;
    try   { particles = initFn(); }
    catch (e) { console.warn('[Effects] init failed for', effect, e); return; }
    loop();
  }

  function stop() {
    if (animFrame) { cancelAnimationFrame(animFrame); animFrame = null; }
    particles = []; currentEffect = null;
  }

  function clear() { if (ctx) ctx.clearRect(0, 0, W, H); }

  function loop(ts = 0) {
    const dt = Math.min(ts - lastTime, 50);
    lastTime = ts;
    if (dt > 0) {
      fpsHistory.push(1000 / dt);
      if (fpsHistory.length > 30) fpsHistory.shift();
      if (fpsHistory.length >= 20) {
        const avg = fpsHistory.reduce((a,b)=>a+b,0) / fpsHistory.length;
        if (avg < 20) { lowEndMode = true; particles = particles.slice(0, Math.floor(particles.length * 0.5)); fpsHistory = []; }
      }
    }
    ctx.clearRect(0, 0, W, H);
    const upd = UPDATERS[currentEffect];
    if (upd) {
      try   { upd(particles, dt); }
      catch (e) { console.warn('[Effects] update error', e); stop(); return; }
    }
    animFrame = requestAnimationFrame(loop);
  }

  function accent() { return getComputedStyle(document.documentElement).getPropertyValue('--accent').trim() || '#7c5cfc'; }
  function rgb(hex) {
    hex = hex.replace(/^#/,''); if (hex.length===3) hex=hex.split('').map(c=>c+c).join('');
    const n=parseInt(hex,16); return `${(n>>16)&255},${(n>>8)&255},${n&255}`;
  }

  /* SNOW */
  EFFECTS_INIT_snow = () => Array.from({length:getMax(120)},()=>({
    x:Math.random()*W, y:Math.random()*H, r:Math.random()*3+1,
    vx:(Math.random()-.5)*.4, vy:Math.random()*.8+.3,
    alpha:Math.random()*.6+.2, wobble:Math.random()*Math.PI*2, ws:Math.random()*.02+.01
  }));
  EFFECTS_UPDATE_snow = p => {
    for (const s of p) {
      s.wobble+=s.ws; s.x+=s.vx+Math.sin(s.wobble)*.3; s.y+=s.vy;
      if(s.y>H+5){s.y=-5;s.x=Math.random()*W;} if(s.x>W+5)s.x=-5; if(s.x<-5)s.x=W+5;
      ctx.beginPath(); ctx.arc(s.x,s.y,s.r,0,Math.PI*2);
      ctx.fillStyle=`rgba(255,255,255,${s.alpha})`; ctx.fill();
    }
  };

  /* RAIN */
  EFFECTS_INIT_rain = () => Array.from({length:getMax(80)},()=>({
    x:Math.random()*W, y:Math.random()*H, len:Math.random()*20+10,
    vx:-1.5, vy:Math.random()*8+8, alpha:Math.random()*.4+.1
  }));
  EFFECTS_UPDATE_rain = p => {
    const c=rgb(accent());
    for (const r of p) {
      r.x+=r.vx; r.y+=r.vy; if(r.y>H){r.y=-r.len;r.x=Math.random()*W;}
      ctx.beginPath(); ctx.moveTo(r.x,r.y); ctx.lineTo(r.x+r.vx*r.len/r.vy,r.y+r.len);
      ctx.strokeStyle=`rgba(${c},${r.alpha})`; ctx.lineWidth=1; ctx.stroke();
    }
  };

  /* PARTICLES */
  EFFECTS_INIT_particles = () => Array.from({length:getMax(60)},()=>({
    x:Math.random()*W, y:Math.random()*H, r:Math.random()*4+1,
    vx:(Math.random()-.5)*.6, vy:(Math.random()-.5)*.6,
    alpha:Math.random()*.5+.15, pulse:Math.random()*Math.PI*2, ps:Math.random()*.02+.008
  }));
  EFFECTS_UPDATE_particles = p => {
    const c=rgb(accent());
    for(let i=0;i<p.length;i++) for(let j=i+1;j<p.length;j++){
      const dx=p[i].x-p[j].x,dy=p[i].y-p[j].y,d=Math.sqrt(dx*dx+dy*dy);
      if(d<120){ctx.beginPath();ctx.moveTo(p[i].x,p[i].y);ctx.lineTo(p[j].x,p[j].y);
        ctx.strokeStyle=`rgba(${c},${(1-d/120)*.15})`;ctx.lineWidth=1;ctx.stroke();}
    }
    for(const pt of p){
      pt.x+=pt.vx;pt.y+=pt.vy;pt.pulse+=pt.ps;
      if(pt.x<0||pt.x>W)pt.vx*=-1; if(pt.y<0||pt.y>H)pt.vy*=-1;
      ctx.beginPath();ctx.arc(pt.x,pt.y,pt.r+Math.sin(pt.pulse)*.5,0,Math.PI*2);
      ctx.fillStyle=`rgba(${c},${pt.alpha})`;ctx.fill();
    }
  };

  /* STARS */
  EFFECTS_INIT_stars = () => Array.from({length:getMax(200)},()=>({
    x:Math.random()*W, y:Math.random()*H, r:Math.random()*1.5+.2,
    phase:Math.random()*Math.PI*2, spd:Math.random()*.008+.003
  }));
  EFFECTS_UPDATE_stars = p => {
    for(const s of p){s.phase+=s.spd; const a=(Math.sin(s.phase)*.5+.5)*.8+.1;
      ctx.beginPath();ctx.arc(s.x,s.y,s.r,0,Math.PI*2);ctx.fillStyle=`rgba(255,255,255,${a})`;ctx.fill();}
  };

  /* MATRIX */
  EFFECTS_INIT_matrix = () => {
    const cols=Math.floor(W/16),chars='01アイウエオカキクケコサシスセソタチツテト'.split('');
    return Array.from({length:getMax(cols)},(_,i)=>({x:i*16,y:Math.random()*H,speed:Math.random()*3+1,chars,char:'0',alpha:Math.random()*.5+.2,timer:0,interval:Math.random()*80+40}));
  };
  EFFECTS_UPDATE_matrix = (p,dt) => {
    const c=rgb(accent()); ctx.font='13px monospace';
    for(const col of p){col.y+=col.speed;col.timer+=dt;
      if(col.timer>col.interval){col.char=col.chars[Math.floor(Math.random()*col.chars.length)];col.timer=0;}
      if(col.y>H){col.y=-20;col.alpha=Math.random()*.4+.1;}
      ctx.fillStyle=`rgba(${c},${col.alpha})`;ctx.fillText(col.char,col.x,col.y);}
  };

  /* DOTS */
  EFFECTS_INIT_dots = () => Array.from({length:getMax(40)},()=>({
    x:Math.random()*W, y:Math.random()*H, r:Math.random()*8+3,
    vx:(Math.random()-.5)*.3, vy:(Math.random()-.5)*.3, alpha:Math.random()*.15+.03, phase:Math.random()*Math.PI*2
  }));
  EFFECTS_UPDATE_dots = p => {
    const c=rgb(accent());
    for(const d of p){d.phase+=.005;d.x+=d.vx+Math.sin(d.phase)*.2;d.y+=d.vy+Math.cos(d.phase*.7)*.2;
      if(d.x<-20)d.x=W+20;if(d.x>W+20)d.x=-20;if(d.y<-20)d.y=H+20;if(d.y>H+20)d.y=-20;
      ctx.beginPath();ctx.arc(d.x,d.y,d.r,0,Math.PI*2);ctx.fillStyle=`rgba(${c},${d.alpha})`;ctx.fill();}
  };

  // Registries — safe to build here because all outer lets are now initialized above
  const EFFECTS = {
    snow:snow=>EFFECTS_INIT_snow(), rain:()=>EFFECTS_INIT_rain(),
    particles:()=>EFFECTS_INIT_particles(), stars:()=>EFFECTS_INIT_stars(),
    matrix:()=>EFFECTS_INIT_matrix(), dots:()=>EFFECTS_INIT_dots(),
  };
  const UPDATERS = {
    snow:EFFECTS_UPDATE_snow, rain:EFFECTS_UPDATE_rain, particles:EFFECTS_UPDATE_particles,
    stars:EFFECTS_UPDATE_stars, matrix:EFFECTS_UPDATE_matrix, dots:EFFECTS_UPDATE_dots,
  };

  return { init, start, stop, current:()=>currentEffect, isLowEnd:()=>lowEndMode };
})();
