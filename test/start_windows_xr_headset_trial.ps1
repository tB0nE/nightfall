param([ValidateRange(1,21600)][int]$Frames = 240, [switch]$Scene, [switch]$AsyncDelivery=$true,
    [string]$HostAddress='127.0.0.1',[string]$HeadsetPublicKey='',[string]$RuntimeRoot='')
$ErrorActionPreference = 'Stop'
$address=[Net.IPAddress]::Parse($HostAddress)
if($address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $address.Equals([Net.IPAddress]::Any)) {throw 'Use a specific IPv4 host address'}
$HostAddress=$address.ToString()
$usb=[Net.IPAddress]::IsLoopback($address)
$repo = Split-Path $PSScriptRoot
$target = Join-Path $repo 'meteor\target'
$root = Join-Path $target 'windows-xr-dev'
if($RuntimeRoot) {$root=(Resolve-Path $RuntimeRoot).Path}
$key = Join-Path $env:LOCALAPPDATA 'Nightfall Meteor\meteor.key'
$bridge = Join-Path $PSScriptRoot 'windows_nf_bridge.ps1'
$env:XRT_NO_STDIN = '1'
$env:METEOR_PROBE_HOLD_MS = '2000'
$env:METEOR_CONTINUOUS_FRAMES = "$Frames"
if($AsyncDelivery) {$env:METEOR_XR_ASYNC_DELIVERY='1'}
else {Remove-Item Env:METEOR_XR_ASYNC_DELIVERY -ErrorAction SilentlyContinue}
$configPath = Join-Path $root 'xr-windows.json'
$config = Get-Content $configPath -Raw | ConvertFrom-Json
$config.pixel_probe = -not $Scene
$config | Add-Member -MemberType NoteProperty -Name async_delivery -Value ([bool]$AsyncDelivery) -Force
[IO.File]::WriteAllText($configPath,($config | ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
if ($Scene) {
    $env:METEOR_XR_FREE_RUNNING = '1'
    $env:METEOR_XR_GPU_MEASURE = '1'
    $env:METEOR_XR_GPU_SCENE_SHADER = Join-Path $target 'windows-runtime-probe\meteor_gpu_scene.spv'
    $env:METEOR_XR_OBSERVE_INPUT = '1'
} else {
    foreach ($name in 'METEOR_XR_FREE_RUNNING','METEOR_XR_GPU_MEASURE','METEOR_XR_GPU_SCENE_SHADER','METEOR_XR_OBSERVE_INPUT') {
        Remove-Item "Env:$name" -ErrorAction SilentlyContinue
    }
}
$identity=$HeadsetPublicKey.ToLowerInvariant()
if(-not $identity) {$identity = (& $bridge -Request '{"cmd":"eval","expr":"welcome_screen.get_xr_control().public_identity()"}' | ConvertFrom-Json).value}
if ($identity -notmatch '^[0-9a-f]{64}$') { throw 'Headset public identity unavailable' }
$adb = Join-Path $target 'windows-platform-tools\platform-tools\adb.exe'
if($usb) {
    foreach ($port in 49100,49101,49102) {
        & $adb reverse "tcp:$port" "tcp:$port"
        if ($LASTEXITCODE -ne 0) { throw "ADB reverse failed for $port" }
    }
}
$args = @('--xr-control-dev',"${HostAddress}:49100",('"{0}"' -f $key),$identity,'--relay',('"{0}"' -f $root),'--ports','49101','49102')
$process = Start-Process (Join-Path $target 'release\nightfall-meteor-xr-dev.exe') -ArgumentList $args -PassThru `
    -RedirectStandardOutput (Join-Path $target 'windows-xr-control.out') `
    -RedirectStandardError (Join-Path $target 'windows-xr-control.err')
Write-Output "xr_service_pid=$($process.Id) host=$HostAddress usb_reverse=$usb control=49100 video=49101 tracking=49102"
