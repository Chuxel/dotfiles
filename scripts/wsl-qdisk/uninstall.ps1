<#
.SYNOPSIS
    Removes the Windows and Ubuntu integration installed by setup.ps1.

.DESCRIPTION
    The VHDX is detached but retained by default. Deleting it requires both -DeleteVhdx
    and an exact confirmation phrase supplied through -ConfirmVhdxDeletion.
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$DistroName = 'Ubuntu',

    [ValidateNotNullOrEmpty()]
    [string]$VhdxPath = 'Q:\WSL\Ubuntu\qdisk.vhdx',

    [ValidatePattern('^[A-Za-z0-9._-]{1,16}$')]
    [string]$DiskLabel = 'qdisk',

    [ValidatePattern('^/[^\r\n]*$')]
    [string]$MountPoint = '/home/clantz/Repos',

    [ValidateNotNullOrEmpty()]
    [string]$TaskName = 'WSL Ubuntu qdisk mount',

    [switch]$DeleteVhdx,

    [string]$ConfirmVhdxDeletion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:HelperPath = '/usr/local/sbin/mount-qdisk'
$script:HelperMarker = '# Managed by chuxel/dotfiles scripts/wsl-qdisk.'
$script:SystemdMarker = '# wsl-qdisk: added systemd setting'
$script:BootCommandMarker = '# wsl-qdisk: added boot command'
$script:AppendedCommandMarker = '# wsl-qdisk: appended mount helper'
$script:BootSectionMarker = '# wsl-qdisk: added boot section'
$script:TaskDescription = 'Managed by chuxel/dotfiles scripts/wsl-qdisk.'
$script:WslExe = Join-Path $env:SystemRoot 'System32\wsl.exe'
$script:LastWslExitCode = 0

function Assert-Prerequisites {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'This script must run on Windows.'
    }

    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this script from an elevated PowerShell session (Run as administrator).'
    }

    if (-not (Test-Path -LiteralPath $script:WslExe -PathType Leaf)) {
        throw "Required executable was not found: $($script:WslExe)"
    }
}

function Invoke-Wsl {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $output = @(& $script:WslExe @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $script:LastWslExitCode = $exitCode
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        $message = ($output | ForEach-Object { "$_" }) -join [Environment]::NewLine
        throw "wsl.exe failed with exit code ${exitCode}: $message"
    }
    return $output | ForEach-Object { "$_" }
}

function Invoke-UbuntuRoot {
    param(
        [Parameter(Mandatory)][string]$Command,
        [string[]]$CommandArguments = @(),
        [switch]$AllowFailure
    )

    $decodedArguments = @($CommandArguments | ForEach-Object {
        $encodedArgument = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_))
        "`"$(printf %s $encodedArgument | base64 -d)`""
    })
    $wrapper = "set -- $($decodedArguments -join ' ')`n$Command"
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($wrapper))
    $bootstrap = 'echo${IFS}' + $payload + '|base64${IFS}-d|/bin/sh'
    $arguments = @('-d', $DistroName, '-u', 'root', '--exec', '/bin/sh', '-c', $bootstrap)
    return Invoke-Wsl -Arguments $arguments -AllowFailure:$AllowFailure
}

function Write-UbuntuFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][ValidatePattern('^[0-7]{4}$')][string]$Mode
    )

    $lfContent = $Content.Replace("`r`n", "`n").Replace("`r", "`n")
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($lfContent))
    $null = Invoke-UbuntuRoot -Command @'
target=$1
mode=$2
encoded=$3
temporary="$(mktemp)"
trap 'rm -f "$temporary"' EXIT
printf '%s' "$encoded" | base64 -d > "$temporary"
chmod "$mode" "$temporary"
mv -f -- "$temporary" "$target"
trap - EXIT
'@ -CommandArguments @($Path, $Mode, $encoded)
}

function Remove-WslConfChanges {
    $encodedContent = (@(Invoke-UbuntuRoot -Command 'if [ -f /etc/wsl.conf ]; then base64 "$1" | tr -d "\n"; fi' -CommandArguments @('/etc/wsl.conf')) -join '').Trim()
    if (-not $encodedContent) {
        return
    }

    $content = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encodedContent)).Replace("`r", '')
    $lines = @($content -split "`n")
    $result = [Collections.Generic.List[string]]::new()
    $changed = $false
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]
        if ($line -eq $script:SystemdMarker) {
            if ($index + 1 -ge $lines.Count -or $lines[$index + 1] -notmatch '^\s*systemd\s*=\s*true\s*$') {
                throw 'Managed systemd marker in /etc/wsl.conf is inconsistent; refusing to edit it.'
            }
            $index++
            $changed = $true
            continue
        }

        if ($line -eq $script:BootCommandMarker) {
            if ($index + 1 -ge $lines.Count -or $lines[$index + 1] -notmatch ('^\s*command\s*=\s*' + [regex]::Escape($script:HelperPath) + '\s*$')) {
                throw 'Managed boot command marker in /etc/wsl.conf is inconsistent; refusing to edit it.'
            }
            $index++
            $changed = $true
            continue
        }

        if ($line.StartsWith("$($script:AppendedCommandMarker) original=", [StringComparison]::Ordinal)) {
            if ($index + 1 -ge $lines.Count) {
                throw 'Managed appended-command marker in /etc/wsl.conf is inconsistent; refusing to edit it.'
            }
            $encodedCommand = $line.Substring(("$($script:AppendedCommandMarker) original=").Length)
            try {
                $originalCommand = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encodedCommand))
            }
            catch {
                throw 'Managed appended-command marker contains invalid data; refusing to edit it.'
            }
            $commandLine = $lines[++$index]
            $expectedCommand = "command=printf %s $encodedCommand | base64 -d | /bin/sh; $($script:HelperPath)"
            if ($commandLine -cne $expectedCommand) {
                throw 'Managed appended command in /etc/wsl.conf was modified; refusing to edit it.'
            }
            $result.Add("command=$originalCommand")
            $changed = $true
            continue
        }

        $result.Add($line)
    }

    $sectionMarkerIndex = $result.IndexOf($script:BootSectionMarker)
    if ($sectionMarkerIndex -ge 0) {
        if ($sectionMarkerIndex + 1 -ge $result.Count -or $result[$sectionMarkerIndex + 1] -notmatch '^\s*\[\s*boot\s*\]\s*$') {
            throw 'Managed boot-section marker in /etc/wsl.conf is inconsistent; refusing to edit it.'
        }

        $sectionEnd = $result.Count
        for ($index = $sectionMarkerIndex + 2; $index -lt $result.Count; $index++) {
            if ($result[$index] -match '^\s*\[[^]]+\]\s*$') {
                $sectionEnd = $index
                break
            }
        }
        $hasUnmanagedSetting = $false
        for ($index = $sectionMarkerIndex + 2; $index -lt $sectionEnd; $index++) {
            if ($result[$index] -notmatch '^\s*$') {
                $hasUnmanagedSetting = $true
                break
            }
        }

        $result.RemoveAt($sectionMarkerIndex)
        if (-not $hasUnmanagedSetting) {
            $result.RemoveAt($sectionMarkerIndex)
        }
        $changed = $true
    }

    if (-not $changed) {
        return
    }

    $content = (($result -join "`n").TrimEnd("`n") + "`n")
    Write-UbuntuFile -Path '/etc/wsl.conf' -Content $content -Mode '0644'
}

function Unmount-LinuxTargets {
    $null = Invoke-UbuntuRoot -Command @'
label=$1
target=$2
for candidate in "$target" /mnt/qdisk; do
    if mountpoint -q -- "$candidate"; then
        device="$(findmnt -rn -M "$candidate" -o SOURCE)"
        mounted_label="$(blkid -s LABEL -o value -- "$device")"
        if [ "$mounted_label" != "$label" ]; then
            echo "Refusing to unmount unexpected filesystem at $candidate" >&2
            exit 1
        fi
        umount -- "$candidate"
    fi
done
'@ -CommandArguments @($DiskLabel, $MountPoint)
}

function Remove-ManagedHelper {
    $null = Invoke-UbuntuRoot -Command @'
if [ -e "$1" ]; then
    if ! grep -Fqx "$2" "$1"; then
        echo "Refusing to remove unmanaged helper $1" >&2
        exit 1
    fi
    rm -f -- "$1"
fi
'@ -CommandArguments @($script:HelperPath, $script:HelperMarker)
}

function Remove-ManagedTask {
    Import-Module ScheduledTasks -ErrorAction Stop
    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue
    if (-not $task) {
        return
    }
    if ($task.Description -ne $script:TaskDescription) {
        Write-Warning "Scheduled Task '$TaskName' is not marked as managed; leaving it in place."
        return
    }
    Unregister-ScheduledTask -TaskName $TaskName -TaskPath '\' -Confirm:$false
}

function Detach-Vhdx {
    $wasAttached = (@(Invoke-UbuntuRoot -Command 'if [ -e "/dev/disk/by-label/$1" ]; then printf attached; fi' -CommandArguments @($DiskLabel)) -join '').Trim()
    $detachOutput = @(Invoke-Wsl -Arguments @('--unmount', $VhdxPath) -AllowFailure)
    if ($script:LastWslExitCode -eq 0) {
        return
    }

    $null = Invoke-Wsl -Arguments @('--terminate', $DistroName) -AllowFailure
    $detachOutput = @(Invoke-Wsl -Arguments @('--unmount', $VhdxPath) -AllowFailure)
    if ($script:LastWslExitCode -eq 0) {
        return
    }

    if ($wasAttached) {
        throw "Failed to detach $VhdxPath`: $(($detachOutput | ForEach-Object { "$_" }) -join ' ')"
    }
}

Assert-Prerequisites
$VhdxPath = [IO.Path]::GetFullPath($VhdxPath)

if ($DeleteVhdx) {
    $requiredConfirmation = "DELETE $VhdxPath"
    if ($ConfirmVhdxDeletion -cne $requiredConfirmation) {
        throw "VHDX deletion requires -ConfirmVhdxDeletion '$requiredConfirmation'."
    }
}
elseif ($PSBoundParameters.ContainsKey('ConfirmVhdxDeletion')) {
    throw '-ConfirmVhdxDeletion is only valid with -DeleteVhdx.'
}

Remove-WslConfChanges
Remove-ManagedHelper
Unmount-LinuxTargets
Remove-ManagedTask

Detach-Vhdx
$null = Invoke-Wsl -Arguments @('--terminate', $DistroName) -AllowFailure

if ($DeleteVhdx -and (Test-Path -LiteralPath $VhdxPath -PathType Leaf)) {
    Remove-Item -LiteralPath $VhdxPath -Force
    Write-Host "Removed configuration and permanently deleted $VhdxPath." -ForegroundColor Yellow
}
else {
    Write-Host "Removed configuration and detached the VHDX. Data remains at $VhdxPath." -ForegroundColor Green
}
