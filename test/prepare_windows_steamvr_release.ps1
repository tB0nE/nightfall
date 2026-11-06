param([switch]$Build)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
$out=Join-Path $repo 'meteor\target\windows-steamvr-release'
New-Item -ItemType Directory -Force $out | Out-Null
$installed=Join-Path $env:LOCALAPPDATA 'Programs\Nightfall Meteor'
$steam=(Get-ItemProperty 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction SilentlyContinue).SteamPath
if(-not $steam){$steam=Join-Path ${env:ProgramFiles(x86)} 'Steam'}
$summary=[ordered]@{ok=$false;installed=$installed;processes=@();headset_used=$false;system_changed=$false;build_requested=[bool]$Build}
try {
    $summary.processes=@(Get-CimInstance Win32_Process | Where-Object {$_.Name -in @('nightfall-meteor.exe','sunshine.exe','steam.exe','vrserver.exe','vrcompositor.exe','vrmonitor.exe')} | Select-Object Name,ProcessId,ExecutablePath)
    $paths=Join-Path $env:LOCALAPPDATA 'openvr\openvrpaths.vrpath'
    if(Test-Path -LiteralPath $paths) {
        $registration=Get-Content -LiteralPath $paths -Raw | ConvertFrom-Json
        $summary.registered_drivers=@($registration.external_drivers)
    }
    $version=([regex]::Match((Get-Content (Join-Path $repo 'meteor\Cargo.toml') -Raw),'(?m)^version = "([^"]+)"')).Groups[1].Value
    if(-not $version){throw 'Cannot determine Meteor release version'}
    $installer=Join-Path $repo "meteor\target\windows-release\Nightfall-Meteor-$version-Setup-x64.exe"
    if(Test-Path -LiteralPath $installer) {
        $backup=Join-Path $out ('previous-installer-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'.exe')
        Copy-Item -LiteralPath $installer -Destination $backup
        $summary.previous_installer=$backup
    }
    if($Build) {
        $models=Join-Path $installed 'share\nightfall-meteor\models'
        if(-not (Test-Path (Join-Path $models 'zipdepth_wide_512x288.ncnn.bin'))){throw 'Installed bundled EdgePad weights are missing'}
        # Run the build in its own PowerShell process: native stderr warnings
        # remain logging rather than terminating the wrapper's pipeline.
        $buildFile=Join-Path $repo 'meteor\tools\build_windows_installer.ps1'
        $nativeError=$ErrorActionPreference
        try {
            $ErrorActionPreference='Continue'
            & powershell.exe -NoProfile -File $buildFile -ModelsDir $models *> (Join-Path $out 'installer-build.log')
            $buildExit=$LASTEXITCODE
        } finally {$ErrorActionPreference=$nativeError}
        if($buildExit){throw "Release build failed ($buildExit); see installer-build.log"}
        $summary.installer=$installer
        $summary.installer_sha256=(Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
        $summary.installer_bytes=(Get-Item -LiteralPath $installer).Length
    }
    $summary.ok=$true
} catch {$summary.error=$_.Exception.Message}
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $out 'prepare-summary.json') -Encoding UTF8
$summary | ConvertTo-Json -Depth 6
if(-not $summary.ok){exit 1}
