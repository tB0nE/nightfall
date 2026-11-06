param([Parameter(Mandatory)][string]$Serial)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
$adb=Join-Path $repo 'meteor\target\windows-platform-tools\platform-tools\adb.exe'
$out=Join-Path $repo 'meteor\target\windows-steamvr-release'
$summary=[ordered]@{ok=$false;serial=$Serial;headset_modified=$false}
try {
    $appProcessId=(@(& $adb -s $Serial shell pidof app.nightfall.quest) -join '').Trim()
    if(-not $appProcessId){throw 'Nightfall is not running'}
    $summary.pid=$appProcessId
    $lines=@(& $adb -s $Serial logcat -d --pid $appProcessId)
    $lines | Set-Content (Join-Path $out 'quest-startup.log') -Encoding UTF8
    $summary.fatal_count=@($lines | Select-String 'FATAL EXCEPTION|Fatal signal|SIGSEGV|SIGABRT').Count
    $summary.script_error_count=@($lines | Select-String 'SCRIPT ERROR:').Count
    $summary.front=@(& $adb -s $Serial shell dumpsys activity activities | Select-String 'topResumedActivity=' | Select-Object -First 1 | ForEach-Object {$_.Line.Trim()})
    $summary.ok=$summary.fatal_count -eq 0 -and $summary.script_error_count -eq 0
} catch {$summary.error=$_.Exception.Message}
$summary | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $out 'quest-startup-summary.json') -Encoding UTF8
$summary | ConvertTo-Json -Depth 5
if(-not $summary.ok){exit 1}
