/* ============================================================
   flow.js — cross-project connections: flow (sankey) + bundle
   Public entry: FlowPage.load()
   ============================================================ */

const FlowPage = (function () {
  'use strict';

  var TYPES = [
    { k: 'doc', n: 'Doc-Verweise' },
    { k: 'msg', n: 'Agent-Nachrichten' },
    { k: 'kn', n: 'Geteiltes Wissen' },
    { k: 'man', n: 'Manuelle Relation' }
  ];
  var TOP_FLOW = 15;
  var TOP_BUNDLE = 40;
  var PARTICLE_CAP = 400;
  var OTHER_ID = -1;

  var root, stage, side, data = null, byId = {};
  var view = 'flow', on = new Set(TYPES.map(function (t) { return t.k; }));
  var sel = null, showAll = false, months = [], monthIdx = -1, playTimer = null;
  var timers = [], wired = false;
  var reduced = window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches;
  // per-viewer switches; the system setting is only the default
  var motion = pref('fl-motion', !reduced);
  var balance = pref('fl-balance', true);

  function pref(key, def) {
    try { var v = localStorage.getItem(key); return v === null ? def : v === '1'; } catch (e) { return def; }
  }
  function savePref(key, val) { try { localStorage.setItem(key, val ? '1' : '0'); } catch (e) { /* storage unavailable */ } }

  function css(k) { return getComputedStyle(root).getPropertyValue('--f-' + k).trim(); }
  function typeName(k) { for (var i = 0; i < TYPES.length; i++) if (TYPES[i].k === k) return TYPES[i].n; return k; }
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function slug(id) { return id === OTHER_ID ? 'Andere' : (byId[id] ? byId[id].slug : String(id)); }

  // ---- timers: stop when leaving the page ----
  function stopTimers() { timers.forEach(function (t) { t.stop(); }); timers = []; }
  function isActive() { return root && root.classList.contains('active') && !document.hidden; }

  // ---- edge weight respecting the time slider ----
  function weight(l) {
    if (monthIdx < 0 || monthIdx >= months.length - 1) return l.n;
    var lim = months[monthIdx], s = 0;
    for (var m in l.months) if (m <= lim) s += l.months[m];
    return s;
  }
  function activeInMonth(l) {
    return monthIdx >= 0 && monthIdx < months.length - 1 && !!l.months[months[monthIdx]];
  }
  function visLinks() {
    return data.links.filter(function (l) { return on.has(l.type) && weight(l) > 0; })
      .map(function (l) { return { s: l.s, t: l.t, type: l.type, n: weight(l), hot: activeInMonth(l), raw: l }; });
  }
  function degrees(links) {
    var d = {};
    links.forEach(function (l) { d[l.s] = (d[l.s] || 0) + l.n; d[l.t] = (d[l.t] || 0) + l.n; });
    return d;
  }
  function topIds(links, k) {
    var d = degrees(links);
    return Object.keys(d).map(Number).sort(function (a, b) { return d[b] - d[a]; }).slice(0, k);
  }

  // ---- particles along svg paths: count ~ sqrt(amount) ----
  function particles(g, paths, amountOf, colorOf, speed) {
    if (!motion) return;
    var items = [];
    paths.each(function (d) { items.push({ el: this, d: d, want: Math.max(1, Math.round(Math.sqrt(amountOf(d)) * 1.3)) }); });
    var total = d3.sum(items, function (i) { return i.want; });
    var scale = total > PARTICLE_CAP ? PARTICLE_CAP / total : 1;
    var P = [];
    items.forEach(function (it) {
      var L = it.el.getTotalLength(), n = Math.max(1, Math.round(it.want * scale));
      for (var i = 0; i < n; i++) P.push({ el: it.el, L: L, o: i / n, c: colorOf(it.d) });
    });
    var dots = g.selectAll('circle').data(P).join('circle').attr('r', 2.2)
      .attr('fill', function (p) { return p.c; }).attr('pointer-events', 'none');
    var t = d3.timer(function (el) {
      if (!isActive()) { stopTimers(); return; }
      dots.each(function (p) {
        var f = ((el * speed / p.L) + p.o) % 1, pt = p.el.getPointAtLength(f * p.L);
        this.setAttribute('cx', pt.x);
        this.setAttribute('cy', pt.y);
        this.setAttribute('opacity', p.el.classList.contains('fl-dim') ? 0.03 : Math.sin(f * Math.PI) * 0.95);
      });
    });
    timers.push(t);
  }

  // ---- flow view ----
  function drawFlow() {
    var W = Math.min(Math.max(760, stage.clientWidth - 40), 1200);
    var links = visLinks();
    if (sel != null) links = links.filter(function (l) { return l.s === sel || l.t === sel; });
    if (!links.length) { stage.innerHTML = '<p class="fl-hint">Keine Verbindungen für diese Auswahl.</p>'; return; }

    var keep = new Set(showAll || sel != null ? links.flatMap(function (l) { return [l.s, l.t]; }) : topIds(links, TOP_FLOW));
    var fold = function (id) { return keep.has(id) ? id : OTHER_ID; };
    var agg = {};
    links.forEach(function (l) {
      var s = fold(l.s), t = fold(l.t);
      if (s === t) return;
      [['s:' + s, 't:' + l.type], ['t:' + l.type, 'z:' + t]].forEach(function (p) {
        var k = p[0] + '|' + p[1];
        (agg[k] = agg[k] || { source: p[0], target: p[1], value: 0, real: 0, k: l.type }).real += l.n;
      });
    });
    var realIn = {}, realOut = {};
    Object.values(agg).forEach(function (a) {
      a.value = balance ? Math.sqrt(a.real) : a.real;
      realOut[a.source] = (realOut[a.source] || 0) + a.real;
      realIn[a.target] = (realIn[a.target] || 0) + a.real;
    });
    var ids = {};
    Object.values(agg).forEach(function (a) { ids[a.source] = 1; ids[a.target] = 1; });
    var nodes = Object.keys(ids).map(function (id) {
      var col = id[0] === 's' ? 0 : id[0] === 't' ? 1 : 2, raw = id.slice(2);
      return { id: id, col: col, k: col === 1 ? raw : null, pid: col === 1 ? null : Number(raw),
        name: col === 1 ? typeName(raw) : slug(Number(raw)) };
    });
    var H = Math.max(420, Math.min(1400, nodes.length * 34));
    var sk = d3.sankey().nodeId(function (d) { return d.id; }).nodeWidth(8).nodePadding(18)
      .nodeAlign(function (d) { return d.col; }).extent([[230, 28], [W - 230, H - 10]]);
    var g0 = sk({ nodes: nodes, links: Object.values(agg).map(function (d) { return Object.assign({}, d); }) });

    var svg = d3.select(stage).append('svg').attr('width', W).attr('height', H)
      .attr('role', 'img').attr('aria-label', 'Fluss: wer verweist, über welche Art, auf wen');
    [['Wer verweist', 230], ['Über welche Art', W / 2], ['Auf wen', W - 230]].forEach(function (h) {
      svg.append('text').attr('class', 'fl-colhead').attr('x', h[1]).attr('y', 14).attr('text-anchor', 'middle').text(h[0]);
    });
    var lk = svg.append('g').attr('fill', 'none').selectAll('path').data(g0.links).join('path')
      .attr('d', d3.sankeyLinkHorizontal()).attr('stroke', function (d) { return css(d.k); })
      .attr('stroke-opacity', .28).attr('stroke-width', function (d) { return Math.max(1, d.width * .4); });
    lk.append('title').text(function (d) { return d.source.name + ' → ' + d.target.name + ': ' + d.value; });
    var ng = svg.append('g').selectAll('g').data(g0.nodes).join('g');
    ng.append('rect').attr('x', function (d) { return d.x0; }).attr('y', function (d) { return d.y0; })
      .attr('width', function (d) { return d.x1 - d.x0; }).attr('height', function (d) { return Math.max(2, d.y1 - d.y0); })
      .attr('rx', 3).attr('fill', function (d) { return d.k ? css(d.k) : css('ink'); });
    ng.append('text').attr('class', 'fl-lbl')
      .attr('x', function (d) { return d.col === 0 ? d.x0 - 8 : d.x1 + 8; })
      .attr('y', function (d) { return (d.y0 + d.y1) / 2; }).attr('dy', '.35em')
      .attr('text-anchor', function (d) { return d.col === 0 ? 'end' : 'start'; })
      .text(function (d) { return d.name + '  ' + (d.col === 2 ? realIn[d.id] : realOut[d.id]); });
    var clickable = ng.filter(function (d) { return d.col !== 1; }).attr('tabindex', 0).style('cursor', 'pointer');
    clickable.on('click', function (ev, d) { pickNode(d.pid); })
      .on('keydown', function (ev, d) { if (ev.key === 'Enter') pickNode(d.pid); });
    particles(svg.append('g'), lk, function (d) { return d.real; }, function (d) { return css(d.k); }, .09);
  }

  // ---- bundle view ----
  function drawBundle() {
    var links = visLinks();
    if (!links.length) { stage.innerHTML = '<p class="fl-hint">Keine Verbindungen für diese Auswahl.</p>'; return; }
    var keep = new Set(showAll ? links.flatMap(function (l) { return [l.s, l.t]; }) : topIds(links, TOP_BUNDLE));
    links = links.filter(function (l) { return keep.has(l.s) && keep.has(l.t); });
    var groups = {};
    keep.forEach(function (id) {
      var g = byId[id] ? byId[id].group : 'Sonstige';
      (groups[g] = groups[g] || []).push(id);
    });
    var tree = { children: Object.keys(groups).sort().map(function (g) {
      return { name: g, children: groups[g].map(function (id) { return { name: slug(id), id: id }; }) };
    }) };
    var S = Math.min(Math.max(760, stage.clientWidth - 40), 1000), R = S / 2 - 215;
    var h = d3.hierarchy(tree);
    d3.cluster().size([2 * Math.PI, R]).separation(function (a, b) { return a.parent === b.parent ? 1 : 2.2; })(h);
    var leaf = {};
    h.leaves().forEach(function (l) { leaf[l.data.id] = l; });
    var svg = d3.select(stage).append('svg').attr('width', S + 160).attr('height', S)
      .attr('role', 'img').attr('aria-label', 'Bündel: Verbindungen zwischen Projekten, nach Gruppe geordnet');
    var gr = svg.append('g').attr('transform', 'translate(' + (S + 160) / 2 + ',' + S / 2 + ')');
    var line = d3.lineRadial().curve(d3.curveBundle.beta(.88)).radius(function (d) { return d.y; }).angle(function (d) { return d.x; });
    var paths = gr.append('g').attr('fill', 'none').selectAll('path').data(links).join('path')
      .attr('d', function (l) { return line(leaf[l.s].path(leaf[l.t])); })
      .attr('stroke', function (l) { return css(l.type); })
      .attr('stroke-width', function (l) { return .8 + Math.sqrt(l.n) * .35; })
      .attr('stroke-opacity', function (l) { return monthIdx >= 0 && monthIdx < months.length - 1 ? (l.hot ? .9 : .22) : .32; })
      .attr('stroke-linecap', 'round');
    paths.append('title').text(function (l) { return slug(l.s) + ' → ' + slug(l.t) + ': ' + l.n + ' ' + typeName(l.type); });
    h.children.forEach(function (g) {
      var ls = g.leaves(), a0 = d3.min(ls, function (l) { return l.x; }) - .05, a1 = d3.max(ls, function (l) { return l.x; }) + .05;
      gr.append('path').attr('d', d3.arc().innerRadius(R + 200).outerRadius(R + 202)({ startAngle: a0, endAngle: a1 })).attr('fill', css('mut'));
      if (ls.length < 2 && g.data.name !== 'Wissen') return;
      var am = (a0 + a1) / 2;
      gr.append('text').attr('class', 'fl-grp').attr('text-anchor', 'middle').attr('dy', '.35em')
        .attr('transform', 'translate(' + Math.sin(am) * (R + 222) + ',' + (-Math.cos(am) * (R + 222)) + ')').text(g.data.name);
    });
    var deg = degrees(links);
    var nd = gr.append('g').selectAll('g').data(h.leaves()).join('g')
      .attr('transform', function (d) { return 'rotate(' + (d.x * 180 / Math.PI - 90) + ') translate(' + d.y + ',0)'; })
      .attr('tabindex', 0).style('cursor', 'pointer');
    nd.append('circle').attr('r', function (d) { return 2.5 + Math.sqrt(deg[d.data.id] || 0) / 3; }).attr('fill', css('ink'));
    nd.append('text').attr('class', 'fl-lbl').attr('dy', '.35em')
      .attr('x', function (d) { return d.x < Math.PI ? 10 : -10; })
      .attr('transform', function (d) { return d.x >= Math.PI ? 'rotate(180)' : null; })
      .attr('text-anchor', function (d) { return d.x < Math.PI ? 'start' : 'end'; }).text(function (d) { return d.data.name; });
    function hi(id) { paths.classed('fl-dim', function (l) { return id != null && l.s !== id && l.t !== id; }); }
    nd.on('mouseenter', function (ev, d) { hi(d.data.id); }).on('mouseleave', function () { hi(sel); })
      .on('click', function (ev, d) { pickNode(d.data.id); })
      .on('keydown', function (ev, d) { if (ev.key === 'Enter') pickNode(d.data.id); });
    hi(sel);
    particles(gr.append('g'), paths, function (l) { return l.n; }, function (l) { return css(l.type); }, .07);
  }

  function pickNode(id) {
    if (id === OTHER_ID) { showAll = true; sel = null; render(); return; }
    sel = sel === id ? null : id;
    render();
  }

  // ---- side panel ----
  function segHtml(t) {
    return TYPES.filter(function (x) { return t[x.k]; }).map(function (x) {
      return '<span title="' + esc(x.n + ': ' + t[x.k]) + '" style="flex:' + t[x.k] + ';background:var(--f-' + x.k + ')"></span>';
    }).join('');
  }
  function renderSide() {
    var links = visLinks();
    if (sel == null) {
      var d = degrees(links), top = Object.keys(d).map(Number).sort(function (a, b) { return d[b] - d[a]; }).slice(0, 25);
      side.innerHTML = '<h2>Alle Projekte</h2><div class="fl-meta">' + data.projects.length + ' Projekte, ' +
        d3.sum(links, function (l) { return l.n; }) + ' Verbindungen' +
        (showAll ? ' · <button class="fl-back" data-act="fold">nur Top zeigen</button>' : '') + '</div>' +
        top.map(function (id) { return '<div class="fl-row" tabindex="0" data-pid="' + id + '"><span>' + esc(slug(id)) + '</span><span>' + d[id] + '</span></div>'; }).join('') +
        (data.null_count ? '<p class="fl-hint">' + data.null_count + ' Doc-Zugriffe ohne Sitzung sind keinem Projekt zuzuordnen und fehlen bei „Geteiltes Wissen“.</p>' : '') +
        '<p class="fl-hint">Projekt anklicken für seine Partner.</p>';
    } else {
      var by = {};
      links.filter(function (l) { return l.s === sel || l.t === sel; }).forEach(function (l) {
        var o = l.s === sel ? l.t : l.s;
        var e = by[o] = by[o] || { n: 0, t: {}, edges: [] };
        e.n += l.n; e.t[l.type] = (e.t[l.type] || 0) + l.n; e.edges.push(l);
      });
      var rows = Object.keys(by).map(Number).sort(function (a, b) { return by[b].n - by[a].n; });
      var p = byId[sel] || {};
      side.innerHTML = '<h2>' + esc(p.name || slug(sel)) + '</h2><div class="fl-meta">' + esc(p.slug || '') +
        ' · ' + (p.docs || 0) + ' Docs · ' + rows.length + ' Partner</div>' +
        rows.map(function (o) {
          return '<div class="fl-row" tabindex="0" data-partner="' + o + '"><span>' + esc(slug(o)) + '</span><span>' + by[o].n + '</span><div class="fl-seg">' + segHtml(by[o].t) + '</div></div><div class="fl-items" data-for="' + o + '"></div>';
        }).join('') +
        '<p><button class="fl-back" data-act="clear">Zurück zur Übersicht</button></p>';
      side._by = by;
    }
  }
  async function loadDetail(partner, box) {
    if (box.childElementCount) { box.innerHTML = ''; return; }
    box.innerHTML = '<div class="fl-hint">lädt…</div>';
    var edges = side._by[partner].edges, out = [], failed = 0;
    for (var i = 0; i < edges.length; i++) {
      var e = edges[i];
      try {
        var res = await fetch('api/graph/flow/detail?s=' + e.s + '&t=' + e.t + '&type=' + e.type, { credentials: 'same-origin' });
        if (!res.ok) { failed++; continue; }
        var j = await res.json();
        j.items.forEach(function (it) { it._type = e.type; it._dir = e.s === sel ? '→' : '←'; out.push(it); });
      } catch (err) {
        failed++;
      }
    }
    if (failed && !out.length) {
      box.innerHTML = '<div class="fl-hint">Details konnten nicht geladen werden. Zeile erneut anklicken.</div>';
      return;
    }
    out.sort(function (a, b) { return (b.ts || '').localeCompare(a.ts || ''); });
    box.innerHTML = out.slice(0, 60).map(function (it) {
      var label = it.title || it.info || '';
      if (it._type === 'msg' && label.charAt(0) === '{') {
        var m = /"text"\s*:\s*"((?:[^"\\]|\\.)*)/.exec(label);
        if (m) { try { label = JSON.parse('"' + m[1] + '"'); } catch (e) { label = m[1]; } }
      }
      var title = it.doc_id ? '<a data-doc="' + it.doc_id + '">' + esc(label || ('#' + it.doc_id)) + '</a>' : esc(label);
      var extra = it._type === 'doc' && it.target_title ? ' → <a data-doc="' + it.target_doc_id + '">' + esc(it.target_title) + '</a>'
        : it._type === 'kn' && it.read_count ? ' · ' + it.read_count + '× gelesen' : '';
      return '<div class="fl-item" style="border-color:var(--f-' + it._type + ')">' + it._dir + ' ' + title + extra +
        '<div class="fl-when">' + esc(typeName(it._type)) + (it.info && it._type !== 'kn' && label !== it.info ? ' · ' + esc(it.info) : '') + ' · ' + esc(it.ts || '') + '</div></div>';
    }).join('') || '<div class="fl-hint">Keine Einträge.</div>';
  }
  function onSideClick(ev) {
    var a = ev.target.closest('[data-doc]');
    if (a) { if (window.App && App.openDoc) App.openDoc(Number(a.dataset.doc)); return; }
    var b = ev.target.closest('[data-act]');
    if (b) {
      if (b.dataset.act === 'clear') sel = null;
      if (b.dataset.act === 'fold') showAll = false;
      render(); return;
    }
    var r = ev.target.closest('.fl-row');
    if (!r) return;
    if (r.dataset.pid) { pickNode(Number(r.dataset.pid)); return; }
    if (r.dataset.partner) loadDetail(Number(r.dataset.partner), side.querySelector('[data-for="' + r.dataset.partner + '"]'));
  }

  // ---- time slider ----
  function setupTime() {
    var set = {};
    data.links.forEach(function (l) { Object.keys(l.months).forEach(function (m) { set[m] = 1; }); });
    months = Object.keys(set).sort();
    var rg = root.querySelector('.fl-range');
    rg.max = Math.max(0, months.length - 1);
    monthIdx = months.length - 1;
    rg.value = monthIdx;
    showMonth();
  }
  function showMonth() {
    var lbl = root.querySelector('.fl-month');
    if (!months.length) { lbl.textContent = ''; return; }
    var m = months[monthIdx].split('-');
    var txt = new Date(Number(m[0]), Number(m[1]) - 1, 1).toLocaleDateString('de-DE', { month: 'long', year: 'numeric' });
    lbl.textContent = monthIdx === months.length - 1 ? 'bis ' + txt : txt;
  }
  function togglePlay() {
    var btn = root.querySelector('.fl-play');
    if (playTimer) { clearInterval(playTimer); playTimer = null; btn.textContent = 'Abspielen'; return; }
    monthIdx = 0; btn.textContent = 'Pause'; step();
    playTimer = setInterval(function () {
      if (!isActive() || monthIdx >= months.length - 1) { clearInterval(playTimer); playTimer = null; btn.textContent = 'Abspielen'; return; }
      monthIdx++; step();
    }, reduced ? 400 : 1100);
    function step() { root.querySelector('.fl-range').value = monthIdx; showMonth(); render(); }
  }

  // ---- shell ----
  function build() {
    root.innerHTML =
      '<div class="fl-head"><div><h1>Wer hängt mit wem zusammen</h1><p class="fl-sub">Verbindungen zwischen allen Projekten, nach Art und Zeit.</p></div>' +
      '<nav class="fl-tabs" aria-label="Ansicht"><button data-view="flow">Fluss</button><button data-view="bundle">Bündel</button></nav></div>' +
      '<div class="fl-bar">' + TYPES.map(function (t) {
        return '<button class="fl-chip" data-type="' + t.k + '" aria-pressed="true"><i style="background:var(--f-' + t.k + ')"></i>' + t.n + '</button>';
      }).join('') +
      '<button class="fl-chip fl-opt" data-opt="balance" aria-pressed="' + balance + '">Ausgleichen</button>' +
      '<button class="fl-chip fl-opt" data-opt="motion" aria-pressed="' + motion + '">Strom</button>' +
      '<span class="fl-note"></span></div>' +
      '<div class="fl-time"><button class="fl-play">Abspielen</button><input class="fl-range" type="range" min="0" value="0" aria-label="Monat"><span class="fl-month"></span></div>' +
      '<div class="fl-main"><div class="fl-stage"></div><aside class="fl-side"></aside></div>';
    stage = root.querySelector('.fl-stage');
    side = root.querySelector('.fl-side');
    root.querySelectorAll('.fl-tabs button').forEach(function (b) {
      b.addEventListener('click', function () { view = b.dataset.view; render(); });
    });
    root.querySelectorAll('.fl-chip[data-type]').forEach(function (b) {
      b.addEventListener('click', function () {
        var k = b.dataset.type;
        if (on.has(k)) on.delete(k); else on.add(k);
        b.classList.toggle('off', !on.has(k));
        b.setAttribute('aria-pressed', on.has(k));
        render();
      });
    });
    root.querySelector('.fl-range').addEventListener('input', function () { monthIdx = Number(this.value); showMonth(); render(); });
    root.querySelector('.fl-play').addEventListener('click', togglePlay);
    root.querySelectorAll('.fl-opt').forEach(function (b) {
      b.classList.toggle('off', b.dataset.opt === 'motion' ? !motion : !balance);
      b.addEventListener('click', function () {
        if (b.dataset.opt === 'motion') { motion = !motion; savePref('fl-motion', motion); }
        else { balance = !balance; savePref('fl-balance', balance); }
        var val = b.dataset.opt === 'motion' ? motion : balance;
        b.classList.toggle('off', !val);
        b.setAttribute('aria-pressed', val);
        render();
      });
    });
    side.addEventListener('click', onSideClick);
    side.addEventListener('keydown', function (ev) { if (ev.key === 'Enter') onSideClick(ev); });
    window.addEventListener('resize', function () {
      clearTimeout(build._r);
      build._r = setTimeout(function () { if (isActive() && data) render(); }, 200);
    });
    document.addEventListener('visibilitychange', function () { if (isActive() && data) render(); });
  }

  function render() {
    stopTimers();
    var timeRow = root.querySelector('.fl-time');
    timeRow.style.display = view === 'flow' ? 'none' : '';
    if (view === 'flow' && months.length && monthIdx !== months.length - 1) {
      if (playTimer) { clearInterval(playTimer); playTimer = null; root.querySelector('.fl-play').textContent = 'Abspielen'; }
      monthIdx = months.length - 1;
      root.querySelector('.fl-range').value = monthIdx;
      showMonth();
    }
    root.querySelectorAll('.fl-tabs button').forEach(function (b) { b.classList.toggle('on', b.dataset.view === view); });
    root.querySelector('.fl-note').textContent = view === 'flow'
      ? (showAll || sel != null ? '' : 'Top ' + TOP_FLOW + ', Rest unter „Andere“ (anklicken zum Aufklappen)')
      : (showAll ? '' : 'Top ' + TOP_BUNDLE + ' nach Vernetzung');
    stage.innerHTML = '';
    if (view === 'flow') drawFlow(); else drawBundle();
    renderSide();
  }

  async function load() {
    root = document.getElementById('page-flow');
    if (!root) return;
    if (window.App && typeof App.showPage === 'function') {
      App.showPage('flow');
    } else {
      document.querySelectorAll('.page').forEach(function (p) { p.classList.remove('active'); });
      root.classList.add('active');
    }
    if (!wired) { wired = true; build(); }
    stage.innerHTML = '<p class="fl-hint">lädt…</p>';
    try {
      var res = await fetch('api/graph/flow', { credentials: 'same-origin' });
      if (res.status === 401 && window.App && App.showLogin) { App.showLogin('Session expired. Please sign in again.'); return; }
      if (!res.ok) throw new Error('HTTP ' + res.status);
      data = await res.json();
    } catch (err) {
      stage.innerHTML = '<p class="fl-hint">Verbindungen konnten nicht geladen werden (' + esc(err.message) + '). Seite neu laden.</p>';
      return;
    }
    byId = {};
    data.projects.forEach(function (p) { byId[p.id] = p; });
    setupTime();
    render();
  }

  return { load: load };
})();
