import { describe, expect, it } from 'vitest'
import { fireEvent, screen } from '@testing-library/react'
import { fixtureReport, renderWithApp } from '@/test'
import { ItemTable } from './ItemTable'

const items = fixtureReport.filesystem_residuals
const labels = { fs_001: '文件系统残留', fs_002: '文件系统残留' }

describe('ItemTable', () => {
  it('shows an empty hint when nothing matches', () => {
    const { getByText } = renderWithApp(<ItemTable items={[]} categoryLabels={{}} />)
    expect(getByText('没有匹配的残留项')).toBeTruthy()
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

  it('disables the checkbox of danger items', () => {
    renderWithApp(<ItemTable items={items} categoryLabels={labels} />)
    const checkboxes = screen.getAllByRole('checkbox') as HTMLInputElement[]
    expect(checkboxes[2].disabled).toBe(true)
    expect(screen.getByText('⚠ 手动确认后方可清理')).toBeTruthy()
  })
})
