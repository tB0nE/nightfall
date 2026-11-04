param(
    [string]$Build = (Join-Path $PSScriptRoot '..\meteor\target\windows-monado-vcpkg-build'),
    [string]$HelloXr = (Join-Path $PSScriptRoot '..\meteor\target\windows-openxr-sample-build\src\tests\hello_xr\Release\hello_xr.exe'),
    [int]$Seconds = 10,
    [ValidateSet('Vulkan','D3D11','D3D12')][string]$Graphics='Vulkan',
    [ValidateSet('Local','Stage','View')][string]$AppSpace='Local',
    [switch]$PixelProbe
)

$ErrorActionPreference = 'Stop'
$serviceExe = Join-Path $Build 'src\xrt\targets\service\Release\monado-service.exe'
$manifest = Join-Path $Build 'Release\openxr_monado-dev.json'
$logDir = Join-Path $Build 'meteor-windows-smoke'
New-Item -ItemType Directory -Force $logDir | Out-Null
$env:XR_RUNTIME_JSON = $manifest
$env:SIMULATED_ENABLE = '1'
$env:XRT_COMPOSITOR_NULL = '1'
if ($PixelProbe) {
    $env:METEOR_WINDOWS_PIXEL_PROBE = '1'
    $env:METEOR_PROBE_OUTPUT = $logDir
    foreach ($name in 'capture-complete','server-eye-left.ppm','server-eye-right.ppm') {
        $file = Join-Path $logDir $name
        if (Test-Path $file) { Remove-Item $file }
    }
}
$env:PATH = "$(Join-Path $Build 'vcpkg_installed\x64-windows\bin');C:\VulkanSDK\1.4.363.0\Bin;$env:PATH"
$service = $null
$sample = $null
try {
    $service = Start-Process $serviceExe -PassThru `
        -RedirectStandardOutput (Join-Path $logDir 'service.out') `
        -RedirectStandardError (Join-Path $logDir 'service.err')
    Start-Sleep -Seconds 2
    if ($service.HasExited) { throw 'Monado service exited before sample startup' }
    $sample = [System.Diagnostics.Process]::new()
    $sample.StartInfo.FileName = $HelloXr
    $sample.StartInfo.Arguments = "-G $Graphics -s $AppSpace"
    $sample.StartInfo.UseShellExecute = $false
    $sample.StartInfo.RedirectStandardInput = $true
    $sample.StartInfo.RedirectStandardOutput = $true
    $sample.StartInfo.RedirectStandardError = $true
    # Keep stdin open: HelloXR exits as soon as it reads EOF.
    if (-not $sample.Start()) { throw 'Could not start HelloXR' }
    $sampleOut = $sample.StandardOutput.ReadToEndAsync()
    $sampleErr = $sample.StandardError.ReadToEndAsync()
    Start-Sleep -Seconds $Seconds
    if (-not $sample.HasExited -and [IO.Path]::GetFileName($HelloXr) -eq 'hello_xr.exe') {
        $sample.StandardInput.WriteLine('q')
        if (-not $sample.WaitForExit(3000)) {throw 'Hello XR did not close after its quit input'}
    }
    if ($sample.HasExited) { Write-Output "sample_exit=$($sample.ExitCode)" }
} finally {
    if ($sample -and $sample.Id -and -not $sample.HasExited) { $sample.Kill(); $sample.WaitForExit() }
    if ($sampleOut) { $sampleOut.Result | Set-Content (Join-Path $logDir 'sample.out') }
    if ($sampleErr) { $sampleErr.Result | Set-Content (Join-Path $logDir 'sample.err') }
    if ($service -and -not $service.HasExited) { Stop-Process -Id $service.Id -Force }
}
$log = Get-Content (Join-Path $logDir 'service.err')
$empty = @($log | Select-String 'METEOR_WINDOWS_CAPTURE_EMPTY').Count
$stereo = @($log | Select-String 'METEOR_WINDOWS_CAPTURE frame=').Count
$failed = @($log | Select-String 'METEOR_WINDOWS_CAPTURE_FAILED').Count
Write-Output "capture_hook_empty=$empty stereo_eye_logs=$stereo failed=$failed log=$logDir"
if ($failed -gt 0 -or ($empty + $stereo) -eq 0) { throw 'Windows capture hook did not run cleanly' }
if ($PixelProbe) {
    if (-not $sample.HasExited -or $sample.ExitCode -ne 0) { throw 'Stereo pixel probe did not exit successfully' }
    foreach ($name in 'capture-complete','server-eye-left.ppm','server-eye-right.ppm') {
        if (-not (Test-Path (Join-Path $logDir $name))) { throw "Missing stereo proof artifact: $name" }
    }
    Write-Output 'server_stereo_pixels=passed'
}
