# Open/read/dismiss Meteor's native menu without selecting an action.
$ErrorActionPreference='Stop'
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class MeteorMenuRead {
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string name,string title);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent,IntPtr after,string name,string title);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window,out uint pid);
 [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window,uint message,IntPtr command,IntPtr value);
 [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr window,uint message,IntPtr command,IntPtr value);
 [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr menu);
 [DllImport("user32.dll")] public static extern IntPtr GetSubMenu(IntPtr menu,int item);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetMenuString(IntPtr menu,uint item,StringBuilder text,int length,uint flags);
}
'@
$owner=[MeteorMenuRead]::FindWindow('NightfallMeteorTray','NightfallMeteorTray')
if($owner -eq [IntPtr]::Zero){throw 'Meteor tray not found'}
[uint32]$ownerId=0;[void][MeteorMenuRead]::GetWindowThreadProcessId($owner,[ref]$ownerId)
$labels=[Collections.Generic.List[string]]::new()
function ReadMenu([IntPtr]$Menu,[int]$Depth) {
    if($Depth -gt 5){throw 'Menu nesting limit'}
    for($i=0;$i -lt [MeteorMenuRead]::GetMenuItemCount($Menu);$i++) {
        $text=[Text.StringBuilder]::new(512)
        [void][MeteorMenuRead]::GetMenuString($Menu,$i,$text,512,0x400)
        if($text.Length){$labels.Add($text.ToString())}
        $child=[MeteorMenuRead]::GetSubMenu($Menu,$i)
        if($child -ne [IntPtr]::Zero){ReadMenu $child ($Depth+1)}
    }
}
try {
    [void][MeteorMenuRead]::PostMessage($owner,0x8001,[IntPtr]::Zero,[IntPtr]0x205)
    $menu=[IntPtr]::Zero
    for($attempt=0;$attempt -lt 30;$attempt++) {
        $after=[IntPtr]::Zero
        do {
            $after=[MeteorMenuRead]::FindWindowEx([IntPtr]::Zero,$after,'#32768',$null)
            if($after -eq [IntPtr]::Zero){break}
            [uint32]$popupId=0;[void][MeteorMenuRead]::GetWindowThreadProcessId($after,[ref]$popupId)
            if($popupId -eq $ownerId){$menu=[MeteorMenuRead]::SendMessage($after,0x1e1,[IntPtr]::Zero,[IntPtr]::Zero);break}
        }while($after -ne [IntPtr]::Zero)
        if($menu -ne [IntPtr]::Zero){break};Start-Sleep -Milliseconds 100
    }
    if($menu -eq [IntPtr]::Zero){throw 'Meteor popup menu not found'}
    ReadMenu $menu 0
    $required=@('PCVR','PCVR ready','Open VR Apps in Nightfall','Moss','VRChat','Monado / xrizer','SteamVR')
    $missing=@($required | Where-Object {$_ -notin $labels})
    $summary=@{ok=($missing.Count -eq 0);check='windows-native-xr-tray';labels=@($labels.ToArray());missing=$missing}
    $target=Join-Path (Split-Path $PSScriptRoot) 'meteor\target'
    $summary | ConvertTo-Json -Depth 4 | Set-Content "$target\windows-native-tray-summary.json" -Encoding utf8
    $summary | ConvertTo-Json -Depth 4
    if($missing.Count){throw 'Expected PCVR menu entries missing'}
} finally {[void][MeteorMenuRead]::PostMessage($owner,0x1f,[IntPtr]::Zero,[IntPtr]::Zero)}
