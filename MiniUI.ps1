param([switch]$SmokeTest,[ValidateRange(0,300)][int]$ProfileSeconds=0)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
. "$PSScriptRoot\PixelTheme.ps1"
$script:uiRoot = $PSScriptRoot
$profileMode=$ProfileSeconds -gt 0
if($profileMode -and ($SmokeTest -or $ProfileSeconds -lt 10)){throw 'Profile requires 10..300 seconds and cannot combine with SmokeTest'}
. "$PSScriptRoot\MemoryWatch.ps1" -LibraryOnly -ObserveOnly:$profileMode
. "$PSScriptRoot\GadgetSupport.ps1"
if ($SmokeTest) { $DataDirectory = Join-Path $PSScriptRoot 'ui-smoke-data' }
if($profileMode){$DataDirectory=Join-Path $PSScriptRoot ('profile-ui-data-'+[guid]::NewGuid().ToString('N'))}
New-Item -ItemType Directory -Path $DataDirectory -Force | Out-Null
$mutexName = if ($SmokeTest) { 'Local\MemoryWatch-MiniUI-Smoke' } elseif($profileMode){'Local\MemoryWatch-MiniUI-Profile-'+[guid]::NewGuid().ToString('N')} else { 'Local\MemoryWatch-MiniUI' }
$mutex = New-Object Threading.Mutex($false, $mutexName)
$ownsMutex = $false
try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
if (-not $ownsMutex) { $mutex.Dispose(); exit 0 }
$script:paused = $false
$script:exitRequested = $false
$script:protectedName = ''
$script:lastMonitor = [datetime]::MinValue
$script:lastResult = '候補を確認中（低CPU状態を60秒計測）'
$script:chart = $null
$script:preferences=if($SmokeTest -or $profileMode){[pscustomobject]@{Palette='Lavender';WindowMode='Normal';X=$null;Y=$null}}else{Read-GadgetPreferences}
$script:palette=$script:gadgetPalettes[$script:preferences.Palette]
$script:restoringPreferences=$true
$script:logForm=$null
$script:settingsForm=$null
$script:settingsPalette=$null
$script:settingsAppearance=$null
$script:diagnosticsText=$null
$script:diagnosticEngine=$null
$script:postTrimEngine=$null
$script:diagnosticSnapshot=$null
$script:postTrimSummary=$null
$script:lastPostTrimJson=$null
$script:profileTimer=$null
$script:profileResult=$null
$script:lastDiagnosticJson=$null
$script:lastHeartbeat=[datetime]::MinValue
$script:heartbeatWrites=0
$form = New-Object NekoGadgetForm
$form.Text = 'RAM'
$form.ClientSize = New-Object Drawing.Size(328,328)
$form.Font = New-Object Drawing.Font('MS Gothic',9)
$form.FormBorderStyle = 'None'
$form.ShowInTaskbar = $false
if($profileMode){$form.Opacity=0}
$form.MaximizeBox = $false
$form.StartPosition = 'Manual'
$area = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location = New-Object Drawing.Point(($area.Right - $form.Width - 16),($area.Bottom - $form.Height - 16))
if($null -ne $script:preferences.X){
    $saved=New-Object Drawing.Point($script:preferences.X,$script:preferences.Y)
    $screen=[Windows.Forms.Screen]::FromPoint($saved).WorkingArea
    $form.Location=New-Object Drawing.Point(([math]::Max($screen.Left,[math]::Min($saved.X,$screen.Right-$form.Width))),([math]::Max($screen.Top,[math]::Min($saved.Y,$screen.Bottom-$form.Height))))
}
$form.BackColor = [Drawing.ColorTranslator]::FromHtml('#F4E8FA')
$form.ForeColor = [Drawing.ColorTranslator]::FromHtml('#48364F')
$form.Add_Paint({ param($sender,$e)
    $e.Graphics.Clear($sender.BackColor)
    [Windows.Forms.ControlPaint]::DrawBorder3D($e.Graphics,$sender.ClientRectangle,[Windows.Forms.Border3DStyle]::Raised)
    $inset=New-Object Drawing.Rectangle(7,60,314,149)
    [Windows.Forms.ControlPaint]::DrawBorder3D($e.Graphics,$inset,[Windows.Forms.Border3DStyle]::Sunken)
})
$catBitmap=New-NekoBitmap 3
$catIcon=New-NekoIcon
$form.Icon=$catIcon
$cat=New-Object Windows.Forms.PictureBox
$cat.Image=$catBitmap
$cat.Location=New-Object Drawing.Point(12,8)
$cat.Size=New-Object Drawing.Size(48,48)
$form.Controls.Add($cat)
$title=New-Object Windows.Forms.Label
$title.Text='RAM / NEKO'
$title.Font=New-Object Drawing.Font('Consolas',13,[Drawing.FontStyle]::Bold)
$title.Location=New-Object Drawing.Point(68,13)
$title.Size=New-Object Drawing.Size(210,23)
$form.Controls.Add($title)
$subtitle=New-Object Windows.Forms.Label
$subtitle.Text='MEMORY WATCH  /  meow!'
$subtitle.Font=New-Object Drawing.Font('Consolas',8)
$subtitle.Location=New-Object Drawing.Point(70,37)
$subtitle.Size=New-Object Drawing.Size(211,15)
$form.Controls.Add($subtitle)
$closeButton=New-Object NekoGadgetButton
$closeButton.Text='x'
$closeButton.Location=New-Object Drawing.Point(294,10)
$closeButton.Size=New-Object Drawing.Size(24,24)
Set-PixelButton $closeButton
$form.Controls.Add($closeButton)
foreach($dragSurface in @($form,$title,$subtitle,$cat)){
    $dragSurface.Add_MouseDown({param($sender,$eventArgs)
        if($eventArgs.Button -eq [Windows.Forms.MouseButtons]::Left -and $script:preferences.WindowMode -ne 'Desktop'){
            [void][NekoWindow]::ReleaseCapture();[void][NekoWindow]::SendMessage($form.Handle,0xA1,[IntPtr]2,[IntPtr]::Zero)
            Save-GadgetSettings
        }
    })
}
$label = New-Object Windows.Forms.Label
$label.Location = New-Object Drawing.Point(12,65)
$label.Size = New-Object Drawing.Size(304,20)
$form.Controls.Add($label)
$candidateLabel = New-Object Windows.Forms.Label
$candidateLabel.Location = New-Object Drawing.Point(12,109)
$candidateLabel.Size = New-Object Drawing.Size(304,20)
$form.Controls.Add($candidateLabel)
$note = New-Object Windows.Forms.Label
$note.Location = New-Object Drawing.Point(12,151)
$note.Size = New-Object Drawing.Size(304,18)
$note.Font = New-Object Drawing.Font('MS Gothic',8)
$note.Text = '候補量 ≠ 実際に解放できる量（共有分を含む）'
$form.Controls.Add($note)
$statusLabel = New-Object Windows.Forms.Label
$statusLabel.Location = New-Object Drawing.Point(12,173)
$statusLabel.Size = New-Object Drawing.Size(304,33)
$form.Controls.Add($statusLabel)
function New-MiniBar([int]$Y,[Drawing.Color]$Color) {
    $back = New-Object Windows.Forms.Panel
    $back.Location = New-Object Drawing.Point(12,$Y)
    $back.Size = New-Object Drawing.Size(300,12)
    $back.BackColor = [Drawing.ColorTranslator]::FromHtml('#DFD0E9')
    $fill = New-Object Windows.Forms.Panel
    $fill.BackColor = $Color
    $fill.Size = New-Object Drawing.Size(0,12)
    $fill.Add_Paint({param($sender,$e)
        $brush=New-Object Drawing.SolidBrush([Drawing.ColorTranslator]::FromHtml($script:palette.Track))
        try{for($x=8;$x -lt $sender.Width;$x+=10){$e.Graphics.FillRectangle($brush,$x,0,2,12)}}finally{$brush.Dispose()}
    })
    $back.Controls.Add($fill); $form.Controls.Add($back)
    $fill
}
$usageBar = New-MiniBar 89 ([Drawing.ColorTranslator]::FromHtml('#A588C5'))
$candidateBar = New-MiniBar 133 ([Drawing.ColorTranslator]::FromHtml('#DDA56C'))
$pauseButton = New-Object NekoGadgetButton
$pauseButton.Text = '一時停止'
$pauseButton.Location = New-Object Drawing.Point(100,215)
$pauseButton.Size = New-Object Drawing.Size(70,27)
$form.Controls.Add($pauseButton)
$hideButton = New-Object NekoGadgetButton
$hideButton.Text = '隠す'
$hideButton.Location = New-Object Drawing.Point(174,215)
$hideButton.Size = New-Object Drawing.Size(60,27)
$form.Controls.Add($hideButton)
$cleanButton = New-Object NekoGadgetButton
$cleanButton.Text = '手動整理'
$cleanButton.Location = New-Object Drawing.Point(12,215)
$cleanButton.Size = New-Object Drawing.Size(83,27)
$form.Controls.Add($cleanButton)
$rulesButton = New-Object NekoGadgetButton
$rulesButton.Text = '基準'
$rulesButton.Location = New-Object Drawing.Point(238,215)
$rulesButton.Size = New-Object Drawing.Size(66,27)
$form.Controls.Add($rulesButton)
foreach($button in @($cleanButton,$pauseButton,$hideButton,$rulesButton)){Set-PixelButton $button}
$desktopButton=New-Object NekoGadgetButton
$desktopButton.Text='デスクトップに固定'
$desktopButton.Location=New-Object Drawing.Point(12,248)
$desktopButton.Size=New-Object Drawing.Size(148,29)
$form.Controls.Add($desktopButton)
$topButton=New-Object NekoGadgetButton
$topButton.Text='前面に固定'
$topButton.Location=New-Object Drawing.Point(166,248)
$topButton.Size=New-Object Drawing.Size(148,29)
$form.Controls.Add($topButton)
$settingsButton=New-Object NekoGadgetButton
$settingsButton.Text='設定'
$settingsButton.Location=New-Object Drawing.Point(12,285)
$settingsButton.Size=New-Object Drawing.Size(96,29)
$settingsBitmap=New-SettingsBitmap
$settingsButton.Image=$settingsBitmap
$form.Controls.Add($settingsButton)
$diagnosticLabel=New-Object Windows.Forms.Label
$diagnosticLabel.Text='診断: 準備中'
$diagnosticLabel.Location=New-Object Drawing.Point(118,293)
$diagnosticLabel.Size=New-Object Drawing.Size(116,18)
$form.Controls.Add($diagnosticLabel)
$logsButton=New-Object NekoGadgetButton
$logsButton.Text='ログ'
$logsButton.Location=New-Object Drawing.Point(238,285)
$logsButton.Size=New-Object Drawing.Size(76,29)
$form.Controls.Add($logsButton)
$tooltip = New-Object Windows.Forms.ToolTip
$tooltip.SetToolTip($candidateLabel,'最大3件の候補のワーキングセット合計 / 物理RAM。共有ページを重複計上する場合があり、解放保証値ではありません。')
$tooltip.SetToolTip($desktopButton,'位置をロックして他のアプリの背面に表示。Windows+Dによる非表示を防ぐ壁紙埋込みではありません。')
$tooltip.SetToolTip($topButton,'他の通常ウインドウより前面に表示。もう一度押すと解除。')
$tray = New-Object Windows.Forms.NotifyIcon
$tray.Icon = $catIcon
$tray.Text = 'RAM / NEKO'
$tray.Visible = -not ($SmokeTest -or $profileMode)
$menu = New-Object Windows.Forms.ContextMenuStrip
$menu.Font=$form.Font
$menu.BackColor=$form.BackColor
$menu.ForeColor=$form.ForeColor
$showItem = $menu.Items.Add('ネコパネルを表示')
$pauseItem = $menu.Items.Add('一時停止')
$exitItem = $menu.Items.Add('監視を終了')
$tray.ContextMenuStrip = $menu
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 5000

function Save-GadgetSettings {
    if($script:restoringPreferences){return}
    if(-not $SmokeTest){$script:preferences.X=$form.Left;$script:preferences.Y=$form.Top}
    Write-GadgetPreferences $script:preferences
}
function Apply-GadgetPalette([string]$Key) {
    if(-not $script:gadgetPalettes.Contains($Key)){throw 'Unknown palette'}
    $script:preferences.Palette=$Key
    $script:palette=$script:gadgetPalettes[$Key]
    $form.BackColor=[Drawing.ColorTranslator]::FromHtml($script:palette.Body)
    $form.ForeColor=[Drawing.ColorTranslator]::FromHtml($script:palette.Text)
    foreach($control in $form.Controls){
        if($control -is [NekoGadgetButton]){
            $control.BackColor=[Drawing.ColorTranslator]::FromHtml($script:palette.Face)
            $control.ForeColor=$form.ForeColor
        }
    }
    $usageBar.BackColor=[Drawing.ColorTranslator]::FromHtml($script:palette.Usage)
    $candidateBar.BackColor=[Drawing.ColorTranslator]::FromHtml($script:palette.Candidate)
    foreach($bar in @($usageBar,$candidateBar)){$bar.Parent.BackColor=[Drawing.ColorTranslator]::FromHtml($script:palette.Track);$bar.Invalidate()}
    $menu.BackColor=$form.BackColor;$menu.ForeColor=$form.ForeColor
    if($script:settingsForm -and -not $script:settingsForm.IsDisposed){
        $script:settingsForm.BackColor=$form.BackColor;$script:settingsForm.ForeColor=$form.ForeColor
        $script:settingsPalette.BackColor=[Drawing.ColorTranslator]::FromHtml($script:palette.Face);$script:settingsPalette.ForeColor=$form.ForeColor
        $script:settingsAppearance.BackColor=$form.BackColor;$script:settingsAppearance.ForeColor=$form.ForeColor
        $script:diagnosticsText.BackColor=[Drawing.ColorTranslator]::FromHtml($script:palette.Face);$script:diagnosticsText.ForeColor=$form.ForeColor
    }
    $form.Invalidate($true)
    if(-not $script:restoringPreferences){Write-GadgetEvent 'palette_changed' $Key;Save-GadgetSettings}
}
function Apply-GadgetWindowMode([string]$Mode) {
    if($Mode -notin @('Normal','Desktop','Topmost')){throw 'Unknown window mode'}
    $script:preferences.WindowMode=$Mode
    $form.DesktopPinned=($Mode -eq 'Desktop')
    $form.TopMost=($Mode -eq 'Topmost')
    $desktopButton.Latched=($Mode -eq 'Desktop');$topButton.Latched=($Mode -eq 'Topmost')
    if($form.IsHandleCreated -and $Mode -eq 'Desktop'){$form.SetDesktopLayer()}
    if(-not $script:restoringPreferences){Write-GadgetEvent 'window_mode' $Mode;Save-GadgetSettings}
}
function Show-GadgetPanel {
    $form.Show()
    Update-MiniStatus
    Apply-GadgetWindowMode $script:preferences.WindowMode
    if($script:preferences.WindowMode -ne 'Desktop'){$form.Activate()}
    Write-GadgetEvent 'panel_shown'
}
function Hide-GadgetPanel { Save-GadgetSettings; $form.Hide(); Write-GadgetEvent 'panel_hidden' }
function Show-GadgetSettings {
    if($script:settingsForm -and -not $script:settingsForm.IsDisposed){$script:settingsForm.Activate();return}
    $script:settingsForm=New-Object Windows.Forms.Form
    $script:settingsForm.Text='RAM / NEKO - 設定'
    $script:settingsForm.ClientSize=New-Object Drawing.Size(450,300)
    $script:settingsForm.Font=$form.Font;$script:settingsForm.BackColor=$form.BackColor;$script:settingsForm.ForeColor=$form.ForeColor
    $script:settingsForm.TopMost=$form.TopMost
    $tabs=New-Object Windows.Forms.TabControl
    $tabs.Dock='Fill'
    $appearance=New-Object Windows.Forms.TabPage
    $appearance.Text='配色'
    $appearance.BackColor=$form.BackColor
    $script:settingsAppearance=$appearance
    $label=New-Object Windows.Forms.Label
    $label.Text='配色（選択すると保存されます）';$label.Location=New-Object Drawing.Point(16,20);$label.Size=New-Object Drawing.Size(380,20)
    $script:settingsPalette=New-Object Windows.Forms.ComboBox
    $script:settingsPalette.DropDownStyle='DropDownList';$script:settingsPalette.Location=New-Object Drawing.Point(16,50);$script:settingsPalette.Width=240
    foreach($key in $script:gadgetPalettes.Keys){[void]$script:settingsPalette.Items.Add($script:gadgetPalettes[$key].Name)}
    $script:settingsPalette.SelectedIndex=@($script:gadgetPalettes.Keys).IndexOf($script:preferences.Palette)
    $script:settingsPalette.Add_SelectedIndexChanged({Apply-GadgetPalette @($script:gadgetPalettes.Keys)[$script:settingsPalette.SelectedIndex]})
    $appearance.Controls.Add($label);$appearance.Controls.Add($script:settingsPalette)
    $diagnostics=New-Object Windows.Forms.TabPage
    $diagnostics.Text='診断（観測専用）'
    $script:diagnosticsText=New-Object Windows.Forms.TextBox
    $script:diagnosticsText.Multiline=$true;$script:diagnosticsText.ReadOnly=$true;$script:diagnosticsText.WordWrap=$false;$script:diagnosticsText.ScrollBars='Both';$script:diagnosticsText.Dock='Fill'
    $diagnostics.Controls.Add($script:diagnosticsText)
    $tabs.TabPages.Add($appearance);$tabs.TabPages.Add($diagnostics);$script:settingsForm.Controls.Add($tabs)
    Update-DiagnosticsDisplay
    if($SmokeTest){$script:settingsForm.StartPosition='Manual';$script:settingsForm.Location=New-Object Drawing.Point(-32000,-32000);$script:settingsForm.ShowInTaskbar=$false}
    $script:settingsForm.Show();Write-GadgetEvent 'settings_opened'
}
function Update-DiagnosticsDisplay {
    if($script:diagnosticsText -and -not $script:diagnosticsText.IsDisposed){
        if($script:diagnosticSnapshot){
            $s=$script:diagnosticSnapshot
            $lines=@("M1: 観測専用 / 整理判断には未使用", "UTC: $($s.Utc)", "収集時間: $($s.CollectionDurationMs) ms",'')
            foreach($property in $s.Metrics.PSObject.Properties){$m=$property.Value;$value=if($null -eq $m.Value){'欠測'}else{[string]$m.Value};$lines+="$($property.Name): $value $($m.Unit) [$($m.Status)] $($m.Reason)"}
        }else{$lines=@('診断結果は準備中・無効・取得不可です。欠測値は0として扱いません。整理判断は従来どおりです。')}
        if($script:postTrimEngine){$lines+="整理後観測: 待機 $($script:postTrimEngine.Pending) / エラー $($script:postTrimEngine.LastError)"}
        if($script:postTrimSummary){$lines+='';$lines+='最新の整理後観測:';$lines+=$script:postTrimSummary}
        $script:diagnosticsText.Text=$lines -join "`r`n"
    }
}
function Update-PostTrimCache {
    if(-not $script:postTrimEngine){return}
    try{
        $json=$script:postTrimEngine.LatestJson
        if($json -and $json -ne $script:lastPostTrimJson){
            $row=$json|ConvertFrom-Json
            $script:postTrimSummary=Format-PostTrimSummary $row
            $script:lastPostTrimJson=$json
            Update-DiagnosticsDisplay
        }
    }catch{$script:postTrimSummary='整理後観測: 取得不可（欠測）';Update-DiagnosticsDisplay}
}
function Update-DiagnosticsCache {
    Update-PostTrimCache
    if(-not $script:diagnosticEngine){return}
    try{
    $json=$script:diagnosticEngine.LatestJson
    if($json -and $json -ne $script:lastDiagnosticJson){
        $script:diagnosticSnapshot=$json|ConvertFrom-Json;$script:lastDiagnosticJson=$json
        if($form.Visible){$diagnosticLabel.Text='診断: 観測専用'}
        Update-DiagnosticsDisplay
    }
    if($script:diagnosticEngine.LastError -and $form.Visible){$diagnosticLabel.Text='診断: 一部欠測'}
    }catch{
        $script:diagnosticSnapshot=$null
        if($form.Visible){$diagnosticLabel.Text='診断: 取得不可'}
    }
}
function Show-GadgetLogs {
    if($script:logForm -and -not $script:logForm.IsDisposed){$script:logForm.Activate();return}
    $script:logForm=New-Object Windows.Forms.Form
    $script:logForm.Text='RAM / NEKO - ログ'
    $script:logForm.ClientSize=New-Object Drawing.Size(660,360)
    $script:logForm.BackColor=$form.BackColor
    $box=New-Object Windows.Forms.TextBox
    $box.Multiline=$true;$box.ReadOnly=$true;$box.WordWrap=$false;$box.ScrollBars='Both'
    $box.Font=New-Object Drawing.Font('MS Gothic',9)
    $box.Location=New-Object Drawing.Point(10,10);$box.Size=New-Object Drawing.Size(640,300)
    $box.Anchor='Top,Bottom,Left,Right';$box.BackColor=[Drawing.ColorTranslator]::FromHtml($script:palette.Face);$box.ForeColor=$form.ForeColor
    $script:logForm.Controls.Add($box)
    $refresh=New-Object NekoGadgetButton
    $refresh.Text='更新';$refresh.Location=New-Object Drawing.Point(10,320);$refresh.Size=New-Object Drawing.Size(86,28)
    $export=New-Object NekoGadgetButton
    $export.Text='CSV保存';$export.Location=New-Object Drawing.Point(104,320);$export.Size=New-Object Drawing.Size(100,28)
    foreach($b in @($refresh,$export)){$b.BackColor=[Drawing.ColorTranslator]::FromHtml($script:palette.Face);$b.ForeColor=$form.ForeColor;$b.Anchor='Bottom,Left';$script:logForm.Controls.Add($b)}
    $render={ $rows=@(Get-GadgetLogRows|Sort-Object Utc);$box.Text=if($rows.Count){($rows|ForEach-Object{"$($_.Utc)  $($_.Action)  free=$($_.AvailableMB)MB  used=$($_.UsedPercent)%  $($_.Detail)"}) -join "`r`n"}else{'まだログがありません。監視は1分ごと、操作時にも記録します。'} }.GetNewClosure()
    $refresh.Add_Click($render)
    $export.Add_Click({
        $dialog=New-Object Windows.Forms.SaveFileDialog
        $dialog.Filter='CSV (*.csv)|*.csv';$dialog.FileName='ram-neko-log-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.csv'
        try{if($dialog.ShowDialog() -eq 'OK'){Export-GadgetLogs $dialog.FileName;Write-GadgetEvent 'log_exported'}}finally{$dialog.Dispose()}
    })
    & $render
    if($SmokeTest){$script:logForm.StartPosition='Manual';$script:logForm.Location=New-Object Drawing.Point(-32000,-32000);$script:logForm.ShowInTaskbar=$false}
    $script:logForm.Show()
    Write-GadgetEvent 'logs_opened'
}

function Update-MiniStatus([switch]$MonitorDue) {
    try {
        Update-DiagnosticsCache
        $foreground = Get-ForegroundProcess
        if ($foreground.Id -ne $PID) { $script:protectedName = $foreground.ProcessName }
        elseif ([MemoryWatchNative]::LastExternalProcessId -ne 0) {
            $script:protectedName = (Get-Process -Id ([MemoryWatchNative]::LastExternalProcessId) -ErrorAction Stop).ProcessName
        }
        if (-not $script:protectedName) { throw 'Foreground unknown; cleanup disabled' }
        if ($MonitorDue -and -not $script:paused) {
            $reference=if($script:diagnosticSnapshot){@{Schema=$script:diagnosticSnapshot.Schema;Version=1;Sequence=$script:diagnosticSnapshot.Sequence;Utc=$script:diagnosticSnapshot.Utc;ObservationOnly=$true}}else{$null}
            $json = Invoke-MemoryWatch -ProtectedName $script:protectedName -DiagnosticsReference $reference -EvaluationObserver $script:postTrimEngine
            $script:lastMonitor = [datetime]::UtcNow
            if ($json) {
                $entry = $json | ConvertFrom-Json
                if ($entry.Action -eq 'trim_attempt') { Set-CleanupSummary $entry }
            }
        }
        $memory = Get-MemorySnapshot
        $candidates = @(Get-TrimCandidates $foreground.ProcessName $foreground.Id $script:protectedName)
        $script:chart = Get-MemoryChartData $memory $candidates
        $mode = if ($script:paused) { '自動整理停止中' } else { '監視中' }
        if($form.Visible -or $SmokeTest){
        $label.Text = ('使用中 {0:N1}%   空き {1:N1} / {2:N1} GB' -f $script:chart.UsedPercent,($memory.AvailableMB/1024),($memory.TotalMB/1024))
        $candidateLabel.Text = ('整理候補 約{0:N1}%  {1:N0} MB / {2}件' -f $script:chart.CandidatePercent,$script:chart.CandidateMB,$script:chart.CandidateCount)
        $usageBar.Width = [int](300*$script:chart.UsedPercent/100)
        $candidateBar.Width = [int](300*$script:chart.CandidatePercent/100)
        $cleanButton.Enabled = $candidates.Count -gt 0
        $statusLabel.Text = "$mode  " + (Get-Date -Format 'HH:mm:ss') + "`n" + $script:lastResult
        $label.ForeColor = if ($script:paused) { [Drawing.Color]::Gray } else { $form.ForeColor }
        }
        $tray.Text = ('RAM free {0:N1} GB - {1}' -f ($memory.AvailableMB/1024),$mode)
        if(([datetime]::UtcNow-$script:lastHeartbeat).TotalSeconds -ge 60){
        @{Pid=$PID; Utc=[datetime]::UtcNow.ToString('o'); Paused=$script:paused; AvailableMB=$memory.AvailableMB;
            IntervalSeconds=60; DisplayIntervalSeconds=5; Chart=$script:chart; ProtectedName=$script:protectedName;
            Theme='8bit-neko';TrayIcon='pixel-cat';TrayVisible=$tray.Visible;Palette=$script:preferences.Palette;WindowMode=$script:preferences.WindowMode} |
            ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $DataDirectory 'ui-status.json') -Encoding UTF8
        $script:lastHeartbeat=[datetime]::UtcNow;$script:heartbeatWrites++
        }
    } catch {
        $failureMessage=$_.Exception.Message
        $cleanButton.Enabled = $false
        $statusLabel.Text = '計測エラー: '+$failureMessage
        try{Write-GadgetUiError $failureMessage;Write-GadgetEvent 'ui_error' $failureMessage}catch{$diagnosticLabel.Text='ログ: 書込み不可'}
    }
}
function Set-CleanupSummary($Entry) {
    $ok = @($Entry.Results | Where-Object Status -eq ok)
    $failed = @($Entry.Results | Where-Object Status -ne ok)
    $change = 0
    foreach ($item in $ok) { $change += $item.AfterMB - $item.BeforeMB }
    $script:lastResult = if (@($Entry.Results).Count -eq 0) { '対象なし（基準や操作状態を再確認）' }
        else { '成功{0} / 拒否等{1}  WS変化 {2:+0;-0;0} MB' -f $ok.Count,$failed.Count,$change }
    Write-GadgetEvent 'cleanup_result' $script:lastResult
}
function Invoke-MiniCleanup {
    $cleanButton.Enabled = $false
    Write-GadgetEvent 'manual_requested'
    try {
        if ($SmokeTest -or $profileMode) { throw 'Observation test cannot trim applications' }
        # Re-read focus tracking on the click, not only on the last display tick.
        $current = Get-ForegroundProcess
        if ($current.Id -ne $PID) { $script:protectedName = $current.ProcessName }
        elseif ([MemoryWatchNative]::LastExternalProcessId -ne 0) {
            $script:protectedName = (Get-Process -Id ([MemoryWatchNative]::LastExternalProcessId) -ErrorAction Stop).ProcessName
        } else { throw 'Previous foreground unknown' }
        $entry = Invoke-MemoryWatch -Manual -ProtectedName $script:protectedName -EvaluationObserver $script:postTrimEngine | ConvertFrom-Json
        Set-CleanupSummary $entry
    } catch { $script:lastResult = '整理保留: '+$_.Exception.Message;Write-GadgetEvent 'manual_deferred' $_.Exception.Message }
    Update-MiniStatus
}
function Switch-MiniPause {
    $script:paused = -not $script:paused
    $pauseButton.Text = if ($script:paused) { '再開' } else { '一時停止' }
    $pauseItem.Text = $pauseButton.Text
    $pauseButton.Latched=$script:paused
    Write-GadgetEvent 'automatic_pause' ([string]$script:paused)
    Update-MiniStatus
}
function Get-UiProfileSnapshot {
    $native=New-Object RamNeko.Safety.WindowsTrimNative
    $handle=$native.OpenReadOnly($PID)
    try{$native.Observe($handle)}finally{$native.Close($handle)}
}
function Start-UiObservationProfile {
    $script:profileBegin=Get-UiProfileSnapshot
    $script:profileTimer=New-Object Windows.Forms.Timer
    $script:profileTimer.Interval=$ProfileSeconds*1000
    $script:profileTimer.Add_Tick({
        $script:profileTimer.Stop()
        try{
            $end=Get-UiProfileSnapshot
            $elapsed=$end.Seconds-$script:profileBegin.Seconds
            $cpu=if($null -ne $end.SelfCpuSeconds -and $null -ne $script:profileBegin.SelfCpuSeconds){$end.SelfCpuSeconds-$script:profileBegin.SelfCpuSeconds}else{$null}
            $entries=@(if(Test-Path (Join-Path $DataDirectory 'monitor.jsonl')){Get-Content (Join-Path $DataDirectory 'monitor.jsonl')|ForEach-Object{$_|ConvertFrom-Json}})
            $script:profileResult=[ordered]@{
                Mode='hidden_observation_only';ObservationOnly=[bool]$ObserveOnly;ElapsedSeconds=$elapsed;CpuSeconds=$cpu
                NormalizedCpuPercent=if($null -ne $cpu){100*$cpu/$elapsed/[Environment]::ProcessorCount}else{$null}
                StartWorkingSetBytes=$script:profileBegin.Bytes['self.working_set_bytes'];EndWorkingSetBytes=$end.Bytes['self.working_set_bytes']
                LogicalReadBytes=$end.Bytes['self.logical_read_bytes_total']-$script:profileBegin.Bytes['self.logical_read_bytes_total']
                LogicalWriteBytes=$end.Bytes['self.logical_write_bytes_total']-$script:profileBegin.Bytes['self.logical_write_bytes_total']
                HeartbeatWrites=$script:heartbeatWrites;DiagnosticWrites=if($script:diagnosticEngine){$script:diagnosticEngine.LogWrites}else{0}
                MonitorSamples=$entries.Count;CleanupAttempts=@($entries|Where-Object Action -in @('trim_attempt','manual_trim')).Count
                DataDirectory=$DataDirectory
            }
        }catch{$script:profileResult=@{Error=$_.Exception.Message;ObservationOnly=[bool]$ObserveOnly;DataDirectory=$DataDirectory}}
        finally{$script:exitRequested=$true;$form.Close()}
    })
    $script:profileTimer.Start()
}
$pauseButton.Add_Click({ Switch-MiniPause })
$cleanButton.Add_Click({ Invoke-MiniCleanup })
$rulesButton.Add_Click({
    $p=$script:trimPolicy
    $rules = "対象: $($p.AllowedNames -join ' / ')、同じセッション。`n操作中・直前に操作したアプリは同名プロセスも除外。`n起動$($p.MinimumAgeSeconds)秒以上、低CPU（1コアの$($p.MaximumCpuCoreFraction*100)%以下）$($p.MinimumIdleSeconds)秒以上。`n$($p.MinimumWorkingSetMB)MB以上、1回最大$($p.MaximumProcesses)件、拒否対象は$($p.DeniedCooldownMinutes)分除外。`n自動: 空き1.5GB未満かつ10%未満が3回連続、$($p.AutomaticCooldownMinutes)分間隔。`n手動: 低メモリ条件を省略、前回から最低$($p.ManualCooldownSeconds)秒。`n候補量は共有分を含み、解放量とは一致しません。`nプロセス終了・ファイル削除はしません。"
    [Windows.Forms.MessageBox]::Show($rules,'整理の基準') | Out-Null
})
$pauseItem.Add_Click({ Switch-MiniPause })
$hideButton.Add_Click({ Hide-GadgetPanel })
$closeButton.Add_Click({ Hide-GadgetPanel })
$showItem.Add_Click({ Show-GadgetPanel })
$tray.Add_DoubleClick({ Show-GadgetPanel })
$desktopButton.Add_Click({$mode=if($script:preferences.WindowMode -eq 'Desktop'){'Normal'}else{'Desktop'};Apply-GadgetWindowMode $mode})
$topButton.Add_Click({$mode=if($script:preferences.WindowMode -eq 'Topmost'){'Normal'}else{'Topmost'};Apply-GadgetWindowMode $mode})
$logsButton.Add_Click({ Show-GadgetLogs })
$settingsButton.Add_Click({Show-GadgetSettings})
$exitItem.Add_Click({ $script:exitRequested = $true; $form.Close() })
$form.Add_FormClosing({
    param($sender,$eventArgs)
    if (-not $script:exitRequested -and -not $SmokeTest) { $eventArgs.Cancel = $true; Hide-GadgetPanel }
})
$timer.Add_Tick({ Update-MiniStatus -MonitorDue:(([datetime]::UtcNow-$script:lastMonitor).TotalSeconds -ge 60);if($form.Visible -and $form.DesktopPinned){$form.SetDesktopLayer()} })
$form.Add_Activated({if($form.DesktopPinned){$form.SetDesktopLayer()}})
$hook = [IntPtr]::Zero
try {
    Initialize-MemoryNative
    Apply-GadgetPalette $script:preferences.Palette
    Apply-GadgetWindowMode $script:preferences.WindowMode
    $script:restoringPreferences=$false
    Write-GadgetEvent 'started'
    if ($SmokeTest) {
        # Isolated observation only: never trim user applications in the UI test.
        $ObserveOnly = $true
        function Get-ForegroundProcess { [pscustomobject]@{Id=123;ProcessName='explorer'} }
        function Get-MemorySnapshot { [pscustomobject]@{AvailableMB=4000;TotalMB=16000} }
        function Get-TrimCandidates { @([pscustomobject]@{WorkingSet64=800MB}) }
        Update-MiniStatus
        if ($script:chart.UsedPercent -ne 75 -or $script:chart.CandidatePercent -ne 5) { throw 'Graph calculation failed' }
        $click = [Windows.Forms.Button].GetMethod('OnClick',[Reflection.BindingFlags]'Instance,NonPublic')
        $click.Invoke($pauseButton,@([EventArgs]::Empty)) | Out-Null
        if (-not $script:paused) { throw 'Pause button failed' }
        $click.Invoke($pauseButton,@([EventArgs]::Empty)) | Out-Null
        if ($script:paused) { throw 'Resume button failed' }
        function Invoke-MemoryWatch { '{"Results":[{"BeforeMB":800,"AfterMB":600,"Status":"ok"}]}' }
        $SmokeTest = $false
        $click.Invoke($cleanButton,@([EventArgs]::Empty)) | Out-Null
        $SmokeTest = $true
        if ($script:lastResult -notlike '*-200 MB*') { throw 'Manual button summary failed' }
        if ($timer.Interval -ne 5000) { throw 'Unexpected display interval' }
        # Render off-screen so the smoke test never flashes a test window.
        $form.ShowInTaskbar = $false
        $form.Location = New-Object Drawing.Point(-32000,-32000)
        $form.Show()
        [Windows.Forms.Application]::DoEvents()
        if($tray.Icon.Width -ne 32 -or $cat.Image.Width -ne 48){throw 'Cat artwork was not installed'}
        $click.Invoke($hideButton,@([EventArgs]::Empty)) | Out-Null
        if($form.Visible){throw 'Hide-to-tray failed'}
        $form.Show()
        $click.Invoke($closeButton,@([EventArgs]::Empty)) | Out-Null
        if($form.Visible){throw 'Custom close-to-tray failed'}
        $showItem.PerformClick()
        if(-not $form.Visible){throw 'Restore-from-tray failed'}
        $click.Invoke($topButton,@([EventArgs]::Empty))|Out-Null
        if(-not $form.TopMost -or -not $form.NativeTopmost -or -not $topButton.Latched){throw 'Topmost mode failed'}
        $click.Invoke($desktopButton,@([EventArgs]::Empty))|Out-Null
        if(-not $form.DesktopPinned -or $form.TopMost -or $form.NativeTopmost -or $topButton.Latched -or -not $desktopButton.Latched){throw 'Desktop mode is not exclusive'}
        $click.Invoke($desktopButton,@([EventArgs]::Empty))|Out-Null
        if($form.DesktopPinned -or $script:preferences.WindowMode -ne 'Normal'){throw 'Pin release failed'}
        $click.Invoke($settingsButton,@([EventArgs]::Empty))|Out-Null
        if(-not $script:settingsForm -or $settingsButton.Image.Width -ne 16){throw 'Settings icon/dialog failed'}
        $script:diagnosticSnapshot=[pscustomobject]@{Utc='2026-01-01T00:00:00Z';CollectionDurationMs=1;Metrics=[pscustomobject]@{sample=[pscustomobject]@{Value=$null;Unit='bytes';Status='unavailable';Reason='test'}}}
        Update-DiagnosticsDisplay
        if($script:diagnosticsText.Text -notlike '*欠測*'){throw 'Diagnostics missing-value display failed'}
        $postFixture=@{Schema='ram-neko.post-trim';Version=1;Utc='2026-01-01T00:00:30Z';Phase='30s';Status='ok';Reason=$null;ActualElapsedSeconds=30;Changes=@{'target.working_set_delta_from_before_bytes'=-150MB;'target.working_set_rebound_from_after_bytes'=50MB}}
        $script:postTrimEngine=[pscustomobject]@{LatestJson=($postFixture|ConvertTo-Json -Depth 8 -Compress);Pending=0;LastError=$null}
        Update-PostTrimCache
        if($script:diagnosticsText.Text -notlike '*+50.0 MB*' -or $script:diagnosticsText.Text -notlike '*未判定*'){throw 'Post-trim diagnostic display failed'}
        $script:postTrimEngine.LatestJson='invalid';Update-PostTrimCache
        if($script:diagnosticsText.Text -notlike '*取得不可*'){throw 'Post-trim invalid cache isolation failed'}
        $script:postTrimEngine=$null;$script:postTrimSummary=$null;$script:lastPostTrimJson=$null
        $script:diagnosticSnapshot=$null
        $script:settingsPalette.SelectedIndex=1
        if($script:preferences.Palette -ne 'Mint' -or $form.BackColor.ToArgb() -ne [Drawing.ColorTranslator]::FromHtml($script:gadgetPalettes.Mint.Body).ToArgb()){throw 'Palette selection failed'}
        $saved=Read-GadgetPreferences
        if($saved.Palette -ne 'Mint' -or $saved.WindowMode -ne 'Normal'){throw 'Preferences persistence failed'}
        $click.Invoke($logsButton,@([EventArgs]::Empty))|Out-Null
        if(-not $script:logForm -or $script:logForm.Controls[0].Text -notlike '*palette_changed*'){throw 'Log viewer failed'}
        $csv=Join-Path $DataDirectory 'smoke-export.csv'
        Export-GadgetLogs $csv
        $rows=@(Import-Csv -LiteralPath $csv)
        if(-not @($rows|Where-Object Action -eq window_mode).Count){throw 'CSV log export failed'}
        $script:logForm.Hide()
        $script:settingsPalette.SelectedIndex=0
        $settingsImage=New-Object Drawing.Bitmap($script:settingsForm.Width,$script:settingsForm.Height)
        try{$script:settingsForm.DrawToBitmap($settingsImage,(New-Object Drawing.Rectangle(0,0,$script:settingsForm.Width,$script:settingsForm.Height)));$settingsImage.Save((Join-Path $PSScriptRoot 'settings-preview.png'))}finally{$settingsImage.Dispose()}
        $script:settingsForm.Hide()
        if($script:heartbeatWrites -ne 1){throw 'Heartbeat was not throttled'}
        $previousData=$DataDirectory;$previousHeartbeat=$script:lastHeartbeat
        $blockedPath=Join-Path $DataDirectory 'write-blocked'
        'x'|Set-Content -LiteralPath $blockedPath
        try{
            $DataDirectory=$blockedPath;$script:lastHeartbeat=[datetime]::MinValue
            Update-MiniStatus
            if($cleanButton.Enabled -or $diagnosticLabel.Text -notlike '*書込み不可*'){throw 'UI write failure was not isolated'}
        }finally{$DataDirectory=$previousData;$script:lastHeartbeat=$previousHeartbeat;Remove-Item -LiteralPath $blockedPath}
        Update-MiniStatus
        $script:diagnosticEngine=[pscustomobject]@{LatestJson='invalid-json';LastError=$null}
        Update-DiagnosticsCache
        if($script:diagnosticSnapshot){throw 'Invalid diagnostics escaped isolation'}
        $script:diagnosticEngine=$null
        $diagnosticLabel.Text='診断: 観測専用'
        $bitmap = New-Object Drawing.Bitmap($form.Width,$form.Height)
        try { $form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height))); $bitmap.Save((Join-Path $PSScriptRoot 'mini-ui-preview.png')) }
        finally { $bitmap.Dispose() }
        $form.Hide()
        Write-Output 'PASS: RAM graphs, candidate labels, Pause/Resume, manual button result, off-screen render'
        Write-Output 'PASS: pixel cat artwork, custom hide/close-to-tray, restore menu, no taskbar button'
        Write-Output 'PASS: native topmost and desktop mode exclusivity, pin release, palette persistence, log viewer and CSV export'
        Write-Output 'PASS: pixel settings icon, palette in settings dialog, heartbeat write throttling'
        Write-Output 'PASS: post-trim cache display, missing-data isolation, and UI write failure protection'
    } else {
        try{
            $config=Get-DiagnosticsConfiguration
            if($config.Enabled){
                $script:diagnosticEngine=Start-Diagnostics $DataDirectory $config.IntervalSeconds
                try{
                    $getter=$script:diagnosticEngine.GetType().GetProperty('LatestJson').GetGetMethod()
                    $context=[Delegate]::CreateDelegate([Func[string]],$script:diagnosticEngine,$getter)
                    $script:postTrimEngine=New-Object RamNeko.Safety.PostTrimEngine($DataDirectory,$context)
                }catch{Write-GadgetEvent 'post_trim_observer_unavailable' $_.Exception.Message}
            }else{$diagnosticLabel.Text='診断: 無効'}
        }catch{Write-GadgetEvent 'diagnostics_unavailable' $_.Exception.Message;$diagnosticLabel.Text='診断: 取得不可'}
        $hook = [MemoryWatchNative]::StartForegroundTracking($PID)
        if ($hook -eq [IntPtr]::Zero) { throw 'Foreground tracking unavailable' }
        $form.Add_Shown({
            if($profileMode){$form.Hide()}
            Apply-GadgetWindowMode $script:preferences.WindowMode;Update-MiniStatus -MonitorDue;$timer.Start()
            if($profileMode){Start-UiObservationProfile}
        })
        [Windows.Forms.Application]::Run($form)
    }
} finally {
    if($script:profileTimer){$script:profileTimer.Stop();$script:profileTimer.Dispose()}
    if($script:postTrimEngine){$script:postTrimEngine.Dispose();[void]$script:postTrimEngine.WaitForStop(1000)}
    if($script:diagnosticEngine){$script:diagnosticEngine.Dispose()}
    try{Write-GadgetEvent 'exited'}catch{} # Always release native/UI resources even when logging fails.
    if($script:logForm -and -not $script:logForm.IsDisposed){$script:logForm.Dispose()}
    if($script:settingsForm -and -not $script:settingsForm.IsDisposed){$script:settingsForm.Dispose()}
    if ($hook -ne [IntPtr]::Zero) { [void][MemoryWatchNative]::UnhookWinEvent($hook) }
    $tooltip.Dispose()
    $timer.Stop(); $timer.Dispose(); $tray.Visible = $false; $tray.Dispose(); $menu.Dispose(); $form.Dispose()
    $catBitmap.Dispose(); $catIcon.Dispose()
    $settingsBitmap.Dispose()
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
if($profileMode){$script:profileResult|ConvertTo-Json -Depth 6}
