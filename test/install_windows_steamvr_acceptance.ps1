param([switch]$Apply)
# Controlled acceptance upgrade. Preserve pairing data and other host processes.
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
$out=Join-Path $repo 'meteor\target\windows-steamvr-release'
$prepared=Get-Content (Join-Path $out 'prepare-summary.json') -Raw | ConvertFrom-Json
if(-not $prepared.ok){throw 'Build and validate the release first'}
$installed=$prepared.installed
$root=Join-Path $env:LOCALAPPDATA 'Nightfall Meteor\xr\windows'
$steam=(Get-ItemProperty 'HKCU:\Software\Valve\Steam' -Name SteamPath).SteamPath
$profile=Join-Path $root 'profiles\438100\xr-windows.json'
$steamvr=(Get-Content -LiteralPath $profile -Raw | ConvertFrom-Json).openvr_runtime
$summary=[ordered]@{ok=$false;applied=$false;headset_used=$false;installed=$installed}
try {
    if((Get-FileHash -LiteralPath $prepared.installer -Algorithm SHA256).Hash -ine $prepared.installer_sha256){throw 'Installer differs from the prepared release'}
    if(Get-Process vrserver,vrcompositor,VRChat,Moss-Win64-Shipping -ErrorAction SilentlyContinue){throw 'Close active VR games and SteamVR before the acceptance upgrade'}
    $summary.installer=$prepared.installer
    $summary.steamvr=$steamvr
    $summary.meteor_running=@(Get-Process nightfall-meteor -ErrorAction SilentlyContinue).Count -gt 0
    $adb=Join-Path $repo 'meteor\target\windows-platform-tools\platform-tools\adb.exe'
    if(Test-Path -LiteralPath $adb){$summary.adb_devices=@(& $adb devices -l | Select-Object -Skip 1 | Where-Object {$_.Trim()})}
    # Preview exact removal of Meteor's VRChat wrapper. Moss keeps xrizer.
    & (Join-Path $PSScriptRoot 'configure_windows_steam_catalog.ps1') -Root $root -Executable (Join-Path $installed 'nightfall-meteor.exe') -SteamRoot $steam -AppIds @('438100') -RemoveMeteorOptions | Out-Null
    $summary.steam_options_preview=$true
    if($Apply) {
        $backup=Join-Path $out ('rollback-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
        New-Item -ItemType Directory -Force $backup | Out-Null
        if($summary.meteor_running) {
            $processes=@(Get-Process nightfall-meteor)
            if($processes.Count -ne 1 -or $processes[0].Path -ine (Join-Path $installed 'nightfall-meteor.exe')){throw 'Another Meteor executable is running; preserved it'}
            & (Join-Path $PSScriptRoot 'stop_windows_meteor.ps1') -ExpectedProcessId $processes[0].Id | Out-Null
        }
        Copy-Item -LiteralPath $installed -Destination (Join-Path $backup 'program') -Recurse
        Copy-Item -LiteralPath (Join-Path $env:APPDATA 'Nightfall Meteor') -Destination (Join-Path $backup 'roaming') -Recurse
        $local=Join-Path $env:LOCALAPPDATA 'Nightfall Meteor'
        $savedLocal=Join-Path $backup 'local';New-Item -ItemType Directory -Force $savedLocal | Out-Null
        Get-ChildItem -LiteralPath $local -File | Copy-Item -Destination $savedLocal
        Copy-Item -LiteralPath $root -Destination (Join-Path $savedLocal 'windows') -Recurse
        $vrpaths=Join-Path $env:LOCALAPPDATA 'openvr\openvrpaths.vrpath'
        if(Test-Path $vrpaths){Copy-Item -LiteralPath $vrpaths -Destination (Join-Path $backup 'openvrpaths.vrpath')}
        $identity=(Get-FileHash (Join-Path $local 'meteor.key')).Hash
        $trust=(Get-FileHash (Join-Path $env:APPDATA 'Nightfall Meteor\xr-trusted-headsets.json')).Hash
        $summary.rollback=$backup
        $arguments=@('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',('/DIR="'+$installed+'"'),'/TASKS=builtinhost,pcvr',('/LOG="'+(Join-Path $out 'install.log')+'"'))
        $installer=Start-Process -FilePath $prepared.installer -ArgumentList $arguments -Wait -PassThru
        if($installer.ExitCode){throw "Installer failed ($($installer.ExitCode)); see install.log"}
        $setup=Get-Content (Join-Path $local 'setup-summary.json') -Raw | ConvertFrom-Json
        if(-not $setup.ok -or -not $setup.pcvr_enabled){throw 'Installed PCVR setup failed'}
        # Pairings and the host identity must survive this upgrade.
        if((Get-FileHash (Join-Path $local 'meteor.key')).Hash -ne $identity -or
           (Get-FileHash (Join-Path $env:APPDATA 'Nightfall Meteor\xr-trusted-headsets.json')).Hash -ne $trust){throw 'Identity/trust data changed unexpectedly; rollback is available'}
        $summary.identity_preserved=$true
        & (Join-Path $installed 'SteamVR-Driver.ps1') -Action Register -AppRoot $installed -SteamVRRoot $steamvr | Out-Null
        $summary.driver_registered=$true
        & (Join-Path $PSScriptRoot 'configure_windows_steam_catalog.ps1') -Root $root -Executable (Join-Path $installed 'nightfall-meteor.exe') -SteamRoot $steam -AppIds @('438100') -RemoveMeteorOptions -Apply | Out-Null
        $summary.vrchat_wrapper_removed=$true
        $summary.meteor_pid=(Start-Process (Join-Path $installed 'nightfall-meteor.exe') -PassThru).Id
        $summary.applied=$true
    }
    $summary.ok=$true
} catch {$summary.error=$_.Exception.Message}
$summary | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $out 'acceptance-install-summary.json') -Encoding UTF8
$summary | ConvertTo-Json -Depth 5
if(-not $summary.ok){exit 1}
