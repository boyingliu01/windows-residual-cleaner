import { useState, useRef, useEffect } from 'react'
import { useApp, startCleanup, fetchCleanupLog, fetchBackupStatus } from '@/hooks/useApp'
import { Button } from './ui/button'
import { Card, CardHeader, CardTitle, CardContent } from './ui/card'
import { Table, TableHeader, TableBody, TableRow, TableHead, TableCell } from './ui/table'
import {
  Play, Eye, CheckCircle2, XCircle, AlertTriangle,
  ClipboardList, RotateCcw, Shield, HelpCircle
} from 'lucide-react'
import type { ScanOutputLine, CleanupLog, BackupStatus, LastRollback } from '@/types'

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
  15: { label: '回滚日志落盘失败，已 fail-closed 中止（未做任何删除）', tone: 'danger' },
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
  if (!backup) {
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

  const rp = backup.restore_point
  const pending = backup.precise_protection.newest_unfinished
  const rpTone = rp.state === 'available' ? 'text-safe' : rp.state === 'unavailable' ? 'text-caution' : 'text-muted-foreground'
  const rpLabel = rp.state === 'available' ? '已建立' : rp.state === 'unavailable' ? '未建立' : '状态未知'
  const ageMs = rp.timestamp ? Date.now() - Date.parse(rp.timestamp) : Number.NaN
  const stale = rp.state === 'available' && Number.isFinite(ageMs) && ageMs > backup.recovery_window_hours * 3600_000

  return (
    <div className="space-y-2 p-3 rounded-lg border border-border text-sm">
      <div className="flex items-start gap-2">
        <Shield className="w-4 h-4 mt-0.5 shrink-0 text-primary" />
        <div className="space-y-0.5">
          <div className="font-medium">强制逐项精准保护</div>
          <div className="text-xs text-muted-foreground">{backup.precise_protection.mechanism}</div>
          {backup.precise_protection.unfinished > 0 ? (
            <div className="text-xs text-danger">
              有 {backup.precise_protection.unfinished} 份回滚日志未完成
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
      <div className="flex items-start gap-2">
        <AlertTriangle className={`w-4 h-4 mt-0.5 shrink-0 ${rpTone}`} />
        <div className="space-y-0.5">
          <div className="font-medium">
            可选系统还原点：<span className={rpTone}>{rpLabel}</span>
          </div>
          <div className="text-xs text-muted-foreground">
            {rp.detail}
            {rp.timestamp ? ` · 记录于 ${rp.timestamp}` : ' · 无记录时间'}
            {stale ? ` · 该记录已超过 ${backup.recovery_window_hours} 小时，可能已被系统清理，不要依赖它` : ''}
          </div>
        </div>
      </div>
      <RecoveryBoundaryNote hours={backup.recovery_window_hours} />
      <LastRollbackResult rollback={backup.last_rollback} windowHours={backup.recovery_window_hours} />
    </div>
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
  const failed = rollback.verdicts.filter(v => v.verdict === 'restore_failed')
  const incomplete = rollback.verdicts.filter(v => v.evidence_incomplete && v.verdict !== 'restore_failed')
  const notRestorable = rollback.verdicts.filter(v => v.verdict === 'not_restorable')
  const restored = rollback.verdicts.filter(v => v.verdict === 'restored')
  const lowConfidence = restored.length > 0 && incomplete.length > restored.length / 2

  return (
    <div className="space-y-1 text-xs">
      <div className="font-medium text-sm">上一次自动回滚：{rollback.run_id ?? '未知 run_id'}</div>
      <div className="text-muted-foreground">
        {rollback.executed_at ?? '未知时间'} ·{' '}
        {rollback.within_window ? '本次回滚发生在恢复窗口内。' : `本次回滚已超出 ${windowHours} 小时恢复窗口。`}
        已恢复 {rollback.counts.restored ?? 0} · 已存在 {rollback.counts.already_present ?? 0} ·
        不可恢复 {rollback.counts.not_restorable ?? 0} · 未修复 {rollback.counts.restore_failed ?? 0}
      </div>
      {failed.length > 0 && (
        <div className="text-danger">
          未修复（需人工处理，清单同时写在 output/rollback-unrepaired-*.json）：
          {failed.map((v, i) => <div key={i} className="font-mono">{v.item_id ?? v.target ?? '?'} — {v.reason ?? ''}</div>)}
        </div>
      )}
      {incomplete.length > 0 && (
        <div className="text-caution">
          证据不完整（判定为已恢复，但缺基线/备份证据，需自行判断是否接受）：{incomplete.length} 条
          {incomplete.map((v, i) => <div key={i} className="font-mono">{v.item_id ?? v.target ?? '?'}</div>)}
        </div>
      )}
      {lowConfidence && (
        <div className="text-danger">
          本轮多数可恢复条目的证据不完整 —— 按低置信结果处理，建议人工确认后再继续清理。
        </div>
      )}
      {notRestorable.length > 0 && (
        <div className="text-muted-foreground">
          本就无法自动恢复（如实告知，不计为待修）：{notRestorable.map(v => v.item_id ?? v.target ?? '?').join('、')}
        </div>
      )}
    </div>
  )
}

export function CleanupPanel() {
  const { state, dispatch } = useApp()
  const [running, setRunning] = useState(false)
  const [lines, setLines] = useState<ScanOutputLine[]>([])
  const [log, setLog] = useState<CleanupLog | null>(state.cleanupLog)
  const [exitCode, setExitCode] = useState<number | null | undefined>(undefined)
  const [error, setError] = useState<string | null>(null)
  const [showConfirm, setShowConfirm] = useState(false)
  const [backup, setBackup] = useState<BackupStatus | null>(null)
  const outputRef = useRef<HTMLDivElement>(null)
  const abortRef = useRef<AbortController | null>(null)

  const selectedCount = state.selectedIds.size

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

  const handleRun = (dryRun: boolean) => {
    setRunning(true)
    setLines([])
    setError(null)
    setLog(null)
    setExitCode(undefined)

    const onLine = (line: ScanOutputLine) => {
      setLines(prev => [...prev, line])
    }

    const onDone = (log: CleanupLog, code?: number | null, detail?: string | null) => {
      setRunning(false)
      setLog(log)
      setExitCode(code === undefined ? null : code)
      if (detail) setError(detail)
      dispatch({ type: 'SET_CLEANUP_LOG', log })
      // The on-disk protection evidence changed the moment a journal was written.
      fetchBackupStatus().then(setBackup)
      if (!dryRun) {
        dispatch({ type: 'SET_PHASE', phase: 'done' })
      }
    }

    const onError = (err: string) => {
      setRunning(false)
      setError(err)
    }

    startCleanup(dryRun, onLine, onDone, onError).then(ac => { abortRef.current = ac })
  }

  const handleProceedCleanup = () => {
    setShowConfirm(false)
    handleRun(false)
  }

  const handleCancel = () => {
    if (abortRef.current) {
      abortRef.current.abort()
      setRunning(false)
    }
  }

  const LogSummary = ({ log }: { log: CleanupLog }) => {
    const { summary, entries } = log
    const failedEntries = entries.filter(e => !e.success)
    const code = exitCode
    const meaning = typeof code === 'number' ? EXIT_CODE_MEANING[code] : undefined
    // A success-flavoured code (0) or a missing one never outranks "the log says items
    // failed" (REQ-015); codes 10-15 already carry their own tone from DD-013.
    const base = meaning?.tone ?? 'safe'
    const tone: 'safe' | 'caution' | 'danger' =
      summary.failed > 0 && (code === 0 || code === undefined || code === null || base === 'safe')
        ? 'danger' : base

    return (
      <div className="space-y-3">
        <div className={`flex items-center gap-2 text-sm p-3 rounded-lg ${
          summary.dry_run ? 'bg-primary/10 text-primary' :
          tone === 'danger' ? 'bg-danger-bg text-danger' :
          tone === 'caution' ? 'bg-caution-bg text-caution' :
          'bg-safe-bg text-safe'
        }`}>
          {summary.dry_run ? <Eye className="w-4 h-4" /> :
           tone === 'safe' ? <CheckCircle2 className="w-4 h-4" /> :
           <AlertTriangle className="w-4 h-4" />}
          <span className="font-medium">
            {summary.dry_run ? 'DryRun 预览' : '清理结果'}
          </span>
          <span className="opacity-70">·</span>
          <span className="opacity-80">处理 {summary.total_processed} 项</span>
          <span className="opacity-70">·</span>
          <span className="text-safe">成功 {summary.succeeded}</span>
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
        </div>

        {!summary.dry_run && (
          <div className="text-xs p-2 rounded-lg bg-secondary text-muted-foreground">
            {code === undefined && '退出码未知：服务端未报告结果码，无法判断回滚是否发生。请查看 output/ 下的回滚日志。'}
            {code === null && '退出码未知（进程未正常结束），不能视为成功。'}
            {typeof code === 'number' && (
              <>
                退出码 <code className="text-xs">{code}</code>：
                {meaning ? meaning.label : '未定义的结果码（请查看回滚日志）'}
              </>
            )}
          </div>
        )}

        {failedEntries.length > 0 && (
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
        )}

        {entries.length > 0 && (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead className="w-20">ID</TableHead>
                <TableHead className="w-16">状态</TableHead>
                <TableHead>路径</TableHead>
                <TableHead>操作</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {entries.slice(0, 50).map((entry, i) => (
                <TableRow key={i}>
                  <TableCell><code className="text-xs">{entry.id}</code></TableCell>
                  <TableCell>
                    {entry.success
                      ? <CheckCircle2 className="w-4 h-4 text-safe" />
                      : <XCircle className="w-4 h-4 text-danger" />}
                  </TableCell>
                  <TableCell>
                    <code className="text-xs">{entry.path || entry.key || entry.name || '-'}</code>
                  </TableCell>
                  <TableCell>
                    <span className="text-xs text-muted-foreground">{entry.action}</span>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </div>
    )
  }

  return (
    <div className="max-w-3xl mx-auto space-y-6 animate-slide-in">
      {/* Step indicator */}
      <div className="flex items-center gap-3">
        <div className={`flex items-center gap-2 px-3 py-1.5 rounded-lg text-sm ${
          state.phase === 'dry-run' || state.phase === 'cleaning' || state.phase === 'done'
            ? 'bg-primary/10 text-primary' : 'bg-secondary text-muted-foreground'
        }`}>
          <Eye className="w-4 h-4" />
          DryRun 预览
        </div>
        <div className="h-px flex-1 bg-border" />
        <div className={`flex items-center gap-2 px-3 py-1.5 rounded-lg text-sm ${
          state.phase === 'cleaning' || state.phase === 'done'
            ? 'bg-primary/10 text-primary' : 'bg-secondary text-muted-foreground'
        }`}>
          <Play className="w-4 h-4" />
          执行清理
        </div>
        <div className="h-px flex-1 bg-border" />
        <div className={`flex items-center gap-2 px-3 py-1.5 rounded-lg text-sm ${
          state.phase === 'done' ? 'bg-safe-bg text-safe' : 'bg-secondary text-muted-foreground'
        }`}>
          <CheckCircle2 className="w-4 h-4" />
          完成
        </div>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="flex items-center gap-2">
            <Shield className="w-5 h-5 text-primary" />
            {state.phase === 'dry-run' ? 'DryRun 预览' : state.phase === 'cleaning' ? '执行清理' : '清理状态'}
          </CardTitle>
        </CardHeader>
        <CardContent className="space-y-4">
          <p className="text-sm text-muted-foreground">
            {state.phase === 'dry-run' && '先执行 DryRun 预览，查看将要执行的操作但不实际删除。确认无误后再执行真正的清理。'}
            {state.phase === 'cleaning' && (
              backup?.restore_point.state === 'available'
                ? '正在执行实际删除操作。注册表键值、启动项与 PATH 有逐项精准保护，失败时自动回滚；文件/目录、服务与计划任务的删除不可自动还原。可选系统还原点已建立，但它是尽力而为的最后手段。'
                : `正在执行实际删除操作。注册表键值、启动项与 PATH 有逐项精准保护，失败时自动回滚；文件/目录、服务与计划任务的删除不可自动还原。可选系统还原点${backup?.restore_point.state === 'unknown' ? '状态未知' : '不可用'}，不要指望它兜底。`
            )}
            {state.phase === 'done' && '清理已完成。以下是清理结果。'}
          </p>

          {/* DD-011: real protection state, read from disk — never a blanket promise */}
          <ProtectionStatus backup={backup} />

          {selectedCount > 0 && (
            <div className="flex items-center gap-2 text-sm p-3 rounded-lg bg-secondary">
              <ClipboardList className="w-4 h-4 text-primary" />
              <span>已确认 <strong>{selectedCount}</strong> 个残留项待处理</span>
              <Button
                size="sm"
                variant="ghost"
                onClick={() => dispatch({ type: 'SET_PHASE', phase: 'review' })}
              >
                返回修改
              </Button>
            </div>
          )}

          {/* Output console */}
          {lines.length > 0 && (
            <div
              ref={outputRef}
              className="bg-[#1e1e1e] text-[#d4d4d4] rounded-lg p-3 font-mono text-xs h-40 overflow-y-auto space-y-0.5"
            >
              {lines.map((line, i) => (
                <div key={i} className={`scan-line ${
                  line.type === 'error' ? 'text-danger' :
                  line.type === 'caution' ? 'text-caution font-medium' :
                  line.type === 'success' ? 'text-safe' :
                  line.type === 'step' ? 'text-primary font-medium' :
                  'opacity-70'
                }`}>
                  {line.text}
                </div>
              ))}
            </div>
          )}

          {error && (
            <div className="flex items-start gap-2 p-3 rounded-lg bg-danger-bg text-danger text-sm">
              <XCircle className="w-4 h-4 mt-0.5 shrink-0" />
              <span>{error}</span>
            </div>
          )}

          {/* Results */}
          {log && <LogSummary log={log} />}

          {/* Action buttons */}
          <div className="flex gap-2">
            {!running && state.phase === 'dry-run' && !log && (
              <>
                <Button onClick={() => handleRun(true)}>
                  <Eye className="w-4 h-4" />
                  运行 DryRun 预览
                </Button>
              </>
            )}

            {!running && log?.summary.dry_run && state.phase === 'dry-run' && (
              <>
                <Button variant="outline" onClick={() => handleRun(true)}>
                  <RotateCcw className="w-4 h-4" />
                  重新预览
                </Button>
                {log.summary.failed === 0 && (
                  <Button variant="destructive" onClick={() => setShowConfirm(true)}>
                    <AlertTriangle className="w-4 h-4" />
                    确认执行清理
                  </Button>
                )}
              </>
            )}

            {!running && !log && state.phase === 'done' && (
              <Button variant="outline" onClick={() => dispatch({ type: 'SET_PHASE', phase: 'review' })}>
                <RotateCcw className="w-4 h-4" />
                返回重新选择
              </Button>
            )}

            {running && (
              <Button variant="destructive" onClick={handleCancel}>
                <XCircle className="w-4 h-4" />
                取消
              </Button>
            )}
          </div>
        </CardContent>
      </Card>

      {/* Final confirmation dialog */}
      {showConfirm && (
        <div className="fixed inset-0 z-50 bg-black/40 flex items-center justify-center" onClick={() => setShowConfirm(false)}>
          <Card className="w-full max-w-md mx-4 animate-slide-in" onClick={(e) => e.stopPropagation()}>
            <CardHeader>
              <CardTitle className="flex items-center gap-2">
                <AlertTriangle className="w-5 h-5 text-danger" />
                确认执行清理
              </CardTitle>
            </CardHeader>
            <CardContent className="space-y-3">
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
              {backup?.restore_point.state === 'available' ? (
                <p className="text-sm text-caution">
                  另有一个尽力而为建立的系统还原点，可作为最后手段；
                  它受 24 小时节流与 System Protection 开关影响，<strong>不保证可用</strong>。
                </p>
              ) : (
                <p className="text-sm text-danger">
                  可选系统还原点
                  {(backup?.restore_point.state ?? 'unknown') === 'unknown' ? '状态未知' : '不可用'}
                  {backup ? `：${backup.restore_point.detail}` : '：服务端未提供证据'}。
                  清理仍会进行（强制精准保护承担安全责任），但整机回退这一层没有。
                </p>
              )}
              <p className="text-xs text-muted-foreground">
                如需恢复，请在清理结束后使用 <code className="text-xs">rollback.ps1</code>；
                崩溃后的自动恢复只在下一次启动时执行，且必须在
                {' '}{backup?.recovery_window_hours ?? 24} 小时之内，超时需人工处理。
              </p>
              <div className="flex gap-2 justify-end pt-2">
                <Button variant="outline" onClick={() => setShowConfirm(false)}>取消</Button>
                <Button variant="destructive" onClick={handleProceedCleanup}>
                  确认清理
                </Button>
              </div>
            </CardContent>
          </Card>
        </div>
      )}
    </div>
  )
}
