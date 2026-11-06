# Fresh-profile package checks; preserve the installed Meteor and registrations.
$ErrorActionPreference='Stop'
$exe=Join-Path $env:LOCALAPPDATA 'Programs\Nightfall Meteor\nightfall-meteor.exe'
$processes=@(Get-Process nightfall-meteor -ErrorAction SilentlyContinue)
if($processes.Count -gt 1 -or ($processes.Count -eq 1 -and $processes[0].Path -ine $exe)){throw 'Unexpected Meteor process; preserved it'}
$restart=$processes.Count -eq 1
if($restart){& (Join-Path $PSScriptRoot 'stop_windows_meteor.ps1') -ExpectedProcessId $processes[0].Id | Out-Null}
try {
    & (Join-Path $PSScriptRoot 'smoke_windows_packaged_setup.ps1')
    if($LASTEXITCODE){throw 'Fresh-profile package setup failed'}
    & (Join-Path $PSScriptRoot 'smoke_windows_packaged_host.ps1')
    if($LASTEXITCODE){throw 'Fresh-profile host startup failed'}
} finally {if($restart){Start-Process $exe | Out-Null}}
