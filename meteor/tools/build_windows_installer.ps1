# Build the portable release and compile a per-user Inno Setup installer.
# Run from PowerShell: .\tools\build_windows_installer.ps1 [-ModelsDir path] [-NcnnDir path]
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
$stage = Join-Path $out "Nightfall-Meteor-$version-windows-x64"

$compiler = Get-Command ISCC.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1
if (-not $compiler) {
    foreach ($candidate in @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 7\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 7\ISCC.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 7\ISCC.exe')
    )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            $compiler = $candidate
            break
        }
    }
}
if (-not $compiler) {
    throw 'Install Inno Setup 7 first: winget install --id JRSoftware.InnoSetup.7 -e -s winget'
}

& (Join-Path $PSScriptRoot 'build_windows_release.ps1') -ModelsDir $ModelsDir -NcnnDir $NcnnDir
if (-not (Test-Path -LiteralPath (Join-Path $stage 'nightfall-meteor.exe'))) {
    throw "Missing release folder $stage"
}

$script = Join-Path $PSScriptRoot 'windows-release\Meteor.iss'
Write-Host 'Compiling Nightfall Meteor installer'
& $compiler "/DAppVersion=$version" "/DStage=$stage" "/DRepoRoot=$repo" "/DOutput=$out" $script
if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed ($LASTEXITCODE)" }
$installer = Join-Path $out "Nightfall-Meteor-$version-Setup-x64.exe"
if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) { throw "Missing $installer" }
$hash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "$installer ($([math]::Round((Get-Item -LiteralPath $installer).Length / 1MB, 1)) MiB)"
Write-Host "SHA-256 $hash"
