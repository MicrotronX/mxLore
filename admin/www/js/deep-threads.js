/* ============================================================
   deep-threads.js — Admin-UI alert for FR#2936/Plan#3266 M2.6
   Surfaces review-notes whose depth (sql/047) is at/above
   warn-threshold 5. Renders compact alert below the navbar
   when threads exist, dismissable per session.
   Endpoint: GET /admin/api/notes/deep-threads
   ============================================================ */
(function () {
  'use strict';

  var ALERT_ID  = 'mx-deep-threads-alert';
  var DISMISS_KEY = 'mx-deep-threads-dismissed-at';
  // Re-show alert this many ms after dismissal (so it nags without spamming)
  var DISMISS_TTL_MS = 6 * 60 * 60 * 1000;  // 6 hours

  function escapeHtml(s) {
    if (s == null) return '';
    return String(s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;',
               '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  function isDismissed() {
    try {
      var ts = sessionStorage.getItem(DISMISS_KEY);
      if (!ts) return false;
      return (Date.now() - parseInt(ts, 10)) < DISMISS_TTL_MS;
    } catch (e) { return false; }
  }

  function markDismissed() {
    try { sessionStorage.setItem(DISMISS_KEY, String(Date.now())); }
    catch (e) { /* private mode */ }
  }

  function ensureAlert() {
    var a = document.getElementById(ALERT_ID);
    if (a) return a;
    a = document.createElement('div');
    a.id = ALERT_ID;
    // Insert directly after the navbar so it sits below the chrome but above
    // every page-content. Falls back to body.prepend if navbar absent.
    var nav = document.querySelector('.navbar');
    if (nav && nav.parentNode) {
      nav.parentNode.insertBefore(a, nav.nextSibling);
    } else {
      document.body.prepend(a);
    }
    return a;
  }

  function hideAlert() {
    var a = document.getElementById(ALERT_ID);
    if (!a) return;
    a.className = '';
    a.innerHTML = '';
  }

  function buildList(threads) {
    // Cap visible rows; rest collapsed under a count.
    var MAX_VISIBLE = 5;
    var visible = threads.slice(0, MAX_VISIBLE);
    var rest = threads.length - visible.length;
    var rows = visible.map(function (t) {
      var projAttr = (t.project_id != null) ? ' data-project-id="' +
        escapeHtml(t.project_id) + '"' : '';
      // Thread-note link (the actual review-note doc)
      var threadLink =
        '<a href="#" data-doc-id="' + escapeHtml(t.id) + '"' + projAttr + '>' +
        escapeHtml(t.title) + '</a>';
      // Root-parent link (the spec/plan being reviewed) — click = open that doc
      var rootLabel;
      if (t.root_title && t.root_parent_doc_id) {
        rootLabel =
          '<a href="#" data-doc-id="' + escapeHtml(t.root_parent_doc_id) + '"' + projAttr + '>' +
          '#' + escapeHtml(t.root_parent_doc_id) + ' ' +
          escapeHtml(t.root_title) + '</a>';
      } else {
        rootLabel = '<span class="mx-dt-orphan">(orphan root)</span>';
      }
      return '<li>' +
        '<span class="mx-dt-depth">depth ' + escapeHtml(t.depth) + '</span> ' +
        threadLink + ' ' +
        '<span class="mx-dt-root">on ' + rootLabel +
        ' <em>(' + escapeHtml(t.project) + ')</em></span>' +
        '</li>';
    }).join('');
    var more = rest > 0
      ? '<li class="mx-dt-more">...and ' + rest + ' more</li>'
      : '';
    return '<ul class="mx-dt-list">' + rows + more + '</ul>';
  }

  function render(data) {
    var threads = (data && data.threads) || [];
    if (!threads.length || isDismissed()) {
      hideAlert();
      return;
    }
    var a = ensureAlert();
    var threshold = (data && data.threshold != null) ? data.threshold : 5;
    var bodyId = 'mx-dt-body-panel';
    a.className = 'visible';
    a.innerHTML =
      '<div class="mx-dt-head">' +
        '<span class="mx-dt-icon">⚠</span>' +
        '<span class="mx-dt-text">' +
          '<strong>' + threads.length + '</strong> review-thread(s) at or beyond depth ' +
          escapeHtml(threshold) +
          ' &mdash; consider promoting to spec/plan/decision.' +
        '</span>' +
        '<button class="mx-dt-toggle" type="button" ' +
          'aria-expanded="false" aria-controls="' + bodyId + '">Show</button>' +
        '<button class="mx-dt-dismiss" type="button" aria-label="Dismiss">&times;</button>' +
      '</div>' +
      '<div class="mx-dt-body" id="' + bodyId + '" hidden>' + buildList(threads) + '</div>';

    var toggle = a.querySelector('.mx-dt-toggle');
    var body   = a.querySelector('.mx-dt-body');
    toggle.addEventListener('click', function () {
      var expanded = toggle.getAttribute('aria-expanded') === 'true';
      toggle.setAttribute('aria-expanded', String(!expanded));
      toggle.textContent = expanded ? 'Show' : 'Hide';
      body.hidden = expanded;
    });

    var dismiss = a.querySelector('.mx-dt-dismiss');
    dismiss.addEventListener('click', function () {
      markDismissed();
      hideAlert();
    });

    // Click delegation: open doc detail directly (FR#3353 Phase C).
    // Fallbacks: project dashboard → projects-list.
    body.addEventListener('click', function (ev) {
      var link = ev.target.closest('a[data-doc-id]');
      if (!link) return;
      ev.preventDefault();
      var docId  = parseInt(link.getAttribute('data-doc-id'), 10);
      var projId = link.getAttribute('data-project-id');
      if (docId && window.App && typeof App.openDoc === 'function') {
        App.openDoc(docId);
      } else if (projId && window.App && typeof App.openProject === 'function') {
        App.openProject(parseInt(projId, 10));
      } else if (window.App && typeof App.navigateTo === 'function') {
        App.navigateTo('projects');
      }
    });
  }

  function fetchAndRender() {
    if (isDismissed()) return;
    if (typeof Api === 'undefined' || typeof Api.getDeepThreads !== 'function') return;
    Api.getDeepThreads()
      .then(function (resp) {
        if (resp && Array.isArray(resp.threads)) render(resp);
      })
      .catch(function () { /* silent — admin can refresh */ });
  }

  // Public API for explicit refresh (e.g. after promote action)
  window.mxDeepThreads = {
    refresh: fetchAndRender,
    hide:    hideAlert
  };

  // Auto-fetch once after page-init. Wait until Api is wired up.
  function tryInit(retries) {
    if (typeof Api !== 'undefined' && typeof Api.getDeepThreads === 'function') {
      fetchAndRender();
    } else if (retries > 0) {
      setTimeout(function () { tryInit(retries - 1); }, 200);
    }
  }
  document.addEventListener('DOMContentLoaded', function () {
    tryInit(20);
  });
})();
