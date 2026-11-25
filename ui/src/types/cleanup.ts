// @no-test-required: Type-only contracts; the TypeScript build and consuming component tests verify their use.
export interface CleanupLogEntry {
  success: boolean
  id: string
  path?: string
  key?: string
  name?: string
  action: string
  error?: string
  renamed_to?: string
}

export interface CleanupLog {
  summary: {
    mode: string
    dry_run: boolean
    total_processed: number
    succeeded: number
    failed: number
    skipped: number
    timestamp: string
  }
  entries: CleanupLogEntry[]
}
