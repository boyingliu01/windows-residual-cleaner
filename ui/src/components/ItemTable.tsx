import { useState, useMemo } from 'react'
import { useApp } from '@/hooks/useApp'
import { Checkbox } from './ui/checkbox'
import { Badge } from './ui/badge'
import { Table, TableHeader, TableBody, TableRow, TableHead, TableCell } from './ui/table'
import { ChevronUp, ChevronDown, FolderOpen, Cpu, CalendarClock, Power, Puzzle, MapPin, FileJson } from 'lucide-react'
import type { ResidualItem, RiskLevel } from '@/types/residual'

const CATEGORY_ICONS: Record<string, React.ReactNode> = {
  '文件系统残留': <FolderOpen className="w-3.5 h-3.5" />,
  '注册表残留': <FileJson className="w-3.5 h-3.5" />,
  '残留服务': <Cpu className="w-3.5 h-3.5" />,
  '残留任务': <CalendarClock className="w-3.5 h-3.5" />,
  '启动项残留': <Power className="w-3.5 h-3.5" />,
  'Shell扩展残留': <Puzzle className="w-3.5 h-3.5" />,
  'PATH残留': <MapPin className="w-3.5 h-3.5" />,
}

const RISK_BADGE: Record<RiskLevel, { variant: 'safe' | 'caution' | 'danger'; label: string }> = {
  safe: { variant: 'safe', label: '安全' },
  caution: { variant: 'caution', label: '警告' },
  danger: { variant: 'danger', label: '危险' },
}

const RISK_ORDER: Record<RiskLevel, number> = { safe: 0, caution: 1, danger: 2 }
const PAGE_SIZE = 50

type SortKey = 'id' | 'risk' | 'name' | 'size'
type SortDirection = 'asc' | 'desc'
type OptionalTextField = 'path' | 'key' | 'registry_key' | 'name' | 'value_name'
type AppDispatch = ReturnType<typeof useApp>['dispatch']

interface Props {
  items: ResidualItem[]
  categoryLabels: Record<string, string>
}

function getOptionalText(item: ResidualItem, key: OptionalTextField): string {
  const value = (item as unknown as Record<string, unknown>)[key]
  return typeof value === 'string' ? value : ''
}

const DISPLAY_PATH_FIELDS: OptionalTextField[] = ['path', 'key', 'registry_key', 'name', 'value_name']

function getDisplayPath(item: ResidualItem): string {
  for (const field of DISPLAY_PATH_FIELDS) {
    const text = getOptionalText(item, field)
    if (text) return text
  }
  return item.id || ''
}

function getSortName(item: ResidualItem): string {
  return getOptionalText(item, 'path') || getOptionalText(item, 'key') || getOptionalText(item, 'name')
}

function getSizeMb(item: ResidualItem): number {
  return 'size_mb' in item ? item.size_mb : 0
}

export function isSelectable(item: ResidualItem): boolean {
  return item.risk !== 'danger' && !('actionable' in item && !item.actionable)
}

type ItemComparator = (a: ResidualItem, b: ResidualItem) => number

const ITEM_COMPARATORS: Record<SortKey, ItemComparator> = {
  id: (a, b) => (a.id || '').localeCompare(b.id || ''),
  risk: (a, b) => RISK_ORDER[a.risk] - RISK_ORDER[b.risk],
  name: (a, b) => getSortName(a).localeCompare(getSortName(b)),
  size: (a, b) => (getSizeMb(a) || 0) - (getSizeMb(b) || 0),
}

function compareItems(a: ResidualItem, b: ResidualItem, key: SortKey): number {
  return ITEM_COMPARATORS[key](a, b)
}

function sortItems(items: ResidualItem[], key: SortKey, direction: SortDirection): ResidualItem[] {
  return [...items].sort((a, b) => {
    const comparison = compareItems(a, b, key)
    return direction === 'asc' ? comparison : -comparison
  })
}

function SortIcon({ column, active, direction }: { column: SortKey; active: SortKey; direction: SortDirection }) {
  if (column !== active) return null
  return direction === 'asc'
    ? <ChevronUp className="w-3 h-3 inline" />
    : <ChevronDown className="w-3 h-3 inline" />
}

function SortableHead({ label, column, active, direction, onSort, className }:
  { label: string; column: SortKey; active: SortKey; direction: SortDirection; onSort: (key: SortKey) => void; className: string }) {
  return (
    <TableHead className={className ? `${className} cursor-pointer` : 'cursor-pointer'} onClick={() => onSort(column)}>
      {label} <SortIcon column={column} active={active} direction={direction} />
    </TableHead>
  )
}

function SelectAllCell({ ids, selectedIds, dispatch }:
  { ids: string[]; selectedIds: Set<string>; dispatch: AppDispatch }) {
  const checked = ids.length > 0 && ids.every(id => selectedIds.has(id))
  return (
    <TableHead className="w-8">
      <Checkbox
        checked={checked}
        onCheckedChange={() => dispatch({ type: 'TOGGLE_ALL', ids })}
        disabled={ids.length === 0}
      />
    </TableHead>
  )
}

function ItemsHeader({ ids, selectedIds, dispatch, sortKey, sortDir, onSort, showSize }:
  { ids: string[]; selectedIds: Set<string>; dispatch: AppDispatch; sortKey: SortKey; sortDir: SortDirection
    onSort: (key: SortKey) => void; showSize: boolean }) {
  return (
    <TableHeader>
      <TableRow>
        <SelectAllCell ids={ids} selectedIds={selectedIds} dispatch={dispatch} />
        <SortableHead label="ID" column="id" active={sortKey} direction={sortDir} onSort={onSort} className="w-20" />
        <SortableHead label="风险" column="risk" active={sortKey} direction={sortDir} onSort={onSort} className="w-16" />
        <TableHead className="w-24">类别</TableHead>
        <SortableHead label="路径 / 名称" column="name" active={sortKey} direction={sortDir} onSort={onSort} className="" />
        <TableHead className="w-24">原因</TableHead>
        {showSize && (
          <SortableHead label="大小" column="size" active={sortKey} direction={sortDir} onSort={onSort} className="w-20 text-right" />
        )}
      </TableRow>
    </TableHeader>
  )
}

function ItemSelectionCell({ id, selected, selectable, dispatch }:
  { id: string; selected: boolean; selectable: boolean; dispatch: AppDispatch }) {
  return (
    <TableCell>
      <Checkbox
        checked={selected}
        onCheckedChange={() => dispatch({ type: 'TOGGLE_ID', id })}
        disabled={!selectable}
        title={selectable ? undefined : '危险项或证据不足的条目不可自动选择'}
      />
    </TableCell>
  )
}

function ItemIdentityCells({ item, categoryLabel }: { item: ResidualItem; categoryLabel: string }) {
  return (
    <>
      <TableCell><code className="text-xs text-muted-foreground">{item.id}</code></TableCell>
      <TableCell><Badge variant={RISK_BADGE[item.risk].variant}>{RISK_BADGE[item.risk].label}</Badge></TableCell>
      <TableCell>
        <span className="inline-flex items-center gap-1 text-xs text-muted-foreground">
          {CATEGORY_ICONS[categoryLabel]}
          {categoryLabel}
        </span>
      </TableCell>
    </>
  )
}

function ItemPathCell({ item }: { item: ResidualItem }) {
  return (
    <TableCell>
      <div className="flex items-center gap-1.5"><code className="text-xs">{getDisplayPath(item)}</code></div>
      {item.risk === 'danger' && <div className="text-xs text-danger mt-0.5">⚠ 手动确认后方可清理</div>}
    </TableCell>
  )
}

function ItemSizeCell({ item }: { item: ResidualItem }) {
  if (!('size_mb' in item)) return null
  const size = item.size_mb
  return (
    <TableCell className="text-right text-xs text-muted-foreground">
      {size >= 1024 ? `${(size / 1024).toFixed(1)} GB` : `${Math.round(size)} MB`}
    </TableCell>
  )
}

function ItemRow({ item, categoryLabel, selectedIds, dispatch }:
  { item: ResidualItem; categoryLabel: string; selectedIds: Set<string>; dispatch: AppDispatch }) {
  return (
    <TableRow className={selectedIds.has(item.id) ? 'bg-primary/5' : ''}>
      <ItemSelectionCell id={item.id} selected={selectedIds.has(item.id)} selectable={isSelectable(item)} dispatch={dispatch} />
      <ItemIdentityCells item={item} categoryLabel={categoryLabel} />
      <ItemPathCell item={item} />
      <TableCell><span className="text-xs text-muted-foreground">{item.reason}</span></TableCell>
      <ItemSizeCell item={item} />
    </TableRow>
  )
}

function ItemsBody({ items, categoryLabels, selectedIds, dispatch }:
  { items: ResidualItem[]; categoryLabels: Record<string, string>; selectedIds: Set<string>; dispatch: AppDispatch }) {
  return (
    <TableBody>
      {items.map(item => (
        <ItemRow
          key={item.id}
          item={item}
          categoryLabel={categoryLabels[item.id] || ''}
          selectedIds={selectedIds}
          dispatch={dispatch}
        />
      ))}
    </TableBody>
  )
}

function Pagination({ page, totalPages, totalItems, onPageChange }: {
  page: number; totalPages: number; totalItems: number; onPageChange: (update: (page: number) => number) => void
}) {
  if (totalPages <= 1) return null
  return (
    <div className="flex items-center justify-between px-3 py-2 text-xs text-muted-foreground">
      <span>共 {totalItems} 项</span>
      <div className="flex items-center gap-1">
        <button
          onClick={() => onPageChange(current => Math.max(0, current - 1))}
          disabled={page === 0}
          className="px-2 py-1 rounded hover:bg-secondary disabled:opacity-30"
        >上一页</button>
        <span className="px-2">{page + 1} / {totalPages}</span>
        <button
          onClick={() => onPageChange(current => Math.min(totalPages - 1, current + 1))}
          disabled={page >= totalPages - 1}
          className="px-2 py-1 rounded hover:bg-secondary disabled:opacity-30"
        >下一页</button>
      </div>
    </div>
  )
}

export function ItemTable({ items, categoryLabels }: Props) {
  const { state, dispatch } = useApp()
  const { selectedIds } = state
  const [sortKey, setSortKey] = useState<SortKey>('risk')
  const [sortDir, setSortDir] = useState<SortDirection>('asc')
  const [page, setPage] = useState(0)
  const sorted = useMemo(() => sortItems(items, sortKey, sortDir), [items, sortKey, sortDir])
  const paged = sorted.slice(page * PAGE_SIZE, (page + 1) * PAGE_SIZE)
  const selectableIds = paged.filter(isSelectable).map(item => item.id)
  const showSize = items.length > 0 && 'size_mb' in items[0]

  const toggleSort = (key: SortKey) => {
    if (sortKey === key) setSortDir(direction => direction === 'asc' ? 'desc' : 'asc')
    else { setSortKey(key); setSortDir('asc') }
  }

  if (items.length === 0) {
    return <div className="text-center py-12 text-muted-foreground text-sm">没有匹配的残留项</div>
  }

  return (
    <div>
      <Table>
        <ItemsHeader
          ids={selectableIds} selectedIds={selectedIds} dispatch={dispatch}
          sortKey={sortKey} sortDir={sortDir} onSort={toggleSort} showSize={showSize}
        />
        <ItemsBody items={paged} categoryLabels={categoryLabels} selectedIds={selectedIds} dispatch={dispatch} />
      </Table>
      <Pagination
        page={page} totalPages={Math.ceil(sorted.length / PAGE_SIZE)}
        totalItems={sorted.length} onPageChange={setPage}
      />
    </div>
  )
}
