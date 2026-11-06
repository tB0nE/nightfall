param([Parameter(Mandatory)][string]$Serial)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
$installed=Join-Path $env:LOCALAPPDATA 'Programs\Nightfall Meteor'
$exe=Join-Path $installed 'nightfall-meteor.exe'
$adb=Join-Path $repo 'meteor\target\windows-platform-tools\platform-tools\adb.exe'
$out=Join-Path $repo 'meteor\target\windows-steamvr-release'
$summary=[ordered]@{ok=$false;pairing_data_changed=$false}
try {
    & $adb -s $Serial shell am force-stop app.nightfall.quest | Out-Null
    $processes=@(Get-Process nightfall-meteor -ErrorAction SilentlyContinue)
    if($processes.Count) {
        if($processes.Count -ne 1 -or $processes[0].Path -ine $exe){throw 'Unexpected Meteor executable; preserved it'}
        & (Join-Path $PSScriptRoot 'stop_windows_meteor.ps1') -ExpectedProcessId $processes[0].Id | Out-Null
    }
    $tools=Join-Path $installed 'runtime\host\tools'
    New-Item -ItemType Directory -Force $tools | Out-Null
    foreach($name in 'sunshine_display_helper.exe','sunshine_wgc_capture.exe') {
        Copy-Item -LiteralPath (Join-Path $repo "meteor\target\windows-vibepollo-src\build-meteor-windows\tools\$name") -Destination $tools -Force
    }
    $summary.meteor_pid=(Start-Process $exe -PassThru).Id
    $state=Join-Path $env:APPDATA 'Nightfall Meteor\host.toml'
    $match=[regex]::Match([IO.File]::ReadAllText($state),'(?m)^base\s*=\s*(\d+)')
    if(-not $match.Success){throw 'Bundled host port is unavailable'}
    $base=[int]$match.Groups[1].Value
    $deadline=[DateTime]::UtcNow.AddSeconds(45);$ready=$false
    while([DateTime]::UtcNow -lt $deadline) {
        if(Get-NetTCPConnection -LocalPort $base -State Listen -ErrorAction SilentlyContinue){$ready=$true;break}
        Start-Sleep -Milliseconds 200
    }
    if(-not $ready){throw 'Bundled host did not become ready; headset remains stopped'}
    & $adb -s $Serial shell am start -n app.nightfall.quest/com.godot.game.GodotAppLauncher | Out-Null
    if($LASTEXITCODE){throw 'Nightfall launch failed'}
    $summary.ok=$true
} catch {$summary.error=$_.Exception.Message}
$summary | ConvertTo-Json | Set-Content (Join-Path $out 'desktop-recovery-summary.json') -Encoding UTF8
$summary | ConvertTo-Json
if(-not $summary.ok){exit 1}
