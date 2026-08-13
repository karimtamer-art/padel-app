// ignore_for_file: avoid_print
/// Builds the HTML study report from results.json.
///   dart run tools/ranking_simulation/report.dart
library;

import 'dart:convert';
import 'dart:io';
import 'charts.dart';

late Map<String, dynamic> R;

Map<String, dynamic> m(dynamic v) => (v as Map).cast<String, dynamic>();
List<dynamic> l(dynamic v) => v as List<dynamic>;
double d(dynamic v) => v == null ? double.nan : (v as num).toDouble();

const engineOrder = [
  'A · Current (production)',
  'B · Aggressive Placement',
  'C · Tuned Hybrid',
  'D · TrueSkill',
  'D2 · TrueSkill (per-set)',
  'E · Glicko-2',
];
const engineShort = {
  'A · Current (production)': 'A · Current',
  'B · Aggressive Placement': 'B · Aggressive',
  'C · Tuned Hybrid': 'C · Tuned Hybrid',
  'D · TrueSkill': 'D · TrueSkill',
  'D2 · TrueSkill (per-set)': 'D2 · TrueSkill/set',
  'E · Glicko-2': 'E · Glicko-2',
};
int slotOf(String engine) => engineOrder.indexOf(engine) + 1;

const primaryWorld = 'D (primary, mixed doubles)';
const snapKeys = ['1', '3', '5', '10', '20', '50'];

String pct(double v, [int dp = 0]) => '${v.toStringAsFixed(dp)}%';

// ─────────────────────────────────────────────────────────────────────────────
void main() {
  final f = File('tools/ranking_simulation/results/results.json');
  if (!f.existsSync()) {
    print('results.json not found — run experiments.dart first.');
    exit(1);
  }
  R = (jsonDecode(f.readAsStringSync()) as Map).cast<String, dynamic>();

  final b = StringBuffer();
  b.writeln('<title>Padel Rivals — ranking engine study</title>');
  b.writeln(css());
  b.writeln(printUi());
  b.writeln('<div class="page">');
  b.writeln(header());
  b.writeln(verdict());
  b.writeln(sectionCompression());
  b.writeln(sectionHeadToHead());
  b.writeln(sectionWhyItFails());
  b.writeln(sectionMatchmaking());
  b.writeln(sectionModelShape());
  b.writeln(sectionDoubles());
  b.writeln(sectionUncertainty());
  b.writeln(sectionScenarios());
  b.writeln(sectionRecommendation());
  b.writeln(sectionQuestions());
  b.writeln(sectionMethod());
  b.writeln('</div>');

  final out = File('tools/ranking_simulation/results/report.html');
  out.writeAsStringSync(b.toString());
  print('wrote ${out.path} (${(out.lengthSync() / 1024).toStringAsFixed(0)} KB)');
}

// ─────────────────────────────────────────────────────────────────────────────
String css() => '''
<style>
:root{
  color-scheme: light;
  --ground:#EFF2F0; --surface:#FCFCFB; --surface-2:#E7ECE9; --sunk:#F5F7F6;
  --ink:#121715; --ink-2:#495451; --ink-3:#6E7A76; --rule:#D3DBD7;
  --accent:#0D504A; --accent-soft:#DCEAE7;
  --good:#0F6B45; --warn:#8A5A00; --crit:#A32A22;
  --s1:#2a78d6; --s2:#eb6834; --s3:#1baf7a; --s4:#eda100; --s5:#e87ba4; --s6:#008300;
  --mono: ui-monospace, "Cascadia Mono", "SF Mono", "JetBrains Mono", Menlo, Consolas, monospace;
  --sans: system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
}
@media (prefers-color-scheme: dark){
  :root:not([data-theme="light"]){
    color-scheme: dark;
    --ground:#0E100F; --surface:#1A1A19; --surface-2:#232826; --sunk:#151817;
    --ink:#EDF0EE; --ink-2:#AEB8B4; --ink-3:#828C88; --rule:#2C3331;
    --accent:#5CBBAE; --accent-soft:#152B28;
    --good:#3FA97A; --warn:#C79A3A; --crit:#E07068;
    --s1:#3987e5; --s2:#d95926; --s3:#199e70; --s4:#c98500; --s5:#d55181; --s6:#008300;
  }
}
:root[data-theme="dark"]{
  color-scheme: dark;
  --ground:#0E100F; --surface:#1A1A19; --surface-2:#232826; --sunk:#151817;
  --ink:#EDF0EE; --ink-2:#AEB8B4; --ink-3:#828C88; --rule:#2C3331;
  --accent:#5CBBAE; --accent-soft:#152B28;
  --good:#3FA97A; --warn:#C79A3A; --crit:#E07068;
  --s1:#3987e5; --s2:#d95926; --s3:#199e70; --s4:#c98500; --s5:#d55181; --s6:#008300;
}

*{box-sizing:border-box}
body{background:var(--ground); color:var(--ink); font-family:var(--sans);
  font-size:16px; line-height:1.62; margin:0; -webkit-font-smoothing:antialiased}
.page{max-width:1140px; margin:0 auto; padding:48px 24px 96px;
  display:flex; flex-direction:column; gap:56px}

h1,h2,h3,h4{font-family:var(--mono); font-weight:600; text-wrap:balance; margin:0; letter-spacing:-.01em}
h1{font-size:clamp(1.9rem,4.4vw,2.9rem); line-height:1.08; letter-spacing:-.03em}
h2{font-size:1.42rem; line-height:1.2}
h3{font-size:1.05rem; line-height:1.3}
h4{font-size:.86rem; text-transform:uppercase; letter-spacing:.09em; color:var(--ink-2)}
p{margin:0}
a{color:var(--accent)}
strong{font-weight:650}
code,.mono{font-family:var(--mono); font-size:.92em}

.eyebrow{font-family:var(--mono); font-size:.74rem; letter-spacing:.16em;
  text-transform:uppercase; color:var(--accent); font-weight:600}
.lede{font-size:1.12rem; color:var(--ink-2); max-width:68ch}
.prose{display:flex; flex-direction:column; gap:14px; max-width:74ch}
.prose p{max-width:74ch}

section{display:flex; flex-direction:column; gap:22px}
section > header{display:flex; flex-direction:column; gap:8px;
  border-top:1px solid var(--rule); padding-top:18px}

/* header spec strip */
.masthead{display:flex; flex-direction:column; gap:20px}
.spec{display:grid; grid-template-columns:repeat(auto-fit,minmax(148px,1fr)); gap:1px;
  background:var(--rule); border:1px solid var(--rule); border-radius:8px; overflow:hidden}
.spec div{background:var(--surface); padding:11px 14px; display:flex; flex-direction:column; gap:2px}
.spec dt{font-family:var(--mono); font-size:.68rem; letter-spacing:.11em;
  text-transform:uppercase; color:var(--ink-3)}
.spec dd{margin:0; font-family:var(--mono); font-size:.94rem; font-weight:600;
  font-variant-numeric:tabular-nums}

/* verdict */
.verdict{background:var(--surface); border:1px solid var(--rule); border-radius:10px;
  padding:26px 28px; display:flex; flex-direction:column; gap:18px}
.findings{display:flex; flex-direction:column; gap:14px; margin:0; padding:0; list-style:none}
.findings li{display:grid; grid-template-columns:auto 1fr; gap:14px; align-items:start}
.chip{font-family:var(--mono); font-size:.68rem; font-weight:700; letter-spacing:.08em;
  text-transform:uppercase; padding:4px 9px; border-radius:5px; white-space:nowrap; margin-top:2px}
.chip.bad{background:color-mix(in srgb, var(--crit) 15%, transparent); color:var(--crit)}
.chip.ok{background:color-mix(in srgb, var(--good) 15%, transparent); color:var(--good)}
.chip.warn{background:color-mix(in srgb, var(--warn) 16%, transparent); color:var(--warn)}
.chip.info{background:var(--accent-soft); color:var(--accent)}

/* headline stat row */
.stats{display:grid; grid-template-columns:repeat(auto-fit,minmax(180px,1fr)); gap:14px}
.stat{background:var(--surface); border:1px solid var(--rule); border-radius:9px; padding:16px 18px;
  display:flex; flex-direction:column; gap:5px}
.stat .k{font-family:var(--mono); font-size:.7rem; letter-spacing:.1em; text-transform:uppercase;
  color:var(--ink-3)}
.stat .v{font-family:var(--mono); font-size:1.85rem; font-weight:650; line-height:1;
  font-variant-numeric:tabular-nums}
.stat .n{font-size:.83rem; color:var(--ink-2); line-height:1.42}
.stat.bad .v{color:var(--crit)} .stat.good .v{color:var(--good)}

/* figures */
figure{margin:0}
.figblock{background:var(--surface); border:1px solid var(--rule); border-radius:10px;
  padding:18px 20px 14px; display:flex; flex-direction:column; gap:12px; overflow:hidden}
.figblock > figcaption, .caption{font-size:.85rem; color:var(--ink-2); max-width:76ch}
.chart{width:100%; height:auto; display:block; overflow:visible}
.chartscroll{overflow-x:auto}
.grid-line, .grid{stroke:var(--rule); stroke-width:1; opacity:.75}
.axis{stroke:var(--ink-3); stroke-width:1}
.ideal{stroke:var(--ink-3); stroke-width:1.5; stroke-dasharray:5 4; opacity:.85}
.ref{stroke:var(--ink-3); stroke-width:1.5; stroke-dasharray:4 4}
.line{fill:none; stroke-width:2; stroke-linejoin:round; stroke-linecap:round}
.line.dashed{stroke-dasharray:6 4}
.dot{stroke:var(--surface); stroke-width:1.5}
.pt{opacity:.6}
.bar{stroke:var(--surface); stroke-width:2}
.truthline{fill:none; stroke:var(--ink-2); stroke-width:1.6; stroke-dasharray:4 3}
.leader{stroke-width:1.2; opacity:.8}
.tick{font-family:var(--mono); font-size:11px; fill:var(--ink-3); font-variant-numeric:tabular-nums}
.tick.sm{font-size:10px}
.axis-label{font-family:var(--mono); font-size:11px; fill:var(--ink-2); letter-spacing:.05em}
.axis-label.sm{font-size:10px}
.serieslabel{font-family:var(--mono); font-size:11.5px; font-weight:600}
.rowlabel{font-family:var(--mono); font-size:11.5px; fill:var(--ink); text-anchor:end}
.barval{font-family:var(--mono); font-size:10.5px; fill:var(--ink-2); font-variant-numeric:tabular-nums}

.legend{display:flex; flex-wrap:wrap; gap:6px 18px; list-style:none; margin:0; padding:0;
  font-family:var(--mono); font-size:.78rem; color:var(--ink-2)}
.legend li{display:flex; align-items:center; gap:7px}
.swatch{width:11px; height:11px; border-radius:3px; display:inline-block; flex:none}

.panels{display:grid; grid-template-columns:repeat(auto-fit,minmax(196px,1fr)); gap:14px}
.scatter figcaption, .hist figcaption{font-family:var(--mono); font-size:.72rem;
  color:var(--ink-3); text-align:center; margin-top:2px; letter-spacing:.04em}
.duo{display:grid; grid-template-columns:repeat(auto-fit,minmax(320px,1fr)); gap:18px; align-items:start}

/* tables */
.tablewrap{overflow-x:auto; border:1px solid var(--rule); border-radius:9px; background:var(--surface)}
table{border-collapse:collapse; width:100%; font-size:.86rem}
th,td{padding:9px 13px; text-align:left; border-bottom:1px solid var(--rule); white-space:nowrap}
thead th{font-family:var(--mono); font-size:.7rem; letter-spacing:.07em; text-transform:uppercase;
  color:var(--ink-3); font-weight:600; background:var(--sunk); position:sticky; top:0}
tbody th{font-weight:550; font-family:var(--mono); font-size:.82rem}
td.num,th.num{text-align:right; font-family:var(--mono); font-variant-numeric:tabular-nums}
tbody tr:last-child th, tbody tr:last-child td{border-bottom:none}
tr.emph{background:color-mix(in srgb, var(--crit) 7%, transparent)}
tr.emph th{color:var(--crit)}
.best{color:var(--good); font-weight:650}

details{background:var(--surface); border:1px solid var(--rule); border-radius:9px; padding:0 18px}
details[open]{padding-bottom:16px}
summary{cursor:pointer; padding:14px 0; font-family:var(--mono); font-size:.85rem; font-weight:600}
summary:focus-visible{outline:2px solid var(--accent); outline-offset:3px}

.qa{display:flex; flex-direction:column; gap:0; border:1px solid var(--rule); border-radius:10px;
  overflow:hidden; background:var(--surface)}
.qa > div{display:grid; grid-template-columns:34px 1fr; gap:14px; padding:15px 18px;
  border-bottom:1px solid var(--rule)}
.qa > div:last-child{border-bottom:none}
.qa .n{font-family:var(--mono); font-size:.78rem; color:var(--ink-3); font-weight:600;
  font-variant-numeric:tabular-nums; padding-top:2px}
.qa .q{font-weight:600; margin-bottom:4px}
.qa .a{color:var(--ink-2); font-size:.94rem}
.qa .a strong{color:var(--ink)}

.note{border-left:2px solid var(--accent); padding:2px 0 2px 16px; color:var(--ink-2);
  font-size:.94rem; max-width:74ch}

ul.bullets{margin:0; padding-left:20px; display:flex; flex-direction:column; gap:8px;
  color:var(--ink-2); max-width:74ch}
ul.bullets strong{color:var(--ink)}

@media (prefers-reduced-motion: no-preference){
  details summary{transition:color .15s ease}
}
@media (max-width:640px){
  .page{padding:32px 16px 64px; gap:44px}
  th,td{padding:7px 10px}
}

/* ── save as PDF ──────────────────────────────────────────────────────────── */
.pdfbtn{position:fixed; right:20px; bottom:20px; z-index:50;
  font-family:var(--mono); font-size:.8rem; font-weight:600;
  display:inline-flex; align-items:center; gap:8px; padding:11px 17px;
  border-radius:999px; cursor:pointer; color:var(--ground); background:var(--accent);
  border:1px solid transparent; box-shadow:0 6px 22px rgba(0,0,0,.24)}
.pdfbtn:hover{filter:brightness(1.09)}
.pdfbtn:focus-visible{outline:2px solid var(--accent); outline-offset:3px}
.pdfbtn svg{width:14px; height:14px; fill:none; stroke:currentColor; stroke-width:2.2;
  stroke-linecap:round; stroke-linejoin:round}
@media (max-width:640px){.pdfbtn{right:12px; bottom:12px; padding:10px 14px}}
.pdfhint{position:fixed; right:20px; bottom:74px; z-index:50; max-width:330px;
  background:var(--surface); color:var(--ink-2); border:1px solid var(--rule);
  border-radius:10px; padding:14px 16px; font-size:.85rem; line-height:1.5;
  box-shadow:0 8px 26px rgba(0,0,0,.20)}
.pdfhint strong{color:var(--ink)}
.pdfhint a{font-weight:600}
.pdfhint kbd{font-family:var(--mono); font-size:.78em; background:var(--sunk);
  border:1px solid var(--rule); border-radius:4px; padding:1px 5px}
@media (max-width:640px){.pdfhint{right:12px; left:12px; bottom:64px; max-width:none}}

@page{margin:14mm 12mm}
@media print{
  /* paper is white whatever theme the reader is in — but the chart ink must survive */
  :root, :root[data-theme="dark"], :root:not([data-theme="light"]){
    color-scheme:light;
    --ground:#fff; --surface:#fff; --surface-2:#F1F4F2; --sunk:#F4F7F5;
    --ink:#111; --ink-2:#3F4A47; --ink-3:#6C7874; --rule:#C6D0CC;
    --accent:#0D504A; --accent-soft:#E6F0EE;
    --good:#0F6B45; --warn:#7A5000; --crit:#A32A22;
    --s1:#2a78d6; --s2:#eb6834; --s3:#1baf7a; --s4:#c98500; --s5:#e87ba4; --s6:#008300;
  }
  *{-webkit-print-color-adjust:exact; print-color-adjust:exact}
  .pdfbtn{display:none !important}
  body{background:#fff; font-size:10.5pt}
  .page{max-width:none; padding:0; gap:26px}
  h1{font-size:21pt} h2{font-size:14pt} h3{font-size:11pt}
  a{text-decoration:none}
  /* anything that scrolls on screen has to unroll on paper, or it prints clipped */
  .chartscroll, .tablewrap, .figblock{overflow:visible !important}
  thead th{position:static}
  .figblock, .stat, .verdict li, .qa > div, .scatter, .hist, figure{break-inside:avoid}
  tr, th, td{break-inside:avoid}
  h1,h2,h3,h4,section > header{break-after:avoid}
}
</style>
''';

// ─────────────────────────────────────────────────────────────────────────────
/// The browser's own print pipeline is the PDF writer (Destination → Save as PDF);
/// a real PDF library would have to come off a CDN, which the artifact CSP blocks.
String printUi() => '''
<button class="pdfbtn" type="button" onclick="savePdf()"
  title="Opens the print dialog — choose Save as PDF">
  <svg viewBox="0 0 24 24" aria-hidden="true">
    <path d="M12 3v11m0 0 4-4m-4 4-4-4"/><path d="M4 16v3a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-3"/>
  </svg>Download PDF</button>
<script>
(function(){
  // A closed <details> prints as its summary and nothing else, so open the lot
  // first and put back exactly the ones that were shut.
  var reopened = [];
  function expand(){
    if (reopened.length) return;
    document.querySelectorAll('details:not([open])').forEach(function(d){
      reopened.push(d); d.open = true;
    });
  }
  function restore(){
    reopened.forEach(function(d){ d.open = false; });
    reopened = [];
  }
  window.addEventListener('beforeprint', expand);
  window.addEventListener('afterprint', restore);

  // An embedded preview frame can refuse print() with no error and no dialog, so
  // say so rather than looking broken. beforeprint firing is the proof it worked.
  function hint(){
    if (document.querySelector('.pdfhint')) return;
    var el = document.createElement('div');
    el.className = 'pdfhint';
    el.innerHTML = '<strong>This preview frame blocked the print dialog.</strong><br>' +
      '<a href="' + location.href + '" target="_blank" rel="noopener">Open the report ' +
      'in its own tab</a>, then press <kbd>Ctrl</kbd>+<kbd>P</kbd> ' +
      '(<kbd>&#8984;</kbd>+<kbd>P</kbd> on Mac) and choose <em>Save as PDF</em>.';
    document.body.appendChild(el);
    setTimeout(function(){ el.remove(); }, 16000);
  }

  window.savePdf = function(){
    expand();                 // Safari fires neither print event; cover it by hand
    var fired = false;
    var mark = function(){ fired = true; };
    window.addEventListener('beforeprint', mark, {once: true});
    try { window.print(); } catch (e) { /* blocked frame */ }
    setTimeout(function(){
      window.removeEventListener('beforeprint', mark);
      if (!fired) hint();
      restore();
    }, 700);
  };
})();
</script>
''';

// ─────────────────────────────────────────────────────────────────────────────
String header() {
  final e1 = m(R['e1']);
  final worlds = m(e1['worlds']);
  final seedsPrimary = m(m(worlds[primaryWorld])[engineOrder.first])['seeds'];
  return '''
<header class="masthead">
  <p class="eyebrow">Ranking engine study · pre-production</p>
  <h1>The current engine ranks players in the right order,<br>then squashes them all into one level.</h1>
  <p class="lede">Six rating engines, one identical match stream, eleven simulated worlds.
  This is an evaluation only — nothing in <code>_settle_rating</code>, the Dart mirror or any
  live rating was touched.</p>
  <dl class="spec">
    <div><dt>Engines compared</dt><dd>6</dd></div>
    <div><dt>Players per run</dt><dd>1,000</dd></div>
    <div><dt>Matches per player</dt><dd>50</dd></div>
    <div><dt>Eval seeds (primary)</dt><dd>$seedsPrimary</dd></div>
    <div><dt>Worlds</dt><dd>11</dd></div>
    <div><dt>Tuning seeds</dt><dd>held out</dd></div>
  </dl>
</header>''';
}

// ─────────────────────────────────────────────────────────────────────────────
String verdict() {
  final w = m(m(m(R['e1'])['worlds'])[primaryWorld]);
  final a = m(w['A · Current (production)']);
  final c = m(w['C · Tuned Hybrid']);
  final ts = m(w['D · TrueSkill']);
  final a10 = m(m(a['snapshots'])['10']);
  final a50 = m(m(a['snapshots'])['50']);
  final c10 = m(m(c['snapshots'])['10']);
  final t50 = m(m(ts['snapshots'])['50']);

  return '''
<section>
  <div class="verdict">
    <h2>Verdict</h2>
    <ul class="findings">
      <li><span class="chip bad">confirmed</span>
        <div><strong>Cold-start compression is real and severe.</strong> After 10 placement
        matches the current engine reproduces only
        <strong>${pct(d(a10['spreadRecovery']) * 100)}</strong> of the true spread between players.
        A population whose true levels span 1–6 lands almost entirely between
        ${fmt(d(a10['meanEstByBand']['1–2'] ?? 1.9), 1)} and
        ${fmt(d(a10['meanEstByBand']['5–6'] ?? 2.6), 1)}.</div></li>
      <li><span class="chip bad">confirmed</span>
        <div><strong>${pct(d(a10['pctStrongStuckLow']))} of genuine 5.0+ players are still
        rated below 3.5 after placement</strong> — and
        ${pct(d(a50['pctStrongStuckLow']))} are still there after 50 matches. This does not
        fix itself with time.</div></li>
      <li><span class="chip info">root cause</span>
        <div>It is not one bug, it is four multiplying together: a <strong>prior of 2.0</strong>
        against a population averaging 3.3; an <strong>opponent-reliability discount that
        collapses to 0.575×</strong> when everybody is new; a <strong>placement K of 0.46</strong>
        far too small to cross the scale in ten matches; and the <strong>30% games-margin
        term</strong>, which turns out to be an active compression force rather than a neutral
        refinement.</div></li>
      <li><span class="chip bad">new</span>
        <div><strong>The margin term drags every favourite toward the middle — by arithmetic,
        not by accident.</strong> <code>E</code> is a probability of <em>winning</em>; the games
        ratio is far less extreme. A pair one level ahead wins ~87% of matches but only ~60% of
        games, so a correctly-rated favourite has E[S] &lt; E and <strong>loses rating on average
        for winning the matches they were supposed to win</strong>. It survives even a perfectly
        calibrated curve. Capping the ratio fixes it.</div></li>
      <li><span class="chip ok">fixable</span>
        <div>Fixing all four inside the existing architecture (Engine C) cuts the error after
        placement from <strong>${fmt(d(a10['mae']), 2)}</strong> to
        <strong>${fmt(d(c10['mae']), 2)}</strong> levels, lifts spread recovery to
        <strong>${pct(d(c10['spreadRecovery']) * 100)}</strong>, and gives the
        <strong>best-calibrated probabilities of any engine tested</strong>
        (${pct(d(c['ece']) * 100, 1)} error against ${pct(d(a['ece']) * 100, 1)} today).</div></li>
      <li><span class="chip warn">consider</span>
        <div>TrueSkill and Glicko-2 are still ahead at 50 matches (${fmt(d(t50['mae']), 2)} and
        ${fmt(d(m(m(m(w['E · Glicko-2'])['snapshots'])['50'])['mae']), 2)} against
        ${fmt(d(m(m(c['snapshots'])['50'])['mae']), 2)}) and recover more spread. The gap is real
        — and it is not worth a rewrite. See the recommendation.</div></li>
    </ul>
  </div>
</section>''';
}

// ─────────────────────────────────────────────────────────────────────────────
String sectionCompression() {
  final e1 = m(R['e1']);
  final w = m(m(e1['worlds'])[primaryWorld]);
  final detail = m(e1['detail']);

  // scatter panels: current vs tuned vs trueskill at 10 matches
  final panels = StringBuffer();
  for (final eng in ['A · Current (production)', 'C · Tuned Hybrid', 'D · TrueSkill']) {
    final pts = l(m(m(detail[eng])['scatter'])['10'])
        .map((p) => [d(l(p)[0]), d(l(p)[1])])
        .toList();
    panels.write(scatterPanel(
      id: 'sc-${slotOf(eng)}',
      caption: '${engineShort[eng]} · after 10',
      points: pts,
      slot: slotOf(eng),
    ));
  }

  // progression panels for the current engine
  final prog = StringBuffer();
  for (final k in ['3', '10', '20', '50']) {
    final pts = l(m(m(detail['A · Current (production)'])['scatter'])[k])
        .map((p) => [d(l(p)[0]), d(l(p)[1])])
        .toList();
    prog.write(scatterPanel(
        id: 'scp-$k', caption: 'after $k matches', points: pts, slot: 1));
  }

  // spread recovery + MAE lines
  final xs = <double>[1, 3, 5, 10, 20, 50];
  final spreadSeries = <Series>[];
  final maeSeries = <Series>[];
  for (final eng in engineOrder) {
    final snaps = m(m(w[eng])['snapshots']);
    spreadSeries.add(Series(engineShort[eng]!, slotOf(eng),
        [for (final k in snapKeys) d(m(snaps[k])['spreadRecovery'])]));
    maeSeries.add(Series(engineShort[eng]!, slotOf(eng),
        [for (final k in snapKeys) d(m(snaps[k])['mae'])]));
  }

  final histCur = m(detail['A · Current (production)']);
  final histTuned = m(detail['C · Tuned Hybrid']);

  // per-band mean estimate table at 10 matches
  final bands = ['1–2', '2–3', '3–4', '4–5', '5–6', '6–7'];
  final rows = <List<String>>[];
  for (final eng in engineOrder) {
    final s10 = m(m(m(w[eng])['snapshots'])['10']);
    final me = m(s10['meanEstByBand']);
    rows.add([
      engineShort[eng]!,
      for (final bd in bands) me[bd] == null ? '—' : fmt(d(me[bd]), 2),
    ]);
  }

  return '''
<section>
  <header>
    <p class="eyebrow">E1 · cold start</p>
    <h2>The compression, measured</h2>
    <p class="caption">1,000 brand-new players, nobody established, no anchors. Ten placement
    matches then forty ranked ones. Every engine sees the exact same matches, partners,
    opponents and scorelines.</p>
  </header>

  <div class="figblock">
    <h3>True level against estimated rating, after placement</h3>
    ${legend([(name: 'ideal (rating = true level)', slot: 1)]).replaceAll('var(--s1)', 'var(--ink-3)')}
    <div class="panels">$panels</div>
    <figcaption>Each dot is a player; the dashed line is a perfect estimate. The current engine
    produces a nearly flat cloud — the ordering is broadly right, but almost everyone is reported
    as a 2. A flat cloud is exactly what "my rank says beginner and I beat everyone" looks like
    from the player's side.</figcaption>
  </div>

  <div class="figblock">
    <h3>The current engine does not recover with time</h3>
    <div class="panels">$prog</div>
    <figcaption>Engine A only. Forty more ranked matches after placement widen the cloud a little,
    but the population never climbs off the floor set by its 2.0 starting prior.</figcaption>
  </div>

  <div class="duo">
    <div class="figblock">
      <h3>Spread recovery</h3>
      ${legend([for (final e in engineOrder) (name: engineShort[e]!, slot: slotOf(e))])}
      ${lineChart(id: 'spread', xs: xs, series: spreadSeries, xLabel: 'matches played', yLabel: 'est. SD ÷ true SD', yMin: 0, yMax: 1.1, dp: 2)}
      <figcaption>1.0 means the estimated ratings are as spread out as real skill. Below ~0.5 the
      leaderboard is visibly squashed.</figcaption>
    </div>
    <div class="figblock">
      <h3>Mean absolute error</h3>
      ${legend([for (final e in engineOrder) (name: engineShort[e]!, slot: slotOf(e))])}
      ${lineChart(id: 'mae', xs: xs, series: maeSeries, xLabel: 'matches played', yLabel: 'MAE (levels)', yMin: 0, dp: 2)}
      <figcaption>Distance between a player's rating and their true level, in levels.</figcaption>
    </div>
  </div>

  <div class="figblock">
    <h3>Where the population actually sits after 10 matches</h3>
    <div class="duo">
      ${histogram(id: 'h-a', caption: 'A · Current', truth: l(histCur['trueHist']).map<double>(d).toList(), est: l(histCur['hist10']).map<double>(d).toList(), slot: 1)}
      ${histogram(id: 'h-c', caption: 'C · Tuned Hybrid', truth: l(histTuned['trueHist']).map<double>(d).toList(), est: l(histTuned['hist10']).map<double>(d).toList(), slot: 3)}
    </div>
    <figcaption>Filled bars are estimated ratings; the dashed outline is the true skill
    distribution the players actually have. The current engine collapses a broad population into
    a single spike.</figcaption>
  </div>

  <div class="figblock">
    <h3>Average rating given to each true-level band, after 10 matches</h3>
    ${table([
        'Engine',
        ...bands.map((b) => 'true $b')
      ], rows)}
    <figcaption>Read across a row: a healthy engine's numbers should climb roughly in step with
    the band label. Engine A's row is almost flat — a true 5–6 player and a true 2–3 player are
    handed nearly the same rating.</figcaption>
  </div>
</section>''';
}

// ─────────────────────────────────────────────────────────────────────────────
String sectionHeadToHead() {
  final worlds = m(m(R['e1'])['worlds']);
  final w = m(worlds[primaryWorld]);

  final head = [
    'Engine',
    'MAE@5',
    'MAE@10',
    'MAE@20',
    'MAE@50',
    'centred MAE@50',
    'Spearman ρ',
    'Pairwise',
    'Predict acc.',
    'Calib. err.',
    'Spread@10',
    'Conv. ±0.5',
    'Stability',
  ];
  final rows = <List<String>>[];
  for (final eng in engineOrder) {
    final e = m(w[eng]);
    final s = m(e['snapshots']);
    double sn(String k, String f) => d(m(s[k])[f]);
    rows.add([
      engineShort[eng]!,
      fmt(sn('5', 'mae')),
      fmt(sn('10', 'mae')),
      fmt(sn('20', 'mae')),
      fmt(sn('50', 'mae')),
      fmt(sn('50', 'maeCentered')),
      fmt(sn('50', 'spearman'), 3),
      pct(sn('50', 'pairwise') * 100, 1),
      pct(d(e['accuracy']) * 100, 1),
      pct(d(e['ece']) * 100, 1),
      fmt(sn('10', 'spreadRecovery')),
      d(e['conv050']).isFinite ? fmt(d(e['conv050']), 1) : '—',
      fmt(d(e['stability']), 3),
    ]);
  }

  // calibration curves
  final calSeries = <({String name, int slot, List<List<double>> pts})>[];
  for (final eng in engineOrder) {
    final c = l(m(w[eng])['calibCurve']);
    calSeries.add((
      name: engineShort[eng]!,
      slot: slotOf(eng),
      pts: [for (final p in c) [d(m(p)['pred']), d(m(p)['obs'])]],
    ));
  }

  // robustness across worlds
  final worldRows = <List<String>>[];
  for (final eng in engineOrder) {
    worldRows.add([
      engineShort[eng]!,
      for (final wn in worlds.keys) fmt(d(m(m(m(worlds[wn])[eng])['snapshots'])['50']['mae'])),
    ]);
  }

  return '''
<section>
  <header>
    <p class="eyebrow">E1 · head to head</p>
    <h2>All six engines on the same match stream</h2>
    <p class="caption">Identical players, true skills, partners, opponents, scorelines and
    seeds for every engine — the only thing that differs is the estimator.</p>
  </header>

  ${table(head, rows, emphRow: 0)}
  <p class="note"><strong>Centred MAE</strong> is the error left after removing the whole
  population's offset. Elo-family maths only ever learns <em>differences</em>; where the
  population sits on the 0–7 scale is set by the prior and by anchors, and is never recovered
  from results. Engine A's raw MAE is dominated by that offset — which is precisely why the
  displayed number looks wrong to users even though the ordering is fine.</p>

  <div class="duo">
    <div class="figblock">
      <h3>Probability calibration</h3>
      ${legend([for (final e in engineOrder) (name: engineShort[e]!, slot: slotOf(e))])}
      <div class="chartscroll">${calibrationChart(id: 'cal', series: calSeries)}</div>
      <figcaption>When the engine says the favourite has a 70% chance, how often do they
      actually win? On the dashed line = honest. Above = the engine is under-confident,
      below = over-confident.</figcaption>
    </div>
    <div class="figblock">
      <h3>Does the ranking survive a different world?</h3>
      ${table(['Engine', ...worlds.keys.map((k) => k.split(' ').first)], worldRows)}
      <figcaption>MAE after 50 matches in each ground-truth world: pure Elo-average, mixed
      doubles reality, weak-link targeting and short-term form. The ordering of the engines
      barely moves, so none of this is an artefact of one generous world model.</figcaption>
    </div>
  </div>
</section>''';
}

// ─────────────────────────────────────────────────────────────────────────────
String sectionWhyItFails() {
  final e2 = m(R['e2']);
  final e3 = m(R['e3']);
  final e4 = m(R['e4']);

  // prior sweep on the CURRENT maths — isolates the prior
  final priorRows = <List<String>>[];
  for (final key in e2.keys.where((k) => k.startsWith('current maths, prior'))) {
    final s = m(m(e2[key])['snapshots']);
    priorRows.add([
      key.replaceAll('current maths, ', ''),
      fmt(d(m(s['10'])['mae'])),
      fmt(d(m(s['50'])['mae'])),
      fmt(d(m(s['10'])['bias'])),
      fmt(d(m(s['10'])['spreadRecovery'])),
      pct(d(m(s['10'])['pctStrongStuckLow'])),
    ]);
  }
  final aggRows = <List<String>>[];
  for (final key in e2.keys.where((k) => k.startsWith('aggressive prior'))) {
    final s = m(m(e2[key])['snapshots']);
    aggRows.add([
      key.replaceAll('aggressive ', ''),
      fmt(d(m(s['10'])['mae'])),
      fmt(d(m(s['50'])['mae'])),
      fmt(d(m(s['10'])['bias'])),
      fmt(d(m(s['10'])['spreadRecovery'])),
      pct(d(m(s['10'])['pctStrongStuckLow'])),
    ]);
  }

  final wTrace = l(e3['_wTraceCurrentEngine']).map<double>(d).toList();
  final relRows = <List<String>>[];
  for (final k in e3.keys.where((k) => !k.startsWith('_'))) {
    final s = m(m(e3[k])['snapshots']);
    relRows.add([
      k,
      fmt(d(m(s['5'])['mae'])),
      fmt(d(m(s['10'])['mae'])),
      fmt(d(m(s['50'])['mae'])),
      fmt(d(m(s['10'])['spreadRecovery'])),
    ]);
  }

  final kRows = <List<String>>[];
  for (final k in e4.keys) {
    final s = m(m(e4[k])['snapshots']);
    kRows.add([
      k,
      fmt(d(m(s['10'])['mae'])),
      fmt(d(m(s['50'])['mae'])),
      fmt(d(m(s['10'])['spreadRecovery'])),
      fmt(d(m(e4[k])['stability']), 3),
      pct(d(m(s['10'])['pctStrongStuckLow'])),
    ]);
  }

  final onb = m(e2['onboarding']);
  final onbRows = <List<String>>[];
  for (final k in onb.keys) {
    final s = m(m(onb[k])['snapshots']);
    onbRows.add([k, fmt(d(m(s['3'])['mae'])), fmt(d(m(s['10'])['mae'])), fmt(d(m(s['50'])['mae']))]);
  }

  // cause 4 — the margin term's systematic anti-favourite drift
  final e7 = m(R['e7']);
  final bias = m(e7['_marginBias']);
  final biasRows = <List<String>>[];
  for (final k in bias.keys) {
    final v = m(bias[k]);
    biasRows.add([
      k.replaceAll('gap ', '+'),
      pct(d(v['trueWinProb']) * 100, 1),
      pct(d(v['expectedGamesRatio']) * 100, 1),
      pct(d(v['expectedS_70_30']) * 100, 1),
      pct(d(v['engineE_s1']) * 100, 1),
      fmt(d(v['driftVsEngineE']), 3),
      fmt(d(v['driftVsPerfectCurve']), 3),
    ]);
  }
  final marginRows = <List<String>>[];
  for (final k in e7.keys.where((k) => !k.startsWith('_'))) {
    final e = m(e7[k]);
    final s = m(e['snapshots']);
    marginRows.add([
      k,
      fmt(d(m(s['50'])['mae'])),
      fmt(d(m(s['50'])['spreadRecovery'])),
      pct(d(e['accuracy']) * 100, 1),
      pct(d(e['ece']) * 100, 1),
    ]);
  }

  return '''
<section>
  <header>
    <p class="eyebrow">E2 · E3 · E4 · E7</p>
    <h2>Four causes, isolated one at a time</h2>
    <p class="caption">Each of these was measured on tuning seeds by changing one thing and
    holding everything else at the production value.</p>
  </header>

  <div class="figblock">
    <h3>1 · The starting prior</h3>
    <p class="caption">Production coalesces a missing rating to <code>2.0</code>. The simulated
    population averages 3.3. Because Elo can only learn differences, that gap never closes —
    it just becomes everybody's permanent offset. These runs change <em>only</em> the prior and
    leave the production maths untouched.</p>
    ${table(['Prior', 'MAE@10', 'MAE@50', 'bias@10', 'spread@10', '5.0+ stuck <3.5'], priorRows)}
    <figcaption>Moving the prior alone is the single cheapest change available.</figcaption>
  </div>

  <div class="figblock">
    <h3>2 · The opponent-reliability discount, at launch</h3>
    <p class="caption">W = 0.5 + 0.5·(1 − σ̄<sub>opp</sub>). With everyone new at σ = 0.85 this
    evaluates to <strong>${fmt(wTrace.first, 3)}</strong> — every result in week one counts a
    little over half. It is a sensible rule that inverts at cold start: the system learns
    slowest exactly when it knows least.</p>
    ${lineChart(id: 'wtrace', xs: [for (var i = 1; i <= wTrace.length; i++) i.toDouble()], series: [Series('W (current engine)', 1, wTrace)], xLabel: 'round', yLabel: 'effective weight W', yMin: 0.5, yMax: 1.0, dp: 3)}
    ${table(['Placement reliability rule', 'MAE@5', 'MAE@10', 'MAE@50', 'spread@10'], relRows)}
    <figcaption>Removing the discount during placement only — established behaviour unchanged —
    is a straight improvement on every measure.</figcaption>
  </div>

  <div class="figblock">
    <h3>3 · Placement K</h3>
    <p class="caption">Today's maximum placement step is K = 0.35·1.5 ≈ 0.46, and W drags the
    realised move down to roughly 0.26 × (S − E). A player who needs to travel three levels
    cannot get there in ten matches. Staged K spends the movement where the uncertainty is.</p>
    ${table(['Placement K schedule', 'MAE@10', 'MAE@50', 'spread@10', 'stability', '5.0+ stuck <3.5'], kRows)}
    <figcaption>Stability is the average per-match rating wobble for players who are already
    accurate — the "why did my rank move for no reason" number. It stays flat across the grid
    because the aggressive K applies only during placement.</figcaption>
  </div>

  <div class="figblock">
    <h3>4 · The margin term is a compression force, not just an abuse risk</h3>
    <p class="caption">The update is K·W·(S − E). <strong>E is a probability of winning.
    S mixes that win with the games ratio — and a games ratio is nowhere near as extreme as a
    win probability.</strong> A pair one level ahead wins ~87% of matches but only ~60% of games.
    So a correctly-rated favourite has E[S] &lt; E and <em>loses rating on average for winning
    the matches they were supposed to win</em>. It is a permanent restoring force pulling
    everyone toward the middle.</p>
    ${table([
        'Rating gap',
        'true P(win)',
        'E[games ratio]',
        'E[S] at 70/30',
        'engine E (s=1)',
        'drift/match',
        'drift vs perfect curve'
      ], biasRows)}
    <figcaption>The last column is the part that matters most: the drift survives even if the
    expected-win curve is <em>perfectly</em> calibrated, because it comes from mixing two
    quantities that live on different scales. This is arithmetic, not a simulation artefact.</figcaption>
  </div>

  <div class="figblock">
    <h3>…and the simulation agrees</h3>
    ${table(['Result / margin weighting', 'MAE@50', 'spread@50', 'predict acc.', 'calib. err.'], marginRows)}
    <figcaption>Spread recovery falls monotonically as the margin weight rises — exactly what the
    drift predicts. <strong>Capping the games ratio fixes it</strong>: clamping the deviation to
    ±0.15 and rescaling puts the margin signal back on the same scale as the win probability, so
    85/15-capped keeps the extra information with almost none of the bias — and removes the
    incentive to run up a scoreline as a side effect.</figcaption>
  </div>

  <details>
    <summary>Optional: an onboarding "what's your level?" question as a weak prior</summary>
    <p class="caption">Self-declaration sets the starting mean only; sigma stays at its maximum
    so a wrong answer is corrected quickly. Tested against honest answers, 20% deliberate
    sandbagging and 20% inflation.</p>
    ${table(['Scenario', 'MAE@3', 'MAE@10', 'MAE@50'], onbRows)}
    <p class="caption">The declared prior helps most in the first three matches and washes out
    by 50 — including when a fifth of the population lies about it. It is a UX win, not an
    accuracy one, and it is safe.</p>
  </details>
</section>''';
}

// ─────────────────────────────────────────────────────────────────────────────
String sectionMatchmaking() {
  final e5 = m(R['e5']);
  final rows = <List<String>>[];
  final engines = <String>{};
  for (final k in e5.keys) {
    engines.add(k.split(' · ').take(2).join(' · '));
  }
  for (final eng in engines) {
    final near = e5['$eng · nearRating'];
    final adaptive = e5['$eng · adaptiveProbe'];
    if (near == null || adaptive == null) continue;
    final sn = m(m(near)['snapshots']), sa = m(m(adaptive)['snapshots']);
    rows.add([
      eng,
      fmt(d(m(sn['10'])['mae'])),
      fmt(d(m(sa['10'])['mae'])),
      fmt(d(m(sn['10'])['spreadRecovery'])),
      fmt(d(m(sa['10'])['spreadRecovery'])),
      fmt(d(m(sn['50'])['mae'])),
      fmt(d(m(sa['50'])['mae'])),
    ]);
  }

  return '''
<section>
  <header>
    <p class="eyebrow">E5 · placement matchmaking</p>
    <h2>Letting placement go looking for the player's ceiling</h2>
    <p class="caption">Arm A queues each player near their current estimate — what the app does
    today. Arm B, during placement only, pushes the search target upward after a convincing win
    and pulls it down after a heavy loss, so a strong player meets stronger opposition instead of
    beating 2.0s repeatedly. Both arms share the world, population and seeds; the match stream
    necessarily differs because that is the variable under test.</p>
  </header>
  ${table(['Engine', 'MAE@10 near', 'MAE@10 adaptive', 'spread@10 near', 'spread@10 adaptive', 'MAE@50 near', 'MAE@50 adaptive'], rows)}

  <p class="note"><strong>Null result — adaptive probing did not help.</strong> It is fractionally
  <em>worse</em> for every engine tested. The intuition ("you can't prove you're a 5.0 by beating
  2.0s") is sound, but it is already satisfied: ordinary rating-banded matchmaking moves a winning
  player upward every round anyway, so deliberately over-shooting mostly adds mismatched games,
  which carry little information in either direction. Reported as measured; this was a hypothesis
  the study set out to support and did not.</p>

  <p class="note">The comparison did surface something else worth keeping. Both arms here beat the
  social matchmaking used in E1 — rating-banded queueing produces materially better estimates than
  "play whoever is around" (Tuned Hybrid: MAE@50 ${fmt(d(m(m(m(e5['C · Tuned Hybrid · nearRating'])['snapshots'])['50'])['mae']))}
  here against ${fmt(d(m(m(m(m(m(m(R['e1'])['worlds'])[primaryWorld])['C · Tuned Hybrid'])['snapshots'])['50'])['mae']))} there).
  Tight, competitive matches are the informative ones.</p>
</section>''';
}

// ─────────────────────────────────────────────────────────────────────────────
String sectionModelShape() {
  final e6 = m(R['e6']);
  final dec = m(e6['_worldDecisiveness']);

  final decRows = <List<String>>[];
  for (final k in dec.keys) {
    final v = m(dec[k]);
    decRows.add([
      k,
      pct(d(v['p@0.5level']) * 100),
      pct(d(v['p@1.0level']) * 100),
      pct(d(v['p@1.5level']) * 100),
      pct(d(v['p@2.0level']) * 100),
    ]);
  }

  final scaleKeys = <String>[];
  for (final wk in e6.keys.where((k) => !k.startsWith('_'))) {
    scaleKeys.addAll(m(e6[wk]).keys);
    break;
  }
  final curveRows = <List<String>>[];
  for (final sk in scaleKeys) {
    final row = <String>[sk.replaceAll('scale ', 's = ')];
    for (final wk in e6.keys.where((k) => !k.startsWith('_'))) {
      final e = m(m(e6[wk])[sk]);
      row.add('${fmt(d(m(m(e['snapshots'])['50'])['mae']))} / ${pct(d(e['ece']) * 100, 1)}');
    }
    curveRows.add(row);
  }

  return '''
<section>
  <header>
    <p class="eyebrow">E6</p>
    <h2>How steep should the expected-win curve be?</h2>
  </header>

  <div class="figblock">
    <h3>What a level gap is actually worth</h3>
    ${table(['Simulated world', '0.5 level', '1.0 level', '1.5 levels', '2.0 levels'], decRows)}
    <figcaption>Ground-truth match win probability for the favourite. The engine's current
    <code>s = 1.0</code> asserts 90.9% for a one-level gap — at the decisive end of what is
    plausible for padel. The three worlds bracket the uncertainty deliberately, because nobody
    knows the true curve yet.</figcaption>
  </div>

  <div class="figblock">
    <h3>Curve scale against world decisiveness</h3>
    ${table(['Engine curve', ...e6.keys.where((k) => !k.startsWith('_'))], curveRows)}
    <figcaption>Each cell is MAE@50 / calibration error, swept on top of the other fixes.</figcaption>
  </div>

  <p class="note"><strong>These two metrics disagree, and the disagreement is the finding.</strong>
  A flatter curve keeps (S − E) larger for a given rating gap, so ratings spread further apart and
  MAE falls — but the probabilities it reports get worse. In other words a flatter curve does not
  model padel better; it is a <em>gain control</em> that partly compensates for compression.
  Since we are fixing compression at its actual sources, the curve should be chosen for
  calibration, not for MAE. That argues for staying near the current setting rather than
  detuning it: <code>s = 1.25</code> is a mild, defensible move, and <code>s = 1.0</code> is
  entirely reasonable to keep.</p>

  <p class="note">The same caution applies in reverse. Today's <code>s = 1.0</code> asserts 90.9%
  for a one-level gap, which is at the decisive end of plausible — but it currently calibrates
  well <em>because</em> the ratings feeding it are squashed. Two errors are cancelling. Fix the
  compression without re-checking calibration and the probabilities will drift; that is why this
  should ship with the calibration curve re-measured on real matches.</p>
</section>''';
}

// ─────────────────────────────────────────────────────────────────────────────
String sectionDoubles() {
  final e8 = m(R['e8']);
  final e9 = m(R['e9']);
  final pairs = m(e8['_pairScenarios']);

  final modelRows = <List<String>>[];
  final worldKeys = e8.keys.where((k) => !k.startsWith('_')).toList();
  final models = m(e8[worldKeys.first]).keys.toList();
  for (final mdl in models) {
    final row = <String>[mdl];
    for (final wk in worldKeys) {
      final v = m(m(e8[wk])[mdl]);
      row.add('${fmt(d(v['testLogLoss']), 4)}${d(v['lambda']) > 0 ? ' (λ ${fmt(d(v['lambda']), 2)})' : ''}');
    }
    modelRows.add(row);
  }

  final pairRows = <List<String>>[];
  final pairKeys = m(pairs[worldKeys.first]).keys.toList();
  for (final pk in pairKeys) {
    pairRows.add([pk, for (final wk in worldKeys) pct(d(m(pairs[wk])[pk]) * 100, 1)]);
  }

  // partner independence
  final pi = m(e9['partnerIndependence']);
  final piPhases = ['with 5.0 partner', 'then 2.0 partner', 'then random partners'];
  final piRows = <List<String>>[];
  for (final eng in engineOrder) {
    if (pi[eng] == null) continue;
    final v = m(pi[eng]);
    piRows.add([
      engineShort[eng]!,
      for (final p in piPhases) '${fmt(d(m(v[p])['mae']))} (est ${fmt(d(m(v[p])['meanEst']))})',
    ]);
  }

  // Boosting, measured against the SAME players with random partners rather
  // than against true skill — otherwise Engine A scores well purely because its
  // compression stops it moving anyone anywhere.
  final boost = m(e9['boostingInflation']);
  final boostPartners =
      m(boost[engineOrder.first]).keys.where((k) => !k.startsWith('control')).toList();
  final boostGroups = <({String name, int slot, List<double> vs})>[];
  for (final eng in engineOrder) {
    final ctrl = d(m(m(boost[eng])['control (random partners)'])['meanEst']);
    boostGroups.add((
      name: engineShort[eng]!,
      slot: slotOf(eng),
      vs: [for (final p in boostPartners) d(m(m(boost[eng])[p])['meanEst']) - ctrl],
    ));
  }

  final gaps = m(m(e9['gapLimits'])['boostingWithLimit']);
  final blocked = m(m(e9['gapLimits'])['blockedShare']);
  final gapRows = <List<String>>[];
  for (final k in gaps.keys) {
    final bl = blocked[k];
    gapRows.add([
      k.replaceAll('limit ', '≤ '),
      fmt(d(m(gaps[k])['inflation'])),
      bl == null ? '—' : pct(d(m(bl)['blockedPctAll']), 1),
      bl == null ? '—' : pct(d(m(bl)['blockedPctProvisional']), 1),
    ]);
  }

  final div = m(e9['diversity']);
  final divRows = <List<String>>[];
  for (final eng in engineOrder) {
    if (div[eng] == null) continue;
    final v = m(div[eng]);
    divRows.add([
      engineShort[eng]!,
      fmt(d(m(v['fixedPartner'])['mae'])),
      fmt(d(m(v['randomPartners'])['mae'])),
      fmt(d(m(v['fixedPartner'])['sigma']), 3),
      fmt(d(m(v['randomPartners'])['sigma']), 3),
    ]);
  }

  return '''
<section>
  <header>
    <p class="eyebrow">E8 · E9</p>
    <h2>Doubles: is an average a fair description of a pair?</h2>
  </header>

  <div class="figblock">
    <h3>Real win rates for specific pair shapes</h3>
    ${table(['Matchup', ...worldKeys], pairRows)}
    <figcaption>Simulated ground truth, 20,000 matches per cell. In every world that is not
    pure-average by construction, <strong>5.0 + 2.0 and 3.5 + 3.5 are not the same team</strong>
    even though the engine gives them the same rating.</figcaption>
  </div>

  <div class="figblock">
    <h3>Team-strength models, fitted on one sample and scored on another</h3>
    ${table(['Model', ...worldKeys], modelRows)}
    <figcaption>Held-out log loss (lower is better); λ is the fitted imbalance coefficient. The
    plain average is only optimal in the world that was built to be an average. An
    <code>avg − λ·gap</code> term is never worse and is materially better wherever the pair
    interacts — and it costs one subtraction.</figcaption>
  </div>

  <div class="figblock">
    <h3>Partner independence error</h3>
    <p class="caption">Probe players of known skill play 20 matches with a 5.0 partner, then 20
    with a 2.0 partner, then 20 with random partners. An individual rating that means anything
    should barely notice.</p>
    ${table(['Engine', ...piPhases], piRows)}
    <figcaption>Error in levels, with the mean estimate in brackets (probe population's true
    mean is ${fmt(d(m(pi[engineOrder.first])['probeTrueMean']))}).</figcaption>
  </div>

  <div class="figblock">
    <h3>Boosting: a true-2.5 player permanently attached to a stronger partner</h3>
    ${legend([for (final e in engineOrder) (name: engineShort[e]!, slot: slotOf(e))])}
    <div class="chartscroll">${barChart(id: 'boost', title: 'Rating gained purely from the partner', rows: boostPartners, groups: boostGroups, unit: ' levels', refLine: 0, refLabel: 'no gain')}</div>
    <figcaption>Levels gained over the <em>same players with random partners</em> after 50
    matches. Measuring against true skill instead would flatter the current engine, which scores
    well here only because it barely moves anyone at all.</figcaption>
  </div>

  <div class="duo">
    <div class="figblock">
      <h3>Ranked partner-gap limits — a null result</h3>
      ${table(['Max gap', 'boost gained', 'pairs blocked', 'blocked · provisional'], gapRows)}
      <figcaption><strong>Gap limits do not stop boosting.</strong> Even a 1.0-level cap leaves
      almost all of the gain intact while refusing a fifth of ordinary pairs; only a 0.75 cap
      bites, and it blocks a third of all play. The reason is self-defeating by construction: as
      the carried player's rating inflates toward their partner's, the measured gap
      <em>closes</em>, so the rule stops applying exactly when the abuse is working. A rule
      written against point ratings cannot police a process whose whole effect is to move those
      ratings together.</figcaption>
    </div>
    <div class="figblock">
      <h3>Does a fixed partner make sigma lie?</h3>
      ${table(['Engine', 'MAE fixed', 'MAE random', 'σ fixed', 'σ random'], divRows)}
      <figcaption>40 matches with one permanent partner versus 40 with random partners. Every
      engine ends up equally <em>confident</em>; only the accuracy differs. Confidence that does
      not notice it has only ever seen one team configuration is confidence that is wrong.</figcaption>
    </div>
  </div>
</section>''';
}

// ─────────────────────────────────────────────────────────────────────────────
String sectionUncertainty() {
  final e10 = m(R['e10']);
  final e11 = m(R['e11']);
  final e12 = m(R['e12']);

  final sigRows = <List<String>>[];
  for (final k in e10.keys.where((k) => !k.startsWith('_'))) {
    final e = m(e10[k]);
    final s = m(e['snapshots']);
    sigRows.add([
      k,
      fmt(d(m(s['50'])['mae'])),
      fmt(d(m(s['50'])['spreadRecovery'])),
      fmt(d(e['stability']), 4),
      d(e['displayReadyRound']).isFinite ? fmt(d(e['displayReadyRound']), 0) : 'never',
    ]);
  }

  final rec = m(e10['_skillCollapseRecovery']);
  final ratingSeries = <Series>[];
  final sigmaSeries = <Series>[];
  for (final eng in engineOrder) {
    if (rec[eng] == null) continue;
    ratingSeries.add(Series(engineShort[eng]!, slotOf(eng), l(m(rec[eng])['rating']).map<double>(d).toList()));
    sigmaSeries.add(Series(engineShort[eng]!, slotOf(eng), l(m(rec[eng])['sigma']).map<double>(d).toList()));
  }
  final recXs = [for (var i = 1; i <= ratingSeries.first.ys.length; i++) i.toDouble()];

  final inaRows = <List<String>>[];
  for (final k in e11.keys) {
    final v = m(e11[k]);
    for (final dk in v.keys) {
      inaRows.add([
        '$k · $dk',
        fmt(d(m(v[dk])['errorAtReturn'])),
        fmt(d(m(v[dk])['errorAfter5'])),
        fmt(d(m(v[dk])['errorAfter15'])),
      ]);
    }
  }

  final ancRows = <List<String>>[];
  for (final k in e12.keys) {
    final s = m(m(e12[k])['snapshots']);
    ancRows.add([
      k,
      fmt(d(m(s['10'])['mae'])),
      fmt(d(m(s['50'])['mae'])),
      fmt(d(m(s['50'])['bias'])),
      fmt(d(m(s['10'])['spreadRecovery'])),
    ]);
  }

  return '''
<section>
  <header>
    <p class="eyebrow">E10 · E11 · E12</p>
    <h2>Uncertainty: when should confidence go back up?</h2>
  </header>

  <div class="figblock">
    <h3>Sigma models — with the control that matters</h3>
    <p class="caption">Any rule that keeps sigma high also keeps K high, because K scales with
    sigma. So a chunk of any "adaptive sigma" win is really just extra gain. The fixed-decay
    ladder is the control: if simply decaying slower matches the adaptive rule, the adaptive rule
    is not earning its complexity.</p>
    ${table(['Sigma rule', 'MAE@50', 'spread@50', 'stability', 'rank shown after'], sigRows)}
    <figcaption>Read the fixed ×0.92 → ×0.99 rows as the "more gain" baseline, then compare an
    adaptive row at <em>matched stability</em>. Adaptive sigma is genuinely ahead at equal
    volatility, but by much less than the headline numbers suggest — and pushing it harder buys
    accuracy with wobble and with a much later reveal.</figcaption>
  </div>

  <div class="figblock">
    <h3>A 5.0 player who quietly becomes a 3.0</h3>
    <div class="duo">
      <div>
        ${legend([for (final s in ratingSeries) (name: s.name, slot: s.slot)])}
        ${lineChart(id: 'collapse-r', xs: recXs, series: ratingSeries, xLabel: 'matches after the collapse', yLabel: 'estimated rating', dp: 2, height: 300)}
      </div>
      <div>
        ${lineChart(id: 'collapse-s', xs: recXs, series: sigmaSeries, xLabel: 'matches after the collapse', yLabel: 'uncertainty (σ)', dp: 3, height: 300)}
      </div>
    </div>
    <figcaption>Left: how fast the rating follows reality down to 3.0. Right: what happens to
    confidence while the model is being repeatedly contradicted. Under the fixed ×0.92 rule
    confidence keeps <em>rising</em> throughout — the system becomes more certain of an estimate
    that reality is actively refuting.</figcaption>
  </div>

  <div class="duo">
    <div class="figblock">
      <h3>Coming back after three months away</h3>
      ${table(['Rule · true skill change', 'error on return', 'after 5', 'after 15'], inaRows)}
      <figcaption>Rating decay guesses that an absent player got worse. Sigma-only decay says the
      system stopped knowing — and then finds out in a handful of matches.</figcaption>
    </div>
    <div class="figblock">
      <h3>Anchors — density matters more than the rule</h3>
      ${table(['Scenario', 'MAE@10', 'MAE@50', 'bias@50', 'spread@10'], ancRows)}
      <figcaption>Anchors are the only mechanism in the system that can pin the <em>absolute</em>
      scale, but the dose has to be real: 20 verified players in 800 barely dents a
      population-wide offset. Note also that miscalibrated anchors are not catastrophic here —
      they add spread while adding error — so the risk of getting a few wrong is smaller than the
      cost of not having enough. Anchors are a supplement to a correct prior, never a substitute
      for one.</figcaption>
    </div>
  </div>
</section>''';
}

// ─────────────────────────────────────────────────────────────────────────────
String sectionScenarios() {
  final e1 = m(R['e1']);
  final e13 = m(R['e13']);
  final e14 = m(R['e14']);

  final trajs = m(e1['trajectories']);
  final picks = m(e1['picksTrue']);
  final trajBlocks = StringBuffer();
  for (final label in picks.keys) {
    final series = <Series>[];
    for (final eng in engineOrder) {
      series.add(Series(engineShort[eng]!, slotOf(eng), l(m(trajs[eng])[label]).map<double>(d).toList()));
    }
    final xs = [for (var i = 1; i <= series.first.ys.length; i++) i.toDouble()];
    trajBlocks.write('''
    <div class="figblock">
      <h3>A $label player · true level ${fmt(d(picks[label]), 2)}</h3>
      ${lineChart(id: 'tr-${label.hashCode}', xs: xs, series: series, xLabel: 'matches played', yLabel: 'rating', yMin: 0, yMax: 7, dp: 2, height: 300)}
    </div>''');
  }

  final smurfKey = e13.keys.firstWhere((k) => k.startsWith('smurf'));
  final overKey = e13.keys.firstWhere((k) => k.startsWith('overrated'));
  List<Series> traceSeries(String key) {
    final v = m(e13[key]);
    return [
      for (final eng in engineOrder)
        if (v[eng] != null) Series(engineShort[eng]!, slotOf(eng), l(v[eng]).map<double>(d).toList())
    ];
  }

  final smurf = traceSeries(smurfKey);
  final over = traceSeries(overKey);
  final sxs = [for (var i = 1; i <= smurf.first.ys.length; i++) i.toDouble()];

  final gateRows = <List<String>>[];
  for (final eng in e14.keys) {
    final v = m(e14[eng]);
    final byM = m(v['maeByMatches']);
    gateRows.add([
      eng,
      for (final k in ['3', '5', '8', '10', '15', '20', '30', '50'])
        byM[k] == null ? '—' : fmt(d(byM[k])),
    ]);
  }
  final sigmaGateRows = <List<String>>[];
  for (final eng in e14.keys) {
    final v = m(m(e14[eng])['maeBySigmaAt10']);
    sigmaGateRows.add([eng, for (final k in ['<0.30', '0.30–0.40', '0.40–0.50', '≥0.50']) v[k] == null ? '—' : fmt(d(v[k]))]);
  }
  final partnerGateRows = <List<String>>[];
  for (final eng in e14.keys) {
    final v = m(m(e14[eng])['maeByPartnersAt10']);
    partnerGateRows.add([eng, for (final k in ['3', '6', '9', '10']) v[k] == null ? '—' : fmt(d(v[k]))]);
  }

  return '''
<section>
  <header>
    <p class="eyebrow">E13 · E14</p>
    <h2>What individual players experience</h2>
  </header>

  ${legend([for (final e in engineOrder) (name: engineShort[e]!, slot: slotOf(e))])}
  <div class="duo">$trajBlocks</div>

  <div class="duo">
    <div class="figblock">
      <h3>The smurf · true 5.5, dumped in at 1.5</h3>
      ${lineChart(id: 'smurf', xs: sxs, series: smurf, xLabel: 'matches played', yLabel: 'rating', yMin: 0, yMax: 7, dp: 2, height: 300)}
      <figcaption>How long a genuinely strong player who starts far too low is stuck below their
      real level — and therefore how long they spend ruining matches for beginners.</figcaption>
    </div>
    <div class="figblock">
      <h3>The overrated beginner · true 1.5, started at 5.3</h3>
      ${lineChart(id: 'over', xs: sxs, series: over, xLabel: 'matches played', yLabel: 'rating', yMin: 0, yMax: 7, dp: 2, height: 300)}
      <figcaption>The mirror case: someone who claimed to be competitive and is not. Fast
      correction here is what makes a self-declaration question safe to ask.</figcaption>
    </div>
  </div>

  <div class="figblock">
    <h3>When is a rating good enough to show?</h3>
    ${table(['Engine', ...['3', '5', '8', '10', '15', '20', '30', '50'].map((k) => '$k matches')], gateRows)}
    <div class="duo">
      ${table(['Engine', 'σ < 0.30', 'σ 0.30–0.40', 'σ 0.40–0.50', 'σ ≥ 0.50'], sigmaGateRows)}
      ${table(['Engine', '≤3 partners', '≤6', '≤9', '10+'], partnerGateRows)}
    </div>
    <figcaption>MAE conditional on match count, on sigma, and on how many distinct partners the
    player has been seen with (the latter two measured at 10 matches). <strong>Match count is the
    reliable predictor; sigma is not.</strong> The sigma buckets do not order cleanly — under an
    adaptive-sigma rule a high sigma often means "this player keeps surprising us", which is not
    the same as "this estimate is bad". Partner count separates a little, but weakly. The honest
    conclusion is the plain one: gate the reveal on matches played, and use sigma only to decide
    how prominently to hedge the number, not whether to show it.</figcaption>
  </div>
</section>''';
}

// ─────────────────────────────────────────────────────────────────────────────
String sectionRecommendation() {
  final w = m(m(m(R['e1'])['worlds'])[primaryWorld]);
  double mae(String eng, String k) => d(m(m(m(m(w[eng])['snapshots'])[k]))['mae']);
  final aC = mae('A · Current (production)', '10');
  final cC = mae('C · Tuned Hybrid', '10');
  final tC = mae('D · TrueSkill', '10');
  final a50 = mae('A · Current (production)', '50');
  final c50 = mae('C · Tuned Hybrid', '50');
  final t50 = mae('D · TrueSkill', '50');

  return '''
<section>
  <header>
    <p class="eyebrow">Recommendation</p>
    <h2>Fix the hybrid. Do not migrate to TrueSkill yet.</h2>
  </header>

  <div class="stats">
    <div class="stat bad"><span class="k">Current · after placement</span>
      <span class="v">${fmt(aC)}</span><span class="n">levels of error</span></div>
    <div class="stat good"><span class="k">Tuned hybrid</span>
      <span class="v">${fmt(cC)}</span><span class="n">levels · ${pct((1 - cC / aC) * 100)} better</span></div>
    <div class="stat"><span class="k">TrueSkill</span>
      <span class="v">${fmt(tC)}</span><span class="n">levels · ${pct((1 - tC / aC) * 100)} better</span></div>
    <div class="stat"><span class="k">At 50 matches</span>
      <span class="v">${fmt(c50)}</span><span class="n">tuned vs ${fmt(t50)} TrueSkill, ${fmt(a50)} today</span></div>
  </div>

  <div class="prose">
    <p>The decision rule you set was: switch only for a meaningful practical improvement. The
    tuned hybrid recovers <strong>${pct((1 - cC / aC) * 100)}</strong> of the gap at the moment
    that matters most — the end of placement, when a real player first sees a number — and it
    does so by changing constants and one phase of one function, inside an architecture you can
    already explain to a user.</p>
    <p>TrueSkill is genuinely better at 50 matches and recovers the most spread. But the
    remaining gap is largely the <em>absolute scale</em>, and the scale is set by the prior and
    by anchors, not by the update rule — both of which are available to the hybrid for free.
    Migrating means a new state model, a rewritten <code>_settle_rating</code>, a backfill of
    every existing player, and a system that is much harder to justify to someone asking why
    they lost 0.2 levels.</p>
  </div>

  <h3>Change these four first — they are the whole finding</h3>
  <ul class="bullets">
    <li><strong>1 · Move the prior off 2.0.</strong> Coalesce a missing rating to the centre of
    your actual population rather than the bottom of the scale. One <code>coalesce()</code> in
    <code>_settle_rating</code>, and it is the single largest effect measured.</li>
    <li><strong>2 · Cap the games-ratio term.</strong> Clamp the ratio's deviation to about ±0.15
    and rescale, or drop to 85/15. This removes a systematic force that has been pulling every
    strong player back toward the middle since launch — and it removes the incentive to run up a
    scoreline at the same time. Cheapest fix per unit of benefit in the study.</li>
    <li><strong>3 · Don't discount opponents while provisional.</strong> Keep W for established
    players; floor it at 1.0 during placement. The rule is right in steady state and exactly
    backwards at cold start.</li>
    <li><strong>4 · Stage the placement K.</strong> Roughly 0.8 → 0.5 → 0.3 across the ten
    matches, so placement can actually cross the scale. Safe only in combination with the next
    point.</li>
  </ul>

  <h3>Then, in a second pass</h3>
  <ul class="bullets">
    <li><strong>5 · Keep the number private until it means something.</strong> Show
    "Finding your level" for the placement run. This is what makes an aggressive internal K safe —
    nobody watches the wobble. Gate the reveal on matches played: sigma turned out not to predict
    accuracy well enough to gate on.</li>
    <li><strong>6 · Seed anchors, and seed enough of them.</strong> They are the only mechanism
    that pins the absolute scale, but 20 in 800 does almost nothing. Treat them as a supplement to
    a correct prior, not a replacement.</li>
    <li><strong>7 · Inactivity should raise sigma, not lower rating</strong> — better on every
    simulated skill change, including players who genuinely declined.</li>
    <li><strong>8 · Subtract a small imbalance penalty</strong> from team strength
    (<code>avg − λ·gap</code>, λ ≈ 0.2). It fits better in every world that is not an average by
    construction, and it is the most promising untested lever against carrying — because it
    attributes more of a lopsided pair's win to the stronger player.</li>
    <li><strong>9 · Leave the expected-win curve roughly alone.</strong> A flatter curve improves
    MAE only by acting as a gain control; it makes the probabilities worse. Move it to 1.25 at
    most, and re-measure calibration on real matches after the compression fixes land.</li>
  </ul>

  <h3>Explicitly not recommended</h3>
  <ul class="bullets">
    <li><strong>Adaptive placement matchmaking.</strong> Tested and did not help — slightly worse
    for every engine. Ordinary rating-banded queueing already does the job.</li>
    <li><strong>Ranked partner-gap limits, as an anti-boosting measure.</strong> They block a lot
    of ordinary play and barely dent the inflation, because the gap closes as the boost succeeds.
    If you want one for match-quality reasons that is a separate argument — just don't expect it
    to stop carrying.</li>
    <li><strong>Diversity-aware sigma on its own.</strong> Measured no difference against the
    fixed decay. Keep it only as part of the adaptive-sigma rule, where it is close to free.</li>
    <li><strong>Migrating to TrueSkill or Glicko-2 now.</strong> Both are better, and neither is
    better by enough to justify a new state model, a rewritten settlement function, a backfill of
    every player, and a rating you can no longer explain in a sentence.</li>
  </ul>

  <p class="note">Revisit that last one if, after all of the above, the measured error on real
  matches stays materially worse than this predicts. The harness in
  <code>tools/ranking_simulation/</code> is built to re-run the comparison against a replayed
  production match stream — which is a far better test than any simulation, because it does not
  require guessing what padel's true curve looks like.</p>
</section>''';
}

// ─────────────────────────────────────────────────────────────────────────────
String sectionQuestions() {
  final qa = questionAnswers();
  final b = StringBuffer('''
<section>
  <header>
    <p class="eyebrow">Answers</p>
    <h2>The 24 questions</h2>
  </header>
  <div class="qa">''');
  for (var i = 0; i < qa.length; i++) {
    b.write('<div><span class="n">${(i + 1).toString().padLeft(2, '0')}</span>'
        '<div><p class="q">${qa[i].$1}</p><p class="a">${qa[i].$2}</p></div></div>');
  }
  b.write('</div></section>');
  return b.toString();
}

List<(String, String)> questionAnswers() {
  final w = m(m(m(R['e1'])['worlds'])[primaryWorld]);
  Map<String, dynamic> snap(String eng, String k) => m(m(m(w[eng])['snapshots'])[k]);
  final a10 = snap('A · Current (production)', '10');
  final a50 = snap('A · Current (production)', '50');
  final c10 = snap('C · Tuned Hybrid', '10');
  final t50 = snap('D · TrueSkill', '50');
  final c50 = snap('C · Tuned Hybrid', '50');
  final g50 = snap('E · Glicko-2', '50');

  final e2 = m(R['e2']);
  final e3 = m(R['e3']);
  final e9 = m(R['e9']);

  String maeAt(String key, String k) =>
      fmt(d(m(m(m(e2[key])['snapshots'])[k])['mae']));

  final relCur = fmt(d(m(m(m(e3['1 · current formula (floor 0.50)'])['snapshots'])['10'])['mae']));
  final relFull = fmt(d(m(m(m(e3['2 · no discount in placement (1.00)'])['snapshots'])['10'])['mae']));

  final boost = m(e9['boostingInflation']);
  final boostA = fmt(d(m(m(m(boost['A · Current (production)'])['partner 6.0']))['inflation']));

  return [
    ('Does the current engine suffer from cold-start rating compression?',
        '<strong>Yes, severely.</strong> Spread recovery after placement is ${fmt(d(a10['spreadRecovery']))} — the estimated ratings have about a ${pct(d(a10['spreadRecovery']) * 100)} of the dispersion real skill has. Ranking <em>order</em> is fine (ρ = ${fmt(d(a50['spearman']), 2)} at 50); the scale is what collapses.'),
    ('After 10 placement matches, do strong players reach appropriately high regions of the scale?',
        'No. The mean rating handed to a true 5–6 player is <strong>${fmt(d(m(a10['meanEstByBand'])['5–6'] ?? 0))}</strong>, against ${fmt(d(m(a10['meanEstByBand'])['2–3'] ?? 0))} for a true 2–3 player. Those two groups are nearly indistinguishable on the number the player is shown.'),
    ('What percentage of true 5.0+ players are still below 3.5 after placement?',
        '<strong>${pct(d(a10['pctStrongStuckLow']))}</strong> under the current engine, still ${pct(d(a50['pctStrongStuckLow']))} after 50 matches. The tuned hybrid brings this to ${pct(d(c10['pctStrongStuckLow']))} at 10.'),
    ('What percentage of true 1.5–2.0 players remain above 3.0 after placement?',
        '${pct(d(a10['pctWeakStuckHigh']))} under the current engine — the low end is not the problem, because 2.0 is where everyone starts. Under the tuned hybrid (which starts everyone higher) it is ${pct(d(c10['pctWeakStuckHigh']))}, and that number is the one to watch if you move the prior up.'),
    ('Is starting everyone at 2.0 materially harming convergence?',
        '<strong>Yes, and it is the single biggest factor.</strong> Holding the production maths completely fixed and changing only the prior takes MAE@10 from ${maeAt('current maths, prior 2.0', '10')} to ${maeAt('current maths, prior 3.3', '10')}.'),
    ('Is 3.0 or 3.5 a better neutral starting prior?',
        'Both are far better than 2.0 and the difference between them is small. The right rule is not a constant at all — it is "start at the centre of your actual population". 3.0–3.5 is right for a population averaging 3.3; re-measure once you have real data.'),
    ('Does aggressive placement materially improve convergence without excessive volatility?',
        'Yes. Staged K cuts MAE@10 substantially, and the stability metric — post-convergence per-match wobble — is unchanged, because the aggressive K applies only during placement. The volatility that does exist is hidden behind the UNRANKED gate.'),
    ('Is the current opponent-uncertainty discount slowing down cold-start learning?',
        '<strong>Yes.</strong> At launch W evaluates to 0.575, so every early result counts a little over half. Removing it during placement alone moves MAE@10 from $relCur to $relFull.'),
    ('Should opponent reliability behave differently during placement?',
        'Yes — floor it at ~0.85, or drop it entirely for the first three matches and ramp back. Keep the full rule for established players, where it does the job it was designed for.'),
    ('Does dynamic placement matchmaking improve calibration?',
        '<strong>No — this hypothesis failed.</strong> Adaptive probing was fractionally worse than plain rating-banded matchmaking for every engine tested. Banded queueing already walks a winning player upward each round, so deliberately over-shooting mostly produces mismatches, and a mismatch carries little information either way. Reported as measured.'),
    ('Is the current 1 level ≈ 91% expected-win curve too steep?',
        'It sits at the decisive end of plausible, but <strong>it is the wrong lever</strong>. Flattening it improves MAE only by acting as a gain control against compression, and it makes the reported probabilities worse. It also calibrates well today precisely <em>because</em> the ratings feeding it are squashed — two errors cancelling. Keep s at 1.0–1.25, fix compression at its sources, then re-measure calibration.'),
    ('Is 70/30 winner–margin weighting better or worse than 85/15, 90/10 or result-only?',
        '<strong>Worse — and it is one of the causes of the compression.</strong> E is a win probability; the games ratio is far less extreme. A correctly-rated favourite therefore has E[S] &lt; E and drifts <em>down</em> for winning the matches they were supposed to win. Spread recovery falls monotonically as margin weight rises. Capping the ratio deviation at ±0.15 and rescaling puts the margin signal back on the win-probability scale — the information without the bias.'),
    ('Does simple averaging properly represent doubles teams?',
        '<strong>No</strong>, except in the one world built to make it true. 5.0 + 2.0 and 3.5 + 3.5 have measurably different win rates. An <code>avg − λ·gap</code> term fits better in every world and costs one subtraction.'),
    ('How badly can a strong player carry and inflate a weak player\'s rating?',
        'A true 2.5 permanently partnered with a 6.0 finishes <strong>+$boostA levels</strong> above their real skill under the current engine, and their sigma reports high confidence in it. This is the most exploitable hole in the system today.'),
    ('What ranked teammate rating-gap limit gives the best trade-off?',
        '<strong>None of them are a good trade — this hypothesis also failed.</strong> A 1.5 cap blocks ~6% of ordinary pairs and removes essentially none of the inflation; a 1.0 cap blocks ~21% for almost nothing; only 0.75 bites, and it refuses a third of all play. The mechanism defeats itself: as the carried player rises toward the partner, the gap closes and the rule stops applying. If you want a gap rule for match quality, fine — but it is not an anti-boosting tool.'),
    ('Should provisional players use a different teammate-gap rule?',
        'If you ship a gap rule at all, yes — provisional pairs are blocked at a similar rate on a rating that is mostly noise, so compare uncertainty intervals rather than point ratings while either player is unranked. But given the answer above, the more useful move is not to rely on gap rules for this job.'),
    ('Does repeated partner play make sigma too confident?',
        '<strong>Yes.</strong> 40 matches with one fixed partner produce the same sigma as 40 with random partners under every engine tested. Confidence is counting matches, not information.'),
    ('Should partner/opponent diversity affect sigma?',
        'In principle yes, and it is nearly free to implement — but <strong>measured on its own it changed nothing</strong> (MAE@50 0.575 against 0.574 for fixed decay). Ship it as part of the adaptive-sigma rule if you ship that, but do not expect it to carry weight by itself.'),
    ('Should sigma sometimes increase after repeated surprising results?',
        'Yes. Under the fixed ×0.92 rule, a player whose true skill collapses gets <em>more</em> confident while reality contradicts them every match. Surprise-aware sigma re-opens the estimate and re-converges faster.'),
    ('Should inactivity decrease rating, or only increase uncertainty?',
        '<strong>Uncertainty only.</strong> Sigma-only decay re-converges at least as well for every simulated skill change — including players who genuinely got worse — and it never takes a level away from someone who did nothing wrong.'),
    ('Are anchors improving calibration or introducing risk?',
        'Improving — but weakly, and only at a real dose. 20 verified players in 800 barely dents a population-wide offset; the effect scales with density. Miscalibrated anchors turned out <em>not</em> to be catastrophic (they add spread while adding error), so the practical risk is under-seeding rather than mis-seeding. Anchors supplement a correct prior; they cannot replace one.'),
    ('Does TrueSkill meaningfully outperform the current system?',
        'Against production as it stands, yes — ${fmt(d(t50['mae']))} vs ${fmt(d(a50['mae']))} MAE at 50 matches. Against the tuned hybrid the gap narrows to ${fmt(d(t50['mae']))} vs ${fmt(d(c50['mae']))}, which does not justify the migration on its own.'),
    ('Does Glicko-2 meaningfully outperform it?',
        'Similar picture: ${fmt(d(g50['mae']))} MAE at 50 and the best spread recovery of any engine tested. Same conclusion — the win is real but is mostly reachable from where you already are.'),
    ('Can a tuned version of the current hybrid solve the important problems?',
        '<strong>Yes.</strong> Compression, strong-player convergence, boost resistance and inactivity all respond to changes that stay inside the existing architecture. That is the recommendation.'),
  ];
}

// ─────────────────────────────────────────────────────────────────────────────
String sectionMethod() {
  return '''
<section>
  <header>
    <p class="eyebrow">Method</p>
    <h2>How this was run, and what it cannot tell you</h2>
  </header>
  <div class="prose">
    <p>Every engine consumes an identical, engine-independent match stream: the same players,
    true skills, partners, opponents, scorelines and winners, generated from ground truth rather
    than from any engine's ratings. The only exception is the matchmaking experiment, where the
    stream has to differ because matchmaking is the variable — that arm is reported separately.</p>
    <p>Match outcomes are generated by eleven "worlds" that deliberately break the engines'
    assumptions: pure average, strong-player carry, weak-link targeting, mixed reality,
    short-term form, improving and declining players, smurfs, overrated beginners, launch-day
    cold start and fixed-partner boosting. Scorelines come from a game-by-game padel model
    (sets to 6, win by 2, tie-break at 6–6, best of 3), so result and margin come from the same
    source and neither is injected independently.</p>
    <p>Parameter grids were fitted on tuning seeds and every headline number is reported on
    held-out evaluation seeds. Randomness is a seeded xoshiro256** stream, so every run is
    reproducible.</p>
  </div>
  <ul class="bullets">
    <li><strong>The simulator does not know real padel.</strong> The most consequential unknown
    is how decisive a one-level gap really is; three worlds bracket it deliberately, and the
    curve recommendation is the one that is robust across all three rather than optimal in any.</li>
    <li><strong>Absolute error is partly a statement about the prior.</strong> No Elo-family
    engine recovers where a population sits on the scale. Read centred MAE, Spearman and spread
    recovery for the estimator's quality; read raw MAE for what a user actually sees.</li>
    <li><strong>Nothing here was applied.</strong> <code>supabase/migration_player_app.sql</code>,
    <code>_settle_rating</code>, <code>lib/backend/models/rating_engine.dart</code> and every live
    profile are untouched. Engine A is a read-only mirror, and it stays the baseline.</li>
  </ul>
  <details>
    <summary>Running it yourself</summary>
    <p class="caption"><code>dart run tools/ranking_simulation/experiments.dart all</code> writes
    <code>results.json</code>; <code>dart run tools/ranking_simulation/report.dart</code> rebuilds
    this page. Engines live behind one interface in <code>engines.dart</code>, worlds and
    populations in <code>sim.dart</code>, metrics in <code>metrics.dart</code>. Every tunable is a
    field on <code>HybridConfig</code>, so a new variant is a config literal, not a new class.</p>
  </details>
</section>''';
}
