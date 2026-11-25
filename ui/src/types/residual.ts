// @no-test-required: Type-only contracts; the TypeScript build and consuming component tests verify their use.
export type RiskLevel = 'safe' | 'caution' | 'danger'

interface ResidualBase {
  risk: RiskLevel
  reason: string
  id: string
}

export interface UninstalledSoftware extends ResidualBase {
  name: string
  registry_key: string
  install_location: string
  uninstall_string: string
  evidence: string[]
  source: string
  actionable: boolean
  actionable_reason?: string
  key?: string
}

export interface FileResidual extends ResidualBase {
  path: string
  size_mb: number
  file_count: number
}

export interface RegistryResidual extends ResidualBase {
  key: string
}

export interface GhostService extends ResidualBase {
  name: string
  binary_path: string
}

export interface GhostTask extends ResidualBase {
  name: string
}

export interface StartupResidual extends ResidualBase {
  key: string
  value_name: string
  value: string
}

export interface ShellResidual extends ResidualBase {
  key: string
}

export interface PathResidual extends ResidualBase {
  path: string
}

export type ResidualItem =
  | FileResidual
  | RegistryResidual
  | GhostService
  | GhostTask
  | StartupResidual
  | ShellResidual
  | PathResidual
  | UninstalledSoftware
