// @no-test-required: Type-only contracts; the TypeScript build and consuming component tests verify their use.
export type AppPhase = 'idle' | 'scanning' | 'review' | 'dry-run' | 'cleaning' | 'done'

export interface ScanOutputLine {
  text: string
  type: 'info' | 'success' | 'error' | 'step' | 'caution' | 'done'
  timestamp: number
}
