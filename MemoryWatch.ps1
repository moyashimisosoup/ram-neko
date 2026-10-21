param([switch]$LibraryOnly, [switch]$ObserveOnly, [string]$DataDirectory = "$PSScriptRoot\data")
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Diagnostics.ps1"
$script:trimPolicy = Get-Content -LiteralPath "$PSScriptRoot\policy.json" -Raw | ConvertFrom-Json
if (@($script:trimPolicy.AllowedNames).Count -eq 0 -or @($script:trimPolicy.AllowedNames | Where-Object { $_ -notin @('chrome','msedge','firefox') }).Count -or
    $script:trimPolicy.MinimumWorkingSetMB -lt 150 -or $script:trimPolicy.MinimumAgeSeconds -lt 300 -or
    $script:trimPolicy.MinimumIdleSeconds -lt 60 -or $script:trimPolicy.MaximumCpuCoreFraction -gt 0.01 -or
    $script:trimPolicy.MaximumCpuCoreFraction -lt 0 -or $script:trimPolicy.MaximumProcesses -lt 1 -or
    $script:trimPolicy.MaximumProcesses -gt 3 -or $script:trimPolicy.ManualCooldownSeconds -lt 60 -or
    $script:trimPolicy.AutomaticCooldownMinutes -lt 15 -or $script:trimPolicy.DeniedCooldownMinutes -lt 15) { throw 'Unsafe trimming policy' }
$script:processObservations = @{}
$script:processBackoff = @{}

function Get-MemoryDecision($AvailableMB, $TotalMB, $LowSamples, $LastActionUtc, $NowUtc) {
    $low = $AvailableMB -lt 1536 -and ($AvailableMB / $TotalMB) -lt 0.10
    $count = if ($low) { $LowSamples + 1 } else { 0 }
    $cool = $LastActionUtc -and ($NowUtc - ([datetime]$LastActionUtc).ToUniversalTime()).TotalMinutes -lt $script:trimPolicy.AutomaticCooldownMinutes
    [pscustomobject]@{ LowSamples = $count; Trim = ($count -ge 3 -and -not $cool) }
}

function Initialize-MemoryNative {
    if (-not ('RamNeko.Safety.TrimGuard' -as [type])) { Add-Type -Path @("$PSScriptRoot\TrimSafety.cs","$PSScriptRoot\PostTrimObserver.cs") -ReferencedAssemblies System,System.Core,System.Web.Extensions }
    if ('MemoryWatchNative' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class MemoryWatchNative {
  [StructLayout(LayoutKind.Sequential)] public struct Memory {
    public uint length, load;
    public ulong total, available, totalPage, availablePage, totalVirtual, availableVirtual, extended;
  }
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GlobalMemoryStatusEx(ref Memory m);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint id);
  public delegate void WinEvent(IntPtr hook, uint ev, IntPtr window, int obj, int child, uint thread, uint time);
  [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr module, WinEvent callback, uint process, uint thread, uint flags);
  [DllImport("user32.dll")] public static extern bool UnhookWinEvent(IntPtr hook);
  static WinEvent foregroundCallback;
  public static uint LastExternalProcessId;
  public static IntPtr StartForegroundTracking(uint self) {
    uint id; GetWindowThreadProcessId(GetForegroundWindow(), out id);
    if (id != self) LastExternalProcessId = id;
    foregroundCallback = delegate(IntPtr h, uint e, IntPtr w, int o, int c, uint t, uint ms) {
      uint p; GetWindowThreadProcessId(w, out p);
      if (p != 0 && p != self) LastExternalProcessId = p;
    };
    return SetWinEventHook(3, 3, IntPtr.Zero, foregroundCallback, 0, 0, 0);
  }
}
'@
}

function Get-MemorySnapshot {
    $m = New-Object MemoryWatchNative+Memory
    $m.length = [Runtime.InteropServices.Marshal]::SizeOf($m)
    if (-not [MemoryWatchNative]::GlobalMemoryStatusEx([ref]$m)) { throw 'GlobalMemoryStatusEx failed' }
    [pscustomobject]@{ AvailableMB = [math]::Round($m.available / 1MB); TotalMB = [math]::Round($m.total / 1MB) }
}

function Invoke-WorkingSetTrim([RamNeko.Safety.CandidateIdentity]$Identity,[switch]$Observe) {
    if ($null -eq $Identity -or $Identity.Name -notin $script:trimPolicy.AllowedNames -or
        $Identity.SessionId -ne (Get-Process -Id $PID).SessionId) { throw 'identity_not_allowed' }
    if($Observe){
        $native=New-Object RamNeko.Safety.WindowsTrimNative
        # Baseline probes add work after the outer focus check. Recheck on this same UI/action thread.
        $native.BeforeEmpty=[Action]{if((Get-ForegroundProcess).ProcessName -eq $Identity.Name){throw 'foreground_changed_before_trim'}}
        [RamNeko.Safety.TrimGuard]::ExecuteObserved($Identity,$native)
    }
    else{[RamNeko.Safety.TrimGuard]::Execute($Identity, (New-Object RamNeko.Safety.WindowsTrimNative))}
}

function Get-IdleObservation($Previous, [double]$CpuSeconds, [datetime]$NowUtc) {
    $idle = 0.0
    if ($Previous) {
        $elapsed = ($NowUtc - $Previous.Utc).TotalSeconds
        if ($elapsed -lt 1 -and $elapsed -ge 0) { return $Previous }
        if ($elapsed -ge 1 -and $elapsed -le 90 -and $CpuSeconds -ge $Previous.CpuSeconds -and
            (($CpuSeconds - $Previous.CpuSeconds) / $elapsed) -le $script:trimPolicy.MaximumCpuCoreFraction) {
            $idle = $Previous.IdleSeconds + $elapsed
        }
    }
    [pscustomobject]@{ Utc=$NowUtc; CpuSeconds=$CpuSeconds; IdleSeconds=$idle }
}

function Select-TrimCandidateRows($Rows, $ForegroundName, $ForegroundId, $ProtectedName, $SessionId, $NowUtc) {
    @($Rows | Where-Object {
        $_.Name -in $script:trimPolicy.AllowedNames -and $_.SessionId -eq $SessionId -and
        $_.Id -ne $ForegroundId -and $_.Name -ne $ForegroundName -and $_.Name -ne $ProtectedName -and
        $_.AgeSeconds -ge $script:trimPolicy.MinimumAgeSeconds -and
        $_.IdleSeconds -ge $script:trimPolicy.MinimumIdleSeconds -and
        $_.WorkingSetMB -ge $script:trimPolicy.MinimumWorkingSetMB -and
        (-not $_.BackoffUtc -or $_.BackoffUtc -le $NowUtc)
    } | Sort-Object WorkingSetMB -Descending | Select-Object -First $script:trimPolicy.MaximumProcesses)
}

function Get-TrimCandidates([string]$ForegroundName, [int]$ForegroundId, [string]$ProtectedName = '') {
    $session = (Get-Process -Id $PID).SessionId
    $now = [datetime]::UtcNow
    $seen = @{}
    $rows = @(foreach ($process in @(Get-Process -Name $script:trimPolicy.AllowedNames -ErrorAction SilentlyContinue)) {
        try {
            if ($process.SessionId -ne $session) { continue }
            $startUtc = $process.StartTime.ToUniversalTime()
            $identity = New-Object RamNeko.Safety.CandidateIdentity($process.Id, $startUtc.Ticks, $process.ProcessName, $process.SessionId)
            $key = "$($identity.Id):$($identity.StartUtcTicks)"
            $seen[$key] = $true
            $observation = Get-IdleObservation $script:processObservations[$key] $process.TotalProcessorTime.TotalSeconds $now
            $script:processObservations[$key] = $observation
            if ($process.Id -eq $ForegroundId -or $process.ProcessName -eq $ForegroundName -or $process.ProcessName -eq $ProtectedName) {
                $observation.IdleSeconds = 0; continue
            }
            $process | Add-Member -NotePropertyName TrimIdentity -NotePropertyValue $identity -Force
            [pscustomobject]@{Process=$process;Id=$process.Id;Name=$process.ProcessName;SessionId=$process.SessionId;
                AgeSeconds=($now-$startUtc).TotalSeconds;IdleSeconds=$observation.IdleSeconds;
                WorkingSetMB=$process.WorkingSet64/1MB;BackoffUtc=$script:processBackoff[$process.Id]}
        } catch { continue }
    })
    foreach ($key in @($script:processObservations.Keys)) { if (-not $seen.ContainsKey($key)) { $script:processObservations.Remove($key) } }
    @(Select-TrimCandidateRows $rows $ForegroundName $ForegroundId $ProtectedName $session $now | ForEach-Object { $_.Process })
}

function Get-MemoryChartData($Memory, $Candidates) {
    $used = [math]::Max(0, $Memory.TotalMB - $Memory.AvailableMB)
    $sum = if ($null -ne $Candidates -and @($Candidates).Count -gt 0) { [double](($Candidates | Measure-Object WorkingSet64 -Sum).Sum) / 1MB } else { 0.0 }
    [pscustomobject]@{ UsedPercent=[math]::Round(100*$used/$Memory.TotalMB,1);
        CandidatePercent=[math]::Min(100,[math]::Round(100*$sum/$Memory.TotalMB,1));
        CandidateMB=[math]::Round($sum); CandidateCount=@($Candidates).Count }
}

function Get-ForegroundProcess {
    [uint32]$foregroundId = 0
    $window = [MemoryWatchNative]::GetForegroundWindow()
    if ($window -eq [IntPtr]::Zero) { throw 'Foreground window unavailable; skip trimming' }
    [void][MemoryWatchNative]::GetWindowThreadProcessId($window, [ref]$foregroundId)
    Get-Process -Id $foregroundId -ErrorAction Stop
}

function Write-MemoryLog($Entry) {
    $path = Join-Path $DataDirectory 'monitor.jsonl'
    if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 5MB) {
        Move-Item -LiteralPath $path -Destination "$path.1" -Force
    }
    $Entry | ConvertTo-Json -Depth 6 -Compress | Add-Content -LiteralPath $path -Encoding UTF8
}

function Invoke-MemoryWatch([switch]$Manual, [string]$ProtectedName = '', $DiagnosticsReference = $null, $EvaluationObserver = $null) {
    New-Item -ItemType Directory -Path $DataDirectory -Force | Out-Null
    # File lock also excludes concurrent manual invocations. No persistent process.
    try { $lock = [IO.File]::Open((Join-Path $DataDirectory 'monitor.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
    catch [IO.IOException] { if ($Manual) { throw 'Monitor busy; try again' }; return }
    try {
        Initialize-MemoryNative
        $now = [datetime]::UtcNow
        $statePath = Join-Path $DataDirectory 'state.json'
        $state = [pscustomobject]@{ LowSamples = 0; LastSampleUtc = $null; LastActionUtc = $null }
        if (Test-Path -LiteralPath $statePath) { $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json }
        if (-not $Manual -and $state.LastSampleUtc -and ($now - ([datetime]$state.LastSampleUtc).ToUniversalTime()).TotalSeconds -lt 45) { return }
        if ($Manual -and $state.LastActionUtc -and ($now - ([datetime]$state.LastActionUtc).ToUniversalTime()).TotalSeconds -lt $script:trimPolicy.ManualCooldownSeconds) { throw 'Wait 60 seconds after the previous cleanup' }
        if (-not $state.LastSampleUtc -or ($now - ([datetime]$state.LastSampleUtc).ToUniversalTime()).TotalMinutes -gt 3) { $state.LowSamples = 0 }
        $memory = Get-MemorySnapshot
        $decision = Get-MemoryDecision $memory.AvailableMB $memory.TotalMB $state.LowSamples $state.LastActionUtc $now
        $entry = [ordered]@{ Utc = $now.ToString('o'); AvailableMB = $memory.AvailableMB; TotalMB = $memory.TotalMB; LowSamples = $decision.LowSamples; Action = 'observe'; Results = @() }
        if($null -ne $DiagnosticsReference){$entry.LogSchemaVersion=2;$entry.Diagnostics=$DiagnosticsReference}
        $state.LowSamples = $decision.LowSamples
        $state.LastSampleUtc = $now.ToString('o')
        if (($decision.Trim -or $Manual) -and -not $ObserveOnly) {
            # Persist cooldown BEFORE mutation, including failures/no candidates.
            $state.LastActionUtc = $now.ToString('o')
            $state.LowSamples = 0
            $state | ConvertTo-Json | Set-Content -LiteralPath "$statePath.tmp" -Encoding UTF8
            Move-Item -LiteralPath "$statePath.tmp" -Destination $statePath -Force
            $foreground = Get-ForegroundProcess
            $entry.Action = if ($Manual) { 'manual_trim' } else { 'trim_attempt' }
            foreach ($process in @(Get-TrimCandidates $foreground.ProcessName $foreground.Id $ProtectedName)) {
                if (-not $Manual -and (Get-MemorySnapshot).AvailableMB -ge 2048) { break }
                # Recheck focus immediately before touching a process.
                $current = Get-ForegroundProcess
                if ($current.ProcessName -eq $process.ProcessName -or $process.ProcessName -eq $ProtectedName) { continue }
                $result = [ordered]@{ Id = $process.Id; Name = $process.ProcessName; BeforeMB = [math]::Round($process.WorkingSet64 / 1MB); Status = 'ok' }
                try {
                    $result.SelectedStartUtcTicks = $process.TrimIdentity.StartUtcTicks
                    $result.SelectedSessionId = $process.TrimIdentity.SessionId
                    $receipt=Invoke-WorkingSetTrim $process.TrimIdentity -Observe:($null -ne $EvaluationObserver)
                    $result.ObservationScheduling='disabled'
                    if($null -ne $EvaluationObserver){
                        try{
                            $result.ObservationAttemptId=$receipt.AttemptId
                            $result.ObservationScheduling=$EvaluationObserver.Enqueue(($receipt|ConvertTo-Json -Depth 8 -Compress))
                        }catch{$result.ObservationScheduling='observation_unavailable'}
                    }
                    $process.Refresh()
                    $result.AfterMB = [math]::Round($process.WorkingSet64/1MB)
                }
                catch { $result.Status = $_.Exception.Message; $script:processBackoff[$process.Id] = $now.AddMinutes($script:trimPolicy.DeniedCooldownMinutes) }
                $entry.Results += $result
            }
            $entry.AfterAvailableMB = (Get-MemorySnapshot).AvailableMB
        }
        $state | ConvertTo-Json | Set-Content -LiteralPath "$statePath.tmp" -Encoding UTF8
        Move-Item -LiteralPath "$statePath.tmp" -Destination $statePath -Force
        Write-MemoryLog $entry
        [pscustomobject]$entry | ConvertTo-Json -Depth 6 -Compress
    } catch {
        Write-MemoryLog @{ Utc = [datetime]::UtcNow.ToString('o'); Action = 'error'; Error = $_.Exception.Message }
        throw
    } finally { $lock.Dispose() }
}

if (-not $LibraryOnly) { Invoke-MemoryWatch }
