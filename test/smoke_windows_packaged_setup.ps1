param([string]$Stage='')
# Relocated release + fresh AppData, restricted PATH, no headset and no games.
$ErrorActionPreference='Stop'
$target=Join-Path (Split-Path $PSScriptRoot) 'meteor\target'
if(-not $Stage){$Stage=Join-Path $target 'windows-release\Nightfall-Meteor-0.1.1-windows-x64'}
$root=Join-Path $env:TEMP ('Nightfall-packaged-check-'+[guid]::NewGuid().ToString('N'))
$install=Join-Path $root 'Programs\Nightfall Meteor'
$saved=@{APPDATA=$env:APPDATA;LOCALAPPDATA=$env:LOCALAPPDATA;PATH=$env:PATH}
$summary=@{ok=$false;headset=$false;root=$root;check='windows-packaged-setup';issues=@()}
try {
    New-Item -ItemType Directory -Force $install | Out-Null
    Copy-Item (Join-Path $Stage '*') $install -Recurse
    $env:APPDATA=Join-Path $root 'Roaming';$env:LOCALAPPDATA=Join-Path $root 'Local'
    $env:PATH="$env:SystemRoot\System32;$env:SystemRoot;$env:SystemRoot\System32\Wbem"
    $exe=Join-Path $install 'nightfall-meteor.exe'
    $manifest=Get-Content (Join-Path $install 'runtime\manifest.json') -Raw | ConvertFrom-Json
    foreach($file in $manifest.files) {
        $path=Join-Path $install ('runtime\'+$file.path)
        if((Get-FileHash $path -Algorithm SHA256).Hash -ine $file.sha256){throw "Package hash mismatch: $($file.path)"}
    }
    $summary.host_helpers=@()
    foreach($helper in 'sunshine_display_helper.exe','sunshine_wgc_capture.exe') {
        if(-not (Test-Path -LiteralPath (Join-Path $install "runtime\host\tools\$helper") -PathType Leaf)){throw "Missing bundled host helper: $helper"}
        $summary.host_helpers+=$helper
    }
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class PackageDllCheck {
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern IntPtr LoadLibraryEx(string path,IntPtr file,uint flags);
 [DllImport("kernel32.dll")] public static extern bool FreeLibrary(IntPtr module);
}
'@
    $summary.loaded_dlls=@()
    foreach($relative in @('ncnn.dll','meteor_vda_vulkan.dll','runtime\xr\bin\openxr_monado.dll','runtime\xr\bin\openxr_loader.dll','runtime\xr\bin\meteor-windows-nvenc.dll','runtime\xr\bin\meteor-windows-tracking.dll','runtime\xr\xrizer\bin\vrclient_x64.dll','runtime\xr\steamvr\bin\win64\driver_meteor.dll')) {
        $handle=[PackageDllCheck]::LoadLibraryEx((Join-Path $install $relative),[IntPtr]::Zero,8)
        if($handle -eq [IntPtr]::Zero){throw "Cannot load packaged $relative (Windows error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"}
        [void][PackageDllCheck]::FreeLibrary($handle)
        $summary.loaded_dlls+=$relative
    }
    & (Join-Path $install 'Setup-Meteor.ps1') -EnableHost -EnablePCVR -Quiet | Out-Null
    if($LASTEXITCODE){throw 'Packaged setup failed'}
    $setup=Get-Content (Join-Path $env:LOCALAPPDATA 'Nightfall Meteor\setup-summary.json') -Raw | ConvertFrom-Json
    if(-not $setup.ok -or -not $setup.host_enabled -or -not $setup.pcvr_enabled -or $setup.games.Count -ne 2){throw 'Expected host and both installed VR games to be configured'}
    $catalog=Join-Path $env:LOCALAPPDATA 'Nightfall Meteor\xr\windows'
    $options=[IO.File]::ReadAllText((Join-Path $catalog 'steam-launch-options.txt'))
    if(-not $options.Contains('--xr-steam-run') -or -not $options.Contains($exe)){throw 'Packaged GUI CLI did not return complete Steam options'}
    . (Join-Path $install 'Meteor-Cli.ps1')
    $rejected=$false
    try {Invoke-MeteorCli -Executable $exe -Options @('--xr-steam-options') | Out-Null}catch{$rejected=$true}
    if(-not $rejected){throw 'CLI helper lost a failing command exit status'}
    foreach($profile in Get-ChildItem (Join-Path $catalog 'profiles') -Recurse -Filter 'xr-windows.json') {
        $config=Get-Content $profile.FullName -Raw | ConvertFrom-Json
        foreach($name in 'service','manifest','encoder','tracking') {
            if(-not $config.$name.StartsWith($install,[StringComparison]::OrdinalIgnoreCase)){throw "Profile $name escapes the installed runtime"}
        }
        foreach($dir in $config.library_dirs){if(-not $dir.StartsWith($install,[StringComparison]::OrdinalIgnoreCase)){throw 'Profile references a development DLL directory'}}
    }
    & (Join-Path $install 'Setup-Meteor.ps1') -EnableHost -EnablePCVR -Quiet | Out-Null
    if($LASTEXITCODE){throw 'Repeated packaged setup failed'}
    $summary.setup=$setup;$summary.catalog=$catalog;$summary.executable=$exe;$summary.ok=$true
} catch {$summary.error=$_.Exception.Message;throw} finally {
    foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name],'Process')}
    $summary | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $target 'windows-packaged-setup-summary.json') -Encoding utf8
}
