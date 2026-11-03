param(
    [string]$Source = (Join-Path $PSScriptRoot '..\meteor\target\windows-monado-src'),
    [string]$Build = (Join-Path $PSScriptRoot '..\meteor\target\windows-monado-vcpkg-build')
)

$ErrorActionPreference = 'Stop'
$patch = Join-Path $PSScriptRoot 'monado_windows_capture.patch'
$header = Join-Path $PSScriptRoot 'monado_windows_capture.h'
$destination = Join-Path $Source 'src\xrt\compositor\null\monado_windows_capture.h'
if (-not (Test-Path (Join-Path $Source '.git'))) { throw "Missing pinned Monado checkout: $Source" }
if (-not (Test-Path $Build)) { throw "Missing configured Monado build: $Build" }

& git -C $Source apply --reverse --check $patch 2>$null
if ($LASTEXITCODE -ne 0) {
    & git -C $Source apply --check $patch
    if ($LASTEXITCODE -ne 0) { throw 'The Windows capture patch does not apply to this Monado checkout' }
    & git -C $Source apply $patch
    if ($LASTEXITCODE -ne 0) { throw 'Could not apply the Windows capture patch' }
}
Copy-Item $header $destination -Force
foreach ($name in 'monado_windows_readback.h','monado_probe_paths.h','monado_windows_encoder.h','monado_nvenc_bridge.h') {
    Copy-Item (Join-Path $PSScriptRoot $name) (Join-Path (Split-Path $destination) $name) -Force
}
& cmake --build $Build --config Release --target monado-service --parallel 4
if ($LASTEXITCODE -ne 0) { throw 'Windows Monado service build failed' }
