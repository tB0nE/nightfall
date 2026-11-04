param([int]$Frames = 360, [switch]$VRChat, [switch]$Encode)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$steamvr = 'C:\Program Files (x86)\Steam\steamapps\common\SteamVR'
$trial = Join-Path $repo 'meteor\target\windows-steamvr-trial'
$driver = Join-Path $repo 'meteor\target\windows-steamvr-build\meteor'
if (Get-Process vrserver,vrcompositor,vrmonitor -ErrorAction SilentlyContinue) {
    throw 'An existing SteamVR session is running; leave it untouched.'
}
if ($Frames -lt 3 -or $Frames -gt 720) { throw 'Frames must be 3..720' }
$utf8 = New-Object System.Text.UTF8Encoding $false
New-Item -ItemType Directory -Force "$trial\config", "$trial\logs" | Out-Null
if (Test-Path "$trial\logs\vrserver.txt") { Move-Item "$trial\logs\vrserver.txt" "$trial\logs\vrserver.previous.txt" -Force }
$paths = @{jsonid='vrpathreg'; version=1; runtime=@($steamvr); config=@("$trial\config"); log=@("$trial\logs"); external_drivers=@($driver)}
[IO.File]::WriteAllText("$trial\openvrpaths.vrpath", ($paths | ConvertTo-Json -Depth 5), $utf8)
$settings = @{steamvr=@{forcedDriver='meteor'; requireHmd=$true; activateMultipleDrivers=$false; enableHomeApp=$false; startDashboardFromAppLaunch=$false; supersampleManualOverride=$true; supersampleScale=1.0; motionSmoothing=$false}; dashboard=@{enableDashboard=$false}; driver_meteor=@{enable=$true}; driver_lighthouse=@{enable=$false}; driver_oculus=@{enable=$false}; driver_null=@{enable=$false}}
[IO.File]::WriteAllText("$trial\config\steamvr.vrsettings", ($settings | ConvertTo-Json -Depth 5), $utf8)
$env:VR_OVERRIDE=$steamvr
$env:VR_PATHREG_OVERRIDE="$trial\openvrpaths.vrpath"
$env:METEOR_STEAMVR_TRIAL='1'
$env:METEOR_STEAMVR_SYNTHETIC='1'
$startedAt=Get-Date
$summary=@{ok=$false; synthetic=$true; frames=$Frames; private_paths=$env:VR_PATHREG_OVERRIDE}
try {
    Start-Process "$steamvr\bin\win64\vrstartup.exe" -PassThru | Out-Null
    $deadline=(Get-Date).AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 500
        $log=Get-Content "$trial\logs\vrserver.txt" -Raw -ErrorAction SilentlyContinue
    } until (($log -match 'METEOR_STEAMVR provider ready') -or (Get-Date) -gt $deadline)
    if ($log -notmatch 'METEOR_STEAMVR provider ready') { throw 'Meteor provider did not initialize; inspect private vrserver log.' }
    if ($VRChat) {
        if (Get-Process VRChat -ErrorAction SilentlyContinue) { throw 'Leave the existing VRChat session untouched.' }
        $env:SteamAppId='438100'; $env:SteamGameId='438100'
        $gameRoot='C:\Program Files (x86)\Steam\steamapps\common\VRChat'
        Start-Process "$gameRoot\start_protected_game.exe" -WorkingDirectory $gameRoot | Out-Null
        # Bounded desktop-only compatibility check; no Quest session is opened.
        Start-Sleep -Seconds 40
        $gameLog=Get-ChildItem "$env:USERPROFILE\AppData\LocalLow\VRChat\VRChat\output_log*.txt" |
            Where-Object { $_.LastWriteTime -ge $startedAt } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (!$gameLog) { throw 'VRChat did not produce a new log' }
        $summary.vrchat_log=$gameLog.FullName
        $content=Get-Content $gameLog.FullName -Raw
        $summary.vrchat_xr_failed=$content -match 'Initializing XR Failed|Could not initialize OpenVR'
        $summary.vrchat_evidence=@($content -split "`n" | Where-Object { $_ -match 'XR Device:|\[OpenVR\]|\[SteamVR\]|EasyAntiCheat|EOS AntiCheat' } | Select-Object -First 20)
        $game=Get-Process VRChat -ErrorAction SilentlyContinue | Where-Object { $_.StartTime -ge $startedAt }
        foreach ($p in $game) { $null=$p.CloseMainWindow() }
        foreach ($p in $game) { if (!$p.WaitForExit(15000)) { throw 'VRChat did not close normally; inspect it before another trial.' } }
        $summary.ok=(!$summary.vrchat_xr_failed) -and ($content -match '\[SteamVR\].*Initialized\. Connected to meteor')
        $summary.dialogs=@(& "$PSScriptRoot\read_windows_vrchat_dialogs.ps1")
    } else {
    if ($Encode) {
        $sink=Start-Process "$repo\meteor\target\windows-runtime-probe\Release\meteor-xr-wire-sink.exe" -ArgumentList @('0',"`"$trial\stereo.h264`"",'1.6') -RedirectStandardOutput "$trial\wire.stdout.log" -RedirectStandardError "$trial\wire.stderr.log" -PassThru
        $null=$sink.Handle
        $deadline=(Get-Date).AddSeconds(5)
        do { Start-Sleep -Milliseconds 50; $wire=Get-Content "$trial\wire.stdout.log" -Raw } until ($wire -match 'wire_sink_port=(\d+)' -or (Get-Date) -gt $deadline)
        if ($wire -notmatch 'wire_sink_port=(\d+)') { throw 'Wire receiver did not start' }
        $env:METEOR_XR_DIRECT_PORT=$Matches[1];$env:METEOR_XR_ASYNC_DELIVERY='1';$env:METEOR_XR_TRACKED_SCENE='1';$env:XRT_COMPOSITOR_NULL_FPS='72'
    }
    $mirror=Start-Process "$repo\meteor\target\windows-steamvr-build\Release\meteor-steamvr-mirror.exe" -ArgumentList @("`"$steamvr\bin\win64\openvr_api.dll`"", '4', "`"$trial\mirror`"") -RedirectStandardOutput "$trial\mirror.stdout.log" -RedirectStandardError "$trial\mirror.stderr.log" -PassThru
    $null=$mirror.Handle
    $probe=Join-Path $repo 'meteor\target\windows-runtime-probe\Release\meteor-openvr-probe.exe'
    $env:METEOR_OPENVR_PROBE_FPS='72'
    $proc=Start-Process $probe -ArgumentList @("`"$steamvr\bin\win64\openvr_api.dll`"", "$Frames", '--scene') -RedirectStandardOutput "$trial\probe.stdout.log" -RedirectStandardError "$trial\probe.stderr.log" -PassThru
    $null=$proc.Handle # Retain the native handle so PowerShell preserves ExitCode.
    if (!$proc.WaitForExit(30000)) { $proc.Kill(); throw 'OpenVR probe timed out' }
    $summary.probe_exit=$proc.ExitCode
    if (!$mirror.WaitForExit(15000)) { $mirror.Kill(); throw 'Mirror probe timed out' }
    $summary.mirror_exit=$mirror.ExitCode
    $summary.ok=$proc.ExitCode -eq 0 -and $mirror.ExitCode -eq 0
    if ($Encode) {
        if (!$sink.WaitForExit(10000)) { $sink.Kill(); throw 'Wire receiver did not drain' }
        $summary.wire_exit=$sink.ExitCode;$summary.ok=$summary.ok -and $sink.ExitCode -eq 0
        $summary.wire_evidence=@(Get-Content "$trial\wire.stdout.log" | Select-Object -Last 2 | ForEach-Object { "$_" })
    }
    Get-Content "$trial\probe.stdout.log", "$trial\probe.stderr.log"
    Get-Content "$trial\mirror.stdout.log"
    Get-Content "$trial\mirror.stderr.log" | Select-Object -Last 3
    }
} catch { $summary.error=$_.Exception.Message; Write-Warning $_ }
finally {
    # Only this bounded trial's processes can have started after our initial check.
    Get-Process vrmonitor,vrserver,vrcompositor,vrdashboard,vrwebhelper,vrstartup -ErrorAction SilentlyContinue |
        Where-Object { $_.StartTime -ge $startedAt } | Stop-Process -Force -ErrorAction SilentlyContinue
    [IO.File]::WriteAllText("$trial\summary.json", ($summary | ConvertTo-Json -Depth 5), $utf8)
    $summary | ConvertTo-Json -Depth 5
}
if (!$summary.ok) { exit 1 }
