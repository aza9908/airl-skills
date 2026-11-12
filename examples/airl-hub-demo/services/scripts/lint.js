'use strict';
// Лёгкий линтер без зависимостей: синтаксис каждого .js и правила проекта.
//  - нет eval / new Function;
//  - нет атрибутов style="…" и обработчиков on…="…" в разметке (CSP без 'unsafe-inline');
//  - токены и пароли не печатаются в лог.
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..');
const files = [];
(function walk(d) {
  for (const e of fs.readdirSync(d, { withFileTypes: true })) {
    if (e.name === 'node_modules') continue;
    const p = path.join(d, e.name);
    if (e.isDirectory()) walk(p); else if (/\.(js|html)$/.test(e.name)) files.push(p);
  }
})(ROOT);

const problems = [];
for (const f of files) {
  const rel = path.relative(ROOT, f);
  const src = fs.readFileSync(f, 'utf8');
  if (f.endsWith('.js')) {
    try { execFileSync(process.execPath, ['--check', f], { stdio: 'pipe' }); } catch (e) { problems.push(`${rel}: синтаксис: ${String(e.stderr).split('\n')[4] || ''}`); }
  }
  src.split('\n').forEach((line, i) => {
    const at = `${rel}:${i + 1}`;
    if (/\beval\s*\(|new Function\s*\(/.test(line)) problems.push(`${at}: eval/new Function`);
    if (/\sstyle="/.test(line) && !rel.endsWith('lint.js')) problems.push(`${at}: атрибут style="…" (CSP)`);
    if (/\son(click|change|load|submit|error)="/i.test(line)) problems.push(`${at}: обработчик в разметке (CSP)`);
    // печать значения переменной с секретом: ${token}, , password) и т. п. (текст «пароль» в сообщении — можно)
    if (/console\.(log|error)\(.*(\$\{[^}]*(token|password|pw|secret)[^}]*\}|,\s*(token|password|pw|secret)\b)/i.test(line)) problems.push(`${at}: секрет в логе?`);
  });
}
if (problems.length) { console.error(problems.join('\n')); console.error(`\nЗамечаний: ${problems.length}`); process.exit(1); }
console.log(`Линтер: ${files.length} файлов, замечаний нет`);
