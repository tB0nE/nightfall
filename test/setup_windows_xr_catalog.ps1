param([string]$Root='', [string]$Executable='', [switch]$Enable)
# Import the already built/tested runtimes into the normal native catalog.
# Binary distribution/download is separate: these profiles reference local builds.
$ErrorActionPreference='Stop'
$target=Join-Path (Split-Path $PSScriptRoot) 'meteor\target'
if(-not $Root){$Root=Join-Path $env:LOCALAPPDATA 'Nightfall Meteor\xr\windows'}
if(-not $Executable){$Executable=Join-Path $target 'release\nightfall-meteor-xr-dev.exe'}
$Executable=(Resolve-Path $Executable).Path
$monado=Get-Content "$target\windows-xr-dev\xr-windows.json" -Raw | ConvertFrom-Json
$steamvr=Get-Content "$target\windows-xr-steamvr\xr-windows.json" -Raw | ConvertFrom-Json
$moss='C:\Program Files (x86)\Steam\steamapps\common\Moss'
$monado.application=(Resolve-Path "$moss\Moss\Binaries\Win64\Moss-Win64-Shipping.exe").Path
$monado.arguments=@('-vr','-dx11','-hmd=SteamVR')
$monado | Add-Member NoteProperty openvr_runtime ((Resolve-Path "$target\windows-xrizer-d3d11-src\target\release").Path) -Force
$monado | Add-Member NoteProperty openvr_loader ((Resolve-Path "$moss\Engine\Binaries\ThirdParty\OpenVR\OpenVRv1_5_17\Win64\openvr_api.dll").Path) -Force
$monado.library_dirs=@($monado.library_dirs)+@((Resolve-Path "$target\windows-openxr-loader-build\src\loader\Release").Path)
$monado | Add-Member NoteProperty steam_app_id '846470' -Force
$monado | Add-Member NoteProperty steam_launch $false -Force
$monado.pixel_probe=$false
foreach($item in @(@{name='Moss';id='846470';config=$monado},@{name='VRChat';id='438100';config=$steamvr})) {
    $profile=Join-Path $Root "profiles\$($item.id)"
    New-Item -ItemType Directory -Force $profile | Out-Null
    $path=Join-Path $profile 'xr-windows.json'
    if(Test-Path $path){Copy-Item $path "$path.previous" -Force}
    [IO.File]::WriteAllText($path,($item.config | ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
    & $Executable --xr-windows-register --root $Root --profile $profile --name $item.name
    if($LASTEXITCODE){throw "Could not register $($item.name)"}
}
if($Enable) {
    & $Executable --xr-windows-enable --root $Root
    if($LASTEXITCODE){throw 'Could not enable Windows XR'}
}
Write-Output "catalog_root=$Root"
Write-Output 'Profiles reference prepared runtime builds. Run Meteor normally to use the native PCVR catalog.'
