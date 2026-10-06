export type RiskLevel = 'safe' | 'caution' | 'danger'

export interface ReportSummary {
  total_residuals: number
  safe: number
  caution: number
  danger: number
  estimated_space_recoverable_mb: number
}

export interface UninstalledSoftware {
  name: string
  registry_key: string
  install_location: string
  uninstall_string: string
  evidence: string[]
  source: string
}

export interface FileResidual {
  path: string
  size_mb: number
  file_count: number
  risk: RiskLevel
  reason: string
  id: string
}

export interface RegistryResidual {
  key: string
  risk: RiskLevel
  reason: string
  id: string
}

export interface GhostService {
  name: string
  binary_path: string
  risk: RiskLevel
  reason: string
  id: string
}

export interface GhostTask {
  name: string
  risk: RiskLevel
  reason: string
  id: string
}

export interface StartupResidual {
  key: string
  value_name: string
  value: string
  risk: RiskLevel
  reason: string
  id: string
}

export interface ShellResidual {
  key: string
  risk: RiskLevel
  reason: string
  id: string
}

export interface PathResidual {
  path: string
  risk: RiskLevel
  reason: string
  id: string
}

export interface FinalReport {
  scan_time: string
  summary: ReportSummary
  uninstalled_software: UninstalledSoftware[]
  filesystem_residuals: FileResidual[]
  registry_residuals: RegistryResidual[]
  ghost_services: GhostService[]
  ghost_tasks: GhostTask[]
  startup_residuals: StartupResidual[]
  shell_residuals: ShellResidual[]
  path_residuals: PathResidual[]
}

export type ResidualItem = FileResidual | RegistryResidual | GhostService | GhostTask | StartupResidual | ShellResidual | PathResidual

export interface CategoryInfo {
  key: string
  label: string
  icon: string
  prefix: string
  items: ResidualItem[]
  color: string
}

export interface CleanupLogEntry {
  success: boolean
  id: string
  path?: string
  key?: string
  name?: string
  action: string
  error?: string
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

export type AppPhase = 'idle' | 'scanning' | 'review' | 'selecting' | 'dry-run' | 'cleaning' | 'done'

export interface ScanOutputLine {
  text: string
  type: 'info' | 'success' | 'error' | 'step' | 'caution'
  timestamp: number
}

/**
 * Real protection state as recorded on disk (REQ-014 / DD-011 / AC-023 / AC-065).
 * 'unknown' means the evidence could not be read — the UI must NOT render it as available.
 */
export interface RestorePointStatus {
  state: 'available' | 'unavailable' | 'unknown'
  enabled: boolean
  /** null = written by a version that did not record whether it even tried */
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
  /** Spec: these must be listed separately from unrepaired items, never silently merged into "success". */
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
