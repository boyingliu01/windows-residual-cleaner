import { useApp } from '@/hooks/useApp'
import { Shield, AlertTriangle, CheckCircle, XCircle } from 'lucide-react'

export function SummaryBar() {
  const { state } = useApp()
  const { report } = state

  if (!report) return null

  const { summary } = report
  const selectedCount = state.selectedIds.size

  return (
    <div className="flex items-center gap-3 px-4 py-2.5 bg-card border rounded-lg">
      <div className="flex items-center gap-2 text-sm">
        <Shield className="w-4 h-4 text-primary" />
        <span className="text-muted-foreground">总计</span>
        <span className="font-semibold">{summary.total_residuals}</span>
      </div>

      <div className="w-px h-5 bg-border" />

      <div className="flex items-center gap-2 text-sm">
        <CheckCircle className="w-4 h-4 text-safe" />
        <span className="text-muted-foreground">安全</span>
        <span className="font-semibold text-safe">{summary.safe}</span>
      </div>

      <div className="w-px h-5 bg-border" />

      <div className="flex items-center gap-2 text-sm">
        <AlertTriangle className="w-4 h-4 text-caution" />
        <span className="text-muted-foreground">警告</span>
        <span className="font-semibold text-caution">{summary.caution}</span>
      </div>

      <div className="w-px h-5 bg-border" />

      <div className="flex items-center gap-2 text-sm">
        <XCircle className="w-4 h-4 text-danger" />
        <span className="text-muted-foreground">危险</span>
        <span className="font-semibold text-danger">{summary.danger}</span>
      </div>

      <div className="flex-1" />

      <div className="flex items-center gap-1.5 text-sm">
        <span className="text-muted-foreground">已选择</span>
        <span className="font-semibold text-primary">{selectedCount}</span>
        <span className="text-muted-foreground">项</span>
      </div>

      {summary.estimated_space_recoverable_mb > 0 && (
        <>
          <div className="w-px h-5 bg-border" />
          <div className="flex items-center gap-1.5 text-sm">
            <span className="text-muted-foreground">可释放</span>
            <span className="font-semibold">
              {summary.estimated_space_recoverable_mb >= 1024
                ? `${(summary.estimated_space_recoverable_mb / 1024).toFixed(1)} GB`
                : `${Math.round(summary.estimated_space_recoverable_mb)} MB`}
            </span>
          </div>
        </>
      )}
    </div>
  )
}
