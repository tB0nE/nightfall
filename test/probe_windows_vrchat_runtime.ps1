param([ValidateSet('Registered','Override')][string]$Mode='Registered',
    [ValidateRange(15,40)][int]$ObserveSeconds=20)
# Original protected game launcher; no game modifications, debugger, or Quest.
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
$target=Join-Path $repo 'meteor\target'
$runtime=(Resolve-Path "$target\windows-xrizer-d3d11-src\target\release").Path
$registry=Join-Path $env:LOCALAPPDATA 'openvr\openvrpaths.vrpath'
$originalRegistry=[IO.File]::ReadAllBytes($registry)
$registered=[Text.Encoding]::UTF8.GetString($originalRegistry) | ConvertFrom-Json
if(@($registered.runtime).Count -ne 1 -or $registered.runtime[0] -ine $runtime) {
    throw 'This test requires the existing per-user registration to select this xrizer build; it never changes registration.'
}
if(Get-Process VRChat,start_protected_game,vrserver,vrcompositor -ErrorAction SilentlyContinue) {throw 'An existing VR session/game is running; leave it untouched.'}
$stamp=[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
$output=Join-Path $target "windows-vrchat-trust\$stamp-$Mode"
New-Item -ItemType Directory -Force $output | Out-Null
$utf8=New-Object Text.UTF8Encoding $false
$summary=@{mode=$Mode;game_files_modified=$false;headset=$false;global_registration_changed=$false;normal_exit=$false;output=$output}
$watcher=$null
$saved=@{}
foreach($name in 'VR_OVERRIDE','VR_PATHREG_OVERRIDE','XR_RUNTIME_JSON','PATH','SteamAppId','SteamGameId') {$saved[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
try {
    Remove-Item Env:VR_OVERRIDE,Env:VR_PATHREG_OVERRIDE -ErrorAction SilentlyContinue
    if($Mode -eq 'Override') {
        [IO.File]::WriteAllBytes("$output\openvrpaths.vrpath",$originalRegistry)
        $env:VR_OVERRIDE=$runtime;$env:VR_PATHREG_OVERRIDE="$output\openvrpaths.vrpath"
    }
    $env:XR_RUNTIME_JSON="$target\windows-monado-vcpkg-build\Release\openxr_monado-dev.json"
    $env:PATH="$target\windows-openxr-loader-build\src\loader\Release;$env:PATH"
    $env:SteamAppId='438100';$env:SteamGameId='438100'
    $watchSeconds=$ObserveSeconds+25
    $watcher=Start-Process "$PSHOME\powershell.exe" -ArgumentList @('-NoProfile','-File',"`"$PSScriptRoot\read_windows_vrchat_dialogs.ps1`"",'-WatchSeconds',"$watchSeconds",'-OutputFile',"`"$output\dialogs.jsonl`"") -PassThru -RedirectStandardOutput "$output\watch.stdout.log" -RedirectStandardError "$output\watch.stderr.log"
    $null=$watcher.Handle
    Start-Sleep -Seconds 1
    $startedAt=Get-Date
    $xrizerLog=Join-Path $env:LOCALAPPDATA 'xrizer\xrizer.txt'
    $xrizerBefore=Get-Item $xrizerLog -ErrorAction SilentlyContinue
    $xrizerTime=if($xrizerBefore) {$xrizerBefore.LastWriteTimeUtc}else{[DateTime]::MinValue}
    $gameRoot='C:\Program Files (x86)\Steam\steamapps\common\VRChat'
    Start-Process "$gameRoot\start_protected_game.exe" -WorkingDirectory $gameRoot | Out-Null
    Write-Output "Protected VRChat launched: mode=$Mode; report=$output"
    Start-Sleep -Seconds $ObserveSeconds
    $game=Get-Process VRChat -ErrorAction SilentlyContinue | Where-Object {$_.StartTime -ge $startedAt}
    foreach($p in $game) {$null=$p.CloseMainWindow()}
    foreach($p in $game) {if(!$p.WaitForExit(10000)) {throw 'VRChat did not close normally; inspect its window before another trial.'}}
    $summary.game_process_seen=@($game).Count -gt 0
    $summary.normal_exit=$summary.game_process_seen
    if(!$watcher.WaitForExit(30000)) {throw 'Dialog monitor exceeded its bounded observation'}
    if($watcher.ExitCode -ne 0) {throw 'Dialog monitor failed; inspect watch.stderr.log'}
    $summary.dialog_events=@(Get-Content "$output\dialogs.jsonl" | ForEach-Object {ConvertFrom-Json $_})
    $log=Get-ChildItem "$env:USERPROFILE\AppData\LocalLow\VRChat\VRChat\output_log*.txt" | Where-Object {$_.LastWriteTime -ge $startedAt} | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if($log) {
        $summary.game_log=$log.FullName
        $summary.xr_evidence=@(Get-Content $log.FullName | Where-Object {$_ -match '\[OpenVR\]|\[SteamVR\]|Initializing XR Failed|XR Device:'} | ForEach-Object {"$_"})
    }
    $xrizerAfter=Get-Item $xrizerLog -ErrorAction SilentlyContinue
    $summary.xrizer_log_updated=($xrizerAfter -and $xrizerAfter.LastWriteTimeUtc -gt $xrizerTime)
    if($summary.xrizer_log_updated) {Copy-Item $xrizerLog "$output\xrizer.log"}
    # Hard-error dialogs can be hosted outside the game and have no readable
    # child controls. Windows logs their complete, untruncated message here.
    $summary.popup_events=@(Get-WinEvent -FilterHashtable @{LogName='System';Id=26;StartTime=$startedAt} -ErrorAction SilentlyContinue |
        Where-Object {$_.Message -match 'Easy Anti|xrizer|vrclient'} |
        ForEach-Object {@{utc=$_.TimeCreated.ToUniversalTime().ToString('o');record_id=$_.RecordId;provider=$_.ProviderName;message=$_.Message}})
} catch {$summary.error=$_.Exception.Message; Write-Warning $_}
finally {
    if($watcher -and !$watcher.HasExited) {Stop-Process -Id $watcher.Id}
    foreach($name in $saved.Keys) {[Environment]::SetEnvironmentVariable($name,$saved[$name],'Process')}
    $after=[IO.File]::ReadAllBytes($registry)
    $summary.global_registration_changed=[Convert]::ToBase64String($after) -cne [Convert]::ToBase64String($originalRegistry)
    [IO.File]::WriteAllText("$output\summary.json",($summary | ConvertTo-Json -Depth 8),$utf8)
    $summary | ConvertTo-Json -Depth 8
}
if($summary.error -or $summary.global_registration_changed) {exit 1}
