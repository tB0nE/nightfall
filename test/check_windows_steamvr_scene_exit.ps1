$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
$exe=Join-Path $env:LOCALAPPDATA 'Programs\Nightfall Meteor\nightfall-meteor.exe'
if(Get-Process vrserver,vrcompositor,vrmonitor -ErrorAction SilentlyContinue){throw 'Close SteamVR before the isolated scene-exit check; existing VR processes are preserved'}
$processes=@(Get-Process nightfall-meteor -ErrorAction SilentlyContinue)
if($processes.Count -ne 1 -or $processes[0].Path -ine $exe){throw 'Unexpected installed Meteor process; preserved it'}
& (Join-Path $PSScriptRoot 'stop_windows_meteor.ps1') -ExpectedProcessId $processes[0].Id | Out-Null
try {
    & (Join-Path $PSScriptRoot 'check_windows_steamvr_integration.ps1') -ExternalCapture -BuildApp
    if($LASTEXITCODE){throw 'Scene-exit capture check failed'}
} finally {Start-Process $exe | Out-Null}
