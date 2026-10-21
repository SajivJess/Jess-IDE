import { build } from 'esbuild';
import { readFile, readdir, writeFile } from 'node:fs/promises';
const result = await build({ entryPoints: { editor: 'remote/editor-source.js', markdown: 'remote/markdown-source.js' }, outdir: 'dist/remote', bundle: true, format: 'esm', target: 'es2022', minify: true, legalComments: 'eof', metafile: true });
const packages = new Set(Object.keys(result.metafile.inputs).filter(path => path.startsWith('node_modules/')).map(path => {
  const parts = path.split('/'); return parts[1].startsWith('@') ? parts.slice(1, 3).join('/') : parts[1];
}));
const notices = [];
for (const name of [...packages].sort()) {
  const root = `node_modules/${name}`;
  const metadata = JSON.parse(await readFile(`${root}/package.json`, 'utf8'));
  const license = (await readdir(root)).find(file => /^licen[sc]e(?:\.md|\.txt)?$/i.test(file));
  if (!license) throw new Error(`Missing license notice for bundled dependency: ${name}`);
  notices.push(`${name} ${metadata.version} (${metadata.license})\n\n${await readFile(`${root}/${license}`, 'utf8')}`);
}
await writeFile('dist/remote/editor-licenses.txt', notices.join('\n\n--------------------\n\n'));
