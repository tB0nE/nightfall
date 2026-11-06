$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$state = Get-Content (Join-Path $env:APPDATA 'Nightfall Meteor\host.toml') -Raw
$userMatch = [regex]::Match($state,'(?m)^user\s*=\s*"([^"]+)"')
$passwordMatch = [regex]::Match($state,'(?m)^password\s*=\s*"([^"]+)"')
if (-not $userMatch.Success -or -not $passwordMatch.Success) { throw 'Missing normal-profile host credentials' }
$exe = Join-Path $repo 'meteor\target\windows-vibepollo-src\build-meteor-windows\sunshine.exe'
Get-Process nightfall-meteor -ErrorAction SilentlyContinue | Stop-Process
Start-Sleep -Seconds 2
$conf = Join-Path (Split-Path $exe) 'config\sunshine.conf'
$result = & $exe $conf --creds $userMatch.Groups[1].Value $passwordMatch.Groups[1].Value 2>&1
if ($LASTEXITCODE -ne 0) { throw 'Could not restore managed host credentials' }
& (Join-Path $PSScriptRoot 'start_windows_multimonitor_trial.ps1')
Start-Sleep -Seconds 5
[Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
$body = @{ username=$userMatch.Groups[1].Value; password=$passwordMatch.Groups[1].Value } | ConvertTo-Json
$response = Invoke-WebRequest -UseBasicParsing -Uri 'https://localhost:49990/api/auth/login' -Method Post -ContentType 'application/json' -Body $body
Write-Output "host_login_http=$($response.StatusCode)"
