/* ============================================================
   acl-helper.js  —  Admin-UI ACL gate (Plan#4007 M3 / T08)
   Centralizes per-project access-level checks mirrored from the
   backend /auth/login + /auth/check responses:
     developer.is_admin       : boolean
     developer.access_levels  : { "<project_id>": "<level>" }
   Levels: 'read' | 'comment' | 'read-write' (+ legacy 'write')
   Admin hard-bypass (OQ8): is_admin=true returns true for all
   canView/canComment/canEdit regardless of access_levels map.
   Global access-keys: canAdmin() requires is_admin (OQ1).
   Defensive by default: all can*() return false when state unset.
   ============================================================ */
var AclHelper = (function () {
  // --- internal state (module-closure, not window-leaked) ---
  var _isAdmin = false;
  var _levels  = Object.create(null);  // map<string, string>

  // Canonical level strings (keep 'write' for legacy rows until sql migration
  // drops it — ADR#3264 4-level whitelist). 'none' / null / undefined = deny.
  var EDIT_LEVELS    = { 'read-write': 1, 'write': 1 };
  var COMMENT_LEVELS = { 'comment': 1, 'read-write': 1, 'write': 1 };
  // View = any non-null level (read/comment/read-write/write)

  function _projKey(projectId) {
    // access_levels map uses string keys (JSON-object from server)
    if (projectId === null || projectId === undefined) return null;
    return String(projectId);
  }

  function setAccessLevels(map, isAdminFlag) {
    _isAdmin = (isAdminFlag === true);
    _levels  = Object.create(null);
    if (map && typeof map === 'object') {
      for (var k in map) {
        if (Object.prototype.hasOwnProperty.call(map, k)) {
          // normalize: trim + lowercase for defensive compare
          var v = map[k];
          if (typeof v === 'string' && v.length) {
            _levels[String(k)] = v.toLowerCase();
          }
        }
      }
    }
  }

  function clear() {
    _isAdmin = false;
    _levels  = Object.create(null);
  }

  function isAdmin() {
    return _isAdmin === true;
  }

  function levelOf(projectId) {
    var k = _projKey(projectId);
    if (!k) return null;
    return _levels[k] || null;
  }

  function getAccessLevels() {
    // Return shallow copy so callers can't mutate state
    var out = Object.create(null);
    for (var k in _levels) {
      if (Object.prototype.hasOwnProperty.call(_levels, k)) out[k] = _levels[k];
    }
    return out;
  }

  function canView(projectId) {
    if (_isAdmin) return true;
    return levelOf(projectId) !== null;
  }

  function canComment(projectId) {
    if (_isAdmin) return true;
    var lvl = levelOf(projectId);
    return lvl !== null && COMMENT_LEVELS[lvl] === 1;
  }

  function canEdit(projectId) {
    if (_isAdmin) return true;
    var lvl = levelOf(projectId);
    return lvl !== null && EDIT_LEVELS[lvl] === 1;
  }

  function canAdmin(/* projectId */) {
    // Only global admin may change ACL (OQ1 — no per-project admin role)
    return _isAdmin === true;
  }

  return {
    setAccessLevels: setAccessLevels,
    clear:           clear,
    isAdmin:         isAdmin,
    levelOf:         levelOf,
    getAccessLevels: getAccessLevels,
    canView:         canView,
    canComment:      canComment,
    canEdit:         canEdit,
    canAdmin:        canAdmin
  };
})();

// Expose on window for cross-module access (app.js, project-bundle.js etc.)
window.AclHelper = AclHelper;
