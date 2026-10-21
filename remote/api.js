/** Browser transport for the existing same-origin password gateway. No backend credentials. */
export class ApiError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

export function createApi(fetcher = globalThis.fetch.bind(globalThis)) {
  async function request(path, method = 'GET', data, key, match) {
    let response;
    try {
      response = await fetcher(path, {
        method, credentials: 'same-origin', cache: 'no-store', redirect: 'error',
        headers: { ...(data ? { 'content-type': 'application/json' } : {}), ...(key ? { 'idempotency-key': key } : {}), ...(match ? { 'if-match': match } : {}) },
        body: data ? JSON.stringify(data) : undefined,
        signal: AbortSignal.timeout(15000),
      });
    } catch { throw new ApiError(0, 'Laptop unreachable. Check your connection and try again.'); }
    if (!response.ok) {
      const messages = { 401: 'Your session has expired. Sign in again.', 403: 'This action or path is not permitted.', 404: 'This item is no longer available.', 409: 'The server state changed. Reload and review before retrying; your edits are preserved.', 413: 'This file or workspace exceeds its size limit.', 415: 'This file cannot be edited as UTF-8 text.', 428: 'A current file revision is required to save.', 429: 'Too many requests. Wait a moment before retrying.' };
      throw new ApiError(response.status, messages[response.status] ?? (response.status >= 500 ? 'The laptop service is unavailable. Try again shortly.' : 'The request could not be completed. Check your input and laptop connection.'));
    }
    try { return await response.json(); }
    catch { throw new ApiError(502, 'The laptop returned an unexpected response.'); }
  }
  const page = (path, before) => `${path}?limit=20${before ? `&before=${encodeURIComponent(before)}` : ''}`;
  const taskPath = id => {
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) throw new ApiError(400, 'Invalid task ID.');
    return `/api/tasks/${id}`;
  };
  return {
    home: (sort = 'recent', offset = 0) => request(`/api/workspace/home?sort=${encodeURIComponent(sort)}&offset=${offset}`),
    searchWorkspace: query => request(`/api/workspace/search?q=${encodeURIComponent(query)}`),
    openProject: (id, conversationId) => request(`/api/projects/${encodeURIComponent(id)}/open`, 'POST', conversationId ? { conversationId } : {}),
    saveProfile: displayName => request('/profile', 'PUT', { displayName }),
    conversations: (projectId, search = '', archived = false) => request(`/api/projects/${encodeURIComponent(projectId)}/conversations?search=${encodeURIComponent(search)}&archived=${archived}`),
    createConversation: (projectId, repositoryId, title) => request(`/api/projects/${encodeURIComponent(projectId)}/conversations`, 'POST', { repositoryId, title }),
    updateConversation: (id, revision, change) => request(`/api/conversations/${encodeURIComponent(id)}`, 'PUT', { revision, ...change }),
    conversation: id => request(`/api/conversations/${encodeURIComponent(id)}`),
    messages: (id, before) => request(`/api/conversations/${encodeURIComponent(id)}/messages${before ? `?before=${before}` : ''}`),
    chatEvents: (id, after = 0) => request(`/api/conversations/${encodeURIComponent(id)}/events?after=${after}`),
    transcript: id => request(`/api/conversations/${encodeURIComponent(id)}/transcript`),
    projectContext: id => request(`/api/projects/${encodeURIComponent(id)}/context`),
    saveContext: (id, revision, summary, handoff) => request(`/api/projects/${encodeURIComponent(id)}/context`, 'PUT', { revision, summary, handoff }),
    exportContext: id => request(`/api/projects/${encodeURIComponent(id)}/context/export`),
    repositories: () => request('/api/repositories'), workspaces: () => request('/api/workspaces'),
    createWorkspace: (taskId, repositoryId) => request(`${taskPath(taskId)}/workspace`, 'POST', { repositoryId }),
    files: (id, path = '', offset = 0) => request(`/api/workspaces/${encodeURIComponent(id)}/files?path=${encodeURIComponent(path)}&offset=${offset}`),
    readFile: (id, path) => request(`/api/workspaces/${encodeURIComponent(id)}/file?path=${encodeURIComponent(path)}`),
    writeFile: (id, path, content, etag) => request(`/api/workspaces/${encodeURIComponent(id)}/file`, 'PUT', { path, content }, undefined, etag),
    fileDiff: (id, path) => request(`/api/workspaces/${encodeURIComponent(id)}/diff?path=${encodeURIComponent(path)}`),
    session: () => request('/session'), ready: () => request('/api/ready'),
    login: async password => {
      try { return await request('/login', 'POST', { password }); }
      catch (error) { if (error.status === 401) throw new ApiError(401, 'Incorrect password. Please try again.'); throw error; }
    },
    logout: () => request('/logout', 'POST'),
    projects: before => request(page('/api/projects', before)),
    tasks: before => request(page('/api/tasks', before)),
    createProject: name => request('/api/projects', 'POST', { name }),
    submit: (projectId, prompt, key) => request('/api/tasks', 'POST', { projectId, prompt }, key),
    task: id => request(taskPath(id)),
    events: (id, after = 0) => request(`${taskPath(id)}/events?after=${after}&limit=100`),
    cancel: id => request(`${taskPath(id)}/cancel`, 'POST'),
  };
}
