$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Add-Type -Path @("$PSScriptRoot\TrimSafety.cs","$PSScriptRoot\PostTrimObserver.cs","$PSScriptRoot\PostTrimTestDoubles.cs") -ReferencedAssemblies System,System.Core,System.Web.Extensions
function Assert($Condition,$Message){if(-not $Condition){throw "FAIL: $Message"};Write-Output "PASS: $Message"}
$h=New-Object RamNeko.Safety.Testing.Harness
$json=$h.Receipt()
Assert ($h.Scheduler.Enqueue($json) -eq 'accepted' -and $h.Scheduler.Pending -eq 1) 'valid observed receipt enters bounded queue'
Assert ($h.Scheduler.Enqueue($json) -eq 'duplicate_receipt') 'duplicate pending attempts are rejected'
$h.Scheduler.Tick()
Assert ($h.Records.Count -eq 2 -and $h.Source.Reads -eq 0 -and $h.Records[0].Phase -eq 'before' -and $h.Records[1].Phase -eq 'after') 'before and after snapshots log without recollecting or holding a target handle'
Assert ($h.Records[0].Schema -eq 'ram-neko.post-trim' -and $h.Records[0].Version -eq 1 -and $h.Records[0].ObservationOnly) 'post-trim log has an observation-only versioned schema'
Assert ($null -eq $h.Records[0].Changes['target.working_set_rebound_from_after_bytes']) 'pre-trim memory cannot be labelled post-trim rebound'
$h.Clock.Now=129;$h.Scheduler.Tick()
Assert ($h.Source.Reads -eq 0 -and $h.Scheduler.NextWaitMilliseconds -eq 1000) 'thirty-second stage never runs early'
$h.Clock.Now=130;$h.Scheduler.Tick()
$at30=$h.Records[2]
Assert ($h.Source.Reads -eq 1 -and $at30.Phase -eq '30s' -and $at30.ActualElapsedSeconds -eq 30 -and $at30.LatenessSeconds -eq 0) 'thirty-second stage records actual monotonic elapsed time'
Assert ($at30.Changes['target.working_set_delta_from_before_bytes'] -eq -120 -and $at30.Changes['target.working_set_rebound_from_after_bytes'] -eq 80) 'working-set reduction and rebound remain signed observations'
Assert ($at30.Changes['target.logical_read_bytes_total_since_after'] -eq 300 -and $at30.Changes['self.cpu_seconds_since_after'] -eq 30) 'logical I/O and own CPU deltas retain byte and second units'
$h.Clock.Now=220;$h.Scheduler.Tick()
Assert ($h.Source.Reads -eq 2 -and $h.Records[3].Phase -eq '120s' -and $h.Scheduler.Pending -eq 0) 'one-hundred-twenty-second observation completes and releases job history'
$h=New-Object RamNeko.Safety.Testing.Harness
$large=$h.Receipt()|ConvertFrom-Json
$large.After.Bytes.'target.logical_read_bytes_total'=[uint64]::Parse('9223372036854775808')
$h.Source.ReadBytesOverride=[uint64]::Parse('9223372036854775809')
[void]$h.Scheduler.Enqueue(($large|ConvertTo-Json -Depth 8 -Compress));$h.Clock.Now=130;$h.Scheduler.Tick()
Assert ($h.Records[2].Changes['target.logical_read_bytes_total_since_after'] -eq 1) 'large cumulative counters subtract as integers before floating conversion'
$h.Source.ReadBytesOverride=1;$h.Clock.Now=220;$h.Scheduler.Tick()
Assert ($null -eq $h.Records[3].Changes['target.logical_read_bytes_total_since_after']) 'reset logical I/O counters do not produce false negative traffic'
$h=New-Object RamNeko.Safety.Testing.Harness
[void]$h.Scheduler.Enqueue($h.Receipt());$h.Clock.Now=300;$h.Scheduler.Tick()
Assert ($h.Source.Reads -eq 0 -and $h.Records.Count -eq 4 -and $h.Records[2].Reason -eq 'missed_deadline' -and $null -eq $h.Records[3].Snapshot) 'sleep or delayed polling records both missed stages without substituting late measurements'
$h=New-Object RamNeko.Safety.Testing.Harness
[void]$h.Scheduler.Enqueue($h.Receipt());$h.Source.Throw=$true;$h.Clock.Now=130;$h.Scheduler.Tick()
Assert ($h.Records[2].Status -eq 'unavailable' -and $null -eq $h.Records[2].Snapshot -and $h.Records[2].Reason -like 'target_exited*') 'target exit identity mismatch and API failure are missing observations rather than rebound'
$h.Source.Throw=$false;$h.Clock.Now=220;$h.Scheduler.Tick()
Assert ($h.Records[3].Status -eq 'ok') 'one failed stage does not suppress the later identity-checked observation'
$h=New-Object RamNeko.Safety.Testing.Harness
[void]$h.Scheduler.Enqueue($h.Receipt());$h.Source.AdvanceSeconds=11;$h.Clock.Now=130;$h.Scheduler.Tick()
Assert ($h.Records[2].Reason -eq 'collection_finished_late' -and $null -eq $h.Records[2].Snapshot) 'collection finishing outside deadline tolerance is explicitly missing'
$h=New-Object RamNeko.Safety.Testing.Harness
[void]$h.Scheduler.Enqueue($h.Receipt());$h.Source.Invalid=$true;$h.Clock.Now=130;$h.Scheduler.Tick()
Assert ($h.Records[2].Reason -eq 'invalid_observation') 'stale or malformed target snapshots cannot masquerade as current measurements'
$h=New-Object RamNeko.Safety.Testing.Harness
1..12|ForEach-Object{[void]$h.Scheduler.Enqueue($h.Receipt())}
Assert ($h.Scheduler.Pending -eq 12 -and $h.Scheduler.Enqueue($h.Receipt()) -eq 'queue_full') 'pending observation history has a fixed twelve-attempt bound'
$h.Scheduler.Stop()
Assert ($h.Scheduler.Enqueue($h.Receipt()) -eq 'stopped') 'stopped scheduler cannot accept more attempts'
$h.Scheduler.CancelPending()
Assert ($h.Scheduler.Pending -eq 0 -and @($h.Records|Where-Object Reason -eq 'observer_stopped').Count -eq 24) 'orderly shutdown marks pending stages cancelled and releases all jobs'
$h=New-Object RamNeko.Safety.Testing.Harness
$old=$h.Receipt();$h.Clock.Now+=6
Assert ($h.Scheduler.Enqueue($old) -eq 'stale_receipt' -and $h.Scheduler.Enqueue('invalid') -eq 'invalid_receipt' -and $h.Scheduler.Enqueue(('x'*17000)) -eq 'invalid_receipt') 'old malformed and oversized receipts are rejected'
$h=New-Object RamNeko.Safety.Testing.Harness
$h.WriteFailure=$true;[void]$h.Scheduler.Enqueue($h.Receipt());$h.Scheduler.Tick();$h.Clock.Now=220;$h.Scheduler.Tick()
Assert ($h.Scheduler.WriteFailures -eq 4 -and $h.Scheduler.Pending -eq 0) 'log failures do not retry indefinitely or retain jobs'
$h=New-Object RamNeko.Safety.Testing.Harness
$context='{"Utc":"2026-01-01T00:01:00Z","Metrics":{"paging.read_operations_per_second":{"Value":2,"Unit":"events/s","Status":"ok"},"disk.read_bytes_per_second":{"Value":400,"Unit":"bytes/s","Status":"ok"}}}'
$withContext=$h.WithContext($context);[void]$withContext.Enqueue($h.Receipt());$withContext.Tick()
Assert ($h.Records[1].DiagnosticContext.Status -eq 'cached' -and $h.Records[1].DiagnosticContext.AgeSeconds -eq 40) 'paging and disk context is labelled cached with source timestamp and age'
$h.Clock.Now=220;$withContext.Tick()
Assert ($h.Records[3].DiagnosticContext.Status -eq 'stale') 'old paging context is visibly stale rather than a phase-specific measurement'
$n=New-Object RamNeko.Safety.Testing.ObservedNative
$r=[RamNeko.Safety.TrimGuard]::ExecuteObserved($n.Identity,$n)
Assert ($n.Trims -eq 1 -and $n.Observations -eq 2 -and $n.Closes -eq 1 -and $r.Before -and $r.After) 'guard captures before and after on the verified control handle'
$n=New-Object RamNeko.Safety.Testing.ObservedNative;$n.ObservationThrows=$true
$r=[RamNeko.Safety.TrimGuard]::ExecuteObserved($n.Identity,$n)
Assert ($n.Trims -eq 1 -and $n.Closes -eq 1 -and $r.Before.Status -eq 'unavailable' -and $r.After.Status -eq 'unavailable') 'observation failure cannot weaken or suppress existing trim safety flow'
$native=New-Object RamNeko.Safety.WindowsTrimNative
$native.BeforeEmpty=[Action]{throw 'foreground_changed_before_trim'}
$blocked=$false;try{$native.Empty([IntPtr]::Zero)}catch{$blocked=$_.Exception.ToString() -match 'foreground_changed_before_trim'}
Assert $blocked 'foreground action recheck executes before the native mutation call'
# Real read-only sampling is restricted to this disposable test process.
$self=Get-Process -Id $PID
$identity=New-Object RamNeko.Safety.CandidateIdentity($self.Id,$self.StartTime.ToUniversalTime().Ticks,$self.ProcessName,$self.SessionId)
$source=New-Object RamNeko.Safety.NativeTargetObservationSource
$sample=$source.Read($identity)
Assert ($sample.Bytes['target.working_set_bytes'] -gt 0 -and $sample.Bytes['physical.available_bytes'] -gt 0 -and $sample.Bytes['commit.used_bytes'] -gt 0 -and $sample.SelfCpuSeconds -ge 0) 'native read-only sampling obtains owned target physical commit and observer measurements'
$reused=New-Object RamNeko.Safety.CandidateIdentity($identity.Id,($identity.StartUtcTicks+1),$identity.Name,$identity.SessionId)
$blocked=$false;try{$source.Read($reused)|Out-Null}catch{$blocked=$true}
Assert $blocked 'native delayed sampling rejects mismatched creation time on an owned test process'
$self.Dispose()
$directory=Join-Path $PSScriptRoot ('test-post-trim-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $directory|Out-Null
try{
    $h=New-Object RamNeko.Safety.Testing.Harness
    $engine=New-Object RamNeko.Safety.PostTrimEngine($directory,$h.Clock,$h.Source,$null)
    try{
        Assert ($engine.Enqueue($h.Receipt()) -eq 'accepted') 'background observer accepts metadata without running a UI callback'
        $deadline=[datetime]::UtcNow.AddSeconds(5)
        while($engine.LogWrites -lt 2 -and [datetime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 25}
        Assert ($engine.LogWrites -eq 2 -and $engine.WorkerAlive -and $h.Source.Reads -eq 0) 'idle worker writes baselines then waits without polling target processes'
    }finally{$engine.Dispose();Assert ($engine.WaitForStop(5000)) 'worker shuts down without waiting for delayed deadlines'}
    $rows=@(Get-Content (Join-Path $directory 'post-trim.jsonl')|ForEach-Object{$_|ConvertFrom-Json})
    Assert ($rows.Count -eq 4 -and $rows[3].Reason -eq 'observer_stopped') 'shutdown cancellations are flushed by the test worker'
    $path=Join-Path $directory 'rotation.jsonl'
    1..5|ForEach-Object{[RamNeko.Safety.PostTrimEngine]::AppendBounded($path,'{"x":123}',32)}
    Assert ((Get-Item $path).Length -le 32 -and (Get-Item "$path.1").Length -le 32) 'post-trim log and backup enforce strict byte limits'
    $blocked=$false;try{[RamNeko.Safety.PostTrimEngine]::AppendBounded($path,('x'*40),32)}catch{$blocked=$true}
    Assert $blocked 'oversized observation rows are rejected before append'
    # Bind the C# cache getter directly; no PowerShell scriptblock runs on a worker.
    . "$PSScriptRoot\Diagnostics.ps1"
    $diagnostics=Start-Diagnostics $directory 60
    try{
        $deadline=[datetime]::UtcNow.AddSeconds(5)
        while(-not $diagnostics.LatestJson -and [datetime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 25}
        $getter=$diagnostics.GetType().GetProperty('LatestJson').GetGetMethod()
        $context=[Delegate]::CreateDelegate([Func[string]],$diagnostics,$getter)
        $h=New-Object RamNeko.Safety.Testing.Harness
        $engine=New-Object RamNeko.Safety.PostTrimEngine($directory,$h.Clock,$h.Source,$context)
        try{
            [void]$engine.Enqueue($h.Receipt());$deadline=[datetime]::UtcNow.AddSeconds(5)
            while($engine.LogWrites -lt 2 -and [datetime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 25}
            Assert ($engine.LogWrites -eq 2 -and -not $engine.LastError) 'real diagnostic cache getter can be called from the observation worker without a PowerShell runspace'
        }finally{$engine.Dispose();[void]$engine.WaitForStop(5000)}
    }finally{$diagnostics.Dispose();[void]$diagnostics.WaitForStop(5000)}
    $blockedPath=Join-Path $directory 'blocked';'x'|Set-Content -LiteralPath $blockedPath
    $h=New-Object RamNeko.Safety.Testing.Harness
    $engine=New-Object RamNeko.Safety.PostTrimEngine($blockedPath,$h.Clock,$h.Source,$null)
    try{
        [void]$engine.Enqueue($h.Receipt());$deadline=[datetime]::UtcNow.AddSeconds(5)
        while(-not $engine.LastError -and [datetime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 25}
        Assert ($engine.LastError -like 'post_trim_log_io:*' -and $engine.WorkerAlive) 'real log I/O failure is exposed without killing the observation worker'
    }finally{$engine.Dispose();[void]$engine.WaitForStop(5000);Remove-Item -LiteralPath $blockedPath}
}finally{
    foreach($name in @('post-trim.jsonl','post-trim.jsonl.1','rotation.jsonl','rotation.jsonl.1','diagnostics.jsonl','diagnostics.jsonl.1')){Remove-Item -LiteralPath (Join-Path $directory $name) -ErrorAction SilentlyContinue}
    Remove-Item -LiteralPath $directory
}
Write-Output 'ALL POST-TRIM CHECKS PASSED'
