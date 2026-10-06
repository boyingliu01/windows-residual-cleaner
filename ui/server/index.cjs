const express = require('express');
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const cors = require('cors');

const app = express();
app.use(express.json({ limit: '10mb' }));
app.use(cors());

// Paths
const PROJECT_ROOT = path.resolve(__dirname, '../..');
const SCRIPTS_DIR = path.join(PROJECT_ROOT, 'references', 'scripts');

const POWERSHELL = 'powershell.exe';
const PS_FLAGS = ['-ExecutionPolicy', 'Bypass', '-NoProfile', '-NonInteractive'];

// ====== HELPER: Run PowerShell and return output ======
function runPS(scriptName, args = []) {
  return new Promise((resolve, reject) => {
    const fullArgs = [
      ...PS_FLAGS,
      '-File', path.join(SCRIPTS_DIR, scriptName),
      ...args
    ];

    const child = spawn(POWERSHELL, fullArgs, {
      cwd: PROJECT_ROOT,
      windowsHide: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    let stdout = '';
    let stderr = '';
    let timedOut = false;

    const timer = setTimeout(() => {
      timedOut = true;
      child.kill();
      reject(new Error(`Script ${scriptName} timed out after 300s`));
    }, 300000);

    child.stdout.on('data', (data) => {
      stdout += data.toString('utf8');
    });

    child.stderr.on('data', (data) => {
      stderr += data.toString('utf8');
    });

    child.on('close', (code) => {
      clearTimeout(timer);
      if (timedOut) return;
      if (code === 0) {
        resolve(stdout.trim());
      } else {
        // 带上真实退出码：/api/restore-point 必须区分「4=可选层未建立（可继续）」
        // 与「1/2/3=真失败」，两者对用户的含义完全不同。
        const err = new Error(stderr.trim() || `Exit code: ${code} for ${scriptName}`);
        err.exitCode = code;
        reject(err);
      }
    });

    child.on('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });
  });
}

// ====== HELPER: Stream PowerShell output ======
function streamPS(scriptName, args = [], onLine, onDone, onError) {
  const fullArgs = [
    ...PS_FLAGS,
    '-File', path.join(SCRIPTS_DIR, scriptName),
    ...args
  ];

  const child = spawn(POWERSHELL, fullArgs, {
    cwd: PROJECT_ROOT,
    windowsHide: true,
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    child.kill();
    onError('Script timed out');
  }, 300000);

  child.stdout.on('data', (data) => {
    const text = data.toString('utf8');
    const lines = text.split('\n').filter(l => l.trim());
    for (const line of lines) {
      onLine(line);
    }
  });

  child.stderr.on('data', (data) => {
    const text = data.toString('utf8');
    const lines = text.split('\n').filter(l => l.trim());
    for (const line of lines) {
      onLine(`[stderr] ${line}`);
    }
  });

  child.on('close', (code) => {
    clearTimeout(timer);
    if (timedOut) return;
    // 把真实退出码一并交给调用方：REQ-026 的 10..15 是「清理/回滚到底怎么样」的唯一
    // 机读信号，只回一句 "exited with code N" 的字符串会让 UI 无法区分「已修复」与「仍受损」。
    if (code === 0) {
      onDone(code);
    } else {
      onError(`Process exited with code ${code}`, code);
    }
  });

  child.on('error', (err) => {
    clearTimeout(timer);
    onError(err.message);
  });

  return child;
}

// ====== JSON file helpers ======
function readJSON(filename) {
  const filepath = path.join(PROJECT_ROOT, filename);
  try {
    if (fs.existsSync(filepath)) {
      return JSON.parse(fs.readFileSync(filepath, 'utf8'));
    }
  } catch (e) {
    console.warn(`Failed to read ${filepath}:`, e.message);
  }
  return null;
}

// ====== HELPER: honest two-layer protection status ======
// REQ-014 / DD-011 / AC-023 / AC-065：UI 只能转述盘上真实存在的证据。
// 「保护」分两层，绝不能混为一谈（REQ-017）：
//   (a) 强制逐项精准保护 = 本轮删除之前由 clean-residuals.ps1 创建的 rollback-journal.json。
//       它不可用时清理会在第一次删除前中止，所以这里**不**替尚未开始的本轮预先宣称
//       「已就绪」，只报机制 + 遗留的未完成日志（那才是「上一轮没修好」的真实信号）。
//   (b) 可选系统还原点 = 尽力而为的最后手段，唯一权威来源是 restore-status.json。
// 读不到 / 解析不了 / 字段缺失 → 一律如实返回「不知道」，绝不默认成可用。
const RECOVERY_WINDOW_HOURS = 24;

// PowerShell 写的 JSON 常常带 UTF-8 BOM，Node 的 JSON.parse 会因此直接抛错。
function readJSONFile(filepath) {
  try {
    return JSON.parse(fs.readFileSync(filepath, 'utf8').replace(/^\uFEFF/, ''));
  } catch (e) {
    return { __error: e.message };
  }
}

function listBackupDirs() {
  try {
    return fs.readdirSync(PROJECT_ROOT, { withFileTypes: true })
      .filter(d => d.isDirectory() && d.name.startsWith('backup-'))
      .map(d => ({ name: d.name, full: path.join(PROJECT_ROOT, d.name) }));
  } catch {
    return [];
  }
}

// 同名文件在各备份目录里取「最近写入」的那份——与 clean-residuals.ps1 的
// Get-OptionalProtectionStatus 同一口径（按 LastWriteTime，不按目录名排序）。
function newestFileInBackups(dirs, fileName) {
  let best = null;
  for (const d of dirs) {
    const f = path.join(d.full, fileName);
    try {
      if (!fs.existsSync(f)) continue;
      const st = fs.statSync(f);
      if (!best || st.mtimeMs > best.mtimeMs) best = { file: f, dir: d.name, mtime: st.mtimeMs };
    } catch { /* 读不动的目录跳过：最终如实表现为「无记录」 */ }
  }
  return best;
}

function readRestorePointStatus(dirs) {
  const restorePoint = {
    state: 'unknown',      // available | unavailable | unknown
    enabled: false,
    attempted: null,       // null = 旧版本未记录，无法判断「试过没有」
    detail: '',
    source: null,
    timestamp: null,
  };
  const rpFile = newestFileInBackups(dirs, 'restore-status.json');
  if (!rpFile) {
    restorePoint.state = 'unavailable';
    restorePoint.detail = 'restore-status.json 不存在（从未运行 create-restore-point.ps1，或该步骤失败）';
    return restorePoint;
  }
  restorePoint.source = `${rpFile.dir}/restore-status.json`;
  const doc = readJSONFile(rpFile.file);
  if (doc.__error) {
    restorePoint.detail = `restore-status.json 不可解析：${doc.__error}`;
    return restorePoint;
  }
  restorePoint.enabled = doc.restore_point_enabled === true;
  restorePoint.state = restorePoint.enabled ? 'available' : 'unavailable';
  restorePoint.attempted = typeof doc.restore_point_attempted === 'boolean' ? doc.restore_point_attempted : null;
  restorePoint.timestamp = doc.timestamp || null;
  restorePoint.detail = restorePoint.enabled
    ? '系统还原点已建立（尽力而为的最后手段）'
    : (restorePoint.attempted === false
      ? '按请求跳过（-SkipRestorePoint），未尝试建立'
      : '系统还原点未建立（System Protection 关闭 / 24h 节流 / 无权限）');
  return restorePoint;
}

function readJournals(dirs) {
  const journals = [];
  for (const d of dirs) {
    const f = path.join(d.full, 'rollback-journal.json');
    if (!fs.existsSync(f)) continue;
    const doc = readJSONFile(f);
    if (doc.__error) continue;
    const entries = Array.isArray(doc.entries) ? doc.entries : [];
    journals.push({
      backup_dir: d.name,
      run_id: doc.run_id || null,
      created_at: doc.created_at || null,
      completed_at: doc.completed_at || null,
      unfinished: !doc.completed_at,
      entries: entries.length,
    });
  }
  return journals;
}

function readLastRollback(dirs) {
  const hit = newestFileInBackups(dirs, 'rollback-result.json');
  if (!hit) return null;
  const doc = readJSONFile(hit.file);
  if (doc.__error) return null;
  const verdicts = Array.isArray(doc.verdicts) ? doc.verdicts : [];
  return {
    backup_dir: hit.dir,
    run_id: doc.run_id || null,
    executed_at: doc.executed_at || null,
    within_window: doc.within_window === true,
    counts: doc.counts || {},
    verdicts: verdicts.map(v => ({
      item_id: v.item_id ?? v.ItemId ?? null,
      kind: v.kind ?? v.Kind ?? null,
      target: v.target ?? v.Target ?? null,
      verdict: v.verdict ?? v.Verdict ?? null,
      reason: v.reason ?? v.Reason ?? null,
      // PS writes the PascalCase field; the spec requires the UI to list these
      // separately from unrepaired items, so it must survive the read.
      evidence_incomplete: v.evidence_incomplete ?? (v.EvidenceIncomplete === true),
    })),
  };
}

function getBackupStatus() {
  const dirs = listBackupDirs();
  const journals = readJournals(dirs);
  const pending = journals.filter(j => j.unfinished)
    .sort((a, b) => String(b.created_at || '').localeCompare(String(a.created_at || '')));

  return {
    restore_point: readRestorePointStatus(dirs),
    precise_protection: {
      mechanism: 'rollback-journal.json + 逐项 pre-image，在第一次删除之前建立；建立失败则中止清理',
      journals: journals.length,
      unfinished: pending.length,
      newest_unfinished: pending[0] || null,
    },
    last_rollback: readLastRollback(dirs),
    recovery_window_hours: RECOVERY_WINDOW_HOURS,
  };
}

// ====== API Routes ======

// Streaming endpoints (scan, cleanup) share the same NDJSON framing; keep it in one place
// so a header change cannot land on one route and miss the other.
function startStream(res) {
  res.writeHead(200, {
    'Content-Type': 'text/plain; charset=utf-8',
    'Transfer-Encoding': 'chunked',
    'X-Content-Type-Options': 'nosniff',
  });
  return (type, text, extra = {}) => {
    res.write(JSON.stringify({ type, text, timestamp: Date.now(), ...extra }) + '\n');
  };
}

// GET /api/backup-status - Real protection state (never a promise)
app.get('/api/backup-status', (req, res) => {
  res.json(getBackupStatus());
});

// GET /api/report - Load existing final-report.json
app.get('/api/report', (req, res) => {
  const report = readJSON('final-report.json');
  if (report) {
    res.json(report);
  } else {
    res.status(404).json({ error: 'No report found' });
  }
});

// POST /api/scan - Run full scan pipeline (streaming)
app.post('/api/scan', (req, res) => {
  const emit = startStream(res);

  const scripts = [
    { name: 'create-restore-point.ps1', label: '正在创建系统还原点...' },
    { name: 'build-installed-index.ps1', label: '正在构建已安装软件索引...' },
    { name: 'scan-uninstalled.ps1', label: '正在扫描已卸载残留...' },
    { name: 'scan-filesystem-residuals.ps1', label: '正在扫描文件系统残留...' },
    { name: 'scan-residuals.ps1', label: '正在扫描注册表/服务/任务残留...' },
    { name: 'generate-report.ps1', label: '正在生成最终报告...' },
  ];

  let idx = 0;

  function runNext() {
    if (idx >= scripts.length) {
      // Done - emit report data
      const report = readJSON('final-report.json');
      if (report) {
        emit('done', '扫描完成', { report });
      } else {
        emit('error', '扫描完成但未找到报告文件');
      }
      res.end();
      return;
    }

    const script = scripts[idx];
    emit('step', script.label);

    const child = streamPS(
      script.name,
      [],
      (line) => emit('info', line),
      () => {
        emit('success', `${script.name} 完成`);
        idx++;
        runNext();
      },
      (err, code) => {
        // 某些脚本在特定机器上会失败——记录并继续。
        // 但要如实分类：create-restore-point.ps1 的 4 是「可选还原点未建立」这一
        // 已知状态（REQ-004），不是脚本坏了。标成 error 会让人以为扫描失败。
        if (script.name === 'create-restore-point.ps1' && code === 4) {
          emit('caution', '可选系统还原点未建立（System Protection 关闭 / 24h 节流 / 无权限）；强制逐项精准保护不受影响，扫描继续');
        } else {
          emit('error', `${script.name}: ${err}`);
        }
        idx++;
        runNext();
      }
    );

    // Store child reference for abort
    req.on('close', () => {
      if (!child.killed) child.kill();
    });
  }

  runNext();
});

// POST /api/confirm - Save selected IDs
app.post('/api/confirm', (req, res) => {
  const { ids } = req.body;
  if (!Array.isArray(ids)) {
    return res.status(400).json({ error: 'ids must be an array' });
  }
  // Write as single-line JSON array (matching PS format)
  const filepath = path.join(PROJECT_ROOT, 'confirmed-ids.json');
  fs.writeFileSync(filepath, JSON.stringify(ids), 'utf8');
  res.json({ ok: true, count: ids.length });
});

// POST /api/cleanup - Run cleanup or dry-run (streaming)
app.post('/api/cleanup', (req, res) => {
  const { dryRun } = req.body;
  const emit = startStream(res);

  const confirmPath = path.join(PROJECT_ROOT, 'confirmed-ids.json');
  if (!fs.existsSync(confirmPath)) {
    emit('error', '未找到 confirmed-ids.json，请先确认选择');
    res.end();
    return;
  }

  // clean-residuals.ps1 is invoked with -File (does NOT change the process cwd,
  // which stays PROJECT_ROOT). Pass an ABSOLUTE path so the ConfirmFile resolves
  // deterministically; a wrong relative path previously escaped the repo and,
  // combined with the script's old fail-open branch, silently over-deleted.
  const args = ['-ConfirmFile', confirmPath];
  if (dryRun) args.push('-DryRun');

  emit('step', dryRun ? '正在执行 DryRun 预览...' : '正在执行清理...');

  const child = streamPS(
    'clean-residuals.ps1',
    args,
    (line) => emit('info', line),
    () => {
      emit('success', dryRun ? 'DryRun 预览完成' : '清理完成');
      const log = readJSON('cleanup-log.json');
      if (log) {
        emit('done', '操作完成', { log, exit_code: 0 });
      }
      res.end();
    },
    (err, code) => {
      // Even on error, try to read log
      const log = readJSON('cleanup-log.json');
      if (log) {
        // 退出码必须原样带出去：REQ-026 用它区分 10/11/12/13/14/15
        // （「部分失败但已回滚」与「仍受损」是两件事）。
        emit('done', '操作完成（有错误）', { log, exit_code: code ?? null, detail: err });
      } else {
        emit('error', err);
      }
      res.end();
    }
  );

  req.on('close', () => {
    if (!child.killed) child.kill();
  });
});

// GET /api/cleanup-log - Get cleanup-log.json
app.get('/api/cleanup-log', (req, res) => {
  const log = readJSON('cleanup-log.json');
  if (log) {
    res.json(log);
  } else {
    res.status(404).json({ error: 'No cleanup log found' });
  }
});

// GET /api/status - Check overall status
app.get('/api/status', (req, res) => {
  const hasReport = fs.existsSync(path.join(PROJECT_ROOT, 'final-report.json'));
  const hasConfirmed = fs.existsSync(path.join(PROJECT_ROOT, 'confirmed-ids.json'));
  const hasLog = fs.existsSync(path.join(PROJECT_ROOT, 'cleanup-log.json'));

  res.json({
    has_report: hasReport,
    has_confirmed: hasConfirmed,
    has_log: hasLog,
    project_root: PROJECT_ROOT,
  });
});

// POST /api/restore-point - Try to establish the OPTIONAL layer and report what happened
app.post('/api/restore-point', async (req, res) => {
  try {
    await runPS('create-restore-point.ps1');
    // 成功也不说「已备份」——读盘上的状态文件，按事实回答（REQ-004 / AC-018）。
    res.json({ ok: true, backup: getBackupStatus() });
  } catch (err) {
    // 4 = 尽力而为层没建立起来。注册表备份与强制精准保护都不受影响，
    // 所以这是「如实的 200」，不是 500——把它报成服务器错误反而会让人以为清理坏了。
    if (err.exitCode === 4) {
      res.json({ ok: false, optional_layer_unavailable: true, backup: getBackupStatus() });
      return;
    }
    res.status(500).json({ error: err.message, exit_code: err.exitCode ?? null });
  }
});

// Serve static frontend in production
const DIST_DIR = path.resolve(__dirname, '../dist');
if (fs.existsSync(DIST_DIR)) {
  app.use(express.static(DIST_DIR));
  app.get('*', (req, res) => {
    if (!req.path.startsWith('/api')) {
      res.sendFile(path.join(DIST_DIR, 'index.html'));
    }
  });
}

// Server start
// Bind loopback ONLY: this server spawns admin-privileged, destructive
// clean-residuals.ps1. Default app.listen() binds 0.0.0.0 (all interfaces),
// exposing those endpoints to the LAN. Override via HOST only deliberately.
const HOST = process.env.HOST || '127.0.0.1';
const PORT = process.env.PORT || 3456;
app.listen(PORT, HOST, () => {
  console.log(`API server running on http://${HOST}:${PORT}`);
  console.log(`Project root: ${PROJECT_ROOT}`);
  console.log(`Scripts dir: ${SCRIPTS_DIR}`);
});
