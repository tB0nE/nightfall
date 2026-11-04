param([ValidateRange(0,600)][int]$WatchSeconds=0,[string]$OutputFile='')
# Read visible VRChat/EAC dialog text without attaching to or modifying a game.
$ErrorActionPreference='Stop'
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class MeteorVrDialogs {
    delegate bool WindowCallback(IntPtr window, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumWindows(WindowCallback callback, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, WindowCallback callback, IntPtr data);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr window,StringBuilder text,int size);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr window,StringBuilder text,int size);
    [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr SendMessageTimeout(IntPtr window,uint message,UIntPtr wparam,StringBuilder text,uint flags,uint timeout,out UIntPtr result);
    static string Text(IntPtr window) {var text=new StringBuilder(2048);GetWindowText(window,text,text.Capacity);return text.ToString();}
    static string Class(IntPtr window) {var text=new StringBuilder(256);GetClassName(window,text,text.Capacity);return text.ToString();}
    static string ControlText(IntPtr window) {
        // GetWindowText cannot reliably retrieve another process's controls.
        // WM_GETTEXT is the documented UI message, bounded for hung dialogs.
        var text=new StringBuilder(8192);UIntPtr result;
        SendMessageTimeout(window,0x000D,(UIntPtr)text.Capacity,text,2,100,out result);
        return text.ToString();
    }
    public static string[] Read(int[] processes) {
        var selected=new HashSet<int>(processes);var lines=new List<string>();
        EnumWindows((window,data)=>{
            uint pid;GetWindowThreadProcessId(window,out pid);
            if(!IsWindowVisible(window))return true;
            var title=Text(window);
            var pattern="Easy Anti.?Cheat|^EAC|VRChat|Untrusted system file";
            if(!selected.Contains((int)pid) && Class(window)!="#32770" && !System.Text.RegularExpressions.Regex.IsMatch(title,pattern,System.Text.RegularExpressions.RegexOptions.IgnoreCase))return true;
            var contents=new List<string>();
            EnumChildWindows(window,(child,unused)=>{var value=ControlText(child);if(value.Length>0)contents.Add(value);return true;},IntPtr.Zero);
            if(!selected.Contains((int)pid) && !System.Text.RegularExpressions.Regex.IsMatch(title+"\n"+String.Join("\n",contents),pattern,System.Text.RegularExpressions.RegexOptions.IgnoreCase))return true;
            lines.Add("pid="+pid+" window="+title);lines.AddRange(contents);
            return true;
        },IntPtr.Zero);
        return lines.ToArray();
    }
}
'@
$deadline=[DateTime]::UtcNow.AddSeconds($WatchSeconds)
$previous=$null
do {
    $processes=@(Get-Process | Where-Object {$_.ProcessName -match '^(VRChat|start_protected_game|EasyAntiCheat.*)$'} | ForEach-Object {$_.Id})
    $lines=@([MeteorVrDialogs]::Read([int[]]$processes))
    $signature=$lines -join "`n"
    if($signature -ne $previous) {
        $record=@{utc=[DateTime]::UtcNow.ToString('o');lines=$lines} | ConvertTo-Json -Compress
        Write-Output $record
        if($OutputFile) {Add-Content -Path $OutputFile -Value $record -Encoding UTF8}
        $previous=$signature
    }
    if($WatchSeconds -eq 0) {break}
    Start-Sleep -Milliseconds 500
} while([DateTime]::UtcNow -lt $deadline)
