# Local activation request only: no executable paths or game arguments.
$ErrorActionPreference='Stop'
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$pipe=[IO.Pipes.NamedPipeClientStream]::new('.',"Nightfall.Meteor.SteamVR.$sid",[IO.Pipes.PipeDirection]::InOut)
try {
    $pipe.Connect(2000)
    $request=[Text.Encoding]::ASCII.GetBytes('MDS2')
    $pipe.Write($request,0,4);$pipe.Flush()
    $reader=[IO.BinaryReader]::new($pipe)
    $length=$reader.ReadUInt32()
    if($length -gt 16384){throw 'Invalid bootstrap reply size'}
    $bytes=$reader.ReadBytes($length)
    if($bytes.Length -ne $length){throw 'Truncated bootstrap reply'}
    $pipe.WriteByte(33);$pipe.Flush()
    @{ok=$true;settings_ready=($length -gt 0)} | ConvertTo-Json -Compress
} finally {$pipe.Dispose()}
