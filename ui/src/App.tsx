import { useApp, AppProvider } from '@/hooks/useApp'
import { ScanPanel } from '@/components/ScanPanel'
import { ReviewPanel } from '@/components/ReviewPanel'
import { CleanupPanel } from '@/components/CleanupPanel'
import { Shield, Menu, X, Github, XCircle } from 'lucide-react'
import { useState } from 'react'

const PHASE_LABELS: Record<string, { label: string; step: number }> = {
  idle: { label: '就绪', step: 0 },
  scanning: { label: '扫描中', step: 1 },
  review: { label: '审查', step: 2 },
  'dry-run': { label: '预览', step: 3 },
  cleaning: { label: '清理中', step: 4 },
  done: { label: '完成', step: 5 },
}

function AppContent() {
  const { state, dispatch } = useApp()
  const [menuOpen, setMenuOpen] = useState(false)
  const phase = state.phase
  const phaseInfo = PHASE_LABELS[phase]

  const canNavigate = (target: string) => {
    const order = ['idle', 'scanning', 'review', 'dry-run', 'cleaning', 'done']
    const currentIdx = order.indexOf(phase)
    const targetIdx = order.indexOf(target)
    // Can always go back to review if we have a report
    if (target === 'review' && state.report) return true
    // Can only go forward
    return targetIdx <= currentIdx
  }

  const handleNavigate = (target: string) => {
    if (canNavigate(target)) {
      dispatch({ type: 'SET_PHASE', phase: target as any })
    }
  }

  return (
    <div className="min-h-screen bg-background">
      {/* Top bar */}
      <header className="sticky top-0 z-40 bg-sidebar text-sidebar-foreground border-b border-sidebar-border">
        <div className="flex items-center h-12 px-4 gap-3">
          <button
            className="md:hidden p-1.5 rounded-md hover:bg-white/10"
            onClick={() => setMenuOpen(!menuOpen)}
          >
            {menuOpen ? <X className="w-4 h-4" /> : <Menu className="w-4 h-4" />}
          </button>
          <Shield className="w-5 h-5 text-primary-light shrink-0" />
          <span className="font-semibold text-sm">Windows 残留清理</span>
          <span className="text-xs text-sidebar-foreground/50 hidden sm:inline">|</span>
          <span className="text-xs text-sidebar-foreground/60 hidden sm:inline">
            {phaseInfo.label}
          </span>
          <div className="flex-1" />
          {/* Phase indicators */}
          <nav className="hidden md:flex items-center gap-1">
            {[
              { key: 'idle', label: '开始' },
              { key: 'review', label: '审查' },
              { key: 'dry-run', label: '预览' },
              { key: 'done', label: '完成' },
            ].map(item => {
              const active = phase === item.key
              const canGo = canNavigate(item.key)
              return (
                <button
                  key={item.key}
                  onClick={() => handleNavigate(item.key)}
                  disabled={!canGo}
                  className={`flex items-center gap-1.5 px-2.5 py-1 rounded text-xs font-medium transition-colors ${
                    active
                      ? 'bg-white/15 text-white'
                      : canGo
                      ? 'text-sidebar-foreground/60 hover:text-sidebar-foreground hover:bg-white/5'
                      : 'text-sidebar-foreground/30 cursor-not-allowed'
                  }`}
                >
                  {active && <Shield className="w-3 h-3" />}
                  {item.label}
                </button>
              )
            })}
          </nav>
          <a
            href="https://github.com/your-repo/windows-residual-cleaner"
            target="_blank"
            rel="noopener noreferrer"
            className="text-sidebar-foreground/40 hover:text-sidebar-foreground/70 transition-colors"
          >
            <Github className="w-4 h-4" />
          </a>
        </div>
      </header>

      {/* Mobile menu */}
      {menuOpen && (
        <div className="md:hidden fixed inset-0 z-30 bg-black/40" onClick={() => setMenuOpen(false)}>
          <div className="w-48 bg-card border-r h-full p-2 space-y-1" onClick={(e) => e.stopPropagation()}>
            {[
              { key: 'idle', label: '开始' },
              { key: 'review', label: '审查残留项' },
              { key: 'dry-run', label: 'DryRun 预览' },
              { key: 'done', label: '清理结果' },
            ].map(item => (
              <button
                key={item.key}
                onClick={() => { handleNavigate(item.key); setMenuOpen(false) }}
                disabled={!canNavigate(item.key)}
                className={`w-full text-left px-3 py-2 rounded-md text-sm ${
                  phase === item.key ? 'bg-primary/10 text-primary font-medium' :
                  canNavigate(item.key) ? 'hover:bg-secondary' :
                  'text-muted-foreground/40 cursor-not-allowed'
                }`}
              >
                {item.label}
              </button>
            ))}
          </div>
        </div>
      )}

      {/* Main content */}
      <main className="p-4 md:p-6 max-w-6xl mx-auto">
        {phase === 'idle' && <ScanPanel />}
        {phase === 'scanning' && <ScanPanel />}
        {phase === 'review' && <ReviewPanel />}
        {phase === 'dry-run' && <CleanupPanel />}
        {phase === 'cleaning' && <CleanupPanel />}
        {phase === 'done' && <CleanupPanel />}
      </main>

      {/* Error toast */}
      {state.error && (
        <div className="fixed bottom-4 right-4 z-50 bg-danger-bg text-danger border border-danger/20 rounded-lg p-3 text-sm shadow-lg max-w-sm">
          <div className="flex items-start gap-2">
            <XCircle className="w-4 h-4 mt-0.5 shrink-0" />
            <span className="flex-1">{state.error}</span>
            <button onClick={() => dispatch({ type: 'SET_ERROR', error: null })} className="shrink-0">
              <X className="w-3.5 h-3.5" />
            </button>
          </div>
        </div>
      )}
    </div>
  )
}

export default function App() {
  return (
    <AppProvider>
      <AppContent />
    </AppProvider>
  )
}
