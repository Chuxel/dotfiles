[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$failed = $false
$files = @(
    (Join-Path $PSScriptRoot 'move-wsl-distro.ps1'),
    (Join-Path $PSScriptRoot 'WslDistroMove.psm1'),
    (Join-Path $PSScriptRoot 'validate.ps1')
)

foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
    foreach ($parseError in $errors) {
        $failed = $true
        Write-Error "$file`: $($parseError.Message)" -ErrorAction Continue
    }
}

if ($failed) {
    throw 'PowerShell parsing failed.'
}

$module = Import-Module (Join-Path $PSScriptRoot 'WslDistroMove.psm1') -Force -PassThru

& $module {
    function Assert-Equal {
        param(
            [Parameter(Mandatory)][object]$Expected,
            [Parameter(Mandatory)][object]$Actual,
            [Parameter(Mandatory)][string]$Test
        )
        if ("$Expected" -cne "$Actual") {
            throw "$Test failed. Expected '$Expected'; got '$Actual'."
        }
    }

    function Assert-Throws {
        param(
            [Parameter(Mandatory)][scriptblock]$Action,
            [Parameter(Mandatory)][string]$Pattern,
            [Parameter(Mandatory)][string]$Test
        )
        try {
            & $Action
            throw "$Test failed. No exception was thrown."
        }
        catch {
            if ($_.Exception.Message -notmatch $Pattern) {
                throw "$Test failed. Unexpected error: $($_.Exception.Message)"
            }
        }
    }

    Assert-Equal 'Q:\.wsl\Ubuntu' `
        (Get-WslDestinationPath -DistroName 'Ubuntu' -DestinationDrive 'q:') `
        'default layout'
    Assert-Equal 'D:\.wsl\Ubuntu-24.04' `
        (Get-WslDestinationPath -DistroName 'Ubuntu-24.04' -DestinationDrive 'D:') `
        'alternate drive layout'
    Assert-Throws { Get-WslDestinationPath -DistroName 'Ubuntu\bad' -DestinationDrive 'Q:' } `
        'cannot be used' `
        'invalid path character'
    Assert-Throws { Get-WslDestinationPath -DistroName 'CON' -DestinationDrive 'Q:' } `
        'reserved' `
        'reserved path component'

    $temporaryDestination = Join-Path ([IO.Path]::GetTempPath()) "wsl-move-validation-$([guid]::NewGuid())"
    $temporaryDrive = ([IO.Path]::GetPathRoot($temporaryDestination)).Substring(0, 2)
    try {
        New-Item -ItemType Directory -Path $temporaryDestination | Out-Null
        Assert-Throws {
            Assert-DestinationAvailable `
                -DestinationDrive $temporaryDrive `
                -DestinationPath $temporaryDestination
        } 'already exists and is empty' 'empty destination collision'

        Set-Content -LiteralPath (Join-Path $temporaryDestination 'existing.txt') -Value 'test'
        Assert-Throws {
            Assert-DestinationAvailable `
                -DestinationDrive $temporaryDrive `
                -DestinationPath $temporaryDestination
        } 'already exists and is non-empty' 'non-empty destination collision'
    }
    finally {
        Remove-Item -LiteralPath $temporaryDestination -Recurse -Force -ErrorAction SilentlyContinue
    }

    $nul = [char]0
    $decoded = @(ConvertFrom-WslOutput -Output @("U${nul}b${nul}u${nul}n${nul}t${nul}u${nul}"))
    Assert-Equal 'Ubuntu' $decoded[0] 'UTF-16 NUL cleanup'

    $script:WslCommandOverride = {
        param([string[]]$Arguments)
        if ($Arguments -contains '--list') {
            return [pscustomobject]@{ ExitCode = 0; Output = @("U${nul}b${nul}u${nul}n${nul}t${nul}u${nul}") }
        }
        return [pscustomobject]@{
            # Current WSL releases can return -1 from --help despite valid output.
            ExitCode = -1
            Output = @('Usage: wsl.exe --manage <Distro> [Options]', '--move <Location>')
        }
    }
    Assert-Equal 'Ubuntu' (Get-InstalledWslDistribution -DistroName 'ubuntu') 'installed distro parsing'
    Assert-Equal 'Ubuntu' (Get-InstalledWslDistribution) 'default distro selection'
    Assert-WslMoveSupport

    $script:WslCommandOverride = {
        param([string[]]$Arguments)
        return [pscustomobject]@{ ExitCode = 1; Output = @('Invalid command line option: --manage') }
    }
    Assert-Throws { Assert-WslMoveSupport } `
        'wsl\.exe --update' `
        'unsupported WSL guidance'
}

Remove-Module $module.Name -Force
Write-Host 'PowerShell parsing and isolated WSL move safety checks passed.' -ForegroundColor Green
