param([Parameter(Mandatory)][string]$Serial)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
$adb=Join-Path $repo 'meteor\target\windows-platform-tools\platform-tools\adb.exe'
try {
    & $adb -s $Serial shell am broadcast -a com.oculus.vrpowermanager.prox_close | Out-Null
    & $adb -s $Serial shell setprop debug.oculus.guardian_pause 0 | Out-Null
    Start-Sleep -Seconds 2
    & (Join-Path $PSScriptRoot 'request_windows_steamvr_connection.ps1')
    Start-Sleep -Seconds 8
    & (Join-Path $PSScriptRoot 'check_windows_quest_startup.ps1') -Serial $Serial
} finally {
    & $adb -s $Serial shell am broadcast -a com.oculus.vrpowermanager.automation_disable | Out-Null
    & $adb -s $Serial shell "setprop debug.oculus.guardian_pause ''" | Out-Null
}
