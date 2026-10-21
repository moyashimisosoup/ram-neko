$ErrorActionPreference = 'Stop'
function Assert($Condition, $Message) { if (-not $Condition) { throw "FAIL: $Message" }; Write-Output "PASS: $Message" }
# Compile the real guard with a fake transport. These tests never open user processes.
$fakeSource = @'
namespace RamNeko.Safety {
    public sealed class FakeTrimNative : ITrimNative {
        public CandidateIdentity Actual;
        public int Opens, Reads, Trims, Closes;
        public string Failure;
        public System.IntPtr Open(int id) {
            Opens++;
            if (Failure == "open") throw new System.InvalidOperationException("access_denied");
            return Failure == "zero" ? System.IntPtr.Zero : new System.IntPtr(73);
        }
        void SameHandle(System.IntPtr handle) {
            if (handle.ToInt64() != 73) throw new System.Exception("wrong_handle");
        }
        public CandidateIdentity ReadIdentity(System.IntPtr handle) {
            SameHandle(handle); Reads++;
            if (Failure == "read" || Failure == "exit") throw new System.InvalidOperationException(Failure);
            return Actual;
        }
        public void Empty(System.IntPtr handle) {
            SameHandle(handle); Trims++;
            if (Failure == "trim") throw new System.InvalidOperationException("trim_failed");
        }
        public void Close(System.IntPtr handle) { SameHandle(handle); Closes++; }
    }
}
'@
Add-Type -TypeDefinition ((Get-Content -LiteralPath "$PSScriptRoot\TrimSafety.cs" -Raw) + $fakeSource)
. "$PSScriptRoot\MemoryWatch.ps1" -LibraryOnly
Initialize-MemoryNative
$expected = New-Object RamNeko.Safety.CandidateIdentity(42, 100, 'chrome', 1)
function Invoke-FakeCase($Actual, $Failure = '') {
    $native = New-Object RamNeko.Safety.FakeTrimNative
    $native.Actual = $Actual; $native.Failure = $Failure
    $blocked = $false
    try { [RamNeko.Safety.TrimGuard]::Execute($expected, $native) } catch { $blocked = $true }
    [pscustomobject]@{Native=$native;Blocked=$blocked}
}
$ok = Invoke-FakeCase (New-Object RamNeko.Safety.CandidateIdentity(42,100,'CHROME',1))
Assert (-not $ok.Blocked -and $ok.Native.Opens -eq 1 -and $ok.Native.Reads -eq 1 -and $ok.Native.Trims -eq 1 -and $ok.Native.Closes -eq 1) 'matching identity trims once using the same verified handle and closes it'
$cases = @(
    (New-Object RamNeko.Safety.CandidateIdentity(43,100,'chrome',1)),
    (New-Object RamNeko.Safety.CandidateIdentity(42,101,'chrome',1)),
    (New-Object RamNeko.Safety.CandidateIdentity(42,100,'firefox',1)),
    (New-Object RamNeko.Safety.CandidateIdentity(42,100,'chrome',2))
)
$labels = @('PID mismatch','PID reuse with a different creation time','image name mismatch','session mismatch')
for ($i=0; $i -lt $cases.Count; $i++) {
    $r = Invoke-FakeCase $cases[$i]
    Assert ($r.Blocked -and $r.Native.Trims -eq 0 -and $r.Native.Closes -eq 1) "$($labels[$i]) skips mutation and closes the handle"
}
$missing = Invoke-FakeCase $null
Assert ($missing.Blocked -and $missing.Native.Trims -eq 0 -and $missing.Native.Closes -eq 1) 'missing identity fails closed'
foreach ($failure in @('open','zero','read','exit','trim')) {
    $r = Invoke-FakeCase $expected $failure
    $expectedCloses = if ($failure -in @('open','zero')) {0} else {1}
    $expectedTrims = if ($failure -eq 'trim') {1} else {0}
    Assert ($r.Blocked -and $r.Native.Closes -eq $expectedCloses -and $r.Native.Trims -eq $expectedTrims) "$failure failure propagates without a leaked handle or retry"
}
$immutable = $false
try { $expected.StartUtcTicks = 999 } catch { $immutable = $true }
Assert ($immutable -and $expected.StartUtcTicks -eq 100) 'selection identity cannot be refreshed or overwritten'
$blocked = $false
try { Invoke-WorkingSetTrim $null } catch { $blocked = $true }
Assert $blocked 'production wrapper rejects missing selection identity'
$self = Get-Process -Id $PID
$blocked = $false
try { Invoke-WorkingSetTrim (New-Object RamNeko.Safety.CandidateIdentity($self.Id,$self.StartTime.ToUniversalTime().Ticks,$self.ProcessName,$self.SessionId)) } catch { $blocked = $true }
Assert $blocked 'production wrapper rejects unlisted test process without trimming it'
$blocked = $false
try { Invoke-WorkingSetTrim (New-Object RamNeko.Safety.CandidateIdentity($self.Id,$self.StartTime.ToUniversalTime().Ticks,'chrome',($self.SessionId+1))) } catch { $blocked = $true }
Assert $blocked 'production wrapper rejects another session before opening a handle'
# Read-only native metadata validation on this explicitly owned test process.
$native = New-Object RamNeko.Safety.WindowsTrimNative
$handle = $native.Open($PID)
try {
    $actual = $native.ReadIdentity($handle)
    Assert ($actual.Id -eq $self.Id -and $actual.StartUtcTicks -eq $self.StartTime.ToUniversalTime().Ticks -and $actual.Name -eq $self.ProcessName -and $actual.SessionId -eq $self.SessionId) 'native same-handle creation time image and token session match owned process'
} finally { $native.Close($handle); $self.Dispose() }
# Candidate collection is mocked too: no browser state or browser mutation.
$session = (Get-Process -Id $PID).SessionId
$start = [datetime]::UtcNow.AddMinutes(-10)
$script:fakeProcess = [pscustomobject]@{Id=42; ProcessName='chrome'; SessionId=$session; StartTime=$start; TotalProcessorTime=[timespan]::Zero; WorkingSet64=200MB}
function Get-Process { param($Id, $Name, $ErrorAction) if ($Id -eq $PID) { [pscustomobject]@{SessionId=$session} } else { $script:fakeProcess } }
$script:processObservations["42:$($start.Ticks)"] = [pscustomobject]@{Utc=[datetime]::UtcNow.AddSeconds(-65);CpuSeconds=0;IdleSeconds=0}
$selected = @(Get-TrimCandidates explorer 123)
Assert ($selected.Count -eq 1 -and $selected[0].TrimIdentity.Id -eq 42 -and $selected[0].TrimIdentity.StartUtcTicks -eq $start.Ticks -and $selected[0].TrimIdentity.SessionId -eq $session) 'candidate collection captures immutable identity alongside existing eligibility gates'
$savedIdentity = $selected[0].TrimIdentity
$script:fakeProcess.StartTime = $start.AddSeconds(1)
Assert (@(Get-TrimCandidates explorer 123).Count -eq 0 -and $savedIdentity.StartUtcTicks -eq $start.Ticks) 'reused PID requires a new idle observation window and preserves old selection identity'
Write-Output 'ALL TRIM SAFETY CHECKS PASSED'
