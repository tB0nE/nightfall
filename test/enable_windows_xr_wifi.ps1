param([string]$HostAddress='10.0.0.13',[string]$QuestAddress='10.0.0.12')
# Run elevated. Limit this diagnostic rule to the selected LAN endpoints,
# release XR test executable, and the three authenticated TCP channels.
$ErrorActionPreference='Stop'
foreach($value in @($HostAddress,$QuestAddress)) {
    $address=[Net.IPAddress]::Parse($value)
    if($address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
        [Net.IPAddress]::IsLoopback($address) -or $address.Equals([Net.IPAddress]::Any)) {throw 'Use specific LAN IPv4 addresses'}
}
$repo=Split-Path $PSScriptRoot
$executable=(Resolve-Path (Join-Path $repo 'meteor\target\release\nightfall-meteor-xr-dev.exe')).Path
$name='NightfallMeteorXRWirelessTrial'
if(Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue) {Remove-NetFirewallRule -Name $name}
New-NetFirewallRule -Name $name -DisplayName 'Nightfall Meteor XR wireless trial' `
    -Direction Inbound -Action Allow -Enabled True -Profile Any -Program $executable `
    -Protocol TCP -LocalPort 49100,49101,49102 -LocalAddress $HostAddress -RemoteAddress $QuestAddress `
    -EdgeTraversalPolicy Block | Out-Null
Write-Output "XR wireless rule enabled: $QuestAddress -> $HostAddress TCP 49100-49102"
