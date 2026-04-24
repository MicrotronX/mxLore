/* ============================================================
   project-bundle.js — FR#3896 Project Export/Import
   Admin-UI module: multi-select + encrypted .mxbundle export,
                    wizard-based import with preview + conflict-res.
   Depends on: api.js (Api.getCsrfToken), app.js (escHtml helper).
   ============================================================ */

(function () {
  'use strict';

  // Internal state
  var selectedIds = new Set();
  var lastImportPreview = null;
  var lastImportBundleB64 = null;
  var lastImportSecret = null;
  // Wizard state — persists user choices across Back/Next navigation.
  var wizardState = {
    conflicts: [],   // [{source_slug, resolution, new_slug}]
    devMap: {},      // { source_id: local_id }
    mapToMe: false
  };

  function renderStepIndicator(current) {
    var steps = ['File', 'Conflicts', 'Developers', 'Confirm', 'Result'];
    return (
      '<div style="display:flex;gap:4px;align-items:center;margin-bottom:12px;' +
        'font-size:0.75rem;color:var(--text-tertiary,#888)">' +
        steps.map(function (s, i) {
          var idx = i + 1;
          var active = idx === current;
          var done = idx < current;
          var style = 'padding:4px 10px;border-radius:12px;' +
            (active ? 'background:var(--accent,#4f46e5);color:white;font-weight:600' :
             done   ? 'background:var(--accent-glow,#eef2ff);color:var(--accent,#4f46e5)' :
                      'background:var(--bg-muted,#f6f8fa);color:var(--text-tertiary,#888)');
          return '<span style="' + style + '">' +
            (done ? '&#x2713; ' : idx + '. ') + esc(s) + '</span>' +
            (idx < steps.length ? '<span style="color:var(--text-tertiary,#888)">&rarr;</span>' : '');
        }).join('') +
      '</div>'
    );
  }

  function esc(s) {
    if (s === null || s === undefined) return '';
    return String(s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;')
      .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }

  function dom(html) {
    var t = document.createElement('template');
    t.innerHTML = html.trim();
    return t.content.firstChild;
  }

  // Convert File to Base64 (strips data-url prefix).
  function fileToBase64(file) {
    return new Promise(function (resolve, reject) {
      var r = new FileReader();
      r.onload = function () {
        var s = r.result;
        var i = s.indexOf(',');
        resolve(i >= 0 ? s.substring(i + 1) : s);
      };
      r.onerror = reject;
      r.readAsDataURL(file);
    });
  }

  // --- Multi-Select integration -------------------------------------------
  //
  // Piggybacks on the existing `.proj-merge-check` checkboxes used by the
  // merge-feature in app.js — no second checkbox column. We just poll the
  // live DOM state whenever the export button is clicked and mirror it
  // into our own selectedIds on every change event.

  function getCheckedProjectIds() {
    var ids = [];
    document.querySelectorAll('.proj-merge-check:checked').forEach(function (cb) {
      var id = parseInt(cb.getAttribute('data-id'), 10);
      if (!isNaN(id)) ids.push(id);
    });
    return ids;
  }

  function getCheckedProjectList() {
    var list = [];
    document.querySelectorAll('.proj-merge-check:checked').forEach(function (cb) {
      list.push({
        id:   parseInt(cb.getAttribute('data-id'), 10),
        name: cb.getAttribute('data-name') || ('#' + cb.getAttribute('data-id'))
      });
    });
    return list;
  }

  function injectSelectionUI() {
    var tbody = document.getElementById('proj-table-body');
    if (!tbody) return;

    // FR#3360 lockdown: Export/Import/Merge are admin-only (backend gates
    // POST /export, POST /import, POST /projects/merge). Don't render the
    // selection bar or Import button for non-admin devs.
    if (window.AclHelper && !AclHelper.isAdmin()) return;

    // Inject action-bar once. Hides the original #proj-merge-bar and
    // absorbs its Merge button into a single selection-aware bar. The bar
    // itself is hidden when 0 projects are selected (via .visible toggle);
    // the persistent Import Bundle button lives next to the dev-filter so
    // it's reachable without any selection.
    if (!document.getElementById('mx-bundle-bar')) {
      var origMergeBar = document.getElementById('proj-merge-bar');
      var bar = dom(
        '<div id="mx-bundle-bar" class="merge-bar">' +
          '<div class="merge-bar__left">' +
            '<i data-lucide="package" class="icon-sm"></i>' +
            '<span class="merge-bar__info"><span id="mx-bundle-count">0</span> selected</span>' +
          '</div>' +
          '<div style="display:flex;gap:8px;align-items:center">' +
            '<button type="button" id="mx-bundle-export-btn" class="btn btn--primary btn--small">' +
              '<i data-lucide="download" class="icon-xs"></i> Export Selected' +
            '</button>' +
            '<span style="display:inline-block;width:24px"></span>' +
            '<button type="button" id="mx-bundle-merge-btn" class="btn btn--small" disabled>' +
              '<i data-lucide="git-merge" class="icon-xs"></i> Merge Selected' +
            '</button>' +
          '</div>' +
        '</div>');

      if (origMergeBar) {
        origMergeBar.style.display = 'none';
        origMergeBar.parentNode.insertBefore(bar, origMergeBar.nextSibling);
      } else {
        tbody.parentNode.parentNode.insertBefore(bar, tbody.parentNode);
      }

      document.getElementById('mx-bundle-export-btn')
        .addEventListener('click', openExportModal);
      document.getElementById('mx-bundle-merge-btn')
        .addEventListener('click', function () {
          var btn = document.getElementById('btn-proj-merge');
          if (btn) btn.click();
        });
    }

    // Persistent Import-Bundle button next to the dev-filter (always visible).
    if (!document.getElementById('mx-bundle-import-btn')) {
      var filterRow = document.getElementById('proj-filter-dev');
      if (filterRow && filterRow.parentNode) {
        var importBtn = dom(
          '<button type="button" id="mx-bundle-import-btn" class="btn btn--small" ' +
            'style="margin-left:8px;vertical-align:middle">' +
            '<i data-lucide="upload" class="icon-xs"></i> Import Bundle...' +
          '</button>');
        filterRow.parentNode.appendChild(importBtn);
        importBtn.addEventListener('click', openImportModal);
      }
    }

    if (window.lucide && window.lucide.createIcons) window.lucide.createIcons();

    // Wire change-listener on the shared merge-checkboxes (idempotent).
    document.querySelectorAll('.proj-merge-check').forEach(function (cb) {
      if (cb.dataset.mxBundleWired === '1') return;
      cb.dataset.mxBundleWired = '1';
      cb.addEventListener('change', updateSelectionUI);
    });

    updateSelectionUI();
  }

  function updateSelectionUI() {
    var bar = document.getElementById('mx-bundle-bar');
    var countEl = document.getElementById('mx-bundle-count');
    var mergeBtn = document.getElementById('mx-bundle-merge-btn');
    if (!bar || !countEl) return;
    var ids = getCheckedProjectIds();
    selectedIds = new Set(ids);
    countEl.textContent = String(selectedIds.size);
    if (selectedIds.size > 0) bar.classList.add('visible');
    else                      bar.classList.remove('visible');
    if (mergeBtn) mergeBtn.disabled = selectedIds.size < 2;
  }

  // --- Export Modal -------------------------------------------------------

  function openExportModal() {
    if (selectedIds.size === 0) return;

    var html =
      '<div id="mx-export-modal" class="modal-overlay visible">' +
        '<div class="modal" style="max-width:520px">' +
          '<div class="modal__header">' +
            '<div class="modal__title">' +
              '<i data-lucide="download"></i>' +
              'Export ' + selectedIds.size + ' project(s) as .mxbundle' +
            '</div>' +
            '<button class="modal__close-btn" id="mx-export-close" title="Close">' +
              '<i data-lucide="x"></i>' +
            '</button>' +
          '</div>' +

          '<div class="modal__body">' +
            '<p style="margin:0;color:var(--text-secondary,#666);font-size:0.85rem">' +
              'Encrypted bundle for migration to another mxLore server.</p>' +

            '<div class="form-group">' +
              '<label class="form-label">Selected projects (' + selectedIds.size + ')</label>' +
              '<div style="max-height:140px;overflow-y:auto;border:1px solid var(--border,#e5e7eb);' +
                  'border-radius:var(--radius-sm,4px);padding:6px 10px;font-size:0.85rem;' +
                  'background:var(--bg-muted,#f9fafb)">' +
                getCheckedProjectList().map(function (p) {
                  return '<div style="padding:2px 0">' +
                    '<span class="mono" style="color:var(--text-tertiary,#888)">#' + p.id + '</span> ' +
                    esc(p.name) + '</div>';
                }).join('') +
              '</div>' +
            '</div>' +

            '<div class="form-group">' +
              '<label class="form-label">Encryption mode</label>' +
              '<label style="display:block;padding:4px 0">' +
                '<input type="radio" name="mx-export-mode" value="api_key" checked> ' +
                '<b>API-key (current login)</b> &mdash; bundle tied to this dev-key</label>' +
              '<label style="display:block;padding:4px 0">' +
                '<input type="radio" name="mx-export-mode" value="passphrase"> ' +
                '<b>Passphrase</b> &mdash; portable, share-able</label>' +
            '</div>' +

            '<div class="form-group">' +
              '<label class="form-label" for="mx-export-secret">Secret (API-key or passphrase)</label>' +
              '<input type="password" id="mx-export-secret" class="form-input mono" ' +
                'autocomplete="new-password" spellcheck="false" name="mx-export-secret-' +
                Date.now() + '">' +
            '</div>' +

            '<div class="form-group">' +
              '<label class="form-label">Content</label>' +
              '<label style="display:block;padding:2px 0"><input type="checkbox" id="mx-export-revs" checked> Include document revisions</label>' +
              '<label style="display:block;padding:2px 0"><input type="checkbox" id="mx-export-env" checked> Include env-vars (re-encrypted)</label>' +
              '<label style="display:block;padding:2px 0"><input type="checkbox" id="mx-export-acl" checked> Include ACL entries</label>' +
            '</div>' +

            '<div id="mx-export-warning" class="alert alert--warning">' +
              '<i data-lucide="alert-triangle" class="icon-sm"></i> ' +
              'API-key mode: this bundle is tied to your current API-key. Rotating it makes the bundle undecryptable.' +
            '</div>' +
          '</div>' +

          '<div class="modal__footer">' +
            '<button type="button" class="btn" id="mx-export-cancel">Cancel</button>' +
            '<button type="button" class="btn btn--primary" id="mx-export-go">' +
              '<i data-lucide="download" class="icon-xs"></i> Export &amp; Download' +
            '</button>' +
          '</div>' +
        '</div>' +
      '</div>';
    document.body.appendChild(dom(html));
    if (window.lucide && window.lucide.createIcons) window.lucide.createIcons();

    document.getElementsByName('mx-export-mode').forEach(function (r) {
      r.addEventListener('change', function () {
        document.getElementById('mx-export-warning').style.display =
          (r.value === 'api_key' && r.checked) ? '' : 'none';
      });
    });

    // Typing a secret → auto-select passphrase mode (API-keys come from the
    // current session, users usually won't paste them here).
    var secret = document.getElementById('mx-export-secret');
    secret.addEventListener('input', function () {
      if (secret.value.length > 0) {
        var pp = document.querySelector('input[name="mx-export-mode"][value="passphrase"]');
        if (pp && !pp.checked) {
          pp.checked = true;
          pp.dispatchEvent(new Event('change'));
        }
      }
    });

    document.getElementById('mx-export-cancel').addEventListener('click', closeExportModal);
    document.getElementById('mx-export-close').addEventListener('click', closeExportModal);
    document.getElementById('mx-export-go').addEventListener('click', executeExport);
  }

  function closeExportModal() {
    var m = document.getElementById('mx-export-modal');
    if (m) m.remove();
  }

  async function executeExport() {
    var mode = '';
    document.getElementsByName('mx-export-mode').forEach(function (r) {
      if (r.checked) mode = r.value;
    });
    var secret = document.getElementById('mx-export-secret').value;
    if (!secret) {
      alert('Please enter a secret (API-key or passphrase).');
      return;
    }

    var body = {
      project_ids: Array.from(selectedIds),
      crypto_mode: mode,
      secret: secret,
      include_revisions: document.getElementById('mx-export-revs').checked,
      include_env_vars:  document.getElementById('mx-export-env').checked,
      include_acl:       document.getElementById('mx-export-acl').checked
    };

    var btn = document.getElementById('mx-export-go');
    btn.disabled = true;
    btn.textContent = 'Exporting...';

    try {
      var res = await fetch('api/export', {
        method: 'POST',
        credentials: 'same-origin',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': (typeof Api !== 'undefined' && Api.getCsrfToken ? Api.getCsrfToken() : '')
        },
        body: JSON.stringify(body)
      });

      if (!res.ok) {
        var txt = await res.text();
        throw new Error('HTTP ' + res.status + ': ' + txt);
      }

      // Trigger file download
      var blob = await res.blob();
      var cd = res.headers.get('Content-Disposition') || '';
      var m = /filename="([^"]+)"/.exec(cd);
      var name = m ? m[1] : 'mxLore-export.mxbundle';

      var a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = name;
      document.body.appendChild(a);
      a.click();
      setTimeout(function () {
        document.body.removeChild(a);
        URL.revokeObjectURL(a.href);
      }, 0);

      var n = res.headers.get('X-MxLore-Bundle-Project-Count') || '?';
      var d = res.headers.get('X-MxLore-Bundle-Doc-Count') || '?';
      var drop = res.headers.get('X-MxLore-Bundle-Dropped-Relations') || '0';
      alert('Exported ' + n + ' project(s), ' + d + ' document(s). ' +
        (drop !== '0' ? ('Dropped ' + drop + ' cross-bundle relation(s).') : ''));
      closeExportModal();
    } catch (e) {
      // WF-2026-04-24-001 Task-Bonus - log raw error for devtools before the
      // UX-friendly alert (retained because no dedicated alert target exists
      // in this modal at this point).
      console.error('[bundle] Export failed:', e);
      alert('Export failed: ' + (e && e.message ? e.message : String(e)));
      btn.disabled = false;
      btn.textContent = 'Export & Download';
    }
  }

  // --- Import Wizard ------------------------------------------------------

  function openImportModal() {
    var html =
      '<div id="mx-import-modal" class="modal-overlay visible">' +
        '<div class="modal" style="max-width:720px">' +
          '<div class="modal__header">' +
            '<div class="modal__title">' +
              '<i data-lucide="upload"></i>Import .mxbundle' +
            '</div>' +
            '<button class="modal__close-btn" id="mx-import-close" title="Close">' +
              '<i data-lucide="x"></i>' +
            '</button>' +
          '</div>' +
          '<div class="modal__body" id="mx-import-step">' + renderImportStep1() + '</div>' +
        '</div>' +
      '</div>';
    document.body.appendChild(dom(html));
    if (window.lucide && window.lucide.createIcons) window.lucide.createIcons();
    document.getElementById('mx-import-close').addEventListener('click', closeImportModal);
    wireStep1();
  }

  function closeImportModal() {
    var m = document.getElementById('mx-import-modal');
    if (m) m.remove();
    lastImportPreview = null;
    lastImportBundleB64 = null;
    lastImportSecret = null;
    wizardState = { conflicts: [], devMap: {}, mapToMe: false };
  }

  function renderImportStep1() {
    return (
      renderStepIndicator(1) +
      '<p style="margin:0;color:var(--text-secondary,#666);font-size:0.85rem">' +
        'Select the .mxbundle file and enter the secret used at export.</p>' +
      '<div class="form-group">' +
        '<label class="form-label" for="mx-import-file">Bundle file</label>' +
        '<input type="file" id="mx-import-file" accept=".mxbundle,.zip" class="form-input">' +
      '</div>' +
      '<div class="form-group">' +
        '<label class="form-label" for="mx-import-secret">Secret (API-key or passphrase)</label>' +
        '<input type="password" id="mx-import-secret" class="form-input mono" ' +
          'autocomplete="new-password" spellcheck="false" name="mx-import-secret-' +
          Date.now() + '">' +
      '</div>' +
      '<div id="mx-import-msg" class="alert alert--error" style="display:none"></div>' +
      '<div class="modal__footer" style="padding:0;border:none;margin-top:8px">' +
        '<button type="button" class="btn" id="mx-import-cancel1">Cancel</button>' +
        '<button type="button" class="btn btn--primary" id="mx-import-preview-btn">' +
          '<i data-lucide="eye" class="icon-xs"></i> Decrypt &amp; Preview' +
        '</button>' +
      '</div>'
    );
  }

  function wireStep1() {
    document.getElementById('mx-import-preview-btn')
      .addEventListener('click', previewImport);
    document.getElementById('mx-import-cancel1')
      .addEventListener('click', closeImportModal);
  }

  function showMsg(elId, text, isError) {
    var m = document.getElementById(elId);
    if (!m) return;
    m.textContent = text;
    m.style.display = 'block';
    if (isError) {
      m.classList.remove('alert--info');
      m.classList.add('alert--error');
    } else {
      m.classList.remove('alert--error');
      m.classList.add('alert--info');
    }
  }

  async function previewImport() {
    console.log('[project-bundle] Preview button clicked');
    var fileInput = document.getElementById('mx-import-file');
    var secretInput = document.getElementById('mx-import-secret');
    var btn = document.getElementById('mx-import-preview-btn');

    if (!fileInput.files || fileInput.files.length === 0) {
      showMsg('mx-import-msg', 'Pick a bundle file first.', true);
      return;
    }
    if (!secretInput.value) {
      showMsg('mx-import-msg', 'Enter the secret.', true);
      return;
    }

    showMsg('mx-import-msg', 'Decrypting... (this may take a few seconds for large bundles)', false);
    if (btn) { btn.disabled = true; btn.textContent = 'Decrypting...'; }

    try {
      var b64 = await fileToBase64(fileInput.files[0]);
      console.log('[project-bundle] Bundle base64 size:', b64.length);
      var body = {
        bundle_b64: b64,
        secret: secretInput.value,
        preview: true
      };
      var res = await fetch('api/import', {
        method: 'POST',
        credentials: 'same-origin',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': (typeof Api !== 'undefined' && Api.getCsrfToken ? Api.getCsrfToken() : '')
        },
        body: JSON.stringify(body)
      });
      console.log('[project-bundle] Preview response status:', res.status);
      if (!res.ok) {
        var err = await res.json().catch(function(){return{};});
        var txt;
        if (res.status === 401) {
          txt = 'Wrong key or passphrase — bundle cannot be decrypted.';
        } else if (res.status === 403) {
          // WF-2026-04-24-001 Task-Bonus - Import is admin-only server-side.
          txt = 'Import is admin-only — log in as admin.';
        } else {
          txt = 'Preview failed (' + res.status + '): ' + (err.error || 'unknown');
        }
        console.error('[project-bundle] Preview failed:', res.status, err);
        showMsg('mx-import-msg', txt, true);
        if (btn) { btn.disabled = false; btn.innerHTML = '<i data-lucide="eye" class="icon-xs"></i> Preview'; if (window.lucide) window.lucide.createIcons(); }
        return;
      }
      lastImportPreview = await res.json();
      lastImportBundleB64 = b64;
      lastImportSecret = secretInput.value;

      // Fetch local developers list for pretty mapping dropdowns.
      try {
        var devResp = await fetch('api/developers', {
          credentials: 'same-origin',
          headers: { 'Content-Type': 'application/json' }
        });
        if (devResp.ok) {
          var devData = await devResp.json();
          lastImportPreview._localDevs = (devData.developers || devData || []);
        }
      } catch (e) {
        // WF-2026-04-24-001 Task-Bonus - non-fatal (mapping-UI degrades to
        // number input) but surface the cause for devtools.
        console.warn('[bundle] Dev-list fetch failed — mapping-UI may be degraded:', e);
      }

      // Fetch current admin id for "Map all to me" visualization.
      try {
        var meResp = await fetch('api/auth/check', { credentials: 'same-origin' });
        if (meResp.ok) {
          var meData = await meResp.json();
          if (meData && meData.developer) {
            lastImportPreview._meDevId = meData.developer.id;
            lastImportPreview._meDevName = meData.developer.name;
          }
        }
      } catch (e) {
        // WF-2026-04-24-001 Task-Bonus - non-fatal; "Map all to me" just
        // won't show the current admin's name. Surface for devtools.
        console.warn('[bundle] auth/check fetch failed — "Map all to me" visualization degraded:', e);
      }

      renderStep2();
    } catch (e) {
      console.error('[project-bundle] Preview exception:', e);
      showMsg('mx-import-msg', 'Error: ' + (e && e.message ? e.message : String(e)), true);
      if (btn) { btn.disabled = false; btn.innerHTML = '<i data-lucide="eye" class="icon-xs"></i> Preview'; if (window.lucide) window.lucide.createIcons(); }
    }
  }

  // ---- Step 2 (Conflicts) ----
  function renderStep2() {
    var p = lastImportPreview;
    var m = p.manifest || {};
    var enc = m.encryption || {};
    var collisionList = (p.conflicts || []).filter(function (c) { return c.local_id > 0; });

    // Prime wizardState.conflicts if empty (first entry) — keep user edits on Back/Next.
    if (!wizardState.conflicts || wizardState.conflicts.length === 0) {
      wizardState.conflicts = (p.conflicts || []).map(function (c) {
        return {
          source_slug: c.source_slug,
          local_id: c.local_id,
          local_name: c.local_name,
          source_name: c.source_name,
          resolution: 'rename-new-slug',
          new_slug: c.suggested_new_slug
        };
      });
    }

    var html =
      renderStepIndicator(2) +

      // Manifest summary card
      '<div style="background:var(--bg-muted,#f6f8fa);border:1px solid var(--border,#e5e7eb);' +
          'border-radius:var(--radius-md,8px);padding:var(--gap-sm,10px) var(--gap-md,14px);' +
          'font-size:0.85rem;display:grid;grid-template-columns:auto 1fr;gap:4px 12px">' +
        '<b>Origin</b><span>' + esc(m.origin_server || '?') + '</span>' +
        '<b>Build</b><span>' + esc(m.mxlore_build || '?') + ' &middot; exported ' + esc(m.export_date || '?') + '</span>' +
        '<b>Crypto</b><span>' + esc(enc.algorithm || '?') + ' / ' + esc(enc.mode || '?') +
          ' / iter ' + esc(enc.iterations || '?') + '</span>' +
        '<b>Projects</b><span>' + (m.projects || []).map(function (p) { return esc(p.slug); }).join(', ') + '</span>' +
      '</div>' +

      '<div class="form-group">' +
        '<label class="form-label">Slug collisions (' + collisionList.length + ')</label>';

    if (collisionList.length === 0) {
      html += '<div class="alert" style="background:#dcfce7;border:1px solid #16a34a;color:#166534">' +
        '<i data-lucide="check-circle" class="icon-sm"></i> ' +
        '<b>No collisions</b> &mdash; all slugs are new on this server.</div>';
    } else {
      html += '<div class="alert alert--warning" style="margin-bottom:8px">' +
        '<i data-lucide="alert-triangle" class="icon-sm"></i> ' +
        '<b>' + collisionList.length + ' collision(s)</b> — pick resolution per row. ' +
        'Default <b>Save as new slug</b> is safest.</div>';

      html += '<div class="data-table-wrap"><table class="data-table">' +
        '<thead><tr>' +
          '<th style="width:24px"></th>' +
          '<th>Source slug</th>' +
          '<th>Local conflict</th>' +
          '<th style="width:200px">Resolution</th>' +
          '<th>New slug (if rename)</th>' +
        '</tr></thead><tbody>';
      wizardState.conflicts.forEach(function (c) {
        if (!c.local_id) return;
        // Color-code the resolution dropdown by current value so the choice
        // stands out even at a glance across many rows.
        var resColor =
          c.resolution === 'overwrite'       ? '#b91c1c' :   // red
          c.resolution === 'skip'            ? '#a16207' :   // amber
          /* rename-new-slug (default) */       '#15803d';   // green
        var resBg =
          c.resolution === 'overwrite'       ? '#fee2e2' :
          c.resolution === 'skip'            ? '#fef3c7' :
                                               '#dcfce7';

        html += '<tr style="background:rgba(251,191,36,0.08)">' +
          '<td style="text-align:center">' +
            '<i data-lucide="alert-triangle" class="icon-sm" style="color:#d97706"></i>' +
          '</td>' +
          '<td class="mono"><b>' + esc(c.source_slug) + '</b></td>' +
          '<td>#' + c.local_id + ' ' + esc(c.local_name) + '</td>' +
          '<td>' +
            '<select class="form-input" data-cres="' + esc(c.source_slug) + '" ' +
              'style="padding:4px 8px;width:100%;font-weight:700;' +
              'color:' + resColor + ';background:' + resBg + ';' +
              'border:2px solid ' + resColor + '">' +
              '<option value="rename-new-slug"' + (c.resolution === 'rename-new-slug' ? ' selected' : '') + '>Save as new slug</option>' +
              '<option value="skip"' + (c.resolution === 'skip' ? ' selected' : '') + '>Skip import</option>' +
              '<option value="overwrite"' + (c.resolution === 'overwrite' ? ' selected' : '') + '>Overwrite existing</option>' +
            '</select>' +
          '</td>' +
          '<td><input class="form-input mono" style="padding:4px 8px" ' +
            'data-cnew="' + esc(c.source_slug) + '" value="' + esc(c.new_slug) + '"></td>' +
        '</tr>';
      });
      html += '</tbody></table></div>';
    }
    html += '</div>';

    html += '<div id="mx-import-msg2" class="alert alert--error" style="display:none"></div>';

    html += '<div class="modal__footer" style="padding:0;border:none;margin-top:8px">' +
      '<button type="button" class="btn" id="mx-import-back">' +
        '<i data-lucide="chevron-left" class="icon-xs"></i> Back' +
      '</button>' +
      '<button type="button" class="btn" id="mx-import-cancel2">Cancel</button>' +
      '<button type="button" class="btn btn--primary" id="mx-import-next2">' +
        'Next <i data-lucide="chevron-right" class="icon-xs"></i>' +
      '</button>' +
    '</div>';

    document.getElementById('mx-import-step').innerHTML = html;
    if (window.lucide && window.lucide.createIcons) window.lucide.createIcons();

    document.getElementById('mx-import-back').addEventListener('click', function () {
      document.getElementById('mx-import-step').innerHTML = renderImportStep1();
      if (window.lucide && window.lucide.createIcons) window.lucide.createIcons();
      wireStep1();
    });
    document.getElementById('mx-import-cancel2').addEventListener('click', closeImportModal);
    document.getElementById('mx-import-next2').addEventListener('click', function () {
      // Collect user's conflict choices into wizardState.
      wizardState.conflicts.forEach(function (c) {
        if (!c.local_id) return;
        var sel = document.querySelector('select[data-cres="' + CSS.escape(c.source_slug) + '"]');
        var inp = document.querySelector('input[data-cnew="' + CSS.escape(c.source_slug) + '"]');
        if (sel) c.resolution = sel.value;
        if (inp) c.new_slug = inp.value;
      });
      renderStep2B();
    });

    // Re-color resolution dropdowns on change so the visual state tracks selection.
    document.querySelectorAll('select[data-cres]').forEach(function (sel) {
      sel.addEventListener('change', function () {
        var resColor =
          sel.value === 'overwrite' ? '#b91c1c' :
          sel.value === 'skip'      ? '#a16207' :
                                      '#15803d';
        var resBg =
          sel.value === 'overwrite' ? '#fee2e2' :
          sel.value === 'skip'      ? '#fef3c7' :
                                      '#dcfce7';
        sel.style.color = resColor;
        sel.style.background = resBg;
        sel.style.borderColor = resColor;
      });
    });
  }

  // ---- Step 2B (Developer mapping) ----
  function renderStep2B() {
    var p = lastImportPreview;
    var localDevs = p._localDevs || [];
    var localById = {};
    localDevs.forEach(function (d) { localById[d.id] = d; });
    var meName = p._meDevName || 'current admin';
    var meId   = p._meDevId || 0;

    // Initialise wizardState.devMap from auto-match on first entry.
    if (Object.keys(wizardState.devMap).length === 0) {
      var autoMap = {};
      (p.auto_dev_map || []).forEach(function (m) { autoMap[m.source_id] = m.local_id; });
      (p.developers || []).forEach(function (d) {
        var tgt = autoMap[d.source_id];
        var sameServer = localById[d.source_id] &&
          (localById[d.source_id].name || '').toLowerCase() === (d.name || '').toLowerCase();
        wizardState.devMap[d.source_id] = (tgt !== undefined && tgt !== null) ? tgt :
                                          (sameServer ? d.source_id : -1);
      });
    }

    var html =
      renderStepIndicator(3) +
      '<p style="margin:0;color:var(--text-secondary,#666);font-size:0.85rem">' +
        'Map source developer-IDs to local developers. Auto-matching by name (same-server) ' +
        'and email is pre-applied; adjust where needed.</p>' +

      '<div class="form-group">' +
        '<label style="display:block;padding:4px 0">' +
          '<input type="checkbox" id="mx-import-map-to-me"' +
          (wizardState.mapToMe ? ' checked' : '') + '> ' +
          'Map all source developers to me (' +
          (meId ? '#' + meId + ' ' + esc(meName) : esc(meName)) + ')</label>' +
        '<div class="data-table-wrap"><table class="data-table">' +
          '<thead><tr>' +
            '<th>Source dev</th>' +
            '<th>Email</th>' +
            '<th style="width:240px">Target on this server</th>' +
            '<th style="width:100px">Match</th>' +
          '</tr></thead><tbody>';
    (p.developers || []).forEach(function (d) {
      var preselected = wizardState.devMap[d.source_id];
      var autoMatched = (lastImportPreview.auto_dev_map || [])
        .some(function (am) { return am.source_id === d.source_id && am.local_id > 0; });
      var sameServer = localById[d.source_id] &&
        (localById[d.source_id].name || '').toLowerCase() === (d.name || '').toLowerCase();
      var matchBadge = '';
      if (sameServer) {
        matchBadge = '<span style="color:#16a34a;font-size:0.75rem;font-weight:600">&#x2713; same-server</span>';
      } else if (autoMatched) {
        matchBadge = '<span style="color:#2563eb;font-size:0.75rem;font-weight:600">&#x2713; email</span>';
      } else {
        matchBadge = '<span style="color:#a16207;font-size:0.75rem">manual</span>';
      }

      var options = '<option value="-1"' + (preselected === -1 ? ' selected' : '') +
        '>&mdash; drop ACL entry &mdash;</option>';
      if (localDevs.length > 0) {
        localDevs.forEach(function (ld) {
          options += '<option value="' + ld.id + '"' +
            (ld.id === preselected ? ' selected' : '') + '>' +
            '#' + ld.id + ' ' + esc(ld.name) + (ld.email ? ' (' + esc(ld.email) + ')' : '') +
            '</option>';
        });
      } else {
        options += '<option value="' + preselected + '" selected>#' + preselected + ' (unresolved)</option>';
      }

      html += '<tr>' +
        '<td>#' + d.source_id + ' ' + esc(d.name) + '</td>' +
        '<td class="mono">' + esc(d.email || '') + '</td>' +
        '<td><select class="form-input" style="padding:2px 6px;width:100%" data-dmap="' +
          d.source_id + '"' + (wizardState.mapToMe ? ' disabled' : '') + '>' +
          options + '</select></td>' +
        '<td>' + matchBadge + '</td>' +
      '</tr>';
    });
    html += '</tbody></table></div></div>';

    html += '<div id="mx-import-msg2b" class="alert alert--error" style="display:none"></div>';

    html += '<div class="modal__footer" style="padding:0;border:none;margin-top:8px">' +
      '<button type="button" class="btn" id="mx-import-back2b">' +
        '<i data-lucide="chevron-left" class="icon-xs"></i> Back' +
      '</button>' +
      '<button type="button" class="btn" id="mx-import-cancel2b">Cancel</button>' +
      '<button type="button" class="btn btn--primary" id="mx-import-next2b">' +
        'Next <i data-lucide="chevron-right" class="icon-xs"></i>' +
      '</button>' +
    '</div>';

    document.getElementById('mx-import-step').innerHTML = html;
    if (window.lucide && window.lucide.createIcons) window.lucide.createIcons();

    // "Map all to me" visual-override
    var cb = document.getElementById('mx-import-map-to-me');
    cb.addEventListener('change', function () {
      document.querySelectorAll('[data-dmap]').forEach(function (sel) {
        if (cb.checked) {
          var opt = sel.querySelector('option[value="' + meId + '"]');
          if (opt) sel.value = String(meId);
          sel.disabled = true;
          sel.style.background = 'var(--bg-muted,#f6f8fa)';
        } else {
          var srcId = sel.getAttribute('data-dmap');
          sel.value = String(wizardState.devMap[srcId]);
          sel.disabled = false;
          sel.style.background = '';
        }
      });
    });

    document.getElementById('mx-import-back2b').addEventListener('click', function () {
      renderStep2();
    });
    document.getElementById('mx-import-cancel2b').addEventListener('click', closeImportModal);
    document.getElementById('mx-import-next2b').addEventListener('click', function () {
      wizardState.mapToMe = cb.checked;
      document.querySelectorAll('[data-dmap]').forEach(function (sel) {
        var srcId = parseInt(sel.getAttribute('data-dmap'), 10);
        if (!isNaN(srcId)) wizardState.devMap[srcId] = parseInt(sel.value, 10);
      });
      renderStep2C();
    });
  }

  // ---- Step 2C (Confirm + Explanation) ----
  function renderStep2C() {
    var p = lastImportPreview;
    var m = p.manifest || {};
    var projCount = (m.projects || []).length;
    var devCount  = (p.developers || []).length;
    var collisions = wizardState.conflicts.filter(function (c) { return c.local_id > 0; });

    var resolutionCounts = { skip: 0, 'rename-new-slug': 0, overwrite: 0 };
    collisions.forEach(function (c) { resolutionCounts[c.resolution] = (resolutionCounts[c.resolution] || 0) + 1; });

    var mapSummary = wizardState.mapToMe ?
      'All ' + devCount + ' source developers &rarr; YOU (#' + (p._meDevId || 0) + ' ' + esc(p._meDevName || 'admin') + ')' :
      devCount + ' developers mapped individually (see dropdowns)';

    var html =
      renderStepIndicator(4) +

      '<div style="background:var(--accent-glow,#eef2ff);border:1px solid rgba(79,70,229,0.15);' +
          'border-radius:var(--radius-md,8px);padding:var(--gap-md,12px);margin-bottom:8px">' +
        '<h4 style="margin:0 0 8px 0;color:var(--accent,#4f46e5);font-size:0.9rem">' +
          '<i data-lucide="info" class="icon-sm" style="vertical-align:middle"></i> ' +
          'About to execute import' +
        '</h4>' +
        '<ul style="margin:0 0 0 16px;padding:0;font-size:0.85rem;line-height:1.6">' +
          '<li><b>' + projCount + '</b> project(s) from bundle</li>' +
          '<li><b>' + collisions.length + '</b> slug collision(s): ' +
            resolutionCounts['rename-new-slug'] + ' rename, ' +
            resolutionCounts.skip + ' skip, ' +
            resolutionCounts.overwrite + ' overwrite</li>' +
          '<li>' + esc(mapSummary) + '</li>' +
          '<li>All operations run in a <b>single DB transaction</b> &mdash; rollback on any error.</li>' +
          '<li>Documents, revisions, tags, relations, ACL and env-vars will be inserted next.</li>' +
        '</ul>' +
      '</div>';

    if (resolutionCounts.overwrite > 0) {
      html += '<div class="alert alert--warning">' +
        '<i data-lucide="alert-triangle" class="icon-sm"></i> ' +
        resolutionCounts.overwrite + ' project(s) set to <b>Overwrite</b>. ' +
        'Existing local project data in those slugs will be replaced.' +
      '</div>';
    }

    html += '<div id="mx-import-msg2c" class="alert alert--error" style="display:none"></div>';

    html += '<div class="modal__footer" style="padding:0;border:none;margin-top:8px">' +
      '<button type="button" class="btn" id="mx-import-back2c">' +
        '<i data-lucide="chevron-left" class="icon-xs"></i> Back' +
      '</button>' +
      '<button type="button" class="btn" id="mx-import-cancel2c">Cancel</button>' +
      '<button type="button" class="btn btn--primary" id="mx-import-exec">' +
        '<i data-lucide="play" class="icon-xs"></i> Execute Import' +
      '</button>' +
    '</div>';

    document.getElementById('mx-import-step').innerHTML = html;
    if (window.lucide && window.lucide.createIcons) window.lucide.createIcons();

    document.getElementById('mx-import-back2c').addEventListener('click', function () { renderStep2B(); });
    document.getElementById('mx-import-cancel2c').addEventListener('click', closeImportModal);
    document.getElementById('mx-import-exec').addEventListener('click', executeImport);
  }

  async function executeImport() {
    console.log('[project-bundle] Execute Import clicked');

    // Move to Step 5 (progress/result) immediately. Shows a running log that
    // will be populated with status + final summary.
    renderStep3Progress();

    // Build request payload from wizardState (already collected in Step 2 + 2B).
    var resolutions = wizardState.conflicts.map(function (c) {
      return { source_slug: c.source_slug, resolution: c.resolution, new_slug: c.new_slug };
    });
    var mapping = [];
    Object.keys(wizardState.devMap).forEach(function (srcId) {
      var localId = wizardState.mapToMe ? 0 : wizardState.devMap[srcId];
      if (isNaN(localId)) localId = 0;
      mapping.push({ source_id: parseInt(srcId, 10), local_id: localId });
    });

    var body = {
      bundle_b64: lastImportBundleB64,
      secret: lastImportSecret,
      preview: false,
      conflict_resolutions: resolutions,
      dev_mapping: mapping
    };

    appendProgressLog('POST /api/import (payload ' +
      (JSON.stringify(body).length / 1024).toFixed(1) + ' KB)...');

    try {
      var t0 = Date.now();
      var res = await fetch('api/import', {
        method: 'POST',
        credentials: 'same-origin',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': (typeof Api !== 'undefined' && Api.getCsrfToken ? Api.getCsrfToken() : '')
        },
        body: JSON.stringify(body)
      });
      var dt = ((Date.now() - t0) / 1000).toFixed(1);
      console.log('[project-bundle] Execute response status:', res.status, 'in', dt, 's');
      appendProgressLog('Server response: HTTP ' + res.status + ' (took ' + dt + 's)');

      if (!res.ok) {
        var err = await res.json().catch(function(){return{};});
        console.error('[project-bundle] Import failed:', res.status, err);
        appendProgressLog('ERROR: ' + (err.error || 'HTTP ' + res.status), true);
        renderStep3Fail();
        return;
      }
      var data = await res.json();
      renderStep3Success(data.summary);
    } catch (e) {
      console.error('[project-bundle] Execute exception:', e);
      appendProgressLog('EXCEPTION: ' + (e && e.message ? e.message : String(e)), true);
      renderStep3Fail();
    }
  }

  // ---- Step 5 progress (shown while the import is running) ----
  function renderStep3Progress() {
    var html =
      renderStepIndicator(5) +
      '<div id="mx-import-progress-header" style="display:flex;align-items:center;gap:10px;margin-bottom:8px">' +
        '<span class="spinner"></span>' +
        '<b>Import in progress...</b>' +
      '</div>' +
      '<pre id="mx-import-log" style="background:var(--bg-muted,#f6f8fa);border:1px solid var(--border,#e5e7eb);' +
        'border-radius:var(--radius-md,8px);padding:10px;font-size:0.8rem;' +
        'max-height:240px;overflow-y:auto;margin:0;white-space:pre-wrap">' +
        '[' + new Date().toTimeString().slice(0,8) + '] Starting import...\n' +
      '</pre>';
    document.getElementById('mx-import-step').innerHTML = html;
    if (window.lucide && window.lucide.createIcons) window.lucide.createIcons();
  }

  function removeProgressSpinner() {
    var h = document.getElementById('mx-import-progress-header');
    if (h) h.remove();
  }

  function appendProgressLog(msg, isError) {
    var pre = document.getElementById('mx-import-log');
    if (!pre) return;
    var stamp = '[' + new Date().toTimeString().slice(0,8) + '] ';
    var line = stamp + (isError ? '❌ ' : '') + msg + '\n';
    pre.textContent += line;
    pre.scrollTop = pre.scrollHeight;
  }

  function renderStep3Fail() {
    removeProgressSpinner();
    var bannerHtml =
      '<div class="alert alert--error" style="margin-bottom:8px">' +
        '<i data-lucide="x-circle" class="icon-sm"></i> ' +
        '<b>Import failed</b> &mdash; see log above. Transaction was rolled back.' +
      '</div>' +
      '<div class="modal__footer" style="padding:0;border:none;margin-top:8px">' +
        '<button type="button" class="btn" id="mx-import-back-from-fail">' +
          '<i data-lucide="chevron-left" class="icon-xs"></i> Back to confirm' +
        '</button>' +
        '<button type="button" class="btn btn--primary" id="mx-import-close-fail">Close</button>' +
      '</div>';
    document.getElementById('mx-import-step').insertAdjacentHTML('beforeend', bannerHtml);
    if (window.lucide && window.lucide.createIcons) window.lucide.createIcons();

    document.getElementById('mx-import-back-from-fail').addEventListener('click', renderStep2C);
    document.getElementById('mx-import-close-fail').addEventListener('click', closeImportModal);
  }

  function renderStep3Success(s) {
    removeProgressSpinner();
    var html =
      '<div class="alert" style="background:#dcfce7;border:1px solid #16a34a;color:#166534;margin-top:8px">' +
        '<i data-lucide="check-circle" class="icon-sm"></i> ' +
        '<b>Import complete</b>' +
      '</div>' +

      '<div style="background:var(--bg-muted,#f6f8fa);border:1px solid var(--border,#e5e7eb);' +
          'border-radius:var(--radius-md,8px);padding:var(--gap-sm,10px) var(--gap-md,14px);' +
          'font-size:0.85rem;line-height:1.6">' +
        '<b>Projects</b><br>' +
        '&nbsp;&nbsp;&bull; ' + s.projects_created + ' new (no collision)<br>' +
        '&nbsp;&nbsp;&bull; ' + s.projects_renamed + ' imported as new slug (collision &rarr; rename)<br>' +
        '&nbsp;&nbsp;&bull; ' + s.projects_updated + ' overwritten (collision &rarr; overwrite)<br>' +
        '&nbsp;&nbsp;&bull; ' + s.projects_skipped + ' skipped (collision &rarr; skip)<br>' +
        '<b>Documents</b> &mdash; ' + s.docs_inserted + ' inserted, ' + s.docs_updated + ' updated<br>' +
        '<b>Revisions</b> &mdash; ' + s.revisions_inserted + ' inserted<br>' +
        '<b>Tags</b> &mdash; ' + s.tags_inserted + ' inserted<br>' +
        '<b>Relations</b> &mdash; ' + s.relations_inserted + ' inserted<br>' +
        '<b>ACL entries</b> &mdash; ' + s.acl_inserted + ' inserted, ' + s.acl_skipped + ' skipped<br>' +
        '<b>Env-vars</b> &mdash; ' + s.env_vars_inserted + ' inserted' +
      '</div>';

    if (s.warnings && s.warnings.length) {
      html += '<div class="alert alert--warning" style="margin-top:8px">' +
        '<i data-lucide="alert-triangle" class="icon-sm"></i> <b>Warnings:</b>' +
        '<ul style="margin:4px 0 0 16px">' +
          s.warnings.map(function (w) { return '<li>' + esc(w) + '</li>'; }).join('') +
        '</ul></div>';
    }

    html += '<div class="modal__footer" style="padding:0;border:none;margin-top:8px">' +
      '<button type="button" class="btn" id="mx-import-close-only">Close</button>' +
      '<button type="button" class="btn btn--primary" id="mx-import-done">' +
        '<i data-lucide="refresh-cw" class="icon-xs"></i> Close &amp; reload projects' +
      '</button>' +
    '</div>';

    // Keep the progress log visible above the result.
    document.getElementById('mx-import-step').insertAdjacentHTML('beforeend', html);
    if (window.lucide && window.lucide.createIcons) window.lucide.createIcons();

    document.getElementById('mx-import-close-only').addEventListener('click', closeImportModal);
    document.getElementById('mx-import-done').addEventListener('click', function () {
      closeImportModal();
      if (window.location.hash === '#projects' || window.location.hash === '') {
        window.location.reload();
      }
    });
  }

  // --- Public API ---------------------------------------------------------

  window.MxProjectBundle = {
    inject: injectSelectionUI,
    openExport: openExportModal,
    openImport: openImportModal
  };

  // Auto-inject on hash-change and initial load — projects page has
  // hash='#projects' in the admin-UI router.
  function maybeInject() {
    if (window.location.hash === '#projects' || window.location.hash === '') {
      // Delay to allow the project-table to render first.
      setTimeout(injectSelectionUI, 250);
      setTimeout(injectSelectionUI, 800); // re-run after slower loads
    }
  }
  window.addEventListener('hashchange', maybeInject);
  window.addEventListener('load', maybeInject);
})();
