/* ============================================================
   graph3d.js — mxLore per-project Knowledge Graph in 3D
   Hand-rolled Three.js (r134, global THREE) + THREE.OrbitControls.
   Mirrors universe.js patterns (setup, fly-to tween, glow texture,
   rAF guard, full dispose). One project = one force-laid-out network:
   glowing doc-nodes (colour = doc_type), additive link lines with
   travelling "synapse" particles. Settle-then-FREEZE layout (no
   perpetual force) so up to ~2000 nodes stay smooth.

   Public: Graph3D.mount({container, slug, onBack, onOpenDoc})
           Graph3D.destroy() / Graph3D.isMounted()
   Data:   GET /api/graph?project=<slug>&limit=2000
           { nodes:[{id,type,title,summary,status}],
             links:[{s,t,rel}], total_nodes, truncated, ... }
   All DOM stays under #page-graph; HUD styled via css/graph.css.
   ============================================================ */

var Graph3D = (function () {
  'use strict';

  // doc_type -> color (mirrors universe.js / graph.js TYPES palette).
  var TYPE_COLOR = {
    lesson: '#3ee08a', spec: '#4aa3ff', plan: '#b07cff', decision: '#ffb340',
    reference: '#2fe0d0', feature_request: '#ff6bb0', session_note: '#7889a8',
    bugreport: '#ff5a6e', note: '#d4c98a', todo: '#ff9d5c', workflow_log: '#5cc8ff'
  };
  var TYPE_LABEL = {
    lesson: 'Lesson', spec: 'Spec', plan: 'Plan', decision: 'Decision / ADR',
    reference: 'Reference', feature_request: 'Feature Request',
    session_note: 'Session Note', bugreport: 'Bug Report', note: 'Note',
    todo: 'Todo', workflow_log: 'Workflow Log'
  };
  var DEFAULT_COLOR = '#7889a8';
  function colorOf(t) { return TYPE_COLOR[t] || DEFAULT_COLOR; }
  function labelOf(t) { return TYPE_LABEL[t] || (t || 'unknown'); }

  var DIM_STATUS = { archived: 1, deprecated: 1, completed: 1, superseded: 1, closed: 1 };

  // Performance caps (keep up to ~2000 nodes smooth).
  var MAX_PARTICLES = 6000;     // total travelling synapse particles
  var BIG_GRAPH = 900;          // above this: cheaper layout sampling
  var LABEL_PX = 15;            // desired on-screen label height in CSS pixels (constant size)
  var LABEL_MIN_SCALE = 4;      // hard floor for world-scale (never vanish)
  var LABEL_MAX_SCALE = 90;     // hard ceiling for world-scale (never fill the screen)

  var REDUCED_MOTION = (typeof window.matchMedia === 'function') &&
    window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  // ---- module state (single live instance, like universe.js) ----
  var S = null;
  var _wp = null;   // scratch world-pos vector (lazily created)
  var _proj = null; // scratch projection vector (lazily created)

  var LABEL_THROTTLE = 3;       // recompute label set every N frames (cheap in between)
  var LABEL_CAND_CAP = 40;      // max candidates fed into the O(n^2) overlap solver
  var LABEL_PAD = 4;            // px padding around each label rect for overlap test

  // ============================================================
  //  Mount
  // ============================================================
  function mount(opts) {
    opts = opts || {};
    var container = opts.container;
    if (!container) return;
    if (S) destroy();
    if (typeof THREE === 'undefined') return;

    S = {
      container: container,
      slug: opts.slug || '',
      onBack: opts.onBack || function () {},
      onOpenDoc: opts.onOpenDoc || function () {},
      raf: null,
      disposables: [],
      nodes: [],          // { id,type,title,summary,status,deg,pos,sprite,baseScale,baseColor,labelSprite }
      links: [],          // { s,t,rel,strong }
      adj: {},            // id -> Set(neighbour ids incl self)
      nodeById: {},
      tween: null,
      hovered: null,
      selected: null,
      search: '',          // live toolbar query (lowercased)
      searchMatch: null,   // Set of matched node ids (or null)
      clustered: null,     // Set of node ids pulled into a search-gather cluster
      anim: null,          // active gather/release position tween
      _gatherTimer: null,  // debounce timer for the gather re-layout
      glowTexture: null,
      linkObj: null,
      particleObj: null,
      particles: [],      // { si,ti,phase,speed } per travelling particle
      frozen: false,
      idleTimer: null,
      homeCam: null,      // camera home position (full view)
      homeTarget: null,
      planet: null,       // THREE.Group holding nodes/links/particles/core/halo
      planetSpin: 0,      // rad/s slow self-rotation (0 under reduced-motion)
      core: null,         // glowing project core sprite
      coreSphere: null,   // small solid core mesh
      halo: null,         // transparent atmosphere sphere
      fadeT: 1            // mount fade-in progress (0 -> 1), 1 = fully shown
    };

    var W = container.clientWidth || window.innerWidth;
    var H = container.clientHeight || window.innerHeight;

    var scene = new THREE.Scene();
    var camera = new THREE.PerspectiveCamera(55, W / H, 0.1, 8000);
    camera.position.set(0, 30, 360);

    var renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
    renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
    renderer.setSize(W, H);
    renderer.setClearColor(0x000000, 0);   // transparent; CSS nebula shows through
    container.appendChild(renderer.domElement);

    var controls = new THREE.OrbitControls(camera, renderer.domElement);
    controls.enableDamping = true;
    controls.dampingFactor = 0.08;
    controls.rotateSpeed = 0.55;
    controls.zoomSpeed = 0.9;
    controls.minDistance = 20;
    controls.maxDistance = 3000;
    controls.autoRotate = !REDUCED_MOTION;
    controls.autoRotateSpeed = 0.28;
    var idleTimer = null;
    controls.addEventListener('start', function () {
      controls.autoRotate = false;
      if (S) S.fadeT = 1;   // user took over -> cancel mount fly-in
      if (idleTimer) { clearTimeout(idleTimer); idleTimer = null; }
    });
    controls.addEventListener('end', function () {
      if (REDUCED_MOTION || !S || S.selected) return;   // no autoRotate while focused
      if (idleTimer) clearTimeout(idleTimer);
      idleTimer = setTimeout(function () { if (S && !S.selected) controls.autoRotate = true; }, 2800);
    });

    S.scene = scene;
    S.camera = camera;
    S.renderer = renderer;
    S.controls = controls;
    S.idleTimer = idleTimer;
    S.glowTexture = makeGlowTexture();
    S.disposables.push(S.glowTexture);

    buildHud(container);

    S.raycaster = new THREE.Raycaster();
    S.raycaster.params.Sprite = {};
    S.pointer = new THREE.Vector2();
    S.pointerClient = { x: 0, y: 0 };
    S.pointerInside = false;

    renderer.domElement.addEventListener('pointermove', onPointerMove);
    renderer.domElement.addEventListener('pointerleave', onPointerLeave);
    renderer.domElement.addEventListener('click', onClick);
    window.addEventListener('resize', onResize);
    document.addEventListener('visibilitychange', onVisibility);
    document.addEventListener('keydown', onKeyDown);
    S.onResize = onResize;
    S.onVisibility = onVisibility;
    S.onKeyDown = onKeyDown;

    loadData(S.slug).then(function (data) {
      if (!S) return;   // destroyed mid-flight
      buildGraph(data);
      startLoop();
    });

    // ---- nested handlers (closure over S) ----
    function onResize() {
      if (!S) return;
      var w = container.clientWidth || window.innerWidth;
      var h = container.clientHeight || window.innerHeight;
      camera.aspect = w / h;
      camera.updateProjectionMatrix();
      renderer.setSize(w, h);
    }
    function onVisibility() { /* loop checks document.hidden each frame */ }
    function onPointerMove(e) {
      var r = renderer.domElement.getBoundingClientRect();
      S.pointer.x = ((e.clientX - r.left) / r.width) * 2 - 1;
      S.pointer.y = -((e.clientY - r.top) / r.height) * 2 + 1;
      S.pointerClient.x = e.clientX - r.left;
      S.pointerClient.y = e.clientY - r.top;
      S.pointerInside = true;
    }
    function onPointerLeave() {
      S.pointerInside = false;
      if (!S.selected) setHover(null);
    }
    function onClick() {
      if (!S || S.tween) return;
      if (S.hovered) { selectNode(S.hovered); }
      else if (S.selected) { deselect(); }   // click empty space -> back to overview
    }
    // Esc -> fly back to overview when a node is focused. Only acts on 3D mode
    // and only consumes the key when there is something to deselect.
    function onKeyDown(e) {
      if (!S || S.tween) return;
      if (e.key !== 'Escape' && e.keyCode !== 27) return;
      var root = document.getElementById('page-graph');
      if (!root || !root.classList.contains('g3d-mode')) return;
      if (S.selected) { e.preventDefault(); deselect(); }
    }
  }

  // ============================================================
  //  Data
  // ============================================================
  function loadData(slug) {
    return fetch('api/graph?project=' + encodeURIComponent(slug) + '&limit=2000',
      { method: 'GET', credentials: 'same-origin' })
      .then(function (res) {
        if (res.status === 401) {
          if (window.App && App.showLogin) App.showLogin('Session expired. Please sign in again.');
          throw new Error('session_expired');
        }
        if (!res.ok) throw new Error('request_failed');
        return res.json();
      })
      .catch(function () { return { nodes: [], links: [] }; });
  }

  // ============================================================
  //  Build graph: nodes, settle-then-freeze layout, links, particles
  // ============================================================
  function buildGraph(data) {
    var rawNodes = (data && data.nodes || []);
    var rawLinks = (data && data.links || []);

    setHud(data);
    if (rawNodes.length === 0) { showEmpty(true); return; }
    showEmpty(false);

    // Node records + id index.
    var nodes = rawNodes.map(function (n) {
      return {
        id: n.id, type: n.type, title: n.title || ('#' + n.id),
        summary: n.summary || '', status: n.status || '', deg: 0,
        pos: new THREE.Vector3(), vel: new THREE.Vector3()
      };
    });
    var byId = {};
    nodes.forEach(function (n, i) { byId[n.id] = i; });

    // Keep only links whose endpoints exist; compute degree + adjacency.
    var adj = {};
    nodes.forEach(function (n) { adj[n.id] = new Set([n.id]); });
    var links = [];
    rawLinks.forEach(function (l) {
      var a = byId[l.s], b = byId[l.t];
      if (a == null || b == null || a === b) return;
      var strong = l.rel === 'replaces' || l.rel === 'supersedes';
      links.push({ s: a, t: b, rel: l.rel, strong: strong });
      nodes[a].deg++; nodes[b].deg++;
      adj[nodes[a].id].add(nodes[b].id);
      adj[nodes[b].id].add(nodes[a].id);
    });

    S.nodes = nodes;
    S.links = links;
    S.adj = adj;
    S.nodeById = byId;

    layoutForce(nodes, links);     // settle-then-freeze

    // Planet group: nodes/links/particles/core/halo all live here so the
    // whole project can slowly self-rotate like a planet. nd.pos stays the
    // canonical LOCAL layout; worldPos() maps to world for camera math.
    var planet = new THREE.Group();
    S.scene.add(planet);
    S.planet = planet;
    S.planetSpin = REDUCED_MOTION ? 0 : 0.045;   // slow, ~2.6 deg/s

    buildCore(nodes);              // glowing core + halo at the cloud centre
    buildNodeSprites(nodes);
    buildLinks(nodes, links);
    buildParticles(nodes, links);
    frameAll(false);               // set camera home to fit the whole graph

    // Mount "fly-in" so opening a project feels like a continuation of the
    // universe galaxy fly-through (no hard cut). Start near the core, ease
    // out to the overview home. Robust: a plain camera dolly, no cross-fade.
    if (!REDUCED_MOTION && S.homeCam && S.homeTarget) {
      S.fadeT = 0;
      var center = S.homeTarget.clone();
      var dir = S.homeCam.clone().sub(center);
      var len = dir.length() || 1;
      dir.multiplyScalar(1 / len);
      // begin at ~32% of the home distance -> a swift pull-back into overview
      S.fadeFrom = center.clone().add(dir.multiplyScalar(len * 0.32));
      S.fadeTo = S.homeCam.clone();
      S.fadeTarget = center;
      S.camera.position.copy(S.fadeFrom);
      S.controls.target.copy(S.fadeTarget);
      S.camera.lookAt(S.fadeTarget);
    } else {
      S.fadeT = 1;
    }
  }

  // Mount fly-in: ease the camera from a near start out to the overview home.
  // Disabled by user interaction (OrbitControls) and by any focus tween.
  function updateFade(dt) {
    if (S.fadeT >= 1 || !S.fadeTo) return;
    if (S.tween || S.selected) { S.fadeT = 1; return; }   // yield to focus-zoom
    S.fadeT += dt / 0.95;
    var e = S.fadeT >= 1 ? 1 : easeInOut(S.fadeT);
    S.camera.position.lerpVectors(S.fadeFrom, S.fadeTo, e);
    S.controls.target.lerpVectors(S.fadeTarget, S.homeTarget, e);
    S.camera.lookAt(S.controls.target);
    if (S.fadeT >= 1) { S.fadeFrom = S.fadeTo = S.fadeTarget = null; }
  }

  // ---- Project "atmosphere" only — NO bright central sun ----
  // The doc-nodes themselves are the stars; the centre stays dark/empty.
  // Previously this built an additive glow sprite + a bright solid core
  // sphere that visually drowned out every node. Both are removed. All that
  // remains is an optional, barely-there translucent aura so the cloud reads
  // as a coherent body — NOT a light source (non-additive, very low opacity,
  // so it can never overpower the nodes).
  function buildCore(nodes) {
    var center = new THREE.Vector3();
    var i;
    for (i = 0; i < nodes.length; i++) center.add(nodes[i].pos);
    center.multiplyScalar(1 / Math.max(1, nodes.length));
    var radius = 1;
    for (i = 0; i < nodes.length; i++) {
      var d = center.distanceTo(nodes[i].pos);
      if (d > radius) radius = d;
    }
    S.cloudCenter = center.clone();
    S.cloudRadius = radius;
    S.core = null;          // no sun
    S.coreSphere = null;    // no bright core body

    // Subtle aura: large faint BackSide sphere. Normal blending (not additive)
    // + tiny opacity -> a faint dark-blue hush behind the nodes, never a glow.
    var hgeo = new THREE.SphereGeometry(radius * 1.18 + 30, 32, 24);
    var hmat = new THREE.MeshBasicMaterial({
      color: 0x1a2740, transparent: true, opacity: 0.04,
      side: THREE.BackSide, depthWrite: false
    });
    var halo = new THREE.Mesh(hgeo, hmat);
    halo.position.copy(center);
    S.planet.add(halo);
    S.disposables.push(hgeo, hmat);
    S.halo = halo;
  }

  // Local -> world position (planet group may be rotated).
  function worldPos(nd, out) {
    out = out || (_wp || (_wp = new THREE.Vector3()));
    out.copy(nd.pos);
    if (S.planet) {
      S.planet.updateMatrixWorld();
      S.planet.localToWorld(out);
    }
    return out;
  }

  // ---- 3D force layout: many-body repulsion + link springs + centering ----
  // Runs a fixed, cooling number of ticks then FREEZES (positions baked into
  // sprite/line geometry). No perpetual simulation. For big graphs we sample
  // the repulsion (O(n*k) instead of O(n^2)) to stay within budget.
  function layoutForce(nodes, links) {
    var n = nodes.length;
    var big = n > BIG_GRAPH;
    var iters = big ? 200 : 320;
    var spread = 60 + Math.pow(n, 0.5) * 22;

    // Seed on a Fibonacci sphere (even, deterministic-ish start).
    var ga = Math.PI * (3 - Math.sqrt(5));
    for (var i = 0; i < n; i++) {
      var y = 1 - (i / Math.max(1, n - 1)) * 2;
      var rad = Math.sqrt(Math.max(0, 1 - y * y));
      var th = ga * i;
      nodes[i].pos.set(Math.cos(th) * rad * spread,
                       y * spread * 0.7,
                       Math.sin(th) * rad * spread);
    }

    var repK = big ? 9000 : 6000;        // repulsion strength
    var sample = big ? 18 : 0;           // >0 => sample N others per node
    var springLen = 36;
    var springK = 0.04;
    var centerK = 0.012;

    for (var it = 0; it < iters; it++) {
      var alpha = 1 - it / iters;        // cooling 1 -> 0
      var step = 0.85 * alpha + 0.04;

      // reset forces into vel (reused as accumulator)
      for (var a = 0; a < n; a++) nodes[a].vel.set(0, 0, 0);

      // Many-body repulsion (full or sampled).
      if (sample > 0) {
        for (var p = 0; p < n; p++) {
          var np = nodes[p];
          for (var q = 0; q < sample; q++) {
            var r = (p + 1 + Math.floor(Math.random() * (n - 1))) % n;
            applyRepulsion(np, nodes[r], repK * (n / sample));
          }
        }
      } else {
        for (var u = 0; u < n; u++) {
          for (var v = u + 1; v < n; v++) {
            applyRepulsionPair(nodes[u], nodes[v], repK);
          }
        }
      }

      // Link springs (attraction toward natural length).
      for (var li = 0; li < links.length; li++) {
        var s = nodes[links[li].s], t = nodes[links[li].t];
        var dx = t.pos.x - s.pos.x, dy = t.pos.y - s.pos.y, dz = t.pos.z - s.pos.z;
        var d = Math.sqrt(dx * dx + dy * dy + dz * dz) || 0.001;
        var f = (d - springLen) * springK / d;
        s.vel.x += dx * f; s.vel.y += dy * f; s.vel.z += dz * f;
        t.vel.x -= dx * f; t.vel.y -= dy * f; t.vel.z -= dz * f;
      }

      // Gentle centering + integrate.
      for (var c = 0; c < n; c++) {
        var nc = nodes[c];
        nc.vel.x -= nc.pos.x * centerK; nc.vel.y -= nc.pos.y * centerK; nc.vel.z -= nc.pos.z * centerK;
        nc.pos.x += nc.vel.x * step; nc.pos.y += nc.vel.y * step; nc.pos.z += nc.vel.z * step;
      }
    }

    // Normalize extent so the camera's frame-all never zooms to a tiny speck.
    // Sparse graphs (esp. link-less "deg-0" nodes that only feel repulsion)
    // let the cloud blow up arbitrarily; rescale by a ROBUST radius (85th pct,
    // so a few outliers don't dominate) then clamp the rest onto the shell.
    if (n > 1) {
      var ctr = new THREE.Vector3();
      for (var m = 0; m < n; m++) ctr.add(nodes[m].pos);
      ctr.multiplyScalar(1 / n);
      var radii = [];
      for (var m2 = 0; m2 < n; m2++) { nodes[m2].pos.sub(ctr); radii.push(nodes[m2].pos.length()); }
      radii.sort(function (x, y) { return x - y; });
      var robustR = radii[Math.floor(radii.length * 0.85)] || radii[radii.length - 1] || 1;
      var targetR = 70 + Math.pow(n, 0.5) * 24;
      var hardR = targetR * 1.25;
      if (robustR > 1) {
        var nsc = targetR / robustR;
        for (var m3 = 0; m3 < n; m3++) {
          var np2 = nodes[m3].pos.multiplyScalar(nsc);
          var mag = np2.length();
          if (mag > hardR) np2.multiplyScalar(hardR / mag);
        }
      }
    }
    S.frozen = true;
  }
  function applyRepulsionPair(a, b, k) {
    var dx = a.pos.x - b.pos.x, dy = a.pos.y - b.pos.y, dz = a.pos.z - b.pos.z;
    var d2 = dx * dx + dy * dy + dz * dz + 0.5;
    var f = k / d2;
    var inv = 1 / Math.sqrt(d2);
    var fx = dx * inv * f, fy = dy * inv * f, fz = dz * inv * f;
    a.vel.x += fx; a.vel.y += fy; a.vel.z += fz;
    b.vel.x -= fx; b.vel.y -= fy; b.vel.z -= fz;
  }
  function applyRepulsion(a, b, k) {   // one-directional (sampled mode)
    var dx = a.pos.x - b.pos.x, dy = a.pos.y - b.pos.y, dz = a.pos.z - b.pos.z;
    var d2 = dx * dx + dy * dy + dz * dz + 0.5;
    var f = k / d2;
    var inv = 1 / Math.sqrt(d2);
    a.vel.x += dx * inv * f; a.vel.y += dy * inv * f; a.vel.z += dz * inv * f;
  }

  // ---- Node sprites (glowing additive, size ~ degree, colour = type) ----
  function buildNodeSprites(nodes) {
    var maxDeg = 1;
    nodes.forEach(function (nd) { if (nd.deg > maxDeg) maxDeg = nd.deg; });

    nodes.forEach(function (nd) {
      var col = new THREE.Color(colorOf(nd.type));
      var dimmed = !!DIM_STATUS[(nd.status || '').toLowerCase()];
      var degF = Math.min(1, nd.deg / maxDeg);
      var bright = (dimmed ? 0.4 : 0.85) + degF * 0.4;
      var base = col.clone().multiplyScalar(Math.min(1, bright));

      var mat = new THREE.SpriteMaterial({
        map: S.glowTexture, color: base, transparent: true,
        opacity: dimmed ? 0.55 : 0.95, depthWrite: false,
        blending: THREE.AdditiveBlending
      });
      var sp = new THREE.Sprite(mat);
      // size ~ degree, capped; hubs a touch bigger.
      var scale = 8 + Math.min(26, Math.sqrt(nd.deg) * 6);
      sp.scale.set(scale, scale, 1);
      sp.position.copy(nd.pos);
      sp.userData.node = nd;
      S.planet.add(sp);
      S.disposables.push(mat);

      nd.sprite = sp;
      nd.home = nd.pos.clone();   // original layout pos (for search-gather restore)
      nd.baseScale = scale;
      nd.baseColor = base.clone();
      nd.baseOpacity = mat.opacity;
      nd.dimmed = dimmed;
      nd.isHub = nd.deg >= 4;

      // Label sprite (built lazily; toggled by declutter each frame).
      nd.label = nd.title.length > 26 ? nd.title.slice(0, 25) + '…' : nd.title;
    });
  }

  // Make a text-label sprite on demand (cached per node).
  function ensureLabel(nd) {
    if (nd.labelSprite) return nd.labelSprite;
    var pad = 8, fs = 34;
    var c = document.createElement('canvas');
    var ctx = c.getContext('2d');
    ctx.font = '400 ' + fs + 'px Sora, system-ui, sans-serif';
    var tw = Math.ceil(ctx.measureText(nd.label).width);
    c.width = tw + pad * 2; c.height = fs + pad * 2;
    ctx = c.getContext('2d');
    ctx.font = '400 ' + fs + 'px Sora, system-ui, sans-serif';
    ctx.textBaseline = 'middle';
    ctx.shadowColor = 'rgba(0,0,0,0.85)'; ctx.shadowBlur = 6;
    ctx.fillStyle = '#dce7f5';
    ctx.fillText(nd.label, pad, c.height / 2);
    var tex = new THREE.CanvasTexture(c);
    tex.needsUpdate = true;
    var mat = new THREE.SpriteMaterial({ map: tex, transparent: true,
      depthWrite: false, opacity: 0.9 });
    var sp = new THREE.Sprite(mat);
    sp.userData.aspect = c.width / c.height;   // texture aspect (w/h) for constant-size scaling
    sp.center.set(-0.05, 0.5);     // sit to the right of the node
    sp.position.copy(nd.pos);
    sp.visible = false;
    S.planet.add(sp);
    S.disposables.push(tex, mat);
    nd.labelSprite = sp;
    return sp;
  }

  // ---- Links: one additive LineSegments object (colour = source type) ----
  function buildLinks(nodes, links) {
    if (!links.length) return;
    var pos = new Float32Array(links.length * 6);
    var col = new Float32Array(links.length * 6);
    var tmp = new THREE.Color();
    for (var i = 0; i < links.length; i++) {
      var l = links[i];
      var s = nodes[l.s].pos, t = nodes[l.t].pos;
      pos[i * 6] = s.x; pos[i * 6 + 1] = s.y; pos[i * 6 + 2] = s.z;
      pos[i * 6 + 3] = t.x; pos[i * 6 + 4] = t.y; pos[i * 6 + 5] = t.z;
      tmp.set(colorOf(nodes[l.s].type));
      var b = l.strong ? 1.0 : 0.55;
      col[i * 6] = tmp.r * b; col[i * 6 + 1] = tmp.g * b; col[i * 6 + 2] = tmp.b * b;
      col[i * 6 + 3] = tmp.r * b; col[i * 6 + 4] = tmp.g * b; col[i * 6 + 5] = tmp.b * b;
    }
    var geo = new THREE.BufferGeometry();
    geo.setAttribute('position', new THREE.BufferAttribute(pos, 3));
    geo.setAttribute('color', new THREE.BufferAttribute(col, 3));
    var mat = new THREE.LineBasicMaterial({
      vertexColors: true, transparent: true, opacity: 0.28,
      blending: THREE.AdditiveBlending, depthWrite: false
    });
    var seg = new THREE.LineSegments(geo, mat);
    S.planet.add(seg);
    S.disposables.push(geo, mat);
    S.linkObj = seg;
    S.linkColors = col;       // keep for hover dim/highlight
    S.linkBaseColors = col.slice(0);
  }

  // ---- Travelling synapse particles (one Points cloud, sampled to cap) ----
  function buildParticles(nodes, links) {
    if (REDUCED_MOTION || !links.length) return;
    // Distribute the particle budget across edges (strong edges get 2).
    var plan = [];
    for (var i = 0; i < links.length; i++) {
      var l = links[i];
      var count = l.strong ? 2 : 1;
      for (var c = 0; c < count; c++) {
        plan.push({ si: l.s, ti: l.t, strong: l.strong });
      }
    }
    // Sample down to the cap.
    if (plan.length > MAX_PARTICLES) {
      for (var k = plan.length - 1; k > 0; k--) {
        var j = Math.floor(Math.random() * (k + 1));
        var tmp = plan[k]; plan[k] = plan[j]; plan[j] = tmp;
      }
      plan = plan.slice(0, MAX_PARTICLES);
    }
    var np = plan.length;
    if (!np) return;

    var pos = new Float32Array(np * 3);
    var col = new Float32Array(np * 3);
    var tmpC = new THREE.Color();
    var parts = new Array(np);
    for (var p = 0; p < np; p++) {
      var pl = plan[p];
      parts[p] = { si: pl.si, ti: pl.ti,
        phase: Math.random(), speed: 0.12 + Math.random() * 0.22 };
      tmpC.set(colorOf(nodes[pl.si].type));
      col[p * 3] = tmpC.r; col[p * 3 + 1] = tmpC.g; col[p * 3 + 2] = tmpC.b;
      // initial position
      var s = nodes[pl.si].pos;
      pos[p * 3] = s.x; pos[p * 3 + 1] = s.y; pos[p * 3 + 2] = s.z;
    }
    var geo = new THREE.BufferGeometry();
    geo.setAttribute('position', new THREE.BufferAttribute(pos, 3));
    geo.setAttribute('color', new THREE.BufferAttribute(col, 3));
    var mat = new THREE.PointsMaterial({
      size: 4.2, sizeAttenuation: true, vertexColors: true,
      map: S.glowTexture, transparent: true, opacity: 0.9,
      depthWrite: false, blending: THREE.AdditiveBlending
    });
    var pts = new THREE.Points(geo, mat);
    S.planet.add(pts);
    S.disposables.push(geo, mat);
    S.particleObj = pts;
    S.particles = parts;
    S.particlePos = pos;
  }

  // ============================================================
  //  Render loop
  // ============================================================
  function startLoop() {
    var clock = new THREE.Clock();
    function loop() {
      if (!S) return;
      S.raf = requestAnimationFrame(loop);
      // Perf guard: idle when hidden or the graph page isn't active.
      var root = document.getElementById('page-graph');
      if (document.hidden || !root || !root.classList.contains('active')) return;

      var dt = Math.min(clock.getDelta(), 0.05);

      // Slow planetary self-rotation. Paused while: user interacting
      // (OrbitControls clears autoRotate), focused, tweening, reduced-motion.
      if (S.planet && S.planetSpin && !S.tween && !S.selected && !S.hovered && S.controls.autoRotate) {
        S.planet.rotation.y += S.planetSpin * dt;   // hover pauses the spin
      }
      updateGather(dt);   // animate search-gather (matches cluster / glide home)
      // (No central "sun" any more — the doc-nodes are the stars.)
      // Gentle pulse on the selection ring so the active node reads clearly.
      if (S.selRing && S.selRing.visible && !REDUCED_MOTION) {
        S.ringT = (S.ringT || 0) + dt;
        S.selRing.material.opacity = 0.7 + Math.sin(S.ringT * 2.4) * 0.18;
      }
      updateFade(dt);

      updateTween(dt);
      updateParticles(dt);
      if (S.pointerInside && !S.tween && !S.selected) updateHover();
      // Throttle the (relatively heavy) label declutter + overlap solver to
      // every Nth frame. Run every frame while tweening/focusing so labels
      // track the moving camera without visible lag at the moment it matters.
      S.labelTick = (S.labelTick || 0) + 1;
      if (S.tween || S.fadeT < 1 || (S.labelTick % LABEL_THROTTLE) === 0) updateLabels();

      S.controls.update();
      S.renderer.render(S.scene, S.camera);
    }
    S.raf = requestAnimationFrame(loop);
  }

  // Move synapse particles source -> target, fade at the ends.
  function updateParticles(dt) {
    if (!S.particleObj || !S.particles.length) return;
    var nodes = S.nodes, parts = S.particles, pos = S.particlePos;
    for (var i = 0; i < parts.length; i++) {
      var pt = parts[i];
      pt.phase += pt.speed * dt;
      if (pt.phase >= 1) pt.phase -= Math.floor(pt.phase);
      var s = nodes[pt.si].pos, t = nodes[pt.ti].pos;
      var f = pt.phase;
      pos[i * 3] = s.x + (t.x - s.x) * f;
      pos[i * 3 + 1] = s.y + (t.y - s.y) * f;
      pos[i * 3 + 2] = s.z + (t.z - s.z) * f;
    }
    S.particleObj.geometry.attributes.position.needsUpdate = true;
  }

  // Label declutter + CONSTANT on-screen size.
  // Clutter rule: labels are HOVER-ONLY (mirrors the universe view) — only the
  // hovered/selected node and its direct neighbours get labels; idle shows
  // none. Each shown label is scaled per frame so its
  // apparent pixel height stays ~LABEL_PX regardless of zoom (s = dist * kPx),
  // hard-capped MIN/MAX so it can never vanish nor fill the screen.
  function updateLabels() {
    var cam = S.camera.position;
    var nodes = S.nodes;
    // kPx: world units per CSS pixel at distance 1 (perspective). The visible
    // world-height at distance d is 2*d*tan(fov/2); dividing by viewport height
    // gives world-units-per-pixel, times the desired LABEL_PX = screen size.
    var VW = S.renderer.domElement.clientWidth || S.renderer.domElement.width || 1;
    var VH = S.renderer.domElement.clientHeight || S.renderer.domElement.height || 1;
    var fov = S.camera.fov * Math.PI / 180;
    var kPx = (2 * Math.tan(fov / 2) / VH) * LABEL_PX;

    // Hover/selection anchors the visible label set (idle shows none).
    var hovered = S.hovered;
    var hoverAdj = hovered ? S.adj[hovered.id] : null;

    // ---- 1) Visibility pre-filter -> candidate pool, each with a PRIORITY ---
    // Hover-only (like the universe): the hovered/selected node and its direct
    // neighbours. Idle shows nothing. Nearer-camera breaks ties.
    var cands = [];
    for (var i = 0; i < nodes.length; i++) {
      var nd = nodes[i];
      var show, prio;
      if (S.selected) {
        show = !!(S.focusSet && S.focusSet.has(nd.id));
        prio = (nd === S.selected) ? 1e9 : 1e8;          // focused node, then its neighbours
      } else if (hovered) {
        show = (nd === hovered) || (hoverAdj && hoverAdj.has(nd.id));
        prio = (nd === hovered) ? 1e9 : 1e8;             // hovered node, then its neighbours
      } else if (S.search && S.searchMatch && S.searchMatch.size) {
        show = S.searchMatch.has(nd.id);                 // label the search hits
        prio = nd.deg;
      } else {
        show = false;                                    // idle: no labels (hover to reveal)
        prio = 0;
      }
      if (!show) { hideLabel(nd); continue; }
      cands.push({ nd: nd, prio: prio, d: cam.distanceTo(worldPos(nd)) });
    }

    // ---- 2) Priority sort (desc); distance as tie-break (nearer first) -----
    cands.sort(function (a, b) {
      if (b.prio !== a.prio) return b.prio - a.prio;
      return a.d - b.d;
    });
    if (cands.length > LABEL_CAND_CAP) {
      for (var x = LABEL_CAND_CAP; x < cands.length; x++) hideLabel(cands[x].nd);
      cands.length = LABEL_CAND_CAP;
    }

    // ---- 3) Project to screen, cull off-screen/behind, greedy non-overlap --
    var placed = [];   // {l,t,r,b} screen rects of already-shown labels
    var v = _proj || (_proj = new THREE.Vector3());
    for (var c = 0; c < cands.length; c++) {
      var cn = cands[c], nd2 = cn.nd;

      // World position -> NDC. project() bakes in the view+projection matrix;
      // z>1 means behind the near/far range (incl. behind the camera).
      worldPos(nd2, v).project(S.camera);
      if (v.z > 1 || v.x < -1.1 || v.x > 1.1 || v.y < -1.1 || v.y > 1.1) {
        hideLabel(nd2); continue;
      }

      // Constant on-screen pixel size (same law as the world-scale below).
      var aspect = (nd2.labelSprite && nd2.labelSprite.userData.aspect) || 4;
      var hPx = LABEL_PX, wPx = LABEL_PX * aspect;
      // Screen pixel of the node anchor. The label sits to the RIGHT of the
      // node (sprite center -0.05,0.5) -> rect starts at the anchor x.
      var sx = (v.x * 0.5 + 0.5) * VW;
      var sy = (-v.y * 0.5 + 0.5) * VH;
      var l = sx - LABEL_PAD, r = sx + wPx + LABEL_PAD;
      var tp = sy - hPx * 0.5 - LABEL_PAD, bt = sy + hPx * 0.5 + LABEL_PAD;

      // Greedy: drop this label if its rect hits any already-placed rect.
      var clash = false;
      for (var k = 0; k < placed.length; k++) {
        var pr = placed[k];
        if (l < pr.r && r > pr.l && tp < pr.b && bt > pr.t) { clash = true; break; }
      }
      if (clash) { hideLabel(nd2); continue; }
      placed.push({ l: l, t: tp, r: r, b: bt });

      var sp = ensureLabel(nd2);
      sp.position.copy(nd2.pos);
      // Constant screen size: world-scale grows linearly with camera distance.
      var s = cn.d * kPx;
      if (s < LABEL_MIN_SCALE) s = LABEL_MIN_SCALE;
      else if (s > LABEL_MAX_SCALE) s = LABEL_MAX_SCALE;
      sp.scale.set(s * (sp.userData.aspect || 4), s, 1);
      sp.visible = true;
    }
  }
  function hideLabel(nd) { if (nd.labelSprite) nd.labelSprite.visible = false; }

  // ============================================================
  //  Hover (raycast sprites) + neighbour highlight
  // ============================================================
  function updateHover() {
    S.raycaster.setFromCamera(S.pointer, S.camera);
    var targets = [];
    for (var i = 0; i < S.nodes.length; i++) targets.push(S.nodes[i].sprite);
    var hits = S.raycaster.intersectObjects(targets, false);
    var nd = hits.length ? hits[0].object.userData.node : null;
    setHover(nd);
  }

  function setHover(nd) {
    if (S.hovered === nd) { if (nd) positionTooltip(); return; }
    S.hovered = nd;
    var canvas = S.renderer.domElement;
    if (nd) {
      canvas.style.cursor = 'pointer';
      if (!S.search) applyHighlight(nd, 0.12);   // search dim stays put while hovering
      showTooltip(nd);
    } else {
      canvas.style.cursor = 'grab';
      if (!S.search && !S.selected) clearHighlight();
      hideTooltip();
    }
  }

  // Highlight a node + its neighbours, dim the rest. dimLevel = opacity floor.
  function applyHighlight(nd, dimLevel) {
    var near = S.adj[nd.id];
    for (var i = 0; i < S.nodes.length; i++) {
      var o = S.nodes[i];
      var on = near.has(o.id);
      o.sprite.material.opacity = on ? Math.min(1, o.baseOpacity + 0.05) : dimLevel;
      var sc = on ? o.baseScale * (o === nd ? 1.4 : 1.12) : o.baseScale;
      o.sprite.scale.set(sc, sc, 1);
    }
    dimLinks(near, dimLevel);
  }
  function clearHighlight() {
    for (var i = 0; i < S.nodes.length; i++) {
      var o = S.nodes[i];
      o.sprite.material.opacity = o.baseOpacity;
      o.sprite.scale.set(o.baseScale, o.baseScale, 1);
    }
    restoreLinks();
  }
  // Dim link colours not touching the highlighted neighbourhood.
  function dimLinks(near, dimLevel) {
    if (!S.linkObj) return;
    var col = S.linkColors, base = S.linkBaseColors, links = S.links, nodes = S.nodes;
    for (var i = 0; i < links.length; i++) {
      var on = near.has(nodes[links[i].s].id) || near.has(nodes[links[i].t].id);
      var f = on ? 1 : Math.max(0.12, dimLevel);
      for (var k = 0; k < 6; k++) col[i * 6 + k] = base[i * 6 + k] * f;
    }
    S.linkObj.geometry.attributes.color.needsUpdate = true;
    S.linkObj.material.opacity = 0.34;
  }
  function restoreLinks() {
    if (!S.linkObj) return;
    var col = S.linkColors, base = S.linkBaseColors;
    for (var i = 0; i < col.length; i++) col[i] = base[i];
    S.linkObj.geometry.attributes.color.needsUpdate = true;
    S.linkObj.material.opacity = 0.28;
  }

  // ============================================================
  //  Live search (toolbar field). Dim everything except the matched nodes
  //  and their direct neighbours, and light each match's edges so the found
  //  doc's CONNECTIONS stand out. Empty query restores the normal view.
  // ============================================================
  function searchFilter(q) {
    if (!S) return;
    q = (q == null ? '' : String(q)).trim().toLowerCase();
    S.search = q;
    if (!q) {
      S.searchMatch = null;
      if (S._gatherTimer) { clearTimeout(S._gatherTimer); S._gatherTimer = null; }
      releaseGather();
      clearHighlight();
      if (S.selected) applyHighlight(S.selected, 0.06);
      updateLabels();
      return;
    }
    var match = new Set(), show = new Set();
    for (var i = 0; i < S.nodes.length; i++) {
      var nd = S.nodes[i];
      var hay = (nd.title + ' #' + nd.id + ' ' + labelOf(nd.type)).toLowerCase();
      if (hay.indexOf(q) === -1) continue;
      match.add(nd.id); show.add(nd.id);
      var ad = S.adj[nd.id];
      if (ad) ad.forEach(function (id) { show.add(id); });   // neighbours -> show connections
    }
    for (var j = 0; j < S.nodes.length; j++) {
      var o = S.nodes[j];
      var isM = match.has(o.id);
      o.sprite.material.opacity = isM ? Math.min(1, o.baseOpacity + 0.12)
                                      : (show.has(o.id) ? o.baseOpacity * 0.9 : 0.04);
      var sc = isM ? o.baseScale * 1.35 : o.baseScale;
      o.sprite.scale.set(sc, sc, 1);
    }
    dimLinks(match, 0.05);     // light edges incident to a match, hard-dim the rest
    S.searchMatch = match;
    // Debounced: pull the match set + neighbours together once typing settles.
    var showArr = []; show.forEach(function (id) { showArr.push(id); });
    if (S._gatherTimer) clearTimeout(S._gatherTimer);
    S._gatherTimer = setTimeout(function () { if (S && S.search) startGather(showArr); }, 350);
    updateLabels();
  }

  // ---- Search-gather: pull matched nodes (+neighbours) into a compact cluster
  // so a sparse result set reads "together", then glide home when cleared.
  function gatherTargets(ids) {
    var k = ids.length, R = 36 + Math.sqrt(Math.max(1, k)) * 11;
    var ga = Math.PI * (3 - Math.sqrt(5)), out = {};
    for (var i = 0; i < k; i++) {
      var y = k > 1 ? 1 - (i / (k - 1)) * 2 : 0;
      var rad = Math.sqrt(Math.max(0, 1 - y * y)), th = ga * i;
      out[ids[i]] = new THREE.Vector3(Math.cos(th) * rad * R, y * R * 0.8, Math.sin(th) * rad * R);
    }
    return out;
  }
  function startGather(showIds) {
    if (!S || !showIds.length) return;
    var tgt = gatherTargets(showIds), keep = new Set(showIds), items = [];
    for (var i = 0; i < showIds.length; i++) {
      var nd = S.nodes[S.nodeById[showIds[i]]];
      if (nd) items.push({ nd: nd, from: nd.pos.clone(), to: tgt[showIds[i]] });
    }
    if (S.clustered) S.clustered.forEach(function (id) {
      if (!keep.has(id)) {
        var n2 = S.nodes[S.nodeById[id]];
        if (n2) items.push({ nd: n2, from: n2.pos.clone(), to: n2.home.clone() });
      }
    });
    S.clustered = keep;
    S.anim = { items: items, t: 0, dur: 0.55 };
  }
  function releaseGather() {
    if (!S || !S.clustered || !S.clustered.size) { if (S) S.clustered = null; return; }
    var items = [];
    S.clustered.forEach(function (id) {
      var nd = S.nodes[S.nodeById[id]];
      if (nd) items.push({ nd: nd, from: nd.pos.clone(), to: nd.home.clone() });
    });
    S.clustered = null;
    S.anim = { items: items, t: 0, dur: 0.5 };
  }
  function updateGather(dt) {
    if (!S.anim) return;
    S.anim.t += dt / S.anim.dur;
    var e = S.anim.t >= 1 ? 1 : easeInOut(S.anim.t);
    var items = S.anim.items;
    for (var i = 0; i < items.length; i++) {
      var it = items[i];
      it.nd.pos.lerpVectors(it.from, it.to, e);
      it.nd.sprite.position.copy(it.nd.pos);
      if (it.nd.labelSprite) it.nd.labelSprite.position.copy(it.nd.pos);
    }
    refreshLinkPositions();
    if (S.anim.t >= 1) S.anim = null;
  }
  function refreshLinkPositions() {
    if (!S.linkObj) return;
    var pos = S.linkObj.geometry.attributes.position.array;
    var links = S.links, nodes = S.nodes;
    for (var i = 0; i < links.length; i++) {
      var s = nodes[links[i].s].pos, t = nodes[links[i].t].pos;
      pos[i * 6] = s.x; pos[i * 6 + 1] = s.y; pos[i * 6 + 2] = s.z;
      pos[i * 6 + 3] = t.x; pos[i * 6 + 4] = t.y; pos[i * 6 + 5] = t.z;
    }
    S.linkObj.geometry.attributes.position.needsUpdate = true;
  }

  // Selection glow ring — a single reused additive sprite parked behind the
  // focused node so it's unmistakable which one is active. Tinted to the node
  // colour; sized a touch larger than the node sprite. Lives in the planet
  // group (rotates with it) and is disposed in destroy() via S.disposables.
  function showSelectRing(nd) {
    if (!S.selRing) {
      var mat = new THREE.SpriteMaterial({
        map: S.glowTexture, color: new THREE.Color(0xffffff),
        transparent: true, opacity: 0.85, depthWrite: false,
        blending: THREE.AdditiveBlending
      });
      var sp = new THREE.Sprite(mat);
      sp.renderOrder = -1;   // sit behind the node sprite
      S.planet.add(sp);
      S.disposables.push(mat);
      S.selRing = sp;
    }
    S.selRing.material.color.copy(nd.baseColor).lerp(new THREE.Color(0xffffff), 0.4);
    var rs = nd.baseScale * 2.6;
    S.selRing.scale.set(rs, rs, 1);
    S.selRing.position.copy(nd.pos);
    S.selRing.visible = true;
  }
  function hideSelectRing() { if (S.selRing) S.selRing.visible = false; }

  // ============================================================
  //  Focus-zoom: select node -> fly so node+neighbours fill frame
  // ============================================================
  function selectNode(nd) {
    S.selected = nd;
    S.controls.autoRotate = false;
    hideTooltip();

    // Bounding sphere of node + direct neighbours (in WORLD space — the
    // planet group may be rotated; rotation is paused for the focus duration).
    if (S.planet) S.planet.updateMatrixWorld();
    var ids = S.adj[nd.id];
    var center = new THREE.Vector3();
    var members = [];
    S.nodes.forEach(function (o) {
      if (ids.has(o.id)) { members.push(o); center.add(o.pos.clone().applyMatrix4(S.planet.matrixWorld)); }
    });
    center.multiplyScalar(1 / Math.max(1, members.length));
    var radius = 1;
    var _m = new THREE.Vector3();
    members.forEach(function (o) {
      _m.copy(o.pos).applyMatrix4(S.planet.matrixWorld);
      radius = Math.max(radius, center.distanceTo(_m) + o.baseScale);
    });

    // Strong dim of everything outside the focus set; highlight inside.
    S.focusSet = ids;
    applyHighlight(nd, 0.06);
    showSelectRing(nd);

    // Fly so the bounding sphere fills the frame, with margin so the focused
    // node + neighbours sit comfortably and their (constant-size) labels stay
    // readable and don't clip at the viewport edge.
    var fov = S.camera.fov * Math.PI / 180;
    var dist = (radius / Math.sin(fov / 2)) * 1.45 + 40;
    var dir = S.camera.position.clone().sub(S.controls.target).normalize();
    if (!isFinite(dir.x) || dir.lengthSq() < 0.001) dir.set(0, 0.2, 1).normalize();
    var to = center.clone().add(dir.multiplyScalar(dist));
    startTween(to, center);

    openDetail(nd);
    showBackHint(true);
  }

  function deselect() {
    if (!S.selected) return;
    S.selected = null;
    S.focusSet = null;
    clearHighlight();
    if (S.search) searchFilter(S.search);   // restore search dim after un-focus
    hideSelectRing();
    closeDetail();
    showBackHint(false);
    frameAll(true);   // fly back to overview (eased return)
    if (!REDUCED_MOTION) S.controls.autoRotate = true;
  }
  function showBackHint(on) { if (S && S.back) S.back.classList.toggle('show', !!on); }

  // Compute (and optionally fly to) a camera framing the whole graph.
  function frameAll(fly) {
    var box = new THREE.Box3();
    if (S.nodes.length) {
      if (S.planet) S.planet.updateMatrixWorld();
      var _p = new THREE.Vector3();
      for (var i = 0; i < S.nodes.length; i++) {
        _p.copy(S.nodes[i].pos);
        if (S.planet) _p.applyMatrix4(S.planet.matrixWorld);
        box.expandByPoint(_p);
      }
    } else {
      box.set(new THREE.Vector3(-50, -50, -50), new THREE.Vector3(50, 50, 50));
    }
    var center = new THREE.Vector3(); box.getCenter(center);
    var size = new THREE.Vector3(); box.getSize(size);
    var radius = Math.max(size.x, size.y, size.z) * 0.5 + 20;
    var fov = S.camera.fov * Math.PI / 180;
    var dist = (radius / Math.sin(fov / 2)) * 0.95 + 16;   // start more zoomed-in
    var to = center.clone().add(new THREE.Vector3(0, size.y * 0.15, dist));
    S.homeCam = to.clone();
    S.homeTarget = center.clone();
    if (fly) startTween(to, center, 1.05);   // softer, slightly longer return ease
    else {
      S.camera.position.copy(to);
      S.controls.target.copy(center);
      S.camera.lookAt(center);
    }
  }

  function startTween(toPos, toTarget, dur) {
    S.controls.enabled = false;
    S.tween = {
      from: S.camera.position.clone(), to: toPos.clone(),
      tFrom: S.controls.target.clone(), tTo: toTarget.clone(),
      t: 0, dur: dur || 0.8
    };
  }
  function updateTween(dt) {
    var tw = S.tween;
    if (!tw) return;
    tw.t += dt / tw.dur;
    var e = tw.t >= 1 ? 1 : easeInOut(tw.t);
    S.camera.position.lerpVectors(tw.from, tw.to, e);
    S.controls.target.lerpVectors(tw.tFrom, tw.tTo, e);
    S.camera.lookAt(S.controls.target);
    if (tw.t >= 1) { S.tween = null; S.controls.enabled = true; }
  }
  function easeInOut(t) { return t < 0.5 ? 2 * t * t : -1 + (4 - 2 * t) * t; }

  // ============================================================
  //  Detail panel (reuses the 2D .gp-detail markup)
  // ============================================================
  function $g(sel) { return document.querySelector('#page-graph ' + sel); }
  function openDetail(nd) {
    var detail = $g('.gp-detail');
    if (!detail) return;
    var col = colorOf(nd.type);
    var sw = $g('.gp-detail .type-tag .swatch'); if (sw) sw.style.color = col;
    setTxt('.gp-d-type', labelOf(nd.type));
    setTxt('.gp-d-title', nd.title);
    setTxt('.gp-d-id', '#' + nd.id);
    var st = $g('.gp-d-status');
    if (st) {
      if (nd.status) { st.innerHTML = 'status <b>' + escHtml(nd.status) + '</b>'; st.style.display = ''; }
      else st.style.display = 'none';
    }
    setTxt('.gp-d-summary', nd.summary || 'No summary available.');

    var open = $g('.gp-d-open');
    if (open) {
      if (/^\d+$/.test('' + nd.id)) {
        open.style.display = '';
        open.onclick = function (e) { if (e) e.preventDefault(); S.onOpenDoc(nd.id); };
      } else open.style.display = 'none';
    }

    var relsEl = $g('.gp-d-rels');
    if (relsEl) {
      var rows = [];
      S.links.forEach(function (l) {
        var sId = S.nodes[l.s].id, tId = S.nodes[l.t].id;
        if (sId !== nd.id && tId !== nd.id) return;
        var other = sId === nd.id ? S.nodes[l.t] : S.nodes[l.s];
        var verb = sId === nd.id ? l.rel : '← ' + l.rel;
        rows.push('<div class="rel"><span class="verb">' + escHtml(verb) + '</span>' +
          '<span style="color:' + colorOf(other.type) + '">●</span> ' + escHtml(other.title) + '</div>');
      });
      relsEl.innerHTML = rows.join('') ||
        '<div class="rel" style="color:var(--g-text-dim)">No relations</div>';
    }
    detail.classList.add('open');

    // Wire the close button to deselect (once).
    var closeBtn = $g('.gp-detail .close');
    if (closeBtn && !closeBtn._g3dWired) {
      closeBtn._g3dWired = true;
      closeBtn.addEventListener('click', function () { if (S) deselect(); });
    }
  }
  function closeDetail() {
    var detail = $g('.gp-detail');
    if (detail) detail.classList.remove('open');
  }
  function setTxt(sel, v) { var el = $g(sel); if (el) el.textContent = v; }

  // ============================================================
  //  HUD (minimal) + tooltip + empty state
  // ============================================================
  function buildHud(container) {
    var hud = document.createElement('div');
    hud.className = 'g3d-hud';
    hud.innerHTML =
      '<div class="g3d-title">' + escHtml(S.slug || 'project') + '</div>' +
      '<div class="g3d-count"><span class="g3d-count-n">0</span> documents</div>' +
      '<div class="g3d-trunc"></div>';
    container.appendChild(hud);

    var tip = document.createElement('div');
    tip.className = 'g3d-tip';
    container.appendChild(tip);

    var empty = document.createElement('div');
    empty.className = 'g3d-empty';
    empty.textContent = 'No documents in this project yet — nothing to map.';
    container.appendChild(empty);

    // Back hint — only visible while a node is focused. Tells the user the two
    // ways back to the overview. Pointer-events stay off (purely informational).
    var back = document.createElement('div');
    back.className = 'g3d-back';
    back.innerHTML = '<kbd>Esc</kbd> · klick ins Leere <span>→ zurück</span>';
    container.appendChild(back);

    S.hud = hud; S.tip = tip; S.empty = empty; S.back = back;
    S.hudCount = hud.querySelector('.g3d-count-n');
    S.hudTrunc = hud.querySelector('.g3d-trunc');
  }
  function setHud(data) {
    var total = (data && data.total_nodes != null) ? data.total_nodes
              : (data && data.nodes ? data.nodes.length : 0);
    if (S.hudCount) S.hudCount.textContent = total;
    if (S.hudTrunc) {
      if (data && data.truncated && data.total_nodes != null) {
        var shown = (data.node_count != null ? data.node_count
          : (data.nodes ? data.nodes.length : 0));
        S.hudTrunc.textContent = 'showing ' + shown + ' of ' + data.total_nodes;
        S.hudTrunc.classList.add('show');
      } else S.hudTrunc.classList.remove('show');
    }
  }
  function showEmpty(on) { if (S && S.empty) S.empty.classList.toggle('show', !!on); }

  function showTooltip(nd) {
    if (!S.tip) return;
    S.tip.innerHTML = '<b>' + escHtml(nd.title) + '</b><span>#' + escHtml(nd.id) +
      ' · ' + escHtml(labelOf(nd.type)) + '</span>';
    S.tip.classList.add('show');
    positionTooltip();
  }
  function positionTooltip() {
    if (!S.tip) return;
    S.tip.style.left = (S.pointerClient.x + 16) + 'px';
    S.tip.style.top = (S.pointerClient.y + 14) + 'px';
  }
  function hideTooltip() { if (S.tip) S.tip.classList.remove('show'); }

  // ============================================================
  //  Helpers
  // ============================================================
  function makeGlowTexture() {
    var size = 64;
    var c = document.createElement('canvas');
    c.width = c.height = size;
    var ctx = c.getContext('2d');
    var g = ctx.createRadialGradient(size / 2, size / 2, 0, size / 2, size / 2, size / 2);
    g.addColorStop(0, 'rgba(255,255,255,1)');
    g.addColorStop(0.25, 'rgba(255,255,255,0.65)');
    g.addColorStop(0.6, 'rgba(255,255,255,0.15)');
    g.addColorStop(1, 'rgba(255,255,255,0)');
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, size, size);
    var tex = new THREE.CanvasTexture(c);
    tex.needsUpdate = true;
    return tex;
  }

  function escHtml(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (ch) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch];
    });
  }

  // ============================================================
  //  Teardown — no WebGL context / listener leaks (mirrors universe.js)
  // ============================================================
  function destroy() {
    if (!S) return;
    var s = S;
    S = null;   // stop the loop guard immediately

    if (s.raf != null) cancelAnimationFrame(s.raf);
    if (s.idleTimer) clearTimeout(s.idleTimer);
    if (s._gatherTimer) clearTimeout(s._gatherTimer);

    window.removeEventListener('resize', s.onResize);
    document.removeEventListener('visibilitychange', s.onVisibility);
    if (s.onKeyDown) document.removeEventListener('keydown', s.onKeyDown);

    if (s.controls && s.controls.dispose) s.controls.dispose();

    (s.disposables || []).forEach(function (o) {
      if (o && typeof o.dispose === 'function') o.dispose();
    });

    if (s.scene) {
      s.scene.traverse(function (obj) {
        if (obj.geometry && obj.geometry.dispose) obj.geometry.dispose();
        if (obj.material) {
          var mats = Array.isArray(obj.material) ? obj.material : [obj.material];
          mats.forEach(function (m) {
            if (m.map && m.map.dispose) m.map.dispose();
            if (m.dispose) m.dispose();
          });
        }
      });
      while (s.scene.children.length) s.scene.remove(s.scene.children[0]);
    }

    if (s.renderer) {
      s.renderer.dispose();
      if (s.renderer.forceContextLoss) {
        try { s.renderer.forceContextLoss(); } catch (e) {}
      }
      var canvas = s.renderer.domElement;
      if (canvas && canvas.parentNode) canvas.parentNode.removeChild(canvas);
    }

    // Close + reset the shared detail panel so it can't bleed into 2D mode.
    var detail = document.querySelector('#page-graph .gp-detail');
    if (detail) detail.classList.remove('open');

    [s.hud, s.tip, s.empty, s.back].forEach(function (el) {
      if (el && el.parentNode) el.parentNode.removeChild(el);
    });
  }

  function isMounted() { return !!S; }

  return { mount: mount, destroy: destroy, isMounted: isMounted, search: searchFilter };
})();
