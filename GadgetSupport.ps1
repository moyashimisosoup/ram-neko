$script:gadgetPalettes=[ordered]@{
    Lavender=@{Name='ラベンダー';Body='#E8DAF2';Face='#F6EBFA';Text='#48364F';Track='#CCBADB';Usage='#A588C5';Candidate='#DDA56C'}
    Mint=@{Name='ミント';Body='#CEE5DA';Face='#EAF6EE';Text='#2F5146';Track='#B2CDBD';Usage='#67A68C';Candidate='#D5A06A'}
    Peach=@{Name='ピーチ';Body='#F0D4CD';Face='#FFF0E7';Text='#68443E';Track='#DDB9AE';Usage='#C88884';Candidate='#CAA357'}
    Sky=@{Name='スカイ';Body='#D0E1EF';Face='#EEF6FC';Text='#354B66';Track='#B3CADF';Usage='#769FC7';Candidate='#D5A577'}
    Midnight=@{Name='ナイト';Body='#414658';Face='#5B6276';Text='#FFF4E4';Track='#303546';Usage='#A5B9D5';Candidate='#E0B18A'}
}
function Read-GadgetPreferences {
    $value=[pscustomobject]@{Palette='Lavender';WindowMode='Normal';X=$null;Y=$null}
    $path=Join-Path $DataDirectory 'preferences.json'
    if(Test-Path -LiteralPath $path){
        try {
            $saved=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            if($script:gadgetPalettes.Contains($saved.Palette)){$value.Palette=$saved.Palette}
            if($saved.WindowMode -in @('Normal','Desktop','Topmost')){$value.WindowMode=$saved.WindowMode}
            if($null -ne $saved.X -and $null -ne $saved.Y){$value.X=[int]$saved.X;$value.Y=[int]$saved.Y}
        } catch { Write-GadgetEvent 'settings_invalid' $_.Exception.Message }
    }
    $value
}
function Write-GadgetPreferences($Value) {
    $path=Join-Path $DataDirectory 'preferences.json'
    $Value | ConvertTo-Json | Set-Content -LiteralPath "$path.tmp" -Encoding UTF8
    Move-Item -LiteralPath "$path.tmp" -Destination $path -Force
}
function Write-GadgetEvent([string]$Action,[string]$Detail='') {
    $path=Join-Path $DataDirectory 'events.jsonl'
    if((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -ge 5MB){Move-Item -LiteralPath $path -Destination "$path.1" -Force}
    @{Utc=[datetime]::UtcNow.ToString('o');Action=$Action;Detail=$Detail} | ConvertTo-Json -Compress |
        Add-Content -LiteralPath $path -Encoding UTF8
}
function Write-GadgetUiError([string]$Message,[long]$Limit=5242880) {
    $path=Join-Path $DataDirectory 'ui-errors.log'
    $encoding=New-Object Text.UTF8Encoding($false)
    $line=[datetime]::UtcNow.ToString('o')+' '+$Message+[Environment]::NewLine
    if((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt $Limit){throw 'Legacy UI error log exceeds capacity; archive it before resuming this log'}
    if($encoding.GetByteCount($line) -gt $Limit){$line=[datetime]::UtcNow.ToString('o')+' error_message_exceeds_log_capacity'+[Environment]::NewLine}
    if($encoding.GetByteCount($line) -gt $Limit){throw 'UI error log limit too small'}
    if((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path).Length+$encoding.GetByteCount($line)) -gt $Limit){Move-Item -LiteralPath $path -Destination "$path.1" -Force}
    [IO.File]::AppendAllText($path,$line,$encoding)
}
function Format-PostTrimSummary($Row) {
    if($Row.Schema -ne 'ram-neko.post-trim' -or $Row.Version -ne 1 -or $Row.Phase -notin @('before','after','30s','120s')){throw 'Invalid post-trim record'}
    $change=if($null -eq $Row.Changes.'target.working_set_delta_from_before_bytes'){'欠測'}else{('{0:+0.0;-0.0;0.0} MB' -f ([double]$Row.Changes.'target.working_set_delta_from_before_bytes'/1MB))}
    $rebound=if($null -eq $Row.Changes.'target.working_set_rebound_from_after_bytes'){'欠測'}else{('{0:+0.0;-0.0;0.0} MB' -f ([double]$Row.Changes.'target.working_set_rebound_from_after_bytes'/1MB))}
    $target=if($Row.PSObject.Properties['Identity'] -and $Row.Identity){"$($Row.Identity.Name) PID $($Row.Identity.Id)"}else{'対象不明'}
    "$target / $($Row.Phase) [$($Row.Status)] $($Row.Reason) / WS差 $change / 再増加 $rebound / $([math]::Round([double]$Row.ActualElapsedSeconds,1)) 秒 / 性能改善は未判定"
}
function Get-GadgetLogRows([int]$Tail=300) {
    foreach($name in @('monitor.jsonl.1','monitor.jsonl','events.jsonl.1','events.jsonl','post-trim.jsonl.1','post-trim.jsonl')){
        $path=Join-Path $DataDirectory $name
        if(-not (Test-Path -LiteralPath $path)){continue}
        $content=if($Tail -gt 0){Get-Content -LiteralPath $path -Tail $Tail -Encoding UTF8}else{Get-Content -LiteralPath $path -Encoding UTF8}
        foreach($line in @($content)){
            try {
                $row=$line|ConvertFrom-Json
                $available='';$used='';$detail=''
                if($row.PSObject.Properties['AvailableMB']){$available=$row.AvailableMB}
                if($row.PSObject.Properties['TotalMB'] -and $row.TotalMB -gt 0){$used=[math]::Round(100*(1-$row.AvailableMB/$row.TotalMB),1)}
                if($row.PSObject.Properties['Detail']){$detail=$row.Detail}
                if($row.PSObject.Properties['Error']){$detail=$row.Error}
                if($row.PSObject.Properties['Results']){$detail=(@($row.Results|ForEach-Object{"$($_.Name): $($_.Status)"}) -join '; ')}
                if($row.PSObject.Properties['DecisionReason']){$detail="$($row.DecisionReason) $detail"}
                $action=if($row.PSObject.Properties['Schema'] -and $row.Schema -eq 'ram-neko.post-trim'){
                    $detail=Format-PostTrimSummary $row
                    if($row.Snapshot -and $null -ne $row.Snapshot.Bytes.'physical.available_bytes'){$available=[math]::Round($row.Snapshot.Bytes.'physical.available_bytes'/1MB)}
                    'post_trim/'+$row.Phase
                }else{$row.Action}
                [pscustomobject]@{Utc=$row.Utc;Action=$action;AvailableMB=$available;UsedPercent=$used;Detail=$detail}
            } catch {
                [pscustomobject]@{Utc='';Action='unreadable_row';AvailableMB='';UsedPercent='';Detail='Malformed log row skipped'}
            }
        }
    }
}
function Export-GadgetLogs([string]$Path) {
    @(Get-GadgetLogRows -Tail 0 | Sort-Object Utc) | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}
