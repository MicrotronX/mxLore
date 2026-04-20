/* ============================================================
   app.js — mxLore Admin UI Application Logic
   Manages views, state, and user interactions
   ============================================================ */

var App = (function () {
  // --- State ---
  var currentDeveloper = null;
  var currentPage = 'developers';
  var selectedForMerge = new Set();
  var selectedProjectsForMerge = new Set();
  var allProjects = [];
  var projectCache = [];
  var editingProjectId = null;
  var currentProjectId = null;
  var projectSortKey = 'last_activity';
  var projectSortDir = 'desc';

  // --- DOM Helpers ---
  function $(sel, ctx) { return (ctx || document).querySelector(sel); }
  function $$(sel, ctx) { return Array.from((ctx || document).querySelectorAll(sel)); }

  function showPage(id) {
    $$('.page').forEach(function (p) { p.classList.remove('active'); });
    var page = $('#page-' + id);
    if (page) page.classList.add('active');
  }

  function showAlert(containerId, type, message) {
    var alert = $('#' + containerId);
    if (!alert) return;
    alert.className = 'alert alert--' + type + ' visible';
    alert.textContent = message;
    setTimeout(function () { alert.classList.remove('visible'); }, 5000);
  }

  function hideAlert(containerId) {
    var alert = $('#' + containerId);
    if (alert) alert.classList.remove('visible');
  }

  // --- Login ---
  function showLogin(message) {
    $('.navbar').classList.remove('visible');
    showPage('login');
    $('#page-login').style.display = 'flex';
    if (message) showAlert('login-alert', 'error', message);
  }

  function setUserUI(name) {
    $('.navbar').classList.add('visible');
    $('.navbar__user').textContent = name;
    var avatar = $('#navbar-avatar');
    if (avatar) avatar.textContent = name.charAt(0).toUpperCase();
  }

  function initLogin() {
    $('#login-form').addEventListener('submit', async function (e) {
      e.preventDefault();
      var keyInput = $('#login-key');
      var btn = $('#login-btn');
      var key = keyInput.value.trim();
      if (!key) return;

      btn.disabled = true;
      btn.innerHTML = '<span class="spinner"></span> Authenticating...';
      hideAlert('login-alert');

      try {
        var data = await Api.login(key);
        Api.setCsrfToken(data.csrf_token);
        setUserUI(data.developer.name);
        $('#page-login').style.display = 'none';
        keyInput.value = '';
        navigateTo('global');
      } catch (err) {
        if (err.message === 'not_admin') {
          showAlert('login-alert', 'error', 'Admin keys only.');
        } else if (err.message === 'ui_login_disabled') {
          showAlert('login-alert', 'error', 'Admin-UI login is disabled for this account. Please use the MCP interface (Claude Code / ChatGPT / claude.ai).');
        } else if (err.message === 'invalid_key') {
          showAlert('login-alert', 'error', 'Invalid API key.');
        } else {
          showAlert('login-alert', 'error', 'Connection error. Is the server reachable?');
        }
      } finally {
        btn.disabled = false;
        btn.innerHTML = 'Sign in';
      }
    });
  }

  function initLogout() {
    $('#btn-logout').addEventListener('click', async function () {
      try { await Api.logout(); } catch (e) { /* ignore */ }
      Api.setCsrfToken('');
      showLogin();
    });
  }

  // --- Developer List ---
  async function loadDeveloperList() {
    showPage('developers');
    selectedForMerge.clear();
    updateMergeBar();

    var tbody = $('#dev-table-body');
    tbody.innerHTML = '<tr><td colspan="9" style="text-align:center;padding:24px"><span class="spinner"></span></td></tr>';

    try {
      var data = await Api.getDevelopers();
      var devs = data.developers || [];
      window._lastDevList = devs;

      if (devs.length === 0) {
        tbody.innerHTML = '<tr><td colspan="9"><div class="empty-state"><div class="empty-state__icon">&#9881;</div>No team members yet</div></td></tr>';
        return;
      }

      // Update stats
      var totalDevs = devs.length;
      var activeDevs = devs.filter(function (d) { return d.is_active; }).length;
      var totalKeys = devs.reduce(function (sum, d) { return sum + (d.key_count || 0); }, 0);
      var totalProjects = devs.reduce(function (sum, d) { return sum + (d.project_count || 0); }, 0);
      animateStat('stat-total', totalDevs);
      animateStat('stat-active', activeDevs);
      animateStat('stat-keys', totalKeys);
      animateStat('stat-projects', totalProjects);

      tbody.innerHTML = devs.map(function (d) {
        var statusClass = d.is_active ? 'active' : 'inactive';
        var statusText = d.is_active ? 'Active' : 'Inactive';
        return '<tr data-id="' + d.id + '">' +
          '<td><input type="checkbox" class="row-check merge-check" data-id="' + d.id + '" data-name="' + escHtml(d.name) + '"></td>' +
          '<td class="text-secondary" style="font-family:monospace;font-size:12px">#' + d.id + '</td>' +
          '<td><span class="cell-link" onclick="App.openDeveloper(' + d.id + ')">' + escHtml(d.name) + '</span></td>' +
          '<td class="text-secondary">' + escHtml(d.email || '\u2014') + '</td>' +
          '<td class="text-secondary">' + escHtml(d.role || '\u2014') + '</td>' +
          '<td class="cell-stat">' + (d.key_count || 0) + '</td>' +
          '<td class="cell-stat">' + (d.project_count || 0) + '</td>' +
          '<td><span class="badge badge--' + statusClass + '">' + statusText + '</span></td>' +
          '<td>' +
            '<button class="btn btn--small btn--ghost" onclick="App.openDeveloper(' + d.id + ')" title="Edit">&#9998;</button>' +
            (d.is_active ? '<button class="btn btn--small btn--danger" onclick="App.confirmDelete(' + d.id + ', \'' + escJsStr(d.name) + '\', false)" title="Deactivate">&#10005;</button>' : '') +
            '<button class="btn btn--small btn--danger" onclick="App.confirmDelete(' + d.id + ', \'' + escJsStr(d.name) + '\', true)" title="Hard Delete" style="opacity:0.6">&#128465;</button>' +
          '</td>' +
        '</tr>';
      }).join('');

      // Merge checkboxes
      $$('.merge-check').forEach(function (cb) {
        cb.addEventListener('change', function () {
          var id = parseInt(this.dataset.id);
          if (this.checked) selectedForMerge.add(id);
          else selectedForMerge.delete(id);
          updateMergeBar();
        });
      });
    } catch (err) {
      if (err.message !== 'session_expired') {
        tbody.innerHTML = '<tr><td colspan="9"><div class="empty-state">Failed to load</div></td></tr>';
      }
    }
  }

  function updateMergeBar() {
    var bar = $('#merge-bar');
    if (selectedForMerge.size >= 2) {
      bar.classList.add('visible');
      $('#merge-count').textContent = selectedForMerge.size + ' members selected';
    } else {
      bar.classList.remove('visible');
    }
  }

  // --- Create Developer Modal ---
  function initCreateDeveloper() {
    $('#btn-new-dev').addEventListener('click', function () {
      $('#modal-new-dev').classList.add('visible');
      $('#new-dev-name').value = '';
      $('#new-dev-email').value = '';
      $('#new-dev-name').focus();
    });

    $('#new-dev-form').addEventListener('submit', async function (e) {
      e.preventDefault();
      var name = $('#new-dev-name').value.trim();
      var email = $('#new-dev-email').value.trim();
      var role = $('#new-dev-role') ? $('#new-dev-role').value : '';
      if (!name) return;

      try {
        var isFirstMember = !window._lastDevList || window._lastDevList.length === 0;
        var resp = await Api.createDeveloper(name, email, role);
        closeModal('modal-new-dev');
        var newDevId = resp && resp.id ? resp.id : 0;

        if (isFirstMember && newDevId) {
          // First member: auto-create admin API key and show it prominently
          var keyResp = await Api.createKey(newDevId, 'Admin Key (auto-created)', 'admin', null);
          var apiKey = keyResp && keyResp.key ? keyResp.key : '';
          if (apiKey) {
            showFirstSetupKey(name, apiKey);
          } else {
            navigateTo('developers');
            loadDeveloperList();
          }
        } else if (newDevId) {
          // Subsequent members: navigate to Connect Team with invite dialog
          await loadConnectPage();
          openNewInviteDialog();
          var sel = $('#invite-developer');
          if (sel) sel.value = String(newDevId);
        }
      } catch (err) {
        showAlert('list-alert', 'error', 'Error: ' + err.message);
      }
    });
  }

  // --- Merge ---
  function initMerge() {
    $('#btn-merge').addEventListener('click', function () {
      if (selectedForMerge.size < 2) return;
      var ids = Array.from(selectedForMerge);

      // Build target selection
      var rows = $$('.merge-check:checked');
      var options = rows.map(function (cb) {
        return '<option value="' + cb.dataset.id + '">' + escHtml(cb.dataset.name) + '</option>';
      }).join('');

      $('#merge-target').innerHTML = options;
      $('#modal-merge').classList.add('visible');
    });

    $('#merge-form').addEventListener('submit', async function (e) {
      e.preventDefault();
      var targetId = parseInt($('#merge-target').value);
      var sourceIds = Array.from(selectedForMerge).filter(function (id) { return id !== targetId; });

      try {
        await Api.mergeDevelopers(sourceIds, targetId);
        closeModal('modal-merge');
        loadDeveloperList();
        showAlert('list-alert', 'success', 'Members merged successfully.');
      } catch (err) {
        showAlert('list-alert', 'error', 'Merge failed: ' + err.message);
      }
    });
  }

  // --- Delete / Deactivate ---
  function confirmDelete(id, name, hard) {
    if (hard) {
      // Find member stats for a detailed warning
      var dev = (window._lastDevList || []).find(function (d) { return d.id === id; });
      var details = '';
      if (dev) {
        var parts = [];
        if (dev.key_count) parts.push(dev.key_count + ' API key(s)');
        if (dev.project_count) parts.push(dev.project_count + ' project assignment(s)');
        if (parts.length) details = '\n\nThis will also delete: ' + parts.join(', ') + '.';
      }
      if (!confirm('PERMANENTLY DELETE "' + name + '"?' + details + '\n\nThis action cannot be undone!')) return;
    } else {
      if (!confirm('Deactivate "' + name + '"?\n\nAll associated API keys will also be deactivated.')) return;
    }
    Api.deleteDeveloper(id, hard).then(function () {
      loadDeveloperList();
      showAlert('list-alert', 'success', hard ? 'Member deleted.' : 'Member deactivated.');
    }).catch(function (err) {
      showAlert('list-alert', 'error', 'Error: ' + err.message);
    });
  }

  // --- Developer Detail ---
  async function openDeveloper(id) {
    showPage('detail');
    setActiveNav('developers');
    currentDeveloper = id;
    location.hash = 'developer/' + id;

    // Reset tabs
    $$('.tab-btn').forEach(function (b) { b.classList.remove('active'); });
    $$('.tab-panel').forEach(function (p) { p.classList.remove('active'); });
    $('.tab-btn[data-tab="info"]').classList.add('active');
    $('#tab-info').classList.add('active');

    // Load developer info
    try {
      var data = await Api.getDevelopers();
      var dev = (data.developers || []).find(function (d) { return d.id === id; });
      if (!dev) { loadDeveloperList(); return; }

      $('#detail-title-name').textContent = dev.name;
      $('#detail-name').value = dev.name;
      $('#detail-email').value = dev.email || '';
      var roleSelect = $('#detail-role');
      if (roleSelect) roleSelect.value = dev.role || '';
      $('#detail-active').checked = dev.is_active;
      applyUiLoginLockMatrix(dev);
    } catch (err) {
      if (err.message !== 'session_expired') loadDeveloperList();
      return;
    }

    loadKeys(id);
    loadProjectAccess(id);
    loadSettings(id);
  }

  function applyUiLoginLockMatrix(dev) {
    var cb = $('#detail-ui-login');
    var hint = $('#detail-ui-login-hint');
    if (!cb) return;
    var level = dev.effective_level || 'none';
    var uiLogin = dev.ui_login_enabled !== false;  // default TRUE per sql/046
    cb.checked = uiLogin;
    cb.disabled = false;
    if (hint) hint.textContent = '';
    switch (level) {
      case 'admin':
        cb.checked = true; cb.disabled = true;
        if (hint) hint.textContent = 'Locked ON — global admin role.';
        break;
      case 'read-write':
        cb.checked = true; cb.disabled = true;
        if (hint) hint.textContent = 'Locked ON — has read-write on at least one project.';
        break;
      case 'read':
        if (hint) hint.textContent = 'Default ON — auditor may opt out.';
        break;
      case 'comment':
        if (hint) hint.textContent = 'Default OFF — reviewer is MCP-only (opt-in for UI).';
        break;
      case 'none':
      default:
        cb.checked = false; cb.disabled = true;
        if (hint) hint.textContent = 'N/A — no project access assigned yet.';
        break;
    }
  }

  function initDetailSave() {
    $('#detail-form').addEventListener('submit', async function (e) {
      e.preventDefault();
      if (!currentDeveloper) return;

      try {
        var roleVal = $('#detail-role') ? $('#detail-role').value : '';
        var uiLoginCb = $('#detail-ui-login');
        var payload = {
          name: $('#detail-name').value.trim(),
          email: $('#detail-email').value.trim() || null,
          role: roleVal || null,
          is_active: $('#detail-active').checked
        };
        if (uiLoginCb && !uiLoginCb.disabled) {
          payload.ui_login_enabled = uiLoginCb.checked;
        }
        await Api.updateDeveloper(currentDeveloper, payload);
        showAlert('detail-alert', 'success', 'Saved.');
        $('#detail-title-name').textContent = $('#detail-name').value.trim();
      } catch (err) {
        showAlert('detail-alert', 'error', 'Error: ' + err.message);
      }
    });
  }

  // --- Tabs ---
  function initTabs() {
    $$('.tab-btn').forEach(function (btn) {
      btn.addEventListener('click', function () {
        $$('.tab-btn').forEach(function (b) { b.classList.remove('active'); });
        $$('.tab-panel').forEach(function (p) { p.classList.remove('active'); });
        btn.classList.add('active');
        $('#tab-' + btn.dataset.tab).classList.add('active');
        // Persist tab in hash
        if (currentDeveloper) location.hash = 'developer/' + currentDeveloper + '/' + btn.dataset.tab;
      });
    });
  }

  // --- Settings / Environments ---
  async function loadSettings(developerId) {
    var tbody = $('#settings-table-body');
    tbody.innerHTML = '<tr><td colspan="5" style="text-align:center;padding:16px"><span class="spinner"></span></td></tr>';

    try {
      var data = await Api.getEnvironments(developerId);
      var envs = data.environments || [];

      if (envs.length === 0) {
        tbody.innerHTML = '<tr><td colspan="5"><div class="empty-state">No environment paths</div></td></tr>';
        return;
      }

      // Group by project, _global first
      var groups = {};
      envs.forEach(function (e) {
        var proj = e.project || '_global';
        if (!groups[proj]) groups[proj] = [];
        groups[proj].push(e);
      });
      var sortedKeys = Object.keys(groups).sort(function (a, b) {
        if (a === '_global') return -1;
        if (b === '_global') return 1;
        return a.localeCompare(b);
      });
      var html = '';
      sortedKeys.forEach(function (proj) {
        html += '<tr><td colspan="4" style="padding:10px 16px 4px;font-weight:600;color:var(--text-bright);border-bottom:2px solid var(--border)">' +
          '<span class="badge" style="margin-right:6px">' + escHtml(proj) + '</span>' +
          '<span class="text-secondary" style="font-weight:400;font-size:0.8rem">' + groups[proj].length + ' entries</span></td></tr>';
        groups[proj].forEach(function (e) {
          html += '<tr>' +
            '<td class="mono">' + escHtml(e.env_key) + '</td>' +
            '<td>' + escHtml(e.env_value) + '</td>' +
            '<td class="text-secondary" style="font-size:0.82rem">' + escHtml(e.key_name || '\u2014') + '</td>' +
            '<td><button class="btn btn--small btn--danger" onclick="App.deleteEnvironment(' + e.id + ',' + developerId + ')" title="Delete">' +
            'Delete</button></td>' +
            '</tr>';
        });
      });
      tbody.innerHTML = html;
    } catch (err) {
      if (err.message !== 'session_expired')
        tbody.innerHTML = '<tr><td colspan="5"><div class="empty-state">Error: ' + escHtml(err.message) + '</div></td></tr>';
    }
  }

  async function deleteEnvironment(envId, developerId) {
    if (!confirm('Delete environment path?')) return;
    try {
      await Api.deleteEnvironment(envId);
      loadSettings(developerId);
    } catch (err) {
      alert('Error: ' + err.message);
    }
  }

  // --- Keys ---
  async function loadKeys(developerId) {
    var tbody = $('#keys-table-body');
    tbody.innerHTML = '<tr><td colspan="6" style="text-align:center;padding:16px"><span class="spinner"></span></td></tr>';

    try {
      var data = await Api.getKeys(developerId);
      var keys = data.keys || [];

      if (keys.length === 0) {
        tbody.innerHTML = '<tr><td colspan="6"><div class="empty-state">No API keys</div></td></tr>';
        return;
      }

      tbody.innerHTML = keys.map(function (k) {
        var roleClass = k.permissions === 'admin' ? 'admin' : (k.permissions === 'readwrite' ? 'write' : 'read');
        var statusClass = k.is_active ? 'active' : 'inactive';
        var roleSelect = '<select class="form-input" style="width:auto;min-width:100px;padding:2px 22px 2px 6px;font-size:0.78rem" onchange="App.changeKeyRole(' + k.id + ',this.value)">' +
          '<option value="read"' + (k.permissions === 'read' ? ' selected' : '') + '>read</option>' +
          '<option value="readwrite"' + (k.permissions === 'readwrite' ? ' selected' : '') + '>readwrite</option>' +
          '<option value="admin"' + (k.permissions === 'admin' ? ' selected' : '') + '>admin</option>' +
          '</select>';
        var actions = '';
        if (k.is_active)
          actions += '<button class="btn btn--small btn--danger" onclick="App.deactivateKey(' + k.id + ')">Deactivate</button> ';
        actions += '<button class="btn btn--small btn--danger" onclick="App.hardDeleteKey(' + k.id + ')" title="Delete permanently">Delete</button>';
        return '<tr>' +
          '<td class="mono">' + escHtml(k.name) + '</td>' +
          '<td class="mono text-secondary" style="font-size:0.78rem">' + escHtml(k.key_prefix || '\u2014') + '</td>' +
          '<td>' + roleSelect + '</td>' +
          '<td class="text-secondary mono" style="font-size:0.78rem">' + formatDate(k.last_used_at) + '</td>' +
          '<td class="text-secondary mono" style="font-size:0.78rem">' + escHtml(k.last_used_ip || '\u2014') + '</td>' +
          '<td><span class="badge badge--' + statusClass + '">' + (k.is_active ? 'Active' : 'Inactive') + '</span></td>' +
          '<td>' + actions + '</td>' +
        '</tr>';
      }).join('');
    } catch (err) { /* handled by session check */ }
  }

  function initCreateKey() {
    $('#btn-new-key').addEventListener('click', function () {
      $('#modal-new-key').classList.add('visible');
      $('#new-key-name').value = '';
      $('#new-key-permissions').value = 'readwrite';
      $('#new-key-expires').value = '';
      $('#key-reveal').classList.remove('visible');
      var genBtn = $('#btn-generate-key');
      if (genBtn) { genBtn.disabled = false; genBtn.style.display = ''; }
      $('#new-key-name').disabled = false;
      $('#new-key-permissions').disabled = false;
      $('#new-key-expires').disabled = false;
      $('#new-key-name').focus();
    });

    $('#new-key-form').addEventListener('submit', async function (e) {
      e.preventDefault();
      if (!currentDeveloper) return;

      var name = $('#new-key-name').value.trim();
      var permissions = $('#new-key-permissions').value;
      var expires = $('#new-key-expires').value || null;
      if (!name) return;

      try {
        var data = await Api.createKey(currentDeveloper, name, permissions, expires);
        // Show the key ONE TIME
        $('#key-reveal-value').textContent = data.key;
        $('#key-reveal').classList.add('visible');
        // Hide Generate button completely + disable inputs to prevent double-submit
        var genBtn = $('#btn-generate-key');
        if (genBtn) { genBtn.disabled = true; genBtn.style.display = 'none'; }
        $('#new-key-name').disabled = true;
        $('#new-key-permissions').disabled = true;
        $('#new-key-expires').disabled = true;
        loadKeys(currentDeveloper);
      } catch (err) {
        showAlert('detail-alert', 'error', 'Key creation failed: ' + err.message);
        closeModal('modal-new-key');
      }
    });

    $('#btn-copy-key').addEventListener('click', function () {
      var key = $('#key-reveal-value').textContent;
      navigator.clipboard.writeText(key).then(function () {
        $('#btn-copy-key').textContent = 'Kopiert!';
        setTimeout(function () { $('#btn-copy-key').textContent = 'Copy'; }, 2000);
      });
    });
  }

  function deactivateKey(keyId) {
    if (!confirm('Deactivate this API key?')) return;
    Api.deleteKey(keyId).then(function () {
      loadKeys(currentDeveloper);
    }).catch(function (err) {
      showAlert('detail-alert', 'error', 'Error: ' + err.message);
    });
  }

  function hardDeleteKey(keyId) {
    if (!confirm('PERMANENTLY delete API key? All associated environment paths will also be deleted.')) return;
    Api.deleteKey(keyId, true).then(function () {
      loadKeys(currentDeveloper);
      loadSettings(currentDeveloper);
    }).catch(function (err) {
      showAlert('detail-alert', 'error', 'Error: ' + err.message);
    });
  }

  function changeKeyRole(keyId, newRole) {
    Api.updateKey(keyId, newRole).then(function () {
      showAlert('detail-alert', 'success', 'Rolle geaendert.');
    }).catch(function (err) {
      showAlert('detail-alert', 'error', 'Error: ' + err.message);
      loadKeys(currentDeveloper);
    });
  }

  // --- Project Access ---
  async function loadProjectAccess(developerId) {
    var container = $('#access-grid');
    container.innerHTML = '<div style="text-align:center;padding:16px"><span class="spinner"></span></div>';

    try {
      // Load all projects + current assignments in parallel
      var results = await Promise.all([
        Api.getProjects(),
        Api.getDeveloperProjects(developerId)
      ]);

      allProjects = (results[0].projects || []).filter(function (p) { return p.is_active !== false; });
      var assigned = results[1].projects || [];
      var accessMap = {};
      assigned.forEach(function (a) { accessMap[a.project_id] = a.access_level; });

      if (allProjects.length === 0) {
        container.innerHTML = '<div class="empty-state">No projects yet</div>';
        return;
      }

      container.innerHTML = allProjects.map(function (p) {
        var level = accessMap[p.id] || '';
        // 4-Level ACL per ADR#3264 (none/comment/read/read-write)
        return '<div class="access-row" data-project-id="' + p.id + '">' +
          '<div class="access-row__project">' + escHtml(p.name) + '<span class="slug">' + escHtml(p.slug) + '</span></div>' +
          '<select class="form-input access-select" data-project-id="' + p.id + '">' +
            '<option value=""'           + (level === ''           ? ' selected' : '') + '>Kein Zugriff</option>' +
            '<option value="comment"'    + (level === 'comment'    ? ' selected' : '') + '>Comment</option>' +
            '<option value="read"'       + (level === 'read'       ? ' selected' : '') + '>Read</option>' +
            '<option value="read-write"' + (level === 'read-write' ? ' selected' : '') + '>Read/Write</option>' +
          '</select>' +
        '</div>';
      }).join('');
    } catch (err) { /* handled by session check */ }
  }

  function initSaveAccess() {
    $('#btn-save-access').addEventListener('click', async function () {
      if (!currentDeveloper) return;
      var btn = this;
      btn.disabled = true;
      btn.innerHTML = '<span class="spinner"></span> Saving...';

      var projects = [];
      $$('.access-select').forEach(function (sel) {
        var level = sel.value;
        if (level) {
          projects.push({
            project_id: parseInt(sel.dataset.projectId),
            access_level: level
          });
        }
      });

      try {
        await Api.updateDeveloperProjects(currentDeveloper, projects);
        showAlert('detail-alert', 'success', 'Assignments saved.');
      } catch (err) {
        showAlert('detail-alert', 'error', 'Error: ' + err.message);
      } finally {
        btn.disabled = false;
        btn.innerHTML = 'Save assignments';
      }
    });
  }

  // Set navbar active-state without loading a page (for detail views)
  function setActiveNav(navKey) {
    $$('.nav-link').forEach(function (btn) {
      if (btn.dataset.nav === navKey) btn.classList.add('active');
      else btn.classList.remove('active');
    });
  }

  // --- Navigation ---
  function navigateTo(page) {
    currentPage = page;
    location.hash = page;
    setActiveNav(page);

    if (page === 'developers') {
      loadDeveloperList();
    } else if (page === 'projects') {
      loadProjectList();
    } else if (page === 'global') {
      loadGlobalPage();
    } else if (page === 'intelligence') {
      loadSkillsPage();
    } else if (page === 'settings') {
      loadSettingsPage();
    } else if (page === 'connect') {
      loadConnectPage();
    }
  }

  // ============================================================
  //   SETTINGS PAGE (v2.4.0 + FR#3296 tabbed)
  // ============================================================
  // FR#3296 — Settings-Page tab switching (mirrors switchDocTab).
  function switchSettingsTab(tabName, skipHashUpdate) {
    var valid = ['self-update', 'connect', 'syslog'];
    if (valid.indexOf(tabName) < 0) tabName = 'self-update';
    $$('#page-settings .pd-tab').forEach(function (btn) {
      var on = btn.dataset.tab === tabName;
      btn.classList.toggle('is-active', on);
      btn.setAttribute('aria-selected', on ? 'true' : 'false');
      btn.setAttribute('tabindex', on ? '0' : '-1');
    });
    $$('#page-settings .pd-tab-panel').forEach(function (panel) {
      var on = panel.dataset.panel === tabName;
      panel.classList.toggle('is-active', on);
      if (on) panel.removeAttribute('hidden');
      else panel.setAttribute('hidden', '');
    });
    if (!skipHashUpdate) {
      location.hash = 'settings' + (tabName !== 'self-update' ? '/' + tabName : '');
    }
    Icons.render();
  }

  async function loadSettingsPage() {
    showPage('settings');
    var alertEl = $('#settings-alert');
    if (alertEl) alertEl.style.display = 'none';
    try {
      var resp = await Api.getSettings();
      var map = {};
      (resp.settings || []).forEach(function (s) { map[s.key] = s.value; });

      $('#setting-internal-host').value = map['connect.internal_host'] || '';
      $('#setting-external-mcp-url').value = map['connect.external_mcp_url'] || '';
      $('#setting-external-admin-url').value = map['connect.external_admin_url'] || '';
      $('#setting-trusted-proxies').value = map['connect.trusted_proxies'] || '';

      var hint = $('#setting-internal-host-hint');
      if (hint) {
        if (!map['connect.internal_host']) {
          hint.textContent = '\u26A0 Not configured \u2014 auto-detect will be used at runtime';
          hint.style.color = 'var(--amber)';
        } else {
          hint.textContent = '';
          hint.style.color = '';
        }
      }
    } catch (e) {
      showSettingsAlert('error', 'Failed to load settings: ' + (e.message || e));
    }
  }

  async function saveSettings(ev) {
    if (ev) ev.preventDefault();
    var payload = {
      'connect.internal_host': $('#setting-internal-host').value.trim(),
      'connect.external_mcp_url': $('#setting-external-mcp-url').value.trim(),
      'connect.external_admin_url': $('#setting-external-admin-url').value.trim(),
      'connect.trusted_proxies': $('#setting-trusted-proxies').value.trim()
    };
    try {
      await Api.saveSettings(payload);
      showSettingsAlert('success', 'Settings saved successfully.');
      loadSettingsPage();
    } catch (e) {
      showSettingsAlert('error', 'Save failed: ' + (e.message || e));
    }
  }

  async function testConnection(which) {
    var url = '';
    var mode = '';
    if (which === 'internal') {
      var host = $('#setting-internal-host').value.trim();
      if (!host) {
        showSettingsAlert('warning', 'Enter an Internal Host first, or leave empty for auto-detect.');
        return;
      }
      var mcpPort = (parseInt(window.location.port, 10) || 8081) - 1;
      url = 'http://' + host + ':' + mcpPort + '/mcp';
      mode = 'mcp';
    } else if (which === 'external-mcp') {
      url = $('#setting-external-mcp-url').value.trim();
      mode = 'mcp';
    } else if (which === 'external-admin') {
      url = $('#setting-external-admin-url').value.trim();
      mode = 'http';
    }
    if (!url) {
      showSettingsAlert('warning', 'No URL configured for this test.');
      return;
    }
    showSettingsAlert('info', 'Testing ' + url + ' ...');
    try {
      var resp = await Api.testConnection(url, mode);
      var kindLabel = (resp.kind === 'mcp') ? 'MCP' : 'HTTP';
      var info = 'HTTP ' + resp.status_code + ', ' + resp.latency_ms + 'ms';
      if (resp.ok) {
        var extra = '';
        if (resp.server_name) {
          extra = ' — ' + resp.server_name;
          if (resp.server_version) extra += ' v' + resp.server_version;
        }
        if (resp.error) extra += ' (' + resp.error + ')';
        showSettingsAlert('success',
          '\u2713 ' + kindLabel + ' endpoint reachable (' + info + ')' + extra);
      } else {
        showSettingsAlert('error',
          '\u2717 ' + kindLabel + ' test failed: ' + (resp.error || info));
      }
    } catch (e) {
      showSettingsAlert('error', 'Test failed: ' + (e.message || e));
    }
  }

  function showSettingsAlert(level, text) {
    var el = $('#settings-alert');
    if (!el) return;
    el.className = 'alert alert--' + level;
    el.textContent = text;
    el.style.display = 'block';
  }

  // ============================================================
  //   CONNECT TEAM PAGE (v2.4.0)
  // ============================================================
  var connectDevelopers = [];  // cached for dropdown + lookup

  async function loadConnectPage() {
    showPage('connect');
    var alertEl = $('#connect-alert');
    if (alertEl) alertEl.style.display = 'none';

    // Fetch developers (for dropdown + name lookup) and invite list in parallel
    try {
      var devsResp = await Api.getDevelopers();
      connectDevelopers = (devsResp.developers || []).filter(function (d) {
        return d.is_active;  // only active devs
      });
    } catch (e) {
      connectDevelopers = [];
      showConnectAlert('error', 'Failed to load developers: ' + (e.message || e));
    }

    await refreshInviteLists();
    if (window.lucide) window.lucide.createIcons();
  }

  async function refreshInviteLists() {
    try {
      var resp = await Api.listInvites('all');
      var invites = resp.invites || [];
      var devMap = {};
      connectDevelopers.forEach(function (d) { devMap[d.id] = d.name; });

      var activeStream = $('#connect-active-stream');
      var historyBody = $('#connect-history-body');
      var activeCards = [];
      var historyRows = [];

      invites.forEach(function (inv) {
        var devName = devMap[inv.developer_id] || ('Dev #' + inv.developer_id);
        if (inv.status === 'active') {
          activeCards.push(renderActiveInviteCard(inv, devName, activeCards.length));
        } else {
          historyRows.push(renderHistoryInviteRow(inv, devName));
        }
      });

      activeStream.innerHTML = activeCards.length
        ? activeCards.join('')
        : renderEmptyActiveState();

      historyBody.innerHTML = historyRows.length
        ? historyRows.join('')
        : '<tr><td colspan="6" class="table-empty">No expired or revoked invites yet</td></tr>';

      // Re-initialize lucide icons in case we injected any data-lucide attrs
      if (window.lucide && typeof window.lucide.createIcons === 'function') {
        window.lucide.createIcons();
      }
    } catch (e) {
      showConnectAlert('error', 'Failed to load invites: ' + (e.message || e));
    }
  }

  function renderActiveInviteCard(inv, devName, index) {
    var viewed    = !!inv.first_viewed_at;
    var confirmed = !!inv.confirmed_at;
    var expiry    = computeExpiryInfo(inv.expires_at);
    var delay     = (index * 50) + 'ms';

    // Lifecycle strip: 3 steps, each with done/pending state
    var lifecycle =
      '<div class="lifecycle-track">' +
        '<div class="lifecycle-step lifecycle-step--done">' +
          '<span class="lifecycle-dot"></span>' +
          '<span class="lifecycle-label">invited</span>' +
        '</div>' +
        '<div class="lifecycle-link' + (viewed ? ' lifecycle-link--done' : '') + '"></div>' +
        '<div class="lifecycle-step' + (viewed ? ' lifecycle-step--done' : '') + '">' +
          '<span class="lifecycle-dot"></span>' +
          '<span class="lifecycle-label">viewed</span>' +
        '</div>' +
        '<div class="lifecycle-link' + (confirmed ? ' lifecycle-link--done' : '') + '"></div>' +
        '<div class="lifecycle-step' + (confirmed ? ' lifecycle-step--done' : '') + '">' +
          '<span class="lifecycle-dot"></span>' +
          '<span class="lifecycle-label">confirmed</span>' +
        '</div>' +
      '</div>';

    var ipBlock = inv.consumer_ip
      ? '<svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><line x1="2" y1="12" x2="22" y2="12"/><path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"/></svg>' +
        '<span class="mono">' + escapeHtml(inv.consumer_ip) + '</span>'
      : '<span class="invite-card__ip--none">no one opened this yet</span>';

    return (
      '<article class="invite-card" style="animation-delay:' + delay + '">' +
        '<header class="invite-card__top">' +
          '<div class="invite-card__identity">' +
            '<div class="invite-card__name">' + escapeHtml(devName) + '</div>' +
            '<div class="invite-card__mode">' +
              '<span class="mode-pill mode-pill--' + escapeHtml(inv.mode) + '">' + escapeHtml(inv.mode) + '</span>' +
              '<span class="invite-card__created">invited ' + formatRelativeTime(inv.created_at) + '</span>' +
            '</div>' +
          '</div>' +
          '<button type="button" class="invite-card__revoke" onclick="App.revokeInvite(' + inv.id + ')" title="Revoke this invite" aria-label="Revoke">' +
            '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>' +
          '</button>' +
        '</header>' +

        '<div class="invite-card__lifecycle">' + lifecycle + '</div>' +

        '<footer class="invite-card__foot">' +
          '<div class="invite-card__expiry invite-card__expiry--' + expiry.urgency + '">' +
            '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/></svg>' +
            '<span class="invite-card__expiry-label">expires in ' + expiry.label + '</span>' +
            '<div class="invite-card__expiry-bar"><div class="invite-card__expiry-fill" style="width:' + expiry.percent + '%"></div></div>' +
          '</div>' +
          '<div class="invite-card__ip">' + ipBlock + '</div>' +
        '</footer>' +
      '</article>'
    );
  }

  function renderHistoryInviteRow(inv, devName) {
    return (
      '<tr>' +
      '<td><span class="history-name">' + escapeHtml(devName) + '</span></td>' +
      '<td><span class="mode-pill mode-pill--' + escapeHtml(inv.mode) + '">' + escapeHtml(inv.mode) + '</span></td>' +
      '<td><span class="history-status history-status--' + escapeHtml(inv.status) + '">' + escapeHtml(inv.status) + '</span></td>' +
      '<td class="history-time">' + formatRelativeTime(inv.created_at) + '</td>' +
      '<td class="mono muted">' + (inv.consumer_ip ? escapeHtml(inv.consumer_ip) : '\u2014') + '</td>' +
      '<td><button type="button" class="btn btn--ghost btn--xs" onclick="App.deleteInvite(' + inv.id + ')" title="Delete">' +
        '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/></svg>' +
      '</button></td>' +
      '</tr>'
    );
  }

  function renderEmptyActiveState() {
    return (
      '<div class="invite-empty">' +
        '<div class="invite-empty__glyph">' +
          '<svg width="36" height="36" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/></svg>' +
        '</div>' +
        '<h4>No active invites</h4>' +
        '<p>Generate an invite link to onboard a team member. The recipient picks their client and connects in under a minute — no manual config.</p>' +
        '<button type="button" class="btn btn--primary" onclick="App.openNewInviteDialog()">' +
          '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>' +
          'New Invite' +
        '</button>' +
      '</div>'
    );
  }

  // --- Time / expiry helpers for the invite stream ---

  function formatRelativeTime(iso) {
    if (!iso) return '—';
    var t;
    try {
      // Support German DD.MM.YYYY HH:MM format (same parser as formatDate)
      var parts = typeof iso === 'string'
        ? iso.match(/(\d{2})\.(\d{2})\.(\d{4})\s+(\d{2}):(\d{2})/) : null;
      if (parts) {
        t = new Date(parts[3], parts[2] - 1, parts[1], parts[4], parts[5]).getTime();
      } else {
        t = new Date(iso).getTime();
      }
    } catch (e) { return iso; }
    if (isNaN(t)) return iso;
    var diff = Date.now() - t;
    var past = diff >= 0;
    var abs = Math.abs(diff);

    var sec = Math.floor(abs / 1000);
    if (sec < 60)   return past ? 'just now'    : 'in a moment';
    var min = Math.floor(sec / 60);
    if (min < 60)   return past ? min + 'm ago' : 'in ' + min + 'm';
    var hr = Math.floor(min / 60);
    if (hr < 24)    return past ? hr + 'h ago'  : 'in ' + hr + 'h';
    var day = Math.floor(hr / 24);
    if (day < 30)   return past ? day + 'd ago' : 'in ' + day + 'd';
    var mo = Math.floor(day / 30);
    return past ? mo + 'mo ago' : 'in ' + mo + 'mo';
  }

  function computeExpiryInfo(iso) {
    if (!iso) return { label: 'unknown', urgency: 'unknown', percent: 0 };
    var t;
    try { t = new Date(iso).getTime(); } catch (e) { return { label: iso, urgency: 'unknown', percent: 0 }; }
    if (isNaN(t)) return { label: 'unknown', urgency: 'unknown', percent: 0 };

    var diffMs = t - Date.now();
    if (diffMs <= 0) return { label: 'now', urgency: 'urgent', percent: 0 };

    var totalHours = Math.floor(diffMs / 3600000);
    var days = Math.floor(totalHours / 24);
    var label;
    if (days > 0) {
      var remHr = totalHours % 24;
      label = days + 'd' + (remHr > 0 ? ' ' + remHr + 'h' : '');
    } else if (totalHours > 0) {
      label = totalHours + 'h';
    } else {
      label = Math.max(1, Math.floor(diffMs / 60000)) + 'm';
    }

    var urgency;
    if (totalHours < 1)       urgency = 'urgent';
    else if (totalHours < 24) urgency = 'soon';
    else                      urgency = 'comfortable';

    // Percent of the bar: 48h = full (typical invite window)
    var percent = Math.min(100, Math.max(4, (totalHours / 48) * 100));
    return { label: label, urgency: urgency, percent: Math.round(percent) };
  }

  function openNewInviteDialog() {
    // Populate developer dropdown from cache
    var select = $('#invite-developer');
    select.innerHTML = connectDevelopers.length
      ? connectDevelopers.map(function (d) {
          return '<option value="' + d.id + '">' + escapeHtml(d.name) + '</option>';
        }).join('')
      : '<option value="">No developers available</option>';

    // Reset form
    $('#invite-key-name').value = '';
    $('#invite-permissions').value = 'readwrite';
    $('#invite-expires').value = '48';
    var extRadio = document.querySelector('input[name="invite-mode"][value="external"]');
    if (extRadio) extRadio.checked = true;

    // Hide any leftover error from previous attempt
    var alert = $('#new-invite-alert');
    if (alert) alert.style.display = 'none';

    $('#modal-new-invite').classList.add('visible');
  }

  function showNewInviteAlert(level, text) {
    var el = $('#new-invite-alert');
    if (!el) return;
    el.className = 'alert alert--' + level;
    el.textContent = text;
    el.style.display = 'block';
  }

  async function onNewInviteSubmit(ev) {
    ev.preventDefault();
    var devId = parseInt($('#invite-developer').value, 10);
    if (!devId) {
      showNewInviteAlert('error', 'Please select a developer');
      return;
    }
    var payload = {
      developer_id: devId,
      key_name: $('#invite-key-name').value.trim() || ('invite-' + new Date().toISOString().slice(0, 16).replace(/[-:T]/g, '')),
      permissions: $('#invite-permissions').value,
      expires_hours: parseInt($('#invite-expires').value, 10),
      mode: (document.querySelector('input[name="invite-mode"]:checked') || {}).value || 'external'
    };
    try {
      var resp = await Api.createInvite(payload);
      $('#modal-new-invite').classList.remove('visible');
      showInviteResultDialog(resp, payload);
      await refreshInviteLists();
    } catch (e) {
      // Show the error IN the modal so it stays visible while the user fixes it.
      showNewInviteAlert('error', 'Failed to create invite: ' + (e.message || e));
    }
  }

  function showInviteResultDialog(resp, payload) {
    // Backend now builds the invite URL from connect.external_admin_url
    // (mode=external) or the request host (mode=internal / fallback).
    // We only use resp.invite_url directly — no more window.location guessing.
    var inviteUrl = resp.invite_url || '(backend did not return invite_url)';

    $('#invite-result-link').value = inviteUrl;
    $('#invite-result-key').value = resp.api_key;

    // Show warning alert if backend flagged a URL fallback (e.g. mode=external
    // but external_admin_url not configured → uses local host, which the
    // recipient probably cannot reach).
    var alertEl = $('#invite-result-alert');
    if (resp.url_warning) {
      if (alertEl) {
        alertEl.className = 'alert alert--warning';
        alertEl.textContent = '\u26A0 ' + resp.url_warning;
        alertEl.style.display = 'block';
      }
    } else if (alertEl) {
      alertEl.style.display = 'none';
    }

    var devName = 'team member';
    connectDevelopers.forEach(function (d) {
      if (d.id === payload.developer_id) devName = d.name;
    });
    var hours = payload.expires_hours;
    var expiryStr = hours >= 24 ? (Math.floor(hours / 24) + ' day' + (hours >= 48 ? 's' : '')) : (hours + ' hours');

    var modeNote = payload.mode === 'internal'
      ? '\n\nNote: this is an internal (LAN) link — you must be on the same network as the server.'
      : '';
    $('#invite-result-email').value =
      'Subject: Connect to mxLore — Your AI Knowledge Base\n\n' +
      'Hi ' + devName + ',\n\n' +
      'You\'ve been invited to connect to our mxLore MCP server.\n' +
      'Click this link to see setup instructions for your client:\n\n' +
      '  ' + inviteUrl + '\n\n' +
      'Works with Claude Desktop, Claude Code, Cursor, Windsurf, and any MCP client.\n' +
      'Setup takes less than a minute.\n\n' +
      'This link expires in ' + expiryStr + '.' + modeNote;

    $('#modal-invite-result').classList.add('visible');
  }

  function copyInviteField(elementId) {
    var el = $('#' + elementId);
    if (!el) return;
    el.select();
    el.setSelectionRange(0, 999999);
    try {
      document.execCommand('copy');
      el.blur();
      // Visual feedback
      var original = el.style.background;
      el.style.background = 'rgba(0, 255, 136, 0.15)';
      setTimeout(function () { el.style.background = original; }, 400);
    } catch (e) { /* ignore */ }
  }

  async function revokeInvite(inviteId) {
    if (!confirm('Revoke this invite? The link will stop working immediately.')) return;
    try {
      await Api.deleteInvite(inviteId);
      showConnectAlert('success', 'Invite revoked.');
      await refreshInviteLists();
    } catch (e) {
      showConnectAlert('error', 'Failed to revoke: ' + (e.message || e));
    }
  }

  async function deleteInvite(inviteId) {
    if (!confirm('Permanently delete this invite record?')) return;
    try {
      await Api.deleteInvite(inviteId);
      showConnectAlert('success', 'Invite deleted.');
      await refreshInviteLists();
    } catch (e) {
      showConnectAlert('error', 'Failed to delete: ' + (e.message || e));
    }
  }

  async function cleanupInvites() {
    if (!confirm('Delete all expired and revoked invites?')) return;
    try {
      var resp = await Api.cleanupInvites();
      showConnectAlert('success', (resp.deleted_count || 0) + ' inactive invites removed.');
      await refreshInviteLists();
    } catch (e) {
      showConnectAlert('error', 'Cleanup failed: ' + (e.message || e));
    }
  }

  // --- First Setup: show admin API key after creating first member ---
  function showFirstSetupKey(memberName, apiKey) {
    var html =
      '<div class="modal-overlay visible" id="modal-first-setup" style="z-index:9999">' +
        '<div class="modal" style="max-width:560px">' +
          '<div class="modal__header">' +
            '<span class="modal__title">' +
              '\u2705 Setup Complete' +
            '</span>' +
          '</div>' +
          '<div class="modal__body">' +
            '<p style="margin-bottom:12px"><strong>' + escapeHtml(memberName) + '</strong> created with admin API key:</p>' +
            '<div style="background:var(--bg-surface);border:1px solid var(--border);border-radius:6px;padding:10px 14px;font-family:var(--font-mono);font-size:0.88rem;word-break:break-all;user-select:all;margin-bottom:12px" id="first-setup-key">' +
              escapeHtml(apiKey) +
            '</div>' +
            '<button type="button" class="btn btn--primary" style="width:100%;margin-bottom:12px" onclick="' +
              'var t=document.getElementById(\'first-setup-key\').textContent;' +
              'navigator.clipboard.writeText(t)' +
              '.then(function(){this.textContent=\'Copied!\'}.bind(this))' +
              '.catch(function(){window.prompt(\'Copy this key:\',t)})' +
            '">' +
              '\uD83D\uDCCB Copy API Key' +
            '</button>' +
            '<div class="alert alert--warning visible" style="margin:0">' +
              '<strong>Save this key now!</strong> It cannot be shown again. ' +
              'Use it to connect Claude Code, claude.ai, Cursor, or other MCP clients.' +
            '</div>' +
          '</div>' +
          '<div class="modal__footer">' +
            '<button type="button" class="btn btn--primary" onclick="' +
              'document.getElementById(\'modal-first-setup\').remove();' +
              'App.navigateTo(\'connect\');' +
            '">Continue to Connect Team</button>' +
          '</div>' +
        '</div>' +
      '</div>';
    document.body.insertAdjacentHTML('beforeend', html);
  }

  function showConnectAlert(level, text) {
    var el = $('#connect-alert');
    if (!el) return;
    el.className = 'alert alert--' + level;
    el.textContent = text;
    el.style.display = 'block';
  }

  function formatIsoDate(iso) {
    if (!iso) return '—';
    try {
      var d = new Date(iso);
      return d.toLocaleString();
    } catch (e) {
      return iso;
    }
  }

  function escapeHtml(s) {
    if (s == null) return '';
    return String(s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  // --- Back to List ---
  function initBackButton() {
    $('#btn-back').addEventListener('click', function () {
      navigateTo('developers');
    });
  }

  // ============================================================
  //   PROJECT LIST
  // ============================================================
  function parseDE(dateStr) {
    if (!dateStr) return 0;
    var p = dateStr.match(/(\d{2})\.(\d{2})\.(\d{4})\s+(\d{2}):(\d{2})/);
    if (p) return new Date(p[3], p[2] - 1, p[1], p[4], p[5]).getTime();
    var d = new Date(dateStr);
    return isNaN(d.getTime()) ? 0 : d.getTime();
  }

  var dateSortKeys = { last_activity: 1, created_at: 1, deleted_at: 1 };

  function sortProjects(projects, key, dir) {
    return projects.slice().sort(function (a, b) {
      var va = a[key], vb = b[key];
      // nulls/undefined last
      if (va == null && vb == null) return 0;
      if (va == null) return 1;
      if (vb == null) return -1;
      // date columns — parse to timestamp for correct sort
      if (dateSortKeys[key]) {
        var ta = parseDE(va), tb = parseDE(vb);
        return dir === 'asc' ? ta - tb : tb - ta;
      }
      // numeric
      if (typeof va === 'number' && typeof vb === 'number') {
        return dir === 'asc' ? va - vb : vb - va;
      }
      // boolean (status)
      if (typeof va === 'boolean') {
        return dir === 'asc' ? (va === vb ? 0 : va ? -1 : 1) : (va === vb ? 0 : va ? 1 : -1);
      }
      // string
      va = String(va).toLowerCase();
      vb = String(vb).toLowerCase();
      var cmp = va < vb ? -1 : va > vb ? 1 : 0;
      return dir === 'asc' ? cmp : -cmp;
    });
  }

  function renderProjectTable() {
    var tbody = $('#proj-table-body');
    var sorted = sortProjects(projectCache, projectSortKey, projectSortDir);

    tbody.innerHTML = sorted.map(function (p) {
      var statusClass = p.is_active ? 'active' : 'inactive';
      var statusText = p.is_active ? 'Active' : 'Inactive';
      var lastAct = p.last_activity ? formatDate(p.last_activity) : '\u2014';
      return '<tr data-id="' + p.id + '" data-creator="' + escHtml(p.created_by_name || '') + '">' +
        '<td><input type="checkbox" class="row-check proj-merge-check" data-id="' + p.id + '" data-name="' + escHtml(p.name) + '"' + (p.is_active ? '' : ' disabled') + '></td>' +
        '<td><span class="cell-link" onclick="App.openProject(' + p.id + ')">' + escHtml(p.name) + '</span></td>' +
        '<td class="mono text-secondary">' + escHtml(p.slug) + '</td>' +
        '<td class="cell-stat">' + (p.doc_count || 0) + '</td>' +
        '<td class="cell-stat">' + (p.developer_count || 0) + '</td>' +
        '<td class="text-secondary" style="font-size:0.82rem">' + escHtml(p.created_by_name || '\u2014') + '</td>' +
        '<td class="text-secondary" style="font-size:0.82rem">' + lastAct + '</td>' +
        '<td><span class="badge badge--' + statusClass + '">' + statusText + '</span></td>' +
        '<td>' +
          '<button class="btn btn--small btn--ghost" onclick="App.openProject(' + p.id + ')" title="Details">&#9998;</button>' +
          (p.is_active ? '<button class="btn btn--small btn--danger" onclick="App.confirmDeleteProject(' + p.id + ', \'' + escJsStr(p.name) + '\', false)" title="Deactivate">&#10005;</button>' : '') +
          '<button class="btn btn--small btn--danger" onclick="App.confirmDeleteProject(' + p.id + ', \'' + escJsStr(p.name) + '\', true)" title="Hard Delete" style="opacity:0.6">&#128465;</button>' +
        '</td>' +
      '</tr>';
    }).join('');

    // Merge checkboxes
    $$('.proj-merge-check').forEach(function (cb) {
      cb.addEventListener('change', function () {
        var id = parseInt(this.dataset.id);
        if (this.checked) selectedProjectsForMerge.add(id);
        else selectedProjectsForMerge.delete(id);
        updateProjectMergeBar();
      });
    });

    Icons.render();
  }

  function initProjectSortHeaders() {
    $$('.data-table th.sortable').forEach(function (th) {
      th.onclick = function () {
        var key = this.dataset.sort;
        if (projectSortKey === key) {
          projectSortDir = projectSortDir === 'asc' ? 'desc' : 'asc';
        } else {
          projectSortKey = key;
          projectSortDir = (key === 'last_activity' || key === 'doc_count' || key === 'developer_count') ? 'desc' : 'asc';
        }
        // Update header classes
        $$('.data-table th.sortable').forEach(function (h) {
          h.classList.remove('sort-active', 'sort-asc', 'sort-desc');
        });
        this.classList.add('sort-active', 'sort-' + projectSortDir);
        renderProjectTable();
      };
    });
  }

  async function loadProjectList() {
    showPage('projects');
    selectedProjectsForMerge.clear();
    updateProjectMergeBar();

    var tbody = $('#proj-table-body');
    tbody.innerHTML = '<tr><td colspan="9" style="text-align:center;padding:24px"><span class="spinner"></span></td></tr>';

    try {
      var data = await Api.getProjects();
      var projects = data.projects || [];

      if (projects.length === 0) {
        tbody.innerHTML = '<tr><td colspan="9"><div class="empty-state"><div class="empty-state__icon">&#128193;</div>No projects yet. Run <code>/mxInitProject</code> in your project directory to register the first one.</div></td></tr>';
        return;
      }

      // Stats
      var total = projects.length;
      var active = projects.filter(function (p) { return p.is_active; }).length;
      var totalDocs = projects.reduce(function (sum, p) { return sum + (p.doc_count || 0); }, 0);
      var totalDevs = projects.reduce(function (sum, p) { return sum + (p.developer_count || 0); }, 0);
      animateStat('pstat-total', total);
      animateStat('pstat-active', active);
      animateStat('pstat-docs', totalDocs);
      animateStat('pstat-devs', totalDevs);

      projectCache = projects;

      // Developer filter dropdown
      var creators = [];
      projects.forEach(function (p) {
        if (p.created_by_name && creators.indexOf(p.created_by_name) === -1)
          creators.push(p.created_by_name);
      });
      creators.sort();
      var filterSel = $('#proj-filter-dev');
      if (filterSel) {
        filterSel.innerHTML = '<option value="">Alle Developer</option>' +
          creators.map(function (c) {
            return '<option value="' + escHtml(c) + '">' + escHtml(c) + '</option>';
          }).join('');
      }

      renderProjectTable();
      initProjectSortHeaders();
    } catch (err) {
      if (err.message !== 'session_expired') {
        tbody.innerHTML = '<tr><td colspan="9"><div class="empty-state">Failed to load</div></td></tr>';
      }
    }
  }

  function updateProjectMergeBar() {
    var bar = $('#proj-merge-bar');
    if (selectedProjectsForMerge.size >= 2) {
      bar.classList.add('visible');
      $('#proj-merge-count').textContent = selectedProjectsForMerge.size + ' projects selected';
    } else {
      bar.classList.remove('visible');
    }
  }

  // --- Project Detail ---
  async function openProject(id) {
    currentProjectId = id;
    // Only overwrite hash if it doesn't already target this project
    // (preserves `project/N/tab` during F5 refresh)
    var curHash = location.hash.replace('#', '');
    if (curHash.indexOf('project/' + id) !== 0) {
      location.hash = 'project/' + id;
    }

    // Try cache first, then reload from server
    var proj = projectCache.find(function (p) { return p.id === id; });
    if (!proj) {
      try {
        var data = await Api.getProjects();
        projectCache = data.projects || [];
        proj = projectCache.find(function (p) { return p.id === id; });
      } catch (e) { /* fall through */ }
    }
    if (!proj) { navigateTo('projects'); return; }

    showPage('project-detail');
    setActiveNav('projects');

    // Phase B: reset to default tab on fresh open (restore path overrides later)
    switchProjectTab('team', true);

    // Fill data
    $('#proj-detail-title').textContent = proj.name;
    $('#proj-detail-name').value = proj.name;
    $('#proj-detail-slug').value = proj.slug;

    var statusClass = proj.is_active ? 'active' : 'inactive';
    var statusText = proj.is_active ? 'Active' : 'Inactive';
    var badge = $('#proj-detail-status');
    badge.className = 'badge badge--' + statusClass;
    badge.textContent = statusText;

    $('#proj-detail-created').textContent = proj.created_at ? formatDate(proj.created_at) : '\u2014';
    $('#pd-docs').textContent = proj.doc_count || 0;
    $('#pd-devs').textContent = proj.developer_count || 0;
    $('#pd-activity').textContent = proj.last_activity ? formatDate(proj.last_activity) : '\u2014';

    Icons.render();

    // Load dashboard data (non-blocking)
    loadProjectDashboard(id, proj);
  }

  function initProjectDetail() {
    $('#btn-back-proj').addEventListener('click', function () {
      navigateTo('projects');
    });

    $('#proj-detail-form').addEventListener('submit', async function (e) {
      e.preventDefault();
      if (!currentProjectId) return;
      var name = $('#proj-detail-name').value.trim();
      if (!name) return;

      var updateData = { name: name };
      var creatorSel = $('#proj-detail-creator');
      if (creatorSel && creatorSel.value) {
        updateData.created_by_developer_id = parseInt(creatorSel.value);
      }

      try {
        await Api.updateProject(currentProjectId, updateData);
        showAlert('proj-detail-alert', 'success', 'Saved.');
        $('#proj-detail-title').textContent = name;
        var proj = projectCache.find(function (p) { return p.id === currentProjectId; });
        if (proj) {
          proj.name = name;
          if (updateData.created_by_developer_id >= 0)
            proj.created_by_developer_id = updateData.created_by_developer_id;
        }
        // Reload dashboard to reflect creator change
        if (proj) loadProjectDashboard(currentProjectId, proj);
      } catch (err) {
        showAlert('proj-detail-alert', 'error', 'Error: ' + err.message);
      }
    });
  }

  // --- Delete Project (Soft-Delete) ---
  function confirmDeleteProject(id, name, hard) {
    var msg = hard
      ? 'PERMANENTLY DELETE project "' + name + '"?\n\nAll documents, tags, relations, sessions and revisions will be deleted irreversibly!'
      : 'Really deactivate project "' + name + '"?\n\nThe project will be soft-deleted and can be reactivated later.';
    if (!confirm(msg)) return;
    Api.deleteProject(id, hard).then(function () {
      loadProjectList();
      showAlert('proj-list-alert', 'success', hard ? 'Project deleted.' : 'Project deactivated.');
    }).catch(function (err) {
      showAlert('proj-list-alert', 'error', 'Error: ' + err.message);
    });
  }

  // --- Project Merge ---
  function initProjectMerge() {
    $('#btn-proj-merge').addEventListener('click', function () {
      if (selectedProjectsForMerge.size < 2) return;

      // Build target selection from checked projects
      var options = [];
      $$('.proj-merge-check:checked').forEach(function (cb) {
        options.push('<option value="' + cb.dataset.id + '">' + escHtml(cb.dataset.name) + '</option>');
      });
      $('#proj-merge-target').innerHTML = options.join('');

      // Hide previous conflicts
      var conflictsEl = $('#proj-merge-conflicts');
      conflictsEl.style.display = 'none';
      conflictsEl.textContent = '';

      $('#modal-proj-merge').classList.add('visible');
    });

    $('#proj-merge-form').addEventListener('submit', async function (e) {
      e.preventDefault();
      var targetId = parseInt($('#proj-merge-target').value);
      var sourceIds = Array.from(selectedProjectsForMerge).filter(function (id) { return id !== targetId; });

      try {
        await Api.mergeProjects(sourceIds, targetId);
        closeModal('modal-proj-merge');
        loadProjectList();
        showAlert('proj-list-alert', 'success', 'Projects merged successfully.');
      } catch (err) {
        if (err.message === 'merge_conflict') {
          // Try to parse conflict details from error
          var conflictsEl = $('#proj-merge-conflicts');
          conflictsEl.textContent = 'Merge blockiert: Es gibt Dokument-Konflikte (gleicher doc_type+slug). Bitte Konflikte zuerst loesen.';
          conflictsEl.style.display = 'flex';
        } else {
          showAlert('proj-list-alert', 'error', 'Merge fehlgeschlagen: ' + err.message);
        }
      }
    });
  }

  // --- Modal Close ---
  function closeModal(id) {
    $('#' + id).classList.remove('visible');
  }

  function initModalCloses() {
    $$('.modal-close').forEach(function (btn) {
      btn.addEventListener('click', function () {
        this.closest('.modal-overlay').classList.remove('visible');
      });
    });

    // Click outside modal
    $$('.modal-overlay').forEach(function (overlay) {
      overlay.addEventListener('click', function (e) {
        if (e.target === overlay) overlay.classList.remove('visible');
      });
    });
  }

  // --- Helpers ---
  function escHtml(str) {
    if (str == null) return '';
    return String(str)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function animateStat(elementId, targetValue) {
    var el = $('#' + elementId);
    if (!el) return;
    var current = parseInt(el.textContent) || 0;
    if (current === targetValue) { el.textContent = targetValue; return; }
    var steps = 12;
    var step = 0;
    var diff = targetValue - current;
    function tick() {
      step++;
      if (step >= steps) { el.textContent = targetValue; return; }
      el.textContent = Math.round(current + (diff * (step / steps)));
      requestAnimationFrame(tick);
    }
    requestAnimationFrame(tick);
  }

  function escJsStr(str) {
    return String(str)
      .replace(/\\/g, '\\\\')
      .replace(/'/g, "\\'")
      .replace(/"/g, '&quot;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/\n/g, '\\n')
      .replace(/\r/g, '\\r');
  }

  function formatDate(dateStr) {
    if (!dateStr) return '\u2014';
    var d;
    // DD.MM.YYYY HH:MM — Punkte im Datum = deutsches Format, NICHT new Date() nutzen
    // (Chrome interpretiert "06.04.2026" als US-Format Month.Day.Year!)
    var parts = dateStr.match(/(\d{2})\.(\d{2})\.(\d{4})\s+(\d{2}):(\d{2})/);
    if (parts) {
      d = new Date(parts[3], parts[2] - 1, parts[1], parts[4], parts[5]);
    } else {
      d = new Date(dateStr);
    }
    if (isNaN(d.getTime())) return dateStr;
    var dd = String(d.getDate()).padStart(2, '0');
    var mm = String(d.getMonth() + 1).padStart(2, '0');
    var yyyy = d.getFullYear();
    var hh = String(d.getHours()).padStart(2, '0');
    var min = String(d.getMinutes()).padStart(2, '0');
    return dd + '.' + mm + '.' + yyyy + ' ' + hh + ':' + min;
  }

  // ============================================================
  //   GLOBAL PAGE
  // ============================================================
  var docTypeLabels = {
    plan: 'Plans',
    spec: 'Specs',
    decision: 'Decisions (ADR)',
    workflow_log: 'Workflows',
    session_note: 'Session Notes',
    note: 'Notes',
    finding: 'Findings',
    reference: 'References',
    snippet: 'Snippets'
  };

  async function loadGlobalPage() {
    showPage('global');

    var dtBody = $('#global-doctypes-body');
    var settBody = $('#global-settings-body');
    dtBody.innerHTML = '<tr><td colspan="3" style="text-align:center;padding:16px"><span class="spinner"></span></td></tr>';
    settBody.innerHTML = '<tr><td colspan="2" style="text-align:center;padding:16px"><span class="spinner"></span></td></tr>';

    try {
      var data = await Api.getGlobalStats();
      var stats = data.stats || {};
      var settings = data.settings || {};
      var docTypes = stats.doc_types || {};

      // Stats bar
      animateStat('gstat-docs', stats.total_documents || 0);
      animateStat('gstat-projects', stats.active_projects || 0);
      animateStat('gstat-devs', stats.active_developers || 0);
      animateStat('gstat-keys', stats.active_keys || 0);
      var aclEl = $('#gstat-acl');
      if (aclEl) aclEl.textContent = (settings.developer_acl_mode || 'off').toUpperCase();

      // Doc types table
      var totalDocs = stats.total_documents || 0;
      var typeEntries = Object.keys(docTypes).sort(function (a, b) {
        return docTypes[b] - docTypes[a];
      });

      if (typeEntries.length === 0) {
        dtBody.innerHTML = '<tr><td colspan="3"><div class="empty-state">No documents</div></td></tr>';
      } else {
        dtBody.innerHTML = typeEntries.map(function (t) {
          var count = docTypes[t];
          var pct = totalDocs > 0 ? Math.round((count / totalDocs) * 100) : 0;
          var label = docTypeLabels[t] || t;
          return '<tr>' +
            '<td><span class="badge">' + escHtml(label) + '</span></td>' +
            '<td class="cell-stat">' + count + '</td>' +
            '<td>' +
              '<div class="progress-bar">' +
                '<div class="progress-bar__fill" style="width:' + pct + '%"></div>' +
                '<span class="progress-bar__label">' + pct + '%</span>' +
              '</div>' +
            '</td>' +
          '</tr>';
        }).join('');
      }

      // Settings table
      var aclBadge = settings.developer_acl_mode === 'enforce'
        ? 'badge--active' : (settings.developer_acl_mode === 'audit' ? 'badge--warning' : 'badge--inactive');
      settBody.innerHTML =
        '<tr><td>ACL-Modus</td><td><span class="badge ' + aclBadge + '">' + escHtml(settings.developer_acl_mode || 'off') + '</span></td></tr>' +
        '<tr><td>MCP-Port</td><td class="mono">' + (settings.mcp_port || '-') + '</td></tr>' +
        '<tr><td>Admin-Port</td><td class="mono">' + (settings.admin_port || '-') + '</td></tr>';

      Icons.render();

      // Load dashboard cards separately (non-blocking, each catches own errors)
      loadAccessLogCard();
      loadPrefetchCard();
      loadHealthCard();
      loadSessionsCard();
    } catch (err) {
      if (err.message !== 'session_expired') {
        showAlert('global-alert', 'error', 'Failed to load: ' + err.message);
      }
    }
  }

  // ---- Card 1: Access-Log ----
  async function loadAccessLogCard() {
    var container = $('#global-accesslog-body');
    if (!container) return;
    container.innerHTML = '<span class="spinner"></span>';

    try {
      var data = await Api.getAccessLogStats();
      var summary = data.summary || {};
      var byDay = data.by_day || [];
      var byTool = data.by_tool || [];
      var topDocs = data.top_docs || [];
      var maxEntries = 0;
      byDay.forEach(function (d) { if (d.entries > maxEntries) maxEntries = d.entries; });

      var html = '';

      // Headline stats
      html += '<div class="card-stats-row">' +
        '<div class="card-stat"><span class="card-stat__value">' + (summary.total_entries || 0) + '</span><span class="card-stat__label">Entries</span></div>' +
        '<div class="card-stat"><span class="card-stat__value">' + (summary.unique_sessions || 0) + '</span><span class="card-stat__label">Sessions</span></div>' +
        '<div class="card-stat"><span class="card-stat__value">' + (summary.days_span || 0) + '</span><span class="card-stat__label">Tage</span></div>' +
      '</div>';

      // Tool breakdown inline
      if (byTool.length > 0) {
        html += '<div style="margin-bottom:12px;display:flex;gap:8px;flex-wrap:wrap">';
        byTool.forEach(function (t) {
          html += '<span class="badge badge--small">' + escHtml(t.tool) + ': ' + t.count + '</span>';
        });
        html += '</div>';
      }

      // Bar chart (CSS-only)
      if (byDay.length > 0) {
        html += '<div class="access-chart">';
        byDay.forEach(function (d) {
          var pct = maxEntries > 0 ? Math.round((d.entries / maxEntries) * 100) : 0;
          var dayLabel = d.date ? d.date.substring(0, 5) : '';
          html += '<div class="access-chart__col" title="' + escHtml(d.date || '') + ': ' + d.entries + ' entries, ' + d.sessions + ' sessions">' +
            '<div class="access-chart__bar" style="height:' + pct + '%"></div>' +
            '<span class="access-chart__label">' + escHtml(dayLabel) + '</span>' +
          '</div>';
        });
        html += '</div>';
      }

      // Top docs
      if (topDocs.length > 0) {
        html += '<div class="card-section-title">Top Documents</div>';
        html += '<div class="card-list">';
        topDocs.slice(0, 5).forEach(function (doc) {
          html += '<div class="card-list__item">' +
            '<span class="card-list__text">' + escHtml(doc.title || '#' + doc.doc_id) + '</span>' +
            '<span class="badge badge--small">' + (doc.access_count || 0) + 'x / ' + (doc.in_sessions || 0) + 's</span>' +
          '</div>';
        });
        html += '</div>';
      }

      container.innerHTML = html;
      Icons.render();
    } catch (err) {
      container.innerHTML = '<div class="empty-state">Error: ' + escHtml(err.message) + '</div>';
    }
  }

  // ---- Card 2: Prefetch-Kandidaten ----
  async function loadPrefetchCard() {
    var container = $('#global-prefetch-body');
    if (!container) return;
    container.innerHTML = '<span class="spinner"></span>';

    try {
      var data = await Api.getPrefetchStats();
      var projects = data.projects || [];
      var total = data.total_candidates || 0;

      var reasonColors = {
        active_plan: 'badge--active',
        linked_adr: 'badge--write',
        frequency: 'badge--read'
      };

      var html = '';

      // Total badge
      html += '<div style="margin-bottom:12px">' +
        '<span class="badge badge--read">' + total + ' Kandidaten</span>' +
      '</div>';

      if (projects.length > 0) {
        projects.forEach(function (p) {
          html += '<div class="card-section-title">' + escHtml(p.name || p.slug) +
            ' <span class="badge badge--small">' + p.candidate_count + '</span></div>';
          if (p.top_candidates && p.top_candidates.length > 0) {
            html += '<div class="card-list">';
            p.top_candidates.forEach(function (c) {
              var reasonClass = reasonColors[c.reason] || '';
              html += '<div class="card-list__item">' +
                '<span class="card-list__text">' + escHtml(c.title || '#' + c.doc_id) + '</span>' +
                '<span class="badge badge--small ' + reasonClass + '">' + escHtml(c.reason) + '</span>' +
              '</div>';
            });
            html += '</div>';
          }
        });
      } else {
        html += '<div class="empty-state">No prefetch candidates</div>';
      }

      container.innerHTML = html;
      Icons.render();
    } catch (err) {
      container.innerHTML = '<div class="empty-state">Error: ' + escHtml(err.message) + '</div>';
    }
  }

  // ---- Card 3: Server Health ----
  async function loadHealthCard() {
    var container = $('#global-health-body');
    if (!container) return;
    container.innerHTML = '<span class="spinner"></span>';

    try {
      var data = await Api.getHealth();
      var html = '';

      // Version + Build + Uptime
      var uptimeSec = data.uptime_seconds || 0;
      var uptimeH = Math.floor(uptimeSec / 3600);
      var uptimeM = Math.floor((uptimeSec % 3600) / 60);
      var uptimeStr = uptimeH + 'h ' + uptimeM + 'm';

      html += '<div class="card-stats-row">' +
        '<div class="card-stat"><span class="card-stat__value mono" style="font-size:0.9rem">v' + escHtml(data.server_version || '-') + '</span><span class="card-stat__label">Version</span></div>' +
        '<div class="card-stat"><span class="card-stat__value">#' + (data.build || '-') + '</span><span class="card-stat__label">Build</span></div>' +
        '<div class="card-stat"><span class="card-stat__value">' + uptimeStr + '</span><span class="card-stat__label">Uptime</span></div>' +
      '</div>';

      // DB status
      var dbOk = data.db_status === 'ok';
      html += '<div style="margin:8px 0">' +
        '<span class="badge ' + (dbOk ? 'badge--active' : 'badge--inactive') + '">DB: ' + escHtml(data.db_status || 'unknown') + '</span>' +
      '</div>';

      // Backup status
      var backup = data.last_backup || {};
      if (backup.file && backup.file !== null) {
        var backupAge = backup.age_hours != null ? backup.age_hours : null;
        var ageClass = 'badge--active';
        if (backupAge != null) {
          if (backupAge > 48) ageClass = 'badge--inactive';
          else if (backupAge > 24) ageClass = 'badge--warning';
        }
        var sizeStr = backup.size_bytes ? (backup.size_bytes > 1048576
          ? (backup.size_bytes / 1048576).toFixed(1) + ' MB'
          : Math.round(backup.size_bytes / 1024) + ' KB') : '';
        html += '<div class="card-section-title">Backup</div>';
        html += '<div class="card-list">';
        html += '<div class="card-list__item"><span class="card-list__text">' + escHtml(backup.file) + '</span></div>';
        if (backupAge != null) {
          html += '<div class="card-list__item"><span class="card-list__text">Alter</span><span class="badge badge--small ' + ageClass + '">' + Math.round(backupAge) + 'h</span></div>';
        }
        if (sizeStr) {
          html += '<div class="card-list__item"><span class="card-list__text">Groesse</span><span class="mono" style="font-size:0.8rem">' + sizeStr + '</span></div>';
        }
        html += '</div>';
      } else {
        html += '<div class="card-section-title">Backup</div>';
        html += '<div class="empty-state" style="padding:4px 0">Kein Backup vorhanden</div>';
      }

      container.innerHTML = html;
      Icons.render();
    } catch (err) {
      container.innerHTML = '<div class="empty-state">Error: ' + escHtml(err.message) + '</div>';
    }
  }

  // ---- Card 4: Active sessions ----
  async function loadSessionsCard() {
    var container = $('#global-sessions-body');
    if (!container) return;
    container.innerHTML = '<span class="spinner"></span>';

    try {
      var data = await Api.getActiveSessions();
      var sessions = data.active_sessions || [];

      var html = '';

      // Total badge
      html += '<div style="margin-bottom:12px">' +
        '<span class="badge badge--active">' + sessions.length + ' aktiv</span>' +
      '</div>';

      if (sessions.length === 0) {
        html += '<div class="empty-state">No active sessions</div>';
      } else {
        var serverVersion = data.setup_version || null;
        html += '<div class="data-table-wrap"><table class="data-table"><thead><tr>' +
          '<th>Projekt</th><th>Developer</th><th>Key</th><th>Setup</th><th>Gestartet</th><th>Heartbeat</th>' +
        '</tr></thead><tbody>';
        sessions.forEach(function (s) {
          var ver = s.setup_version || null;
          var verClass = !ver ? 'color:#999' : (serverVersion && ver === serverVersion ? 'color:#22c55e' : 'color:#eab308');
          var verText = ver || '?';
          html += '<tr>' +
            '<td>' + escHtml(s.project || '-') + '</td>' +
            '<td>' + escHtml(s.developer || '-') + '</td>' +
            '<td>' + escHtml(s.key_name || '-') + '</td>' +
            '<td class="mono" style="font-size:0.8rem;' + verClass + '" title="Server: ' + escHtml(serverVersion || '?') + '">' + escHtml(verText) + '</td>' +
            '<td class="mono" style="font-size:0.8rem">' + escHtml(formatDate(s.started_at || '')) + '</td>' +
            '<td class="mono" style="font-size:0.8rem">' + escHtml(formatRelativeTime(s.last_heartbeat || s.last_activity || '')) + '</td>' +
          '</tr>';
        });
        html += '</tbody></table></div>';
      }

      container.innerHTML = html;
      Icons.render();
    } catch (err) {
      container.innerHTML = '<div class="empty-state">Error: ' + escHtml(err.message) + '</div>';
    }
  }

  function formatRelativeTime(dateStr) {
    if (!dateStr) return '';
    var d;
    // Try German DD.MM.YYYY HH:MM FIRST — Chrome silently misparses it as
    // US MM.DD.YYYY and returns a future date, producing "gerade eben" for
    // everything. Fallback to native parser ONLY if regex doesn't match.
    var parts = typeof dateStr === 'string'
      ? dateStr.match(/(\d{2})\.(\d{2})\.(\d{4})\s+(\d{2}):(\d{2})/) : null;
    if (parts) {
      d = new Date(parts[3], parts[2] - 1, parts[1], parts[4], parts[5]);
    } else {
      d = new Date(dateStr);
    }
    if (isNaN(d.getTime())) return dateStr;
    var diffSec = Math.floor((Date.now() - d.getTime()) / 1000);
    if (diffSec < 0)       return 'in der Zukunft';
    if (diffSec < 60)      return 'gerade eben';
    if (diffSec < 3600)    return Math.floor(diffSec / 60)    + ' Min';
    if (diffSec < 86400)   return Math.floor(diffSec / 3600)  + ' Std';
    return Math.floor(diffSec / 86400) + ' Tage';
  }

  // ---- Card 5: Recall Metriken ----
  async function loadRecallCard() {
    var container = $('#global-recall-body');
    if (!container) return;
    container.innerHTML = '<span class="spinner"></span>';

    try {
      var data = await Api.getRecallMetrics();
      var total = data.total || 0;
      var hits = data.hits || 0;
      var hitratePct = data.hitrate_pct || 0;
      var gateLevels = data.gate_levels || [];
      var outcomes = data.outcomes || [];
      var topLessons = data.top_lessons || [];
      var html = '';

      if (total === 0) {
        container.innerHTML = '<div class="empty-state">No recall data (last 30 days)</div>';
        return;
      }

      // Headline: Hitrate big + stats
      html += '<div style="display:flex;gap:var(--gap-lg);align-items:flex-start;flex-wrap:wrap;margin-bottom:16px">';
      html += '<div style="text-align:center;min-width:120px">' +
        '<div style="font-size:2.2rem;font-weight:700;color:var(--accent)">' + hitratePct + '%</div>' +
        '<div class="text-secondary" style="font-size:0.82rem">Hitrate</div>' +
        '<div class="text-secondary" style="font-size:0.75rem">' + hits + ' / ' + total + ' Aufrufe</div>' +
      '</div>';

      // Gate-Level bars
      if (gateLevels.length > 0) {
        var maxGate = 0;
        gateLevels.forEach(function (g) { if (g.count > maxGate) maxGate = g.count; });
        html += '<div style="flex:1;min-width:200px">';
        html += '<div class="card-section-title" style="margin-bottom:8px">Gate-Level</div>';
        gateLevels.forEach(function (g) {
          var pct = maxGate > 0 ? Math.round((g.count / maxGate) * 100) : 0;
          var barColor = g.level === 'BLOCK' ? 'var(--danger)' :
                         g.level === 'WARN' ? 'var(--warning, #f59e0b)' :
                         g.level === 'INFO' ? 'var(--accent)' : 'var(--text-secondary)';
          html += '<div style="display:flex;align-items:center;gap:8px;margin-bottom:4px">' +
            '<span class="mono" style="font-size:0.8rem;width:50px;text-align:right">' + escHtml(g.level) + '</span>' +
            '<div style="flex:1;height:16px;background:var(--surface-alt, rgba(255,255,255,0.05));border-radius:4px;overflow:hidden">' +
              '<div style="height:100%;width:' + pct + '%;background:' + barColor + ';border-radius:4px;transition:width 0.5s"></div>' +
            '</div>' +
            '<span class="mono" style="font-size:0.8rem;width:35px">' + g.count + '</span>' +
          '</div>';
        });
        html += '</div>';
      }

      // Outcome distribution
      if (outcomes.length > 0) {
        html += '<div style="flex:1;min-width:200px">';
        html += '<div class="card-section-title" style="margin-bottom:8px">Outcomes</div>';
        html += '<div class="data-table-wrap"><table class="data-table"><thead><tr><th>Outcome</th><th>Count</th></tr></thead><tbody>';
        outcomes.forEach(function (o) {
          html += '<tr><td><span class="badge badge--small">' + escHtml(o.outcome) + '</span></td>' +
            '<td class="cell-stat">' + o.count + '</td></tr>';
        });
        html += '</tbody></table></div>';
        html += '</div>';
      }

      html += '</div>';

      // Top-10 Lessons
      if (topLessons.length > 0) {
        html += '<div class="card-section-title">Top-10 Lessons (nach Wirksamkeit)</div>';
        html += '<div class="data-table-wrap"><table class="data-table"><thead><tr>' +
          '<th>ID</th><th>Title</th><th>Violations</th><th>Successes</th><th>Total</th>' +
        '</tr></thead><tbody>';
        topLessons.forEach(function (l) {
          var totalCount = (l.violations || 0) + (l.successes || 0);
          html += '<tr>' +
            '<td class="mono">#' + l.id + '</td>' +
            '<td>' + escHtml(l.title || '-') + '</td>' +
            '<td class="cell-stat">' + (l.violations || 0) + '</td>' +
            '<td class="cell-stat">' + (l.successes || 0) + '</td>' +
            '<td class="cell-stat"><strong>' + totalCount + '</strong></td>' +
          '</tr>';
        });
        html += '</tbody></table></div>';
      }

      container.innerHTML = html;
      Icons.render();
    } catch (err) {
      container.innerHTML = '<div class="empty-state">Error: ' + escHtml(err.message) + '</div>';
    }
  }

  // ---- Card 6: Skill Evolution ----
  async function loadSkillEvolutionCard() {
    var container = $('#global-skillevolution-body');
    if (!container) return;
    container.innerHTML = '<span class="spinner"></span>';

    try {
      var data = await Api.getSkillEvolution();
      var bySkill = data.by_skill || [];
      var recent = data.recent || [];
      var params = data.params || [];
      var html = '';

      // Skill stats
      if (bySkill.length === 0) {
        html += '<div class="empty-state">No findings</div>';
      } else {
        html += '<div class="card-stats-row">';
        var totalAll = 0, pendingAll = 0;
        bySkill.forEach(function (s) { totalAll += s.total; pendingAll += s.pending; });
        html += '<div class="card-stat"><span class="card-stat__value">' + totalAll +
          '</span><span class="card-stat__label">Findings</span></div>';
        html += '<div class="card-stat"><span class="card-stat__value">' + pendingAll +
          '</span><span class="card-stat__label">Pending</span></div>';
        html += '<div class="card-stat"><span class="card-stat__value">' + bySkill.length +
          '</span><span class="card-stat__label">Skills</span></div>';
        html += '</div>';

        // Per-skill breakdown
        html += '<div class="card-section-title">Pro Skill</div>';
        html += '<div class="card-list">';
        bySkill.forEach(function (s) {
          var reacted = s.total - s.pending;
          var fpRate = reacted > 0 ? Math.round((s.false_positives / reacted) * 100) : 0;
          var fpClass = fpRate > 50 ? 'badge--inactive' : fpRate > 20 ? 'badge--warning' : 'badge--active';
          html += '<div class="card-list__item">' +
            '<span class="card-list__text">' + escHtml(s.skill) + '</span>' +
            '<span class="badge badge--small">' + s.confirmed + '/' + s.dismissed + '/' + s.false_positives + '</span>' +
            '<span class="badge badge--small ' + fpClass + '">FP ' + fpRate + '%</span>' +
          '</div>';
        });
        html += '</div>';
      }

      // Recent findings
      if (recent.length > 0) {
        html += '<div class="card-section-title">Recent findings (7d)</div>';
        html += '<div class="card-list">';
        recent.slice(0, 8).forEach(function (f) {
          var sevClass = f.severity === 'error' || f.severity === 'critical' ? 'badge--inactive' :
                         f.severity === 'warning' ? 'badge--warning' : '';
          var reactBadge = f.reaction === 'pending' ? 'badge--warning' :
                           f.reaction === 'confirmed' ? 'badge--active' : '';
          html += '<div class="card-list__item">' +
            '<span class="badge badge--small ' + sevClass + '">' + f.severity.toUpperCase() + '</span>' +
            '<span class="card-list__text" title="' + escHtml(f.uid) + '">' +
              escHtml(f.title.substring(0, 50)) + '</span>' +
            '<span class="badge badge--small ' + reactBadge + '">' + f.reaction + '</span>' +
          '</div>';
        });
        html += '</div>';
      }

      // Active params
      if (params.length > 0) {
        html += '<div class="card-section-title">Tuning-Parameter</div>';
        html += '<div class="card-list">';
        params.forEach(function (p) {
          html += '<div class="card-list__item">' +
            '<span class="card-list__text">' + escHtml(p.skill) + '/' + escHtml(p.key) +
            ' = ' + escHtml(p.value) + '</span>' +
            '<span class="badge badge--small">v' + p.version + '</span>' +
          '</div>';
        });
        html += '</div>';
      }

      container.innerHTML = html;
      Icons.render();
    } catch (err) {
      container.innerHTML = '<div class="empty-state">Error: ' + escapeHtml(err.message) + '</div>';
    }
  }

  // ============================================================
  //   SKILLS PAGE
  // ============================================================

  var skillIcons = {
    mxBugChecker: { icon: 'bug', cls: 'skill-card__icon--bug', accent: '#dc2626' },
    mxDesignChecker: { icon: 'ruler', cls: 'skill-card__icon--design', accent: '#6366f1' },
    mxHealth: { icon: 'heart-pulse', cls: 'skill-card__icon--health', accent: '#10b981' },
    mxPlan: { icon: 'map', cls: 'skill-card__icon--default', accent: '#4f46e5' },
    mxSpec: { icon: 'file-text', cls: 'skill-card__icon--default', accent: '#4f46e5' },
    mxDecision: { icon: 'scale', cls: 'skill-card__icon--default', accent: '#7c3aed' },
    mxSave: { icon: 'save', cls: 'skill-card__icon--default', accent: '#0891b2' },
    mxOrchestrate: { icon: 'workflow', cls: 'skill-card__icon--default', accent: '#0891b2' },
    mxSetup: { icon: 'settings', cls: 'skill-card__icon--default', accent: '#64748b' },
    mxMigrateToDb: { icon: 'database', cls: 'skill-card__icon--default', accent: '#d97706' },
    erzeugeaiconfig: { icon: 'folder-cog', cls: 'skill-card__icon--default', accent: '#64748b' }
  };

  // ---- Intelligence Overview Cards (Recall + Graph + Lessons) ----
  async function loadIntelOverviewCards() {
    try {
      var data = await Api.getRecallMetrics();
      animateStat('intel-recall-total', data.total || 0);
      var el = $('#intel-recall-hitrate');
      if (el) el.textContent = (data.hitrate_pct || 0) + '%';
    } catch (e) {
      var el = $('#intel-recall-total');
      if (el) el.textContent = '-';
    }
    try {
      var data = await Api.getGraphStats();
      animateStat('intel-graph-nodes', data.node_count || 0);
      animateStat('intel-graph-edges', data.edge_count || 0);
    } catch (e) {
      var el = $('#intel-graph-nodes');
      if (el) el.textContent = '-';
    }
    try {
      var data = await Api.getLessonStats();
      animateStat('intel-lessons-total', data.total || 0);
    } catch (e) {
      var el = $('#intel-lessons-total');
      if (el) el.textContent = '-';
    }
    try {
      var data = await Api.getEmbeddingStats();
      animateStat('intel-embedding-count', data.embedded || 0);
      var el = $('#intel-embedding-coverage');
      if (el) el.textContent = (data.coverage_pct || 0) + '%';
      var staleEl = $('#intel-embedding-stale');
      if (staleEl) staleEl.textContent = data.stale || 0;
    } catch (e) {
      var el = $('#intel-embedding-count');
      if (el) el.textContent = '-';
    }
  }

  async function loadTokenStatsCard() {
    try {
      var data = await Api.getTokenStats();
      var el = document.getElementById('token-stats-card');
      if (!el) return;
      var savings = data.savings_pct || 0;
      var avgProjK = Math.round((data.avg_available_tokens || 0) / 1000);
      var avgAvail = data.avg_available_tokens || 0;
      var avgSessK = savings > 0 ? Math.round((avgAvail * (1 - savings / 100)) / 1000) : Math.round((data.avg_tokens_per_session || 0) / 1000);
      el.innerHTML =
        '<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:16px;text-align:center">' +
          '<div><div style="font-size:1.8rem;font-weight:700;color:var(--accent)">' + savings + '%</div>' +
          '<div class="text-secondary" style="font-size:0.78rem">Token Savings</div></div>' +
          '<div><div style="font-size:1.8rem;font-weight:700">' + avgProjK + 'K</div>' +
          '<div class="text-secondary" style="font-size:0.78rem">Available/Session</div></div>' +
          '<div><div style="font-size:1.8rem;font-weight:700">' + avgSessK + 'K</div>' +
          '<div class="text-secondary" style="font-size:0.78rem">Avg Delivered/Session</div></div>' +
          '<div><div style="font-size:1.8rem;font-weight:700">' + (data.mcp_calls_30d || 0) + '</div>' +
          '<div class="text-secondary" style="font-size:0.78rem">MCP Calls (30d)</div></div>' +
          '<div><div style="font-size:1.8rem;font-weight:700">' + (data.total_sessions_30d || 0) + '</div>' +
          '<div class="text-secondary" style="font-size:0.78rem">Sessions (30d)</div></div>' +
          '<div><div style="font-size:1.8rem;font-weight:700">' + (data.total_docs || 0) + '</div>' +
          '<div class="text-secondary" style="font-size:0.78rem">Documents</div></div>' +
        '</div>';
    } catch (e) {
      var el = document.getElementById('token-stats-card');
      if (el) el.innerHTML = '<div class="text-secondary">Token stats unavailable</div>';
    }
  }

  async function loadSkillsPage() {
    showPage('intelligence');

    try {
      var data = await Api.getSkillsDashboard();
      var summary = data.summary || {};
      var skills = data.skills || [];
      var findings = data.findings || [];
      var rules = data.rules || [];
      var params = data.params || [];

      // Stats bar
      animateStat('sstat-total', summary.total_findings || 0);
      animateStat('sstat-confirmed', summary.confirmed || 0);
      animateStat('sstat-dismissed', summary.dismissed || 0);
      var crEl = $('#sstat-confrate');
      if (crEl) crEl.textContent = (summary.overall_conf_rate || 0) + '%';

      // Intelligence overview cards (Recall + Graph + Lessons + Embedding)
      loadIntelOverviewCards();

      // Token efficiency card
      loadTokenStatsCard();

      // Installed skills
      renderInstalledSkills(data.installed_skills || []);

      // Skill evolution cards
      renderSkillCards(skills);

      // Findings table
      renderFindingsTable(findings);

      // Rules table (params for downgrade status)
      renderRulesTable(rules, params);

      // Tuning table
      renderTuningTable(params);

      // Feature tracking cards
      renderFeatureCards(data.features || []);

      // AI-Batch status
      renderAIBatchCard(data.ai_batch || {});

      Icons.render();
    } catch (err) {
      if (err.message !== 'session_expired') {
        showAlert('skills-alert', 'error', 'Failed to load: ' + err.message);
      }
    }
  }

  function renderFeatureCards(features) {
    var grid = $('#features-grid');
    if (!grid) return;

    if (features.length === 0) {
      grid.innerHTML = '<div style="grid-column: span 3; text-align: center; padding: 16px; color: var(--text-tertiary)">No feature data available</div>';
      return;
    }

    var html = '';
    features.forEach(function (f, i) {
      // Build metrics row items based on available data
      var metrics = [];
      metrics.push({ value: f.metric, label: f.metric_label });

      if (f.positive !== undefined) {
        var pct = f.metric > 0 ? Math.round(f.positive / f.metric * 100) : 0;
        metrics.push({ value: pct + '%', label: 'Positiv' });
      }
      if (f.avg_latency_ms !== undefined) {
        metrics.push({ value: f.avg_latency_ms + 'ms', label: 'Avg Latenz' });
      }
      if (f.blocks !== undefined) {
        metrics.push({ value: f.blocks, label: 'Blocks' });
      }
      // Pad to 3 columns if needed
      if (metrics.length < 3 && f.last_activity) {
        metrics.push({ value: f.last_activity.split(' ')[0], label: 'Last' });
      }
      while (metrics.length < 3) {
        metrics.push({ value: '—', label: '' });
      }

      html += '<div class="skill-card" style="--skill-accent: ' + f.accent +
        '; animation-delay: ' + (i * 60) + 'ms">' +
        '<div class="skill-card__header">' +
          '<div class="skill-card__icon skill-card__icon--default" style="background: linear-gradient(135deg, ' + f.accent + '1f, ' + f.accent + '08); color: ' + f.accent + '">' +
            '<i data-lucide="' + f.icon + '"></i>' +
          '</div>' +
          '<div style="flex:1">' +
            '<div class="skill-card__name">' + escHtml(f.name) + '</div>' +
            '<div class="skill-card__meta">' + (f.last_activity ? 'Last activity: ' + f.last_activity : 'Active') + '</div>' +
          '</div>' +
        '</div>' +
        '<div class="skill-card__metrics">';

      metrics.slice(0, 3).forEach(function (m) {
        html += '<div class="skill-metric">' +
          '<div class="skill-metric__value">' + m.value + '</div>' +
          '<div class="skill-metric__label">' + escHtml(m.label) + '</div>' +
        '</div>';
      });

      html += '</div></div>';
    });

    grid.innerHTML = html;
  }

  function renderInstalledSkills(installed) {
    var body = $('#skills-installed-body');
    var countEl = $('#skills-installed-count');
    if (!body) return;
    if (countEl) countEl.textContent = installed.length;

    if (installed.length === 0) {
      body.innerHTML = '<div class="empty-state">No skills found in claude-setup/</div>';
      return;
    }

    var html = '<div class="installed-skills-grid">';
    installed.forEach(function (s, i) {
      var si = skillIcons[s.name] || { icon: 'zap', cls: 'skill-card__icon--default', accent: 'var(--accent)' };
      var invBadge = s.user_invocable
        ? '<span class="badge badge--small badge--active">/' + escHtml(s.name) + '</span>'
        : '<span class="badge badge--small">intern</span>';

      html += '<div class="installed-skill" style="animation-delay: ' + (i * 40) + 'ms">' +
        '<div class="installed-skill__icon ' + si.cls + '">' +
          '<i data-lucide="' + si.icon + '"></i>' +
        '</div>' +
        '<div class="installed-skill__info">' +
          '<div class="installed-skill__name">' + escHtml(s.name) + '</div>' +
          '<div class="installed-skill__desc">' + escHtml(s.description || '') + '</div>' +
        '</div>' +
        '<div class="installed-skill__badge">' + invBadge + '</div>' +
      '</div>';
    });
    html += '</div>';
    body.innerHTML = html;
  }

  function renderSkillCards(skills) {
    var grid = $('#skills-grid');
    if (!grid) return;

    if (skills.length === 0) {
      grid.innerHTML =
        '<div class="skills-empty" style="grid-column: span 3">' +
          '<div class="skills-empty__icon"><i data-lucide="brain"></i></div>' +
          '<div class="skills-empty__title">Noch keine Skill-Daten</div>' +
          '<div class="skills-empty__text">' +
            'Fuehre /mxBugChecker, /mxDesignChecker oder /mxHealth aus ' +
            'um die ersten Findings zu generieren.' +
          '</div>' +
        '</div>';
      return;
    }

    var html = '';
    skills.forEach(function (s, i) {
      var si = skillIcons[s.name] || { icon: 'zap', cls: 'skill-card__icon--default', accent: 'var(--accent)' };
      var reacted = s.total - s.pending;
      var precPct = s.precision || 0;
      var fpPct = s.fp_rate || 0;

      // Ring color based on precision
      var ringColor = precPct >= 80 ? '#16a34a' : precPct >= 50 ? '#d97706' : '#dc2626';
      if (reacted === 0) ringColor = 'var(--border)';

      html += '<div class="skill-card" style="--skill-accent: ' + si.accent +
        '; animation-delay: ' + (i * 60) + 'ms">' +
        '<div class="skill-card__header">' +
          '<div class="skill-card__icon ' + si.cls + '">' +
            '<i data-lucide="' + si.icon + '"></i>' +
          '</div>' +
          '<div>' +
            '<div class="skill-card__name">' + escHtml(s.name) + '</div>' +
            '<div class="skill-card__meta">' + s.rules + ' rules &middot; ' +
              s.projects + ' projects</div>' +
          '</div>' +
          '<div class="precision-ring" style="--ring-pct: ' + precPct + '; --ring-color: ' + ringColor + '">' +
            '<div style="text-align:center; line-height: 1.2">' +
              '<div class="precision-ring__value">' + (reacted > 0 ? precPct + '%' : '—') + '</div>' +
              '<div class="precision-ring__label">Conf</div>' +
            '</div>' +
          '</div>' +
        '</div>' +
        '<div class="skill-card__metrics">' +
          '<div class="skill-metric">' +
            '<div class="skill-metric__value">' + s.total + '</div>' +
            '<div class="skill-metric__label">Findings</div>' +
          '</div>' +
          '<div class="skill-metric">' +
            '<div class="skill-metric__value">' + s.pending + '</div>' +
            '<div class="skill-metric__label">Pending</div>' +
          '</div>' +
          '<div class="skill-metric">' +
            '<div class="skill-metric__value"' +
              (fpPct > 50 ? ' style="color:#dc2626"' : fpPct > 20 ? ' style="color:#d97706"' : '') +
              '>' + fpPct + '%</div>' +
            '<div class="skill-metric__label">FP-Rate</div>' +
          '</div>' +
        '</div>' +
      '</div>';
    });

    grid.innerHTML = html;
  }

  // Store findings for filtering
  var _allFindings = [];
  var _findingsFilter = 'pending';

  function setFindingsFilter(filter) {
    _findingsFilter = filter;
    renderFindingsFiltered();
    // Update active button
    var btns = document.querySelectorAll('.findings-filter-btn');
    btns.forEach(function (b) {
      b.classList.toggle('active', b.dataset.filter === filter);
    });
  };

  function renderFindingsFiltered() {
    var filtered = _allFindings;
    if (_findingsFilter === 'pending') {
      filtered = _allFindings.filter(function (f) { return f.reaction === 'pending'; });
    } else if (_findingsFilter !== 'all') {
      filtered = _allFindings.filter(function (f) { return f.reaction === _findingsFilter; });
    }

    var countEl = $('#findings-filter-count');
    if (countEl) countEl.textContent = filtered.length + ' / ' + _allFindings.length;

    renderFindingsRows(filtered);
  }

  function renderFindingsTable(findings) {
    _allFindings = findings;
    // Render filter bar
    var filterBar = $('#findings-filter-bar');
    if (filterBar) {
      var pendingCount = findings.filter(function (f) { return f.reaction === 'pending'; }).length;
      var confirmedCount = findings.filter(function (f) { return f.reaction === 'confirmed'; }).length;
      var dismissedCount = findings.filter(function (f) { return f.reaction === 'dismissed'; }).length;
      var fpCount = findings.filter(function (f) { return f.reaction === 'false_positive'; }).length;
      filterBar.innerHTML =
        '<button class="findings-filter-btn active" data-filter="pending" onclick="App.setFindingsFilter(\'pending\')">Pending (' + pendingCount + ')</button>' +
        '<button class="findings-filter-btn" data-filter="all" onclick="App.setFindingsFilter(\'all\')">Alle (' + findings.length + ')</button>' +
        '<button class="findings-filter-btn" data-filter="confirmed" onclick="App.setFindingsFilter(\'confirmed\')">Confirmed (' + confirmedCount + ')</button>' +
        '<button class="findings-filter-btn" data-filter="dismissed" onclick="App.setFindingsFilter(\'dismissed\')">Dismissed (' + dismissedCount + ')</button>' +
        '<button class="findings-filter-btn" data-filter="false_positive" onclick="App.setFindingsFilter(\'false_positive\')">FP (' + fpCount + ')</button>' +
        '<span id="findings-filter-count" class="text-secondary" style="margin-left:auto;font-size:0.75rem"></span>';
    }
    renderFindingsFiltered();
  }

  function renderFindingsRows(findings) {
    var body = $('#skills-findings-body');
    if (!body) return;

    if (findings.length === 0) {
      body.innerHTML = '<tr><td colspan="9"><div class="empty-state">No findings in this view</div></td></tr>';
      return;
    }

    body.innerHTML = findings.map(function (f) {
      var sevDot = '<span class="severity-dot severity-dot--' + f.severity + '"></span>';
      var sevLabel = f.severity.toUpperCase();

      var reactionBadge = '';
      if (f.reaction === 'pending') {
        reactionBadge = '<span class="badge badge--small badge--warning">PENDING</span>';
      } else if (f.reaction === 'confirmed') {
        reactionBadge = '<span class="badge badge--small badge--active">OK</span>';
      } else if (f.reaction === 'dismissed') {
        reactionBadge = '<span class="badge badge--small">DISMISSED</span>';
      } else if (f.reaction === 'false_positive') {
        reactionBadge = '<span class="badge badge--small badge--inactive">FP</span>';
      }

      var actions = '';
      if (f.reaction === 'pending') {
        actions =
          '<button class="feedback-btn feedback-btn--confirm" onclick="App.skillFeedback(\'' +
            escHtml(f.uid) + '\', \'confirmed\')" title="Bestaetigen">&#10003;</button> ' +
          '<button class="feedback-btn feedback-btn--dismiss" onclick="App.skillFeedback(\'' +
            escHtml(f.uid) + '\', \'dismissed\')" title="Verwerfen">&#10007;</button> ' +
          '<button class="feedback-btn feedback-btn--fp" onclick="App.skillFeedback(\'' +
            escHtml(f.uid) + '\', \'false_positive\')" title="False Positive">FP</button>';
      } else {
        actions = '<span class="text-tertiary" style="font-size:0.7rem">—</span>';
      }

      var fileStr = '';
      if (f.file) {
        var shortFile = f.file.length > 30 ? '...' + f.file.substring(f.file.length - 30) : f.file;
        fileStr = '<span class="mono text-secondary" style="font-size:0.7rem" title="' +
          escHtml(f.file) + '">' + escHtml(shortFile) +
          (f.line ? ':' + f.line : '') + '</span><br>';
      }

      return '<tr>' +
        '<td>' + sevDot + '<span class="mono" style="font-size:0.72rem">' + sevLabel + '</span></td>' +
        '<td><span class="mono" style="font-size:0.78rem">' + escHtml(f.skill) + '</span></td>' +
        '<td><span class="badge badge--small">' + escHtml(f.rule) + '</span></td>' +
        '<td>' + fileStr + escHtml(f.title.substring(0, 60)) + '</td>' +
        '<td><span class="badge badge--small">' + escHtml(f.project) + '</span></td>' +
        '<td class="mono text-secondary" style="font-size:0.72rem">' + f.created + '</td>' +
        '<td>' + reactionBadge + '</td>' +
        '<td style="white-space:nowrap">' + actions + '</td>' +
      '</tr>';
    }).join('');
  }

  function renderRulesTable(rules, params) {
    var body = $('#skills-rules-body');
    if (!body) return;

    if (rules.length === 0) {
      body.innerHTML = '<tr><td colspan="9"><div class="empty-state">No rules</div></td></tr>';
      return;
    }

    // Build downgrade lookup from tuning params
    var downgraded = {};
    (params || []).forEach(function (p) {
      if (p.key && p.key.indexOf('_severity') > -1 && p.value === 'downgraded') {
        var ruleId = p.key.replace('rule_', '').replace('_severity', '');
        downgraded[p.skill + '/' + ruleId] = true;
      }
      if (p.key && p.key.indexOf('_enabled') > -1 && p.value === 'false') {
        var ruleId = p.key.replace('rule_', '').replace('_enabled', '');
        downgraded[p.skill + '/' + ruleId] = 'disabled';
      }
    });

    body.innerHTML = rules.map(function (r) {
      var reacted = r.total - (r.pending || 0);
      var confRate = reacted > 0 ? Math.round(r.confirmed / reacted * 100) : 0;
      var confColor = confRate >= 80 ? '#16a34a' : confRate >= 50 ? '#d97706' : '#dc2626';
      if (reacted === 0) confColor = 'var(--text-tertiary)';

      var key = r.skill + '/' + r.rule;
      var status = downgraded[key];
      var statusBadge = '';
      if (status === 'disabled') {
        statusBadge = '<span class="badge badge--small" style="background:#dc2626;color:#fff">disabled</span>';
      } else if (status) {
        statusBadge = '<span class="badge badge--small" style="background:#d97706;color:#fff">downgraded</span>';
      } else {
        statusBadge = '<span class="badge badge--small" style="background:#16a34a;color:#fff">active</span>';
      }

      var rowStyle = status ? ' style="opacity:0.6"' : '';

      return '<tr' + rowStyle + '>' +
        '<td><span class="mono" style="font-size:0.78rem">' + escHtml(r.skill) + '</span></td>' +
        '<td><span class="badge badge--small">' + escHtml(r.rule) + '</span></td>' +
        '<td>' + statusBadge + '</td>' +
        '<td class="mono">' + r.total + '</td>' +
        '<td class="mono" style="color:var(--status-active)">' + r.confirmed + '</td>' +
        '<td class="mono">' + (r.dismissed || 0) + '</td>' +
        '<td class="mono" style="color:var(--status-inactive)">' + r.false_positives + '</td>' +
        '<td><span class="mono" style="color:' + confColor + '">' + confRate + '%</span>' +
          '<div class="precision-bar"><div class="precision-bar__fill" style="width:' +
            confRate + '%; background:' + confColor + '"></div></div></td>' +
      '</tr>';
    }).join('');
  }

  function renderTuningTable(params) {
    var body = $('#skills-tuning-body');
    if (!body) return;

    if (params.length === 0) {
      body.innerHTML = '<tr><td colspan="9"><div class="empty-state">No tuning parameters</div></td></tr>';
      return;
    }

    body.innerHTML = params.map(function (p) {
      return '<tr>' +
        '<td><span class="mono" style="font-size:0.78rem">' + escHtml(p.skill) + '</span></td>' +
        '<td><span class="badge badge--small">' + escHtml(p.key) + '</span></td>' +
        '<td class="mono" style="font-weight:600">' + escHtml(p.value) + '</td>' +
        '<td class="mono text-secondary">v' + p.version + '</td>' +
        '<td class="mono text-tertiary">' + (p.previous ? escHtml(p.previous) : '—') + '</td>' +
        '<td style="font-size:0.78rem">' + escHtml(p.reason || '—') + '</td>' +
        '<td><span class="badge badge--small">' + escHtml(p.project) + '</span></td>' +
        '<td class="mono text-secondary" style="font-size:0.72rem">' + p.updated + '</td>' +
      '</tr>';
    }).join('');
  }

  function renderAIBatchCard(aiBatch) {
    var body = $('#skills-ai-batch-body');
    if (!body) return;
    if (!aiBatch || !aiBatch.jobs || aiBatch.jobs.length === 0) {
      body.innerHTML = '<div class="empty-state">Noch keine AI-Batch Runs</div>';
      return;
    }
    var totalCalls = aiBatch.total_calls || 0;
    var jobCount = aiBatch.jobs ? aiBatch.jobs.length : 0;
    var html = '<div style="display:flex;gap:24px;margin-bottom:12px">' +
      '<div><span class="text-secondary" style="font-size:0.78rem">Gesamt-Runs</span>' +
      '<div class="mono" style="font-size:1.1rem;font-weight:600">' + totalCalls + '</div></div>' +
      '<div><span class="text-secondary" style="font-size:0.78rem">Job-Typen</span>' +
      '<div class="mono" style="font-size:1.1rem;font-weight:600">' + jobCount + '</div></div>' +
    '</div>';
    html += '<div class="table-scroll"><table class="data-table"><thead><tr>' +
      '<th>Job type</th><th>Total</th><th>Success</th><th>Errors</th>' +
      '<th>Last run</th>' +
      '</tr></thead><tbody>';
    aiBatch.jobs.forEach(function (j) {
      var errCls = j.errors > 0 ? 'color:var(--status-inactive);font-weight:600' : '';
      html += '<tr>' +
        '<td><span class="badge badge--small">' + escHtml(j.type) + '</span></td>' +
        '<td class="mono">' + j.total + '</td>' +
        '<td class="mono" style="color:var(--status-active)">' + j.success + '</td>' +
        '<td class="mono" style="' + errCls + '">' + j.errors + '</td>' +
        '<td class="mono text-secondary" style="font-size:0.72rem">' + (j.last_run || '—') + '</td>' +
      '</tr>';
    });
    html += '</tbody></table></div>';
    body.innerHTML = html;
  }

  function switchSkillTab(tab) {
    $$('#skills-tabs .tab-btn').forEach(function (btn) {
      if (btn.dataset.tab === tab) btn.classList.add('active');
      else btn.classList.remove('active');
    });
    $$('.skills-tab-panel').forEach(function (p) {
      if (p.id === 'skills-tab-' + tab) p.classList.add('active');
      else p.classList.remove('active');
    });
  }

  async function skillFeedback(findingUid, reaction) {
    try {
      await Api.postSkillFeedback(findingUid, reaction);
      showAlert('skills-alert', 'success', 'Feedback saved: ' + reaction);
      // Reload data
      loadSkillsPage();
    } catch (err) {
      showAlert('skills-alert', 'error', 'Error: ' + err.message);
    }
  }

  // ============================================================
  //   PROJECT DASHBOARD
  // ============================================================
  async function loadProjectDashboard(projId, proj) {
    var chipsBox = $('#pd-doctypes-chips');
    var devBody = $('#pd-devs-body');
    var relBody = $('#pd-relations-body');
    var creatorSel = $('#proj-detail-creator');
    if (!devBody) return;

    devBody.innerHTML = '<tr><td colspan="5" style="text-align:center;padding:8px"><span class="spinner"></span></td></tr>';

    try {
      var results = await Promise.all([
        Api.getProjectDashboard(projId),
        Api.getDevelopers()
      ]);
      var dash = results[0];
      var allDevs = (results[1].developers || []).filter(function (d) { return d.is_active; });
      var docTypes = dash.doc_types || {};
      var devs = dash.developers || [];

      // Doc-type chips (FR#3353 Phase C — compact summary, click filters doc list)
      if (chipsBox) {
        var typeKeys = Object.keys(docTypes).sort(function (a, b) { return docTypes[b] - docTypes[a]; });
        if (typeKeys.length === 0) {
          chipsBox.innerHTML = '<span class="pd-doctypes-chips__empty">No documents</span>';
        } else {
          chipsBox.innerHTML =
            '<span class="pd-doctypes-chip" data-type="" onclick="App.filterDocsByType(\'\')">' +
              '<span>all</span>' +
              '<span class="pd-doctypes-chip__count">' +
                typeKeys.reduce(function (a, k) { return a + docTypes[k]; }, 0) +
              '</span>' +
            '</span>' +
            typeKeys.map(function (t) {
              var label = docTypeLabels[t] || t;
              return '<span class="pd-doctypes-chip" data-type="' + escJsStr(t) +
                '" onclick="App.filterDocsByType(\'' + escJsStr(t) + '\')">' +
                '<span>' + escHtml(label) + '</span>' +
                '<span class="pd-doctypes-chip__count">' + docTypes[t] + '</span>' +
                '</span>';
            }).join('');
        }
      }

      // Developers — enriched status dashboard (FR#3353 Phase A)
      if (devs.length === 0) {
        devBody.innerHTML = '<tr><td colspan="5"><div class="empty-state">No assignments</div></td></tr>';
      } else {
        var aclMap = {
          'none':       { cls: 'badge--acl-none',    label: 'none' },
          'comment':    { cls: 'badge--acl-comment', label: 'comment' },
          'read':       { cls: 'badge--acl-read',    label: 'read' },
          'read-write': { cls: 'badge--acl-rw',      label: 'read-write' }
        };
        devBody.innerHTML = devs.map(function (d) {
          var aclRaw = String(d.access_level || 'none').toLowerCase();
          var acl = aclMap[aclRaw] || { cls: 'badge--acl-none', label: aclRaw };

          var uiOn = d.ui_login_enabled !== false;
          var uiHtml = '<span class="stat-icon ' + (uiOn ? 'stat-icon--on' : 'stat-icon--off') +
            '" title="' + escJsStr(uiOn ? 'UI login enabled' : 'UI login disabled') +
            '"><i data-lucide="' + (uiOn ? 'log-in' : 'log-out') + '" class="icon-xs"></i></span>';

          var msgsOn = d.accept_agent_messages !== false;
          var msgHtml = '<span class="stat-icon ' + (msgsOn ? 'stat-icon--on' : 'stat-icon--off') +
            '" title="' + escJsStr(msgsOn ? 'Accepts agent messages' : 'Opt-out of agent messages') +
            '"><i data-lucide="' + (msgsOn ? 'mail' : 'ban') + '" class="icon-xs"></i></span>';

          var active = d.active_keys || 0;
          var revoked = d.revoked_keys || 0;
          var keyHtml;
          if (active === 0) {
            keyHtml = '<span class="key-status key-status--empty" title="no active keys">&mdash;</span>';
          } else {
            var expiryHtml = '';
            if (d.next_expiry) {
              var then = new Date(d.next_expiry).getTime();
              if (!isNaN(then)) {
                var days = Math.round((then - Date.now()) / 86400000);
                var expCls = 'key-exp';
                var label = days + 'd';
                if (days < 0) { expCls += ' key-exp--expired'; label = 'expired'; }
                else if (days < 14) { expCls += ' key-exp--urgent'; }
                else if (days < 30) { expCls += ' key-exp--warn'; }
                expiryHtml = '<span class="' + expCls + '" title="' +
                  escJsStr('next expiry: ' + d.next_expiry) + '">' + escHtml(label) + '</span>';
              }
            }
            var revHtml = '';
            if (revoked > 0) {
              revHtml = '<span class="key-revoked" title="' +
                escJsStr(revoked + ' revoked key(s)') + '">&middot; ' + revoked + ' rev</span>';
            }
            keyHtml = '<span class="key-status">' +
              '<span class="key-count" title="' + escJsStr(active + ' active key(s)') + '">' +
              active + '</span>' + expiryHtml + revHtml + '</span>';
          }

          // Inline-edit ACL select (Gap#2)
          var aclOpts = [
            { v: 'none',       l: 'none' },
            { v: 'comment',    l: 'comment' },
            { v: 'read',       l: 'read' },
            { v: 'read-write', l: 'read-write' }
          ];
          var selOptions = aclOpts.map(function (o) {
            return '<option value="' + o.v + '"' +
              (o.v === aclRaw ? ' selected' : '') + '>' + o.l + '</option>';
          }).join('');
          var aclVariant = acl.cls.replace('badge--acl-', '');
          var aclCell = '<select class="acl-select acl-select--' + aclVariant + '" ' +
            'data-dev-id="' + d.id + '" ' +
            'onchange="App.onAclChange(' + d.id + ', this)">' +
            selOptions + '</select>';

          // Name is clickable → Developer-Detail (Key-Revoke/Rotate UI lives there)
          var nameCell = '<a href="#developer/' + d.id + '/keys" class="link" ' +
            'onclick="event.stopPropagation(); App.openDeveloper(' + d.id + ');return false" ' +
            'title="Manage keys + revoke">' + escHtml(d.name) + '</a>';
          return '<tr>' +
            '<td class="col-name">' + nameCell + '</td>' +
            '<td class="col-acl">' + aclCell + '</td>' +
            '<td class="col-icon">' + uiHtml + '</td>' +
            '<td class="col-icon">' + msgHtml + '</td>' +
            '<td class="col-keys">' + keyHtml + '</td></tr>';
        }).join('');
      }

      // Related projects (with delete button column)
      var rels = dash.related_projects || [];
      if (relBody) {
        if (rels.length === 0) {
          relBody.innerHTML = '<tr><td colspan="4"><div class="empty-state">No relations</div></td></tr>';
        } else {
          var relLabels = { depends_on: 'depends on', related_to: 'related to', extends: 'extends' };
          var dirLabels = { outgoing: 'outbound', incoming: 'inbound' };
          relBody.innerHTML = rels.map(function (r) {
            var relLabel = relLabels[r.relation_type] || r.relation_type;
            var dirLabel = dirLabels[r.direction] || r.direction;
            var dirClass = r.direction === 'incoming' ? 'badge--read' : 'badge--write';
            var delBtn = r.rel_id ?
              '<button class="rel-delete-btn" onclick="App.confirmDeleteProjectRelation(' + r.rel_id + ', \'' + escJsStr(r.name || r.slug) + '\')" title="Remove relation">' +
              '<i data-lucide="x"></i></button>' : '';
            return '<tr>' +
              '<td><a href="#project/' + r.id + '" class="link">' +
                escHtml(r.name || r.slug) + '</a></td>' +
              '<td><span class="badge badge--small">' + escHtml(relLabel) + '</span></td>' +
              '<td><span class="badge badge--small ' + dirClass + '">' + escHtml(dirLabel) + '</span></td>' +
              '<td style="text-align:right">' + delBtn + '</td></tr>';
          }).join('');
          Icons.render();
        }
      }

      // Creator select
      if (creatorSel) {
        var currentCreator = proj.created_by_developer_id || 0;
        creatorSel.innerHTML = '<option value="">— unbekannt —</option>' +
          allDevs.map(function (d) {
            return '<option value="' + d.id + '"' +
              (d.id === currentCreator ? ' selected' : '') + '>' +
              escHtml(d.name) + '</option>';
          }).join('');
      }

      Icons.render();
    } catch (err) {
      dtBody.innerHTML = '<tr><td colspan="2"><div class="empty-state">Error</div></td></tr>';
    }
  }

  // FR#3353 Phase B / FR#3472 C — project-detail tab switching + hash persistence
  function switchProjectTab(tabName, skipHashUpdate) {
    var valid = ['team', 'docs', 'reviews', 'relations'];
    if (valid.indexOf(tabName) < 0) tabName = 'team';
    $$('.pd-tab').forEach(function (btn) {
      var on = btn.dataset.tab === tabName;
      btn.classList.toggle('is-active', on);
      btn.setAttribute('aria-selected', on ? 'true' : 'false');
      btn.setAttribute('tabindex', on ? '0' : '-1');
    });
    $$('.pd-tab-panel').forEach(function (panel) {
      var on = panel.dataset.panel === tabName;
      panel.classList.toggle('is-active', on);
      if (on) panel.removeAttribute('hidden');
      else panel.setAttribute('hidden', '');
    });
    if (!skipHashUpdate && currentProjectId) {
      location.hash = 'project/' + currentProjectId + '/' + tabName;
    }
    Icons.render();
    // Lazy load per-tab content
    if (tabName === 'docs') loadDocsList();
    if (tabName === 'reviews') loadProjectReviews();
  }

  // FR#3472 C / SPEC#3583 — Project-Detail Reviews-Tab
  async function loadProjectReviews() {
    if (!currentProjectId) return;
    var body = $('#pd-reviews-body');
    var cntEl = $('#pd-reviews-count');
    var hintEl = $('#pd-reviews-hint');
    if (!body) return;
    body.innerHTML = '<div class="empty-state"><span class="spinner"></span></div>';
    try {
      var resp = await Api.getProjectReviews(currentProjectId);
      var reviews = (resp && resp.reviews) || [];
      var total = (resp && resp.total != null) ? resp.total : reviews.length;
      if (cntEl) {
        if (total > 0) {
          cntEl.textContent = total;
          cntEl.removeAttribute('hidden');
        } else {
          cntEl.setAttribute('hidden', '');
        }
      }
      if (hintEl) {
        if (resp && resp.truncated) {
          hintEl.textContent = 'Showing first 100 threads — older threads are not listed.';
          hintEl.removeAttribute('hidden');
        } else {
          hintEl.setAttribute('hidden', '');
        }
      }
      if (!reviews.length) {
        body.innerHTML = '<div class="reviews-empty">No review-threads in this project yet.</div>';
        return;
      }
      body.innerHTML = reviews.map(function (r) {
        var typeCls = 'doc-cell-type doc-cell-type--' + (r.doc_type || 'note');
        var statusCls = r.status === 'active' ? 'active'
                       : r.status === 'archived' ? 'inactive'
                       : r.status === 'draft' ? 'read' : 'write';
        var when = r.last_activity ? formatRelativeTime(r.last_activity) : '';
        return '<div class="review-row" data-root-id="' + r.root_id + '">' +
          '<span class="review-row__chevron mono">&#9656;</span>' +
          '<span class="doc-type-badge ' + typeCls + '">' + escHtml(r.doc_type || 'doc') + '</span>' +
          '<span class="review-row__title">' + escHtml(r.title || '(untitled)') + ' ' +
            '<span class="mono" style="opacity:0.55;font-size:0.85em">#' + r.root_id + '</span>' +
          '</span>' +
          '<span class="badge badge--small badge--' + statusCls + '">' + escHtml(r.status || '—') + '</span>' +
          '<span class="review-row__stats">' +
            (r.reply_count || 0) + ' replies · depth ' + (r.max_depth || 0) +
            ' · ' + escHtml(when) +
          '</span>' +
        '</div>';
      }).join('');
      // Wire up inline-expand: first click -> expand via /docs/:id/thread,
      // second click -> collapse.
      body.querySelectorAll('.review-row').forEach(function (row) {
        row.addEventListener('click', onReviewRowClick);
      });
      Icons.render();
    } catch (err) {
      body.innerHTML = '<div class="reviews-empty">Failed to load reviews: ' +
        escHtml((err && err.message) || 'unknown') + '</div>';
    }
  }

  async function onReviewRowClick(ev) {
    var row = ev.currentTarget;
    var rootId = parseInt(row.getAttribute('data-root-id'), 10);
    if (!rootId) return;
    var next = row.nextElementSibling;
    // Collapse if expansion already exists directly below.
    if (next && next.classList.contains('review-expand') &&
        next.getAttribute('data-root-id') === String(rootId)) {
      next.parentNode.removeChild(next);
      row.classList.remove('review-row--open');
      return;
    }
    // Remove any other open expansion first (only one at a time).
    var openExp = row.parentNode.querySelector('.review-expand');
    if (openExp) {
      openExp.parentNode.removeChild(openExp);
      var prevOpenRow = row.parentNode.querySelector('.review-row--open');
      if (prevOpenRow) prevOpenRow.classList.remove('review-row--open');
    }
    var expand = document.createElement('div');
    expand.className = 'review-expand';
    expand.setAttribute('data-root-id', String(rootId));
    expand.innerHTML = '<div class="empty-state"><span class="spinner"></span></div>';
    row.parentNode.insertBefore(expand, row.nextSibling);
    row.classList.add('review-row--open');
    try {
      var resp = await Api.getDocThread(rootId);
      var thread = (resp && resp.thread) || [];
      if (thread.length <= 1) {
        expand.innerHTML = '<div class="reviews-empty" style="padding:var(--gap-sm)">No replies.</div>';
        return;
      }
      expand.innerHTML = '<div class="thread-list">' + thread.map(function (n) {
        var typeCls = 'doc-cell-type doc-cell-type--' + (n.doc_type || 'note');
        var statusCls = n.status === 'active' ? 'active'
                       : n.status === 'archived' ? 'inactive'
                       : n.status === 'draft' ? 'read' : 'write';
        var author = n.author_name || '—';
        var when = n.created_at ? formatRelativeTime(n.created_at) : '';
        var titleLink =
          '<a href="#" class="thread-node__title link" onclick="event.preventDefault();event.stopPropagation();App.openDoc(' + n.id + ')">' +
          escHtml(n.title || '(untitled)') + '</a>';
        return '<div class="thread-node" style="padding-left:' + (n.depth * 20) + 'px">' +
          '<span class="doc-type-badge ' + typeCls + '">' + escHtml(n.doc_type || 'doc') + '</span> ' +
          titleLink +
          ' <span class="badge badge--small badge--' + statusCls + '">' + escHtml(n.status || '—') + '</span>' +
          ' <span class="thread-node__meta"><span class="thread-node__id mono">#' + n.id + '</span> · ' +
          escHtml(author) + ' · ' + escHtml(when) + '</span>' +
          '</div>';
      }).join('') + '</div>';
    } catch (err) {
      expand.innerHTML = '<div class="reviews-empty" style="padding:var(--gap-sm)">Failed to load thread: ' +
        escHtml((err && err.message) || 'unknown') + '</div>';
    }
  }

  // FR#3353 Phase C — doc list in docs tab
  var _docsFilterTimer = null;
  function onDocsFilterInput() {
    if (_docsFilterTimer) clearTimeout(_docsFilterTimer);
    _docsFilterTimer = setTimeout(loadDocsList, 300);
  }
  // FR#3472 B — debounce doc-id input; strip leading # + non-digits live.
  function onDocsIdInput() {
    var el = $('#pd-docs-id');
    if (el) {
      var cleaned = String(el.value || '').replace(/[^0-9#]/g, '').replace(/#/g, '');
      if (cleaned !== el.value) el.value = cleaned;
    }
    if (_docsFilterTimer) clearTimeout(_docsFilterTimer);
    _docsFilterTimer = setTimeout(loadDocsList, 300);
  }
  function filterDocsByType(type) {
    var typeSel = $('#pd-docs-type');
    if (typeSel) typeSel.value = type || '';
    // Chip active-state
    $$('.pd-doctypes-chip').forEach(function (c) {
      c.classList.toggle('is-active', (c.dataset.type || '') === (type || ''));
    });
    loadDocsList();
  }
  async function loadDocsList() {
    if (!currentProjectId) return;
    var body  = $('#pd-docs-body');
    var cntEl = $('#pd-docs-count');
    if (!body) return;
    var docIdRaw = String(($('#pd-docs-id') || {}).value || '').trim().replace(/^#/, '');
    var opts = {
      type:   ($('#pd-docs-type')   || {}).value || '',
      status: ($('#pd-docs-status') || {}).value || '',
      q:      ($('#pd-docs-q')      || {}).value || '',
      doc_id: /^\d+$/.test(docIdRaw) ? docIdRaw : '',
      limit:  200
    };
    body.innerHTML = '<tr><td colspan="5"><div class="empty-state"><span class="spinner"></span></div></td></tr>';
    try {
      var res  = await Api.listProjectDocs(currentProjectId, opts);
      var docs = res.documents || [];
      if (cntEl) cntEl.textContent = docs.length + ' doc' + (docs.length === 1 ? '' : 's');
      if (docs.length === 0) {
        body.innerHTML = '<tr><td colspan="5"><div class="empty-state">No documents match filter</div></td></tr>';
        return;
      }
      body.innerHTML = docs.map(function (d) {
        var typeCls = 'doc-cell-type doc-cell-type--' + d.doc_type;
        var updated = d.updated_at ? formatRelativeTime(d.updated_at) : '&mdash;';
        var summary = d.summary_l1 ? '<span class="doc-summary">' + escHtml(d.summary_l1) + '</span>' : '';
        var statusBadge = d.status ?
          '<span class="badge badge--small">' + escHtml(d.status) + '</span>' : '';
        var authorText = d.author_name || d.created_by || 'mcp';
        var updatedAbs = d.updated_at ? formatDate(d.updated_at) : '';
        var createdAbs = d.created_at ? formatDate(d.created_at) : '';
        var dateCell =
          '<div class="doc-date-rel">' + updated + '</div>' +
          (updatedAbs ? '<div class="doc-date-abs">' + escHtml(updatedAbs) + '</div>' : '') +
          (createdAbs && createdAbs !== updatedAbs ?
            '<div class="doc-date-created" title="created">+ ' + escHtml(createdAbs) + '</div>' : '');
        var actions =
          '<span class="doc-list-actions">' +
            '<button class="doc-action-btn doc-action-btn--small" onclick="event.stopPropagation(); App.openDoc(' + d.id + ')" title="View">' +
              '<i data-lucide="eye"></i></button>' +
            '<button class="doc-action-btn doc-action-btn--small doc-action-btn--danger" onclick="event.stopPropagation(); App.confirmDeleteDocFromList(' + d.id + ', \'' + escJsStr(d.title || '') + '\')" title="Delete">' +
              '<i data-lucide="trash-2"></i></button>' +
          '</span>';
        var isDel = String(d.status || '').trim().toLowerCase() === 'deleted';
        var rowCls = isDel ? 'doc-row--deleted' : '';
        return '<tr class="' + rowCls + '" data-status="' + escJsStr(d.status || '') + '" onclick="App.openDoc(' + d.id + ')">' +
          '<td class="doc-cell-title"><span class="doc-cell-id">#' + d.id + '</span> ' + escHtml(d.title || '(untitled)') + summary + '</td>' +
          '<td><span class="' + typeCls + '">' + escHtml(d.doc_type) + '</span></td>' +
          '<td>' + statusBadge + '</td>' +
          '<td class="doc-cell-by">' + escHtml(authorText) + '</td>' +
          '<td class="doc-cell-date" title="' + escJsStr(d.updated_at || '') + '">' + dateCell + '</td>' +
          '<td class="doc-cell-actions">' + actions + '</td></tr>';
      }).join('');
      Icons.render();
    } catch (err) {
      body.innerHTML = '<tr><td colspan="6"><div class="empty-state">Error loading documents</div></td></tr>';
    }
  }

  // FR#3353 Phase C — Doc-detail page (view-only)
  // FR#3600 — Tab-layout extension: url = #doc/:id or #doc/:id/:tab
  var _prevHashBeforeDoc = null;
  var _docProjectId = null;   // fallback when user refreshes directly on #doc/N
  async function openDoc(docId, initialTab) {
    if (!docId) return;
    var curHash = location.hash.replace('#', '') || '';
    // Only capture "before-doc" hash when coming from a non-doc page —
    // doc→doc navigation (relation click) must preserve the ORIGINAL origin
    if (curHash.indexOf('doc/') !== 0) {
      _prevHashBeforeDoc = curHash;
    }
    // Resolve tab: explicit arg > hash suffix > 'content' default
    var tab = initialTab;
    if (!tab) {
      var m = curHash.match(/^doc\/\d+\/([a-z]+)/);
      tab = (m && m[1]) || 'content';
    }
    if (['content', 'relations', 'reviews'].indexOf(tab) < 0) tab = 'content';
    location.hash = 'doc/' + docId + (tab !== 'content' ? '/' + tab : '');
    showPage('doc-detail');
    switchDocTab(tab, true);
    $('#doc-detail-title').textContent = 'Loading…';
    $('#doc-detail-type').textContent  = 'doc';
    $('#doc-detail-id').textContent    = '#' + docId;
    $('#doc-detail-content').textContent = '';
    $('#doc-detail-summary').textContent = '';
    $('#doc-detail-tags').innerHTML = '';
    // Clear stale panel-bodies so doc→doc navigation doesn't flash previous
    // doc's relations/thread while the new fetches are in flight.
    var relBody = $('#doc-detail-relations-body');
    if (relBody) relBody.innerHTML =
      '<tr><td colspan="4"><div class="empty-state"><span class="spinner"></span></div></td></tr>';
    var threadBody = $('#doc-detail-thread-body');
    if (threadBody) threadBody.innerHTML =
      '<div class="empty-state"><span class="spinner"></span></div>';
    // Reset tab-badges
    var relCnt = $('#doc-detail-rel-count'); if (relCnt) relCnt.setAttribute('hidden', '');
    var revCnt = $('#doc-detail-rev-count'); if (revCnt) revCnt.setAttribute('hidden', '');
    try {
      var d = await Api.getDoc(docId);
      _docProjectId = d.project_id || null;
      renderDocDetail(d);
      // FR#3472 A — fire-and-forget thread-load; silent on error/empty
      loadDocThread(docId);
    } catch (err) {
      showAlert('doc-detail-alert', 'error',
        'Failed to load doc: ' + (err && err.message ? err.message : 'unknown'));
      $('#doc-detail-title').textContent = 'Error';
    }
  }

  // FR#3600 — Doc-Detail tab switching (mirrors switchProjectTab).
  function switchDocTab(tabName, skipHashUpdate) {
    var valid = ['content', 'relations', 'reviews'];
    if (valid.indexOf(tabName) < 0) tabName = 'content';
    $$('#page-doc-detail .pd-tab').forEach(function (btn) {
      var on = btn.dataset.tab === tabName;
      btn.classList.toggle('is-active', on);
      btn.setAttribute('aria-selected', on ? 'true' : 'false');
      btn.setAttribute('tabindex', on ? '0' : '-1');
    });
    $$('#page-doc-detail .pd-tab-panel').forEach(function (panel) {
      var on = panel.dataset.panel === tabName;
      panel.classList.toggle('is-active', on);
      if (on) panel.removeAttribute('hidden');
      else panel.setAttribute('hidden', '');
    });
    if (!skipHashUpdate && _currentDoc) {
      location.hash = 'doc/' + _currentDoc.id +
        (tabName !== 'content' ? '/' + tabName : '');
    }
    Icons.render();
  }

  // FR#3472 A / SPEC#3583 — render review-thread inside Reviews-Tab (FR#3600).
  async function loadDocThread(docId) {
    var body = $('#doc-detail-thread-body');
    var count = $('#doc-detail-thread-count');
    var revTabCnt = $('#doc-detail-rev-count');
    var warn = $('#doc-detail-thread-warn');
    if (!body) return;
    try {
      var resp = await Api.getDocThread(docId);
      var thread = (resp && resp.thread) || [];
      // Empty-state when only root-row (no review-children) — tab stays visible.
      if (thread.length <= 1) {
        if (count) count.setAttribute('hidden', '');
        if (revTabCnt) revTabCnt.setAttribute('hidden', '');
        if (warn) warn.setAttribute('hidden', '');
        body.innerHTML = '<div class="empty-state">No review-thread for this document.</div>';
        return;
      }
      body.innerHTML = thread.map(function (n) {
        var typeCls = 'doc-cell-type doc-cell-type--' + (n.doc_type || 'note');
        var statusCls = n.status === 'active' ? 'active'
                       : n.status === 'archived' ? 'inactive'
                       : n.status === 'draft' ? 'read' : 'write';
        var author = n.author_name || '—';
        var when = n.created_at ? formatRelativeTime(n.created_at) : '';
        var titleLink = (n.id === docId)
          ? '<span class="thread-node__title thread-node__title--self">' + escHtml(n.title || '(untitled)') + '</span>'
          : '<a href="#" class="thread-node__title link" onclick="event.preventDefault();App.openDoc(' + n.id + ')">' +
              escHtml(n.title || '(untitled)') + '</a>';
        return '<div class="thread-node" style="padding-left:' + (n.depth * 20) + 'px">' +
          '<span class="doc-type-badge ' + typeCls + '">' + escHtml(n.doc_type || 'doc') + '</span> ' +
          titleLink +
          ' <span class="badge badge--small badge--' + statusCls + '">' + escHtml(n.status || '—') + '</span>' +
          ' <span class="thread-node__meta"><span class="thread-node__id mono">#' + n.id + '</span> · ' +
          escHtml(author) + ' · ' + escHtml(when) + '</span>' +
          '</div>';
      }).join('');
      // reply_count excludes root itself
      var replyCount = thread.length - 1;
      if (count) {
        count.textContent = replyCount;
        count.removeAttribute('hidden');
      }
      if (revTabCnt) {
        revTabCnt.textContent = replyCount;
        revTabCnt.removeAttribute('hidden');
      }
      // Cap warnings — guard count/warn spans AND resp fields (mxBugChecker W1)
      if (warn) {
        var warnMsgs = [];
        if (resp && resp.max_depth_reached) warnMsgs.push('max depth 10 reached — thread truncated');
        if (resp && resp.truncated)         warnMsgs.push('row cap 200 reached — additional replies not shown');
        if (warnMsgs.length) {
          warn.textContent = warnMsgs.join(' · ');
          warn.removeAttribute('hidden');
        } else {
          warn.setAttribute('hidden', '');
        }
      }
      Icons.render();
    } catch (e) {
      // Silent on error — show empty-state rather than hide entire tab.
      if (count) count.setAttribute('hidden', '');
      if (revTabCnt) revTabCnt.setAttribute('hidden', '');
      if (warn) warn.setAttribute('hidden', '');
      body.innerHTML = '<div class="empty-state">Failed to load review-thread.</div>';
    }
  }

  function renderDocDetail(d) {
    $('#doc-detail-title').textContent = d.title || '(untitled)';
    // Type badge with type-color class (reuse doc-cell-type palette)
    var typeEl = $('#doc-detail-type');
    typeEl.textContent = d.doc_type || 'doc';
    typeEl.className = 'doc-type-badge doc-cell-type doc-cell-type--' + (d.doc_type || 'note');
    $('#doc-detail-id').textContent    = '#' + d.id;
    var badge = $('#doc-detail-status');
    var statusCls = d.status === 'active' ? 'active'
                  : d.status === 'archived' ? 'inactive'
                  : d.status === 'draft' ? 'read' : 'write';
    badge.className = 'badge badge--' + statusCls;
    badge.textContent = d.status || '—';
    var projLink = $('#doc-detail-project');
    projLink.textContent = d.project_name || d.project_slug || '—';
    projLink.onclick = function (e) {
      e.preventDefault();
      if (d.project_id) openProject(d.project_id);
    };
    $('#doc-detail-author').textContent  = d.author_name || d.created_by || 'mcp';
    var createdEl = $('#doc-detail-created');
    if (createdEl) {
      createdEl.textContent = d.created_at ? formatRelativeTime(d.created_at) : '—';
      createdEl.title = d.created_at || '';
    }
    $('#doc-detail-updated').textContent = d.updated_at ? formatRelativeTime(d.updated_at) : '—';
    $('#doc-detail-updated').title       = d.updated_at || '';
    $('#doc-detail-tokens').textContent  = (d.token_estimate || 0) + ' tokens';
    // Confidence (only show if > 0)
    var confWrap = $('#doc-detail-conf-wrap');
    if (confWrap) {
      if (d.confidence && d.confidence > 0) {
        confWrap.removeAttribute('hidden');
        $('#doc-detail-conf').textContent = (d.confidence * 100).toFixed(0) + '%';
      } else {
        confWrap.setAttribute('hidden', '');
      }
    }
    // Tags — now inline in header top-line
    var tagBox = $('#doc-detail-tags');
    if (d.tags && d.tags.length) {
      tagBox.innerHTML = d.tags.map(function (t) {
        return '<span class="doc-detail__tag">' + escHtml(t) + '</span>';
      }).join('');
    } else {
      tagBox.innerHTML = '';
    }
    // Summary
    $('#doc-detail-summary').textContent = d.summary_l1 || '';
    // Content — plain pre/text for now (markdown rendering = later)
    $('#doc-detail-content').textContent = d.content || '(no content)';
    // Relations (FR#3600: always visible inside Relations-Tab, empty-state when 0)
    var relBody = $('#doc-detail-relations-body');
    var relCnt  = $('#doc-detail-rel-count');
    if (d.relations && d.relations.length) {
      if (relCnt) { relCnt.textContent = d.relations.length; relCnt.removeAttribute('hidden'); }
      relBody.innerHTML = d.relations.map(function (r) {
        var dirCls = r.direction === 'outbound' ? 'badge--write' : 'badge--read';
        return '<tr onclick="App.openDoc(' + r.target_id + ')" style="cursor:pointer">' +
          '<td><span class="badge badge--small ' + dirCls + '">' + escHtml(r.direction) + '</span></td>' +
          '<td><span class="badge badge--small">' + escHtml(r.relation_type) + '</span></td>' +
          '<td>' + escHtml(r.target_title) +
            ' <span class="text-secondary" style="font-size:0.8rem">(' +
              escHtml(r.target_type) + ' #' + r.target_id + ')</span></td>' +
          '<td style="text-align:right">' +
            (r.rel_id ?
              '<button class="rel-delete-btn" onclick="event.stopPropagation(); App.confirmDeleteRelation(' + r.rel_id + ', \'' + escJsStr(r.target_title) + '\', ' + d.id + ')" title="Delete relation">' +
                '<i data-lucide="x"></i></button>'
              : '') +
          '</td></tr>';
      }).join('');
    } else {
      if (relCnt) relCnt.setAttribute('hidden', '');
      relBody.innerHTML =
        '<tr><td colspan="4"><div class="empty-state">No relations.</div></td></tr>';
    }
    // Show Restore button + hide Delete button when viewing a deleted doc
    var isDeleted = d.status === 'deleted';
    var delBtn = $('#doc-detail-delete-btn');
    var restBtn = $('#doc-detail-restore-btn');
    var editBtn = $('#doc-detail-edit-btn');
    if (delBtn)  delBtn.style.display  = isDeleted ? 'none' : '';
    if (restBtn) restBtn.style.display = isDeleted ? '' : 'none';
    if (editBtn) editBtn.style.display = isDeleted ? 'none' : '';
    // Visual "deleted" cue on whole page
    var page = $('#page-doc-detail');
    if (page) page.classList.toggle('is-doc-deleted', isDeleted);
    // Store for edit-mode reuse
    _currentDoc = d;
    Icons.render();
  }

  async function confirmDeleteProjectRelation(relId, projName) {
    if (!window.confirm('Remove project relation to "' + projName + '"?')) return;
    try {
      await Api.deleteProjectRelation(relId);
      var proj = projectCache.find(function (p) { return p.id === currentProjectId; });
      if (proj) loadProjectDashboard(currentProjectId, proj);
    } catch (err) {
      alert('Failed: ' + (err && err.message ? err.message : 'unknown'));
    }
  }

  async function confirmRestoreDoc() {
    if (!_currentDoc) return;
    if (!window.confirm('Restore "' + (_currentDoc.title || _currentDoc.id) +
      '"?\n\nSets status=active again.')) return;
    try {
      await Api.updateDocAdmin(_currentDoc.id, {
        status: 'active',
        change_reason: 'Restored via Admin-UI'
      });
      showAlert('doc-detail-alert', 'success', 'Document restored.');
      var fresh = await Api.getDoc(_currentDoc.id);
      renderDocDetail(fresh);
    } catch (err) {
      showAlert('doc-detail-alert', 'error',
        'Restore failed: ' + (err && err.message ? err.message : 'unknown'));
    }
  }

  // FR#3353 Phase C — doc edit / delete / relation-delete handlers
  var _currentDoc = null;

  function toggleDocEdit(on) {
    var pre    = $('#doc-detail-content');
    var ta     = $('#doc-detail-edit-area');
    var reason = $('#doc-detail-edit-reason');
    var editBtn   = $('#doc-detail-edit-btn');
    var cancelBtn = $('#doc-detail-cancel-btn');
    var saveBtn   = $('#doc-detail-save-btn');
    var delBtn    = $('#doc-detail-delete-btn');
    if (on) {
      ta.value = _currentDoc ? (_currentDoc.content || '') : '';
      $('#doc-detail-reason-input').value = '';
      pre.setAttribute('hidden', '');
      ta.removeAttribute('hidden');
      reason.removeAttribute('hidden');
      editBtn.setAttribute('hidden', '');
      delBtn.setAttribute('hidden', '');
      cancelBtn.removeAttribute('hidden');
      saveBtn.removeAttribute('hidden');
      ta.focus();
    } else {
      ta.setAttribute('hidden', '');
      reason.setAttribute('hidden', '');
      pre.removeAttribute('hidden');
      cancelBtn.setAttribute('hidden', '');
      saveBtn.setAttribute('hidden', '');
      editBtn.removeAttribute('hidden');
      delBtn.removeAttribute('hidden');
    }
  }

  async function saveDocEdit() {
    if (!_currentDoc) return;
    var newContent = $('#doc-detail-edit-area').value;
    var reason = $('#doc-detail-reason-input').value || 'Admin-UI content edit';
    if (newContent === _currentDoc.content) {
      showAlert('doc-detail-alert', 'info', 'No changes.');
      toggleDocEdit(false);
      return;
    }
    var saveBtn = $('#doc-detail-save-btn');
    saveBtn.disabled = true;
    try {
      await Api.updateDocAdmin(_currentDoc.id, {
        content: newContent,
        change_reason: reason
      });
      showAlert('doc-detail-alert', 'success', 'Saved.');
      toggleDocEdit(false);
      // Reload doc detail
      var fresh = await Api.getDoc(_currentDoc.id);
      renderDocDetail(fresh);
    } catch (err) {
      var msg = err && err.message ? err.message : 'unknown';
      showAlert('doc-detail-alert', 'error',
        err && err.code === 'notes_require_mx_update_note'
          ? 'Notes must be edited via mx_update_note (M2.5 edit-window).'
          : 'Save failed: ' + msg);
    } finally {
      saveBtn.disabled = false;
    }
  }

  async function confirmDeleteDoc() {
    if (!_currentDoc) return;
    if (!window.confirm(
      'Delete document "' + (_currentDoc.title || _currentDoc.id) +
      '"?\n\nThis soft-deletes (status=deleted). Revisions are kept.'))
      return;
    try {
      await Api.deleteDoc(_currentDoc.id);
      showAlert('doc-detail-alert', 'success', 'Document deleted.');
      backFromDoc();
    } catch (err) {
      showAlert('doc-detail-alert', 'error',
        'Delete failed: ' + (err && err.message ? err.message : 'unknown'));
    }
  }

  async function confirmDeleteDocFromList(docId, docTitle) {
    if (!window.confirm('Delete "' + docTitle + '"?\n\nSoft-delete. Revisions kept.'))
      return;
    try {
      await Api.deleteDoc(docId);
      loadDocsList();
    } catch (err) {
      alert('Delete failed: ' + (err && err.message ? err.message : 'unknown'));
    }
  }

  async function confirmDeleteRelation(relId, targetTitle, docId) {
    if (!window.confirm('Remove relation to "' + targetTitle + '"?')) return;
    try {
      await Api.deleteRelation(relId);
      // Reload current doc to refresh relations table
      var fresh = await Api.getDoc(docId);
      renderDocDetail(fresh);
      showAlert('doc-detail-alert', 'success', 'Relation removed.');
    } catch (err) {
      showAlert('doc-detail-alert', 'error',
        'Failed: ' + (err && err.message ? err.message : 'unknown'));
    }
  }

  function backFromDoc() {
    var prev = _prevHashBeforeDoc;
    _prevHashBeforeDoc = null;
    // 1) Preferred: return to the project/tab we came from
    if (prev && prev.indexOf('project/') === 0) {
      var parts = prev.split('/');
      var pid = parseInt(parts[1], 10);
      var tab = parts[2] || 'docs';
      if (pid) {
        openProject(pid).then(function () { switchProjectTab(tab, true); });
        return;
      }
    }
    // 2) Fallback: use the doc's own project (covers direct-link refresh)
    if (_docProjectId) {
      var pid2 = _docProjectId;
      _docProjectId = null;
      openProject(pid2).then(function () { switchProjectTab('docs', true); });
      return;
    }
    // 3) Last resort: project list
    navigateTo('projects');
  }

  // FR#3353 Phase A Gap#6 — inline Add-Member panel
  function toggleAddMember() {
    var panel = $('#pd-add-member');
    var btn   = $('#btn-add-member');
    if (!panel) return;
    var opening = !panel.classList.contains('is-open');
    panel.classList.toggle('is-open', opening);
    panel.setAttribute('aria-hidden', opening ? 'false' : 'true');
    if (btn) btn.classList.toggle('is-active', opening);
    if (opening) {
      populateAddMemberDropdown();
    } else {
      var devSel = $('#pd-add-dev');
      var lvlSel = $('#pd-add-level');
      if (devSel) devSel.value = '';
      if (lvlSel) {
        lvlSel.value = 'read';
        lvlSel.className = 'acl-select acl-select--read add-member-form__level';
      }
    }
  }

  async function populateAddMemberDropdown() {
    if (!currentProjectId) return;
    var devSel = $('#pd-add-dev');
    var saveBtn = $('#pd-add-save');
    if (!devSel) return;
    devSel.innerHTML = '<option value="" disabled selected>Loading&hellip;</option>';
    if (saveBtn) saveBtn.disabled = true;
    try {
      var results = await Promise.all([
        Api.getProjectDashboard(currentProjectId),
        Api.getDevelopers()
      ]);
      var assigned = {};
      (results[0].developers || []).forEach(function (d) { assigned[d.id] = true; });
      var unassigned = (results[1].developers || []).filter(function (d) {
        return d.is_active && !assigned[d.id];
      });
      if (unassigned.length === 0) {
        devSel.innerHTML = '<option value="" disabled selected>&mdash; all developers assigned &mdash;</option>';
        if (saveBtn) saveBtn.disabled = true;
        return;
      }
      devSel.innerHTML = '<option value="" disabled selected>&mdash; select developer &mdash;</option>' +
        unassigned.map(function (d) {
          return '<option value="' + d.id + '">' + escHtml(d.name) + '</option>';
        }).join('');
      if (saveBtn) saveBtn.disabled = false;
      devSel.focus();
    } catch (err) {
      devSel.innerHTML = '<option value="" disabled selected>&mdash; load error &mdash;</option>';
    }
  }

  function onAddLevelChange(selectEl) {
    selectEl.className = 'acl-select acl-select--' +
      (selectEl.value === 'read-write' ? 'rw' : selectEl.value) + ' add-member-form__level';
  }

  async function submitAddMember() {
    if (!currentProjectId) return;
    var devSel = $('#pd-add-dev');
    var lvlSel = $('#pd-add-level');
    if (!devSel || !lvlSel) return;
    var devId = parseInt(devSel.value, 10);
    var level = lvlSel.value;
    if (!devId || !level || level === 'none') {
      showAlert('proj-detail-alert', 'error', 'Developer and access level required.');
      return;
    }
    var saveBtn = $('#pd-add-save');
    if (saveBtn) saveBtn.disabled = true;
    try {
      await Api.setProjectAccess(currentProjectId, devId, level);
      showAlert('proj-detail-alert', 'success', 'Member added.');
      toggleAddMember();
      var proj = projectCache.find(function (p) { return p.id === currentProjectId; });
      if (proj) loadProjectDashboard(currentProjectId, proj);
    } catch (err) {
      showAlert('proj-detail-alert', 'error',
        'Failed: ' + (err && err.message ? err.message : 'unknown'));
    } finally {
      if (saveBtn) saveBtn.disabled = false;
    }
  }

  // FR#3353 Phase A Gap#2: inline-edit ACL in project-detail member row
  async function onAclChange(devId, selectEl) {
    if (!currentProjectId) return;
    var newLevel = selectEl.value;
    var prevLevel = selectEl.getAttribute('data-prev') || '';
    // Optimistic class swap for immediate feedback
    selectEl.className = selectEl.className.replace(/\bacl-select--\S+/g, '');
    selectEl.classList.add('acl-select');
    selectEl.classList.add('acl-select--' + newLevel.replace('-', ''));
    selectEl.disabled = true;
    try {
      await Api.setProjectAccess(currentProjectId, devId, newLevel);
      selectEl.setAttribute('data-prev', newLevel);
      showAlert('proj-detail-alert', 'success',
        'Access updated: ' + newLevel);
    } catch (err) {
      showAlert('proj-detail-alert', 'error',
        'Failed: ' + (err.message || 'unknown'));
      // Revert on failure
      if (prevLevel) selectEl.value = prevLevel;
    } finally {
      selectEl.disabled = false;
    }
  }

  // ============================================================
  //   PROJECT LIST FILTER
  // ============================================================
  function filterProjectsByDev() {
    var sel = $('#proj-filter-dev');
    if (!sel) return;
    var devName = sel.value;
    var rows = $$('#proj-table-body tr');
    rows.forEach(function (row) {
      if (!devName || row.dataset.creator === devName) {
        row.style.display = '';
      } else {
        row.style.display = 'none';
      }
    });
  }

  async function runCleanup() {
    var btn = $('#btn-cleanup');
    var result = $('#cleanup-result');
    btn.disabled = true;
    btn.innerHTML = '<span class="spinner"></span> Laeuft...';
    result.textContent = '';

    try {
      var data = await Api.postCleanup();
      var count = data.archived_count || 0;
      result.textContent = count > 0
        ? count + ' Notes archiviert.'
        : 'No old notes found.';
      if (count > 0) loadGlobalPage(); // Refresh stats
    } catch (err) {
      result.textContent = 'Error: ' + err.message;
    } finally {
      btn.disabled = false;
      btn.innerHTML = 'Alte Notes archivieren';
    }
  }

  async function runBackup() {
    var btn = $('#btn-backup');
    var result = $('#backup-result');
    btn.disabled = true;
    btn.innerHTML = '<span class="spinner"></span> Backup laeuft...';
    result.textContent = '';

    try {
      var data = await Api.postBackup();
      var sizeKB = Math.round((data.size_bytes || 0) / 1024);
      result.textContent = 'Backup OK (' + sizeKB + ' KB)';
    } catch (err) {
      result.textContent = 'Error: ' + err.message;
    } finally {
      btn.disabled = false;
      btn.innerHTML = '<i data-lucide="database-backup" class="icon-xs"></i> DB Backup';
      if (typeof Icons !== 'undefined') Icons.render();
    }
  }

  // --- Init ---
  async function init() {
    // Re-render icons after initial DOM parse (icons.js auto-renders once)
    if (typeof Icons !== 'undefined') Icons.render();

    initLogin();
    initLogout();
    initCreateDeveloper();
    initMerge();
    initTabs();
    initDetailSave();
    initCreateKey();
    initSaveAccess();
    initBackButton();
    initProjectDetail();
    initProjectMerge();
    initModalCloses();

    // Settings form (v2.4.0)
    var settingsForm = $('#settings-form');
    if (settingsForm) {
      settingsForm.addEventListener('submit', saveSettings);
    }

    // New invite form (v2.4.0)
    var newInviteForm = $('#new-invite-form');
    if (newInviteForm) {
      newInviteForm.addEventListener('submit', onNewInviteSubmit);
    }

    // Try to restore existing session (cookie still valid after refresh)
    try {
      var data = await Api.checkSession();
      Api.setCsrfToken(data.csrf_token);
      setUserUI(data.developer.name);
      $('#page-login').style.display = 'none';
      // Setup mode: first start with no members → go to Team Members page
      // Detect via developer.id === 0 (server sets DeveloperId=0 in HasNoDevelopers bypass)
      var isSetupMode = data.developer && data.developer.id === 0;
      var restoreHash = location.hash.replace('#', '') || (isSetupMode ? 'developers' : 'global');
      if (restoreHash.indexOf('developer/') === 0) {
        var devParts = restoreHash.split('/');
        var devId = parseInt(devParts[1]);
        var devTab = devParts[2] || 'info';
        if (devId) {
          openDeveloper(devId).then(function () {
            // Restore tab
            var tabBtn = $('.tab-btn[data-tab="' + devTab + '"]');
            if (tabBtn) tabBtn.click();
          });
          return;
        }
      }
      if (restoreHash.indexOf('project/') === 0) {
        var projParts = restoreHash.split('/');
        var projId = parseInt(projParts[1]);
        var projTab = projParts[2] || 'team';
        if (projId) {
          openProject(projId).then(function () {
            switchProjectTab(projTab, true);
          });
          return;
        }
      }
      if (restoreHash.indexOf('doc/') === 0) {
        var docParts = restoreHash.split('/');
        var docId = parseInt(docParts[1]);
        var docTab = docParts[2] || 'content';
        if (docId) { openDoc(docId, docTab); return; }
      }
      // FR#3296 — Settings hash #settings/:tab restore
      if (restoreHash.indexOf('settings') === 0) {
        var setParts = restoreHash.split('/');
        var setTab = setParts[1] || 'self-update';
        loadSettingsPage().then(function () { switchSettingsTab(setTab, true); });
        return;
      }
      if (restoreHash !== 'global' && restoreHash !== 'intelligence' && restoreHash !== 'developers' && restoreHash !== 'projects' && restoreHash !== 'settings' && restoreHash !== 'connect') restoreHash = 'global';
      navigateTo(restoreHash);
    } catch (e) {
      showLogin();
    }
  }

  document.addEventListener('DOMContentLoaded', init);

  // Public API
  return {
    showLogin: showLogin,
    navigateTo: navigateTo,
    openDeveloper: openDeveloper,
    confirmDelete: confirmDelete,
    deactivateKey: deactivateKey,
    closeModal: closeModal,
    loadDeveloperList: loadDeveloperList,
    loadProjectList: loadProjectList,
    openProject: openProject,
    confirmDeleteProject: confirmDeleteProject,
    onAclChange: onAclChange,
    switchProjectTab: switchProjectTab,
    toggleAddMember: toggleAddMember,
    submitAddMember: submitAddMember,
    onAddLevelChange: onAddLevelChange,
    loadDocsList: loadDocsList,
    filterDocsByType: filterDocsByType,
    onDocsFilterInput: onDocsFilterInput,
    onDocsIdInput: onDocsIdInput,
    openDoc: openDoc,
    switchDocTab: switchDocTab,
    loadDocThread: loadDocThread,
    loadProjectReviews: loadProjectReviews,
    backFromDoc: backFromDoc,
    toggleDocEdit: toggleDocEdit,
    saveDocEdit: saveDocEdit,
    confirmDeleteDoc: confirmDeleteDoc,
    confirmDeleteDocFromList: confirmDeleteDocFromList,
    confirmDeleteRelation: confirmDeleteRelation,
    confirmDeleteProjectRelation: confirmDeleteProjectRelation,
    confirmRestoreDoc: confirmRestoreDoc,
    deleteEnvironment: deleteEnvironment,
    hardDeleteKey: hardDeleteKey,
    changeKeyRole: changeKeyRole,
    loadGlobalPage: loadGlobalPage,
    loadSkillsPage: loadSkillsPage,
    switchSettingsTab: switchSettingsTab,
    switchSkillTab: switchSkillTab,
    skillFeedback: skillFeedback,
    runCleanup: runCleanup,
    runBackup: runBackup,
    filterProjectsByDev: filterProjectsByDev,
    setFindingsFilter: setFindingsFilter,

    // Settings (v2.4.0)
    loadSettingsPage: loadSettingsPage,
    saveSettings: saveSettings,
    testConnection: testConnection,

    // Connect Team (v2.4.0)
    loadConnectPage: loadConnectPage,
    openNewInviteDialog: openNewInviteDialog,
    copyInviteField: copyInviteField,
    revokeInvite: revokeInvite,
    deleteInvite: deleteInvite,
    cleanupInvites: cleanupInvites
  };
})();
