import { describe, expect, it } from 'vitest'
import { cn, formatBytes } from './utils'

describe('cn', () => {
  it('joins class names and drops falsy inputs', () => {
    expect(cn('a', false, null, undefined, 'c')).toBe('a c')
  })

  it('lets later tailwind classes win conflicts', () => {
    expect(cn('p-2', 'p-4')).toBe('p-4')
  })
})

describe('formatBytes', () => {
  it('formats megabyte values', () => {
    expect(formatBytes(45)).toBe('45 MB')
  })

  it('formats gigabyte values with one decimal', () => {
    expect(formatBytes(1536)).toBe('1.5 GB')
  })
})
