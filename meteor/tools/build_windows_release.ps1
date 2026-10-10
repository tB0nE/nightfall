# Build the Windows release zip. VDA and TensorRT remain tray downloads.
# Run from PowerShell: .\tools\build_windows_release.ps1 [-ModelsDir path] [-NcnnDir path]
param(
    [string]$ModelsDir = (Join-Path $env:LOCALAPPDATA 'Nightfall Meteor\models'),
    [string]$NcnnDir = ''
)

$ErrorActionPreference = 'Stop'
$meteor = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$repo = (Resolve-Path (Join-Path $meteor '..')).Path
$out = Join-Path $meteor 'target\windows-release'
$version = ([regex]::Match((Get-Content -LiteralPath (Join-Path $meteor 'Cargo.toml') -Raw), '(?m)^version = "([^"]+)"')).Groups[1].Value
if (-not $version) { throw 'Could not read the Meteor version from Cargo.toml' }
$name = "Nightfall-Meteor-$version-windows-x64"
$stage = Join-Path $out $name
$zip = Join-Path $out "$name.zip"
$edgepad = 'zipdepth_wide_512x288'
$ncnnVersion = '20260526'
$ncnnDllHash = 'd5709a0c84bdc6da1b1e2bd9151a529f083ff76264de60af9bacd0bee63db025'
$ncnnLicenseHash = '7c974bac98848df46be1af5bdaa3c3c9c01f6082a90f55caeb7f60c6208aa255'
$zipDepthLicenseHash = '0007e2ff761f1b89ad89327870b807cd4de00cb657b442b62de2f92fdc87d508'

function Assert-Hash([string]$Path, [string]$Expected) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing $Path" }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Expected) { throw "SHA-256 mismatch for $Path`nExpected $Expected`nActual   $actual" }
}

foreach ($extension in @('param', 'bin')) {
    $path = Join-Path $ModelsDir "$edgepad.ncnn.$extension"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing $path" }
}
$paramFile = Join-Path $ModelsDir "$edgepad.ncnn.param"
if (-not (Select-String -LiteralPath $paramFile -Pattern '^Input .* 0=512 1=288 2=3' -Quiet)) {
    throw "$paramFile has no 512x288 input size; convert it with models/convert_ncnn.py"
}

New-Item -ItemType Directory -Path $out -Force | Out-Null
if (-not $NcnnDir) {
    $NcnnDir = Join-Path $out 'ncnn-20260526'
    $dll = Join-Path $NcnnDir 'ncnn.dll'
    $licence = Join-Path $NcnnDir 'LICENSE.txt'
    if (-not ((Test-Path -LiteralPath $dll) -and (Test-Path -LiteralPath $licence))) {
        $archive = Join-Path $out "ncnn-$ncnnVersion-windows-vs2022-shared.zip"
        $extract = Join-Path $out 'ncnn-extract'
        Write-Host "Downloading ncnn $ncnnVersion from Tencent"
        Invoke-WebRequest -Uri "https://github.com/Tencent/ncnn/releases/download/$ncnnVersion/ncnn-$ncnnVersion-windows-vs2022-shared.zip" -OutFile $archive
        if (Test-Path -LiteralPath $extract) { Remove-Item -LiteralPath $extract -Recurse -Force }
        Expand-Archive -LiteralPath $archive -DestinationPath $extract
        $downloadedDll = Get-ChildItem -Path $extract -Recurse -Filter ncnn.dll -File |
            Where-Object { $_.FullName -match '[\\/]x64[\\/]bin[\\/]ncnn\.dll$' } |
            Select-Object -First 1
        if (-not $downloadedDll) { throw 'The ncnn archive has no x64/bin/ncnn.dll' }
        Assert-Hash $downloadedDll.FullName $ncnnDllHash
        New-Item -ItemType Directory -Path $NcnnDir -Force | Out-Null
        Copy-Item -LiteralPath $downloadedDll.FullName -Destination $dll
        Invoke-WebRequest -Uri "https://raw.githubusercontent.com/Tencent/ncnn/$ncnnVersion/LICENSE.txt" -OutFile $licence
    }
}
$ncnnDll = Join-Path $NcnnDir 'ncnn.dll'
$ncnnLicence = Join-Path $NcnnDir 'LICENSE.txt'
Assert-Hash $ncnnDll $ncnnDllHash
Assert-Hash $ncnnLicence $ncnnLicenseHash
$zipDepthLicence = Join-Path $out 'ZipDepth-LICENSE.txt'
if (-not (Test-Path -LiteralPath $zipDepthLicence)) {
    Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/fabiotosi92/ZipDepth/main/LICENSE' -OutFile $zipDepthLicence
}
Assert-Hash $zipDepthLicence $zipDepthLicenseHash

Push-Location $meteor
try {
    Write-Host 'Building Meteor (release, without ONNX Runtime)'
    & cargo build --release --locked --no-default-features
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed ($LASTEXITCODE)" }

    if (-not (Get-Command cargo-about -ErrorAction SilentlyContinue)) {
        Write-Host 'Installing cargo-about 0.9.2 for Rust crate notices'
        & cargo install --locked --features cli cargo-about@0.9.2
        if ($LASTEXITCODE -ne 0) { throw "cargo-about install failed ($LASTEXITCODE)" }
    }
    Write-Host 'Generating Rust crate licence notices'
    $crateNoticesPath = Join-Path $out 'crates.txt'
    & cargo about generate --no-default-features --fail -c tools/appimage/about.toml -o $crateNoticesPath tools/appimage/about.hbs
    if ($LASTEXITCODE -ne 0) { throw "cargo about failed ($LASTEXITCODE)" }
} finally {
    Pop-Location
}

if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
$models = Join-Path $stage 'share\nightfall-meteor\models'
$doc = Join-Path $stage 'share\doc\nightfall-meteor'
New-Item -ItemType Directory -Path $models, $doc -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $meteor 'target\release\nightfall-meteor.exe'), $ncnnDll -Destination $stage
Copy-Item -LiteralPath (Join-Path $ModelsDir "$edgepad.ncnn.param"), (Join-Path $ModelsDir "$edgepad.ncnn.bin") -Destination $models
Copy-Item -LiteralPath (Join-Path $repo 'LICENSE') -Destination $doc
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'windows-release\README.txt') -Destination $stage

$opus = @(Get-ChildItem -Path (Join-Path $env:USERPROFILE '.cargo\registry\src\*\audiopus_sys-*\opus\COPYING') -File -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending | Select-Object -First 1)
if (-not $opus) { throw 'Missing libopus COPYING in the Cargo registry' }
$notices = @(
    "Nightfall Meteor $version is free software under the GNU GPL v3 (LICENSE)."
    'It includes the components below, under their own licences.'
    ''
    "- ncnn $ncnnVersion (Tencent), BSD 3-Clause: ncnn.dll"
    '- EdgePad 512x288 weights: Nightfall fine-tune of ZipDepth (Fabio Tosi), MIT: share/nightfall-meteor/models'
    '- NVIDIA TensorRT headers, Apache 2.0, compiled into the TensorRT shim'
    '- libopus (Xiph.Org Foundation and others), BSD 3-Clause, compiled into Meteor for microphone audio'
    '- Rust crates listed at the end'
    ''
    'Video Depth Anything downloads NVIDIA TensorRT from NVIDIA under its licence:'
    'https://docs.nvidia.com/deeplearning/tensorrt/latest/reference/sla.html'
    'The VDA graphs are Apache 2.0. Neither ships in this zip.'
    ''
    '========================================================================== ncnn'
    (Get-Content -LiteralPath $ncnnLicence -Raw)
    '========================================================================== ZipDepth'
    (Get-Content -LiteralPath $zipDepthLicence -Raw)
    '========================================================================== NVIDIA TensorRT headers'
    (Get-Content -LiteralPath (Join-Path $meteor 'third_party\tensorrt\LICENSE') -Raw)
    '========================================================================== libopus'
    (Get-Content -LiteralPath $opus[0].FullName -Raw)
    '========================================================================== Rust crates'
    (Get-Content -LiteralPath $crateNoticesPath -Raw)
)
Set-Content -LiteralPath (Join-Path $doc 'THIRD_PARTY_NOTICES.txt') -Value $notices -Encoding UTF8

if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -LiteralPath $stage -DestinationPath $zip -CompressionLevel Optimal
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "$zip ($([math]::Round((Get-Item -LiteralPath $zip).Length / 1MB, 1)) MiB)"
Write-Host "SHA-256 $hash"
