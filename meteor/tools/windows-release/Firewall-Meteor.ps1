param(
    [switch]$Remove,
    [switch]$Check,
    # Meteor's install folder; the script normally sits in it.
    [string]$Root = $PSScriptRoot
)
# Lets the Quest reach Meteor and its host through Windows Firewall.
#
# Windows otherwise makes these rules itself, the first time each program
# listens, from an "Allow access" prompt. That prompt is easy to miss or
# cancel (which makes block rules), and it never comes back once any rule
# names the program, even a disabled one. Setup runs this script in its one
# elevated step instead, so a fresh install works without the prompt.
#
#   (no switch)  Add the rules. Needs administrator rights.
#   -Remove      Remove the rules this script added. Needs administrator rights.
#   -Check       Print "open" or "blocked: <reason>". No rights needed; Meteor
#                runs this to tell the user when the Quest can't get through.
$ErrorActionPreference = 'Stop'
$group = 'Nightfall Meteor'
$programs = @(
    @{ name = 'Nightfall Meteor'; path = (Join-Path $Root 'nightfall-meteor.exe') },
    @{ name = 'Nightfall Meteor host'; path = (Join-Path $Root 'runtime\host\sunshine.exe') }
)

# Inbound rules that name exactly this program.
function RulesFor([string]$path) {
    @(Get-NetFirewallApplicationFilter -Program $path -ErrorAction SilentlyContinue |
        Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object { $_.Direction -eq 'Inbound' })
}

# The profiles of the networks with a default route: where the Quest connects from.
function ActiveProfiles {
    $categories = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue |
        Where-Object { $_.IPv4DefaultGateway -or $_.IPv6DefaultGateway } |
        ForEach-Object { $_.NetProfile.NetworkCategory } | Where-Object { $null -ne $_ })  # Public is 0
    if (-not $categories.Count) {
        $categories = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object { $_.NetworkCategory })
    }
    @($categories | ForEach-Object { if ("$_" -eq 'DomainAuthenticated') { 'Domain' } else { "$_" } } | Select-Object -Unique)
}

function Covers($rule, [string]$profileName) {
    $p = "$($rule.Profile)"
    $p -eq 'Any' -or ($p -split ',\s*') -contains $profileName
}

if ($Check) {
    $issues = @()
    $profiles = ActiveProfiles
    $enabled = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -and $profiles -contains "$($_.Name)" })
    if ($enabled.Count) {
        foreach ($program in $programs) {
            if (-not (Test-Path -LiteralPath $program.path)) { continue }
            $rules = RulesFor $program.path | Where-Object { $_.Enabled -eq 'True' }
            foreach ($fw in $enabled) {
                $profileName = "$($fw.Name)"
                $applies = @($rules | Where-Object { Covers $_ $profileName })
                if ($applies | Where-Object { $_.Action -eq 'Block' }) {
                    $issues += "a rule blocks $($program.name) on $profileName networks"
                } elseif (-not ($applies | Where-Object { $_.Action -eq 'Allow' })) {
                    $issues += "no rule allows $($program.name) on $profileName networks"
                }
            }
        }
    }
    if ($issues.Count) { Write-Output ('blocked: ' + ($issues -join '; ')); exit 1 }
    Write-Output 'open'
    exit 0
}

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]'Administrator')) {
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Remove) { $arguments += '-Remove' }
    if ($Root -ne $PSScriptRoot) { $arguments += @('-Root', "`"$Root`"") }
    $process = Start-Process powershell.exe -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    exit $process.ExitCode
}

Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue | Remove-NetFirewallRule
if ($Remove) {
    Write-Host 'Removed the Nightfall Meteor firewall rules.'
    exit 0
}
foreach ($program in $programs) {
    if (-not (Test-Path -LiteralPath $program.path)) {
        Write-Warning "Missing $($program.path); no firewall rule added for it."
        continue
    }
    # Rules Windows made for this exact path from an earlier prompt: block rules
    # from a cancelled prompt would override the allow rule below, and disabled
    # ones only stop Windows asking again. Both are stale once Setup decides.
    foreach ($rule in RulesFor $program.path | Where-Object { $_.Action -eq 'Block' -or $_.Enabled -ne 'True' }) {
        Write-Host "Removing stale rule '$($rule.DisplayName)' ($($rule.Action), enabled=$($rule.Enabled)) for $($program.path)"
        $rule | Remove-NetFirewallRule
    }
    # Home networks are often classed as Public, and the Quest must work there.
    New-NetFirewallRule -DisplayName $program.name -Group $group -Direction Inbound -Action Allow `
        -Program $program.path -Profile Any -Description 'Lets a Nightfall headset reach this PC.' | Out-Null
    Write-Host "Allowed $($program.path) through Windows Firewall."
}
exit 0
