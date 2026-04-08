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
      App.showLogin('Sitzung abgelaufen. Bitte erneut anmelden.');
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

  function createDeveloper(name, email) {
    return request('POST', '/developers', { name: name, email: email || null });
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

  function createProject(name, slug) {
    return request('POST', '/projects', { name: name, slug: slug });
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
    createProject: createProject,
    updateProject: updateProject,
    getProjectDashboard: getProjectDashboard,
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
    updateDeveloperProjects: updateDeveloperProjects
  };
})();
