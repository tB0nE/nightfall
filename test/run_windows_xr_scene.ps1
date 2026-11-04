param([ValidateSet(0,512,1024,2048,2560)][int]$EyeSize=0, [ValidateRange(5,300)][int]$Seconds=30, [switch]$AsyncDelivery=$true,
    [ValidateSet(-1,0,16,32,48,64,80,100,120,160)][int]$BitrateMbps=-1,
    [string]$Application='', [string[]]$ApplicationArguments=@('-vr','-openxr','-dx11'), [uint32]$SteamAppId=0,
    [string]$OpenVrRuntime='',
    [string]$OpenVrLoader='',
    [string]$RuntimeRoot='',
    [string]$HostAddress='127.0.0.1')
$ErrorActionPreference='Stop'
$bridge=Join-Path $PSScriptRoot 'windows_nf_bridge.ps1'
function Eval([string]$Expression) {
    $reply=& $bridge -Request (@{cmd='eval';expr=$Expression} | ConvertTo-Json -Compress) | ConvertFrom-Json
    if (-not $reply.ok) {throw $reply.error}
    return $reply.value
}
$saved=$false
$autoSaved=$false
$gpuMonitor=$null
$runtimeConfigPath=Join-Path (Split-Path $PSScriptRoot) 'meteor\target\windows-xr-dev\xr-windows.json'
if($RuntimeRoot) {$runtimeConfigPath=Join-Path (Resolve-Path $RuntimeRoot).Path 'xr-windows.json'}
$originalRuntimeConfig=$null
try {
    $controlState=Eval 'welcome_screen.get_xr_control().state'
    if ($controlState -notin @('idle','failed','connecting','watching') -or
        (Eval 'pcvr_test.backend.get_test_status().get("state","idle")') -ne 'idle') {throw 'Another XR session is active'}
    Eval 'set_meta("windows_scene_original_auto_suppressed",welcome_screen.get("_auto_suppressed"))' | Out-Null
    $autoSaved=$true
    Eval 'welcome_screen.set("_auto_suppressed",true)' | Out-Null
    Eval 'welcome_screen.get_xr_control().cancel()' | Out-Null
    Get-Process nightfall-meteor-xr-dev -ErrorAction SilentlyContinue | Stop-Process
    if($Application) {
        $originalRuntimeConfig=Get-Content $runtimeConfigPath -Raw
        $runtimeConfig=$originalRuntimeConfig | ConvertFrom-Json
        $runtimeConfig.application=(Resolve-Path $Application).Path
        $runtimeConfig.arguments=@($ApplicationArguments)
        $runtimeConfig | Add-Member -MemberType NoteProperty -Name steam_launch -Value $false -Force
        if($OpenVrRuntime) {
            $runtime=(Resolve-Path $OpenVrRuntime).Path
            if(-not (Test-Path (Join-Path $runtime 'bin\vrclient_x64.dll'))) {throw 'Missing Windows OpenVR runtime'}
            $runtimeConfig | Add-Member -MemberType NoteProperty -Name openvr_runtime -Value $runtime -Force
            $runtimeConfig.library_dirs=@($runtimeConfig.library_dirs)+@((Join-Path (Split-Path $PSScriptRoot) 'meteor\target\windows-openxr-loader-build\src\loader\Release'))
        }
        if($OpenVrLoader) {$runtimeConfig | Add-Member -MemberType NoteProperty -Name openvr_loader -Value ((Resolve-Path $OpenVrLoader).Path) -Force}
        [IO.File]::WriteAllText($runtimeConfigPath,($runtimeConfig | ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
        if($SteamAppId) {$env:SteamAppId="$SteamAppId";$env:SteamGameId="$SteamAppId"}
    }
    & (Join-Path $PSScriptRoot 'start_windows_xr_headset_trial.ps1') -Scene -Frames ($Seconds*72) -AsyncDelivery:$AsyncDelivery -HostAddress $HostAddress -RuntimeRoot $RuntimeRoot
    $serviceLog=Join-Path (Split-Path $PSScriptRoot) 'meteor\target\windows-xr-control.out'
    $hostKey=''
    for($attempt=0;$attempt -lt 20;$attempt++) {
        $text=Get-Content $serviceLog -Raw
        if($text -match 'pinned host key ([0-9a-f]{64})') {$hostKey=$Matches[1];break}
        Start-Sleep -Milliseconds 100
    }
    if(-not $hostKey) {throw 'Could not read isolated service public identity'}
    Eval 'set_meta("windows_scene_original_video",welcome_screen.get_xr_control().get_script().get_script_constant_map()["PCVRVideoSettings"].new(false))' | Out-Null
    Eval 'get_meta("windows_scene_original_video").load_from()' | Out-Null
    $saved=$true
    Eval 'set_meta("windows_scene_original_config",welcome_screen.get_xr_control().get("_discovered_config"))' | Out-Null
    Eval 'set_meta("windows_scene_video",welcome_screen.get_xr_control().get_script().get_script_constant_map()["PCVRVideoSettings"].new(false))' | Out-Null
    Eval 'get_meta("windows_scene_video").load_from()' | Out-Null
    # Follow saved client resolution/bitrate unless a diagnostic override was
    # explicitly requested. Windows DEV still requires non-foveated H.264.
    if($EyeSize -gt 0) {
        Eval ('[get_meta("windows_scene_video").set("eye_size",{0}),get_meta("windows_scene_video").set("resolution_percent",0)]' -f $EyeSize) | Out-Null
    }
    if($BitrateMbps -ge 0) {Eval ('get_meta("windows_scene_video").set("bitrate_mbps",{0})' -f $BitrateMbps) | Out-Null}
    Eval '[get_meta("windows_scene_video").set("foveated_encoding",false),get_meta("windows_scene_video").save_to()]' | Out-Null
    # Load a fresh saved config so the original discovered-host object is not
    # mutated when the temporary USB endpoint is assigned.
    Eval '[welcome_screen.get_xr_control().set("_discovered_config",null),welcome_screen.get_xr_control().set("_discovered_config",welcome_screen.get_xr_control().current_config())]' | Out-Null
    $options=@{address=$HostAddress;port=49100;key=$hostKey;relay=$true;hz=72;long_run=$true;handover_on_ready=$true;standby_only=$false}
    if($EyeSize -gt 0) {$options.eye_size=$EyeSize}
    foreach($entry in $options.GetEnumerator()) {
        $literal=$entry.Value | ConvertTo-Json -Compress
        Eval ('welcome_screen.get_xr_control().current_config().set_value("host","{0}",{1})' -f $entry.Key,$literal) | Out-Null
    }
    $smi=Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if($smi) {
        $gpuLog=Join-Path (Split-Path $PSScriptRoot) 'meteor\target\windows-xr-gpu.csv'
        $gpuMonitor=Start-Process $smi.Source -ArgumentList @('--query-gpu=timestamp,pstate,clocks.current.graphics,clocks.current.sm,utilization.gpu,utilization.encoder,power.draw,temperature.gpu','--format=csv','-lms','500') -RedirectStandardOutput $gpuLog -NoNewWindow -PassThru
    }
    if($Application) {& (Join-Path $PSScriptRoot 'run_windows_xr_headset_offer.ps1') -TimeoutSeconds ($Seconds+45) -StopAfterSeconds $Seconds}
    else {& (Join-Path $PSScriptRoot 'run_windows_xr_headset_offer.ps1') -TimeoutSeconds ($Seconds+15)}
} finally {
    if($gpuMonitor -and -not $gpuMonitor.HasExited) {Stop-Process -Id $gpuMonitor.Id}
    if ($saved) {
        Eval 'welcome_screen.get_xr_control().cancel()' | Out-Null
        Eval 'get_meta("windows_scene_original_video").save_to()' | Out-Null
        Eval 'welcome_screen.get_xr_control().set("_discovered_config",get_meta("windows_scene_original_config"))' | Out-Null
    }
    if($autoSaved) {Eval 'welcome_screen.set("_auto_suppressed",get_meta("windows_scene_original_auto_suppressed"))' | Out-Null}
    if($originalRuntimeConfig -ne $null) {[IO.File]::WriteAllText($runtimeConfigPath,$originalRuntimeConfig,[Text.UTF8Encoding]::new($false))}
}
