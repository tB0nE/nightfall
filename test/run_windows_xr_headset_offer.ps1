param([ValidateRange(10,345)][int]$TimeoutSeconds=60,[ValidateRange(0,300)][int]$StopAfterSeconds=0)
$ErrorActionPreference = 'Stop'
$bridge = Join-Path $PSScriptRoot 'windows_nf_bridge.ps1'
$log = Join-Path (Split-Path $PSScriptRoot) 'meteor\target\windows-xr-headset-trial.jsonl'
function Eval([string]$Expression) {
    $request = @{cmd='eval';expr=$Expression} | ConvertTo-Json -Compress
    $reply = & $bridge -Request $request | ConvertFrom-Json
    if (-not $reply.ok) { throw $reply.error }
    return $reply.value
}
Eval 'welcome_screen.get_xr_control().connect_offer()' | Out-Null
$deadline = [DateTime]::UtcNow.AddSeconds(8)
do {
    $state = Eval 'welcome_screen.get_xr_control().state'
    if ($state -eq 'offered') { break }
    if ($state -eq 'failed') { throw (Eval 'welcome_screen.get_xr_control().message') }
    Start-Sleep -Milliseconds 100
} while ([DateTime]::UtcNow -lt $deadline)
if ($state -ne 'offered') { throw "No XR offer: $state" }
Eval 'welcome_screen.get_xr_control().accept_offer()' | Out-Null
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$last = ''
$nextConsole = [DateTime]::MinValue
$lines = @()
$clock=[Diagnostics.Stopwatch]::StartNew()
$applicationStarted=-1.0
do {
    $sample = Eval '[welcome_screen.get_xr_control().state,welcome_screen.get_xr_control().message,welcome_screen.get_xr_control().runtime_status,pcvr_test.backend.get_test_status(),{"app_fps":telemetry.app_fps,"display_hz":display_refresh_rate,"timing_active":settings_controller.pcvr_timing.active}]'
    $sample += @{elapsed_s=$clock.Elapsed.TotalSeconds}
    $line = $sample | ConvertTo-Json -Depth 8 -Compress
    $lines += $line
    if ($line -ne $last -and [DateTime]::UtcNow -ge $nextConsole) {
        Write-Output $line; $last=$line; $nextConsole=[DateTime]::UtcNow.AddSeconds(1)
    }
    if($StopAfterSeconds -gt 0 -and $sample[2].phase -eq 'session_active' -and $sample[3].frames -gt 0) {
        if($applicationStarted -lt 0) {$applicationStarted=$clock.Elapsed.TotalSeconds}
        elseif($clock.Elapsed.TotalSeconds-$applicationStarted -ge $StopAfterSeconds) {
            Eval 'welcome_screen.get_xr_control().cancel()' | Out-Null
        }
    }
    if ($sample[0] -eq 'failed' -or ($sample[0] -eq 'idle' -and $sample[3].state -eq 'idle')) { break }
    Start-Sleep -Milliseconds 100
} while ([DateTime]::UtcNow -lt $deadline)
$lines | Set-Content $log
Write-Output $line
if ($sample[0] -eq 'failed') {throw $sample[1]}
if ($sample[3].error) {throw "Headset receiver failed: $($sample[3].error)"}
if ($sample[0] -ne 'idle') {throw "XR trial did not finish within $TimeoutSeconds seconds"}
