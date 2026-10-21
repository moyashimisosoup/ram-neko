param([ValidateRange(3,30)][int]$Samples=6,[ValidateRange(100,10000)][int]$GapMilliseconds=1000)
$ErrorActionPreference='Stop'
$process=Get-Process -Id $PID
$initialWorkingSet=$process.WorkingSet64
. "$PSScriptRoot\Diagnostics.ps1"
Initialize-Diagnostics
$source=New-Object RamNeko.Diagnostics.NativeDiagnosticSource
$sampler=New-Object RamNeko.Diagnostics.DiagnosticSampler($source,(New-Object RamNeko.Diagnostics.DiagnosticClock),60)
$serializer=New-Object Web.Script.Serialization.JavaScriptSerializer
$directory=Join-Path $PSScriptRoot ('measure-diagnostics-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $directory|Out-Null
$duration=@();$writeTimes=@();$sizes=@();$last=$null
$process.Refresh();$cpuBefore=$process.TotalProcessorTime.TotalMilliseconds
$elapsed=[Diagnostics.Stopwatch]::StartNew()
try{
    foreach($i in 1..$Samples){
        $sample=$sampler.Sample();$last=$sample
        $duration+=$sample.CollectionDurationMs
        $json=$serializer.Serialize($sample)
        $sizes+=[Text.Encoding]::UTF8.GetByteCount($json+[Environment]::NewLine)
        $write=[Diagnostics.Stopwatch]::StartNew()
        [RamNeko.Diagnostics.DiagnosticEngine]::AppendBounded((Join-Path $directory 'diagnostics.jsonl'),$json)
        $write.Stop();$writeTimes+=$write.Elapsed.TotalMilliseconds
        if($i -lt $Samples){Start-Sleep -Milliseconds $GapMilliseconds}
    }
    $process.Refresh()
    $missing=@($last.Metrics.Values|Where-Object Status -ne ok).Count
    [pscustomobject]@{
        Samples=$Samples;GapMilliseconds=$GapMilliseconds;ElapsedSeconds=$elapsed.Elapsed.TotalSeconds
        CollectionMeanMs=($duration|Measure-Object -Average).Average;CollectionMaxMs=($duration|Measure-Object -Maximum).Maximum
        LogAppendMeanMs=($writeTimes|Measure-Object -Average).Average
        CpuMilliseconds=$process.TotalProcessorTime.TotalMilliseconds-$cpuBefore
        WorkingSetBeforeInitializationBytes=$initialWorkingSet;WorkingSetAfterBytes=$process.WorkingSet64
        MeanRecordBytes=($sizes|Measure-Object -Average).Average;LastSampleMissingMetricCount=$missing
        DiagnosticIntervalSeconds=60;EstimatedLogBytesPerHour=(($sizes|Measure-Object -Average).Average*60)
        PagingFaultStatus=$last.Metrics['paging.total_faults_per_second'].Status
        PagingReadStatus=$last.Metrics['paging.read_operations_per_second'].Status
        DiskReadStatus=$last.Metrics['disk.read_bytes_per_second'].Status
        Comparison='Observer microbenchmark only; not an application-responsiveness benchmark'
    }|ConvertTo-Json
}finally{
    $sampler.Dispose();$process.Dispose()
    Remove-Item -LiteralPath (Join-Path $directory 'diagnostics.jsonl') -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $directory
}
