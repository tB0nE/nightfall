param([string]$Runtime='')
# Older Valve loaders ignore VR_PATHREG_OVERRIDE and require the standard
# per-user registry even with VR_OVERRIDE. Never replace an existing registry.
$ErrorActionPreference='Stop'
if(-not $Runtime) {$Runtime=Join-Path (Split-Path $PSScriptRoot) 'meteor\target\windows-xrizer-d3d11-src\target\release'}
$Runtime=(Resolve-Path $Runtime).Path
if(-not (Test-Path (Join-Path $Runtime 'bin\vrclient_x64.dll'))) {throw 'Missing Windows OpenVR runtime DLL'}
$directory=Join-Path $env:LOCALAPPDATA 'openvr'
$path=Join-Path $directory 'openvrpaths.vrpath'
if(Test-Path $path) {
    $existing=Get-Content $path -Raw | ConvertFrom-Json
    if($existing.version -ne 1 -or -not $existing.runtime) {throw "Existing OpenVR registry is invalid; preserved $path"}
    Write-Output "Existing OpenVR registry preserved: $path"
    return
}
$config=Join-Path $env:LOCALAPPDATA 'xrizer\config'
$logs=Join-Path $env:LOCALAPPDATA 'xrizer\logs'
New-Item -ItemType Directory -Force $directory,$config,$logs | Out-Null
$value=[ordered]@{jsonid='vrpathreg';version=1;runtime=@($Runtime);config=@($config);log=@($logs);external_drivers=$null}
$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($value | ConvertTo-Json))
$file=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try {$file.Write($bytes,0,$bytes.Length)} finally {$file.Dispose()}
Write-Output "Registered the Windows xrizer OpenVR runtime: $path"
