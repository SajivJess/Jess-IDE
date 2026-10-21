import { test, expect } from '@playwright/test';

let sharedCookies = [];
async function login(page) {
  if (sharedCookies.length) {
    await page.context().addCookies(sharedCookies);
    await page.goto('/#chat');
    await expect(page.locator('#connection-label')).toHaveText('Laptop online');
    return;
  }
  await page.goto('/#chat');
  await page.getByLabel('Access password').fill('browser-tests-only-password-12345');
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await expect(page.locator('#connection-label')).toHaveText('Laptop online');
  sharedCookies = await page.context().cookies();
}
async function createProject(page, name) {
  await page.locator('nav').getByText('Projects', { exact: true }).click();
  await page.getByLabel('New project').fill(name);
  await page.getByRole('button', { name: 'Create project', exact: false }).click();
  await expect(page.locator('#projects').getByRole('heading', { name, exact: true })).toBeVisible();
}

test('sign in, create a project, run a task, replay events, restore history and sign out', async ({ page }, info) => {
  const errors = []; page.on('pageerror', error => errors.push(error.message));
  await login(page);
  const name = `Browser ${info.project.name} ${Date.now()}`;
  await createProject(page, name);
  await page.locator('#projects').getByRole('button').filter({ hasText: name }).click();
  const prompt = `Validate mobile workflow ${name}`;
  await page.getByLabel('Your task', { exact: true }).fill(prompt);
  await page.getByRole('button', { name: 'Run simulated task' }).click();
  await expect(page.locator('#task-detail h2')).toHaveText(prompt);
  await expect(page.locator('#task-detail .status')).toHaveText('COMPLETED', { timeout: 25000 });
  await expect(page.locator('#task-detail')).toContainText('No real files were edited');
  await expect(page.locator('.event-list')).toContainText('task completed');
  await page.getByRole('tab', { name: 'Checks' }).click();
  await expect(page.locator('#detail-content')).toContainText('simulated');
  await page.getByRole('tab', { name: 'Changes' }).click();
  await expect(page.locator('#detail-content')).toContainText('No Git diff was produced');
  await page.reload();
  await expect(page.locator('#tasks')).toContainText(prompt);
  await page.locator('nav').getByText('Tasks', { exact: true }).click();
  await page.getByRole('link', { name: 'New task', exact: false }).click();
  await page.getByRole('link', { name: 'Jess Ide Dev Home', exact: true }).click();
  await expect(page.locator('#home-projects')).toContainText(name);
  await page.screenshot({ path: `.local/mobile-preview/${info.project.name}-home.png`, fullPage: true });
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  await page.goto('/#chat');
  await page.locator('#chat-overflow summary').click();
  await page.getByRole('link', { name: 'Settings', exact: true }).click();
  for (const theme of ['light', 'dark']) {
    await page.getByLabel('Theme').selectOption(theme);
    const ratios = await page.evaluate(() => {
      const style = getComputedStyle(document.documentElement);
      const luminance = token => {
        const value = style.getPropertyValue(token).trim().slice(1); const hex = value.length === 3 ? value.split('').map(c => c + c).join('') : value;
        const rgb = [0, 2, 4].map(index => parseInt(hex.slice(index, index + 2), 16) / 255).map(c => c <= .04045 ? c / 12.92 : ((c + .055) / 1.055) ** 2.4);
        return rgb[0] * .2126 + rgb[1] * .7152 + rgb[2] * .0722;
      };
      return [['--ink', '--bg'], ['--muted', '--panel'], ['--on-accent', '--accent'], ['--accent', '--panel'], ['--success', '--panel'], ['--warning', '--panel'], ['--error', '--panel']].map(pair => { const a = luminance(pair[0]), b = luminance(pair[1]); return (Math.max(a, b) + .05) / (Math.min(a, b) + .05); });
    });
    for (const ratio of ratios) expect(ratio).toBeGreaterThanOrEqual(4.5);
  }
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');
  await page.reload();
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');
  await expect(page.locator('#connection-label')).toHaveText('Laptop online');
  await page.screenshot({ path: `.local/mobile-preview/${info.project.name}-settings-dark.png`, fullPage: true });
  await page.getByRole('button', { name: 'Sign out', exact: true }).click();
  sharedCookies = [];
  await expect(page.locator('#login')).toBeVisible();
  await expect(page.locator('#workspace')).toBeHidden();
  expect(await page.evaluate(() => Object.keys(localStorage))).toEqual(['jess-theme']);
  expect(errors).toEqual([]);
});

test('cancels work and presents unsupported files without pretending to edit', async ({ page }, info) => {
  await login(page);
  const name = `Cancel ${info.project.name} ${Date.now()}`;
  await createProject(page, name);
  await page.locator('#projects').getByRole('button').filter({ hasText: name }).click();
  await page.getByLabel('Your task', { exact: true }).fill('Cancel this test task');
  await page.getByRole('button', { name: 'Run simulated task' }).click();
  await page.getByRole('button', { name: 'Cancel task', exact: true }).click();
  await page.locator('nav').getByText('Tasks', { exact: true }).click();
  await page.getByRole('button', { name: 'Refresh workspace' }).click();
  await expect(page.locator('#task-detail .status')).toHaveText('CANCELLED', { timeout: 25000 });
  await page.locator('nav').getByText('Files', { exact: true }).click();
  await expect(page.locator('#page-files')).toContainText('not live laptop files or agent output');
  await expect(page.locator('#page-files input[type=file]')).toHaveCount(0);
});

test('renders untrusted project names as text and recovers from offline and expired sessions', async ({ page, context }, info) => {
  await login(page);
  const name = `<img src=x onerror=alert(1)> ${info.project.name}`;
  await createProject(page, name);
  await expect(page.locator('#projects img')).toHaveCount(0);
  await context.setOffline(true);
  await expect(page.locator('#connection-label')).toHaveText('Offline');
  await context.setOffline(false);
  await expect(page.locator('#connection-label')).toHaveText('Laptop online');
  await context.clearCookies();
  await page.locator('nav').getByText('Tasks', { exact: true }).click();
  await page.getByRole('button', { name: 'Refresh workspace' }).click();
  await expect(page.locator('#login')).toBeVisible();
  await expect(page.locator('#projects')).not.toContainText(name);
});

test('PWA metadata and offline fallback never cache API responses', async ({ page, context }) => {
  await login(page);
  const manifest = await (await page.request.get('/manifest.webmanifest')).json();
  expect(manifest.display).toBe('standalone');
  await page.evaluate(() => navigator.serviceWorker.ready);
  await page.reload();
  await expect(page.locator('#workspace')).toBeVisible();
  const cached = await page.evaluate(async () => {
    const entries = await Promise.all((await caches.keys()).map(async key => {
      const requests = await (await caches.open(key)).keys();
      return requests.map(request => new URL(request.url).pathname);
    }));
    return entries.flat();
  });
  expect(cached).toEqual(['/offline.html']);
  await context.setOffline(true);
  await page.reload();
  await expect(page.getByRole('heading', { name: 'Your laptop is out of reach' })).toBeVisible();
});

test('local-only capability disables submission and diff contents render safely', async ({ page }, info) => {
  await login(page);
  const id = '00000000-0000-4000-8000-000000000099';
  const task = { id, projectId: id, prompt: 'Diff renderer fixture', status: 'COMPLETED', attempt: 1, maxAttempts: 3, cancelRequested: false,
    createdAt: new Date().toISOString(), updatedAt: new Date().toISOString(), error: null,
    result: { simulated: false, summary: 'Renderer test fixture; no agent run.', files: [{ path: 'src/test.ts', change: 'added' }], checks: [{ name: 'TypeScript', status: 'passed' }],
      execution: { branch: 'test/fixture', baseCommit: 'a'.repeat(40), diff: '+<img src=x onerror=alert(1)>\n-old content\n@@ fixture @@', truncated: true } } };
  await page.route('**/session', route => route.fulfill({ json: { ok: true, capabilities: { taskSubmission: false, agentMode: 'local-only' } } }));
  await page.route('**/api/tasks?*', route => route.fulfill({ json: { tasks: [task], nextCursor: null } }));
  await page.route(`**/api/tasks/${id}`, route => route.fulfill({ json: task }));
  await page.route(`**/api/tasks/${id}/events?*`, route => route.fulfill({ json: { events: [], nextCursor: 0, hasMore: false, taskStatus: 'COMPLETED' } }));
  await page.locator('nav').getByText('Tasks', { exact: true }).click();
  await page.getByRole('button', { name: 'Refresh workspace' }).click();
  await expect(page.locator('#submit-task')).toBeDisabled();
  await expect(page.locator('#mode-badge')).toHaveText('Real agent · local only');
  await page.locator('nav').getByText('Tasks', { exact: true }).click();
  await page.locator('#tasks').getByRole('button').filter({ hasText: 'Diff renderer fixture' }).click();
  await page.getByRole('tab', { name: 'Changes' }).click();
  await expect(page.locator('.diff')).toContainText('<img src=x onerror=alert(1)>');
  await expect(page.locator('.diff img')).toHaveCount(0);
  await expect(page.locator('#detail-content')).toContainText('truncated by the server');
  await page.screenshot({ path: `.local/mobile-preview/${info.project.name}-diff.png`, fullPage: true });
  if (info.project.name === 'phone') {
    await page.setViewportSize({ width: 320, height: 700 });
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  }
});

test('edits a review snapshot, shows its real diff and preserves a conflicting draft', async ({ page }, info) => {
  const errors = []; page.on('pageerror', error => errors.push(error.message));
  const csp = []; page.on('console', message => { if (message.type() === 'error' && /Content Security Policy/.test(message.text())) csp.push(message.text()); });
  await login(page);
  const project = await (await page.request.post('/api/projects', { headers: { origin: 'http://localhost:4173' }, data: { name: 'Editor scenario' } })).json();
  const task = await (await page.request.post('/api/tasks', { headers: { origin: 'http://localhost:4173' }, data: { projectId: project.id, prompt: 'Editor scenario fixture' } })).json();
  await page.request.post(`/api/tasks/${task.task.id}/cancel`, { headers: { origin: 'http://localhost:4173' } });
  await expect.poll(async () => (await (await page.request.get(`/api/tasks/${task.task.id}`)).json()).status).toBe('CANCELLED');
  await page.locator('nav').getByText('Tasks', { exact: true }).click();
  await page.getByRole('button', { name: 'Refresh workspace' }).click();
  await page.locator('nav').getByText('Files', { exact: true }).click();
  await page.getByText('Create a review workspace', { exact: true }).click();
  await expect(page.locator('#repository-select option')).toHaveCount(2);
  await page.locator('#repository-select').selectOption({ index: 1 });
  await page.locator('#review-task').selectOption({ index: 1 });
  await page.getByRole('button', { name: 'Create review snapshot', exact: true }).click();
  await page.locator('#file-list').getByRole('button', { name: 'image.png', exact: false }).click();
  await expect(page.locator('#files-message')).toContainText('Read-only metadata');
  await page.locator('#file-list').getByRole('button', { name: 'src', exact: false }).click();
  await page.locator('#file-list').getByRole('button', { name: 'main.ts', exact: false }).click();
  const editor = page.getByRole('textbox', { name: 'File content' });
  await expect(editor).toContainText('export const greeting');
  await editor.click(); await editor.press('ControlOrMeta+A'); await editor.pressSequentially('export const greeting = "edited";'); await editor.press('Enter');
  await expect(page.locator('#file-state')).toHaveText('Unsaved changes');
  await page.getByRole('button', { name: 'Save snapshot', exact: true }).click();
  await expect(page.locator('#file-state')).toHaveText('Saved in review snapshot');
  await page.getByRole('button', { name: 'Review diff', exact: true }).click();
  await expect(page.locator('#file-patch')).toContainText('+export const greeting = "edited";');
  const id = await page.locator('#workspace-select').inputValue();
  const before = await (await page.request.get(`/api/workspaces/${id}/file?path=src/main.ts`)).json();
  expect((await page.request.put(`/api/workspaces/${id}/file`, { headers: { origin: 'http://localhost:4173', 'if-match': before.etag }, data: { path: 'src/main.ts', content: 'server changed\n' } })).status()).toBe(200);
  await editor.click(); await editor.press('ControlOrMeta+A'); await editor.pressSequentially('my unsaved draft'); await editor.press('Enter');
  await page.getByRole('button', { name: 'Save snapshot', exact: true }).click();
  await expect(page.locator('#files-message')).toContainText('your edits are preserved');
  await expect(editor).toContainText('my unsaved draft');
  await page.locator('nav').getByText('Tasks', { exact: true }).click();
  await page.getByRole('link', { name: 'New task', exact: false }).click();
  await page.locator('nav').getByText('Files', { exact: true }).click();
  await expect(editor).toContainText('my unsaved draft');
  page.once('dialog', dialog => dialog.accept());
  await page.getByRole('button', { name: 'Reload file', exact: true }).click();
  await expect(editor).toContainText('server changed');
  await page.getByRole('button', { name: 'Find / replace', exact: true }).click();
  await expect(page.locator('.cm-search')).toBeVisible();
  await page.screenshot({ path: `.local/mobile-preview/${info.project.name}-snapshot-editor.png`, fullPage: true });
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  expect(errors).toEqual([]); expect(csp).toEqual([]);
  await page.context().clearCookies();
  await page.getByRole('button', { name: 'Reload file', exact: true }).click();
  await expect(page.locator('#login')).toBeVisible();
  await expect(page.locator('.cm-editor')).toHaveCount(0);
});

test('restores recorded conversations, keeps portable notes and downloads the actual transcript', async ({ page }, info) => {
  const errors=[]; page.on('pageerror', error=>errors.push(error.message));
  await login(page);
  await chooseFixtureChat(page);
  await expect(page.locator('#chat-history')).toContainText('Browser fixture question');
  await expect(page.locator('#chat-history')).toContainText('Recorded fixture reply <img');
  await expect(page.locator('#chat-history img')).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Send message', exact: true })).toBeDisabled();
  const id=(await page.evaluate(()=>location.hash)).split('/')[1];
  expect((await page.request.post(`/api/conversations/${id}/messages`, { headers: { origin: 'http://localhost:4173' }, data: { content: 'Run tools' } })).status()).toBe(403);
  await page.reload();
  await expect(page.locator('#chat-history')).toContainText('Recorded fixture reply');
  await page.locator('#chat-overflow summary').click();
  await page.getByRole('button', { name: 'Conversation details', exact: true }).click();
  await page.getByLabel('Project summary and decisions').fill('Use native CLI context; retain portable handoff notes.');
  await page.getByLabel('Handoff notes', { exact: true }).fill('Continue the integration checks.');
  await page.getByRole('button', { name: 'Save project context', exact: true }).click();
  await expect(page.locator('#context-state')).toContainText('Saved');
  await page.getByRole('button', { name: 'Close conversation details', exact: true }).click();
  await page.locator('#chat-overflow summary').click();
  const downloading=page.waitForEvent('download');
  await page.getByRole('button', { name: 'Export transcript', exact: true }).click();
  const download=await downloading;
  expect(download.suggestedFilename()).toBe(`conversation-${id}.md`);
  await download.saveAs(`.local/mobile-preview/${info.project.name}-chat-transcript.md`);
  await page.locator('nav').getByText('Tasks', { exact: true }).click();
  await page.getByRole('link', { name: 'New task', exact: false }).click();
  await page.locator('nav').getByText('Chat', { exact: true }).click();
  await page.locator('#chat-overflow summary').click();
  await page.getByRole('button', { name: 'Conversation details', exact: true }).click();
  await expect(page.getByLabel('Handoff notes', { exact: true })).toHaveValue('Continue the integration checks.');
  const projectId=await page.locator('#chat-project').inputValue();
  const context=await (await page.request.get(`/api/projects/${projectId}/context`)).json();
  expect((await page.request.put(`/api/projects/${projectId}/context`, { headers: { origin: 'http://localhost:4173' }, data: { revision: context.revision, summary: 'Server updated notes', handoff: 'Server handoff' } })).status()).toBe(200);
  await page.getByLabel('Handoff notes', { exact: true }).fill('Keep my conflicting draft');
  await page.getByRole('button', { name: 'Save project context', exact: true }).click();
  await expect(page.locator('#chat-notice')).toContainText('your edits are preserved');
  await expect(page.getByLabel('Handoff notes', { exact: true })).toHaveValue('Keep my conflicting draft');
  page.once('dialog', dialog=>dialog.accept());
  await page.getByRole('button', { name: 'Reload project context', exact: true }).click();
  await expect(page.getByLabel('Handoff notes', { exact: true })).toHaveValue('Server handoff');
  await page.getByRole('button', { name: 'Close conversation details', exact: true }).click();
  await page.screenshot({ path: `.local/mobile-preview/${info.project.name}-chat.png`, fullPage: true });
  if(info.project.name==='phone')await page.setViewportSize({width:320,height:700});
  expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);
  await page.context().clearCookies();
  await page.locator('#chat-overflow summary').click();
  await page.getByRole('button', { name: 'Reconnect / refresh', exact: true }).click();
  await expect(page.locator('#login')).toBeVisible();
  await expect(page.locator('#chat-history')).not.toContainText('Recorded fixture reply');
  await expect(page.getByLabel('Project summary and decisions')).toHaveValue('');
  expect(errors).toEqual([]);
});

async function openConversationMenu(page) { await page.locator('#chat-overflow summary').click(); }
async function chooseFixtureChat(page) {
  await page.locator('nav').getByText('Chat', { exact: true }).click();
  if(await page.locator('#conversation-drawer').getAttribute('open')===null)await page.getByRole('button',{name:'Open conversations',exact:true}).click();
  await page.locator('#chat-project').selectOption({label:'Chat fixture project'});
  await expect(page.locator('#chat-project')).toBeEnabled();
  if(await page.locator('#conversation-drawer').getAttribute('open')===null)await page.getByRole('button',{name:'Open conversations',exact:true}).click();
  await page.getByRole('button',{name:/^Chat test fixture/}).click();
  await expect(page.locator('#chat-heading')).toHaveText('Chat test fixture');
}

test('prompt shortcuts and message actions preserve drafts without dispatching agent work', async ({page,context},info)=>{
  const errors=[], dispatches=[]; page.on('pageerror',error=>errors.push(error.message));
  page.on('request',request=>{if(request.method()==='POST' && /\/api\/conversations\/[^/]+\/messages$/.test(new URL(request.url()).pathname))dispatches.push(request.url());});
  await login(page); await chooseFixtureChat(page);
  const input=page.getByRole('textbox',{name:'Message Antigravity',exact:true});
  await input.fill('Keep my existing instructions.');
  await page.getByRole('button',{name:'Prompt shortcuts',exact:true}).click();
  await expect(page.getByRole('dialog',{name:'Prompt shortcuts',exact:true})).toBeVisible();
  await page.screenshot({path:`.local/mobile-preview/${info.project.name}-prompt-shortcuts.png`,animations:'disabled'});
  await page.getByRole('button',{name:'Explain code',exact:false}).click();
  await expect(input).toHaveValue(/^Keep my existing instructions\.\n\nExplain the relevant code/);
  await expect(input).toBeFocused();
  const beforeReuse=await input.inputValue();
  await page.locator('.chat-user').first().getByRole('button',{name:'Reuse prompt',exact:true}).click();
  await expect(input).toHaveValue(beforeReuse+'\n\nBrowser fixture question');
  await context.grantPermissions(['clipboard-read','clipboard-write']);
  await page.getByRole('button',{name:'Copy user message',exact:true}).first().click();
  expect(await page.evaluate(()=>navigator.clipboard.readText())).toBe('Browser fixture question');
  const preserved=await input.inputValue();
  await page.locator('#navigation').getByRole('link',{name:'Tasks',exact:true}).click();
  await page.locator('#navigation').getByRole('link',{name:'Chat',exact:true}).click();
  await expect(input).toHaveValue(preserved);
  await input.fill('x'.repeat(7990));
  await page.getByRole('button',{name:'Prompt shortcuts',exact:true}).click();
  await page.getByRole('button',{name:'Write tests',exact:false}).click();
  await expect(input).toHaveValue('x'.repeat(7990));
  await expect(page.locator('#chat-prompts-dialog')).toBeVisible();
  await expect(page.locator('#chat-prompts-dialog [data-chat-error]')).toContainText('8,000-character draft limit');
  await page.keyboard.press('Escape');
  await expect(page.getByRole('button',{name:'Prompt shortcuts',exact:true})).toBeFocused();
  await expect(page.locator('#chat-notice')).toContainText('8,000-character draft limit');
  await context.setOffline(true); await expect(page.locator('#chat-mobile-status')).toHaveText('Browser offline');
  await input.fill('Offline draft');
  await page.getByRole('button',{name:'Prompt shortcuts',exact:true}).click();
  await page.getByRole('button',{name:'Debug a problem',exact:false}).click();
  await expect(input).toHaveValue(/^Offline draft\n\nInvestigate this problem/);
  await expect(page.getByRole('button',{name:'Send message',exact:true})).toBeDisabled();
  expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);
  expect(dispatches).toEqual([]); expect(errors).toEqual([]);
  await context.setOffline(false); await input.fill('');
});

test('chat-first layout renders safe Markdown, copies code and stays usable in a keyboard-sized viewport', async ({page,context}, info)=>{
  const errors=[], tracking=[];page.on('pageerror',error=>errors.push(error.message));page.on('request',request=>{if(request.url().includes('attacker.example'))tracking.push(request.url());});
  await login(page);
  await expect(page.locator('#page-chat')).toBeVisible();
  expect(await page.locator('#navigation a').allTextContents()).toEqual(['Home','Chat','Projects','Tasks','Files']);
  await chooseFixtureChat(page);
  await expect(page.locator('.markdown-content h3')).toHaveText('Review findings');
  for(const theme of ['dark','light']){
    const contrast=await page.evaluate(theme=>{
      document.documentElement.dataset.theme=theme;
      const luminance=color=>{const rgb=color.match(/[\d.]+/g).slice(0,3).map(Number).map(c=>c/255).map(c=>c<=.04045?c/12.92:((c+.055)/1.055)**2.4);return rgb[0]*.2126+rgb[1]*.7152+rgb[2]*.0722;};
      const label=document.querySelector('.message-meta strong');const a=luminance(getComputedStyle(label).color),b=luminance(getComputedStyle(label.closest('.chat-user')).backgroundColor);return(Math.max(a,b)+.05)/(Math.min(a,b)+.05);
    },theme);
    expect(contrast,`${theme} small user label`).toBeGreaterThanOrEqual(4.5);
  }
  await page.evaluate(()=>{document.documentElement.dataset.theme='dark';});
  await expect(page.locator('.markdown-content table')).toContainText('Recorded');
  await expect(page.locator('.code-block code')).toHaveText('export const greeting: string = "hello";');
  await expect(page.locator('.code-block .tok-keyword').first()).toBeVisible();
  await expect(page.locator('.markdown-content img,.markdown-content script,.markdown-content iframe')).toHaveCount(0);
  await expect(page.locator('.markdown-content a[href^="javascript:"]')).toHaveCount(0);
  await context.grantPermissions(['clipboard-read','clipboard-write']);
  await page.getByRole('button',{name:'Copy code',exact:true}).click();
  expect(await page.evaluate(()=>navigator.clipboard.readText())).toBe('export const greeting: string = "hello";');
  await page.getByRole('textbox',{name:'Message Antigravity',exact:true}).fill('Unsent draft\nSecond line');
  await expect(page.getByRole('button',{name:'Send message',exact:true})).toBeDisabled();
  await page.locator('#chat-history').evaluate(element=>{element.scrollTop=0;});
  await openConversationMenu(page);await page.getByRole('button',{name:'Reconnect / refresh',exact:true}).click();
  await expect(page.locator('#chat-refresh')).toBeEnabled();
  expect(await page.locator('#chat-history').evaluate(element=>element.scrollTop)).toBe(0);
  for(const viewport of [{width:390,height:460},{width:780,height:360},{width:320,height:640}]){
    await page.setViewportSize(viewport);
    await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
    const boxes=await page.evaluate(()=>({input:document.querySelector('.chat-input-shell').getBoundingClientRect().toJSON(),nav:document.querySelector('#navigation').getBoundingClientRect().toJSON(),timeline:document.querySelector('#chat-history').getBoundingClientRect().toJSON(),height:innerHeight,overflow:document.documentElement.scrollWidth>innerWidth}));
    expect(boxes.input.bottom).toBeLessThanOrEqual(boxes.nav.top);expect(boxes.nav.bottom).toBeLessThanOrEqual(boxes.height+1);expect(boxes.timeline.bottom,JSON.stringify({viewport,boxes})).toBeLessThanOrEqual(boxes.input.top);expect(boxes.overflow).toBe(false);
  }
  await context.setOffline(true);
  await expect(page.locator('#chat-mobile-status')).toHaveText('Browser offline');
  await expect(page.locator('#chat-send-help')).toContainText('Draft not sent');
  await expect(page.locator('#chat-input')).toHaveValue('Unsent draft\nSecond line');
  await context.setOffline(false);
  await expect(page.locator('#chat-connection')).toHaveText('Laptop online');
  await page.locator('#chat-input').fill('');
  await page.setViewportSize(info.project.name==='phone'?{width:393,height:851}:{width:1440,height:1000});
  await page.screenshot({path:`.local/mobile-preview/${info.project.name}-chat-first.png`});
  expect(errors).toEqual([]);expect(tracking).toEqual([]);
});

test('drawer searches message content and preserves drafts while switching, renaming and archiving conversations',async({page},info)=>{
  await login(page);await chooseFixtureChat(page);
  const projectId=await page.locator('#chat-project').inputValue();
  const repos=await(await page.request.get('/api/repositories')).json();
  const created=[];
  for(const title of [`Draft A ${info.project.name}`,`Draft B ${info.project.name}`])created.push(await(await page.request.post(`/api/projects/${projectId}/conversations`,{headers:{origin:'http://localhost:4173'},data:{repositoryId:repos.repositories[0].id,title}})).json());
  await page.locator('#chat-input').fill('Fixture draft survives switching');
  if(await page.locator('#conversation-drawer').getAttribute('open')===null)await page.getByRole('button',{name:'Open conversations',exact:true}).click();
  await page.getByLabel('Search conversations',{exact:true}).fill('violet-never-present');
  await expect(page.locator('#conversation-list')).toContainText('No matching');
  await page.getByLabel('Search conversations',{exact:true}).fill('Browser fixture question');
  await expect(page.locator('#conversation-list .conversation-item')).toHaveCount(1);
  await page.getByLabel('Search conversations',{exact:true}).fill('Draft A');
  await page.locator(`[data-conversation-id="${created[0].id}"]`).click();
  await page.locator('#chat-input').fill('A separate draft');
  if(await page.locator('#conversation-drawer').getAttribute('open')===null)await page.getByRole('button',{name:'Open conversations',exact:true}).click();
  await page.getByLabel('Search conversations',{exact:true}).fill('Draft B');
  await page.locator(`[data-conversation-id="${created[1].id}"]`).click();
  await expect(page.locator('#chat-input')).toHaveValue('');
  await openConversationMenu(page);await page.getByRole('button',{name:'Rename conversation',exact:true}).click();
  await page.getByLabel('Conversation name',{exact:true}).fill(`Renamed draft ${info.project.name}`);
  await page.getByRole('button',{name:'Save name',exact:true}).click();
  await expect(page.locator('#chat-heading')).toHaveText(`Renamed draft ${info.project.name}`);
  let replayStarted, releaseReplay;
  const replaySeen=new Promise(resolve=>{replayStarted=resolve;}), replayGate=new Promise(resolve=>{releaseReplay=resolve;});
  const replayPattern=`**/api/conversations/${created[1].id}/events?*`;
  const delayedReplay=async route=>{replayStarted();await replayGate;await route.continue();};
  await page.route(replayPattern,delayedReplay);
  try {
    await replaySeen;
    await openConversationMenu(page);
    await expect(page.getByRole('button',{name:'Archive conversation',exact:true})).toBeEnabled();
    page.once('dialog',dialog=>dialog.accept());await page.getByRole('button',{name:'Archive conversation',exact:true}).click();
    await expect(page.locator('#chat-send-help')).toContainText('Archived conversation');
  } finally { releaseReplay();await page.unrouteAll({behavior:'wait'}); }
  if(await page.locator('#conversation-drawer').getAttribute('open')===null)await page.getByRole('button',{name:'Open conversations',exact:true}).click();
  await page.getByLabel('Search conversations',{exact:true}).fill('Renamed draft');
  await expect(page.locator(`[data-conversation-id="${created[1].id}"]`)).toHaveCount(0);
  await page.getByLabel('Include archived',{exact:true}).check();
  await page.locator(`[data-conversation-id="${created[1].id}"]`).click();
  await openConversationMenu(page);await page.getByRole('button',{name:'Restore conversation',exact:true}).click();
  if(await page.locator('#conversation-drawer').getAttribute('open')===null)await page.getByRole('button',{name:'Open conversations',exact:true}).click();
  await page.getByLabel('Search conversations',{exact:true}).fill('Draft A');await page.locator(`[data-conversation-id="${created[0].id}"]`).click();
  await expect(page.locator('#chat-input')).toHaveValue('A separate draft');await page.locator('#chat-input').fill('');
});

test('Home launches projects, restores the last conversation, searches actual content and uses the saved profile',async({page},info)=>{
  const errors=[];page.on('pageerror',error=>errors.push(error.message));
  await login(page);await page.getByRole('link',{name:'Jess Ide Dev Home',exact:true}).click();
  await expect(page.locator('#page-home')).toBeVisible();await expect(page.locator('#navigation')).toBeHidden();
  await expect(page.locator('#home-welcome')).toHaveText('Welcome back, Browser Tester 👋');
  await expect(page.locator('#home-projects')).toContainText('Chat fixture project');
  await expect(page.locator('#home-availability')).toContainText('remote messaging unavailable');
  await page.getByRole('button',{name:'Create new project',exact:false}).click();
  const name=`Home launch ${info.project.name}`;await page.getByLabel('Project name',{exact:true}).fill(name);
  await page.getByRole('button',{name:'Create and open project',exact:false}).click();
  await expect(page.locator('#page-chat')).toBeVisible();await expect(page.locator('#chat-project-name')).toHaveText(name);
  await expect(page.locator('#chat-history')).toContainText('Choose a conversation or start a new one.');
  await chooseFixtureChat(page);
  await expect(page.locator('.app-header .home-shortcut')).toHaveCount(0);
  await page.locator('#navigation').getByRole('link',{name:'Home',exact:true}).click();
  await expect(page.locator('#page-home')).toBeVisible();
  await expect(page.locator('#home-recent')).toContainText('Chat test fixture');
  await page.locator('#home-recent').getByRole('button').click();await expect(page.locator('#chat-heading')).toHaveText('Chat test fixture');
  await page.getByRole('link',{name:'Jess Ide Dev Home',exact:true}).click();
  await page.getByLabel('Project view',{exact:true}).selectOption('list');await expect(page.locator('#home-projects')).toHaveAttribute('data-layout','list');
  await page.getByLabel('Sort projects',{exact:true}).selectOption('name');
  await page.keyboard.press('ControlOrMeta+k');await expect(page.locator('#global-search-dialog')).toBeVisible();
  await page.getByRole('searchbox',{name:'Search projects, repositories and conversations',exact:true}).fill('Browser fixture question');
  await expect(page.locator('#global-search-results')).toContainText('Chat test fixture');
  await page.locator('#global-search-results').getByRole('button').click();await expect(page.locator('#chat-heading')).toHaveText('Chat test fixture');
  await page.getByRole('link',{name:'Jess Ide Dev Home',exact:true}).click();
  await page.getByRole('link',{name:'Settings',exact:true}).click();await page.getByLabel('Display name',{exact:true}).fill('Avery');
  await page.getByRole('button',{name:'Save profile',exact:true}).click();await expect(page.locator('#profile-status')).toHaveText('Profile saved.');
  await page.getByRole('link',{name:'Jess Ide Dev Home',exact:true}).click();await expect(page.locator('#home-welcome')).toHaveText('Welcome back, Avery 👋');
  await page.reload();await expect(page.locator('#home-welcome')).toHaveText('Welcome back, Avery 👋');await expect(page.locator('#navigation')).toBeHidden();
  await page.setViewportSize(info.project.name==='phone'?{width:320,height:700}:{width:1440,height:1000});
  expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);
  await page.screenshot({path:`.local/mobile-preview/${info.project.name}-project-home.png`,fullPage:true,animations:'disabled'});
  await page.request.put('/profile',{headers:{origin:'http://localhost:4173'},data:{displayName:'Browser Tester'}});
  await page.context().clearCookies();await page.getByRole('button',{name:'Refresh projects',exact:true}).click();await expect(page.locator('#login')).toBeVisible();
  await expect(page.locator('#home-projects')).not.toContainText('Chat fixture project');await expect(page.locator('#home-welcome')).not.toContainText('Avery');expect(errors).toEqual([]);
});

test('Home preserves a created project after repository attachment fails and blocks duplicate creation',async({page},info)=>{
  await login(page);await page.getByRole('link',{name:'Jess Ide Dev Home',exact:true}).click();
  await page.getByRole('button',{name:'Create new project',exact:false}).click();
  await expect(page.locator('#home-create-repository option')).toHaveCount(2);
  await page.getByLabel('Project name',{exact:true}).fill(`Partial creation ${info.project.name}`);
  await page.getByLabel('Repository (optional)',{exact:true}).selectOption({index:1});
  let submissions=0;page.on('request',request=>{if(request.method()==='POST'&&new URL(request.url()).pathname==='/api/projects')submissions++;});
  await page.route('**/api/projects/*/conversations',route=>route.request().method()==='POST'?route.fulfill({status:503,contentType:'application/json',body:'{"error":"TEST_ATTACHMENT_UNAVAILABLE"}'}):route.continue());
  await page.getByRole('button',{name:'Create and open project',exact:false}).click();
  await expect(page.locator('#home-create-message')).toContainText('Project created, but the next step failed.');
  await expect(page.locator('#home-create-submit')).toBeDisabled();
  await page.locator('#home-create-form').evaluate(form=>form.requestSubmit());expect(submissions).toBe(1);
  await page.getByRole('button',{name:'Close create project',exact:true}).click();
  await expect(page.locator('#home-projects')).toContainText(`Partial creation ${info.project.name}`);
  const projects=await(await page.request.get('/api/workspace/home')).json();expect(projects.projects.filter(p=>p.name===`Partial creation ${info.project.name}`)).toHaveLength(1);
});
