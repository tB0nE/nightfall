# One-time recovery of Steam client's stuck VR initialization flag. This does
# not alter SteamVR driver blocking, fabricate a successful build, or disable
# crash protection. Steam must stop cleanly before its config can be changed.
param([string]$SteamRoot='C:\Program Files (x86)\Steam')
$ErrorActionPreference='Stop'
if(Get-Process VRChat,vrserver,vrcompositor,vrmonitor -ErrorAction SilentlyContinue){throw 'Close active VR games/runtime before Steam recovery'}
$steam=(Resolve-Path (Join-Path $SteamRoot 'steam.exe')).Path
$config=Join-Path $SteamRoot 'config\config.vdf'
$running=@(Get-Process steam -ErrorAction SilentlyContinue)
$restart=$running.Count -gt 0
try {
    if($restart) {
        Start-Process $steam -ArgumentList '-shutdown' | Out-Null
        $deadline=[DateTime]::UtcNow.AddSeconds(30)
        while((Get-Process steam -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 200}
        if(Get-Process steam -ErrorAction SilentlyContinue){throw 'Steam did not exit cleanly; configuration was not changed'}
    }
    $text=[IO.File]::ReadAllText($config)
    $section=[regex]::Match($text,'(?ms)^\t"VR"\r?\n\t\{\r?\n(?<body>.*?)^\t\}')
    if(-not $section.Success){throw 'Steam VR config section not found; no changes made'}
    $flag=[regex]::Match($section.Groups['body'].Value,'(?m)^\t\t"AttemptingInit"\s+"(?<value>[01])"')
    if(-not $flag.Success){throw 'Recognized Steam VR initialization marker not found; no changes made'}
    if($flag.Groups['value'].Value -eq '1') {
        $backup="$config.before-meteor-vr-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')).bak"
        Copy-Item $config $backup -ErrorAction Stop
        $offset=$section.Groups['body'].Index+$flag.Groups['value'].Index
        $updated=$text.Remove($offset,1).Insert($offset,'0')
        # The only mutation is a same-length single ASCII digit.
        if($updated.Length -ne $text.Length){throw 'Unexpected config mutation'}
        [IO.File]::WriteAllText($config,$updated,[Text.UTF8Encoding]::new($false))
        Write-Output 'Reset only VR/AttemptingInit from 1 to 0; original config backed up beside it.'
    } else {Write-Output 'Steam cleared VR/AttemptingInit during its clean shutdown; no edit needed.'}
} finally {
    if($restart -and -not (Get-Process steam -ErrorAction SilentlyContinue)){Start-Process $steam | Out-Null}
}
