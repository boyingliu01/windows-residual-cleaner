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
        reject(new Error(stderr.trim() || `Exit code: ${code} for ${scriptName}`));
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
    if (code === 0) {
      onDone();
    } else {
      onError(`Process exited with code ${code}`);
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

// ====== API Routes ======

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
  res.writeHead(200, {
    'Content-Type': 'text/plain; charset=utf-8',
    'Transfer-Encoding': 'chunked',
    'X-Content-Type-Options': 'nosniff',
  });

  const emit = (type, text, extra = {}) => {
    const msg = JSON.stringify({ type, text, timestamp: Date.now(), ...extra }) + '\n';
    res.write(msg);
  };

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
      (err) => {
        // Some scripts may error on certain systems - log but continue
        emit('error', `${script.name}: ${err}`);
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

  res.writeHead(200, {
    'Content-Type': 'text/plain; charset=utf-8',
    'Transfer-Encoding': 'chunked',
    'X-Content-Type-Options': 'nosniff',
  });

  const emit = (type, text, extra = {}) => {
    const msg = JSON.stringify({ type, text, timestamp: Date.now(), ...extra }) + '\n';
    res.write(msg);
  };

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
        emit('done', '操作完成', { log });
      }
      res.end();
    },
    (err) => {
      // Even on error, try to read log
      const log = readJSON('cleanup-log.json');
      if (log) {
        emit('done', '操作完成（有错误）', { log });
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

// POST /api/restore-point - Create a restore point
app.post('/api/restore-point', async (req, res) => {
  try {
    await runPS('create-restore-point.ps1');
    res.json({ ok: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
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
