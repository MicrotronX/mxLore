/* ============================================================
   graph.js — mxLore Knowledge Graph page (Admin UI)
   Force-directed D3 graph over /api/graph?project={slug}.
   Adapted from prototype doc #7678 (SPEC #7677).

   Public entry: GraphPage.loadGraphPage()  (called by App.navigateTo)
   All DOM lives under #page-graph; all styles in css/graph.css.
   ============================================================ */

var GraphPage = (function () {
  'use strict';

  // doc_type -> color + human label. Mirrors prototype #7678; the three
  // types missing there (note/todo/workflow_log) get matching tones.
  var TYPES = {
    lesson:          { color: '#3ee08a', label: 'Lesson' },
    spec:            { color: '#4aa3ff', label: 'Spec' },
    plan:            { color: '#b07cff', label: 'Plan' },
    decision:        { color: '#ffb340', label: 'Decision / ADR' },
    reference:       { color: '#2fe0d0', label: 'Reference' },
    feature_request: { color: '#ff6bb0', label: 'Feature Request' },
    session_note:    { color: '#7889a8', label: 'Session Note' },
    bugreport:       { color: '#ff5a6e', label: 'Bug Report' },
    note:            { color: '#d4c98a', label: 'Note' },
    todo:            { color: '#ff9d5c', label: 'Todo' },
    workflow_log:    { color: '#5cc8ff', label: 'Workflow Log' }
  };
  function typeMeta(t) { return TYPES[t] || { color: '#7889a8', label: t || 'unknown' }; }

  // --- module state ---
  var initialized = false;   // event wiring done once
  var currentSlug = null;
  var pendingSlug = null;    // slug requested via #graph/:slug (F5/bookmark restore)
  var sim = null;            // active d3 force simulation (stopped on re-render)
  var selected = null;       // currently selected node
  var els = {};              // cached DOM refs
  var use3D = true;          // project-mode default: 3D Graph3D (toggle to 2D)

  // --- synapse-pulse animation state (Spec: neural observatory) ---
  var pulseRAF = null;       // requestAnimationFrame handle for the pulse loop
  var pulseState = null;     // { edges, pool, gNode, zoomScale } for the active loop
  var REDUCED_MOTION = (typeof window.matchMedia === 'function') &&
    window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  var MAX_PULSES = 250;      // cap travelling particles for performance
  var DIM_STATUS = { archived: 1, deprecated: 1, completed: 1, superseded: 1, closed: 1 };

  function $(sel) { return document.querySelector('#page-graph ' + sel); }

  function cacheEls() {
    els.root     = document.getElementById('page-graph');
    els.svg      = $('.gp-svg');
    els.universe = $('.gp-universe');
    els.threed   = $('.gp-3d');
    els.select   = $('.gp-project-select');
    els.search   = $('.gp-search');
    els.trunc    = $('.gp-trunc-hint');
    els.truncTxt = $('.gp-trunc-text');
    els.overlay  = $('.gp-overlay');
    els.ovIcon   = $('.gp-overlay .gp-spinner');
    els.ovEmpty  = $('.gp-overlay .gp-empty-icon');
    els.ovMsg    = $('.gp-msg');
    els.legend   = $('.gp-legend-items');
    els.statN    = $('.gp-stat-nodes');
    els.statL    = $('.gp-stat-links');
    els.detail   = $('.gp-detail');
    els.dSwatch  = $('.gp-detail .type-tag .swatch');
    els.dType    = $('.gp-d-type');
    els.dTitle   = $('.gp-d-title');
    els.dId      = $('.gp-d-id');
    els.dStatus  = $('.gp-d-status');
    els.dSummary = $('.gp-d-summary');
    els.dOpen    = $('.gp-d-open');
    els.dRels    = $('.gp-d-rels');
  }

  // ---- overlay helpers ----
  function showLoading() {
    els.overlay.classList.add('show');
    els.ovIcon.style.display = 'block';
    els.ovEmpty.style.display = 'none';
    els.ovMsg.textContent = 'mapping the knowledge field…';
  }
  function showEmpty(msg) {
    els.overlay.classList.add('show');
    els.ovIcon.style.display = 'none';
    els.ovEmpty.style.display = 'block';
    els.ovMsg.textContent = msg;
    if (window.lucide) lucide.createIcons();
  }
  function hideOverlay() { els.overlay.classList.remove('show'); }

  // ---- public entry ----
  async function loadGraphPage() {
    cacheEls();
    if (!els.root) return;

    // Activate this SPA view. navigateTo() does not call showPage for us, and
    // other loaders (e.g. loadGlobalPage) call App.showPage internally — mirror
    // that here, with a self-contained fallback if showPage isn't exported.
    if (window.App && typeof App.showPage === 'function') {
      App.showPage('graph');
    } else {
      document.querySelectorAll('.page').forEach(function (p) {
        p.classList.remove('active');
      });
      els.root.classList.add('active');
    }

    // one-time event wiring
    if (!initialized) {
      initialized = true;
      els.svg.addEventListener('click', closeDetail);
      var closeBtn = $('.gp-detail .close');
      if (closeBtn) closeBtn.addEventListener('click', closeDetail);
      els.select.addEventListener('change', function () {
        var v = els.select.value;
        if (!v) { enterUniverseMode(); return; }
        enterProjectMode(v);
      });
      var backBtn = $('.gp-universe-back');
      if (backBtn) backBtn.addEventListener('click', function () { enterUniverseMode(); });
      window.addEventListener('resize', onResize);
    }

    await loadProjectSelector();

    // ---- Mode switch: slug active -> Project (2D); no slug -> Universe (3D) ---
    if (currentSlug) {
      enterProjectMode(currentSlug);
    } else {
      enterUniverseMode();
    }
  }

  // Show a project graph; tear down the 3D Universe. Default rendering is the
  // 3D Graph3D view; a toolbar toggle flips to the 2D D3 graph (kept for dense
  // reading/search). Only ONE of the two is ever mounted at a time.
  function enterProjectMode(slug) {
    currentSlug = slug;
    if (els.select) els.select.value = slug;
    syncHash();
    setUniverseVisible(false);
    if (window.Universe && Universe.isMounted && Universe.isMounted()) Universe.destroy();
    setupModeToggle();
    applyProjectMode(slug);
  }

  // Mount whichever project view (3D or 2D) is selected; tear down the other.
  function applyProjectMode(slug) {
    set3DVisible(use3D);
    if (use3D) {
      // Tear down any live 2D state so it can't run in the background.
      if (sim) { sim.stop(); sim = null; }
      stopPulseLoop();
      if (els.svg) { var sv = d3.select(els.svg); sv.selectAll('*').remove(); sv.on('.zoom', null); }
      hideOverlay();
      if (!window.Graph3D) { use3D = false; set3DVisible(false); renderGraph(slug); return; }
      Graph3D.mount({
        container: els.threed,
        slug: slug,
        onBack: enterUniverseMode,
        onOpenDoc: function (id) {
          if (window.App && typeof App.openDoc === 'function') App.openDoc(id);
          else location.hash = 'doc/' + id;
        }
      });
      // Wire the toolbar search to the 3D view (the 2D path wires its own).
      if (els.search) {
        els.search.value = '';
        els.search.oninput = function (e) {
          if (window.Graph3D && Graph3D.isMounted && Graph3D.isMounted()) {
            Graph3D.search(e.target.value);
          }
        };
      }
    } else {
      if (window.Graph3D && Graph3D.isMounted && Graph3D.isMounted()) Graph3D.destroy();
      renderGraph(slug);
    }
  }

  // Toggle visibility of the dedicated 3D container vs the 2D chrome. The 3D
  // container is its own layer (.gp-3d) so it never shares DOM with the 2D SVG.
  function set3DVisible(on) {
    if (els.root) els.root.classList.toggle('g3d-mode', !!on);
  }

  // Inject + wire the small 2D⇄3D toggle button in the toolbar (project mode
  // only). Created lazily so index.html needs no extra markup for it.
  function setupModeToggle() {
    var toolbar = $('.gp-toolbar');
    if (!toolbar) return;
    var btn = toolbar.querySelector('.gp-mode-toggle');
    if (!btn) {
      btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'gp-mode-toggle';
      // Sits right after the universe-back button.
      var back = toolbar.querySelector('.gp-universe-back');
      if (back && back.nextSibling) toolbar.insertBefore(btn, back.nextSibling);
      else toolbar.appendChild(btn);
      btn.addEventListener('click', function () {
        use3D = !use3D;
        paintModeToggle(btn);
        if (currentSlug) applyProjectMode(currentSlug);
      });
    }
    btn.style.display = '';
    paintModeToggle(btn);
  }
  function paintModeToggle(btn) {
    btn.textContent = use3D ? '◧ 2D view' : '◉ 3D view';
    btn.setAttribute('aria-pressed', use3D ? 'true' : 'false');
  }

  // Show the 3D Universe; tear down the 2D graph + clear the slug/hash.
  function enterUniverseMode() {
    currentSlug = null;
    if (els.select) els.select.value = '';
    // Tear down the 3D project view + hide its container/toggle.
    if (window.Graph3D && Graph3D.isMounted && Graph3D.isMounted()) Graph3D.destroy();
    set3DVisible(false);
    var modeBtn = $('.gp-mode-toggle');
    if (modeBtn) modeBtn.style.display = 'none';
    // Stop any running 2D sim/pulse + clear the SVG so it can't bleed through.
    if (sim) { sim.stop(); sim = null; }
    stopPulseLoop();
    if (els.svg) { var sv = d3.select(els.svg); sv.selectAll('*').remove(); sv.on('.zoom', null); }
    hideOverlay();
    if (location.hash.replace('#', '') !== 'graph') location.hash = 'graph';
    setUniverseVisible(true);
    if (!window.Universe) return;
    Universe.mount({
      container: els.universe,
      onOpenProject: function (slug) { enterProjectMode(slug); }
    });
  }

  // Toggle which mode's DOM is visible. Universe canvas vs the 2D SVG + chrome.
  function setUniverseVisible(on) {
    if (els.root) els.root.classList.toggle('uv-mode', !!on);
  }

  // ---- project selector ----
  async function loadProjectSelector() {
    try {
      var data = await apiGet('projects');
      var projects = (data && data.projects || []).filter(function (p) {
        return p.is_active !== false && p.slug;
      });
      projects.sort(function (a, b) { return (a.name || a.slug).localeCompare(b.name || b.slug); });

      // First option = Universe (empty value); selecting it returns to the 3D view.
      els.select.innerHTML = '<option value="">◐ universe</option>' + projects.map(function (p) {
        return '<option value="' + escAttr(p.slug) + '">' + escHtml(p.name || p.slug) + '</option>';
      }).join('');

      if (projects.length === 0) {
        currentSlug = null;
        return;
      }
      // Selection priority: hash (#graph/:slug, survives F5) > kept selection.
      // ⚡ Universe-default: when NO slug was requested (bare #graph, fresh open),
      // we leave currentSlug null so loadGraphPage mounts the Universe. We only
      // force a project (and syncHash) when a slug was actually requested.
      var want = pendingSlug || currentSlug;
      pendingSlug = null;
      var valid = want && projects.some(function (p) { return p.slug === want; });
      currentSlug = valid ? want : null;
      els.select.value = currentSlug || '';
      if (currentSlug) syncHash();
    } catch (err) {
      currentSlug = null;
      showEmpty('Failed to load projects.');
    }
  }

  // ---- core render (idempotent: clears prior SVG + stops prior sim) ----
  async function renderGraph(slug) {
    if (!slug) return;
    selected = null;
    els.detail.classList.remove('open');
    if (els.search) els.search.value = '';
    els.trunc.classList.remove('show');

    // tear down previous d3 state
    if (sim) { sim.stop(); sim = null; }
    stopPulseLoop();
    var svgSel = d3.select(els.svg);
    svgSel.selectAll('*').remove();
    svgSel.on('.zoom', null);

    showLoading();

    var data;
    try {
      data = await apiGet('graph?project=' + encodeURIComponent(slug) + '&limit=2000');
    } catch (err) {
      showEmpty('Failed to load graph for this project.');
      return;
    }
    // Ignore stale responses if the user switched projects mid-flight.
    if (slug !== currentSlug) return;

    var NODES = (data && data.nodes || []).map(function (n) {
      return { id: n.id, type: n.type, title: n.title || ('#' + n.id),
               summary: n.summary || '', status: n.status || '' };
    });
    var LINKS = (data && data.links || []).map(function (l) {
      return { source: l.s, target: l.t, rel: l.rel };
    });

    els.statN.textContent = (data && data.total_nodes != null) ? data.total_nodes : NODES.length;
    els.statL.textContent = (data && data.link_count != null) ? data.link_count : LINKS.length;

    // Truncation hint
    if (data && data.truncated && data.total_nodes != null) {
      els.truncTxt.textContent = 'showing ' + (data.node_count != null ? data.node_count : NODES.length) +
                                 ' of ' + data.total_nodes + ' nodes';
      els.trunc.classList.add('show');
    }

    if (NODES.length === 0) {
      showEmpty('No documents in this project yet — nothing to map.');
      return;
    }
    hideOverlay();

    drawGraph(svgSel, NODES, LINKS);
  }

  // Compute the connected-network centre and the isolated "park" pole for the
  // current viewport. The connected network always keeps the full field centred
  // at the canvas middle — isolated nodes are hidden by default, and even when
  // shown they pool in a small, tidy cluster tucked into the bottom-right corner
  // rather than reserving a column. So the connected layout never shifts.
  function computeZones(W, H) {
    return {
      connX: W / 2,
      connY: H / 2,
      // Compact park pole near the bottom-right; tight gravity gathers the dots.
      isoX: W - Math.min(140, W * 0.16),
      isoY: H - Math.min(120, H * 0.18)
    };
  }

  function drawGraph(svgSel, NODES, LINKS) {
    var W = els.root.clientWidth || window.innerWidth;
    var H = els.root.clientHeight || window.innerHeight;
    svgSel.attr('viewBox', [0, 0, W, H]);

    var nodeById = new Map(NODES.map(function (n) { return [n.id, n]; }));
    var links = LINKS.filter(function (l) {
      return nodeById.has(l.source) && nodeById.has(l.target);
    });

    var degree = {};
    links.forEach(function (l) {
      degree[l.source] = (degree[l.source] || 0) + 1;
      degree[l.target] = (degree[l.target] || 0) + 1;
    });
    NODES.forEach(function (n) { n.deg = degree[n.id] || 1; });
    var radius = function (d) { return Math.min(20, 4 + Math.sqrt(d.deg) * 2.6); };

    // Split nodes by connectivity. Isolated (degree 0 — never referenced by any
    // surviving link) are HIDDEN by default; a toolbar chip reveals them. When
    // shown they pool into one compact, tidy cluster (tight gravity pole) in the
    // bottom-right corner as tiny dim dots — never scattered across the field.
    // `iso` flags the node for the per-node force-target + visibility logic.
    NODES.forEach(function (n) { n.iso = !degree[n.id]; });
    var isolated = NODES.filter(function (n) { return n.iso; });
    var isoCount = isolated.length;
    var showIso = false;   // default: unlinked nodes hidden (state per render)

    // glow filter
    var defs = svgSel.append('defs');
    var glow = defs.append('filter').attr('id', 'gp-glow')
      .attr('x', '-50%').attr('y', '-50%').attr('width', '200%').attr('height', '200%');
    glow.append('feGaussianBlur').attr('stdDeviation', '2.5').attr('result', 'b');
    var merge = glow.append('feMerge');
    merge.append('feMergeNode').attr('in', 'b');
    merge.append('feMergeNode').attr('in', 'SourceGraphic');

    var container = svgSel.append('g');
    // Zoom-dependent label declutter: when zoomed out past a threshold, hide all
    // labels except hub nodes; fully zoomed-out hides everything. Re-applied on
    // every zoom event and on render so the canvas stays legible at any scale.
    var lastScale = 1;
    function applyLabelDeclutter(k) {
      lastScale = k;
      svgSel.classed('z-far', k < 0.85).classed('z-near', k >= 0.85);
    }
    svgSel.call(d3.zoom().scaleExtent([0.3, 4]).on('zoom', function (e) {
      container.attr('transform', e.transform);
      applyLabelDeclutter(e.transform.k);
    }));
    applyLabelDeclutter(1);

    // ---- Connected vs. isolated layout zones ------------------------------
    // The connected network owns the full field (centre = canvas middle). The
    // isolated nodes get a TIGHT gravity pole + strong collide-free clustering
    // into a compact pool in the bottom-right corner, so when revealed they read
    // as one tidy clump of tiny dots. Zones recompute in onResize. Hidden iso
    // nodes still get parked (cheap) so toggling on is instant + already tidy.
    var ZONE = computeZones(W, H);
    sim = d3.forceSimulation(NODES)
      .force('link', d3.forceLink(links).id(function (d) { return d.id; })
        .distance(function (d) { return 70 + (d.source.deg + d.target.deg) * 4; }).strength(0.35))
      .force('charge', d3.forceManyBody().strength(function (d) { return d.iso ? -30 : -340; }))
      .force('collide', d3.forceCollide().radius(function (d) { return d.iso ? 4 : radius(d) + 14; }))
      .force('x', d3.forceX(function (d) { return d.iso ? ZONE.isoX : ZONE.connX; })
        .strength(function (d) { return d.iso ? 0.5 : 0.06; }))
      .force('y', d3.forceY(function (d) { return d.iso ? ZONE.isoY : ZONE.connY; })
        .strength(function (d) { return d.iso ? 0.5 : 0.06; }));
    // Stash zone accessors on the sim so onResize can recompute them in place.
    sim._gpZone = ZONE;

    // Faint park-zone hint: a scoped, low-emphasis label over the pooled unlinked
    // dots. Only present when iso nodes exist; visibility follows the toggle via
    // the .iso-hidden class on the SVG root (CSS hides it together with the dots).
    if (isoCount > 0) {
      container.append('text').attr('class', 'gp-park-label')
        .attr('text-anchor', 'middle')
        .attr('x', ZONE.isoX).attr('y', ZONE.isoY - 22)
        .text('unlinked · no relations');
    }

    var link = container.append('g').selectAll('line').data(links).join('line')
      .attr('class', 'link')
      .attr('stroke', function (d) {
        var sid = typeof d.source === 'object' ? d.source.id : d.source;
        return typeMeta(nodeById.get(sid).type).color;
      })
      .attr('stroke-width', function (d) { return (d.rel === 'replaces' || d.rel === 'supersedes') ? 2 : 1; })
      // Dash period = 12 for every link so the single gp-flow keyframe loops
      // seamlessly. replaces/supersedes get a heavier dash to stay distinct.
      .attr('stroke-dasharray', function (d) { return (d.rel === 'replaces' || d.rel === 'supersedes') ? '9 3' : '6 6'; });

    var node = container.append('g').selectAll('g').data(NODES).join('g')
      .attr('class', function (d) { return 'node' + (d.iso ? ' is-iso' : ''); })
      .style('cursor', 'pointer')
      .style('opacity', 0)
      .call(d3.drag()
        .on('start', function (e, d) { if (!e.active) sim.alphaTarget(0.3).restart(); d.fx = d.x; d.fy = d.y; })
        .on('drag', function (e, d) { d.fx = e.x; d.fy = e.y; })
        .on('end', function (e, d) { if (!e.active) sim.alphaTarget(0); d.fx = null; d.fy = null; }));

    // Hub breathing: high-degree nodes get a slow, stronger pulsing glow so
    // they read as the gravitational centres of the network. Duration shrinks
    // and amplitude grows with degree (capped). Driven by CSS keyframe 'gp-breathe'
    // via a per-node class + inline animation-duration. reduced-motion = no anim.
    var maxDeg = 1;
    NODES.forEach(function (n) { if (n.deg > maxDeg) maxDeg = n.deg; });
    node.append('circle').attr('class', 'node-glow')
      .attr('r', function (d) { return d.iso ? 0 : radius(d) * 2.4; })
      .attr('fill', function (d) { return typeMeta(d.type).color; })
      .classed('hub', function (d) { return !REDUCED_MOTION && !d.iso && d.deg >= 4; })
      .style('animation-duration', function (d) {
        if (REDUCED_MOTION || d.deg < 4) return null;
        // deg 4 -> ~5.2s (calm), high-deg hub -> ~2.6s (urgent throb)
        var f = Math.min(d.deg / maxDeg, 1);
        return (5.2 - f * 2.6).toFixed(2) + 's';
      });
    var isDimStatus = function (d) { return !!DIM_STATUS[(d.status || '').toLowerCase()]; };
    node.append('circle').attr('class', 'node-core')
      .attr('r', function (d) { return d.iso ? 2.7 : radius(d); })
      .attr('fill', function (d) { return typeMeta(d.type).color; })
      // Tiny iso dots skip the glow filter (cheaper + visually dezent per spec).
      .attr('filter', function (d) { return d.iso ? null : 'url(#gp-glow)'; })
      // Status encoding: archived/deprecated/completed/superseded/closed fade
      // back; live docs stay bright. Drives visual "what's still alive" hierarchy.
      .classed('inactive', isDimStatus)
      .attr('stroke', 'rgba(10,14,20,0.8)').attr('stroke-width', 1.5);
    node.append('text')
      .attr('class', function (d) { return 'label' + (d.deg >= 4 ? ' is-hub' : ''); })
      .attr('dy', function (d) { return radius(d) + 13; }).attr('text-anchor', 'middle')
      .text(function (d) { return d.title.length > 22 ? d.title.slice(0, 21) + '…' : d.title; });

    // staggered fade-in of nodes
    node.transition().duration(500).delay(function (d, i) { return Math.min(i * 12, 800); })
      .style('opacity', 1);

    // adjacency for hover-highlight
    var adj = {};
    NODES.forEach(function (n) { adj[n.id] = new Set([n.id]); });
    links.forEach(function (l) {
      var s = typeof l.source === 'object' ? l.source.id : l.source;
      var t = typeof l.target === 'object' ? l.target.id : l.target;
      adj[s].add(t); adj[t].add(s);
    });

    function highlight(d) {
      var near = adj[d.id];
      node.selectAll('.node-core').classed('dim', function (n) { return !near.has(n.id); });
      node.selectAll('.node-glow').style('opacity', function (n) { return near.has(n.id) ? 0.7 : 0.1; });
      node.selectAll('.label').classed('hot', function (n) { return near.has(n.id); })
        .classed('dim', function (n) { return !near.has(n.id); });
      link.classed('hot', function (l) { return l.source.id === d.id || l.target.id === d.id; })
        .classed('dim', function (l) { return !(l.source.id === d.id || l.target.id === d.id); });
    }
    function clearHL() {
      node.selectAll('.node-core').classed('dim', false);
      node.selectAll('.node-glow').style('opacity', 0.55);
      node.selectAll('.label').classed('hot', false).classed('dim', false);
      link.classed('hot', false).classed('dim', false);
    }

    node.on('mouseenter', function (e, d) {
      highlight(d);
      // Hover pulse-burst: fire an extra wave of synapse particles along this
      // node's incident edges so a hover "lights up" its immediate neighbourhood.
      burstFromNode(d);
    })
      .on('mouseleave', function () { if (!selected) clearHL(); else highlight(selected); });
    node.on('click', function (e, d) { e.stopPropagation(); openDetail(d, links, clearHL, highlight); });

    // live search
    if (els.search) {
      els.search.oninput = function (e) {
        var q = e.target.value.toLowerCase().trim();
        if (!q) { if (selected) highlight(selected); else clearHL(); return; }
        var match = function (n) {
          return n.title.toLowerCase().indexOf(q) >= 0 ||
                 ('' + n.id).indexOf(q) >= 0 || (n.type || '').indexOf(q) >= 0;
        };
        node.selectAll('.node-core').classed('dim', function (n) { return !match(n); });
        node.selectAll('.node-glow').style('opacity', function (n) { return match(n) ? 0.8 : 0.06; });
        node.selectAll('.label').classed('hot', match).classed('dim', function (n) { return !match(n); });
        link.classed('dim', true).classed('hot', false);
      };
    }

    // legend (clickable type filter)
    buildLegend(NODES, node, link);

    // ---- Isolated-node visibility toggle ----------------------------------
    // Default: unlinked nodes hidden. A toolbar chip flips the .iso-hidden class
    // on the SVG root; CSS hides both the .is-iso node groups and the park label
    // together. The chip only appears when there actually are isolated nodes.
    svgSel.classed('iso-hidden', !showIso);
    setupIsoToggle(isoCount, function (next) {
      showIso = next;
      svgSel.classed('iso-hidden', !showIso);
    });

    // expose for openDetail closure access
    drawGraph._link = link;
    drawGraph._node = node;
    drawGraph._highlight = highlight;
    drawGraph._clearHL = clearHL;

    sim.on('tick', function () {
      link.attr('x1', function (d) { return d.source.x; }).attr('y1', function (d) { return d.source.y; })
        .attr('x2', function (d) { return d.target.x; }).attr('y2', function (d) { return d.target.y; });
      node.attr('transform', function (d) { return 'translate(' + d.x + ',' + d.y + ')'; });
    });

    // ---- Synapse pulses: action-potentials travelling source -> target ----
    startPulseLoop(svgSel, container, links, nodeById, node);
  }

  // ============================================================
  //  Synapse-pulse animation (independent rAF loop, not sim-tick)
  // ============================================================

  // Stop + fully tear down the running pulse loop. Idempotent. Called from the
  // renderGraph teardown so a project switch can never leave a second loop alive.
  function stopPulseLoop() {
    if (pulseRAF != null) { cancelAnimationFrame(pulseRAF); pulseRAF = null; }
    pulseState = null;
  }

  // Build the particle pool + edge schedule and kick off the rAF loop.
  function startPulseLoop(svgSel, container, links, nodeById, nodeSel) {
    stopPulseLoop();
    if (REDUCED_MOTION || !links.length) return;

    // Sample up to MAX_PULSES edges so dense graphs stay smooth.
    var edges = links;
    if (links.length > MAX_PULSES) {
      edges = links.slice();
      for (var i = edges.length - 1; i > 0; i--) {
        var j = Math.floor(Math.random() * (i + 1));
        var tmp = edges[i]; edges[i] = edges[j]; edges[j] = tmp;
      }
      edges = edges.slice(0, MAX_PULSES);
    }

    // Per-edge organic timing: random phase offset + speed (cycles/second).
    var sched = edges.map(function (l) {
      var sid = typeof l.source === 'object' ? l.source.id : l.source;
      var sn = nodeById.get(sid);
      return {
        link: l,
        phase: Math.random(),                 // 0..1 start offset
        speed: 0.12 + Math.random() * 0.22,   // travel cycles per second
        color: typeMeta(sn ? sn.type : '').color,
        firedThisCycle: false
      };
    });

    // Reusable circle pool inside the zoom/pan container (so pulses ride along).
    var gPulse = container.append('g').attr('class', 'gp-pulse-layer');
    var pool = gPulse.selectAll('circle').data(sched).join('circle')
      .attr('class', 'gp-pulse')
      .attr('r', 2.6)
      .attr('fill', function (s) { return s.color; })
      .attr('filter', 'url(#gp-glow)');
    var poolNodes = pool.nodes();

    pulseState = {
      sched: sched, poolNodes: poolNodes, nodeSel: nodeSel,
      bursts: [], last: 0
    };

    var loop = function (ts) {
      pulseRAF = requestAnimationFrame(loop);
      var st = pulseState;
      if (!st) return;
      // Performance guard: idle when the page is hidden or the graph view is
      // not the active SPA page. We keep the rAF alive (cheap) but skip work.
      if (document.hidden || !els.root || !els.root.classList.contains('active')) {
        st.last = ts; return;
      }
      var dt = st.last ? Math.min((ts - st.last) / 1000, 0.05) : 0;
      st.last = ts;

      for (var k = 0; k < st.sched.length; k++) {
        var s = st.sched[k];
        var c = st.poolNodes[k];
        var l = s.link;
        var src = l.source, tgt = l.target;
        if (!src || !tgt || src.x == null || tgt.x == null) { c.style.opacity = 0; continue; }

        s.phase += s.speed * dt;
        if (s.phase >= 1) { s.phase -= Math.floor(s.phase); s.firedThisCycle = false; }
        var f = s.phase;

        // Node-firing flash when a pulse reaches its target (frac near 1).
        if (f > 0.92 && !s.firedThisCycle) {
          s.firedThisCycle = true;
          fireNode(st.nodeSel, tgt);
        }

        var x = src.x + (tgt.x - src.x) * f;
        var y = src.y + (tgt.y - src.y) * f;
        c.setAttribute('cx', x);
        c.setAttribute('cy', y);
        // Fade in/out at the ends so particles "emit" and "absorb" smoothly.
        var op = Math.sin(f * Math.PI);
        c.style.opacity = (0.25 + op * 0.75).toFixed(3);
      }
      st.last = ts;
    };
    pulseRAF = requestAnimationFrame(loop);
  }

  // Brief activation flash on a node when a pulse lands (CSS transition handles
  // the pop+fade; class auto-clears so repeated hits keep re-triggering).
  function fireNode(nodeSel, datum) {
    if (!nodeSel) return;
    nodeSel.filter(function (n) { return n.id === datum.id; }).each(function () {
      var g = this;
      g.classList.remove('firing');
      // force reflow so the class re-add restarts the transition
      void g.getBoundingClientRect();
      g.classList.add('firing');
      window.setTimeout(function () { g.classList.remove('firing'); }, 260);
    });
  }

  // Hover burst: nudge the phase of incident edges so a fresh wave of pulses
  // leaves the hovered node immediately (lights up the neighbourhood).
  function burstFromNode(datum) {
    var st = pulseState;
    if (!st) return;
    for (var k = 0; k < st.sched.length; k++) {
      var l = st.sched[k].link;
      var sid = l.source && l.source.id, tid = l.target && l.target.id;
      if (sid === datum.id) { st.sched[k].phase = 0.02; st.sched[k].firedThisCycle = false; }
      else if (tid === datum.id) {
        // reverse-incident: send from the far end so the wave converges here
        st.sched[k].phase = 0.02; st.sched[k].firedThisCycle = false;
      }
    }
  }

  function buildLegend(NODES, node, link) {
    var counts = {};
    NODES.forEach(function (n) { counts[n.type] = (counts[n.type] || 0) + 1; });
    var hidden = new Set();
    els.legend.innerHTML = '';
    Object.keys(TYPES).forEach(function (key) {
      if (!counts[key]) return;
      var t = TYPES[key];
      var el = document.createElement('div');
      el.className = 'gp-legend-item';
      el.innerHTML = '<span class="swatch" style="background:' + t.color + ';color:' + t.color + '"></span>' +
        escHtml(t.label) + '<span class="cnt">' + counts[key] + '</span>';
      el.onclick = function () {
        if (hidden.has(key)) hidden.delete(key); else hidden.add(key);
        el.classList.toggle('off');
        node.style('display', function (n) { return hidden.has(n.type) ? 'none' : null; });
        link.style('display', function (l) {
          return (hidden.has(l.source.type) || hidden.has(l.target.type)) ? 'none' : null;
        });
      };
      els.legend.appendChild(el);
    });
    // any unknown/unmapped types fall through with default tone
    Object.keys(counts).forEach(function (key) {
      if (TYPES[key]) return;
      var t = typeMeta(key);
      var el = document.createElement('div');
      el.className = 'gp-legend-item';
      el.innerHTML = '<span class="swatch" style="background:' + t.color + ';color:' + t.color + '"></span>' +
        escHtml(t.label) + '<span class="cnt">' + counts[key] + '</span>';
      els.legend.appendChild(el);
    });
  }

  // Inject (once) + sync the toolbar chip that toggles isolated-node visibility.
  // Lives in .gp-toolbar; created lazily via JS so index.html needs no edit. The
  // chip is hidden when the project has no isolated nodes. `onToggle(next)` is
  // called with the new desired visibility; the active class mirrors the state.
  function setupIsoToggle(isoCount, onToggle) {
    var toolbar = $('.gp-toolbar');
    if (!toolbar) return;
    var chip = toolbar.querySelector('.gp-iso-toggle');
    if (!chip) {
      chip = document.createElement('button');
      chip.type = 'button';
      chip.className = 'gp-iso-toggle';
      toolbar.appendChild(chip);
    }
    if (isoCount <= 0) { chip.style.display = 'none'; return; }
    chip.style.display = '';
    var active = false;   // reset to default (hidden) on every render
    var paint = function () {
      chip.classList.toggle('on', active);
      chip.setAttribute('aria-pressed', active ? 'true' : 'false');
      chip.textContent = '⊙ ' + isoCount + ' unlinked';
    };
    paint();
    chip.onclick = function () { active = !active; paint(); onToggle(active); };
  }

  // ---- detail panel ----
  function openDetail(d, links, clearHL, highlight) {
    selected = d;
    highlight(d);
    var t = typeMeta(d.type);
    els.dSwatch.style.color = t.color;
    els.dType.textContent = t.label;
    els.dTitle.textContent = d.title;
    els.dId.textContent = '#' + d.id;
    if (d.status) { els.dStatus.innerHTML = 'status <b>' + escHtml(d.status) + '</b>'; els.dStatus.style.display = ''; }
    else els.dStatus.style.display = 'none';
    els.dSummary.textContent = d.summary || 'No summary available.';

    // "open doc" deep-link to the existing admin doc view, if id looks numeric.
    if (/^\d+$/.test('' + d.id)) {
      els.dOpen.style.display = '';
      els.dOpen.onclick = function (e) {
        if (e) e.preventDefault();
        if (window.App && typeof App.openDoc === 'function') App.openDoc(d.id);
        else location.hash = 'doc/' + d.id;
      };
    } else {
      els.dOpen.style.display = 'none';
    }

    var rels = links.filter(function (l) { return l.source.id === d.id || l.target.id === d.id; })
      .map(function (l) {
        var other = l.source.id === d.id ? l.target : l.source;
        var dir = l.source.id === d.id ? l.rel : '← ' + l.rel;
        return { other: other, verb: dir };
      });
    els.dRels.innerHTML = rels.map(function (r) {
      return '<div class="rel"><span class="verb">' + escHtml(r.verb) + '</span>' +
        '<span style="color:' + typeMeta(r.other.type).color + '">●</span> ' + escHtml(r.other.title) + '</div>';
    }).join('') || '<div class="rel" style="color:var(--g-text-dim)">No relations</div>';

    els.detail.classList.add('open');
  }

  function closeDetail() {
    selected = null;
    els.detail.classList.remove('open');
    if (drawGraph._clearHL) drawGraph._clearHL();
  }

  // ---- resize ----
  function onResize() {
    if (!sim || !els.root) return;
    if (!els.root.classList.contains('active')) return;
    var W = els.root.clientWidth || window.innerWidth;
    var H = els.root.clientHeight || window.innerHeight;
    d3.select(els.svg).attr('viewBox', [0, 0, W, H]);
    // Recompute the connected/park zones for the new viewport. The force-x/y
    // accessors read sim._gpZone live, so mutating it in place re-targets both
    // poles without re-adding forces; the park label is moved to match.
    var ZONE = computeZones(W, H);
    if (sim._gpZone) {
      sim._gpZone.connX = ZONE.connX; sim._gpZone.connY = ZONE.connY;
      sim._gpZone.isoX = ZONE.isoX;   sim._gpZone.isoY = ZONE.isoY;
    }
    d3.select(els.svg).select('.gp-park-label')
      .attr('x', ZONE.isoX).attr('y', ZONE.isoY - 22);
    sim.alpha(0.3).restart();
  }

  // ---- helpers ----
  // GET via the same convention as Api.request: 'api'+path, same-origin cookie,
  // no CSRF for GET. Kept local so graph.js has no hard Api dependency.
  async function apiGet(path) {
    var res = await fetch('api/' + path, { method: 'GET', credentials: 'same-origin' });
    if (res.status === 401) {
      if (window.App && App.showLogin) App.showLogin('Session expired. Please sign in again.');
      throw new Error('session_expired');
    }
    if (!res.ok) throw new Error('request_failed');
    return res.json();
  }

  function escHtml(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function escAttr(s) { return escHtml(s); }

  // Reflect the selected project into the URL so F5 / bookmarks restore it.
  function syncHash() {
    if (!currentSlug) return;
    var h = 'graph/' + currentSlug;
    if (location.hash.replace('#', '') !== h) location.hash = h;
  }

  return {
    loadGraphPage: loadGraphPage,
    setPendingSlug: function (s) { pendingSlug = s; }
  };
})();
