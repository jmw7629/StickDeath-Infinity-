#!/usr/bin/env node
// Validates website/help/articles.json against the repository and regenerates
// website/help/help-data.js (the embedded copy that lets the help center work
// from file:// without fetch). Node only, no dependencies.
//
//   node scripts/website/check_help.mjs          # validate and (re)write help-data.js
//   node scripts/website/check_help.mjs --check  # validate; fail if help-data.js is stale
//   node scripts/website/check_help.mjs --sync-guide-revision
//       # when the Swift guide revision was bumped: rewrite every guideRevision in
//       # articles.json to the value in SpatterAIViewModel.swift, then validate and
//       # regenerate help-data.js. The reviewed dates are NOT touched: a revision
//       # bump is not a content review, so re-read the articles before committing.
//
// Rules enforced:
//   * every article has non-empty `sources` and an ISO `reviewed` date (not in the future)
//   * every `guideRevision` equals `currentGuideVersion` in SpatterAIViewModel.swift
//   * every curly-quoted UI label (“…”) in steps/limits exists verbatim in a Swift or Kotlin source
//   * every `sources` path exists in the repository
//   * ids are unique and lowercase, categories/statuses come from fixed sets

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '..', '..');
const articlesPath = path.join(repo, 'website', 'help', 'articles.json');
const dataPath = path.join(repo, 'website', 'help', 'help-data.js');
const guidePath = path.join(repo, 'StickDeathInfinity', 'ViewModels', 'SpatterAIViewModel.swift');
const checkOnly = process.argv.includes('--check');
const syncGuide = process.argv.includes('--sync-guide-revision');
if (checkOnly && syncGuide) { console.error('check_help: --check and --sync-guide-revision are exclusive'); process.exit(1); }

const CATEGORIES = new Set(['create', 'animate', 'keep', 'account']);
const STATUSES = new Set(['source-implemented', 'verified-on-device', 'unavailable']);
const errors = [];
const fail = (message) => errors.push(message);

function walk(dir, extensions, out = []) {
  if (!fs.existsSync(dir)) return out;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name.startsWith('.') || entry.name === 'build' || entry.name === 'node_modules') continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full, extensions, out);
    else if (extensions.has(path.extname(entry.name))) out.push(full);
  }
  return out;
}

let doc;
try {
  doc = JSON.parse(fs.readFileSync(articlesPath, 'utf8'));
} catch (error) {
  console.error(`articles.json unreadable: ${error.message}`);
  process.exit(1);
}

const guideSource = fs.readFileSync(guidePath, 'utf8');
const guideMatch = guideSource.match(/static let currentGuideVersion = "([^"]+)"/);
if (!guideMatch) fail(`currentGuideVersion not found in ${path.relative(repo, guidePath)}`);
const currentGuideVersion = guideMatch ? guideMatch[1] : null;

if (syncGuide && currentGuideVersion) {
  const stale = [doc, ...(Array.isArray(doc.articles) ? doc.articles : [])].filter((entry) => entry.guideRevision !== currentGuideVersion);
  if (stale.length) {
    for (const entry of stale) entry.guideRevision = currentGuideVersion;
    fs.writeFileSync(articlesPath, JSON.stringify(doc, null, 2) + '\n');
    console.log(`check_help: guideRevision synced to ${currentGuideVersion} on ${stale.length} entr${stale.length === 1 ? 'y' : 'ies'} (reviewed dates unchanged; re-read the articles)`);
  }
}
if (doc.schemaVersion !== 1) fail('schemaVersion must be 1');
if (doc.guideRevision !== currentGuideVersion) fail(`top-level guideRevision ${doc.guideRevision} != ${currentGuideVersion}`);
if (!Array.isArray(doc.articles) || !doc.articles.length) fail('articles must be a non-empty array');

const swiftFiles = walk(path.join(repo, 'StickDeathInfinity'), new Set(['.swift']));
const kotlinFiles = walk(path.join(repo, 'android'), new Set(['.kt']));
const corpus = [...swiftFiles, ...kotlinFiles].map((file) => fs.readFileSync(file, 'utf8')).join('\n');
if (!swiftFiles.length) fail('no Swift sources found');
if (!kotlinFiles.length) fail('no Kotlin sources found');

const today = new Date().toISOString().slice(0, 10);
const ids = new Set();
const labelsChecked = new Set();
const sourcesChecked = new Set();
const labelPattern = /“([^”]+)”/g;

for (const article of doc.articles || []) {
  const where = `article ${article.id ?? '<missing id>'}`;
  if (typeof article.id !== 'string' || !/^[a-z0-9-]+$/.test(article.id)) fail(`${where}: id must be lowercase letters, digits and hyphens`);
  if (ids.has(article.id)) fail(`${where}: duplicate id`);
  ids.add(article.id);
  if (!CATEGORIES.has(article.category)) fail(`${where}: category must be one of ${[...CATEGORIES].join(', ')}`);
  if (!STATUSES.has(article.status)) fail(`${where}: status must be one of ${[...STATUSES].join(', ')}`);
  for (const field of ['platform', 'title']) {
    if (typeof article[field] !== 'string' || !article[field].trim()) fail(`${where}: ${field} must be a non-empty string`);
  }
  if (!Array.isArray(article.steps) || !article.steps.length || article.steps.some((s) => typeof s !== 'string' || !s.trim())) fail(`${where}: steps must be a non-empty array of strings`);
  if (!Array.isArray(article.limits) || article.limits.some((s) => typeof s !== 'string')) fail(`${where}: limits must be an array of strings`);
  if (article.keywords !== undefined && (!Array.isArray(article.keywords) || article.keywords.some((s) => typeof s !== 'string'))) fail(`${where}: keywords must be an array of strings`);
  if (!Array.isArray(article.sources) || !article.sources.length) fail(`${where}: sources must be a non-empty array`);
  if (article.guideRevision !== currentGuideVersion) fail(`${where}: guideRevision ${article.guideRevision} != ${currentGuideVersion}`);
  if (typeof article.reviewed !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(article.reviewed) || Number.isNaN(Date.parse(article.reviewed))) {
    fail(`${where}: reviewed must be an ISO date (YYYY-MM-DD)`);
  } else if (article.reviewed > today) {
    fail(`${where}: reviewed ${article.reviewed} is in the future`);
  }
  for (const source of article.sources || []) {
    if (typeof source !== 'string' || source.includes('..') || path.isAbsolute(source)) { fail(`${where}: invalid source path ${source}`); continue; }
    sourcesChecked.add(source);
    if (!fs.existsSync(path.join(repo, source))) fail(`${where}: source path does not exist: ${source}`);
  }
  for (const text of [...(article.steps || []), ...(article.limits || [])]) {
    if (typeof text !== 'string') continue;
    for (const match of text.matchAll(labelPattern)) {
      const label = match[1];
      labelsChecked.add(label);
      if (!corpus.includes(label)) fail(`${where}: quoted label not found verbatim in Swift/Kotlin sources: “${label}”`);
    }
  }
}

if (errors.length) {
  console.error(`check_help: ${errors.length} problem(s)`);
  for (const error of errors) console.error(`  - ${error}`);
  process.exit(1);
}

const generated = `/* Generated by scripts/website/check_help.mjs from website/help/articles.json. Do not edit by hand. */\nwindow.STUDIO_HELP_DATA = ${JSON.stringify(doc, null, 1)};\n`;
const existing = fs.existsSync(dataPath) ? fs.readFileSync(dataPath, 'utf8') : null;
const stale = existing !== generated;
if (checkOnly) {
  if (stale) {
    console.error('check_help: website/help/help-data.js is stale; run without --check to regenerate');
    process.exit(1);
  }
} else if (stale) {
  fs.writeFileSync(dataPath, generated);
}

console.log(`check_help: OK — ${doc.articles.length} articles, guide revision ${currentGuideVersion}, ${labelsChecked.size} distinct UI labels verified against ${swiftFiles.length} Swift and ${kotlinFiles.length} Kotlin files, ${sourcesChecked.size} source paths exist; help-data.js ${checkOnly ? 'in sync' : stale ? 'regenerated' : 'unchanged'}`);
