/* ============================================================
   connect.js — mxLore Invite Landing Page (standalone, no deps)
   Fetches /api/invite/{token}, renders client tabs, handles confirm
   ============================================================ */

(function () {
  'use strict';

  // --- State refs ---
  var stateEls = {
    loading:   document.getElementById('state-loading'),
    error:     document.getElementById('state-error'),
    success:   document.getElementById('state-success'),
    confirmed: document.getElementById('state-confirmed')
  };

  // --- Error code → user-facing title/message ---
  var ERROR_MESSAGES = {
    invite_not_found: {
      title: 'Invalid invite link',
      msg:   'The link may have been mistyped or was already removed from the server. Contact your mxLore admin for a new one.'
    },
    invite_expired: {
      title: 'Link expired',
      msg:   'This invite link has expired. Contact your mxLore admin for a new one.'
    },
    invite_revoked: {
      title: 'Link revoked',
      msg:   'This invite link has been revoked by the admin. Contact them if you still need access.'
    },
    rate_limited: {
      title: 'Too many requests',
      msg:   'Please wait a few minutes before trying again.'
    },
    ip_blocked: {
      title: 'Access blocked',
      msg:   'Your IP has been temporarily blocked due to too many failed attempts. Try again later.'
    }
  };

  // --- Extract token from URL query string ---
  var token = '';
  try {
    token = new URLSearchParams(window.location.search).get('token') || '';
  } catch (e) {
    // Older browser — fall back to manual parse
    var match = window.location.search.match(/[?&]token=([^&]+)/);
    token = match ? decodeURIComponent(match[1]) : '';
  }

  // --- Show a single state, hide others ---
  function showState(name) {
    Object.keys(stateEls).forEach(function (key) {
      var el = stateEls[key];
      if (!el) return;
      el.classList.toggle('hidden', key !== name);
    });
  }

  // --- Render error state ---
  function showError(title, msg) {
    document.getElementById('error-title').textContent = title;
    document.getElementById('error-message').textContent = msg;
    showState('error');
  }

  // --- Client-side token format check (server also validates) ---
  function tokenLooksValid(t) {
    return typeof t === 'string' && t.length === 68 && /^inv_[0-9a-f]{64}$/.test(t);
  }

  // --- Fetch + render invite ---
  function loadInvite() {
    if (!tokenLooksValid(token)) {
      showError('Invalid link', 'The invite link is missing or malformed. Make sure you copied the full URL.');
      return;
    }

    fetch('api/invite/' + encodeURIComponent(token), {
      method: 'GET',
      credentials: 'same-origin',
      headers: { 'Accept': 'application/json' }
    })
      .then(function (r) {
        return r.json()
          .catch(function () { return { status: 'error', code: 'unknown_error' }; })
          .then(function (body) { return { ok: r.ok, status: r.status, body: body }; });
      })
      .then(function (wrapper) {
        var data = wrapper.body || {};
        // Error detection — three flavors:
        //   1. HTTP status >= 400 (server threw)
        //   2. Body has status='error' + code (our handler's shape)
        //   3. Body has error field (generic error shape from outer handler)
        if (!wrapper.ok || data.status === 'error' || data.error) {
          var code = data.code || data.error || 'unknown_error';
          var meta = ERROR_MESSAGES[code] || {
            title: 'Unable to load invite',
            msg: 'Server returned HTTP ' + wrapper.status + ' (code: ' + code + ')'
          };
          showError(meta.title, meta.msg);
          return;
        }
        if (data.status !== 'valid') {
          showError('Unexpected response', 'Server response was missing the valid status flag.');
          return;
        }
        populateInvite(data);
        showState('success');
      })
      .catch(function (err) {
        showError(
          'Connection error',
          'Could not reach the mxLore server. Check your network and try again in a moment. (' + (err && err.message ? err.message : err) + ')'
        );
      });
  }

  // --- Populate tab content with invite data ---
  function populateInvite(data) {
    var devName = data.developer_name || 'team member';
    var mcpUrl  = data.mcp_url || '';
    var apiKey  = data.api_key || '';

    document.getElementById('dev-name').textContent = devName;

    // Post-confirm state: api_key was already cleared
    if (!apiKey) {
      var notice = document.getElementById('post-confirm-notice');
      if (notice) notice.classList.remove('hidden');
      // Hide the confirm box since there's nothing left to confirm
      var cb = document.getElementById('confirm-box');
      if (cb) cb.style.display = 'none';
    }

    // --- Claude Code tab ---
    var mxsetupCmd = '/mxSetup ' + (apiKey || '<api-key>');
    setText('mxsetup-cmd', mxsetupCmd);

    // --- Claude Desktop tab ---
    var urlWithKey = buildUrlWithKey(mcpUrl, apiKey);
    setText('desktop-url', urlWithKey);

    // --- claude.ai Web tab ---
    setText('web-url', urlWithKey);

    // --- Cursor / Windsurf / Cline tab ---
    var cursorConfig = {
      mcpServers: {
        'mxai-knowledge': {
          type: 'http',
          url: mcpUrl || 'https://your-server/mcp',
          headers: {
            Authorization: 'Bearer ' + (apiKey || '<api-key>')
          }
        }
      }
    };
    setText('cursor-json', JSON.stringify(cursorConfig, null, 2));

    // --- Other / Raw values ---
    setText('other-url', mcpUrl || '(not configured — ask admin)');
    setText('other-key', apiKey || '(already confirmed — ask admin for a new invite)');
  }

  // --- Build URL with ?api_key= query param, URL-encoded ---
  function buildUrlWithKey(url, key) {
    if (!url) return '(server URL not configured — contact admin)';
    if (!key) return url + '  (key already confirmed)';
    var sep = url.indexOf('?') >= 0 ? '&' : '?';
    return url + sep + 'api_key=' + encodeURIComponent(key);
  }

  // --- Safe textContent setter ---
  function setText(id, text) {
    var el = document.getElementById(id);
    if (el) el.textContent = text;
  }

  // --- Tab switching ---
  function initTabs() {
    var tabs = document.querySelectorAll('.tab');
    tabs.forEach(function (btn) {
      btn.addEventListener('click', function () {
        var tabId = btn.getAttribute('data-tab');
        tabs.forEach(function (b) { b.classList.remove('active'); });
        document.querySelectorAll('.tab-content').forEach(function (c) {
          c.classList.remove('active');
        });
        btn.classList.add('active');
        var target = document.getElementById('tab-' + tabId);
        if (target) target.classList.add('active');
      });
    });
  }

  // --- Copy buttons (delegated click handler) ---
  function initCopyButtons() {
    document.addEventListener('click', function (e) {
      var btn = e.target;
      if (!btn || !btn.classList || !btn.classList.contains('copy-btn')) return;
      var targetId = btn.getAttribute('data-target');
      if (!targetId) return;
      var target = document.getElementById(targetId);
      if (!target) return;
      var text = target.textContent || '';

      copyToClipboard(text, function (ok) {
        if (ok) flashCopied(btn);
      });
    });
  }

  function copyToClipboard(text, callback) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(
        function () { callback(true); },
        function () { fallbackCopy(text, callback); }
      );
    } else {
      fallbackCopy(text, callback);
    }
  }

  function fallbackCopy(text, callback) {
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.style.position = 'fixed';
    ta.style.top = '-9999px';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.focus();
    ta.select();
    var ok = false;
    try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
    document.body.removeChild(ta);
    callback(ok);
  }

  function flashCopied(btn) {
    var originalText = btn.textContent;
    btn.classList.add('copied');
    btn.textContent = 'Copied!';
    setTimeout(function () {
      btn.classList.remove('copied');
      btn.textContent = originalText;
    }, 1400);
  }

  // --- Confirm handler ---
  function initConfirm() {
    var btn = document.getElementById('confirm-btn');
    if (!btn) return;
    btn.addEventListener('click', function () {
      btn.disabled = true;
      var originalText = btn.textContent;
      btn.textContent = 'Confirming…';

      fetch('api/invite/' + encodeURIComponent(token) + '/confirm', {
        method: 'POST',
        credentials: 'same-origin',
        headers: { 'Accept': 'application/json' }
      })
        .then(function (r) { return r.json().catch(function () { return {}; }); })
        .then(function (data) {
          if (data && data.ok) {
            showState('confirmed');
            return;
          }
          btn.disabled = false;
          btn.textContent = originalText;
          alert('Could not confirm: ' + ((data && data.error) || 'unknown error'));
        })
        .catch(function (err) {
          btn.disabled = false;
          btn.textContent = originalText;
          alert('Network error. Try again. (' + (err && err.message ? err.message : err) + ')');
        });
    });
  }

  // --- Boot ---
  function init() {
    initTabs();
    initCopyButtons();
    initConfirm();
    loadInvite();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
