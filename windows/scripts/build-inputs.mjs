import { createHash } from 'node:crypto';
import { readdir, readFile, mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const excluded = new Set(['node_modules', 'target', 'dist', 'gen', 'test-results', 'playwright-report', '.runtime', '__pycache__']);
const files = [];
const hash = data => createHash('sha256').update(data).digest('hex');
async function visit(folder) {
  for (const entry of await readdir(folder, { withFileTypes: true })) {
    if (excluded.has(entry.name)) continue;
    const file = path.join(folder, entry.name);
    if (entry.isDirectory()) await visit(file);
    else if (entry.isFile()) files.push({ path: path.relative(root, file).replaceAll(path.sep, '/'), sha256: hash(await readFile(file)) });
  }
}
await visit(root);
files.push({ path: '../LICENSE', sha256: hash(await readFile(path.join(root, '../LICENSE'))) });
files.sort((a, b) => a.path.localeCompare(b.path, 'en'));
const { version } = JSON.parse(await readFile(path.join(root, 'package.json'), 'utf8'));
const output = path.resolve(root, '../.build/windows-build-inputs', `${version}.json`);
await mkdir(path.dirname(output), { recursive: true });
await writeFile(output, JSON.stringify({ version, capturedAt: new Date().toISOString(), digest: hash(JSON.stringify(files)), files }, null, 2) + '\n');
console.log(`构建输入已记录：${files.length} 个文件`);
