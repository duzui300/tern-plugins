#!/usr/bin/env node
'use strict';
const fs = require('fs');
const path = require('path');

const args = process.argv.slice(2);
function arg(name, def) {
  const i = args.indexOf('--' + name);
  return i >= 0 ? args[i + 1] : def;
}

const agent = arg('agent', '');
const file = arg('path', '');
const MAX_MESSAGE_BYTES = 8000;
const MAX_TOTAL_BYTES = 160000;
const out = [];
let role = null;
let buf = [];

function byteLen(text) {
  return Buffer.byteLength(text, 'utf8');
}
function cutUtf8(text, max) {
  const bytes = Buffer.from(text, 'utf8');
  if (bytes.length <= max) return text;
  let end = max;
  while (end > 0 && (bytes[end] & 0xC0) === 0x80) end--;
  return bytes.toString('utf8', 0, end);
}

function flush() {
  if (!buf.length) return;
  out.push('### ' + role + '\n\n' + buf.join('\n\n') + '\n');
  buf = [];
}
function add(r, text) {
  let t = String(text || '').replace(/\r/g, '').trim();
  if (!t) return;
  if (byteLen(t) > MAX_MESSAGE_BYTES) t = cutUtf8(t, MAX_MESSAGE_BYTES) + '\n\n… (truncated)';
  if (r !== role) { flush(); role = r; }
  buf.push(t);
}
function headText(p, max) {
  let fd;
  try {
    fd = fs.openSync(p, 'r');
    const b = Buffer.alloc(max);
    const n = fs.readSync(fd, b, 0, b.length, 0);
    return b.toString('utf8', 0, n);
  } catch { return ''; }
  finally { if (fd !== undefined) try { fs.closeSync(fd); } catch {} }
}
function lines(p) { try { return fs.readFileSync(p, 'utf8').split('\n'); } catch { return []; } }
function contentText(c, sep) {
  if (typeof c === 'string') return c;
  if (Array.isArray(c)) {
    return c.filter(x => x && x.type === 'text' && typeof x.text === 'string').map(x => x.text).join(sep || '\n\n');
  }
  if (c && typeof c === 'object' && typeof c.text === 'string') return c.text;
  return '';
}
function isMetaPrompt(t) {
  return /^(\/|Set effort level to|Caveat: The messages below were generated|Name this chat from the user's first request|This session is being continued|<command-|<local-command|\[Request interrupted)/i.test(t);
}

function claude() {
  for (const line of lines(file)) {
    if (!line) continue;
    let o; try { o = JSON.parse(line); } catch { continue; }
    if (o.isSidechain || o.isMeta) continue;
    if (o.type === 'user' && o.message) {
      const t = contentText(o.message.content, '\n\n').trim();
      if (t && !t.startsWith('<') && !isMetaPrompt(t)) add('You', t);
    } else if (o.type === 'assistant' && o.message) {
      add('Assistant', contentText(o.message.content, '\n\n'));
    }
  }
}

function pi() {
  for (const line of lines(file)) {
    if (!line) continue;
    let o; try { o = JSON.parse(line); } catch { continue; }
    if (o.type !== 'message' || !o.message) continue;
    const r = o.message.role;
    if (r !== 'user' && r !== 'assistant') continue;
    add(r === 'user' ? 'You' : 'Assistant', contentText(o.message.content, '\n\n'));
  }
}

function stripMeta(t) {
  return String(t || '')
    .replace(/<ADDITIONAL_METADATA>[\s\S]*?<\/ADDITIONAL_METADATA>/g, '')
    .replace(/<USER_SETTINGS_CHANGE>[\s\S]*?<\/USER_SETTINGS_CHANGE>/g, '')
    .replace(/<\/?USER_REQUEST>/g, '')
    .trim();
}

function agy() {
  let files = [];
  const single = path.join(file, '.system_generated', 'logs', 'transcript_full.jsonl');
  if (fs.existsSync(single)) {
    files = [single];
  } else {
    const dir = path.join(file, '.system_generated', 'logs', 'chunks', 'transcript_full');
    try {
      files = fs.readdirSync(dir).filter(f => f.endsWith('.jsonl')).sort().map(f => path.join(dir, f));
    } catch { files = []; }
  }
  for (const f of files) {
    for (const line of headText(f, 8 * 1024 * 1024).split('\n')) {
      if (!line) continue;
      let o; try { o = JSON.parse(line); } catch { continue; }
      if (o.type === 'USER_INPUT') add('You', stripMeta(o.content));
      else if (o.type === 'PLANNER_RESPONSE') add('Assistant', contentText(o.content, '\n\n'));
    }
  }
}

function carlyContext(t) {
  return String(t || '').replace(/<context>[\s\S]*?<\/context>/g, '').trim();
}

function carly() {
  for (const line of lines(file)) {
    if (!line) continue;
    let o; try { o = JSON.parse(line); } catch { continue; }
    if (o.type !== 'message' || !o.message) continue;
    const r = o.message.role;
    if (r !== 'user' && r !== 'assistant') continue;
    let t = contentText(o.message.content, '\n\n');
    if (r === 'user') t = carlyContext(t);
    add(r === 'user' ? 'You' : 'Assistant', t);
  }
}

try {
  if (agent === 'claude') claude();
  else if (agent === 'pi' || agent === 'omp') pi();
  else if (agent === 'antigravity') agy();
  else if (agent === 'carly') carly();
  flush();
  if (!out.length) out.push('_No messages found._');
  let text = out.join('\n\n');
  if (byteLen(text) > MAX_TOTAL_BYTES) {
    text = cutUtf8(text, MAX_TOTAL_BYTES) + '\n\n… (transcript truncated; use Copy path to read the rest)';
  }
  process.stdout.write(text);
} catch (e) {
  process.stderr.write(String((e && e.stack) || e));
  process.exit(1);
}
