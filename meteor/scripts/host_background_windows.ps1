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
// PowerShell sees the COM object, not this interface, and can't call its methods
// ("does not contain a method named GetBackgroundColor"): call them from C#.
public class Wallpaper {
 readonly IDesktopWallpaper d = (IDesktopWallpaper)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("C2CF3110-460E-4FC1-B9D0-8A1C0C9CC4BD")));
 public uint GetColor() { uint c; d.GetBackgroundColor(out c); return c; }
 public void SetColor(uint c) { d.SetBackgroundColor(c); }
 public uint GetState() { uint s; d.GetStatus(out s); return s; }
 public void Enable(bool on) { d.Enable(on); }
 public string[] Monitors() {
  uint n; d.GetMonitorDevicePathCount(out n);
  var ids = new string[n];
  for (uint i = 0; i < n; i++) { string id; d.GetMonitorDevicePathAt(i, out id); ids[i] = id; }
  return ids;
 }
 public string GetPath(string monitor) { string p; d.GetWallpaper(monitor, out p); return p; }
}
'@
    $desktop = New-Object Wallpaper
    function Snapshot {
        $paths = @{}
        foreach ($id in $desktop.Monitors()) { $paths[$id] = $desktop.GetPath($id) }
        return @{ color=$desktop.GetColor(); enabled=(($desktop.GetState() -band 1) -ne 0); paths=$paths }
    }
    function Restore {
        if (!(Test-Path $journal)) { return }
        $saved = Get-Content -Raw $journal | ConvertFrom-Json
        if ($env:METEOR_BG_COLOR -eq 'off' -and $env:METEOR_BG_OWNER -and $saved.owner -ne $env:METEOR_BG_OWNER) { return }
        $now = Snapshot
        # Do not overwrite a manual change. While the wallpaper is off Windows reports
        # no wallpaper paths, so they can't tell; choosing a wallpaper turns it back
        # on, and choosing a colour changes it. Enable(false) keeps each monitor's
        # wallpaper and slideshow configuration intact.
        if ($now.color -eq $saved.afterColor) {
            $desktop.SetColor([uint32]$saved.before.color)
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
        $desktop.SetColor([uint32]$saved.afterColor)
        $desktop.Enable($false)
    } catch { Restore; throw }
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
