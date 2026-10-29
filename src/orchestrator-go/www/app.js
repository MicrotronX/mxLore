(function () {
  "use strict";

  const $ = (id) => document.getElementById(id);
  const state = { projects: [], groups: [], tabs: [], views: new Map(), active: null, pollTimer: null, pollCount: 0, filter: "", online: true, signedIn: false, mru: [] };

  class AuthError extends Error {}
  class NetError extends Error {}

  const errorText = {
    unauthorized: "Your session has ended. Sign in again.",
    bad_request: "The request was not understood. Reload the page and try again.",
    not_found: "That item no longer exists. The list has been refreshed.",
    project_not_found: "This project was removed. The list has been refreshed.",
    path_not_absolute: "Enter a full path that starts with a drive letter, for example C:\\Projects\\example.",
    path_not_found: "That folder does not exist. Check the path, or tick \"Create the folder\".",
    mkdir_failed: "The folder could not be created. Check the path and your permissions.",
    path_already_registered: "This folder is already in your project list.",
    invalid_session_id: "There is no previous session to resume. Use Continue or New instead.",
    invalid_mode: "Unknown start mode. Reload the page and try again.",
    start_failed: "The console could not be started.",
    busy: "This session is already saving or closing. Wait for it to finish.",
    invalid_save_prompt: "The save command must be a single line of up to 200 characters.",
    invalid_save_idle_seconds: "Quiet time must be between 2 and 600 seconds.",
    invalid_save_timeout_minutes: "Save timeout must be between 1 and 240 minutes.",
    invalid_session_days: "Stay signed in must be between 1 and 90 days.",
    stale_quick_action: "The quick actions were changed elsewhere. The buttons are reloaded, please click again.",
    invalid_quick_actions: "Quick actions: up to 8 buttons, names up to 40 characters, 1 to 10 single-line steps of up to 200 characters each.",
    save_failed: "Settings could not be written to disk. Check the data folder permissions.",
    bad_origin: "The server rejected the request origin. Open the orchestrator via its own address.",
    rate_limited: "Too many sign-in attempts. Wait a minute, then try again.",
    code_not_found: "VS Code was not found. Install it and make sure the code command is on the PATH of the orchestrator.",
    invalid_group_name: "Enter a group name of up to 80 characters.",
    group_exists: "A group with this name already exists.",
    group_not_found: "That group no longer exists. The list has been refreshed.",
    unknown_project: "One of the projects no longer exists. The list has been refreshed.",
    invalid_mxlore_url: "Enter a full address, for example http://127.0.0.1:8080 or https://lore.example.com. A server on another computer needs https.",
    mxlore_not_configured: "Set the mxLore server address first. Open Server settings below.",
    setup_code_required: "Enter the setup code.",
    invalid_setup_code: "That setup code is not valid. Copy it again from the setup code file.",
    use_recovery: "Two-factor sign-in is not set up, so the address cannot be changed here. Start the orchestrator with --recovery and change it after signing in.",
    totp_mandatory: "Two-factor sign-in cannot be turned off while an mxLore account is linked.",
    enroll_2fa_required: "Set up two-factor sign-in to continue.",
    conflict: "Something changed in the meantime. Close this window and open it again.",
    totp_locked: "Too many wrong codes. Wait 15 minutes, then try again.",
    totp_not_started: "The setup has expired. Start the two-factor setup again.",
    totp_already_enabled: "Two-factor sign-in is already on.",
    totp_not_enabled: "Two-factor sign-in is already off.",
    totp_failed: "The two-factor setup could not be started.",
    key_and_totp_required: "Enter the mxLore key of the linked account and the code from your authenticator app.",
    invalid_key: "That mxLore key does not belong to the linked account.",
    mxlore_unreachable: "The current mxLore server could not be reached, so your key cannot be checked. Start the orchestrator with --recovery and change the address after signing in."
  };

  function describe(e) {
    const code = e && e.data && e.data.error;
    let msg = (code && errorText[code]) || (e && e.message) || String(e);
    if (code === "start_failed" && e.data.detail) msg += " " + e.data.detail;
    return msg;
  }

  async function api(method, path, body) {
    const opt = { method, credentials: "same-origin", headers: {} };
    if (body !== undefined) {
      opt.headers["Content-Type"] = "application/json";
      opt.body = JSON.stringify(body);
    }
    let res;
    try { res = await fetch(path, opt); } catch (e) {
      setOnline(false);
      throw new NetError("The orchestrator is not reachable. Check that it is still running.");
    }
    setOnline(true);
    let data = null;
    const text = await res.text();
    if (text) { try { data = JSON.parse(text); } catch (e) { data = { error: text.trim() }; } }
    if (res.status === 401 && path !== "/api/login") {
      if (state.signedIn) showLogin(false, errorText.unauthorized);
      throw new AuthError("unauthorized");
    }
    if (res.status === 403 && data && data.error === "enroll_2fa_required") {
      if (state.signedIn) showEnroll();
      throw new AuthError("enroll_2fa_required");
    }
    if (!res.ok) {
      const err = new Error((data && data.error) || res.statusText || "Request failed (" + res.status + ").");
      err.status = res.status;
      err.data = data || {};
      throw err;
    }
    return data;
  }

  function setOnline(on) {
    if (state.online === on) return;
    state.online = on;
    const b = $("connBanner");
    if (on) {
      b.classList.add("hidden");
      if (state.signedIn) refreshAll();
    } else if (state.signedIn) {
      b.textContent = "Connection to the orchestrator lost. Sessions keep running on the server; this page reconnects on its own.";
      b.classList.remove("hidden");
    }
  }

  function toast(msg, bad) {
    const t = $("toast");
    t.textContent = msg;
    t.classList.toggle("bad", !!bad);
    t.classList.add("show");
    clearTimeout(toast.timer);
    toast.timer = setTimeout(() => t.classList.remove("show"), bad ? 6000 : 3200);
  }

  function fail(e) {
    if (e instanceof AuthError) return;
    toast(describe(e), true);
  }

  function el(tag, cls, text) {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text !== undefined) n.textContent = text;
    return n;
  }

  const SVGNS = "http://www.w3.org/2000/svg";
  function icon(d) {
    const s = document.createElementNS(SVGNS, "svg");
    s.setAttribute("viewBox", "0 0 16 16");
    s.setAttribute("aria-hidden", "true");
    const p = document.createElementNS(SVGNS, "path");
    p.setAttribute("d", d);
    s.appendChild(p);
    return s;
  }
  const ICON_X = "M4 4l8 8M12 4l-8 8";
  const ICON_PEN = "M10.5 2.5l3 3L6 13H3v-3z";
  const ICON_TRASH = "M3 4.5h10M6.5 4.5V3h3v1.5M4.5 4.5l.7 8.5h5.6l.7-8.5";

  function relTime(iso) {
    if (!iso) return "";
    const s = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
    if (s < 60) return "just now";
    if (s < 3600) return Math.floor(s / 60) + " min ago";
    if (s < 86400) return Math.floor(s / 3600) + " h ago";
    const d = Math.floor(s / 86400);
    if (d === 1) return "yesterday";
    if (d < 30) return d + " days ago";
    return new Date(iso).toLocaleDateString();
  }

  function duration(iso) {
    if (!iso) return "";
    let s = Math.max(0, Math.floor((Date.now() - new Date(iso).getTime()) / 1000));
    const h = Math.floor(s / 3600); s -= h * 3600;
    const m = Math.floor(s / 60);
    if (h >= 24) return Math.floor(h / 24) + " d " + (h % 24) + " h";
    if (h) return h + " h " + m + " min";
    return m ? m + " min" : "under a minute";
  }

  function isClaude(t) { return t.mode === "new" || t.mode === "continue" || t.mode === "resume"; }

  function lampOf(t) {
    if (!t.running) return "none";
    if (t.state === "saving" || t.state === "exiting") return "busy";
    if (t.state === "save_timeout") return "timeout";
    if (t.claudeState === "blocked") return "attention";
    if (t.working) return "working";
    return "running";
  }

  const stateLabel = { none: "Exited", busy: "Saving", timeout: "Save timed out", attention: "Needs you", working: "Working", running: "Waiting for you" };
  function stateText(t) {
    if (!t.running) return "Exited" + (t.exitCode !== null && t.exitCode !== undefined ? " (code " + t.exitCode + ")" : "");
    if (t.state === "exiting") return "Closing";
    if (t.state === "save_timeout") return "Save timed out, still running";
    if (!isClaude(t)) return "Running";
    return stateLabel[lampOf(t)];
  }

  function projectLamp(p) {
    if (!p.exists) return "missing";
    const rank = { timeout: 5, attention: 4, busy: 3, working: 2, running: 1, none: 0 };
    let best = "none";
    for (const t of state.tabs) if (t.projectId === p.id && rank[lampOf(t)] > rank[best]) best = lampOf(t);
    return best;
  }

  const loginMessages = {
    invalid_key: "That key is not valid. Use the mxLore key of the account linked to this orchestrator.",
    invalid_key_setup: "That mxLore key was rejected by the server. Check the key and the server address.",
    totp_required: "Enter the 6-digit code from your authenticator app.",
    mxlore_unreachable: "The mxLore server could not be reached. Check the address under Server settings.",
    mxlore_not_configured: errorText.mxlore_not_configured,
    setup_code_required: "This orchestrator is not linked yet. Enter the setup code as well.",
    invalid_setup_code: errorText.invalid_setup_code,
    invalid_totp: "That authenticator code is not valid. Check the time on this device and try the current code.",
    rate_limited: errorText.rate_limited
  };

  const pre = { info: null };

  function preRender() {
    const i = pre.info;
    if (!i) return;
    $("loginServer").textContent = i.mxLoreUrl ? "Server: " + i.mxLoreUrl : "No mxLore server is set yet.";
    const where = i.setupCodePath ? "You find the setup code in " + i.setupCodePath + " on the computer running the orchestrator." : "";
    $("setupCodeRow").classList.toggle("hidden", !i.setupMode);
    $("setupCodeHint").textContent = where;
    $("preSetupRow").classList.toggle("hidden", !i.setupMode);
    $("preSetupHint").textContent = where;
    $("preKeyRow").classList.toggle("hidden", i.setupMode);
    $("preTotpRow").classList.toggle("hidden", i.setupMode);
    $("totpRow").classList.toggle("hidden", !i.totpEnabled);
    if (!i.mxLoreUrl) {
      showPreSettings(true);
      $("preUrl").focus();
    }
  }

  async function preLoad() {
    try { pre.info = await api("GET", "/api/setup"); } catch (e) { pre.info = null; }
    preRender();
  }

  function showPreSettings(open) {
    $("preSettings").classList.toggle("hidden", !open);
    $("preSettingsToggle").setAttribute("aria-expanded", open ? "true" : "false");
    if (open && !$("preUrl").value && pre.info && pre.info.mxLoreUrl) $("preUrl").value = pre.info.mxLoreUrl;
  }

  function showLogin(totpEnabled, message) {
    state.signedIn = false;
    stopPolling();
    closeOverlays();
    for (const v of state.views.values()) disposeView(v);
    state.views.clear();
    state.tabs = [];
    state.active = null;
    $("connBanner").classList.add("hidden");
    $("app").classList.add("hidden");
    $("enroll").classList.add("hidden");
    $("login").classList.remove("hidden");
    $("totpRow").classList.toggle("hidden", !totpEnabled);
    $("loginError").textContent = message || "";
    $("loginKey").focus();
    preLoad();
  }

  function showIdentity(me) {
    const el = $("signedInAs");
    const name = me && me.developer && me.developer.name;
    const text = name ? "Signed in as " + name : (me && me.loginKind === "recovery" ? "Signed in with the recovery key" : "");
    el.textContent = text;
    el.title = text;
    el.classList.toggle("hidden", !text);
  }

  async function showEnroll() {
    state.signedIn = false;
    stopPolling();
    closeOverlays();
    $("app").classList.add("hidden");
    $("login").classList.add("hidden");
    $("enroll").classList.remove("hidden");
    $("enrollError").textContent = "";
    $("enrollCode").value = "";
    $("enrollRetry").classList.add("hidden");
    $("enrollSubmit").classList.remove("hidden");
    $("enrollQr").classList.remove("hidden");
    $("enrollSecret").classList.remove("hidden");
    try {
      const r = await api("POST", "/api/security/totp/start");
      $("enrollQr").src = r.qr;
      $("enrollSecret").textContent = r.secret;
      $("enrollCode").focus();
    } catch (e) {
      if (e instanceof AuthError) return;
      $("enrollQr").classList.add("hidden");
      $("enrollSecret").classList.add("hidden");
      $("enrollSubmit").classList.add("hidden");
      $("enrollRetry").classList.remove("hidden");
      $("enrollError").textContent = describe(e);
      $("enrollRetry").focus();
    }
  }

  async function showApp() {
    let me = null;
    try { me = await api("GET", "/api/me"); } catch (e) {}
    if (me && me.mustEnroll2FA) { await showEnroll(); return; }
    state.signedIn = true;
    showIdentity(me);
    $("login").classList.add("hidden");
    $("enroll").classList.add("hidden");
    $("app").classList.remove("hidden");
    await refreshAll();
    loadQuickActions();
    startPolling();
  }

  $("loginForm").addEventListener("submit", async (ev) => {
    ev.preventDefault();
    $("loginError").textContent = "";
    const body = { key: $("loginKey").value.trim() };
    const totp = $("loginTotp").value.trim();
    if (totp) body.totp = totp;
    const setupCode = $("loginSetupCode").value.trim();
    if (setupCode) body.setupCode = setupCode;
    try {
      await api("POST", "/api/login", body);
      $("loginKey").value = "";
      $("loginTotp").value = "";
      $("loginSetupCode").value = "";
      await showApp();
    } catch (e) {
      const code = e.data && e.data.error;
      if (code === "totp_required" || code === "invalid_totp") {
        $("totpRow").classList.remove("hidden");
        $("loginTotp").focus();
      }
      if (code === "setup_code_required" || code === "invalid_setup_code") {
        $("setupCodeRow").classList.remove("hidden");
        $("loginSetupCode").focus();
      }
      if (code === "mxlore_not_configured" || code === "mxlore_unreachable") showPreSettings(true);
      const key = code === "invalid_key" && pre.info && pre.info.setupMode ? "invalid_key_setup" : code;
      $("loginError").textContent = loginMessages[key] || (e.status === 429 ? loginMessages.rate_limited : describe(e));
    }
  });

  $("preSettingsToggle").addEventListener("click", () => {
    showPreSettings($("preSettings").classList.contains("hidden"));
  });

  $("preSettings").addEventListener("submit", async (ev) => {
    ev.preventDefault();
    $("preError").textContent = "";
    const body = { url: $("preUrl").value.trim() };
    const setupCode = $("preSetupCode").value.trim();
    if (setupCode) body.setupCode = setupCode;
    const totp = $("preTotp").value.trim();
    if (totp) body.totp = totp;
    const key = $("preKey").value.trim();
    if (key) body.key = key;
    try {
      const r = await api("POST", "/api/setup/mxlore-url", body);
      $("preTotp").value = "";
      $("preKey").value = "";
      $("preUrl").value = r.mxLoreUrl;
      if (setupCode && !$("loginSetupCode").value) $("loginSetupCode").value = setupCode;
      $("preSetupCode").value = "";
      await preLoad();
      showPreSettings(false);
      $("loginError").textContent = "";
      toast("mxLore server address saved.");
      $("loginKey").focus();
    } catch (e) {
      const code = e.data && e.data.error;
      $("preError").textContent = errorText[code] || (e.status === 429 ? errorText.rate_limited : describe(e));
    }
  });

  $("enrollForm").addEventListener("submit", async (ev) => {
    ev.preventDefault();
    $("enrollError").textContent = "";
    try {
      await api("POST", "/api/security/totp/confirm", { code: $("enrollCode").value.trim() });
      $("enrollCode").value = "";
      $("enrollQr").removeAttribute("src");
      $("enrollSecret").textContent = "";
      toast("Two-factor sign-in is on.");
      await showApp();
    } catch (e) {
      if (e instanceof AuthError) return;
      const code = e.data && e.data.error;
      if (code === "totp_not_started") { await showEnroll(); $("enrollError").textContent = errorText.totp_not_started; return; }
      $("enrollError").textContent = describe(e);
    }
  });

  $("enrollSignOut").addEventListener("click", () => signOut());
  $("enrollRetry").addEventListener("click", () => showEnroll());

  async function signOut() {
    try { await api("POST", "/api/logout"); } catch (e) {}
    showLogin(false, "You are signed out.");
  }
  $("logoutBtn").addEventListener("click", signOut);

  async function refreshAll() {
    try {
      const [projects, tabs, groups] = await Promise.all([api("GET", "/api/projects"), api("GET", "/api/tabs"), api("GET", "/api/groups")]);
      state.projects = projects || [];
      state.groups = groups || [];
      syncTabs(tabs || []);
      renderProjects();
    } catch (e) { fail(e); }
  }

  async function refreshProjects() {
    try { const [ps, gs] = await Promise.all([api("GET", "/api/projects"), api("GET", "/api/groups")]); state.projects = ps || []; state.groups = gs || []; renderProjects(); } catch (e) { if (!(e instanceof NetError)) fail(e); }
  }

  function startPolling() {
    stopPolling();
    state.pollTimer = setInterval(async () => {
      state.pollCount++;
      try {
        syncTabs((await api("GET", "/api/tabs")) || []);
        if (state.pollCount % 15 === 0) await refreshProjects();
        if (state.pollCount % 5 === 0) await refreshUpdate();
      } catch (e) {}
    }, 2000);
  }

  // The tab strip has no visible scrollbar; the mouse wheel scrolls it sideways.
  $("tabBar").addEventListener("wheel", (ev) => {
    const bar = $("tabBar");
    if (bar.scrollWidth <= bar.clientWidth || Math.abs(ev.deltaX) > Math.abs(ev.deltaY)) return;
    bar.scrollLeft += ev.deltaY;
    ev.preventDefault();
  }, { passive: false });

  async function refreshUpdate() {
    const u = await api("GET", "/api/update");
    const bar = $("updateBar");
    bar.classList.toggle("hidden", !(u && u.pending));
    if (!u || !u.pending) return;
    const n = u.busy.length;
    $("updateText").textContent = n
      ? "A new version is ready. Restart when you are ready. Still working: " + u.busy.join(", ") + "."
      : "A new version is ready. Restart when you are ready.";
  }
  $("updateNow").addEventListener("click", async () => {
    if (!confirm("Restart now? Sessions that are still working are interrupted. Every tab can be resumed afterwards.")) return;
    try { await api("POST", "/api/update/restart"); $("updateText").textContent = "Restarting. Reload this page in a few seconds."; } catch (e) { fail(e); }
  });

  function stopPolling() {
    if (state.pollTimer) clearInterval(state.pollTimer);
    state.pollTimer = null;
  }

  function projectById(id) { return state.projects.find((p) => p.id === id); }

  function sortedProjects() {
    return state.projects.slice().sort((a, b) => {
      const ta = a.lastSessionAt ? Date.parse(a.lastSessionAt) : 0;
      const tb = b.lastSessionAt ? Date.parse(b.lastSessionAt) : 0;
      if (ta !== tb) return tb - ta;
      return a.name.localeCompare(b.name);
    });
  }

  function pinnedProjects() {
    return state.projects.filter((p) => p.pinned).sort((a, b) => ((a.order || 1e9) - (b.order || 1e9)) || a.name.localeCompare(b.name));
  }

  function sortedGroups() {
    return state.groups.slice().sort((a, b) => (a.order - b.order) || a.name.localeCompare(b.name));
  }
  function groupById(id) { return state.groups.find((g) => g.id === id); }
  function groupOf(p) { return p.groupId && groupById(p.groupId) ? p.groupId : ""; }
  function groupMembers(gid) { return sortedProjects().filter((p) => groupOf(p) === gid); }

  function railProjects() {
    const rest = sortedProjects().filter((p) => !p.pinned);
    let out = pinnedProjects();
    for (const g of sortedGroups()) out = out.concat(rest.filter((p) => groupOf(p) === g.id));
    return out.concat(rest.filter((p) => !groupOf(p)));
  }

  const LAMP_RANK = { timeout: 5, attention: 4, busy: 3, working: 2, running: 1, none: 0, missing: -1 };
  function groupLamp(gid) {
    let best = "none";
    for (const p of groupMembers(gid)) { const l = projectLamp(p); if (LAMP_RANK[l] > LAMP_RANK[best]) best = l; }
    return best;
  }

  function matchesFilter(p, q) {
    if (!q) return true;
    return fuzzy(q, p.name + " " + p.path) !== null;
  }

  const AVATAR_COLORS = ["#4E6C9C", "#6E5E9E", "#865A7A", "#5A7A68", "#7A6C55", "#55708A", "#7B5E8E", "#647089"];
  function hashStr(s) {
    let h = 2166136261;
    for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); }
    return h >>> 0;
  }
  function monogram(name) {
    const words = (name || "?").replace(/([a-z])([A-Z])/g, "$1 $2").split(/[\s_\-.]+/).filter(Boolean);
    if (words.length >= 2) return (words[0][0] + words[1][0]).toUpperCase();
    const w = words[0] || "?";
    return w.slice(0, 2).toUpperCase();
  }
  function avatar(p) {
    const lamp = projectLamp(p);
    const a = el("span", "avatar");
    a.style.background = AVATAR_COLORS[hashStr(p.id) % AVATAR_COLORS.length];
    a.appendChild(el("span", "av-mono", monogram(p.name)));
    a.appendChild(el("i", "lamp av-lamp " + lamp));
    const n = state.tabs.filter((t) => t.projectId === p.id && t.running).length;
    if (n > 1) a.appendChild(el("span", "av-count", String(n)));
    a.setAttribute("aria-hidden", "true");
    return a;
  }
  function lampWord(lamp) { return lamp === "missing" ? "Folder missing" : (lamp === "none" ? "No open session" : stateLabel[lamp]); }

  function activeProjectId() { const t = activeTab(); return t ? t.projectId : null; }

  function renderProjects() {
    const list = $("projectList");
    const hadFocus = list.contains(document.activeElement) ? document.activeElement.closest(".project") : null;
    const focusId = hadFocus ? hadFocus.dataset.id : null;
    list.textContent = "";
    hideTip();
    if (!state.projects.length) {
      const li = el("li", "rail-empty");
      li.appendChild(el("p", "", "Register a project folder to start Claude Code sessions in it."));
      const b = el("button", "btn primary", "Add your first project");
      b.addEventListener("click", openAddProject);
      li.appendChild(b);
      list.appendChild(li);
      return;
    }
    const q = state.filter.trim();
    const pinned = pinnedProjects().filter((p) => matchesFilter(p, q));
    const rest = sortedProjects().filter((p) => !p.pinned && matchesFilter(p, q));
    const groups = sortedGroups();
    if (!pinned.length && !rest.length && !groups.length) {
      list.appendChild(el("li", "rail-empty", "No project matches \"" + q + "\"."));
      return;
    }
    const section = (label) => { const li = el("li", "rail-sec", label); li.setAttribute("role", "presentation"); list.appendChild(li); return li; };
    if (pinned.length) {
      wirePinDrop(section("Pinned"));
      for (const p of pinned) list.appendChild(projectRow(p, true));
    }
    for (const g of groups) {
      const members = manualOrder(rest.filter((p) => groupOf(p) === g.id));
      if (q && !members.length) continue;
      list.appendChild(groupHead(g, members.length));
      if (!g.collapsed || q) for (const p of members) list.appendChild(projectRow(p, true));
    }
    const loose = manualOrder(rest.filter((p) => !groupOf(p)));
    if (loose.length && (pinned.length || groups.length)) {
      const h = section(groups.length ? "Ungrouped" : "Projects");
      if (groups.length) wireGroupDrop(h, "");
    }
    for (const p of loose) list.appendChild(projectRow(p, true));
    if (!list.querySelector(".project") && q) list.appendChild(el("li", "rail-empty", "No project matches \"" + q + "\"."));
    if (focusId) { const b = list.querySelector('.project[data-id="' + focusId + '"] .pmain'); if (b) b.focus(); }
  }

  const ICON_CHEV = "M6 4l4 4-4 4";
  function groupHead(g, count) {
    const li = el("li", "group-head" + (g.collapsed ? " closed" : ""));
    li.dataset.group = g.id;
    const b = el("button", "ghead");
    b.setAttribute("aria-expanded", g.collapsed ? "false" : "true");
    b.setAttribute("aria-haspopup", "menu");
    b.appendChild(icon(ICON_CHEV));
    b.appendChild(el("span", "gname", g.name));
    b.appendChild(el("span", "gcount", String(count)));
    const lamp = groupLamp(g.id);
    const l = el("i", "lamp glamp " + lamp);
    b.appendChild(l);
    b.setAttribute("aria-label", g.name + ", " + count + (count === 1 ? " project" : " projects") + ", " + lampWord(lamp) + (g.collapsed ? ", collapsed" : ""));
    b.addEventListener("click", () => toggleGroup(g));
    b.addEventListener("mouseenter", () => showGroupTip(g, count, li));
    b.addEventListener("mouseleave", hideTip);
    b.addEventListener("focus", () => showGroupTip(g, count, li));
    b.addEventListener("blur", hideTip);
    li.appendChild(b);
    li.addEventListener("contextmenu", (ev) => { ev.preventDefault(); openGroupCtx(g, ev.clientX, ev.clientY, b); });
    wireGroupDrop(li, g.id);
    li.draggable = true;
    li.addEventListener("dragstart", (ev) => { dragGroupId = g.id; li.classList.add("dragging"); ev.dataTransfer.effectAllowed = "move"; try { ev.dataTransfer.setData("text/plain", g.id); } catch (e) {} hideTip(); });
    li.addEventListener("dragend", () => { dragGroupId = null; li.classList.remove("dragging"); clearDrop(); });
    return li;
  }
  let dragGroupId = null;
  function wireGroupDrop(li, gid) {
    const groupTarget = () => dragGroupId && gid && dragGroupId !== gid;
    li.addEventListener("dragover", (ev) => {
      if (groupTarget()) {
        ev.preventDefault();
        const r = li.getBoundingClientRect();
        clearDrop();
        li.classList.add(ev.clientY < r.top + r.height / 2 ? "drop-before" : "drop-after");
        return;
      }
      if (!dragId) return;
      ev.preventDefault(); clearDrop(); li.classList.add("drop-into");
      const g = groupById(gid);
      if (g) armHoverOpen(g);
    });
    li.addEventListener("dragleave", () => { li.classList.remove("drop-into", "drop-before", "drop-after"); disarmHoverOpen(); });
    li.addEventListener("drop", (ev) => {
      if (groupTarget()) {
        ev.preventDefault();
        const before = li.classList.contains("drop-before");
        const moved = groupById(dragGroupId);
        clearDrop();
        const gs = sortedGroups().filter((x) => x !== moved);
        let at = gs.indexOf(groupById(gid));
        if (!before) at++;
        gs.splice(at, 0, moved);
        reorderGroups(gs);
        return;
      }
      if (!dragId) return;
      ev.preventDefault();
      const p = projectById(dragId);
      clearDrop();
      if (p) moveToGroup(p, gid);
    });
  }
  // Drop target shown only while a project is dragged: creates a group around it.
  function newGroupJack() {
    const li = el("li", "new-jack");
    li.appendChild(el("i", "lamp"));
    li.appendChild(el("span", "", "Drop here to start a new group"));
    li.addEventListener("dragover", (ev) => { ev.preventDefault(); clearDrop(); li.classList.add("drop-into"); });
    li.addEventListener("dragleave", () => li.classList.remove("drop-into"));
    li.addEventListener("drop", (ev) => {
      ev.preventDefault();
      const p = projectById(dragId);
      clearDrop();
      if (p) newGroup((g) => moveToGroup(p, g.id));
    });
    return li;
  }
  // Hovering a collapsed group while dragging opens it, so items can land between its projects.
  let hoverOpen = null;
  function armHoverOpen(g) {
    if (hoverOpen && hoverOpen.g === g) return;
    disarmHoverOpen();
    if (!g.collapsed) return;
    // Rows are inserted in place: a full re-render would drop the dragged node and end the drag.
    hoverOpen = { g, t: setTimeout(() => {
      hoverOpen = null; g.collapsed = false;
      const head = $("projectList").querySelector('.group-head[data-group="' + g.id + '"]');
      if (head) {
        head.classList.remove("closed");
        let at = head;
        for (const p of manualOrder(state.projects.filter((x) => !x.pinned && groupOf(x) === g.id))) { const r = projectRow(p, true); at.after(r); at = r; }
      }
      api("PUT", "/api/groups/" + encodeURIComponent(g.id), { collapsed: false }).catch(() => {}); }, 600) };
  }
  function disarmHoverOpen() { if (hoverOpen) { clearTimeout(hoverOpen.t); hoverOpen = null; } }
  function wirePinDrop(li) {
    li.addEventListener("dragover", (ev) => { if (!dragId) return; ev.preventDefault(); clearDrop(); li.classList.add("drop-into"); });
    li.addEventListener("dragleave", () => li.classList.remove("drop-into"));
    li.addEventListener("drop", (ev) => {
      if (!dragId) return;
      ev.preventDefault();
      const p = projectById(dragId);
      clearDrop();
      if (p && !p.pinned) togglePin(p);
    });
  }
  async function reorderGroups(gs) {
    gs.forEach((x, k) => { x.order = k + 1; });
    renderProjects();
    try { for (const x of gs) await api("PUT", "/api/groups/" + encodeURIComponent(x.id), { order: x.order }); } catch (e) { fail(e); refreshProjects(); }
  }
  function showGroupTip(g, count, anchor) {
    if (!$("app").classList.contains("rail-collapsed") || narrow() || dragId) return;
    tip.textContent = "";
    tip.appendChild(el("span", "tip-name", g.name));
    tip.appendChild(el("span", "tip-meta", count + (count === 1 ? " project, " : " projects, ") + lampWord(groupLamp(g.id)) + (g.collapsed ? ", collapsed" : "")));
    placeTip(anchor);
  }
  async function toggleGroup(g) {
    g.collapsed = !g.collapsed;
    renderProjects();
    const b = $("projectList").querySelector('.group-head[data-group="' + g.id + '"] .ghead');
    if (b) b.focus();
    try { await api("PUT", "/api/groups/" + encodeURIComponent(g.id), { collapsed: g.collapsed }); } catch (e) { fail(e); refreshProjects(); }
  }
  async function moveToGroup(p, gid) {
    if (groupOf(p) === gid && !p.pinned) return;
    try {
      const v = await api("PUT", "/api/projects/" + encodeURIComponent(p.id), { groupId: gid, pinned: false });
      Object.assign(p, { groupId: v.groupId, pinned: v.pinned });
      renderProjects();
      const g = groupById(gid);
      toast(g ? "Moved " + p.name + " to " + g.name + "." : "Moved " + p.name + " out of its group.");
    } catch (e) { fail(e); if (e.data && e.data.error === "group_not_found") refreshProjects(); }
  }
  let groupDialogDone = null;
  function askGroupName(title, value, done) {
    $("groupTitle").textContent = title;
    $("groupSubmit").textContent = value ? "Rename" : "Create group";
    $("groupName").value = value || "";
    $("groupError").textContent = "";
    groupDialogDone = done;
    $("groupDialog").showModal();
    $("groupName").select();
  }
  $("groupCancel").addEventListener("click", () => $("groupDialog").close());
  $("groupForm").addEventListener("submit", async (ev) => {
    ev.preventDefault();
    const name = $("groupName").value.trim();
    if (!name) { $("groupError").textContent = "Enter a name."; return; }
    try { if (groupDialogDone) await groupDialogDone(name); $("groupDialog").close(); }
    catch (e) { if (!(e instanceof AuthError)) $("groupError").textContent = describe(e); }
  });
  function newGroup(then) {
    askGroupName("New group", "", async (name) => {
      const g = await api("POST", "/api/groups", { name });
      state.groups.push(g);
      if (then) await then(g); else renderProjects();
      toast("Created group " + g.name + ".");
    });
  }
  function renameGroup(g) {
    askGroupName("Rename group", g.name, async (name) => {
      if (name === g.name) return;
      const v = await api("PUT", "/api/groups/" + encodeURIComponent(g.id), { name });
      g.name = v.name;
      renderProjects();
    });
  }
  async function deleteGroup(g) {
    const n = groupMembers(g.id).length;
    if (!confirm('Delete the group "' + g.name + '"?' + (n ? " Its " + n + (n === 1 ? " project moves" : " projects move") + " to Ungrouped and stay in the list." : ""))) return;
    try { await api("DELETE", "/api/groups/" + encodeURIComponent(g.id)); await refreshProjects(); toast("Deleted group " + g.name + "."); } catch (e) { fail(e); }
  }
  async function restoreGroup(g) {
    const todo = groupMembers(g.id).filter((p) => p.exists && !state.tabs.some((t) => t.projectId === p.id && t.running));
    if (!todo.length) { toast("Every project in " + g.name + " already has a running tab."); return; }
    let skipped = 0;
    for (const p of todo) {
      if (p.lastSessionActive) { skipped++; continue; }
      await openTab(defaultStart(p));
    }
    if (skipped) toast("Opened " + (todo.length - skipped) + " of " + todo.length + ". " + skipped + " skipped because their last session looks active elsewhere.", true);
  }
  async function saveGroup(g) {
    const ids = new Set(groupMembers(g.id).map((p) => p.id));
    const tabs = state.tabs.filter((t) => ids.has(t.projectId) && t.running && isClaude(t) && t.state === "running");
    if (!tabs.length) { toast("No idle Claude session in " + g.name + "."); return; }
    let ok = 0;
    for (const t of tabs) {
      try { const info = await api("POST", "/api/tabs/" + encodeURIComponent(t.id) + "/save"); if (info && info.id) setTab(info); ok++; } catch (e) { if (e instanceof AuthError) return; }
    }
    toast("Running mxSave in " + ok + " of " + tabs.length + " sessions in " + g.name + ".", ok < tabs.length);
  }
  function openGroupCtx(g, x, y, returnTo) {
    hideTip();
    const gs = sortedGroups();
    const i = gs.indexOf(g);
    showMenu([
      { label: g.collapsed ? "Expand" : "Collapse", fn: () => toggleGroup(g) },
      { label: "Restore all in group", fn: () => restoreGroup(g) },
      { label: "mxSave all in group", fn: () => saveGroup(g) },
      "sep",
      { label: "Move up", fn: () => moveGroup(g, -1), disabled: i <= 0 },
      { label: "Move down", fn: () => moveGroup(g, 1), disabled: i >= gs.length - 1 },
      { label: "Rename", fn: () => renameGroup(g) },
      "sep",
      { label: "Delete group", fn: () => deleteGroup(g), cls: "danger" }
    ], x, y, returnTo);
  }
  async function moveGroup(g, dir) {
    const gs = sortedGroups();
    const i = gs.indexOf(g), j = i + dir;
    if (j < 0 || j >= gs.length) return;
    gs.splice(i, 1); gs.splice(j, 0, g);
    reorderGroups(gs);
  }
  function openMoveMenu(p, x, y, returnTo) {
    const cur = groupOf(p);
    const items = sortedGroups().map((g) => ({ label: (g.id === cur ? "In " : "") + g.name, fn: () => moveToGroup(p, g.id), disabled: g.id === cur }));
    if (items.length) items.push({ label: "Ungrouped", fn: () => moveToGroup(p, ""), disabled: !cur }, "sep");
    items.push({ label: "New group", fn: () => newGroup((g) => moveToGroup(p, g.id)) });
    showMenu(items, x, y, returnTo);
  }

  const ICON_MORE = "M2.8 8a1.2 1.2 0 1 0 2.4 0a1.2 1.2 0 1 0-2.4 0M6.8 8a1.2 1.2 0 1 0 2.4 0a1.2 1.2 0 1 0-2.4 0M10.8 8a1.2 1.2 0 1 0 2.4 0a1.2 1.2 0 1 0-2.4 0";

  function projectRow(p, draggable) {
    const lamp = projectLamp(p);
    const li = el("li", "project" + (p.exists ? "" : " missing") + (state.tabs.some((t) => t.projectId === p.id) ? " has-tab" : "") + (activeProjectId() === p.id ? " current" : "") + (p.pinned ? " pinned" : "") + (!p.pinned && groupOf(p) ? " in-group" : ""));
    li.dataset.id = p.id;
    const av = avatar(p);
    li.appendChild(av);
    li.appendChild(el("i", "lamp plamp " + lamp));
    const main = el("button", "pmain");
    main.appendChild(el("span", "pname", p.name));
    main.setAttribute("aria-label", p.name + ", " + lampWord(lamp) + ". " + defaultActionTitle(p));
    main.setAttribute("aria-haspopup", "menu");
    if (activeProjectId() === p.id) main.setAttribute("aria-current", "true");
    main.addEventListener("click", () => { openDefault(p); closeDrawer(); });
    main.addEventListener("mouseenter", () => showTip(p, main));
    main.addEventListener("mouseleave", hideTip);
    main.addEventListener("focus", () => showTip(p, main));
    main.addEventListener("blur", hideTip);
    li.appendChild(main);
    av.addEventListener("click", () => main.click());
    li.addEventListener("contextmenu", (ev) => { ev.preventDefault(); openProjectCtx(p, ev.clientX, ev.clientY, main); });
    const more = el("button", "mini pmore");
    more.title = "Options and details"; more.setAttribute("aria-label", "Options and details for " + p.name);
    more.setAttribute("aria-haspopup", "menu");
    more.appendChild(icon(ICON_MORE));
    more.addEventListener("click", (ev) => { ev.stopPropagation(); const r = more.getBoundingClientRect(); openProjectCtx(p, r.left, r.bottom + 2, more); });
    li.appendChild(more);
    if (draggable) wireDrag(li, p);
    return li;
  }

  function defaultActionTitle(p) {
    if (state.tabs.some((t) => t.projectId === p.id)) return "Switch to the open tab";
    if (!p.exists) return "Folder not found";
    if (p.lastSessionActive) return "The last session looks active elsewhere";
    return defaultMode(p) === "resume" ? "Resume the last session" : "Start a new session in this folder";
  }

  // A session ended with /clear or exit starts fresh; a crash resumes the last session.
  function defaultMode(p) {
    return p.lastSessionId && !p.cleanEnd ? "resume" : "new";
  }

  function defaultStart(p) {
    return defaultMode(p) === "resume" ? { projectId: p.id, mode: "resume", sessionId: p.lastSessionId } : { projectId: p.id, mode: "new" };
  }

  function openDefault(p) {
    const open = state.tabs.find((t) => t.projectId === p.id);
    if (open) { activate(open.id); return; }
    if (!p.exists) { toast("The folder " + p.path + " was not found. Reconnect the drive or remove the project.", true); return; }
    if (p.lastSessionActive) { toast("The last session in " + p.name + " was active less than a minute ago, probably in another window. Use Continue or New to avoid two clients on one session.", true); return; }
    openTab(defaultStart(p));
  }

  const tip = $("railTip");
  function showTip(p, anchor) {
    if (!$("app").classList.contains("rail-collapsed") || narrow() || dragId) return;
    tip.textContent = "";
    tip.appendChild(el("span", "tip-name", p.name));
    tip.appendChild(el("span", "tip-path", p.path));
    tip.appendChild(el("span", "tip-meta", lampWord(projectLamp(p)) + (p.lastSessionAt ? ", last used " + relTime(p.lastSessionAt) : ", not used yet")));
    placeTip(anchor);
  }
  function placeTip(anchor) {
    tip.classList.remove("hidden");
    const r = anchor.getBoundingClientRect();
    const h = tip.getBoundingClientRect().height;
    tip.style.left = (r.right + 10) + "px";
    tip.style.top = Math.max(4, Math.min(r.top + r.height / 2 - h / 2, innerHeight - h - 4)) + "px";
  }
  function hideTip() { tip.classList.add("hidden"); }

  async function togglePin(p) {
    const body = { pinned: !p.pinned };
    if (!p.pinned) body.order = pinnedProjects().reduce((m, x) => Math.max(m, x.order || 0), 0) + 1;
    try {
      const v = await api("PUT", "/api/projects/" + encodeURIComponent(p.id), body);
      Object.assign(p, { pinned: v.pinned, order: v.order });
      renderProjects();
      toast((v.pinned ? "Pinned " : "Unpinned ") + p.name + ".");
    } catch (e) { fail(e); }
  }

  let dragId = null;
  function wireDrag(li, p) {
    li.draggable = true;
    li.addEventListener("dragstart", (ev) => {
      dragId = p.id; li.classList.add("dragging"); ev.dataTransfer.effectAllowed = "move";
      try { ev.dataTransfer.setData("text/plain", p.id); } catch (e) {}
      hideTip();
      setTimeout(() => { if (dragId) $("projectList").appendChild(newGroupJack()); }, 0);
    });
    li.addEventListener("dragend", () => {
      dragId = null; li.classList.remove("dragging"); clearDrop(); disarmHoverOpen();
      for (const n of $("projectList").querySelectorAll(".new-jack")) n.remove();
    });
    li.addEventListener("dragover", (ev) => {
      if (!dragId || dragId === p.id) return;
      ev.preventDefault();
      ev.stopPropagation();
      const r = li.getBoundingClientRect();
      clearDrop();
      li.classList.add(ev.clientY < r.top + r.height / 2 ? "drop-before" : "drop-after");
    });
    li.addEventListener("dragleave", () => li.classList.remove("drop-before", "drop-after"));
    li.addEventListener("drop", (ev) => {
      if (!dragId || dragId === p.id) return;
      ev.preventDefault();
      const before = li.classList.contains("drop-before");
      const m = projectById(dragId);
      clearDrop();
      if (m) dropBeside(m, p, before);
    });
  }
  // Projects in one rail section, in display order: pinned, a group, or ungrouped.
  function sectionOf(p) {
    if (p.pinned) return pinnedProjects();
    const gid = groupOf(p);
    return manualOrder(state.projects.filter((x) => !x.pinned && groupOf(x) === gid));
  }
  // Manually placed projects first (by order), never placed ones after them by last use.
  function manualOrder(list) {
    const recent = sortedProjects();
    return list.slice().sort((a, b) => ((a.order || 1e9) - (b.order || 1e9)) || (recent.indexOf(a) - recent.indexOf(b)));
  }
  // Drop project m next to target t: join t's section (pin state and group), then reorder it.
  async function dropBeside(m, t, before) {
    if (m.pinned !== t.pinned || (!t.pinned && groupOf(m) !== groupOf(t))) {
      const body = t.pinned ? { pinned: true } : { pinned: false, groupId: groupOf(t) };
      try {
        const v = await api("PUT", "/api/projects/" + encodeURIComponent(m.id), body);
        Object.assign(m, { pinned: v.pinned, groupId: v.groupId });
      } catch (e) { fail(e); refreshProjects(); return; }
    }
    const ids = sectionOf(t).map((x) => x.id).filter((id) => id !== m.id);
    let at = ids.indexOf(t.id);
    if (!before) at++;
    ids.splice(at, 0, m.id);
    reorderSection(ids);
  }
  // A drop re-renders the rail, which can remove the source row before its dragend fires.
  document.addEventListener("drop", () => setTimeout(endDrag, 0));
  function endDrag() {
    dragId = null; dragGroupId = null; disarmHoverOpen(); clearDrop();
    for (const n of $("projectList").querySelectorAll(".new-jack")) n.remove();
  }
  function clearDrop() { for (const n of $("projectList").querySelectorAll(".drop-before, .drop-after, .drop-into")) n.classList.remove("drop-before", "drop-after", "drop-into"); }
  async function reorderSection(ids) {
    ids.forEach((id, i) => { const p = projectById(id); if (p) p.order = i + 1; });
    renderProjects();
    try { await api("POST", "/api/projects/reorder", { ids }); } catch (e) { fail(e); refreshProjects(); }
  }
  function movePinned(p, dir) {
    const ids = pinnedProjects().map((x) => x.id);
    const i = ids.indexOf(p.id), j = i + dir;
    if (i < 0 || j < 0 || j >= ids.length) return;
    ids.splice(i, 1); ids.splice(j, 0, p.id);
    reorderSection(ids);
  }

  async function copyPath(p) {
    try { await navigator.clipboard.writeText(p.path); toast("Copied " + p.path + "."); }
    catch (e) { toast("Copy was blocked by the browser. Path: " + p.path, true); }
  }
  async function openExternal(p, what) {
    try {
      await api("POST", "/api/projects/" + encodeURIComponent(p.id) + "/open-" + what);
      toast(what === "vscode" ? "Opening " + p.name + " in VS Code." : "Opening " + p.name + " in Explorer.");
    } catch (e) { fail(e); }
  }

  function openProjectCtx(p, x, y, returnTo) {
    hideTip();
    const ok = p.exists;
    const items = [
      { info: [p.path, ok ? lampWord(projectLamp(p)) + (p.lastSessionAt ? ", last used " + relTime(p.lastSessionAt) : ", not used yet") : "Folder not found. Reconnect the drive or remove this entry."] },
      "sep",
      { label: "Resume last session", fn: () => openTab({ projectId: p.id, mode: "resume", sessionId: p.lastSessionId }), disabled: !ok || !p.lastSessionId },
      { label: "Continue", fn: () => openTab({ projectId: p.id, mode: "continue" }), disabled: !ok },
      { label: "New session", fn: () => openTab({ projectId: p.id, mode: "new" }), disabled: !ok },
      { label: "Shell", fn: () => openTab({ projectId: p.id, mode: "shell" }), disabled: !ok },
      "sep",
      { label: p.pinned ? "Unpin" : "Pin to top", fn: () => togglePin(p) }
    ];
    if (p.pinned) {
      const ids = pinnedProjects().map((q) => q.id);
      items.push({ label: "Move up", fn: () => movePinned(p, -1), disabled: ids[0] === p.id });
      items.push({ label: "Move down", fn: () => movePinned(p, 1), disabled: ids[ids.length - 1] === p.id });
    }
    items.push({ label: "Move to group", fn: () => setTimeout(() => openMoveMenu(p, x, y, returnTo), 0), sub: true });
    items.push({ label: "Rename", fn: () => renameProject(p) });
    items.push("sep");
    items.push({ label: "Open in Explorer", fn: () => openExternal(p, "explorer"), disabled: !ok });
    items.push({ label: "Open in VS Code", fn: () => openExternal(p, "vscode"), disabled: !ok });
    items.push({ label: "Copy path", fn: () => copyPath(p) });
    items.push("sep");
    items.push({ label: "Remove from list", fn: () => removeProject(p), cls: "danger" });
    showMenu(items, x, y, returnTo);
  }

  function railButtons() { return Array.from($("projectList").querySelectorAll(".project .pmain, .group-head .ghead")); }
  function focusRail() {
    if (narrow()) openDrawer();
    const bs = railButtons();
    if (!bs.length) { $("projectFilter").focus(); return; }
    const cur = $("projectList").querySelector(".project.current .pmain") || $("projectList").querySelector(".project .pmain");
    (cur || bs[0]).focus();
  }
  $("projectList").addEventListener("keydown", (ev) => {
    const b = document.activeElement;
    if (!b || !(b.classList.contains("pmain") || b.classList.contains("ghead"))) return;
    const bs = railButtons();
    const i = bs.indexOf(b);
    const row = b.closest(".project");
    const p = row ? projectById(row.dataset.id) : null;
    const g = row ? null : groupById(b.closest(".group-head").dataset.group);
    if (g && (ev.key === "ArrowLeft" || ev.key === "ArrowRight")) {
      ev.preventDefault();
      if ((ev.key === "ArrowLeft") !== !!g.collapsed) toggleGroup(g);
      return;
    }
    if (ev.key === "ArrowDown" || ev.key === "ArrowUp") {
      ev.preventDefault();
      if (ev.altKey && p && p.pinned) { movePinned(p, ev.key === "ArrowDown" ? 1 : -1); return; }
      const n = bs[(i + (ev.key === "ArrowDown" ? 1 : -1) + bs.length) % bs.length];
      if (n) n.focus();
    } else if (ev.key === "Home" || ev.key === "End") {
      ev.preventDefault();
      bs[ev.key === "Home" ? 0 : bs.length - 1].focus();
    } else if (ev.key === "ContextMenu" || (ev.key === "F10" && ev.shiftKey)) {
      ev.preventDefault();
      const r = b.getBoundingClientRect();
      if (p) openProjectCtx(p, r.left + 24, r.bottom - 4, b);
      else if (g) openGroupCtx(g, r.left + 24, r.bottom - 4, b);
    } else if (ev.key === "Escape") {
      ev.preventDefault();
      closeDrawer();
      const v = state.views.get(state.active); if (v) v.term.focus();
    }
  });

  const narrowMq = matchMedia("(max-width: 860px)");
  function narrow() { return narrowMq.matches; }
  function lsGet(k) { try { return localStorage.getItem(k); } catch (e) { return null; } }
  function lsSet(k, v) { try { localStorage.setItem(k, v); } catch (e) {} }
  const RAIL_MIN = 200, RAIL_MAX = 420, RAIL_DEFAULT = 280;
  function setRailWidth(w, persist) {
    w = Math.round(Math.max(RAIL_MIN, Math.min(RAIL_MAX, w)));
    $("app").style.setProperty("--rail-w", w + "px");
    $("railResize").setAttribute("aria-valuenow", String(w));
    if (persist) lsSet("mxo.rail.width", String(w));
    return w;
  }
  function setCollapsed(on) {
    $("app").classList.toggle("rail-collapsed", on);
    const t = $("railToggle");
    t.setAttribute("aria-label", on ? "Expand project list" : "Collapse project list");
    t.title = (on ? "Expand" : "Collapse") + " (Ctrl+B)";
    t.setAttribute("aria-expanded", on ? "false" : "true");
    lsSet("mxo.rail.collapsed", on ? "1" : "0");
    hideTip();
  }
  function toggleRail() {
    if (narrow()) { if ($("app").classList.contains("drawer-open")) closeDrawer(); else openDrawer(); return; }
    setCollapsed(!$("app").classList.contains("rail-collapsed"));
  }
  function openDrawer() {
    $("app").classList.add("drawer-open");
    $("railMenuBtn").setAttribute("aria-expanded", "true");
    const b = railButtons()[0];
    if (b && !$("rail").contains(document.activeElement)) b.focus();
  }
  function closeDrawer() {
    if (!$("app").classList.contains("drawer-open")) return;
    $("app").classList.remove("drawer-open");
    $("railMenuBtn").setAttribute("aria-expanded", "false");
  }
  {
    const w = parseInt(lsGet("mxo.rail.width"), 10);
    setRailWidth(isNaN(w) ? RAIL_DEFAULT : w, false);
    setCollapsed(lsGet("mxo.rail.collapsed") === "1");
  }
  $("railToggle").addEventListener("click", () => { if (narrow()) closeDrawer(); else toggleRail(); });
  $("railMenuBtn").addEventListener("click", openDrawer);
  $("railScrim").addEventListener("click", closeDrawer);
  narrowMq.addEventListener("change", (ev) => { if (!ev.matches) closeDrawer(); hideTip(); });
  {
    const h = $("railResize");
    let startX = 0, startW = 0, dragging = false;
    h.addEventListener("pointerdown", (ev) => {
      if (ev.button !== 0) return;
      dragging = true; startX = ev.clientX; startW = $("rail").getBoundingClientRect().width;
      h.setPointerCapture(ev.pointerId);
      $("app").classList.add("resizing");
      ev.preventDefault();
    });
    h.addEventListener("pointermove", (ev) => { if (dragging) setRailWidth(startW + ev.clientX - startX, false); });
    const end = () => {
      if (!dragging) return;
      dragging = false;
      $("app").classList.remove("resizing");
      setRailWidth($("rail").getBoundingClientRect().width, true);
    };
    h.addEventListener("pointerup", end);
    h.addEventListener("pointercancel", end);
    h.addEventListener("dblclick", () => setRailWidth(RAIL_DEFAULT, true));
    h.addEventListener("keydown", (ev) => {
      const cur = $("rail").getBoundingClientRect().width;
      if (ev.key === "ArrowLeft") { ev.preventDefault(); setRailWidth(cur - 16, true); }
      else if (ev.key === "ArrowRight") { ev.preventDefault(); setRailWidth(cur + 16, true); }
      else if (ev.key === "Enter" || ev.key === "Home") { ev.preventDefault(); setRailWidth(RAIL_DEFAULT, true); }
    });
  }

  $("projectFilter").addEventListener("input", (ev) => { state.filter = ev.target.value; renderProjects(); });
  $("projectFilter").addEventListener("keydown", (ev) => {
    if (ev.key === "Escape") { ev.target.value = ""; state.filter = ""; renderProjects(); }
    if (ev.key === "ArrowDown") { const b = railButtons()[0]; if (b) { ev.preventDefault(); b.focus(); } }
    if (ev.key === "Enter") {
      const p = railProjects().filter((x) => matchesFilter(x, state.filter.trim()))[0];
      if (p) openDefault(p);
    }
  });

  async function removeProject(p) {
    if (!confirm('Remove "' + p.name + '" from the list? The folder and its files stay on disk.')) return;
    try { await api("DELETE", "/api/projects/" + encodeURIComponent(p.id)); await refreshAll(); toast("Removed " + p.name + " from the list."); } catch (e) { fail(e); }
  }

  let renameTarget = null;
  function renameProject(p) {
    renameTarget = p;
    $("renameName").value = p.name;
    $("renameError").textContent = "";
    $("renameDialog").showModal();
    $("renameName").select();
  }
  $("renameCancel").addEventListener("click", () => $("renameDialog").close());
  $("renameForm").addEventListener("submit", async (ev) => {
    ev.preventDefault();
    const name = $("renameName").value.trim();
    if (!renameTarget) return;
    if (!name) { $("renameError").textContent = "Enter a name."; return; }
    if (name === renameTarget.name) { $("renameDialog").close(); return; }
    try {
      await api("PUT", "/api/projects/" + encodeURIComponent(renameTarget.id), { name });
      $("renameDialog").close();
      await refreshAll();
    } catch (e) { if (!(e instanceof AuthError)) $("renameError").textContent = describe(e); }
  });

  const dlg = $("projectDialog");
  function openAddProject() {
    $("projectForm").reset();
    $("projName").dataset.auto = "1";
    $("projError").textContent = "";
    const sel = $("projGroup");
    sel.textContent = "";
    const none = el("option", "", "No group"); none.value = ""; sel.appendChild(none);
    for (const g of sortedGroups()) { const o = el("option", "", g.name); o.value = g.id; sel.appendChild(o); }
    $("projGroupRow").classList.toggle("hidden", !state.groups.length);
    $("fsPanel").classList.add("hidden");
    $("projBrowse").setAttribute("aria-expanded", "false");
    dlg.showModal();
    $("projPath").focus();
  }
  $("addProjectBtn").addEventListener("click", openAddProject);
  $("projCancel").addEventListener("click", () => dlg.close());
  $("projPath").addEventListener("input", () => {
    const n = $("projName");
    if (!n.value || n.dataset.auto === "1") {
      const parts = $("projPath").value.split(/[\\/]/).filter(Boolean);
      n.value = parts.length ? parts[parts.length - 1] : "";
      n.dataset.auto = "1";
    }
  });
  $("projName").addEventListener("input", () => { $("projName").dataset.auto = "0"; });

  // Folder browser: the server lists folders (a browser file picker never reveals full paths).
  function setPath(p) {
    $("projPath").value = p;
    $("projPath").dispatchEvent(new Event("input"));
  }
  async function browse(path, focusList) {
    let res;
    try { res = await api("GET", "/api/fs?path=" + encodeURIComponent(path || "")); }
    catch (e) { if (!(e instanceof AuthError)) $("projError").textContent = path ? "The folder " + path + " cannot be opened." : describe(e); return; }
    $("projError").textContent = "";
    const crumbs = $("fsCrumbs");
    crumbs.textContent = "";
    const crumb = (label, p, current) => {
      const b = el("button", "fs-crumb", label);
      b.type = "button";
      if (current) b.setAttribute("aria-current", "location");
      b.addEventListener("click", () => browse(p, true));
      crumbs.appendChild(b);
    };
    crumb("This PC", "", !res.path);
    if (res.path) {
      const parts = res.path.split("\\").filter(Boolean);
      let acc = "";
      parts.forEach((part, i) => { acc += part + "\\"; crumb(part, acc, i === parts.length - 1); });
      setPath(res.path);
    }
    const list = $("fsList");
    list.textContent = "";
    if (!res.dirs.length) list.appendChild(el("li", "fs-empty", "No sub-folders. Use this folder, or type a new name after the path and tick Create."));
    for (const d of res.dirs) {
      const li = el("li");
      const b = el("button", "fs-item");
      b.type = "button";
      b.appendChild(el("i", "lamp " + (d.project ? "running" : "none")));
      b.appendChild(el("span", "", d.name));
      b.title = d.path;
      b.addEventListener("click", () => browse(d.path, true));
      li.appendChild(b);
      list.appendChild(li);
    }
    if (res.more) list.appendChild(el("li", "fs-empty", "Only the first 1000 folders are shown. Type the path instead."));
    list.scrollTop = 0;
    if (focusList) { const f = list.querySelector(".fs-item") || crumbs.lastChild; if (f) f.focus(); }
  }
  $("projBrowse").addEventListener("click", () => {
    const panel = $("fsPanel");
    const open = panel.classList.toggle("hidden") === false;
    $("projBrowse").setAttribute("aria-expanded", open ? "true" : "false");
    if (open) browse($("projPath").value.trim(), true);
  });
  $("projectForm").addEventListener("submit", async (ev) => {
    ev.preventDefault();
    $("projError").textContent = "";
    try {
      const p = await api("POST", "/api/projects", { name: $("projName").value.trim(), path: $("projPath").value.trim(), create: $("projCreate").checked, groupId: $("projGroup").value });
      dlg.close();
      await refreshAll();
      toast("Added " + ((p && p.name) || "project") + ".");
    } catch (e) {
      if (!(e instanceof AuthError)) $("projError").textContent = describe(e);
    }
  });

  async function openTab(req) {
    try {
      const tab = await api("POST", "/api/tabs", req);
      // The server answers with the already running tab when the session is open in one.
      if (!state.tabs.some((t) => t.id === tab.id)) {
        state.tabs.push(tab);
        ensureView(tab);
      }
      renderTabs();
      activate(tab.id);
      renderProjects();
    } catch (e) {
      fail(e);
      if (e.data && (e.data.error === "project_not_found" || e.data.error === "path_not_found")) refreshProjects();
    }
  }

  async function restoreWorkspace() {
    try {
      const res = await api("POST", "/api/workspace/restore");
      const tabs = await api("GET", "/api/tabs");
      syncTabs(tabs || []);
      const openedList = res && Array.isArray(res.opened) ? res.opened : [];
      const skipped = res && Array.isArray(res.skipped) ? res.skipped.length : 0;
      let msg = openedList.length ? "Restored " + openedList.length + (openedList.length === 1 ? " tab." : " tabs.") : "Nothing to restore. Your saved workspace is empty or already open.";
      if (skipped) msg += " Skipped " + skipped + " that were already open or whose project is gone.";
      toast(msg);
      const last = openedList.length ? openedList[openedList.length - 1] : null;
      if (last && last.id) activate(last.id);
      renderProjects();
    } catch (e) { fail(e); }
  }
  $("emptyRestoreBtn").addEventListener("click", restoreWorkspace);

  function syncTabs(tabs) {
    const ids = new Set(tabs.map((t) => t.id));
    for (const [id, v] of state.views) {
      if (!ids.has(id)) { disposeView(v); state.views.delete(id); }
    }
    const before = state.tabs.map((t) => t.id + lampOf(t)).join();
    state.tabs = tabs;
    for (const t of tabs) {
      const v = ensureView(t);
      const wasRunning = v.tab.running;
      v.tab = t;
      if (t.running && !wasRunning && !v.ws) connect(v, true);
      updateOverlay(v);
    }
    state.mru = state.mru.filter((id) => ids.has(id));
    if (state.active && !ids.has(state.active)) state.active = state.mru[0] || null;
    if (!state.active && tabs.length) state.active = tabs[0].id;
    renderTabs();
    showActive(false);
    if (before !== tabs.map((t) => t.id + lampOf(t)).join()) renderProjects();
  }

  function tabTitle(t) {
    const p = projectById(t.projectId);
    return t.title || (p ? p.name : "Session");
  }

  const modeLabel = { resume: "resume", continue: "continue", shell: "shell", new: "" };

  function renderTabs() {
    const bar = $("tabBar");
    bar.textContent = "";
    state.tabs.forEach((t, i) => {
      const on = t.id === state.active;
      const b = el("div", "tab" + (on ? " active" : ""));
      b.setAttribute("role", "tab");
      b.setAttribute("aria-selected", on ? "true" : "false");
      b.tabIndex = on ? 0 : -1;
      b.dataset.id = t.id;
      b.appendChild(el("i", "lamp " + lampOf(t)));
      b.appendChild(el("span", "title", tabTitle(t)));
      b.title = tabTitle(t) + (modeLabel[t.mode] ? " (" + modeLabel[t.mode] + ")" : "") + "\n" + stateText(t) + (i < 9 ? "\nAlt+" + (i + 1) : "");
      const x = el("button", "x");
      x.title = "Close tab";
      x.setAttribute("aria-label", "Close " + tabTitle(t));
      x.tabIndex = -1;
      x.appendChild(icon(ICON_X));
      x.addEventListener("click", (ev) => { ev.stopPropagation(); closeTab(t); });
      b.appendChild(x);
      // Activate on pointerdown: the poll re-renders the bar whenever a lamp changes, which can
      // replace this element between mousedown and mouseup and swallow the click.
      b.addEventListener("pointerdown", (ev) => { if (ev.button === 0 && !ev.target.closest(".x")) activate(t.id); });
      b.addEventListener("click", () => { if (state.active !== t.id) activate(t.id); });
      wireTabDrag(b, t);
      b.addEventListener("auxclick", (ev) => { if (ev.button === 1) closeTab(t); });
      b.addEventListener("contextmenu", (ev) => { ev.preventDefault(); openCtx(t, ev.clientX, ev.clientY); });
      b.addEventListener("keydown", (ev) => {
        if (ev.key === "ArrowRight" || ev.key === "ArrowLeft") { ev.preventDefault(); cycle(ev.key === "ArrowRight" ? 1 : -1, true); }
        else if (ev.key === "Delete") closeTab(t);
        else if (ev.key === "ContextMenu" || (ev.shiftKey && ev.key === "F10")) { ev.preventDefault(); const r = b.getBoundingClientRect(); openCtx(t, r.left, r.bottom); }
      });
      bar.appendChild(b);
    });
    $("emptyState").classList.toggle("hidden", state.tabs.length > 0);
    renderStatus();
  }

  let dragTabId = null;
  function wireTabDrag(b, t) {
    b.draggable = true;
    const clear = () => { for (const n of $("tabBar").querySelectorAll(".drop-before, .drop-after")) n.classList.remove("drop-before", "drop-after"); };
    b.addEventListener("dragstart", (ev) => {
      dragTabId = t.id; b.classList.add("dragging"); ev.dataTransfer.effectAllowed = "move";
      try { ev.dataTransfer.setData("text/plain", t.id); } catch (e) {}
      hideTip();
    });
    b.addEventListener("dragend", () => { dragTabId = null; b.classList.remove("dragging"); clear(); });
    b.addEventListener("dragover", (ev) => {
      if (!dragTabId || dragTabId === t.id) return;
      ev.preventDefault();
      const r = b.getBoundingClientRect();
      clear();
      b.classList.add(ev.clientX < r.left + r.width / 2 ? "drop-before" : "drop-after");
    });
    b.addEventListener("dragleave", () => b.classList.remove("drop-before", "drop-after"));
    b.addEventListener("drop", async (ev) => {
      if (!dragTabId || dragTabId === t.id) return;
      ev.preventDefault();
      const id = dragTabId, before = b.classList.contains("drop-before");
      clear();
      const rest = state.tabs.filter((x) => x.id !== id);
      const index = rest.findIndex((x) => x.id === t.id) + (before ? 0 : 1);
      const moved = state.tabs.find((x) => x.id === id);
      state.tabs = [...rest.slice(0, index), moved, ...rest.slice(index)];
      renderTabs();
      try { syncTabs(await api("POST", "/api/tabs/" + encodeURIComponent(id) + "/move", { index })); } catch (e) { fail(e); }
    });
  }

  function activeTab() { return state.tabs.find((t) => t.id === state.active) || null; }

  function renderStatus() {
    const t = activeTab();
    $("statusBar").classList.toggle("hidden", !t);
    if (!t) return;
    const p = projectById(t.projectId);
    const lamp = lampOf(t);
    $("sbLamp").className = "lamp " + lamp;
    $("sbState").textContent = stateText(t);
    $("sbPath").textContent = p ? p.path : "";
    $("sbPath").title = p ? p.path : "";
    $("sbSid").textContent = t.sessionId ? t.sessionId.slice(0, 8) : "";
    $("sbUptime").textContent = t.running && t.startedAt ? "Up " + duration(t.startedAt) : "";
    const idle = t.running && isClaude(t) && (t.state === "running" || !t.state);
    for (const b of $("sbQuick").children) b.disabled = !idle;
  }
  setInterval(() => {
    const t = activeTab();
    if (t && t.running && t.startedAt) $("sbUptime").textContent = "Up " + duration(t.startedAt);
  }, 30000);

  async function copySessionId(t) {
    if (!t || !t.sessionId) { toast("This tab has no Claude session id yet."); return; }
    try { await navigator.clipboard.writeText(t.sessionId); toast("Copied session id " + t.sessionId + "."); }
    catch (e) { toast("Copy was blocked by the browser. Session id: " + t.sessionId, true); }
  }
  $("sbSid").addEventListener("click", () => copySessionId(activeTab()));
  // Phone key row: keys that are hard to reach on a touch keyboard.
  const keySeq = { esc: "\x1b", tab: "\t", up: "\x1b[A", down: "\x1b[B", enter: "\r", newline: "\n", ctrlc: "\x03" };
  for (const b of $("sbKeys").children) {
    b.addEventListener("pointerdown", (ev) => ev.preventDefault()); // keep focus (and the keyboard) on the terminal
    b.addEventListener("click", () => {
      const v = state.views.get(state.active);
      if (v) { send(v, enc.encode(keySeq[b.dataset.key])); v.term.focus(); }
    });
  }
  $("sbMore").addEventListener("click", () => {
    const open = $("statusBar").classList.toggle("sb-open");
    $("sbMore").setAttribute("aria-expanded", String(open));
  });

  function askClose(t) {
    return new Promise((resolve) => {
      const d = $("closeDialog");
      $("closeTitle").textContent = 'Close "' + tabTitle(t) + '"';
      d.returnValue = "cancel";
      d.addEventListener("close", () => resolve(d.returnValue || "cancel"), { once: true });
      d.showModal();
    });
  }

  function setTab(info) {
    const i = state.tabs.findIndex((x) => x.id === info.id);
    if (i >= 0) state.tabs[i] = info;
    const v = state.views.get(info.id);
    if (v) v.tab = info;
    renderTabs();
    renderProjects();
  }

  async function saveOnly(t) {
    try {
      const info = await api("POST", "/api/tabs/" + encodeURIComponent(t.id) + "/save");
      if (info && info.id) setTab(info);
      toast("Running mxSave in " + tabTitle(t) + ". The session stays open.");
    } catch (e) { fail(e); }
  }

  async function saveClose(t) {
    try {
      const info = await api("POST", "/api/tabs/" + encodeURIComponent(t.id) + "/save-close");
      if (info && info.id) setTab(info);
      toast("Saving " + tabTitle(t) + ". The tab closes when the save is done.");
    } catch (e) { fail(e); }
  }

  async function saveAll() {
    try {
      const r = await api("POST", "/api/workspace/save-all");
      const ids = (r && r.started) || [];
      for (const id of ids) {
        const t = state.tabs.find((x) => x.id === id);
        if (t) setTab(Object.assign({}, t, { state: "saving" }));
      }
      toast(ids.length ? "Running mxSave in " + ids.length + (ids.length === 1 ? " session." : " sessions.") : "No idle Claude sessions to save. Busy or exited sessions are skipped.");
    } catch (e) { fail(e); }
  }

  async function saveCloseAll() {
    if (!state.tabs.some((t) => t.running)) { toast("No running tabs to save."); return; }
    try {
      const list = await api("POST", "/api/workspace/save-close-all");
      for (const info of list || []) setTab(info);
      const n = (list && list.length) || 0;
      toast("Saving and closing " + n + (n === 1 ? " tab." : " tabs.") + " Restore workspace brings them back.");
    } catch (e) { fail(e); }
  }
  $("setAuto").addEventListener("change", () => { $("setAutoReboot").disabled = !$("setAuto").checked; });
  $("mainMenuBtn").addEventListener("click", () => {
    const b = $("mainMenuBtn"), r = b.getBoundingClientRect();
    showMenu([
      { label: "mxSave all", fn: saveAll },
      { label: "Save & close all", fn: saveCloseAll },
      { label: "Restore workspace", fn: restoreWorkspace },
      "sep",
      { label: "Add project", fn: openAddProject },
      { label: "New group", fn: () => newGroup() },
      { label: "Commands (Ctrl+K)", fn: openPalette },
      "sep",
      { label: "Settings", fn: openSettings },
      { label: "Security", fn: openSecurity },
      { label: "Sign out", fn: signOut }
    ], r.right - 220, r.bottom + 4, b);
  });

  function dropTab(id) {
    const v = state.views.get(id);
    if (v) { disposeView(v); state.views.delete(id); }
    const idx = state.tabs.findIndex((x) => x.id === id);
    state.tabs = state.tabs.filter((x) => x.id !== id);
    state.mru = state.mru.filter((x) => x !== id);
    if (state.active === id) {
      const next = state.mru.find((x) => state.tabs.some((t) => t.id === x)) || (state.tabs[Math.min(idx, state.tabs.length - 1)] || {}).id;
      state.active = next || null;
    }
  }

  async function killTab(t, ask) {
    if (ask && t.running && !confirm('Kill "' + tabTitle(t) + '" now? The process ends immediately and unsaved work is lost.')) return;
    try {
      await api("DELETE", "/api/tabs/" + encodeURIComponent(t.id));
      dropTab(t.id);
      renderTabs();
      showActive(true);
      renderProjects();
    } catch (e) { fail(e); }
  }

  async function closeTab(t) {
    if (t.running && (t.state === "saving" || t.state === "exiting")) {
      if (!confirm('"' + tabTitle(t) + '" is saving and closes on its own when done. Kill it now? The save may be lost.')) return;
      await killTab(t, false);
      return;
    }
    if (t.running && isClaude(t) && (t.state === "running" || t.state === "save_timeout" || !t.state)) {
      if (t.state === "save_timeout") { await killTab(t, true); return; }
      const choice = await askClose(t);
      if (choice === "save") { await saveClose(t); return; }
      if (choice !== "kill") return;
      await killTab(t, false);
      return;
    }
    if (t.running && !isClaude(t) && !confirm('Close "' + tabTitle(t) + '"? The running shell will be terminated.')) return;
    await killTab(t, false);
  }

  async function closeOthers(keep) {
    const others = state.tabs.filter((t) => t.id !== keep.id);
    if (!others.length) { toast("There are no other tabs."); return; }
    if (!confirm("Close " + others.length + " other " + (others.length === 1 ? "tab" : "tabs") + "? Idle Claude sessions are saved first; shells and exited tabs are closed right away.")) return;
    let saving = 0;
    for (const t of others) {
      try {
        if (t.running && isClaude(t) && t.state === "running") {
          const info = await api("POST", "/api/tabs/" + encodeURIComponent(t.id) + "/save-close");
          if (info && info.id) setTab(info);
          saving++;
        } else if (t.state !== "saving" && t.state !== "exiting") {
          await api("DELETE", "/api/tabs/" + encodeURIComponent(t.id));
          dropTab(t.id);
        }
      } catch (e) { fail(e); }
    }
    activate(keep.id);
    renderProjects();
    if (saving) toast("Saving " + saving + (saving === 1 ? " session" : " sessions") + " before closing.");
  }

  async function restartTab(t) {
    const v = state.views.get(t.id);
    if (!v) return;
    if (t.running && !confirm('Restart "' + tabTitle(t) + '"? The current process is ended first and unsaved work is lost.')) return;
    try {
      const info = await api("POST", "/api/tabs/" + encodeURIComponent(t.id) + "/restart");
      if (info && info.id) v.tab = info; else v.tab.running = true;
      v.term.reset();
      if (v.ws) { v.closing = true; v.ws.close(); v.ws = null; }
      v.closing = false;
      connect(v, false);
      updateOverlay(v);
      setTab(v.tab);
    } catch (e) { fail(e); }
  }

  function activate(id) {
    if (!state.tabs.some((t) => t.id === id)) return;
    state.active = id;
    state.mru = [id].concat(state.mru.filter((x) => x !== id));
    renderTabs();
    renderProjects();
    showActive(true);
  }

  function showActive(focus) {
    for (const [id, v] of state.views) {
      const on = id === state.active;
      v.box.classList.toggle("hidden", !on);
      if (on) requestAnimationFrame(() => { fit(v); if (focus && !overlayOpen()) v.term.focus(); });
    }
  }

  function cycle(dir, focusTab) {
    if (!state.tabs.length) return;
    let i = state.tabs.findIndex((t) => t.id === state.active);
    i = (i + dir + state.tabs.length) % state.tabs.length;
    activate(state.tabs[i].id);
    if (focusTab) { const b = $("tabBar").querySelector('[data-id="' + state.tabs[i].id + '"]'); if (b) b.focus(); }
  }

  const ctx = $("ctxMenu");
  let ctxReturn = null;
  function showMenu(items, x, y, returnTo) {
    ctx.textContent = "";
    ctxReturn = returnTo || null;
    for (const it of items) {
      if (it === "sep") { const li = el("li", "sep"); li.setAttribute("role", "separator"); ctx.appendChild(li); continue; }
      if (it.info) {
        const li = el("li", "ctx-info");
        li.setAttribute("role", "presentation");
        it.info.forEach((line, i) => li.appendChild(el("span", i ? "ctx-meta" : "ctx-path", line)));
        ctx.appendChild(li);
        continue;
      }
      const li = el("li");
      li.setAttribute("role", "none");
      const b = el("button", (it.cls || "") + (it.sub ? " sub" : ""), it.label);
      b.setAttribute("role", "menuitem");
      if (it.sub) b.setAttribute("aria-haspopup", "menu");
      b.disabled = !!it.disabled;
      b.addEventListener("click", () => {
        const back = ctxReturn; ctxReturn = null; closeCtx(); if (it.sub) ctxReturn = back; else closeDrawer(); it.fn();
        // Menu actions (mxSave, Save & close, ...) return the cursor to the terminal unless they opened a dialog.
        if (!it.sub) requestAnimationFrame(() => { const v = state.views.get(state.active); if (v && !overlayOpen()) v.term.focus(); });
      });
      li.appendChild(b);
      ctx.appendChild(li);
    }
    ctx.classList.remove("hidden");
    const r = ctx.getBoundingClientRect();
    ctx.style.left = Math.max(4, Math.min(x, innerWidth - r.width - 4)) + "px";
    ctx.style.top = Math.max(4, Math.min(y, innerHeight - r.height - 4)) + "px";
    const first = ctx.querySelector("button:not(:disabled)");
    if (first) first.focus();
  }
  function subKey(ev) {
    if (ev.key === "ArrowRight" && document.activeElement && document.activeElement.classList.contains("sub")) { ev.preventDefault(); document.activeElement.click(); }
  }
  function openCtx(t, x, y) {
    const claudeIdle = t.running && isClaude(t) && t.state === "running";
    const busy = t.state === "saving" || t.state === "exiting";
    showMenu([
      { label: "mxSave", fn: () => saveOnly(t), disabled: !claudeIdle },
      { label: "Save & close", fn: () => saveClose(t), disabled: !(t.running && isClaude(t)) || busy },
      { label: "Restart", fn: () => restartTab(t), disabled: busy },
      "sep",
      { label: "Copy session id", fn: () => copySessionId(t), disabled: !t.sessionId },
      { label: "Close others", fn: () => closeOthers(t), disabled: state.tabs.length < 2 },
      "sep",
      { label: "Kill", fn: () => killTab(t, true), disabled: !t.running, cls: "danger" }
    ], x, y);
  }
  function closeCtx() { ctx.classList.add("hidden"); }
  ctx.addEventListener("keydown", subKey);
  ctx.addEventListener("keydown", (ev) => {
    const items = Array.from(ctx.querySelectorAll("button:not(:disabled)"));
    const i = items.indexOf(document.activeElement);
    if (ev.key === "ArrowDown") { ev.preventDefault(); items[(i + 1) % items.length].focus(); }
    else if (ev.key === "ArrowUp") { ev.preventDefault(); items[(i - 1 + items.length) % items.length].focus(); }
    else if (ev.key === "Escape" || ev.key === "Tab") {
      ev.preventDefault();
      const back = ctxReturn; ctxReturn = null;
      closeCtx();
      if (back && document.contains(back)) { back.focus(); return; }
      const v = state.views.get(state.active); if (v) v.term.focus();
    }
  });
  document.addEventListener("mousedown", (ev) => { if (!ctx.contains(ev.target)) closeCtx(); });
  window.addEventListener("blur", closeCtx);

  // Quick actions: user-defined status bar buttons, run step by step on the server.
  let quickActions = [];
  function renderQuick() {
    const box = $("sbQuick");
    box.textContent = "";
    quickActions.forEach((a, i) => {
      const b = el("button", "btn small ghost");
      b.textContent = a.name;
      b.title = a.steps.join("  →  ");
      b.addEventListener("pointerdown", (ev) => ev.preventDefault()); // keep focus on the terminal
      b.addEventListener("click", () => { const t = activeTab(); if (t) runQuick(t, i); });
      box.appendChild(b);
    });
    renderStatus();
  }
  async function loadQuickActions() {
    try { const s = await api("GET", "/api/settings"); quickActions = s.quickActions || []; renderQuick(); } catch (e) {}
  }
  async function runQuick(t, i) {
    try {
      const info = await api("POST", "/api/tabs/" + encodeURIComponent(t.id) + "/action/" + i + "?name=" + encodeURIComponent(quickActions[i].name));
      if (info && info.id) setTab(info);
      toast("Running \"" + quickActions[i].name + "\" in " + tabTitle(t) + ".");
    } catch (e) { if (e && e.message === "stale_quick_action") loadQuickActions(); fail(e); }
    finally { const v = state.views.get(state.active); if (v && !overlayOpen()) v.term.focus(); }
  }
  function quickToText(list) {
    return list.map((a) => a.name + ": " + a.steps.join(" | ")).join("\n");
  }
  function quickFromText(text) {
    const out = [];
    for (const raw of text.split("\n")) {
      const line = raw.trim();
      if (!line) continue;
      const c = line.indexOf(":");
      if (c <= 0) throw new Error("Quick action line needs \"name: steps\": " + line);
      out.push({ name: line.slice(0, c).trim(), steps: line.slice(c + 1).split("|").map((s) => s.trim()).filter(Boolean) });
    }
    return out;
  }

  const sDlg = $("settingsDialog");
  async function openSettings() {
    $("setError").textContent = "";
    try {
      const s = await api("GET", "/api/settings");
      $("setPrompt").value = s.savePrompt;
      $("setIdle").value = s.saveIdleSeconds;
      $("setTimeout").value = s.saveTimeoutMinutes;
      $("setDays").value = s.sessionDays;
      $("setAuto").checked = !!s.autoRestore;
      $("setAutoReboot").checked = !!s.autoRestoreAfterReboot;
      $("setAutoReboot").disabled = !s.autoRestore;
      $("setQuick").value = quickToText(s.quickActions || []);
      $("setCloseExit").checked = !!s.closeOnClaudeExit;
      sDlg.dataset.theme = themeName;
      $("setTheme").value = themeName;
      $("setAutoFit").checked = autoFit();
      sDlg.showModal();
      $("setPrompt").focus();
    } catch (e) { fail(e); }
  }
  $("settingsBtn").addEventListener("click", openSettings);
  $("setCancel").addEventListener("click", () => { applyTheme(sDlg.dataset.theme || themeName, false); sDlg.close(); });
  $("setTheme").addEventListener("change", () => applyTheme($("setTheme").value, false));
  sDlg.addEventListener("cancel", () => applyTheme(sDlg.dataset.theme || themeName, false));
  $("settingsForm").addEventListener("submit", async (ev) => {
    ev.preventDefault();
    $("setError").textContent = "";
    let quick;
    try { quick = quickFromText($("setQuick").value); } catch (e) { $("setError").textContent = e.message; return; }
    const body = {
      quickActions: quick,
      closeOnClaudeExit: $("setCloseExit").checked,
      savePrompt: $("setPrompt").value.trim(),
      saveIdleSeconds: parseInt($("setIdle").value, 10),
      saveTimeoutMinutes: parseInt($("setTimeout").value, 10),
      sessionDays: parseInt($("setDays").value, 10),
      autoRestore: $("setAuto").checked,
      autoRestoreAfterReboot: $("setAuto").checked && $("setAutoReboot").checked
    };
    try {
      const saved = await api("PUT", "/api/settings", body);
      quickActions = (saved && saved.quickActions) || [];
      renderQuick();
      applyTheme($("setTheme").value, true);
      lsSet("mxo-autofit", $("setAutoFit").checked ? "on" : "off");
      for (const v of state.views.values()) if (v.grid) applyGrid(v, v.grid);
      sDlg.dataset.theme = themeName;
      sDlg.close();
      toast("Settings saved.");
    } catch (e) { if (!(e instanceof AuthError)) $("setError").textContent = describe(e); }
  });

  const secDlg = $("securityDialog");
  const sec = { info: null };
  function secErr(e) {
    if (e instanceof AuthError) return;
    $("secError").textContent = describe(e);
  }
  function secRender() {
    const i = sec.info;
    const d = i.developer;
    $("secBound").textContent = d ? "Linked to " + (d.name || "developer") + " (#" + d.id + ")." : "Not linked yet. The next mxLore sign-in with the setup code links the account.";
    $("secBound").classList.toggle("ok", !!d);
    $("secUnbind").classList.toggle("hidden", !d);
    const enrolling = !$("secEnroll").classList.contains("hidden");
    $("secTotpState").textContent = i.totpEnabled ? "Two-factor sign-in is on." : "Two-factor sign-in is off.";
    $("secTotpState").classList.toggle("ok", i.totpEnabled);
    $("secTotpStart").classList.toggle("hidden", i.totpEnabled || enrolling);
    $("secTotpOn").classList.toggle("hidden", !enrolling);
    $("secTotpOff").classList.toggle("hidden", !i.totpEnabled || !!d);
    $("secCodeRow").classList.toggle("hidden", !i.totpEnabled && !enrolling);
  }
  async function secReload() {
    sec.info = await api("GET", "/api/security");
    secRender();
  }
  async function openSecurity() {
    $("secError").textContent = "";
    $("secCode").value = "";
    $("secEnroll").classList.add("hidden");
    try {
      await secReload();
      $("secUrl").value = sec.info.mxLoreUrl || "http://127.0.0.1:8080";
      secDlg.showModal();
      $("secUrl").focus();
    } catch (e) { fail(e); }
  }
  function secCode() { return $("secCode").value.trim(); }
  async function secRun(fn) {
    $("secError").textContent = "";
    try { await fn(); } catch (e) { secErr(e); }
  }
  $("secClose").addEventListener("click", () => secDlg.close());
  secDlg.addEventListener("close", () => { $("secCode").value = ""; });
  $("securityForm").addEventListener("submit", (ev) => ev.preventDefault());
  $("secUrlSave").addEventListener("click", () => secRun(async () => {
    const r = await api("PUT", "/api/security/mxlore-url", { url: $("secUrl").value.trim(), totp: secCode() });
    $("secCode").value = "";
    if (r.signedOut) { secDlg.close(); showLogin(false, "Server address saved. Sign in again with the setup code."); return; }
    $("secUrl").value = r.mxLoreUrl;
    await secReload();
    toast("mxLore server address saved.");
  }));
  $("secUnbind").addEventListener("click", () => secRun(async () => {
    if (!confirm("Unlink this orchestrator? You are signed out, and the next sign-in needs the setup code again.")) return;
    const r = await api("POST", "/api/security/mxlore-unbind", { totp: secCode() });
    $("secCode").value = "";
    if (r.signedOut) { secDlg.close(); showLogin(false, "Unlinked. Sign in again with the setup code."); return; }
    await secReload();
    toast("Unlinked.");
  }));
  $("secTotpStart").addEventListener("click", () => secRun(async () => {
    const r = await api("POST", "/api/security/totp/start");
    $("secQr").src = r.qr;
    $("secSecret").textContent = r.secret;
    $("secEnroll").classList.remove("hidden");
    secRender();
    $("secCode").focus();
  }));
  $("secTotpOn").addEventListener("click", () => secRun(async () => {
    await api("POST", "/api/security/totp/confirm", { code: secCode() });
    $("secCode").value = "";
    $("secEnroll").classList.add("hidden");
    $("secQr").removeAttribute("src");
    $("secSecret").textContent = "";
    await secReload();
    toast("Two-factor sign-in is on. Other browsers have been signed out.");
  }));
  $("secTotpOff").addEventListener("click", () => secRun(async () => {
    await api("POST", "/api/security/totp/disable", { code: secCode() });
    $("secCode").value = "";
    await secReload();
    toast("Two-factor sign-in is off.");
  }));

  function fuzzy(q, text) {
    q = q.toLowerCase();
    const s = text.toLowerCase();
    const sub = s.indexOf(q);
    if (sub >= 0) return { score: 1000 - sub - text.length * 0.1, hits: Array.from({ length: q.length }, (_, k) => sub + k) };
    const hits = [];
    let j = 0, score = 0, prev = -2;
    for (let i = 0; i < s.length && j < q.length; i++) {
      if (s[i] === q[j]) {
        hits.push(i);
        score += prev === i - 1 ? 5 : 1;
        if (i === 0 || /[\s\\/_\-.]/.test(s[i - 1])) score += 3;
        prev = i; j++;
      }
    }
    if (j < q.length) return null;
    return { score: score - text.length * 0.05, hits };
  }

  function commands() {
    const list = [];
    state.tabs.forEach((t, i) => list.push({ group: "Tab", label: "Switch to " + tabTitle(t), lamp: lampOf(t), key: i < 9 ? "Alt+" + (i + 1) : "", run: () => activate(t.id) }));
    for (const p of railProjects()) {
      if (!p.exists) continue;
      list.push({ group: "Project", label: p.name, sub: p.path, lamp: projectLamp(p), run: () => openDefault(p) });
      list.push({ group: "Project", label: "New session in " + p.name, run: () => openTab({ projectId: p.id, mode: "new" }) });
      list.push({ group: "Project", label: "Continue in " + p.name, run: () => openTab({ projectId: p.id, mode: "continue" }) });
      list.push({ group: "Project", label: "Shell in " + p.name, run: () => openTab({ projectId: p.id, mode: "shell" }) });
    }
    list.push({ group: "Command", label: "Next tab", key: "Ctrl+Tab", run: () => cycle(1) });
    list.push({ group: "Command", label: "Previous tab", key: "Ctrl+Shift+Tab", run: () => cycle(-1) });
    list.push({ group: "Command", label: "mxSave all", run: saveAll });
    list.push({ group: "Command", label: "Save & close all", run: saveCloseAll });
    list.push({ group: "Command", label: "Restore workspace", run: restoreWorkspace });
    list.push({ group: "Command", label: "Toggle project list", key: "Ctrl+B", run: toggleRail });
    list.push({ group: "Command", label: "Focus project list", key: "Ctrl+Shift+E", run: focusRail });
    list.push({ group: "Command", label: "Add project", run: openAddProject });
    list.push({ group: "Command", label: "New group", run: () => newGroup() });
    for (const g of sortedGroups()) list.push({ group: "Group", label: "Restore all in " + g.name, lamp: groupLamp(g.id), run: () => restoreGroup(g) });
    list.push({ group: "Command", label: "Settings", run: openSettings });
    list.push({ group: "Command", label: "Security", run: openSecurity });
    list.push({ group: "Command", label: "Sign out", run: signOut });
    return list;
  }

  const pal = $("palette");
  const palState = { items: [], sel: 0 };
  function openPalette() {
    if (!state.signedIn) return;
    closeCtx();
    if (pal.open) { $("paletteInput").select(); return; }
    $("paletteInput").value = "";
    pal.showModal();
    renderPalette();
    $("paletteInput").focus();
  }
  function highlight(text, hits) {
    const frag = document.createDocumentFragment();
    const set = new Set(hits || []);
    let buf = "";
    for (let i = 0; i < text.length; i++) {
      if (set.has(i)) { if (buf) { frag.appendChild(document.createTextNode(buf)); buf = ""; } frag.appendChild(el("mark", "", text[i])); }
      else buf += text[i];
    }
    if (buf) frag.appendChild(document.createTextNode(buf));
    return frag;
  }
  function renderPalette() {
    const q = $("paletteInput").value.trim();
    let items = commands().map((c, i) => ({ c, i, m: q ? fuzzy(q, c.label) : { score: -i, hits: [] } }));
    if (q) items = items.filter((x) => x.m || fuzzy(q, x.c.label + " " + (x.c.sub || ""))).map((x) => x.m ? x : { c: x.c, i: x.i, m: { score: -50, hits: [] } }).sort((a, b) => b.m.score - a.m.score);
    palState.items = items.slice(0, 60);
    palState.sel = 0;
    const ul = $("paletteList");
    ul.textContent = "";
    if (!palState.items.length) { ul.appendChild(el("li", "pl-empty", "Nothing matches. Try a project name or a command such as \"restore\".")); return; }
    palState.items.forEach((x, k) => {
      const li = el("li");
      li.setAttribute("role", "option");
      li.id = "pl-" + k;
      const lamp = el("i", "lamp " + (x.c.lamp || "none"));
      if (!x.c.lamp) lamp.style.visibility = "hidden";
      li.appendChild(lamp);
      const lab = el("span", "pl-label");
      lab.appendChild(highlight(x.c.label, x.m.hits));
      li.appendChild(lab);
      li.appendChild(el("span", "pl-group", x.c.group));
      if (x.c.key) li.appendChild(el("span", "pl-key", x.c.key));
      li.addEventListener("mousemove", () => selPalette(k));
      li.addEventListener("click", () => runPalette(k));
      ul.appendChild(li);
    });
    selPalette(0);
  }
  function selPalette(k) {
    const ul = $("paletteList");
    const old = ul.children[palState.sel];
    if (old) old.classList.remove("sel");
    palState.sel = k;
    const n = ul.children[k];
    if (n && palState.items.length) { n.classList.add("sel"); n.scrollIntoView({ block: "nearest" }); $("paletteInput").setAttribute("aria-activedescendant", n.id); }
  }
  function runPalette(k) {
    const x = palState.items[k];
    if (!x) return;
    pal.close();
    x.c.run();
  }
  $("paletteInput").addEventListener("input", renderPalette);
  $("paletteInput").addEventListener("keydown", (ev) => {
    const n = palState.items.length;
    if (ev.key === "ArrowDown") { ev.preventDefault(); if (n) selPalette((palState.sel + 1) % n); }
    else if (ev.key === "ArrowUp") { ev.preventDefault(); if (n) selPalette((palState.sel - 1 + n) % n); }
    else if (ev.key === "Enter") { ev.preventDefault(); runPalette(palState.sel); }
  });
  pal.addEventListener("close", () => { const v = state.views.get(state.active); if (v && !overlayOpen()) v.term.focus(); });
  pal.addEventListener("click", (ev) => { if (ev.target === pal) pal.close(); });
  $("paletteBtn").addEventListener("click", openPalette);
  $("emptyPaletteBtn").addEventListener("click", openPalette);

  function overlayOpen() { return !!document.querySelector("dialog[open]"); }
  function closeOverlays() { closeCtx(); for (const d of document.querySelectorAll("dialog[open]")) d.close(); }

  function shortcut(ev) {
    if (ev.type !== "keydown") return null;
    if (ev.ctrlKey && !ev.altKey && !ev.metaKey && (ev.key === "k" || ev.key === "K") && !ev.shiftKey) return "palette";
    if (ev.ctrlKey && !ev.altKey && !ev.metaKey && !ev.shiftKey && ev.code === "KeyB") return "rail";
    if (ev.ctrlKey && ev.shiftKey && !ev.altKey && !ev.metaKey && ev.code === "KeyE") return "railfocus";
    if (ev.ctrlKey && !ev.altKey && ev.key === "Tab") return ev.shiftKey ? "prev" : "next";
    if (ev.altKey && !ev.ctrlKey && !ev.metaKey && !ev.shiftKey && /^Digit[1-9]$/.test(ev.code)) return "jump" + ev.code.slice(5);
    return null;
  }

  window.addEventListener("keydown", (ev) => {
    if (!state.signedIn) return;
    const s = shortcut(ev);
    if (!s) return;
    if (s !== "palette" && document.querySelector("dialog[open]:not(#palette)")) return;
    ev.preventDefault();
    ev.stopPropagation();
    if (s === "palette") { openPalette(); return; }
    if (pal.open) pal.close();
    if (s === "rail") { toggleRail(); return; }
    if (s === "railfocus") { closeCtx(); focusRail(); return; }
    if (s === "next") cycle(1);
    else if (s === "prev") cycle(-1);
    else { const t = state.tabs[parseInt(s.slice(4), 10) - 1]; if (t) activate(t.id); }
  }, true);

  const enc = new TextEncoder();
  const TERM_THEMES = {
    black: {
      background: "#000000", foreground: "#C9CED4", cursor: "#C9CED4", cursorAccent: "#000000",
      selectionBackground: "#343A42", selectionInactiveBackground: "#24282E",
      black: "#1A1D22", red: "#D9665C", green: "#4DB39F", yellow: "#D6A24A", blue: "#6C9FD6", magenta: "#AE8CD0", cyan: "#5BB8C9", white: "#C9CED4",
      brightBlack: "#5F666F", brightRed: "#EB8A80", brightGreen: "#72CDBB", brightYellow: "#E9BE6E", brightBlue: "#94BDEA", brightMagenta: "#C7AAE4", brightCyan: "#84D2DF", brightWhite: "#E6E9ED"
    },
    slate: {
      background: "#18202B", foreground: "#D9E1EA", cursor: "#D9E1EA", cursorAccent: "#18202B",
      selectionBackground: "#3C4B5F", selectionInactiveBackground: "#2E3A4A",
      black: "#232E3C", red: "#E05A4F", green: "#3FB6A8", yellow: "#E0A43A", blue: "#6EA2DC", magenta: "#B48FD8", cyan: "#5CC4D6", white: "#D9E1EA",
      brightBlack: "#6B7888", brightRed: "#F08A80", brightGreen: "#6DD3C6", brightYellow: "#F0C06A", brightBlue: "#9CC3F0", brightMagenta: "#CFB1EC", brightCyan: "#8ADBE8", brightWhite: "#FFFFFF"
    },
    night: {
      background: "#1A1714", foreground: "#DCD2C4", cursor: "#D8B88A", cursorAccent: "#1A1714",
      selectionBackground: "#4B4239", selectionInactiveBackground: "#3A332C",
      black: "#2C2722", red: "#D47A63", green: "#8FB57E", yellow: "#D9AE5F", blue: "#8FA7C4", magenta: "#BE95B0", cyan: "#86B5AC", white: "#DCD2C4",
      brightBlack: "#7A6F63", brightRed: "#E59B85", brightGreen: "#AACB9A", brightYellow: "#E8C682", brightBlue: "#AFC2D8", brightMagenta: "#D3B2C7", brightCyan: "#A6CDC5", brightWhite: "#EFE7DB"
    }
  };
  // Colour scheme is a per-browser preference; the page works without storage.
  let themeName = "black";
  try { const t = localStorage.getItem("mxo-theme"); if (t && TERM_THEMES[t]) themeName = t; } catch (e) {}
  let termTheme = TERM_THEMES[themeName];
  function applyTheme(name, persist) {
    if (!TERM_THEMES[name]) return;
    themeName = name;
    termTheme = TERM_THEMES[name];
    document.documentElement.dataset.theme = name;
    for (const v of state.views.values()) v.term.options.theme = termTheme;
    if (persist) { try { localStorage.setItem("mxo-theme", name); } catch (e) {} }
  }
  applyTheme(themeName, false);

  function openLink(ev, uri) {
    if (!(ev.ctrlKey || ev.metaKey)) return;
    if (!/^https?:\/\//i.test(uri)) return;
    window.open(uri, "_blank", "noopener");
  }

  // Plain-text URLs (no OSC 8): underline on hover, Ctrl+click opens.
  function urlLinkProvider(term) {
    const re = /https?:\/\/[^\s"'<>`]+[^\s"'<>`.,;:!?)\]}]/g;
    return {
      provideLinks(y, callback) {
        const line = term.buffer.active.getLine(y - 1);
        if (!line) { callback(undefined); return; }
        const text = line.translateToString(true);
        const links = [];
        let m;
        re.lastIndex = 0;
        while ((m = re.exec(text))) {
          const uri = m[0];
          links.push({
            range: { start: { x: m.index + 1, y }, end: { x: m.index + uri.length, y } },
            text: uri,
            activate: (e) => openLink(e, uri)
          });
        }
        callback(links.length ? links : undefined);
      }
    };
  }

  function ensureView(tab) {
    let v = state.views.get(tab.id);
    if (v) return v;
    const box = el("div", "term hidden");
    $("terminals").appendChild(box);
    const term = new Terminal({
      cursorBlink: true,
      fontFamily: '"JetBrains Mono", Consolas, monospace',
      fontSize: 14,
      lineHeight: 1.1,
      scrollback: 10000,
      allowProposedApi: true,
      theme: termTheme,
      // OSC 8 hyperlinks: Ctrl+click opens, like the Windows console.
      linkHandler: { activate: (ev, uri) => openLink(ev, uri), allowNonHttpProtocols: false }
    });
    const fitAddon = new FitAddon.FitAddon();
    term.loadAddon(fitAddon);
    // OSC 52: Claude Code writes its copies here; without this addon xterm drops them and nothing reaches the clipboard.
    term.loadAddon(new ClipboardAddon.ClipboardAddon());
    // Unicode 11 widths: emoji take two columns, as Claude Code assumes; the v6 default shifts the rest of the line.
    term.loadAddon(new Unicode11Addon.Unicode11Addon());
    term.unicode.activeVersion = "11";
    term.attachCustomKeyEventHandler((ev) => {
      // Ctrl+V / Ctrl+Shift+V: leave it to the browser so the paste event fires.
      if (ev.ctrlKey && !ev.altKey && !ev.metaKey && ev.code === "KeyV") return false;
      // Ctrl+C with a selection copies (like the Windows console), else it stays ^C; Ctrl+Shift+C always copies.
      // The browser's own copy event fires and xterm fills the clipboard from the selection.
      if (ev.ctrlKey && !ev.altKey && !ev.metaKey && ev.code === "KeyC" && (ev.shiftKey || term.hasSelection())) {
        if (ev.type === "keydown" && term.hasSelection()) setTimeout(() => term.clearSelection(), 0);
        return false;
      }
      // Ctrl+Enter / Shift+Enter: line feed, which Claude Code reads as a new line (like the Windows console).
      if (ev.key === "Enter" && (ev.ctrlKey || ev.shiftKey) && !ev.altKey && !ev.metaKey) {
        if (ev.type === "keydown") { const tv = state.views.get(tab.id); if (tv) send(tv, enc.encode("\n")); }
        ev.preventDefault();
        return false;
      }
      return !shortcut(ev);
    });
    term.registerLinkProvider(urlLinkProvider(term));
    term.open(box);
    // Phone keyboards send suggestions as compositions that xterm repeats: turn them off.
    if (term.textarea) {
      for (const [k, val] of [["autocomplete", "off"], ["autocorrect", "off"], ["autocapitalize", "off"], ["spellcheck", "false"]]) term.textarea.setAttribute(k, val);
    }
    // Android keyboards ignore those attributes and xterm resends the whole field per word.
    // There the field is the source of truth: send only what changed since the last send.
    const ime = term.textarea && /Android/i.test(navigator.userAgent) ? { sent: "", bsAt: 0 } : null;
    if (ime) {
      const ta = term.textarea;
      ta.addEventListener("keydown", (ev) => { if (ev.keyCode === 8) ime.bsAt = performance.now(); }, true);
      ta.addEventListener("focus", () => { ime.sent = ta.value; });
      // xterm empties the field from code (no input event); what is left there is already sent.
      ta.addEventListener("beforeinput", () => { if (ta.value !== ime.sent) ime.sent = ta.value; }, true);
      ta.addEventListener("input", (ev) => {
        if (ev.inputType === "insertFromPaste") { ime.sent = ta.value; return; }
        const now = ta.value, old = ime.sent;
        let p = 0;
        while (p < now.length && p < old.length && now[p] === old[p]) p++;
        const removed = [...old.slice(p)].length;
        ime.sent = now;
        // A real Backspace key already went out through xterm.
        const del = performance.now() - ime.bsAt < 100 ? Math.max(0, removed - 1) : removed;
        const out = "\x7f".repeat(del) + now.slice(p);
        if (out) send(v, enc.encode(out));
      });
    }
    // Files dragged onto the terminal: the browser knows only name and bytes, so the
    // orchestrator stores each file and the absolute path is typed into the terminal.
    box.addEventListener("dragover", (ev) => {
      if (!ev.dataTransfer || !Array.from(ev.dataTransfer.types).includes("Files")) return;
      ev.preventDefault(); ev.dataTransfer.dropEffect = "copy"; box.classList.add("drop-files");
    });
    box.addEventListener("dragleave", () => box.classList.remove("drop-files"));
    box.addEventListener("drop", async (ev) => {
      box.classList.remove("drop-files");
      const files = ev.dataTransfer ? Array.from(ev.dataTransfer.files) : [];
      if (!files.length) return;
      ev.preventDefault(); ev.stopPropagation();
      await dropFilesInto(v, files);
    });
    box.addEventListener("paste", (ev) => {
      const cd = ev.clipboardData;
      if (cd && cd.getData("text/plain")) return; // xterm pastes text itself (bracketed paste)
      // No text (e.g. an image): Claude reads the clipboard of this machine on ^V.
      ev.preventDefault();
      ev.stopPropagation();
      send(v, enc.encode("\x16"));
    }, true);
    // xterm has no touch scrolling: a vertical finger drag scrolls the scrollback,
    // or, in full-screen apps (no scrollback), is sent as mouse-wheel notches the
    // app scrolls itself. A quick flick keeps scrolling and slows down (momentum).
    const NOTCH_ROWS = 3; // rows of finger travel per wheel notch
    let touchY = null, touchX = 0, touchRest = 0, lastT = 0, vel = 0, flingRaf = 0;
    // Measured on the terminal, not the box: a device showing another device's size has a box of a different height.
    const rowHeight = () => (term.element ? term.element.clientHeight : box.clientHeight) / Math.max(term.rows, 1);
    const scrollRows = (rows) => {
      touchRest += rows;
      if (term.buffer.active.type === "alternate") {
        const notches = Math.trunc(touchRest / NOTCH_ROWS);
        if (!notches) return;
        touchRest -= notches * NOTCH_ROWS;
        const target = term.element.querySelector(".xterm-screen") || term.element;
        for (let i = 0; i < Math.abs(notches); i++) {
          // xterm turns the wheel into mouse reports or arrow keys via onData.
          target.dispatchEvent(new WheelEvent("wheel", { deltaY: Math.sign(notches) * rowHeight(), deltaMode: 0, clientX: touchX, clientY: touchY ?? 0, bubbles: true, cancelable: true }));
        }
      } else {
        const lines = Math.trunc(touchRest);
        if (lines) { term.scrollLines(lines); touchRest -= lines; }
      }
    };
    box.addEventListener("touchstart", (ev) => {
      cancelAnimationFrame(flingRaf);
      touchY = ev.touches.length === 1 ? ev.touches[0].clientY : null;
      touchX = touchY === null ? 0 : ev.touches[0].clientX;
      touchRest = 0; vel = 0; lastT = performance.now();
    }, { passive: true });
    box.addEventListener("touchmove", (ev) => {
      if (touchY === null || ev.touches.length !== 1) return;
      const y = ev.touches[0].clientY, now = performance.now();
      const rows = (touchY - y) / rowHeight();
      const dt = Math.max(now - lastT, 1);
      vel = 0.8 * (rows / dt) + 0.2 * vel; // rows per ms, smoothed
      const x = ev.touches[0].clientX;
      // Showing a larger size than the screen: a drag pans the terminal first;
      // only once the pan hits the edge does a vertical drag scroll the scrollback.
      let panned = false;
      if (box.classList.contains("grid-locked")) {
        box.scrollLeft -= x - touchX;
        const top = box.scrollTop;
        box.scrollTop -= y - touchY;
        panned = box.scrollTop !== top;
      }
      touchY = y; touchX = x; lastT = now;
      if (panned) vel = 0; else scrollRows(rows);
      ev.preventDefault();
    }, { passive: false });
    box.addEventListener("touchend", () => {
      if (touchY === null) return;
      // Momentum only after a real flick, and not if the finger rested before lifting.
      if (Math.abs(vel) < 0.02 || performance.now() - lastT > 80) { touchY = null; return; }
      let prev = performance.now();
      const step = (now) => {
        const dt = now - prev; prev = now;
        vel *= Math.pow(0.995, dt); // friction
        if (Math.abs(vel) < 0.005) { touchY = null; return; }
        scrollRows(vel * dt);
        flingRaf = requestAnimationFrame(step);
      };
      flingRaf = requestAnimationFrame(step);
    }, { passive: true });
    v = { tab, box, term, fitAddon, ws: null, retry: 0, timer: null, closing: false, overlay: null, lastSize: "", grid: null };
    // The terminal size belongs to one device at a time; the others show that
    // size as it is. This button moves the size to this device.
    const claim = el("button", "btn small grid-claim", "Fit to this screen");
    claim.title = "Use this window's size for the terminal. Other devices then show it at this size.";
    claim.addEventListener("pointerdown", (ev) => ev.preventDefault()); // keep focus on the terminal
    claim.addEventListener("click", () => {
      const d = fitAddon.proposeDimensions();
      if (d && d.cols && d.rows && v.ws && v.ws.readyState === WebSocket.OPEN) v.ws.send(JSON.stringify({ type: "claim", cols: d.cols, rows: d.rows }));
      term.focus();
    });
    box.appendChild(claim);
    // The box scrolls when it pans a larger size; keep its controls in view.
    box.addEventListener("scroll", () => {
      const shift = "translate(" + box.scrollLeft + "px," + box.scrollTop + "px)";
      claim.style.transform = shift;
      if (v.overlay) v.overlay.style.transform = shift;
    }, { passive: true });
    term.onData((d) => {
      if (ime) {
        // Plain text comes from the input listener; keys (Enter, arrows, Backspace, paste) pass.
        if (!/[\x00-\x1f\x7f]/.test(d)) return;
        if (/[\r\n\x03\x1b]/.test(d)) { term.textarea.value = ""; ime.sent = ""; }
      }
      send(v, enc.encode(d));
    });
    term.onBinary((d) => {
      const b = new Uint8Array(d.length);
      for (let i = 0; i < d.length; i++) b[i] = d.charCodeAt(i) & 255;
      send(v, b);
    });
    state.views.set(tab.id, v);
    connect(v, false);
    return v;
  }

  if (document.fonts && document.fonts.load) {
    document.fonts.load('14px "JetBrains Mono"').then(() => {
      for (const v of state.views.values()) { try { v.term.options.fontFamily = '"JetBrains Mono", Consolas, monospace'; } catch (e) {} fit(v); }
    }).catch(() => {});
  }

  // Page-wide file drop: anywhere outside the project/tab reorder zones goes to the active
  // terminal; without this the browser opens the dropped file in a new tab.
  const hasFiles = (ev) => !!(ev.dataTransfer && Array.from(ev.dataTransfer.types).includes("Files"));
  // Capture phase, so no inner handler can let the browser open a dropped file.
  window.addEventListener("dragover", (ev) => { if (hasFiles(ev)) { ev.preventDefault(); ev.dataTransfer.dropEffect = "copy"; } }, true);
  window.addEventListener("drop", (ev) => { if (hasFiles(ev)) ev.preventDefault(); }, true);
  document.addEventListener("drop", async (ev) => {
    if (!hasFiles(ev)) return;
    const v = state.views.get(state.active);
    if (!v) { toast("Open a terminal tab first, then drop the file onto it.", true); return; }
    const files = Array.from(ev.dataTransfer.files);
    if (!files.length) { toast("The dropped item carried no file data. Try dragging it again.", true); return; }
    await dropFilesInto(v, files);
  });
  async function dropFilesInto(v, files) {
    const paths = [];
    for (const f of files) {
      try { paths.push(await uploadDrop(f)); } catch (e) { fail(e); }
    }
    if (!paths.length) return;
    send(v, enc.encode(paths.map((p) => (/\s/.test(p) ? '"' + p + '"' : p)).join(" ") + " "));
    v.term.focus();
  }
  async function uploadDrop(file) {
    const fd = new FormData();
    fd.append("file", file, file.name);
    let res;
    try { res = await fetch("/api/drops", { method: "POST", credentials: "same-origin", body: fd }); }
    catch (e) { throw new NetError("The orchestrator is not reachable. Check that it is still running."); }
    const text = await res.text();
    let data = null;
    if (text) { try { data = JSON.parse(text); } catch (e) { data = { error: text.trim() }; } }
    if (!res.ok) {
      const code = data && data.error;
      if (code === "drop_too_large") throw new Error("\"" + file.name + "\" is larger than 64 MB and was not stored.");
      throw new Error("\"" + file.name + "\" could not be stored" + (code ? " (" + code + ")" : "") + ".");
    }
    return data.path;
  }

  function send(v, bytes) {
    if (v.ws && v.ws.readyState === WebSocket.OPEN) v.ws.send(bytes);
  }

  // One terminal size is shared by every device viewing the tab. The server
  // sends it as {type:"size"}; the device that owns it sizes the terminal to its
  // window, every other device shows that size as it is (no local reflow).
  function sendResize(v, cols, rows) {
    if (v.ws && v.ws.readyState === WebSocket.OPEN) {
      v.ws.send(JSON.stringify({ type: "resize", cols, rows }));
      v.lastSize = cols + "x" + rows;
    }
  }

  // drivesSize: this view may size the terminal to its window. The owner always
  // may; while nobody owns the size, the window in use (focused, active tab) takes it.
  function drivesSize(v) {
    if (!v.grid) return false;
    if (v.grid.owner) return true;
    return !v.grid.owned && autoFit() && document.hasFocus() && state.active === v.tab.id;
  }

  // Per device: phones default to off, so they keep the size a desktop set and pan it.
  function autoFit() {
    const s = lsGet("mxo-autofit");
    return s ? s === "on" : !narrow();
  }

  function applyGrid(v, g) {
    v.grid = g;
    // The size the terminal really has now; fit() sends only when ours differs from it.
    v.lastSize = g.cols + "x" + g.rows;
    v.box.classList.toggle("grid-locked", !g.owner && (g.owned || !autoFit()));
    if (!v.box.classList.contains("grid-locked")) { v.box.scrollLeft = 0; v.box.scrollTop = 0; }
    if (drivesSize(v)) { fit(v); return; }
    if (v.term.cols !== g.cols || v.term.rows !== g.rows) v.term.resize(g.cols, g.rows);
  }

  window.addEventListener("focus", () => {
    const v = state.views.get(state.active);
    if (v) { v.lastSize = ""; fit(v); }
  });
  function fit(v) {
    if (v.box.classList.contains("hidden") || !v.box.clientWidth) return;
    if (!drivesSize(v)) {
      if (v.grid && (v.term.cols !== v.grid.cols || v.term.rows !== v.grid.rows)) v.term.resize(v.grid.cols, v.grid.rows);
      return;
    }
    try { v.fitAddon.fit(); } catch (e) {}
    // The on-screen keyboard animates the height over many frames; resizing the
    // terminal on each one makes the program redraw mid-flight and leaves broken
    // lines. Reflow locally right away, send the size once it has settled.
    clearTimeout(v.resizeTimer);
    v.resizeTimer = setTimeout(() => {
      const key = v.term.cols + "x" + v.term.rows;
      if (key !== v.lastSize && drivesSize(v)) sendResize(v, v.term.cols, v.term.rows);
    }, 200);
  }

  function connect(v, clearFirst) {
    if (v.closing) return;
    clearTimeout(v.timer);
    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    const ws = new WebSocket(proto + "//" + location.host + "/ws/tabs/" + encodeURIComponent(v.tab.id));
    ws.binaryType = "arraybuffer";
    v.ws = ws;
    let first = true;
    ws.onopen = () => {
      v.retry = 0;
      v.lastSize = "";
      v.grid = null; // the server sends the current size as its first message
      updateOverlay(v);
    };
    ws.onmessage = (ev) => {
      if (typeof ev.data === "string") {
        let msg;
        try { msg = JSON.parse(ev.data); } catch (e) { return; }
        if (msg.type === "size") { applyGrid(v, msg); return; }
        if (msg.type === "exit") {
          v.tab.running = false;
          v.tab.exitCode = msg.code;
          updateOverlay(v);
          renderTabs();
          renderProjects();
        }
        return;
      }
      if (first) { first = false; if (clearFirst || v.hadData) v.term.reset(); }
      v.hadData = true;
      v.term.write(new Uint8Array(ev.data));
    };
    ws.onclose = () => {
      if (v.ws !== ws) return;
      v.ws = null;
      if (v.closing) return;
      updateOverlay(v);
      if (!v.tab.running) return;
      const delay = Math.min(30000, 500 * Math.pow(2, v.retry++));
      v.timer = setTimeout(async () => {
        try {
          const tabs = await api("GET", "/api/tabs");
          syncTabs(tabs || []);
          const cur = state.views.get(v.tab.id);
          if (cur === v && v.tab.running && !v.ws) connect(v, false);
        } catch (e) {
          if (!(e instanceof AuthError)) connect(v, false);
        }
      }, delay);
    };
  }

  function updateOverlay(v) {
    const t = v.tab;
    let text = null;
    let restart = false;
    if (!t.running) { text = "The process exited" + (t.exitCode !== undefined && t.exitCode !== null ? " with code " + t.exitCode : "") + "."; restart = true; }
    else if (!v.ws || v.ws.readyState !== WebSocket.OPEN) text = "Reconnecting to the console. The process keeps running on the server.";
    if (!text) { if (v.overlay) { v.overlay.remove(); v.overlay = null; } return; }
    if (!v.overlay) { v.overlay = el("div", "term-overlay"); v.box.appendChild(v.overlay); }
    v.overlay.textContent = "";
    v.overlay.appendChild(el("span", "", text));
    if (restart) {
      const b = el("button", "btn primary small", "Restart");
      b.addEventListener("click", () => restartTab(v.tab));
      v.overlay.appendChild(b);
    }
  }

  function disposeView(v) {
    v.closing = true;
    clearTimeout(v.timer);
    if (v.ws) { try { v.ws.close(); } catch (e) {} v.ws = null; }
    try { v.term.dispose(); } catch (e) {}
    v.box.remove();
  }

  let resizeRaf = 0;
  const ro = new ResizeObserver(() => {
    cancelAnimationFrame(resizeRaf);
    resizeRaf = requestAnimationFrame(() => {
      const v = state.views.get(state.active);
      if (v) fit(v);
    });
  });
  ro.observe($("terminals"));

  // The on-screen keyboard overlays the page (no resize, so the PTY keeps its
  // size). Shift the app up by the covered height so the prompt stays visible.
  const vv = window.visualViewport;
  if (vv) {
    const syncKeyboard = () => {
      const covered = Math.max(0, window.innerHeight - vv.height - vv.offsetTop);
      document.documentElement.style.setProperty("--kb", (covered > 80 ? Math.round(covered) : 0) + "px");
      if (window.scrollY) window.scrollTo(0, 0);
    };
    vv.addEventListener("resize", syncKeyboard);
    vv.addEventListener("scroll", syncKeyboard);
    syncKeyboard();
  }

  setInterval(() => { if (state.signedIn && !document.hidden) renderProjects(); }, 60000);

  (async function boot() {
    try {
      const me = await api("GET", "/api/me");
      if (me && me.authenticated && me.mustEnroll2FA) await showEnroll();
      else if (me && me.authenticated) await showApp();
      else showLogin(me && me.totpEnabled);
    } catch (e) {
      if (!(e instanceof AuthError)) showLogin(false, describe(e));
    }
  })();
})();
