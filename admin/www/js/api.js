/* ============================================================
   api.js — Centralized API client for mxLore Admin UI
   Handles CSRF tokens, session cookies, error routing
   ============================================================ */

const Api = (function () {
  let csrfToken = '';

  function setCsrfToken(token) {
    csrfToken = token;
  }

  function getCsrfToken() {
    return csrfToken;
  }

  async function request(method, path, body) {
    const opts = {
      method: method,
      headers: { 'Content-Type': 'application/json' },
      credentials: 'same-origin'
    };

    // CSRF token for mutating requests
    if (method !== 'GET' && csrfToken) {
      opts.headers['X-CSRF-Token'] = csrfToken;
    }

    if (body && method !== 'GET') {
      opts.body = JSON.stringify(body);
    }

    const res = await fetch('api' + path, opts);

    // Session expired — redirect to login
    if (res.status === 401) {
      csrfToken = '';
      App.showLogin('Session expired. Please sign in again.');
      throw new Error('session_expired');
    }

    // CSRF failure
    if (res.status === 403) {
      const data = await res.json().catch(function () { return {}; });
      throw new Error(data.error || 'forbidden');
    }

    const data = await res.json().catch(function () { return null; });

    if (!res.ok) {
      throw new Error(data && data.error ? data.error : 'request_failed');
    }

    return data;
  }

  // --- Auth ---
  function login(apiKey) {
    return request('POST', '/auth/login', { api_key: apiKey });
  }

  function logout() {
    return request('POST', '/auth/logout', {});
  }

  function checkSession() {
    return request('GET', '/auth/check');
  }

  // --- Developers ---
  function getDevelopers() {
    return request('GET', '/developers');
  }

  function createDeveloper(name, email, role) {
    var body = { name: name, email: email || null };
    if (role) body.role = role;
    return request('POST', '/developers', body);
  }

  function updateDeveloper(id, data) {
    return request('PUT', '/developers/' + id, data);
  }

  function deleteDeveloper(id, hard) {
    return request('DELETE', '/developers/' + id + (hard ? '?hard=true' : ''));
  }

  function mergeDevelopers(sourceIds, targetId) {
    return request('POST', '/developers/merge', {
      source_ids: sourceIds,
      target_id: targetId
    });
  }

  // --- Keys ---
  function getKeys(developerId) {
    return request('GET', '/developers/' + developerId + '/keys');
  }

  function createKey(developerId, name, permissions, expiresAt) {
    return request('POST', '/developers/' + developerId + '/keys', {
      name: name,
      permissions: permissions,
      expires_at: expiresAt || null
    });
  }

  function deleteKey(keyId, hard) {
    return request('DELETE', '/keys/' + keyId + (hard ? '?hard=true' : ''));
  }

  function updateKey(keyId, permissions) {
    return request('PUT', '/keys/' + keyId, { permissions: permissions });
  }

  // --- Environments ---
  function getEnvironments(developerId) {
    return request('GET', '/developers/' + developerId + '/environments');
  }

  function deleteEnvironment(envId) {
    return request('DELETE', '/environments/' + envId);
  }

  // --- Projects ---
  function getProjects() {
    return request('GET', '/projects');
  }

  function updateProject(id, data) {
    return request('PUT', '/projects/' + id, data);
  }

  function getProjectDashboard(id) {
    return request('GET', '/projects/' + id + '/dashboard');
  }

  function deleteProject(id, hard) {
    return request('DELETE', '/projects/' + id + (hard ? '?hard=true' : ''));
  }

  function mergeProjects(sourceIds, targetId) {
    return request('POST', '/projects/merge', {
      source_ids: sourceIds,
      target_id: targetId
    });
  }

  // --- Global ---
  function getGlobalStats() {
    return request('GET', '/global/stats');
  }

  function getActivity() {
    return request('GET', '/global/activity');
  }

  function getAccessLogStats() {
    return request('GET', '/global/access-log-stats');
  }

  function getPrefetchStats() {
    return request('GET', '/global/prefetch');
  }

  function getHealth() {
    return request('GET', '/global/health');
  }

  function getActiveSessions() {
    return request('GET', '/global/sessions');
  }

  function getSkillEvolution() {
    return request('GET', '/global/skill-evolution');
  }

  function getRecallMetrics() {
    return request('GET', '/global/recall-metrics');
  }

  function getGraphStats() {
    return request('GET', '/global/graph-stats');
  }

  function getLessonStats() {
    return request('GET', '/global/lesson-stats');
  }

  function getEmbeddingStats() {
    return request('GET', '/global/embedding-stats');
  }

  function getTokenStats() {
    return request('GET', '/global/token-stats');
  }

  function getSkillsDashboard() {
    return request('GET', '/skills/dashboard');
  }

  function postSkillFeedback(findingUid, reaction) {
    return request('POST', '/skills/feedback', {
      finding_uid: findingUid,
      reaction: reaction
    });
  }

  function postCleanup() {
    return request('POST', '/global/cleanup', {});
  }

  function postBackup() {
    return request('POST', '/global/backup', {});
  }

  function getDeveloperProjects(developerId) {
    return request('GET', '/developers/' + developerId + '/projects');
  }

  function updateDeveloperProjects(developerId, projects) {
    return request('PUT', '/developers/' + developerId + '/projects', {
      projects: projects
    });
  }

  // FR#3353 Phase A Gap#2 — single-pair project-access upsert/delete
  function setProjectAccess(projId, developerId, accessLevel) {
    return request('PUT', '/projects/' + projId + '/access', {
      developer_id: developerId,
      access_level: accessLevel
    });
  }

  // FR#3353 Phase C — filterable document list per project
  function listProjectDocs(projId, opts) {
    opts = opts || {};
    var qs = [];
    if (opts.type)   qs.push('type='   + encodeURIComponent(opts.type));
    if (opts.q)      qs.push('q='      + encodeURIComponent(opts.q));
    if (opts.status) qs.push('status=' + encodeURIComponent(opts.status));
    if (opts.doc_id) qs.push('doc_id=' + encodeURIComponent(opts.doc_id));
    if (opts.limit)  qs.push('limit='  + opts.limit);
    if (opts.offset) qs.push('offset=' + opts.offset);
    var path = '/projects/' + projId + '/documents' +
               (qs.length ? '?' + qs.join('&') : '');
    return request('GET', path);
  }

  // FR#3353 Phase C — full document detail (view-only)
  function getDoc(docId) {
    return request('GET', '/docs/' + docId);
  }

  // FR#3353 Phase C — soft-delete document
  function deleteDoc(docId) {
    return request('DELETE', '/docs/' + docId);
  }

  // FR#3353 Phase C — delete single relation row
  function deleteRelation(relId) {
    return request('DELETE', '/relations/' + relId);
  }

  // FR#3353 Phase C — admin-side document edit
  function updateDocAdmin(docId, changes) {
    return request('PUT', '/docs/' + docId, changes);
  }

  // FR#3353 Phase C — delete project-relation
  function deleteProjectRelation(relId) {
    return request('DELETE', '/project-relations/' + relId);
  }

  // --- Notes (FR#2936/Plan#3266 M2.6) ---
  function getDeepThreads() {
    return request('GET', '/notes/deep-threads');
  }

  // --- Intelligence status (FR#3294 / SPEC#3583) ---
  function getIntelligenceStatus() {
    return request('GET', '/intelligence/status');
  }

  // --- Doc review thread (FR#3472 A / SPEC#3583) ---
  function getDocThread(docId) {
    return request('GET', '/docs/' + encodeURIComponent(docId) + '/thread');
  }

  // --- Project reviews list (FR#3472 C / SPEC#3583) ---
  function getProjectReviews(projId) {
    return request('GET', '/projects/' + encodeURIComponent(projId) + '/reviews');
  }

  return {
    setCsrfToken: setCsrfToken,
    getCsrfToken: getCsrfToken,
    login: login,
    logout: logout,
    checkSession: checkSession,
    getDevelopers: getDevelopers,
    createDeveloper: createDeveloper,
    updateDeveloper: updateDeveloper,
    deleteDeveloper: deleteDeveloper,
    mergeDevelopers: mergeDevelopers,
    getKeys: getKeys,
    createKey: createKey,
    deleteKey: deleteKey,
    updateKey: updateKey,
    getEnvironments: getEnvironments,
    deleteEnvironment: deleteEnvironment,
    getProjects: getProjects,
    updateProject: updateProject,
    getProjectDashboard: getProjectDashboard,
    setProjectAccess: setProjectAccess,
    listProjectDocs: listProjectDocs,
    getDoc: getDoc,
    deleteDoc: deleteDoc,
    deleteRelation: deleteRelation,
    updateDocAdmin: updateDocAdmin,
    deleteProjectRelation: deleteProjectRelation,
    deleteProject: deleteProject,
    mergeProjects: mergeProjects,
    getGlobalStats: getGlobalStats,
    getActivity: getActivity,
    getAccessLogStats: getAccessLogStats,
    getPrefetchStats: getPrefetchStats,
    getHealth: getHealth,
    getActiveSessions: getActiveSessions,
    getSkillEvolution: getSkillEvolution,
    getRecallMetrics: getRecallMetrics,
    getGraphStats: getGraphStats,
    getLessonStats: getLessonStats,
    getEmbeddingStats: getEmbeddingStats,
    getTokenStats: getTokenStats,
    getSkillsDashboard: getSkillsDashboard,
    postSkillFeedback: postSkillFeedback,
    postCleanup: postCleanup,
    postBackup: postBackup,
    getDeveloperProjects: getDeveloperProjects,
    updateDeveloperProjects: updateDeveloperProjects,

    // --- Notes (FR#2936/Plan#3266 M2.6) ---
    getDeepThreads: getDeepThreads,

    // --- FR#3294 Intelligence / FR#3472 Thread-Viewer (SPEC#3583) ---
    getIntelligenceStatus: getIntelligenceStatus,
    getDocThread: getDocThread,
    getProjectReviews: getProjectReviews,

    // --- Settings (v2.4.0) ---
    getSettings: function () {
      return request('GET', '/settings');
    },
    saveSettings: function (obj) {
      return request('PUT', '/settings', obj);
    },
    testConnection: function (url, mode) {
      return request('POST', '/settings/test-connection', { url: url, mode: mode || '' });
    },

    // --- Invites (v2.4.0) ---
    listInvites: function (statusFilter) {
      var path = '/invites';
      if (statusFilter && statusFilter !== 'all') path += '?status=' + encodeURIComponent(statusFilter);
      return request('GET', path);
    },
    createInvite: function (payload) {
      // payload: { developer_id, key_name, permissions, expires_hours, mode }
      return request('POST', '/invites', payload);
    },
    deleteInvite: function (inviteId) {
      return request('DELETE', '/invites/' + inviteId);
    },
    cleanupInvites: function () {
      return request('DELETE', '/invites/cleanup');
    }
  };
})();
