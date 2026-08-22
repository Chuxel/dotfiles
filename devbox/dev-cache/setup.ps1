<#
.SYNOPSIS
    Relocates developer tool caches to a dedicated Windows drive.

.DESCRIPTION
    Creates per-tool cache directories beneath CacheRoot, persists the corresponding
    user environment variables, and configures installed package managers. Existing
    cache contents are not moved; this script only configures future cache use.

.PARAMETER CacheRoot
    Absolute filesystem path that will contain the developer caches.

.PARAMETER MigrateExisting
    Moves existing tool-cache contents into newly selected locations. Conflicting
    files are rejected before moving. Windows TEMP/TMP contents and Cargo-installed
    binaries and install metadata remain in place.

.EXAMPLE
    .\devbox\dev-cache\setup.ps1

.EXAMPLE
    .\devbox\dev-cache\setup.ps1 -CacheRoot 'D:\.tools'

.EXAMPLE
    .\devbox\dev-cache\setup.ps1 -MigrateExisting
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [ValidateScript({
        $pathRoot = [IO.Path]::GetPathRoot($_)
        if (-not [IO.Path]::IsPathRooted($_) -or $pathRoot -match '^[A-Za-z]:$') {
            throw 'CacheRoot must be an absolute Windows path.'
        }
        $true
    })]
    [string]$CacheRoot = 'Q:\.tools',

    [Parameter()]
    [switch]$MigrateExisting
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory)]
        [string]$Command,

        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    Write-Host "Configuring $Command..."
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command failed with exit code $LASTEXITCODE."
    }
}

function Set-UserEnvironmentVariable {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Value
    )

    $userValue = [Environment]::GetEnvironmentVariable($Name, 'User')
    $machineValue = [Environment]::GetEnvironmentVariable($Name, 'Machine')
    if ($userValue -eq $Value -or (-not $userValue -and $machineValue -eq $Value)) {
        Write-Host "Environment variable $Name is already configured."
    }
    else {
        [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
        Write-Host "Set user environment variable $Name=$Value"
    }

    Set-Item -LiteralPath "Env:$Name" -Value $Value
}

function Get-PathDriveRoot {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $expandedPath = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    if (-not [IO.Path]::IsPathRooted($expandedPath)) {
        return $null
    }

    $pathRoot = [IO.Path]::GetPathRoot($expandedPath)
    if ($pathRoot -match '^[A-Za-z]:$') {
        return "$pathRoot\"
    }
    return $pathRoot
}

function Resolve-EnvironmentRedirect {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [AllowNull()]
        [string]$UserValue,

        [AllowNull()]
        [string]$MachineValue,

        [Parameter(Mandatory)]
        [string]$DesiredValue,

        [Parameter(Mandatory)]
        [string]$SystemDriveRoot
    )

    $userRoot = Get-PathDriveRoot -Path $UserValue
    $machineRoot = Get-PathDriveRoot -Path $MachineValue
    $previousValue = if (-not [string]::IsNullOrWhiteSpace($UserValue)) {
        $UserValue
    }
    else {
        $MachineValue
    }

    if (-not [string]::IsNullOrWhiteSpace($UserValue)) {
        if ($null -ne $userRoot -and $userRoot -ne $SystemDriveRoot) {
            return [PSCustomObject]@{
                Name = $Name; Action = 'PreserveUser'; EffectiveValue = $UserValue; PreviousValue = $previousValue
            }
        }
        if ($null -ne $machineRoot -and $machineRoot -ne $SystemDriveRoot) {
            return [PSCustomObject]@{
                Name = $Name; Action = 'RemoveUser'; EffectiveValue = $MachineValue; PreviousValue = $previousValue
            }
        }
        return [PSCustomObject]@{
            Name = $Name; Action = 'SetUser'; EffectiveValue = $DesiredValue; PreviousValue = $previousValue
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($MachineValue)) {
        if ($null -eq $machineRoot -or $machineRoot -eq $SystemDriveRoot) {
            return [PSCustomObject]@{
                Name = $Name; Action = 'SetUser'; EffectiveValue = $DesiredValue; PreviousValue = $previousValue
            }
        }
        return [PSCustomObject]@{
            Name = $Name; Action = 'PreserveMachine'; EffectiveValue = $MachineValue; PreviousValue = $previousValue
        }
    }

    return [PSCustomObject]@{
        Name = $Name; Action = 'SetUser'; EffectiveValue = $DesiredValue; PreviousValue = $previousValue
    }
}

function Assert-DirectoryMigrationCompatible {
    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$Destination,

        [string[]]$ExcludeNames = @()
    )

    foreach ($sourceItem in @(Get-ChildItem -LiteralPath $Source -Force)) {
        if ($ExcludeNames -contains $sourceItem.Name) {
            continue
        }

        $destinationItemPath = Join-Path $Destination $sourceItem.Name
        if (-not (Test-Path -LiteralPath $destinationItemPath)) {
            continue
        }

        $destinationItem = Get-Item -LiteralPath $destinationItemPath -Force
        $sourceIsReparsePoint =
            ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        $destinationIsReparsePoint =
            ($destinationItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        if ($sourceIsReparsePoint -or $destinationIsReparsePoint) {
            throw "Migration collision involving a reparse point: $destinationItemPath"
        }

        if ($sourceItem.PSIsContainer -and $destinationItem.PSIsContainer) {
            Assert-DirectoryMigrationCompatible `
                -Source $sourceItem.FullName `
                -Destination $destinationItem.FullName
            continue
        }

        if (-not $sourceItem.PSIsContainer -and -not $destinationItem.PSIsContainer) {
            $sourceHash = (Get-FileHash -LiteralPath $sourceItem.FullName -Algorithm SHA256).Hash
            $destinationHash = (Get-FileHash -LiteralPath $destinationItem.FullName -Algorithm SHA256).Hash
            if ($sourceHash -eq $destinationHash) {
                continue
            }
        }

        throw "Migration collision would overwrite different content: $destinationItemPath"
    }
}

function Move-DirectoryContents {
    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$Destination,

        [string[]]$ExcludeNames = @(),

        [switch]$SuppressSummary
    )

    $sourcePath = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Source))
    $destinationPath = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Destination))
    if ($sourcePath.TrimEnd('\') -eq $destinationPath.TrimEnd('\')) {
        return
    }
    if ($sourcePath.TrimEnd('\') -eq [IO.Path]::GetPathRoot($sourcePath).TrimEnd('\')) {
        throw "Refusing to migrate a drive root: $sourcePath"
    }
    if ($sourcePath.TrimEnd('\') -eq [IO.Path]::GetFullPath($HOME).TrimEnd('\')) {
        throw "Refusing to migrate the user profile root: $sourcePath"
    }
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        Write-Host "No existing cache contents to migrate from $sourcePath"
        return
    }
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
        throw "Migration source is not a directory: $sourcePath"
    }

    $eligibleItems = @(
        Get-ChildItem -LiteralPath $sourcePath -Force |
            Where-Object { $ExcludeNames -notcontains $_.Name }
    )
    if ($eligibleItems.Count -eq 0) {
        Write-Host "No eligible cache contents to migrate from $sourcePath"
        return
    }

    New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
    Assert-DirectoryMigrationCompatible `
        -Source $sourcePath `
        -Destination $destinationPath `
        -ExcludeNames $ExcludeNames

    foreach ($sourceItem in @(Get-ChildItem -LiteralPath $sourcePath -Force)) {
        if ($ExcludeNames -contains $sourceItem.Name) {
            continue
        }

        $sourceAttributes = $sourceItem.Attributes
        $destinationItemPath = Join-Path $destinationPath $sourceItem.Name
        if (-not (Test-Path -LiteralPath $destinationItemPath)) {
            $sourceIsReparsePoint =
                ($sourceAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
            if ($sourceItem.PSIsContainer -and -not $sourceIsReparsePoint) {
                New-Item -ItemType Directory -Path $destinationItemPath -Force | Out-Null
                Move-DirectoryContents `
                    -Source $sourceItem.FullName `
                    -Destination $destinationItemPath `
                    -SuppressSummary
                [IO.File]::SetAttributes($destinationItemPath, $sourceAttributes)
            }
            elseif ($sourceIsReparsePoint) {
                Move-Item -LiteralPath $sourceItem.FullName -Destination $destinationItemPath
            }
            else {
                [IO.File]::Copy($sourceItem.FullName, $destinationItemPath, $false)
                $copiedHash = (Get-FileHash -LiteralPath $destinationItemPath -Algorithm SHA256).Hash
                $sourceHash = (Get-FileHash -LiteralPath $sourceItem.FullName -Algorithm SHA256).Hash
                if ($copiedHash -ne $sourceHash) {
                    Remove-Item -LiteralPath $destinationItemPath -Force
                    throw "Migration copy verification failed: $($sourceItem.FullName)"
                }
                [IO.File]::SetAttributes($sourceItem.FullName, [IO.FileAttributes]::Normal)
                [IO.File]::Delete($sourceItem.FullName)
                [IO.File]::SetAttributes($destinationItemPath, $sourceAttributes)
            }
            continue
        }

        $destinationItem = Get-Item -LiteralPath $destinationItemPath -Force
        if ($sourceItem.PSIsContainer -and $destinationItem.PSIsContainer) {
            Move-DirectoryContents `
                -Source $sourceItem.FullName `
                -Destination $destinationItem.FullName `
                -SuppressSummary
            continue
        }

        [IO.File]::SetAttributes($sourceItem.FullName, [IO.FileAttributes]::Normal)
        [IO.File]::Delete($sourceItem.FullName)
    }

    if (@(Get-ChildItem -LiteralPath $sourcePath -Force).Count -eq 0) {
        [IO.File]::SetAttributes($sourcePath, [IO.FileAttributes]::Directory)
        [IO.Directory]::Delete($sourcePath)
    }
    if (-not $SuppressSummary) {
        Write-Host "Migrated cache contents from $sourcePath to $destinationPath"
    }
}

function Apply-EnvironmentRedirect {
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Plan,

        [switch]$MigrateExisting,

        [string[]]$MigrationExcludeNames = @()
    )

    if ($MigrateExisting -and
        $Plan.Action -in @('SetUser', 'RemoveUser') -and
        -not [string]::IsNullOrWhiteSpace($Plan.PreviousValue)) {
        if ($Plan.Name -in @('TEMP', 'TMP')) {
            Write-Warning "Existing $($Plan.Name) contents were not migrated because the directory may be in use."
        }
        elseif ($null -eq (Get-PathDriveRoot -Path $Plan.PreviousValue)) {
            Write-Warning "Existing $($Plan.Name) contents were not migrated because the previous path is not absolute."
        }
        else {
            Move-DirectoryContents `
                -Source $Plan.PreviousValue `
                -Destination $Plan.EffectiveValue `
                -ExcludeNames $MigrationExcludeNames
        }
    }

    switch ($Plan.Action) {
        'SetUser' {
            New-Item -ItemType Directory -Path $Plan.EffectiveValue -Force | Out-Null
            [Environment]::SetEnvironmentVariable($Plan.Name, $Plan.EffectiveValue, 'User')
            Write-Host "Set user environment variable $($Plan.Name)=$($Plan.EffectiveValue)"
        }
        'RemoveUser' {
            [Environment]::SetEnvironmentVariable($Plan.Name, $null, 'User')
            Write-Host "Removed the C:-based user override for $($Plan.Name); using machine value $($Plan.EffectiveValue)"
        }
        'PreserveUser' {
            Write-Host "Preserved user environment variable $($Plan.Name)=$($Plan.EffectiveValue)"
        }
        'PreserveMachine' {
            Write-Host "Preserved machine environment variable $($Plan.Name)=$($Plan.EffectiveValue)"
        }
        default {
            throw "Unknown environment redirect action: $($Plan.Action)"
        }
    }

    Set-Item -LiteralPath "Env:$($Plan.Name)" -Value $Plan.EffectiveValue
}

function Test-PathListContains {
    param(
        [AllowNull()]
        [string[]]$PathValues,

        [Parameter(Mandatory)]
        [string]$Directory
    )

    $expected = [Environment]::ExpandEnvironmentVariables($Directory).Trim().TrimEnd('\')
    foreach ($pathValue in @($PathValues)) {
        foreach ($entry in @($pathValue -split ';' | Where-Object { $_ })) {
            $candidate = [Environment]::ExpandEnvironmentVariables($entry).Trim().Trim('"').TrimEnd('\')
            if ($candidate -eq $expected) {
                return $true
            }
        }
    }
    return $false
}

function Add-ToEffectivePath {
    param(
        [Parameter(Mandatory)]
        [string]$Directory
    )

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if (Test-PathListContains -PathValues @($userPath, $machinePath) -Directory $Directory) {
        Write-Host "Directory is already on the effective persistent PATH: $Directory"
    }
    else {
        $entries = @($userPath -split ';' | Where-Object { $_ })
        [Environment]::SetEnvironmentVariable('Path', (@($entries) + $Directory) -join ';', 'User')
        Write-Host "Added directory to the user PATH: $Directory"
    }

    if (-not (Test-PathListContains -PathValues @($env:Path) -Directory $Directory)) {
        $env:Path = (@($env:Path, $Directory) | Where-Object { $_ }) -join ';'
    }
}

function Get-InstalledRustupToolchains {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Output
    )

    return @(
        $Output |
            ForEach-Object { "$_".Trim() } |
            Where-Object { $_ -and $_ -ne 'no installed toolchains' }
    )
}

function Assert-RustupConfiguration {
    param(
        [Parameter(Mandatory)]
        [string]$RustupCommand
    )

    $toolchainOutput = @(& $RustupCommand toolchain list 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not list Rustup toolchains from '$env:RUSTUP_HOME': $($toolchainOutput -join [Environment]::NewLine)"
    }

    $toolchains = @(Get-InstalledRustupToolchains -Output $toolchainOutput)
    if ($toolchains.Count -eq 0) {
        Write-Warning "Rustup is installed but '$env:RUSTUP_HOME' contains no installed toolchains."
        return
    }

    $activeOutput = @(& $RustupCommand show active-toolchain 2>&1)
    if ($LASTEXITCODE -ne 0 -or
        ($activeOutput -join [Environment]::NewLine) -match 'no active toolchain') {
        throw @"
Rustup found installed toolchains in '$env:RUSTUP_HOME' but no active default.
The script will not download or select a toolchain automatically. Run 'rustup default <installed-toolchain>' after reviewing 'rustup toolchain list'.
"@
    }

    Write-Host "Rustup configuration verified: $(($activeOutput -join ' ').Trim())"
}

function Publish-EnvironmentChange {
    if (-not ('DevCache.NativeMethods' -as [type])) {
        Add-Type -TypeDefinition @'
namespace DevCache {
    using System;
    using System.Runtime.InteropServices;

    public static class NativeMethods {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr SendMessageTimeout(
            IntPtr hWnd,
            uint message,
            UIntPtr wParam,
            string lParam,
            uint flags,
            uint timeout,
            out UIntPtr result);
    }
}
'@
    }

    $result = [UIntPtr]::Zero
    $returnValue = [DevCache.NativeMethods]::SendMessageTimeout(
        [IntPtr]0xffff,
        0x001a,
        [UIntPtr]::Zero,
        'Environment',
        0x0002,
        5000,
        [ref]$result)
    if ($returnValue -eq [IntPtr]::Zero -and [Runtime.InteropServices.Marshal]::GetLastWin32Error() -ne 0) {
        Write-Warning 'Could not notify other applications that persistent environment settings changed.'
    }
}

function Set-MavenLocalRepository {
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryPath,

        [Parameter()]
        [string]$MavenDirectory = (Join-Path $HOME '.m2'),

        [switch]$MigrateExisting
    )

    $settingsPath = Join-Path $mavenDirectory 'settings.xml'
    New-Item -ItemType Directory -Path $mavenDirectory -Force | Out-Null

    $document = [Xml.XmlDocument]::new()
    $document.PreserveWhitespace = $true

    if (Test-Path -LiteralPath $settingsPath) {
        if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
            throw "Maven settings path is not a file: $settingsPath"
        }

        $readerSettings = [Xml.XmlReaderSettings]::new()
        $readerSettings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
        $readerSettings.XmlResolver = $null
        $reader = $null
        try {
            $reader = [Xml.XmlReader]::Create($settingsPath, $readerSettings)
            $document.Load($reader)
        }
        catch [Xml.XmlException] {
            throw "Maven settings.xml is malformed; no changes were made to '$settingsPath': $($_.Exception.Message)"
        }
        finally {
            if ($null -ne $reader) {
                $reader.Dispose()
            }
        }
    }
    else {
        $declaration = $document.CreateXmlDeclaration('1.0', 'utf-8', $null)
        [void]$document.AppendChild($declaration)
        [void]$document.AppendChild($document.CreateWhitespace("`r`n"))
        $settings = $document.CreateElement('settings', 'http://maven.apache.org/SETTINGS/1.0.0')
        $namespaceDeclaration = $document.CreateAttribute(
            'xmlns',
            'xsi',
            'http://www.w3.org/2000/xmlns/')
        $namespaceDeclaration.Value = 'http://www.w3.org/2001/XMLSchema-instance'
        [void]$settings.Attributes.Append($namespaceDeclaration)
        $schemaLocation = $document.CreateAttribute(
            'xsi',
            'schemaLocation',
            'http://www.w3.org/2001/XMLSchema-instance')
        $schemaLocation.Value =
            'http://maven.apache.org/SETTINGS/1.0.0 https://maven.apache.org/xsd/settings-1.0.0.xsd'
        [void]$settings.Attributes.Append($schemaLocation)
        [void]$document.AppendChild($settings)
        [void]$settings.AppendChild($document.CreateWhitespace("`r`n"))
    }

    $settingsElement = $document.DocumentElement
    if ($null -eq $settingsElement -or $settingsElement.LocalName -ne 'settings') {
        throw "Maven settings.xml must have a <settings> document element; no changes were made to '$settingsPath'."
    }

    $localRepositories = @(
        $settingsElement.ChildNodes |
            Where-Object { $_ -is [Xml.XmlElement] -and $_.LocalName -eq 'localRepository' }
    )
    if ($localRepositories.Count -gt 1) {
        throw "Maven settings.xml contains multiple <localRepository> elements; no changes were made to '$settingsPath'."
    }

    $previousRepositoryPath = if ($localRepositories.Count -eq 1) {
        $localRepositories[0].InnerText
    }
    else {
        Join-Path $mavenDirectory 'repository'
    }
    if ($MigrateExisting -and
        -not [string]::IsNullOrWhiteSpace($previousRepositoryPath) -and
        [IO.Path]::IsPathRooted($previousRepositoryPath)) {
        Move-DirectoryContents -Source $previousRepositoryPath -Destination $RepositoryPath
    }

    if ($localRepositories.Count -eq 1) {
        $localRepository = $localRepositories[0]
        if ($localRepository.InnerText -eq $RepositoryPath) {
            Write-Host "Maven localRepository is already configured in $settingsPath"
            return
        }
        $localRepository.InnerText = $RepositoryPath
    }
    else {
        $localRepository = $document.CreateElement('localRepository', $settingsElement.NamespaceURI)
        $localRepository.InnerText = $RepositoryPath

        $lastChild = $settingsElement.LastChild
        if ($null -ne $lastChild -and $lastChild -is [Xml.XmlWhitespace]) {
            [void]$settingsElement.InsertBefore($document.CreateWhitespace("`r`n  "), $lastChild)
            [void]$settingsElement.InsertBefore($localRepository, $lastChild)
        }
        else {
            [void]$settingsElement.AppendChild($document.CreateWhitespace("`r`n  "))
            [void]$settingsElement.AppendChild($localRepository)
            [void]$settingsElement.AppendChild($document.CreateWhitespace("`r`n"))
        }
    }

    $temporaryPath = Join-Path $mavenDirectory "settings.xml.$([Guid]::NewGuid().ToString('N')).tmp"
    $document.Save($temporaryPath)
    if (Test-Path -LiteralPath $settingsPath) {
        $backupPath = Join-Path $mavenDirectory "settings.xml.$([Guid]::NewGuid().ToString('N')).bak"
        [IO.File]::Replace($temporaryPath, $settingsPath, $backupPath)
        Remove-Item -LiteralPath $backupPath -Force
    }
    else {
        [IO.File]::Move($temporaryPath, $settingsPath)
    }
    Write-Host "Configured Maven localRepository in $settingsPath"
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This script must run on Windows.'
}

$CacheRoot = [IO.Path]::GetFullPath($CacheRoot)
$rootPath = [IO.Path]::GetPathRoot($CacheRoot)
if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) {
    throw "The drive for CacheRoot is not available: $rootPath"
}

$cacheDirectories = [ordered]@{
    TEMP                         = 'temp'
    TMP                          = 'temp'
    NUGET_PACKAGES               = '.nuget\packages'
    NUGET_HTTP_CACHE_PATH        = '.nuget\v3-cache'
    NUGET_PLUGINS_CACHE_PATH     = '.nuget\plugins-cache'
    npm_config_cache             = '.npm'
    npm_config_prefix            = '.npm-global'
    COREPACK_HOME                = 'corepack'
    BUN_INSTALL_CACHE_DIR        = 'bun'
    DENO_DIR                     = 'deno'
    PIP_CACHE_DIR                = 'pip'
    POETRY_CACHE_DIR             = 'poetry'
    UV_CACHE_DIR                 = 'uv'
    GOCACHE                      = 'go-build'
    GOMODCACHE                   = 'go-mod'
    GRADLE_USER_HOME             = 'gradle'
    CARGO_HOME                   = 'cargo'
    RUSTUP_HOME                  = 'rustup'
    SCCACHE_DIR                  = 'sccache'
    VCPKG_DEFAULT_BINARY_CACHE   = 'vcpkg-binary'
    VCPKG_DOWNLOADS              = 'vcpkg-downloads'
    PLAYWRIGHT_BROWSERS_PATH     = 'playwright'
    CYPRESS_CACHE_FOLDER         = 'cypress'
    ELECTRON_CACHE               = 'electron'
    ELECTRON_BUILDER_CACHE       = 'electron-builder'
}

$defaultMigrationSources = @{
    NUGET_PACKAGES             = @((Join-Path $HOME '.nuget\packages'))
    NUGET_HTTP_CACHE_PATH      = @((Join-Path $env:LOCALAPPDATA 'NuGet\v3-cache'))
    NUGET_PLUGINS_CACHE_PATH   = @((Join-Path $env:LOCALAPPDATA 'NuGet\plugins-cache'))
    npm_config_cache           = @((Join-Path $env:LOCALAPPDATA 'npm-cache'))
    npm_config_prefix          = @((Join-Path $env:APPDATA 'npm'))
    COREPACK_HOME              = @((Join-Path $env:LOCALAPPDATA 'node\corepack'))
    BUN_INSTALL_CACHE_DIR      = @((Join-Path $HOME '.bun\install\cache'))
    DENO_DIR                   = @((Join-Path $env:LOCALAPPDATA 'deno'))
    PIP_CACHE_DIR              = @((Join-Path $env:LOCALAPPDATA 'pip\Cache'))
    POETRY_CACHE_DIR           = @((Join-Path $env:LOCALAPPDATA 'pypoetry\Cache'))
    UV_CACHE_DIR               = @((Join-Path $env:LOCALAPPDATA 'uv\cache'))
    GOCACHE                    = @((Join-Path $env:LOCALAPPDATA 'go-build'))
    GOMODCACHE                 = @((Join-Path $HOME 'go\pkg\mod'))
    GRADLE_USER_HOME           = @((Join-Path $HOME '.gradle'))
    CARGO_HOME                 = @((Join-Path $HOME '.cargo'))
    RUSTUP_HOME                = @((Join-Path $HOME '.rustup'))
    SCCACHE_DIR                = @((Join-Path $env:LOCALAPPDATA 'Mozilla\sccache\cache'))
    VCPKG_DOWNLOADS            = @((Join-Path $env:LOCALAPPDATA 'vcpkg\downloads'))
    PLAYWRIGHT_BROWSERS_PATH   = @((Join-Path $env:LOCALAPPDATA 'ms-playwright'))
    CYPRESS_CACHE_FOLDER       = @((Join-Path $env:LOCALAPPDATA 'Cypress\Cache'))
    ELECTRON_CACHE             = @((Join-Path $env:LOCALAPPDATA 'electron\Cache'))
    ELECTRON_BUILDER_CACHE     = @((Join-Path $env:LOCALAPPDATA 'electron-builder\Cache'))
}

$systemDriveRoot = "$($env:SystemDrive)\"
$effectiveValues = @{}
foreach ($entry in $cacheDirectories.GetEnumerator()) {
    $desiredValue = Join-Path $CacheRoot $entry.Value
    $plan = Resolve-EnvironmentRedirect `
        -Name $entry.Key `
        -UserValue ([Environment]::GetEnvironmentVariable($entry.Key, 'User')) `
        -MachineValue ([Environment]::GetEnvironmentVariable($entry.Key, 'Machine')) `
        -DesiredValue $desiredValue `
        -SystemDriveRoot $systemDriveRoot
    $migrationExcludeNames = if ($entry.Key -eq 'CARGO_HOME') {
        @('bin', '.crates.toml', '.crates2.json')
    }
    else {
        @()
    }
    Apply-EnvironmentRedirect `
        -Plan $plan `
        -MigrateExisting:$MigrateExisting `
        -MigrationExcludeNames $migrationExcludeNames
    if ($MigrateExisting -and $defaultMigrationSources.ContainsKey($entry.Key)) {
        foreach ($source in $defaultMigrationSources[$entry.Key]) {
            if ($source.TrimEnd('\') -ne "$($plan.PreviousValue)".TrimEnd('\')) {
                Move-DirectoryContents `
                    -Source $source `
                    -Destination $plan.EffectiveValue `
                    -ExcludeNames $migrationExcludeNames
            }
        }
    }
    $effectiveValues[$entry.Key] = $plan.EffectiveValue
}

$yarn = Get-Command 'yarn' -ErrorAction SilentlyContinue
if ($yarn) {
    $yarnPlan = Resolve-EnvironmentRedirect `
        -Name 'YARN_CACHE_FOLDER' `
        -UserValue ([Environment]::GetEnvironmentVariable('YARN_CACHE_FOLDER', 'User')) `
        -MachineValue ([Environment]::GetEnvironmentVariable('YARN_CACHE_FOLDER', 'Machine')) `
        -DesiredValue (Join-Path $CacheRoot '.yarn') `
        -SystemDriveRoot $systemDriveRoot
    Apply-EnvironmentRedirect -Plan $yarnPlan -MigrateExisting:$MigrateExisting
    if ($MigrateExisting) {
        foreach ($source in @(
            (Join-Path $env:LOCALAPPDATA 'Yarn\Cache'),
            (Join-Path $env:LOCALAPPDATA 'Yarn\Berry\cache')
        )) {
            if ($source.TrimEnd('\') -ne "$($yarnPlan.PreviousValue)".TrimEnd('\')) {
                Move-DirectoryContents -Source $source -Destination $yarnPlan.EffectiveValue
            }
        }
    }
}
else {
    Write-Warning 'Yarn is not installed; skipped Yarn cache configuration.'
}

$cargoInstallRoot = Join-Path $HOME '.cargo'
$cargoBin = Join-Path $cargoInstallRoot 'bin'
New-Item -ItemType Directory -Path $cargoBin -Force | Out-Null
Set-UserEnvironmentVariable -Name 'CARGO_INSTALL_ROOT' -Value $cargoInstallRoot
Add-ToEffectivePath -Directory $effectiveValues['npm_config_prefix']
Add-ToEffectivePath -Directory $cargoBin

$sccache = Get-Command 'sccache' -ErrorAction SilentlyContinue
if ($sccache) {
    Set-UserEnvironmentVariable -Name 'RUSTC_WRAPPER' -Value 'sccache'
    Write-Host 'Rust compilation will use sccache.'
}
else {
    Write-Warning 'sccache is not installed; configured its cache directory but skipped the Rust compiler wrapper.'
}

$rustup = Get-Command 'rustup' -ErrorAction SilentlyContinue
if ($rustup) {
    Assert-RustupConfiguration -RustupCommand $rustup.Source
}
else {
    Write-Warning 'rustup is not installed; Rust toolchain verification was skipped.'
}

$pnpm = Get-Command 'pnpm' -ErrorAction SilentlyContinue
if ($pnpm) {
    Write-Host 'pnpm store location is not overridden; pnpm will use its per-drive store.'
}
else {
    Write-Warning 'pnpm is not installed; skipped pnpm store configuration.'
}

$composer = Get-Command 'composer' -ErrorAction SilentlyContinue
if ($composer) {
    $composerCache = Join-Path $CacheRoot 'composer'
    if ($MigrateExisting) {
        $previousComposerCache = @(& $composer.Source config --global cache-dir 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "Could not determine the existing Composer cache directory: $($previousComposerCache -join [Environment]::NewLine)"
        }
        $previousComposerCache = ($previousComposerCache -join '').Trim()
        if ([IO.Path]::IsPathRooted($previousComposerCache)) {
            Move-DirectoryContents -Source $previousComposerCache -Destination $composerCache
        }
        else {
            Write-Warning 'Existing Composer contents were not migrated because its cache path is not absolute.'
        }
    }
    New-Item -ItemType Directory -Path $composerCache -Force | Out-Null
    Invoke-ExternalCommand -Command $composer.Source -Arguments @(
        'config', '--global', 'cache-dir', $composerCache)
}
else {
    Write-Warning 'Composer is not installed; skipped Composer cache configuration.'
}

New-Item -ItemType Directory -Path (Join-Path $CacheRoot 'maven') -Force | Out-Null
Set-MavenLocalRepository `
    -RepositoryPath (Join-Path $CacheRoot 'maven') `
    -MigrateExisting:$MigrateExisting

Publish-EnvironmentChange

Write-Host ''
Write-Host "Developer cache redirects are configured; fallback root: $CacheRoot" -ForegroundColor Green
if ($MigrateExisting) {
    Write-Host 'Existing tool-cache contents were migrated where safe and present.'
}
else {
    Write-Host 'Existing cache contents were not migrated.'
}
Write-Host "Effective npm prefix: $($effectiveValues['npm_config_prefix'])"
Write-Host "Go and Cargo-installed executables remain in their user-profile locations on $([IO.Path]::GetPathRoot($HOME))"
Write-Host 'Other PowerShell processes that were already open cannot have their environment changed.'
Write-Host 'Restart those shells, or refresh Rust in one with:'
Write-Host '  $env:RUSTUP_HOME = [Environment]::GetEnvironmentVariable(''RUSTUP_HOME'', ''User'')'
Write-Host '  $env:CARGO_HOME = [Environment]::GetEnvironmentVariable(''CARGO_HOME'', ''User'')'
Write-Warning "The drive containing '$CacheRoot' must remain available whenever these tools run."
