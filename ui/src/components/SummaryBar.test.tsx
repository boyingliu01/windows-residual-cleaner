import { describe, expect, it } from 'vitest'
import { screen } from '@testing-library/react'
import { fixtureReport, renderWithApp } from '@/test'
import { SummaryBar } from './SummaryBar'

describe('SummaryBar', () => {
  it('renders nothing without a report', () => {
    const { container } = renderWithApp(<SummaryBar />)
    expect(container.firstChild).toBeNull()
  })

  it('shows risk totals, selection count and recoverable space', () => {
    const { dispatch } = renderWithApp(<SummaryBar />)
    dispatch({ type: 'SET_REPORT', report: fixtureReport })
    dispatch({ type: 'TOGGLE_ID', id: 'fs_001' })
    const valueAfter = (label: string) =>
      (screen.getByText(label).nextSibling as HTMLElement | null)?.textContent
    expect(valueAfter('总计')).toBe('3')
    expect(valueAfter('安全')).toBe('1')
    expect(valueAfter('警告')).toBe('1')
    expect(valueAfter('危险')).toBe('1')
    expect(valueAfter('已选择')).toBe('1')
    expect(valueAfter('可释放')).toBe('1.5 GB')
  })
})
