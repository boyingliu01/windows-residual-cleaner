import { describe, expect, it } from 'vitest'
import { fireEvent, screen } from '@testing-library/react'
import { fixtureReport, renderWithApp } from '@/test'
import type { ResidualItem } from '@/types/residual'
import { ItemTable } from './ItemTable'

const items = fixtureReport.filesystem_residuals
const labels = { fs_001: '文件系统残留', fs_002: '文件系统残留' }

function visibleIds(): string[] {
  return screen.getAllByRole('row').slice(1)
    .map(row => row.querySelector('code')?.textContent ?? '')
}

describe('ItemTable', () => {
  it('shows an empty hint when nothing matches', () => {
    const { getByText } = renderWithApp(<ItemTable items={[]} categoryLabels={{}} />)
    expect(getByText('没有匹配的残留项').textContent).toBe('没有匹配的残留项')
  })

  it('renders ids, paths and reasons; toggling a checkbox selects the item', () => {
    const { app } = renderWithApp(<ItemTable items={items} categoryLabels={labels} />)
    expect(screen.getByText('fs_001')).toBeTruthy()
    expect(screen.getByText('C:/ProgramData/OldApp')).toBeTruthy()
    expect(screen.getByText('orphan directory')).toBeTruthy()

    const checkboxes = screen.getAllByRole('checkbox') as HTMLInputElement[]
    // [0] = header select-all, then one per row
    fireEvent.click(checkboxes[1])
    expect(app.current?.state.selectedIds.has('fs_001')).toBe(true)
    expect(app.current?.state.selectedIds.has('fs_002')).toBe(false)
  })

  it('never selects danger items through the page header', () => {
    const { app } = renderWithApp(<ItemTable items={items} categoryLabels={labels} />)
    fireEvent.click(screen.getAllByRole('checkbox')[0])
    expect(app.current?.state.selectedIds.has('fs_001')).toBe(true)
    expect(app.current?.state.selectedIds.has('fs_002')).toBe(false)
  })

  it('disables the checkbox of danger items', () => {
    renderWithApp(<ItemTable items={items} categoryLabels={labels} />)
    const checkboxes = screen.getAllByRole('checkbox') as HTMLInputElement[]
    expect(checkboxes[2].disabled).toBe(true)
    expect(screen.getByText('⚠ 手动确认后方可清理')).toBeTruthy()
  })

  it('displays registry_key when no path, key, or name is available', () => {
    const item: ResidualItem = {
      id: 'uni_001', registry_key: 'HKCU:/Software/RegistryOnly', risk: 'caution', reason: 'missing evidence',
      name: '', install_location: '', uninstall_string: '', evidence: [], source: 'HKCU', actionable: false,
    }
    renderWithApp(<ItemTable items={[item]} categoryLabels={{ uni_001: '已卸载软件' }} />)
    expect(screen.getByText('HKCU:/Software/RegistryOnly').textContent).toBe('HKCU:/Software/RegistryOnly')
  })

  it('excludes non-actionable items from page select-all', () => {
    const reportItems: ResidualItem[] = [
      {
        id: 'uni_001', registry_key: 'HKCU:/Software/Actionable', name: 'Actionable',
        install_location: '', uninstall_string: '', evidence: [], source: 'HKCU',
        risk: 'caution', reason: 'missing evidence', actionable: true,
      },
      {
        id: 'uni_002', registry_key: 'HKCU:/Software/Incomplete', name: 'Incomplete',
        install_location: '', uninstall_string: '', evidence: [], source: 'HKCU',
        risk: 'safe', reason: 'missing evidence', actionable: false,
      },
    ]
    const { app } = renderWithApp(<ItemTable items={reportItems} categoryLabels={{}} />)
    fireEvent.click(screen.getAllByRole('checkbox')[0])
    expect(app.current?.state.selectedIds.has('uni_001')).toBe(true)
    expect(app.current?.state.selectedIds.has('uni_002')).toBe(false)
  })

  it.each([
    {
      label: 'prefers path over every other display field',
      fields: { path: 'C:/Path', key: 'HKCU:/Key', registry_key: 'HKCU:/Registry', name: 'Name', value_name: 'ValueName' },
      expected: 'C:/Path',
    },
    {
      label: 'prefers key over registry_key and name',
      fields: { path: '', key: 'HKCU:/Key', registry_key: 'HKCU:/Registry', name: 'Name', value_name: 'ValueName' },
      expected: 'HKCU:/Key',
    },
    {
      label: 'prefers registry_key over name',
      fields: { registry_key: 'HKCU:/Registry', name: 'Name', value_name: 'ValueName' },
      expected: 'HKCU:/Registry',
    },
    {
      label: 'prefers name over value_name',
      fields: { name: 'Name', value_name: 'ValueName' },
      expected: 'Name',
    },
    {
      label: 'falls back to value_name',
      fields: { name: '', value_name: 'ValueName' },
      expected: 'ValueName',
    },
    {
      label: 'ignores non-string fields and falls back to id',
      fields: { path: 42, key: null, registry_key: false, name: {}, value_name: [] },
      expected: 'fallback_id',
    },
  ])('$label', ({ fields, expected }) => {
    const item = { id: 'fallback_id', risk: 'safe', reason: 'test', ...fields } as unknown as ResidualItem
    renderWithApp(<ItemTable items={[item]} categoryLabels={{}} />)
    expect(screen.getAllByText(expected).length).toBeGreaterThan(0)
  })

  it('sorts every supported column in both directions', () => {
    const sortableItems: ResidualItem[] = [
      { id: 'item_c', path: 'C:/Same', size_mb: 10, file_count: 1, risk: 'danger', reason: 'test' },
      { id: 'item_a', path: 'A:/Same', size_mb: 2, file_count: 1, risk: 'safe', reason: 'test' },
      { id: 'item_b', key: 'HKCU:/Same', risk: 'caution', reason: 'test' },
    ]
    renderWithApp(<ItemTable items={sortableItems} categoryLabels={{}} />)

    expect(visibleIds()).toEqual(['item_a', 'item_b', 'item_c'])
    fireEvent.click(screen.getByRole('columnheader', { name: /^ID/ }))
    expect(visibleIds()).toEqual(['item_a', 'item_b', 'item_c'])
    fireEvent.click(screen.getByRole('columnheader', { name: /^ID/ }))
    expect(visibleIds()).toEqual(['item_c', 'item_b', 'item_a'])

    fireEvent.click(screen.getByRole('columnheader', { name: /^风险/ }))
    expect(visibleIds()).toEqual(['item_a', 'item_b', 'item_c'])
    fireEvent.click(screen.getByRole('columnheader', { name: /^风险/ }))
    expect(visibleIds()).toEqual(['item_c', 'item_b', 'item_a'])

    fireEvent.click(screen.getByRole('columnheader', { name: /^路径/ }))
    expect(visibleIds()).toEqual(['item_a', 'item_c', 'item_b'])
    fireEvent.click(screen.getByRole('columnheader', { name: /^路径/ }))
    expect(visibleIds()).toEqual(['item_b', 'item_c', 'item_a'])

    fireEvent.click(screen.getByRole('columnheader', { name: /^大小/ }))
    expect(visibleIds()).toEqual(['item_b', 'item_a', 'item_c'])
    fireEvent.click(screen.getByRole('columnheader', { name: /^大小/ }))
    expect(visibleIds()).toEqual(['item_c', 'item_a', 'item_b'])
  })

  it('keeps equal-key rows stable without mutating the input array', () => {
    const tiedItems: ResidualItem[] = [
      { id: 'third', key: 'HKCU:/Same', risk: 'caution', reason: 'test' },
      { id: 'first', key: 'HKCU:/Same', risk: 'caution', reason: 'test' },
      { id: 'second', key: 'HKCU:/Same', risk: 'caution', reason: 'test' },
    ]
    const originalIds = tiedItems.map(item => item.id)
    renderWithApp(<ItemTable items={tiedItems} categoryLabels={{}} />)

    fireEvent.click(screen.getByRole('columnheader', { name: /^风险/ }))
    expect(visibleIds()).toEqual(originalIds)
    fireEvent.click(screen.getByRole('columnheader', { name: /^风险/ }))
    expect(visibleIds()).toEqual(originalIds)
    expect(tiedItems.map(item => item.id)).toEqual(originalIds)
  })
})
