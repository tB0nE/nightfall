# Local D3D11/xrizer/Monado capture; no headset or game configuration changes.
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
$target=Join-Path $repo 'meteor\target'
$steam=(Get-ItemProperty 'HKCU:\Software\Valve\Steam' -Name SteamPath).SteamPath
$loader=Join-Path $steam 'steamapps\common\Moss\Engine\Binaries\ThirdParty\OpenVR\OpenVRv1_5_17\Win64\openvr_api.dll'
$old=$env:METEOR_EXPECT_FULL_VIEW_RENDER
try {
    $env:METEOR_EXPECT_FULL_VIEW_RENDER='1'
    & (Join-Path $PSScriptRoot 'smoke_windows_xr_application.ps1') `
        -Application (Join-Path $target 'windows-runtime-probe\Release\meteor-openvr-probe.exe') `
        -ApplicationArguments @($loader,'360','--scene') `
        -OpenVrRuntime (Join-Path $target 'windows-xrizer-d3d11-src\target\release') `
        -OpenVrLoader $loader -ObserveSeconds 3 -EyeWidth 2064 -EyeHeight 2208 -Codec h265
    if($LASTEXITCODE){throw 'Full-view capture check failed'}
} finally {$env:METEOR_EXPECT_FULL_VIEW_RENDER=$old}
