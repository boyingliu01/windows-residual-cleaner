import { useState, useMemo } from 'react'
import { useApp, confirmCleanup } from '@/hooks/useApp'
import { SummaryBar } from './SummaryBar'
import { ItemTable, isSelectable } from './ItemTable'
import { Button } from './ui/button'
import { Card, CardHeader, CardTitle, CardContent } from './ui/card'
import {
  FolderOpen, Cpu, CalendarClock, Power, Puzzle, MapPin, FileJson,
  CheckCircle2, AlertTriangle, Loader2, Play
} from 'lucide-react'
import type { FinalReport } from '@/types/report'
import type { ResidualItem, RiskLevel } from '@/types/residual'

type CategoryKey = keyof Omit<FinalReport, 'scan_time' | 'summary'>
type RiskFilter = RiskLevel | 'all'
type AppDispatch = ReturnType<typeof useApp>['dispatch']
type OptionalTextField = 'path' | 'key' | 'registry_key' | 'name' | 'value_name' | 'value'

interface CategoryDefinition {
  key: CategoryKey
  label: string
  icon: React.ReactNode
  prefix: string
}

interface CategorizedItem {
  item: ResidualItem
  category: CategoryKey
  categoryLabel: string
}

interface CategoryCount {
  total: number
  safe: number
  caution: number
  danger: number
}

const CATEGORIES: CategoryDefinition[] = [
  { key: 'filesystem_residuals', label: '文件系统残留', icon: <FolderOpen className="w-4 h-4" />, prefix: 'fs' },
  { key: 'registry_residuals', label: '注册表残留', icon: <FileJson className="w-4 h-4" />, prefix: 'reg' },
  { key: 'ghost_services', label: '残留服务', icon: <Cpu className="w-4 h-4" />, prefix: 'svc' },
  { key: 'ghost_tasks', label: '残留任务', icon: <CalendarClock className="w-4 h-4" />, prefix: 'tsk' },
  { key: 'startup_residuals', label: '启动项残留', icon: <Power className="w-4 h-4" />, prefix: 'str' },
  { key: 'shell_residuals', label: 'Shell扩展残留', icon: <Puzzle className="w-4 h-4" />, prefix: 'shl' },
  { key: 'path_residuals', label: 'PATH残留', icon: <MapPin className="w-4 h-4" />, prefix: 'path' },
  { key: 'uninstalled_software', label: '已卸载软件', icon: <FileJson className="w-4 h-4" />, prefix: 'uni' },
]

function getOptionalText(item: ResidualItem, key: OptionalTextField): string {
  const value = (item as unknown as Record<string, unknown>)[key]
  return typeof value === 'string' ? value : ''
}

function countRisk(items: ResidualItem[], risk: RiskLevel): number {
  return items.filter(item => item.risk === risk).length
}

function getCategoryItems(report: FinalReport, key: CategoryKey): ResidualItem[] {
  return report[key] || []
}

function getCategoryCounts(report: FinalReport): Record<CategoryKey, CategoryCount> {
  const counts = {} as Record<CategoryKey, CategoryCount>
  for (const category of CATEGORIES) {
    const items = getCategoryItems(report, category.key)
    counts[category.key] = {
      total: items.length,
      safe: countRisk(items, 'safe'),
      caution: countRisk(items, 'caution'),
      danger: countRisk(items, 'danger'),
    }
  }
  return counts
}

function flattenReport(report: FinalReport | null): CategorizedItem[] {
  const all: CategorizedItem[] = []
  if (!report) return all
  for (const category of CATEGORIES) {
    for (const item of getCategoryItems(report, category.key)) {
      all.push({ item, category: category.key, categoryLabel: category.label })
    }
  }
  return all
}

function getSearchableText(entry: CategorizedItem): string {
  const { item, categoryLabel } = entry
  return [
    item.id, getOptionalText(item, 'path'), getOptionalText(item, 'key'),
    getOptionalText(item, 'registry_key'), getOptionalText(item, 'name'),
    getOptionalText(item, 'value_name'), getOptionalText(item, 'value'), categoryLabel,
  ].filter(Boolean).join(' ').toLowerCase()
}

function matchesCategory(entry: CategorizedItem, activeTab: string): boolean {
  return activeTab === 'all' || entry.category === activeTab
}

function matchesRisk(entry: CategorizedItem, riskFilter: RiskFilter): boolean {
  return riskFilter === 'all' || entry.item.risk === riskFilter
}

function matchesSearch(entry: CategorizedItem, searchQuery: string): boolean {
  const query = searchQuery.toLowerCase()
  return !query || getSearchableText(entry).includes(query)
}

function matchesFilters(entry: CategorizedItem, activeTab: string, riskFilter: RiskFilter, searchQuery: string): boolean {
  return matchesCategory(entry, activeTab)
    && matchesRisk(entry, riskFilter)
    && matchesSearch(entry, searchQuery)
}

function filterItems(items: CategorizedItem[], activeTab: string, riskFilter: RiskFilter, searchQuery: string): CategorizedItem[] {
  return items.filter(entry => matchesFilters(entry, activeTab, riskFilter, searchQuery))
}

function getSelectableRiskIds(items: CategorizedItem[], risk: RiskLevel): string[] {
  return items.filter(({ item }) => item.risk === risk && isSelectable(item)).map(({ item }) => item.id)
}

function getCategoryLabels(items: CategorizedItem[]): Record<string, string> {
  return Object.fromEntries(items.map(entry => [entry.item.id, entry.categoryLabel]))
}

function parseRiskFilter(value: string): RiskFilter {
  return value === 'safe' || value === 'caution' || value === 'danger' ? value : 'all'
}

function categoryTabClass(active: boolean): string {
  return `px-3 py-1.5 rounded-md text-sm font-medium transition-colors ${
    active ? 'bg-primary text-primary-foreground' : 'bg-secondary text-secondary-foreground hover:bg-secondary/80'
  }`
}

function CategoryTab({ category, count, active, onSelect }: {
  category: CategoryDefinition; count: number; active: boolean; onSelect: (key: string) => void
}) {
  return (
    <button onClick={() => onSelect(category.key)} className={`inline-flex items-center gap-1.5 ${categoryTabClass(active)}`}>
      {category.icon}
      {category.label}
      <span className="ml-0.5 opacity-60">({count})</span>
    </button>
  )
}

function CategoryTabs({ activeTab, counts, onSelect }: {
  activeTab: string; counts: Record<CategoryKey, CategoryCount>; onSelect: (key: string) => void
}) {
  return (
    <div className="flex items-center gap-1.5 flex-wrap">
      <button onClick={() => onSelect('all')} className={categoryTabClass(activeTab === 'all')}>全部</button>
      {CATEGORIES.map(category => {
        const count = counts[category.key]
        if (count.total === 0) return null
        return (
          <CategoryTab
            key={category.key} category={category} count={count.total}
            active={activeTab === category.key} onSelect={onSelect}
          />
        )
      })}
    </div>
  )
}

function FilterControls({ riskFilter, searchQuery, filteredCount, totalCount, onRiskFilterChange, onSearchChange }: {
  riskFilter: RiskFilter; searchQuery: string; filteredCount: number; totalCount: number
  onRiskFilterChange: (risk: RiskFilter) => void; onSearchChange: (query: string) => void
}) {
  return (
    <div className="flex items-center gap-2">
      <select
        value={riskFilter}
        onChange={event => onRiskFilterChange(parseRiskFilter(event.target.value))}
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
        onChange={event => onSearchChange(event.target.value)}
        className="h-8 flex-1 max-w-xs rounded-md border border-input bg-background px-3 text-xs outline-none focus:border-primary transition-colors"
      />
      <div className="flex-1" />
      <span className="text-xs text-muted-foreground">显示 {filteredCount} / {totalCount} 项</span>
    </div>
  )
}

function QuickSelection({ safeIds, cautionIds, selectedCount, confirming, dispatch, onConfirm }: {
  safeIds: string[]; cautionIds: string[]; selectedCount: number; confirming: boolean
  dispatch: AppDispatch; onConfirm: () => void
}) {
  return (
    <div className="flex items-center gap-2">
      <Button size="sm" variant="outline" onClick={() => dispatch({ type: 'SELECT_ALL_RISK', risk: 'safe', ids: safeIds })}>
        <CheckCircle2 className="w-3.5 h-3.5" />选所有安全项
      </Button>
      <Button size="sm" variant="outline" onClick={() => dispatch({ type: 'SELECT_ALL_RISK', risk: 'caution', ids: cautionIds })}>
        <AlertTriangle className="w-3.5 h-3.5" />选所有警告项
      </Button>
      <Button size="sm" variant="ghost" onClick={() => dispatch({ type: 'CLEAR_SELECTION' })}>清空选择</Button>
      <div className="flex-1" />
      {selectedCount > 0 && (
        <Button size="sm" onClick={onConfirm} disabled={confirming}>
          {confirming ? <Loader2 className="w-3.5 h-3.5 animate-spin" /> : <Play className="w-3.5 h-3.5" />}
          确认选择 ({selectedCount})
        </Button>
      )}
    </div>
  )
}

function useConfirmation(dispatch: AppDispatch, selectedIds: Set<string>) {
  const [showConfirm, setShowConfirm] = useState(false)
  const [confirming, setConfirming] = useState(false)
  const close = () => setShowConfirm(false)
  const handleConfirm = async () => {
    setConfirming(true)
    const ok = await confirmCleanup(Array.from(selectedIds))
    if (ok) dispatch({ type: 'SET_PHASE', phase: 'dry-run' })
    else dispatch({ type: 'SET_ERROR', error: '保存确认ID失败' })
    setConfirming(false)
    close()
  }
  return { showConfirm, confirming, open: () => setShowConfirm(true), close, handleConfirm }
}

function ConfirmationDialog({ selectedCount, confirming, onConfirm, onClose }: {
  selectedCount: number; confirming: boolean; onConfirm: () => void; onClose: () => void
}) {
  return (
    <div className="fixed inset-0 z-50 bg-black/40 flex items-center justify-center" onClick={onClose}>
      <Card className="w-full max-w-md mx-4 animate-slide-in" onClick={event => event.stopPropagation()}>
        <CardHeader><CardTitle>确认选择</CardTitle></CardHeader>
        <CardContent className="space-y-3">
          <p className="text-sm text-muted-foreground">
            你已选择 <strong className="text-foreground">{selectedCount}</strong> 个残留项进行清理。
            确认后将进入 DryRun 预览阶段。
          </p>
          <div className="flex gap-2 justify-end">
            <Button variant="outline" onClick={onClose}>取消</Button>
            <Button onClick={onConfirm} disabled={confirming}>
              {confirming ? <Loader2 className="w-4 h-4 animate-spin" /> : null}
              确认并继续
            </Button>
          </div>
        </CardContent>
      </Card>
    </div>
  )
}

export function ReviewPanel() {
  const { state, dispatch } = useApp()
  const [activeTab, setActiveTab] = useState('all')
  const [riskFilter, setRiskFilter] = useState<RiskFilter>('all')
  const [searchQuery, setSearchQuery] = useState('')
  const report = state.report
  const allItems = useMemo(() => flattenReport(report), [report])
  const filtered = useMemo(
    () => filterItems(allItems, activeTab, riskFilter, searchQuery),
    [allItems, activeTab, riskFilter, searchQuery],
  )
  const confirmation = useConfirmation(dispatch, state.selectedIds)

  if (!report) return null

  const categoryCounts = getCategoryCounts(report)
  const safeIds = getSelectableRiskIds(allItems, 'safe')
  const cautionIds = getSelectableRiskIds(allItems, 'caution')

  return (
    <div className="space-y-4 animate-slide-in">
      <SummaryBar />
      <CategoryTabs activeTab={activeTab} counts={categoryCounts} onSelect={setActiveTab} />
      <FilterControls
        riskFilter={riskFilter} searchQuery={searchQuery} filteredCount={filtered.length} totalCount={allItems.length}
        onRiskFilterChange={setRiskFilter} onSearchChange={setSearchQuery}
      />
      <QuickSelection
        safeIds={safeIds} cautionIds={cautionIds} selectedCount={state.selectedIds.size}
        confirming={confirmation.confirming} dispatch={dispatch} onConfirm={confirmation.open}
      />
      <ItemTable items={filtered.map(entry => entry.item)} categoryLabels={getCategoryLabels(filtered)} />
      {confirmation.showConfirm && (
        <ConfirmationDialog
          selectedCount={state.selectedIds.size} confirming={confirmation.confirming}
          onConfirm={confirmation.handleConfirm} onClose={confirmation.close}
        />
      )}
    </div>
  )
}
