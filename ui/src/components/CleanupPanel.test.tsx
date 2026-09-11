import { describe, expect, it, vi, afterEach } from 'vitest'
import { fireEvent, screen } from '@testing-library/react'
import { fixtureCleanupLog, renderWithApp, sseResponse } from '@/test'
import { CleanupPanel } from './CleanupPanel'

afterEach(() => {
  vi.unstubAllGlobals()
})

function stubCleanupApi(doneLog: unknown) {
  vi.stubGlobal('fetch', vi.fn(async (input: unknown) => {
    const url = String((input as RequestInfo))
    if (url.includes('/api/cleanup-log')) {
      return { ok: true, statusText: 'OK', json: async () => null } as unknown as Response
    }
    return sseResponse([{ type: 'done', log: doneLog }])
  }))
}

describe('CleanupPanel', () => {
  it('runs a dry-run from the streamed output and offers the real cleanup', async () => {
    stubCleanupApi(fixtureCleanupLog)
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
    stubCleanupApi(failedLog)
    const { dispatch } = renderWithApp(<CleanupPanel />)
    dispatch({ type: 'SET_PHASE', phase: 'dry-run' })

    fireEvent.click(screen.getByText('运行 DryRun 预览'))

    expect(await screen.findByText('删除失败的项：')).toBeTruthy()
    expect(screen.getByText(/\[fs_002\].*access denied/)).toBeTruthy()
  })
})
