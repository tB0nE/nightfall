$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$config = Join-Path $env:APPDATA 'Nightfall Meteor\host.toml'
$backup = "$config.before-multimonitor-trial"
if (Get-Process nightfall-meteor -ErrorAction SilentlyContinue) { throw 'Meteor is already running; stop it before starting the trial' }
if (-not (Test-Path $backup)) { Copy-Item $config $backup }
$state = Get-Content $config -Raw
$state = $state -replace '(?m)^choice\s*=.*$', 'choice = "bundled"'
[IO.File]::WriteAllText($config,$state,[Text.UTF8Encoding]::new($false))
$env:METEOR_WINDOWS_MULTIMONITOR = '1'
Remove-Item Env:METEOR_WINDOWS_MULTIMONITOR_PROBE -ErrorAction SilentlyContinue
$env:PATH = "C:\msys64\ucrt64\bin;$env:PATH"
$meteor = Start-Process (Join-Path $repo 'meteor\target\release\nightfall-meteor.exe') -ArgumentList '--no-depth','--no-mic' -PassThru
Write-Output "meteor_pid=$($meteor.Id) profile_backup=$backup"
