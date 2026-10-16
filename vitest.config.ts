import { defineConfig } from 'vitest/config'

// Root vitest runs ONLY the API-server tests (node environment).
//
// Why a scoped config instead of collecting everything: the xp-gate pre-commit
// hook (Gate 5) executes `npx vitest run --coverage` from the REPO ROOT, where
// jsdom/react are not resolvable - the React component suite keeps its own
// jsdom config in ui/vite.config.ts and is run by the UI toolchain
// (cd ui && npm test, mirrored in CI). Without this scope a root full-run
// would collect ui/src/**/*.test.tsx and fail on module resolution, not on
// real regressions.
export default defineConfig({
  test: {
    environment: 'node',
    include: ['ui/server/**/*.test.{mjs,cjs,ts}'],
    coverage: {
      provider: 'v8',
      include: ['ui/server/**'],
      // Explicit boundary (round-2 walkthrough 2026-10-16): the root pipeline is
      // server-only; its artifacts must not be confused with the UI suite's
      // ui/coverage/ output. Gate reads coverage.xml (PowerShell) only - JS
      // coverage is a local diagnostic, gitignored via coverage/.
      reportsDirectory: 'coverage/server',
    },
  },
})
