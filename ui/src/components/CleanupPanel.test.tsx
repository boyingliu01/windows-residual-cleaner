import { describe, expect, it, vi, afterEach } from 'vitest'
import { fireEvent, screen } from '@testing-library/react'
import { fixtureCleanupLog, renderWithApp, sseResponse, jsonResponse } from '@/test'
import { CleanupPanel } from './CleanupPanel'
import type { BackupStatus } from '@/types'

afterEach(() => {
  vi.unstubAllGlobals()
})

function status(over: Partial<BackupStatus['restore_point']>): BackupStatus {
  return {
    restore_point: {
      state: 'available',
      enabled: true,
      attempted: true,
      detail: '系统还原点已建立（尽力而为的最后手段）',
      source: 'backup-x/restore-status.json',
      // Fresh, so the staleness caveat does not fire in unrelated assertions.
      timestamp: new Date().toISOString(),
      ...over,
    },
    precise_protection: {
      mechanism: 'rollback-journal.json + 逐项 pre-image，在第一次删除之前建立；建立失败则中止清理',
      journals: 1,
      unfinished: 0,
      newest_unfinished: null,
    },
    last_rollback: null,
    recovery_window_hours: 24,
  }
}

function stubApi(doneLog: unknown, backup: BackupStatus | null) {
  vi.stubGlobal('fetch', vi.fn(async (input: unknown) => {
    const url = String((input as RequestInfo))
    if (url.includes('/api/cleanup-log')) return jsonResponse(null, false)
    if (url.includes('/api/backup-status')) {
      return backup === null ? jsonResponse({}, false) : jsonResponse(backup)
    }
    return sseResponse([{ type: 'done', log: doneLog, exit_code: 0 }])
  }))
}

describe('CleanupPanel', () => {
  it('runs a dry-run from the streamed output and offers the real cleanup', async () => {
    stubApi(fixtureCleanupLog, status({}))
    const { dispatch } = renderWithApp(<CleanupPanel />)
    dispatch({ type: 'SET_PHASE', phase: 'dry-run' })

    fireEvent.click(screen.getByText('运行 DryRun 预览'))

    expect(await screen.findByText(/处理 2 项/)).toBeTruthy()
    expect(screen.getByText('成功 2')).toBeTruthy()
    expect(screen.getByText('确认执行清理')).toBeTruthy()
  })

  it('shows failure entries with their error text', async () => {
    const failedLog = {
      ...fixtureCleanupLog,
      summary: { ...fixtureCleanupLog.summary, failed: 1, succeeded: 1 },
      entries: [
        { success: true, id: 'fs_001', path: 'C:/ProgramData/OldApp', action: 'would delete' },
        { success: false, id: 'fs_002', path: 'C:/ProgramData/Other', action: 'delete', error: 'access denied' },
      ],
    }
    stubApi(failedLog, status({}))
    const { dispatch } = renderWithApp(<CleanupPanel />)
    dispatch({ type: 'SET_PHASE', phase: 'dry-run' })

    fireEvent.click(screen.getByText('运行 DryRun 预览'))

    expect(await screen.findByText('删除失败的项：')).toBeTruthy()
    expect(screen.getByText(/\[fs_002\].*access denied/)).toBeTruthy()
  })
})

describe('CleanupPanel protection status (AC-013 / AC-023 / AC-065)', () => {
  it('reports the restore point as available without calling it a backup promise', async () => {
    stubApi(fixtureCleanupLog, status({}))
    renderWithApp(<CleanupPanel />)

    expect(await screen.findByText(/强制逐项精准保护/)).toBeTruthy()
    expect(screen.getByText(/可选系统还原点/)).toBeTruthy()
    expect(screen.getByText('已建立')).toBeTruthy()
    expect(screen.queryByText(/已通过系统还原点备份/)).toBeNull()
  })

  it('never renders the backup promise while the layer is unavailable', async () => {
    stubApi(fixtureCleanupLog, status({
      state: 'unavailable',
      enabled: false,
      detail: '系统还原点未建立（System Protection 关闭 / 24h 节流 / 无权限）',
    }))
    renderWithApp(<CleanupPanel />)

    expect(await screen.findByText('未建立')).toBeTruthy()
    expect(screen.getByText(/System Protection 关闭/)).toBeTruthy()
    expect(screen.queryByText(/已通过系统还原点备份/)).toBeNull()
  })

  it('says "unknown" instead of assuming protection when the server gives no evidence', async () => {
    stubApi(fixtureCleanupLog, null)
    renderWithApp(<CleanupPanel />)

    expect(await screen.findByText(/保护状态未知/)).toBeTruthy()
    expect(screen.queryByText(/已通过系统还原点备份/)).toBeNull()
  })

  it('surfaces an unfinished journal from the previous run', async () => {
    const pending = status({})
    pending.precise_protection = {
      ...pending.precise_protection,
      unfinished: 2,
      newest_unfinished: {
        backup_dir: 'backup-20261004-010101',
        run_id: 'run_42',
        created_at: '2026-10-04T01:01:01Z',
        completed_at: null,
        unfinished: true,
        entries: 7,
      },
    }
    stubApi(fixtureCleanupLog, pending)
    renderWithApp(<CleanupPanel />)

    expect(await screen.findByText(/上一轮清理可能未恢复/)).toBeTruthy()
    expect(screen.getByText(/run_42，7 项/)).toBeTruthy()
  })

  it('states the 24h next-launch recovery boundary', async () => {
    stubApi(fixtureCleanupLog, status({}))
    renderWithApp(<CleanupPanel />)

    expect(await screen.findByText(/24 小时内/)).toBeTruthy()
    expect(screen.getByText(/无法自动还原/)).toBeTruthy()
  })

  it('repeats the honest warning inside the confirm dialog, without a backup claim', async () => {
    stubApi(fixtureCleanupLog, status({ state: 'unavailable', enabled: false, detail: 'System Protection 已关闭' }))
    const { dispatch } = renderWithApp(<CleanupPanel />)
    dispatch({ type: 'SET_PHASE', phase: 'dry-run' })

    fireEvent.click(screen.getByText('运行 DryRun 预览'))
    fireEvent.click(await screen.findByText('确认执行清理'))

    expect(await screen.findByText(/整机回退这一层没有/)).toBeTruthy()
    // The reason is shown twice by design: once in the standing protection block,
    // once inside the dialog the user is about to confirm.
    expect(screen.getAllByText(/System Protection 已关闭/).length).toBeGreaterThan(1)
    expect(screen.queryByText(/已通过系统还原点备份/)).toBeNull()
  })
})

describe('CleanupPanel last rollback result', () => {
  it('says nothing was rolled back when no journal was ever consumed', async () => {
    stubApi(fixtureCleanupLog, status({}))
    renderWithApp(<CleanupPanel />)

    expect(await screen.findByText(/从未回滚/)).toBeTruthy()
  })

  it('separates unrepaired items from the ones that were never restorable', async () => {
    const withRollback = status({})
    withRollback.last_rollback = {
      backup_dir: 'backup-20261005-101010',
      run_id: 'run_7',
      executed_at: '2026-10-05T10:10:10Z',
      within_window: true,
      counts: { restored: 1, already_present: 0, not_restorable: 1, restore_failed: 1 },
      verdicts: [
        { item_id: 'registry:HKCU//Software/WRC-Missing', kind: 'registry_key', target: 'HKCU//Software/WRC-Missing', verdict: 'restored', reason: null, evidence_incomplete: false },
        { item_id: 'service:WRCGhost', kind: 'service', target: 'WRCGhost', verdict: 'not_restorable', reason: 'not_restorable_service', evidence_incomplete: false },
        { item_id: 'path_entry:C://wrc-drill', kind: 'path_entry', target: 'C://wrc-drill', verdict: 'restore_failed', reason: 'conflict(target_present_and_differs)', evidence_incomplete: false },
      ],
    }
    stubApi(fixtureCleanupLog, withRollback)
    renderWithApp(<CleanupPanel />)

    expect(await screen.findByText(/未修复 1/)).toBeTruthy()
    expect(screen.getByText(/已恢复 1/)).toBeTruthy()
    expect(screen.getByText(/conflict\(target_present_and_differs\)/)).toBeTruthy()
    // A not_restorable verdict is disclosure, not a repair queue — it must not be
    // counted where a user would look for what still needs fixing.
    expect(screen.getByText(/本就无法自动恢复/)).toBeTruthy()
    expect(screen.getByText(/service:WRCGhost/)).toBeTruthy()
    expect(screen.queryByText(/证据不完整/)).toBeNull()
  })

  it('lists evidence-incomplete items apart from unrepaired ones', async () => {
    const withRollback = status({})
    withRollback.last_rollback = {
      backup_dir: 'backup-20261005-111111',
      run_id: 'run_8',
      executed_at: '2026-10-05T11:11:11Z',
      within_window: true,
      counts: { restored: 1, already_present: 0, not_restorable: 0, restore_failed: 0 },
      verdicts: [
        { item_id: 'startup_value:HKCU:/Software/Microsoft/Windows/CurrentVersion/Run/WRC-Drill', kind: 'startup_value', target: 'HKCU:/Software/Microsoft/Windows/CurrentVersion/Run/WRC-Drill', verdict: 'restored', reason: null, evidence_incomplete: true },
      ],
    }
    stubApi(fixtureCleanupLog, withRollback)
    renderWithApp(<CleanupPanel />)

    // The item list and the low-confidence verdict both name the condition.
    expect((await screen.findAllByText(/证据不完整/)).length).toBeGreaterThan(1)
    expect(screen.getByText(/多数可恢复条目的证据不完整/)).toBeTruthy()
    expect(screen.getByText(/WRC-Drill/)).toBeTruthy()
  })
})

describe('CleanupPanel restore-point record age', () => {
  it('warns that an available restore point older than the window may be gone', async () => {
    stubApi(fixtureCleanupLog, status({ timestamp: '2020-01-01T00:00:00Z' }))
    renderWithApp(<CleanupPanel />)

    expect(await screen.findByText(/已超过/)).toBeTruthy()
  })

  it('does not age-warn about a record from this run', async () => {
    stubApi(fixtureCleanupLog, status({}))
    renderWithApp(<CleanupPanel />)

    expect(await screen.findByText(/记录于/)).toBeTruthy()
    expect(screen.queryByText(/已超过/)).toBeNull()
  })
})

describe('CleanupPanel result honesty', () => {
  it('renders a caution line from the stream as caution, not info', async () => {
    vi.stubGlobal('fetch', vi.fn(async (input: unknown) => {
      const url = String((input as RequestInfo))
      if (url.includes('/api/cleanup-log')) return jsonResponse(null, false)
      if (url.includes('/api/backup-status')) return jsonResponse(status({}))
      return sseResponse([
        { type: 'caution', text: '可选系统还原点未建立' },
        { type: 'done', log: fixtureCleanupLog, exit_code: 0 },
      ])
    }))
    const { dispatch } = renderWithApp(<CleanupPanel />)
    dispatch({ type: 'SET_PHASE', phase: 'dry-run' })
    fireEvent.click(screen.getByText('运行 DryRun 预览'))

    const line = await screen.findByText('可选系统还原点未建立')
    expect(line.className).toContain('text-caution')
  })

  it('shows the DD-013 meaning of exit code 11 instead of a plain success', async () => {
    const partialFailure = {
      ...fixtureCleanupLog,
      summary: { ...fixtureCleanupLog.summary, dry_run: false, mode: 'execute', failed: 1, succeeded: 1 },
    }
    vi.stubGlobal('fetch', vi.fn(async (input: unknown) => {
      const url = String((input as RequestInfo))
      if (url.includes('/api/cleanup-log')) return jsonResponse(null, false)
      if (url.includes('/api/backup-status')) return jsonResponse(status({}))
      return sseResponse([{ type: 'done', log: partialFailure, exit_code: 11 }])
    }))
    const { dispatch } = renderWithApp(<CleanupPanel />)
    dispatch({ type: 'SET_PHASE', phase: 'dry-run' })
    fireEvent.click(screen.getByText('运行 DryRun 预览'))

    expect(await screen.findByText(/回滚未完全成功/)).toBeTruthy()
  })

  it('does not report success when the server withheld the exit code', async () => {
    const executed = {
      ...fixtureCleanupLog,
      summary: { ...fixtureCleanupLog.summary, dry_run: false, mode: 'execute' },
    }
    vi.stubGlobal('fetch', vi.fn(async (input: unknown) => {
      const url = String((input as RequestInfo))
      if (url.includes('/api/cleanup-log')) return jsonResponse(null, false)
      if (url.includes('/api/backup-status')) return jsonResponse(status({}))
      return sseResponse([{ type: 'done', log: executed }])
    }))
    const { dispatch } = renderWithApp(<CleanupPanel />)
    dispatch({ type: 'SET_PHASE', phase: 'dry-run' })
    fireEvent.click(screen.getByText('运行 DryRun 预览'))

    expect(await screen.findByText(/退出码未知/)).toBeTruthy()
  })

  it('surfaces a streamed error line instead of hanging on a finished run', async () => {
    vi.stubGlobal('fetch', vi.fn(async (input: unknown) => {
      const url = String((input as RequestInfo))
      if (url.includes('/api/cleanup-log')) return jsonResponse(null, false)
      if (url.includes('/api/backup-status')) return jsonResponse(status({}))
      return sseResponse([{ type: 'error', text: 'clean-residuals.ps1: 前置门禁失败，未删除任何内容' }])
    }))
    const { dispatch } = renderWithApp(<CleanupPanel />)
    dispatch({ type: 'SET_PHASE', phase: 'dry-run' })
    fireEvent.click(screen.getByText('运行 DryRun 预览'))

    const shown = await screen.findAllByText(/前置门禁失败/)
    // console line + error banner: the run must be visibly failed, not just logged
    expect(shown.length).toBeGreaterThan(1)
    expect(screen.queryByText('取消')).toBeNull()
  })
})
