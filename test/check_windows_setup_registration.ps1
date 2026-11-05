# Isolated setup integration. Stub CLI/registration; never call real vrpathreg.
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
$root=Join-Path $repo 'meteor\target\windows-setup-registration-test'
$app=Join-Path $root 'app'
$steam=Join-Path $root 'Steam'
$saved=@{APPDATA=$env:APPDATA;LOCALAPPDATA=$env:LOCALAPPDATA}
$summary=@{ok=$false;system_registration_changed=$false}
try {
    $env:APPDATA=Join-Path $root 'Roaming';$env:LOCALAPPDATA=Join-Path $root 'Local'
    foreach($path in @($app,"$steam\steamapps\common\SteamVR","$steam\steamapps\common\Moss")) {
        New-Item -ItemType Directory -Force $path | Out-Null
    }
    Copy-Item (Join-Path $repo 'meteor\tools\windows-release\Setup-Meteor.ps1') $app -Force
    [IO.File]::WriteAllText("$app\nightfall-meteor.exe",'fixture; never executed')
    [IO.File]::WriteAllText("$app\Meteor-Cli.ps1",'function Invoke-MeteorCli { param($Executable,$Options) if($Options[0] -eq "--xr-steam-options"){return "fixture launch options"} }')
    [IO.File]::WriteAllText("$app\SteamVR-Driver.ps1",@'
param($Action,$AppRoot,$SteamVRRoot,[switch]$Preview)
if($Preview){throw 'Normal PCVR setup must register, not preview'}
if($Action -ne 'Register' -or $AppRoot -ne $PSScriptRoot){throw 'Unexpected registration arguments'}
$record=@{action=$Action;driver=$AppRoot;runtime=$SteamVRRoot;registered=$true}
$record | ConvertTo-Json | Set-Content (Join-Path $PSScriptRoot 'registration-call.json')
$record | ConvertTo-Json
'@)
    foreach($game in @(@{id='250820';dir='SteamVR'},@{id='846470';dir='Moss'})) {
        [IO.File]::WriteAllText("$steam\steamapps\appmanifest_$($game.id).acf",('"AppState" { "installdir" "'+$game.dir+'" }'))
    }
    $setup=Join-Path $app 'Setup-Meteor.ps1'
    # Setup's process guard must see the isolated fixture, not the user's
    # running installation. This function is scoped to this test process.
    function Get-Process {param($Name,$ErrorAction)}
    $result=& $setup -EnablePCVR -SteamRoot $steam -Root (Join-Path $root 'profiles') -Quiet | ConvertFrom-Json
    if(-not $result.ok -or -not $result.pcvr_enabled -or -not $result.steamvr_driver.registered){throw 'PCVR setup did not register the driver'}
    $call=Get-Content "$app\registration-call.json" -Raw | ConvertFrom-Json
    if($call.runtime -ne "$steam\steamapps\common\SteamVR"){throw 'Wrong SteamVR installation selected'}
    # Host-only setup must not invoke SteamVR registration.
    $before=(Get-Item "$app\registration-call.json").LastWriteTimeUtc
    $hostOnly=& $setup -EnableHost -Root (Join-Path $root 'profiles') -Quiet | ConvertFrom-Json
    if(-not $hostOnly.ok -or $hostOnly.PSObject.Properties.Name -contains 'steamvr_driver'){throw 'Host-only setup unexpectedly configured SteamVR'}
    if((Get-Item "$app\registration-call.json").LastWriteTimeUtc -ne $before){throw 'Host-only setup invoked registration'}
    $summary.ok=$true
} catch {$summary.error=$_.Exception.Message} finally {
    $env:APPDATA=$saved.APPDATA;$env:LOCALAPPDATA=$saved.LOCALAPPDATA
    $summary | ConvertTo-Json | Set-Content (Join-Path $root 'summary.json')
}
$summary | ConvertTo-Json
if(-not $summary.ok){exit 1}
