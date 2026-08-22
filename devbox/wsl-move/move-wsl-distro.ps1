<#
.SYNOPSIS
    Moves an installed WSL distribution to <drive>\.wsl\<distribution>.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Position = 0)]
    [AllowEmptyString()]
    [string]$DistroName,

    [Parameter(Position = 1)]
    [ValidatePattern('^[A-Za-z]:$')]
    [string]$DestinationDrive = 'Q:'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'WslDistroMove.psm1') -Force
Move-WslDistribution @PSBoundParameters
