$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$root = Join-Path $repo 'meteor\target\windows-runtime-probe'
$env:METEOR_TRACKING_BRIDGE = Join-Path $root 'Release\meteor-windows-tracking.dll'
$env:METEOR_TRACKING_PORT = '45994'
$env:METEOR_XR_CONTROLLERS = '1'
$env:METEOR_XR_TOUCH_INPUTS = '1'
$env:METEOR_XR_HAPTICS = '1'
$env:SIMULATED_LEFT = 'touch'
$env:SIMULATED_RIGHT = 'touch'
$publisher = $null
try {
    $publisher = Start-Process (Join-Path $root 'Release\meteor-tracking-socket.exe') -ArgumentList '--serve' -PassThru `
        -RedirectStandardOutput (Join-Path $root 'tracking-publisher.out') `
        -RedirectStandardError (Join-Path $root 'tracking-publisher.err')
    $publisherHandle = $publisher.Handle
    & (Join-Path $PSScriptRoot 'smoke_windows_xr_delivery.ps1')
    $log = Get-Content (Join-Path $repo 'meteor\target\windows-monado-vcpkg-build\meteor-windows-smoke\service.err')
    if (-not ($log | Select-String 'METEOR_TRACKING_APPLIED.*position=0.250000,0.500000,-0.750000')) { throw 'Monado did not apply the published head pose' }
    Write-Output 'PASS: synthetic head samples reached Windows Monado while stereo encoding remained active'
} finally {
    if ($publisher -and -not $publisher.HasExited) { Stop-Process -Id $publisher.Id -Force }
}
