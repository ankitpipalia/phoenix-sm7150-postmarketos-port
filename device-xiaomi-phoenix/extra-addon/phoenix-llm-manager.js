'use strict';
/* Phoenix Console — vanilla JS, no build step, no CDN.
   Charts follow the small-multiples rule: one measure per canvas, never two
   y-scales, at most three series, legend only when there is more than one. */

// ---------- utilities ----------
const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const SERIES = ['#3987e5', '#d95926', '#199e70'];
const fmt = {
  bytes(n, d = 1) { if (n == null) return '—'; const u = ['B', 'KiB', 'MiB', 'GiB', 'TiB']; let i = 0; n = Math.abs(n); while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; } return `${n.toFixed(i ? d : 0)} ${u[i]}`; },
  rate(bps) { if (bps == null) return '—'; const u = ['B/s', 'KB/s', 'MB/s', 'GB/s']; let i = 0; let n = bps; while (n >= 1000 && i < u.length - 1) { n /= 1000; i++; } return `${n.toFixed(i ? 1 : 0)} ${u[i]}`; },
  dur(s) { if (s == null) return '—'; s = Math.max(0, Math.round(s)); const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60); if (d) return `${d}d ${h}h`; if (h) return `${h}h ${m}m`; if (m) return `${m}m ${s % 60}s`; return `${s}s`; },
  v(uv) { return uv == null ? '—' : `${(uv / 1e6).toFixed(3)} V`; },
  ma(ua) { return ua == null ? '—' : `${(ua / 1e3).toFixed(0)} mA`; },
  w(w) { return w == null ? '—' : `${Number(w).toFixed(2)} W`; },
  c(t) { return t == null ? '—' : `${Number(t).toFixed(1)} °C`; },
  pct(p) { return p == null ? '—' : `${Number(p).toFixed(1)}%`; },
  ghz(khz) { return khz == null ? '—' : `${(khz / 1e6).toFixed(2)} GHz`; },
  time(t) { const d = new Date(t * 1000); return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' }); },
  hm(t) { const d = new Date(t * 1000); return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }); },
  raw(k, v) { if (v == null || v === '') return 'Unavailable'; if (typeof v !== 'number') return String(v); if (k.includes('voltage')) return fmt.v(v); if (k.includes('current')) return `${(v / 1e6).toFixed(3)} A`; if (k === 'temp') return fmt.c(v / 10); if (k.includes('charge_') || k === 'energy') return `${(v / 1e6).toFixed(3)} Ah`; if (k.endsWith('_w')) return fmt.w(v); return String(v); },
};

// ---------- persisted settings ----------
const settings = new Proxy(JSON.parse(localStorage.getItem('phoenixConsole') || '{}'), {
  set(t, k, v) { t[k] = v; localStorage.setItem('phoenixConsole', JSON.stringify(t)); return true; },
});
settings.poll ??= 5000; settings.range ??= 180; settings.motion ??= 'auto'; settings.tween ??= 'on';
let token = sessionStorage.getItem('phoenixToken') || '';
function applyMotion() {
  document.documentElement.classList.toggle('reduce-motion', settings.motion === 'off');
  document.documentElement.classList.toggle('force-motion', settings.motion === 'on');
}
applyMotion();
const motionOff = () => settings.motion === 'off' || (settings.motion === 'auto' && matchMedia('(prefers-reduced-motion: reduce)').matches);

// ---------- api ----------
async function api(path, opt = {}) {
  opt.headers = { ...(opt.headers || {}), ...(token ? { 'X-API-Key': token } : {}) };
  const r = await fetch(path, opt);
  let body = null; try { body = await r.json(); } catch { /* non-json */ }
  if (r.status === 401) { showPage('settings'); toast('API token required', true); }
  if (!r.ok) throw new Error((body && body.error) || `HTTP ${r.status}`);
  return body;
}
let toastTimer;
function toast(msg, bad = false) { const e = $('toast'); e.textContent = msg; e.className = `show${bad ? ' bad' : ''}`; clearTimeout(toastTimer); toastTimer = setTimeout(() => e.className = '', 3200); }

// ---------- value tweening ----------
function setValue(el, text, cls) {
  if (!el) return;
  if (el.textContent === text) return;
  const from = parseFloat(el.textContent), to = parseFloat(text);
  el.classList.remove('tick'); void el.offsetWidth; el.classList.add('tick');
  if (settings.tween === 'on' && !motionOff() && Number.isFinite(from) && Number.isFinite(to) && from !== to && /^-?[\d.,+]+/.test(text)) {
    const suffix = text.replace(/^-?[\d.,+]+/, ''); const decimals = (text.match(/\.(\d+)/) || ['', ''])[1].length; const sign = /^\+/.test(text) ? '+' : '';
    const t0 = performance.now(), d = 420;
    const step = (now) => { const p = Math.min(1, (now - t0) / d), e = 1 - Math.pow(1 - p, 3); const v = from + (to - from) * e; el.textContent = `${v >= 0 ? sign : ''}${v.toFixed(decimals)}${suffix}`; if (p < 1) requestAnimationFrame(step); else el.textContent = text; };
    requestAnimationFrame(step);
  } else el.textContent = text;
  if (cls !== undefined) el.parentElement.className = `card ${cls}`;
}
function card(label, value, unit = '', cls = '', extra = '') { return `<div class="card ${cls}" style="--i:${cardIdx++}"><div class="label">${esc(label)}</div><div class="value">${esc(value)}</div><div class="unit">${esc(unit)}</div>${extra}</div>`; }
let cardIdx = 0;
function bar(pct, cls = '') { const p = Math.max(0, Math.min(100, pct || 0)); return `<div class="bar ${cls || (p > 90 ? 'bad' : p > 75 ? 'warn' : '')}"><i style="width:${p}%"></i></div>`; }
function stateTag(s) { return `<span class="state ${esc(s)}">${esc(s || '?')}</span>`; }
function kv(obj, skip = []) { return Object.entries(obj || {}).filter(([k]) => !skip.includes(k)).map(([k, v]) => `<div class="key">${esc(k.replaceAll('_', ' '))}</div><div>${esc(fmt.raw(k, v))}</div>`).join(''); }

// ---------- charts ----------
const tooltip = $('tooltip');
class LineChart {
  constructor(canvas, opts) {
    this.c = canvas; this.ctx = canvas.getContext('2d'); this.o = { format: (v) => String(v), zero: false, smooth: false, fill: true, ...opts };
    this.data = []; this.window = settings.range; this.hidden = new Set(); this.reveal = 1; this.hover = null;
    this.legend = null;
    if (this.o.series.length > 1) {
      this.legend = document.createElement('div'); this.legend.className = 'legend';
      this.o.series.forEach((s, i) => { const b = document.createElement('button'); b.textContent = s.label; b.style.setProperty('--c', SERIES[i]); b.onclick = () => { this.hidden.has(s.key) ? this.hidden.delete(s.key) : this.hidden.add(s.key); b.classList.toggle('off'); this.draw(); }; this.legend.appendChild(b); });
      canvas.parentElement.appendChild(this.legend);
    }
    canvas.addEventListener('mousemove', (e) => this.onHover(e)); canvas.addEventListener('mouseleave', () => { this.hover = null; tooltip.hidden = true; this.draw(); });
    canvas.addEventListener('touchstart', (e) => this.onHover(e.touches[0]), { passive: true }); canvas.addEventListener('touchmove', (e) => this.onHover(e.touches[0]), { passive: true });
    new ResizeObserver(() => this.draw()).observe(canvas);
  }
  setData(points) { const first = this.data.length === 0 && points.length > 0; this.data = points; if (first && !motionOff()) this.animateReveal(); else this.draw(); }
  animateReveal() { this.reveal = 0; const t0 = performance.now(); const step = (now) => { this.reveal = Math.min(1, (now - t0) / 550); this.draw(); if (this.reveal < 1) requestAnimationFrame(step); }; requestAnimationFrame(step); }
  visible() { return this.data.slice(-this.window); }
  layout() { const dpr = devicePixelRatio || 1; const w = this.c.clientWidth, h = this.c.clientHeight; if (this.c.width !== w * dpr || this.c.height !== h * dpr) { this.c.width = w * dpr; this.c.height = h * dpr; } this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0); return { w, h, l: this.gutter || 44, r: 8, t: 8, b: 18 }; }
  scale(rows) {
    let min = Infinity, max = -Infinity;
    for (const s of this.o.series) if (!this.hidden.has(s.key)) for (const r of rows) { const v = r[s.key]; if (v != null && Number.isFinite(v)) { if (v < min) min = v; if (v > max) max = v; } }
    if (!Number.isFinite(min)) { min = 0; max = 1; }
    if (this.o.zero || this.o.forceZero) { min = Math.min(0, min); max = Math.max(0, max); }
    if (this.o.max != null) max = Math.max(max, this.o.max);
    // A hard ceiling (e.g. 100%) is the top of the axis; padding above it would print 108%.
    if (max === min) { max += 1; min -= 1; } else { const pad = (max - min) * 0.08; const capped = this.o.max != null && max <= this.o.max; min -= pad; if (!capped) max += pad; }
    if ((this.o.zero || this.o.forceZero) && min < 0 && !this.o.negative) min = 0;
    return { min, max };
  }
  draw() {
    let { w, h, l, r, t, b } = this.layout(); const ctx = this.ctx; ctx.clearRect(0, 0, w, h);
    const rows = this.visible(); if (rows.length < 2) { ctx.fillStyle = '#5c6c67'; ctx.font = '11px system-ui'; ctx.fillText('collecting…', l + 6, h / 2); return; }
    const { min, max } = this.scale(rows);
    // Size the left gutter to the widest tick label so "652.7 MiB" never clips.
    ctx.font = '10px system-ui'; let widest = 0; for (let i = 0; i <= 4; i++) widest = Math.max(widest, ctx.measureText(this.o.format(min + (max - min) * i / 4)).width);
    l = this.gutter = Math.max(36, Math.ceil(widest) + 12);
    const pw = w - l - r, ph = h - t - b;
    const X = (i) => l + (i / (rows.length - 1)) * pw, Y = (v) => t + ph - ((v - min) / (max - min)) * ph;
    ctx.strokeStyle = '#1b252b'; ctx.lineWidth = 1; ctx.fillStyle = '#6f807b'; ctx.font = '10px system-ui'; ctx.textAlign = 'right'; ctx.textBaseline = 'middle';
    for (let i = 0; i <= 4; i++) { const v = min + (max - min) * i / 4, y = Y(v); ctx.beginPath(); ctx.moveTo(l, y); ctx.lineTo(w - r, y); ctx.stroke(); ctx.fillText(this.o.format(v), l - 6, y); }
    if (min < 0 && max > 0) { ctx.strokeStyle = '#33454f'; ctx.beginPath(); ctx.moveTo(l, Y(0)); ctx.lineTo(w - r, Y(0)); ctx.stroke(); }
    ctx.textBaseline = 'top'; const ticks = Math.min(5, rows.length); for (let i = 0; i < ticks; i++) { const idx = Math.round(i * (rows.length - 1) / (ticks - 1)); ctx.textAlign = i === 0 ? 'left' : i === ticks - 1 ? 'right' : 'center'; if (rows[idx]?.t) ctx.fillText(fmt.hm(rows[idx].t), X(idx), h - b + 4); }
    const revealTo = Math.floor(rows.length * this.reveal);
    this.o.series.forEach((s, si) => {
      if (this.hidden.has(s.key)) return; const col = SERIES[si]; let vals = rows.map((r) => r[s.key]);
      if (this.o.smooth) vals = vals.map((v, i, a) => { let n = 0, sum = 0; for (let k = -2; k <= 2; k++) { const x = a[i + k]; if (x != null && Number.isFinite(x)) { sum += x; n++; } } return n ? sum / n : v; });
      ctx.beginPath(); let started = false, last = null;
      for (let i = 0; i < revealTo; i++) { const v = vals[i]; if (v == null || !Number.isFinite(v)) { started = false; continue; } const x = X(i), y = Y(v); if (!started) { ctx.moveTo(x, y); started = true; } else ctx.lineTo(x, y); last = { x, y, v: rows[i][s.key] }; }
      ctx.strokeStyle = col; ctx.lineWidth = 2; ctx.lineJoin = 'round'; ctx.lineCap = 'round'; ctx.stroke();
      if (this.o.fill && this.o.series.length === 1 && last) { ctx.lineTo(last.x, Y(Math.max(min, Math.min(max, 0)))); ctx.lineTo(X(0), Y(Math.max(min, Math.min(max, 0)))); ctx.closePath(); ctx.fillStyle = col + '22'; ctx.fill(); }
      if (last && this.reveal >= 1) { ctx.beginPath(); ctx.arc(last.x, last.y, 4, 0, Math.PI * 2); ctx.fillStyle = col; ctx.fill(); ctx.strokeStyle = '#091013'; ctx.lineWidth = 2; ctx.stroke(); }
    });
    if (this.hover != null) { const x = X(this.hover); ctx.strokeStyle = '#3f5561'; ctx.setLineDash([3, 3]); ctx.beginPath(); ctx.moveTo(x, t); ctx.lineTo(x, h - b); ctx.stroke(); ctx.setLineDash([]); this.o.series.forEach((s, si) => { if (this.hidden.has(s.key)) return; const v = rows[this.hover][s.key]; if (v == null) return; ctx.beginPath(); ctx.arc(x, Y(v), 5, 0, Math.PI * 2); ctx.fillStyle = SERIES[si]; ctx.fill(); ctx.strokeStyle = '#091013'; ctx.lineWidth = 2; ctx.stroke(); }); }
  }
  onHover(e) {
    const rows = this.visible(); if (rows.length < 2) return; const rect = this.c.getBoundingClientRect(); const l = this.gutter || 44, r = 8; const pw = rect.width - l - r;
    const i = Math.max(0, Math.min(rows.length - 1, Math.round(((e.clientX - rect.left - l) / pw) * (rows.length - 1)))); this.hover = i; this.draw();
    const row = rows[i]; const lines = this.o.series.filter((s) => !this.hidden.has(s.key)).map((s, si) => `<div class="r"><span style="--c:${SERIES[this.o.series.indexOf(s)]}">${esc(s.label)}</span><b>${esc(row[s.key] == null ? '—' : this.o.format(row[s.key]))}</b></div>`).join('');
    tooltip.innerHTML = `<div class="t">${esc(row.t ? fmt.time(row.t) : '')}</div>${lines}`; tooltip.hidden = false;
    const tw = tooltip.offsetWidth, th = tooltip.offsetHeight; let tx = e.clientX + 14, ty = e.clientY - th - 10; if (tx + tw > innerWidth - 8) tx = e.clientX - tw - 14; if (ty < 8) ty = e.clientY + 14; tooltip.style.left = `${tx}px`; tooltip.style.top = `${ty}px`;
  }
}
const charts = {};
function chart(name, opts) { if (!charts[name]) { const cv = document.querySelector(`canvas[data-chart="${name}"]`); if (!cv) return null; charts[name] = new LineChart(cv, opts); } return charts[name]; }
// Per-page control rows: range, smooth, zero-based. Each scopes every chart in its group.
const groups = {};
document.querySelectorAll('.controls[data-chart-group]').forEach((ctl) => {
  const g = ctl.dataset.chartGroup; groups[g] = { range: settings.range, smooth: false, zero: false, charts: [] };
  ctl.querySelectorAll('[data-role=range] button').forEach((b) => { b.classList.toggle('on', +b.dataset.range === settings.range); b.onclick = () => { ctl.querySelectorAll('[data-role=range] button').forEach((x) => x.classList.remove('on')); b.classList.add('on'); groups[g].range = +b.dataset.range; if (g === 'overview') $('ovRangeLabel').textContent = { 60: '5 minutes', 180: '15 minutes', 360: '30 minutes', 720: 'hour' }[b.dataset.range]; applyGroup(g); }; });
  ctl.querySelector('[data-role=smooth]')?.addEventListener('change', (e) => { groups[g].smooth = e.target.checked; applyGroup(g); });
  ctl.querySelector('[data-role=zero]')?.addEventListener('change', (e) => { groups[g].zero = e.target.checked; applyGroup(g); });
});
function applyGroup(g) { for (const ch of groups[g].charts) { ch.window = groups[g].range; ch.o.smooth = groups[g].smooth; ch.o.zero = groups[g].zero; ch.draw(); } }
function groupChart(g, name, opts) { const ch = chart(name, opts); if (ch && !groups[g].charts.includes(ch)) { groups[g].charts.push(ch); ch.window = groups[g].range; } return ch; }

// ---------- router ----------
// The hash is "#/page" (no element carries that id), so the browser never
// performs an anchor scroll that would drag the section under the sticky header.
let currentPage = 'overview';
history.scrollRestoration = 'manual';
const pageFromHash = () => location.hash.replace(/^#\/?/, '');
function showPage(page) {
  if (!$(page)) return; currentPage = page; history.replaceState(null, '', `#/${page}`);
  document.querySelectorAll('.tab').forEach((b) => b.classList.toggle('active', b.dataset.page === page));
  document.querySelectorAll('.page').forEach((p) => { p.classList.remove('active'); }); void $(page).offsetWidth; $(page).classList.add('active');
  scrollTo({ top: 0, left: 0, behavior: 'instant' });
  refreshPage(true);
}
document.querySelectorAll('.tab').forEach((b) => b.onclick = () => showPage(b.dataset.page));
addEventListener('hashchange', () => { const p = pageFromHash(); if (p && p !== currentPage) showPage(p); });

// ---------- header rail + overview ----------
function verdictClass(v) { return /OK/.test(v) ? 'good' : /DEFICIT/.test(v) ? 'warn' : /BATTERY/.test(v) ? 'bad' : ''; }
async function loadRail() {
  const o = await api('/api/overview'); const sys = o.system || {}; const hot = sys.thermal?.hottest; const verdict = o.power?.verdict || '';
  $('brandModel').textContent = `${o.info.model} · ${o.info.hostname}`;
  $('rail').innerHTML = [
    `<span class="pill ${o.runtime.ready ? 'good' : o.runtime.running ? 'warn' : ''}">${o.runtime.ready ? '● model ready' : o.runtime.running ? '◉ loading' : '○ no model'}</span>`,
    `<span class="pill">CPU ${fmt.pct(sys.cpu)}</span>`,
    `<span class="pill ${hot && hot.temp_c >= 80 ? 'bad' : hot && hot.temp_c >= 65 ? 'warn' : ''}">${hot ? `${hot.temp_c} °C` : '—'}</span>`,
    `<span class="pill">${fmt.bytes(sys.memory?.available_bytes, 1)} free</span>`,
    `<span class="pill ${verdictClass(verdict)}">${esc(o.charger.online ? (verdict.split(' - ')[0] || 'adapter') : 'on battery')} · ${o.battery.capacity ?? '—'}%</span>`,
  ].join('');
  return o;
}
async function loadOverview(o) {
  const sys = o.system || {}, mem = sys.memory || {}, hot = sys.thermal?.hottest;
  $('ovHero').innerHTML = `<div><span class="eyebrow">Device</span><div class="headline">${esc(o.info.model)}</div><div class="sub">${esc(o.info.hostname)} · ${esc(o.info.os)} · Linux ${esc(o.info.kernel)}</div></div><div class="hero-side">up <b>${fmt.dur(o.info.uptime_s)}</b><br>load <b>${sys.load ? `${sys.load.load1} / ${sys.load.load5} / ${sys.load.load15}` : '—'}</b><br>${o.info.cpu_count} cores · ${esc(sys.policies?.map((p) => fmt.ghz(p.cur_khz)).join(' + ') || '')}</div>`;
  cardIdx = 0;
  $('ovCards').innerHTML = card('CPU', fmt.pct(sys.cpu), sys.clusters ? `little ${fmt.pct(sys.clusters.policy0)} · big ${fmt.pct(sys.clusters.policy6)}` : '', sys.cpu > 85 ? 'warn' : '', bar(sys.cpu))
    + card('Memory', fmt.bytes(mem.used_bytes), `${fmt.pct(mem.used_percent)} of ${fmt.bytes(mem.total_bytes)}`, '', bar(mem.used_percent))
    + card('Hottest sensor', hot ? `${hot.temp_c} °C` : '—', hot?.name || '', hot && hot.temp_c >= 80 ? 'bad' : hot && hot.temp_c >= 65 ? 'warn' : 'good')
    + card('Battery', o.battery.capacity != null ? `${o.battery.capacity}%` : '—', `${fmt.v(o.battery.voltage_avg ?? o.battery.voltage_now)} · ${fmt.ma(o.battery.current_now)}`, verdictClass(o.power?.verdict || ''))
    + card('Adapter', o.charger.online ? fmt.w(o.charger.input_power_w) : 'offline', o.charger.online ? `${(o.power['adapter input'] || '').split(' = ')[0]} · ICL ${o.power['settled input ICL'] || '—'}` : 'running on battery', o.charger.online ? 'good' : 'bad')
    + card('Processes', sys.process_count ?? '—', `${sys.load?.running ?? '—'} running`)
    + card('Root filesystem', o.root_fs ? fmt.pct(o.root_fs.used_percent) : '—', o.root_fs ? `${fmt.bytes(o.root_fs.available_bytes)} free` : '', '', bar(o.root_fs?.used_percent))
    + card('Network', o.primary_iface ? o.primary_iface.name : 'no link', o.primary_iface ? `${(o.primary_iface.addresses || []).find((a) => a.includes('.')) || ''} · ${o.primary_iface.speed_mbps ? `${o.primary_iface.speed_mbps} Mb/s` : ''}` : '', o.primary_iface ? 'good' : 'bad');
  $('ovPower').innerHTML = Object.entries(o.power || {}).map(([k, v]) => `<div class="key">${esc(k)}</div><div class="${verdictClass(v)}">${esc(v)}</div>`).join('') || '<div class="key">status</div><div>unavailable</div>';
  $('ovUnits').innerHTML = Object.entries(o.units || {}).map(([u, s]) => `<div><span>${esc(u.replace(/\.(service|timer)$/, ''))}</span>${stateTag(s)}</div>`).join('');
  const [sh, bh] = await Promise.all([api('/api/system/history'), api('/api/battery/history')]);
  groupChart('overview', 'ovCpu', { series: [{ key: 'cpu', label: 'CPU %' }], format: (v) => `${v.toFixed(0)}%`, forceZero: true, max: 100 })?.setData(sh);
  groupChart('overview', 'ovMem', { series: [{ key: 'mem_used', label: 'Used' }], format: (v) => fmt.bytes(v, 1), forceZero: true })?.setData(sh);
  groupChart('overview', 'ovTemp', { series: [{ key: 'temp_hot', label: '°C' }], format: (v) => `${v.toFixed(0)}°` })?.setData(sh);
  groupChart('overview', 'ovIbat', { series: [{ key: 'current_ua', label: 'mA' }], format: (v) => String(Math.round(v / 1000) || 0), negative: true })?.setData(bh);
  const last = sh[sh.length - 1] || {}, lb = bh[bh.length - 1] || {};
  setValue(document.querySelector('[data-latest=cpu]'), fmt.pct(last.cpu)); setValue(document.querySelector('[data-latest=mem]'), fmt.bytes(last.mem_used)); setValue(document.querySelector('[data-latest=temp]'), fmt.c(last.temp_hot)); setValue(document.querySelector('[data-latest=ibat]'), fmt.ma(lb.current_ua));
}

// ---------- power ----------
async function loadPower() {
  const [p, hist] = await Promise.all([api('/api/power'), api('/api/battery/history')]);
  const b = p.battery, q = b.battery, c = b.charger, src = b.source; const f = p.status.fields || {};
  $('powerVerdict').innerHTML = f.verdict ? `<span class="pill ${verdictClass(f.verdict)}">${esc(f.verdict)}</span>` : '';
  $('batteryWarnings').innerHTML = b.warnings.map((w) => `<span class="pill warn">${esc(w)}</span>`).join('');
  cardIdx = 0;
  $('batteryCards').innerHTML = card('Voltage', fmt.v(q.voltage_avg ?? q.voltage_now), `design max ${fmt.v(q.voltage_max_design)}`)
    + card('Battery current', fmt.ma(q.current_now), q.current_now >= 0 ? 'charging / idle' : 'discharging', q.current_now < -20000 && c.online ? 'warn' : '')
    + card('Cell temperature', fmt.c(q.temperature_c), b.thermals.hottest ? `SoC peak ${b.thermals.hottest.temp_c} °C` : '', q.temperature_c >= 45 ? 'bad' : q.temperature_c >= 40 ? 'warn' : '')
    + card('Adapter input', fmt.w(c.input_power_w), src.advertised_power_w != null ? `${src.advertised_power_w} W offered` : '', c.online ? 'good' : 'bad')
    + card('Settled ICL', c.current_max != null ? `${(c.current_max / 1000).toFixed(0)} mA` : '—', 'AICL result, not the programmed limit')
    + card('Charge control', c.charge_behaviour || '—', f['control mode'] || '')
    + card('Reported capacity', q.capacity != null ? `${q.capacity}%` : '—', 'voltage-derived, not true SOC')
    + card('Integrated use', `${b.usage_since_manager_start.discharged_mah} mAh`, `${b.usage_since_manager_start.discharged_mwh} mWh out since start`);
  $('powerStatus').textContent = p.status.text || 'phoenix-charge-cap status unavailable';
  $('serviceTable').innerHTML = kv(b.services);
  $('batteryTable').innerHTML = kv(q, ['name', 'capacity_semantics', 'learned_full_capacity_available', 'state_of_health_percent']);
  $('chargerTable').innerHTML = kv(c, ['name']);
  $('sourceTable').innerHTML = kv({ ...src, ...Object.fromEntries(Object.entries(b.typec || {}).map(([k, v]) => [`typec_${k}`, v])) }, ['name']);
  $('telemetryReport').textContent = b.historical_telemetry_report || 'no telemetry report available';
  $('adapterTable').querySelector('tbody').innerHTML = p.adapters.map((a) => `<tr><td>${esc(a.label)}</td><td>${esc(a.source || '—')}</td><td class="num">${esc(a.voc)}</td><td class="num">${esc(a.res)}${a.res_kind === 'est' ? ' ~' : ''}</td><td class="num">${esc(a.maxw)}</td><td class="num">${esc(a.idle_ma)}</td><td class="num">${esc(a.load_ma)}</td><td>${stateTag(/GOOD|FAIR/.test(a.verdict) && !/DEFICIT/.test(a.verdict) ? 'good' : /DEFICIT|POOR/.test(a.verdict) ? 'bad' : 'warn')} ${esc(a.verdict)}</td><td class="muted">${esc((a.stamp || '').replace(/T(\d\d)(\d\d)\d\dZ/, ' $1:$2'))}</td></tr>`).join('') || '<tr><td colspan="9" class="muted">No adapter tests recorded yet.</td></tr>';
  $('powerPath').innerHTML = p.powerpath.map((r) => `<h3 style="margin:16px 0 6px">${esc(r.file)}</h3><pre class="mono-block">${esc(r.text)}</pre>`).join('');
  groupChart('power', 'pwrV', { series: [{ key: 'voltage_uv', label: 'V' }], format: (v) => (v / 1e6).toFixed(2) })?.setData(hist);
  groupChart('power', 'pwrI', { series: [{ key: 'current_ua', label: 'mA' }], format: (v) => String(Math.round(v / 1000) || 0), negative: true })?.setData(hist);
  groupChart('power', 'pwrT', { series: [{ key: 'temp_c', label: '°C' }], format: (v) => v.toFixed(1) })?.setData(hist);
  groupChart('power', 'pwrW', { series: [{ key: 'input_w', label: 'W' }], format: (v) => v.toFixed(1), forceZero: true })?.setData(hist.map((h) => ({ ...h, input_w: h.input_w ?? null })));
  const last = hist[hist.length - 1] || {};
  setValue(document.querySelector('[data-latest=pv]'), fmt.v(last.voltage_uv)); setValue(document.querySelector('[data-latest=pi]'), fmt.ma(last.current_ua)); setValue(document.querySelector('[data-latest=pt]'), fmt.c(last.temp_c)); setValue(document.querySelector('[data-latest=pw]'), fmt.w(last.input_w));
}

// ---------- runtime (LLM) ----------
async function loadRuntime() {
  const [s, p] = await Promise.all([api('/api/status'), api('/api/profiles')]); const hot = s.thermal.hottest || {};
  $('hero').innerHTML = `<div><span class="eyebrow">Runtime</span><div class="headline">${s.ready ? esc(s.profile) : s.running ? 'Loading model…' : 'No model loaded'}</div><div class="sub">${esc(s.turboquant.mode)} · ${esc(s.turboquant.backend)} · <code>${esc(s.runtime_url)}</code></div></div><div class="hero-side">${s.running ? `PID <b>${s.pid}</b><br>RSS <b>${fmt.bytes(s.process_rss_bytes)}</b><br>since <b>${s.started_at ? fmt.time(s.started_at) : '—'}</b>` : 'Ready to launch'}</div>`;
  cardIdx = 0;
  $('systemCards').innerHTML = card('Available memory', fmt.bytes(s.memory.available_bytes), `${s.memory.used_percent}% system used`, '', bar(s.memory.used_percent))
    + card('Runtime memory', fmt.bytes(s.process_rss_bytes), 'resident set')
    + card('Hottest sensor', hot.temp_c == null ? '—' : `${hot.temp_c} °C`, hot.name || '', hot.temp_c >= 80 ? 'bad' : hot.temp_c >= 65 ? 'warn' : 'good')
    + card('Swap used', fmt.bytes(s.memory.swap_used_bytes), `${fmt.bytes(s.memory.swap_total_bytes)} zram configured`);
  $('profiles').innerHTML = p.map((x) => `<div class="profile"><h3>${esc(x.title)}</h3><p>${esc(x.description)}</p><div class="tags"><span class="tag">${x.context / 1024}K ctx</span><span class="tag">${x.threads} threads</span><span class="tag">K ${esc(x.cache_k)}</span><span class="tag">V ${esc(x.cache_v)}</span><span class="tag">${x.cache_ram} MiB prompt cache</span>${x.experimental ? '<span class="tag">experimental</span>' : ''}</div><button data-start="${esc(x.name)}" ${s.running ? 'disabled' : ''}>Start</button></div>`).join('');
  $('profiles').querySelectorAll('[data-start]').forEach((b) => b.onclick = () => startProfile(b.dataset.start));
  $('stop').disabled = !s.running; $('restart').disabled = !s.running;
  $('turboTable').innerHTML = kv(s.turboquant); $('guardTable').innerHTML = kv({ min_available_mib: 768, thermal_critical_c: 92, require_external_power: 'yes (preflight)', min_battery_v: 3.7, log_rotation_mib: 8 });
}
async function startProfile(n) { try { toast('Loading model… this takes a minute'); await api(`/api/runtime/${encodeURIComponent(n)}/start`, { method: 'POST' }); toast('Runtime ready'); refreshPage(true); } catch (e) { toast(e.message, true); refreshPage(true); } }
$('stop').onclick = async () => { try { await api('/api/runtime/stop', { method: 'POST' }); toast('Runtime stopped'); refreshPage(true); } catch (e) { toast(e.message, true); } };
$('restart').onclick = async () => { try { toast('Restarting runtime…'); await api('/api/runtime/restart', { method: 'POST' }); toast('Runtime ready'); refreshPage(true); } catch (e) { toast(e.message, true); } };

// ---------- chat ----------
$('chatForm').onsubmit = async (e) => {
  e.preventDefault(); const p = $('prompt').value.trim(); if (!p) return; const box = $('messages'); box.insertAdjacentHTML('beforeend', `<div class="message user">${esc(p)}</div>`); $('prompt').value = ''; $('sendBtn').disabled = true;
  try { const r = await api('/api/chat', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ model: 'spark', messages: [{ role: 'user', content: p }], max_tokens: +$('maxTokens').value, temperature: +$('temperature').value, stream: false }) }); const m = r.choices?.[0]?.message || {}; box.insertAdjacentHTML('beforeend', `<div class="message assistant">${esc(m.content || m.reasoning_content || JSON.stringify(r))}</div>`); }
  catch (err) { box.insertAdjacentHTML('beforeend', `<div class="message assistant">Error: ${esc(err.message)}</div>`); }
  $('sendBtn').disabled = false; box.scrollTop = box.scrollHeight;
};

// ---------- tasks ----------
let procSort = 'cpu';
$('procSort').querySelectorAll('button').forEach((b) => b.onclick = () => { $('procSort').querySelectorAll('button').forEach((x) => x.classList.remove('on')); b.classList.add('on'); procSort = b.dataset.sort; loadTasks(); });
$('procSearch').oninput = debounce(loadTasks, 250); $('procLimit').onchange = loadTasks;
async function loadTasks() {
  const q = encodeURIComponent($('procSearch').value.trim());
  const [t, sh] = await Promise.all([api(`/api/processes?sort=${procSort}&limit=${$('procLimit').value}&q=${q}`), api('/api/system/history')]);
  const last = sh[sh.length - 1] || {};
  $('procCount').textContent = t.total; $('procLoad').textContent = `CPU ${fmt.pct(last.cpu)} · load ${last.load1 ?? '—'}`;
  groupChart('tasks', 'taskCpu', { series: [{ key: 'little', label: 'little cores (0–5)' }, { key: 'big', label: 'big cores (6–7)' }, { key: 'cpu', label: 'all' }], format: (v) => `${v.toFixed(0)}%`, forceZero: true, max: 100, fill: false })?.setData(sh.map((h) => ({ t: h.t, cpu: h.cpu, little: h.clusters?.policy0, big: h.clusters?.policy6 })));
  const tb = $('procTable').querySelector('tbody');
  tb.innerHTML = t.rows.map((r) => `<tr class="${r.killable ? 'me' : r.uid === 0 ? 'sys' : ''}"><td class="num">${r.pid}</td><td><b>${esc(r.name)}</b></td><td>${esc(r.user)}</td><td class="num">${r.cpu_percent.toFixed(1)}</td><td class="num">${fmt.bytes(r.rss_bytes)}</td><td class="num">${r.threads}</td><td>${stateTag({ R: 'running', S: 'sleeping', D: 'disk', Z: 'zombie', T: 'stopped', I: 'idle' }[r.state] || r.state)}</td><td class="num">${fmt.dur(r.elapsed_s)}</td><td class="cmd" title="${esc(r.cmdline)}">${esc(r.cmdline || r.name)}</td><td>${r.killable ? `<button class="tiny ghost" data-sig="TERM" data-pid="${r.pid}">stop</button> <button class="tiny danger" data-sig="KILL" data-pid="${r.pid}">kill</button>` : ''}</td></tr>`).join('');
  tb.querySelectorAll('[data-sig]').forEach((b) => b.onclick = async () => { if (b.dataset.sig === 'KILL' && !confirm(`SIGKILL pid ${b.dataset.pid}?`)) return; try { const r = await api(`/api/processes/${b.dataset.pid}/signal`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ signal: b.dataset.sig }) }); toast(`${r.signal} sent to ${r.name || r.pid}`); setTimeout(loadTasks, 600); } catch (e) { toast(e.message, true); } });
}
function debounce(fn, ms) { let t; return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); }; }

// ---------- services ----------
let svcState = '';
$('svcState').querySelectorAll('button').forEach((b) => b.onclick = () => { $('svcState').querySelectorAll('button').forEach((x) => x.classList.remove('on')); b.classList.add('on'); svcState = b.dataset.state; renderServices(); });
$('svcSearch').oninput = debounce(renderServices, 200);
let svcData = null;
async function loadServices() { svcData = await api('/api/services'); renderServices(); }
function renderServices() {
  if (!svcData) return; const q = $('svcSearch').value.toLowerCase();
  cardIdx = 0;
  $('phoenixUnits').innerHTML = svcData.phoenix.map((u) => `<div class="unit-card" style="--i:${cardIdx++}"><h3><span>${esc(u.unit)}</span>${stateTag(u.ActiveState)}</h3><div class="meta">${esc(u.Description || '')}<br>${esc(u.SubState || '')} · ${esc(u.UnitFileState || '')}${u.MainPID && u.MainPID !== '0' ? ` · pid ${esc(u.MainPID)}` : ''}${u.MemoryCurrent && u.MemoryCurrent !== '[not set]' && !isNaN(+u.MemoryCurrent) ? ` · ${fmt.bytes(+u.MemoryCurrent)}` : ''}${u.NRestarts && u.NRestarts !== '0' ? ` · restarts ${esc(u.NRestarts)}` : ''}<br>${u.ActiveEnterTimestamp ? `since ${esc(u.ActiveEnterTimestamp.replace(/^\w+ /, ''))}` : ''}</div></div>`).join('');
  const rows = svcData.services.filter((s) => (!svcState || s.active === svcState) && (!q || `${s.unit} ${s.description}`.toLowerCase().includes(q)));
  $('svcCount').textContent = `${rows.length} / ${svcData.services.length}`;
  $('svcTable').querySelector('tbody').innerHTML = rows.map((s) => `<tr><td><b>${esc(s.unit)}</b></td><td>${esc(s.load)}</td><td>${stateTag(s.active)}</td><td>${stateTag(s.sub)}</td><td class="muted">${esc(s.description)}</td></tr>`).join('');
  $('timerTable').querySelector('tbody').innerHTML = (svcData.timers || []).map((t) => `<tr><td><b>${esc(t.unit)}</b></td><td>${esc(t.activates || '')}</td><td>${esc(t.next || t.left || '')}</td><td>${esc(t.last || t.passed || '')}</td></tr>`).join('') || '<tr><td colspan="4" class="muted">No timers reported.</td></tr>';
}

// ---------- network ----------
let netIface = null;
$('netIface').onchange = () => { netIface = $('netIface').value; loadNetwork(); };
async function loadNetwork() {
  const [n, sh] = await Promise.all([api('/api/network'), api('/api/system/history')]);
  const ifaces = n.interfaces.filter((i) => i.name !== 'lo'); if (!netIface) netIface = (ifaces.find((i) => i.operstate === 'up') || ifaces[0] || {}).name;
  $('netIface').innerHTML = ifaces.map((i) => `<option ${i.name === netIface ? 'selected' : ''}>${esc(i.name)}</option>`).join(''); $('netIfaceLabel').textContent = netIface || '—';
  cardIdx = 0;
  $('ifaceCards').innerHTML = ifaces.map((i) => { const r = n.rates[i.name] || {}; return `<div class="card ${i.operstate === 'up' ? 'good' : ''}" style="--i:${cardIdx++}"><div class="label">${esc(i.name)} ${stateTag(i.operstate)}</div><div class="value">${i.operstate === 'up' ? `↓ ${fmt.rate(r.rx_bps)} ↑ ${fmt.rate(r.tx_bps)}` : 'no carrier'}</div><div class="unit">${i.speed_mbps ? `${i.speed_mbps} Mb/s · ` : ''}rx ${fmt.bytes(i.rx_bytes)} · tx ${fmt.bytes(i.tx_bytes)}${i.rx_errors || i.tx_errors ? ` · errors ${i.rx_errors}/${i.tx_errors}` : ''}</div><div class="addr">${esc(i.mac || '')}<br>${(i.addresses || []).map(esc).join('<br>') || '<span class="muted">no address</span>'}</div></div>`; }).join('');
  groupChart('network', 'netChart', { series: [{ key: 'rx', label: 'receive' }, { key: 'tx', label: 'transmit' }], format: (v) => fmt.rate(v), forceZero: true, fill: false })?.setData(sh.map((h) => ({ t: h.t, rx: h.net?.[netIface]?.rx_bps ?? null, tx: h.net?.[netIface]?.tx_bps ?? null })));
  $('portTable').querySelector('tbody').innerHTML = n.listening.map((p) => `<tr><td class="num"><b>${p.port}</b></td><td>${esc(p.proto)}</td><td>${esc(p.host)}</td><td class="muted">${esc(p.service || '')}</td></tr>`).join('');
}

// ---------- storage ----------
async function loadStorage() {
  const s = await api('/api/storage'); cardIdx = 0;
  $('mountCards').innerHTML = s.mounts.map((m) => `<div class="mount" style="--i:${cardIdx++}"><h3><span>${esc(m.mountpoint)}</span><span class="muted">${esc(m.fstype)}</span></h3><div class="meta">${esc(m.device)}</div>${bar(m.used_percent)}<div class="legend-row"><span>${fmt.bytes(m.used_bytes)} used · ${fmt.pct(m.used_percent)}</span><span>${fmt.bytes(m.available_bytes)} free of ${fmt.bytes(m.total_bytes)}</span></div></div>`).join('');
}

// ---------- thermal ----------
async function loadThermal() {
  const [t, sh] = await Promise.all([api('/api/thermal'), api('/api/system/history')]); const g = t.groups || {}; const hot = t.thermal.hottest || {};
  cardIdx = 0;
  $('thermalCards').innerHTML = card('Hottest', hot.temp_c == null ? '—' : `${hot.temp_c} °C`, hot.name || '', hot.temp_c >= 80 ? 'bad' : hot.temp_c >= 65 ? 'warn' : 'good')
    + card('CPU zones', fmt.c(g.cpu), 'max of cpu*-thermal', g.cpu >= 80 ? 'bad' : g.cpu >= 65 ? 'warn' : '')
    + card('GPU zones', fmt.c(g.gpu), 'max of gpuss*-thermal', g.gpu >= 80 ? 'bad' : g.gpu >= 65 ? 'warn' : '')
    + card('Battery', fmt.c(g.battery), 'qcom_qg', g.battery >= 45 ? 'bad' : g.battery >= 40 ? 'warn' : '')
    + card('Throttling', t.cooling.some((c) => c.cur > 0) ? 'active' : 'none', t.cooling.filter((c) => c.cur > 0).map((c) => `${c.type} ${c.cur}/${c.max}`).join(', ') || 'kernel trips 90/95 °C', t.cooling.some((c) => c.cur > 0) ? 'warn' : 'good');
  groupChart('thermal', 'thermChart', { series: [{ key: 'temp_cpu', label: 'CPU' }, { key: 'temp_gpu', label: 'GPU' }, { key: 'temp_battery', label: 'battery' }], format: (v) => `${v.toFixed(0)}°`, fill: false })?.setData(sh);
  $('freqTable').innerHTML = t.policies.map((p) => `<div class="freq-row"><span class="name">${esc(p.name)}<br><small>cpu ${esc(p.cpus)}</small></span>${bar(p.hw_max_khz ? 100 * p.cur_khz / p.hw_max_khz : 0, 'good')}<span class="val">${fmt.ghz(p.cur_khz)}<br><small class="muted">${esc(p.governor)} · max ${fmt.ghz(p.max_khz)}</small></span></div>`).join('');
  $('coolingTable').innerHTML = t.cooling.map((c) => `<div class="freq-row"><span class="name">${esc(c.type)}</span>${bar(c.max ? 100 * c.cur / c.max : 0, c.cur > 0 ? 'warn' : 'good')}<span class="val">state ${c.cur} / ${c.max}</span></div>`).join('');
  $('thermals').innerHTML = t.thermal.zones.map((z) => `<div class="thermal ${z.temp_c >= 80 ? 'hot' : z.temp_c >= 65 ? 'warm' : ''}">${esc(z.name)}<strong>${z.temp_c}°</strong></div>`).join('');
}

// ---------- logs ----------
async function loadLogs() {
  const l = await api('/api/logs?lines=300'); $('logText').textContent = l.lines.join('\n') || 'No runtime log yet.'; $('logText').scrollTop = $('logText').scrollHeight;
  await loadJournal();
}
async function loadJournal() {
  const unit = $('jUnit').value.trim(), prio = $('jPrio').value, lines = $('jLines').value;
  try {
    const j = await api(`/api/journal?lines=${lines}${unit ? `&unit=${encodeURIComponent(unit)}` : ''}${prio ? `&priority=${prio}` : ''}`);
    $('journal').innerHTML = j.entries.map((e) => `<div class="p${e.priority ?? 6}"><span class="ts">${esc(e.ts ? fmt.time(e.ts) : '')}</span><span class="u" title="${esc(e.unit)}">${esc(e.unit)}</span><span class="m">${esc(e.message)}</span></div>`).join('') || '<div><span></span><span></span><span class="m muted">No entries.</span></div>';
    $('journal').scrollTop = $('journal').scrollHeight;
  } catch (e) { $('journal').innerHTML = `<div><span></span><span></span><span class="m">${esc(e.message)}</span></div>`; }
}
$('refreshLogs').onclick = loadLogs; $('jRefresh').onclick = loadJournal; $('jUnit').onkeydown = (e) => { if (e.key === 'Enter') loadJournal(); }; $('jPrio').onchange = loadJournal; $('jLines').onchange = loadJournal;

// ---------- settings ----------
$('token').value = token;
$('saveToken').onclick = () => { token = $('token').value; sessionStorage.setItem('phoenixToken', token); toast('Token applied'); refreshPage(true); };
$('setPoll').value = String(settings.poll); $('setRange').value = String(settings.range); $('setMotion').value = settings.motion; $('setTween').value = settings.tween;
$('setPoll').onchange = (e) => { settings.poll = +e.target.value; schedule(); };
$('setRange').onchange = (e) => { settings.range = +e.target.value; for (const g in groups) { groups[g].range = settings.range; document.querySelectorAll(`.controls[data-chart-group=${g}] [data-role=range] button`).forEach((b) => b.classList.toggle('on', +b.dataset.range === settings.range)); applyGroup(g); } };
$('setMotion').onchange = (e) => { settings.motion = e.target.value; applyMotion(); };
$('setTween').onchange = (e) => { settings.tween = e.target.value; };
async function loadSettings(o) { $('securityState').textContent = o.manager.auth_enabled ? 'API authentication is enabled.' : 'Warning: manager mutations are accessible to the local network without authentication. Set API_TOKEN in /etc/phoenix-llm-manager.conf.'; $('aboutTable').innerHTML = kv({ device: o.info.model, hostname: o.info.hostname, os: o.info.os, kernel: o.info.kernel, boot_id: o.info.boot_id, uptime: fmt.dur(o.info.uptime_s), console: 'Phoenix Console 2.0 · stdlib Python + vanilla JS', service: 'phoenix-llm-manager.service (unprivileged)' }); }

// ---------- scheduler ----------
const loaders = { overview: loadOverview, power: loadPower, runtime: loadRuntime, chat: null, tasks: loadTasks, services: loadServices, network: loadNetwork, storage: loadStorage, thermal: loadThermal, logs: null, settings: loadSettings };
let timer, busy = false;
async function refreshPage(force = false) {
  if (busy || document.hidden) return; busy = true;
  try {
    const o = await loadRail();
    if (currentPage === 'tasks' && !$('procLive').checked && !force) { /* paused */ }
    else if (loaders[currentPage]) await loaders[currentPage](o);
    if (force && currentPage === 'logs') await loadLogs();
  } catch (e) { $('rail').innerHTML = `<span class="pill bad">${esc(e.message)}</span>`; }
  busy = false;
}
function schedule() { clearInterval(timer); timer = setInterval(refreshPage, settings.poll); }
document.addEventListener('visibilitychange', () => { if (!document.hidden) refreshPage(); });
const initial = pageFromHash(); if (initial && $(initial)) showPage(initial); else refreshPage(true);
schedule();
