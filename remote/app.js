const $ = id => document.getElementById(id);
const message = text => { $('message').textContent = text; };
let projects = JSON.parse(localStorage.getItem('jess-projects') || '[]');
let tasks = JSON.parse(localStorage.getItem('jess-tasks') || '[]');
let active = false;
const save = () => { localStorage.setItem('jess-projects', JSON.stringify(projects)); localStorage.setItem('jess-tasks', JSON.stringify(tasks)); };
async function api(path, method = 'GET', data) {
  const response = await fetch(path, { method, headers: data ? { 'content-type': 'application/json' } : {}, body: data ? JSON.stringify(data) : undefined });
  const value = await response.json();
  if (!response.ok) { if (response.status === 401 && path !== '/login') showLogin(); throw new Error(value.error || 'Request failed'); }
  return value;
}
function showLogin() { active = false; $('workspace').hidden = true; $('login').hidden = false; }
function options() {
  $('project').replaceChildren();
  for (const project of projects) { const option = document.createElement('option'); option.value = project.id; option.textContent = project.name; $('project').append(option); }
  $('submit-task').disabled = projects.length === 0;
}
function draw() {
  $('tasks').replaceChildren();
  if (!tasks.length) { const p = document.createElement('p'); p.className = 'muted'; p.textContent = 'Create a project, then try your first simulated task.'; $('tasks').append(p); }
  for (const task of [...tasks].reverse()) {
    const card = document.createElement('article'); card.className = 'task';
    const status = document.createElement('span'); status.className = 'state'; status.textContent = task.status;
    const prompt = document.createElement('p'); prompt.textContent = task.prompt;
    card.append(status, prompt);
    if (task.result) { const result = document.createElement('pre'); result.textContent = JSON.stringify(task.result, null, 2); card.append(result); }
    if (task.error) { const p = document.createElement('p'); p.textContent = task.error; card.append(p); }
    if (['QUEUED', 'RUNNING'].includes(task.status)) {
      const button = document.createElement('button'); button.className = 'quiet'; button.textContent = 'Cancel';
      button.onclick = async () => { try { await api(`/api/tasks/${task.id}/cancel`, 'POST'); await refresh(); } catch (e) { message(e.message); } };
      card.append(button);
    }
    $('tasks').append(card);
  }
}
async function refresh() {
  if (!active) return;
  for (let i = 0; i < tasks.length; i++) if (['QUEUED', 'RUNNING'].includes(tasks[i].status)) tasks[i] = await api(`/api/tasks/${tasks[i].id}`);
  save(); draw();
}
async function enter() {
  await api('/session'); active = true; $('login').hidden = true; $('workspace').hidden = false;
  options(); draw();
  try { await api('/api/ready'); $('connection').textContent = '● Laptop online · Database connected'; await refresh(); } catch (e) { message(e.message); }
}
$('login-form').onsubmit = async event => {
  event.preventDefault(); message('Signing in…');
  try { await api('/login', 'POST', { password: $('password').value }); $('password').value = ''; message(''); await enter(); } catch (e) { message(e.message); }
};
$('logout').onclick = async () => { try { await api('/logout', 'POST'); showLogin(); } catch (e) { message(e.message); } };
$('project-form').onsubmit = async event => {
  event.preventDefault(); message('');
  try { const p = await api('/api/projects', 'POST', { name: $('project-name').value }); projects.push(p); save(); options(); $('project').value = p.id; $('project-name').value = ''; } catch (e) { message(e.message); }
};
$('task-form').onsubmit = async event => {
  event.preventDefault(); $('submit-task').disabled = true; message('');
  try { const { task } = await api('/api/tasks', 'POST', { projectId: $('project').value, prompt: $('prompt').value }); tasks.push(task); tasks = tasks.slice(-30); save(); draw(); $('prompt').value = ''; } catch (e) { message(e.message); }
  finally { $('submit-task').disabled = projects.length === 0; }
};
setInterval(() => { if (active && !document.hidden) refresh().catch(e => message(e.message)); }, 3000);
enter().catch(() => showLogin());
