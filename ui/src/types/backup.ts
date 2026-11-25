// @no-test-required: Type-only contracts; the TypeScript build and consuming component tests verify their use.
export interface RestorePointStatus {
  state: 'available' | 'unavailable' | 'unknown'
  enabled: boolean
  attempted: boolean | null
  detail: string
  source: string | null
  timestamp: string | null
}

export interface UnfinishedJournal {
  backup_dir: string
  run_id: string | null
  created_at: string | null
  completed_at: string | null
  unfinished: boolean
  entries: number
}

export interface RollbackVerdict {
  item_id: string | null
  kind: string | null
  target: string | null
  verdict: string | null
  reason: string | null
  evidence_incomplete: boolean
}

export interface LastRollback {
  backup_dir: string
  run_id: string | null
  executed_at: string | null
  within_window: boolean
  counts: Record<string, number>
  verdicts: RollbackVerdict[]
}

export interface BackupStatus {
  restore_point: RestorePointStatus
  precise_protection: {
    mechanism: string
    journals: number
    unfinished: number
    newest_unfinished: UnfinishedJournal | null
  }
  last_rollback: LastRollback | null
  recovery_window_hours: number
}
