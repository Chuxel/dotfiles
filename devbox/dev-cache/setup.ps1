<#
.SYNOPSIS
    Relocates developer tool caches to a dedicated Windows drive.

.DESCRIPTION
    Creates per-tool cache directories beneath CacheRoot, persists the corresponding
    user environment variables, and configures installed package managers. Installs
    and activates Mr Boxington for Rust builds. Existing tool caches are migrated
    by default, except for Mr Boxington's managed build data and Bazel build caches.

.PARAMETER CacheRoot
    Absolute filesystem path that will contain the developer caches.

.PARAMETER MigrateExisting
    Moves existing tool-cache contents into newly selected locations. Enabled by
    default; pass -MigrateExisting:$false for configuration only. Windows TEMP/TMP
    contents, Bazel build caches, and Cargo-installed binaries and install metadata
    remain in place. Existing Bazel storage is reported for offline review.

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
    [switch]$MigrateExisting = $true
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

        [string[]]$ExcludeNames = @(),

        [string]$MigrationSourceRoot,

        [string]$MigrationDestinationRoot,

        [switch]$ResolveCacheConflicts
    )

    if (-not $MigrationSourceRoot) {
        $MigrationSourceRoot = $Source
    }
    if (-not $MigrationDestinationRoot) {
        $MigrationDestinationRoot = $Destination
    }

    foreach ($sourceItem in @(Get-MigrationItems -Path $Source)) {
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
        if ($sourceIsReparsePoint) {
            try {
                $mappedTarget = Get-MappedReparseTarget `
                    -Item $sourceItem `
                    -SourceRoot $MigrationSourceRoot `
                    -DestinationRoot $MigrationDestinationRoot
            }
            catch {
                if (-not $ResolveCacheConflicts) {
                    throw
                }
                # The move pass reports and retains unsupported source links.
                continue
            }
            if ($destinationIsReparsePoint) {
                $destinationTarget = Resolve-ReparseTarget -Item $destinationItem
                if ($destinationTarget.Resolved -ne
                    [IO.Path]::GetFullPath($mappedTarget.Destination).TrimEnd('\')) {
                    throw "Migration collision involving a different reparse point: $destinationItemPath"
                }
            }
            elseif ($sourceItem.PSIsContainer -and $destinationItem.PSIsContainer) {
                # A previous migration may have materialized an internal alias as
                # a real directory. The canonical target is validated separately.
            }
            else {
                throw "Migration collision involving a reparse point: $destinationItemPath"
            }
            continue
        }
        if ($destinationIsReparsePoint) {
            throw "Migration collision involving an unexpected destination reparse point: $destinationItemPath"
        }

        if ($sourceItem.PSIsContainer -and $destinationItem.PSIsContainer) {
            Assert-DirectoryMigrationCompatible `
                -Source $sourceItem.FullName `
                -Destination $destinationItem.FullName `
                -MigrationSourceRoot $MigrationSourceRoot `
                -MigrationDestinationRoot $MigrationDestinationRoot `
                -ResolveCacheConflicts:$ResolveCacheConflicts
            continue
        }

        if (-not $sourceItem.PSIsContainer -and -not $destinationItem.PSIsContainer) {
            if ($ResolveCacheConflicts) {
                continue
            }
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

        [switch]$SuppressSummary,

        [string]$MigrationSourceRoot,

        [string]$MigrationDestinationRoot,

        [switch]$ResolveCacheConflicts
    )

    $sourcePath = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Source))
    $destinationPath = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Destination))
    if (-not $MigrationSourceRoot) {
        $MigrationSourceRoot = $sourcePath
    }
    if (-not $MigrationDestinationRoot) {
        $MigrationDestinationRoot = $destinationPath
    }
    if ($sourcePath.TrimEnd('\') -eq $destinationPath.TrimEnd('\')) {
        return
    }
    if ($sourcePath.StartsWith("$($destinationPath.TrimEnd('\'))\", [StringComparison]::OrdinalIgnoreCase) -or
        $destinationPath.StartsWith("$($sourcePath.TrimEnd('\'))\", [StringComparison]::OrdinalIgnoreCase)) {
        throw "Migration source and destination must not overlap: $sourcePath -> $destinationPath"
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
    foreach ($path in @($sourcePath, $destinationPath)) {
        if ((Test-Path -LiteralPath $path) -and
            ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Migration refuses a root reparse point: $path"
        }
    }

    $eligibleItems = @(
        Get-MigrationItems -Path $sourcePath |
            Where-Object { $ExcludeNames -notcontains $_.Name }
    )
    if ($eligibleItems.Count -eq 0) {
        if (-not $SuppressSummary) {
            Write-Host "No eligible cache contents to migrate from $sourcePath"
        }
        return
    }

    New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
    Assert-DirectoryMigrationCompatible `
        -Source $sourcePath `
        -Destination $destinationPath `
        -ExcludeNames $ExcludeNames `
        -MigrationSourceRoot $MigrationSourceRoot `
        -MigrationDestinationRoot $MigrationDestinationRoot `
        -ResolveCacheConflicts:$ResolveCacheConflicts

    foreach ($sourceItem in $eligibleItems) {
        if (-not (Test-Path -LiteralPath $sourceItem.FullName)) {
            continue
        }
        if ($ExcludeNames -contains $sourceItem.Name) {
            continue
        }

        $sourceAttributes = $sourceItem.Attributes
        $destinationItemPath = Join-Path $destinationPath $sourceItem.Name
        $sourceIsReparsePoint =
            ($sourceAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        if ($sourceIsReparsePoint) {
            try {
                $mappedTarget = Get-MappedReparseTarget `
                    -Item $sourceItem `
                    -SourceRoot $MigrationSourceRoot `
                    -DestinationRoot $MigrationDestinationRoot
            }
            catch {
                if (-not $ResolveCacheConflicts) {
                    throw
                }
                Write-Warning "Cache reparse point was left in place: $($sourceItem.FullName) ($($_.Exception.Message))"
                continue
            }
            if (-not $sourceItem.PSIsContainer) {
                if ($sourceItem.LinkType -ne 'SymbolicLink') {
                    throw "Migration refuses an unsupported file reparse point: $($sourceItem.FullName)"
                }
                if (-not (Test-Path -LiteralPath $mappedTarget.Source -PathType Leaf) -and
                    -not (Test-Path -LiteralPath $mappedTarget.Destination -PathType Leaf)) {
                    throw "Migration file-link target does not exist: $($mappedTarget.Source)"
                }

                if (Test-Path -LiteralPath $destinationItemPath) {
                    [IO.File]::Delete($sourceItem.FullName)
                    continue
                }

                $destinationParent = Split-Path -Parent $destinationItemPath
                New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
                $symbolicLinkTarget = if ([IO.Path]::IsPathRooted($mappedTarget.Raw)) {
                    $mappedTarget.Destination
                }
                else {
                    $mappedTarget.Raw
                }
                New-Item `
                    -ItemType SymbolicLink `
                    -Path $destinationItemPath `
                    -Target $symbolicLinkTarget | Out-Null
                [IO.File]::Delete($sourceItem.FullName)
                continue
            }

            if (Test-Path -LiteralPath $mappedTarget.Source -PathType Container) {
                Move-DirectoryContents `
                    -Source $mappedTarget.Source `
                    -Destination $mappedTarget.Destination `
                    -SuppressSummary `
                    -MigrationSourceRoot $MigrationSourceRoot `
                    -MigrationDestinationRoot $MigrationDestinationRoot `
                    -ResolveCacheConflicts:$ResolveCacheConflicts
            }
            elseif (-not (Test-Path -LiteralPath $mappedTarget.Destination -PathType Container)) {
                throw "Migration reparse-point target does not exist: $($mappedTarget.Source)"
            }

            if (Test-Path -LiteralPath $destinationItemPath) {
                $destinationItem = Get-Item -LiteralPath $destinationItemPath -Force
                $destinationIsReparsePoint =
                    ($destinationItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
                if ($destinationIsReparsePoint) {
                    [IO.Directory]::Delete($sourceItem.FullName)
                    continue
                }
                if (-not (Test-Path -LiteralPath $mappedTarget.Destination -PathType Container)) {
                    throw "Cannot replace a materialized cache alias without its canonical target: $destinationItemPath"
                }
                Remove-Item -LiteralPath $destinationItemPath -Recurse -Force
            }

            $destinationParent = Split-Path -Parent $destinationItemPath
            New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
            if ($sourceItem.LinkType -eq 'SymbolicLink') {
                $symbolicLinkTarget = if ([IO.Path]::IsPathRooted($mappedTarget.Raw)) {
                    $mappedTarget.Destination
                }
                else {
                    $mappedTarget.Raw
                }
                New-Item `
                    -ItemType SymbolicLink `
                    -Path $destinationItemPath `
                    -Target $symbolicLinkTarget | Out-Null
            }
            else {
                New-Item `
                    -ItemType Junction `
                    -Path $destinationItemPath `
                    -Target $mappedTarget.Destination | Out-Null
            }
            [IO.Directory]::Delete($sourceItem.FullName)
            continue
        }

        if (-not (Test-Path -LiteralPath $destinationItemPath)) {
            if ($sourceItem.PSIsContainer) {
                New-Item -ItemType Directory -Path $destinationItemPath -Force | Out-Null
                Move-DirectoryContents `
                    -Source $sourceItem.FullName `
                    -Destination $destinationItemPath `
                    -SuppressSummary `
                    -MigrationSourceRoot $MigrationSourceRoot `
                    -MigrationDestinationRoot $MigrationDestinationRoot `
                    -ResolveCacheConflicts:$ResolveCacheConflicts
                [IO.File]::SetAttributes($destinationItemPath, $sourceAttributes)
            }
            else {
                $copyCreated = $false
                $temporaryCopyPath = Join-Path $destinationPath ".dev-cache-$([Guid]::NewGuid().ToString('N')).tmp"
                try {
                    [IO.File]::Copy($sourceItem.FullName, $temporaryCopyPath, $false)
                    $copiedHash = (Get-FileHash -LiteralPath $temporaryCopyPath -Algorithm SHA256).Hash
                    $sourceHash = (Get-FileHash -LiteralPath $sourceItem.FullName -Algorithm SHA256).Hash
                    if ($copiedHash -ne $sourceHash) {
                        throw "Migration copy verification failed: $($sourceItem.FullName)"
                    }
                    [IO.File]::Move($temporaryCopyPath, $destinationItemPath)
                    $copyCreated = $true
                    [IO.File]::SetAttributes($destinationItemPath, $sourceAttributes)
                    [IO.File]::SetAttributes($sourceItem.FullName, [IO.FileAttributes]::Normal)
                    [IO.File]::Delete($sourceItem.FullName)
                }
                catch [IO.IOException], [UnauthorizedAccessException] {
                    if (-not $ResolveCacheConflicts) {
                        throw
                    }
                    if ($copyCreated -and (Test-Path -LiteralPath $destinationItemPath)) {
                        Remove-Item -LiteralPath $destinationItemPath -Force
                    }
                    Write-Warning "Cache file is in use and will be retried later: $($sourceItem.FullName)"
                }
                finally {
                    if (Test-Path -LiteralPath $temporaryCopyPath) {
                        Remove-Item -LiteralPath $temporaryCopyPath -Force
                    }
                }
            }
            continue
        }

        $destinationItem = Get-Item -LiteralPath $destinationItemPath -Force
        if ($sourceItem.PSIsContainer -and $destinationItem.PSIsContainer) {
            Move-DirectoryContents `
                -Source $sourceItem.FullName `
                -Destination $destinationItem.FullName `
                -SuppressSummary `
                -MigrationSourceRoot $MigrationSourceRoot `
                -MigrationDestinationRoot $MigrationDestinationRoot `
                -ResolveCacheConflicts:$ResolveCacheConflicts
            continue
        }

        if ($ResolveCacheConflicts) {
            try {
                if ($sourceItem.LastWriteTimeUtc -gt $destinationItem.LastWriteTimeUtc) {
                    $sourceHash = (Get-FileHash -LiteralPath $sourceItem.FullName -Algorithm SHA256).Hash
                    [IO.File]::Copy($sourceItem.FullName, $destinationItem.FullName, $true)
                    $copiedHash = (Get-FileHash -LiteralPath $destinationItem.FullName -Algorithm SHA256).Hash
                    if ($copiedHash -ne $sourceHash) {
                        throw "Migration copy verification failed: $($sourceItem.FullName)"
                    }
                    [IO.File]::SetAttributes($destinationItem.FullName, $sourceAttributes)
                }
                [IO.File]::SetAttributes($sourceItem.FullName, [IO.FileAttributes]::Normal)
                [IO.File]::Delete($sourceItem.FullName)
            }
            catch [IO.IOException], [UnauthorizedAccessException] {
                Write-Warning "Cache file is in use and will be retried later: $($sourceItem.FullName)"
            }
            continue
        }
        [IO.File]::SetAttributes($sourceItem.FullName, [IO.FileAttributes]::Normal)
        [IO.File]::Delete($sourceItem.FullName)
    }

    $remainingItems = @(
        Get-MigrationItems -Path $sourcePath |
            Where-Object { $ExcludeNames -notcontains $_.Name }
    )
    if ((Test-Path -LiteralPath $sourcePath -PathType Container) -and
        @(Get-MigrationItems -Path $sourcePath).Count -eq 0) {
        [IO.File]::SetAttributes($sourcePath, [IO.FileAttributes]::Directory)
        [IO.Directory]::Delete($sourcePath)
    }
    if (-not $SuppressSummary) {
        if ($remainingItems.Count -eq 0) {
            Write-Host "Migrated cache contents from $sourcePath to $destinationPath"
        }
        else {
            Write-Warning "$($remainingItems.Count) cache item(s) remain at $sourcePath and will be retried later."
        }
    }
}

function Apply-EnvironmentRedirect {
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Plan,

        [switch]$MigrateExisting,

        [string[]]$MigrationExcludeNames = @(),

        [switch]$ResolveCacheConflicts
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
                -ExcludeNames $MigrationExcludeNames `
                -ResolveCacheConflicts:$ResolveCacheConflicts
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

function Write-BazelMigrationWarning {
    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$Destination
    )

    if ($null -eq (Get-PathDriveRoot -Path $Source)) {
        Write-Warning "Bazel migration deferred for non-absolute path '$Source'; existing contents were left intact."
        return
    }
    $sourcePath = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Source))
    $destinationPath = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Destination))
    if ($sourcePath.TrimEnd('\') -ne $destinationPath.TrimEnd('\') -and
        (Test-Path -LiteralPath $sourcePath)) {
        Write-Warning "Bazel migration deferred: '$sourcePath' was left intact; future builds use '$destinationPath'. Bazel servers may still be using the old tree, and build state can contain absolute paths. Stop affected builds/servers before reviewing old data for tool-supported migration or cleanup; setup does not move or delete it."
    }
}

function Set-BazelCacheRedirects {
    param(
        [Parameter(Mandatory)]
        [string]$CacheRoot,

        [Parameter(Mandatory)]
        [string]$SystemDriveRoot,

        [switch]$MigrateExisting
    )

    $redirects = [ordered]@{
        XDG_CACHE_HOME = Join-Path $CacheRoot 'cache'
        COPILOT_BAZEL_OUTPUT_USER_ROOT = Join-Path ([IO.Path]::GetPathRoot($CacheRoot)) 'b'
    }
    foreach ($entry in $redirects.GetEnumerator()) {
        $userValue = [Environment]::GetEnvironmentVariable($entry.Key, 'User')
        $machineValue = [Environment]::GetEnvironmentVariable($entry.Key, 'Machine')
        $processValue = [Environment]::GetEnvironmentVariable($entry.Key, 'Process')
        $plan = Resolve-EnvironmentRedirect `
            -Name $entry.Key -UserValue $userValue -MachineValue $machineValue `
            -DesiredValue $entry.Value -SystemDriveRoot $SystemDriveRoot
        # Never bulk-migrate a general XDG root or a potentially live Bazel tree.
        Apply-EnvironmentRedirect -Plan $plan

        if (-not $MigrateExisting) {
            continue
        }
        $defaultSource = if ($entry.Key -eq 'XDG_CACHE_HOME') {
            Join-Path $HOME '.cache'
        }
        else {
            Join-Path $SystemDriveRoot 'b'
        }
        $previousRoots = @(
            @($defaultSource, $userValue, $machineValue, $processValue) |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -Unique
        )
        foreach ($sourceRoot in $previousRoots) {
            if ($entry.Key -eq 'XDG_CACHE_HOME') {
                if ($null -eq (Get-PathDriveRoot -Path $sourceRoot)) {
                    Write-Warning "Bazel migration deferred for non-absolute XDG cache root '$sourceRoot'; existing contents were left intact."
                    continue
                }
                foreach ($cacheName in @('copilot-bazel-disk', 'copilot-bazel-incremental')) {
                    Write-BazelMigrationWarning `
                        -Source (Join-Path $sourceRoot $cacheName) `
                        -Destination (Join-Path $plan.EffectiveValue $cacheName)
                }
            }
            else {
                Write-BazelMigrationWarning -Source $sourceRoot -Destination $plan.EffectiveValue
            }
        }
    }

    foreach ($scope in @('User', 'Machine', 'Process')) {
        $incrementalOverride = [Environment]::GetEnvironmentVariable('COPILOT_BAZEL_INCREMENTAL_DIR', $scope)
        if (-not [string]::IsNullOrWhiteSpace($incrementalOverride)) {
            Write-Warning "Existing $scope COPILOT_BAZEL_INCREMENTAL_DIR override was left unchanged. It overrides XDG cache placement and must include a per-worktree leaf; do not point every worktree at one shared incremental directory."
        }
    }
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
        [string]$Directory,

        [switch]$Prepend
    )

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($Prepend -and
        -not (Test-PathListContains -PathValues @($machinePath) -Directory $Directory)) {
        $updatedPath = Get-PrependedPath -PathValue $userPath -Directory $Directory
        if ($updatedPath -ne $userPath) {
            [Environment]::SetEnvironmentVariable('Path', $updatedPath, 'User')
            Write-Host "Prepended directory to the user PATH: $Directory"
        }
    }
    elseif (Test-PathListContains -PathValues @($userPath, $machinePath) -Directory $Directory) {
        Write-Host "Directory is already on the effective persistent PATH: $Directory"
    }
    else {
        $entries = @($userPath -split ';' | Where-Object { $_ })
        [Environment]::SetEnvironmentVariable('Path', (@($entries) + $Directory) -join ';', 'User')
        Write-Host "Added directory to the user PATH: $Directory"
    }

    if ($Prepend) {
        $env:Path = Get-PrependedPath -PathValue $env:Path -Directory $Directory
    }
    elseif (-not (Test-PathListContains -PathValues @($env:Path) -Directory $Directory)) {
        $env:Path = (@($env:Path, $Directory) | Where-Object { $_ }) -join ';'
    }
}

function Get-PrependedPath {
    param(
        [AllowNull()]
        [string]$PathValue,

        [Parameter(Mandatory)]
        [string]$Directory
    )

    $entries = @($PathValue -split ';' | Where-Object {
        $_ -and -not (Test-PathListContains -PathValues @($_) -Directory $Directory)
    })
    return (@($Directory) + $entries) -join ';'
}

function Install-MrBoxington {
    param(
        [Parameter(Mandatory)]
        [string]$BinDirectory
    )

    $existing = Get-Command 'mbx' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($existing) {
        return $existing.Source
    }
    $executable = Join-Path $BinDirectory 'mbx.exe'
    if (Test-Path -LiteralPath $executable -PathType Leaf) {
        return $executable
    }

    $architecture = if ($env:PROCESSOR_ARCHITEW6432) {
        $env:PROCESSOR_ARCHITEW6432
    }
    else {
        $env:PROCESSOR_ARCHITECTURE
    }
    $target = switch ($architecture) {
        'AMD64' { 'x86_64-pc-windows-msvc' }
        'ARM64' { 'aarch64-pc-windows-msvc' }
        default { throw "Mr Boxington has no Windows release for architecture '$architecture'." }
    }
    $archiveName = "mbx-$target.zip"
    $releaseUrl = 'https://github.com/jdx/mr-boxington/releases/latest/download'
    $temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) "dev-cache-mbx-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
    try {
        $archivePath = Join-Path $temporaryDirectory $archiveName
        Invoke-WebRequest -UseBasicParsing -Uri "$releaseUrl/$archiveName" -OutFile $archivePath
        $checksumsPath = Join-Path $temporaryDirectory 'SHA256SUMS'
        Invoke-WebRequest -UseBasicParsing -Uri "$releaseUrl/SHA256SUMS" -OutFile $checksumsPath
        $checksums = [IO.File]::ReadAllText($checksumsPath)
        $pattern = '(?m)^([a-fA-F0-9]{64})[ \t]+\*?' + [regex]::Escape($archiveName) + '\r?$'
        $checksumMatches = [regex]::Matches([string]$checksums, $pattern)
        if ($checksumMatches.Count -ne 1 -or
            (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash -ne $checksumMatches[0].Groups[1].Value) {
            throw "Mr Boxington archive checksum verification failed: $archiveName"
        }
        $extractDirectory = Join-Path $temporaryDirectory 'extracted'
        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractDirectory
        $downloadedExecutable = Join-Path $extractDirectory 'mbx.exe'
        if (-not (Test-Path -LiteralPath $downloadedExecutable -PathType Leaf)) {
            throw "Mr Boxington archive does not contain mbx.exe: $archiveName"
        }
        New-Item -ItemType Directory -Path $BinDirectory -Force | Out-Null
        Copy-Item -LiteralPath $downloadedExecutable -Destination $executable
        Write-Host "Installed Mr Boxington at $executable"
        return $executable
    }
    finally {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    }
}

function Resolve-MrBoxingtonCache {
    param(
        [AllowNull()]
        [string]$UserValue,

        [AllowNull()]
        [string]$MachineValue,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$ConfiguredCache,

        [Parameter(Mandatory)]
        [string]$DesiredValue,

        [Parameter(Mandatory)]
        [string]$SystemDriveRoot
    )

    if ($UserValue -or $MachineValue) {
        return Resolve-EnvironmentRedirect -Name 'MBX_CACHE_DIR' `
            -UserValue $UserValue -MachineValue $MachineValue `
            -DesiredValue $DesiredValue -SystemDriveRoot $SystemDriveRoot
    }
    $configuredRoot = Get-PathDriveRoot -Path $ConfiguredCache
    if ($null -ne $configuredRoot -and $configuredRoot -ne $SystemDriveRoot) {
        return [PSCustomObject]@{
            Name = 'MBX_CACHE_DIR'; Action = 'PreserveConfig'; EffectiveValue = $ConfiguredCache
        }
    }
    return [PSCustomObject]@{
        Name = 'MBX_CACHE_DIR'; Action = 'SetConfig'; EffectiveValue = $DesiredValue
    }
}

function Set-MrBoxingtonCache {
    param(
        [Parameter(Mandatory)]
        [string]$Command,

        [Parameter(Mandatory)]
        [string]$CacheRoot,

        [Parameter(Mandatory)]
        [string]$SystemDriveRoot
    )

    # Read the file setting without a stale process-only environment override.
    $previousProcessValue = [Environment]::GetEnvironmentVariable('MBX_CACHE_DIR', 'Process')
    Remove-Item -LiteralPath 'Env:MBX_CACHE_DIR' -ErrorAction SilentlyContinue
    try {
        $output = @(& $Command settings get cache_dir 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "Could not read Mr Boxington cache configuration: $($output -join [Environment]::NewLine)"
        }
        $configuredCache = ($output -join '').Trim()
    }
    finally {
        [Environment]::SetEnvironmentVariable('MBX_CACHE_DIR', $previousProcessValue, 'Process')
    }

    $plan = Resolve-MrBoxingtonCache `
        -UserValue ([Environment]::GetEnvironmentVariable('MBX_CACHE_DIR', 'User')) `
        -MachineValue ([Environment]::GetEnvironmentVariable('MBX_CACHE_DIR', 'Machine')) `
        -ConfiguredCache $configuredCache -DesiredValue (Join-Path $CacheRoot 'mbx') `
        -SystemDriveRoot $SystemDriveRoot
    $selectedCache = $plan.EffectiveValue
    switch ($plan.Action) {
        'PreserveConfig' {
            Write-Host "Preserved Mr Boxington cache configuration: $selectedCache"
            $env:MBX_CACHE_DIR = $selectedCache
        }
        'SetConfig' {
            Invoke-ExternalCommand -Command $Command -Arguments @('settings', 'set', 'cache_dir', $selectedCache)
            $env:MBX_CACHE_DIR = $selectedCache
        }
        default {
            Apply-EnvironmentRedirect -Plan $plan
        }
    }
    New-Item -ItemType Directory -Path $selectedCache -Force | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($configuredCache) -and $configuredCache -ne $selectedCache) {
        Write-Warning "Mr Boxington data at '$configuredCache' was not moved. Existing managed targets must be relocated by mbx, not bulk-migrated."
    }
    Write-Host "Mr Boxington build cache: $selectedCache"
}

function Enable-MrBoxington {
    param(
        [Parameter(Mandatory)]
        [string]$Command
    )

    foreach ($name in @('RUSTC_WRAPPER', 'RUSTC_WORKSPACE_WRAPPER')) {
        $userValue = [Environment]::GetEnvironmentVariable($name, 'User')
        $machineValue = [Environment]::GetEnvironmentVariable($name, 'Machine')
        $processValue = [Environment]::GetEnvironmentVariable($name, 'Process')
        if ($name -eq 'RUSTC_WRAPPER' -and $userValue -in @('sccache', 'sccache.exe')) {
            [Environment]::SetEnvironmentVariable($name, $null, 'User')
            $userValue = $null
            Write-Host 'Removed the legacy user RUSTC_WRAPPER=sccache setting.'
        }
        if ($name -eq 'RUSTC_WRAPPER' -and $processValue -in @('sccache', 'sccache.exe') -and
            -not $userValue -and -not $machineValue) {
            Remove-Item -LiteralPath "Env:$name"
            $processValue = $null
        }
        if ($userValue -or $machineValue -or $processValue) {
            throw "$name is configured. Remove the conflicting compiler wrapper before enabling Mr Boxington; mbx cannot cache those compilations."
        }
    }

    Invoke-ExternalCommand -Command $Command -Arguments @('--version')
    Invoke-ExternalCommand -Command $Command -Arguments @('setup', '--yes')
    $shimDirectory = Join-Path $env:LOCALAPPDATA 'mbx\bin'
    if (-not (Test-Path -LiteralPath (Join-Path $shimDirectory 'cargo.exe') -PathType Leaf)) {
        throw "Mr Boxington did not create its Cargo shim at $shimDirectory."
    }
    Add-ToEffectivePath -Directory $shimDirectory -Prepend
    if ((Get-Command 'cargo' -ErrorAction Stop).Source -ne (Join-Path $shimDirectory 'cargo.exe')) {
        throw 'Cargo does not resolve to the Mr Boxington shim. Remove the conflicting Cargo alias or function.'
    }
    $currentPath = $env:Path
    try {
        $env:Path = [Environment]::ExpandEnvironmentVariables(
            @([Environment]::GetEnvironmentVariable('Path', 'Machine'),
                [Environment]::GetEnvironmentVariable('Path', 'User')) -join ';')
        if ((Get-Command 'cargo' -ErrorAction Stop).Source -ne (Join-Path $shimDirectory 'cargo.exe')) {
            throw 'The persistent PATH selects another Cargo before the Mr Boxington shim. Reorder the conflicting Machine PATH entry.'
        }
    }
    finally {
        $env:Path = $currentPath
    }
    Invoke-ExternalCommand -Command $Command -Arguments @('setup', '--status')
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

function Resolve-ReparseTarget {
    param(
        [Parameter(Mandatory)]
        [IO.FileSystemInfo]$Item
    )

    $targets = @($Item.Target | Where-Object { $_ })
    if ($targets.Count -ne 1) {
        throw "Migration cannot safely resolve reparse point: $($Item.FullName)"
    }

    $rawTarget = "$($targets[0])"
    $resolvedTarget = if ([IO.Path]::IsPathRooted($rawTarget)) {
        [IO.Path]::GetFullPath($rawTarget)
    }
    else {
        $itemParent = if ($Item.PSIsContainer) {
            $Item.Parent.FullName
        }
        else {
            $Item.DirectoryName
        }
        [IO.Path]::GetFullPath((Join-Path $itemParent $rawTarget))
    }
    return [PSCustomObject]@{
        Raw = $rawTarget
        Resolved = $resolvedTarget.TrimEnd('\')
    }
}

function Select-RustupDefaultCandidate {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Toolchains
    )

    $toolchainNames = @(
        $Toolchains |
            ForEach-Object { ($_ -replace '\s+\([^)]*\)\s*$', '').Trim() } |
            Where-Object { $_ }
    )
    $stableToolchains = @($toolchainNames | Where-Object { $_ -match '^stable(?:-|$)' })
    if ($stableToolchains.Count -eq 1) {
        return $stableToolchains[0]
    }
    if ($toolchainNames.Count -eq 1) {
        return $toolchainNames[0]
    }
    return $null
}

function Get-MappedReparseTarget {
    param(
        [Parameter(Mandatory)]
        [IO.FileSystemInfo]$Item,

        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$DestinationRoot
    )

    $target = Resolve-ReparseTarget -Item $Item
    $sourceRootPath = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
    $targetPath = $target.Resolved
    $sourcePrefix = "$sourceRootPath\"
    if (-not $targetPath.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Migration refuses an external reparse-point target: $($Item.FullName) -> $targetPath"
    }

    $relativeTarget = $targetPath.Substring($sourcePrefix.Length)
    return [PSCustomObject]@{
        Source = $targetPath
        Destination = Join-Path $DestinationRoot $relativeTarget
        Raw = $target.Raw
    }
}

function Get-MigrationItems {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return @()
    }
    try {
        return @(Get-ChildItem -LiteralPath $Path -Force)
    }
    catch [Management.Automation.ItemNotFoundException] {
        return @()
    }
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
        $defaultCandidate = Select-RustupDefaultCandidate -Toolchains $toolchains
        if (-not $defaultCandidate) {
            throw @"
Rustup found installed toolchains in '$env:RUSTUP_HOME' but no unambiguous default.
Run 'rustup default <installed-toolchain>' after reviewing 'rustup toolchain list'.
"@
        }

        $defaultOutput = @(& $RustupCommand default $defaultCandidate 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "Could not restore installed Rustup default '$defaultCandidate': $($defaultOutput -join [Environment]::NewLine)"
        }
        Write-Host "Restored Rustup default to already-installed toolchain: $defaultCandidate"
        $activeOutput = @(& $RustupCommand show active-toolchain 2>&1)
        if ($LASTEXITCODE -ne 0 -or
            ($activeOutput -join [Environment]::NewLine) -match 'no active toolchain') {
            throw "Rustup still has no active default after selecting '$defaultCandidate'."
        }
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
        Move-DirectoryContents `
            -Source $previousRepositoryPath `
            -Destination $RepositoryPath `
            -ResolveCacheConflicts
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
    YARN_CACHE_FOLDER            = '.yarn'
    COREPACK_HOME                = 'corepack'
    BUN_INSTALL_CACHE_DIR        = 'bun'
    DENO_DIR                     = 'deno'
    COMPOSER_CACHE_DIR           = 'composer'
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
    YARN_CACHE_FOLDER          = @(
        (Join-Path $env:LOCALAPPDATA 'Yarn\Cache'),
        (Join-Path $env:LOCALAPPDATA 'Yarn\Berry\cache')
    )
    COREPACK_HOME              = @((Join-Path $env:LOCALAPPDATA 'node\corepack'))
    BUN_INSTALL_CACHE_DIR      = @((Join-Path $HOME '.bun\install\cache'))
    DENO_DIR                   = @((Join-Path $env:LOCALAPPDATA 'deno'))
    COMPOSER_CACHE_DIR         = @((Join-Path $env:LOCALAPPDATA 'Composer'))
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
        -MigrationExcludeNames $migrationExcludeNames `
        -ResolveCacheConflicts
    if ($MigrateExisting -and $defaultMigrationSources.ContainsKey($entry.Key)) {
        foreach ($source in $defaultMigrationSources[$entry.Key]) {
            if ($source.TrimEnd('\') -ne "$($plan.PreviousValue)".TrimEnd('\')) {
                Move-DirectoryContents `
                    -Source $source `
                    -Destination $plan.EffectiveValue `
                    -ExcludeNames $migrationExcludeNames `
                    -ResolveCacheConflicts
            }
        }
    }
    $effectiveValues[$entry.Key] = $plan.EffectiveValue
}

Set-BazelCacheRedirects -CacheRoot $CacheRoot -SystemDriveRoot $systemDriveRoot -MigrateExisting:$MigrateExisting

$cargoInstallRoot = Join-Path $HOME '.cargo'
$cargoBin = Join-Path $cargoInstallRoot 'bin'
New-Item -ItemType Directory -Path $cargoBin -Force | Out-Null
Set-UserEnvironmentVariable -Name 'CARGO_INSTALL_ROOT' -Value $cargoInstallRoot
Add-ToEffectivePath -Directory $effectiveValues['npm_config_prefix']
Add-ToEffectivePath -Directory $cargoBin

$rustup = Get-Command 'rustup' -ErrorAction SilentlyContinue
if ($rustup) {
    Assert-RustupConfiguration -RustupCommand $rustup.Source
}
else {
    Write-Warning 'rustup is not installed; Rust toolchain verification was skipped.'
}

$mbxCommand = Install-MrBoxington -BinDirectory $cargoBin
Add-ToEffectivePath -Directory (Split-Path -Parent $mbxCommand)
Set-MrBoxingtonCache -Command $mbxCommand -CacheRoot $CacheRoot -SystemDriveRoot $systemDriveRoot
Enable-MrBoxington -Command $mbxCommand

$pnpm = Get-Command 'pnpm' -ErrorAction SilentlyContinue
if ($pnpm) {
    Write-Host 'pnpm store location is not overridden; pnpm will use its per-drive store.'
}
else {
    Write-Warning 'pnpm is not installed; skipped pnpm store configuration.'
}

$composer = Get-Command 'composer' -ErrorAction SilentlyContinue
if ($composer) {
    $composerCache = $effectiveValues['COMPOSER_CACHE_DIR']
    if ($MigrateExisting) {
        $composerCacheEnvironment = $env:COMPOSER_CACHE_DIR
        Remove-Item -LiteralPath 'Env:COMPOSER_CACHE_DIR'
        try {
            $previousComposerCache = @(& $composer.Source config --global cache-dir 2>&1)
            $composerConfigExitCode = $LASTEXITCODE
        }
        finally {
            Set-Item -LiteralPath 'Env:COMPOSER_CACHE_DIR' -Value $composerCacheEnvironment
        }
        if ($composerConfigExitCode -ne 0) {
            throw "Could not determine the existing Composer cache directory: $($previousComposerCache -join [Environment]::NewLine)"
        }
        $previousComposerCache = ($previousComposerCache -join '').Trim()
        if ([IO.Path]::IsPathRooted($previousComposerCache)) {
            Move-DirectoryContents `
                -Source $previousComposerCache `
                -Destination $composerCache `
                -ResolveCacheConflicts
        }
        else {
            Write-Warning 'Existing Composer contents were not migrated because its cache path is not absolute.'
        }
    }
    New-Item -ItemType Directory -Path $composerCache -Force | Out-Null
    Invoke-ExternalCommand -Command $composer.Source -Arguments @(
        'config', '--global', 'cache-dir', $composerCache)
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
