/* ============================================================
   intelligence.js — FR#3294 / SPEC#3583
   Banner above the Intelligence page when Semantic Search is
   inactive (or embeddings-empty). Reason-specific text + CTA.
   Endpoint: GET /admin/api/intelligence/status
   ============================================================ */
(function () {
  'use strict';

  var BANNER_ID      = 'intel-banner';
  var DISMISS_KEY    = 'mx-intel-banner-dismissed-at';
  var DISMISS_TTL_MS = 6 * 60 * 60 * 1000;  // 6h, matches deep-threads.js

  // Reason -> {level, title, body, cta?} map. Kept in one place so the
  // admin-UI and future localisation can treat this as the SSoT.
  var REASONS = {
    no_mariadb_vector: {
      level: 'alert--error',
      title: 'Semantic Search unavailable — MariaDB VECTOR column missing.',
      body:  'Your MariaDB installation does not expose the <code>documents.embedding</code> ' +
             'VECTOR column. Upgrade MariaDB to 11.6+ and restart the server so ' +
             'sql/043 auto-migrate can add the column.',
      cta:   null
    },
    no_api_key: {
      level: 'alert--warning',
      title: 'Semantic Search inactive — embedding provider not configured.',
      body:  'Set <code>[AI] EmbeddingEnabled=true</code>, <code>EmbeddingUrl</code>, ' +
             '<code>EmbeddingApiKey</code>, and <code>EmbeddingModel</code> in ' +
             'mxLoreMCP.ini, then restart the server.',
      cta:   { label: 'Open Settings', page: 'settings' }
    },
    provider_error: {
      level: 'alert--error',
      title: 'Semantic Search failing — provider error.',
      body:  'The embedding provider is configured but recent batches failed. ' +
             'Check the server log for HTTP errors from the embedding endpoint.',
      cta:   null
    },
    no_embeddings: {
      level: 'alert--info',
      title: 'Semantic Search configured but no documents embedded yet.',
      body:  'The embedding provider is reachable, but <strong>0</strong> documents carry ' +
             'an embedding vector. The AI batch will backfill on its next run; ' +
             'hybrid search falls back to keyword-only until then.',
      cta:   null
    }
  };

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

  function hide() {
    var el = document.getElementById(BANNER_ID);
    if (!el) return;
    el.style.display = 'none';
    el.className = 'alert';
    el.innerHTML = '';
  }

  function render(status) {
    var el = document.getElementById(BANNER_ID);
    if (!el) return;
    if (status && status.semantic_active === true) { hide(); return; }
    if (isDismissed()) { hide(); return; }

    var reason = (status && status.reason) || 'no_api_key';
    var info = REASONS[reason];
    if (!info) { hide(); return; }

    var total    = (status && status.total_docs    != null) ? status.total_docs    : 0;
    var embedded = (status && status.embedded_docs != null) ? status.embedded_docs : 0;
    var provider = (status && status.provider_url) ? status.provider_url : '';
    var model    = (status && status.model)        ? status.model        : '';
    var statsHtml = '<div class="intel-banner__stats">' +
      '<strong>' + escapeHtml(embedded) + '</strong> of ' +
      '<strong>' + escapeHtml(total) + '</strong> documents embedded' +
      (provider ? ' · provider <code>' + escapeHtml(provider) + '</code>' : '') +
      (model    ? ' · model <code>'    + escapeHtml(model)    + '</code>' : '') +
      '</div>';

    var ctaHtml = '';
    if (info.cta) {
      ctaHtml =
        '<button type="button" class="intel-banner__cta" data-target="' +
          escapeHtml(info.cta.page) + '">' +
          escapeHtml(info.cta.label) +
        '</button>';
    }

    el.className = 'alert ' + info.level + ' intel-banner visible';
    el.style.display = 'block';
    el.innerHTML =
      '<div class="intel-banner__head">' +
        '<span class="intel-banner__title"><strong>' + escapeHtml(info.title) + '</strong></span>' +
        ctaHtml +
        '<button type="button" class="intel-banner__dismiss" aria-label="Dismiss">&times;</button>' +
      '</div>' +
      '<div class="intel-banner__body">' + info.body + '</div>' +
      statsHtml;

    var dismiss = el.querySelector('.intel-banner__dismiss');
    if (dismiss) {
      dismiss.addEventListener('click', function () {
        markDismissed();
        hide();
      });
    }
    var cta = el.querySelector('.intel-banner__cta');
    if (cta) {
      cta.addEventListener('click', function () {
        var page = cta.getAttribute('data-target');
        if (page && window.App && typeof App.navigateTo === 'function') {
          App.navigateTo(page);
        }
      });
    }
  }

  function fetchAndRender() {
    if (typeof Api === 'undefined' || typeof Api.getIntelligenceStatus !== 'function') return;
    Api.getIntelligenceStatus()
      .then(render)
      .catch(function () { /* silent — admin can refresh */ });
  }

  window.mxIntelligence = {
    refresh: fetchAndRender,
    hide:    hide
  };

  function tryInit(retries) {
    if (typeof Api !== 'undefined' && typeof Api.getIntelligenceStatus === 'function') {
      fetchAndRender();
    } else if (retries > 0) {
      setTimeout(function () { tryInit(retries - 1); }, 200);
    }
  }
  document.addEventListener('DOMContentLoaded', function () {
    tryInit(20);
  });
})();
