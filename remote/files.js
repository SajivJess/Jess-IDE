/** Review snapshots only: no live host paths or agent execution. */
export function mountFiles(doc, win, api, expired) {
  const $ = id => doc.getElementById(id);
  const node = (tag, text) => { const n = doc.createElement(tag); n.textContent = text; return n; };
  let session = false, loaded = false, busy = false, generation = 0, tasks = [], workspaces = [], workspace = '', folder = '', entries = [], file = null, editor = null;
  const dirty = () => !!editor && editor.value !== file.content;
  const discard = () => !dirty() || win.confirm('Discard your unsaved file changes?');
  function controls() {
    doc.querySelectorAll('.file-entry, #file-breadcrumb button').forEach(button => { button.disabled = busy || !session; });
    $('file-save').disabled = busy || !dirty();
    $('file-reload').disabled = busy || !file;
    $('file-diff').disabled = busy || !file || dirty();
    $('file-state').textContent = file ? (dirty() ? 'Unsaved changes' : 'Saved in review snapshot') : 'Select a text file';
    for (const id of ['workspace-create', 'files-refresh', 'workspace-select', 'repository-select', 'review-task', 'file-find', 'file-undo', 'file-redo']) $(id).disabled = busy || !session;
  }
  async function run(fn) {
    if (busy || !session) return;
    const epoch = generation; busy = true; controls(); $('files-message').textContent = 'Loading…';
    const current = () => epoch === generation;
    try { await fn(current); if (current()) $('files-message').textContent = ''; }
    catch (error) { if (current()) { $('files-message').textContent = error.message; if (error.status === 401) expired(); } }
    finally { if (current()) { busy = false; controls(); } }
  }
  function clearEditor() { editor?.destroy(); editor = null; file = null; $('editor-panel').hidden = true; $('file-patch').textContent = ''; controls(); }
  function options(id, values, label, placeholder) {
    const chosen = $(id).value; $(id).replaceChildren();
    const empty = node('option', placeholder); empty.value = ''; $(id).append(empty);
    for (const value of values) { const option = node('option', label(value)); option.value = value.id; $(id).append(option); }
    if (values.some(v => v.id === chosen)) $(id).value = chosen;
  }
  function drawEntries() {
    const query = $('file-search').value.toLowerCase();
    const list = entries.filter(e => e.name.toLowerCase().includes(query)).sort((a, b) => $('file-sort').value === 'type' ? a.kind.localeCompare(b.kind) || a.name.localeCompare(b.name) : a.name.localeCompare(b.name));
    $('file-list').replaceChildren();
    if (!list.length) $('file-list').append(node('p', 'No matching files in this directory.'));
    for (const entry of list) {
      const button = node('button', `${entry.kind === 'directory' ? '▸' : entry.kind === 'text' ? '◇' : '⊘'} ${entry.name}`);
      button.type = 'button'; button.className = 'file-entry'; button.disabled = busy;
      button.onclick = () => {
        if (entry.kind === 'directory') void run(current => browse(entry.path, current));
        else if (entry.kind !== 'text') $('files-message').textContent = `Read-only metadata: ${entry.reason}. Content is not available in this snapshot.`;
        else if (discard()) void run(current => open(entry.path, current));
      };
      $('file-list').append(button);
    }
  }
  async function browse(path, current) {
    const all = []; let offset = 0;
    do { const page = await api.files(workspace, path, offset); if (!current()) return; all.push(...page.entries); offset = page.nextOffset; } while (offset !== null);
    folder = path; entries = all; $('file-search').value = ''; $('file-breadcrumb').replaceChildren();
    const parts = path ? path.split('/') : [];
    for (let i = 0; i <= parts.length; i++) {
      const destination = parts.slice(0, i).join('/'); const button = node('button', i === 0 ? 'Root' : parts[i - 1]);
      button.className = 'secondary'; button.type = 'button'; button.onclick = () => void run(current => browse(destination, current)); $('file-breadcrumb').append(button);
    }
    drawEntries();
  }
  async function open(path, current) {
    const result = await api.readFile(workspace, path); const module = await import('/editor.js'); if (!current()) return;
    clearEditor(); file = result; $('editor-panel').hidden = false; $('file-title').textContent = path;
    editor = module.createEditor($('file-editor'), path, file.content, controls); controls();
  }
  async function refresh(current) {
    const [repos, spaces] = await Promise.all([api.repositories(), api.workspaces()]); if (!current()) return;
    workspaces = spaces.workspaces; options('repository-select', repos.repositories, r => `${r.name} · ${r.branch} · ${r.baseCommit.slice(0, 7)}`, 'Choose registered revision');
    options('workspace-select', workspaces, w => `${w.name} · task ${w.taskId.slice(0, 8)}`, 'Choose a review workspace'); loaded = true;
    $('registration-help').textContent = repos.repositories.length ? 'Registrations are fixed committed revisions. Uncommitted laptop files are excluded.' : 'No repository is registered for this account. Register an explicit repository and branch on the laptop first.';
  }
  $('files-refresh').onclick = () => void run(refresh);
  $('workspace-create').onclick = () => void run(async current => {
    if (!discard()) return;
    if (!$('review-task').value || !$('repository-select').value) throw new Error('Choose a finished task and registered repository.');
    const result = await api.createWorkspace($('review-task').value, $('repository-select').value); if (!current()) return;
    await refresh(current); if (!current()) return; $('workspace-select').value = result.id; await select(result.id, current);
  });
  async function select(id, current) {
    clearEditor(); workspace = id; entries = []; drawEntries(); $('workspace-files').hidden = !id;
    const selected = workspaces.find(w => w.id === id);
    $('workspace-context').textContent = selected ? `${selected.name} · ${selected.branch} · base ${selected.baseCommit.slice(0, 12)} · review only` : '';
    if (id) await browse('', current);
  }
  $('workspace-select').onchange = () => {
    if (!discard()) { $('workspace-select').value = workspace; return; }
    void run(current => select($('workspace-select').value, current));
  };
  $('file-search').oninput = drawEntries; $('file-sort').onchange = drawEntries;
  $('file-find').onclick = () => editor?.find(); $('file-undo').onclick = () => editor?.undo(); $('file-redo').onclick = () => editor?.redo();
  $('file-reload').onclick = () => { if (discard()) void run(current => open(file.path, current)); };
  $('file-save').onclick = () => void run(async current => {
    const content = editor.value; const saved = await api.writeFile(workspace, file.path, content, file.etag); if (!current()) return;
    file = saved; $('file-patch').textContent = ''; await browse(folder, current);
  });
  $('file-diff').onclick = () => void run(async current => {
    const diff = await api.fileDiff(workspace, file.path); if (!current()) return;
    $('file-patch').replaceChildren();
    if (diff.truncated) $('file-patch').textContent = 'Diff exceeds the preview limit.';
    else for (const line of (diff.changed ? diff.diff : 'No changes from the registered base.').split('\n')) {
      const span = node('span', line + '\n'); span.className = line.startsWith('+') ? 'diff-add' : line.startsWith('-') ? 'diff-remove' : ''; $('file-patch').append(span);
    }
  });
  const leaving = event => { if (dirty()) { event.preventDefault(); event.returnValue = ''; } }; win.addEventListener('beforeunload', leaving);
  return {
    update(state, active) {
      const ready = state.session === 'ready';
      if (!ready && session) { generation++; busy = false; loaded = false; clearEditor(); workspace = ''; entries = []; workspaces = []; $('file-list').replaceChildren(); $('workspace-context').textContent = ''; for (const id of ['repository-select', 'workspace-select', 'review-task']) $(id).replaceChildren(); }
      session = ready; tasks = state.tasks.filter(t => ['COMPLETED', 'FAILED', 'CANCELLED'].includes(t.status));
      options('review-task', tasks, t => t.prompt.slice(0, 70), 'Choose a finished task');
      if (ready && active && !loaded && !busy) void run(refresh);
      controls();
    },
    destroy() { generation++; editor?.destroy(); win.removeEventListener('beforeunload', leaving); },
  };
}
