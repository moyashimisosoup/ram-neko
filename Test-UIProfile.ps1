param([ValidateRange(10,300)][int]$Seconds=60)
$ErrorActionPreference='Stop'
$output=& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -STA -File "$PSScriptRoot\MiniUI.ps1" -ProfileSeconds $Seconds
if($LASTEXITCODE -ne 0){throw 'Observation-only UI profile failed'}
$result=($output|Out-String)|ConvertFrom-Json
$result|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $PSScriptRoot 'ui-profile-result.json') -Encoding UTF8
if($result.PSObject.Properties['Error']){throw $result.Error}
if(-not $result.ObservationOnly -or $result.CleanupAttempts -ne 0 -or $result.Mode -ne 'hidden_observation_only'){throw 'Profile safety invariant failed'}
if($result.ElapsedSeconds -lt ($Seconds-1) -or $result.CpuSeconds -lt 0 -or $result.EndWorkingSetBytes -le 0 -or $result.MonitorSamples -lt 1 -or $result.DiagnosticWrites -lt 1){throw 'Profile measurements incomplete'}
Write-Output 'PASS: isolated hidden WinForms profile ran with native observation and zero cleanup attempts'
$result|ConvertTo-Json -Depth 6 -Compress
