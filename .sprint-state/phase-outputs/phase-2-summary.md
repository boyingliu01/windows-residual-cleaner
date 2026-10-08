# Phase 2/6: DESIGN — sprint-2026-10-01-01 (auto-rollback)

status: completed (released **with recorded dissent**, not by consensus)
delphi artifact: `.sprint-state/delphi-reviewed.json` — `mode: design`,
`verdict: APPROVED`, `consensus_ratio: 0`, `converged: false`, `dissent_recorded: true`,
`design_hash: bfb0032bde5fd66d91381723e53523588504653b4b46a21755badd3d984389ab`,
`head_commit: 34a0817`
design document: `docs/plans/2026-10-02-auto-rollback-design.md`
requirements: `.sprint-state/phase-outputs/requirements-auto-rollback.md`, `specification.yaml`

## Deliverables

- Normative requirement set REQ-024 … REQ-031 with acceptance criteria (AC-060 … AC-094), plus
  the DD-xxx design decisions.
- The three contracts that BUILD later implemented verbatim: the single authoritative restore
  decision table (REQ-024), the atomic journal write protocol (REQ-005), and the T3 startup-recovery
  consumption protocol (REQ-019 / REQ-031).
- `to-issues` slices (S1 journal core, S2 T3 crash recovery, S3 `-Auto` entry, S4 UI honesty).

## Decisions taken

- **DR-003 / DR-007** — automatic = **in-process targeted undo** of the reversible subset only.
  The tool arms and documents a restore point but **never fires `Restore-Computer` itself**
  (it reverts unrelated user work and forces a reboot). Capability ceiling written into §3.6/§3.7;
  the tool may never claim deleted file/service/task data was recovered.
- **DR-004** — real-machine writes: authorized in principle, but **ask before each destructive or
  admin-level write and wait**. Tests may only touch self-created `HKCU\Software\WRC-*` fixtures and
  must remove them.
- **DR-005** — sprint `phase` is owned by the `xp-gate` CLI, not hand-written; fabricating a
  `delphi-reviewed.json` to satisfy Gate 11 would defeat the gate.
- **DR-006** — design HARD-GATE approved with all four recommendations: Q1 in-process rollback,
  Q2 trigger on `summary.failed > 0` with **per-item** undo, Q4 fold the four extra defects into
  this sprint (PATH pre-image, truthful `path_deleted`, real backup precondition, loud failure from
  `create-restore-point.ps1`), Q6 admin drill includes a real restore-point creation attempt.
- **DR-009 (DD-018)** — bound the restore claim in prose instead of stacking unprovable flags.
- **DR-010 / DR-011** — the panels did not converge: R1 requirements review ran 11 rounds to
  convergence then needed 22 rounds at release; R2 design review was released at **0/3 approvals
  after 4 rounds** with the same non-convergence signature. Both were released by explicit user
  decision with the dissent recorded in this file — see the honesty note below.

## Honesty note on the review outcome (do not read this as a green stamp)

`.sprint-state/delphi-reviewed.json` carries `verdict: APPROVED` (the release decision Gate 11
reads) while simultaneously recording `consensus_ratio: 0`, `converged: false`,
`dissent_recorded: true`, and per-expert `REQUEST_CHANGES`. The two numbers mean different things
and neither is a mistake: **the design was released by decision, not by panel consensus.**
The dissent items were then re-checked one by one in VERIFY (**DR-012**: 29 findings, 27 resolved,
2 residual) rather than being argued down.

The design document's sha256 is frozen as `design_hash`; amendments go to `specification.yaml`,
`AGENTS.md`, `CHANGELOG.md` and this file — editing that document destroys review provenance.

## next_phase_context

BUILD implements the decision table literally; any divergence found while coding is a spec defect
to be raised, not silently patched in the script. VERIFY must re-measure tests/coverage on both
engines by hand, because the PowerShell gates SKIP silently when `pwsh`/`node` are off the git PATH.
