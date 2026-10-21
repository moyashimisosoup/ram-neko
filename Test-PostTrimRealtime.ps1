# Optional ~120-second native integration check. Only this disposable test host is trimmed.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if($PSVersionTable.PSEdition -ne 'Desktop'){throw 'Run with powershell.exe'}
Add-Type -Path @("$PSScriptRoot\TrimSafety.cs","$PSScriptRoot\PostTrimObserver.cs") -ReferencedAssemblies System,System.Core,System.Web.Extensions
function Assert($Condition,$Message){if(-not $Condition){throw "FAIL: $Message"};Write-Output "PASS: $Message"}
$directory=Join-Path $PSScriptRoot ('test-post-realtime-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $directory|Out-Null
$self=Get-Process -Id $PID
$identity=New-Object RamNeko.Safety.CandidateIdentity($self.Id,$self.StartTime.ToUniversalTime().Ticks,$self.ProcessName,$self.SessionId)
$engine=New-Object RamNeko.Safety.PostTrimEngine($directory,$null)
try{
    $receipt=[RamNeko.Safety.TrimGuard]::ExecuteObserved($identity,(New-Object RamNeko.Safety.WindowsTrimNative))
    Assert ($receipt.Before.Bytes['target.working_set_bytes'] -gt 0 -and $receipt.After.Bytes['target.working_set_bytes'] -gt 0) 'real before and after snapshots use the owned disposable trim handle'
    Assert ($engine.Enqueue(($receipt|ConvertTo-Json -Depth 8 -Compress)) -eq 'accepted') 'real-time observer schedules the disposable attempt'
    $deadline=[datetime]::UtcNow.AddSeconds(145)
    while($engine.LogWrites -lt 4 -and $engine.WorkerAlive -and [datetime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 250}
    Assert ($engine.LogWrites -eq 4 -and -not $engine.LastError) 'real worker writes all four phases without a UI timer'
    $rows=@(Get-Content (Join-Path $directory 'post-trim.jsonl')|ForEach-Object{$_|ConvertFrom-Json})
    Assert ($rows[2].Phase -eq '30s' -and $rows[2].ActualElapsedSeconds -ge 30 -and $rows[2].ActualElapsedSeconds -le 40 -and $rows[2].Snapshot.Bytes.'target.working_set_bytes' -gt 0) 'native thirty-second follow-up matches the same owned process'
    Assert ($rows[3].Phase -eq '120s' -and $rows[3].ActualElapsedSeconds -ge 120 -and $rows[3].ActualElapsedSeconds -le 130 -and $rows[3].Snapshot.Bytes.'target.working_set_bytes' -gt 0) 'native one-hundred-twenty-second follow-up matches the same owned process'
    $rows|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $PSScriptRoot 'post-trim-realtime-result.json') -Encoding UTF8
    $rows|Select-Object Phase,Status,ActualElapsedSeconds,LatenessSeconds,@{Name='CollectionMs';Expression={$_.Snapshot.DurationMs}}|ConvertTo-Json -Compress
}finally{
    $engine.Dispose();[void]$engine.WaitForStop(5000);$self.Dispose()
    foreach($name in @('post-trim.jsonl','post-trim.jsonl.1')){Remove-Item -LiteralPath (Join-Path $directory $name) -ErrorAction SilentlyContinue}
    Remove-Item -LiteralPath $directory
}
