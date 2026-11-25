import { useApp } from '@/hooks/useApp'
import { Shield, AlertTriangle, CheckCircle, XCircle } from 'lucide-react'
import type { LucideIcon } from 'lucide-react'
import type { ReportSummary } from '@/types/report'

function SummaryMetric({ icon: Icon, label, value, iconClassName = '', valueClassName = '' }: {
  icon: LucideIcon
  label: string
  value: string | number
  iconClassName?: string
  valueClassName?: string
}) {
  return (
    <div className="flex items-center gap-2 text-sm">
      <Icon className={['w-4 h-4', iconClassName].filter(Boolean).join(' ')} />
      <span className="text-muted-foreground">{label}</span>
      <span className={['font-semibold', valueClassName].filter(Boolean).join(' ')}>{value}</span>
    </div>
  )
}

function RecoverableSpace({ summary }: { summary: ReportSummary }) {
  if (summary.estimated_space_recoverable_mb <= 0) return null

  const megabytes = summary.estimated_space_recoverable_mb
  const value = megabytes >= 1024
    ? `${(megabytes / 1024).toFixed(1)} GB`
    : `${Math.round(megabytes)} MB`

  return (
    <>
      <div className="w-px h-5 bg-border" />
      <div className="flex items-center gap-1.5 text-sm">
        <span className="text-muted-foreground">可释放</span>
        <span className="font-semibold">{value}</span>
      </div>
    </>
  )
}

export function SummaryBar() {
  const { state } = useApp()
  const { report } = state

  if (!report) return null

  const { summary } = report
  const selectedCount = state.selectedIds.size

  return (
    <div className="flex items-center gap-3 px-4 py-2.5 bg-card border rounded-lg">
      <SummaryMetric icon={Shield} label="总计" value={summary.total_residuals} iconClassName="text-primary" />
      <div className="w-px h-5 bg-border" />
      <SummaryMetric icon={CheckCircle} label="安全" value={summary.safe} iconClassName="text-safe" valueClassName="text-safe" />
      <div className="w-px h-5 bg-border" />
      <SummaryMetric icon={AlertTriangle} label="警告" value={summary.caution} iconClassName="text-caution" valueClassName="text-caution" />
      <div className="w-px h-5 bg-border" />
      <SummaryMetric icon={XCircle} label="危险" value={summary.danger} iconClassName="text-danger" valueClassName="text-danger" />
      <div className="flex-1" />
      <div className="flex items-center gap-1.5 text-sm">
        <span className="text-muted-foreground">已选择</span>
        <span className="font-semibold text-primary">{selectedCount}</span>
        <span className="text-muted-foreground">项</span>
      </div>
      <RecoverableSpace summary={summary} />
    </div>
  )
}
