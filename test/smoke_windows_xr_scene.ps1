param([ValidateSet(512,1024,2048)][int]$EyeSize=2048,[ValidateRange(5,30)][int]$Seconds=10,[switch]$ObserveInput,
    [switch]$HelloXr,[ValidateSet('Vulkan','D3D11','D3D12')][string]$Graphics='Vulkan',
    [ValidateSet('Local','Stage','View')][string]$AppSpace='Local')
# Native capture/encode/delivery check without a headset. This does not test
# Android decoding, headset presentation, or physical controller interaction.
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
$root=Join-Path $repo 'meteor\target\windows-runtime-probe'
$output=Join-Path $root 'local-scene'
New-Item -ItemType Directory -Force $output | Out-Null
Remove-Item (Join-Path $output 'capture-complete') -ErrorAction SilentlyContinue
$env:METEOR_WINDOWS_ENCODER=Join-Path $root 'Release\meteor-windows-nvenc.dll'
$env:METEOR_TRACKING_BRIDGE=Join-Path $root 'Release\meteor-windows-tracking.dll'
$env:METEOR_XR_HEADSET_OPTICS='1'
$env:METEOR_XR_TRACKED_SCENE='1'
$env:METEOR_XR_GPU_MEASURE='1'
$env:METEOR_XR_GPU_SCENE_SHADER=Join-Path $root 'meteor_gpu_scene.spv'
$env:METEOR_XR_EYE_SIZE="$EyeSize"
$env:METEOR_XR_EYE_HEIGHT="$EyeSize"
$env:XRT_COMPOSITOR_NULL_FPS='72'
$env:XRT_NO_STDIN='1'
$env:METEOR_XR_FREE_RUNNING='1'
$env:METEOR_XR_ASYNC_DELIVERY='1'
$env:METEOR_CONTINUOUS_FRAMES="$($Seconds*72)"
$env:METEOR_PROBE_OUTPUT=$output
foreach($name in 'METEOR_WINDOWS_PIXEL_PROBE','METEOR_CONTROLLER_FIXTURE','METEOR_XR_OBSERVE_INPUT','METEOR_PROBE_HOLD_MS') {
    Remove-Item "Env:$name" -ErrorAction SilentlyContinue
}
if($ObserveInput) {
    $env:METEOR_XR_OBSERVE_INPUT='1'
    $env:METEOR_XR_CONTROLLERS='1'
    $env:METEOR_XR_TOUCH_INPUTS='1'
    $env:SIMULATED_LEFT='touch'
    $env:SIMULATED_RIGHT='touch'
}
$publisher=$null;$sink=$null
function WaitPort([string]$Log,[string]$Pattern,[Diagnostics.Process]$Process) {
    for($attempt=0;$attempt -lt 100;$attempt++) {
        if($Process.HasExited) {throw "Fixture exited; check $Log and its stderr"}
        if((Get-Content $Log -Raw) -match $Pattern) {return $Matches[1]}
        Start-Sleep -Milliseconds 50
    }
    throw "Fixture did not publish its port: $Log"
}
try {
    $publisher=Start-Process (Join-Path $root 'Release\meteor-tracking-socket.exe') -ArgumentList '--serve','0' -PassThru `
        -RedirectStandardOutput (Join-Path $output 'tracking.out') -RedirectStandardError (Join-Path $output 'tracking.err')
    $sinkArgs=@('0',(Join-Path $output 'received.h264'))
    if($HelloXr -and $AppSpace -eq 'View') {$sinkArgs+='0.5'}
    $sink=Start-Process (Join-Path $root 'Release\meteor-xr-wire-sink.exe') -PassThru `
        -ArgumentList $sinkArgs `
        -RedirectStandardOutput (Join-Path $output 'delivery.out') -RedirectStandardError (Join-Path $output 'delivery.err')
    $publisherHandle=$publisher.Handle;$sinkHandle=$sink.Handle
    $env:METEOR_TRACKING_PORT=WaitPort (Join-Path $output 'tracking.out') 'loopback:(\d+)' $publisher
    $env:METEOR_XR_DIRECT_PORT=WaitPort (Join-Path $output 'delivery.out') 'wire_sink_port=(\d+)' $sink
    $application=Join-Path $root 'Release\meteor-runtime-probe.exe'
    if($HelloXr) {$application=Join-Path $repo 'meteor\target\windows-openxr-sample-build\src\tests\hello_xr\Release\hello_xr.exe'}
    $result=& (Join-Path $PSScriptRoot 'smoke_monado_windows.ps1') `
        -HelloXr $application -Seconds ($Seconds+5) -Graphics $Graphics -AppSpace $AppSpace
    $result | Write-Output
    if(-not ($result -match '^sample_exit=0$')) {throw 'GPU scene did not exit successfully'}
    if(-not $sink.WaitForExit(5000)) {throw 'Local scene receiver did not acknowledge END'}
    $sink.WaitForExit()
    if($sink.ExitCode -ne 0) {Get-Content (Join-Path $output 'delivery.err');throw 'Local scene wire validation failed'}
    Get-Content (Join-Path $output 'delivery.out') | Select-Object -Last 1
    if($ObserveInput) {
        $appLog=Get-Content (Join-Path $repo 'meteor\target\windows-monado-vcpkg-build\meteor-windows-smoke\sample.out') -Raw
        foreach($hand in 0,1) {foreach($action in 'stick_click','by_click') {
            if($appLog -notmatch "APP_INPUT hand=$hand action=$action active=1 value=1") {
                throw "Scene input observer did not see synthetic hand=$hand action=$action"
            }
        }}
        Write-Output 'PASS: scene observer sees both synthetic controllers through live OpenXR actions'
    }
    if($HelloXr) {Write-Output "application=hello_xr graphics=$Graphics eye_size=$EyeSize duration_s=$($Seconds+5) artifacts=$output"}
    else {Write-Output "local_scene_eye_size=$EyeSize target_hz=72 source_frames=$($Seconds*72) artifacts=$output"}
} finally {
    foreach($process in @($sink,$publisher)) {
        if($process -and -not $process.HasExited) {Stop-Process -Id $process.Id}
    }
}
