$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
$checks=Get-Content (Join-Path $repo 'meteor\target\windows-steamvr-integration\summary.json') -Raw | ConvertFrom-Json
if(-not $checks.ok -or 'release-app' -notin $checks.checks){throw 'BuildApp integration checks must pass first'}
$installed=Join-Path $env:LOCALAPPDATA 'Programs\Nightfall Meteor'
$exe=Join-Path $installed 'nightfall-meteor.exe'
$driver=Join-Path $installed 'runtime\xr\steamvr\bin\win64\driver_meteor.dll'
$out=Join-Path $repo 'meteor\target\windows-steamvr-release'
$backup=Join-Path $out ('before-handoff-fix-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
$summary=[ordered]@{ok=$false;headset_modified=$false}
try {
    # Request normal closure of the failed SteamVR session; never force-kill it.
    foreach($monitor in @(Get-Process vrmonitor -ErrorAction SilentlyContinue)){[void]$monitor.CloseMainWindow()}
    $deadline=[DateTime]::UtcNow.AddSeconds(15)
    while((Get-Process vrserver,vrcompositor -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 100}
    if(Get-Process vrserver,vrcompositor -ErrorAction SilentlyContinue){throw 'SteamVR did not close normally; installed files are unchanged'}
    New-Item -ItemType Directory -Force $backup | Out-Null
    Copy-Item -LiteralPath $exe,$driver -Destination $backup
    $processes=@(Get-Process nightfall-meteor -ErrorAction SilentlyContinue)
    if($processes.Count) {
        if($processes.Count -ne 1 -or $processes[0].Path -ine $exe){throw 'Another Meteor executable is running; preserved it'}
        & (Join-Path $PSScriptRoot 'stop_windows_meteor.ps1') -ExpectedProcessId $processes[0].Id | Out-Null
    }
    Copy-Item -LiteralPath (Join-Path $repo 'meteor\target\release\nightfall-meteor.exe') -Destination $exe -Force
    Copy-Item -LiteralPath (Join-Path $repo 'meteor\target\windows-steamvr-build\meteor\bin\win64\driver_meteor.dll') -Destination $driver -Force
    $summary.rollback=$backup
    $summary.meteor_pid=(Start-Process $exe -PassThru).Id
    $summary.ok=$true
} catch {$summary.error=$_.Exception.Message}
$summary | ConvertTo-Json | Set-Content (Join-Path $out 'handoff-fix-install-summary.json') -Encoding UTF8
$summary | ConvertTo-Json
if(-not $summary.ok){exit 1}
