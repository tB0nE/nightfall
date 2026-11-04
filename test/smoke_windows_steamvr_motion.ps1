param([ValidateRange(3,10)][int]$Seconds=5)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
$target=Join-Path $repo 'meteor\target'
$stamp=[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')
$output=Join-Path $target "windows-steamvr-motion\$stamp"
New-Item -ItemType Directory -Force "$output\images" | Out-Null
$oldMotion=$env:METEOR_TRACKING_MOTION;$oldProbe=$env:METEOR_STEAMVR_GEOMETRY_PROBE
try {
    $env:METEOR_TRACKING_MOTION='1';$env:METEOR_STEAMVR_GEOMETRY_PROBE='1'
    & "$PSScriptRoot\smoke_windows_xr_application.ps1" -SteamVR -Application "$target\windows-runtime-probe\Release\meteor-openvr-probe.exe" `
        -ApplicationArguments @('C:\Program Files (x86)\Steam\steamapps\common\SteamVR\bin\win64\openvr_api.dll','720','--scene') -ObserveSeconds $Seconds
    foreach($file in 'application-startup.h264','application-frames.jsonl','smoke-summary.json') {Copy-Item "$target\windows-xr-application\$file" "$output\$file"}
    $ffmpeg="$target\windows-ffmpeg\extract\ffmpeg-n8.0.1-66-g27b8d1a017-win64-lgpl-shared-8.0\bin\ffmpeg.exe"
    & $ffmpeg -v error -y -i "$output\application-startup.h264" -vf 'select=not(mod(n\,20)),scale=1024:512' -fps_mode passthrough -frames:v 20 "$output\images\frame-%04d.ppm"
    if($LASTEXITCODE -ne 0) {throw 'Motion capture could not be decoded'}
    Write-Output "motion_artifacts=$output"
    Write-Output 'Run test/verify_windows_steamvr_motion.py on images and application-frames.jsonl with the host /usr/bin/python3.'
} finally {$env:METEOR_TRACKING_MOTION=$oldMotion;$env:METEOR_STEAMVR_GEOMETRY_PROBE=$oldProbe}
