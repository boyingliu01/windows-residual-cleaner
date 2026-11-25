import { describe, expect, it, vi, afterEach } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import { fixtureReport, jsonResponse, renderWithApp } from '@/test'
import App, { PhaseContent } from './App'
import type { AppPhase } from '@/types/app'

afterEach(() => {
  vi.unstubAllGlobals()
})

function expectPhasePanel(phase: AppPhase, marker: string) {
  if (phase === 'dry-run' || phase === 'cleaning' || phase === 'done') {
    expect(screen.getByRole('heading', { name: marker }).textContent).toBe(marker)
  } else {
    expect(screen.getByText(marker).textContent).toBe(marker)
  }
}

function expectOtherPanelHidden(phase: AppPhase) {
  const hiddenText = phase === 'idle' || phase === 'scanning' ? '显示 3 / 3 项' : '扫描系统残留'
  expect(screen.queryByText(hiddenText)).toBeNull()
}

describe('App', () => {
  it('renders the shell and the idle scan panel', () => {
    render(<App />)
    expect(screen.getByText('Windows 残留清理').textContent).toBe('Windows 残留清理')
    expect(screen.getByText('就绪').textContent).toBe('就绪')
    expect(screen.getByText('扫描系统残留').textContent).toBe('扫描系统残留')
    expect(screen.getByText('开始扫描').textContent).toBe('开始扫描')
  })

  it('links to the actual repository', () => {
    render(<App />)
    expect(screen.getByRole('link').getAttribute('href')).toBe('https://github.com/boyingliu01/windows-residual-cleaner')
  })

  it('opens and closes the mobile navigation', () => {
    render(<App />)
    fireEvent.click(screen.getAllByRole('button')[0])
    expect(screen.getByText('审查残留项').textContent).toBe('审查残留项')
    fireEvent.click(screen.getByText('审查残留项'))
    expect(screen.getByText('审查残留项').textContent).toBe('审查残留项')
    fireEvent.click(screen.getAllByRole('button')[0])
    expect(screen.queryByText('审查残留项')).toBeNull()
  })

  it('starts on the idle phase with forward navigation locked', () => {
    render(<App />)
    const reviewNav = screen.getByRole('button', { name: '审查' })
    expect((reviewNav as HTMLButtonElement).disabled).toBe(true)
    const startNav = screen.getByRole('button', { name: '开始' })
    expect((startNav as HTMLButtonElement).disabled).toBe(false)
  })

  it.each<{ phase: AppPhase; marker: string }>([
    { phase: 'idle', marker: '扫描系统残留' },
    { phase: 'scanning', marker: '扫描系统残留' },
    { phase: 'review', marker: '显示 3 / 3 项' },
    { phase: 'dry-run', marker: 'DryRun 预览' },
    { phase: 'cleaning', marker: '执行清理' },
    { phase: 'done', marker: '清理状态' },
  ])('renders the matching panel for the $phase phase', async ({ phase, marker }) => {
    vi.stubGlobal('fetch', vi.fn(async () => jsonResponse(null, false)))
    const { dispatch } = renderWithApp(<PhaseContent phase={phase} />)
    dispatch({ type: 'SET_PHASE', phase })
    dispatch({ type: 'SET_REPORT', report: fixtureReport })

    if (phase === 'dry-run' || phase === 'cleaning' || phase === 'done') {
      expect(await screen.findByText(/保护状态未知/)).toBeTruthy()
    }
    expectPhasePanel(phase, marker)
    expectOtherPanelHidden(phase)
  })
})
