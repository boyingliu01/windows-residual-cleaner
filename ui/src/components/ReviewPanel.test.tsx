import { describe, expect, it, vi, afterEach } from 'vitest'
import { fireEvent, screen, waitFor } from '@testing-library/react'
import { fixtureReport, renderWithApp } from '@/test'
import { ReviewPanel } from './ReviewPanel'

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('ReviewPanel', () => {
  it('renders nothing without a report', () => {
    const { container } = renderWithApp(<ReviewPanel />)
    expect(container.firstChild).toBeNull()
  })

  it('shows item rows, filters and tabs once a report is loaded', () => {
    const { dispatch } = renderWithApp(<ReviewPanel />)
    dispatch({ type: 'SET_REPORT', report: fixtureReport })

    expect(screen.getByText('C:/ProgramData/OldApp')).toBeTruthy()
    expect(screen.getByText('HKCU:/Software/OldApp')).toBeTruthy()
    expect(screen.getByText('显示 3 / 3 项')).toBeTruthy()
    expect(screen.getByPlaceholderText('搜索路径、ID、名称...')).toBeTruthy()
    expect(screen.getByText('全部风险等级')).toBeTruthy()
    // Categories with zero items get no tab
    expect(screen.queryByText(/Shell扩展残留/)).toBeNull()
    expect(screen.queryByText(/PATH残留/)).toBeNull()
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
})
