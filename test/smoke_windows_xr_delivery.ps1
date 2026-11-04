$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$root = Join-Path $repo 'meteor\target\windows-runtime-probe'
$env:METEOR_WINDOWS_ENCODER = Join-Path $root 'Release\meteor-windows-nvenc.dll'
$env:METEOR_XR_DIRECT_PORT = '45993'
$sink = $null
try {
    $sink = Start-Process (Join-Path $root 'Release\meteor-xr-wire-sink.exe') -PassThru `
        -ArgumentList '45993',(Join-Path $root 'delivered.h264') `
        -RedirectStandardOutput (Join-Path $root 'delivery.out') `
        -RedirectStandardError (Join-Path $root 'delivery.err')
    $sinkHandle = $sink.Handle
    & (Join-Path $PSScriptRoot 'smoke_monado_windows.ps1') `
        -HelloXr (Join-Path $root 'Release\meteor-runtime-probe.exe') -Seconds 3 -PixelProbe
    if (-not $sink.WaitForExit(5000)) { throw 'XR receiver did not receive session END' }
    $sink.WaitForExit()
    Get-Content (Join-Path $root 'delivery.out')
    if ($sink.ExitCode -ne 0) { Get-Content (Join-Path $root 'delivery.err'); throw 'XR wire validation failed' }
} finally {
    if ($sink -and -not $sink.HasExited) { Stop-Process -Id $sink.Id -Force }
}
