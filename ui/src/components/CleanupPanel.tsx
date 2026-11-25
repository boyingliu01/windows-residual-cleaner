import { useState, useRef, useEffect, type Dispatch, type ReactNode, type RefObject, type SetStateAction } from 'react'
import { useApp, startCleanup, fetchCleanupLog, fetchBackupStatus } from '@/hooks/useApp'
import { Button } from './ui/button'
import { Card, CardHeader, CardTitle, CardContent } from './ui/card'
import { Table, TableHeader, TableBody, TableRow, TableHead, TableCell } from './ui/table'
import {
  Play, Eye, CheckCircle2, XCircle, AlertTriangle,
  ClipboardList, RotateCcw, Shield, HelpCircle
} from 'lucide-react'
import type { AppPhase, ScanOutputLine } from '@/types/app'
import type { CleanupLog, CleanupLogEntry } from '@/types/cleanup'
import type { BackupStatus, LastRollback, RollbackVerdict } from '@/types/backup'

/**
 * DD-013 exit-code matrix. The cleanup script's own summary cannot express
 * "partially failed but fully rolled back" vs "still damaged", so the code is the
 * only machine-readable signal the server hands us — rendering it as a bare
 * "完成" would erase REQ-025's whole point.
 */
const EXIT_CODE_MEANING: Record<number, { label: string; tone: 'safe' | 'caution' | 'danger' }> = {
  0: { label: '全部成功', tone: 'safe' },
  1: { label: '输入或前置错误', tone: 'danger' },
  2: { label: '权限错误：需要管理员权限', tone: 'danger' },
  3: { label: '依赖文件缺失', tone: 'danger' },
  10: { label: '清理部分失败，回滚已把受影响项完全恢复', tone: 'caution' },
  11: { label: '清理部分失败，且回滚未完全成功 —— 系统可能仍处于不一致状态', tone: 'danger' },
  12: { label: '清理部分失败，且没有可回滚的记录', tone: 'danger' },
  13: { label: '清理部分失败，自动回滚已被 -NoAutoRollback 显式关闭', tone: 'danger' },
  14: { label: '上一轮崩溃遗留的恢复未完全成功，本轮未开始', tone: 'danger' },
  15: { label: '回滚日志或清理日志持久化失败，可能仍有未恢复改动', tone: 'danger' },
}
const MAX_LOG_ENTRIES = 50

type CleanupAction = Parameters<ReturnType<typeof useApp>['dispatch']>[0]
type LogTone = 'safe' | 'caution' | 'danger'

interface CleanupEffects {
  outputRef: RefObject<HTMLDivElement>
  lines: ScanOutputLine[]
  setLog: Dispatch<SetStateAction<CleanupLog | null>>
  setBackup: Dispatch<SetStateAction<BackupStatus | null>>
}

function useCleanupEffects({ outputRef, lines, setLog, setBackup }: CleanupEffects) {
  useEffect(() => {
    if (outputRef.current) {
      outputRef.current.scrollTop = outputRef.current.scrollHeight
    }
  }, [lines])

  useEffect(() => {
    // Load existing log, but never clobber a log set by an in-flight run
    fetchCleanupLog().then(l => setLog(prev => prev ?? l))
    fetchBackupStatus().then(setBackup)
  }, [])
}

function useCleanupState(initialLog: CleanupLog | null) {
  const [running, setRunning] = useState(false)
  const [lines, setLines] = useState<ScanOutputLine[]>([])
  const [log, setLog] = useState<CleanupLog | null>(initialLog)
  const [exitCode, setExitCode] = useState<number | null | undefined>(undefined)
  const [error, setError] = useState<string | null>(null)
  const [showConfirm, setShowConfirm] = useState(false)
  const [backup, setBackup] = useState<BackupStatus | null>(null)
  const outputRef = useRef<HTMLDivElement>(null)
  const abortRef = useRef<AbortController | null>(null)
  useCleanupEffects({ outputRef, lines, setLog, setBackup })
  return {
    running, setRunning, lines, setLines, log, setLog, exitCode, setExitCode,
    error, setError, showConfirm, setShowConfirm, backup, setBackup, outputRef, abortRef,
  }
}

function useCleanupActions(run: ReturnType<typeof useCleanupState>, dispatch: Dispatch<CleanupAction>) {
  const { setRunning, setLines, setLog, setExitCode, setError, setBackup, abortRef } = run
  const handleRun = (dryRun: boolean) => {
    setRunning(true)
    setLines([])
    setError(null)
    setLog(null)
    setExitCode(undefined)
    const onLine = (line: ScanOutputLine) => setLines(prev => [...prev, line])
    const onDone = (log: CleanupLog, code?: number | null, detail?: string | null) => {
      setRunning(false)
      setLog(log)
      setExitCode(code === undefined ? null : code)
      if (detail) setError(detail)
      dispatch({ type: 'SET_CLEANUP_LOG', log })
      // The on-disk protection evidence changed the moment a journal was written.
      fetchBackupStatus().then(setBackup)
      if (!dryRun) dispatch({ type: 'SET_PHASE', phase: 'done' })
    }
    const onError = (err: string) => {
      setRunning(false)
      setError(err)
    }
    startCleanup(dryRun, onLine, onDone, onError).then(ac => { abortRef.current = ac })
  }
  const handleProceedCleanup = () => {
    run.setShowConfirm(false)
    handleRun(false)
  }
  const handleCancel = () => {
    if (abortRef.current) {
      abortRef.current.abort()
      setRunning(false)
    }
  }
  const returnToReview = () => dispatch({ type: 'SET_PHASE', phase: 'review' })
  return { handleRun, handleProceedCleanup, handleCancel, returnToReview }
}

function useCleanupRun() {
  const { state, dispatch } = useApp()
  const run = useCleanupState(state.cleanupLog)
  const actions = useCleanupActions(run, dispatch)
  return {
    state, phase: state.phase, selectedCount: state.selectedIds.size, ...run, ...actions,
    onRun: actions.handleRun, onCancel: actions.handleCancel, onReturnToReview: actions.returnToReview,
  }
}

function UnknownProtectionStatus() {
  return (
    <div className="flex items-start gap-2 p-3 rounded-lg bg-secondary text-muted-foreground text-sm">
      <HelpCircle className="w-4 h-4 mt-0.5 shrink-0" />
      <span>
        保护状态未知：服务端未能提供备份证据（/api/backup-status 不可用）。
        此处不假定任何一层保护已就绪。
      </span>
    </div>
  )
}

function PreciseProtectionStatus({ backup }: { backup: BackupStatus }) {
  const { precise_protection: protection } = backup
  const pending = protection.newest_unfinished
  return (
    <div className="flex items-start gap-2">
      <Shield className="w-4 h-4 mt-0.5 shrink-0 text-primary" />
      <div className="space-y-0.5">
        <div className="font-medium">强制逐项精准保护</div>
        <div className="text-xs text-muted-foreground">{protection.mechanism}</div>
        {protection.unfinished > 0 ? (
          <div className="text-xs text-danger">
            有 {protection.unfinished} 份回滚日志未完成
            {pending?.run_id ? `（最近：${pending.run_id}，${pending.entries} 项）` : ''}
            —— 上一轮清理可能未恢复，下次启动时才会尝试恢复。
          </div>
        ) : (
          <div className="text-xs text-muted-foreground">
            本轮日志在第一次删除之前写入；写不进去时清理直接中止，不会留下无保护的变化。
          </div>
        )}
      </div>
    </div>
  )
}

function getRestorePointPresentation(state: BackupStatus['restore_point']['state']) {
  const states = {
    available: { tone: 'text-safe', label: '已建立' },
    unavailable: { tone: 'text-caution', label: '未建立' },
    unknown: { tone: 'text-muted-foreground', label: '状态未知' },
  }
  return states[state]
}

function getRestorePointAge(backup: BackupStatus): number {
  return backup.restore_point.timestamp ? Date.now() - Date.parse(backup.restore_point.timestamp) : Number.NaN
}

function getRestorePointMeta(backup: BackupStatus) {
  const rp = backup.restore_point
  const ageMs = getRestorePointAge(backup)
  const stale = rp.state === 'available'
    && Number.isFinite(ageMs)
    && ageMs > backup.recovery_window_hours * 3600_000
  return { rp, ...getRestorePointPresentation(rp.state), stale }
}

function RestorePointSummary({ backup }: { backup: BackupStatus }) {
  const { rp, tone, label, stale } = getRestorePointMeta(backup)
  return (
    <div className="flex items-start gap-2">
      <AlertTriangle className={`w-4 h-4 mt-0.5 shrink-0 ${tone}`} />
      <div className="space-y-0.5">
        <div className="font-medium">
          可选系统还原点：<span className={tone}>{label}</span>
        </div>
        <div className="text-xs text-muted-foreground">
          {rp.detail}
          {rp.timestamp ? ` · 记录于 ${rp.timestamp}` : ' · 无记录时间'}
          {stale ? ` · 该记录已超过 ${backup.recovery_window_hours} 小时，可能已被系统清理，不要依赖它` : ''}
        </div>
      </div>
    </div>
  )
}

/** AC-065 / REQ-016: never promise unconditional automatic recovery. */
export function RecoveryBoundaryNote({ hours }: { hours: number }) {
  return (
    <p className="text-xs text-muted-foreground">
      崩溃或断电后的自动恢复只发生在 <strong>{hours} 小时内</strong>的下一次启动；
      超时后需手动运行 <code className="text-xs">rollback.ps1</code>。
      文件/目录、服务与计划任务的删除始终<strong>无法自动还原</strong>（精准保护覆盖注册表键值、启动项与 PATH）。
    </p>
  )
}

export function ProtectionStatus({ backup }: { backup: BackupStatus | null }) {
  if (!backup) return <UnknownProtectionStatus />
  return (
    <div className="space-y-2 p-3 rounded-lg border border-border text-sm">
      <PreciseProtectionStatus backup={backup} />
      <RestorePointSummary backup={backup} />
      <RecoveryBoundaryNote hours={backup.recovery_window_hours} />
      <LastRollbackResult rollback={backup.last_rollback} windowHours={backup.recovery_window_hours} />
    </div>
  )
}

function getRollbackGroups(rollback: LastRollback) {
  const failed = rollback.verdicts.filter(v => v.verdict === 'restore_failed')
  const incomplete = rollback.verdicts.filter(v => v.evidence_incomplete && v.verdict !== 'restore_failed')
  const notRestorable = rollback.verdicts.filter(v => v.verdict === 'not_restorable')
  const restored = rollback.verdicts.filter(v => v.verdict === 'restored')
  const lowConfidence = restored.length > 0 && incomplete.length > restored.length / 2
  return { failed, incomplete, notRestorable, lowConfidence }
}

function verdictTarget(verdict: RollbackVerdict): string {
  return verdict.item_id ?? verdict.target ?? '?'
}

function RollbackFailedItems({ items }: { items: RollbackVerdict[] }) {
  if (items.length === 0) return null
  return (
    <div className="text-danger">
      未修复（需人工处理，清单同时写在 output/rollback-unrepaired-*.json）：
      {items.map((v, i) => <div key={i} className="font-mono">{verdictTarget(v)} — {v.reason ?? ''}</div>)}
    </div>
  )
}

function RollbackIncompleteItems({ items }: { items: RollbackVerdict[] }) {
  if (items.length === 0) return null
  return (
    <div className="text-caution">
      证据不完整（判定为已恢复，但缺基线/备份证据，需自行判断是否接受）：{items.length} 条
      {items.map((v, i) => <div key={i} className="font-mono">{verdictTarget(v)}</div>)}
    </div>
  )
}

function RollbackNotRestorableItems({ items }: { items: RollbackVerdict[] }) {
  if (items.length === 0) return null
  return (
    <div className="text-muted-foreground">
      本就无法自动恢复（如实告知，不计为待修）：{items.map(verdictTarget).join('、')}
    </div>
  )
}

function RollbackCounts({ counts }: { counts: LastRollback['counts'] }) {
  return (
    <>
      已恢复 {counts.restored ?? 0} · 已存在 {counts.already_present ?? 0} ·
      不可恢复 {counts.not_restorable ?? 0} · 未修复 {counts.restore_failed ?? 0}
    </>
  )
}

function RollbackWindow({ rollback, windowHours }: { rollback: LastRollback, windowHours: number }) {
  return rollback.within_window
    ? '本次回滚发生在恢复窗口内。'
    : `本次回滚已超出 ${windowHours} 小时恢复窗口。`
}

function RollbackSummaryMeta({ rollback, windowHours }: { rollback: LastRollback, windowHours: number }) {
  return (
    <>
      <div className="font-medium text-sm">上一次自动回滚：{rollback.run_id ?? '未知 run_id'}</div>
      <div className="text-muted-foreground">
        {rollback.executed_at ?? '未知时间'} · <RollbackWindow rollback={rollback} windowHours={windowHours} />
        <RollbackCounts counts={rollback.counts} />
      </div>
    </>
  )
}

export function LastRollbackResult({ rollback, windowHours }: { rollback: LastRollback | null, windowHours: number }) {
  if (!rollback) {
    return (
      <p className="text-xs text-muted-foreground">
        盘上没有 rollback-result.json —— 上一轮从未回滚，或结果文件未能写出。
      </p>
    )
  }
  const { failed, incomplete, notRestorable, lowConfidence } = getRollbackGroups(rollback)
  return (
    <div className="space-y-1 text-xs">
      <RollbackSummaryMeta rollback={rollback} windowHours={windowHours} />
      <RollbackFailedItems items={failed} />
      <RollbackIncompleteItems items={incomplete} />
      {lowConfidence && (
        <div className="text-danger">
          本轮多数可恢复条目的证据不完整 —— 按低置信结果处理，建议人工确认后再继续清理。
        </div>
      )}
      <RollbackNotRestorableItems items={notRestorable} />
    </div>
  )
}

function getExitMeaning(code: number | null | undefined) {
  return typeof code === 'number' ? EXIT_CODE_MEANING[code] : undefined
}

function hasUnreportedFailure(summary: CleanupLog['summary'], code: number | null | undefined, base: LogTone): boolean {
  const missingOrSuccessfulCode = code === 0 || code === undefined || code === null
  return summary.failed > 0 && (missingOrSuccessfulCode || base === 'safe')
}

function getLogTone(summary: CleanupLog['summary'], entries: CleanupLogEntry[], code: number | null | undefined): LogTone {
  // A success-flavoured code (0) or a missing one never outranks "the log says items
  // failed" (REQ-015); codes 10-15 already carry their own tone from DD-013.
  const base = getExitMeaning(code)?.tone ?? 'safe'
  if (hasUnreportedFailure(summary, code, base)) return 'danger'
  return base === 'safe' && entries.some(isDeferredRename) ? 'caution' : base
}

function getLogBannerClass(summary: CleanupLog['summary'], tone: LogTone): string {
  if (summary.dry_run) return 'bg-primary/10 text-primary'
  const toneClasses: Record<LogTone, string> = {
    safe: 'bg-safe-bg text-safe',
    caution: 'bg-caution-bg text-caution',
    danger: 'bg-danger-bg text-danger',
  }
  return toneClasses[tone]
}

function LogBannerIcon({ summary, tone }: { summary: CleanupLog['summary'], tone: LogTone }) {
  if (summary.dry_run) return <Eye className="w-4 h-4" />
  return tone === 'safe' ? <CheckCircle2 className="w-4 h-4" /> : <AlertTriangle className="w-4 h-4" />
}

function isDeferredRename(entry: CleanupLogEntry): boolean {
  return entry.action === 'path_renamed'
}

function LogSummaryCounts({ summary, entries }: { summary: CleanupLog['summary'], entries: CleanupLogEntry[] }) {
  const renamedCount = entries.filter(isDeferredRename).length
  const succeeded = Math.max(0, summary.succeeded - renamedCount)
  return (
    <>
      <span className="opacity-70">·</span>
      <span className="opacity-80">处理 {summary.total_processed} 项</span>
      <span className="opacity-70">·</span>
      <span className="text-safe">成功 {succeeded}</span>
      {renamedCount > 0 && (
        <>
          <span className="opacity-70">·</span>
          <span className="text-caution">改名未删除 {renamedCount}</span>
        </>
      )}
      {summary.failed > 0 && (
        <>
          <span className="opacity-70">·</span>
          <span className="text-danger">失败 {summary.failed}</span>
        </>
      )}
      {summary.skipped > 0 && (
        <>
          <span className="opacity-70">·</span>
          <span className="opacity-60">跳过 {summary.skipped}</span>
        </>
      )}
    </>
  )
}

function LogSummaryBanner({ summary, entries, tone }: { summary: CleanupLog['summary'], entries: CleanupLogEntry[], tone: LogTone }) {
  return (
    <div className={`flex items-center gap-2 text-sm p-3 rounded-lg ${getLogBannerClass(summary, tone)}`}>
      <LogBannerIcon summary={summary} tone={tone} />
      <span className="font-medium">{summary.dry_run ? 'DryRun 预览' : '清理结果'}</span>
      <LogSummaryCounts summary={summary} entries={entries} />
    </div>
  )
}

function getUnknownExitMessage(code: number | null | undefined): string | null {
  if (code === undefined) {
    return '退出码未知：服务端未报告结果码，无法判断回滚是否发生。请查看 output/ 下的回滚日志。'
  }
  if (code === null) return '退出码未知（进程未正常结束），不能视为成功。'
  return null
}

function LogExitCodeMessage({ code, deferredRename }: { code: number | null | undefined, deferredRename: boolean }) {
  const unknownMessage = getUnknownExitMessage(code)
  if (unknownMessage) return unknownMessage
  if (code === 0 && deferredRename) {
    return '退出码 0：存在改名未删除项，内容仍在磁盘，需等待重启删除或人工处理。'
  }
  const meaning = getExitMeaning(code)
  return <>退出码 <code className="text-xs">{code}</code>：{meaning?.label ?? '未定义的结果码（请查看回滚日志）'}</>
}

function LogExitCode({ code, deferredRename }: { code: number | null | undefined, deferredRename: boolean }) {
  return (
    <div className="text-xs p-2 rounded-lg bg-secondary text-muted-foreground">
      <LogExitCodeMessage code={code} deferredRename={deferredRename} />
    </div>
  )
}

function LogFailedEntries({ entries }: { entries: CleanupLogEntry[] }) {
  const failedEntries = entries.filter(e => !e.success)
  if (failedEntries.length === 0) return null
  return (
    <div className="p-3 rounded-lg bg-danger-bg text-sm">
      <div className="font-medium text-danger mb-2">删除失败的项：</div>
      <ul className="space-y-1">
        {failedEntries.map((e, i) => (
          <li key={i} className="text-xs text-danger/80 font-mono">
            [{e.id}] {e.path || e.key || e.name} — {e.error || '未知错误'}
          </li>
        ))}
      </ul>
    </div>
  )
}

function LogEntryStatus({ entry }: { entry: CleanupLogEntry }) {
  if (isDeferredRename(entry)) return <span className="text-xs text-caution">已改名，未删除</span>
  if (entry.success) return <CheckCircle2 className="w-4 h-4 text-safe" />
  return <XCircle className="w-4 h-4 text-danger" />
}

function getLogTarget(entry: CleanupLogEntry): string {
  return entry.path || entry.key || entry.name || '-'
}

function CleanupLogTable({ entries }: { entries: CleanupLogEntry[] }) {
  if (entries.length === 0) return null
  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead className="w-20">ID</TableHead>
          <TableHead className="w-32">状态</TableHead>
          <TableHead>路径</TableHead>
          <TableHead>操作</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {entries.slice(0, MAX_LOG_ENTRIES).map((entry, i) => (
          <TableRow key={i}>
            <TableCell><code className="text-xs">{entry.id}</code></TableCell>
            <TableCell><LogEntryStatus entry={entry} /></TableCell>
            <TableCell>
              <code className="text-xs">{getLogTarget(entry)}</code>
            </TableCell>
            <TableCell>
              <span className="text-xs text-muted-foreground">{entry.action}</span>
            </TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  )
}

function LogSummary({ log, exitCode }: { log: CleanupLog, exitCode: number | null | undefined }) {
  const deferredRename = log.entries.some(isDeferredRename)
  const tone = getLogTone(log.summary, log.entries, exitCode)
  return (
    <div className="space-y-3">
      <LogSummaryBanner summary={log.summary} entries={log.entries} tone={tone} />
      {!log.summary.dry_run && <LogExitCode code={exitCode} deferredRename={deferredRename} />}
      <LogFailedEntries entries={log.entries} />
      <CleanupLogTable entries={log.entries} />
    </div>
  )
}

function getLineClassName(type: ScanOutputLine['type']): string {
  return `scan-line ${
    type === 'error' ? 'text-danger' :
    type === 'caution' ? 'text-caution font-medium' :
    type === 'success' ? 'text-safe' :
    type === 'step' ? 'text-primary font-medium' :
    'opacity-70'
  }`
}

function CleanupOutput({ lines, outputRef }: { lines: ScanOutputLine[], outputRef: RefObject<HTMLDivElement> }) {
  if (lines.length === 0) return null
  return (
    <div
      ref={outputRef}
      className="bg-[#1e1e1e] text-[#d4d4d4] rounded-lg p-3 font-mono text-xs h-40 overflow-y-auto space-y-0.5"
    >
      {lines.map((line, i) => (
        <div key={i} className={getLineClassName(line.type)}>
          {line.text}
        </div>
      ))}
    </div>
  )
}

function CleanupError({ error }: { error: string | null }) {
  if (!error) return null
  return (
    <div className="flex items-start gap-2 p-3 rounded-lg bg-danger-bg text-danger text-sm">
      <XCircle className="w-4 h-4 mt-0.5 shrink-0" />
      <span>{error}</span>
    </div>
  )
}

function CleanupStep({ icon, label, active, tone = 'primary' }: {
  icon: ReactNode, label: string, active: boolean, tone?: 'primary' | 'safe'
}) {
  const stateClass = active
    ? tone === 'safe' ? 'bg-safe-bg text-safe' : 'bg-primary/10 text-primary'
    : 'bg-secondary text-muted-foreground'
  return (
    <div className={`flex items-center gap-2 px-3 py-1.5 rounded-lg text-sm ${stateClass}`}>
      {icon}
      {label}
    </div>
  )
}

function StepConnector() {
  return <div className="h-px flex-1 bg-border" />
}

function CleanupStepIndicator({ phase }: { phase: AppPhase }) {
  return (
    <div className="flex items-center gap-3">
      <CleanupStep icon={<Eye className="w-4 h-4" />} label="DryRun 预览" active={phase !== 'idle' && phase !== 'scanning' && phase !== 'review'} />
      <StepConnector />
      <CleanupStep icon={<Play className="w-4 h-4" />} label="执行清理" active={phase === 'cleaning' || phase === 'done'} />
      <StepConnector />
      <CleanupStep icon={<CheckCircle2 className="w-4 h-4" />} label="完成" active={phase === 'done'} tone="safe" />
    </div>
  )
}

function getCleaningMessage(backup: BackupStatus | null): string {
  const protection = '正在执行实际删除操作。注册表键值、启动项与 PATH 有逐项精准保护，失败时自动回滚；文件/目录、服务与计划任务的删除不可自动还原。'
  if (backup?.restore_point.state === 'available') {
    return `${protection}可选系统还原点已建立，但它是尽力而为的最后手段。`
  }
  const state = backup?.restore_point.state === 'unknown' ? '状态未知' : '不可用'
  return `${protection}可选系统还原点${state}，不要指望它兜底。`
}

function getPhaseMessage(phase: AppPhase, backup: BackupStatus | null): string {
  if (phase === 'dry-run') return '先执行 DryRun 预览，查看将要执行的操作但不实际删除。确认无误后再执行真正的清理。'
  if (phase === 'cleaning') return getCleaningMessage(backup)
  return '清理已完成。以下是清理结果。'
}

function CleanupPhaseMessage({ phase, backup }: { phase: AppPhase, backup: BackupStatus | null }) {
  return <p className="text-sm text-muted-foreground">{getPhaseMessage(phase, backup)}</p>
}

function CleanupSelectionNotice({ selectedCount, onReturnToReview }: {
  selectedCount: number, onReturnToReview: () => void
}) {
  if (selectedCount === 0) return null
  return (
    <div className="flex items-center gap-2 text-sm p-3 rounded-lg bg-secondary">
      <ClipboardList className="w-4 h-4 text-primary" />
      <span>已确认 <strong>{selectedCount}</strong> 个残留项待处理</span>
      <Button size="sm" variant="ghost" onClick={onReturnToReview}>
        返回修改
      </Button>
    </div>
  )
}

interface CleanupActionsProps {
  phase: AppPhase
  running: boolean
  log: CleanupLog | null
  onRun: (dryRun: boolean) => void
  onConfirm: () => void
  onCancel: () => void
  onReturnToReview: () => void
}

function InitialCleanupActions({ phase, log, onRun }: Pick<CleanupActionsProps, 'phase' | 'log' | 'onRun'>) {
  if (phase !== 'dry-run' || log) return null
  return (
    <Button onClick={() => onRun(true)}>
      <Eye className="w-4 h-4" />
      运行 DryRun 预览
    </Button>
  )
}

function PreviewCleanupActions({ phase, log, onRun, onConfirm }: Pick<CleanupActionsProps, 'phase' | 'log' | 'onRun' | 'onConfirm'>) {
  if (phase !== 'dry-run' || !log?.summary.dry_run) return null
  return (
    <>
      <Button variant="outline" onClick={() => onRun(true)}>
        <RotateCcw className="w-4 h-4" />
        重新预览
      </Button>
      {log.summary.failed === 0 && (
        <Button variant="destructive" onClick={onConfirm}>
          <AlertTriangle className="w-4 h-4" />
          确认执行清理
        </Button>
      )}
    </>
  )
}

function CompletedCleanupActions({ phase, log, onReturnToReview }: Pick<CleanupActionsProps, 'phase' | 'log' | 'onReturnToReview'>) {
  if (phase !== 'done' || log) return null
  return (
    <Button variant="outline" onClick={onReturnToReview}>
      <RotateCcw className="w-4 h-4" />
      返回重新选择
    </Button>
  )
}

function RunningCleanupAction({ running, onCancel }: Pick<CleanupActionsProps, 'running' | 'onCancel'>) {
  if (!running) return null
  return (
    <Button variant="destructive" onClick={onCancel}>
      <XCircle className="w-4 h-4" />
      取消
    </Button>
  )
}

function CleanupActions({ phase, running, log, onRun, onConfirm, onCancel, onReturnToReview }: CleanupActionsProps) {
  return (
    <div className="flex gap-2">
      {!running && <InitialCleanupActions phase={phase} log={log} onRun={onRun} />}
      {!running && <PreviewCleanupActions phase={phase} log={log} onRun={onRun} onConfirm={onConfirm} />}
      {!running && <CompletedCleanupActions phase={phase} log={log} onReturnToReview={onReturnToReview} />}
      <RunningCleanupAction running={running} onCancel={onCancel} />
    </div>
  )
}

interface CleanupPanelCardProps extends CleanupActionsProps {
  selectedCount: number
  backup: BackupStatus | null
  lines: ScanOutputLine[]
  error: string | null
  exitCode: number | null | undefined
  outputRef: RefObject<HTMLDivElement>
}

function CleanupPanelCard(props: CleanupPanelCardProps) {
  const { phase, backup, selectedCount, lines, error, log, exitCode, outputRef } = props
  const title = phase === 'dry-run' ? 'DryRun 预览' : phase === 'cleaning' ? '执行清理' : '清理状态'
  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-2">
          <Shield className="w-5 h-5 text-primary" />
          {title}
        </CardTitle>
      </CardHeader>
      <CardContent className="space-y-4">
        <CleanupPhaseMessage phase={phase} backup={backup} />
        {/* DD-011: real protection state, read from disk — never a blanket promise */}
        <ProtectionStatus backup={backup} />
        <CleanupSelectionNotice selectedCount={selectedCount} onReturnToReview={props.onReturnToReview} />
        {/* Output console */}
        <CleanupOutput lines={lines} outputRef={outputRef} />
        <CleanupError error={error} />
        {/* Results */}
        {log && <LogSummary log={log} exitCode={exitCode} />}
        {/* Action buttons */}
        <CleanupActions {...props} />
      </CardContent>
    </Card>
  )
}

function RestorePointConfirmation({ backup }: { backup: BackupStatus | null }) {
  if (backup?.restore_point.state === 'available') {
    return (
      <p className="text-sm text-caution">
        另有一个尽力而为建立的系统还原点，可作为最后手段；
        它受 24 小时节流与 System Protection 开关影响，<strong>不保证可用</strong>。
      </p>
    )
  }
  return (
    <p className="text-sm text-danger">
      可选系统还原点
      {(backup?.restore_point.state ?? 'unknown') === 'unknown' ? '状态未知' : '不可用'}
      {backup ? `：${backup.restore_point.detail}` : '：服务端未提供证据'}。
      清理仍会进行（强制精准保护承担安全责任），但整机回退这一层没有。
    </p>
  )
}

interface CleanupConfirmationContentProps {
  backup: BackupStatus | null
  log: CleanupLog | null
  onCancel: () => void
  onConfirm: () => void
}

function CleanupConfirmationContent({ backup, log, onCancel, onConfirm }: CleanupConfirmationContentProps) {
  return (
    <>
      <p className="text-sm text-muted-foreground">
        此操作将<strong className="text-foreground">永久删除</strong>所选残留项，
        包括文件、目录、注册表键值、服务等。
        <span className="block mt-1">
          删除后不保证可逆：注册表键值、启动项与 PATH 由本轮逐项精准保护覆盖，
          清理失败时自动回滚；<strong className="text-foreground">文件/目录、服务与计划任务无法自动还原</strong>。
        </span>
        {log && !log.summary.dry_run && (
          <span className="block mt-1 text-xs text-caution">
            请确保已确认 DryRun 结果无误。
          </span>
        )}
      </p>
      {/* AC-013 / AC-023: the sentence below must never claim a restore point
          that the disk does not prove exists. */}
      <RestorePointConfirmation backup={backup} />
      <p className="text-xs text-muted-foreground">
        如需恢复，请在清理结束后使用 <code className="text-xs">rollback.ps1</code>；
        崩溃后的自动恢复只在下一次启动时执行，且必须在
        {' '}{backup?.recovery_window_hours ?? 24} 小时之内，超时需人工处理。
      </p>
      <div className="flex gap-2 justify-end pt-2">
        <Button variant="outline" onClick={onCancel}>取消</Button>
        <Button variant="destructive" onClick={onConfirm}>
          确认清理
        </Button>
      </div>
    </>
  )
}

function CleanupConfirmationDialog({ show, backup, log, onCancel, onConfirm }: CleanupConfirmationContentProps & { show: boolean }) {
  if (!show) return null
  return (
    <div className="fixed inset-0 z-50 bg-black/40 flex items-center justify-center" onClick={onCancel}>
      <Card className="w-full max-w-md mx-4 animate-slide-in" onClick={(e) => e.stopPropagation()}>
        <CardHeader>
          <CardTitle className="flex items-center gap-2">
            <AlertTriangle className="w-5 h-5 text-danger" />
            确认执行清理
          </CardTitle>
        </CardHeader>
        <CardContent className="space-y-3">
          <CleanupConfirmationContent backup={backup} log={log} onCancel={onCancel} onConfirm={onConfirm} />
        </CardContent>
      </Card>
    </div>
  )
}

export function CleanupPanel() {
  const run = useCleanupRun()
  const cancelConfirmation = () => run.setShowConfirm(false)
  return (
    <div className="max-w-3xl mx-auto space-y-6 animate-slide-in">
      {/* Step indicator */}
      <CleanupStepIndicator phase={run.state.phase} />
      <CleanupPanelCard {...run} onConfirm={() => run.setShowConfirm(true)} />
      {/* Final confirmation dialog */}
      <CleanupConfirmationDialog
        show={run.showConfirm}
        backup={run.backup}
        log={run.log}
        onCancel={cancelConfirmation}
        onConfirm={run.handleProceedCleanup}
      />
    </div>
  )
}
