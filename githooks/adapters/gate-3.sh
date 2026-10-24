# shellcheck shell=bash
# ============================================================================
# GATE 3: Cyclomatic Complexity Check
# Uses lizard - checks cyclomatic complexity of changed source files
# ============================================================================

 2>&1 echo ""
 2>&1 echo "→ Gate 3: Cyclomatic complexity..."
GATE_3_START=$(gate_start_ms)
# #537: every non-run records WHY so the report can say why a gate is SKIP.
# Consumed by the sourcing parent (pre-commit report JSON), not here.
# shellcheck disable=SC2034
GATE_3_REASON=""

if [ "$PROJECT_LANG" = "documentation-only" ]; then
  echo "⏭️  SKIPPED - Complexity (documentation project)."
  GATE_3_STATUS="SKIP"
  # Consumed by the sourcing parent (pre-commit report JSON), not here.
  # shellcheck disable=SC2034
  GATE_3_REASON="documentation_project"

elif [ "$PROJECT_LANG" = "powershell" ]; then
  # Downstream hardening 2026-10-24: this arm used to be a hard SKIP with
  # "no PowerShell tool available". That was true of lizard (it cannot parse
  # .ps1) but NOT of the platform: PowerShell's own AST gives an exact decision
  # count, which is the same quantity lizard measures for other languages.
  # A PowerShell-primary repo therefore had a permanently unmeasured quality
  # dimension while the score implied coverage (#537).
  #
  # The measurement lives in the repo (tools/Measure-PowerShellComplexity.ps1)
  # because the hook cannot know a project's refactor history; the adapter only
  # runs it and translates the verdict.
  PS_CC_SCRIPT="tools/Measure-PowerShellComplexity.ps1"
  if [ ! -f "$PS_CC_SCRIPT" ]; then
    echo "ℹ️  No PowerShell complexity tool available"
    echo "     (add tools/Measure-PowerShellComplexity.ps1 to enable AST-based CCN)"
    echo "⏭️  SKIPPED - Complexity (no PowerShell tool)"
    GATE_3_STATUS="SKIP"
    # Consumed by the sourcing parent (pre-commit report JSON), not here.
    # shellcheck disable=SC2034
    GATE_3_REASON="no_powershell_tool"
  else
    # Resolve a PowerShell engine LOCALLY.
    #
    # Downstream hardening 2026-10-24: this arm called `_detect_pwsh`, which is
    # defined in adapters/powershell.sh. But the hook sources that adapter inside
    # a SUBSHELL for Gate 1
    #     PS_G1_OUTPUT=$(source "$POWERSHELL_ADAPTER"; run_static_analysis)
    # so its functions never reach this gate. Measured: Gate 3 printed
    #     ⚠️  WARN - no PowerShell engine found; complexity not measured
    # on a machine with pwsh 7 AND PS 5.1 installed -- i.e. the "no engine"
    # verdict was about bash scoping, not about the engine.
    # A gate must not depend on another gate having sourced a library first.
    _gate3_detect_pwsh() {
      if command -v pwsh >/dev/null 2>&1; then echo pwsh; return 0; fi
      if command -v powershell.exe >/dev/null 2>&1; then echo powershell.exe; return 0; fi
      local _c
      for _c in \
        "${LOCALAPPDATA:-$HOME/AppData/Local}/Microsoft/WindowsApps/pwsh.exe" \
        "/c/Program Files/PowerShell/7/pwsh.exe" \
        "/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"; do
        [ -x "$_c" ] && { echo "$_c"; return 0; }
      done
      return 1
    }
    PS_CC_PWSH=$(_gate3_detect_pwsh 2>/dev/null || true)
    if [ -z "$PS_CC_PWSH" ]; then
      echo "⚠️  WARN - no PowerShell engine found; complexity not measured"
      GATE_3_STATUS="WARN"
      # Consumed by the sourcing parent (pre-commit report JSON), not here.
      # shellcheck disable=SC2034
      GATE_3_REASON="no_powershell_engine"
    else
      # Freshly added files only: this arm has no baseline concept, so it judges
      # each file's functions against the threshold. A file that is merely being
      # touched keeps its history (that is what .ccn-baseline.json is for on the
      # lizard path); here we deliberately measure only ADDED files so the arm
      # can never retroactively block a cleanup commit.
      PS_ADDED=$(git diff --cached --name-only --diff-filter=A 2>/dev/null | grep -E '\.ps(m)?1$' || true)
      if [ -z "$PS_ADDED" ]; then
        # No added files, but modified ones can still get MORE complex. That is
        # the actual regression this dimension exists to catch: refactoring a
        # 140-CCN function into two 80-CCN functions is a 20-point improvement,
        # and adding one `elseif` to it is a regression -- a flat threshold
        # cannot tell those apart, a baseline can.
        PS_RATCHET_BASELINE=".xp-gate-powershell-ccn-baseline.json"
        # Scope the ratchet to PRODUCT code.
        #
        # Downstream hardening 2026-10-24: `--diff-filter=ACM` swept in every
        # touched .ps1, including tests/. The ratchet treats "function not in the
        # baseline" as a REGRESSION, so the first time a test file was touched it
        # blocked on functions the baseline never covered:
        #
        #     ❌ tests/unit/complexity-tool.Tests.ps1:23 new function at ccn=3
        #     ❌ tests/unit/scripts.Tests.ps1:1295 New-WrcFixture new function at ccn=2
        #
        # That is not a complexity regression -- a 2-CCN test helper is not a
        # maintainability problem -- it is a scope error. Measuring test code also
        # creates a perverse incentive: it pushes authors to flatten test helpers
        # to dodge the gate.
        # The baseline's generator (tools/Update-ComplexityBaseline.ps1) only ever
        # covered product scripts, so the two halves disagreed about scope. Honour
        # the same scope here, and take it from the baseline's own `scope` field
        # when present so the two can never drift apart silently again.
        PS_TOUCHED=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null | grep -E '\.ps(m)?1$' || true)
        if [ -n "$PS_TOUCHED" ]; then
          PS_TOUCHED=$(printf '%s\n' "$PS_TOUCHED" | grep -vE '(^|/)tests/' || true)
        fi
        if [ ! -f "$PS_RATCHET_BASELINE" ] || [ -z "$PS_TOUCHED" ]; then
          echo "⏭️  SKIPPED - Complexity (no added PowerShell files to measure)."
          GATE_3_STATUS="SKIP"
          # Consumed by the sourcing parent (pre-commit report JSON), not here.
          # shellcheck disable=SC2034
          GATE_3_REASON="no_added_powershell_files"
        else
          PS_CC_ARGS=()
          for _f in $PS_TOUCHED; do PS_CC_ARGS[${#PS_CC_ARGS[@]}]="'$_f'"; done
          PS_CC_OUT=$("$PS_CC_PWSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass \
            -Command "& './$PS_CC_SCRIPT' -Path @($(IFS=','; echo "${PS_CC_ARGS[*]}")) -Threshold 1" 2>&1 || true)
          PS_CC_MEASURED=$(printf '%s\n' "$PS_CC_OUT" | sed -n 's/^functions_measured=//p' | tail -1)
          if [ -z "$PS_CC_MEASURED" ] || [ "${PS_CC_MEASURED:-0}" -eq 0 ]; then
            echo "⏭️  SKIPPED - Complexity (no functions in changed PowerShell files)."
            GATE_3_STATUS="SKIP"
            # Consumed by the sourcing parent (pre-commit report JSON), not here.
            # shellcheck disable=SC2034
            GATE_3_REASON="no_functions_found"
          else
            # Compare against the baseline with node when available (jq may be
            # absent on Windows) -- a bash+jq-only ratchet would itself become a
            # silent SKIP on the very platform this repo targets.
            PS_CC_NODE=""
            if command -v node >/dev/null 2>&1; then PS_CC_NODE="node"; fi
            if [ -z "$PS_CC_NODE" ]; then
              echo "ℹ️  node unavailable — complexity measured (${PS_CC_MEASURED} function(s)) but ratchet not compared"
              echo "✅ PASSED - PowerShell complexity measured (ratchet unavailable)."
              GATE_3_STATUS="PASS"
              GATE_3_DETAIL="mode=measured_no_ratchet"
            else
              PS_CC_VERDICT=$(printf '%s\n' "$PS_CC_OUT" | "$PS_CC_NODE" -e '
                let raw = "";
                process.stdin.on("data", d => raw += d).on("end", () => {
                  const fs = require("fs");
                  const basePath = process.argv[1];
                  let base = { entries: [] };
                  try {
                    // Strip a UTF-8 BOM before parsing: JSON.parse throws on it,
                    // and a baseline committed from PowerShell 5.1 used to carry
                    // one. A BOM must never turn a configured gate into "unreadable".
                    base = JSON.parse(fs.readFileSync(basePath, "utf8").replace(/^\uFEFF/, ""));
                  }
                  catch (e) { console.log("ERR unreadable baseline: " + e.message); return; }
                  const known = new Map();
                  for (const e of (base.entries || [])) known.set(e.file + "::" + e.function, Number(e.ccn));
                  const norm = p => String(p).replace(/\\/g, "/").replace(/^\.\//, "");
                  const regressions = [];
                  const improvements = [];
                  let measured = 0;
                  for (const line of raw.split(/\r?\n/)) {
                    const m = line.match(/^OVER (.+):(\d+) (\S+) ccn=(\d+)$/);
                    if (!m) continue;
                    measured++;
                    const key = norm(m[1]) + "::" + m[3];
                    const now = Number(m[4]);
                    if (!known.has(key)) { regressions.push(`${norm(m[1])}:${m[2]} ${m[3]} new function at ccn=${now}`); continue; }
                    const was = known.get(key);
                    if (now > was) regressions.push(`${norm(m[1])}:${m[2]} ${m[3]} ccn ${was} -> ${now}`);
                    else if (now < was) improvements.push(`${norm(m[1])}:${m[2]} ${m[3]} ccn ${was} -> ${now}`);
                  }
                  for (const i of improvements) console.log("IMPROVED " + i);
                  if (regressions.length === 0) { console.log("OK " + measured); return; }
                  for (const r of regressions) console.log("REGRESSION " + r);
                  console.log("FAIL " + regressions.length);
                });
              ' "$PS_RATCHET_BASELINE" 2>&1 || true)
              if printf '%s\n' "$PS_CC_VERDICT" | grep -q '^FAIL '; then
                PS_CC_REG=$(printf '%s\n' "$PS_CC_VERDICT" | sed -n 's/^FAIL //p' | tail -1)
                printf '%s\n' "$PS_CC_VERDICT" | grep '^REGRESSION ' | sed 's/^REGRESSION /     ❌ /'
                echo ""
                echo "❌ BLOCKED - ${PS_CC_REG} function(s) increased cyclomatic complexity vs ${PS_RATCHET_BASELINE}."
                echo "   The ratchet only allows complexity to go DOWN. Refactor, or if the"
                echo "   increase is deliberate, regenerate with tools/Update-ComplexityBaseline.ps1"
                echo "   and explain the trade-off in the commit message."
                GATE_3_STATUS="BLOCK"
                # Consumed by the sourcing parent (pre-commit report JSON), not here.
                # shellcheck disable=SC2034
                GATE_3_REASON="ccn_ratchet_regression"
                exit 1
              elif printf '%s\n' "$PS_CC_VERDICT" | grep -q '^ERR '; then
                echo "⚠️  WARN - complexity ratchet baseline unreadable: $(printf '%s\n' "$PS_CC_VERDICT" | sed -n 's/^ERR //p' | head -1)"
                GATE_3_STATUS="WARN"
                # Consumed by the sourcing parent (pre-commit report JSON), not here.
                # shellcheck disable=SC2034
                GATE_3_REASON="ratchet_baseline_unreadable"
              else
                PS_CC_IMPROVED=$(printf '%s\n' "$PS_CC_VERDICT" | grep -c '^IMPROVED ' || true)
                if [ "${PS_CC_IMPROVED:-0}" -gt 0 ]; then
                  printf '%s\n' "$PS_CC_VERDICT" | grep '^IMPROVED ' | sed 's/^IMPROVED /     📉 /'
                  echo "   (improvements recorded; regenerate the baseline in a later commit)"
                fi
                echo "✅ PASSED - PowerShell complexity within ratchet (${PS_CC_MEASURED} function(s) checked)."
                GATE_3_STATUS="PASS"
                GATE_3_DETAIL="mode=ratchet"
              fi
            fi
          fi
        fi
      else
        PS_CC_ARGS=()
        for _f in $PS_ADDED; do PS_CC_ARGS[${#PS_CC_ARGS[@]}]="'$_f'"; done
        PS_CC_OUT=$("$PS_CC_PWSH" -NoProfile -NonInteractive -ExecutionPolicy Bypass \
          -Command "& './$PS_CC_SCRIPT' -Path @($(IFS=','; echo "${PS_CC_ARGS[*]}")) -Threshold ${CCN_THRESHOLD:-5}" 2>&1 || true)
        PS_CC_MEASURED=$(printf '%s\n' "$PS_CC_OUT" | sed -n 's/^functions_measured=//p' | tail -1)
        PS_CC_OVER=$(printf '%s\n' "$PS_CC_OUT" | sed -n 's/^over_threshold=//p' | tail -1)
        PS_CC_MAX=$(printf '%s\n' "$PS_CC_OUT" | sed -n 's/^max_ccn=//p' | tail -1)
        if [ -z "$PS_CC_MEASURED" ]; then
          echo "⚠️  WARN - PowerShell complexity measurement produced no parsable result"
          printf '%s\n' "$PS_CC_OUT" | head -10 | sed 's/^/     /'
          GATE_3_STATUS="WARN"
          # Consumed by the sourcing parent (pre-commit report JSON), not here.
          # shellcheck disable=SC2034
          GATE_3_REASON="measurement_unparsable"
        elif [ "${PS_CC_MEASURED:-0}" -eq 0 ]; then
          echo "⏭️  SKIPPED - Complexity (added files contain no functions)."
          GATE_3_STATUS="SKIP"
          # Consumed by the sourcing parent (pre-commit report JSON), not here.
          # shellcheck disable=SC2034
          GATE_3_REASON="no_functions_found"
        else
          echo "   Measured ${PS_CC_MEASURED} function(s) via AST; max CCN ${PS_CC_MAX} (threshold ${CCN_THRESHOLD:-5})"
          if [ "${PS_CC_OVER:-0}" -gt 0 ]; then
            printf '%s\n' "$PS_CC_OUT" | grep '^OVER ' | sed 's/^/     /'
            echo ""
            echo "❌ BLOCKED - ${PS_CC_OVER} newly added function(s) with CCN > ${CCN_THRESHOLD:-5}."
            echo "Refactor high-complexity functions, or raise the threshold deliberately."
            GATE_3_STATUS="BLOCK"
            # Consumed by the sourcing parent (pre-commit report JSON), not here.
            # shellcheck disable=SC2034
            GATE_3_REASON="ccn_over_threshold"
            exit 1
          else
            echo "✅ PASSED - All added PowerShell functions within complexity threshold (${CCN_THRESHOLD:-5})."
            GATE_3_STATUS="PASS"
          fi
        fi
      fi
    fi
  fi

else
  # S2 (#507): three-level CCN threshold override --
  # .xp-gate/ccn-threshold (positive integer) > XP_GATE_CCN_THRESHOLD > 5.
  # Invalid values WARN on stderr and fall back to the default; the resolved
  # value reaches the gate-3 audit record via the --detail argument below.
  # Implemented with bash builtins only (no tr/grep spawns): every process
  # spawn is expensive on Windows under AV filter drivers.
  resolve_ccn_threshold() {
    local default=5 val
    if [ -f ".xp-gate/ccn-threshold" ]; then
      val=$(<".xp-gate/ccn-threshold")
      val="${val//[[:space:]]/}"
      case "$val" in
        ''|*[!0-9]*|0)
          echo "WARN - invalid .xp-gate/ccn-threshold value '${val}' (expected a positive integer), falling back to ${default}" >&2
          ;;
        *)
          echo "$val"
          return 0
          ;;
      esac
      echo "$default"
      return 0
    fi
    val=${XP_GATE_CCN_THRESHOLD:-}
    if [ -n "$val" ]; then
      case "$val" in
        ''|*[!0-9]*|0)
          echo "WARN - invalid XP_GATE_CCN_THRESHOLD value '${val}' (expected a positive integer), falling back to ${default}" >&2
          ;;
        *)
          echo "$val"
          return 0
          ;;
      esac
    fi
    echo "$default"
  }

  CCN_THRESHOLD=$(resolve_ccn_threshold)
  
  # Check lizard availability
  LIZARD_CMD=""
  if command -v lizard > /dev/null 2>&1; then
    LIZARD_CMD=lizard
  elif [ -f ~/.local/bin/lizard ]; then
    LIZARD_CMD=~/.local/bin/lizard
  fi
  
  if [ -n "$LIZARD_CMD" ]; then
    LIZARD_PATH=$(eval echo "$LIZARD_CMD")
    
    # Get changed source files for complexity check (includes test files)
    CC_FILES=$(echo "$CHANGED_FILES" | grep -E '\.(ts|tsx|js|jsx|py|go|java|swift|cpp|c|hpp|h|m|mm|kt)$' || true)

    # Grade exactly the population the baseline was written from. The two must
    # match or the ratchet reports pre-existing code as "new", which is a false
    # BLOCK no repair can clear (the exact failure #495 Round 3 called out, in a
    # different place). scripts/ccn-report.cjs --write-baseline records only
    # bucket === 'production' rows; its bucketFor() classifies two other buckets:
    #   mirror     src/npm-package/**, plugins/*/src/** — regenerated by prepack
    #              from a canonical source that IS graded here. Editing a mirror
    #              is reverted at the next publish, so grading it cannot be acted
    #              on (doctorDelphi CCN=106 blocked every src/npm-package commit,
    #              on HEAD too — no baseline entry could ever exist for it).
    #   test       __tests__/, *.test.*, *_test.{py,go}, *Test(s).java — recorded
    #              in the report's test bucket, never in the baseline.
    # Both prefixes and the test pattern mirror ccn-report.cjs so the gate and
    # the writer cannot drift apart again (pinned by __tests__/gate-3-*.bats).
    CC_FILES=$(echo "$CC_FILES" | grep -vE \
      '^"?src/npm-package/|^"?plugins/[^/]+/src/|(^|/)__tests__?/|\.test\.[cm]?[jt]sx?$|_test\.(py|go)$|Test(s)?\.java$' || true)

    if [ -n "$CC_FILES" ]; then
      echo "Checking complexity for source files..."
      
      # Run lizard with CCN threshold
      # One path per line, into an array. Unquoted $CC_FILES relied on word
      # splitting, which also splits any path containing a space -- handing
      # lizard two bogus paths and checking neither (#457 defect class, same
      # fix as gate-4's PRINCIPLES_ARGS). Quoting the scalar would instead
      # collapse the list into one argument. An array does both.
      CC_FILES_ARGS=()
      while IFS= read -r _cc_file; do
        [ -n "$_cc_file" ] && CC_FILES_ARGS+=("$_cc_file")
      done <<< "$CC_FILES"
      CC_OUTPUT=$("$LIZARD_PATH" -C "$CCN_THRESHOLD" ${CC_FILES_ARGS[@]+"${CC_FILES_ARGS[@]}"} 2>&1 || true)

      # REQ-D (sprint-20261018-quality): baseline ratchet. When
      # .ccn-baseline.json exists it replaces the flat threshold verdict:
      # recorded functions may not get WORSE (strictly greater blocks), new
      # functions face the live thresholds, improvements only hint. The
      # legacy path below stays byte-for-byte for repos without a baseline.
      if [ -f ".ccn-baseline.json" ]; then
        # #544: lizard's raw CCN is not what the baseline was recorded with.
        # The baseline comes from scripts/ccn-report.cjs, which re-derives every
        # above-threshold CCN from brace-balanced source (lizard's TS parser
        # loses braces on generic-arrow fields and charges neighbours). Feeding
        # the ratchet raw numbers compared two different engines — a function
        # at its recorded ceiling read as "worse" purely from span inflation.
        # Route the CSV through the same verifier; on rows it cannot verify the
        # helper exits non-zero, and this gate fails closed instead of passing
        # an unvalidated number.
        CC_CSV=$("$LIZARD_PATH" --csv ${CC_FILES_ARGS[@]+"${CC_FILES_ARGS[@]}"} 2>/dev/null || true)
        CC_REPORT="$(git rev-parse --show-toplevel 2>/dev/null)/scripts/ccn-report.cjs"
        # Fail closed when the verifier is unavailable. Previously this fell
        # through and graded the RAW lizard CSV, while CI hard-fails on the same
        # condition — so the hook and CI could reach opposite verdicts on
        # identical code, and the hook silently compared baseline numbers
        # (recorded by ccn-report's brace-verified engine) against an engine it
        # no longer had. Agreeing with CI is the point of having both.
        if [ ! -f "$CC_REPORT" ] || ! command -v node >/dev/null 2>&1; then
          echo "❌ BLOCKED - complexity verifier unavailable (scripts/ccn-report.cjs needs node)."
          echo "CI fails on this same condition; refusing to grade unverified CCN locally."
          GATE_3_DETAIL="mode=ratchet verifier=MISSING"
          exit 1
        fi
        if [ -f "$CC_REPORT" ] && command -v node >/dev/null 2>&1; then
          _cc_verify_failed=0
          CC_CSV_VERIFIED=$(printf '%s\n' "$CC_CSV" | node "$CC_REPORT" --csv-verified batch --root "$(git rev-parse --show-toplevel 2>/dev/null)") || _cc_verify_failed=1
          if [ "$_cc_verify_failed" -ne 0 ]; then
            echo "❌ BLOCKED - complexity could not be span-verified; refusing to grade unverified CCN."
            GATE_3_DETAIL="mode=ratchet verify=FAILED"
            exit 1
          fi
          CC_CSV="$CC_CSV_VERIFIED"
        fi
        RATCHET_LIB="$GATE_DIR/lib/ccn-ratchet.sh"
        [ -f "$RATCHET_LIB" ] || RATCHET_LIB="$(git rev-parse --show-toplevel 2>/dev/null)/githooks/lib/ccn-ratchet.sh"
        # shellcheck source=/dev/null
        . "$RATCHET_LIB"
        # NOTE: the thresholds must be plain assignments BEFORE the pipe. As a
        # prefix to a variable assignment (`T=1 V=$(... | fn)`) they land in the
        # assignment's subshell, so the function sees no thresholds AND reads an
        # empty stdin — the verdict comes back empty and Gate 3 passes on zero
        # rows (measured while wiring #544: same input passed or blocked
        # depending only on where the prefix sat).
        # Consumed by evaluate_ccn_ratchet in the sourced lib, not here.
        # shellcheck disable=SC2034
        CCN_WARN_THRESHOLD="$CCN_THRESHOLD"
        # shellcheck disable=SC2034
        CCN_BLOCK_THRESHOLD=$((CCN_THRESHOLD * 2))
        RATCHET_VERDICT=$(printf '%s\n' "$CC_CSV" | evaluate_ccn_ratchet ".ccn-baseline.json")
        CC_VIOLATIONS=$(printf '%s\n' "$RATCHET_VERDICT" | grep -c '^BLOCK ' || true)
        CC_LOWER=$(printf '%s\n' "$RATCHET_VERDICT" | grep -c '^LOWER ' || true)
        printf '%s\n' "$RATCHET_VERDICT" | grep -v '^OK ' || true
        if [ "${CC_LOWER:-0}" -gt 0 ]; then
          echo "ℹ️  $CC_LOWER function(s) improved below baseline — refresh with: node scripts/ccn-report.cjs --write-baseline"
        fi
        GATE_3_DETAIL="mode=ratchet"
        if [ "${CC_VIOLATIONS:-0}" -gt 0 ]; then
          echo ""
          echo "❌ BLOCKED - $CC_VIOLATIONS function(s) violate the complexity ratchet (.ccn-baseline.json)."
          echo "Revert the increase, or refactor; refresh the baseline only via ccn-baseline-refresh commits."
          exit 1
        else
          echo "✅ PASSED - Complexity within ratchet baseline."
          GATE_3_STATUS="PASS"
        fi
      else
      # #543: count from lizard's machine-readable CSV, never its tables.
      #
      # The previous parser grepped '^Warning cnt' for a summary row. Two things
      # made that never match: "Warning cnt" is a column header in the MIDDLE of
      # a line ("Total nloc  Avg.NLOC  ...  Warning cnt  Fun Rt  nloc Rt"), and
      # lizard omits the summary block entirely when given explicit file
      # arguments -- which is how this gate always invokes it. CC_WARNINGS was
      # therefore always 0 and the flat-threshold path could not block anything.
      #
      # --csv has a stable column order (NLOC,CCN,token,PARAM,length,location,
      # file,name,signature,...), so the verdict comes from the same numbers
      # lizard uses, independent of version and table formatting. --csv here is
      # the flat-threshold run; the ratchet branch above builds its own.
      CC_CSV_FLAT=$("$LIZARD_PATH" --csv -C "$CCN_THRESHOLD" ${CC_FILES_ARGS[@]+"${CC_FILES_ARGS[@]}"} 2>/dev/null || true)
      CC_WARNINGS=$(printf '%s\n' "$CC_CSV_FLAT" | awk -F, -v t="$CCN_THRESHOLD" '
        NF > 1 && $2 + 0 > t + 0 { c++ }
        END { print c + 0 }
      ')
      # A lizard that produced no parsable row must not read as "clean". Without
      # this, a crashing or mis-invoked lizard yields 0 warnings and the gate
      # reports PASSED on zero analysed functions -- the same silent-success
      # failure this issue is about.
      if ! printf '%s\n' "$CC_CSV_FLAT" | awk -F, 'NF > 1 && $2 ~ /^[0-9]+$/ { found = 1; exit }
                                                 END { exit(found ? 0 : 1) }'; then
        echo "⚠️  WARN - lizard produced no parsable results; complexity not verified"
        GATE_3_STATUS="WARN"
        # Consumed by the sourcing parent (pre-commit report JSON), not here.
        # shellcheck disable=SC2034
        GATE_3_REASON="lizard_output_unparsable"
      elif [ "$CC_WARNINGS" -gt 0 ]; then
        echo "$CC_OUTPUT"
        echo ""
        echo "❌ BLOCKED - $CC_WARNINGS functions with CCN > $CCN_THRESHOLD found."
        echo "Refactor high-complexity functions to keep below $CCN_THRESHOLD complexity."
        GATE_3_STATUS="BLOCK"
        # Consumed by the sourcing parent (pre-commit report JSON), not here.
        # shellcheck disable=SC2034
        GATE_3_REASON="ccn_over_threshold"
        exit 1
      else
        echo "✅ PASSED - All functions within complexity threshold ($CCN_THRESHOLD)."
        GATE_3_STATUS="PASS"
      fi
      fi
    else
      echo "⏭️  SKIPPED - Complexity (no source files to check)."
      GATE_3_STATUS="SKIP"
      # Consumed by the sourcing parent (pre-commit report JSON), not here.
      # shellcheck disable=SC2034
      GATE_3_REASON="no_source_files_changed"
    fi
  else
    echo "⚠️  WARN - lizard not installed, complexity check not performed"
    echo "   Install with: pip install --user lizard"
    echo "   Gate 3: Complexity check (WARN, tool not available)"
    GATE_3_STATUS="WARN"
    # Consumed by the sourcing parent (pre-commit report JSON), not here.
    # shellcheck disable=SC2034
    GATE_3_REASON="tool_not_installed"
  fi
fi
# The audit's issues_found comes from whichever mode actually ran. In ratchet
# mode the count lives in CC_VIOLATIONS (functions worse than their recorded
# baseline); the flat-threshold mode parses CC_WARNINGS from lizard's own table.
# Reading only CC_WARNINGS meant every ratchet block recorded issues_found=0 —
# the gate failed while the journal claimed nothing was found.
CC_ISSUES="${CC_VIOLATIONS:-${CC_WARNINGS:-0}}"
record_gate_audit "gate-3" "complexity" "$GATE_3_STATUS" "$CC_ISSUES" "$GATE_3_START" "ccn_threshold=${CCN_THRESHOLD:-5}${GATE_3_DETAIL:+ $GATE_3_DETAIL}"
