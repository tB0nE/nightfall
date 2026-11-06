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
$env:METEOR_CONTROLLER_FIXTURE = Join-Path $root 'controller-phase.txt'
$publisher = $null
try {
    $publisher = Start-Process (Join-Path $root 'Release\meteor-tracking-socket.exe') -ArgumentList '--serve' -PassThru `
        -RedirectStandardOutput (Join-Path $root 'controller-publisher.out') `
        -RedirectStandardError (Join-Path $root 'controller-publisher.err')
    $publisherHandle = $publisher.Handle
    & (Join-Path $PSScriptRoot 'smoke_monado_windows.ps1') `
        -HelloXr (Join-Path $root 'Release\meteor-runtime-probe.exe') -Seconds 8
    $logDir = Join-Path $repo 'meteor\target\windows-monado-vcpkg-build\meteor-windows-smoke'
    $output = Get-Content (Join-Path $logDir 'sample.out')
    $phases = @($output | Select-String 'PASS: OpenXR per-hand phase').Count
    if ($phases -ne 10) { Get-Content (Join-Path $logDir 'sample.err'); throw "Only $phases/10 OpenXR controller phases passed" }
    $haptics = Get-Content (Join-Path $root 'controller-publisher.out')
    foreach ($hand in 0,1) {
        if (-not ($haptics | Select-String "haptic_ack_hand=$hand amplitude=0.400 duration_ms=50")) { throw "Missing OpenXR haptic acknowledgement for hand $hand" }
    }
    Write-Output 'PASS: both Windows Monado Touch controllers deliver independent stick-click and B/Y button transitions through OpenXR actions'
} finally {
    if ($publisher -and -not $publisher.HasExited) { Stop-Process -Id $publisher.Id -Force }
}
