// @vitest-environment node
// =============================================================================
// ui/server/index.test.mjs — 服务端路由的最小真实测试（2026-10-16 审计 P3）
// =============================================================================
// 背景：ui/server/index.cjs（唯一 spawn 管理员 PowerShell 的层）此前 516 行零测试，
// 原因是顶层无条件 app.listen —— require 即起服务撞 3456 端口。可测化改造后
// （require.main === module 守卫 + 导出 app），本文件对真实 express app 起临时端口。
//
// 测试红线：**绝不**触发会 spawn PowerShell 的路径（POST /api/cleanup 的 happy path
// 会拉起真实清理——仓库根存在 confirmed-ids.json，绝对不能碰）；**绝不**写仓库根
// 的真实 JSON（/api/confirm 只测 400 校验分支，不测落盘分支）。
// =============================================================================
import { describe, it, expect, beforeAll, afterAll, afterEach, beforeEach, vi } from 'vitest';
import http from 'node:http';
import path from 'node:path';
import os from 'node:os';
import fs from 'node:fs';
import childProcess from 'node:child_process';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { createRequire } from 'node:module';

const spawnMock = vi.spyOn(childProcess, 'spawn').mockImplementation(() => {
  throw new Error('Tests must not spawn real PowerShell');
});
const requireCjs = createRequire(import.meta.url);
const serverFs = requireCjs('node:fs');
const { app, PROJECT_ROOT, getBackupStatus, runPS, streamPS } = requireCjs('./index.cjs');

let server;
let baseUrl;

beforeAll(async () => {
  server = http.createServer(app);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});

afterAll(async () => {
  await new Promise((resolve) => server.close(resolve));
});

function request(routePath, { method = 'GET', headers = {}, body = null } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      `${baseUrl}${routePath}`,
      { method, headers },
      (res) => {
        let data = '';
        res.on('data', (chunk) => { data += chunk; });
        res.on('end', () => resolve({ status: res.statusCode, text: data }));
      },
    );
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

function getJSON(routePath, headers = {}) {
  return request(routePath, { headers }).then(async (res) => ({
    ...res,
    json: JSON.parse(res.text),
  }));
}

function fakeChild() {
  const child = new EventEmitter();
  child.stdout = new PassThrough();
  child.stderr = new PassThrough();
  child.kill = vi.fn();
  return child;
}

const tempRoots = [];
let currentDirs;
let statSpy = null;

afterEach(() => {
  currentDirs = undefined;
  statSpy?.mockRestore();
  statSpy = null;
  for (const root of tempRoots.splice(0)) {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

function createBackupDir(name) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wrc-backup-status-'));
  tempRoots.push(root);
  const full = path.join(root, name);
  fs.mkdirSync(full);
  return { name, full };
}

function writeBackupFile(dir, fileName, content, mtime = '2026-01-01T00:00:00Z') {
  const file = path.join(dir.full, fileName);
  fs.writeFileSync(file, content, 'utf8');
  const date = new Date(mtime);
  fs.utimesSync(file, date, date);
  return file;
}

function useBackupDirs(dirs) {
  currentDirs = dirs;
}

function readBackupStatus() {
  return getBackupStatus(currentDirs);
}

describe('GET /api/status — 状态形状（不泄露项目根）', () => {
  it('返回 200，三个布尔字段，且响应体不含任何绝对路径', async () => {
    const res = await getJSON('/api/status');
    expect(res.status).toBe(200);
    expect(typeof res.json.has_report).toBe('boolean');
    expect(typeof res.json.has_confirmed).toBe('boolean');
    expect(typeof res.json.has_log).toBe('boolean');
    expect(res.text).not.toMatch(/[A-Za-z]:\\\\/);
  });
});

describe('GET /api/backup-status — 诚实两层保护状态', () => {
  it('返回 200，restore_point.state 只能是三态之一，窗口为 24h', async () => {
    const res = await getJSON('/api/backup-status');
    expect(res.status).toBe(200);
    expect(['available', 'unavailable', 'unknown']).toContain(res.json.restore_point.state);
    expect(res.json.precise_protection).toHaveProperty('mechanism');
    expect(typeof res.json.precise_protection.journals).toBe('number');
    expect(typeof res.json.precise_protection.unfinished).toBe('number');
    expect(res.json.recovery_window_hours).toBe(24);
  });

  it('导出的 getBackupStatus 与路由读到的是同一份磁盘事实', () => {
    const status = readBackupStatus();
    expect(status.restore_point).toHaveProperty('state');
    expect(status.precise_protection).toHaveProperty('unfinished');
  });
});

describe('备份状态读取 — 磁盘证据与字段语义', () => {
  it('没有 restore-status.json 时如实返回 unavailable，不宣称保护可用', () => {
    useBackupDirs([]);
    expect(readBackupStatus().restore_point).toEqual({
      state: 'unavailable',
      enabled: false,
      attempted: null,
      detail: 'restore-status.json 不存在（从未运行 create-restore-point.ps1，或该步骤失败）',
      source: null,
      timestamp: null,
    });
  });

  it('按文件 mtime 选最新还原点状态，兼容 BOM，且不按目录名排序', () => {
    const oldDir = createBackupDir('backup-a');
    const newDir = createBackupDir('backup-z');
    writeBackupFile(oldDir, 'restore-status.json', JSON.stringify({ restore_point_enabled: false }));
    writeBackupFile(newDir, 'restore-status.json', '\uFEFF' + JSON.stringify({
      restore_point_enabled: true,
      restore_point_attempted: true,
      timestamp: '2026-01-02T03:04:05Z',
    }), '2026-01-02T00:00:00Z');
    useBackupDirs([oldDir, newDir]);

    expect(readBackupStatus().restore_point).toEqual({
      state: 'available',
      enabled: true,
      attempted: true,
      detail: '系统还原点已建立（尽力而为的最后手段）',
      source: 'backup-z/restore-status.json',
      timestamp: '2026-01-02T03:04:05Z',
    });
  });

  it('最新状态文件不可解析时返回 unknown，并保留来源与解析错误', () => {
    const dir = createBackupDir('backup-a');
    writeBackupFile(dir, 'restore-status.json', '{broken');
    useBackupDirs([dir]);

    const restorePoint = readBackupStatus().restore_point;
    expect(restorePoint.state).toBe('unknown');
    expect(restorePoint.enabled).toBe(false);
    expect(restorePoint.attempted).toBeNull();
    expect(restorePoint.source).toBe('backup-a/restore-status.json');
    expect(restorePoint.detail).toMatch(/^restore-status.json 不可解析：/);
  });

  it('状态 JSON 为 null 时返回 unknown，而不是让备份状态路由崩溃', () => {
    const dir = createBackupDir('backup-a');
    writeBackupFile(dir, 'restore-status.json', 'null');
    useBackupDirs([dir]);

    const restorePoint = readBackupStatus().restore_point;
    expect(restorePoint.state).toBe('unknown');
    expect(restorePoint.enabled).toBe(false);
    expect(restorePoint.source).toBe('backup-a/restore-status.json');
    expect(restorePoint.detail).toBe('restore-status.json 缺少有效状态字段');
  });

  it('只有布尔 false 表示主动跳过，字符串值不能被误判为状态证据', () => {
    const skippedDir = createBackupDir('backup-skipped');
    writeBackupFile(skippedDir, 'restore-status.json', JSON.stringify({
      restore_point_enabled: false,
      restore_point_attempted: false,
    }));
    useBackupDirs([skippedDir]);
    expect(readBackupStatus().restore_point.detail).toBe('按请求跳过（-SkipRestorePoint），未尝试建立');

    const malformedDir = createBackupDir('backup-malformed');
    writeBackupFile(malformedDir, 'restore-status.json', JSON.stringify({
      restore_point_enabled: 'true',
      restore_point_attempted: 'false',
      timestamp: 0,
    }));
    useBackupDirs([malformedDir]);
    expect(readBackupStatus().restore_point).toMatchObject({
      state: 'unavailable',
      enabled: false,
      attempted: null,
      timestamp: null,
      detail: '系统还原点未建立（System Protection 关闭 / 24h 节流 / 无权限）',
    });
  });

  it('读取 journal 时跳过缺失/损坏文件，兼容 BOM，并保留未完成证据', () => {
    const missingDir = createBackupDir('backup-missing');
    const brokenDir = createBackupDir('backup-broken');
    const openDir = createBackupDir('backup-open');
    const doneDir = createBackupDir('backup-done');
    const nonArrayDir = createBackupDir('backup-non-array');
    writeBackupFile(brokenDir, 'rollback-journal.json', '{broken');
    writeBackupFile(openDir, 'rollback-journal.json', '\uFEFF' + JSON.stringify({
      run_id: 'run-open',
      created_at: '2026-01-03T00:00:00Z',
      completed_at: '',
      entries: [{ id: 'fs_001' }, { id: 'fs_002' }],
    }));
    writeBackupFile(doneDir, 'rollback-journal.json', JSON.stringify({
      run_id: 'run-done',
      created_at: '2026-01-02T00:00:00Z',
      completed_at: '2026-01-02T01:00:00Z',
      entries: [],
    }));
    writeBackupFile(nonArrayDir, 'rollback-journal.json', JSON.stringify({ entries: {} }));
    useBackupDirs([missingDir, brokenDir, openDir, doneDir, nonArrayDir]);

    const precise = readBackupStatus().precise_protection;
    expect(precise.journals).toBe(3);
    expect(precise.unfinished).toBe(2);
    expect(precise.newest_unfinished).toEqual({
      backup_dir: 'backup-open',
      run_id: 'run-open',
      created_at: '2026-01-03T00:00:00Z',
      completed_at: null,
      unfinished: true,
      entries: 2,
    });
  });

  it('journal JSON 为 null 时跳过该文件，不把它计作有效保护证据', () => {
    const dir = createBackupDir('backup-null');
    writeBackupFile(dir, 'rollback-journal.json', 'null');
    useBackupDirs([dir]);

    expect(readBackupStatus().precise_protection).toMatchObject({
      journals: 0,
      unfinished: 0,
      newest_unfinished: null,
    });
  });

  it('最新 rollback-result 不可解析时返回 null，不回退到旧结果', () => {
    const oldDir = createBackupDir('backup-old');
    const newDir = createBackupDir('backup-new');
    writeBackupFile(oldDir, 'rollback-result.json', JSON.stringify({ run_id: 'old-run' }));
    writeBackupFile(newDir, 'rollback-result.json', '{broken', '2026-01-02T00:00:00Z');
    useBackupDirs([oldDir, newDir]);

    expect(readBackupStatus()).toMatchObject({ last_rollback: null });
  });

  it('rollback-result JSON 为 null 时返回 null，而不是让状态路由崩溃', () => {
    const dir = createBackupDir('backup-null');
    writeBackupFile(dir, 'rollback-result.json', 'null');
    useBackupDirs([dir]);

    expect(readBackupStatus()).toMatchObject({ last_rollback: null });
  });

  it('规范化 rollback verdict 的 camel/Pascal 字段，并严格保留 evidence_incomplete', () => {
    const dir = createBackupDir('backup-a');
    writeBackupFile(dir, 'rollback-result.json', '\uFEFF' + JSON.stringify({
      run_id: 'run-1',
      executed_at: '2026-01-02T03:00:00Z',
      within_window: true,
      counts: { restored: 2, restore_failed: 1 },
      verdicts: [
        { item_id: 'fs_001', kind: 'file', target: 'C:\\old', verdict: 'restored', reason: 'ok', evidence_incomplete: true },
        { ItemId: 'reg_002', Kind: 'registry', Target: 'HKCU\\old', Verdict: 'restore_failed', Reason: 'locked', EvidenceIncomplete: true },
        { item_id: '', ItemId: 'fallback-id', kind: null, Kind: 'fallback-kind', evidence_incomplete: false, EvidenceIncomplete: true },
      ],
    }));
    useBackupDirs([dir]);

    expect(readBackupStatus().last_rollback).toEqual({
      backup_dir: 'backup-a',
      run_id: 'run-1',
      executed_at: '2026-01-02T03:00:00Z',
      within_window: true,
      counts: { restored: 2, restore_failed: 1 },
      verdicts: [
        { item_id: 'fs_001', kind: 'file', target: 'C:\\old', verdict: 'restored', reason: 'ok', evidence_incomplete: true },
        { item_id: 'reg_002', kind: 'registry', target: 'HKCU\\old', verdict: 'restore_failed', reason: 'locked', evidence_incomplete: true },
        { item_id: '', kind: 'fallback-kind', target: null, verdict: null, reason: null, evidence_incomplete: false },
      ],
    });
  });

  it('rollback 的窗口与 counts 缺失时使用保守默认值，verdicts 非数组时为空', () => {
    const dir = createBackupDir('backup-a');
    writeBackupFile(dir, 'rollback-result.json', JSON.stringify({
      within_window: 'true',
      counts: null,
      verdicts: {},
    }));
    useBackupDirs([dir]);

    expect(readBackupStatus().last_rollback).toEqual({
      backup_dir: 'backup-a',
      run_id: null,
      executed_at: null,
      within_window: false,
      counts: {},
      verdicts: [],
    });
  });

  it('单个备份文件 stat 失败时跳过它，不丢掉其他可读证据', () => {
    const readableDir = createBackupDir('backup-readable');
    const unreadableDir = createBackupDir('backup-unreadable');
    writeBackupFile(readableDir, 'restore-status.json', JSON.stringify({ restore_point_enabled: true }));
    const unreadableFile = writeBackupFile(unreadableDir, 'restore-status.json', '{broken', '2026-01-02T00:00:00Z');
    const statSync = serverFs.statSync;
    statSpy = vi.spyOn(serverFs, 'statSync').mockImplementation((file) => {
      if (file === unreadableFile) throw new Error('locked');
      return statSync(file);
    });
    useBackupDirs([unreadableDir, readableDir]);

    expect(readBackupStatus().restore_point).toMatchObject({
      state: 'available',
      source: 'backup-readable/restore-status.json',
    });
  });
});

describe('POST /api/confirm — id 校验（confirmed-ids.json 是删除凭证，坏输入必须 400）', () => {
  const postJSON = (payload) => request('/api/confirm', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  });

  it('ids 不是数组 → 400', async () => {
    const res = await postJSON({ ids: 'fs_001' });
    expect(res.status).toBe(400);
    expect(JSON.parse(res.text).error).toBe('ids must be an array');
  });

  it('id 不是报告生成的形状（前缀_三位以上数字）→ 400', async () => {
    for (const bad of [['../evil'], ['fs_1'], ['path_1'], [123], [null]]) {
      const res = await postJSON({ ids: bad });
      expect(res.status).toBe(400);
      expect(JSON.parse(res.text).error).toBe('ids contain unknown item ids');
    }
  });

  it('ids 缺席 → 400', async () => {
    const res = await postJSON({});
    expect(res.status).toBe(400);
  });

  it('畸形 JSON 请求体 → 结构化 400 JSON，而不是 Express 默认 HTML 错误页', async () => {
    // delphi 走查 2026-10-16 minor：express.json() 的 SyntaxError 曾直接落到
    // 默认错误处理器，返回 HTML —— 前端 res.json() 会再抛解析异常掩盖真因。
    const res = await request('/api/confirm', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: 'not-json',
    });
    expect(res.status).toBe(400);
    expect(res.text).not.toMatch(/<!DOCTYPE/i);
    expect(JSON.parse(res.text).error).toBe('Malformed JSON body');
  });
});

describe('Origin 守卫（DNS rebinding / 跨站可读性）', () => {
  it('非 loopback Host 头 → 403（rebinding 防线）', async () => {
    const res = await request('/api/status', { headers: { Host: 'attacker.example' } });
    expect(res.status).toBe(403);
    expect(JSON.parse(res.text).error).toBe('non-loopback host rejected');
  });

  it('陌生 Origin 的浏览器请求 → 403 且响应不可被跨站读取', async () => {
    const res = await request('/api/status', { headers: { Origin: 'http://evil.example' } });
    expect(res.status).toBe(403);
    expect(JSON.parse(res.text).error).toBe('cross-origin request rejected');
  });

  it('无 Origin 头的本地客户端（curl/工具）放行', async () => {
    const res = await request('/api/status');
    expect(res.status).toBe(200);
  });
});

describe('未知 API 路由', () => {
  it('返回 404 而不是落到静态 SPA 分支', async () => {
    const res = await request('/api/definitely-not-a-route');
    expect(res.status).toBe(404);
  });
});

describe('Streaming route lifecycle', () => {
  beforeEach(() => {
    spawnMock.mockImplementation(() => {
      throw new Error('Tests must not spawn real PowerShell');
    });
  });

  it('does not kill a scan when the completed request body closes', async () => {
    const children = [];
    spawnMock.mockImplementation(() => {
      const child = fakeChild();
      children.push(child);
      return child;
    });

    const responsePromise = request('/api/scan', { method: 'POST' });
    await vi.waitFor(() => expect(children).toHaveLength(1));
    await new Promise(resolve => setImmediate(resolve));
    const killedAfterRequest = children[0].kill.mock.calls.length > 0;

    while (children.length < 6) children.at(-1).emit('close', 0);
    children.at(-1).emit('close', 0);
    const res = await responsePromise;

    expect(res.status).toBe(200);
    expect(killedAfterRequest).toBe(false);
  });

  it('does not kill cleanup when its JSON request body finishes normally', async () => {
    const children = [];
    spawnMock.mockImplementation(() => {
      const child = fakeChild();
      children.push(child);
      return child;
    });
    const confirmPath = path.join(PROJECT_ROOT, 'confirmed-ids.json');
    const existsSync = serverFs.existsSync;
    const existsSpy = vi.spyOn(serverFs, 'existsSync').mockImplementation(file => (
      file === confirmPath || existsSync(file)
    ));
    let requestFinished = false;
    const body = JSON.stringify({ dryRun: true });
    const responsePromise = new Promise((resolve, reject) => {
      const req = http.request(`${baseUrl}/api/cleanup`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(body),
        },
      }, (res) => {
        let text = '';
        res.on('data', chunk => { text += chunk; });
        res.on('end', () => resolve({ status: res.statusCode, text }));
      });
      req.on('error', reject);
      req.on('finish', () => { requestFinished = true; });
      req.end(body);
    });

    try {
      await vi.waitFor(() => {
        expect(children).toHaveLength(1);
        expect(requestFinished).toBe(true);
      });
      await new Promise(resolve => setImmediate(resolve));
      expect(children[0].kill).not.toHaveBeenCalled();

      children[0].emit('close', 0);
      await expect(responsePromise).resolves.toMatchObject({ status: 200 });
    } finally {
      existsSpy.mockRestore();
    }
  });
});

describe('PowerShell buffered output', () => {
  beforeEach(() => {
    spawnMock.mockImplementation(() => {
      throw new Error('Tests must not spawn real PowerShell');
    });
  });

  it('preserves UTF-8 output split across byte chunks', async () => {
    const child = fakeChild();
    spawnMock.mockReturnValue(child);
    const result = runPS('status.ps1');
    const record = Buffer.from('{"message":"系统状态"}');

    for (let i = 0; i < record.length; i++) child.stdout.write(record.subarray(i, i + 1));
    child.emit('close', 0);

    await expect(result).resolves.toBe('{"message":"系统状态"}');
  });

  it('exposes the buffered process boundary for fake-child tests', () => {
    expect(typeof runPS).toBe('function')
  })
})

describe('PowerShell stream framing', () => {
  beforeEach(() => {
    spawnMock.mockImplementation(() => {
      throw new Error('Tests must not spawn real PowerShell');
    });
  });

  it('buffers a record split across stdout chunks', () => {
    const child = fakeChild();
    spawnMock.mockReturnValue(child);
    const lines = [];
    const onDone = vi.fn();

    streamPS('scan.ps1', [], line => lines.push(line), onDone, vi.fn());
    const record = Buffer.from('{"type":"info","text":"扫描完成"}\n');
    child.stdout.write(record.subarray(0, 12));
    child.stdout.write(record.subarray(12));
    child.emit('close', 0);

    expect(lines).toEqual(['{"type":"info","text":"扫描完成"}']);
    expect(onDone).toHaveBeenCalledWith(0);
  });

  it('preserves UTF-8 characters split across byte chunks', () => {
    const child = fakeChild();
    spawnMock.mockReturnValue(child);
    const lines = [];

    streamPS('scan.ps1', [], line => lines.push(line), vi.fn(), vi.fn());
    const record = Buffer.from('{"type":"info","text":"系统残留"}\n');
    for (let i = 0; i < record.length; i++) child.stdout.write(record.subarray(i, i + 1));
    child.emit('close', 0);

    expect(lines).toEqual(['{"type":"info","text":"系统残留"}']);
  });

  it('flushes a final stdout line without a newline', () => {
    const child = fakeChild();
    spawnMock.mockReturnValue(child);
    const lines = [];

    streamPS('scan.ps1', [], line => lines.push(line), vi.fn(), vi.fn());
    child.stdout.write(Buffer.from('最后一行'));
    child.stdout.emit('end');
    child.emit('close', 0);

    expect(lines).toEqual(['最后一行']);
  });

  it('exposes the process boundary for fake-child tests', () => {
    expect(typeof streamPS).toBe('function')
  })
})

describe('可测化导出契约', () => {
  it('PROJECT_ROOT 指向仓库根（结构性判据：能同时命中 package.json 与 references/scripts）', () => {
    // 不用仓库名做断言——仓库目录改名即误红；改用仓库根的锚点文件/目录。
    expect(fs.existsSync(path.join(PROJECT_ROOT, 'package.json'))).toBe(true);
    expect(fs.existsSync(path.join(PROJECT_ROOT, 'references', 'scripts'))).toBe(true);
  });
});
