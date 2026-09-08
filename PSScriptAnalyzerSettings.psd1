# PSScriptAnalyzerSettings.psd1
# Usage: Invoke-ScriptAnalyzer -Path references/scripts -Recurse -Settings PSScriptAnalyzerSettings.psd1
@{
    Severity     = @('Error', 'Warning')
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
