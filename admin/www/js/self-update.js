/* ============================================================
   self-update.js — Admin-UI banner for FR#2242 Self-Update v1
   Self-contained: works on index.html (authenticated SPA) and
   connect.html (public landing). Exports window.mxSelfUpdate.
   ============================================================ */
(function () {
  'use strict';

  var BANNER_ID = 'mx-selfupdate-banner';
  var POLL_INTERVAL_MS = 2000;
  var POLL_TIMEOUT_MS = 3000;
  var SUCCESS_AUTOHIDE_MS = 10000;

  function csrfToken() {
    // Api is declared via `const` in api.js — that does NOT attach to window,
    // but the binding is still accessible as a bare identifier.
    try {
      if (typeof Api !== 'undefined' &&
          Api && typeof Api.getCsrfToken === 'function') {
        return Api.getCsrfToken() || '';
      }
    } catch (e) { /* Api not defined on this page (e.g. connect.html) */ }
    if (window.mxCsrfToken) return window.mxCsrfToken;
    var meta = document.querySelector('meta[name="csrf-token"]');
    return meta ? meta.getAttribute('content') : '';
  }

  function ensureBanner() {
    var b = document.getElementById(BANNER_ID);
    if (b) return b;
    b = document.createElement('div');
    b.id = BANNER_ID;
    document.body.prepend(b);
    return b;
  }

  function setBannerState(b, stateClass, innerHtml) {
    b.className = 'visible state-' + stateClass;
    b.innerHTML = innerHtml;
    document.body.classList.add('mx-su-banner-visible');
  }

  function hideBanner(b) {
    if (!b) b = document.getElementById(BANNER_ID);
    if (!b) return;
    b.className = '';
    b.innerHTML = '';
    document.body.classList.remove('mx-su-banner-visible');
  }

  function escapeHtml(s) {
    if (s == null) return '';
    return String(s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;',
               '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  function renderAvailable(b, info) {
    setBannerState(b, 'available',
      '<span class="mx-su-text">Build ' + escapeHtml(info.build_latest) +
      ' available (currently running ' + escapeHtml(info.build_current) + ').</span>' +
      '<button class="mx-su-btn" id="mx-su-install-btn">Install</button>' +
      '<button class="mx-su-btn" id="mx-su-dismiss-btn">Dismiss</button>');
    var install = document.getElementById('mx-su-install-btn');
    if (install) install.addEventListener('click', onInstallClick);
    var dismiss = document.getElementById('mx-su-dismiss-btn');
    if (dismiss) dismiss.addEventListener('click', function () { hideBanner(b); });
  }

  function renderUpdating(b, msg) {
    setBannerState(b, 'updating',
      '<span class="mx-su-spinner"></span>' +
      '<span class="mx-su-text">' + escapeHtml(msg || 'Updating...') + '</span>');
  }

  function renderSuccess(b, info) {
    setBannerState(b, 'success',
      '<span class="mx-su-text">Updated to build ' +
      escapeHtml(info && info.build_current) + '.</span>' +
      '<button class="mx-su-btn" id="mx-su-dismiss-btn">Dismiss</button>');
    var dismiss = document.getElementById('mx-su-dismiss-btn');
    if (dismiss) dismiss.addEventListener('click', function () { hideBanner(b); });
    setTimeout(function () { hideBanner(b); }, SUCCESS_AUTOHIDE_MS);
  }

  function renderError(b, msg) {
    setBannerState(b, 'error',
      '<span class="mx-su-text">Update failed: ' +
      escapeHtml(msg || 'unknown error') + '</span>' +
      '<button class="mx-su-btn" id="mx-su-retry-btn">Retry</button>' +
      '<button class="mx-su-btn" id="mx-su-dismiss-btn">Dismiss</button>');
    var retry = document.getElementById('mx-su-retry-btn');
    if (retry) retry.addEventListener('click', function () { checkStatus(true); });
    var dismiss = document.getElementById('mx-su-dismiss-btn');
    if (dismiss) dismiss.addEventListener('click', function () { hideBanner(b); });
  }

  function renderCooldown(b, msg) {
    setBannerState(b, 'updating',
      '<span class="mx-su-text">' +
      escapeHtml(msg || 'Rate-limited, try again in 60s') + '</span>' +
      '<button class="mx-su-btn" id="mx-su-dismiss-btn">Dismiss</button>');
    var dismiss = document.getElementById('mx-su-dismiss-btn');
    if (dismiss) dismiss.addEventListener('click', function () { hideBanner(b); });
  }

  function fetchJson(path, method) {
    var ctrl = new AbortController();
    var timer = setTimeout(function () { ctrl.abort(); }, POLL_TIMEOUT_MS);
    var opts = {
      method: method || 'GET',
      credentials: 'same-origin',
      headers: {},
      signal: ctrl.signal
    };
    if (opts.method !== 'GET') {
      opts.headers['X-CSRF-Token'] = csrfToken();
      opts.headers['Content-Type'] = 'application/json';
    }
    return fetch('api/self-update/' + path, opts)
      .then(function (r) {
        clearTimeout(timer);
        if (r.status === 401) return { _unauth: true };
        return r.json().then(function (data) {
          data._httpStatus = r.status;
          return data;
        });
      })
      .catch(function (e) { clearTimeout(timer); throw e; });
  }

  function handleStatusResponse(data) {
    var b = ensureBanner();
    if (!data || data._unauth) {
      hideBanner(b);
      return;
    }
    if (data.state === 'disabled' || data.state === 'idle') {
      hideBanner(b);
      return;
    }
    if (data.state === 'cooldown') { renderCooldown(b, data.message); return; }
    if (data.state === 'update_available') { renderAvailable(b, data); return; }
    if (data.state === 'downloading' || data.state === 'swapping') {
      renderUpdating(b, 'Update in progress...');
      pollUntilDone();
      return;
    }
    if (data.state === 'post_update_ok') { renderSuccess(b, data); return; }
    if (data.state === 'error') { renderError(b, data.error_message); return; }
    hideBanner(b);
  }

  function checkStatus(force) {
    var path = force ? 'recheck' : 'status';
    var method = force ? 'POST' : 'GET';
    return fetchJson(path, method)
      .then(handleStatusResponse)
      .catch(function () { /* network failure: stay silent on initial load */ });
  }

  var polling = false;
  function pollUntilDone() {
    if (polling) return;
    polling = true;
    var serverWasDown = false;

    function tick() {
      fetchJson('status', 'GET')
        .then(function (data) {
          if (data && data._unauth) {
            polling = false;
            hideBanner();
            return;
          }
          if (serverWasDown) {
            renderSuccess(ensureBanner(), data || {});
            polling = false;
            return;
          }
          if (data && data.state === 'post_update_ok') {
            renderSuccess(ensureBanner(), data);
            polling = false;
            return;
          }
          if (data && data.state === 'error') {
            renderError(ensureBanner(), data.error_message);
            polling = false;
            return;
          }
          setTimeout(tick, POLL_INTERVAL_MS);
        })
        .catch(function () {
          serverWasDown = true;
          setTimeout(tick, POLL_INTERVAL_MS);
        });
    }
    tick();
  }

  function onInstallClick() {
    var installBtn = document.getElementById('mx-su-install-btn');
    if (installBtn) installBtn.disabled = true;
    var b = ensureBanner();
    renderUpdating(b, 'Downloading build...');

    fetchJson('install', 'POST')
      .then(function (data) {
        if (data && data._unauth) {
          renderError(b, 'session expired, please sign in');
          return;
        }
        if (data && (data.ok || data.state === 'swapping')) {
          renderUpdating(b, 'Installing, server will restart...');
          pollUntilDone();
        } else {
          renderError(b, (data && data.message) || 'install refused');
        }
      })
      .catch(function (e) {
        renderError(b, 'request failed: ' + (e && e.message || 'unknown'));
      });
  }

  // Public API for settings page and any other caller.
  window.mxSelfUpdate = {
    checkNow: function () { return checkStatus(false); },
    recheck:  function () { return checkStatus(true); },
    install:  onInstallClick,
    hide:     function () { hideBanner(); }
  };

  // Auto-run on both entry points.
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () { checkStatus(false); });
  } else {
    checkStatus(false);
  }
})();
