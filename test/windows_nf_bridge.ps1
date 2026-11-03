param([string]$Request = '{"cmd":"state"}', [string]$LogPattern = '')
$ErrorActionPreference = 'Stop'
$client = [Net.Sockets.TcpClient]::new()
try {
    $client.Connect('127.0.0.1',47950)
    $stream = $client.GetStream()
    $stream.ReadTimeout = 5000
    $bytes = [Text.Encoding]::UTF8.GetBytes($Request + "`n")
    $stream.Write($bytes,0,$bytes.Length)
    $reader = [IO.StreamReader]::new($stream)
    $reply = $reader.ReadLine()
    if ($LogPattern) { ($reply | ConvertFrom-Json).lines | Select-String -Pattern $LogPattern }
    else { $reply }
} finally { $client.Dispose() }
