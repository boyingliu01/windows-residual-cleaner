import { describe, expect, it, vi, afterEach } from 'vitest'
import { render } from '@testing-library/react'
import { fixtureReport, renderWithApp, sseResponse, jsonResponse } from '@/test'
import { useApp, confirmCleanup, fetchBackupStatus, startCleanup, startScan } from './useApp'

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

  it('collects all item ids from every report category', () => {
    const { app, dispatch } = renderWithApp(null)
    dispatch({ type: 'SET_REPORT', report: fixtureReport })
    expect(app.current?.allItemIds).toEqual(['fs_001', 'fs_002', 'reg_001'])
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
    vi.stubGlobal('fetch', vi.fn(async () => jsonResponse({}, false)))
    await expect(fetchBackupStatus()).resolves.toBeNull()
    vi.stubGlobal('fetch', vi.fn(async () => { throw new Error('offline') }))
    await expect(fetchBackupStatus()).resolves.toBeNull()
  })
})

describe('startCleanup result channel', () => {
  const log = { summary: { dry_run: false, failed: 0 }, entries: [] }
  // The stream is consumed by a detached async loop, so a macrotask boundary is
  // needed before the callbacks are observable.
  const flush = async () => { for (let i = 0; i < 5; i++) await new Promise(r => setTimeout(r, 0)) }

  it('passes the exit code through so 10..15 stay distinguishable', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => sseResponse([{ type: 'done', log, exit_code: 11 }])))
    const codes: unknown[] = []
    const controller = await startCleanup(false, () => {}, (l, code) => codes.push([l, code]), () => {})
    await flush()
    controller.abort()
    expect(codes).toEqual([[log, 11]])
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
