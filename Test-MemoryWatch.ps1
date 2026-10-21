$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\MemoryWatch.ps1" -LibraryOnly
function Assert($Condition, $Message) { if (-not $Condition) { throw "FAIL: $Message" }; Write-Output "PASS: $Message" }
$now = [datetime]::UtcNow
Assert (-not (Get-MemoryDecision 1000 16000 0 $null $now).Trim) 'first low sample does not trim'
Assert (-not (Get-MemoryDecision 1000 16000 1 $null $now).Trim) 'second low sample does not trim'
Assert (Get-MemoryDecision 1000 16000 2 $null $now).Trim 'third low sample triggers'
Assert (-not (Get-MemoryDecision 1000 16000 9 $now.AddMinutes(-14).ToString('o') $now).Trim) 'cooldown prevents repeated trim'
Assert (Get-MemoryDecision 1000 16000 9 $now.AddMinutes(-16).ToString('o') $now).Trim 'cooldown expires'
Assert ((Get-MemoryDecision 3000 16000 9 $null $now).LowSamples -eq 0) 'recovery resets consecutive count'
Assert (-not (Get-MemoryDecision 1000 8000 9 $null $now).Trim) 'both pressure thresholds required'
Assert (-not (Get-MemoryDecision 1536 32000 9 $null $now).Trim) 'absolute boundary does not trim'
Initialize-MemoryNative
$m = Get-MemorySnapshot
Assert ($m.TotalMB -gt 0 -and $m.AvailableMB -ge 0) 'native memory measurement works'
Assert (@(Get-TrimCandidates chrome 0 | Where-Object ProcessName -eq chrome).Count -eq 0) 'foreground browser family excluded'
# Exercise the real API only against this isolated test process.
$self = Get-Process -Id $PID
[RamNeko.Safety.TrimGuard]::Execute((New-Object RamNeko.Safety.CandidateIdentity($self.Id, $self.StartTime.ToUniversalTime().Ticks, $self.ProcessName, $self.SessionId)), (New-Object RamNeko.Safety.WindowsTrimNative))
Assert $true 'real EmptyWorkingSet succeeds on disposable test process'
$initial = Get-IdleObservation $null 10 $now
Assert ($initial.IdleSeconds -eq 0) 'new processes require an observation window'
$idle = Get-IdleObservation $initial 10.2 $now.AddSeconds(60)
Assert ($idle.IdleSeconds -eq 60) 'low CPU accumulates an idle window'
Assert ((Get-IdleObservation $idle 15 $now.AddSeconds(65)).IdleSeconds -eq 0) 'busy CPU resets idle window'
Assert ((Get-IdleObservation $idle 10.2 $now.AddSeconds(200)).IdleSeconds -eq 0) 'long observation gaps reset idle window'
$row = [pscustomobject]@{Id=42;Name='chrome';SessionId=1;AgeSeconds=600;IdleSeconds=60;WorkingSetMB=200;BackoffUtc=$null}
Assert (@(Select-TrimCandidateRows @($row) explorer 10 '' 1 $now).Count -eq 1) 'eligible idle browser is selected'
Assert (@(Select-TrimCandidateRows @($row) chrome 10 '' 1 $now).Count -eq 0) 'foreground browser family excluded by policy'
Assert (@(Select-TrimCandidateRows @($row) powershell 10 chrome 1 $now).Count -eq 0) 'previous foreground browser remains protected on panel click'
Assert (@(Select-TrimCandidateRows @($row) explorer 10 '' 2 $now).Count -eq 0) 'other session excluded'
$row.Name='python'
Assert (@(Select-TrimCandidateRows @($row) explorer 10 '' 1 $now).Count -eq 0) 'unlisted Python process excluded'
$row.Name='chrome'; $row.IdleSeconds=59
Assert (@(Select-TrimCandidateRows @($row) explorer 10 '' 1 $now).Count -eq 0) 'insufficient idle time excluded'
$row.IdleSeconds=60; $row.AgeSeconds=299
Assert (@(Select-TrimCandidateRows @($row) explorer 10 '' 1 $now).Count -eq 0) 'young process excluded'
$row.AgeSeconds=600; $row.WorkingSetMB=149
Assert (@(Select-TrimCandidateRows @($row) explorer 10 '' 1 $now).Count -eq 0) 'small working set excluded'
$row.WorkingSetMB=200; $row.BackoffUtc=$now.AddMinutes(5)
Assert (@(Select-TrimCandidateRows @($row) explorer 10 '' 1 $now).Count -eq 0) 'denied process backoff enforced'
$many = @(1..5 | ForEach-Object { [pscustomobject]@{Id=$_;Name='chrome';SessionId=1;AgeSeconds=600;IdleSeconds=60;WorkingSetMB=200+$_;BackoffUtc=$null} })
$selected = @(Select-TrimCandidateRows $many explorer 10 '' 1 $now)
Assert ($selected.Count -eq 3 -and $selected[0].Id -eq 5) 'policy selects at most three largest candidates'
$chart = Get-MemoryChartData ([pscustomobject]@{TotalMB=16000;AvailableMB=4000}) @([pscustomobject]@{WorkingSet64=800MB})
Assert ($chart.UsedPercent -eq 75 -and $chart.CandidatePercent -eq 5) 'used and candidate percentages have physical RAM denominator'
$emptyChart = Get-MemoryChartData ([pscustomobject]@{TotalMB=16000;AvailableMB=4000}) @()
Assert ($emptyChart.CandidateMB -eq 0 -and $emptyChart.CandidateCount -eq 0) 'empty candidate graph is zero'
$helper = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList '-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 30"' -WindowStyle Hidden -PassThru
try {
    [RamNeko.Safety.TrimGuard]::Execute((New-Object RamNeko.Safety.CandidateIdentity($helper.Id, $helper.StartTime.ToUniversalTime().Ticks, $helper.ProcessName, $helper.SessionId)), (New-Object RamNeko.Safety.WindowsTrimNative))
    Assert $true 'real EmptyWorkingSet succeeds on a separate disposable process'
} finally {
    if (-not $helper.HasExited) { $helper.Kill() }
    $helper.Dispose()
}
$DataDirectory = Join-Path $PSScriptRoot ('test-' + [guid]::NewGuid().ToString('N'))
$script:trimCalls = 0
# Simulate pressure without touching user apps; keep real state/log I/O.
function Get-MemorySnapshot { [pscustomobject]@{ AvailableMB = 1000; TotalMB = 16000 } }
function Get-ForegroundProcess { [pscustomobject]@{ Id = 123; ProcessName = 'explorer' } }
function Get-TrimCandidates {
    $fake=[pscustomobject]@{ Id=456; ProcessName='chrome'; WorkingSet64=200MB; TrimIdentity=(New-Object RamNeko.Safety.CandidateIdentity(456, 1, 'chrome', 1)) }
    $fake | Add-Member -MemberType ScriptMethod -Name Refresh -Value {} -PassThru
}
function Invoke-WorkingSetTrim($Identity) { if ($Identity.Id -ne 456) { throw 'Wrong identity passed' }; $script:trimCalls++ }
1..3 | ForEach-Object {
    Invoke-MemoryWatch | Out-Null
    $path = Join-Path $DataDirectory 'state.json'
    $s = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $s.LastSampleUtc = [datetime]::UtcNow.AddSeconds(-60).ToString('o')
    $s | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8
}
Assert ($script:trimCalls -eq 1) 'three pressure samples invoke one trim through full state/log flow'
Invoke-MemoryWatch | Out-Null
Assert ($script:trimCalls -eq 1) 'persisted cooldown blocks next full invocation'
$log = @(Get-Content -LiteralPath (Join-Path $DataDirectory 'monitor.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
Assert (@($log | Where-Object Action -eq trim_attempt).Count -eq 1) 'trim attempt logged exactly once'
Assert ((Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).LastActionUtc) 'cooldown persisted'
$s = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
$s.LastActionUtc = [datetime]::UtcNow.AddMinutes(-2).ToString('o')
$s.LastSampleUtc = [datetime]::UtcNow.ToString('o')
$s | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8
function Get-MemorySnapshot { [pscustomobject]@{ AvailableMB=8000; TotalMB=16000 } }
$manual = Invoke-MemoryWatch -Manual | ConvertFrom-Json
Assert ($script:trimCalls -eq 2 -and $manual.Action -eq 'manual_trim') 'manual cleanup bypasses pressure and auto cooldown without bypassing candidates'
$blocked=$false
try { Invoke-MemoryWatch -Manual | Out-Null } catch { $blocked=$true }
Assert ($blocked -and $script:trimCalls -eq 2) 'manual cleanup retains sixty-second debounce'
$s=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
$s.LastSampleUtc=[datetime]::UtcNow.AddSeconds(-60).ToString('o')
$s|ConvertTo-Json|Set-Content -LiteralPath $path -Encoding UTF8
$observed=Invoke-MemoryWatch -DiagnosticsReference @{Schema='ram-neko.diagnostics';Version=1;ObservationOnly=$true;OsLow=$true;CommitPercent=100}|ConvertFrom-Json
Assert ($observed.Action -eq 'observe' -and $script:trimCalls -eq 2) 'new diagnostic pressure values cannot trigger cleanup'
Assert ($observed.LogSchemaVersion -eq 2 -and $observed.Diagnostics.ObservationOnly) 'optional versioned diagnostics reference preserves legacy log fields'
$s.LastActionUtc=[datetime]::UtcNow.AddMinutes(-2).ToString('o')
$s|ConvertTo-Json|Set-Content -LiteralPath $path -Encoding UTF8
function Invoke-WorkingSetTrim($Identity) { throw 'identity_mismatch' }
$failed=Invoke-MemoryWatch -Manual|ConvertFrom-Json
Assert ($failed.Results[0].Status -match 'identity_mismatch' -and $script:processBackoff[456] -gt [datetime]::UtcNow) 'identity rejection is logged and retains existing target backoff'
Assert ($failed.Results[0].SelectedStartUtcTicks -eq 1 -and $failed.Results[0].SelectedSessionId -eq 1) 'attempt log records the selected creation time and session without an image path'
# Only known test artifacts; never recursively delete a computed directory.
'state.json','monitor.jsonl','monitor.lock' | ForEach-Object { Remove-Item -LiteralPath (Join-Path $DataDirectory $_) }
Remove-Item -LiteralPath $DataDirectory
Write-Output 'ALL CHECKS PASSED'
