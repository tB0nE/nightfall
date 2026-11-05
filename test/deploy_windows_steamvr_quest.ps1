param([Parameter(Mandatory)][string]$Serial,[Parameter(Mandatory)][string]$ExpectedSha256,
    [switch]$Install,[switch]$Launch)
# Invoke only after the user's headset-install/launch approval. Never uninstall.
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
$adb=Join-Path $repo 'meteor\target\windows-platform-tools\platform-tools\adb.exe'
$apk=Join-Path $repo 'Nightfall-Android-arm64-v8a.apk'
$out=Join-Path $repo 'meteor\target\windows-steamvr-release'
$summary=[ordered]@{ok=$false;serial=$Serial;installed=$false;launched=$false}
try {
    if((Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash -ine $ExpectedSha256){throw 'APK differs from the verified release'}
    & $adb -s $Serial get-state | Out-Null
    if($LASTEXITCODE){throw 'Selected headset is unavailable'}
    if($Install) {
        $nativeError=$ErrorActionPreference
        try {
            $ErrorActionPreference='Continue'
            $result=& $adb -s $Serial install -r $apk 2>&1
            $installExit=$LASTEXITCODE
        } finally {$ErrorActionPreference=$nativeError}
        $result | Set-Content (Join-Path $out 'quest-install.log') -Encoding UTF8
        if($installExit -or ($result -join ' ') -notmatch 'Success'){throw 'Release APK update failed; never uninstalling to bypass a signing mismatch. See quest-install.log.'}
        $summary.installed=$true
    }
    if($Launch) {
        & $adb -s $Serial shell am force-stop app.nightfall.quest | Out-Null
        & $adb -s $Serial shell am start -n app.nightfall.quest/com.godot.game.GodotAppLauncher | Out-Null
        if($LASTEXITCODE){throw 'Nightfall launch failed'}
        Start-Sleep -Seconds 3
        $summary.launched=$true
    }
    $summary.pid=(& $adb -s $Serial shell pidof app.nightfall.quest).Trim()
    if($Launch -and -not $summary.pid){throw 'Nightfall exited after launch'}
    $summary.version=@(& $adb -s $Serial shell dumpsys package app.nightfall.quest | Select-String 'versionName=|versionCode=' | ForEach-Object {$_.Line.Trim()})
    $summary.front=@(& $adb -s $Serial shell dumpsys activity activities | Select-String 'topResumedActivity=' | Select-Object -First 1 | ForEach-Object {$_.Line.Trim()})
    $summary.ok=$true
} catch {$summary.error=$_.Exception.Message}
$summary | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $out 'quest-deploy-summary.json') -Encoding UTF8
$summary | ConvertTo-Json -Depth 5
if(-not $summary.ok){exit 1}
