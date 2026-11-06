param(
    [uint32]$SteamAppId=438100,
    [string]$Root='',
    [string]$OpenVrRuntime='',
    [string]$OpenVrLoader=''
)
# Prepare an isolated DEV configuration and copyable Steam launch options.
# Does not edit Steam's userdata, system OpenXR registration, or the Quest.
$ErrorActionPreference='Stop'
$target=Join-Path (Split-Path $PSScriptRoot) 'meteor\target'
if(-not $Root) {$Root=Join-Path $target 'windows-xr-steam'}
if(-not $OpenVrRuntime) {$OpenVrRuntime=Join-Path $target 'windows-xrizer-d3d11-src\target\release'}
if(-not $SteamAppId) {throw 'A nonzero Steam app ID is required'}
$runtime=(Resolve-Path $OpenVrRuntime).Path
$loader=Join-Path $target 'windows-openxr-loader-build\src\loader\Release'
if(-not (Test-Path (Join-Path $runtime 'bin\vrclient_x64.dll'))) {throw 'Build Windows xrizer first'}
if(-not (Test-Path (Join-Path $loader 'openxr_loader.dll'))) {throw 'Build the shared OpenXR loader first'}
New-Item -ItemType Directory -Force $Root | Out-Null
$Root=(Resolve-Path $Root).Path
$path=Join-Path $Root 'xr-windows.json'
if(Test-Path $path) {Copy-Item $path ($path+'.backup-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fffffff'))}
$config=Get-Content (Join-Path $target 'windows-xr-dev\xr-windows.json') -Raw | ConvertFrom-Json
$config.pixel_probe=$false
$config | Add-Member -MemberType NoteProperty -Name steam_launch -Value $true -Force
$config | Add-Member -MemberType NoteProperty -Name steam_app_id -Value "$SteamAppId" -Force
$config | Add-Member -MemberType NoteProperty -Name openvr_runtime -Value $runtime -Force
if($OpenVrLoader) {$config | Add-Member -MemberType NoteProperty -Name openvr_loader -Value ((Resolve-Path $OpenVrLoader).Path) -Force}
$config.library_dirs=@($config.library_dirs)+@($loader)
[IO.File]::WriteAllText($path,($config | ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
$options=& (Join-Path $target 'release\nightfall-meteor-xr-dev.exe') --xr-steam-options --root $Root
if($LASTEXITCODE) {throw 'Could not generate Windows Steam launch options'}
[IO.File]::WriteAllText((Join-Path $Root 'steam-launch-options.txt'),($options+"`r`n"),[Text.UTF8Encoding]::new($false))
Write-Output $options
Write-Output "Prepared Steam app $SteamAppId in $Root. Start the XR test service with -RuntimeRoot `"$Root`"."
