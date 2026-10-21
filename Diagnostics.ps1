function Initialize-Diagnostics {
    if($PSVersionTable.PSEdition -ne 'Desktop'){throw 'Diagnostics require Windows PowerShell 5.1 (powershell.exe), not pwsh.exe'}
    if(-not ('RamNeko.Diagnostics.DiagnosticEngine' -as [type])){
        Add-Type -Path "$PSScriptRoot\DiagnosticsEngine.cs" -ReferencedAssemblies System,System.Web.Extensions,System.Core -ErrorAction Stop
    }
}
function Start-Diagnostics([string]$Directory,[int]$IntervalSeconds=60){
    Initialize-Diagnostics
    New-Object RamNeko.Diagnostics.DiagnosticEngine($Directory,$IntervalSeconds)
}
function Get-DiagnosticsConfiguration {
    $config=Get-Content -LiteralPath "$PSScriptRoot\diagnostics.json" -Raw|ConvertFrom-Json
    Test-DiagnosticsConfiguration $config
}
function Test-DiagnosticsConfiguration($config){
    if($config.Version -ne 1 -or $config.ObservationOnly -isnot [bool] -or $config.ObservationOnly -ne $true -or $config.Enabled -isnot [bool] -or
        $config.IntervalSeconds -isnot [ValueType] -or $config.IntervalSeconds -ne [math]::Truncate([double]$config.IntervalSeconds) -or
        $config.IntervalSeconds -lt 30 -or $config.IntervalSeconds -gt 3600){throw 'Invalid observation-only diagnostics configuration'}
    $config
}
function Get-DiagnosticsSnapshot($Engine){
    if(-not $Engine){return $null}
    $json=$Engine.LatestJson
    if($json){$json|ConvertFrom-Json}
}
