$ErrorActionPreference='Stop'
$DataDirectory=Join-Path $PSScriptRoot ('test-gadget-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $DataDirectory|Out-Null
. "$PSScriptRoot\GadgetSupport.ps1"
try {
    Write-GadgetEvent 'window_mode' 'Topmost'
    $value=[pscustomobject]@{Palette='Mint';WindowMode='Desktop';X=12;Y=34}
    Write-GadgetPreferences $value
    $read=Read-GadgetPreferences
    if($read.Palette -ne 'Mint' -or $read.WindowMode -ne 'Desktop' -or $read.X -ne 12){throw 'Preference roundtrip failed'}
    $rows=1..305|ForEach-Object{[pscustomobject]@{Utc='2026-01-01T00:00:00Z';Action='observe';AvailableMB=4000;TotalMB=16000;Results=@()}|ConvertTo-Json -Compress}
    $rows|Set-Content -LiteralPath (Join-Path $DataDirectory 'monitor.jsonl') -Encoding UTF8
    $csv=Join-Path $DataDirectory 'export.csv'
    Export-GadgetLogs $csv
    $exported=@(Import-Csv -LiteralPath $csv)
    if($exported.Count -ne 306 -or @($exported|Where-Object UsedPercent -eq 75).Count -ne 305){throw 'Full retained log export truncated or incorrect'}
    'bad-json'|Add-Content -LiteralPath (Join-Path $DataDirectory 'monitor.jsonl')
    if(-not @(Get-GadgetLogRows|Where-Object Action -eq unreadable_row).Count){throw 'Malformed log handling failed'}
    Write-Output 'PASS: preferences roundtrip, complete CSV export beyond viewer tail, malformed log handling'
    $post=[pscustomobject]@{Schema='ram-neko.post-trim';Version=1;Utc='2026-01-01T00:00:30Z';Phase='30s';Status='ok';Reason=$null;ActualElapsedSeconds=30;Changes=@{'target.working_set_delta_from_before_bytes'=-150MB;'target.working_set_rebound_from_after_bytes'=50MB};Snapshot=@{Bytes=@{'physical.available_bytes'=4000MB}}}
    $post|ConvertTo-Json -Depth 8 -Compress|Set-Content -LiteralPath (Join-Path $DataDirectory 'post-trim.jsonl') -Encoding UTF8
    $text=Format-PostTrimSummary $post
    if($text -notlike '*-150.0 MB*' -or $text -notlike '*+50.0 MB*' -or $text -notlike '*未判定*'){throw 'Observed reduction/rebound summary failed'}
    Write-Output 'PASS: post-trim summary preserves signed MiB changes without claiming performance benefit'
    $post.Phase='120s';$post.Status='unavailable';$post.Reason='missed_deadline';$post.ActualElapsedSeconds=150;$post.Snapshot=$null
    $post.Changes['target.working_set_delta_from_before_bytes']=$null;$post.Changes['target.working_set_rebound_from_after_bytes']=$null
    $post|ConvertTo-Json -Depth 8 -Compress|Add-Content -LiteralPath (Join-Path $DataDirectory 'post-trim.jsonl') -Encoding UTF8
    Export-GadgetLogs $csv
    $records=@(Import-Csv -LiteralPath $csv|Where-Object Action -like 'post_trim/*')
    if($records.Count -ne 2 -or $records[0].AvailableMB -ne 4000 -or $records[1].Detail -notlike '*missed_deadline*欠測*'){throw 'Post-trim viewer/CSV missing or incorrect'}
    Write-Output 'PASS: log viewer and CSV include post-trim records and explicit missing reasons'
    1..10|ForEach-Object{Write-GadgetUiError ('test error '+$_) 256}
    Write-GadgetUiError ('x'*1024) 256
    foreach($file in @('ui-errors.log','ui-errors.log.1')){if((Get-Item (Join-Path $DataDirectory $file)).Length -gt 256){throw 'UI error retention exceeded limit'}}
    if((Get-Content (Join-Path $DataDirectory 'ui-errors.log') -Raw) -notlike '*error_message_exceeds_log_capacity*'){throw 'Oversized UI error was not summarized'}
    Write-Output 'PASS: UI error log rotates within byte limits and bounds oversized messages'
    $legacy=Join-Path $DataDirectory 'ui-errors.log'
    [IO.File]::WriteAllText($legacy,('x'*300))
    $refused=$false;try{Write-GadgetUiError 'new error' 256}catch{$refused=$true}
    if(-not $refused -or (Get-Item $legacy).Length -ne 300){throw 'Oversized legacy error log was appended or altered'}
    Write-Output 'PASS: oversized legacy UI errors refuse further growth without reading or rewriting content'
} finally {
    foreach($file in @('events.jsonl','preferences.json','monitor.jsonl','post-trim.jsonl','export.csv','ui-errors.log','ui-errors.log.1')){Remove-Item -LiteralPath (Join-Path $DataDirectory $file) -ErrorAction SilentlyContinue}
    Remove-Item -LiteralPath $DataDirectory
}
