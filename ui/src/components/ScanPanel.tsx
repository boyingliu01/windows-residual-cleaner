import { useRef, useEffect, useState } from 'react'
import { useApp, startScan, fetchReport } from '@/hooks/useApp'
import { Button } from './ui/button'
import { Card, CardHeader, CardTitle, CardContent } from './ui/card'
import { Shield, Play, Loader2, CheckCircle2, XCircle, FileText } from 'lucide-react'
import type { ScanOutputLine } from '@/types'

const SCAN_STEPS = [
  '正在创建系统还原点...',
  '正在构建已安装软件索引...',
  '正在扫描已卸载残留...',
  '正在扫描文件系统残留...',
  '正在扫描注册表/服务/任务残留...',
  '正在生成最终报告...',
]

export function ScanPanel() {
  const { state, dispatch } = useApp()
  const [scanning, setScanning] = useState(false)
  const [lines, setLines] = useState<ScanOutputLine[]>([])
  const [currentStep, setCurrentStep] = useState(-1)
  const [error, setError] = useState<string | null>(null)
  const outputRef = useRef<HTMLDivElement>(null)
  const abortRef = useRef<AbortController | null>(null)
  const reportLoaded = state.report !== null

  // Auto-scroll
  useEffect(() => {
    if (outputRef.current) {
      outputRef.current.scrollTop = outputRef.current.scrollHeight
    }
  }, [lines])

  const handleScan = async () => {
    setScanning(true)
    setLines([])
    setError(null)
    setCurrentStep(0)
    dispatch({ type: 'CLEAR_SCAN_OUTPUT' })

    const onLine = (line: ScanOutputLine) => {
      setLines(prev => [...prev, line])
      // Detect step from text
      for (let i = 0; i < SCAN_STEPS.length; i++) {
        if (line.text.includes(SCAN_STEPS[i].replace('...', '').replace('正在', '').replace('...', ''))) {
          setCurrentStep(i)
          break
        }
      }
    }

    const onDone = (report: any) => {
      setScanning(false)
      dispatch({ type: 'SET_REPORT', report })
      dispatch({ type: 'SET_PHASE', phase: 'review' })
    }

    const onError = (err: string) => {
      setScanning(false)
      setError(err)
    }

    abortRef.current = startScan(onLine, onDone, onError)
  }

  const handleCancel = () => {
    if (abortRef.current) {
      abortRef.current.abort()
      setScanning(false)
    }
  }

  const handleLoadExisting = async () => {
    const report = await fetchReport()
    if (report) {
      dispatch({ type: 'SET_REPORT', report })
      dispatch({ type: 'SET_PHASE', phase: 'review' })
    } else {
      setError('未找到现有报告，请先执行扫描')
    }
  }

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

          {/* Step indicator */}
          <div className="space-y-2">
            {SCAN_STEPS.map((step, i) => (
              <div key={i} className="flex items-center gap-3 text-sm">
                <div className={`w-6 h-6 rounded-full flex items-center justify-center text-xs font-medium shrink-0 ${
                  i < currentStep ? 'bg-safe text-white' :
                  i === currentStep && scanning ? 'bg-primary text-white' :
                  scanning ? 'bg-secondary text-muted-foreground' :
                  'bg-secondary text-muted-foreground'
                }`}>
                  {i < currentStep ? <CheckCircle2 className="w-3.5 h-3.5" /> :
                   i === currentStep && scanning ? <Loader2 className="w-3.5 h-3.5 animate-spin" /> :
                   i + 1}
                </div>
                <span className={
                  i === currentStep && scanning ? 'text-foreground font-medium' :
                  i < currentStep ? 'text-safe' :
                  'text-muted-foreground'
                }>
                  {step}
                </span>
              </div>
            ))}
          </div>

          {/* Output console */}
          {lines.length > 0 && (
            <div
              ref={outputRef}
              className="bg-[#1e1e1e] text-[#d4d4d4] rounded-lg p-3 font-mono text-xs h-48 overflow-y-auto space-y-0.5"
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

          <div className="flex gap-2">
            {!scanning ? (
              <>
                <Button onClick={handleScan} size="lg">
                  <Play className="w-4 h-4" />
                  开始扫描
                </Button>
                <Button variant="outline" onClick={handleLoadExisting} disabled={reportLoaded}>
                  <FileText className="w-4 h-4" />
                  {reportLoaded ? '报告已加载' : '加载已有报告'}
                </Button>
              </>
            ) : (
              <Button variant="destructive" onClick={handleCancel}>
                <XCircle className="w-4 h-4" />
                取消扫描
              </Button>
            )}
          </div>
        </CardContent>
      </Card>

      {reportLoaded && (
        <Card>
          <CardContent className="p-4 flex items-center gap-2 text-sm">
            <CheckCircle2 className="w-4 h-4 text-safe" />
            <span>已有扫描报告，共 <strong>{state.report!.summary.total_residuals}</strong> 个残留项</span>
            <div className="flex-1" />
            <Button size="sm" variant="outline" onClick={() => dispatch({ type: 'SET_PHASE', phase: 'review' })}>
              查看详情
            </Button>
          </CardContent>
        </Card>
      )}
    </div>
  )
}
