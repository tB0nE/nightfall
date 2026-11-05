param([string]$RuntimeRoot='', [string]$Executable='')
# Normal Meteor startup with isolated preferences and ports, no headset/game.
$ErrorActionPreference='Stop'
$target=Join-Path (Split-Path $PSScriptRoot) 'meteor\target'
if(-not $RuntimeRoot){$RuntimeRoot=Join-Path $env:LOCALAPPDATA 'Nightfall Meteor\xr\windows'}
$RuntimeRoot=(Resolve-Path $RuntimeRoot).Path
if(-not $Executable){$Executable=Join-Path $target 'release\nightfall-meteor-xr-dev.exe'}
$root=Join-Path $target 'windows-normal-xr-smoke'
$oldRoaming=$env:APPDATA;$oldLocal=$env:LOCALAPPDATA
$process=$null
$summary=@{ok=$false;check='windows-normal-xr-startup';profile='release';headset=$false}
try {
    $env:APPDATA=Join-Path $root 'Roaming';$env:LOCALAPPDATA=Join-Path $root 'Local'
    $config=Join-Path $env:APPDATA 'Nightfall Meteor'
    New-Item -ItemType Directory -Force $config | Out-Null
    $catalog=Join-Path $root 'catalog';New-Item -ItemType Directory -Force $catalog | Out-Null
    foreach($file in 'xr-windows.json','windows-games.json'){Copy-Item (Join-Path $RuntimeRoot $file) (Join-Path $catalog $file) -Force}
    $RuntimeRoot=$catalog
    [IO.File]::WriteAllText((Join-Path $config 'meteor.toml'),"sunshine_port = 55989`nport_offset = 1000`n[xr]`nenabled = true`nruntime_root = '$RuntimeRoot'`nlisten = '127.0.0.1:56100'`nvideo_port = 56101`ntracking_port = 56102`n",[Text.UTF8Encoding]::new($false))
    $out=Join-Path $root 'stdout.log';$err=Join-Path $root 'stderr.log'
    $process=Start-Process $Executable -ArgumentList '--no-tray','--no-depth','--no-mic' -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    $ready=$false
    for($attempt=0;$attempt -lt 100;$attempt++) {
        if($process.HasExited){throw 'Normal Meteor exited before managed XR became ready'}
        $log=Join-Path $env:LOCALAPPDATA 'Nightfall Meteor\meteor.log'
        if((Test-Path $log) -and ((Get-Content $log -Raw) -match 'Managed XR service alongside proxy at 127.0.0.1:56100')){$ready=$true;break}
        Start-Sleep -Milliseconds 100
    }
    if(-not $ready){throw 'Normal Meteor did not start the native managed XR service'}
    $socket=[Net.Sockets.TcpClient]::new();try{$socket.Connect('127.0.0.1',56100)}finally{$socket.Dispose()}
    $summary.ok=$true;$summary.native_managed_service=$true;$summary.control_port=56100
} finally {
    if($process -and -not $process.HasExited){Stop-Process -Id $process.Id}
    $env:APPDATA=$oldRoaming;$env:LOCALAPPDATA=$oldLocal
    $summary | ConvertTo-Json | Set-Content "$target\windows-normal-xr-summary.json" -Encoding utf8
}
