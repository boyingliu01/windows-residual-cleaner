import { describe, expect, it, vi, afterEach } from 'vitest'
import { fireEvent, screen, waitFor } from '@testing-library/react'
import { fixtureReport, renderWithApp } from '@/test'
import type { FinalReport } from '@/types/report'
import { ReviewPanel } from './ReviewPanel'

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('ReviewPanel', () => {
  it('renders nothing without a report', () => {
    const { container } = renderWithApp(<ReviewPanel />)
    expect(container.childNodes).toHaveLength(0)
  })

  it('shows item rows, filters and tabs once a report is loaded', () => {
    const { dispatch } = renderWithApp(<ReviewPanel />)
    dispatch({ type: 'SET_REPORT', report: fixtureReport })

    expect(screen.getByText('C:/ProgramData/OldApp').textContent).toBe('C:/ProgramData/OldApp')
    expect(screen.getByText('HKCU:/Software/OldApp').textContent).toBe('HKCU:/Software/OldApp')
    expect(screen.getByText('显示 3 / 3 项').textContent).toBe('显示 3 / 3 项')
    expect(screen.getByPlaceholderText('搜索路径、ID、名称...').getAttribute('placeholder')).toBe('搜索路径、ID、名称...')
    expect(screen.getByText('全部风险等级').textContent).toBe('全部风险等级')
    // Categories with zero items get no tab
    expect(screen.queryByText(/Shell扩展残留/)).toBeNull()
    expect(screen.queryByText(/PATH残留/)).toBeNull()
  })

  it('shows uninstalled evidence and only allows actionable entries to be selected', () => {
    const report = {
      ...fixtureReport,
      uninstalled_software: [
        {
          id: 'uni_001', registry_key: 'HKCU:/Software/GoneApp', key: 'HKCU:/Software/GoneApp',
          name: 'GoneApp', install_location: 'C:/GoneApp', uninstall_string: 'C:/GoneApp/uninstall.exe',
          source: 'HKCU', evidence: ['directory missing', 'uninstaller missing'],
          risk: 'caution', reason: 'install directory and uninstaller are missing', actionable: true,
        },
        {
          id: 'uni_002', registry_key: 'HKCU:/Software/UnknownApp', name: 'UnknownApp',
          install_location: '', uninstall_string: 'MsiExec.exe /X{GUID}', source: 'HKCU', evidence: ['uninstaller unknown'],
          risk: 'caution', reason: 'missing path evidence', actionable: false, actionable_reason: 'evidence incomplete',
        },
      ],
    } as unknown as FinalReport
    const { app, dispatch } = renderWithApp(<ReviewPanel />)
    dispatch({ type: 'SET_REPORT', report })
    expect(app.current?.allItemIds).toContain('uni_001')
    expect(app.current?.allItemIds).not.toContain('uni_002')

    fireEvent.click(screen.getByRole('button', { name: /已卸载软件/ }))
    const actionable = screen.getByText('HKCU:/Software/GoneApp').closest('tr')!
    const evidenceOnly = screen.getByText('HKCU:/Software/UnknownApp').closest('tr')!
    fireEvent.click(actionable.querySelector('input[type="checkbox"]')!)
    expect(app.current?.state.selectedIds.has('uni_001')).toBe(true)
    expect((evidenceOnly.querySelector('input[type="checkbox"]') as HTMLInputElement).disabled).toBe(true)
    expect(app.current?.state.selectedIds.has('uni_002')).toBe(false)

    fireEvent.click(screen.getByText('选所有警告项'))
    expect(app.current?.state.selectedIds.has('uni_001')).toBe(true)
    expect(app.current?.state.selectedIds.has('uni_002')).toBe(false)
  })

  it('selects all safe items and moves to dry-run after confirmation', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: true } as Response)))
    const { app, dispatch } = renderWithApp(<ReviewPanel />)
    dispatch({ type: 'SET_REPORT', report: fixtureReport })

    fireEvent.click(screen.getByText('选所有安全项'))
    expect(app.current?.state.selectedIds.size).toBe(1)
    expect(app.current?.state.selectedIds.has('fs_001')).toBe(true)

    fireEvent.click(screen.getByText('确认选择 (1)'))
    expect(screen.getByText(/你已选择/)).toBeTruthy()
    fireEvent.click(screen.getByText('确认并继续'))

    await waitFor(() => expect(app.current?.state.phase).toBe('dry-run'))
  })

  it('searches paths, keys and ids case-insensitively and restores all rows when cleared', () => {
    const { dispatch } = renderWithApp(<ReviewPanel />)
    dispatch({ type: 'SET_REPORT', report: fixtureReport })
    const search = screen.getByPlaceholderText('搜索路径、ID、名称...')

    fireEvent.change(search, { target: { value: 'OLDAPP' } })
    expect(screen.getByText('显示 2 / 3 项').textContent).toBe('显示 2 / 3 项')
    expect(screen.getByText('C:/ProgramData/OldApp').textContent).toBe('C:/ProgramData/OldApp')
    expect(screen.getByText('HKCU:/Software/OldApp').textContent).toBe('HKCU:/Software/OldApp')
    expect(screen.queryByText('C:/ProgramData/Other')).toBeNull()

    fireEvent.change(search, { target: { value: 'FS_001' } })
    expect(screen.getByText('显示 1 / 3 项').textContent).toBe('显示 1 / 3 项')
    expect(screen.getByText('C:/ProgramData/OldApp').textContent).toBe('C:/ProgramData/OldApp')

    fireEvent.change(search, { target: { value: '' } })
    expect(screen.getByText('显示 3 / 3 项')).toBeTruthy()
  })

  it('intersects category, risk and search filters', () => {
    const { dispatch } = renderWithApp(<ReviewPanel />)
    dispatch({ type: 'SET_REPORT', report: fixtureReport })

    fireEvent.click(screen.getByRole('button', { name: /文件系统残留/ }))
    expect(screen.getByText('显示 2 / 3 项')).toBeTruthy()
    fireEvent.change(screen.getByRole('combobox'), { target: { value: 'caution' } })
    expect(screen.getByText('显示 0 / 3 项')).toBeTruthy()
    expect(screen.getByText('没有匹配的残留项')).toBeTruthy()

    fireEvent.change(screen.getByRole('combobox'), { target: { value: 'safe' } })
    expect(screen.getByText('显示 1 / 3 项')).toBeTruthy()
    fireEvent.change(screen.getByPlaceholderText('搜索路径、ID、名称...'), { target: { value: 'OTHER' } })
    expect(screen.getByText('显示 0 / 3 项')).toBeTruthy()
    fireEvent.change(screen.getByPlaceholderText('搜索路径、ID、名称...'), { target: { value: '' } })
    fireEvent.change(screen.getByPlaceholderText('搜索路径、ID、名称...'), { target: { value: 'OldApp' } })
    expect(screen.getByText('显示 1 / 3 项')).toBeTruthy()
    fireEvent.change(screen.getByPlaceholderText('搜索路径、ID、名称...'), { target: { value: '' } })

    fireEvent.click(screen.getByRole('button', { name: '全部' }))
    fireEvent.change(screen.getByRole('combobox'), { target: { value: 'danger' } })
    expect(screen.getByText('显示 1 / 3 项')).toBeTruthy()
    expect(screen.getByText('C:/ProgramData/Other')).toBeTruthy()
    const dangerRow = screen.getByText('C:/ProgramData/Other').closest('tr')!
    expect((dangerRow.querySelector('input[type="checkbox"]') as HTMLInputElement).disabled).toBe(true)
  })

  it('searches startup value names, values and category labels', () => {
    const report = {
      ...fixtureReport,
      summary: { ...fixtureReport.summary, total_residuals: 1, safe: 0, caution: 1, danger: 0 },
      filesystem_residuals: [],
      registry_residuals: [],
      startup_residuals: [{
        id: 'str_001', key: 'HKCU:/Software/Microsoft/Windows/CurrentVersion/Run',
        value_name: 'LegacyHelper', value: 'C:/Tools/Helper.exe', risk: 'caution', reason: 'missing target',
      }],
    } as FinalReport
    const { dispatch } = renderWithApp(<ReviewPanel />)
    dispatch({ type: 'SET_REPORT', report })
    const search = screen.getByPlaceholderText('搜索路径、ID、名称...')

    for (const query of ['legacyhelper', 'HELPER.EXE', 'str_001', '启动项残留']) {
      fireEvent.change(search, { target: { value: query } })
      expect(screen.getByText('显示 1 / 1 项').textContent).toBe('显示 1 / 1 项')
      expect(screen.getByText('HKCU:/Software/Microsoft/Windows/CurrentVersion/Run').textContent)
        .toBe('HKCU:/Software/Microsoft/Windows/CurrentVersion/Run')
    }
  })
})
