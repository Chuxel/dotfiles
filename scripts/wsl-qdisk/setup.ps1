<#
.SYNOPSIS
    Creates and configures a persistent ext4 data VHDX for an Ubuntu WSL 2 distribution.

.DESCRIPTION
    Run from an elevated Windows PowerShell session. The script creates a dynamic VHDX
    when needed, safely initializes an empty disk, installs the mount helper, updates
    /etc/wsl.conf without replacing unrelated settings, and verifies user write access.
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$DistroName = 'Ubuntu',

    [ValidateNotNullOrEmpty()]
    [string]$VhdxDirectory = 'Q:\WSL\Ubuntu',

    [ValidateNotNullOrEmpty()]
    [string]$VhdxPath,

    [ValidateRange(1, 65536)]
    [int]$SizeGB = 500,

    [ValidatePattern('^[A-Za-z0-9._-]{1,16}$')]
    [string]$DiskLabel = 'qdisk',

    [ValidatePattern('^[a-z_][a-z0-9_-]*[$]?$')]
    [string]$LinuxUser = 'clantz',

    [ValidatePattern('^/[^\r\n]*$')]
    [string]$MountPoint = '/home/clantz/Repos',

    [ValidateNotNullOrEmpty()]
    [string]$TaskName = 'WSL Ubuntu qdisk mount'
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
$vhdxPathWasSpecified = $PSBoundParameters.ContainsKey('VhdxPath')
$vhdxDirectoryWasSpecified = $PSBoundParameters.ContainsKey('VhdxDirectory')

if ($vhdxPathWasSpecified -and $vhdxDirectoryWasSpecified) {
    throw 'Specify either -VhdxDirectory or -VhdxPath, not both.'
}
if (-not $vhdxPathWasSpecified) {
    if (-not [IO.Path]::IsPathRooted($VhdxDirectory)) {
        throw 'VhdxDirectory must be an absolute Windows path.'
    }
    $VhdxPath = Join-Path $VhdxDirectory 'qdisk.vhdx'
}

function Assert-Prerequisites {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'This script must run on Windows.'
    }

    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this script from an elevated PowerShell session (Run as administrator).'
    }

    foreach ($path in @($script:WslExe, (Join-Path $env:SystemRoot 'System32\diskpart.exe'))) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Required executable was not found: $path"
        }
    }

    if ($TaskName.IndexOfAny(@([char]0x0d, [char]0x0a, [char]0x22, [char]0x2f, [char]0x5c)) -ge 0) {
        throw 'TaskName cannot contain quotes, slashes, or newline characters.'
    }

    if ($VhdxPath.IndexOfAny(@([char]0x0d, [char]0x0a, [char]0x22)) -ge 0) {
        throw 'VhdxPath cannot contain quotes or newline characters.'
    }

    if ([IO.Path]::GetExtension($VhdxPath) -ne '.vhdx') {
        throw 'VhdxPath must end in .vhdx.'
    }

    if (-not [IO.Path]::IsPathRooted($VhdxPath)) {
        throw 'VhdxPath must be an absolute Windows path.'
    }

    $null = Invoke-UbuntuRoot -Command @'
case "$(uname -r)" in
    *[Ww][Ss][Ll]2*) ;;
    *) echo "The selected distribution is not running under WSL 2." >&2; exit 1 ;;
esac
command -v blkid >/dev/null
command -v findmnt >/dev/null
command -v lsblk >/dev/null
command -v mountpoint >/dev/null
command -v mkfs.ext4 >/dev/null
command -v wipefs >/dev/null
id "$1" >/dev/null
'@ -CommandArguments @($LinuxUser)
}

function Invoke-Wsl {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

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
        [Parameter(Mandatory)]
        [string]$Command,

        [string[]]$CommandArguments = @(),

        [switch]$AllowFailure
    )

    $decodedArguments = @($CommandArguments | ForEach-Object {
        $encodedArgument = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_))
        '"$(printf %s {0} | base64 -d)"' -f $encodedArgument
    })
    $wrapper = "set -- $($decodedArguments -join ' ')`n$Command"
    $wrapper = $wrapper.Replace("`r`n", "`n").Replace("`r", "`n")
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($wrapper))

    # The bootstrap contains no spaces or quotes, so Windows PowerShell 5.1 cannot
    # rewrite it while handing the argument to wsl.exe.
    $bootstrap = 'echo${IFS}' + $payload + '|base64${IFS}-d|/bin/sh'
    $arguments = @('-d', $DistroName, '-u', 'root', '--exec', '/bin/sh', '-c', $bootstrap)
    return Invoke-Wsl -Arguments $arguments -AllowFailure:$AllowFailure
}

function ConvertTo-ShellLiteral {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $singleQuote = [string][char]39
    $replacement = $singleQuote + '"' + $singleQuote + '"' + $singleQuote
    return $singleQuote + $Value.Replace($singleQuote, $replacement) + $singleQuote
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

function Get-WslConf {
    $encoded = (@(Invoke-UbuntuRoot -Command 'if [ -f /etc/wsl.conf ]; then base64 "$1" | tr -d "\n"; fi' -CommandArguments @('/etc/wsl.conf')) -join '').Trim()
    if (-not $encoded) {
        return ''
    }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
}

function Set-WslConf {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    $normalized = $Content.TrimEnd("`n") + "`n"
    Write-UbuntuFile -Path '/etc/wsl.conf' -Content $normalized -Mode '0644'
}

function Update-WslConf {
    $content = Get-WslConf
    $lines = [Collections.Generic.List[string]]::new()
    if ($content.Length -gt 0) {
        foreach ($line in ($content -split "`n")) {
            $lines.Add($line)
        }
    }

    $bootStart = -1
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '^\s*\[\s*boot\s*\]\s*$') {
            if ($bootStart -ge 0) {
                throw 'Multiple [boot] sections were found in /etc/wsl.conf; merge them before rerunning.'
            }
            $bootStart = $index
        }
    }

    if ($bootStart -lt 0) {
        if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -ne '') {
            $lines.Add('')
        }
        $lines.Add($script:BootSectionMarker)
        $lines.Add('[boot]')
        $lines.Add($script:SystemdMarker)
        $lines.Add('systemd=true')
        $lines.Add($script:BootCommandMarker)
        $lines.Add("command=$($script:HelperPath)")
        Set-WslConf -Content ($lines -join "`n")
        return
    }

    $bootEnd = $lines.Count
    for ($index = $bootStart + 1; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '^\s*\[[^]]+\]\s*$') {
            $bootEnd = $index
            break
        }
    }

    $systemdIndexes = @()
    for ($index = $bootStart + 1; $index -lt $bootEnd; $index++) {
        if ($lines[$index] -match '^\s*systemd\s*=\s*(.*?)\s*$') {
            $systemdIndexes += $index
        }
    }
    if ($systemdIndexes.Count -gt 1) {
        throw 'Multiple systemd settings were found in [boot]; resolve them before rerunning.'
    }
    if ($systemdIndexes.Count -eq 1) {
        if ($lines[$systemdIndexes[0]] -notmatch '^\s*systemd\s*=\s*true\s*$') {
            throw 'The existing [boot] systemd setting is not true; refusing to replace it.'
        }
    }
    else {
        $lines.Insert($bootEnd, $script:SystemdMarker)
        $lines.Insert($bootEnd + 1, 'systemd=true')
        $bootEnd += 2
    }

    $commandIndexes = @()
    for ($index = $bootStart + 1; $index -lt $bootEnd; $index++) {
        if ($lines[$index] -match '^\s*command\s*=\s*(.*?)\s*$') {
            $commandIndexes += $index
        }
    }
    if ($commandIndexes.Count -gt 1) {
        throw 'Multiple command settings were found in [boot]; resolve them before rerunning.'
    }
    if ($commandIndexes.Count -eq 0) {
        $lines.Insert($bootEnd, $script:BootCommandMarker)
        $lines.Insert($bootEnd + 1, "command=$($script:HelperPath)")
    }
    else {
        $commandIndex = $commandIndexes[0]
        $commandValue = [regex]::Match($lines[$commandIndex], '^\s*command\s*=\s*(.*?)\s*$').Groups[1].Value
        if ($commandValue -notmatch [regex]::Escape($script:HelperPath)) {
            $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($commandValue))
            $lines[$commandIndex] = "command=printf %s $encodedCommand | base64 -d | /bin/sh; $($script:HelperPath)"
            $lines.Insert($commandIndex, "$($script:AppendedCommandMarker) original=$encodedCommand")
        }
    }

    Set-WslConf -Content ($lines -join "`n")
}

function Install-MountHelper {
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Fa-f0-9-]+$')]
        [string]$FilesystemUuid
    )

    $templatePath = Join-Path $PSScriptRoot 'mount-qdisk.sh'
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        throw "Mount helper template was not found: $templatePath"
    }

    $existingCheck = @(Invoke-UbuntuRoot -Command @'
if [ -e "$1" ] && ! grep -Fqx "$2" "$1"; then
    echo "Refusing to replace unmanaged file $1" >&2
    exit 1
fi
'@ -CommandArguments @($script:HelperPath, $script:HelperMarker))

    $template = [IO.File]::ReadAllText($templatePath)
    $rendered = $template.
        Replace('__DISK_LABEL__', (ConvertTo-ShellLiteral $DiskLabel)).
        Replace('__FILESYSTEM_UUID__', (ConvertTo-ShellLiteral $FilesystemUuid)).
        Replace('__LINUX_USER__', (ConvertTo-ShellLiteral $LinuxUser)).
        Replace('__MOUNT_POINT__', (ConvertTo-ShellLiteral $MountPoint)).
        Replace('__TASK_NAME__', (ConvertTo-ShellLiteral $TaskName))
    Write-UbuntuFile -Path $script:HelperPath -Content $rendered -Mode '0755'
}

function New-DynamicVhdx {
    $fullPath = [IO.Path]::GetFullPath($VhdxPath)
    $parent = Split-Path -Parent $fullPath
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $maximumMB = [int64]$SizeGB * 1024
    $diskpartFile = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllLines(
            $diskpartFile,
            @("create vdisk file=`"$fullPath`" maximum=$maximumMB type=expandable"),
            [Text.Encoding]::ASCII)
        $output = @(& (Join-Path $env:SystemRoot 'System32\diskpart.exe') /s $diskpartFile 2>&1)
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw "diskpart failed to create the VHDX: $(($output | ForEach-Object { "$_" }) -join ' ')"
        }
    }
    finally {
        Remove-Item -LiteralPath $diskpartFile -Force -ErrorAction SilentlyContinue
    }
}

function Assert-ExistingVhdxMetadata {
    $getVhd = Get-Command Get-VHD -ErrorAction SilentlyContinue
    if (-not $getVhd) {
        Write-Verbose 'Get-VHD is unavailable; filesystem identity will be validated after attachment.'
        return
    }

    $vhd = Get-VHD -Path $VhdxPath
    if ("$($vhd.VhdType)" -ne 'Dynamic') {
        throw "Existing VHDX is $($vhd.VhdType), not Dynamic."
    }

    $expectedSize = [int64]$SizeGB * 1GB
    if ([int64]$vhd.Size -ne $expectedSize) {
        throw "Existing VHDX maximum size is $($vhd.Size) bytes; expected $expectedSize bytes."
    }
}

function Register-MountTask {
    Import-Module ScheduledTasks -ErrorAction Stop
    $expectedArguments = "--mount `"$([IO.Path]::GetFullPath($VhdxPath))`" --vhd --bare"
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $existing = Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction SilentlyContinue

    if ($existing -and $existing.Description -ne $script:TaskDescription) {
        $action = @($existing.Actions)
        $isExpected = $action.Count -eq 1 -and
            $action[0].Execute -eq $script:WslExe -and
            $action[0].Arguments -eq $expectedArguments -and
            "$($existing.Principal.RunLevel)" -eq 'Highest' -and
            $existing.Principal.UserId -eq $identity
        if (-not $isExpected) {
            throw "Scheduled Task '$TaskName' exists but is not managed by this script and does not match the requested configuration."
        }

        Write-Verbose "Using matching unmanaged Scheduled Task '$TaskName'; uninstall will leave it in place."
        return
    }

    $action = New-ScheduledTaskAction -Execute $script:WslExe -Argument $expectedArguments
    $principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
    $definition = New-ScheduledTask `
        -Action $action `
        -Principal $principal `
        -Settings $settings `
        -Description $script:TaskDescription
    Register-ScheduledTask -TaskName $TaskName -InputObject $definition -Force | Out-Null
}

function Get-LinuxDisks {
    $output = @(Invoke-UbuntuRoot -Command 'lsblk -dnpo NAME,TYPE')
    return @($output | ForEach-Object {
        if ($_ -match '^\s*(/\S+)\s+disk\s*$') {
            $matches[1]
        }
    })
}

function Get-DeviceByLabel {
    $output = @(Invoke-UbuntuRoot -Command @'
if [ -e "/dev/disk/by-label/$1" ]; then
    readlink -f -- "/dev/disk/by-label/$1"
fi
'@ -CommandArguments @($DiskLabel))
    return ($output -join '').Trim()
}

function Wait-ForDeviceLabel {
    param([Parameter(Mandatory)][string]$ExpectedDevice)

    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $labeledDevice = Get-DeviceByLabel
        if ($labeledDevice) {
            if ($labeledDevice -ne $ExpectedDevice) {
                throw "The '$DiskLabel' label resolved to unexpected device $labeledDevice."
            }
            return
        }
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "/dev/disk/by-label/$DiskLabel did not appear for $ExpectedDevice."
}

function Start-MountTaskAndWait {
    param([string[]]$DisksBefore)

    $startedAt = Get-Date
    Start-ScheduledTask -TaskName $TaskName -TaskPath '\'
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 500
        $task = Get-ScheduledTask -TaskName $TaskName -TaskPath '\'
        $taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath '\'
        $ranAfterStart = $taskInfo.LastRunTime -ge $startedAt.AddSeconds(-2)
        if ($ranAfterStart -and "$($task.State)" -notin @('Running', 'Queued')) {
            if ([int64]$taskInfo.LastTaskResult -ne 0) {
                throw "Scheduled Task '$TaskName' failed with result $($taskInfo.LastTaskResult)."
            }
            break
        }
    } while ([DateTime]::UtcNow -lt $deadline)

    if (-not $ranAfterStart -or "$($task.State)" -in @('Running', 'Queued')) {
        throw "Scheduled Task '$TaskName' did not finish within 30 seconds."
    }

    Start-Sleep -Seconds 1
    $disksAfter = @(Get-LinuxDisks)
    return [pscustomobject]@{
        Device = Get-DeviceByLabel
        NewDisks = @($disksAfter | Where-Object { $_ -notin $DisksBefore })
    }
}

function Reset-RequestedAttachment {
    $existingDevice = Get-DeviceByLabel
    $detachResult = @(Invoke-Wsl -Arguments @('--unmount', $VhdxPath) -AllowFailure)

    if ($script:LastWslExitCode -ne 0 -and $existingDevice) {
        $null = Invoke-UbuntuRoot -Command @'
target=$1
label=$2
if mountpoint -q -- "$target"; then
    device="$(findmnt -rn -M "$target" -o SOURCE)"
    mounted_label="$(blkid -s LABEL -o value -- "$device")"
    if [ "$mounted_label" != "$label" ]; then
        echo "Refusing to unmount unexpected filesystem at $target" >&2
        exit 1
    fi
    umount -- "$target"
fi
'@ -CommandArguments @($MountPoint, $DiskLabel)
        $detachResult = @(Invoke-Wsl -Arguments @('--unmount', $VhdxPath) -AllowFailure)
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        if (-not (Get-DeviceByLabel)) {
            return
        }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)

    $detail = ($detachResult -join [Environment]::NewLine)
    throw "A filesystem labeled '$DiskLabel' remained after detaching the requested VHDX. Refusing ambiguous disk selection. $detail"
}

function Initialize-OrValidateFilesystem {
    param(
        [string]$LabeledDevice,
        [string[]]$NewDisks
    )

    if ($NewDisks.Count -ne 1) {
        throw "Could not safely identify the attached VHDX. Expected one new disk, found $($NewDisks.Count); no disk was formatted."
    }

    $attachedDevice = $NewDisks[0]
    if ($LabeledDevice) {
        if ($LabeledDevice -ne $attachedDevice) {
            throw "The '$DiskLabel' label resolved to $LabeledDevice instead of newly attached disk $attachedDevice."
        }
    }

    $device = $attachedDevice
    $deviceType = (@(Invoke-UbuntuRoot -Command 'lsblk -dno TYPE "$1"' -CommandArguments @($device)) -join '').Trim()
    $filesystemType = (@(Invoke-UbuntuRoot -Command 'blkid -s TYPE -o value -- "$1" || true' -CommandArguments @($device)) -join '').Trim()
    $filesystemLabel = (@(Invoke-UbuntuRoot -Command 'blkid -s LABEL -o value -- "$1" || true' -CommandArguments @($device)) -join '').Trim()
    if ($deviceType -ne 'disk') {
        throw "Newly attached device $device is not a whole disk."
    }
    if ($filesystemType) {
        if ($filesystemType -ne 'ext4' -or $filesystemLabel -ne $DiskLabel) {
            throw "The newly attached disk $device contains unexpected filesystem '$filesystemType' labeled '$filesystemLabel'. Refusing to reformat it."
        }

        $null = Invoke-UbuntuRoot -Command @'
if command -v udevadm >/dev/null 2>&1; then
    udevadm trigger --subsystem-match=block
    udevadm settle
fi
'@
        Wait-ForDeviceLabel -ExpectedDevice $device
        return
    }

    $signatures = @(Invoke-UbuntuRoot -Command 'wipefs --no-act --noheadings --output TYPE -- "$1"' -CommandArguments @($device))
    $layout = @(Invoke-UbuntuRoot -Command 'lsblk -nrpo NAME,TYPE,FSTYPE,LABEL "$1"' -CommandArguments @($device))
    $hasFilesystem = $layout | Where-Object { $_ -match '\s(ext2|ext3|ext4|xfs|btrfs|ntfs|vfat|swap|crypto_LUKS)\s' }
    if ($signatures.Count -gt 0 -or $hasFilesystem) {
        throw "The newly attached disk $device already contains a filesystem or disk signature. Refusing to reformat it."
    }

    $null = Invoke-UbuntuRoot -Command @'
mkfs.ext4 -F -L "$2" -- "$1"
if command -v udevadm >/dev/null 2>&1; then
    udevadm trigger --subsystem-match=block
    udevadm settle
fi
'@ -CommandArguments @($device, $DiskLabel)
    Wait-ForDeviceLabel -ExpectedDevice $device
}

function Convert-OldMountLayout {
    $null = Invoke-UbuntuRoot -Command @'
label=$1
target=$2
old_target=/mnt/qdisk

if mountpoint -q -- "$target"; then
    mounted_device="$(findmnt -rn -M "$target" -o SOURCE)"
    mounted_label="$(blkid -s LABEL -o value -- "$mounted_device")"
    if [ "$mounted_label" != "$label" ]; then
        echo "Refusing to replace unexpected mount at $target" >&2
        exit 1
    fi
fi

if mountpoint -q -- "$old_target"; then
    old_device="$(findmnt -rn -M "$old_target" -o SOURCE)"
    old_label="$(blkid -s LABEL -o value -- "$old_device")"
    if [ "$old_label" != "$label" ]; then
        echo "Refusing to unmount unexpected filesystem at $old_target" >&2
        exit 1
    fi
    umount -- "$old_target"
fi

if [ -L "$target" ]; then
    resolved="$(readlink -f -- "$target")"
    if [ "$resolved" != "$old_target" ]; then
        echo "Refusing to replace unexpected symlink $target -> $resolved" >&2
        exit 1
    fi
    rm -- "$target"
fi

if [ -e "$target" ] && [ ! -d "$target" ]; then
    echo "Mount target $target is not a directory" >&2
    exit 1
fi

mkdir -p -- "$target"
if ! mountpoint -q -- "$target" && [ -n "$(find "$target" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    echo "Refusing to hide files already present in $target" >&2
    exit 1
fi
'@ -CommandArguments @($DiskLabel, $MountPoint)
}

function Restart-AndVerify {
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Fa-f0-9-]+$')]
        [string]$FilesystemUuid
    )

    $null = Invoke-Wsl -Arguments @('--terminate', $DistroName)
    $null = Invoke-UbuntuRoot -Command $script:HelperPath
    $null = Invoke-UbuntuRoot -Command @'
label=$1
user=$2
target=$3
expected_uuid=$4

if [ -L "$target" ] || ! mountpoint -q -- "$target"; then
    echo "$target is not a direct mount point" >&2
    exit 1
fi

device="$(findmnt -rn -M "$target" -o SOURCE)"
filesystem_type="$(findmnt -rn -M "$target" -o FSTYPE)"
mounted_label="$(blkid -s LABEL -o value -- "$device")"
mounted_uuid="$(blkid -s UUID -o value -- "$device")"
owner="$(stat -c '%U' -- "$target")"
if [ "$filesystem_type" != "ext4" ] ||
    [ "$mounted_label" != "$label" ] ||
    [ "$mounted_uuid" != "$expected_uuid" ] ||
    [ "$owner" != "$user" ]; then
    echo "Mounted filesystem validation failed" >&2
    exit 1
fi

test_file="$target/.wsl-qdisk-write-test.$$"
runuser -u "$user" -- touch "$test_file"
rm -f -- "$test_file"
'@ -CommandArguments @($DiskLabel, $LinuxUser, $MountPoint, $FilesystemUuid)
}

Assert-Prerequisites

$VhdxPath = [IO.Path]::GetFullPath($VhdxPath)
$vhdxExists = Test-Path -LiteralPath $VhdxPath -PathType Leaf
if ($vhdxExists) {
    Assert-ExistingVhdxMetadata
}
else {
    Write-Host "Creating dynamic ${SizeGB} GB VHDX at $VhdxPath..."
    New-DynamicVhdx
}

Register-MountTask
Reset-RequestedAttachment
$disksBefore = @(Get-LinuxDisks)
$attached = Start-MountTaskAndWait -DisksBefore $disksBefore
Initialize-OrValidateFilesystem -LabeledDevice $attached.Device -NewDisks $attached.NewDisks
$filesystemDevice = Get-DeviceByLabel
$filesystemUuid = (@(Invoke-UbuntuRoot -Command 'blkid -s UUID -o value -- "$1"' -CommandArguments @($filesystemDevice)) -join '').Trim()
if ($filesystemUuid -notmatch '^[A-Fa-f0-9-]+$') {
    throw "Could not read a valid filesystem UUID from $filesystemDevice."
}
Install-MountHelper -FilesystemUuid $filesystemUuid
Update-WslConf
Convert-OldMountLayout
Restart-AndVerify -FilesystemUuid $filesystemUuid

Write-Host "qdisk is mounted directly at $MountPoint and is writable by $LinuxUser." -ForegroundColor Green
