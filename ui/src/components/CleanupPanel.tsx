import { useState, useRef, useEffect } from 'react'
import { useApp, startCleanup, fetchCleanupLog } from '@/hooks/useApp'
import { Button } from './ui/button'
import { Card, CardHeader, CardTitle, CardContent } from './ui/card'
import { Table, TableHeader, TableBody, TableRow, TableHead, TableCell } from './ui/table'
import {
  Play, Eye, CheckCircle2, XCircle, AlertTriangle,
  ClipboardList, RotateCcw, Shield
} from 'lucide-react'
import type { ScanOutputLine, CleanupLog } from '@/types'

export function CleanupPanel() {
  const { state, dispatch } = useApp()
  const [running, setRunning] = useState(false)
  const [lines, setLines] = useState<ScanOutputLine[]>([])
  const [log, setLog] = useState<CleanupLog | null>(state.cleanupLog)
  const [error, setError] = useState<string | null>(null)
  const [showConfirm, setShowConfirm] = useState(false)
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
  }, [])

  const handleRun = (dryRun: boolean) => {
    setRunning(true)
    setLines([])
    setError(null)
    setLog(null)

    const onLine = (line: ScanOutputLine) => {
      setLines(prev => [...prev, line])
    }

    const onDone = (log: CleanupLog) => {
      setRunning(false)
      setLog(log)
      dispatch({ type: 'SET_CLEANUP_LOG', log })
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

    return (
      <div className="space-y-3">
        <div className={`flex items-center gap-2 text-sm p-3 rounded-lg ${
          summary.dry_run ? 'bg-primary/10 text-primary' :
          summary.failed > 0 ? 'bg-caution-bg text-caution' :
          'bg-safe-bg text-safe'
        }`}>
          {summary.dry_run ? <Eye className="w-4 h-4" /> :
           summary.failed > 0 ? <AlertTriangle className="w-4 h-4" /> :
           <CheckCircle2 className="w-4 h-4" />}
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
            {state.phase === 'cleaning' && '正在执行实际删除操作。此操作不可逆，但可通过系统还原点恢复。'}
            {state.phase === 'done' && '清理已完成。以下是清理结果。'}
          </p>

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
                包括文件、目录、注册表键值、服务等。此操作不可逆。
                {log && !log.summary.dry_run && (
                  <span className="block mt-1 text-xs text-caution">
                    请确保已确认 DryRun 结果无误。
                  </span>
                )}
              </p>
              <p className="text-sm">
                已通过系统还原点备份，如需恢复可使用 <code className="text-xs">rollback.ps1</code> 回滚。
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
