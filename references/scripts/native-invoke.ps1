# native-invoke.ps1 — 原生 exe 调用的唯一通道（引号封装 + 真实超时）
# =============================================================================
# 教训（2026-10-16 接管审计 P1-1）：
#   Start-Process -ArgumentList <数组> 把元素按空格拼接且**不加引号**——
#   含空格的注册表键名（如 ...\Uninstall\Google Chrome）、文件路径、服务名
#   会在拼接处碎裂。项目曾在 drill4/drill5 现场用 ('"{0}"' -f $path) 修过同类
#   问题（CHANGELOG 2026-10-09），但产品链一直未回流；本文件把该修法收敛为
#   产品级封装，并把 Invoke-ScExe / Invoke-RegExe / Remove-ItemRobust Tier2
#   全部收拢到这一条通道上。
#
# 契约：
#   1. 产品脚本内禁止直接 Start-Process 传数组字面量形式的 -ArgumentList
#      （AST 守卫：tests/unit/platform-hygiene.Tests.ps1），一律走 Invoke-NativeExe。
#   2. 本文件不得有顶层 param()（AGENTS.md 陷阱 8a：dot-source 不得把默认值
#      冲进调用方作用域）。
#   3. 返回哈希表、不抛异常——调用方以 exit_code 是否为 $null 区分
#      「正常退出」与「超时被杀 / 进程失败」（与 Invoke-ScExe 既有语义一致）。
# =============================================================================

function ConvertTo-NativeArgument {
    <#
    .SYNOPSIS
        把单个参数转成 Windows 命令行安全形态：含空白/引号的值包双引号。
    .DESCRIPTION
        引号规则（MSVCRT 惯例）：值内嵌的 " 转义为 \"，且其前面的反斜杠要成对
        翻倍；结尾的反斜杠也要翻倍，避免吞掉包裹引号。
        不含空白与引号的值原样返回（不画蛇添足）。
    #>
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrEmpty($Value)) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Invoke-NativeExe {
    <#
    .SYNOPSIS
        可靠地调用原生 exe：元素显式加引号 + 双流重定向 + 真实超时。
    .DESCRIPTION
        返回 @{ ok; exit_code; stdout; stderr; error }；不抛。
        - exit_code $null = 进程被超时击杀或未能返回退出码（调用方必须视为失败，
          不得当成幂等成功码——见 clean-residuals.ps1 Invoke-ScExe 的 1060 语义）。
        - 超时用 WaitForExit(ms) 实现：Start-Process -Wait 无法超时，会永久挂起，
          TimeoutSeconds 参数在旧实现里只是写在报错文案里的装饰（2026-10-16 发现）。
        - 重定向目标是文件而非管道：不存在管道缓冲填满导致的子进程死锁。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments,
        [int]$TimeoutSeconds = 30
    )

    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        # 关键行：Start-Process 不会替我们加引号（P1-1 根因），必须先转换。
        $quotedArgs = @($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ })
        $proc = Start-Process -FilePath $FilePath `
            -ArgumentList $quotedArgs -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
            -ErrorAction Stop

        # PS 5.1 陷阱：-PassThru（无 -Wait）返回的 Process 对象必须先触碰 .Handle
        # 强制取得句柄，否则进程退出后 ExitCode 恒为 $null（pwsh 7 无此问题；
        # 双引擎行为差异 2026-10-16 实测：5.1 下全部读到 null）。
        $null = $proc.Handle

        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            # 击杀失败的唯一常见原因是进程已自行退出——此时超时结论仍然成立，
            # 用 Write-Verbose 留痕即可（Verbose 流不污染成功流契约）。
            try { $proc.Kill() } catch { Write-Verbose "Kill after timeout failed (process may have exited): $($_.Exception.Message)" }
            $proc.WaitForExit()
            return @{
                ok = $false; exit_code = $null; stdout = ''; stderr = ''
                error = "native process timed out after ${TimeoutSeconds}s and was killed: $FilePath"
            }
        }

        # 文件总是存在（GetTempFileName 已创建），读取仅用于获取进程输出。
        $stdout = [string](Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue)
        $stderr = [string](Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)
        $exitCode = $proc.ExitCode
        if ($null -eq $exitCode) {
            return @{ ok = $false; exit_code = $null; stdout = $stdout; stderr = $stderr; error = "native process returned no exit code: $FilePath" }
        }
        return @{
            ok        = ($exitCode -eq 0)
            exit_code = $exitCode
            stdout    = $stdout
            stderr    = $stderr
            error     = if ($exitCode -eq 0) { '' } else { (($stdout + "`n" + $stderr).Trim()) }
        }
    } catch {
        # Start-Process 自身失败（权限不足 / exe 缺失 / 被安全软件拦截）：
        # exit_code 保持 $null 以区别于「进程正常运行并返回了退出码」。
        return @{ ok = $false; exit_code = $null; stdout = ''; stderr = ''; error = $_.Exception.Message }
    } finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}
