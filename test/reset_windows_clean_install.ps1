param([switch]$Apply)
# Preview by default. Preserve all Meteor state outside its normal search paths.
# Drivers, Steam, games, VB-CABLE and headset data are deliberately retained.
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
$backup=Join-Path $env:LOCALAPPDATA ('Nightfall Meteor clean-install backups\'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))
$paths=@(
    @{name='roaming';path=(Join-Path $env:APPDATA 'Nightfall Meteor')},
    @{name='local';path=(Join-Path $env:LOCALAPPDATA 'Nightfall Meteor')},
    @{name='development-host-config';path=(Join-Path $repo 'meteor\target\windows-vibepollo-src\build-meteor-windows\config')}
)
$allRules=@(Get-NetFirewallRule)
# Setup's own rules (group 'Nightfall Meteor'), and the ones Windows made from its
# "Allow access" prompt for Meteor or for a host that Meteor or its checks ran.
$rules=@($allRules | Where-Object {$_.DisplayName -match '^nightfall[-_]meteor' -or $_.Name -eq 'NightfallMeteorXRWirelessTrial' -or $_.Group -eq 'Nightfall Meteor'})
$hostRoots=@($repo,(Join-Path $env:TEMP 'Nightfall-packaged-check-'),(Join-Path $env:LOCALAPPDATA 'Programs\Nightfall Meteor'))
foreach($rule in $allRules | Where-Object {$_.DisplayName -eq 'sunshine.exe'}) {
    $application=$rule | Get-NetFirewallApplicationFilter
    if($hostRoots | Where-Object {$application.Program.StartsWith($_,[StringComparison]::OrdinalIgnoreCase)}){$rules+=$rule}
}
$summary=[ordered]@{applied=$false;backup=$backup;folders=@($paths | Where-Object {Test-Path -LiteralPath $_.path});firewall_rules=@($rules | Select-Object Name,DisplayName,Enabled,Action);preserved=@('GPU and audio drivers','Steam and games','VB-CABLE','Quest app and pairing data');issues=@();moved=@()}
if(-not $Apply){$summary | ConvertTo-Json -Depth 5;return}
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if($rules.Count -and -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run this reset as administrator to remove the old Meteor firewall rules; nothing was changed'}
if(Get-Process VRChat,Moss-Win64-Shipping,vrserver,vrcompositor -ErrorAction SilentlyContinue){throw 'Exit the active VR game/runtime before resetting Meteor'}
New-Item -ItemType Directory -Path $backup | Out-Null
$report=Join-Path $backup 'reset-summary.json'
function SaveReport { $summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $report -Encoding utf8 }
SaveReport
if(Get-Process nightfall-meteor -ErrorAction SilentlyContinue) {
    & (Join-Path $PSScriptRoot 'stop_windows_meteor.ps1')
    if($LASTEXITCODE){throw 'Meteor did not stop cleanly'}
}
if(Get-Process nightfall-meteor,sunshine,monado-service -ErrorAction SilentlyContinue){throw 'Streaming processes remain; no state folders were moved'}
# Remove only the exact launch options generated for this repository/catalog.
& (Join-Path $PSScriptRoot 'configure_windows_steam_catalog.ps1') -RemoveMeteorOptions -Apply -NoRestart
if($LASTEXITCODE){throw 'Steam launch options could not be reset'}
# Removed, not disabled: Windows never asks again about a program that any rule
# names, even a disabled one, so a disabled rule left a reinstall blocked.
$rules | ForEach-Object {[pscustomobject]@{Name=$_.Name;DisplayName=$_.DisplayName;Enabled=$_.Enabled;Action=$_.Action;Profile="$($_.Profile)";Program=($_ | Get-NetFirewallApplicationFilter).Program}} | Export-Clixml (Join-Path $backup 'firewall-rules.xml')
foreach($rule in $rules){Remove-NetFirewallRule -Name $rule.Name}
$openvr=Join-Path $env:LOCALAPPDATA 'openvr\openvrpaths.vrpath'
if(Test-Path -LiteralPath $openvr) {
    $text=[IO.File]::ReadAllText($openvr);$value=$text | ConvertFrom-Json
    $removed=@($value.runtime | Where-Object {$_.StartsWith($repo,[StringComparison]::OrdinalIgnoreCase)})
    if($removed.Count) {
        $remaining=@($value.runtime | Where-Object {-not $_.StartsWith($repo,[StringComparison]::OrdinalIgnoreCase)})
        if(-not $remaining.Count){throw 'No non-development OpenVR runtime to retain; review the registration manually'}
        Copy-Item -LiteralPath $openvr -Destination (Join-Path $backup 'openvrpaths.vrpath')
        $value.runtime=$remaining
        $steamvr=@($remaining | Where-Object {Test-Path (Join-Path $_ 'bin\win64\vrstartup.exe')})
        if($steamvr.Count) {
            $steam=Split-Path (Split-Path (Split-Path $steamvr[0]))
            $xrizer=Join-Path $env:LOCALAPPDATA 'xrizer'
            $value.config=@($value.config | ForEach-Object {if($_.StartsWith($xrizer,[StringComparison]::OrdinalIgnoreCase)){Join-Path $steam 'config'}else{$_}})
            $value.log=@($value.log | ForEach-Object {if($_.StartsWith($xrizer,[StringComparison]::OrdinalIgnoreCase)){Join-Path $steam 'logs'}else{$_}})
        }
        [IO.File]::WriteAllText($openvr,($value | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    }
}
$run='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$startup=(Get-ItemProperty $run -Name 'Nightfall Meteor' -ErrorAction SilentlyContinue).'Nightfall Meteor'
if($startup) {
    [IO.File]::WriteAllText((Join-Path $backup 'meteor-autostart.txt'),$startup)
    Remove-ItemProperty $run -Name 'Nightfall Meteor'
}
foreach($entry in $summary.folders) {
    $destination=Join-Path $backup $entry.name
    Move-Item -LiteralPath $entry.path -Destination $destination
    $summary.moved+=@{source=$entry.path;backup=$destination};SaveReport
}
$installed=Join-Path $env:LOCALAPPDATA 'Programs\Nightfall Meteor'
$uninstaller=Join-Path $installed 'unins000.exe'
if(Test-Path -LiteralPath $uninstaller) {
    Copy-Item -LiteralPath $installed -Destination (Join-Path $backup 'installed-program') -Recurse
    $process=Start-Process $uninstaller -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART' -PassThru -Wait
    if($process.ExitCode){throw "Old Meteor uninstall failed ($($process.ExitCode)); backups retained"}
}
$summary.applied=$true;SaveReport
Write-Output "Meteor reset completed. Recovery state: $backup"
