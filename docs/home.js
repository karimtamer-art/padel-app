// padel-rivals.com — web tournament registration.
// Talks to Supabase as `anon` through two RPCs only (web_open_tournaments,
// web_register) plus an insert-only upload to the private
// `web-payment-proofs` bucket. See supabase/changes/2026-10-20_web_registrations.sql.
(function () {
  'use strict';

  // ── Settings — edit these ─────────────────────────────────────────────
  var CONFIG = {
    supabaseUrl: 'https://lxihwifpcufhieppfeza.supabase.co',
    // The public anon key (same one the app ships; safe to expose — RLS guards the data).
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imx4aWh3aWZwY3VmaGllcHBmZXphIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODAzMzAzOTEsImV4cCI6MjA5NTkwNjM5MX0.7afCxV225wcNDa5njZz4KAIRTo3eOeMj0099NPF94oQ',
    // Leave instapayHandle empty to offer "pay at venue" only.
    instapayHandle: '',          // e.g. 'padelrivals@instapay'
    instapayName: '',            // name the account is registered to
    // Direct WhatsApp for confirmations, digits only with country code (e.g. '201000000000').
    // Empty = links go to the community group at /whatsapp.
    whatsappNumber: ''
  };
  var LEVELS = ['D Low', 'D Mid', 'D Upper', 'C Low', 'C Mid', 'C Upper',
                'B Low', 'B Mid', 'B Upper', 'A Low', 'A Mid', 'A Upper'];
  var CATEGORY = { mens: "Men's", womens: "Women's", mixed: 'Mixed', open: '' };
  var MAX_PROOF_BYTES = 5 * 1024 * 1024;

  var $ = function (id) { return document.getElementById(id); };
  var tournaments = [];
  var current = null;

  // ── Supabase helpers ─────────────────────────────────────────────────
  function headers(extra) {
    var h = { apikey: CONFIG.anonKey, Authorization: 'Bearer ' + CONFIG.anonKey };
    for (var k in extra) h[k] = extra[k];
    return h;
  }
  function rpc(fn, body) {
    return fetch(CONFIG.supabaseUrl + '/rest/v1/rpc/' + fn, {
      method: 'POST',
      headers: headers({ 'Content-Type': 'application/json' }),
      body: JSON.stringify(body || {})
    }).then(function (r) {
      return r.json().catch(function () { return null; }).then(function (data) {
        if (!r.ok) throw new Error((data && data.message) || 'Something went wrong. Please try again.');
        return data;
      });
    });
  }
  function uploadProof(file, tournamentId) {
    var ext = (file.type.split('/')[1] || 'jpg').replace('jpeg', 'jpg').replace(/[^a-z0-9]/gi, '');
    var id = (window.crypto && crypto.randomUUID) ? crypto.randomUUID()
           : Date.now().toString(36) + Math.random().toString(36).slice(2);
    var path = 'web/' + tournamentId + '/' + id + '.' + ext;
    return fetch(CONFIG.supabaseUrl + '/storage/v1/object/web-payment-proofs/' + path, {
      method: 'POST',
      headers: headers({ 'Content-Type': file.type || 'image/jpeg', 'x-upsert': 'false' }),
      body: file
    }).then(function (r) {
      if (!r.ok) throw new Error('We could not upload your screenshot. Please try a smaller image.');
      return path;
    });
  }

  // ── Formatting ───────────────────────────────────────────────────────
  function money(n) { return 'EGP ' + Number(n || 0).toLocaleString('en-US'); }
  function fmtDate(d) {
    var dt = new Date(d + 'T12:00:00');
    return dt.toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' });
  }
  function range(t) {
    var lo = t.min_category ? LEVELS.indexOf(t.min_category) : 0;
    var hi = t.max_category ? LEVELS.indexOf(t.max_category) : LEVELS.length - 1;
    if (lo < 0) lo = 0;
    if (hi < 0) hi = LEVELS.length - 1;
    return LEVELS.slice(lo, hi + 1);
  }
  function rangeText(t) {
    if (!t.min_category && !t.max_category) return 'all levels';
    var r = range(t);
    return r[0] + ' to ' + r[r.length - 1];
  }
  function waLink() {
    return CONFIG.whatsappNumber ? 'https://wa.me/' + CONFIG.whatsappNumber : '/whatsapp';
  }

  // ── UI helpers ───────────────────────────────────────────────────────
  function showStep(n) {
    ['step1', 'step2', 'step3'].forEach(function (id, i) { $(id).hidden = (i + 1 !== n); });
    document.querySelectorAll('.steps li').forEach(function (li) {
      li.classList.toggle('on', Number(li.dataset.step) <= n);
    });
    $('form-card').scrollIntoView({ behavior: 'smooth', block: 'start' });
  }
  function showError(form, msg) {
    var box = form.querySelector('.alert');
    box.textContent = msg || '';
    box.hidden = !msg;
  }
  function fillLevels(select, levels) {
    select.innerHTML = '';
    var first = document.createElement('option');
    first.value = '';
    first.textContent = levels ? 'Choose a level' : 'Choose a tournament first';
    select.appendChild(first);
    (levels || []).forEach(function (l) {
      var o = document.createElement('option');
      o.value = l; o.textContent = l;
      select.appendChild(o);
    });
    select.disabled = !levels;
  }
  function val(id) { return $(id).value.trim(); }

  // ── Load tournaments ─────────────────────────────────────────────────
  function load() {
    rpc('web_open_tournaments').then(function (rows) {
      tournaments = rows || [];
      $('state-loading').hidden = true;
      if (!tournaments.length) { $('state-empty').hidden = false; return; }
      var sel = $('f-tournament');
      tournaments.forEach(function (t) {
        var o = document.createElement('option');
        var bits = [t.name, fmtDate(t.start_date) + (t.start_time ? ' ' + t.start_time : '')];
        if (t.venue_name) bits.push(t.venue_name);
        bits.push(rangeText(t));
        o.value = t.id;
        o.textContent = bits.join(' · ');
        sel.appendChild(o);
      });
      $('step1').hidden = false;
    }).catch(function () {
      $('state-loading').hidden = true;
      $('state-empty').hidden = false;
    });
  }

  function onTournament() {
    current = tournaments.filter(function (t) { return t.id === $('f-tournament').value; })[0] || null;
    var info = $('t-info');
    if (!current) {
      info.hidden = true;
      fillLevels($('f-level'), null);
      fillLevels($('f-plevel'), null);
      return;
    }
    var parts = ['Open to ' + rangeText(current)];
    if (CATEGORY[current.category]) parts.push(CATEGORY[current.category] + ' event');
    parts.push(Number(current.entry_fee) > 0 ? money(current.entry_fee * 2) + ' per pair' : 'Free entry');
    if (current.spots_left !== null && current.spots_left <= 8) {
      parts.push(current.spots_left === 0 ? 'Full' : current.spots_left + ' spots left');
    }
    info.textContent = parts.join(' · ');
    info.hidden = false;
    var lv = range(current);
    fillLevels($('f-level'), lv);
    fillLevels($('f-plevel'), lv);
  }

  // ── Step 1 → 2 ───────────────────────────────────────────────────────
  function step1Submit(e) {
    e.preventDefault();
    var f = $('step1');
    var err = '';
    if (!current) err = 'Please choose a tournament.';
    else if (current.spots_left === 0) err = 'Sorry, this tournament is full.';
    else if (val('f-name').length < 2) err = 'Please enter your full name.';
    else if (val('f-phone').replace(/\D/g, '').length < 10) err = 'Please enter a valid WhatsApp number.';
    else if (!val('f-level')) err = 'Please choose your level.';
    else if (val('f-pname').length < 2) err = "Please enter your partner's name.";
    else if (!val('f-plevel')) err = "Please choose your partner's level.";
    showError(f, err);
    if (err) return;

    var free = !(Number(current.entry_fee) > 0);
    $('due-amount').textContent = free ? 'Free' : money(current.entry_fee * 2);
    $('due-names').textContent = val('f-name') + ' & ' + val('f-pname');
    $('pay-choice').hidden = free;
    $('opt-instapay').hidden = !CONFIG.instapayHandle;
    if (!CONFIG.instapayHandle) {
      document.querySelector('input[name=pay][value=venue]').checked = true;
    }
    onPayChange();
    showError($('step2'), '');
    showStep(2);
  }

  function payMethod() {
    if (!(Number(current && current.entry_fee) > 0)) return 'free';
    var c = document.querySelector('input[name=pay]:checked');
    return c ? c.value : '';
  }
  function onPayChange() { $('instapay-box').hidden = payMethod() !== 'instapay'; }

  // ── Step 2 → 3 ───────────────────────────────────────────────────────
  function step2Submit(e) {
    e.preventDefault();
    var f = $('step2');
    var pay = payMethod();
    var file = $('f-proof').files && $('f-proof').files[0];
    var err = '';
    if (!pay) err = 'Please choose how you want to pay.';
    else if (pay === 'instapay' && val('f-sender').length < 2) err = 'Please enter the name on the InstaPay transfer.';
    else if (pay === 'instapay' && !file) err = 'Please upload a screenshot of the transfer.';
    else if (pay === 'instapay' && file.size > MAX_PROOF_BYTES) err = 'That screenshot is over 5 MB. Please use a smaller image.';
    else if (!$('f-agree').checked) err = 'Please accept the terms to continue.';
    showError(f, err);
    if (err) return;

    var btn = $('submit');
    btn.disabled = true;
    btn.textContent = 'Sending…';

    var proof = pay === 'instapay' ? uploadProof(file, current.id) : Promise.resolve(null);
    proof.then(function (path) {
      return rpc('web_register', {
        p_tournament: current.id,
        p_name: val('f-name'),
        p_phone: val('f-phone'),
        p_email: val('f-email') || null,
        p_level: val('f-level'),
        p_partner_name: val('f-pname'),
        p_partner_phone: val('f-pphone') || null,
        p_partner_level: val('f-plevel'),
        p_pay_method: pay,
        p_sender: pay === 'instapay' ? val('f-sender') : null,
        p_proof_path: path
      });
    }).then(function () {
      var first = val('f-name').split(/\s+/)[0];
      $('done-title').textContent = "You're registered, " + first + '!';
      $('done-text').textContent = pay === 'instapay'
        ? 'We received your payment screenshot. Our team will check it and confirm your spot on WhatsApp at ' + val('f-phone') + '.'
        : pay === 'venue'
          ? 'Your spot is held. We will message you on WhatsApp at ' + val('f-phone') + ' with the details — bring the entry fee to the venue.'
          : 'We will message you on WhatsApp at ' + val('f-phone') + ' to confirm your spot.';
      showStep(3);
    }).catch(function (ex) {
      showError(f, ex.message);
    }).then(function () {
      btn.disabled = false;
      btn.textContent = 'Complete registration';
    });
  }

  function reset() {
    $('step1').reset();
    $('step2').reset();
    current = null;
    onTournament();
    showStep(1);
  }

  // ── Wire up ──────────────────────────────────────────────────────────
  document.addEventListener('DOMContentLoaded', function () {
    $('year').textContent = new Date().getFullYear();
    document.querySelectorAll('.js-whatsapp').forEach(function (a) { a.href = waLink(); });
    if (CONFIG.instapayHandle) {
      $('ip-handle').textContent = CONFIG.instapayHandle;
      $('ip-name').textContent = (CONFIG.instapayName ? 'Account name: ' + CONFIG.instapayName + ' · ' : '') + 'Only pay to this address.';
    }
    $('f-tournament').addEventListener('change', onTournament);
    $('step1').addEventListener('submit', step1Submit);
    $('step2').addEventListener('submit', step2Submit);
    document.querySelectorAll('input[name=pay]').forEach(function (r) { r.addEventListener('change', onPayChange); });
    $('back').addEventListener('click', function () { showStep(1); });
    $('again').addEventListener('click', reset);
    load();
  });
})();
