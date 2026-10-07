// @vitest-environment node
import { describe, it, expect } from 'vitest';
import { validateItemIds, createOriginGuard, isLoopbackHostname } from './security.cjs';

function fakeRes() {
  const out = { status: 0, body: null };
  return {
    out,
    status(code) {
      out.status = code;
      return this;
    },
    json(payload) {
      out.body = payload;
      return this;
    },
  };
}

function run(guard, req) {
  const res = fakeRes();
  let passed = false;
  guard(req, res, () => {
    passed = true;
  });
  return { status: res.out.status, body: res.out.body, passed };
}

const guard = createOriginGuard({
  allowedOrigins: ['http://localhost:5173', 'http://127.0.0.1:5173'],
});

describe('validateItemIds', () => {
  it('accepts the report id shape generate-report.ps1 emits', () => {
    expect(validateItemIds(['fs_001', 'path_1234', 'shl_007']).ok).toBe(true);
  });
  it('rejects a non-array body', () => {
    expect(validateItemIds('fs_001').ok).toBe(false);
    expect(validateItemIds(undefined).ok).toBe(false);
  });
  it('rejects ids that are not strings or not in the report shape', () => {
    for (const bad of [['fs_01'], ['FS_001'], ['fs_001', ''], [42], ['..\\..\\x'], ['fs_001; Get-ChildItem']]) {
      expect(validateItemIds(bad).ok).toBe(false);
    }
  });
  it('accepts an empty selection (clearing the confirmation)', () => {
    expect(validateItemIds([]).ok).toBe(true);
  });
});

describe('createOriginGuard', () => {
  it('lets non-browser clients through (no Origin header)', () => {
    const r = run(guard, { headers: { host: '127.0.0.1:3456' } });
    expect(r.passed).toBe(true);
  });
  it('lets same-origin browser requests through', () => {
    const r = run(guard, { headers: { host: '127.0.0.1:3456', origin: 'http://127.0.0.1:3456' } });
    expect(r.passed).toBe(true);
  });
  it('lets the vite dev origin through (proxied /api)', () => {
    const r = run(guard, { headers: { host: 'localhost:3456', origin: 'http://localhost:5173' } });
    expect(r.passed).toBe(true);
  });
  it('rejects a foreign page that POSTs to loopback', () => {
    const r = run(guard, { headers: { host: '127.0.0.1:3456', origin: 'https://evil.example' } });
    expect(r.passed).toBe(false);
    expect(r.status).toBe(403);
  });
  it('rejects a rebinding Host even when Origin matches it', () => {
    const r = run(guard, { headers: { host: 'attacker.example:3456', origin: 'http://attacker.example:3456' } });
    expect(r.passed).toBe(false);
    expect(r.status).toBe(403);
  });
  it('treats IPv6 loopback as loopback', () => {
    expect(isLoopbackHostname('[::1]')).toBe(true);
    const r = run(guard, { headers: { host: '[::1]:3456', origin: 'http://[::1]:3456' } });
    expect(r.passed).toBe(true);
  });
});
