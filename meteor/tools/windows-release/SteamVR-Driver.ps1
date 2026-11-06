param([ValidateSet('Status','Register','Unregister')][string]$Action='Status',
    [string]$AppRoot=$PSScriptRoot,[string]$SteamVRRoot='',[switch]$Preview)
# Per-user registration through Valve's installed tool. Never replace vrpaths.
$ErrorActionPreference='Stop'
$record=Join-Path $env:LOCALAPPDATA 'Nightfall Meteor\steamvr-driver-registration.json'
$driver=[IO.Path]::GetFullPath((Join-Path $AppRoot 'runtime\xr\steamvr')).TrimEnd('\')
function SamePath([string]$Left,[string]$Right) {
    if(-not $Left -or -not $Right){return $false}
    return [IO.Path]::GetFullPath($Left).TrimEnd('\') -ieq [IO.Path]::GetFullPath($Right).TrimEnd('\')
}
if(-not $SteamVRRoot -and (Test-Path -LiteralPath $record)) {
    $saved=Get-Content -LiteralPath $record -Raw | ConvertFrom-Json
    if(SamePath $saved.driver $driver){$SteamVRRoot=$saved.runtime}
}
if(-not $SteamVRRoot){throw 'Supply the installed SteamVR directory.'}
$tool=Join-Path $SteamVRRoot 'bin\win64\vrpathreg.exe'
if(-not (Test-Path -LiteralPath $tool -PathType Leaf)){throw "SteamVR registration tool missing: $tool"}
$paths=Join-Path $env:LOCALAPPDATA 'openvr\openvrpaths.vrpath'
$external=@()
if(Test-Path -LiteralPath $paths) {
    if((Get-Item -LiteralPath $paths).Length -gt 1MB){throw 'OpenVR registration file exceeds 1 MiB'}
    $external=@((Get-Content -LiteralPath $paths -Raw | ConvertFrom-Json).external_drivers)
}
$registered=@($external | Where-Object {$_ -and (SamePath $_ $driver)}).Count -gt 0
$operation=$null
if($Action -eq 'Register') {
    foreach($file in @('driver.vrdrivermanifest','bin\win64\driver_meteor.dll')) {
        if(-not (Test-Path -LiteralPath (Join-Path $driver $file) -PathType Leaf)){throw "Meteor SteamVR driver missing: $file"}
    }
    foreach($other in $external) {
        if(-not $other -or (SamePath $other $driver)){continue}
        $manifest=Join-Path $other 'driver.vrdrivermanifest'
        if((Test-Path -LiteralPath $manifest) -and (Get-Item -LiteralPath $manifest).Length -lt 16KB) {
            try {$name=(Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json).name}catch{$name=''}
            if($name -eq 'meteor'){throw "Another Meteor driver is registered at $other. Remove that registration before changing installations."}
        }
    }
    if(-not $registered){$operation='adddriver'}
} elseif($Action -eq 'Unregister' -and $registered) {
    $operation='removedriver'
}
if($operation -and -not $Preview) {
    # Inherited developer overrides must never redirect installed registration.
    $old=$env:VR_PATHREG_OVERRIDE
    try {
        Remove-Item Env:VR_PATHREG_OVERRIDE -ErrorAction SilentlyContinue
        & $tool $operation $driver | Out-Null
        if($LASTEXITCODE){throw "SteamVR $operation failed ($LASTEXITCODE)"}
    } finally {
        if($null -ne $old){$env:VR_PATHREG_OVERRIDE=$old}
    }
    $registered=$Action -eq 'Register'
}
if(-not $Preview -and $Action -eq 'Register') {
    New-Item -ItemType Directory -Force (Split-Path $record) | Out-Null
    [IO.File]::WriteAllText($record,(@{driver=$driver;runtime=[IO.Path]::GetFullPath($SteamVRRoot)} | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
} elseif(-not $Preview -and $Action -eq 'Unregister' -and (Test-Path -LiteralPath $record)) {
    $saved=Get-Content -LiteralPath $record -Raw | ConvertFrom-Json
    if(SamePath $saved.driver $driver){Remove-Item -LiteralPath $record}
}
@{action=$Action;driver=$driver;registered=$registered;operation=$operation;preview=[bool]$Preview} | ConvertTo-Json -Compress
