import { render, act } from '@testing-library/react'
import { AppProvider, useApp } from '@/hooks/useApp'
import type { CleanupLog, FinalReport } from '@/types'
import type { ReactElement } from 'react'

export const fixtureReport: FinalReport = {
  scan_time: '2026-09-11T00:00:00Z',
  summary: {
    total_residuals: 3,
    safe: 1,
    caution: 1,
    danger: 1,
    estimated_space_recoverable_mb: 1536,
  },
  uninstalled_software: [],
  filesystem_residuals: [
    { id: 'fs_001', path: 'C:/ProgramData/OldApp', size_mb: 1536, file_count: 12, risk: 'safe', reason: 'orphan directory' },
    { id: 'fs_002', path: 'C:/ProgramData/Other', size_mb: 2, file_count: 1, risk: 'danger', reason: 'service dll locked' },
  ],
  registry_residuals: [
    { id: 'reg_001', key: 'HKCU:/Software/OldApp', risk: 'caution', reason: 'uninstall entry missing' },
  ],
  ghost_services: [],
  ghost_tasks: [],
  startup_residuals: [],
  shell_residuals: [],
  path_residuals: [],
}

export const fixtureCleanupLog: CleanupLog = {
  summary: {
    mode: 'dry-run',
    dry_run: true,
    total_processed: 2,
    succeeded: 2,
    failed: 0,
    skipped: 0,
    timestamp: '2026-09-11T00:00:00Z',
  },
  entries: [
    { success: true, id: 'fs_001', path: 'C:/ProgramData/OldApp', action: 'would delete' },
    { success: true, id: 'reg_001', key: 'HKCU:/Software/OldApp', action: 'would delete' },
  ],
}

type AppApi = ReturnType<typeof useApp>
type AppAction = Parameters<AppApi['dispatch']>[0]

/** Renders a component inside AppProvider and exposes the live context value. */
export function renderWithApp(ui: ReactElement | null) {
  const ref: { current: AppApi | null } = { current: null }
  function Probe() {
    ref.current = useApp()
    return null
  }
  const view = render(
    <AppProvider>
      <Probe />
      {ui}
    </AppProvider>,
  )
  const dispatch = (action: AppAction) => {
    act(() => {
      ref.current?.dispatch(action)
    })
  }
  return { ...view, app: ref, dispatch }
}

/** Builds a fetch Response whose body streams NDJSON lines, as the API server does. */
export function sseResponse(lines: unknown[]): Response {
  const enc = new TextEncoder()
  const body = new ReadableStream({
    start(controller) {
      for (const line of lines) controller.enqueue(enc.encode(JSON.stringify(line) + '\n'))
      controller.close()
    },
  })
  return { ok: true, statusText: 'OK', body } as unknown as Response
}

/** JSON fetch Response stub. */
export function jsonResponse(data: unknown, ok = true): Response {
  return { ok, statusText: ok ? 'OK' : 'ERROR', json: async () => data } as unknown as Response
}
