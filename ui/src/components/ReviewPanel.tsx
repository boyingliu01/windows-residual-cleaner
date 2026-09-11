import { useState, useMemo } from 'react'
import { useApp, confirmCleanup } from '@/hooks/useApp'
import { SummaryBar } from './SummaryBar'
import { ItemTable } from './ItemTable'
import { Button } from './ui/button'
import { Card, CardHeader, CardTitle, CardContent } from './ui/card'
import {
  FolderOpen, Cpu, CalendarClock, Power, Puzzle, MapPin, FileJson,
  CheckCircle2, AlertTriangle, Loader2, Play
} from 'lucide-react'
import type { ResidualItem, RiskLevel } from '@/types'

const CATEGORIES: { key: string; label: string; icon: React.ReactNode; prefix: string }[] = [
  { key: 'filesystem_residuals', label: '文件系统残留', icon: <FolderOpen className="w-4 h-4" />, prefix: 'fs' },
  { key: 'registry_residuals', label: '注册表残留', icon: <FileJson className="w-4 h-4" />, prefix: 'reg' },
  { key: 'ghost_services', label: '残留服务', icon: <Cpu className="w-4 h-4" />, prefix: 'svc' },
  { key: 'ghost_tasks', label: '残留任务', icon: <CalendarClock className="w-4 h-4" />, prefix: 'tsk' },
  { key: 'startup_residuals', label: '启动项残留', icon: <Power className="w-4 h-4" />, prefix: 'str' },
  { key: 'shell_residuals', label: 'Shell扩展残留', icon: <Puzzle className="w-4 h-4" />, prefix: 'shl' },
  { key: 'path_residuals', label: 'PATH残留', icon: <MapPin className="w-4 h-4" />, prefix: 'path' },
]

function getCategoryCounts(report: any) {
  const counts: Record<string, { total: number; safe: number; caution: number; danger: number }> = {}
  for (const cat of CATEGORIES) {
    const items = (report as any)[cat.key] || []
    counts[cat.key] = {
      total: items.length,
      safe: items.filter((i: ResidualItem) => i.risk === 'safe').length,
      caution: items.filter((i: ResidualItem) => i.risk === 'caution').length,
      danger: items.filter((i: ResidualItem) => i.risk === 'danger').length,
    }
  }
  return counts
}

export function ReviewPanel() {
  const { state, dispatch } = useApp()
  const [activeTab, setActiveTab] = useState('all')
  const [riskFilter, setRiskFilter] = useState<RiskLevel | 'all'>('all')
  const [searchQuery, setSearchQuery] = useState('')
  const [showConfirm, setShowConfirm] = useState(false)
  const [confirming, setConfirming] = useState(false)

  // Build flat item list with category info — every hook must run before the
  // early return below, otherwise re-rendering with a report crashes React.
  const report = state.report
  const allItems = useMemo(() => {
    const all: { item: ResidualItem; category: string; categoryLabel: string }[] = []
    if (!report) return all
    for (const cat of CATEGORIES) {
      const items = (report as any)[cat.key] || []
      for (const item of items) {
        all.push({ item, category: cat.key, categoryLabel: cat.label })
      }
    }
    return all
  }, [report])

  // Filter items
  const filtered = useMemo(() => {
    return allItems.filter(({ item, category, categoryLabel }) => {
      if (activeTab !== 'all' && category !== activeTab) return false
      if (riskFilter !== 'all' && item.risk !== riskFilter) return false
      if (searchQuery) {
        const q = searchQuery.toLowerCase()
        const searchable = [item.id, (item as any).path, (item as any).key, (item as any).name, (item as any).value_name, (item as any).value, categoryLabel].filter(Boolean).join(' ').toLowerCase()
        if (!searchable.includes(q)) return false
      }
      return true
    })
  }, [allItems, activeTab, riskFilter, searchQuery])

  if (!state.report) return null

  const categoryCounts = getCategoryCounts(state.report)
  const selectedCount = state.selectedIds.size

  // Stats
  const safeItems = allItems.filter(({ item }) => item.risk === 'safe').map(({ item }) => item.id!)
  const cautionItems = allItems.filter(({ item }) => item.risk === 'caution').map(({ item }) => item.id!)

  const handleConfirm = async () => {
    setConfirming(true)
    const ids = Array.from(state.selectedIds)
    const ok = await confirmCleanup(ids)
    if (ok) {
      dispatch({ type: 'SET_PHASE', phase: 'dry-run' })
    } else {
      dispatch({ type: 'SET_ERROR', error: '保存确认ID失败' })
    }
    setConfirming(false)
    setShowConfirm(false)
  }

  return (
    <div className="space-y-4 animate-slide-in">
      {/* Summary bar */}
      <SummaryBar />

      {/* Category tabs */}
      <div className="flex items-center gap-1.5 flex-wrap">
        <button
          onClick={() => setActiveTab('all')}
          className={`px-3 py-1.5 rounded-md text-sm font-medium transition-colors ${
            activeTab === 'all' ? 'bg-primary text-primary-foreground' : 'bg-secondary text-secondary-foreground hover:bg-secondary/80'
          }`}
        >
          全部
        </button>
        {CATEGORIES.map((cat) => {
          const cc = categoryCounts[cat.key]
          if (!cc || cc.total === 0) return null
          return (
            <button
              key={cat.key}
              onClick={() => setActiveTab(cat.key)}
              className={`inline-flex items-center gap-1.5 px-3 py-1.5 rounded-md text-sm font-medium transition-colors ${
                activeTab === cat.key ? 'bg-primary text-primary-foreground' : 'bg-secondary text-secondary-foreground hover:bg-secondary/80'
              }`}
            >
              {cat.icon}
              {cat.label}
              <span className="ml-0.5 opacity-60">({cc.total})</span>
            </button>
          )
        })}
      </div>

      {/* Risk filter + Search */}
      <div className="flex items-center gap-2">
        <select
          value={riskFilter}
          onChange={(e) => setRiskFilter(e.target.value as any)}
          className="h-8 rounded-md border border-input bg-background px-2 text-xs font-medium"
        >
          <option value="all">全部风险等级</option>
          <option value="safe">安全</option>
          <option value="caution">警告</option>
          <option value="danger">危险</option>
        </select>
        <input
          type="text"
          placeholder="搜索路径、ID、名称..."
          value={searchQuery}
          onChange={(e) => setSearchQuery(e.target.value)}
          className="h-8 flex-1 max-w-xs rounded-md border border-input bg-background px-3 text-xs outline-none focus:border-primary transition-colors"
        />
        <div className="flex-1" />
        <span className="text-xs text-muted-foreground">
          显示 {filtered.length} / {allItems.length} 项
        </span>
      </div>

      {/* Quick selection actions */}
      <div className="flex items-center gap-2">
        <Button size="sm" variant="outline" onClick={() => dispatch({ type: 'SELECT_ALL_RISK', risk: 'safe', ids: safeItems })}>
          <CheckCircle2 className="w-3.5 h-3.5" />
          选所有安全项
        </Button>
        <Button size="sm" variant="outline" onClick={() => dispatch({ type: 'SELECT_ALL_RISK', risk: 'caution', ids: cautionItems })}>
          <AlertTriangle className="w-3.5 h-3.5" />
          选所有警告项
        </Button>
        <Button size="sm" variant="ghost" onClick={() => dispatch({ type: 'CLEAR_SELECTION' })}>
          清空选择
        </Button>
        <div className="flex-1" />
        {selectedCount > 0 && (
          <Button size="sm" onClick={() => setShowConfirm(true)} disabled={confirming}>
            {confirming ? <Loader2 className="w-3.5 h-3.5 animate-spin" /> : <Play className="w-3.5 h-3.5" />}
            确认选择 ({selectedCount})
          </Button>
        )}
      </div>

      {/* Items table */}
      <ItemTable
        items={filtered.map(f => f.item)}
        categoryLabels={Object.fromEntries(filtered.map(f => [f.item.id, f.categoryLabel]))}
      />

      {/* Confirmation dialog */}
      {showConfirm && (
        <div className="fixed inset-0 z-50 bg-black/40 flex items-center justify-center" onClick={() => setShowConfirm(false)}>
          <Card className="w-full max-w-md mx-4 animate-slide-in" onClick={(e) => e.stopPropagation()}>
            <CardHeader>
              <CardTitle>确认选择</CardTitle>
            </CardHeader>
            <CardContent className="space-y-3">
              <p className="text-sm text-muted-foreground">
                你已选择 <strong className="text-foreground">{selectedCount}</strong> 个残留项进行清理。
                确认后将进入 DryRun 预览阶段。
              </p>
              <div className="flex gap-2 justify-end">
                <Button variant="outline" onClick={() => setShowConfirm(false)}>取消</Button>
                <Button onClick={handleConfirm} disabled={confirming}>
                  {confirming ? <Loader2 className="w-4 h-4 animate-spin" /> : null}
                  确认并继续
                </Button>
              </div>
            </CardContent>
          </Card>
        </div>
      )}
    </div>
  )
}
