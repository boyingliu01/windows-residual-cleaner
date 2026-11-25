import { describe, expect, it, vi, afterEach } from 'vitest'
import { fireEvent, screen, waitFor } from '@testing-library/react'
import { fixtureReport, jsonResponse, renderWithApp, sseResponse } from '@/test'
import { ScanPanel } from './ScanPanel'

afterEach(() => {
  vi.unstubAllGlobals()
})

function controllableScan() {
  const encoder = new TextEncoder()
  let controller!: ReadableStreamDefaultController<Uint8Array>
  let signal: AbortSignal | null | undefined
  const body = new ReadableStream<Uint8Array>({
    start(streamController) { controller = streamController },
  })
  vi.stubGlobal('fetch', vi.fn((_input: RequestInfo | URL, init?: RequestInit) => {
    signal = init?.signal
    return Promise.resolve({ ok: true, body } as Response)
  }))
  return {
    emit: (line: unknown) => controller.enqueue(encoder.encode(JSON.stringify(line) + '\n')),
    close: () => controller.close(),
    getSignal: () => signal,
  }
}

function stepRow(label: string): HTMLElement {
  return screen.getByText(label).parentElement!
}

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

    expect((await screen.findByText('未找到现有报告，请先执行扫描')).textContent).toBe('未找到现有报告，请先执行扫描')
  })

  it('returns to idle when an in-flight scan is cancelled', async () => {
    vi.stubGlobal('fetch', vi.fn(() => new Promise<Response>(() => {})))
    const { app } = renderWithApp(<ScanPanel />)
    fireEvent.click(screen.getByText('开始扫描'))
    expect(app.current?.state.phase).toBe('scanning')
    fireEvent.click(screen.getByText('取消扫描'))
    expect(app.current?.state.phase).toBe('idle')
    expect(screen.getByText('开始扫描')).toBeTruthy()
  })

  it('renders the six pipeline steps up front', () => {
    renderWithApp(<ScanPanel />)
    expect(screen.getByText(/正在创建系统还原点/).textContent).toMatch(/正在创建系统还原点/)
    expect(screen.getByText(/正在生成最终报告/).textContent).toMatch(/正在生成最终报告/)
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

  it('marks pending, active and completed pipeline steps without completing future steps', async () => {
    const stream = controllableScan()
    renderWithApp(<ScanPanel />)
    const first = stepRow('正在创建系统还原点...')
    const second = stepRow('正在构建已安装软件索引...')
    const third = stepRow('正在扫描已卸载残留...')
    expect(first.firstElementChild?.className).toContain('bg-secondary')
    expect(first.textContent).toContain('1')
    expect(second.textContent).toContain('2')

    fireEvent.click(screen.getByRole('button', { name: '开始扫描' }))
    await waitFor(() => expect(stream.getSignal()).not.toBeNull())
    expect(first.firstElementChild?.className).toContain('bg-primary')
    expect(first.querySelector('.animate-spin')).toBeTruthy()
    expect(second.textContent).toContain('2')

    stream.emit({ type: 'step', text: '正在构建已安装软件索引...' })
    await waitFor(() => expect(second.firstElementChild?.className).toContain('bg-primary'))
    expect(first.firstElementChild?.className).toContain('bg-safe')
    expect(first.querySelector('.animate-spin')).toBeNull()
    expect(second.querySelector('.animate-spin')).toBeTruthy()
    expect(third.textContent).toContain('3')

    stream.emit({ type: 'done', report: fixtureReport })
    stream.close()
    expect(await screen.findByText(/已有扫描报告/)).toBeTruthy()
    expect(first.firstElementChild?.className).toContain('bg-safe')
    expect(second.firstElementChild?.className).toContain('bg-secondary')
    expect(second.querySelector('.animate-spin')).toBeNull()
    expect(second.textContent).toContain('2')
    expect(third.textContent).toContain('3')
  })

  it('aborts the actual request when an in-flight scan is cancelled', async () => {
    const stream = controllableScan()
    const { app } = renderWithApp(<ScanPanel />)

    fireEvent.click(screen.getByRole('button', { name: '开始扫描' }))
    await waitFor(() => expect(stream.getSignal()).not.toBeNull())
    fireEvent.click(screen.getByRole('button', { name: '取消扫描' }))

    expect(stream.getSignal()?.aborted).toBe(true)
    expect(app.current?.state.phase).toBe('idle')
    expect(screen.getByRole('button', { name: '开始扫描' })).toBeTruthy()
    stream.close()
  })
})
