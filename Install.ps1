$ErrorActionPreference = 'Stop'
$name = 'MemoryWatch-PressureOnly'
$existing = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
if ($existing -and -not ($existing.Actions.Arguments -like "*$PSScriptRoot*")) { throw 'Refusing to replace an unrelated task' }
$exe = "$env:SystemRoot\System32\wscript.exe"
$action = New-ScheduledTaskAction -Execute $exe -Argument "//B //Nologo `"$PSScriptRoot\LaunchHidden.vbs`"" -WorkingDirectory $PSScriptRoot
$trigger = New-ScheduledTaskTrigger -AtLogOn -User ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
$principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Hidden launch at login; tiny RAM panel with 60-second internal monitoring timer.' -Force | Select-Object TaskName,State
