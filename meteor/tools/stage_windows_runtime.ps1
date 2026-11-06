param([Parameter(Mandatory)][string]$Stage)
# Stage only runtime binaries/assets; never copy dev config, credentials or logs.
$ErrorActionPreference='Stop'
$meteor=Split-Path $PSScriptRoot
$target=Join-Path $meteor 'target'
$runtime=Join-Path $Stage 'runtime'
$bin=Join-Path $runtime 'xr\bin'
$hostDir=Join-Path $runtime 'host'
$licenses=Join-Path $Stage 'share\doc\nightfall-meteor\runtime'
New-Item -ItemType Directory -Force $bin,$hostDir,$licenses | Out-Null
function CopyRequired([string]$Source,[string]$Destination) {
    if(-not (Test-Path -LiteralPath $Source)){throw "Missing runtime input: $Source"}
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
}
$monado=Join-Path $target 'windows-monado-vcpkg-build'
CopyRequired "$monado\src\xrt\targets\service\Release\monado-service.exe" $bin
CopyRequired "$monado\src\xrt\targets\openxr\Release\openxr_monado.dll" $bin
foreach($file in 'cjson.dll','pthreadVCE3.dll','vulkan-1.dll') {
    CopyRequired "$monado\vcpkg_installed\x64-windows\bin\$file" $bin
}
foreach($file in 'meteor-windows-tracking.dll','meteor-windows-nvenc.dll') {
    CopyRequired "$target\windows-runtime-probe\Release\$file" $bin
}
CopyRequired "$target\windows-openxr-loader-build\src\loader\Release\openxr_loader.dll" $bin
CopyRequired "$target\windows-steamvr-build\Release\meteor-steamvr-mirror.exe" $bin
$xrizer=Join-Path $runtime 'xr\xrizer\bin'
New-Item -ItemType Directory -Force $xrizer | Out-Null
CopyRequired "$target\windows-xrizer-d3d11-src\target\release\bin\vrclient_x64.dll" $xrizer
$driver=Join-Path $runtime 'xr\steamvr\bin\win64'
New-Item -ItemType Directory -Force $driver | Out-Null
CopyRequired "$target\windows-steamvr-build\meteor\bin\win64\driver_meteor.dll" $driver
CopyRequired "$target\windows-steamvr-build\meteor\driver.vrdrivermanifest" (Split-Path (Split-Path $driver))
CopyRequired "$target\windows-vibepollo-src\build-meteor-windows\sunshine.exe" $hostDir
CopyRequired "$target\windows-vibepollo-src\build-meteor-windows\assets" $hostDir
$hostTools=Join-Path $hostDir 'tools'
New-Item -ItemType Directory -Force $hostTools | Out-Null
foreach($helper in 'sunshine_display_helper.exe','sunshine_wgc_capture.exe') {
    CopyRequired "$target\windows-vibepollo-src\build-meteor-windows\tools\$helper" $hostTools
}
$manifest=@{file_format_version='1.0.0';runtime=@{name='Monado';library_path='.\bin\openxr_monado.dll'}}
[IO.File]::WriteAllText((Join-Path $runtime 'xr\openxr_monado.json'),($manifest | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
# App-local Microsoft redistributable DLLs: no dependency on the build tools' PATH.
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs=& $vswhere -latest -products '*' -property installationPath
if($LASTEXITCODE -or -not $vs){throw 'Could not locate the Visual Studio redistributables'}
$crt=@(Get-ChildItem "$vs\VC\Redist\MSVC\*\x64\Microsoft.VC*.CRT" -Directory -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)
$omp=@(Get-ChildItem "$vs\VC\Redist\MSVC\*\x64\Microsoft.VC*.OpenMP" -Directory -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)
if(-not $crt.Count -or -not $omp.Count){throw 'Missing Visual Studio app-local CRT/OpenMP redistributables'}
foreach($dir in @($crt[0].FullName,$omp[0].FullName)) {
    foreach($file in Get-ChildItem $dir -Filter '*.dll' -File) {
        foreach($destination in @($Stage,$bin,$xrizer,$driver)) {CopyRequired $file.FullName $destination}
    }
}
CopyRequired (Join-Path $PSScriptRoot 'windows-release\Setup-Meteor.ps1') $Stage
CopyRequired (Join-Path $PSScriptRoot 'windows-release\Meteor-Cli.ps1') $Stage
CopyRequired (Join-Path $PSScriptRoot 'windows-release\Pair-Headset.ps1') $Stage
CopyRequired (Join-Path $PSScriptRoot 'windows-release\Install-SteamVR.ps1') $Stage
CopyRequired (Join-Path $PSScriptRoot 'windows-release\SteamVR-Driver.ps1') $Stage
foreach($component in @(
    @{name='Monado';source="$target\windows-monado-src\LICENSE"},
    @{name='xrizer';source="$target\windows-xrizer-d3d11-src\LICENSE"},
    @{name='Vibepollo';source="$target\windows-vibepollo-src\LICENSE"},
    @{name='Vibepollo-NOTICE';source="$target\windows-vibepollo-src\NOTICE"},
    @{name='OpenXR';source="$target\windows-openxr-sample\LICENSE"}
)) {CopyRequired $component.source (Join-Path $licenses ($component.name+'-LICENSE.txt'))}
CopyRequired "$target\windows-monado-src\LICENSES" (Join-Path $licenses 'Monado')
CopyRequired "$target\windows-openxr-sample\LICENSES" (Join-Path $licenses 'OpenXR')
$patches=Join-Path $licenses 'patches';New-Item -ItemType Directory -Force $patches | Out-Null
foreach($name in 'xrizer_windows_injection.patch','xrizer_windows_tests.patch','monado_windows_capture.patch','monado_windows_tracking.patch','monado_windows_controllers.patch','vibepollo_windows_multimonitor.patch') {
    CopyRequired (Join-Path (Split-Path $meteor) "test\$name") $patches
}
foreach($port in 'cjson','pthreads','vulkan-loader') {
    $source=Join-Path $monado "vcpkg_installed\x64-windows\share\$port\copyright"
    CopyRequired $source (Join-Path $licenses ($port+'-copyright.txt'))
}
$files=@(Get-ChildItem $runtime -Recurse -File | Where-Object {$_.FullName -ne (Join-Path $runtime 'manifest.json')} | ForEach-Object {
    @{path=$_.FullName.Substring($runtime.Length+1).Replace('\','/');bytes=$_.Length;sha256=(Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
})
$components=@{}
foreach($name in 'windows-monado-src','windows-xrizer-d3d11-src','windows-vibepollo-src') {
    $components[$name]=(& git -C (Join-Path $target $name) rev-parse HEAD)
    if($LASTEXITCODE){throw "Missing source revision for $name"}
}
$patchHashes=@{};foreach($file in Get-ChildItem $patches -File){$patchHashes[$file.Name]=(Get-FileHash $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
[IO.File]::WriteAllText((Join-Path $runtime 'manifest.json'),(@{format=1;components=$components;patches=$patchHashes;files=$files} | ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
Write-Host "Staged built-in host and Windows XR runtime ($($files.Count) files)."
