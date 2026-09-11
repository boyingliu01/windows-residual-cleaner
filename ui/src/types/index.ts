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
  type: 'info' | 'success' | 'error' | 'step'
  timestamp: number
}
