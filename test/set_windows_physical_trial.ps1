$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$conf = Join-Path $repo 'meteor\target\windows-vibepollo-src\build-meteor-windows\config\sunshine.conf'
if (-not (Test-Path "$conf.before-physical-trial")) { Copy-Item $conf "$conf.before-physical-trial" }
$text = Get-Content $conf -Raw
$options = @{ virtual_display_mode='disabled'; dd_configuration_option='disabled' }
$text = [regex]::Replace($text,'(?m)^use_sunshine_virtual_display_driver\s*=.*\r?\n?','')
foreach ($key in $options.Keys) {
    $text = [regex]::Replace($text,"(?m)^$key\s*=.*\r?\n?",'')
    $text += "`n$key = $($options[$key])`n"
}
Get-Process nightfall-meteor -ErrorAction SilentlyContinue | Stop-Process
Start-Sleep -Seconds 2
[IO.File]::WriteAllText($conf,$text,[Text.UTF8Encoding]::new($false))
& (Join-Path $PSScriptRoot 'start_windows_multimonitor_trial.ps1')
