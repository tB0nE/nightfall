# Built-in Windows desktop API. No Python or extra install required.
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'Nightfall-Meteor'
[IO.Directory]::CreateDirectory($root) | Out-Null
$journal = Join-Path $root 'host-background.json'
$mutex = New-Object Threading.Mutex($false, 'Local\NightfallMeteorHostBackground')
$locked = $false
try {
    try { $locked = $mutex.WaitOne(10000) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (!$locked) { throw 'Background lock timed out' }
    if ($env:METEOR_BG_COLOR -eq 'off' -and !(Test-Path $journal)) { exit 0 }
    Add-Type @'
using System;
using System.Runtime.InteropServices;
[ComImport, Guid("B92B56A9-8B55-4E14-9A89-0199BBB6F93B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IDesktopWallpaper {
 void SetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitor, [MarshalAs(UnmanagedType.LPWStr)] string path);
 void GetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitor, [MarshalAs(UnmanagedType.LPWStr)] out string path);
 void GetMonitorDevicePathAt(uint index, [MarshalAs(UnmanagedType.LPWStr)] out string monitor);
 void GetMonitorDevicePathCount(out uint count);
 void GetMonitorRECT([MarshalAs(UnmanagedType.LPWStr)] string monitor, IntPtr rect);
 void SetBackgroundColor(uint color);
 void GetBackgroundColor(out uint color);
 void SetPosition(uint position);
 void GetPosition(out uint position);
 void SetSlideshow(IntPtr items);
 void GetSlideshow(out IntPtr items);
 void SetSlideshowOptions(uint options, uint tick);
 void GetSlideshowOptions(out uint options, out uint tick);
 void AdvanceSlideshow([MarshalAs(UnmanagedType.LPWStr)] string monitor, uint direction);
 void GetStatus(out uint state);
 void Enable([MarshalAs(UnmanagedType.Bool)] bool enable);
}
public static class Wallpaper {
 public static IDesktopWallpaper Open() {
  return (IDesktopWallpaper)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("C2CF3110-460E-4FC1-B9D0-8A1C0C9CC4BD")));
 }
}
'@
    $desktop = [Wallpaper]::Open()
    function Snapshot {
        [uint32]$color = 0; [uint32]$state = 0; [uint32]$count = 0
        $desktop.GetBackgroundColor([ref]$color); $desktop.GetStatus([ref]$state)
        $desktop.GetMonitorDevicePathCount([ref]$count)
        $paths = @{}
        for ([uint32]$i=0; $i -lt $count; $i++) {
            [string]$id = ''; [string]$path = ''
            $desktop.GetMonitorDevicePathAt($i, [ref]$id); $desktop.GetWallpaper($id, [ref]$path)
            $paths[$id] = $path
        }
        return @{ color=$color; enabled=(($state -band 1) -ne 0); paths=$paths }
    }
    function Restore {
        if (!(Test-Path $journal)) { return }
        $saved = Get-Content -Raw $journal | ConvertFrom-Json
        if ($env:METEOR_BG_COLOR -eq 'off' -and $env:METEOR_BG_OWNER -and $saved.owner -ne $env:METEOR_BG_OWNER) { return }
        $now = Snapshot
        # Do not overwrite a manual wallpaper/colour change. Enable(false) keeps
        # each monitor's wallpaper and slideshow configuration intact.
        $unchanged = $now.color -eq $saved.afterColor
        foreach ($property in $saved.before.paths.PSObject.Properties) {
            if ($now.paths[$property.Name] -ne $property.Value) { $unchanged = $false }
        }
        if ($unchanged) {
            $desktop.SetBackgroundColor([uint32]$saved.before.color)
            if (!$now.enabled) { $desktop.Enable([bool]$saved.before.enabled) }
        }
        Remove-Item $journal
    }
    Restore
    if ($env:METEOR_BG_COLOR -eq 'off') { exit 0 }
    $colors = @{ green=65280; blue=16711680; magenta=16711935 } # COLORREF: 0x00BBGGRR
    if (!$colors.ContainsKey($env:METEOR_BG_COLOR)) { throw 'Invalid background colour' }
    $before = Snapshot
    $saved = @{owner=$env:METEOR_BG_OWNER; before=$before; afterColor=$colors[$env:METEOR_BG_COLOR]}
    $temp = "$journal.tmp"
    [IO.File]::WriteAllText($temp, ($saved | ConvertTo-Json -Depth 6))
    Move-Item -Force $temp $journal
    try {
        $desktop.SetBackgroundColor([uint32]$saved.afterColor)
        $desktop.Enable($false)
    } catch { Restore; throw }
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
