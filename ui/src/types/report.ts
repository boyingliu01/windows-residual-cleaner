// @no-test-required: Type-only contracts; the TypeScript build and consuming component tests verify their use.
import type {
  FileResidual,
  GhostService,
  GhostTask,
  PathResidual,
  RegistryResidual,
  ShellResidual,
  StartupResidual,
  UninstalledSoftware,
} from './residual'

export interface ReportSummary {
  total_residuals: number
  safe: number
  caution: number
  danger: number
  estimated_space_recoverable_mb: number
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
