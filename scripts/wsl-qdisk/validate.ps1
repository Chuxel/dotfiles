[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$powerShellFiles = @(
    (Join-Path $PSScriptRoot 'setup.ps1'),
    (Join-Path $PSScriptRoot 'uninstall.ps1'),
    (Join-Path $PSScriptRoot 'validate.ps1')
)

$failed = $false
foreach ($file in $powerShellFiles) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $file,
        [ref]$tokens,
        [ref]$errors)
    if ($errors.Count -gt 0) {
        $failed = $true
        foreach ($error in $errors) {
            Write-Error "$file`: $($error.Message)" -ErrorAction Continue
        }
    }
}

$helper = Join-Path $PSScriptRoot 'mount-qdisk.sh'
$shell = Get-Command sh -ErrorAction SilentlyContinue
if ($shell) {
    & $shell.Source -n $helper
    if ($LASTEXITCODE -ne 0) {
        $failed = $true
    }
}
else {
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if ($wsl) {
        $linuxPath = (& $wsl.Source --exec wslpath -a -u $helper 2>$null | Select-Object -First 1)
        if ($LASTEXITCODE -eq 0 -and $linuxPath) {
            & $wsl.Source --exec sh -n $linuxPath
            if ($LASTEXITCODE -ne 0) {
                $failed = $true
            }
        }
        else {
            Write-Warning 'Could not translate the helper path for WSL; shell syntax was not checked.'
        }
    }
    else {
        Write-Warning 'Neither sh nor wsl.exe is available; shell syntax was not checked.'
    }
}

if ($failed) {
    throw 'Validation failed.'
}

Write-Host 'PowerShell parsing and available shell checks passed.' -ForegroundColor Green
