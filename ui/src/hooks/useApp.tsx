import React, { createContext, useContext, useReducer, type ReactNode } from 'react'
import type { FinalReport } from '@/types/report'
import type { CleanupLog } from '@/types/cleanup'
import type { AppPhase, ScanOutputLine } from '@/types/app'
import type { RiskLevel } from '@/types/residual'
import type { BackupStatus } from '@/types/backup'

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

function toggleIds(selected: Set<string>, ids: string[]): Set<string> {
  const next = new Set(selected)
  for (const id of ids) {
    if (next.has(id)) next.delete(id)
    else next.add(id)
  }
  return next
}

type ActionReducer = (state: AppState, action: Action) => AppState

function reduceSelectionToggles(state: AppState, action: Action): AppState {
  switch (action.type) {
    case 'TOGGLE_ID':
      return { ...state, selectedIds: toggleIds(state.selectedIds, [action.id]) }
    case 'TOGGLE_ALL':
      return { ...state, selectedIds: toggleIds(state.selectedIds, action.ids) }
    default:
      return state
  }
}

function reduceSelectionBulk(state: AppState, action: Action): AppState {
  switch (action.type) {
    case 'SELECT_ALL_RISK':
      return { ...state, selectedIds: new Set([...state.selectedIds, ...action.ids]) }
    case 'CLEAR_SELECTION':
      return { ...state, selectedIds: new Set() }
    case 'SET_SELECTED_IDS':
      return { ...state, selectedIds: new Set(action.ids) }
    default:
      return state
  }
}

function reduceSelection(state: AppState, action: Action): AppState {
  switch (action.type) {
    case 'TOGGLE_ID':
    case 'TOGGLE_ALL':
      return reduceSelectionToggles(state, action)
    default:
      return reduceSelectionBulk(state, action)
  }
}

function reduceResultActions(state: AppState, action: Action): AppState {
  switch (action.type) {
    case 'SET_PHASE':
      return { ...state, phase: action.phase }
    case 'SET_REPORT':
      return { ...state, report: action.report }
    case 'SET_CLEANUP_LOG':
      return { ...state, cleanupLog: action.log }
    default:
      return state
  }
}

function reduceScanActions(state: AppState, action: Action): AppState {
  switch (action.type) {
    case 'ADD_SCAN_LINE':
      return { ...state, scanOutput: [...state.scanOutput, action.line] }
    case 'CLEAR_SCAN_OUTPUT':
      return { ...state, scanOutput: [], scanProgress: 0 }
    case 'SET_SCAN_PROGRESS':
      return { ...state, scanProgress: action.progress }
    default:
      return state
  }
}

function reducePreferenceActions(state: AppState, action: Action): AppState {
  switch (action.type) {
    case 'SET_ACTIVE_CATEGORY':
      return { ...state, activeCategory: action.category }
    case 'SET_ERROR':
      return { ...state, error: action.error }
    default:
      return state
  }
}

const actionReducers: Record<Action['type'], ActionReducer> = {
  SET_PHASE: reduceResultActions,
  SET_REPORT: reduceResultActions,
  SET_CLEANUP_LOG: reduceResultActions,
  ADD_SCAN_LINE: reduceScanActions,
  CLEAR_SCAN_OUTPUT: reduceScanActions,
  SET_SCAN_PROGRESS: reduceScanActions,
  SET_ACTIVE_CATEGORY: reducePreferenceActions,
  SET_ERROR: reducePreferenceActions,
  TOGGLE_ID: reduceSelection,
  TOGGLE_ALL: reduceSelection,
  SELECT_ALL_RISK: reduceSelection,
  CLEAR_SELECTION: reduceSelection,
  SET_SELECTED_IDS: reduceSelection,
}

function appReducer(state: AppState, action: Action): AppState {
  return actionReducers[action.type](state, action)
}

interface AppContextValue {
  state: AppState
  dispatch: React.Dispatch<Action>
  allItemIds: string[]
}

const AppContext = createContext<AppContextValue | null>(null)

const REPORT_ITEM_CATEGORIES = [
  'filesystem_residuals',
  'registry_residuals',
  'ghost_services',
  'ghost_tasks',
  'startup_residuals',
  'shell_residuals',
  'path_residuals',
] as const

function appendItemIds(ids: string[], items: ReadonlyArray<{ id?: string }>): void {
  for (const item of items) {
    if (item.id) ids.push(item.id)
  }
}

function appendActionableIds(ids: string[], items: ReadonlyArray<{ id?: string; actionable?: boolean }>): void {
  for (const item of items) {
    if (item.actionable && item.id) ids.push(item.id)
  }
}

function collectAllItemIds(report: FinalReport | null): string[] {
  if (!report) return []
  const ids: string[] = []
  for (const category of REPORT_ITEM_CATEGORIES) appendItemIds(ids, report[category] ?? [])
  appendActionableIds(ids, report.uninstalled_software ?? [])
  return ids
}

export function AppProvider({ children }: { children: ReactNode }) {
  const [state, dispatch] = useReducer(appReducer, initialState)

  const allItemIds = React.useMemo(() => collectAllItemIds(state.report), [state.report])

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

interface StreamPayload {
  type?: ScanOutputLine['type']
  text?: string
  timestamp?: number
  report?: FinalReport
  log?: CleanupLog
  exit_code?: number | null
  detail?: string | null
}

interface StreamHandlers {
  onLine: (line: ScanOutputLine) => void
  onDone: (parsed: StreamPayload) => void
  onError: (err: string) => void
  failPrefix: string
  readPrefix: string
  fallbackMessage: string
}

type LineHandlers = Pick<StreamHandlers, 'onLine' | 'onDone' | 'onError'>

function emitParsedLine(parsed: StreamPayload, line: string, handlers: LineHandlers): void {
  const type = parsed.type || 'info'
  const text = parsed.text || line
  handlers.onLine({ text, type, timestamp: parsed.timestamp || Date.now() })
  if (parsed.type === 'done') handlers.onDone(parsed)
  if (type === 'error') handlers.onError(text)
}

function consumeStreamLine(line: string, handlers: LineHandlers): void {
  if (!line.trim()) return
  try {
    const parsed = JSON.parse(line) as StreamPayload
    emitParsedLine(parsed, line, handlers)
  } catch {
    handlers.onLine({ text: line, type: 'info', timestamp: Date.now() })
  }
}

function createLineConsumer(handlers: LineHandlers) {
  return (line: string) => consumeStreamLine(line, handlers)
}

function consumeCompleteLines(buffer: string, consume: (line: string) => void): string {
  const lines = buffer.split('\n')
  buffer = lines.pop() || ''
  for (const line of lines) consume(line)
  return buffer
}

async function readResponseBody(res: Response, handlers: StreamHandlers): Promise<void> {
  const reader = res.body?.getReader()
  if (!reader) {
    handlers.onError(handlers.readPrefix)
    return
  }
  const decoder = new TextDecoder()
  const consume = createLineConsumer(handlers)
  let buffer = ''
  for (;;) {
    const { done, value } = await reader.read()
    if (done) break
    buffer = consumeCompleteLines(buffer + decoder.decode(value, { stream: true }), consume)
  }
  buffer += decoder.decode()
  consume(buffer)
}

function handleStreamError(err: unknown, handlers: StreamHandlers): void {
  if (err instanceof Error && err.name === 'AbortError') return
  handlers.onError(err instanceof Error ? err.message : handlers.fallbackMessage)
}

async function streamNDJSON(url: string, init: RequestInit, handlers: StreamHandlers): Promise<void> {
  try {
    const res = await fetch(url, init)
    if (!res.ok) {
      handlers.onError(`${handlers.failPrefix}: ${res.statusText}`)
      return
    }
    await readResponseBody(res, handlers)
  } catch (err) {
    handleStreamError(err, handlers)
  }
}

export function startScan(onLine: (line: ScanOutputLine) => void, onDone: (report: FinalReport) => void, onError: (err: string) => void): AbortController {
  const controller = new AbortController()

  void streamNDJSON(`${API_BASE}/scan`, {
    method: 'POST',
    signal: controller.signal,
  }, {
    onLine,
    onError,
    failPrefix: '扫描失败',
    readPrefix: '无法读取扫描输出',
    fallbackMessage: '扫描过程中出错',
    onDone: (parsed) => {
      if (parsed.report) onDone(parsed.report)
    },
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

export async function startCleanup(dryRun: boolean, onLine: (line: ScanOutputLine) => void, onDone: (log: CleanupLog, exitCode?: number | null, detail?: string | null) => void, onError: (err: string) => void): Promise<AbortController> {
  const controller = new AbortController()

  void streamNDJSON(`${API_BASE}/cleanup`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ dryRun }),
    signal: controller.signal,
  }, {
    onLine,
    onError,
    failPrefix: '清理失败',
    readPrefix: '无法读取清理输出',
    fallbackMessage: '清理过程中出错',
    onDone: (parsed) => {
      if (!parsed.log) return
      // null 与 0 含义不同：0 是「脚本报告成功」，null 是「服务端没告诉我们」，
      // 后者绝不能显示成成功（诚实口径与 AC-065 同源）。
      onDone(parsed.log, typeof parsed.exit_code === 'number' ? parsed.exit_code : null, typeof parsed.detail === 'string' ? parsed.detail : null)
    },
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

export async function fetchBackupStatus(): Promise<BackupStatus | null> {
  try {
    const res = await fetch(`${API_BASE}/backup-status`)
    if (!res.ok) return null
    return await res.json()
  } catch {
    return null
  }
}
