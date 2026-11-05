$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
$installed=Join-Path $env:LOCALAPPDATA 'Programs\Nightfall Meteor'
$config=Join-Path $installed 'runtime\host\config\sunshine.conf'
$text=[IO.File]::ReadAllText($config)
$backup=$config+'.before-physical-capture-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
Copy-Item -LiteralPath $config -Destination $backup
if($text -match '(?m)^\s*virtual_display_mode\s*=') {
    $text=[regex]::Replace($text,'(?m)^\s*virtual_display_mode\s*=.*$','virtual_display_mode = disabled')
} else {$text+="`nvirtual_display_mode = disabled`n"}
$processes=@(Get-Process nightfall-meteor -ErrorAction SilentlyContinue)
if($processes.Count -ne 1 -or $processes[0].Path -ine (Join-Path $installed 'nightfall-meteor.exe')){throw 'Unexpected Meteor process; configuration preserved'}
& (Join-Path $PSScriptRoot 'stop_windows_meteor.ps1') -ExpectedProcessId $processes[0].Id | Out-Null
[IO.File]::WriteAllText($config,$text,[Text.UTF8Encoding]::new($false))
$started=Start-Process (Join-Path $installed 'nightfall-meteor.exe') -PassThru
@{ok=$true;meteor_pid=$started.Id;virtual_display_mode='disabled';backup=$backup;pairing_data_changed=$false} | ConvertTo-Json
