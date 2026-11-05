# Request normal tray Quit; allow Meteor to drain XR and stop its owned host.
# Do not force-kill an unrelated executable if its process/window changed.
param([uint32]$ExpectedProcessId=0)
$ErrorActionPreference='Stop'
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class MeteorTrayQuit {
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string name,string title);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window,out uint pid);
 [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window,uint message,IntPtr command,IntPtr value);
}
'@
$window=[MeteorTrayQuit]::FindWindow('NightfallMeteorTray','NightfallMeteorTray')
if($window -eq [IntPtr]::Zero){throw 'No normal Meteor tray window found; refusing to kill processes'}
[uint32]$meteorProcessId=0
[void][MeteorTrayQuit]::GetWindowThreadProcessId($window,[ref]$meteorProcessId)
if($ExpectedProcessId -and $meteorProcessId -ne $ExpectedProcessId){throw 'Tray belongs to another Meteor instance; preserved it'}
$process=Get-Process -Id $meteorProcessId
if($process.ProcessName -ne 'nightfall-meteor'){throw 'Tray belongs to a different executable'}
if(-not [MeteorTrayQuit]::PostMessage($window,0x111,[IntPtr]3,[IntPtr]::Zero)){throw 'Could not request Meteor Quit'}
if(-not $process.WaitForExit(15000)){throw 'Meteor did not stop gracefully within 15 seconds'}
Write-Output "stopped_meteor_pid=$meteorProcessId"
