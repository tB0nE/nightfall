param(
    [string]$Source = (Join-Path $PSScriptRoot '..\meteor\target\windows-xrizer-d3d11-src'),
    [string]$LibClang = 'C:\Program Files\LLVM\bin',
    [string]$VulkanSdk = $env:VULKAN_SDK
)

# Experimental native Windows baseline. Keep the fork revision explicit: this
# is not the upstream Linux pin, and successful builds do not prove game support.
$ErrorActionPreference = 'Stop'
$repository = 'https://github.com/webhead2oo9/xrizer.git'
$revision = 'ee62d2647bb84dd0969be91a6ff430bba4f72090'
if (-not (Test-Path (Join-Path $LibClang 'libclang.dll'))) {
    throw "Missing libclang.dll in $LibClang. Install LLVM or pass -LibClang."
}
if (-not $VulkanSdk) {
    $sdk = Get-ChildItem 'C:\VulkanSDK' -Directory -ErrorAction SilentlyContinue |
        Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
    if ($sdk) { $VulkanSdk = $sdk.FullName }
}
if (-not $VulkanSdk -or -not (Test-Path (Join-Path $VulkanSdk 'Bin\glslc.exe'))) {
    throw 'Missing Vulkan SDK glslc.exe. Install the Vulkan SDK or pass -VulkanSdk.'
}
if (-not (Test-Path $Source)) {
    & git clone --branch feat/windows-d3d11 --single-branch $repository $Source
    if ($LASTEXITCODE -ne 0) { throw 'Could not clone the Windows xrizer fork' }
    & git -C $Source checkout --detach $revision
    if ($LASTEXITCODE -ne 0) { throw 'Could not select the pinned Windows xrizer revision' }
}
$head = & git -C $Source rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $head -ne $revision) {
    throw "Expected xrizer revision $revision in $Source; refusing to change an existing checkout."
}
$testPatch = Join-Path $PSScriptRoot 'xrizer_windows_tests.patch'
$runtimePatch = Join-Path $PSScriptRoot 'xrizer_windows_injection.patch'
$changes = & git -C $Source status --porcelain
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect xrizer checkout' }
if ($changes) {
    # Only the exact tracked test-fixture patch is permitted on repeated runs.
    $actual = ((& git -C $Source diff --no-ext-diff -- src/graphics_backends.rs src/openxr_data.rs) | Where-Object { $_ -notmatch '^index ' }) -join "`n"
    $expected = (Get-Content $testPatch) -join "`n"
    $other = @($changes | Where-Object { $_ -notmatch '^ M src/(graphics_backends\.rs|openxr_data\.rs|clientcore\.rs)$' })
    if ($actual.Trim() -ne $expected.Trim() -or $other.Count) { throw 'Unexpected local changes in xrizer checkout' }
} else {
    & git -C $Source apply --check $testPatch
    if ($LASTEXITCODE -ne 0) { throw 'The pinned xrizer test-fixture patch does not apply' }
    & git -C $Source apply $testPatch
    if ($LASTEXITCODE -ne 0) { throw 'Could not apply xrizer test-fixture patch' }
}
$actual=((& git -C $Source diff --no-ext-diff -- src/clientcore.rs) | Where-Object {$_ -notmatch '^index '}) -join "`n"
if($actual.Trim()) {
    $expected=((Get-Content $runtimePatch) | Where-Object {$_ -notmatch '^index '}) -join "`n"
    if($actual.Trim() -ne $expected.Trim()){throw 'Unexpected xrizer interface-cache changes'}
} else {
    & git -C $Source apply --check $runtimePatch
    if($LASTEXITCODE){throw 'Interface-cache race patch does not apply'}
    & git -C $Source apply $runtimePatch
    if($LASTEXITCODE){throw 'Could not apply interface-cache race patch'}
}
$Source = (Resolve-Path $Source).Path
$previousPath = $env:PATH
$previousClang = $env:LIBCLANG_PATH
$previousVersion = $env:XRIZER_VERSION
Push-Location $Source
try {
    $env:PATH = "$LibClang;$(Join-Path $VulkanSdk 'Bin');$previousPath"
    $env:LIBCLANG_PATH = $LibClang
    $env:XRIZER_VERSION = "nightfall-windows-$($revision.Substring(0,12))"
    # Build the packaging helper in Release too; cargo xbuild's alias otherwise
    # builds that helper in the development profile.
    & cargo run --release --locked -p xbuild -- --release --locked --no-default-features
    if ($LASTEXITCODE -ne 0) { throw 'Windows xrizer release build failed' }
    $runtime = Join-Path $Source 'target\release\bin\vrclient_x64.dll'
    if (-not (Test-Path $runtime)) { throw "Missing runtime DLL: $runtime" }
    & cargo test --release --locked --no-default-features -p xrizer --lib
    if ($LASTEXITCODE -ne 0) { throw 'Windows xrizer release tests failed' }
    [ordered]@{
        repository = $repository
        revision = $revision
        test_fixture_patch = (Get-FileHash $testPatch -Algorithm SHA256).Hash.ToLowerInvariant()
        runtime_patch = (Get-FileHash $runtimePatch -Algorithm SHA256).Hash.ToLowerInvariant()
        profile = 'release'
        runtime = $runtime
        sha256 = (Get-FileHash $runtime -Algorithm SHA256).Hash.ToLowerInvariant()
        library_tests_passed = $true
        game_compatibility_tested = $false
    } | ConvertTo-Json | Set-Content (Join-Path $Source 'target\release\nightfall-build.json') -Encoding UTF8
    Write-Output "Windows xrizer release runtime: $runtime"
} finally {
    Pop-Location
    $env:PATH = $previousPath
    $env:LIBCLANG_PATH = $previousClang
    $env:XRIZER_VERSION = $previousVersion
}
