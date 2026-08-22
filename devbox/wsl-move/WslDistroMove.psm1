Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:WslCommandOverride = $null

function ConvertFrom-WslOutput {
    param([AllowNull()][object[]]$Output)

    return @(
        $Output |
            ForEach-Object {
                "$_".Replace(([char]0).ToString(), '').TrimStart([char]0xfeff)
            }
    )
}

function Invoke-WslCommand {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [switch]$AllowFailure
    )

    if ($script:WslCommandOverride) {
        $result = & $script:WslCommandOverride $Arguments
        $exitCode = [int]$result.ExitCode
        $output = ConvertFrom-WslOutput -Output @($result.Output)
    }
    else {
        $output = ConvertFrom-WslOutput -Output @(& $script:WslExe @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        $detail = ($output | Where-Object { $_ } | ForEach-Object { "$_" }) -join [Environment]::NewLine
        if (-not $detail) {
            $detail = 'No error details were returned.'
        }
        throw "wsl.exe $($Arguments -join ' ') failed with exit code ${exitCode}: $detail"
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = @($output)
    }
}

function Get-InstalledWslDistribution {
    param([AllowEmptyString()][string]$DistroName)

    $result = Invoke-WslCommand -Arguments @('--list', '--quiet')
    $installed = @(
        $result.Output |
            ForEach-Object { "$_".Trim() } |
            Where-Object { $_ }
    )
    if ($installed.Count -eq 0) {
        throw 'No WSL distributions are installed.'
    }

    if ([string]::IsNullOrWhiteSpace($DistroName)) {
        return $installed[0]
    }

    $match = @(
        $installed |
            Where-Object { [string]::Equals($_, $DistroName, [StringComparison]::OrdinalIgnoreCase) }
    )
    if ($match.Count -ne 1) {
        $available = if ($installed.Count -gt 0) { $installed -join ', ' } else { '(none)' }
        throw "WSL distribution '$DistroName' is not installed. Installed distributions: $available"
    }

    return $match[0]
}

function Assert-ValidPathComponent {
    param([Parameter(Mandatory)][string]$Value)

    if ($Value.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
        $Value -match '[<>:"/\\|?*\x00-\x1f]' -or
        $Value.EndsWith(' ') -or
        $Value.EndsWith('.')) {
        throw "Distribution name '$Value' cannot be used as a Windows directory name."
    }

    $baseName = $Value.Split('.')[0]
    if ($baseName -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
        throw "Distribution name '$Value' is a reserved Windows directory name."
    }
}

function Get-WslDestinationPath {
    param(
        [Parameter(Mandatory)][string]$DistroName,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z]:$')][string]$DestinationDrive
    )

    Assert-ValidPathComponent -Value $DistroName
    $drive = $DestinationDrive.Substring(0, 1).ToUpperInvariant()
    return [IO.Path]::GetFullPath("${drive}:\.wsl\$DistroName")
}

function Assert-WslMoveSupport {
    $result = Invoke-WslCommand -Arguments @('--help') -AllowFailure
    $help = $result.Output -join [Environment]::NewLine
    if ($help -notmatch '(?im)(?:^|\s)--manage(?:\s|$)' -or
        $help -notmatch '(?im)(?:^|\s)--move(?:\s|$)') {
        throw @"
This WSL installation does not advertise 'wsl.exe --manage <distro> --move <location>'.
Update the Microsoft Store version of WSL with 'wsl.exe --update', restart if requested,
and then rerun this command. No distribution was stopped or changed.
"@
    }
}

function Assert-DestinationAvailable {
    param(
        [Parameter(Mandatory)][string]$DestinationDrive,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    $driveName = $DestinationDrive.Substring(0, 1)
    $drive = Get-PSDrive -Name $driveName -PSProvider FileSystem -ErrorAction SilentlyContinue
    if (-not $drive -or -not (Test-Path -LiteralPath "$($driveName):\" -PathType Container)) {
        throw "Destination drive '$DestinationDrive' is not available as a Windows filesystem drive."
    }

    $destinationRoot = Join-Path "$($driveName):\" '.wsl'
    if (Test-Path -LiteralPath $destinationRoot) {
        if (-not (Test-Path -LiteralPath $destinationRoot -PathType Container)) {
            throw "Destination root '$destinationRoot' exists but is not a directory."
        }
    }

    if (Test-Path -LiteralPath $DestinationPath) {
        $item = Get-Item -LiteralPath $DestinationPath -Force
        if (-not $item.PSIsContainer) {
            throw "Destination '$DestinationPath' already exists and is not a directory."
        }

        $hasContents = $null -ne (Get-ChildItem -LiteralPath $DestinationPath -Force | Select-Object -First 1)
        $kind = if ($hasContents) { 'non-empty' } else { 'empty' }
        throw "Destination '$DestinationPath' already exists and is $kind. WSL location cannot be queried safely without unsupported registry inspection, so the script will not assume this is the current location."
    }

    return $destinationRoot
}

function Move-WslDistribution {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Position = 0)]
        [AllowEmptyString()]
        [string]$DistroName,

        [Parameter(Position = 1)]
        [ValidatePattern('^[A-Za-z]:$')]
        [string]$DestinationDrive = 'Q:'
    )

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'This command must run in Windows PowerShell or PowerShell on Windows.'
    }

    $script:WslExe = Join-Path $env:SystemRoot 'System32\wsl.exe'
    if (-not (Test-Path -LiteralPath $script:WslExe -PathType Leaf)) {
        throw "Required executable was not found: $($script:WslExe)"
    }

    $installedName = Get-InstalledWslDistribution -DistroName $DistroName
    $destinationPath = Get-WslDestinationPath -DistroName $installedName -DestinationDrive $DestinationDrive
    $destinationRoot = Assert-DestinationAvailable -DestinationDrive $DestinationDrive -DestinationPath $destinationPath
    Assert-WslMoveSupport

    $action = "terminate only '$installedName', then move it to '$destinationPath'"
    if (-not $PSCmdlet.ShouldProcess("WSL distribution '$installedName'", $action)) {
        return
    }

    if (-not (Test-Path -LiteralPath $destinationRoot)) {
        New-Item -ItemType Directory -Path $destinationRoot | Out-Null
    }

    $null = Invoke-WslCommand -Arguments @('--terminate', $installedName)
    try {
        $null = Invoke-WslCommand -Arguments @('--manage', $installedName, '--move', $destinationPath)
    }
    catch {
        throw "The move failed after '$installedName' was terminated. WSL did not report a successful relocation; the script did not unregister the distribution or delete its original data. Resolve the reported WSL error and start it with 'wsl.exe -d `"$installedName`"'. $($_.Exception.Message)"
    }

    Write-Host "Moved WSL distribution '$installedName' to '$destinationPath'."
    Write-Host "Verify it with: wsl.exe -d `"$installedName`""
}

Export-ModuleMember -Function Move-WslDistribution
