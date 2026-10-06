import { describe, expect, it, vi, afterEach } from 'vitest'
import { fireEvent, screen } from '@testing-library/react'
import { fixtureReport, jsonResponse, renderWithApp, sseResponse } from '@/test'
import { ScanPanel } from './ScanPanel'

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('ScanPanel', () => {
  it('streams the scan, loads the report and moves to review', async () => {
    vi.stubGlobal('fetch', vi.fn(async () =>
      sseResponse([
        { text: '正在扫描文件系统残留', type: 'step' },
        { type: 'done', report: fixtureReport },
      ]),
    ))
    const { app } = renderWithApp(<ScanPanel />)

    fireEvent.click(screen.getByText('开始扫描'))

    expect(await screen.findByText('正在扫描文件系统残留')).toBeTruthy()
    expect(await screen.findByText(/已有扫描报告/)).toBeTruthy()
    expect(app.current?.state.phase).toBe('review')
    expect(app.current?.state.report?.summary.total_residuals).toBe(3)
  })

  it('shows an error when loading an existing report fails', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => jsonResponse(null, false)))
    renderWithApp(<ScanPanel />)

    fireEvent.click(screen.getByText('加载已有报告'))

    expect(await screen.findByText('未找到现有报告，请先执行扫描')).toBeTruthy()
  })

  it('renders the six pipeline steps up front', () => {
    renderWithApp(<ScanPanel />)
    expect(screen.getByText(/正在创建系统还原点/)).toBeTruthy()
    expect(screen.getByText(/正在生成最终报告/)).toBeTruthy()
  })

  it('does not claim a finished scan when the pipeline streamed an error', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => sseResponse([
      { type: 'step', text: '正在创建系统还原点...' },
      { type: 'success', text: 'run-all.ps1 完成' },
      { type: 'error', text: 'run-all.ps1: 权限不足，已中止' },
    ])))
    const { app } = renderWithApp(<ScanPanel />)

    fireEvent.click(screen.getByText('开始扫描'))

    // Both the console and the banner must carry it: a step can succeed while the
    // pipeline as a whole failed, and the headline may not pretend otherwise.
    const shown = await screen.findAllByText('run-all.ps1: 权限不足，已中止')
    expect(shown.length).toBe(2)
    expect(screen.queryByText(/已有扫描报告/)).toBeNull()
    expect(app.current?.state.report).toBeNull()
    expect(screen.getByText('开始扫描')).toBeTruthy()
  })

  it('keeps the caution line from the optional restore-point layer visibly separate', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => sseResponse([
      { type: 'caution', text: '可选系统还原点未建立（System Protection 关闭 / 24h 节流 / 无权限）' },
      { type: 'done', report: fixtureReport },
    ])))
    renderWithApp(<ScanPanel />)

    fireEvent.click(screen.getByText('开始扫描'))

    const line = await screen.findByText(/可选系统还原点未建立/)
    expect(line.className).toContain('text-caution')
    expect(screen.getByText(/已有扫描报告/)).toBeTruthy()
  })
})
