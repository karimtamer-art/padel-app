/* Ranking Lab — UI layer.
 *
 * All maths lives in the Dart kernel (globalThis.rankLab); this file only asks
 * questions and draws answers. If you find yourself computing a rating here,
 * stop — it belongs in the kernel where the golden tests can see it. */

(() => {
  'use strict';

  // ── kernel ────────────────────────────────────────────────────────────────
  const call = (op, args = {}) => {
    const res = JSON.parse(globalThis.rankLab(JSON.stringify({ op, ...args })));
    if (res.error) throw new Error(res.error);
    return res;
  };

  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

  // ── formatting ────────────────────────────────────────────────────────────
  const f = (v, dp = 2) => (v === null || v === undefined || Number.isNaN(v) ? '—' : Number(v).toFixed(dp));
  const pct = (v, dp = 0) => (v === null || v === undefined || Number.isNaN(v) ? '—' : Number(v).toFixed(dp) + '%');
  const signed = (v, dp = 2) => (v === null || v === undefined || Number.isNaN(v) ? '—' : (v >= 0 ? '+' : '') + Number(v).toFixed(dp));
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

  /// Mirrors RankingScale.divisions — what the player would actually be shown.
  const DIVISIONS = [
    { key: 'D', name: 'Division D', metal: 'Bronze', league: 'Beginner League', min: 0.0, max: 1.9 },
    { key: 'C', name: 'Division C', metal: 'Silver', league: 'Intermediate League', min: 2.0, max: 3.4 },
    { key: 'B', name: 'Division B', metal: 'Gold', league: 'Advanced League', min: 3.5, max: 4.9 },
    { key: 'A', name: 'Division A', metal: 'Elite', league: 'Expert League', min: 5.0, max: 7.0 },
  ];
  const divisionFor = (lv) => DIVISIONS.find((d) => lv <= d.max) || DIVISIONS[DIVISIONS.length - 1];
  const quarter = (lv) => Math.round(Math.max(0, Math.min(7, lv)) * 4) / 4;
  const confidenceWord = (sigma) => (sigma <= 0.3 ? 'High' : sigma <= 0.5 ? 'Moderate' : sigma <= 0.7 ? 'Low' : 'Very low');

  /// Severity for an absolute rating error, in levels.
  const errClass = (e) => {
    const a = Math.abs(e);
    return a <= 0.35 ? 'good' : a <= 0.8 ? 'warn' : 'crit';
  };

  // ── engine identity: one colour per engine, everywhere ────────────────────
  const ENGINE_COLOR = {
    v2: 'var(--e2)',
    v3: 'var(--e3)',
    tuned: 'var(--e6)',
    aggressive: 'var(--e7)',
    trueskill: 'var(--e4)',
    trueskill_set: 'var(--e5)',
    glicko: 'var(--e1)',
    v3a: 'var(--v3a)',
    v3b: 'var(--v3b)',
    v3c: 'var(--v3c)',
    v3d: 'var(--v3d)',
    v3e: 'var(--v3e)',
    v3f: 'var(--v3f)',
    v3f5: 'var(--v3f5)',
  };
  const V3_VARIANTS = ['v3a', 'v3b', 'v3c', 'v3d', 'v3e', 'v3f', 'v3f5'];
  const V3_REFS = ['v2', 'trueskill', 'glicko'];
  const colorOf = (id) => ENGINE_COLOR[id] || 'var(--accent)';

  // Production's two match counts: K is boosted over the first 5, and a rating
  // stays provisional below 10. Mirrored here so the UI can scale them together.
  const CURRENT_BOOST = 5;
  const CURRENT_PROVISIONAL_AT = 10;

  let META = null;
  const CFG = {};        // engine id → config overrides (live, applies everywhere)
  const SELECTED = {};   // picker id → Set of engine ids

  const specOf = (id) => (CFG[id] && Object.keys(CFG[id]).length ? { id, cfg: CFG[id] } : { id });
  const specsFor = (picker) => [...(SELECTED[picker] || [])].map(specOf);
  const labelOf = (id) => (META.engines.find((e) => e.id === id) || {}).label || id;
  const shortOf = (id) => (META.engines.find((e) => e.id === id) || {}).short || id;

  // ── tiny DOM helpers ──────────────────────────────────────────────────────
  const html = (strings, ...vals) => strings.reduce((a, s, i) => a + s + (vals[i] ?? ''), '');
  const setHTML = (node, s) => { node.innerHTML = s; return node; };

  function enginePicker(hostId, pickerKey, defaults, { multi = true, onChange = null, ids = null, min = 1 } = {}) {
    const host = $('#' + hostId);
    if (!host) return;
    SELECTED[pickerKey] = new Set(defaults);
    const list = ids ? META.engines.filter((e) => ids.includes(e.id)) : META.engines;
    const paint = () => {
      host.innerHTML = list
        .map((e) => {
          const on = SELECTED[pickerKey].has(e.id);
          return `<button class="chip" role="button" aria-pressed="${on}" data-id="${e.id}"
            style="color:${colorOf(e.id)}" title="${esc(e.blurb)}">
            <span class="dot"></span>${esc(e.short)}</button>`;
        })
        .join('');
    };
    host.addEventListener('click', (ev) => {
      const b = ev.target.closest('.chip');
      if (!b) return;
      const id = b.dataset.id;
      if (multi) {
        if (SELECTED[pickerKey].has(id)) {
          if (SELECTED[pickerKey].size > min) SELECTED[pickerKey].delete(id);
        } else SELECTED[pickerKey].add(id);
      } else {
        SELECTED[pickerKey] = new Set([id]);
      }
      paint();
      if (onChange) onChange();
    });
    paint();
  }

  const legendFor = (items) =>
    `<ul class="legend">${items
      .map((i) => `<li><span class="swatch" style="background:${i.color}"></span>${esc(i.name)}</li>`)
      .join('')}</ul>`;

  // ── charts ────────────────────────────────────────────────────────────────
  // Deliberately hand-rolled SVG: no CDN is reachable, and these five shapes
  // cover everything the lab needs.

  function lineChart(opt) {
    const W = 720, H = opt.height || 260;
    const m = { l: 44, r: 16, t: 12, b: 34 };
    const series = opt.series.filter((s) => s.ys && s.ys.length);
    if (!series.length) return '<div class="empty">No data.</div>';
    const n = Math.max(...series.map((s) => s.ys.length));
    const all = series.flatMap((s) => s.ys).filter((v) => v !== null && !Number.isNaN(v));
    if (opt.ref !== undefined && opt.ref !== null) all.push(opt.ref);
    const autoLo = opt.yMin === undefined, autoHi = opt.yMax === undefined;
    let lo = autoLo ? Math.min(...all) : opt.yMin;
    let hi = autoHi ? Math.max(...all) : opt.yMax;
    if (hi - lo < 0.5) { const c = (hi + lo) / 2; lo = c - 0.25; hi = c + 0.25; }
    // Only pad an axis we chose ourselves — padding an explicit 0–7 rating scale
    // would label the chart up to 7.6, which is not a rating that can exist.
    const padY = (hi - lo) * 0.08;
    if (autoLo) lo -= padY;
    if (autoHi) hi += padY;

    const x0 = opt.x0 !== undefined ? opt.x0 : 0;
    const X = (i) => m.l + ((i) / Math.max(1, n - 1)) * (W - m.l - m.r);
    const Y = (v) => m.t + (1 - (v - lo) / (hi - lo)) * (H - m.t - m.b);

    let g = '';
    const ticks = 5;
    for (let i = 0; i <= ticks; i++) {
      const v = lo + ((hi - lo) * i) / ticks;
      const y = Y(v);
      g += `<line class="grid" x1="${m.l}" y1="${y.toFixed(1)}" x2="${W - m.r}" y2="${y.toFixed(1)}"/>`;
      g += `<text class="tickt" x="${m.l - 7}" y="${(y + 3.5).toFixed(1)}" text-anchor="end">${f(v, opt.yDp ?? 1)}</text>`;
    }
    const step = Math.max(1, Math.ceil(n / 12));
    for (let i = 0; i < n; i += step) {
      const label = opt.xTicks ? opt.xTicks[i] : x0 + i;
      g += `<text class="tickt" x="${X(i).toFixed(1)}" y="${H - m.b + 15}" text-anchor="middle">${esc(String(label))}</text>`;
    }
    g += `<line class="axis" x1="${m.l}" y1="${H - m.b}" x2="${W - m.r}" y2="${H - m.b}"/>`;

    if (opt.ref !== undefined && opt.ref !== null) {
      const y = Y(opt.ref);
      g += `<line class="truthline" x1="${m.l}" y1="${y.toFixed(1)}" x2="${W - m.r}" y2="${y.toFixed(1)}"/>`;
      g += `<text class="tickt" style="fill:var(--truth)" x="${W - m.r}" y="${(y - 5).toFixed(1)}" text-anchor="end">${esc(opt.refLabel || 'true skill ' + f(opt.ref))}</text>`;
    }
    if (opt.marker !== undefined && opt.marker !== null && opt.marker >= 0 && opt.marker < n) {
      const x = X(opt.marker);
      g += `<line class="idealline" x1="${x.toFixed(1)}" y1="${m.t}" x2="${x.toFixed(1)}" y2="${H - m.b}"/>`;
      if (opt.markerLabel) g += `<text class="tickt" x="${(x + 5).toFixed(1)}" y="${m.t + 11}">${esc(opt.markerLabel)}</text>`;
    }

    for (const s of series) {
      const pts = s.ys.map((v, i) => (v === null || Number.isNaN(v) ? null : `${X(i).toFixed(1)},${Y(v).toFixed(1)}`)).filter(Boolean);
      g += `<polyline class="serie" style="stroke:${s.color}${s.dashed ? ';stroke-dasharray:6 4' : ''}" points="${pts.join(' ')}"/>`;
      const last = s.ys[s.ys.length - 1];
      if (last !== null && !Number.isNaN(last)) {
        g += `<circle cx="${X(s.ys.length - 1).toFixed(1)}" cy="${Y(last).toFixed(1)}" r="3.4" style="fill:${s.color}"/>`;
      }
    }
    g += `<text class="axlabel" x="${m.l}" y="${H - 4}">${esc(opt.xLabel || 'matches played')}</text>`;

    return `<svg class="chart" viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(opt.aria || opt.xLabel || 'chart')}">${g}</svg>`;
  }

  function scatterChart(opt) {
    const W = 420, H = 340;
    const m = { l: 40, r: 12, t: 12, b: 34 };
    const X = (v) => m.l + (v / 7) * (W - m.l - m.r);
    const Y = (v) => m.t + (1 - v / 7) * (H - m.t - m.b);
    let g = '';
    for (let v = 0; v <= 7; v++) {
      g += `<line class="grid" x1="${m.l}" y1="${Y(v).toFixed(1)}" x2="${W - m.r}" y2="${Y(v).toFixed(1)}"/>`;
      g += `<text class="tickt" x="${m.l - 6}" y="${(Y(v) + 3.5).toFixed(1)}" text-anchor="end">${v}</text>`;
      g += `<text class="tickt" x="${X(v).toFixed(1)}" y="${H - m.b + 15}" text-anchor="middle">${v}</text>`;
    }
    g += `<line class="idealline" x1="${X(0)}" y1="${Y(0)}" x2="${X(7)}" y2="${Y(7)}"/>`;
    for (const p of opt.points) {
      g += `<circle class="pt" cx="${X(p[0]).toFixed(1)}" cy="${Y(p[1]).toFixed(1)}" r="2.6" style="fill:${opt.color || 'var(--accent)'}"/>`;
    }
    g += `<text class="axlabel" x="${m.l}" y="${H - 3}">true skill →</text>`;
    g += `<text class="axlabel" transform="translate(11,${m.t + 78}) rotate(-90)">engine rating →</text>`;
    return `<svg class="chart" viewBox="0 0 ${W} ${H}" role="img" aria-label="true skill against engine rating">${g}</svg>`;
  }

  function histChart(opt) {
    const W = 420, H = 260;
    const m = { l: 34, r: 10, t: 10, b: 30 };
    const bins = opt.est.length;
    const hi = Math.max(...opt.est, ...opt.truth, 1);
    const bw = (W - m.l - m.r) / bins;
    const Y = (v) => m.t + (1 - v / hi) * (H - m.t - m.b);
    let g = '';
    for (let i = 0; i < bins; i++) {
      const h = H - m.b - Y(opt.est[i]);
      if (h > 0.2) g += `<rect class="bar" x="${(m.l + i * bw).toFixed(1)}" y="${Y(opt.est[i]).toFixed(1)}" width="${(bw - 0.5).toFixed(1)}" height="${h.toFixed(1)}" style="fill:${opt.color || 'var(--accent)'}"/>`;
    }
    const pts = opt.truth.map((v, i) => `${(m.l + i * bw + bw / 2).toFixed(1)},${Y(v).toFixed(1)}`);
    g += `<polyline class="truthline" points="${pts.join(' ')}"/>`;
    g += `<line class="axis" x1="${m.l}" y1="${H - m.b}" x2="${W - m.r}" y2="${H - m.b}"/>`;
    for (let lv = 0; lv <= 7; lv++) {
      const x = m.l + (lv / 0.25) * bw;
      if (x <= W - m.r) g += `<text class="tickt" x="${x.toFixed(1)}" y="${H - m.b + 14}" text-anchor="middle">${lv}</text>`;
    }
    g += `<text class="axlabel" x="${m.l}" y="${H - 2}">rating →</text>`;
    return `<svg class="chart" viewBox="0 0 ${W} ${H}" role="img" aria-label="distribution of true skill against engine ratings">${g}</svg>`;
  }

  function barChart(rows, opt = {}) {
    const W = 720, rowH = 30;
    const m = { l: opt.labelWidth || 150, r: 60, t: 6, b: 22 };
    const H = m.t + rows.length * rowH + m.b;
    const vals = rows.map((r) => r.value);
    const lo = Math.min(0, ...vals), hi = Math.max(0, ...vals);
    const span = hi - lo || 1;
    const X = (v) => m.l + ((v - lo) / span) * (W - m.l - m.r);
    let g = '';
    const zero = X(0);
    g += `<line class="axis" x1="${zero.toFixed(1)}" y1="${m.t}" x2="${zero.toFixed(1)}" y2="${(H - m.b).toFixed(1)}"/>`;
    rows.forEach((r, i) => {
      const y = m.t + i * rowH + 5;
      const x = X(Math.min(0, r.value));
      const w = Math.abs(X(r.value) - zero);
      g += `<rect x="${x.toFixed(1)}" y="${y}" width="${Math.max(1, w).toFixed(1)}" height="${rowH - 12}" rx="2" style="fill:${r.color || 'var(--accent)'}"/>`;
      g += `<text class="tickt" x="${m.l - 8}" y="${y + rowH / 2 - 2}" text-anchor="end" style="fill:var(--ink)">${esc(r.label)}</text>`;
      g += `<text class="tickt" x="${(X(r.value) + (r.value >= 0 ? 6 : -6)).toFixed(1)}" y="${y + rowH / 2 - 2}" text-anchor="${r.value >= 0 ? 'start' : 'end'}">${esc(r.text ?? f(r.value))}</text>`;
    });
    return `<svg class="chart" viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(opt.aria || 'bar chart')}">${g}</svg>`;
  }

  function calibChart(seriesList) {
    const W = 340, H = 300;
    const m = { l: 38, r: 12, t: 12, b: 32 };
    const X = (v) => m.l + ((v - 0.5) / 0.5) * (W - m.l - m.r);
    const Y = (v) => m.t + (1 - (v - 0.5) / 0.5) * (H - m.t - m.b);
    let g = '';
    for (let v = 0.5; v <= 1.0001; v += 0.1) {
      g += `<line class="grid" x1="${m.l}" y1="${Y(v).toFixed(1)}" x2="${W - m.r}" y2="${Y(v).toFixed(1)}"/>`;
      g += `<text class="tickt" x="${m.l - 6}" y="${(Y(v) + 3.5).toFixed(1)}" text-anchor="end">${Math.round(v * 100)}</text>`;
      g += `<text class="tickt" x="${X(v).toFixed(1)}" y="${H - m.b + 14}" text-anchor="middle">${Math.round(v * 100)}</text>`;
    }
    g += `<line class="idealline" x1="${X(0.5)}" y1="${Y(0.5)}" x2="${X(1)}" y2="${Y(1)}"/>`;
    for (const s of seriesList) {
      const pts = s.bins.filter((b) => b.n > 30).map((b) => `${X(b.predicted).toFixed(1)},${Y(b.observed).toFixed(1)}`);
      if (pts.length) g += `<polyline class="serie" style="stroke:${s.color}" points="${pts.join(' ')}"/>`;
    }
    g += `<text class="axlabel" x="${m.l}" y="${H - 2}">predicted % → (observed ↑)</text>`;
    return `<svg class="chart" viewBox="0 0 ${W} ${H}" role="img" aria-label="probability calibration">${g}</svg>`;
  }

  // ── seed plumbing ─────────────────────────────────────────────────────────
  const seed = () => parseInt($('#seed').value, 10) || 1;

  // ══════════════════════════════════════════════════════════════════════════
  // STORY
  // ══════════════════════════════════════════════════════════════════════════
  const PRESETS = [
    ['Beginner', 1.5], ['Low int.', 2.5], ['Average', 3.3],
    ['Advanced', 4.5], ['Strong', 5.5], ['Elite', 6.5],
  ];

  let story = null;

  function storyInit() {
    $('#st_presets').innerHTML =
      PRESETS.map(([n, v]) => `<button class="chip" data-v="${v}">${n} ${v}</button>`).join('') +
      '<button class="chip" data-v="random">random</button>';
    $('#st_presets').addEventListener('click', (e) => {
      const b = e.target.closest('.chip');
      if (!b) return;
      $('#st_true').value = b.dataset.v === 'random' ? (0.8 + Math.random() * 5.8).toFixed(1) : b.dataset.v;
    });
    $('#st_placementQuick').innerHTML = [5, 8, 10, 15, 20, 30]
      .map((v) => `<button class="chip" data-p="${v}">${v}</button>`)
      .join('');
    $('#st_placementQuick').addEventListener('click', (e) => {
      const b = e.target.closest('.chip');
      if (!b) return;
      $('#st_placement').value = b.dataset.p;
      placementNote();
    });
    $('#st_placement').addEventListener('input', placementNote);
    fillWorlds('#st_world');
    enginePicker('st_engines', 'story', ['v2', 'v3'], { onChange: placementNote });
    $('#st_start').addEventListener('click', storyStart);
    placementNote();
  }

  /// Stretches an engine's placement schedule to a different length.
  ///
  /// Changing `placementMatches` alone would leave the stage boundaries where
  /// they were, so a 30-match placement would spend matches 10–29 in the final,
  /// smallest stage — a different rule, not a longer one. The boundaries, the K
  /// schedule and the reveal gate all scale together, so the SHAPE of placement
  /// (big steps first, small steps last) survives at any length.
  ///
  /// Short placements are the awkward case: you cannot fit three stages into two
  /// matches. Rather than emit boundaries that run past the end of placement,
  /// stages are dropped, and the K values are resampled across what is left so
  /// the first stage stays the biggest and the last stays the gentlest.
  function scalePlacement(baseEnds, baseK, basePlacement, want) {
    const n = Math.max(1, Math.min(baseEnds.length, want));

    const ends = [];
    for (let i = 0; i < n; i++) {
      let v = Math.round((baseEnds[i] / basePlacement) * want);
      // leave room for at least one match in every stage, before and after
      v = Math.max(i + 1, Math.min(want - (n - 1 - i), v));
      ends.push(v);
    }
    ends[n - 1] = want;                                  // placement ends where it says
    for (let i = n - 2; i >= 0; i--) ends[i] = Math.min(ends[i], ends[i + 1] - 1);
    for (let i = 1; i < n; i++) ends[i] = Math.max(ends[i], ends[i - 1] + 1);

    // resample K: 3 stages -> unchanged; 2 -> first and last; 1 -> the biggest
    const ks = [];
    for (let i = 0; i < n; i++) {
      const at = n === 1 ? 0 : Math.round((i * (baseK.length - 1)) / (n - 1));
      ks.push(baseK[at]);
    }
    return { ends, ks };
  }

  function placementPatch(id, want) {
    // V2 has no placement phase, so there is nothing to stretch — but it does
    // have two match counts, and leaving them fixed while V3's move would rig
    // the comparison. Both scale together, keeping production's 5-of-10 ratio.
    // At 10 this is the identity, so the default really is production.
    if (id === 'v2') {
      if (!want || want === CURRENT_PROVISIONAL_AT) return null;
      return {
        provisionalAt: want,
        boostWindow: Math.max(1, Math.round(want * CURRENT_BOOST / CURRENT_PROVISIONAL_AT)),
      };
    }

    const preset = META.presets[id] || {};
    const base = preset.placementMatches || 10;
    if (!want || want === base) return null;
    const { ends, ks } = scalePlacement(
      preset.stageEnds || [3, 7, 10],
      preset.stageK || [0.8, 0.5, 0.3],
      base,
      want
    );
    return {
      placementMatches: want,
      stageEnds: ends,
      stageK: ks,
      // the reveal is gated on placement too, or a longer placement would show a
      // public rating while the player is still provisional
      displayMinMatches: want,
    };
  }

  function placementNote() {
    const want = Math.max(1, Math.min(60, parseInt($('#st_placement').value, 10) || 10));
    const picked = [...(SELECTED.story || [])];
    // describe an engine that actually has a placement phase; V2 has none
    const id = picked.find((x) => x !== 'v2') || 'v3';
    const preset = META.presets[id] || META.presets.v3;
    const p = placementPatch(id, want);
    const stages = p ? p.stageEnds : preset.stageEnds || [3, 7, 10];
    const ks = p ? p.stageK : preset.stageK || [0.8, 0.5, 0.3];
    const spans = stages.map(
      (end, i) => `${i === 0 ? 1 : stages[i - 1] + 1}–${end}: K ${f(ks[i], 2)}`
    );
    const dropped = stages.length < (preset.stageEnds || [3, 7, 10]).length;
    const v2Patch = placementPatch('v2', want);

    $('#st_placementNote').innerHTML =
      `<strong>${esc(shortOf(id))}</strong> stretches to fit — ${esc(spans.join(' · '))}.
       Big steps first, gentle steps last, whatever the length. The public rating stays hidden
       for all of it.` +
      (dropped
        ? ` Too short for ${(preset.stageEnds || []).length} stages, so it runs ${stages.length}.`
        : '') +
      (picked.includes('v2')
        ? ` <strong>V2 has no placement phase</strong>, so its two match counts scale together
           instead: K boosted over the first
           <strong>${v2Patch ? v2Patch.boostWindow : CURRENT_BOOST}</strong> matches, provisional
           until <strong>${want}</strong>. Both engines now commit at the same point.` +
          (v2Patch
            ? ` That is no longer production, so V2 is marked <em>adapted</em> —
               only ${CURRENT_PROVISIONAL_AT} is the real thing.`
            : '')
        : '');
  }

  function storyStart() {
    const startRating = $('#st_startRating').value.trim();
    const startSigma = $('#st_startSigma').value.trim();
    const declared = $('#st_declared').value;
    const placement = parseInt($('#st_placement').value, 10) || 10;
    const engines = specsFor('story').map((s) => {
      const spec = { ...s };
      if (startRating) spec.startRating = parseFloat(startRating);
      if (startSigma) spec.startSigma = parseFloat(startSigma);
      if (declared !== 'unknown') {
        spec.declared = declared;
        spec.cfg = { ...(spec.cfg || {}), useDeclaredPrior: true };
      }
      const p = placementPatch(spec.id, placement);
      if (p) spec.cfg = { ...(spec.cfg || {}), ...p };
      return spec;
    });
    story = call('story.start', {
      seed: seed(),
      trueSkill: parseFloat($('#st_true').value),
      name: $('#st_name').value || 'Player',
      world: $('#st_world').value,
      pool: $('#st_pool').value,
      engines,
    }).state;
    renderStory(null);
  }

  function storyPlay(req) {
    try {
      const res = call('story.next', req || {});
      story = res.state;
      renderStory(res.match);
    } catch (e) {
      $('#st_out').insertAdjacentHTML('afterbegin', `<div class="err">${esc(e.message)}</div>`);
    }
  }

  function storyAuto(n) {
    story = call('story.auto', { n }).state;
    renderStory(story.log[story.log.length - 1] || null);
  }

  function renderStory(match) {
    const s = story;
    const out = $('#st_out');
    const done = s.played;
    // Only engines with a real placement phase have something to "finish". If
    // none is selected (V2 alone, say), fall back to the furthest display gate.
    const withPhase = s.engines.filter((e) => e.hasPlacement);
    const placement = withPhase.length
      ? Math.max(...withPhase.map((e) => e.placementMatches))
      : Math.max(...s.engines.map((e) => e.gateMatches));
    const phaseWord = withPhase.length ? 'placement' : 'until settled';

    const controls = html`
      <div class="card stack">
        <header>
          <h2>${esc(s.name)} · true skill ${f(s.trueSkill, 2)}</h2>
          <span class="grow"></span>
          <span class="tag ${done < placement ? 'warn' : 'good'}">${done < placement ? `${phaseWord} ${done} / ${placement}` : `${done} matches played`}</span>
          <span class="tag quiet">${s.wins}W · ${s.losses}L</span>
          <span class="tag quiet">seed ${s.seed}</span>
        </header>
        <div class="playbar">
          <button class="primary big" id="st_next">Play next match</button>
          <button id="st_win">Force a win</button>
          <button id="st_loss">Force a loss</button>
        </div>
        <div class="row">
          <label class="field" style="flex:0 0 190px"><span>Type an exact score</span>
            <input type="text" id="st_score" placeholder="6-4,6-3" /></label>
          <button id="st_playScore">Play that score</button>
          <span class="grow"></span>
          <button id="st_rest">${withPhase.length ? 'Finish placement' : 'Play to the reveal'} (${Math.max(0, placement - done)} left)</button>
          <button id="st_10">+10</button>
          <button id="st_40">+40</button>
        </div>
        <p class="hint">Partner and opponents are picked from <strong>true</strong> skill, never from
        any engine's rating — otherwise the engines would each see a different match and the
        comparison would mean nothing.</p>
      </div>`;

    const cards = s.engines
      .map((e) => {
        const m = match ? match.engines.find((x) => x.key === e.key) : null;
        const t = m && m.focus;
        const col = colorOf(e.id);
        const gate = e.displayReady;
        const q = quarter(e.rating);
        const div = divisionFor(q);
        return html`
        <div class="enginecard" style="--eng:${col}">
          <header>
            <span class="name">${esc(e.label)}</span>
            <span class="grow"></span>
            ${stateTag(e)}
          </header>
          <div class="row" style="align-items:baseline;gap:14px">
            <div><div class="bigval" style="color:${col}">${f(e.rating)}</div>
              <div class="hint">internal rating</div></div>
            <div><div class="num" style="font-size:1rem">${signed(e.error)}</div>
              <div class="hint">error vs true</div></div>
            <div><div class="num" style="font-size:1rem">${f(e.sigma)}</div>
              <div class="hint">sigma</div></div>
            <span class="grow"></span>
            <span class="tag ${errClass(e.error)}">${Math.abs(e.error) <= 0.35 ? 'close' : Math.abs(e.error) <= 0.8 ? 'off' : 'far off'}</span>
          </div>
          ${t ? mathStrip(t) : ''}
          <div class="playerview">
            <div class="viewbox dev">
              <span class="cap">what you see as the developer</span>
              <div class="num">rating ${f(e.rating)} · sigma ${f(e.sigma)} · ${e.matches} matches</div>
              <div class="hint">true skill ${f(s.trueSkill)} — hidden from the engine</div>
            </div>
            <div class="viewbox user">
              <span class="cap">what the player would see</span>
              ${gate
                ? `<div class="num" style="font-size:1.05rem">Level ${f(q, 2)} · ${div.metal}</div>
                   <div class="hint">${div.name} — ${div.league} · confidence ${confidenceWord(e.sigma)}</div>`
                : `<div class="num" style="font-size:1.05rem">${e.hasPlacement ? 'Finding your level' : 'Not shown yet'}</div>
                   <div class="hint">${gateReason(e)}</div>`}
            </div>
          </div>
        </div>`;
      })
      .join('');

    const chart = html`
      <div class="card stack">
        <header><h2>Rating against the truth</h2>
          <span class="grow"></span>${legendFor(s.engines.map((e) => ({ name: e.short, color: colorOf(e.id) })).concat([{ name: 'true skill', color: 'var(--truth)' }]))}
        </header>
        <div class="chartbox">
          ${lineChart({
            series: s.engines.map((e) => ({ name: e.short, color: colorOf(e.id), ys: e.ratingTrack })),
            ref: s.trueSkill,
            refLabel: 'true skill ' + f(s.trueSkill),
            marker: placement,
            markerLabel: 'placement ends',
            yMin: 0, yMax: 7, yDp: 1,
            xLabel: 'matches played',
          })}
        </div>
      </div>`;

    out.innerHTML =
      controls +
      (match ? matchCard(match) : '') +
      `<div class="stack">${cards}</div>` +
      chart +
      storyLog(s);

    $('#st_next').onclick = () => storyPlay({});
    $('#st_win').onclick = () => storyPlay({ winner: 'A' });
    $('#st_loss').onclick = () => storyPlay({ winner: 'B' });
    $('#st_playScore').onclick = () => storyPlay({ score: $('#st_score').value });
    $('#st_rest').onclick = () => storyAuto(Math.max(1, placement - done));
    $('#st_10').onclick = () => storyAuto(10);
    $('#st_40').onclick = () => storyAuto(40);
  }

  /// Engines differ in KIND, not just in numbers: only the hybrid has a
  /// placement phase. Production has a display gate and a K boost, which are
  /// two separate mechanisms and neither is a phase — so it must not be
  /// labelled as one.
  function stateTag(e) {
    if (e.hasPlacement) {
      return e.inPlacement
        ? `<span class="tag warn" title="A placement phase with its own rules, ending at match ${e.placementMatches}.">placement ${Math.min(e.matches, e.placementMatches)} / ${e.placementMatches}</span>`
        : '<span class="tag quiet">established</span>';
    }
    const adapted = e.adapted
      ? `<span class="tag info" title="Thresholds moved off production's own values so this engine commits at the same match count as the one it is being compared with. K boosted over the first ${e.boostWindow} matches, provisional until ${e.gateMatches}.">adapted</span> `
      : '';
    return adapted + (e.displayReady
      ? '<span class="tag quiet" title="No placement phase — this engine simply passed its display gate.">settled</span>'
      : `<span class="tag warn" title="No placement phase. A rating is flagged provisional until sigma is low enough AND enough matches are played.">provisional</span>`);
  }

  /// Says which half of the gate is still failing, in the engine's own terms.
  function gateReason(e) {
    const needMatches = e.matches < e.gateMatches;
    const needSigma = e.sigma > e.gateSigma;
    if (e.hasPlacement) {
      const left = Math.max(0, e.placementMatches - e.matches);
      if (left > 0) return `${e.matches} / ${e.placementMatches} placement matches`;
      return needSigma
        ? `placement done, but still too uncertain to show (sigma ${f(e.sigma)}, needs ${f(e.gateSigma)} or lower)`
        : 'placement done';
    }
    const parts = [];
    if (needMatches) parts.push(`${e.matches} of ${e.gateMatches} matches played`);
    if (needSigma) parts.push(`sigma ${f(e.sigma)}, needs ${f(e.gateSigma)} or lower`);
    return parts.length
      ? `Rating stays provisional — ${parts.join(' · ')}`
      : 'Rating is settled';
  }

  function mathStrip(t) {
    const has = t.k !== undefined;
    const cells = [
      ['team', f(t.teamRating)],
      ['opponents', f(t.oppRating)],
      ['expected', pct(t.expected * 100, 0)],
      ...(has ? [['K', f(t.k, 3)], ['W', f(t.w, 3)], ['signal S', f(t.signal, 3)]] : []),
      ...(has ? [['from result', f(t.resultPart, 3)], ['from margin', f(t.marginPart, 3)]] : []),
      ['Δ rating', signed(t.delta)],
      ['sigma', `${f(t.sigmaBefore)}→${f(t.sigmaAfter)}`],
    ];
    const marginNote =
      has && t.marginEffect !== undefined
        ? `<p class="hint">The games margin ${Math.abs(t.marginEffect) < 0.001 ? 'made no difference here' : `moved this by <strong>${signed(t.marginEffect, 3)}</strong>`}${t.won && t.marginEffect < -0.001 ? ' — a win that cost rating because the score was closer than the engine expected.' : '.'}</p>`
        : '';
    return html`
      <div class="mathrow">
        ${cells
          .map(([k, v]) => `<div><dt>${esc(k)}</dt><dd class="${k === 'Δ rating' ? (t.delta >= 0 ? 'pos' : 'neg') : ''}">${esc(v)}</dd></div>`)
          .join('')}
      </div>
      ${marginNote}`;
  }

  function matchCard(m) {
    return html`
      <div class="matchcard">
        <div class="spread">
          <h3>Match ${m.n}</h3>
          <span class="row tight">
            <span class="tag ${m.won ? 'good' : 'crit'}">${m.won ? 'won' : 'lost'}</span>
            <span class="tag quiet">${esc(m.source)}</span>
          </span>
        </div>
        <div class="teams">
          <div class="team">
            <span class="who">You + partner</span>
            <span class="lvl num">partner true ${f(m.partner.skill)}</span>
          </div>
          <span class="vs">VS</span>
          <div class="team b">
            <span class="who">Opponents</span>
            <span class="lvl num">true ${f(m.opp1.skill)} &amp; ${f(m.opp2.skill)}</span>
          </div>
        </div>
        <div class="spread">
          <span class="scoreline">${esc(m.score)}</span>
          <span class="hint num">games ${m.gamesA}–${m.gamesB} · true chance to win ${pct(m.trueWinProb * 100)}</span>
        </div>
      </div>`;
  }

  function storyLog(s) {
    if (!s.log.length) return '';
    const rows = s.log
      .slice()
      .reverse()
      .map(
        (m) => `<tr>
          <td class="n">${m.n}</td>
          <td>${m.won ? '<span class="tag good">W</span>' : '<span class="tag crit">L</span>'}</td>
          <td class="n">${esc(m.score)}</td>
          <td class="n">${f(m.partner.skill, 1)}</td>
          <td class="n">${f(m.opp1.skill, 1)} / ${f(m.opp2.skill, 1)}</td>
          ${m.engines.map((e) => `<td class="n" style="color:${colorOf(e.key.split('#')[0])}">${f(e.rating)} <span style="opacity:.6">${signed(e.focus ? e.focus.delta : 0)}</span></td>`).join('')}
        </tr>`
      )
      .join('');
    const heads = s.log[0].engines.map((e) => `<th class="n">${esc(e.short)}</th>`).join('');
    return html`
      <details class="foldout">
        <summary>Every match so far (${s.log.length})</summary>
        <div class="tablewrap scroller">
          <table><thead><tr><th class="n">#</th><th></th><th class="n">score</th>
          <th class="n">partner</th><th class="n">opponents</th>${heads}</tr></thead>
          <tbody>${rows}</tbody></table>
        </div>
      </details>`;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // COMPARE
  // ══════════════════════════════════════════════════════════════════════════
  function compareInit() {
    $('#cm_quick').innerHTML = [1.5, 2.0, 3.5, 5.0, 6.0]
      .map((v) => `<button class="tiny" data-v="${v}">Test true ${v}</button>`)
      .join('');
    $('#cm_quick').addEventListener('click', (e) => {
      const b = e.target.closest('button');
      if (!b) return;
      $('#cm_true').value = b.dataset.v;
      $('#cm_startRating').value = '';
      compareRun();
    });
    enginePicker('cm_engines', 'compare', ['v2', 'v3', 'trueskill', 'glicko']);
    $('#cm_run').onclick = () => compareRun();
    $('#cm_smurf').onclick = () => { $('#cm_true').value = 5.5; $('#cm_startRating').value = 1.5; $('#cm_matches').value = 30; compareRun('A true 5.5 starting from 1.5 — the smurf case. Until this converges they are ruining beginners\' matches, not just carrying a wrong number.'); };
    $('#cm_over').onclick = () => { $('#cm_true').value = 1.5; $('#cm_startRating').value = 5.3; $('#cm_matches').value = 30; compareRun('A true 1.5 starting from 5.3 — the overrated case, and the risk of trusting an onboarding answer.'); };
    $('#cm_new').onclick = () => { $('#cm_startRating').value = ''; compareRun('Everyone in the app is brand new — launch week. Nobody is established, so no rating carries information yet.', 'fresh'); };
    variantsInit();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // V3 PLACEMENT TUNING
  //
  // Investigation only. Nothing here is a production proposal, and no variant
  // is preferred by the code — the tables decide.
  // ══════════════════════════════════════════════════════════════════════════
  const SWEEP_SKILLS = [0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0, 5.5, 6.0, 6.5];
  const EXTREMES = [
    ['Extreme beginner', 0.5], ['Beginner', 1.0], ['Low', 1.5],
    ['Average', 3.3], ['Strong', 5.5], ['Elite', 6.5],
  ];
  let sweepRes = null, sweepView = 'established', sweepH = 0;

  function variantsInit() {
    fillWorlds('#cm_vworld');
    enginePicker('cm_vpick', 'v3vars', V3_VARIANTS, { ids: V3_VARIANTS });
    enginePicker('cm_refs', 'v3refs', V3_REFS, { ids: V3_REFS, min: 0 });
    $('#cm_extreme').innerHTML = EXTREMES
      .map(([n, v]) => `<button class="tiny" data-v="${v}">${n} ${v}</button>`)
      .join('');
    $('#cm_extreme').addEventListener('click', (e) => {
      const b = e.target.closest('button');
      if (b) runSweep([parseFloat(b.dataset.v)]);
    });
    $('#cm_sweep').onclick = () => runSweep(SWEEP_SKILLS);
    $('#cm_mode').addEventListener('click', (e) => {
      const b = e.target.closest('.chip');
      if (!b) return;
      const variants = b.dataset.mode === 'variants';
      [...$('#cm_mode').children].forEach((c) => c.setAttribute('aria-pressed', String(c === b)));
      $('#cm_pane_engines').hidden = variants;
      $('#cm_pane_variants').hidden = !variants;
      $('#cm_out').innerHTML = variants
        ? '<div class="empty">Press <strong>Run skill sweep</strong>, or a single-skill shortcut.</div>'
        : '<div class="empty">Press <strong>Run</strong>.</div>';
    });
  }

  function variantSpecs() {
    return [...specsFor('v3vars'), ...specsFor('v3refs')];
  }

  function runSweep(skills) {
    const engines = variantSpecs();
    const reps = parseInt($('#cm_vreps').value, 10) || 50;
    const horizons = $('#cm_horizon').value.split(',').map((v) => parseInt(v, 10));
    const single = skills.length === 1;
    $('#cm_out').innerHTML = `<div class="empty busy">Running ${skills.length} skill${skills.length > 1 ? 's' : ''}
      × ${reps} seeds × ${horizons[horizons.length - 1]} matches × ${engines.length} engines,
      twice (established, then brand new)…</div>`;
    setTimeout(() => {
      const args = { seed: seed(), reps, horizons, engines, skills, world: $('#cm_vworld').value };
      sweepRes = {
        established: call('v3.sweep', { ...args, pool: 'established' }),
        fresh: call('v3.sweep', { ...args, pool: 'fresh' }),
        single,
      };
      sweepH = 0;
      paintSweep();
    }, 20);
  }

  function paintSweep() {
    const res = sweepRes[sweepView];
    const other = sweepView === 'established' ? 'fresh' : 'established';
    $('#cm_out').innerHTML = html`
      <div class="card">
        <div class="chips seg" id="cm_surr">
          <button class="chip" data-view="established" aria-pressed="${sweepView === 'established'}">
            Established surroundings</button>
          <button class="chip" data-view="fresh" aria-pressed="${sweepView === 'fresh'}">
            Everyone brand new</button>
        </div>
        <p class="hint" style="margin:8px 0 0">${sweepView === 'established'
          ? 'Everyone except the player being measured is pinned at their true level. The cleanest possible read on placement: the only unknown in the match is the focus player.'
          : 'Nobody is rated yet — this is the app as it stands today. Every rating in the match is a guess, so a correction can be made against a wrong reference.'}
        Switch to <strong>${other === 'fresh' ? 'brand new' : 'established'}</strong> and check the story survives.</p>
      </div>
      ${sweepRes.single ? singleSkillCards(res) : sweepCards(res)}`;
    $('#cm_surr').addEventListener('click', (e) => {
      const b = e.target.closest('.chip');
      if (!b) return;
      sweepView = b.dataset.view;
      paintSweep();
    });
    const hsel = $('#cm_hsel');
    if (hsel) hsel.addEventListener('click', (e) => {
      const b = e.target.closest('.chip');
      if (!b) return;
      sweepH = parseInt(b.dataset.h, 10);
      paintSweep();
    });
  }

  // ── shared little formatters ──────────────────────────────────────────────
  // fraction (0…1) → percent. `pct` at the top takes an ALREADY-scaled number.
  const pc = (v, dp = 0) => (v === null || v === undefined ? '—' : `${(v * 100).toFixed(dp)}%`);
  const rowOf = (res, skill, id) =>
    res.rows.find((r) => r.trueSkill === skill && r.id === id);
  const atOf = (res, skill, id) => rowOf(res, skill, id).at[sweepH];
  const sumOf = (res, id) => res.summary.find((s) => s.id === id);
  // Recovery is signed: negative means it moved AWAY from the truth.
  const recClass = (v) => (v === null ? '' : v >= 0.75 ? 'good' : v >= 0.5 ? 'warn' : 'crit');

  function horizonPicker(res) {
    if (res.horizons.length < 2) return '';
    return `<div class="chips seg" id="cm_hsel" style="max-width:420px">
      ${res.horizons.map((h, i) => `<button class="chip" data-h="${i}"
        aria-pressed="${i === sweepH}">after ${h}</button>`).join('')}</div>`;
  }

  function singleSkillCards(res) {
    const skill = res.skills[0];
    const ctx = res.context[0];
    const cards = res.engines
      .map((e) => {
        const r = rowOf(res, skill, e.id);
        const a = r.at[sweepH];
        const conf = a.confidenceError;
        const wrong = a.confWrong;
        return `<div class="card stack">
          <header><h3 style="color:${colorOf(e.id)};margin:0">${esc(e.label)}</h3>
            <span class="grow"></span>
            ${wrong > 0.25 ? `<span class="tag crit" title="In ${pc(wrong)} of seeds the engine's own sigma says the truth is more than 3 sigma away. Development diagnostic only.">confidently wrong ${pc(wrong)}</span>` : ''}
          </header>
          <div class="bignum" style="color:${colorOf(e.id)}">${f(r.start)} → ${f(a.mean)}</div>
          <table><tbody>
            <tr><th>Movement</th><td class="n">${signed(a.movement)}</td></tr>
            <tr><th>Required</th><td class="n">${signed(a.required)}</td></tr>
            <tr><th>Recovered</th><td class="n"><span class="tag ${recClass(a.recovered)}">${pc(a.recovered)}</span></td></tr>
            <tr><th>Error vs true ${f(skill, 1)}</th><td class="n"><span class="tag ${errClass(a.error)}">${signed(a.error)}</span></td></tr>
            <tr><th>Final sigma</th><td class="n">${f(a.sigma)}</td></tr>
            <tr><th>Error ÷ sigma</th><td class="n">${f(conf)}</td></tr>
            <tr><th>Confidence state</th><td class="n">${a.shown >= 0.5
              ? `<span class="tag info">shown to players (${pc(a.shown)})</span>`
              : `<span class="tag quiet">still provisional (${pc(1 - a.shown)})</span>`}</td></tr>
            <tr><th>Within ±0.5</th><td class="n">${pc(a.within50)}</td></tr>
            <tr><th>Median (p10–p90)</th><td class="n">${f(a.median)}
              <span class="sub">${f(a.p10)} – ${f(a.p90)}</span></td></tr>
            <tr><th>Matches to halve the error</th><td class="n">${r.half50 === null ? '—' : f(r.half50, 0)}</td></tr>
          </tbody></table>
        </div>`;
      })
      .join('');

    return html`
      <div class="card stack">
        <header><h2>True ${f(skill, 1)} · ${res.reps} seeds${res.horizons.length > 1 ? ` · after ${res.horizons[sweepH]} matches` : ''}</h2></header>
        ${horizonPicker(res)}
        <p class="hint">Every engine played the same ${res.reps} careers.
        <strong>Recovered</strong> is how much of the distance from its own starting
        point to the truth the engine actually travelled.</p>
        ${matchContextTable([ctx])}
      </div>
      <div class="gridpair">${cards}</div>`;
  }

  function sweepCards(res) {
    const E = res.engines;
    const S = res.skills;
    const head = E.map((e) => `<th class="n" style="color:${colorOf(e.id)}">${esc(e.short)}</th>`).join('');
    const headWide = E.map((e) => `<th class="n" colspan="2" style="color:${colorOf(e.id)}">${esc(e.short)}</th>`).join('');

    // ── 1. summary strip ──
    const summary = E.map((e) => {
      const s = sumOf(res, e.id), a = s.at[sweepH];
      return `<tr>
        <th style="color:${colorOf(e.id)}">${esc(e.short)}</th>
        <td class="n">${f(s.start)}</td>
        <td class="n">${f(a.mae)}</td>
        <td class="n"><span class="tag ${errClass(a.bias)}">${signed(a.bias)}</span></td>
        <td class="n">${f(a.biasSlope)}</td>
        <td class="n">${pc(a.spreadRecovery)}</td>
        <td class="n">${pc(a.within50)}</td>
        <td class="n"><span class="tag ${recClass(a.downRecovery)}">${pc(a.downRecovery)}</span></td>
        <td class="n"><span class="tag ${recClass(a.upRecovery)}">${pc(a.upRecovery)}</span></td>
        <td class="n">${a.asymmetry === null ? '—' : `${(a.asymmetry * 100).toFixed(0)} pp`}</td>
        <td class="n">${pc(a.confWrong)}</td>
        <td class="n">${f(s.brier, 3)}</td>
      </tr>`;
    }).join('');

    // ── 2. rating + error by skill ──
    const mainRows = S.map((sk) => {
      const cells = E.map((e) => {
        const a = atOf(res, sk, e.id);
        return `<td class="n"><strong style="color:${colorOf(e.id)}">${f(a.mean)}</strong></td>
                <td class="n"><span class="tag ${errClass(a.error)}">${signed(a.error)}</span></td>`;
      }).join('');
      return `<tr><th>${f(sk, 1)}</th>${cells}</tr>`;
    }).join('');

    // ── 3. distance recovered ──
    const recRows = S.map((sk) => {
      const cells = E.map((e) => {
        const a = atOf(res, sk, e.id);
        return `<td class="n">${a.recovered === null
          ? '<span class="sub">at prior</span>'
          : `<span class="tag ${recClass(a.recovered)}">${pc(a.recovered)}</span>
             <span class="sub">${signed(a.movement)} of ${signed(a.required)}</span>`}</td>`;
      }).join('');
      return `<tr><th>${f(sk, 1)}</th>${cells}</tr>`;
    }).join('');

    // ── charts ──
    const xTicks = S.map((v) => f(v, 1));
    const biasSeries = E.map((e) => ({
      name: e.short, color: colorOf(e.id),
      dashed: V3_REFS.includes(e.id),
      ys: S.map((sk) => atOf(res, sk, e.id).error),
    }));
    const estSeries = [
      { name: 'perfect', color: 'var(--truth)', dashed: true, ys: S.slice() },
      ...E.map((e) => ({
        name: e.short, color: colorOf(e.id),
        dashed: V3_REFS.includes(e.id),
        ys: S.map((sk) => atOf(res, sk, e.id).mean),
      })),
    ];

    // ── tolerance + percentiles ──
    const tolRows = S.map((sk) => {
      const cells = E.map((e) => {
        const a = atOf(res, sk, e.id);
        return `<td class="n">${pc(a.within50)}<span class="sub">${pc(a.within25)} · ${pc(a.within100)}</span></td>`;
      }).join('');
      return `<tr><th>${f(sk, 1)}</th>${cells}</tr>`;
    }).join('');

    const pctTables = E.map((e) => `<div class="tablewrap">
      <h4 style="color:${colorOf(e.id)}">${esc(e.label)}</h4>
      <table><thead><tr><th>true</th><th class="n">p10</th><th class="n">p25</th>
      <th class="n">median</th><th class="n">p75</th><th class="n">p90</th>
      <th class="n">spread</th></tr></thead><tbody>
      ${S.map((sk) => {
        const a = atOf(res, sk, e.id);
        return `<tr><th>${f(sk, 1)}</th><td class="n">${f(a.p10)}</td><td class="n">${f(a.p25)}</td>
          <td class="n"><strong>${f(a.median)}</strong></td><td class="n">${f(a.p75)}</td>
          <td class="n">${f(a.p90)}</td><td class="n">${f(a.p90 - a.p10)}</td></tr>`;
      }).join('')}</tbody></table></div>`).join('');

    // ── horizons ──
    const horizonBlock = res.horizons.length < 2 ? '' : `
      <div class="card stack">
        <header><h2>Does it fix itself later?</h2></header>
        <div class="tablewrap">
          <table><thead><tr><th>true</th>${E.map((e) =>
            `<th class="n" colspan="${res.horizons.length}" style="color:${colorOf(e.id)}">${esc(e.short)}</th>`).join('')}</tr>
          <tr><th></th>${E.map(() => res.horizons.map((h) => `<th class="n">@${h}</th>`).join('')).join('')}</tr></thead>
          <tbody>${S.map((sk) => `<tr><th>${f(sk, 1)}</th>${E.map((e) => {
            const r = rowOf(res, sk, e.id);
            return r.at.map((a) => `<td class="n">${f(a.mean)}<span class="sub">${signed(a.error)}</span></td>`).join('');
          }).join('')}</tr>`).join('')}</tbody></table>
        </div>
        <p class="hint">If the error at 20 and 50 is not much better than at 10, the problem is
        not “placement is temporarily wrong” — the engine has settled on a wrong answer.</p>
      </div>`;

    // ── half-life, overshoot, stability ──
    const hlRows = S.map((sk) => {
      const cells = E.map((e) => {
        const r = rowOf(res, sk, e.id);
        return `<td class="n">${r.half50 === null ? '—' : f(r.half50, 0)}
          <span class="sub">${r.half75 === null ? '—' : f(r.half75, 0)}${r.never75 > 0.02 ? ` · ${pc(r.never75)} never` : ''}</span></td>`;
      }).join('');
      return `<tr><th>${f(sk, 1)}</th>${cells}</tr>`;
    }).join('');

    const stabRows = E.map((e) => {
      const s = sumOf(res, e.id), a = s.at[sweepH];
      return `<tr><th style="color:${colorOf(e.id)}">${esc(e.short)}</th>
        <td class="n">${f(s.overshoot)}</td>
        <td class="n">${pc(s.overshootPct)}</td>
        <td class="n">${s.wobble === null ? '—' : f(s.wobble)}</td>
        <td class="n">${s.drift === null ? '—' : signed(s.drift)}</td>
        <td class="n">${pc(a.confWrong)}</td>
        <td class="n">${f(s.brier, 3)}</td></tr>`;
    }).join('');

    // ── matched-distance asymmetry: the only fair up-vs-down comparison ──
    const pairRows = E.map((e) => {
      const a = sumOf(res, e.id).at[sweepH];
      if (!a.pairs || !a.pairs.length) return '';
      const cells = a.pairs.map((p) => `<td class="n">
        <span class="tag ${recClass(p.downRecovered)}">${pc(p.downRecovered)}</span>
        <span class="sub">vs ${pc(p.upRecovered)} up</span></td>`).join('');
      return `<tr><th style="color:${colorOf(e.id)}">${esc(e.short)}</th>${cells}</tr>`;
    }).join('');
    const pairHead = (sumOf(res, E[0].id).at[sweepH].pairs || [])
      .map((p) => `<th class="n">${f(p.distance, 1)}<span class="sub">${f(p.downSkill, 1)} vs ${f(p.upSkill, 1)}</span></th>`)
      .join('');

    // In a cold pool the whole population is unrated AND every match is played
    // against neighbours, so there is nothing to measure anyone against. That
    // is a property of the situation, not of a variant — say so, or the row of
    // zeros reads as a broken run.
    const degenerate = res.pool === 'fresh' &&
      res.summary.every((s) => Math.abs(s.at[sweepH].spreadRecovery) < 0.1);

    return html`
      ${degenerate ? `<div class="card stack">
        <header><h2>Nothing moved — and that is the finding</h2></header>
        <p>Every engine, including TrueSkill and Glicko-2, left every player within a
        few hundredths of the prior. Spread kept is about 1% and recovery is roughly zero
        in both directions.</p>
        <p class="hint">This is not a tuning failure. When nobody in the pool is rated and
        everybody plays neighbours of their own standard, a true 0.5 player and a true 6.5
        player produce <strong>identical evidence</strong> — each wins about half against
        people like themselves. No amount of K or sigma can separate two worlds that look
        the same from the inside. Fixing cold start needs an external reference: seeded
        anchor players, or matches that cross levels. Compare with
        <strong>Established surroundings</strong>, where opponents carry known levels and
        the same engines recover 50–80%.</p>
      </div>` : ''}
      <div class="card stack">
        <header><h2>Every variant, scored</h2>
          <span class="grow"></span>
          <span class="tag quiet">${res.reps} seeds · ${res.skills.length} skills</span>
        </header>
        ${horizonPicker(res)}
        <div class="tablewrap">
          <table><thead><tr><th>engine</th><th class="n">start</th><th class="n">MAE</th>
          <th class="n">bias</th><th class="n">slope</th><th class="n">spread kept</th>
          <th class="n">within ±0.5</th><th class="n">down</th><th class="n">up</th>
          <th class="n">asym</th><th class="n">conf. wrong</th><th class="n">Brier</th></tr></thead>
          <tbody>${summary}</tbody></table>
        </div>
        <p class="hint"><strong>slope</strong> is how the error changes per level of true skill:
        0 is flat, negative means still compressing toward the middle.
        <strong>spread kept</strong> is how much of the population's real spread survives —
        100% would mean the ratings are as spread out as the players.
        <strong>down / up</strong> are the average share of the needed distance recovered
        below and above that engine's own starting point, and <strong>asym</strong> is
        up minus down. <strong>conf. wrong</strong> is the share of runs where the truth
        sits more than 3 of the engine's own sigmas away — a development flag, not a
        production metric.</p>
      </div>

      <div class="card stack">
        <header><h2>Rating after ${res.horizons[sweepH]} matches</h2></header>
        <div class="tablewrap">
          <table><thead>
            <tr><th rowspan="2">true skill</th>${headWide}</tr>
            <tr>${E.map(() => '<th class="n">rating</th><th class="n">error</th>').join('')}</tr>
          </thead><tbody>${mainRows}</tbody></table>
        </div>
      </div>

      <div class="card stack">
        <header><h2>Bias by skill</h2></header>
        <div class="chartbox">
          ${lineChart({
            series: biasSeries, xTicks, ref: 0, refLabel: 'no bias',
            yDp: 2, height: 300, xLabel: 'true skill', aria: 'final rating error against true skill',
          })}
          <figcaption>Error = rating − true skill. Positive on the left means beginners are
          overrated; negative on the right means strong players are underrated. A line sloping
          down from left to right is still compressing everyone toward the middle.</figcaption>
        </div>
        ${legendFor(E.map((e) => ({ name: e.label, color: colorOf(e.id) })))}
      </div>

      <div class="card stack">
        <header><h2>Estimated against true</h2></header>
        <div class="chartbox">
          ${lineChart({
            series: estSeries, xTicks, yMin: 0, yMax: 7, yDp: 1, height: 320,
            xLabel: 'true skill', aria: 'average estimated rating against true skill',
          })}
          <figcaption>The dashed ochre line is a perfect engine. A flatter line is a more
          compressed engine — it is giving different players the same rating.</figcaption>
        </div>
      </div>

      <div class="card stack">
        <header><h2>Placement distance recovered</h2></header>
        <div class="tablewrap">
          <table><thead><tr><th>true skill</th>${head}</tr></thead><tbody>${recRows}</tbody></table>
        </div>
        <p class="hint">Share of the journey from the engine's own starting point to the truth
        that actually happened, with the movement and the requirement underneath. Rows near an
        engine's prior have nowhere to travel and are marked “at prior”.</p>
      </div>

      ${pairRows.replace(/\s/g, '') === '' ? '' : `<div class="card stack">
        <header><h2>Is it worse at going down than going up?</h2></header>
        <div class="tablewrap">
          <table><thead><tr><th>distance needed<span class="sub">down vs up skill</span></th>${pairHead}</tr></thead>
          <tbody>${pairRows}</tbody></table>
        </div>
        <p class="hint">Each column pairs a player who must come <strong>down</strong> with one
        who must go <strong>up</strong> by about the same distance, so the only difference left
        is the direction. The big figure is the downward recovery, and beside it the upward one
        at the same distance. Equal numbers mean placement is simply too slow in general; a
        persistent gap means the engine corrects one direction better than the other.</p>
        <p class="hint"><strong>Check the win rate before believing a gap.</strong> Look at
        “actually won” below: if the focus team wins more than half its matches at every skill,
        that standing tailwind is added to the upward evidence and subtracted from the downward
        evidence, and an asymmetry will appear that belongs to the doubles model rather than to
        the engine. Re-run under the <strong>pure average, no carry</strong> world to separate
        the two.</p>
      </div>`}

      <div class="card stack">
        <header><h2>Within tolerance</h2></header>
        <div class="tablewrap">
          <table><thead><tr><th>true skill</th>${head}</tr></thead><tbody>${tolRows}</tbody></table>
        </div>
        <p class="hint">Large figure is the share of seeds within <strong>±0.5</strong> of the
        truth; underneath, ±0.25 and ±1.0. Easier to act on than an average error: ±0.25 is one
        display step.</p>
      </div>

      <div class="card stack">
        <header><h2>Correction half-life</h2></header>
        <div class="tablewrap">
          <table><thead><tr><th>true skill</th>${head}</tr></thead><tbody>${hlRows}</tbody></table>
        </div>
        <p class="hint">Matches needed to remove half the starting error, and underneath to
        remove three quarters. Only counted for seeds that started at least 0.5 away — a player
        seeded near their true level has no error to halve.</p>
      </div>

      <div class="card stack">
        <header><h2>Overshoot, stability and confidence</h2></header>
        <div class="tablewrap">
          <table><thead><tr><th>engine</th><th class="n">avg overshoot</th>
          <th class="n">past truth by 0.5+</th><th class="n">wobble after 10</th>
          <th class="n">drift 10 → last</th><th class="n">conf. wrong</th>
          <th class="n">Brier</th></tr></thead><tbody>${stabRows}</tbody></table>
        </div>
        <p class="hint">A variant that corrects faster must not sail past the truth.
        <strong>Overshoot</strong> is how far beyond the true skill the rating travelled in the
        direction it was moving. <strong>Wobble</strong> and <strong>drift</strong> need the
        20- or 50-match horizon to mean anything.</p>
      </div>

      ${horizonBlock}

      <div class="card stack">
        <header><h2>What the engine expected against what happened</h2></header>
        <div class="tablewrap">
          <table><thead><tr><th>true skill</th><th class="n">actually won</th>${head}</tr></thead>
          <tbody>${S.map((sk, i) => {
            const c = res.context[i];
            const actual = c.wins / Math.max(1, c.wins + c.losses);
            return `<tr><th>${f(sk, 1)}</th><td class="n">${pc(actual)}</td>${E.map((e) => {
              const r = rowOf(res, sk, e.id);
              return `<td class="n">${pc(r.expected)}<span class="sub">${signed(actual - r.expected, 2)}</span></td>`;
            }).join('')}</tr>`;
          }).join('')}</tbody></table>
        </div>
        <p class="hint">The engine's average predicted win chance for the focus team over the
        first 10 matches, with the gap to what actually happened underneath. <strong>That gap
        is the fuel</strong> — it is what every rating move is computed from. A row where the
        gap is small has little to push against no matter how large K is, which is why the same
        distance is not equally easy to travel in both directions.</p>
      </div>

      <div class="card stack">
        <header><h2>What the matches actually were</h2></header>
        ${matchContextTable(res.context)}
        <p class="hint">This is doubles: a weak player with a strong partner can legitimately
        win. Before blaming the engine, check the record and the company. Averages over the
        first 10 matches.</p>
      </div>

      <details class="foldout">
        <summary>Percentiles — the lucky and unlucky tails</summary>
        <div class="gridpair">${pctTables}</div>
      </details>`;
  }

  function matchContextTable(ctx) {
    return `<div class="tablewrap">
      <table><thead><tr><th>true skill</th><th class="n">avg record (10)</th>
      <th class="n">partner</th><th class="n">opp 1</th><th class="n">opp 2</th>
      <th class="n">own team</th><th class="n">opp team</th></tr></thead>
      <tbody>${ctx.map((c) => `<tr><th>${f(c.trueSkill, 1)}</th>
        <td class="n">${f(c.wins, 1)} W / ${f(c.losses, 1)} L</td>
        <td class="n">${f(c.partner)}</td><td class="n">${f(c.opp1)}</td>
        <td class="n">${f(c.opp2)}</td><td class="n">${f(c.teamStrength)}</td>
        <td class="n">${f(c.oppStrength)}</td></tr>`).join('')}</tbody></table>
      </div>`;
  }

  function compareRun(note, pool) {
    const trueSkill = parseFloat($('#cm_true').value);
    const matches = parseInt($('#cm_matches').value, 10);
    const reps = parseInt($('#cm_reps').value, 10) || 1;
    const startRating = $('#cm_startRating').value.trim();
    const engines = specsFor('compare').map((s) => (startRating ? { ...s, startRating: parseFloat(startRating) } : s));

    const res = call('solo.average', {
      seed: seed(), trueSkill, matches, reps, engines,
      pool: pool || 'established',
    });

    const marks = [0, 1, 2, 3, 5, 10, 20, 30, 50].filter((k) => k <= matches);
    const rows = res.series
      .map((s) => {
        const cells = marks.map((k) => `<td class="n">${f(s.ratings[k])}</td>`).join('');
        return `<tr><th style="color:${colorOf(s.id)}">${esc(s.short)}</th>${cells}
          <td class="n"><span class="tag ${errClass(s.error)}">${signed(s.error)}</span></td></tr>`;
      })
      .join('');

    const best = res.series.reduce((a, b) => (Math.abs(a.error) <= Math.abs(b.error) ? a : b));

    $('#cm_out').innerHTML = html`
      ${note ? `<div class="card"><p class="hint">${esc(note)}</p></div>` : ''}
      <div class="card stack">
        <header><h2>True ${f(trueSkill, 1)} after ${matches} matches</h2>
          <span class="grow"></span>
          <span class="tag quiet">${reps} seed${reps > 1 ? 's' : ''} averaged</span>
          <span class="tag info">closest: ${esc(best.short)} (${signed(best.error)})</span>
        </header>
        <div class="kpis">
          ${res.series
            .map(
              (s) => `<div class="kpi ${errClass(s.error)}">
                <span class="k">${esc(s.short)}</span>
                <span class="v">${f(s.final)}</span>
                <span class="n">error ${signed(s.error)}${reps > 1 ? ` · spread ±${f(s.finalSd)}` : ''}</span>
              </div>`
            )
            .join('')}
        </div>
        <div class="chartbox">
          ${lineChart({
            series: res.series.map((s) => ({ name: s.short, color: colorOf(s.id), ys: s.ratings })),
            ref: trueSkill, refLabel: 'true skill ' + f(trueSkill, 1),
            yMin: 0, yMax: 7, yDp: 1, xLabel: 'matches played',
          })}
          <figcaption>Mean rating across ${reps} seed${reps > 1 ? 's' : ''}. The dashed ochre line is
          where a perfect engine would land.</figcaption>
        </div>
        ${legendFor(res.series.map((s) => ({ name: s.label, color: colorOf(s.id) })))}
      </div>
      <div class="card stack">
        <header><h2>Rating after N matches</h2></header>
        <div class="tablewrap">
          <table><thead><tr><th>engine</th>${marks.map((k) => `<th class="n">${k === 0 ? 'start' : k}</th>`).join('')}<th class="n">final error</th></tr></thead>
          <tbody>${rows}</tbody></table>
        </div>
      </div>
      <div class="card stack">
        <header><h2>How far off, match by match</h2></header>
        <div class="chartbox">
          ${lineChart({
            series: res.series.map((s) => ({ name: s.short, color: colorOf(s.id), ys: s.absError })),
            yMin: 0, yDp: 2, xLabel: 'matches played',
          })}
          <figcaption>Mean absolute error in levels — lower is better. A line that flattens above
          zero has stopped learning while still being wrong.</figcaption>
        </div>
      </div>`;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // POPULATION
  // ══════════════════════════════════════════════════════════════════════════
  let popRes = null, popAt = 10, popKey = null;

  function populationInit() {
    fillWorlds('#pp_world');
    enginePicker('pp_engines', 'pop', ['v2', 'v3']);
    $('#pp_run').onclick = populationRun;
  }

  function populationRun() {
    const players = parseInt($('#pp_players').value, 10);
    const matches = parseInt($('#pp_matches').value, 10);
    $('#pp_out').innerHTML = '<div class="empty busy">Running…</div>';
    setTimeout(() => {
      popRes = call('population.run', {
        seed: seed(), players, matches,
        dist: $('#pp_dist').value,
        world: $('#pp_world').value,
        engines: specsFor('pop'),
      });
      popCache = {};
      popAt = Math.min(10, matches);
      popKey = popRes.engines[popRes.engines.length - 1].key;
      renderPopulation();
    }, 10);
  }

  /// Metrics are computed at the EXACT match count the slider is on, not the
  /// nearest pre-baked snapshot — otherwise dragging the slider would quietly
  /// show numbers from a different point in the run.
  let popCache = {};
  const stateAt = (key, at) => {
    const ck = key + '@' + at;
    return (popCache[ck] = popCache[ck] || call('population.at', { at, key }));
  };

  function renderPopulation() {
    const r = popRes;
    const maxAt = r.rounds;
    const idOf = (key) => key.split('#')[0];

    const kpi = r.engines
      .map((e) => {
        const s = stateAt(e.key, popAt).metrics;
        return html`
          <div class="card stack" style="border-left:3px solid ${colorOf(e.id)}">
            <header><h3 style="color:${colorOf(e.id)}">${esc(e.label)}</h3></header>
            <div class="kpis">
              <div class="kpi ${s.mae <= 0.5 ? 'good' : s.mae <= 0.9 ? 'warn' : 'crit'}">
                <span class="k">avg error</span><span class="v">${f(s.mae)}</span>
                <span class="n">levels off the truth</span></div>
              <div class="kpi ${s.spreadRecovery >= 0.7 ? 'good' : s.spreadRecovery >= 0.45 ? 'warn' : 'crit'}">
                <span class="k">spread kept</span><span class="v">${pc(s.spreadRecovery * 100)}</span>
                <span class="n">100% = as spread out as real skill</span></div>
              <div class="kpi ${s.pctStrongStuckLow <= 15 ? 'good' : s.pctStrongStuckLow <= 40 ? 'warn' : 'crit'}">
                <span class="k">5.0+ stuck low</span><span class="v">${pc(s.pctStrongStuckLow)}</span>
                <span class="n">strong players shown under 3.5</span></div>
              <div class="kpi ${s.pctWeakStuckHigh <= 15 ? 'good' : s.pctWeakStuckHigh <= 40 ? 'warn' : 'crit'}">
                <span class="k">weak stuck high</span><span class="v">${pc(s.pctWeakStuckHigh)}</span>
                <span class="n">true ≤2.0 shown over 3.0</span></div>
              <div class="kpi"><span class="k">order (ρ)</span><span class="v">${f(s.spearman)}</span>
                <span class="n">1.0 = perfect ranking order</span></div>
              <div class="kpi"><span class="k">bias</span><span class="v">${signed(s.bias)}</span>
                <span class="n">whole population shifted by</span></div>
            </div>
          </div>`;
      })
      .join('');

    const bands = ['1–2', '2–3', '3–4', '4–5', '5–6', '6–7'];
    const bandRows = r.engines
      .map((e) => {
        const s = stateAt(e.key, popAt).metrics;
        return `<tr><th style="color:${colorOf(e.id)}">${esc(e.short)}</th>${bands
          .map((b) => `<td class="n">${s.meanEstByBand && s.meanEstByBand[b] !== undefined ? f(s.meanEstByBand[b]) : '—'}</td>`)
          .join('')}</tr>`;
      })
      .join('');

    $('#pp_out').innerHTML = html`
      <div class="card stack">
        <header>
          <h2>State after ${popAt} match${popAt === 1 ? '' : 'es'}</h2>
          <span class="grow"></span>
          <span class="tag quiet">${r.players} players · true mean ${f(r.trueMean)} · true spread ${f(r.trueSd)}</span>
        </header>
        <label class="field"><span>Show the league after N matches</span>
          <input type="range" id="pp_slider" min="1" max="${maxAt}" value="${popAt}" /></label>
      </div>
      <div class="stack">${kpi}</div>
      <div class="card stack">
        <header><h2>Average rating given to each true-level band</h2></header>
        <p class="hint">Read across a row. The numbers should climb <strong>in step with the
        headings</strong>. A flat row means the engine is handing everyone the same rating.</p>
        <div class="tablewrap">
          <table><thead><tr><th>engine</th>${bands.map((b) => `<th class="n">true ${b}</th>`).join('')}</tr></thead>
          <tbody>${bandRows}</tbody></table>
        </div>
      </div>
      <div class="card stack">
        <header><h2>Every player, plotted</h2>
          <span class="grow"></span>
          <select id="pp_which">${r.engines.map((e) => `<option value="${e.key}" ${e.key === popKey ? 'selected' : ''}>${esc(e.label)}</option>`).join('')}</select>
        </header>
        <div class="duo" id="pp_plots"></div>
      </div>
      <div class="card stack">
        <header><h2>Probability calibration</h2></header>
        <p class="hint">When an engine says the favourite has a 70% chance, do they win 70% of the
        time? On the line is honest; below it is over-confident. Scored over the
        <strong>second half</strong> of the run, where the ratings are the engine's work rather
        than the prior's.</p>
        <div class="duo">
          <div class="chartbox">${calibChart(r.snapshots.map((s) => ({ color: colorOf(idOf(s.key)), bins: s.calibration.bins })))}</div>
          <div class="tablewrap"><table>
            <thead><tr><th>engine</th><th class="n">calib. error</th><th class="n">Brier</th><th class="n">log loss</th><th class="n">picked winner</th></tr></thead>
            <tbody>${r.snapshots
              .map((s) => {
                const e = r.engines.find((x) => x.key === s.key);
                return `<tr><th style="color:${colorOf(e.id)}">${esc(e.short)}</th>
                  <td class="n">${pc(s.calibration.ece * 100, 1)}</td>
                  <td class="n">${f(s.calibration.brier, 3)}</td>
                  <td class="n">${f(s.calibration.logLoss, 3)}</td>
                  <td class="n">${pc(s.calibration.accuracy * 100, 1)}</td></tr>`;
              })
              .join('')}</tbody></table></div>
        </div>
      </div>
      <div class="card stack">
        <header><h2>Individual players, not averages</h2>
          <span class="grow"></span>
          <select id="pp_sort">
            <option value="worst">Worst-rated</option>
            <option value="under">Most under-rated</option>
            <option value="over">Most over-rated</option>
            <option value="strong">Strongest players</option>
            <option value="weak">Weakest players</option>
          </select>
        </header>
        <div id="pp_table"></div>
        <div id="pp_player"></div>
      </div>`;

    $('#pp_slider').oninput = (e) => {
      popAt = parseInt(e.target.value, 10);
      renderPopulation();
    };
    $('#pp_which').onchange = (e) => { popKey = e.target.value; renderPlots(); };
    $('#pp_sort').onchange = renderPlayerTable;
    renderPlots();
    renderPlayerTable();
  }

  function renderPlots() {
    const d = stateAt(popKey, popAt);
    const col = colorOf(popKey.split('#')[0]);
    $('#pp_plots').innerHTML = html`
      <div class="chartbox">
        ${scatterChart({ points: d.scatter, color: col })}
        <figcaption>Each dot is a player. <strong>Hug the diagonal</strong> = healthy. A flat
        horizontal smear means the rating barely responds to real skill.</figcaption>
      </div>
      <div class="chartbox">
        ${histChart({ truth: d.histTrue, est: d.histEst, color: col })}
        <figcaption>Filled bars are engine ratings; the dashed ochre outline is real skill.
        Estimated spread ${f(d.estSd)} against a true spread of ${f(d.trueSd)}.</figcaption>
      </div>`;
  }

  function renderPlayerTable() {
    const sort = $('#pp_sort').value;
    const d = call('population.players', { at: popAt, key: popKey, sort, limit: 20 });
    const engines = popRes.engines;
    $('#pp_table').innerHTML = html`
      <div class="tablewrap scroller">
        <table><thead><tr><th class="n">#</th><th class="n">true skill</th>
        ${engines.map((e) => `<th class="n" style="color:${colorOf(e.id)}">${esc(e.short)}</th>`).join('')}
        </tr></thead><tbody>
        ${d.rows
          .map(
            (r) => `<tr class="clickable" data-id="${r.id}">
              <td class="n">${r.id}</td>
              <td class="n" style="color:var(--truth);font-weight:700">${f(r.trueSkill)}</td>
              ${r.engines.map((e) => `<td class="n"><span class="tag ${errClass(e.error)}">${f(e.rating)}</span></td>`).join('')}
            </tr>`
          )
          .join('')}
        </tbody></table>
      </div>`;
    $('#pp_table').onclick = (ev) => {
      const tr = ev.target.closest('tr[data-id]');
      if (!tr) return;
      $$('#pp_table tr').forEach((x) => x.classList.remove('sel'));
      tr.classList.add('sel');
      renderPlayerCard(parseInt(tr.dataset.id, 10));
    };
    if (d.rows.length) renderPlayerCard(d.rows[0].id);
  }

  function renderPlayerCard(id) {
    const p = call('population.player', { id });
    $('#pp_player').innerHTML = html`
      <div class="stack" style="margin-top:12px">
        <div class="spread">
          <h3>Player #${p.id} · true skill ${f(p.trueSkill)}</h3>
          <span class="tag truth">ground truth ${f(p.trueSkill)}</span>
        </div>
        <div class="kpis">
          ${p.engines
            .map(
              (e) => `<div class="kpi ${errClass(e.error)}">
                <span class="k">${esc(e.short)}</span>
                <span class="v">${f(e.final)}</span>
                <span class="n">error ${signed(e.error)} · sigma ${f(e.sigma[e.sigma.length - 1])}<br>
                ${e.wins}W ${e.losses}L · ${e.partners} partners · ${e.displayReady ? 'shown as ' + f(e.publicRating, 2) : 'still unranked'}</span>
              </div>`
            )
            .join('')}
        </div>
        <div class="duo">
          <div class="chartbox">
            ${lineChart({
              series: p.engines.map((e) => ({ name: e.short, color: colorOf(e.key.split('#')[0]), ys: e.rating })),
              ref: p.trueSkill, refLabel: 'true ' + f(p.trueSkill), yMin: 0, yMax: 7, yDp: 1, height: 220,
            })}
            <figcaption>Rating over the run.</figcaption>
          </div>
          <div class="chartbox">
            ${lineChart({
              series: p.engines.map((e) => ({ name: e.short, color: colorOf(e.key.split('#')[0]), ys: e.sigma })),
              yMin: 0, yDp: 2, height: 220,
            })}
            <figcaption>Uncertainty (sigma). Falling means the engine is getting more confident —
            check that it earned it.</figcaption>
          </div>
        </div>
      </div>`;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // DOUBLES
  // ══════════════════════════════════════════════════════════════════════════
  function doublesInit() {
    const paint = () => {
      const lam = parseFloat($('#db_lambda').value);
      $('#db_lamlabel').textContent = 'λ = ' + f(lam, 2);
      const d = call('doubles.pairs', { lambda: lam, seed: seed() });
      const rows = d.rows
        .map((r) => {
          const models = r.models;
          return `<tr>
            <td class="n">${f(r.pair[0], 1)} + ${f(r.pair[1], 1)}</td>
            <td class="n">${f(r.pair[2], 1)} + ${f(r.pair[3], 1)}</td>
            <td class="n" style="color:var(--truth);font-weight:700">${pc(r.trueWinPct, 1)}</td>
            <td class="n">${signed(models.avg.diff)}</td>
            <td class="n"><strong>${signed(models.lambda.diff)}</strong></td>
            <td class="n">${signed(models.weakLink.diff)}</td>
            <td class="n">${signed(models.carry.diff)}</td>
          </tr>`;
        })
        .join('');
      $('#db_out').innerHTML = html`
        <div class="tablewrap">
          <table><thead><tr><th class="n">team A</th><th class="n">team B</th>
          <th class="n">A really wins</th><th class="n">plain average</th><th class="n">avg − λ·gap</th>
          <th class="n">weak link</th><th class="n">carry</th></tr></thead>
          <tbody>${rows}</tbody></table>
        </div>
        <p class="hint">Compare the ochre column with the model columns. A model whose difference
        is near <strong>0.00</strong> when the true win rate is near <strong>50%</strong> — and
        positive when A really does win more — is describing the pair honestly.
        <strong>λ is experimental</strong>; it stays off in the V3 preset until real match data
        can fit it.</p>`;
    };
    $('#db_lambda').addEventListener('input', paint);
    enginePicker('bo_engines', 'boost', ['v2', 'v3']);
    enginePicker('pf_engines', 'partner', ['v2', 'v3']);
    $('#bo_run').onclick = boostRun;
    $('#pf_run').onclick = partnerRun;
    paint();
  }

  function boostRun() {
    $('#bo_out').innerHTML = '<div class="empty busy">Running…</div>';
    setTimeout(() => {
      const gap = $('#bo_gap').value;
      const d = call('boost', {
        seed: seed(),
        weakSkill: parseFloat($('#bo_weak').value),
        partnerSkill: parseFloat($('#bo_strong').value),
        matches: parseInt($('#bo_matches').value, 10),
        gapLimit: gap === '' ? null : parseFloat(gap),
        engines: specsFor('boost'),
      });
      const bars = d.rows.map((r) => ({
        label: r.short + ' inflation',
        value: r.inflation,
        color: colorOf(r.id),
        text: signed(r.inflation) + ' levels',
      }));
      $('#bo_out').innerHTML = html`
        <div class="kpis">
          ${d.rows
            .map(
              (r) => `<div class="kpi ${Math.abs(r.inflation) <= 0.2 ? 'good' : Math.abs(r.inflation) <= 0.5 ? 'warn' : 'crit'}">
                <span class="k">${esc(r.short)}</span>
                <span class="v">${signed(r.inflation)}</span>
                <span class="n">with strong ${f(r.withStrongPartner)} vs random ${f(r.withRandomPartners)}<br>
                true skill ${f(r.trueSkill)}</span></div>`
            )
            .join('')}
        </div>
        <div class="chartbox">${barChart(bars, { aria: 'rating gained purely from the partner' })}
          <figcaption>Rating the weak player gained purely from <em>who they played with</em>.
          Zero would mean the rating describes the player.</figcaption></div>
        <p class="hint">Note which way this cuts: engines that move more also leak more. Judge
        inflation next to the error columns, not on its own.</p>`;
    }, 10);
  }

  function partnerRun() {
    $('#pf_out').innerHTML = '<div class="empty busy">Running…</div>';
    setTimeout(() => {
      const d = call('partner.phases', {
        seed: seed(),
        trueSkill: parseFloat($('#pf_true').value),
        strongPartner: parseFloat($('#pf_strong').value),
        weakPartner: parseFloat($('#pf_weak').value),
        matches: parseInt($('#pf_matches').value, 10),
        engines: specsFor('partner'),
      });
      $('#pf_out').innerHTML = html`
        <div class="tablewrap"><table>
          <thead><tr><th>engine</th><th class="n">with strong partner</th><th class="n">with weak partner</th>
          <th class="n">random partners</th><th class="n">swing</th></tr></thead>
          <tbody>${d.rows
            .map(
              (r) => `<tr><th style="color:${colorOf(r.id)}">${esc(r.short)}</th>
                <td class="n">${f(r.strong)}</td><td class="n">${f(r.weak)}</td><td class="n">${f(r.random)}</td>
                <td class="n"><span class="tag ${r.independenceError <= 0.3 ? 'good' : r.independenceError <= 0.7 ? 'warn' : 'crit'}">${f(r.independenceError)}</span></td></tr>`
            )
            .join('')}</tbody></table></div>
        <p class="hint">All three columns describe the <strong>same player</strong> with a true skill of
        ${f(d.trueSkill)}. The swing is how much of their rating is really their partner's.</p>`;
    }, 10);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // KNOB SWEEPS
  // ══════════════════════════════════════════════════════════════════════════
  const SWEEP_VALUES = {
    prior: { values: [2.0, 2.5, 3.0, 3.3, 3.5, 4.0], label: (v) => f(v, 1) },
    placementK: { values: [0.3, 0.4, 0.5, 0.6, 0.8, 1.0], label: (v) => f(v, 1) },
    reliability: { values: [0.5, 0.65, 0.75, 0.85, 1.0], label: (v) => 'floor ' + f(v, 2) },
    margin: {
      values: [[1.0, 0.5], [0.9, 0.5], [0.85, 0.15], [0.8, 0.2], [0.7, 0.5]],
      label: (v) => `${Math.round(v[0] * 100)}/${Math.round((1 - v[0]) * 100)}${v[1] < 0.5 ? ' cap ±' + f(v[1], 2) : ' linear'}`,
    },
    curve: { values: [0.8, 1.0, 1.25, 1.5, 2.0], label: (v) => 's = ' + f(v, 2) },
    lambda: { values: [0, 0.05, 0.1, 0.15, 0.2, 0.3], label: (v) => 'λ = ' + f(v, 2) },
    sigmaDecay: { values: [0.88, 0.92, 0.95, 0.97, 0.99], label: (v) => '×' + f(v, 2) },
  };

  function knobsInit() {
    $('#kn_engine').innerHTML = META.engines
      .filter((e) => e.kind === 'hybrid' || e.id === 'v2')
      .map((e) => `<option value="${e.id}" ${e.id === 'v3' ? 'selected' : ''}>${esc(e.label)}</option>`)
      .join('');
    $('#kn_run').onclick = knobsRun;
    enginePicker('sc_engines', 'score', ['v2', 'v3']);
    $('#sc_run').onclick = scoreRun;
    $('#dc_run').onclick = declRun;
  }

  function knobsRun() {
    const param = $('#kn_param').value;
    const conf = SWEEP_VALUES[param];
    $('#kn_out').innerHTML = '<div class="empty busy">Sweeping…</div>';
    setTimeout(() => {
      const d = call('sweep', {
        param,
        values: conf.values,
        seed: 100,
        seeds: parseInt($('#kn_seeds').value, 10),
        players: parseInt($('#kn_players').value, 10),
        matches: parseInt($('#kn_matches').value, 10),
        engine: specOf($('#kn_engine').value),
      });
      const bestMae = Math.min(...d.rows.map((r) => r.mae));
      const bestSpread = Math.max(...d.rows.map((r) => r.spreadRecovery));
      $('#kn_out').innerHTML = html`
        <div class="tablewrap"><table>
          <thead><tr><th>${esc(param)}</th><th class="n">avg error</th><th class="n">spread kept</th>
          <th class="n">bias</th><th class="n">5.0+ stuck low</th><th class="n">weak stuck high</th>
          <th class="n">order ρ</th><th class="n">calib. error</th></tr></thead>
          <tbody>${d.rows
            .map(
              (r) => `<tr>
                <th class="n">${esc(conf.label(r.value))}</th>
                <td class="n ${r.mae === bestMae ? 'best' : ''}">${f(r.mae)}</td>
                <td class="n ${r.spreadRecovery === bestSpread ? 'best' : ''}">${pc(r.spreadRecovery * 100)}</td>
                <td class="n">${signed(r.bias)}</td>
                <td class="n">${pc(r.pctStrongStuckLow)}</td>
                <td class="n">${pc(r.pctWeakStuckHigh)}</td>
                <td class="n">${f(r.spearman)}</td>
                <td class="n">${pc(r.ece * 100, 1)}</td>
              </tr>`
            )
            .join('')}</tbody></table></div>
        <div class="duo">
          <div class="chartbox">${barChart(d.rows.map((r) => ({ label: conf.label(r.value), value: r.mae, color: 'var(--e1)', text: f(r.mae) })), { aria: 'average error by ' + param })}
            <figcaption>Average error in levels — shorter is better.</figcaption></div>
          <div class="chartbox">${barChart(d.rows.map((r) => ({ label: conf.label(r.value), value: r.spreadRecovery, color: 'var(--e3)', text: pc(r.spreadRecovery * 100) })), { aria: 'spread recovery by ' + param })}
            <figcaption>Spread kept — longer is better. 100% would mean the leaderboard is as
            spread out as real skill.</figcaption></div>
        </div>
        <p class="hint">Do not pick on average error alone. A knob that flattens everyone toward
        the middle can improve error while making the ranking useless — read the spread and the
        calibration columns with it.</p>`;
    }, 10);
  }

  function scoreRun() {
    const parse = (s) => s.split(',').map((x) => parseFloat(x.trim()));
    const a = parse($('#sc_a').value), b = parse($('#sc_b').value);
    const scores = $('#sc_scores').value.split('|').map((s) => s.trim()).filter(Boolean);
    const d = call('score.compare', {
      a1: a[0], a2: a[1] ?? a[0], b1: b[0], b2: b[1] ?? b[0],
      sigma: parseFloat($('#sc_sigma').value),
      scores,
      engines: specsFor('score'),
    });
    $('#sc_out').innerHTML = d.rows
      .map((r) => {
        const ok = r.scores.filter((s) => !s.error);
        const spread = ok.length > 1 ? Math.max(...ok.map((s) => s.delta)) - Math.min(...ok.map((s) => s.delta)) : 0;
        return html`
          <div class="stack" style="margin-top:10px">
            <div class="spread"><h3 style="color:${colorOf(r.id)}">${esc(r.label)}</h3>
              <span class="tag ${spread <= 0.03 ? 'good' : spread <= 0.07 ? 'warn' : 'crit'}">
                margin is worth ${f(spread, 3)} levels</span></div>
            <div class="tablewrap"><table>
              <thead><tr><th class="n">score</th><th class="n">result</th><th class="n">signal S</th>
              <th class="n">from margin</th><th class="n">Δ rating</th><th class="n">margin's effect</th></tr></thead>
              <tbody>${r.scores
                .map((s) =>
                  s.error
                    ? `<tr><th class="n">${esc(s.score)}</th><td colspan="5">${esc(s.error)}</td></tr>`
                    : `<tr><th class="n">${esc(s.score)}</th>
                       <td class="n">${s.won ? 'won' : 'lost'}</td>
                       <td class="n">${f(s.signal, 3)}</td>
                       <td class="n">${f(s.marginPart, 3)}</td>
                       <td class="n"><strong>${signed(s.delta, 3)}</strong></td>
                       <td class="n">${signed(s.marginEffect, 3)}</td></tr>`
                )
                .join('')}</tbody></table></div>
          </div>`;
      })
      .join('');
  }

  function declRun() {
    $('#dc_out').innerHTML = '<div class="empty busy">Running…</div>';
    setTimeout(() => {
      const d = call('declaration', {
        players: parseInt($('#dc_players').value, 10),
        matches: parseInt($('#dc_matches').value, 10),
        seeds: parseInt($('#dc_seeds').value, 10),
        engine: 'v3',
      });
      const colors = ['var(--e1)', 'var(--e2)', 'var(--e3)', 'var(--e4)', 'var(--e5)'];
      $('#dc_out').innerHTML = html`
        <div class="tablewrap"><table>
          <thead><tr><th>arm</th>${d.at.map((k) => `<th class="n">after ${k}</th>`).join('')}</tr></thead>
          <tbody>${d.rows
            .map((r, i) => `<tr><th style="color:${colors[i % colors.length]}">${esc(r.label)}</th>
              ${r.mae.map((v) => `<td class="n">${f(v)}</td>`).join('')}</tr>`)
            .join('')}</tbody></table></div>
        <div class="chartbox">
          ${lineChart({
            series: d.rows.map((r, i) => ({ name: r.label, color: colors[i % colors.length], ys: r.mae })),
            yDp: 2, xLabel: 'snapshot', x0: 0, height: 240,
          })}
          <figcaption>Average error in levels. The declared prior helps early and washes out —
          which is exactly why sigma must stay at maximum regardless of the answer.</figcaption>
        </div>
        ${legendFor(d.rows.map((r, i) => ({ name: r.label, color: colors[i % colors.length] })))}`;
    }, 10);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // CAREER
  // ══════════════════════════════════════════════════════════════════════════
  function careerInit() {
    enginePicker('sh_engines', 'shift', ['v2', 'v3']);
    enginePicker('in_engines', 'idle', ['v2', 'v3']);
    $('#sh_run').onclick = shiftRun;
    $('#in_run').onclick = idleRun;
  }

  function shiftRun() {
    $('#sh_out').innerHTML = '<div class="empty busy">Running…</div>';
    setTimeout(() => {
      const to = parseFloat($('#sh_to').value);
      const d = call('skill.shift', {
        seed: seed(),
        from: parseFloat($('#sh_from').value),
        to,
        preMatches: parseInt($('#sh_pre').value, 10),
        postMatches: parseInt($('#sh_post').value, 10),
        engines: specsFor('shift'),
      });
      $('#sh_out').innerHTML = html`
        <div class="kpis">
          ${d.rows
            .map(
              (r) => `<div class="kpi ${errClass(r.residualError)}">
                <span class="k">${esc(r.short)}</span><span class="v">${f(r.finalRating)}</span>
                <span class="n">true skill is now ${f(to, 1)} · still off by ${signed(r.residualError)}<br>
                sigma ${f(r.sigmaAtShift)} → ${f(r.finalSigma)}</span></div>`
            )
            .join('')}
        </div>
        <div class="duo">
          <div class="chartbox">
            ${lineChart({
              series: d.rows.map((r) => ({ name: r.short, color: colorOf(r.id), ys: r.ratings })),
              ref: to, refLabel: 'new true skill ' + f(to, 1),
              marker: d.rows[0].shiftAt, markerLabel: 'skill changes',
              yMin: 0, yMax: 7, yDp: 1, height: 250,
            })}
            <figcaption>Rating. The dashed vertical line is where the player really changed.</figcaption>
          </div>
          <div class="chartbox">
            ${lineChart({
              series: d.rows.map((r) => ({ name: r.short, color: colorOf(r.id), ys: r.sigmas })),
              marker: d.rows[0].shiftAt, markerLabel: 'skill changes',
              yMin: 0, yDp: 2, height: 250,
            })}
            <figcaption>Uncertainty. <strong>Watch for sigma falling after the change</strong> —
            that is an engine becoming more confident while being repeatedly proven wrong.</figcaption>
          </div>
        </div>`;
    }, 10);
  }

  function idleRun() {
    $('#in_out').innerHTML = '<div class="empty busy">Running…</div>';
    setTimeout(() => {
      const ret = parseFloat($('#in_return').value);
      const d = call('inactivity', {
        seed: seed(),
        settledAt: parseFloat($('#in_settled').value),
        days: parseInt($('#in_days').value, 10),
        returnSkill: ret,
        matchesAfter: parseInt($('#in_after').value, 10),
        engines: specsFor('idle'),
      });
      $('#in_out').innerHTML = html`
        <div class="tablewrap"><table>
          <thead><tr><th>engine</th><th class="n">before the break</th><th class="n">after ${d.days} days</th>
          <th class="n">lost to decay</th><th class="n">sigma</th><th class="n">matches to recover</th>
          <th class="n">final</th></tr></thead>
          <tbody>${d.rows
            .map(
              (r) => `<tr><th style="color:${colorOf(r.id)}">${esc(r.short)}</th>
                <td class="n">${f(r.beforeIdle)}</td><td class="n">${f(r.afterIdle)}</td>
                <td class="n"><span class="tag ${r.lostToDecay <= 0.02 ? 'good' : r.lostToDecay <= 0.2 ? 'warn' : 'crit'}">${f(r.lostToDecay)}</span></td>
                <td class="n">${f(r.sigmaBefore)} → ${f(r.sigmaAfter)}</td>
                <td class="n">${r.recoveryMatches < 0 ? 'not yet' : r.recoveryMatches}</td>
                <td class="n">${f(r.finalRating)} (${signed(r.residualError)})</td></tr>`
            )
            .join('')}</tbody></table></div>
        <div class="chartbox">
          ${lineChart({
            series: d.rows.map((r) => ({ name: r.short, color: colorOf(r.id), ys: r.ratings })),
            ref: ret, refLabel: 'true skill on return ' + f(ret, 1),
            marker: d.rows[0].idleAt, markerLabel: `${d.days} days away`,
            yMin: 0, yMax: 7, yDp: 1,
          })}
          <figcaption>Rating through the break and back. Anything lost at the dashed line was
          taken for <em>not playing</em>, not for playing badly.</figcaption>
        </div>`;
    }, 10);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // SETTINGS
  // ══════════════════════════════════════════════════════════════════════════
  const FIELDS = [
    ['prior', 'Starting prior', 'number', 0.1, 'Where a brand-new player begins.'],
    ['sigma0', 'Starting sigma', 'number', 0.05, 'How unsure the engine starts out.'],
    ['placementMatches', 'Placement length', 'int', 1, 'Matches before a player counts as established.'],
    ['stageK', 'Placement K per stage', 'list', 0, 'Biggest step allowed in each placement stage.'],
    ['stageEnds', 'Stage boundaries', 'intlist', 0, 'Match counts where each stage ends.'],
    ['placementRelFloor', 'Reliability floor in placement', 'number', 0.05, '1.0 = ignore how unsure the opponents are.'],
    ['relFloor', 'Reliability floor once established', 'number', 0.05, ''],
    ['resultWeight', 'Weight on the result', 'number', 0.05, 'The rest is the games margin.'],
    ['marginCap', 'Margin cap', 'number', 0.05, '0.5 = no cap (today). Lower saturates blowouts.'],
    ['curveScale', 'Expected-win curve', 'number', 0.05, 'Higher = a level gap means less.'],
    ['kMax', 'Max K (established)', 'number', 0.01, ''],
    ['sigmaDecay', 'Sigma decay per match', 'number', 0.01, ''],
    ['lambdaImbalance', 'Team imbalance λ', 'number', 0.05, 'Experimental. 0 = plain average.'],
    ['ratingInactivityDecay', 'Rating decays when idle', 'bool', 0, 'Off = keep the rating, widen the uncertainty.'],
    ['idleSigmaPerWeek', 'Sigma growth per idle week', 'number', 0.005, ''],
    ['displayMinMatches', 'Matches before showing a rank', 'int', 1, ''],
    ['displayMaxSigma', 'Max sigma to show a rank', 'number', 0.05, ''],
    ['displayMinPartners', 'Different partners required', 'int', 1, ''],
    ['adaptiveSigma', 'Surprise-aware sigma', 'bool', 0, ''],
    ['diversitySigma', 'Diversity-aware sigma', 'bool', 0, ''],
    ['internalMin', 'Internal floor', 'number', 0.5, 'May sit outside the public 0–7 scale.'],
    ['internalMax', 'Internal ceiling', 'number', 0.5, ''],
  ];

  function settingsInit() {
    const editable = META.engines.filter((e) => e.kind === 'hybrid');
    $('#cfg_which').innerHTML = editable.map((e) => `<option value="${e.id}">${esc(e.label)}</option>`).join('');
    $('#cfg_which').onchange = renderConfig;
    $$('[data-panel="settings"] [data-preset]').forEach((b) => {
      b.onclick = () => {
        delete CFG[$('#cfg_which').value];
        if (b.dataset.preset !== $('#cfg_which').value) {
          CFG[$('#cfg_which').value] = { ...META.presets[b.dataset.preset] };
          delete CFG[$('#cfg_which').value].declaredPriors;
        }
        renderConfig();
      };
    });
    enginePicker('rp_engines', 'replay', ['v2', 'v3', 'trueskill']);
    $('#rp_load').onclick = replayLoad;
    $('#cfg_export').onclick = exportScenario;
    $('#cfg_import').onclick = importScenario;
    $('#cfg_save').onclick = saveScenario;
    $('#cfg_clear').onclick = () => { localStorage.removeItem('rankLabScenarios'); renderSaved(); };
    renderConfig();
    renderSaved();
  }

  function effectiveCfg(id) {
    return { ...(META.presets[id] || META.presets.v3), ...(CFG[id] || {}) };
  }

  function renderConfig() {
    const id = $('#cfg_which').value;
    const cfg = effectiveCfg(id);
    const dirty = CFG[id] && Object.keys(CFG[id]).length;
    $('#cfg_title').textContent = labelOf(id);
    $('#cfg_badge').textContent = dirty ? 'modified from preset' : 'preset defaults';
    $('#cfg_badge').className = 'tag grow ' + (dirty ? 'warn' : 'info');

    $('#cfg_form').innerHTML = `<div class="stack">${FIELDS.map(([key, label, type, step, note]) => {
      const v = cfg[key];
      let input;
      if (type === 'bool') {
        input = `<select data-key="${key}" data-type="bool"><option value="true" ${v ? 'selected' : ''}>on</option><option value="false" ${!v ? 'selected' : ''}>off</option></select>`;
      } else if (type === 'list' || type === 'intlist') {
        input = `<input type="text" data-key="${key}" data-type="${type}" value="${Array.isArray(v) ? v.join(', ') : ''}" />`;
      } else {
        input = `<input type="number" step="${step}" data-key="${key}" data-type="${type}" value="${v}" />`;
      }
      return `<label class="field"><span>${esc(label)}</span>${input}
        ${note ? `<span class="hint">${esc(note)}</span>` : ''}</label>`;
    }).join('')}</div>`;

    $$('#cfg_form [data-key]').forEach((inp) => {
      inp.onchange = () => {
        const key = inp.dataset.key, type = inp.dataset.type;
        let val;
        if (type === 'bool') val = inp.value === 'true';
        else if (type === 'int') val = parseInt(inp.value, 10);
        else if (type === 'list') val = inp.value.split(',').map((x) => parseFloat(x.trim())).filter((x) => !Number.isNaN(x));
        else if (type === 'intlist') val = inp.value.split(',').map((x) => parseInt(x.trim(), 10)).filter((x) => !Number.isNaN(x));
        else val = parseFloat(inp.value);
        CFG[id] = { ...(CFG[id] || {}), [key]: val };
        renderConfig();
      };
    });
  }

  function exportScenario() {
    const blob = {
      savedAt: new Date().toISOString(),
      seed: seed(),
      configs: CFG,
      note: 'Padel Rivals ranking lab scenario. Simulation only.',
    };
    download('ranking-lab-scenario.json', JSON.stringify(blob, null, 2), 'application/json');
  }

  function importScenario() {
    const inp = document.createElement('input');
    inp.type = 'file';
    inp.accept = 'application/json';
    inp.onchange = () => {
      const file = inp.files[0];
      if (!file) return;
      const r = new FileReader();
      r.onload = () => {
        try {
          const blob = JSON.parse(r.result);
          Object.keys(CFG).forEach((k) => delete CFG[k]);
          Object.assign(CFG, blob.configs || {});
          if (blob.seed) $('#seed').value = blob.seed;
          renderConfig();
        } catch (e) {
          alert('That file is not a lab scenario: ' + e.message);
        }
      };
      r.readAsText(file);
    };
    inp.click();
  }

  function saveScenario() {
    const name = prompt('Name this scenario', 'Strong player cold start');
    if (!name) return;
    const all = JSON.parse(localStorage.getItem('rankLabScenarios') || '{}');
    all[name] = { seed: seed(), configs: JSON.parse(JSON.stringify(CFG)) };
    localStorage.setItem('rankLabScenarios', JSON.stringify(all));
    renderSaved();
  }

  function renderSaved() {
    const all = JSON.parse(localStorage.getItem('rankLabScenarios') || '{}');
    const names = Object.keys(all);
    $('#cfg_saved').innerHTML = names.length
      ? `<h4>Saved scenarios</h4><div class="btnrow" style="margin-top:6px">${names
          .map((n) => `<button class="tiny ghost" data-load="${esc(n)}">${esc(n)}</button>`)
          .join('')}</div>`
      : '<p class="hint">No saved scenarios yet.</p>';
    $$('#cfg_saved [data-load]').forEach((b) => {
      b.onclick = () => {
        const s = all[b.dataset.load];
        Object.keys(CFG).forEach((k) => delete CFG[k]);
        Object.assign(CFG, s.configs || {});
        $('#seed').value = s.seed;
        renderConfig();
      };
    });
  }

  function replayLoad() {
    const inp = document.createElement('input');
    inp.type = 'file';
    inp.accept = 'application/json';
    inp.onchange = () => {
      const file = inp.files[0];
      if (!file) return;
      const rd = new FileReader();
      rd.onload = () => {
        try {
          const blob = JSON.parse(rd.result);
          const d = call('replay.run', {
            players: blob.players || [],
            matches: blob.matches || [],
            warmup: blob.warmup,
            engines: specsFor('replay'),
          });
          const best = d.rows.reduce((a, b) => (a.brier <= b.brier ? a : b));
          $('#rp_out').innerHTML = html`
            <div class="kpis" style="margin-top:10px">
              ${d.rows
                .map(
                  (r) => `<div class="kpi ${r === best ? 'good' : ''}">
                    <span class="k">${esc(r.short)}</span>
                    <span class="v">${pc(r.accuracy * 100, 1)}</span>
                    <span class="n">picked the winner · Brier ${f(r.brier, 3)} · calib. ${pc(r.ece * 100, 1)}<br>
                    ratings averaged ${f(r.ratingMean)} spread ${f(r.ratingSd)}</span></div>`
                )
                .join('')}
            </div>
            <p class="hint">${d.matches} matches, ${d.players} players; the first ${d.warmup} were
            used to warm the engines up and ${d.scored} were scored. Lowest Brier score wins —
            <strong>${esc(best.short)}</strong> here. ${esc(d.note)}</p>`;
        } catch (e) {
          $('#rp_out').innerHTML = `<div class="err">${esc(e.message)}</div>`;
        }
      };
      rd.readAsText(file);
    };
    inp.click();
  }

  function download(name, text, mime) {
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([text], { type: mime }));
    a.download = name;
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  }

  // ── shell wiring ──────────────────────────────────────────────────────────
  function fillWorlds(sel) {
    const node = $(sel);
    if (!node) return;
    node.innerHTML = META.worlds
      .map((w) => `<option value="${w.id}" ${w.id === 'D' ? 'selected' : ''}>${esc(w.label)}</option>`)
      .join('');
  }

  function tabsInit() {
    $$('.tab').forEach((t) => {
      t.onclick = () => {
        $$('.tab').forEach((x) => x.setAttribute('aria-selected', String(x === t)));
        $$('[data-panel]').forEach((p) => { p.hidden = p.dataset.panel !== t.dataset.tab; });
      };
    });
    $('#seedCopy').onclick = () => navigator.clipboard && navigator.clipboard.writeText($('#seed').value);
    $('#seedNew').onclick = () => { $('#seed').value = Math.floor(Math.random() * 900000) + 100000; };
  }

  function boot() {
    if (!globalThis.rankLab) {
      document.body.insertAdjacentHTML('afterbegin',
        '<div class="err" style="margin:18px">The simulation kernel did not load.</div>');
      return;
    }
    META = call('meta');
    tabsInit();
    storyInit();
    compareInit();
    populationInit();
    doublesInit();
    knobsInit();
    careerInit();
    settingsInit();
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
})();
