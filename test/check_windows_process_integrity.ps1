param([string[]]$Names=@('steam','nightfall-meteor','sunshine'))
$ErrorActionPreference='Stop'
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ProcessElevationCheck {
 [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,int pid);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr process,uint access,out IntPtr token);
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool GetTokenInformation(IntPtr token,int kind,out int value,int length,out int needed);
 public static int Elevated(int pid) {
  IntPtr process=OpenProcess(0x1000,false,pid);if(process==IntPtr.Zero)throw new System.ComponentModel.Win32Exception();
  try {IntPtr token;if(!OpenProcessToken(process,8,out token))throw new System.ComponentModel.Win32Exception();
   try {int value,needed;if(!GetTokenInformation(token,20,out value,4,out needed))throw new System.ComponentModel.Win32Exception();return value;}
   finally {CloseHandle(token);}
  }finally {CloseHandle(process);}
 }
}
'@
$items=@(foreach($name in $Names){foreach($p in Get-Process $name -ErrorAction SilentlyContinue){
    try {[pscustomobject]@{name=$p.ProcessName;pid=$p.Id;elevated=([ProcessElevationCheck]::Elevated($p.Id) -ne 0)}}
    catch {[pscustomobject]@{name=$p.ProcessName;pid=$p.Id;error=$_.Exception.Message}}
}})
$items | ConvertTo-Json -Compress
