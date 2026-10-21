$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if($PSVersionTable.PSEdition -ne 'Desktop'){throw 'Run with powershell.exe'}
Add-Type -Path @("$PSScriptRoot\DiagnosticsEngine.cs","$PSScriptRoot\DiagnosticsTestDoubles.cs") -ReferencedAssemblies System,System.Core,System.Web.Extensions
function Assert($Value,$Message){if(-not $Value){throw "FAIL: $Message"};Write-Output "PASS: $Message"}
$source=New-Object RamNeko.Diagnostics.Testing.Source
$clock=New-Object RamNeko.Diagnostics.Testing.Clock
$sampler=New-Object RamNeko.Diagnostics.DiagnosticSampler($source,$clock,60)
$source.Value.Idle=50;$source.Value.Kernel=100;$source.Value.User=100
$source.Value.SelfCpuSeconds=3;$source.Value.SelfReadBytes=100;$source.Value.SelfWriteBytes=200;$source.Value.ProcessorCount=4
$source.Value.Metrics['physical.available_bytes']=[RamNeko.Diagnostics.Metric]::Ok(4000,'bytes','fake')
$source.Value.Metrics['commit.used_bytes']=[RamNeko.Diagnostics.Metric]::Ok(100,'bytes','fake')
$source.Value.Metrics['paging.total_faults_per_second']=[RamNeko.Diagnostics.Metric]::Ok(1234,'events/s','fake')
$source.Value.Metrics['paging.read_operations_per_second']=[RamNeko.Diagnostics.Metric]::Ok(2,'events/s','fake')
$first=$sampler.Sample()
Assert ($first.Version -eq 1 -and $first.ObservationOnly -and $first.Schema -eq 'ram-neko.diagnostics') 'versioned observation-only schema'
Assert ($null -eq $first.Metrics['cpu.system_percent'].Value -and $first.Metrics['cpu.system_percent'].Status -eq 'warmup') 'first CPU sample is missing, not zero'
Assert ($first.Metrics['paging.total_faults_per_second'].Value -eq 1234 -and $first.Metrics['paging.read_operations_per_second'].Value -eq 2) 'total faults and paging read operations stay distinct without a percent cap'
Assert ($null -eq $first.Metrics['paging.hard_faults_per_second'].Value -and $first.Metrics['interaction.app_switch_ms'].Status -eq 'unavailable') 'unmeasured hard-fault count and responsiveness are explicit missing fields'
Assert ([RamNeko.Diagnostics.DiagnosticSampler]::PagesToBytes(2048,4096) -eq 8388608) 'commit pages convert to bytes'
$overflow=$false;try{[RamNeko.Diagnostics.DiagnosticSampler]::PagesToBytes([ulong]::MaxValue,4096)|Out-Null}catch{$overflow=$true}
Assert $overflow 'overflow cannot become a false byte measurement'
$next=New-Object RamNeko.Diagnostics.RawSnapshot
$next.Idle=70;$next.Kernel=150;$next.User=150;$next.ProcessorCount=4
$next.SelfCpuSeconds=3.4;$next.SelfReadBytes=500;$next.SelfWriteBytes=300
$next.Metrics['physical.available_bytes']=[RamNeko.Diagnostics.Metric]::Ok(3000,'bytes','fake')
$next.Metrics['commit.used_bytes']=[RamNeko.Diagnostics.Metric]::Ok(200,'bytes','fake')
$source.Value=$next;$clock.Now=2
$second=$sampler.Sample()
Assert ($second.Metrics['cpu.system_percent'].Value -eq 80) 'system CPU accounts for idle included in kernel time'
Assert ([math]::Abs($second.Metrics['self.cpu_percent'].Value-5) -lt 0.00001) 'self CPU is normalized by elapsed time and processor count'
Assert ($second.Metrics['self.io_read_bytes_per_second'].Value -eq 200 -and $second.Metrics['self.io_write_bytes_per_second'].Value -eq 50) 'logical I/O rates use interval deltas'
Assert ($second.Metrics['physical.available_bytes_per_second'].Value -eq -500 -and $second.Metrics['commit.used_bytes_per_second'].Value -eq 50) 'memory trends preserve signed byte rates'
$reset=New-Object RamNeko.Diagnostics.RawSnapshot
$reset.Idle=1;$reset.Kernel=2;$reset.User=3;$reset.SelfReadBytes=1;$reset.SelfWriteBytes=1;$source.Value=$reset;$clock.Now=3
$resetSample=$sampler.Sample()
Assert ($resetSample.Metrics['cpu.system_percent'].Status -ne 'ok' -and $null -eq $resetSample.Metrics['self.io_read_bytes_per_second'].Value) 'reset CPU and I/O counters do not produce false rates'
$clock.Now=400
$gap=$sampler.Sample()
Assert ($gap.Metrics['cpu.system_percent'].Status -ne 'ok' -and $null -eq $gap.ElapsedSeconds) 'long sampling gap is not a current CPU estimate'
$source.Value=New-Object RamNeko.Diagnostics.RawSnapshot;$clock.Now=401
$partial=$sampler.Sample()
Assert ($null -eq $partial.Metrics['commit.used_bytes'].Value -and $partial.Metrics['commit.used_bytes'].Status -eq 'unavailable') 'API failures stay unavailable rather than zero'
$source.Throw=$true;$clock.Now=402
$failed=$sampler.Sample()
Assert ($failed.ProcessCollectionStatus -eq 'provider_error' -and $null -eq $failed.Metrics['physical.available_bytes'].Value) 'source exceptions produce missing diagnostics'
$sampler.Dispose();Assert $source.Disposed 'source lifecycle disposed'
. "$PSScriptRoot\Diagnostics.ps1"
$config=Get-DiagnosticsConfiguration
Assert ($config.ObservationOnly -and $config.IntervalSeconds -eq 60) 'default diagnostic configuration is observation-only at sixty seconds'
$config.ObservationOnly=$false
$rejected=$false;try{Test-DiagnosticsConfiguration $config|Out-Null}catch{$rejected=$true}
Assert $rejected 'diagnostic configuration cannot turn observation into control'
$config.ObservationOnly=$true;$config.IntervalSeconds=30.5
$rejected=$false;try{Test-DiagnosticsConfiguration $config|Out-Null}catch{$rejected=$true}
Assert $rejected 'fractional or out-of-contract sampling intervals rejected'
$native=New-Object RamNeko.Diagnostics.DiagnosticSampler((New-Object RamNeko.Diagnostics.NativeDiagnosticSource),(New-Object RamNeko.Diagnostics.DiagnosticClock),60)
try{
    $real=$native.Sample()
    Assert ($real.Metrics['physical.total_bytes'].Status -eq 'ok' -and $real.Metrics['physical.total_bytes'].Value -gt 0) 'real physical-memory API works'
    Assert ($real.Metrics['commit.used_bytes'].Status -eq 'ok' -and $real.Metrics['commit.limit_bytes'].Value -ge $real.Metrics['commit.used_bytes'].Value) 'real commit API returns byte values'
    Assert ($real.Metrics['memory.os_low'].Value -is [bool] -or $real.Metrics['memory.os_low'].Status -eq 'unavailable') 'OS low-memory state is boolean or explicitly missing'
    Assert ($real.Processes.Count -le 5 -and $real.Metrics['self.working_set_bytes'].Value -gt 0) 'major process list is bounded and self memory measured'
}finally{$native.Dispose()}
$directory=Join-Path $PSScriptRoot ('test-diagnostics-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $directory|Out-Null
try{
    $path=Join-Path $directory 'rotation.jsonl'
    1..5|ForEach-Object{[RamNeko.Diagnostics.DiagnosticEngine]::AppendBounded($path,'{"x":123}',32)}
    Assert ((Get-Item -LiteralPath $path).Length -le 32 -and (Get-Item -LiteralPath "$path.1").Length -le 32) 'diagnostic log and backup have strict size bounds'
    $oversize=$false;try{[RamNeko.Diagnostics.DiagnosticEngine]::AppendBounded($path,('x'*40),32)}catch{$oversize=$true}
    Assert $oversize 'oversized record rejected before append'
    $workerSource=New-Object RamNeko.Diagnostics.Testing.Source
    $engine=New-Object RamNeko.Diagnostics.DiagnosticEngine($directory,60,$workerSource.Factory())
    try{
        $timeout=[datetime]::UtcNow.AddSeconds(15)
        while(-not $engine.LatestJson -and $engine.WorkerAlive -and [datetime]::UtcNow -lt $timeout){Start-Sleep -Milliseconds 100}
        Assert ($engine.LatestJson -and $engine.WorkerAlive) 'background worker publishes a snapshot without a UI callback'
        $cached=$engine.LatestJson;1..10|ForEach-Object{$engine.LatestJson|Out-Null}
        Assert ($engine.LatestJson -eq $cached -and $engine.LogWrites -le 1) 'cached UI reads do not recollect or write logs'
    }finally{$engine.Dispose();Assert ($engine.WaitForStop(10000) -and $workerSource.Disposed) 'background worker stops and disposes its injected source'}
    $blockedPath=Join-Path $directory 'not-a-directory'
    'x'|Set-Content -LiteralPath $blockedPath
    $ioSource=New-Object RamNeko.Diagnostics.Testing.Source
    $engine=New-Object RamNeko.Diagnostics.DiagnosticEngine($blockedPath,60,$ioSource.Factory())
    try{
        $timeout=[datetime]::UtcNow.AddSeconds(5)
        while(-not $engine.LastError -and [datetime]::UtcNow -lt $timeout){Start-Sleep -Milliseconds 50}
        Assert ($engine.LatestJson -and $engine.WorkerAlive -and $engine.LastError -like 'log_io:*') 'diagnostic log failure preserves cached observation and worker isolation'
    }finally{$engine.Dispose();[void]$engine.WaitForStop(10000);Remove-Item -LiteralPath $blockedPath}
}finally{
    foreach($name in @('rotation.jsonl','rotation.jsonl.1','diagnostics.jsonl','diagnostics.jsonl.1')){Remove-Item -LiteralPath (Join-Path $directory $name) -ErrorAction SilentlyContinue}
    Remove-Item -LiteralPath $directory
}
Write-Output 'ALL DIAGNOSTICS CHECKS PASSED'
