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
} finally {
    foreach($file in @('events.jsonl','preferences.json','monitor.jsonl','export.csv')){Remove-Item -LiteralPath (Join-Path $DataDirectory $file) -ErrorAction SilentlyContinue}
    Remove-Item -LiteralPath $DataDirectory
}
