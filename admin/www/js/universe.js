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
      dragging: false,
      // Gentle hover-dolly: ease the camera a touch toward a hovered galaxy.
      dolly: { amt: 0, gal: null, lastGal: null, restP: null, restT: null },
      _t1: new THREE.Vector3(), _t2: new THREE.Vector3(), _t3: new THREE.Vector3()
    };

    var W = container.clientWidth || window.innerWidth;
    var H = container.clientHeight || window.innerHeight;

    var scene = new THREE.Scene();
    var camera = new THREE.PerspectiveCamera(55, W / H, 0.1, 4000);
    camera.position.set(0, 40, 320);

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
    controls.minDistance = 40;
    controls.maxDistance = 1600;
    // Ambient idle motion is intentional and runs regardless of
    // prefers-reduced-motion (reduced-motion only tames very aggressive
    // effects, not the gentle base drift the user explicitly wants).
    controls.autoRotate = true;
    controls.autoRotateSpeed = 0.35;
    // Pause autoRotate while the user is interacting; resume after idle.
    var idleTimer = null;
    controls.addEventListener('start', function () {
      controls.autoRotate = false;
      if (idleTimer) { clearTimeout(idleTimer); idleTimer = null; }
      if (S) { S.dragging = true; S.dolly.gal = null; }   // let the user orbit freely
    });
    controls.addEventListener('end', function () {
      if (idleTimer) clearTimeout(idleTimer);
      idleTimer = setTimeout(function () { if (S) controls.autoRotate = true; }, 2500);
      if (S) S.dragging = false;
    });

    S.scene = scene;
    S.camera = camera;
    S.renderer = renderer;
    S.controls = controls;
    S.idleTimer = idleTimer;
    S.coreTexture = makeGlowTexture();
    S.disposables.push(S.coreTexture);

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

    // 1) Deterministic Fibonacci-sphere layout, radius scales with count.
    var n = galaxies.length;
    var spread = 80 + Math.sqrt(n) * 44;   // tighter cluster -> default view fills more
    var pos = galaxies.map(function (g, i) {
      return fibonacciPoint(i, n, spread);
    });

    // 2) A few relation-attraction iterations: pull related galaxies closer.
    var idIndex = {};
    galaxies.forEach(function (g, i) { idIndex[g.id] = i; });
    var edges = [];
    links.forEach(function (l) {
      var a = idIndex[l.s], b = idIndex[l.t];
      if (a == null || b == null || a === b) return;
      edges.push([a, b, l.rel]);
    });
    for (var iter = 0; iter < 24; iter++) {
      edges.forEach(function (e) {
        var pa = pos[e[0]], pb = pos[e[1]];
        var mx = (pa.x + pb.x) / 2, my = (pa.y + pb.y) / 2, mz = (pa.z + pb.z) / 2;
        var k = 0.04;
        pa.x += (mx - pa.x) * k; pa.y += (my - pa.y) * k; pa.z += (mz - pa.z) * k;
        pb.x += (mx - pb.x) * k; pb.y += (my - pb.y) * k; pb.z += (mz - pb.z) * k;
      });
    }

    // 3) Compute global particle budget allocation.
    var totalDocs = galaxies.reduce(function (a, g) { return a + (g.doc_count || 1); }, 0) || 1;

    galaxies.forEach(function (g, i) {
      var p = pos[i];
      var built = buildGalaxy(g, totalDocs);
      built.group.position.set(p.x, p.y, p.z);
      built.slug = g.slug;
      built.name = g.name || g.slug;
      built.docCount = g.doc_count || 0;
      built.center = new THREE.Vector3(p.x, p.y, p.z);
      S.scene.add(built.group);
      S.galaxies.push(built);
    });

    // 4) Relation arcs between galaxy centres (additive, low opacity).
    buildArcs(edges, pos);

    // 5) Fit-to-view: frame the WHOLE universe with margin so the user opens
    //    onto every galaxy, not zoomed into one. Bounding sphere = max
    //    (centre distance + galaxy radius) around the universe centroid.
    fitToView();
  }

  // Compute the bounding sphere of all galaxies (centre + radius) and place
  // the start camera so everything fits the frame with a margin.
  function fitToView() {
    if (!S || !S.galaxies.length) return;
    var center = new THREE.Vector3();
    S.galaxies.forEach(function (g) { center.add(g.center); });
    center.multiplyScalar(1 / S.galaxies.length);

    var boundingRadius = 1;
    S.galaxies.forEach(function (g) {
      // core sprite stretches a bit past the particle radius -> use coreScale
      var reach = center.distanceTo(g.center) +
        Math.max(g.radius, (g.core && g.core.userData.baseScale) || g.radius);
      if (reach > boundingRadius) boundingRadius = reach;
    });

    var fov = S.camera.fov * Math.PI / 180;
    var margin = 1.05;   // start a touch more zoomed-in by default
    var dist = (boundingRadius / Math.sin(fov / 2)) * margin;

    // Pleasant oblique axis (slightly above + offset), looking at centre.
    var dir = new THREE.Vector3(0.35, 0.28, 1).normalize();
    S.camera.position.copy(center.clone().add(dir.multiplyScalar(dist)));
    S.controls.target.copy(center);
    S.camera.lookAt(center);

    // Make sure nothing clips: far plane past the far edge, allow zoom-out.
    S.camera.far = Math.max(S.camera.far, (dist + boundingRadius) * 2.2);
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

    var spiral = docCount > GLOBULAR_MAX;
    var radius = spiral ? (26 + Math.min(36, Math.sqrt(docCount) * 3.4))
                        : (12 + Math.min(18, Math.sqrt(docCount) * 2.4));

    // Color blend from the galaxy's dominant doc_types (top 3, weighted).
    var palette = topColors(g.types);

    var positions = new Float32Array(count * 3);
    var colors = new Float32Array(count * 3);
    var arms = docCount > 60 ? 3 : 2;
    var tmp = new THREE.Color();

    for (var i = 0; i < count; i++) {
      var x, y, z;
      if (spiral) {
        // Spiral disk + bulge. Logarithmic arms with scatter.
        var bulge = Math.random() < 0.22;
        if (bulge) {
          var br = Math.pow(Math.random(), 1.8) * radius * 0.35;
          var ba = Math.random() * Math.PI * 2;
          var bp = Math.acos(2 * Math.random() - 1);
          x = br * Math.sin(bp) * Math.cos(ba);
          y = br * Math.cos(bp) * 0.7;
          z = br * Math.sin(bp) * Math.sin(ba);
        } else {
          var t = Math.pow(Math.random(), 0.6);
          var rr = t * radius;
          var arm = Math.floor(Math.random() * arms);
          var baseAng = (arm / arms) * Math.PI * 2;
          var ang = baseAng + t * 3.4;                 // winding
          var scatter = (1 - t) * 0.5 + 0.12;
          ang += (Math.random() - 0.5) * scatter;
          x = Math.cos(ang) * rr + (Math.random() - 0.5) * 4;
          z = Math.sin(ang) * rr + (Math.random() - 0.5) * 4;
          y = (Math.random() - 0.5) * (3.5 + (1 - t) * 7);  // thin disk, thick core
        }
      } else {
        // Globular cluster: dense centre, smooth falloff (Plummer-ish).
        var gr = Math.pow(Math.random(), 1.6) * radius;
        var ga = Math.random() * Math.PI * 2;
        var gp = Math.acos(2 * Math.random() - 1);
        x = gr * Math.sin(gp) * Math.cos(ga);
        y = gr * Math.cos(gp);
        z = gr * Math.sin(gp) * Math.sin(ga);
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
      size: spiral ? 1.6 : 1.9,
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

    // Bright core glow sprite (also the raycast target via a small hit point).
    var coreColor = new THREE.Color(palette[0]);
    var spriteMat = new THREE.SpriteMaterial({
      map: S.coreTexture, color: coreColor, transparent: true,
      opacity: 0.9, depthWrite: false, blending: THREE.AdditiveBlending
    });
    var core = new THREE.Sprite(spriteMat);
    var coreScale = radius * (spiral ? 1.0 : 1.35);   // tighter nucleus -> less flat outer-glow disc
    core.scale.set(coreScale, coreScale, 1);
    core.userData.baseScale = coreScale;
    S.disposables.push(spriteMat);

    var group = new THREE.Group();
    group.add(points);
    group.add(core);
    group.userData.isGalaxy = true;

    return {
      group: group, points: points, core: core, coreColor: coreColor,
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
    });
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
      for (var i = 0; i < S.galaxies.length; i++) {
        var gx = S.galaxies[i];
        if (!S.hovered) gx.group.rotation.y += gx.baseSpin * dt;   // hover pauses the spin
        if (gx !== S.hovered && gx.core) {
          // gentle per-galaxy out-of-phase opacity breath (dimmed core glow)
          var tw = 0.32 + Math.sin(S.clockT * 0.9 + gx.twPhase) * 0.06;
          gx.core.material.opacity = tw;
        }
      }

      // Hover dolly: ease the camera a touch toward the hovered galaxy, and
      // back out on leave. Suspended while dragging (free orbit) or flying.
      var d = S.dolly;
      if (d.lastGal && d.restP && !S.tween && !S.dragging) {
        var goal = d.gal ? 1 : 0;
        d.amt += (goal - d.amt) * Math.min(1, dt * 5);
        if (goal === 0 && d.amt < 0.003) {
          d.amt = 0; d.lastGal = null; S.controls.autoRotate = true;
        } else {
          var gc = d.lastGal.center;
          var off = S._t1.copy(d.restP).sub(gc);
          var rest = off.length() || 1;
          var near = Math.max(d.lastGal.radius * 3.0, rest * 0.86);
          off.multiplyScalar(near / rest);
          S.camera.position.lerpVectors(d.restP, S._t2.copy(gc).add(off), d.amt);
          S.controls.target.lerpVectors(d.restT, S._t3.copy(d.restT).lerp(gc, 0.30), d.amt);
        }
      }

      updateTween(dt);
      if (S.pointerInside && !S.tween) updateHover();

      S.controls.update();
      S.renderer.render(S.scene, S.camera);
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
    // restore previous
    if (S.hovered) {
      var bs = S.hovered.core.userData.baseScale;
      S.hovered.core.scale.set(bs, bs, 1);
      S.hovered.core.material.opacity = 0.9;
    }
    S.hovered = gal;
    var canvas = S.renderer.domElement;
    if (gal) {
      var bs2 = gal.core.userData.baseScale * 1.35;
      gal.core.scale.set(bs2, bs2, 1);
      gal.core.material.opacity = 1.0;
      canvas.style.cursor = 'pointer';
      showTooltip(gal);
      // Start a gentle dolly toward this galaxy (skipped during a fly-to).
      if (!S.tween) {
        var d = S.dolly;
        if (d.amt < 0.05) { d.restP = S.camera.position.clone(); d.restT = S.controls.target.clone(); }
        d.gal = gal; d.lastGal = gal;
        S.controls.autoRotate = false;
      }
    } else {
      canvas.style.cursor = 'grab';
      hideTooltip();
      S.dolly.gal = null;   // release -> eases back to the pre-hover pose
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
  // Even point distribution on a sphere (Fibonacci spiral).
  function fibonacciPoint(i, n, r) {
    var ga = Math.PI * (3 - Math.sqrt(5));     // golden angle
    var y = 1 - (i / Math.max(1, n - 1)) * 2;  // -1..1
    var rad = Math.sqrt(Math.max(0, 1 - y * y));
    var theta = ga * i;
    return new THREE.Vector3(Math.cos(theta) * rad * r, y * r, Math.sin(theta) * rad * r);
  }

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
