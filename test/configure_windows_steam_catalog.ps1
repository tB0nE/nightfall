param([string]$Root='', [string]$Executable='',
    [string]$SteamRoot='C:\Program Files (x86)\Steam',
    [string[]]$AppIds=@('846470','438100'),[switch]$Apply,[switch]$SelfTest,
    [switch]$RemoveMeteorOptions,[switch]$NoRestart)
# Surgical edits to only the active Steam user's selected LaunchOptions.
# Preview by default. Custom existing launch options require manual review.
$ErrorActionPreference='Stop'
function Plan([string]$Text,[string[]]$Ids,[string]$Options,[string]$PreviousOptions='') {
    $tokens=[regex]::Matches($Text,'//[^\r\n]*|"(?:\\.|[^"\\])*"|[{}]')
    $stack=[Collections.Generic.List[string]]::new();$found=@{};$edits=[Collections.Generic.List[object]]::new()
    for($i=0;$i -lt $tokens.Count;$i++) {
        $token=$tokens[$i];if($token.Value.StartsWith('//')){continue}
        if($token.Value -eq '}') {
            if(-not $stack.Count){throw 'Unbalanced Steam VDF'}
            $path=$stack -join '/'
            foreach($id in $Ids) {
                if($path -ieq "UserLocalConfigStore/Software/Valve/Steam/apps/$id") {
                    if(-not $found.ContainsKey($id)) {
                        $line=$Text.LastIndexOf("`n",$token.Index)+1
                        $indent=$Text.Substring($line,$token.Index-$line)
                        $escaped=$Options.Replace('\','\\').Replace('"','\"')
                        $edits.Add(@{start=$line;length=0;text=($indent+"`t"+'"LaunchOptions"'+"`t`t"+'"'+$escaped+'"'+"`n")})
                        $found[$id]=''
                    }
                }
            }
            $stack.RemoveAt($stack.Count-1);continue
        }
        if(-not $token.Value.StartsWith('"')){throw 'Unsupported Steam VDF token'}
        $key=$token.Value.Substring(1,$token.Value.Length-2)
        $i++;while($i -lt $tokens.Count -and $tokens[$i].Value.StartsWith('//')){$i++}
        if($i -ge $tokens.Count){throw 'Truncated Steam VDF'}
        $value=$tokens[$i]
        if($value.Value -eq '{'){$stack.Add($key);continue}
        if(-not $value.Value.StartsWith('"')){throw 'Unsupported Steam VDF value'}
        foreach($id in $Ids) {
            if(($stack -join '/') -ieq "UserLocalConfigStore/Software/Valve/Steam/apps/$id" -and $key -ieq 'LaunchOptions') {
                if($found.ContainsKey($id)){throw 'Duplicate Steam launch options'}
                $old=$value.Value.Substring(1,$value.Value.Length-2).Replace('\\','\').Replace('\"','"')
                $found[$id]=$old
                if($old -eq $Options){continue}
                if($old.Length -and $old -ne $PreviousOptions){throw "Steam app $id has custom launch options; preserve/review them manually"}
                $escaped=$Options.Replace('\','\\').Replace('"','\"')
                $edits.Add(@{start=$value.Index;length=$value.Length;text=('"'+$escaped+'"')})
            }
        }
    }
    if($stack.Count){throw 'Unbalanced Steam VDF'}
    foreach($id in $Ids){if(-not $found.ContainsKey($id)){throw "Steam app $id was not found in the active user's app settings"}}
    $updated=$Text
    foreach($edit in ($edits | Sort-Object start -Descending)){$updated=$updated.Remove($edit.start,$edit.length).Insert($edit.start,$edit.text)}
    return @{text=$updated;edits=$edits.Count}
}
if($SelfTest) {
    $fixture="`"UserLocalConfigStore`" { `"Software`" { `"Valve`" { `"Steam`" { `"apps`" { `"42`" {`n`t`t`"name`" `"literal { brace }`"`n`t}`n} } } } }"
    $options='"C:\Program Files\Meteor.exe" --xr-steam-run --root "C:\User Data\xr" -- %command%'
    $first=Plan $fixture @('42') $options
    if($first.edits -ne 1 -or (Plan $first.text @('42') $options).edits -ne 0){throw 'VDF edit round-trip failed'}
    $rejected=$false;try{Plan $first.text @('42') 'different wrapper' | Out-Null}catch{$rejected=$true}
    if(-not $rejected){throw 'Custom launch options must be preserved'}
    $removed=Plan $first.text @('42') '' $options
    if($removed.edits -ne 1 -or (Plan $removed.text @('42') '').edits -ne 0){throw 'Meteor removal round-trip failed'}
    Write-Output 'PASS: surgical Steam VDF insertion, quoted braces, escaped paths, idempotence and custom-option rejection';return
}
$target=Join-Path (Split-Path $PSScriptRoot) 'meteor\target'
if(-not $Root){$Root=Join-Path $env:LOCALAPPDATA 'Nightfall Meteor\xr\windows'}
if(-not $Executable){$Executable=Join-Path $target 'release\nightfall-meteor.exe'}
. (Join-Path (Split-Path $PSScriptRoot) 'meteor\tools\windows-release\Meteor-Cli.ps1')
$expected=Invoke-MeteorCli -Executable $Executable -Options @('--xr-steam-options','--root',$Root)
$options=if($RemoveMeteorOptions){''}else{$expected}
$previous=if($RemoveMeteorOptions){$expected}else{''}
$user=(Get-ItemProperty 'HKCU:\Software\Valve\Steam\ActiveProcess' -Name ActiveUser).ActiveUser
if(-not $user){throw 'No active Steam account'}
$config=Join-Path $SteamRoot "userdata\$user\config\localconfig.vdf"
if((Get-Item $config).Length -gt 16MB){throw 'Steam user config exceeds 16 MiB'}
$preview=Plan ([IO.File]::ReadAllText($config)) $AppIds $options $previous
Write-Output "Steam app IDs: $($AppIds -join ', ')"
Write-Output $options
if(-not $Apply -or $preview.edits -eq 0){Write-Output "planned_changes=$($preview.edits)";return}
if(Get-Process VRChat,Moss-Win64-Shipping,vrserver,vrcompositor -ErrorAction SilentlyContinue){throw 'Close active VR games/runtime before changing Steam options'}
$steam=(Resolve-Path (Join-Path $SteamRoot 'steam.exe')).Path
$restart=@(Get-Process steam -ErrorAction SilentlyContinue).Count -gt 0
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if($restart -and -not $NoRestart -and $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Refusing to restart Steam from an elevated process. Run normally, or use -NoRestart and open Steam normally afterwards.'
}
try {
    if($restart) {
        Start-Process $steam -ArgumentList '-shutdown' | Out-Null
        $deadline=[DateTime]::UtcNow.AddSeconds(30)
        while((Get-Process steam -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 200}
        if(Get-Process steam -ErrorAction SilentlyContinue){throw 'Steam did not exit cleanly; settings unchanged'}
    }
    $text=[IO.File]::ReadAllText($config);$plan=Plan $text $AppIds $options $previous
    $backup="$config.before-meteor-launch-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')).bak"
    Copy-Item $config $backup
    [IO.File]::WriteAllText($config,$plan.text,[Text.UTF8Encoding]::new($false))
    if((Plan ([IO.File]::ReadAllText($config)) $AppIds $options).edits -ne 0){Copy-Item $backup $config -Force;throw 'Steam options verification failed; backup restored'}
    Write-Output "Applied $($plan.edits) launch-option edits; original config backed up beside it."
} finally {if($restart -and -not $NoRestart -and -not (Get-Process steam -ErrorAction SilentlyContinue)){Start-Process $steam | Out-Null}}
