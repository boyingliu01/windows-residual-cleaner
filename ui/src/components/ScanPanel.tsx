import { useRef, useEffect, useState } from 'react'
import type { RefObject } from 'react'
import { useApp, startScan, fetchReport } from '@/hooks/useApp'
import { Button } from './ui/button'
import { Card, CardHeader, CardTitle, CardContent } from './ui/card'
import { Shield, Play, Loader2, CheckCircle2, XCircle, FileText, type LucideIcon } from 'lucide-react'
import type { FinalReport } from '@/types/report'
import type { ScanOutputLine } from '@/types/app'

const SCAN_STEPS = [
  '正在创建系统还原点...',
  '正在构建已安装软件索引...',
  '正在扫描已卸载残留...',
  '正在扫描文件系统残留...',
  '正在扫描注册表/服务/任务残留...',
  '正在生成最终报告...',
]

type ScanStepState = 'completed' | 'active' | 'pending'

const SCAN_STEP_STYLES: Record<ScanStepState, { badge: string; label: string }> = {
  completed: { badge: 'bg-safe text-white', label: 'text-safe' },
  active: { badge: 'bg-primary text-white', label: 'text-foreground font-medium' },
  pending: { badge: 'bg-secondary text-muted-foreground', label: 'text-muted-foreground' },
}
const SCAN_STEP_ICONS: Record<ScanStepState, LucideIcon | null> = {
  completed: CheckCircle2,
  active: Loader2,
  pending: null,
}

function getScanStepState(index: number, currentStep: number, scanning: boolean): ScanStepState {
  if (index < currentStep) return 'completed'
  if (index === currentStep && scanning) return 'active'
  return 'pending'
}

function ScanStepIcon({ state, index }: { state: ScanStepState; index: number }) {
  const Icon = SCAN_STEP_ICONS[state]
  if (!Icon) return index + 1
  const className = state === 'active' ? 'w-3.5 h-3.5 animate-spin' : 'w-3.5 h-3.5'
  return <Icon className={className} />
}

function ScanStep({ label, index, currentStep, scanning }: {
  label: string; index: number; currentStep: number; scanning: boolean
}) {
  const state = getScanStepState(index, currentStep, scanning)
  const styles = SCAN_STEP_STYLES[state]
  return (
    <div className="flex items-center gap-3 text-sm">
      <div className={`w-6 h-6 rounded-full flex items-center justify-center text-xs font-medium shrink-0 ${styles.badge}`}>
        <ScanStepIcon state={state} index={index} />
      </div>
      <span className={styles.label}>{label}</span>
    </div>
  )
}

function ScanSteps({ currentStep, scanning }: { currentStep: number; scanning: boolean }) {
  return (
    <div className="space-y-2">
      {SCAN_STEPS.map((step, index) => (
        <ScanStep key={index} label={step} index={index} currentStep={currentStep} scanning={scanning} />
      ))}
    </div>
  )
}

function ScanOutput({ lines, outputRef }: {
  lines: ScanOutputLine[]
  outputRef: RefObject<HTMLDivElement>
}) {
  if (lines.length === 0) return null

  return (
    <div
      ref={outputRef}
      className="bg-[#1e1e1e] text-[#d4d4d4] rounded-lg p-3 font-mono text-xs h-48 overflow-y-auto space-y-0.5"
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
  )
}

function ScanError({ error }: { error: string | null }) {
  if (!error) return null

  return (
    <div className="flex items-start gap-2 p-3 rounded-lg bg-danger-bg text-danger text-sm">
      <XCircle className="w-4 h-4 mt-0.5 shrink-0" />
      <span>{error}</span>
    </div>
  )
}

function ScanActions({ scanning, reportLoaded, onScan, onCancel, onLoad }: {
  scanning: boolean
  reportLoaded: boolean
  onScan: () => void
  onCancel: () => void
  onLoad: () => void
}) {
  return (
    <div className="flex gap-2">
      {!scanning ? (
        <>
          <Button onClick={onScan} size="lg">
            <Play className="w-4 h-4" />
            开始扫描
          </Button>
          <Button variant="outline" onClick={onLoad} disabled={reportLoaded}>
            <FileText className="w-4 h-4" />
            {reportLoaded ? '报告已加载' : '加载已有报告'}
          </Button>
        </>
      ) : (
        <Button variant="destructive" onClick={onCancel}>
          <XCircle className="w-4 h-4" />
          取消扫描
        </Button>
      )}
    </div>
  )
}

function ExistingReport({ report, onReview }: { report: FinalReport; onReview: () => void }) {
  return (
    <Card>
      <CardContent className="p-4 flex items-center gap-2 text-sm">
        <CheckCircle2 className="w-4 h-4 text-safe" />
        <span>已有扫描报告，共 <strong>{report.summary.total_residuals}</strong> 个残留项</span>
        <div className="flex-1" />
        <Button size="sm" variant="outline" onClick={onReview}>
          查看详情
        </Button>
      </CardContent>
    </Card>
  )
}

function findScanStep(text: string) {
  for (let i = 0; i < SCAN_STEPS.length; i++) {
    if (text.includes(SCAN_STEPS[i].replace('...', '').replace('正在', '').replace('...', ''))) {
      return i
    }
  }
  return -1
}

function useScanOutput() {
  const [lines, setLines] = useState<ScanOutputLine[]>([])
  const [currentStep, setCurrentStep] = useState(-1)
  const [error, setError] = useState<string | null>(null)
  const outputRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (outputRef.current) {
      outputRef.current.scrollTop = outputRef.current.scrollHeight
    }
  }, [lines])

  const appendLine = (line: ScanOutputLine) => {
    setLines(prev => [...prev, line])
    const step = findScanStep(line.text)
    if (step >= 0) setCurrentStep(step)
  }
  const resetOutput = () => {
    setLines([])
    setError(null)
    setCurrentStep(0)
  }

  return { lines, currentStep, error, outputRef, setError, appendLine, resetOutput }
}

function useScanSession(output: ReturnType<typeof useScanOutput>) {
  const { dispatch } = useApp()
  const [scanning, setScanning] = useState(false)
  const abortRef = useRef<AbortController | null>(null)

  const handleScan = async () => {
    setScanning(true)
    output.resetOutput()
    dispatch({ type: 'SET_PHASE', phase: 'scanning' })
    dispatch({ type: 'CLEAR_SCAN_OUTPUT' })
    const onDone = (report: FinalReport) => {
      setScanning(false)
      dispatch({ type: 'SET_REPORT', report })
      dispatch({ type: 'SET_PHASE', phase: 'review' })
    }
    const onError = (err: string) => {
      setScanning(false)
      output.setError(err)
    }
    abortRef.current = startScan(output.appendLine, onDone, onError)
  }

  const handleCancel = () => {
    if (abortRef.current) {
      abortRef.current.abort()
      setScanning(false)
      dispatch({ type: 'SET_PHASE', phase: 'idle' })
    }
  }

  return { scanning, handleScan, handleCancel }
}

function ScanContent({ report, scanning, reportLoaded, output, session, onLoad, onReview }: {
  report: FinalReport | null
  scanning: boolean
  reportLoaded: boolean
  output: ReturnType<typeof useScanOutput>
  session: ReturnType<typeof useScanSession>
  onLoad: () => void
  onReview: () => void
}) {
  return (
    <div className="max-w-2xl mx-auto space-y-6 animate-slide-in">
      <Card>
        <CardHeader>
          <CardTitle className="flex items-center gap-2">
            <Shield className="w-5 h-5 text-primary" />
            扫描系统残留
          </CardTitle>
        </CardHeader>
        <CardContent className="space-y-4">
          <p className="text-sm text-muted-foreground">
            将执行完整的扫描流水线：创建还原点 → 构建安装索引 → 扫描注册表/文件系统/服务/任务/COM扩展等残留。
            此过程需要管理员权限，可能会持续数分钟。
          </p>
          <ScanSteps currentStep={output.currentStep} scanning={scanning} />
          <ScanOutput lines={output.lines} outputRef={output.outputRef} />
          <ScanError error={output.error} />
          <ScanActions
            scanning={scanning}
            reportLoaded={reportLoaded}
            onScan={session.handleScan}
            onCancel={session.handleCancel}
            onLoad={onLoad}
          />
        </CardContent>
      </Card>
      {report && <ExistingReport report={report} onReview={onReview} />}
    </div>
  )
}

export function ScanPanel() {
  const { state, dispatch } = useApp()
  const output = useScanOutput()
  const session = useScanSession(output)

  const handleLoadExisting = async () => {
    const report = await fetchReport()
    if (report) {
      dispatch({ type: 'SET_REPORT', report })
      dispatch({ type: 'SET_PHASE', phase: 'review' })
    } else {
      output.setError('未找到现有报告，请先执行扫描')
    }
  }

  return (
    <ScanContent
      report={state.report}
      scanning={session.scanning}
      reportLoaded={state.report !== null}
      output={output}
      session={session}
      onLoad={handleLoadExisting}
      onReview={() => dispatch({ type: 'SET_PHASE', phase: 'review' })}
    />
  )
}
