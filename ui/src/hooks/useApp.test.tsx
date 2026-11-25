import { describe, expect, it, vi, afterEach } from 'vitest'
import { render } from '@testing-library/react'
import { fixtureReport, fixtureCleanupLog, renderWithApp, sseResponse, jsonResponse } from '@/test'
import type { FinalReport } from '@/types/report'
import { useApp, confirmCleanup, fetchBackupStatus, startCleanup, startScan } from './useApp'

function chunkedResponse(chunks: Uint8Array[]): Response {
  const body = new ReadableStream({
    start(controller) {
      for (const chunk of chunks) controller.enqueue(chunk)
      controller.close()
    },
  })
  return { ok: true, statusText: 'OK', body } as unknown as Response
}

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('app reducer', () => {
  it('toggles a selected id on and off', () => {
    const { app, dispatch } = renderWithApp(null)
    dispatch({ type: 'TOGGLE_ID', id: 'fs_001' })
    expect(app.current?.state.selectedIds.has('fs_001')).toBe(true)
    dispatch({ type: 'TOGGLE_ID', id: 'fs_001' })
    expect(app.current?.state.selectedIds.has('fs_001')).toBe(false)
  })

  it('selects all ids of a risk level and keeps existing selection', () => {
    const { app, dispatch } = renderWithApp(null)
    dispatch({ type: 'TOGGLE_ID', id: 'fs_001' })
    dispatch({ type: 'SELECT_ALL_RISK', risk: 'caution', ids: ['reg_001', 'fs_001'] })
    expect(app.current?.state.selectedIds.has('reg_001')).toBe(true)
    expect(app.current?.state.selectedIds.has('fs_001')).toBe(true)
  })

  it('clears selection and stores errors', () => {
    const { app, dispatch } = renderWithApp(null)
    dispatch({ type: 'TOGGLE_ID', id: 'fs_001' })
    dispatch({ type: 'CLEAR_SELECTION' })
    expect(app.current?.state.selectedIds.size).toBe(0)
    dispatch({ type: 'SET_ERROR', error: 'boom' })
    expect(app.current?.state.error).toBe('boom')
  })

  it('preserves every non-selection action domain', () => {
    const { app, dispatch } = renderWithApp(null)
    dispatch({ type: 'SET_PHASE', phase: 'scanning' })
    dispatch({ type: 'SET_CLEANUP_LOG', log: fixtureCleanupLog })
    dispatch({ type: 'ADD_SCAN_LINE', line: { text: 'scanning', type: 'step', timestamp: 1 } })
    dispatch({ type: 'SET_SCAN_PROGRESS', progress: 50 })
    dispatch({ type: 'SET_ACTIVE_CATEGORY', category: 'filesystem' })
    expect(app.current?.state.phase).toBe('scanning')
    expect(app.current?.state.cleanupLog).toBe(fixtureCleanupLog)
    expect(app.current?.state.scanOutput).toEqual([{ text: 'scanning', type: 'step', timestamp: 1 }])
    expect(app.current?.state.scanProgress).toBe(50)
    expect(app.current?.state.activeCategory).toBe('filesystem')

    dispatch({ type: 'CLEAR_SCAN_OUTPUT' })
    expect(app.current?.state.scanOutput).toEqual([])
    expect(app.current?.state.scanProgress).toBe(0)
  })

  it('supports bulk toggles and replacing the selected ids', () => {
    const { app, dispatch } = renderWithApp(null)
    dispatch({ type: 'TOGGLE_ALL', ids: ['fs_001', 'reg_001'] })
    expect(app.current?.state.selectedIds).toEqual(new Set(['fs_001', 'reg_001']))
    dispatch({ type: 'SET_SELECTED_IDS', ids: ['fs_002'] })
    expect(app.current?.state.selectedIds).toEqual(new Set(['fs_002']))
  })

  it('collects all item ids from every report category', () => {
    const { app, dispatch } = renderWithApp(null)
    dispatch({ type: 'SET_REPORT', report: fixtureReport })
    expect(app.current?.allItemIds).toEqual(['fs_001', 'fs_002', 'reg_001'])
  })

  it('collects existing ids when legacy report categories are missing', () => {
    const legacyReport = { ...fixtureReport } as FinalReport
    delete (legacyReport as Partial<FinalReport>).ghost_tasks
    delete (legacyReport as Partial<FinalReport>).uninstalled_software
    const { app, dispatch } = renderWithApp(null)

    expect(() => dispatch({ type: 'SET_REPORT', report: legacyReport })).not.toThrow()
    expect(app.current?.allItemIds).toEqual(['fs_001', 'fs_002', 'reg_001'])
  })

  it('includes only actionable uninstalled software ids', () => {
    const { app, dispatch } = renderWithApp(null)
    const uninstalled = {
      id: 'uni_001',
      name: 'Old App',
      registry_key: 'HKCU:/Software/OldApp',
      install_location: '',
      uninstall_string: '',
      evidence: [],
      source: 'HKCU',
      actionable: true,
      risk: 'caution' as const,
      reason: 'uninstall entry missing',
    }
    dispatch({
      type: 'SET_REPORT',
      report: {
        ...fixtureReport,
        uninstalled_software: [uninstalled, { ...uninstalled, id: 'uni_002', actionable: false }],
      },
    })
    expect(app.current?.allItemIds).toEqual(['fs_001', 'fs_002', 'reg_001', 'uni_001'])
  })
})

describe('useApp guard', () => {
  it('throws when used outside AppProvider', () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    function Naked() {
      useApp()
      return null
    }
    expect(() => render(<Naked />)).toThrow('useApp must be used within AppProvider')
    spy.mockRestore()
  })
})

describe('confirmCleanup', () => {
  it('returns true when the API accepts the ids', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: true } as Response)))
    await expect(confirmCleanup(['fs_001'])).resolves.toBe(true)
  })

  it('returns false when the API rejects or the request fails', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: false } as Response)))
    await expect(confirmCleanup(['fs_001'])).resolves.toBe(false)
    vi.stubGlobal('fetch', vi.fn(async () => { throw new Error('network down') }))
    await expect(confirmCleanup(['fs_001'])).resolves.toBe(false)
  })
})

describe('fetchBackupStatus', () => {
  it('returns the parsed status when the server answers', async () => {
    const payload = { restore_point: { state: 'unavailable' }, recovery_window_hours: 24 }
    vi.stubGlobal('fetch', vi.fn(async () => jsonResponse(payload)))
    await expect(fetchBackupStatus()).resolves.toEqual(payload)
  })

  it('returns null rather than guessing when the route fails or the network dies', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse({}, false))
      .mockRejectedValueOnce(new Error('offline'))
    vi.stubGlobal('fetch', fetchMock)
    await expect(fetchBackupStatus()).resolves.toBeNull()
    await expect(fetchBackupStatus()).resolves.toBeNull()
    expect(fetchMock).toHaveBeenCalledTimes(2)
    expect(fetchMock).toHaveBeenNthCalledWith(1, '/api/backup-status')
    expect(fetchMock).toHaveBeenNthCalledWith(2, '/api/backup-status')
  })
})

describe('startCleanup result channel', () => {
  const log = { summary: { dry_run: false, failed: 0 }, entries: [] }
  // The stream is consumed by a detached async loop, so a macrotask boundary is
  // needed before the callbacks are observable.
  const flush = async () => { for (let i = 0; i < 5; i++) await new Promise(r => setTimeout(r, 0)) }

  it('passes the exit code and detail through so 10..15 stay distinguishable', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => sseResponse([{ type: 'done', log, exit_code: 11, detail: 'rollback incomplete' }])))
    const codes: unknown[] = []
    const controller = await startCleanup(false, () => {}, (l, code, detail) => codes.push([l, code, detail]), () => {})
    await flush()
    controller.abort()
    expect(codes).toEqual([[log, 11, 'rollback incomplete']])
  })

  it('reports null, not 0, when the server never told us the code', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => sseResponse([{ type: 'done', log }])))
    const codes: unknown[] = []
    const controller = await startCleanup(false, () => {}, (_l, code) => codes.push(code), () => {})
    await flush()
    controller.abort()
    expect(codes).toEqual([null])
  })

  it('routes a streamed error line to onError so the caller stops spinning', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => sseResponse([
      { type: 'info', text: '正在删除' },
      { type: 'error', text: '前置门禁失败，未删除任何内容' },
    ])))
    const errors: string[] = []
    const lines: string[] = []
    const controller = await startCleanup(false, l => lines.push(l.text), () => {}, e => errors.push(e))
    await flush()
    controller.abort()
    expect(errors).toEqual(['前置门禁失败，未删除任何内容'])
    expect(lines).toContain('前置门禁失败，未删除任何内容')
  })
})

describe('startScan stream framing', () => {
  const settle = async () => { for (let i = 0; i < 5; i++) await new Promise(r => setTimeout(r, 0)) }

  it('consumes a final record without a trailing newline', async () => {
    const payload = JSON.stringify({ type: 'done', report: fixtureReport })
    vi.stubGlobal('fetch', vi.fn(async () => chunkedResponse([new TextEncoder().encode(payload)])))
    const done = vi.fn()
    const controller = startScan(() => {}, done, () => {})
    await settle()
    controller.abort()
    expect(done).toHaveBeenCalledWith(fixtureReport)
  })

  it('preserves records and multibyte text split at every byte boundary', async () => {
    const bytes = new TextEncoder().encode(
      `${JSON.stringify({ type: 'step', text: '正在扫描系统残留' })}\n` +
      `${JSON.stringify({ type: 'done', report: fixtureReport })}\n`,
    )
    vi.stubGlobal('fetch', vi.fn(async () => chunkedResponse([...bytes].map(byte => Uint8Array.of(byte)))))
    const lines: string[] = []
    const done = vi.fn()
    const controller = startScan(l => lines.push(l.text), done, () => {})
    await settle()
    controller.abort()
    expect(lines.filter(line => line === '正在扫描系统残留')).toEqual(['正在扫描系统残留'])
    expect(lines.some(line => line.includes('\uFFFD'))).toBe(false)
    expect(done).toHaveBeenCalledWith(fixtureReport)
  })

  it('skips blank lines and exposes malformed records as console output', async () => {
    const payload = `\nnot-json\n${JSON.stringify({ type: 'done', report: fixtureReport })}`
    vi.stubGlobal('fetch', vi.fn(async () => chunkedResponse([new TextEncoder().encode(payload)])))
    const lines: string[] = []
    const done = vi.fn()
    const controller = startScan(l => lines.push(l.text), done, () => {})
    await settle()
    controller.abort()
    expect(lines).toContain('not-json')
    expect(lines).toContain(JSON.stringify({ type: 'done', report: fixtureReport }))
    expect(lines).toHaveLength(2)
    expect(done).toHaveBeenCalledWith(fixtureReport)
  })

  it('reports HTTP, missing-body and network failures without claiming completion', async () => {
    const done = vi.fn()
    const errors: string[] = []
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: false, statusText: 'Forbidden' } as Response)))
    startScan(() => {}, done, e => errors.push(e)).abort()
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: true } as Response)))
    startScan(() => {}, done, e => errors.push(e)).abort()
    vi.stubGlobal('fetch', vi.fn(async () => { throw new Error('offline') }))
    startScan(() => {}, done, e => errors.push(e)).abort()
    await settle()
    expect(errors).toEqual(['扫描失败: Forbidden', '无法读取扫描输出', 'offline'])
    expect(done).not.toHaveBeenCalled()
  })
  it('uses the fallback for non-Error failures and ignores aborts', async () => {
    const done = vi.fn()
    const errors: string[] = []
    vi.stubGlobal('fetch', vi.fn()
      .mockRejectedValueOnce('offline')
      .mockRejectedValueOnce(Object.assign(new Error('aborted'), { name: 'AbortError' })))
    startScan(() => {}, done, e => errors.push(e)).abort()
    startScan(() => {}, done, e => errors.push(e)).abort()
    await settle()
    expect(errors).toEqual(['扫描过程中出错'])
    expect(done).not.toHaveBeenCalled()
  })
})

describe('startScan error channel', () => {
  it('forwards a streamed error line to onError while keeping it in the console', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => sseResponse([
      { type: 'step', text: '正在生成最终报告...' },
      { type: 'caution', text: '可选系统还原点未建立' },
      { type: 'error', text: 'run-all.ps1: Process exited with code 2' },
    ])))
    const errors: string[] = []
    const lines: string[] = []
    const done = vi.fn()
    const controller = startScan(l => lines.push(l.text), done, e => errors.push(e))
    for (let i = 0; i < 5; i++) await new Promise(r => setTimeout(r, 0))
    controller.abort()
    expect(errors).toEqual(['run-all.ps1: Process exited with code 2'])
    expect(lines).toContain('可选系统还原点未建立')
    expect(done).not.toHaveBeenCalled()
  })
})
