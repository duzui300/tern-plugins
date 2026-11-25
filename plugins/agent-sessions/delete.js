#!/usr/bin/env node
'use strict';
const fs = require('fs');
const path = require('path');
const os = require('os');

const args = process.argv.slice(2);
function arg(name, def) {
  const i = args.indexOf('--' + name);
  return i >= 0 ? args[i + 1] : def;
}

const agent = arg('agent', '');
const id = arg('id', '');
const file = arg('path', '');
const errors = [];
const warnings = [];
const home = process.env.USERPROFILE || process.env.HOME || os.homedir();
const SAFE_ID = /^[A-Za-z0-9._-]+$/;

function output() {
  process.stdout.write(JSON.stringify({ ok: errors.length === 0, errors, warnings }));
}
function fail(message) {
  errors.push(message);
  output();
  process.exit(0);
}
function rm(x) {
  if (!x) return;
  try { fs.rmSync(x, { recursive: true, force: true }); }
  catch (e) { errors.push(x + ': ' + e.message); }
}
function within(base, p) {
  const rel = path.relative(base, p);
  return rel !== '' && !rel.startsWith('..') && !path.isAbsolute(rel);
}
function carlySessionsDir() {
  const candidates = [];
  if (process.env.TERN_BLOB_DIR) candidates.push(path.join(path.dirname(process.env.TERN_BLOB_DIR), 'carly', 'main', 'sessions'));
  if (process.env.LOCALAPPDATA) candidates.push(path.join(process.env.LOCALAPPDATA, 'Tern', 'carly', 'main', 'sessions'));
  if (process.platform === 'darwin') candidates.push(path.join(home, 'Library', 'Application Support', 'Tern', 'carly', 'main', 'sessions'));
  candidates.push(path.join(process.env.XDG_DATA_HOME || path.join(home, '.local', 'share'), 'Tern', 'carly', 'main', 'sessions'));
  for (const d of candidates) { try { if (fs.statSync(d).isDirectory()) return d; } catch {} }
  return '';
}

if (!id || !file) fail('missing id or path');
if (!SAFE_ID.test(id) || id === '.' || id === '..') fail('invalid session id');
if (!path.isAbsolute(file)) fail('session path is not absolute');

if (agent === 'claude') {
  const root = path.join(home, '.claude', 'projects');
  if (!within(root, file) || !/\.jsonl$/i.test(file)) fail('session path is outside the Claude store');
  rm(file);
  rm(file.replace(/\.jsonl$/i, ''));
} else if (agent === 'pi') {
  const root = path.join(home, '.pi', 'agent', 'sessions');
  if (!within(root, file) || !/\.jsonl$/i.test(file)) fail('session path is outside the Pi store');
  rm(file);
} else if (agent === 'carly') {
  const root = carlySessionsDir();
  if (!root || !within(root, file) || !/\.jsonl$/i.test(file)) fail('session path is outside the Carly store');
  rm(file);
  rm(file.replace(/\.jsonl$/i, ''));
} else if (agent === 'omp') {
  const root = path.join(home, '.omp', 'agent', 'sessions');
  if (!within(root, file) || !/\.jsonl$/i.test(file)) fail('session path is outside the omp store');
  rm(file);
  rm(file.replace(/\.jsonl$/i, ''));
} else if (agent === 'antigravity') {
  const roots = [path.join(home, '.gemini', 'antigravity'), path.join(home, '.gemini', 'antigravity-cli')];
  let matched = null;
  for (const root of roots) {
    if (within(path.join(root, 'brain'), file)) { matched = root; break; }
  }
  if (!matched) fail('session path is outside the Antigravity store');
  rm(file);
  rm(path.join(matched, 'conversations', id + '.db'));
  for (const root of roots) {
    const dbp = path.join(root, 'conversation_summaries.db');
    if (!fs.existsSync(dbp)) continue;
    try {
      const { DatabaseSync } = require('node:sqlite');
      const db = new DatabaseSync(dbp);
      db.exec('pragma busy_timeout = 3000');
      db.prepare('delete from conversation_summaries where conversation_id = ?').run(id);
      db.close();
    } catch (e) {
      warnings.push(dbp + ': ' + e.message);
    }
  }
} else {
  errors.push('unknown agent ' + agent);
}

output();
