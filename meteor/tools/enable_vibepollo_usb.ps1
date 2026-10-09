# Run elevated after checking that this is the Vibepollo/Apollo installation.
# Windows protects the service's configuration under Program Files.
$ErrorActionPreference = 'Stop'
$config = 'C:\Program Files\Apollo\config\sunshine.conf'
$backup = 'C:\Temp\sunshine.conf.pre-usb'
$result = 'C:\Temp\meteor-usb-config-result.txt'

try {
    if (-not (Test-Path -LiteralPath $config)) {
        throw "Vibepollo config not found: $config"
    }
    if (-not (Test-Path -LiteralPath $backup)) {
        Copy-Item -LiteralPath $config -Destination $backup
    }
    $lines = @(Get-Content -LiteralPath $config | Where-Object { $_ -notmatch '^\s*address_family\s*=' })
    $lines += 'address_family = both'
    Set-Content -LiteralPath $config -Value $lines -Encoding Ascii
    Restart-Service -Name ApolloService -Force
    Set-Content -LiteralPath $result -Value 'Vibepollo IPv4+IPv6 enabled; ApolloService restarted.'
} catch {
    Set-Content -LiteralPath $result -Value "Vibepollo USB setup failed: $_"
    throw
}
