import { marked } from 'marked';
import { highlightTree, classHighlighter } from '@lezer/highlight';
import { javascript } from '@codemirror/lang-javascript';
import { json } from '@codemirror/lang-json';
import { css } from '@codemirror/lang-css';
import { html } from '@codemirror/lang-html';

// Build a closed set of DOM nodes from tokens. Agent text never becomes HTML,
// event handlers, image requests, style attributes or arbitrary navigation.
export function renderMarkdown(doc, source, copy) {
  const create = (tag, text) => { const n = doc.createElement(tag); if (text !== undefined) n.textContent = text; return n; };
  const fragment = doc.createDocumentFragment(); let budget = 15000;
  function inline(parent, tokens, depth = 0) {
    if (depth > 24) { parent.append(doc.createTextNode(tokens.map(t => t.raw ?? t.text ?? '').join(''))); return; }
    for (const t of tokens) {
      if (--budget < 0) throw new Error('Markdown complexity limit');
      if (['strong', 'em', 'del'].includes(t.type)) { const n = create(t.type); inline(n, t.tokens ?? [], depth + 1); parent.append(n); }
      else if (t.type === 'codespan') parent.append(create('code', t.text));
      else if (t.type === 'br') parent.append(create('br'));
      else if (t.type === 'link') {
        let valid = false; try { const url = new URL(t.href); valid = ['https:', 'http:'].includes(url.protocol) && !url.username && !url.password; } catch { /* Relative links have no verified workspace binding. */ }
        const n = create(valid ? 'a' : 'span'); if (valid) { n.href = t.href; n.target = '_blank'; n.rel = 'noopener noreferrer'; } inline(n, t.tokens ?? [{ type: 'text', text: t.text }], depth + 1); parent.append(n);
      } else if (t.type === 'image') parent.append(create('span', `[Image: ${t.text || 'reference'}]`));
      else if (t.tokens && t.type !== 'html') inline(parent, t.tokens, depth + 1);
      else parent.append(doc.createTextNode(t.text ?? t.raw ?? ''));
    }
  }
  function code(parent, t) {
    const language = String(t.lang ?? '').split(/\s/)[0].toLowerCase(); const wrapper = create('div'); wrapper.className = 'code-block';
    const header = create('div'); header.className = 'code-toolbar'; const button = create('button', 'Copy'); button.type = 'button'; button.setAttribute('aria-label', 'Copy code'); button.onclick = () => copy(t.text, button); header.append(create('span', language || 'code'), button);
    const pre = create('pre'); pre.tabIndex = 0; pre.setAttribute('aria-label', `${language || 'Plain text'} code`); const content = create('code');
    const parser = ['js', 'javascript', 'ts', 'typescript', 'tsx', 'jsx'].includes(language) ? javascript({ typescript: ['ts', 'typescript', 'tsx'].includes(language), jsx: ['tsx', 'jsx'].includes(language) }).language.parser : language === 'json' ? json().language.parser : language === 'css' ? css().language.parser : ['html', 'xml'].includes(language) ? html().language.parser : null;
    if (parser && t.text.length <= 20000) {
      let cursor = 0;
      highlightTree(parser.parse(t.text), classHighlighter, (from, to, classes) => { if (from > cursor) content.append(doc.createTextNode(t.text.slice(cursor, from))); const span = create('span', t.text.slice(from, to)); span.className = classes; content.append(span); cursor = to; });
      content.append(doc.createTextNode(t.text.slice(cursor)));
    } else content.textContent = t.text;
    pre.append(content); wrapper.append(header, pre); parent.append(wrapper);
  }
  function blocks(parent, tokens, depth = 0) {
    if (depth > 24) { parent.append(create('pre', tokens.map(t => t.raw ?? '').join(''))); return; }
    for (const t of tokens) {
      if (--budget < 0) throw new Error('Markdown complexity limit');
      if (t.type === 'space' || t.type === 'def') continue;
      if (t.type === 'code') code(parent, t);
      else if (t.type === 'heading' || t.type === 'paragraph' || t.type === 'text') { const n = create(t.type === 'heading' ? `h${Math.min(6, Math.max(2, t.depth + 1))}` : 'p'); inline(n, t.tokens ?? [{ type: 'text', text: t.text }]); parent.append(n); }
      else if (t.type === 'hr') parent.append(create('hr'));
      else if (t.type === 'blockquote') { const n = create('blockquote'); blocks(n, t.tokens, depth + 1); parent.append(n); }
      else if (t.type === 'list') {
        const list = create(t.ordered ? 'ol' : 'ul'); if (t.ordered && t.start) list.start = t.start;
        for (const item of t.items) { const li = create('li'); if (item.task) li.append(create('span', item.checked ? '☑ ' : '☐ ')); blocks(li, item.tokens, depth + 1); list.append(li); } parent.append(list);
      } else if (t.type === 'table') {
        const wrapper = create('div'); wrapper.className = 'markdown-table'; wrapper.tabIndex = 0; wrapper.setAttribute('aria-label', 'Response table'); const table = create('table'); const head = create('thead'); const header = create('tr');
        for (const cell of t.header) { const th = create('th'); th.scope = 'col'; inline(th, cell.tokens); header.append(th); } head.append(header); table.append(head); const body = create('tbody');
        for (const row of t.rows) { const tr = create('tr'); for (const cell of row) { const td = create('td'); inline(td, cell.tokens); tr.append(td); } body.append(tr); } table.append(body); wrapper.append(table); parent.append(wrapper);
      } else parent.append(create('p', t.text ?? t.raw ?? ''));
    }
  }
  try { blocks(fragment, marked.lexer(source, { gfm: true, breaks: false })); }
  catch { fragment.replaceChildren(create('p', source)); }
  return fragment;
}
