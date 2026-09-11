import React, { createContext, useContext, useReducer, type ReactNode } from 'react'
import type { FinalReport, CleanupLog, AppPhase, ScanOutputLine, RiskLevel } from '@/types'

interface AppState {
  phase: AppPhase
  report: FinalReport | null
  cleanupLog: CleanupLog | null
  scanOutput: ScanOutputLine[]
  scanProgress: number
  selectedIds: Set<string>
  activeCategory: string
  error: string | null
}

type Action =
  | { type: 'SET_PHASE'; phase: AppPhase }
  | { type: 'SET_REPORT'; report: FinalReport }
  | { type: 'SET_CLEANUP_LOG'; log: CleanupLog }
  | { type: 'ADD_SCAN_LINE'; line: ScanOutputLine }
  | { type: 'CLEAR_SCAN_OUTPUT' }
  | { type: 'SET_SCAN_PROGRESS'; progress: number }
  | { type: 'TOGGLE_ID'; id: string }
  | { type: 'TOGGLE_ALL'; ids: string[] }
  | { type: 'SELECT_ALL_RISK'; risk: RiskLevel; ids: string[] }
  | { type: 'CLEAR_SELECTION' }
  | { type: 'SET_ACTIVE_CATEGORY'; category: string }
  | { type: 'SET_ERROR'; error: string | null }
  | { type: 'SET_SELECTED_IDS'; ids: string[] }

const initialState: AppState = {
  phase: 'idle',
  report: null,
  cleanupLog: null,
  scanOutput: [],
  scanProgress: 0,
  selectedIds: new Set(),
  activeCategory: 'all',
  error: null,
}

function appReducer(state: AppState, action: Action): AppState {
  switch (action.type) {
    case 'SET_PHASE':
      return { ...state, phase: action.phase }
    case 'SET_REPORT':
      return { ...state, report: action.report }
    case 'SET_CLEANUP_LOG':
      return { ...state, cleanupLog: action.log }
    case 'ADD_SCAN_LINE':
      return { ...state, scanOutput: [...state.scanOutput, action.line] }
    case 'CLEAR_SCAN_OUTPUT':
      return { ...state, scanOutput: [], scanProgress: 0 }
    case 'SET_SCAN_PROGRESS':
      return { ...state, scanProgress: action.progress }
    case 'TOGGLE_ID': {
      const next = new Set(state.selectedIds)
      if (next.has(action.id)) next.delete(action.id)
      else next.add(action.id)
      return { ...state, selectedIds: next }
    }
    case 'TOGGLE_ALL': {
      const next = new Set(state.selectedIds)
      for (const id of action.ids) {
        if (next.has(id)) next.delete(id)
        else next.add(id)
      }
      return { ...state, selectedIds: next }
    }
    case 'SELECT_ALL_RISK': {
      const next = new Set(state.selectedIds)
      for (const id of action.ids) next.add(id)
      return { ...state, selectedIds: next }
    }
    case 'CLEAR_SELECTION':
      return { ...state, selectedIds: new Set() }
    case 'SET_ACTIVE_CATEGORY':
      return { ...state, activeCategory: action.category }
    case 'SET_ERROR':
      return { ...state, error: action.error }
    case 'SET_SELECTED_IDS':
      return { ...state, selectedIds: new Set(action.ids) }
    default:
      return state
  }
}

interface AppContextValue {
  state: AppState
  dispatch: React.Dispatch<Action>
  allItemIds: string[]
}

const AppContext = createContext<AppContextValue | null>(null)

export function AppProvider({ children }: { children: ReactNode }) {
  const [state, dispatch] = useReducer(appReducer, initialState)

  const allItemIds = React.useMemo(() => {
    if (!state.report) return []
    const ids: string[] = []
    for (const key of ['filesystem_residuals', 'registry_residuals', 'ghost_services', 'ghost_tasks', 'startup_residuals', 'shell_residuals', 'path_residuals'] as const) {
      for (const item of (state.report as any)[key] || []) {
        if (item.id) ids.push(item.id)
      }
    }
    return ids
  }, [state.report])

  return (
    <AppContext.Provider value={{ state, dispatch, allItemIds }}>
      {children}
    </AppContext.Provider>
  )
}

export function useApp() {
  const ctx = useContext(AppContext)
  if (!ctx) throw new Error('useApp must be used within AppProvider')
  return ctx
}

// API helpers
const API_BASE = '/api'

export async function fetchReport(): Promise<FinalReport | null> {
  try {
    const res = await fetch(`${API_BASE}/report`)
    if (!res.ok) return null
    return await res.json()
  } catch {
    return null
  }
}

export function startScan(onLine: (line: ScanOutputLine) => void, onDone: (report: FinalReport) => void, onError: (err: string) => void): AbortController {
  const controller = new AbortController()

  fetch(`${API_BASE}/scan`, {
    method: 'POST',
    signal: controller.signal,
  }).then(async (res) => {
    if (!res.ok) {
      onError(`扫描失败: ${res.statusText}`)
      return
    }
    const reader = res.body?.getReader()
    if (!reader) {
      onError('无法读取扫描输出')
      return
    }

    const decoder = new TextDecoder()
    let buffer = ''

    for (;;) {
      const { done, value } = await reader.read()
      if (done) break

      buffer += decoder.decode(value, { stream: true })
      const lines = buffer.split('\n')
      buffer = lines.pop() || ''

      for (const line of lines) {
        if (!line.trim()) continue
        try {
          const parsed = JSON.parse(line)
          onLine({
            text: parsed.text || line,
            type: parsed.type || 'info',
            timestamp: parsed.timestamp || Date.now(),
          })
          if (parsed.type === 'done' && parsed.report) {
            onDone(parsed.report)
          }
        } catch {
          onLine({ text: line, type: 'info', timestamp: Date.now() })
        }
      }
    }
  }).catch((err) => {
    if (err.name !== 'AbortError') {
      onError(err.message || '扫描过程中出错')
    }
  })

  return controller
}

export async function confirmCleanup(ids: string[]): Promise<boolean> {
  try {
    const res = await fetch(`${API_BASE}/confirm`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ ids }),
    })
    return res.ok
  } catch {
    return false
  }
}

export async function startCleanup(dryRun: boolean, onLine: (line: ScanOutputLine) => void, onDone: (log: any) => void, onError: (err: string) => void): Promise<AbortController> {
  const controller = new AbortController()

  fetch(`${API_BASE}/cleanup`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ dryRun }),
    signal: controller.signal,
  }).then(async (res) => {
    if (!res.ok) {
      onError(`清理失败: ${res.statusText}`)
      return
    }
    const reader = res.body?.getReader()
    if (!reader) {
      onError('无法读取清理输出')
      return
    }

    const decoder = new TextDecoder()
    let buffer = ''

    for (;;) {
      const { done, value } = await reader.read()
      if (done) break

      buffer += decoder.decode(value, { stream: true })
      const lines = buffer.split('\n')
      buffer = lines.pop() || ''

      for (const line of lines) {
        if (!line.trim()) continue
        try {
          const parsed = JSON.parse(line)
          onLine({
            text: parsed.text || line,
            type: parsed.type || 'info',
            timestamp: parsed.timestamp || Date.now(),
          })
          if (parsed.type === 'done' && parsed.log) {
            onDone(parsed.log)
          }
        } catch {
          onLine({ text: line, type: 'info', timestamp: Date.now() })
        }
      }
    }
  }).catch((err) => {
    if (err.name !== 'AbortError') {
      onError(err.message || '清理过程中出错')
    }
  })

  return controller
}

export async function fetchCleanupLog(): Promise<CleanupLog | null> {
  try {
    const res = await fetch(`${API_BASE}/cleanup-log`)
    if (!res.ok) return null
    return await res.json()
  } catch {
    return null
  }
}

export async function checkRestorePoint(): Promise<boolean> {
  try {
    const res = await fetch(`${API_BASE}/restore-point`)
    return res.ok
  } catch {
    return false
  }
}
