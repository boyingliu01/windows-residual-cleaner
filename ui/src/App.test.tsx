import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import App from './App'

describe('App', () => {
  it('renders the shell and the idle scan panel', () => {
    render(<App />)
    expect(screen.getByText('Windows 残留清理')).toBeTruthy()
    expect(screen.getByText('就绪')).toBeTruthy()
    expect(screen.getByText('扫描系统残留')).toBeTruthy()
    expect(screen.getByText('开始扫描')).toBeTruthy()
  })

  it('starts on the idle phase with forward navigation locked', () => {
    render(<App />)
    const reviewNav = screen.getByRole('button', { name: '审查' })
    expect((reviewNav as HTMLButtonElement).disabled).toBe(true)
    const startNav = screen.getByRole('button', { name: '开始' })
    expect((startNav as HTMLButtonElement).disabled).toBe(false)
  })
})
