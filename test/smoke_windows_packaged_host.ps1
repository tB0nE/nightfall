# Normal startup of the relocated package, fresh settings, isolated ports.
$ErrorActionPreference='Stop'
$target=Join-Path (Split-Path $PSScriptRoot) 'meteor\target'
$package=Get-Content (Join-Path $target 'windows-packaged-setup-summary.json') -Raw | ConvertFrom-Json
if(-not $package.ok){throw 'Run packaged setup smoke check first'}
$saved=@{APPDATA=$env:APPDATA;LOCALAPPDATA=$env:LOCALAPPDATA;PATH=$env:PATH;NIGHTFALL_TEST_SKIP_TRAY_PROMOTION=$env:NIGHTFALL_TEST_SKIP_TRAY_PROMOTION}
$process=$null;$summary=@{ok=$false;headset=$false;check='windows-packaged-host'}
function FreeTestBase {
    foreach($candidate in @(53989,51989,55989,57989,59989)) {
        $sockets=@();$free=$true
        try {
            $tcp=@(($candidate-5),$candidate,($candidate+1),($candidate+21),($candidate+995),($candidate+1000),($candidate+1021),($candidate-89),($candidate-88),($candidate+111),($candidate+112),($candidate+113))
            $udp=@(($candidate+9),($candidate+10),($candidate+11),($candidate+13),($candidate+1009),($candidate+1010),($candidate+1011),($candidate+1013),($candidate-87))
            foreach($port in $tcp) {
                $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Any,$port)
                $listener.Server.ExclusiveAddressUse=$true;$listener.Start();$sockets+=$listener
            }
            foreach($port in $udp) {
                $listener=[Net.Sockets.UdpClient]::new()
                $listener.Client.ExclusiveAddressUse=$true
                $listener.Client.Bind([Net.IPEndPoint]::new([Net.IPAddress]::Any,$port));$sockets+=$listener
            }
        } catch {$free=$false} finally {
            foreach($socket in $sockets){if($socket -is [Net.Sockets.TcpListener]){$socket.Stop()}else{$socket.Dispose()}}
        }
        if($free){return $candidate}
    }
    throw 'No isolated port block is available for the packaged host check'
}
try {
    $env:NIGHTFALL_TEST_SKIP_TRAY_PROMOTION='1'
    $env:APPDATA=Join-Path $package.root 'Roaming';$env:LOCALAPPDATA=Join-Path $package.root 'Local'
    $env:PATH="$env:SystemRoot\System32;$env:SystemRoot;$env:SystemRoot\System32\Wbem"
    $config=Join-Path $env:APPDATA 'Nightfall Meteor'
    # Keep setup's enabled host/PCVR choices but isolate this check's listeners.
    $path=Join-Path $config 'meteor.toml'
    $base=FreeTestBase;$xrPort=$base+111
    $text="sunshine_port = $base`nport_offset = 1000`n[host_env]`nMETEOR_WINDOWS_MULTIMONITOR = '1'`n[xr]`nenabled = true`nruntime_root = '$($package.catalog)'`nlisten = '127.0.0.1:$xrPort'`nvideo_port = $($xrPort+1)`ntracking_port = $($xrPort+2)`n"
    [IO.File]::WriteAllText($path,$text,[Text.UTF8Encoding]::new($false))
    $state=Join-Path $config 'host.toml';$text=[IO.File]::ReadAllText($state)
    if($text -match '(?m)^base\s*='){ $text=[regex]::Replace($text,'(?m)^base\s*=.*$',"base = $base") }else{$text+="`nbase = $base`n"}
    [IO.File]::WriteAllText($state,$text,[Text.UTF8Encoding]::new($false))
    $log=Join-Path $env:LOCALAPPDATA 'Nightfall Meteor\meteor.log'
    if(Test-Path $log){Move-Item $log "$log.before-host-check" -Force}
    $process=Start-Process $package.executable -ArgumentList '--no-depth','--no-mic' -PassThru
    $ready=$false
    for($i=0;$i -lt 150;$i++) {
        if($process.HasExited){throw 'Packaged Meteor exited during normal startup'}
        $text=''
        if(Test-Path $log){$text=[string](Get-Content $log -Raw)}
        if(-not [string]::IsNullOrEmpty($text) -and $text.Contains("Managed XR service alongside proxy at 127.0.0.1:$xrPort") -and $text.Contains("Sunshine is running on port $base")){$ready=$true;break}
        Start-Sleep -Milliseconds 200
    }
    if(-not $ready){throw 'Packaged host and XR service did not both become ready'}
    $tcp=[Net.Sockets.TcpClient]::new();try{$tcp.Connect('127.0.0.1',$xrPort)}finally{$tcp.Dispose()}
    $hostConfig=Join-Path (Split-Path $package.executable) 'runtime\host\config'
    if(-not (Test-Path (Join-Path $hostConfig 'sunshine_state.json'))){throw 'Packaged host did not initialize its own pairing state'}
    $summary.ok=$true;$summary.built_in_host=$true;$summary.pcvr=$true;$summary.base=$base
} catch {$summary.error=$_.Exception.Message;throw} finally {
    if($process -and -not $process.HasExited) {
        try {& (Join-Path $PSScriptRoot 'stop_windows_meteor.ps1') -ExpectedProcessId $process.Id}catch{$summary.cleanup_error=$_.Exception.Message}
        if(-not $process.WaitForExit(15000)){Stop-Process -Id $process.Id;$summary.cleanup_forced=$true}
    }
    foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name],'Process')}
    $summary | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $target 'windows-packaged-host-summary.json') -Encoding utf8
}
