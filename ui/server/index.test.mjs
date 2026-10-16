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
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import http from 'node:http';
import { createRequire } from 'node:module';

const requireCjs = createRequire(import.meta.url);
const { app, PROJECT_ROOT, getBackupStatus } = requireCjs('./index.cjs');

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
    const status = getBackupStatus();
    expect(status.restore_point).toHaveProperty('state');
    expect(status.precise_protection).toHaveProperty('unfinished');
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

describe('可测化导出契约', () => {
  it('PROJECT_ROOT 指向仓库根', () => {
    expect(PROJECT_ROOT.endsWith('windows-residual-cleaner')).toBe(true);
  });
});
