#!/usr/bin/env node
// Regenerate .xp-gate-req-ids from specification.yaml.
//
// The generator lives in the repo (not in the hook) so the id list has one
// source of truth: specification.yaml. `tests/unit/platform-hygiene.Tests.ps1`
// re-runs this logic and fails when the checked-in list drifts, so a
// specification edit that forgets to regenerate turns the suite red instead of
// silently widening (or narrowing) what annotations may reference.
//
// Usage: node .xp-gate-req-ids.cjs > .xp-gate-req-ids
'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = process.cwd();
const SPEC = path.join(ROOT, 'specification.yaml');
const HEADER = fs.readFileSync(path.join(ROOT, '.xp-gate-req-ids.header'), 'utf8').replace(/^\uFEFF/, '');

function extractIds(text) {
  const reqs = [];
  const acs = [];
  // Top-level list entries only: `- id: REQ-012` / `- id: AC-034`.
  const re = /^[ \t]*-[ \t]+id:[ \t]*(REQ-\d+|AC-\d+)[ \t]*$/gm;
  let m;
  while ((m = re.exec(text)) !== null) {
    (m[1].startsWith('REQ-') ? reqs : acs).push(m[1]);
  }
  const uniq = (xs) => [...new Set(xs)].sort();
  return { reqs: uniq(reqs), acs: uniq(acs) };
}

const spec = fs.readFileSync(SPEC, 'utf8');
const { reqs, acs } = extractIds(spec);

const out = [HEADER.trimEnd(), ''];
out.push('# ── Requirements ─────────────────────────────────────────────────────────────');
out.push(...reqs);
out.push('');
out.push('# ── Acceptance criteria ──────────────────────────────────────────────────────');
out.push(...acs);
out.push('');
process.stdout.write(out.join('\n'));
