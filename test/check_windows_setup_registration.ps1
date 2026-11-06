# Isolated setup integration. Stub CLI/registration; never call real vrpathreg.
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
$root=Join-Path $repo ('meteor\target\windows-setup-registration-test-'+[guid]::NewGuid().ToString('N'))
$app=Join-Path $root 'app'
$steam=Join-Path $root 'Steam'
$saved=@{APPDATA=$env:APPDATA;LOCALAPPDATA=$env:LOCALAPPDATA}
$summary=@{ok=$false;system_registration_changed=$false}
try {
    $env:APPDATA=Join-Path $root 'Roaming';$env:LOCALAPPDATA=Join-Path $root 'Local'
    foreach($path in @($app,"$steam\steamapps\common\SteamVR","$steam\config")) {
        New-Item -ItemType Directory -Force $path | Out-Null
    }
    Copy-Item (Join-Path $repo 'meteor\tools\windows-release\Setup-Meteor.ps1') $app -Force
    [IO.File]::WriteAllText("$app\nightfall-meteor.exe",'fixture; never executed')
    [IO.File]::WriteAllText("$steam\steam.exe",'fixture; never executed')
    [IO.File]::WriteAllText("$app\Meteor-Cli.ps1",'function Invoke-MeteorCli { param($Executable,$Options) if($Options[0] -eq "--xr-steam-options"){return "fixture launch options"} }')
    [IO.File]::WriteAllText("$app\SteamVR-Driver.ps1",@'
param($Action,$AppRoot,$SteamVRRoot,[switch]$Preview)
if($Preview){throw 'Normal PCVR setup must register, not preview'}
if($Action -ne 'Register' -or $AppRoot -ne $PSScriptRoot){throw 'Unexpected registration arguments'}
$record=@{action=$Action;driver=$AppRoot;runtime=$SteamVRRoot;registered=$true}
$record | ConvertTo-Json | Set-Content (Join-Path $PSScriptRoot 'registration-call.json')
$record | ConvertTo-Json
'@)
    foreach($game in @(@{id='250820';dir='SteamVR'})) {
        [IO.File]::WriteAllText("$steam\steamapps\appmanifest_$($game.id).acf",('"AppState" { "installdir" "'+$game.dir+'" }'))
    }
    $setup=Join-Path $app 'Setup-Meteor.ps1'
    # Setup's process guard must see the isolated fixture, not the user's
    # running installation. This function is scoped to this test process.
    function Get-Process {param($Name,$ErrorAction)}
    $result=& $setup -EnablePCVR -SteamRoot $steam -Root (Join-Path $root 'profiles') -Quiet | ConvertFrom-Json
    if(-not $result.ok -or -not $result.pcvr_enabled -or -not $result.steamvr_driver.registered){throw 'PCVR setup did not register the driver'}
    if($result.games.Count -ne 0 -or -not (Test-Path (Join-Path $root 'profiles\steamvr-runtime\xr-windows.json'))){throw 'General PCVR setup must work without Moss, VRChat, or any installed game'}
    $call=Get-Content "$app\registration-call.json" -Raw | ConvertFrom-Json
    if($call.runtime -ne "$steam\steamapps\common\SteamVR"){throw 'Wrong SteamVR installation selected'}
    # Add an arbitrary VR title in a second library, plus a non-VR installation.
    $library=Join-Path $root 'Second Library'
    New-Item -ItemType Directory -Force "$library\steamapps\common\Example VR","$steam\steamapps\common\Desktop Game" | Out-Null
    [IO.File]::WriteAllText("$steam\steamapps\libraryfolders.vdf",('"libraryfolders" { "1" { "path" "'+$library.Replace('\','\\')+'" } }'))
    [IO.File]::WriteAllText("$library\steamapps\appmanifest_123456.acf",'"AppState" { "installdir" "Example VR" }')
    [IO.File]::WriteAllText("$steam\steamapps\appmanifest_234567.acf",'"AppState" { "installdir" "Desktop Game" }')
    [IO.File]::WriteAllText("$steam\config\steamapps.vrmanifest",(@{applications=@(
        @{app_key='steam.app.123456';url='steam://untrusted-command';strings=@{en_us=@{name='Example VR'}}},
        @{app_key='steam.app.123456'},@{app_key='steam.app.999999'},@{app_key='remote:arbitrary'}
    )} | ConvertTo-Json -Depth 6))
    $general=& $setup -EnablePCVR -SteamRoot $steam -Root (Join-Path $root 'profiles') -Quiet | ConvertFrom-Json
    if(-not $general.ok -or $general.games.Count -ne 1 -or $general.games[0].id -ne '123456'){throw 'Generic discovery did not filter installed VR games correctly'}
    $profile=Get-Content (Join-Path $root 'profiles\profiles\123456\steamvr\xr-windows.json') -Raw | ConvertFrom-Json
    if(-not $profile.steamvr_launch_via_steam -or $profile.arguments.Count -ne 1 -or $profile.arguments[0] -ne 'steam://launch/123456/VR'){throw 'Generic VR launch did not construct a game-scoped Steam URL'}
    # Host-only setup must not invoke SteamVR registration.
    $before=(Get-Item "$app\registration-call.json").LastWriteTimeUtc
    $hostOnly=& $setup -EnableHost -Root (Join-Path $root 'profiles') -Quiet | ConvertFrom-Json
    if(-not $hostOnly.ok -or $hostOnly.PSObject.Properties.Name -contains 'steamvr_driver'){throw 'Host-only setup unexpectedly configured SteamVR'}
    if((Get-Item "$app\registration-call.json").LastWriteTimeUtc -ne $before){throw 'Host-only setup invoked registration'}
    Rename-Item "$steam\steamapps\appmanifest_250820.acf" 'appmanifest_250820.uninstalled'
    $missingRoot=Join-Path $root 'without-steamvr'
    $missing=& $setup -EnablePCVR -SteamRoot $steam -Root $missingRoot -Quiet | ConvertFrom-Json
    if(-not $missing.ok -or -not $missing.pcvr_enabled -or $missing.steamvr_ready -or $missing.games.Count -ne 1 -or $missing.warnings.Count){throw 'Missing SteamVR must remain a per-game requirement, not block setup'}
    $descriptor=Get-Content (Join-Path $missingRoot 'xr-windows.json') -Raw | ConvertFrom-Json
    if(-not $descriptor.library_only){throw 'App library must remain available before SteamVR is installed'}
    $summary.ok=$true
} catch {$summary.error=$_.Exception.Message} finally {
    $env:APPDATA=$saved.APPDATA;$env:LOCALAPPDATA=$saved.LOCALAPPDATA
    $summary | ConvertTo-Json | Set-Content (Join-Path $root 'summary.json')
}
$summary | ConvertTo-Json
if(-not $summary.ok){exit 1}
