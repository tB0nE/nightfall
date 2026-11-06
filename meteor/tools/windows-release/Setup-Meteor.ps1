param([switch]$EnableHost,[switch]$EnablePCVR,[string]$SteamRoot='',
    [string]$Root='',[switch]$Quiet,[switch]$PreviewSteamVRRegistration)
# Installed setup entry point. All runtime inputs must live beside Meteor.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Meteor-Cli.ps1')
$exe=Join-Path $PSScriptRoot 'nightfall-meteor.exe'
$runtime=Join-Path $PSScriptRoot 'runtime\xr'
if(-not $Root){$Root=Join-Path $env:LOCALAPPDATA 'Nightfall Meteor\xr\windows'}
$summary=[ordered]@{ok=$false;host_enabled=$false;pcvr_enabled=$false;games=@();warnings=@()}
$data=Join-Path $env:LOCALAPPDATA 'Nightfall Meteor'
New-Item -ItemType Directory -Force $data | Out-Null
function WriteJson([string]$Path,$Value) {
    New-Item -ItemType Directory -Force (Split-Path $Path) | Out-Null
    if((Test-Path -LiteralPath $Path) -and -not (Test-Path -LiteralPath "$Path.before-setup")){Copy-Item -LiteralPath $Path -Destination "$Path.before-setup"}
    [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
}
function InvokeMeteor([string[]]$Options) {
    Invoke-MeteorCli -Executable $exe -Options $Options | Out-Null
}
try {
    if(-not (Test-Path -LiteralPath $exe)){throw 'Meteor executable missing beside setup'}
    if(Get-Process nightfall-meteor -ErrorAction SilentlyContinue){throw 'Quit Meteor from its tray before running setup again'}
    if($EnableHost) {
        InvokeMeteor -Options @('--xr-windows-host','--root',$Root)
        $summary.host_enabled=$true
    }
    if($EnablePCVR) {
        if(-not $SteamRoot){$SteamRoot=(Get-ItemProperty 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction SilentlyContinue).SteamPath}
        if(-not $SteamRoot){$SteamRoot=Join-Path ${env:ProgramFiles(x86)} 'Steam'}
        $libraries=@($SteamRoot)
        $libraryFile=Join-Path $SteamRoot 'steamapps\libraryfolders.vdf'
        if(Test-Path -LiteralPath $libraryFile) {
            if((Get-Item $libraryFile).Length -gt 1MB){throw 'Steam library configuration exceeds 1 MiB'}
            foreach($match in [regex]::Matches([IO.File]::ReadAllText($libraryFile),'"path"\s+"(?<path>(?:\\.|[^"\\])*)"')) {
                $libraries+=$match.Groups['path'].Value.Replace('\\','\')
            }
        }
        $libraries=@($libraries | Select-Object -Unique)
        function FindGame([string]$Id) {
            foreach($library in $libraries) {
                $acf=Join-Path $library "steamapps\appmanifest_$Id.acf"
                if(-not (Test-Path -LiteralPath $acf)){continue}
                if((Get-Item $acf).Length -gt 1MB){throw 'Steam app manifest exceeds 1 MiB'}
                $match=[regex]::Match([IO.File]::ReadAllText($acf),'"installdir"\s+"(?<dir>[^"\\/]+)"')
                if($match.Success -and $match.Groups['dir'].Value -notin @('.','..')) {
                    $game=Join-Path $library ('steamapps\common\'+$match.Groups['dir'].Value)
                    if(Test-Path -LiteralPath $game -PathType Container){return $game}
                }
            }
            return $null
        }
        $steamvr=FindGame '250820'
        $bin=Join-Path $runtime 'bin'
        if($steamvr) {
            $shared=@{
                service=(Join-Path $bin 'meteor-steamvr-mirror.exe');manifest=(Join-Path $runtime 'openxr_monado.json')
                encoder=(Join-Path $bin 'meteor-windows-nvenc.dll');tracking=(Join-Path $bin 'meteor-windows-tracking.dll')
                library_dirs=@($bin);steam_app_id='250820';steam_launch=$false;pixel_probe=$false;async_delivery=$true;arguments=@()
                application=(Join-Path $steamvr 'bin\win64\vrmonitor.exe');openvr_runtime=$steamvr
                steamvr_driver=(Join-Path $runtime 'steamvr');steamvr_capture='direct'
            }
            WriteJson (Join-Path $Root 'steamvr-runtime\xr-windows.json') $shared
            if(-not (Test-Path (Join-Path $Root 'xr-windows.json'))){WriteJson (Join-Path $Root 'xr-windows.json') $shared}
            $registration=& (Join-Path $PSScriptRoot 'SteamVR-Driver.ps1') -Action Register -AppRoot $PSScriptRoot -SteamVRRoot $steamvr -Preview:$PreviewSteamVRRegistration
            $summary.steamvr_driver=$registration | ConvertFrom-Json
            if(-not $summary.steamvr_driver.registered -and -not $PreviewSteamVRRegistration){throw 'Meteor SteamVR driver registration did not complete'}
            $summary.steamvr_ready=$true
        }
        # Retain a known native-runtime optimization, not a supported-game list.
        foreach($game in @(@{id='846470';name='Moss'})) {
            $installed=FindGame $game.id
            if(-not $installed){continue}
            $profile=Join-Path $Root ('profiles\'+$game.id)
            $config=@{
                service=(Join-Path $bin 'monado-service.exe');manifest=(Join-Path $runtime 'openxr_monado.json')
                encoder=(Join-Path $bin 'meteor-windows-nvenc.dll');tracking=(Join-Path $bin 'meteor-windows-tracking.dll')
                library_dirs=@($bin);steam_app_id=$game.id;steam_launch=$false;pixel_probe=$false;async_delivery=$true;arguments=@()
            }
            if($game.id -eq '846470') {
                $config.application=Join-Path $installed 'Moss\Binaries\Win64\Moss-Win64-Shipping.exe'
                $config.arguments=@('-vr','-dx11','-hmd=SteamVR')
                $config.openvr_runtime=Join-Path $runtime 'xrizer'
                $config.openvr_loader=Join-Path $installed 'Engine\Binaries\ThirdParty\OpenVR\OpenVRv1_5_17\Win64\openvr_api.dll'
                if(-not (Test-Path $config.openvr_loader)){$config.openvr_loader=Join-Path $installed 'Moss\Engine\Binaries\ThirdParty\OpenVR\OpenVRv1_5_17\Win64\openvr_api.dll'}
            }
            if(-not (Test-Path -LiteralPath $config.application -PathType Leaf) -or -not (Test-Path -LiteralPath $config.openvr_loader -PathType Leaf)){continue}
            WriteJson (Join-Path $profile 'xr-windows.json') $config
            InvokeMeteor -Options @('--xr-windows-register','--root',$Root,'--profile',$profile,'--name',$game.name)
            $summary.games+=$game
        }
        if($steamvr) {
            $vrManifest=Join-Path $SteamRoot 'config\steamapps.vrmanifest'
            if(Test-Path -LiteralPath $vrManifest) {
                if((Get-Item $vrManifest).Length -gt 8MB){throw 'Steam VR manifest exceeds 8 MiB'}
                $apps=(Get-Content $vrManifest -Raw | ConvertFrom-Json).applications
                $seen=@{}
                foreach($app in @($apps | Select-Object -First 1000)) {
                    if($app.app_key -notmatch '^steam\.app\.([1-9][0-9]{0,9})$'){continue}
                    $id=$Matches[1]
                    if($id -eq '250820' -or $seen.ContainsKey($id)){continue}
                    $installed=FindGame $id
                    if(-not $installed){continue}
                    $seen[$id]=$true
                    $name=[string]$app.strings.en_us.name
                    if(-not $name){$name=Split-Path $installed -Leaf}
                    if($name.Length -gt 96){$name=$name.Substring(0,96)}
                    if($name -match '[\x00-\x1f]'){continue}
                    $profile=Join-Path $Root ('profiles\'+$id+'\steamvr')
                    $config=$shared.Clone();$config.steam_app_id=$id
                    $config.application=Join-Path $SteamRoot 'steam.exe'
                    $config.arguments=@('steam://launch/'+$id+'/VR');$config.steamvr_launch_via_steam=$true
                    WriteJson (Join-Path $profile 'xr-windows.json') $config
                    InvokeMeteor -Options @('--xr-windows-register','--root',$Root,'--profile',$profile,'--name',$name)
                    if(-not @($summary.games | Where-Object {$_.id -eq $id}).Count){$summary.games+=@{id=$id;name=$name}}
                }
            }
        }
        if($summary.games.Count -or $steamvr) {
            InvokeMeteor -Options @('--xr-windows-enable','--root',$Root)
            $options=Invoke-MeteorCli -Executable $exe -Options @('--xr-steam-options','--root',$Root)
            [IO.File]::WriteAllText((Join-Path $Root 'steam-launch-options.txt'),$options,[Text.UTF8Encoding]::new($false))
            $summary.pcvr_enabled=$true
        } else {$summary.warnings+='Install SteamVR through Steam, then run Set up Nightfall Meteor again.'}
    }
    $summary.ok=$true
} catch {
    $summary.error=$_.Exception.Message
} finally {
    [IO.File]::WriteAllText((Join-Path $data 'setup-summary.json'),($summary | ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
}
if(-not $Quiet -and (-not $summary.ok -or $summary.warnings.Count)) {
    Add-Type -AssemblyName System.Windows.Forms
    $message=if($summary.ok){$summary.warnings -join "`r`n`r`n"}else{"Meteor setup needs attention: $($summary.error)"}
    [Windows.Forms.MessageBox]::Show($message,'Nightfall Meteor setup') | Out-Null
}
$summary | ConvertTo-Json -Depth 6
if(-not $summary.ok){exit 1}
