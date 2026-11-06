$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$target = Join-Path $repo 'meteor\target'
$build = Join-Path $target 'windows-monado-vcpkg-build'
$probe = Join-Path $target 'windows-runtime-probe'
$root = Join-Path $target 'windows-xr-dev'
New-Item -ItemType Directory -Force $root | Out-Null
$files = @{
    service = Join-Path $build 'src\xrt\targets\service\Release\monado-service.exe'
    manifest = Join-Path $build 'Release\openxr_monado-dev.json'
    encoder = Join-Path $probe 'Release\meteor-windows-nvenc.dll'
    tracking = Join-Path $probe 'Release\meteor-windows-tracking.dll'
    application = Join-Path $probe 'Release\meteor-runtime-probe.exe'
    arguments = @()
    library_dirs = @((Join-Path $build 'vcpkg_installed\x64-windows\bin'),'C:\VulkanSDK\1.4.363.0\Bin')
    pixel_probe = $true
    async_delivery = $true
}
[IO.File]::WriteAllText((Join-Path $root 'xr-windows.json'),($files | ConvertTo-Json -Depth 3),[Text.UTF8Encoding]::new($false))
$env:NIGHTFALL_WINDOWS_XR_ROOT = $root
$env:NIGHTFALL_WINDOWS_TRACKING_PORT = '45994'
$env:METEOR_CONTINUOUS_FRAMES = '5'
$publisher = $null
try {
    $publisher = Start-Process (Join-Path $probe 'Release\meteor-tracking-socket.exe') -ArgumentList '--serve' -PassThru `
        -RedirectStandardOutput (Join-Path $probe 'session-publisher.out') `
        -RedirectStandardError (Join-Path $probe 'session-publisher.err')
    $publisherHandle = $publisher.Handle
    Push-Location (Join-Path $repo 'meteor')
    try {
        & cargo test --release --locked --no-default-features xr_session::tests::configured_runtime_delivers_frames_and_cleans_up -- --ignored --nocapture
        if ($LASTEXITCODE -ne 0) { throw 'Native Windows XR session check failed' }
    } finally { Pop-Location }
} finally {
    if ($publisher -and -not $publisher.HasExited) { Stop-Process -Id $publisher.Id -Force }
}
