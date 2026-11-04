param([string]$Application='C:\Program Files (x86)\Steam\steamapps\common\VRChat\start_protected_game.exe',
    [string[]]$ApplicationArguments=@(),[uint32]$SteamAppId=438100)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
$target=Join-Path $repo 'meteor\target'
$root=Join-Path $target 'windows-xr-steamvr'
$config=Get-Content "$target\windows-xr-dev\xr-windows.json" -Raw | ConvertFrom-Json
$config.service=(Resolve-Path "$target\windows-steamvr-build\Release\meteor-steamvr-mirror.exe").Path
$config.application=(Resolve-Path $Application).Path
$config.arguments=@($ApplicationArguments)
$config.pixel_probe=$false
$config | Add-Member NoteProperty steamvr_driver ((Resolve-Path "$target\windows-steamvr-build\meteor").Path) -Force
$config | Add-Member NoteProperty openvr_runtime ((Resolve-Path 'C:\Program Files (x86)\Steam\steamapps\common\SteamVR').Path) -Force
$config | Add-Member NoteProperty steam_launch $false -Force
$config | Add-Member NoteProperty steamvr_capture 'direct' -Force
$config | Add-Member NoteProperty steam_app_id "$SteamAppId" -Force
$config.PSObject.Properties.Remove('openvr_loader')
New-Item -ItemType Directory -Force $root | Out-Null
$file=Join-Path $root 'xr-windows.json'
if(Test-Path $file) {Copy-Item $file "$file.previous" -Force}
[IO.File]::WriteAllText($file,($config | ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
Write-Output "steamvr_runtime_root=$root"
Write-Output 'The separate trial configuration is ready. The default Monado configuration was preserved.'
