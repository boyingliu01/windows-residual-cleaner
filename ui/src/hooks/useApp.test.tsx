import { describe, expect, it, vi, afterEach } from 'vitest'
import { render } from '@testing-library/react'
import { fixtureReport, renderWithApp } from '@/test'
import { useApp, confirmCleanup } from './useApp'

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('app reducer', () => {
  it('toggles a selected id on and off', () => {
    const { app, dispatch } = renderWithApp(null)
    dispatch({ type: 'TOGGLE_ID', id: 'fs_001' })
    expect(app.current?.state.selectedIds.has('fs_001')).toBe(true)
    dispatch({ type: 'TOGGLE_ID', id: 'fs_001' })
    expect(app.current?.state.selectedIds.has('fs_001')).toBe(false)
  })

  it('selects all ids of a risk level and keeps existing selection', () => {
    const { app, dispatch } = renderWithApp(null)
    dispatch({ type: 'TOGGLE_ID', id: 'fs_001' })
    dispatch({ type: 'SELECT_ALL_RISK', risk: 'caution', ids: ['reg_001', 'fs_001'] })
    expect(app.current?.state.selectedIds.has('reg_001')).toBe(true)
    expect(app.current?.state.selectedIds.has('fs_001')).toBe(true)
  })

  it('clears selection and stores errors', () => {
    const { app, dispatch } = renderWithApp(null)
    dispatch({ type: 'TOGGLE_ID', id: 'fs_001' })
    dispatch({ type: 'CLEAR_SELECTION' })
    expect(app.current?.state.selectedIds.size).toBe(0)
    dispatch({ type: 'SET_ERROR', error: 'boom' })
    expect(app.current?.state.error).toBe('boom')
  })

  it('collects all item ids from every report category', () => {
    const { app, dispatch } = renderWithApp(null)
    dispatch({ type: 'SET_REPORT', report: fixtureReport })
    expect(app.current?.allItemIds).toEqual(['fs_001', 'fs_002', 'reg_001'])
  })
})

describe('useApp guard', () => {
  it('throws when used outside AppProvider', () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    function Naked() {
      useApp()
      return null
    }
    expect(() => render(<Naked />)).toThrow('useApp must be used within AppProvider')
    spy.mockRestore()
  })
})

describe('confirmCleanup', () => {
  it('returns true when the API accepts the ids', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: true } as Response)))
    await expect(confirmCleanup(['fs_001'])).resolves.toBe(true)
  })

  it('returns false when the API rejects or the request fails', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: false } as Response)))
    await expect(confirmCleanup(['fs_001'])).resolves.toBe(false)
    vi.stubGlobal('fetch', vi.fn(async () => { throw new Error('network down') }))
    await expect(confirmCleanup(['fs_001'])).resolves.toBe(false)
  })
})
