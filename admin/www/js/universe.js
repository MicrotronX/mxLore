/* ============================================================
   universe.js — mxLore Knowledge "Universe" (Admin UI, 3D)
   Hand-rolled Three.js (r134, global THREE) + THREE.OrbitControls.
   Each project = a galaxy (particle system). Relations = glowing
   arcs between galaxy centres. Click a galaxy -> camera fly-to ->
   onOpenProject(slug) drills into the 2D per-project graph.

   Public: Universe.mount({container, onOpenProject}) / Universe.destroy()
   Data:   GET /api/graph/universe
           { galaxies:[{id,slug,name,doc_count,types:{type:n}}],
             links:[{s,t,rel}] }
   All DOM stays under #page-graph; HUD styled via css/graph.css.
   ============================================================ */

var Universe = (function () {
  'use strict';

  // doc_type -> color. Self-contained (mirrors graph.js TYPES palette).
  var TYPE_COLOR = {
    lesson: '#3ee08a', spec: '#4aa3ff', plan: '#b07cff', decision: '#ffb340',
    reference: '#2fe0d0', feature_request: '#ff6bb0', session_note: '#7889a8',
    bugreport: '#ff5a6e', note: '#d4c98a', todo: '#ff9d5c', workflow_log: '#5cc8ff'
  };
  var DEFAULT_COLOR = '#7889a8';

  // Particle / galaxy budgets (keep dense graphs smooth).
  var CAP_PER_GALAXY = 2500;
  var CAP_TOTAL = 40000;
  var GLOBULAR_MAX = 18;     // doc_count <= this -> compact globular cluster

  var REDUCED_MOTION = (typeof window.matchMedia === 'function') &&
    window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  // ---- module state (single live instance) ----
  var S = null;   // active scene state, or null when destroyed

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
      onOpenProject: opts.onOpenProject || function () {},
      raf: null,
      disposables: [],     // geometries/materials/textures to dispose()
      galaxies: [],        // { slug, name, docCount, points, core, group, baseSpin }
      tween: null,         // active camera fly-to
      hovered: null,
      coreTexture: null,
      ringTexture: null,
      ring: null,          // shared selection-halo sprite, parked on the hovered galaxy
      arcs: [],            // { line, baseOpacity, baseColor } for relation-highlight
      dragging: false
    };

    var W = container.clientWidth || window.innerWidth;
    var H = container.clientHeight || window.innerHeight;

    var scene = new THREE.Scene();
    var camera = new THREE.PerspectiveCamera(55, W / H, 0.1, 4000);
    camera.position.set(0, 40, 320);

    var renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
    renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
    renderer.setSize(W, H);
    // Opaque clear matching the page --g-bg so the seam is invisible. The
    // bloom composer can't preserve a transparent backdrop, so the scene
    // carries its own starfield + nebula instead of the CSS wash.
    renderer.setClearColor(0x0a0e14, 1);
    container.appendChild(renderer.domElement);

    var controls = new THREE.OrbitControls(camera, renderer.domElement);
    controls.enableDamping = true;
    controls.dampingFactor = 0.08;
    controls.rotateSpeed = 0.55;
    controls.zoomSpeed = 0.9;
    controls.minDistance = 40;
    controls.maxDistance = 1600;
    // No camera auto-orbit: the layout is a window-filling board, not a globe,
    // so a continuous spin would tilt it edge-on and read oddly. Ambient life
    // comes from each galaxy's own rotation + the arc flow motes instead.
    controls.autoRotate = false;
    var idleTimer = null;
    controls.addEventListener('start', function () {
      if (idleTimer) { clearTimeout(idleTimer); idleTimer = null; }
      if (S) S.dragging = true;   // let the user orbit freely
    });
    controls.addEventListener('end', function () {
      if (S) S.dragging = false;
    });

    S.scene = scene;
    S.camera = camera;
    S.renderer = renderer;
    S.controls = controls;
    S.idleTimer = idleTimer;
    S.coreTexture = makeGlowTexture();
    S.disposables.push(S.coreTexture);
    S.ringTexture = makeRingTexture();
    S.disposables.push(S.ringTexture);
    S.ring = makeSelectionRing(S.ringTexture);
    scene.add(S.ring);

    // Backdrop: distant starfield + a few faint nebula clouds (replaces the
    // CSS wash now that the canvas is opaque). Data-independent, built once.
    buildBackdrop(scene);

    // Optional bloom post-processing. Degrades gracefully to a plain render
    // if the example/js postproc files didn't load (no black-screen risk).
    setupComposer(W, H);

    // HUD (built once, lives inside container).
    buildHud(container);

    // Raycaster for hover/click on galaxy cores.
    S.raycaster = new THREE.Raycaster();
    S.raycaster.params.Points = { threshold: 6 };
    S.pointer = new THREE.Vector2();
    S.pointerClient = { x: 0, y: 0 };
    S.pointerInside = false;

    renderer.domElement.addEventListener('pointermove', onPointerMove);
    renderer.domElement.addEventListener('pointerleave', onPointerLeave);
    renderer.domElement.addEventListener('click', onClick);
    renderer.domElement.addEventListener('contextmenu', onContextMenu);
    window.addEventListener('resize', onResize);
    document.addEventListener('visibilitychange', onVisibility);
    S.onResize = onResize;
    S.onVisibility = onVisibility;

    // Load data, build galaxies, start loop.
    loadData().then(function (data) {
      if (!S) return;   // destroyed mid-flight
      buildUniverse(data);
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
      if (S.composer) S.composer.setSize(w, h);
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
      setHover(null);
    }
    function onClick() {
      if (!S || !S.hovered) return;
      flyTo(S.hovered);
    }
    // Right-click a galaxy = jump straight into the project (skip the fly-to).
    function onContextMenu(e) {
      if (e) e.preventDefault();
      if (!S || !S.hovered) return;
      S.onOpenProject(S.hovered.slug);
    }
  }

  // ============================================================
  //  Data
  // ============================================================
  function loadData() {
    return fetch('api/graph/universe', { method: 'GET', credentials: 'same-origin' })
      .then(function (res) {
        if (res.status === 401) {
          if (window.App && App.showLogin) App.showLogin('Session expired. Please sign in again.');
          throw new Error('session_expired');
        }
        if (!res.ok) throw new Error('request_failed');
        return res.json();
      })
      .catch(function () { return { galaxies: [], links: [] }; });
  }

  // ============================================================
  //  Build galaxies + relation arcs
  // ============================================================
  function buildUniverse(data) {
    var galaxies = (data && data.galaxies || []).filter(function (g) { return g && g.slug; });
    var links = (data && data.links || []);

    setHudCount(galaxies.length);
    if (galaxies.length === 0) { showEmpty(true); return; }
    showEmpty(false);

    var n = galaxies.length;

    // 1) Build every galaxy first (at the origin) so each one's radius is
    //    known before we lay them out.
    var totalDocs = galaxies.reduce(function (a, g) { return a + (g.doc_count || 1); }, 0) || 1;
    var built = galaxies.map(function (g) {
      var b = buildGalaxy(g, totalDocs);
      b.slug = g.slug;
      b.name = g.name || g.slug;
      b.docCount = g.doc_count || 0;
      return b;
    });

    // 2) Lay them out across the full viewport as an aspect-matched box volume,
    //    evenly spaced via a jittered grid -> guaranteed minimum distance, no
    //    clumping, and the silhouette fills the window rather than a circle.
    var maxR = built.reduce(function (m, b) { return Math.max(m, b.radius); }, 1);
    var pos = layoutBox(n, maxR, S.camera.aspect || 1);

    built.forEach(function (b, i) {
      b.group.position.copy(pos[i]);
      b.center = pos[i].clone();
      S.scene.add(b.group);
      S.galaxies.push(b);
    });

    // 3) Relation edges (index pairs) -> arcs + flow motes.
    var idIndex = {};
    galaxies.forEach(function (g, i) { idIndex[g.id] = i; });
    var edges = [];
    links.forEach(function (l) {
      var a = idIndex[l.s], b = idIndex[l.t];
      if (a == null || b == null || a === b) return;
      edges.push([a, b, l.rel]);
    });
    buildArcs(edges, pos);

    // 4) Frame the whole board so it fills the viewport.
    fitToView();
  }

  // Even, screen-filling layout: an aspect-matched box volume sampled on a
  // jittered 3D grid. Cell size > 2*maxR so no two galaxies crowd each other;
  // empty cells are shuffled in so any gaps scatter instead of leaving a hole
  // in one corner. Depth (Z) is shallower than width/height so the board reads
  // as a window-filling wall that still has parallax when orbited.
  function layoutBox(n, maxR, aspect) {
    var nz = Math.max(1, Math.round(Math.cbrt(n) * 0.6));
    var perLayer = Math.ceil(n / nz);
    var nx = Math.max(1, Math.round(Math.sqrt(perLayer * Math.max(0.2, aspect))));
    var ny = Math.max(1, Math.ceil(perLayer / nx));
    var cell = maxR * 2.9 + 24;
    var depthCell = cell * 0.8;
    var jit = cell * 0.16;
    var cells = [];
    for (var z = 0; z < nz; z++)
      for (var y = 0; y < ny; y++)
        for (var x = 0; x < nx; x++) cells.push([x, y, z]);
    for (var k = cells.length - 1; k > 0; k--) {   // Fisher-Yates shuffle
      var j = Math.floor(Math.random() * (k + 1));
      var t = cells[k]; cells[k] = cells[j]; cells[j] = t;
    }
    var out = [];
    for (var i = 0; i < n; i++) {
      var c = cells[i];
      // Stagger odd layers by half a cell in X+Y so back-layer galaxies land in
      // the gaps of the front layer -> head-on, none hides directly behind another.
      var stag = (c[2] % 2) ? cell * 0.5 : 0;
      out.push(new THREE.Vector3(
        (c[0] - (nx - 1) / 2) * cell + stag + (Math.random() - 0.5) * 2 * jit,
        ((ny - 1) / 2 - c[1]) * cell + stag + (Math.random() - 0.5) * 2 * jit,
        (c[2] - (nz - 1) / 2) * depthCell + (Math.random() - 0.5) * 2 * jit
      ));
    }
    return out;
  }

  // Frame the whole board so it fills the viewport: fit BOTH the horizontal
  // and vertical extents to the camera frustum and take the tighter distance.
  function fitToView() {
    if (!S || !S.galaxies.length) return;
    var box = new THREE.Box3();
    var v = new THREE.Vector3();
    S.galaxies.forEach(function (g) {
      var r = Math.max(g.radius, (g.core && g.core.userData.baseScale) || g.radius);
      box.expandByPoint(v.copy(g.center).addScalar(r));
      box.expandByPoint(v.copy(g.center).addScalar(-r));
    });
    var center = box.getCenter(new THREE.Vector3());
    var size = box.getSize(new THREE.Vector3());

    var fov = S.camera.fov * Math.PI / 180;
    var aspect = S.camera.aspect || 1;
    var margin = 1.08;
    var distV = (size.y / 2) / Math.tan(fov / 2);
    var distH = (size.x / 2 / aspect) / Math.tan(fov / 2);
    var dist = Math.max(distV, distH) * margin + size.z / 2;

    // Mostly head-on so the board fills the frame, with a slight tilt for depth.
    var dir = new THREE.Vector3(0.12, 0.10, 1).normalize();
    S.camera.position.copy(center.clone().add(dir.multiplyScalar(dist)));
    S.controls.target.copy(center);
    S.camera.lookAt(center);

    // Make sure nothing clips: far plane past the far edge, allow zoom-out.
    S.camera.far = Math.max(S.camera.far, (dist + size.length()) * 2.2);
    S.camera.updateProjectionMatrix();
    S.controls.maxDistance = Math.max(S.controls.maxDistance, dist * 1.8);
    S.controls.update();
  }

  // Build one galaxy as a THREE.Points particle system + a glowing core sprite.
  function buildGalaxy(g, totalDocs) {
    var docCount = Math.max(1, g.doc_count || 1);
    // Particle count ~ doc_count, scaled to the global cap, then per-galaxy cap.
    var share = (docCount / totalDocs) * CAP_TOTAL;
    var count = Math.max(120, Math.min(CAP_PER_GALAXY, Math.round(share + docCount * 8)));

    // Pick a morphology so no two galaxies read the same. Tiny ones stay
    // compact globular clusters; larger ones draw from a varied catalogue.
    var kind;
    if (docCount <= GLOBULAR_MAX) {
      kind = 'globular';
    } else {
      var roll = Math.random();
      kind = roll < 0.38 ? 'spiral'
           : roll < 0.60 ? 'barred'
           : roll < 0.78 ? 'elliptical'
           : roll < 0.91 ? 'ring'
                         : 'irregular';
    }
    var disky = (kind === 'spiral' || kind === 'barred' || kind === 'ring');
    var radius = disky ? (26 + Math.min(36, Math.sqrt(docCount) * 3.4))
                       : (16 + Math.min(28, Math.sqrt(docCount) * 2.9));

    // Per-galaxy shape parameters (randomised once -> every galaxy differs).
    var arms = 2 + Math.floor(Math.random() * 4);          // 2..5 spiral arms
    var wind = 2.4 + Math.random() * 3.2;                  // arm winding tightness
    var spinSign = Math.random() < 0.5 ? 1 : -1;           // arm chirality
    var barLen = radius * (0.32 + Math.random() * 0.22);   // central bar half-length
    var ellY = 0.42 + Math.random() * 0.5;                 // elliptical squash
    var ellZ = 0.6 + Math.random() * 0.4;
    var ringR = radius * (0.55 + Math.random() * 0.15);    // ring radius
    var clumps = [];
    if (kind === 'irregular') {
      var nc = 3 + Math.floor(Math.random() * 4);
      for (var ci = 0; ci < nc; ci++) {
        clumps.push({
          cx: (Math.random() - 0.5) * radius * 1.3,
          cy: (Math.random() - 0.5) * radius * 0.5,
          cz: (Math.random() - 0.5) * radius * 1.3,
          r: radius * (0.2 + Math.random() * 0.32)
        });
      }
    }

    // Color blend from the galaxy's dominant doc_types (top 3, weighted).
    var palette = topColors(g.types);

    var positions = new Float32Array(count * 3);
    var colors = new Float32Array(count * 3);
    var tmp = new THREE.Color();

    for (var i = 0; i < count; i++) {
      var x = 0, y = 0, z = 0;
      if (kind === 'globular') {
        // Dense centre, smooth falloff (Plummer-ish sphere).
        var gr = Math.pow(Math.random(), 1.6) * radius;
        var ga = Math.random() * Math.PI * 2, gp = Math.acos(2 * Math.random() - 1);
        x = gr * Math.sin(gp) * Math.cos(ga); y = gr * Math.cos(gp); z = gr * Math.sin(gp) * Math.sin(ga);
      } else if (kind === 'elliptical') {
        // Smooth ellipsoid with random axis ratios (E0..E7-ish).
        var er = Math.pow(Math.random(), 1.7) * radius;
        var ea = Math.random() * Math.PI * 2, ep = Math.acos(2 * Math.random() - 1);
        x = er * Math.sin(ep) * Math.cos(ea);
        y = er * Math.cos(ep) * ellY;
        z = er * Math.sin(ep) * Math.sin(ea) * ellZ;
      } else if (kind === 'ring') {
        if (Math.random() < 0.18) {            // small central nucleus
          var br = Math.pow(Math.random(), 1.8) * radius * 0.22;
          var ba = Math.random() * Math.PI * 2, bp = Math.acos(2 * Math.random() - 1);
          x = br * Math.sin(bp) * Math.cos(ba); y = br * Math.cos(bp) * 0.7; z = br * Math.sin(bp) * Math.sin(ba);
        } else {                               // the ring itself
          var ra = Math.random() * Math.PI * 2;
          var rr0 = ringR + (Math.random() - 0.5) * radius * 0.26;
          x = Math.cos(ra) * rr0; z = Math.sin(ra) * rr0; y = (Math.random() - 0.5) * 4;
        }
      } else if (kind === 'irregular') {
        // A handful of offset clumps, no symmetry.
        var cl = clumps[Math.floor(Math.random() * clumps.length)];
        var ir = Math.pow(Math.random(), 1.4) * cl.r;
        var ia = Math.random() * Math.PI * 2, ip = Math.acos(2 * Math.random() - 1);
        x = cl.cx + ir * Math.sin(ip) * Math.cos(ia);
        y = cl.cy + ir * Math.cos(ip) * 0.7;
        z = cl.cz + ir * Math.sin(ip) * Math.sin(ia);
      } else if (kind === 'barred') {
        if (Math.random() < 0.30) {            // central bar
          x = (Math.random() - 0.5) * 2 * barLen + (Math.random() - 0.5) * 4;
          z = (Math.random() - 0.5) * 6;
          y = (Math.random() - 0.5) * 5;
        } else {                               // two arms off the bar ends
          var tb = Math.pow(Math.random(), 0.6);
          var rb = barLen + tb * (radius - barLen);
          var endSide = Math.random() < 0.5 ? 0 : Math.PI;
          var angB = spinSign * tb * wind + endSide;
          x = Math.cos(angB) * rb + (Math.random() - 0.5) * 4;
          z = Math.sin(angB) * rb + (Math.random() - 0.5) * 4;
          y = (Math.random() - 0.5) * (3 + (1 - tb) * 6);
        }
      } else {                                 // 'spiral'
        if (Math.random() < 0.22) {            // bulge
          var br2 = Math.pow(Math.random(), 1.8) * radius * 0.32;
          var ba2 = Math.random() * Math.PI * 2, bp2 = Math.acos(2 * Math.random() - 1);
          x = br2 * Math.sin(bp2) * Math.cos(ba2); y = br2 * Math.cos(bp2) * 0.7; z = br2 * Math.sin(bp2) * Math.sin(ba2);
        } else {                               // logarithmic arms with scatter
          var t = Math.pow(Math.random(), 0.6);
          var rr = t * radius;
          var arm = Math.floor(Math.random() * arms);
          var ang = (arm / arms) * Math.PI * 2 + spinSign * t * wind;
          var scatter = (1 - t) * 0.5 + 0.12;
          ang += (Math.random() - 0.5) * scatter;
          x = Math.cos(ang) * rr + (Math.random() - 0.5) * 4;
          z = Math.sin(ang) * rr + (Math.random() - 0.5) * 4;
          y = (Math.random() - 0.5) * (3.5 + (1 - t) * 7);   // thin disk, thicker core
        }
      }
      positions[i * 3] = x;
      positions[i * 3 + 1] = y;
      positions[i * 3 + 2] = z;

      // pick a palette color, brighten toward the core
      var col = palette[i % palette.length];
      var distF = 1 - Math.min(1, Math.sqrt(x * x + y * y + z * z) / radius);
      tmp.set(col);
      var b = 0.6 + distF * 0.55;
      colors[i * 3] = Math.min(1, tmp.r * b);
      colors[i * 3 + 1] = Math.min(1, tmp.g * b);
      colors[i * 3 + 2] = Math.min(1, tmp.b * b);
    }

    var geo = new THREE.BufferGeometry();
    geo.setAttribute('position', new THREE.BufferAttribute(positions, 3));
    geo.setAttribute('color', new THREE.BufferAttribute(colors, 3));
    var mat = new THREE.PointsMaterial({
      size: disky ? 1.6 : 1.9,
      sizeAttenuation: true,
      vertexColors: true,
      transparent: true,
      opacity: 0.92,
      depthWrite: false,
      blending: THREE.AdditiveBlending,
      map: S.coreTexture
    });
    var points = new THREE.Points(geo, mat);
    S.disposables.push(geo, mat);

    // Bright core glow sprite (also the raycast target).
    var coreColor = new THREE.Color(palette[0]);
    var spriteMat = new THREE.SpriteMaterial({
      map: S.coreTexture, color: coreColor, transparent: true,
      opacity: 0.9, depthWrite: false, blending: THREE.AdditiveBlending
    });
    var core = new THREE.Sprite(spriteMat);
    var coreScale = radius * (disky ? 1.0 : 1.35);   // tighter nucleus -> less flat outer-glow disc
    core.scale.set(coreScale, coreScale, 1);
    core.userData.baseScale = coreScale;
    S.disposables.push(spriteMat);

    var group = new THREE.Group();
    group.add(points);
    group.add(core);
    group.userData.isGalaxy = true;
    // Random 3D orientation so disks don't all lie in the same plane. Self-spin
    // in the loop uses group.rotateY (local axis) to preserve this tilt.
    group.rotation.set(
      Math.random() * Math.PI * 2,
      Math.random() * Math.PI * 2,
      Math.random() * Math.PI * 2
    );

    return {
      group: group, points: points, core: core, coreColor: coreColor, kind: kind,
      // Visible self-rotation, varied per galaxy: ~5..18 deg/s (rad/s).
      // Always animated (decoupled from prefers-reduced-motion) and
      // randomly signed so neighbours don't all spin in lockstep.
      baseSpin: (Math.random() < 0.5 ? 1 : -1) *
        (0.087 + Math.random() * 0.227),
      twPhase: Math.random() * Math.PI * 2,
      radius: radius
    };
  }

  // Glowing arcs between related galaxy centres (THREE.Line, additive, faint).
  function buildArcs(edges, pos) {
    if (!edges.length) return;
    edges.forEach(function (e) {
      var a = pos[e[0]], b = pos[e[1]];
      var va = new THREE.Vector3(a.x, a.y, a.z);
      var vb = new THREE.Vector3(b.x, b.y, b.z);
      var mid = va.clone().add(vb).multiplyScalar(0.5);
      // lift midpoint outward for a gentle bow
      var lift = va.distanceTo(vb) * 0.18;
      mid.add(mid.clone().normalize().multiplyScalar(lift));
      var curve = new THREE.QuadraticBezierCurve3(va, mid, vb);
      var pts = curve.getPoints(24);
      var geo = new THREE.BufferGeometry().setFromPoints(pts);
      var strong = e[2] === 'replaces' || e[2] === 'supersedes';
      var mat = new THREE.LineBasicMaterial({
        color: strong ? 0xb07cff : 0x4aa3ff,
        transparent: true,
        opacity: strong ? 0.22 : 0.12,
        blending: THREE.AdditiveBlending,
        depthWrite: false
      });
      var line = new THREE.Line(geo, mat);
      S.scene.add(line);
      S.disposables.push(geo, mat);

      // Link this arc to both galaxies so hovering one can light up its relations.
      var entry = { line: line, curve: curve, baseOpacity: mat.opacity, baseColor: mat.color.clone() };
      S.arcs.push(entry);
      var ga = S.galaxies[e[0]], gb = S.galaxies[e[1]];
      if (ga) (ga.arcs = ga.arcs || []).push(entry);
      if (gb) (gb.arcs = gb.arcs || []).push(entry);
    });

    // Flowing light motes travelling along each arc -> knowledge visibly
    // "flows" between related projects. One shared Points system, advanced
    // per frame in the loop (positions sampled along the stored bezier curves).
    var DOTS_PER_ARC = 3;
    var maxDots = Math.min(1800, S.arcs.length * DOTS_PER_ARC);
    if (maxDots > 0) {
      var fpos = new Float32Array(maxDots * 3);
      var dots = [];
      for (var di = 0; di < maxDots; di++) {
        var arc = S.arcs[di % S.arcs.length];
        dots.push({ curve: arc.curve, phase: Math.random(), speed: 0.05 + Math.random() * 0.06 });
      }
      var fgeo = new THREE.BufferGeometry();
      fgeo.setAttribute('position', new THREE.BufferAttribute(fpos, 3));
      var fmat = new THREE.PointsMaterial({
        size: 3.4, sizeAttenuation: true, map: S.coreTexture,
        color: 0xbfe3ff, transparent: true, opacity: 0.9,
        depthWrite: false, blending: THREE.AdditiveBlending
      });
      var fpoints = new THREE.Points(fgeo, fmat);
      fpoints.frustumCulled = false;
      S.scene.add(fpoints);
      S.disposables.push(fgeo, fmat);
      S.flow = { attr: fgeo.getAttribute('position'), dots: dots, scratch: new THREE.Vector3() };
    }
  }

  // ============================================================
  //  Render loop
  // ============================================================
  function startLoop() {
    var clock = new THREE.Clock();
    function loop() {
      if (!S) return;
      S.raf = requestAnimationFrame(loop);
      // Performance guard: idle when hidden or the graph page isn't active.
      var root = document.getElementById('page-graph');
      if (document.hidden || !root || !root.classList.contains('active')) return;

      var dt = Math.min(clock.getDelta(), 0.05);

      // Galaxy self-rotation + subtle core twinkle. Always runs: the ambient
      // motion is intentional and decoupled from prefers-reduced-motion.
      S.clockT = (S.clockT || 0) + dt;
      var dimOthers = S.hovered ? 0.5 : 1;   // recede unfocused galaxies on hover
      for (var i = 0; i < S.galaxies.length; i++) {
        var gx = S.galaxies[i];
        // Every galaxy keeps spinning around its OWN (tilted) disk axis; the
        // hovered one energises (spins up). rotateY = local Y, preserves tilt.
        gx.group.rotateY(gx.baseSpin * (gx === S.hovered ? 2.4 : 1) * dt);
        if (gx !== S.hovered && gx.core) {
          // gentle per-galaxy out-of-phase opacity breath, dimmed while another
          // galaxy is focused so the hovered one clearly stands out.
          var tw = (0.32 + Math.sin(S.clockT * 0.9 + gx.twPhase) * 0.06) * dimOthers;
          gx.core.material.opacity = tw;
        }
      }

      // Selection halo: gentle breathing pulse around the hovered galaxy.
      if (S.ring && S.ring.visible && S.hovered) {
        var pulse = Math.sin(S.clockT * 3.2);
        var rs = S.hovered.radius * (2.4 + pulse * 0.12);
        S.ring.scale.set(rs, rs, 1);
        S.ring.material.opacity = 0.55 + pulse * 0.12;
      }

      // Advance the motes flowing along relation arcs.
      if (S.flow) {
        var fa = S.flow.attr, fd = S.flow.dots, sc = S.flow.scratch;
        for (var fi = 0; fi < fd.length; fi++) {
          var dot = fd[fi];
          dot.curve.getPoint((S.clockT * dot.speed + dot.phase) % 1, sc);
          fa.setXYZ(fi, sc.x, sc.y, sc.z);
        }
        fa.needsUpdate = true;
      }

      updateTween(dt);
      if (S.pointerInside && !S.tween) updateHover();

      S.controls.update();
      if (S.composer) S.composer.render();
      else S.renderer.render(S.scene, S.camera);
    }
    S.raf = requestAnimationFrame(loop);
  }

  // ============================================================
  //  Hover / raycast
  // ============================================================
  function updateHover() {
    S.raycaster.setFromCamera(S.pointer, S.camera);
    var targets = S.galaxies.map(function (g) { return g.core; });
    var hits = S.raycaster.intersectObjects(targets, false);
    var hit = hits.length ? hits[0].object : null;
    var gal = null;
    if (hit) {
      for (var i = 0; i < S.galaxies.length; i++) {
        if (S.galaxies[i].core === hit) { gal = S.galaxies[i]; break; }
      }
    }
    setHover(gal);
  }

  function setHover(gal) {
    if (S.hovered === gal) {
      if (gal) positionTooltip();
      return;
    }
    // restore previously hovered galaxy + its relation arcs
    if (S.hovered) {
      var bs = S.hovered.core.userData.baseScale;
      S.hovered.core.scale.set(bs, bs, 1);
      S.hovered.core.material.opacity = 0.9;
      setArcHighlight(S.hovered, false);
    }
    S.hovered = gal;
    var canvas = S.renderer.domElement;
    if (gal) {
      var bs2 = gal.core.userData.baseScale * 1.35;
      gal.core.scale.set(bs2, bs2, 1);
      gal.core.material.opacity = 1.0;
      canvas.style.cursor = 'pointer';
      showTooltip(gal);
      setArcHighlight(gal, true);
      // Park the selection halo on this galaxy, tinted in its own colour.
      if (S.ring) {
        S.ring.position.copy(gal.center);
        S.ring.material.color.copy(gal.coreColor);
        S.ring.visible = true;
      }
    } else {
      canvas.style.cursor = 'grab';
      hideTooltip();
      if (S.ring) S.ring.visible = false;
    }
  }

  // Light up (or restore) every relation arc touching a galaxy — hovering a
  // project reveals which other projects it links to.
  function setArcHighlight(gal, on) {
    var list = gal && gal.arcs;
    if (!list) return;
    for (var i = 0; i < list.length; i++) {
      var a = list[i];
      if (on) {
        a.line.material.opacity = Math.min(0.85, a.baseOpacity * 4 + 0.4);
        a.line.material.color.setHex(0x9fd0ff);
      } else {
        a.line.material.opacity = a.baseOpacity;
        a.line.material.color.copy(a.baseColor);
      }
    }
  }

  // ============================================================
  //  Camera fly-to + drill-down
  // ============================================================
  function flyTo(gal) {
    if (S.tween) return;
    hideTooltip();
    var from = S.camera.position.clone();
    // Land a bit in front of the galaxy along the current view direction.
    var dir = from.clone().sub(gal.center).normalize();
    var dist = Math.max(gal.radius * 3.2, 60);
    var to = gal.center.clone().add(dir.multiplyScalar(dist));
    S.controls.autoRotate = false;
    S.controls.enabled = false;
    S.tween = {
      from: from, to: to,
      targetFrom: S.controls.target.clone(), targetTo: gal.center.clone(),
      t: 0, dur: 0.8, gal: gal, done: false
    };
  }

  function updateTween(dt) {
    var tw = S.tween;
    if (!tw) return;
    tw.t += dt / tw.dur;
    var e = tw.t >= 1 ? 1 : easeInOut(tw.t);
    S.camera.position.lerpVectors(tw.from, tw.to, e);
    S.controls.target.lerpVectors(tw.targetFrom, tw.targetTo, e);
    S.camera.lookAt(S.controls.target);
    if (tw.t >= 1 && !tw.done) {
      tw.done = true;
      var slug = tw.gal.slug;
      S.tween = null;
      S.controls.enabled = true;
      // Drill into the 2D per-project graph.
      S.onOpenProject(slug);
    }
  }
  function easeInOut(t) { return t < 0.5 ? 2 * t * t : -1 + (4 - 2 * t) * t; }

  // ============================================================
  //  HUD (clean / minimal)
  // ============================================================
  function buildHud(container) {
    var hud = document.createElement('div');
    hud.className = 'uv-hud';
    hud.innerHTML =
      '<div class="uv-title">universe</div>' +
      '<div class="uv-count"><span class="uv-count-n">0</span> galaxies</div>';
    container.appendChild(hud);

    var tip = document.createElement('div');
    tip.className = 'uv-tip';
    container.appendChild(tip);

    var empty = document.createElement('div');
    empty.className = 'uv-empty';
    empty.textContent = 'No projects to map yet.';
    container.appendChild(empty);

    S.hud = hud;
    S.tip = tip;
    S.empty = empty;
    S.hudCount = hud.querySelector('.uv-count-n');
  }
  function setHudCount(n) { if (S && S.hudCount) S.hudCount.textContent = n; }
  function showEmpty(on) { if (S && S.empty) S.empty.classList.toggle('show', !!on); }

  function showTooltip(gal) {
    if (!S.tip) return;
    S.tip.innerHTML = '<b>' + escHtml(gal.name) + '</b><span>' + gal.docCount + ' docs</span>';
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
  // Top doc_type colors (by count), at least one. Returns array of hex strings.
  function topColors(types) {
    var entries = [];
    if (types) {
      Object.keys(types).forEach(function (k) { entries.push([k, types[k] || 0]); });
    }
    entries.sort(function (a, b) { return b[1] - a[1]; });
    var out = [];
    for (var i = 0; i < entries.length && out.length < 3; i++) {
      out.push(TYPE_COLOR[entries[i][0]] || DEFAULT_COLOR);
    }
    if (!out.length) out.push(DEFAULT_COLOR);
    // Weight the dominant type so the mix leans toward it.
    if (out.length > 1) out.unshift(out[0]);
    return out;
  }

  // Radial-gradient sprite texture (soft glow) used for points + core.
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

  // Luminous annulus texture for the hover selection halo (soft glow + crisp line).
  function makeRingTexture() {
    var size = 128;
    var c = document.createElement('canvas');
    c.width = c.height = size;
    var ctx = c.getContext('2d');
    var cx = size / 2;
    var rad = size * 0.40;
    // soft outer glow
    ctx.lineWidth = 6;
    ctx.strokeStyle = 'rgba(255,255,255,0.18)';
    ctx.shadowColor = 'rgba(255,255,255,0.9)';
    ctx.shadowBlur = 10;
    ctx.beginPath();
    ctx.arc(cx, cx, rad, 0, Math.PI * 2);
    ctx.stroke();
    // crisp bright inner line
    ctx.shadowBlur = 0;
    ctx.lineWidth = 2.5;
    ctx.strokeStyle = 'rgba(255,255,255,0.95)';
    ctx.beginPath();
    ctx.arc(cx, cx, rad, 0, Math.PI * 2);
    ctx.stroke();
    var tex = new THREE.CanvasTexture(c);
    tex.needsUpdate = true;
    return tex;
  }

  // Shared, always-camera-facing selection halo sprite (one instance, reused).
  function makeSelectionRing(tex) {
    var mat = new THREE.SpriteMaterial({
      map: tex, color: 0xffffff, transparent: true,
      opacity: 0, depthWrite: false, depthTest: false,
      blending: THREE.AdditiveBlending
    });
    var sprite = new THREE.Sprite(mat);
    sprite.visible = false;
    sprite.renderOrder = 999;   // always drawn over the particle clouds
    S.disposables.push(mat);
    return sprite;
  }

  // Wire an EffectComposer with a bloom pass — but only if the postproc libs
  // actually loaded. Any absence/error falls back to a plain renderer.render.
  function setupComposer(w, h) {
    if (typeof THREE.EffectComposer !== 'function' ||
        typeof THREE.RenderPass !== 'function' ||
        typeof THREE.UnrealBloomPass !== 'function') {
      return;
    }
    try {
      var composer = new THREE.EffectComposer(S.renderer);
      composer.setPixelRatio(S.renderer.getPixelRatio());
      composer.setSize(w, h);
      composer.addPass(new THREE.RenderPass(S.scene, S.camera));
      // (resolution, strength, radius, threshold) — bright cores/motes glow.
      var bloom = new THREE.UnrealBloomPass(new THREE.Vector2(w, h), 0.85, 0.55, 0.18);
      composer.addPass(bloom);
      S.composer = composer;
      S.bloom = bloom;
    } catch (e) {
      S.composer = null;
    }
  }

  // Distant starfield (constant-size pinpoints) + a few faint nebula clouds.
  // Gives the now-opaque canvas its own depth, replacing the CSS wash.
  function buildBackdrop(scene) {
    var STAR_COUNT = 2600;
    var sp = new Float32Array(STAR_COUNT * 3);
    var scol = new Float32Array(STAR_COUNT * 3);
    var col = new THREE.Color();
    for (var i = 0; i < STAR_COUNT; i++) {
      var r = 1400 + Math.random() * 1100;            // shell well inside camera.far
      var a = Math.random() * Math.PI * 2;
      var p = Math.acos(2 * Math.random() - 1);
      sp[i * 3]     = r * Math.sin(p) * Math.cos(a);
      sp[i * 3 + 1] = r * Math.cos(p);
      sp[i * 3 + 2] = r * Math.sin(p) * Math.sin(a);
      var tint = Math.random();
      if (tint < 0.12) col.setHSL(0.58, 0.5, 0.8);            // cool blue
      else if (tint < 0.20) col.setHSL(0.08, 0.5, 0.8);       // warm
      else col.setHSL(0, 0, 0.7 + Math.random() * 0.3);       // white-ish
      var br = 0.5 + Math.random() * 0.5;
      scol[i * 3] = col.r * br; scol[i * 3 + 1] = col.g * br; scol[i * 3 + 2] = col.b * br;
    }
    var sgeo = new THREE.BufferGeometry();
    sgeo.setAttribute('position', new THREE.BufferAttribute(sp, 3));
    sgeo.setAttribute('color', new THREE.BufferAttribute(scol, 3));
    var smat = new THREE.PointsMaterial({
      size: 1.7, sizeAttenuation: false, vertexColors: true,
      transparent: true, opacity: 0.9, depthWrite: false, map: S.coreTexture
    });
    var stars = new THREE.Points(sgeo, smat);
    stars.frustumCulled = false;
    scene.add(stars);
    S.disposables.push(sgeo, smat);

    // Huge, very faint additive nebula blobs for colour + depth.
    [{ c: 0x4aa3ff, x: -700, y: 250, z: -600 },
     { c: 0xb07cff, x: 650, y: -300, z: -500 },
     { c: 0x2fe0d0, x: 200, y: 400, z: -900 }].forEach(function (nb) {
      var m = new THREE.SpriteMaterial({
        map: S.coreTexture, color: new THREE.Color(nb.c), transparent: true,
        opacity: 0.06, depthWrite: false, depthTest: false,
        blending: THREE.AdditiveBlending
      });
      var s = new THREE.Sprite(m);
      s.scale.set(1500, 1500, 1);
      s.position.set(nb.x, nb.y, nb.z);
      s.renderOrder = -1;
      scene.add(s);
      S.disposables.push(m);
    });
  }

  function escHtml(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (ch) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch];
    });
  }

  // ============================================================
  //  Teardown — no WebGL context / listener leaks
  // ============================================================
  function destroy() {
    if (!S) return;
    var s = S;
    S = null;   // stop the loop guard immediately

    if (s.raf != null) cancelAnimationFrame(s.raf);
    if (s.idleTimer) clearTimeout(s.idleTimer);

    // canvas-bound listeners (pointermove/leave/click) die with the removed
    // canvas DOM node below; only window/document listeners need explicit removal.
    window.removeEventListener('resize', s.onResize);
    document.removeEventListener('visibilitychange', s.onVisibility);

    if (s.controls && s.controls.dispose) s.controls.dispose();
    if (s.composer && s.composer.dispose) s.composer.dispose();
    if (s.bloom && s.bloom.dispose) s.bloom.dispose();

    // Dispose all tracked geometries/materials/textures.
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
      // clear children
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

    // Remove HUD DOM.
    [s.hud, s.tip, s.empty].forEach(function (el) {
      if (el && el.parentNode) el.parentNode.removeChild(el);
    });
  }

  function isMounted() { return !!S; }

  return { mount: mount, destroy: destroy, isMounted: isMounted };
})();
