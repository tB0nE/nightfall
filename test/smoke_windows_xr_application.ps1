param([Parameter(Mandatory)][string]$Application,[string[]]$ApplicationArguments=@('-vr','-openxr','-dx11'),[uint32]$SteamAppId=0,
    [string]$OpenVrRuntime='',
    [string]$OpenVrLoader='',
    [switch]$SteamVR,
    [switch]$SteamCommand,
    [switch]$NaturalExit,
    [ValidateRange(1,60)][int]$ObserveSeconds=10,
    [ValidateRange(256,4096)][int]$EyeWidth=1024,
    [ValidateRange(256,4096)][int]$EyeHeight=1024,
    [ValidateRange(8,160)][int]$BitrateMbps=32)
# Launch only the explicit application in Meteor's owned process tree. The
# integration test observes 10s after three validated frames, then cancels;
# startup is bounded by 45s. This is not a graceful game-exit acceptance test.
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
$target=Join-Path $repo 'meteor\target'
$root=Join-Path $target 'windows-xr-application'
New-Item -ItemType Directory -Force $root | Out-Null
$summaryPath=Join-Path $root 'smoke-summary.json'
$summary=[ordered]@{ok=$false;check='windows-xr-application';profile='release';steam_command=[bool]$SteamCommand;natural_exit=[bool]$NaturalExit;headset=$false;application=$Application}
$summary | ConvertTo-Json | Set-Content $summaryPath -Encoding UTF8
$config=Get-Content (Join-Path $target 'windows-xr-dev\xr-windows.json') -Raw | ConvertFrom-Json
$config.application=(Resolve-Path $Application).Path
$config.arguments=@($ApplicationArguments)
$config.pixel_probe=$false
if($SteamCommand -and -not $SteamAppId) {throw 'Steam command check requires -SteamAppId'}
$config | Add-Member -MemberType NoteProperty -Name steam_launch -Value ([bool]$SteamCommand) -Force
if($SteamCommand) {$config | Add-Member -MemberType NoteProperty -Name steam_app_id -Value "$SteamAppId" -Force}
if($OpenVrRuntime) {
    $config | Add-Member -MemberType NoteProperty -Name openvr_runtime -Value ((Resolve-Path $OpenVrRuntime).Path) -Force
    $config.library_dirs=@($config.library_dirs)+@((Join-Path $target 'windows-openxr-loader-build\src\loader\Release'))
}
if($OpenVrLoader) {$config | Add-Member -MemberType NoteProperty -Name openvr_loader -Value ((Resolve-Path $OpenVrLoader).Path) -Force}
if($SteamVR) {
    $config.service=Join-Path $target 'windows-steamvr-build\Release\meteor-steamvr-mirror.exe'
    $config | Add-Member -MemberType NoteProperty -Name steamvr_driver -Value (Join-Path $target 'windows-steamvr-build\meteor') -Force
    $config | Add-Member -MemberType NoteProperty -Name openvr_runtime -Value 'C:\Program Files (x86)\Steam\steamapps\common\SteamVR' -Force
    $config.PSObject.Properties.Remove('openvr_loader')
    $env:METEOR_OPENVR_PROBE_FPS='72'
}
$config | Add-Member -MemberType NoteProperty -Name async_delivery -Value $true -Force
[IO.File]::WriteAllText((Join-Path $root 'xr-windows.json'),($config | ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
$env:NIGHTFALL_WINDOWS_XR_ROOT=$root
$env:NIGHTFALL_WINDOWS_XR_OBSERVE_SECONDS="$ObserveSeconds"
$env:NIGHTFALL_WINDOWS_XR_TEST_WIDTH="$EyeWidth"
$env:NIGHTFALL_WINDOWS_XR_TEST_HEIGHT="$EyeHeight"
$env:NIGHTFALL_WINDOWS_XR_TEST_BITRATE="$BitrateMbps"
$env:METEOR_NEUTRAL_INPUT='1'
if($SteamAppId) {$env:SteamAppId="$SteamAppId";$env:SteamGameId="$SteamAppId"}
foreach($name in 'METEOR_XR_GPU_MEASURE','METEOR_XR_GPU_SCENE_SHADER','METEOR_XR_OBSERVE_INPUT','METEOR_XR_FREE_RUNNING','METEOR_CONTINUOUS_FRAMES','METEOR_CONTROLLER_FIXTURE') {
    Remove-Item "Env:$name" -ErrorAction SilentlyContinue
}
$publisher=$null
$wrapper=$null
$previousVrOverride=$env:VR_OVERRIDE
$previousVrRegistry=$env:VR_PATHREG_OVERRIDE
try {
    if($OpenVrRuntime) {
        $runtime=(Resolve-Path $OpenVrRuntime).Path
        if(-not (Test-Path (Join-Path $runtime 'bin\vrclient_x64.dll'))) {throw 'Missing Windows OpenVR runtime DLL'}
        Remove-Item Env:VR_OVERRIDE,Env:VR_PATHREG_OVERRIDE -ErrorAction SilentlyContinue
    }
    if($SteamCommand) {
        # Start-Process uses a command-line string on Windows PowerShell 5.
        # Quote according to CommandLineToArgvW/CRT rules, without a shell.
        $wrapperArguments=@('--xr-steam-run','--root',$root,'--',$config.application)+@($ApplicationArguments)
        $quoted=@($wrapperArguments | ForEach-Object {
            $escaped=[regex]::Replace($_,'(\\*)"','$1$1\"')
            $escaped=[regex]::Replace($escaped,'(\\+)$','$1$1')
            '"'+$escaped+'"'
        })
        $wrapper=Start-Process (Join-Path $target 'release\nightfall-meteor-xr-dev.exe') -ArgumentList $quoted -PassThru `
            -RedirectStandardOutput (Join-Path $root 'steam-wrapper.out') -RedirectStandardError (Join-Path $root 'steam-wrapper.err')
        $wrapperHandle=$wrapper.Handle
    }
    $publisher=Start-Process (Join-Path $target 'windows-runtime-probe\Release\meteor-tracking-socket.exe') -ArgumentList '--serve','0' -PassThru `
        -RedirectStandardOutput (Join-Path $root 'tracking.out') -RedirectStandardError (Join-Path $root 'tracking.err')
    $publisherHandle=$publisher.Handle
    $port=''
    for($attempt=0;$attempt -lt 100;$attempt++) {
        if($publisher.HasExited) {throw 'Synthetic tracking publisher exited'}
        if((Get-Content (Join-Path $root 'tracking.out') -Raw) -match 'loopback:(\d+)') {$port=$Matches[1];break}
        Start-Sleep -Milliseconds 50
    }
    if(-not $port) {throw 'Tracking publisher did not become ready'}
    $env:NIGHTFALL_WINDOWS_TRACKING_PORT=$port
    Push-Location (Join-Path $repo 'meteor')
    try {
        $test='xr_session::tests::configured_application_delivers_frames_before_bounded_stop'
        if($NaturalExit) {$test='xr_session::tests::configured_runtime_delivers_frames_and_cleans_up'}
        & cargo test --release --locked --no-default-features --bin nightfall-meteor $test -- --ignored --nocapture
        if($LASTEXITCODE) {throw 'Configured Windows application did not pass the local XR capture check'}
        if($SteamCommand) {
            if(-not $wrapper.WaitForExit(5000)) {throw 'Steam wrapper did not stop after session cancellation'}
            $expected=130
            if($NaturalExit) {$expected=0}
            if($wrapper.ExitCode -ne $expected) {throw "Expected Steam wrapper exit $expected; got $($wrapper.ExitCode)"}
            Write-Output "PASS: Steam wrapper handed off the actual command and returned status $expected"
            $summary['wrapper_exit_code']=$wrapper.ExitCode
        }
        $summary['ok']=$true
        $summary['capture_validated']=$true
        $summary['owned_process_cleanup']=$true
        $summary | ConvertTo-Json | Set-Content $summaryPath -Encoding UTF8
    } finally {Pop-Location}
} finally {
    if($publisher -and -not $publisher.HasExited) {Stop-Process -Id $publisher.Id}
    if($wrapper -and -not $wrapper.HasExited) {Stop-Process -Id $wrapper.Id}
    $env:VR_OVERRIDE=$previousVrOverride
    $env:VR_PATHREG_OVERRIDE=$previousVrRegistry
}
