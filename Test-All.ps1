param([switch]$SkipInstalled)
$ErrorActionPreference = 'Stop'
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -File "$PSScriptRoot\Test-MemoryWatch.ps1"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -File "$PSScriptRoot\Test-TrimSafety.ps1"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -File "$PSScriptRoot\Test-Diagnostics.ps1"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -File "$PSScriptRoot\Test-GadgetSupport.ps1"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -STA -File "$PSScriptRoot\MiniUI.ps1" -SmokeTest
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
if($SkipInstalled){Write-Output 'ALL PORTABLE MONITOR AND UI CHECKS PASSED';exit 0}
$task = Get-ScheduledTask -TaskName 'MemoryWatch-PressureOnly'
if ($task.Triggers.Count -ne 1 -or $task.Triggers[0].CimClass.CimClassName -ne 'MSFT_TaskLogonTrigger') { throw 'Expected one logon trigger' }
if ($task.Triggers[0].Repetition.Interval) { throw 'Unexpected repeated task launches' }
if ($task.Actions[0].Execute -notlike '*\wscript.exe' -or $task.Actions[0].Arguments -notlike '*LaunchHidden.vbs*') { throw 'Expected hidden VBScript launcher' }
Write-Output 'PASS: installed task has logon-only trigger, no repetition, wscript launcher'
$heartbeat = Get-Content -LiteralPath "$PSScriptRoot\data\ui-status.json" -Raw | ConvertFrom-Json
$process = Get-CimInstance Win32_Process -Filter "ProcessId=$($heartbeat.Pid)" -ErrorAction Stop
if ($process.Name -ne 'powershell.exe' -or -not $process.CommandLine.Contains((Join-Path $PSScriptRoot 'MiniUI.ps1'))) { throw 'Expected live RAM monitor process' }
if (([datetime]::UtcNow - ([datetime]$heartbeat.Utc).ToUniversalTime()).TotalSeconds -gt 120) { throw 'UI heartbeat stale' }
if ($heartbeat.IntervalSeconds -ne 60) { throw 'Unexpected UI timer interval' }
if ($heartbeat.DisplayIntervalSeconds -ne 5 -or $null -eq $heartbeat.Chart) { throw 'Expected graph heartbeat and five-second display interval' }
if ($heartbeat.Theme -ne '8bit-neko' -or $heartbeat.TrayIcon -ne 'pixel-cat' -or -not $heartbeat.TrayVisible) { throw 'Expected live cat notification icon' }
if($heartbeat.WindowMode -notin @('Normal','Desktop','Topmost') -or $heartbeat.Palette -notin @('Lavender','Mint','Peach','Sky','Midnight')){throw 'Expected live gadget mode and palette'}
Write-Output 'PASS: live RAM panel process and fresh 60-second heartbeat'
Write-Output 'ALL MONITOR AND UI CHECKS PASSED'
