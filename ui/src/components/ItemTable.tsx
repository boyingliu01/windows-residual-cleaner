import { useState, useMemo } from 'react'
import { useApp } from '@/hooks/useApp'
import { Checkbox } from './ui/checkbox'
import { Badge } from './ui/badge'
import { Table, TableHeader, TableBody, TableRow, TableHead, TableCell } from './ui/table'
import { ChevronUp, ChevronDown, FolderOpen, Cpu, CalendarClock, Power, Puzzle, MapPin, FileJson } from 'lucide-react'
import type { ResidualItem, RiskLevel } from '@/types'

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

type SortKey = 'id' | 'risk' | 'name' | 'size'

interface Props {
  items: ResidualItem[]
  categoryLabels: Record<string, string>
}

export function ItemTable({ items, categoryLabels }: Props) {
  const { state, dispatch } = useApp()
  const { selectedIds } = state

  const [sortKey, setSortKey] = useState<SortKey>('risk')
  const [sortDir, setSortDir] = useState<'asc' | 'desc'>('asc')
  const [page, setPage] = useState(0)
  const pageSize = 50

  const sorted = useMemo(() => {
    const arr = [...items]
    arr.sort((a, b) => {
      let cmp = 0
      switch (sortKey) {
        case 'id':
          cmp = (a.id || '').localeCompare(b.id || '')
          break
        case 'risk': {
          const order = { safe: 0, caution: 1, danger: 2 }
          cmp = (order[a.risk] || 0) - (order[b.risk] || 0)
          break
        }
        case 'name':
          cmp = ((a as any).path || (a as any).key || (a as any).name || '').localeCompare(
            (b as any).path || (b as any).key || (b as any).name || ''
          )
          break
        case 'size':
          cmp = ((a as any).size_mb || 0) - ((b as any).size_mb || 0)
          break
      }
      return sortDir === 'asc' ? cmp : -cmp
    })
    return arr
  }, [items, sortKey, sortDir])

  const totalPages = Math.ceil(sorted.length / pageSize)
  const paged = sorted.slice(page * pageSize, (page + 1) * pageSize)

  const toggleSort = (key: SortKey) => {
    if (sortKey === key) setSortDir(d => d === 'asc' ? 'desc' : 'asc')
    else { setSortKey(key); setSortDir('asc') }
  }

  const SortIcon = ({ k }: { k: SortKey }) => {
    if (sortKey !== k) return null
    return sortDir === 'asc' ? <ChevronUp className="w-3 h-3 inline" /> : <ChevronDown className="w-3 h-3 inline" />
  }

  const getDisplayPath = (item: ResidualItem): string => {
    return (item as any).path || (item as any).key || (item as any).name || (item as any).value_name || item.id || ''
  }

  if (items.length === 0) {
    return (
      <div className="text-center py-12 text-muted-foreground text-sm">
        没有匹配的残留项
      </div>
    )
  }

  return (
    <div>
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead className="w-8">
              <Checkbox
                checked={paged.every(i => selectedIds.has(i.id!)) && paged.length > 0}
                onCheckedChange={() => dispatch({ type: 'TOGGLE_ALL', ids: paged.map(i => i.id!).filter(Boolean) })}
              />
            </TableHead>
            <TableHead className="w-20 cursor-pointer" onClick={() => toggleSort('id')}>
              ID <SortIcon k="id" />
            </TableHead>
            <TableHead className="w-16 cursor-pointer" onClick={() => toggleSort('risk')}>
              风险 <SortIcon k="risk" />
            </TableHead>
            <TableHead className="w-24">类别</TableHead>
            <TableHead className="cursor-pointer" onClick={() => toggleSort('name')}>
              路径 / 名称 <SortIcon k="name" />
            </TableHead>
            <TableHead className="w-24">原因</TableHead>
            {'size_mb' in items[0] && (
              <TableHead className="w-20 text-right cursor-pointer" onClick={() => toggleSort('size')}>
                大小 <SortIcon k="size" />
              </TableHead>
            )}
          </TableRow>
        </TableHeader>
        <TableBody>
          {paged.map((item) => {
            const id = item.id!
            const catLabel = categoryLabels[id] || ''
            const isDanger = item.risk === 'danger'
            const displayPath = getDisplayPath(item)

            return (
              <TableRow key={id} className={selectedIds.has(id) ? 'bg-primary/5' : ''}>
                <TableCell>
                  <Checkbox
                    checked={selectedIds.has(id)}
                    onCheckedChange={() => dispatch({ type: 'TOGGLE_ID', id })}
                    disabled={isDanger}
                    title={isDanger ? '危险项不可自动选择' : undefined}
                  />
                </TableCell>
                <TableCell>
                  <code className="text-xs text-muted-foreground">{id}</code>
                </TableCell>
                <TableCell>
                  <Badge variant={RISK_BADGE[item.risk].variant}>
                    {RISK_BADGE[item.risk].label}
                  </Badge>
                </TableCell>
                <TableCell>
                  <span className="inline-flex items-center gap-1 text-xs text-muted-foreground">
                    {CATEGORY_ICONS[catLabel]}
                    {catLabel}
                  </span>
                </TableCell>
                <TableCell>
                  <div className="flex items-center gap-1.5">
                    <code className="text-xs">{displayPath}</code>
                  </div>
                  {item.risk === 'danger' && (
                    <div className="text-xs text-danger mt-0.5">⚠ 手动确认后方可清理</div>
                  )}
                </TableCell>
                <TableCell>
                  <span className="text-xs text-muted-foreground">{item.reason}</span>
                </TableCell>
                {'size_mb' in item && (
                  <TableCell className="text-right text-xs text-muted-foreground">
                    {(item as any).size_mb >= 1024
                      ? `${((item as any).size_mb / 1024).toFixed(1)} GB`
                      : `${Math.round((item as any).size_mb)} MB`}
                  </TableCell>
                )}
              </TableRow>
            )
          })}
        </TableBody>
      </Table>

      {/* Pagination */}
      {totalPages > 1 && (
        <div className="flex items-center justify-between px-3 py-2 text-xs text-muted-foreground">
          <span>共 {sorted.length} 项</span>
          <div className="flex items-center gap-1">
            <button
              onClick={() => setPage(p => Math.max(0, p - 1))}
              disabled={page === 0}
              className="px-2 py-1 rounded hover:bg-secondary disabled:opacity-30"
            >
              上一页
            </button>
            <span className="px-2">{page + 1} / {totalPages}</span>
            <button
              onClick={() => setPage(p => Math.min(totalPages - 1, p + 1))}
              disabled={page >= totalPages - 1}
              className="px-2 py-1 rounded hover:bg-secondary disabled:opacity-30"
            >
              下一页
            </button>
          </div>
        </div>
      )}
    </div>
  )
}
