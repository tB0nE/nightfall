param(
    [switch]$Uninstall
)
# Installs or uninstalls the SunshineVirtualDisplay IDD driver and the
# SunshineVirtualDisplayBroker service bundled with Meteor-Vibepollo.
# Requires elevation; self-elevates via UAC if not already running as admin.
$ErrorActionPreference = 'Stop'
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]'Administrator')) {
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Uninstall) { $args += '-Uninstall' }
    Start-Process powershell.exe -ArgumentList $args -Verb RunAs -Wait
    exit $LASTEXITCODE
}
$driverDir = Join-Path $PSScriptRoot 'runtime\host\drivers\sunshine'
$innerScript = Join-Path $driverDir 'install.ps1'
if (-not (Test-Path -LiteralPath $innerScript)) {
    Write-Error "Virtual display driver files not found at: $driverDir"
    exit 1
}
# The service runs as LocalSystem, so its exe must live somewhere only admins
# can write (Program Files), never in the per-user install folder. The staged
# copy beside the driver is just the source for that copy.
$brokerSource = Join-Path $driverDir 'virtualdisplay_broker.exe'
$brokerDir = Join-Path $env:ProgramFiles 'Nightfall Meteor'
$broker = Join-Path $brokerDir 'virtualdisplay_broker.exe'
$brokerSvc = 'SunshineVirtualDisplayBroker'
Write-Host "Virtual display driver directory: $driverDir"
if ($Uninstall) {
    # Stop and delete the broker service before uninstalling the driver.
    $svc = Get-Service -Name $brokerSvc -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Host "Stopping $brokerSvc service..."
        Stop-Service -Name $brokerSvc -Force -ErrorAction SilentlyContinue
        sc.exe delete $brokerSvc | Out-Null
        Write-Host "$brokerSvc service removed."
    }
    Remove-Item -LiteralPath $brokerDir -Recurse -Force -ErrorAction SilentlyContinue
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $innerScript -Uninstall -InstallerBestEffort
} else {
    # The broker must exist BEFORE the inner installer runs: its health-check
    # ladder recycles the broker to revive the driver without a reboot, and its
    # Start-VirtualDisplayBrokerIfNeeded is a no-op when the service is absent.
    # Creating it afterwards left that ladder with nothing to recycle, so a
    # first install fell through to "restart required".
    if (Test-Path -LiteralPath $brokerSource) {
        $svc = Get-Service -Name $brokerSvc -ErrorAction SilentlyContinue
        # An upgrade finds the service already running (possibly from the old
        # per-user location), which locks its exe. Stop it before replacing.
        if ($svc -and $svc.Status -ne 'Stopped') {
            Write-Host "Stopping $brokerSvc service..."
            Stop-Service -Name $brokerSvc -Force -ErrorAction SilentlyContinue
            $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
        }
        New-Item -ItemType Directory -Force -Path $brokerDir | Out-Null
        Copy-Item -LiteralPath $brokerSource -Destination $broker -Force
        $binPath = "`"$broker`" --service"
        if (-not $svc) {
            Write-Host "Creating $brokerSvc service..."
            New-Service -Name $brokerSvc `
                -BinaryPathName $binPath `
                -StartupType Automatic `
                -DisplayName "Sunshine Virtual Display Broker" `
                -Description "Manages Sunshine virtual display adapter for Vibepollo." | Out-Null
        } else {
            Write-Host "Pointing $brokerSvc at $broker..."
            sc.exe config $brokerSvc binPath= $binPath | Out-Null
        }
        # Earlier builds ran the service from the install folder; the service no
        # longer points there, so the leftover copy can go.
        Remove-Item -LiteralPath (Join-Path $PSScriptRoot 'runtime\host\tools\virtualdisplay_broker.exe') -Force -ErrorAction SilentlyContinue
        Write-Host "Starting $brokerSvc service..."
        try {
            Start-Service -Name $brokerSvc -ErrorAction Stop
            Write-Host "$brokerSvc service running."
        } catch {
            # The driver may not be installed yet; the check after the driver script starts it again.
            Write-Warning "$brokerSvc did not start yet: $($_.Exception.Message)"
        }
    } else {
        Write-Warning "Broker executable not found at: $brokerSource (virtual display API may not work)"
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $innerScript -InstallerBestEffort
    # Patch the device-object security descriptor to add Interactive Users so
    # Vibepollo (non-elevated user process) can open the control interface.
    # The shipped INF's HKR,,Security grants SY + the broker service SID only;
    # the driver's own source composes it with IU as well, but the signed
    # catalog predates that, and re-generating the INF would break the
    # signature. So the ACE is added post-install here instead.
    #
    # Windows reads this value when the device object is created, so the device
    # has to be restarted for it to take effect. That restart is the whole
    # reason a reboot used to be needed: Disable-PnpDevice fails on this device
    # ("Generic failure"), leaving the patch dormant until boot re-enumerated it.
    $hardwareId = 'Root\SunshineVirtualDisplay'
    $enumRoot = 'HKLM:\SYSTEM\CurrentControlSet\Enum\ROOT\DISPLAY'
    $pnputil = Join-Path $env:SystemRoot 'System32\pnputil.exe'

    # Find the device by hardware ID. The instance number is assigned by
    # Windows and is not always 0001, so it must never be hardcoded.
    $deviceKeys = @()
    if (Test-Path -LiteralPath $enumRoot) {
        $deviceKeys = @(
            Get-ChildItem -LiteralPath $enumRoot -ErrorAction SilentlyContinue | Where-Object {
                $props = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
                $props -and ($props.HardwareID -contains $hardwareId)
            }
        )
    }

    if ($deviceKeys.Count -eq 0) {
        Write-Warning "No device found for $hardwareId; SDDL patch skipped."
    }

    foreach ($deviceKey in $deviceKeys) {
        $devicePath = 'HKLM:\' + $deviceKey.Name.Substring('HKEY_LOCAL_MACHINE\'.Length)
        $instanceId = 'ROOT\DISPLAY\' + $deviceKey.PSChildName
        $patched = $false

        $existing = (Get-ItemProperty -LiteralPath $devicePath -Name Security -ErrorAction SilentlyContinue).Security
        if ($existing -and $existing -is [byte[]]) {
            $sd = New-Object System.Security.AccessControl.RawSecurityDescriptor($existing, 0)
            $iuSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-4')
            $alreadyPresent = $false
            foreach ($ace in $sd.DiscretionaryAcl) {
                if ($ace.SecurityIdentifier -eq $iuSid) { $alreadyPresent = $true; break }
            }
            if ($alreadyPresent) {
                Write-Host "Interactive Users already granted on $instanceId."
            } else {
                $sd.DiscretionaryAcl.InsertAce(
                    $sd.DiscretionaryAcl.Count,
                    (New-Object System.Security.AccessControl.CommonAce(
                        [System.Security.AccessControl.AceFlags]::None,
                        [System.Security.AccessControl.AceQualifier]::AccessAllowed,
                        0x10000000,
                        $iuSid,
                        $false,
                        $null
                    ))
                )
                $newBinary = New-Object byte[] $sd.BinaryLength
                $sd.GetBinaryForm($newBinary, 0)
                Set-ItemProperty -LiteralPath $devicePath -Name Security -Value $newBinary -Type Binary
                Write-Host "Patched device object SDDL on $instanceId to add Interactive Users."
                $patched = $true
            }
        } else {
            Write-Warning "No binary Security value on $instanceId; SDDL patch skipped."
        }

        if (-not $patched) { continue }

        # Apply it. pnputil /restart-device is the supported mechanism and is
        # what the driver's own recovery ladder uses; Disable/Enable-PnpDevice
        # is the fallback for builds of pnputil that lack the verb.
        $restarted = $false
        if (Test-Path -LiteralPath $pnputil) {
            & $pnputil /restart-device $instanceId 2>&1 | Write-Host
            if ($LASTEXITCODE -eq 0) { $restarted = $true }
        }
        if (-not $restarted) {
            Write-Host "pnputil /restart-device unavailable or failed on $instanceId; trying Disable/Enable-PnpDevice."
            Get-PnpDevice -InstanceId $instanceId -ErrorAction SilentlyContinue | ForEach-Object {
                Disable-PnpDevice -InputObject $_ -Confirm:$false -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 500
                Enable-PnpDevice -InputObject $_ -Confirm:$false -ErrorAction SilentlyContinue
            }
        }
        if (Test-Path -LiteralPath $pnputil) {
            & $pnputil /scan-devices 2>&1 | Out-Null
        }
    }

    # The driver script recycles the broker while it revives the device and can leave it
    # stopped; the host needs it running. Say so if it will not start, rather than leave a
    # service that is quietly down.
    $svc = Get-Service -Name $brokerSvc -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Running') {
        try {
            Start-Service -Name $brokerSvc -ErrorAction Stop
            Write-Host "$brokerSvc service running."
        } catch {
            Write-Warning "$brokerSvc did not start: $($_.Exception.Message)"
        }
    }

    # Confirm a non-elevated process can actually open the control interface.
    # Without this the installer can report success while Vibepollo still gets
    # ERROR_ACCESS_DENIED, which is exactly how this failed silently before.
    $probe = Join-Path $driverDir 'virtualdisplay_probe.exe'
    if ((Test-Path -LiteralPath $probe) -and $deviceKeys.Count -gt 0) {
        $diag = (& $probe --diagnose 2>&1 | Out-String)
        if ($diag -match 'openable=1') {
            Write-Host 'Virtual display control interface is reachable. Virtual monitors are ready to use.'
        } else {
            Write-Warning 'Virtual display control interface is still not openable.'
            Write-Warning 'Virtual monitors will not work until the machine is restarted.'
            Write-Host $diag
        }
    }
}
exit $LASTEXITCODE
