# Real Windows Forms/UI automation, fake CLI host: no headset or real pairing.
param([string]$Stage='')
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
if(-not $Stage){$Stage=Join-Path $repo 'meteor\tools\windows-release'}
$root=Join-Path $repo ('meteor\target\pairing-dialog-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $root | Out-Null
$process=$null;$summary=@{ok=$false;real_host_used=$false;headset_used=$false}
try {
    foreach($file in 'Pair-Headset.ps1','Meteor-Cli.ps1') {
        Copy-Item (Join-Path $Stage $file) $root
    }
    Add-Type -OutputAssembly (Join-Path $root 'nightfall-meteor.exe') -OutputType ConsoleApplication -TypeDefinition @'
using System;
public static class FakePairingHost {
 public static int Main(string[] args) {
  if(args.Length!=1 || args[0]!="--host-pair-pin" || Console.In.ReadToEnd()!="0123") return 1;
  Console.WriteLine("PIN sent. Finish pairing in Nightfall."); return 0;
 }
}
'@
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class PairingUiMessages {
 [DllImport("user32.dll",EntryPoint="SendMessageW",CharSet=CharSet.Unicode)] public static extern IntPtr SetText(IntPtr h,uint m,IntPtr w,string text);
 [DllImport("user32.dll",EntryPoint="SendMessageW")] public static extern IntPtr Click(IntPtr h,uint m,IntPtr w,IntPtr l);
}
'@
    $process=Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"'+(Join-Path $root 'Pair-Headset.ps1')+'"')) -RedirectStandardError (Join-Path $root 'dialog-error.log') -PassThru
    $deadline=[DateTime]::UtcNow.AddSeconds(15);$window=$null
    while([DateTime]::UtcNow -lt $deadline) {
        $condition=[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty,$process.Id)
        $window=[Windows.Automation.AutomationElement]::RootElement.FindFirst([Windows.Automation.TreeScope]::Children,$condition)
        if($window -and $window.Current.Name -eq 'Pair Nightfall headset'){break}
        $window=$null;Start-Sleep -Milliseconds 100
    }
    if(-not $window){throw 'Pairing dialog did not open'}
    $deadline=[DateTime]::UtcNow.AddSeconds(10);$edit=$null
    while([DateTime]::UtcNow -lt $deadline) {
        $edit=$window.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition) | Where-Object {$_.Current.ClassName -like 'WindowsForms10.EDIT.*'} | Select-Object -First 1
        if($edit){break};Start-Sleep -Milliseconds 100
    }
    if(-not $edit){
        $summary.controls=@($window.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition) | ForEach-Object { $_.Current.Name+' / '+$_.Current.ControlType.ProgrammaticName+' / '+$_.Current.ClassName })
        throw 'Pairing PIN field did not become ready'
    }
    [void][PairingUiMessages]::SetText([IntPtr]$edit.Current.NativeWindowHandle,0x000C,[IntPtr]::Zero,'0123')
    $send=$window.FindFirst([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty,'Send PIN'))
    [void][PairingUiMessages]::Click([IntPtr]$send.Current.NativeWindowHandle,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)
    $deadline=[DateTime]::UtcNow.AddSeconds(10);$success=$null
    while([DateTime]::UtcNow -lt $deadline) {
        $success=$window.FindFirst([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty,'PIN sent. Finish pairing in Nightfall.'))
        if($success){break};Start-Sleep -Milliseconds 100
    }
    if(-not $success){throw 'PIN did not reach the fake CLI over stdin'}
    $window.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close()
    if(-not $process.WaitForExit(5000)){throw 'Pairing dialog did not close'}
    $summary.ok=$true
} catch {$summary.error=$_.Exception.Message;$summary.line=$_.InvocationInfo.ScriptLineNumber} finally {
    if($process -and -not $process.HasExited){Stop-Process -Id $process.Id}
    $summary | ConvertTo-Json | Set-Content (Join-Path $root 'summary.json')
}
$summary | ConvertTo-Json
if(-not $summary.ok){exit 1}
