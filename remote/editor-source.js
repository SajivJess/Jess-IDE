import { basicSetup, EditorView } from 'codemirror';
import { EditorState } from '@codemirror/state';
import { openSearchPanel } from '@codemirror/search';
import { undo, redo } from '@codemirror/commands';
import { HighlightStyle, syntaxHighlighting } from '@codemirror/language';
import { tags } from '@lezer/highlight';
import { javascript } from '@codemirror/lang-javascript';
import { json } from '@codemirror/lang-json';
import { html } from '@codemirror/lang-html';
import { css } from '@codemirror/lang-css';
import { markdown } from '@codemirror/lang-markdown';

export function createEditor(parent, path, content, onChange) {
  const language = /\.[cm]?[jt]sx?$/.test(path) ? javascript({ typescript: /\.tsx?$/.test(path), jsx: /[jt]sx$/.test(path) }) : /\.json$/.test(path) ? json() : /\.html?$/.test(path) ? html() : /\.css$/.test(path) ? css() : /\.md$/.test(path) ? markdown() : [];
  const colors = HighlightStyle.define([
    { tag: [tags.keyword, tags.operator, tags.typeName], color: 'var(--accent)' },
    { tag: [tags.string, tags.regexp], color: 'var(--success)' },
    { tag: [tags.number, tags.bool, tags.null], color: 'var(--warning)' },
    { tag: [tags.comment, tags.meta], color: 'var(--muted)' },
  ]);
  const view = new EditorView({ parent, state: EditorState.create({ doc: content, extensions: [
    basicSetup, language, syntaxHighlighting(colors), EditorView.lineWrapping,
    EditorView.cspNonce.of(document.querySelector('meta[name="jess-style-nonce"]')?.content ?? ''),
    EditorView.contentAttributes.of({ 'aria-label': 'File content', spellcheck: 'false' }),
    // Replacing highlighted selections through native contenteditable can make
    // Chromium copy a token's inline color. Apply plain text via the document
    // model instead; leave composition and non-cancelable mobile input to CM.
    EditorView.domEventHandlers({ beforeinput(event, view) {
      if (event.cancelable && !event.isComposing && !view.composing && event.inputType === 'insertText' && event.data !== null && !view.state.selection.main.empty) {
        event.preventDefault(); view.dispatch(view.state.replaceSelection(event.data), { scrollIntoView: true, userEvent: 'input.type' }); return true;
      }
      return false;
    } }),
    EditorView.theme({ '&': { backgroundColor: 'var(--bg)', color: 'var(--ink)', fontSize: '13px' }, '.cm-content': { fontFamily: 'ui-monospace, Consolas, monospace', minHeight: '260px' }, '.cm-scroller': { overflow: 'auto', maxHeight: '60vh' }, '.cm-gutters': { backgroundColor: 'var(--panel)', color: 'var(--muted)', borderColor: 'var(--line)' }, '.cm-activeLine,.cm-activeLineGutter': { backgroundColor: 'var(--tint)' }, '.cm-cursor': { borderLeftColor: 'var(--ink)' }, '&.cm-focused .cm-selectionBackground, .cm-selectionBackground': { backgroundColor: 'var(--selection)' }, '.cm-panels': { backgroundColor: 'var(--panel)', color: 'var(--ink)' } }),
    EditorView.updateListener.of(update => { if (update.docChanged) onChange(view.state.doc.toString()); }),
  ] }) });
  return { get value() { return view.state.doc.toString(); }, find: () => openSearchPanel(view), undo: () => undo(view), redo: () => redo(view), destroy: () => view.destroy(), focus: () => view.focus() };
}
