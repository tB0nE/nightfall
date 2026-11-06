param([switch]$SkipBuild,[switch]$Capture,[switch]$ExternalCapture,[switch]$BuildApp)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
$build=Join-Path $repo 'meteor\target\windows-steamvr-build'
$out=Join-Path $repo 'meteor\target\windows-steamvr-integration'
New-Item -ItemType Directory -Force $out | Out-Null
$summary=[ordered]@{ok=$false;release=$true;checks=@();headset_used=$false;system_registration_changed=$false}
function InvokeNative([string]$Program,[string[]]$Options,[string]$LogName) {
    # Windows PowerShell 5 treats native stderr warnings as ErrorRecords.
    $ErrorActionPreference='Continue'
    & $Program @Options *> (Join-Path $out $LogName)
    if($LASTEXITCODE){throw "$Program failed ($LASTEXITCODE); see $LogName"}
}
try {
    if(-not $SkipBuild) {
        InvokeNative -Program cmake -Options @('--build',$build,'--config','Release','--parallel','4') -LogName 'build.log'
    }
    foreach($test in @('geometry','bootstrap')) {
        InvokeNative -Program (Join-Path $build "Release\meteor-steamvr-$test-test.exe") -Options @() -LogName "$test.log"
        $summary.checks+=$test
    }
    $env:METEOR_VDA_NCNN_SDK=Join-Path $repo 'meteor\target\windows-release\ncnn-20260526'
    $env:METEOR_STEAMVR_BOOTSTRAP_TEST=Join-Path $build 'Release\meteor-steamvr-bootstrap-test.exe'
    $cargoOptions=@('test','--manifest-path',(Join-Path $repo 'meteor\Cargo.toml'),'--release','--locked','--no-default-features','--bin','nightfall-meteor')
    InvokeNative -Program cargo -Options $cargoOptions -LogName 'windows-unit.log'
    $summary.checks+='windows-release-unit'
    InvokeNative -Program cargo -Options ($cargoOptions+@('xr_steamvr_windows::tests::native_bootstrap_reads_the_rust_broker','--','--ignored','--exact')) -LogName 'native-bootstrap.log'
    $summary.checks+='rust-native-pipe'
    # Exercise the registration planner in an isolated profile, always Preview.
    # Never invoke vrpathreg against this PC's installed driver registrations.
    $fixture=Join-Path $out 'registration-fixture'
    $app=Join-Path $fixture 'app'
    $steam=Join-Path $fixture 'SteamVR'
    $profile=Join-Path $fixture 'profile'
    foreach($dir in @("$app\runtime\xr\steamvr\bin\win64","$steam\bin\win64","$profile\openvr")) {New-Item -ItemType Directory -Force $dir | Out-Null}
    [IO.File]::WriteAllText("$app\runtime\xr\steamvr\driver.vrdrivermanifest",'{"name":"meteor"}')
    [IO.File]::WriteAllText("$app\runtime\xr\steamvr\bin\win64\driver_meteor.dll",'fixture')
    [IO.File]::WriteAllText("$steam\bin\win64\vrpathreg.exe",'not executable; Preview only')
    $paths="$profile\openvr\openvrpaths.vrpath"
    [IO.File]::WriteAllText($paths,'{"external_drivers":[]}')
    $oldProfile=$env:LOCALAPPDATA
    try {
        $env:LOCALAPPDATA=$profile
        $helper=Join-Path $repo 'meteor\tools\windows-release\SteamVR-Driver.ps1'
        $planned=(& $helper -Action Register -AppRoot $app -SteamVRRoot $steam -Preview) | ConvertFrom-Json
        if($planned.operation -ne 'adddriver' -or $planned.registered){throw 'Registration plan incorrect'}
        [IO.File]::WriteAllText($paths,(@{external_drivers=@($planned.driver)} | ConvertTo-Json))
        $before=[IO.File]::ReadAllText($paths)
        $existing=(& $helper -Action Register -AppRoot $app -SteamVRRoot $steam -Preview) | ConvertFrom-Json
        if($existing.operation -or -not $existing.registered){throw 'Registration is not idempotent'}
        $remove=(& $helper -Action Unregister -AppRoot $app -SteamVRRoot $steam -Preview) | ConvertFrom-Json
        if($remove.operation -ne 'removedriver'){throw 'Removal plan incorrect'}
        if([IO.File]::ReadAllText($paths) -ne $before){throw 'Preview mutated registrations'}
    } finally {$env:LOCALAPPDATA=$oldProfile}
    $summary.checks+='registration-preview'
    if($BuildApp) {
        InvokeNative -Program cargo -Options @('build','--manifest-path',(Join-Path $repo 'meteor\Cargo.toml'),'--release','--locked','--no-default-features','--bin','nightfall-meteor') -LogName 'release-app.log'
        $summary.checks+='release-app'
    }
    if($Capture -or $ExternalCapture) {
        if(Get-Process vrserver,vrcompositor,vrmonitor -ErrorAction SilentlyContinue){throw 'An existing SteamVR session will be left untouched; quit it before the local capture check.'}
        $env:NIGHTFALL_WINDOWS_STEAMVR_BOOTSTRAP='1'
        $oldRegistry=$env:VR_PATHREG_OVERRIDE
        $oldReconnect=$env:METEOR_TRACKING_RECONNECT
        if($ExternalCapture) {
            InvokeNative -Program cmake -Options @('--build',(Join-Path $repo 'meteor\target\windows-runtime-probe'),'--config','Release','--target','meteor-tracking-socket','--parallel','4') -LogName 'tracking-build.log'
            $env:NIGHTFALL_WINDOWS_EXTERNAL_STEAMVR='1'
            $env:VR_PATHREG_OVERRIDE=Join-Path $repo 'meteor\target\windows-xr-application\external-paths.vrpath'
            $env:METEOR_TRACKING_RECONNECT='1'
        }
        try {
            & (Join-Path $PSScriptRoot 'smoke_windows_xr_application.ps1') -SteamVR `
                -Application (Join-Path $repo 'meteor\target\windows-runtime-probe\Release\meteor-openvr-probe.exe') `
                -ApplicationArguments @('C:\Program Files (x86)\Steam\steamapps\common\SteamVR\bin\win64\openvr_api.dll','1440','--scene') `
                -ObserveSeconds 3 *> (Join-Path $out 'capture.log')
            $captureSummary=Get-Content (Join-Path $repo 'meteor\target\windows-xr-application\smoke-summary.json') -Raw | ConvertFrom-Json
            if(-not $captureSummary.ok){throw 'Local SteamVR capture through the bootstrap pipe failed'}
            $summary.checks+='steamvr-capture-through-pipe'
            if($ExternalCapture){$summary.checks+='ordinary-steamvr-activation-and-two-connection-cycles'}
        } finally {
            Remove-Item Env:NIGHTFALL_WINDOWS_STEAMVR_BOOTSTRAP,Env:NIGHTFALL_WINDOWS_EXTERNAL_STEAMVR -ErrorAction SilentlyContinue
            $env:VR_PATHREG_OVERRIDE=$oldRegistry
            $env:METEOR_TRACKING_RECONNECT=$oldReconnect
        }
    }
    $summary.ok=$true
} catch {$summary.error=$_.Exception.Message}
$summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $out 'summary.json') -Encoding UTF8
$summary | ConvertTo-Json -Depth 5
if(-not $summary.ok){exit 1}
