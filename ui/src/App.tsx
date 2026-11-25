import { useApp, AppProvider } from '@/hooks/useApp'
import { ScanPanel } from '@/components/ScanPanel'
import { ReviewPanel } from '@/components/ReviewPanel'
import { CleanupPanel } from '@/components/CleanupPanel'
import { Shield, Menu, X, Github, XCircle } from 'lucide-react'
import { useState, type ComponentType } from 'react'
import type { AppPhase } from '@/types/app'

const PHASE_LABELS: Record<AppPhase, { label: string; step: number }> = {
  idle: { label: '就绪', step: 0 },
  scanning: { label: '扫描中', step: 1 },
  review: { label: '审查', step: 2 },
  'dry-run': { label: '预览', step: 3 },
  cleaning: { label: '清理中', step: 4 },
  done: { label: '完成', step: 5 },
}

const PHASE_ORDER: AppPhase[] = ['idle', 'scanning', 'review', 'dry-run', 'cleaning', 'done']
const DESKTOP_NAV_ITEMS: { key: AppPhase; label: string }[] = [
  { key: 'idle', label: '开始' },
  { key: 'review', label: '审查' },
  { key: 'dry-run', label: '预览' },
  { key: 'done', label: '完成' },
]
const MOBILE_NAV_ITEMS: { key: AppPhase; label: string }[] = [
  { key: 'idle', label: '开始' },
  { key: 'review', label: '审查残留项' },
  { key: 'dry-run', label: 'DryRun 预览' },
  { key: 'done', label: '清理结果' },
]
const PHASE_CONTENT: Record<AppPhase, ComponentType> = {
  idle: ScanPanel,
  scanning: ScanPanel,
  review: ReviewPanel,
  'dry-run': CleanupPanel,
  cleaning: CleanupPanel,
  done: CleanupPanel,
}

function canNavigate(phase: AppPhase, target: AppPhase, hasReport: boolean) {
  const currentIdx = PHASE_ORDER.indexOf(phase)
  const targetIdx = PHASE_ORDER.indexOf(target)
  if (target === 'review' && hasReport) return true
  return targetIdx <= currentIdx
}

function DesktopNavigation({ phase, hasReport, onNavigate }: {
  phase: AppPhase
  hasReport: boolean
  onNavigate: (target: AppPhase) => void
}) {
  return (
    <nav className="hidden md:flex items-center gap-1">
      {DESKTOP_NAV_ITEMS.map(item => {
        const active = phase === item.key
        const canGo = canNavigate(phase, item.key, hasReport)
        return (
          <button
            key={item.key}
            onClick={() => onNavigate(item.key)}
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
  )
}

function MobileNavigation({ phase, hasReport, onNavigate, onClose }: {
  phase: AppPhase
  hasReport: boolean
  onNavigate: (target: AppPhase) => void
  onClose: () => void
}) {
  return (
    <div className="md:hidden fixed inset-0 z-30 bg-black/40" onClick={onClose}>
      <div className="w-48 bg-card border-r h-full p-2 space-y-1" onClick={(e) => e.stopPropagation()}>
        {MOBILE_NAV_ITEMS.map(item => (
          <button
            key={item.key}
            onClick={() => { onNavigate(item.key); onClose() }}
            disabled={!canNavigate(phase, item.key, hasReport)}
            className={`w-full text-left px-3 py-2 rounded-md text-sm ${
              phase === item.key ? 'bg-primary/10 text-primary font-medium' :
              canNavigate(phase, item.key, hasReport) ? 'hover:bg-secondary' :
              'text-muted-foreground/40 cursor-not-allowed'
            }`}
          >
            {item.label}
          </button>
        ))}
      </div>
    </div>
  )
}

function AppHeader({ phase, hasReport, menuOpen, onToggleMenu, onNavigate }: {
  phase: AppPhase
  hasReport: boolean
  menuOpen: boolean
  onToggleMenu: () => void
  onNavigate: (target: AppPhase) => void
}) {
  return (
    <header className="sticky top-0 z-40 bg-sidebar text-sidebar-foreground border-b border-sidebar-border">
      <div className="flex items-center h-12 px-4 gap-3">
        <button
          className="md:hidden p-1.5 rounded-md hover:bg-white/10"
          onClick={onToggleMenu}
        >
          {menuOpen ? <X className="w-4 h-4" /> : <Menu className="w-4 h-4" />}
        </button>
        <Shield className="w-5 h-5 text-primary-light shrink-0" />
        <span className="font-semibold text-sm">Windows 残留清理</span>
        <span className="text-xs text-sidebar-foreground/50 hidden sm:inline">|</span>
        <span className="text-xs text-sidebar-foreground/60 hidden sm:inline">
          {PHASE_LABELS[phase].label}
        </span>
        <div className="flex-1" />
        <DesktopNavigation phase={phase} hasReport={hasReport} onNavigate={onNavigate} />
        <a
          href="https://github.com/boyingliu01/windows-residual-cleaner"
          target="_blank"
          rel="noopener noreferrer"
          className="text-sidebar-foreground/40 hover:text-sidebar-foreground/70 transition-colors"
        >
          <Github className="w-4 h-4" />
        </a>
      </div>
    </header>
  )
}

export function PhaseContent({ phase }: { phase: AppPhase }) {
  const Content = PHASE_CONTENT[phase]
  return (
    <main className="p-4 md:p-6 max-w-6xl mx-auto">
      <Content />
    </main>
  )
}

function ErrorToast({ error, onDismiss }: { error: string; onDismiss: () => void }) {
  return (
    <div className="fixed bottom-4 right-4 z-50 bg-danger-bg text-danger border border-danger/20 rounded-lg p-3 text-sm shadow-lg max-w-sm">
      <div className="flex items-start gap-2">
        <XCircle className="w-4 h-4 mt-0.5 shrink-0" />
        <span className="flex-1">{error}</span>
        <button onClick={onDismiss} className="shrink-0">
          <X className="w-3.5 h-3.5" />
        </button>
      </div>
    </div>
  )
}

function AppContent() {
  const { state, dispatch } = useApp()
  const [menuOpen, setMenuOpen] = useState(false)
  const phase = state.phase

  const handleNavigate = (target: AppPhase) => {
    if (canNavigate(phase, target, state.report !== null)) {
      dispatch({ type: 'SET_PHASE', phase: target })
    }
  }

  return (
    <div className="min-h-screen bg-background">
      <AppHeader
        phase={phase}
        hasReport={state.report !== null}
        menuOpen={menuOpen}
        onToggleMenu={() => setMenuOpen(!menuOpen)}
        onNavigate={handleNavigate}
      />
      {menuOpen && (
        <MobileNavigation
          phase={phase}
          hasReport={state.report !== null}
          onNavigate={handleNavigate}
          onClose={() => setMenuOpen(false)}
        />
      )}
      <PhaseContent phase={phase} />
      {state.error && (
        <ErrorToast error={state.error} onDismiss={() => dispatch({ type: 'SET_ERROR', error: null })} />
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
