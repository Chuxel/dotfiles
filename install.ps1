<#
.SYNOPSIS
    Windows equivalent of install.sh - sets up fonts, Oh My Posh, fnm, bun, GitHub CLI,
    Copilot CLI, and git configuration.

.PARAMETER Overwrite
    Overwrite existing git user configuration. Defaults to $true.

.EXAMPLE
    ./install.ps1
    ./install.ps1 -Overwrite:$false
#>
[CmdletBinding()]
param(
    [bool]$Overwrite = $true
)

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

function Test-Command {
    param([Parameter(Mandatory)][string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-GitCredentialManager {
    if (Test-Command 'git-credential-manager') {
        return $true
    }

    if (Test-Command 'git') {
        & git credential-manager --version *> $null
        return $LASTEXITCODE -eq 0
    }

    return $false
}

function Update-SessionPath {
    $machine = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [System.Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = ($machine, $user | Where-Object { $_ }) -join ';'
}

function Add-ToUserPath {
    param([Parameter(Mandatory)][string]$Directory)

    $userPath = [System.Environment]::GetEnvironmentVariable('Path', 'User')
    $entries = @()
    if ($userPath) { $entries = $userPath -split ';' | Where-Object { $_ } }

    if ($entries -notcontains $Directory) {
        $newPath = (@($entries) + $Directory) -join ';'
        [System.Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    }

    if (($env:Path -split ';') -notcontains $Directory) {
        $env:Path = "$Directory;$env:Path"
    }
}

function Add-ToProfile {
    param(
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][string]$Content,
        [string]$ProfilePath = $PROFILE.CurrentUserAllHosts
    )

    $profileDir = Split-Path -Parent $ProfilePath
    if (-not (Test-Path $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    }
    if (-not (Test-Path $ProfilePath)) {
        New-Item -ItemType File -Path $ProfilePath -Force | Out-Null
    }

    if (Select-String -Path $ProfilePath -Pattern ([regex]::Escape($Marker)) -Quiet) {
        return
    }

    Add-Content -Path $ProfilePath -Value "`r`n$Content`r`n"
}

function Get-PowerShellProfilePaths {
    if (Test-Command 'pwsh') {
        return @(& pwsh -NoProfile -Command '$PROFILE.CurrentUserAllHosts; $PROFILE.CurrentUserCurrentHost') |
            ForEach-Object { $_.Trim() } |
            Select-Object -Unique
    }

    return @($PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost) | Select-Object -Unique
}

function Repair-OhMyPoshProfile {
    param([Parameter(Mandatory)][string]$ProfilePath)

    if (-not (Test-Path $ProfilePath)) {
        return
    }

    $content = [System.IO.File]::ReadAllText($ProfilePath)
    $legacyConfigPattern = '(?im)(oh-my-posh\s+init\s+pwsh\s+--config\s+)["'']?\$env:POSH_THEMES_PATH[/\\][^\s"'']+["'']?'
    $updatedContent = [regex]::Replace($content, $legacyConfigPattern, '$1"$HOME/.chuxel.omp.json"')

    if ($updatedContent -ne $content) {
        [System.IO.File]::WriteAllText($ProfilePath, $updatedContent)
    }
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$CommandName
    )

    if ($CommandName -and (Test-Command $CommandName)) {
        return
    }

    if (-not (Test-Command 'winget')) {
        Write-Warning "winget is not available - skipping install of $Id. Install 'App Installer' from the Microsoft Store."
        return
    }

    Write-Host "Installing $Id..."
    winget install --id $Id --exact --source winget --accept-package-agreements --accept-source-agreements --silent
    Update-SessionPath
}

function Install-Fonts {
    $registryPath = 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
    $installedFontNames = @()
    if (Test-Path $registryPath) {
        $installedFontNames = @((Get-ItemProperty -Path $registryPath).PSObject.Properties.Name)
    }

    $cascadiaInstalled = $installedFontNames -match '^Cascadia.*\(TrueType\)$'
    $requiredMesloFonts = @(
        'MesloLGS NF Regular (TrueType)'
        'MesloLGS NF Bold (TrueType)'
        'MesloLGS NF Italic (TrueType)'
        'MesloLGS NF Bold Italic (TrueType)'
    )

    if ($cascadiaInstalled -and ($requiredMesloFonts | Where-Object { $_ -notin $installedFontNames }).Count -eq 0) {
        Write-Host 'Fonts are already installed.'
        return
    }

    $downloadTo = Join-Path $env:TEMP 'dotfiles-fonts'
    New-Item -ItemType Directory -Path $downloadTo -Force | Out-Null

    # Per-user font folder - no admin rights required
    $fontFolder = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    New-Item -ItemType Directory -Path $fontFolder -Force | Out-Null

    try {
        $ttfFiles = @()
        if (-not $cascadiaInstalled) {
            $cascadiaZip = Join-Path $downloadTo 'cascadia.zip'
            Invoke-WebRequest -UseBasicParsing `
                -Uri 'https://github.com/microsoft/cascadia-code/releases/download/v2407.24/CascadiaCode-2407.24.zip' `
                -OutFile $cascadiaZip
            Expand-Archive -Path $cascadiaZip -DestinationPath (Join-Path $downloadTo 'cascadia') -Force

            $ttfFiles += Get-ChildItem -Path (Join-Path $downloadTo 'cascadia\ttf') -Filter '*.ttf' -File
        }

        $mesloFonts = @{
            'MesloLGS NF Regular.ttf'     = 'MesloLGS%20NF%20Regular.ttf'
            'MesloLGS NF Bold.ttf'        = 'MesloLGS%20NF%20Bold.ttf'
            'MesloLGS NF Italic.ttf'      = 'MesloLGS%20NF%20Italic.ttf'
            'MesloLGS NF Bold Italic.ttf' = 'MesloLGS%20NF%20Bold%20Italic.ttf'
        }
        foreach ($font in $mesloFonts.GetEnumerator()) {
            $target = Join-Path $downloadTo $font.Key
            Invoke-WebRequest -UseBasicParsing `
                -Uri "https://github.com/romkatv/powerlevel10k-media/raw/master/$($font.Value)" `
                -OutFile $target
            $ttfFiles += Get-Item $target
        }

        if (-not (Test-Path $registryPath)) {
            New-Item -Path $registryPath -Force | Out-Null
        }

        foreach ($file in $ttfFiles) {
            $destination = Join-Path $fontFolder $file.Name
            Copy-Item -Path $file.FullName -Destination $destination -Force
            Set-ItemProperty -Path $registryPath -Name "$($file.BaseName) (TrueType)" -Value $destination
        }
    }
    finally {
        Remove-Item -Path $downloadTo -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Install-OhMyPosh {
    Install-WingetPackage -Id 'JanDeDobbeleer.OhMyPosh' -CommandName 'oh-my-posh'

    Copy-Item -Path (Join-Path $PSScriptRoot 'chuxel.omp.json') -Destination (Join-Path $HOME '.chuxel.omp.json') -Force

    $profilePaths = @(Get-PowerShellProfilePaths)
    foreach ($profilePath in $profilePaths) {
        Repair-OhMyPoshProfile -ProfilePath $profilePath
    }

    Add-ToProfile -ProfilePath $profilePaths[0] -Marker 'oh-my-posh init' -Content @'
# Add Oh My Posh
if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
    oh-my-posh init pwsh --config "$HOME/.chuxel.omp.json" | Invoke-Expression
}
'@
}

function Install-Fnm {
    Install-WingetPackage -Id 'Schniz.fnm' -CommandName 'fnm'

    Add-ToProfile -ProfilePath (Get-PowerShellProfilePath) -Marker 'fnm env' -Content @'
# Add fnm (Node.js version manager) with auto-switch on cd
if (Get-Command fnm -ErrorAction SilentlyContinue) {
    fnm env --use-on-cd --shell power-shell | Out-String | Invoke-Expression
}
'@

    if (Test-Command 'fnm') {
        # Install and activate the latest LTS if no Node version is managed yet
        if (-not (fnm list | Select-String -Pattern 'v\d' -Quiet)) {
            fnm install --lts
        }
        fnm default lts-latest
    }
}

function Install-Bun {
    if (-not (Test-Command 'bun')) {
        Write-Host 'Installing bun...'
        # bun's Windows installer is a PowerShell script
        Invoke-RestMethod -Uri 'https://bun.sh/install.ps1' | Invoke-Expression
        Update-SessionPath
    }

    $bunInstall = if ($env:BUN_INSTALL) { $env:BUN_INSTALL } else { Join-Path $HOME '.bun' }
    if (-not [System.Environment]::GetEnvironmentVariable('BUN_INSTALL', 'User')) {
        [System.Environment]::SetEnvironmentVariable('BUN_INSTALL', $bunInstall, 'User')
    }
    $env:BUN_INSTALL = $bunInstall
    Add-ToUserPath -Directory (Join-Path $bunInstall 'bin')
}

function Install-GhCli {
    Install-WingetPackage -Id 'GitHub.cli' -CommandName 'gh'
}

function Install-CopilotCli {
    Install-WingetPackage -Id 'GitHub.Copilot' -CommandName 'copilot'
}

function Install-Git {
    Install-WingetPackage -Id 'Git.Git' -CommandName 'git'
}

function Install-GitCredentialManager {
    if ($env:CODESPACES -eq 'true') {
        Write-Host 'Running in a Codespace - skipping Git Credential Manager setup.'
        return
    }

    if (-not (Test-GitCredentialManager)) {
        # Git for Windows bundles GCM, but install the standalone package if it is missing
        Install-WingetPackage -Id 'Git.GCM'
    }

    if (Test-GitCredentialManager) {
        git credential-manager configure
    }
    else {
        git config --global credential.helper manager
    }

    # DPAPI-backed store works over SSH sessions as well as interactive ones
    git config --global credential.credentialStore dpapi
}

function Test-WindowsTerminalInstalled {
    if (Get-Command 'wt.exe' -ErrorAction SilentlyContinue) {
        return $true
    }

    # wt.exe is an app execution alias and may not resolve in every shell - check the package directly
    if (Get-Command 'Get-AppxPackage' -ErrorAction SilentlyContinue) {
        $appx = Get-AppxPackage -Name 'Microsoft.WindowsTerminal' -ErrorAction SilentlyContinue
        if ($appx) {
            return $true
        }
    }

    $wtPaths = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsTerminal\wt.exe')
    )
    if ($wtPaths | Where-Object { Test-Path $_ }) {
        return $true
    }

    return $false
}

function Install-Terminal {
    if (Test-WindowsTerminalInstalled) {
        Write-Host 'Windows Terminal is already installed.'
    }
    else {
        Write-Host 'Windows Terminal not found - installing...'
        Install-WingetPackage -Id 'Microsoft.WindowsTerminal'

        if (-not (Test-WindowsTerminalInstalled)) {
            Write-Warning 'Windows Terminal install could not be verified - skipping terminal configuration.'
            return
        }
    }

    Install-WingetPackage -Id 'Microsoft.PowerShell' -CommandName 'pwsh'
    Set-DefaultTerminal
    Set-TerminalSettings
}

function Set-DefaultTerminal {
    # Make Windows Terminal the default terminal application (Windows 11+)
    $consoleKey = 'HKCU:\Console\%%Startup'
    if (-not (Test-Path $consoleKey)) {
        New-Item -Path $consoleKey -Force | Out-Null
    }

    # Well-known Windows Terminal delegation CLSIDs
    Set-ItemProperty -Path $consoleKey -Name 'DelegationConsole' -Value '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}' -Type String
    Set-ItemProperty -Path $consoleKey -Name 'DelegationTerminal' -Value '{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}' -Type String
}

function Set-TerminalSettings {
    # Default to PowerShell 7 with a Nerd Font in Windows Terminal
    $powerShell7ProfileGuid = '{574e775e-4f2a-5b96-ac1e-a2962a402336}'

    $candidatePaths = @(
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json')
    )

    $settingsPaths = @($candidatePaths | Where-Object { Test-Path $_ })

    if (-not $settingsPaths) {
        # Fresh install - Windows Terminal has not written settings yet, so seed the packaged location
        $seedPath = $candidatePaths[0]
        $seedDir = Split-Path -Parent $seedPath
        if (-not (Test-Path $seedDir)) {
            Write-Warning 'Windows Terminal settings folder not found - launch Windows Terminal once, then re-run to apply defaults.'
            return
        }

        '{}' | Set-Content -Path $seedPath -Encoding UTF8
        $settingsPaths = @($seedPath)
    }

    foreach ($settingsPath in $settingsPaths) {
        try {
            $settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json
        }
        catch {
            Write-Warning "Could not parse $settingsPath - skipping."
            continue
        }

        Copy-Item -Path $settingsPath -Destination "$settingsPath.bak" -Force

        $settings | Add-Member -NotePropertyName 'defaultProfile' -NotePropertyValue $powerShell7ProfileGuid -Force

        if (-not $settings.profiles) {
            $settings | Add-Member -NotePropertyName 'profiles' -NotePropertyValue ([pscustomobject]@{}) -Force
        }
        if (-not $settings.profiles.defaults) {
            $settings.profiles | Add-Member -NotePropertyName 'defaults' -NotePropertyValue ([pscustomobject]@{}) -Force
        }
        $settings.profiles.defaults | Add-Member -NotePropertyName 'font' -NotePropertyValue ([pscustomobject]@{ face = 'MesloLGS NF' }) -Force

        $settings | ConvertTo-Json -Depth 32 | Set-Content -Path $settingsPath -Encoding UTF8
    }
}

if (-not $IsAdmin) {
    Write-Warning 'Not running as administrator - some winget installs may prompt for elevation.'
}

Install-Fonts
Install-Git
Install-GitCredentialManager
Install-Terminal
Install-OhMyPosh
Install-Fnm
Install-Bun
Install-GhCli
Install-CopilotCli

# Set git username and email
$gitConfigPath = Join-Path $HOME '.gitconfig'
if ((-not (Test-Path $gitConfigPath)) -or $Overwrite) {
    git config --global user.email 'chuck_lantz@hotmail.com'
    git config --global user.name 'Chuck Lantz'
}

# Get rid of annoying git message on pull behaviors
git config --global pull.rebase false

# Copy SSH client config if present
$sshSource = Join-Path $PSScriptRoot '.ssh\config'
if (Test-Path $sshSource) {
    $sshFolder = Join-Path $HOME '.ssh'
    New-Item -ItemType Directory -Path $sshFolder -Force | Out-Null
    $sshTarget = Join-Path $sshFolder 'config'
    if ((-not (Test-Path $sshTarget)) -or $Overwrite) {
        Copy-Item -Path $sshSource -Destination $sshTarget -Force
    }
}

Write-Host ''
Write-Host 'Done. Restart your terminal to pick up PATH and profile changes.' -ForegroundColor Green
Write-Host 'Node.js is managed by fnm - use "fnm install <version>" and "fnm use <version>" as needed.' -ForegroundColor Green
