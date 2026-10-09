# Isolated lab: does `cmd /c "rd /s /q ..." 2>&1` leak into the output stream
# so that `$deleted = Remove-ItemRobust ...` captures non-empty output?
$ErrorActionPreference = 'Continue'
$d = Join-Path $PSScriptRoot 'drill5-work\RDLab'
if (Test-Path $d) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $d -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $d 'x.dat'), 'x')

if (-not ('WrcRdLabLock' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class WrcRdLabLock {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr CreateFileW(string lpFileName, uint dwDesiredAccess, uint dwShareMode,
        IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);
}
"@
}
$h = [WrcRdLabLock]::CreateFileW($d, [uint32]2147483648, [uint32]0, [IntPtr]::Zero, [uint32]3, [uint32]0x02000000, [IntPtr]::Zero)
"handle valid: $(($h -ne [IntPtr]::Zero) -and ($h -ne [IntPtr](-1)))"

# --- replicate the product's tier 3 exactly --------------------------------
$x = cmd /c "rd /s /q `"$d`"" 2>&1
"rd LASTEXITCODE = $LASTEXITCODE"
"rd output count = $(@($x).Count)"
foreach ($o in @($x)) { "  OUT: [$($o.GetType().Name)] $o" }
"dir still exists: $(Test-Path $d)"

$null = [WrcRdLabLock]::CloseHandle($h)
Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
"cleaned: $(-not (Test-Path $d))"
