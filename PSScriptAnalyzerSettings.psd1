# PSScriptAnalyzerSettings.psd1
# Usage: Invoke-ScriptAnalyzer -Path references/scripts -Recurse -Settings PSScriptAnalyzerSettings.psd1
@{
    # ParseError MUST be listed explicitly (R6 Round-3 expert probe 2026-10-17):
    # with Severity limited to Error/Warning, PSSA silently DROPS ParseError-class
    # findings (e.g. MissingEndCurlyBrace) - a syntactically broken script would
    # pass Gate 1 with zero findings. Verified: bare run of a broken script yields
    # 2 x ParseError; with Error/Warning-only settings it yields count=0; with
    # 'ParseError' added it yields count=2. (IncludeRules=@('ParseError') does NOT
    # work - count stays 0.)
    Severity     = @('Error', 'Warning', 'ParseError')
    ExcludeRules = @(
        # Every script declares its entry parameters in a top-level param() block and
        # consumes them inside `function Main` (see AGENTS.md "function/execution
        # separation"). PSReviewUnusedParameter does not follow script-scope variables
        # into a nested function body, so it reports all 23 real parameters as unused.
        # Verified individually: the only genuinely dead parameter was run-all.ps1
        # -Verbose, which has been removed rather than suppressed.
        'PSReviewUnusedParameter'
    )
}
